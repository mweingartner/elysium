import Foundation

// The LAN host's copy of what a guest carries, and the ways it changes.
//
// A guest owns its inventory. It tells the host what it holds in a snapshot (an inventory
// publish, or the inventory that comes with a container edit) and says with it which grant it
// had applied last. The host changes what a guest holds only by sending a grant, and applies
// every grant to its copy with the function the guest runs when the grant arrives
// (`lanApply(_:to:)`). So the copy is at every moment what the guest will hold once every
// grant on its way has arrived:
//
//     copy = the guest's latest snapshot, then every grant that snapshot does not include
//
// A snapshot that crosses a grant on the wire is behind it. The host keeps each grant until
// the guest names it as applied, and applies the grants a snapshot is behind before it checks
// or stores that snapshot (`guestInventory(_:appliedGrantID:of:)`). Without that, a crossed
// publish put paid materials back into the copy and dropped a refund or a pickup out of it.
//
// A grant follows stacks and never writes slots: the guest may have moved a stack since the
// host last heard from it, and a slot written from the host's copy would then create or destroy
// items. For the same reason no grant replaces a guest's inventory with the host's copy.
//
// The copy shows the 36 inventory slots. A guest also carries stacks the host does not see: in
// its off-hand, as armor, on the mouse cursor of an open screen. A grant that takes something
// away must reach those too, or one key press before it arrives saves the stack from it. So
// the guest's client looks in its off-hand and armor after its inventory (`pockets`), and
// first has an open screen hand back what it holds (`GameHost.returnStacksHeldByScreens`).

/// How many grants the host keeps for a guest that has not named them as applied. An unmodified
/// client names every grant within a tick. Past this the host forgets the oldest.
let LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS = 128

/// How many stacks those kept grants may name in all (`LANInventoryGrant.entryCount`). The host
/// applies every kept grant to each snapshot that is behind it, so this bounds what one
/// snapshot costs. Grants an unmodified client leaves unnamed for a moment name a few stacks
/// each; a way back after a refused container edit can name a whole inventory, and a modified
/// client can ask for one after another. More than any single grant can name (200).
let LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANT_ENTRIES = 256

/// One stack the host changed in a guest's inventory: a block it placed for the guest, a tool
/// that wore, an item the guest threw. `before` and `after` are the stack as the host's copy
/// held it (nil: nothing there), each naming the slot it sat in on the host. The guest makes
/// the same change to that stack wherever it sits now.
public struct LANInventoryStackChange: Codable, Equatable {
    public var before: LANInventorySlotSnapshot?
    public var after: LANInventorySlotSnapshot?

    public init(before: LANInventorySlotSnapshot?, after: LANInventorySlotSnapshot?) {
        self.before = before
        self.after = after
    }
}

/// The stacks that differ between two inventories, slot by slot, first slot first. A slot that
/// holds another item afterwards is two changes, one stack gone and one added: only the same
/// item in another state (a tool that wore) is one stack that became another.
func lanStackChanges(from before: LANPlayerInventorySnapshot?,
                     to after: LANPlayerInventorySnapshot) -> [LANInventoryStackChange] {
    var old: [Int: LANInventorySlotSnapshot] = [:]
    var new: [Int: LANInventorySlotSnapshot] = [:]
    for slot in before?.slots ?? [] { old[slot.slot] = slot }
    for slot in after.slots { new[slot.slot] = slot }
    return Set(old.keys).union(new.keys).sorted().flatMap { slot -> [LANInventoryStackChange] in
        guard old[slot] != new[slot] else { return [] }
        if let gone = old[slot], let added = new[slot], gone.itemID != added.itemID {
            return [LANInventoryStackChange(before: gone, after: nil), LANInventoryStackChange(before: nil, after: added)]
        }
        return [LANInventoryStackChange(before: old[slot], after: new[slot])]
    }
}

/// The stack a grant entry names, never above the item's stack size; nil when it names none.
func lanStack(_ entry: LANInventorySlotSnapshot) -> ItemStack? {
    guard entry.itemID >= 0, entry.itemID < itemDefs.count, entry.count > 0, entry.damage >= 0 else { return nil }
    let stack = ItemStack(entry.itemID, 1, damage: entry.damage, ench: entry.enchantments.map(\.enchantment),
                          label: entry.label,
                          data: makeLANStackData(craftingQuality: entry.craftingQuality, potion: entry.potion))
    stack.count = min(entry.count, maxStackOf(stack))
    return stack
}

