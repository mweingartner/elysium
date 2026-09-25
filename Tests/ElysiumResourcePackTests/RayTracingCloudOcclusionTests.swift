import Foundation
import Metal
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// Actual primary-ray regression: bright terrain behind a cloud slab must be occluded, not
/// merely surrounded by a cloudy sky. Emission and a black night sky isolate segment absorption
/// from changes in direct sunlight or the sky's diffuse contribution.
final class RayTracingCloudOcclusionTests: XCTestCase {
    private func environment(x: Float,y: Float,z: Float,clouds: Bool) -> AtmosphereUniforms {
        var env=AtmosphereUniforms()
        env.cameraTime = .init(x,y,z,0)
        env.sunDaylight = .init(0,-1,0,0)
        env.zenith = .zero; env.horizon = .zero; env.fogColor = .zero
        env.weather = .init(1,0,clouds ? 1:0,0)
        env.clouds = .init(192,248,8192,16)
        return env
    }

    private func cloudLocation(device: MTLDevice,queue: MTLCommandQueue) throws -> SIMD2<Float> {
        let probe="""
        kernel void cloud_locations(device float4* result [[buffer(0)]],
                                    constant ElyAtmosphereU& env [[buffer(1)]],
                                    uint index [[thread_position_in_grid]]) {
            float x=float(index%8)*192.0-664.0;
            float z=float(index/8)*192.0-664.0;
            float4 cloud=elyCloudLayerForRay(float3(x,280,z),float3(0,-1,0),env,120.0,true);
            result[index]=float4(x,cloud.a,z,0);
        }
        """
        let library=try device.makeLibrary(source:ELYSIUM_ENVIRONMENT_MSL+"\n"+probe,options:nil)
        let pipeline=try device.makeComputePipelineState(function:XCTUnwrap(library.makeFunction(name:"cloud_locations")))
        let output=try XCTUnwrap(device.makeBuffer(length:64*MemoryLayout<SIMD4<Float>>.stride,options:.storageModeShared))
        let command=try XCTUnwrap(queue.makeCommandBuffer())
        let encoder=try XCTUnwrap(command.makeComputeCommandEncoder())
        var env=environment(x:0,y:280,z:0,clouds:true)
        encoder.setComputePipelineState(pipeline); encoder.setBuffer(output,offset:0,index:0)
        encoder.setBytes(&env,length:MemoryLayout<AtmosphereUniforms>.stride,index:1)
        encoder.dispatchThreads(.init(width:64,height:1,depth:1),threadsPerThreadgroup:.init(width:8,height:1,depth:1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed,command.error?.localizedDescription ?? "Cloud-location GPU failure")
        let values=output.contents().bindMemory(to:SIMD4<Float>.self,capacity:64)
        let candidate=(0..<64).map { values[$0] }.min { $0.y<$1.y }!
        XCTAssertLessThan(candidate.y,0.35,"The fixed weather fixture must contain a substantial real cloud column")
        return .init(candidate.x,candidate.z)
    }

    private struct TerrainImage {
        var colors: [SIMD3<Float>]
        var depth: [Float]
        var mean: Float { colors.reduce(0) { $0+$1.x }/Float(colors.count) }
    }

    private func terrainImage(device: MTLDevice,queue: MTLCommandQueue,location: SIMD2<Float>,
                              cameraY: Float,clouds: Bool,fogStart: Float=1_000,fogEnd: Float=2_000,
                              fogColor: SIMD3<Float> = .zero,floorY: Int=160,floorWidth: Float=16,
                              gamma: Float=0.5,underwater: Bool=false) throws -> TerrainImage {
        let renderer=try XCTUnwrap(RayTracedWorldRenderer(device:device))
        renderer.resize(width:32,height:32)
        let tileDescriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false)
        tileDescriptor.textureType = .type2DArray; tileDescriptor.arrayLength=1
        tileDescriptor.usage = .shaderRead
        let atlas=try XCTUnwrap(device.makeTexture(descriptor:tileDescriptor))
        var white: UInt32=0xffffffff
        atlas.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,slice:0,
            withBytes:&white,bytesPerRow:4,bytesPerImage:4)
        let localY=Float(floorY%16)
        let positions:[SIMD3<Float>]=[.init(0,localY,0),.init(0,localY,16),
            .init(floorWidth,localY,16),.init(floorWidth,localY,0)]
        var words:[UInt32]=[]
        for position in positions {
            words += [position.x.bitPattern,position.y.bitPattern,position.z.bitPattern,
                      Float(0.5).bitPattern,Float(0.5).bitPattern,
                      1<<12 | 15<<17 | 1<<25,0xffffff]
        }
        let layer=MeshLayer(data:words,idx:[0,1,2,0,2,3],count:4)
        let empty=MeshLayer(data:[],idx:[],count:0)
        renderer.uploadSection(key:SectionKey(cx:Int(floor(location.x/16)),sy:floorY/16,cz:Int(floor(location.y/16))),minY:0,
            mesh:MeshOutput(opaque:layer,cutout:empty,translucent:empty))
        let projection=Elysium.mat4Perspective(fovYRad:6 * .pi/180,aspect:1,near:0.1,far:512)
        let view=Elysium.mat4LookDir(eye:.zero,dir:.init(0,-1,0),up:.init(0,0,1))
        let vp=projection*view
        var atmosphere=environment(x:location.x,y:cameraY,z:location.y,clouds:clouds)
        atmosphere.fogColor=SIMD4(fogColor,0)
        atmosphere.weather.w=underwater ? 1:0
        let frame=RayTracingFrame(viewProjection:vp,inverseViewProjection:vp.inverse,
            camera:.init(Double(location.x),Double(cameraY),Double(location.y)),
            atmosphere:atmosphere,renderDistance:256,gamma:gamma,
            shadows:false,worldIdentity:1,fogStart:fogStart,fogEnd:fogEnd,
            viewMatrix:view,projectionMatrix:projection)
        let command=try XCTUnwrap(queue.makeCommandBuffer())
        let color=try XCTUnwrap(renderer.render(command:command,frame:frame,atlas:atlas,entities:[]),renderer.diagnostics.status)
        let depth=try XCTUnwrap(renderer.depthTexture)
        let readback=try XCTUnwrap(device.makeBuffer(length:32*256,options:.storageModeShared))
        let depthReadback=try XCTUnwrap(device.makeBuffer(length:32*256,options:.storageModeShared))
        let blit=try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from:color,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:32,height:32,depth:1),
            to:readback,destinationOffset:0,destinationBytesPerRow:256,destinationBytesPerImage:32*256)
        blit.copy(from:depth,sourceSlice:0,sourceLevel:0,sourceOrigin:.init(x:0,y:0,z:0),sourceSize:.init(width:32,height:32,depth:1),
            to:depthReadback,destinationOffset:0,destinationBytesPerRow:256,destinationBytesPerImage:32*256)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed,command.error?.localizedDescription ?? "Terrain-cloud GPU failure")
        let pixels=readback.contents().bindMemory(to:UInt16.self,capacity:32*32*4)
        let values=(0..<(32*32)).map { SIMD3<Float>(Float(Float16(bitPattern:pixels[$0*4])),
            Float(Float16(bitPattern:pixels[$0*4+1])),Float(Float16(bitPattern:pixels[$0*4+2]))) }
        let depthValues=(0..<(32*32)).map { index in
            depthReadback.contents().advanced(by:(index/32)*256).assumingMemoryBound(to:Float.self)[index%32]
        }
        XCTAssertTrue(values.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        return TerrainImage(colors:values,depth:depthValues)
    }

    private func terrainMean(device: MTLDevice,queue: MTLCommandQueue,location: SIMD2<Float>,
                             cameraY: Float,clouds: Bool) throws -> Float {
        try terrainImage(device:device,queue:queue,location:location,cameraY:cameraY,clouds:clouds).mean
    }

    func testAboveAndInsideCloudOccludeTerrainButBelowCloudDoesNot() throws {
        guard let device=MTLCreateSystemDefaultDevice(),device.supportsRaytracing else {
            throw XCTSkip("Requires actual Metal ray tracing")
        }
        registerAllBlocks()
        let queue=try XCTUnwrap(device.makeCommandQueue())
        let location=try cloudLocation(device:device,queue:queue)
        let aboveClear=try terrainMean(device:device,queue:queue,location:location,cameraY:280,clouds:false)
        let aboveCloud=try terrainMean(device:device,queue:queue,location:location,cameraY:280,clouds:true)
        let insideClear=try terrainMean(device:device,queue:queue,location:location,cameraY:224,clouds:false)
        let insideCloud=try terrainMean(device:device,queue:queue,location:location,cameraY:224,clouds:true)
        let belowClear=try terrainMean(device:device,queue:queue,location:location,cameraY:180,clouds:false)
        let belowCloud=try terrainMean(device:device,queue:queue,location:location,cameraY:180,clouds:true)
        XCTAssertGreaterThan(aboveClear,1,"Bright floor must be the primary surface, not a ray miss")
        XCTAssertLessThan(aboveCloud,aboveClear*0.65,"Terrain behind the full cloud column must be obscured")
        XCTAssertLessThan(insideCloud,insideClear*0.85,"Flying inside the cloud must obscure the terrain below")
        XCTAssertEqual(belowCloud,belowClear,accuracy:0.08,"No foreground cloud absorption below its lower boundary")
    }

    func testFullyDistanceFoggedTerrainMatchesAdjacentRayMissAndGameplayFogStillWins() throws {
        guard let device=MTLCreateSystemDefaultDevice(),device.supportsRaytracing else {
            throw XCTSkip("Requires actual Metal ray tracing")
        }
        registerAllBlocks()
        let queue=try XCTUnwrap(device.makeCommandQueue())
        let location=try cloudLocation(device:device,queue:queue)
        let gray=SIMD3<Float>(repeating:0.8)
        let expected=pow(Float(0.8),Float(2.2))
        // Half of each view hits distant terrain, the other half misses. Compare against the
        // exact same view with the floor moved behind the camera, rather than an artificial
        // constant-fog mean: no loaded-world silhouette may remain in the real atmosphere.
        for clouds in [false,true] {
            let terrain=try terrainImage(device:device,queue:queue,location:location,cameraY:280,
                clouds:clouds,fogStart:32,fogEnd:80,fogColor:gray,floorWidth:8,gamma:0.8)
            let sky=try terrainImage(device:device,queue:queue,location:location,cameraY:280,
                clouds:clouds,fogStart:32,fogEnd:80,fogColor:gray,floorY:320,gamma:0.8)
            XCTAssertGreaterThan(terrain.depth.filter { $0<0.999999 }.count,400,"Fixture must contain adjacent real geometry hits")
            XCTAssertGreaterThan(terrain.depth.filter { $0>=0.999999 }.count,400,"Fixture must contain adjacent real ray misses")
            XCTAssertTrue(sky.depth.allSatisfy { $0>=0.999999 })
            for index in terrain.colors.indices {
                let actual=terrain.colors[index], reference=sky.colors[index]
                XCTAssertEqual(actual.x,reference.x,accuracy:0.002,"Distance-fog discontinuity at pixel \(index), clouds=\(clouds)")
                XCTAssertEqual(actual.y,reference.y,accuracy:0.002)
                XCTAssertEqual(actual.z,reference.z,accuracy:0.002)
            }
        }
        // The same cloud cannot punch through short-range blindness/lava/snow visibility.
        let gameplayCloud=try terrainImage(device:device,queue:queue,location:location,cameraY:280,
            clouds:true,fogStart:0,fogEnd:32,fogColor:gray)
        XCTAssertEqual(gameplayCloud.mean,expected,accuracy:0.002,"Short-range gameplay fog must remain the final visibility constraint")
    }

    func testUnderwaterPrimaryMissRetainsWaterTransportInsteadOfAnalyticAirSky() throws {
        guard let device=MTLCreateSystemDefaultDevice(),device.supportsRaytracing else {
            throw XCTSkip("Requires actual Metal ray tracing")
        }
        registerAllBlocks()
        let queue=try XCTUnwrap(device.makeCommandQueue())
        let location=SIMD2<Float>(8,8)
        let waterFog=SIMD3<Float>(0.2,0.45,0.65)
        let submerged=try terrainImage(device:device,queue:queue,location:location,cameraY:280,
            clouds:true,fogColor:waterFog,floorY:320,underwater:true)
        let submergedNoClouds=try terrainImage(device:device,queue:queue,location:location,cameraY:280,
            clouds:false,fogColor:waterFog,floorY:320,underwater:true)
        let air=try terrainImage(device:device,queue:queue,location:location,cameraY:280,
            clouds:false,fogColor:waterFog,floorY:320)
        XCTAssertTrue(submerged.depth.allSatisfy { $0>=0.999999 })
        for index in submerged.colors.indices {
            let water=submerged.colors[index], noClouds=submergedNoClouds.colors[index]
            XCTAssertEqual(water.x,noClouds.x,accuracy:0.002,"Camera-underwater rays must not receive air clouds")
            XCTAssertEqual(water.y,noClouds.y,accuracy:0.002)
            XCTAssertEqual(water.z,noClouds.z,accuracy:0.002)
        }
        let center=16*32+16
        XCTAssertGreaterThan(submerged.colors[center].z,air.colors[center].z+0.01,
            "Water scattering and transmitted underwater radiance must not be replaced by the black air sky")
    }
}
