// EventDescriptorRegistry.swift — enumerable, typed authoring metadata for EventKind's shipped
// validated-string catalog. EventKind intentionally remains open for custom events; this registry
// describes only the built-ins that the engine reserves or currently raises.

import Foundation

public struct ScriptEventFieldDescriptor: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let type: ScriptLanguageValueType
    public let isNullable: Bool
    public let summary: String

    public init(
        name: String,
        type: ScriptLanguageValueType,
        isNullable: Bool = false,
        summary: String
    ) {
        self.name = name
        self.type = type
        self.isNullable = isNullable
        self.summary = summary
    }
}

public struct ScriptEventDescriptor: Sendable, Equatable, Identifiable {
    public var id: String { kind.rawValue }
    public let kind: EventKind
    public let subjectKinds: Set<ObjectKind>
    public let payload: [ScriptEventFieldDescriptor]
    public let availability: ScriptLanguageAvailability
    public let summary: String

    public init(
        kind: EventKind,
        subjectKinds: Set<ObjectKind>,
        payload: [ScriptEventFieldDescriptor] = [],
        availability: ScriptLanguageAvailability = .available,
        summary: String
    ) {
        self.kind = kind
        self.subjectKinds = subjectKinds
        self.payload = payload
        self.availability = availability
        self.summary = summary
    }
}

public enum EventDescriptorRegistry {
    private static let everyObjectKind = Set(ObjectKind.allCases)

    /// Fields present on every delivered `ev` table. Payload fields are merged alongside these;
    /// `source` always denotes event provenance (`player`, `engine`, `ai`, `lan`, or script owner).
    public static let commonFields: [ScriptEventFieldDescriptor] = [
        field("kind", .string, "Validated event name."),
        field("subject", .objectHandle, "The event subject."),
        field("tick", .integer, "World tick at which the event was raised."),
        field("source", .string, "Event provenance, not a damage-cause identifier."),
    ]

