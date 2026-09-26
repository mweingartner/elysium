import XCTest
import simd
@testable import Elysium
@testable import ElysiumCore

final class RayTracingMeshTests: XCTestCase {
    private let empty=MeshLayer(data:[],idx:[],count:0)

    private func layer(tile:UInt32=0,normal:UInt32=1,animation:UInt32=0,emissive:Bool=false) -> MeshLayer {
        let positions:[SIMD3<Float>]=[.init(0,0,0),.init(1,0,0),.init(0,0,1)]
        let uv:[SIMD2<Float>]=[.init(0,0),.init(4,0),.init(0,8)]
        var words:[UInt32]=[]
        for i in 0..<3 {
            words += [positions[i].x.bitPattern,positions[i].y.bitPattern,positions[i].z.bitPattern,
                      uv[i].x.bitPattern,uv[i].y.bitPattern,
                      tile | normal<<12 | 12<<17 | 7<<21 | (emissive ? 1<<25:0),
                      0x3478ab | animation<<24]
        }
        return MeshLayer(data:words,idx:[0,1,2],count:3)
    }
    private func decode(_ layer:MeshLayer,cutout:Bool=false,translucent:Bool=false) -> RayTracingMeshDecoder.Decoded? {
        RayTracingMeshDecoder.decode(.init(opaque:cutout || translucent ? empty:layer,
            cutout:cutout ? layer:empty,translucent:translucent ? layer:empty))
    }

    private func actualBlockMesh(_ block: UInt16, metadata: Int = 0) -> MeshOutput {
        var blocks = [UInt16](repeating: 0, count: 18 * 18 * 18)
        blocks[(9 * 18 + 9) * 18 + 9] = cell(block, metadata)
        return buildSectionMesh(MeshInput(blocks: blocks,
            skyLight: [UInt8](repeating: 0, count: blocks.count),
            blockLight: [UInt8](repeating: 13, count: blocks.count),
            biomes: [UInt8](repeating: 0, count: 18 * 18)))
    }

    /// Builds a real mesher output for a fully submerged waterlogged plant `column`
    /// (bottom-to-top (block, meta) pairs) standing on a 5x5 sand seabed at (8, 8, 8),
    /// with two layers of real water above its top and around every other column.
    private func submergedAquaticPlantMesh(_ column: [(UInt16, Int)]) -> MeshOutput {
        let paddedCount = 18 * 18 * 18
        var blocks = [UInt16](repeating: 0, count: paddedCount)
        func index(_ x: Int, _ y: Int, _ z: Int) -> Int { ((y + 1) * 18 + (z + 1)) * 18 + (x + 1) }
        let baseY = 8
        let topY = baseY + column.count - 1
        for x in 6...10 {
            for z in 6...10 {
                blocks[index(x, baseY - 1, z)] = cell(B.sand)
                for y in baseY...(topY + 2) {
                    if x == 8, z == 8, y <= topY { continue }
                    blocks[index(x, y, z)] = cell(B.water)
                }
            }
        }
        for (offset, entry) in column.enumerated() {
            blocks[index(8, baseY + offset, 8)] = cell(entry.0, entry.1)
        }
        return buildSectionMesh(MeshInput(blocks: blocks,
            skyLight: [UInt8](repeating: 15, count: paddedCount),
            blockLight: [UInt8](repeating: 0, count: paddedCount),
            biomes: [UInt8](repeating: 0, count: 18 * 18)))
    }

    func testActualLitFurnaceCasingDoesNotEmitButMouthAndRoomLightRemain() throws {
        registerAllBlocks()
        let facades: Set<String> = ["furnace_top", "furnace_side", "furnace_front_lit"]
        for facing in 0..<4 {
            let mesh = actualBlockMesh(B.furnace_lit, metadata: facing)
            let decoded = try XCTUnwrap(RayTracingMeshDecoder.decode(mesh))
            let casing = decoded.primitives.filter { facades.contains(tileName(Int($0.material.y))) }
            XCTAssertEqual(Set(casing.map { tileName(Int($0.material.y)) }), facades)
            XCTAssertTrue(casing.allSatisfy { $0.normalEmission.w == 0 },
                          "Furnace stone must not self-emit, including its front border")
            let mouth = decoded.primitives.filter { tileName(Int($0.material.y)) == "fire" }
            XCTAssertFalse(mouth.isEmpty)
            XCTAssertTrue(mouth.allSatisfy { $0.normalEmission.w > 0 })
            XCTAssertFalse(decoded.emitters.isEmpty, "The actual flame still supplies fallback ray lights")
            let source = try XCTUnwrap(mesh.lighting?.emitters.first)
            XCTAssertEqual(mesh.lighting?.emitters.count, 1)
            XCTAssertEqual(source.level, 13, "Casing classification cannot remove placed-source illumination")
            XCTAssertEqual(source.position, SIMD3<UInt8>(8, 8, 8))
        }
    }

