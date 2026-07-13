// Enchantments (the frozen baseline) and status effects + the full brewing
// graph (the frozen baseline).

import Foundation

public struct EnchantmentDef {
    public let id: String
    public let displayName: String
    public let maxLevel: Int
    public let weight: Int             // 10 common, 5 uncommon, 2 rare, 1 very rare
    public let target: String
    public let treasure: Bool
    public let curse: Bool
    public let tradeable: Bool
    /// enchanting power window for level L (1-based)
    public let minPower: (Int) -> Int
    public let maxPower: (Int) -> Int
    public let exclusiveGroup: String?
}

private func ench(_ id: String, _ displayName: String, _ maxLevel: Int, _ weight: Int, _ target: String,
                  _ minP: @escaping (Int) -> Int, _ span: Int,
                  treasure: Bool = false, curse: Bool = false, group: String? = nil, tradeable: Bool = true) -> EnchantmentDef {
    EnchantmentDef(id: id, displayName: displayName, maxLevel: maxLevel, weight: weight, target: target,
                   treasure: treasure, curse: curse, tradeable: tradeable,
                   minPower: minP, maxPower: { l in minP(l) + span }, exclusiveGroup: group)
}
private func enchF(_ id: String, _ displayName: String, _ maxLevel: Int, _ weight: Int, _ target: String,
                   _ minP: @escaping (Int) -> Int, _ maxP: @escaping (Int) -> Int,
                   treasure: Bool = false, curse: Bool = false, group: String? = nil, tradeable: Bool = true) -> EnchantmentDef {
    EnchantmentDef(id: id, displayName: displayName, maxLevel: maxLevel, weight: weight, target: target,
                   treasure: treasure, curse: curse, tradeable: tradeable,
                   minPower: minP, maxPower: maxP, exclusiveGroup: group)
}

