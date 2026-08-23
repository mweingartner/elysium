// AttributeRegistry.swift — object-graph-attributes (change 1a). design.md
// Decision 7 / spec `attribute-registry`. A pure-data table of every built-in
// attribute of every kind — no world-capturing closures (Sendable data shared
// with docs and the AI tools, §6.2) — plus resolution (canonical names,
// aliases, indexed/keyed families), applicability, and did-you-mean.
// `BuiltInAttributes.swift` holds the typed GET/SET switches that actually
// read/write the engine; this file only says *what exists and where*.

import Foundation

/// The shape of a built-in attribute's value.
public enum AttrKind: Sendable, Equatable {
    case bool, int, number, string, ref, list, map, item, effectList
    /// Spec's `.enum([String])` — named `enumeration` because `enum` is a
    /// Swift keyword.
    case enumeration([String])
}

public enum Mutability: Sendable, Equatable {
    case getSet, readOnly
}

/// What object a descriptor applies to, beyond its `kinds` set. Pure data —
/// `.custom` names a predicate implemented once in `applies(_:in:)` for the
/// handful of attributes (id-family/name-pattern based) a closed list of
/// shapes or ids cannot express tersely.
// `@unchecked Sendable`: `Shape` (BlockDefs.swift, outside this change's
// manifest) is a plain `UInt8` raw-value enum with no reference/mutable
// state — structurally Sendable — but is not itself declared `Sendable`, so
// the compiler cannot infer it automatically.
public enum Applicability: @unchecked Sendable, Equatable {
    case any
    case blockShapes([Shape])
    case blockNames([String])
    case blockEntityAny
    case livingOnly
    case mobOnly
    case entityTypes([String])
    case custom(String)
}

public struct AttributeDescriptor: Sendable {
    public let canonical: String
    public let aliases: [String]
    public let kinds: Set<ObjectKind>
    public let applicability: Applicability
    public let valueKind: AttrKind
    public let mutability: Mutability
    public let observable: Bool
    public let aiExposed: Bool
    public let summary: String

    public init(
        canonical: String, aliases: [String] = [], kinds: Set<ObjectKind>,
        applicability: Applicability = .any, valueKind: AttrKind, mutability: Mutability,
        observable: Bool = true, aiExposed: Bool = true, summary: String
    ) {
        self.canonical = canonical
        self.aliases = aliases
        self.kinds = kinds
        self.applicability = applicability
        self.valueKind = valueKind
        self.mutability = mutability
        self.observable = observable
        self.aiExposed = aiExposed
        self.summary = summary
    }
}

/// The context `applies(_:in:)` checks a descriptor's `applicability` against
/// — never captured by a descriptor itself, only passed at query time by
/// `BuiltInAttributes`, which has the live object.
public enum AttributeApplicabilityContext {
    case block(shape: Shape, name: String, blockEntityType: String?)
    case entity(type: String, isPlayer: Bool, isLiving: Bool, isMob: Bool)
    case dimension
    case world
}

public enum AttributeRegistry {
    // MARK: - the 1a built-in table (spec `attribute-registry` "The 1a built-in table")

    public static let all: [AttributeDescriptor] = blockDescriptors + entityDescriptors
        + playerDescriptors + dimensionDescriptors + worldDescriptors

