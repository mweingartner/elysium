import XCTest
@testable import PebbleCore

final class TemplateTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    private func makeWorld() -> World {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 2468)
        let info = dimInfo(.overworld)
        for cz in 0...1 {
            for cx in 0...1 {
                let chunk = Chunk(cx: cx, cz: cz, minY: info.minY, height: info.height)
                chunk.status = .lit
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        return world
    }

    private func makeFurnishedObject(in world: World) {
        world.setBlock(1, 64, 1, Int(cell(B.oak_planks)))
        world.setBlock(2, 64, 1, Int(cell(B.chest)))
        world.setBlock(1, 65, 1, Int(cell(B.torch)))
        world.setBlock(1, 63, 1, Int(cell(B.grass_block)))
        let chest = makeContainerBE(2, 64, 1, 27)
        chest.items?[0] = stack("diamond", 3)
        world.setBlockEntity(chest)
    }

    private func tempDB() -> SaveDB {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pebble-template-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SaveDB(databaseURL: dir.appendingPathComponent("pebble.db"), migrateLegacy: false)
    }

    func testCloneConnectedObjectExcludesUnderlyingTerrain() throws {
        let world = makeWorld()
        makeFurnishedObject(in: world)

        let result = try cloneObjectTemplate(named: "Cabin", from: world, targetX: 1, targetY: 64, targetZ: 1)
        let names = result.template.blocks.map { item in blockDefs[Int(item.cell >> 4)].name }.sorted()

        XCTAssertEqual(result.template.name, "cabin")
        XCTAssertEqual(result.template.blocks.count, 3)
        XCTAssertEqual(names, ["chest", "oak_planks", "torch"])
        XCTAssertEqual(result.template.blockEntities.count, 1)
        XCTAssertEqual(result.template.sizeX, 2)
        XCTAssertEqual(result.template.sizeY, 2)
        XCTAssertEqual(result.template.sizeZ, 1)
    }

    func testCloneDeepCopiesBlockEntityContents() throws {
        let world = makeWorld()
        makeFurnishedObject(in: world)

        let result = try cloneObjectTemplate(named: "Storage", from: world, targetX: 1, targetY: 64, targetZ: 1)
        world.getBlockEntity(2, 64, 1)?.items?[0]?.count = 1

        let clonedChest = try XCTUnwrap(result.template.blockEntities.first)
        XCTAssertEqual(clonedChest.items?[0]?.id, iid("diamond"))
        XCTAssertEqual(clonedChest.items?[0]?.count, 3)
    }

    func testPlaceObjectTemplateAtCursorAnchor() throws {
        let world = makeWorld()
        makeFurnishedObject(in: world)
        let result = try cloneObjectTemplate(named: "Cabin", from: world, targetX: 1, targetY: 64, targetZ: 1)

        let placed = try placeObjectTemplate(result.template, in: world, targetX: 8, targetY: 70, targetZ: 8)

        XCTAssertEqual(placed.blocksPlaced, 3)
        XCTAssertEqual(placed.blockEntitiesPlaced, 1)
        XCTAssertEqual(placed.blocksCleared, 0)
        XCTAssertEqual(placed.supportBlocksFilled, 0)
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.oak_planks))
        XCTAssertEqual(world.getBlockId(9, 70, 8), Int(B.chest))
        XCTAssertEqual(world.getBlockId(8, 71, 8), Int(B.torch))
        XCTAssertEqual(world.getBlockEntity(9, 70, 8)?.items?[0]?.count, 3)
    }

    func testRotatedObjectTemplateRotatesBlocksAnchorAndBlockEntities() throws {
        registerCoreIfNeeded()
        let chest = makeContainerBE(1, 0, 2, 27)
        chest.items?[0] = stack("diamond", 2)
        let template = ObjectTemplate(
            name: "Turn",
            anchorX: 1, anchorY: 0, anchorZ: 0,
            sizeX: 2, sizeY: 1, sizeZ: 3,
            blocks: [
                TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.stone))),
                TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                TemplateBlock(dx: 1, dy: 0, dz: 2, cell: UInt16(cell(B.chest))),
            ],
            blockEntities: [chest])

        let rotated = try rotatedObjectTemplate(template, rotationSteps: 1)

        XCTAssertEqual(rotated.sizeX, 3)
        XCTAssertEqual(rotated.sizeY, 1)
        XCTAssertEqual(rotated.sizeZ, 2)
        XCTAssertEqual(rotated.anchorX, 2)
        XCTAssertEqual(rotated.anchorY, 0)
        XCTAssertEqual(rotated.anchorZ, 1)
        let coords = rotated.blocks.map { [$0.dx, $0.dy, $0.dz, Int($0.cell >> 4)] }
        XCTAssertEqual(coords, [
            [2, 0, 0, Int(B.stone)],
            [0, 0, 1, Int(B.chest)],
            [2, 0, 1, Int(B.oak_planks)],
        ])
        let rotatedChest = try XCTUnwrap(rotated.blockEntities.first)
        XCTAssertEqual(rotatedChest.x, 0)
        XCTAssertEqual(rotatedChest.y, 0)
        XCTAssertEqual(rotatedChest.z, 1)
        XCTAssertEqual(rotatedChest.items?[0]?.id, iid("diamond"))
        XCTAssertEqual(rotatedChest.items?[0]?.count, 2)
    }

    func testPlaceObjectTemplateWithRotationUsesRotatedAnchor() throws {
        let world = makeWorld()
        let chest = makeContainerBE(1, 0, 2, 27)
        chest.items?[0] = stack("diamond", 4)
        let template = ObjectTemplate(
            name: "Rotated Place",
            anchorX: 1, anchorY: 0, anchorZ: 0,
            sizeX: 2, sizeY: 1, sizeZ: 3,
            blocks: [
                TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.stone))),
                TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                TemplateBlock(dx: 1, dy: 0, dz: 2, cell: UInt16(cell(B.chest))),
            ],
            blockEntities: [chest])

        let placed = try placeObjectTemplate(template, in: world,
                                             targetX: 8, targetY: 70, targetZ: 8,
                                             rotationSteps: 1)

        XCTAssertEqual(placed.originX, 6)
        XCTAssertEqual(placed.originY, 70)
        XCTAssertEqual(placed.originZ, 7)
        XCTAssertEqual(world.getBlockId(8, 70, 7), Int(B.stone))
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.oak_planks))
        XCTAssertEqual(world.getBlockId(6, 70, 8), Int(B.chest))
        XCTAssertEqual(world.getBlockEntity(6, 70, 8)?.items?[0]?.count, 4)
    }

    func testObjectTemplatePlacementTargetCentersTemplateInView() throws {
        registerCoreIfNeeded()
        let template = ObjectTemplate(
            name: "Preview",
            anchorX: 1, anchorY: 0, anchorZ: 1,
            sizeX: 4, sizeY: 2, sizeZ: 2,
            blocks: [TemplateBlock(dx: 1, dy: 0, dz: 1, cell: UInt16(cell(B.oak_planks)))])

        let target = try objectTemplatePlacementTarget(for: template,
                                                       eyeX: 0, eyeY: 2, eyeZ: 0,
                                                       yaw: 0, pitch: 0)

        XCTAssertGreaterThanOrEqual(target.distance, 6)
        XCTAssertEqual(target.originX, -2)
        XCTAssertEqual(target.originY, 1)
        XCTAssertEqual(target.originZ, Int((target.distance - 1).rounded(.down)))
        XCTAssertEqual(target.targetX, -1)
        XCTAssertEqual(target.targetY, 1)
        XCTAssertEqual(target.targetZ, target.originZ + 1)
    }

    func testPreparedPlacementClearsObstructionsAndFillsFoundationGapFromAdjacentBlock() throws {
        let world = makeWorld()
        world.setBlock(7, 69, 8, Int(cell(B.dirt)))
        world.setBlock(8, 68, 8, Int(cell(B.stone)))
        world.setBlock(8, 70, 8, Int(cell(B.cobblestone)))
        world.setBlock(8, 71, 8, Int(cell(B.chest)))
        world.setBlockEntity(makeContainerBE(8, 71, 8, 27))
        let template = ObjectTemplate(
            name: "Prepared",
            anchorX: 0, anchorY: 0, anchorZ: 0,
            sizeX: 1, sizeY: 2, sizeZ: 1,
            blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks)))])

        let placed = try placeObjectTemplate(template, in: world,
                                             targetX: 8, targetY: 70, targetZ: 8,
                                             options: TemplatePlacementOptions(prepareTerrain: true))

        XCTAssertEqual(placed.blocksPlaced, 1)
        XCTAssertEqual(placed.blocksCleared, 2)
        XCTAssertEqual(placed.supportBlocksFilled, 1)
        XCTAssertEqual(world.getBlockId(8, 69, 8), Int(B.dirt))
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.oak_planks))
        XCTAssertEqual(world.getBlockId(8, 71, 8), 0)
        XCTAssertNil(world.getBlockEntity(8, 71, 8))
    }

    func testPreparedPlacementRejectsDeepFoundationBeforeMutating() throws {
        let world = makeWorld()
        world.setBlock(8, 70, 8, Int(cell(B.cobblestone)))
        let template = ObjectTemplate(
            name: "Unsupported",
            anchorX: 0, anchorY: 0, anchorZ: 0,
            sizeX: 1, sizeY: 1, sizeZ: 1,
            blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks)))])

        XCTAssertThrowsError(try placeObjectTemplate(template, in: world,
                                                     targetX: 8, targetY: 70, targetZ: 8,
                                                     options: TemplatePlacementOptions(prepareTerrain: true))) { error in
            XCTAssertEqual(error as? TemplateError, .foundationTooDeep(8, 69, 8))
        }
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.cobblestone))
        XCTAssertEqual(world.getBlockId(8, 69, 8), 0)
    }

    func testPlaceRejectsBlockedDestinationBeforeMutating() throws {
        let world = makeWorld()
        makeFurnishedObject(in: world)
        let result = try cloneObjectTemplate(named: "Cabin", from: world, targetX: 1, targetY: 64, targetZ: 1)
        world.setBlock(8, 70, 8, Int(cell(B.stone)))

        XCTAssertThrowsError(try placeObjectTemplate(result.template, in: world, targetX: 8, targetY: 70, targetZ: 8)) { error in
            XCTAssertEqual(error as? TemplateError, .destinationBlocked(8, 70, 8))
        }
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.stone))
        XCTAssertEqual(world.getBlockId(9, 70, 8), 0)
    }

    func testTemplateStoreRoundTripsThroughSQLite() throws {
        let world = makeWorld()
        makeFurnishedObject(in: world)
        let result = try cloneObjectTemplate(named: "Round Trip", from: world, targetX: 1, targetY: 64, targetZ: 1)
        let db = tempDB()

        XCTAssertTrue(try db.putTemplate(result.template))
        XCTAssertEqual(db.listTemplates(), ["round trip"])
        let loaded = try XCTUnwrap(try db.getTemplate(named: "ROUND TRIP"))

        XCTAssertEqual(loaded.name, "round trip")
        XCTAssertEqual(loaded.blocks.count, 3)
        XCTAssertEqual(loaded.blockEntities.first?.items?[0]?.id, iid("diamond"))
        XCTAssertEqual(loaded.blockEntities.first?.items?[0]?.count, 3)
    }

    func testObjectTemplateSummaryReportsBrowserMetadata() throws {
        let world = makeWorld()
        makeFurnishedObject(in: world)
        let result = try cloneObjectTemplate(named: "Browser Card", from: world, targetX: 1, targetY: 64, targetZ: 1)

        let summary = try summarizeObjectTemplate(result.template)

        XCTAssertEqual(summary.name, "browser card")
        XCTAssertEqual(summary.sizeX, 2)
        XCTAssertEqual(summary.sizeY, 2)
        XCTAssertEqual(summary.sizeZ, 1)
        XCTAssertEqual(summary.blockCount, 3)
        XCTAssertEqual(summary.blockEntityCount, 1)
        XCTAssertFalse(summary.dominantBlockName.isEmpty)
        XCTAssertFalse(summary.dominantBlockDisplayName.isEmpty)
    }

    func testReplaceObjectTemplateBlocksByWoodFamilyCategory() throws {
        registerCoreIfNeeded()
        let template = ObjectTemplate(
            name: "Wood Swap",
            anchorX: 0, anchorY: 0, anchorZ: 0,
            sizeX: 4, sizeY: 1, sizeZ: 1,
            blocks: [
                TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.spruce_log))),
                TemplateBlock(dx: 2, dy: 0, dz: 0, cell: UInt16(cell(B.bamboo_mosaic))),
                TemplateBlock(dx: 3, dy: 0, dz: 0, cell: UInt16(cell(B.stone))),
            ])

        let result = try replacingObjectTemplateBlocks(template, matching: .woodFamily, with: B.bamboo)

        XCTAssertEqual(result.replacedBlocks, 3)
        XCTAssertEqual(result.template.blocks.map { Int($0.cell >> 4) },
                       [Int(B.bamboo), Int(B.bamboo), Int(B.bamboo), Int(B.stone)])
        let palette = try objectTemplateBlockPalette(result.template, limit: 2)
        XCTAssertEqual(palette.first?.blockName, "bamboo")
    }

    func testGeneratedPirateShipTemplateIsBoundedAndValid() throws {
        registerCoreIfNeeded()

        let ship = try generatedObjectTemplate(named: "pirateShip",
                                               kind: "pirate_ship",
                                               requestedLength: 50,
                                               style: "dark sinister wood and black sail")
        let encoded = try encodeObjectTemplate(ship)
        let decoded = try decodeObjectTemplate(encoded)
        let palette = try objectTemplateBlockPalette(decoded, limit: 8).map(\.blockName)

        XCTAssertEqual(decoded.name, "pirateship")
        XCTAssertEqual(decoded.sizeX, 50)
        XCTAssertLessThanOrEqual(decoded.sizeX, OBJECT_TEMPLATE_MAX_SPAN)
        XCTAssertLessThanOrEqual(decoded.sizeY, OBJECT_TEMPLATE_MAX_SPAN)
        XCTAssertLessThanOrEqual(decoded.sizeZ, OBJECT_TEMPLATE_MAX_SPAN)
        XCTAssertGreaterThan(decoded.blocks.count, 200)
        XCTAssertLessThanOrEqual(decoded.blocks.count, OBJECT_TEMPLATE_MAX_BLOCKS)
        XCTAssertTrue(palette.contains("black_wool") || palette.contains("polished_blackstone_bricks"))
    }

    func testInvalidTemplateNamesAreRejected() {
        XCTAssertNil(normalizedTemplateName("../bad"))
        XCTAssertNil(normalizedTemplateName(""))
        XCTAssertEqual(normalizedTemplateName(" Foo Bar "), "foo bar")
    }

    func testRequestedTemplateCommandPhrasesParseQuotedNames() {
        let cloneParts = splitCommandLineArguments("clone the target with new name \"Foo House\"")
        let placeParts = splitCommandLineArguments("place object \"Foo House\" at the cursor")
        let shortPlaceParts = splitCommandLineArguments("place \"Foo House\" at target")
        let previewPlaceParts = splitCommandLineArguments("place \"Foo House\"")

        XCTAssertEqual(cloneParts, ["clone", "the", "target", "with", "new", "name", "Foo House"])
        XCTAssertEqual(placeParts, ["place", "object", "Foo House", "at", "the", "cursor"])
        XCTAssertEqual(shortPlaceParts, ["place", "Foo House", "at", "target"])
        XCTAssertEqual(previewPlaceParts, ["place", "Foo House"])
        XCTAssertEqual(cloneTemplateNameFromCommandArgs(Array(cloneParts.dropFirst())), "Foo House")
        XCTAssertEqual(placeTemplateNameFromCommandArgs(Array(placeParts.dropFirst())), "Foo House")
        XCTAssertEqual(placeTemplateNameFromCommandArgs(Array(shortPlaceParts.dropFirst())), "Foo House")
        XCTAssertEqual(placeTemplateNameFromCommandArgs(["object", "Foo House", "at", "target"]), "Foo House")
        XCTAssertEqual(placeTemplateNameFromCommandArgs(["Foo House"]), "Foo House")
        XCTAssertEqual(splitCommandLineArguments("listTemplates"), ["listTemplates"])
    }

    func testCursorPlacementPositionUsesTargetFace() {
        let hit = RaycastHit(x: 10, y: 64, z: -3, face: 5, cell: Int(cell(B.crafting_table)),
                             t: 2.0, px: 10.9, py: 64.5, pz: -2.5)
        let placement = cursorPlacementPosition(from: hit)

        XCTAssertEqual(placement?.x, 11)
        XCTAssertEqual(placement?.y, 64)
        XCTAssertEqual(placement?.z, -3)
        XCTAssertNil(cursorPlacementPosition(from: nil))
    }

    func testObjectTemplateCopyTargetUsesFreshCenterCrosshairRaycast() throws {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 1357)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.set(4, 65, 8, cell(B.crafting_table))
        chunk.buildHeightmap()
        chunk.status = .lit
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)

        let player = Player(world: world)
        player.setPos(4.5, 64, 4.5)
        player.yaw = 0
        player.pitch = 0

        let hit = try XCTUnwrap(GameCore.crosshairBlock(in: world, player: player))
        XCTAssertEqual(hit.x, 4)
        XCTAssertEqual(hit.y, 65)
        XCTAssertEqual(hit.z, 8)
        XCTAssertEqual(hit.cell >> 4, Int(B.crafting_table))
    }

    func testTerrainTargetIsNotCloneable() {
        let world = makeWorld()
        world.setBlock(1, 63, 1, Int(cell(B.grass_block)))

        XCTAssertThrowsError(try cloneObjectTemplate(named: "grass", from: world, targetX: 1, targetY: 63, targetZ: 1)) { error in
            XCTAssertEqual(error as? TemplateError, .targetNotCloneable)
        }
    }

    func testOversizedCloneIsRejectedByCap() {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.oak_planks)))
        world.setBlock(2, 64, 1, Int(cell(B.oak_planks)))

        XCTAssertThrowsError(try cloneObjectTemplate(
            named: "too big",
            from: world,
            targetX: 1,
            targetY: 64,
            targetZ: 1,
            options: TemplateCloneOptions(maxBlocks: 1, maxSpan: OBJECT_TEMPLATE_MAX_SPAN))) { error in
                XCTAssertEqual(error as? TemplateError, .objectTooLarge(2))
            }
    }
}
