// Block registrations — registration order is frozen (ids persist in saves).
// REGISTRATION ORDER IS LOAD-BEARING: ids must match the golden baselines so worldgen
// output can be verified cell-for-cell against goldens.

import Foundation

// MARK: - builder shorthands

@discardableResult
private func stone(_ name: String, _ hardness: Double, resistance: Double? = nil, tier: Int = 0,
                   light: Int = 0, sound: String = "stone", tex: TexSpec = .own, texFn: ((Int, Int) -> Int)? = nil,
                   display: String? = nil, drops: DropSpec = .selfDrop) -> UInt16 {
    registerBlock(name, tex: tex, texFn: texFn, display: display, light: light,
                  hardness: hardness, resistance: resistance ?? hardness * 2,
                  tool: .pickaxe, tier: tier, requiresTool: true, sound: sound, drops: drops)
}

@discardableResult
private func wood(_ name: String, shape: Shape = .cube, tex: TexSpec = .own, texFn: ((Int, Int) -> Int)? = nil,
                  opaque: Bool = true, fullCube: Bool? = nil, light: Int = 0, lightOpacity: Int? = nil,
                  hardness: Double = 2, sound: String = "wood", flammable: Int = 5,
                  piston: PistonBehavior = .normal, drops: DropSpec = .selfDrop) -> UInt16 {
    registerBlock(name, shape: shape, tex: tex, texFn: texFn, opaque: opaque, fullCube: fullCube,
                  light: light, lightOpacity: lightOpacity, hardness: hardness, resistance: 3,
                  tool: .axe, sound: sound, flammable: flammable, burnOdds: flammable > 0 ? 20 : 0,
                  piston: piston, drops: drops)
}

@discardableResult
private func earth(_ name: String, _ hardness: Double, sound: String = "gravel",
                   gravity: Bool = false, drops: DropSpec = .selfDrop) -> UInt16 {
    registerBlock(name, hardness: hardness, tool: .shovel, sound: sound, gravity: gravity, drops: drops)
}

@discardableResult
private func plant(_ name: String, shape: Shape = .cross, tex: TexSpec = .own, texFn: ((Int, Int) -> Int)? = nil,
                   display: String? = nil, replaceable: Bool = false, light: Int = 0, tint: Int = 0,
                   sound: String = "grass", flammable: Int = 60, randomTicks: Bool = false,
                   climbable: Bool = false, drops: DropSpec = .selfDrop) -> UInt16 {
    registerBlock(name, shape: shape, tex: tex, texFn: texFn, display: display,
                  opaque: false, solid: false, fullCube: false, replaceable: replaceable,
                  light: light, hardness: 0, sound: sound, tint: tint,
                  flammable: flammable, burnOdds: flammable > 0 ? 100 : 0,
                  piston: .destroy, climbable: climbable, randomTicks: randomTicks,
                  drops: drops, ao: false)
}

@discardableResult
private func ore(_ name: String, _ tier: Int, _ dropItem: String?, hardness: Double = 3,
                 sound: String = "stone", randomTicks: Bool = false, drops: DropSpec? = nil) -> UInt16 {
    var spec: DropSpec = .selfDrop
    if let d = drops {
        spec = d
    } else if let item = dropItem {
        spec = .fn { _, ctx in
            if ctx.silkTouch { return [Drop(name)] }
            let bonus = ctx.fortune > 0 ? max(1, Int(ctx.random() * Double(ctx.fortune + 2))) : 1
            return [Drop(item, bonus)]
        }
    }
    return registerBlock(name, hardness: hardness, resistance: 3, tool: .pickaxe, tier: tier,
                         requiresTool: true, sound: sound, randomTicks: randomTicks, drops: spec)
}

// MARK: - data tables shared with worldgen/UI

public let WOODS = ["oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry", "bamboo", "crimson", "warped"]
public let LEAF_WOODS = ["oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry", "azalea", "flowering_azalea"]
public let COLORS = ["white", "orange", "magenta", "light_blue", "yellow", "lime", "pink", "gray",
                     "light_gray", "cyan", "purple", "blue", "brown", "green", "red", "black"]
public let COLOR_RGB: [String: UInt32] = [
    "white": 0xf9fffe, "orange": 0xf9801d, "magenta": 0xc74ebd, "light_blue": 0x3ab3da,
    "yellow": 0xfed83d, "lime": 0x80c71f, "pink": 0xf38baa, "gray": 0x474f52,
    "light_gray": 0x9d9d97, "cyan": 0x169c9c, "purple": 0x8932b8, "blue": 0x3c44aa,
    "brown": 0x835432, "green": 0x5e7c16, "red": 0xb02e26, "black": 0x1d1d21,
]
public let CORALS = ["tube", "brain", "bubble", "fire", "horn"]
public let FLOWERS = ["dandelion", "poppy", "blue_orchid", "allium", "azure_bluet", "red_tulip",
                      "orange_tulip", "white_tulip", "pink_tulip", "oxeye_daisy", "cornflower",
                      "lily_of_the_valley", "torchflower"]
public let COPPER_STAGES = ["", "exposed_", "weathered_", "oxidized_"]

