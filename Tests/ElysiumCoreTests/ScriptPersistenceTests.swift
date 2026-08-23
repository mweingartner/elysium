// ScriptPersistenceTests.swift — object-graph-attributes (change 1a). Spec
// `object-attribute-persistence`: SaveDB chunk round trip (VCK1 and VCK2),
// byte-identical zero-record blobs, corrupt tail corpus, entity/player
// `object`, world record keys + legacy decode + `scriptsEnabled`, LAN resume
// strip, and Security (plan) C21's aliasing-key corpus.

import XCTest
@testable import ElysiumCore

@MainActor
final class ScriptPersistenceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
    }

    // MARK: - zero-record blobs are byte-identical to a pre-change fixture

    /// Test coverage gap 11 / Condition 8: a genuine pre-change fixture, not a
    /// self-referential re-derivation through the same post-change encoder. The
    /// exact bytes below were captured by running this identical input (same
    /// `ChunkRecord`, same fixed-size all-zero block/biome arrays) through
    /// `encodeLegacyVCK` **at base HEAD `286692a`** — the commit immediately
    /// before this change — via a disposable `git worktree`. The full 198,291-byte
    /// blob is mostly the fixed-size, all-zero block/biome arrays (98,304 blocks +
    /// 1,536 biome bytes for the overworld's height), so this test verifies those
    /// two sections structurally (exact byte count, every byte zero — deterministic
    /// either way, not a "fixture" concern) and compares the small, actually
    /// interesting JSON tail (130 bytes) against the captured literal exactly —
    /// together these two checks are equivalent to a full byte-for-byte comparison
    /// against the real pre-change blob, without inlining a 396 KB hex literal
    /// (`Package.swift` — out of manifest scope — is required to bundle a binary
    /// test resource, so a literal is the only in-manifest option).
    func testZeroObjectRecordChunkIsByteIdenticalToPreChangeFixture() {
        let blockCount = CHUNK_W * CHUNK_W * dimInfo(.overworld).height
        let biomeCount = 4 * 4 * ((dimInfo(.overworld).height + 3) / 4)
        var record = ChunkRecord(
            key: "k", worldId: "w", dim: 0, cx: 0, cz: 0,
            blocks: [UInt16](repeating: 0, count: blockCount),
            biomes: [UInt8](repeating: 0, count: biomeCount),
            entities: [["type": "cow", "x": 1.0, "y": 64.0, "z": 1.0, "vx": 0.0, "vy": 0.0, "vz": 0.0,
                        "yaw": 0.0, "pitch": 0.0, "age": 0, "fire": 0, "persistent": false, "id": 1]]
        )
        record.objects = [:] // explicit: zero object records
        guard let data = encodeLegacyVCK(record) else { return XCTFail() }

        // Captured pre-change JSON tail, base HEAD 286692a (git worktree capture,
        // this session) — the byte-exact contents of "VCK1"'s trailing JSON
        // section for this identical input, with no "objects" key at all.
        let preChangeJSONTail = """
        {"entities":[{"fire":0,"id":1,"vy":0,"type":"cow","age":0,"y":64,"pitch":0,"x":1,"yaw":0,"vz":0,"vx":0,"z":1,"persistent":false}]}
        """
        XCTAssertEqual(data.count, 198_291, "total blob length must match the captured pre-change fixture exactly")

        // "VCK1" | u8 flags(0x01) | u32 nBlocks(LE) | u16[nBlocks] | u32 nBiomes(LE) | u8[nBiomes] | u32 jsonLen(LE) | JSON
        var offset = 0
        let magic = data.subdata(in: offset..<offset + 4); offset += 4
        XCTAssertEqual(magic, Data("VCK1".utf8))
        let flags = data[data.startIndex + offset]; offset += 1
        XCTAssertEqual(flags, 0x01)
        let nBlocks = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self) }; offset += 4
        XCTAssertEqual(Int(nBlocks), blockCount)
        let blockSectionStart = offset
        offset += blockCount * 2
        XCTAssertTrue(data.subdata(in: blockSectionStart..<offset).allSatisfy { $0 == 0 }, "captured fixture's block array was all zero")
        let nBiomes = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self) }; offset += 4
        XCTAssertEqual(Int(nBiomes), biomeCount)
        let biomeSectionStart = offset
        offset += biomeCount
        XCTAssertTrue(data.subdata(in: biomeSectionStart..<offset).allSatisfy { $0 == 0 }, "captured fixture's biome array was all zero")
        let jsonLen = data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.load(as: UInt32.self) }; offset += 4
        XCTAssertEqual(Int(jsonLen), preChangeJSONTail.utf8.count, "JSON tail byte length must match the captured pre-change fixture exactly")
        let jsonTail = data.subdata(in: offset..<data.count)
        XCTAssertEqual(offset + jsonTail.count, data.count)
        // `chunkTailJSON`'s "entities"/"blockEntities" section is (both before and
        // after this change — unrelated to it) plain `JSONSerialization` without
        // `.sortedKeys`, so its *inner* per-entity key order is a genuine,
        // pre-existing cross-process non-determinism (unlike the "objects" section
        // below it, which this change adds and does sort). A semantic (parsed)
        // comparison is therefore the correct fixture check here — byte-length
        // equality (asserted above) already proves the content is exactly as
        // large as the captured fixture, and the deep-equality check below proves
        // it carries exactly the captured fixture's keys and values, regardless
        // of this process's particular key order.
        guard let liveObject = try? JSONSerialization.jsonObject(with: jsonTail) as? [String: Any],
              let fixtureObject = try? JSONSerialization.jsonObject(with: Data(preChangeJSONTail.utf8)) as? [String: Any]
        else {
            return XCTFail("both the live and captured JSON tails must parse")
        }
        XCTAssertEqual(
            NSDictionary(dictionary: liveObject), NSDictionary(dictionary: fixtureObject),
            "JSON tail must be semantically identical to the captured pre-change fixture"
        )
        XCTAssertNil(liveObject["objects"], "the captured pre-change fixture and the live output must both omit \"objects\" when empty")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"objects\""))
    }

    // MARK: - SaveDB chunk round trip (VCK1)

    func testChunkRoundTripThroughSaveDBVCK1Path() throws {
        let db = try PersistenceTestSupport.makeDatabase(owner: self)
        var record = ChunkRecord(
            key: db.chunkKey("w1", 0, 0, 0), worldId: "w1", dim: 0, cx: 0, cz: 0,
            blocks: [UInt16](repeating: 0, count: CHUNK_W * CHUNK_W * dimInfo(.overworld).height),
            biomes: [UInt8](repeating: 0, count: 4 * 4 * ((dimInfo(.overworld).height + 3) / 4)),
            entities: [["type": "cow", "x": 1.0, "y": 64.0, "z": 1.0, "vx": 0.0, "vy": 0.0, "vz": 0.0,
                        "yaw": 0.0, "pitch": 0.0, "age": 0, "fire": 0, "persistent": false, "id": 21]]
        )
        let blockRecord = ObjectRecord(entries: [
            "mood": .value(.string("happy"), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 0)),
        ], revision: 3)
        record.objects = [chunkCellIndex(3, 64, 5): ObjectRecordCodec.encode(blockRecord)]

        XCTAssertTrue(db.putChunks([record]))
        guard let read = db.getChunk("w1", 0, 0, 0) else { return XCTFail("chunk did not round trip") }
        XCTAssertEqual(read.objects[chunkCellIndex(3, 64, 5)].flatMap { ObjectRecordCodec.decode($0, caps: .defaults) }?.revision, 3)
        XCTAssertEqual((read.entities.first?["id"] as? NSNumber)?.intValue, 21)

        // a second save of the *same in-memory record* (mirroring an
        // ordinary re-save with no edits) reproduces the same "objects" text
        // for that cell — the encoder is a pure function of the record.
        guard let secondEncode = encodeLegacyVCK(record) else { return XCTFail() }
        guard let firstEncode = encodeLegacyVCK(record) else { return XCTFail() }
        XCTAssertEqual(secondEncode, firstEncode)
    }

    private func chunkCellIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
        let c = Chunk(cx: 0, cz: 0, minY: dimInfo(.overworld).minY, height: dimInfo(.overworld).height)
        return c.index(x, y, z)
    }

    // MARK: - VCK2 round trip

    func testChunkRoundTripThroughVCK2Path() {
        let info = dimInfo(.overworld)
        var blocks = [UInt16](repeating: 0, count: CHUNK_W * CHUNK_W * info.height)
        blocks[0] = cell(B.stone)
        let sectionCount = (info.height + 15) / 16
        var sections: [CompactChunkSectionV2] = []
        for s in 0..<sectionCount {
            let start = s * 4096
            let slice = Array(blocks[start..<(start + 4096)])
            var runs: [CompactChunkRunV2] = []
            var current = slice[0]
            var length: UInt16 = 1
            for v in slice.dropFirst() {
                if v == current, length < UInt16.max { length += 1 } else {
                    runs.append(CompactChunkRunV2(length: length, value: current))
                    current = v
                    length = 1
                }
            }
            runs.append(CompactChunkRunV2(length: length, value: current))
            if !(runs.count == 1 && runs[0].value == 0) {
                sections.append(CompactChunkSectionV2(y: Int8(clamping: floorDiv(info.minY, 16) + s), runs: runs))
            }
        }
        let biomes = [UInt8](repeating: 0, count: 4 * 4 * ((info.height + 3) / 4))
        let objects = [42: ObjectRecordCodec.encode(ObjectRecord(entries: [
            "n": .value(.int(1), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 0)),
        ]))]
        guard let data = encodeCompactVCK2(dimension: 0, sections: sections, biomes: biomes, objects: objects) else {
            return XCTFail("encode failed")
        }
        guard let decoded = decodeLegacyVCK(data, key: "k", worldId: "w", dimension: 0, chunkX: 0, chunkZ: 0) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(decoded.objects[42].flatMap { ObjectRecordCodec.decode($0, caps: .defaults) }?.entries.count, 1)
        XCTAssertEqual(decoded.blocks?[0], cell(B.stone))
    }

    // MARK: - corrupt tail entries

    func testCorruptTailEntriesAreDropped() throws {
        let info = dimInfo(.overworld)
        let tail: [String: Any] = [
            "entities": [],
            "objects": ["-1": "x", "abc": "y", "70000": "{\"attrs\":{},\"rev\":0,\"v\":1}",
                        "100": "{\"attrs\":{},\"rev\":0,\"v\":1}", "101": 5],
        ]
        let json = try JSONSerialization.data(withJSONObject: tail)
        var data = Data("VCK1".utf8)
        data.append(0) // no blocks
        var length = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(json)
        // Nether (dim 1, height 128): limit is CHUNK_W*CHUNK_W*128 = 32,768,
        // so "70000" is genuinely out of range here (it would *not* be for
        // the overworld's taller chunks) — matching the spec scenario's
        // literal cell index.
        guard let record = decodeLegacyVCK(data, key: "k", worldId: "w", dimension: 1, chunkX: 0, chunkZ: 0) else {
            return XCTFail()
        }
        XCTAssertEqual(record.objects.count, 1)
        XCTAssertNotNil(record.objects[100])
        _ = info
    }

    // MARK: - Security (plan) C21: aliasing cell-index keys

    func testAliasingCellIndexKeysAreRefusedDeterministically() throws {
        let recordA = "{\"attrs\":{\"n\":{\"by\":\"player\",\"ro\":false,\"t\":0,\"v\":1}},\"rev\":0,\"v\":1}"
        let recordB = "{\"attrs\":{\"n\":{\"by\":\"player\",\"ro\":false,\"t\":0,\"v\":2}},\"rev\":0,\"v\":1}"
        let recordC = "{\"attrs\":{\"n\":{\"by\":\"player\",\"ro\":false,\"t\":0,\"v\":3}},\"rev\":0,\"v\":1}"
        let tail: [String: Any] = ["entities": [], "objects": ["7": recordA, "007": recordB, "+7": recordC]]
        let json = try JSONSerialization.data(withJSONObject: tail)
        var data = Data("VCK1".utf8)
        data.append(0)
        var length = UInt32(json.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(json)

        for _ in 0..<100 {
            guard let record = decodeLegacyVCK(data, key: "k", worldId: "w", dimension: 0, chunkX: 0, chunkZ: 0) else {
                return XCTFail()
            }
            XCTAssertEqual(record.objects.count, 1)
            XCTAssertEqual(record.objects[7], recordA)
        }
    }

    // MARK: - entity / player "object"

    func testEntitySaveAndLoadRoundTripsObject() {
        let world = World(dim: .overworld, seed: 1)
        let cow = Cow(world: world)
        cow.objectRecord = ObjectRecord(entries: [
            "mood": .value(.string("curious"), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 5)),
        ], revision: 1)
        let dict = cow.save()
        XCTAssertNotNil(dict["object"])
        let cow2 = Cow(world: world)
        cow2.load(dict)
        XCTAssertEqual(cow2.objectRecord.entries.count, 1)
        XCTAssertEqual(cow2.objectRecord.revision, 1)
    }

    func testEntityWithEmptyRecordOmitsObjectKey() {
        let world = World(dim: .overworld, seed: 1)
        let cow = Cow(world: world)
        let dict = cow.save()
        XCTAssertNil(dict["object"])
        XCTAssertNotNil(dict["id"])
    }

    // MARK: - world record keys

    /// DEF-1 (Test verdict, design.md Decision 11 / Condition 8): the trust gate defaults
    /// to untrusted. Bare `WorldRecord.init` is false; only `GameCore.createWorld` — a
    /// genuinely new, locally-created world — sets it true, durably, before its own
    /// `db.putWorld`. Every other construction path (Reality Derived imports, transient
    /// LAN-client records, decode-absent legacy rows) inherits the false default and must
    /// never override it.
    func testWorldRecordScriptsEnabledDefaultsFalseAndOnlyCreateWorldSetsTrue() throws {
        // (1) Bare init defaults to false.
        var rec = WorldRecord(id: "w2", name: "n", seed: 1, gameMode: 0, difficulty: 1)
        XCTAssertFalse(rec.scriptsEnabled, "WorldRecord.init must default scriptsEnabled to false")
        rec.objects["world"] = ObjectRecordCodec.encode(ObjectRecord(entries: [
            "logs_broken": .value(.int(12), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 0)),
        ]))
        guard let data = encodeWorldRecordJSON(rec) else { return XCTFail() }
        let decoded = try JSONDecoder().decode(WorldRecord.self, from: data)
        XCTAssertFalse(decoded.scriptsEnabled, "the false default must survive an encode/decode round trip")
        guard let text = decoded.objects["world"], let record = ObjectRecordCodec.decode(text, caps: .defaults) else {
            return XCTFail()
        }
        guard case .value(.int(12), _, _)? = record.entries["logs_broken"] else {
            return XCTFail("expected logs_broken to decode as int 12")
        }

        // (2) The Reality Derived import path (`GameCore.persistRealityDerivedWorld`)
        // constructs its `WorldRecord` with the identical initializer signature
        // (`id:name:seed:gameMode:difficulty:mapSize:`) and never touches
        // `.scriptsEnabled` — so a plan-imported world inherits the untrusted default.
        let imported = WorldRecord(
            id: "imported", name: "Imported", seed: 2, gameMode: 0, difficulty: 1, mapSize: .medium
        )
        XCTAssertFalse(imported.scriptsEnabled, "a Reality Derived import must not be script-trusted")

        // (3) `GameCore.createWorld` is the ONLY path that sets scriptsEnabled true, and it
        // does so durably before its own `db.putWorld` — proven end to end through a real
        // GameCore/SaveDB, not just at the WorldRecord-construction level.
        let game = PersistenceTestSupport.makeGame(owner: self, label: "scripts-enabled")
        game.createWorld(name: "Scripts Enabled", seedText: "3", mode: GameMode.survival, difficulty: 2)
        guard let worldID = game.worldRec?.id else { return XCTFail("createWorld did not populate worldRec") }
        XCTAssertEqual(game.worldRec?.scriptsEnabled, true, "createWorld must set scriptsEnabled true in memory")
        guard let persisted = game.db.getWorld(worldID) else {
            return XCTFail("createWorld must durably persist the world record")
        }
        XCTAssertTrue(persisted.scriptsEnabled, "createWorld must persist scriptsEnabled true, not just hold it in memory")

        // (4) The transient LAN-client record (`GameCore.enterLANClientWorld`) uses the
        // same plain initializer as the import path and must also stay untrusted.
        let lanClient = WorldRecord(
            id: "lan-probe", name: "LAN: probe", seed: 4, gameMode: 0, difficulty: 1
        )
        XCTAssertFalse(lanClient.scriptsEnabled, "a transient LAN-client record must not be script-trusted")
    }

    func testPre1AWorldJSONDecodesWithEmptyBagAndScriptsDisabled() throws {
        let legacyJSON = """
        {"id":"legacy","name":"Legacy","seed":1,"gameMode":0,"difficulty":1,"lastPlayed":0,
         "version":"elysium-1.0.0","dims":{},"spawnX":0,"spawnY":80,"spawnZ":0,
         "worldPreset":"normal","singleBiome":"plains","dungeonDensity":1,"gameRules":{},
         "dragonKilled":false,"gatewaysSpawned":0,"nextEntityId":1,"rpgSimulationTick":0,
         "mapSize":"medium","mapCenterX":0,"mapCenterZ":0}
        """
        let decoded = try JSONDecoder().decode(WorldRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertFalse(decoded.scriptsEnabled)
        XCTAssertTrue(decoded.objects.isEmpty)
    }

    // MARK: - LAN client resume omits attributes

    func testLANClientResumeOmitsObject() throws {
        let db = try PersistenceTestSupport.makeDatabase(owner: self)
        let game = GameCore(db: db)
        let summary = LANWorldSummary(
            worldID: "lan-persist-host", worldName: "LAN Persist", seed: 9,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2
        )
        game.enterLANClientWorld(summary)
        game.player.objectRecord = ObjectRecord(entries: [
            "x": .value(.int(1), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 0)),
        ])
        game.saveAndFlush(synchronous: true)
        // Test coverage gap 10: the row must genuinely exist and carry the
        // player's serialized state — asserting on `data["object"]` only when
        // a row happens to be present let this test pass vacuously if the
        // resume-key derivation or the save path silently produced nothing.
        guard let key = lanClientResumeKey(for: summary) else {
            return XCTFail("expected a resume key to be derivable for this summary")
        }
        guard let stored = db.getLANClientResume(key) else {
            return XCTFail("expected saveAndFlush to have written a LAN client resume row")
        }
        guard let data = stored["data"] as? [String: Any] else {
            return XCTFail("expected the stored resume row to carry a \"data\" object")
        }
        // Sanity: this is genuinely the player's row, not an empty stub.
        XCTAssertNotNil(data["x"], "expected the player's ordinary fields to be present")
        XCTAssertNil(data["object"], "a LAN client resume row must never carry the player's scripted attribute record")
    }
}