private func lanStack(_ stack: ItemStack, count: Int) -> ItemStack {
    let copy = stack.copy()
    copy.count = count
    return copy
}

/// A stack as the host sees it: what travels on the wire, without slot and count.
private func lanWireForm(_ stack: ItemStack) -> LANInventorySlotSnapshot {
    LANInventorySlotSnapshot(
        slot: 0, itemID: stack.id, count: 1, damage: stack.damage, label: (stack.label ?? "").isEmpty ? nil : stack.label,
        craftingQuality: stack.data.craftingQuality, enchantments: stack.ench.map(LANItemEnchantmentSnapshot.init),
        potion: stack.data.potion)
}

/// Whether `held` is of the kind a grant names with `named`. The host knows a stack by what
/// travels on the wire: item, damage, label, quality, enchantments in one fixed order, potion.
/// A guest's own stack can hold more (the work an anvil did on it, a rocket's flight, its own
/// order of enchantments), which the host never saw. So the two are compared as the host sees
/// them: compared field by field, a guest would never find such a stack, and a change to it
/// (a toss, a tool's wear) would be skipped on the guest alone.
private func lanIsKind(_ held: ItemStack, _ named: ItemStack) -> Bool {
    var wire: LANInventorySlotSnapshot?
    return lanIsKind(held, named, &wire)
}

/// The same for one named stack looked for in many slots: its wire form is worked out once.
private func lanIsKind(_ held: ItemStack, _ named: ItemStack, _ namedWireForm: inout LANInventorySlotSnapshot?) -> Bool {
    guard held.id == named.id, held.damage == named.damage else { return false }
    if stacksEqual(held, named) { return true }
    if namedWireForm == nil { namedWireForm = lanWireForm(named) }
    return lanWireForm(held) == namedWireForm
}

/// `held` once the host has changed it into `new`: what the wire carries comes from `new`, and
/// what only the guest knows about its stack stays as it was.
private func lanStack(_ held: ItemStack, became new: ItemStack) -> ItemStack {
    guard held.id == new.id else { return new }
    let result = lanStack(held, count: new.count)
    result.damage = new.damage
    result.label = new.label
    result.data.craftingQuality = new.data.craftingQuality
    result.data.potion = new.data.potion
    if lanWireForm(held).enchantments != lanWireForm(new).enchantments { result.ench = new.ench }
    return result
}

/// Adds `stack` the way a player is given an item: onto stacks of its kind first, then into
/// the first empty slot. Returns how many found no room.
@discardableResult
func lanGive(_ stack: ItemStack, to inventory: inout [ItemStack?]) -> Int {
    var left = stack.count
    for index in inventory.indices where left > 0 {
        guard let held = inventory[index], canMerge(held, stack) else { continue }
        let added = min(maxStackOf(held) - held.count, left)
        guard added > 0 else { continue }
        inventory[index] = lanStack(held, count: held.count + added)
        left -= added
    }
    guard left > 0 else { return 0 }
    guard let empty = inventory.firstIndex(where: { $0 == nil }) else { return left }
    inventory[empty] = lanStack(stack, count: left)
    return 0
}

/// Every slot, `slot` first: where the host saw a stack is where the guest most likely has it.
private func lanSlots(startingAt slot: Int, in inventory: [ItemStack?]) -> [Int] {
    inventory.indices.contains(slot) ? [slot] + inventory.indices.filter { $0 != slot } : Array(inventory.indices)
}

/// Removes up to `count` of the kind of `stack`, looking in `slot` first, and returns how many
/// it removed. A guest that no longer holds them has none to remove.
@discardableResult
private func lanRemove(_ stack: ItemStack, count: Int, lookingFirstIn slot: Int, from inventory: inout [ItemStack?]) -> Int {
    var left = count
    var wire: LANInventorySlotSnapshot?
    for index in lanSlots(startingAt: slot, in: inventory) where left > 0 {
        guard let held = inventory[index], lanIsKind(held, stack, &wire) else { continue }
        let removed = min(held.count, left)
        left -= removed
        inventory[index] = held.count > removed ? lanStack(held, count: held.count - removed) : nil
    }
    return count - left
}

