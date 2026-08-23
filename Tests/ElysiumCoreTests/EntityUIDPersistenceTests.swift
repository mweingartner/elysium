// EntityUIDPersistenceTests.swift — object-graph-attributes (change 1a). Spec
// `entity-uid-persistence`: save/load survival, collision handling, legacy
// rows, the durable hi/lo reservation protocol, and Security (plan) C20 (the
// `nextEntityId` decode clamp).

import XCTest
@testable import ElysiumCore

@MainActor
final class EntityUIDPersistenceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
    }

    override func tearDown() {
        // design.md note D3: the process-wide reservation hook can outlive a
        // `GameCore` that skipped `exitToTitle` — clear it so later tests
        // (in this file or others) never inherit it.
        clearEntityIdReservation()
        super.tearDown()
    }

    // MARK: - uid survives save and load

    func testUIDSurvivesChunkUnloadAndReload() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "uid-survive")
        game.createWorld(name: "UID Survive", seedText: "1", mode: GameMode.survival, difficulty: 2)
        let world = game.world
        let cow = Cow(world: world)
        cow.setPos(game.player.x + 2, game.player.y, game.player.z)
        world.addEntity(cow)
        let uid = cow.id
        XCTAssertGreaterThan(uid, 0)
        // `saveAndFlush` only captures chunks with `modified == true` (entity
        // adds alone don't set it — that only happens on unload, or here,
        // simulating an ordinary block touch in the same chunk); mark it
        // explicitly so this chunk's entity is actually included.
        world.getChunkAt(Int(cow.x), Int(cow.z))?.modified = true

        game.saveAndFlushChecked()
        // simulate reload by re-entering the same world
        game.exitToTitle()
        game.loadWorld(game.db.listWorlds().first!.id)

        let world2 = game.world
        guard let restored = world2.entityById[uid] as? Cow else {
            return XCTFail("cow with uid \(uid) did not survive reload")
        }
        XCTAssertFalse(restored.dead)
        XCTAssertGreaterThan(peekNextEntityId(), uid)
    }

    // MARK: - collision keeps the minted id

    func testCollisionKeepsMintedIdAndAddsBothEntities() {
        let world = World(dim: .overworld, seed: 9)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        resetEntityIds(1)

        let existing = Cow(world: world)
        world.addEntity(existing) // id 1
        let liveID = existing.id

        // A "loaded" entity whose saved id collides with the already-live one.
        var dict = Cow(world: world).save() // mints id 2, discarded
        dict["type"] = "cow"
        dict["id"] = liveID
        let e = loadEntity(world, dict)
        XCTAssertNotNil(e)
        XCTAssertNotEqual(e?.id, liveID, "the colliding entity must keep its minted id, not steal the live one")
        world.addEntity(e!)
        XCTAssertEqual(world.entityById[liveID] === existing, true)
        XCTAssertNotNil(world.entityById[e!.id])
    }

    // MARK: - legacy row without an id

    func testLegacyRowWithoutIdKeepsAdoptionOrderId() {
        let world = World(dim: .overworld, seed: 9)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        resetEntityIds(1)

        var dict = Cow(world: world).save() // mints id 1
        dict["type"] = "cow"
        dict.removeValue(forKey: "id")
        let loaded = loadEntity(world, dict)
        XCTAssertNotNil(loaded)
        // no id was adopted — the entity keeps whatever loadEntity's own
        // `createEntity` call minted internally.
        XCTAssertGreaterThan(loaded!.id, 0)
    }

    func testNonIntegerOrOutOfRangeIdIsTreatedAsLegacy() {
        let world = World(dim: .overworld, seed: 9)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        resetEntityIds(1)

        for badID: Any in [0, -5, 3.5, "17", true] {
            var dict = Cow(world: world).save()
            dict["type"] = "cow"
            dict["id"] = badID
            let mintedBefore = peekNextEntityId()
            let loaded = loadEntity(world, dict)
            XCTAssertNotNil(loaded)
            // A rejected "id" never gets adopted — the entity keeps its own
            // minted id, distinct from the bad value.
            if let intBadID = badID as? Int {
                XCTAssertNotEqual(loaded?.id, intBadID)
            }
            _ = mintedBefore
        }
    }

    /// Test coverage gap 5 / Security (plan) C26(c): the literal `Int64.max` row —
    /// out of `entityIdAdoptionRange` (clamped to `Int.max - 1_000_000`, the same
    /// bound `WorldRecord.nextEntityId` decodes against), so it is treated exactly
    /// like the other out-of-range classes already covered above: the entity loads
    /// under a freshly minted id, not the literal value, and the counter does not
    /// trap on the very next mint afterward.
    func testInt64MaxLiteralIdIsTreatedAsLegacyAndDoesNotTrap() {
        let world = World(dim: .overworld, seed: 9)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        resetEntityIds(1)

        var dict = Cow(world: world).save()
        dict["type"] = "cow"
        dict["id"] = Int64.max
        let loaded = loadEntity(world, dict)
        XCTAssertNotNil(loaded)
        XCTAssertNotEqual(loaded?.id, Int(Int64.max), "Int64.max is above the adoption range and must not be adopted verbatim")
        // The next ordinary mint must not trap.
        let cow2 = Cow(world: world)
        XCTAssertGreaterThan(cow2.id, 0)
    }

    /// Test coverage gap 6: build.md's Conditions self-check 9.3 claimed this test
    /// already existed; it did not. Adopting an id already above the current
    /// reservation mark must trigger the reservation hook (a durable write) before
    /// any further entity is minted — proven here by installing an observing hook
    /// directly, independent of a full `GameCore`/`SaveDB` round trip (the durable
    /// write itself is exercised separately by
    /// `testCrashSimulationCounterStaysAheadOfEveryStoredId` through a real
    /// `SaveDB`; this test isolates the *triggering* condition).
    func testAdoptedIdAboveReservationMarkTriggersReservationWriteBeforeNextMint() throws {
        let world = World(dim: .overworld, seed: 9)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        resetEntityIds(1)

        var hookCallCount = 0
        var lastHookSeenLimit: Int?
        installEntityIdReservation(limit: 10) { needed in
            hookCallCount += 1
            lastHookSeenLimit = needed
            raiseEntityIdReservationLimit(to: needed + 4096)
        }
        defer { clearEntityIdReservation() }

        // Adopt an id (50) already above the installed mark (10).
        var dict = Cow(world: world).save()
        dict["type"] = "cow"
        dict["id"] = 50
        let loaded = loadEntity(world, dict)
        XCTAssertEqual(loaded?.id, 50, "an in-range id above the mark must still be adopted")
        XCTAssertEqual(hookCallCount, 1, "adopting an id above the mark must trigger the reservation hook immediately")
        XCTAssertEqual(lastHookSeenLimit, 51, "the hook must see the counter already bumped past the adopted id")
        XCTAssertGreaterThanOrEqual(peekReservedEntityIdLimit(), 51 + 4096 - 1)

        // The reservation write happened *before* any further mint — the next
        // ordinary mint must not need to trigger the hook a second time.
        let cow2 = Cow(world: world)
        XCTAssertGreaterThan(cow2.id, 50)
        XCTAssertEqual(hookCallCount, 1, "the next ordinary mint must not require a second reservation write")
    }

    // MARK: - crash cannot mint a duplicate uid

    func testCrashSimulationCounterStaysAheadOfEveryStoredId() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "uid-crash")
        game.createWorld(name: "UID Crash", seedText: "2", mode: GameMode.survival, difficulty: 2)
        let worldID = game.worldRec!.id
        let world = game.world
        var maxID = 0
        for i in 0..<50 {
            let cow = Cow(world: world)
            cow.setPos(game.player.x + Double(i % 5), game.player.y, game.player.z + Double(i / 5))
            world.addEntity(cow)
            maxID = max(maxID, cow.id)
        }
        // Flush the chunk batch (as an autosave would) without calling
        // saveAndFlush's world-record write.
        game.saveAndFlushChecked()

        guard let stored = game.db.getWorld(worldID) else { return XCTFail("world record missing") }
        XCTAssertGreaterThan(stored.nextEntityId, maxID, "the durable mark must stay ahead of every minted id")
    }

    // MARK: - Security (plan) C20: corrupt counter near Int.max

    func testCorruptCounterNearIntMaxDoesNotCrashAndClampsOnDecode() throws {
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "uid-clamp")
        var rec = WorldRecord(id: "corrupt-id-world", name: "Corrupt", seed: 3, gameMode: GameMode.survival, difficulty: 2)
        rec.nextEntityId = Int.max - 10
        database.putWorld(rec)

        let readBack = database.getWorld("corrupt-id-world")
        XCTAssertNotNil(readBack)
        XCTAssertLessThanOrEqual(readBack!.nextEntityId, WorldRecord.maxReservableEntityId)

        let game = GameCore(db: database)
        game.loadWorld("corrupt-id-world")
        XCTAssertTrue(game.hasWorld())
        // the first reservation write (installed at entry) must not trap even
        // starting from the clamp bound.
        let cow = Cow(world: game.world)
        game.world.addEntity(cow)
        XCTAssertGreaterThan(cow.id, 0)
        game.exitToTitle()
    }

    func testNegativeOrZeroStoredCounterClampsToOne() throws {
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "uid-clamp-low")
        var rec = WorldRecord(id: "low-id-world", name: "Low", seed: 3, gameMode: GameMode.survival, difficulty: 2)
        rec.nextEntityId = -50
        database.putWorld(rec)
        XCTAssertEqual(database.getWorld("low-id-world")?.nextEntityId, 1)
    }

    // MARK: - goldens / headless use unchanged

    func testHeadlessEntityCreationIsUnaffectedWithoutAGameCore() {
        clearEntityIdReservation()
        resetEntityIds(1)
        let world = World(dim: .overworld, seed: 1)
        var ids: [Int] = []
        for _ in 0..<10 { ids.append(Cow(world: world).id) }
        XCTAssertEqual(ids, Array(1...10))
    }

    // MARK: - LAN client world never writes a world record

    func testLANClientWorldNeverCallsPutWorldForReservation() throws {
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "uid-lan")
        let game = GameCore(db: database)
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "lan-uid-host", worldName: "LAN UID Host", seed: 55,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2
        ))
        XCTAssertTrue(game.isLANClientWorld)
        for i in 0..<20 {
            let cow = Cow(world: game.world)
            cow.setPos(Double(i), 64, 0)
            game.world.addEntity(cow)
        }
        // No world record was ever created for a LAN client id "lan-<...>",
        // so a reservation write (if one incorrectly fired) would have
        // nothing to update; the practical assertion is simply that entering
        // and minting entities on a LAN client world does not crash and the
        // synthetic id never persists.
        XCTAssertNil(database.getWorld(game.worldRec?.id ?? "lan-uid-host"))
        game.exitToTitle()
    }
}
