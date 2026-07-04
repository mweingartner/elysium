// Every crafting, smelting, stonecutting and smithing recipe — Ingredients are item names; '#name' references a tag.
// Registration order matters for golden parity.

import Foundation

public enum CraftRecipe {
    case shaped(w: Int, h: Int, grid: [String?], out: String, count: Int)
    case shapeless(inputs: [String], out: String, count: Int)
}

public struct SmeltRecipe {
    public let input: String
    public let output: String
    public let xp: Double
    public let kind: String // any | blast | smoke
}
public struct StonecutRecipe {
    public let input: String
    public let output: String
    public let count: Int
}
public struct SmithRecipe {
    public let template: String
    public let base: String
    public let addition: String
    public let output: String // item name or 'trim'
}

public var craftingRecipes: [CraftRecipe] = []
public var smeltingRecipes: [SmeltRecipe] = []
public var stonecuttingRecipes: [StonecutRecipe] = []
public var smithingRecipes: [SmithRecipe] = []
public var TAGS: [String: [String]] = [:]

public func tagMatches(_ tag: String, _ itemNm: String) -> Bool {
    TAGS[tag]?.contains(itemNm) ?? false
}

public let TRIM_MATERIALS = ["iron_ingot", "copper_ingot", "gold_ingot", "lapis_lazuli", "emerald", "diamond", "netherite_ingot", "redstone", "amethyst_shard", "quartz"]

private func shaped(_ pattern: String, _ key: [Character: String], _ out: String, _ count: Int = 1) {
    let rows = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    let h = rows.count
    let w = rows.map { $0.count }.max() ?? 0
    var grid: [String?] = []
    for y in 0..<h {
        let chars = Array(rows[y])
        for x in 0..<w {
            let ch: Character = x < chars.count ? chars[x] : " "
            if ch == " " { grid.append(nil); continue }
            guard let ing = key[ch] else { fatalError("recipe \(out): no key for '\(ch)'") }
            grid.append(ing)
        }
    }
    craftingRecipes.append(.shaped(w: w, h: h, grid: grid, out: out, count: count))
}
private func shapeless(_ inputs: [String], _ out: String, _ count: Int = 1) {
    craftingRecipes.append(.shapeless(inputs: inputs, out: out, count: count))
}
private func smelt(_ input: String, _ output: String, _ xp: Double, _ kind: String = "any") {
    smeltingRecipes.append(SmeltRecipe(input: input, output: output, xp: xp, kind: kind))
}
private func cut(_ input: String, _ output: String, _ count: Int = 1) {
    stonecuttingRecipes.append(StonecutRecipe(input: input, output: output, count: count))
}

private func stoneSet(_ fam: String, _ base: String, stairs: Bool = true, wall: Bool = true) {
    if stairs && itemExists("\(fam)_stairs") {
        shaped("X  /XX /XXX", ["X": base], "\(fam)_stairs", 4)
        cut(base, "\(fam)_stairs")
    }
    if itemExists("\(fam)_slab") {
        shaped("XXX", ["X": base], "\(fam)_slab", 6)
        cut(base, "\(fam)_slab", 2)
    }
    if wall && itemExists("\(fam)_wall") {
        shaped("XXX/XXX", ["X": base], "\(fam)_wall", 6)
        cut(base, "\(fam)_wall")
    }
}

