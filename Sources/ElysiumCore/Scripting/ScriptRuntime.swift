// ScriptRuntime.swift — script-runtime (change 1c). design.md §8.2/§7.5. Owns
// the one `LuaState` per open world session, the lifecycle of every attached
// script (pending -> live -> unload), the coroutine scheduler (resumptions,
// preemption, `wait`, `ai.await`), the named-durable-timer registry, and the
// event dispatcher plugged into `EventBus.delivery` (1b's seam). The Lua API
// v1 host-binding tree and handle metamethod bodies live in
// `ScriptRuntimeAPI.swift` — this file is lifecycle/scheduling only.
//
// Invariant (design.md §15): zero cost with no scripts. `GameScriptingState
// .anyScriptsAttached` is the single boolean every phase step checks before
// doing anything else; `ScriptStore.attach`/`.detach` keep it current via
// `GameCore+Scripting.swift`'s wrappers.

import ElysiumScript
import Foundation

/// design.md §12: the kill switch is a `doScripts` gamerule (default
/// enabled; absent == enabled, matching every other implicit-default
/// gamerule read in this package) layered on top of the persisted trust gate
/// (`WorldRecord.scriptsEnabled`, already enforced by `ObjectGraphHost
/// .scriptsEnabled` since change 1a). Scripts never run when either is off.
public func scriptsEffectivelyEnabled(host: ObjectGraphHost) -> Bool {
    guard host.scriptsEnabled else { return false }
    guard let w = host.world(for: host.currentDimension) else { return false }
    return (w.gameRules["doScripts"] ?? 1) != 0
}

/// `ScriptRuntime.runEphemeral`'s result (a plain enum rather than `Result`
/// — the failure case is a display string, which does not conform to
/// `Error`, and wrapping it just to satisfy `Result` would add nothing).
public enum ScriptRunOutcome {
    case success(String)
    case failure(String)
}

/// scripting-ui-and-replication (change 3): an `ElysiumCore`-native mirror of
/// `ElysiumScript.ScriptValidation` (see `ScriptRuntime.validateSourceForEditor`'s own comment
/// on why a mirror, not a re-export). `stage` is 0-3, `line` is 1-based (0 when the stage has
/// no single-line locus) — exactly `ScriptValidation.refused`'s own documented shape.
/// scripting-ui-and-replication (change 3), design.md §12: "F3 summary". `faultsThisTick`/
/// `eventsPendingThisTick` are read fresh from `EventBus` by the HUD (they are that type's own
/// state, not duplicated here) — this struct carries only what `ScriptRuntime` itself owns.
public struct ScriptRuntimeSummary: Equatable {
    public let liveScripts: Int
    public let suspendedCoroutines: Int
    public let durableTimers: Int
}

public struct ScriptValidationResult: Equatable {
    public enum Outcome: Equatable {
        case accepted
        case refused(stage: Int, message: String, hint: String, line: Int)
    }

    public let outcome: Outcome

    public init(outcome: Outcome) {
        self.outcome = outcome
    }
}

/// The opaque payload carried by a `ScriptOwnedSubscription.token` (event-bus,
/// change 1b reserved the field; this change is the only thing that ever
/// constructs one).
final class ScriptHandlerToken {
    enum Body {
        /// Handler mode: the trigger's own chunk is the handler — resume the
        /// named script instance directly with `ev`.
        case handlerChunk(ref: ObjectRef, name: String)
        /// Module mode: a closure a script passed to `on`/`subscribe` at load.
        case closure(ScriptFunction, owner: ObjectRef, scriptName: String)
    }
    let body: Body
    init(_ body: Body) { self.body = body }
}

public final class ScriptRuntime {
    let lua: LuaState
    let host: ObjectGraphHost
    let state: GameScriptingState
    let sayFn: (String) -> Void
    /// Test/production seam for `ai.ask`/`ai.await` (design.md §9.6: "tests
    /// inject a stub broker"; the real Ollama pump is change 2). `nil`
    /// (production default until change 2) means every request times out.
    var aiResponder: (String) -> String?

    // Implicitly-unwrapped: Swift auto-initializes an Optional-shaped stored
    // property to `nil` without needing an `init` assignment, which is what
    // lets `self` become usable (to build `[weak self]` dispatch closures)
    // *before* these two are actually registered a few lines into `init` —
    // `registerHandleKind` needs the closures, and the closures need `self`
    // fully constructed, so this breaks that ordering cycle. Both are always
    // non-nil by the time any script runs (set at the end of `init`, never
    // reassigned after).
    private(set) var objectHandleKind: HandleKind!
    private(set) var attrsHandleKind: HandleKind!

    /// The script currently executing, for provenance (`AttributeStore
    /// .set(by:)`, `ScriptStore.attach(by:)`) and verb-budget accounting.
    /// Set/restored around every `resume`/`call` into a script's code —
    /// never stacked (scripts never synchronously re-enter the runtime from
    /// inside another script's call, §7.6's cascades are queued, not
    /// nested).
    private(set) var currentScript: (owner: ObjectRef, name: String)?