public let ENCHANTMENTS: [EnchantmentDef] = [
    // armor
    ench("protection", "Protection", 4, 10, "armor", { l in 1 + (l - 1) * 11 }, 11, group: "protection"),
    ench("fire_protection", "Fire Protection", 4, 5, "armor", { l in 10 + (l - 1) * 8 }, 8, group: "protection"),
    ench("feather_falling", "Feather Falling", 4, 5, "armor_feet", { l in 5 + (l - 1) * 6 }, 6),
    ench("blast_protection", "Blast Protection", 4, 2, "armor", { l in 5 + (l - 1) * 8 }, 8, group: "protection"),
    ench("projectile_protection", "Projectile Protection", 4, 5, "armor", { l in 3 + (l - 1) * 6 }, 6, group: "protection"),
    ench("respiration", "Respiration", 3, 2, "armor_head", { l in 10 * l }, 30),
    ench("aqua_affinity", "Aqua Affinity", 1, 2, "armor_head", { _ in 1 }, 40),
    ench("thorns", "Thorns", 3, 1, "armor", { l in 10 + 20 * (l - 1) }, 50),
    ench("depth_strider", "Depth Strider", 3, 2, "armor_feet", { l in 10 * l }, 15, group: "boots_move"),
    ench("frost_walker", "Frost Walker", 2, 2, "armor_feet", { l in 10 * l }, 15, treasure: true, group: "boots_move"),
    ench("curse_of_binding", "Curse of Binding", 1, 1, "wearable", { _ in 25 }, 25, treasure: true, curse: true),
    ench("soul_speed", "Soul Speed", 3, 1, "armor_feet", { l in 10 * l }, 15, treasure: true, tradeable: false),
    ench("swift_sneak", "Swift Sneak", 3, 1, "armor_legs", { l in 25 * l }, 50, treasure: true, tradeable: false),
    // sword
    ench("sharpness", "Sharpness", 5, 10, "sword", { l in 1 + (l - 1) * 11 }, 20, group: "damage"),
    ench("smite", "Smite", 5, 5, "sword", { l in 5 + (l - 1) * 8 }, 20, group: "damage"),
    ench("bane_of_arthropods", "Bane of Arthropods", 5, 5, "sword", { l in 5 + (l - 1) * 8 }, 20, group: "damage"),
    ench("knockback", "Knockback", 2, 5, "sword", { l in 5 + 20 * (l - 1) }, 50),
    ench("fire_aspect", "Fire Aspect", 2, 2, "sword", { l in 10 + 20 * (l - 1) }, 50),
    ench("looting", "Looting", 3, 2, "sword", { l in 15 + (l - 1) * 9 }, 50),
    ench("sweeping_edge", "Sweeping Edge", 3, 2, "sword", { l in 5 + (l - 1) * 9 }, 15),
    // tools
    ench("efficiency", "Efficiency", 5, 10, "digger", { l in 1 + 10 * (l - 1) }, 50),
    ench("silk_touch", "Silk Touch", 1, 1, "digger", { _ in 15 }, 50, group: "silk_fortune"),
    ench("unbreaking", "Unbreaking", 3, 5, "breakable", { l in 5 + (l - 1) * 8 }, 50),
    ench("fortune", "Fortune", 3, 2, "digger", { l in 15 + (l - 1) * 9 }, 50, group: "silk_fortune"),
    // bow
    ench("power", "Power", 5, 10, "bow", { l in 1 + (l - 1) * 10 }, 15),
    ench("punch", "Punch", 2, 2, "bow", { l in 12 + (l - 1) * 20 }, 25),
    ench("flame", "Flame", 1, 2, "bow", { _ in 20 }, 30),
    ench("infinity", "Infinity", 1, 1, "bow", { _ in 20 }, 30, group: "inf_mend"),
    // fishing
    ench("luck_of_the_sea", "Luck of the Sea", 3, 2, "fishing_rod", { l in 15 + (l - 1) * 9 }, 50),
    ench("lure", "Lure", 3, 2, "fishing_rod", { l in 15 + (l - 1) * 9 }, 50),
    // trident
    enchF("loyalty", "Loyalty", 3, 5, "trident", { l in 5 + 7 * l }, { _ in 50 }, group: "riptide_x"),
    ench("impaling", "Impaling", 5, 2, "trident", { l in 1 + (l - 1) * 8 }, 20),
    enchF("riptide", "Riptide", 3, 2, "trident", { l in 10 + 7 * l }, { _ in 50 }, group: "riptide"),
    ench("channeling", "Channeling", 1, 1, "trident", { _ in 25 }, 25, group: "riptide_x"),
    // crossbow
    ench("multishot", "Multishot", 1, 2, "crossbow", { _ in 20 }, 30, group: "multi_pierce"),
    ench("quick_charge", "Quick Charge", 3, 5, "crossbow", { l in 12 + (l - 1) * 20 }, 50),
    ench("piercing", "Piercing", 4, 10, "crossbow", { l in 1 + (l - 1) * 10 }, 50, group: "multi_pierce"),
    // universal
    ench("mending", "Mending", 1, 2, "breakable", { _ in 25 }, 50, treasure: true, group: "inf_mend"),
    ench("curse_of_vanishing", "Curse of Vanishing", 1, 1, "vanishable", { _ in 25 }, 25, treasure: true, curse: true),
]

public let ENCH_BY_ID: [String: EnchantmentDef] = Dictionary(uniqueKeysWithValues: ENCHANTMENTS.map { ($0.id, $0) })

public func enchDef(_ id: String) -> EnchantmentDef {
    guard let e = ENCH_BY_ID[id] else { fatalError("unknown enchantment: \(id)") }
    return e
}

public func compatible(_ a: EnchantmentDef, _ b: EnchantmentDef) -> Bool {
    if a.id == b.id { return false }
    if let g = a.exclusiveGroup, g == b.exclusiveGroup { return false }
    let pair = Set([a.exclusiveGroup, b.exclusiveGroup])
    if pair.contains("riptide") && pair.contains("riptide_x") { return false }
    return true
}

public func appliesTo(_ e: EnchantmentDef, _ item: ItemDef) -> Bool {
    let t = item.tool, a = item.armor
    switch e.target {
    case "armor": return a != nil && a!.material != "elytra"
    case "armor_head": return a?.slot == 0
    case "armor_chest": return a?.slot == 1 && a?.material != "elytra"
    case "armor_legs": return a?.slot == 2
    case "armor_feet": return a?.slot == 3
    case "sword": return t?.type == "sword"
    case "digger": return t?.type == "pickaxe" || t?.type == "axe" || t?.type == "shovel" || t?.type == "hoe"
    case "axe": return t?.type == "axe"
    case "bow": return t?.type == "bow"
    case "crossbow": return t?.type == "crossbow"
    case "trident": return t?.type == "trident"
    case "fishing_rod": return t?.type == "fishing_rod"
    case "breakable": return t != nil || a != nil || item.name == "shield"
    case "wearable": return a != nil
    case "vanishable": return t != nil || a != nil || item.name == "shield" || item.name == "compass"
    default: return false
    }
}

