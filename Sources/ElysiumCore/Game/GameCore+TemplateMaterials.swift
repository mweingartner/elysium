import Foundation

// What a paste costs the player at this keyboard: a single-player world or a LAN host.
//
// A survival paste costs the items that place its blocks (`TemplateMaterials.swift`). They come
// from the player's inventory first and then from the containers crafting already pools,
// within `CRAFTING_CONTAINER_RADIUS`. Creative is free. A LAN guest's paste is placed and
// charged by the host from what the guest carries (`LANTemplatePayment.swift`); on a guest
// this file only says what a paste will cost.
//
// `/give` and `/gamemode` are open to the player of a single-player or host world, so this is a
// rule of normal play and not a barrier against cheating. The paste itself must still never
// hand out more than it was paid.

/// What a click on the armed preview places, and what it costs. `bill` is nil for a free paste.
struct TemplatePaste {
    let template: ObjectTemplate
    let options: TemplatePlacementOptions
    let bill: TemplateMaterialBill?
}

/// One line of what a paste would cost: how many are needed, and how many the player has.
public struct TemplateMaterialQuoteLine: Equatable {
    public let itemID: Int
    public let need: Int
    public let have: Int

    public var missing: Int { max(0, need - have) }
}

/// What pasting a template would cost the player now, before any ground has to be filled in.
public enum TemplateMaterialQuote: Equatable {
    /// Creative: the paste is free.
    case free
    /// Survival cannot place this object; the sentence names the block.
    case unplaceable(String)
    /// Missing materials first, then the most needed, then by name.
    case cost([TemplateMaterialQuoteLine])

    private var lines: [TemplateMaterialQuoteLine] {
        if case .cost(let lines) = self { return lines }
        return []
    }

    /// What is still missing, as bill lines.
    public var missing: [TemplateMaterialLine] {
        lines.filter { $0.missing > 0 }.map { TemplateMaterialLine(itemID: $0.itemID, count: $0.missing) }
    }

    /// One short line for the template browser.
    public var statusText: String {
        switch self {
        case .free:
            return "Free in Creative"
        case .unplaceable(let sentence):
            return String(sentence.prefix { $0 != "." })
        case .cost(let lines):
            let total = lines.reduce(0) { $0 + $1.need }
            let short = lines.filter { $0.missing > 0 }.count
            if lines.isEmpty { return "Costs nothing" }
            return short == 0 ? "Have all \(templateMaterialCountText(total))"
                              : "Missing \(short) of \(lines.count) \(lines.count == 1 ? "material" : "materials")"
        }
    }

    /// The cost as full sentences, for chat and for VoiceOver.
    public var sentence: String {
        switch self {
        case .free:
            return "Free in Creative."
        case .unplaceable(let sentence):
            return sentence
        case .cost(let lines):
            guard !lines.isEmpty else { return "Costs nothing." }
            let cost = "Costs \(templateMaterialCountText(lines.reduce(0) { $0 + $1.need }))."
            return missing.isEmpty ? cost + " You have them all."
                                   : cost + " Still missing \(templateMaterialListText(missing))."
        }
    }
}

/// The rows a local paste is paid from, with what is needed to write them back.
struct TemplateMaterialStoreAccess {
    var stores: TemplateMaterialStores
    fileprivate let storageSlots: [CraftingResourceSlot]

    /// Writes every changed slot back to the player and the containers.
    func commit(to player: Player, in world: World) {
        for index in stores.inventory.touchedSlots { player.inventory[index] = stores.inventory.stacks[index] }
        for index in stores.storage.touchedSlots {
            storageSlots[index].owner.set(stores.storage.stacks[index])
            storageSlots[index].owner.markDirty(in: world)
        }
    }
}

extension GameCore {
    /// Whether the player at this keyboard pastes for free.
    var templatePasteIsFree: Bool { player?.gameMode == GameMode.creative }

    /// The inventory and the pooled containers, as copies to work on. `excluded` names cells a
    /// placement or an undo is about to rewrite: a container standing there is neither paid
    /// from nor refunded into. A container whose loot has not been rolled takes no refund.
    func templateMaterialStores(excluding excluded: (TemplatePos) -> Bool) -> TemplateMaterialStoreAccess {
        var slots: [CraftingResourceSlot] = []
        if let center = craftingContainerPoolCenter(for: player, isLANClientWorld: isLANClientWorld) {
            slots = nearbyCraftingResourceSlots(in: world, centerX: center.x, centerY: center.y, centerZ: center.z,
                                                radius: CRAFTING_CONTAINER_RADIUS).filter { slot in
                if case .blockEntity(let blockEntity, _) = slot.owner {
                    return !excluded(TemplatePos(x: blockEntity.x, y: blockEntity.y, z: blockEntity.z))
                }
                return true
            }
        }
        let acceptsRefund = slots.map { slot -> Bool in
            if case .blockEntity(let blockEntity, _) = slot.owner, blockEntity.lootTable != nil { return false }
            return slot.owner.acceptsCraftingReturnDeposits
        }
        return TemplateMaterialStoreAccess(
            stores: TemplateMaterialStores(
                inventory: TemplateMaterialSlots(copying: player.inventory),
                storage: TemplateMaterialSlots(copying: slots.map { $0.owner.get() }, acceptsRefund: acceptsRefund)),
            storageSlots: slots)
    }

