import XCTest
@testable import ElysiumCore

@MainActor
final class BowUseTests: XCTestCase {
    private func makeFixture() -> (World, Player, InteractCtx) {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
        let world = World(dim: .overworld, seed: 0xB0A)
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        player.inventory[0] = stack("bow")
        player.inventory[1] = stack("arrow", 4)
        player.selectedSlot = 0
        return (world, player, InteractCtx(world: world, player: player))
    }

    func testHoldingBowBeginsChargeAndReleaseFiresUsingTheSameTickCount() {
        let (world, player, context) = makeFixture()

        XCTAssertTrue(useItem(context, nil))
        XCTAssertTrue(player.usingItem)
        XCTAssertEqual(player.useItemHand, "main")
        player.useItemTicks = 20

        releaseUsingItem(context)

        XCTAssertFalse(player.usingItem)
        XCTAssertEqual(player.countItem(iid("arrow")), 3)
        XCTAssertEqual(world.entities.compactMap { $0 as? ArrowEntity }.count, 1)
        XCTAssertEqual(player.stats["arrowsShot"], 1)
    }

    func testReleasingBeforeMinimumChargeDoesNotFireOrConsumeArrow() {
        let (world, player, context) = makeFixture()
        XCTAssertTrue(useItem(context, nil))
        player.useItemTicks = 1

        releaseUsingItem(context)

        XCTAssertFalse(player.usingItem)
        XCTAssertEqual(player.countItem(iid("arrow")), 4)
        XCTAssertTrue(world.entities.compactMap { $0 as? ArrowEntity }.isEmpty)
    }

    func testChangingSelectedSlotCancelsTheChargedShot() {
        let (world, player, context) = makeFixture()
        XCTAssertTrue(useItem(context, nil))
        player.useItemTicks = 20
        player.selectedSlot = 1

        releaseUsingItem(context)

        XCTAssertFalse(player.usingItem)
        XCTAssertEqual(player.countItem(iid("arrow")), 4)
        XCTAssertTrue(world.entities.compactMap { $0 as? ArrowEntity }.isEmpty)
    }
}
