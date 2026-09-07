import XCTest
@testable import ElysiumCore

/// Players must come to rest on dry, open ground (never on a lake or a canopy), and land
/// animals must not wander into or across water.
final class SpawnGroundingAndWaterAvoidanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
    }

    /// One lit chunk: grass at y63, a pond at x 3...5 / z 3...5, and an oak at (10, 10) whose
    /// canopy also covers (9...11, 9...11) at y 67...68.
    private func makeFixtureWorld() -> World {
        let world = World(dim: .overworld, seed: 4242)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.status = .lit
        for z in 0..<16 {
            for x in 0..<16 {
                chunk.set(x, 62, z, cell(B.stone))
                chunk.set(x, 63, z, cell(B.grass_block))
            }
        }
        for z in 3...5 {
            for x in 3...5 {
                chunk.set(x, 63, z, cell(B.water))
            }
        }
        for y in 64...66 { chunk.set(10, y, 10, cell(B.oak_log)) }
        for z in 9...11 {
            for x in 9...11 {
                for y in 67...68 { chunk.set(x, y, z, cell(B.oak_leaves)) }
            }
        }
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        return world
    }

    func testDryGroundRejectsWaterAndTreesAndAcceptsOpenGrass() {
        let world = makeFixtureWorld()
        XCTAssertEqual(world.dryGroundY(1, 1), 64)
        XCTAssertNil(world.dryGroundY(4, 4), "a pond is not a spawn")
        XCTAssertNil(world.dryGroundY(10, 10), "a canopy over a trunk is not a spawn")
        XCTAssertNil(world.dryGroundY(9, 9), "a canopy is not a spawn")
        XCTAssertNil(world.dryGroundY(40, 40), "unloaded columns never qualify")
        // The old surface lookup landed in the pond bed and on top of the leaves.
        XCTAssertEqual(world.surfaceY(4, 4), 63)
        XCTAssertEqual(world.surfaceY(10, 10), 69)
    }

    func testGroundedSpawnColumnWalksOutwardToTheNearestDryGround() throws {
        let world = makeFixtureWorld()
        let fromPond = try XCTUnwrap(world.groundedSpawnColumn(near: 4, 4))
        XCTAssertEqual(fromPond.y, 64)
        XCTAssertEqual(max(abs(fromPond.x - 4), abs(fromPond.z - 4)), 2, "first ring past the pond")
        XCTAssertNotNil(world.dryGroundY(fromPond.x, fromPond.z))
        let fromTree = try XCTUnwrap(world.groundedSpawnColumn(near: 10, 10))
        XCTAssertEqual(fromTree.y, 64)
        XCTAssertEqual(max(abs(fromTree.x - 10), abs(fromTree.z - 10)), 2, "first ring past the canopy")
        let onGrass = try XCTUnwrap(world.groundedSpawnColumn(near: 1, 1))
        XCTAssertEqual(onGrass.x, 1)
        XCTAssertEqual(onGrass.z, 1)
        XCTAssertEqual(onGrass.y, 64)
        // Deterministic: the same world always answers the same column.
        let again = try XCTUnwrap(world.groundedSpawnColumn(near: 4, 4))
        XCTAssertEqual(again.x, fromPond.x)
        XCTAssertEqual(again.z, fromPond.z)
        XCTAssertNil(world.groundedSpawnColumn(near: 200, 200, radius: 4), "nothing loaded there")
    }

    func testLandAnimalsRefuseWaterWhileSwimmersDoNot() {
        let world = makeFixtureWorld()
        for animal in [Cow(world: world), Pig(world: world), Sheep(world: world), Chicken(world: world),
                       Wolf(world: world), Horse(world: world), Goat(world: world), PolarBear(world: world)] as [Mob] {
            XCTAssertTrue(animal.nav.avoidWater, "\(animal.type) should stay out of water")
        }
        for swimmer in [Turtle(world: world), Frog(world: world), Axolotl(world: world),
                        Dolphin(world: world), Squid(world: world)] as [Mob] {
            XCTAssertFalse(swimmer.nav.avoidWater, "\(swimmer.type) lives in water")
        }
        // Water is neither a stroll target nor a path node for an avoiding navigator...
        XCTAssertFalse(walkable(world, 4, 64, 4, true), "standing on the pond surface")
        XCTAssertFalse(walkable(world, 4, 63, 4, true), "wading in the pond")
        XCTAssertTrue(walkable(world, 1, 64, 1, true))
        // ...but remains reachable for swimmers.
        XCTAssertTrue(walkable(world, 4, 63, 4, false))
        // A path that must cross the pond goes around it, never through it.
        let path = findPath(world, 4.5, 64, 1.5, 4.5, 64, 7.5, 600, true)
        XCTAssertNotNil(path)
        for node in path ?? [] {
            XCTAssertFalse((3...5).contains(node.x) && (3...5).contains(node.z),
                           "path node (\(node.x), \(node.z)) crosses the pond")
        }
    }
}
