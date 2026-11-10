import XCTest
@testable import ElysiumCore

/// Object templates must not give a player more than the world held.
///
/// Two rules are pinned here. The support fill under a pasted object is made of plain
/// natural ground and never of whatever stood beside the gap. And undo gives back what the
/// placement itself removed, not what stood there when the placement was admitted — on a LAN
/// host the world keeps changing between the two.
@MainActor
final class TemplateDuplicationRegressionTests: XCTestCase {
    private let prepared = TemplatePlacementOptions(prepareTerrain: true)

    private func makeWorld() -> World {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
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

    /// Writes a cell without any of `setBlock`'s side effects, so every registered block,
    /// however exotic, can stand beside the gap.
    private func force(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ cellValue: Int) {
        world.getChunkAt(x, z)!.set(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W), UInt16(cellValue))
    }

    private func plank(name: String, sizeX: Int = 1, sizeY: Int = 1, sizeZ: Int = 1) -> ObjectTemplate {
        var blocks: [TemplateBlock] = []
        for y in 0..<sizeY {
            for z in 0..<sizeZ {
                for x in 0..<sizeX {
                    blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: UInt16(cell(B.oak_planks))))
                }
            }
        }
        return ObjectTemplate(name: name, anchorX: 0, anchorY: 0, anchorZ: 0,
                              sizeX: sizeX, sizeY: sizeY, sizeZ: sizeZ, blocks: blocks)
    }

    private func run(_ job: ObjectTemplatePlacementJob, budget: Int) {
        var steps = 0
        while !job.step(maxOperations: budget) {
            steps += 1
            XCTAssertLessThan(steps, 100_000, "placement job did not converge")
            if steps >= 100_000 { return }
        }
    }

    // MARK: - Support fill

    func testTheSupportFillGroundListIsPlainNaturalTerrain() {
        _ = makeWorld()
        XCTAssertFalse(TEMPLATE_SUPPORT_FILL_GROUND.isEmpty)
        XCTAssertTrue(TEMPLATE_SUPPORT_FILL_GROUND.contains("dirt"), "dirt is the fallback and must be ground")
        for name in TEMPLATE_SUPPORT_FILL_GROUND.sorted() {
            XCTAssertTrue(blockExists(name), "\(name) is not a registered block")
            guard blockExists(name) else { continue }
            let def = blockDefs[Int(bid(name))]
            XCTAssertTrue(def.solid && def.fullCube && !def.replaceable && def.hardness >= 0,
                          "\(name) cannot carry a building")
            XCTAssertFalse(isTemplateCloneableBlock(Int(cell(bid(name)))),
                           "\(name) can be captured by a template, so it is a building block, not ground")
            XCTAssertNil(skillTreeMiningResource(blockID: name), "\(name) earns Mining XP")
            XCTAssertEqual(def.lightEmit, 0, "\(name) gives off light")
            XCTAssertNotEqual(def.piston, .blockEntity, "\(name) needs a block entity")
        }
    }

    /// Every registered solid full cube takes a turn as the first neighbour the fill
    /// inspects. (The ground list holds nothing else, as the test above pins.) The base under
    /// the gap is planks, so nothing else nearby can supply the material.
    func testASupportGapIsFilledWithGroundWhateverStandsBesideIt() throws {
        let world = makeWorld()
        let template = plank(name: "Beside Anything")
        var groundSeen = 0
        for id in 1..<blockDefs.count where blockDefs[id].solid && blockDefs[id].fullCube {
            let name = blockDefs[id].name
            for sliced in [false, true] {
                force(world, 8, 68, 8, Int(cell(B.oak_planks)))
                force(world, 7, 68, 8, Int(cell(B.oak_planks)))     // keeps sand and gravel from falling
                force(world, 7, 69, 8, id << 4)
                force(world, 8, 69, 8, 0)
                force(world, 8, 70, 8, 0)
                if sliced {
                    let job = try ObjectTemplatePlacementJob(rawTemplate: template, in: world,
                                                             targetX: 8, targetY: 70, targetZ: 8, options: prepared)
                    run(job, budget: 1)
                } else {
                    _ = try placeObjectTemplate(template, in: world, targetX: 8, targetY: 70, targetZ: 8,
                                                options: prepared)
                }
                let filled = blockDefs[world.getBlockId(8, 69, 8)].name
                XCTAssertEqual(world.getMeta(8, 69, 8), 0, "\(name): fill keeps no metadata")
                XCTAssertNil(world.getBlockEntity(8, 69, 8), "\(name): fill has no block entity")
                if TEMPLATE_SUPPORT_FILL_GROUND.contains(name) {
                    XCTAssertEqual(filled, name, "ground beside the gap is matched (sliced: \(sliced))")
                    groundSeen += 1
                } else {
                    XCTAssertEqual(filled, "dirt", "\(name) beside the gap must not be copied (sliced: \(sliced))")
                }
            }
        }
        XCTAssertGreaterThan(groundSeen, 0)
        XCTAssertEqual(groundSeen, TEMPLATE_SUPPORT_FILL_GROUND.count * 2, "every ground block was exercised")
    }

    func testValuableNeighboursAreSkippedForTheNextGroundNeighbour() throws {
        for valuable in ["diamond_block", "gold_block", "netherite_block", "glowstone", "packed_ice",
                         "budding_amethyst", "furnace", "spawner", "tnt", "oak_planks", "sandstone",
                         "diamond_ore", "ancient_debris"] {
            let world = makeWorld()
            XCTAssertTrue(blockExists(valuable), valuable)
            world.setBlock(7, 69, 8, Int(cell(bid(valuable))))     // inspected first
            world.setBlock(8, 69, 9, Int(cell(B.netherrack)))      // inspected fourth
            world.setBlock(8, 68, 8, Int(cell(B.stone)))           // inspected fifth
            let placed = try placeObjectTemplate(plank(name: "Next Neighbour"), in: world,
                                                 targetX: 8, targetY: 70, targetZ: 8, options: prepared)
            XCTAssertEqual(placed.supportBlocksFilled, 1, valuable)
            XCTAssertEqual(world.getBlockId(8, 69, 8), Int(B.netherrack), valuable)
            XCTAssertEqual(world.getBlockId(7, 69, 8), Int(bid(valuable)), "\(valuable) itself is untouched")
        }
    }

    // MARK: - Undo gives back what the placement removed

    private struct LootScene {
        let world: World
        let job: ObjectTemplatePlacementJob
        /// A chest in the object volume, a chest in the support gap, and a block in each.
        static let volumeChest = (x: 9, y: 70, z: 8)
        static let gapChest = (x: 10, y: 69, z: 8)
        static let volumeBlock = (x: 8, y: 70, z: 8)
        static let gapBlock = (x: 11, y: 69, z: 8)
    }

    /// A 4x1x1 plank row pasted at y 70 over a stone floor at y 68. The row's volume holds a
    /// diamond block and a full chest; the gap under it holds a second full chest and a lantern.
    private func makeLootScene() throws -> LootScene {
        let world = makeWorld()
        for x in 8...11 { world.setBlock(x, 68, 8, Int(cell(B.stone))) }
        world.setBlock(LootScene.volumeBlock.x, LootScene.volumeBlock.y, LootScene.volumeBlock.z,
                       Int(cell(B.diamond_block)))
        world.setBlock(LootScene.gapBlock.x, LootScene.gapBlock.y, LootScene.gapBlock.z, Int(cell(B.lantern)))
        for spot in [LootScene.volumeChest, LootScene.gapChest] {
            world.setBlock(spot.x, spot.y, spot.z, Int(cell(B.chest)))
            let chest = makeContainerBE(spot.x, spot.y, spot.z, 27)
            chest.items?[0] = stack("diamond", 5)
            world.setBlockEntity(chest)
        }
        let job = try ObjectTemplatePlacementJob(rawTemplate: plank(name: "Over The Loot", sizeX: 4),
                                                 in: world, targetX: 8, targetY: 70, targetZ: 8,
                                                 options: prepared)
        return LootScene(world: world, job: job)
    }

    private func diamonds(in world: World, at spot: (x: Int, y: Int, z: Int)) -> Int {
        (world.getBlockEntity(spot.x, spot.y, spot.z)?.items ?? [])
            .compactMap { $0 }.filter { $0.id == iid("diamond") }.map(\.count).reduce(0, +)
    }

    func testUndoRestoresEverythingWhenNothingChangedDuringThePlacement() throws {
        for budget in [1, 3, 8_192] {
            let scene = try makeLootScene()
            let world = scene.world
            XCTAssertTrue(scene.job.undoSnapshot.cells.isEmpty, "nothing is recorded before the job takes a cell")
            let admitted = try objectTemplatePlacementUndoSnapshot(
                for: plank(name: "Over The Loot", sizeX: 4), in: world, targetX: 8, targetY: 70, targetZ: 8,
                options: prepared)
            run(scene.job, budget: budget)
            let finished = scene.job.undoSnapshot

            XCTAssertEqual(finished.cells.count, admitted.cells.count)
            for (a, b) in zip(admitted.cells, finished.cells) {
                XCTAssertEqual([a.x, a.y, a.z, a.cell], [b.x, b.y, b.z, b.cell], "budget \(budget)")
                XCTAssertEqual(a.blockEntity?.items?[0]?.count, b.blockEntity?.items?[0]?.count, "budget \(budget)")
            }
            XCTAssertEqual(restoreObjectTemplatePlacementUndo(finished, in: world), finished.cells.count)
            XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.diamond_block))
            XCTAssertEqual(world.getBlockId(11, 69, 8), Int(B.lantern))
            XCTAssertEqual(diamonds(in: world, at: LootScene.volumeChest), 5)
            XCTAssertEqual(diamonds(in: world, at: LootScene.gapChest), 5)
        }
    }

    /// The duplication: a paste is admitted, the player empties the chests and mines the
    /// blocks under it before the job reaches them, the job finishes, and undo used to put
    /// the admission-time chests and blocks back.
    func testUndoDoesNotGiveBackWhatAPlayerTookBeforeTheJobReachedIt() throws {
        for budget in [1, 3, 8_192] {
            let scene = try makeLootScene()
            let world = scene.world

            for spot in [LootScene.volumeChest, LootScene.gapChest] {
                world.getBlockEntity(spot.x, spot.y, spot.z)?.items?[0] = nil
            }
            world.setBlock(LootScene.volumeBlock.x, LootScene.volumeBlock.y, LootScene.volumeBlock.z, 0)
            world.setBlock(LootScene.gapBlock.x, LootScene.gapBlock.y, LootScene.gapBlock.z, 0)

            run(scene.job, budget: budget)
            XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.oak_planks))
            _ = restoreObjectTemplatePlacementUndo(scene.job.undoSnapshot, in: world)

            XCTAssertEqual(world.getBlockId(8, 70, 8), 0, "the mined diamond block stays mined (budget \(budget))")
            XCTAssertEqual(world.getBlockId(11, 69, 8), 0, "the taken lantern stays taken (budget \(budget))")
            XCTAssertEqual(world.getBlockId(9, 70, 8), Int(B.chest), "the chest itself was the job's to restore")
            XCTAssertEqual(world.getBlockId(10, 69, 8), Int(B.chest))
            XCTAssertEqual(diamonds(in: world, at: LootScene.volumeChest), 0, "budget \(budget)")
            XCTAssertEqual(diamonds(in: world, at: LootScene.gapChest), 0, "budget \(budget)")
        }
    }

    /// A change made after the job has passed a cell is the job's own loss to give back:
    /// what the job removed returns exactly once.
    func testUndoStillGivesBackWhatTheJobItselfRemoved() throws {
        let scene = try makeLootScene()
        let world = scene.world
        run(scene.job, budget: 8_192)
        world.setBlock(8, 70, 8, 0)                                   // the player mines a pasted plank
        _ = restoreObjectTemplatePlacementUndo(scene.job.undoSnapshot, in: world)
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.diamond_block))
        XCTAssertEqual(diamonds(in: world, at: LootScene.volumeChest), 5)
    }

    /// Something built in the footprint after admission is destroyed by the job, so undo
    /// returns it, in the state the job found it.
    func testUndoReturnsWhatWasBuiltInTheFootprintAfterAdmission() throws {
        let scene = try makeLootScene()
        let world = scene.world
        world.setBlock(8, 70, 8, Int(cell(B.gold_block)))             // replaces the diamond block
        world.getBlockEntity(9, 70, 8)?.items?[0] = stack("diamond", 2)
        run(scene.job, budget: 2)
        _ = restoreObjectTemplatePlacementUndo(scene.job.undoSnapshot, in: world)
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.gold_block))
        XCTAssertEqual(diamonds(in: world, at: LootScene.volumeChest), 2)
    }

    /// A furnace set down inside a running paste is the job's to destroy and undo's to return,
    /// exactly once. `setBlock` keeps a block entity across a same-shape swap, and breaking a
    /// block spills whatever block entity sits under it, so nothing of the furnace may stay
    /// hidden under the pasted block or the fill.
    func testAContainerPlacedInsideARunningPasteLeavesNothingHiddenUnderIt() throws {
        for budget in [1, 8_192] {
            let world = makeWorld()
            for x in 8...9 { world.setBlock(x, 68, 8, Int(cell(B.stone))) }
            let job = try ObjectTemplatePlacementJob(rawTemplate: plank(name: "Over Furnaces", sizeX: 2), in: world,
                                                     targetX: 8, targetY: 70, targetZ: 8, options: prepared)
            // Both cells were air at admission: one is a template cell, one a support gap.
            let spots = [(x: 8, y: 70, z: 8), (x: 9, y: 69, z: 8)]
            for spot in spots {
                world.setBlock(spot.x, spot.y, spot.z, Int(cell(B.furnace)))
                let furnace = makeFurnaceBE(spot.x, spot.y, spot.z, "furnace")
                furnace.items?[0] = stack("diamond", 7)
                world.setBlockEntity(furnace)
            }

            run(job, budget: budget)
            XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.oak_planks))
            XCTAssertNotEqual(world.getBlockId(9, 69, 8), Int(B.furnace))
            for spot in spots {
                XCTAssertNil(world.getBlockEntity(spot.x, spot.y, spot.z),
                             "a furnace's contents stayed hidden at \(spot) (budget \(budget))")
            }

            _ = restoreObjectTemplatePlacementUndo(job.undoSnapshot, in: world)
            for spot in spots {
                XCTAssertEqual(world.getBlockId(spot.x, spot.y, spot.z), Int(B.furnace), "budget \(budget)")
                XCTAssertEqual(diamonds(in: world, at: spot), 7, "budget \(budget)")
            }
        }
    }

    /// A cell whose chunk is not loaded when the job reaches it is not written by the job, so
    /// it never enters the undo record: undo has nothing there to give back.
    func testACellTheJobCouldNotReachIsNotInTheUndoRecord() throws {
        let world = makeWorld()
        for x in 15...16 { world.setBlock(x, 69, 8, Int(cell(B.stone))) }
        world.setBlock(16, 70, 8, Int(cell(B.diamond_block)))         // in chunk (1, 0)
        let job = try ObjectTemplatePlacementJob(rawTemplate: plank(name: "Straddle", sizeX: 2), in: world,
                                                 targetX: 15, targetY: 70, targetZ: 8, options: prepared)
        let saved = try XCTUnwrap(world.getChunk(1, 0))
        world.removeChunk(1, 0)
        run(job, budget: 1)
        world.setChunk(saved)
        XCTAssertEqual(job.undoSnapshot.cells.map { [$0.x, $0.y, $0.z, $0.cell] }, [[15, 70, 8, 0]])
        XCTAssertEqual(world.getBlockId(16, 70, 8), Int(B.diamond_block), "the job wrote nothing it had not recorded")
        XCTAssertEqual(world.getBlockId(15, 70, 8), Int(B.oak_planks))
    }

    /// The ledger finds cells by binary search over the placement order; a wrong comparator
    /// would silently skip the re-read. Every cell of a volume with holes must be found.
    func testEveryCellOfALargePlacementIsReReadExactlyWhenFirstTouched() throws {
        let world = makeWorld()
        for z in 4...9 { for x in 4...9 { world.setBlock(x, 68, z, Int(cell(B.stone))) } }
        // Obstructions in a checker pattern through the volume and the gap.
        for y in 69...72 { for z in 4...9 { for x in 4...9 where (x + y + z) % 2 == 0 {
            world.setBlock(x, y, z, Int(cell(B.cobblestone)))
        } } }
        let checker = plank(name: "Checker", sizeX: 6, sizeY: 3, sizeZ: 6)
        let admitted = try objectTemplatePlacementUndoSnapshot(for: checker, in: world,
                                                               targetX: 4, targetY: 70, targetZ: 4, options: prepared)
        let job = try ObjectTemplatePlacementJob(rawTemplate: checker, in: world,
                                                 targetX: 4, targetY: 70, targetZ: 4, options: prepared)
        // After admission every obstruction is swapped for glass; undo must return glass.
        for cellRecord in admitted.cells where cellRecord.cell >> 4 == Int(B.cobblestone) {
            world.setBlock(cellRecord.x, cellRecord.y, cellRecord.z, Int(cell(B.glass)))
        }
        run(job, budget: 5)
        let finished = job.undoSnapshot
        XCTAssertEqual(finished.cells.count, admitted.cells.count)
        for (before, after) in zip(admitted.cells, finished.cells) {
            XCTAssertEqual([before.x, before.y, before.z], [after.x, after.y, after.z])
            let expected = before.cell >> 4 == Int(B.cobblestone) ? Int(cell(B.glass)) : before.cell
            XCTAssertEqual(after.cell, expected, "cell \(after.x),\(after.y),\(after.z)")
        }
    }

    // MARK: - Unreachable cells

    /// The job could not write the cells in chunk (1, 0) because the chunk was unloaded when it
    /// reached them, so it removed nothing there and undo has nothing there to give back. A
    /// block mined and a chest emptied there must stay that way after undo, whether the player
    /// took them before the chunk unloaded or after it came back.
    func testUndoDoesNotReturnWhatWasTakenFromCellsTheJobNeverReached() throws {
        for takenBeforeTheChunkUnloaded in [true, false] {
            try assertNothingReturnsFromUnreachedCells(takenBeforeTheChunkUnloaded: takenBeforeTheChunkUnloaded)
        }
    }

    private func assertNothingReturnsFromUnreachedCells(takenBeforeTheChunkUnloaded early: Bool) throws {
        let world = makeWorld()
        for z in 8...9 { for x in 15...16 { world.setBlock(x, 69, z, Int(cell(B.stone))) } }
        world.setBlock(16, 70, 8, Int(cell(B.diamond_block)))         // in chunk (1, 0)
        world.setBlock(16, 70, 9, Int(cell(B.chest)))
        let chest = makeContainerBE(16, 70, 9, 27)
        chest.items?[0] = stack("diamond", 5)
        world.setBlockEntity(chest)
        let job = try ObjectTemplatePlacementJob(rawTemplate: plank(name: "Straddle Loot", sizeX: 2, sizeZ: 2), in: world,
                                                 targetX: 15, targetY: 70, targetZ: 8, options: prepared)
        // The player mines the block and empties the chest, either before walking away (the
        // chunk is saved as it then stands) or after coming back. The chunk is unloaded while
        // the job runs and loaded again before undo.
        func take() {
            world.setBlock(16, 70, 8, 0)
            world.getBlockEntity(16, 70, 9)?.items?[0] = nil
        }
        if early { take() }
        let saved = try XCTUnwrap(world.getChunk(1, 0))
        world.removeChunk(1, 0)
        run(job, budget: 1)
        world.setChunk(saved)
        XCTAssertEqual(world.getBlockId(16, 70, 9), Int(B.chest), "the job left the unreached chest alone (early \(early))")
        if !early {
            XCTAssertEqual(diamonds(in: world, at: (x: 16, y: 70, z: 9)), 5, "and its contents")
            take()
        }
        XCTAssertTrue(templateUndoSnapshotFullyLoaded(job.undoSnapshot, in: world))
        XCTAssertFalse(job.undoSnapshot.cells.contains { $0.x == 16 }, "no unreached cell is in the undo record")

        _ = restoreObjectTemplatePlacementUndo(job.undoSnapshot, in: world)
        XCTAssertEqual(world.getBlockId(16, 70, 8), 0, "the diamond block the player mined came back (early \(early))")
        XCTAssertEqual(world.getBlockId(16, 70, 9), Int(B.chest))
        XCTAssertEqual(diamonds(in: world, at: (x: 16, y: 70, z: 9)), 0, "the diamonds the player took came back (early \(early))")
        XCTAssertEqual(world.getBlockId(15, 70, 8), 0, "the reached half is undone as the job found it")
    }

    /// A template's own block entity belongs on the template's block. Where the job could not
    /// write that block (its chunk was unloaded during the block phase and is back for the
    /// block-entity phase), the cell keeps the block entity it really has.
    func testATemplateBlockEntityIsNotAttachedWhereTheJobCouldNotWriteItsBlock() throws {
        let world = makeWorld()
        world.setBlock(16, 70, 8, Int(cell(B.furnace)))               // in chunk (1, 0)
        let furnace = makeFurnaceBE(16, 70, 8, "furnace")
        furnace.items?[0] = stack("diamond", 7)
        world.setBlockEntity(furnace)
        let template = ObjectTemplate(
            name: "Chest Over Furnace", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 2, sizeY: 1, sizeZ: 1,
            blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                     TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.chest)))],
            blockEntities: [makeContainerBE(1, 0, 0, 27)])
        let job = try ObjectTemplatePlacementJob(rawTemplate: template, in: world, targetX: 15, targetY: 70, targetZ: 8,
                                                 options: TemplatePlacementOptions(replaceExisting: true))
        let saved = try XCTUnwrap(world.getChunk(1, 0))
        world.removeChunk(1, 0)
        XCTAssertFalse(job.step(maxOperations: 2))                     // the whole block phase
        world.setChunk(saved)
        run(job, budget: 1)

        XCTAssertEqual(try XCTUnwrap(job.result).blockEntitiesPlaced, 0)
        XCTAssertEqual(world.getBlockId(15, 70, 8), Int(B.oak_planks))
        XCTAssertEqual(world.getBlockId(16, 70, 8), Int(B.furnace))
        XCTAssertEqual(world.getBlockEntity(16, 70, 8)?.type, "furnace", "the template's chest replaced a real furnace's contents")
        XCTAssertEqual(diamonds(in: world, at: (x: 16, y: 70, z: 8)), 7)
        XCTAssertEqual(job.undoSnapshot.cells.map { [$0.x, $0.y, $0.z] }, [[15, 70, 8]])
    }

    /// The same, where the cell the job could not write already holds the template's own
    /// block: a real chest full of diamonds stands where the template puts an empty chest. The
    /// block ids match, so only "the job holds the cell" keeps the template's empty chest from
    /// replacing the real one's contents (with nothing in the undo record to give them back).
    func testATemplateBlockEntityDoesNotReplaceAMatchingBlockTheJobCouldNotWrite() throws {
        let world = makeWorld()
        world.setBlock(16, 70, 8, Int(cell(B.chest)))                 // in chunk (1, 0)
        let chest = makeContainerBE(16, 70, 8, 27)
        chest.items?[0] = stack("diamond", 5)
        world.setBlockEntity(chest)
        let template = ObjectTemplate(
            name: "Chest Over Chest", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 2, sizeY: 1, sizeZ: 1,
            blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                     TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.chest)))],
            blockEntities: [makeContainerBE(1, 0, 0, 27)])
        let job = try ObjectTemplatePlacementJob(rawTemplate: template, in: world, targetX: 15, targetY: 70, targetZ: 8,
                                                 options: TemplatePlacementOptions(replaceExisting: true))
        let saved = try XCTUnwrap(world.getChunk(1, 0))
        world.removeChunk(1, 0)
        XCTAssertFalse(job.step(maxOperations: 2))                     // the whole block phase
        world.setChunk(saved)
        run(job, budget: 1)

        XCTAssertEqual(try XCTUnwrap(job.result).blockEntitiesPlaced, 0)
        XCTAssertEqual(world.getBlockId(16, 70, 8), Int(B.chest))
        XCTAssertEqual(diamonds(in: world, at: (x: 16, y: 70, z: 8)), 5, "the template's empty chest replaced a real chest")
        XCTAssertEqual(job.undoSnapshot.cells.map { [$0.x, $0.y, $0.z] }, [[15, 70, 8]])
    }

    /// A cell the job wrote and a player then rebuilt before the block-entity phase: the
    /// template's chest belongs on the template's chest block only, never on the furnace that
    /// now stands there, whose contents would otherwise be replaced.
    func testATemplateBlockEntityIsNotAttachedToABlockReplacedAfterTheJobWroteIt() throws {
        let world = makeWorld()
        let template = ObjectTemplate(
            name: "Lone Chest", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 1, sizeY: 1, sizeZ: 1,
            blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.chest)))],
            blockEntities: [makeContainerBE(0, 0, 0, 27)])
        let job = try ObjectTemplatePlacementJob(rawTemplate: template, in: world, targetX: 8, targetY: 70, targetZ: 8)
        XCTAssertFalse(job.step(maxOperations: 1))                     // writes the chest block
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.chest))
        world.setBlock(8, 70, 8, Int(cell(B.furnace)))
        let furnace = makeFurnaceBE(8, 70, 8, "furnace")
        furnace.items?[0] = stack("diamond", 7)
        world.setBlockEntity(furnace)
        run(job, budget: 1)

        XCTAssertEqual(try XCTUnwrap(job.result).blockEntitiesPlaced, 0)
        XCTAssertEqual(world.getBlockEntity(8, 70, 8)?.type, "furnace", "the template's chest replaced the furnace's contents")
        XCTAssertEqual(diamonds(in: world, at: (x: 8, y: 70, z: 8)), 7)
    }

    /// A support cell whose chunk is not loaded when the job reaches it is neither filled nor
    /// counted as filled, and stays out of the undo record.
    func testASupportCellTheJobCouldNotReachIsNeitherFilledNorCounted() throws {
        let world = makeWorld()
        for x in 15...16 { world.setBlock(x, 68, 8, Int(cell(B.stone))) }   // gap at y 69 under both
        let job = try ObjectTemplatePlacementJob(rawTemplate: plank(name: "Straddle Gap", sizeX: 2), in: world,
                                                 targetX: 15, targetY: 70, targetZ: 8, options: prepared)
        let saved = try XCTUnwrap(world.getChunk(1, 0))
        world.removeChunk(1, 0)
        run(job, budget: 1)
        world.setChunk(saved)

        let result = try XCTUnwrap(job.result)
        XCTAssertEqual(result.supportBlocksFilled, 1, "only the reachable support cell was filled")
        XCTAssertEqual(world.getBlockId(15, 69, 8), Int(B.stone))
        XCTAssertEqual(world.getBlockId(16, 69, 8), 0)
        XCTAssertEqual(job.undoSnapshot.cells.map { [$0.x, $0.y, $0.z, $0.cell] }, [[15, 69, 8, 0], [15, 70, 8, 0]])
    }

    /// A prepared paste clears its whole volume, including the holes between the template's own
    /// blocks: an obstruction there is a cell only the clearance plan names. It is cleared,
    /// counted, recorded, and given back by undo.
    func testAPreparedPasteClearsTheHolesInItsVolumeAndUndoReturnsThem() throws {
        for budget in [1, 8_192] {
            let world = makeWorld()
            for x in 8...10 { world.setBlock(x, 69, 8, Int(cell(B.stone))) }
            world.setBlock(9, 70, 8, Int(cell(B.diamond_block)))
            let hollow = ObjectTemplate(
                name: "Hollow", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 3, sizeY: 1, sizeZ: 1,
                blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks))),
                         TemplateBlock(dx: 2, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks)))])
            let job = try ObjectTemplatePlacementJob(rawTemplate: hollow, in: world, targetX: 8, targetY: 70, targetZ: 8,
                                                     options: prepared)
            run(job, budget: budget)
            XCTAssertEqual(try XCTUnwrap(job.result).blocksCleared, 1, "budget \(budget)")
            XCTAssertEqual((8...10).map { world.getBlockId($0, 70, 8) }, [Int(B.oak_planks), 0, Int(B.oak_planks)],
                           "the obstruction in the hole was left standing (budget \(budget))")
            XCTAssertEqual(job.undoSnapshot.cells.map { [$0.x, $0.y, $0.z, $0.cell] },
                           [[8, 70, 8, 0], [9, 70, 8, Int(cell(B.diamond_block))], [10, 70, 8, 0]], "budget \(budget)")

            _ = restoreObjectTemplatePlacementUndo(job.undoSnapshot, in: world)
            XCTAssertEqual((8...10).map { world.getBlockId($0, 70, 8) }, [0, Int(B.diamond_block), 0], "budget \(budget)")
        }
    }

    /// The ledger's rule in isolation: nothing is recorded at admission, a cell is recorded
    /// only while its chunk is loaded, only once, and only if the placement planned it; and
    /// `record` answers whether the job may write the cell now.
    func testTheLedgerRecordsACellOnlyWhileItsChunkIsLoadedAndOnlyOnce() throws {
        let world = makeWorld()
        let p = TemplatePos(x: 20, y: 70, z: 4)                       // chunk (1, 0)
        force(world, p.x, p.y, p.z, Int(cell(B.stone)))
        var ledger = TemplateUndoLedger(templateName: "Away", dimension: world.dim.rawValue, positions: [p])
        XCTAssertTrue(ledger.snapshot.cells.isEmpty, "nothing is recorded at admission")
        XCTAssertFalse(ledger.holds(p))

        let saved = try XCTUnwrap(world.getChunk(1, 0))
        world.removeChunk(1, 0)
        XCTAssertFalse(ledger.record(p, in: world), "an unloaded cell may not be written")
        XCTAssertTrue(ledger.snapshot.cells.isEmpty, "and is not recorded as the air an unloaded chunk reads as")

        world.setChunk(saved)
        force(world, p.x, p.y, p.z, Int(cell(B.glass)))
        XCTAssertTrue(ledger.record(p, in: world))
        XCTAssertEqual(ledger.snapshot.cells.map(\.cell), [Int(cell(B.glass))], "the first loaded touch records the cell")
        force(world, p.x, p.y, p.z, Int(cell(B.cobblestone)))
        XCTAssertTrue(ledger.record(p, in: world))
        XCTAssertEqual(ledger.snapshot.cells.map(\.cell), [Int(cell(B.glass))], "and no later touch replaces it")
        XCTAssertFalse(ledger.record(TemplatePos(x: 21, y: 70, z: 4), in: world), "an unplanned cell may not be written")

        world.removeChunk(1, 0)
        XCTAssertFalse(ledger.record(p, in: world), "a recorded cell may not be written while its chunk is away")
        XCTAssertTrue(ledger.holds(p))
        XCTAssertEqual(ledger.snapshot.cells.count, 1)
    }

    // MARK: - The ledger against a brute-force lookup

    /// `record` finds a cell by binary search over the (y, z, x) order. For seeded random
    /// position sets, including negative coordinates on both sides of a chunk border, a probe
    /// must record exactly the listed cell it names (a linear membership test is the oracle),
    /// an unlisted probe must be refused and change nothing, and a second probe must never
    /// replace the first reading.
    func testTheLedgerRecordsExactlyTheListedCellForSeededPositionSets() {
        let world = makeWorldAroundOrigin()
        let stoneCell = Int(cell(B.stone)), glassCell = Int(cell(B.glass)), cobbleCell = Int(cell(B.cobblestone))
        var settledChecks = 0, untouchedChecks = 0, emptyLedgers = 0
        for seed in UInt64(1)...150 {
            var rng = TemplateSceneGenerator(seed: seed)
            func randomPos() -> TemplatePos {
                TemplatePos(x: -16 + rng.int(32), y: 60 + rng.int(12), z: -16 + rng.int(32))
            }
            var listed = Set<TemplatePos>()
            let count = rng.int(48)
            while listed.count < count { listed.insert(randomPos()) }
            let positions = listed.sorted()
            if positions.isEmpty { emptyLedgers += 1 }
            for p in positions { force(world, p.x, p.y, p.z, stoneCell) }
            var ledger = TemplateUndoLedger(templateName: "Ledger \(seed)", dimension: world.dim.rawValue,
                                            positions: positions)
            XCTAssertTrue(ledger.snapshot.cells.isEmpty, "seed \(seed)")

            // Probes: about half the listed cells, their unlisted x-neighbours (adjacent in the
            // search order) and some random cells, in a seeded shuffled order.
            var probes = positions.filter { _ in rng.int(2) == 0 }
            for p in positions where rng.int(3) == 0 {
                for q in [TemplatePos(x: p.x - 1, y: p.y, z: p.z), TemplatePos(x: p.x + 1, y: p.y, z: p.z)]
                where !listed.contains(q) && (-16..<16).contains(q.x) {
                    probes.append(q)
                }
            }
            for _ in 0..<rng.int(12) { probes.append(randomPos()) }
            probes = probes.map { ($0, rng.next()) }.sorted { $0.1 < $1.1 }.map(\.0)
            let probed = Set(probes)
            let touched = listed.union(probed)

            for p in touched { force(world, p.x, p.y, p.z, glassCell) }
            for p in probes {
                XCTAssertEqual(ledger.record(p, in: world), listed.contains(p), "seed \(seed): \(p.x),\(p.y),\(p.z)")
            }
            let recordedFirst = positions.filter(probed.contains)
            XCTAssertEqual(ledger.snapshot.cells.map { TemplatePos(x: $0.x, y: $0.y, z: $0.z) }, recordedFirst,
                           "seed \(seed): exactly the probed listed cells, ascending")
            XCTAssertTrue(ledger.snapshot.cells.allSatisfy { $0.cell == glassCell }, "seed \(seed)")
            for p in positions {
                XCTAssertEqual(ledger.holds(p), probed.contains(p), "seed \(seed): \(p.x),\(p.y),\(p.z)")
                if probed.contains(p) { settledChecks += 1 } else { untouchedChecks += 1 }
            }

            for p in touched { force(world, p.x, p.y, p.z, cobbleCell) }
            for p in positions { XCTAssertTrue(ledger.record(p, in: world)) }
            XCTAssertEqual(ledger.snapshot.cells.count, positions.count, "seed \(seed)")
            for (index, recorded) in ledger.snapshot.cells.enumerated() {
                let p = positions[index]
                XCTAssertEqual([recorded.x, recorded.y, recorded.z], [p.x, p.y, p.z], "seed \(seed)")
                XCTAssertEqual(recorded.cell, probed.contains(p) ? glassCell : cobbleCell,
                               "seed \(seed): a second reading replaced the first at \(p.x),\(p.y),\(p.z)")
            }
            for p in touched { force(world, p.x, p.y, p.z, 0) }
        }
        XCTAssertGreaterThan(settledChecks, 500)
        XCTAssertGreaterThan(untouchedChecks, 500)
        XCTAssertGreaterThan(emptyLedgers, 0, "an empty ledger must also be probed")
    }

    // MARK: - The fill, cell by cell

    /// The doc order (west, east, north, south, below, above) decides which ground a column
    /// takes, so it is part of the deterministic result. The gap sits at (-1, 69, -1), where its
    /// four sides lie in four different chunks.
    func testTheFillTakesTheFirstGroundNeighbourInDocumentedOrderWithoutItsMetadata() {
        let world = makeWorldAroundOrigin()
        let (x, y, z) = (-1, 69, -1)
        let sides: [(x: Int, y: Int, z: Int, block: UInt16, name: String)] = [
            (x - 1, y, z, B.sand, "west"), (x + 1, y, z, B.gravel, "east"),
            (x, y, z - 1, B.granite, "north"), (x, y, z + 1, B.diorite, "south"),
            (x, y - 1, z, B.andesite, "below"), (x, y + 1, z, B.netherrack, "above"),
        ]
        for (index, side) in sides.enumerated() {
            force(world, side.x, side.y, side.z, Int(cell(side.block, 1 + index)))
        }
        for side in sides {
            XCTAssertEqual(templateSupportFillCell(in: world, x, y, z), Int(cell(side.block)),
                           "\(side.name) is read next and its metadata is dropped")
            force(world, side.x, side.y, side.z, Int(cell(B.diamond_block)))   // not ground: the next side wins
        }
        XCTAssertEqual(templateSupportFillCell(in: world, x, y, z), Int(cell(B.dirt)), "no ground around: dirt")

        // A cell id outside the registry (a corrupt chunk) is skipped, never indexed.
        if blockDefs.count < 4096 {
            force(world, x - 1, y, z, blockDefs.count << 4)
            force(world, x + 1, y, z, Int(cell(B.stone, 5)))
            XCTAssertEqual(templateSupportFillCell(in: world, x, y, z), Int(cell(B.stone)))
        }
    }

    // MARK: - Paths without terrain preparation

    /// With `prepareTerrain: false` (here with `replaceExisting`, as the debug runtime may ask
    /// for) nothing is cleared or filled, so the block phase is the only first touch. A chest
    /// emptied after admission must not be refilled by undo, and a furnace overwritten by
    /// planks (a same-shape swap that `setBlock` keeps a block entity across) must leave
    /// nothing hidden under them.
    func testAReplacingPasteWithoutTerrainPreparationRecordsItsCellsAtTheBlockPhase() throws {
        for budget in [1, 8_192] {
            let world = makeWorld()
            world.setBlock(8, 70, 8, Int(cell(B.chest)))
            let chest = makeContainerBE(8, 70, 8, 27)
            chest.items?[0] = stack("diamond", 5)
            world.setBlockEntity(chest)
            world.setBlock(9, 70, 8, Int(cell(B.furnace)))
            let furnace = makeFurnaceBE(9, 70, 8, "furnace")
            furnace.items?[0] = stack("diamond", 7)
            world.setBlockEntity(furnace)
            let template = ObjectTemplate(
                name: "Replace In Place", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 2, sizeY: 1, sizeZ: 1,
                blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.chest))),
                         TemplateBlock(dx: 1, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks)))],
                blockEntities: [makeContainerBE(0, 0, 0, 27)])
            let job = try ObjectTemplatePlacementJob(rawTemplate: template, in: world, targetX: 8, targetY: 70, targetZ: 8,
                                                     options: TemplatePlacementOptions(replaceExisting: true))
            XCTAssertTrue(job.undoSnapshot.cells.isEmpty)

            world.getBlockEntity(8, 70, 8)?.items?[0] = nil
            world.getBlockEntity(9, 70, 8)?.items?[0]?.count = 3
            run(job, budget: budget)
            XCTAssertEqual(job.undoSnapshot.cells.count, 2)

            let result = try XCTUnwrap(job.result)
            XCTAssertEqual([result.blocksPlaced, result.blockEntitiesPlaced, result.blocksCleared, result.supportBlocksFilled],
                           [2, 1, 0, 0], "budget \(budget)")
            XCTAssertEqual(world.getBlockEntity(8, 70, 8)?.type, "container", "the template's own chest is placed")
            XCTAssertEqual(diamonds(in: world, at: (x: 8, y: 70, z: 8)), 0)
            XCTAssertNil(world.getBlockEntity(9, 70, 8), "the furnace stayed hidden under the planks (budget \(budget))")

            _ = restoreObjectTemplatePlacementUndo(job.undoSnapshot, in: world)
            XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.chest))
            XCTAssertEqual(diamonds(in: world, at: (x: 8, y: 70, z: 8)), 0, "the emptied chest came back full (budget \(budget))")
            XCTAssertEqual(world.getBlockId(9, 70, 8), Int(B.furnace))
            XCTAssertEqual(diamonds(in: world, at: (x: 9, y: 70, z: 8)), 3, "the furnace returns as the job found it")
        }
    }

    /// The synchronous `placeObjectTemplate` (the debug-control runtime's `template.place`,
    /// which passes `replaceExisting` through) is the job run to completion, so it too drops
    /// the block entity under every cell it writes. It once had its own implementation that
    /// did not: a furnace overwritten by planks kept its contents hidden under them.
    func testTheSynchronousPasteLeavesNoBlockEntityUnderWhatItWrote() throws {
        let world = makeWorld()
        world.setBlock(9, 70, 8, Int(cell(B.furnace)))
        let furnace = makeFurnaceBE(9, 70, 8, "furnace")
        furnace.items?[0] = stack("diamond", 7)
        world.setBlockEntity(furnace)
        _ = try placeObjectTemplate(plank(name: "Sync Over Furnace"), in: world, targetX: 9, targetY: 70, targetZ: 8,
                                    options: TemplatePlacementOptions(replaceExisting: true))
        XCTAssertEqual(world.getBlockId(9, 70, 8), Int(B.oak_planks))
        XCTAssertNil(world.getBlockEntity(9, 70, 8), "the furnace's contents are hidden under the pasted plank")
    }

    /// A cell the job cleared and the player then built on again before the block phase: undo
    /// returns what the job removed first, once, and the new chest's block entity is not left
    /// under the pasted plank. (The chest itself is overwritten by the paste, as anything built
    /// inside a running paste's volume is.)
    func testACellClearedByTheJobAndBuiltOnBeforeTheBlockPhaseUndoesToWhatTheJobRemoved() throws {
        let world = makeWorld()
        for x in 8...9 { world.setBlock(x, 69, 8, Int(cell(B.stone))) }
        world.setBlock(8, 70, 8, Int(cell(B.diamond_block)))
        let job = try ObjectTemplatePlacementJob(rawTemplate: plank(name: "Rebuilt", sizeX: 2), in: world,
                                                 targetX: 8, targetY: 70, targetZ: 8, options: prepared)
        XCTAssertFalse(job.step(maxOperations: 1))                     // clears (8, 70, 8)
        XCTAssertEqual(world.getBlockId(8, 70, 8), 0)
        world.setBlock(8, 70, 8, Int(cell(B.chest)))
        let chest = makeContainerBE(8, 70, 8, 27)
        chest.items?[0] = stack("emerald", 4)
        world.setBlockEntity(chest)
        run(job, budget: 1)
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.oak_planks))
        XCTAssertNil(world.getBlockEntity(8, 70, 8))

        _ = restoreObjectTemplatePlacementUndo(job.undoSnapshot, in: world)
        XCTAssertEqual(world.getBlockId(8, 70, 8), Int(B.diamond_block), "undo returns what the job removed first")
        XCTAssertNil(world.getBlockEntity(8, 70, 8))
        XCTAssertEqual(world.getBlockId(9, 70, 8), 0)
    }

    // MARK: - The local game path

    /// Single player: the click commits a job, the game finishes it on its own tick, and
    /// Command-Z restores the record the finished job built, not one read at the click.
    func testLocalGameUndoRestoresWhatTheFinishedJobTookNotWhatStoodThereAtTheClick() throws {
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self, label: "template-ledger"))
        game.createWorld(name: "Ledger Test", seedText: "ledger", mode: GameMode.creative, difficulty: 0)
        let world = World(dim: .overworld, seed: 8642)
        let info = dimInfo(.overworld)
        for cz in -1...2 {
            for cx in -1...1 {
                let chunk = Chunk(cx: cx, cz: cz, minY: info.minY, height: info.height)
                chunk.status = .lit
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        world.hooks = game.world.hooks
        world.spawnX = game.world.spawnX
        world.spawnY = game.world.spawnY
        world.spawnZ = game.world.spawnZ
        game.player.world.removeEntity(game.player)
        game.player.world = world
        game.player.setPos(0.5, 64, 0.5)
        game.player.yaw = 0
        game.player.pitch = 0
        world.addEntity(game.player)
        game.worlds[game.dim] = world

        try game.beginTemplatePlacement(plank(name: "Local Ledger", sizeX: 3))
        let target = try XCTUnwrap(game.templatePlacementTarget())
        let (x0, y0, z0) = (target.originX, target.originY, target.originZ)
        for dx in 0...2 { world.setBlock(x0 + dx, y0 - 2, z0, Int(cell(B.stone))) }
        for dx in 0...1 { world.setBlock(x0 + dx, y0 - 1, z0, Int(cell(B.stone))) }
        for (spot, item, count) in [((x: x0 + 1, y: y0, z: z0), "diamond", 5), ((x: x0 + 2, y: y0 - 1, z: z0), "emerald", 3)] {
            world.setBlock(spot.x, spot.y, spot.z, Int(cell(B.chest)))
            let chest = makeContainerBE(spot.x, spot.y, spot.z, 27)
            chest.items?[0] = stack(item, count)
            world.setBlockEntity(chest)
        }

        XCTAssertNil(try game.commitTemplatePlacement())
        XCTAssertTrue(game.hasActiveTemplatePlacementJob())
        world.getBlockEntity(x0 + 1, y0, z0)?.items?[0] = nil         // taken after the click
        var frames = 0
        while game.hasActiveTemplatePlacementJob() {
            _ = game.frame(dtMs: TICK_MS)
            frames += 1
            guard frames < 400 else { return XCTFail("the local placement job never finished") }
        }
        for dx in 0...2 { XCTAssertEqual(game.world.getBlockId(x0 + dx, y0, z0), Int(B.oak_planks)) }
        XCTAssertNil(game.world.getBlockEntity(x0 + 1, y0, z0))
        XCTAssertNil(game.world.getBlockEntity(x0 + 2, y0 - 1, z0))
        XCTAssertEqual(game.lastTemplatePlacementUndo?.cells.count, 4, "three object cells and one support cell")

        XCTAssertTrue(game.undoLastTemplatePlacement())
        XCTAssertNil(game.lastTemplatePlacementUndo)
        XCTAssertEqual(game.world.getBlockId(x0, y0, z0), 0)
        XCTAssertEqual(game.world.getBlockId(x0 + 1, y0, z0), Int(B.chest))
        XCTAssertEqual(diamonds(in: game.world, at: (x: x0 + 1, y: y0, z: z0)), 0, "the diamonds taken after the click came back")
        XCTAssertEqual(game.world.getBlockId(x0 + 2, y0 - 1, z0), Int(B.chest))
        let emeralds = game.world.getBlockEntity(x0 + 2, y0 - 1, z0)?.items?[0]
        XCTAssertEqual(emeralds?.id, iid("emerald"))
        XCTAssertEqual(emeralds?.count, 3, "what the fill destroyed comes back once")
    }

    // MARK: - Seeded scenes: sliced == synchronous, and undo under mid-flight edits

    /// Four chunks around the origin, so seeded placements cross the x = 0 and z = 0 chunk
    /// borders at negative coordinates, where `floorDiv`/`posMod` matter. Unlit, like the LAN
    /// tests' worlds: placement never reads light, and lighting hundreds of seeded worlds
    /// would dominate the run.
    private func makeWorldAroundOrigin() -> World {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
        let world = World(dim: .overworld, seed: 1357)
        let info = dimInfo(.overworld)
        for cz in -1...0 {
            for cx in -1...0 {
                let chunk = Chunk(cx: cx, cz: cz, minY: info.minY, height: info.height)
                chunk.status = .generated
                world.setChunk(chunk)
            }
        }
        return world
    }

    private struct SeededScene {
        let template: ObjectTemplate
        let rotated: ObjectTemplate
        let rotation: Int
        let origin: TemplatePos
        let prepareTerrain: Bool
        var target: TemplatePos {
            TemplatePos(x: origin.x + rotated.anchorX, y: origin.y + rotated.anchorY, z: origin.z + rotated.anchorZ)
        }
        var options: TemplatePlacementOptions { TemplatePlacementOptions(prepareTerrain: prepareTerrain) }
        /// The object volume, the deepest possible gap and one ring of neighbours.
        var region: [TemplatePos] {
            var out: [TemplatePos] = []
            for y in (origin.y - 5)...(origin.y + rotated.sizeY) {
                for z in (origin.z - 1)...(origin.z + rotated.sizeZ) {
                    for x in (origin.x - 1)...(origin.x + rotated.sizeX) { out.append(TemplatePos(x: x, y: y, z: z)) }
                }
            }
            return out
        }
    }

    private func blockEntitySignature(_ be: BlockEntityData) -> String {
        let items = (be.items ?? []).enumerated().compactMap { slot, item in item.map { "\(slot):\($0.id)x\($0.count)" } }
        return "\(be.type)[\(items.joined(separator: ","))]"
    }

    private func state(_ world: World, _ p: TemplatePos) -> String {
        "\(world.getBlock(p.x, p.y, p.z))|" + (world.getBlockEntity(p.x, p.y, p.z).map(blockEntitySignature) ?? "-")
    }

    private func signature(_ c: TemplatePlacementUndoCell) -> String {
        "\(c.x),\(c.y),\(c.z)=\(c.cell)|" + (c.blockEntity.map(blockEntitySignature) ?? "-")
    }

    private func regionState(_ world: World, _ scene: SeededScene) -> [String] {
        scene.region.map { state(world, $0) }
    }

    private func putContainer(_ world: World, _ p: TemplatePos, furnace: Bool, _ rng: inout TemplateSceneGenerator) {
        world.setBlock(p.x, p.y, p.z, Int(cell(furnace ? B.furnace : B.chest)), SET_NO_NEIGHBORS)
        let be = furnace ? makeFurnaceBE(p.x, p.y, p.z, "furnace") : makeContainerBE(p.x, p.y, p.z, 27)
        be.items?[0] = stack(rng.pick(["diamond", "emerald", "gold_ingot"]), 1 + rng.int(9))
        world.setBlockEntity(be)
    }

    /// The same seed always builds the same world and template, so two worlds from one seed
    /// can be driven down different paths and compared cell by cell. World blocks and template
    /// blocks never share a cell value (world chests always hold loot; template chests are
    /// empty), so a cell still reading as it did at admission has not been touched by the job.
    private func makeSeededScene(seed: UInt64, prepareTerrain: Bool) throws -> (World, SeededScene) {
        var rng = TemplateSceneGenerator(seed: seed)
        let world = makeWorldAroundOrigin()
        let sizeX = 1 + rng.int(4), sizeY = 1 + rng.int(3), sizeZ = 1 + rng.int(4)
        let palette = [B.oak_planks, B.glass, B.bricks, B.coal_ore, B.chest]
        var blocks: [TemplateBlock] = []
        var blockEntities: [BlockEntityData] = []
        for y in 0..<sizeY {
            for z in 0..<sizeZ {
                for x in 0..<sizeX where rng.int(10) < 7 {
                    let block = rng.pick(palette)
                    blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: cell(block)))
                    if block == B.chest { blockEntities.append(makeContainerBE(x, y, z, 27)) }
                }
            }
        }
        if blocks.isEmpty { blocks.append(TemplateBlock(dx: 0, dy: 0, dz: 0, cell: cell(B.oak_planks))) }
        let template = ObjectTemplate(name: "Seeded \(seed)", anchorX: rng.int(sizeX), anchorY: 0, anchorZ: rng.int(sizeZ),
                                      sizeX: sizeX, sizeY: sizeY, sizeZ: sizeZ,
                                      blocks: blocks, blockEntities: blockEntities)
        let rotation = rng.int(4)
        let rotated = try rotatedObjectTemplate(template, rotationSteps: rotation)
        let origin = TemplatePos(x: -3 + rng.int(4), y: 70, z: -3 + rng.int(4))
        let templateCells = Set(rotated.blocks.map { TemplatePos(x: origin.x + $0.dx, y: origin.y + $0.dy, z: origin.z + $0.dz) })

        // Loose ground beside the gaps, so the fill sometimes finds ground and sometimes not.
        for y in (origin.y - 4)..<origin.y {
            for z in (origin.z - 1)...(origin.z + rotated.sizeZ) {
                for x in (origin.x - 1)...(origin.x + rotated.sizeX) {
                    let block = rng.pick([0, 0, B.stone, B.granite, B.diamond_block, B.dirt])
                    world.setBlock(x, y, z, Int(cell(block)), SET_NO_NEIGHBORS)
                }
            }
        }
        for dz in 0..<rotated.sizeZ {
            for dx in 0..<rotated.sizeX {
                let (x, z) = (origin.x + dx, origin.z + dz)
                let floorY = origin.y - 1 - rng.int(4)
                world.setBlock(x, floorY, z, Int(cell(rng.pick([B.stone, B.dirt, B.granite, B.cobblestone, B.diamond_block]))),
                               SET_NO_NEIGHBORS)
                for y in (floorY + 1)..<origin.y {
                    let p = TemplatePos(x: x, y: y, z: z)
                    switch rng.int(20) {
                    case 0..<12: world.setBlock(x, y, z, 0, SET_NO_NEIGHBORS)
                    case 12..<17: putContainer(world, p, furnace: false, &rng)
                    default: world.setBlock(x, y, z, Int(cell(B.glass)), SET_NO_NEIGHBORS)
                    }
                }
                for y in origin.y..<(origin.y + rotated.sizeY) {
                    let p = TemplatePos(x: x, y: y, z: z)
                    if !prepareTerrain && templateCells.contains(p) {
                        world.setBlock(x, y, z, 0, SET_NO_NEIGHBORS)
                        continue
                    }
                    switch rng.int(16) {
                    case 0..<8: world.setBlock(x, y, z, 0, SET_NO_NEIGHBORS)
                    case 8: putContainer(world, p, furnace: false, &rng)
                    case 9: putContainer(world, p, furnace: true, &rng)
                    default:
                        let block = rng.pick([B.stone, B.cobblestone, B.diamond_block, B.white_wool, B.gold_block])
                        world.setBlock(x, y, z, Int(cell(block)), SET_NO_NEIGHBORS)
                    }
                }
            }
        }
        return (world, SeededScene(template: template, rotated: rotated, rotation: rotation,
                                   origin: origin, prepareTerrain: prepareTerrain))
    }

    private func makeJob(_ scene: SeededScene, in world: World) throws -> ObjectTemplatePlacementJob {
        try ObjectTemplatePlacementJob(rawTemplate: scene.template, in: world,
                                       targetX: scene.target.x, targetY: scene.target.y, targetZ: scene.target.z,
                                       rotationSteps: scene.rotation, options: scene.options)
    }

    /// Metamorphic: with nothing changing in between, the tick-sliced job must leave exactly the
    /// world the synchronous `placeObjectTemplate` leaves, report the same result, and settle
    /// to exactly the snapshot `objectTemplatePlacementUndoSnapshot` takes up front, at every
    /// step budget; and place-then-undo must be the identity on both paths. Along the way the
    /// job's progress never runs backwards, its phases come in order, and it takes exactly
    /// `operations / budget + 1` steps (the last one only notices it is done).
    func testSlicedPlacementMatchesTheSynchronousPlacementForSeededScenesAtEveryBudget() throws {
        let phases = ["clearing", "supporting", "placing blocks", "placing block entities", "updating neighbors", "done"]
        var rotations = Set<Int>(), crossedBothBorders = 0, cleared = 0, filled = 0, entities = 0, unprepared = 0
        for seed in UInt64(1)...24 {
            let prepare = seed % 4 != 0
            let (oracleWorld, scene) = try makeSeededScene(seed: seed, prepareTerrain: prepare)
            let pristine = regionState(oracleWorld, scene)
            let oracleUndo = try objectTemplatePlacementUndoSnapshot(
                for: scene.template, in: oracleWorld, targetX: scene.target.x, targetY: scene.target.y, targetZ: scene.target.z,
                rotationSteps: scene.rotation, options: scene.options)
            let oracle = try placeObjectTemplate(
                scene.template, in: oracleWorld, targetX: scene.target.x, targetY: scene.target.y, targetZ: scene.target.z,
                rotationSteps: scene.rotation, options: scene.options)
            let placed = regionState(oracleWorld, scene)
            XCTAssertEqual(restoreObjectTemplatePlacementUndo(oracleUndo, in: oracleWorld), oracleUndo.cells.count)
            XCTAssertEqual(regionState(oracleWorld, scene), pristine, "seed \(seed): synchronous place then undo")

            let positions = oracleUndo.cells.map { TemplatePos(x: $0.x, y: $0.y, z: $0.z) }
            XCTAssertTrue(zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 },
                          "seed \(seed): undo cells must be strictly ascending in (y, z, x), as the ledger's search requires")
            let clearance = prepare ? oracleUndo.cells.filter { $0.y >= scene.origin.y && $0.cell != 0 }.count : 0
            let support = prepare ? oracleUndo.cells.filter { $0.y < scene.origin.y }.count : 0
            let operations = clearance + support + scene.rotated.blocks.count + scene.rotated.blockEntities.count + positions.count

            rotations.insert(scene.rotation)
            if positions.contains(where: { $0.x < 0 }) && positions.contains(where: { $0.x >= 0 })
                && positions.contains(where: { $0.z < 0 }) && positions.contains(where: { $0.z >= 0 }) {
                crossedBothBorders += 1
            }
            cleared += oracle.blocksCleared
            filled += oracle.supportBlocksFilled
            entities += oracle.blockEntitiesPlaced
            if !prepare { unprepared += 1 }

            // One rebuilt world serves every budget: each run ends with an undo that is asserted
            // to restore the region exactly, and each run starts by asserting it is pristine.
            let (world, _) = try makeSeededScene(seed: seed, prepareTerrain: prepare)
            for budget in [1, 2, 3, 5, 8, 13, 10_000] {
                let label = "seed \(seed) budget \(budget)"
                XCTAssertEqual(regionState(world, scene), pristine, "\(label): the world must start pristine")
                let job = try makeJob(scene, in: world)
                XCTAssertTrue(job.undoSnapshot.cells.isEmpty, "\(label): nothing is recorded before the job takes a cell")
                XCTAssertEqual(job.progress.totalOperations, operations, label)

                // Per-step invariants are checked with plain comparisons (a few hundred steps per
                // run would otherwise mean ~10^5 XCTest assertions); the first violation is reported.
                var steps = 0, lastCompleted = 0, lastPhase = 0
                var violation: String?
                while true {
                    let done = job.step(maxOperations: budget)
                    steps += 1
                    let progress = job.progress
                    let phase = phases.firstIndex(of: progress.phase) ?? -1
                    let advanced = progress.completedOperations - lastCompleted
                    if violation == nil {
                        if phase < lastPhase { violation = "phase \(progress.phase) after \(phases[lastPhase])" }
                        else if advanced < 0 || advanced > budget { violation = "progress moved by \(advanced)" }
                        else if done != (phase == phases.count - 1) { violation = "done \(done) in phase \(progress.phase)" }
                    }
                    lastCompleted = progress.completedOperations
                    lastPhase = max(phase, 0)
                    if done { break }
                    guard steps <= operations + 1 else { return XCTFail("\(label): the job did not converge") }
                }
                XCTAssertNil(violation, "\(label) at step \(steps)")
                XCTAssertEqual(steps, operations / budget + 1, "\(label): \(operations) operations")
                XCTAssertEqual(job.progress.percent, 100, label)
                XCTAssertTrue(job.step(maxOperations: budget), "\(label): a finished job stays finished")

                let result = try XCTUnwrap(job.result, label)
                XCTAssertEqual([result.originX, result.originY, result.originZ, result.blocksPlaced, result.blockEntitiesPlaced,
                                result.blocksCleared, result.supportBlocksFilled],
                               [oracle.originX, oracle.originY, oracle.originZ, oracle.blocksPlaced, oracle.blockEntitiesPlaced,
                                oracle.blocksCleared, oracle.supportBlocksFilled], label)
                XCTAssertEqual(regionState(world, scene), placed, "\(label): sliced and synchronous worlds differ")
                XCTAssertEqual(job.undoSnapshot.cells.map(signature), oracleUndo.cells.map(signature),
                               "\(label): nothing changed in flight, so the job's record is the up-front reading")
                XCTAssertEqual(restoreObjectTemplatePlacementUndo(job.undoSnapshot, in: world), positions.count, label)
                XCTAssertEqual(regionState(world, scene), pristine, "\(label): sliced place then undo")
            }
        }
        XCTAssertEqual(rotations, [0, 1, 2, 3], "every rotation is exercised")
        XCTAssertGreaterThan(crossedBothBorders, 0, "some placement straddles both chunk borders")
        XCTAssertGreaterThan(cleared, 0)
        XCTAssertGreaterThan(filled, 0)
        XCTAssertGreaterThan(entities, 0)
        XCTAssertGreaterThan(unprepared, 0)
    }

    /// Property: whatever a player does inside the footprint while the job runs, undo gives
    /// back each cell exactly as the job first found it. Before every step, seeded edits hit
    /// cells the job has not reached yet (each cell at most once): a block is mined, a container
    /// is emptied, or something is built in an empty cell. The model is simple because every
    /// first touch changes a cell (see `makeSeededScene`): a cell still reading as it did at
    /// admission is unreached, and the edit made there is what undo must return. After the job,
    /// no block entity may remain under anything it wrote, except the template's own.
    func testUndoGivesBackEachCellAsTheJobFirstFoundItUnderSeededMidFlightEdits() throws {
        var mined = 0, emptied = 0, built = 0
        for seed in UInt64(101)...160 {
            var rng = TemplateSceneGenerator(seed: seed &* 7_919)
            let (world, scene) = try makeSeededScene(seed: seed, prepareTerrain: seed % 5 != 0)
            let job = try makeJob(scene, in: world)
            let footprint = try objectTemplatePlacementUndoSnapshot(
                for: scene.template, in: world, targetX: scene.target.x, targetY: scene.target.y, targetZ: scene.target.z,
                rotationSteps: scene.rotation, options: scene.options)
            let positions = footprint.cells.map { TemplatePos(x: $0.x, y: $0.y, z: $0.z) }
            var admitted: [TemplatePos: String] = [:]
            for p in positions { admitted[p] = state(world, p) }
            var expected = admitted
            var edited = Set<TemplatePos>()
            let budget = rng.pick([1, 2, 3, 4, 7])
            let label = "seed \(seed) budget \(budget)"

            var steps = 0
            repeat {
                for _ in 0..<rng.int(3) {
                    let p = rng.pick(positions)
                    guard !edited.contains(p), state(world, p) == admitted[p] else { continue }
                    edited.insert(p)
                    if world.getBlock(p.x, p.y, p.z) == 0 {
                        if rng.int(2) == 0 {
                            world.setBlock(p.x, p.y, p.z, Int(cell(B.gold_block)))
                        } else {
                            putContainer(world, p, furnace: false, &rng)
                        }
                        built += 1
                    } else if let be = world.getBlockEntity(p.x, p.y, p.z), rng.int(2) == 0 {
                        be.items = be.items.map { [ItemStack?](repeating: nil, count: $0.count) }
                        emptied += 1
                    } else {
                        world.setBlock(p.x, p.y, p.z, 0)
                        mined += 1
                    }
                    expected[p] = state(world, p)
                }
                steps += 1
                guard steps < 100_000 else { return XCTFail("\(label): the job did not converge") }
            } while !job.step(maxOperations: budget)

            let ownEntities = Set(scene.rotated.blockEntities.map {
                TemplatePos(x: scene.origin.x + $0.x, y: scene.origin.y + $0.y, z: scene.origin.z + $0.z)
            })
            for p in positions where !ownEntities.contains(p) {
                XCTAssertNil(world.getBlockEntity(p.x, p.y, p.z), "\(label): a block entity stayed hidden at \(p.x),\(p.y),\(p.z)")
            }
            _ = restoreObjectTemplatePlacementUndo(job.undoSnapshot, in: world)
            for p in positions {
                XCTAssertEqual(state(world, p), expected[p],
                               "\(label) at \(p.x),\(p.y),\(p.z): admitted \(admitted[p] ?? "?"), edited \(edited.contains(p))")
            }
        }
        XCTAssertGreaterThan(mined, 20)
        XCTAssertGreaterThan(emptied, 10)
        XCTAssertGreaterThan(built, 20)
    }
}

/// Fixed-seed SplitMix64, as in `ScriptUsabilityDeepTests`: a failure replays from the seed
/// named in its message.
private struct TemplateSceneGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ upperExclusive: Int) -> Int { Int(next() % UInt64(upperExclusive)) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
}
