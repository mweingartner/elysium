import Metal
import simd
import XCTest
@testable import Elysium

/// These run the production MSL helpers on the actual Metal device. They test optical invariants
/// and controls, not whether a screenshot is attractive; native gameplay captures cover that.
final class AtmosphereShaderTests: XCTestCase {
    private static let probeMSL = """
    kernel void atmosphere_probe(device float4* result [[buffer(0)]],
                                  constant ElyAtmosphereU& e [[buffer(1)]],
                                  uint index [[thread_position_in_grid]]) {
        float3 tint = float3(0.247, 0.463, 0.894);
        float3 p = float3(-137.25, 63.9, 512.5);
        switch (index) {
            case 0: result[index] = float4(elyDielectricFresnel(1.0, 1.0, 1.333),
                elyDielectricFresnel(0.05, 1.0, 1.333), elyDielectricFresnel(0.50, 1.333, 1.0),
                elyDielectricFresnel(0.0, 1.0, 1.0)); break;
            case 1: result[index] = float4(elyWaterNormal(p, float3(0,1,0), 12.0, e.weather.x), 1); break;
            case 2: result[index] = float4(elyWaterNormal(p, float3(0,-1,0), 12.0, e.weather.x), 1); break;
            case 3: result[index] = float4(elyWaterNormal(p, float3(1,0,0), 12.0, e.weather.x), 1); break;
            case 4: result[index] = float4(elyWaterTransmittance(0.0, tint), 1); break;
            case 5: result[index] = float4(elyWaterTransmittance(24.0, tint), 1); break;
            case 6: result[index] = float4(elyWaterTransmittance(1.0, tint), 1); break;
            case 7: result[index] = float4(elyWaterScattering(float3(1), tint, 1.0), 1); break;
            case 8: result[index] = float4(elyWaterScattering(float3(0), tint, 0.05), 1); break;
            case 9: result[index] = float4(elyWaterScattering(float3(0), tint, 1.0), 1); break;
            case 10: result[index] = float4(elyWaterFoam(0.0, p, 12.0, e.weather.x),
                elyWaterFoam(4.0, p, 12.0, e.weather.x),
                elyWaterFoam(0.0, float3(0), -0.8726646, 1.0), 0); break;
            case 11: result[index] = elyCloudLayer(float3(0,70,0), float3(0,1,0), e, 100.0); break;
            case 12: result[index] = float4(e.options.w > 0.5
                ? elyAtmosphereRadianceAir(float3(0,70,0), float3(0,1,0), e, true)
                : elyAtmosphereRadiance(float3(0,70,0), float3(0,1,0), e, true), 1); break;
            case 13: result[index] = float4(elyAtmosphereRadiance(float3(0,70,0), float3(1,0,0), e, true), 1); break;
            case 14: result[index] = float4(elyAtmosphereRadiance(float3(0,70,0), float3(0,-1,0), e, true), 1); break;
            case 15: result[index] = float4(elyCloudSunTransmittance(float3(0,70,0), e), 0, 0, 1); break;
            default: {
                float3 origin = float3(float((index - 16) % 8) * 179.0 - 521.0, 70,
                                       float((index - 16) / 8) * 163.0 - 413.0);
                float4 cloud = elyCloudLayer(origin, normalize(float3(0.2,1,0.13)), e, 4096.0);
                result[index] = cloud;
                break;
            }
        }
    }
    """

