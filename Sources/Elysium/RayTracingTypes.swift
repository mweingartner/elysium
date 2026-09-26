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
    /// Cumulative whole-frame temporal-history resets by cause, and frames the renderer could not
    /// present (raster fallback) by cause. Diagnostics only; they never alter rendering.
    var historyResets: [String: Int] = [:]
    var fallbackFrames: [String: Int] = [:]
    /// Streaming state of the last frame. `deferredSections` are selected but not yet built and
    /// are omitted from the ray scene until a later frame builds them (nearest first);
    /// `staleSections` present their previous revision's BLAS while the new one waits;
    /// `truncatedSections` are the farthest selected sections dropped to fit the instance and
    /// triangle caps; `locallyInvalidatedInstances` had their per-pixel history rejected.
    var deferredSections = 0
    var staleSections = 0
    var truncatedSections = 0
    var locallyInvalidatedInstances = 0
    var builtSections = 0
    var builtTriangles = 0
    /// Section BLASes compacted in the last frame, and the cumulative bytes compaction saved.
    var compactedSections = 0
    var compactionSavedBytes = 0
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
    /// A traversal/memory quality cap, not a Metal limit. Selection beyond it is truncated
    /// farthest-first (fog covers that tail); it never switches the frame to raster.
    static let maximumTriangles = 16_000_000
    /// Sections within this horizontal radius are always rebuilt in the frame their mesh
    /// changes (player edits), and a new one here must be built before a frame is presented.
    static let nearBuildRadius: Double = 32
    static let nearBuildsPerFrame = 128
    static let nearBuildTrianglesPerFrame = 1_500_000
    /// Before the first presentation every section within fog start must be built; this
    /// larger loading budget applies until then.
    static let buildsPerFrame = 32
    static let buildTrianglesPerFrame = 500_000
    /// Afterward, farther sections stream in nearest-first within this per-frame budget,
    /// presenting their previous BLAS (or nothing, for a new section) until built.
    static let streamingBuildsPerFrame = 24
    static let streamingBuildTrianglesPerFrame = 200_000
    /// A fallback run longer than this many frames discards temporal history on recovery.
    static let fallbackHistoryGapFrames = 4
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

    /// Material traits of one atlas layer, derived from its registered tile name.
    struct TileTraits: OptionSet {
        let rawValue: UInt8
        /// Registered leaf materials transmit canopy light. Generic cutouts also include
        /// fences, doors, roots and machinery, which remain solid occluders.
        static let foliage = TileTraits(rawValue: 1)
        static let metal = TileTraits(rawValue: 2)
        /// The legacy emissive bit covers the entire lit furnace block. Its stone facade is
        /// reflective, not a lamp: the mesher supplies a separate fire overlay in the mouth,
        /// and source metadata supplies the room illumination.
        static let furnaceFacade = TileTraits(rawValue: 4)

        static func of(_ name: String) -> TileTraits {
            var traits: TileTraits = []
            if LEAF_WOODS.contains(where: { name == "\($0)_leaves" }) { traits.insert(.foliage) }
            if ["iron_block","gold_block","copper_block","netherite_block","raw_iron_block","raw_gold_block"].contains(name)
                || name.hasPrefix("cut_copper") || name.hasSuffix("_copper") { traits.insert(.metal) }
            if name == "furnace_top" || name == "furnace_side" || name == "furnace_front_lit" { traits.insert(.furnaceFacade) }
            return traits
        }
    }

    private final class TileTraitCache: @unchecked Sendable {
        let lock = NSLock()
        var traits: [TileTraits] = []
    }
    private static let traitCache = TileTraitCache()

    /// One trait per registered tile. The tile registry is append-only, so its count is the
    /// cache version. Replacing per-triangle string matching with this table measured about
    /// 4x faster decoding (117 to 29 ns per triangle) on the M5 Max.
    static func tileTraits() -> [TileTraits] {
        let tiles = allTileNames()
        traitCache.lock.lock(); defer { traitCache.lock.unlock() }
        if traitCache.traits.count != tiles.count { traitCache.traits = tiles.map(TileTraits.of) }
        return traitCache.traits
    }

    private static let faceNormals: [SIMD3<Float>] = [.init(0,-1,0), .init(0,1,0), .init(0,0,-1),
                                                      .init(0,0,1), .init(-1,0,0), .init(1,0,0)]

    private static func decodeLayers(_ layers: [(data:[UInt32],idx:[UInt32],count:Int,flags:UInt32)]) -> Decoded? {
        var output = Decoded()
        let traits = tileTraits()
        let normals = faceNormals
        let vertexCount = layers.reduce(0) { $0 + $1.count }
        let indexCount = layers.reduce(0) { $0 + $1.idx.count }
        output.positions.reserveCapacity(vertexCount)
        output.indices.reserveCapacity(indexCount)
        output.primitives.reserveCapacity(indexCount / 3)
        for layer in layers {
            let layerFlags=layer.flags, data=layer.data, idx=layer.idx
            guard data.count == layer.count * 7, idx.count % 3 == 0,
                  idx.allSatisfy({ Int($0) < layer.count }) else { return nil }
            let base = UInt32(output.positions.count)
            for i in 0..<layer.count {
                let offset = i * 7
                let p = SIMD3<Float>(Float(bitPattern: data[offset]),
                                     Float(bitPattern: data[offset + 1]),
                                     Float(bitPattern: data[offset + 2]))
                guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return nil }
                output.positions.append(p)
            }
            output.indices.append(contentsOf: idx.lazy.map { $0 + base })
            for i in stride(from: 0, to: idx.count, by: 3) {
                let o0 = Int(idx[i]) * 7, o1 = Int(idx[i + 1]) * 7, o2 = Int(idx[i + 2]) * 7
                let a = data[o0 + 5], b = data[o0 + 6]
                let normalID = (a >> 12) & 7
                guard normalID < 6 else { return nil }
                let anim = (b >> 24) & 7
                let layerIndex = Int(a & 4095)
                let trait = layerIndex < traits.count ? traits[layerIndex] : []
                let emission: Float = ((a >> 25) & 1) == 1 && !trait.contains(.furnaceFacade)
                    ? (anim == 2 ? 5 : 2) * RenderLocalLightPolicy.outputMultiplier : 0
                let v0 = SIMD2<Float>(Float(bitPattern: data[o0 + 3]), Float(bitPattern: data[o0 + 4]))
                let v1 = SIMD2<Float>(Float(bitPattern: data[o1 + 3]), Float(bitPattern: data[o1 + 4]))
                let v2 = SIMD2<Float>(Float(bitPattern: data[o2 + 3]), Float(bitPattern: data[o2 + 4]))
                guard v0.x.isFinite, v0.y.isFinite, v1.x.isFinite, v1.y.isFinite,
                      v2.x.isFinite, v2.y.isFinite else { return nil }
                let p0 = output.positions[Int(idx[i] + base)]
                let p1 = output.positions[Int(idx[i + 1] + base)]
                let p2 = output.positions[Int(idx[i + 2] + base)]
                let e1 = p1 - p0, e2 = p2 - p0
                let plane = simd_cross(e1,e2)
                let areaSquared = simd_length_squared(plane)
                let reciprocal1 = areaSquared > 1e-12 ? simd_cross(e2,plane)/areaSquared : .zero
                let reciprocal2 = areaSquared > 1e-12 ? simd_cross(plane,e1)/areaSquared : .zero
                let gradientU = reciprocal1*(v1.x-v0.x)+reciprocal2*(v2.x-v0.x)
                let gradientV = reciprocal1*(v1.y-v0.y)+reciprocal2*(v2.y-v0.y)
                var flags = anim == 1 ? UInt32(2) : layerFlags
                if trait.contains(.foliage) { flags |= 32 | 1 }
                if trait.contains(.metal) { flags |= 16 }
                output.primitives.append(RayTracingPrimitive(uv01: .init(v0.x,v0.y,v1.x,v1.y),
                    uv2Light: .init(v2.x,v2.y,Float((a >> 17)&15)/15,Float((a >> 21)&15)/15),
                    normalEmission: .init(normals[Int(normalID)],emission),
                    material: .init(b & 0xffffff,a & 4095,flags,anim),
                    textureGradientU: .init(gradientU,0),textureGradientV: .init(gradientV,0)))
                if emission > 0, i % 6 == 0 {
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
