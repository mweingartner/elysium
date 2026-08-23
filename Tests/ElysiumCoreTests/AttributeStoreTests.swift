// AttributeStoreTests.swift — object-graph-attributes (change 1a). Spec
// `object-attribute-store` "AttributeStore is the single executor": lifecycle,
// readonly/force, caps, built-in collision, revision, onChange, sorted list,
// plus Security (plan) C27 (LAN-client refusal at the store level).

import XCTest
@testable import ElysiumCore

final class AttributeStoreTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
    }

    private func makeStore(isLANClient: Bool = false) -> (FakeObjectGraphHost, AttributeStore) {
        let host = FakeObjectGraphHost()
        host.isLANClient = isLANClient
        let world = World(dim: .overworld, seed: 3)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        host.worldsByDim[.overworld] = world
        let store = AttributeStore(graph: ObjectGraph(host: host))
        return (host, store)
    }

    private let blockRef = ObjectRef.block(dim: .overworld, x: 3, y: 64, z: 5)

    // MARK: - lifecycle (spec "Set, define, readonly, remove")

    func testSetDefineReadonlyRemoveLifecycle() {
        let (_, store) = makeStore()
        _ = store.graph.host.world(for: .overworld)?.setBlock(3, 64, 5, Int(cell(B.chest)))

        guard case .success(.string("happy")) = store.set(blockRef, "mood", .string("happy")) else {
            return XCTFail("expected set to succeed")
        }
        XCTAssertEqual(store.record(blockRef)?.revision, 1)

        guard case .success = store.define(blockRef, "owner", .ref("player"), readonly: true) else {
            return XCTFail("expected define to succeed")
        }
        XCTAssertEqual(store.record(blockRef)?.revision, 2)

        guard case .failure(.readonly) = store.set(blockRef, "owner", .string("x")) else {
            return XCTFail("expected readonly refusal")
        }

        guard case .failure(.readonly) = store.remove(blockRef, "owner") else {
            return XCTFail("expected readonly refusal on remove")
        }

        guard case .success(let removed) = store.remove(blockRef, "owner", force: true) else {
            return XCTFail("expected forced remove to succeed")
        }
        XCTAssertTrue(removed.existed)
        XCTAssertTrue(removed.forced)
        XCTAssertEqual(store.record(blockRef)?.revision, 3)
    }

    // MARK: - caps

    func testTooManyEntries() {
        let (_, store) = makeStore()
        _ = store.graph.host.world(for: .overworld)?.setBlock(3, 64, 5, Int(cell(B.chest)))
        for i in 0..<64 {
            guard case .success = store.set(blockRef, "n\(i)", .int(Int64(i))) else {
                return XCTFail("expected entry \(i) to succeed")
            }
        }
        guard case .failure(.tooManyEntries(let limit)) = store.set(blockRef, "one_too_many", .int(0)) else {
            return XCTFail("expected tooManyEntries")
        }
        XCTAssertEqual(limit, 64)
        XCTAssertEqual(store.record(blockRef)?.entries.count, 64)
    }

    func testValueTooLargeCap() {
        let (_, store) = makeStore()
        _ = store.graph.host.world(for: .overworld)?.setBlock(3, 64, 5, Int(cell(B.chest)))
        let big = String(repeating: "x", count: 4_097)
        guard case .failure(.invalidValue) = store.set(blockRef, "n", .string(big)) else {
            return XCTFail("expected invalidValue for an over-cap string")
        }
    }

    func testRecordTextTooLargeCap() {
        let (_, store) = makeStore()
        _ = store.graph.host.world(for: .overworld)?.setBlock(3, 64, 5, Int(cell(B.chest)))
        var lastResult: Result<AttrValue, AttributeError> = .success(.null)
        for i in 0..<20 {
            lastResult = store.set(blockRef, "n\(i)", .string(String(repeating: "y", count: 4_000)))
        }
        // 20 * ~4000B entries should exceed the 65,536 B per-object cap well
        // before 20 entries land.
        if case .failure(.recordTooLarge) = lastResult { return }
        // Depending on exact overhead this may need fewer entries; assert the
        // cap is reachable rather than pin an exact iteration count.
        var reached = false
        for i in 20..<64 {
            if case .failure(.recordTooLarge) = store.set(blockRef, "m\(i)", .string(String(repeating: "y", count: 4_000))) {
                reached = true
                break
            }
        }
        XCTAssertTrue(reached, "expected recordTooLarge to be reachable within the 64-entry cap")
    }

    // MARK: - coverage gap 8: per-chunk 1 MiB cap (.chunkTooLarge)

    /// `AttributeStore.swift`'s `chunkTooLarge` branch sums every *other* block
    /// record already in the chunk against the candidate's own text — seed a
    /// sibling cell directly (bypassing `store.set`, so this test controls the
    /// exact byte count rather than depending on `recordTooLarge` firing first)
    /// and confirm a small, otherwise-fine candidate is refused once the sum
    /// crosses a deliberately tiny per-chunk cap.
    func testChunkTooLargeCapAcrossMultipleBlocksInSameChunk() {
        let host = FakeObjectGraphHost()
        let world = World(dim: .overworld, seed: 3)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        host.worldsByDim[.overworld] = world
        var caps = ScriptingStorageCaps.defaults
        caps.maxChunkObjectBytes = 100 // trivially small; maxRecordTextBytes stays default
        let store = AttributeStore(graph: ObjectGraph(host: host), caps: caps)

        _ = world.setBlock(1, 64, 1, Int(cell(B.chest)))
        _ = world.setBlock(2, 64, 1, Int(cell(B.chest)))
        let siblingIndex = chunk.index(1, 64, 1)
        chunk.objectRecords[siblingIndex] = ObjectRecord(entries: [
            "mood": .value(.string(String(repeating: "x", count: 150)), readonly: false,
                          provenance: Provenance(createdBy: .player, createdTick: 0)),
        ])
        XCTAssertGreaterThan(ObjectRecordCodec.encode(chunk.objectRecords[siblingIndex]!).utf8.count, caps.maxChunkObjectBytes,
                              "test setup sanity: the seeded sibling record alone must already exceed the tiny cap")

        let refB = ObjectRef.block(dim: .overworld, x: 2, y: 64, z: 1)
        guard case .failure(.chunkTooLarge) = store.set(refB, "mood", .string("hi")) else {
            return XCTFail("expected chunkTooLarge when the chunk's summed record bytes exceed the cap")
        }
    }

    // MARK: - built-in collision (spec "Built-in names are protected")

    func testBuiltInNamesAreProtected() {
        let (host, store) = makeStore()
        let world = host.worldsByDim[.overworld]!
        let cow = Cow(world: world)
        world.addEntity(cow)
        let ref = ObjectRef.entity(uid: cow.id)
        guard case .failure(.nameIsBuiltIn) = store.set(ref, "health", .number(5)) else {
            return XCTFail("expected nameIsBuiltIn for 'health'")
        }
        _ = world.setBlock(3, 64, 5, Int(cell(B.stone)))
        guard case .failure(.nameIsBuiltIn) = store.set(blockRef, "facing", .string("north")) else {
            return XCTFail("expected nameIsBuiltIn for 'facing'")
        }
    }

    // MARK: - revision and onChange

    func testRevisionBumpsAndOnChangeFires() {
        var (host, store) = makeStore()
        _ = host.worldsByDim[.overworld]?.setBlock(3, 64, 5, Int(cell(B.chest)))
        var changes: [(ObjectRef, String, AttrValue?, AttrValue?, UInt64)] = []
        store.onChange = { ref, name, old, new, rev in changes.append((ref, name, old, new, rev)) }
        _ = store.set(blockRef, "a", .int(1))
        _ = store.set(blockRef, "a", .int(2))
        _ = store.remove(blockRef, "a")
        XCTAssertEqual(changes.count, 3)
        XCTAssertNil(changes[0].2) // no old value on first set
        XCTAssertEqual(changes[0].3, .int(1))
        XCTAssertEqual(changes[1].2, .int(1))
        XCTAssertEqual(changes[1].3, .int(2))
        XCTAssertEqual(changes[2].2, .int(2))
        XCTAssertNil(changes[2].3) // no new value on remove
        XCTAssertEqual(changes.map(\.4), [1, 2, 3])
    }

    // MARK: - sorted list

    func testListIsSortedByName() {
        let (_, store) = makeStore()
        _ = store.graph.host.world(for: .overworld)?.setBlock(3, 64, 5, Int(cell(B.chest)))
        _ = store.set(blockRef, "zeta", .int(1))
        _ = store.set(blockRef, "alpha", .int(2))
        _ = store.set(blockRef, "mid", .int(3))
        XCTAssertEqual(store.list(blockRef).map(\.name), ["alpha", "mid", "zeta"])
    }

    // MARK: - world/dim caps

    func testWorldBagUsesSmallerCap() {
        let (_, store) = makeStore()
        var lastResult: Result<AttrValue, AttributeError> = .success(.null)
        for i in 0..<10 {
            lastResult = store.set(.world, "n\(i)", .string(String(repeating: "z", count: 2_000)))
        }
        if case .failure(.recordTooLarge) = lastResult { return }
        XCTFail("expected the smaller 16 KiB world/dim cap to trip within 10 entries of 2 KiB each")
    }

    // MARK: - Security (plan) C27: LAN client refusal

    func testLANClientRefusesEverySetDefineRemove() {
        let (host, store) = makeStore(isLANClient: true)
        _ = host.worldsByDim[.overworld]?.setBlock(3, 64, 5, Int(cell(B.chest)))
        guard case .failure(.lanClient) = store.set(blockRef, "a", .int(1)) else { return XCTFail() }
        guard case .failure(.lanClient) = store.define(blockRef, "a", .int(1), readonly: false) else { return XCTFail() }
        guard case .failure(.lanClient) = store.remove(blockRef, "a") else { return XCTFail() }
    }

    // MARK: - not-live refusals

    func testObjectNotLiveRefusal() {
        let (_, store) = makeStore()
        guard case .failure(.objectNotLive) = store.set(.block(dim: .overworld, x: 100_000, y: 64, z: 0), "a", .int(1)) else {
            return XCTFail()
        }
    }
}
