import XCTest
@testable import ElysiumCore

final class TreeEcologyChunkPersistenceTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private func record() -> ChunkRecord {
        let info = dimInfo(.overworld)
        var blocks = [UInt16](repeating: 0, count: 256 * info.height)
        let index = (65 - info.minY) * 256 + 3 * 16 + 2
        blocks[index] = cell(B.oak_log)
        return ChunkRecord(key: "tree:0:0:0", worldId: "tree", dim: 0, cx: 0, cz: 0,
                           blocks: blocks, biomes: [UInt8](repeating: 0, count: 16 * ((info.height + 3) / 4)),
                           naturalTreeCells: [index: NaturalTreeCell(
                            origin: .init(x: 2, y: 64, z: 3), expected: blocks[index], decayStartTick: 730)])
    }

    func testBothChunkFormatsRoundTripNaturalTreeDecay() throws {
        let original = record()
        for data in [try XCTUnwrap(encodeLegacyVCK(original)), try XCTUnwrap(encodeCompactVCK2(original))] {
            let restored = try XCTUnwrap(decodeLegacyVCK(data, key: original.key, worldId: original.worldId,
                                                      dimension: 0, chunkX: 0, chunkZ: 0))
            XCTAssertEqual(restored.blocks, original.blocks)
            XCTAssertEqual(restored.naturalTreeCells, original.naturalTreeCells)
        }
    }

    func testLegacySavedWoodIsNotInferredToBeNatural() throws {
        var original = record()
        original.naturalTreeCells = [:]
        let data = try XCTUnwrap(encodeLegacyVCK(original))
        let restored = try XCTUnwrap(decodeLegacyVCK(data, key: original.key, worldId: original.worldId,
                                                  dimension: 0, chunkX: 0, chunkZ: 0))
        XCTAssertEqual(restored.blocks, original.blocks)
        XCTAssertTrue(restored.naturalTreeCells.isEmpty)
    }
}
