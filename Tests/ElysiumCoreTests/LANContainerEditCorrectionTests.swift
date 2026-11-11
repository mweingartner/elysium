import XCTest
@testable import ElysiumCore

/// A guest edits a container on its own side first and then tells the host. These tests cover
/// what the host does with the inventory such an edit carries (`applyContainerEditIntent`) and
/// what it hands back when it refuses the edit (`correctRefusedContainerEdit`): the container
/// and the guest's inventory as the host holds them, so nothing the guest moved is left in two
/// places or in none.
final class LANContainerEditCorrectionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    // MARK: - fixtures

    /// Chunk (0,0), flat dirt at y 63, a chest at 2,64,1 holding `items`.
    private func worldWithChest(_ items: [(String, Int)] = []) -> World {
        let world = World(dim: .overworld, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        for z in 0..<CHUNK_W { for x in 0..<CHUNK_W { chunk.set(x, 63, z, cell(B.dirt, 0)) } }
        chunk.status = .generated
        world.setChunk(chunk)
        world.setBlock(2, 64, 1, Int(cell(B.chest)), SET_SILENT)
        let chest = makeContainerBE(2, 64, 1, 27)
        for (index, item) in items.enumerated() { chest.items![index] = ItemStack(iid(item.0), item.1) }
        world.setBlockEntity(chest)
        return world
    }

    private func hostSession(carrying items: [(String, Int)] = []) -> LANMultiplayerHostSession {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(playerID: "guest", displayName: "Alex", x: 2.5, y: 64, z: 1.5, yaw: 0, pitch: 0,
                                                 health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival))
        session.recordInventorySnapshot(inventory(items), from: "guest")
        return session
    }

    private func inventory(_ items: [(String, Int)]) -> LANPlayerInventorySnapshot {
        LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: items.enumerated().map {
            LANInventorySlotSnapshot(slot: $0.offset, itemID: iid($0.element.0), count: $0.element.1)
        })
    }

    private func chestSnapshot(_ items: [(String, Int)], x: Int = 2, dimension: Int = Dim.overworld.rawValue) -> LANBlockEntitySnapshot {
        LANBlockEntitySnapshot(dimension: dimension, x: x, y: 64, z: 1, type: "container", slotCount: 27, slots: items.enumerated().map {
            LANBlockEntitySlotSnapshot(slot: $0.offset, itemID: iid($0.element.0), count: $0.element.1)
        })
    }

    private func held(_ world: World) throws -> LANBlockEntitySnapshot {
        try XCTUnwrap(makeLANBlockEntitySnapshot(try XCTUnwrap(world.getBlockEntity(2, 64, 1)), dimension: Dim.overworld.rawValue))
    }

    private func copy(_ session: LANMultiplayerHostSession) -> [String: Int] {
        var counts: [String: Int] = [:]
        for slot in session.peerRecord(playerID: "guest")?.inventory?.slots ?? [] { counts[itemDefs[slot.itemID].name, default: 0] += slot.count }
        return counts
    }

    private func counts(_ stacks: [ItemStack?]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for case let stack? in stacks { counts[itemDefs[stack.id].name, default: 0] += stack.count }
        return counts
    }

    private func chestCounts(_ world: World) -> [String: Int] {
        counts(world.getBlockEntity(2, 64, 1)?.items ?? [])
    }

    // MARK: - A refused edit is handed back

    /// Someone else emptied the chest a moment before the guest took the two coal out of its own
    /// view of it. The host refuses the edit (the chest is not what the guest saw). Until 1.5.0
    /// the guest only heard "refused" and kept the coal, which the other player holds too. Now
    /// it is granted the way back (the coal leaves its inventory again) and gets the chest as
    /// the host holds it.
    func testAGuestThatTookFromAChestSomeoneElseEmptiedKeepsNothing() throws {
        let world = worldWithChest([("coal", 2)])
        let session = hostSession()
        let seen = try held(world)
        world.getBlockEntity(2, 64, 1)?.items?[0] = nil                 // the other player took the coal

        var guest: [ItemStack?] = Array(repeating: nil, count: 36)
        guest[0] = ItemStack(iid("coal"), 2)                            // the guest's own move
        let mirror = worldWithChest()                                   // its view of the chest after that move
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([]),
                                          inventory: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0,
                                                                                slots: makeLANInventorySlotSnapshots(guest)),
                                          revision: 1, editSeq: 1, blockEntityRevision: lanBlockEntityRevision([seen]))
        XCTAssertEqual(session.applyContainerEditIntent(edit, from: "guest", to: world), .rejected("stale container revision"))

        let containers = session.correctRefusedContainerEdit(edit, from: "guest", in: world)
        XCTAssertEqual(containers, [try held(world)], "the chest as the host holds it")
        let grants = session.drainGrants(for: "guest")
        XCTAssertEqual(grants.map(\.changes), [[LANInventoryStackChange(
            before: LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 2), after: nil)]],
                       "the way back from what the guest holds to what the host holds, and nothing else")
        XCTAssertFalse(grants[0].clearAll)
        _ = applyLANBlockEntitySnapshots(containers, to: mirror)
        for grant in grants { lanApply(grant, to: &guest) }
        XCTAssertEqual(counts(guest), [:], "the coal the guest took exists once, with the other player")
        XCTAssertEqual(chestCounts(mirror), [:])
        XCTAssertEqual(copy(session), [:])
        // Handing the same edit back again changes nothing: the first grant is still on its way.
        XCTAssertEqual(session.correctRefusedContainerEdit(edit, from: "guest", in: world), containers)
        XCTAssertTrue(session.drainGrants(for: "guest").isEmpty)
    }

    /// The other direction: the guest put three diamonds into a chest and the host refused the
    /// edit. The diamonds were in neither place until the guest's inventory next changed.
    func testAGuestWhoseDepositIsRefusedGetsItsItemsBack() throws {
        let world = worldWithChest([("coal", 1)])
        let session = hostSession(carrying: [("diamond", 3), ("stick", 2)])
        session.setPermissions(LANPeerPermissions(canUseContainers: false), for: "guest")
        var guest = try XCTUnwrap(makeInventory(from: inventory([("stick", 2)])))      // after its own move
        let mirror = worldWithChest([("coal", 1), ("diamond", 3)])
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([("coal", 1), ("diamond", 3)]),
                                          inventory: inventory([("stick", 2)]), revision: 1, editSeq: 1,
                                          blockEntityRevision: lanBlockEntityRevision([try held(world)]))
        guard case .rejected = session.applyContainerEditIntent(edit, from: "guest", to: world) else {
            return XCTFail("a guest without the container permission edits nothing")
        }
        let containers = session.correctRefusedContainerEdit(edit, from: "guest", in: world)
        _ = applyLANBlockEntitySnapshots(containers, to: mirror)
        for grant in session.drainGrants(for: "guest") { lanApply(grant, to: &guest) }
        XCTAssertEqual(counts(guest), ["diamond": 3, "stick": 2])
        XCTAssertEqual(makeLANInventorySlotSnapshots(guest), session.peerRecord(playerID: "guest")?.inventory?.slots,
                       "slot for slot what the host holds")
        XCTAssertEqual(chestCounts(mirror), ["coal": 1])
        XCTAssertEqual(chestCounts(world), ["coal": 1])
    }

    /// The guest goes on playing while the way back is on its way to it: it publishes (it moved
    /// a stack) an inventory that still holds the coal it took. That publish is behind the
    /// grant, which is applied to it; once the guest has applied the grant too, the two agree.
    func testAPublishThatCrossesTheWayBackDoesNotUndoIt() throws {
        let world = worldWithChest([("coal", 2)])
        let session = hostSession(carrying: [("stick", 2)])
        var guest = try XCTUnwrap(makeInventory(from: inventory([("stick", 2), ("coal", 2)])))  // took the coal, on its side
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([]), inventory: inventory([("stick", 2), ("coal", 2)]),
                                          revision: 1, editSeq: 1, blockEntityRevision: 12345)
        XCTAssertEqual(session.applyContainerEditIntent(edit, from: "guest", to: world), .rejected("stale container revision"))
        _ = session.correctRefusedContainerEdit(edit, from: "guest", in: world)
        let grants = session.drainGrants(for: "guest")
        XCTAssertEqual(copy(session), ["stick": 2], "the host's copy is where the grant leads; it is not changed")

        guest.swapAt(0, 7)
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: 2,
            snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: makeLANInventorySlotSnapshots(guest)),
            appliedGrantID: 0), from: "guest"))
        XCTAssertEqual(copy(session), ["stick": 2], "the coal is in the chest, and stays out of the copy")

        for grant in grants { lanApply(grant, to: &guest) }
        XCTAssertEqual(counts(guest), ["stick": 2])
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: 3,
            snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: makeLANInventorySlotSnapshots(guest)),
            appliedGrantID: try XCTUnwrap(grants.last).grantID), from: "guest"))
        XCTAssertEqual(session.peerRecord(playerID: "guest")?.inventory?.slots, makeLANInventorySlotSnapshots(guest))
        XCTAssertEqual(chestCounts(world), ["coal": 2])
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants.count, 0)
    }

    /// The security review's case. An edit is refused, and before the way back arrives the guest
    /// presses the swap-hands key with 64 diamonds in its hand. A host that sent its whole copy
    /// of the inventory would write the diamonds back into the slot while the off-hand keeps
    /// them. The way back undoes the edit and touches nothing else: the diamonds exist once.
    func testAStackSwappedToTheOffHandWhileTheWayBackIsOnItsWayExistsOnce() throws {
        let world = worldWithChest([("coal", 2)])
        let session = hostSession(carrying: [("diamond", 64)])
        var guest = try XCTUnwrap(makeInventory(from: inventory([("diamond", 64), ("coal", 2)])))   // took the coal
        var pockets: [ItemStack?] = [nil, nil, nil, nil, nil]
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([]), inventory: inventory([("diamond", 64), ("coal", 2)]),
                                          revision: 1, editSeq: 1, blockEntityRevision: 999)
        guard case .rejected = session.applyContainerEditIntent(edit, from: "guest", to: world) else { return XCTFail("refused") }
        _ = session.correctRefusedContainerEdit(edit, from: "guest", in: world)
        let grants = session.drainGrants(for: "guest")

        pockets[0] = guest[0]                                           // the swap-hands key
        guest[0] = nil
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: 2,
            snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: makeLANInventorySlotSnapshots(guest)),
            appliedGrantID: 0), from: "guest"))
        for grant in grants { lanApply(grant, to: &guest, pockets: &pockets) }
        XCTAssertEqual(counts(guest), [:], "the coal is gone and no diamonds were written back")
        XCTAssertEqual(pockets[0]?.count, 64)
        XCTAssertEqual(copy(session), [:])
        guest[0] = pockets[0]                                           // and back into the hand
        pockets[0] = nil
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: 3,
            snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: makeLANInventorySlotSnapshots(guest)),
            appliedGrantID: try XCTUnwrap(grants.last).grantID), from: "guest"))
        XCTAssertEqual(copy(session), ["diamond": 64])
    }

    /// What the guest did on its own in the round trip is left alone: a helmet it took off into
    /// its inventory is not wiped by the way back, and bread it ate does not come back.
    func testTheWayBackLeavesAloneWhatTheGuestDidMeanwhile() throws {
        let world = worldWithChest([("coal", 2)])
        let session = hostSession(carrying: [("bread", 3)])
        var guest = try XCTUnwrap(makeInventory(from: inventory([("bread", 3), ("coal", 2)])))
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([]), inventory: inventory([("bread", 3), ("coal", 2)]),
                                          revision: 1, editSeq: 1, blockEntityRevision: 999)
        guard case .rejected = session.applyContainerEditIntent(edit, from: "guest", to: world) else { return XCTFail("refused") }
        _ = session.correctRefusedContainerEdit(edit, from: "guest", in: world)
        guest[0] = ItemStack(iid("bread"), 2)                           // ate one
        guest[9] = ItemStack(iid("iron_helmet"), 1)                     // took its helmet off
        for grant in session.drainGrants(for: "guest") { lanApply(grant, to: &guest) }
        XCTAssertEqual(counts(guest), ["bread": 2, "iron_helmet": 1])
    }

    /// A guest took a host-crafted quality sword out of a chest and the edit was refused. Its
    /// inventory then showed a quality item the host's copy does not hold, so every later
    /// publish was refused as a forged quality and the copy stood still. The way back takes the
    /// sword out again, and the guest's publishes are stored as before.
    func testAQualityItemTakenWithARefusedEditDoesNotFreezeTheCopy() throws {
        let world = worldWithChest()
        world.getBlockEntity(2, 64, 1)?.items?[0] = ItemStack(iid("iron_sword"), 1, data: makeLANStackData(craftingQuality: 4))
        let session = hostSession(carrying: [("stick", 1)])
        let sword = LANInventorySlotSnapshot(slot: 1, itemID: iid("iron_sword"), count: 1, craftingQuality: 4)
        let taken = LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0,
                                               slots: [LANInventorySlotSnapshot(slot: 0, itemID: iid("stick"), count: 1), sword])
        var guest = try XCTUnwrap(makeInventory(from: taken))
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([]), inventory: taken, revision: 1, editSeq: 1, blockEntityRevision: 5)
        guard case .rejected = session.applyContainerEditIntent(edit, from: "guest", to: world) else { return XCTFail("refused") }
        _ = session.correctRefusedContainerEdit(edit, from: "guest", in: world)
        let grants = session.drainGrants(for: "guest")
        for grant in grants { lanApply(grant, to: &guest) }
        XCTAssertEqual(counts(guest), ["stick": 1])
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: 2,
            snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: makeLANInventorySlotSnapshots(guest)),
            appliedGrantID: try XCTUnwrap(grants.last).grantID), from: "guest"), "the copy is not frozen")
        XCTAssertEqual(chestCounts(world), ["iron_sword": 1])
    }

    // MARK: - The way back leads to what the guest last said it holds

    /// The second security review's case. A host-crafted quality pickaxe is mended on the guest
    /// (granted experience mends a tool on the guest only). From then on the host refuses every
    /// publish of that guest as a changed quality item, so its copy stands still. The guest
    /// swaps 64 diamonds into its off-hand, then moves one cobblestone into a chest; the edit is
    /// refused because the totals no longer match the copy. A way back to the copy would hand
    /// the diamonds out again, in the slot, while the off-hand keeps them. The way back leads
    /// to what the guest last said it holds, and undoes the cobblestone alone.
    func testTheWayBackDoesNotHandOutAgainWhatTheGuestPutAwaySinceTheCopyStoodStill() throws {
        let world = worldWithChest()
        let session = hostSession()
        let pickaxe = { (damage: Int) in LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_pickaxe"), count: 1, damage: damage, craftingQuality: 3) }
        func carrying(_ slots: [LANInventorySlotSnapshot]) -> LANPlayerInventorySnapshot {
            LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 1, slots: slots)
        }
        let diamonds = LANInventorySlotSnapshot(slot: 1, itemID: iid("diamond"), count: 64)
        func cobblestone(_ count: Int) -> LANInventorySlotSnapshot { LANInventorySlotSnapshot(slot: 2, itemID: iid("cobblestone"), count: count) }
        session.recordInventorySnapshot(carrying([pickaxe(50), diamonds, cobblestone(64)]), from: "guest")

        // Mended on the guest: this and every later publish is refused, the copy stands still.
        XCTAssertFalse(session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: 1, snapshot: carrying([pickaxe(40), diamonds, cobblestone(64)])), from: "guest"))
        // The swap-hands key: the diamonds are in the off-hand, which no snapshot shows.
        XCTAssertFalse(session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: 2, snapshot: carrying([pickaxe(40), cobblestone(64)])), from: "guest"))
        XCTAssertEqual(copy(session), ["iron_pickaxe": 1, "diamond": 64, "cobblestone": 64], "the copy stood still")

        var guest = try XCTUnwrap(makeInventory(from: carrying([pickaxe(40), cobblestone(63)])))    // one cobblestone into the chest
        var pockets: [ItemStack?] = [ItemStack(iid("diamond"), 64), nil, nil, nil, nil]
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([("cobblestone", 1)]), inventory: carrying([pickaxe(40), cobblestone(63)]),
                                          revision: 3, editSeq: 1, blockEntityRevision: lanBlockEntityRevision([try held(world)]))
        XCTAssertEqual(session.applyContainerEditIntent(edit, from: "guest", to: world), .rejected("container edit is not host-verifiable"))
        _ = session.correctRefusedContainerEdit(edit, from: "guest", in: world)
        let grants = session.drainGrants(for: "guest")
        XCTAssertEqual(grants.map(\.changes), [[LANInventoryStackChange(before: cobblestone(63), after: cobblestone(64))]],
                       "the cobblestone comes back, and nothing the guest put away is handed out again")
        for grant in grants { lanApply(grant, to: &guest, pockets: &pockets) }
        XCTAssertEqual(counts(guest), ["iron_pickaxe": 1, "cobblestone": 64])
        XCTAssertEqual(guest[0]?.damage, 40, "the mending is not undone either")
        XCTAssertEqual(pockets[0]?.count, 64, "64 diamonds, once")
    }

    /// The same when the host dropped the guest's publish while it caught up: the transport
    /// tells the session what it heard, and the way back leads there.
    func testTheWayBackLeadsToAPublishTheHostHeardAndDidNotTake() throws {
        let world = worldWithChest([("coal", 2)])
        let session = hostSession(carrying: [("bread", 3), ("stick", 1)])
        // The guest ate two bread; the host dropped that publish and only heard it.
        session.noteInventoryHeard(LANInventoryUpdate(playerID: "guest", revision: 1, snapshot: inventory([("bread", 1), ("stick", 1)])),
                                   from: "guest")
        XCTAssertEqual(copy(session), ["bread": 3, "stick": 1])
        var guest = try XCTUnwrap(makeInventory(from: inventory([("bread", 1), ("stick", 1), ("coal", 2)])))   // took the coal
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([]), inventory: inventory([("bread", 1), ("stick", 1), ("coal", 2)]),
                                          revision: 2, editSeq: 1, blockEntityRevision: lanBlockEntityRevision([try held(world)]))
        guard case .rejected = session.applyContainerEditIntent(edit, from: "guest", to: world) else { return XCTFail("the totals do not match the copy") }
        _ = session.correctRefusedContainerEdit(edit, from: "guest", in: world)
        for grant in session.drainGrants(for: "guest") { lanApply(grant, to: &guest) }
        XCTAssertEqual(counts(guest), ["bread": 1, "stick": 1], "the coal goes back; the eaten bread does not return")
        XCTAssertEqual(chestCounts(world), ["coal": 2])
    }

    /// A refused edit swapped 64 iron for 10 diamonds in one slot. Before the way back arrives
    /// the guest splits the diamonds over two slots. The way back is "the diamonds go, the iron
    /// comes back", each by itself, so the split changes nothing: no diamond stays with the
    /// guest while the host's chest holds them too, and the iron is not lost.
    func testAWayBackThatSwapsItemsFollowsAStackTheGuestHasSplit() throws {
        let world = worldWithChest([("diamond", 10)])
        let session = hostSession(carrying: [("iron_ingot", 64)])
        var guest = try XCTUnwrap(makeInventory(from: inventory([("diamond", 10)])))
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([("iron_ingot", 64)]), inventory: inventory([("diamond", 10)]),
                                          revision: 1, editSeq: 1, blockEntityRevision: 4242)
        XCTAssertEqual(session.applyContainerEditIntent(edit, from: "guest", to: world), .rejected("stale container revision"))
        _ = session.correctRefusedContainerEdit(edit, from: "guest", in: world)
        let grants = session.drainGrants(for: "guest")
        XCTAssertEqual(grants.first?.changes, [
            LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 0, itemID: iid("diamond"), count: 10), after: nil),
            LANInventoryStackChange(before: nil, after: LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_ingot"), count: 64)),
        ])
        guest[0] = ItemStack(iid("diamond"), 5)                         // split 5 + 5, and published
        guest[6] = ItemStack(iid("diamond"), 5)
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: 2,
            snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: makeLANInventorySlotSnapshots(guest)),
            appliedGrantID: 0), from: "guest"))
        XCTAssertEqual(copy(session), ["iron_ingot": 64])
        for grant in grants { lanApply(grant, to: &guest) }
        XCTAssertEqual(counts(guest), ["iron_ingot": 64])
        XCTAssertEqual(chestCounts(world), ["diamond": 10])
        XCTAssertEqual(session.peerRecord(playerID: "guest")?.inventory?.slots, makeLANInventorySlotSnapshots(guest))
    }

    /// A refusal tells a guest nothing it could not already see: a container out of its reach,
    /// in another dimension or that is no container is left out. An edit whose inventory is not
    /// newer than the stored one, or is malformed, says nothing about what the guest holds now:
    /// it gets no way back, and no container either, because a container put right beside an
    /// inventory left as it is would leave the moved items in both.
    func testWhatIsHandedBackIsOnlyWhatTheGuestCouldEditAndOnlyForAnEditThatSaysWhatItHolds() throws {
        let world = worldWithChest([("diamond", 9)])
        world.setBlock(14, 64, 1, Int(cell(B.chest)), SET_SILENT)
        let far = makeContainerBE(14, 64, 1, 27)
        far.items![0] = ItemStack(iid("emerald"), 5)
        world.setBlockEntity(far)
        let session = hostSession(carrying: [("stick", 1)])
        func refused(_ first: LANBlockEntitySnapshot, _ second: LANBlockEntitySnapshot, revision: Int = 1,
                     carrying: LANPlayerInventorySnapshot? = nil) -> LANContainerEditIntent {
            LANContainerEditIntent(blockEntity: first, additionalBlockEntities: [second],
                                   inventory: carrying ?? inventory([("stick", 1), ("emerald", 5)]), revision: revision, editSeq: 1)
        }
        let edit = refused(chestSnapshot([], x: 14), chestSnapshot([("coal", 1)], x: 2))
        guard case .rejected = session.applyContainerEditIntent(edit, from: "guest", to: world) else { return XCTFail("refused") }
        XCTAssertEqual(session.correctRefusedContainerEdit(edit, from: "guest", in: world), [try held(world)],
                       "the chest in reach, and not the one 12 blocks away")
        XCTAssertEqual(session.drainGrants(for: "guest").map(\.changes), [[LANInventoryStackChange(
            before: LANInventorySlotSnapshot(slot: 1, itemID: iid("emerald"), count: 5), after: nil)]])
        XCTAssertEqual(session.correctRefusedContainerEdit(
            refused(chestSnapshot([], x: 2, dimension: Dim.nether.rawValue), chestSnapshot([], x: 3)), from: "guest", in: world), [],
                       "another dimension, and a block that is no container")
        XCTAssertEqual(session.correctRefusedContainerEdit(refused(chestSnapshot([], x: 2), chestSnapshot([("coal", 1)], x: 2)),
                                                           from: "guest", in: world), [try held(world)], "once")

        // Not newer than the stored inventory, or malformed: nothing at all.
        let other = hostSession(carrying: [("stick", 1)])
        XCTAssertTrue(other.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 4, snapshot: inventory([("stick", 1)])),
                                                 from: "guest"))
        XCTAssertEqual(other.correctRefusedContainerEdit(refused(chestSnapshot([], x: 2), chestSnapshot([], x: 3), revision: 4),
                                                         from: "guest", in: world), [])
        let malformed = LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: [
            LANInventorySlotSnapshot(slot: 50, itemID: iid("diamond"), count: 64)])
        XCTAssertEqual(other.correctRefusedContainerEdit(refused(chestSnapshot([], x: 2), chestSnapshot([], x: 3), revision: 9, carrying: malformed),
                                                         from: "guest", in: world), [])
        XCTAssertTrue(other.drainGrants(for: "guest").isEmpty)
        XCTAssertEqual(other.peers["guest"]?.lastGrantID, 0)

        // A guest in another dimension than the host's world sees none of its containers.
        var elsewhere = try XCTUnwrap(session.peerRecord(playerID: "guest")?.playerState)
        session.setPermissions(LANPeerPermissions(canChangeDimensions: true), for: "guest")
        elsewhere.dimension = Dim.nether.rawValue
        session.updatePlayerState(elsewhere)
        XCTAssertEqual(session.correctRefusedContainerEdit(edit, from: "guest", in: world), [])
        XCTAssertEqual(session.correctRefusedContainerEdit(edit, from: "nobody", in: world), [])
        XCTAssertTrue(session.drainGrants(for: "nobody").isEmpty)
    }

    // MARK: - The inventory an edit carries

    /// A modified guest can have the host refuse edit after edit, each with a way back as large
    /// as an inventory, and never name one as applied. The host keeps such grants and applies
    /// them to every snapshot that is behind them, so what it keeps for a guest is bounded by
    /// the stacks they name and not only by their number: a snapshot never costs the host more
    /// than that bound, however many edits were refused before it.
    func testAFloodOfRefusedEditsDoesNotMakeEverySnapshotExpensive() throws {
        let world = worldWithChest()
        let session = hostSession()
        func sticks(_ label: String) -> LANPlayerInventorySnapshot {
            LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: (0..<36).map {
                LANInventorySlotSnapshot(slot: $0, itemID: iid("stick"), count: 1, label: label)
            })
        }
        var revision = 1
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: revision, snapshot: sticks("x")),
                                                   from: "guest"))
        for _ in 0..<300 {
            revision += 1
            let edit = LANContainerEditIntent(blockEntity: chestSnapshot([]), inventory: sticks("y"), revision: revision,
                                              editSeq: revision, blockEntityRevision: 7,
                                              appliedGrantID: session.peers["guest"]?.lastGrantID ?? 0)
            guard case .rejected = session.applyContainerEditIntent(edit, from: "guest", to: world) else { return XCTFail("refused") }
            _ = session.correctRefusedContainerEdit(edit, from: "guest", in: world)
        }
        let peer = try XCTUnwrap(session.peers["guest"])
        XCTAssertEqual(peer.lastGrantID, 300, "every refusal was answered with a way back")
        let entries = peer.unacknowledgedGrants.reduce(0) { $0 + $1.entryCount }
        XCTAssertLessThanOrEqual(entries, LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANT_ENTRIES)
        XCTAssertGreaterThan(peer.forgottenGrantID, 0, "the oldest ways back are forgotten")
        XCTAssertEqual(peer.unacknowledgedGrants.last?.grantID, 300, "the newest is kept")

        // The dearest snapshot the guest can send now: as far behind as the host still takes one.
        var timings: [Double] = []
        for _ in 0..<5 {
            revision += 1
            let began = DispatchTime.now().uptimeNanoseconds
            _ = session.guestInventory(sticks("y"), revision: revision, appliedGrantID: peer.forgottenGrantID, of: peer)
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
        }
        // A loose guard and not a benchmark (the suite runs beside other work): with 128 grants
        // of 36 changes kept, as before the bound, this took 263 ms in a debug build on a quiet
        // machine, and takes about a twentieth of that now.
        XCTAssertLessThan(timings.sorted()[2], 150, "median ms for one snapshot behind everything the host keeps: \(timings)")

        // A snapshot behind a forgotten way back is not taken, and gets no way back of its own.
        let behind = LANContainerEditIntent(blockEntity: chestSnapshot([]), inventory: sticks("y"), revision: revision + 1,
                                            editSeq: revision + 1, blockEntityRevision: 7, appliedGrantID: 0)
        XCTAssertEqual(session.correctRefusedContainerEdit(behind, from: "guest", in: world), [])
        XCTAssertEqual(session.peers["guest"]?.lastGrantID, 300)
    }

    /// An edit carries the guest's inventory with a revision, as a publish does. An edit that is
    /// not newer than what the host has stored was applied to the container all the same, while
    /// its inventory was left out: a modified client could put a host-crafted quality sword into
    /// a chest and keep it in the host's copy, then take it out again and hold two. It is refused.
    func testAnEditThatIsNotNewerThanTheStoredInventoryIsRefused() throws {
        let world = worldWithChest()
        let session = hostSession()
        let sword = LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_sword"), count: 1, craftingQuality: 4)
        session.recordInventorySnapshot(LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: [sword]), from: "guest")
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: 5, snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: [sword])),
            from: "guest"))
        let deposit = LANBlockEntitySnapshot(dimension: Dim.overworld.rawValue, x: 2, y: 64, z: 1, type: "container", slotCount: 27, slots: [
            LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("iron_sword"), count: 1, craftingQuality: 4)])
        for revision in [5, 4, 0] {
            let edit = LANContainerEditIntent(blockEntity: deposit, inventory: inventory([]), revision: revision, editSeq: 1,
                                              blockEntityRevision: lanBlockEntityRevision([try held(world)]))
            XCTAssertEqual(session.applyContainerEditIntent(edit, from: "guest", to: world), .rejected("stale inventory revision"),
                           "revision \(revision)")
        }
        XCTAssertEqual(chestCounts(world), [:], "the sword is in the copy and not in the chest")
        XCTAssertEqual(copy(session), ["iron_sword": 1])
        let edit = LANContainerEditIntent(blockEntity: deposit, inventory: inventory([]), revision: 6, editSeq: 1,
                                          blockEntityRevision: lanBlockEntityRevision([try held(world)]))
        guard case .applied = session.applyContainerEditIntent(edit, from: "guest", to: world) else { return XCTFail("a newer edit") }
        XCTAssertEqual(chestCounts(world), ["iron_sword": 1])
        XCTAssertEqual(copy(session), [:], "and now in the chest and not in the copy")
        XCTAssertEqual(session.peerRecord(playerID: "guest")?.inventoryRevision, 6)
    }

    /// A pickup is on its way to the guest while it puts its sticks into a chest. The edit's
    /// inventory does not hold the pickup yet. The host adds it before it checks the totals and
    /// before it stores the inventory, so the edit is accepted and the pickup stays in the copy.
    func testAnEditThatCrossesAPickupIsCheckedAndStoredWithThePickup() throws {
        let world = worldWithChest()
        let session = hostSession(carrying: [("stick", 2)])
        let pickup = try XCTUnwrap(session.applyAuthoritativePickupMutation(
            LANAuthoritativePickupMutation(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 4)], xp: 0), for: "guest"))
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([("stick", 2)]), inventory: inventory([]), revision: 1, editSeq: 1,
                                          blockEntityRevision: lanBlockEntityRevision([try held(world)]), appliedGrantID: 0)
        guard case .applied = session.applyContainerEditIntent(edit, from: "guest", to: world) else {
            return XCTFail("an honest edit made before the pickup arrived is refused")
        }
        XCTAssertEqual(copy(session), ["coal": 4])
        XCTAssertEqual(chestCounts(world), ["stick": 2])
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants.map(\.grantID), [pickup.grantID], "not yet named as applied")

        // The same edit from a guest that says it had applied the pickup, though its inventory
        // does not show it: nothing is added for it, and the totals do not match.
        let other = worldWithChest()
        let again = hostSession(carrying: [("stick", 2)])
        _ = again.applyAuthoritativePickupMutation(
            LANAuthoritativePickupMutation(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 4)], xp: 0), for: "guest")
        let claimed = LANContainerEditIntent(blockEntity: chestSnapshot([("stick", 2)]), inventory: inventory([]), revision: 1, editSeq: 1,
                                             blockEntityRevision: lanBlockEntityRevision([try held(other)]), appliedGrantID: 1)
        XCTAssertEqual(again.applyContainerEditIntent(claimed, from: "guest", to: other), .rejected("container edit is not host-verifiable"))
    }

    // MARK: - The guest's client

    /// The shipped client names the last grant it applied in a container edit, read at the
    /// moment it builds the inventory the edit carries.
    @MainActor func testTheClientNamesTheLastGrantItAppliedInAContainerEdit() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lan-edit-applied-grant")
        game.enterLANClientWorld(LANWorldSummary(worldID: "host", worldName: "Host", seed: 42, gameMode: GameMode.survival,
                                                 difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2))
        var edits: [LANContainerEditIntent] = []
        game.lanContainerEditHandler = { edits.append($0) }
        let chest = makeContainerBE(1, 64, 1, 27)
        game.captureLANContainerEdit(chest)
        game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 9,
                                             items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 2)], xp: 0, clearAll: false))
        game.captureLANContainerEdit(chest)
        XCTAssertEqual(edits.map(\.appliedGrantID), [0, 9])
        XCTAssertEqual(edits.last?.inventory.slots, [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 2)])
        XCTAssertGreaterThan(edits[1].revision, edits[0].revision)
    }
}
