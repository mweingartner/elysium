// Block registrations, part 3: functional blocks, redstone, rails, stone
// families, copper, amethyst, mushroom, misc — then lookup tables.

import Foundation

private func facingFrontTexFn(_ front: String, _ top: String, _ side: String, bottom: String? = nil) -> (Int, Int) -> Int {
    { m, f in
        let face = [2, 3, 4, 5][m & 3]
        if f == face { return tileId(front) }
        if let b = bottom {
            return f == 1 ? tileId(top) : f == 0 ? tileId(b) : tileId(side)
        }
        return f <= 1 ? tileId(top) : tileId(side)
    }
}

func registerFunctionalToEnd() {
    // functional blocks
    registerBlock("crafting_table", tex: tex6("oak_planks", "crafting_table_top", "crafting_table_front", "crafting_table_side", "crafting_table_side", "crafting_table_front"), hardness: 2.5, tool: .axe, sound: "wood", flammable: 5)
    registerBlock("furnace", tex: tex6("furnace_top", "furnace_top", "furnace_front", "furnace_side", "furnace_side", "furnace_side"),
                  texFn: facingFrontTexFn("furnace_front", "furnace_top", "furnace_side"), hardness: 3.5, tool: .pickaxe, requiresTool: true, piston: .blockEntity)
    registerBlock("furnace_lit", tex: tex6("furnace_top", "furnace_top", "furnace_front_lit", "furnace_side", "furnace_side", "furnace_side"),
                  texFn: facingFrontTexFn("furnace_front_lit", "furnace_top", "furnace_side"), light: 13, hardness: 3.5, tool: .pickaxe, requiresTool: true, piston: .blockEntity, drops: .item("furnace"))
    registerBlock("blast_furnace", tex: tex6("blast_furnace_top", "blast_furnace_top", "blast_furnace_front", "blast_furnace_side", "blast_furnace_side", "blast_furnace_side"),
                  texFn: facingFrontTexFn("blast_furnace_front", "blast_furnace_top", "blast_furnace_side"), hardness: 3.5, tool: .pickaxe, requiresTool: true, piston: .blockEntity)
    registerBlock("blast_furnace_lit", tex: tex6("blast_furnace_top", "blast_furnace_top", "blast_furnace_front_lit", "blast_furnace_side", "blast_furnace_side", "blast_furnace_side"),
                  texFn: facingFrontTexFn("blast_furnace_front_lit", "blast_furnace_top", "blast_furnace_side"), light: 13, hardness: 3.5, tool: .pickaxe, requiresTool: true, piston: .blockEntity, drops: .item("blast_furnace"))
    registerBlock("smoker", tex: tex6("smoker_bottom", "smoker_top", "smoker_front", "smoker_side", "smoker_side", "smoker_side"),
                  texFn: facingFrontTexFn("smoker_front", "smoker_top", "smoker_side", bottom: "smoker_bottom"), hardness: 3.5, tool: .pickaxe, requiresTool: true, piston: .blockEntity)
    registerBlock("smoker_lit", tex: tex6("smoker_bottom", "smoker_top", "smoker_front_lit", "smoker_side", "smoker_side", "smoker_side"),
                  texFn: facingFrontTexFn("smoker_front_lit", "smoker_top", "smoker_side", bottom: "smoker_bottom"), light: 13, hardness: 3.5, tool: .pickaxe, requiresTool: true, piston: .blockEntity, drops: .item("smoker"))
    registerBlock("chest", shape: .chest, tex: .named("chest_side"), opaque: false, fullCube: false, hardness: 2.5, tool: .axe, sound: "wood", flammable: 5, piston: .blockEntity)
    registerBlock("trapped_chest", shape: .chest, tex: .named("chest_side"), opaque: false, fullCube: false, hardness: 2.5, tool: .axe, sound: "wood", flammable: 5, piston: .blockEntity)
    registerBlock("ender_chest", shape: .chest, tex: .named("ender_chest_side"), opaque: false, fullCube: false, light: 7, hardness: 22.5, resistance: 600, tool: .pickaxe, requiresTool: true, piston: .blockEntity,
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("ender_chest")] : [Drop("obsidian", 8)] })
    registerBlock("barrel", tex: texCol("barrel_top", "barrel_side"),
                  texFn: { m, f in
                      let facing = m & 7
                      let openTop = (m & 8) != 0
                      if f == facing { return tileId(openTop ? "barrel_top_open" : "barrel_top") }
                      if (f ^ 1) == facing { return tileId("barrel_bottom") }
                      return tileId("barrel_side")
                  }, hardness: 2.5, tool: .axe, sound: "wood", piston: .blockEntity)
    registerBlock("bookshelf", tex: texCol("oak_planks", "bookshelf"), hardness: 1.5, tool: .axe, sound: "wood", flammable: 30, burnOdds: 20, drops: .list([Drop("book", 3)]))
    registerBlock("chiseled_bookshelf", tex: texCol("chiseled_bookshelf_top", "chiseled_bookshelf_empty"),
                  texFn: facingFrontTexFn("chiseled_bookshelf_occupied", "chiseled_bookshelf_top", "chiseled_bookshelf_side"),
                  hardness: 1.5, tool: .axe, sound: "wood", flammable: 30, burnOdds: 20, piston: .blockEntity, drops: .none)
    registerBlock("enchanting_table", shape: .enchantTable, tex: tex6("enchanting_table_bottom", "enchanting_table_top", "enchanting_table_side", "enchanting_table_side", "enchanting_table_side", "enchanting_table_side"),
                  opaque: false, fullCube: false, light: 7, hardness: 5, resistance: 1200, tool: .pickaxe, requiresTool: true, piston: .blockEntity)
    registerBlock("anvil", shape: .anvil, tex: texCol("anvil_top", "anvil_side"), opaque: false, fullCube: false, hardness: 5, resistance: 1200, tool: .pickaxe, requiresTool: true, sound: "anvil", piston: .block, gravity: true)
    registerBlock("chipped_anvil", shape: .anvil, tex: texCol("chipped_anvil_top", "anvil_side"), opaque: false, fullCube: false, hardness: 5, resistance: 1200, tool: .pickaxe, requiresTool: true, sound: "anvil", piston: .block, gravity: true)
    registerBlock("damaged_anvil", shape: .anvil, tex: texCol("damaged_anvil_top", "anvil_side"), opaque: false, fullCube: false, hardness: 5, resistance: 1200, tool: .pickaxe, requiresTool: true, sound: "anvil", piston: .block, gravity: true)
    registerBlock("grindstone", shape: .grindstone, tex: texCol("grindstone_pivot", "grindstone_side"), opaque: false, fullCube: false, hardness: 2, resistance: 6, tool: .pickaxe, requiresTool: true, piston: .block)
    registerBlock("stonecutter", shape: .stonecutter, tex: tex6("stonecutter_bottom", "stonecutter_top", "stonecutter_side", "stonecutter_side", "stonecutter_side", "stonecutter_side"), opaque: false, fullCube: false, hardness: 3.5, tool: .pickaxe, requiresTool: true)
    registerBlock("smithing_table", tex: tex6("smithing_table_bottom", "smithing_table_top", "smithing_table_front", "smithing_table_front", "smithing_table_side", "smithing_table_side"), hardness: 2.5, tool: .axe, sound: "wood")
    registerBlock("fletching_table", tex: tex6("fletching_table_top", "fletching_table_top", "fletching_table_front", "fletching_table_front", "fletching_table_side", "fletching_table_side"), hardness: 2.5, tool: .axe, sound: "wood", flammable: 5)
    registerBlock("cartography_table", tex: tex6("cartography_table_side", "cartography_table_top", "cartography_table_side", "cartography_table_side", "cartography_table_side", "cartography_table_side"), hardness: 2.5, tool: .axe, sound: "wood", flammable: 5)
    registerBlock("loom", tex: tex6("loom_bottom", "loom_top", "loom_front", "loom_front", "loom_side", "loom_side"), hardness: 2.5, tool: .axe, sound: "wood", flammable: 5)
    registerBlock("composter", shape: .composter, tex: texTB("composter_top", "composter_bottom", "composter_side"), opaque: false, fullCube: false, hardness: 0.6, tool: .axe, sound: "wood", flammable: 5)
    registerBlock("cauldron", shape: .cauldron, tex: texTB("cauldron_top", "cauldron_bottom", "cauldron_side"), opaque: false, fullCube: false, hardness: 2, tool: .pickaxe, requiresTool: true, sound: "metal", drops: .item("cauldron"))
    registerBlock("brewing_stand", shape: .brewingStand, tex: .named("brewing_stand"), opaque: false, fullCube: false, light: 1, hardness: 0.5, tool: .pickaxe, requiresTool: true, piston: .blockEntity)
    registerBlock("jukebox", tex: texCol("jukebox_top", "jukebox_side"), hardness: 2, tool: .axe, sound: "wood", flammable: 5, piston: .blockEntity)
    registerBlock("note_block", tex: .named("note_block"), hardness: 0.8, tool: .axe, sound: "wood", flammable: 5)
    registerBlock("lectern", shape: .lectern, tex: texTB("lectern_top", "oak_planks", "lectern_side"), opaque: false, fullCube: false, hardness: 2.5, tool: .axe, sound: "wood", flammable: 5)
    registerBlock("bell", shape: .bell, tex: .named("bell_body"), opaque: false, fullCube: false, hardness: 5, tool: .pickaxe, requiresTool: true, sound: "metal", piston: .destroy)
    registerBlock("ladder", shape: .ladder, tex: .named("ladder"), opaque: false, solid: false, fullCube: false, hardness: 0.4, tool: .axe, sound: "ladder", piston: .destroy, climbable: true, ao: false)
    registerBlock("scaffolding", shape: .scaffolding, tex: texCol("scaffolding_top", "scaffolding_side"), opaque: false, solid: false, fullCube: false, hardness: 0, sound: "scaffolding", flammable: 60, piston: .destroy, climbable: true, ao: false)
    registerBlock("torch", shape: .torch, tex: .named("torch"), opaque: false, solid: false, fullCube: false, light: 14, hardness: 0, sound: "wood", piston: .destroy, emissiveRender: true, ao: false)
    registerBlock("soul_torch", shape: .torch, tex: .named("soul_torch"), opaque: false, solid: false, fullCube: false, light: 10, hardness: 0, sound: "wood", piston: .destroy, emissiveRender: true, ao: false)
    registerBlock("lantern", shape: .lantern, tex: .named("lantern"), opaque: false, fullCube: false, light: 15, hardness: 3.5, tool: .pickaxe, requiresTool: true, sound: "chain", piston: .destroy, emissiveRender: true)
    registerBlock("soul_lantern", shape: .lantern, tex: .named("soul_lantern"), opaque: false, fullCube: false, light: 10, hardness: 3.5, tool: .pickaxe, requiresTool: true, sound: "chain", piston: .destroy, emissiveRender: true)
    registerBlock("chain", shape: .chain, tex: .named("chain"), opaque: false, fullCube: false, hardness: 5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "chain")
    registerBlock("campfire", shape: .campfire, tex: .named("campfire_log"), opaque: false, fullCube: false, light: 15, hardness: 2, tool: .axe, sound: "wood", piston: .destroy, emissiveRender: true,
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("campfire")] : [Drop("charcoal", 2)] })
    registerBlock("soul_campfire", shape: .campfire, tex: .named("soul_campfire_log"), opaque: false, fullCube: false, light: 10, hardness: 2, tool: .axe, sound: "wood", piston: .destroy, emissiveRender: true,
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("soul_campfire")] : [Drop("soul_soil")] })
    registerBlock("beacon", shape: .beacon, tex: .named("beacon"), opaque: false, fullCube: false, light: 15, hardness: 3, sound: "glass", piston: .blockEntity)
    registerBlock("conduit", shape: .conduit, tex: .named("conduit"), opaque: false, fullCube: false, light: 15, hardness: 3, piston: .blockEntity)
    registerBlock("lodestone", tex: texCol("lodestone_top", "lodestone_side"), hardness: 3.5, resistance: 3.5, tool: .pickaxe, requiresTool: true)
    registerBlock("respawn_anchor", tex: texCol("respawn_anchor_top", "respawn_anchor_side"),
                  texFn: { m, f in
                      if f == 1 { return tileId((m & 7) > 0 ? "respawn_anchor_top" : "respawn_anchor_top_off") }
                      return f == 0 ? tileId("respawn_anchor_bottom") : tileId("respawn_anchor_side")
                  }, hardness: 50, resistance: 1200, tool: .pickaxe, tier: 3, requiresTool: true, piston: .block, emissiveRender: true)
    registerBlock("flower_pot", shape: .flowerPot, tex: .named("flower_pot"), opaque: false, fullCube: false, hardness: 0, piston: .destroy,
                  drops: .fn { _, _ in [Drop("flower_pot")] })
    registerBlock("decorated_pot", shape: .decoratedPot, tex: .named("decorated_pot_side"), opaque: false, fullCube: false, hardness: 0, sound: "decorated_pot", piston: .destroy, drops: .none)
    registerBlock("spawner", opaque: false, lightOpacity: 1, hardness: 5, tool: .pickaxe, requiresTool: true, sound: "spawner", piston: .blockEntity, transparentRender: true, drops: .none)
    registerBlock("slime_block", opaque: false, lightOpacity: 0, hardness: 0, sound: "slime", translucent: true, cullSame: true)
    registerBlock("honey_block", opaque: false, fullCube: false, lightOpacity: 0, hardness: 0, sound: "honey", translucent: true)
    registerBlock("honeycomb_block", hardness: 0.6, sound: "coral")
    registerBlock("bee_nest", tex: tex6("bee_nest_bottom", "bee_nest_top", "bee_nest_front", "bee_nest_side", "bee_nest_side", "bee_nest_side"), hardness: 0.3, tool: .axe, sound: "wood", flammable: 30, burnOdds: 20, piston: .blockEntity, drops: .none)
    registerBlock("beehive", tex: tex6("beehive_end", "beehive_end", "beehive_front", "beehive_side", "beehive_side", "beehive_side"), hardness: 0.6, tool: .axe, sound: "wood", flammable: 30, burnOdds: 20, piston: .blockEntity, drops: .item("beehive"))
    registerBlock("hay_block", tex: texCol("hay_block_top", "hay_block_side"), hardness: 0.5, tool: .hoe, sound: "grass", flammable: 60, burnOdds: 20)
    registerBlock("target", tex: texCol("target_top", "target_side"), hardness: 0.5, tool: .hoe, sound: "grass")
    registerBlock("tnt", tex: texTB("tnt_top", "tnt_bottom", "tnt_side"), hardness: 0, sound: "grass", flammable: 15, burnOdds: 100)
    registerBlock("cake", shape: .cake, tex: texTB("cake_top", "cake_bottom", "cake_side"), opaque: false, fullCube: false, hardness: 0.5, sound: "cloth", piston: .destroy, drops: .none)
    registerBlock("dragon_head", shape: .head, tex: .named("obsidian"), opaque: false, solid: false, fullCube: false, hardness: 1, piston: .destroy, drops: .item("dragon_head"))
    registerBlock("skeleton_skull", shape: .head, tex: .named("bone_block_side"), opaque: false, solid: false, fullCube: false, hardness: 1, piston: .destroy, drops: .item("skeleton_skull"))
    registerBlock("wither_skeleton_skull", shape: .head, tex: .named("blackstone"), opaque: false, solid: false, fullCube: false, hardness: 1, piston: .destroy, drops: .item("wither_skeleton_skull"))

    // redstone
    registerBlock("redstone_wire", shape: .redstoneWire, tex: .named("redstone_dust_dot"), opaque: false, solid: false, fullCube: false, hardness: 0, piston: .destroy, drops: .item("redstone"), ao: false)
    registerBlock("redstone_torch", shape: .torch, tex: .named("redstone_torch"), opaque: false, solid: false, fullCube: false, light: 7, hardness: 0, sound: "wood", piston: .destroy, emissiveRender: true, ao: false)
    registerBlock("redstone_torch_off", shape: .torch, tex: .named("redstone_torch_off"), opaque: false, solid: false, fullCube: false, hardness: 0, sound: "wood", piston: .destroy, drops: .item("redstone_torch"), ao: false)
    registerBlock("repeater", shape: .repeater, tex: .named("repeater"), opaque: false, fullCube: false, hardness: 0, sound: "wood", piston: .destroy, drops: .item("repeater"))
    registerBlock("repeater_on", shape: .repeater, tex: .named("repeater_on"), opaque: false, fullCube: false, light: 7, hardness: 0, sound: "wood", piston: .destroy, drops: .item("repeater"))
    registerBlock("comparator", shape: .comparator, tex: .named("comparator"), opaque: false, fullCube: false, hardness: 0, sound: "wood", piston: .destroy, drops: .item("comparator"))
    registerBlock("comparator_on", shape: .comparator, tex: .named("comparator_on"), opaque: false, fullCube: false, light: 7, hardness: 0, sound: "wood", piston: .destroy, drops: .item("comparator"))
    registerBlock("lever", shape: .lever, tex: .named("lever"), opaque: false, solid: false, fullCube: false, hardness: 0.5, sound: "wood", piston: .destroy)
    registerBlock("stone_button", shape: .button, tex: .named("stone"), opaque: false, solid: false, fullCube: false, hardness: 0.5, piston: .destroy)
    registerBlock("polished_blackstone_button", shape: .button, tex: .named("polished_blackstone"), opaque: false, solid: false, fullCube: false, hardness: 0.5, piston: .destroy)
    registerBlock("stone_pressure_plate", shape: .pressurePlate, tex: .named("stone"), opaque: false, solid: false, fullCube: false, hardness: 0.5, tool: .pickaxe, requiresTool: true, piston: .destroy)
    registerBlock("polished_blackstone_pressure_plate", shape: .pressurePlate, tex: .named("polished_blackstone"), opaque: false, solid: false, fullCube: false, hardness: 0.5, tool: .pickaxe, requiresTool: true, piston: .destroy)
    registerBlock("light_weighted_pressure_plate", shape: .pressurePlate, tex: .named("gold_block"), opaque: false, solid: false, fullCube: false, hardness: 0.5, tool: .pickaxe, requiresTool: true, sound: "metal", piston: .destroy)
    registerBlock("heavy_weighted_pressure_plate", shape: .pressurePlate, tex: .named("iron_block"), opaque: false, solid: false, fullCube: false, hardness: 0.5, tool: .pickaxe, requiresTool: true, sound: "metal", piston: .destroy)
    registerBlock("tripwire_hook", shape: .tripwireHook, tex: .named("tripwire_hook"), opaque: false, solid: false, fullCube: false, hardness: 0, sound: "wood", piston: .destroy)
    registerBlock("tripwire", shape: .tripwire, tex: .named("tripwire"), opaque: false, solid: false, fullCube: false, hardness: 0, piston: .destroy, drops: .item("string"), ao: false)
    registerBlock("piston", shape: .piston, tex: texCol("piston_top", "piston_side"), opaque: false, fullCube: false, hardness: 1.5, piston: .block)
    registerBlock("sticky_piston", shape: .piston, tex: texCol("piston_top_sticky", "piston_side"), opaque: false, fullCube: false, hardness: 1.5, piston: .block)
    registerBlock("piston_head", shape: .pistonHead, tex: texCol("piston_top", "piston_side"), opaque: false, fullCube: false, hardness: 1.5, piston: .block, drops: .none)
    registerBlock("moving_piston", tex: .named("piston_side"), opaque: false, solid: false, fullCube: false, hardness: -1, piston: .block, drops: .none)
    registerBlock("observer", tex: texCol("observer_top", "observer_side"),
                  texFn: { m, f in
                      let facing = m & 7
                      if f == facing { return tileId("observer_front") }
                      if (f ^ 1) == facing { return tileId((m & 8) != 0 ? "observer_back_lit" : "observer_back") }
                      return (f <= 1 || facing <= 1) ? tileId("observer_top") : tileId("observer_side")
                  }, hardness: 3, tool: .pickaxe, requiresTool: true)
    registerBlock("dispenser", tex: texCol("furnace_top", "furnace_side"),
                  texFn: { m, f in
                      let facing = m & 7
                      if f == facing { return tileId(facing <= 1 ? "dispenser_front_vertical" : "dispenser_front") }
                      return f <= 1 ? tileId("furnace_top") : tileId("furnace_side")
                  }, hardness: 3.5, tool: .pickaxe, requiresTool: true, piston: .blockEntity)
    registerBlock("dropper", tex: texCol("furnace_top", "furnace_side"),
                  texFn: { m, f in
                      let facing = m & 7
                      if f == facing { return tileId(facing <= 1 ? "dropper_front_vertical" : "dropper_front") }
                      return f <= 1 ? tileId("furnace_top") : tileId("furnace_side")
                  }, hardness: 3.5, tool: .pickaxe, requiresTool: true, piston: .blockEntity)
    registerBlock("hopper", shape: .hopper, tex: texTB("hopper_top", "hopper_outside", "hopper_outside"), opaque: false, fullCube: false, hardness: 3, resistance: 4.8, tool: .pickaxe, requiresTool: true, sound: "metal", piston: .blockEntity)
    registerBlock("redstone_lamp", hardness: 0.3, sound: "glass")
    registerBlock("redstone_lamp_on", light: 15, hardness: 0.3, sound: "glass", drops: .item("redstone_lamp"))
    registerBlock("daylight_detector", shape: .daylightSensor, tex: texTB("daylight_detector_top", "daylight_detector_side", "daylight_detector_side"), opaque: false, fullCube: false, hardness: 0.2, tool: .axe, sound: "wood", piston: .blockEntity)
    registerBlock("daylight_detector_inverted", shape: .daylightSensor, tex: texTB("daylight_detector_inverted_top", "daylight_detector_side", "daylight_detector_side"), opaque: false, fullCube: false, hardness: 0.2, tool: .axe, sound: "wood", piston: .blockEntity, drops: .item("daylight_detector"))
    registerBlock("sculk_sensor", shape: .daylightSensor, tex: texTB("sculk_sensor_top", "sculk_sensor_bottom", "sculk_sensor_side"), opaque: false, fullCube: false, light: 1, hardness: 1.5, tool: .hoe, sound: "sculk_sensor", piston: .destroy,
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("sculk_sensor")] : [] })
    registerBlock("calibrated_sculk_sensor", shape: .daylightSensor, tex: texTB("calibrated_sculk_sensor_top", "sculk_sensor_bottom", "calibrated_sculk_sensor_side"), opaque: false, fullCube: false, light: 1, hardness: 1.5, tool: .hoe, sound: "sculk_sensor", piston: .destroy,
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("calibrated_sculk_sensor")] : [] })
    registerBlock("sculk", hardness: 0.2, tool: .hoe, sound: "sculk",
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("sculk")] : [] })
    registerBlock("sculk_catalyst", tex: texTB("sculk_catalyst_top", "sculk_catalyst_bottom", "sculk_catalyst_side"), light: 6, hardness: 3, tool: .hoe, sound: "sculk_catalyst",
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("sculk_catalyst")] : [] })
    registerBlock("sculk_shrieker", shape: .daylightSensor, tex: texTB("sculk_shrieker_top", "sculk_shrieker_bottom", "sculk_shrieker_side"), opaque: false, fullCube: false, hardness: 3, tool: .hoe, sound: "sculk_shrieker", piston: .destroy,
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("sculk_shrieker")] : [] })

    // rails
    registerBlock("rail", shape: .rail, tex: .named("rail"), opaque: false, solid: false, fullCube: false, hardness: 0.7, tool: .pickaxe, sound: "metal", ao: false)
    registerBlock("powered_rail", shape: .rail, tex: .named("powered_rail"), texFn: { m, _ in tileId((m & 8) != 0 ? "powered_rail_on" : "powered_rail") }, opaque: false, solid: false, fullCube: false, hardness: 0.7, tool: .pickaxe, sound: "metal", ao: false)
    registerBlock("detector_rail", shape: .rail, tex: .named("detector_rail"), texFn: { m, _ in tileId((m & 8) != 0 ? "detector_rail_on" : "detector_rail") }, opaque: false, solid: false, fullCube: false, hardness: 0.7, tool: .pickaxe, sound: "metal", ao: false)
    registerBlock("activator_rail", shape: .rail, tex: .named("activator_rail"), texFn: { m, _ in tileId((m & 8) != 0 ? "activator_rail_on" : "activator_rail") }, opaque: false, solid: false, fullCube: false, hardness: 0.7, tool: .pickaxe, sound: "metal", ao: false)

    registerBlock("iron_door", shape: .door, tex: .named("iron_door"), opaque: false, fullCube: false, hardness: 5, resistance: 5, tool: .pickaxe, requiresTool: true, sound: "metal", piston: .destroy,
                  drops: .fn { m, _ in (m & 8) != 0 ? [] : [Drop("iron_door")] })
    registerBlock("iron_trapdoor", shape: .trapdoor, tex: .named("iron_trapdoor"), opaque: false, fullCube: false, hardness: 5, resistance: 5, tool: .pickaxe, requiresTool: true, sound: "metal")

    // stone families (stairs/slabs/walls)
    let NO_WALL: Set<String> = ["smooth_stone", "purpur", "quartz", "smooth_quartz", "smooth_sandstone", "smooth_red_sandstone", "cut_sandstone", "cut_red_sandstone"]
    let NO_STAIRS: Set<String> = ["cut_sandstone", "cut_red_sandstone"]
    for (fam, baseTex) in STONE_FAMILIES {
        let deep = fam.contains("deepslate")
        let snd = deep ? "deepslate" : fam.contains("nether_brick") ? "nether_brick" : fam.contains("tuff") ? "tuff" : fam.contains("mud") ? "mud" : "stone"
        let sideTex = blockExists(baseTex) ? (baseTex == "sandstone" ? "sandstone_side" : baseTex == "red_sandstone" ? "red_sandstone_side" : baseTex) : baseTex
        if !NO_STAIRS.contains(fam) {
            registerBlock("\(fam)_stairs", shape: .stairs, tex: .named(sideTex), opaque: false, fullCube: false, lightOpacity: 0, hardness: 1.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: snd)
        }
        registerBlock("\(fam)_slab", shape: .slab, tex: .named(sideTex), opaque: false, fullCube: false, lightOpacity: 0, hardness: 1.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: snd,
                      drops: .fn { m, _ in [Drop("\(fam)_slab", (m & 3) == 2 ? 2 : 1)] })
        if !NO_WALL.contains(fam) {
            registerBlock("\(fam)_wall", shape: .wall, tex: .named(sideTex), opaque: false, fullCube: false, hardness: 1.5, resistance: 6, tool: .pickaxe, requiresTool: true, sound: snd)
        }
    }
    registerBlock("petrified_oak_slab", shape: .slab, tex: .named("oak_planks"), opaque: false, fullCube: false, lightOpacity: 0, hardness: 2, resistance: 6, tool: .pickaxe, requiresTool: true)

    // copper chain
    for stage in 0..<4 {
        for waxed in ["", "waxed_"] {
            let p = waxed + COPPER_STAGES[stage]
            let baseTexName = COPPER_STAGES[stage].isEmpty ? "copper_block" : "\(COPPER_STAGES[stage])copper"
            let ticks = waxed.isEmpty && stage < 3
            registerBlock("\(p)copper_block", tex: .named(baseTexName),
                          display: prettify("\(p)copper\(waxed.isEmpty && stage == 0 ? " block" : "")"),
                          hardness: 3, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "copper", randomTicks: ticks)
            registerBlock("\(p)cut_copper", tex: .named("\(COPPER_STAGES[stage])cut_copper"), hardness: 3, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "copper", randomTicks: ticks)
            registerBlock("\(p)cut_copper_stairs", shape: .stairs, tex: .named("\(COPPER_STAGES[stage])cut_copper"), opaque: false, fullCube: false, lightOpacity: 0, hardness: 3, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "copper", randomTicks: ticks)
            registerBlock("\(p)cut_copper_slab", shape: .slab, tex: .named("\(COPPER_STAGES[stage])cut_copper"), opaque: false, fullCube: false, lightOpacity: 0, hardness: 3, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "copper", randomTicks: ticks)
        }
    }
    registerBlock("lightning_rod", shape: .torch, tex: .named("lightning_rod"), opaque: false, fullCube: false, hardness: 3, resistance: 6, tool: .pickaxe, requiresTool: true, sound: "copper")

    // amethyst / dripstone / lush pieces
    registerBlock("amethyst_cluster", shape: .amethystCluster, tex: .named("amethyst_cluster"), opaque: false, solid: false, fullCube: false, light: 5, hardness: 1.5, tool: .pickaxe, sound: "amethyst", piston: .destroy,
                  drops: .fn { _, ctx in ctx.toolType == .pickaxe ? [Drop("amethyst_shard", 4 + max(0, ctx.fortune))] : [Drop("amethyst_shard", 2)] })
    registerBlock("large_amethyst_bud", shape: .amethystCluster, tex: .named("large_amethyst_bud"), opaque: false, solid: false, fullCube: false, light: 4, hardness: 1.5, tool: .pickaxe, sound: "amethyst", piston: .destroy,
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("large_amethyst_bud")] : [] })
    registerBlock("medium_amethyst_bud", shape: .amethystCluster, tex: .named("medium_amethyst_bud"), opaque: false, solid: false, fullCube: false, light: 2, hardness: 1.5, tool: .pickaxe, sound: "amethyst", piston: .destroy,
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("medium_amethyst_bud")] : [] })
    registerBlock("small_amethyst_bud", shape: .amethystCluster, tex: .named("small_amethyst_bud"), opaque: false, solid: false, fullCube: false, light: 1, hardness: 1.5, tool: .pickaxe, sound: "amethyst", piston: .destroy,
                  drops: .fn { _, ctx in ctx.silkTouch ? [Drop("small_amethyst_bud")] : [] })
    registerBlock("pointed_dripstone", shape: .dripstone, tex: .named("pointed_dripstone"), opaque: false, solid: false, fullCube: false, hardness: 1.5, resistance: 3, tool: .pickaxe, sound: "pointed_dripstone", piston: .destroy, randomTicks: true)
    registerBlock("sniffer_egg", shape: .snifferEgg, tex: .named("sniffer_egg"), opaque: false, fullCube: false, hardness: 0.5, sound: "sniffer_egg", piston: .destroy, randomTicks: true)
    registerBlock("turtle_egg", shape: .turtleEgg, tex: .named("turtle_egg"), opaque: false, fullCube: false, hardness: 0.5, piston: .destroy, randomTicks: true, drops: .none)
    registerBlock("frogspawn", shape: .frogspawn, tex: .named("frogspawn"), opaque: false, solid: false, fullCube: false, hardness: 0, sound: "frogspawn", piston: .destroy, randomTicks: true, drops: .none, ao: false)
    registerBlock("ochre_froglight", tex: texCol("ochre_froglight_top", "ochre_froglight_side"), light: 15, hardness: 0.3, sound: "froglight")
    registerBlock("verdant_froglight", tex: texCol("verdant_froglight_top", "verdant_froglight_side"), light: 15, hardness: 0.3, sound: "froglight")
    registerBlock("pearlescent_froglight", tex: texCol("pearlescent_froglight_top", "pearlescent_froglight_side"), light: 15, hardness: 0.3, sound: "froglight")

    // mushroom blocks
    registerBlock("brown_mushroom_block", hardness: 0.2, tool: .axe, sound: "wood",
                  drops: .fn { _, ctx in
                      let r = ctx.random()
                      return r < 0.25 ? [Drop("brown_mushroom", r < 0.125 ? 1 : 2)] : []
                  })
    registerBlock("red_mushroom_block", hardness: 0.2, tool: .axe, sound: "wood",
                  drops: .fn { _, ctx in
                      let r = ctx.random()
                      return r < 0.25 ? [Drop("red_mushroom", r < 0.125 ? 1 : 2)] : []
                  })
    registerBlock("mushroom_stem", hardness: 0.2, tool: .axe, sound: "wood", drops: .none)

    // misc terrain
    registerBlock("cobweb", shape: .web, tex: .named("cobweb"), opaque: false, solid: false, fullCube: false, hardness: 4, tool: .sword, sound: "cloth", piston: .destroy,
                  drops: .fn { _, ctx in (ctx.shears || ctx.silkTouch) ? [Drop("cobweb")] : [Drop("string")] }, ao: false)
    registerBlock("fire", shape: .fire, tex: .named("fire"), opaque: false, solid: false, fullCube: false, replaceable: true, light: 15, hardness: 0, sound: "cloth", piston: .destroy, randomTicks: true, emissiveRender: true, drops: .none, ao: false)
    registerBlock("soul_fire", shape: .fire, tex: .named("soul_fire"), opaque: false, solid: false, fullCube: false, replaceable: true, light: 10, hardness: 0, sound: "cloth", piston: .destroy, emissiveRender: true, drops: .none, ao: false)
    stone2("infested_stone", 0.75, tex: .named("stone"), display: "Stone", drops: .none)
    stone2("infested_cobblestone", 1, tex: .named("cobblestone"), display: "Cobblestone", drops: .none)
    stone2("infested_stone_bricks", 0.75, tex: .named("stone_bricks"), display: "Stone Bricks", drops: .none)
    registerBlock("infested_deepslate", tex: texCol("deepslate_top", "deepslate"), display: "Deepslate", hardness: 1.5, tool: .pickaxe, sound: "deepslate", drops: .none)

    finalizeBlockRegistry()
}

