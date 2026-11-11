import Foundation

// Paying for a survival paste and paying it back.
//
// Materials come from rows of item slots: what the player carries, and the containers near
// the player in the order crafting takes from them. Every step here works on copies of those
// rows. The owner writes the changed slots back only once the whole step has succeeded, so a
// paste that cannot be paid, or an undo with no room for its refund, changes nothing.

/// Whether a stack may pay for a paste: an ordinary stack of the item, with no enchantment,
/// wear, name or contents. A filled shulker box or a renamed block is never taken.
func isPlainTemplateMaterial(_ stack: ItemStack) -> Bool {
    stack.count > 0 && stack.damage == 0 && stack.ench.isEmpty
        && (stack.label ?? "").isEmpty && stack.data.isEmpty
}

/// A row of item slots that a paste is paid from and refunded into. It is a value: a take or
/// a put replaces the stack in a slot and never changes a stack another copy of the row holds.
struct TemplateMaterialSlots {
    private(set) var stacks: [ItemStack?]
    /// Whether a refund may go into each slot. Materials may be taken from every slot.
    private let acceptsRefund: [Bool]
    private var touched: [Bool]

    /// Copies `stacks`; the originals are never changed from here.
    init(copying stacks: [ItemStack?], acceptsRefund: [Bool]? = nil) {
        self.stacks = stacks.map(copyStack)
        self.acceptsRefund = acceptsRefund ?? Array(repeating: true, count: stacks.count)
        touched = Array(repeating: false, count: stacks.count)
        precondition(self.acceptsRefund.count == stacks.count)
    }

    /// The slots a take or a put has changed, ascending.
    var touchedSlots: [Int] { touched.indices.filter { touched[$0] } }

    /// How many plain items of each kind the row holds.
    func plainCounts() -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for case let stack? in stacks where isPlainTemplateMaterial(stack) {
            counts[stack.id, default: 0] += stack.count
        }
        return counts
    }

    /// Removes up to `count` plain items of `itemID`, first slot first. Returns how many.
    mutating func take(itemID: Int, count: Int) -> Int {
        var left = max(0, count)
        for index in stacks.indices where left > 0 {
            guard let stack = stacks[index], stack.id == itemID, isPlainTemplateMaterial(stack) else { continue }
            let taken = min(stack.count, left)
            left -= taken
            stacks[index] = stack.count > taken ? ItemStack(itemID, stack.count - taken) : nil
            touched[index] = true
        }
        return max(0, count) - left
    }

    /// Adds up to `count` plain items of `itemID`: onto stacks of it first, then into empty
    /// slots, never above the item's stack size. Returns how many went in.
    mutating func put(itemID: Int, count: Int) -> Int {
        guard itemID >= 0, itemID < itemDefs.count else { return 0 }
        let limit = max(1, itemDefs[itemID].maxStack)
        var left = max(0, count)
        for index in stacks.indices where left > 0 && acceptsRefund[index] {
            guard let stack = stacks[index], stack.id == itemID, isPlainTemplateMaterial(stack),
                  stack.count < limit else { continue }
            let added = min(limit - stack.count, left)
            stacks[index] = ItemStack(itemID, stack.count + added)
            left -= added
            touched[index] = true
        }
        for index in stacks.indices where left > 0 && acceptsRefund[index] && stacks[index] == nil {
            let added = min(limit, left)
            stacks[index] = ItemStack(itemID, added)
            left -= added
            touched[index] = true
        }
        return max(0, count) - left
    }
}

/// Everything one player's paste may be paid from: the inventory first, then storage.
struct TemplateMaterialStores {
    var inventory: TemplateMaterialSlots
    var storage: TemplateMaterialSlots

    init(inventory: TemplateMaterialSlots, storage: TemplateMaterialSlots = TemplateMaterialSlots(copying: [])) {
        self.inventory = inventory
        self.storage = storage
    }

    /// How many plain items of each kind the player can pay with.
    func available() -> [Int: Int] {
        inventory.plainCounts().merging(storage.plainCounts(), uniquingKeysWith: +)
    }
}