    public static let all: [ScriptEventDescriptor] = [
        event(
            .attributeChanged, everyObjectKind,
            [field("key", .string, "Changed attribute name."), nullable("old", .any, "Previous value, or nil."), nullable("new", .any, "New value, or nil.")],
            "A built-in or custom attribute changed."
        ),

        event(.blockPlaced, [.block], [field("by", .objectHandle, "Player that placed the block."), field("item", .string, "Placed block's registered name.")], "A player placed a block."),
        event(.blockBroken, [.block], [field("by", .objectHandle, "Player that broke the block."), nullable("item", .string, "Held item name, or nil.")], "A player broke a block."),
        event(
            .blockReplaced, [.block], availability: .reserved("The name is reserved, but the shipped engine does not currently raise it."),
            "Reserved lifecycle event for record-owning block replacement."
        ),
        event(
            .blockChanged, [.block],
            [field("oldName", .string, "Previous registered block name."), field("newName", .string, "New registered block name."), field("oldMeta", .integer, "Previous metadata nibble."), field("newMeta", .integer, "New metadata nibble.")],
            "A non-silent block cell write changed name or metadata."
        ),
        event(.blockUsed, [.block], [field("by", .objectHandle, "Player that used the block."), nullable("item", .string, "Held item name, or nil.")], "A player successfully used a block."),
        event(.blockNeighborChanged, [.block], [field("from", .objectHandle, "Neighbor block whose change caused the notification.")], "A recorded block received a neighbor update."),
        event(
            .blockScheduledTick, [.block], availability: .reserved("The name is reserved, but no script scheduling API or producer is shipped."),
            "Reserved block scheduled-tick event."
        ),

        event(.entitySpawned, [.entity, .player], summary: "A scriptable non-mirror entity entered a world."),
        event(.entityRemoved, [.entity, .player], summary: "A scriptable non-mirror entity left a world."),
        event(
            .entityDamaged, [.entity, .player],
            [field("amount", .number, "Actual health lost."), nullable("attacker", .objectHandle, "Attacking entity, or nil.")],
            "A living entity lost health. ev.source is provenance; the engine's damage-cause string is not currently exposed."
        ),
        event(.entityDied, [.entity, .player], [nullable("attacker", .objectHandle, "Killing entity, or nil.")], "A living entity died."),
        event(.entityHealed, [.entity, .player], [field("amount", .number, "Effective health restored.")], "A living entity recovered health."),
        event(.entityInteracted, [.entity], [field("by", .objectHandle, "Player that interacted."), nullable("item", .string, "Held item name, or nil.")], "A player successfully interacted with an entity."),
        event(.entityTargetChanged, [.entity], [nullable("old", .objectHandle, "Previous target, or nil."), nullable("new", .objectHandle, "New target, or nil.")], "A mob changed its target."),

        event(.playerJoined, [.player], summary: "The local/host player entered the world."),
        event(.playerLeft, [.player], summary: "The local/host player left the world."),
        event(.playerRespawned, [.player], summary: "The player respawned."),
        event(.playerDimensionChanged, [.player], [field("old", .string, "Previous dimension name."), field("new", .string, "New dimension name.")], "The player changed dimension."),
        event(.playerPickedUp, [.player], [field("item", .string, "Registered item name."), field("count", .integer, "Number gained.")], "The player picked up items."),
        event(.playerDropped, [.player], [field("item", .string, "Registered item name."), field("count", .integer, "Number dropped.")], "The player dropped items."),
        event(.playerAttacked, [.player], [field("target", .objectHandle, "Entity the player attacked.")], "The player initiated an attack."),
        event(.playerSlept, [.player], summary: "The player successfully entered a bed."),
        event(.playerLeveled, [.player], [field("old", .integer, "Previous experience level."), field("new", .integer, "New experience level.")], "The player's experience level increased."),
        event(.playerAdvancement, [.player], [field("id", .string, "Granted advancement identifier.")], "The player earned an advancement."),

        event(.dimDayPhaseChanged, [.dim], [field("old", .string, "Previous day phase."), field("new", .string, "New day phase.")], "A dimension's day phase changed."),
        event(.dimWeatherChanged, [.dim], [field("key", .string, "raining or thundering."), field("old", .boolean, "Previous state."), field("new", .boolean, "New state.")], "A dimension's rain or thunder state changed."),
        event(.worldGameruleChanged, [.world], [field("key", .string, "Game-rule name."), field("old", .number, "Previous numeric value."), field("new", .number, "New numeric value.")], "A game rule changed."),
        event(.worldDifficultyChanged, [.world], [field("old", .integer, "Previous difficulty."), field("new", .integer, "New difficulty.")], "World difficulty changed."),
        event(
            .explosion, [.dim],
            [field("x", .number, "Explosion X."), field("y", .number, "Explosion Y."), field("z", .number, "Explosion Z."), field("power", .number, "Explosion power."), nullable("by", .objectHandle, "Causing entity, or nil.")],
            "An explosion began in a dimension."
        ),

        event(.load, everyObjectKind, [field("name", .string, "Loaded script name.")], "A script finished loading and became live."),
        event(
            .unload, everyObjectKind, availability: .reserved("The name is reserved, but the shipped runtime does not currently deliver unload handlers."),
            "Reserved script lifecycle event."
        ),
        event(.timerFired, everyObjectKind, [field("name", .string, "Registered timer-handler name.")], "A durable named timer fired."),
        event(
            .aiReplied, [.world],
            [field("requestId", .integer, "Script AI request identifier."), nullable("text", .string, "Reply text, or nil."), nullable("error", .string, "timeout or budget error, or nil.")],
            "A fire-and-forget ai.ask request completed."
        ),
        event(.scriptFaulted, everyObjectKind, [field("name", .string, "Faulting script name."), field("message", .string, "Bounded fault message.")], "A script failed to compile or run."),
        event(.scriptAttached, everyObjectKind, [field("name", .string, "Attached script name.")], "A script attached another script successfully."),
        event(.scriptOverBudget, [.world], [field("message", .string, "Bounded budget diagnostic.")], "The event bus dropped excess work for this tick."),
    ]

    public static var available: [ScriptEventDescriptor] {
        all.filter { $0.availability.isCompletable }
    }

    public static var names: [String] { all.map(\.kind.rawValue) }

    public static func descriptor(for kind: EventKind) -> ScriptEventDescriptor? {
        all.first { $0.kind == kind }
    }

    public static func descriptor(named name: String) -> ScriptEventDescriptor? {
        all.first { $0.kind.rawValue == name }
    }

    private static func field(
        _ name: String, _ type: ScriptLanguageValueType, _ summary: String
    ) -> ScriptEventFieldDescriptor {
        ScriptEventFieldDescriptor(name: name, type: type, summary: summary)
    }

    private static func nullable(
        _ name: String, _ type: ScriptLanguageValueType, _ summary: String
    ) -> ScriptEventFieldDescriptor {
        ScriptEventFieldDescriptor(name: name, type: type, isNullable: true, summary: summary)
    }

    private static func event(
        _ kind: EventKind,
        _ subjectKinds: Set<ObjectKind>,
        _ payload: [ScriptEventFieldDescriptor] = [],
        availability: ScriptLanguageAvailability = .available,
        _ summary: String
    ) -> ScriptEventDescriptor {
        ScriptEventDescriptor(
            kind: kind, subjectKinds: subjectKinds, payload: payload,
            availability: availability, summary: summary
        )
    }

    private static func event(
        _ kind: EventKind,
        _ subjectKinds: Set<ObjectKind>,
        availability: ScriptLanguageAvailability = .available,
        summary: String
    ) -> ScriptEventDescriptor {
        event(kind, subjectKinds, [], availability: availability, summary)
    }
}

public extension EventKind {
    /// Deterministic built-in order for editors and generated documentation. Custom EventKind
    /// values remain valid even though they are not present here.
    static var builtInKinds: [EventKind] { EventDescriptorRegistry.all.map(\.kind) }
}
