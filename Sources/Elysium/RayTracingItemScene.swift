// Physical item presentation for primary, reflection and shadow rays. These
// snapshots share the raster renderer's sizes, interpolation and billboard pose;
// they never tick an entity or mutate an inventory stack.
import Metal
import simd
import ElysiumCore

final class RayTracingBlockGeometry {
    let key: String
    /// Native terrain ABI: position3, UV2, packed material A/B (seven words).
    let vertices: [UInt32]
    let indices: [UInt32]

    init(key: String, vertices: [UInt32], indices: [UInt32]) {
        self.key = key
        self.vertices = vertices
        self.indices = indices
    }
}

struct RayTracingBlockInstance {
    let geometry: RayTracingBlockGeometry
    var identity: String
    var transform: simd_float4x4
    var tint: SIMD4<Float> = SIMD4<Float>(repeating: 1)
    var overlay: SIMD4<Float> = .zero
    var primaryVisible: Bool = true
}

struct RayTracingItemPresentation {
    var entities: [RayTracingEntityInstance] = []
    var blocks: [RayTracingBlockInstance] = []
    /// An allocation/geometry failure requests the complete raster fallback;
    /// a failed icon must not quietly delete a physical object from the world.
    var isComplete = true
}

final class RayTracingItemScene {
    static let cacheLimit = 128
    private let device: MTLDevice
    private var generation: UInt64?
    private var iconGeneration: UInt64?
    private var sprites: [String: RayTracingEntityGeometry] = [:]
    private var spriteOrder: [String] = []
    private var cubes: [String: RayTracingBlockGeometry] = [:]
    private var cubeOrder: [String] = []
    var cachedSpriteCount: Int { sprites.count }
    var cachedCubeCount: Int { cubes.count }

    init(device: MTLDevice) { self.device = device }

    func reset() {
        generation = nil
        iconGeneration = nil
        sprites.removeAll(keepingCapacity: true)
        spriteOrder.removeAll(keepingCapacity: true)
        cubes.removeAll(keepingCapacity: true)
        cubeOrder.removeAll(keepingCapacity: true)
    }

    func collect(game: GameCore, camPos: SIMD3<Double>, cam: CamState,
                 partial: Double, atlasGeneration: UInt64) -> RayTracingItemPresentation {
        collect(entities: game.world.entities.compactMap { $0 as? Entity },
                camPos: camPos, cam: cam, partial: partial, atlasGeneration: atlasGeneration)
    }

    /// Entity-only overload permits focused presentation tests without starting
    /// world generation, a save session or the game simulation.
    func collect(entities: [Entity], camPos: SIMD3<Double>, cam: CamState,
                 partial: Double, atlasGeneration: UInt64) -> RayTracingItemPresentation {
        let currentIcons = currentIconSourceGeneration()
        if generation != atlasGeneration || iconGeneration != currentIcons {
            reset()
            generation = atlasGeneration
            iconGeneration = currentIcons
        }
        var result = RayTracingItemPresentation()
        for entity in entities where !entity.dead {
            let dx = entity.x - camPos.x, dz = entity.z - camPos.z
            if let block = Self.blockAppearance(entity) {
                guard dx * dx + dz * dz <= 96 * 96 else { continue }
                guard let geometry = cube(cell: block.cell, flash: block.flash,
                                          generation: atlasGeneration) else {
                    result.isComplete = false
                    continue
                }
                let translation = Self.interpolatedPosition(entity, partial: partial, origin: camPos)
                var transform = matrix_identity_float4x4
                transform.columns.3 = SIMD4(translation, 1)
                result.blocks.append(RayTracingBlockInstance(geometry: geometry,
                    identity: "physical-block:\(entity.id)", transform: transform))
            } else if let appearance = Self.spriteAppearance(entity) {
                guard dx * dx + dz * dz <= 64 * 64 else { continue }
                guard let geometry = sprite(stack: appearance.stack, emission: appearance.emission,
                                            generation: atlasGeneration) else {
                    result.isComplete = false
                    continue
                }
                var translation = Self.interpolatedPosition(entity, partial: partial, origin: camPos)
                if entity.type == "item" {
                    translation.y += Float(detSin((Double(entity.age) + partial) * 0.08) * 0.08 + 0.12)
                }
                let right = SIMD3<Float>(Float(detCos(cam.yaw)), 0, Float(detSin(cam.yaw)))
                let up = SIMD3<Float>(0, 1, 0)
                let size = appearance.size
                let transform = simd_float4x4(columns: (
                    SIMD4(right * size, 0), SIMD4(up * size, 0),
                    SIMD4(simd_cross(right, up) * size, 0), SIMD4(translation, 1)))
                result.entities.append(RayTracingEntityInstance(geometry: geometry,
                    identity: "physical-sprite:\(entity.id)", transform: transform))
            }
        }
        return result
    }

    private static func interpolatedPosition(_ entity: Entity, partial: Double,
                                              origin: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3(Float(entity.prevX + (entity.x - entity.prevX) * partial - origin.x),
              Float(entity.prevY + (entity.y - entity.prevY) * partial - origin.y),
              Float(entity.prevZ + (entity.z - entity.prevZ) * partial - origin.z))
    }

    static func blockAppearance(_ entity: Entity) -> (cell: Int, flash: Bool)? {
        if let block = entity as? FallingBlockEntity { return (block.blockCell, false) }
        if let tnt = entity as? TNTEntity {
            let flash = (Double(tnt.fuse) / 5).truncatingRemainder(dividingBy: 2) < 1
            return (Int(cell(B.tnt)), flash && tnt.fuse % 10 < 5)
        }
        return nil
    }

