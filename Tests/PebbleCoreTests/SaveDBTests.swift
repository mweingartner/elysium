import XCTest
@testable import PebbleCore

final class SaveDBTests: XCTestCase {
    private func makeDB() throws -> SaveDB {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PebbleCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SaveDB(databaseURL: dir.appendingPathComponent("pebble.db"), migrateLegacy: false)
    }

    private func registerBlocksIfNeeded() {
        if blockDefs.isEmpty { registerAllBlocks() }
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
}