private var recipesRegistered = false
public func registerAllRecipes() {
    if recipesRegistered { return }
    recipesRegistered = true

    // --- tags ---
    TAGS = [
        "planks": WOODS.map { "\($0)_planks" },
        "logs": [],
        "wool": COLORS.map { "\($0)_wool" },
        "wooden_slabs": WOODS.map { "\($0)_slab" },
        "stone_crafting": ["cobblestone", "cobbled_deepslate", "blackstone"],
        "coals": ["coal", "charcoal"],
        "soul_fire_base": ["soul_sand", "soul_soil"],
        "fishes": ["cod", "salmon", "tropical_fish", "pufferfish"],
    ]
    for w in WOODS {
        if w == "bamboo" {
            TAGS["bamboo_logs"] = ["bamboo_block", "stripped_bamboo_block"]
            continue
        }
        let log = (w == "crimson" || w == "warped") ? "\(w)_stem" : "\(w)_log"
        let woodB = (w == "crimson" || w == "warped") ? "\(w)_hyphae" : "\(w)_wood"
        TAGS["\(w)_logs"] = [log, woodB, "stripped_\(log)", "stripped_\(woodB)"]
        TAGS["logs"]!.append(contentsOf: TAGS["\(w)_logs"]!)
    }
    TAGS["logs_that_burn"] = TAGS["logs"]!.filter { !$0.contains("crimson") && !$0.contains("warped") }

    // --- wood ---
    for w in WOODS {
        let planks = "\(w)_planks"
        if w == "bamboo" {
            shaped("BBB/BBB/BBB", ["B": "bamboo"], "bamboo_block")
            shapeless(["#bamboo_logs"], "bamboo_planks", 2)
            shaped("S/S", ["S": "bamboo_slab"], "bamboo_mosaic")
            shaped("X  /XX /XXX", ["X": "bamboo_mosaic"], "bamboo_mosaic_stairs", 4)
            shaped("XXX", ["X": "bamboo_mosaic"], "bamboo_mosaic_slab", 6)
            shaped("P P/PPP", ["P": planks], "bamboo_raft")
            shapeless(["bamboo_raft", "chest"], "bamboo_chest_raft")
        } else {
            shapeless(["#\(w)_logs"], planks, 4)
            let log = (w == "crimson" || w == "warped") ? "\(w)_stem" : "\(w)_log"
            let woodB = (w == "crimson" || w == "warped") ? "\(w)_hyphae" : "\(w)_wood"
            shaped("LL/LL", ["L": log], woodB, 3)
            shaped("LL/LL", ["L": "stripped_\(log)"], "stripped_\(woodB)", 3)
            if w != "crimson" && w != "warped" {
                shaped("P P/PPP", ["P": planks], "\(w)_boat")
                shapeless(["\(w)_boat", "chest"], "\(w)_chest_boat")
            }
        }
        shaped("X  /XX /XXX", ["X": planks], "\(w)_stairs", 4)
        shaped("XXX", ["X": planks], "\(w)_slab", 6)
        shaped("PSP/PSP", ["P": planks, "S": "stick"], "\(w)_fence", 3)
        shaped("SPS/SPS", ["P": planks, "S": "stick"], "\(w)_fence_gate")
        shaped("PP/PP/PP", ["P": planks], "\(w)_door", 3)
        shaped("PPP/PPP", ["P": planks], "\(w)_trapdoor", 2)
        shapeless([planks], "\(w)_button")
        shaped("PP", ["P": planks], "\(w)_pressure_plate")
        shaped("PPP/PPP/ S ", ["P": planks, "S": "stick"], "\(w)_sign", 3)
        let stripped = w == "bamboo" ? "stripped_bamboo_block" : ((w == "crimson" || w == "warped") ? "stripped_\(w)_stem" : "stripped_\(w)_log")
        shaped("C C/SSS/SSS", ["C": "chain", "S": stripped], "\(w)_hanging_sign", 6)
    }
    shaped("PP/PP", ["P": "#planks"], "crafting_table")
    shaped("S/S", ["S": "#planks"], "stick", 4)
    shaped("P P/P P/PPP", ["P": "#planks"], "ladder", 3)
    shaped("PPP/P P/PPP", ["P": "#planks"], "chest")
    shaped("PSP/P P/PSP", ["P": "#planks", "S": "#wooden_slabs"], "barrel")
    shaped("P P/PPP", ["P": "#planks"], "bowl", 4)
    shapeless(["chest", "tripwire_hook"], "trapped_chest")
    shaped("PPP/BBB/PPP", ["P": "#planks", "B": "book"], "bookshelf")
    shaped("PPP/SSS/PPP", ["P": "#planks", "S": "#wooden_slabs"], "chiseled_bookshelf")
    shaped("SSS/ B /SSS", ["S": "#wooden_slabs", "B": "bookshelf"], "lectern")

    // --- stone & building ---
    stoneSet("cobblestone", "cobblestone")
    stoneSet("mossy_cobblestone", "mossy_cobblestone")
    stoneSet("stone", "stone")
    stoneSet("smooth_stone", "smooth_stone", stairs: false, wall: false)
    stoneSet("stone_brick", "stone_bricks")
    stoneSet("mossy_stone_brick", "mossy_stone_bricks")
    stoneSet("granite", "granite")
    stoneSet("polished_granite", "polished_granite", wall: false)
    stoneSet("diorite", "diorite")
    stoneSet("polished_diorite", "polished_diorite", wall: false)
    stoneSet("andesite", "andesite")
    stoneSet("polished_andesite", "polished_andesite", wall: false)
    stoneSet("cobbled_deepslate", "cobbled_deepslate")
    stoneSet("polished_deepslate", "polished_deepslate")
    stoneSet("deepslate_brick", "deepslate_bricks")
    stoneSet("deepslate_tile", "deepslate_tiles")
    stoneSet("brick", "bricks")
    stoneSet("mud_brick", "mud_bricks")
    stoneSet("sandstone", "sandstone")
    stoneSet("smooth_sandstone", "smooth_sandstone", wall: false)
    stoneSet("cut_sandstone", "cut_sandstone", stairs: false, wall: false)
    stoneSet("red_sandstone", "red_sandstone")
    stoneSet("smooth_red_sandstone", "smooth_red_sandstone", wall: false)
    stoneSet("cut_red_sandstone", "cut_red_sandstone", stairs: false, wall: false)
    stoneSet("prismarine", "prismarine")
    stoneSet("prismarine_brick", "prismarine_bricks", wall: false)
    stoneSet("dark_prismarine", "dark_prismarine", wall: false)
    stoneSet("nether_brick", "nether_bricks")
    stoneSet("red_nether_brick", "red_nether_bricks")
    stoneSet("blackstone", "blackstone")
    stoneSet("polished_blackstone", "polished_blackstone")
    stoneSet("polished_blackstone_brick", "polished_blackstone_bricks")
    stoneSet("end_stone_brick", "end_stone_bricks")
    stoneSet("purpur", "purpur_block", wall: false)
    stoneSet("quartz", "quartz_block", wall: false)
    stoneSet("smooth_quartz", "smooth_quartz", wall: false)
    stoneSet("tuff", "tuff")

    shaped("XX/XX", ["X": "stone"], "stone_bricks", 4)
    shaped("XX/XX", ["X": "cobbled_deepslate"], "polished_deepslate", 4)
    shaped("XX/XX", ["X": "polished_deepslate"], "deepslate_bricks", 4)
    shaped("XX/XX", ["X": "deepslate_bricks"], "deepslate_tiles", 4)
    shaped("XX/XX", ["X": "blackstone"], "polished_blackstone", 4)
    shaped("XX/XX", ["X": "polished_blackstone"], "polished_blackstone_bricks", 4)
    shaped("XX/XX", ["X": "granite"], "polished_granite", 4)
    shaped("XX/XX", ["X": "diorite"], "polished_diorite", 4)
    shaped("XX/XX", ["X": "andesite"], "polished_andesite", 4)
    shapeless(["diorite", "cobblestone"], "andesite", 2)
    shapeless(["diorite", "quartz"], "granite")
    shapeless(["cobblestone", "quartz"], "diorite", 2)
    shapeless(["cobblestone", "vine"], "mossy_cobblestone")
    shapeless(["cobblestone", "moss_block"], "mossy_cobblestone")
    shapeless(["stone_bricks", "vine"], "mossy_stone_bricks")
    shapeless(["stone_bricks", "moss_block"], "mossy_stone_bricks")
    shaped("S/S", ["S": "stone_brick_slab"], "chiseled_stone_bricks")
    shaped("S/S", ["S": "sandstone_slab"], "chiseled_sandstone")
    shaped("S/S", ["S": "red_sandstone_slab"], "chiseled_red_sandstone")
    shaped("S/S", ["S": "cobbled_deepslate_slab"], "chiseled_deepslate")
    shaped("S/S", ["S": "nether_brick_slab"], "chiseled_nether_bricks")
    shaped("S/S", ["S": "polished_blackstone_slab"], "chiseled_polished_blackstone")
    shaped("S/S", ["S": "quartz_slab"], "chiseled_quartz_block")
    shaped("S/S", ["S": "purpur_slab"], "purpur_pillar")
    shaped("XX/XX", ["X": "sand"], "sandstone")
    shaped("XX/XX", ["X": "red_sand"], "red_sandstone")
    shaped("XX/XX", ["X": "sandstone"], "cut_sandstone", 4)
    shaped("XX/XX", ["X": "red_sandstone"], "cut_red_sandstone", 4)
    shaped("XX/XX", ["X": "brick"], "bricks")
    shaped("XX/XX", ["X": "nether_brick"], "nether_bricks")
    shaped("NW/WN", ["N": "nether_brick", "W": "nether_wart"], "red_nether_bricks")
    shaped("XX/XX", ["X": "packed_mud"], "mud_bricks", 4)
    shapeless(["mud", "wheat"], "packed_mud")
    shapeless(["mud", "mangrove_roots"], "muddy_mangrove_roots")
    shaped("XX/XX", ["X": "quartz"], "quartz_block")
    shaped("XX/XX", ["X": "quartz_block"], "quartz_bricks", 4)
    shaped("X/X", ["X": "quartz_block"], "quartz_pillar", 2)
    shaped("XX/XX", ["X": "end_stone"], "end_stone_bricks", 4)
    shaped("XX/XX", ["X": "popped_chorus_fruit"], "purpur_block", 4)
    shaped("X/X", ["X": "basalt"], "polished_basalt", 2)
    shaped("DG/GD", ["D": "dirt", "G": "gravel"], "coarse_dirt", 4)
    shaped("XXX/XXX/XXX", ["X": "melon_slice"], "melon")
    shapeless(["pumpkin"], "pumpkin_seeds", 4)
    shapeless(["melon_slice"], "melon_seeds")
    shaped("XXX/XXX/XXX", ["X": "ice"], "packed_ice")
    shaped("XXX/XXX/XXX", ["X": "packed_ice"], "blue_ice")
    shaped("XX/XX", ["X": "snowball"], "snow_block")
    shaped("XXX", ["X": "snow_block"], "snow", 6)
    shaped("XX/XX", ["X": "clay_ball"], "clay")
    shaped("XX/XX", ["X": "glowstone_dust"], "glowstone")
    shaped("XXX/XXX/XXX", ["X": "wheat"], "hay_block")
    shapeless(["hay_block"], "wheat", 9)
    shaped("XXX/XXX/XXX", ["X": "bone_meal"], "bone_block")
    shapeless(["bone_block"], "bone_meal", 9)
    shapeless(["bone"], "bone_meal", 3)
    shaped("XXX/XXX/XXX", ["X": "dried_kelp"], "dried_kelp_block")
    shapeless(["dried_kelp_block"], "dried_kelp", 9)
    shaped("XX/XX", ["X": "string"], "white_wool")
    shaped("XXX/XXX/XXX", ["X": "slime_ball"], "slime_block")
    shapeless(["slime_block"], "slime_ball", 9)
    shaped("XX/XX", ["X": "honeycomb"], "honeycomb_block")
    shaped("BB/BB", ["B": "honey_bottle"], "honey_block")
    shaped("XX/XX", ["X": "amethyst_shard"], "amethyst_block")
    shaped(" S /SGS/ S ", ["S": "amethyst_shard", "G": "glass"], "tinted_glass", 2)
    shaped("XX/XX", ["X": "pointed_dripstone"], "dripstone_block")

    // metals
    for (ingot, blockNm, nugget) in [("iron_ingot", "iron_block", "iron_nugget"), ("gold_ingot", "gold_block", "gold_nugget")] {
        shaped("XXX/XXX/XXX", ["X": ingot], blockNm)
        shapeless([blockNm], ingot, 9)
        shaped("XXX/XXX/XXX", ["X": nugget], ingot)
        shapeless([ingot], nugget, 9)
    }
    for (item, blockNm) in [("diamond", "diamond_block"), ("emerald", "emerald_block"), ("coal", "coal_block"),
                            ("lapis_lazuli", "lapis_block"), ("redstone", "redstone_block"),
                            ("copper_ingot", "copper_block"), ("netherite_ingot", "netherite_block"),
                            ("raw_iron", "raw_iron_block"), ("raw_copper", "raw_copper_block"), ("raw_gold", "raw_gold_block")] {
        shaped("XXX/XXX/XXX", ["X": item], blockNm)
        shapeless([blockNm], item, 9)
    }
    shapeless(["gold_ingot", "gold_ingot", "gold_ingot", "gold_ingot", "netherite_scrap", "netherite_scrap", "netherite_scrap", "netherite_scrap"], "netherite_ingot")

    // copper family
    for stage in 0..<4 {
        let p = ["", "exposed_", "weathered_", "oxidized_"][stage]
        shaped("XX/XX", ["X": "\(p)copper_block"], "\(p)cut_copper", 4)
        cut("\(p)copper_block", "\(p)cut_copper", 4)
        shaped("X  /XX /XXX", ["X": "\(p)cut_copper"], "\(p)cut_copper_stairs", 4)
        cut("\(p)copper_block", "\(p)cut_copper_stairs", 4)
        cut("\(p)cut_copper", "\(p)cut_copper_stairs")
        shaped("XXX", ["X": "\(p)cut_copper"], "\(p)cut_copper_slab", 6)
        cut("\(p)copper_block", "\(p)cut_copper_slab", 8)
        cut("\(p)cut_copper", "\(p)cut_copper_slab", 2)
        for base in ["\(p)copper_block", "\(p)cut_copper", "\(p)cut_copper_stairs", "\(p)cut_copper_slab"] {
            shapeless([base, "honeycomb"], "waxed_\(base)")
        }
    }
    shaped("C/C/C", ["C": "copper_ingot"], "lightning_rod")

    // --- tools / combat ---
    for (mat, ing) in [("wooden", "#planks"), ("stone", "#stone_crafting"), ("iron", "iron_ingot"),
                       ("golden", "gold_ingot"), ("diamond", "diamond")] {
        shaped("X/X/S", ["X": ing, "S": "stick"], "\(mat)_sword")
        shaped("XXX/ S / S ", ["X": ing, "S": "stick"], "\(mat)_pickaxe")
        shaped("XX/XS/ S", ["X": ing, "S": "stick"], "\(mat)_axe")
        shaped("X/S/S", ["X": ing, "S": "stick"], "\(mat)_shovel")
        shaped("XX/ S/ S", ["X": ing, "S": "stick"], "\(mat)_hoe")
    }
    shaped("EDE/ D / D ", ["D": "diamond", "E": "emerald"], "flying_wand")
    for (mat, ing) in [("leather", "leather"), ("iron", "iron_ingot"), ("golden", "gold_ingot"), ("diamond", "diamond")] {
        shaped("XXX/X X", ["X": ing], "\(mat)_helmet")
        shaped("X X/XXX/XXX", ["X": ing], "\(mat)_chestplate")
        shaped("XXX/X X/X X", ["X": ing], "\(mat)_leggings")
        shaped("X X/X X", ["X": ing], "\(mat)_boots")
    }
    shaped("XXX/X X", ["X": "scute"], "turtle_helmet")
    shaped("WIW/WWW/ W ", ["W": "#planks", "I": "iron_ingot"], "shield")
    shaped("SIS/XTX/ S ", ["S": "stick", "I": "iron_ingot", "T": "tripwire_hook", "X": "string"], "crossbow")
    shaped(" SX/S X/ SX", ["S": "stick", "X": "string"], "bow")
    shaped("F/S/E", ["F": "flint", "S": "stick", "E": "feather"], "arrow", 4)
    shapeless(["arrow", "glowstone_dust", "glowstone_dust", "glowstone_dust", "glowstone_dust"], "spectral_arrow", 2)
    shaped("  S/ SX/S X", ["S": "stick", "X": "string"], "fishing_rod")
    shapeless(["iron_ingot", "flint"], "flint_and_steel")
    shaped("SS /SE /  S", ["S": "string", "E": "slime_ball"], "lead", 2)
    shaped("F/C/S", ["F": "feather", "C": "copper_ingot", "S": "stick"], "brush")
    shaped("A/C/C", ["A": "amethyst_shard", "C": "copper_ingot"], "spyglass")
    shapeless(["fishing_rod", "carrot"], "carrot_on_a_stick")
    shapeless(["fishing_rod", "warped_fungus"], "warped_fungus_on_a_stick")

    // --- food ---
    shaped("WWW", ["W": "wheat"], "bread")
    shaped("WCW", ["W": "wheat", "C": "cocoa_beans"], "cookie", 8)
    shaped("MMM/SES/WWW", ["M": "milk_bucket", "S": "sugar", "E": "egg", "W": "wheat"], "cake")
    shapeless(["pumpkin", "sugar", "egg"], "pumpkin_pie")
    shapeless(["brown_mushroom", "red_mushroom", "bowl"], "mushroom_stew")
    shapeless(["beetroot", "beetroot", "beetroot", "beetroot", "beetroot", "beetroot", "bowl"], "beetroot_soup")
    shapeless(["cooked_rabbit", "carrot", "baked_potato", "brown_mushroom", "bowl"], "rabbit_stew")
    shapeless(["brown_mushroom", "red_mushroom", "bowl", "dandelion"], "suspicious_stew")
    shaped("GGG/GAG/GGG", ["G": "gold_ingot", "A": "apple"], "golden_apple")
    shaped("GGG/GCG/GGG", ["G": "gold_nugget", "C": "carrot"], "golden_carrot")
    shaped("GGG/GMG/GGG", ["G": "gold_nugget", "M": "melon_slice"], "glistering_melon_slice")
    shapeless(["sugar_cane"], "sugar")
    shapeless(["honey_bottle"], "sugar", 3)

    // --- redstone ---
    shaped("C/S", ["C": "#coals", "S": "stick"], "torch", 4)
    shaped("C/S/B", ["C": "#coals", "S": "stick", "B": "#soul_fire_base"], "soul_torch", 4)
    shaped("R/S", ["R": "redstone", "S": "stick"], "redstone_torch")
    shaped("S/C", ["S": "stick", "C": "cobblestone"], "lever")
    shaped("TRT/SSS", ["T": "redstone_torch", "R": "redstone", "S": "stone"], "repeater")
    shaped(" T /TQT/SSS", ["T": "redstone_torch", "Q": "quartz", "S": "stone"], "comparator")
    shapeless(["stone"], "stone_button")
    shapeless(["polished_blackstone"], "polished_blackstone_button")
    shaped("SS", ["S": "stone"], "stone_pressure_plate")
    shaped("SS", ["S": "polished_blackstone"], "polished_blackstone_pressure_plate")
    shaped("GG", ["G": "gold_ingot"], "light_weighted_pressure_plate")
    shaped("II", ["I": "iron_ingot"], "heavy_weighted_pressure_plate")
    shaped("WWW/CIC/CRC", ["W": "#planks", "C": "cobblestone", "I": "iron_ingot", "R": "redstone"], "piston")
    shapeless(["piston", "slime_ball"], "sticky_piston")
    shaped("CCC/RRQ/CCC", ["C": "cobblestone", "R": "redstone", "Q": "quartz"], "observer")
    shaped("CCC/CBC/CRC", ["C": "cobblestone", "B": "bow", "R": "redstone"], "dispenser")
    shaped("CCC/C C/CRC", ["C": "cobblestone", "R": "redstone"], "dropper")
    shaped("I I/ICI/ I ", ["I": "iron_ingot", "C": "chest"], "hopper")
    shaped(" G /GRG/ G ", ["G": "glowstone", "R": "redstone"], "redstone_lamp")
    shaped("GGG/QQQ/SSS", ["G": "glass", "Q": "quartz", "S": "#wooden_slabs"], "daylight_detector")
    shaped(" R /RHR/ R ", ["R": "redstone", "H": "hay_block"], "target")
    shaped("GSG/SGS/GSG", ["G": "gunpowder", "S": "sand"], "tnt")
    shaped("I/S", ["I": "iron_ingot", "S": "stick"], "tripwire_hook", 2)
    shaped("PPP/PRP/PPP", ["P": "#planks", "R": "redstone"], "note_block")
    shaped("PPP/PDP/PPP", ["P": "#planks", "D": "diamond"], "jukebox")
    shaped(" A /ASA", ["A": "amethyst_shard", "S": "sculk_sensor"], "calibrated_sculk_sensor")
    shaped("I I/ISI/I I", ["I": "iron_ingot", "S": "stick"], "rail", 16)
    shaped("G G/GSG/GRG", ["G": "gold_ingot", "S": "stick", "R": "redstone"], "powered_rail", 6)
    shaped("I I/IPI/IRI", ["I": "iron_ingot", "P": "stone_pressure_plate", "R": "redstone"], "detector_rail", 6)
    shaped("ISI/IRI/ISI", ["I": "iron_ingot", "S": "stick", "R": "redstone_torch"], "activator_rail", 6)
    shaped("I I/III", ["I": "iron_ingot"], "minecart")
    shapeless(["minecart", "chest"], "chest_minecart")
    shapeless(["minecart", "furnace"], "furnace_minecart")
    shapeless(["minecart", "hopper"], "hopper_minecart")
    shapeless(["minecart", "tnt"], "tnt_minecart")

    // --- functional ---
    shaped("CCC/C C/CCC", ["C": "cobblestone"], "furnace")
    shaped("III/IFI/SSS", ["I": "iron_ingot", "F": "furnace", "S": "smooth_stone"], "blast_furnace")
    shaped(" L /LFL/ L ", ["L": "#logs_that_burn", "F": "furnace"], "smoker")
    shaped(" S /SCS/LLL", ["S": "stick", "C": "#coals", "L": "#logs_that_burn"], "campfire")
    shaped(" S /SCS/LLL", ["S": "stick", "C": "#soul_fire_base", "L": "#logs_that_burn"], "soul_campfire")
    shaped("III/ICI/III", ["I": "iron_nugget", "C": "torch"], "lantern")
    shaped("III/ICI/III", ["I": "iron_nugget", "C": "soul_torch"], "soul_lantern")
    shaped("N/I/N", ["N": "iron_nugget", "I": "iron_ingot"], "chain")
    shaped(" B /DOD/OOO", ["B": "book", "D": "diamond", "O": "obsidian"], "enchanting_table")
    shaped("BBB/ I /III", ["B": "iron_block", "I": "iron_ingot"], "anvil")
    shaped("SAS/P P", ["S": "stick", "A": "stone_slab", "P": "#planks"], "grindstone")
    shaped(" I /SSS", ["I": "iron_ingot", "S": "stone"], "stonecutter")
    shaped("II/PP/PP", ["I": "iron_ingot", "P": "#planks"], "smithing_table")
    shaped("FF/PP/PP", ["F": "flint", "P": "#planks"], "fletching_table")
    shaped("PP/MM/MM", ["P": "paper", "M": "#planks"], "cartography_table")
    shaped("SS/PP/PP", ["S": "string", "P": "#planks"], "loom")
    shaped("P P/P P/PPP", ["P": "#wooden_slabs"], "composter")
    shaped("I I/I I/III", ["I": "iron_ingot"], "cauldron")
    shaped(" B /SSS", ["B": "blaze_rod", "S": "cobblestone"], "brewing_stand")
    shaped("GGG/GNG/OOO", ["G": "glass", "N": "nether_star", "O": "obsidian"], "beacon")
    shaped("NNN/NHN/NNN", ["N": "nautilus_shell", "H": "heart_of_the_sea"], "conduit")
    shaped("CCC/CNC/CCC", ["C": "chiseled_stone_bricks", "N": "netherite_ingot"], "lodestone")
    shaped("OOO/GGG/OOO", ["O": "crying_obsidian", "G": "glowstone"], "respawn_anchor")
    shaped("I I/ I ", ["I": "iron_ingot"], "bucket")
    shapeless(["glass", "glass", "glass"], "glass_bottle", 3)
    shaped(" I/I ", ["I": "iron_ingot"], "shears")
    shaped(" I /IRI/ I ", ["I": "iron_ingot", "R": "redstone"], "compass")
    shaped(" G /GRG/ G ", ["G": "gold_ingot", "R": "redstone"], "clock")
    shaped("CCC/CEC/CCC", ["C": "echo_shard", "E": "compass"], "recovery_compass")
    shaped("OOO/OEO/OOO", ["O": "obsidian", "E": "ender_eye"], "ender_chest")
    shapeless(["ender_pearl", "blaze_powder"], "ender_eye")
    shaped("S/C/S", ["S": "shulker_shell", "C": "chest"], "shulker_box")
    shaped("GGG/GEG/GTG", ["G": "glass", "E": "ender_eye", "T": "ghast_tear"], "end_crystal")
    shapeless(["blaze_rod"], "blaze_powder", 2)
    shapeless(["blaze_powder", "slime_ball"], "magma_cream")
    shapeless(["spider_eye", "brown_mushroom", "sugar"], "fermented_spider_eye")
    shapeless(["gunpowder", "blaze_powder", "coal"], "fire_charge", 3)
    shaped("SSS", ["S": "sugar_cane"], "paper", 3)
    shapeless(["paper", "paper", "paper", "leather"], "book")
    shapeless(["book", "ink_sac", "feather"], "writable_book")
    shaped("GGG/GGG", ["G": "glass"], "glass_pane", 16)
    shaped("III/III", ["I": "iron_ingot"], "iron_bars", 16)
    shaped("H/S", ["H": "honeycomb", "S": "string"], "candle")
    shaped("SCS/CCC/SCS", ["S": "prismarine_shard", "C": "prismarine_crystals"], "sea_lantern")
    shaped("SS/SS", ["S": "prismarine_shard"], "prismarine")
    shaped("SSS/SSS/SSS", ["S": "prismarine_shard"], "prismarine_bricks")
    shaped("SSS/SIS/SSS", ["S": "prismarine_shard", "I": "black_dye"], "dark_prismarine")
    shaped("PPP/HHH/PPP", ["P": "#planks", "H": "honeycomb"], "beehive")
    shaped("P/B", ["P": "pumpkin", "B": "torch"], "jack_o_lantern")
    shaped("BSB/B B/B B", ["B": "bamboo", "S": "string"], "scaffolding", 6)
    shaped("II/II/II", ["I": "iron_ingot"], "iron_door", 3)
    shaped("II/II", ["I": "iron_ingot"], "iron_trapdoor")
    shaped(" B /B B/ B ", ["B": "brick"], "decorated_pot")
    shapeless(["paper", "gunpowder"], "firework_rocket", 3)
    shaped("B B/ B ", ["B": "brick"], "flower_pot")

    // --- dyes & colored blocks ---
    let DYE_SOURCES: [(String, String)] = [
        ("dandelion", "yellow_dye"), ("poppy", "red_dye"), ("blue_orchid", "light_blue_dye"),
        ("allium", "magenta_dye"), ("azure_bluet", "light_gray_dye"), ("red_tulip", "red_dye"),
        ("orange_tulip", "orange_dye"), ("white_tulip", "light_gray_dye"), ("pink_tulip", "pink_dye"),
        ("oxeye_daisy", "light_gray_dye"), ("cornflower", "blue_dye"), ("lily_of_the_valley", "white_dye"),
        ("wither_rose", "black_dye"), ("beetroot", "red_dye"),
        ("lapis_lazuli", "blue_dye"), ("cocoa_beans", "brown_dye"), ("ink_sac", "black_dye"),
        ("bone_meal", "white_dye"), ("torchflower", "orange_dye"),
    ]
    for (src, dye) in DYE_SOURCES { shapeless([src], dye) }
    for (src, dye) in [("sunflower", "yellow_dye"), ("lilac", "magenta_dye"), ("rose_bush", "red_dye"), ("peony", "pink_dye"), ("pitcher_plant", "cyan_dye")] {
        shapeless([src], dye, 2)
    }
    shapeless(["red_dye", "yellow_dye"], "orange_dye", 2)
    shapeless(["blue_dye", "white_dye"], "light_blue_dye", 2)
    shapeless(["blue_dye", "green_dye"], "cyan_dye", 2)
    shapeless(["red_dye", "blue_dye"], "purple_dye", 2)
    shapeless(["purple_dye", "pink_dye"], "magenta_dye", 2)
    shapeless(["red_dye", "white_dye"], "pink_dye", 2)
    shapeless(["green_dye", "white_dye"], "lime_dye", 2)
    shapeless(["black_dye", "white_dye"], "gray_dye", 2)
    shapeless(["gray_dye", "white_dye"], "light_gray_dye", 2)
    for c in COLORS {
        if c != "white" { shapeless(["\(c)_dye", "white_wool"], "\(c)_wool") }
        shaped("WW", ["W": "\(c)_wool"], "\(c)_carpet", 3)
        shaped("WWW/PPP", ["W": "\(c)_wool", "P": "#planks"], "\(c)_bed")
        shaped("GGG/GDG/GGG", ["G": "glass", "D": "\(c)_dye"], "\(c)_stained_glass", 8)
        shaped("GGG/GGG", ["G": "\(c)_stained_glass"], "\(c)_stained_glass_pane", 16)
        shaped("TTT/TDT/TTT", ["T": "terracotta", "D": "\(c)_dye"], "\(c)_terracotta", 8)
        shapeless(["\(c)_dye", "sand", "sand", "sand", "sand", "gravel", "gravel", "gravel", "gravel"], "\(c)_concrete_powder", 8)
        shapeless(["candle", "\(c)_dye"], "\(c)_candle")
        shapeless(["shulker_box", "\(c)_dye"], "\(c)_shulker_box")
    }

    // --- smelting ---
    let ORE_SMELTS: [(String, String, Double)] = [
        ("iron_ore", "iron_ingot", 0.7), ("deepslate_iron_ore", "iron_ingot", 0.7), ("raw_iron", "iron_ingot", 0.7),
        ("gold_ore", "gold_ingot", 1), ("deepslate_gold_ore", "gold_ingot", 1), ("raw_gold", "gold_ingot", 1),
        ("copper_ore", "copper_ingot", 0.7), ("deepslate_copper_ore", "copper_ingot", 0.7), ("raw_copper", "copper_ingot", 0.7),
        ("coal_ore", "coal", 0.1), ("deepslate_coal_ore", "coal", 0.1),
        ("diamond_ore", "diamond", 1), ("deepslate_diamond_ore", "diamond", 1),
        ("emerald_ore", "emerald", 1), ("deepslate_emerald_ore", "emerald", 1),
        ("lapis_ore", "lapis_lazuli", 0.2), ("deepslate_lapis_ore", "lapis_lazuli", 0.2),
        ("redstone_ore", "redstone", 0.7), ("deepslate_redstone_ore", "redstone", 0.7),
        ("nether_gold_ore", "gold_ingot", 1), ("nether_quartz_ore", "quartz", 0.2),
        ("ancient_debris", "netherite_scrap", 2),
    ]
    for (i, o, xp) in ORE_SMELTS { smelt(i, o, xp, "blast") }
    let FOOD_SMELTS: [(String, String, Double)] = [
        ("beef", "cooked_beef", 0.35), ("porkchop", "cooked_porkchop", 0.35),
        ("chicken", "cooked_chicken", 0.35), ("mutton", "cooked_mutton", 0.35),
        ("rabbit", "cooked_rabbit", 0.35), ("cod", "cooked_cod", 0.35),
        ("salmon", "cooked_salmon", 0.35), ("potato", "baked_potato", 0.35),
        ("kelp", "dried_kelp", 0.1),
    ]
    for (i, o, xp) in FOOD_SMELTS { smelt(i, o, xp, "smoke") }
    let GENERAL_SMELTS: [(String, String, Double)] = [
        ("cobblestone", "stone", 0.1), ("stone", "smooth_stone", 0.1),
        ("sand", "glass", 0.1), ("red_sand", "glass", 0.1),
        ("sandstone", "smooth_sandstone", 0.1), ("red_sandstone", "smooth_red_sandstone", 0.1),
        ("quartz_block", "smooth_quartz", 0.1), ("basalt", "smooth_basalt", 0.1),
        ("clay_ball", "brick", 0.3), ("clay", "terracotta", 0.35),
        ("netherrack", "nether_brick", 0.1), ("cobbled_deepslate", "deepslate", 0.1),
        ("cactus", "green_dye", 1), ("sea_pickle", "lime_dye", 0.1),
        ("chorus_fruit", "popped_chorus_fruit", 0.1), ("wet_sponge", "sponge", 0.15),
        ("stone_bricks", "cracked_stone_bricks", 0.1), ("deepslate_bricks", "cracked_deepslate_bricks", 0.1),
        ("deepslate_tiles", "cracked_deepslate_tiles", 0.1), ("nether_bricks", "cracked_nether_bricks", 0.1),
        ("polished_blackstone_bricks", "cracked_polished_blackstone_bricks", 0.1),
    ]
    for (i, o, xp) in GENERAL_SMELTS { smelt(i, o, xp) }
    for log in TAGS["logs_that_burn"]! { smelt(log, "charcoal", 0.15) }
    for c in COLORS { smelt("\(c)_terracotta", "\(c)_glazed_terracotta", 0.1) }

    // --- stonecutting extras ---
    cut("stone", "stone_bricks")
    cut("stone", "chiseled_stone_bricks")
    cut("stone_bricks", "chiseled_stone_bricks")
    cut("sandstone", "cut_sandstone")
    cut("sandstone", "chiseled_sandstone")
    cut("red_sandstone", "cut_red_sandstone")
    cut("red_sandstone", "chiseled_red_sandstone")
    cut("cobbled_deepslate", "polished_deepslate")
    cut("cobbled_deepslate", "deepslate_bricks")
    cut("cobbled_deepslate", "deepslate_tiles")
    cut("cobbled_deepslate", "chiseled_deepslate")
    cut("polished_deepslate", "deepslate_bricks")
    cut("polished_deepslate", "deepslate_tiles")
    cut("deepslate_bricks", "deepslate_tiles")
    cut("blackstone", "polished_blackstone")
    cut("blackstone", "polished_blackstone_bricks")
    cut("blackstone", "chiseled_polished_blackstone")
    cut("polished_blackstone", "polished_blackstone_bricks")
    cut("polished_blackstone", "chiseled_polished_blackstone")
    cut("end_stone", "end_stone_bricks")
    cut("quartz_block", "quartz_bricks")
    cut("quartz_block", "quartz_pillar")
    cut("quartz_block", "chiseled_quartz_block")
    cut("purpur_block", "purpur_pillar")
    cut("granite", "polished_granite")
    cut("diorite", "polished_diorite")
    cut("andesite", "polished_andesite")

    // --- smithing ---
    for t in ["sword", "pickaxe", "axe", "shovel", "hoe"] {
        smithingRecipes.append(SmithRecipe(template: "netherite_upgrade", base: "diamond_\(t)", addition: "netherite_ingot", output: "netherite_\(t)"))
    }
    for s in ["helmet", "chestplate", "leggings", "boots"] {
        smithingRecipes.append(SmithRecipe(template: "netherite_upgrade", base: "diamond_\(s)", addition: "netherite_ingot", output: "netherite_\(s)"))
    }
    for t in TRIM_PATTERNS {
        smithingRecipes.append(SmithRecipe(template: "\(t)_armor_trim", base: "#armor", addition: "#trim_material", output: "trim"))
        shaped("DTD/DMD/DDD", ["D": "diamond", "T": "\(t)_armor_trim", "M": "cobblestone"], "\(t)_armor_trim", 2)
    }
    shaped("DTD/DMD/DDD", ["D": "diamond", "T": "netherite_upgrade", "M": "netherrack"], "netherite_upgrade", 2)
}
