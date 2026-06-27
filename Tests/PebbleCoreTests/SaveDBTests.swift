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
}