    static func spriteAppearance(_ entity: Entity) -> (stack: ItemStack, size: Float, emission: Float)? {
        if let item = entity as? ItemEntity { return (item.stack, 0.45, 0) }
        if entity.type == "xp_orb" { return (ItemStack(iid("experience_bottle"), 1), 0.3, 1) }
        guard SPRITE_TYPES.contains(entity.type) else { return nil }
        let names = [
            "snowball": "snowball", "egg": "egg", "ender_pearl": "ender_pearl",
            "xp_bottle": "experience_bottle", "thrown_potion": "splash_potion",
            "firework": "firework_rocket", "eye_of_ender": "ender_eye",
            "fishing_bobber": "string", "wither_skull": "wither_skeleton_skull_item",
            "dragon_fireball": "fire_charge", "fireball": "fire_charge",
            "shulker_bullet": "shulker_shell", "llama_spit": "snowball",
        ]
        var name = names[entity.type] ?? "snowball"
        var data = StackData()
        if let potion = entity as? ThrownPotion {
            data.potion = potion.potionId
            name = potion.lingering ? "lingering_potion" : "splash_potion"
        }
        let id = iidOpt(name) ?? iid("snowball")
        let emission: Float = ["fireball", "dragon_fireball", "wither_skull"].contains(entity.type) ? 1 : 0
        return (ItemStack(id, 1, data: data), 0.35, emission)
    }

    private func sprite(stack: ItemStack, emission: Float, generation: UInt64) -> RayTracingEntityGeometry? {
        let key = "physical-sprite:\(generation):\(iconGeneration ?? 0):\(stack.id):\(stack.data.potion ?? ""):e\(emission)"
        if let cached = sprites[key] { return cached }
        let pixels = itemIconPixels(stack.id, stack.data)
        guard pixels.count == 16 * 16 * 4 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 16, height: 16, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = key
        pixels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: 16 * 4)
        }
        // Exact sprite_vs corner/UV order: bottom-anchored upright billboard.
        let corners: [(Float, Float)] = [(-0.5, 0), (0.5, 0), (0.5, 1),
                                        (-0.5, 0), (0.5, 1), (-0.5, 1)]
        let vertices: [Float] = corners.flatMap { x, y -> [Float] in
            [x, y, 0, 0, 0, 1, x + 0.5, 1 - y, 0]
        }
        let geometry = RayTracingEntityGeometry(key: key, vertices: vertices,
                                                texture: texture, emission: emission)
        // Eviction removes only the cache reference. Submitted snapshots retain
        // their immutable texture/geometry until their command buffer completes.
        if spriteOrder.count >= Self.cacheLimit { sprites.removeValue(forKey: spriteOrder.removeFirst()) }
        sprites[key] = geometry
        spriteOrder.append(key)
        return geometry
    }

    private func cube(cell: Int, flash: Bool, generation: UInt64) -> RayTracingBlockGeometry? {
        let key = "physical-cube:\(generation):\(cell):\(flash)"
        if let cached = cubes[key] { return cached }
        guard let geometry = Self.cubeGeometry(cell: cell, flash: flash, key: key) else { return nil }
        if cubeOrder.count >= Self.cacheLimit { cubes.removeValue(forKey: cubeOrder.removeFirst()) }
        cubes[key] = geometry
        cubeOrder.append(key)
        return geometry
    }

    static func cubeGeometry(cell: Int, flash: Bool, key: String) -> RayTracingBlockGeometry? {
        let id = cell >> 4, metadata = cell & 15
        guard blockDefs.indices.contains(id), cell >= 0 else { return nil }
        let definition = blockDefs[id]
        let h: Float = 0.49
        let faces: [[[Float]]] = [
            [[-h, 0, h], [h, 0, h], [h, 0, -h], [-h, 0, -h]],
            [[-h, h * 2, -h], [h, h * 2, -h], [h, h * 2, h], [-h, h * 2, h]],
            [[h, 0, -h], [h, h * 2, -h], [-h, h * 2, -h], [-h, 0, -h]],
            [[-h, 0, h], [-h, h * 2, h], [h, h * 2, h], [h, 0, h]],
            [[-h, 0, -h], [-h, h * 2, -h], [-h, h * 2, h], [-h, 0, h]],
            [[h, 0, h], [h, h * 2, h], [h, h * 2, -h], [h, 0, -h]],
        ]
        let uv: [[Float]] = [[0, 1], [1, 1], [1, 0], [0, 0]]
        var vertices: [UInt32] = []
        var indices: [UInt32] = []
        for face in 0..<6 {
            let layer = definition.texFn?(metadata, face)
                ?? (definition.tex.isEmpty ? 0 : Int(definition.tex[face]))
            let packed = UInt32((layer & 4095) | (face << 12) | (3 << 15) | (15 << 17)
                                | ((flash ? 15 : 0) << 21) | ((flash ? 1 : 0) << 25))
            let base = UInt32(vertices.count / 7)
            for corner in 0..<4 {
                vertices.append(contentsOf: (faces[face][corner] + uv[corner]).map(\.bitPattern))
                vertices.append(contentsOf: [packed, 0xffffff])
            }
            indices.append(contentsOf: [base, base + 1, base + 2, base + 2, base + 3, base])
        }
        return RayTracingBlockGeometry(key: key, vertices: vertices, indices: indices)
    }
}