// MARK: - lookup tables + cell helpers

public var OPAQUE = [UInt8](repeating: 0, count: 4096)
public var FULL_CUBE = [UInt8](repeating: 0, count: 4096)
public var SOLID = [UInt8](repeating: 0, count: 4096)
public var LIGHT_EMIT = [UInt8](repeating: 0, count: 4096)
public var LIGHT_OPACITY = [UInt8](repeating: 0, count: 4096)
public var REPLACEABLE = [UInt8](repeating: 0, count: 4096)
public var SHAPE_OF = [UInt8](repeating: 0, count: 4096)
public var TINT_OF = [UInt8](repeating: 0, count: 4096)
public var TRANSLUCENT = [UInt8](repeating: 0, count: 4096)
public var TRANSPARENT_RENDER = [UInt8](repeating: 0, count: 4096)
public var CULL_SAME = [UInt8](repeating: 0, count: 4096)
public var HAS_GRAVITY = [UInt8](repeating: 0, count: 4096)
public var CLIMBABLE = [UInt8](repeating: 0, count: 4096)
public var RANDOM_TICKS = [UInt8](repeating: 0, count: 4096)
public var AO_OF = [UInt8](repeating: 0, count: 4096)
public var EMISSIVE = [UInt8](repeating: 0, count: 4096)