    private static let blockDescriptors: [AttributeDescriptor] = [
        d("name", .block, .any, .string, .readOnly, "the block's registered name"),
        d("meta", .block, .any, .int, .getSet, "raw meta nibble (0-15)", aiExposed: false),
        d("shape", .block, .any, .string, .readOnly, "the block's placement shape"),
        d("hardness", .block, .any, .number, .readOnly, "mining hardness"),
        d("light", .block, .any, .int, .readOnly, "emitted light level"),
        d("sky_light", .block, .any, .int, .readOnly, "sky light at this cell"),
        d("waterlogged", .block, .any, .bool, .readOnly, "cell is water-filled"),
        // Declared value kind is the union of the facing-4 (`north south west
        // east`) and facing-6 (`down up north south west east`) enums —
        // `BuiltInAttributes` enforces the narrower set for the specific
        // shape at GET/SET time.
        d("facing", .block, .custom("facing"),
          .enumeration(["down", "up", "north", "south", "west", "east"]), .getSet, "block facing"),
        d("half", .block, .custom("half"), .enumeration(["bottom", "top"]), .getSet, "top/bottom half"),
        d("open", .block, .blockShapes([.door, .trapdoor, .fenceGate]), .bool, .getSet, "door/trapdoor/gate open"),
        d("hinge", .block, .blockShapes([.door]), .enumeration(["left", "right"]), .getSet, "door hinge side"),
        d("powered", .block, .custom("powered"), .bool, .getSet, "lever/button powered"),
        d("delay", .block, .blockShapes([.repeater]), .int, .getSet, "repeater delay (1-4)"),
        d("mode", .block, .blockShapes([.comparator]), .enumeration(["compare", "subtract"]), .getSet,
          "comparator mode"),
        d("age", .block, .blockShapes([.crop, .netherWart]), .int, .getSet, "growth stage"),
        d("axis", .block, .custom("axis"), .enumeration(["y", "x", "z"]), .getSet, "log/pillar axis"),
        d("layers", .block, .blockShapes([.layer]), .int, .getSet, "snow layer count (1-8)"),
        // Verified bit layout exists only for sea pickle (`(meta & 3) + 1`,
        // `BlockRegistry3.swift:382`, `BlockRegistry.swift:377`); candle and
        // turtle egg stack counts are left unverified and therefore absent
        // rather than guessed (design.md Decision 8).
        d("count", .block, .custom("count"), .int, .getSet, "sea pickle count (1-4)"),
        d("lit", .block, .custom("lit"), .bool, .getSet, "furnace/blast furnace/smoker/lamp lit"),
        d("be.type", .block, .blockEntityAny, .string, .readOnly, "block entity type"),
        d("be.name", .block, .blockEntityAny, .string, .readOnly, "block entity custom name"),
        d("be.lines", .block, .blockEntityAny, .list, .readOnly, "sign text lines"),
        d("be.burn_time", .block, .blockEntityAny, .int, .readOnly, "furnace burn time remaining"),
        d("be.cook_time", .block, .blockEntityAny, .int, .readOnly, "furnace cook time elapsed"),
        d("be.mob", .block, .blockEntityAny, .string, .readOnly, "spawner mob type"),
    ]

    /// `be.items[i]` is an indexed family (resolved in `resolve(kind:name:)`,
    /// synthesized on demand) rather than a table row — recorded here only so
    /// `descriptors(for:)`/conformance can see it exists.
    static let blockItemsFamily = AttributeDescriptor(
        canonical: "be.items", kinds: [.block], applicability: .blockEntityAny,
        valueKind: .item, mutability: .readOnly, summary: "container slot item (or null)"
    )

    private static let entityDescriptors: [AttributeDescriptor] = [
        d("type", [.entity, .player], .any, .string, .readOnly, "entity type"),
        d("x", [.entity, .player], .any, .number, .getSet, "world X"),
        d("y", [.entity, .player], .any, .number, .getSet, "world Y"),
        d("z", [.entity, .player], .any, .number, .getSet, "world Z"),
        d("yaw", [.entity, .player], .any, .number, .getSet, "yaw (radians)"),
        d("pitch", [.entity, .player], .any, .number, .getSet, "pitch (radians)"),
        d("vx", [.entity, .player], .any, .number, .getSet, "velocity X"),
        d("vy", [.entity, .player], .any, .number, .getSet, "velocity Y"),
        d("vz", [.entity, .player], .any, .number, .getSet, "velocity Z"),
        d("on_ground", [.entity, .player], .any, .bool, .readOnly, "standing on solid ground"),
        d("in_water", [.entity, .player], .any, .bool, .readOnly, "submerged in water"),
        d("on_fire", [.entity, .player], .any, .bool, .getSet, "currently on fire"),
        d("age", [.entity, .player], .any, .int, .readOnly, "ticks alive"),
        d("dead", [.entity, .player], .any, .bool, .readOnly, "removed from the world"),
        d("persistent", [.entity, .player], .any, .bool, .getSet, "exempt from despawning"),
        d("health", [.entity, .player], .livingOnly, .number, .getSet, "current health"),
        d("max_health", [.entity, .player], .livingOnly, .number, .readOnly, "maximum health"),
        d("absorption", [.entity, .player], .livingOnly, .number, .readOnly, "absorption hearts"),
        d("effects", [.entity, .player], .livingOnly, .effectList, .readOnly, "active potion effects"),
        d("armor", [.entity, .player], .livingOnly, .list, .readOnly, "worn armor pieces"),
        d("main_hand", [.entity, .player], .livingOnly, .item, .readOnly, "main-hand item"),
        d("off_hand", [.entity, .player], .livingOnly, .item, .readOnly, "off-hand item"),
        d("target", [.entity, .player], .mobOnly, .ref, .readOnly, "current AI target"),
        d("baby", [.entity, .player], .mobOnly, .bool, .getSet, "juvenile form"),
        d("sitting", [.entity, .player], .mobOnly, .bool, .getSet, "sitting (tamed mobs)"),
        d("tamed", [.entity, .player], .mobOnly, .bool, .readOnly, "has an owner"),
        d("owner", [.entity, .player], .mobOnly, .ref, .readOnly, "owning player"),
        d("variant", [.entity, .player], .any, .int, .readOnly, "type-specific variant id"),
        d("color", [.entity, .player], .any, .int, .readOnly, "type-specific color id"),
        d("item", [.entity, .player], .entityTypes(["item"]), .item, .readOnly, "dropped item stack"),
        d("xp", [.entity, .player], .entityTypes(["xp_orb"]), .int, .readOnly, "experience orb value"),
    ]

