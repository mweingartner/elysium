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

    func testWholeAnimalCannotDriftOrCutDiagonallyIntoPond() {
        let world = makeFixtureWorld()
        for animal in [Cow(world: world), Sheep(world: world), Goat(world: world), Horse(world: world)] as [Animal] {
            animal.x = 4.5; animal.y = 64; animal.z = 2.0
            animal.onGround = true
            animal.move(0, -0.08, 0.7)
            XCTAssertEqual(animal.z, 2.0, "\(animal.type) must stop before its body overlaps the pond")
            XCTAssertFalse(animal.touchesWater(atX: animal.x, y: animal.y, z: animal.z, below: 0.5))
            animal.x = 2; animal.z = 2
            animal.move(1.2, 0, 1.2)
            XCTAssertEqual(animal.x, 2)
            XCTAssertEqual(animal.z, 2)
        }
        let cow = Cow(world: world)
        cow.x = 1.5; cow.y = 64; cow.z = 1.5
        cow.move(0.4, -0.08, 0.4)
        XCTAssertEqual(cow.x, 1.9, accuracy: 0.0001, "ordinary dry grazing is unchanged")
    }

    func testAnimalsActuallySwimOutAndResumeDryGrazing() {
        let world = makeFixtureWorld()
        for animal in [Cow(world: world), Sheep(world: world), Goat(world: world), Horse(world: world),
                       Pig(world: world), Chicken(world: world), Wolf(world: world)] as [Animal] {
            animal.x = 4.5; animal.y = 63; animal.z = 4.5
            animal.rng = RandomX(42)
            animal.persistent = true
            animal.lookX = 4.5; animal.lookY = 64; animal.lookZ = 12
            // Exercise complete goal selection, navigation, buoyancy and collision, not just flags.
            var escaped = false
            for _ in 0..<300 {
                animal.tick()
                if !animal.touchesWater(atX: animal.x, y: animal.y, z: animal.z, below: 0.5), animal.onGround {
                    escaped = true
                    break
                }
            }
            XCTAssertTrue(escaped, "\(animal.type) stayed in water at \(animal.x),\(animal.y),\(animal.z)")
            for _ in 0..<150 { animal.tick() }
            XCTAssertFalse(animal.inWater, "\(animal.type) returned to the pond")
        }
    }

    func testEscapeFindsReachableShoreAndHandlesDeepWater() throws {
        let world = makeFixtureWorld()
        for z in 3...5 { for x in 3...5 {
            for y in 58...62 { world.setBlock(x, y, z, Int(cell(B.water))) }
        } }
        // Block the first (+X) exit. The ordered search must find another bank.
        for z in 2...6 { for y in 63...67 { world.setBlock(6, y, z, Int(cell(B.stone))) } }
        let sheep = Sheep(world: world)
        sheep.x = 4.5; sheep.y = 59; sheep.z = 4.5
        sheep.rng = RandomX(9)
        let goal = LeaveWaterGoal(sheep, -1)
        let path = try XCTUnwrap(goal.pathToShore())
        XCTAssertFalse(path.contains { $0.x == 6 })
        let end = try XCTUnwrap(path.last)
        XCTAssertTrue(walkable(world, end.x, end.y, end.z, true))
        for _ in 0..<400 { sheep.tick() }
        XCTAssertFalse(sheep.inWater)
        XCTAssertGreaterThanOrEqual(sheep.y, 64)
    }

    func testNoReachableShoreIsBoundedAndAnimalKeepsFloating() {
        let world = makeFixtureWorld()
        for z in 0..<16 { for x in 0..<16 { world.setBlock(x, 63, z, Int(cell(B.water))) } }
        let cow = Cow(world: world)
        cow.x = 8.5; cow.y = 63; cow.z = 8.5
        let goal = LeaveWaterGoal(cow, -1)
        XCTAssertNil(goal.pathToShore(maxNodes: 32))
        for _ in 0..<100 { cow.tick() }
        XCTAssertGreaterThan(cow.y, 63, "no land in loaded chunks: float and retry instead of sinking")
        XCTAssertTrue(cow.x.isFinite && cow.y.isFinite && cow.z.isFinite)
    }

    func testBatsLiftOutOfWaterAndDoNotDiveBackIn() {
        let world = makeFixtureWorld()
        let bat = Bat(world: world)
        bat.x = 4.5; bat.y = 63; bat.z = 4.5
        bat.hanging = true
        bat.persistent = true
        bat.rng = RandomX(12)
        for _ in 0..<12 { bat.tick() }
        XCTAssertFalse(bat.inWater)
        XCTAssertFalse(bat.hanging)
        XCTAssertGreaterThan(bat.y, 64)
        bat.x = 4.5; bat.y = 64.4; bat.z = 4.5
        bat.vx = 0; bat.vz = 0; bat.vy = -0.2
        for _ in 0..<100 {
            bat.tick()
            XCTAssertFalse(bat.touchesWater(atX: bat.x, y: bat.y, z: bat.z))
        }
    }

    func testAquaticAnimalsAndRiddenHorsesCanStillEnterWater() {
        let world = makeFixtureWorld()
        for swimmer in [Turtle(world: world), Frog(world: world), Axolotl(world: world)] as [Animal] {
            swimmer.x = 4.5; swimmer.y = 64; swimmer.z = 2
            swimmer.move(0, 0, 1)
            XCTAssertEqual(swimmer.z, 3)
            XCTAssertFalse(LeaveWaterGoal(swimmer, -1).canUse())
        }
        let horse = Horse(world: world)
        horse.x = 4.5; horse.y = 64; horse.z = 2
        let rider = Player(world: world)
        rider.mount(horse)
        horse.move(0, 0, 1)
        XCTAssertEqual(horse.z, 3)
    }

    func testGrazingStaysDryAcrossSeededTurnsAndWideFootprints() {
        let world = makeFixtureWorld()
        for seed in 0..<6 {
            for animal in [Sheep(world: world), Horse(world: world)] as [Animal] {
                animal.x = 4.5; animal.y = 64; animal.z = 1.5
                animal.rng = RandomX(UInt32(seed))
                animal.goals = GoalSelector()
                animal.goals.add(StrollGoal(animal, 6, 1, 1))
                for tick in 0..<600 {
                    animal.tick()
                    XCTAssertFalse(animal.inWater, "\(animal.type) seed \(seed) entered water at tick \(tick)")
                }
            }
        }
    }
}
