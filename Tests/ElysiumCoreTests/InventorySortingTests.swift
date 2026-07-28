import XCTest
@testable import ElysiumCore

final class InventorySortingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
    }

    func testEmptyAndAlreadyOrderedSnapshotsAreValidNoOps() throws {
        XCTAssertEqual(try XCTUnwrap(sortedInventoryStacks([])).count, 0)
        let apple = try XCTUnwrap(iidOpt("apple"))
        let stone = try XCTUnwrap(iidOpt("stone"))
        let input: [ItemStack?] = [ItemStack(apple, 2), ItemStack(stone, 3), nil]
        let result = try XCTUnwrap(sortedInventoryStacks(input))
        XCTAssertTrue(result[0] === input[0])
        XCTAssertTrue(result[1] === input[1])
        XCTAssertNil(result[2])
    }

    func testOrderingNilsStabilityAndRichReferenceMetadataConservation() throws {
        let stone = try XCTUnwrap(iidOpt("stone"))
        let apple = try XCTUnwrap(iidOpt("apple"))
        var data = StackData()
        data.potion = "healing"
        data.trim = TrimData(pattern: "sentry", material: "gold")
        data.sherds = ["angler", "blade"]
        data.charged = true
        data.priorWork = 3
        data.repairUnits = 4
        data.lodestone = [1, 2, 3, 0]
        data.flight = 2
        let nested = ItemStack(apple, 5, damage: 1)
        data.contents = [nested, nil]
        let firstStone = ItemStack(stone, 3, damage: 2, ench: [EnchInstance("sharpness", 3)],
                                   label: "kept", data: data)
        let appleStack = ItemStack(apple, 7)
        let secondStone = ItemStack(stone, 1)
        let input: [ItemStack?] = [firstStone, nil, appleStack, secondStone, nil]
        let result = try XCTUnwrap(sortedInventoryStacks(input))

        XCTAssertEqual(result.count, input.count)
        XCTAssertTrue(result[0] === appleStack)
        XCTAssertTrue(result[1] === firstStone)
        XCTAssertTrue(result[2] === secondStone)
        XCTAssertNil(result[result.count - 1])
        XCTAssertNil(result[result.count - 2])
        let firstIndex = try XCTUnwrap(result.firstIndex { $0 === firstStone })
        let secondIndex = try XCTUnwrap(result.firstIndex { $0 === secondStone })
        XCTAssertLessThan(firstIndex, secondIndex, "equal-key stacks retain source order")
        XCTAssertEqual(firstStone.count, 3)
        XCTAssertEqual(secondStone.count, 1, "sorting must not merge equal stacks")
        XCTAssertEqual(firstStone.damage, 2)
        XCTAssertEqual(firstStone.ench, [EnchInstance("sharpness", 3)])
        XCTAssertEqual(firstStone.label, "kept")
        XCTAssertEqual(firstStone.data.potion, "healing")
        XCTAssertEqual(firstStone.data.trim, TrimData(pattern: "sentry", material: "gold"))
        XCTAssertEqual(firstStone.data.sherds, ["angler", "blade"])
        XCTAssertEqual(firstStone.data.charged, true)
        XCTAssertEqual(firstStone.data.priorWork, 3)
        XCTAssertEqual(firstStone.data.repairUnits, 4)
        XCTAssertEqual(firstStone.data.lodestone, [1, 2, 3, 0])
        XCTAssertEqual(firstStone.data.flight, 2)
        XCTAssertTrue(firstStone.data.contents?[0] === nested)
        XCTAssertEqual(firstStone.data.contents?[0]?.count, 5)
        XCTAssertEqual(firstStone.data.contents?.count, 2)
    }

    func testASCIIFoldingDoesNotUseLocaleOrTransformNonASCII() {
        XCTAssertEqual(inventorySortASCIIFold("Az Z!"), "az z!")
        XCTAssertEqual(inventorySortASCIIFold("ÉΣß"), "ÉΣß")
    }

    func testNegativeAndHighIDsFailClosed() throws {
        let stone = try XCTUnwrap(iidOpt("stone"))
        let good = ItemStack(stone, 1)
        XCTAssertNil(sortedInventoryStacks([good, ItemStack(-1, 1)]))
        XCTAssertNil(sortedInventoryStacks([good, ItemStack(itemDefs.count, 1)]))
    }
}
