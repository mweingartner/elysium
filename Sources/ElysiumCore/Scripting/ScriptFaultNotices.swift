// ScriptFaultNotices.swift — player-facing chat notices for script faults and event-name and
// dot-sugar attribute typo warnings. Presentation only: notices go through the same host-only sink and display hygiene as
// `say()`, never consume simulation RNG, never raise events, and never touch world state. The
// limiter below is deterministic (tick-keyed, no wall clock), bounded, and never persisted.

import Foundation

/// Admission control for script chat notices.
///
/// Scheme (all limits are per runtime session; nothing is saved):
/// - Per key (a fault key is one `owner#script`; a warning key also names the warned-about event
///   or attribute):
///   an identical message is shown at most once per `repeatQuietTicks` (1,200 ticks, one minute),
///   a different message at most once per `changeQuietTicks` (200 ticks). A suppressed notice is
///   silent and does not count toward the world cap.
/// - World-wide: at most `maxNoticesPerTick` (4) notices per tick. A notice over that cap is NOT
///   recorded as shown, so the same notice can still appear on a later tick; it is tallied, and the
///   tally is reported as a single "…and N more" line on a later tick, at most once per
///   `summaryQuietTicks` (200 ticks).
/// - Memory: at most `maxTrackedKeys` keys. When full, entries whose longest quiet window has
///   expired (they restrict nothing) are dropped. An entry still inside its window is never
///   evicted: a new key that finds no free slot is tallied into the summary instead, so key churn
///   cannot cancel quiet windows. While the table stays full of active entries, the earliest expiry
///   is remembered so each new key costs O(1) instead of a rescan.
struct ScriptNoticeLimiter {
    static let repeatQuietTicks: Int64 = 1_200
    static let changeQuietTicks: Int64 = 200
    static let summaryQuietTicks: Int64 = 200
    static let maxNoticesPerTick = 4
    static let maxTrackedKeys = 256

    enum Admission: Equatable {
        case post
        case suppressed
        case overflow
    }

    private struct Entry {
        var message: String
        var tick: Int64
    }

    private var entries: [String: Entry] = [:]
    private var countedTick: Int64?
    private var postedThisTick = 0
    private var overflowCount = 0
    private var overflowTick: Int64 = 0
    private var lastSummaryTick: Int64?
    /// Set when a sweep left the table full of active entries: (tick of that sweep, first tick at
    /// which some entry's window expires). A later tick before that expiry needs no rescan.
    private var fullUntil: (sweptAt: Int64, expiry: Int64)?

    var trackedKeyCount: Int { entries.count }

    mutating func admit(key: String, message: String, tick now: Int64) -> Admission {
        if countedTick != now {
            countedTick = now
            postedThisTick = 0
        }
        if let last = entries[key] {
            let (elapsed, overflow) = now.subtractingReportingOverflow(last.tick)
            // A backward clock (new session state, test reset) starts fresh rather than muting.
            if !overflow, elapsed >= 0 {
                let quiet = last.message == message ? Self.repeatQuietTicks : Self.changeQuietTicks
                if elapsed < quiet { return .suppressed }
            }
        }
        guard postedThisTick < Self.maxNoticesPerTick, hasSlot(for: key, tick: now) else {
            overflowCount = overflowCount == Int.max ? Int.max : overflowCount + 1
            overflowTick = now
            return .overflow
        }
        entries[key] = Entry(message: message, tick: now)
        postedThisTick += 1
        return .post
    }

    /// The number of over-cap notices to summarize: only after the tick in which they occurred, and
    /// at most once per `summaryQuietTicks`. Later overflow keeps accumulating into the next one.
    mutating func takeOverflowSummary(at now: Int64) -> Int? {
        guard overflowCount > 0, overflowTick != now else { return nil }
        if let last = lastSummaryTick {
            let (elapsed, overflow) = now.subtractingReportingOverflow(last)
            if !overflow, elapsed >= 0, elapsed < Self.summaryQuietTicks { return nil }
        }
        defer { overflowCount = 0 }
        lastSummaryTick = now
        return overflowCount
    }

    private static func isActive(_ entry: Entry, at now: Int64) -> Bool {
        let (elapsed, overflow) = now.subtractingReportingOverflow(entry.tick)
        return !overflow && elapsed >= 0 && elapsed < repeatQuietTicks
    }

    /// Whether `key` is tracked or can be, dropping only entries whose windows have all expired.
    private mutating func hasSlot(for key: String, tick now: Int64) -> Bool {
        guard entries[key] == nil, entries.count >= Self.maxTrackedKeys else { return true }
        if let full = fullUntil, now >= full.sweptAt, now < full.expiry { return false }
        entries = entries.filter { Self.isActive($0.value, at: now) }
        guard entries.count >= Self.maxTrackedKeys else {
            fullUntil = nil
            return true
        }
        let oldest = entries.values.map(\.tick).min() ?? now
        let (expiry, overflow) = oldest.addingReportingOverflow(Self.repeatQuietTicks)
        fullUntil = (now, overflow ? Int64.max : expiry)
        return false
    }
}