public func enchantability(_ item: ItemDef) -> Int {
    item.tool?.enchantability ?? item.armor?.enchantability ?? 1
}

// =============================================================================
// Status effects + potions
// =============================================================================
public struct EffectDef {
    public let id: String
    public let displayName: String
    public let color: Int
    public let beneficial: Bool
    public let instant: Bool

    init(_ id: String, _ displayName: String, _ color: Int, _ beneficial: Bool, _ instant: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.color = color
        self.beneficial = beneficial
        self.instant = instant
    }
}

public let EFFECTS: [EffectDef] = [
    EffectDef("speed", "Speed", 0x33ebff, true),
    EffectDef("slowness", "Slowness", 0x8bafe0, false),
    EffectDef("haste", "Haste", 0xd9c043, true),
    EffectDef("mining_fatigue", "Mining Fatigue", 0x4a4217, false),
    EffectDef("strength", "Strength", 0xffc700, true),
    EffectDef("instant_health", "Instant Health", 0xf82423, true, true),
    EffectDef("instant_damage", "Instant Damage", 0xa9656a, false, true),
    EffectDef("jump_boost", "Jump Boost", 0xfdff84, true),
    EffectDef("nausea", "Nausea", 0x551d4a, false),
    EffectDef("regeneration", "Regeneration", 0xcd5cab, true),
    EffectDef("resistance", "Resistance", 0x9146f0, true),
    EffectDef("fire_resistance", "Fire Resistance", 0xff9900, true),
    EffectDef("water_breathing", "Water Breathing", 0x98dac0, true),
    EffectDef("invisibility", "Invisibility", 0xf6f6f6, true),
    EffectDef("blindness", "Blindness", 0x1f1f23, false),
    EffectDef("night_vision", "Night Vision", 0xc2ff66, true),
    EffectDef("hunger", "Hunger", 0x587653, false),
    EffectDef("weakness", "Weakness", 0x484d48, false),
    EffectDef("poison", "Poison", 0x87a363, false),
    EffectDef("wither", "Wither", 0x736156, false),
    EffectDef("health_boost", "Health Boost", 0xf87d23, true),
    EffectDef("absorption", "Absorption", 0x2552a5, true),
    EffectDef("saturation", "Saturation", 0xf82423, true, true),
    EffectDef("glowing", "Glowing", 0x94a061, false),
    EffectDef("levitation", "Levitation", 0xceffff, false),
    EffectDef("slow_falling", "Slow Falling", 0xf3cfb9, true),
    EffectDef("conduit_power", "Conduit Power", 0x1dc2d1, true),
    EffectDef("dolphins_grace", "Dolphin's Grace", 0x88a3be, true),
    EffectDef("bad_omen", "Bad Omen", 0x0b6138, false),
    EffectDef("hero_of_the_village", "Hero of the Village", 0x44ff44, true),
    EffectDef("darkness", "Darkness", 0x292721, false),
]
public let EFFECT_BY_ID: [String: EffectDef] = Dictionary(uniqueKeysWithValues: EFFECTS.map { ($0.id, $0) })
public func effectDef(_ id: String) -> EffectDef {
    guard let e = EFFECT_BY_ID[id] else { fatalError("unknown effect: \(id)") }
    return e
}

public struct ActiveEffect: Codable, Equatable {
    public var id: String
    public var duration: Int    // ticks remaining (-1 infinite)
    public var amplifier: Int   // 0 = level I
    public var ambient: Bool?
    public var showParticles: Bool?

    public init(id: String, duration: Int, amplifier: Int, ambient: Bool? = nil, showParticles: Bool? = nil) {
        self.id = id
        self.duration = duration
        self.amplifier = amplifier
        self.ambient = ambient
        self.showParticles = showParticles
    }
}

public struct PotionEffectSpec {
    public let effect: String
    public let duration: Int
    public let amplifier: Int
}

public struct PotionDef {
    public let id: String
    public let displayName: String
    public let color: Int
    public let effects: [PotionEffectSpec]
}

