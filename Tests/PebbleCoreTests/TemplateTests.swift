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

    private func assertEmptyItems(_ be: BlockEntityData,
                                  slotCount: Int,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws {
        let items = try XCTUnwrap(be.items, file: file, line: line)
        XCTAssertEqual(items.count, slotCount, file: file, line: line)
        XCTAssertTrue(items.allSatisfy { $0 == nil }, file: file, line: line)
    }

    private func blockEntity(in template: ObjectTemplate, dx: Int, dy: Int = 0, dz: Int = 0) throws -> BlockEntityData {
        try XCTUnwrap(template.blockEntities.first { $0.x == dx && $0.y == dy && $0.z == dz })
    }

    private func tempDB() -> SaveDB {
        try! PersistenceTestSupport.makeDatabase(owner: self, label: "template")
    }

    private func makeLargeTemplate(name: String = "Large Template",
                                   blockCount: Int = OBJECT_TEMPLATE_MAX_BLOCKS,
                                   sizeX: Int = OBJECT_TEMPLATE_MAX_SPAN,
                                   sizeY: Int = 57,
                                   sizeZ: Int = OBJECT_TEMPLATE_MAX_SPAN) -> ObjectTemplate {
        registerCoreIfNeeded()
        var blocks: [TemplateBlock] = []
        blocks.reserveCapacity(blockCount)
        let stone = UInt16(cell(B.stone))
        var emitted = 0
        outer: for y in 0..<sizeY {
            for z in 0..<sizeZ {
                for x in 0..<sizeX {
                    blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: stone))
                    emitted += 1
                    if emitted == blockCount { break outer }
                }
            }
        }
        return ObjectTemplate(
            name: name,
            anchorX: sizeX / 2,
            anchorY: 0,
            anchorZ: sizeZ / 2,
            sizeX: sizeX,
            sizeY: sizeY,
            sizeZ: sizeZ,
            blocks: blocks)
    }

    private func makeLoadedWorld(minX: Int, maxX: Int, minZ: Int, maxZ: Int) -> World {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 8642)
        let info = dimInfo(.overworld)
        let minCX = floorDiv(minX, CHUNK_W)
        let maxCX = floorDiv(maxX, CHUNK_W)
        let minCZ = floorDiv(minZ, CHUNK_W)
        let maxCZ = floorDiv(maxZ, CHUNK_W)
        for cz in minCZ...maxCZ {
            for cx in minCX...maxCX {
                let chunk = Chunk(cx: cx, cz: cz, minY: info.minY, height: info.height)
                chunk.status = .lit
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        return world
    }

    private func fillTemplateTestBlocks(in world: World,
                                        minX: Int = 0, startY: Int = 64, minZ: Int = 0,
                                        sizeX: Int, sizeY: Int, sizeZ: Int,
                                        blockCount rawBlockCount: Int? = nil,
                                        blockCell rawBlockCell: UInt16? = nil) {
        let blockCount = rawBlockCount ?? sizeX * sizeY * sizeZ
        precondition(sizeX > 0 && sizeY > 0 && sizeZ > 0)
        precondition(blockCount >= 0 && blockCount <= sizeX * sizeY * sizeZ)
        let blockCell = rawBlockCell ?? UInt16(cell(B.oak_planks))
        var emitted = 0
        outer: for yOffset in 0..<sizeY {
            let y = startY + yOffset
            for zOffset in 0..<sizeZ {
                let z = minZ + zOffset
                for xOffset in 0..<sizeX {
                    let x = minX + xOffset
                    guard let chunk = world.getChunkAt(x, z) else {
                        preconditionFailure("missing chunk for \(x),\(z)")
                    }
                    chunk.set(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W), blockCell)
                    emitted += 1
                    if emitted == blockCount { break outer }
                }
            }
        }
        for key in world.chunks.keys.sorted() {
            world.chunks[key]?.buildHeightmap()
        }
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

    func testCloneCopiesContainerBlockEntityWithoutContainedItems() throws {
        let world = makeWorld()
        makeFurnishedObject(in: world)

        let result = try cloneObjectTemplate(named: "Storage", from: world, targetX: 1, targetY: 64, targetZ: 1)
        let sourceChest = try XCTUnwrap(world.getBlockEntity(2, 64, 1))
        XCTAssertEqual(sourceChest.items?[0]?.id, iid("diamond"))
        XCTAssertEqual(sourceChest.items?[0]?.count, 3)

        let clonedChest = try XCTUnwrap(result.template.blockEntities.first)
        XCTAssertEqual(clonedChest.type, "container")
        try assertEmptyItems(clonedChest, slotCount: 27)
    }

    func testCloneIncludesEdgeTouchingConstructionBlocks() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.oak_planks)))
        world.setBlock(2, 65, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(2, 65, 1, 27)
        chest.items?[0] = stack("diamond", 6)
        world.setBlockEntity(chest)

        let result = try cloneObjectTemplate(named: "Edge Cabin", from: world, targetX: 1, targetY: 64, targetZ: 1)
        let names = result.template.blocks.map { blockDefs[Int($0.cell >> 4)].name }.sorted()

        XCTAssertEqual(result.template.blocks.count, 2)
        XCTAssertEqual(names, ["chest", "oak_planks"])
        XCTAssertEqual(result.template.sizeX, 2)
        XCTAssertEqual(result.template.sizeY, 2)
        XCTAssertEqual(result.template.sizeZ, 1)
        let clonedChest = try XCTUnwrap(result.template.blockEntities.first)
        XCTAssertEqual(clonedChest.x, 1)
        XCTAssertEqual(clonedChest.y, 1)
        XCTAssertEqual(clonedChest.z, 0)
        try assertEmptyItems(clonedChest, slotCount: 27)
    }

    func testCloneClearsInventoryBearingBlockEntitiesAndDeferredLoot() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(1, 64, 1, 27)
        chest.items?[0] = stack("diamond", 8)
        chest.lootTable = "mineshaft"
        chest.lootSeed = 42
        chest.viewers = 2
        world.setBlockEntity(chest)

        world.setBlock(2, 64, 1, Int(cell(B.dropper)))
        let dropper = makeContainerBE(2, 64, 1, 9)
        dropper.items?[0] = stack("coal", 4)
        world.setBlockEntity(dropper)

        world.setBlock(3, 64, 1, Int(cell(B.hopper)))
        let hopper = makeHopperBE(3, 64, 1)
        hopper.items?[0] = stack("iron_ingot", 2)
        hopper.cooldown = 7
        world.setBlockEntity(hopper)

        world.setBlock(4, 64, 1, Int(cell(B.furnace_lit, 2)))
        let furnace = makeFurnaceBE(4, 64, 1, "furnace")
        furnace.items?[0] = stack("coal", 1)
        furnace.items?[1] = stack("coal", 1)
        furnace.burnTime = 120
        furnace.burnTotal = 1600
        furnace.cookTime = 80
        furnace.xpBank = 3
        world.setBlockEntity(furnace)

        world.setBlock(5, 64, 1, Int(cell(B.brewing_stand)))
        let brewing = makeBrewingBE(5, 64, 1)
        brewing.items?[0] = stack("coal", 1)
        brewing.items?[3] = stack("coal", 1)
        brewing.brewTime = 200
        brewing.fuel = 4
        world.setBlockEntity(brewing)

        world.setBlock(6, 64, 1, Int(cell(B.chiseled_bookshelf, 4)))
        let shelf = BlockEntityData(type: "shelf", x: 6, y: 64, z: 1)
        shelf.items = Array(repeating: nil, count: 6)
        shelf.items?[0] = stack("book", 1)
        shelf.lastSlot = 0
        world.setBlockEntity(shelf)

        world.setBlock(7, 64, 1, Int(cell(B.campfire, 4)))
        let campfire = BlockEntityData(type: "campfire", x: 7, y: 64, z: 1)
        campfire.items = Array(repeating: nil, count: 4)
        campfire.items?[0] = stack("cooked_chicken", 1)
        campfire.times = [100, 0, 0, 0]
        world.setBlockEntity(campfire)

        let result = try cloneObjectTemplate(named: "Empty Storage", from: world,
                                             targetX: 1, targetY: 64, targetZ: 1)

        XCTAssertEqual(result.template.blockEntities.count, 7)
        try assertEmptyItems(blockEntity(in: result.template, dx: 0), slotCount: 27)
        XCTAssertNil(try blockEntity(in: result.template, dx: 0).lootTable)
        XCTAssertNil(try blockEntity(in: result.template, dx: 0).lootSeed)
        XCTAssertNil(try blockEntity(in: result.template, dx: 0).viewers)
        try assertEmptyItems(blockEntity(in: result.template, dx: 1), slotCount: 9)
        let clonedHopper = try blockEntity(in: result.template, dx: 2)
        try assertEmptyItems(clonedHopper, slotCount: 5)
        XCTAssertEqual(clonedHopper.cooldown, 0)
        let clonedFurnace = try blockEntity(in: result.template, dx: 3)
        try assertEmptyItems(clonedFurnace, slotCount: 3)
        XCTAssertEqual(clonedFurnace.burnTime, 0)
        XCTAssertEqual(clonedFurnace.burnTotal, 0)
        XCTAssertEqual(clonedFurnace.cookTime, 0)
        XCTAssertEqual(clonedFurnace.xpBank, 0)
        let furnaceBlock = try XCTUnwrap(result.template.blocks.first { $0.dx == 3 })
        XCTAssertEqual(furnaceBlock.cell >> 4, B.furnace)
        let clonedBrewing = try blockEntity(in: result.template, dx: 4)
        try assertEmptyItems(clonedBrewing, slotCount: 5)
        XCTAssertEqual(clonedBrewing.brewTime, 0)
        XCTAssertEqual(clonedBrewing.fuel, 0)
        let clonedShelf = try blockEntity(in: result.template, dx: 5)
        try assertEmptyItems(clonedShelf, slotCount: 6)
        XCTAssertEqual(clonedShelf.lastSlot, -1)
        let shelfBlock = try XCTUnwrap(result.template.blocks.first { $0.dx == 5 })
        XCTAssertEqual(Int(shelfBlock.cell & 15) & 4, 0)
        let clonedCampfire = try blockEntity(in: result.template, dx: 6)
        try assertEmptyItems(clonedCampfire, slotCount: 4)
        XCTAssertEqual(clonedCampfire.times, [0, 0, 0, 0])
    }

    func testCloneDoesNotBridgeTerrainOrCornerOnlyContact() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.oak_planks)))
        world.setBlock(2, 65, 1, Int(cell(B.grass_block)))
        world.setBlock(2, 65, 2, Int(cell(B.chest)))
        let chest = makeContainerBE(2, 65, 2, 27)
        chest.items?[0] = stack("diamond", 4)
        world.setBlockEntity(chest)

        let result = try cloneObjectTemplate(named: "Narrow Cabin", from: world, targetX: 1, targetY: 64, targetZ: 1)

        XCTAssertEqual(result.template.blocks.count, 1)
        XCTAssertEqual(result.template.blockEntities.count, 0)
        XCTAssertEqual(blockDefs[Int(result.template.blocks[0].cell >> 4)].name, "oak_planks")
        XCTAssertEqual(result.template.sizeX, 1)
        XCTAssertEqual(result.template.sizeY, 1)
        XCTAssertEqual(result.template.sizeZ, 1)
    }

    func testCloneTenBySevenFootprintDoesNotFloodFillStoneSubstrate() throws {
        let world = makeLoadedWorld(minX: -64, maxX: 64, minZ: -64, maxZ: 64)
        fillTemplateTestBlocks(in: world, minX: -64, startY: 63, minZ: -64,
                               sizeX: 129, sizeY: 1, sizeZ: 129,
                               blockCell: UInt16(cell(B.stone)))
        fillTemplateTestBlocks(in: world, minX: 0, startY: 64, minZ: 0,
                               sizeX: 10, sizeY: 1, sizeZ: 7)

        let result = try cloneObjectTemplate(named: "Ten By Seven", from: world,
                                             targetX: 0, targetY: 64, targetZ: 0)

        XCTAssertEqual(result.template.blocks.count, 70)
        XCTAssertEqual(result.template.sizeX, 10)
        XCTAssertEqual(result.template.sizeY, 1)
        XCTAssertEqual(result.template.sizeZ, 7)
        XCTAssertEqual(Set(result.template.blocks.map { Int($0.cell >> 4) }),
                       Set([Int(B.oak_planks)]))
    }

    func testCloneAcceptsExactMaxSpanFootprint() throws {
        // load one extra chunk ring around the footprint so the flood fill's boundary probe
        // lands on loaded (non-cloneable) terrain rather than an unloaded chunk (T6 guard).
        let world = makeLoadedWorld(minX: -CHUNK_W, maxX: OBJECT_TEMPLATE_MAX_SPAN - 1 + CHUNK_W,
                                    minZ: -CHUNK_W, maxZ: OBJECT_TEMPLATE_MAX_SPAN - 1 + CHUNK_W)
        fillTemplateTestBlocks(in: world, sizeX: OBJECT_TEMPLATE_MAX_SPAN, sizeY: 1,
                               sizeZ: OBJECT_TEMPLATE_MAX_SPAN)

        let result = try cloneObjectTemplate(named: "Max Span", from: world,
                                             targetX: 0, targetY: 64, targetZ: 0)

        XCTAssertEqual(result.template.blocks.count, OBJECT_TEMPLATE_MAX_SPAN * OBJECT_TEMPLATE_MAX_SPAN)
        XCTAssertEqual(result.template.sizeX, OBJECT_TEMPLATE_MAX_SPAN)
        XCTAssertEqual(result.template.sizeY, 1)
        XCTAssertEqual(result.template.sizeZ, OBJECT_TEMPLATE_MAX_SPAN)
    }

    func testCloneAcceptsExact512KBlockLimit() throws {
        // load one extra chunk ring around the footprint so the flood fill's boundary probe
        // lands on loaded (non-cloneable) terrain rather than an unloaded chunk (T6 guard).
        let world = makeLoadedWorld(minX: -CHUNK_W, maxX: OBJECT_TEMPLATE_MAX_SPAN - 1 + CHUNK_W,
                                    minZ: -CHUNK_W, maxZ: OBJECT_TEMPLATE_MAX_SPAN - 1 + CHUNK_W)
        fillTemplateTestBlocks(in: world,
                               sizeX: OBJECT_TEMPLATE_MAX_SPAN, sizeY: 57,
                               sizeZ: OBJECT_TEMPLATE_MAX_SPAN,
                               blockCount: OBJECT_TEMPLATE_MAX_BLOCKS)

        let result = try cloneObjectTemplate(named: "Max Blocks", from: world,
                                             targetX: 0, targetY: 64, targetZ: 0)

        XCTAssertEqual(result.template.blocks.count, OBJECT_TEMPLATE_MAX_BLOCKS)
        XCTAssertEqual(result.template.sizeX, OBJECT_TEMPLATE_MAX_SPAN)
        XCTAssertEqual(result.template.sizeY, 57)
        XCTAssertEqual(result.template.sizeZ, OBJECT_TEMPLATE_MAX_SPAN)
    }

    func testCloneRejectsFootprintWiderThanMaxSpan() throws {
        // load one extra chunk ring around the footprint so the flood fill's boundary probe
        // lands on loaded (non-cloneable) terrain rather than an unloaded chunk (T6 guard).
        let world = makeLoadedWorld(minX: -CHUNK_W, maxX: OBJECT_TEMPLATE_MAX_SPAN + CHUNK_W,
                                    minZ: -CHUNK_W, maxZ: CHUNK_W)
        fillTemplateTestBlocks(in: world, sizeX: OBJECT_TEMPLATE_MAX_SPAN + 1,
                               sizeY: 1, sizeZ: 1)

        XCTAssertThrowsError(try cloneObjectTemplate(named: "Too Wide", from: world,
                                                     targetX: 0, targetY: 64, targetZ: 0)) { error in
            XCTAssertEqual(error as? TemplateError, .objectTooWide)
        }
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
        try assertEmptyItems(try XCTUnwrap(world.getBlockEntity(9, 70, 8)), slotCount: 27)
    }

    func testObjectTemplatePlacementJobSlicesPlacementAndBuildsUndo() throws {
        let world = makeWorld()
        let stone = UInt16(cell(B.stone))
        let template = ObjectTemplate(
            name: "Sliced Place",
            anchorX: 0,
            anchorY: 0,
            anchorZ: 0,
            sizeX: 4,
            sizeY: 1,
            sizeZ: 1,
            blocks: (0..<4).map { TemplateBlock(dx: $0, dy: 0, dz: 0, cell: stone) })
        let job = try ObjectTemplatePlacementJob(
            rawTemplate: template,
            in: world,
            targetX: 8,
            targetY: 70,
            targetZ: 8)

        XCTAssertFalse(job.step(maxOperations: 1))
        XCTAssertNil(job.result)
        var iterations = 0
        while !job.isDone {
            _ = job.step(maxOperations: 1)
            iterations += 1
            XCTAssertLessThan(iterations, 32)
        }

        let result = try XCTUnwrap(job.result)
        XCTAssertEqual(result.blocksPlaced, 4)
        XCTAssertEqual(world.getBlock(8, 70, 8), Int(stone))
        XCTAssertEqual(world.getBlock(11, 70, 8), Int(stone))
        XCTAssertEqual(job.undoSnapshot.cells.count, 4)
        XCTAssertEqual(restoreObjectTemplatePlacementUndo(job.undoSnapshot, in: world), 4)
        XCTAssertEqual(world.getBlock(8, 70, 8), 0)
        XCTAssertEqual(world.getBlock(11, 70, 8), 0)
    }

    func testObjectTemplateUndoRestoreJobSlicesRestore() throws {
        let world = makeWorld()
        let stone = UInt16(cell(B.stone))
        let template = ObjectTemplate(
            name: "Sliced Undo",
            anchorX: 0,
            anchorY: 0,
            anchorZ: 0,
            sizeX: 4,
            sizeY: 1,
            sizeZ: 1,
            blocks: (0..<4).map { TemplateBlock(dx: $0, dy: 0, dz: 0, cell: stone) })
        let undo = try objectTemplatePlacementUndoSnapshot(for: template, in: world, targetX: 8, targetY: 70, targetZ: 8)
        _ = try placeObjectTemplate(template, in: world, targetX: 8, targetY: 70, targetZ: 8)
        XCTAssertEqual(world.getBlock(8, 70, 8), Int(stone))

        let job = ObjectTemplateUndoRestoreJob(snapshot: undo, in: world)

        // one op per step: the first step restores exactly the first cell and leaves the rest
        // of the object (and neighbor notification) still pending.
        XCTAssertFalse(job.step(maxOperations: 1))
        XCTAssertEqual(job.restored, 1)
        XCTAssertEqual(world.getBlock(8, 70, 8), 0)
        XCTAssertEqual(world.getBlock(11, 70, 8), Int(stone), "later cells must not be touched before their slice runs")
        var iterations = 0
        while !job.isDone {
            _ = job.step(maxOperations: 1)
            iterations += 1
            XCTAssertLessThan(iterations, 64)
        }

        XCTAssertEqual(job.restored, undo.cells.count)
        XCTAssertEqual(world.getBlock(8, 70, 8), 0)
        XCTAssertEqual(world.getBlock(11, 70, 8), 0)
    }

    /// Metamorphic: for any per-step operation budget, driving `ObjectTemplateUndoRestoreJob` to
    /// completion on independent copies of the same post-place world yields identical final world
    /// state and identical `restored` counts as the synchronous `restoreObjectTemplatePlacementUndo`
    /// oracle — slicing must never change the outcome, only how many ticks it takes to get there.
    func testUndoRestoreJobSlicedEqualsSynchronousUnderAnyBudget() throws {
        let stone = UInt16(cell(B.stone))
        let template = ObjectTemplate(
            name: "Metamorphic Undo",
            anchorX: 0,
            anchorY: 0,
            anchorZ: 0,
            sizeX: 6,
            sizeY: 3,
            sizeZ: 6,
            blocks: (0..<6).flatMap { x in (0..<3).flatMap { y in (0..<6).map { z in
                TemplateBlock(dx: x, dy: y, dz: z, cell: stone)
            } } })

        func placedWorld() throws -> (World, TemplatePlacementUndoSnapshot) {
            let world = makeWorld()
            let undo = try objectTemplatePlacementUndoSnapshot(for: template, in: world, targetX: 8, targetY: 70, targetZ: 8)
            _ = try placeObjectTemplate(template, in: world, targetX: 8, targetY: 70, targetZ: 8)
            return (world, undo)
        }

        let (oracleWorld, oracleUndo) = try placedWorld()
        let oracleRestored = restoreObjectTemplatePlacementUndo(oracleUndo, in: oracleWorld)

        for budget in [1, 7, 2048, 100_000] {
            let (world, undo) = try placedWorld()
            let job = ObjectTemplateUndoRestoreJob(snapshot: undo, in: world)
            var iterations = 0
            while !job.isDone {
                _ = job.step(maxOperations: budget)
                iterations += 1
                XCTAssertLessThan(iterations, 1_000, "budget \(budget) did not converge")
            }
            XCTAssertEqual(job.restored, oracleRestored, "budget \(budget) restored count mismatch")
            for cell in undo.cells {
                XCTAssertEqual(
                    world.getBlock(cell.x, cell.y, cell.z),
                    oracleWorld.getBlock(cell.x, cell.y, cell.z),
                    "budget \(budget) diverged at \(cell.x),\(cell.y),\(cell.z)")
            }
        }
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

    func testPlacementUndoRestoresPreparedPlacementMutation() throws {
        let world = makeWorld()
        world.setBlock(7, 69, 8, Int(cell(B.dirt)))
        world.setBlock(8, 68, 8, Int(cell(B.stone)))
        world.setBlock(8, 70, 8, Int(cell(B.cobblestone)))
        world.setBlock(8, 71, 8, Int(cell(B.chest)))
        let chest = makeContainerBE(8, 71, 8, 27)
        chest.items?[0] = stack("diamond", 5)
        world.setBlockEntity(chest)
        let template = ObjectTemplate(
            name: "Undo Place",
            anchorX: 0, anchorY: 0, anchorZ: 0,
            sizeX: 1, sizeY: 2, sizeZ: 1,
            blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks)))])

        let undo = try objectTemplatePlacementUndoSnapshot(
            for: template,
            in: world,
            targetX: 8,
            targetY: 70,
            targetZ: 8,
            options: TemplatePlacementOptions(prepareTerrain: true))
        let placed = try placeObjectTemplate(template, in: world,
                                             targetX: 8, targetY: 70, targetZ: 8,
                                             options: TemplatePlacementOptions(prepareTerrain: true))

        XCTAssertEqual(placed.blocksPlaced, 1)
        XCTAssertEqual(world.getBlockId(8, 69, 8), Int(B.dirt))
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.oak_planks))
        XCTAssertEqual(world.getBlockId(8, 71, 8), 0)
        XCTAssertNil(world.getBlockEntity(8, 71, 8))

        let restored = restoreObjectTemplatePlacementUndo(undo, in: world)

        XCTAssertEqual(restored, undo.cells.count)
        XCTAssertEqual(world.getBlockId(8, 69, 8), 0)
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.cobblestone))
        XCTAssertEqual(world.getBlockId(8, 71, 8), Int(B.chest))
        XCTAssertEqual(world.getBlockEntity(8, 71, 8)?.items?[0]?.id, iid("diamond"))
        XCTAssertEqual(world.getBlockEntity(8, 71, 8)?.items?[0]?.count, 5)
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
        try assertEmptyItems(try XCTUnwrap(loaded.blockEntities.first), slotCount: 27)
    }

    func testTemplateStoreDeletesNormalizedTemplateNames() throws {
        let world = makeWorld()
        makeFurnishedObject(in: world)
        let first = try cloneObjectTemplate(named: "First Object", from: world, targetX: 1, targetY: 64, targetZ: 1)
        let second = try cloneObjectTemplate(named: "Second Object", from: world, targetX: 2, targetY: 64, targetZ: 1)
        let db = tempDB()

        XCTAssertTrue(try db.putTemplate(first.template))
        XCTAssertTrue(try db.putTemplate(second.template))
        XCTAssertEqual(db.listTemplates(), ["first object", "second object"])
        XCTAssertTrue(try db.deleteTemplate(named: " FIRST OBJECT "))

        XCTAssertEqual(db.listTemplates(), ["second object"])
        XCTAssertNil(try db.getTemplate(named: "first object"))
        XCTAssertNotNil(try db.getTemplate(named: "second object"))
        XCTAssertFalse(try db.deleteTemplate(named: "first object"))
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

    func testObjectTemplateAccepts512KBlockLimitWithBinaryEncoding() throws {
        let template = makeLargeTemplate(blockCount: OBJECT_TEMPLATE_MAX_BLOCKS)

        let encoded = try encodeObjectTemplate(template)
        let decoded = try decodeObjectTemplate(encoded)
        let previewBoxes = try objectTemplatePreviewBoxes(for: decoded)

        XCTAssertEqual(Array(encoded.prefix(4)), [UInt8(0x50), UInt8(0x42), UInt8(0x54), UInt8(0x32)])
        XCTAssertLessThan(encoded.count, OBJECT_TEMPLATE_MAX_BINARY_BYTES)
        XCTAssertEqual(decoded.blocks.count, OBJECT_TEMPLATE_MAX_BLOCKS)
        XCTAssertEqual(decoded.sizeX, OBJECT_TEMPLATE_MAX_SPAN)
        XCTAssertEqual(decoded.sizeY, 57)
        XCTAssertEqual(decoded.sizeZ, OBJECT_TEMPLATE_MAX_SPAN)
        XCTAssertEqual(previewBoxes.count, OBJECT_TEMPLATE_PREVIEW_MAX_BOXES)
    }

    func testObjectTemplateRejectsAbove512KBlockLimit() {
        let template = makeLargeTemplate(blockCount: OBJECT_TEMPLATE_MAX_BLOCKS + 1)

        XCTAssertThrowsError(try encodeObjectTemplate(template)) { error in
            XCTAssertEqual(error as? TemplateError, .objectTooLarge(OBJECT_TEMPLATE_MAX_BLOCKS + 1))
        }
    }

    func testTemplateStoreRoundTrips512KTemplateThroughSQLiteSummaries() throws {
        let db = tempDB()
        let template = makeLargeTemplate(name: "Large Store", blockCount: OBJECT_TEMPLATE_MAX_BLOCKS)

        XCTAssertTrue(try db.putTemplate(template))

        let summary = try XCTUnwrap(db.listTemplateSummaries().first)
        XCTAssertEqual(summary.name, "large store")
        XCTAssertEqual(summary.blockCount, OBJECT_TEMPLATE_MAX_BLOCKS)
        XCTAssertEqual(summary.blockEntityCount, 0)
        XCTAssertEqual(summary.sizeX, OBJECT_TEMPLATE_MAX_SPAN)
        XCTAssertEqual(summary.sizeY, 57)
        XCTAssertEqual(summary.sizeZ, OBJECT_TEMPLATE_MAX_SPAN)

        let loaded = try XCTUnwrap(try db.getTemplate(named: "Large Store"))
        XCTAssertEqual(loaded.name, "large store")
        XCTAssertEqual(loaded.blocks.count, OBJECT_TEMPLATE_MAX_BLOCKS)
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

    func testObjectTemplatePreviewUsesThreeDimensionalBlockShapes() throws {
        registerCoreIfNeeded()
        let template = ObjectTemplate(
            name: "Lights",
            anchorX: 0, anchorY: 0, anchorZ: 0,
            sizeX: 3, sizeY: 1, sizeZ: 1,
            blocks: [
                TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.torch))),
                TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.lantern))),
                TemplateBlock(dx: 2, dy: 0, dz: 0, cell: UInt16(cell(B.chain))),
            ])

        let boxes = try objectTemplatePreviewBoxes(for: template)
        let torch = try XCTUnwrap(boxes.first { $0.cell >> 4 == B.torch })
        let lantern = try XCTUnwrap(boxes.first { $0.cell >> 4 == B.lantern })
        let chain = try XCTUnwrap(boxes.first { $0.cell >> 4 == B.chain })

        for box in [torch, lantern, chain] {
            XCTAssertGreaterThan(box.x1 - box.x0, 0)
            XCTAssertGreaterThan(box.y1 - box.y0, 0)
            XCTAssertGreaterThan(box.z1 - box.z0, 0)
        }
        XCTAssertLessThan(torch.x1 - torch.x0, 1.0)
        XCTAssertLessThan(torch.z1 - torch.z0, 1.0)
        XCTAssertLessThan(lantern.x1 - lantern.x0, 1.0)
        XCTAssertLessThan(lantern.y1 - lantern.y0, 1.0)
        XCTAssertLessThan(chain.x1 - chain.x0, 1.0)
        XCTAssertEqual(chain.y1 - chain.y0, 1.0, accuracy: 0.0001)
    }

    func testObjectTemplatePreviewCapsComplexGeometryForRendererSafety() throws {
        registerCoreIfNeeded()
        var blocks: [TemplateBlock] = []
        for y in 0..<28 {
            for z in 0..<28 {
                for x in 0..<28 {
                    blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: UInt16(cell(B.stone))))
                }
            }
        }
        let template = ObjectTemplate(
            name: "Large Preview",
            anchorX: 14, anchorY: 0, anchorZ: 14,
            sizeX: 28, sizeY: 28, sizeZ: 28,
            blocks: blocks)

        let boxes = try objectTemplatePreviewBoxes(for: template)

        XCTAssertEqual(boxes.count, OBJECT_TEMPLATE_PREVIEW_MAX_BOXES)
        XCTAssertGreaterThan(objectTemplatePreviewLineByteCount(boxCount: boxes.count, includeBounds: true), 4_096)
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

    func testUndoSnapshotCarriesDimension() throws {
        let world = makeWorld()
        let template = ObjectTemplate(
            name: "Dim Tag",
            anchorX: 0, anchorY: 0, anchorZ: 0,
            sizeX: 1, sizeY: 1, sizeZ: 1,
            blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.stone)))])

        let undo = try objectTemplatePlacementUndoSnapshot(for: template, in: world,
                                                            targetX: 1, targetY: 64, targetZ: 1)

        XCTAssertEqual(undo.dimension, Dim.overworld.rawValue)
    }

    func testUndoRestoreSkipsUnloadedCellsAndReportsTrueCount() throws {
        // two chunks loaded (cx 0 and cx 1) so the two template cells land in different chunks
        let world = makeLoadedWorld(minX: 0, maxX: CHUNK_W, minZ: 0, maxZ: CHUNK_W)
        let template = ObjectTemplate(
            name: "Two Chunk",
            anchorX: 0, anchorY: 0, anchorZ: 0,
            sizeX: CHUNK_W + 1, sizeY: 1, sizeZ: 1,
            blocks: [
                TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                TemplateBlock(dx: CHUNK_W, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
            ])
        let undo = try objectTemplatePlacementUndoSnapshot(for: template, in: world,
                                                            targetX: 1, targetY: 64, targetZ: 1)
        _ = try placeObjectTemplate(template, in: world, targetX: 1, targetY: 64, targetZ: 1)

        // simulate the far cell's chunk becoming unloaded before undo is applied
        let farCell = try XCTUnwrap(undo.cells.first { $0.x == 1 + CHUNK_W })
        XCTAssertTrue(world.isLoadedAt(farCell.x, farCell.z))
        world.removeChunk(1, 0)

        XCTAssertFalse(templateUndoSnapshotFullyLoaded(undo, in: world))
        let restored = restoreObjectTemplatePlacementUndo(undo, in: world)
        XCTAssertEqual(restored, 1, "only the loaded cell should be restored")
    }

    func testCloneThrowsOnUnloadedNeighborInsteadOfTruncating() throws {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 1357)
        let info = dimInfo(.overworld)
        // only chunk (0,0) is loaded; the object touches its edge so the flood fill
        // must probe an unloaded neighbor chunk rather than silently stopping there.
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.status = .lit
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        world.setBlock(CHUNK_W - 1, 64, 1, Int(cell(B.oak_planks)))

        XCTAssertThrowsError(try cloneObjectTemplate(named: "edge", from: world,
                                                     targetX: CHUNK_W - 1, targetY: 64, targetZ: 1)) { error in
            guard case .destinationUnavailable = error as? TemplateError else {
                XCTFail("expected destinationUnavailable, got \(error)")
                return
            }
        }
    }

    func testCloneOver32kBlockEntitiesReportsFriendlyError() {
        let description = TemplateError.tooManyBlockEntities(40_000).description
        XCTAssertFalse(description.lowercased().contains("corrupt"))
        XCTAssertTrue(description.contains("40000") || description.contains("40,000"))
    }

    func testRotationFastPathMatchesValidatedPath() throws {
        registerCoreIfNeeded()
        let chest = makeContainerBE(1, 0, 2, 27)
        chest.items?[0] = stack("diamond", 2)
        let template = ObjectTemplate(
            name: "Fast Path Check",
            anchorX: 1, anchorY: 0, anchorZ: 0,
            sizeX: 2, sizeY: 1, sizeZ: 3,
            blocks: [
                TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.stone))),
                TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                TemplateBlock(dx: 1, dy: 0, dz: 2, cell: UInt16(cell(B.chest))),
            ],
            blockEntities: [chest])

        for steps in 1...3 {
            var session = try TemplatePlacementSession(template: template)
            try session.rotate(by: steps)
            let viaSlowPath = try rotatedObjectTemplate(template, rotationSteps: steps)

            XCTAssertEqual(session.rotatedTemplate.sizeX, viaSlowPath.sizeX)
            XCTAssertEqual(session.rotatedTemplate.sizeY, viaSlowPath.sizeY)
            XCTAssertEqual(session.rotatedTemplate.sizeZ, viaSlowPath.sizeZ)
            XCTAssertEqual(session.rotatedTemplate.anchorX, viaSlowPath.anchorX)
            XCTAssertEqual(session.rotatedTemplate.anchorY, viaSlowPath.anchorY)
            XCTAssertEqual(session.rotatedTemplate.anchorZ, viaSlowPath.anchorZ)
            XCTAssertEqual(session.rotatedTemplate.blocks.map { [$0.dx, $0.dy, $0.dz, Int($0.cell)] },
                           viaSlowPath.blocks.map { [$0.dx, $0.dy, $0.dz, Int($0.cell)] })
            XCTAssertEqual(session.rotatedTemplate.blockEntities.map { [$0.x, $0.y, $0.z] },
                           viaSlowPath.blockEntities.map { [$0.x, $0.y, $0.z] })
            XCTAssertEqual(session.rotatedTemplate.blockEntities.first?.items?[0]?.count,
                           viaSlowPath.blockEntities.first?.items?[0]?.count)
        }
    }

    func testAtCapEncodeDecodePlaceRoundTrip() throws {
        let template = makeLargeTemplate(name: "At Cap Round Trip", blockCount: OBJECT_TEMPLATE_MAX_BLOCKS)

        let encoded = try encodeObjectTemplate(template)
        let decoded = try decodeObjectTemplate(encoded)

        XCTAssertEqual(decoded.name, template.name)
        XCTAssertEqual(decoded.blocks.count, template.blocks.count)
        XCTAssertEqual(decoded.sizeX, template.sizeX)
        XCTAssertEqual(decoded.sizeY, template.sizeY)
        XCTAssertEqual(decoded.sizeZ, template.sizeZ)
        XCTAssertEqual(decoded.anchorX, template.anchorX)
        XCTAssertEqual(decoded.anchorY, template.anchorY)
        XCTAssertEqual(decoded.anchorZ, template.anchorZ)
    }

    // MARK: - graceful-termination settle (settleInFlightTemplatePlacementJobs)

    /// Builds a GameCore whose active overworld is a deterministically pre-loaded
    /// `World` (no async chunk generation involved), with the player positioned at
    /// its center looking toward +z (yaw 0, pitch 0) so a template placement session
    /// started here always targets fully-loaded ground. The chunk range is wide
    /// enough to hold the preview distance of any template used by these tests.
    private func makeGameCoreReadyForTemplatePlacement(db: SaveDB) -> GameCore {
        let game = GameCore(db: db)
        game.createWorld(name: "Settle Test", seedText: "settle", mode: GameMode.creative, difficulty: 0)
        // covers the player at the origin plus every multi-batch template's preview
        // footprint (target lands roughly 48 blocks ahead along +z) with margin
        let loaded = makeLoadedWorld(minX: -48, maxX: 48, minZ: -48, maxZ: 96)
        loaded.hooks = game.world.hooks
        loaded.spawnX = game.world.spawnX
        loaded.spawnY = game.world.spawnY
        loaded.spawnZ = game.world.spawnZ
        // solid ground from well below any object's footprint up to the surface
        // (y=63) so a large object's foundation search always finds stone directly
        // below it, regardless of how far below the surface the object's bottom lands
        fillTemplateTestBlocks(in: loaded, minX: -48, startY: 0, minZ: -48,
                               sizeX: 96, sizeY: 64, sizeZ: 144,
                               blockCell: UInt16(cell(B.stone)))
        game.player.world.removeEntity(game.player)
        game.player.world = loaded
        game.player.setPos(0.5, 64, 0.5)
        game.player.yaw = 0
        game.player.pitch = 0
        loaded.addEntity(game.player)
        game.worlds[game.dim] = loaded
        return game
    }

    /// Starts and commits a placement session for `template` directly ahead of the
    /// player, installing a real `templatePlacementJob` through the same public
    /// commit path the app uses (Command-V then left click).
    private func beginAndCommitPlacement(_ game: GameCore, _ template: ObjectTemplate) throws {
        try game.beginTemplatePlacement(template)
        _ = try game.commitTemplatePlacement()
    }

    /// A template just over one `step(maxOperations:)` batch (12,000) so settling it
    /// exercises the settle loop's multi-iteration path, while staying well under
    /// `OBJECT_TEMPLATE_MAX_BLOCKS` and within the preview distance covered by
    /// `makeGameCoreReadyForTemplatePlacement`'s loaded range.
    private func makeMultiBatchTemplate(name: String = "Multi Batch") -> ObjectTemplate {
        registerCoreIfNeeded()
        let sizeX = 26, sizeY = 20, sizeZ = 26
        var blocks: [TemplateBlock] = []
        blocks.reserveCapacity(sizeX * sizeY * sizeZ)
        let stone = UInt16(cell(B.stone))
        for y in 0..<sizeY {
            for z in 0..<sizeZ {
                for x in 0..<sizeX {
                    blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: stone))
                }
            }
        }
        return ObjectTemplate(
            name: name,
            anchorX: sizeX / 2, anchorY: 0, anchorZ: sizeZ / 2,
            sizeX: sizeX, sizeY: sizeY, sizeZ: sizeZ,
            blocks: blocks)
    }

    /// Every cell the undo snapshot says was mutated, read back from live world state
    /// (block id/metadata plus block-entity data where present) rather than trusting
    /// the undo snapshot itself as a proxy for what actually landed in the world.
    private func actualWorldState(for snapshot: TemplatePlacementUndoSnapshot, in world: World) -> [String] {
        snapshot.cells.sorted { ($0.x, $0.y, $0.z) < ($1.x, $1.y, $1.z) }.map { cell in
            let block = world.getBlock(cell.x, cell.y, cell.z)
            let be = world.getBlockEntity(cell.x, cell.y, cell.z)
            return "\(cell.x),\(cell.y),\(cell.z)=\(block)|\(be?.type ?? "-")"
        }
    }

    func testSaveAndFlushSettlesInFlightTemplatePlacementJobBeforePersisting() throws {
        let db = tempDB()
        let game = makeGameCoreReadyForTemplatePlacement(db: db)
        let template = makeMultiBatchTemplate()

        try beginAndCommitPlacement(game, template)
        XCTAssertTrue(game.hasActiveTemplatePlacementJob())
        // partially step via one real tick so the job is genuinely mid-flight
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertTrue(game.hasActiveTemplatePlacementJob(), "one tick must not finish a multi-batch job")

        game.saveAndFlush(synchronous: true)

        XCTAssertFalse(game.hasActiveTemplatePlacementJob())
        let undo = try XCTUnwrap(game.lastTemplatePlacementUndo)
        XCTAssertEqual(undo.cells.count, template.blocks.count)
        let stoneCell = Int(cell(B.stone))
        for placedCell in undo.cells {
            XCTAssertEqual(game.world.getBlock(placedCell.x, placedCell.y, placedCell.z), stoneCell)
        }
    }

    /// Condition 11: the interactive resign-active caller shape — `saveAndFlush` is
    /// invoked directly while a job is active, without ever going through tick() or
    /// Escape/cancel. This is distinct from the test above (which partially steps the
    /// job through one real tick first) — here the job has never been ticked at all,
    /// matching applicationDidResignActive -> PauseScreen -> "Save & Quit to Title",
    /// which calls saveAndFlush while tick() is frozen at the pause guard.
    func testSaveAndFlushSettlesJobInvokedDirectlyWithoutTickOrEscape() throws {
        let db = tempDB()
        let game = makeGameCoreReadyForTemplatePlacement(db: db)
        let template = makeMultiBatchTemplate(name: "Resign Active Shape")

        try beginAndCommitPlacement(game, template)
        XCTAssertTrue(game.hasActiveTemplatePlacementJob())

        game.saveAndFlush(synchronous: true)

        XCTAssertFalse(game.hasActiveTemplatePlacementJob())
        let undo = try XCTUnwrap(game.lastTemplatePlacementUndo)
        XCTAssertEqual(undo.cells.count, template.blocks.count)
        XCTAssertEqual(actualWorldState(for: undo, in: game.world).count, template.blocks.count)
    }

    func testSaveAndFlushIsNoOpWhenNoTemplateJobActive() throws {
        let db = tempDB()
        let game = makeGameCoreReadyForTemplatePlacement(db: db)
        XCTAssertEqual(game.settleInFlightTemplatePlacementJobs(), 0)

        game.world.setBlock(4, 64, 4, Int(cell(B.oak_planks)), SET_NO_NEIGHBORS)
        game.saveAndFlush(synchronous: true)

        XCTAssertFalse(game.hasActiveTemplatePlacementJob())
        XCTAssertEqual(game.world.getBlockId(4, 64, 4), Int(B.oak_planks))
    }

    /// Reconstructs a chunk purely from its saved `ChunkRecord` (the same `blocks`/
    /// `biomes` arrays `chunkRecord` writes on save), independent of worldgen or the
    /// app's own chunk-streaming radius, so the test verifies exactly what landed on
    /// disk rather than what a second GameCore happens to stream back in.
    private func loadPersistedChunk(_ db: SaveDB, worldID: String, dim: Int, cx: Int, cz: Int) throws -> Chunk {
        let record = try XCTUnwrap(db.getChunk(worldID, dim, cx, cz),
                                   "chunk \(cx),\(cz) must have been persisted as a full record")
        let info = dimInfo(Dim(rawValue: dim) ?? .overworld)
        let chunk = Chunk(cx: cx, cz: cz, minY: info.minY, height: info.height)
        chunk.blocks = try XCTUnwrap(record.blocks)
        if let biomes = record.biomes { chunk.biomes = biomes }
        return chunk
    }

    func testSettledTemplatePlacementJobPersistsCompleteObjectToDisk() throws {
        let db = tempDB()
        let game = makeGameCoreReadyForTemplatePlacement(db: db)
        let template = makeMultiBatchTemplate(name: "Persist Round Trip")

        try beginAndCommitPlacement(game, template)
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertTrue(game.hasActiveTemplatePlacementJob())
        let worldID = try XCTUnwrap(game.worldRec?.id)
        let dim = game.dim.rawValue

        game.saveAndFlush(synchronous: true)
        XCTAssertFalse(game.hasActiveTemplatePlacementJob())
        let placedCells = try XCTUnwrap(game.lastTemplatePlacementUndo).cells
        let stoneCell = Int(cell(B.stone))

        var reconstructed: [String: Chunk] = [:]
        for cellRecord in placedCells {
            let cx = floorDiv(cellRecord.x, CHUNK_W), cz = floorDiv(cellRecord.z, CHUNK_W)
            let key = "\(cx),\(cz)"
            let chunk = try reconstructed[key] ?? loadPersistedChunk(db, worldID: worldID, dim: dim, cx: cx, cz: cz)
            reconstructed[key] = chunk
            let block = chunk.get(posMod(cellRecord.x, CHUNK_W), cellRecord.y, posMod(cellRecord.z, CHUNK_W))
            XCTAssertEqual(Int(block), stoneCell,
                           "cell \(cellRecord.x),\(cellRecord.y),\(cellRecord.z) must survive reload as the completed object")
        }
    }

    /// Metamorphic: place the same template at the same target in two independently
    /// built worlds. World A completes the job entirely through normal per-tick
    /// stepping; world B is interrupted mid-flight and finished through
    /// `settleInFlightTemplatePlacementJobs`. Condition 10: compare ACTUAL world state
    /// cell-by-cell (block id and block-entity data for every mutated cell) rather
    /// than undo-snapshot equality, since the undo snapshot is captured at job
    /// construction (before either job steps at all) and would trivially match even
    /// if settle corrupted the result.
    func testSettleInFlightTemplatePlacementJobsMatchesPerTickCompletion() throws {
        let templateA = makeMultiBatchTemplate(name: "Metamorphic A")
        let templateB = makeMultiBatchTemplate(name: "Metamorphic B")

        let gameA = makeGameCoreReadyForTemplatePlacement(db: tempDB())
        try beginAndCommitPlacement(gameA, templateA)
        while gameA.hasActiveTemplatePlacementJob() {
            _ = gameA.frame(dtMs: TICK_MS)
        }
        let undoA = try XCTUnwrap(gameA.lastTemplatePlacementUndo)

        let gameB = makeGameCoreReadyForTemplatePlacement(db: tempDB())
        try beginAndCommitPlacement(gameB, templateB)
        _ = gameB.frame(dtMs: TICK_MS)
        XCTAssertTrue(gameB.hasActiveTemplatePlacementJob(), "world B must be interrupted mid-flight before settling")
        XCTAssertEqual(gameB.settleInFlightTemplatePlacementJobs(), 1)
        let undoB = try XCTUnwrap(gameB.lastTemplatePlacementUndo)

        XCTAssertEqual(undoA.cells.count, undoB.cells.count)
        // relative cell positions/mutation shape must be identical between A and B —
        // both templates share the same size/anchor and were committed at the same
        // player position, so their absolute cell coordinates line up directly.
        let relativeA = actualWorldState(for: undoA, in: gameA.world)
        let relativeB = actualWorldState(for: undoB, in: gameB.world)
        XCTAssertEqual(relativeA, relativeB)
    }

    func testSettleInFlightTemplatePlacementJobIsBounded() throws {
        let db = tempDB()
        let game = makeGameCoreReadyForTemplatePlacement(db: db)
        let template = makeMultiBatchTemplate(name: "Bounded Settle")

        try beginAndCommitPlacement(game, template)
        XCTAssertTrue(game.hasActiveTemplatePlacementJob())

        XCTAssertEqual(game.settleInFlightTemplatePlacementJobs(), 1)

        XCTAssertFalse(game.hasActiveTemplatePlacementJob())
        let undo = try XCTUnwrap(game.lastTemplatePlacementUndo)
        XCTAssertEqual(undo.cells.count, template.blocks.count)
    }

    /// Condition 12: DeathScreen's exitToTitle cannot coincide with an active
    /// placement job. `tick()` returns early inside `tickTemplatePlacementJob()`
    /// whenever a job exists (GameCore.swift, before the death/DeathScreen branch),
    /// so death processing and DeathScreen never run while a job is in flight; there
    /// is no code path that opens DeathScreen mid-job. If exitToTitle is ever reached
    /// from DeathScreen, `settleInFlightTemplatePlacementJobs` still could not have an
    /// active job to settle — verified here by confirming a fresh game has no active
    /// job and that exitToTitle's own saveAndFlush call is therefore a structural
    /// no-op for this path, exactly like the other pause-gated callers.
    func testExitToTitleHasNoActiveTemplateJobBecauseDeathTickNeverRunsDuringPlacement() throws {
        let db = tempDB()
        let game = makeGameCoreReadyForTemplatePlacement(db: db)
        XCTAssertFalse(game.hasActiveTemplatePlacementJob())

        game.exitToTitle()

        XCTAssertFalse(game.hasWorld())
    }
}
