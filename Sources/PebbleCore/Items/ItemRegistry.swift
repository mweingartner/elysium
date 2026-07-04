// Item registrations — registration order is frozen (ids persist in saves).
// Order mirrors baseline exactly for id parity with the golden baselines.

import Foundation

public let SHERDS = ["angler", "archer", "arms_up", "blade", "brewer", "burn", "danger", "explorer", "friend",
                     "heart", "heartbreak", "howl", "miner", "mourner", "plenty", "prize", "sheaf", "shelter", "skull", "snort"]
public let TRIM_PATTERNS = ["sentry", "dune", "coast", "wild", "ward", "eye", "vex", "tide", "snout", "rib",
                            "spire", "wayfinder", "shaper", "silence", "raiser", "host"]
public let SPAWN_EGG_MOBS = [
    "allay", "axolotl", "bat", "bee", "blaze", "camel", "cat", "cave_spider", "chicken", "cod",
    "cow", "creeper", "dolphin", "donkey", "drowned", "elder_guardian", "enderman", "endermite",
    "evoker", "fox", "frog", "ghast", "glow_squid", "goat", "guardian", "hoglin", "horse", "husk",
    "iron_golem", "llama", "magma_cube", "mooshroom", "mule", "ocelot", "panda", "parrot", "phantom",
    "pig", "piglin", "piglin_brute", "pillager", "polar_bear", "pufferfish", "rabbit", "ravager",
    "salmon", "sheep", "shulker", "silverfish", "skeleton", "skeleton_horse", "slime", "sniffer",
    "snow_golem", "spider", "squid", "stray", "strider", "tadpole", "tropical_fish", "turtle",
    "vex", "villager", "vindicator", "wandering_trader", "warden", "witch", "wither_skeleton",
    "wolf", "zoglin", "zombie", "zombie_villager", "zombified_piglin",
]

private var registered = false

private func matches(_ name: String, _ pattern: String) -> Bool {
    name.range(of: pattern, options: .regularExpression) != nil
}

