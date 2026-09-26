import Foundation
import Metal
import ElysiumCore

/// The initial 2x lamp boost was toned down 15%; the expanded reach is retained.
enum RenderLocalLightPolicy {
    static let outputMultiplier: Float = 1.7
}

struct RenderLocalLightUniforms {
    var originAndSize: SIMD4<Float> = .zero
    var params: SIMD4<Float> = .zero
}

/// Immutable, completion-owned GPU upload. Never rewrite a texture used by an earlier frame.
struct RenderLocalLightVolume {
    let texture: MTLTexture
    let origin: SIMD3<Int>
    let size: Int
    let generation: UInt64
    private let field: RenderLocalLightField

    init?(device: MTLDevice, field: RenderLocalLightField, generation: UInt64) {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = field.size
        descriptor.height = field.size
        descriptor.depth = field.size
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "Presentation-only local light \(generation)"
        field.rgba.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, field.size, field.size, field.size),
                mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!,
                bytesPerRow: field.size * 4, bytesPerImage: field.size * field.size * 4)
        }
        self.texture = texture
        self.origin = field.origin
        self.size = field.size
        self.generation = generation
        self.field = field
    }

    /// RGB is source tint; A is remaining presentation level / 30, before optical transfer.
    func sample(worldPosition: SIMD3<Double>) -> SIMD4<Float> {
        field.sample(worldPosition: worldPosition)
    }
}

struct RenderLocalLightSection: Sendable {
    let origin: SIMD3<Int>
    let metadata: MeshLightingMetadata
}

/// Pure bounded worker kernel. Missing sections are opaque, not invented open air.
struct RenderLocalLightField: Sendable {
    let origin: SIMD3<Int>
    let size: Int
    let rgba: [UInt8]

    func sample(worldPosition: SIMD3<Double>) -> SIMD4<Float> {
        let p = worldPosition - SIMD3(Double(origin.x), Double(origin.y), Double(origin.z))
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite,
              p.x >= 0, p.y >= 0, p.z >= 0,
              p.x < Double(size), p.y < Double(size), p.z < Double(size) else { return .zero }
        let index = (Int(p.x) + size * (Int(p.y) + size * Int(p.z))) * 4
        return .init(Float(rgba[index]) / 255, Float(rgba[index + 1]) / 255,
                     Float(rgba[index + 2]) / 255, Float(rgba[index + 3]) / 255)
    }

    static func build(origin: SIMD3<Int>, size: Int = 128,
                      sections: [RenderLocalLightSection]) -> RenderLocalLightField? {
        guard size >= 16, size <= 128, size % 16 == 0 else { return nil }
        let count = size * size * size, plane = size * size
        var opacity = [UInt8](repeating: 15, count: count)
        var levels = [UInt8](repeating: 0, count: count)
        var rgba = [UInt8](repeating: 0, count: count * 4)
        // Highest-level-first buckets visit each voxel at its final best level. This avoids
        // re-flooding a large lava region once for every weaker nearby source.
        var buckets = [[Int32]](repeating: [], count: 31)
        let sorted = sections.sorted {
            if $0.origin.z != $1.origin.z { return $0.origin.z < $1.origin.z }
            if $0.origin.y != $1.origin.y { return $0.origin.y < $1.origin.y }
            return $0.origin.x < $1.origin.x
        }
        for section in sorted {
            guard section.metadata.opacity.count == 4096 else { continue }
            let offset = section.origin &- origin
            guard offset.x > -16, offset.y > -16, offset.z > -16,
                  offset.x < size, offset.y < size, offset.z < size else { continue }
            for z in max(0, -offset.z)..<min(16, size - offset.z) {
                for y in max(0, -offset.y)..<min(16, size - offset.y) {
                    for x in max(0, -offset.x)..<min(16, size - offset.x) {
                        let i = offset.x + x + size * (offset.y + y + size * (offset.z + z))
                        opacity[i] = min(15, section.metadata.opacity[x + 16 * (y + 16 * z)])
                        // White, zero-level cells distinguish known unlit space from missing data.
                        rgba[i * 4] = 255; rgba[i * 4 + 1] = 255; rgba[i * 4 + 2] = 255
                    }
                }
            }
        }
        for section in sorted {
            guard section.metadata.opacity.count == 4096 else { continue }
            let offset = section.origin &- origin
            for source in section.metadata.emitters {
                guard source.position.x < 16, source.position.y < 16, source.position.z < 16,
                      source.level > 0, source.level <= 15,
                      source.color.x.isFinite, source.color.y.isFinite, source.color.z.isFinite else { continue }
                let p = offset &+ SIMD3(Int(source.position.x), Int(source.position.y), Int(source.position.z))
                guard p.x >= 0, p.y >= 0, p.z >= 0, p.x < size, p.y < size, p.z < size else { continue }
                let i = p.x + size * (p.y + size * p.z), level = source.level * 2
                guard level > levels[i] else { continue }
                levels[i] = level
                for channel in 0..<3 {
                    rgba[i * 4 + channel] = UInt8((min(1, max(0, source.color[channel])) * 255).rounded())
                }
                buckets[Int(level)].append(Int32(i))
            }
        }
        for level in stride(from: 30, through: 1, by: -1) {
            for entry in buckets[level] {
                let i = Int(entry)
                guard Int(levels[i]) == level else { continue }
                let x = i % size, y = (i / size) % size, z = i / plane
                for direction in 0..<6 {
                    let next: Int
                    switch direction {
                    case 0: next = x > 0 ? i - 1 : -1
                    case 1: next = x + 1 < size ? i + 1 : -1
                    case 2: next = y > 0 ? i - size : -1
                    case 3: next = y + 1 < size ? i + size : -1
                    case 4: next = z > 0 ? i - plane : -1
                    default: next = z + 1 < size ? i + plane : -1
                    }
                    guard next >= 0 else { continue }
                    // A solid's old opacity15 must not become half-transparent to level30.
                    let op = Int(opacity[next])
                    guard op < 15 else { continue }
                    let remaining = level - max(1, op)
                    guard remaining > 0, remaining > Int(levels[next]) else { continue }
                    levels[next] = UInt8(remaining)
                    rgba[next * 4] = rgba[i * 4]
                    rgba[next * 4 + 1] = rgba[i * 4 + 1]
                    rgba[next * 4 + 2] = rgba[i * 4 + 2]
                    buckets[remaining].append(Int32(next))
                }
            }
            buckets[level].removeAll(keepingCapacity: false)
        }
        for i in levels.indices { rgba[i * 4 + 3] = UInt8((Int(levels[i]) * 255 + 15) / 30) }
        return .init(origin: origin, size: size, rgba: rgba)
    }
}

