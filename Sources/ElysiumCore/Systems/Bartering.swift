import Foundation

public enum VillagerProfession: String, Codable, CaseIterable, Sendable {
    case farmer, librarian, armorer, weaponsmith, toolsmith, cleric, butcher
    case fisherman, shepherd, fletcher, mason, cartographer, leatherworker

    public var displayName: String {
        switch self {
        case .farmer: "Farmer"
        case .librarian: "Librarian"
        case .armorer: "Armorer"
        case .weaponsmith: "Weaponsmith"
        case .toolsmith: "Toolsmith"
        case .cleric: "Cleric"
        case .butcher: "Butcher"
        case .fisherman: "Fisherman"
        case .shepherd: "Shepherd"
        case .fletcher: "Fletcher"
        case .mason: "Mason"
        case .cartographer: "Cartographer"
        case .leatherworker: "Leatherworker"
        }
    }
}

public enum NPCBarterMerchantKind: Equatable, Sendable {
    case villager(VillagerProfession)
    case wanderingTrader
}

public struct NPCBarterCostSnapshot: Equatable {
    public let stack: ItemStack
    public let playerCount: Int
    public let shortage: Int
}

/// An opaque, one-shot capability. It is deliberately not Codable and its
/// authority bindings are not publicly constructible or inspectable.
public struct NPCBarterReceipt: Equatable {
    let coreID: ObjectIdentifier
    let worldID: ObjectIdentifier
    let playerID: ObjectIdentifier
    let merchantID: ObjectIdentifier
    let merchantEntityID: Int
    let capabilityNonce: UInt64
    let nonce: UInt64
    let merchantRevision: UInt64
    let offerID: String
    let offerDigest: String
    let inventoryDigest: String
}

public struct NPCBarterOfferSnapshot: Equatable {
    public let id: String
    public let tier: Int
    public let costs: [NPCBarterCostSnapshot]
    public let output: ItemStack
    public let uses: Int
    public let maxUses: Int
    public let locked: Bool
    public let affordable: Bool
    public let outputFitsAfterPayment: Bool
    public let receipt: NPCBarterReceipt

    public var inStock: Bool { uses < maxUses }
    public var canTrade: Bool {
        !locked && inStock && affordable && outputFitsAfterPayment
    }
}

public struct NPCBarterSnapshot: Equatable {
    public let merchantKind: NPCBarterMerchantKind
    public let merchantEntityID: Int
    public let merchantRevision: UInt64
    public let header: String
    public let level: Int?
    public let xp: Int?
    public let nextLevelXP: Int?
    public let restockTicks: Int?
    public let hasWorkstation: Bool?
    public let wantedResourceNames: [String]
    public let offers: [NPCBarterOfferSnapshot]
}

public enum NPCBarterFailure: String, Error, Equatable {
    case unavailable
    case unauthorized
    case staleReceipt
    case replayedReceipt
    case merchantDetached
    case outOfRange
    case blockedLineOfSight
    case invalidOffer
    case tierLocked
    case outOfStock
    case missingPayment
    case inventoryFull
    case revisionExhausted
}

public struct NPCBarterCommit: Equatable {
    public let offerID: String
    public let output: ItemStack
    public let merchantRevision: UInt64
    public let newLevel: Int?
    public let levelChanged: Bool
}

/// Pure geometry shared by the AppKit trading screen and executable layout tests.
/// The smallest supported logical viewport is 360x224; the panel keeps a
/// four-point margin there while separating offer status from the inventory.
public struct NPCBarterScreenLayout: Equatable, Sendable {
    public let panelX: Double
    public let panelY: Double
    public let panelW: Double
    public let panelH: Double
    public let listX: Double
    public let listY: Double
    public let listW: Double
    public let listH: Double
    public let detailX: Double
    public let tradeX: Double
    public let tradeY: Double
    public let statusX: Double
    public let statusY: Double
    public let statusW: Double
    public let statusH: Double
    public let inventoryLabelX: Double
    public let inventoryLabelY: Double
    public let inventorySlotsX: Double
    public let inventorySlotsY: Double

    public static func make(viewWidth: Double, viewHeight: Double) -> Self {
        let panelW = min(340, max(300, viewWidth - 8))
        let panelH = min(224, max(216, viewHeight - 8))
        let panelX = ((viewWidth - panelW) / 2).rounded(.down)
        let panelY = ((viewHeight - panelH) / 2).rounded(.down)
        let listX = panelX + 8
        let listY = panelY + 32
        let listW = panelW - 184
        let listH = 140.0
        let detailX = panelX + panelW - 174
        return Self(
            panelX: panelX, panelY: panelY, panelW: panelW, panelH: panelH,
            listX: listX, listY: listY, listW: listW, listH: listH,
            detailX: detailX,
            tradeX: panelX + panelW - 86, tradeY: panelY + 68,
            statusX: listX + 2, statusY: listY + listH + 2,
            statusW: listW - 4, statusH: 20,
            inventoryLabelX: detailX, inventoryLabelY: panelY + panelH - 90,
            inventorySlotsX: panelX + panelW - 170,
            inventorySlotsY: panelY + panelH - 83)
    }
}

