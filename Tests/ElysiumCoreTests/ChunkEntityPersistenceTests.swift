// ChunkEntityPersistenceTests.swift — entity changes in loaded chunks must
// survive exit and autosave even when no block in the chunk was edited, an
// entity crossing a chunk border must be persisted exactly once, and a chunk
// reloaded before its unload record reaches the database must adopt that
// newer record. These are the save-side causes of dinosaurs vanishing (or
// duplicating) on prehistoric maps.

import XCTest
@testable import ElysiumCore

@MainActor
final class ChunkEntityPersistenceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
    }

    override func tearDown() {
        clearEntityIdReservation()
        super.tearDown()
    }

    // MARK: - fixtures

    private func makePrehistoricGame(_ label: String) -> (GameCore, String) {
        let game = PersistenceTestSupport.makeGame(owner: self, label: label)
        game.createWorld(name: label, seedText: "7", mode: GameMode.survival, difficulty: 2,
                         worldPreset: .prehistoricLostWorldV3)
        return (game, game.db.listWorlds().first?.id ?? "")
    }

    private func playerChunk(_ game: GameCore) -> (cx: Int, cz: Int) {
        (floorDiv(ifloor(game.player.x), 16), floorDiv(ifloor(game.player.z), 16))
    }

    /// Centre of chunk (cx, cz) at the player's height; the entities in these
    /// tests never tick, so their saved positions are exact.
    private func centre(_ game: GameCore, _ cx: Int, _ cz: Int) -> (x: Double, y: Double, z: Double) {
        (Double(cx * 16) + 8.5, game.player.y, Double(cz * 16) + 8.5)
    }

    private func spawnDryosaurus(_ game: GameCore, at p: (x: Double, y: Double, z: Double)) throws -> PrehistoricCreature {
        try XCTUnwrap(spawnMob(game.world, "prehistoric.dryosaurus", p.x, p.y, p.z) as? PrehistoricCreature)
    }

    private func dryosaurs(_ world: World, at p: (x: Double, y: Double, z: Double)) -> [Entity] {
        world.entities.compactMap { $0 as? Entity }.filter {
            $0.type == "prehistoric.dryosaurus" && $0.x == p.x && $0.z == p.z
        }
    }

    private func markEveryChunkSaved(_ game: GameCore) {
        for world in [game.world] { for chunk in world.chunks.values { chunk.modified = false } }
    }

    // MARK: - exit capture

    func testDinosaurInAnUnmodifiedChunkSurvivesExitAndReload() throws {
        let (game, worldID) = makePrehistoricGame("dino-exit")
        let (pcx, pcz) = playerChunk(game)
        let site = centre(game, pcx + 1, pcz)
        let dinosaur = try spawnDryosaurus(game, at: site)
        let uid = dinosaur.id
        // The state after an ordinary autosave: no block edit pending anywhere.
        markEveryChunkSaved(game)

        game.exitToTitle()
        game.loadWorld(worldID)

        let restored = try XCTUnwrap(game.world.entityById[uid] as? PrehistoricCreature,
                                     "a dinosaur standing in a never-edited chunk was lost on exit")
        XCTAssertEqual(restored.type, "prehistoric.dryosaurus")
        XCTAssertEqual(restored.x, site.x)
        XCTAssertEqual(dryosaurs(game.world, at: site).count, 1)
    }

    func testDinosaurLeavingARewrittenChunkIsNotLost() throws {
        let (game, worldID) = makePrehistoricGame("dino-migrate-lost")
        let (pcx, pcz) = playerChunk(game)
        let from = centre(game, pcx, pcz), to = centre(game, pcx + 1, pcz)
        let dinosaur = try spawnDryosaurus(game, at: from)
        let uid = dinosaur.id
        game.world.getChunk(pcx, pcz)?.modified = true
        XCTAssertTrue(game.saveAndFlushChecked())

        // It walks into the neighbouring chunk, and a block is then edited in
        // the chunk it left: that chunk is rewritten without it.
        dinosaur.setPos(to.x, to.y, to.z)
        game.world.getChunk(pcx, pcz)?.modified = true
        game.exitToTitle()
        game.loadWorld(worldID)

        XCTAssertNotNil(game.world.entityById[uid] as? PrehistoricCreature, "the migrant was lost")
        XCTAssertEqual(dryosaurs(game.world, at: to).count, 1)
        XCTAssertEqual(dryosaurs(game.world, at: from).count, 0)
    }

    func testDinosaurLeavingAStaleRecordIsNotDuplicated() throws {
        let (game, worldID) = makePrehistoricGame("dino-migrate-dup")
        let (pcx, pcz) = playerChunk(game)
        let from = centre(game, pcx + 1, pcz), to = centre(game, pcx, pcz)
        let dinosaur = try spawnDryosaurus(game, at: from)
        let uid = dinosaur.id
        game.world.getChunk(pcx + 1, pcz)?.modified = true
        XCTAssertTrue(game.saveAndFlushChecked())

        // It moves into a chunk that is then edited; the chunk it left still
        // holds a record containing it.
        dinosaur.setPos(to.x, to.y, to.z)
        game.world.getChunk(pcx, pcz)?.modified = true
        game.exitToTitle()
        game.loadWorld(worldID)

        XCTAssertNotNil(game.world.entityById[uid] as? PrehistoricCreature)
        XCTAssertEqual(dryosaurs(game.world, at: to).count, 1)
        XCTAssertEqual(dryosaurs(game.world, at: from).count, 0, "the stale record resurrected a duplicate")
    }

    func testDeathInAnUnmodifiedChunkIsPersistedOnExit() throws {
        let (game, worldID) = makePrehistoricGame("dino-death")
        let (pcx, pcz) = playerChunk(game)
        let site = centre(game, pcx, pcz + 1)
        let dinosaur = try spawnDryosaurus(game, at: site)
        game.world.getChunk(pcx, pcz + 1)?.modified = true
        XCTAssertTrue(game.saveAndFlushChecked())

        game.world.removeEntity(dinosaur)
        markEveryChunkSaved(game)
        game.exitToTitle()
        game.loadWorld(worldID)

        XCTAssertEqual(dryosaurs(game.world, at: site).count, 0, "a dead dinosaur came back from its old record")
    }

    // MARK: - autosave

    func testAutosaveWritesOnlyChunksWhoseEntitySetChangedAsEntityOnlyRecords() throws {
        let (game, worldID) = makePrehistoricGame("autosave-membership")
        let (pcx, pcz) = playerChunk(game)
        markEveryChunkSaved(game)
        // Settle anything already pending (e.g. a worldgen pack member placed
        // across a chunk border), then measure one entity change in isolation.
        game.saveAndFlush(synchronous: true)
        let keysBefore = game.db.getChunkKeys(worldID)
        XCTAssertFalse(keysBefore.contains(game.db.chunkKey(worldID, Dim.overworld.rawValue, pcx, pcz - 1)))
        let site = centre(game, pcx, pcz - 1)
        let dinosaur = try spawnDryosaurus(game, at: site)

        game.saveAndFlush(synchronous: true)

        let changedKey = game.db.chunkKey(worldID, Dim.overworld.rawValue, pcx, pcz - 1)
        XCTAssertEqual(game.db.getChunkKeys(worldID).subtracting(keysBefore), [changedKey],
                       "only the chunk whose entity set changed is written")
        let record = try XCTUnwrap(game.db.getChunk(worldID, Dim.overworld.rawValue, pcx, pcz - 1))
        XCTAssertNil(record.blocks, "a never-edited chunk is saved as a cheap entity-only record")
        XCTAssertTrue(record.entities.contains { ($0["id"] as? NSNumber)?.intValue == dinosaur.id })
        XCTAssertEqual(game._testPersistedEntityIDs(.overworld, cx: pcx, cz: pcz - 1)?.contains(dinosaur.id), true)

        // Nothing changed since: the next autosave writes nothing new.
        let keysAfterFirst = game.db.getChunkKeys(worldID)
        game.saveAndFlush(synchronous: true)
        XCTAssertEqual(game.db.getChunkKeys(worldID), keysAfterFirst)
    }

    /// A chunk with a committed, fully-saved block edit that later only gains
    /// an entity (no further block edit) must still rewrite as a FULL record,
    /// not the cheap entity-only shape: `chunkRecord` must keep taking the
    /// full path once `savedFullKeys` remembers this chunk, even though
    /// `c.modified` is false on the membership-only pass.
    func testEntityOnlyMembershipChangeDoesNotDropAnEarlierBlockEdit() throws {
        let (game, worldID) = makePrehistoricGame("blocks-survive-entity-only")
        let (pcx, pcz) = playerChunk(game)
        let (cx, cz) = (pcx + 1, pcz)
        let site = centre(game, cx, cz)
        let editX = Int(site.x), editY = Int(site.y), editZ = Int(site.z)
        XCTAssertNotEqual(game.world.getBlockId(editX, editY, editZ), Int(B.gold_block))
        _ = game.world.setBlock(editX, editY, editZ, Int(cell(B.gold_block)))
        XCTAssertTrue(game.saveAndFlushChecked())
        let fullRecord = try XCTUnwrap(game.db.getChunk(worldID, Dim.overworld.rawValue, cx, cz))
        XCTAssertNotNil(fullRecord.blocks, "the block edit must have produced a full record")

        // Only gain an entity afterwards, with no further block edit — the
        // ordinary cheap autosave path (`.changed` scope).
        let dinosaur = try spawnDryosaurus(game, at: site)
        game.saveAndFlush(synchronous: true)

        let record = try XCTUnwrap(game.db.getChunk(worldID, Dim.overworld.rawValue, cx, cz))
        XCTAssertNotNil(record.blocks,
                        "an entity-only membership change must not drop the chunk's earlier block edit")
        XCTAssertTrue(record.entities.contains { ($0["id"] as? NSNumber)?.intValue == dinosaur.id })

        game.exitToTitle()
        game.loadWorld(worldID)
        XCTAssertEqual(game.world.getBlockId(editX, editY, editZ), Int(B.gold_block),
                       "the earlier block edit must survive an entity-only autosave and a reload")
        XCTAssertNotNil(game.world.entityById[dinosaur.id] as? PrehistoricCreature)
    }

    func testAdoptionRemembersTheEntitiesAReloadWouldReproduce() throws {
        let (game, worldID) = makePrehistoricGame("adoption-membership")
        let (pcx, pcz) = playerChunk(game)
        let dinosaur = try spawnDryosaurus(game, at: centre(game, pcx - 1, pcz))
        XCTAssertTrue(game.saveAndFlushChecked())
        game.exitToTitle()
        game.loadWorld(worldID)
        XCTAssertEqual(game._testPersistedEntityIDs(.overworld, cx: pcx - 1, cz: pcz)?.contains(dinosaur.id), true)
    }

    // MARK: - reload race

    func testRecordAwaitingCommitIsPreferredPendingFirst() {
        let (game, worldID) = makePrehistoricGame("awaiting-commit-order")
        let key = game.db.chunkKey(worldID, Dim.overworld.rawValue, 400, 400)
        XCTAssertNil(game.chunkRecordAwaitingCommit(key))
        let inFlight = ChunkRecord(key: key, worldId: worldID, dim: 0, cx: 400, cz: 400,
                                   entities: [["type": "cow"], ["type": "cow"]])
        game._testMarkChunkRecordInFlight(inFlight)
        XCTAssertEqual(game.chunkRecordAwaitingCommit(key)?.entities.count, 2,
                       "an uncommitted hand-off wins over the database")
        let pending = ChunkRecord(key: key, worldId: worldID, dim: 0, cx: 400, cz: 400,
                                  entities: [["type": "cow"]])
        game._testBufferChunkRecord(pending)
        XCTAssertEqual(game.chunkRecordAwaitingCommit(key)?.entities.count, 1,
                       "a buffered unload record is the newest of all")
    }

    func testChunkReloadedBeforeItsUnloadRecordIsWrittenKeepsItsDinosaur() throws {
        let (game, worldID) = makePrehistoricGame("reload-pending")
        let (pcx, pcz) = playerChunk(game)
        let (cx, cz) = (pcx + 1, pcz + 1)
        let site = centre(game, cx, cz)
        let uid = try spawnDryosaurus(game, at: site).id

        game._testUnloadChunk(.overworld, cx: cx, cz: cz)
        XCTAssertNil(game.world.entityById[uid])
        XCTAssertNil(game.db.getChunk(worldID, Dim.overworld.rawValue, cx, cz),
                     "the unload record is still only buffered")
        game._testEnsureChunkLoaded(.overworld, cx: cx, cz: cz)

        XCTAssertNotNil(game.world.entityById[uid] as? PrehistoricCreature,
                        "a reload inside the write window rebuilt the chunk without its dinosaur")
        XCTAssertEqual(dryosaurs(game.world, at: site).count, 1)
    }

    func testChunkReloadedWhileItsRecordIsStillBeingWrittenKeepsItsDinosaur() throws {
        let (game, worldID) = makePrehistoricGame("reload-in-flight")
        let (pcx, pcz) = playerChunk(game)
        let (cx, cz) = (pcx - 1, pcz + 1)
        let site = centre(game, cx, cz)
        let uid = try spawnDryosaurus(game, at: site).id

        game._testUnloadChunk(.overworld, cx: cx, cz: cz)
        let gate = game._testHoldSaveQueue()
        defer { gate.signal() }
        // Hands the buffered unload record to the (parked) save queue.
        game.saveAndFlush()
        let key = game.db.chunkKey(worldID, Dim.overworld.rawValue, cx, cz)
        XCTAssertNotNil(game.chunkRecordAwaitingCommit(key))
        XCTAssertNil(game.db.getChunk(worldID, Dim.overworld.rawValue, cx, cz), "not committed yet")
        game._testEnsureChunkLoaded(.overworld, cx: cx, cz: cz)

        XCTAssertNotNil(game.world.entityById[uid] as? PrehistoricCreature)
        XCTAssertEqual(dryosaurs(game.world, at: site).count, 1)
    }

    /// A failing write's async recovery must never requeue its own stale
    /// record when a strictly newer hand-off already owns the same key: the
    /// `(inFlightChunkSaves[r.key]?.sequence ?? sequence) <= sequence` guard
    /// in `writeChunkBatch`'s failure path exists exactly for this race. The
    /// failure itself is forced deterministically (an out-of-`Int32`-range
    /// coordinate that `db.putChunks` always rejects), never a real storage
    /// fault.
    func testFailedWriteDoesNotRequeueAStaleRecordOverANewerInFlightHandoff() {
        let (game, worldID) = makePrehistoricGame("failed-write-race")
        // Settle anything already pending before isolating the race.
        game.saveAndFlush(synchronous: true)

        let key = game.db.chunkKey(worldID, Dim.overworld.rawValue, 500, 500)
        let badRecord = ChunkRecord(key: key, worldId: worldID, dim: Dim.overworld.rawValue,
                                    cx: 500, cz: Int(Int32.max) + 1, entities: [["type": "cow"]])
        game._testBufferChunkRecord(badRecord)
        let gate = game._testHoldSaveQueue()
        game.saveAndFlush() // hands badRecord off at sequence S1, parked behind the gate

        // A newer, valid unload record for the very same key arrives while
        // the failing batch is still parked on the save queue.
        let newRecord = ChunkRecord(key: key, worldId: worldID, dim: Dim.overworld.rawValue,
                                    cx: 500, cz: 500, entities: [["type": "pig"]])
        game._testMarkChunkRecordInFlight(newRecord) // sequence S2 > S1

        gate.signal()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertEqual(game.chunkRecordAwaitingCommit(key)?.entities.first?["type"] as? String, "pig",
                       "a failed write's requeue must not clobber a strictly newer in-flight hand-off")
    }

    // MARK: - dimension isolation

    /// The same (cx, cz) coordinates in two different dimensions must never
    /// share persisted-membership bookkeeping: `persistedChunkEntityIDs` is
    /// keyed by `DimChunk`, which folds in the dimension's raw value.
    func testDimensionsKeepIndependentPersistedEntityMembership() throws {
        let (game, _) = makePrehistoricGame("dimension-isolation")
        let overworld = try XCTUnwrap(game.worlds[.overworld])
        let nether = try XCTUnwrap(game.worlds[.nether])
        let (cx, cz) = (40, 40)
        game._testEnsureChunkLoaded(.overworld, cx: cx, cz: cz)
        game._testEnsureChunkLoaded(.nether, cx: cx, cz: cz)
        XCTAssertNotNil(overworld.getChunk(cx, cz))
        XCTAssertNotNil(nether.getChunk(cx, cz))

        let site = (x: Double(cx * 16) + 8.5, z: Double(cz * 16) + 8.5)
        let dinosaur = try XCTUnwrap(
            spawnMob(overworld, "prehistoric.dryosaurus", site.x, 64, site.z) as? PrehistoricCreature)
        // A real unload+reload cycle is what actually recomputes persisted
        // membership for the overworld chunk (`recordAdoptedEntityMembership`).
        game._testUnloadChunk(.overworld, cx: cx, cz: cz)
        game._testEnsureChunkLoaded(.overworld, cx: cx, cz: cz)

        XCTAssertEqual(game._testPersistedEntityIDs(.overworld, cx: cx, cz: cz)?.contains(dinosaur.id), true)
        // The Nether chunk at the identical coordinates was also freshly
        // loaded (so it too gets an entry — an empty one, from its own zero
        // adopted entities), but it must never contain the overworld's dinosaur.
        XCTAssertEqual(game._testPersistedEntityIDs(.nether, cx: cx, cz: cz) ?? [], [],
                       "identical (cx,cz) coordinates in a different dimension must not share membership state")
        XCTAssertTrue(nether.entities.isEmpty, "nothing leaked into the Nether's identical chunk coordinates")
    }
}
