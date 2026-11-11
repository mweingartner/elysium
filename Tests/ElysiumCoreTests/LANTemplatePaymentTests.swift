import XCTest
@testable import ElysiumCore

/// What a LAN guest's survival paste costs, on the host (`LANTemplatePayment.swift`,
/// `LANHostTemplateJobs.swift`). The guest owns its inventory and the host keeps a copy: the
/// host charges from the copy and tells the guest what to remove, by item and not by slot.
final class LANTemplatePaymentTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    // MARK: - fixtures

    /// Chunks (0,0) and (1,0), flat dirt at y 63.
    private func loadedWorld() -> World {
        let world = World(dim: .overworld, seed: 42)
        for cx in 0...1 {
            let chunk = Chunk(cx: cx, cz: 0, minY: world.info.minY, height: world.info.height)
            for z in 0..<CHUNK_W { for x in 0..<CHUNK_W { chunk.set(x, 63, z, cell(B.dirt, 0)) } }
            chunk.status = .generated
            world.setChunk(chunk)
        }
        return world
    }

    private func playerState(gameMode: Int = GameMode.survival, dead: Bool = false) -> LANPlayerState {
        LANPlayerState(playerID: "guest", displayName: "Alex", x: 2.5, y: 64, z: 1.5, yaw: 0, pitch: 0,
                       health: dead ? 0 : 20, hunger: 20, selectedHotbarSlot: 0, gameMode: gameMode, dead: dead)
    }

    private func hostSession(carrying items: [(String, Int)] = []) -> LANMultiplayerHostSession {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        session.updatePlayerState(playerState())
        if !items.isEmpty { carry(session, items) }
        return session
    }

    private func carry(_ session: LANMultiplayerHostSession, _ items: [(String, Int)]) {
        let slots = items.enumerated().map { LANInventorySlotSnapshot(slot: $0.offset, itemID: iid($0.element.0), count: $0.element.1) }
        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: slots), from: "guest")
    }

    /// The guest publishes what it carries, saying which grants it had applied when it looked.
    @discardableResult
    private func publish(_ session: LANMultiplayerHostSession, _ items: [(String, Int)], revision: Int,
                         applied: Int, selectedHotbarSlot: Int = 0) -> Bool {
        let slots = items.enumerated().map { LANInventorySlotSnapshot(slot: $0.offset, itemID: iid($0.element.0), count: $0.element.1) }
        return session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: revision,
            snapshot: LANPlayerInventorySnapshot(playerID: "", selectedHotbarSlot: selectedHotbarSlot, slots: slots),
            appliedGrantID: applied), from: "guest")
    }

    /// What the host believes the guest carries, by item name.
    private func hostCopy(_ session: LANMultiplayerHostSession) -> [String: Int] {
        var counts: [String: Int] = [:]
        for slot in session.peerInventorySnapshotsByPlayerID()["guest"]?.slots ?? [] {
            counts[itemDefs[slot.itemID].name, default: 0] += slot.count
        }
        return counts
    }

    private func row(_ block: String, _ count: Int, name: String = "Row", meta: Int = 0) -> ObjectTemplate {
        ObjectTemplate(name: name, anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: count, sizeY: 1, sizeZ: 1,
                       blocks: (0..<count).map { TemplateBlock(dx: $0, dy: 0, dz: 0, cell: cell(bid(block), meta)) })
    }

    private func placeIntent(_ template: ObjectTemplate, x: Int = 4, y: Int = 64, z: Int = 4,
                             appliedGrantID: Int = 0, inventoryRevision: Int = 0) throws -> LANTemplateIntent {
        LANTemplateIntent(action: .placeTemplate, templateName: template.name, x: x, y: y, z: z, rotation: 0,
                          templateData: try lanGuestTemplatePayload(for: template), appliedGrantID: appliedGrantID,
                          inventoryRevision: inventoryRevision)
    }

    private func undoIntent(appliedGrantID: Int = 0, inventoryRevision: Int = 0) -> LANTemplateIntent {
        LANTemplateIntent(action: .undoPlacement, templateName: "", x: 0, y: 0, z: 0, rotation: 0,
                          appliedGrantID: appliedGrantID, inventoryRevision: inventoryRevision)
    }

    private func finish(_ session: LANMultiplayerHostSession, in world: World, budgetPerPeer: Int = 2_048,
                        between steps: (Int) -> Void = { _ in }) -> [LANTemplateIntentResult] {
        var step = 0
        while session.hasActiveTemplateJob(playerID: "guest") {
            steps(step)
            session.stepTemplateJobs(in: world, budgetPerPeer: budgetPerPeer)
            step += 1
            if step > 100_000 { XCTFail("the template job did not finish"); break }
        }
        return session.drainTemplateIntentResponses().map(\.result)
    }

    private func dropped(_ world: World, _ name: String) -> Int {
        world.entities.compactMap { $0 as? ItemEntity }.filter { $0.stack.id == iid(name) }.reduce(0) { $0 + $1.stack.count }
    }

    private func takeCount(_ grants: [LANInventoryGrant], _ name: String) -> Int {
        grants.flatMap(\.take).filter { $0.itemID == iid(name) }.reduce(0) { $0 + $1.count }
    }

    private func itemCount(_ grants: [LANInventoryGrant], _ name: String) -> Int {
        grants.flatMap(\.items).filter { $0.itemID == iid(name) }.reduce(0) { $0 + $1.count }
    }

    // MARK: - Who pays

    func testOnlyCreativeTheHostGrantedIsFree() {
        let granted = LANPeerPermissions(canUseCreative: true)
        XCTAssertTrue(lanTemplatePasteIsFree(playerState(gameMode: GameMode.creative), granted))
        XCTAssertFalse(lanTemplatePasteIsFree(playerState(gameMode: GameMode.creative), LANPeerPermissions()))
        XCTAssertFalse(lanTemplatePasteIsFree(playerState(gameMode: GameMode.survival), granted))
        XCTAssertFalse(lanTemplatePasteIsFree(playerState(gameMode: 7), granted), "an unknown mode pays")
    }

    func testAGuestThatClaimsCreativeWithoutTheGrantStillPays() throws {
        let world = loadedWorld()
        let session = hostSession()
        session.updatePlayerState(playerState(gameMode: GameMode.creative))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 3)), from: "guest", world: world),
                       .rejected("Missing 3 Oak Planks - nothing was placed."))
        XCTAssertEqual(world.getBlock(4, 64, 4), 0)
    }

    func testAGuestWithGrantedCreativePastesForFreeAsBefore() throws {
        let world = loadedWorld()
        let session = hostSession()
        session.setPermissions(LANPeerPermissions(canUseCreative: true), for: "guest")
        session.updatePlayerState(playerState(gameMode: GameMode.creative))
        let full = row("composter", 1, meta: 8)
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(full), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        XCTAssertEqual(session.drainGrants(for: "guest").count, 0, "nothing to pay")
        XCTAssertEqual(finish(session, in: world), [.placed(name: "Row", blocks: 1, blockEntities: 0, cleared: 0, filled: 0)])
        XCTAssertEqual(world.getBlock(4, 64, 4), Int(cell(B.composter, 8)), "a creative paste keeps what the template holds")
        // Its undo pays nothing, also after the grant is withdrawn.
        session.setPermissions(LANPeerPermissions(), for: "guest")
        session.updatePlayerState(playerState())
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        XCTAssertEqual(finish(session, in: world), [.undone(name: "Row", restored: 1)])
        XCTAssertEqual(session.drainGrants(for: "guest").count, 0)
    }

    // MARK: - Paying

    func testASurvivalGuestPaysFromWhatItCarriesAndIsToldWhatToRemove() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 10), ("glass", 2)])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 6)), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 4, "glass": 2], "the host's copy is charged at admission")
        XCTAssertEqual(world.getBlock(4, 64, 4), 0, "and before the first block is placed")
        let grants = session.drainGrants(for: "guest")
        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(takeCount(grants, "oak_planks"), 6)
        XCTAssertEqual(grants[0].items.count + grants[0].slots.count + grants[0].clearedSlots.count, 0,
                       "by item, never by slot")
        XCTAssertEqual(finish(session, in: world), [.placed(name: "Row", blocks: 6, blockEntities: 0, cleared: 0, filled: 0,
                                                            payment: "Used 6 materials.")])
        for dx in 0..<6 { XCTAssertEqual(world.getBlockId(4 + dx, 64, 4), Int(B.oak_planks)) }
    }

    func testAGuestThatCannotPayIsRefusedAndNothingChanges() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 2)])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 6)), from: "guest", world: world),
                       .rejected("Missing 4 Oak Planks - nothing was placed."))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 2])
        XCTAssertEqual(session.drainGrants(for: "guest").count, 0)
        XCTAssertFalse(session.hasActiveTemplateJob(playerID: "guest"))
        for dx in 0..<6 { XCTAssertEqual(world.getBlock(4 + dx, 64, 4), 0) }
        // A guest that has never published an inventory has nothing to pay with.
        let silent = hostSession()
        XCTAssertEqual(silent.applyTemplateIntent(try placeIntent(row("oak_planks", 1)), from: "guest", world: world),
                       .rejected("Missing 1 Oak Planks - nothing was placed."))
    }

    func testARefusalListsAtMostFourKindsAndFitsAnEvent() throws {
        let world = loadedWorld()
        let kinds = ["oak_planks", "glass", "torch", "stone", "cobblestone", "bricks", "oak_log", "bookshelf"]
        let many = ObjectTemplate(name: "Many", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: kinds.count, sizeY: 1, sizeZ: 1,
                                  blocks: kinds.enumerated().map { TemplateBlock(dx: $0.offset, dy: 0, dz: 0, cell: cell(bid($0.element), 0)) })
        guard case .rejected(let reason) = hostSession().applyTemplateIntent(try placeIntent(many), from: "guest", world: world) else {
            return XCTFail("nothing was carried")
        }
        XCTAssertTrue(reason.hasSuffix("and 4 more kinds - nothing was placed."), reason)
        XCTAssertLessThan(reason.utf8.count, 512)
    }

    func testAPayingGuestsPasteIsPlacedUngrownEmptyAndOnDirt() throws {
        let world = loadedWorld()
        world.setBlock(4, 62, 4, Int(cell(B.stone)), SET_SILENT)
        world.setBlock(4, 63, 4, 0, SET_SILENT)            // a gap one deep under the first block ...
        world.setBlock(3, 63, 4, Int(cell(B.sand)), SET_SILENT)   // ... with sand beside it
        let session = hostSession(carrying: [("composter", 1), ("respawn_anchor", 1), ("dirt", 3)])
        let object = ObjectTemplate(name: "Stateful", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 2, sizeY: 1, sizeZ: 1, blocks: [
            TemplateBlock(dx: 0, dy: 0, dz: 0, cell: cell(B.composter, 8)),
            TemplateBlock(dx: 1, dy: 0, dz: 0, cell: cell(B.respawn_anchor, 4)),
        ])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(object), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Stateful"))
        XCTAssertEqual(takeCount(session.drainGrants(for: "guest"), "dirt"), 1, "the ground it fills costs dirt")
        _ = finish(session, in: world)
        XCTAssertEqual(world.getBlock(4, 64, 4), Int(cell(B.composter, 0)))
        XCTAssertEqual(world.getBlock(5, 64, 4), Int(cell(B.respawn_anchor, 0)))
        XCTAssertEqual(world.getBlockId(4, 63, 4), Int(B.dirt), "dirt, not the sand beside the gap")
        XCTAssertEqual(hostCopy(session), ["dirt": 2])

        let short = hostSession(carrying: [("composter", 1), ("respawn_anchor", 1)])
        let again = loadedWorld()
        again.setBlock(4, 62, 4, Int(cell(B.stone)), SET_SILENT)
        again.setBlock(4, 63, 4, 0, SET_SILENT)
        XCTAssertEqual(short.applyTemplateIntent(try placeIntent(object), from: "guest", world: again),
                       .rejected("Missing 1 Dirt - nothing was placed."))
    }

    func testAnObjectSurvivalCannotPlaceIsRefusedForAPayingGuest() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 64)])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("water", 1)), from: "guest", world: world),
                       .rejected("Survival can't place Water. Switch to Creative to place this object."))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 64])
    }

    // MARK: - The host's copy must be current

    func testASecondPasteWaitsUntilTheGuestHasAppliedTheLastPayment() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 10)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 6)), from: "guest", world: world)
        let payment = try XCTUnwrap(session.drainGrants(for: "guest").first)
        _ = finish(session, in: world)
        // The guest asks again before the payment has reached it. It still holds all ten planks
        // and says so; six of them are spent.
        XCTAssertTrue(publish(session, [("oak_planks", 10)], revision: 1, applied: payment.grantID - 1))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 4), z: 8, appliedGrantID: payment.grantID - 1),
                                                   from: "guest", world: world),
                       .rejected(LANTemplateRefusal.paymentPending))
        XCTAssertEqual(world.getBlock(4, 64, 8), 0)
        XCTAssertEqual(hostCopy(session), ["oak_planks": 4])
        // The guest applies the grant and publishes what it really holds; now it can ask again.
        XCTAssertTrue(publish(session, [("oak_planks", 4)], revision: 2, applied: payment.grantID))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 6), z: 8, appliedGrantID: payment.grantID),
                                                   from: "guest", world: world),
                       .rejected("Missing 2 Oak Planks - nothing was placed."))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 4), z: 8, appliedGrantID: payment.grantID),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
    }

    /// Review finding: the guest publishes its inventory whenever it changes, and the selected
    /// hotbar slot is part of it. A publish that left the guest after the click and before the
    /// payment reached it still shows the materials. Stored as it came, it put them back into
    /// the host's copy, and a guest that then reconnected was handed them a second time.
    func testAPublishFromBeforeThePaymentArrivedDoesNotPutThePaidMaterialsBack() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 10), ("glass", 3)])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 6)), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        let payment = try XCTUnwrap(session.drainGrants(for: "guest").first)
        _ = finish(session, in: world)

        XCTAssertTrue(publish(session, [("oak_planks", 10), ("glass", 3)], revision: 1,
                              applied: payment.grantID - 1, selectedHotbarSlot: 3))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 4, "glass": 3])
        let stored = try XCTUnwrap(session.peerInventorySnapshotsByPlayerID()["guest"])
        XCTAssertEqual(stored.selectedHotbarSlot, 3, "everything else in the publish is kept")
        // A guest that reconnects is given the host's copy as its inventory.
        let restore = try XCTUnwrap(session.peerRestoreState(playerID: "guest"))
        XCTAssertEqual(restore.inventory.slots.filter { $0.itemID == iid("oak_planks") }.reduce(0) { $0 + $1.count }, 4)
        XCTAssertGreaterThanOrEqual(restore.grantID, payment.grantID, "and it will not apply the payment again")

        // A second publish from before the payment is treated the same way.
        XCTAssertTrue(publish(session, [("glass", 3), ("oak_planks", 10)], revision: 2, applied: 0))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 4, "glass": 3])
        // The guest applied the payment and says so: from here its inventory is stored as it is.
        XCTAssertTrue(publish(session, [("oak_planks", 4), ("glass", 3)], revision: 3, applied: payment.grantID))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 4, "glass": 3])
        XCTAssertTrue(publish(session, [("oak_planks", 9), ("glass", 3)], revision: 4, applied: payment.grantID))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 9, "glass": 3], "a payment is taken out once")
    }

    /// The same window, ending in the guest's death: what lies on the ground is what the guest
    /// owned after paying, not what it owned before.
    func testAGuestThatDiesBeforeThePaymentArrivedDropsOnlyWhatItStillOwns() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 10)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 6)), from: "guest", world: world)
        let payment = try XCTUnwrap(session.drainGrants(for: "guest").first)
        _ = finish(session, in: world)
        XCTAssertTrue(publish(session, [("oak_planks", 10)], revision: 1, applied: payment.grantID - 1))
        session.updatePlayerState(playerState(dead: true))
        let drops = try XCTUnwrap(session.consumeDeathDrops(for: "guest"))
        XCTAssertEqual(drops.inventory.slots.map(\.count), [4])
        XCTAssertEqual((0..<6).filter { world.getBlockId(4 + $0, 64, 4) == Int(B.oak_planks) }.count, 6)
    }

    /// Review finding: a host that is catching up refuses guest messages, so the publish a guest
    /// sends just before its request can be lost while the request arrives. The request names
    /// the inventory it was made with, and the host waits until it holds that one.
    func testAPayingPasteWaitsForTheInventoryItWasMadeWith() throws {
        let world = loadedWorld()
        let session = hostSession()
        XCTAssertTrue(publish(session, [("oak_planks", 64)], revision: 4, applied: 0))
        // Since then the guest used most of its planks; the publish that says so was lost.
        let ask = try placeIntent(row("oak_planks", 6), inventoryRevision: 5)
        XCTAssertEqual(session.applyTemplateIntent(ask, from: "guest", world: world),
                       .rejected(LANTemplateRefusal.inventoryNotHeard))
        XCTAssertEqual(world.getBlock(4, 64, 4), 0)
        XCTAssertEqual(hostCopy(session), ["oak_planks": 64])
        XCTAssertTrue(session.drainGrants(for: "guest").isEmpty)
        XCTAssertTrue(publish(session, [("oak_planks", 2)], revision: 5, applied: 0))
        XCTAssertEqual(session.applyTemplateIntent(ask, from: "guest", world: world),
                       .rejected("Missing 4 Oak Planks - nothing was placed."))
        XCTAssertTrue(publish(session, [("oak_planks", 8)], revision: 6, applied: 0))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 6), inventoryRevision: 6),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
    }

    func testAFreePasteDoesNotWaitForAnInventory() throws {
        let world = loadedWorld()
        let session = hostSession()
        session.letPasteForFree("guest")
        session.updatePlayerState(playerState(gameMode: GameMode.creative))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 6), inventoryRevision: 99),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
    }

    func testAPaidUndoWaitsForTheInventoryItWasMadeWith() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 6)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 6)), from: "guest", world: world)
        let payment = try XCTUnwrap(session.drainGrants(for: "guest").first)
        _ = finish(session, in: world)
        XCTAssertTrue(publish(session, [], revision: 1, applied: payment.grantID))
        // The refund is sized to the room in the host's copy, so the copy must be the current one.
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(appliedGrantID: payment.grantID, inventoryRevision: 2),
                                                   from: "guest", world: world),
                       .rejected(LANTemplateRefusal.inventoryNotHeard))
        XCTAssertEqual(world.getBlockId(4, 64, 4), Int(B.oak_planks))
        XCTAssertTrue(publish(session, [], revision: 2, applied: payment.grantID))
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(appliedGrantID: payment.grantID, inventoryRevision: 2),
                                                   from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
    }

    // MARK: - Undo

    func testUndoPaysBackWhatStandsCountedAsEachCellIsRestored() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 6)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 6)), from: "guest", world: world)
        _ = session.drainGrants(for: "guest")
        _ = finish(session, in: world)
        world.setBlock(4, 64, 4, 0)                        // mined before the undo starts
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        // One cell a step: after the first cell is restored another player mines a plank the
        // undo has not reached. A count taken when the undo started would still pay for it.
        let results = finish(session, in: world, budgetPerPeer: 1) { step in
            if step == 1 { world.setBlock(7, 64, 4, 0) }
        }
        XCTAssertEqual(results.last, .undone(name: "Row", restored: 6, refund: "Returned 4 materials."))
        let grants = session.drainGrants(for: "guest")
        XCTAssertEqual(itemCount(grants, "oak_planks"), 4)
        XCTAssertEqual(grants.flatMap(\.take).count, 0)
        XCTAssertEqual(hostCopy(session), ["oak_planks": 4])
        for dx in 0..<6 { XCTAssertEqual(world.getBlock(4 + dx, 64, 4), 0) }
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .rejected(LANTemplateRefusal.nothingToUndo), "nothing is paid back twice")
    }

    func testABlockPutBackDuringTheUndoIsPaidForButNeverMoreThanWasPaid() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 3)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 3)), from: "guest", world: world)
        _ = session.drainGrants(for: "guest")
        _ = finish(session, in: world)
        for dx in 0..<3 { world.setBlock(4 + dx, 64, 4, 0) }                 // all mined: nothing stands
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        let results = finish(session, in: world, budgetPerPeer: 1) { step in
            // Planks are put back on cells the undo has not reached, and a double slab is no plank.
            if step == 0 { world.setBlock(5, 64, 4, Int(cell(B.oak_planks))); world.setBlock(6, 64, 4, Int(cell(B.oak_slab, 2))) }
        }
        XCTAssertEqual(results.last, .undone(name: "Row", restored: 3, refund: "Returned 1 material."))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 1])
    }

    func testAnUndoWhoseRefundHasNoRoomIsRefusedAndCanBeAskedAgain() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 5)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 5)), from: "guest", world: world)
        _ = session.drainGrants(for: "guest")
        _ = finish(session, in: world)
        carry(session, (0..<36).map { _ in ("cobblestone", 64) })
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .rejected("Make room for 1 more stack to undo this object."))
        XCTAssertFalse(session.hasActiveTemplateJob(playerID: "guest"))
        XCTAssertEqual(world.getBlockId(4, 64, 4), Int(B.oak_planks))
        carry(session, (0..<35).map { _ in ("cobblestone", 64) })
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        XCTAssertEqual(finish(session, in: world).last,
                       .undone(name: "Row", restored: 5, refund: "Returned 5 materials."))
    }

    func testARefundForAGuestThatDiedDuringTheUndoLiesOnTheGroundAndIsNotGranted() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 4)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 4)), from: "guest", world: world)
        _ = session.drainGrants(for: "guest")
        _ = finish(session, in: world)
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        session.updatePlayerState(playerState(dead: true))
        let results = finish(session, in: world)
        XCTAssertEqual(results.last, .undone(name: "Row", restored: 4, refund: "4 materials had no room and lie on the ground."))
        XCTAssertEqual(dropped(world, "oak_planks"), 4)
        XCTAssertEqual(itemCount(session.drainGrants(for: "guest"), "oak_planks"), 0,
                       "a dead guest's inventory is not added to")
    }

    // MARK: - Blocks the job could not write

    func testAPasteThatCouldNotWriteEveryBlockPaysTheRestBackOnceAtCompletion() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 8)])
        // Six planks from x 13 to x 18: three in chunk (0,0), three in chunk (1,0).
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 6), x: 13), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        XCTAssertEqual(takeCount(session.drainGrants(for: "guest"), "oak_planks"), 6)
        world.removeChunk(1, 0)                             // unloads before the job reaches it
        let results = finish(session, in: world)
        guard case .placed(_, _, _, _, _, let payment)? = results.last else { return XCTFail("\(results)") }
        XCTAssertEqual(payment, "Used 3 materials.")
        XCTAssertEqual(itemCount(session.drainGrants(for: "guest"), "oak_planks"), 3, "the three that were never placed")
        XCTAssertEqual(hostCopy(session), ["oak_planks": 5])
        for x in 13...15 { XCTAssertEqual(world.getBlockId(x, 64, 4), Int(B.oak_planks)) }
        // The undo pays back the three that were placed and no more.
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        XCTAssertEqual(finish(session, in: world).last,
                       .undone(name: "Row", restored: 3, refund: "Returned 3 materials."))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 8])
    }

    /// Review finding: a potted plant is charged as a pot and a plant, and the plant is read
    /// from the pot's block entity. When the job could not place the pot, only the pot was
    /// paid back.
    func testAPotThePasteCouldNotPlaceIsPaidBackWithItsPlant() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("flower_pot", 2), ("poppy", 2)])
        func potted(_ dx: Int) -> BlockEntityData {
            let pot = BlockEntityData(type: "lectern", x: dx, y: 0, z: 0)
            pot.plant = "poppy"
            return pot
        }
        // Two potted poppies at x 14 and x 17: one in chunk (0,0), one in chunk (1,0).
        let pots = ObjectTemplate(name: "Pots", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 4, sizeY: 1, sizeZ: 1,
                                  blocks: [0, 3].map { TemplateBlock(dx: $0, dy: 0, dz: 0, cell: cell(B.flower_pot, 0)) },
                                  blockEntities: [potted(0), potted(3)])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(pots, x: 14), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Pots"))
        let paid = session.drainGrants(for: "guest")
        XCTAssertEqual(takeCount(paid, "flower_pot"), 2)
        XCTAssertEqual(takeCount(paid, "poppy"), 2)
        world.removeChunk(1, 0)                             // unloads before the job reaches it
        let results = finish(session, in: world)
        guard case .placed(_, _, _, _, _, let payment)? = results.last else { return XCTFail("\(results)") }
        XCTAssertEqual(payment, "Used 2 materials.")
        let back = session.drainGrants(for: "guest")
        XCTAssertEqual(itemCount(back, "flower_pot"), 1)
        XCTAssertEqual(itemCount(back, "poppy"), 1, "the plant of the pot that was never placed")
        XCTAssertEqual(hostCopy(session), ["flower_pot": 1, "poppy": 1])
        XCTAssertEqual(world.getBlockEntity(14, 64, 4)?.plant, "poppy")
    }

    // MARK: - The guest's side of a take

    func testATakeRemovesPlainItemsWhereverTheySitAndNothingElse() {
        var filled = StackData()
        filled.contents = [stack("diamond", 64)]
        var inventory: [ItemStack?] = [
            ItemStack(iid("oak_planks"), 5, label: "Keep"), nil, stack("oak_planks", 3), stack("glass", 9),
            ItemStack(iid("shulker_box"), 1, data: filled), stack("oak_planks", 64),
        ]
        lanApplyTemplateTake([
            LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 64),
            LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 2),
            LANInventorySlotSnapshot(slot: 0, itemID: iid("shulker_box"), count: 1),
            LANInventorySlotSnapshot(slot: 0, itemID: iid("torch"), count: 5),
        ], to: &inventory)
        XCTAssertEqual(inventory[0]?.count, 5, "a renamed stack stays")
        XCTAssertNil(inventory[2])
        XCTAssertEqual(inventory[5]?.count, 1, "66 plain planks went, from the first slots first")
        XCTAssertEqual(inventory[3]?.count, 9)
        XCTAssertNotNil(inventory[4], "a filled box is never taken, even when the host could not see it is filled")
    }

    func testAGrantCarriesItsTakeThroughTheCodecAndAnOlderShapeDecodesWithout() throws {
        let grant = LANInventoryGrant(playerID: "guest", grantID: 7, items: [], xp: 0, clearAll: false,
                                      take: [LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 64),
                                             LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 6)])
        let decoded = try JSONDecoder().decode(LANInventoryGrant.self, from: JSONEncoder().encode(grant))
        XCTAssertEqual(decoded, grant)
        XCTAssertEqual(decoded.take.map(\.count), [64, 6])
        let legacy = Data(#"{"playerID":"guest","grantID":3,"items":[],"xp":0,"clearAll":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LANInventoryGrant.self, from: legacy).take, [])
        let flood = LANInventoryGrant(playerID: "guest", grantID: 1, items: [], xp: 0, clearAll: false,
                                      take: (0..<500).map { _ in LANInventorySlotSnapshot(slot: 0, itemID: 1, count: 1) })
        XCTAssertEqual(flood.take.count, LAN_MULTIPLAYER_MAX_GRANT_ITEMS)
    }

    func testAnIntentCarriesTheAppliedGrantThroughTheCodec() throws {
        let intent = try placeIntent(row("oak_planks", 1), appliedGrantID: 41)
        let decoded = try JSONDecoder().decode(LANTemplateIntent.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(decoded.appliedGrantID, 41)
        XCTAssertEqual(decoded, intent)
        XCTAssertEqual(undoIntent(appliedGrantID: -9).appliedGrantID, 0)
        let legacy = Data(#"{"action":"undoPlacement","templateName":"","x":0,"y":0,"z":0,"rotation":0}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LANTemplateIntent.self, from: legacy).appliedGrantID, 0)
        XCTAssertEqual(try JSONDecoder().decode(LANTemplateIntent.self, from: legacy).inventoryRevision, 0)
    }

    func testAnIntentAndAPublishCarryWhatTheHostChecksThroughTheCodec() throws {
        let intent = try placeIntent(row("oak_planks", 1), appliedGrantID: 41, inventoryRevision: 17)
        let decoded = try JSONDecoder().decode(LANTemplateIntent.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(decoded.inventoryRevision, 17)
        XCTAssertEqual(decoded, intent)
        XCTAssertEqual(undoIntent(inventoryRevision: -3).inventoryRevision, 0)

        let update = LANInventoryUpdate(
            playerID: "guest", revision: 9,
            snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: []), appliedGrantID: 12)
        let message = try LANMultiplayerFrameCodec.decode(try LANMultiplayerFrameCodec.encode(.inventoryUpdate(update), sequence: 1)).message
        guard case .inventoryUpdate(let received) = message else { return XCTFail("an inventory update must survive the frame codec") }
        XCTAssertEqual(received.appliedGrantID, 12)
        XCTAssertEqual(received, update)
        let older = Data(#"{"playerID":"guest","revision":3,"snapshot":{"playerID":"guest","selectedHotbarSlot":0,"slots":[]}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(LANInventoryUpdate.self, from: older).appliedGrantID, 0)
        XCTAssertEqual(LANInventoryUpdate(playerID: "guest", revision: 1, snapshot: update.snapshot, appliedGrantID: -5).appliedGrantID, 0)
    }

    // MARK: - Seeded: an unmodified guest never ends up ahead

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

    /// A guest as the shipped client behaves, with the host's grants arriving late. The guest
    /// rearranges its inventory, publishes at odd moments, pastes and undoes. Whatever the
    /// order, the planks it holds plus the planks standing in the world never exceed what it
    /// started with, and once everything has arrived the host's copy is what the guest holds.
    func testAnUnmodifiedGuestNeverEndsUpAheadWhateverTheOrderOfMessages() throws {
        var random = SplitMix64(state: 0x1A2B_3C4D)
        let planks = iid("oak_planks")
        for round in 0..<120 {
            let world = loadedWorld()
            let session = hostSession()
            var inventory: [ItemStack?] = Array(repeating: nil, count: 36)
            let start = 20 + random.int(60)
            inventory[random.int(36)] = ItemStack(planks, min(64, start))
            if start > 64 { inventory[(0..<36).first { inventory[$0] == nil }!] = ItemStack(planks, start - 64) }
            var revision = 0, appliedGrantID = 0
            var wire: [LANInventoryGrant] = []                 // host to guest, in order, delivered late
            var pasted = false
            func held() -> Int { inventory.compactMap { $0 }.filter { $0.id == planks }.reduce(0) { $0 + $1.count } }
            func standing() -> Int { (0..<16).filter { world.getBlockId($0, 64, 4) == Int(B.oak_planks) }.count }
            func publish() {
                revision += 1
                _ = session.applyInventoryUpdate(LANInventoryUpdate(
                    playerID: "guest", revision: revision,
                    snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0,
                                                         slots: makeLANInventorySlotSnapshots(inventory)),
                    appliedGrantID: appliedGrantID), from: "guest")
            }
            func deliverOne() {
                guard !wire.isEmpty else { return }
                let grant = wire.removeFirst()
                guard grant.grantID > appliedGrantID else { return }
                appliedGrantID = grant.grantID
                lanApplyTemplateTake(grant.take, to: &inventory)
                var slots = TemplateMaterialSlots(copying: inventory)
                for item in grant.items { _ = slots.put(itemID: item.itemID, count: item.count) }
                for index in slots.touchedSlots { inventory[index] = slots.stacks[index] }
                if !grant.take.isEmpty { publish() }        // the client publishes after a take
            }
            publish()
            for _ in 0..<40 {
                switch random.int(6) {
                case 0:
                    publish()
                case 1:
                    let a = random.int(36), b = random.int(36)
                    inventory.swapAt(a, b)
                case 2:
                    deliverOne()
                case 3 where !pasted:
                    publish()                               // the client publishes before it asks
                    let count = 1 + random.int(12)
                    let result = session.applyTemplateIntent(
                        try placeIntent(row("oak_planks", count), x: 0, appliedGrantID: appliedGrantID, inventoryRevision: revision),
                        from: "guest", world: world)
                    wire.append(contentsOf: session.drainGrants(for: "guest"))
                    if case .accepted = result {
                        if random.int(2) == 0 { publish() } // a publish that crosses the grant
                        _ = finish(session, in: world)
                        wire.append(contentsOf: session.drainGrants(for: "guest"))
                        pasted = true
                    }
                case 4 where pasted:
                    publish()
                    if case .accepted = session.applyTemplateIntent(
                        undoIntent(appliedGrantID: appliedGrantID, inventoryRevision: revision), from: "guest", world: world) {
                        _ = finish(session, in: world)
                        wire.append(contentsOf: session.drainGrants(for: "guest"))
                        pasted = false
                    }
                default:
                    break
                }
                // The grants still on the wire are takes the guest has yet to apply (it holds
                // too much for a moment) or refunds it has yet to receive (too little).
                let owedByGuest = wire.flatMap(\.take).reduce(0) { $0 + $1.count }
                XCTAssertLessThanOrEqual(held() - owedByGuest + standing(), start, "round \(round)")
                // And the host never believes the guest holds planks that stand in the world:
                // its copy is what a reconnect hands back and what a death drops.
                XCTAssertLessThanOrEqual((hostCopy(session)["oak_planks"] ?? 0) + standing(), start, "round \(round): host copy")
            }
            while !wire.isEmpty { deliverOne() }
            publish()
            XCTAssertEqual(held() + standing(), start, "round \(round): every plank is held or stands")
            XCTAssertEqual(hostCopy(session)["oak_planks"] ?? 0, held(), "round \(round): the host's copy is true again")
        }
    }

    // MARK: - Deeper: who pays, through admission

    /// The grant alone does not make a paste free: a guest the host lets use creative, but
    /// playing in survival, pays like any other.
    func testAGuestWithTheCreativeGrantButInSurvivalPays() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 4)])
        session.setPermissions(LANPeerPermissions(canUseCreative: true), for: "guest")
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 3)), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 1])
        XCTAssertEqual(takeCount(session.drainGrants(for: "guest"), "oak_planks"), 3)
    }

    /// A guest that pasted for free in granted creative pays as soon as the grant is withdrawn,
    /// even when it goes on claiming creative.
    func testWithdrawingTheCreativeGrantMakesTheNextPastePay() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 4)])
        session.setPermissions(LANPeerPermissions(canUseCreative: true), for: "guest")
        session.updatePlayerState(playerState(gameMode: GameMode.creative))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 2)), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        XCTAssertEqual(finish(session, in: world), [.placed(name: "Row", blocks: 2, blockEntities: 0, cleared: 0, filled: 0)])
        XCTAssertEqual(hostCopy(session), ["oak_planks": 4], "a free paste takes nothing")
        XCTAssertEqual(session.drainGrants(for: "guest").count, 0)

        session.setPermissions(LANPeerPermissions(), for: "guest")
        session.updatePlayerState(playerState(gameMode: GameMode.creative))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 2), z: 8), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        XCTAssertEqual(hostCopy(session), ["oak_planks": 2])
        XCTAssertEqual(finish(session, in: world).last,
                       .placed(name: "Row", blocks: 2, blockEntities: 0, cleared: 0, filled: 0, payment: "Used 2 materials."))
    }

    /// The other side of the same rule: survival cells and plain dirt are what a paying guest
    /// gets. A guest in granted creative keeps what the template holds and its ground is filled
    /// like the land around it, for free.
    func testOnlyAPayingGuestsGroundIsFilledWithDirt() throws {
        let world = loadedWorld()
        world.setBlock(4, 62, 4, Int(cell(B.stone)), SET_SILENT)
        world.setBlock(4, 63, 4, 0, SET_SILENT)
        world.setBlock(3, 63, 4, Int(cell(B.sand)), SET_SILENT)
        let session = hostSession()
        session.setPermissions(LANPeerPermissions(canUseCreative: true), for: "guest")
        session.updatePlayerState(playerState(gameMode: GameMode.creative))
        let object = ObjectTemplate(name: "Stateful", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 1, sizeY: 1, sizeZ: 1,
                                    blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: cell(B.composter, 8))])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(object), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Stateful"))
        XCTAssertEqual(session.drainGrants(for: "guest").count, 0)
        XCTAssertEqual(finish(session, in: world), [.placed(name: "Stateful", blocks: 1, blockEntities: 0, cleared: 0, filled: 1)])
        XCTAssertEqual(world.getBlock(4, 64, 4), Int(cell(B.composter, 8)))
        XCTAssertEqual(world.getBlockId(4, 63, 4), Int(B.sand), "free ground matches the land beside it")
    }

    // MARK: - Deeper: the payment gate

    /// The gate holds back a paying paste only. An undo charges nothing and a free paste takes
    /// nothing from the copy, so neither waits for a payment the guest has yet to apply.
    func testThePaymentGateHoldsBackOnlyAPayingPaste() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 10)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 3)), from: "guest", world: world)
        let payment = try XCTUnwrap(session.drainGrants(for: "guest").first)
        XCTAssertGreaterThan(payment.grantID, 0)
        _ = finish(session, in: world)
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(appliedGrantID: 0), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        XCTAssertEqual(finish(session, in: world).last, .undone(name: "Row", restored: 3, refund: "Returned 3 materials."))
        _ = session.drainGrants(for: "guest")

        session.setPermissions(LANPeerPermissions(canUseCreative: true), for: "guest")
        session.updatePlayerState(playerState(gameMode: GameMode.creative))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 3), z: 8, appliedGrantID: 0),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
    }

    /// The gate names the grant that carried the last payment, and moves with every payment.
    /// A pickup or a refund is a grant too, but it costs the guest nothing, so a guest that has
    /// applied the payment and not those may paste again.
    func testThePaymentGateFollowsEachPaymentAndNoOtherGrant() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 20)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 2), z: 2), from: "guest", world: world)
        let first = try XCTUnwrap(session.drainGrants(for: "guest").last)
        _ = finish(session, in: world)
        let pickup = try XCTUnwrap(session.enqueueGrant(
            items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("torch"), count: 1)], xp: 0, clearAll: false, to: "guest"))
        XCTAssertGreaterThan(pickup.grantID, first.grantID)

        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 2), z: 5, appliedGrantID: first.grantID - 1),
                                                   from: "guest", world: world),
                       .rejected(LANTemplateRefusal.paymentPending))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 2), z: 5, appliedGrantID: first.grantID),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        let grants = session.drainGrants(for: "guest")
        XCTAssertEqual(grants.map(\.grantID), [pickup.grantID, pickup.grantID + 1])
        let second = try XCTUnwrap(grants.last)
        XCTAssertEqual(takeCount([second], "oak_planks"), 2)
        _ = finish(session, in: world)

        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 2), z: 8, appliedGrantID: pickup.grantID),
                                                   from: "guest", world: world),
                       .rejected(LANTemplateRefusal.paymentPending), "the second payment moved the gate")
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 2), z: 8, appliedGrantID: second.grantID),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
    }

    /// A paste the host refuses after reading the template, out of reach or onto bedrock,
    /// is refused before anything is charged, and leaves nothing for the gate to wait on.
    func testAPasteTheHostCannotPlaceChargesNothing() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 10)])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 3), x: 200), from: "guest", world: world),
                       .rejected(LANTemplateRefusal.outOfReach))
        world.setBlock(5, 64, 4, Int(cell(B.bedrock)), SET_SILENT)
        guard case .rejected(let reason) = session.applyTemplateIntent(try placeIntent(row("oak_planks", 3)),
                                                                       from: "guest", world: world) else {
            return XCTFail("a box with bedrock in it cannot be prepared")
        }
        XCTAssertFalse(reason.hasPrefix("Missing"), reason)
        XCTAssertEqual(hostCopy(session), ["oak_planks": 10])
        XCTAssertEqual(session.drainGrants(for: "guest").count, 0)
        XCTAssertFalse(session.hasActiveTemplateJob(playerID: "guest"))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 3), z: 8, appliedGrantID: 0),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"), "nothing is owed")
    }

    // MARK: - Deeper: what an undo pays back

    /// What stands can be worth more than what was paid: two slabs pasted, made double by
    /// someone else. The undo pays back the two that were paid, not the four that stand.
    func testUndoNeverPaysBackMoreThanTheReceiptHolds() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_slab", 2)])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_slab", 2)), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        _ = session.drainGrants(for: "guest")
        _ = finish(session, in: world)
        for x in 4...5 { world.setBlock(x, 64, 4, Int(cell(B.oak_slab, 2))) }
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        XCTAssertEqual(finish(session, in: world).last, .undone(name: "Row", restored: 2, refund: "Returned 2 materials."))
        XCTAssertEqual(itemCount(session.drainGrants(for: "guest"), "oak_slab"), 2)
        XCTAssertEqual(hostCopy(session), ["oak_slab": 2])
    }

    /// What a job could not write is paid back at completion and comes off the receipt, so an
    /// undo cannot pay for it a second time even when what stands is worth more than was placed.
    func testBlocksTheJobCouldNotWriteComeOffTheReceiptTheUndoPaysAgainst() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_slab", 6)])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_slab", 6), x: 13), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        _ = session.drainGrants(for: "guest")
        world.removeChunk(1, 0)
        guard case .placed(_, let blocks, _, _, _, let payment)? = finish(session, in: world).last else { return XCTFail() }
        XCTAssertEqual(payment, "Used 3 materials.")
        XCTAssertEqual(blocks, 3, "the result counts the blocks the job wrote, so the guest reads 3 blocks, used 3")
        XCTAssertEqual(itemCount(session.drainGrants(for: "guest"), "oak_slab"), 3)
        for x in 13...15 { world.setBlock(x, 64, 4, Int(cell(B.oak_slab, 2))) }   // six slabs stand on three cells
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        XCTAssertEqual(finish(session, in: world).last, .undone(name: "Row", restored: 3, refund: "Returned 3 materials."))
        XCTAssertEqual(hostCopy(session), ["oak_slab": 6], "never more than the guest started with")
    }

    /// Ground the job did not have to fill, because someone filled it first, is paid back.
    func testGroundSomeoneElseFilledFirstIsPaidBack() throws {
        let world = loadedWorld()
        world.setBlock(4, 62, 4, Int(cell(B.stone)), SET_SILENT)
        world.setBlock(4, 63, 4, 0, SET_SILENT)
        let session = hostSession(carrying: [("oak_planks", 2), ("dirt", 1)])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 2)), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        XCTAssertEqual(takeCount(session.drainGrants(for: "guest"), "dirt"), 1)
        world.setBlock(4, 63, 4, Int(cell(B.dirt)))
        XCTAssertEqual(finish(session, in: world).last,
                       .placed(name: "Row", blocks: 2, blockEntities: 0, cleared: 0, filled: 0, payment: "Used 2 materials."))
        XCTAssertEqual(itemCount(session.drainGrants(for: "guest"), "dirt"), 1)
        XCTAssertEqual(hostCopy(session), ["dirt": 1])
        // Its undo does not pay for the dirt someone else put there.
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        XCTAssertEqual(finish(session, in: world).last?.refundText, "Returned 2 materials.")
        XCTAssertEqual(hostCopy(session), ["dirt": 1, "oak_planks": 2])
    }

    /// A guest that died while its paste ran is not given what the job could not write: it
    /// lies at the object.
    func testWhatAJobCouldNotWriteForADeadGuestLiesAtTheObject() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 6)])
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 6), x: 13), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        _ = session.drainGrants(for: "guest")
        world.removeChunk(1, 0)
        session.updatePlayerState(playerState(dead: true))
        guard case .placed(_, _, _, _, _, let payment)? = finish(session, in: world).last else { return XCTFail() }
        XCTAssertEqual(payment, "Used 3 materials.")
        XCTAssertEqual(itemCount(session.drainGrants(for: "guest"), "oak_planks"), 0)
        XCTAssertEqual(dropped(world, "oak_planks"), 3)
        for item in world.entities.compactMap({ $0 as? ItemEntity }) {
            XCTAssertEqual(item.x, 13.5, accuracy: 0.01, "at the object's origin, not where the guest fell")
        }
    }

    /// The room check at admission is only a check: the guest may fill its inventory while the
    /// undo runs. What still fits is granted; the rest lies beside the guest.
    func testARefundThatNoLongerFitsIsPartlyGrantedAndTheRestLiesBesideTheGuest() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 5)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 5)), from: "guest", world: world)
        _ = session.drainGrants(for: "guest")
        _ = finish(session, in: world)
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        carry(session, (0..<35).map { _ in ("cobblestone", 64) } + [("oak_planks", 62)])
        XCTAssertEqual(finish(session, in: world).last,
                       .undone(name: "Row", restored: 5,
                               refund: "Returned 2 materials. 3 materials had no room and lie on the ground."))
        XCTAssertEqual(itemCount(session.drainGrants(for: "guest"), "oak_planks"), 2)
        XCTAssertEqual(dropped(world, "oak_planks"), 3)
        for item in world.entities.compactMap({ $0 as? ItemEntity }) {
            XCTAssertEqual(item.x, 2.5, accuracy: 0.01, "beside the guest")
            XCTAssertEqual(item.z, 1.5, accuracy: 0.01)
        }
        XCTAssertEqual(hostCopy(session)["oak_planks"], 64)
    }

    /// A paste paid for in survival is paid back by its undo even when the guest has since been
    /// granted creative: the receipt travels with the paste, not with the mode.
    func testAPaidPasteUndoneInGrantedCreativeStillPaysBack() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 3)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 3)), from: "guest", world: world)
        _ = session.drainGrants(for: "guest")
        _ = finish(session, in: world)
        session.setPermissions(LANPeerPermissions(canUseCreative: true), for: "guest")
        session.updatePlayerState(playerState(gameMode: GameMode.creative))
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        XCTAssertEqual(finish(session, in: world).last, .undone(name: "Row", restored: 3, refund: "Returned 3 materials."))
        XCTAssertEqual(itemCount(session.drainGrants(for: "guest"), "oak_planks"), 3)
    }

    // MARK: - Deeper: leaving and the host restarting

    /// A guest that leaves mid-undo loses the refund for what was already restored (accepted)
    /// and nothing is dropped for it. When it comes back, the restore names every grant the host
    /// has issued, so the client's next paste passes the gate, and is charged from the copy the
    /// payment left.
    func testAGuestThatLeavesMidUndoRejoinsAbleToPaste() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 6)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 3)), from: "guest", world: world)
        let payment = try XCTUnwrap(session.drainGrants(for: "guest").first)
        _ = finish(session, in: world)
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Row"))
        session.stepTemplateJobs(in: world, budgetPerPeer: 1)
        session.disconnectPeer(playerID: "guest", tick: 10)
        XCTAssertFalse(session.hasActiveTemplateJob(playerID: "guest"))
        XCTAssertTrue(session.drainTemplateIntentResponses().isEmpty)
        XCTAssertEqual(dropped(world, "oak_planks"), 0)
        XCTAssertEqual(itemCount(session.drainGrants(for: "guest"), "oak_planks"), 0)

        session.acceptPeer(playerID: "guest", displayName: "Alex")
        let restore = try XCTUnwrap(session.peerRestoreState(playerID: "guest"))
        XCTAssertGreaterThanOrEqual(restore.grantID, payment.grantID)
        XCTAssertEqual(restore.inventory.slots.filter { $0.itemID == iid("oak_planks") }.reduce(0) { $0 + $1.count }, 3)
        XCTAssertEqual(session.applyTemplateIntent(undoIntent(), from: "guest", world: world),
                       .rejected(LANTemplateRefusal.nothingToUndo))
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 3), z: 8, appliedGrantID: restore.grantID),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        XCTAssertEqual(hostCopy(session), [:])
    }

    /// A host that restarts starts its grant ids again, and the payment gate with them, so a
    /// guest restored from the saved record can paste.
    func testAHostRestartStartsThePaymentGateAgainWithTheGrantIDs() throws {
        let world = loadedWorld()
        let session = hostSession(carrying: [("oak_planks", 10)])
        _ = session.applyTemplateIntent(try placeIntent(row("oak_planks", 3)), from: "guest", world: world)
        XCTAssertEqual(session.drainGrants(for: "guest").count, 1)
        _ = finish(session, in: world)
        let record = try XCTUnwrap(session.peerRecord(playerID: "guest"))

        let restarted = LANMultiplayerHostSession()
        restarted.seedPeerRecord(record)
        restarted.acceptPeer(playerID: "guest", displayName: "Alex")
        restarted.updatePlayerState(playerState())
        let restore = try XCTUnwrap(restarted.peerRestoreState(playerID: "guest"))
        XCTAssertEqual(restore.grantID, 0)
        XCTAssertEqual(hostCopy(restarted), ["oak_planks": 7])
        XCTAssertEqual(restarted.applyTemplateIntent(try placeIntent(row("oak_planks", 3), z: 8, appliedGrantID: restore.grantID),
                                                     from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Row"))
        XCTAssertEqual(hostCopy(restarted), ["oak_planks": 4])
    }

    // MARK: - Fuzz: the new wire fields

    /// Seeded grants with take lists of any shape, and intents with any applied grant id, go
    /// through the real frame codec unchanged once constructed, and construction bounds them.
    func testFuzzedTakeListsAndAppliedGrantIDsSurviveTheFrameCodec() throws {
        var random = SplitMix64(state: 0x5EED_0001)
        let payload = try lanGuestTemplatePayload(for: row("oak_planks", 2))
        for round in 0..<300 {
            let take = (0..<random.int(90)).map { _ in
                LANInventorySlotSnapshot(slot: random.int(48) - 4, itemID: random.int(itemDefs.count + 40) - 20,
                                         count: random.int(400) - 100)
            }
            let grantID = Int(bitPattern: UInt(random.next()))
            let grant = LANInventoryGrant(playerID: "guest", grantID: grantID, items: [], xp: 0,
                                          clearAll: random.int(4) == 0, take: take)
            XCTAssertEqual(grant.take.count, min(take.count, LAN_MULTIPLAYER_MAX_GRANT_ITEMS), "round \(round)")
            XCTAssertEqual(grant.grantID, max(0, grantID), "round \(round)")
            XCTAssertTrue(grant.take.allSatisfy { $0.count >= 0 && $0.count <= 127 && $0.itemID >= 0 }, "round \(round)")
            let grantFrame = try LANMultiplayerFrameCodec.encode(.inventoryGrant(grant), sequence: UInt32(round))
            guard case .inventoryGrant(let decodedGrant) = try LANMultiplayerFrameCodec.decode(grantFrame).message else {
                XCTFail("round \(round): a grant must decode as a grant"); continue
            }
            XCTAssertEqual(decodedGrant, grant, "round \(round)")

            let applied = Int(bitPattern: UInt(random.next()))
            let intent = random.int(2) == 0
                ? LANTemplateIntent(action: .placeTemplate, templateName: "Row", x: random.int(64), y: 64, z: random.int(64),
                                    rotation: random.int(4), templateData: payload, appliedGrantID: applied)
                : LANTemplateIntent(action: .undoPlacement, templateName: "", x: 0, y: 0, z: 0, rotation: 0,
                                    appliedGrantID: applied)
            XCTAssertEqual(intent.appliedGrantID, max(0, applied), "round \(round)")
            let intentFrame = try LANMultiplayerFrameCodec.encode(.templateIntent(playerID: "guest", intent: intent),
                                                                   sequence: UInt32(round))
            guard case .templateIntent(_, let decodedIntent) = try LANMultiplayerFrameCodec.decode(intentFrame).message else {
                XCTFail("round \(round): an intent must decode as an intent"); continue
            }
            XCTAssertEqual(decodedIntent, intent, "round \(round)")
        }
    }

    /// Hand-written frames the codec must refuse, or read safely.
    func testMalformedTakeAndAppliedGrantIDFieldsAreRefusedOrClamped() throws {
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(LANInventoryGrant.self, from: Data(
            #"{"playerID":"guest","grantID":3,"items":[],"xp":0,"clearAll":false,"take":"planks"}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(LANInventoryGrant.self, from: Data(
            #"{"playerID":"guest","grantID":3,"items":[],"xp":0,"clearAll":false,"take":[{"slot":0,"count":4}]}"#.utf8)))
        let negative = try decoder.decode(LANInventoryGrant.self, from: Data(
            #"{"playerID":"guest","grantID":3,"items":[],"xp":0,"clearAll":false,"take":[{"slot":-3,"itemID":-9,"count":-4}]}"#.utf8))
        XCTAssertEqual(negative.take.map(\.count), [0])
        XCTAssertThrowsError(try decoder.decode(LANTemplateIntent.self, from: Data(
            #"{"action":"undoPlacement","templateName":"","x":0,"y":0,"z":0,"rotation":0,"appliedGrantID":"7"}"#.utf8)))
        XCTAssertEqual(try decoder.decode(LANTemplateIntent.self, from: Data(
            #"{"action":"undoPlacement","templateName":"","x":0,"y":0,"z":0,"rotation":0,"appliedGrantID":-5}"#.utf8)).appliedGrantID, 0)
        // A take of nothing, or of no real item, leaves a guest's inventory as it was.
        var inventory: [ItemStack?] = [stack("oak_planks", 5), nil, stack("glass", 3)]
        lanApplyTemplateTake(negative.take, to: &inventory)
        lanApplyTemplateTake([LANInventorySlotSnapshot(slot: 0, itemID: itemDefs.count + 5, count: 64)], to: &inventory)
        XCTAssertEqual(inventory.map { $0?.count }, [5, nil, 3])
    }

    // MARK: - Property: a take and a charge agree

    private func plainCounts(_ inventory: [ItemStack?]) -> [Int: Int] {
        TemplateMaterialSlots(copying: inventory).plainCounts()
    }

    private func layout(_ inventory: [ItemStack?]) -> [String] {
        inventory.map { stack in
            guard let stack else { return "-" }
            return "\(stack.id)x\(stack.count)/\(stack.damage)/\(stack.label ?? "")/\(stack.ench.count)/\(stack.data.isEmpty)"
        }
    }

    /// Seeded inventories of plain and marked stacks, and seeded takes. A take removes exactly
    /// what was asked of each plain item, or all of it; never a marked stack. Splitting an entry
    /// in two, or reordering the entries, changes nothing (metamorphic).
    func testATakeRemovesExactlyWhatWasAskedOfPlainStacksInAnyOrder() {
        var random = SplitMix64(state: 0x7A4E_0002)
        let kinds = ["oak_planks", "glass", "dirt", "cobblestone", "torch", "oak_slab", "ender_pearl"].map { iid($0) }
        for round in 0..<400 {
            var inventory: [ItemStack?] = (0..<36).map { _ in
                guard random.int(3) > 0 else { return nil }
                let id = kinds[random.int(kinds.count)]
                let count = 1 + random.int(max(1, itemDefs[id].maxStack))
                switch random.int(5) {
                case 0: return ItemStack(id, count, label: "Named")
                case 1: return ItemStack(id, count, damage: 1 + random.int(5))
                default: return ItemStack(id, count)
                }
            }
            let take = (0..<random.int(8)).map { _ in
                LANInventorySlotSnapshot(slot: 0, itemID: kinds[random.int(kinds.count)], count: random.int(130))
            }
            let before = inventory.map(copyStack)
            var split = inventory.map(copyStack)
            var reordered = inventory.map(copyStack)
            lanApplyTemplateTake(take, to: &inventory)
            lanApplyTemplateTake(take.flatMap { entry -> [LANInventorySlotSnapshot] in
                let half = entry.count / 2
                return [LANInventorySlotSnapshot(slot: 0, itemID: entry.itemID, count: half),
                        LANInventorySlotSnapshot(slot: 0, itemID: entry.itemID, count: entry.count - half)]
            }, to: &split)
            lanApplyTemplateTake(take.reversed(), to: &reordered)
            XCTAssertEqual(layout(split), layout(inventory), "round \(round)")
            XCTAssertEqual(layout(reordered), layout(inventory), "round \(round)")

            let had = plainCounts(before), has = plainCounts(inventory)
            for id in kinds {
                let asked = take.filter { $0.itemID == id }.reduce(0) { $0 + $1.count }
                XCTAssertEqual((had[id] ?? 0) - (has[id] ?? 0), min(had[id] ?? 0, asked), "round \(round) item \(id)")
            }
            for index in before.indices where before[index].map({ !isPlainTemplateMaterial($0) }) == true {
                XCTAssertEqual(layout([inventory[index]]), layout([before[index]]), "round \(round): a marked stack was touched")
            }
        }
    }

    /// Seeded copies and bills. What the host takes from its copy is what the guest's take
    /// removes from the same inventory, slot for slot; the take is never cut short by the grant's
    /// size cap; nothing else in the copy changes; and paying back the whole bill restores
    /// every item's count (round trip). A bill the copy cannot pay names exactly the shortfall.
    func testWhatTheHostTakesFromItsCopyIsWhatTheGuestsTakeRemoves() throws {
        var random = SplitMix64(state: 0xC0FF_EE03)
        let kinds = ["oak_planks", "glass", "dirt", "torch", "oak_slab", "ender_pearl", "saddle"].map { iid($0) }
        for round in 0..<300 {
            let stacks: [ItemStack?] = (0..<36).map { _ in
                guard random.int(4) > 0 else { return nil }
                let id = kinds[random.int(kinds.count)]
                let count = 1 + random.int(max(1, itemDefs[id].maxStack))
                return random.int(6) == 0 ? ItemStack(id, count, label: "Named") : ItemStack(id, count)
            }
            let copy = LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: random.int(9),
                                                  slots: makeLANInventorySlotSnapshots(stacks),
                                                  xp: random.int(500), xpLevel: random.int(30), xpProgress: 0.25)
            let guest = try XCTUnwrap(makeInventory(from: copy))
            var counts: [Int: Int] = [:]
            for _ in 0..<(1 + random.int(4)) {
                counts[kinds[random.int(kinds.count)], default: 0] += 1 + random.int(160)
            }
            let bill = TemplateMaterialBill(counts)
            let plain = plainCounts(guest)
            switch lanPayTemplateMaterials(bill, from: copy, playerID: "guest") {
            case .failure(let error):
                let short = bill.lines.compactMap { line -> TemplateMaterialLine? in
                    let missing = line.count - (plain[line.itemID] ?? 0)
                    return missing > 0 ? TemplateMaterialLine(itemID: line.itemID, count: missing) : nil
                }
                XCTAssertFalse(short.isEmpty, "round \(round): refused a bill the copy could pay")
                XCTAssertEqual(error, .missing(short), "round \(round)")
            case .success(let payment):
                XCTAssertTrue(bill.lines.allSatisfy { $0.count <= (plain[$0.itemID] ?? 0) }, "round \(round)")
                XCTAssertEqual(payment.receipt.total, bill.total, "round \(round)")
                XCTAssertLessThanOrEqual(payment.take.count, LAN_MULTIPLAYER_MAX_GRANT_ITEMS, "round \(round)")
                let grant = LANInventoryGrant(playerID: "guest", grantID: 1, items: [], xp: 0, clearAll: false, take: payment.take)
                XCTAssertEqual(grant.take.reduce(0) { $0 + $1.count }, bill.total, "round \(round): the take was cut short")
                var taken = guest.map(copyStack)
                lanApplyTemplateTake(grant.take, to: &taken)
                XCTAssertEqual(makeLANInventorySlotSnapshots(taken), payment.inventory.slots, "round \(round)")
                XCTAssertEqual(payment.inventory.selectedHotbarSlot, copy.selectedHotbarSlot)
                XCTAssertEqual(payment.inventory.xp, copy.xp)
                XCTAssertEqual(payment.inventory.xpLevel, copy.xpLevel)
                XCTAssertEqual(payment.inventory.xpProgress, copy.xpProgress)
                // The guest may have moved its stacks since it published: the counts still agree.
                var moved = guest.map(copyStack)
                for index in stride(from: moved.count - 1, to: 0, by: -1) { moved.swapAt(index, random.int(index + 1)) }
                lanApplyTemplateTake(grant.take, to: &moved)
                XCTAssertEqual(plainCounts(moved), plainCounts(taken), "round \(round)")

                var receipt = payment.receipt
                let refund = lanRefundTemplateMaterials(counts, against: &receipt, into: payment.inventory, playerID: "guest")
                XCTAssertEqual(refund.returned, bill.total, "round \(round)")
                XCTAssertTrue(refund.leftover.isEmpty, "round \(round)")
                XCTAssertEqual(receipt.total, 0)
                XCTAssertEqual(plainCounts(try XCTUnwrap(makeInventory(from: refund.inventory))), plain, "round \(round)")
                XCTAssertEqual(lanTemplateRefundShortfall(counts, receipt: payment.receipt, inventory: payment.inventory,
                                                          playerID: "guest"), 0, "round \(round)")
                // The guest, given the refund's items, holds what the host's copy holds.
                var given = TemplateMaterialSlots(copying: taken)
                for item in refund.items { XCTAssertEqual(given.put(itemID: item.itemID, count: item.count), item.count) }
                XCTAssertEqual(given.plainCounts(), plain, "round \(round)")
            }
        }
    }

    // MARK: - A publish that crosses the take, end to end

    /// The guest owns its inventory and publishes it whenever it changes. A publish sent after
    /// the paste was asked for and before the take arrived (the guest moved a stack, picked
    /// something up, or asked again after the answer timed out) still shows the paid planks. The
    /// host takes the payment out of it again, so a death in that window drops only what the
    /// guest still owns, and a disconnect restores the guest from a copy that is already
    /// charged (the take, counted in the restore's grant id, is never applied). Either way the
    /// planks held, on the ground and standing are no more than the guest had.
    func testADeathOrARejoinWhileAPublishCrossesTheTakeLeavesTheGuestNoRicher() throws {
        for leaves in [false, true] {
            let world = loadedWorld()
            let session = hostSession(carrying: [("oak_planks", 10)])
            XCTAssertEqual(session.applyTemplateIntent(try placeIntent(row("oak_planks", 4)), from: "guest", world: world),
                           .accepted(action: .placeTemplate, name: "Row"))
            let take = try XCTUnwrap(session.drainGrants(for: "guest").first)
            _ = finish(session, in: world)
            // The guest moved its planks to another slot before the take arrived and published that.
            XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(
                playerID: "guest", revision: 5,
                snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: [
                    LANInventorySlotSnapshot(slot: 3, itemID: iid("oak_planks"), count: 10)])), from: "guest"))
            var guest: [ItemStack?] = Array(repeating: nil, count: 36)
            guest[3] = stack("oak_planks", 10)
            var onTheGround = 0
            if leaves {
                session.disconnectPeer(playerID: "guest", tick: 1)
                session.acceptPeer(playerID: "guest", displayName: "Alex")
                let restore = try XCTUnwrap(session.peerRestoreState(playerID: "guest"))
                XCTAssertGreaterThanOrEqual(restore.grantID, take.grantID, "the take is counted as applied")
                guest = try XCTUnwrap(makeInventory(from: restore.inventory))
            } else {
                session.updatePlayerState(playerState(dead: true))
                let drop = try XCTUnwrap(session.consumeDeathDrops(for: "guest"))
                onTheGround = drop.inventory.slots.filter { $0.itemID == iid("oak_planks") }.reduce(0) { $0 + $1.count }
                lanApplyTemplateTake(take.take, to: &guest)
                guest = guest.map { _ in nil }                      // the clear the transport sends
            }
            let held = guest.compactMap { $0 }.filter { $0.id == iid("oak_planks") }.reduce(0) { $0 + $1.count }
            let standing = (4..<8).filter { world.getBlockId($0, 64, 4) == Int(B.oak_planks) }.count
            XCTAssertEqual(standing, 4)
            XCTAssertEqual(held + onTheGround + standing, 10, leaves ? "disconnect" : "death")
        }
    }

    // MARK: - Seeded: death, leaving, unloading and jobs in flight

    /// One message from the host to the guest, in the order the transport sends them.
    private enum HostToGuest {
        case grant(LANInventoryGrant)
        /// The accepted or refused event for the guest's request; it follows that request's grants.
        case answer
    }

    /// The seeded rounds above with more of a real game in them: jobs run for several ticks
    /// while everything else goes on, the far chunk unloads and comes back, the guest dies and
    /// respawns (the host drops its copy and clears the guest), and leaves and rejoins (the host
    /// restores it). The guest behaves like the shipped client: one request at a time until the
    /// host answers, a publish when its inventory changed, always one just before it asks, and
    /// another after a take. The design accepts some losses; nothing may ever leave the guest
    /// with more planks, held, standing or on the ground, than it started with. The guest dies
    /// and leaves at any moment, also while a publish has crossed a take that is still on its way.
    func testNoInterleavingOfDeathRejoinOrUnloadPutsAGuestAhead() throws {
        var random = SplitMix64(state: 0x0DD5_EED5)
        let planks = iid("oak_planks")
        for round in 0..<150 {
            let world = loadedWorld()
            let session = hostSession()
            var inventory: [ItemStack?] = Array(repeating: nil, count: 36)
            let start = 20 + random.int(100)
            inventory[random.int(18)] = ItemStack(planks, min(64, start))
            if start > 64 { inventory[18 + random.int(18)] = ItemStack(planks, start - 64) }
            var revision = 0, appliedGrantID = 0, alive = true, awaiting = false
            var lastPublished: [LANInventorySlotSnapshot]?
            var wire: [HostToGuest] = []
            var far: Chunk?
            var trail: [String] = []

            func grantsOnTheWire() -> [LANInventoryGrant] {
                wire.compactMap { if case .grant(let grant) = $0 { return grant } else { return nil } }
            }
            func slots() -> [LANInventorySlotSnapshot] { makeLANInventorySlotSnapshots(inventory) }
            func publish(force: Bool) {
                guard alive, force || slots() != lastPublished else { return }
                lastPublished = slots()
                revision += 1
                _ = session.applyInventoryUpdate(LANInventoryUpdate(
                    playerID: "guest", revision: revision,
                    snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: lastPublished!),
                    appliedGrantID: appliedGrantID), from: "guest")
            }
            func apply(_ grant: LANInventoryGrant, to stacks: inout [ItemStack?]) {
                if grant.clearAll { stacks = Array(repeating: nil, count: stacks.count) }
                lanApplyTemplateTake(grant.take, to: &stacks)
                var row = TemplateMaterialSlots(copying: stacks)
                for item in grant.items { _ = row.put(itemID: item.itemID, count: item.count) }
                for index in row.touchedSlots { stacks[index] = row.stacks[index] }
            }
            func deliverOne() {
                guard !wire.isEmpty else { return }
                switch wire.removeFirst() {
                case .answer:
                    awaiting = false
                case .grant(let grant):
                    guard grant.grantID > appliedGrantID else { return }
                    appliedGrantID = grant.grantID
                    apply(grant, to: &inventory)
                    lastPublished = grant.take.isEmpty ? slots() : nil
                }
            }
            func collect() { wire.append(contentsOf: session.drainGrants(for: "guest").map(HostToGuest.grant)) }
            // The request is built after the publish, as the client does: it names that publish.
            func ask(_ makeIntent: () throws -> LANTemplateIntent) rethrows {
                publish(force: true)
                _ = session.applyTemplateIntent(try makeIntent(), from: "guest", world: world)
                collect()
                wire.append(.answer)
                awaiting = true
            }
            func heldOnceTheWireArrives() -> Int {
                var stacks = inventory.map(copyStack)
                var applied = appliedGrantID
                for grant in grantsOnTheWire() where grant.grantID > applied { applied = grant.grantID; apply(grant, to: &stacks) }
                return stacks.compactMap { $0 }.filter { $0.id == planks }.reduce(0) { $0 + $1.count }
            }
            func standing() -> Int {
                var count = (0..<CHUNK_W * 2).filter { world.getBlockId($0, 64, 4) == Int(B.oak_planks) }.count
                if let far { count += (0..<CHUNK_W).filter { Int(far.get($0, 64, 4)) >> 4 == Int(B.oak_planks) }.count }
                return count
            }
            func runJobs(_ budget: Int) {
                session.stepTemplateJobs(in: world, budgetPerPeer: budget)
                _ = session.drainTemplateIntentResponses()
                collect()
            }

            publish(force: false)
            for step in 0..<60 {
                let roll = random.int(12)
                trail.append(String(roll))
                switch roll {
                case 0:
                    publish(force: false)
                case 1:
                    inventory.swapAt(random.int(36), random.int(36))
                case 2, 3:
                    deliverOne()
                case 4 where alive && !awaiting:
                    let count = 1 + random.int(12)
                    // The client refuses what it can see it cannot pay.
                    guard inventory.compactMap({ $0 }).filter({ $0.id == planks }).reduce(0, { $0 + $1.count }) >= count else { break }
                    let x = random.int(13)
                    try ask { try self.placeIntent(self.row("oak_planks", count), x: x, appliedGrantID: appliedGrantID,
                                                   inventoryRevision: revision) }
                case 5 where alive && !awaiting:
                    ask { self.undoIntent(appliedGrantID: appliedGrantID, inventoryRevision: revision) }
                case 6:
                    runJobs(1 + random.int(4))
                case 7:
                    if let chunk = far { world.setChunk(chunk); far = nil } else { far = world.getChunk(1, 0); world.removeChunk(1, 0) }
                case 8:
                    if alive {
                        alive = false
                        session.updatePlayerState(playerState(dead: true))
                        if let drop = session.consumeDeathDrops(for: "guest") {
                            for slot in drop.inventory.slots {
                                _ = spawnItem(world, drop.x, drop.y, drop.z, ItemStack(slot.itemID, slot.count))
                            }
                            _ = session.enqueueGrant(items: [], xp: 0, clearAll: true, to: "guest")   // as the transport does
                        }
                        collect()
                    } else {
                        // The guest sees its death after the clear that came with it, and only then respawns.
                        while !wire.isEmpty { deliverOne() }
                        alive = true
                        session.updatePlayerState(playerState())
                    }
                case 9:
                    session.disconnectPeer(playerID: "guest", tick: step)
                    wire.removeAll()
                    awaiting = false
                    session.acceptPeer(playerID: "guest", displayName: "Alex")
                    let restore = try XCTUnwrap(session.peerRestoreState(playerID: "guest"))
                    var restored = try XCTUnwrap(makeInventory(from: restore.inventory))
                    restored += Array(repeating: nil, count: max(0, 36 - restored.count))
                    inventory = restored
                    appliedGrantID = restore.grantID
                    revision = restore.revision
                    lastPublished = slots()
                    alive = !restore.playerState.dead
                    collect()
                case 10:
                    while session.hasActiveTemplateJob(playerID: "guest") { runJobs(2_048) }
                default:
                    break
                }
                XCTAssertLessThanOrEqual(heldOnceTheWireArrives() + standing() + dropped(world, "oak_planks"), start,
                                         "seed 0x0DD5EED5 round \(round) step \(step) trail \(trail.joined(separator: ","))")
            }
            if let chunk = far { world.setChunk(chunk); far = nil }
            while session.hasActiveTemplateJob(playerID: "guest") { runJobs(2_048) }
            while !wire.isEmpty { deliverOne() }
            if !alive { alive = true; session.updatePlayerState(playerState()) }
            XCTAssertLessThanOrEqual(heldOnceTheWireArrives() + standing() + dropped(world, "oak_planks"), start, "round \(round)")
            publish(force: true)
            XCTAssertEqual(hostCopy(session)["oak_planks"] ?? 0, heldOnceTheWireArrives(), "round \(round)")
        }
    }
}

private extension LANTemplateIntentResult {
    var refundText: String? {
        if case .undone(_, _, let refund) = self { return refund }
        return nil
    }
}