    func testActualTorchAndGlowstoneRetainSurfaceEmission() throws {
        registerAllBlocks()
        for (block, glowTile) in [(B.torch, "fire"), (B.glowstone, "glowstone")] {
            let decoded = try XCTUnwrap(RayTracingMeshDecoder.decode(actualBlockMesh(block)))
            let glow = decoded.primitives.filter { tileName(Int($0.material.y)) == glowTile }
            XCTAssertFalse(glow.isEmpty)
            XCTAssertTrue(glow.allSatisfy { $0.normalEmission.w > 0 })
            XCTAssertFalse(decoded.emitters.isEmpty)
            let stems = decoded.primitives.filter { tileName(Int($0.material.y)) == "oak_planks" }
            XCTAssertTrue(stems.allSatisfy { $0.normalEmission.w == 0 })
        }
    }

    func testPrimitiveAndFrameABIExactlyMatchesMetal() {
        XCTAssertEqual(MemoryLayout<RayTracingPrimitive>.stride,96)
        XCTAssertEqual(MemoryLayout<RayTracingPrimitive>.offset(of:\.textureGradientU),64)
        XCTAssertEqual(MemoryLayout<RayTracingPrimitive>.offset(of:\.textureGradientV),80)
        XCTAssertEqual(MemoryLayout<RayTracingInstanceUniforms>.stride,240)
        XCTAssertEqual(MemoryLayout<RayTracingLight>.stride,32)
        XCTAssertEqual(MemoryLayout<RayTracingUniforms>.stride,448)
    }

    func testPackedMeshPreservesRepeatedUVLightTintAndNormal() throws {
        let decoded=try XCTUnwrap(decode(layer(tile:37)))
        XCTAssertEqual(decoded.positions,[.init(0,0,0),.init(1,0,0),.init(0,0,1)])
        XCTAssertEqual(decoded.indices,[0,1,2])
        let p=try XCTUnwrap(decoded.primitives.first)
        XCTAssertEqual(p.uv01,.init(0,0,4,0))
        XCTAssertEqual(p.uv2Light.x,0); XCTAssertEqual(p.uv2Light.y,8)
        XCTAssertEqual(p.uv2Light.z,12.0/15,accuracy:0.00001)
        XCTAssertEqual(p.uv2Light.w,7.0/15,accuracy:0.00001)
        XCTAssertEqual(p.normalEmission,.init(0,1,0,0))
        XCTAssertEqual(p.material.x,0x3478ab); XCTAssertEqual(p.material.y,37)
        XCTAssertEqual(p.textureGradientU,.init(4,0,0,0))
        XCTAssertEqual(p.textureGradientV,.init(0,0,8,0))
    }

    func testLayersKeepDistinctCutoutWaterAndGlassClassification() throws {
        XCTAssertEqual(try XCTUnwrap(decode(layer(),cutout:true)).primitives[0].material.z&7,1)
        XCTAssertEqual(try XCTUnwrap(decode(layer(),translucent:true)).primitives[0].material.z&7,4)
        XCTAssertEqual(try XCTUnwrap(decode(layer(animation:1),translucent:true)).primitives[0].material.z&7,2)
    }

    func testLavaKeepsEmissionAndPublishesAnActualSurfaceLight() throws {
        let value=try XCTUnwrap(decode(layer(animation:2,emissive:true)))
        XCTAssertEqual(value.primitives[0].normalEmission.w,8.5)
        let emitter=try XCTUnwrap(value.emitters.first)
        XCTAssertGreaterThan(emitter.colorPower.w,0)
        XCTAssertGreaterThan(emitter.positionRadius.y,0,"The shadow ray starts outside the emitting face")
    }

    func testMalformedTopologyAndNonfiniteValuesRejectWholeMesh() {
        let good=layer()
        XCTAssertNil(decode(.init(data:good.data,idx:[0,1,3],count:3)))
        XCTAssertNil(decode(.init(data:good.data,idx:[0,1],count:3)))
        XCTAssertNil(decode(.init(data:Array(good.data.dropLast()),idx:good.idx,count:3)))
        var bad=good.data; bad[0]=Float.nan.bitPattern
        XCTAssertNil(decode(.init(data:bad,idx:good.idx,count:3)))
        bad=good.data; bad[3]=Float.infinity.bitPattern
        XCTAssertNil(decode(.init(data:bad,idx:good.idx,count:3)))
        XCTAssertNil(decode(layer(normal:7)))
    }

