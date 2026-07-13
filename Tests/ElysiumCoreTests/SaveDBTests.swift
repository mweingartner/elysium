import XCTest
@testable import ElysiumCore

final class SaveDBTests: XCTestCase {
    private func makeDB() throws -> SaveDB {
        try PersistenceTestSupport.makeDatabase(owner: self, label: "save-db")
    }

    private func registerBlocksIfNeeded() {
        if blockDefs.isEmpty { registerAllBlocks() }
    }

    private func runSQLite(_ databaseURL: URL, _ sql: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, sql]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let diagnostics = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, diagnostics)
    }

    private func chunkBlob(flags: UInt8, blocks: [UInt16]? = nil, biomes: [UInt8]? = nil,
                           entities: [[String: Any]] = []) -> Data {
        var data = Data("VCK1".utf8)
        data.append(flags)
        func putU32(_ v: Int) {
            var le = UInt32(v).littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        if let blocks {
            putU32(blocks.count)
            for b in blocks {
                var le = b.littleEndian
                withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
            }
        }
        if let biomes {
            putU32(biomes.count)
            data.append(contentsOf: biomes)
        }
        let tail = try! JSONSerialization.data(withJSONObject: ["entities": entities])
        putU32(tail.count)
        data.append(tail)
        return data
    }

    func testFullChunkRoundTripsThroughSQLite() throws {
        registerBlocksIfNeeded()
        let db = try makeDB()
        let info = dimInfo(.overworld)
        let blocks = [UInt16](repeating: cell(B.stone), count: CHUNK_W * CHUNK_W * info.height)
        let biomes = [UInt8](repeating: 1, count: 4 * 4 * ((info.height + 3) / 4))
        let rec = ChunkRecord(
            key: db.chunkKey("world", Dim.overworld.rawValue, 0, 0),
            worldId: "world", dim: Dim.overworld.rawValue, cx: 0, cz: 0,
            blocks: blocks, biomes: biomes, blockEntities: [], entities: [["type": "cow", "x": 1.0]]
        )

        XCTAssertTrue(db.putChunks([rec]))
        let got = db.getChunk("world", Dim.overworld.rawValue, 0, 0)
        XCTAssertEqual(got?.blocks?.count, blocks.count)
        XCTAssertEqual(got?.biomes?.count, biomes.count)
        XCTAssertEqual(got?.blocks?.first, cell(B.stone))
        XCTAssertEqual(got?.entities.count, 1)
    }

    func testEntityOnlyChunkDecodesWithoutBlockArrays() throws {
        let db = try makeDB()
        let blob = chunkBlob(flags: 0, entities: [["type": "item", "count": 1]])
        let got = db.decodeChunk(blob, key: "k", worldId: "world", dim: Dim.overworld.rawValue, cx: 0, cz: 0)

        XCTAssertNil(got?.blocks)
        XCTAssertNil(got?.biomes)
        XCTAssertEqual(got?.entities.count, 1)
    }

    func testMalformedChunkDimensionsAreRejectedBeforeAllocationUse() throws {
        registerBlocksIfNeeded()
        let db = try makeDB()
        let blob = chunkBlob(flags: 1, blocks: [0], biomes: [0])
        let got = db.decodeChunk(blob, key: "k", worldId: "world", dim: Dim.overworld.rawValue, cx: 0, cz: 0)

        XCTAssertNil(got)
    }

    func testCorruptBlockIdsAreClampedToAir() throws {
        registerBlocksIfNeeded()
        let db = try makeDB()
        let info = dimInfo(.overworld)
        var blocks = [UInt16](repeating: cell(B.stone), count: CHUNK_W * CHUNK_W * info.height)
        blocks[0] = UInt16.max
        let biomes = [UInt8](repeating: 0, count: 4 * 4 * ((info.height + 3) / 4))
        let blob = chunkBlob(flags: 1, blocks: blocks, biomes: biomes)
        let got = db.decodeChunk(blob, key: "k", worldId: "world", dim: Dim.overworld.rawValue, cx: 0, cz: 0)

        XCTAssertEqual(got?.blocks?.first, 0)
        XCTAssertEqual(got?.blocks?[1], cell(B.stone))
    }

    // ---- lan_players ------------------------------------------------------------

    private func sampleLANPlayerRecord(revision: Int = 1) -> [String: Any] {
        [
            "state": ["x": 12.5, "y": 64.0, "z": -3.0, "yaw": 90.0, "pitch": 0.0, "gameMode": 0],
            "inventory": ["slots": [["id": "stone", "count": 32]], "selected": 0],
            "revision": revision,
            "permissions": ["canBreak": true, "canPlace": true],
            "displayName": "Guest1",
            "updated": 1_700_000_000_000.0
        ]
    }

    func testLANPlayerRoundTripsNestedDictsThroughSQLite() throws {
        let db = try makeDB()
        let record = sampleLANPlayerRecord()

        db.putLANPlayer(world: "world-a", playerID: "peer-1", record)
        let got = db.getLANPlayer(world: "world-a", playerID: "peer-1")

        XCTAssertNotNil(got)
        let state = got?["state"] as? [String: Any]
        XCTAssertEqual(state?["x"] as? Double, 12.5)
        XCTAssertEqual(state?["gameMode"] as? Int, 0)
        let inventory = got?["inventory"] as? [String: Any]
        let slots = inventory?["slots"] as? [[String: Any]]
        XCTAssertEqual(slots?.first?["id"] as? String, "stone")
        XCTAssertEqual(slots?.first?["count"] as? Int, 32)
        XCTAssertEqual(got?["revision"] as? Int, 1)
        let permissions = got?["permissions"] as? [String: Any]
        XCTAssertEqual(permissions?["canBreak"] as? Bool, true)
        XCTAssertEqual(got?["displayName"] as? String, "Guest1")
    }

    func testListLANPlayersReturnsOnlyItsWorldOrderedByPlayerID() throws {
        let db = try makeDB()
        db.putLANPlayer(world: "world-a", playerID: "zeta", sampleLANPlayerRecord())
        db.putLANPlayer(world: "world-a", playerID: "alpha", sampleLANPlayerRecord())
        db.putLANPlayer(world: "world-b", playerID: "middle", sampleLANPlayerRecord())

        let listA = db.listLANPlayers(world: "world-a")
        XCTAssertEqual(listA.map(\.playerID), ["alpha", "zeta"])

        let listB = db.listLANPlayers(world: "world-b")
        XCTAssertEqual(listB.map(\.playerID), ["middle"])
    }

    func testPutLANPlayerUpsertsInPlaceOnPrimaryKey() throws {
        let db = try makeDB()
        db.putLANPlayer(world: "world-a", playerID: "peer-1", sampleLANPlayerRecord(revision: 1))
        db.putLANPlayer(world: "world-a", playerID: "peer-1", sampleLANPlayerRecord(revision: 2))

        let all = db.listLANPlayers(world: "world-a")
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.data["revision"] as? Int, 2)
    }

    func testGetLANPlayerReturnsNilForMissingRow() throws {
        let db = try makeDB()
        XCTAssertNil(db.getLANPlayer(world: "world-a", playerID: "ghost"))
    }

    func testDeleteLANPlayerRemovesExactlyOneRow() throws {
        let db = try makeDB()
        db.putLANPlayer(world: "world-a", playerID: "peer-1", sampleLANPlayerRecord())
        db.putLANPlayer(world: "world-a", playerID: "peer-2", sampleLANPlayerRecord())

        db.deleteLANPlayer(world: "world-a", playerID: "peer-1")

        XCTAssertNil(db.getLANPlayer(world: "world-a", playerID: "peer-1"))
        XCTAssertNotNil(db.getLANPlayer(world: "world-a", playerID: "peer-2"))
        XCTAssertEqual(db.listLANPlayers(world: "world-a").count, 1)
    }

    func testCorruptLANPlayerJSONRowIsSkippedNotCrashed() throws {
        let db = try makeDB()
        db.putLANPlayer(world: "world-a", playerID: "good", sampleLANPlayerRecord())

        // simulate a corrupted row by writing invalid JSON directly, mirroring
        // the shape putLANPlayer would produce but bypassing JSONSerialization
        db.execRawLANPlayerInsertForTesting(world: "world-a", playerID: "bad", json: "{not valid json")

        XCTAssertNil(db.getLANPlayer(world: "world-a", playerID: "bad"))
        XCTAssertNotNil(db.getLANPlayer(world: "world-a", playerID: "good"))

        // listLANPlayers must skip the corrupt row without crashing and still
        // return the good one
        let all = db.listLANPlayers(world: "world-a")
        XCTAssertEqual(all.map(\.playerID), ["good"])
    }

    func testWorldPlayerAdvancementAndResumeAdapterMatrix() throws {
        let db = try makeDB()
        let world = WorldRecord(id: "adapter-world", name: "Adapter World", seed: 77,
                                gameMode: GameMode.survival, difficulty: 2)
        db.putWorld(world)
        XCTAssertEqual(db.getWorld(world.id)?.name, world.name)
        XCTAssertEqual(db.listWorlds().map(\.id), [world.id])

        db.putPlayer(world.id, ["health": 19.5, "alive": true])
        XCTAssertEqual(db.getPlayer(world.id)?["health"] as? Double, 19.5)
        XCTAssertEqual(db.getPlayer(world.id)?["alive"] as? Bool, true)

        db.putAdvancements(world.id, ["story_root", "mine_stone"])
        XCTAssertEqual(db.getAdvancements(world.id), ["story_root", "mine_stone"])

        db.putLANClientResume("host-world", ["updated": false, "x": 12.25])
        XCTAssertEqual(db.getLANClientResume("host-world")?["updated"] as? Bool, false)
        XCTAssertEqual(db.getLANClientResume("host-world")?["x"] as? Double, 12.25)
        db.deleteLANClientResume("host-world")
        XCTAssertNil(db.getLANClientResume("host-world"))

        db.deleteWorld(world.id)
        XCTAssertNil(db.getWorld(world.id))
        XCTAssertNil(db.getPlayer(world.id))
        XCTAssertNil(db.getAdvancements(world.id))
    }

    func testTemplateFormatNilZeroOneAndModernFallbackMatrix() throws {
        registerBlocksIfNeeded()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "elysium-template-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("elysium.db")
        let bootstrap = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false)
        try bootstrap.close()

        let base = ObjectTemplate(name: "base", anchorX: 0, anchorY: 0, anchorZ: 0,
                                  sizeX: 1, sizeY: 1, sizeZ: 1,
                                  blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0,
                                                         cell: UInt16(cell(B.stone)))])
        let legacy = try JSONEncoder().encode(base).map { String(format: "%02x", $0) }.joined()
        let modern = try encodeObjectTemplate(base).map { String(format: "%02x", $0) }.joined()
        let rows = [
            ("nil", "'bad'", "NULL", legacy),
            ("zero", "0", "NULL", legacy),
            ("one", "1", "NULL", legacy),
            ("two", "2", modern, ""),
            ("three", "3", modern, ""),
            ("candidate", "2", modern, ""),
        ].map { name, format, data, json -> String in
            let dataSQL = data == "NULL" ? "NULL" : "X'\(data)'"
            let jsonSQL = json.isEmpty ? "''" : "CAST(X'\(json)' AS TEXT)"
            let sizeX = name == "candidate" ? "'bad'" : "0"
            return "INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,blockCount,blockEntityCount,dominantBlock,dominantDisplay) VALUES('\(name)',\(jsonSQL),0,\(format),\(dataSQL),\(sizeX),0,0,0,0,'','');"
        }.joined()
        try runSQLite(databaseURL, rows + "INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,blockCount,blockEntityCount,dominantBlock,dominantDisplay) VALUES('corrupt','bad',0,2,X'00','bad',0,0,0,0,'','');")

        let database = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false)
        defer { try? database.close() }
        for name in ["nil", "zero", "one", "two", "three", "candidate"] {
            let value = try XCTUnwrap(database.getTemplate(named: name), name)
            XCTAssertEqual(value.blocks.count, 1, name)
            XCTAssertEqual(value.sizeX, 1, name)
        }
        XCTAssertThrowsError(try database.getTemplate(named: "corrupt"))
        let summaries = database.listTemplateSummaries()
        XCTAssertEqual(summaries.count, 6)
        XCTAssertTrue(summaries.allSatisfy { $0.name == "base" && $0.blockCount == 1 })
    }

    func testChunkBatchPreflightsEveryRowBeforeAtomicWrite() throws {
        registerBlocksIfNeeded()
        let db = try makeDB()
        let valid = ChunkRecord(key: db.chunkKey("world", 0, 1, 2), worldId: "world",
                                dim: 0, cx: 1, cz: 2, entities: [])
        let outOfRange = ChunkRecord(key: "bad", worldId: "world", dim: 0,
                                     cx: Int.max, cz: 3, entities: [])
        XCTAssertFalse(db.putChunks([valid, outOfRange]))
        XCTAssertEqual(db.getChunkKeys("world"), [])
        XCTAssertTrue(db.putChunks([]))
        XCTAssertTrue(db.putChunks([valid]))
        XCTAssertEqual(db.getChunkKeys("world"), [db.chunkKey("world", 0, 1, 2)])
    }
}
