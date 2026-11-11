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