private var waterFilled = Set<UInt16>()
public var CANDLE_IDS = Set<UInt16>()

func finalizeBlockRegistry() {
    for d in blockDefs {
        OPAQUE[d.id] = d.opaque ? 1 : 0
        FULL_CUBE[d.id] = d.fullCube ? 1 : 0
        SOLID[d.id] = d.solid ? 1 : 0
        LIGHT_EMIT[d.id] = UInt8(d.lightEmit)
        LIGHT_OPACITY[d.id] = UInt8(d.lightOpacity)
        REPLACEABLE[d.id] = d.replaceable ? 1 : 0
        SHAPE_OF[d.id] = d.shape.rawValue
        TINT_OF[d.id] = UInt8(d.tint)
        TRANSLUCENT[d.id] = d.translucent ? 1 : 0
        TRANSPARENT_RENDER[d.id] = d.transparentRender ? 1 : 0
        CULL_SAME[d.id] = d.cullSame ? 1 : 0
        HAS_GRAVITY[d.id] = d.gravity ? 1 : 0
        CLIMBABLE[d.id] = d.climbable ? 1 : 0
        RANDOM_TICKS[d.id] = d.randomTicks ? 1 : 0
        AO_OF[d.id] = d.ao ? 1 : 0
        EMISSIVE[d.id] = d.emissiveRender ? 1 : 0
    }
    // water-filled aquatic plants
    for n in ["seagrass", "tall_seagrass", "kelp", "kelp_plant", "sea_pickle"] { waterFilled.insert(bid(n)) }
    for c in CORALS {
        waterFilled.insert(bid("\(c)_coral"))
        waterFilled.insert(bid("\(c)_coral_fan"))
    }
    CANDLE_IDS.insert(bid("candle"))
    for c in COLORS { CANDLE_IDS.insert(bid("\(c)_candle")) }
    // eagerly exercise every texFn so tile order is deterministic before atlas build
    for d in blockDefs {
        if let fn = d.texFn {
            for m in 0..<16 {
                for f in 0..<6 { _ = fn(m, f) }
            }
        }
    }
    for extra in [
        "redstone_dust_line", "campfire_fire", "soul_campfire_fire",
        "destroy_0", "destroy_1", "destroy_2", "destroy_3", "destroy_4",
        "destroy_5", "destroy_6", "destroy_7", "destroy_8", "destroy_9",
        "smoke_particle", "flame_particle", "portal_particle", "crit_particle",
        "heart_particle", "angry_particle", "splash_particle", "bubble_particle",
        "snow_particle", "petal_particle", "note_particle", "redstone_particle",
        "soul_particle", "enchant_particle", "slime_particle", "sweep_particle",
    ] { tileId(extra) }

    // freeze every B.<name> into stored fields — direct loads on all hot paths
    populateBlockIDs()

    // prebaked cell→tile table + leaves flags: the mesher resolved these via
    // blockDefs[id] struct copies (8 refcounted fields) per visible cell face,
    // which dominated section meshing
    TILE_TABLE = [Int32](repeating: 0, count: 65536 * 8)
    IS_LEAVES = [UInt8](repeating: 0, count: 4096)
    for d in blockDefs {
        if d.name.contains("leaves") { IS_LEAVES[d.id] = 1 }
        for m in 0..<16 {
            let cellV = (d.id << 4) | m
            for f in 0..<6 {
                let tile = d.texFn?(m, f) ?? (d.tex.isEmpty ? 0 : Int(d.tex[f]))
                TILE_TABLE[(cellV << 3) | f] = Int32(tile)
            }
        }
    }

    // bed faces get dedicated blanket/frame tiles — allocated HERE, after the
    // frozen baseline tile range, so the original 757 tile IDs stay stable
    for c in COLORS {
        let bedId = Int(bid("\(c)_bed"))
        let top = Int32(tileId("\(c)_bed_top"))
        let side = Int32(tileId("\(c)_bed_side"))
        let bottom = Int32(tileId("oak_planks"))
        for m in 0..<16 {
            let cellV = (bedId << 4) | m
            TILE_TABLE[(cellV << 3) | 0] = bottom
            TILE_TABLE[(cellV << 3) | 1] = top
            for f in 2..<6 { TILE_TABLE[(cellV << 3) | f] = side }
        }
    }
}