public let STONE_FAMILIES: [(String, String)] = [
    ("cobblestone", "cobblestone"), ("mossy_cobblestone", "mossy_cobblestone"),
    ("stone", "stone"), ("smooth_stone", "smooth_stone"),
    ("stone_brick", "stone_bricks"), ("mossy_stone_brick", "mossy_stone_bricks"),
    ("granite", "granite"), ("polished_granite", "polished_granite"),
    ("diorite", "diorite"), ("polished_diorite", "polished_diorite"),
    ("andesite", "andesite"), ("polished_andesite", "polished_andesite"),
    ("cobbled_deepslate", "cobbled_deepslate"), ("polished_deepslate", "polished_deepslate"),
    ("deepslate_brick", "deepslate_bricks"), ("deepslate_tile", "deepslate_tiles"),
    ("brick", "bricks"), ("mud_brick", "mud_bricks"),
    ("sandstone", "sandstone"), ("smooth_sandstone", "sandstone_top"), ("cut_sandstone", "cut_sandstone"),
    ("red_sandstone", "red_sandstone"), ("smooth_red_sandstone", "red_sandstone_top"), ("cut_red_sandstone", "cut_red_sandstone"),
    ("prismarine", "prismarine"), ("prismarine_brick", "prismarine_bricks"), ("dark_prismarine", "dark_prismarine"),
    ("nether_brick", "nether_bricks"), ("red_nether_brick", "red_nether_bricks"),
    ("blackstone", "blackstone"), ("polished_blackstone", "polished_blackstone"), ("polished_blackstone_brick", "polished_blackstone_bricks"),
    ("end_stone_brick", "end_stone_bricks"), ("purpur", "purpur_block"),
    ("quartz", "quartz_block_side"), ("smooth_quartz", "quartz_block_bottom"),
    ("tuff", "tuff"),
]

// MARK: - registration (call registerAllBlocks() exactly once at startup)

private var registered = false

