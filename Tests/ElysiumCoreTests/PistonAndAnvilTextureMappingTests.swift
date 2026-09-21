import XCTest
@testable import ElysiumCore

/// Stateful model materials must stay with their physical surfaces. These
/// tests exercise the pack-backed meshing path, where asymmetric authored art
/// would otherwise make a world-aligned mapping visible.
final class PistonAndAnvilTextureMappingTests: XCTestCase {
    private struct TopVertex {
        let x: Double
        let z: Double
        let u: Double
        let v: Double
    }

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private func inputIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
        ((y + 1) * 18 + (z + 1)) * 18 + (x + 1)
    }

    private func packBackedContext() -> MeshRenderContext {
        MeshRenderContext(
            tintGate: [UInt8](repeating: 0, count: allTileNames().count),
            textureGate: [UInt8](repeating: 1, count: allTileNames().count),
            generation: 1
        )!
    }

    private func mesh(for id: UInt16, meta: Int) -> MeshOutput {
        let count = 18 * 18 * 18
        var blocks = [UInt16](repeating: cell(B.air), count: count)
        blocks[inputIndex(8, 8, 8)] = cell(id, meta)
        return buildSectionMesh(MeshInput(
            blocks: blocks,
            skyLight: [UInt8](repeating: 15, count: count),
            blockLight: [UInt8](repeating: 0, count: count),
            biomes: [UInt8](repeating: 0, count: 18 * 18),
            noMerge: true,
            renderContext: packBackedContext()
        ))
    }

    private func tileNames(in mesh: MeshOutput, normal: Int) -> Set<String> {
        var names: Set<String> = []
        for layer in [mesh.opaque, mesh.cutout, mesh.translucent] {
            for vertex in 0..<layer.count {
                let material = layer.data[vertex * 7 + 5]
                guard Int((material >> 12) & 7) == normal else { continue }
                names.insert(tileName(Int(material & 4095)))
            }
        }
        return names
    }

    private func topVertices(in mesh: MeshOutput, tile expectedTile: String) -> [TopVertex] {
        var result: [TopVertex] = []
        for layer in [mesh.opaque, mesh.cutout, mesh.translucent] {
            for vertex in 0..<layer.count {
                let base = vertex * 7
                let material = layer.data[base + 5]
                guard Int((material >> 12) & 7) == 1,
                      tileName(Int(material & 4095)) == expectedTile else { continue }
                result.append(TopVertex(
                    x: Double(Float(bitPattern: layer.data[base])),
                    z: Double(Float(bitPattern: layer.data[base + 2])),
                    u: Double(Float(bitPattern: layer.data[base + 3])),
                    v: Double(Float(bitPattern: layer.data[base + 4]))
                ))
            }
        }
        return result
    }

    private func assertFront(_ name: String, _ id: UInt16, _ meta: Int, tile: String) {
        let facing = meta & 7
        let rendered = mesh(for: id, meta: meta)
        XCTAssertTrue(tileNames(in: rendered, normal: facing).contains(tile),
                      "\(name) must put \(tile) on face \(facing), meta \(meta)")
        for face in 0..<6 where face != facing {
            XCTAssertFalse(tileNames(in: rendered, normal: face).contains(tile),
                           "\(name) leaked \(tile) onto face \(face), meta \(meta)")
        }
    }

    func testPistonAndHeadFrontTilesFollowAllSixFacingStates() {
        for facing in 0..<6 {
            for extended in [false, true] {
                let meta = facing | (extended ? 8 : 0)
                assertFront("piston", B.piston, meta, tile: "piston_top")
                assertFront("sticky piston", B.sticky_piston, meta, tile: "piston_top_sticky")
            }
            assertFront("piston head", B.piston_head, facing, tile: "piston_top")
            assertFront("sticky piston head", B.piston_head, facing | 8, tile: "piston_top_sticky")
        }
    }

    func testAnvilTopArtTracksBothAxesAndOpposingFacings() {
        let fixtures: [(name: String, id: UInt16, tile: String)] = [
            ("anvil", B.anvil, "anvil_top"),
            ("chipped anvil", B.chipped_anvil, "chipped_anvil_top"),
            ("damaged anvil", B.damaged_anvil, "damaged_anvil_top"),
        ]

        for fixture in fixtures {
            for facing in 0..<4 {
                let vertices = topVertices(in: mesh(for: fixture.id, meta: facing), tile: fixture.tile)
                XCTAssertFalse(vertices.isEmpty, "\(fixture.name), facing \(facing)")
                for vertex in vertices {
                    let expected = facingTopUV((facing + 2) & 3, vertex.x - 8, vertex.z - 8)
                    XCTAssertEqual(vertex.u, expected.0, accuracy: 0.0001,
                                   "\(fixture.name), facing \(facing) U")
                    XCTAssertEqual(vertex.v, expected.1, accuracy: 0.0001,
                                   "\(fixture.name), facing \(facing) V")
                }
            }
        }
    }
}