    struct Instance {
        var ref: ObjectRef
        var name: String
        var mode: ScriptMode
        var environment: ScriptEnvironment
        var live: Bool = false
        /// The SAME reference-type adapter handed to `makeEnvironment` —
        /// `math.random`/`randomseed` mutate it in place inside
        /// `LuaState`'s own (inaccessible-to-us) bookkeeping, so this is the
        /// only way this runtime can read the *current* stream state back
        /// out for persistence (`storeRNGWords`, called after every phase).
        var randomAdapter: RandomStreamBoxAdapter
    }
    var instances: [String: Instance] = [:]

    struct ScheduledRun {
        var key: String
        var coroutine: ScriptCoroutine
        var wakeTick: Int64
        var ordinal: UInt64
        /// Set while suspended on `.await(token)`; `nil` for `.wait`/
        /// `.preempted` (those are woken by tick alone).
        var awaitToken: UInt64?
        var isLoad: Bool
    }
    var scheduled: [ScheduledRun] = []
    private var nextOrdinal: UInt64 = 0

    var timers: [DurableTimer] = []
    private var nextTimerId: UInt64 = 1

    /// `"<ownerRef>#<scriptName>#<handlerName>"` -> the function a module's
    /// load body registered with `register(name, fn)` (this change's
    /// adaptation for named-handler resolution — see ARCHITECTURE.md).
    /// Re-populated every load; never persisted (functions cannot survive a
    /// restart).
    var namedHandlers: [String: ScriptFunction] = [:]

    struct AIOutboxEntry { var id: UInt64; var prompt: String }
    private var aiOutbox: [AIOutboxEntry] = []
    private var nextAIRequestID: UInt64 = 1
    /// design.md §8.4: "<= 30 per world per minute" — approximated here as
    /// per-1200-ticks (20 Hz * 60 s), reset opportunistically.
    private var aiRequestsThisWindow = 0
    private var aiWindowStartTick: Int64 = 0
    /// design.md §8.4: "<= 2 in flight per world" — a local constant
    /// (not `ScriptBudgets`, matching this file's own `aiRequestsThisWindow`/
    /// `aiWindowStartTick` precedent for AI-specific numbers change 1c
    /// already kept out of that struct). This is also this subsystem's
    /// "per-tick pump budget": the broker handoff (`outboxHandoff`) only
    /// ever sees requests that already passed this gate, so it can never be
    /// asked to fire more than `aiMaxInFlightPerWorld` concurrent network
    /// requests for one world session.
    static let aiMaxInFlightPerWorld = 2
    private(set) var aiInFlightCount = 0

    /// ai-object-graph (change 2), design.md §9.6: the async production
    /// broker seam. `nil` (default, and every 1c test) means "no broker
    /// attached" — `runAIInbox()` falls back to the synchronous `aiResponder`
    /// stub seam unchanged, so every 1c test keeps passing untouched. When
    /// set (production only, wired by the app layer's per-frame pump), each
    /// newly enqueued `(requestID, prompt)` is handed off here instead of
    /// being answered synchronously; the real reply arrives later via
    /// `submitAIReply`, off the game loop's own call stack, and is drained
    /// into `ai.replied` events / `ai.await` resumptions at the next script
    /// phase — the tick never blocks on the model.
    public var outboxHandoff: ((UInt64, String) -> Void)?
    private var incomingAIReplies: [(id: UInt64, text: String?, error: String?)] = []

    /// ai-object-graph (change 2), design.md §9.4 stage 6: set for the
    /// duration of `dryRun` only. Every mutating verb dispatch
    /// (`ScriptRuntimeAPI.swift`) checks this first and turns itself into a
    /// harmless no-op while it is `true` — the "read-only facade" the design
    /// calls for, implemented as a flag rather than a second execution path
    /// so dry-run and real execution can never drift apart on anything but
    /// the flag itself.
    var dryRunActive = false

    let budgets: ScriptBudgets

    /// §8.4: "attach/detach <= 2 (world <= 32)" — this change enforces the
    /// per-script half (world-wide accounting is a documented gap, noted in
    /// ARCHITECTURE.md); reset every tick by `resetPerTickCounters()`.
    var attachDetachCounts: [String: Int] = [:]

    /// design.md §7.2: `"script.attached"` fits the custom event grammar
    /// (`[a-z][a-z0-9_]{0,31}` segments, 1-4 of them) — parsed once, not a
    /// v1 catalog constant (`EventKind.swift` is 1b's file).
    static let scriptAttachedEventKind = EventKind.parse("script.attached")!

    public init(
        host: ObjectGraphHost, state: GameScriptingState, budgets: ScriptBudgets = .defaults,
        say: @escaping (String) -> Void, aiResponder: @escaping (String) -> String? = { _ in nil }
    ) throws {
        self.host = host
        self.state = state
        self.budgets = budgets
        self.sayFn = say
        self.aiResponder = aiResponder
        self.lua = try LuaState(budgets: budgets, math: ScriptHostMath.deterministic, log: ScriptRuntimeLogSink())
        // `self` is fully constructed from here (every other stored property
        // has a value); the dispatch closures built in `ScriptRuntimeAPI.swift`
        // capture it weakly.
        self.objectHandleKind = lua.registerHandleKind(name: "object", dispatch: Self.makeObjectDispatch(self), interned: true)
        self.attrsHandleKind = lua.registerHandleKind(name: "attrs", dispatch: Self.makeAttrsDispatch(self), interned: true)
    }

    // MARK: - handle helpers (shared with ScriptRuntimeAPI.swift)