public func registerAllBlocks() {
    if registered { return }
    registered = true

    // air
    registerBlock("air", shape: .air, opaque: false, solid: false, fullCube: false, replaceable: true, lightOpacity: 0, hardness: 0, drops: .none)
    registerBlock("cave_air", shape: .air, opaque: false, solid: false, fullCube: false, replaceable: true, lightOpacity: 0, hardness: 0, drops: .none)
    registerBlock("void_air", shape: .air, opaque: false, solid: false, fullCube: false, replaceable: true, lightOpacity: 0, hardness: 0, drops: .none)

    // stones
    stone("stone", 1.5, resistance: 6, drops: .item("cobblestone"))
    stone("granite", 1.5, resistance: 6)
    stone("polished_granite", 1.5, resistance: 6)
    stone("diorite", 1.5, resistance: 6)
    stone("polished_diorite", 1.5, resistance: 6)
    stone("andesite", 1.5, resistance: 6)
    stone("polished_andesite", 1.5, resistance: 6)
    registerBlock("deepslate", tex: texCol("deepslate_top", "deepslate"), hardness: 3, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "deepslate", drops: .item("cobbled_deepslate"))
    registerBlock("cobbled_deepslate", hardness: 3.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "deepslate")
    registerBlock("polished_deepslate", hardness: 3.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "deepslate")
    registerBlock("deepslate_bricks", hardness: 3.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "deepslate")
    registerBlock("cracked_deepslate_bricks", hardness: 3.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "deepslate")
    registerBlock("deepslate_tiles", hardness: 3.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "deepslate")
    registerBlock("cracked_deepslate_tiles", hardness: 3.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "deepslate")
    registerBlock("chiseled_deepslate", hardness: 3.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "deepslate")
    registerBlock("reinforced_deepslate", tex: texTB("reinforced_deepslate_top", "reinforced_deepslate_bottom", "reinforced_deepslate_side"), hardness: 55, resistance: 1200, tool: .pickaxe, sound: "deepslate", drops: .none)
    registerBlock("tuff", hardness: 1.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "tuff")
    registerBlock("calcite", hardness: 0.75, tool: .pickaxe, requiresTool: true, sound: "stone")
    stone("dripstone_block", 1.5, sound: "pointed_dripstone")
    stone("cobblestone", 2, resistance: 6)
    stone("mossy_cobblestone", 2, resistance: 6)
    stone("smooth_stone", 2, resistance: 6)
    stone("stone_bricks", 1.5, resistance: 6)
    stone("mossy_stone_bricks", 1.5, resistance: 6)
    stone("cracked_stone_bricks", 1.5, resistance: 6)
    stone("chiseled_stone_bricks", 1.5, resistance: 6)
    stone("bricks", 2, resistance: 6)
    registerBlock("bedrock", hardness: -1, resistance: 3_600_000, drops: .none)
    stone("obsidian", 50, resistance: 1200, tier: 3)
    stone("crying_obsidian", 50, resistance: 1200, tier: 3, light: 10)

    // earth
    registerBlock("grass_block", tex: texTB("grass_top", "dirt", "grass_side"), hardness: 0.6, tool: .shovel, sound: "grass", tint: 1, randomTicks: true, drops: .item("dirt"))
    earth("dirt", 0.5)
    earth("coarse_dirt", 0.5)
    earth("rooted_dirt", 0.5)
    registerBlock("podzol", tex: texTB("podzol_top", "dirt", "podzol_side"), hardness: 0.5, tool: .shovel, sound: "gravel", drops: .item("dirt"))
    registerBlock("mycelium", tex: texTB("mycelium_top", "dirt", "mycelium_side"), hardness: 0.6, tool: .shovel, sound: "grass", randomTicks: true, drops: .item("dirt"))
    registerBlock("dirt_path", shape: .path, tex: texTB("dirt_path_top", "dirt", "dirt_path_side"), opaque: false, fullCube: false, hardness: 0.65, tool: .shovel, sound: "grass", drops: .item("dirt"))
    registerBlock("farmland", shape: .farmland, tex: texTB("farmland_dry", "dirt", "dirt"),
                  texFn: { m, f in f == 1 ? (m >= 7 ? tileId("farmland_wet") : tileId("farmland_dry")) : tileId("dirt") },
                  opaque: false, fullCube: false, hardness: 0.6, tool: .shovel, sound: "gravel", randomTicks: true, drops: .item("dirt"))
    registerBlock("mud", hardness: 0.5, tool: .shovel, sound: "mud")
    registerBlock("packed_mud", hardness: 1, tool: .pickaxe, sound: "mud")
    stone("mud_bricks", 1.5, sound: "mud")
    earth("clay", 0.6, drops: .list([Drop("clay_ball", 4)]))
    earth("gravel", 0.6, gravity: true, drops: .fn { _, ctx in ctx.random() < 0.1 + Double(ctx.fortune) * 0.04 ? [Drop("flint")] : [Drop("gravel")] })
    earth("sand", 0.5, sound: "sand", gravity: true)
    earth("red_sand", 0.5, sound: "sand", gravity: true)
    earth("suspicious_sand", 0.25, sound: "suspicious_sand", gravity: true, drops: .none)
    earth("suspicious_gravel", 0.25, sound: "suspicious_gravel", gravity: true, drops: .none)
    stone("sandstone", 0.8, tex: texTB("sandstone_top", "sandstone_bottom", "sandstone_side"))
    stone("chiseled_sandstone", 0.8, tex: texTB("sandstone_top", "sandstone_top", "chiseled_sandstone"))
    stone("cut_sandstone", 0.8, tex: texTB("sandstone_top", "sandstone_top", "cut_sandstone"))
    stone("smooth_sandstone", 2, tex: .named("sandstone_top"))
    stone("red_sandstone", 0.8, tex: texTB("red_sandstone_top", "red_sandstone_bottom", "red_sandstone_side"))
    stone("chiseled_red_sandstone", 0.8, tex: texTB("red_sandstone_top", "red_sandstone_top", "chiseled_red_sandstone"))
    stone("cut_red_sandstone", 0.8, tex: texTB("red_sandstone_top", "red_sandstone_top", "cut_red_sandstone"))
    stone("smooth_red_sandstone", 2, tex: .named("red_sandstone_top"))

    // ores
    ore("coal_ore", 0, "coal")
    ore("deepslate_coal_ore", 0, "coal", hardness: 4.5, sound: "deepslate")
    ore("copper_ore", 1, nil, drops: .fn { _, ctx in ctx.silkTouch ? [Drop("copper_ore")] : [Drop("raw_copper", 2, 5)] })
    ore("deepslate_copper_ore", 1, nil, hardness: 4.5, sound: "deepslate", drops: .fn { _, ctx in ctx.silkTouch ? [Drop("deepslate_copper_ore")] : [Drop("raw_copper", 2, 5)] })
    ore("iron_ore", 1, nil, drops: .fn { _, ctx in ctx.silkTouch ? [Drop("iron_ore")] : [Drop("raw_iron")] })
    ore("deepslate_iron_ore", 1, nil, hardness: 4.5, sound: "deepslate", drops: .fn { _, ctx in ctx.silkTouch ? [Drop("deepslate_iron_ore")] : [Drop("raw_iron")] })
    ore("gold_ore", 2, nil, drops: .fn { _, ctx in ctx.silkTouch ? [Drop("gold_ore")] : [Drop("raw_gold")] })
    ore("deepslate_gold_ore", 2, nil, hardness: 4.5, sound: "deepslate", drops: .fn { _, ctx in ctx.silkTouch ? [Drop("deepslate_gold_ore")] : [Drop("raw_gold")] })
    ore("redstone_ore", 2, nil, randomTicks: true, drops: .fn { _, ctx in ctx.silkTouch ? [Drop("redstone_ore")] : [Drop("redstone", 4, 5 + ctx.fortune)] })
    ore("deepslate_redstone_ore", 2, nil, hardness: 4.5, sound: "deepslate", drops: .fn { _, ctx in ctx.silkTouch ? [Drop("deepslate_redstone_ore")] : [Drop("redstone", 4, 5 + ctx.fortune)] })
    ore("lapis_ore", 1, nil, drops: .fn { _, ctx in ctx.silkTouch ? [Drop("lapis_ore")] : [Drop("lapis_lazuli", 4, 9)] })
    ore("deepslate_lapis_ore", 1, nil, hardness: 4.5, sound: "deepslate", drops: .fn { _, ctx in ctx.silkTouch ? [Drop("deepslate_lapis_ore")] : [Drop("lapis_lazuli", 4, 9)] })
    ore("diamond_ore", 2, "diamond")
    ore("deepslate_diamond_ore", 2, "diamond", hardness: 4.5, sound: "deepslate")
    ore("emerald_ore", 2, "emerald")
    ore("deepslate_emerald_ore", 2, "emerald", hardness: 4.5, sound: "deepslate")
    ore("nether_gold_ore", 0, nil, sound: "netherrack", drops: .fn { _, ctx in ctx.silkTouch ? [Drop("nether_gold_ore")] : [Drop("gold_nugget", 2, 6)] })
    ore("nether_quartz_ore", 0, "quartz", sound: "netherrack")
    registerBlock("ancient_debris", tex: texCol("ancient_debris_top", "ancient_debris_side"), hardness: 30, resistance: 1200, tool: .pickaxe, tier: 3, requiresTool: true, sound: "netherite")

    // mineral blocks
    stone("coal_block", 5, resistance: 6)
    stone("iron_block", 5, resistance: 6, tier: 1, sound: "metal")
    stone("gold_block", 3, resistance: 6, tier: 2, sound: "metal")
    stone("diamond_block", 5, resistance: 6, tier: 2, sound: "metal")
    stone("emerald_block", 5, resistance: 6, tier: 2, sound: "metal")
    stone("lapis_block", 3, tier: 1)
    stone("redstone_block", 5, resistance: 6, sound: "metal")
    stone("netherite_block", 50, resistance: 1200, tier: 3, sound: "netherite")
    stone("quartz_block", 0.8, tex: texTB("quartz_block_top", "quartz_block_bottom", "quartz_block_side"))
    stone("chiseled_quartz_block", 0.8, tex: texCol("chiseled_quartz_block_top", "chiseled_quartz_block"))
    stone("quartz_pillar", 0.8, tex: texCol("quartz_pillar_top", "quartz_pillar"))
    stone("smooth_quartz", 2, tex: .named("quartz_block_bottom"))
    stone("quartz_bricks", 0.8)
    stone("raw_iron_block", 5, resistance: 6, tier: 1)
    stone("raw_copper_block", 5, resistance: 6, tier: 1)
    stone("raw_gold_block", 5, resistance: 6, tier: 2)
    registerBlock("amethyst_block", hardness: 1.5, tool: .pickaxe, requiresTool: true, sound: "amethyst")
    registerBlock("budding_amethyst", hardness: 1.5, tool: .pickaxe, requiresTool: true, sound: "amethyst", piston: .destroy, randomTicks: true, drops: .none)

    // wood family
    func woodSound(_ w: String) -> String {
        w == "cherry" ? "cherry" : w == "bamboo" ? "bamboo_wood" : (w == "crimson" || w == "warped") ? "nether_wood" : "wood"
    }
    func logTexFn(_ top: String, _ side: String) -> (Int, Int) -> Int {
        { m, f in
            let topT = tileId(top), sideT = tileId(side)
            let axis = m & 3
            if axis == 0 { return (f == 0 || f == 1) ? topT : sideT }
            if axis == 1 { return (f == 4 || f == 5) ? topT : sideT }
            return (f == 2 || f == 3) ? topT : sideT
        }
    }
    for w in WOODS {
        let snd = woodSound(w)
        let flam = (w == "crimson" || w == "warped") ? 0 : 5
        if w != "bamboo" {
            let logName = (w == "crimson" || w == "warped") ? "\(w)_stem" : "\(w)_log"
            wood(logName, tex: texCol("\(logName)_top", logName), texFn: logTexFn("\(logName)_top", logName), sound: snd, flammable: flam)
            let strippedLog = "stripped_\(logName)"
            wood(strippedLog, tex: texCol("\(strippedLog)_top", strippedLog), texFn: logTexFn("\(strippedLog)_top", strippedLog), sound: snd, flammable: flam)
            let woodName = (w == "crimson" || w == "warped") ? "\(w)_hyphae" : "\(w)_wood"
            wood(woodName, tex: .named(logName), sound: snd, flammable: flam)
            wood("stripped_\(woodName)", tex: .named(strippedLog), sound: snd, flammable: flam)
        } else {
            wood("bamboo_block", tex: texCol("bamboo_block_top", "bamboo_block"), sound: "bamboo_wood")
            wood("stripped_bamboo_block", tex: texCol("stripped_bamboo_block_top", "stripped_bamboo_block"), sound: "bamboo_wood")
        }
        let planksName = w == "bamboo" ? "bamboo_planks" : "\(w)_planks"
        wood(planksName, sound: snd, flammable: flam)
        if w == "bamboo" { wood("bamboo_mosaic", sound: snd) }
        wood("\(w)_stairs", shape: .stairs, tex: .named(planksName), opaque: false, fullCube: false, lightOpacity: 0, sound: snd, flammable: flam)
        wood("\(w)_slab", shape: .slab, tex: .named(planksName), opaque: false, fullCube: false, lightOpacity: 0, sound: snd, flammable: flam,
             drops: .fn { m, _ in [Drop("\(w)_slab", (m & 3) == 2 ? 2 : 1)] })
        if w == "bamboo" {
            wood("bamboo_mosaic_stairs", shape: .stairs, tex: .named("bamboo_mosaic"), opaque: false, fullCube: false, sound: snd)
            wood("bamboo_mosaic_slab", shape: .slab, tex: .named("bamboo_mosaic"), opaque: false, fullCube: false, sound: snd)
        }
        wood("\(w)_fence", shape: .fence, tex: .named(planksName), opaque: false, fullCube: false, sound: snd, flammable: flam)
        wood("\(w)_fence_gate", shape: .fenceGate, tex: .named(planksName), opaque: false, fullCube: false, sound: snd, flammable: flam)
        wood("\(w)_door", shape: .door, tex: .named("\(w)_door"), opaque: false, fullCube: false, sound: snd, piston: .destroy,
             drops: .fn { m, _ in (m & 8) != 0 ? [] : [Drop("\(w)_door")] })
        wood("\(w)_trapdoor", shape: .trapdoor, tex: .named("\(w)_trapdoor"), opaque: false, fullCube: false, hardness: 3, sound: snd)
        registerBlock("\(w)_button", shape: .button, tex: .named(planksName), opaque: false, solid: false, fullCube: false, hardness: 0.5, sound: snd, piston: .destroy)
        registerBlock("\(w)_pressure_plate", shape: .pressurePlate, tex: .named(planksName), opaque: false, solid: false, fullCube: false, hardness: 0.5, sound: snd, piston: .destroy)
        registerBlock("\(w)_sign", shape: .sign, tex: .named(planksName), opaque: false, solid: false, fullCube: false, hardness: 1, sound: snd, piston: .destroy, drops: .item("\(w)_sign"))
        registerBlock("\(w)_wall_sign", shape: .wallSign, tex: .named(planksName), opaque: false, solid: false, fullCube: false, hardness: 1, sound: snd, piston: .destroy, drops: .item("\(w)_sign"))
        registerBlock("\(w)_hanging_sign", shape: .hangingSign, tex: .named(planksName), opaque: false, solid: false, fullCube: false, hardness: 1, sound: "hanging_sign", piston: .destroy, drops: .item("\(w)_hanging_sign"))
    }

    // leaves / saplings
    for w in LEAF_WOODS {
        let name = "\(w)_leaves"
        let tint = (w == "birch" || w == "spruce" || w == "cherry" || w == "azalea" || w == "flowering_azalea") ? 0 : 2
        registerBlock(name, tex: .named(name), opaque: false, lightOpacity: 1, hardness: 0.2, tool: .shears,
                      sound: w == "cherry" ? "cherry" : w.contains("azalea") ? "azalea" : "grass",
                      tint: tint, flammable: 30, burnOdds: 60, randomTicks: true, transparentRender: true, cullSame: false,
                      drops: .fn { _, ctx in
                          if ctx.shears || ctx.silkTouch { return [Drop(name)] }
                          var out: [Drop] = []
                          let sapling = w == "azalea" ? "azalea" : w == "flowering_azalea" ? "flowering_azalea"
                              : w == "mangrove" ? "mangrove_propagule" : "\(w)_sapling"
                          if ctx.random() < 0.05 + Double(ctx.fortune) * 0.01 { out.append(Drop(sapling)) }
                          if ctx.random() < 0.02 + Double(ctx.fortune) * 0.005 { out.append(Drop("stick", 1, 2)) }
                          if w == "oak" || w == "dark_oak" {
                              if ctx.random() < 0.005 + Double(ctx.fortune) * 0.001 { out.append(Drop("apple")) }
                          }
                          return out
                      }, ao: true)
    }
    for w in ["oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "cherry"] {
        plant("\(w)_sapling", randomTicks: true)
    }
    registerBlock("mangrove_propagule", shape: .propagule, opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy, randomTicks: true, ao: false)
    registerBlock("mangrove_roots", shape: .cube, opaque: false, lightOpacity: 1, hardness: 0.7, tool: .axe, sound: "mangrove_roots", transparentRender: true)
    registerBlock("muddy_mangrove_roots", tex: texCol("muddy_mangrove_roots_top", "muddy_mangrove_roots_side"), hardness: 0.7, tool: .shovel, sound: "mud")

    // liquids
    registerBlock("water", shape: .liquid, opaque: false, solid: false, fullCube: false, replaceable: true,
                  lightOpacity: 1, hardness: 100, sound: "water", tint: 3, piston: .destroy, translucent: true, drops: .none, ao: false)
    registerBlock("lava", shape: .liquid, opaque: false, solid: false, fullCube: false, replaceable: true,
                  light: 15, lightOpacity: 1, hardness: 100, sound: "lava", piston: .destroy, emissiveRender: true, drops: .none, ao: false)

    // glass
    registerBlock("glass", opaque: false, lightOpacity: 0, hardness: 0.3, sound: "glass", transparentRender: true, cullSame: true, drops: .none)
    registerBlock("tinted_glass", opaque: false, lightOpacity: 15, hardness: 0.3, sound: "glass", translucent: true, cullSame: true, drops: .item("tinted_glass"))
    registerBlock("glass_pane", shape: .pane, tex: .named("glass"), opaque: false, fullCube: false, hardness: 0.3, sound: "glass", drops: .none)
    registerBlock("iron_bars", shape: .bars, tex: .named("iron_bars"), opaque: false, fullCube: false, hardness: 5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "metal")

    // colored families
    for c in COLORS {
        registerBlock("\(c)_wool", hardness: 0.8, tool: .shears, sound: "cloth", flammable: 30, burnOdds: 60)
        registerBlock("\(c)_carpet", shape: .carpet, tex: .named("\(c)_wool"), opaque: false, fullCube: false, hardness: 0.1, sound: "cloth", flammable: 60, burnOdds: 20)
        stone("\(c)_concrete", 1.8)
        earth("\(c)_concrete_powder", 0.5, sound: "sand", gravity: true)
        stone("\(c)_terracotta", 1.25, resistance: 4.2)
        registerBlock("\(c)_glazed_terracotta", hardness: 1.4, resistance: 2.8, tool: .pickaxe, requiresTool: true, piston: .block)
        registerBlock("\(c)_stained_glass", opaque: false, lightOpacity: 0, hardness: 0.3, sound: "glass", translucent: true, cullSame: true, drops: .none)
        registerBlock("\(c)_stained_glass_pane", shape: .pane, tex: .named("\(c)_stained_glass"), opaque: false, fullCube: false, hardness: 0.3, sound: "glass", translucent: true, drops: .none)
        registerBlock("\(c)_bed", shape: .bed, tex: .named("\(c)_wool"), opaque: false, fullCube: false, hardness: 0.2, sound: "wood", piston: .destroy,
                      drops: .fn { m, _ in (m & 8) != 0 ? [] : [Drop("\(c)_bed")] })
        registerBlock("\(c)_candle", shape: .candle, tex: .named("\(c)_candle"), opaque: false, solid: false, fullCube: false, hardness: 0.1, sound: "candle", piston: .destroy,
                      drops: .fn { m, _ in [Drop("\(c)_candle", (m & 3) + 1)] })
        registerBlock("\(c)_shulker_box", opaque: false, hardness: 2, tool: .pickaxe, sound: "stone", piston: .blockEntity, drops: .none)
    }
    stone("terracotta", 1.25, resistance: 4.2)
    registerBlock("candle", shape: .candle, opaque: false, solid: false, fullCube: false, hardness: 0.1, sound: "candle", piston: .destroy,
                  drops: .fn { m, _ in [Drop("candle", (m & 3) + 1)] })
    registerBlock("shulker_box", opaque: false, hardness: 2, tool: .pickaxe, sound: "stone", piston: .blockEntity, drops: .none)

    // plants
    plant("short_grass", display: "Grass", replaceable: true, tint: 1,
          drops: .fn { _, ctx in ctx.shears ? [Drop("short_grass")] : (ctx.random() < 0.125 ? [Drop("wheat_seeds")] : []) })
    plant("fern", replaceable: true, tint: 1,
          drops: .fn { _, ctx in ctx.shears ? [Drop("fern")] : (ctx.random() < 0.125 ? [Drop("wheat_seeds")] : []) })
    plant("dead_bush", drops: .fn { _, ctx in ctx.shears ? [Drop("dead_bush")] : [Drop("stick", 0, 2)] })
    plant("tall_grass", shape: .tallCross, replaceable: true, tint: 1,
          drops: .fn { m, ctx in ctx.shears && (m & 1) == 0 ? [Drop("tall_grass")] : [] })
    plant("large_fern", shape: .tallCross, replaceable: true, tint: 1,
          drops: .fn { m, ctx in ctx.shears && (m & 1) == 0 ? [Drop("large_fern")] : [] })
    for f in FLOWERS { plant(f) }
    plant("wither_rose")
    for f in ["sunflower", "lilac", "rose_bush", "peony"] {
        plant(f, shape: .tallCross, tex: .named("\(f)_bottom"), texFn: { m, _ in tileId((m & 1) != 0 ? "\(f)_top" : "\(f)_bottom") },
              drops: .fn { m, _ in (m & 1) != 0 ? [] : [Drop(f)] })
    }
    plant("pitcher_plant", shape: .tallCross, tex: .named("pitcher_plant_bottom"), texFn: { m, _ in tileId((m & 1) != 0 ? "pitcher_plant_top" : "pitcher_plant_bottom") },
          drops: .fn { m, _ in (m & 1) != 0 ? [] : [Drop("pitcher_plant")] })
    registerBlock("pitcher_crop", shape: .pitcherCropShape, opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy, randomTicks: true, drops: .none, ao: false)
    plant("brown_mushroom", light: 1, flammable: 0)
    plant("red_mushroom", flammable: 0)
    plant("crimson_fungus", sound: "fungus", flammable: 0)
    plant("warped_fungus", sound: "fungus", flammable: 0)
    plant("crimson_roots", shape: .rootsShape, replaceable: true, sound: "fungus", flammable: 0)
    plant("warped_roots", shape: .rootsShape, replaceable: true, sound: "fungus", flammable: 0)
    plant("nether_sprouts", replaceable: true, sound: "fungus", flammable: 0,
          drops: .fn { _, ctx in ctx.shears ? [Drop("nether_sprouts")] : [] })
    registerBlock("weeping_vines", shape: .cross, opaque: false, solid: false, fullCube: false, hardness: 0, sound: "fungus", piston: .destroy, climbable: true, randomTicks: true,
                  drops: .fn { _, ctx in (ctx.shears || ctx.random() < 0.33) ? [Drop("weeping_vines")] : [] }, ao: false)
    registerBlock("twisting_vines", shape: .cross, opaque: false, solid: false, fullCube: false, hardness: 0, sound: "fungus", piston: .destroy, climbable: true, randomTicks: true,
                  drops: .fn { _, ctx in (ctx.shears || ctx.random() < 0.33) ? [Drop("twisting_vines")] : [] }, ao: false)
    registerBlock("sugar_cane", shape: .cross, opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", tint: 1, flammable: 60, piston: .destroy, randomTicks: true, ao: false)
    registerBlock("cactus", shape: .cactusShape, tex: texTB("cactus_top", "cactus_bottom", "cactus_side"), opaque: false, fullCube: false, hardness: 0.4, sound: "cloth", piston: .destroy, randomTicks: true)
    registerBlock("bamboo", shape: .bamboo, opaque: false, fullCube: false, hardness: 1, tool: .sword, sound: "bamboo", flammable: 60, piston: .destroy, randomTicks: true)
    registerBlock("bamboo_sapling", shape: .bambooSapling, opaque: false, solid: false, fullCube: false, hardness: 1, sound: "bamboo", piston: .destroy, randomTicks: true, drops: .item("bamboo"))
    registerBlock("vine", shape: .vine, opaque: false, solid: false, fullCube: false, hardness: 0.2, tool: .shears, sound: "grass", tint: 2, flammable: 15, burnOdds: 100, piston: .destroy, climbable: true, randomTicks: true,
                  drops: .fn { _, ctx in ctx.shears ? [Drop("vine")] : [] }, ao: false)
    registerBlock("glow_lichen", shape: .glowLichen, opaque: false, solid: false, fullCube: false, replaceable: true, light: 7, hardness: 0.2, tool: .shears, sound: "glow_lichen", piston: .destroy,
                  drops: .fn { _, ctx in ctx.shears ? [Drop("glow_lichen")] : [] }, ao: false)
    registerBlock("sculk_vein", shape: .sculkVein, opaque: false, solid: false, fullCube: false, replaceable: true, hardness: 0.2, tool: .hoe, sound: "sculk", piston: .destroy,
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("sculk_vein")] : [] }, ao: false)
    registerBlock("lily_pad", shape: .lilyPad, opaque: false, fullCube: false, hardness: 0, sound: "wet_grass", tint: 2, piston: .destroy)
    plant("seagrass", replaceable: true, sound: "wet_grass", flammable: 0,
          drops: .fn { _, ctx in ctx.shears ? [Drop("seagrass")] : [] })
    plant("tall_seagrass", shape: .tallCross, tex: .named("tall_seagrass_bottom"), texFn: { m, _ in tileId((m & 1) != 0 ? "tall_seagrass_top" : "tall_seagrass_bottom") },
          replaceable: true, sound: "wet_grass", flammable: 0, drops: .none)
    registerBlock("kelp", shape: .cross, opaque: false, solid: false, fullCube: false, hardness: 0, sound: "wet_grass", piston: .destroy, randomTicks: true, drops: .item("kelp"), ao: false)
    registerBlock("kelp_plant", shape: .cross, opaque: false, solid: false, fullCube: false, hardness: 0, sound: "wet_grass", piston: .destroy, drops: .item("kelp"), ao: false)
    registerBlock("sea_pickle", shape: .seaPickle, opaque: false, fullCube: false, light: 6, hardness: 0, sound: "slime", piston: .destroy,
                  drops: .fn { m, _ in [Drop("sea_pickle", (m & 3) + 1)] })
    registerBlock("spore_blossom", shape: .sporeBlossom, opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy)
    registerBlock("hanging_roots", shape: .hangingRoots, opaque: false, solid: false, fullCube: false, replaceable: true, hardness: 0, tool: .shears, sound: "hanging_sign", piston: .destroy,
                  drops: .fn { _, ctx in ctx.shears ? [Drop("hanging_roots")] : [] }, ao: false)
    registerBlock("big_dripleaf", shape: .bigDripleaf, opaque: false, fullCube: false, hardness: 0.1, sound: "big_dripleaf", tint: 2, flammable: 15, piston: .destroy)
    registerBlock("big_dripleaf_stem", shape: .cross, tex: .named("big_dripleaf_stem"), opaque: false, solid: false, fullCube: false, hardness: 0.1, sound: "big_dripleaf", tint: 2, piston: .destroy, drops: .item("big_dripleaf"), ao: false)
    registerBlock("small_dripleaf", shape: .smallDripleafShape, opaque: false, solid: false, fullCube: false, hardness: 0, sound: "big_dripleaf", tint: 2, piston: .destroy,
                  drops: .fn { m, ctx in ctx.shears && (m & 1) == 0 ? [Drop("small_dripleaf")] : [] })
    registerBlock("moss_block", hardness: 0.1, tool: .hoe, sound: "moss")
    registerBlock("moss_carpet", shape: .carpet, tex: .named("moss_block"), opaque: false, fullCube: false, hardness: 0.1, sound: "moss", piston: .destroy)
    registerBlock("pink_petals", shape: .frogspawn, tex: .named("pink_petals"), opaque: false, solid: false, fullCube: false, hardness: 0, sound: "cherry", piston: .destroy,
                  drops: .fn { m, _ in [Drop("pink_petals", (m & 3) + 1)] }, ao: false)
    registerBlock("azalea", shape: .cross, opaque: false, fullCube: false, hardness: 0, sound: "azalea", flammable: 60, piston: .destroy, randomTicks: true)
    registerBlock("flowering_azalea", shape: .cross, opaque: false, fullCube: false, hardness: 0, sound: "azalea", flammable: 60, piston: .destroy, randomTicks: true)
    registerBlock("cave_vines", shape: .caveVinesShape, tex: .named("cave_vines"), texFn: { m, _ in tileId((m & 8) != 0 ? "cave_vines_lit" : "cave_vines") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy, climbable: true, randomTicks: true,
                  drops: .fn { m, _ in (m & 8) != 0 ? [Drop("glow_berries")] : [] }, ao: false)
    registerBlock("cave_vines_plant", shape: .caveVinesShape, tex: .named("cave_vines_plant"), texFn: { m, _ in tileId((m & 8) != 0 ? "cave_vines_plant_lit" : "cave_vines_plant") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy, climbable: true,
                  drops: .fn { m, _ in (m & 8) != 0 ? [Drop("glow_berries")] : [] }, ao: false)
    registerBlock("sweet_berry_bush", shape: .sweetBerry, tex: .named("sweet_berry_bush_stage3"), texFn: { m, _ in tileId("sweet_berry_bush_stage\(min(3, m & 3))") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy, randomTicks: true,
                  drops: .fn { m, _ in (m & 3) >= 2 ? [Drop("sweet_berries", 1, 3)] : [] })

    // crops
    registerBlock("wheat", shape: .crop, tex: .named("wheat_stage7"), texFn: { m, _ in tileId("wheat_stage\(min(7, m & 7))") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy, randomTicks: true,
                  drops: .fn { m, ctx in (m & 7) >= 7 ? [Drop("wheat"), Drop("wheat_seeds", 1, 3 + ctx.fortune)] : [Drop("wheat_seeds")] }, ao: false)
    registerBlock("carrots", shape: .crop, tex: .named("carrots_stage3"), texFn: { m, _ in tileId("carrots_stage\(min(3, (m & 7) >> 1))") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy, randomTicks: true,
                  drops: .fn { m, ctx in (m & 7) >= 7 ? [Drop("carrot", 2, 5 + ctx.fortune)] : [Drop("carrot")] }, ao: false)
    registerBlock("potatoes", shape: .crop, tex: .named("potatoes_stage3"), texFn: { m, _ in tileId("potatoes_stage\(min(3, (m & 7) >> 1))") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy, randomTicks: true,
                  drops: .fn { m, ctx in
                      if (m & 7) < 7 { return [Drop("potato")] }
                      var d = [Drop("potato", 2, 5 + ctx.fortune)]
                      if ctx.random() < 0.02 { d.append(Drop("poisonous_potato")) }
                      return d
                  }, ao: false)
    registerBlock("beetroots", shape: .crop, tex: .named("beetroots_stage3"), texFn: { m, _ in tileId("beetroots_stage\(min(3, m & 3))") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy, randomTicks: true,
                  drops: .fn { m, ctx in (m & 3) >= 3 ? [Drop("beetroot"), Drop("beetroot_seeds", 1, 3 + ctx.fortune)] : [Drop("beetroot_seeds")] }, ao: false)
    registerBlock("torchflower_crop", shape: .crop, tex: .named("torchflower_crop_stage1"), texFn: { m, _ in tileId("torchflower_crop_stage\(min(1, m & 1))") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", piston: .destroy, randomTicks: true, drops: .item("torchflower_seeds"), ao: false)
    registerBlock("melon_stem", shape: .crop, tex: .named("stem_stage7"), texFn: { m, _ in tileId((m & 8) != 0 ? "attached_stem" : "stem_stage\(m & 7)") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", tint: 1, piston: .destroy, randomTicks: true,
                  drops: .fn { _, ctx in ctx.random() < 0.4 ? [Drop("melon_seeds")] : [] }, ao: false)
    registerBlock("pumpkin_stem", shape: .crop, tex: .named("stem_stage7"), texFn: { m, _ in tileId((m & 8) != 0 ? "attached_stem" : "stem_stage\(m & 7)") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "grass", tint: 1, piston: .destroy, randomTicks: true,
                  drops: .fn { _, ctx in ctx.random() < 0.4 ? [Drop("pumpkin_seeds")] : [] }, ao: false)
    registerBlock("melon", tex: texCol("melon_top", "melon_side"), hardness: 1, tool: .axe, sound: "wood",
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("melon")] : [Drop("melon_slice", 3, min(9, 7 + ctx.fortune))] })
    registerBlock("pumpkin", tex: texCol("pumpkin_top", "pumpkin_side"), hardness: 1, tool: .axe, sound: "wood")
    registerBlock("carved_pumpkin", tex: tex6("pumpkin_top", "pumpkin_top", "carved_pumpkin", "pumpkin_side", "pumpkin_side", "pumpkin_side"),
                  texFn: { m, f in
                      let face = [2, 3, 4, 5][m & 3]
                      return f == face ? tileId("carved_pumpkin") : (f <= 1 ? tileId("pumpkin_top") : tileId("pumpkin_side"))
                  }, hardness: 1, tool: .axe, sound: "wood")
    registerBlock("jack_o_lantern", tex: tex6("pumpkin_top", "pumpkin_top", "jack_o_lantern", "pumpkin_side", "pumpkin_side", "pumpkin_side"),
                  texFn: { m, f in
                      let face = [2, 3, 4, 5][m & 3]
                      return f == face ? tileId("jack_o_lantern") : (f <= 1 ? tileId("pumpkin_top") : tileId("pumpkin_side"))
                  }, light: 15, hardness: 1, tool: .axe, sound: "wood")
    registerBlock("cocoa", shape: .cocoa, tex: .named("cocoa_stage2"), texFn: { m, _ in tileId("cocoa_stage\((m >> 2) & 3)") },
                  opaque: false, fullCube: false, hardness: 0.2, tool: .axe, sound: "wood", piston: .destroy, randomTicks: true,
                  drops: .fn { m, _ in [Drop("cocoa_beans", ((m >> 2) & 3) >= 2 ? 3 : 1)] })
    registerBlock("nether_wart", shape: .netherWart, tex: .named("nether_wart_stage2"), texFn: { m, _ in tileId("nether_wart_stage\(min(2, m & 3))") },
                  opaque: false, solid: false, fullCube: false, hardness: 0, sound: "wart", piston: .destroy, randomTicks: true,
                  drops: .fn { m, ctx in (m & 3) >= 3 ? [Drop("nether_wart", 2, 4 + ctx.fortune)] : [Drop("nether_wart")] }, ao: false)

    registerSnowToEnd()
}