public func npcBarterRestockMessage(hasWorkstation: Bool?, restockTicks: Int?) -> String {
    guard hasWorkstation != false else { return "No workstation" }
    let ticks = max(0, restockTicks ?? 0)
    guard ticks > 0 else { return "Ready to restock at workstation" }
    let seconds = (ticks + 19) / 20
    let duration = seconds >= 60
        ? "\(seconds / 60)m" + (seconds % 60 == 0 ? "" : " \(seconds % 60)s")
        : "\(seconds)s"
    return "Restocks at workstation in \(duration)"
}

public func npcBarterSuccessMessage(_ result: NPCBarterCommit) -> String {
    let output = "\(result.output.count) \(itemDef(result.output.id).displayName)"
    if result.levelChanged {
        return "Trade complete: \(output) - level \(result.newLevel ?? 1) unlocked"
    }
    return "Trade complete: \(output)"
}

private let NPC_BARTER_MAX_OFFERS = 64
private let NPC_BARTER_MAX_OUTSTANDING_RECEIPTS = 256
private let NPC_BARTER_REACH_SQUARED = 36.0

private func merchantKind(_ merchant: Mob) -> NPCBarterMerchantKind? {
    if let villager = merchant as? Villager,
       let profession = VillagerProfession(rawValue: villager.profession) {
        return .villager(profession)
    }
    if merchant is WanderingTrader { return .wanderingTrader }
    return nil
}

private func merchantOffers(_ merchant: Mob) -> [TradeOffer]? {
    if let villager = merchant as? Villager { return villager.offers }
    if let trader = merchant as? WanderingTrader { return trader.offers }
    return nil
}

private func merchantRevision(_ merchant: Mob) -> UInt64? {
    if let villager = merchant as? Villager, !villager.barterUnavailable {
        return villager.barterRevision
    }
    if let trader = merchant as? WanderingTrader, !trader.barterUnavailable {
        return trader.barterRevision
    }
    return nil
}

private func copyOffer(_ offer: TradeOffer) -> TradeOffer {
    TradeOffer(buyA: offer.buyA.copy(), buyB: offer.buyB?.copy(), sell: offer.sell.copy(),
               maxUses: offer.maxUses, uses: offer.uses, xp: offer.xp,
               stableID: offer.stableID, unlockLevel: offer.unlockLevel)
}

private func validRuntimeOffer(_ offer: TradeOffer, expectedPrefix: String) -> Bool {
    validMerchantStack(offer.buyA) && (offer.buyB.map(validMerchantStack) ?? true)
        && validMerchantStack(offer.sell)
        && offer.maxUses > 0 && offer.maxUses <= 1_024
        && offer.uses >= 0 && offer.uses <= offer.maxUses
        && offer.xp >= 0 && offer.xp <= 1_000
        && offer.unlockLevel >= 1 && offer.unlockLevel <= 5
        && !offer.stableID.isEmpty && offer.stableID.utf8.count <= 96
        && offer.stableID.hasPrefix(expectedPrefix + ".")
}

private func offerDigest(_ offer: TradeOffer) -> String? {
    rpgSemanticInventoryDigest(offer)
}

private func matchingCount(_ cost: ItemStack, in inventory: [ItemStack?]) -> Int {
    inventory.reduce(into: 0) { total, candidate in
        if let candidate, stacksEqual(candidate, cost) { total += candidate.count }
    }
}

private func inventoryByPaying(_ costs: [ItemStack],
                               receiving output: ItemStack,
                               inventory: [ItemStack?]) -> [ItemStack?]? {
    guard inventory.count == 36 else { return nil }
    var result = inventory.map(copyStack)
    for cost in costs {
        var remaining = cost.count
        for index in result.indices where remaining > 0 {
            guard let candidate = result[index], stacksEqual(candidate, cost) else { continue }
            let take = min(candidate.count, remaining)
            candidate.count -= take
            remaining -= take
            if candidate.count == 0 { result[index] = nil }
        }
        if remaining != 0 { return nil }
    }
    let remainingOutput = output.copy()
    for index in result.indices where remainingOutput.count > 0 {
        guard let candidate = result[index], canMerge(candidate, remainingOutput) else { continue }
        let take = min(max(0, maxStackOf(candidate) - candidate.count), remainingOutput.count)
        candidate.count += take
        remainingOutput.count -= take
    }
    while remainingOutput.count > 0 {
        guard let empty = result.firstIndex(where: { $0 == nil }) else { return nil }
        let placed = remainingOutput.copy()
        placed.count = min(maxStackOf(placed), remainingOutput.count)
        remainingOutput.count -= placed.count
        result[empty] = placed
    }
    return result
}

