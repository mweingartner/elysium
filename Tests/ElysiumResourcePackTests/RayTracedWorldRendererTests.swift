import Foundation
import Metal
import MetalFX
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// Real Metal integration: these tests build acceleration structures and read
/// the production path tracer's depth/radiance back from GPU textures. They do
/// not substitute CPU ray/triangle calculations for shader execution.
final class RayTracedWorldRendererTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private struct Fixture {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let renderer: RayTracedWorldRenderer
        let atlas: MTLTexture
    }

    private struct Image {
        let width: Int
        let height: Int
        let colorWidth: Int
        let colorHeight: Int
        let depth: [Float]
        let radiance: [SIMD4<Float>]
        func depthAt(_ x: Int, _ y: Int) -> Float { depth[y * width + x] }
        func colorAt(_ x: Int, _ y: Int) -> SIMD4<Float> { radiance[y * colorWidth + x] }
    }

    private let section = SectionKey(cx: 0, sy: 0, cz: 0)

    private func fixture(splitAlpha: Bool = false, slices: Int = 2, redTile: Int? = nil,
                         memoryBudgetOverride: Int? = nil, tileSize: Int = 16,
                         mipmapped: Bool = false) throws -> Fixture {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsRaytracing else {
            throw XCTSkip("Requires a Metal device with ray tracing support")
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        // Capability is known supported: a shader/pipeline failure is a test
        // failure, not an unsupported-device skip.
#if DEBUG
        let candidate = RayTracedWorldRenderer(device: device, memoryBudgetOverride: memoryBudgetOverride)
#else
        let candidate = RayTracedWorldRenderer(device: device)
#endif
        let renderer = try XCTUnwrap(candidate,
                                    "Production ray-tracing shader pipelines must compile")
        renderer.resize(width: 32, height: 32)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = tileSize; descriptor.height = tileSize; descriptor.arrayLength = slices
        descriptor.mipmapLevelCount = mipmapped ? 1 + Int(log2(Double(tileSize))) : 1
        descriptor.usage = .shaderRead
        let atlas = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        for slice in 0..<slices {
            for level in 0..<atlas.mipmapLevelCount {
                let size = max(1, tileSize >> level)
                var pixels = [UInt8](repeating: 255, count: size * size * 4)
                if slice == redTile {
                    for pixel in 0..<(size * size) {
                        pixels[pixel * 4 + 1] = 0; pixels[pixel * 4 + 2] = 0
                    }
                }
                if splitAlpha && slice == 0 {
                    for y in 0..<size { for x in 0..<(size / 2) { pixels[(y * size + x) * 4 + 3] = 0 } }
                }
                pixels.withUnsafeBytes { raw in
                    atlas.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: level, slice: slice,
                                  withBytes: raw.baseAddress!, bytesPerRow: size * 4, bytesPerImage: size * size * 4)
                }
            }
        }
        return Fixture(device: device, queue: queue, renderer: renderer, atlas: atlas)
    }

    private func plane(distance: Float, halfSize: Float = 2, tile: UInt32 = 0) -> MeshLayer {
        // The plane faces +Z. The camera faces -Z, matching the game's projection.
        let positions: [SIMD3<Float>] = [SIMD3(-halfSize, -halfSize, -distance),
            SIMD3(halfSize, -halfSize, -distance), SIMD3(halfSize, halfSize, -distance),
            SIMD3(-halfSize, halfSize, -distance)]
        let uv: [SIMD2<Float>] = [SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0), SIMD2(0, 0)]
        var words: [UInt32] = []
        for i in positions.indices {
            words.append(contentsOf: [positions[i].x.bitPattern, positions[i].y.bitPattern,
                positions[i].z.bitPattern, uv[i].x.bitPattern, uv[i].y.bitPattern,
                tile | (3 << 12) | (15 << 17), 0x00ffffff])
        }
        return MeshLayer(data: words, idx: [0, 1, 2, 0, 2, 3], count: 4)
    }

    private func mesh(opaque: MeshLayer? = nil, cutout: MeshLayer? = nil) -> MeshOutput {
        let empty = MeshLayer(data: [], idx: [], count: 0)
        return MeshOutput(opaque: opaque ?? empty, cutout: cutout ?? empty, translucent: empty)
    }

    private func frame(width: Int = 32, height: Int = 32, world: UInt64 = 1,
                       atlas: UInt64 = 1) -> RayTracingFrame {
        let projection = Elysium.mat4Perspective(fovYRad: 70 * .pi / 180,
                                        aspect: Float(width) / Float(height), near: 0.1, far: 128)
        var atmosphere = AtmosphereUniforms()
        atmosphere.weather.z = 0 // Stable cloud-free sky isolates geometry admission.
        atmosphere.sunDaylight = SIMD4<Float>(0, 0.8, 0.6, 1)
        return RayTracingFrame(viewProjection: projection, inverseViewProjection: projection.inverse,
            camera: .zero, atmosphere: atmosphere, renderDistance: 64,
            atlasGeneration: atlas, worldIdentity: world,
            viewMatrix: matrix_identity_float4x4, projectionMatrix: projection)
    }

    private func expectedDepth(distance: Float, frame: RayTracingFrame) -> Float {
        let clip = frame.viewProjection * SIMD4<Float>(0, 0, -distance, 1)
        return clip.z / clip.w
    }

    private func render(_ fixture: Fixture, frame: RayTracingFrame,
                        entities: [RayTracingEntityInstance] = []) throws -> Image {
        let command = try XCTUnwrap(fixture.queue.makeCommandBuffer())
        let color = try XCTUnwrap(fixture.renderer.render(command: command, frame: frame,
            atlas: fixture.atlas, entities: entities), fixture.renderer.diagnostics.status)
        let depth = try XCTUnwrap(fixture.renderer.depthTexture)
        XCTAssertTrue(fixture.renderer.diagnostics.ready)
        XCTAssertEqual(depth.pixelFormat, .r32Float)
        XCTAssertEqual(color.pixelFormat, .rgba16Float)
        let width = depth.width, height = depth.height
        // Blit row alignment is honored even for the small non-power-of-two resize fixture.
        let depthStride = ((width * 4 + 255) / 256) * 256
        let colorStride = ((color.width * 8 + 255) / 256) * 256
        let depthBytes = try XCTUnwrap(fixture.device.makeBuffer(length: depthStride * height,
                                                                options: .storageModeShared))
        let colorBytes = try XCTUnwrap(fixture.device.makeBuffer(length: colorStride * color.height,
                                                                options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: width, height: height, depth: 1), to: depthBytes,
                  destinationOffset: 0, destinationBytesPerRow: depthStride,
                  destinationBytesPerImage: depthStride * height)
        blit.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: color.width, height: color.height, depth: 1), to: colorBytes,
                  destinationOffset: 0, destinationBytesPerRow: colorStride,
                  destinationBytesPerImage: colorStride * color.height)
        blit.endEncoding()
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "GPU command failed")
        if command.status != .completed { throw NSError(domain: "RayTracingGPUFixture", code: 1) }
        var depths: [Float] = [], colors: [SIMD4<Float>] = []
        for y in 0..<height {
            let depthRow = depthBytes.contents().advanced(by: y * depthStride).assumingMemoryBound(to: Float.self)
            for x in 0..<width { depths.append(depthRow[x]) }
        }
        for y in 0..<color.height {
            let colorRow = colorBytes.contents().advanced(by: y * colorStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<color.width {
                colors.append(SIMD4<Float>(Float(Float16(bitPattern: colorRow[x * 4])),
                    Float(Float16(bitPattern: colorRow[x * 4 + 1])),
                    Float(Float16(bitPattern: colorRow[x * 4 + 2])),
                    Float(Float16(bitPattern: colorRow[x * 4 + 3]))))
            }
        }
        XCTAssertTrue(depths.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertTrue(colors.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
        return Image(width: width, height: height,colorWidth:color.width,colorHeight:color.height,
                     depth: depths, radiance: colors)
    }

    func testLocalLightVolumeBrightensCaveWithoutStaticProxyDoubleCountingAndResetsOnSourceEdit() throws {
        let f=try fixture()
        var view=frame()
        view.atmosphere.options.x=1 // No sun/moon; isolates the local underground term.
        view.atmosphere.fogColor = .zero
        view.atmosphere.zenith = .zero; view.atmosphere.horizon = .zero
        let originalWall=plane(distance:4,halfSize:8)
        var wallWords=originalWall.data
        for vertex in 0..<originalWall.count { wallWords[vertex*7+5] &= ~(UInt32(15)<<17) }
        let wall=MeshLayer(data:wallWords,idx:originalWall.idx,count:originalWall.count)
        f.renderer.uploadSection(key:section,minY:0,mesh:mesh(opaque:wall))
        let descriptor=MTLTextureDescriptor()
        descriptor.textureType = .type3D; descriptor.pixelFormat = .rgba8Unorm
        descriptor.width=64; descriptor.height=64; descriptor.depth=64
        descriptor.usage = .shaderRead
        func volume(level: UInt8) throws -> MTLTexture {
            let texture=try XCTUnwrap(f.device.makeTexture(descriptor:descriptor))
            var pixels=[UInt8](repeating:255,count:64*64*64*4)
            for i in 0..<(64*64*64) { pixels[i*4+3]=level }
            pixels.withUnsafeBytes { texture.replace(region:MTLRegionMake3D(0,0,0,64,64,64),mipmapLevel:0,slice:0,
                withBytes:$0.baseAddress!,bytesPerRow:64*4,bytesPerImage:64*64*4) }
            return texture
        }
        view.localLightTexture=try volume(level:0)
        view.localLightOrigin = .init(-32,-32,-32); view.localLightGeneration=1
        let dark=try render(f,frame:view).radiance[16*32+16]
        view.localLightTexture=try volume(level:192); view.localLightGeneration=2
        let lit=try render(f,frame:view).radiance[16*32+16]
        XCTAssertEqual(f.renderer.diagnostics.historySamples,1,"Source edits must discard old dark illumination")
        XCTAssertGreaterThan(lit.x,dark.x+0.25)
        XCTAssertLessThan(lit.x,dark.x+0.35,"Nearby diffuse lamp response must remain below the washed-out unit response")
        XCTAssertGreaterThan(dark.x,0.035,"Display encoding preserves this deliberately dim linear cave floor")
        XCTAssertLessThan(dark.x,0.06,"The cave visibility floor must not illuminate a room like daylight")
        view.localLightOrigin = .init(-33,-32,-32)
        _=try render(f,frame:view)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,2,"Camera-only volume recentering is not a light-source edit")

        // Packed emitter power stays nonzero, but black source texels return no secondary
        // radiance. This isolates duplicate static proxy lighting; an ordinary white emitter
        // can legitimately brighten this wall through diffuse bounce rays even with a field.
        var black=[UInt8](repeating:0,count:16*16*4)
        for pixel in 0..<(16*16) { black[pixel*4+3]=255 }
        black.withUnsafeBytes { f.atlas.replace(region:MTLRegionMake2D(0,0,16,16),mipmapLevel:0,slice:1,
            withBytes:$0.baseAddress!,bytesPerRow:16*4,bytesPerImage:16*16*4) }
        let emitterPlane=plane(distance:1,halfSize:1,tile:1)
        var emitterWords=emitterPlane.data
        for vertex in 0..<emitterPlane.count {
            emitterWords[vertex*7]=(Float(bitPattern:emitterWords[vertex*7])+4.5).bitPattern
            emitterWords[vertex*7+5] = 1 | (2<<12) | (1<<25)
        }
        let emitter=MeshLayer(data:emitterWords,idx:emitterPlane.idx,count:emitterPlane.count)
        let extra=SectionKey(cx:0,sy:1,cz:0)
        f.renderer.uploadSection(key:extra,minY:-16,mesh:mesh(opaque:emitter))
        let after=try render(f,frame:view).radiance[16*32+16]
        XCTAssertEqual(after.x,lit.x,accuracy:0.06,"The static field replaces, not duplicates, mesh proxy lighting")
        view.localLightTexture=try volume(level:0); view.localLightGeneration=3
        let off=try render(f,frame:view).radiance[16*32+16]
        XCTAssertLessThan(off.x,lit.x*0.3)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,1)
    }

    func testEnclosedWhiteRoomDoesNotMultiplyPropagatedLightOrCaveFillAcrossDiffuseBounces() throws {
        let f=try fixture()
        var view=frame()
        view.atmosphere.options.x=1 // Disable directional lighting; the surrounding sky is black.
        view.atmosphere.fogColor = .zero
        view.atmosphere.zenith = .zero; view.atmosphere.horizon = .zero
        view.localLightOrigin = .init(-32,-32,-32)

        func room(enclosed: Bool) -> MeshOutput {
            var data:[UInt32]=[],indices:[UInt32]=[]
            func quad(_ points: [SIMD3<Float>],normal: UInt32) {
                let base=UInt32(data.count/7)
                let uv:[SIMD2<Float>]=[.init(0,0),.init(1,0),.init(1,1),.init(0,1)]
                for i in 0..<4 {
                    let p=points[i]
                    // Unit-albedo white, no emission and zero cached block/sky light.
                    data += [p.x.bitPattern,p.y.bitPattern,p.z.bitPattern,uv[i].x.bitPattern,
                             uv[i].y.bitPattern,normal<<12,0xffffff]
                }
                indices += [base,base+1,base+2,base,base+2,base+3]
            }
            quad([.init(-8,-8,-4),.init(8,-8,-4),.init(8,8,-4),.init(-8,8,-4)],normal:3)
            if enclosed {
                // Every diffuse ray leaving the front wall hits another white wall. This is
                // the worst case for accidentally re-adding the same propagated solution.
                quad([.init(-8,-8,4),.init(-8,8,4),.init(8,8,4),.init(8,-8,4)],normal:2)
                quad([.init(-8,-8,-4),.init(-8,8,-4),.init(-8,8,4),.init(-8,-8,4)],normal:5)
                quad([.init(8,-8,-4),.init(8,-8,4),.init(8,8,4),.init(8,8,-4)],normal:4)
                quad([.init(-8,-8,-4),.init(-8,-8,4),.init(8,-8,4),.init(8,-8,-4)],normal:1)
                quad([.init(-8,8,-4),.init(8,8,-4),.init(8,8,4),.init(-8,8,4)],normal:0)
            }
            return mesh(opaque:MeshLayer(data:data,idx:indices,count:data.count/7))
        }
        func volume(level: UInt8) throws -> MTLTexture {
            let descriptor=MTLTextureDescriptor()
            descriptor.textureType = .type3D; descriptor.pixelFormat = .rgba8Unorm
            descriptor.width=64; descriptor.height=64; descriptor.depth=64
            descriptor.usage = .shaderRead
            let texture=try XCTUnwrap(f.device.makeTexture(descriptor:descriptor))
            var pixels=[UInt8](repeating:255,count:64*64*64*4)
            for i in 0..<(64*64*64) { pixels[i*4+3]=level }
            pixels.withUnsafeBytes { texture.replace(region:MTLRegionMake3D(0,0,0,64,64,64),mipmapLevel:0,slice:0,
                withBytes:$0.baseAddress!,bytesPerRow:64*4,bytesPerImage:64*64*4) }
            return texture
        }
        func centerMean(_ image: Image) -> Float {
            var result: Float=0
            for y in 12..<20 { for x in 12..<20 { result+=image.radiance[y*image.width+x].x } }
            return result/64
        }

        for level in [UInt8(0),128] {
            view.localLightTexture=try volume(level:level)
            view.localLightGeneration+=1
            f.renderer.uploadSection(key:section,minY:0,mesh:room(enclosed:false))
            let open=try render(f,frame:view)
            f.renderer.uploadSection(key:section,minY:0,mesh:room(enclosed:true))
            let closed=try render(f,frame:view)
            XCTAssertEqual(f.renderer.diagnostics.triangles,12,"All six enclosing faces must enter the actual ray scene")
            let openLight=centerMean(open),closedLight=centerMean(closed)
            let normalized=Float(level)/255
            let expected=Float(0.045)+0.40*RenderLocalLightPolicy.outputMultiplier*normalized/(4-3*normalized)
            XCTAssertEqual(openLight,expected,accuracy:0.015)
            XCTAssertEqual(closedLight,openLight,accuracy:0.015,
                "Reflective enclosure must not turn one diffuse illumination cache into three copies")
            if level == 0 {
                XCTAssertGreaterThan(closedLight,0.035,"The dark room retains a dim readable floor")
                XCTAssertLessThan(closedLight,0.06,"The floor is not compounded by secondary bounces")
            } else {
                XCTAssertGreaterThan(closedLight,0.15,"A lamp must still produce useful local illumination")
                XCTAssertLessThan(closedLight,0.22,"Moderate cached light must not become daylight in an enclosure")
            }
        }
    }

    func testFallbackLocalLightingIsNotDimmedByMoreThan512RemoteEmissiveFaces() throws {
        let f=try fixture()
        var view=frame()
        view.atmosphere.options.x=1; view.atmosphere.fogColor = .zero
        view.atmosphere.zenith = .zero; view.atmosphere.horizon = .zero
        let wall=plane(distance:4,halfSize:8)
        func source(x: Float) -> MeshLayer {
            let base=plane(distance:1.5,halfSize:0.5)
            var words=base.data
            for vertex in 0..<base.count {
                words[vertex*7]=(Float(bitPattern:words[vertex*7])+x).bitPattern
                words[vertex*7+5] = (2<<12) | (1<<25)
            }
            return MeshLayer(data:words,idx:base.idx,count:base.count)
        }
        func scene(remote: Bool) -> MeshOutput {
            let layers=[wall,source(x:2)] + (remote ? (0..<600).map { source(x:Float(100+$0)) }:[])
            var data:[UInt32]=[],indices:[UInt32]=[]
            for layer in layers {
                let base=UInt32(data.count/7)
                data+=layer.data; indices+=layer.idx.map { $0+base }
            }
            return mesh(opaque:MeshLayer(data:data,idx:indices,count:data.count/7))
        }
        f.renderer.uploadSection(key:section,minY:0,mesh:scene(remote:false))
        let local=try render(f,frame:view).radiance[16*32+16]
        XCTAssertGreaterThan(local.x,0.08,"A real shadow ray must carry nearby emitter light to the cave wall")
        f.renderer.uploadSection(key:section,minY:0,mesh:scene(remote:true))
        let crowded=try render(f,frame:view).radiance[16*32+16]
        XCTAssertEqual(crowded.x,local.x,accuracy:0.035)
        XCTAssertEqual(crowded.y,local.y,accuracy:0.035)
        XCTAssertEqual(crowded.z,local.z,accuracy:0.035)
    }

    func testPrimaryRaysHitPlaneAndMissToLitSky() throws {
        let f = try fixture(), view = frame()
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 4)))
        let image = try render(f, frame: view)
        XCTAssertEqual(image.depthAt(16, 16), expectedDepth(distance: 4, frame: view), accuracy: 0.00001)
        XCTAssertEqual(image.depthAt(0, 0), 1, accuracy: 0.00001)
        let sky = image.radiance[0]
        XCTAssertGreaterThan(sky.x + sky.y + sky.z, 0.05)
        XCTAssertEqual(f.renderer.diagnostics.triangles, 2)
        XCTAssertEqual(f.renderer.diagnostics.instances, 1)
    }

    func testAlphaCutoutRaysContinueToOpaqueGeometryBehindIt() throws {
        let f = try fixture(splitAlpha: true), view = frame()
        f.renderer.uploadSection(key: section, minY: 0,
            mesh: mesh(opaque: plane(distance: 6, halfSize: 4, tile: 1),
                       cutout: plane(distance: 3, halfSize: 2, tile: 0)))
        let image = try render(f, frame: view)
        XCTAssertEqual(image.depthAt(8, 16), expectedDepth(distance: 6, frame: view), accuracy: 0.00001,
                       "Transparent atlas pixels must not become an invisible ray blocker")
        XCTAssertEqual(image.depthAt(24, 16), expectedDepth(distance: 3, frame: view), accuracy: 0.00001)
    }

    func testNativeSurfaceResolvePreservesFullResolutionCutoutDepthAndCameraMedia() throws {
        let f=try fixture(splitAlpha:true,redTile:1)
        guard #available(macOS 26.0, *),
              MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(f.device) else {
            throw XCTSkip("Requires native lighting denoising")
        }
        f.renderer.uploadSection(key:section,minY:0,
            mesh:mesh(opaque:plane(distance:6,halfSize:4,tile:1),
                      cutout:plane(distance:3,halfSize:2,tile:0)))
        let small=try render(f,frame:frame())
        XCTAssertEqual(small.width,32); XCTAssertEqual(small.height,32)
        XCTAssertEqual(small.colorWidth,32); XCTAssertEqual(small.colorHeight,32)
        f.renderer.resize(width:1920,height:1080)
        var view=frame(width:1920,height:1080)
        var upscaled=try render(f,frame:view)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,1)
        for _ in 0..<2 { upscaled=try render(f,frame:view) }
        XCTAssertEqual(f.renderer.diagnostics.denoiser,"MetalFX temporal denoising")
        XCTAssertEqual(upscaled.width,1920); XCTAssertEqual(upscaled.height,1080)
        XCTAssertEqual(upscaled.colorWidth,1920); XCTAssertEqual(upscaled.colorHeight,1080)
        XCTAssertEqual(f.renderer.diagnostics.width,640); XCTAssertEqual(f.renderer.diagnostics.height,360)
        XCTAssertEqual(f.renderer.diagnostics.outputWidth,1920); XCTAssertEqual(f.renderer.diagnostics.outputHeight,1080)
        XCTAssertEqual(upscaled.depthAt(720,540),expectedDepth(distance:6,frame:view),accuracy:0.00001,
            "Native primary rays must see through the transparent half")
        XCTAssertEqual(upscaled.depthAt(1200,540),expectedDepth(distance:3,frame:view),accuracy:0.00001,
            "Low-rate lighting must not reduce visible geometry or overlay depth resolution")
        let red=upscaled.colorAt(720,540),white=upscaled.colorAt(1200,540)
        XCTAssertGreaterThan(red.x-red.y,0.05,"The alpha opening must show the red backing surface")
        XCTAssertGreaterThan(white.y-red.y,0.1,"Reconstruction must preserve both sides of the authored cutout")

        // This is the complete renderer output after rt_media, not just MetalFX's output.
        // A short gameplay-fog mask has an analytic answer at every output pixel, including
        // pixels beyond the lighting texture's physical width/height.
        view.fogStart=0.01; view.fogEnd=1
        view.atmosphere.fogColor = .init(0.4,0.6,0.8,1)
        let fogged=try render(f,frame:view)
        let expected=SIMD3<Float>(pow(0.4,2.2),pow(0.6,2.2),pow(0.8,2.2))
        for y in stride(from:0,to:fogged.colorHeight,by:67) {
            for x in stride(from:0,to:fogged.colorWidth,by:71) {
                let actual=fogged.colorAt(x,y)
                for channel in 0..<3 { XCTAssertEqual(actual[channel],expected[channel],accuracy:0.001) }
            }
        }
        XCTAssertEqual(fogged.depthAt(720,540),expectedDepth(distance:6,frame:view),accuracy:0.00001,
            "Camera fog must not overwrite the depth used by raster overlays")

        f.renderer.resize(width:48,height:24)
        let restoredView=frame(width:48,height:24)
        let restored=try render(f,frame:restoredView)
        XCTAssertEqual(restored.width,48); XCTAssertEqual(restored.height,24)
        XCTAssertEqual(restored.colorWidth,48); XCTAssertEqual(restored.colorHeight,24)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,1)
        XCTAssertEqual(restored.depthAt(18,12),expectedDepth(distance:6,frame:restoredView),accuracy:0.00001)
        XCTAssertEqual(restored.depthAt(30,12),expectedDepth(distance:3,frame:restoredView),accuracy:0.00001)
        _=try render(f,frame:restoredView)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,2,
            "After resizing back, correctly sized resources must resume normal temporal history")
    }

    /// Rotates the standard "camera looks along -Z" frame so its forward axis points down world
    /// -Y, letting a horizontal (Y-up) water/seabed pair reuse the same local-space, distance-based
    /// vertex math as `plane()`/`nativeDetailPlane()`. Robust to whichever handedness `simd_quatf`
    /// happens to use: it measures the actual transform and flips the pitch if needed, so the
    /// camera always ends up looking down at freshly built geometry, never up past it.
    private func lookingDownFrame(width: Int, height: Int) -> (view: RayTracingFrame, worldFromView: simd_float4x4) {
        var view = frame(width: width, height: height)
        func viewMatrix(_ angle: Float) -> simd_float4x4 {
            simd_float4x4(simd_quatf(angle: angle, axis: SIMD3<Float>(1, 0, 0)))
        }
        var candidate = viewMatrix(.pi / 2)
        if (candidate.inverse * SIMD4<Float>(0, 0, -1, 0)).y > 0 { candidate = viewMatrix(-.pi / 2) }
        view.viewMatrix = candidate
        view.viewProjection = view.projectionMatrix * candidate
        view.inverseViewProjection = view.viewProjection.inverse
        return (view, candidate.inverse)
    }

    func testTopWaterSeenFromAirInSeparatedSurfaceModeIsFiniteAtNativeResolution() throws {
        let f = try fixture(redTile: 1)
        guard #available(macOS 26.0, *),
              MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(f.device) else {
            throw XCTSkip("Requires the split-rate native surface (MetalFX) path")
        }
        f.renderer.resize(width: 1440, height: 810)
        let (view, worldFromView) = lookingDownFrame(width: 1440, height: 810)

        // Raw normal (0,1,0): the shader always flips it to face the incoming ray, so this
        // choice is not load-bearing for which side the camera is actually looking from.
        func quad(_ local: [SIMD3<Float>], tile: UInt32, anim: UInt32 = 0) -> MeshLayer {
            let uv: [SIMD2<Float>] = [.init(0, 1), .init(1, 1), .init(1, 0), .init(0, 0)]
            var words: [UInt32] = []
            for i in 0..<4 {
                let w = worldFromView * SIMD4<Float>(local[i], 1)
                let p = SIMD3<Float>(w.x, w.y, w.z)
                words += [p.x.bitPattern, p.y.bitPattern, p.z.bitPattern, uv[i].x.bitPattern, uv[i].y.bitPattern,
                          tile | (1 << 12) | (15 << 17), 0xffffff | (anim << 24)]
            }
            return MeshLayer(data: words, idx: [0, 1, 2, 0, 2, 3], count: 4)
        }

        let waterDistance: Float = 4, seabedDepth: Float = 2
        let waterHalfX = waterDistance / view.projectionMatrix[0][0]
        let waterHalfY = waterDistance / view.projectionMatrix[1][1]
        let totalDistance = waterDistance + seabedDepth
        let seabedHalfX = totalDistance / view.projectionMatrix[0][0]
        let seabedHalfY = totalDistance / view.projectionMatrix[1][1]
        let water = quad([.init(-waterHalfX, -waterHalfY, -waterDistance), .init(waterHalfX, -waterHalfY, -waterDistance),
                          .init(waterHalfX, waterHalfY, -waterDistance), .init(-waterHalfX, waterHalfY, -waterDistance)],
                         tile: 0, anim: 1) // anim=1 marks this primitive as water regardless of mesh layer.
        let seabedZ = -totalDistance
        // White (tile 0) and red (tile 1) halves split exactly at local/world x = 0: a ray down
        // the camera's own axis refracts with zero deflection, so this boundary is not smeared
        // by the water above it, only attenuated and tinted by it.
        let white = quad([.init(-seabedHalfX, -seabedHalfY, seabedZ), .init(0, -seabedHalfY, seabedZ),
                          .init(0, seabedHalfY, seabedZ), .init(-seabedHalfX, seabedHalfY, seabedZ)], tile: 0)
        let red = quad([.init(0, -seabedHalfY, seabedZ), .init(seabedHalfX, -seabedHalfY, seabedZ),
                        .init(seabedHalfX, seabedHalfY, seabedZ), .init(0, seabedHalfY, seabedZ)], tile: 1)
        let combined = MeshLayer(data: water.data + white.data + red.data,
            idx: water.idx + white.idx.map { $0 + 4 } + red.idx.map { $0 + 8 }, count: 12)
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: combined))

        var image = try render(f, frame: view)
        for _ in 0..<2 { image = try render(f, frame: view) }
        XCTAssertEqual(f.renderer.diagnostics.denoiser, "MetalFX temporal denoising")
        XCTAssertEqual(image.colorWidth, 1440); XCTAssertEqual(image.colorHeight, 810)
        XCTAssertEqual(f.renderer.diagnostics.outputWidth, 1440); XCTAssertEqual(f.renderer.diagnostics.outputHeight, 810)
        XCTAssertLessThan(f.renderer.diagnostics.width, image.colorWidth,
            "This must actually exercise the separated-surface (below-native lighting) path")

        // `render()` already requires every value to be finite; add the non-negative half here.
        for pixel in image.radiance {
            for channel in 0..<4 {
                XCTAssertGreaterThanOrEqual(pixel[channel], 0, "Ray-traced radiance must never go negative")
            }
        }

        // A native-resolution seabed texture edge: sample redness (R minus the other channels)
        // along the center row and require the transition near the center to be only a few
        // native pixels wide, not smeared to the width of a low-resolution lighting texel.
        let centerY = image.colorHeight / 2
        let window = 600..<840
        let redness = window.map { x -> Float in
            let c = image.colorAt(x, centerY); return c.x - max(c.y, c.z)
        }
        XCTAssertTrue(redness.contains { $0 < -0.01 }, "Some sampled column must show the white seabed tinted by water, not red")
        XCTAssertTrue(redness.contains { $0 > 0.02 }, "Some sampled column must show the red seabed through water")
        let maximumStep = zip(redness, redness.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        XCTAssertGreaterThan(maximumStep, 0.01,
            "The red/white boundary must resolve as a sharp native-resolution edge, not a blurred low-resolution one")
    }

    func testSelectionCacheRefreshesOnSectionUploadRemovalAndRenderDistanceChange() throws {
        let f = try fixture()
        let near = section
        let far = SectionKey(cx: 20, sy: 0, cz: 0) // world x = 20*16+8 = 328 blocks from the camera
        f.renderer.uploadSection(key: near, minY: 0, mesh: mesh(opaque: plane(distance: 4)))
        var view = frame(); view.renderDistance = 32 // range = 56: `far` (328) is excluded
        _ = try render(f, frame: view)
        XCTAssertEqual(f.renderer.diagnostics.sections, 1)

        // A distant upload stays outside the radius. Invalidating the cache on upload must
        // re-filter by distance, not blindly append the newly uploaded section.
        f.renderer.uploadSection(key: far, minY: 0, mesh: mesh(opaque: plane(distance: 6)))
        _ = try render(f, frame: view)
        XCTAssertEqual(f.renderer.diagnostics.sections, 1,
            "An out-of-range upload must not leak into the cached selection")

        // Widen the render distance alone: same camera, same section set. The cache key must
        // include `range`, not only the sections revision and the camera position.
        view.renderDistance = 512
        let widened = try render(f, frame: view)
        XCTAssertEqual(f.renderer.diagnostics.sections, 2,
            "Widening the render distance alone must refresh the cached selection")
        XCTAssertEqual(f.renderer.diagnostics.pendingSections, 0)
        XCTAssertEqual(widened.depthAt(16, 16), expectedDepth(distance: 4, frame: view), accuracy: 0.00001)

        // Removing the near section (render distance and camera unchanged) must drop it from
        // the very next selection rather than keep serving a stale cached entry.
        f.renderer.uploadSection(key: near, minY: 0, mesh: mesh())
        let afterRemoval = try render(f, frame: view)
        XCTAssertEqual(f.renderer.diagnostics.sections, 1,
            "Removing a section must refresh the cached selection")
        XCTAssertEqual(afterRemoval.depthAt(16, 16), 1, accuracy: 0.00001,
            "The removed section's geometry must no longer be selected for tracing")
    }

    /// Exactly three output pixels per authored atlas texel. Geometry spans the
    /// projection, so the native oracle is screen x/3,y/3 without CPU ray tracing.
    private func nativeDetailPlane(distance: Float, view: RayTracingFrame,
                                   tile: UInt32 = 0, left: Float = 0, right: Float = 1,
                                   emissive: Bool = false) -> MeshLayer {
        let halfX = distance / view.projectionMatrix[0][0]
        let halfY = distance / view.projectionMatrix[1][1]
        let positions: [SIMD3<Float>] = [.init((left * 2 - 1) * halfX,-halfY,-distance),
            .init((right * 2 - 1) * halfX,-halfY,-distance),
            .init((right * 2 - 1) * halfX,halfY,-distance),
            .init((left * 2 - 1) * halfX,halfY,-distance)]
        let uv: [SIMD2<Float>] = [.init(left * 30,16.875),.init(right * 30,16.875),
            .init(right * 30,0),.init(left * 30,0)] // 1440/48 by 810/48 repeats.
        var words: [UInt32] = []
        for index in 0..<4 {
            let p = positions[index]
            words += [p.x.bitPattern,p.y.bitPattern,p.z.bitPattern,uv[index].x.bitPattern,
                uv[index].y.bitPattern,tile | (3 << 12) | (15 << 21) | (emissive ? 1 << 25 : 0),0xffffff]
        }
        return MeshLayer(data: words,idx: [0,1,2,0,2,3],count: 4)
    }

    private func nativeDetailFixture(tileSize: Int = 16, mipmapped: Bool = true) throws -> (Fixture,RayTracingFrame) {
        let f = try fixture(tileSize:tileSize,mipmapped:mipmapped)
        guard #available(macOS 26.0, *),
              MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(f.device) else {
            throw XCTSkip("Requires the split-rate native surface path")
        }
        f.renderer.resize(width:1440,height:810)
        var view = frame(width:1440,height:810)
        view.atmosphere.options.x = 1 // No directional light or environment radiance.
        view.atmosphere.zenith = .zero; view.atmosphere.horizon = .zero
        view.atmosphere.fogColor = .zero
        return (f,view)
    }

    private func writeMinificationCheckerboard(_ atlas: MTLTexture) {
        // Each coarse texel covers equal areas of black and white. Encode their
        // independently known linear-light average, not the average encoded byte.
        let average = UInt8((pow(0.5,1.0/2.2) * 255).rounded())
        for level in 0..<atlas.mipmapLevelCount {
            let size = max(1,atlas.width >> level)
            var pixels = [UInt8](repeating:255,count:size * size * 4)
            for y in 0..<size { for x in 0..<size {
                let value: UInt8 = level == 0 ? ((x+y).isMultiple(of:2) ? 0 : 255) : average
                let offset = (y * size + x) * 4
                pixels[offset] = value; pixels[offset+1] = value; pixels[offset+2] = value
            }}
            pixels.withUnsafeBytes { atlas.replace(region:MTLRegionMake2D(0,0,size,size),
                mipmapLevel:level,slice:0,withBytes:$0.baseAddress!,
                bytesPerRow:size * 4,bytesPerImage:size * size * 4) }
        }
    }

    private func minificationPlane(repetitions: SIMD2<Float>) -> MeshLayer {
        let original = plane(distance:4,halfSize:32)
        var words = original.data
        for vertex in 0..<original.count {
            words[vertex * 7 + 3] = (Float(bitPattern:words[vertex * 7 + 3]) * repetitions.x).bitPattern
            words[vertex * 7 + 4] = (Float(bitPattern:words[vertex * 7 + 4]) * repetitions.y).bitPattern
            words[vertex * 7 + 5] = (3 << 12) | (15 << 21) // Exact constant cached illumination.
        }
        return MeshLayer(data:words,idx:original.idx,count:original.count)
    }

    func testNativeSurfaceMinificationAveragesSubpixelTexelsAndRemainsStableDuringCameraMotion() throws {
        let (f,view) = try nativeDetailFixture(tileSize:64,mipmapped:true)
        writeMinificationCheckerboard(f.atlas)
        // More than three texels fit in one output pixel, despite being only four
        // world units from the camera. Distance alone cannot determine texture LOD.
        f.renderer.uploadSection(key:section,minY:0,
            mesh:mesh(opaque:minificationPlane(repetitions:.init(1024,1024))))
        let initial = try render(f,frame:view)
        var movedView = view
        movedView.camera.x = 0.0008; movedView.camera.y = 0.0006
        movedView.atmosphere.cameraTime.x = 0.0008; movedView.atmosphere.cameraTime.y = 0.0006
        let moved = try render(f,frame:movedView)
        XCTAssertEqual(f.renderer.diagnostics.denoiser,"MetalFX temporal denoising")
        XCTAssertEqual(initial.colorWidth,1440); XCTAssertEqual(initial.colorHeight,810)
        let expected: Float = 0.5 * (0.4 * RenderLocalLightPolicy.outputMultiplier)
        var maximumError: Float = 0, maximumMotionChange: Float = 0
        for y in 300..<492 { for x in 600..<840 {
            for channel in 0..<3 {
                maximumError = max(maximumError,abs(initial.colorAt(x,y)[channel]-expected),
                                   abs(moved.colorAt(x,y)[channel]-expected))
                maximumMotionChange = max(maximumMotionChange,
                    abs(initial.colorAt(x,y)[channel]-moved.colorAt(x,y)[channel]))
            }
        }}
        XCTAssertLessThan(maximumError,0.008,
            "A subpixel checkerboard must resolve to its linear area average on the first frame")
        XCTAssertLessThan(maximumMotionChange,0.004,
            "Subpixel camera movement must not exchange black and white nearest texels")
    }

    func testNativeSurfaceMinificationUsesProjectedFootprintForObliqueUnequalUVDensity() throws {
        let (f,baseView) = try nativeDetailFixture(tileSize:64,mipmapped:true)
        writeMinificationCheckerboard(f.atlas)
        // One UV axis is highly minified while the other is magnified. A grazing
        // camera adds perspective variation across the same axis-aligned wall.
        f.renderer.uploadSection(key:section,minY:0,
            mesh:mesh(opaque:minificationPlane(repetitions:.init(1024,0.0625))))
        var view = baseView
        view.viewMatrix = simd_float4x4(simd_quatf(angle:Float.pi/3,axis:.init(0,1,0)))
        view.viewProjection = view.projectionMatrix * view.viewMatrix
        view.inverseViewProjection = view.viewProjection.inverse
        let image = try render(f,frame:view)
        let expected: Float = 0.5 * (0.4 * RenderLocalLightPolicy.outputMultiplier)
        var maximumError: Float = 0
        for y in stride(from:300,to:492,by:3) { for x in 600..<840 {
            XCTAssertLessThan(image.depthAt(x,y),1,"The oblique fixture must hit the wall")
            for channel in 0..<3 {
                maximumError = max(maximumError,abs(image.colorAt(x,y)[channel]-expected))
            }
        }}
        XCTAssertLessThan(maximumError,0.008,
            "UV density and grazing incidence must select filtered texels without losing average energy")
    }

    func testNativeSurfaceResolvePreservesThreePixelAuthoredDetailIncludingBlackTexels() throws {
        let (f,view) = try nativeDetailFixture()
        func texel(_ x: Int,_ y: Int) -> UInt8 {
            if x % 16 == 15 && y % 16 == 15 { return 0 }
            return (x+y).isMultiple(of:2) ? 64:224
        }
        var pixels: [UInt8] = []
        for y in 0..<16 { for x in 0..<16 {
            let value = texel(x,y); pixels += [value,value,value,255]
        }}
        pixels.withUnsafeBytes { f.atlas.replace(region:MTLRegionMake2D(0,0,16,16),mipmapLevel:0,slice:0,
            withBytes:$0.baseAddress!,bytesPerRow:64,bytesPerImage:1024) }
        f.renderer.uploadSection(key:section,minY:0,mesh:mesh(opaque:nativeDetailPlane(distance:4,view:view)))
        var image = try render(f,frame:view)
        for _ in 0..<3 { image = try render(f,frame:view) }
        XCTAssertEqual(image.width,1440); XCTAssertEqual(image.height,810)
        XCTAssertEqual(f.renderer.diagnostics.width,640); XCTAssertEqual(f.renderer.diagnostics.height,360)
        var squaredError = 0.0, maximumError: Float = 0, dark = 0.0, bright = 0.0
        var darkCount = 0, brightCount = 0, blackCount = 0, maximumBlack: Float = 0
        for y in 300..<492 { for x in 600..<840 {
            let authored = texel(x/3,y/3)
            let expected = pow(Float(authored)/255,2.2) * (0.4 * RenderLocalLightPolicy.outputMultiplier)
            let actual = image.colorAt(x,y).x
            let error = abs(actual-expected)
            maximumError = max(maximumError,error); squaredError += Double(error*error)
            if authored == 0 { blackCount += 1; maximumBlack = max(maximumBlack,abs(actual)) }
            else if authored == 64 { dark += Double(actual); darkCount += 1 }
            else { bright += Double(actual); brightCount += 1 }
        }}
        XCTAssertLessThan(squaredError / Double(192*240),0.0001,
            "Final GPU image must match the analytic full-resolution authored texture")
        XCTAssertLessThan(maximumError,0.025,"Texel edges must not acquire interpolated material colors")
        XCTAssertGreaterThan(bright/Double(brightCount)-dark/Double(darkCount),0.45,
            "Keep the fine-detail contrast bar that rejected the blurry upscaling experiment")
        XCTAssertGreaterThan(blackCount,0)
        XCTAssertLessThan(maximumBlack,0.0001,"True black material channels cannot gain a division-floor glow")
    }

    func testNativeCutoutSilhouetteRemainsExactAcrossStationaryFrames() throws {
        let (f,view) = try nativeDetailFixture()
        var pixels = [UInt8](repeating:255,count:16*16*4)
        for y in 0..<16 { for x in 0..<16 {
            pixels[(y*16+x)*4+3] = (x+y).isMultiple(of:2) ? 0:255
        }}
        pixels.withUnsafeBytes { f.atlas.replace(region:MTLRegionMake2D(0,0,16,16),mipmapLevel:0,slice:0,
            withBytes:$0.baseAddress!,bytesPerRow:64,bytesPerImage:1024) }
        f.renderer.uploadSection(key:section,minY:0,
            mesh:mesh(opaque:nativeDetailPlane(distance:6,view:view,tile:1),
                      cutout:nativeDetailPlane(distance:3,view:view)))
        let initial = try render(f,frame:view)
        let near = expectedDepth(distance:3,frame:view), far = expectedDepth(distance:6,frame:view)
        for _ in 0..<3 {
            let next = try render(f,frame:view)
            var changed = 0, maximumError: Float = 0
            for y in 300..<492 { for x in 600..<840 {
                let expected = (x/3+y/3).isMultiple(of:2) ? far:near
                maximumError = max(maximumError,abs(next.depthAt(x,y)-expected))
                if next.depthAt(x,y) != initial.depthAt(x,y) { changed += 1 }
            }}
            XCTAssertEqual(changed,0,"Static alpha coverage must not shimmer as temporal samples advance")
            XCTAssertLessThan(maximumError,0.00001,"All three-pixel holes must expose the actual backing geometry")
        }
    }

    func testNativeEmissionDoesNotBleedAcrossCoplanarMaterialBoundary() throws {
        let (f,view) = try nativeDetailFixture()
        let dark = nativeDetailPlane(distance:4,view:view,right:0.5)
        let glowing = nativeDetailPlane(distance:4,view:view,tile:1,left:0.5,emissive:true)
        let combined = MeshLayer(data:dark.data+glowing.data,
            idx:dark.idx+glowing.idx.map { $0+4 },count:8)
        f.renderer.uploadSection(key:section,minY:0,mesh:mesh(opaque:combined))
        var image = try render(f,frame:view)
        for _ in 0..<3 { image = try render(f,frame:view) }
        let cached = 0.4 * RenderLocalLightPolicy.outputMultiplier
        let emission = 2 * RenderLocalLightPolicy.outputMultiplier
        for y in stride(from:320,to:480,by:13) {
            for x in 716..<724 {
                let expected = cached + (x>=720 ? emission:0)
                XCTAssertEqual(image.colorAt(x,y).x,expected,accuracy:0.035,
                    "Visible emission must stay on its exact native surface, not blur into neighboring stone")
            }
        }
    }

    func testDielectricGuidesPreserveMaterialTagsAndBackfacesReuseLightingOnGPU() throws {
        guard let device = MTLCreateSystemDefaultDevice(),device.supportsRaytracing else {
            throw XCTSkip("Requires actual Metal ray tracing")
        }
        let options = MTLCompileOptions(); options.languageVersion = .version3_1
        let library = try device.makeLibrary(source:ELYSIUM_ENVIRONMENT_MSL+RAY_TRACING_MSL,options:options)
        let pathFunction = try XCTUnwrap(library.makeFunction(name:"rt_pathtrace"))
        let path = try XCTUnwrap(try RayTracingAlphaPipeline(device:device,library:library,function:pathFunction))
        let surfaceFunction = try XCTUnwrap(library.makeFunction(name:"rt_surface_resolve"))
        let surface = try XCTUnwrap(try RayTracingAlphaPipeline(device:device,library:library,function:surfaceFunction))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            try values.withUnsafeBytes { try XCTUnwrap(device.makeBuffer(bytes:$0.baseAddress!,
                length:$0.count,options:.storageModeShared)) }
        }
        func texture(_ format: MTLPixelFormat,width: Int = 4) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:format,width:width,height:1,mipmapped:false)
            descriptor.storageMode = .shared; descriptor.usage = [.shaderRead,.shaderWrite]
            return try XCTUnwrap(device.makeTexture(descriptor:descriptor))
        }
        // Four pixel-center rays hit front/back water and front/back glass. The
        // backface normal is deliberately opposite the face-forward shading normal.
        var vertices: [SIMD3<Float>] = [], primitives: [RayTracingPrimitive] = []
        for index in 0..<4 {
            let x = Float(index*8-12)
            vertices += [.init(x-3,-3,-4),.init(x+3,-3,-4),.init(x+3,3,-4),
                         .init(x-3,-3,-4),.init(x+3,3,-4),.init(x-3,3,-4)]
            for _ in 0..<2 {
                primitives.append(.init(uv01:.init(repeating:0.5),uv2Light:.init(0.5,0.5,0,0),
                    normalEmission:.init(0,0,index.isMultiple(of:2) ? 1:-1,0),
                    material:.init(0xffffff,0,index<2 ? 2:4,0)))
            }
        }
        let vertexBuffer = try buffer(vertices),primitiveBuffer = try buffer(primitives)
        let triangles = MTLAccelerationStructureTriangleGeometryDescriptor()
        triangles.vertexBuffer = vertexBuffer; triangles.vertexFormat = .float3
        triangles.vertexStride = MemoryLayout<SIMD3<Float>>.stride; triangles.triangleCount = primitives.count
        triangles.opaque = true; triangles.primitiveDataBuffer = primitiveBuffer
        triangles.primitiveDataStride = MemoryLayout<RayTracingPrimitive>.stride
        triangles.primitiveDataElementSize = MemoryLayout<RayTracingPrimitive>.stride
        let bottomDescriptor = MTLPrimitiveAccelerationStructureDescriptor(); bottomDescriptor.geometryDescriptors = [triangles]
        let bottomSize = device.accelerationStructureSizes(descriptor:bottomDescriptor)
        let bottom = try XCTUnwrap(device.makeAccelerationStructure(size:bottomSize.accelerationStructureSize))
        let bottomScratch = try XCTUnwrap(device.makeBuffer(length:max(1,bottomSize.buildScratchBufferSize),options:.storageModePrivate))
        var descriptor = MTLAccelerationStructureInstanceDescriptor()
        descriptor.transformationMatrix = MTLPackedFloat4x3(columns:(MTLPackedFloat3Make(1,0,0),
            MTLPackedFloat3Make(0,1,0),MTLPackedFloat3Make(0,0,1),MTLPackedFloat3Make(0,0,0)))
        descriptor.mask = 0xff; descriptor.options = .opaque; descriptor.accelerationStructureIndex = 0
        let descriptorBuffer = try buffer([descriptor])
        let topDescriptor = MTLInstanceAccelerationStructureDescriptor()
        topDescriptor.instancedAccelerationStructures = [bottom]; topDescriptor.instanceCount = 1
        topDescriptor.instanceDescriptorBuffer = descriptorBuffer
        topDescriptor.instanceDescriptorStride = MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride
        let topSize = device.accelerationStructureSizes(descriptor:topDescriptor)
        let scene = try XCTUnwrap(device.makeAccelerationStructure(size:topSize.accelerationStructureSize))
        let topScratch = try XCTUnwrap(device.makeBuffer(length:max(1,topSize.buildScratchBufferSize),options:.storageModePrivate))
        let instances = try buffer([RayTracingInstanceUniforms(transform:matrix_identity_float4x4,
            normalTransform:matrix_identity_float4x4,previousFromCurrent:matrix_identity_float4x4,
            tint:.init(repeating:1),overlay:.zero,info:.zero)])
        let lights = try buffer([RayTracingLight(positionRadius:.zero,colorPower:.zero)])
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:1,height:1,mipmapped:false)
        textureDescriptor.textureType = .type2DArray; textureDescriptor.arrayLength = 1; textureDescriptor.usage = .shaderRead
        let atlas = try XCTUnwrap(device.makeTexture(descriptor:textureDescriptor))
        var white = UInt32.max
        atlas.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,slice:0,withBytes:&white,bytesPerRow:4,bytesPerImage:4)
        let skin = try texture(.rgba8Unorm,width:1)
        skin.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&white,bytesPerRow:4)
        textureDescriptor.textureType = .type3D; textureDescriptor.depth = 1
        let local = try XCTUnwrap(device.makeTexture(descriptor:textureDescriptor))
        var zero: UInt32 = 0
        local.replace(region:MTLRegionMake3D(0,0,0,1,1,1),mipmapLevel:0,slice:0,withBytes:&zero,bytesPerRow:4,bytesPerImage:4)
        let argumentEncoder = pathFunction.makeArgumentEncoder(bufferIndex:4)
        let arguments = try XCTUnwrap(device.makeBuffer(length:argumentEncoder.encodedLength,options:.storageModeShared))
        argumentEncoder.setArgumentBuffer(arguments,offset:0)
        for index in 0..<512 { argumentEncoder.setTexture(skin,index:index) }; argumentEncoder.setTexture(atlas,index:512)
        let pathTable = try XCTUnwrap(path.makeTable(instances:instances,textures:arguments))
        let surfaceTable = try XCTUnwrap(surface.makeTable(instances:instances,textures:arguments))
        let raw = try texture(.rgba16Float),depth = try texture(.r32Float),normal = try texture(.rgba16Float)
        let motion = try texture(.rgba16Float),diffuse = try texture(.rgba16Float),specular = try texture(.rgba16Float)
        let resolved = try texture(.rgba16Float),resolvedDepth = try texture(.r32Float),resolvedNormal = try texture(.rgba16Float)
        let sky = try texture(.rgba16Float,width:1) // per-frame sky radiance input (black here)
        let projection = Elysium.mat4Perspective(fovYRad:.pi/2,aspect:4,near:0.1,far:64)
        var atmosphere = AtmosphereUniforms()
        atmosphere.options.x = 1; atmosphere.weather.z = 0
        atmosphere.zenith = .zero; atmosphere.horizon = .zero; atmosphere.fogColor = .zero
        var uniforms = RayTracingUniforms(inverseViewProjection:projection.inverse,viewProjection:projection,
            previousViewProjection:projection,cameraDelta:.zero,params:.init(64,0.5,0,0),
            heldLight:.zero,fogParameters:.init(32,64,0,0),quality:.init(2,0,0,1),counts:.init(0,0,4,1),atmosphere:atmosphere)
        func encode(_ command: MTLCommandBuffer,pipeline: RayTracingAlphaPipeline,
                    table: MTLIntersectionFunctionTable,textures: [MTLTexture]) throws {
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline.pipeline); encoder.setAccelerationStructure(scene,bufferIndex:0)
            encoder.setBuffer(instances,offset:0,index:1); encoder.setBytes(&uniforms,length:MemoryLayout<RayTracingUniforms>.stride,index:2)
            encoder.setBuffer(lights,offset:0,index:3); encoder.setBuffer(arguments,offset:0,index:4)
            encoder.setIntersectionFunctionTable(table,bufferIndex:5)
            for (index,texture) in textures.enumerated() { encoder.setTexture(texture,index:index) }
            encoder.useResource(bottom,usage:.read); encoder.useResource(skin,usage:.read)
            encoder.dispatchThreads(.init(width:4,height:1,depth:1),threadsPerThreadgroup:.init(width:4,height:1,depth:1))
            encoder.endEncoding()
        }
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let bottomBuild = try XCTUnwrap(command.makeAccelerationStructureCommandEncoder())
        bottomBuild.build(accelerationStructure:bottom,descriptor:bottomDescriptor,scratchBuffer:bottomScratch,scratchBufferOffset:0)
        bottomBuild.endEncoding()
        let topBuild = try XCTUnwrap(command.makeAccelerationStructureCommandEncoder())
        topBuild.build(accelerationStructure:scene,descriptor:topDescriptor,scratchBuffer:topScratch,scratchBufferOffset:0)
        topBuild.endEncoding()
        try encode(command,pipeline:path,table:pathTable,textures:[atlas,raw,depth,normal,motion,diffuse,specular,local,sky])
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status,.completed,String(describing:command.error))
        var guide = [Float16](repeating:0,count:16)
        guide.withUnsafeMutableBytes { specular.getBytes($0.baseAddress!,bytesPerRow:32,from:MTLRegionMake2D(0,0,4,1),mipmapLevel:0) }
        for index in 0..<4 {
            XCTAssertEqual(Float(guide[index*4+3]),index<2 ? -2:-3,
                "Fresnel RGB updates must retain the distinct water/glass donor tag")
        }
        // Write only after the first command completes. A conspicuous donor makes
        // successful reconstruction distinguishable from a correct-looking retrace.
        let donor: [Float16] = Array(repeating:[Float16(2),3,4,1],count:4).flatMap { $0 }
        donor.withUnsafeBytes { raw.replace(region:MTLRegionMake2D(0,0,4,1),mipmapLevel:0,
            withBytes:$0.baseAddress!,bytesPerRow:32) }
        let resolve = try XCTUnwrap(queue.makeCommandBuffer())
        try encode(resolve,pipeline:surface,table:surfaceTable,
            textures:[atlas,raw,depth,normal,diffuse,resolved,resolvedDepth,resolvedNormal,local,specular,sky])
        resolve.commit(); resolve.waitUntilCompleted()
        XCTAssertEqual(resolve.status,.completed,String(describing:resolve.error))
        var output = [Float16](repeating:0,count:16)
        output.withUnsafeMutableBytes { resolved.getBytes($0.baseAddress!,bytesPerRow:32,from:MTLRegionMake2D(0,0,4,1),mipmapLevel:0) }
        for index in 0..<4 { for channel in 0..<3 {
            XCTAssertEqual(Float(output[index*4+channel]),Float(channel+2),accuracy:0.001,
                "Front/back water and glass must reuse matching lighting, not invoke full transport fallback")
        }}
    }

    func testBlockGeometryReplacementInvalidatesHistoryAndChangesRealHit() throws {
        let f = try fixture(), view = frame()
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 4)))
        _ = try render(f, frame: view)
        _ = try render(f, frame: view)
        XCTAssertEqual(f.renderer.diagnostics.historySamples, 2)
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 7, halfSize: 4)))
        let edited = try render(f, frame: view)
        XCTAssertEqual(edited.depthAt(16, 16), expectedDepth(distance: 7, frame: view), accuracy: 0.00001)
        XCTAssertEqual(f.renderer.diagnostics.historySamples, 1)
        XCTAssertEqual(f.renderer.diagnostics.pendingSections, 0)
    }

    func testResizeAtlasAndWorldChangesResetActualRendererHistory() throws {
        let f = try fixture()
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 4)))
        _ = try render(f, frame: frame())
        _ = try render(f, frame: frame())
        XCTAssertEqual(f.renderer.diagnostics.historySamples, 2)
        f.renderer.resize(width: 48, height: 24)
        let resizedView = frame(width: 48, height: 24)
        let resized = try render(f, frame: resizedView)
        XCTAssertEqual(resized.width, 48); XCTAssertEqual(resized.height, 24)
        XCTAssertEqual(resized.depthAt(24, 12), expectedDepth(distance: 4, frame: resizedView), accuracy: 0.00001)
        XCTAssertEqual(f.renderer.diagnostics.historySamples, 1)
        _ = try render(f, frame: frame(width: 48, height: 24, atlas: 2))
        XCTAssertEqual(f.renderer.diagnostics.historySamples, 1)
        _ = try render(f, frame: frame(width: 48, height: 24, world: 2, atlas: 2))
        XCTAssertEqual(f.renderer.diagnostics.historySamples, 1)
        f.renderer.clear()
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 9, halfSize: 4)))
        let newWorld = try render(f, frame: frame(width: 48, height: 24, world: 3, atlas: 2))
        XCTAssertEqual(newWorld.depthAt(24, 12), expectedDepth(distance: 9, frame: resizedView), accuracy: 0.00001)
        XCTAssertEqual(f.renderer.diagnostics.historySamples, 1)
    }

    func testDynamicInstanceMovesWithoutStalePrimaryGeometry() throws {
        let f = try fixture(), view = frame()
        f.renderer.uploadSection(key: section, minY: 0,
                                 mesh: mesh(opaque: plane(distance: 6, halfSize: 4)))
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 1, height: 1, mipmapped: false)
        textureDescriptor.usage = .shaderRead
        let texture = try XCTUnwrap(f.device.makeTexture(descriptor: textureDescriptor))
        var white: UInt32 = 0xffffffff
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &white, bytesPerRow: 4)
        let native = plane(distance: 3, halfSize: 1)
        var vertices: [Float] = []
        for index in native.idx {
            let start = Int(index) * 7
            vertices.append(contentsOf: [Float(bitPattern: native.data[start]),
                Float(bitPattern: native.data[start + 1]), Float(bitPattern: native.data[start + 2]),
                0, 0, 1, Float(bitPattern: native.data[start + 3]), Float(bitPattern: native.data[start + 4]), 0])
        }
        let geometry = RayTracingEntityGeometry(key: "test-entity-part", vertices: vertices, texture: texture)
        var entity = RayTracingEntityInstance(geometry: geometry, identity: "test-entity:42",
                                             transform: matrix_identity_float4x4)
        let first = try render(f, frame: view, entities: [entity])
        XCTAssertEqual(first.depthAt(16, 16), expectedDepth(distance: 3, frame: view), accuracy: 0.00001)
        entity.primaryVisible = false
        let secondaryOnly = try render(f, frame: view, entities: [entity])
        XCTAssertEqual(secondaryOnly.depthAt(16, 16), expectedDepth(distance: 6, frame: view), accuracy: 0.00001,
                       "A first-person body stays in the ray scene without occluding the primary camera")
        XCTAssertEqual(f.renderer.diagnostics.instances, 2)
        entity.primaryVisible = true
        entity.transform = mTranslate(matrix_identity_float4x4, 5, 0, 0)
        let moved = try render(f, frame: view, entities: [entity])
        XCTAssertEqual(moved.depthAt(16, 16), expectedDepth(distance: 6, frame: view), accuracy: 0.00001)
        XCTAssertEqual(f.renderer.diagnostics.instances, 2)
    }

    func testReflectiveMetalSeesEmissiveGeometryBehindTheCamera() throws {
        let iron = try XCTUnwrap(allTileNames().firstIndex(of: "iron_block"))
        let redTile = iron + 1
        let f = try fixture(slices: redTile + 1, redTile: redTile), view = frame()
        f.renderer.uploadSection(key: section, minY: 0,
            mesh: mesh(opaque: plane(distance: 3, halfSize: 2, tile: UInt32(iron))))
        let baseline = try render(f, frame: view)
        // This entire red emitter lies at world Z=+3, behind the eye. A screen-
        // space reflection or primary-only ray pass cannot see any of its pixels.
        let behindKey = SectionKey(cx: 0, sy: 0, cz: 1)
        let behind = plane(distance: 13, halfSize: 6, tile: UInt32(redTile))
        var data = behind.data
        for vertex in 0..<behind.count {
            data[vertex * 7 + 5] |= 1 << 25 // Native emissive material bit.
            data[vertex * 7 + 6] |= 2 << 24 // Lava-level emission, red test texture.
        }
        f.renderer.uploadSection(key: behindKey, minY: 0,
            mesh: mesh(opaque: MeshLayer(data: data, idx: behind.idx, count: behind.count)))
        var reflected = try render(f, frame: view)
        for _ in 0..<3 { reflected = try render(f, frame: view) }
        func centerMean(_ image: Image) -> SIMD3<Float> {
            var sum = SIMD3<Float>(repeating: 0)
            for y in 12..<20 { for x in 12..<20 {
                let p = image.radiance[y * image.width + x]
                sum += SIMD3<Float>(p.x, p.y, p.z)
            } }
            return sum / 64
        }
        let plain = centerMean(baseline), mirror = centerMean(reflected)
        // The large difference excludes a mere weak diffuse local-light term;
        // it requires secondary rays returning the emitter's surface radiance.
        XCTAssertGreaterThan(mirror.x - plain.x, 0.8)
        XCTAssertGreaterThan(mirror.x, mirror.z * 3)
        XCTAssertEqual(reflected.depthAt(16, 16), expectedDepth(distance: 3, frame: view), accuracy: 0.00001,
                       "The primary surface remains the front mirror, not the reflected object")
        XCTAssertEqual(f.renderer.diagnostics.instances, 2)
    }

    func testMissingOrInvalidGeometryFallsBackInsteadOfPresentingPartialScene() throws {
        let f = try fixture(), view = frame()
        var command = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertNil(f.renderer.render(command: command, frame: view, atlas: f.atlas, entities: []))
        XCTAssertFalse(f.renderer.diagnostics.ready)
        XCTAssertNil(f.renderer.depthTexture)
        command.commit(); command.waitUntilCompleted()
        let malformed = MeshLayer(data: [0], idx: [0, 0, 0], count: 1)
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: malformed))
        command = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertNil(f.renderer.render(command: command, frame: view, atlas: f.atlas, entities: []))
        XCTAssertFalse(f.renderer.diagnostics.ready)
        XCTAssertTrue(f.renderer.diagnostics.status.contains("Invalid section geometry"))
        command.commit(); command.waitUntilCompleted()
        f.renderer.clear()
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 4)))
        _ = try render(f, frame: view)
        f.renderer.removeChunk(cx: 0, cz: 0, sectionCount: 1)
        command = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertNil(f.renderer.render(command: command, frame: view, atlas: f.atlas, entities: []))
        XCTAssertFalse(f.renderer.diagnostics.ready)
        XCTAssertNil(f.renderer.depthTexture)
        command.commit(); command.waitUntilCompleted()
    }

    func testIncrementalBuildNeverPresentsAnIncompleteRayScene() throws {
        let f = try fixture(), view = frame()
        let count = RayTracingLimits.buildsPerFrame + 1
        for y in 0..<count {
            f.renderer.uploadSection(key: SectionKey(cx: 0, sy: y, cz: 0), minY: 0,
                                     mesh: mesh(opaque: plane(distance: 4)))
        }
        let command = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertNil(f.renderer.render(command: command, frame: view, atlas: f.atlas, entities: []))
        XCTAssertFalse(f.renderer.diagnostics.ready)
        XCTAssertNil(f.renderer.depthTexture)
        XCTAssertEqual(f.renderer.diagnostics.pendingSections, 1)
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "GPU build failed")
        let complete = try render(f, frame: view)
        XCTAssertTrue(f.renderer.diagnostics.ready)
        XCTAssertEqual(f.renderer.diagnostics.pendingSections, 0)
        XCTAssertEqual(f.renderer.diagnostics.sections, count)
        XCTAssertEqual(complete.depthAt(16, 16), expectedDepth(distance: 4, frame: view), accuracy: 0.00001)
    }

    func testWarmSceneAbsorbs26MeshCompletionBurstWithoutRasterFallbackOrStaleBlocks() throws {
        let f=try fixture(), view=frame()
        f.renderer.uploadSection(key:section,minY:0,mesh:mesh(opaque:plane(distance:4)))
        _=try render(f,frame:view)
        // The core mesher can complete 26 jobs together. Replace the visible surface as part
        // of that burst: merely retaining the previous image/BLAS is not a valid solution.
        for y in 0..<26 {
            f.renderer.uploadSection(key:SectionKey(cx:0,sy:y,cz:0),minY:0,
                mesh:mesh(opaque:plane(distance:7,halfSize:4)))
        }
        let updated=try render(f,frame:view)
        XCTAssertTrue(f.renderer.diagnostics.ready)
        XCTAssertEqual(f.renderer.diagnostics.pendingSections,0)
        XCTAssertEqual(f.renderer.diagnostics.instances,26)
        XCTAssertEqual(f.renderer.diagnostics.triangles,52)
        XCTAssertEqual(updated.depthAt(16,16),expectedDepth(distance:7,frame:view),accuracy:0.00001)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,1,"Real participating edits still invalidate old lighting")
    }

    func testDistantAndEmptyMeshUpdatesDoNotResetParticipatingHistory() throws {
        let f=try fixture(), view=frame()
        f.renderer.uploadSection(key:section,minY:0,mesh:mesh(opaque:plane(distance:4)))
        _=try render(f,frame:view)
        let distant=SectionKey(cx:64,sy:0,cz:0)
        f.renderer.uploadSection(key:distant,minY:0,mesh:mesh(opaque:plane(distance:7)))
        _=try render(f,frame:view)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,2)
        f.renderer.uploadSection(key:SectionKey(cx:1,sy:3,cz:0),minY:0,mesh:mesh())
        _=try render(f,frame:view)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,3,"An empty new section has no participating geometry")
        f.renderer.removeChunk(cx:64,cz:0,sectionCount:2)
        let retained=try render(f,frame:view)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,4)
        XCTAssertEqual(retained.depthAt(16,16),expectedDepth(distance:4,frame:view),accuracy:0.00001)
    }

    func testRemovingParticipatingSectionResetsHistoryAndRevealsFreshGeometry() throws {
        let f=try fixture(), view=frame()
        f.renderer.uploadSection(key:section,minY:0,mesh:mesh(opaque:plane(distance:4)))
        // A separate section uses an offset world origin to place the backing plane at eye level.
        f.renderer.uploadSection(key:SectionKey(cx:0,sy:1,cz:0),minY:-16,
            mesh:mesh(opaque:plane(distance:7,halfSize:4)))
        _=try render(f,frame:view); _=try render(f,frame:view)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,2)
        f.renderer.uploadSection(key:section,minY:0,mesh:mesh())
        let removed=try render(f,frame:view)
        XCTAssertEqual(removed.depthAt(16,16),expectedDepth(distance:7,frame:view),accuracy:0.00001)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,1)
        XCTAssertEqual(f.renderer.diagnostics.instances,1)
    }

    func testSmallSelectionBoundaryReversalRetainsBLASInsteadOfRebuilding() throws {
        let f=try fixture()
        var inside=frame(); inside.camera.x=1; inside.atmosphere.cameraTime.x=1
        var outside=inside; outside.camera.x = -1; outside.atmosphere.cameraTime.x = -1
        f.renderer.uploadSection(key:section,minY:0,mesh:mesh(opaque:plane(distance:4,halfSize:4)))
        f.renderer.uploadSection(key:SectionKey(cx:5,sy:0,cz:0),minY:0,
            mesh:mesh(opaque:plane(distance:6)))
        _=try render(f,frame:inside)
        f.renderer.refreshMemoryDiagnostics()
        let retainedResident=f.renderer.diagnostics.residentGeometryBytes
        XCTAssertEqual(f.renderer.diagnostics.sections,2)
        _=try render(f,frame:inside)
        let steadyTransient=f.renderer.diagnostics.transientGeometryBytes
        XCTAssertGreaterThan(steadyTransient,0)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,2)
        _=try render(f,frame:outside)
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertEqual(f.renderer.diagnostics.sections,1)
        XCTAssertEqual(f.renderer.diagnostics.residentGeometryBytes,retainedResident,
            "The 32-block retention margin must keep the just-exited section cached")
        XCTAssertEqual(f.renderer.diagnostics.historySamples,3,
            "Camera-only selection changes must not reset otherwise valid scene history")
        let returned=try render(f,frame:inside)
        XCTAssertEqual(f.renderer.diagnostics.sections,2)
        XCTAssertLessThanOrEqual(f.renderer.diagnostics.transientGeometryBytes,steadyTransient,
            "Returning across the boundary must need only normal TLAS/tables, not BLAS build uploads")
        XCTAssertEqual(returned.depthAt(16,16),expectedDepth(distance:4,frame:inside),accuracy:0.00001)
        XCTAssertEqual(f.renderer.diagnostics.pendingSections,0)
        XCTAssertEqual(f.renderer.diagnostics.historySamples,4)
    }

    func testFailedNativeDenoisingActivatesFourSampleFallbackThenRecovers() throws {
        let f = try fixture()
        guard #available(macOS 26.0, *),
              MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(f.device) else {
            throw XCTSkip("Requires native denoising to exercise runtime fallback")
        }
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 4)))
        let valid = frame()
        var invalid = valid
        // Only the optional denoiser camera guide is invalid. Primary path-ray
        // matrices remain valid so the real fallback still renders the plane.
        invalid.projectionMatrix.columns.0.x = .nan
        _ = try render(f, frame: invalid)
        XCTAssertEqual(f.renderer.diagnostics.samplesPerPixel, 2)
        XCTAssertEqual(f.renderer.diagnostics.denoiser, "Albedo-guided temporal/spatial")
        let fallback = try render(f, frame: invalid)
        XCTAssertEqual(f.renderer.diagnostics.samplesPerPixel, 4)
        XCTAssertEqual(fallback.depthAt(16, 16), expectedDepth(distance: 4, frame: valid), accuracy: 0.00001)
        _ = try render(f, frame: valid)
        XCTAssertEqual(f.renderer.diagnostics.samplesPerPixel, 4, "Recovery frame keeps the already dispatched sample count")
        XCTAssertEqual(f.renderer.diagnostics.denoiser, "MetalFX temporal denoising")
        _ = try render(f, frame: valid)
        XCTAssertEqual(f.renderer.diagnostics.samplesPerPixel, 2)
    }

    func testPostDenoiseFogStaysNeutralAcrossSaturatedMaterialEdgesAndHistory() throws {
        // The native failure was neutral rain fog being reconstructed through
        // strongly green material guides, producing distant magenta speckles.
        // Exercise both neural and native fallback reconstruction with real GPU
        // reads: fully fogged output must be independent of either material.
        for forceFallback in [false, true] {
            let f = try fixture()
            var pixels = [UInt8](repeating: 255, count: 16 * 16 * 4)
            for y in 0..<16 { for x in 0..<16 {
                let i = (y * 16 + x) * 4
                pixels[i] = x < 8 ? 0 : 255
                pixels[i + 1] = x < 8 ? 255 : 0
                pixels[i + 2] = x < 8 ? 0 : 255
            }}
            pixels.withUnsafeBytes { raw in
                f.atlas.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
                    slice: 0, withBytes: raw.baseAddress!, bytesPerRow: 16 * 4, bytesPerImage: 16 * 16 * 4)
            }
            f.renderer.uploadSection(key: section, minY: 0,
                                     mesh: mesh(opaque: plane(distance: 4, halfSize: 4)))
            var view = frame()
            view.fogStart = 1
            view.fogEnd = 2
            view.atmosphere.fogColor = SIMD4<Float>(0.6, 0.6, 0.6, 2)
            if forceFallback { view.projectionMatrix.columns.0.x = .nan }
            let expected = Float(pow(0.6, 2.2))
            for frameIndex in 0..<10 {
                let image = try render(f, frame: view)
                for y in 2..<(image.height - 2) { for x in 2..<(image.width - 2) {
                    let value = image.radiance[y * image.width + x]
                    XCTAssertLessThan(image.depthAt(x, y), 1)
                    XCTAssertEqual(value.x, expected, accuracy: 0.001,
                        "Red fog contamination; fallback=\(forceFallback), frame=\(frameIndex), pixel=\(x),\(y)")
                    XCTAssertEqual(value.y, expected, accuracy: 0.001)
                    XCTAssertEqual(value.z, expected, accuracy: 0.001)
                }}
            }
            // This is a color-preservation test, not an all-gray renderer: when
            // fog recedes, green and magenta surfaces must remain distinct.
            view.fogStart = 128
            view.fogEnd = 256
            let clear = try render(f, frame: view)
            let green = clear.radiance[16 * clear.width + 8]
            let magenta = clear.radiance[16 * clear.width + 24]
            XCTAssertGreaterThan(green.y - max(green.x, green.z), 0.05)
            XCTAssertGreaterThan(min(magenta.x, magenta.z) - magenta.y, 0.05)
            // Partial fog is bounded/finite and independent of native history
            // contents; near-edge interpolation still retains some material.
            view.fogStart = 2
            view.fogEnd = 8
            let partial = try render(f, frame: view)
            XCTAssertTrue(partial.radiance.allSatisfy {
                [$0.x, $0.y, $0.z].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 32 }
            })
        }
    }