public func registerAllItems() {
    if registered { return }
    registered = true
    precondition(!blockDefs.isEmpty, "registerAllBlocks() must run first")

    // ---- block items (auto) ----
    var skip: Set<String> = [
        "air", "cave_air", "void_air", "iron_door", "water", "lava", "fire", "soul_fire", "nether_portal",
        "end_portal", "end_gateway", "piston_head", "moving_piston", "bubble_column",
        "tall_seagrass", "kelp", "kelp_plant", "cave_vines", "cave_vines_plant", "bamboo_sapling",
        "wheat", "carrots", "potatoes", "beetroots", "torchflower_crop", "pitcher_crop",
        "melon_stem", "pumpkin_stem", "cocoa", "sweet_berry_bush", "nether_wart",
        "redstone_wire", "tripwire", "furnace_lit", "blast_furnace_lit", "smoker_lit",
        "redstone_torch_off", "repeater", "repeater_on", "comparator", "comparator_on",
        "redstone_lamp_on", "daylight_detector_inverted", "frosted_ice", "farmland", "dirt_path",
        "weeping_vines", "twisting_vines", "frogspawn", "snow", "sugar_cane",
        "big_dripleaf_stem", "powder_snow", "suspicious_sand", "suspicious_gravel",
    ]
    for w in WOODS {
        skip.insert("\(w)_wall_sign"); skip.insert("\(w)_sign")
        skip.insert("\(w)_hanging_sign"); skip.insert("\(w)_door")
    }
    for c in COLORS { skip.insert("\(c)_bed") }
    skip.insert("flower_pot")

    func categoryForBlock(_ name: String) -> String {
        if matches(name, "wool|carpet|concrete|terracotta|stained_glass|candle|shulker|_bed") { return "colored" }
        if matches(name, "sapling|leaves|flower|grass|fern|bush|mushroom|fungus|roots|vine|lichen|sprouts|kelp|pickle|coral|dirt|sand|gravel|stone$|ore|log|stem$|pumpkin|melon|cactus|bamboo$|moss|petals|dripleaf|blossom|azalea|nylium|wart_block|shroomlight|froglight|sculk|egg|ice|snow") { return "natural" }
        if matches(name, "piston|observer|dispenser|dropper|hopper|rail|redstone|lever|button|plate|tripwire|daylight|target|tnt|note_block|comparator|repeater|sensor") { return "redstone" }
        if matches(name, "table|furnace|smoker|chest|barrel|anvil|grindstone|stonecutter|composter|cauldron|brewing|jukebox|lectern|bell|ladder|scaffold|torch|lantern|campfire|beacon|conduit|lodestone|anchor|bookshelf|bee|sign|pot$") { return "functional" }
        return "building"
    }
    func burnTimeForBlock(_ name: String) -> Int {
        if matches(name, "planks|log$|_wood$|hyphae|bamboo_block|mosaic") && !matches(name, "crimson|warped") { return 300 }
        if matches(name, "sapling") { return 100 }
        if name == "coal_block" { return 16000 }
        if name == "bookshelf" { return 300 }
        if matches(name, "^(oak|spruce|birch|jungle|acacia|dark_oak|mangrove|cherry|bamboo)_(fence|fence_gate|stairs|slab|trapdoor|button|pressure_plate)$") {
            return matches(name, "slab") ? 150 : 300
        }
        if ["crafting_table", "cartography_table", "fletching_table", "smithing_table", "loom", "composter", "barrel", "chest", "trapped_chest"].contains(name) { return 300 }
        if name == "dried_kelp_block" { return 4000 }
        if matches(name, "ladder|bowl") { return 300 }
        return 0
    }
    func compostForBlock(_ name: String) -> Double {
        if matches(name, "leaves|sapling|grass$|fern|flower|tulip|daisy|orchid|allium|bluet|dandelion|poppy|cornflower|lily_of|azalea") { return 0.3 }
        if matches(name, "pumpkin$|melon$|moss_block|sea_pickle|cactus") { return 0.65 }
        if matches(name, "hay_block|mushroom_block") { return 0.85 }
        if name == "cake" { return 1 }
        return 0
    }
    for bdef in blockDefs {
        if skip.contains(bdef.name) { continue }
        registerItem(bdef.name, display: bdef.displayName, block: UInt16(bdef.id),
                     category: categoryForBlock(bdef.name),
                     burnTime: burnTimeForBlock(bdef.name),
                     compostChance: compostForBlock(bdef.name))
    }

    // ---- special placers ----
    registerItem("wheat_seeds", block: B.wheat, category: "natural", icon: "wheat_seeds", compostChance: 0.3)
    registerItem("beetroot_seeds", block: B.beetroots, category: "natural", icon: "beetroot_seeds", compostChance: 0.3)
    registerItem("melon_seeds", block: B.melon_stem, category: "natural", icon: "melon_seeds", compostChance: 0.3)
    registerItem("pumpkin_seeds", block: B.pumpkin_stem, category: "natural", icon: "pumpkin_seeds", compostChance: 0.3)
    registerItem("torchflower_seeds", block: B.torchflower_crop, category: "natural", icon: "torchflower_seeds", compostChance: 0.3)
    registerItem("pitcher_pod", block: B.pitcher_crop, category: "natural", icon: "pitcher_pod", compostChance: 0.3)
    registerItem("cocoa_beans", block: B.cocoa, category: "natural", icon: "cocoa_beans", compostChance: 0.65)
    registerItem("sugar_cane", block: B.sugar_cane, category: "natural", icon: "sugar_cane", compostChance: 0.5)
    registerItem("kelp", block: B.kelp, category: "natural", icon: "kelp", burnTime: 200, compostChance: 0.3)
    registerItem("redstone", block: B.redstone_wire, category: "redstone", icon: "redstone")
    registerItem("string", block: B.tripwire, category: "ingredients", icon: "string")
    registerItem("snowball", maxStack: 16, category: "natural", icon: "snowball")
    registerItem("repeater", block: B.repeater, category: "redstone", icon: "repeater_item")
    registerItem("comparator", block: B.comparator, category: "redstone", icon: "comparator_item")
    registerItem("glow_berries", block: B.cave_vines, food: FoodDef(hunger: 2, saturation: 0.4), category: "food", icon: "glow_berries", compostChance: 0.3)
    registerItem("sweet_berries", block: B.sweet_berry_bush, food: FoodDef(hunger: 2, saturation: 0.4), category: "food", icon: "sweet_berries", compostChance: 0.3)
    registerItem("flower_pot", block: B.flower_pot, category: "functional", icon: "flower_pot_item")
    for w in WOODS {
        registerItem("\(w)_door", block: B["\(w)_door"], category: "building", icon: "\(w)_door_item", burnTime: (w == "crimson" || w == "warped") ? 0 : 200)
        registerItem("\(w)_sign", maxStack: 16, block: B["\(w)_sign"], category: "functional", icon: "\(w)_sign_item", burnTime: (w == "crimson" || w == "warped") ? 0 : 200)
        registerItem("\(w)_hanging_sign", maxStack: 16, block: B["\(w)_hanging_sign"], category: "functional", icon: "\(w)_hanging_sign_item", burnTime: (w == "crimson" || w == "warped") ? 0 : 200)
    }
    for c in COLORS {
        registerItem("\(c)_bed", maxStack: 1, block: B["\(c)_bed"], category: "colored", icon: "\(c)_bed_item")
    }
    registerItem("iron_door", block: B.iron_door, category: "redstone", icon: "iron_door_item")
    registerItem("snow", block: B.snow, category: "natural", icon: "block")

    // ---- tools ----
    struct TierSpec {
        let tier: Int; let speed: Double; let dur: Int; let ench: Int
        let swordDmg: Double; let pickDmg: Double; let axeDmg: Double; let axeSpd: Double
        let shovelDmg: Double; let hoeSpd: Double
    }
    let tierOrder = ["wooden", "stone", "iron", "golden", "diamond", "netherite"]
    let TIERS: [String: TierSpec] = [
        "wooden": TierSpec(tier: 0, speed: 2, dur: 59, ench: 15, swordDmg: 3, pickDmg: 1, axeDmg: 6, axeSpd: 0.8, shovelDmg: 1.5, hoeSpd: 1),
        "stone": TierSpec(tier: 1, speed: 4, dur: 131, ench: 5, swordDmg: 4, pickDmg: 2, axeDmg: 8, axeSpd: 0.8, shovelDmg: 2.5, hoeSpd: 2),
        "iron": TierSpec(tier: 2, speed: 6, dur: 250, ench: 14, swordDmg: 5, pickDmg: 3, axeDmg: 8, axeSpd: 0.9, shovelDmg: 3.5, hoeSpd: 3),
        "golden": TierSpec(tier: 0, speed: 12, dur: 32, ench: 22, swordDmg: 3, pickDmg: 1, axeDmg: 6, axeSpd: 1.0, shovelDmg: 1.5, hoeSpd: 1),
        "diamond": TierSpec(tier: 3, speed: 8, dur: 1561, ench: 10, swordDmg: 6, pickDmg: 4, axeDmg: 8, axeSpd: 1.0, shovelDmg: 4.5, hoeSpd: 4),
        "netherite": TierSpec(tier: 4, speed: 9, dur: 2031, ench: 15, swordDmg: 7, pickDmg: 5, axeDmg: 9, axeSpd: 1.0, shovelDmg: 5.5, hoeSpd: 4),
    ]
    for mat in tierOrder {
        let t = TIERS[mat]!
        let burn = mat == "wooden" ? 200 : 0
        registerItem("\(mat)_sword", tool: ToolDef("sword", tier: t.tier, speed: 1.5, attackDamage: t.swordDmg, attackSpeed: 1.6, durability: t.dur, enchantability: t.ench), category: "combat", burnTime: burn)
        registerItem("\(mat)_pickaxe", tool: ToolDef("pickaxe", tier: t.tier, speed: t.speed, attackDamage: t.pickDmg, attackSpeed: 1.2, durability: t.dur, enchantability: t.ench), category: "tools", burnTime: burn)
        registerItem("\(mat)_axe", tool: ToolDef("axe", tier: t.tier, speed: t.speed, attackDamage: t.axeDmg, attackSpeed: t.axeSpd, durability: t.dur, enchantability: t.ench), category: "tools", burnTime: burn)
        registerItem("\(mat)_shovel", tool: ToolDef("shovel", tier: t.tier, speed: t.speed, attackDamage: t.shovelDmg, attackSpeed: 1, durability: t.dur, enchantability: t.ench), category: "tools", burnTime: burn)
        registerItem("\(mat)_hoe", tool: ToolDef("hoe", tier: t.tier, speed: t.speed, attackDamage: 1, attackSpeed: t.hoeSpd, durability: t.dur, enchantability: t.ench), category: "tools", burnTime: burn)
    }
    registerItem("shears", tool: ToolDef("shears", tier: 0, speed: 1.5, attackDamage: 0, attackSpeed: 4, durability: 238, enchantability: 1), category: "tools")
    registerItem("flint_and_steel", tool: ToolDef("flint_and_steel", tier: 0, speed: 1, attackDamage: 0, attackSpeed: 4, durability: 64, enchantability: 1), category: "tools")
    registerItem("fishing_rod", tool: ToolDef("fishing_rod", tier: 0, speed: 1, attackDamage: 0, attackSpeed: 4, durability: 64, enchantability: 1), category: "tools", burnTime: 300)
    registerItem("bow", tool: ToolDef("bow", tier: 0, speed: 1, attackDamage: 0, attackSpeed: 4, durability: 384, enchantability: 1), category: "combat", burnTime: 300)
    registerItem("crossbow", tool: ToolDef("crossbow", tier: 0, speed: 1, attackDamage: 0, attackSpeed: 4, durability: 465, enchantability: 1), category: "combat", burnTime: 300)
    registerItem("trident", tool: ToolDef("trident", tier: 0, speed: 1, attackDamage: 8, attackSpeed: 1.1, durability: 250, enchantability: 1), category: "combat")
    registerItem("brush", tool: ToolDef("brush", tier: 0, speed: 1, attackDamage: 0, attackSpeed: 4, durability: 64, enchantability: 1), category: "tools")

    // ---- armor ----
    struct ArmorMat {
        let name: String; let def: [Int]; let tough: Double; let kb: Double; let dur: [Int]; let ench: Int
    }
    let ARMORS: [ArmorMat] = [
        ArmorMat(name: "leather", def: [1, 3, 2, 1], tough: 0, kb: 0, dur: [56, 81, 76, 66], ench: 15),
        ArmorMat(name: "chainmail", def: [2, 5, 4, 1], tough: 0, kb: 0, dur: [166, 241, 226, 196], ench: 12),
        ArmorMat(name: "iron", def: [2, 6, 5, 2], tough: 0, kb: 0, dur: [166, 241, 226, 196], ench: 9),
        ArmorMat(name: "golden", def: [2, 5, 3, 1], tough: 0, kb: 0, dur: [78, 113, 106, 92], ench: 25),
        ArmorMat(name: "diamond", def: [3, 8, 6, 3], tough: 2, kb: 0, dur: [364, 529, 496, 430], ench: 10),
        ArmorMat(name: "netherite", def: [3, 8, 6, 3], tough: 3, kb: 0.1, dur: [408, 593, 556, 482], ench: 15),
    ]
    let SLOT_NAMES = ["helmet", "chestplate", "leggings", "boots"]
    for a in ARMORS {
        for s in 0..<4 {
            registerItem("\(a.name)_\(SLOT_NAMES[s])",
                         armor: ArmorDef(slot: s, defense: a.def[s], toughness: a.tough, knockbackRes: a.kb, durability: a.dur[s], enchantability: a.ench, material: a.name),
                         category: "combat")
        }
    }
    registerItem("turtle_helmet", armor: ArmorDef(slot: 0, defense: 2, toughness: 0, knockbackRes: 0, durability: 275, enchantability: 9, material: "turtle"), category: "combat")
    registerItem("elytra", armor: ArmorDef(slot: 1, defense: 0, toughness: 0, knockbackRes: 0, durability: 432, enchantability: 1, material: "elytra"), category: "combat", rarity: 2)
    registerItem("shield", maxStack: 1, category: "combat", icon: "shield")

    // ---- food ----
    @discardableResult
    func food(_ name: String, _ hunger: Int, _ sat: Double, display: String? = nil, maxStack: Int? = nil,
              alwaysEat: Bool = false, meat: Bool = false, fast: Bool = false,
              effects: [(effect: String, duration: Int, amplifier: Int, chance: Double)] = [],
              rarity: Int = 0, compostChance: Double = 0) -> Int {
        registerItem(name, display: display, maxStack: maxStack,
                     food: FoodDef(hunger: hunger, saturation: sat, alwaysEat: alwaysEat, meat: meat, fast: fast, effects: effects),
                     category: "food", rarity: rarity, compostChance: compostChance)
    }
    food("apple", 4, 2.4, compostChance: 0.65)
    food("golden_apple", 4, 9.6, alwaysEat: true, effects: [("regeneration", 100, 1, 1), ("absorption", 2400, 0, 1)], rarity: 1)
    food("enchanted_golden_apple", 4, 9.6, alwaysEat: true, effects: [("regeneration", 400, 1, 1), ("resistance", 6000, 0, 1), ("fire_resistance", 6000, 0, 1), ("absorption", 2400, 3, 1)], rarity: 3)
    food("bread", 5, 6, compostChance: 0.85)
    food("cookie", 2, 0.4, compostChance: 0.85)
    food("melon_slice", 2, 1.2, compostChance: 0.5)
    food("dried_kelp", 1, 0.6, fast: true, compostChance: 0.3)
    food("beef", 3, 1.8, display: "Raw Beef", meat: true)
    food("cooked_beef", 8, 12.8, display: "Steak", meat: true)
    food("porkchop", 3, 1.8, display: "Raw Porkchop", meat: true)
    food("cooked_porkchop", 8, 12.8, meat: true)
    food("mutton", 2, 1.2, display: "Raw Mutton", meat: true)
    food("cooked_mutton", 6, 9.6, meat: true)
    food("chicken", 2, 1.2, display: "Raw Chicken", meat: true, effects: [("hunger", 600, 0, 0.3)])
    food("cooked_chicken", 6, 7.2, meat: true)
    food("rabbit", 3, 1.8, display: "Raw Rabbit", meat: true)
    food("cooked_rabbit", 5, 6, meat: true)
    food("cod", 2, 0.4, display: "Raw Cod")
    food("cooked_cod", 5, 6)
    food("salmon", 2, 0.4, display: "Raw Salmon")
    food("cooked_salmon", 6, 9.6)
    food("tropical_fish", 1, 0.2)
    food("pufferfish", 1, 0.2, effects: [("poison", 1200, 1, 1), ("hunger", 300, 2, 1), ("nausea", 300, 0, 1)])
    food("carrot", 3, 3.6, compostChance: 0.65)
    food("golden_carrot", 6, 14.4)
    food("potato", 1, 0.6, compostChance: 0.65)
    food("baked_potato", 5, 6, compostChance: 0.85)
    food("poisonous_potato", 2, 1.2, effects: [("poison", 100, 0, 0.6)])
    food("beetroot", 1, 1.2, compostChance: 0.65)
    food("beetroot_soup", 6, 7.2, maxStack: 1)
    food("mushroom_stew", 6, 7.2, maxStack: 1)
    food("rabbit_stew", 10, 12, maxStack: 1)
    food("suspicious_stew", 6, 7.2, maxStack: 1, alwaysEat: true)
    food("pumpkin_pie", 8, 4.8, compostChance: 1)
    food("rotten_flesh", 4, 0.8, meat: true, effects: [("hunger", 600, 0, 0.8)])
    food("spider_eye", 2, 3.2, effects: [("poison", 100, 0, 1)])
    food("chorus_fruit", 4, 2.4, alwaysEat: true)
    food("honey_bottle", 6, 1.2, maxStack: 16)
    food("milk_bucket", 0, 0, maxStack: 1, alwaysEat: true)

    // ---- materials & misc ----
    registerItem("stick", category: "ingredients", burnTime: 100)
    registerItem("coal", category: "ingredients", burnTime: 1600)
    registerItem("charcoal", category: "ingredients", burnTime: 1600)
    for n in ["raw_iron", "iron_ingot", "iron_nugget", "raw_copper", "copper_ingot", "raw_gold", "gold_ingot", "gold_nugget",
              "diamond", "emerald", "lapis_lazuli", "quartz"] {
        registerItem(n, category: "ingredients")
    }
    registerItem("netherite_scrap", category: "ingredients", rarity: 1)
    registerItem("netherite_ingot", category: "ingredients", rarity: 1)
    registerItem("amethyst_shard", category: "ingredients")
    registerItem("echo_shard", category: "ingredients", rarity: 1)
    for n in ["flint", "clay_ball", "brick", "nether_brick", "bone", "bone_meal", "leather", "rabbit_hide", "feather"] {
        registerItem(n, category: "ingredients")
    }
    registerItem("egg", maxStack: 16, category: "ingredients")
    registerItem("gunpowder", category: "ingredients")
    registerItem("blaze_rod", category: "ingredients", burnTime: 2400)
    registerItem("blaze_powder", category: "ingredients")
    registerItem("ender_pearl", maxStack: 16, category: "ingredients")
    registerItem("ender_eye", display: "Eye of Ender", maxStack: 64, category: "ingredients")
    for n in ["ghast_tear", "slime_ball", "magma_cream", "fermented_spider_eye", "glistering_melon_slice",
              "rabbit_foot", "phantom_membrane", "shulker_shell", "nautilus_shell"] {
        registerItem(n, category: "ingredients")
    }
    registerItem("heart_of_the_sea", category: "ingredients", rarity: 1)
    registerItem("dragon_breath", maxStack: 64, category: "ingredients", rarity: 1)
    registerItem("nether_star", category: "ingredients", rarity: 1)
    for n in ["prismarine_shard", "prismarine_crystals", "ink_sac", "glow_ink_sac", "scute", "honeycomb"] {
        registerItem(n, category: "ingredients")
    }
    registerItem("wheat", category: "ingredients", compostChance: 0.65)
    for n in ["sugar", "paper", "book"] { registerItem(n, category: "ingredients") }
    registerItem("writable_book", maxStack: 1, category: "ingredients")
    registerItem("glass_bottle", category: "ingredients")
    registerItem("experience_bottle", display: "Bottle o' Enchanting", category: "ingredients", rarity: 1)
    registerItem("glowstone_dust", category: "ingredients")
    registerItem("fire_charge", category: "ingredients")
    registerItem("bowl", category: "ingredients", burnTime: 100)
    for n in ["arrow", "spectral_arrow", "tipped_arrow"] { registerItem(n, category: "ingredients") }
    registerItem("saddle", maxStack: 1, category: "ingredients")
    registerItem("lead", category: "ingredients")
    registerItem("name_tag", category: "ingredients")
    registerItem("totem_of_undying", maxStack: 1, category: "ingredients", rarity: 1)
    registerItem("recovery_compass", category: "ingredients", rarity: 1)
    registerItem("compass", category: "ingredients")
    registerItem("clock", category: "ingredients")
    registerItem("spyglass", maxStack: 1, category: "ingredients")
    registerItem("goat_horn", maxStack: 1, category: "ingredients")

    // dyes
    for c in COLORS { registerItem("\(c)_dye", category: "ingredients") }

    // buckets
    registerItem("bucket", maxStack: 16, category: "tools")
    registerItem("water_bucket", maxStack: 1, category: "tools")
    registerItem("lava_bucket", maxStack: 1, category: "tools", burnTime: 20000)
    registerItem("powder_snow_bucket", maxStack: 1, category: "tools")
    for n in ["cod_bucket", "salmon_bucket", "pufferfish_bucket", "tropical_fish_bucket", "axolotl_bucket", "tadpole_bucket"] {
        registerItem(n, maxStack: 1, category: "tools")
    }

    registerItem("nether_wart", block: B.nether_wart, category: "ingredients", icon: "nether_wart")
    registerItem("popped_chorus_fruit", category: "ingredients")
    registerItem("end_crystal", category: "combat", icon: "end_crystal", rarity: 2)
    registerItem("enchanted_book", maxStack: 1, category: "ingredients", rarity: 1)
    for n in ["leather_horse_armor", "iron_horse_armor", "golden_horse_armor", "diamond_horse_armor"] {
        registerItem(n, maxStack: 1, category: "combat")
    }
    registerItem("carrot_on_a_stick", maxStack: 1, category: "tools")
    registerItem("warped_fungus_on_a_stick", maxStack: 1, category: "tools")

    // potions
    registerItem("potion", maxStack: 1, category: "food", icon: "potion")
    registerItem("splash_potion", maxStack: 1, category: "food", icon: "splash_potion")
    registerItem("lingering_potion", maxStack: 1, category: "food", icon: "lingering_potion")

    // boats & minecarts
    for w in ["oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry"] {
        registerItem("\(w)_boat", maxStack: 1, category: "tools", icon: "\(w)_boat")
        registerItem("\(w)_chest_boat", maxStack: 1, category: "tools", icon: "\(w)_chest_boat")
    }
    registerItem("bamboo_raft", maxStack: 1, category: "tools", icon: "bamboo_raft")
    registerItem("bamboo_chest_raft", maxStack: 1, category: "tools", icon: "bamboo_chest_raft")
    for n in ["minecart", "chest_minecart", "furnace_minecart", "hopper_minecart", "tnt_minecart"] {
        registerItem(n, maxStack: 1, category: "tools")
    }

    // fireworks
    registerItem("firework_rocket", category: "tools")
    registerItem("firework_star", category: "ingredients")

    // music discs
    registerItem("music_disc_wander", display: "Music Disc - Wander", maxStack: 1, category: "tools", rarity: 2)
    registerItem("music_disc_aurora", display: "Music Disc - Aurora", maxStack: 1, category: "tools", rarity: 2)
    registerItem("music_disc_descent", display: "Music Disc - Descent", maxStack: 1, category: "tools", rarity: 2)

    // sherds + smithing templates
    for s in SHERDS { registerItem("\(s)_pottery_sherd", category: "ingredients", icon: "pottery_sherd", rarity: 1) }
    for t in TRIM_PATTERNS {
        registerItem("\(t)_armor_trim", display: prettify(t) + " Armor Trim Smithing Template", category: "ingredients", icon: "smithing_template", rarity: 1)
    }
    registerItem("netherite_upgrade", display: "Netherite Upgrade Smithing Template", category: "ingredients", icon: "smithing_template", rarity: 1)

    // spawn eggs
    for m in SPAWN_EGG_MOBS { registerItem("\(m)_spawn_egg", category: "spawn_eggs", icon: "spawn_egg") }

    // appended LATE so every earlier id stays stable — these blocks were on
    // the no-item skip list while their drop fns referenced the item names,
    // making the blocks silently unobtainable
    registerItem("weeping_vines", block: B.weeping_vines, category: "natural")
    registerItem("twisting_vines", block: B.twisting_vines, category: "natural")
    registerItem("flying_wand", display: "Flying Wand",
                 tool: ToolDef("sword", tier: 3, speed: 1.5, attackDamage: 6, attackSpeed: 1.6, durability: 1561, enchantability: 10),
                 category: "combat", icon: "torch")

    // post-registration fixups
    itemDefs[iid("cake")].maxStack = 1
}
