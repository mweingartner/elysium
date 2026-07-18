import XCTest
@testable import ElysiumCore

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

    func testHuskBurnsInDirectSunlightLikeEveryNonCreeperMonster() throws {
        let world = makeOverworld()
        world.dayTime = 1_000
        world.gameRules["doDaylightCycle"] = 0
        let husk = try XCTUnwrap(spawnMob(world, "husk", 0.5, 64, 0.5, SpawnOpts()) as? Husk)
        husk.persistent = true
        husk.baby = false

        tick(world, count: 240)

        XCTAssertGreaterThan(husk.fireTicks, 0)
        XCTAssertLessThan(husk.health, husk.maxHealth)
        XCTAssertFalse(husk.dead)
    }

    func testEveryRegisteredMonsterUsesUniformSunlightReaction() throws {
        // Keep this inventory explicit so adding a hostile factory requires a
        // deliberate sunlight classification update rather than silently
        // inheriting whichever registry snapshot a concurrent test observes.
        let registered = [
            "zombie", "husk", "drowned", "zombie_villager",
            "skeleton", "stray", "creeper", "spider", "cave_spider",
            "slime", "witch", "enderman", "silverfish", "endermite",
            "phantom", "guardian", "elder_guardian", "shulker",
            "pillager", "vindicator", "evoker", "vex", "ravager",
            "blaze", "ghast", "magma_cube", "zombified_piglin",
            "piglin", "piglin_brute", "hoglin", "zoglin",
            "wither_skeleton", "warden", "wither",
        ]
        var checked: [String] = []
        for type in registered {
            let world = makeOverworld()
            world.gameRules["doDaylightCycle"] = 0
            guard let monster = createEntity(type, world) as? Monster else { continue }
            monster.setPos(0.5, 64, 0.5)
            monster.persistent = true
            monster.tickSunlightBurning()
            checked.append(type)
            if let creeper = monster as? Creeper {
                XCTAssertNotNil(creeper.fuse, "creeper should start its rapid sunlight fuse")
                XCTAssertEqual(creeper.fuse?.trigger, .sunlight)
                XCTAssertEqual(creeper.fireTicks, 0)
            } else {
                XCTAssertGreaterThan(monster.fireTicks, 0, "\(type) should ignite")
            }
        }
        XCTAssertGreaterThan(checked.count, 20, "the registry-wide assertion must cover the hostile catalog")
        XCTAssertTrue(checked.contains("husk"))
        XCTAssertTrue(checked.contains("creeper"))
    }

    func testDaylightIgnitionParticleDensityIsCappedAcrossACrowd() throws {
        let world = makeOverworld()
        var emitted = 0
        world.hooks.addParticles = { name, _, _, _, count, _, _ in
            if name == "flame" { emitted += count }
        }

        for _ in 0..<40 {
            let monster = Zombie(world: world)
            monster.reactToDirectSunlight()
        }

        XCTAssertEqual(emitted, 24)
    }
}
