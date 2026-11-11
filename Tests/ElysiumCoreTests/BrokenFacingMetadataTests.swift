import XCTest
@testable import ElysiumCore

/// A lever, a button and a redstone torch keep the face they hang on in their metadata. Three
/// or four bits can name eight or sixteen faces and a block has six, so a cell that was pasted,
/// imported or sent by a LAN guest can name a face that does not exist. Clicking or ticking
/// such a block read past the end of the direction tables and stopped the game.
final class BrokenFacingMetadataTests: XCTestCase {
    private func makeFixture() -> (World, Player) {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
        let world = World(dim: .overworld, seed: 0xFACE)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.status = .lit
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        for x in 0..<16 { for z in 0..<16 { world.setBlock(x, 63, z, Int(cell(B.stone)), SET_SILENT) } }
        let player = Player(world: world)
        player.setPos(8.5, 64, 6.5)
        world.addEntity(player)
        return (world, player)
    }

    private func use(_ world: World, _ player: Player, _ x: Int, _ y: Int, _ z: Int) -> Bool {
        let hit = RaycastHit(x: x, y: y, z: z, face: 1, cell: world.getBlock(x, y, z), t: 1,
                             px: Double(x) + 0.5, py: Double(y) + 1, pz: Double(z) + 0.5)
        return useBlock(InteractCtx(world: world, player: player), hit)
    }

    func testAStepTowardADirectionThatDoesNotExistIsNoStep() {
        for dir in 0..<6 {
            let step = dirStep(dir)
            XCTAssertEqual([step.x, step.y, step.z], [DIR_X[dir], DIR_Y[dir], DIR_Z[dir]])
        }
        for dir in [-1, 6, 7, 15, 1_000, Int.min, Int.max] {
            let step = dirStep(dir)
            XCTAssertEqual([step.x, step.y, step.z], [0, 0, 0], "direction \(dir)")
        }
    }

    func testALeverWithAnyMetadataCanBeFlipped() {
        let (world, player) = makeFixture()
        for meta in 0..<16 {
            world.setBlock(8, 64, 8, Int(cell(B.lever, meta)), SET_SILENT)
            XCTAssertTrue(use(world, player, 8, 64, 8), "metadata \(meta)")
            XCTAssertEqual(world.getBlock(8, 64, 8), Int(cell(B.lever, meta ^ 8)), "metadata \(meta)")
        }
    }

    func testAButtonWithAnyMetadataCanBePressedAndSpringsBack() throws {
        let (world, player) = makeFixture()
        var buttons = 0
        for id in 1..<blockDefs.count where blockDefs[id].shape == .button {
            let release = try XCTUnwrap(blockTickHandlers[id], "\(blockDefs[id].name) has no tick")
            for meta in 0..<16 {
                world.setBlock(8, 64, 8, Int(cell(UInt16(id), meta)), SET_SILENT)
                XCTAssertTrue(use(world, player, 8, 64, 8), "\(blockDefs[id].name) metadata \(meta)")
                XCTAssertEqual(world.getBlock(8, 64, 8), Int(cell(UInt16(id), meta | 8)))
                release(world, 8, 64, 8, world.getBlock(8, 64, 8))
                XCTAssertEqual(world.getBlock(8, 64, 8), Int(cell(UInt16(id), meta & 7)))
            }
            buttons += 1
        }
        XCTAssertGreaterThan(buttons, 5)
    }

    // MARK: - Pistons, dispensers, droppers, hoppers and observers facing a seventh way

