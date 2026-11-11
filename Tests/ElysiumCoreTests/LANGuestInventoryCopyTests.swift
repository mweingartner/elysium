import XCTest
@testable import ElysiumCore

/// The LAN host's copy of what a guest carries (`LANGuestInventoryCopy.swift`): every grant is
/// applied to the copy with the guest's own function, a snapshot that crosses a grant has that
/// grant applied before it is stored, and a grant follows stacks instead of writing slots.
/// The payment of a paste has its own suite, `LANTemplatePaymentTests`.
final class LANGuestInventoryCopyTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    // MARK: - fixtures

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

    /// Chunk (0,0), flat dirt at y 63.
    private func loadedWorld() -> World {
        let world = World(dim: .overworld, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        for z in 0..<CHUNK_W { for x in 0..<CHUNK_W { chunk.set(x, 63, z, cell(B.dirt, 0)) } }
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }

    private func playerState(x: Double = 2.5, dead: Bool = false) -> LANPlayerState {
        LANPlayerState(playerID: "guest", displayName: "Alex", x: x, y: 64, z: 1.5, yaw: 0, pitch: 0,
                       health: dead ? 0 : 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival, dead: dead)
    }

    private func hostSession() -> LANMultiplayerHostSession {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        session.updatePlayerState(playerState())
        return session
    }

    private func snapshot(_ stacks: [ItemStack?], selected: Int = 0) -> LANPlayerInventorySnapshot {
        LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: selected, slots: makeLANInventorySlotSnapshots(stacks))
    }

    private func empty() -> [ItemStack?] { Array(repeating: nil, count: 36) }

    private func stack(_ name: String, _ count: Int = 1, damage: Int = 0, quality: Int? = nil) -> ItemStack {
        ItemStack(iid(name), count, damage: damage, data: makeLANStackData(craftingQuality: quality))
    }

    private func copy(_ session: LANMultiplayerHostSession) -> LANPlayerInventorySnapshot {
        session.peerRecord(playerID: "guest")?.inventory ?? snapshot(empty())
    }

    private func count(_ name: String, in stacks: [ItemStack?]) -> Int {
        stacks.compactMap { $0 }.filter { $0.id == iid(name) }.reduce(0) { $0 + $1.count }
    }

    private func count(_ name: String, in inventory: LANPlayerInventorySnapshot) -> Int {
        inventory.slots.filter { $0.itemID == iid(name) }.reduce(0) { $0 + $1.count }
    }

    /// The guest publishes `stacks`, saying which grant it had applied when it looked.
    @discardableResult
    private func publish(_ session: LANMultiplayerHostSession, _ stacks: [ItemStack?], revision: Int, applied: Int) -> Bool {
        session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: revision, snapshot: snapshot(stacks),
                                                        appliedGrantID: applied), from: "guest")
    }

    private func place(_ block: String, at x: Int, in world: World, for session: LANMultiplayerHostSession) -> LANInventoryGrant? {
        let outcome = LANHostGhostRegistry().applyPlace(
            for: "guest",
            intent: LANBlockIntent(action: .placeBlock, x: x, y: 63, z: 3, face: Dir.up, selectedHotbarSlot: 0, cell: Int(cell(bid(block)))),
            world: world, session: session)
        XCTAssertTrue(outcome.placed)
        return session.recordGhostInventory(outcome.inventory, for: "guest")
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

    // MARK: - A hand placement that crosses a rearrangement

    /// The guest holds ten planks and places one. Before the host's grant for that arrives, it
    /// drags the stack to another slot and publishes. Until 1.5.0 the grant wrote slot 0 from
    /// the host's copy ("nine planks"), so the guest held the nine in slot 0 and its ten in slot
    /// 5, with one more standing. The grant now takes one plank from wherever the stack sits.
    @MainActor func testAHandPlacementGrantThatCrossesARearrangementCreatesNothing() throws {
        let world = loadedWorld()
        let session = hostSession()
        let game = guestGame(session, label: "lan-copy-place")
        game.player.inventory[0] = stack("oak_planks", 10)
        game.publishLANInventoryNow()

        let grant = try XCTUnwrap(place("oak_planks", at: 2, in: world, for: session))
        XCTAssertEqual(grant.changes, [LANInventoryStackChange(
            before: LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 10),
            after: LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 9))])

        game.player.inventory.swapAt(0, 5)                      // dragged before the grant arrived
        game.publishLANInventoryNow()
        XCTAssertEqual(count("oak_planks", in: copy(session)), 9, "the crossed publish is stored with the placement in it")
        game.applyLANGrant(grant)
        game.publishLANInventoryNow()

        XCTAssertEqual(world.getBlockId(2, 64, 3), Int(B.oak_planks))
        XCTAssertEqual(game.player.countItem(iid("oak_planks")), 9)
        XCTAssertEqual(game.player.inventory[5]?.count, 9, "taken from the stack where it sits now")
        XCTAssertNil(game.player.inventory[0])
        XCTAssertEqual(copy(session).slots, makeLANInventorySlotSnapshots(game.player.inventory))
    }

    /// Three blocks placed before the first grant comes back: each grant takes one more.
    func testPlacementsFasterThanTheirGrantsEachTakeOne() throws {
        let world = loadedWorld()
        let session = hostSession()
        var guest = empty()
        guest[0] = stack("oak_planks", 10)
        publish(session, guest, revision: 1, applied: 0)
        let grants = try (2...4).map { try XCTUnwrap(place("oak_planks", at: $0, in: world, for: session)) }
        XCTAssertEqual(count("oak_planks", in: copy(session)), 7)
        for grant in grants { lanApply(grant, to: &guest) }
        XCTAssertEqual(guest[0]?.count, 7)
        XCTAssertTrue(publish(session, guest, revision: 2, applied: grants[2].grantID))
        XCTAssertEqual(copy(session).slots, makeLANInventorySlotSnapshots(guest))
    }

    // MARK: - A change follows the stack

    func testAWornToolIsReplacedWhereTheGuestHoldsItNow() {
        let worn = LANInventoryStackChange(
            before: LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_pickaxe"), count: 1, damage: 5),
            after: LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_pickaxe"), count: 1, damage: 6))
        var moved = empty()
        moved[7] = stack("iron_pickaxe", damage: 5)
        moved[0] = stack("dirt", 3)
        lanApply(worn, to: &moved)
        XCTAssertEqual(moved[7]?.damage, 6, "the tool wore in the slot the guest moved it to")
        XCTAssertEqual(moved[0]?.id, iid("dirt"), "and the slot the host named is not written")

        var gone = empty()
        gone[0] = stack("dirt", 3)
        lanApply(worn, to: &gone)
        XCTAssertEqual(makeLANInventorySlotSnapshots(gone), [LANInventorySlotSnapshot(slot: 0, itemID: iid("dirt"), count: 3)],
                       "a guest that no longer holds the tool is given no tool")

        var twin = empty()
        twin[0] = stack("iron_pickaxe", damage: 5)
        twin[1] = stack("iron_pickaxe", damage: 5)
        lanApply(worn, to: &twin)
        XCTAssertEqual([twin[0]?.damage, twin[1]?.damage], [6, 5], "the slot the host named is looked at first")
    }

    func testARemovalTakesOnlyWhatIsThereAndABrokenToolIsOnlyRemoved() {
        var guest = empty()
        guest[4] = stack("arrow", 2)
        lanApply(LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 0, itemID: iid("arrow"), count: 5),
                                         after: LANInventorySlotSnapshot(slot: 0, itemID: iid("arrow"), count: 1)), to: &guest)
        XCTAssertNil(guest[4], "four were asked for and two were there")
        XCTAssertTrue(guest.allSatisfy { $0 == nil })

        guest[3] = stack("iron_pickaxe", damage: 249)
        lanApply(LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_pickaxe"), count: 1, damage: 249),
                                         after: nil), to: &guest)
        XCTAssertTrue(guest.allSatisfy { $0 == nil }, "the tool broke")
    }

    func testAnAdditionGoesToTheNamedSlotOrWhereAPlayerIsGivenIt() {
        let added = LANInventoryStackChange(before: nil, after: LANInventorySlotSnapshot(slot: 2, itemID: iid("glass_bottle"), count: 1))
        var free = empty()
        lanApply(added, to: &free)
        XCTAssertEqual(free[2]?.id, iid("glass_bottle"))
        var taken = empty()
        taken[2] = stack("dirt", 1)
        lanApply(added, to: &taken)
        XCTAssertEqual(taken[2]?.id, iid("dirt"), "an occupied slot is never overwritten")
        XCTAssertEqual(taken[0]?.id, iid("glass_bottle"))
    }

    func testAChangeThatNamesNoKnownItemDoesNothing() {
        var guest = empty()
        guest[0] = stack("dirt", 3)
        lanApply(LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 0, itemID: 1_000_000, count: 1),
                                         after: LANInventorySlotSnapshot(slot: 0, itemID: iid("diamond"), count: 64)), to: &guest)
        lanApply(LANInventoryStackChange(before: nil, after: nil), to: &guest)
        XCTAssertEqual(makeLANInventorySlotSnapshots(guest), [LANInventorySlotSnapshot(slot: 0, itemID: iid("dirt"), count: 3)])
    }

    // MARK: - Property: the changes between two inventories lead from one to the other

    private func seededInventory(_ random: inout SplitMix64) -> [ItemStack?] {
        let kinds = ["oak_planks", "glass", "dirt", "arrow", "ender_pearl"].map { iid($0) }
        let tools = ["iron_pickaxe", "bow", "iron_sword"].map { iid($0) }
        return (0..<36).map { _ in
            switch random.int(5) {
            case 0, 1: return nil
            case 2: return ItemStack(tools[random.int(tools.count)], 1, damage: random.int(4),
                                     data: makeLANStackData(craftingQuality: random.int(3) == 0 ? 1 + random.int(4) : nil))
            default:
                let id = kinds[random.int(kinds.count)]
                return ItemStack(id, 1 + random.int(itemDefs[id].maxStack), label: random.int(8) == 0 ? "Named" : nil)
            }
        }
    }

    /// What a ghost can do to an inventory: use up part of a stack or all of it, wear or break a
    /// tool, add to a stack, leave a new stack in an empty slot.
    private func ghostEdit(_ stacks: [ItemStack?], _ random: inout SplitMix64) -> [ItemStack?] {
        var after = stacks.map(copyStack)
        for _ in 0..<(1 + random.int(5)) {
            let slot = random.int(36)
            guard let held = after[slot] else {
                if random.int(2) == 0 { after[slot] = ItemStack(iid("glass_bottle"), 1 + random.int(3)) }
                continue
            }
            switch random.int(4) {
            case 0: after[slot] = nil
            case 1 where held.count > 1: held.count -= 1 + random.int(held.count - 1)
            case 2 where itemDefs[held.id].maxStack == 1: held.damage += 1
            case 3 where held.count < itemDefs[held.id].maxStack: held.count += 1
            default: break
            }
        }
        return after
    }

    /// On the inventory the host diffed, the changes give exactly the inventory the ghost left:
    /// the host's copy after a ghost acted is what the grant makes of it.
    func testTheChangesBetweenTwoInventoriesLeadFromOneToTheOther() throws {
        var random = SplitMix64(state: 0x57AC_C0DE)
        for round in 0..<400 {
            let before = seededInventory(&random)
            let after = ghostEdit(before, &random)
            let changes = lanStackChanges(from: snapshot(before), to: snapshot(after))
            var applied = before.map(copyStack)
            for change in changes { lanApply(change, to: &applied) }
            XCTAssertEqual(makeLANInventorySlotSnapshots(applied), makeLANInventorySlotSnapshots(after), "seed 0x57ACC0DE round \(round)")
            XCTAssertTrue(lanStackChanges(from: snapshot(after), to: snapshot(after)).isEmpty)
        }
    }

    private func totals(_ stacks: [ItemStack?]) -> [String: Int] {
        var totals: [String: Int] = [:]
        for case let stack? in stacks {
            totals["\(stack.id)/\(stack.damage)/\(stack.label ?? "")/\(stack.data.craftingQuality ?? 0)", default: 0] += stack.count
        }
        return totals
    }

    /// The guest has rearranged, split and spent stacks since the host last heard from it. A
    /// grant the host built from its own copy never leaves that guest with more of anything
    /// than the host's copy gained by the same grant, kind by kind: nothing is made from a
    /// slot the host only believed was there.
    func testAGrantBuiltFromTheHostsCopyNeverGivesARearrangedGuestMoreThanTheCopyGained() throws {
        var random = SplitMix64(state: 0xD1FF_E4ED)
        for round in 0..<400 {
            let before = seededInventory(&random)
            let after = ghostEdit(before, &random)
            let grant = LANInventoryGrant(playerID: "guest", grantID: 1, items: [], xp: 0, clearAll: false,
                                          changes: lanStackChanges(from: snapshot(before), to: snapshot(after)))
            var guest = before.map(copyStack)
            for index in stride(from: 35, to: 0, by: -1) { guest.swapAt(index, random.int(index + 1)) }     // rearranged
            for _ in 0..<random.int(4) { guest[random.int(36)] = nil }                                      // spent
            let held = totals(guest)
            lanApply(grant, to: &guest)
            let gained = totals(after).merging(totals(before).mapValues { -$0 }, uniquingKeysWith: +)
            for (kind, now) in totals(guest) {
                XCTAssertLessThanOrEqual(now - (held[kind] ?? 0), max(0, gained[kind] ?? 0), "seed 0xD1FFE4ED round \(round) kind \(kind)")
            }
        }
    }

    // MARK: - A grant that crosses a publish stays in the copy

    /// A pickup is on its way to the guest when the guest publishes for another reason. The
    /// publish does not hold the pickup yet; stored as it came, it dropped the pickup out of
    /// the host's copy until the guest's inventory next changed.
    func testAPickupThatCrossesAPublishStaysInTheHostsCopy() throws {
        let session = hostSession()
        var guest = empty()
        guest[0] = stack("bread", 3)
        publish(session, guest, revision: 1, applied: 0)
        let pickup = try XCTUnwrap(session.applyAuthoritativePickupMutation(
            LANAuthoritativePickupMutation(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 4)], xp: 7),
            for: "guest"))
        XCTAssertEqual(count("coal", in: copy(session)), 4)

        guest[0] = stack("bread", 2)                            // the guest ate, and published that
        XCTAssertTrue(publish(session, guest, revision: 2, applied: 0))
        XCTAssertEqual(count("coal", in: copy(session)), 4, "the pickup is applied to the publish that crossed it")
        XCTAssertEqual(count("bread", in: copy(session)), 2)
        XCTAssertEqual(copy(session).xp, 7, "and so is its experience")

        lanApply(pickup, to: &guest)
        XCTAssertTrue(publish(session, guest, revision: 3, applied: pickup.grantID))
        XCTAssertEqual(copy(session).slots, makeLANInventorySlotSnapshots(guest), "once the guest says it applied it, not twice")
    }

    /// The case a publish after every grant alone would get wrong: a host-crafted quality item
    /// is granted, a publish crosses it, and the guest's next publish holds the item. The copy
    /// never lost it, so the publish that "brings it back" is not refused as a forged quality.
    func testAQualityItemThatCrossesAPublishIsNotRefusedWhenTheGuestPublishesIt() throws {
        let session = hostSession()
        var guest = empty()
        publish(session, guest, revision: 1, applied: 0)
        let sword = LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_sword"), count: 1, craftingQuality: 4)
        let pickup = try XCTUnwrap(session.applyAuthoritativePickupMutation(
            LANAuthoritativePickupMutation(items: [sword], xp: 0), for: "guest"))
        guest[3] = stack("dirt", 1)
        XCTAssertTrue(publish(session, guest, revision: 2, applied: 0))
        lanApply(pickup, to: &guest)
        XCTAssertTrue(publish(session, guest, revision: 3, applied: pickup.grantID), "the guest's own publish of a granted item")
        XCTAssertEqual(copy(session).slots, makeLANInventorySlotSnapshots(guest))
        // A quality item the host never granted is still refused.
        guest[9] = stack("iron_sword", quality: 5)
        XCTAssertFalse(publish(session, guest, revision: 4, applied: pickup.grantID))
    }

    /// A quality tool wears on the host while the guest publishes. The publish still shows the
    /// tool before the wear, which the host's copy no longer holds: it is stored worn, not refused.
    func testAPublishThatCrossesTheWearOfAQualityToolIsStoredWorn() throws {
        let session = hostSession()
        var guest = empty()
        guest[0] = stack("iron_pickaxe", damage: 5, quality: 3)
        session.recordInventorySnapshot(snapshot(guest), from: "guest")     // host-verified: the copy holds the quality
        var worn = guest.map(copyStack)
        worn[0] = stack("iron_pickaxe", damage: 6, quality: 3)
        let grant = try XCTUnwrap(session.recordGhostInventory(snapshot(worn), for: "guest"))

        guest.swapAt(0, 8)
        XCTAssertTrue(publish(session, guest, revision: 1, applied: 0), "a publish behind the wear is not a forged quality")
        XCTAssertEqual(copy(session).slots, [LANInventorySlotSnapshot(slot: 8, itemID: iid("iron_pickaxe"), count: 1, damage: 6, craftingQuality: 3)])
        lanApply(grant, to: &guest)
        XCTAssertTrue(publish(session, guest, revision: 2, applied: grant.grantID))
        XCTAssertEqual(copy(session).slots, makeLANInventorySlotSnapshots(guest))
    }

    // MARK: - The grants the host keeps

    func testAGrantIsKeptUntilTheGuestNamesItAndAnEmptyOneIsNotKept() throws {
        let session = hostSession()
        let first = try XCTUnwrap(session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)],
                                                       xp: 0, clearAll: false, to: "guest"))
        let ask = try XCTUnwrap(session.enqueueGrant(items: [], xp: 0, clearAll: false, to: "guest"))
        let second = try XCTUnwrap(session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("stick"), count: 2)],
                                                        xp: 0, clearAll: false, to: "guest"))
        XCTAssertEqual([first.grantID, ask.grantID, second.grantID], [1, 2, 3])
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants.map(\.grantID), [1, 3], "a grant that changes nothing is not kept")
        XCTAssertEqual(session.drainGrants(for: "guest").map(\.grantID), [1, 2, 3], "but it is sent: it asks the guest to publish")

        var guest = empty()
        lanApply(first, to: &guest)
        publish(session, guest, revision: 1, applied: first.grantID)
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants.map(\.grantID), [3])
        XCTAssertEqual(count("stick", in: copy(session)), 2)
        XCTAssertEqual(count("coal", in: copy(session)), 1)
    }

    /// A guest that never names a grant as applied (a stalled or a modified client) cannot make
    /// the host keep grants without end: past the limit the host forgets the oldest. A snapshot
    /// that is behind a forgotten grant could only be stored short of what the guest will hold
    /// (and if the forgotten grant was a payment, with the paid materials back in it), so the
    /// host does not take it and its copy stays right. The guest's next snapshot, built after it
    /// applied the grants, is taken. Nothing is ever written over what the guest holds.
    func testTheHostForgetsTheOldestGrantOfAGuestThatDoesNotAcknowledge() throws {
        let session = hostSession()
        var guest = empty()
        var grants: [LANInventoryGrant] = []
        for _ in 0..<(LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS + 3) {
            grants.append(try XCTUnwrap(session.enqueueGrant(
                items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)], xp: 0, clearAll: false, to: "guest")))
        }
        let kept = try XCTUnwrap(session.peers["guest"]?.unacknowledgedGrants)
        XCTAssertEqual(kept.count, LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS)
        XCTAssertEqual(kept.first?.grantID, 4, "the three oldest are forgotten")
        XCTAssertEqual(kept.last?.grantID, grants.last?.grantID)
        XCTAssertEqual(session.drainGrants(for: "guest").count, grants.count, "every grant is still sent")
        XCTAssertEqual(count("coal", in: copy(session)), grants.count)

        // The stalled guest wakes, publishes before it has applied anything, then applies all.
        XCTAssertEqual(session.peers["guest"]?.forgottenGrantID, 3)
        XCTAssertFalse(publish(session, guest, revision: 1, applied: 0), "behind a grant the host no longer keeps")
        XCTAssertFalse(publish(session, guest, revision: 2, applied: 2))
        XCTAssertEqual(count("coal", in: copy(session)), grants.count, "the copy is still what the guest will hold")
        for grant in grants.prefix(3) { lanApply(grant, to: &guest) }
        XCTAssertTrue(publish(session, guest, revision: 3, applied: 3), "not behind a forgotten grant any more")
        XCTAssertEqual(count("coal", in: copy(session)), grants.count)
        for grant in grants.dropFirst(3) { lanApply(grant, to: &guest) }
        XCTAssertTrue(publish(session, guest, revision: 4, applied: try XCTUnwrap(grants.last).grantID))
        XCTAssertEqual(copy(session).slots, makeLANInventorySlotSnapshots(guest), "and right again")
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants.count, 0)
    }

    func testADeathClearsTheGrantsBeforeItAndAPublishBehindItIsStoredEmpty() throws {
        let session = hostSession()
        var guest = empty()
        guest[0] = stack("oak_planks", 10)
        publish(session, guest, revision: 1, applied: 0)
        _ = session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)], xp: 0, clearAll: false, to: "guest")
        session.updatePlayerState(playerState(dead: true))
        XCTAssertEqual(session.consumeDeathDrops(for: "guest")?.inventory.slots.count, 2, "the planks and the coal lie on the ground")
        let clear = try XCTUnwrap(session.enqueueGrant(items: [], xp: 0, clearAll: true, to: "guest"))    // as the transport does
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants, [clear])
        session.updatePlayerState(playerState())
        XCTAssertTrue(publish(session, guest, revision: 2, applied: 0), "built before the clear arrived")
        XCTAssertTrue(copy(session).slots.isEmpty, "what lies on the ground does not come back into the copy")
    }

    func testAGuestThatLeavesIsRestoredFromTheCopyAndOwesNoGrant() throws {
        let session = hostSession()
        let grant = try XCTUnwrap(session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 2)],
                                                       xp: 0, clearAll: false, to: "guest"))
        session.disconnectPeer(playerID: "guest", tick: 1)
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants, [])
        let restore = try XCTUnwrap(session.peerRestoreState(playerID: "guest"))
        XCTAssertEqual(restore.grantID, grant.grantID)
        XCTAssertEqual(count("coal", in: restore.inventory), 2)
    }

    func testAPickupTheCopyHasNoRoomForIsNotMadeAtAll() throws {
        let session = hostSession()
        let full: [ItemStack?] = (0..<36).map { _ in stack("iron_sword") }
        publish(session, full, revision: 1, applied: 0)
        XCTAssertNil(session.applyAuthoritativePickupMutation(
            LANAuthoritativePickupMutation(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 4)], xp: 3), for: "guest"))
        XCTAssertTrue(session.drainGrants(for: "guest").isEmpty)
        XCTAssertEqual(session.peers["guest"]?.lastGrantID, 0)
        XCTAssertEqual(copy(session).xp, 0)
    }

    // MARK: - What a guest carries outside its inventory

    /// The host's copy shows 36 slots. A guest also carries its off-hand and its armor, and
    /// one key moves the stack in its hand there. A grant that takes something away follows it:
    /// otherwise the swap-hands key, pressed before the grant arrives, would save the stack.
    func testWhatAGrantTakesAwayIsFoundInTheOffHandAndTheArmor() {
        var inventory = empty()
        var pockets: [ItemStack?] = [stack("oak_planks", 10), nil, nil, stack("iron_pickaxe", damage: 5), nil]
        let placed = LANInventoryGrant(playerID: "guest", grantID: 1, items: [], xp: 0, clearAll: false, changes: [
            LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 10),
                                    after: LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 9)),
            LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 1, itemID: iid("iron_pickaxe"), count: 1, damage: 5),
                                    after: LANInventorySlotSnapshot(slot: 1, itemID: iid("iron_pickaxe"), count: 1, damage: 6)),
        ])
        lanApply(placed, to: &inventory, pockets: &pockets)
        XCTAssertEqual(pockets[0]?.count, 9, "one plank leaves the off-hand")
        XCTAssertEqual(pockets[3]?.damage, 6, "and the tool wears where it is")
        XCTAssertTrue(inventory.allSatisfy { $0 == nil }, "nothing is put into the inventory for it")

        let paid = LANInventoryGrant(playerID: "guest", grantID: 2, items: [], xp: 0, clearAll: false,
                                     take: [LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 6)])
        inventory[4] = stack("oak_planks", 2)
        lanApply(paid, to: &inventory, pockets: &pockets)
        XCTAssertNil(inventory[4], "a payment takes from the inventory first")
        XCTAssertEqual(pockets[0]?.count, 5, "and the rest from the off-hand")

        let thrown = LANInventoryGrant(playerID: "guest", grantID: 3, items: [], xp: 0, clearAll: false, changes: [
            LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 5), after: nil)])
        lanApply(thrown, to: &inventory, pockets: &pockets)
        XCTAssertNil(pockets[0])
    }

    func testWhatAGrantGivesNeverGoesIntoTheOffHandOrTheArmor() {
        var inventory: [ItemStack?] = (0..<36).map { _ in stack("iron_sword") }
        var pockets: [ItemStack?] = [stack("coal", 3), nil, nil, nil, nil]
        let given = LANInventoryGrant(playerID: "guest", grantID: 1,
                                      items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 4)], xp: 0, clearAll: false,
                                      changes: [LANInventoryStackChange(before: nil, after: LANInventorySlotSnapshot(slot: 2, itemID: iid("dirt"), count: 1))])
        XCTAssertEqual(lanApply(given, to: &inventory, pockets: &pockets), 4, "a full inventory has no room, whatever the off-hand holds")
        XCTAssertEqual(pockets.map { $0?.count }, [3, nil, nil, nil, nil])
        let death = LANInventoryGrant(playerID: "guest", grantID: 2, items: [], xp: 0, clearAll: true)
        lanApply(death, to: &inventory, pockets: &pockets)
        XCTAssertTrue(inventory.allSatisfy { $0 == nil })
        XCTAssertEqual(pockets[0]?.count, 3, "a death clears the inventory; the off-hand and armor stay the client's own, as before")
    }

    /// The security review's case. The guest throws its whole stack and presses the swap-hands
    /// key before the host's grant is back. The stack is in the off-hand when the grant arrives,
    /// and leaves it there: the thrown diamonds exist once.
    @MainActor func testAStackThrownAndThenSwappedToTheOffHandExistsOnce() throws {
        let world = loadedWorld()
        let session = hostSession()
        let game = guestGame(session, label: "lan-copy-toss-swap")
        game.player.selectedSlot = 0
        game.player.inventory[0] = stack("diamond", 64)
        game.publishLANInventoryNow()
        var asked: [LANTossIntent] = []
        game.lanTossIntentHandler = { asked.append($0) }
        game.keyDown("KeyQ", now: 0, ctrlOrCmd: true)
        game.keyDown(try XCTUnwrap(game.keybinds["swapOffhand"]), now: 0)
        XCTAssertEqual(game.player.offHand?.count, 64)
        XCTAssertNil(game.player.inventory[0])

        let outcome = LANHostGhostRegistry().applyToss(for: "guest", intent: try XCTUnwrap(asked.first), world: world, session: session)
        XCTAssertTrue(outcome.tossed)
        let grant = try XCTUnwrap(session.recordGhostInventory(outcome.inventory, for: "guest"))
        game.publishLANInventoryNow()                           // the publish that crosses the grant
        game.applyLANGrant(grant)
        game.publishLANInventoryNow()
        XCTAssertNil(game.player.offHand, "the thrown stack left the off-hand")
        XCTAssertEqual(game.player.countItem(iid("diamond")), 0)
        XCTAssertEqual(world.entities.compactMap { $0 as? ItemEntity }.map(\.stack.count), [64])
        XCTAssertTrue(copy(session).slots.isEmpty)
    }

    /// The same key after a paste was clicked and before its payment arrived: the planks are
    /// taken out of the off-hand.
    @MainActor func testAPaymentFindsThePlanksTheGuestSwappedToItsOffHand() throws {
        let session = hostSession()
        let game = guestGame(session, label: "lan-copy-take-swap")
        game.player.selectedSlot = 0
        game.player.inventory[0] = stack("oak_planks", 10)
        game.publishLANInventoryNow()
        let take = try XCTUnwrap(session.enqueueGrant(items: [], xp: 0, clearAll: false, to: "guest",
                                                      take: [LANInventorySlotSnapshot(slot: 0, itemID: iid("oak_planks"), count: 6)]))
        game.keyDown(try XCTUnwrap(game.keybinds["swapOffhand"]), now: 0)
        game.publishLANInventoryNow()
        game.applyLANGrant(take)
        game.publishLANInventoryNow()
        XCTAssertEqual(game.player.offHand?.count, 4)
        XCTAssertTrue(copy(session).slots.isEmpty, "the host sees the 36 slots, and they are empty")
        game.keyDown(try XCTUnwrap(game.keybinds["swapOffhand"]), now: 0)
        game.publishLANInventoryNow()
        XCTAssertEqual(count("oak_planks", in: copy(session)), 4, "back in the hand: four, not ten")
    }

    private final class ScreenSpyHost: GameHost {
        var handedBack = 0
        func returnStacksHeldByScreens() { handedBack += 1 }
        func showActionBar(_ text: String, _ time: Int) {}
        func pushChat(_ line: String) {}
        func hasScreen() -> Bool { false }; func screenPausesGame() -> Bool { false }
        func openScreen(_ kind: String, _ data: ScreenData?) {}
        func openTrading(_ villager: Mob) {}; func openVehicleChest(_ kind: String, _ vehicle: Entity) {}
        func openChat(_ prefix: String) {}; func openDeathScreen(_ message: String) {}
        func openPauseScreen() {}; func openTitleScreen() {}; func closeAllScreens() {}
        func releasePointer() {}; func capturePointer() {}
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

    /// A stack on the cursor of an open screen is in no slot at all. Before a grant takes
    /// something away, the client has its screen hand such stacks back; a grant that only
    /// gives, or a death, needs nothing handed back.
    @MainActor func testBeforeAGrantTakesSomethingAwayTheScreenHandsBackWhatItHolds() {
        let session = hostSession()
        let game = guestGame(session, label: "lan-copy-screen-spy")
        let spy = ScreenSpyHost()
        game.host = spy
        game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 1,
                                             items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 2)], xp: 0, clearAll: false))
        game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 2, items: [], xp: 0, clearAll: true))
        game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 3, items: [], xp: 0, clearAll: false))
        XCTAssertEqual(spy.handedBack, 0)
        game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 4, items: [], xp: 0, clearAll: false,
                                             take: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)]))
        game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 5, items: [], xp: 0, clearAll: false, changes: [
            LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1), after: nil)]))
        XCTAssertEqual(spy.handedBack, 2)
    }

    // MARK: - A toss

    /// The guest only asks. The host throws the item from its copy and the grant takes it out
    /// of the guest's inventory, wherever the stack sits by then.
    @MainActor func testATossLeavesTheGuestsInventoryWhenTheHostsGrantArrives() throws {
        let world = loadedWorld()
        let session = hostSession()
        let game = guestGame(session, label: "lan-copy-toss")
        game.player.selectedSlot = 0
        game.player.inventory[0] = stack("oak_planks", 5)
        game.publishLANInventoryNow()
        var asked: [LANTossIntent] = []
        game.lanTossIntentHandler = { asked.append($0) }
        game.keyDown("KeyQ", now: 0)
        XCTAssertEqual(game.player.countItem(iid("oak_planks")), 5, "the guest's own copy waits for the host")

        let outcome = LANHostGhostRegistry().applyToss(for: "guest", intent: try XCTUnwrap(asked.first), world: world, session: session)
        XCTAssertTrue(outcome.tossed)
        let grant = try XCTUnwrap(session.recordGhostInventory(outcome.inventory, for: "guest"))
        game.player.inventory.swapAt(0, 4)                      // moved before the grant arrived
        game.applyLANGrant(grant)
        game.publishLANInventoryNow()
        XCTAssertEqual(game.player.inventory[4]?.count, 4)
        XCTAssertEqual(world.entities.compactMap { $0 as? ItemEntity }.map(\.stack.count), [1])
        XCTAssertEqual(copy(session).slots, makeLANInventorySlotSnapshots(game.player.inventory))
    }

    /// A toss the host does not carry out (its copy holds nothing in that slot) costs nothing:
    /// until 1.5.0 the guest had already taken the item out of its own inventory.
    @MainActor func testATossTheHostDoesNotCarryOutCostsTheGuestNothing() throws {
        let world = loadedWorld()
        let session = hostSession()
        let game = guestGame(session, label: "lan-copy-toss-refused")
        game.player.selectedSlot = 3
        game.player.inventory[3] = stack("diamond", 2)
        var asked: [LANTossIntent] = []
        game.lanTossIntentHandler = { asked.append($0) }
        game.keyDown("KeyQ", now: 0)                            // before the host has heard of the diamonds
        let outcome = LANHostGhostRegistry().applyToss(for: "guest", intent: try XCTUnwrap(asked.first), world: world, session: session)
        XCTAssertFalse(outcome.tossed)
        XCTAssertNil(session.recordGhostInventory(outcome.inventory, for: "guest"))
        XCTAssertEqual(game.player.countItem(iid("diamond")), 2)
        XCTAssertTrue(world.entities.compactMap { $0 as? ItemEntity }.isEmpty)
    }

    // MARK: - Seeded: placing, throwing, picking up and storing while everything arrives late

    private enum HostToGuest {
        case grant(LANInventoryGrant)
        case container(LANBlockEntitySnapshot)
    }

    /// A guest as the shipped client behaves: it rearranges its inventory, publishes when it
    /// changed, places planks by hand, throws them, picks planks up, and moves them in and out
    /// of a chest on its own side first; another player empties the chest now and then. Every
    /// message from the host arrives late. At every step the planks the guest will hold once
    /// the wire has arrived, plus those standing, lying on the ground and in the chest, are no
    /// more than it started with and picked up; the same holds for the host's copy; and at the
    /// end none is missing and the copy is the guest's inventory, slot for slot.
    ///
    /// One thing is left out: a placement the host's copy cannot pay for. The host places that
    /// block for nothing today (`testAPlacementTheHostsCopyCannotPayForIsStillFree`).
    func testNoInterleavingOfPlacingThrowingPickingUpAndStoringPutsAGuestAhead() throws {
        var random = SplitMix64(state: 0x0B10_C4ED)
        let planks = iid("oak_planks")
        var done = (placed: 0, thrown: 0, stored: 0, refused: 0, picked: 0)
        for round in 0..<150 {
            let world = loadedWorld()
            world.setBlock(2, 64, 1, Int(cell(B.chest)), SET_SILENT)
            let chest = makeContainerBE(2, 64, 1, 27)
            world.setBlockEntity(chest)
            let session = hostSession()
            let ghosts = LANHostGhostRegistry()
            var inventory = empty()
            let start = 8 + random.int(70)
            inventory[random.int(36)] = ItemStack(planks, min(64, start))
            if start > 64 { inventory[(0..<36).first { inventory[$0] == nil }!] = ItemStack(planks, start - 64) }
            var revision = 0, appliedGrantID = 0, pickedUp = 0, takenByOthers = 0
            var lastPublished: [LANInventorySlotSnapshot]?
            var wire: [HostToGuest] = []
            var mirror: [ItemStack?] = Array(repeating: nil, count: 27)
            var mirrorRevision = lanBlockEntityRevision([try XCTUnwrap(makeLANBlockEntitySnapshot(chest, dimension: 0))])
            var free = (0..<6).flatMap { x in (3..<6).map { z in (x, z) } }        // cells a plank can be placed on
            var trail: [String] = []

            func count(_ stacks: [ItemStack?]) -> Int { stacks.compactMap { $0 }.filter { $0.id == planks }.reduce(0) { $0 + $1.count } }
            func standing() -> Int { (0..<6).reduce(0) { sum, x in sum + (3..<6).filter { world.getBlockId(x, 64, $0) == Int(B.oak_planks) }.count } }
            func onTheGround() -> Int { world.entities.compactMap { $0 as? ItemEntity }.filter { $0.stack.id == planks }.reduce(0) { $0 + $1.stack.count } }
            func inChest() -> Int { count(chest.items ?? []) }
            func chestSnapshot(_ items: [ItemStack?]) -> LANBlockEntitySnapshot {
                LANBlockEntitySnapshot(dimension: 0, x: 2, y: 64, z: 1, type: "container", slotCount: 27,
                                       slots: items.enumerated().compactMap { index, stack in
                                           stack.map { LANBlockEntitySlotSnapshot(slot: index, itemID: $0.id, count: $0.count) }
                                       })
            }
            func publish(force: Bool = false) {
                let slots = makeLANInventorySlotSnapshots(inventory)
                guard force || slots != lastPublished else { return }
                lastPublished = slots
                revision += 1
                _ = session.applyInventoryUpdate(LANInventoryUpdate(
                    playerID: "guest", revision: revision,
                    snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: slots),
                    appliedGrantID: appliedGrantID), from: "guest")
            }
            func collect() { wire.append(contentsOf: session.drainGrants(for: "guest").map(HostToGuest.grant)) }
            func deliverOne() {
                guard !wire.isEmpty else { return }
                switch wire.removeFirst() {
                case .container(let snapshot):
                    mirror = Array(repeating: nil, count: 27)
                    for slot in snapshot.slots { mirror[slot.slot] = ItemStack(slot.itemID, slot.count) }
                    mirrorRevision = lanBlockEntityRevision([snapshot])
                case .grant(let grant):
                    guard grant.grantID > appliedGrantID else { return }
                    appliedGrantID = grant.grantID
                    lanApply(grant, to: &inventory)
                    lastPublished = nil                         // the client publishes on its next tick
                }
            }
            func heldOnceTheWireArrives() -> Int {
                var stacks = inventory.map(copyStack)
                var applied = appliedGrantID
                for case .grant(let grant) in wire where grant.grantID > applied { applied = grant.grantID; lanApply(grant, to: &stacks) }
                return count(stacks)
            }
            func hostCopy() -> Int { self.count("oak_planks", in: self.copy(session)) }
            func editChest(deposit: Bool) {
                let from = deposit ? inventory : mirror
                let sources = from.indices.filter { from[$0]?.id == planks }
                guard !sources.isEmpty else { return }
                let source = sources[random.int(sources.count)]
                guard let stack = from[source] else { return }
                let moved = 1 + random.int(stack.count)
                var into = deposit ? mirror : inventory
                guard lanGive(ItemStack(planks, moved), to: &into) == 0 else { return }
                let rest = stack.count > moved ? ItemStack(planks, stack.count - moved) : nil
                if deposit { inventory[source] = rest; mirror = into } else { mirror[source] = rest; inventory = into }
                revision += 1
                let slots = makeLANInventorySlotSnapshots(inventory)
                lastPublished = slots                           // an edit carries the inventory
                let edit = LANContainerEditIntent(
                    blockEntity: chestSnapshot(mirror),
                    inventory: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: slots),
                    revision: revision, editSeq: revision, blockEntityRevision: mirrorRevision, appliedGrantID: appliedGrantID)
                mirrorRevision = lanBlockEntityRevision([chestSnapshot(mirror)])
                switch session.applyContainerEditIntent(edit, from: "guest", to: world) {
                case .applied(let containers):
                    done.stored += 1
                    wire.append(contentsOf: containers.map(HostToGuest.container))
                case .rejected:
                    done.refused += 1
                    wire.append(contentsOf: session.correctRefusedContainerEdit(edit, from: "guest", in: world).map(HostToGuest.container))
                    collect()
                }
            }

            publish()
            for step in 0..<70 {
                let roll = random.int(13)
                trail.append(String(roll))
                switch roll {
                case 0, 1:
                    publish()                                   // a client tick
                case 2:
                    inventory.swapAt(random.int(36), random.int(36))
                case 3, 4, 5:
                    deliverOne()
                case 6 where count(inventory) > 0 && hostCopy() > 0 && !free.isEmpty:
                    // The guest clicks with planks in its hand; the host places and charges its copy.
                    let (x, z) = free.remove(at: random.int(free.count))
                    let outcome = ghosts.applyPlace(
                        for: "guest",
                        intent: LANBlockIntent(action: .placeBlock, x: x, y: 63, z: z, face: Dir.up, selectedHotbarSlot: 0,
                                               cell: Int(cell(B.oak_planks))),
                        world: world, session: session)
                    XCTAssertTrue(outcome.placed)
                    _ = session.recordGhostInventory(outcome.inventory, for: "guest")
                    collect()
                    done.placed += 1
                case 7:
                    // The drop key, on a slot that holds planks on the guest's side.
                    let slots = inventory.indices.filter { inventory[$0]?.id == planks }
                    guard !slots.isEmpty, let stack = inventory[slots[random.int(slots.count)]] else { break }
                    let slot = inventory.firstIndex { $0 === stack }!
                    let all = random.int(3) == 0
                    let outcome = ghosts.applyToss(for: "guest", intent: LANTossIntent(slot: slot, count: all ? stack.count : 1, all: all),
                                                   world: world, session: session)
                    if outcome.tossed {
                        _ = session.recordGhostInventory(outcome.inventory, for: "guest")
                        collect()
                        done.thrown += 1
                    }
                case 8:
                    let found = 1 + random.int(4)
                    if session.applyAuthoritativePickupMutation(
                        LANAuthoritativePickupMutation(items: [LANInventorySlotSnapshot(slot: 0, itemID: planks, count: found)], xp: 0),
                        for: "guest") != nil {
                        pickedUp += found
                        done.picked += 1
                    }
                    collect()
                case 9:
                    editChest(deposit: true)
                case 10:
                    editChest(deposit: false)
                case 11 where inChest() > 0 && random.int(2) == 0:
                    if let slot = chest.items?.firstIndex(where: { $0?.id == planks }) {
                        takenByOthers += chest.items?[slot]?.count ?? 0
                        chest.items?[slot] = nil
                        wire.append(.container(try XCTUnwrap(makeLANBlockEntitySnapshot(chest, dimension: 0))))
                    }
                default:
                    break
                }
                let elsewhere = standing() + onTheGround() + inChest() + takenByOthers
                let which = "seed 0x0B10C4ED round \(round) step \(step) trail \(trail.joined(separator: ","))"
                XCTAssertLessThanOrEqual(heldOnceTheWireArrives() + elsewhere, start + pickedUp, which)
                XCTAssertLessThanOrEqual(hostCopy() + elsewhere, start + pickedUp, "\(which): host copy")
            }
            while !wire.isEmpty { deliverOne() }
            publish(force: true)
            let which = "seed 0x0B10C4ED round \(round) trail \(trail.joined(separator: ","))"
            XCTAssertEqual(count(inventory) + standing() + onTheGround() + inChest() + takenByOthers, start + pickedUp,
                           "\(which): every plank is somewhere, once")
            XCTAssertEqual(copy(session).slots, makeLANInventorySlotSnapshots(inventory), "\(which): the host's copy is the guest's inventory")
            XCTAssertEqual(count(mirror), inChest(), which)
        }
        XCTAssertGreaterThan(done.placed, 150)
        XCTAssertGreaterThan(done.thrown, 150)
        XCTAssertGreaterThan(done.stored, 150)
        XCTAssertGreaterThan(done.refused, 30)
        XCTAssertGreaterThan(done.picked, 150)
    }

    /// ACCEPTED, NOT FIXED: the host places a block for a guest even when its copy of that
    /// guest's inventory holds no such item (`LANHostGhostRegistry.applyPlace`), and charges
    /// nothing. A guest with one plank that clicks twice before the first grant is back has
    /// two planks standing. The window is one round trip, the gain one block per click, and a
    /// guest can give itself blocks with a chat command in any case; closing it means refusing
    /// the placement, which needs the item a guest holds to be matched to the block it places
    /// (seeds place wheat). Expected to fail until the host refuses a placement it cannot charge.
    func testAPlacementTheHostsCopyCannotPayForIsStillFree() throws {
        let world = loadedWorld()
        let session = hostSession()
        var guest = empty()
        guest[0] = stack("oak_planks", 1)
        publish(session, guest, revision: 1, applied: 0)
        let first = try XCTUnwrap(place("oak_planks", at: 2, in: world, for: session))
        let second = place("oak_planks", at: 3, in: world, for: session)       // clicked before the grant was back
        lanApply(first, to: &guest)
        if let second { lanApply(second, to: &guest) }
        let standing = [2, 3].filter { world.getBlockId($0, 64, 3) == Int(B.oak_planks) }.count
        XCTExpectFailure("a placement the host's copy cannot pay for is placed for nothing") {
            XCTAssertEqual(count("oak_planks", in: guest) + standing, 1)
        }
    }

    // MARK: - The wire

    func testAGrantCarriesItsChangesThroughTheCodecAndAnOlderShapeDecodesWithout() throws {
        let grant = LANInventoryGrant(playerID: "guest", grantID: 4, items: [], xp: 0, clearAll: false, changes: [
            LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 2, itemID: iid("iron_pickaxe"), count: 1, damage: 5, craftingQuality: 2),
                                    after: LANInventorySlotSnapshot(slot: 2, itemID: iid("iron_pickaxe"), count: 1, damage: 6, craftingQuality: 2)),
            LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 7, itemID: iid("arrow"), count: 1), after: nil),
        ])
        let frame = try LANMultiplayerFrameCodec.encode(.inventoryGrant(grant), sequence: 1)
        XCTAssertEqual(try LANMultiplayerFrameCodec.decode(frame).message, .inventoryGrant(grant))
        let older = Data(#"{"playerID":"guest","grantID":3,"items":[],"xp":0,"clearAll":false,"clearedSlots":[1,2],"slots":[{"slot":0,"itemID":1,"count":64}]}"#.utf8)
        let decoded = try JSONDecoder().decode(LANInventoryGrant.self, from: older)
        XCTAssertTrue(decoded.changes.isEmpty)
        XCTAssertEqual(decoded.grantID, 3)
        let flood = LANInventoryGrant(playerID: "guest", grantID: 1, items: [], xp: 0, clearAll: false,
                                      changes: Array(repeating: LANInventoryStackChange(before: nil, after: nil), count: 500))
        XCTAssertEqual(flood.changes.count, LAN_MULTIPLAYER_MAX_GRANT_CHANGES)
    }

    func testAContainerEditCarriesTheAppliedGrantThroughTheCodecAndAnOlderShapeDecodesToNone() throws {
        let chest = LANBlockEntitySnapshot(dimension: 0, x: 2, y: 64, z: 1, type: "container", slotCount: 27, slots: [])
        let edit = LANContainerEditIntent(blockEntity: chest, inventory: snapshot(empty()), revision: 3, editSeq: 1,
                                          blockEntityRevision: 9, appliedGrantID: 12)
        let frame = try LANMultiplayerFrameCodec.encode(.containerEditIntent(playerID: "guest", intent: edit), sequence: 1)
        guard case .containerEditIntent(_, let received) = try LANMultiplayerFrameCodec.decode(frame).message else {
            return XCTFail("no edit")
        }
        XCTAssertEqual(received.appliedGrantID, 12)
        XCTAssertEqual(received, edit)
        XCTAssertEqual(LANContainerEditIntent(blockEntity: chest, inventory: snapshot(empty()), revision: 1, editSeq: 1,
                                              appliedGrantID: -4).appliedGrantID, 0)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as? [String: Any])
        object.removeValue(forKey: "appliedGrantID")
        let older = try JSONDecoder().decode(LANContainerEditIntent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.appliedGrantID, 0)
    }
}