#if DEBUG
    func testMemoryPressureShedsMarginCacheAndRecoversAtSameCameraAfterCompletion() throws {
        let f = try fixture(memoryBudgetOverride: 64 * 1_024 * 1_024)
        var inside = frame()
        inside.camera.x = 1; inside.atmosphere.cameraTime.x = 1
        var outside = inside
        outside.camera.x = -1; outside.atmosphere.cameraTime.x = -1
        f.renderer.uploadSection(key: section, minY: 0,
            mesh: mesh(opaque: plane(distance: 4, halfSize: 4)))
        _ = try render(f, frame: inside)
        _ = try render(f, frame: inside)
        // The render diagnostics retain the encode-time peak until refreshed. Derive a
        // device-specific limit that fits one complete scene plus half a spare BLAS,
        // but not a second cached BLAS alongside that scene's normal frame resources.
        let oneScenePeak = f.renderer.diagnostics.geometryBytes
        f.renderer.refreshMemoryDiagnostics()
        let oneResident = f.renderer.diagnostics.residentGeometryBytes
        XCTAssertGreaterThan(oneResident, 0)
        XCTAssertGreaterThan(oneScenePeak, oneResident)
        let selectedSceneBudget = oneScenePeak + oneResident / 2

        let margin = SectionKey(cx: 5, sy: 0, cz: 0)
        f.renderer.uploadSection(key: margin, minY: 0,
            mesh: mesh(opaque: plane(distance: 6)))
        let pending = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertNotNil(f.renderer.render(command: pending, frame: inside, atlas: f.atlas, entities: []))
        XCTAssertEqual(f.renderer.diagnostics.sections, 2)
        f.renderer.refreshMemoryDiagnostics()
        let twoResident = f.renderer.diagnostics.residentGeometryBytes
        XCTAssertGreaterThan(twoResident, oneResident)

        // Crossing this boundary removes only the far BLAS from selection, not from the
        // 32-block retention margin. It is still a consumer of the uncommitted frame.
        f.renderer.memoryBudgetOverride = selectedSceneBudget
        let rejected = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertNil(f.renderer.render(command: rejected, frame: outside, atlas: f.atlas, entities: []))
        XCTAssertEqual(f.renderer.diagnostics.sections, 1)
        XCTAssertFalse(f.renderer.diagnostics.ready)
        XCTAssertNil(f.renderer.depthTexture)
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertEqual(f.renderer.diagnostics.residentGeometryBytes, twoResident,
            "Dropping the optional cache must not uncharge a BLAS still owned by a pending GPU consumer")
        XCTAssertGreaterThan(f.renderer.diagnostics.transientGeometryBytes, 0)

        let completions = expectation(description: "Pressure-shed geometry remains valid through GPU completion")
        completions.expectedFulfillmentCount = 2
        pending.addCompletedHandler { _ in completions.fulfill() }
        rejected.addCompletedHandler { _ in completions.fulfill() }
        pending.commit(); rejected.commit()
        wait(for: [completions], timeout: 10)
        XCTAssertEqual(pending.status, .completed, String(describing: pending.error))
        XCTAssertEqual(rejected.status, .completed, String(describing: rejected.error))
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertEqual(f.renderer.diagnostics.residentGeometryBytes, oneResident,
            "The unselected margin BLAS must leave the cache under pressure, even while command objects remain alive")
        XCTAssertEqual(f.renderer.diagnostics.transientGeometryBytes, 0)

        // Do not move farther, increase the budget, re-upload geometry or reopen the world.
        let recovered = try render(f, frame: outside)
        XCTAssertEqual(recovered.depthAt(16, 16), expectedDepth(distance: 4, frame: outside), accuracy: 0.00001)
        XCTAssertTrue(f.renderer.diagnostics.ready)
        XCTAssertEqual(f.renderer.diagnostics.pendingSections, 0)
        XCTAssertLessThanOrEqual(f.renderer.diagnostics.geometryBytes, selectedSceneBudget)
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertEqual(f.renderer.diagnostics.residentGeometryBytes, oneResident)
        XCTAssertEqual(f.renderer.diagnostics.transientGeometryBytes, 0)
        XCTAssertEqual(f.renderer.diagnostics.historySamples, 1)
    }

    func testGeometryBudgetFailureRecoversWithoutClearingOrReopeningWorld() throws {
        let f = try fixture(memoryBudgetOverride: 1), view = frame()
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 4)))
        let rejected = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertNil(f.renderer.render(command: rejected, frame: view, atlas: f.atlas, entities: []))
        XCTAssertFalse(f.renderer.diagnostics.ready)
        XCTAssertNil(f.renderer.depthTexture)
        rejected.commit()
        rejected.waitUntilCompleted()
        XCTAssertEqual(rejected.status, .completed, String(describing: rejected.error))
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertEqual(f.renderer.diagnostics.transientGeometryBytes, 0)
        XCTAssertEqual(f.renderer.diagnostics.residentGeometryBytes, 0,
                       "Rejected geometry must not allocate a resident acceleration structure")

        // The source section remains admitted. Only available capacity changes;
        // no clear(), re-upload, settings toggle or world reload is allowed.
        f.renderer.memoryBudgetOverride = 64 * 1_024 * 1_024
        let recovered = try render(f, frame: view)
        XCTAssertEqual(recovered.depthAt(16, 16), expectedDepth(distance: 4, frame: view), accuracy: 0.00001)
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertTrue(f.renderer.diagnostics.ready)
        XCTAssertEqual(f.renderer.diagnostics.pendingSections, 0)
        XCTAssertGreaterThan(f.renderer.diagnostics.residentGeometryBytes, 0)
        XCTAssertLessThanOrEqual(f.renderer.diagnostics.geometryBytes, f.renderer.diagnostics.memoryBudgetBytes)
    }

    func testExhaustedGlobalHeadroomFallsBackAndRecoversExistingScene() throws {
        let f = try fixture(memoryBudgetOverride: 64 * 1_024 * 1_024), view = frame()
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 4)))
        _ = try render(f, frame: view)
        f.renderer.refreshMemoryDiagnostics()
        let resident = f.renderer.diagnostics.residentGeometryBytes
        XCTAssertGreaterThan(resident, 0)

        // Even a built scene needs temporary TLAS/instance tables each frame.
        // Exhausting device-wide headroom must not present stale or partial RT.
        f.renderer.memoryHeadroomOverride = 0
        let rejected = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertNil(f.renderer.render(command: rejected, frame: view, atlas: f.atlas, entities: []))
        XCTAssertFalse(f.renderer.diagnostics.ready)
        XCTAssertNil(f.renderer.depthTexture)
        rejected.commit()
        rejected.waitUntilCompleted()
        XCTAssertEqual(rejected.status, .completed, String(describing: rejected.error))
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertEqual(f.renderer.diagnostics.transientGeometryBytes, 0)

        f.renderer.memoryHeadroomOverride = nil
        let recovered = try render(f, frame: view)
        XCTAssertEqual(recovered.depthAt(16, 16), expectedDepth(distance: 4, frame: view), accuracy: 0.00001)
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertTrue(f.renderer.diagnostics.ready)
        XCTAssertEqual(f.renderer.diagnostics.residentGeometryBytes, resident)
        XCTAssertEqual(f.renderer.diagnostics.historySamples, 1, "Recovery must discard stale lighting history")
    }

    func testCompletedSubmissionsReleaseScratchUploadsAndRetiredGeometry() throws {
        let f = try fixture(memoryBudgetOverride: 64 * 1_024 * 1_024), view = frame()
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 4)))
        let first = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertNotNil(f.renderer.render(command: first, frame: view, atlas: f.atlas, entities: []))
        f.renderer.refreshMemoryDiagnostics()
        let oneResident = f.renderer.diagnostics.residentGeometryBytes
        XCTAssertGreaterThan(oneResident, 0)
        XCTAssertGreaterThan(f.renderer.diagnostics.transientGeometryBytes, 0,
                             "Scratch/upload/scene buffers remain charged while their GPU consumer is pending")

        // Retire the first mesh before either GPU submission has run. The old
        // BLAS and upload buffers must remain alive for the first command.
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 6)))
        let second = try XCTUnwrap(f.queue.makeCommandBuffer())
        XCTAssertNotNil(f.renderer.render(command: second, frame: view, atlas: f.atlas, entities: []))
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertGreaterThan(f.renderer.diagnostics.residentGeometryBytes, oneResident)
        let completions = expectation(description: "Both real GPU submissions release their completion-owned resources")
        completions.expectedFulfillmentCount = 2
        first.addCompletedHandler { _ in completions.fulfill() }
        second.addCompletedHandler { _ in completions.fulfill() }
        first.commit()
        second.commit()
        wait(for: [completions], timeout: 10)
        XCTAssertEqual(first.status, .completed, String(describing: first.error))
        XCTAssertEqual(second.status, .completed, String(describing: second.error))
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertEqual(f.renderer.diagnostics.transientGeometryBytes, 0)
        XCTAssertEqual(f.renderer.diagnostics.residentGeometryBytes, oneResident,
                       "Only the current two-triangle BLAS survives; command objects are deliberately still retained")
        XCTAssertEqual(f.renderer.diagnostics.geometryBytes, oneResident)
        let current = try render(f, frame: view)
        XCTAssertEqual(current.depthAt(16, 16), expectedDepth(distance: 6, frame: view), accuracy: 0.00001)
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertEqual(f.renderer.diagnostics.transientGeometryBytes, 0,
                       "Steady-state TLAS and instance tables must not accumulate either")
    }

    func testOutOfRangeAccelerationStructuresEvictAndRebuildOnReturn() throws {
        let f = try fixture(memoryBudgetOverride: 64 * 1_024 * 1_024)
        let home = frame()
        var away = home
        away.camera.x = 256
        away.atmosphere.cameraTime.x = 256
        let distant = SectionKey(cx: 16, sy: 0, cz: 0)
        f.renderer.uploadSection(key: section, minY: 0, mesh: mesh(opaque: plane(distance: 4)))
        f.renderer.uploadSection(key: distant, minY: 0, mesh: mesh(opaque: plane(distance: 6)))
        let initial = try render(f, frame: home)
        XCTAssertEqual(initial.depthAt(16, 16), expectedDepth(distance: 4, frame: home), accuracy: 0.00001)
        f.renderer.refreshMemoryDiagnostics()
        let oneResident = f.renderer.diagnostics.residentGeometryBytes
        XCTAssertGreaterThan(oneResident, 0)
        XCTAssertEqual(f.renderer.diagnostics.sections, 1)

        let traveled = try render(f, frame: away)
        XCTAssertEqual(traveled.depthAt(16, 16), expectedDepth(distance: 6, frame: away), accuracy: 0.00001)
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertEqual(f.renderer.diagnostics.sections, 1)
        XCTAssertEqual(f.renderer.diagnostics.residentGeometryBytes, oneResident,
                       "Leaving the selection radius evicts the old BLAS instead of accumulating both")
        XCTAssertEqual(f.renderer.diagnostics.transientGeometryBytes, 0)

        // No section is re-uploaded. A return visit must rebuild from its
        // retained packed source, not show an empty world or a stale far BLAS.
        let returned = try render(f, frame: home)
        XCTAssertEqual(returned.depthAt(16, 16), expectedDepth(distance: 4, frame: home), accuracy: 0.00001)
        f.renderer.refreshMemoryDiagnostics()
        XCTAssertEqual(f.renderer.diagnostics.sections, 1)
        XCTAssertEqual(f.renderer.diagnostics.residentGeometryBytes, oneResident)
        XCTAssertEqual(f.renderer.diagnostics.transientGeometryBytes, 0)
        XCTAssertEqual(f.renderer.diagnostics.historySamples, 1)
    }
#endif
}