    func testLayerConcatenationRebasesTriangleIndicesWithoutChangingLocalPositions() throws {
        let decoded=try XCTUnwrap(RayTracingMeshDecoder.decode(.init(opaque:layer(),cutout:layer(),translucent:layer(animation:1))))
        XCTAssertEqual(decoded.positions.count,9)
        XCTAssertEqual(decoded.indices,[0,1,2,3,4,5,6,7,8])
        XCTAssertEqual(decoded.primitives.count,3)
        XCTAssertEqual(decoded.positions[0],decoded.positions[3])
    }

    func testMovingBlockDecoderPreservesTheSectionVertexABI() throws {
        let source=layer(tile:19,animation:2,emissive:true)
        let block=try XCTUnwrap(RayTracingMeshDecoder.decodePacked(data:source.data,indices:source.idx))
        let section=try XCTUnwrap(decode(source))
        XCTAssertEqual(block.positions,section.positions)
        XCTAssertEqual(block.indices,section.indices)
        XCTAssertEqual(block.primitives.first?.material,section.primitives.first?.material)
        XCTAssertEqual(block.primitives.first?.normalEmission,section.primitives.first?.normalEmission)
        XCTAssertNil(RayTracingMeshDecoder.decodePacked(data:[0],indices:[]))
    }

    func testFallbackLightSelectionDoesNotLetRemoteEmittersStarveNearbyLights() {
        let nearby=RayTracingLight(positionRadius:.init(2,1,-3,30),colorPower:.init(1,0.7,0.3,4))
        let remote=(0..<1024).map { RayTracingLight(positionRadius:.init(Float(100+$0),0,0,30),colorPower:.init(1,0.3,0.1,10)) }
        let selected=RayTracingLocalLightSelection.select(remote+[nearby])
        XCTAssertEqual(selected.count,512)
        XCTAssertEqual(selected.first?.positionRadius,nearby.positionRadius)
        let reversed=RayTracingLocalLightSelection.select(Array(([nearby]+remote).reversed()))
        XCTAssertEqual(selected.map(\.positionRadius),reversed.map(\.positionRadius))
        XCTAssertEqual(selected.first?.colorPower.w,4,"Selection must not add biased population compensation")
        XCTAssertTrue(RayTracingLocalLightSelection.select([nearby],limit:0).isEmpty)
    }

    func testFallbackLightSelectionRejectsNonfiniteAndDisabledLights() {
        let bad=RayTracingLight(positionRadius:.init(.nan,0,0,30),colorPower:.init(1,1,1,1))
        let off=RayTracingLight(positionRadius:.init(0,0,0,0),colorPower:.init(1,1,1,1))
        XCTAssertTrue(RayTracingLocalLightSelection.select([bad,off]).isEmpty)
    }

    func testDecodedMeshHasNoDownwardWaterPrimitiveInsideSubmergedPlantColumns() throws {
        registerAllBlocks()

        let columns: [(String, [(UInt16, Int)])] = [
            ("seagrass", [(B.seagrass, 0)]),
            ("tall_seagrass (both halves)", [(B.tall_seagrass, 0), (B.tall_seagrass, 8)]),
            ("kelp (falling meta 12)", [(B.kelp, 12)]),
            ("kelp_plant", [(B.kelp_plant, 0)]),
            ("sea_pickle", [(B.sea_pickle, 0)]),
            ("tube_coral", [(B.tube_coral, 0)]),
        ]

        for (name, column) in columns {
            let mesh = submergedAquaticPlantMesh(column)
            let decoded = try XCTUnwrap(RayTracingMeshDecoder.decode(mesh), "\(name)")
            XCTAssertEqual(decoded.indices.count, decoded.primitives.count * 3, "\(name)")

            let topY = Float(8 + column.count - 1)
            let interfaceHeight = topY + 1 // the plant-top / real-water boundary
            for (index, primitive) in decoded.primitives.enumerated() {
                guard primitive.material.z & 2 != 0, primitive.normalEmission.y < -0.5 else { continue }
                let p0 = decoded.positions[Int(decoded.indices[index * 3])]
                let p1 = decoded.positions[Int(decoded.indices[index * 3 + 1])]
                let p2 = decoded.positions[Int(decoded.indices[index * 3 + 2])]
                let center = (p0 + p1 + p2) / 3
                let insidePlantColumn = center.x >= 8 && center.x <= 9 && center.z >= 8 && center.z <= 9
                let atTheFalseInterface = abs(center.y - interfaceHeight) < 0.05
                XCTAssertFalse(insidePlantColumn && atTheFalseInterface,
                              "\(name): downward water-flagged primitive at the false interface above the plant")
            }
        }
    }
}