    private func evaluate(_ environment: AtmosphereUniforms = AtmosphereUniforms()) throws -> [SIMD4<Float>] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: ELYSIUM_ENVIRONMENT_MSL + Self.probeMSL, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "atmosphere_probe"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let output = try XCTUnwrap(device.makeBuffer(length: 80 * MemoryLayout<SIMD4<Float>>.stride,
                                                    options: .storageModeShared))
        var uniforms = environment
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<AtmosphereUniforms>.stride, index: 1)
        encoder.dispatchThreads(MTLSize(width: 80, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(32, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        XCTAssertEqual(command.status, .completed)
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: 80))
    }

    func testUniformLayoutMatchesEightMetalFloat4Values() {
        XCTAssertEqual(MemoryLayout<AtmosphereUniforms>.stride, 128)
        XCTAssertEqual(MemoryLayout<AtmosphereUniforms>.offset(of: \AtmosphereUniforms.weather), 80)
        XCTAssertEqual(MemoryLayout<AtmosphereUniforms>.offset(of: \AtmosphereUniforms.clouds), 96)
        XCTAssertEqual(MemoryLayout<AtmosphereUniforms>.offset(of: \AtmosphereUniforms.options), 112)
    }

    func testProductionRasterWaterCloudAndRayResolvePipelinesCompile() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: GAME_MSL, options: nil)
        let vertex = MTLVertexDescriptor()
        let formats: [MTLVertexFormat] = [.float3, .float2, .uint, .uint]
        for (index, offset) in [0, 12, 20, 24].enumerated() {
            vertex.attributes[index].format = formats[index]
            vertex.attributes[index].offset = offset
            vertex.attributes[index].bufferIndex = 0
        }
        vertex.layouts[0].stride = 28
        for (vertexName, fragmentName) in [("chunk_vs", "water_fs"),
                                           ("chunk_vs", "translucent_refraction_fs"),
                                           ("fs_vs", "cloud_volume_fs"),
                                           ("fs_vs", "cloud_composite_fs"),
                                           ("fs_vs", "ray_resolve_fs")] {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: vertexName))
            descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: fragmentName))
            descriptor.colorAttachments[0].pixelFormat = .rgba16Float
            descriptor.depthAttachmentPixelFormat = .depth32Float
            if vertexName == "chunk_vs" { descriptor.vertexDescriptor = vertex }
            _ = try device.makeRenderPipelineState(descriptor: descriptor)
        }
    }

    func testRayTracedHDRToneMappingDoesNotDependOnScreenSpaceUltraEffects() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: GAME_MSL, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "fs_vs"))
        pipelineDescriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "composite_fs"))
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let inputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: 1, height: 1, mipmapped: false)
        inputDescriptor.usage = .shaderRead
        let input = try XCTUnwrap(device.makeTexture(descriptor: inputDescriptor))
        let pixel: [Float] = [4, 4, 4, 1]
        pixel.withUnsafeBytes { bytes in
            input.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                          withBytes: bytes.baseAddress!, bytesPerRow: 16)
        }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 1, height: 1, mipmapped: false)
        outputDescriptor.usage = .renderTarget
        let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))
        let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: MTLSamplerDescriptor()))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        func render(hdr: Float, value: Float = 4) throws -> UInt8 {
            let pixel: [Float] = [value, value, value, 1]
            pixel.withUnsafeBytes { input.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: 16) }
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            var uniforms = CompositeUniforms(params: .zero, tint: .zero,
                                              params2: SIMD4(0, 0, 0, hdr))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 1)
            for index in 0..<3 { encoder.setFragmentTexture(input, index: index) }
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 4,
                from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
            return bytes[0]
        }
        XCTAssertEqual(try render(hdr: 0), 255, "The legacy curve clips this HDR fixture")
        let mapped = try render(hdr: 1)
        XCTAssertGreaterThan(mapped, 200)
        XCTAssertLessThan(mapped, 254, "Ray-traced highlights retain headroom without enabling SSAO")
        let dark = try render(hdr: 1, value: 0.03)
        let exposed = 0.03 * 0.92
        let aces = (exposed * (2.51 * exposed + 0.03)) / (exposed * (2.43 * exposed + 0.59) + 0.14)
        let encoded = 1.055 * pow(aces, 1.0 / 2.4) - 0.055
        XCTAssertEqual(Double(dark), encoded * 255, accuracy: 1,
            "Linear ray radiance needs display encoding on the actual BGRA8Unorm target")
        XCTAssertGreaterThan(dark, 30, "Dim stone must not be crushed into near-black display values")
        XCTAssertEqual(try render(hdr: 0, value: 0.03), 8,
            "The legacy raster/UI display path must not be gamma-encoded twice")
    }

    func testHalfResolutionCloudUpsampleDoesNotBleedAcrossFullResolutionTerrainEdge() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: GAME_MSL + """
        struct CloudTestDepth { float depth [[depth(any)]]; };
        fragment CloudTestDepth cloud_test_depth_fs(FSVOut in [[stage_in]]) {
            CloudTestDepth out; out.depth = in.uv.x < 0.5 ? 0.2 : 1.0; return out;
        }
        """, options: nil)
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
            width: 4, height: 4, mipmapped: false)
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        let layerDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: 2, height: 2, mipmapped: false)
        layerDescriptor.usage = .shaderRead
        let layer = try XCTUnwrap(device.makeTexture(descriptor: layerDescriptor))
        // Type the upload before flatMap: mixing an explicit Float with untyped decimal literals
        // otherwise infers [Any] and uploads existential containers instead of RGBA float bytes.
        let layerPixel: [Float] = [0.25, 0.5, 0.75, 0.8]
        let layerPixels = Array(repeating: layerPixel, count: 4).flatMap { $0 }
        layerPixels.withUnsafeBytes { layer.replace(region: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 2 * 16) }
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: 4, height: 4, mipmapped: false)
        outputDescriptor.usage = .renderTarget
        let output = try XCTUnwrap(device.makeTexture(descriptor: outputDescriptor))
        let depthPipelineDescriptor = MTLRenderPipelineDescriptor()
        depthPipelineDescriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "fs_vs"))
        depthPipelineDescriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "cloud_test_depth_fs"))
        depthPipelineDescriptor.depthAttachmentPixelFormat = .depth32Float
        let depthPipeline = try device.makeRenderPipelineState(descriptor: depthPipelineDescriptor)
        let colorPipelineDescriptor = MTLRenderPipelineDescriptor()
        colorPipelineDescriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "fs_vs"))
        colorPipelineDescriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "cloud_composite_fs"))
        colorPipelineDescriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let colorPipeline = try device.makeRenderPipelineState(descriptor: colorPipelineDescriptor)
        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = .always
        depthStateDescriptor.isDepthWriteEnabled = true
        let depthState = try XCTUnwrap(device.makeDepthStencilState(descriptor: depthStateDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let depthPass = MTLRenderPassDescriptor()
        depthPass.depthAttachment.texture = depth
        depthPass.depthAttachment.loadAction = .clear
        depthPass.depthAttachment.storeAction = .store
        depthPass.depthAttachment.clearDepth = 1
        let depthEncoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: depthPass))
        depthEncoder.setRenderPipelineState(depthPipeline)
        depthEncoder.setDepthStencilState(depthState)
        depthEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        depthEncoder.endEncoding()
        let colorPass = MTLRenderPassDescriptor()
        colorPass.colorAttachments[0].texture = output
        colorPass.colorAttachments[0].loadAction = .clear
        colorPass.colorAttachments[0].storeAction = .store
        let colorEncoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: colorPass))
        var atmosphere = AtmosphereUniforms()
        atmosphere.cameraTime.y = 70
        var environment = EnvironmentRenderUniforms(inverseViewProjection: matrix_identity_float4x4,
            atmosphere: atmosphere, viewport: SIMD4(4, 4, 0.25, 0.25))
        colorEncoder.setRenderPipelineState(colorPipeline)
        colorEncoder.setFragmentTexture(layer, index: 0)
        colorEncoder.setFragmentTexture(depth, index: 1)
        colorEncoder.setFragmentBytes(&environment, length: MemoryLayout<EnvironmentRenderUniforms>.stride, index: 3)
        colorEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        colorEncoder.endEncoding()
        let depthReadback = device.makeBuffer(length: 1024, options: .storageModeShared)!
        let inspect = command.makeBlitCommandEncoder()!
        inspect.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                     sourceSize: .init(width: 4, height: 4, depth: 1), to: depthReadback,
                     destinationOffset: 0, destinationBytesPerRow: 256, destinationBytesPerImage: 1024)
        inspect.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var pixels = [Float](repeating: 0, count: 4 * 4 * 4)
        pixels.withUnsafeMutableBytes { output.getBytes($0.baseAddress!, bytesPerRow: 4 * 16,
            from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0) }
        for y in 0..<4 {
            let row = depthReadback.contents().advanced(by: y * 256).assumingMemoryBound(to: Float.self)
            for x in 0..<4 { XCTAssertEqual(row[x], x < 2 ? 0.2 : 1.0, accuracy: 0.00001) }
        }
        for y in 0..<2 {
            for x in 0..<4 {
                let offset = (y * 4 + x) * 4
                if x < 2 {
                    for channel in 0..<4 { XCTAssertEqual(pixels[offset + channel], 0) }
                } else {
                    XCTAssertEqual(pixels[offset], 0.25, accuracy: 0.00001)
                    XCTAssertEqual(pixels[offset + 3], 0.8, accuracy: 0.00001)
                }
            }
        }
    }

    func testMetalDielectricReflectanceAndWaterExitTotalInternalReflection() throws {
        let result = try evaluate()
        XCTAssertEqual(result[0].x, 0.02037, accuracy: 0.0001)
        XCTAssertGreaterThan(result[0].y, 0.70)
        XCTAssertEqual(result[0].z, 1)
        XCTAssertEqual(result[0].w, 0, "Equal refractive indices do not create a grazing-angle mirror")
    }

    /// Runs the actual raster fragment entrypoints with controlled surface/depth inputs. The
    /// fixture vertex stage changes no shading logic; it isolates refraction from mesh culling.
    private func rasterWaterPixel(fragment: String, surfaceDepth: Float = 0.5,
                                  sceneDepth: Float = 1, surfacePosition: SIMD3<Float> = SIMD3(0, 1, 0)) throws -> SIMD4<Float> {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let library = try device.makeLibrary(source: GAME_MSL + """
        vertex ChunkVOut water_regression_vs(uint vertexID [[vertex_id]],
                                               constant float4& fixture [[buffer(0)]]) {
            float2 p = float2(vertexID == 1 ? 3.0 : -1.0, vertexID == 2 ? 3.0 : -1.0);
            ChunkVOut out;
            out.clip = float4(p, fixture.w, 1);
            out.worldPos = fixture.xyz;
            out.faceNormal = float3(0,-1,0); out.materialTint = float3(0.25,0.46,0.89);
            out.uv = float2(0.5); out.color = float3(1); out.fogDist = 0;
            out.localMaterial = float3(0); out.localFallback = float3(0);
            out.shadowPos = float4(0); out.skyAmt = 1; out.layer = 0; out.anim = 1;
            return out;
        }
        """, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = try XCTUnwrap(library.makeFunction(name: "water_regression_vs"))
        pipelineDescriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: fragment))
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba32Float
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
            width: 1, height: 1, mipmapped: false)
        colorDescriptor.usage = .shaderRead
        let background = try XCTUnwrap(device.makeTexture(descriptor: colorDescriptor))
        let black: [Float] = [0, 0, 0, 1]
        black.withUnsafeBytes { background.replace(region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16) }
        colorDescriptor.textureType = .type2DArray
        colorDescriptor.arrayLength = 1
        let atlas = try XCTUnwrap(device.makeTexture(descriptor: colorDescriptor))
        let white: [Float] = [1, 1, 1, 1]
        white.withUnsafeBytes { atlas.replace(region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0, slice: 0, withBytes: $0.baseAddress!, bytesPerRow: 16, bytesPerImage: 16) }
        colorDescriptor.textureType = .type2D
        colorDescriptor.usage = .renderTarget
        let output = try XCTUnwrap(device.makeTexture(descriptor: colorDescriptor))
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
            width: 1, height: 1, mipmapped: false)
        depthDescriptor.usage = [.renderTarget, .shaderRead]
        depthDescriptor.storageMode = .private
        let depth = try XCTUnwrap(device.makeTexture(descriptor: depthDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let depthPass = MTLRenderPassDescriptor()
        depthPass.depthAttachment.texture = depth
        depthPass.depthAttachment.loadAction = .clear
        depthPass.depthAttachment.storeAction = .store
        depthPass.depthAttachment.clearDepth = Double(sceneDepth)
        let clearEncoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: depthPass))
        clearEncoder.endEncoding()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
        var fixture = SIMD4<Float>(surfacePosition, surfaceDepth)
        var chunk = ChunkSharedU(viewProj: matrix_identity_float4x4, shadowMat: matrix_identity_float4x4,
            light: SIMD4(1, 0, 0, 0), fog: SIMD4(100, 200, 0, 1),
            fogColor: SIMD4(0.01, 0.02, 0.03, 1), misc: SIMD4(0, 1, 0, 0), heldLight: .zero)
        var atmosphere = AtmosphereUniforms()
        atmosphere.cameraTime = SIMD4(0, 70, 0, 0)
        atmosphere.sunDaylight = SIMD4(simd_normalize(SIMD3<Float>(0.2, 0.9, 0.25)), 1)
        atmosphere.weather = SIMD4(0, 0, 0, 1)
        atmosphere.options.z = 0 // exclude the solar disc from this sky-transmission fixture
        atmosphere.fogColor = SIMD4(0.01, 0.02, 0.03, 1)
        var environment = EnvironmentRenderUniforms(inverseViewProjection: matrix_identity_float4x4,
            atmosphere: atmosphere, viewport: SIMD4(1, 1, 1, 1))
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&fixture, length: 16, index: 0)
        encoder.setFragmentBytes(&chunk, length: MemoryLayout<ChunkSharedU>.stride, index: 1)
        encoder.setFragmentBytes(&environment, length: MemoryLayout<EnvironmentRenderUniforms>.stride, index: 3)
        encoder.setFragmentTexture(atlas, index: 0)
        let localDescriptor = MTLTextureDescriptor()
        localDescriptor.textureType = .type3D
        localDescriptor.pixelFormat = .rgba8Unorm
        localDescriptor.usage = .shaderRead
        let emptyLocal = try XCTUnwrap(device.makeTexture(descriptor: localDescriptor))
        var emptyPixel: UInt32 = 0
        emptyLocal.replace(region: MTLRegionMake3D(0, 0, 0, 1, 1, 1), mipmapLevel: 0, slice: 0,
                           withBytes: &emptyPixel, bytesPerRow: 4, bytesPerImage: 4)
        var localUniforms = RenderLocalLightUniforms(originAndSize: SIMD4(0, 0, 0, 1), params: .zero)
        encoder.setFragmentTexture(emptyLocal, index: 7)
        encoder.setFragmentBytes(&localUniforms, length: MemoryLayout<RenderLocalLightUniforms>.stride, index: 7)
        encoder.setFragmentTexture(background, index: 2)
        for index in [1, 3, 4] { encoder.setFragmentTexture(depth, index: index) }
        let sampler = try XCTUnwrap(device.makeSamplerState(descriptor: MTLSamplerDescriptor()))
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        XCTAssertEqual(command.status, .completed)
        var result = SIMD4<Float>.zero
        withUnsafeMutableBytes(of: &result) { output.getBytes($0.baseAddress!, bytesPerRow: 16,
            from: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0) }
        return result
    }

    func testRasterUnderwaterExitShowsSkyWithoutLeakingSkyThroughTIRorGeometry() throws {
        let sky = try rasterWaterPixel(fragment: "water_fs")
        XCTAssertGreaterThan(sky.z, 0.75, "The open water surface must transmit sky, not underwater fog-clear color")
        XCTAssertGreaterThan(sky.z, sky.x)
        let solid = try rasterWaterPixel(fragment: "water_fs", sceneDepth: 0.8)
        XCTAssertLessThan(solid.z, 0.10, "An opaque ceiling must not be replaced by the air-side sky")
        let totalReflection = try rasterWaterPixel(fragment: "water_fs", surfacePosition: SIMD3(4, 1, 0))
        XCTAssertLessThan(totalReflection.z, 0.10, "Total internal reflection must not leak sky outside Snell's window")
    }

    func testDistantSubmergedGlassSurvivesWhileCoplanarAndForegroundGlassAreExcluded() throws {
        // This 5e-6 separation is smaller than the old bias but represents about one block at
        // 100 blocks viewing distance with the actual camera's 0.05 near plane.
        let behind = try rasterWaterPixel(fragment: "translucent_refraction_fs",
            surfaceDepth: 0.999505, sceneDepth: 0.9995)
        XCTAssertEqual(behind, SIMD4(1, 1, 1, 1))
        let coplanar = try rasterWaterPixel(fragment: "translucent_refraction_fs",
            surfaceDepth: 0.9995, sceneDepth: 0.9995)
        XCTAssertEqual(coplanar, .zero)
        let foreground = try rasterWaterPixel(fragment: "translucent_refraction_fs",
            surfaceDepth: 0.99949, sceneDepth: 0.9995)
        XCTAssertEqual(foreground, .zero)
    }

    func testWaveNormalsRespectUpperLowerAndFlowingSideFaces() throws {
        let result = try evaluate()
        for index in 1...3 {
            let n = SIMD3(result[index].x, result[index].y, result[index].z)
            XCTAssertEqual(simd_length(n), 1, accuracy: 0.00001)
        }
        XCTAssertGreaterThan(result[1].y, 0.97)
        XCTAssertLessThan(result[2].y, -0.97)
        XCTAssertEqual(result[1].x, -result[2].x, accuracy: 0.00001)
        XCTAssertEqual(result[1].z, -result[2].z, accuracy: 0.00001)
        XCTAssertGreaterThan(result[3].x, 0.99)
        XCTAssertEqual(result[3].y, 0, accuracy: 0.00001)
    }

    func testAbsorptionIsDepthDependentAndScatteringDoesNotHideShallowArt() throws {
        let result = try evaluate()
        XCTAssertEqual(result[4], SIMD4(1, 1, 1, 1))
        for channel in 0..<3 {
            XCTAssertGreaterThan(result[6][channel], result[5][channel])
            XCTAssertGreaterThan(result[5][channel], 0)
            XCTAssertEqual(result[7][channel], 0)
            XCTAssertLessThan(result[8][channel], result[9][channel])
        }
        XCTAssertLessThan(result[5].x, result[5].y)
        XCTAssertLessThan(result[5].y, result[5].z)
        XCTAssertEqual(result[10].y, 0, "Foam is confined to the shoreline, not painted over deep water")
        XCTAssertGreaterThan(result[10].z, 0.15)
        XCTAssertLessThanOrEqual(result[10].z, 0.17)
    }

    func testCloudLayerIsBoundedByOpaqueDepthAndHasWeatherDependentCoverage() throws {
        var e = AtmosphereUniforms()
        let clear = try evaluate(e)
        XCTAssertEqual(clear[11], SIMD4(0, 0, 0, 1), "Opaque terrain below cloud base occludes clouds")
        e.weather.x = 1
        let rainy = try evaluate(e)
        let clearTransmission = clear[16...].reduce(Float(0)) { $0 + $1.w }
        let rainTransmission = rainy[16...].reduce(Float(0)) { $0 + $1.w }
        XCTAssertLessThan(rainTransmission, clearTransmission)
        XCTAssertLessThan(clearTransmission, 64, "The real GPU sampled visible fair-weather cloud volume")
        for value in clear + rainy {
            for channel in 0..<4 { XCTAssertTrue(value[channel].isFinite) }
        }
        for value in Array(clear[16...]) + Array(rainy[16...]) {
            XCTAssertGreaterThanOrEqual(value.w, 0)
            XCTAssertLessThanOrEqual(value.w, 1)
            for channel in 0..<3 { XCTAssertGreaterThanOrEqual(value[channel], 0) }
        }
    }

    func testCloudControlsExcludeOtherDimensionsAndUnderwater() throws {
        let cases: [(Float, Float, Float)] = [(0, 0, 0), (1, 1, 0), (2, 1, 0), (0, 1, 1)]
        for (dimension, enabled, underwater) in cases {
            var e = AtmosphereUniforms()
            e.options.x = dimension; e.weather.z = enabled; e.weather.w = underwater
            let result = try evaluate(e)
            XCTAssertEqual(result[15].x, 1)
            for cloud in result[16...] { XCTAssertEqual(cloud, SIMD4(0, 0, 0, 1)) }
        }
    }

    func testAbsolutePositionNotCameraTranslationAnchorsCloudsAndWater() throws {
        var e = AtmosphereUniforms()
        e.cameraTime = SIMD4(20, 70, -10, 12)
        let first = try evaluate(e)
        e.cameraTime = SIMD4(-930, 98, 617, 12)
        let movedCamera = try evaluate(e)
        XCTAssertEqual(first, movedCamera, "Changing the view origin must not transport stationary world-space effects")
    }

    func testSecondaryRayExitingWaterSeesAirWhileCameraRemainsUnderwater() throws {
        var environment = AtmosphereUniforms()
        let air = try evaluate(environment)[12]
        environment.weather.w = 1
        let water = try evaluate(environment)[12]
        XCTAssertNotEqual(water, air)
        environment.options.w = 1 // probe requests the explicit per-ray air helper
        let escaped = try evaluate(environment)[12]
        XCTAssertEqual(escaped, air, "Camera submersion must not suppress the sky after a refracted ray exits water")
    }

    func testReducedMotionFreezesCloudWindAndNightSkyRemainsFinite() throws {
        var e = AtmosphereUniforms()
        e.options.y = 1
        let first = try evaluate(e)
        e.cameraTime.w = 1000
        XCTAssertEqual(first, try evaluate(e))
        e.sunDaylight = SIMD4(0, -1, 0, 0.06)
        e.zenith = SIMD4(0.012, 0.015, 0.04, 0)
        e.horizon = SIMD4(0.04, 0.05, 0.1, 0)
        let night = try evaluate(e)
        for index in 12...14 {
            for channel in 0..<3 {
                XCTAssertTrue(night[index][channel].isFinite)
                XCTAssertGreaterThan(night[index][channel], 0)
            }
        }
    }
}
