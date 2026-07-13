import XCTest
@testable import ElysiumCore

final class InteractPersistenceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    func testBedSpawnUseRequestsPlayerStatePersistence() {
        let world = makeLoadedWorld(dim: .overworld)
        let player = Player(world: world)
        _ = world.setBlock(2, 64, 2, Int(cell(B.red_bed, 0)))
        var persistCount = 0

        XCTAssertTrue(useBlock(
            InteractCtx(
                world: world,
                player: player,
                persistPlayerState: { persistCount += 1 }
            ),
            RaycastHit(
                x: 2,
                y: 64,
                z: 2,
                face: Dir.up,
                cell: world.getBlock(2, 64, 2),
                t: 1,
                px: 2.5,
                py: 65,
                pz: 2.5
            )
        ))

        XCTAssertEqual(player.spawnPoint?.0, 2)
        XCTAssertEqual(player.spawnPoint?.1, 64)
        XCTAssertEqual(player.spawnPoint?.2, 2)
        XCTAssertEqual(player.spawnDim, Dim.overworld.rawValue)
        XCTAssertEqual(persistCount, 1)
    }

    func testRespawnAnchorSpawnUseRequestsPlayerStatePersistence() {
        let world = makeLoadedWorld(dim: .nether)
        let player = Player(world: world)
        _ = world.setBlock(3, 64, 2, Int(cell(B.respawn_anchor, 1)))
        var persistCount = 0

        XCTAssertTrue(useBlock(
            InteractCtx(
                world: world,
                player: player,
                persistPlayerState: { persistCount += 1 }
            ),
            RaycastHit(
                x: 3,
                y: 64,
                z: 2,
                face: Dir.up,
                cell: world.getBlock(3, 64, 2),
                t: 1,
                px: 3.5,
                py: 65,
                pz: 2.5
            )
        ))

        XCTAssertEqual(player.spawnPoint?.0, 3)
        XCTAssertEqual(player.spawnPoint?.1, 65)
        XCTAssertEqual(player.spawnPoint?.2, 2)
        XCTAssertEqual(player.spawnDim, Dim.nether.rawValue)
        XCTAssertEqual(persistCount, 1)
    }

    private func makeLoadedWorld(dim: Dim) -> World {
        let world = World(dim: dim, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }
}
