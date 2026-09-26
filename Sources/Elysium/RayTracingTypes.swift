// Render-only contracts. None of these values feed world simulation or save data.
import Foundation
import Metal
import simd
import ElysiumCore

struct RayTracingFrame {
    var viewProjection: simd_float4x4
    var inverseViewProjection: simd_float4x4
    var camera: SIMD3<Double>
    var atmosphere: AtmosphereUniforms
    var renderDistance: Float
    var gamma: Float = 0.5
    var heldLight: SIMD4<Float> = .zero
    /// Immutable, occlusion-propagated local illumination; origin is camera-relative.
    var localLightTexture: MTLTexture?
    var localLightOrigin: SIMD3<Float>?
    var localLightGeneration: UInt64 = 0
    var shadows = true
    var atlasGeneration: UInt64 = 0
    /// World identity changes even when the next world happens to use the same dimension.
    var worldIdentity: UInt64 = 0
    var fogStart: Float = 128
    var fogEnd: Float = 256
    var nightVision: Float = 0
    var viewMatrix: simd_float4x4 = matrix_identity_float4x4
    var projectionMatrix: simd_float4x4 = matrix_identity_float4x4
}

struct RayTracingDiagnostics {
    var available = false
    var ready = false
    var status = "Ray tracing unavailable"
    var sections = 0
    var pendingSections = 0
    var instances = 0
    var triangles = 0
    var geometryBytes = 0
    var residentGeometryBytes = 0
    var transientGeometryBytes = 0
    var memoryBudgetBytes = 0
    var deviceAllocatedBytes = 0
    var deviceRecommendedBytes = 0
    var width = 0
    var height = 0
    var outputWidth = 0
    var outputHeight = 0
    var historySamples = 0
    var gpuMilliseconds = 0.0
    var gpuStageMilliseconds: [String:Double] = [:]
    var gpuStageFrameIndex: UInt64 = 0
    var denoiser = "Spatial/temporal"
    var samplesPerPixel = 4
}

/// Exact 96-byte primitive payload, copied into the acceleration structure by Metal.
/// UV gradients retain arbitrary authored density, including greedy-repeat values.
struct RayTracingPrimitive {
    var uv01: SIMD4<Float>
    var uv2Light: SIMD4<Float>
    var normalEmission: SIMD4<Float>
    /// tint RGB, atlas layer, flags (cutout=1, water=2, glass=4, entity=8, metal=16, foliage=32), animation
    var material: SIMD4<UInt32>
    var textureGradientU: SIMD4<Float> = .zero
    var textureGradientV: SIMD4<Float> = .zero
}

struct RayTracingInstanceUniforms {
    var transform: simd_float4x4
    var normalTransform: simd_float4x4
    var previousFromCurrent: simd_float4x4
    var tint: SIMD4<Float>
    var overlay: SIMD4<Float>
    /// Entity texture slot, dynamic, previous transform valid, reserved.
    var info: SIMD4<UInt32>
}

struct RayTracingLight {
    var positionRadius: SIMD4<Float>
    var colorPower: SIMD4<Float>
}

/// Compatibility path for synthetic scenes and frames without a propagated light volume.
/// Fixed camera-distance ordering keeps nearby sources when distant emitters exceed the cap;
/// the production volume is spatially complete and never uses this approximate candidate cap.
enum RayTracingLocalLightSelection {
    static func select(_ lights: [RayTracingLight], limit: Int = RayTracingLimits.maximumLights) -> [RayTracingLight] {
        guard limit > 0 else { return [] }
        let valid=lights.filter { light in
            let p=light.positionRadius, c=light.colorPower
            return p.x.isFinite && p.y.isFinite && p.z.isFinite && p.w.isFinite && p.w>0
                && c.x.isFinite && c.y.isFinite && c.z.isFinite && c.w.isFinite && c.w>0
        }
        guard valid.count>limit else { return valid }
        return Array(valid.sorted { a,b in
            let ad=a.positionRadius.x*a.positionRadius.x+a.positionRadius.y*a.positionRadius.y+a.positionRadius.z*a.positionRadius.z
            let bd=b.positionRadius.x*b.positionRadius.x+b.positionRadius.y*b.positionRadius.y+b.positionRadius.z*b.positionRadius.z
            if ad != bd { return ad<bd }
            for channel in 0..<4 where a.positionRadius[channel] != b.positionRadius[channel] {
                return a.positionRadius[channel]<b.positionRadius[channel]
            }
            for channel in 0..<4 where a.colorPower[channel] != b.colorPower[channel] {
                return a.colorPower[channel]>b.colorPower[channel]
            }
            return false
        }.prefix(limit))
    }
}

