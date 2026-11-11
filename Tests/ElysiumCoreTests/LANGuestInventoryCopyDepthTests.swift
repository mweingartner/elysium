import XCTest
@testable import ElysiumCore

/// Deeper, seeded coverage of the LAN host's copy of a guest's inventory
/// (`LANGuestInventoryCopy.swift`), extending `LANGuestInventoryCopyTests` and
/// `LANContainerEditCorrectionTests`:
///
/// - P1  a grant leaves the host's copy and the guest's client holding the same thing
/// - P2  the stack changes between two inventories lead from one to the other, for any two
/// - P3  a stack change never makes more of anything than it says it adds
/// - P4  a snapshot behind grants is stored with exactly those grants; the kept list is bounded
/// - P5  every refusal of a container edit, corrected, leaves guest and host agreeing
/// - P6  grants and container edits on the wire, valid and hostile
/// - P7  a hostile grant never crashes the guest's client
///
/// Every seeded test names its seed and round in each failure message so a failure replays.
/// The defects these properties found have their own suite, `LANGuestInventoryCopyDefectTests`.
final class LANGuestInventoryCopyDepthTests: XCTestCase {
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
        mutating func chance(_ oneIn: Int) -> Bool { int(oneIn) == 0 }
    }

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

    private func playerState(x: Double = 2.5, dead: Bool = false) -> LANPlayerState {
        LANPlayerState(playerID: "guest", displayName: "Alex", x: x, y: 64, z: 1.5, yaw: 0, pitch: 0,
                       health: dead ? 0 : 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival, dead: dead)
    }

    private func hostSession(state: Bool = true) -> LANMultiplayerHostSession {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        if state { session.updatePlayerState(playerState()) }
        return session
    }

    private func snapshot(_ stacks: [ItemStack?], xp: Int = 0, level: Int = 0, progress: Double = 0) -> LANPlayerInventorySnapshot {
        LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: makeLANInventorySlotSnapshots(stacks),
                                   xp: xp, xpLevel: level, xpProgress: progress)
    }

    private func empty() -> [ItemStack?] { Array(repeating: nil, count: 36) }

    private func copy(_ session: LANMultiplayerHostSession) -> LANPlayerInventorySnapshot? {
        session.peers["guest"]?.inventory
    }

    private func slots(_ stacks: [ItemStack?]) -> [LANInventorySlotSnapshot] { makeLANInventorySlotSnapshots(stacks) }

    /// A stack exactly as the wire carries it: every field survives a snapshot round trip.
    private func wireForm(_ stacks: [ItemStack?]) -> [ItemStack?] {
        makeInventory(from: snapshot(stacks)) ?? empty()
    }

    private let plainKinds = ["dirt", "oak_planks", "glass", "arrow", "ender_pearl", "coal", "stick"]
    private let toolKinds = ["iron_pickaxe", "iron_sword", "bow"]

    /// Any well-formed stack the wire can carry: plain stacks of every size (16-stacks too),
    /// labelled ones, damaged tools with a crafting quality and canonical enchantments, tipped
    /// arrows with a potion. Never mending (see the defect suite).
    private func randomStack(_ random: inout SplitMix64) -> ItemStack {
        switch random.int(6) {
        case 0, 1, 2:
            let id = iid(plainKinds[random.int(plainKinds.count)])
            return ItemStack(id, 1 + random.int(itemDefs[id].maxStack), label: random.chance(6) ? ["Named", "Other"][random.int(2)] : nil)
        case 3, 4:
            let id = iid(toolKinds[random.int(toolKinds.count)])
            var ench: [EnchInstance] = []
            if random.chance(3) { ench.append(EnchInstance("looting", 1 + random.int(3))) }
            if random.chance(3) { ench.append(EnchInstance("unbreaking", 1 + random.int(3))) }
            return ItemStack(id, 1, damage: random.int(6), ench: ench,
                             label: random.chance(8) ? "Named" : nil,
                             data: makeLANStackData(craftingQuality: random.chance(2) ? 1 + random.int(5) : nil))
        default:
            if let tipped = iidOpt("tipped_arrow"), random.chance(2) {
                return ItemStack(tipped, 1 + random.int(16),
                                 data: makeLANStackData(craftingQuality: nil, potion: ["healing", "poison", "strength"][random.int(3)]))
            }
            return ItemStack(iid("ender_pearl"), 1 + random.int(16))
        }
    }

    /// A well-formed inventory in wire form; `fill` is the share of slots that hold something.
    private func randomInventory(_ random: inout SplitMix64, full: Bool = false) -> [ItemStack?] {
        let fill = full ? 1 : random.int(5)
        return wireForm((0..<36).map { _ in full || random.int(4) < fill ? randomStack(&random) : nil })
    }

    private func randomEntry(_ random: inout SplitMix64, hostile: Bool) -> LANInventorySlotSnapshot {
        if hostile, random.chance(5) {
            return LANInventorySlotSnapshot(slot: random.int(80) - 8, itemID: [1_000_000, -3, itemDefs.count][random.int(3)],
                                            count: [0, 127, -5, 1_000][random.int(4)])
        }
        let stack = randomStack(&random)
        let count = hostile && random.chance(4) ? [0, 127, 65, 200][random.int(4)] : stack.count
        return LANInventorySlotSnapshot(slot: hostile ? random.int(64) : random.int(36), itemID: stack.id, count: count,
                                        damage: stack.damage, label: stack.label, craftingQuality: stack.data.craftingQuality,
                                        enchantments: stack.ench.map(LANItemEnchantmentSnapshot.init), potion: stack.data.potion)
    }

    /// A stack change from a host that might not be honest: either side may be missing, name
    /// another item, a slot past the inventory, a count past the stack or none at all.
    private func randomChange(_ random: inout SplitMix64, from inventory: [ItemStack?]) -> LANInventoryStackChange {
        func side() -> LANInventorySlotSnapshot? {
            switch random.int(5) {
            case 0: return nil
            case 1:
                let held = inventory.indices.filter { inventory[$0] != nil }
                guard let index = held.isEmpty ? nil : held[random.int(held.count)] else { return nil }
                return slots([inventory[index]].map(copyStack)).first.map { entry in
                    var entry = entry
                    entry.slot = random.chance(3) ? random.int(64) : index
                    return entry
                }
            default: return randomEntry(&random, hostile: true)
            }
        }
        return LANInventoryStackChange(before: side(), after: side())
    }

    /// A grant of every shape the host can send, some of them hostile. (No `slots`: the whole-
    /// inventory grant is being removed from the design, so nothing here depends on it.)
    private func randomGrant(_ random: inout SplitMix64, from inventory: [ItemStack?]) -> (items: [LANInventorySlotSnapshot], xp: Int,
                                                                                         clearAll: Bool,
                                                                                         take: [LANInventorySlotSnapshot],
                                                                                         changes: [LANInventoryStackChange]) {
        var items: [LANInventorySlotSnapshot] = []
        var xp = 0
        var clearAll = false
        var take: [LANInventorySlotSnapshot] = []
        var changes: [LANInventoryStackChange] = []
        for _ in 0..<(1 + random.int(3)) {
            switch random.int(7) {
            case 0: items += (0..<(1 + random.int(random.chance(4) ? 64 : 4))).map { _ in randomEntry(&random, hostile: random.chance(3)) }
            case 1: xp += random.int(400)
            case 2:
                take += (0..<(1 + random.int(3))).map { _ in
                    LANInventorySlotSnapshot(slot: 0, itemID: iid(plainKinds[random.int(plainKinds.count)]), count: 1 + random.int(80))
                }
            case 3, 4: changes += (0..<(1 + random.int(random.chance(4) ? 64 : 6))).map { _ in randomChange(&random, from: inventory) }
            case 5:
                var edited = inventory.map(copyStack)
                for _ in 0..<(1 + random.int(4)) { edited[random.int(36)] = random.chance(3) ? nil : randomStack(&random) }
                changes += lanStackChanges(from: snapshot(inventory), to: snapshot(wireForm(edited)))
            default:
                clearAll = random.chance(2)                    // a death clear
            }
        }
        return (items, xp, clearAll, take, changes)
    }

    private func isWellFormed(_ inventory: [ItemStack?]) -> Bool {
        inventory.count == 36 && inventory.allSatisfy { stack in
            guard let stack else { return true }
            return stack.id >= 0 && stack.id < itemDefs.count && stack.count > 0 && stack.count <= itemDefs[stack.id].maxStack && stack.damage >= 0
        }
    }

    @MainActor private func guestGame(label: String) -> GameCore {
        let game = PersistenceTestSupport.makeGame(owner: self, label: label)
        game.enterLANClientWorld(LANWorldSummary(worldID: "host", worldName: "Host", seed: 42, gameMode: GameMode.survival,
                                                 difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2))
        return game
    }

    // MARK: - P1: the host's copy and the guest's client apply a grant alike

    /// The host and a real guest client start from the same inventory and experience. Whatever
    /// the grant (pickups that do not fit, payments, stack changes that name nothing the guest
    /// holds, a death clear, experience across levels), the host's copy after `enqueueGrant`
    /// is what the client holds after `applyLANGrant`, slot for slot and point for point.
    @MainActor func testP1_TheHostsCopyAfterAGrantIsWhatTheGuestsClientHoldsAfterIt() throws {
        let seed: UInt64 = 0xC0_9E_5A_4E
        var random = SplitMix64(state: seed)
        let game = guestGame(label: "lan-copy-depth-p1")
        let player = try XCTUnwrap(game.player)
        var shapes = (items: 0, take: 0, changes: 0, clearAll: 0, xp: 0, unplaced: 0)
        for round in 0..<300 {
            let start = randomInventory(&random, full: random.chance(6))
            let xp = random.int(2_000), level = random.int(40), progress = Double(random.int(1_000)) / 1_000
            let session = hostSession()
            session.recordInventorySnapshot(snapshot(start, xp: xp, level: level, progress: progress), from: "guest")
            let begin = try XCTUnwrap(copy(session))
            let shape = randomGrant(&random, from: start)
            var grant = try XCTUnwrap(session.enqueueGrant(items: shape.items, xp: shape.xp, clearAll: shape.clearAll, to: "guest",
                                                           take: shape.take, changes: shape.changes),
                                      "seed \(seed) round \(round): a well-formed copy takes every grant")
            XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants.count ?? 0, grant.changesInventory ? 1 : 0)
            let host = try XCTUnwrap(copy(session))

            player.inventory = makeInventory(from: begin) ?? empty()
            player.xp = begin.xp
            player.xpLevel = begin.xpLevel
            player.xpProgress = begin.xpProgress
            grant.grantID = round + 1                          // the client applies each id once
            game.applyLANGrant(grant)

            let which = "seed \(seed) round \(round)"
            XCTAssertEqual(slots(player.inventory), host.slots, "\(which): slots")
            XCTAssertEqual(player.xp, host.xp, "\(which): xp")
            XCTAssertEqual(player.xpLevel, host.xpLevel, "\(which): level")
            XCTAssertEqual(player.xpProgress, host.xpProgress, accuracy: 1e-9, "\(which): progress")
            XCTAssertTrue(isWellFormed(player.inventory), which)
            XCTAssertEqual(game.lanLastAppliedGrantID, round + 1)
            shapes.items += shape.items.isEmpty ? 0 : 1
            shapes.take += shape.take.isEmpty ? 0 : 1
            shapes.changes += shape.changes.isEmpty ? 0 : 1
            shapes.clearAll += shape.clearAll ? 1 : 0
            shapes.xp += shape.xp > 0 ? 1 : 0
            var scratch = makeInventory(from: begin) ?? empty()
            shapes.unplaced += lanApply(grant, to: &scratch) > 0 ? 1 : 0
        }
        XCTAssertGreaterThan(shapes.items, 60)
        XCTAssertGreaterThan(shapes.take, 40)
        XCTAssertGreaterThan(shapes.changes, 100)
        XCTAssertGreaterThan(shapes.clearAll, 20)
        XCTAssertGreaterThan(shapes.xp, 40)
        XCTAssertGreaterThan(shapes.unplaced, 10, "pickups with no room were exercised")
    }

    /// A grant applied a second time (a replay over the wire) changes nothing on the client, and
    /// an id at or below the last applied one is ignored even when it differs.
    @MainActor func testP1_AReplayedOrOlderGrantIsIgnoredByTheClient() throws {
        let game = guestGame(label: "lan-copy-depth-replay")
        let player = try XCTUnwrap(game.player)
        let coal = LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 3)
        game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 5, items: [coal], xp: 0, clearAll: false))
        game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 5, items: [coal], xp: 0, clearAll: false))
        game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 4, items: [], xp: 0, clearAll: true))
        game.applyLANGrant(LANInventoryGrant(playerID: "", grantID: 0, items: [coal], xp: 0, clearAll: false))
        XCTAssertEqual(player.countItem(iid("coal")), 3)
        XCTAssertEqual(game.lanLastAppliedGrantID, 5)
    }

    // MARK: - P2: the changes between any two inventories lead from one to the other

    /// Not only the shapes a ghost leaves: two unrelated inventories, a shuffle of the same
    /// stacks, every pair of slots swapped, every stack changed into another kind with more than
    /// one in it, and inventories with all 36 slots full on both sides. A slot that holds another
    /// item afterwards is two changes, so a diff of 36 slots is at most 72: the cap of a grant,
    /// which therefore never cuts one short. It survives the codec.
    func testP2_TheChangesBetweenAnyTwoInventoriesLeadFromOneToTheOther() throws {
        let seed: UInt64 = 0x00D1_FF00
        var random = SplitMix64(state: seed)
        var shapesSeen = Set<Int>()
        for round in 0..<600 {
            let shape = round % 6
            shapesSeen.insert(shape)
            let a = randomInventory(&random, full: shape == 4 || random.chance(5))
            var b: [ItemStack?]
            switch shape {
            case 0: b = randomInventory(&random, full: random.chance(3))                 // unrelated
            case 1:                                                                         // shuffled
                b = a.map(copyStack)
                for index in stride(from: 35, to: 0, by: -1) { b.swapAt(index, random.int(index + 1)) }
            case 2:                                                                         // pairs swapped
                b = a.map(copyStack)
                for _ in 0..<(1 + random.int(6)) { b.swapAt(random.int(36), random.int(36)) }
            case 3:                                                                         // kinds changed, counts > 1
                b = a.map { stack in
                    guard let stack else { return nil }
                    let other = iid(self.plainKinds[random.int(self.plainKinds.count)])
                    return ItemStack(other, 2 + random.int(itemDefs[other].maxStack - 1))
                }
            case 4: b = randomInventory(&random, full: true)                                // 36 full on both sides
            default:                                                                        // same kind, other count, label or damage
                b = a.map { stack in
                    guard let stack = stack?.copy() else { return random.chance(3) ? self.randomStack(&random) : nil }
                    switch random.int(4) {
                    case 0: stack.count = 1 + random.int(itemDefs[stack.id].maxStack)
                    case 1: stack.label = stack.label == nil ? "Named" : nil
                    case 2: stack.damage += 1 + random.int(3)
                    default: break
                    }
                    return stack
                }
            }
            b = wireForm(b)
            let which = "seed \(seed) round \(round) shape \(shape)"
            let changes = lanStackChanges(from: snapshot(a), to: snapshot(b))
            XCTAssertLessThanOrEqual(changes.count, LAN_MULTIPLAYER_MAX_GRANT_CHANGES, which)
            var applied = a.map(copyStack)
            for change in changes { lanApply(change, to: &applied) }
            XCTAssertEqual(slots(applied), slots(b), which)

            // As a grant through the codec, onto the host's copy: the same inventory.
            let grant = LANInventoryGrant(playerID: "guest", grantID: 1, items: [], xp: 0, clearAll: false, changes: changes)
            XCTAssertEqual(grant.changes.count, changes.count, "\(which): the grant cap never cuts a diff short")
            guard case .inventoryGrant(let received) = try LANMultiplayerFrameCodec.decode(
                try LANMultiplayerFrameCodec.encode(.inventoryGrant(grant), sequence: 1)).message else { return XCTFail(which) }
            let copied = try XCTUnwrap(lanInventory(snapshot(a), applying: [received]), which)
            XCTAssertEqual(copied.inventory.slots, slots(b), "\(which): through the wire")
            XCTAssertTrue(lanStackChanges(from: snapshot(b), to: snapshot(b)).isEmpty, which)
        }
        XCTAssertEqual(shapesSeen.count, 6)
    }

    /// From no copy at all (a guest the host has never heard from) the changes build the
    /// inventory from nothing, and to an empty inventory they take every stack away.
    func testP2_FromNoCopyAndToNothing() {
        var random = SplitMix64(state: 0x0E_4D_17)
        for round in 0..<50 {
            let b = randomInventory(&random, full: round % 5 == 0)
            var built = empty()
            for change in lanStackChanges(from: nil, to: snapshot(b)) { lanApply(change, to: &built) }
            XCTAssertEqual(slots(built), slots(b), "seed 0x0E4D17 round \(round): from nothing")
            var emptied = b.map(copyStack)
            for change in lanStackChanges(from: snapshot(b), to: snapshot(empty())) { lanApply(change, to: &emptied) }
            XCTAssertTrue(emptied.allSatisfy { $0 == nil }, "seed 0x0E4D17 round \(round): to nothing")
        }
    }

    // MARK: - P3: a stack change never makes more than it says it adds

    private struct Kind: Hashable {
        let id: Int, damage: Int, label: String, quality: Int, potion: String, ench: [LANItemEnchantmentSnapshot]
    }

    private func kinds(_ stacks: [ItemStack?]) -> [Kind: Int] {
        var totals: [Kind: Int] = [:]
        for case let stack? in stacks {
            totals[Kind(id: stack.id, damage: stack.damage, label: stack.label ?? "", quality: stack.data.craftingQuality ?? 0,
                        potion: stack.data.potion ?? "", ench: stack.ench.map(LANItemEnchantmentSnapshot.init)), default: 0] += stack.count
        }
        return totals
    }

    private func ids(_ stacks: [ItemStack?]) -> [Int: Int] {
        var totals: [Int: Int] = [:]
        for case let stack? in stacks { totals[stack.id, default: 0] += stack.count }
        return totals
    }

    /// The most one change may add of each kind (and each item id): its own `after` less its
    /// own `before`, each read as the guest reads them (unknown items name nothing, counts are
    /// held to a stack).
    private func allowance(_ change: LANInventoryStackChange) -> (kinds: [Kind: Int], ids: [Int: Int]) {
        let before = change.before.flatMap(lanStack), after = change.after.flatMap(lanStack)
        var kinds = self.kinds([after]), ids = self.ids([after])
        for (kind, count) in self.kinds([before]) { kinds[kind, default: 0] -= count }
        for (id, count) in self.ids([before]) { ids[id, default: 0] -= count }
        return (kinds, ids)
    }

    /// Hostile and honest changes, one at a time, against inventories that were rearranged,
    /// split, partly spent or full. Nothing grows by more than the change's own allowance, and
    /// the inventory stays well formed.
    func testP3_AStackChangeNeverAddsMoreThanItsOwnAfterLessBefore() {
        let seed: UInt64 = 0x00A1_10CA
        var random = SplitMix64(state: seed)
        var effective = 0
        for round in 0..<3_000 {
            let host = randomInventory(&random, full: random.chance(4))
            var guest = host.map(copyStack)
            switch random.int(4) {                                        // what the guest did since
            case 0: for index in stride(from: 35, to: 0, by: -1) { guest.swapAt(index, random.int(index + 1)) }
            case 1:                                                       // split a stack into an empty slot
                if let from = guest.indices.first(where: { (guest[$0]?.count ?? 0) > 1 }),
                   let to = guest.indices.first(where: { guest[$0] == nil }), let stack = guest[from] {
                    let half = stack.count / 2
                    guest[from] = ItemStack(stack.id, stack.count - half, damage: stack.damage, ench: stack.ench, label: stack.label, data: stack.data)
                    guest[to] = ItemStack(stack.id, half, damage: stack.damage, ench: stack.ench, label: stack.label, data: stack.data)
                }
            case 2: for _ in 0..<(1 + random.int(5)) { guest[random.int(36)] = nil }
            default: break
            }
            let change = random.chance(3)
                ? (lanStackChanges(from: snapshot(host), to: snapshot(randomInventory(&random))).first ?? randomChange(&random, from: host))
                : randomChange(&random, from: guest)
            let held = (kinds: kinds(guest), ids: ids(guest))
            lanApply(change, to: &guest)
            let now = (kinds: kinds(guest), ids: ids(guest))
            let allowed = allowance(change)
            let which = "seed \(seed) round \(round) change \(change)"
            for (kind, count) in now.kinds {
                XCTAssertLessThanOrEqual(count - (held.kinds[kind] ?? 0), max(0, allowed.kinds[kind] ?? 0), "\(which) kind \(kind)")
            }
            for (id, count) in now.ids {
                XCTAssertLessThanOrEqual(count - (held.ids[id] ?? 0), max(0, allowed.ids[id] ?? 0), "\(which) id \(id)")
            }
            // Nor does it take more of a kind than it says it takes: a stack the guest split or
            // moved loses only what the change names, and a kind it adds loses nothing.
            for (kind, count) in held.kinds {
                XCTAssertLessThanOrEqual(count - (now.kinds[kind] ?? 0), max(0, -(allowed.kinds[kind] ?? 0)), "\(which) kind \(kind) lost")
            }
            XCTAssertTrue(isWellFormed(guest), which)
            if now.kinds != held.kinds { effective += 1 }
        }
        XCTAssertGreaterThan(effective, 600, "the changes did something often enough to mean something")
    }

    // MARK: - P4: snapshots behind grants, and the grants the host keeps

    /// A guest as the shipped client behaves: it applies grants in order as they arrive, and
    /// rearranges its inventory only right before it publishes. The host sends pickups,
    /// payments, ghost changes, empty asks and death clears, sometimes over a hundred before the
    /// guest hears any, sometimes none. At every step the host's copy is exactly what the guest
    /// will hold once the wire has arrived; the kept grants are increasing, all newer than the
    /// last one the guest named, and never more than the caps, of grants and of the stacks they
    /// name. (The host stops just below either cap: past it the host forgets grants and takes
    /// no snapshot behind them; see `LANGuestInventoryCopyRegressionTests`.)
    func testP4_TheHostsCopyIsAlwaysTheGuestOnceTheWireHasArrived() throws {
        let seed: UInt64 = 0x00AC_4ED5
        var random = SplitMix64(state: seed)
        var seen = (published: 0, behind: 0, clears: 0, maxKept: 0, maxEntries: 0)
        for round in 0..<40 {
            let session = hostSession()
            var guest = randomInventory(&random)
            var revision = 1, applied = 0, named = 0
            var wire: [LANInventoryGrant] = []
            // Host-verified, as a restore is: the quality items in it are the host's own.
            session.recordInventorySnapshot(snapshot(guest), from: "guest")
            let stall = random.chance(3)                               // this guest goes quiet for a long time
            for step in 0..<(stall ? 400 : 160) {
                let which = "seed \(seed) round \(round) step \(step)"
                let keptNow = session.peers["guest"]?.unacknowledgedGrants ?? []
                // One step adds one grant of at most six stacks (a ghost that changed three slots).
                let nearlyFull = keptNow.count >= LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS - 2
                    || keptNow.reduce(0) { $0 + $1.entryCount } >= LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANT_ENTRIES - 8
                let drawn = random.int(10)
                let roll = nearlyFull && drawn < 6 ? 6 : drawn
                switch roll {
                case 0, 1:                                             // a pickup, without experience
                    // All of it or none, as the host's pickup is: no grant gives what the copy
                    // has no room for. (One that did would leave the copy without a stack the
                    // guest may still find room for, and a quality stack among them would then
                    // have the guest's next publish refused.)
                    _ = session.enqueueGrant(items: (0..<(1 + random.int(3))).map { _ in randomEntry(&random, hostile: false) },
                                             xp: 0, clearAll: false, to: "guest", onlyIfItFits: true)
                case 2:                                                // a ghost acted on the copy
                    var edited = try XCTUnwrap(makeInventory(from: try XCTUnwrap(copy(session))))
                    for _ in 0..<(1 + random.int(3)) { edited[random.int(36)] = random.chance(2) ? nil : randomStack(&random) }
                    _ = session.recordGhostInventory(snapshot(wireForm(edited)), for: "guest")
                case 3:                                                // a payment
                    _ = session.enqueueGrant(items: [], xp: 0, clearAll: false, to: "guest",
                                             take: [LANInventorySlotSnapshot(slot: 0, itemID: iid(plainKinds[random.int(plainKinds.count)]),
                                                                             count: 1 + random.int(20))])
                case 4 where random.chance(4):
                    _ = session.enqueueGrant(items: [], xp: 0, clearAll: false, to: "guest")       // an empty ask
                case 5 where random.chance(12):                        // a death clear
                    _ = session.enqueueGrant(items: [], xp: 0, clearAll: true, to: "guest")
                    seen.clears += 1
                case 6, 7:                                             // deliveries
                    guard !stall || random.chance(40) else { break }
                    for _ in 0..<(1 + random.int(3)) where !wire.isEmpty {
                        let grant = wire.removeFirst()
                        guard grant.grantID > applied else { continue }
                        applied = grant.grantID
                        lanApply(grant, to: &guest)
                    }
                case 8, 9:                                             // a publish, perhaps after a rearrangement
                    guard !stall || random.chance(10) else { break }
                    if random.chance(2) { guest.swapAt(random.int(36), random.int(36)) }
                    revision += 1
                    let behind = wire.contains { $0.grantID > applied && $0.changesInventory }
                    XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: revision,
                                                                                  snapshot: snapshot(guest), appliedGrantID: applied),
                                                               from: "guest"), which)
                    named = applied
                    seen.published += 1
                    seen.behind += behind ? 1 : 0
                default:
                    break
                }
                wire += session.drainGrants(for: "guest")

                var arrived = guest.map(copyStack)
                var arrivedID = applied
                for grant in wire where grant.grantID > arrivedID {
                    arrivedID = grant.grantID
                    lanApply(grant, to: &arrived)
                }
                XCTAssertEqual(try XCTUnwrap(copy(session), which).slots, slots(arrived), "\(which) roll \(roll)")
                let kept = try XCTUnwrap(session.peers["guest"]?.unacknowledgedGrants, which)
                XCTAssertLessThanOrEqual(kept.count, LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS, which)
                XCTAssertEqual(kept.map(\.grantID), kept.map(\.grantID).sorted(), which)
                XCTAssertEqual(Set(kept.map(\.grantID)).count, kept.count, which)
                XCTAssertTrue(kept.allSatisfy { $0.grantID > named && $0.changesInventory }, which)
                let entries = kept.reduce(0) { $0 + $1.entryCount }
                XCTAssertLessThanOrEqual(entries, LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANT_ENTRIES, which)
                seen.maxKept = max(seen.maxKept, kept.count)
                seen.maxEntries = max(seen.maxEntries, entries)
            }
            // Everything arrives and the guest publishes: the copy is the guest, and nothing is kept.
            for grant in wire where grant.grantID > applied { applied = grant.grantID; lanApply(grant, to: &guest) }
            wire.removeAll()
            revision += 1
            XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: revision,
                                                                          snapshot: snapshot(guest), appliedGrantID: applied), from: "guest"))
            XCTAssertEqual(copy(session)?.slots, slots(guest), "seed \(seed) round \(round): settled")
            XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants, [], "seed \(seed) round \(round): settled")
        }
        XCTAssertGreaterThan(seen.published, 500)
        XCTAssertGreaterThan(seen.behind, 200, "many publishes crossed grants")
        XCTAssertGreaterThan(seen.clears, 10, "death clears crossed publishes")
        XCTAssertGreaterThan(seen.maxKept, 100, "the list ran close to the cap of grants")
        XCTAssertGreaterThan(seen.maxEntries, 150, "and named many stacks (the cap of those is run into by `testAFloodOfRefusedEditsDoesNotMakeEverySnapshotExpensive`)")
    }

    /// The cap boundary, exactly: 128 kept grants are kept as they are, and empty asks do not
    /// count. One more and the list is again no longer than the cap and holds the newest grant
    /// (true of the resend this patch has and of dropping the oldest, which replaces it).
    func testP4_TheCapIsExactlyOneHundredAndTwentyEight() throws {
        let session = hostSession()
        let coal = LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)
        for index in 0..<LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS {
            _ = session.enqueueGrant(items: [coal], xp: 0, clearAll: false, to: "guest")
            if index % 7 == 0 { _ = session.enqueueGrant(items: [], xp: 0, clearAll: false, to: "guest") }   // not kept
        }
        var kept = try XCTUnwrap(session.peers["guest"]?.unacknowledgedGrants)
        XCTAssertEqual(kept.count, LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS, "exactly at the cap: nothing is resent")
        XCTAssertFalse(kept.contains { $0.clearAll })
        XCTAssertEqual(session.drainGrants(for: "guest").filter(\.clearAll), [])
        XCTAssertEqual(copy(session)?.slots, [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 64),
                                              LANInventorySlotSnapshot(slot: 1, itemID: iid("coal"), count: 64)])

        let last = try XCTUnwrap(session.enqueueGrant(items: [coal], xp: 0, clearAll: false, to: "guest"))
        kept = try XCTUnwrap(session.peers["guest"]?.unacknowledgedGrants)
        XCTAssertLessThanOrEqual(kept.count, LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS, "one past the cap")
        XCTAssertGreaterThanOrEqual(kept.last?.grantID ?? 0, last.grantID, "the newest grant is kept")
        XCTAssertEqual(session.drainGrants(for: "guest").first?.grantID, last.grantID, "and sent")
        XCTAssertEqual(copy(session)?.slots.reduce(0) { $0 + $1.count }, 129, "the copy holds all 129")

        // A guest that applied everything up to and including the 129th.
        var guest = empty()
        guest[0] = ItemStack(iid("coal"), 64); guest[1] = ItemStack(iid("coal"), 64); guest[2] = ItemStack(iid("coal"), 1)
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 1, snapshot: snapshot(guest),
                                                                      appliedGrantID: kept.last?.grantID ?? last.grantID), from: "guest"))
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants, [])
        XCTAssertEqual(copy(session)?.slots, slots(guest))
    }

    /// A snapshot names a grant in the middle of the kept list: only the later ones are applied
    /// to it, the named one and the ones before it are forgotten, and naming it again in a later
    /// snapshot never applies it a second time.
    func testP4_ASnapshotThatNamesAGrantNeverHasItAppliedAgain() throws {
        let session = hostSession()
        let grants = try (0..<5).map { index in
            try XCTUnwrap(session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1 + index)],
                                               xp: 0, clearAll: false, to: "guest"))
        }
        var guest = empty()
        for grant in grants.prefix(3) { lanApply(grant, to: &guest) }                   // 1+2+3 = 6 coal
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 1, snapshot: snapshot(guest),
                                                                      appliedGrantID: grants[2].grantID), from: "guest"))
        XCTAssertEqual(copy(session)?.slots, [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 15)], "6, then 4 and 5")
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants.map(\.grantID), [grants[3].grantID, grants[4].grantID])
        // The same snapshot again, newer revision: still 15, not 6 + 4 + 5 + 4 + 5.
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 2, snapshot: snapshot(guest),
                                                                      appliedGrantID: grants[2].grantID), from: "guest"))
        XCTAssertEqual(copy(session)?.slots, [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 15)])
        // A stale revision is refused and changes neither the copy nor the kept grants.
        XCTAssertFalse(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 2, snapshot: snapshot(empty()),
                                                                       appliedGrantID: grants[4].grantID), from: "guest"))
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants.count, 2)
        // A malformed snapshot is refused the same way.
        XCTAssertFalse(session.applyInventoryUpdate(LANInventoryUpdate(
            playerID: "guest", revision: 3,
            snapshot: LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: [
                LANInventorySlotSnapshot(slot: 40, itemID: iid("coal"), count: 1)]),
            appliedGrantID: grants[4].grantID), from: "guest"))
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants.count, 2)
        XCTAssertEqual(session.peers["guest"]?.inventoryRevision, 2)
    }

    /// The container edit is a snapshot too: an edit that names a grant as applied forgets it
    /// and the ones before it; one that is behind keeps the later ones and is stored with them.
    func testP4_AContainerEditForgetsTheGrantsItNamesAndKeepsTheRest() throws {
        let world = worldWithChest()
        let session = hostSession()
        var guest = empty()
        guest[0] = ItemStack(iid("stick"), 4)
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 1, snapshot: snapshot(guest)), from: "guest"))
        let first = try XCTUnwrap(session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 2)],
                                                       xp: 0, clearAll: false, to: "guest"))
        let second = try XCTUnwrap(session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("glass"), count: 1)],
                                                        xp: 0, clearAll: false, to: "guest"))
        lanApply(first, to: &guest)                                  // the coal arrived, the glass did not
        guest[0] = nil                                               // and the sticks went into the chest
        let chestHeld = try XCTUnwrap(makeLANBlockEntitySnapshot(try XCTUnwrap(world.getBlockEntity(2, 64, 1)), dimension: 0))
        let edit = LANContainerEditIntent(
            blockEntity: LANBlockEntitySnapshot(dimension: 0, x: 2, y: 64, z: 1, type: "container", slotCount: 27,
                                                slots: [LANBlockEntitySlotSnapshot(slot: 0, itemID: iid("stick"), count: 4)]),
            inventory: snapshot(guest), revision: 2, editSeq: 1, blockEntityRevision: lanBlockEntityRevision([chestHeld]),
            appliedGrantID: first.grantID)
        guard case .applied = session.applyContainerEditIntent(edit, from: "guest", to: world) else { return XCTFail("an honest edit") }
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants.map(\.grantID), [second.grantID])
        lanApply(second, to: &guest)
        XCTAssertEqual(copy(session)?.slots, slots(guest), "the glass on its way is in the copy, the coal once")
        XCTAssertEqual(session.peers["guest"]?.inventoryRevision, 2)
    }

    // MARK: - P5: every refusal of a container edit, corrected

    private struct Guest {
        var inventory: [ItemStack?]
        let mirror: World
    }

    /// One container-edit refusal: how to set the host up, which edit the guest sends, and the
    /// reason the host must give.
    private struct Refusal {
        let name: String
        let reason: String
        /// False where the edit's inventory says nothing about what the guest holds now (not
        /// newer than the stored one, malformed: only a modified client sends those) and where
        /// there is nobody to send to. The host then hands no inventory back.
        var handedBack = true
        var withdraw = true
        var prepare: (LANMultiplayerHostSession, World) -> Void = { _, _ in }
        var edit: (LANContainerEditIntent) -> LANContainerEditIntent = { $0 }
    }

    private func chestSnapshot(_ items: [(String, Int)], x: Int = 2, dimension: Int = 0, type: String = "container",
                               slotCount: Int = 27) -> LANBlockEntitySnapshot {
        LANBlockEntitySnapshot(dimension: dimension, x: x, y: 64, z: 1, type: type, slotCount: slotCount, slots: items.enumerated().map {
            LANBlockEntitySlotSnapshot(slot: $0.offset, itemID: iid($0.element.0), count: $0.element.1)
        })
    }

    private var refusals: [Refusal] {
        [
            Refusal(name: "permission", reason: "permission denied: container",
                    prepare: { session, _ in session.setPermissions(LANPeerPermissions(canUseContainers: false), for: "guest") }),
            Refusal(name: "dead", reason: "player is dead",
                    prepare: { session, _ in session.updatePlayerState(self.playerState(dead: true)) }),
            Refusal(name: "disconnected", reason: "player disconnected", handedBack: false,
                    prepare: { session, _ in session.disconnectPeer(playerID: "guest", tick: 1) }),
            Refusal(name: "player in another dimension", reason: "target dimension unavailable",
                    prepare: { session, _ in
                        session.setPermissions(LANPeerPermissions(canChangeDimensions: true), for: "guest")
                        var state = self.playerState()
                        state.dimension = Dim.nether.rawValue
                        session.updatePlayerState(state)
                    }),
            Refusal(name: "stale inventory revision", reason: "stale inventory revision", handedBack: false,
                    edit: { var edit = $0; edit.revision = 1; return edit }),
            Refusal(name: "invalid inventory payload", reason: "invalid inventory payload", handedBack: false,
                    edit: { edit in
                        var edit = edit
                        edit.inventory.slots = [LANInventorySlotSnapshot(slot: 50, itemID: iid("coal"), count: 1)]
                        return edit
                    }),
            Refusal(name: "invalid container payload", reason: "invalid container payload",
                    edit: { var edit = $0; edit.blockEntity.type = "nonsense"; return edit }),
            Refusal(name: "out of reach", reason: "target out of reach",
                    prepare: { session, _ in session.updatePlayerState(self.playerState(x: 12.5)) }),
            Refusal(name: "target in another dimension", reason: "target dimension unavailable",
                    edit: { var edit = $0; edit.blockEntity.dimension = Dim.nether.rawValue; return edit }),
            Refusal(name: "incompatible target", reason: "incompatible container target",
                    prepare: { _, world in world.setBlock(2, 64, 1, Int(cell(B.dirt)), SET_SILENT) }),
            Refusal(name: "duplicate target", reason: "duplicate container target",
                    edit: { edit in
                        LANContainerEditIntent(blockEntity: edit.blockEntity, additionalBlockEntities: [edit.blockEntity],
                                               inventory: edit.inventory, revision: edit.revision, editSeq: edit.editSeq,
                                               blockEntityRevision: edit.blockEntityRevision, appliedGrantID: edit.appliedGrantID)
                    }),
            Refusal(name: "stale container revision", reason: "stale container revision",
                    prepare: { _, world in world.getBlockEntity(2, 64, 1)?.items?[0] = nil }),
            Refusal(name: "not host-verifiable", reason: "container edit is not host-verifiable",
                    edit: { edit in
                        var edit = edit                       // the guest also claims diamonds it never had
                        edit.inventory.slots.append(LANInventorySlotSnapshot(slot: 20, itemID: iid("diamond"), count: 5))
                        return edit
                    }),
            Refusal(name: "deposit, permission", reason: "permission denied: container", withdraw: false,
                    prepare: { session, _ in session.setPermissions(LANPeerPermissions(canUseContainers: false), for: "guest") }),
            Refusal(name: "deposit, stale container revision", reason: "stale container revision", withdraw: false,
                    prepare: { _, world in world.getBlockEntity(2, 64, 1)?.items?[1] = ItemStack(iid("glass"), 3) }),
        ]
    }

    /// Walks every refusal `applyContainerEditIntent` can give an edit (each `return .rejected`
    /// that a payload can reach, plus a deposit as well as a withdrawal). The guest made its
    /// edit on its own side first; a pickup is on its way to it as well. After the way back
    /// and every grant have arrived, the guest's inventory is the host's copy, slot for slot,
    /// and its view of each container the correction returned is the host's. Three refusals
    /// hand no inventory back (`Refusal.handedBack`), and for those nothing but the pickup is sent.
    func testP5_EveryRefusalCorrectedLeavesTheGuestAndTheHostAgreeing() throws {
        var reasons = Set<String>()
        for refusal in refusals {
            let world = worldWithChest([("coal", 5)])
            let session = hostSession()
            var guest = Guest(inventory: empty(), mirror: worldWithChest([("coal", 5)]))
            guest.inventory[0] = ItemStack(iid("stick"), 7)
            guest.inventory[1] = ItemStack(iid("glass"), 3)
            XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 4, snapshot: snapshot(guest.inventory)),
                                                       from: "guest"))
            let pickup = try XCTUnwrap(session.applyAuthoritativePickupMutation(
                LANAuthoritativePickupMutation(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("ender_pearl"), count: 2)], xp: 0),
                for: "guest"))
            let heldBefore = try XCTUnwrap(makeLANBlockEntitySnapshot(try XCTUnwrap(world.getBlockEntity(2, 64, 1)), dimension: 0))

            // The guest's own move, on its side, before it asks.
            let mirrorChest = try XCTUnwrap(guest.mirror.getBlockEntity(2, 64, 1))
            if refusal.withdraw {
                mirrorChest.items?[0] = nil
                lanGive(ItemStack(iid("coal"), 5), to: &guest.inventory)
            } else {
                mirrorChest.items?[1] = guest.inventory[0]
                guest.inventory[0] = nil
            }
            let sent = refusal.edit(LANContainerEditIntent(
                blockEntity: try XCTUnwrap(makeLANBlockEntitySnapshot(mirrorChest, dimension: 0)),
                inventory: snapshot(guest.inventory), revision: 5, editSeq: 1,
                blockEntityRevision: lanBlockEntityRevision([heldBefore]), appliedGrantID: 0))
            refusal.prepare(session, world)

            XCTAssertEqual(session.applyContainerEditIntent(sent, from: "guest", to: world), .rejected(refusal.reason), refusal.name)
            reasons.insert(refusal.reason)
            let containers = session.correctRefusedContainerEdit(sent, from: "guest", in: world)
            let grants = session.drainGrants(for: "guest")
            XCTAssertEqual(grants.first, pickup, "\(refusal.name): the pickup goes out first")
            guard refusal.handedBack else {
                XCTAssertEqual(grants.count, 1, "\(refusal.name): no inventory is handed back")
                XCTAssertEqual(session.peers["guest"]?.inventoryRevision, 4, "\(refusal.name): a refused edit stores nothing")
                continue
            }
            XCTAssertGreaterThan(grants.count, 1, "\(refusal.name): the way back follows it")
            XCTAssertTrue(grants.dropFirst().allSatisfy { !$0.clearAll && $0.items.isEmpty && $0.take.isEmpty },
                          "\(refusal.name): the way back is stack changes, never the whole inventory")

            _ = applyLANBlockEntitySnapshots(containers, to: guest.mirror)
            var applied = 0
            for grant in grants where grant.grantID > applied { applied = grant.grantID; lanApply(grant, to: &guest.inventory) }
            XCTAssertEqual(slots(guest.inventory), copy(session)?.slots, "\(refusal.name): inventory")
            XCTAssertEqual(guest.inventory.compactMap { $0 }.filter { $0.id == iid("ender_pearl") }.reduce(0) { $0 + $1.count },
                           refusal.name == "dead" ? 0 : 2, "\(refusal.name): the pickup arrived once")
            for container in containers {
                let host = try XCTUnwrap(world.getBlockEntity(container.x, container.y, container.z), refusal.name)
                XCTAssertEqual(container, makeLANBlockEntitySnapshot(host, dimension: 0), "\(refusal.name): returned as held")
                let mirrored = try XCTUnwrap(guest.mirror.getBlockEntity(container.x, container.y, container.z), refusal.name)
                XCTAssertEqual(makeLANBlockEntitySnapshot(mirrored, dimension: 0), makeLANBlockEntitySnapshot(host, dimension: 0),
                               "\(refusal.name): the guest's view of the container")
            }
            // Nothing exists twice: the coal the guest took, or the sticks it put in, is in one place.
            let coal = guest.inventory.compactMap { $0 }.filter { $0.id == iid("coal") }.reduce(0) { $0 + $1.count }
                + (world.getBlockEntity(2, 64, 1)?.items ?? []).compactMap { $0 }.filter { $0.id == iid("coal") }.reduce(0) { $0 + $1.count }
            XCTAssertLessThanOrEqual(coal, 5, "\(refusal.name): coal")
            XCTAssertEqual(session.peers["guest"]?.inventoryRevision, 4, "\(refusal.name): a refused edit stores nothing")
        }
        XCTAssertEqual(reasons.count, 12, "every reachable refusal was walked")
    }

    /// "too many container targets" cannot be reached through the wire: the intent itself keeps
    /// at most the cap of containers, from code and from JSON alike.
    func testP5_TooManyContainerTargetsIsHeldToTheCapBeforeTheHostSeesIt() throws {
        let chest = chestSnapshot([])
        let edit = LANContainerEditIntent(blockEntity: chest, additionalBlockEntities: Array(repeating: chest, count: 50),
                                          inventory: snapshot(empty()), revision: 1, editSeq: 1)
        XCTAssertEqual(edit.additionalBlockEntities.count, LAN_MULTIPLAYER_MAX_CONTAINER_EDIT_BLOCK_ENTITIES - 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as? [String: Any])
        object["additionalBlockEntities"] = Array(repeating: try JSONSerialization.jsonObject(with: JSONEncoder().encode(chest)), count: 50)
        let decoded = try JSONDecoder().decode(LANContainerEditIntent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded.additionalBlockEntities.count, LAN_MULTIPLAYER_MAX_CONTAINER_EDIT_BLOCK_ENTITIES - 1)
    }

    /// An unknown player is refused and corrected with nothing at all.
    func testP5_AnUnknownPlayerIsRefusedAndGetsNoCorrection() {
        let world = worldWithChest([("coal", 1)])
        let session = hostSession()
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([]), inventory: snapshot(empty()), revision: 1, editSeq: 1)
        XCTAssertEqual(session.applyContainerEditIntent(edit, from: "stranger", to: world), .rejected("unknown player"))
        XCTAssertEqual(session.correctRefusedContainerEdit(edit, from: "stranger", in: world), [])
        XCTAssertTrue(session.drainGrants(for: "stranger").isEmpty)
        XCTAssertNil(session.recordGhostInventory(snapshot(empty()), for: "stranger"))
    }

    /// A guest the host has no position for is refused ("player state unavailable"). The host
    /// cannot tell what the guest could see, so it returns no container, but the guest's
    /// inventory still comes back as the host holds it. (The guest's view of the container keeps
    /// its own edit until the container next replicates; see the report.)
    func testP5_AGuestWithNoPositionGetsItsInventoryBackAndNoContainer() throws {
        let world = worldWithChest([("coal", 5)])
        let session = hostSession(state: false)
        var guest = empty()
        guest[0] = ItemStack(iid("stick"), 2)
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 1, snapshot: snapshot(guest)), from: "guest"))
        guest[1] = ItemStack(iid("coal"), 5)                       // taken on its own side
        let held = try XCTUnwrap(makeLANBlockEntitySnapshot(try XCTUnwrap(world.getBlockEntity(2, 64, 1)), dimension: 0))
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([]), inventory: snapshot(guest), revision: 2, editSeq: 1,
                                          blockEntityRevision: lanBlockEntityRevision([held]))
        XCTAssertEqual(session.applyContainerEditIntent(edit, from: "guest", to: world), .rejected("player state unavailable"))
        XCTAssertEqual(session.correctRefusedContainerEdit(edit, from: "guest", in: world), [])
        for grant in session.drainGrants(for: "guest") { lanApply(grant, to: &guest) }
        XCTAssertEqual(slots(guest), copy(session)?.slots)
        XCTAssertEqual(slots(guest), [LANInventorySlotSnapshot(slot: 0, itemID: iid("stick"), count: 2)])
    }

    // MARK: - P6: the wire

    private func randomSide(_ random: inout SplitMix64) -> LANInventorySlotSnapshot? {
        random.chance(3) ? nil : randomEntry(&random, hostile: random.chance(4))
    }

    /// Seeded grants and container edits of every shape, changes with either side missing among
    /// them, come out of the codec as they went in.
    func testP6_GrantsAndEditsSurviveTheCodec() throws {
        let seed: UInt64 = 0x00C0_DEC5
        var random = SplitMix64(state: seed)
        for round in 0..<300 {
            let grant = LANInventoryGrant(
                playerID: random.chance(5) ? String(repeating: "g", count: 200) : "guest", grantID: random.int(1_000_000),
                items: (0..<random.int(70)).map { _ in randomEntry(&random, hostile: random.chance(3)) },
                xp: random.int(2_000_000_000), clearAll: random.chance(4),
                take: (0..<random.int(5)).map { _ in randomEntry(&random, hostile: false) },
                changes: (0..<random.int(90)).map { _ in LANInventoryStackChange(before: randomSide(&random), after: randomSide(&random)) })
            let which = "seed \(seed) round \(round)"
            XCTAssertLessThanOrEqual(grant.items.count, LAN_MULTIPLAYER_MAX_GRANT_ITEMS, which)
            XCTAssertLessThanOrEqual(grant.changes.count, LAN_MULTIPLAYER_MAX_GRANT_CHANGES, which)
            XCTAssertLessThanOrEqual(grant.xp, 1_000_000_000, which)
            XCTAssertEqual(try LANMultiplayerFrameCodec.decode(try LANMultiplayerFrameCodec.encode(.inventoryGrant(grant), sequence: 7)).message,
                           .inventoryGrant(grant), which)

            let edit = LANContainerEditIntent(
                blockEntity: chestSnapshot([("coal", 1 + random.int(64))]),
                additionalBlockEntities: random.chance(2) ? [chestSnapshot([], x: 3)] : [],
                inventory: snapshot(randomInventory(&random), xp: random.int(10_000), level: random.int(50)),
                revision: random.int(1_000_000) - 10, editSeq: random.int(1_000), blockEntityRevision: random.int(1 << 40),
                appliedGrantID: random.int(1_000_000) - 500)
            XCTAssertGreaterThanOrEqual(edit.appliedGrantID, 0, which)
            guard case .containerEditIntent(_, let received) = try LANMultiplayerFrameCodec.decode(
                try LANMultiplayerFrameCodec.encode(.containerEditIntent(playerID: "guest", intent: edit), sequence: 3)).message
            else { return XCTFail(which) }
            XCTAssertEqual(received, edit, which)
        }
    }

    private func grantFrame(_ grantJSON: String) -> Data {
        LANMultiplayerFrameCodec.frame(kind: .inventoryGrant, payload: Data(#"{"inventoryGrant":{"_0":\#(grantJSON)}}"#.utf8), sequence: 1)
    }

    private func decodedGrant(_ grantJSON: String) throws -> LANInventoryGrant {
        guard case .inventoryGrant(let grant) = try LANMultiplayerFrameCodec.decode(grantFrame(grantJSON)).message else {
            throw LANMultiplayerCodecError.truncated
        }
        return grant
    }

    /// Hostile values are clamped on the way in, and shapes that are not a grant are refused
    /// with an error, never a crash: negative ids and counts, counts past any stack, slots far
    /// out of range, 10,000 changes, missing keys, wrong types, an older shape.
    func testP6_MalformedGrantsAreClampedOrRefusedAndNeverCrash() throws {
        // The frame shape the tests build by hand is the codec's own.
        let plain = LANInventoryGrant(playerID: "guest", grantID: 2, items: [], xp: 0, clearAll: false)
        let encoded = try LANMultiplayerFrameCodec.encodePayload(.inventoryGrant(plain)).payload
        let outer = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let inner = try XCTUnwrap((outer["inventoryGrant"] as? [String: Any])?["_0"])
        XCTAssertEqual(try decodedGrant(String(decoding: try JSONSerialization.data(withJSONObject: inner), as: UTF8.self)), plain)

        let clamped = try decodedGrant(#"""
            {"playerID":"guest","grantID":-9,"xp":-4,"items":[{"slot":-3,"itemID":-1,"count":9223372036854775807,"damage":-8}],
             "slots":[{"slot":100000,"itemID":1,"count":-1}],
             "changes":[{"before":{"slot":-1,"itemID":3,"count":1000}},{"after":{"slot":99,"itemID":3,"count":0}},{}]}
            """#)
        XCTAssertEqual(clamped.grantID, 0)
        XCTAssertEqual(clamped.xp, 0)
        XCTAssertEqual(clamped.items, [LANInventorySlotSnapshot(slot: 0, itemID: 0, count: 127, damage: 0)])
        XCTAssertEqual(clamped.changes.count, 3)
        XCTAssertEqual(clamped.changes[0].before?.count, 127)
        XCTAssertEqual(clamped.changes[0].before?.slot, 0)
        XCTAssertNil(clamped.changes[0].after)
        XCTAssertEqual(clamped.changes[1].after?.slot, LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORY_SLOTS - 1)
        XCTAssertEqual(clamped.changes[2], LANInventoryStackChange(before: nil, after: nil))

        let change = #"{"before":{"slot":0,"itemID":3,"count":1},"after":{"slot":1,"itemID":4,"count":2}}"#
        let flood = try decodedGrant(#"{"playerID":"guest","grantID":1,"changes":[\#(Array(repeating: change, count: 10_000).joined(separator: ","))]}"#)
        XCTAssertEqual(flood.changes.count, LAN_MULTIPLAYER_MAX_GRANT_CHANGES, "10,000 changes are held to the cap")

        XCTAssertEqual(try decodedGrant(#"{"playerID":"guest"}"#), LANInventoryGrant(playerID: "guest", grantID: 0, items: [], xp: 0, clearAll: false))
        let older = try decodedGrant(#"{"playerID":"guest","grantID":3,"items":[],"xp":0,"clearAll":false,"clearedSlots":[1,2]}"#)
        XCTAssertEqual(older.changes, [])
        XCTAssertEqual(older.grantID, 3)

        let refused = [
            #"{}"#,                                                                         // no playerID
            #"{"playerID":7}"#,
            #"{"playerID":"guest","changes":"many"}"#,
            #"{"playerID":"guest","changes":[{"before":5}]}"#,
            #"{"playerID":"guest","changes":[{"before":{"slot":0,"itemID":3}}]}"#,           // no count
            #"{"playerID":"guest","changes":[{"before":{"slot":0,"itemID":3,"count":1e40}}]}"#,
            #"{"playerID":"guest","grantID":"one"}"#,
            #"{"playerID":"guest","clearAll":"yes"}"#,
            #"{"playerID":"guest","changes":[null]}"#,
            #"{"playerID":"guest","items":[{"slot":0,"itemID":3,"count":1.5}]}"#,
            #"[1,2,3]"#,
        ]
        for json in refused {
            XCTAssertThrowsError(try LANMultiplayerFrameCodec.decode(grantFrame(json)), json)
        }
        // A frame that claims more payload than it carries, or more than the cap, is refused too.
        var truncated = grantFrame(#"{"playerID":"guest"}"#)
        truncated.removeLast(3)
        XCTAssertThrowsError(try LANMultiplayerFrameCodec.decode(truncated))
    }

    /// An edit with hostile numbers is clamped; one with wrong types or missing required keys is
    /// refused; an edit in the shape from before `appliedGrantID` names no grant.
    func testP6_MalformedContainerEditsAreClampedOrRefused() throws {
        let edit = LANContainerEditIntent(blockEntity: chestSnapshot([]), inventory: snapshot(empty()), revision: 1, editSeq: 1,
                                          appliedGrantID: 4)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(edit)) as? [String: Any])
        object["appliedGrantID"] = -77
        object["revision"] = -3
        let clamped = try JSONDecoder().decode(LANContainerEditIntent.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(clamped.appliedGrantID, 0)
        XCTAssertEqual(clamped.revision, 0)
        object["appliedGrantID"] = Int.max
        XCTAssertEqual(try JSONDecoder().decode(LANContainerEditIntent.self, from: JSONSerialization.data(withJSONObject: object)).appliedGrantID,
                       Int.max)
        for (key, value) in [("appliedGrantID", "x" as Any), ("inventory", 3 as Any), ("blockEntity", NSNull() as Any)] {
            var bad = object
            bad[key] = value
            XCTAssertThrowsError(try JSONDecoder().decode(LANContainerEditIntent.self, from: JSONSerialization.data(withJSONObject: bad)), key)
        }
        var missing = object
        missing.removeValue(forKey: "inventory")
        XCTAssertThrowsError(try JSONDecoder().decode(LANContainerEditIntent.self, from: JSONSerialization.data(withJSONObject: missing)))
    }

    /// A guest that names a grant the host never sent (a modified client) only ever loses grants
    /// on its own copy: the host forgets them all and applies none to its snapshot. It cannot
    /// make the host apply anything twice.
    func testP6_AGuestThatNamesAGrantFromTheFutureLosesOnlyItsOwnGrants() throws {
        let session = hostSession()
        _ = session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 3)], xp: 0, clearAll: false, to: "guest")
        var guest = empty()
        guest[4] = ItemStack(iid("stick"), 1)
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 1, snapshot: snapshot(guest),
                                                                      appliedGrantID: Int.max), from: "guest"))
        XCTAssertEqual(copy(session)?.slots, slots(guest))
        XCTAssertEqual(session.peers["guest"]?.unacknowledgedGrants, [])
    }

    // MARK: - P7: a hostile grant never crashes the guest's client

    /// Grants a hostile host could send, applied by a real client: slots out of range, unknown
    /// items, counts of 0 and 127, 64 changes that all name one slot, a whole inventory of 64
    /// slots, 64 items into a full inventory. The client never traps and holds only
    /// well-formed stacks; the same grants applied by the host's function agree with it.
    @MainActor func testP7_AHostileGrantNeverCrashesTheGuestsClient() throws {
        let game = guestGame(label: "lan-copy-depth-p7")
        let player = try XCTUnwrap(game.player)
        let dirt = iid("dirt")
        var grantID = 0
        func send(_ grant: LANInventoryGrant, _ name: String) {
            grantID += 1
            var grant = grant
            grant.grantID = grantID
            var expected = player.inventory.map(copyStack)
            lanApply(grant, to: &expected)
            game.applyLANGrant(grant)
            XCTAssertTrue(isWellFormed(player.inventory), name)
            XCTAssertEqual(slots(player.inventory), slots(expected), name)
        }
        let hostile: [(String, LANInventoryGrant)] = [
            ("slots out of range", LANInventoryGrant(playerID: "", grantID: 0, items: [], xp: 0, clearAll: false, changes: (36..<64).map {
                LANInventoryStackChange(before: nil, after: LANInventorySlotSnapshot(slot: $0, itemID: dirt, count: 64)) })),
            ("unknown items", LANInventoryGrant(playerID: "", grantID: 0, items: [LANInventorySlotSnapshot(slot: 0, itemID: 1_000_000, count: 5)],
                                                xp: 0, clearAll: false,
                                                take: [LANInventorySlotSnapshot(slot: 0, itemID: 999_999, count: 5)],
                                                changes: [LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 3, itemID: 1_000_000, count: 1),
                                                                                  after: LANInventorySlotSnapshot(slot: 3, itemID: 2_000_000, count: 1))])),
            ("counts 0 and 127", LANInventoryGrant(playerID: "", grantID: 0, items: [
                LANInventorySlotSnapshot(slot: 0, itemID: dirt, count: 0), LANInventorySlotSnapshot(slot: 0, itemID: dirt, count: 127),
                LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_sword"), count: 127)], xp: 0, clearAll: false,
                changes: [LANInventoryStackChange(before: nil, after: LANInventorySlotSnapshot(slot: 2, itemID: iid("ender_pearl"), count: 127)),
                          LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 0, itemID: dirt, count: 0), after: nil)])),
            ("64 changes on one slot", LANInventoryGrant(playerID: "", grantID: 0, items: [], xp: 0, clearAll: false,
                changes: (0..<64).map { index in
                    index % 2 == 0
                        ? LANInventoryStackChange(before: nil, after: LANInventorySlotSnapshot(slot: 5, itemID: dirt, count: 127))
                        : LANInventoryStackChange(before: LANInventorySlotSnapshot(slot: 5, itemID: dirt, count: 127),
                                                  after: LANInventorySlotSnapshot(slot: 5, itemID: iid("iron_sword"), count: 127, damage: Int.max))
                })),
            ("a clear with 64 additions on every slot", LANInventoryGrant(playerID: "", grantID: 0, items: [], xp: 0, clearAll: true,
                changes: (0..<64).map { LANInventoryStackChange(before: nil, after: LANInventorySlotSnapshot(
                    slot: $0, itemID: $0 % 2 == 0 ? dirt : iid("bow"), count: 127, damage: $0)) })),
            ("64 items into a full inventory", LANInventoryGrant(playerID: "", grantID: 0,
                items: (0..<64).map { _ in LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 64) }, xp: 0, clearAll: false)),
            ("experience at the cap", LANInventoryGrant(playerID: "", grantID: 0, items: [], xp: Int.max, clearAll: false)),
            ("clear everything", LANInventoryGrant(playerID: "", grantID: 0, items: [], xp: 0, clearAll: true)),
        ]
        for (name, grant) in hostile { send(grant, name) }
        XCTAssertEqual(grantID, hostile.count)
        XCTAssertTrue(player.inventory.allSatisfy { $0 == nil }, "the last grant cleared everything")

        // And seeded: 400 random hostile grants against whatever the client holds by then.
        let seed: UInt64 = 0x0000_4057
        var random = SplitMix64(state: seed)
        for round in 0..<400 {
            let shape = randomGrant(&random, from: player.inventory)
            send(LANInventoryGrant(playerID: "", grantID: 0, items: shape.items, xp: 0, clearAll: shape.clearAll,
                                   take: shape.take, changes: shape.changes), "seed \(seed) round \(round)")
        }
    }

    // MARK: - Boundaries of the pickup

    /// A pickup is all of it or none: exactly the room left fits; one stack more is refused and
    /// changes nothing; 64 entries (the cap) are judged as a whole; 65 are refused outright.
    func testAPickupFitsExactlyTheRoomLeftAndNoMore() throws {
        let session = hostSession()
        var guest = empty()
        for index in 0..<30 { guest[index] = ItemStack(iid("iron_sword")) }
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 1, snapshot: snapshot(guest)), from: "guest"))
        let coal = LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 64)
        XCTAssertNil(session.applyAuthoritativePickupMutation(LANAuthoritativePickupMutation(items: Array(repeating: coal, count: 7), xp: 0), for: "guest"))
        XCTAssertEqual(session.peers["guest"]?.lastGrantID, 0, "a refused pickup takes no grant id")
        let fits = try XCTUnwrap(session.applyAuthoritativePickupMutation(
            LANAuthoritativePickupMutation(items: Array(repeating: coal, count: 6), xp: 0), for: "guest"))
        lanApply(fits, to: &guest)
        XCTAssertTrue(guest.allSatisfy { $0 != nil }, "36 full slots")
        XCTAssertEqual(copy(session)?.slots, slots(guest))
        XCTAssertNil(session.applyAuthoritativePickupMutation(
            LANAuthoritativePickupMutation(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)], xp: 5), for: "guest"),
            "a full inventory takes no more coal, not even with experience")
        XCTAssertEqual(copy(session)?.xp, 0)
        XCTAssertNotNil(session.applyAuthoritativePickupMutation(LANAuthoritativePickupMutation(items: [], xp: 5), for: "guest"),
                        "experience alone always fits")
        XCTAssertNil(session.applyAuthoritativePickupMutation(
            LANAuthoritativePickupMutation(items: Array(repeating: LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1),
                                                        count: LAN_MULTIPLAYER_MAX_GRANT_ITEMS + 1), xp: 0), for: "guest"))
        for bad in [LANInventorySlotSnapshot(slot: 0, itemID: iid("iron_sword"), count: 2),
                    LANInventorySlotSnapshot(slot: 0, itemID: 1_000_000, count: 1),
                    LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 0)] {
            XCTAssertNil(session.applyAuthoritativePickupMutation(LANAuthoritativePickupMutation(items: [bad], xp: 0), for: "guest"), "\(bad)")
        }
        XCTAssertNil(session.applyAuthoritativePickupMutation(LANAuthoritativePickupMutation(items: [], xp: 0), for: "guest"))
        XCTAssertNil(session.applyAuthoritativePickupMutation(LANAuthoritativePickupMutation(items: [], xp: -1), for: "guest"))
    }

    /// 64 pickup entries into an empty inventory: 36 stacks fit, so the pickup is refused as a
    /// whole; a grant made without `onlyIfItFits` keeps the 36 on both sides and drops the rest
    /// on both sides alike.
    func testAGrantOfSixtyFourStacksIntoThirtySixSlotsDropsTheSameOnBothSides() throws {
        let session = hostSession()
        session.recordInventorySnapshot(snapshot(empty()), from: "guest")
        let entries = Array(repeating: LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 64), count: 64)
        XCTAssertNil(session.applyAuthoritativePickupMutation(LANAuthoritativePickupMutation(items: entries, xp: 0), for: "guest"))
        let grant = try XCTUnwrap(session.enqueueGrant(items: entries, xp: 0, clearAll: false, to: "guest"))
        var guest = empty()
        XCTAssertEqual(lanApply(grant, to: &guest), 28 * 64)
        XCTAssertEqual(copy(session)?.slots, slots(guest))
        XCTAssertEqual(copy(session)?.slots.count, 36)
    }

    /// A copy that is not well formed (as a damaged save might leave it) takes no grant at all,
    /// and the guest's next well-formed publish replaces it.
    func testACopyThatIsNotWellFormedTakesNoGrantUntilTheGuestPublishes() throws {
        let session = hostSession()
        session.peers["guest"]?.inventory = LANPlayerInventorySnapshot(playerID: "guest", selectedHotbarSlot: 0, slots: [
            LANInventorySlotSnapshot(slot: 3, itemID: iid("coal"), count: 1), LANInventorySlotSnapshot(slot: 3, itemID: iid("dirt"), count: 1)])
        XCTAssertNil(session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)], xp: 0, clearAll: false, to: "guest"))
        XCTAssertNil(session.recordGhostInventory(snapshot([ItemStack(iid("dirt"))]), for: "guest"))
        XCTAssertEqual(session.peers["guest"]?.lastGrantID, 0)
        XCTAssertTrue(session.drainGrants(for: "guest").isEmpty)
        var guest = empty()
        guest[0] = ItemStack(iid("stick"), 2)
        XCTAssertTrue(session.applyInventoryUpdate(LANInventoryUpdate(playerID: "guest", revision: 1, snapshot: snapshot(guest)), from: "guest"))
        XCTAssertNotNil(session.enqueueGrant(items: [LANInventorySlotSnapshot(slot: 0, itemID: iid("coal"), count: 1)], xp: 0, clearAll: false, to: "guest"))
    }

    // MARK: - Performance

    /// The host applies every kept grant to each snapshot that is behind them. At the cap that is
    /// 128 grants of 64 changes each, per publish; it stays well inside a tick.
    func testReplayingAFullListOfKeptGrantsStaysCheap() throws {
        var random = SplitMix64(state: 0x0000_F457)
        let start = randomInventory(&random, full: true)
        let grants = (1...LAN_MULTIPLAYER_MAX_UNACKNOWLEDGED_GRANTS).map { id in
            LANInventoryGrant(playerID: "guest", grantID: id, items: [], xp: 0, clearAll: false,
                              changes: (0..<64).map { _ in randomChange(&random, from: start) })
        }
        var timings: [Double] = []
        for _ in 0..<5 {
            let began = DispatchTime.now().uptimeNanoseconds
            XCTAssertNotNil(lanInventory(snapshot(start), applying: grants))
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
        }
        // A guard against the replay growing with the square of something, not a benchmark: the
        // suite runs beside other work, so the bound is far above what a quiet machine needs.
        let median = timings.sorted()[2]
        XCTAssertLessThan(median, 2_000, "median \(median) ms for 128 × 64 changes on a full inventory")
    }
}
