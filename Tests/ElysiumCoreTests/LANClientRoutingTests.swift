import XCTest
@testable import ElysiumCore

/// Exercises GameCore's LAN client-side gameplay routing (W3): every behavior here is gated on
/// `isLANClientWorld` and none of it mutates the local mirror world directly — intents are
/// captured via the public handler hooks instead of a live transport.
@MainActor
final class LANClientRoutingTests: XCTestCase {
    // MARK: - fixtures

    private func makeLANClientGame() -> GameCore {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lan-client-routing")
        let summary = LANWorldSummary(
            worldID: "host world",
            worldName: "Host LAN",
            seed: 42,
            gameMode: GameMode.survival,
            difficulty: 2,
            dimension: Dim.overworld.rawValue,
            playerCount: 2
        )
        game.enterLANClientWorld(summary)
        game.player.setPos(8.5, 65, 8.5)
        game.player.yaw = 0
        game.player.pitch = 0
        game.player.vx = 0
        game.player.vy = 0
        game.player.vz = 0
        buildGround(in: game)
        return game
    }

    /// installs a full section of dirt covering the player's feet and a solid wall two blocks
    /// ahead at eye height, and registers the sections as LAN-applied so streaming/visibility
    /// checks see a complete local neighborhood.
    @discardableResult
    private func buildGround(in game: GameCore) -> Chunk {
        let w = game.world
        let sectionY = (64 - w.info.minY) / SECTION_H // section covering y in [64, 79]
        let chunk = Chunk(cx: 0, cz: 0, minY: w.info.minY, height: w.info.height)
        for z in 0..<CHUNK_W {
            for x in 0..<CHUNK_W {
                chunk.set(x, 64, z, cell(B.dirt, 0))
            }
        }
        // solid wall at z=10 spanning the player's eye height so a straight-ahead raycast
        // (yaw=0, pitch=0 looks toward +z) always hits a block face
        for y in 66...67 {
            for x in 0..<CHUNK_W {
                chunk.set(x, y, 10, cell(B.stone, 0))
            }
        }
        chunk.status = .generated
        w.setChunk(chunk)
        if let snapshot = makeLANChunkSectionSnapshot(from: chunk, dimension: w.dim.rawValue, sectionY: sectionY) {
            game.markLANChunkSectionsApplied([snapshot])
        }
        return chunk
    }

    /// runs exactly one simulation tick (frame's fixed-step accumulator fires once for a
    /// dtMs equal to the tick length)
    private func stepOneTick(_ game: GameCore) {
        _ = game.frame(dtMs: TICK_MS)
    }

    // MARK: - attack vs mine dispatch (mouseDown button 0)