struct RayTracingUniforms {
    var inverseViewProjection: simd_float4x4
    var viewProjection: simd_float4x4
    var previousViewProjection: simd_float4x4
    var cameraDelta: SIMD4<Float>
    var params: SIMD4<Float> // far, gamma, history valid, shadows
    var heldLight: SIMD4<Float>
    var localLight: RenderLocalLightUniforms = .init()
    var fogParameters: SIMD4<Float> // start, end, night vision, reserved
    var quality: SIMD4<Float> // samples per pixel, reserved
    var counts: SIMD4<UInt32> // frame, lights, width, height
    var atmosphere: AtmosphereUniforms
}

enum RayTracingLimits {
    static let maximumInstances = 16_384
    static let maximumTextures = 512
    static let maximumTriangles = 8_000_000
    static let buildsPerFrame = 12
    static let buildTrianglesPerFrame = 250_000
    // Native primary surfaces: 1920x1080 on a 2880x1620 Retina drawable (a 1.5x final resample).
    // Measured on the M5 Max reference scenes it trades roughly 8-11 FPS for visibly finer
    // distant terrain edges than the former 1440x900 cap; lighting stays at the 640x400 cap.
    static let maximumInternalWidth = 1_920
    static let maximumInternalHeight = 1_200
    // Expensive lighting is independent of full-resolution primary surfaces.
    static let maximumNativeTraceWidth = 640
    static let maximumNativeTraceHeight = 400
    static let maximumLights = 512
}

/// Independent packed-mesh decoding also used by the native GPU regression executable.
enum RayTracingMeshDecoder {
    struct Decoded {
        var positions: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var primitives: [RayTracingPrimitive] = []
        var emitters: [RayTracingLight] = []
        var byteCount: Int {
            positions.count * MemoryLayout<SIMD3<Float>>.stride
                + indices.count * 4 + primitives.count * MemoryLayout<RayTracingPrimitive>.stride
        }
    }

    static func decode(_ mesh: MeshOutput) -> Decoded? {
        decodeLayers([(mesh.opaque.data,mesh.opaque.idx,mesh.opaque.count,0),
                      (mesh.cutout.data,mesh.cutout.idx,mesh.cutout.count,1),
                      (mesh.translucent.data,mesh.translucent.idx,mesh.translucent.count,4)])
    }

    static func decodePacked(data: [UInt32],indices: [UInt32]) -> Decoded? {
        guard data.count.isMultiple(of:7) else { return nil }
        return decodeLayers([(data,indices,data.count/7,0)])
    }

