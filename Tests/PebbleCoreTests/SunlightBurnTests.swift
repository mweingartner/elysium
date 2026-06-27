import XCTest
@testable import PebbleCore

final class SunlightBurnTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    private func makeOverworld(roofY: Int? = nil) -> World {
        registerCoreIfNeeded()

        let world = World(dim: .overworld, seed: 42)
        world.gameRules["doWeatherCycle"] = 0
        world.rainLevel = 0
        world.dayTime = 23_000

        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.set(0, 63, 0, cell(B.stone))
        if let roofY {
            chunk.set(0, roofY, 0, cell(B.stone))
        }
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        return world
    }

    private func tick(_ world: World, count: Int) {
        for _ in 0..<count {
            world.tick()
            for entityRef in Array(world.entities) {
                (entityRef as? Entity)?.tick()
            }
            for entityRef in Array(world.entities) where entityRef.dead {
                world.removeEntity(entityRef)
            }
        }
    }

    func testExposedZombieBurnsToDeathAfterSunrise() throws {
        let world = makeOverworld()
        let zombie = try XCTUnwrap(spawnMob(world, "zombie", 0.5, 64, 0.5, SpawnOpts()) as? Zombie)
        zombie.persistent = true
        zombie.baby = false

        tick(world, count: 2_000)

        XCTAssertTrue(zombie.dead || zombie.deathTime > 0, "exposed zombie should die once daylight arrives")
        XCTAssertFalse(world.entities.contains { $0 === zombie }, "dead zombie should be removed from the world")
    }

    func testExposedZombieIgnitesAtVisibleSunrise() throws {
        let world = makeOverworld()
        world.dayTime = 23_000
        world.gameRules["doDaylightCycle"] = 0
        let zombie = try XCTUnwrap(spawnMob(world, "zombie", 0.5, 64, 0.5, SpawnOpts()) as? Zombie)
        zombie.persistent = true
        zombie.baby = false

        tick(world, count: 1)

        XCTAssertGreaterThan(zombie.fireTicks, 0, "exposed zombie should ignite once direct sunrise light is strong enough")
    }

    func testSunlightBurningMonsterTypesIgniteAtVisibleSunrise() throws {
        for type in ["zombie", "zombie_villager", "skeleton", "stray", "drowned", "phantom"] {
            let world = makeOverworld()
            world.dayTime = 23_000
            world.gameRules["doDaylightCycle"] = 0
            let entity = try XCTUnwrap(spawnMob(world, type, 0.5, 64, 0.5, SpawnOpts()))
            (entity as? Mob)?.persistent = true
            (entity as? Zombie)?.baby = false

            tick(world, count: 1)

            XCTAssertGreaterThan(entity.fireTicks, 0, "\(type) should ignite at visible sunrise")
        }
    }

    func testRoofBlocksZombieSunlightBurn() throws {
        let world = makeOverworld(roofY: 66)
        world.dayTime = 1_000
        world.gameRules["doDaylightCycle"] = 0
        let zombie = try XCTUnwrap(spawnMob(world, "zombie", 0.5, 64, 0.5, SpawnOpts()) as? Zombie)
        zombie.persistent = true
        zombie.baby = false

        tick(world, count: 240)

        XCTAssertEqual(zombie.fireTicks, 0)
        XCTAssertEqual(zombie.health, zombie.maxHealth)
        XCTAssertFalse(zombie.dead)
    }

    func testHuskDoesNotBurnInDirectSunlight() throws {
        let world = makeOverworld()
        world.dayTime = 1_000
        world.gameRules["doDaylightCycle"] = 0
        let husk = try XCTUnwrap(spawnMob(world, "husk", 0.5, 64, 0.5, SpawnOpts()) as? Husk)
        husk.persistent = true
        husk.baby = false

        tick(world, count: 240)

        XCTAssertEqual(husk.fireTicks, 0)
        XCTAssertEqual(husk.health, husk.maxHealth)
        XCTAssertFalse(husk.dead)
    }
}
