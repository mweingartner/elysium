import Foundation
import Metal
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// Actual geometry visibility, not a CPU approximation of the leaf attenuation formula.
/// The neutral transmission and fill are bounded rendering choices, not botanical measurements.
final class RayTracingCanopyLightingTests: XCTestCase {
    func testOnlyRegisteredLeafTilesReceiveCanopyTransmission() throws {
        registerAllBlocks()
        let empty = MeshLayer(data: [], idx: [], count: 0)
        func flags(_ tile: String) throws -> UInt32 {
            var words: [UInt32] = []
            let positions: [SIMD3<Float>] = [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,0,1)]
            for p in positions {
                words += [p.x.bitPattern,p.y.bitPattern,p.z.bitPattern,0,0,
                          UInt32(tileId(tile)) | 1<<12 | 15<<17,0xffffff]
            }
            let mesh = MeshOutput(opaque: empty,
                cutout: MeshLayer(data: words, idx: [0,1,2], count: 3), translucent: empty)
            return try XCTUnwrap(RayTracingMeshDecoder.decode(mesh)?.primitives.first).material.z
        }
        for wood in LEAF_WOODS {
            XCTAssertEqual(try flags("\(wood)_leaves") & 33, 33)
        }
        for tile in ["stone", "glass", "oak_planks", "iron_bars", "mangrove_roots", "grass"] {
            XCTAssertEqual(try flags(tile) & 32, 0, "Generic cutouts/fence art must not transmit like leaves")
            XCTAssertEqual(try flags(tile) & 1, 1, "Keep ordinary cutout semantics unchanged")
        }
    }

    func testActualCanopyVisibilityIsNeutralLayeredStableAndNeverPassesStone() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsRaytracing else {
            throw XCTSkip("Requires actual Metal ray tracing")
        }
        let source = ELYSIUM_ENVIRONMENT_MSL + RAY_TRACING_MSL + """
        // Pre-optimization surface-decoding implementation, kept only as a GPU oracle.
        static float3 canopy_reference_visibility(float3 position,float3 normal,float3 direction,float distance,
            instance_acceleration_structure scene,device const RTInstance* instances,
            constant RTTextures& textures,texture2d_array<float> atlas,
            intersection_function_table<triangle_data,instancing> functions) {
            ray r; r.origin=position+normal*0.003; r.direction=direction;
            r.min_distance=0.001; r.max_distance=max(0.002,distance-0.008);
            float3 t(1);
            for(uint layer=0;layer<8;++layer) {
                RTSurface s=rtIntersect(r,scene,instances,textures,atlas,functions);
                if(!s.hit) return t;
                if((s.flags&32u)!=0) t*=0.62;
                else if((s.flags&6u)!=0) t*=((s.flags&2u)!=0)?float3(0.7,0.86,0.92):mix(float3(1),s.albedo,0.35);
                else return float3(0);
                r.min_distance=s.distance+0.003;
                if(r.min_distance>=r.max_distance) return t;
            }
            return float3(0);
        }
        kernel void canopy_probe(instance_acceleration_structure scene [[buffer(0)]],
                                 device const RTInstance* instances [[buffer(1)]],
                                 constant RTTextures& textures [[buffer(2)]],
                                 device float4* result [[buffer(3)]],
                                 constant RTUniforms* uniforms [[buffer(4)]],
                                 device float4* reference [[buffer(5)]],
                                 intersection_function_table<triangle_data,instancing> functions [[buffer(6)]],
                                 texture2d_array<float> atlas [[texture(0)]],
                                 uint index [[thread_position_in_grid]]) {
            if(index<160 || index>=164) {
                uint scenario=index<160?index%10:index-154;
                float3 t=rtVisibility(float3(float(scenario)*4+0.2,0,0.1),float3(0,1,0),
                    float3(0,1,0),20,scene,instances,textures,atlas,functions);
                result[index]=float4(t,1);
                reference[index]=float4(canopy_reference_visibility(float3(float(scenario)*4+0.2,0,0.1),
                    float3(0,1,0),float3(0,1,0),20,scene,instances,textures,atlas,functions),1);
            } else if(index==160) {
                result[index]=float4(rtDirectLightCosine(float3(0,1,0),float3(0,1,0),32),
                    rtDirectLightCosine(float3(0,-1,0),float3(0,1,0),32),
                    rtDirectLightCosine(float3(0,-1,0),float3(0,1,0),0),
                    rtDirectLightCosine(float3(1,0,0),float3(0,1,0),32));
            } else if(index==161) {
                result[index]=float4(rtCachedIllumination(1,0,uniforms[0]),
                    rtCachedIllumination(0.5,0,uniforms[0]),rtCachedIllumination(0,0,uniforms[0]),
                    rtCachedIllumination(1,0,uniforms[1]));
            } else if(index==162) {
                result[index]=float4(rtCachedIllumination(1,0,uniforms[2]),
                    rtCachedIllumination(0,0,uniforms[2]),rtCachedIllumination(1,0,uniforms[3]),
                    rtCachedIllumination(0,0,uniforms[3]));
            } else {
                result[index]=float4(rtCachedIllumination(1,0,uniforms[4]),
                    rtCachedIllumination(1,0,uniforms[5]),
                    rtCachedIllumination(0,1,uniforms[0]),rtCachedIllumination(0,0.5,uniforms[0]));
            }
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let function = try XCTUnwrap(library.makeFunction(name: "canopy_probe"))
        let alphaPipeline = try XCTUnwrap(try RayTracingAlphaPipeline(device:device,library:library,function:function))
        let pipeline = alphaPipeline.pipeline
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            try values.withUnsafeBytes { try XCTUnwrap(device.makeBuffer(bytes: $0.baseAddress!,
                length: $0.count, options: .storageModeShared)) }
        }
        var positions: [SIMD3<Float>] = [], primitives: [RayTracingPrimitive] = []
        func surface(column: Int, y: Float, flags: UInt32, tile: UInt32 = 0, normalY: Float = 1) {
            let x = Float(column) * 4
            let a = SIMD3<Float>(x-1.5,y,-1.5), b = SIMD3<Float>(x+1.5,y,-1.5)
            let c = SIMD3<Float>(x+1.5,y,1.5), d = SIMD3<Float>(x-1.5,y,1.5)
            positions += [a,b,c,a,c,d]
            for _ in 0..<2 {
                primitives.append(.init(uv01: .init(repeating: 0.5), uv2Light: .init(0.5,0.5,1,0),
                    normalEmission: .init(0,normalY,0,0), material: .init(0xffffff,tile,flags,0)))
            }
        }
        for column in 1...3 { for face in 0..<(column*2) { surface(column: column, y: Float(face+1), flags: 33) } }
        surface(column: 4, y: 1, flags: 0) // solid roof
        for face in 1...2 { surface(column: 5, y: Float(face), flags: 33, tile: 1) } // actual alpha holes
        surface(column: 6, y: 1, flags: 1) // opaque texel of a non-leaf cutout
        surface(column: 7, y: 1, flags: 33); surface(column: 7, y: 2, flags: 0)
        for face in 1...10 { surface(column: 8, y: Float(face), flags: 33) } // continuation budget fails closed
        for face in 1...2 { surface(column: 9, y: Float(face), flags: 33, tile: 2) } // saturated art, neutral transport
        for face in 1...2 { surface(column: 10, y: Float(face), flags: 2) }
        // The camera is below the glass slab: its lower face points down (entry), upper
        // face up (exit). Two upward normals falsely start the ray inside glass and cause
        // total internal reflection at this grazing angle, never exercising both lobes.
        for face in 1...2 { surface(column: 11, y: Float(face), flags: 4, tile: 2, normalY: face == 1 ? -1:1) }
        surface(column: 12, y: 1, flags: 2)
        surface(column: 12, y: 2, flags: 4, tile: 2)
        surface(column: 12, y: 3, flags: 33)
        for face in 0..<100 { surface(column: 13, y: 1+Float(face)*0.02, flags: 33, tile: 1) }
        surface(column: 14, y: 1, flags: 9) // independently fading entity, not an alpha-cutout texel
        surface(column: 14, y: 1.01, flags: 0, tile: 2)
        surface(column: 15, y: 1, flags: 33) // backlit leaf completely shadowed by a nearby roof
        surface(column: 15, y: 1.01, flags: 0)
        let vertices = try buffer(positions), payload = try buffer(primitives)
        let triangles = MTLAccelerationStructureTriangleGeometryDescriptor()
        triangles.vertexBuffer = vertices; triangles.vertexStride = MemoryLayout<SIMD3<Float>>.stride
        triangles.vertexFormat = .float3; triangles.triangleCount = primitives.count; triangles.opaque = true
        triangles.primitiveDataBuffer = payload
        triangles.primitiveDataStride = MemoryLayout<RayTracingPrimitive>.stride
        triangles.primitiveDataElementSize = MemoryLayout<RayTracingPrimitive>.stride
        let bottomDescriptor = MTLPrimitiveAccelerationStructureDescriptor()
        bottomDescriptor.geometryDescriptors = [triangles]
        let bottomSize = device.accelerationStructureSizes(descriptor: bottomDescriptor)
        let bottom = try XCTUnwrap(device.makeAccelerationStructure(size: bottomSize.accelerationStructureSize))
        let bottomScratch = try XCTUnwrap(device.makeBuffer(length: max(1,bottomSize.buildScratchBufferSize), options: .storageModePrivate))
        let buildBottom = try XCTUnwrap(command.makeAccelerationStructureCommandEncoder())
        buildBottom.build(accelerationStructure: bottom, descriptor: bottomDescriptor,
            scratchBuffer: bottomScratch, scratchBufferOffset: 0)
        buildBottom.endEncoding()
        var instance = MTLAccelerationStructureInstanceDescriptor()
        instance.transformationMatrix = MTLPackedFloat4x3(columns: (MTLPackedFloat3Make(1,0,0),
            MTLPackedFloat3Make(0,1,0),MTLPackedFloat3Make(0,0,1),MTLPackedFloat3Make(0,0,0)))
        instance.mask = 0xff; instance.options = .opaque; instance.accelerationStructureIndex = 0
        let instanceDescriptors = try buffer([instance])
        let topDescriptor = MTLInstanceAccelerationStructureDescriptor()
        topDescriptor.instancedAccelerationStructures = [bottom]
        topDescriptor.instanceCount = 1; topDescriptor.instanceDescriptorBuffer = instanceDescriptors
        topDescriptor.instanceDescriptorStride = MemoryLayout<MTLAccelerationStructureInstanceDescriptor>.stride
        let topSize = device.accelerationStructureSizes(descriptor: topDescriptor)
        let top = try XCTUnwrap(device.makeAccelerationStructure(size: topSize.accelerationStructureSize))
        let topScratch = try XCTUnwrap(device.makeBuffer(length: max(1,topSize.buildScratchBufferSize), options: .storageModePrivate))
        let buildTop = try XCTUnwrap(command.makeAccelerationStructureCommandEncoder())
        buildTop.build(accelerationStructure: top, descriptor: topDescriptor, scratchBuffer: topScratch, scratchBufferOffset: 0)
        buildTop.endEncoding()
        let instanceData = try buffer([RayTracingInstanceUniforms(transform: matrix_identity_float4x4,
            normalTransform: matrix_identity_float4x4, previousFromCurrent: matrix_identity_float4x4,
            tint: SIMD4(repeating: 1), overlay: .zero, info: .zero)])
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 1, height: 1, mipmapped: false)
        textureDescriptor.textureType = .type2DArray; textureDescriptor.arrayLength = 3; textureDescriptor.usage = .shaderRead
        let atlas = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let tilePixels: [[UInt8]] = [[255,255,255,255], [255,255,255,0], [8,240,12,255]]
        for (slice, rgba) in tilePixels.enumerated() {
            rgba.withUnsafeBytes { atlas.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0,
                slice: slice, withBytes: $0.baseAddress!, bytesPerRow: 4, bytesPerImage: 4) }
        }
        textureDescriptor.textureType = .type2D; textureDescriptor.arrayLength = 1
        let entityTexture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        var white = UInt32.max
        entityTexture.replace(region: MTLRegionMake2D(0,0,1,1), mipmapLevel: 0, withBytes: &white, bytesPerRow: 4)
        let textureEncoder = function.makeArgumentEncoder(bufferIndex: 2)
        let arguments = try XCTUnwrap(device.makeBuffer(length: textureEncoder.encodedLength, options: .storageModeShared))
        textureEncoder.setArgumentBuffer(arguments, offset: 0)
        for index in 0..<512 { textureEncoder.setTexture(entityTexture, index: index) }
        textureEncoder.setTexture(atlas,index:512)
        let alphaFunctions=try XCTUnwrap(alphaPipeline.makeTable(instances:instanceData,textures:arguments))
        var uniform = RayTracingUniforms(inverseViewProjection: matrix_identity_float4x4,
            viewProjection: matrix_identity_float4x4, previousViewProjection: matrix_identity_float4x4,
            cameraDelta: .zero, params: .zero, heldLight: .zero, fogParameters: .zero,
            quality: .zero, counts: .zero, atmosphere: AtmosphereUniforms())
        var uniforms = [uniform]
        uniform.atmosphere.sunDaylight = .init(0,-1,0,0.06); uniforms.append(uniform)
        uniform.atmosphere.options.x = 1; uniforms.append(uniform)
        uniform.atmosphere.options.x = 2; uniforms.append(uniform)
        uniform.atmosphere.options.x = 0
        uniform.atmosphere.sunDaylight = .init(1,0.0001,0,0.5002); uniforms.append(uniform)
        uniform.atmosphere.sunDaylight = .init(1,-0.0001,0,0.4998); uniforms.append(uniform)
        let uniformBuffer = try buffer(uniforms)
        let result = try XCTUnwrap(device.makeBuffer(length: 168 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        let reference = try XCTUnwrap(device.makeBuffer(length: result.length, options: .storageModeShared))
        let compute = try XCTUnwrap(command.makeComputeCommandEncoder())
        compute.setComputePipelineState(pipeline); compute.setAccelerationStructure(top, bufferIndex: 0)
        compute.setBuffer(instanceData, offset: 0, index: 1); compute.setBuffer(arguments, offset: 0, index: 2)
        compute.setBuffer(result, offset: 0, index: 3); compute.setBuffer(uniformBuffer, offset: 0, index: 4)
        compute.setBuffer(reference, offset: 0, index: 5)
        compute.setIntersectionFunctionTable(alphaFunctions,bufferIndex:6)
        compute.setTexture(atlas, index: 0)
        compute.useResource(bottom, usage: .read); compute.useResource(entityTexture, usage: .read)
        compute.dispatchThreads(.init(width: 168,height: 1,depth: 1), threadsPerThreadgroup: .init(width: 16,height: 1,depth: 1))
        compute.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "Canopy GPU probe failed")
        let values = result.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let referenceValues = reference.contents().assumingMemoryBound(to: SIMD4<Float>.self)
        let expected: [Float] = [1,0.3844,0.14776336,0.056800235584,0,1,0,0,0,0.3844]
        for index in 0..<160 {
            for channel in 0..<3 { XCTAssertEqual(values[index][channel], expected[index%10], accuracy: 0.00001) }
            XCTAssertEqual(values[index], values[index%10], "Repeated actual rays must not introduce stochastic canopy flicker")
        }
        for index in Array(0..<160) + Array(164..<168) {
            for channel in 0..<4 {
                XCTAssertEqual(values[index][channel], referenceValues[index][channel], accuracy: 0.00001,
                    "Visibility-only decode must match full surface decode, including water/glass and accepted-layer limits")
            }
        }
        XCTAssertEqual(values[160], SIMD4(1,0.30,0,0))
        let expectedFill: [Float] = [0.185,0.08,0.045,0.0534]
        for (channel, value) in expectedFill.enumerated() {
            XCTAssertEqual(values[161][channel], value, accuracy: 0.00001)
        }
        for (channel,value) in [Float(0.045),0.045,0.045,0.045].enumerated() {
            XCTAssertEqual(values[162][channel],value,accuracy:0.00001)
        }
        XCTAssertEqual(values[163].x, 0.115028, accuracy: 0.00001)
        XCTAssertEqual(values[163].y, 0.114972, accuracy: 0.00001)
        XCTAssertLessThan(abs(values[163].x-values[163].y), 0.0001,
            "Crossing the horizon must not switch the canopy fill between day/night constants")
        XCTAssertEqual(values[163].z, 0.68, accuracy: 0.00001,
            "Full legacy block light must use the same 0.40 diffuse response as the local field")
        XCTAssertEqual(values[163].w, 0.136, accuracy: 0.00001,
            "Half-strength cached light must retain the optical curve without a field-boundary boost")

        // Test-only variants of the actual path-tracing kernel: a counter records real solar
        // visibility evaluations, and one exact substitution disables only primary reuse.
        // No runtime preference or alternate production algorithm is introduced for testing.
        let reuseNeedle = "bool reusePrimarySolar = firstSurface && primarySolarValid"
        let primaryReuseNeedle = "if(bounce==0 && sample>0) s=primarySurface;"
        // Count entry to the unique primary/continuation call independently of its
        // trailing texture-footprint arguments; the full production call stays intact.
        let intersectionNeedle = "s=rtIntersect(r,scene,instances,textures,atlas,functions,primaryPending?0x01:0xff,"
        let signatureNeedle = "device const RTLight* lights [[buffer(3)]],"
        let visibilityNeedle = "float3 visibility=u.params.w>0.5"
        let cloudGuardNeedle = "if(any(visibility>float3(0))) clouds="
        let cloudNeedle = "elyCloudSunTransmittanceAir(worldPosition,u.atmosphere)"
        let fadeNeedle = "r.origin=s.position+r.direction*0.004; r.min_distance=0.001; continue;"
        let dielectricNeedle = "if(firstSurface && !totalReflection) throughput*=reflected?2*fresnel:2*(1-fresnel);"
        let helperStart = try XCTUnwrap(RAY_TRACING_MSL.range(of:"static RTPathResult rtTracePixel(")).lowerBound
        let helperEnd = try XCTUnwrap(RAY_TRACING_MSL.range(of:"\nkernel void rt_pathtrace")).lowerBound
        let helperRange = helperStart..<helperEnd
        let helperSource = String(RAY_TRACING_MSL[helperRange])
        for needle in [reuseNeedle,primaryReuseNeedle,intersectionNeedle,visibilityNeedle,
                       cloudGuardNeedle,cloudNeedle,fadeNeedle,dielectricNeedle] {
            XCTAssertEqual(helperSource.components(separatedBy: needle).count, 2,
                "Instrumentation must target exactly one production statement")
        }
        func tracePrimary(cached: Bool = true, primaryCached: Bool = true, skipBlockedClouds: Bool = true,
                          samples: Float = 4, column: Float = 1, entityAlpha: Float = 1,
                          clouds: Bool = false) throws -> (pixels: [[Float]], evaluations: [UInt32]) {
            var helper = helperSource
            if !cached { helper = helper.replacingOccurrences(of: reuseNeedle,
                with: "bool reusePrimarySolar = false && firstSurface && primarySolarValid") }
            if !primaryCached { helper = helper.replacingOccurrences(of: primaryReuseNeedle,
                with: "if(false && bounce==0 && sample>0) s=primarySurface;") }
            if !skipBlockedClouds { helper = helper.replacingOccurrences(of: cloudGuardNeedle,
                with: "if(true) clouds=") }
            let helperSignature = "texture3d<float,access::sample> localLightTexture,bool allowFactor) {"
            XCTAssertEqual(helper.components(separatedBy:helperSignature).count,2)
            helper = helper.replacingOccurrences(of:helperSignature,
                with:"texture3d<float,access::sample> localLightTexture,bool allowFactor,device atomic_uint* solarEvaluations=nullptr) {")
            helper = helper.replacingOccurrences(of: visibilityNeedle,
                with: "atomic_fetch_add_explicit(solarEvaluations,1u,memory_order_relaxed);\n" + visibilityNeedle)
            helper = helper.replacingOccurrences(of: intersectionNeedle,
                with: "if(bounce==0) atomic_fetch_add_explicit(solarEvaluations+1,1u,memory_order_relaxed);\n" + intersectionNeedle)
            helper = helper.replacingOccurrences(of: cloudNeedle,
                with: "(atomic_fetch_add_explicit(solarEvaluations+2,1u,memory_order_relaxed)," + cloudNeedle + ")")
            helper = helper.replacingOccurrences(of: fadeNeedle,
                with: "atomic_fetch_add_explicit(solarEvaluations+3,1u,memory_order_relaxed);\n" + fadeNeedle)
            helper = helper.replacingOccurrences(of: dielectricNeedle,
                with: "if(firstSurface && !totalReflection) atomic_fetch_add_explicit(solarEvaluations+(reflected?4:5),1u,memory_order_relaxed);\n" + dielectricNeedle)
            var shader = RAY_TRACING_MSL.replacingCharacters(in:helperRange,with:helper)
            let kernelStart = try XCTUnwrap(shader.range(of:"kernel void rt_pathtrace")).lowerBound
            let kernelEnd = try XCTUnwrap(shader.range(of:"// Deterministic fallback for native diffuse")).lowerBound
            let kernelRange = kernelStart..<kernelEnd
            var kernel = String(shader[kernelRange])
            XCTAssertEqual(kernel.components(separatedBy:signatureNeedle).count,2)
            kernel = kernel.replacingOccurrences(of:signatureNeedle,
                with:signatureNeedle + "\n device atomic_uint* solarEvaluations [[buffer(6)]],")
            let callNeedle = "atlas,localLightTexture,true);"
            XCTAssertEqual(kernel.components(separatedBy:callNeedle).count,2)
            kernel = kernel.replacingOccurrences(of:callNeedle,with:"atlas,localLightTexture,true,solarEvaluations);")
            shader = shader.replacingCharacters(in:kernelRange,with:kernel)
            let traceLibrary = try device.makeLibrary(source: ELYSIUM_ENVIRONMENT_MSL+shader, options: nil)
            let traceFunction = try XCTUnwrap(traceLibrary.makeFunction(name: "rt_pathtrace"))
            let traceAlphaPipeline=try XCTUnwrap(try RayTracingAlphaPipeline(device:device,library:traceLibrary,function:traceFunction))
            let tracePipeline = traceAlphaPipeline.pipeline
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float,
                width: 16, height: 16, mipmapped: false)
            textureDescriptor.usage = [.shaderRead,.shaderWrite]
            let outputs = try (0..<6).map { _ in try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor)) }
            let localDescriptor=MTLTextureDescriptor()
            localDescriptor.textureType = .type3D; localDescriptor.pixelFormat = .rgba8Unorm
            localDescriptor.width=1; localDescriptor.height=1; localDescriptor.depth=1
            localDescriptor.usage = .shaderRead
            let localTexture=try XCTUnwrap(device.makeTexture(descriptor:localDescriptor))
            var zero: UInt32=0
            localTexture.replace(region:MTLRegionMake3D(0,0,0,1,1,1),mipmapLevel:0,slice:0,
                withBytes:&zero,bytesPerRow:4,bytesPerImage:4)
            let skyDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                width: 1, height: 1, mipmapped: false)
            skyDescriptor.usage = .shaderRead
            let sky = try XCTUnwrap(device.makeTexture(descriptor: skyDescriptor)) // per-frame sky radiance input
            let counter = try buffer([UInt32](repeating: 0,count: 6))
            let lights = try buffer([RayTracingLight(positionRadius: .zero,colorPower: .zero)])
            // Narrowly target one column without moving the camera-relative acceleration structure.
            let projection = Elysium.mat4Perspective(fovYRad: 0.02 * .pi/180,aspect: 1,near: 0.05,far: 128)
            let view = Elysium.mat4LookDir(eye: .zero,dir: simd_normalize(SIMD3<Float>(column*4,1,0)),up: SIMD3(0,0,1))
            var frame = uniforms[0]
            frame.viewProjection = projection*view; frame.inverseViewProjection = frame.viewProjection.inverse
            frame.previousViewProjection = frame.viewProjection
            frame.params = .init(128,0.5,0,1); frame.quality = .init(samples,0,0,0)
            frame.counts = .init(7,0,16,16); frame.atmosphere.weather.z = clouds ? 1:0
            var instanceUniform = instanceData.contents().assumingMemoryBound(to: RayTracingInstanceUniforms.self).pointee
            instanceUniform.tint.w = entityAlpha
            let traceInstanceData = try buffer([instanceUniform])
            let traceAlphaFunctions=try XCTUnwrap(traceAlphaPipeline.makeTable(instances:traceInstanceData,textures:arguments))
            let traceCommand = try XCTUnwrap(queue.makeCommandBuffer())
            let trace = try XCTUnwrap(traceCommand.makeComputeCommandEncoder())
            trace.setComputePipelineState(tracePipeline); trace.setAccelerationStructure(top,bufferIndex: 0)
            trace.setBuffer(traceInstanceData,offset: 0,index: 1)
            trace.setBytes(&frame,length: MemoryLayout<RayTracingUniforms>.stride,index: 2)
            trace.setBuffer(lights,offset: 0,index: 3); trace.setBuffer(arguments,offset: 0,index: 4)
            trace.setIntersectionFunctionTable(traceAlphaFunctions,bufferIndex:5)
            trace.setBuffer(counter,offset: 0,index: 6); trace.setTexture(atlas,index: 0)
            for index in outputs.indices { trace.setTexture(outputs[index],index: index+1) }
            trace.setTexture(localTexture,index:7); trace.setTexture(sky,index:8)
            trace.useResource(bottom,usage: .read); trace.useResource(entityTexture,usage: .read)
            trace.dispatchThreads(.init(width: 16,height: 16,depth: 1),
                threadsPerThreadgroup: .init(width: 8,height: 8,depth: 1))
            trace.endEncoding(); traceCommand.commit(); traceCommand.waitUntilCompleted()
            XCTAssertEqual(traceCommand.status,.completed,traceCommand.error?.localizedDescription ?? "Primary solar GPU fixture failed")
            let pixels = outputs.map { output -> [Float] in
                var values = [Float](repeating: 0,count: 16*16*4)
                values.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow: 16*16,
                    from: MTLRegionMake2D(0,0,16,16),mipmapLevel: 0) }
                return values
            }
            return (pixels,Array(UnsafeBufferPointer(start: counter.contents().assumingMemoryBound(to: UInt32.self),count: 6)))
        }
        func assertEquivalent(_ optimized: [[Float]],_ reference: [[Float]],_ context: String,
                              file: StaticString = #filePath,line: UInt = #line) {
            for texture in optimized.indices {
                for index in optimized[texture].indices {
                    XCTAssertTrue(optimized[texture][index].isFinite,file: file,line: line)
                    XCTAssertEqual(optimized[texture][index],reference[texture][index],accuracy: 0.00001,
                        "\(context): radiance and all depth/normal/motion/material guides must match",file: file,line: line)
                }
            }
        }
        let cached = try tracePrimary(cached: true), uncached = try tracePrimary(cached: false)
        XCTAssertGreaterThan(uncached.evaluations[0], 256, "The fixture must execute repeated real primary shadow rays")
        XCTAssertGreaterThan(cached.evaluations[0], 0)
        XCTAssertLessThan(cached.evaluations[0], uncached.evaluations[0],
            "Identical primary hits must actually avoid duplicate solar visibility evaluations")
        XCTAssertGreaterThan(cached.pixels[0].reduce(0,+), 256,
            "Equivalence must cover illuminated surfaces, not an empty black ray scene")
        assertEquivalent(cached.pixels,uncached.pixels,"Primary solar reuse")
        for samples in [Float(2),Float(4)] {
            // Real leaves, actual alpha holes, water, glass, and per-sample death fade.
            for (column,alpha) in [(Float(1),Float(1)),(5,1),(10,1),(11,1),(14,0.5)] {
                let optimized = try tracePrimary(samples: samples,column: column,entityAlpha: alpha)
                let reference = try tracePrimary(primaryCached: false,samples: samples,column: column,entityAlpha: alpha)
                XCTAssertEqual(optimized.evaluations[1],256,
                    "Only one raw primary intersection per pixel, including misses and fading bodies")
                XCTAssertEqual(reference.evaluations[1],UInt32(samples)*256)
                XCTAssertEqual(Array(optimized.evaluations[3...5]),Array(reference.evaluations[3...5]),
                    "Entity fade RNG decisions and both dielectric branch counts remain unchanged")
                if column==14 { XCTAssertGreaterThan(optimized.evaluations[3],0,"Exercise actual entity fade continuations") }
                if column==10 || column==11 {
                    XCTAssertGreaterThan(optimized.evaluations[4],0,"Primary reflection must still execute, column \(column), \(samples) samples")
                    XCTAssertGreaterThan(optimized.evaluations[5],0,"Primary transmission must still execute, column \(column), \(samples) samples")
                }
                assertEquivalent(optimized.pixels,reference.pixels,"Primary-hit reuse, column \(column), \(samples) samples")
            }
        }
        let blockedClouds = try tracePrimary(column: 15,clouds: true)
        let marchedClouds = try tracePrimary(skipBlockedClouds: false,column: 15,clouds: true)
        XCTAssertGreaterThan(marchedClouds.evaluations[2],0,"The roof fixture must execute the reference cloud-shadow helper")
        XCTAssertLessThan(blockedClouds.evaluations[2],marchedClouds.evaluations[2],
            "Fully occluded surfaces must avoid real cloud-density evaluations")
        assertEquivalent(blockedClouds.pixels,marchedClouds.pixels,"Zero-visibility cloud-shadow skip")
    }
}
