import Foundation

// What a LAN guest's survival paste costs, worked out on the host.
//
// A guest owns its inventory: it publishes it and the host keeps a copy. The host decides from
// that copy whether the guest can pay, takes the materials off the copy, and tells the guest
// what to remove with a grant that names items and not slots (`LANInventoryGrant.take`). A
// slot-by-slot correction would be computed from the copy, and if the guest had moved a stack
// since its last publish, writing those slots back would create or destroy items. A guest pays
// from what it carries only: the containers around it belong to the host's world, and crafting
// keeps a guest out of that pool for the same reason.
//
// A guest that edits its own client can publish any inventory, as it always could. What the
// host holds to is narrower: an unmodified client never ends up with blocks it did not pay for.

/// Whether a guest's paste is free: only in creative mode, and only when the host granted it.
/// The host already clamps a creative claim it has not granted; this does not rely on that.
func lanTemplatePasteIsFree(_ state: LANPlayerState, _ permissions: LANPeerPermissions) -> Bool {
    state.gameMode == GameMode.creative && permissions.canUseCreative
}

/// The host's copy of a guest's inventory as stacks, or nil when the copy is not well formed.
func lanTemplateInventoryStacks(_ inventory: LANPlayerInventorySnapshot?) -> [ItemStack?]? {
    guard let inventory else { return Array(repeating: nil, count: LAN_PLAYER_INVENTORY_SLOT_COUNT) }
    return makeInventory(from: inventory)
}

/// `inventory` with its slots replaced by `stacks`.
private func lanTemplateInventory(_ inventory: LANPlayerInventorySnapshot?, playerID: String,
                                  holding stacks: [ItemStack?]) -> LANPlayerInventorySnapshot {
    LANPlayerInventorySnapshot(
        playerID: playerID,
        selectedHotbarSlot: inventory?.selectedHotbarSlot ?? 0,
        slots: makeLANInventorySlotSnapshots(stacks),
        xp: inventory?.xp ?? 0,
        xpLevel: inventory?.xpLevel ?? 0,
        xpProgress: inventory?.xpProgress ?? 0)
}

/// So many plain items of one kind as grant entries, each no larger than a stack.
private func lanTemplateGrantEntries(itemID: Int, count: Int) -> [LANInventorySlotSnapshot] {
    guard itemID >= 0, itemID < itemDefs.count, count > 0 else { return [] }
    let limit = max(1, itemDefs[itemID].maxStack)
    var entries: [LANInventorySlotSnapshot] = []
    var left = count
    while left > 0 {
        entries.append(LANInventorySlotSnapshot(slot: 0, itemID: itemID, count: min(limit, left)))
        left -= min(limit, left)
    }
    return entries
}

/// A guest's payment as the host sees it.
struct LANTemplatePayment {
    let receipt: TemplateMaterialReceipt
    /// The host's copy after the payment.
    let inventory: LANPlayerInventorySnapshot
    /// What the guest must remove, for `LANInventoryGrant.take`.
    let take: [LANInventorySlotSnapshot]
}

/// Takes `bill` from the host's copy of a guest's inventory. Fails, with what is missing, when
/// the copy does not hold it; the copy is then unchanged.
func lanPayTemplateMaterials(_ bill: TemplateMaterialBill, from inventory: LANPlayerInventorySnapshot?,
                             playerID: String) -> Result<LANTemplatePayment, TemplateMaterialError> {
    guard let stacks = lanTemplateInventoryStacks(inventory) else { return .failure(.missing(bill.lines)) }
    var stores = TemplateMaterialStores(inventory: TemplateMaterialSlots(copying: stacks))
    switch payTemplateMaterials(bill, from: &stores) {
    case .failure(let error):
        return .failure(error)
    case .success(let receipt):
        return .success(LANTemplatePayment(
            receipt: receipt,
            inventory: lanTemplateInventory(inventory, playerID: playerID, holding: stores.inventory.stacks),
            take: receipt.lines.flatMap { lanTemplateGrantEntries(itemID: $0.itemID, count: $0.paid) }))
    }
}