private func merchantIsUsable(_ merchant: Mob, game: GameCore) -> NPCBarterFailure? {
    guard game.inWorld, !game.isLANClientWorld, let player = game.player else {
        return game.isLANClientWorld ? .unauthorized : .merchantDetached
    }
    let world = game.world
    let playerAttachments = world.entities.reduce(into: 0) { count, entity in
        if (entity as AnyObject) === player { count += 1 }
    }
    let merchantAttachments = world.entities.reduce(into: 0) { count, entity in
        if (entity as AnyObject) === merchant { count += 1 }
    }
    guard player.world === world, merchant.world === world,
          !player.dead, !merchant.dead,
          playerAttachments == 1, merchantAttachments == 1 else {
        return .merchantDetached
    }
    let coordinates = [player.x, player.y, player.z, merchant.x, merchant.y, merchant.z]
    guard coordinates.allSatisfy(\.isFinite) else { return .outOfRange }
    let distance = player.distanceToSq(merchant)
    guard distance.isFinite, distance <= NPC_BARTER_REACH_SQUARED else { return .outOfRange }
    guard player.canSee(merchant) else { return .blockedLineOfSight }
    return nil
}

public extension GameCore {
    @MainActor
    func prepareNPCBarter(for merchant: Mob) -> NPCBarterSnapshot? {
        guard merchantIsUsable(merchant, game: self) == nil,
              let player,
              let kind = merchantKind(merchant),
              let revision = merchantRevision(merchant), revision > 0,
              let sourceOffers = merchantOffers(merchant),
              sourceOffers.count <= NPC_BARTER_MAX_OFFERS,
              let inventoryDigest = rpgSemanticInventoryDigest(player.inventory)
        else { return nil }

        let prefix: String
        let level: Int
        switch kind {
        case .villager(let profession): prefix = profession.rawValue; level = (merchant as! Villager).tradeLevel
        case .wanderingTrader: prefix = "wandering"; level = 1
        }
        var seen = Set<String>()
        guard sourceOffers.allSatisfy({ validRuntimeOffer($0, expectedPrefix: prefix)
            && seen.insert($0.stableID).inserted }) else { return nil }

        if barterIssuedNonces.count + sourceOffers.count > NPC_BARTER_MAX_OUTSTANDING_RECEIPTS {
            barterIssuedNonces.removeAll(keepingCapacity: true)
        }
        guard barterNextNonce > 0,
              UInt64(sourceOffers.count) <= UInt64.max - barterNextNonce else { return nil }

        var wanted: [String] = []
        var wantedIDs = Set<Int>()
        var snapshots: [NPCBarterOfferSnapshot] = []
        snapshots.reserveCapacity(sourceOffers.count)
        for offer in sourceOffers {
            guard let digest = offerDigest(offer) else { return nil }
            let costs = [offer.buyA, offer.buyB].compactMap { $0 }
            for cost in costs where wantedIDs.insert(cost.id).inserted {
                wanted.append(itemDef(cost.id).displayName)
            }
            let costSnapshots = costs.map { cost -> NPCBarterCostSnapshot in
                let held = matchingCount(cost, in: player.inventory)
                return NPCBarterCostSnapshot(stack: cost.copy(), playerCount: held,
                                             shortage: max(0, cost.count - held))
            }
            let nonce = barterNextNonce
            barterNextNonce += 1
            barterIssuedNonces.insert(nonce)
            let receipt = NPCBarterReceipt(
                coreID: ObjectIdentifier(self), worldID: ObjectIdentifier(world),
                playerID: ObjectIdentifier(player), merchantID: ObjectIdentifier(merchant),
                merchantEntityID: merchant.id, capabilityNonce: barterCapabilityNonce,
                nonce: nonce, merchantRevision: revision,
                offerID: offer.stableID, offerDigest: digest, inventoryDigest: inventoryDigest)
            snapshots.append(NPCBarterOfferSnapshot(
                id: offer.stableID, tier: offer.unlockLevel, costs: costSnapshots,
                output: offer.sell.copy(), uses: offer.uses, maxUses: offer.maxUses,
                locked: offer.unlockLevel > level,
                affordable: costSnapshots.allSatisfy { $0.shortage == 0 },
                outputFitsAfterPayment: inventoryByPaying(costs, receiving: offer.sell,
                                                          inventory: player.inventory) != nil,
                receipt: receipt))
        }

        if let villager = merchant as? Villager,
           let profession = VillagerProfession(rawValue: villager.profession) {
            let thresholds = [0, 10, 70, 150, 250]
            return NPCBarterSnapshot(
                merchantKind: kind, merchantEntityID: merchant.id, merchantRevision: revision,
                header: "\(profession.displayName) - Level \(villager.tradeLevel)",
                level: villager.tradeLevel, xp: villager.tradeXP,
                nextLevelXP: villager.tradeLevel < 5 ? thresholds[villager.tradeLevel] : nil,
                restockTicks: villager.restockTimer,
                hasWorkstation: villager.hasValidWorkstation(),
                wantedResourceNames: wanted, offers: snapshots)
        }
        return NPCBarterSnapshot(
            merchantKind: kind, merchantEntityID: merchant.id, merchantRevision: revision,
            header: "Wandering Trader", level: nil, xp: nil, nextLevelXP: nil,
            restockTicks: nil, hasWorkstation: nil,
            wantedResourceNames: wanted, offers: snapshots)
    }

