import XCTest
@testable import ElysiumCore

/// A directional resource-pack tile must stay attached to an openable model as
/// its stored state rotates the geometry. These tests deliberately mark the
/// real tile as pack-backed and inspect emitted UVs rather than relying on
/// symmetric procedural art to hide an orientation regression.
final class StatefulOpenableTextureMappingTests: XCTestCase {
    private struct Vertex {
        let x: Double
        let y: Double
        let z: Double
        let u: Double
        let v: Double
        let normal: Int
    }

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private func mesh(for blockID: Int, meta: Int, packTile: Int) throws -> MeshOutput {
        let side = 18
        var cells = [UInt16](repeating: cell(B.air), count: side * side * side)
        let center = ((8 + 1) * side + (8 + 1)) * side + (8 + 1)
        cells[center] = cell(UInt16(blockID), meta)
        var textureGate = [UInt8](repeating: 0, count: allTileNames().count)
        textureGate[packTile] = 1
        let context = try XCTUnwrap(MeshRenderContext(tintGate: nil, textureGate: textureGate,
                                                      generation: 2))
        return buildSectionMesh(MeshInput(
            blocks: cells,
            skyLight: [UInt8](repeating: 15, count: cells.count),
            blockLight: [UInt8](repeating: 0, count: cells.count),
            biomes: [UInt8](repeating: 0, count: side * side),
            noMerge: true,
            renderContext: context
        ))
    }

    private func vertices(in layer: MeshLayer, matching tile: Int) -> [Vertex] {
        (0..<layer.count).compactMap { index in
            let base = index * 7
            let material = layer.data[base + 5]
            guard Int(material & 4095) == tile else { return nil }
            return Vertex(
                x: Double(Float(bitPattern: layer.data[base])) - 8,
                y: Double(Float(bitPattern: layer.data[base + 1])) - 8,
                z: Double(Float(bitPattern: layer.data[base + 2])) - 8,
                u: Double(Float(bitPattern: layer.data[base + 3])),
                v: Double(Float(bitPattern: layer.data[base + 4])),
                normal: Int((material >> 12) & 7)
            )
        }
    }

    private func rawFaceUV(_ face: Int, _ vertex: Vertex) -> (Double, Double) {
        switch face {
        case 0, 1: return (vertex.x, vertex.z)
        case 2: return (1 - vertex.x, 1 - vertex.y)
        case 3: return (vertex.x, 1 - vertex.y)
        case 4: return (vertex.z, 1 - vertex.y)
        default: return (1 - vertex.z, 1 - vertex.y)
        }
    }

    private func canonicalGatePoint(_ facing: Int, _ vertex: Vertex,
                                    wallLowering: Double) -> (Double, Double, Double) {
        let y = vertex.y + wallLowering
        switch facing & 3 {
        case 0: return (1 - vertex.x, y, 1 - vertex.z)
        case 1: return (vertex.x, y, vertex.z)
        case 2: return (vertex.z, y, 1 - vertex.x)
        default: return (1 - vertex.z, y, vertex.x)
        }
    }

    private func canonicalGateFace(_ facing: Int, _ face: Int) -> Int {
        guard face >= 2 else { return face }
        switch facing & 3 {
        case 0: return face ^ 1
        case 1: return face
        case 2:
            switch face {
            case 2: return 4
            case 3: return 5
            case 4: return 3
            default: return 2
            }
        default:
            switch face {
            case 2: return 5
            case 3: return 4
            case 4: return 2
            default: return 3
            }
        }
    }

    private func canonicalFaceUV(_ face: Int, _ point: (Double, Double, Double)) -> (Double, Double) {
        switch face {
        case 0, 1: return (point.0, point.2)
        case 2: return (1 - point.0, 1 - point.1)
        case 3: return (point.0, 1 - point.1)
        case 4: return (point.2, 1 - point.1)
        default: return (1 - point.2, 1 - point.1)
        }
    }

    private func assertUV(_ actual: Vertex, equals expected: (Double, Double),
                          _ message: @autoclosure () -> String) {
        XCTAssertEqual(actual.u, expected.0, accuracy: 0.0001, message())
        XCTAssertEqual(actual.v, expected.1, accuracy: 0.0001, message())
    }

    func testPackBackedBambooGateUVsTrackEveryFacingOpenAndWallState() throws {
        let gateID = Int(bid("bamboo_fence_gate"))
        let tile = tileId("bamboo_fence_gate")

        for meta in 0..<16 {
            let mesh = try mesh(for: gateID, meta: meta, packTile: tile)
            let gateVertices = vertices(in: mesh.cutout, matching: tile)
            XCTAssertFalse(gateVertices.isEmpty, "bamboo gate meta \(meta) must reach the pack-backed mesh")

            let facing = meta & 3
            let wallLowering = meta & 8 == 0 ? 0.0 : 3.0 / 16.0
            for vertex in gateVertices {
                let canonical = canonicalGatePoint(facing, vertex, wallLowering: wallLowering)
                let expected = canonicalFaceUV(canonicalGateFace(facing, vertex.normal), canonical)
                assertUV(vertex, equals: expected, "bamboo gate meta \(meta), normal \(vertex.normal)")
            }
        }
    }

    func testPackBackedTrapdoorUVsStayWithLeafAcrossEveryState() throws {
        for name in WOODS.map({ "\($0)_trapdoor" }) + ["iron_trapdoor"] {
            let blockID = Int(bid(name))
            let tile = tileId(name)
            for meta in 0..<16 {
                let mesh = try mesh(for: blockID, meta: meta, packTile: tile)
                let trapdoorVertices = vertices(in: mesh.cutout, matching: tile)
                XCTAssertFalse(trapdoorVertices.isEmpty, "\(name) meta \(meta) must reach the pack-backed mesh")

                let facing = meta & 3
                let open = meta & 4 != 0
                let outwardFace = (facing ^ 1) + 2
                let leafV: (Double) -> Double = { rawV in
                    (meta & 8) == 0 ? rawV : 1 - rawV
                }
                for vertex in trapdoorVertices {
                    let raw = rawFaceUV(vertex.normal, vertex)
                    let expected: (Double, Double)
                    if !open && (vertex.normal == 0 || vertex.normal == 1) {
                        expected = facingTopUV(facing, raw.0, raw.1)
                    } else if open, vertex.normal == outwardFace {
                        expected = (raw.0, leafV(raw.1))
                    } else if open, vertex.normal == (outwardFace ^ 1) {
                        expected = (1 - raw.0, leafV(raw.1))
                    } else {
                        expected = raw
                    }
                    assertUV(vertex, equals: expected, "\(name) meta \(meta), normal \(vertex.normal)")
                }
            }
        }
    }
}
