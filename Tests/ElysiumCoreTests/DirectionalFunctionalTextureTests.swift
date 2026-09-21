import XCTest
@testable import ElysiumCore

/// Regression coverage for functional blocks whose metadata chooses which
/// physical face receives an asymmetric, player-recognizable texture.  These
/// assertions use the pack-backed mesh path: the same route Faithful uses at
/// runtime, rather than only inspecting a block definition's `texFn`.
final class DirectionalFunctionalTextureTests: XCTestCase {
    private struct Vertex {
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

    private func packedContext() -> MeshRenderContext {
        MeshRenderContext(
            tintGate: [UInt8](repeating: 0, count: allTileNames().count),
            textureGate: [UInt8](repeating: 1, count: allTileNames().count),
            generation: 1
        )!
    }

    private func meshFor(_ id: UInt16, meta: Int) -> MeshOutput {
        let count = 18 * 18 * 18
        var blocks = [UInt16](repeating: cell(B.air), count: count)
        blocks[inputIndex(8, 8, 8)] = cell(id, meta)
        return buildSectionMesh(MeshInput(
            blocks: blocks,
            skyLight: [UInt8](repeating: 15, count: count),
            blockLight: [UInt8](repeating: 0, count: count),
            biomes: [UInt8](repeating: 0, count: 18 * 18),
            noMerge: true,
            renderContext: packedContext()
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

    private func topVertices(in mesh: MeshOutput, tile expectedTile: String) -> [Vertex] {
        var result: [Vertex] = []
        for layer in [mesh.opaque, mesh.cutout, mesh.translucent] {
            for vertex in 0..<layer.count {
                let base = vertex * 7
                let material = layer.data[base + 5]
                guard Int((material >> 12) & 7) == 1,
                      tileName(Int(material & 4095)) == expectedTile else { continue }
                result.append(Vertex(
                    x: Double(Float(bitPattern: layer.data[base])),
                    z: Double(Float(bitPattern: layer.data[base + 2])),
                    u: Double(Float(bitPattern: layer.data[base + 3])),
                    v: Double(Float(bitPattern: layer.data[base + 4]))
                ))
            }
        }
        return result
    }

    func testFourWayFunctionalFrontTexturesFollowTheirFacing() {
        let fixtures: [(name: String, id: UInt16, frontTile: String)] = [
            ("furnace", B.furnace, "furnace_front"),
            ("lit furnace", B.furnace_lit, "furnace_front_lit"),
            ("blast furnace", B.blast_furnace, "blast_furnace_front"),
            ("lit blast furnace", B.blast_furnace_lit, "blast_furnace_front_lit"),
            ("smoker", B.smoker, "smoker_front"),
            ("lit smoker", B.smoker_lit, "smoker_front_lit"),
            ("carved pumpkin", B.carved_pumpkin, "carved_pumpkin"),
            ("jack o lantern", B.jack_o_lantern, "jack_o_lantern"),
            ("loom", B.loom, "loom_front"),
            ("chiseled bookshelf", B.chiseled_bookshelf, "chiseled_bookshelf_occupied"),
        ]

        for fixture in fixtures {
            for facing in 0..<4 {
                let mesh = meshFor(fixture.id, meta: facing)
                let front = facing + 2
                XCTAssertTrue(tileNames(in: mesh, normal: front).contains(fixture.frontTile),
                              "\(fixture.name) must put its front on facing \(facing)")
                for other in 2..<6 where other != front {
                    XCTAssertFalse(tileNames(in: mesh, normal: other).contains(fixture.frontTile),
                                   "\(fixture.name) front leaked onto face \(other) for facing \(facing)")
                }
            }
        }
    }

    func testSixWayFunctionalFrontTexturesFollowTheirFacingAndState() {
        let fixtures: [(name: String, id: UInt16, frontTile: (Int, Bool) -> String)] = [
            ("observer", B.observer, { _, _ in "observer_front" }),
            ("dispenser", B.dispenser, { facing, _ in
                facing <= 1 ? "dispenser_front_vertical" : "dispenser_front"
            }),
            ("dropper", B.dropper, { facing, _ in
                facing <= 1 ? "dropper_front_vertical" : "dropper_front"
            }),
            ("barrel", B.barrel, { _, open in open ? "barrel_top_open" : "barrel_top" }),
        ]

        for fixture in fixtures {
            for facing in 0..<6 {
                for poweredOrOpen in [false, true] {
                    let meta = facing | (poweredOrOpen ? 8 : 0)
                    let frontTile = fixture.frontTile(facing, poweredOrOpen)
                    let mesh = meshFor(fixture.id, meta: meta)
                    XCTAssertTrue(tileNames(in: mesh, normal: facing).contains(frontTile),
                                  "\(fixture.name) must put \(frontTile) on facing \(facing), state \(poweredOrOpen)")
                    for other in 0..<6 where other != facing {
                        XCTAssertFalse(tileNames(in: mesh, normal: other).contains(frontTile),
                                       "\(fixture.name) front leaked onto face \(other) for facing \(facing), state \(poweredOrOpen)")
                    }
                }
            }
        }
    }

    func testDirectionalTopTexturesRotateWithRepeaterComparatorAndCampfireState() {
        let fixtures: [(name: String, id: UInt16, tile: String, metas: [Int])] = [
            ("repeater", B.repeater, "repeater", Array(0..<16)),
            ("powered repeater", B.repeater_on, "repeater_on", Array(0..<16)),
            ("comparator", B.comparator, "comparator", Array(0..<8)),
            ("powered comparator", B.comparator_on, "comparator_on", Array(0..<8)),
            ("campfire", B.campfire, "campfire_log", Array(0..<8)),
            ("soul campfire", B.soul_campfire, "soul_campfire_log", Array(0..<8)),
        ]

        for fixture in fixtures {
            for meta in fixture.metas {
                let vertices = topVertices(in: meshFor(fixture.id, meta: meta), tile: fixture.tile)
                XCTAssertFalse(vertices.isEmpty, "\(fixture.name), meta \(meta)")
                for vertex in vertices {
                    let expected = facingTopUV(meta & 3, vertex.x - 8, vertex.z - 8)
                    XCTAssertEqual(vertex.u, expected.0, accuracy: 0.0001,
                                   "\(fixture.name), meta \(meta) U")
                    XCTAssertEqual(vertex.v, expected.1, accuracy: 0.0001,
                                   "\(fixture.name), meta \(meta) V")
                }
            }
        }
    }
}