    func testMouseDownOnMirrorMobEmitsAttackIntentTargetingHostEntityID() {
        let game = makeLANClientGame()
        let mirror = Zombie(world: game.world)
        mirror.lanReplicatedMirror = true
        mirror.lanReplicationSourceID = 777
        // between the player (z=8.5) and the fixture's wall (z=10) so the block raycast
        // doesn't shadow the entity hit
        mirror.setPos(8.5, 65, 9.5)
        game.world.addEntity(mirror)

        var captured: [LANAttackIntent] = []
        game.lanAttackIntentHandler = { captured.append($0) }
        var blockIntents: [LANBlockIntent] = []
        game.lanBlockIntentHandler = { blockIntents.append($0) }

        game.mouseDown(0)

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.targetEntityID, 777)
        XCTAssertTrue(blockIntents.isEmpty)
    }

    func testMouseDownOnBlockStartsMiningAndEmitsBreakIntentOnCompletion() {
        let game = makeLANClientGame()
        var captured: [LANBlockIntent] = []
        game.lanBlockIntentHandler = { captured.append($0) }
        game.lanAttackIntentHandler = { _ in XCTFail("no entity under crosshair — must not attack") }

        game.mouseDown(0)
        XCTAssertTrue(captured.isEmpty, "mining must not emit an intent before progress completes")

        let originalCell = game.world.getBlock(8, 66, 10)
        for _ in 0..<200 {
            stepOneTick(game)
            if !captured.isEmpty { break }
        }

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.action, .breakBlock)
        XCTAssertEqual(captured.first?.x, 8)
        XCTAssertEqual(captured.first?.y, 66)
        XCTAssertEqual(captured.first?.z, 10)
        // the LAN client mirror world is never mutated locally — only the host applies breaks
        XCTAssertEqual(game.world.getBlock(8, 66, 10), originalCell)
    }

    // MARK: - placement

    func testRightClickWithBlockHeldEmitsPlaceBlockIntentWithoutMutatingWorld() {
        let game = makeLANClientGame()
        game.player.mainHand = ItemStack(iid("dirt"), 64)
        var captured: [LANBlockIntent] = []
        game.lanBlockIntentHandler = { captured.append($0) }

        game.mouseDown(2)

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.action, .placeBlock)
        XCTAssertEqual(captured.first?.x, 8)
        XCTAssertEqual(captured.first?.y, 66)
        XCTAssertEqual(captured.first?.z, 10)
        // placement target is one block closer than the wall (face toward the player)
        XCTAssertEqual(captured.first.map { Int($0.cell) >> 4 }, Int(B.dirt))
        // the mirror world itself was never touched — the wall block is unchanged and the
        // space in front of it is still air
        XCTAssertEqual(game.world.getBlock(8, 66, 10) >> 4, Int(B.stone))
        XCTAssertEqual(game.world.getBlock(8, 66, 9), 0)
    }

    func testRightClickOpenableWithBlockHeldEmitsUseBeforePlace() {
        let game = makeLANClientGame()
        guard let chunk = game.world.getChunkAt(8, 10) else {
            return XCTFail("test fixture missing loaded chunk")
        }
        chunk.set(8, 66, 10, cell(B.oak_door, 0))
        chunk.set(8, 67, 10, cell(B.oak_door, 8))
        game.player.mainHand = ItemStack(iid("dirt"), 64)
        var captured: [LANBlockIntent] = []
        game.lanBlockIntentHandler = { captured.append($0) }

        game.mouseDown(2)

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.action, .useBlock)
        XCTAssertEqual(captured.first?.x, 8)
        XCTAssertEqual(captured.first?.z, 10)
        // The LAN mirror does not locally toggle or place; the host's authoritative echo will.
        XCTAssertEqual(game.world.getBlock(8, 66, 10), Int(cell(B.oak_door, 0)))
        XCTAssertEqual(game.world.getBlock(8, 66, 9), 0)
    }

    // MARK: - toss

    func testDropKeyEmitsTossIntentAndDecrementsLocalSlotOptimistically() {
        let game = makeLANClientGame()
        game.player.selectedSlot = 0
        game.player.inventory[0] = ItemStack(iid("dirt"), 5)
        var captured: [LANTossIntent] = []
        game.lanTossIntentHandler = { captured.append($0) }

        game.keyDown("KeyQ", now: 0)

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.slot, 0)
        XCTAssertEqual(captured.first?.count, 1)
        XCTAssertFalse(captured.first?.all ?? true)
        XCTAssertEqual(game.player.inventory[0]?.count, 4)
    }

    func testDropKeyWithAllModifierTossesEntireStackAndClearsSlot() {
        let game = makeLANClientGame()
        game.player.selectedSlot = 2
        game.player.inventory[2] = ItemStack(iid("dirt"), 5)
        var captured: [LANTossIntent] = []
        game.lanTossIntentHandler = { captured.append($0) }

        game.keyDown("KeyQ", now: 0, ctrlOrCmd: true)

        XCTAssertEqual(captured.first?.count, 5)
        XCTAssertTrue(captured.first?.all ?? false)
        XCTAssertNil(game.player.inventory[2])
    }

    // MARK: - inventory grants

    func testApplyLANGrantIsIdempotentUnderDuplicateGrantID() {
        let game = makeLANClientGame()
        let grant = LANInventoryGrant(
            playerID: "peer", grantID: 1,
            items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("dirt"), count: 3)],
            xp: 5, clearAll: false
        )

        game.applyLANGrant(grant)
        XCTAssertEqual(game.player.countItem(iid("dirt")), 3)
        XCTAssertEqual(game.player.xp, 5)

        // duplicate grantID must be ignored entirely — no double-application
        game.applyLANGrant(grant)
        XCTAssertEqual(game.player.countItem(iid("dirt")), 3)
        XCTAssertEqual(game.player.xp, 5)
    }

    func testApplyLANGrantClearAllWipesInventoryBeforeMerging() {
        let game = makeLANClientGame()
        game.player.inventory[0] = ItemStack(iid("stone"), 10)
        let grant = LANInventoryGrant(
            playerID: "peer", grantID: 1,
            items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("dirt"), count: 2)],
            xp: 0, clearAll: true
        )

        game.applyLANGrant(grant)

        XCTAssertEqual(game.player.countItem(iid("stone")), 0)
        XCTAssertEqual(game.player.countItem(iid("dirt")), 2)
    }

    func testApplyLANGrantMergesAdditively() {
        let game = makeLANClientGame()
        game.player.inventory[0] = ItemStack(iid("dirt"), 10)
        let grant = LANInventoryGrant(
            playerID: "peer", grantID: 1,
            items: [LANInventorySlotSnapshot(slot: 5, itemID: iid("dirt"), count: 4)],
            xp: 0, clearAll: false
        )

        game.applyLANGrant(grant)

        XCTAssertEqual(game.player.countItem(iid("dirt")), 14)
    }

    // MARK: - restore

    func testApplyLANRestoreSetsPositionInventoryAndRevisionBaselines() {
        let game = makeLANClientGame()
        let state = LANPlayerState(
            playerID: "peer", displayName: "Alex",
            x: 100.5, y: 70, z: -12.5, yaw: 1.1, pitch: -0.2,
            health: 15, hunger: 12, selectedHotbarSlot: 3,
            gameMode: GameMode.survival, dimension: Dim.overworld.rawValue
        )
        let inventory = LANPlayerInventorySnapshot(
            playerID: "peer", selectedHotbarSlot: 3,
            slots: [LANInventorySlotSnapshot(slot: 3, itemID: iid("stone"), count: 7)],
            xp: 40, xpLevel: 2, xpProgress: 0.5
        )
        let restore = LANRestoreState(playerState: state, inventory: inventory, revision: 9, grantID: 4)

        game.applyLANRestore(restore)

        XCTAssertEqual(game.player.x, 100.5, accuracy: 0.001)
        XCTAssertEqual(game.player.y, 70, accuracy: 0.001)
        XCTAssertEqual(game.player.z, -12.5, accuracy: 0.001)
        XCTAssertEqual(game.player.health, 15, accuracy: 0.001)
        XCTAssertEqual(game.player.countItem(iid("stone")), 7)
        XCTAssertEqual(game.player.xp, 40)

        // a later grant with a lower (stale) id must be ignored
        let staleGrant = LANInventoryGrant(playerID: "peer", grantID: 4, items: [], xp: 100, clearAll: true)
        game.applyLANGrant(staleGrant)
        XCTAssertEqual(game.player.countItem(iid("stone")), 7)
        XCTAssertEqual(game.player.xp, 40)

        // a fresh, higher grantID is honored
        let freshGrant = LANInventoryGrant(playerID: "peer", grantID: 5, items: [], xp: 0, clearAll: true)
        game.applyLANGrant(freshGrant)
        XCTAssertEqual(game.player.countItem(iid("stone")), 0)
    }

    // MARK: - inventory publish

    func testPublishLANInventoryIfChangedFiresOnceForOneActualChange() {
        let game = makeLANClientGame()
        var publishes: [(LANPlayerInventorySnapshot, Int)] = []
        game.lanInventoryPublishHandler = { snapshot, revision in publishes.append((snapshot, revision)) }

        stepOneTick(game)
        XCTAssertEqual(publishes.count, 1, "first tick always publishes the initial (empty) snapshot")

        stepOneTick(game)
        XCTAssertEqual(publishes.count, 1, "no change since — must not republish")

        game.player.inventory[0] = ItemStack(iid("dirt"), 1)
        stepOneTick(game)
        XCTAssertEqual(publishes.count, 2)
        XCTAssertEqual(publishes.last?.1, 2)

        stepOneTick(game)
        XCTAssertEqual(publishes.count, 2, "steady state again — no republish")
    }

    // MARK: - container edit capture

    func testCaptureLANContainerEditSuppressedBetweenBeginAndEndReplicationApply() {
        let game = makeLANClientGame()
        let be = BlockEntityData(type: "container", x: 1, y: 64, z: 1)
        be.items = [ItemStack(iid("dirt"), 1)]
        var captured: [LANContainerEditIntent] = []
        game.lanContainerEditHandler = { captured.append($0) }

        game.captureLANContainerEdit(be)
        XCTAssertEqual(captured.count, 1)

        game.beginLANReplicationApply()
        game.captureLANContainerEdit(be)
        XCTAssertEqual(captured.count, 1, "must not capture while a replication batch is applying")
        game.endLANReplicationApply()

        game.captureLANContainerEdit(be)
        XCTAssertEqual(captured.count, 2)
    }

    // MARK: - streaming: section-granular in-flight expiry

    func testUnansweredSectionRequestBecomesRequestableAgainAfterExpiry() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lan-request-expiry")
        let summary = LANWorldSummary(
            worldID: "host world", worldName: "Host LAN", seed: 7,
            gameMode: GameMode.survival, difficulty: 1,
            dimension: Dim.overworld.rawValue, playerCount: 2
        )
        // enter with no handler installed yet so the initial entry sweep is a no-op, then pin
        // the player to a known chunk before installing the handler and driving requests
        // entirely through the per-tick streamChunks() path — this avoids depending on
        // enterLANClientWorld's internal (private) spawn-placement logic.
        game.enterLANClientWorld(summary)
        game.player.setPos(8.5, 65, 8.5)

        var centerRequestTicks: [Int] = []
        var tick = 0
        game.lanChunkRequestHandler = { _, cx, cz in
            if cx == 0 && cz == 0 { centerRequestTicks.append(tick) }
            return true
        }

        stepOneTick(game)
        XCTAssertEqual(centerRequestTicks.count, 1, "the first tick issues the initial request for the player's chunk")

        // advance ticks without ever answering the request (no markLANChunkSectionsApplied) —
        // it must not be re-requested before the expiry window elapses
        for _ in 0..<(LAN_CHUNK_REQUEST_EXPIRY_TICKS - 1) {
            tick += 1
            stepOneTick(game)
        }
        XCTAssertEqual(centerRequestTicks.count, 1, "still within the expiry window — no re-request yet")

        // cross the expiry threshold — the section becomes requestable again
        for _ in 0..<5 {
            tick += 1
            stepOneTick(game)
        }
        XCTAssertGreaterThan(centerRequestTicks.count, 1, "expired in-flight request must be retried")
    }

    // MARK: - connection loss

    func testSaveLANClientResumeIsNoOpAfterConnectionLost() {
        let db = try! PersistenceTestSupport.makeDatabase(owner: self, label: "lan-routing-loss")
        let game = GameCore(db: db)
        let summary = LANWorldSummary(
            worldID: "host world", worldName: "Host LAN", seed: 11,
            gameMode: GameMode.survival, difficulty: 1,
            dimension: Dim.overworld.rawValue, playerCount: 2
        )
        game.enterLANClientWorld(summary)
        game.player.setPos(1, 65, 1)
        game.saveAndFlush(synchronous: true)

        game.handleLANConnectionLost(reason: "host disappeared")
        XCTAssertTrue(game.lanConnectionLost)

        // drift the position after the loss and try to save again — the last-good resume
        // snapshot (captured before the loss) must not be overwritten
        game.player.setPos(999, 65, 999)
        game.saveAndFlush(synchronous: true)

        let second = GameCore(db: db)
        second.enterLANClientWorld(summary)
        XCTAssertEqual(second.player.x, 1, accuracy: 0.001)
        XCTAssertEqual(second.player.z, 1, accuracy: 0.001)
    }

    // MARK: - protocol-5 RPG zero fallback

    func testProtocol5RPGSubmissionDeniesBeforeLegacyIntentOrLocalMutation() {
        let game = makeLANClientGame()
        XCTAssertNil(game.player.createRPGCharacter(RPGCreationDraft(
            pathID: "arcanist", branchID: "arcanist_elementalist",
            startingSkillIDs: rpgBranchDefinition("arcanist_elementalist")!.skillIDs
        )))
        let beforeRPG = game.player.rpg
        let beforeInventory = game.player.inventory
        var intents: [LANRPGIntent] = []
        game.lanRPGIntentHandler = { intents.append($0) }

        _ = game.requestRPGLearnSkill("spell_formula")
        _ = game.requestRPGAssignPreparedActionToQuickSlot(kind: .skill,
                                                            id: "spell_formula", slot: 0)
        _ = game.requestRPGUseSelectedAction()

        XCTAssertEqual(game.rpgAuthorityPresentation, .unavailable)
        XCTAssertNil(game.rpgLocalPreferenceScope)
        XCTAssertFalse(game.rpgLocalPreferenceWritable)
        XCTAssertEqual(game.player.rpg, beforeRPG)
        XCTAssertEqual(game.player.inventory, beforeInventory)
        XCTAssertTrue(intents.isEmpty)
    }
}