/// What a survival paste was paid for one item, and where it came from.
public struct TemplateMaterialReceiptLine: Equatable {
    public var itemID: Int
    public var fromInventory: Int
    public var fromStorage: Int

    public var paid: Int { fromInventory + fromStorage }
}

/// What one survival paste was paid. It travels with the paste's undo record
/// (`TemplatePlacementUndoSnapshot.materials`), so an undo can never pay back more than this.
public struct TemplateMaterialReceipt: Equatable {
    /// Ascending by item id; no line is empty.
    public private(set) var lines: [TemplateMaterialReceiptLine]

    public init(lines: [TemplateMaterialReceiptLine] = []) {
        self.lines = lines.filter { $0.paid > 0 && $0.fromInventory >= 0 && $0.fromStorage >= 0 }
            .sorted { $0.itemID < $1.itemID }
    }

    public var fromInventory: Int { lines.reduce(0) { $0 + $1.fromInventory } }
    public var fromStorage: Int { lines.reduce(0) { $0 + $1.fromStorage } }
    public var total: Int { fromInventory + fromStorage }

    public func paid(_ itemID: Int) -> Int {
        lines.first { $0.itemID == itemID }?.paid ?? 0
    }

    /// Takes `count` of `itemID` off the receipt because it is being given back, and says how
    /// much of it goes to the inventory and how much to storage: what came from the inventory
    /// returns there first. Never more than the receipt still holds.
    mutating func giveBack(itemID: Int, count: Int) -> (toInventory: Int, toStorage: Int) {
        guard let index = lines.firstIndex(where: { $0.itemID == itemID }) else { return (0, 0) }
        let amount = min(max(0, count), lines[index].paid)
        let toInventory = min(amount, lines[index].fromInventory)
        let toStorage = amount - toInventory
        lines[index].fromInventory -= toInventory
        lines[index].fromStorage -= toStorage
        if lines[index].paid <= 0 { lines.remove(at: index) }
        return (toInventory, toStorage)
    }
}

/// Takes `bill` from `stores`, the inventory first and then storage, and returns the receipt.
/// When anything is missing the result says what, and `stores` is left as it was.
func payTemplateMaterials(_ bill: TemplateMaterialBill,
                          from stores: inout TemplateMaterialStores) -> Result<TemplateMaterialReceipt, TemplateMaterialError> {
    let available = stores.available()
    let missing = bill.lines.compactMap { line -> TemplateMaterialLine? in
        let short = line.count - (available[line.itemID] ?? 0)
        return short > 0 ? TemplateMaterialLine(itemID: line.itemID, count: short) : nil
    }
    guard missing.isEmpty else { return .failure(.missing(missing)) }
    var lines: [TemplateMaterialReceiptLine] = []
    for line in bill.lines {
        let fromInventory = stores.inventory.take(itemID: line.itemID, count: line.count)
        let fromStorage = stores.storage.take(itemID: line.itemID, count: line.count - fromInventory)
        lines.append(TemplateMaterialReceiptLine(itemID: line.itemID, fromInventory: fromInventory,
                                                 fromStorage: fromStorage))
    }
    return .success(TemplateMaterialReceipt(lines: lines))
}

/// What became of a refund: how much went where, and what found no room.
struct TemplateMaterialRefund: Equatable {
    var toInventory = 0
    var toStorage = 0
    /// Ascending by item id.
    var leftover: [TemplateMaterialLine] = []

    var returned: Int { toInventory + toStorage }

    /// The free slots the leftover still needs.
    var leftoverStacks: Int {
        leftover.reduce(0) { total, line in
            let limit = line.itemID >= 0 && line.itemID < itemDefs.count ? max(1, itemDefs[line.itemID].maxStack) : 64
            return total + (line.count + limit - 1) / limit
        }
    }
}

