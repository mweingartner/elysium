import XCTest
@testable import ElysiumCore

@MainActor
final class OffhandToggleTests: XCTestCase {
    private func makePlayer() -> Player {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
        let world = World(dim: .overworld, seed: 7)
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        return player
    }

    func testEquipsFromInventoryIntoEmptyOffHand() {
        let p = makePlayer()
        p.inventory[3] = stack("shield", 1)

        XCTAssertTrue(p.toggleOffhandItem(named: "shield"))
        XCTAssertEqual(p.offHand?.id, iid("shield"))
        XCTAssertNil(p.inventory[3], "the only shield moved out of the inventory")
    }

    func testTogglingSameItemUnequipsBackToInventory() {
        let p = makePlayer()
        p.inventory[0] = stack("shield", 1)
        XCTAssertTrue(p.toggleOffhandItem(named: "shield"))
        XCTAssertEqual(p.offHand?.id, iid("shield"))

        XCTAssertTrue(p.toggleOffhandItem(named: "shield"))
        XCTAssertNil(p.offHand, "second press returns the shield")
        XCTAssertEqual(p.countItem(iid("shield")), 1)
    }

    func testTorchEquipsOneAndLeavesTheRestForPlacing() {
        let p = makePlayer()
        p.inventory[5] = stack("torch", 16)

        XCTAssertTrue(p.toggleOffhandItem(named: "torch"))
        XCTAssertEqual(p.offHand?.id, iid("torch"))
        XCTAssertEqual(p.offHand?.count, 1, "only one torch goes to the off-hand")
        XCTAssertEqual(p.countItem(iid("torch")), 15, "the rest stay in the inventory")
    }

    func testEquippingReplacesAndStowsThePreviousOffHandItem() {
        let p = makePlayer()
        p.inventory[0] = stack("shield", 1)
        p.inventory[1] = stack("torch", 4)
        XCTAssertTrue(p.toggleOffhandItem(named: "shield"))
        XCTAssertEqual(p.offHand?.id, iid("shield"))

        XCTAssertTrue(p.toggleOffhandItem(named: "torch"))
        XCTAssertEqual(p.offHand?.id, iid("torch"), "torch replaces the shield in the off-hand")
        XCTAssertEqual(p.countItem(iid("shield")), 1, "the displaced shield returns to the inventory")
    }

    func testNoOpWhenItemIsNotInInventory() {
        let p = makePlayer()
        XCTAssertFalse(p.toggleOffhandItem(named: "shield"))
        XCTAssertNil(p.offHand)
    }
}