    /// Registers `ref` as a live handle (idempotent) and returns the marshal-
    /// ready value. `id` is unused by every dispatch closure in this runtime
    /// (they all re-derive identity from `HandleRef.ref`), so a constant is
    /// always correct (design.md Decision 10's `id` is an optimization this
    /// runtime does not need).
    func handleValue(for ref: ObjectRef) -> ScriptValue {
        _ = try? lua.makeHandle(kind: objectHandleKind, ref: ref.canonical, id: 0)
        return .ref(ref.canonical)
    }

    func attrsHandleValue(for ref: ObjectRef) -> ScriptValue {
        let synthetic = "attrs:" + ref.canonical
        _ = try? lua.makeHandle(kind: attrsHandleKind, ref: synthetic, id: 0)
        return .ref(synthetic)
    }

    func ownerRef(fromAttrsRef s: String) -> ObjectRef? {
        guard s.hasPrefix("attrs:") else { return nil }
        return ObjectRef.parse(String(s.dropFirst(6)))
    }

    var graph: ObjectGraph { ObjectGraph(host: host) }
    var attributeStore: AttributeStore {
        AttributeStore(graph: graph, onChange: { [weak self] ref, name, old, new, revision, author in
            self?.raiseAttributeChanged(ref: ref, name: name, old: old, new: new, revision: revision, author: author)
        })
    }
    var scriptStore: ScriptStore { ScriptStore(graph: graph) }

    private func raiseAttributeChanged(
        ref: ObjectRef, name: String, old: AttrValue?, new: AttrValue?, revision: UInt64, author: Provenance.Author
    ) {
        let source: EventSource
        switch author {
        case .player: source = .player
        case .ai(let model): source = .ai(model: model)
        case .script(let owner, let scriptName): source = .script(owner: owner, name: scriptName)
        case .lan(let peer): source = .lan(peerID: peer)
        }
        state.eventBus.raise(
            kind: .attributeChanged, subject: ref,
            payload: ["key": .string(name), "old": old ?? .null, "new": new ?? .null],
            source: source, tick: host.currentTick
        )
    }

    // MARK: - per-tick verb budget reset

    public func resetPerTickCounters() {
        attachDetachCounts.removeAll()
    }

    // MARK: - scheduler helpers (shared with ScriptRuntimeAPI.swift)

    func scheduleOrdinal() -> UInt64 {
        defer { nextOrdinal += 1 }
        return nextOrdinal
    }

    func allocateTimerID() -> UInt64 {
        defer { nextTimerId += 1 }
        return nextTimerId
    }

    func appendScheduled(key: String, coroutine: ScriptCoroutine, wakeTick: Int64) {
        scheduled.append(ScheduledRun(
            key: key, coroutine: coroutine, wakeTick: wakeTick, ordinal: scheduleOrdinal(), awaitToken: nil, isLoad: false
        ))
    }

    // MARK: - dispatcher (plugged into `EventBus.delivery` by `GameCore
    // +Scripting.swift`)

    public func deliver(_ event: ScriptEvent, _ targets: [EventDeliveryTarget]) {
        guard scriptsEffectivelyEnabled(host: host) else { return }
        for target in targets {
            switch target.kind {
            case .persisted(let sub):
                invokeNamed(owner: sub.subscriber, scriptName: sub.scriptName, handlerName: sub.handler, event: event)
            case .scriptOwned(let sub):
                guard let token = sub.token as? ScriptHandlerToken else { continue }
                switch token.body {
                case .handlerChunk(let ref, let name):
                    invokeHandlerChunk(ref: ref, name: name, event: event)
                case .closure(let fn, let owner, let scriptName):
                    invokeClosure(fn, owner: owner, scriptName: scriptName, event: event)
                }
            }
        }
    }

    private func invokeNamed(owner: ObjectRef, scriptName: String, handlerName: String, event: ScriptEvent) {
        let key = owner.canonical + "#" + scriptName + "#" + handlerName
        guard let fn = namedHandlers[key] else { return } // pruned silently (§7.3: dormant, not fatal)
        invokeClosure(fn, owner: owner, scriptName: scriptName, event: event)
    }

    private func invokeHandlerChunk(ref: ObjectRef, name: String, event: ScriptEvent) {
        let key = ref.canonical + "#" + name
        guard var instance = instances[key], instance.live, instance.mode == .handler else { return }
        guard case .live = graph.resolve(ref) else { return }
        guard let compiled = compileForRun(instance: &instance) else { instances[key] = instance; return }
        instances[key] = instance
        runNew(
            key: key, function: compiled, args: [handleValue(for: ref), handleValue(for: .world), handleValue(for: .player), eventValue(event)],
            isLoad: false
        )
    }

    private func invokeClosure(_ fn: ScriptFunction, owner: ObjectRef, scriptName: String, event: ScriptEvent) {
        guard case .live = graph.resolve(owner) else { return }
        let key = owner.canonical + "#" + scriptName + "#closure#" + String(nextOrdinal)
        runNew(key: key, function: fn, args: [eventValue(event)], isLoad: false, contextOverride: (owner, scriptName))
    }

