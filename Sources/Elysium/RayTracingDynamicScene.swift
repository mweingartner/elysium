// Immutable rigid geometry shared with the raster entity renderer. World state
// and animation are sampled by the owner once; ray tracing only consumes that
// presentation snapshot and never advances simulation or a second animator.

import Metal
import simd

final class RayTracingEntityGeometry {
    /// Includes the skin generation, so a resource-pack swap cannot reuse an
    /// acceleration structure with a previous skin/material binding.
    let key: String
    /// Existing entity ABI: position3, normal3, UV2, part index (9 floats).
    /// Complete, non-indexed triangles in the rigid part's local coordinates.
    let vertices: [Float]
    let texture: MTLTexture
    let emission: Float

    init(key: String, vertices: [Float], texture: MTLTexture, emission: Float = 0) {
        self.key = key
        self.vertices = vertices
        self.texture = texture
        self.emission = emission.isFinite ? min(8,max(0,emission)) : 0
    }
}

struct RayTracingEntityInstance {
    let geometry: RayTracingEntityGeometry
    /// Stable live entity ID plus rigid part key, supplied by the world owner.
    /// Array positions are not identities: spawn/despawn can reorder a frame.
    var identity: String = ""
    /// First-person bodies stay in secondary/reflection/shadow rays without
    /// occluding the camera or its independent held-item presentation pass.
    var primaryVisible: Bool = true
    /// Relative to the same Double-precision origin as the ray-traced world.
    /// The owner subtracts that origin before converting translation to Float.
    var transform: simd_float4x4
    var tint: SIMD4<Float> = SIMD4<Float>(repeating: 1)
    /// Same mix(base, overlay.rgb, overlay.a) as the raster entity fragment.
    var overlay: SIMD4<Float> = .zero
}

struct EntityRigidPartVertices {
    let partIndex: Int
    let vertices: [Float]
}

enum EntityRigidGeometry {
    static let floatsPerVertex = 9
    static let maximumParts = 24

    /// Partition complete triangles, never individual vertices. This preserves
    /// the native winding, normals, UVs, detailed dinosaur facets and texture
    /// resolution. Invalid geometry is rejected as a whole, not partially
    /// rendered with a misleading missing limb or incorrect part transform.
    static func partition(_ vertices: [Float], partCount: Int) -> [EntityRigidPartVertices]? {
        guard (0...maximumParts).contains(partCount),
              vertices.count.isMultiple(of: floatsPerVertex * 3) else { return nil }
        var parts = [[Float]](repeating: [], count: partCount)
        for start in stride(from: 0, to: vertices.count, by: floatsPerVertex * 3) {
            let index = vertices[start + 8]
            guard index.isFinite, index >= 0, index < Float(partCount),
                  index.rounded(.towardZero) == index else { return nil }
            let triangle = vertices[start..<(start + floatsPerVertex * 3)]
            guard triangle.allSatisfy(\.isFinite),
                  vertices[start + 17] == index, vertices[start + 26] == index else { return nil }
            parts[Int(index)].append(contentsOf: triangle)
        }
        return parts.indices.compactMap { index in
            parts[index].isEmpty ? nil : EntityRigidPartVertices(partIndex: index, vertices: parts[index])
        }
    }
}
