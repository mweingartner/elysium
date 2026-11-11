import XCTest
@testable import ElysiumCore

/// What the independent white-box pass over the LAN host's copy of a guest's inventory found
/// (`LANGuestInventoryCopy.swift`), kept as regression tests.
///
/// The first two had one cause: the host names a stack by its wire form
/// (`LANInventorySlotSnapshot`: id, count, damage, label, quality, canonical enchantments,
/// potion), and the guest looked for it by full in-memory equality (`stacksEqual`: every
/// `StackData` field, enchantments in stored order). A stack whose in-memory form is not its
/// wire form (anvil `priorWork`, `repairUnits`, firework `flight`, trims, enchantments not in
/// sorted order, ...) was never found on the guest, so a change to it was silently skipped.
/// The guest now compares stacks as the host sees them (`lanIsKind`) and keeps what only it
/// knows about a stack when the host changes it (`lanStack(_:became:)`).
final class LANGuestInventoryCopyRegressionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    /// Chunk (0,0), flat dirt at y 63.
    private func loadedWorld() -> World {
        let world = World(dim: .overworld, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        for z in 0..<CHUNK_W { for x in 0..<CHUNK_W { chunk.set(x, 63, z, cell(B.dirt, 0)) } }
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }

    private func hostSession(state: Bool = true) -> LANMultiplayerHostSession {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        if state {
            session.updatePlayerState(LANPlayerState(playerID: "guest", displayName: "Alex", x: 2.5, y: 64, z: 1.5, yaw: 0, pitch: 0,
                                                     health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival))
        }
        return session
    }

    private func snapshot(_ stacks: [ItemStack?], xp: Int = 0) -> LANPlayerInventorySnapshot {
        LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: makeLANInventorySlotSnapshots(stacks), xp: xp)
    }

    @MainActor private func guestGame(_ session: LANMultiplayerHostSession, label: String) -> GameCore {
        let game = PersistenceTestSupport.makeGame(owner: self, label: label)
        game.enterLANClientWorld(LANWorldSummary(worldID: "host", worldName: "Host", seed: 42, gameMode: GameMode.survival,
                                                 difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2))
        game.lanInventoryPublishHandler = { [unowned game] snapshot, revision in
            _ = session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: revision, snapshot: snapshot,
                                                                appliedGrantID: game.lanLastAppliedGrantID), from: "guest")
        }
        return game
    }

    // MARK: - An item the wire does not fully describe, thrown

    /// A guest presses Q on a stack whose in-memory form differs from its wire form. The host
    /// throws one from its copy and spawns it in the world; its grant says "take one of <wire
    /// form>". Compared field by field the guest found no such stack, kept every item, and
    /// published them back into the host's copy: one item more for every toss. The items in
    /// the guest's inventory plus those on the ground must equal what the guest held.
    @MainActor func testAThrownStackTheWireDoesNotFullyDescribeExistsOnce() throws {
        var variants: [(String, ItemStack)] = []
        var anvil = StackData()
        anvil.priorWork = 1
        variants.append(("an anvil-renamed sword (priorWork)", ItemStack(iid("iron_sword"), 1, label: "Edge", data: anvil)))
        variants.append(("a sword whose enchantments are not in sorted order",
                         ItemStack(iid("iron_sword"), 1, ench: [EnchInstance("sharpness", 2), EnchInstance("looting", 1)])))
        var flight = StackData()
        flight.flight = 2
        variants.append(("firework rockets with a flight duration", ItemStack(iid("firework_rocket"), 3, data: flight)))

        for (name, stack) in variants {
            let world = loadedWorld()
            let session = hostSession()
            let game = guestGame(session, label: "lan-defect-toss-\(variants.firstIndex { $0.0 == name }!)")
            game.player.selectedSlot = 0
            game.player.inventory[0] = stack.copy()
            game.publishLANInventoryNow()
            var asked: [LANTossIntent] = []
            game.lanTossIntentHandler = { asked.append($0) }
            game.keyDown("KeyQ", now: 0)

            let outcome = LANHostGhostRegistry().applyToss(for: "guest", intent: try XCTUnwrap(asked.first, name), world: world, session: session)
            XCTAssertTrue(outcome.tossed, name)
            let grant = try XCTUnwrap(session.recordGhostInventory(outcome.inventory, for: "guest"), name)
            game.applyLANGrant(grant)
            game.publishLANInventoryNow()

            let onTheGround = world.entities.compactMap { $0 as? ItemEntity }.filter { $0.stack.id == stack.id }.reduce(0) { $0 + $1.stack.count }
            XCTAssertEqual(onTheGround, 1, name)
            XCTAssertEqual(game.player.countItem(stack.id) + onTheGround, stack.count,
                           "\(name): the thrown item exists twice, on the ground and still in the guest's inventory")
            XCTAssertEqual(session.peers["guest"]?.inventory?.slots.reduce(0) { $0 + $1.count }, stack.count - 1,
                           "\(name): the guest's publish put the thrown item back into the host's copy")
        }
    }

    // MARK: - A tool the wire does not fully describe, worn

    /// A guest mines with an anvil-worked pickaxe (any tool that has been through an anvil
    /// carries `priorWork`). The host's ghost breaks the block and wears its copy of the
    /// pickaxe; the grant says "replace <pickaxe, damage 5> with <damage 6>". Compared field by
    /// field the guest's pickaxe was not that stack, so it never wore, and the guest's next
    /// publish put the unworn pickaxe back into the host's copy. It wears on both sides, and it
    /// keeps the anvil's work, which the slot write of 1.5.0 lost.
    @MainActor func testAnAnvilWorkedToolWearsOnTheGuestAndKeepsItsWork() throws {
        let world = loadedWorld()
        world.setBlock(2, 64, 3, Int(cell(B.stone)), SET_SILENT)
        let session = hostSession()
        let game = guestGame(session, label: "lan-defect-wear")
        var anvil = StackData()
        anvil.priorWork = 1
        game.player.selectedSlot = 0
        game.player.inventory[0] = ItemStack(iid("iron_pickaxe"), 1, damage: 5, data: anvil)
        game.publishLANInventoryNow()

        let outcome = LANHostGhostRegistry().applyBreak(for: "guest", x: 2, y: 64, z: 3, world: world, session: session)
        XCTAssertTrue(outcome.broke)
        let grant = try XCTUnwrap(session.recordGhostInventory(outcome.inventory, for: "guest"), "the host's copy wore")
        XCTAssertEqual(session.peers["guest"]?.inventory?.slots.first?.damage, 6)
        game.applyLANGrant(grant)
        game.publishLANInventoryNow()

        XCTAssertEqual(game.player.inventory[0]?.damage, 6, "the guest's pickaxe wore")
        XCTAssertEqual(game.player.inventory[0]?.data.priorWork, 1, "and is still the tool the anvil worked on")
        XCTAssertEqual(session.peers["guest"]?.inventory?.slots.first?.damage, 6, "and the host's copy kept the wear")
    }

    // MARK: - Experience and Mending

    /// ACCEPTED, NOT FIXED (older than this change): the guest spends granted experience on
    /// Mending (`Player.addXP` repairs a held mending tool first); the host's copy does not
    /// model that. After the same grant the two differ in experience and in the tool's damage
    /// until the guest's next publish, which it sends on its next tick. In that window a
    /// change the host works out for the tool names a damage the guest no longer has and is
    /// skipped on the guest. Expected to fail until the host models Mending or the guest's
    /// client applies granted experience the way the host counts it.
    @MainActor func testMendingSpendsGrantedExperienceOnlyOnTheGuest() throws {
        let session = hostSession()
        let game = guestGame(session, label: "lan-defect-mending")
        game.player.selectedSlot = 0
        game.player.inventory[0] = ItemStack(iid("iron_pickaxe"), 1, damage: 10, ench: [EnchInstance("mending", 1)])
        game.publishLANInventoryNow()
        let grant = try XCTUnwrap(session.applyAuthoritativePickupMutation(LANAuthoritativePickupMutation(items: [], xp: 7), for: "guest"))
        game.applyLANGrant(grant)
        let host = try XCTUnwrap(session.peers["guest"]?.inventory)
        XCTExpectFailure("granted experience mends a tool on the guest only, until its next publish") {
            XCTAssertEqual(game.player.xp, host.xp, "experience after the same grant")
            XCTAssertEqual(makeLANInventorySlotSnapshots(game.player.inventory), host.slots, "the mending tool after the same grant")
        }
        game.publishLANInventoryNow()
        XCTAssertEqual(makeLANInventorySlotSnapshots(game.player.inventory), session.peers["guest"]?.inventory?.slots,
                       "the guest's next publish puts the copy right")
        XCTAssertEqual(session.peers["guest"]?.inventory?.xp, game.player.xp)
    }

    /// A guest that is more than the cap behind publishes a snapshot built before any of the
    /// grants. The host no longer keeps them all, so it could only store that snapshot short of
    /// what the guest will hold once the wire has arrived; had the forgotten grant been a
    /// payment, the copy would hold the paid materials again, for a death to drop. The host
    /// does not take such a snapshot: its copy stays what the guest will hold.
    func testASnapshotMoreThanTheCapBehindIsNotStoredShortOfWhatTheGuestWillHold() throws {
        let session = hostSession()
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 1, snapshot: snapshot([])), from: "guest"))
        _ = session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 3)], xp: 0, clearAll: false, to: "guest")
        for _ in 0..<LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS {
            _ = session.enqueueGrant(items: [], xp: 1, clearAll: false, to: "guest")
        }
        let sent = session.drainGrants(for: "guest")
        let arrived = try XCTUnwrap(lanInventory(snapshot([]), applying: sent))
        XCTAssertFalse(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 2, snapshot: snapshot([]),
                                                                       appliedGrantID: 0), from: "guest"),
                       "a snapshot behind a grant the host no longer keeps is not taken")
        XCTAssertEqual(session.peers["guest"]?.inventory?.slots, arrived.inventory.slots, "items once the wire has arrived")
        XCTAssertEqual(session.peers["guest"]?.inventory?.xp, arrived.inventory.xp, "experience once the wire has arrived")
    }
}
