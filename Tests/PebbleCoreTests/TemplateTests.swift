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
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.oak_planks))
        XCTAssertEqual(world.getBlockId(9, 70, 8), Int(B.chest))
        XCTAssertEqual(world.getBlockId(8, 71, 8), Int(B.torch))
        XCTAssertEqual(world.getBlockEntity(9, 70, 8)?.items?[0]?.count, 3)
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

    func testInvalidTemplateNamesAreRejected() {
        XCTAssertNil(normalizedTemplateName("../bad"))
        XCTAssertNil(normalizedTemplateName(""))
        XCTAssertEqual(normalizedTemplateName(" Foo Bar "), "foo bar")
    }

    func testRequestedTemplateCommandPhrasesParseQuotedNames() {
        let cloneParts = splitCommandLineArguments("clone the target with new name \"Foo House\"")
        let placeParts = splitCommandLineArguments("place object \"Foo House\" at the cursor")
        let shortPlaceParts = splitCommandLineArguments("place \"Foo House\" at target")

        XCTAssertEqual(cloneParts, ["clone", "the", "target", "with", "new", "name", "Foo House"])
        XCTAssertEqual(placeParts, ["place", "object", "Foo House", "at", "the", "cursor"])
        XCTAssertEqual(shortPlaceParts, ["place", "Foo House", "at", "target"])
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