/// The slot that holds at least `stack.count` of the kind of `stack`, looking in `slot` first.
private func lanSlot(holding stack: ItemStack, lookingFirstIn slot: Int, in inventory: [ItemStack?]) -> Int? {
    var wire: LANInventorySlotSnapshot?
    return lanSlots(startingAt: slot, in: inventory).first { index in
        inventory[index].map { lanIsKind($0, stack, &wire) && $0.count >= stack.count } ?? false
    }
}

/// Adds `stack` in `slot` when that slot is empty or holds its kind with room for all of it,
/// and otherwise wherever a player would be given it.
private func lanPut(_ stack: ItemStack, in slot: Int, of inventory: inout [ItemStack?]) {
    if inventory.indices.contains(slot) {
        guard let held = inventory[slot] else {
            inventory[slot] = stack.copy()
            return
        }
        if canMerge(held, stack), held.count + stack.count <= maxStackOf(held) {
            inventory[slot] = lanStack(held, count: held.count + stack.count)
            return
        }
    }
    lanGive(stack, to: &inventory)
}

/// Makes one change the host made to a stack. The guest may have moved, split or spent that
/// stack since the host last heard from it, so the change follows the stack and never writes a
/// slot: what is no longer there is not removed, and a stack that became another one (a tool
/// that wore) is replaced only where the guest still holds the old one. What a change takes
/// away or replaces is looked for in `inventory` first and then in `pockets`; what it adds goes
/// into `inventory` only.
func lanApply(_ change: LANInventoryStackChange, to inventory: inout [ItemStack?], pockets: inout [ItemStack?]) {
    let old = change.before.flatMap(lanStack)
    let new = change.after.flatMap(lanStack)
    guard (old == nil) == (change.before == nil), (new == nil) == (change.after == nil) else { return }
    let slot = change.before?.slot ?? change.after?.slot ?? 0
    guard let old else {
        if let new { lanPut(new, in: slot, of: &inventory) }
        return
    }
    if let new, old.id != new.id {
        // Another item altogether: the old stack goes, as far as the guest holds it, and the
        // new one is added. (`lanStackChanges` sends these as two changes.)
        lanApply(LANInventoryStackChange(before: change.before, after: nil), to: &inventory, pockets: &pockets)
        lanPut(new, in: slot, of: &inventory)
        return
    }
    if let new, lanIsKind(old, new), new.count >= old.count {
        if new.count > old.count { lanPut(lanStack(new, count: new.count - old.count), in: slot, of: &inventory) }
        return
    }
    guard let new, !lanIsKind(old, new) else {
        // Fewer of the same kind, or none left.
        let gone = old.count - (new?.count ?? 0)
        let missing = gone - lanRemove(old, count: gone, lookingFirstIn: slot, from: &inventory)
        if missing > 0 { lanRemove(old, count: missing, lookingFirstIn: -1, from: &pockets) }
        return
    }
    // The same item in another state (a tool that wore): only where the guest still holds it.
    if let index = lanSlot(holding: old, lookingFirstIn: slot, in: inventory), let held = inventory[index] {
        inventory[index] = held.count == old.count ? lanStack(held, became: new) : lanStack(held, count: held.count - old.count)
        if held.count != old.count { lanGive(lanStack(held, became: new), to: &inventory) }
    } else if let index = lanSlot(holding: old, lookingFirstIn: -1, in: pockets), let held = pockets[index] {
        pockets[index] = held.count == old.count ? lanStack(held, became: new) : lanStack(held, count: held.count - old.count)
        if held.count != old.count { lanGive(lanStack(held, became: new), to: &inventory) }
    }
}

/// The same for an inventory with nothing outside it.
func lanApply(_ change: LANInventoryStackChange, to inventory: inout [ItemStack?]) {
    var none: [ItemStack?] = []
    lanApply(change, to: &inventory, pockets: &none)
}