    /// Re-compiles a handler-mode chunk fresh for each firing (its whole
    /// body IS the handler, so there is no persistent closure to reuse —
    /// matches the "chunk runs" framing of §8.1 exactly, at the cost of a
    /// recompile per delivery; acceptable at v1 scale, notable in
    /// ARCHITECTURE.md as a place to optimize later with a cached
    /// `ScriptFunction`).
    private func compileForRun(instance: inout Instance) -> ScriptFunction? {
        guard let record = scriptStore.get(instance.ref, instance.name) else { return nil }
        let wrapped = "local self, world, player, ev = ...\n" + record.source
        switch instance.environment.compile(source: wrapped, chunkName: instance.name) {
        case .success(let fn): return fn
        case .failure(let fault):
            scriptStore.storeLastError(instance.ref, instance.name, fault.message)
            return nil
        }
    }

    func eventValue(_ event: ScriptEvent) -> ScriptValue {
        var map: [String: ScriptValue] = [
            "kind": .string(event.kind.rawValue),
            "tick": .int(event.tick),
            "subject": handleValue(for: event.subject),
        ]
        for (k, v) in event.payload { map[k] = v }
        if case .script(let owner, _) = event.source { map["source"] = .string("script:" + owner.canonical) }
        else if case .player = event.source { map["source"] = .string("player") }
        else if case .ai = event.source { map["source"] = .string("ai") }
        else if case .lan = event.source { map["source"] = .string("lan") }
        else { map["source"] = .string("engine") }
        return .map(map)
    }

    // MARK: - running a fresh coroutine (load, handler, timer, closure)

    @discardableResult
    func runNew(
        key: String, function: ScriptFunction, args: [ScriptValue], isLoad: Bool,
        contextOverride: (owner: ObjectRef, name: String)? = nil
    ) -> Bool {
        guard let coroutine = try? lua.makeCoroutine(function: function) else { return false }
        return resumeAndSchedule(key: key, coroutine: coroutine, args: args, isLoad: isLoad, context: contextOverride)
    }

    private func resumeAndSchedule(
        key: String, coroutine: ScriptCoroutine, args: [ScriptValue], isLoad: Bool,
        context: (owner: ObjectRef, name: String)?
    ) -> Bool {
        let previous = currentScript
        currentScript = context ?? parseKey(key)
        defer { currentScript = previous }
        let outcome: ScriptResumeOutcome
        do {
            outcome = try lua.resume(coroutine, args: args, slice: budgets.handlerSliceInstructions)
        } catch {
            return false
        }
        switch outcome {
        case .completed:
            return true
        case .yielded(let reason):
            let wakeTick: Int64
            var awaitToken: UInt64?
            switch reason {
            case .preempted: wakeTick = host.currentTick + 1
            case .wait(let n): wakeTick = host.currentTick + Int64(max(0, n))
            case .await(let token): wakeTick = host.currentTick; awaitToken = token
            }
            scheduled.append(ScheduledRun(
                key: key, coroutine: coroutine, wakeTick: wakeTick, ordinal: nextOrdinal, awaitToken: awaitToken,
                isLoad: isLoad
            ))
            nextOrdinal += 1
            return false
        case .faulted(let fault):
            if let ctx = currentScript {
                scriptStore.storeLastError(ctx.owner, ctx.name, fault.message)
                state.eventBus.raise(
                    kind: .scriptFaulted, subject: ctx.owner,
                    payload: ["name": .string(ctx.name), "message": .string(fault.message)],
                    source: .engine, tick: host.currentTick
                )
            }
            return false
        }
    }

