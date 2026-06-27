import XCTest
@testable import PebbleCore

final class FoodUseTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    private func makePlayer() -> (World, Player) {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 99)
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        return (world, player)
    }

    func testCookedChickenEatsFromSelectedHotbarSlot() {
        let (world, player) = makePlayer()
        var advancements: [String] = []
        let ctx = InteractCtx(world: world, player: player, advance: { advancements.append($0) })
        player.inventory[0] = stack("cooked_chicken", 2)
        player.selectedSlot = 0
        player.hunger = 10
        player.saturation = 0

        XCTAssertTrue(useItem(ctx, nil))
        XCTAssertTrue(player.usingItem)
        XCTAssertEqual(player.useItemSlot, 0)
        XCTAssertEqual(player.useItemItemId, iid("cooked_chicken"))

        finishUsingItem(ctx)

        XCTAssertFalse(player.usingItem)
        XCTAssertEqual(player.hunger, 16)
        XCTAssertEqual(player.saturation, 7.2, accuracy: 0.000_001)
        XCTAssertEqual(player.inventory[0]?.id, iid("cooked_chicken"))
        XCTAssertEqual(player.inventory[0]?.count, 1)
        XCTAssertEqual(advancements, ["husbandry_eat"])
    }

    func testOrdinaryFoodCannotBeEatenAtFullHunger() {
        let (world, player) = makePlayer()
        let ctx = InteractCtx(world: world, player: player)
        player.inventory[0] = stack("cooked_chicken")
        player.hunger = 20
        player.saturation = 5

        XCTAssertFalse(useItem(ctx, nil))

        XCTAssertFalse(player.usingItem)
        XCTAssertEqual(player.inventory[0]?.count, 1)
        XCTAssertEqual(player.hunger, 20)
        XCTAssertEqual(player.saturation, 5, accuracy: 0.000_001)
    }

    func testAlwaysEatFoodCanBeUsedAtFullHunger() {
        let (world, player) = makePlayer()
        let ctx = InteractCtx(world: world, player: player)
        player.inventory[0] = stack("milk_bucket")
        player.hunger = 20
        player.saturation = 5
        player.addEffect("poison", 100, 0)

        XCTAssertTrue(useItem(ctx, nil))
        finishUsingItem(ctx)

        XCTAssertEqual(player.hunger, 20)
        XCTAssertEqual(player.saturation, 5, accuracy: 0.000_001)
        XCTAssertEqual(player.inventory[0]?.id, iid("bucket"))
        XCTAssertTrue(player.effects.isEmpty)
    }

    func testChangingHotbarSlotCancelsEatingWithoutConsuming() {
        let (world, player) = makePlayer()
        let ctx = InteractCtx(world: world, player: player)
        player.inventory[0] = stack("cooked_chicken")
        player.inventory[1] = stack("dirt")
        player.selectedSlot = 0
        player.hunger = 10
        player.saturation = 0

        XCTAssertTrue(useItem(ctx, nil))
        player.selectedSlot = 1
        finishUsingItem(ctx)

        XCTAssertFalse(player.usingItem)
        XCTAssertEqual(player.hunger, 10)
        XCTAssertEqual(player.saturation, 0, accuracy: 0.000_001)
        XCTAssertEqual(player.inventory[0]?.id, iid("cooked_chicken"))
        XCTAssertEqual(player.inventory[0]?.count, 1)
        XCTAssertEqual(player.inventory[1]?.id, iid("dirt"))
        XCTAssertEqual(player.inventory[1]?.count, 1)
    }

    func testEatingToFullHungerEnablesNaturalHealthRegeneration() {
        let (world, player) = makePlayer()
        let ctx = InteractCtx(world: world, player: player)
        player.inventory[0] = stack("cooked_chicken")
        player.hunger = 14
        player.saturation = 0
        player.health = 18

        XCTAssertTrue(useItem(ctx, nil))
        finishUsingItem(ctx)
        for _ in 0..<10 { player.tick() }

        XCTAssertEqual(player.hunger, 20)
        XCTAssertEqual(player.health, 19, accuracy: 0.000_001)
        XCTAssertLessThan(player.saturation, 7.2)
    }

    func testFoodUseDurationsMatchFoodDefinition() {
        registerCoreIfNeeded()

        XCTAssertEqual(heldUseDurationTicks(itemDef(iid("cooked_chicken"))), 32)
        XCTAssertEqual(heldUseDurationTicks(itemDef(iid("dried_kelp"))), 17)
        XCTAssertEqual(heldUseDurationTicks(itemDef(iid("potion"))), 32)
    }
}
