import Foundation
import Metal
import simd
import XCTest
@testable import Elysium

final class RayTracingAlphaIntersectionTests: XCTestCase {
    // The production callback and pipeline factory execute on real Metal geometry.
    // Both BLAS and TLAS are deliberately opaque to verify the ray-level override.
    func testDeepAlphaStacksEntityCutoffsAndInstanceMasksOnGPU() throws {
        guard let device=MTLCreateSystemDefaultDevice(), device.supportsRaytracing else { throw XCTSkip("Requires native ray tracing") }
        let options = MTLCompileOptions()
        options.languageVersion = .version3_1
        let source=ELYSIUM_ENVIRONMENT_MSL+RAY_TRACING_MSL+"""
        kernel void queryProbe(instance_acceleration_structure scene [[buffer(0)]],
            device const RTInstance* instances [[buffer(1)]], constant RTTextures& textures [[buffer(2)]],
            device float4* output [[buffer(3)]], texture2d_array<float> atlas [[texture(0)]],
            intersection_function_table<triangle_data,instancing> functions [[buffer(5)]],
            uint id [[thread_position_in_grid]]) {
            ray r;r.origin=float3(float(id)*4,0,0);r.direction=float3(0,0,-1);r.min_distance=0.001;r.max_distance=256;
            RTSurface hit=rtIntersect(r,scene,instances,textures,atlas,functions,id==6?0x01:0xff);
            output[id]=float4(hit.hit?hit.distance:-1,0,0,0);
        }
        """

        let library = try device.makeLibrary(source: source, options: options)
        let alphaPipeline=try RayTracingAlphaPipeline(device:device,library:library,function:library.makeFunction(name:"queryProbe")!)!
        let pipeline=alphaPipeline.pipeline

        struct Primitive {
            var uv01=SIMD4<Float>(0,0,1,0)
            var uv2Light=SIMD4<Float>(0.5,1,1,0)
            var normalEmission=SIMD4<Float>(0,0,1,0)
            var material: SIMD4<UInt32>
            var textureGradientU=SIMD4<Float>.zero
            var textureGradientV=SIMD4<Float>.zero
        }
        struct Instance {
            var transform=matrix_identity_float4x4
            var normalTransform=matrix_identity_float4x4
            var previousFromCurrent=matrix_identity_float4x4
            var tint=SIMD4<Float>(1,1,1,0.5)
            var overlay=SIMD4<Float>.zero
            var info=SIMD4<UInt32>.zero
        }
        var vertices=[SIMD3<Float>](), primitives=[Primitive]()
        func surface(_ scenario: Int,_ distance: Float,_ layer: UInt32,_ flags: UInt32) {
            let x=Float(scenario)*4
            vertices += [.init(x-1,-1,-distance),.init(x+1,-1,-distance),.init(x,1,-distance)]
            primitives.append(.init(material:.init(0xffffff,layer,flags,0)))
        }
        for distance in 1...32 { surface(0,Float(distance),0,1) }
        surface(0,200,1,1)
        surface(1,1,0,0) // nominally opaque material still has a texture-alpha hole
        surface(1,2,2,1) // terrain alpha .2 * instance .5 fails .35 cutoff
        surface(1,6,1,1)
        surface(2,2,2,9) // entity skin alpha .2 passes .1 independently of tint .5
        surface(2,7,1,1)
        for distance in 1...128 { surface(3,Float(distance),0,1) }
        for (scenario,count) in [(4,96),(5,128)] {
            for distance in 1...count { surface(scenario,Float(distance),0,1) }
            surface(scenario,200,1,1)
        }
        surface(6,2,1,1);surface(7,2,1,1)
        surface(8,2,3,1);surface(8,7,1,1) // 178/255 * .5 is below terrain cutoff
        surface(9,2,4,1);surface(9,7,1,1) // 179/255 * .5 is above terrain cutoff
        func buffer<T>(_ values:[T])->MTLBuffer {
            values.withUnsafeBytes { device.makeBuffer(bytes:$0.baseAddress!,length:$0.count,options:.storageModeShared)! }
        }
        let vb=buffer(vertices),pb=buffer(primitives),ib=buffer([Instance()])
        let g=MTLAccelerationStructureTriangleGeometryDescriptor()
        g.vertexBuffer=vb;g.vertexStride=MemoryLayout<SIMD3<Float>>.stride;g.vertexFormat = .float3
        g.triangleCount=primitives.count;g.opaque=true
        g.primitiveDataBuffer=pb;g.primitiveDataStride=MemoryLayout<Primitive>.stride
        g.primitiveDataElementSize=MemoryLayout<Primitive>.stride
        let bd=MTLPrimitiveAccelerationStructureDescriptor();bd.geometryDescriptors=[g]
        let bs=device.accelerationStructureSizes(descriptor:bd)
        let blas=device.makeAccelerationStructure(size:bs.accelerationStructureSize)!
        let scratch=device.makeBuffer(length:bs.buildScratchBufferSize,options:.storageModePrivate)!
        var instance=MTLAccelerationStructureInstanceDescriptor()
        instance.transformationMatrix=MTLPackedFloat4x3(columns:(MTLPackedFloat3Make(1,0,0),MTLPackedFloat3Make(0,1,0),MTLPackedFloat3Make(0,0,1),MTLPackedFloat3Make(0,0,0)))
        instance.options = .opaque;instance.mask=0x02;instance.accelerationStructureIndex=0
        let idb=buffer([instance])
        let td=MTLInstanceAccelerationStructureDescriptor()
        td.instancedAccelerationStructures=[blas];td.instanceCount=1;td.instanceDescriptorBuffer=idb
        let ts=device.accelerationStructureSizes(descriptor:td)
        let scene=device.makeAccelerationStructure(size:ts.accelerationStructureSize)!
        let topScratch=device.makeBuffer(length:ts.buildScratchBufferSize,options:.storageModePrivate)!
        let textureDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false)
        textureDescriptor.textureType = .type2DArray;textureDescriptor.arrayLength=5;textureDescriptor.usage = .shaderRead
        let atlas=device.makeTexture(descriptor:textureDescriptor)!
        for (layer,alpha) in [UInt8(0),255,51,178,179].enumerated() {
            var pixel:[UInt8]=[255,255,255,alpha]
            atlas.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,slice:layer,withBytes:&pixel,bytesPerRow:4,bytesPerImage:4)
        }
        textureDescriptor.textureType = .type2D;textureDescriptor.arrayLength=1
        let skin=device.makeTexture(descriptor:textureDescriptor)!
        var pixel:[UInt8]=[255,255,255,51]
        skin.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&pixel,bytesPerRow:4)
        let argumentEncoder=library.makeFunction(name:"queryProbe")!.makeArgumentEncoder(bufferIndex:2)
        let textures=device.makeBuffer(length:argumentEncoder.encodedLength,options:.storageModeShared)!
        argumentEncoder.setArgumentBuffer(textures,offset:0)
        for index in 0..<512 { argumentEncoder.setTexture(skin,index:index) }
        argumentEncoder.setTexture(atlas,index:512)
        let alphaFunctions=alphaPipeline.makeTable(instances:ib,textures:textures)!
        let results=device.makeBuffer(length:10*MemoryLayout<SIMD4<Float>>.stride,options:.storageModeShared)!
        let queue=device.makeCommandQueue()!, command=queue.makeCommandBuffer()!
        let build=command.makeAccelerationStructureCommandEncoder()!
        build.build(accelerationStructure:blas,descriptor:bd,scratchBuffer:scratch,scratchBufferOffset:0)
        build.endEncoding()
        let topBuild=command.makeAccelerationStructureCommandEncoder()!
        topBuild.build(accelerationStructure:scene,descriptor:td,scratchBuffer:topScratch,scratchBufferOffset:0)
        topBuild.endEncoding()
        let compute=command.makeComputeCommandEncoder()!
        compute.setComputePipelineState(pipeline);compute.setAccelerationStructure(scene,bufferIndex:0)
        compute.setIntersectionFunctionTable(alphaFunctions,bufferIndex:5)
        compute.setBuffer(ib,offset:0,index:1);compute.setBuffer(textures,offset:0,index:2);compute.setBuffer(results,offset:0,index:3)
        compute.setTexture(atlas,index:0);compute.useResource(blas,usage:.read);compute.useResource(skin,usage:.read)
        compute.dispatchThreads(.init(width:10,height:1,depth:1),threadsPerThreadgroup:.init(width:4,height:1,depth:1))
        compute.endEncoding();command.commit();command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed,String(describing:command.error))
        guard command.status == .completed else { return }
        let values=results.contents().bindMemory(to:SIMD4<Float>.self,capacity:10)
        let expected:[Float]=[200,6,2,-1,200,200,-1,2,7,2]
        for index in 0..<10 { XCTAssertEqual(values[index].x,expected[index],accuracy:0.0001,"Scenario \(index)") }
        // Update only after the previous GPU submission has completed. The same
        // production callback must distinguish skin coverage from body opacity.
        func entityDepth(skinAlpha:UInt8,tint:Float=0.5)throws->Float {
            var pixel:[UInt8]=[255,255,255,skinAlpha]
            skin.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&pixel,bytesPerRow:4)
            var value=Instance();value.tint.w=tint
            withUnsafeBytes(of:&value) { ib.contents().copyMemory(from:$0.baseAddress!,byteCount:$0.count) }
            let command=try XCTUnwrap(queue.makeCommandBuffer()),encoder=try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline);encoder.setAccelerationStructure(scene,bufferIndex:0)
            encoder.setIntersectionFunctionTable(alphaFunctions,bufferIndex:5)
            encoder.setBuffer(ib,offset:0,index:1);encoder.setBuffer(textures,offset:0,index:2);encoder.setBuffer(results,offset:0,index:3)
            encoder.setTexture(atlas,index:0);encoder.useResource(blas,usage:.read);encoder.useResource(skin,usage:.read)
            encoder.dispatchThreads(.init(width:10,height:1,depth:1),threadsPerThreadgroup:.init(width:4,height:1,depth:1))
            encoder.endEncoding();command.commit();command.waitUntilCompleted()
            XCTAssertEqual(command.status,.completed,String(describing:command.error))
            return values[2].x
        }
        XCTAssertEqual(try entityDepth(skinAlpha:25),7,accuracy:0.0001,"Skin below .1 cuts out")
        XCTAssertEqual(try entityDepth(skinAlpha:26),2,accuracy:0.0001,"Skin above .1 remains independent of body fade")
        XCTAssertEqual(try entityDepth(skinAlpha:51,tint:0.024),-1,accuracy:0.0001,"Combined alpha below .005 is invisible")
        XCTAssertEqual(try entityDepth(skinAlpha:51,tint:0.026),2,accuracy:0.0001,"Combined alpha above .005 remains visible")
    }
}