    /// What pasting `template` would cost the player now: the bill of its blocks against the
    /// inventory and the pooled containers. Dirt for ground the paste has to fill in is only
    /// known once the object is aimed, so it is not part of the quote.
    public func templateMaterialQuote(for template: ObjectTemplate) -> TemplateMaterialQuote {
        guard !templatePasteIsFree else { return .free }
        let bill: TemplateMaterialBill
        do {
            bill = try templateMaterialBill(templateForSurvivalPaste(template))
        } catch {
            return .unplaceable((error as? TemplateMaterialError)?.description ?? "Survival can't place this object.")
        }
        let available = templateMaterialStores(excluding: { _ in false }).stores.available()
        let lines = bill.lines.map {
            TemplateMaterialQuoteLine(itemID: $0.itemID, need: $0.count, have: available[$0.itemID] ?? 0)
        }
        return .cost(lines.sorted { a, b in
            if (a.missing > 0) != (b.missing > 0) { return a.missing > 0 }
            if a.need != b.need { return a.need > b.need }
            return itemDefs[a.itemID].displayName < itemDefs[b.itemID].displayName
        })
    }

    /// Arming a preview: refuses an object survival cannot place, and tells the player what
    /// the paste will cost and what is still missing. The click decides; the player may fetch
    /// what is missing first.
    func checkTemplateMaterialsOnArm(_ session: TemplatePlacementSession) throws {
        let quote = templateMaterialQuote(for: session.baseTemplate)
        switch quote {
        case .free:
            return
        case .unplaceable(let sentence):
            throw TemplateError.materials(sentence)
        case .cost(let lines):
            guard !lines.isEmpty else { return }
            host?.pushChat((quote.missing.isEmpty ? "§7" : "§e") + quote.sentence)
        }
    }

    /// What a click on `session`'s preview places and what it costs.
    func templatePaste(for session: TemplatePlacementSession) throws -> TemplatePaste {
        var options = TemplatePlacementOptions(prepareTerrain: true)
        guard !templatePasteIsFree else {
            return TemplatePaste(template: session.rotatedTemplate, options: options, bill: nil)
        }
        let template = templateForSurvivalPaste(session.rotatedTemplate)
        options.plainDirtSupport = true
        do {
            return TemplatePaste(template: template, options: options, bill: try templateMaterialBill(template))
        } catch let error as TemplateMaterialError {
            throw TemplateError.materials(error.description)
        }
    }

    /// Takes what `paste` costs, with dirt for the ground `job` will fill, and puts the receipt
    /// on the job. Throws, having changed nothing, when the player cannot pay. Call it once the
    /// job is admitted and before it is installed, so a refused paste costs nothing and a paid
    /// one cannot be refused afterwards.
    func chargeTemplateMaterials(_ paste: TemplatePaste, to job: ObjectTemplatePlacementJob) throws {
        guard let bill = paste.bill else { return }
        var access = templateMaterialStores(excluding: job.plans)
        switch payTemplateMaterials(bill.adding(itemID: iid("dirt"), count: job.plannedSupportCellCount),
                                    from: &access.stores) {
        case .success(let receipt):
            access.commit(to: player, in: world)
            job.materials = receipt
        case .failure(let error):
            throw TemplateError.materials(error.description)
        }
    }

    /// A finished job: gives back what was paid for blocks it could not write and ground it
    /// did not have to fill, and takes that off the receipt. Call it before the job's undo
    /// record is read. Returns what the paste used, for the chat.
    func settleTemplateMaterials(of job: ObjectTemplatePlacementJob) -> String? {
        guard var receipt = job.materials, let result = job.result else { return nil }
        let unwritten = templateUnwrittenMaterials(
            unplacedBlocks: job.unplacedBlocks,
            unfilledSupportCells: job.plannedSupportCellCount - result.supportBlocksFilled)
        if !unwritten.isEmpty {
            var access = templateMaterialStores(excluding: job.plans)
            let refund = refundTemplateMaterials(unwritten, against: &receipt, into: &access.stores)
            access.commit(to: player, in: world)
            dropTemplateMaterials(refund.leftover)
            job.materials = receipt
        }
        return templateMaterialsUsedText(receipt)
    }

    /// What undoing `undo` pays back, already checked for room. Nil, after telling the player,
    /// when the refund has nowhere to go: the undo must then change nothing. Undo runs in one
    /// step here, so what stands in the cells now is what the restore is about to remove.
    func templateUndoRefund(for undo: TemplatePlacementUndoSnapshot) -> (() -> Void)? {
        guard var receipt = undo.materials, receipt.total > 0 else { return {} }
        let restored = Set(undo.cells.map { TemplatePos(x: $0.x, y: $0.y, z: $0.z) })
        var access = templateMaterialStores(excluding: restored.contains)
        let refund = refundTemplateMaterials(templateStandingMaterials(in: world, restoring: undo.cells),
                                             against: &receipt, into: &access.stores)
        guard refund.leftover.isEmpty else {
            let text = TemplateMaterialError.noRoomForRefund(stacks: refund.leftoverStacks).description
            host?.pushChat("§c" + text)
            host?.showActionBar(text, 70)
            return nil
        }
        return { [self] in
            access.commit(to: player, in: world)
            if let text = templateMaterialsReturnedText(refund) { host?.pushChat("§7" + text) }
        }
    }

    /// Drops materials that found no room at the player's feet, in full stacks.
    private func dropTemplateMaterials(_ lines: [TemplateMaterialLine]) {
        for line in lines where line.itemID >= 0 && line.itemID < itemDefs.count {
            var left = line.count
            while left > 0 {
                let count = min(left, max(1, itemDefs[line.itemID].maxStack))
                _ = spawnItem(world, player.x, player.y + 0.5, player.z, ItemStack(line.itemID, count))
                left -= count
            }
        }
    }
}