    private static func decodeLayers(_ layers: [(data:[UInt32],idx:[UInt32],count:Int,flags:UInt32)]) -> Decoded? {
        var output = Decoded()
        let tiles = allTileNames()
        // Only the game's registered leaf materials transmit canopy light. Generic cutouts
        // also include fences, doors, roots and machinery, which remain solid occluders.
        let foliageTiles = Set(LEAF_WOODS.map { "\($0)_leaves" })
        for layer in layers {
            let layerFlags=layer.flags
            guard layer.data.count == layer.count * 7, layer.idx.count % 3 == 0,
                  layer.idx.allSatisfy({ Int($0) < layer.count }) else { return nil }
            let base = UInt32(output.positions.count)
            for i in 0..<layer.count {
                let offset = i * 7
                let p = SIMD3<Float>(Float(bitPattern: layer.data[offset]),
                                     Float(bitPattern: layer.data[offset + 1]),
                                     Float(bitPattern: layer.data[offset + 2]))
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
                output.positions.append(p)
            }
            output.indices.append(contentsOf: layer.idx.map { $0 + base })
            for i in stride(from: 0, to: layer.idx.count, by: 3) {
                let offsets = (0..<3).map { Int(layer.idx[i + $0]) * 7 }
                func uv(_ j: Int) -> SIMD2<Float> {
                    SIMD2(Float(bitPattern: layer.data[offsets[j] + 3]), Float(bitPattern: layer.data[offsets[j] + 4]))
                }
                let a = layer.data[offsets[0] + 5], b = layer.data[offsets[0] + 6]
                let normalID = (a >> 12) & 7
                guard normalID < 6 else { return nil }
                let normals: [SIMD3<Float>] = [.init(0,-1,0), .init(0,1,0), .init(0,0,-1),
                                             .init(0,0,1), .init(-1,0,0), .init(1,0,0)]
                let anim = (b >> 24) & 7
                let layerIndex = Int(a & 4095)
                let name = tiles.indices.contains(layerIndex) ? tiles[layerIndex] : ""
                // The legacy emissive bit covers the entire lit furnace block. Its stone
                // facade is reflective, not a lamp: the mesher supplies a separate fire
                // overlay in the mouth, and source metadata supplies the room illumination.
                let furnaceFacade = name == "furnace_top" || name == "furnace_side"
                    || name == "furnace_front_lit"
                let emission: Float = ((a >> 25) & 1) == 1 && !furnaceFacade
                    ? (anim == 2 ? 5 : 2) * RenderLocalLightPolicy.outputMultiplier : 0
                let v0 = uv(0), v1 = uv(1), v2 = uv(2)
                guard [v0.x,v0.y,v1.x,v1.y,v2.x,v2.y].allSatisfy(\.isFinite) else { return nil }
                let p0 = output.positions[Int(layer.idx[i] + base)]
                let e1 = output.positions[Int(layer.idx[i+1] + base)] - p0
                let e2 = output.positions[Int(layer.idx[i+2] + base)] - p0
                let plane = simd_cross(e1,e2)
                let areaSquared = simd_length_squared(plane)
                let reciprocal1 = areaSquared > 1e-12 ? simd_cross(e2,plane)/areaSquared : .zero
                let reciprocal2 = areaSquared > 1e-12 ? simd_cross(plane,e1)/areaSquared : .zero
                let gradientU = reciprocal1*(v1.x-v0.x)+reciprocal2*(v2.x-v0.x)
                let gradientV = reciprocal1*(v1.y-v0.y)+reciprocal2*(v2.y-v0.y)
                var flags = anim == 1 ? UInt32(2) : layerFlags
                if foliageTiles.contains(name) { flags |= 32 | 1 }
                if ["iron_block","gold_block","copper_block","netherite_block","raw_iron_block","raw_gold_block"].contains(name)
                    || name.hasPrefix("cut_copper") || name.hasSuffix("_copper") { flags |= 16 }
                output.primitives.append(RayTracingPrimitive(uv01: .init(v0.x,v0.y,v1.x,v1.y),
                    uv2Light: .init(v2.x,v2.y,Float((a >> 17)&15)/15,Float((a >> 21)&15)/15),
                    normalEmission: .init(normals[Int(normalID)],emission),
                    material: .init(b & 0xffffff,a & 4095,flags,anim),
                    textureGradientU: .init(gradientU,0),textureGradientV: .init(gradientV,0)))
                if emission > 0, i % 6 == 0 {
                    let p0 = output.positions[Int(layer.idx[i] + base)]
                    let p1 = output.positions[Int(layer.idx[i+1] + base)]
                    let p2 = output.positions[Int(layer.idx[i+2] + base)]
                    let area = simd_length(simd_cross(p1-p0,p2-p0)) * 0.5
                    if area > 0.00001 {
                        let color: SIMD3<Float> = anim == 2 ? .init(1,0.29,0.04) : .init(1,0.68,0.27)
                        output.emitters.append(.init(positionRadius: .init((p0+p1+p2)/3 + normals[Int(normalID)]*0.04,30),
                            colorPower: .init(color, min(8 * RenderLocalLightPolicy.outputMultiplier,area*emission))))
                    }
                }
            }
        }
        return output
    }
}
