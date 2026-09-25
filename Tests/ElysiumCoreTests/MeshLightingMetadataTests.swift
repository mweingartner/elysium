import XCTest
@testable import ElysiumCore

final class MeshLightingMetadataTests: XCTestCase {
    override func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private func padded(_ cells: [(SIMD3<Int>, UInt16)]) -> [UInt16] {
        var result = [UInt16](repeating: 0, count: 18 * 18 * 18)
        for (p, cell) in cells { result[((p.y + 1) * 18 + p.z + 1) * 18 + p.x + 1] = cell }
        return result
    }

    func testMetadataCoversEveryRegisteredEmitterAndStateWithoutChangingGameplayLight() throws {
        let before = LIGHT_EMIT
        let cells = blockDefs.flatMap { block in (0..<16).map { UInt16(block.id << 4 | $0) } }
        for start in stride(from: 0, to: cells.count, by: 4096) {
            let batch = Array(cells[start..<min(cells.count, start + 4096)])
            let positions = batch.indices.map { SIMD3($0 % 16, ($0 / 16) % 16, $0 / 256) }
            let snapshot = try XCTUnwrap(MeshLightingMetadata(paddedBlocks: padded(Array(zip(positions, batch)))))
            let byPosition = Dictionary(uniqueKeysWithValues: snapshot.emitters.map { ($0.position, $0) })
            for (i, cell) in batch.enumerated() {
                let p = positions[i], key = SIMD3(UInt8(p.x), UInt8(p.y), UInt8(p.z))
                // Exhaustive raw nibbles include invalid anchor charge states above four;
                // presentation remains bounded without changing the simulation decoder.
                let expected = min(15, lightEmitOf(cell))
                XCTAssertEqual(Int(byPosition[key]?.level ?? 0), expected, "cell \(cell)")
                XCTAssertEqual(snapshot.opacity[i], LIGHT_OPACITY[Int(cell >> 4)])
                if let source = byPosition[key] {
                    XCTAssertTrue(source.color.x.isFinite && source.color.y.isFinite && source.color.z.isFinite)
                    XCTAssertGreaterThan(max(source.color.x, max(source.color.y, source.color.z)), 0)
                }
            }
        }
        XCTAssertEqual(LIGHT_EMIT, before, "Presentation metadata must not modify gameplay emission")
    }

    func testStatefulSourcesAndLightColorsAreAuthoritative() throws {
        let entries: [(SIMD3<Int>, UInt16)] = [
            (.init(1, 2, 3), cell(B.furnace)), (.init(2, 2, 3), cell(B.furnace_lit)),
            (.init(3, 2, 3), cell(B.campfire)), (.init(4, 2, 3), cell(B.campfire, 4)),
            (.init(5, 2, 3), cell(bid("candle"))), (.init(6, 2, 3), cell(bid("candle"), 8)),
            (.init(7, 2, 3), cell(B.soul_torch)), (.init(8, 2, 3), cell(B.lava)),
            (.init(9, 2, 3), cell(bid("small_amethyst_bud"))),
        ]
        let metadata = try XCTUnwrap(MeshLightingMetadata(paddedBlocks: padded(entries)))
        XCTAssertEqual(metadata.emitters.map(\.position.x), [2, 4, 6, 7, 8, 9])
        XCTAssertEqual(metadata.emitters.map(\.level), [13, 15, 3, 10, 15, 1])
        let soul = try XCTUnwrap(metadata.emitters.first { $0.position.x == 7 })
        let lava = try XCTUnwrap(metadata.emitters.first { $0.position.x == 8 })
        XCTAssertGreaterThan(soul.color.z, soul.color.x)
        XCTAssertGreaterThan(lava.color.x, lava.color.z)
        XCTAssertEqual(metadata.opacity[1 + 16 * (2 + 16 * 3)], 15)
    }

    func testMeshMetadataIsOptionalAndDoesNotChangePackedVertexContract() throws {
        let empty = MeshLayer(data: [], idx: [], count: 0)
        XCTAssertNil(MeshOutput(opaque: empty, cutout: empty, translucent: empty).lighting)
        XCTAssertNil(MeshLightingMetadata(paddedBlocks: []))
        let blocks = padded([(.init(7, 8, 9), cell(B.furnace_lit))])
        let blockLight = [UInt8](repeating: 7, count: blocks.count)
        let input = MeshInput(blocks: blocks, skyLight: [UInt8](repeating: 15, count: blocks.count),
            blockLight: blockLight, biomes: [UInt8](repeating: 0, count: 18 * 18))
        let mesh = buildSectionMesh(input)
        XCTAssertEqual(mesh.lighting?.emitters.count, 1)
        XCTAssertEqual(input.blocks, blocks)
        XCTAssertEqual(input.blockLight, blockLight)
        for layer in [mesh.opaque, mesh.cutout, mesh.translucent] {
            XCTAssertEqual(layer.data.count, layer.count * 7)
            for i in 0..<layer.count {
                XCTAssertEqual((layer.data[i * 7 + 5] >> 21) & 15, 7)
            }
        }
    }
}