extension ScriptRuntime {
    /// Lua compile/runtime messages begin `[string "<chunk>"]:<line>: `; players read that as
    /// noise. Rewrites the location to `line <n>: ` and leaves every other message unchanged.
    static func friendlyFaultText(_ message: String) -> String {
        guard message.hasPrefix("[string \""), let close = message.range(of: "\"]:") else { return message }
        let rest = message[close.upperBound...]
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, rest.dropFirst(digits.count).hasPrefix(": ") else { return message }
        return "line \(digits): " + rest.dropFirst(digits.count + 2)
    }

    /// One chat line of at most 256 UTF-8 bytes. The script-controlled `detail` is sanitized and
    /// truncated first so the fixed prefix and the "how to look" suffix always survive. When fewer
    /// than three bytes remain (too few for even the ellipsis) a detail that does not fit is omitted.
    static func boundedNoticeLine(prefix: String, detail: String, suffix: String = "") -> String {
        let head = ScriptingDisplayText.line(prefix)
        let tail = ScriptingDisplayText.line(suffix)
        let budget = max(0, 256 - head.utf8.count - tail.utf8.count)
        let clean = ScriptingDisplayText.line(detail)
        let shown = clean.utf8.count <= budget ? clean : (budget < 3 ? "" : truncateUTF8(clean, toByteCount: budget))
        return ScriptingDisplayText.line(head + shown + tail)
    }

    /// Tells the host player that `owner`'s script `scriptName` faulted. Never during Check/dry-run.
    func postFaultNotice(owner: ObjectRef, scriptName: String, message: String) {
        let detail = Self.friendlyFaultText(message)
        postScriptNotice(
            key: owner.canonical + "#" + scriptName,
            line: Self.boundedNoticeLine(
                prefix: "[script] \(scriptName) on \(owner.canonical) failed: ", detail: detail,
                suffix: " (/script show \(owner.canonical) \(scriptName))"
            )
        )
    }

    /// Warns (subscription still made) when `event` is a near miss of a built-in event and is not a
    /// custom event declared on the exact object `target`.
    func warnIfEventTypo(_ event: EventKind, target: SubscriptionTarget, owner: ObjectRef, scriptName: String) {
        guard !dryRunActive, ScriptNameSuggestions.nearestBuiltInEvent(to: event.rawValue) != nil else { return }
        var declared = false
        if case .object(let ref) = target { declared = customEventStore.get(ref, event.rawValue) != nil }
        guard let hint = ScriptNameSuggestions.eventTypoHint(for: event.rawValue, isDeclared: declared) else { return }
        postScriptNotice(
            key: owner.canonical + "#" + scriptName + "#event:" + event.rawValue,
            line: Self.boundedNoticeLine(prefix: "[script] \(scriptName): ", detail: hint)
        )
    }

    /// Advises (the write already succeeded) when a dot-sugar write `h.<name> = v` has just created a
    /// custom attribute whose name is a likely typo of one of `ref`'s built-ins. Never during
    /// Check/dry-run or unload. The host-side sweep is bounded per script and per world each tick
    /// (`attributeTypoChecks`) and skipped outright for a name too long to be a near miss.
    func warnIfCreatedAttributeTypo(ref: ObjectRef, rawName: String) {
        guard !dryRunActive, !unloadActive, let ctx = currentScript,
              let query = ScriptNameSuggestions.attributeTypoQuery(kind: ref.kind, rawName: rawName),
              occupiedCustomAttributeName(for: ref, rawName: rawName) != nil,
              attributeTypoChecks.admit(scriptKey: ctx.owner.canonical + "#" + ctx.name, tick: host.currentTick),
              let suggestion = ScriptNameSuggestions.nearestBuiltInAttribute(kind: ref.kind, query: query) else { return }
        postScriptNotice(
            key: ctx.owner.canonical + "#" + ctx.name + "#attr:" + rawName,
            line: Self.boundedNoticeLine(
                prefix: "[script] \(ctx.name) on \(ctx.owner.canonical): ",
                detail: "'\(rawName)' is not a built-in attribute — did you mean '\(suggestion)'?",
                suffix: " (h.attrs.\(rawName) is the custom form)"
            )
        )
    }

    /// Posts the pending "…and N more" summary once the tick that overflowed has passed.
    func flushScriptNoticeSummary() {
        guard let count = scriptNotices.takeOverflowSummary(at: host.currentTick) else { return }
        sayFn(ScriptingDisplayText.line("[script] …and \(count) more script faults (/script list)"))
    }

    /// `line` is already bounded (<= 256 bytes), so it doubles as the limiter's comparison message.
    private func postScriptNotice(key: String, line: String) {
        guard !dryRunActive else { return }
        flushScriptNoticeSummary()
        guard scriptNotices.admit(key: key, message: line, tick: host.currentTick) == .post else { return }
        sayFn(line)
    }
}
