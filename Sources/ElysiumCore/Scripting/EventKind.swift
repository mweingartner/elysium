// EventKind.swift — event-bus (change 1b). design.md §7.1/§7.2. `EventKind` is a
// validated string, not a closed Swift enum — the catalog table in §7.2 fixes a set
// of well-known kinds (`"attribute.changed"`, `"block.broken"`, …) but custom events
// are script/player-defined names in the same namespace, "bare names, namespaced by
// convention"; the manual `emit()`/AI `emit_event`/`/events emit` funnels can produce
// those custom names (e.g. `"lumber.milestone"`) but reject engine-produced built-ins.
// One type, one grammar, so a catalog kind and a custom kind are
// indistinguishable to anything downstream (subscriptions, delivery, persistence).

import Foundation

/// A typed event kind: either one of the v1 catalog's fixed names or a
/// custom, script/player-defined name (`"lumber.milestone"`). Custom-name grammar is one or more
/// `[a-z][a-z0-9_]{0,31}` segments joined by `.`, ≤ 64 bytes total. Frozen catalog names
/// predate that grammar and contain camel-case suffixes; `parse` accepts those exact ABI names but
/// does not broaden the custom namespace. Never traps; construction from untrusted text goes
/// through `EventKind.parse(_:)`, which returns `nil` on anything malformed.
public struct EventKind: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    /// Only used internally by the catalog constants below and by `parse`,
    /// both of which already validated `rawValue` — never called directly on
    /// untrusted text (use `parse(_:)` for that).
    private init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    /// Strict parse for command/AI/script-supplied event names: each `.`-
    /// separated segment matches `[a-z][a-z0-9_]{0,31}`, 1–4 segments, ≤ 64
    /// bytes total. Accepts both catalog names and custom names — the two are
    /// never distinguished structurally, exactly like the design's own
    /// `EventKind` field ("`\"attribute.changed\"`, `\"block.broken\"`,
    /// `\"lumber.milestone\"`…").
    public static func parse(_ s: String) -> EventKind? {
        guard s.utf8.count <= 64, !s.isEmpty else { return nil }
        if camelCaseCatalogNames.contains(s) { return EventKind(s) }
        let segments = s.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 1, segments.count <= 4 else { return nil }
        for segment in segments {
            let bytes = Array(segment.utf8)
            guard bytes.count >= 1, bytes.count <= 32 else { return nil }
            guard bytes[0] >= UInt8(ascii: "a"), bytes[0] <= UInt8(ascii: "z") else { return nil }
            for b in bytes.dropFirst() {
                let ok = (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
                    || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: "_")
                if !ok { return nil }
            }
        }
        return EventKind(s)
    }

    /// Frozen spellings emitted and persisted by the v1 engine. They are exact exceptions to the
    /// lowercase custom-event grammar; accepting arbitrary uppercase custom names would silently
    /// expand the script API and weaken typo detection.
    private static let camelCaseCatalogNames: Set<String> = [
        "block.neighborChanged",
        "block.scheduledTick",
        "block.toolStrike",
        "entity.targetChanged",
        "player.dimensionChanged",
        "player.pickedUp",
        "dim.dayPhaseChanged",
        "dim.weatherChanged",
        "world.gameruleChanged",
        "world.difficultyChanged",
        "script.overBudget",
    ]

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let s = try container.decode(String.self)
        guard let parsed = EventKind.parse(s) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "invalid EventKind '\(s)'")
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    /// Whether a `.kind(.block, typeFilter)` subscription without a type
    /// filter is refused for this kind (§7.3: "for blocks a type filter is
    /// required for `block.changed`/`attribute.changed`; causal block events
    /// (placed/broken/used) may be unfiltered").
    public var requiresBlockTypeFilter: Bool {
        self == .blockChanged || self == .attributeChanged
    }

    /// Whether this kind participates in the pending-queue coalescing rule
    /// (§7.6): `attribute.changed` per `(subject,key)`, `block.changed` per
    /// position. Every other kind is delivered individually.
    public var isCoalescable: Bool {
        self == .attributeChanged || self == .blockChanged
    }

    // MARK: - v1 catalog (design.md §7.2)

    public static let attributeChanged = EventKind("attribute.changed")

    public static let blockPlaced = EventKind("block.placed")
    public static let blockToolStrike = EventKind("block.toolStrike")
    public static let blockBroken = EventKind("block.broken")
    public static let blockReplaced = EventKind("block.replaced")
    public static let blockChanged = EventKind("block.changed")
    public static let blockUsed = EventKind("block.used")
    public static let blockNeighborChanged = EventKind("block.neighborChanged")
    public static let blockScheduledTick = EventKind("block.scheduledTick")

    public static let entitySpawned = EventKind("entity.spawned")
    public static let entityRemoved = EventKind("entity.removed")
    public static let entityDamaged = EventKind("entity.damaged")
    public static let entityDied = EventKind("entity.died")
    public static let entityHealed = EventKind("entity.healed")
    public static let entityInteracted = EventKind("entity.interacted")
    public static let entityTargetChanged = EventKind("entity.targetChanged")

    public static let playerJoined = EventKind("player.joined")
    public static let playerLeft = EventKind("player.left")
    public static let playerRespawned = EventKind("player.respawned")
    public static let playerDimensionChanged = EventKind("player.dimensionChanged")
    public static let playerPickedUp = EventKind("player.pickedUp")
    public static let playerDropped = EventKind("player.dropped")
    public static let playerAttacked = EventKind("player.attacked")
    public static let playerSlept = EventKind("player.slept")
    public static let playerLeveled = EventKind("player.leveled")
    public static let playerAdvancement = EventKind("player.advancement")

    public static let dimDayPhaseChanged = EventKind("dim.dayPhaseChanged")
    public static let dimWeatherChanged = EventKind("dim.weatherChanged")

    public static let worldGameruleChanged = EventKind("world.gameruleChanged")
    public static let worldDifficultyChanged = EventKind("world.difficultyChanged")

    public static let explosion = EventKind("explosion")

    /// Script lifecycle (§8.2) — 1c raises these once scripts exist; the
    /// kind is reserved here so 1c only plugs in the funnel.
    public static let load = EventKind("load")
    public static let unload = EventKind("unload")

    /// Durable timers (§8) — 1c raises these once scripts/timers exist.
    public static let timerFired = EventKind("timer.fired")
    /// The AI inbox (phase 2) — reserved here.
    public static let aiReplied = EventKind("ai.replied")

    public static let scriptFaulted = EventKind("script.faulted")
    public static let scriptAttached = EventKind("script.attached")
    /// Also raised by `EventBus` itself (§7.6: "excess is dropped
    /// deterministically with one `script.overBudget`") when a cap trips.
    public static let scriptOverBudget = EventKind("script.overBudget")
}
