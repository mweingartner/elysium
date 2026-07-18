import XCTest
@testable import ElysiumCore

final class NPCBarterTests: XCTestCase {
    func testTradingLayoutKeepsCompactStatusInventoryAndActionDisjoint() {
        for viewport in [(360.0, 224.0), (420.0, 260.0), (800.0, 600.0)] {
            let layout = NPCBarterScreenLayout.make(viewWidth: viewport.0, viewHeight: viewport.1)
            XCTAssertGreaterThanOrEqual(layout.panelX, 4)
            XCTAssertGreaterThanOrEqual(layout.panelY, 4)
            XCTAssertLessThanOrEqual(layout.panelX + layout.panelW, viewport.0 - 4)
            XCTAssertLessThanOrEqual(layout.panelY + layout.panelH, viewport.1 - 4)
            XCTAssertGreaterThanOrEqual(layout.statusY, layout.listY + layout.listH)
            XCTAssertLessThanOrEqual(layout.statusY + layout.statusH,
                                     layout.panelY + layout.panelH)
            XCTAssertLessThanOrEqual(layout.tradeY + 18, layout.inventoryLabelY)
            XCTAssertLessThan(layout.statusX + layout.statusW, layout.inventoryLabelX)
            XCTAssertLessThan(layout.inventoryLabelY, layout.inventorySlotsY)
            XCTAssertLessThanOrEqual(layout.inventorySlotsY + 72,
                                     layout.panelY + layout.panelH)
        }
    }

