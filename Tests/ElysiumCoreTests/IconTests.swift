import XCTest
@testable import ElysiumCore

final class IconTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    func testTorchLanternAndChainBlockItemsUseThreeDimensionalIcons() {
        registerCoreIfNeeded()

        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.torch)))
        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.soul_torch)))
        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.lantern)))
        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.soul_lantern)))
        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.chain)))
    }

    func testFlatAndEffectBlockItemsStayFlatIcons() {
        registerCoreIfNeeded()

        XCTAssertTrue(blockItemIconUsesThreeDimensionalPreview(Int(B.stone)))
        XCTAssertFalse(blockItemIconUsesThreeDimensionalPreview(Int(B.short_grass)))
        XCTAssertFalse(blockItemIconUsesThreeDimensionalPreview(Int(B.vine)))
        XCTAssertFalse(blockItemIconUsesThreeDimensionalPreview(Int(B.water)))
        XCTAssertFalse(blockItemIconUsesThreeDimensionalPreview(Int(B.fire)))
    }

    func testFlyingWandUsesTorchIconAndDiamondSwordCombatStats() throws {
        registerCoreIfNeeded()
        resetIconCache()

        let wand = itemDef(iid(FLYING_WAND_ITEM_NAME))
        let sword = itemDef(iid("diamond_sword"))
        let wandTool = try XCTUnwrap(wand.tool)
        let swordTool = try XCTUnwrap(sword.tool)

        XCTAssertEqual(wand.displayName, "Flying Wand")
        XCTAssertEqual(wand.maxStack, 1)
        XCTAssertEqual(wand.category, "combat")
        XCTAssertEqual(wand.icon, "torch")
        XCTAssertEqual(wandTool.type, swordTool.type)
        XCTAssertEqual(wandTool.tier, swordTool.tier)
        XCTAssertEqual(wandTool.speed, swordTool.speed, accuracy: 0.000_001)
        XCTAssertEqual(wandTool.attackDamage, swordTool.attackDamage, accuracy: 0.000_001)
        XCTAssertEqual(wandTool.attackSpeed, swordTool.attackSpeed, accuracy: 0.000_001)
        XCTAssertEqual(wandTool.durability, swordTool.durability)
        XCTAssertEqual(wandTool.enchantability, swordTool.enchantability)
        XCTAssertEqual(itemIconPixels(wand.id), itemIconPixels(iid("torch")))
    }
}
