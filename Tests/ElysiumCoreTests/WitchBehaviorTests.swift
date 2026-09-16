import XCTest
@testable import ElysiumCore

final class WitchBehaviorTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    private func makeWorld() -> World {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 42)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        for x in 0..<16 {
            for z in 0..<16 {
                chunk.set(x, 63, z, cell(B.stone))
            }
        }
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        return world
    }

    private func makeWitch(in world: World) -> Witch {
        let witch = Witch(world: world)
        witch.setPos(0.5, 64, 0.5)
        witch.persistent = true
        return witch
    }

    func testDrinkingPersistsAndHealingCompletesAtEndOfUseWindow() throws {
        let world = makeWorld()
        let witch = makeWitch(in: world)
        witch.health = 10
        XCTAssertTrue(witch.startDrinking("healing"))

        let saved = witch.save()
        let restored = try XCTUnwrap(loadEntity(world, saved) as? Witch)
        XCTAssertEqual(restored.drinkTime, 32)
        XCTAssertEqual(restored.drinkingPotionId, "healing")
        XCTAssertFalse(restored.suppressesMobAI)
        XCTAssertEqual(restored.effectiveSpeed(), 0.075, accuracy: 0.000_001)

        for _ in 0..<31 { witch.tick() }
        XCTAssertEqual(witch.drinkTime, 1)
        XCTAssertEqual(witch.health, 10, "healing cannot take effect before the drink finishes")

        witch.tick()
        XCTAssertEqual(witch.drinkTime, 0)
        XCTAssertNil(witch.drinkingPotionId)
        XCTAssertEqual(witch.health, 14, "healing must take effect when the 32-tick use ends")
        XCTAssertEqual(witch.effectiveSpeed(), 0.1, accuracy: 0.000_001)

        var invalid = saved
        invalid["witchDrinkTime"] = 33
        invalid["witchDrinkPotion"] = "not_a_potion"
        let rejected = try XCTUnwrap(loadEntity(world, invalid) as? Witch)
        XCTAssertEqual(rejected.drinkTime, 0)
        XCTAssertNil(rejected.drinkingPotionId)
        XCTAssertFalse(rejected.suppressesMobAI)
    }

    func testDrinkingRetainsNavigationAtReducedSpeed() {
        let world = makeWorld()
        let witch = makeWitch(in: world)
        world.addEntity(witch)
        witch.nav.path = [PathNode(x: 1, y: 64, z: 0)]
        XCTAssertFalse(witch.nav.isDone())
        XCTAssertEqual(witch.effectiveSpeed(), 0.1, accuracy: 0.000_001)
        XCTAssertTrue(witch.startDrinking("fire_resistance"))

        witch.tick()

        XCTAssertFalse(witch.suppressesMobAI)
        XCTAssertFalse(witch.nav.isDone(), "an active drink must retain navigation")
        XCTAssertEqual(witch.effectiveSpeed(), 0.075, accuracy: 0.000_001)
    }

    func testDrinkingSuppressesPotionThrows() {
        let world = makeWorld()
        let witch = makeWitch(in: world)
        let player = Player(world: world)
        player.setPos(5.5, 64, 0.5)
        world.addEntity(witch)
        world.addEntity(player)
        witch.setTarget(player)
        witch.age = 1 // next tick reaches the ranged-goal selector cadence
        XCTAssertTrue(witch.startDrinking("fire_resistance"))

        witch.tick()

        XCTAssertTrue(world.entities.compactMap { $0 as? ThrownPotion }.isEmpty,
                      "an active drink must suppress ranged potion attacks")
    }

    func testDefensivePotionSelectionCoversWaterFireHealingAndSpeed() {
        let world = makeWorld()
        let witch = makeWitch(in: world)

        witch.underwater = true
        witch.rng = RandomX(12) // first sample is below the 15% water-defense threshold
        XCTAssertEqual(witch.selectDefensivePotion(), "water_breathing")

        witch.underwater = false
        witch.fireTicks = 1
        witch.rng = RandomX(12)
        XCTAssertEqual(witch.selectDefensivePotion(), "fire_resistance")

        witch.fireTicks = 0
        witch.health = witch.maxHealth - 1
        witch.rng = RandomX(16) // first sample is below the 5% healing threshold
        XCTAssertEqual(witch.selectDefensivePotion(), "healing")

        let player = Player(world: world)
        player.setPos(12.5, 64, 0.5)
        witch.setTarget(player)
        witch.health = witch.maxHealth
        witch.rng = RandomX(0) // first sample is below the 50% speed threshold
        XCTAssertEqual(witch.selectDefensivePotion(), "swiftness")
    }

    func testTargetAwarePotionSelectionAndProjectileOwnership() throws {
        let world = makeWorld()
        let witch = makeWitch(in: world)
        let player = Player(world: world)
        player.setPos(9.5, 64, 0.5)

        XCTAssertEqual(witch.selectOffensivePotion(for: player), "slowness")

        player.setPos(5.5, 64, 0.5)
        XCTAssertEqual(witch.selectOffensivePotion(for: player), "poison")

        player.health = 7
        player.setPos(2.5, 64, 0.5)
        witch.rng = RandomX(1) // first sample is below the 25% weakness threshold
        XCTAssertEqual(witch.selectOffensivePotion(for: player), "weakness")

        player.addEffect("weakness", 100)
        XCTAssertEqual(witch.selectOffensivePotion(for: player), "harming")

        player.clearEffects()
        player.health = player.maxHealth
        player.setPos(9.5, 64, 0.5)
        world.addEntity(witch)
        world.addEntity(player)
        witch.setTarget(player)
        // Goal selectors begin on even entity ages; the first tick advances
        // from age zero and the second is the first ranged-attack decision.
        witch.tick()
        witch.tick()

        let potion = try XCTUnwrap(world.entities.compactMap { $0 as? ThrownPotion }.first)
        XCTAssertTrue(potion.owner === witch)
        XCTAssertEqual(potion.potionId, "slowness")
    }

    func testPlayerKillCanDropThePotionBeingDrunkExactlyOnce() {
        let world = makeWorld()
        let witch = makeWitch(in: world)
        let player = Player(world: world)
        player.setPos(2.5, 64, 0.5)
        world.addEntity(witch)
        world.addEntity(player)
        XCTAssertTrue(witch.startDrinking("healing"))
        witch.rng = RandomX(16) // first sample is below the carried-potion 8.5% drop chance

        var dropped: [ItemStack] = []
        let restoreItems = spawnItemFn
        let restoreXP = spawnXPFn
        bindSpawners({ _, _, _, _, stack, _, _, _ in dropped.append(stack) }, restoreXP)
        defer { bindSpawners(restoreItems, restoreXP) }

        XCTAssertTrue(witch.hurt(witch.maxHealth, "test", player))
        XCTAssertFalse(witch.hurt(1, "test", player), "death must stay idempotent")

        let carriedPotions = dropped.filter { itemDef($0.id).name == "potion" }
        XCTAssertEqual(carriedPotions.count, 1)
        XCTAssertEqual(carriedPotions.first?.data.potion, "healing")
    }

    func testWitchAdvertisesModernGuaranteedRedstoneRange() {
        let world = makeWorld()
        let witch = makeWitch(in: world)
        let redstone = witch.drops().first { $0.item == "redstone" }
        XCTAssertEqual(redstone?.min, 4)
        XCTAssertEqual(redstone?.max, 8)
        XCTAssertNil(redstone?.chance)
    }
}
