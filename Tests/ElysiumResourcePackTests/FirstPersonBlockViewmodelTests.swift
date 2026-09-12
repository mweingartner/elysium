import Foundation
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class FirstPersonBlockViewmodelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        registerAllBlocks(); registerAllItems(); registerAllBiomes()
    }

    private func color(_ value: UInt32) -> SIMD4<Float> {
        viewmodelLinearColor(SIMD4(Float((value >> 16) & 255)/255,
                                  Float((value >> 8) & 255)/255,Float(value & 255)/255,1))
    }

    private func vertices(_ mesh: ViewmodelMesh, tile: String) -> [ViewmodelVertex] {
        mesh.vertices.filter { tileName(Int($0.surface.z)) == tile }
    }

    private func assertV(_ mesh: ViewmodelMesh, tile: String, min low: Float, max high: Float,
                         file: StaticString = #filePath, line: UInt = #line) {
        let selected = vertices(mesh, tile: tile)
        XCTAssertFalse(selected.isEmpty, tile, file: file, line: line)
        XCTAssertEqual(selected.map(\.surface.y).min() ?? -1, low, accuracy: 0.00001, file: file, line: line)
        XCTAssertEqual(selected.map(\.surface.y).max() ?? -1, high, accuracy: 0.00001, file: file, line: line)
    }

    func testGrassAndLeavesUseCurrentBiomeColorsInLinearSpace() throws {
        for biome in [Biome.plains, .swamp] {
            let definition = try XCTUnwrap(BIOMES[biome.rawValue])
            let grass = ViewmodelMesh.block(Int(B.grass_block), biome: biome.rawValue)
            let leaves = ViewmodelMesh.block(Int(bid("oak_leaves")), biome: biome.rawValue)
            XCTAssertFalse(grass.vertices.isEmpty)
            XCTAssertFalse(leaves.vertices.isEmpty)
            XCTAssertTrue(grass.vertices.allSatisfy { $0.color == color(definition.grassColor) })
            XCTAssertTrue(leaves.vertices.allSatisfy { $0.color == color(definition.foliageColor) })
        }
    }

    func testTintGateLeavesAlreadyColoredFacesUntinted() throws {
        var gate = [UInt8](repeating: 0, count: allTileNames().count)
        gate[tileId("grass_top")] = 1
        let context = try XCTUnwrap(MeshRenderContext(tintGate: gate, textureGate: nil, generation: 2))
        let mesh = ViewmodelMesh.block(Int(B.grass_block), context: context, biome: Biome.swamp.rawValue)
        let biome = try XCTUnwrap(BIOMES[Biome.swamp.rawValue])
        XCTAssertTrue(vertices(mesh, tile: "grass_top").allSatisfy { $0.color == color(biome.grassColor) })
        let sides = vertices(mesh, tile: "grass_side") + vertices(mesh, tile: "dirt")
        XCTAssertFalse(sides.isEmpty)
        XCTAssertTrue(sides.allSatisfy { $0.color == SIMD4(repeating: 1) },
                      "pack-colored faces must not receive the grass multiplier a second time")
    }

    func testSlabCropsSideUVInsteadOfStretchingAWholeTile() {
        let slab = ViewmodelMesh.block(Int(bid("stone_slab")))
        let sides = slab.vertices.filter { abs($0.normal.y) < 0.5 }
        XCTAssertFalse(sides.isEmpty)
        XCTAssertEqual(sides.map(\.surface.y).min() ?? -1, 0.5, accuracy: 0.00001)
        XCTAssertEqual(sides.map(\.surface.y).max() ?? -1, 1, accuracy: 0.00001)
        let top = slab.vertices.filter { $0.normal.y > 0.5 }
        XCTAssertEqual(top.map(\.surface.x).min() ?? -1, 0, accuracy: 0.00001)
        XCTAssertEqual(top.map(\.surface.x).max() ?? -1, 1, accuracy: 0.00001)
        XCTAssertEqual(top.map(\.surface.y).min() ?? -1, 0, accuracy: 0.00001)
        XCTAssertEqual(top.map(\.surface.y).max() ?? -1, 1, accuracy: 0.00001)
        XCTAssertEqual((slab.vertices.map(\.position.y).max() ?? 0) - (slab.vertices.map(\.position.y).min() ?? 0),
                       0.19, accuracy: 0.00001)
    }

    func testRealFaithfulProvenanceSelectsCanonicalChestDoorAndBedCrops() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pack = try XCTUnwrap(ResourcePack(url: repository.appendingPathComponent(
            "packaging/Faithful 64x - December 2025 Release.zip")))
        let atlas = try XCTUnwrap(buildPackAtlas(packs: [pack]))
        let context = try XCTUnwrap(MeshRenderContext(tintGate: atlas.tintGate,
                                                     textureGate: atlas.textureGate, generation: 9))
        for tile in ["chest_side", "oak_door", "red_bed_top", "red_bed_side"] {
            XCTAssertEqual(atlas.textureGate[tileId(tile)], 1, "test requires the actual packed semantic tile")
        }
        assertV(ViewmodelMesh.block(Int(B.chest), context: context), tile: "chest_side", min: 0, max: 1/3)
        assertV(ViewmodelMesh.block(Int(bid("oak_door")), context: context), tile: "oak_door", min: 0.5, max: 1)
        let bed = ViewmodelMesh.block(Int(bid("red_bed")), context: context)
        assertV(bed, tile: "red_bed_top", min: 0.5, max: 1)
        assertV(bed, tile: "red_bed_side", min: 0.5, max: 1)

        let proceduralDoor = ViewmodelMesh.block(Int(bid("oak_door")))
        assertV(proceduralDoor, tile: "oak_door", min: 0, max: 1)
        let shortContext = try XCTUnwrap(MeshRenderContext(tintGate: [], textureGate: [], generation: 10))
        assertV(ViewmodelMesh.block(Int(bid("oak_door")), context: shortContext), tile: "oak_door", min: 0, max: 1)
    }

    func testWholeAndMultipartBlocksStayBoundedFiniteAndOutwardWound() {
        for name in ["stone", "stone_slab", "oak_stairs", "chest", "oak_door", "red_bed", "torch"] {
            let mesh = ViewmodelMesh.block(Int(bid(name)))
            XCTAssertFalse(mesh.vertices.isEmpty, name)
            XCTAssertLessThanOrEqual(mesh.vertices.count, 16_384, name)
            for vertex in mesh.vertices {
                XCTAssertTrue([vertex.position.x,vertex.position.y,vertex.position.z,
                               vertex.surface.x,vertex.surface.y,vertex.surface.z].allSatisfy(\.isFinite), name)
            }
            for i in stride(from: 0, to: mesh.vertices.count, by: 3) {
                let a = mesh.vertices[i], b = mesh.vertices[i + 1], c = mesh.vertices[i + 2]
                let ab = b.position-a.position, ac = c.position-a.position
                let n = simd_cross(SIMD3(ab.x,ab.y,ab.z),SIMD3(ac.x,ac.y,ac.z))
                XCTAssertGreaterThan(simd_dot(n,SIMD3(a.normal.x,a.normal.y,a.normal.z)),0,name)
            }
        }
        XCTAssertTrue(ViewmodelMesh.block(-1).vertices.isEmpty)
        XCTAssertTrue(ViewmodelMesh.block(blockDefs.count).vertices.isEmpty)
    }
}
