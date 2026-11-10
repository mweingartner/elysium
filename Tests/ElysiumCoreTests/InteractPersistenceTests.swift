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

    /// Ejecting and breaking a jukebox that holds a disc both tell the host to stop the music
    /// (`jukebox.stop`); breaking an empty jukebox does not. The disc drops either way.
    func testJukeboxEjectAndBreakBothEmitJukeboxStop() {
        let world = makeLoadedWorld(dim: .overworld)
        let player = Player(world: world)
        var sounds: [String] = []
        world.hooks.playSound = { name, _, _, _, _, _ in sounds.append(name) }
        func jukebox(at x: Int, disc: Bool) {
            _ = world.setBlock(x, 64, 2, Int(cell(B.jukebox)))
            let be = BlockEntityData(type: "jukebox", x: x, y: 64, z: 2)
            if disc { be.disc = stack("music_disc_aurora") }
            world.setBlockEntity(be)
        }

        jukebox(at: 2, disc: true)
        let hit = RaycastHit(x: 2, y: 64, z: 2, face: Dir.up, cell: world.getBlock(2, 64, 2),
                             t: 1, px: 2.5, py: 65, pz: 2.5)
        XCTAssertTrue(useBlock(InteractCtx(world: world, player: player), hit))
        XCTAssertEqual(sounds.filter { $0 == "jukebox.stop" }.count, 1, "eject")

        jukebox(at: 5, disc: true)
        finishBreaking(InteractCtx(world: world, player: player), 5, 64, 2)
        XCTAssertEqual(world.getBlock(5, 64, 2), 0)
        XCTAssertEqual(sounds.filter { $0 == "jukebox.stop" }.count, 2, "breaking a playing jukebox")

        jukebox(at: 8, disc: false)
        finishBreaking(InteractCtx(world: world, player: player), 8, 64, 2)
        XCTAssertEqual(sounds.filter { $0 == "jukebox.stop" }.count, 2, "an empty jukebox has nothing to stop")
    }

    private func makeLoadedWorld(dim: Dim) -> World {
        let world = World(dim: dim, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }
}