    @MainActor
    func commitNPCBarter(_ receipt: NPCBarterReceipt, merchant: Mob)
        -> Result<NPCBarterCommit, NPCBarterFailure> {
        guard receipt.coreID == ObjectIdentifier(self) else { return .failure(.unauthorized) }
        guard receipt.capabilityNonce == barterCapabilityNonce else { return .failure(.unauthorized) }
        guard barterIssuedNonces.remove(receipt.nonce) != nil else { return .failure(.replayedReceipt) }
        guard let player else { return .failure(.unavailable) }
        guard receipt.worldID == ObjectIdentifier(world),
              receipt.playerID == ObjectIdentifier(player),
              receipt.merchantID == ObjectIdentifier(merchant),
              receipt.merchantEntityID == merchant.id else { return .failure(.staleReceipt) }
        if let failure = merchantIsUsable(merchant, game: self) { return .failure(failure) }
        guard let revision = merchantRevision(merchant), revision == receipt.merchantRevision,
              let offers = merchantOffers(merchant), offers.count <= NPC_BARTER_MAX_OFFERS,
              let index = offers.firstIndex(where: { $0.stableID == receipt.offerID }),
              offers.filter({ $0.stableID == receipt.offerID }).count == 1 else {
            return .failure(.staleReceipt)
        }
        let offer = offers[index]
        guard let currentOfferDigest = offerDigest(offer), currentOfferDigest == receipt.offerDigest,
              let currentInventoryDigest = rpgSemanticInventoryDigest(player.inventory),
              currentInventoryDigest == receipt.inventoryDigest else { return .failure(.staleReceipt) }
        let level = (merchant as? Villager)?.tradeLevel ?? 1
        guard offer.unlockLevel <= level else { return .failure(.tierLocked) }
        guard offer.uses < offer.maxUses else { return .failure(.outOfStock) }
        let costs = [offer.buyA, offer.buyB].compactMap { $0 }
        guard costs.allSatisfy({ matchingCount($0, in: player.inventory) >= $0.count }) else {
            return .failure(.missingPayment)
        }
        guard let postInventory = inventoryByPaying(costs, receiving: offer.sell,
                                                    inventory: player.inventory) else {
            return .failure(.inventoryFull)
        }
        guard revision < UInt64.max else { return .failure(.revisionExhausted) }

        var postOffers = offers.map(copyOffer)
        postOffers[index].uses += 1
        let postRevision = revision + 1
        var postLevel: Int? = nil
        var levelChanged = false
        if let villager = merchant as? Villager {
            let thresholds = [0, 10, 70, 150, 250]
            let oldLevel = villager.tradeLevel
            var newLevel = oldLevel
            let newXP = min(1_000_000, max(0, villager.tradeXP) + max(0, offer.xp))
            while newLevel < 5 && newXP >= thresholds[newLevel] { newLevel += 1 }

            // Non-failing publication of fully detached post-state occurs before
            // sounds, particles, or advancement callbacks.
            player.inventory = postInventory
            villager.offers = postOffers
            villager.tradeXP = newXP
            villager.tradeLevel = newLevel
            villager.barterRevision = postRevision
            if villager.restockTimer == 0 { villager.restockTimer = 2_400 }
            postLevel = newLevel
            levelChanged = newLevel != oldLevel
        } else if let trader = merchant as? WanderingTrader {
            player.inventory = postInventory
            trader.offers = postOffers
            trader.barterRevision = postRevision
        } else {
            return .failure(.unavailable)
        }

        world.hooks.playSound("entity.villager.yes", merchant.x, merchant.y, merchant.z, 1, 1)
        if levelChanged { world.hooks.addParticles("heart", merchant.x, merchant.y + 2, merchant.z, 5, 0.4, 0) }
        advance("trade_villager")
        return .success(NPCBarterCommit(offerID: offer.stableID, output: offer.sell.copy(),
                                       merchantRevision: postRevision,
                                       newLevel: postLevel, levelChanged: levelChanged))
    }
}
