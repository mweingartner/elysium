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

    func testToolStrikeIntentEmitsOncePerMiningStartOnlyForARealTool() {
        let game = makeLANClientGame()
        game.player.mainHand = ItemStack(iid("wooden_pickaxe"), 1)
        var captured: [LANBlockIntent] = []
        game.lanBlockIntentHandler = { captured.append($0) }

        game.mouseDown(0)
        stepOneTick(game)
        for _ in 0..<8 { stepOneTick(game) }

        var strikes = captured.filter { $0.action == .toolStrike }
        XCTAssertEqual(strikes.count, 1, "held-button mining must not repeat the start intent")
        XCTAssertEqual(strikes.first?.toolStrikeSequence, 1)
        XCTAssertEqual(strikes.first?.toolStrikeGesture, 1)
        XCTAssertEqual(strikes.first?.cell, game.world.getBlock(8, 66, 10))

        game.mouseUp(0)
        stepOneTick(game)
        game.mouseDown(0)
        stepOneTick(game)
        strikes = captured.filter { $0.action == .toolStrike }
        XCTAssertEqual(strikes.map(\.toolStrikeSequence), [1, 2])
        XCTAssertEqual(strikes.map(\.toolStrikeGesture), [1, 2])

        game.mouseUp(0)
        stepOneTick(game)
        game.player.mainHand = ItemStack(iid("dirt"), 1)
        game.mouseDown(0)
        stepOneTick(game)
        XCTAssertEqual(captured.filter { $0.action == .toolStrike }.count, 2)
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

    func testRightClickChestNextToChestUsesExistingFacingInPlaceIntent() {
        let game = makeLANClientGame()
        guard let chunk = game.world.getChunkAt(7, 9) else {
            return XCTFail("test fixture missing loaded chunk")
        }
        // The target is east of this south-facing chest. With yaw 0 the normal
        // fallback would be north-facing, so this exercises the shared seam.
        chunk.set(7, 66, 9, cell(B.chest, 1))
        game.player.mainHand = ItemStack(iid("chest"), 1)
        var captured: [LANBlockIntent] = []
        game.lanBlockIntentHandler = { captured.append($0) }

        game.mouseDown(2)

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.action, .placeBlock)
        XCTAssertEqual(captured.first?.cell, Int(cell(B.chest, 1)))
        XCTAssertEqual(game.world.getBlock(8, 66, 9), 0,
                       "the LAN client must still leave its mirror untouched")
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

    func testRightClickOrdinaryBowSendsHostTimedDrawReleaseWithoutMirrorProjectile() {
        let game = makeLANClientGame()
        game.player.mainHand = ItemStack(iid("bow"), 1)
        game.player.inventory[1] = ItemStack(iid("arrow"), 1)
        var captured: [LANBowIntent] = []
        game.lanBowIntentHandler = { captured.append($0) }

        game.mouseDown(2)

        XCTAssertEqual(captured, [
            LANBowIntent(action: .begin, selectedHotbarSlot: 0, sequence: 1),
        ])
        XCTAssertTrue(game.player.usingItem, "the guest may retain local bow draw feedback")
        XCTAssertTrue(game.world.entities.compactMap { $0 as? ArrowEntity }.isEmpty,
                      "only the host may create the real shared-world projectile")

        for _ in 0..<6 { stepOneTick(game) }
        XCTAssertEqual(captured.count, 1, "holding the button must not restart host charge")
        XCTAssertTrue(game.world.entities.compactMap { $0 as? ArrowEntity }.isEmpty)

        game.mouseUp(2)
        XCTAssertEqual(captured, [
            LANBowIntent(action: .begin, selectedHotbarSlot: 0, sequence: 1),
            LANBowIntent(action: .release, selectedHotbarSlot: 0, sequence: 2),
        ])
        XCTAssertFalse(game.player.usingItem)
        XCTAssertTrue(game.world.entities.compactMap { $0 as? ArrowEntity }.isEmpty)
    }

    func testRightClickOrdinaryBowCanStartInOpenAirWithoutMirrorProjectile() {
        let game = makeLANClientGame()
        game.player.mainHand = ItemStack(iid("bow"), 1)
        game.player.inventory[1] = ItemStack(iid("arrow"), 1)
        // Look above the wall and ground fixture so a bow use cannot depend on a block raycast.
        game.player.pitch = -1.3
        var captured: [LANBowIntent] = []
        game.lanBowIntentHandler = { captured.append($0) }

        game.mouseDown(2)

        XCTAssertEqual(captured, [
            LANBowIntent(action: .begin, selectedHotbarSlot: 0, sequence: 1),
        ])
        XCTAssertTrue(game.player.usingItem)
        XCTAssertTrue(game.world.entities.compactMap { $0 as? ArrowEntity }.isEmpty)
    }

    func testRightClickInertBlockEmitsOneSemanticInteractionPerUsePulse() {
        let game = makeLANClientGame()
        var interactions: [LANInteractionIntent] = []
        var mutations: [LANBlockIntent] = []
        game.lanInteractionIntentHandler = { interactions.append($0) }
        game.lanBlockIntentHandler = { mutations.append($0) }

        game.mouseDown(2)

        XCTAssertEqual(interactions, [
            LANInteractionIntent(
                target: .block(
                    x: 8, y: 66, z: 10, face: Dir.north,
                    cell: Int(cell(B.stone, 0))
                ),
                selectedHotbarSlot: 0,
                sequence: 1
            ),
        ])
        XCTAssertTrue(mutations.isEmpty, "inert block use is event-only")

        for _ in 0..<4 { stepOneTick(game) }
        XCTAssertEqual(interactions.count, 1)
        stepOneTick(game)
        XCTAssertEqual(interactions.map(\.sequence), [1, 2])
        XCTAssertTrue(mutations.isEmpty)
        game.mouseUp(2)
    }

    func testRightClickForemostInertEntityTargetsItsAuthoritativeHostID() {
        let game = makeLANClientGame()
        let mirror = Entity(world: game.world)
        mirror.lanReplicatedMirror = true
        mirror.lanReplicationSourceID = 888
        mirror.setPos(8.5, 65.3, 9.5)
        game.world.addEntity(mirror)
        var interactions: [LANInteractionIntent] = []
        var mutations: [LANBlockIntent] = []
        game.lanInteractionIntentHandler = { interactions.append($0) }
        game.lanBlockIntentHandler = { mutations.append($0) }

        game.mouseDown(2)

        XCTAssertEqual(interactions, [
            LANInteractionIntent(
                target: .entity(id: 888),
                selectedHotbarSlot: 0,
                sequence: 1
            ),
        ])
        XCTAssertTrue(mutations.isEmpty)
        game.mouseUp(2)
    }

    // MARK: - toss

    /// The drop key only asks. The host throws the item from its copy of this inventory and
    /// its grant takes it out here, so a toss the host does not carry out costs nothing.
    func testDropKeyEmitsTossIntentAndTheHostsGrantTakesTheItem() {
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
        XCTAssertEqual(game.player.inventory[0]?.count, 5, "nothing leaves the inventory until the host says so")

        game.applyLANGrant(LANInventoryGrant(playerID: "peer", grantID: 1, items: [], xp: 0, clearAll: false, changes: [
            LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 0, itemID: iid("dirt"), count: 5),
                                    after: LANInventorySlotSnapshot(slot: 0, itemID: iid("dirt"), count: 4)),
        ]))
        XCTAssertEqual(game.player.inventory[0]?.count, 4)
    }

    func testDropKeyWithAllModifierAsksForTheEntireStack() {
        let game = makeLANClientGame()
        game.player.selectedSlot = 2
        game.player.inventory[2] = ItemStack(iid("dirt"), 5)
        var captured: [LANTossIntent] = []
        game.lanTossIntentHandler = { captured.append($0) }

        game.keyDown("KeyQ", now: 0, ctrlOrCmd: true)

        XCTAssertEqual(captured.first?.count, 5)
        XCTAssertTrue(captured.first?.all ?? false)
        XCTAssertEqual(game.player.inventory[2]?.count, 5)

        game.applyLANGrant(LANInventoryGrant(playerID: "peer", grantID: 1, items: [], xp: 0, clearAll: false, changes: [
            LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 2, itemID: iid("dirt"), count: 5), after: nil),
        ]))
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

    func testApplyLANGrantPreservesCraftingQualityForGivenAndChangedStacks() throws {
        let game = makeLANClientGame()
        let grant = LANInventoryGrant(
            playerID: "peer",
            grantID: 1,
            items: [
                LANInventorySlotSnapshot(
                    slot: 0, itemID: iid("iron_sword"), count: 1, damage: 7, craftingQuality: 4,
                    enchantments: [LANItemEnchantmentSnapshot(id: "sharpness", lvl: 3)],
                    potion: "poison"
                ),
            ],
            xp: 0,
            clearAll: false,
            changes: [
                LANInventoryStackChange(before: nil, after: LANInventorySlotSnapshot(
                    slot: 3, itemID: iid("iron_pickaxe"), count: 1, damage: 11, craftingQuality: 5,
                    enchantments: [LANItemEnchantmentSnapshot(id: "efficiency", lvl: 4)]
                )),
            ]
        )

        game.applyLANGrant(grant)

        XCTAssertEqual(game.player.inventory[0]?.data.craftingQuality, 4)
        XCTAssertEqual(game.player.inventory[3]?.data.craftingQuality, 5)
        XCTAssertEqual(game.player.inventory[0]?.ench, [EnchInstance("sharpness", 3)])
        XCTAssertEqual(game.player.inventory[0]?.data.potion, "poison")
        XCTAssertEqual(game.player.inventory[3]?.ench, [EnchInstance("efficiency", 4)])
        let qualityPickaxe = try XCTUnwrap(game.player.inventory[3])
        XCTAssertGreaterThan(maxDamageOf(qualityPickaxe),
                             itemDef(iid("iron_pickaxe")).tool!.durability)
    }

    func testApplyLANPickupGrantAdvancesCanonicalExperienceState() {
        let game = makeLANClientGame()
        let grant = LANInventoryGrant(
            playerID: "peer", grantID: 1,
            items: [], xp: 10, clearAll: false
        )

        game.applyLANGrant(grant)

        XCTAssertEqual(game.player.xp, 10)
        XCTAssertEqual(game.player.xpLevel, 1)
        XCTAssertEqual(game.player.xpProgress, 1.0 / 3.0, accuracy: 0.000_001)
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

    // MARK: - an open container (LANClientContainers.swift)

    /// A host with a screen: `hasScreen()` is true from the moment the game opens one.
    private final class ContainerScreenHost: GameHost {
        var open = false
        var handBack: (() -> Void)?
        func hasScreen() -> Bool { open }
        func openScreen(_ kind: String, _ data: ScreenData?) { open = true }
        func closeAllScreens() { open = false }
        func returnStacksHeldByScreens() { handBack?() }
        func screenPausesGame() -> Bool { false }
        func openTrading(_ villager: Mob) {}; func openVehicleChest(_ kind: String, _ vehicle: Entity) {}
        func openChat(_ prefix: String) {}; func openDeathScreen(_ message: String) {}
        func openPauseScreen() {}; func openTitleScreen() {}
        func releasePointer() {}; func capturePointer() {}
        func showActionBar(_ text: String, _ time: Int) {}; func pushChat(_ line: String) {}
        func pushToast(_ adv: AdvancementDef) {}; func setBossBars(_ bars: [BossBarInfo]) {}
        func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double, _ pitch: Double) {}
        func playUI(_ name: String) {}; func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
        func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {}
        func tickMusic(_ mood: String, _ enabled: Bool) {}; func stopDisc() {}
        func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double, _ count: Int, _ spread: Double, _ cell: Int) {}
        func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double, _ groundY: Double) {}
        func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {}
        func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {}; func clearAllSections() {}
    }

    /// A guest looking at a chest (in place of the fixture's wall) and right-clicking it.
    /// The items are named and not built: the registry is filled when the game is made.
    private func openMirroredChest(holding items: [(slot: Int, item: String, count: Int)] = []) throws
        -> (game: GameCore, host: ContainerScreenHost, chest: BlockEntityData) {
        let game = makeLANClientGame()
        let host = ContainerScreenHost()
        game.host = host
        game.world.setBlock(8, 66, 10, Int(cell(B.chest)), SET_SILENT)
        game.world.setBlock(8, 67, 10, 0, SET_SILENT)                 // a chest under a solid block does not open
        let chest = makeContainerBE(8, 66, 10, 27)
        for held in items { chest.items?[held.slot] = ItemStack(iid(held.item), held.count) }
        game.world.setBlockEntity(chest)
        game.lanBlockIntentHandler = { _ in }
        game.mouseDown(2)
        game.mouseUp(2)
        XCTAssertTrue(host.open, "the right-click opened the mirrored chest")
        return (game, host, try XCTUnwrap(game.world.getBlockEntity(8, 66, 10)))
    }

    private func hostBatch(_ chest: BlockEntityData, holding items: [(Int, ItemStack)]) throws -> LANReplicationBatch {
        let held = makeContainerBE(chest.x, chest.y, chest.z, 27)
        for (slot, stack) in items { held.items?[slot] = stack }
        return LANReplicationBatch(tick: 1, fullSnapshot: false,
                                   blockEntities: [try XCTUnwrap(makeLANBlockEntitySnapshot(held, dimension: Dim.overworld.rawValue))])
    }

    private func apply(_ batch: LANReplicationBatch, to game: GameCore) {
        game.beginLANReplicationApply()
        _ = game.applyLANHostReplicationBatch(batch)
        game.endLANReplicationApply()
    }

    /// While a container is open, the guest's inventory travels with its container edits only.
    /// The tick's ordinary publish used to go out as well, often ahead of the edit: the host
    /// then heard that items had left the inventory before the edit said where they went, saw
    /// the edit create them, and refused it.
    func testWhileAContainerIsOpenTheInventoryIsNotPublishedOnItsOwn() throws {
        let (game, host, chest) = try openMirroredChest()
        var publishes: [LANPlayerInventorySnapshot] = []
        var edits: [LANContainerEditIntent] = []
        game.lanInventoryPublishHandler = { snapshot, _ in publishes.append(snapshot) }
        game.lanContainerEditHandler = { edits.append($0) }

        game.player.inventory[0] = nil
        chest.items?[3] = ItemStack(iid("dirt"), 5)                  // five dirt into the chest, on the guest's side
        stepOneTick(game)
        stepOneTick(game)
        XCTAssertTrue(publishes.isEmpty, "no publish may overtake the edit")
        game.captureLANContainerEdit(chest)
        XCTAssertEqual(edits.count, 1)
        XCTAssertTrue(edits[0].inventory.slots.isEmpty, "the edit carries the inventory")

        host.open = false
        game.gameScreenWillClose(be: chest)
        XCTAssertEqual(edits.count, 2, "closing sends the last edit")
        game.player.inventory[1] = ItemStack(iid("stick"), 1)
        stepOneTick(game)
        XCTAssertEqual(publishes.count, 1, "and the ordinary publish is back")
        XCTAssertGreaterThan(game.lanLocalInventoryRevision, edits[1].revision)
    }

    /// The guest publishes when it opens a container, so the host checks the first edit against
    /// what the guest holds at that moment (a stack moved to the off-hand a moment earlier).
    func testOpeningAContainerPublishesTheInventoryFirst() throws {
        let game = makeLANClientGame()
        let host = ContainerScreenHost()
        game.host = host
        game.world.setBlock(8, 66, 10, Int(cell(B.chest)), SET_SILENT)
        game.world.setBlock(8, 67, 10, 0, SET_SILENT)
        game.world.setBlockEntity(makeContainerBE(8, 66, 10, 27))
        game.lanBlockIntentHandler = { _ in }
        var publishes: [LANPlayerInventorySnapshot] = []
        game.lanInventoryPublishHandler = { snapshot, _ in publishes.append(snapshot) }
        game.player.inventory[4] = ItemStack(iid("coal"), 3)           // changed in this very tick
        game.mouseDown(2)
        game.mouseUp(2)
        XCTAssertTrue(host.open)
        XCTAssertEqual(publishes.map { $0.slots.map(\.count) }, [[3]], "published before the screen opened")
    }

    /// The host sends every container near a player twice a second. A guest that has taken two
    /// coal out of the chest (they are on its cursor, or already in its inventory) and not told
    /// the host yet keeps its own view: written over it, the snapshot would put the coal back
    /// into the chest while the guest holds it too. The guest's edit then names the chest as
    /// the host last sent it, so the host can tell whether someone else changed it meanwhile.
    func testAHostSnapshotIsNotWrittenOverAChangeTheGuestHasNotSentYet() throws {
        let (game, _, chest) = try openMirroredChest(holding: [(slot: 0, item: "coal", count: 2)])
        var edits: [LANContainerEditIntent] = []
        game.lanContainerEditHandler = { edits.append($0) }
        let asSent = try hostBatch(chest, holding: [(0, ItemStack(iid("coal"), 2))])
        let sentRevision = lanBlockEntityRevision(asSent.blockEntities)
        XCTAssertFalse(game.lanHasUnsentContainerEdit)

        chest.items?[0] = nil                                           // picked up: on the cursor
        XCTAssertTrue(game.lanHasUnsentContainerEdit)
        apply(asSent, to: game)                                         // the host's twice-a-second snapshot
        apply(LANReplicationBatch(tick: 2, fullSnapshot: false), to: game)
        XCTAssertNil(chest.items?[0], "the coal is not put back under the guest's cursor")

        game.player.inventory[0] = ItemStack(iid("coal"), 2)            // put down in the inventory
        game.captureLANContainerEdit(chest)
        XCTAssertEqual(edits.last?.blockEntityRevision, sentRevision, "the edit names the chest as the host last sent it")
        XCTAssertFalse(game.lanHasUnsentContainerEdit, "sent")

        // Once sent, the host's snapshots are applied again: its answer, or another player's change.
        apply(try hostBatch(chest, holding: [(5, ItemStack(iid("glass"), 1))]), to: game)
        XCTAssertEqual(chest.items?[5]?.id, iid("glass"))
        chest.items?[5] = nil
        game.captureLANContainerEdit(chest)
        XCTAssertEqual(edits.last?.blockEntityRevision,
                       lanBlockEntityRevision(try hostBatch(chest, holding: [(5, ItemStack(iid("glass"), 1))]).blockEntities))
    }

    /// A grant that takes something away first has an open screen hand back what it holds, and
    /// closing a container screen sends an edit. That edit is built before the grant is applied
    /// and must not name it: the host would otherwise believe the edit's inventory already
    /// holds the grant, and what the grant gives or takes would count twice.
    func testAnEditSentWhileAScreenHandsBackItsStacksDoesNotNameTheGrantBeingApplied() throws {
        let (game, host, chest) = try openMirroredChest()
        var edits: [LANContainerEditIntent] = []
        game.lanContainerEditHandler = { edits.append($0) }
        game.player.inventory[0] = ItemStack(iid("oak_planks"), 10)
        host.handBack = { [unowned game] in game.gameScreenWillClose(be: chest) }     // as closing the screen does
        game.applyLANGrant(LANInventoryGrant(playerID: "peer", grantID: 7, items: [], xp: 0, clearAll: false,
                                             take: [LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 6)]))
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits[0].appliedGrantID, 0, "the edit was built before grant 7 was applied")
        XCTAssertEqual(edits[0].inventory.slots.first?.count, 10, "and its inventory does not hold it")
        XCTAssertEqual(game.lanLastAppliedGrantID, 7)
        XCTAssertEqual(game.player.countItem(iid("oak_planks")), 4)
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

    func testProtocol5LegacyRPGSubmissionDeniesBeforeIntentOrLocalMutation() {
        let game = makeLANClientGame()
        XCTAssertTrue(game.world.isTransientLANClient)
        XCTAssertTrue(game.world.rule(RPG_CLASSES_GAME_RULE),
                      "the legacy summary field may still be true on a transient mirror")
        XCTAssertEqual(game.player.rpg, .skillTreeProgression(),
                       "the direct constructor must reject even a pristine usage tree")
        XCTAssertEqual(game.player.createRPGCharacter(RPGCreationDraft(
            pathID: "arcanist", branchID: "arcanist_elementalist",
            startingSkillIDs: rpgBranchDefinition("arcanist_elementalist")!.skillIDs
        )), .classesDisabled)
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