/// tile for (cell, face), index = (cell << 3) | face — covers texFn + tex
public var TILE_TABLE = [Int32]()
public var IS_LEAVES = [UInt8]()

// MARK: - cells

@inline(__always) public func cell(_ id: UInt16, _ meta: Int = 0) -> UInt16 { (id << 4) | UInt16(meta & 15) }
@inline(__always) public func cellId(_ c: UInt16) -> Int { Int(c >> 4) }
@inline(__always) public func cellMeta(_ c: UInt16) -> Int { Int(c & 15) }
@inline(__always) public func defOf(_ c: UInt16) -> BlockDef { blockDefs[Int(c >> 4)] }

public func isAir(_ c: UInt16) -> Bool {
    let id = c >> 4
    return id == B.air || id == B.cave_air || id == B.void_air
}
@inline(__always) public func isWaterCell(_ c: UInt16) -> Bool { (c >> 4) == B.water }
@inline(__always) public func isLavaCell(_ c: UInt16) -> Bool { (c >> 4) == B.lava }
@inline(__always) public func isLiquid(_ c: UInt16) -> Bool {
    let id = c >> 4
    return id == B.water || id == B.lava
}
@inline(__always) public func isWaterlogged(_ c: UInt16) -> Bool {
    (c >> 4) == B.water || waterFilled.contains(c >> 4)
}

/// meta-dependent light emission
public func lightEmitOf(_ c: UInt16) -> Int {
    let id = c >> 4
    let m = Int(c & 15)
    if id == B.respawn_anchor {
        let charges = m & 7
        return charges > 0 ? charges * 4 - 1 : 0
    }
    if id == B.campfire || id == B.soul_campfire { return (m & 4) != 0 ? Int(LIGHT_EMIT[Int(id)]) : 0 }
    if id == B.cave_vines || id == B.cave_vines_plant { return (m & 8) != 0 ? 14 : 0 }
    if id == B.sea_pickle { return 6 + 3 * (m & 3) }
    if CANDLE_IDS.contains(id) { return (m & 8) != 0 ? 3 * ((m & 3) + 1) : 0 }
    if id == B.redstone_ore || id == B.deepslate_redstone_ore { return (m & 1) != 0 ? 9 : 0 }
    return Int(LIGHT_EMIT[Int(id)])
}