/// Main-thread cache with one coalesced immutable worker snapshot in flight.
final class RenderLocalLighting {
    private struct Completed {
        let ticket: UInt64
        let epoch: UInt64
        let generation: UInt64
        let origin: SIMD3<Int>
        let field: RenderLocalLightField?
    }
    private final class Mailbox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Completed?
        func put(_ value: Completed) { lock.lock(); self.value = value; lock.unlock() }
        func take() -> Completed? {
            lock.lock(); defer { lock.unlock() }
            defer { value = nil }
            return value
        }
    }
    static let size = 128
    private let device: MTLDevice
    private let queue: DispatchQueue
    private let mailbox = Mailbox()
    private var sections: [SIMD3<Int>: MeshLightingMetadata] = [:]
    private var requestedOrigin: SIMD3<Int>?
    private var generation: UInt64 = 1
    /// Bumped by `clear()`. A field built for an earlier world or dimension is never published,
    /// even though its worker completion may still arrive afterward.
    private var epoch: UInt64 = 0
    private var nextTicket: UInt64 = 0
    private var activeTicket: UInt64?
    private var current: RenderLocalLightVolume?

    init(device: MTLDevice, queue: DispatchQueue = DispatchQueue(label: "elysium.render-local-light", qos: .userInitiated)) {
        self.device = device
        self.queue = queue
    }

    func upload(origin: SIMD3<Int>, metadata: MeshLightingMetadata?) {
        precondition(Thread.isMainThread)
        let valid = metadata.flatMap { $0.opacity.count == 4096 ? $0 : nil }
        guard sections[origin] != valid else { return }
        sections[origin] = valid
        invalidateIfRelevant(origin)
    }

    func removeChunk(cx: Int, cz: Int) {
        precondition(Thread.isMainThread)
        let keys = sections.keys.filter { $0.x == cx * 16 && $0.z == cz * 16 }
        var relevant = false
        for key in keys {
            sections.removeValue(forKey: key)
            relevant = relevant || intersectsRelevantVolume(key)
        }
        if relevant { invalidate() }
    }

    func clear() {
        precondition(Thread.isMainThread)
        sections.removeAll(keepingCapacity: true)
        requestedOrigin = nil
        epoch &+= 1
        invalidate()
        current = nil // a different world or dimension never inherits the old field
    }

    private func intersectsRequestedVolume(_ section: SIMD3<Int>) -> Bool {
        guard let origin = requestedOrigin else { return false }
        return intersects(section, volumeOrigin: origin)
    }

    private func intersects(_ section: SIMD3<Int>, volumeOrigin origin: SIMD3<Int>) -> Bool {
        let delta = section &- origin
        return delta.x > -16 && delta.y > -16 && delta.z > -16
            && delta.x < Self.size && delta.y < Self.size && delta.z < Self.size
    }

    private func intersectsRelevantVolume(_ section: SIMD3<Int>) -> Bool {
        intersectsRequestedVolume(section)
            || (current.map { intersects(section, volumeOrigin: $0.origin) } ?? false)
    }

    private func invalidateIfRelevant(_ section: SIMD3<Int>) {
        if intersectsRelevantVolume(section) { invalidate() }
    }

    /// A nearby edit schedules a rebuild but keeps the displayed field until its replacement lands
    /// (tens of milliseconds). Dropping it immediately switched both renderers to a different
    /// lighting model for several frames, and continuous edits (flowing fluids, fire) repeated that
    /// every time, which read as flicker in exactly those areas.
    private func invalidate() {
        generation &+= 1
    }

    func prepare(camera: SIMD3<Double>) -> RenderLocalLightVolume? {
        precondition(Thread.isMainThread)
        guard camera.x.isFinite, camera.y.isFinite, camera.z.isFinite,
              abs(camera.x) < 1e12, abs(camera.y) < 1e12, abs(camera.z) < 1e12 else { return nil }
        let origin = SIMD3(Int(floor(camera.x / 16)) * 16 - 64,
                           Int(floor(camera.y / 16)) * 16 - 64,
                           Int(floor(camera.z / 16)) * 16 - 64)
        if requestedOrigin != origin {
            requestedOrigin = origin
            // Keep the previous immutable field during ordinary walking. Its world-space
            // origin remains authoritative until the replacement is complete.
        }
        if let volume = current {
            let p = camera - SIMD3(Double(volume.origin.x), Double(volume.origin.y), Double(volume.origin.z))
            if p.x < 32 || p.y < 32 || p.z < 32 || p.x >= 96 || p.y >= 96 || p.z >= 96 {
                current = nil // large movement/teleport no longer has the safe30-block source margin
            }
        }
        if let completed = mailbox.take(), completed.ticket == activeTicket {
            activeTicket = nil
            // Accept any completed field for this origin that is newer than the displayed one, even
            // if more edits arrived meanwhile; otherwise continuous edits starve the volume forever.
            if completed.epoch == epoch, completed.origin == origin, let field = completed.field,
               current.map({ $0.origin != origin || $0.generation < completed.generation }) ?? true {
                current = RenderLocalLightVolume(device: device, field: field, generation: completed.generation)
            }
        }
        if (current == nil || current?.origin != origin || current?.generation != generation) && activeTicket == nil {
            nextTicket &+= 1
            let ticket = nextTicket, revision = generation, epoch = epoch, mailbox = mailbox
            activeTicket = ticket
            let snapshot = sections.compactMap { key, value in
                intersectsRequestedVolume(key) ? RenderLocalLightSection(origin: key, metadata: value) : nil
            }
            queue.async {
                let field = RenderLocalLightField.build(origin: origin, sections: snapshot)
                mailbox.put(.init(ticket: ticket, epoch: epoch, generation: revision, origin: origin, field: field))
            }
        }
        return current
    }
}