private let MINUTE = 1200 // 1 minute in ticks
private func potion(_ id: String, _ displayName: String, _ color: Int, _ effects: [PotionEffectSpec] = []) -> PotionDef {
    PotionDef(id: id, displayName: displayName, color: color, effects: effects)
}
private func fx(_ e: String, _ d: Int, _ a: Int) -> PotionEffectSpec { PotionEffectSpec(effect: e, duration: d, amplifier: a) }

public let POTIONS: [PotionDef] = [
    potion("water", "Water Bottle", 0x385dc6),
    potion("mundane", "Mundane Potion", 0x385dc6),
    potion("thick", "Thick Potion", 0x385dc6),
    potion("awkward", "Awkward Potion", 0x385dc6),
    potion("night_vision", "Potion of Night Vision", 0x1f1fa1, [fx("night_vision", 3 * MINUTE, 0)]),
    potion("long_night_vision", "Potion of Night Vision", 0x1f1fa1, [fx("night_vision", 8 * MINUTE, 0)]),
    potion("invisibility", "Potion of Invisibility", 0x7f8392, [fx("invisibility", 3 * MINUTE, 0)]),
    potion("long_invisibility", "Potion of Invisibility", 0x7f8392, [fx("invisibility", 8 * MINUTE, 0)]),
    potion("leaping", "Potion of Leaping", 0x22ff4c, [fx("jump_boost", 3 * MINUTE, 0)]),
    potion("long_leaping", "Potion of Leaping", 0x22ff4c, [fx("jump_boost", 8 * MINUTE, 0)]),
    potion("strong_leaping", "Potion of Leaping II", 0x22ff4c, [fx("jump_boost", 90 * 20, 1)]),
    potion("fire_resistance", "Potion of Fire Resistance", 0xe49a3a, [fx("fire_resistance", 3 * MINUTE, 0)]),
    potion("long_fire_resistance", "Potion of Fire Resistance", 0xe49a3a, [fx("fire_resistance", 8 * MINUTE, 0)]),
    potion("swiftness", "Potion of Swiftness", 0x7cafc6, [fx("speed", 3 * MINUTE, 0)]),
    potion("long_swiftness", "Potion of Swiftness", 0x7cafc6, [fx("speed", 8 * MINUTE, 0)]),
    potion("strong_swiftness", "Potion of Swiftness II", 0x7cafc6, [fx("speed", 90 * 20, 1)]),
    potion("slowness", "Potion of Slowness", 0x5a6c81, [fx("slowness", 90 * 20, 0)]),
    potion("long_slowness", "Potion of Slowness", 0x5a6c81, [fx("slowness", 4 * MINUTE, 0)]),
    potion("strong_slowness", "Potion of Slowness IV", 0x5a6c81, [fx("slowness", 20 * 20, 3)]),
    potion("water_breathing", "Potion of Water Breathing", 0x2e5299, [fx("water_breathing", 3 * MINUTE, 0)]),
    potion("long_water_breathing", "Potion of Water Breathing", 0x2e5299, [fx("water_breathing", 8 * MINUTE, 0)]),
    potion("healing", "Potion of Healing", 0xf82423, [fx("instant_health", 1, 0)]),
    potion("strong_healing", "Potion of Healing II", 0xf82423, [fx("instant_health", 1, 1)]),
    potion("harming", "Potion of Harming", 0x430a09, [fx("instant_damage", 1, 0)]),
    potion("strong_harming", "Potion of Harming II", 0x430a09, [fx("instant_damage", 1, 1)]),
    potion("poison", "Potion of Poison", 0x4e9331, [fx("poison", 45 * 20, 0)]),
    potion("long_poison", "Potion of Poison", 0x4e9331, [fx("poison", 90 * 20, 0)]),
    potion("strong_poison", "Potion of Poison II", 0x4e9331, [fx("poison", 21 * 20 + 12, 1)]),
    potion("regeneration", "Potion of Regeneration", 0xcd5cab, [fx("regeneration", 45 * 20, 0)]),
    potion("long_regeneration", "Potion of Regeneration", 0xcd5cab, [fx("regeneration", 90 * 20, 0)]),
    potion("strong_regeneration", "Potion of Regeneration II", 0xcd5cab, [fx("regeneration", 22 * 20 + 10, 1)]),
    potion("strength", "Potion of Strength", 0xffc700, [fx("strength", 3 * MINUTE, 0)]),
    potion("long_strength", "Potion of Strength", 0xffc700, [fx("strength", 8 * MINUTE, 0)]),
    potion("strong_strength", "Potion of Strength II", 0xffc700, [fx("strength", 90 * 20, 1)]),
    potion("weakness", "Potion of Weakness", 0x484d48, [fx("weakness", 90 * 20, 0)]),
    potion("long_weakness", "Potion of Weakness", 0x484d48, [fx("weakness", 4 * MINUTE, 0)]),
    potion("slow_falling", "Potion of Slow Falling", 0xf3cfb9, [fx("slow_falling", 90 * 20, 0)]),
    potion("long_slow_falling", "Potion of Slow Falling", 0xf3cfb9, [fx("slow_falling", 4 * MINUTE, 0)]),
    potion("turtle_master", "Potion of the Turtle Master", 0x7691c9, [fx("slowness", 20 * 20, 3), fx("resistance", 20 * 20, 2)]),
    potion("long_turtle_master", "Potion of the Turtle Master", 0x7691c9, [fx("slowness", 40 * 20, 3), fx("resistance", 40 * 20, 2)]),
    potion("strong_turtle_master", "Potion of the Turtle Master II", 0x7691c9, [fx("slowness", 20 * 20, 5), fx("resistance", 20 * 20, 3)]),
]
public let POTION_BY_ID: [String: PotionDef] = Dictionary(uniqueKeysWithValues: POTIONS.map { ($0.id, $0) })
public func potionDef(_ id: String) -> PotionDef { POTION_BY_ID[id] ?? POTIONS[0] }