    private static let playerDescriptors: [AttributeDescriptor] = [
        d("hunger", .player, .any, .int, .getSet, "hunger (0-20)"),
        d("saturation", .player, .any, .number, .getSet, "food saturation"),
        d("xp_level", .player, .any, .int, .getSet, "experience level"),
        d("xp_progress", .player, .any, .number, .readOnly, "progress to next level (0-1)"),
        d("game_mode", .player, .any, .enumeration(["survival", "creative"]), .getSet, "game mode"),
        d("dimension", .player, .any, .enumeration(["overworld", "nether", "end"]), .readOnly, "current dimension"),
        d("held_slot", .player, .any, .int, .getSet, "selected hotbar slot (0-8)"),
        d("held_item", .player, .any, .item, .readOnly, "item in the selected slot"),
        d("sneaking", .player, .any, .bool, .readOnly, "sneaking"),
        d("sprinting", .player, .any, .bool, .readOnly, "sprinting"),
        d("flying", .player, .any, .bool, .readOnly, "flying (creative)"),
        d("sleeping", .player, .any, .bool, .readOnly, "in bed"),
        d("spawn_point", .player, .any, .map, .readOnly, "respawn point"),
        d("rpg.path", .player, .any, .string, .readOnly, "chosen RPG class path"),
        d("rpg.level", .player, .any, .int, .readOnly, "RPG character level"),
        d("rpg.fatigue", .player, .any, .number, .readOnly, "RPG fatigue"),
    ]

    /// `inventory[i]` and `stats.<name>` are families (resolved on demand);
    /// recorded here only so `descriptors(for:)`/conformance can see them.
    static let inventoryFamily = AttributeDescriptor(
        canonical: "inventory", kinds: [.player], valueKind: .item, mutability: .readOnly,
        summary: "inventory slot item (0-35, or null)"
    )
    static let statsFamily = AttributeDescriptor(
        canonical: "stats", kinds: [.player], valueKind: .int, mutability: .readOnly,
        summary: "a player statistic, keyed by name"
    )

    private static let dimensionDescriptors: [AttributeDescriptor] = [
        d("time", .dim, .any, .int, .readOnly, "dimension age in ticks"),
        d("day_time", .dim, .any, .int, .getSet, "time of day (0-23999)"),
        d("day_phase", .dim, .any, .enumeration(["day", "sunset", "night", "sunrise"]), .readOnly, "phase of day"),
        d("raining", .dim, .any, .bool, .getSet, "currently raining"),
        d("thundering", .dim, .any, .bool, .getSet, "currently thundering"),
        d("rain_level", .dim, .any, .number, .readOnly, "rain intensity (0-1)"),
    ]

    private static let worldDescriptors: [AttributeDescriptor] = [
        d("difficulty", .world, .any, .enumeration(["peaceful", "easy", "normal", "hard"]), .getSet,
          "world difficulty"),
        d("seed", .world, .any, .int, .readOnly, "world seed"),
        d("tick", .world, .any, .int, .readOnly, "RPG simulation tick"),
        d("scripts_enabled", .world, .any, .bool, .readOnly, "scripting trust gate (1c)"),
    ]