    /// Every cell from x-1...x+1, y-1...y+1, z-1...z+1, to tell "did nothing" from "did something".
    private func around(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> [Int] {
        var cells: [Int] = []
        for dx in -1...1 { for dy in -1...1 { for dz in -1...1 { cells.append(world.getBlock(x + dx, y + dy, z + dz)) } } }
        return cells
    }

    /// A powered piston with a facing of 6 or 7, extended or not, moves nothing and makes no
    /// head. The same piston facing north does extend, so the power reaches it.
    func testAPoweredPistonFacingNoRealWayDoesNothing() throws {
        for piston in [B.piston, B.sticky_piston] {
            let tick = try XCTUnwrap(blockTickHandlers[Int(piston)])
            for meta in [6, 7, 6 | 8, 7 | 8] {
                let (world, _) = makeFixture()
                world.setBlock(8, 64, 8, Int(cell(piston, meta)), SET_SILENT)
                world.setBlock(9, 64, 8, Int(cell(B.redstone_block)), SET_SILENT)   // power from the east
                world.setBlock(8, 64, 7, Int(cell(B.cobblestone)), SET_SILENT)     // something to push
                world.setBlock(8, 65, 8, Int(cell(B.cobblestone)), SET_SILENT)
                let before = around(world, 8, 64, 8)
                tick(world, 8, 64, 8, world.getBlock(8, 64, 8))
                XCTAssertEqual(around(world, 8, 64, 8), before, "\(blockDefs[Int(piston)].name) metadata \(meta)")
            }
            // The control: facing north (2), the same power extends it and pushes the cobblestone.
            let (world, _) = makeFixture()
            world.setBlock(8, 64, 8, Int(cell(piston, 2)), SET_SILENT)
            world.setBlock(9, 64, 8, Int(cell(B.redstone_block)), SET_SILENT)
            world.setBlock(8, 64, 7, Int(cell(B.cobblestone)), SET_SILENT)
            tick(world, 8, 64, 8, world.getBlock(8, 64, 8))
            XCTAssertEqual(world.getBlock(8, 64, 8), Int(cell(piston, 2 | 8)), "the control extends")
            XCTAssertEqual(world.getBlockId(8, 64, 7), Int(B.piston_head))
            XCTAssertEqual(world.getBlockId(8, 64, 6), Int(B.cobblestone))
        }
    }

    /// A dispenser or dropper with a facing of 6 or 7 keeps what it holds and throws nothing.
    /// Facing north, the same block does throw.
    func testADispenserOrDropperFacingNoRealWayKeepsItsItems() throws {
        for block in [B.dispenser, B.dropper] {
            let fire = try XCTUnwrap(blockTickHandlers[Int(block)])
            for meta in [2, 6, 7, 6 | 8, 7 | 8] {
                let (world, _) = makeFixture()
                world.setBlock(8, 64, 8, Int(cell(block, meta)), SET_SILENT)
                let contents = try XCTUnwrap(placementBlockEntity(Int(block), 8, 64, 8))
                contents.items?[0] = stack("cobblestone", 4)
                world.setBlockEntity(contents)
                let entitiesBefore = world.entities.count
                fire(world, 8, 64, 8, world.getBlock(8, 64, 8))
                let left = world.getBlockEntity(8, 64, 8)?.items?.compactMap { $0 }.reduce(0) { $0 + $1.count }
                let name = "\(blockDefs[Int(block)].name) metadata \(meta)"
                if meta == 2 {
                    XCTAssertEqual(left, 3, "\(name): the control throws one")
                    XCTAssertGreaterThan(world.entities.count, entitiesBefore, name)
                } else {
                    XCTAssertEqual(left, 4, name)
                    XCTAssertEqual(world.entities.count, entitiesBefore, name)
                }
            }
        }
    }

    /// A hopper with a facing of 6 or 7 neither pushes nor pulls. Facing down (0), the same
    /// hopper under the same chest pulls one item.
    func testAHopperFacingNoRealWayMovesNothing() throws {
        let tick = try XCTUnwrap(beTickHandlers["hopper"])
        for meta in [0, 6, 7] {
            let (world, _) = makeFixture()
            world.setBlock(8, 64, 8, Int(cell(B.hopper, meta)), SET_SILENT)
            let hopper = try XCTUnwrap(placementBlockEntity(Int(B.hopper), 8, 64, 8))
            world.setBlockEntity(hopper)
            world.setBlock(8, 65, 8, Int(cell(B.chest, 2)), SET_SILENT)
            let chest = makeContainerBE(8, 65, 8, 27)
            chest.items?[0] = stack("cobblestone", 5)
            world.setBlockEntity(chest)
            tick(world, hopper)
            let inChest = world.getBlockEntity(8, 65, 8)?.items?.compactMap { $0 }.reduce(0) { $0 + $1.count }
            let inHopper = hopper.items?.compactMap { $0 }.reduce(0) { $0 + $1.count } ?? 0
            XCTAssertEqual(inChest, meta == 0 ? 4 : 5, "metadata \(meta)")
            XCTAssertEqual(inHopper, meta == 0 ? 1 : 0, "metadata \(meta)")
        }
    }

    /// An observer with a facing of 6 or 7 watches nothing: a change on any side schedules no
    /// pulse. An observer of each real facing reacts to its watched side only.
    func testAnObserverFacingNoRealWayWatchesNothing() throws {
        let heard = try XCTUnwrap(neighborHandlers[Int(B.observer)])
        for meta in 0..<8 {
            for side in 0..<6 {
                let (world, _) = makeFixture()
                world.setBlock(8, 64, 8, Int(cell(B.observer, meta)), SET_SILENT)
                heard(world, 8, 64, 8, world.getBlock(8, 64, 8), 8 + DIR_X[side], 64 + DIR_Y[side], 8 + DIR_Z[side])
                XCTAssertEqual(world.hasScheduledTick(8, 64, 8, Int(B.observer)), meta < 6 && side == meta,
                               "observer metadata \(meta), change on side \(side)")
            }
        }
    }

    func testARedstoneTorchWithAnyMetadataTicks() throws {
        let (world, _) = makeFixture()
        for torch in [B.redstone_torch, B.redstone_torch_off] {
            let tick = try XCTUnwrap(blockTickHandlers[Int(torch)])
            for meta in 0..<16 {
                world.setBlock(8, 64, 8, Int(cell(torch, meta)), SET_SILENT)
                tick(world, 8, 64, 8, world.getBlock(8, 64, 8))
                let id = world.getBlockId(8, 64, 8)
                XCTAssertTrue(id == Int(B.redstone_torch) || id == Int(B.redstone_torch_off), "metadata \(meta)")
            }
        }
    }
}