// brewing: base potion + ingredient → result
public struct BrewRecipe {
    public let base: String
    public let ingredient: String
    public let result: String
}
public let BREW_RECIPES: [BrewRecipe] = {
    var out: [BrewRecipe] = []
    func brew(_ base: String, _ ingredient: String, _ result: String) {
        out.append(BrewRecipe(base: base, ingredient: ingredient, result: result))
    }
    brew("water", "nether_wart", "awkward")
    brew("water", "glowstone_dust", "thick")
    brew("water", "redstone", "mundane")
    brew("water", "fermented_spider_eye", "weakness")
    brew("awkward", "golden_carrot", "night_vision")
    brew("awkward", "rabbit_foot", "leaping")
    brew("awkward", "magma_cream", "fire_resistance")
    brew("awkward", "sugar", "swiftness")
    brew("awkward", "pufferfish", "water_breathing")
    brew("awkward", "glistering_melon_slice", "healing")
    brew("awkward", "spider_eye", "poison")
    brew("awkward", "ghast_tear", "regeneration")
    brew("awkward", "blaze_powder", "strength")
    brew("awkward", "phantom_membrane", "slow_falling")
    brew("awkward", "turtle_helmet", "turtle_master")
    // corruptions
    brew("night_vision", "fermented_spider_eye", "invisibility")
    brew("long_night_vision", "fermented_spider_eye", "long_invisibility")
    brew("swiftness", "fermented_spider_eye", "slowness")
    brew("long_swiftness", "fermented_spider_eye", "long_slowness")
    brew("strong_swiftness", "fermented_spider_eye", "strong_slowness")
    brew("leaping", "fermented_spider_eye", "slowness")
    brew("healing", "fermented_spider_eye", "harming")
    brew("strong_healing", "fermented_spider_eye", "strong_harming")
    brew("poison", "fermented_spider_eye", "harming")
    brew("long_poison", "fermented_spider_eye", "harming")
    brew("strong_poison", "fermented_spider_eye", "strong_harming")
    // redstone extensions
    for p in ["night_vision", "invisibility", "leaping", "fire_resistance", "swiftness", "slowness", "water_breathing", "poison", "regeneration", "strength", "weakness", "slow_falling", "turtle_master"] {
        brew(p, "redstone", "long_\(p)")
    }
    // glowstone strengthening
    for p in ["leaping", "swiftness", "healing", "harming", "poison", "regeneration", "strength", "slowness", "turtle_master"] {
        brew(p, "glowstone_dust", "strong_\(p)")
    }
    return out
}()

public func findBrew(_ base: String, _ ingredient: String) -> String? {
    for r in BREW_RECIPES where r.base == base && r.ingredient == ingredient {
        return r.result
    }
    return nil
}
public func isBrewIngredient(_ item: String) -> Bool {
    if item == "gunpowder" || item == "dragon_breath" { return true }
    for r in BREW_RECIPES where r.ingredient == item { return true }
    return false
}
