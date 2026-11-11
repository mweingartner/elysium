import XCTest
@testable import ElysiumCore

/// A LAN guest's object-template paste and undo. The host owns the world, so the guest must never
/// write its own mirror of it: it sends a `LANTemplateIntent` carrying the template from its own
/// library and shows the host's answers. The last test runs guest and host together, with every
/// message passed through the real frame codec.
@MainActor
final class LANClientTemplateRoutingTests: XCTestCase {
    // MARK: - fixtures

    private final class CapturingHost: GameHost {
        var actionBars: [String] = []
        var chat: [String] = []
        func showActionBar(_ text: String, _ time: Int) { actionBars.append(text) }
        func pushChat(_ line: String) { chat.append(line) }
        func hasScreen() -> Bool { false }; func screenPausesGame() -> Bool { false }
        func openScreen(_ kind: String, _ data: ScreenData?) {}
        func openTrading(_ villager: Mob) {}; func openVehicleChest(_ kind: String, _ vehicle: Entity) {}
        func openChat(_ prefix: String) {}; func openDeathScreen(_ message: String) {}
        func openPauseScreen() {}; func openTitleScreen() {}; func closeAllScreens() {}
        func releasePointer() {}; func capturePointer() {}
        func pushToast(_ adv: AdvancementDef) {}; func setBossBars(_ bars: [BossBarInfo]) {}
        func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double,
                       _ volume: Double, _ pitch: Double) {}
        func playUI(_ name: String) {}; func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
        func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {}
        func tickMusic(_ mood: String, _ enabled: Bool) {}; func stopDisc() {}
        func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double,
                          _ count: Int, _ spread: Double, _ cell: Int) {}
        func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double,
                                _ groundY: Double) {}
        func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {}
        func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {}; func clearAllSections() {}
    }

    private struct Guest {
        let game: GameCore
        let screen: CapturingHost
    }

    private var sentIntents: [LANTemplateIntent] = []

    override func setUp() {
        super.setUp()
        sentIntents = []
    }

    private func groundChunk(in world: World) -> Chunk {
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        for z in 0..<CHUNK_W {
            for x in 0..<CHUNK_W {
                chunk.set(x, 64, z, cell(B.dirt, 0))
            }
        }
        chunk.status = .generated
        world.setChunk(chunk)
        return chunk
    }

    /// A guest standing on flat ground and looking along +z, connected through a handler that
    /// records what it sends.
    private func makeGuest(connected: Bool = true, mode: Int = GameMode.creative) -> Guest {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lan-client-template")
        let screen = CapturingHost()
        game.host = screen
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "host world", worldName: "Host LAN", seed: 42, gameMode: GameMode.survival,
            difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2))
        // Most tests here are about what a guest sends and shows, not what a paste costs: their
        // guest is in creative, where a paste is free and the client checks no materials.
        game.player.setGameMode(mode)
        for index in game.player.inventory.indices { game.player.inventory[index] = nil }
        game.player.setPos(8.5, 65, 4.5)
        game.player.yaw = 0
        game.player.pitch = 0
        game.player.vx = 0
        game.player.vy = 0
        game.player.vz = 0
        let w = game.world
        let chunk = groundChunk(in: w)
        let sectionY = (64 - w.info.minY) / SECTION_H
        if let snapshot = makeLANChunkSectionSnapshot(from: chunk, dimension: w.dim.rawValue, sectionY: sectionY) {
            game.markLANChunkSectionsApplied([snapshot])
        }
        if connected {
            game.lanTemplateIntentHandler = { [unowned self] in self.sentIntents.append($0) }
        }
        screen.actionBars = []
        screen.chat = []
        return Guest(game: game, screen: screen)
    }

    private func marker(named name: String = "Marker") -> ObjectTemplate {
        ObjectTemplate(
            name: name,
            anchorX: 0, anchorY: 0, anchorZ: 0,
            sizeX: 1, sizeY: 1, sizeZ: 1,
            blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks, 0)))]
        )
    }

    /// Every cell of the fixture chunk's lower sections, so any local write shows up.
    private func mirrorCells(of game: GameCore) -> [Int] {
        var cells: [Int] = []
        for y in 60..<80 {
            for z in 0..<CHUNK_W {
                for x in 0..<CHUNK_W {
                    cells.append(game.world.getBlock(x, y, z))
                }
            }
        }
        return cells
    }

    private func step(_ game: GameCore, ticks: Int) {
        for _ in 0..<ticks { _ = game.frame(dtMs: TICK_MS) }
    }

    private func event(_ kind: LANGameplayEventKind, _ message: String) -> LANGameplayEvent {
        LANGameplayEvent(playerID: "guest", kind: kind, message: message, tick: 1)
    }

    // MARK: - the reported gap: nothing ghost-pastes

    func testGuestPasteNeverWritesTheMirrorWorld() throws {
        let guest = makeGuest()
        let before = mirrorCells(of: guest.game)

        try guest.game.beginTemplatePlacement(marker())
        XCTAssertNotNil(guest.game.templatePlacementTarget(), "the fixture must give the preview a target")
        guest.game.mouseDown(0)
        step(guest.game, ticks: 40)

        XCTAssertEqual(mirrorCells(of: guest.game), before,
                       "a guest's paste wrote blocks into its own mirror of the host's world")
        XCTAssertFalse(guest.game.hasActiveTemplatePlacementJob(),
                       "a guest must not run a local placement job against the mirror world")
        XCTAssertEqual(sentIntents.count, 1, "the paste must go to the host instead")
    }

    func testGuestUndoNeverWritesTheMirrorWorld() throws {
        let guest = makeGuest()
        let before = mirrorCells(of: guest.game)

        XCTAssertTrue(guest.game.undoLastTemplatePlacement(), "the undo request must go out")
        step(guest.game, ticks: 40)

        XCTAssertEqual(mirrorCells(of: guest.game), before,
                       "a guest's undo rewrote its own mirror of the host's world")
        XCTAssertNil(guest.game.lastTemplatePlacementUndo,
                     "a guest must not hold a local undo record for the host's world")
        XCTAssertEqual(sentIntents.map(\.action), [.undoPlacement])
        XCTAssertNil(sentIntents.first?.templateData, "an undo carries no template")
    }

    // MARK: - what the guest sends

    func testGuestPasteSendsItsOwnTemplateWithThePreviewTargetAndRotation() throws {
        let guest = makeGuest()
        let stairs = ObjectTemplate(
            name: "Step", anchorX: 1, anchorY: 0, anchorZ: 0, sizeX: 2, sizeY: 1, sizeZ: 3,
            blocks: [
                TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.oak_planks, 0))),
                TemplateBlock(dx: 1, dy: 0, dz: 2, cell: UInt16(cell(B.stone, 0))),
            ])
        try guest.game.beginTemplatePlacement(stairs)
        XCTAssertTrue(guest.game.rotateTemplatePlacement(by: 1))
        let target = try XCTUnwrap(guest.game.templatePlacementTarget())

        guest.game.mouseDown(0)

        let intent = try XCTUnwrap(sentIntents.first)
        XCTAssertEqual(intent.action, .placeTemplate)
        XCTAssertEqual(intent.templateName, "Step")
        XCTAssertEqual([intent.x, intent.y, intent.z], [target.targetX, target.targetY, target.targetZ])
        XCTAssertEqual(intent.rotation, 1)
        // The bytes are the unrotated template; the host rotates, as it does for its own paste.
        let sent = try lanHostTemplate(fromGuestPayload: try XCTUnwrap(intent.templateData))
        XCTAssertEqual(sent.name, "Step")
        XCTAssertEqual([sent.sizeX, sent.sizeY, sent.sizeZ], [2, 1, 3])
        XCTAssertEqual([sent.anchorX, sent.anchorY, sent.anchorZ], [1, 0, 0])
        XCTAssertEqual(sent.blocks, stairs.blocks)
        XCTAssertNotNil(guest.game.templatePlacement, "the preview stays armed until the host accepts")
        XCTAssertEqual(guest.screen.actionBars.last, "Asking the host to place \"Step\"")
    }

    func testGuestDoesNotSendASecondRequestWhileTheHostHasNotAnswered() throws {
        let guest = makeGuest()
        try guest.game.beginTemplatePlacement(marker())

        guest.game.mouseDown(0)
        guest.game.mouseDown(0)
        XCTAssertFalse(guest.game.undoLastTemplatePlacement())

        XCTAssertEqual(sentIntents.count, 1)
        XCTAssertEqual(guest.screen.actionBars.last, "Waiting for the host to answer")
    }

    func testGuestWithoutAConnectionSaysSoAndSendsNothing() throws {
        let guest = makeGuest(connected: false)
        try guest.game.beginTemplatePlacement(marker())

        guest.game.mouseDown(0)
        XCTAssertFalse(guest.game.undoLastTemplatePlacement())

        XCTAssertTrue(sentIntents.isEmpty)
        XCTAssertEqual(guest.screen.chat, ["§cNo active LAN connection.", "§cNo active LAN connection."])
        XCTAssertFalse(guest.game.hasActiveTemplatePlacementJob())
    }

    func testGuestRefusesToArmATemplateTooLargeForOneIntent() {
        let guest = makeGuest()
        var blocks: [TemplateBlock] = []
        let count = LAN_MULTIPLAYER_TEMPLATE_GUEST_BLOCK_GUIDE + 1
        outer: for y in 0..<96 {
            for z in 0..<96 {
                for x in 0..<96 {
                    if blocks.count == count { break outer }
                    blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: UInt16(cell(B.stone, 0))))
                }
            }
        }
        let huge = ObjectTemplate(name: "Huge", anchorX: 0, anchorY: 0, anchorZ: 0,
                                  sizeX: 96, sizeY: 96, sizeZ: 96, blocks: blocks)

        XCTAssertThrowsError(try guest.game.beginTemplatePlacement(huge)) { error in
            XCTAssertEqual(error as? TemplateError, .tooLargeForLANGuest(count))
            XCTAssertTrue(String(describing: error).contains("too large to place in a LAN game you joined"))
        }
        XCTAssertNil(guest.game.templatePlacement, "a template that cannot be sent must not arm a preview")
    }

    // MARK: - what the guest shows

    func testAcceptedPlacementClearsThePreviewAndReportsProgressAndCompletion() throws {
        let guest = makeGuest()
        try guest.game.beginTemplatePlacement(marker())
        guest.game.mouseDown(0)

        guest.game.applyLANTemplateEvent(event(.templatePlaceAccepted, "Placing \"Marker\""))
        XCTAssertNil(guest.game.templatePlacement, "the preview has done its job once the host accepts")
        XCTAssertEqual(guest.screen.actionBars.last, "Placing \"Marker\"")

        guest.game.applyLANTemplateEvent(event(.templateProgress, "Placing \"Marker\" 40% - placing blocks"))
        XCTAssertEqual(guest.screen.actionBars.last, "Placing \"Marker\" 40% - placing blocks")
        XCTAssertTrue(guest.screen.chat.isEmpty, "progress belongs in the action bar, not in chat")

        guest.game.applyLANTemplateEvent(event(
            .templateCompleted, "Placed object \"Marker\" - 1 blocks, 0 block entities"))
        XCTAssertEqual(guest.screen.chat, ["§7Placed object \"Marker\" - 1 blocks, 0 block entities"])
        XCTAssertEqual(guest.screen.actionBars.last, "Placed object \"Marker\"")
    }

    func testRefusedPlacementKeepsThePreviewSoThePlayerCanTryAgain() throws {
        let guest = makeGuest()
        try guest.game.beginTemplatePlacement(marker())
        guest.game.mouseDown(0)

        guest.game.applyLANTemplateEvent(event(.templateRefused, LANTemplateRefusal.outOfReach))

        XCTAssertNotNil(guest.game.templatePlacement)
        XCTAssertEqual(guest.screen.chat, ["§c" + LANTemplateRefusal.outOfReach])
        XCTAssertEqual(guest.screen.actionBars.last, LANTemplateRefusal.outOfReach)

        guest.game.mouseDown(0)
        XCTAssertEqual(sentIntents.count, 2, "after a refusal the same preview can be sent again")
    }

    func testGuestStopsWaitingWhenTheHostNeverAnswers() throws {
        let guest = makeGuest()
        try guest.game.beginTemplatePlacement(marker())
        guest.game.mouseDown(0)

        step(guest.game, ticks: LAN_CLIENT_TEMPLATE_ANSWER_TIMEOUT_TICKS - 1)
        guest.game.mouseDown(0)
        XCTAssertEqual(sentIntents.count, 1, "still waiting one tick before the timeout")

        step(guest.game, ticks: 1)
        XCTAssertEqual(guest.screen.chat, ["§cThe host did not answer. Try again."])
        guest.game.mouseDown(0)
        XCTAssertEqual(sentIntents.count, 2)
    }

    func testALateAcceptLeavesAPreviewArmedSinceAlone() throws {
        let guest = makeGuest()
        try guest.game.beginTemplatePlacement(marker(named: "First"))
        guest.game.mouseDown(0)
        step(guest.game, ticks: LAN_CLIENT_TEMPLATE_ANSWER_TIMEOUT_TICKS)
        XCTAssertEqual(guest.screen.chat, ["§cThe host did not answer. Try again."])

        // The player gives up on the first object and arms another; then the host's answer to
        // the first request arrives after all.
        guest.game.cancelTemplatePlacement(showMessage: false)
        try guest.game.beginTemplatePlacement(marker(named: "Second"))
        guest.game.applyLANTemplateEvent(event(.templatePlaceAccepted, "Placing \"First\""))

        XCTAssertEqual(guest.game.templatePlacement?.name, "Second", "the newer preview must stay armed")
        guest.game.mouseDown(0)
        XCTAssertEqual(sentIntents.count, 2)
        XCTAssertEqual(try lanHostTemplate(fromGuestPayload: try XCTUnwrap(sentIntents.last?.templateData)).name, "Second")
    }

    func testTemplateEventsAreIgnoredOutsideALANClientWorld() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lan-client-template-local")
        let screen = CapturingHost()
        game.host = screen

        game.applyLANTemplateEvent(event(.templateRefused, "nope"))

        XCTAssertTrue(screen.chat.isEmpty)
        XCTAssertTrue(screen.actionBars.isEmpty)
    }

    // MARK: - guest and host together

    /// Passes a message through the real frame codec, as the transport does.
    private func overTheWire(_ message: LANMultiplayerMessage) throws -> LANMultiplayerMessage {
        try LANMultiplayerFrameCodec.decode(try LANMultiplayerFrameCodec.encode(message, sequence: 1)).message
    }

    private func deliver(_ result: LANTemplateIntentResult, to guest: Guest) throws {
        let sent = LANMultiplayerMessage.gameplayEvent(
            lanTemplateGameplayEvent(for: result, playerID: "guest", tick: 1))
        guard case .gameplayEvent(let received) = try overTheWire(sent) else {
            return XCTFail("a gameplay event must survive the frame codec")
        }
        guest.game.applyLANTemplateEvent(received)
    }

    private func sendLastIntent(to session: LANMultiplayerHostSession, world: World) throws -> LANTemplateIntentResult {
        let sent = LANMultiplayerMessage.templateIntent(playerID: "guest", intent: try XCTUnwrap(sentIntents.last))
        guard case .templateIntent(let playerID, let received) = try overTheWire(sent) else {
            XCTFail("a template intent must survive the frame codec")
            return .rejected("not delivered")
        }
        return session.applyTemplateIntent(received, from: playerID, world: world)
    }

    private func runHostJob(_ session: LANMultiplayerHostSession, world: World, to guest: Guest) throws {
        var steps = 0
        while session.hasActiveTemplateJob(playerID: "guest") {
            session.stepTemplateJobs(in: world)
            steps += 1
            XCTAssertLessThan(steps, 64, "the host's job did not finish")
            if steps >= 64 { return }
        }
        for (_, result) in session.drainTemplateIntentResponses() { try deliver(result, to: guest) }
    }

    func testGuestPasteAndUndoChangeTheHostWorldAndTheGuestHearsBack() throws {
        let guest = makeGuest()
        let mirrorBefore = mirrorCells(of: guest.game)
        let hostWorld = World(dim: .overworld, seed: 42)
        _ = groundChunk(in: hostWorld)
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        session.updatePlayerState(makeLANPlayerState(guest.game.player, playerID: "guest", displayName: "Alex"))
        session.letPasteForFree("guest")

        try guest.game.beginTemplatePlacement(marker())
        let target = try XCTUnwrap(guest.game.templatePlacementTarget())
        // The marker's preview sits six blocks ahead: one block beyond survival block reach is
        // already further than the host's ordinary reach rule would allow.
        XCTAssertGreaterThanOrEqual(target.distance, 6)
        let hostBefore = hostWorld.getBlock(target.targetX, target.targetY, target.targetZ)
        guest.game.mouseDown(0)

        let admitted = try sendLastIntent(to: session, world: hostWorld)
        XCTAssertEqual(admitted, .accepted(action: .placeTemplate, name: "Marker"))
        try deliver(admitted, to: guest)
        XCTAssertNil(guest.game.templatePlacement)
        try runHostJob(session, world: hostWorld, to: guest)

        XCTAssertEqual(hostWorld.getBlock(target.targetX, target.targetY, target.targetZ), Int(cell(B.oak_planks, 0)),
                       "the paste must land in the host's world where the guest's preview stood")
        XCTAssertEqual(guest.screen.chat.count, 1)
        XCTAssertTrue(guest.screen.chat[0].hasPrefix("§7Placed object \"Marker\" - 1 blocks"), guest.screen.chat[0])

        XCTAssertTrue(guest.game.undoLastTemplatePlacement())
        let undoing = try sendLastIntent(to: session, world: hostWorld)
        XCTAssertEqual(undoing, .accepted(action: .undoPlacement, name: "Marker"))
        try deliver(undoing, to: guest)
        try runHostJob(session, world: hostWorld, to: guest)

        XCTAssertEqual(hostWorld.getBlock(target.targetX, target.targetY, target.targetZ), hostBefore)
        XCTAssertEqual(guest.screen.chat.count, 2)
        XCTAssertTrue(guest.screen.chat[1].hasPrefix("§7Undid object placement \"Marker\""), guest.screen.chat[1])
        XCTAssertEqual(mirrorCells(of: guest.game), mirrorBefore,
                       "only replication may change the guest's mirror; the guest itself never wrote it")

        // A second undo has nothing left: the host says so and the guest shows it.
        XCTAssertTrue(guest.game.undoLastTemplatePlacement())
        let nothing = try sendLastIntent(to: session, world: hostWorld)
        XCTAssertEqual(nothing, .rejected(LANTemplateRefusal.nothingToUndo))
        try deliver(nothing, to: guest)
        XCTAssertEqual(guest.screen.chat.last, "§c" + LANTemplateRefusal.nothingToUndo)
    }

    // MARK: - a survival guest pays, end to end

    /// A guest in survival and its host, with every message through the frame codec and the
    /// host's grants applied by the real client: the click pays, the blocks arrive, undo pays back.
    func testASurvivalGuestPaysForItsPasteAndIsPaidBackByUndo() throws {
        let guest = makeGuest(mode: GameMode.survival)
        let hostWorld = World(dim: .overworld, seed: 42)
        _ = groundChunk(in: hostWorld)
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        session.updatePlayerState(makeLANPlayerState(guest.game.player, playerID: "guest", displayName: "Alex"))
        // As the transport does: each publish says which grants the guest had applied.
        guest.game.lanInventoryPublishHandler = { [unowned game = guest.game] snapshot, revision in
            _ = session.applyInventoryUpdate(LANInventoryUpdate(
                playerID: "guest", revision: revision, snapshot: snapshot,
                appliedGrantID: game.lanLastAppliedGrantID), from: "guest")
        }
        func carried(_ name: String = "oak_planks") -> Int { guest.game.player.countItem(iid(name)) }
        func hostCopy(_ name: String = "oak_planks") -> Int {
            (session.peerInventorySnapshotsByPlayerID()["guest"]?.slots ?? [])
                .filter { $0.itemID == iid(name) }.reduce(0) { $0 + $1.count }
        }
        func deliverGrants() throws {
            for grant in session.drainGrants(for: "guest") {
                guard case .inventoryGrant(let received) = try overTheWire(.inventoryGrant(grant)) else {
                    return XCTFail("a grant must survive the frame codec")
                }
                guest.game.applyLANGrant(received)
            }
        }

        // Nothing carried: the client itself says what is missing and asks nobody.
        try guest.game.beginTemplatePlacement(marker())
        XCTAssertEqual(guest.screen.chat, ["§eCosts 1 material. Still missing 1 Oak Planks."])
        guest.game.mouseDown(0)
        XCTAssertTrue(sentIntents.isEmpty, "a paste the guest can see it cannot pay is not sent")
        XCTAssertEqual(guest.screen.chat.last, "§cMissing 1 Oak Planks - nothing was placed.")
        XCTAssertNotNil(guest.game.templatePlacement, "the preview stays armed")

        // With planks in a slot the host has not heard of yet: the click publishes, then asks.
        // The marker floats one block above the ground, so the host has to fill under it, and
        // only the host knows that: it refuses for the dirt the guest's own quote could not see.
        guest.game.player.inventory[7] = stack("oak_planks", 5)
        let target = try XCTUnwrap(guest.game.templatePlacementTarget())
        guest.game.mouseDown(0)
        XCTAssertEqual(hostCopy(), 5, "the host hears the inventory before it hears the request")
        let short = try sendLastIntent(to: session, world: hostWorld)
        XCTAssertEqual(short, .rejected("Missing 1 Dirt - nothing was placed."))
        try deliver(short, to: guest)
        XCTAssertEqual(guest.screen.chat.last, "§cMissing 1 Dirt - nothing was placed.")
        XCTAssertNotNil(guest.game.templatePlacement)
        XCTAssertEqual(session.drainGrants(for: "guest").count, 0)
        XCTAssertEqual(carried(), 5)

        guest.game.player.inventory[8] = stack("dirt", 3)
        guest.game.mouseDown(0)
        let admitted = try sendLastIntent(to: session, world: hostWorld)
        XCTAssertEqual(admitted, .accepted(action: .placeTemplate, name: "Marker"))
        XCTAssertEqual(hostCopy(), 4)
        XCTAssertEqual(hostCopy("dirt"), 2)
        try deliverGrants()                                  // the payment goes out before the answer
        XCTAssertEqual(carried(), 4, "the guest removes what the host took")
        XCTAssertEqual(carried("dirt"), 2)
        try deliver(admitted, to: guest)
        try runHostJob(session, world: hostWorld, to: guest)
        XCTAssertEqual(hostWorld.getBlock(target.targetX, target.targetY, target.targetZ), Int(cell(B.oak_planks, 0)))
        XCTAssertEqual(hostWorld.getBlockId(target.targetX, target.targetY - 1, target.targetZ), Int(B.dirt))
        XCTAssertTrue(guest.screen.chat.last?.hasSuffix("Used 2 materials.") == true,
                      "\(guest.screen.chat)")

        // Undo: the plank and the dirt still stand, so both come back.
        XCTAssertTrue(guest.game.undoLastTemplatePlacement())
        let undoing = try sendLastIntent(to: session, world: hostWorld)
        XCTAssertEqual(undoing, .accepted(action: .undoPlacement, name: "Marker"))
        try deliver(undoing, to: guest)
        try runHostJob(session, world: hostWorld, to: guest)
        try deliverGrants()
        XCTAssertEqual(carried(), 5)
        XCTAssertEqual(carried("dirt"), 3)
        XCTAssertEqual(hostCopy(), 5)
        XCTAssertEqual(hostCopy("dirt"), 3)
        XCTAssertTrue(guest.screen.chat.last?.hasSuffix("Returned 2 materials.") == true,
                      "\(guest.screen.chat)")
        XCTAssertEqual(hostWorld.getBlock(target.targetX, target.targetY, target.targetZ), 0)
    }

    /// The host's copy of a guest's inventory does not show what a stack holds, so a filled
    /// shulker box looks plain to it. The guest's own client refuses to pay with one.
    func testAGuestDoesNotAskToPayWithAFilledShulkerBox() throws {
        let guest = makeGuest(mode: GameMode.survival)
        var filled = StackData()
        filled.contents = [stack("diamond", 64)]
        guest.game.player.inventory[0] = ItemStack(iid("shulker_box"), 1, data: filled)
        let box = ObjectTemplate(name: "Box", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 1, sizeY: 1, sizeZ: 1,
                                 blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.shulker_box, 0)))])
        try guest.game.beginTemplatePlacement(box)
        guest.game.mouseDown(0)
        XCTAssertTrue(sentIntents.isEmpty)
        XCTAssertEqual(guest.screen.chat.last, "§cMissing 1 Shulker Box - nothing was placed.")
        XCTAssertNotNil(guest.game.player.inventory[0]?.data.contents)
    }

    // MARK: - a survival guest pays: the client's part, deeper

    /// Every request is preceded by a publish of what the guest holds now, even when nothing
    /// changed since the last one, and names the last grant the guest applied.
    func testAGuestPublishesJustBeforeEachRequestAndNamesTheLastGrantItApplied() throws {
        let guest = makeGuest(mode: GameMode.survival)
        var log: [String] = []
        guest.game.lanInventoryPublishHandler = { snapshot, revision in
            log.append("publish \(revision) planks \(snapshot.slots.filter { $0.itemID == iid("oak_planks") }.reduce(0) { $0 + $1.count })")
        }
        guest.game.lanTemplateIntentHandler = { intent in log.append("intent \(intent.action) applied \(intent.appliedGrantID)") }
        guest.game.player.inventory[4] = stack("oak_planks", 2)
        step(guest.game, ticks: 1)
        guest.game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 7,
                                                   items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 1)],
                                                   xp: 0, clearAll: false))
        step(guest.game, ticks: 1)
        XCTAssertEqual(log, ["publish 1 planks 2"], "a plain grant is not published back: the host already counted it")
        log = []

        try guest.game.beginTemplatePlacement(marker())
        guest.game.mouseDown(0)
        XCTAssertEqual(log, ["publish 3 planks 3", "intent placeTemplate applied 7"])
        try deliver(.rejected(LANTemplateRefusal.outOfReach), to: guest)
        log = []
        XCTAssertTrue(guest.game.undoLastTemplatePlacement())
        XCTAssertEqual(log, ["publish 4 planks 3", "intent undoPlacement applied 7"], "published although nothing changed")
    }

    /// After a take the guest publishes on its next tick, so the host's copy cannot stay behind
    /// a publish that crossed the take. A grant that only adds is not published back.
    func testAfterATakeTheGuestPublishesAgainOnItsNextTick() {
        let guest = makeGuest(mode: GameMode.survival)
        var published: [Int] = []
        guest.game.lanInventoryPublishHandler = { snapshot, _ in
            published.append(snapshot.slots.filter { $0.itemID == iid("oak_planks") }.reduce(0) { $0 + $1.count })
        }
        guest.game.player.inventory[2] = stack("oak_planks", 9)
        step(guest.game, ticks: 1)
        XCTAssertEqual(published, [9])
        guest.game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 1, items: [], xp: 0, clearAll: false,
                                                   take: [LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 4)]))
        XCTAssertEqual(guest.game.player.countItem(iid("oak_planks")), 5)
        XCTAssertEqual(guest.game.lanLastAppliedGrantID, 1)
        step(guest.game, ticks: 1)
        XCTAssertEqual(published, [9, 5])
        step(guest.game, ticks: 3)
        XCTAssertEqual(published, [9, 5], "once")
        // A take the guest already applied is not applied twice, and is not published again.
        guest.game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 1, items: [], xp: 0, clearAll: false,
                                                   take: [LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 4)]))
        step(guest.game, ticks: 1)
        XCTAssertEqual(guest.game.player.countItem(iid("oak_planks")), 5)
        XCTAssertEqual(published, [9, 5])
    }

    /// The client's own check counts what the host's take can remove: a renamed stack is no
    /// payment there either. A guest in creative is not checked at all.
    func testTheClientCountsOnlyWhatATakeCanRemove() throws {
        let renamed = makeGuest(mode: GameMode.survival)
        renamed.game.player.inventory[0] = ItemStack(iid("oak_planks"), 5, label: "Keep")
        try renamed.game.beginTemplatePlacement(marker())
        renamed.game.mouseDown(0)
        XCTAssertTrue(sentIntents.isEmpty)
        XCTAssertEqual(renamed.screen.chat.last, "§cMissing 1 Oak Planks - nothing was placed.")

        let creative = makeGuest(mode: GameMode.creative)
        try creative.game.beginTemplatePlacement(marker())
        creative.game.mouseDown(0)
        XCTAssertEqual(sentIntents.count, 1, "creative carries nothing and still asks: the host decides")
    }

    /// FINDING (low): a grant that only adds (a refund, a pickup) sets the client's last
    /// published inventory to what it holds after the grant, on the assumption that the host's
    /// copy already counts it. A publish that crossed the grant, such as the one every request
    /// now sends first, has replaced the copy with the inventory before the grant, and nothing
    /// publishes again. Here the guest asks to undo once more while its refund is on its way:
    /// the host's copy stays one plank short until something else changes the inventory. A
    /// disconnect or a death in that time loses the plank. It is a loss only, a picked-up item
    /// has always had the same window, and the decision record lists it as accepted. Expected to
    /// fail until the host keeps every grant a published snapshot does not include yet, as it
    /// already does for a payment (`Peer.pendingTake`). Publishing back after every grant is not
    /// the fix: a publish that crosses a second grant would drop a host-crafted quality item
    /// from the copy, and the host refuses a later publish that brings one back.
    func testARefundThatCrossesTheNextRequestsPublishIsMissingFromTheHostsCopy() throws {
        let guest = makeGuest(mode: GameMode.survival)
        let hostWorld = World(dim: .overworld, seed: 42)
        _ = groundChunk(in: hostWorld)
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        session.updatePlayerState(makeLANPlayerState(guest.game.player, playerID: "guest", displayName: "Alex"))
        guest.game.lanInventoryPublishHandler = { [unowned game = guest.game] snapshot, revision in
            _ = session.applyInventoryUpdate(LANInventoryUpdate(
                playerID: "guest", revision: revision, snapshot: snapshot,
                appliedGrantID: game.lanLastAppliedGrantID), from: "guest")
        }
        func carried() -> Int { guest.game.player.countItem(iid("oak_planks")) }
        func hostCopy() -> Int {
            (session.peerInventorySnapshotsByPlayerID()["guest"]?.slots ?? [])
                .filter { $0.itemID == iid("oak_planks") }.reduce(0) { $0 + $1.count }
        }
        func deliverGrants(_ grants: [LANInventoryGrant]) throws {
            for grant in grants {
                guard case .inventoryGrant(let received) = try overTheWire(.inventoryGrant(grant)) else {
                    return XCTFail("a grant must survive the frame codec")
                }
                guest.game.applyLANGrant(received)
            }
        }
        guest.game.player.inventory[7] = stack("oak_planks", 5)
        guest.game.player.inventory[8] = stack("dirt", 3)
        try guest.game.beginTemplatePlacement(marker())
        guest.game.mouseDown(0)
        let admitted = try sendLastIntent(to: session, world: hostWorld)
        XCTAssertEqual(admitted, .accepted(action: .placeTemplate, name: "Marker"))
        try deliverGrants(session.drainGrants(for: "guest"))
        try deliver(admitted, to: guest)
        try runHostJob(session, world: hostWorld, to: guest)
        step(guest.game, ticks: 1)
        XCTAssertEqual(hostCopy(), 4)

        XCTAssertTrue(guest.game.undoLastTemplatePlacement())
        let undoing = try sendLastIntent(to: session, world: hostWorld)
        XCTAssertEqual(undoing, .accepted(action: .undoPlacement, name: "Marker"))
        try deliver(undoing, to: guest)
        try runHostJob(session, world: hostWorld, to: guest)
        let refund = session.drainGrants(for: "guest")          // still on its way
        XCTAssertEqual(hostCopy(), 5, "the host counted the refund into its copy")

        XCTAssertTrue(guest.game.undoLastTemplatePlacement())
        XCTAssertEqual(try sendLastIntent(to: session, world: hostWorld), .rejected(LANTemplateRefusal.nothingToUndo))
        XCTAssertEqual(hostCopy(), 4, "the request's publish did not hold the refund yet")
        try deliverGrants(refund)
        step(guest.game, ticks: 5)
        XCTAssertEqual(carried(), 5)
        XCTExpectFailure("T2: an additive grant that crossed a publish is never published back") {
            XCTAssertEqual(hostCopy(), carried())
        }
    }

    // MARK: - rotation, end to end

    /// Five different blocks, no two alike, in a box whose anchor is not at its origin: any
    /// mix-up of axes, mirror or anchor shows as a block in the wrong place.
    private func asymmetricTemplate() -> ObjectTemplate {
        let blocks: [(Int, Int, Int, UInt16)] = [
            (0, 0, 0, B.oak_planks), (2, 0, 0, B.bricks), (1, 0, 1, B.glass),
            (0, 1, 1, B.dark_oak_planks), (2, 1, 1, B.mossy_stone_bricks),
        ]
        return ObjectTemplate(
            name: "Crooked", anchorX: 2, anchorY: 0, anchorZ: 1, sizeX: 3, sizeY: 2, sizeZ: 2,
            blocks: blocks.map { TemplateBlock(dx: $0.0, dy: $0.1, dz: $0.2, cell: UInt16(cell($0.3, 0))) })
    }

    func testGuestPasteLandsWhereItsOwnPreviewStoodForEveryRotation() throws {
        for rotation in 0..<4 {
            sentIntents = []
            let guest = makeGuest()
            let hostWorld = World(dim: .overworld, seed: 42)
            _ = groundChunk(in: hostWorld)
            let session = LANMultiplayerHostSession()
            session.acceptPeer(playerID: "guest", displayName: "Alex")
            session.updatePlayerState(makeLANPlayerState(guest.game.player, playerID: "guest", displayName: "Alex"))
        session.letPasteForFree("guest")

            try guest.game.beginTemplatePlacement(asymmetricTemplate())
            if rotation > 0 { XCTAssertTrue(guest.game.rotateTemplatePlacement(by: rotation)) }
            let preview = try XCTUnwrap(guest.game.templatePlacement)
            XCTAssertEqual(preview.rotationSteps, rotation)
            let target = try XCTUnwrap(guest.game.templatePlacementTarget())
            // Where the guest's wireframe drew each block.
            var expected: [String: Int] = [:]
            for block in preview.rotatedTemplate.blocks {
                expected["\(target.originX + block.dx),\(target.originY + block.dy),\(target.originZ + block.dz)"] =
                    skillTreePlayerPlacedCell(Int(block.cell))
            }
            XCTAssertEqual(expected.count, 5)

            guest.game.mouseDown(0)
            XCTAssertEqual(try sendLastIntent(to: session, world: hostWorld),
                           .accepted(action: .placeTemplate, name: "Crooked"), "rotation \(rotation)")
            try runHostJob(session, world: hostWorld, to: guest)

            // Every cell of the preview's box above the ground holds exactly what the preview drew.
            let size = (x: preview.rotatedTemplate.sizeX, y: preview.rotatedTemplate.sizeY, z: preview.rotatedTemplate.sizeZ)
            for dy in 0..<size.y {
                for dz in 0..<size.z {
                    for dx in 0..<size.x {
                        let (x, y, z) = (target.originX + dx, target.originY + dy, target.originZ + dz)
                        XCTAssertEqual(hostWorld.getBlock(x, y, z), expected["\(x),\(y),\(z)"] ?? 0,
                                       "rotation \(rotation): host cell \(x),\(y),\(z) differs from the guest's preview")
                    }
                }
            }
        }
    }

    // MARK: - the guest's request state

    func testAnswersThatArriveWhenNothingIsAwaitedLeaveTheGuestFreeToAsk() throws {
        let guest = makeGuest()

        guest.game.applyLANTemplateEvent(event(.templateProgress, "Placing \"Marker\" 50% - placing blocks"))
        guest.game.applyLANTemplateEvent(event(.templateUndoAccepted, "Undoing \"Marker\""))
        guest.game.applyLANTemplateEvent(event(.templatePlaceAccepted, "Placing \"Marker\""))
        guest.game.applyLANTemplateEvent(event(.templateRefused, LANTemplateRefusal.busy))
        guest.game.applyLANTemplateEvent(event(.templateCompleted, "Undid object placement \"Marker\" - restored 3 cells"))

        XCTAssertEqual(guest.screen.chat, ["§c" + LANTemplateRefusal.busy,
                                           "§7Undid object placement \"Marker\" - restored 3 cells"])
        XCTAssertEqual(guest.screen.actionBars.last, "Undid object placement \"Marker\"")
        XCTAssertNil(guest.game.templatePlacement)
        XCTAssertTrue(guest.game.undoLastTemplatePlacement(), "stray answers must not leave the guest waiting")
        XCTAssertEqual(sentIntents.map(\.action), [.undoPlacement])
    }

    func testAnAcceptAfterTheTimeoutStillEndsThePreviewAndLeavesNothingWaiting() throws {
        let guest = makeGuest()
        try guest.game.beginTemplatePlacement(marker())
        guest.game.mouseDown(0)
        step(guest.game, ticks: LAN_CLIENT_TEMPLATE_ANSWER_TIMEOUT_TICKS)
        XCTAssertEqual(guest.screen.chat, ["§cThe host did not answer. Try again."])
        XCTAssertNotNil(guest.game.templatePlacement, "a timed-out paste keeps its preview for a retry")

        guest.game.applyLANTemplateEvent(event(.templatePlaceAccepted, "Placing \"Marker\""))

        XCTAssertNil(guest.game.templatePlacement, "the host is placing it after all")
        XCTAssertNil(guest.game.lanClientTemplates.payload)
        XCTAssertTrue(guest.game.undoLastTemplatePlacement())
        XCTAssertEqual(sentIntents.map(\.action), [.placeTemplate, .undoPlacement])
    }

    func testACompletionWithoutAnAcceptDoesNotEndAWaitForAnotherRequest() throws {
        let guest = makeGuest()
        XCTAssertTrue(guest.game.undoLastTemplatePlacement())

        // The completion of an earlier paste: informative, but it does not answer the undo.
        guest.game.applyLANTemplateEvent(event(.templateCompleted, "Placed object \"Marker\" - 1 blocks, 0 block entities"))

        XCTAssertEqual(guest.screen.chat, ["§7Placed object \"Marker\" - 1 blocks, 0 block entities"])
        XCTAssertEqual(guest.screen.actionBars.last, "Placed object \"Marker\"")
        XCTAssertFalse(guest.game.undoLastTemplatePlacement(), "the undo is still unanswered")
        XCTAssertEqual(guest.screen.actionBars.last, "Waiting for the host to answer")
        XCTAssertEqual(sentIntents.count, 1)
    }

    func testARefusalAfterThePreviewWasCancelledDoesNotBringItBack() throws {
        let guest = makeGuest()
        try guest.game.beginTemplatePlacement(marker())
        guest.game.mouseDown(0)
        guest.game.mouseDown(2) // right click cancels the preview while the host decides
        XCTAssertNil(guest.game.templatePlacement)

        guest.game.applyLANTemplateEvent(event(.templateRefused, LANTemplateRefusal.outOfReach))

        XCTAssertNil(guest.game.templatePlacement)
        XCTAssertEqual(guest.screen.chat, ["§c" + LANTemplateRefusal.outOfReach])
        guest.game.mouseDown(0)
        XCTAssertEqual(sentIntents.count, 1, "with no preview a click sends nothing")
        XCTAssertTrue(guest.game.undoLastTemplatePlacement(), "the refusal ended the wait")
    }

    func testLeavingTheLANWorldMidRequestForgetsItAndIgnoresLateAnswers() throws {
        let guest = makeGuest()
        try guest.game.beginTemplatePlacement(marker())
        guest.game.mouseDown(0)
        XCTAssertNotNil(guest.game.lanClientTemplates.awaiting)

        guest.game.exitToTitle()
        guest.screen.chat = []
        guest.screen.actionBars = []
        guest.game.applyLANTemplateEvent(event(.templateRefused, LANTemplateRefusal.busy))
        XCTAssertTrue(guest.screen.chat.isEmpty, "an answer for a world the guest left must not show")
        XCTAssertTrue(guest.screen.actionBars.isEmpty)

        guest.game.enterLANClientWorld(LANWorldSummary(
            worldID: "host world", worldName: "Host LAN", seed: 42, gameMode: GameMode.survival,
            difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2))
        XCTAssertNil(guest.game.templatePlacement)
        XCTAssertNil(guest.game.lanClientTemplates.awaiting)
        XCTAssertNil(guest.game.lanClientTemplates.payload)
        XCTAssertTrue(guest.game.undoLastTemplatePlacement(), "a fresh LAN world starts with nothing awaited")
        XCTAssertEqual(sentIntents.map(\.action), [.placeTemplate, .undoPlacement])
    }

    func testATooLargeTemplateLeavesTheArmedPreviewAndItsPayloadTogether() throws {
        let guest = makeGuest()
        try guest.game.beginTemplatePlacement(marker(named: "Small"))
        var blocks: [TemplateBlock] = []
        outer: for y in 0..<96 {
            for z in 0..<96 {
                for x in 0..<96 {
                    if blocks.count > LAN_MULTIPLAYER_TEMPLATE_GUEST_BLOCK_GUIDE { break outer }
                    blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: UInt16(cell(B.oak_planks, 0))))
                }
            }
        }
        let huge = ObjectTemplate(name: "Huge", anchorX: 0, anchorY: 0, anchorZ: 0,
                                  sizeX: 96, sizeY: 96, sizeZ: 96, blocks: blocks)
        XCTAssertThrowsError(try guest.game.beginTemplatePlacement(huge))

        XCTAssertEqual(guest.game.templatePlacement?.name, "Small")
        guest.game.mouseDown(0)
        let intent = try XCTUnwrap(sentIntents.first)
        XCTAssertEqual(intent.templateName, "Small")
        XCTAssertEqual(try lanHostTemplate(fromGuestPayload: try XCTUnwrap(intent.templateData)).name, "Small",
                       "the bytes sent must be the template the preview shows")
    }
}