/// Gives `materials` back into `stores`, but for each item no more than `receipt` still holds,
/// and takes what it gives back off the receipt. What came from the inventory returns there
/// and the rest to storage; either overflows into the other. `materials` maps item to count.
func refundTemplateMaterials(_ materials: [Int: Int], against receipt: inout TemplateMaterialReceipt,
                             into stores: inout TemplateMaterialStores) -> TemplateMaterialRefund {
    var refund = TemplateMaterialRefund()
    for itemID in materials.keys.sorted() {
        let share = receipt.giveBack(itemID: itemID, count: materials[itemID] ?? 0)
        var toInventory = stores.inventory.put(itemID: itemID, count: share.toInventory)
        var toStorage = stores.storage.put(itemID: itemID, count: share.toStorage)
        var left = share.toInventory + share.toStorage - toInventory - toStorage
        if left > 0 {
            let more = stores.inventory.put(itemID: itemID, count: left)
            toInventory += more
            left -= more
        }
        if left > 0 {
            let more = stores.storage.put(itemID: itemID, count: left)
            toStorage += more
            left -= more
        }
        refund.toInventory += toInventory
        refund.toStorage += toStorage
        if left > 0 { refund.leftover.append(TemplateMaterialLine(itemID: itemID, count: left)) }
    }
    return refund
}

/// The materials standing in the cells an undo is about to restore, counted only where the
/// restore really replaces what stands there. A cell that already holds what undo puts back
/// is left as it is, so nothing is paid for it.
func templateStandingMaterials(in world: World, restoring cells: [TemplatePlacementUndoCell]) -> [Int: Int] {
    var counts: [Int: Int] = [:]
    for cell in cells { addTemplateStandingMaterials(in: world, restoring: cell, to: &counts) }
    return counts
}

/// One cell of `templateStandingMaterials`. A tick-sliced undo calls this for each cell at the
/// moment it restores that cell, so the count never comes from an earlier picture of the world.
func addTemplateStandingMaterials(in world: World, restoring cell: TemplatePlacementUndoCell,
                                  to counts: inout [Int: Int]) {
    guard world.isLoadedAt(cell.x, cell.z), world.getBlock(cell.x, cell.y, cell.z) != cell.cell else { return }
    for line in templateStandingMaterials(in: world, cell.x, cell.y, cell.z) {
        counts[line.itemID, default: 0] += line.count
    }
}

/// What a paste paid for the blocks it could not write, the plants of the pots among them, and
/// the ground it did not have to fill.
func templateUnwrittenMaterials(of job: ObjectTemplatePlacementJob, result: TemplatePlacementResult) -> [Int: Int] {
    var counts: [Int: Int] = [:]
    for block in job.unplacedBlocks {
        if case .item(let itemID, let count) = templateCellCharge(Int(block.cell)) {
            counts[itemID, default: 0] += count
        }
    }
    for blockEntity in job.unplacedBlockEntities {
        if let plant = blockEntity.plant, let itemID = iidOpt(plant) { counts[itemID, default: 0] += 1 }
    }
    let unfilled = job.plannedSupportCellCount - result.supportBlocksFilled
    if unfilled > 0 { counts[iid("dirt"), default: 0] += unfilled }
    return counts
}

/// "Used 412 materials: 380 from your inventory, 32 from containers."
public func templateMaterialsUsedText(_ receipt: TemplateMaterialReceipt) -> String? {
    guard receipt.total > 0 else { return nil }
    return "Used \(templateMaterialCountText(receipt.total)): "
        + templateMaterialPlacesText(inventory: receipt.fromInventory, storage: receipt.fromStorage, toward: false)
}

/// "Returned 400 materials: 380 to your inventory, 20 to containers."
func templateMaterialsReturnedText(_ refund: TemplateMaterialRefund) -> String? {
    guard refund.returned > 0 else { return nil }
    return "Returned \(templateMaterialCountText(refund.returned)): "
        + templateMaterialPlacesText(inventory: refund.toInventory, storage: refund.toStorage, toward: true)
}

func templateMaterialCountText(_ count: Int) -> String {
    count == 1 ? "1 material" : "\(count) materials"
}

private func templateMaterialPlacesText(inventory: Int, storage: Int, toward: Bool) -> String {
    let word = toward ? "to" : "from"
    var parts: [String] = []
    if inventory > 0 { parts.append("\(inventory) \(word) your inventory") }
    if storage > 0 { parts.append("\(storage) \(word) containers") }
    return parts.joined(separator: ", ") + "."
}