let renderLocalLightingShaderSource = #"""
#include <metal_stdlib>
using namespace metal;
constant float elyNonSunLightOutput = 1.7;
struct RenderLocalLightUniforms {
    float4 originAndSize;
    float4 params;
};
// Returns linear local irradiance plus coverage; preserve the old cache outside this field.
static float4 sampleRenderLocalLight(float3 position, float3 normal,
    constant RenderLocalLightUniforms &u, texture3d<float, access::sample> volume) {
    if (u.params.x < 0.5 || u.originAndSize.w <= 0) return float4(0);
    float3 p = position + normal * 0.51 - u.originAndSize.xyz;
    float size = u.originAndSize.w;
    if (any(p < 0) || any(p >= size)) return float4(0);
    // Integer nearest sampling cannot interpolate lit air through a one-voxel solid wall.
    float4 value = volume.read(uint3(floor(p)));
    if (all(value.rgb == 0) && value.a == 0) return float4(0); // missing snapshot coverage
    float level = clamp(value.a, 0.0, 1.0);
    float intensity = level / max(1.0, 4.0 - 3.0 * level);
    float3 edge = min(p, float3(size) - p);
    float coverage = smoothstep(0.0, 16.0, min(edge.x, min(edge.y, edge.z)));
    return float4(value.rgb * intensity * u.params.y, coverage);
}

"""# + "\n"