    private func parseKey(_ key: String) -> (owner: ObjectRef, name: String)? {
        let parts = key.split(separator: "#", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2, let ref = ObjectRef.parse(String(parts[0])) else { return nil }
        return (ref, String(parts[1]))
    }

    // MARK: - phase steps (called from `GameCore+Scripting.runScriptPhase`)

    /// §7.5 step 1: compile+run every pending script (newly attached, or
    /// edited since it last went live). Sorted by ref then name for
    /// determinism.
    public func runLoads() {
        guard scriptsEffectivelyEnabled(host: host) else { return }
        // §15's zero-cost invariant, amortized: `state.anyScriptsAttached`
        // is the fast path (one boolean) for the overwhelming majority of
        // ticks; every 20th tick (~1s at 20 Hz) this also runs when the flag
        // is still `false`, so scripts already on disk for a chunk/entity
        // that has not yet triggered the flag through any other path
        // (world/dim bag at open, or `h:attach` at runtime) are discovered
        // within about a second of load rather than never — a scan that
        // finds nothing changes no game state and cannot affect determinism.
        guard state.anyScriptsAttached || host.currentTick % 20 == 0 else { return }
        var pending: [(ObjectRef, ScriptRecord)] = []
        forEachScriptedObject { ref, record in
            let key = ref.canonical + "#" + record.name
            if let existing = instances[key], existing.live, sourceUnchanged(existing, record) { return }
            pending.append((ref, record))
        }
        pending.sort { a, b in a.0.canonical == b.0.canonical ? a.1.name < b.1.name : a.0.canonical < b.0.canonical }
        for (ref, record) in pending {
            guard record.enabled else { continue }
            load(ref: ref, record: record)
        }
    }

    private func sourceUnchanged(_ instance: Instance, _ record: ScriptRecord) -> Bool {
        // We do not cache the source on `Instance`; a live instance is only
        // ever re-queued for reload by `ScriptStore.attach` clearing its
        // `live` flag via `markEdited`, so simply trusting `live` here is
        // correct and avoids keeping a second copy of the source text.
        true
    }

    private func load(ref: ObjectRef, record: ScriptRecord) {
        let key = ref.canonical + "#" + record.name
        let seed = record.rngWords.map { RandomX(stateWords: ($0[0], $0[1], $0[2], $0[3])) }
            ?? RandomX(mix32(UInt32(truncatingIfNeeded: (ref.canonical + record.name).hashValue))
                ^ UInt32(truncatingIfNeeded: record.createdTick))
        let adapter = RandomStreamBoxAdapter(seed)
        let env = lua.makeEnvironment(name: key, hostBindings: buildHostBindings(), random: adapter)
        var instance = Instance(ref: ref, name: record.name, mode: record.mode, environment: env, randomAdapter: adapter)
        instances[key] = instance
        let wrapped = record.mode == .module
            ? "local self, world, player = ...\n" + record.source
            : "local self, world, player, ev = ...\n" + record.source
        switch env.compile(source: wrapped, chunkName: record.name) {
        case .failure(let fault):
            scriptStore.storeLastError(ref, record.name, fault.message)
            state.eventBus.raise(
                kind: .scriptFaulted, subject: ref,
                payload: ["name": .string(record.name), "message": .string(fault.message)],
                source: .engine, tick: host.currentTick
            )
            instances.removeValue(forKey: key)
            return
        case .success(let compiled):
            if record.mode == .handler {
                // §8.1: "handler-mode bodies run with ev bound" — only when
                // an actual matching event arrives (`invokeHandlerChunk`
                // recompiles and runs it fresh per delivery). Unlike module
                // mode, "load" for a handler-mode script is compile-and-index
                // only: this compile already proved the source is valid;
                // running it now (against a synthetic empty `ev`) would only
                // ever fault on `ev.subject`/`ev.<payload field>` being nil.
                instance.live = true
                instances[key] = instance
                scriptStore.storeLastError(ref, record.name, nil)
                for trigger in record.triggers {
                    let token = ScriptHandlerToken(.handlerChunk(ref: ref, name: record.name))
                    state.eventBus.registerScriptOwned(
                        owner: ref, scriptName: record.name, target: trigger.target, event: trigger.event,
                        attribute: trigger.attribute, token: token
                    )
                }
                state.eventBus.raise(kind: .load, subject: ref, payload: ["name": .string(record.name)], source: .engine, tick: host.currentTick)
                return
            }
            let args: [ScriptValue] = [handleValue(for: ref), handleValue(for: .world), handleValue(for: .player)]
            let completed = runNew(key: key, function: compiled, args: args, isLoad: true)
            instance = instances[key] ?? instance
            if completed {
                instance.live = true
                instances[key] = instance
                scriptStore.storeLastError(ref, record.name, nil)
                state.eventBus.raise(kind: .load, subject: ref, payload: ["name": .string(record.name)], source: .engine, tick: host.currentTick)
            }
            // If not completed (yielded/faulted), the instance stays
            // non-live; a yielded load is already tracked in `scheduled`
            // and will be resumed in `runResumptions()`.
        }
    }

    /// §7.5 step 4: resumptions (preempted/`wait` wakeups, `.await` replies)
    /// in ascending `(wakeTick, ordinal)`, then durable timers due this tick
    /// in ascending `(wakeTick, timerId)`.
    public func runResumptions() {
        guard scriptsEffectivelyEnabled(host: host) else { return }
        let tick = host.currentTick
        let runnable = scheduled.filter { $0.awaitToken == nil && $0.wakeTick <= tick }
            .sorted { $0.wakeTick == $1.wakeTick ? $0.ordinal < $1.ordinal : $0.wakeTick < $1.wakeTick }
        for run in runnable {
            scheduled.removeAll { $0.key == run.key && $0.ordinal == run.ordinal }
            let completed = resumeAndSchedule(key: run.key, coroutine: run.coroutine, args: [], isLoad: run.isLoad, context: nil)
            if completed, run.isLoad, var instance = instances[run.key] {
                instance.live = true
                instances[run.key] = instance
                if let (ref, name) = parseKey(run.key) {
                    scriptStore.storeLastError(ref, name, nil)
                    state.eventBus.raise(kind: .load, subject: ref, payload: ["name": .string(name)], source: .engine, tick: tick)
                }
            }
        }
        runDueTimers(tick: tick)
    }

    private func runDueTimers(tick: Int64) {
        guard !timers.isEmpty else { return }
        let due = timers.filter { $0.wakeTick <= tick }.sorted { $0.wakeTick == $1.wakeTick ? $0.id < $1.id : $0.wakeTick < $1.wakeTick }
        for timer in due {
            let handlerKey = timer.owner.canonical + "#" + timer.scriptName + "#" + timer.handlerName
            if case .live = graph.resolve(timer.owner), let fn = namedHandlers[handlerKey] {
                let key = timer.owner.canonical + "#" + timer.scriptName + "#timer#\(timer.id)#\(tick)"
                runNew(
                    key: key, function: fn, args: [.map(["kind": .string("timer.fired"), "name": .string(timer.handlerName)])],
                    isLoad: false, contextOverride: (timer.owner, timer.scriptName)
                )
                state.eventBus.raise(
                    kind: .timerFired, subject: timer.owner, payload: ["name": .string(timer.handlerName)],
                    source: .engine, tick: tick
                )
            }
            if let interval = timer.intervalTicks {
                if let idx = timers.firstIndex(where: { $0.id == timer.id }) {
                    timers[idx].wakeTick = tick + interval
                }
            } else {
                timers.removeAll { $0.id == timer.id }
            }
        }
    }

    // MARK: - AI outbox/inbox (design.md §9.6, this change's stub-broker seam)

    /// design.md §8.4's two AI request budgets, checked together before a
    /// request is ever enqueued: the in-flight cap (never queued past it —
    /// refused immediately) and the per-world-per-minute window (reset
    /// opportunistically every ~1200 ticks).
    func aiBudgetAvailable() -> Bool {
        let tick = host.currentTick
        if tick - aiWindowStartTick >= 1_200 {
            aiWindowStartTick = tick
            aiRequestsThisWindow = 0
        }
        return aiInFlightCount < Self.aiMaxInFlightPerWorld && aiRequestsThisWindow < 30
    }

    func enqueueAIRequest(prompt: String) -> UInt64 {
        let id = nextAIRequestID
        nextAIRequestID += 1
        aiOutbox.append(AIOutboxEntry(id: id, prompt: prompt))
        aiInFlightCount += 1
        aiRequestsThisWindow += 1
        return id
    }

    /// §7.5 step 3 ("AI inbox"). Two modes, chosen by whether a production
    /// broker is attached (`outboxHandoff != nil`):
    ///   - **No broker** (default; every 1c test): drains the outbox
    ///     synchronously against the injected `aiResponder` stub, exactly as
    ///     1c shipped it — unchanged behavior, unchanged tests.
    ///   - **Broker attached** (production, change 2, §9.6): hands each
    ///     freshly enqueued `(id, prompt)` to the broker (which dispatches
    ///     an async, cancellable Ollama request off the tick's call stack)
    ///     instead of answering it here, then drains whatever real replies
    ///     `submitAIReply` has queued up since the last phase — in
    ///     `requestId` order, per §9.6's own wording.
    public func runAIInbox() {
        if let handoff = outboxHandoff {
            if !aiOutbox.isEmpty {
                let batch = aiOutbox
                aiOutbox.removeAll()
                for entry in batch { handoff(entry.id, entry.prompt) }
            }
            guard !incomingAIReplies.isEmpty else { return }
            let replies = incomingAIReplies.sorted { $0.id < $1.id }
            incomingAIReplies.removeAll()
            for reply in replies { deliverAIReply(id: reply.id, text: reply.text, errorText: reply.error) }
            return
        }
        guard !aiOutbox.isEmpty else { return }
        let batch = aiOutbox
        aiOutbox.removeAll()
        for entry in batch {
            let reply = aiResponder(entry.prompt)
            deliverAIReply(id: entry.id, text: reply, errorText: reply == nil ? "timeout" : nil)
        }
    }

    private func deliverAIReply(id: UInt64, text: String?, errorText: String?) {
        aiInFlightCount = max(0, aiInFlightCount - 1)
        let waiting = scheduled.filter { $0.awaitToken == id }
        if waiting.isEmpty {
            // `ai.ask` path: deliver as an event to the requester. The
            // requester ref/script name is not tracked in the outbox in
            // this change (ask is fire-and-forget to `world`, matching
            // the "requesting object" wording loosely) — a documented
            // simplification; `ai.await` is the fully-wired path.
            state.eventBus.raise(
                kind: .aiReplied, subject: .world,
                payload: ["requestId": .int(Int64(id)), "text": text.map { .string($0) } ?? .null,
                          "error": errorText.map { .string($0) } ?? .null],
                source: .engine, tick: host.currentTick
            )
        } else {
            for run in waiting {
                scheduled.removeAll { $0.key == run.key && $0.ordinal == run.ordinal }
                let args: [ScriptValue] = text != nil
                    ? [.string(text!), .null] : [.null, .string(errorText ?? "timeout")]
                _ = resumeAndSchedule(key: run.key, coroutine: run.coroutine, args: args, isLoad: false, context: nil)
            }
        }
    }

    /// ai-object-graph (change 2): the broker calls this — from any thread
    /// that ultimately serializes onto the main/game-loop thread before this
    /// call (the app layer's network completion handlers already dispatch
    /// back to main, matching every other network callback in this codebase)
    /// — once a real reply (or a definitive failure) for `id` is known.
    /// Queued, not applied immediately: delivery only ever happens inside
    /// `runAIInbox`, at the fixed script-phase point, so a reply that lands
    /// mid-tick from the app's per-frame pump still only ever mutates
    /// scripting state at the one deterministic phase this whole subsystem
    /// promises.
    public func submitAIReply(id: UInt64, text: String?, error: String?) {
        incomingAIReplies.append((id, text, error))
    }

    // MARK: - unload (§7.5 step 6, §8.2)

    /// Runs `on("unload")`-registered closures (if any were captured via
    /// `register`) against an attrs-only facade and drops the compiled
    /// environment for every `(ref,name)` in `refs`. Called from
    /// `GameCore+Scripting.handleScriptedChunkUnload` (chunk unload) and
    /// `exitToTitle` (whole-session shutdown).
    func unloadScripts(for refs: [ObjectRef]) {
        guard !instances.isEmpty else { return }
        let refSet = Set(refs.map(\.canonical))
        let keys = instances.keys.filter { key in
            guard let parsed = parseKey(key) else { return false }
            return refSet.contains(parsed.owner.canonical)
        }
        for key in keys.sorted() {
            guard let instance = instances[key] else { continue }
            if let unloadFn = namedHandlers[key + "#unload"] {
                _ = runNew(key: key + "#unload", function: unloadFn, args: [], isLoad: false)
            }
            instance.environment.destroy()
            instances.removeValue(forKey: key)
            scheduled.removeAll { $0.key.hasPrefix(key) }
            namedHandlers = namedHandlers.filter { !$0.key.hasPrefix(key + "#") }
        }
    }

    /// Whole-session teardown (`exitToTitle`): unload every live instance,
    /// synchronously, before the world record is captured for save.
    func unloadAllForShutdown() {
        let refs = Array(Set(instances.values.map(\.ref)))
        unloadScripts(for: refs)
    }

    /// §8.6: persists every live instance's current RNG stream words. Called
    /// once at the end of the script phase (cheap: a handful of live
    /// instances at most, guarded by the same zero-scripts fast path).
    public func persistRNGState() {
        guard !instances.isEmpty else { return }
        for instance in instances.values where instance.live {
            let words = instance.randomAdapter.inner.stateWords
            scriptStore.storeRNGWords(instance.ref, instance.name, [words.0, words.1, words.2, words.3])
        }
    }

    // MARK: - ephemeral run (§9.3 `run_script` / `/script run`)

    /// Runs `source` once, immediately, against `owner` — never persisted,
    /// never subscribed, never timed, never yieldable (`lua.call` is the
    /// synchronous, non-yieldable form; an attempted `wait`/`ai.await`
    /// becomes `.invalidYield`, matching §9.3's "capability-reduced: no
    /// subscribe, no timers, no `ai.*`"). This change's documented
    /// simplification of "runs once in the next phase" (§9.3) — see
    /// ARCHITECTURE.md.
    public func runEphemeral(source: String, owner: ObjectRef) -> ScriptRunOutcome {
        guard scriptsEffectivelyEnabled(host: host) else { return .failure("scripting is disabled") }
        guard case .live = graph.resolve(owner) else { return .failure("\(owner.canonical) is not loaded") }
        if case .refused(let stage, let message, _, let line) = ScriptValidator.validate(
            source: source, chunkName: "run", using: lua
        ) {
            return .failure("validation stage \(stage) line \(line): \(message)")
        }
        let env = lua.makeEnvironment(
            name: "run#\(nextOrdinal)", hostBindings: buildHostBindings(),
            random: RandomStreamBoxAdapter(RandomX(mix32(UInt32(truncatingIfNeeded: nextOrdinal))))
        )
        nextOrdinal += 1
        defer { env.destroy() }
        let wrapped = "local self, world, player = ...\n" + source
        switch env.compile(source: wrapped, chunkName: "run") {
        case .failure(let fault):
            return .failure("compile error: \(fault.message)")
        case .success(let fn):
            let previous = currentScript
            currentScript = (owner, "run")
            defer { currentScript = previous }
            let outcome: ScriptCallOutcome
            do {
                outcome = try lua.call(
                    fn, args: [handleValue(for: owner), handleValue(for: .world), handleValue(for: .player)],
                    slice: budgets.handlerSliceInstructions
                )
            } catch {
                return .failure("call failed")
            }
            switch outcome {
            case .success: return .success("ran '\(owner.canonical)' script (ephemeral, not saved)")
            case .failure(let fault): return .failure("runtime error: \(fault.message)")
            }
        }
    }

    // MARK: - validation / dry-run (ai-object-graph, change 2, design.md §9.4)

    /// Stages 0-3 of `ScriptValidator` against this session's `LuaState` —
    /// the same compile-time gate `h:attach`/`/script attach`/`runEphemeral`
    /// already use, exposed for the AI tool loop's `check_script` query tool
    /// and as the first half of `AIScriptValidationGate.validate` (which
    /// adds stage 5 on top). `lua` itself stays un-exposed; this is the one
    /// operation callers outside this file need from it.
    /// scripting-ui-and-replication (change 3), design.md §12: the F3 debug-summary line's own
    /// data source. Cheap (a count over the already-in-memory `instances`/`scheduled`/`timers`
    /// collections, no scan) — safe to read every frame the overlay is on, matching §15's
    /// zero-cost invariant (a world with no scripts has empty collections here, so this is
    /// effectively free even when F3 is showing).
    public var summary: ScriptRuntimeSummary {
        ScriptRuntimeSummary(
            liveScripts: instances.values.filter(\.live).count,
            suspendedCoroutines: scheduled.count,
            durableTimers: timers.count
        )
    }

    public func validateSource(_ source: String, chunkName: String) -> ScriptValidation {
        ScriptValidator.validate(source: source, chunkName: chunkName, using: lua)
    }

    /// scripting-ui-and-replication (change 3): the app target (`Sources/Elysium`, the full
    /// `ScriptEditorScreen`) does not depend on `ElysiumScript` (design.md §4's own module
    /// diagram — only `ElysiumCore` is allowed to see it), so it cannot spell `ScriptValidation`
    /// by name. This is the anticorruption translation at that seam — the same pattern
    /// `ScriptingDisplayText.isValidScriptSource` already established for
    /// `ScriptTextHygiene.isClean` — re-expressed as an `ElysiumCore`-native type the editor can
    /// use directly for its error-line highlight.
    public func validateSourceForEditor(_ source: String, chunkName: String) -> ScriptValidationResult {
        switch validateSource(source, chunkName: chunkName) {
        case .accepted:
            return ScriptValidationResult(outcome: .accepted)
        case .refused(let stage, let message, let hint, let line):
            return ScriptValidationResult(outcome: .refused(stage: stage, message: message, hint: hint, line: line))
        }
    }

    /// design.md §9.4 stage 6: "run the chunk in a scratch env over a
    /// read-only facade (throwaway RNG, no AI, no attrs writes) and invoke
    /// each registered handler once with a synthetic event; failures are
    /// *warnings* in the tool result." Compiles and runs `source` once
    /// against `owner`'s real handles (so reads/attribute lookups behave
    /// normally — useful signal) with `dryRunActive` set for the duration,
    /// which turns every mutating verb in `ScriptRuntimeAPI.swift` into a
    /// no-op: nothing this call does is ever persisted, emits an event,
    /// writes a block, sends chat, or reaches the AI outbox. Returns a
    /// human-readable failure line, or `nil` on success. Never throws; any
    /// internal failure (including an over-budget slice) becomes a message,
    /// not a Swift error — the caller treats this as advisory.
    public func dryRun(source: String, owner: ObjectRef, mode: ScriptMode) -> String? {
        guard scriptsEffectivelyEnabled(host: host) else { return "scripting is disabled" }
        guard case .live = graph.resolve(owner) else { return "\(owner.canonical) is not loaded" }
        let wasDryRun = dryRunActive
        dryRunActive = true
        defer { dryRunActive = wasDryRun }
        let env = lua.makeEnvironment(
            name: "dryrun#\(nextOrdinal)", hostBindings: buildHostBindings(),
            random: RandomStreamBoxAdapter(RandomX(0xD8A1_1D8A))
        )
        nextOrdinal += 1
        defer { env.destroy() }
        let wrapped = mode == .module
            ? "local self, world, player = ...\n" + source
            : "local self, world, player, ev = ...\n" + source
        switch env.compile(source: wrapped, chunkName: "dryrun") {
        case .failure(let fault):
            return fault.message
        case .success(let fn):
            let previous = currentScript
            currentScript = (owner, "dryrun")
            defer { currentScript = previous }
            let args: [ScriptValue] = mode == .module
                ? [handleValue(for: owner), handleValue(for: .world), handleValue(for: .player)]
                : [
                    handleValue(for: owner), handleValue(for: .world), handleValue(for: .player),
                    .map(["kind": .string("dryrun"), "tick": .int(host.currentTick), "subject": handleValue(for: owner)]),
                ]
            do {
                let outcome = try lua.call(fn, args: args, slice: budgets.handlerSliceInstructions)
                if case .failure(let fault) = outcome { return fault.message }
                return nil
            } catch {
                return "dry run failed to execute"
            }
        }
    }

    // MARK: - discovery (bounded scan, only when `state.anyScriptsAttached`)

    private func forEachScriptedObject(_ body: (ObjectRef, ScriptRecord) -> Void) {
        for ref in [ObjectRef.world, .dimension(.overworld), .dimension(.nether), .dimension(.end)] {
            for record in scriptStore.list(ref) { body(ref, record) }
        }
        guard let w = host.world(for: host.currentDimension) else { return }
        for e in w.entities {
            guard let ent = e as? Entity, !ent.dead else { continue }
            let ref = scriptRef(for: ent)
            for record in scriptStore.list(ref) { body(ref, record) }
        }
        for chunk in w.chunks.values where !chunk.objectRecords.isEmpty {
            for cellIndex in chunk.objectRecords.keys.sorted() {
                let (x, y, z) = chunk.idxToWorld(cellIndex)
                let ref = ObjectRef.block(dim: w.dim, x: x, y: y, z: z)
                for record in scriptStore.list(ref) { body(ref, record) }
            }
        }
    }
}


/// `ScriptLogSink` -> stdout, capped and hygiene-filtered upstream already
/// (design.md Condition 33) — no further processing needed; `/script log`
/// is out of scope for 1c (deferred, documented in ARCHITECTURE.md).
final class ScriptRuntimeLogSink: ScriptLogSink {
    func log(envId: UInt64, line: String) {
        print("[script] \(line)")
    }
}

/// Bridges the game's `RandomX` (Core) to the `ScriptRandomStream` protocol
/// (ElysiumScript) through a small value box, since `ElysiumScript` cannot
/// see `RandomX` directly (design.md Decision 11 — `ScriptHostBindings.swift`
/// already conforms `RandomX` itself; this wrapper exists only because
/// `makeEnvironment` wants a value it can copy into its own bookkeeping while
/// this runtime also wants to read the *same* stream back out for
/// persistence — `RandomStreamBox`'s own class semantics inside
/// `ElysiumScript` are `internal`, so this runtime keeps its own reference).
final class RandomStreamBoxAdapter: ScriptRandomStream {
    var inner: RandomX
    init(_ inner: RandomX) { self.inner = inner }
    func nextUInt32() -> UInt32 { inner.next() }
    func reseed(_ seed: UInt32) { inner = RandomX(seed) }
}
