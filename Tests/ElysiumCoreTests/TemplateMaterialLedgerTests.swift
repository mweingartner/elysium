import XCTest
@testable import ElysiumCore

/// Paying for a survival paste and paying it back (`TemplateMaterialLedger.swift`), on rows of
/// item slots with no world behind them.
final class TemplateMaterialLedgerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
    }

    private func bill(_ needs: [(String, Int)]) -> TemplateMaterialBill {
        var counts: [Int: Int] = [:]
        for (name, count) in needs { counts[iid(name), default: 0] += count }
        return TemplateMaterialBill(counts)
    }

    private func total(_ slots: TemplateMaterialSlots) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for case let stack? in slots.stacks { counts[stack.id, default: 0] += stack.count }
        return counts
    }

    // MARK: - What may pay

    func testOnlyAPlainStackPaysForAPaste() {
        XCTAssertTrue(isPlainTemplateMaterial(stack("oak_planks", 3)))
        XCTAssertFalse(isPlainTemplateMaterial(ItemStack(iid("oak_planks"), 0)))
        XCTAssertFalse(isPlainTemplateMaterial(ItemStack(iid("oak_planks"), 3, label: "Keep")))
        XCTAssertFalse(isPlainTemplateMaterial(ItemStack(iid("diamond_pickaxe"), 1, damage: 4)))
        XCTAssertFalse(isPlainTemplateMaterial(ItemStack(iid("oak_planks"), 3, ench: [EnchInstance("unbreaking", 1)])))
        var filled = StackData()
        filled.contents = [stack("diamond", 64)]
        XCTAssertFalse(isPlainTemplateMaterial(ItemStack(iid("shulker_box"), 1, data: filled)))
        XCTAssertTrue(isPlainTemplateMaterial(ItemStack(iid("shulker_box"), 1)))
    }

    func testAFilledShulkerBoxAndARenamedStackAreNeverTaken() {
        var filled = StackData()
        filled.contents = [stack("diamond", 64)]
        var stores = TemplateMaterialStores(inventory: TemplateMaterialSlots(copying: [
            ItemStack(iid("shulker_box"), 1, data: filled),
            ItemStack(iid("oak_planks"), 10, label: "Keep"),
            stack("oak_planks", 2),
        ]))
        let before = stores.inventory.stacks.map(copyStack)
        guard case .failure(let error) = payTemplateMaterials(bill([("shulker_box", 1), ("oak_planks", 5)]),
                                                              from: &stores) else {
            return XCTFail("a filled box and a renamed stack must not pay")
        }
        XCTAssertEqual(error, .missing([
            TemplateMaterialLine(itemID: min(iid("shulker_box"), iid("oak_planks")),
                                 count: iid("shulker_box") < iid("oak_planks") ? 1 : 3),
            TemplateMaterialLine(itemID: max(iid("shulker_box"), iid("oak_planks")),
                                 count: iid("shulker_box") < iid("oak_planks") ? 3 : 1),
        ]))
        XCTAssertEqual(stores.inventory.stacks, before, "a refused payment changes nothing")
        XCTAssertEqual(stores.inventory.touchedSlots, [])
    }

    // MARK: - Slots

    func testTakingRemovesFromTheFirstSlotsAndLeavesTheOriginalsAlone() {
        let originals: [ItemStack?] = [stack("stone", 5), nil, stack("dirt", 9), stack("stone", 64)]
        var slots = TemplateMaterialSlots(copying: originals)
        XCTAssertEqual(slots.take(itemID: iid("stone"), count: 7), 7)
        XCTAssertNil(slots.stacks[0])
        XCTAssertEqual(slots.stacks[3]?.count, 62)
        XCTAssertEqual(slots.stacks[2]?.count, 9)
        XCTAssertEqual(slots.touchedSlots, [0, 3])
        XCTAssertEqual(originals[0]?.count, 5, "the row works on copies")
        XCTAssertEqual(originals[3]?.count, 64)
        XCTAssertEqual(slots.take(itemID: iid("stone"), count: 1_000), 62, "no more than there is")
        XCTAssertEqual(slots.take(itemID: iid("stone"), count: -4), 0)
        XCTAssertEqual(slots.take(itemID: iid("glass"), count: 3), 0)
    }

    func testACopyOfARowIsIndependentOfTheRowItWasCopiedFrom() {
        var first = TemplateMaterialSlots(copying: [stack("stone", 10)])
        var second = first
        XCTAssertEqual(second.take(itemID: iid("stone"), count: 4), 4)
        XCTAssertEqual(first.stacks[0]?.count, 10)
        XCTAssertEqual(second.stacks[0]?.count, 6)
        XCTAssertEqual(first.put(itemID: iid("stone"), count: 3), 3)
        XCTAssertEqual(first.stacks[0]?.count, 13)
        XCTAssertEqual(second.stacks[0]?.count, 6)
    }

    func testPuttingFillsStacksOfTheItemThenEmptySlotsAndNeverOverfills() {
        var slots = TemplateMaterialSlots(copying: [stack("stone", 60), nil, stack("dirt", 64),
                                                    ItemStack(iid("stone"), 1, label: "Keep"), nil])
        XCTAssertEqual(slots.put(itemID: iid("stone"), count: 100), 100)
        XCTAssertEqual(slots.stacks[0]?.count, 64)
        XCTAssertEqual(slots.stacks[1]?.count, 64)
        XCTAssertEqual(slots.stacks[4]?.count, 32)
        XCTAssertEqual(slots.stacks[3]?.count, 1, "a renamed stack is not topped up")
        XCTAssertEqual(slots.put(itemID: iid("stone"), count: 100), 32, "only what fits")
        XCTAssertEqual(slots.put(itemID: iid("stone"), count: 1), 0)
        XCTAssertEqual(slots.put(itemID: -1, count: 5), 0)
        XCTAssertEqual(slots.put(itemID: itemDefs.count, count: 5), 0)

        // An item that does not stack takes one slot each.
        let disc = iid("music_disc_wander")
        XCTAssertEqual(itemDefs[disc].maxStack, 1)
        var oneEach = TemplateMaterialSlots(copying: [nil, nil, nil])
        XCTAssertEqual(oneEach.put(itemID: disc, count: 5), 3)
        XCTAssertTrue(oneEach.stacks.allSatisfy { $0?.count == 1 })
    }

    func testARefundSkipsSlotsThatDoNotTakeOne() {
        var slots = TemplateMaterialSlots(copying: [nil, stack("stone", 1), nil],
                                          acceptsRefund: [false, false, true])
        XCTAssertEqual(slots.put(itemID: iid("stone"), count: 200), 64)
        XCTAssertNil(slots.stacks[0])
        XCTAssertEqual(slots.stacks[1]?.count, 1)
        XCTAssertEqual(slots.stacks[2]?.count, 64)
        XCTAssertEqual(slots.take(itemID: iid("stone"), count: 1), 1, "taking is allowed from every slot")
        XCTAssertNil(slots.stacks[1])
    }

    // MARK: - Paying

    func testAPasteIsPaidFromTheInventoryFirstAndThenFromStorage() throws {
        var stores = TemplateMaterialStores(
            inventory: TemplateMaterialSlots(copying: [stack("oak_planks", 10), stack("glass", 4)]),
            storage: TemplateMaterialSlots(copying: [stack("oak_planks", 64), stack("oak_planks", 64), stack("torch", 8)]))
        let receipt = try payTemplateMaterials(bill([("oak_planks", 80), ("glass", 3), ("torch", 2)]), from: &stores).get()
        XCTAssertEqual(receipt.lines.map(\.itemID), receipt.lines.map(\.itemID).sorted())
        let planks = try XCTUnwrap(receipt.lines.first { $0.itemID == iid("oak_planks") })
        XCTAssertEqual(planks.fromInventory, 10)
        XCTAssertEqual(planks.fromStorage, 70)
        XCTAssertEqual(receipt.paid(iid("glass")), 3)
        XCTAssertEqual(receipt.paid(iid("torch")), 2)
        XCTAssertEqual(receipt.total, 85)
        XCTAssertEqual(receipt.fromInventory, 13)
        XCTAssertEqual(receipt.fromStorage, 72)
        XCTAssertNil(stores.inventory.stacks[0])
        XCTAssertEqual(stores.inventory.stacks[1]?.count, 1)
        XCTAssertNil(stores.storage.stacks[0])
        XCTAssertEqual(stores.storage.stacks[1]?.count, 58)
        XCTAssertEqual(stores.storage.stacks[2]?.count, 6)
    }

    func testAPasteThatCannotBePaidTakesNothingAndSaysWhatIsMissing() {
        var stores = TemplateMaterialStores(
            inventory: TemplateMaterialSlots(copying: [stack("oak_planks", 10)]),
            storage: TemplateMaterialSlots(copying: [stack("glass", 2)]))
        guard case .failure(let error) = payTemplateMaterials(bill([("oak_planks", 10), ("glass", 5), ("torch", 1)]),
                                                              from: &stores) else {
            return XCTFail("glass and torches are missing")
        }
        guard case .missing(let lines) = error else { return XCTFail("\(error)") }
        XCTAssertEqual(Set(lines.map(\.itemID)), [iid("glass"), iid("torch")])
        XCTAssertEqual(lines.first { $0.itemID == iid("glass") }?.count, 3)
        XCTAssertEqual(lines.first { $0.itemID == iid("torch") }?.count, 1)
        XCTAssertEqual(stores.inventory.stacks[0]?.count, 10, "the planks stay although they were enough")
        XCTAssertEqual(stores.storage.stacks[0]?.count, 2)
        XCTAssertEqual(stores.inventory.touchedSlots + stores.storage.touchedSlots, [])
    }

    func testAnEmptyBillCostsNothing() throws {
        var stores = TemplateMaterialStores(inventory: TemplateMaterialSlots(copying: [stack("stone", 1)]))
        let receipt = try payTemplateMaterials(TemplateMaterialBill(), from: &stores).get()
        XCTAssertEqual(receipt.total, 0)
        XCTAssertEqual(stores.inventory.touchedSlots, [])
    }

    // MARK: - The receipt

    func testGivingBackReturnsTheInventoryShareFirstAndNeverMoreThanWasPaid() {
        var receipt = TemplateMaterialReceipt(lines: [
            TemplateMaterialReceiptLine(itemID: iid("stone"), fromInventory: 10, fromStorage: 30),
            TemplateMaterialReceiptLine(itemID: iid("glass"), fromInventory: 0, fromStorage: 0),
        ])
        XCTAssertEqual(receipt.lines.count, 1, "an empty line is not kept")
        var share = receipt.giveBack(itemID: iid("stone"), count: 4)
        XCTAssertEqual(share.toInventory, 4)
        XCTAssertEqual(share.toStorage, 0)
        share = receipt.giveBack(itemID: iid("stone"), count: 16)
        XCTAssertEqual(share.toInventory, 6)
        XCTAssertEqual(share.toStorage, 10)
        XCTAssertEqual(receipt.paid(iid("stone")), 20)
        share = receipt.giveBack(itemID: iid("stone"), count: 1_000)
        XCTAssertEqual(share.toInventory + share.toStorage, 20, "capped by what the receipt still holds")
        XCTAssertEqual(receipt.total, 0)
        XCTAssertEqual(receipt.lines.count, 0)
        share = receipt.giveBack(itemID: iid("stone"), count: 5)
        XCTAssertEqual(share.toInventory + share.toStorage, 0, "nothing is paid back twice")
        share = receipt.giveBack(itemID: iid("glass"), count: 5)
        XCTAssertEqual(share.toInventory + share.toStorage, 0, "an item that was never paid")
        var other = TemplateMaterialReceipt(lines: [
            TemplateMaterialReceiptLine(itemID: iid("stone"), fromInventory: 3, fromStorage: 0)])
        share = other.giveBack(itemID: iid("stone"), count: -7)
        XCTAssertEqual(share.toInventory + share.toStorage, 0)
        XCTAssertEqual(other.total, 3)
    }

    // MARK: - Refunding

    func testARefundGoesBackWhereItCameFromAndOverflowsIntoTheOtherRow() throws {
        var stores = TemplateMaterialStores(
            inventory: TemplateMaterialSlots(copying: [stack("stone", 20), nil]),
            storage: TemplateMaterialSlots(copying: [stack("stone", 64), stack("stone", 64), nil]))
        var receipt = try payTemplateMaterials(bill([("stone", 100)]), from: &stores).get()
        XCTAssertEqual(receipt.fromInventory, 20)
        XCTAssertEqual(receipt.fromStorage, 80)

        var refund = refundTemplateMaterials([iid("stone"): 100], against: &receipt, into: &stores)
        XCTAssertEqual(refund.toInventory, 20)
        XCTAssertEqual(refund.toStorage, 80)
        XCTAssertEqual(refund.leftover, [])
        XCTAssertEqual(receipt.total, 0)
        XCTAssertEqual(total(stores.inventory)[iid("stone")], 20)
        XCTAssertEqual(total(stores.storage)[iid("stone")], 128)

        // Storage is full now: what would go there overflows into the inventory.
        var full = TemplateMaterialStores(
            inventory: TemplateMaterialSlots(copying: [nil, nil]),
            storage: TemplateMaterialSlots(copying: [stack("dirt", 64)]))
        var paid = TemplateMaterialReceipt(lines: [
            TemplateMaterialReceiptLine(itemID: iid("stone"), fromInventory: 0, fromStorage: 70)])
        refund = refundTemplateMaterials([iid("stone"): 70], against: &paid, into: &full)
        XCTAssertEqual(refund.toStorage, 0)
        XCTAssertEqual(refund.toInventory, 70)
        XCTAssertEqual(refund.leftover, [])
    }

    func testARefundWithNoRoomReportsWhatIsLeftOverInStacks() {
        var stores = TemplateMaterialStores(inventory: TemplateMaterialSlots(copying: [stack("dirt", 64), nil]))
        var receipt = TemplateMaterialReceipt(lines: [
            TemplateMaterialReceiptLine(itemID: iid("stone"), fromInventory: 200, fromStorage: 0),
            TemplateMaterialReceiptLine(itemID: iid("oak_door"), fromInventory: 2, fromStorage: 0),
        ])
        let refund = refundTemplateMaterials([iid("stone"): 200, iid("oak_door"): 2], against: &receipt, into: &stores)
        XCTAssertEqual(refund.returned + refund.leftover.reduce(0) { $0 + $1.count }, 202)
        XCTAssertEqual(refund.leftover.map(\.itemID), refund.leftover.map(\.itemID).sorted())
        XCTAssertGreaterThan(refund.leftoverStacks, 0)
        let stoneLeft = refund.leftover.first { $0.itemID == iid("stone") }?.count ?? 0
        let doorsLeft = refund.leftover.first { $0.itemID == iid("oak_door") }?.count ?? 0
        let doorStack = itemDefs[iid("oak_door")].maxStack
        XCTAssertEqual(refund.leftoverStacks, (stoneLeft + 63) / 64 + (doorsLeft + doorStack - 1) / doorStack)
    }

    func testARefundNeverExceedsTheReceiptHoweverMuchStands() {
        var stores = TemplateMaterialStores(inventory: TemplateMaterialSlots(copying: Array(repeating: nil, count: 36)))
        var receipt = TemplateMaterialReceipt(lines: [
            TemplateMaterialReceiptLine(itemID: iid("stone"), fromInventory: 5, fromStorage: 0)])
        let refund = refundTemplateMaterials([iid("stone"): 500, iid("diamond_block"): 64],
                                             against: &receipt, into: &stores)
        XCTAssertEqual(refund.returned, 5)
        XCTAssertEqual(total(stores.inventory), [iid("stone"): 5], "nothing that was not paid comes back")
        XCTAssertEqual(refundTemplateMaterials([iid("stone"): 500], against: &receipt, into: &stores).returned, 0,
                       "and nothing comes back a second time")
    }

    // MARK: - Seeded: nothing is made or lost

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
    }

    /// For seeded inventories, storage and bills: a payment either changes nothing or takes
    /// exactly the bill, and paying back any part of it never returns more than was paid, never
    /// loses an item, and never touches a stack that is not plain.
    func testPayingAndRefundingConservesEveryItemForSeededStores() throws {
        let names = ["stone", "oak_planks", "glass", "oak_door", "torch", "dirt"]
        var random = SplitMix64(state: 0x00C0_FFEE)
        for round in 0..<400 {
            func row(_ slots: Int) -> [ItemStack?] {
                (0..<slots).map { _ in
                    switch random.int(5) {
                    case 0: return nil
                    case 1: return ItemStack(iid(names[random.int(names.count)]), 1 + random.int(8), label: "Keep")
                    default:
                        let id = iid(names[random.int(names.count)])
                        return ItemStack(id, 1 + random.int(itemDefs[id].maxStack))
                    }
                }
            }
            let inventory = row(1 + random.int(12)), storage = row(random.int(20))
            var stores = TemplateMaterialStores(inventory: TemplateMaterialSlots(copying: inventory),
                                                storage: TemplateMaterialSlots(copying: storage))
            var needs: [(String, Int)] = []
            for name in names where random.int(2) == 0 { needs.append((name, 1 + random.int(90))) }
            let wanted = bill(needs)
            let before = total(stores.inventory).merging(total(stores.storage), uniquingKeysWith: +)
            let keptBefore = (inventory + storage).compactMap { $0 }.filter { !isPlainTemplateMaterial($0) }.count

            guard case .success(var receipt) = payTemplateMaterials(wanted, from: &stores) else {
                XCTAssertEqual(stores.inventory.stacks, inventory, "round \(round): a refusal changes nothing")
                XCTAssertEqual(stores.storage.stacks, storage, "round \(round)")
                continue
            }
            var after = total(stores.inventory).merging(total(stores.storage), uniquingKeysWith: +)
            for line in wanted.lines {
                XCTAssertEqual((before[line.itemID] ?? 0) - (after[line.itemID] ?? 0), line.count, "round \(round)")
                XCTAssertEqual(receipt.paid(line.itemID), line.count, "round \(round)")
            }
            XCTAssertEqual(receipt.total, wanted.total, "round \(round)")

            // Some of it stands, some of it was mined: pay back a part, then ask for all of it twice.
            var standing: [Int: Int] = [:]
            for line in wanted.lines { standing[line.itemID] = random.int(line.count + 20) }
            let first = refundTemplateMaterials(standing, against: &receipt, into: &stores)
            let second = refundTemplateMaterials(standing.mapValues { $0 + 1_000 }, against: &receipt, into: &stores)
            let third = refundTemplateMaterials(standing.mapValues { $0 + 1_000 }, against: &receipt, into: &stores)
            XCTAssertEqual(third.returned, 0, "round \(round): nothing is left to pay back")
            XCTAssertEqual(receipt.total, 0, "round \(round)")
            let leftover = (first.leftover + second.leftover).reduce(0) { $0 + $1.count }
            XCTAssertEqual(first.returned + second.returned + leftover, wanted.total, "round \(round)")
            after = total(stores.inventory).merging(total(stores.storage), uniquingKeysWith: +)
            for itemID in Set(before.keys).union(after.keys) {
                XCTAssertLessThanOrEqual(after[itemID] ?? 0, before[itemID] ?? 0,
                                         "round \(round): more \(itemDefs[itemID].name) than before the paste")
            }
            let afterTotal = after.values.reduce(0, +), beforeTotal = before.values.reduce(0, +)
            XCTAssertEqual(afterTotal + leftover, beforeTotal, "round \(round): every item is in a slot or left over")
            let keptAfter = (stores.inventory.stacks + stores.storage.stacks).compactMap { $0 }
                .filter { !isPlainTemplateMaterial($0) }.count
            XCTAssertEqual(keptAfter, keptBefore, "round \(round): a stack that is not plain is never touched")
            for case let stack? in stores.inventory.stacks + stores.storage.stacks {
                XCTAssertLessThanOrEqual(stack.count, itemDefs[stack.id].maxStack, "round \(round)")
                XCTAssertGreaterThan(stack.count, 0, "round \(round)")
            }
        }
    }

    // MARK: - Texts

    func testTheUsedAndReturnedTextsSayHowManyAndWhere() {
        XCTAssertNil(templateMaterialsUsedText(TemplateMaterialReceipt()))
        XCTAssertEqual(templateMaterialsUsedText(TemplateMaterialReceipt(lines: [
            TemplateMaterialReceiptLine(itemID: iid("stone"), fromInventory: 380, fromStorage: 32)])),
                       "Used 412 materials: 380 from your inventory, 32 from containers.")
        XCTAssertEqual(templateMaterialsUsedText(TemplateMaterialReceipt(lines: [
            TemplateMaterialReceiptLine(itemID: iid("stone"), fromInventory: 1, fromStorage: 0)])),
                       "Used 1 material: 1 from your inventory.")
        XCTAssertNil(templateMaterialsReturnedText(TemplateMaterialRefund()))
        XCTAssertEqual(templateMaterialsReturnedText(TemplateMaterialRefund(toInventory: 0, toStorage: 20)),
                       "Returned 20 materials: 20 to containers.")
    }
}
