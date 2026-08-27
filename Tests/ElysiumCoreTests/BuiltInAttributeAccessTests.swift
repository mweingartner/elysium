// BuiltInAttributeAccessTests.swift — object-graph-attributes (change 1a).
// Spec `attribute-registry` "Strict SET with did-you-mean", "Lenient GET",
// "Health SET goes through the funnels", "Ranged integer built-ins refuse
// out-of-range writes before the field changes" (Security (plan) C22), plus
// note A4's `0x`-free `/inspect` output assertion.

import XCTest
@testable import ElysiumCore

final class BuiltInAttributeAccessTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    private func makeWorldAndHost() -> (World, FakeObjectGraphHost) {
        let world = World(dim: .overworld, seed: 5)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        let host = FakeObjectGraphHost()
        host.worldsByDim[.overworld] = world
        return (world, host)
    }

    // MARK: - GET per kind (headless world)

    func testGetBlockFields() {
        let (world, host) = makeWorldAndHost()
        _ = world.setBlock(1, 64, 1, Int(cell(bid("oak_stairs"), 0)))
        let live = LiveObject.block(world: world, chunk: world.getChunk(0, 0)!, cellIndex: world.getChunk(0, 0)!.index(1, 64, 1), x: 1, y: 64, z: 1)
        guard case .value(.string("oak_stairs")) = BuiltInAttributes.get(live, name: "name", host: host) else { return XCTFail() }
        guard case .value(.string("north")) = BuiltInAttributes.get(live, name: "facing", host: host) else { return XCTFail() }
    }

    func testGetEntityAndPlayerFields() {
        let (world, host) = makeWorldAndHost()
        let player = Player(world: world)
        player.setPos(1, 65, 1)
        world.addEntity(player)
        let live = LiveObject.player(player, world)
        guard case .value(.number(let x)) = BuiltInAttributes.get(live, name: "x", host: host) else { return XCTFail() }
        XCTAssertEqual(x, 1, accuracy: 0.0001)
        guard case .value(.int(let hunger)) = BuiltInAttributes.get(live, name: "hunger", host: host) else { return XCTFail() }
        XCTAssertEqual(hunger, 20)
    }

    func testMobOwnerUsesCanonicalPlayerReferenceAndDoesNotExposeDanglingEntityID() {
        let (world, host) = makeWorldAndHost()
        let player = Player(world: world)
        world.addEntity(player)
        let wolf = Wolf(world: world)
        wolf.ownerId = player.id
        world.addEntity(wolf)
        let live = LiveObject.entity(wolf, world)

        guard case .value(.ref(let owner)) = BuiltInAttributes.get(live, name: "owner", host: host)
        else { return XCTFail("expected a canonical owner ref") }
        XCTAssertEqual(owner, ObjectRef.player.canonical)

        world.removeEntity(player)
        guard case .value(.null) = BuiltInAttributes.get(live, name: "owner", host: host)
        else { return XCTFail("an unloaded owner must not become a dangling entity ref") }
    }

    func testGetDimensionAndWorldFields() {
        let (world, host) = makeWorldAndHost()
        world.dayTime = 500
        let liveDim = LiveObject.dimension(world)
        guard case .value(.int(500)) = BuiltInAttributes.get(liveDim, name: "day_time", host: host) else { return XCTFail() }
        let liveWorld = LiveObject.world
        guard case .value(.bool(true)) = BuiltInAttributes.get(liveWorld, name: "scripts_enabled", host: host) else { return XCTFail() }
    }

    // MARK: - strict SET with did-you-mean

    func testStrictSetWithDidYouMean() {
        let (world, host) = makeWorldAndHost()
        _ = world.setBlock(2, 64, 2, Int(cell(bid("oak_stairs"), 0)))
        let live = LiveObject.block(world: world, chunk: world.getChunk(0, 0)!, cellIndex: world.getChunk(0, 0)!.index(2, 64, 2), x: 2, y: 64, z: 2)
        guard case .unknownName(let suggestions) = BuiltInAttributes.set(live, name: "Facing", value: .string("east"), host: host) else {
            return XCTFail("expected unknownName for a wrong-case name")
        }
        XCTAssertEqual(suggestions, ["facing"])
        // block is unchanged
        guard case .value(.string("north")) = BuiltInAttributes.get(live, name: "facing", host: host) else { return XCTFail() }
    }

    // MARK: - lenient GET

    func testLenientGetTargetAndInapplicableOpen() {
        let (world, host) = makeWorldAndHost()
        let cow = Cow(world: world)
        world.addEntity(cow)
        let liveCow = LiveObject.entity(cow, world)
        guard case .value(.null) = BuiltInAttributes.get(liveCow, name: "target", host: host) else { return XCTFail() }

        _ = world.setBlock(3, 64, 3, Int(cell(B.stone)))
        let liveStone = LiveObject.block(world: world, chunk: world.getChunk(0, 0)!, cellIndex: world.getChunk(0, 0)!.index(3, 64, 3), x: 3, y: 64, z: 3)
        guard case .notApplicable = BuiltInAttributes.get(liveStone, name: "open", host: host) else {
            return XCTFail("expected notApplicable for 'open' on stone")
        }
    }

    // MARK: - health SET through the funnels

    func testHealthSetGoesThroughHealAndHurt() {
        let (world, host) = makeWorldAndHost()
        let cow = Cow(world: world)
        cow.health = 10
        cow.maxHealth = 10
        world.addEntity(cow)
        let live = LiveObject.entity(cow, world)

        guard case .ok(.number(let afterHurt)) = BuiltInAttributes.set(live, name: "health", value: .number(3), host: host) else {
            return XCTFail()
        }
        XCTAssertLessThanOrEqual(afterHurt, 3.0001)
        XCTAssertGreaterThan(cow.health, 0) // armor/invuln may adjust the exact result, but it went through hurt()

        guard case .ok(.number(let afterHeal)) = BuiltInAttributes.set(live, name: "health", value: .number(30), host: host) else {
            return XCTFail()
        }
        XCTAssertLessThanOrEqual(afterHeal, cow.maxHealth + 0.0001)
    }

    // MARK: - ranged integer built-ins (Security (plan) C22)

    func testRangedIntegerBuiltinsRefuseOutOfRangeBeforeFieldChanges() {
        let (world, host) = makeWorldAndHost()
        let player = Player(world: world)
        world.addEntity(player)
        let live = LiveObject.player(player, world)

        let before = player.xpLevel
        guard case .outOfRange(let range1) = BuiltInAttributes.set(live, name: "xp_level", value: .int(100_001), host: host) else {
            return XCTFail("expected outOfRange for xp_level 100001")
        }
        XCTAssertEqual(range1, "0...100000")
        XCTAssertEqual(player.xpLevel, before)

        guard case .outOfRange = BuiltInAttributes.set(live, name: "xp_level", value: .int(9_223_372_036_854_775_807), host: host) else {
            return XCTFail("expected outOfRange for xp_level Int.max")
        }
        XCTAssertEqual(player.xpLevel, before)

        guard case .outOfRange(let range2) = BuiltInAttributes.set(live, name: "hunger", value: .int(21), host: host) else {
            return XCTFail("expected outOfRange for hunger 21")
        }
        XCTAssertEqual(range2, "0...20")

        // addXP must not trap after the refused xp_level writes.
        player.addXP(50)
    }

    /// Test coverage gap 12: ranged built-ins beyond `xp_level`/`hunger` also
    /// refuse out-of-range writes before the field changes — `held_slot`
    /// (player, 0...8), `day_time` (dimension, 0...23999), and the block fields
    /// `meta` (0-15), `delay` (repeater, 1-4), `layers` (snow, 1-8), which route
    /// through `BlockStateCodec.write` and surface as `.wrongValueKind` (a
    /// failed codec write carries no separate out-of-range case) rather than
    /// leaving the block unchanged.
    func testAdditionalRangedBuiltinsRefuseOutOfRange() {
        let (world, host) = makeWorldAndHost()

        let player = Player(world: world)
        world.addEntity(player)
        let liveP = LiveObject.player(player, world)
        let beforeSlot = player.selectedSlot
        guard case .outOfRange(let slotRange) = BuiltInAttributes.set(liveP, name: "held_slot", value: .int(9), host: host) else {
            return XCTFail("expected outOfRange for held_slot 9")
        }
        XCTAssertEqual(slotRange, "0...8")
        XCTAssertEqual(player.selectedSlot, beforeSlot)
        guard case .outOfRange = BuiltInAttributes.set(liveP, name: "held_slot", value: .int(-1), host: host) else {
            return XCTFail("expected outOfRange for held_slot -1")
        }
        XCTAssertEqual(player.selectedSlot, beforeSlot)

        let liveDim = LiveObject.dimension(world)
        let beforeDayTime = world.dayTime
        guard case .outOfRange(let dayRange) = BuiltInAttributes.set(liveDim, name: "day_time", value: .int(24_000), host: host) else {
            return XCTFail("expected outOfRange for day_time 24000")
        }
        XCTAssertEqual(dayRange, "0...23999")
        XCTAssertEqual(world.dayTime, beforeDayTime)

        _ = world.setBlock(1, 64, 1, Int(cell(B.stone)))
        let chunk = world.getChunk(0, 0)!
        let liveStone = LiveObject.block(world: world, chunk: chunk, cellIndex: chunk.index(1, 64, 1), x: 1, y: 64, z: 1)
        let beforeStoneCell = world.getBlock(1, 64, 1)
        guard case .wrongValueKind = BuiltInAttributes.set(liveStone, name: "meta", value: .int(16), host: host) else {
            return XCTFail("expected meta 16 to be refused (0-15)")
        }
        XCTAssertEqual(world.getBlock(1, 64, 1), beforeStoneCell)
        guard case .wrongValueKind = BuiltInAttributes.set(liveStone, name: "meta", value: .int(-1), host: host) else {
            return XCTFail("expected meta -1 to be refused")
        }
        XCTAssertEqual(world.getBlock(1, 64, 1), beforeStoneCell)

        _ = world.setBlock(2, 64, 1, Int(cell(B.repeater, 0)))
        let liveRepeater = LiveObject.block(world: world, chunk: chunk, cellIndex: chunk.index(2, 64, 1), x: 2, y: 64, z: 1)
        let beforeRepeaterCell = world.getBlock(2, 64, 1)
        guard case .wrongValueKind = BuiltInAttributes.set(liveRepeater, name: "delay", value: .int(5), host: host) else {
            return XCTFail("expected delay 5 to be refused (1-4)")
        }
        XCTAssertEqual(world.getBlock(2, 64, 1), beforeRepeaterCell)
        guard case .wrongValueKind = BuiltInAttributes.set(liveRepeater, name: "delay", value: .int(0), host: host) else {
            return XCTFail("expected delay 0 to be refused")
        }
        XCTAssertEqual(world.getBlock(2, 64, 1), beforeRepeaterCell)

        _ = world.setBlock(3, 64, 1, Int(cell(B.snow, 0)))
        let liveSnow = LiveObject.block(world: world, chunk: chunk, cellIndex: chunk.index(3, 64, 1), x: 3, y: 64, z: 1)
        let beforeSnowCell = world.getBlock(3, 64, 1)
        guard case .wrongValueKind = BuiltInAttributes.set(liveSnow, name: "layers", value: .int(9), host: host) else {
            return XCTFail("expected layers 9 to be refused (1-8)")
        }
        XCTAssertEqual(world.getBlock(3, 64, 1), beforeSnowCell)
        guard case .wrongValueKind = BuiltInAttributes.set(liveSnow, name: "layers", value: .int(0), host: host) else {
            return XCTFail("expected layers 0 to be refused")
        }
        XCTAssertEqual(world.getBlock(3, 64, 1), beforeSnowCell)
    }

    // MARK: - gamerule / difficulty callbacks

    func testGameruleAndDifficultyGoThroughHostCallbacks() {
        let host = FakeObjectGraphHost()
        host.gameRules["doFireTick"] = 1
        let liveWorld = LiveObject.world
        guard case .ok(.number(0)) = BuiltInAttributes.set(liveWorld, name: "gamerule.doFireTick", value: .number(0), host: FakeGameRuleHost(host: host)) else {
            return XCTFail()
        }
    }

    /// A tiny host wrapper that answers `world(for:)` with a world whose
    /// `gameRules` mirrors the fake's dictionary, so `BuiltInAttributes`'s
    /// "existing rules only" check against a live `World` can be exercised
    /// without constructing a full chunked world here.
    private final class FakeGameRuleHost: ObjectGraphHost {
        let inner: FakeObjectGraphHost
        let world: World
        init(host: FakeObjectGraphHost) {
            inner = host
            world = World(dim: .overworld, seed: 1)
            for (k, v) in host.gameRules { world.gameRules[k] = v }
        }
        var currentDimension: Dim { inner.currentDimension }
        func world(for dim: Dim) -> World? { dim == .overworld ? world : nil }
        var localPlayer: Player? { inner.localPlayer }
        var isLANClient: Bool { inner.isLANClient }
        var currentTick: Int64 { inner.currentTick }
        var scriptsEnabled: Bool { inner.scriptsEnabled }
        func worldObjectRecord(for ref: ObjectRef) -> ObjectRecord { inner.worldObjectRecord(for: ref) }
        func setWorldObjectRecord(_ record: ObjectRecord, for ref: ObjectRef) { inner.setWorldObjectRecord(record, for: ref) }
        func setDifficulty(_ d: Int) { world.difficulty = d }
        func setGameRule(_ name: String, _ value: Double) { world.gameRules[name] = value }
    }

    func testDifficultySet() {
        let host = FakeGameRuleHost(host: FakeObjectGraphHost())
        guard case .ok(.string("hard")) = BuiltInAttributes.set(.world, name: "difficulty", value: .string("hard"), host: host) else {
            return XCTFail()
        }
        XCTAssertEqual(host.world.difficulty, 3)
    }

    // MARK: - note A4: no `0x` (object address) ever appears in /inspect-style output

    func testNoRawAddressInOutputAcrossEveryKind() {
        let (world, host) = makeWorldAndHost()
        _ = world.setBlock(4, 64, 4, Int(cell(bid("furnace_lit"), 2)))
        let cow = Cow(world: world)
        world.addEntity(cow)
        let player = Player(world: world)
        world.addEntity(player)

        let live: [(ObjectKind, LiveObject)] = [
            (.block, .block(world: world, chunk: world.getChunk(0, 0)!, cellIndex: world.getChunk(0, 0)!.index(4, 64, 4), x: 4, y: 64, z: 4)),
            (.entity, .entity(cow, world)),
            (.player, .player(player, world)),
            (.dim, .dimension(world)),
            (.world, .world),
        ]
        for (kind, obj) in live {
            for descriptor in AttributeRegistry.descriptors(for: kind) {
                guard case .value(let v) = BuiltInAttributes.get(obj, name: descriptor.canonical, host: host) else { continue }
                let text = AttrValueCodec.encode(v)
                XCTAssertFalse(text.contains("0x"), "'\(descriptor.canonical)' leaked what looks like a raw address: \(text)")
            }
        }
    }
}
