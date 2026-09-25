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

    func testPrimitiveAndFrameABIExactlyMatchesMetal() {
        XCTAssertEqual(MemoryLayout<RayTracingPrimitive>.stride,64)
        XCTAssertEqual(MemoryLayout<RayTracingInstanceUniforms>.stride,240)
        XCTAssertEqual(MemoryLayout<RayTracingLight>.stride,32)
        XCTAssertEqual(MemoryLayout<RayTracingUniforms>.stride,416)
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
    }

    func testLayersKeepDistinctCutoutWaterAndGlassClassification() throws {
        XCTAssertEqual(try XCTUnwrap(decode(layer(),cutout:true)).primitives[0].material.z&7,1)
        XCTAssertEqual(try XCTUnwrap(decode(layer(),translucent:true)).primitives[0].material.z&7,4)
        XCTAssertEqual(try XCTUnwrap(decode(layer(animation:1),translucent:true)).primitives[0].material.z&7,2)
    }

    func testLavaKeepsEmissionAndPublishesAnActualSurfaceLight() throws {
        let value=try XCTUnwrap(decode(layer(animation:2,emissive:true)))
        XCTAssertEqual(value.primitives[0].normalEmission.w,5)
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
}