/// A refund to a guest as the host sees it.
struct LANTemplateRefund {
    /// The host's copy after the refund.
    let inventory: LANPlayerInventorySnapshot
    /// What the guest is given, for `LANInventoryGrant.items`.
    let items: [LANInventorySlotSnapshot]
    /// What found no room in the copy; the host drops it beside the guest.
    let leftover: [TemplateMaterialLine]
    let returned: Int
}

/// Gives `materials` back into the host's copy of a guest's inventory, for each item no more
/// than `receipt` still holds, and takes it off the receipt.
func lanRefundTemplateMaterials(_ materials: [Int: Int], against receipt: inout TemplateMaterialReceipt,
                                into inventory: LANPlayerInventorySnapshot?, playerID: String) -> LANTemplateRefund {
    let stacks = lanTemplateInventoryStacks(inventory) ?? Array(repeating: nil, count: LAN_PLAYER_INVENTORY_SLOT_COUNT)
    var stores = TemplateMaterialStores(inventory: TemplateMaterialSlots(copying: stacks))
    let before = stores.inventory.plainCounts()
    let refund = refundTemplateMaterials(materials, against: &receipt, into: &stores)
    let after = stores.inventory.plainCounts()
    let items = after.keys.sorted().flatMap { itemID in
        lanTemplateGrantEntries(itemID: itemID, count: (after[itemID] ?? 0) - (before[itemID] ?? 0))
    }
    return LANTemplateRefund(
        inventory: lanTemplateInventory(inventory, playerID: playerID, holding: stores.inventory.stacks),
        items: items, leftover: refund.leftover, returned: refund.returned)
}

/// How many more free slots a refund of `materials` would need in the host's copy. Zero means
/// it fits. An undo is admitted only when this is zero, so an undo does not scatter stacks.
func lanTemplateRefundShortfall(_ materials: [Int: Int], receipt: TemplateMaterialReceipt,
                                inventory: LANPlayerInventorySnapshot?, playerID: String) -> Int {
    var scratch = receipt
    let refund = lanRefundTemplateMaterials(materials, against: &scratch, into: inventory, playerID: playerID)
    return TemplateMaterialRefund(leftover: refund.leftover).leftoverStacks
}

/// The payment the host has sent a guest and the guest has not yet said it applied. There is at
/// most one: the next paying paste is admitted only after the guest has applied this one.
struct LANTemplatePendingTake {
    let grantID: Int
    let take: [LANInventorySlotSnapshot]
}

/// An inventory the guest published, as the host must store it. A snapshot built before the
/// guest applied a take still holds what that take removes; stored as it is, it would put paid
/// materials back into the host's copy, and a guest that then died or reconnected would get
/// them a second time. So a take the snapshot does not include yet is taken out of it here,
/// with the function the guest itself will use.
func lanInventory(_ published: LANPlayerInventorySnapshot,
                  without pending: LANTemplatePendingTake?) -> LANPlayerInventorySnapshot {
    guard let pending, var stacks = makeInventory(from: published) else { return published }
    lanApplyTemplateTake(pending.take, to: &stacks)
    return lanTemplateInventory(published, playerID: published.playerID, holding: stacks)
}

/// A guest removes what the host took for its paste: plain stacks of each item, wherever they
/// sit now. An item the guest no longer holds is simply not there to remove.
func lanApplyTemplateTake(_ take: [LANInventorySlotSnapshot], to inventory: inout [ItemStack?]) {
    var slots = TemplateMaterialSlots(copying: inventory)
    for entry in take { _ = slots.take(itemID: entry.itemID, count: entry.count) }
    for index in slots.touchedSlots { inventory[index] = slots.stacks[index] }
}

/// What a sliced undo has seen standing in the cells it restored, counted as it restored them.
final class LANTemplateRefundTally {
    private(set) var standing: [Int: Int] = [:]

    func note(restoring cell: TemplatePlacementUndoCell, in world: World) {
        addTemplateStandingMaterials(in: world, restoring: cell, to: &standing)
    }
}