    /// `gamerule.<name>` is a keyed family (resolved on demand); recorded here
    /// only so `descriptors(for:)`/conformance can see it exists.
    static let gameruleFamily = AttributeDescriptor(
        canonical: "gamerule", kinds: [.world], valueKind: .number, mutability: .getSet,
        summary: "a game rule, keyed by name"
    )

    private static func d(
        _ canonical: String, _ kind: ObjectKind, _ applicability: Applicability, _ valueKind: AttrKind,
        _ mutability: Mutability, _ summary: String, aiExposed: Bool = true
    ) -> AttributeDescriptor {
        AttributeDescriptor(
            canonical: canonical, kinds: [kind], applicability: applicability, valueKind: valueKind,
            mutability: mutability, aiExposed: aiExposed, summary: summary
        )
    }
    private static func d(
        _ canonical: String, _ kinds: Set<ObjectKind>, _ applicability: Applicability, _ valueKind: AttrKind,
        _ mutability: Mutability, _ summary: String, aiExposed: Bool = true
    ) -> AttributeDescriptor {
        AttributeDescriptor(
            canonical: canonical, kinds: kinds, applicability: applicability, valueKind: valueKind,
            mutability: mutability, aiExposed: aiExposed, summary: summary
        )
    }

    // MARK: - lookup tables (built once, keyed by kind)

    private static let byKindAndName: [ObjectKind: [String: AttributeDescriptor]] = {
        var out: [ObjectKind: [String: AttributeDescriptor]] = [:]
        for descr in all {
            for kind in descr.kinds {
                var forKind = out[kind] ?? [:]
                forKind[descr.canonical] = descr
                for alias in descr.aliases { forKind[alias] = descr }
                out[kind] = forKind
            }
        }
        return out
    }()

    /// Every descriptor applicable to `kind`, in table-declaration order
    /// (spec "`descriptors(for kind:)` in registry order").
    public static func descriptors(for kind: ObjectKind) -> [AttributeDescriptor] {
        all.filter { $0.kinds.contains(kind) }
    }

    // MARK: - resolution

    /// Resolves `name` (canonical, alias, or an indexed/keyed family spelling)
    /// against `kind`. Ignores per-object applicability — call `applies(_:in:)`
    /// with a live context to check whether the *specific* object has it.
    public static func resolve(kind: ObjectKind, name: String) -> AttributeDescriptor? {
        if let hit = byKindAndName[kind]?[name] { return hit }
        if kind == .player, name.hasPrefix("inventory["), name.hasSuffix("]") {
            let inner = name.dropFirst("inventory[".count).dropLast()
            if let idx = Int(inner), idx >= 0, idx <= 35 {
                return AttributeDescriptor(
                    canonical: name, kinds: [.player], valueKind: .item, mutability: .readOnly,
                    summary: inventoryFamily.summary
                )
            }
        }
        if kind == .block, name.hasPrefix("be.items["), name.hasSuffix("]") {
            let inner = name.dropFirst("be.items[".count).dropLast()
            if let idx = Int(inner), idx >= 0 {
                return AttributeDescriptor(
                    canonical: name, kinds: [.block], applicability: .blockEntityAny, valueKind: .item,
                    mutability: .readOnly, summary: blockItemsFamily.summary
                )
            }
        }
        if kind == .world, name.hasPrefix("gamerule.") {
            let ruleName = String(name.dropFirst("gamerule.".count))
            guard !ruleName.isEmpty else { return nil }
            return AttributeDescriptor(
                canonical: name, kinds: [.world], valueKind: .number, mutability: .getSet,
                summary: gameruleFamily.summary
            )
        }
        if kind == .player, name.hasPrefix("stats.") {
            let statName = String(name.dropFirst("stats.".count))
            guard !statName.isEmpty else { return nil }
            return AttributeDescriptor(
                canonical: name, kinds: [.player], valueKind: .int, mutability: .readOnly,
                summary: statsFamily.summary
            )
        }
        return nil
    }