/// What a guest does to what it carries when a grant arrives, and what the host does to its
/// copy of the guest's inventory when it sends one: one function, so the two cannot drift.
/// `pockets` are the places a guest carries stacks outside its inventory (off-hand, armor); the
/// host's copy has none. Returns how many of the grant's `items` found no room; the guest does
/// not get those.
@discardableResult
func lanApply(_ grant: LANInventoryGrant, to inventory: inout [ItemStack?], pockets: inout [ItemStack?]) -> Int {
    if grant.clearAll { for index in inventory.indices { inventory[index] = nil } }
    lanApplyTemplateTake(grant.take, to: &inventory, pockets: &pockets)
    for change in grant.changes { lanApply(change, to: &inventory, pockets: &pockets) }
    var unplaced = 0
    for entry in grant.items {
        if let stack = lanStack(entry) { unplaced += lanGive(stack, to: &inventory) }
    }
    return unplaced
}

/// The same for an inventory with nothing outside it: the host's copy.
@discardableResult
func lanApply(_ grant: LANInventoryGrant, to inventory: inout [ItemStack?]) -> Int {
    var none: [ItemStack?] = []
    return lanApply(grant, to: &inventory, pockets: &none)
}

/// A guest's client applies a grant to everything the player carries: the inventory, and for
/// what the grant takes away or replaces also the off-hand and the armor.
func lanApply(_ grant: LANInventoryGrant, to player: Player) {
    var pockets: [ItemStack?] = [player.offHand] + player.armor
    lanApply(grant, to: &player.inventory, pockets: &pockets)
    if pockets[0] !== player.offHand { player.offHand = pockets[0] }
    for index in player.armor.indices where pockets[index + 1] !== player.armor[index] {
        player.armor[index] = pockets[index + 1]
    }
}

/// A guest's experience after `points` more, counted as `Player.addXP` counts it.
private func lanExperience(xp: Int, level: Int, progress: Double, adding points: Int) -> (xp: Int, level: Int, progress: Double) {
    var level = level
    var needed = Double(lanXPRequiredForLevel(level))
    var held = progress * needed + Double(points)
    while held >= needed {
        held -= needed
        level = min(100_000, level + 1)
        needed = Double(lanXPRequiredForLevel(level))
    }
    return (max(0, min(1_000_000_000, xp + points)), level, needed > 0 ? max(0, min(1, held / needed)) : 0)
}

/// `inventory` once `grants` have been applied to it in order, each as the guest applies it,
/// and how many granted items found no room on the way. nil when `inventory` is not well formed.
func lanInventory(_ inventory: LANPlayerInventorySnapshot,
                  applying grants: [LANInventoryGrant]) -> (inventory: LANPlayerInventorySnapshot, unplaced: Int)? {
    guard var stacks = makeInventory(from: inventory) else { return nil }
    guard !grants.isEmpty else { return (inventory, 0) }
    var unplaced = 0
    var experience = (xp: inventory.xp, level: inventory.xpLevel, progress: inventory.xpProgress)
    for grant in grants {
        unplaced += lanApply(grant, to: &stacks)
        if grant.xp > 0 {
            experience = lanExperience(xp: experience.xp, level: experience.level, progress: experience.progress,
                                       adding: grant.xp)
        }
    }
    return (LANPlayerInventorySnapshot(
        playerID: inventory.playerID, selectedHotbarSlot: inventory.selectedHotbarSlot,
        slots: makeLANInventorySlotSnapshots(stacks), xp: experience.xp, xpLevel: experience.level,
        xpProgress: experience.progress), unplaced)
}

extension LANMultiplayerHostSession {
    /// The only way the host changes what a guest carries: a pickup or a refund (`items`), a
    /// payment (`take`), what a ghost did for the guest (`changes`), a death (`clearAll`). The
    /// grant is applied to the host's copy here, with the guest's own function, and kept until
    /// the guest names it as applied. `grantID` rises by one per peer, so a guest applies each
    /// grant once. With `onlyIfItFits`, a grant whose `items` have no room in the copy is not
    /// made at all. A caller gives `items` only as far as the copy has room for them (a pickup
    /// all or none, a refund what fits): a stack the copy could not take is one the guest may
    /// still find room for, and the copy would then lack it. A grant with nothing in it changes
    /// nothing and asks the guest to say what it holds.
    @discardableResult
    public func enqueueGrant(
        items: [LANInventorySlotSnapshot],
        xp: Int,
        clearAll: Bool,
        to rawPlayerID: String,
        take: [LANInventorySlotSnapshot] = [],
        changes: [LANInventoryStackChange] = [],
        onlyIfItFits: Bool = false
    ) -> LANInventoryGrant? {
        issueGrant(items: items, xp: xp, clearAll: clearAll, to: rawPlayerID, take: take, changes: changes,
                   onlyIfItFits: onlyIfItFits, theCopyAlreadyHoldsIt: false)
    }

