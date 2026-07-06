import XCTest
@testable import PebbleCore

final class AIAgentTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
        registerAllSystems()
    }

    private func makeWorldAndPlayer() -> (World, Player, RaycastHit) {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 777)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.set(0, 63, 0, cell(B.stone))
        chunk.buildHeightmap()
        chunk.status = .lit
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)

        let player = Player(world: world)
        player.setPos(4.5, 64, 4.5)
        player.selectedSlot = 0
        world.addEntity(player)
        let hit = RaycastHit(x: 0, y: 63, z: 0, face: Dir.up, cell: Int(cell(B.stone)),
                             t: 1, px: 0.5, py: 64, pz: 0.5)
        return (world, player, hit)
    }

    private func makeFlatWorldWithDeepHole() -> (World, Player) {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 778)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.status = .lit
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)

        for z in 0..<16 {
            for x in 0..<16 {
                world.setBlock(x, 48, z, Int(cell(B.stone)))
                world.setBlock(x, 63, z, Int(cell(B.grass_block)))
            }
        }
        for z in 8...10 {
            for x in 3...5 {
                for y in 49...63 {
                    world.setBlock(x, y, z, 0)
                }
            }
        }

        let player = Player(world: world)
        player.setPos(4.5, 64, 4.5)
        player.yaw = 0
        player.pitch = 0
        world.addEntity(player)
        return (world, player)
    }

    private func makeFlatBiomePatchWorld() -> (World, Player) {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 779)
        let info = dimInfo(.overworld)
        for cz in -1...1 {
            for cx in -1...1 {
                let chunk = Chunk(cx: cx, cz: cz, minY: info.minY, height: info.height)
                for z in 0..<16 {
                    for x in 0..<16 {
                        for y in info.minY..<0 {
                            chunk.set(x, y, z, cell(B.deepslate))
                        }
                        for y in 0...59 {
                            chunk.set(x, y, z, cell(B.stone))
                        }
                        for y in 60...62 {
                            chunk.set(x, y, z, cell(B.dirt))
                        }
                        chunk.set(x, 63, z, cell(B.grass_block))
                    }
                }
                for qy in 0..<(chunk.biomes.count / 16) {
                    for qz in 0..<4 {
                        for qx in 0..<4 {
                            chunk.setBiome(qx, qy, qz, Biome.plains.rawValue)
                        }
                    }
                }
                chunk.buildHeightmap()
                chunk.status = .lit
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }

        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        player.yaw = 0
        player.pitch = 0
        world.addEntity(player)
        return (world, player)
    }

    func testParseExtractsFirstJSONActionFromModelText() throws {
        let action = try parseAIAgentAction(from: "```json\n{\"action\":\"place_block\",\"item\":\"crafting station\",\"target\":\"cursor\"}\n```")

        XCTAssertEqual(action.action, "place_block")
        XCTAssertEqual(action.item, "crafting station")
        XCTAssertEqual(action.target, "cursor")
    }

    func testParseRejectsNonJSONModelText() {
        XCTAssertThrowsError(try parseAIAgentAction(from: "place a crafting table now")) { error in
            XCTAssertEqual(error as? AIAgentError, .malformedJSON)
        }
    }

    func testNaturalNamesResolveThroughAliasesAndDisplayNames() {
        registerCoreIfNeeded()

        XCTAssertEqual(resolveAIAgentItemID("roasted chicken"), iid("cooked_chicken"))
        XCTAssertEqual(resolveAIAgentItemID("a stack of coal"), iid("coal"))
        XCTAssertEqual(resolveAIAgentItemID("10 diamonds"), iid("diamond"))
        XCTAssertEqual(resolveAIAgentBlockID("crafting station"), B.crafting_table)
        XCTAssertEqual(resolveAIAgentBlockID("Crafting Table"), B.crafting_table)
    }

    func testGiveItemCreatesRegisteredInventoryItem() throws {
        let (world, player, _) = makeWorldAndPlayer()

        let result = try executeAIAgentAction(
            AIAgentAction(action: "give_item", item: "roasted chicken", count: 3),
            world: world,
            player: player,
            cursor: nil)

        XCTAssertFalse(result.changedWorld)
        XCTAssertEqual(player.countItem(iid("cooked_chicken")), 3)
    }

    func testDirectInventoryRequestAddsAStackOfCoal() throws {
        let (world, player, _) = makeWorldAndPlayer()
        let action = try XCTUnwrap(inferDirectAIAgentAction(from: "add a stack of coal to my inventory"))

        let result = try executeAIAgentAction(action, world: world, player: player, cursor: nil)

        XCTAssertFalse(result.changedWorld)
        XCTAssertEqual(action.action, "give_item")
        XCTAssertEqual(action.item, "coal")
        XCTAssertEqual(action.count, 64)
        XCTAssertEqual(player.countItem(iid("coal")), 64)
    }

    func testDirectInventoryRequestUsesItemMaxStackSize() throws {
        registerCoreIfNeeded()
        let action = try XCTUnwrap(inferDirectAIAgentAction(from: "give me a stack of ender pearls"))

        XCTAssertEqual(action.item, "ender_pearl")
        XCTAssertEqual(action.count, itemDef(iid("ender_pearl")).maxStack)
    }

    func testDirectInventoryRequestSupportsNumericCountsAndPlurals() throws {
        registerCoreIfNeeded()
        let action = try XCTUnwrap(inferDirectAIAgentAction(from: "give me 10 diamonds"))

        XCTAssertEqual(action.item, "diamond")
        XCTAssertEqual(action.count, 10)
    }

    func testDirectInventoryRequestDoesNotOvermatchPlacementText() {
        registerCoreIfNeeded()
        XCTAssertNil(inferDirectAIAgentAction(from: "place a stack of coal at the cursor"))
        XCTAssertNil(inferDirectAIAgentAction(from: "what can I craft with coal"))
    }

    func testDirectHoleFillRequestParsesTerrainLevelingAction() throws {
        registerCoreIfNeeded()

        let action = try XCTUnwrap(inferDirectAIAgentAction(
            from: "fill the hole in front of me with dirt"))

        XCTAssertEqual(action.action, "fill_hole")
        XCTAssertEqual(action.block, "dirt")
        XCTAssertEqual(action.target, "front")
        XCTAssertNil(inferDirectAIAgentAction(from: "fill the hole in front of me with torch"))
    }

    func testDirectBiomeReworkRequestParsesRollingResourceAction() throws {
        registerCoreIfNeeded()

        let action = try XCTUnwrap(inferDirectAIAgentAction(
            from: "change the current biome to rolling hills with rich resources"))

        XCTAssertEqual(action.action, "rework_biome")
        XCTAssertEqual(action.target, "current_biome")
        XCTAssertEqual(action.profile, "rolling_hills_resource_rich")
    }

    func testBiomeReworkMakesCurrentLoadedBiomeRollingAndResourceRich() throws {
        let (world, player) = makeFlatBiomePatchWorld()
        let protectedChest = makeContainerBE(1, 64, 1, 27)
        protectedChest.items?[0] = stack("diamond", 1)
        world.setBlock(1, 64, 1, Int(cell(B.chest)))
        world.setBlockEntity(protectedChest)
        let action = try XCTUnwrap(inferDirectAIAgentAction(
            from: "change the current biome to rolling hills with rich resources"))

        let result = try executeAIAgentAction(action, world: world, player: player, cursor: nil)

        XCTAssertTrue(result.changedWorld)
        XCTAssertEqual(world.biomeAt(0, 64, 0), Biome.meadow.rawValue)
        XCTAssertEqual(world.getBlockId(1, 64, 1), Int(B.chest))
        XCTAssertNotNil(world.getBlockEntity(1, 64, 1))

        var heights: [Int] = []
        for z in stride(from: -20, through: 20, by: 4) {
            for x in stride(from: -20, through: 20, by: 4) where world.isLoadedAt(x, z) {
                heights.append(world.surfaceY(x, z))
            }
        }
        let minHeight = try XCTUnwrap(heights.min())
        let maxHeight = try XCTUnwrap(heights.max())
        XCTAssertGreaterThan(maxHeight - minHeight, 6)

        let ores = oreFamilyCounts(in: world)
        for family in ["coal", "iron", "copper", "gold", "redstone", "lapis", "diamond", "emerald"] {
            XCTAssertGreaterThan(ores[family, default: 0], 0, "\(family) should be present after rich-resource rework")
        }

        var deepAir = 0
        for chunk in world.chunks.values {
            for z in 0..<16 {
                for x in 0..<16 {
                    for y in -40...40 where chunk.get(x, y, z) == 0 {
                        deepAir += 1
                    }
                }
            }
        }
        XCTAssertEqual(deepAir, 0, "reworking rolling resource hills must not carve underground caverns")
    }

    func testFillHoleInFrontLevelsDeepDirtAdjacentHoleWithoutCursorHit() throws {
        let (world, player) = makeFlatWorldWithDeepHole()
        let action = try XCTUnwrap(inferDirectAIAgentAction(
            from: "fill the hole in front of me with dirt"))

        let result = try executeAIAgentAction(action, world: world, player: player, cursor: nil)

        XCTAssertTrue(result.changedWorld)
        XCTAssertEqual(result.message, "Filled 135 blocks with Dirt.")
        XCTAssertEqual(world.getBlockId(4, 63, 8), Int(B.dirt))
        XCTAssertEqual(world.getBlockId(4, 49, 8), Int(B.dirt))
        XCTAssertEqual(world.getBlockId(4, 48, 8), Int(B.stone))
        XCTAssertEqual(world.getBlockId(2, 63, 8), Int(B.grass_block))
    }

    func testFillHoleInFrontRequiresDirtLikeRim() throws {
        let (world, player) = makeFlatWorldWithDeepHole()
        for z in 0..<16 {
            for x in 0..<16 where world.getBlockId(x, 63, z) == Int(B.grass_block) {
                world.setBlock(x, 63, z, Int(cell(B.stone)))
            }
        }
        let action = AIAgentAction(action: "fill_hole", block: "dirt", target: "front")

        XCTAssertThrowsError(try executeAIAgentAction(action, world: world, player: player, cursor: nil)) { error in
            XCTAssertEqual(error as? AIAgentError, .missingHoleTarget)
        }
    }

    func testDirectTemplateReplacementRequestParsesWoodCategory() throws {
        registerCoreIfNeeded()
        let action = try XCTUnwrap(inferDirectAIAgentAction(
            from: #"change the type of all wood blocks in "house" to bamboo"#))

        XCTAssertEqual(action.action, "replace_template_blocks")
        XCTAssertEqual(action.template, "house")
        XCTAssertEqual(action.fromBlock, "wood")
        XCTAssertEqual(action.toBlock, "bamboo")
        XCTAssertTrue(isAIAgentTemplateAction(action))
    }

    func testTemplateReplacementActionEditsSavedWoodBlocks() throws {
        registerCoreIfNeeded()
        var store: [String: ObjectTemplate] = [
            "house": ObjectTemplate(
                name: "house",
                anchorX: 0, anchorY: 0, anchorZ: 0,
                sizeX: 3, sizeY: 1, sizeZ: 1,
                blocks: [
                    TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                    TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.spruce_log))),
                    TemplateBlock(dx: 2, dy: 0, dz: 0, cell: UInt16(cell(B.stone))),
                ]),
        ]
        let action = try XCTUnwrap(inferDirectAIAgentAction(
            from: #"change the type of all wood blocks in "house" to bamboo"#))

        let result = try executeAIAgentTemplateAction(
            action,
            loadTemplate: { store[normalizedTemplateName($0)!] },
            saveTemplate: { store[$0.name] = $0; return true })

        XCTAssertTrue(result.changedWorld)
        XCTAssertTrue(result.message.contains("replaced 2"))
        let updated = try XCTUnwrap(store["house"])
        XCTAssertEqual(updated.blocks.map { Int($0.cell >> 4) }, [Int(B.bamboo), Int(B.bamboo), Int(B.stone)])
    }

    func testTemplateReplacementSupportsExactBlockTypesAndDropsChangedBlockEntities() throws {
        registerCoreIfNeeded()
        let chest = makeContainerBE(0, 0, 0, 27)
        chest.items?[0] = stack("diamond", 1)
        var store: [String: ObjectTemplate] = [
            "storage": ObjectTemplate(
                name: "storage",
                anchorX: 0, anchorY: 0, anchorZ: 0,
                sizeX: 2, sizeY: 1, sizeZ: 1,
                blocks: [
                    TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.chest))),
                    TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.cobblestone))),
                ],
                blockEntities: [chest]),
        ]

        let result = try executeAIAgentTemplateAction(
            AIAgentAction(action: "replace_template_blocks",
                          template: "storage",
                          fromBlock: "chest",
                          toBlock: "diamond_block"),
            loadTemplate: { store[normalizedTemplateName($0)!] },
            saveTemplate: { store[$0.name] = $0; return true })

        XCTAssertTrue(result.changedWorld)
        let updated = try XCTUnwrap(store["storage"])
        XCTAssertEqual(updated.blocks.map { Int($0.cell >> 4) }, [Int(B.diamond_block), Int(B.cobblestone)])
        XCTAssertTrue(updated.blockEntities.isEmpty)
    }

    func testDirectTemplateCreationRequestBuildsStoredPirateShip() throws {
        registerCoreIfNeeded()
        let prompt = #"/ai create a object that looks like a pirate ship about 50 blocks long and use darker colored block type from wood to other material to make it look sinister. Name the object pirateShip"#
        let action = try XCTUnwrap(inferDirectAIAgentAction(from: prompt))
        var saved: ObjectTemplate?

        let result = try executeAIAgentTemplateAction(
            action,
            loadTemplate: { _ in nil },
            saveTemplate: { saved = $0; return true })

        XCTAssertTrue(result.changedWorld)
        let template = try XCTUnwrap(saved)
        XCTAssertEqual(template.name, "pirateship")
        XCTAssertEqual(template.sizeX, 50)
        XCTAssertGreaterThan(template.blocks.count, 200)
        let palette = try objectTemplateBlockPalette(template, limit: 8).map(\.blockName)
        XCTAssertTrue(palette.contains("dark_oak_planks") || palette.contains("spruce_planks"))
        XCTAssertTrue(palette.contains("black_wool") || palette.contains("polished_blackstone_bricks"))
    }

    func testPlaceBlockAtCursorUsesPlacementPathAndPreservesHotbar() throws {
        let (world, player, hit) = makeWorldAndPlayer()
        player.inventory[0] = stack("dirt", 5)

        let result = try executeAIAgentAction(
            AIAgentAction(action: "place_block", item: "crafting station", target: "cursor"),
            world: world,
            player: player,
            cursor: hit)

        XCTAssertTrue(result.changedWorld)
        XCTAssertEqual(world.getBlock(0, 64, 0) >> 4, Int(B.crafting_table))
        XCTAssertEqual(player.inventory[0]?.id, iid("dirt"))
        XCTAssertEqual(player.inventory[0]?.count, 5)
    }

    func testPlaceBlockRequiresCursorHit() {
        let (world, player, _) = makeWorldAndPlayer()

        XCTAssertThrowsError(try executeAIAgentAction(
            AIAgentAction(action: "place_block", item: "crafting station", target: "cursor"),
            world: world,
            player: player,
            cursor: nil)) { error in
                XCTAssertEqual(error as? AIAgentError, .missingCursorTarget)
            }
    }

    func testSetTimeActionAcceptsPresetsAndNormalizesTicks() throws {
        let (world, player, hit) = makeWorldAndPlayer()
        let direct = try XCTUnwrap(inferDirectAIAgentAction(from: "set time to night"))

        let result = try executeAIAgentAction(direct, world: world, player: player, cursor: hit)

        XCTAssertTrue(result.changedWorld)
        XCTAssertEqual(direct.action, "set_time")
        XCTAssertEqual(world.dayTime, 13_000)

        _ = try executeAIAgentAction(
            AIAgentAction(action: "set_time", ticks: -1),
            world: world,
            player: player,
            cursor: hit)
        XCTAssertEqual(world.dayTime, DAY_LENGTH - 1)
    }

    func testSetWeatherActionAppliesImmediateWeatherState() throws {
        let (world, player, hit) = makeWorldAndPlayer()
        let direct = try XCTUnwrap(inferDirectAIAgentAction(from: "make it thunder"))

        let result = try executeAIAgentAction(direct, world: world, player: player, cursor: hit)

        XCTAssertTrue(result.changedWorld)
        XCTAssertEqual(direct.action, "set_weather")
        XCTAssertEqual(direct.weather, "thunder")
        XCTAssertTrue(world.raining)
        XCTAssertTrue(world.thundering)
        XCTAssertEqual(world.rainLevel, 1)
        XCTAssertEqual(world.thunderLevel, 1)
        XCTAssertEqual(world.weatherTimer, AIAgentWeatherDurationTicks)

        _ = try executeAIAgentAction(
            AIAgentAction(action: "set_weather", weather: "clear"),
            world: world,
            player: player,
            cursor: hit)
        XCTAssertFalse(world.raining)
        XCTAssertFalse(world.thundering)
        XCTAssertEqual(world.rainLevel, 0)
        XCTAssertEqual(world.thunderLevel, 0)
    }

    func testSpawnEntityAtCursorUsesRegisteredNameAndCapsCount() throws {
        let (world, player, hit) = makeWorldAndPlayer()
        let direct = try XCTUnwrap(inferDirectAIAgentAction(from: "spawn two zombies at the cursor"))

        let directResult = try executeAIAgentAction(direct, world: world, player: player, cursor: hit)
        let cappedResult = try executeAIAgentAction(
            AIAgentAction(action: "spawn_entity", count: 99, target: "cursor", entity: "cow"),
            world: world,
            player: player,
            cursor: hit)

        XCTAssertTrue(directResult.changedWorld)
        XCTAssertTrue(cappedResult.changedWorld)
        XCTAssertEqual(direct.entity, "zombie")
        XCTAssertEqual(direct.count, 2)
        XCTAssertEqual(world.entities.compactMap { $0 as? Entity }.filter { $0.type == "zombie" }.count, 2)
        XCTAssertEqual(world.entities.compactMap { $0 as? Entity }.filter { $0.type == "cow" }.count, AIAgentMaxSpawnCount)
        let cow = try XCTUnwrap(world.entities.compactMap { $0 as? Entity }.first { $0.type == "cow" })
        XCTAssertTrue(cow.persistent)
        XCTAssertEqual(cow.x, 0.5)
        XCTAssertEqual(cow.y, 64)
        XCTAssertEqual(cow.z, 0.5)
    }

    func testSpawnEntityRejectsUnknownEntityAndMissingCursor() {
        let (world, player, hit) = makeWorldAndPlayer()

        XCTAssertThrowsError(try executeAIAgentAction(
            AIAgentAction(action: "spawn_entity", count: 1, target: "cursor", entity: "missingno"),
            world: world,
            player: player,
            cursor: hit)) { error in
                XCTAssertEqual(error as? AIAgentError, .unknownEntity("missingno"))
            }

        XCTAssertThrowsError(try executeAIAgentAction(
            AIAgentAction(action: "spawn_entity", count: 1, target: "cursor", entity: "zombie"),
            world: world,
            player: player,
            cursor: nil)) { error in
                XCTAssertEqual(error as? AIAgentError, .missingCursorTarget)
            }
    }

    func testSnapshotIncludesNearbyDroppedItems() {
        let (world, player, hit) = makeWorldAndPlayer()
        let item = ItemEntity(world: world)
        item.stack = stack("diamond", 2)
        item.setPos(player.x + 1, player.y, player.z)
        world.addEntity(item)

        let snapshot = buildAIAgentSnapshot(world: world, player: player, cursor: hit)

        XCTAssertTrue(snapshot.contains("diamondx2"), snapshot)
        XCTAssertTrue(snapshot.contains("Cursor: block=stone"), snapshot)
        XCTAssertTrue(snapshot.contains("Available items:"), snapshot)
        XCTAssertTrue(snapshot.contains("Available spawnable entities:"), snapshot)
        XCTAssertTrue(snapshot.contains("zombie"), snapshot)
    }

    func testSnapshotIncludesSavedTemplatePalette() {
        let (world, player, hit) = makeWorldAndPlayer()
        let template = ObjectTemplate(
            name: "house",
            anchorX: 0, anchorY: 0, anchorZ: 0,
            sizeX: 2, sizeY: 1, sizeZ: 1,
            blocks: [
                TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.blackstone))),
            ])

        let snapshot = buildAIAgentSnapshot(world: world, player: player, cursor: hit,
                                            savedTemplates: [template])

        XCTAssertTrue(snapshot.contains("Saved object templates:"), snapshot)
        XCTAssertTrue(snapshot.contains("template=\"house\""), snapshot)
        XCTAssertTrue(snapshot.contains("oak_planksx1"), snapshot)
        XCTAssertTrue(snapshot.contains("blackstonex1"), snapshot)
    }

    func testPromptAdvertisesWorldMutatorActions() {
        let (world, player, hit) = makeWorldAndPlayer()

        let prompt = buildAIAgentPrompt(userRequest: "make it rain and spawn a cow", world: world,
                                        player: player, cursor: hit)

        XCTAssertTrue(prompt.contains(#""set_time""#), prompt)
        XCTAssertTrue(prompt.contains(#""set_weather""#), prompt)
        XCTAssertTrue(prompt.contains(#""spawn_entity""#), prompt)
        XCTAssertTrue(prompt.contains(#""rework_biome""#), prompt)
        XCTAssertTrue(prompt.contains("rolling_hills_resource_rich"), prompt)
        XCTAssertTrue(prompt.contains("Available spawnable entities:"), prompt)
    }

    private func oreFamilyCounts(in world: World) -> [String: Int] {
        let families: [UInt16: String] = [
            B.coal_ore: "coal", B.deepslate_coal_ore: "coal",
            B.iron_ore: "iron", B.deepslate_iron_ore: "iron",
            B.copper_ore: "copper", B.deepslate_copper_ore: "copper",
            B.gold_ore: "gold", B.deepslate_gold_ore: "gold",
            B.redstone_ore: "redstone", B.deepslate_redstone_ore: "redstone",
            B.lapis_ore: "lapis", B.deepslate_lapis_ore: "lapis",
            B.diamond_ore: "diamond", B.deepslate_diamond_ore: "diamond",
            B.emerald_ore: "emerald", B.deepslate_emerald_ore: "emerald",
        ]
        var counts: [String: Int] = [:]
        for chunk in world.chunks.values {
            for cell in chunk.blocks {
                if let family = families[cell >> 4] {
                    counts[family, default: 0] += 1
                }
            }
        }
        return counts
    }
}