    /// Whether `descriptor` applies to the *specific* object `context`
    /// describes (spec "reject a name that is not applicable to the object's
    /// family, e.g. `facing` on a `stone` block").
    public static func applies(_ descriptor: AttributeDescriptor, in context: AttributeApplicabilityContext) -> Bool {
        switch (descriptor.applicability, context) {
        case (.any, _):
            return true
        case (.blockShapes(let shapes), .block(let shape, _, _)):
            return shapes.contains(shape)
        case (.blockNames(let names), .block(_, let name, _)):
            return names.contains(name)
        case (.blockEntityAny, .block(_, _, let beType)):
            return beType != nil
        case (.livingOnly, .entity(_, _, let isLiving, _)):
            return isLiving
        case (.mobOnly, .entity(_, _, _, let isMob)):
            return isMob
        case (.entityTypes(let types), .entity(let type, _, _, _)):
            return types.contains(type)
        case (.custom(let key), .block(let shape, let name, _)):
            return customBlockApplicability(key, shape: shape, name: name)
        default:
            return false
        }
    }

    /// The handful of block attributes whose applicability is an id-family or
    /// a name pattern, not a closed shape list.
    private static func customBlockApplicability(_ key: String, shape: Shape, name: String) -> Bool {
        switch key {
        case "facing":
            // facing-4 shapes/ids
            return [.stairs, .door, .fenceGate, .bed, .repeater, .comparator, .campfire, .chest].contains(shape)
                || ["furnace", "furnace_lit", "blast_furnace", "blast_furnace_lit", "smoker", "smoker_lit",
                    "carved_pumpkin", "jack_o_lantern", "loom", "chiseled_bookshelf"].contains(name)
                // facing-6 shapes
                || [.piston, .pistonHead].contains(shape)
                || ["observer", "dispenser", "dropper", "barrel", "hopper"].contains(name)
                || (shape == .lever || shape == .button)
        case "half":
            return [.stairs, .slab, .trapdoor, .door].contains(shape)
        case "powered":
            return [.lever, .button].contains(shape)
        case "axis":
            return name.hasSuffix("_log") || name.hasSuffix("_stem") || name.hasSuffix("_wood")
                || name.contains("hyphae") || name.contains("basalt") || name == "bone_block"
                || name == "chain" || name == "quartz_pillar" || name == "purpur_pillar" || name == "bamboo_block"
        case "count":
            return name == "sea_pickle"
        case "lit":
            return ["furnace", "furnace_lit", "blast_furnace", "blast_furnace_lit", "smoker", "smoker_lit",
                    "redstone_lamp", "redstone_lamp_on"].contains(name)
        default:
            return false
        }
    }

    // MARK: - did-you-mean

    /// Case-insensitive, camelCase-normalized, Levenshtein-distance-≤2 match
    /// over `kind`'s canonical names and aliases, ≤ 3 suggestions, ordered by
    /// (distance, then canonical spelling) for determinism. Security (code)
    /// SC-2: `name` is bounded to 64 bytes before the Levenshtein sweep over
    /// every descriptor — unreachable from the 1a command path today (a
    /// registered name `resolve` would accept is ≤32 bytes by construction,
    /// and a longer custom name is refused earlier by
    /// `AttributeStore.isValidAttributeName`), but this is a public API a
    /// future caller (1c's `completeCommandLineItem`) could reach directly
    /// with an unbounded string.
    public static func didYouMean(kind: ObjectKind, name: String) -> [String] {
        guard name.utf8.count <= 64 else { return [] }
        let query = normalizeForMatch(name)
        var candidates: [(name: String, distance: Int)] = []
        var seen = Set<String>()
        for descr in descriptors(for: kind) {
            guard seen.insert(descr.canonical).inserted else { continue }
            let dist = levenshtein(query, normalizeForMatch(descr.canonical))
            if dist <= 2 { candidates.append((descr.canonical, dist)) }
        }
        candidates.sort { a, b in a.distance == b.distance ? a.name < b.name : a.distance < b.distance }
        return candidates.prefix(3).map(\.name)
    }

    /// lowercases and inserts `_` at camelCase boundaries so "MaxHealth" and
    /// "maxhealth" both compare against "max_health" the same way.
    private static func normalizeForMatch(_ s: String) -> String {
        var out = ""
        var previousLower = false
        for ch in s {
            if ch.isUppercase && previousLower { out.append("_") }
            out.append(Character(ch.lowercased()))
            previousLower = ch.isLowercase
        }
        return out
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