    /// Makes, keeps and queues one grant. `theCopyAlreadyHoldsIt` is for the one grant that
    /// leads a guest back from a refused container edit (`correctRefusedContainerEdit`): the
    /// host never took that edit, so only the guest and a snapshot behind the grant apply it.
    private func issueGrant(
        items: [LANInventorySlotSnapshot], xp: Int, clearAll: Bool, to rawPlayerID: String,
        take: [LANInventorySlotSnapshot], changes: [LANInventoryStackChange],
        onlyIfItFits: Bool, theCopyAlreadyHoldsIt: Bool
    ) -> LANInventoryGrant? {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID] else { return nil }
        let grant = LANInventoryGrant(
            playerID: peer.playerID, grantID: peer.lastGrantID + 1, items: items, xp: xp, clearAll: clearAll,
            take: take, changes: changes)
        if !theCopyAlreadyHoldsIt {
            let copy = peer.inventory ?? LANPlayerInventorySnapshot(
                playerID: peer.playerID, selectedHotbarSlot: peer.playerState?.selectedHotbarSlot ?? 0, slots: [])
            // A copy that is not well formed (a damaged save) takes no grant until the guest publishes.
            guard let granted = lanInventory(copy, applying: [grant]), !onlyIfItFits || granted.unplaced == 0 else { return nil }
            peer.inventory = granted.inventory
            // What the guest last said it holds will hold this grant too.
            peer.heardInventory = peer.heardInventory.flatMap { lanInventory($0, applying: [grant])?.inventory }
        }
        peer.lastGrantID = grant.grantID
        // A grant that empties the inventory leaves nothing of the grants before it.
        if grant.clearAll {
            peer.unacknowledgedGrants.removeAll()
            peer.forgottenGrantID = 0
        }
        if grant.changesInventory { peer.unacknowledgedGrants.append(grant) }
        // A guest that names no grant as applied (a stalled or a modified client) cannot make
        // the host keep them without end, nor keep so much that every snapshot is dear to
        // check. The host forgets the oldest and from then on takes no snapshot that is behind
        // it: the copy stays what the guest will hold.
        var entries = peer.unacknowledgedGrants.reduce(0) { $0 + $1.entryCount }
        while peer.unacknowledgedGrants.count > LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS
                || (entries > LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANT_ENTRIES && peer.unacknowledgedGrants.count > 1) {
            let forgotten = peer.unacknowledgedGrants.removeFirst()
            peer.forgottenGrantID = forgotten.grantID
            entries -= forgotten.entryCount
        }
        peers[playerID] = peer
        pendingGrants[playerID, default: []].append(grant)
        return grant
    }

    /// What a guest's snapshot will be once the guest has applied every grant it had not
    /// applied when it built the snapshot. This is the inventory the host checks and stores for
    /// a publish and for a container edit alike, and the one place that says which snapshots
    /// it takes at all: one that is newer than the stored one, well formed, and not behind a
    /// grant the host has forgotten (it could only be stored short of what the guest will hold).
    func guestInventory(_ snapshot: LANPlayerInventorySnapshot, revision: Int, appliedGrantID: Int,
                        of peer: Peer) -> Result<LANPlayerInventorySnapshot, LANGuestSnapshotRefusal> {
        guard revision > peer.inventoryRevision else { return .failure(.stale) }
        guard appliedGrantID >= peer.forgottenGrantID else { return .failure(.behind) }
        guard let normalized = normalizedLANInventorySnapshot(snapshot) else { return .failure(.malformed) }
        let held = LANPlayerInventorySnapshot(
            playerID: peer.playerID, selectedHotbarSlot: normalized.selectedHotbarSlot, slots: normalized.slots,
            xp: normalized.xp, xpLevel: normalized.xpLevel, xpProgress: normalized.xpProgress)
        guard let arrived = lanInventory(held, applying: peer.unacknowledgedGrants.filter { $0.grantID > appliedGrantID }) else {
            return .failure(.malformed)
        }
        return .success(arrived.inventory)
    }

    /// Makes `inventory`, as `guestInventory` returned it, the host's copy, and forgets the
    /// grants the guest has now named as applied.
    func storeGuestInventory(_ inventory: LANPlayerInventorySnapshot, revision: Int, appliedGrantID: Int,
                             in peer: inout Peer) {
        peer.inventory = inventory
        peer.heardInventory = inventory
        peer.inventoryRevision = revision
        peer.unacknowledgedGrants.removeAll { $0.grantID <= appliedGrantID }
    }

    /// The host received an inventory from a guest and did not make it its copy: the transport
    /// dropped the publish while the host caught up. It is still what the guest holds, and the
    /// way back from a refused container edit leads there (`Peer.heardInventory`).
    public func noteInventoryHeard(_ update: LANInventoryUpdate, from rawPlayerID: String) {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID],
              case .success(let heard) = guestInventory(update.snapshot, revision: update.revision,
                                                        appliedGrantID: update.appliedGrantID, of: peer)
        else { return }
        peer.heardInventory = heard
        peers[playerID] = peer
    }

    /// A ghost acted for a guest (broke or placed a block, struck, shot, threw an item) and
    /// left `inventory` of the host's copy. The guest is sent each stack that changed.
    @discardableResult
    public func recordGhostInventory(_ inventory: LANPlayerInventorySnapshot,
                                     for rawPlayerID: String) -> LANInventoryGrant? {
        let playerID = String(rawPlayerID.prefix(128))
        guard let peer = peers[playerID], let after = normalizedLANInventorySnapshot(inventory) else { return nil }
        let changes = lanStackChanges(from: peer.inventory, to: after)
        guard !changes.isEmpty else { return nil }
        return enqueueGrant(items: [], xp: 0, clearAll: false, to: playerID, changes: changes)
    }

    /// Commits what a guest's proxy picked up: into the host's copy and, with the same grant,
    /// into the guest's own inventory. All of it or none: a pickup the copy has no room for
    /// stays with the proxy. No other field of the cosmetic proxy is trusted or copied back.
    @discardableResult
    func applyAuthoritativePickupMutation(_ mutation: LANAuthoritativePickupMutation,
                                          for rawPlayerID: String) -> LANInventoryGrant? {
        guard mutation.items.count <= LAN_MULTIPLAYER_MAX_GRANT_ITEMS,
              !mutation.items.isEmpty || mutation.xp > 0,
              mutation.xp >= 0, mutation.xp <= 1_000_000_000,
              mutation.items.allSatisfy({ item in
                  item.itemID >= 0 && item.itemID < itemDefs.count && item.damage >= 0
                      && item.count > 0 && item.count <= itemDefs[item.itemID].maxStack
              })
        else { return nil }
        return enqueueGrant(items: mutation.items, xp: mutation.xp, clearAll: false, to: rawPlayerID,
                            onlyIfItFits: true)
    }

    /// One container a guest's edit names: the edit as the host reads it, the container as the
    /// host holds it, and the block entity the edit would be written to.
    struct EditedContainer {
        let edit: LANBlockEntitySnapshot
        let held: LANBlockEntitySnapshot
        let target: BlockEntityData
    }

    /// Finds the container `raw` names for a guest standing at `playerState`, or says why the
    /// guest may not edit it. A container the host has never opened is empty.
    func editedContainer(_ raw: LANBlockEntitySnapshot, by playerState: LANPlayerState,
                         in world: World) -> Result<EditedContainer, LANContainerEditRefusal> {
        guard let edit = normalizedLANBlockEntitySnapshot(raw) else { return .failure(.invalidPayload) }
        guard isWithinLANReach(playerState, x: edit.x, y: edit.y, z: edit.z) else { return .failure(.outOfReach) }
        guard edit.dimension == world.dim.rawValue else { return .failure(.otherDimension) }
        guard isLANBlockEntitySnapshotCompatible(edit, cell: world.getBlock(edit.x, edit.y, edit.z)) else {
            return .failure(.incompatibleTarget)
        }
        let existing = world.getBlockEntity(edit.x, edit.y, edit.z)
        let target = existing?.type == edit.type ? existing! : makeBlockEntity(from: edit)
        guard let held = makeLANBlockEntitySnapshot(target, dimension: world.dim.rawValue), held.type == edit.type else {
            return .failure(.notVerifiable)
        }
        return .success(EditedContainer(edit: edit, held: held, target: target))
    }

    /// The host refused a guest's container edit, but the guest made that edit on its own side
    /// before it asked. This hands the guest's inventory back and returns the containers the
    /// edit named as the host holds them, for the guest alone.
    ///
    /// The inventory the edit carries, with the grants on their way applied, is what the guest
    /// holds on its side of the refused edit. The guest is granted the changes that lead from
    /// there to what it held before the edit: the last inventory it told the host of
    /// (`Peer.heardInventory`). It undoes its own move, wherever those stacks are by then, and
    /// nothing else it carries is touched. The way back does not lead to the host's copy: the
    /// copy can be behind what the guest holds (a publish the host did not take), and a way back
    /// to it would hand out again whatever the guest has spent or put away since. The grant is
    /// kept for a snapshot that is behind it, and changes neither the copy nor what was heard.
    ///
    /// An edit whose inventory the host would not take as a snapshot (not newer than the stored
    /// one, malformed, too far behind) says nothing about what the guest holds now. It gets no
    /// way back and no container either: a container put right beside an inventory left as it
    /// is would leave the moved items in both.
    ///
    /// A container the guest could not have edited from where it stands is left out, so a
    /// refusal tells a guest nothing it could not already see.
    public func correctRefusedContainerEdit(_ intent: LANContainerEditIntent, from rawPlayerID: String,
                                            in world: World) -> [LANBlockEntitySnapshot] {
        let playerID = String(rawPlayerID.prefix(128))
        guard let peer = peers[playerID], peer.lifecycle != .disconnected,
              let before = peer.heardInventory ?? peer.inventory,
              case .success(let held) = guestInventory(intent.inventory, revision: intent.revision,
                                                       appliedGrantID: intent.appliedGrantID, of: peer)
        else { return [] }
        let back = lanStackChanges(from: held, to: before)
        if !back.isEmpty {
            _ = issueGrant(items: [], xp: 0, clearAll: false, to: playerID, take: [], changes: back,
                           onlyIfItFits: false, theCopyAlreadyHoldsIt: true)
        }
        guard let playerState = peer.playerState, playerState.dimension == world.dim.rawValue else { return [] }
        var seen = Set<LANBlockPosition>()
        return ([intent.blockEntity] + intent.additionalBlockEntities).compactMap { raw -> LANBlockEntitySnapshot? in
            guard case .success(let container) = editedContainer(raw, by: playerState, in: world),
                  seen.insert(LANBlockPosition(dimension: container.held.dimension, x: container.held.x,
                                               y: container.held.y, z: container.held.z)).inserted
            else { return nil }
            return container.held
        }
    }
}

/// Why the host does not take an inventory a guest sent.
enum LANGuestSnapshotRefusal: String, Error {
    case stale = "stale inventory revision"
    case malformed = "invalid inventory payload"
    case behind = "inventory is behind grants the host no longer keeps"
}

/// Why the host does not take a container a guest's edit names.
enum LANContainerEditRefusal: String, Error {
    case invalidPayload = "invalid container payload"
    case outOfReach = "target out of reach"
    case otherDimension = "target dimension unavailable"
    case incompatibleTarget = "incompatible container target"
    case notVerifiable = "container edit is not host-verifiable"
}

extension LANInventoryGrant {
    /// Whether applying this grant can change an inventory. One that cannot only asks the guest
    /// to say what it holds, and the host need not keep it.
    var changesInventory: Bool {
        clearAll || xp > 0 || !items.isEmpty || !take.isEmpty || !changes.isEmpty
    }

    /// How many stacks this grant names: what applying it to an inventory costs.
    var entryCount: Int { take.count + changes.count + items.count }
}