    func testTradingStatusCopyNamesWorkstationAndTradedResult() throws {
        registerAllBlocks()
        registerAllItems()
        XCTAssertEqual(npcBarterRestockMessage(hasWorkstation: false, restockTicks: 2_400),
                       "No workstation")
        XCTAssertEqual(npcBarterRestockMessage(hasWorkstation: true, restockTicks: 2_400),
                       "Restocks at workstation in 2m")
        XCTAssertEqual(npcBarterRestockMessage(hasWorkstation: true, restockTicks: 0),
                       "Ready to restock at workstation")
        let output = ItemStack(iid("emerald"), 2)
        let commit = NPCBarterCommit(offerID: "farmer.1", output: output,
                                     merchantRevision: 2, newLevel: nil, levelChanged: false)
        XCTAssertEqual(npcBarterSuccessMessage(commit), "Trade complete: 2 Emerald")
        let levelCommit = NPCBarterCommit(offerID: "farmer.2", output: output,
                                          merchantRevision: 3, newLevel: 2, levelChanged: true)
        XCTAssertEqual(npcBarterSuccessMessage(levelCommit),
                       "Trade complete: 2 Emerald - level 2 unlocked")
    }
    private func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
        try MainActor.assumeIsolated(body)
    }

    private func makeGame(_ label: String) throws -> GameCore {
        let db = try PersistenceTestSupport.makeDatabase(owner: self, label: "barter-\(label)")
        let game = GameCore(db: db)
        onMain {
            game.createWorld(name: "Barter \(label)", seedText: "7717",
                             mode: GameMode.survival, difficulty: 2)
        }
        game.player.setPos(0.5, 65, 0.5)
        return game
    }

    private func installMerchant(_ profession: String, in game: GameCore) -> Villager {
        let villager = Villager(world: game.world)
        villager.setPos(0.5, 65, 3.5)
        villager.profession = profession
        villager.refreshTrades()
        game.world.addEntity(villager)
        return villager
    }

    private func installPayment(for offer: TradeOffer, in player: Player) {
        player.inventory = Array(repeating: nil, count: 36)
        player.inventory[0] = offer.buyA.copy()
        if let buyB = offer.buyB { player.inventory[1] = buyB.copy() }
    }

    private func inventoryBytes(_ inventory: [ItemStack?]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(inventory)
    }

    func testSnapshotExposesProfessionWantsCompleteCatalogAndTwoCosts() throws {
        let game = try makeGame("snapshot")
        let villager = installMerchant("fletcher", in: game)
        let snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }

        XCTAssertEqual(snapshot.header, "Fletcher - Level 1")
        XCTAssertEqual(snapshot.offers.count, villager.offers.count)
        XCTAssertGreaterThan(snapshot.offers.count, 7)
        XCTAssertTrue(snapshot.offers.contains { $0.costs.count == 2 })
        XCTAssertTrue(snapshot.offers.contains { $0.tier > 1 && $0.locked })
        XCTAssertTrue(snapshot.wantedResourceNames.contains("Gravel"))
        XCTAssertTrue(snapshot.wantedResourceNames.contains("Flint"))
        XCTAssertEqual(Set(snapshot.offers.map(\.id)).count, snapshot.offers.count)
    }

    func testSuccessfulTradeIsAtomicAndReceiptIsOneShot() throws {
        let game = try makeGame("success")
        let villager = installMerchant("farmer", in: game)
        let index = try XCTUnwrap(villager.offers.firstIndex { $0.unlockLevel == 1 })
        installPayment(for: villager.offers[index], in: game.player)
        let beforeUses = villager.offers[index].uses
        let snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        let prepared = try XCTUnwrap(snapshot.offers.first { $0.id == villager.offers[index].stableID })

        let result = onMain { game.commitNPCBarter(prepared.receipt, merchant: villager) }
        let commit = try result.get()
        XCTAssertEqual(commit.offerID, prepared.id)
        XCTAssertEqual(villager.offers[index].uses, beforeUses + 1)
        XCTAssertEqual(game.player.countItem(prepared.output.id), prepared.output.count)
        XCTAssertEqual(villager.restockTimer, 2_400)
        XCTAssertTrue(game.advancements.has("trade_villager"))

        let inventoryAfter = try inventoryBytes(game.player.inventory)
        let usesAfter = villager.offers[index].uses
        XCTAssertEqual(onMain { game.commitNPCBarter(prepared.receipt, merchant: villager) },
                       .failure(.replayedReceipt))
        XCTAssertEqual(try inventoryBytes(game.player.inventory), inventoryAfter)
        XCTAssertEqual(villager.offers[index].uses, usesAfter)
    }

    func testPaymentCanCreateOutputCapacityInAFullInventory() throws {
        let game = try makeGame("capacity")
        let villager = installMerchant("farmer", in: game)
        let index = try XCTUnwrap(villager.offers.firstIndex {
            $0.unlockLevel == 1 && $0.buyB == nil && $0.sell.id != $0.buyA.id
        })
        let offer = villager.offers[index]
        let filler = ItemStack(iid("cobblestone"), 64)
        game.player.inventory = (0..<36).map { _ in filler.copy() }
        game.player.inventory[0] = offer.buyA.copy()

        let snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        let prepared = try XCTUnwrap(snapshot.offers.first { $0.id == offer.stableID })
        XCTAssertTrue(prepared.outputFitsAfterPayment)
        XCTAssertTrue(prepared.canTrade)
        _ = try onMain { game.commitNPCBarter(prepared.receipt, merchant: villager) }.get()
        XCTAssertEqual(game.player.countItem(offer.sell.id), offer.sell.count)
    }

    func testFullInventoryFailureLeavesInventoryAndMerchantUntouched() throws {
        let game = try makeGame("full")
        let villager = installMerchant("farmer", in: game)
        let index = try XCTUnwrap(villager.offers.firstIndex {
            $0.unlockLevel == 1 && $0.buyB == nil
                && maxStackOf($0.buyA) > $0.buyA.count
                && $0.sell.id != iid("cobblestone")
        })
        let offer = villager.offers[index]
        game.player.inventory = (0..<36).map { _ in ItemStack(iid("cobblestone"), 64) }
        game.player.inventory[0] = ItemStack(offer.buyA.id, maxStackOf(offer.buyA),
                                             damage: offer.buyA.damage,
                                             ench: offer.buyA.ench,
                                             label: offer.buyA.label,
                                             data: offer.buyA.data)
        let beforeInventory = try inventoryBytes(game.player.inventory)
        let beforeOffers = villager.offers
        let snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        let prepared = try XCTUnwrap(snapshot.offers.first { $0.id == offer.stableID })
        XCTAssertFalse(prepared.outputFitsAfterPayment)

        XCTAssertEqual(onMain { game.commitNPCBarter(prepared.receipt, merchant: villager) },
                       .failure(.inventoryFull))
        XCTAssertEqual(try inventoryBytes(game.player.inventory), beforeInventory)
        XCTAssertEqual(villager.offers, beforeOffers)
    }

    func testStaleAndOutOfRangeAttemptsAreFailureAtomic() throws {
        let game = try makeGame("stale")
        let villager = installMerchant("farmer", in: game)
        let offer = try XCTUnwrap(villager.offers.first { $0.unlockLevel == 1 })
        installPayment(for: offer, in: game.player)
        let first = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        let receipt = try XCTUnwrap(first.offers.first { $0.id == offer.stableID }).receipt
        game.player.inventory[5] = ItemStack(iid("stick"), 1)
        let before = try inventoryBytes(game.player.inventory)
        XCTAssertEqual(onMain { game.commitNPCBarter(receipt, merchant: villager) },
                       .failure(.staleReceipt))
        XCTAssertEqual(try inventoryBytes(game.player.inventory), before)
        XCTAssertEqual(villager.offers.first { $0.stableID == offer.stableID }?.uses, 0)

        game.player.inventory[5] = nil
        let second = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        let rangeReceipt = try XCTUnwrap(second.offers.first { $0.id == offer.stableID }).receipt
        game.player.setPos(100, 65, 100)
        XCTAssertEqual(onMain { game.commitNPCBarter(rangeReceipt, merchant: villager) },
                       .failure(.outOfRange))
        XCTAssertEqual(villager.offers.first { $0.stableID == offer.stableID }?.uses, 0)
    }

    func testCompetingPreparedReceiptsCommitAtMostOnce() throws {
        let game = try makeGame("compete")
        let villager = installMerchant("farmer", in: game)
        let offer = try XCTUnwrap(villager.offers.first { $0.unlockLevel == 1 })
        installPayment(for: offer, in: game.player)
        let one = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        let two = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        let r1 = try XCTUnwrap(one.offers.first { $0.id == offer.stableID }).receipt
        let r2 = try XCTUnwrap(two.offers.first { $0.id == offer.stableID }).receipt

        XCTAssertNoThrow(try onMain { game.commitNPCBarter(r1, merchant: villager) }.get())
        XCTAssertEqual(onMain { game.commitNPCBarter(r2, merchant: villager) },
                       .failure(.staleReceipt))
        XCTAssertEqual(villager.offers.first { $0.stableID == offer.stableID }?.uses, 1)
    }

    func testProgressionPreservesEarlierOfferIdentityAndUses() throws {
        let game = try makeGame("level")
        let villager = installMerchant("farmer", in: game)
        villager.tradeXP = 9
        let offer = try XCTUnwrap(villager.offers.first { $0.unlockLevel == 1 && $0.xp > 0 })
        installPayment(for: offer, in: game.player)
        let beforeIDs = villager.offers.map(\.stableID)
        let snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        let receipt = try XCTUnwrap(snapshot.offers.first { $0.id == offer.stableID }).receipt

        let commit = try onMain { game.commitNPCBarter(receipt, merchant: villager) }.get()
        XCTAssertTrue(commit.levelChanged)
        XCTAssertEqual(villager.tradeLevel, 2)
        XCTAssertEqual(villager.offers.map(\.stableID), beforeIDs)
        XCTAssertEqual(villager.offers.first { $0.stableID == offer.stableID }?.uses, 1)
    }

    func testMerchantPersistenceCapsRepairsAndRejectsDuplicates() throws {
        registerAllBlocks(); registerAllItems(); registerAllEntities()
        let world = World(dim: .overworld, seed: 8)
        var rng = RandomX(99)
        var canonical = tradesFor("farmer", 1, &rng)[0]
        canonical.uses = 1
        let duplicateBytes = try JSONEncoder().encode([canonical, canonical])
        let duplicateRaw = try JSONSerialization.jsonObject(with: duplicateBytes)
        let villager = Villager(world: world)
        villager.load(["profession": "farmer", "tradeLevel": 99, "tradeXP": -50,
                       "offers": duplicateRaw])
        XCTAssertEqual(villager.tradeLevel, 5)
        XCTAssertEqual(villager.tradeXP, 0)
        var expectedRNG = RandomX(villager.barterSeed)
        XCTAssertEqual(villager.offers.count, tradesFor("farmer", 5, &expectedRNG).count)
        XCTAssertEqual(Set(villager.offers.map(\.stableID)).count, villager.offers.count)
        XCTAssertTrue(villager.offers.allSatisfy { $0.uses == 0 })

        let oversized = Array(repeating: duplicateRaw, count: MERCHANT_MAX_RAW_OFFERS + 1)
        let repaired = Villager(world: world)
        repaired.load(["profession": "farmer", "offers": oversized])
        XCTAssertLessThanOrEqual(repaired.offers.count, MERCHANT_MAX_RAW_OFFERS)
        XCTAssertEqual(repaired.offers.count, tradesFor("farmer", 5, &rng).count)
        XCTAssertEqual(Set(repaired.offers.map(\.stableID)).count, repaired.offers.count)
    }

    func testMerchantPersistenceRejectsStorageBoundaryStringBeforeSecondaryMaterialization() {
        let storageBoundaryString = String(repeating: "x", count: 67_108_864)
        let raw: [Any] = [["stableID": storageBoundaryString]]
        XCTAssertFalse(merchantRawPayloadWithinBudget(raw))
        XCTAssertTrue(decodeMerchantOffers(raw, profession: "farmer").isEmpty)
    }

    func testMerchantPersistenceRejectsDeepTreesAndContainerContents() throws {
        var nested: Any = NSNumber(value: 1)
        for _ in 0...MERCHANT_MAX_RAW_DEPTH { nested = ["nested": nested] }
        XCTAssertFalse(merchantRawPayloadWithinBudget([nested]))
        XCTAssertTrue(decodeMerchantOffers([nested], profession: "farmer").isEmpty)

        var rng = RandomX(101)
        let canonical = tradesFor("farmer", 1, &rng)[0]
        let bytes = try JSONEncoder().encode(canonical)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var buyA = try XCTUnwrap(raw["buyA"] as? [String: Any])
        var data = try XCTUnwrap(buyA["data"] as? [String: Any])
        data["contents"] = Array(repeating: NSNull(), count: 28)
        buyA["data"] = data
        raw["buyA"] = buyA
        XCTAssertTrue(decodeMerchantOffers([raw], profession: "farmer").isEmpty)
    }

    func testMerchantIntegerDecoderRejectsEveryTrappingAndNonIntegerBoundary() {
        let twoTo63 = pow(2.0, 63.0)
        XCTAssertNil(merchantInt(NSNumber(value: Double(Int.max))))
        XCTAssertNil(merchantInt(NSNumber(value: twoTo63)))
        XCTAssertEqual(merchantInt(NSNumber(value: Double(Int.min))), Int.min)
        let adjacentUpper = twoTo63.nextDown
        XCTAssertEqual(merchantInt(NSNumber(value: adjacentUpper)), Int(adjacentUpper))
        XCTAssertNil(merchantInt(NSNumber(value: Double.infinity)))
        XCTAssertNil(merchantInt(NSNumber(value: -Double.infinity)))
        XCTAssertNil(merchantInt(NSNumber(value: Double.nan)))
        XCTAssertNil(merchantInt(NSNumber(value: 1.5)))
        XCTAssertNil(merchantInt(NSNumber(value: true)))
    }

    func testAnyInvalidMerchantOfferRejectsTheCompletePayload() throws {
        registerAllBlocks(); registerAllItems()
        var rng = RandomX(303)
        let canonical = Array(tradesFor("farmer", 5, &rng).prefix(2))
        let bytes = try JSONEncoder().encode(canonical)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])

        raw[1]["maxUses"] = NSNumber(value: -1)
        XCTAssertTrue(decodeMerchantOffers(raw, profession: "farmer").isEmpty)

        raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        raw[1]["stableID"] = raw[0]["stableID"]
        XCTAssertTrue(decodeMerchantOffers(raw, profession: "farmer").isEmpty)

        raw = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
        raw[1]["unlockLevel"] = "not-an-integer"
        XCTAssertTrue(decodeMerchantOffers(raw, profession: "farmer").isEmpty)
    }

    func testWanderingTraderPersistsUsesAndDoesNotExposeLevelOrRestock() throws {
        let game = try makeGame("wandering")
        let trader = WanderingTrader(world: game.world)
        trader.setPos(0.5, 65, 3.5)
        trader.offers[0].uses = 2
        trader.barterRevision = 9
        game.world.addEntity(trader)
        let snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: trader)) }
        XCTAssertEqual(snapshot.header, "Wandering Trader")
        XCTAssertNil(snapshot.level)
        XCTAssertNil(snapshot.restockTicks)

        let loaded = WanderingTrader(world: game.world)
        loaded.load(trader.save())
        XCTAssertEqual(loaded.offers.map(\.stableID), trader.offers.map(\.stableID))
        XCTAssertEqual(loaded.offers.map(\.uses), trader.offers.map(\.uses))
        XCTAssertEqual(loaded.barterRevision, 9)
    }

    func testLANClientCannotPrepareOrCommitBarter() throws {
        let game = try makeGame("lan-denial")
        let localMerchant = installMerchant("farmer", in: game)
        let offer = try XCTUnwrap(localMerchant.offers.first { $0.unlockLevel == 1 })
        installPayment(for: offer, in: game.player)
        let localSnapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: localMerchant)) }
        let receipt = try XCTUnwrap(localSnapshot.offers.first { $0.id == offer.stableID }).receipt

        onMain {
            game.enterLANClientWorld(LANWorldSummary(
                worldID: "barter-host", worldName: "Barter Host", seed: 99,
                gameMode: GameMode.survival, difficulty: 2,
                dimension: Dim.overworld.rawValue, playerCount: 2))
        }
        let mirrorMerchant = installMerchant("farmer", in: game)
        XCTAssertNil(onMain { game.prepareNPCBarter(for: mirrorMerchant) })
        XCTAssertEqual(onMain { game.commitNPCBarter(receipt, merchant: mirrorMerchant) },
                       .failure(.staleReceipt))
        XCTAssertTrue(mirrorMerchant.offers.allSatisfy { $0.uses == 0 })
    }

    func testTwoCostOfferConsumesBothCostsExactly() throws {
        let game = try makeGame("two-cost")
        let villager = installMerchant("fletcher", in: game)
        let offer = try XCTUnwrap(villager.offers.first { $0.unlockLevel == 1 && $0.buyB != nil })
        installPayment(for: offer, in: game.player)
        let snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        let prepared = try XCTUnwrap(snapshot.offers.first { $0.id == offer.stableID })
        XCTAssertEqual(prepared.costs.count, 2)

        _ = try onMain { game.commitNPCBarter(prepared.receipt, merchant: villager) }.get()
        XCTAssertEqual(game.player.countItem(offer.buyA.id), 0)
        XCTAssertEqual(game.player.countItem(try XCTUnwrap(offer.buyB).id), 0)
        XCTAssertEqual(game.player.countItem(offer.sell.id), offer.sell.count)
    }

    func testTierStockAttachmentAndMerchantIdentityRejectionsAreAtomic() throws {
        let game = try makeGame("rejections")
        let villager = installMerchant("farmer", in: game)

        let locked = try XCTUnwrap(villager.offers.first { $0.unlockLevel > 1 })
        installPayment(for: locked, in: game.player)
        var snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        var receipt = try XCTUnwrap(snapshot.offers.first { $0.id == locked.stableID }).receipt
        XCTAssertEqual(onMain { game.commitNPCBarter(receipt, merchant: villager) },
                       .failure(.tierLocked))

        let availableIndex = try XCTUnwrap(villager.offers.firstIndex { $0.unlockLevel == 1 })
        villager.offers[availableIndex].uses = villager.offers[availableIndex].maxUses
        villager.bumpBarterRevision()
        let soldOut = villager.offers[availableIndex]
        installPayment(for: soldOut, in: game.player)
        snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        receipt = try XCTUnwrap(snapshot.offers.first { $0.id == soldOut.stableID }).receipt
        XCTAssertEqual(onMain { game.commitNPCBarter(receipt, merchant: villager) },
                       .failure(.outOfStock))

        villager.offers[availableIndex].uses = 0
        villager.bumpBarterRevision()
        installPayment(for: villager.offers[availableIndex], in: game.player)
        snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        receipt = try XCTUnwrap(snapshot.offers.first { $0.id == villager.offers[availableIndex].stableID }).receipt
        let other = installMerchant("farmer", in: game)
        XCTAssertEqual(onMain { game.commitNPCBarter(receipt, merchant: other) },
                       .failure(.staleReceipt))

        snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
        receipt = try XCTUnwrap(snapshot.offers.first { $0.id == villager.offers[availableIndex].stableID }).receipt
        game.world.removeEntity(villager)
        XCTAssertEqual(onMain { game.commitNPCBarter(receipt, merchant: villager) },
                       .failure(.merchantDetached))
        XCTAssertEqual(villager.offers[availableIndex].uses, 0)
    }

    func testValidWorkstationRestocksOnlyUsesAndAdvancesRevision() throws {
        let game = try makeGame("restock")
        let villager = installMerchant("farmer", in: game)
        let chunk = Chunk(cx: 0, cz: 0, minY: game.world.info.minY, height: game.world.info.height)
        chunk.status = .lit
        game.world.setChunk(chunk)
        XCTAssertEqual(game.world.setBlock(2, 65, 3, Int(cell(B.composter, 0))), 0)
        villager.workstation = (2, 65, 3)
        villager.offers[0].uses = 3
        villager.restockTimer = 1
        let ids = villager.offers.map(\.stableID)
        let revision = villager.barterRevision

        villager.tick()

        XCTAssertTrue(villager.offers.allSatisfy { $0.uses == 0 })
        XCTAssertEqual(villager.offers.map(\.stableID), ids)
        XCTAssertEqual(villager.restockTimer, 0)
        XCTAssertEqual(villager.barterRevision, revision + 1)
    }

    func testCatalogWideConservationPropertyForEveryFarmerOffer() throws {
        let game = try makeGame("conservation")
        let villager = installMerchant("farmer", in: game)
        villager.tradeLevel = 5
        for source in villager.offers {
            guard let current = villager.offers.first(where: { $0.stableID == source.stableID }) else {
                return XCTFail("offer identity disappeared")
            }
            installPayment(for: current, in: game.player)
            let snapshot = try onMain { try XCTUnwrap(game.prepareNPCBarter(for: villager)) }
            let prepared = try XCTUnwrap(snapshot.offers.first { $0.id == current.stableID })
            _ = try onMain { game.commitNPCBarter(prepared.receipt, merchant: villager) }.get()

            let totalCount = game.player.inventory.compactMap { $0 }.reduce(0) { $0 + $1.count }
            XCTAssertEqual(totalCount, current.sell.count,
                           "only the declared output may remain for \(current.stableID)")
            XCTAssertEqual(game.player.countItem(current.sell.id), current.sell.count)
        }
    }

    func testOutstandingReceiptSetRemainsBoundedAcrossRepeatedRefresh() throws {
        let game = try makeGame("receipt-bound")
        let villager = installMerchant("farmer", in: game)
        for _ in 0..<80 {
            XCTAssertNotNil(onMain { game.prepareNPCBarter(for: villager) })
            XCTAssertLessThanOrEqual(game.barterIssuedNonces.count, 256)
        }
    }
}
