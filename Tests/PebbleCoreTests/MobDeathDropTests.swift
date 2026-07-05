import XCTest
@testable import PebbleCore

final class MobDeathDropTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    private func makeLoadedWorld() -> World {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
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

    /// deterministic drop fixture: chance 1, min == max, so `dropLoot` never touches `rng`
    /// for its outcome and every death produces exactly one item stack of 3 coal.
    private final class GuaranteedDropMob: LivingEntity {
        override var type: String { "guaranteed_drop_mob" }
        var dropLootCallCount = 0

        override init(world: World) {
            super.init(world: world)
            width = 0.6
            height = 1.8
            maxHealth = 10
            health = 10
        }

        override func tick() {
            baseLivingTick()
        }

        override func dropLoot(_ looting: Int, _ byPlayer: Bool) {
            dropLootCallCount += 1
            super.dropLoot(looting, byPlayer)
        }

        override func drops() -> [DropEntry] {
            [DropEntry("coal", min: 3, max: 3, chance: 1)]
        }
    }

    /// same fixture but with a nonzero XP reward, for the XP-credit-survives-death-animation test.
    private final class GuaranteedXPMob: LivingEntity {
        override var type: String { "guaranteed_xp_mob" }

        override init(world: World) {
            super.init(world: world)
            width = 0.6
            height = 1.8
            maxHealth = 10
            health = 10
            xpReward = 7
        }

        override func tick() {
            baseLivingTick()
        }

        override func drops() -> [DropEntry] { [] }
    }

