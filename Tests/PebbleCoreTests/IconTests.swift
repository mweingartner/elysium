import XCTest
@testable import PebbleCore

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
}
