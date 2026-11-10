// ScriptClosureTimers.swift — live-only closure timers: repeating `every(n, fn)` callbacks and the
// `cancel(id)` verb shared with `after(n, fn)`. Named durable timers (`every(n, "name")`) live in
// `ScriptTimers.swift` and are unaffected.
//
// Each beat of a repeating closure starts a fresh coroutine with the normal per-callback
// instruction budget (one never-ending coroutine would trip the lifetime budget). A beat that
// arrives while the previous firing is still suspended (it called `wait`) is skipped rather than
// queued. The registry is an insertion-ordered array scanned in (wakeTick, id) order, so firing
// order is deterministic; it is never persisted and is dropped whenever the owning instance unloads
// (detach, edit, disable, chunk unload, world exit) or the script faults.

import ElysiumScript
import Foundation

/// One live `every(n, fn)` registration.
struct ScriptRepeatingClosureTimer {
    let id: UInt64
    let owner: ObjectRef
    let scriptName: String
    let function: ScriptFunction
    let interval: Int64
    var wakeTick: Int64
}

/// Runtime-owned state for closure timers. Caps bound per-tick work: at most `maxPerWorld` due
/// timers are examined per phase, each costing one bounded scheduler lookup.
struct ScriptClosureTimerRegistry {
    static let maxPerScript = 16
    static let maxPerWorld = 256

    var repeating: [ScriptRepeatingClosureTimer] = []
    private var nextID: UInt64 = 1

    /// Ids are shared by `after` and `every` closures, start at 1 (Check returns 0), and never repeat
    /// within a session.
    mutating func allocateID() -> UInt64 {
        defer { nextID = nextID == UInt64.max ? 1 : nextID + 1 }
        return nextID
    }
}

extension ScriptRuntime {
    var repeatingClosureTimerCount: Int { closureTimers.repeating.count }

    /// Run key of a pending `after(n, fn)` closure (and of its later suspensions).
    func afterClosureRunKey(owner: ObjectRef, scriptName: String, id: UInt64) -> String {
        owner.canonical + "#" + scriptName + "#timer#\(id)"
    }

    /// Run key of a repeating closure's current firing. Beats never overlap, so one key per timer
    /// suffices and doubles as the "previous firing still suspended" probe.
    func repeatingClosureRunKey(owner: ObjectRef, scriptName: String, id: UInt64) -> String {
        owner.canonical + "#" + scriptName + "#every#\(id)"
    }

    func scheduleRepeatingClosure(
        _ function: ScriptFunction, every interval: Int, owner: ObjectRef, scriptName: String
    ) -> HostResult {
        let mine = closureTimers.repeating.reduce(0) { count, timer in
            count + (timer.owner == owner && timer.scriptName == scriptName ? 1 : 0)
        }
        guard mine < ScriptClosureTimerRegistry.maxPerScript else {
            return .error("too many repeating every() callbacks on this script (limit \(ScriptClosureTimerRegistry.maxPerScript)); cancel one first")
        }
        guard closureTimers.repeating.count < ScriptClosureTimerRegistry.maxPerWorld else {
            return .error("too many repeating every() callbacks in this world (limit \(ScriptClosureTimerRegistry.maxPerWorld))")
        }
        let id = closureTimers.allocateID()
        closureTimers.repeating.append(ScriptRepeatingClosureTimer(
            id: id, owner: owner, scriptName: scriptName, function: function,
            interval: Int64(interval), wakeTick: scheduledTick(after: Int64(interval))
        ))
        return .values([.int(Int64(id))])
    }

    /// `cancel(id)`: stops one of the calling script's own `after`/`every` closures and closes a
    /// firing of it that is suspended in `wait`/`ai.await`. A callback that cancels its own timer
    /// finishes its current run. Returns whether anything was stopped.
    func hostCancel(_ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("cancel() outside script context") }
        guard !unloadActive else { return .error("timers are not available during unload") }
        guard !ephemeralRunActive else { return .error("timers are not available during ephemeral run") }
        guard call.arguments.count == 1, let raw = intArg(call.arguments[0]) else {
            return .error("cancel(id) requires the id returned by after() or every()")
        }
        guard !dryRunActive, raw > 0 else { return .values([.bool(false)]) }
        let id = UInt64(raw)
        let before = closureTimers.repeating.count
        closureTimers.repeating.removeAll { $0.id == id && $0.owner == ctx.owner && $0.scriptName == ctx.name }
        let keys: Set<String> = [
            afterClosureRunKey(owner: ctx.owner, scriptName: ctx.name, id: id),
            repeatingClosureRunKey(owner: ctx.owner, scriptName: ctx.name, id: id),
        ]
        let closed = closeScheduledRuns { keys.contains($0.key) }
        return .values([.bool(closureTimers.repeating.count != before || closed > 0)])
    }

    /// Drops every repeating closure the script registered (unload, detach, edit, fault).
    func dropRepeatingClosures(owner: ObjectRef, scriptName: String) {
        closureTimers.repeating.removeAll { $0.owner == owner && $0.scriptName == scriptName }
    }

    /// Fires due repeating closures in ascending (wakeTick, id) order inside the resumption lane.
    /// A timer whose script is still loading waits; one that cannot get an instruction slice keeps
    /// its wake tick and retries next phase.
    func runDueRepeatingClosures(tick: Int64) {
        guard !closureTimers.repeating.isEmpty else { return }
        let due = closureTimers.repeating.filter { $0.wakeTick <= tick }
            .sorted { $0.wakeTick == $1.wakeTick ? $0.id < $1.id : $0.wakeTick < $1.wakeTick }
        guard !due.isEmpty else { return }
        let suspendedKeys = Set(scheduled.map(\.key))
        for timer in due {
            guard let index = closureTimers.repeating.firstIndex(where: { $0.id == timer.id }) else { continue }
            let scriptKey = timer.owner.canonical + "#" + timer.scriptName
            guard let instance = instances[scriptKey], case .live = graph.resolve(timer.owner) else {
                closureTimers.repeating.remove(at: index)
                continue
            }
            // An edited/disabled definition is retired by reconciliation; a loading one goes live soon.
            guard instance.live, definitionIsCurrent(instance) else { continue }
            let key = repeatingClosureRunKey(owner: timer.owner, scriptName: timer.scriptName, id: timer.id)
            if suspendedKeys.contains(key) {
                closureTimers.repeating[index].wakeTick = scheduledTick(after: timer.interval)
                continue
            }
            guard nextInstructionSlice > 0 else { break }
            let result = runNew(
                key: key, function: timer.function, args: [], isLoad: false,
                contextOverride: (timer.owner, timer.scriptName)
            )
            if case .deferred = result { break }
            // The callback may have cancelled itself, and a fault drops the script's timers.
            guard let current = closureTimers.repeating.firstIndex(where: { $0.id == timer.id }) else { continue }
            if case .faulted = result {
                closureTimers.repeating.remove(at: current)
            } else {
                closureTimers.repeating[current].wakeTick = scheduledTick(after: timer.interval)
            }
        }
    }

    /// Removes and closes matching suspended runs, cancelling any AI request they await.
    @discardableResult
    func closeScheduledRuns(where shouldClose: (ScheduledRun) -> Bool) -> Int {
        let removed = removeScheduledRuns(where: shouldClose)
        for run in removed {
            try? lua.close(run.coroutine)
            if let token = run.awaitToken { cancelAIRequest(token) }
        }
        return removed.count
    }
}