    func testDamageDuringDeathAnimationDoesNotDuplicateDrops() {
        let world = makeLoadedWorld()
        let mob = GuaranteedDropMob(world: world)
        mob.setPos(4.5, 65, 4.5)
        mob.persistent = true
        world.addEntity(mob)

        XCTAssertTrue(mob.hurt(mob.maxHealth, "test"))

        tick(world, count: 14)
        XCTAssertFalse(mob.dead)
        XCTAssertGreaterThan(mob.deathTime, 0)
        XCTAssertEqual(mob.invulnTicks, 0)

        // re-damage during the death animation window must not re-enter die()/dropLoot
        XCTAssertFalse(mob.hurt(5, "test"))
        XCTAssertFalse(mob.hurt(5, "test"))

        tick(world, count: 10)

        let items = world.entities.compactMap { $0 as? ItemEntity }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.reduce(0) { $0 + (itemDef($1.stack.id).name == "coal" ? $1.stack.count : 0) }, 3)
    }

    func testLavaCorpseDoesNotLoopLootOrResetDeathTime() {
        let world = makeLoadedWorld()
        let mob = GuaranteedDropMob(world: world)
        mob.setPos(4.5, 65, 4.5)
        mob.persistent = true
        world.addEntity(mob)
        _ = world.setBlock(4, 64, 4, Int(B.lava) << 4)
        _ = world.setBlock(4, 65, 4, Int(B.lava) << 4)

        mob.die("test")
        XCTAssertEqual(mob.deathTime, 1)

        tick(world, count: 40)

        XCTAssertTrue(mob.dead)
        XCTAssertGreaterThanOrEqual(mob.deathTime, 20)
        // the dropped item itself burns up in the lava pool immediately, so assert on the
        // drop-call count (the actual regression surface) rather than the item's survival.
        XCTAssertEqual(mob.dropLootCallCount, 1, "a corpse continuously re-hurt by lava must not re-run dropLoot")
    }

    func testDieIsIdempotent() {
        let world = makeLoadedWorld()
        let mob = GuaranteedDropMob(world: world)
        mob.setPos(4.5, 65, 4.5)
        world.addEntity(mob)

        mob.die("test")
        XCTAssertEqual(mob.deathTime, 1)
        mob.die("test")
        XCTAssertEqual(mob.deathTime, 1, "second die() call must not reset the death animation")

        let items = world.entities.compactMap { $0 as? ItemEntity }
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.reduce(0) { $0 + (itemDef($1.stack.id).name == "coal" ? $1.stack.count : 0) }, 3)
    }

    /// Player.die does not call super.die, so the base LivingEntity guard does not cover it;
    /// this is the security-review-mandated regression test for that exception.
    func testPlayerDieIsIdempotent() {
        let world = makeLoadedWorld()
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        player.inventory[0] = ItemStack(iid("coal"), 5)
        world.addEntity(player)

        player.die("test")
        XCTAssertEqual(player.deathTime, 1)
        XCTAssertEqual(player.health, 0, accuracy: 0.000_001)

        let dropsAfterFirstDeath = world.entities.compactMap { $0 as? ItemEntity }.count
        XCTAssertGreaterThan(dropsAfterFirstDeath, 0)

        player.die("test")
        XCTAssertEqual(player.deathTime, 1, "second die() call must not reset the death animation")
        XCTAssertEqual(world.entities.compactMap { $0 as? ItemEntity }.count, dropsAfterFirstDeath,
                       "second die() must not duplicate the inventory drop")
    }

    func testXPCreditSurvivesDeathAnimation() throws {
        let world = makeLoadedWorld()
        let mob = GuaranteedXPMob(world: world)
        mob.setPos(4.5, 65, 4.5)
        mob.persistent = true
        world.addEntity(mob)

        // far enough away that the player's item-magnet pickup radius (1.6 blocks) can't
        // consume the XP orb once it spawns, while still being the killing attacker.
        let player = Player(world: world)
        player.setPos(30.5, 65, 4.5)
        world.addEntity(player)

        XCTAssertTrue(mob.hurt(mob.maxHealth, "test", player))
        XCTAssertGreaterThan(mob.lastHurtByPlayerTime, 0)

        tick(world, count: 25)

        XCTAssertTrue(mob.dead)
        let orb = try XCTUnwrap(world.entities.compactMap { $0 as? XPOrb }.first)
        XCTAssertGreaterThan(orb.amount, 0)
    }

    func testSlimeDoesNotMultiplyOnReHitDuringDeath() {
        let world = makeLoadedWorld()
        let slime = Slime(world: world)
        slime.setSize(2)
        slime.setPos(4.5, 65, 4.5)
        slime.persistent = true
        world.addEntity(slime)

        XCTAssertTrue(slime.hurt(slime.maxHealth, "test"))
        tick(world, count: 12)
        XCTAssertFalse(slime.dead)
        XCTAssertGreaterThan(slime.deathTime, 0)
        XCTAssertEqual(slime.invulnTicks, 0, "re-hit must land after invulnerability expires")

        // re-damage during the death window must not trigger a second split
        XCTAssertFalse(slime.hurt(5, "test"))
        XCTAssertFalse(slime.hurt(5, "test"))

        tick(world, count: 20)

        let children = world.entities.compactMap { $0 as? Slime }.filter { $0 !== slime }
        XCTAssertGreaterThanOrEqual(children.count, 2)
        XCTAssertLessThanOrEqual(children.count, 3, "a second die() re-entry would double the split batch")
    }

    func testKilledCreeperDoesNotExplode() {
        let world = makeLoadedWorld()
        var explosions = 0
        bindExplode { _, _, _, _, _, _, _ in explosions += 1 }
        defer { bindExplode(nil) }

        let creeper = Creeper(world: world)
        creeper.setPos(4.5, 65, 4.5)
        creeper.persistent = true
        creeper.swellTicks = 25
        world.addEntity(creeper)

        XCTAssertTrue(creeper.hurt(creeper.maxHealth, "test"))
        tick(world, count: 30)

        XCTAssertTrue(creeper.dead)
        XCTAssertEqual(explosions, 0, "a corpse must not finish swelling and explode")
    }

    func testDyingZombieDoesNotConvertToDrowned() {
        let world = makeLoadedWorld()
        let zombie = Zombie(world: world)
        zombie.setPos(4.5, 65, 4.5)
        zombie.persistent = true
        zombie.baby = false
        world.addEntity(zombie)
        for y in 64...66 {
            _ = world.setBlock(4, y, 4, Int(B.water) << 4)
        }

        XCTAssertTrue(zombie.hurt(zombie.maxHealth, "test"))
        tick(world, count: 700)

        XCTAssertTrue(zombie.dead)
        XCTAssertTrue(world.entities.compactMap { $0 as? Drowned }.isEmpty,
                      "a corpse must not finish the drowned conversion")
    }

    func testCatalystBloomPendingFiresOnceAndDieReentryDoesNotReArmIt() {
        let world = makeLoadedWorld()
        let mob = GuaranteedDropMob(world: world)
        mob.setPos(4.5, 65, 4.5)
        world.addEntity(mob)

        XCTAssertFalse(mob.catalystBloomPending)
        mob.die("test")
        XCTAssertTrue(mob.catalystBloomPending, "die() must arm the bloom flag exactly once per real death")

        // simulate GameCore's consume-and-clear
        mob.catalystBloomPending = false

        // a second die() call is a no-op post idempotency guard and must not re-arm the flag
        mob.die("test")
        XCTAssertFalse(mob.catalystBloomPending, "an idempotent die() re-entry must not re-trigger the bloom")
    }
}
