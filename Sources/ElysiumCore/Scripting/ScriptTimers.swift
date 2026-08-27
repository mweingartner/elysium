// ScriptTimers.swift — script-runtime (change 1c). design.md §8.6/§17-8:
// "named timers (`after(n, 'handler')`, `every(n, 'handler')`) are persisted
// in the registry (<= 256 per world), survive unload/reload and restarts,
// and fire at the due tick (an overdue timer fires in the first phase after
// its owner loads)." Closure timers (an anonymous Lua function passed
// instead of a name) are live-only and never reach this type.
//
// Persisted in `WorldRecord.scriptTimers` — a field of its own rather than a
// new section inside `scriptRegistry` (design.md §10 describes one combined
// `scriptRegistry` shape; this change keeps subscriptions and durable timers
// in two independently-encoded fields instead, both under the same 512 KiB
// world-document budget). This is a deliberate, low-risk scoping decision:
// it leaves `EventSubscription.swift`'s codec (1b) completely untouched
// rather than reopening its already-reviewed shape, at the cost of one extra
// (small, empty-omitted) WorldRecord key — documented in ARCHITECTURE.md.

import Foundation

public struct DurableTimer: Equatable, Sendable {
    public var id: UInt64
    public var owner: ObjectRef
    public var scriptName: String
    /// The named handler (§8.6) — resolved through `ScriptRuntime`'s named-
    /// handler table, populated when the owning script's module body calls
    /// `register(name, fn)` (this change's adaptation of "a bare global
    /// function name" — see ARCHITECTURE.md's script-runtime section for why
    /// the shipped host-binding API cannot look up an arbitrary Lua global
    /// by name from Swift).
    public var handlerName: String
    public var wakeTick: Int64
    /// `nil` for `after` (one-shot); the repeat interval for `every`.
    public var intervalTicks: Int64?

    public init(
        id: UInt64, owner: ObjectRef, scriptName: String, handlerName: String,
        wakeTick: Int64, intervalTicks: Int64?
    ) {
        self.id = id
        self.owner = owner
        self.scriptName = scriptName
        self.handlerName = handlerName
        self.wakeTick = wakeTick
        self.intervalTicks = intervalTicks
    }
}

public enum DurableTimerRegistryCodec {
    public static let maxTimersPerWorld = 256

    public static func encode(_ timers: [DurableTimer]) -> String {
        var out = "{\"timers\":["
        var first = true
        for timer in timers.sorted(by: { $0.id < $1.id }) {
            if !first { out += "," }
            first = false
            out += "{\"id\":\(timer.id)"
            out += ",\"who\":" + jsonString(timer.owner.canonical)
            out += ",\"script\":" + jsonString(timer.scriptName)
            out += ",\"handler\":" + jsonString(timer.handlerName)
            out += ",\"wake\":\(timer.wakeTick)"
            if let interval = timer.intervalTicks { out += ",\"every\":\(interval)" }
            out += "}"
        }
        out += "],\"v\":1}"
        return out
    }

    public static func decode(
        _ text: String, diagnostic: (String) -> Void = { _ in }
    ) -> [DurableTimer]? {
        guard text.utf8.count <= 131_072 else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        guard strictScriptingRegistryInteger(root["v"]) == 1 else { return nil }
        guard let raw = root["timers"] as? [[String: Any]] else { return [] }
        var result: [DurableTimer] = []
        var seenIDs = Set<UInt64>()
        for entry in raw {
            guard let timer = decodeOne(entry), !seenIDs.contains(timer.id), result.count < maxTimersPerWorld else {
                diagnostic("dropped malformed or duplicate-id durable timer entry")
                continue
            }
            seenIDs.insert(timer.id)
            result.append(timer)
        }
        return result
    }

    private static func decodeOne(_ raw: [String: Any]) -> DurableTimer? {
        guard let idValue = strictScriptingRegistryInteger(raw["id"]), idValue >= 0 else { return nil }
        guard let whoText = raw["who"] as? String, let owner = ObjectRef.parse(whoText) else { return nil }
        guard let scriptName = raw["script"] as? String, isValidAttributeName(scriptName) else { return nil }
        guard let handlerName = raw["handler"] as? String, isValidAttributeName(handlerName) else { return nil }
        guard let wakeTick = strictScriptingRegistryInteger(raw["wake"]) else { return nil }
        var interval: Int64?
        if let rawInterval = raw["every"] {
            guard let intervalTicks = strictScriptingRegistryInteger(rawInterval), intervalTicks > 0 else { return nil }
            interval = intervalTicks
        }
        return DurableTimer(
            id: UInt64(idValue), owner: owner, scriptName: scriptName, handlerName: handlerName,
            wakeTick: wakeTick, intervalTicks: interval
        )
    }

    private static func jsonString(_ s: String) -> String {
        AttrValueCodec.encode(.string(s))
    }
}
