import Metal
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class RayTracingItemSceneTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
    }

    private func collector() throws -> RayTracingItemScene {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Requires Metal textures") }
        return RayTracingItemScene(device: device)
    }

    private func pixels(_ texture: MTLTexture) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 16 * 16 * 4)
        result.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: 16 * 4,
                from: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0)
        }
        return result
    }

    func testSpriteMatchesNativeBillboardSizeBobUVAndFarOriginInterpolation() throws {
        let scene = try collector()
        let world = World(dim: .overworld, seed: 9)
        let item = ItemEntity(world: world)
        item.stack = ItemStack(iid("iron_pickaxe"), 3)
        item.age = 12
        let origin = SIMD3<Double>(20_000_000, 64, -20_000_000)
        item.prevX = origin.x + 1
        item.prevY = origin.y + 2
        item.prevZ = origin.z - 3
        item.x = item.prevX + 0.5
        item.y = item.prevY + 0.5
        item.z = item.prevZ + 0.5
        var cam = CamState()
        cam.yaw = .pi / 3
        let result = scene.collect(entities: [item], camPos: origin, cam: cam,
                                   partial: 0.5, atlasGeneration: 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(result.blocks.isEmpty)
        let sprite = try XCTUnwrap(result.entities.first)
        XCTAssertEqual(sprite.identity, "physical-sprite:\(item.id)")
        XCTAssertEqual(sprite.transform.columns.3.x, 1.25, accuracy: 0.000001)
        XCTAssertEqual(sprite.transform.columns.3.z, -2.75, accuracy: 0.000001)
        let bob = Float(detSin(12.5 * 0.08) * 0.08 + 0.12)
        XCTAssertEqual(sprite.transform.columns.3.y, 2.25 + bob, accuracy: 0.000001)
        XCTAssertEqual(sprite.transform.columns.0.x, Float(detCos(cam.yaw)) * 0.45, accuracy: 0.000001)
        XCTAssertEqual(sprite.transform.columns.0.z, Float(detSin(cam.yaw)) * 0.45, accuracy: 0.000001)
        XCTAssertEqual(sprite.transform.columns.1, SIMD4<Float>(0, 0.45, 0, 0))
        XCTAssertEqual(sprite.geometry.vertices.count, 6 * 9)
        XCTAssertEqual(Array(sprite.geometry.vertices[0..<9]), [-0.5, 0, 0, 0, 0, 1, 0, 1, 0])
        XCTAssertEqual(Array(sprite.geometry.vertices[18..<27]), [0.5, 1, 0, 0, 0, 1, 1, 0, 0])
        XCTAssertEqual(pixels(sprite.geometry.texture), itemIconPixels(item.stack.id, item.stack.data))
        XCTAssertEqual(item.age, 12)
        XCTAssertEqual(item.stack.count, 3)
        XCTAssertEqual(item.x, origin.x + 1.5)
    }

    func testPotionDataAndLingeringVariantArePreservedWithoutMutatingDrop() throws {
        let world = World(dim: .overworld, seed: 1)
        let potion = ThrownPotion(world: world)
        potion.potionId = "strong_healing"
        potion.lingering = true
        let appearance = try XCTUnwrap(RayTracingItemScene.spriteAppearance(potion))
        XCTAssertEqual(appearance.stack.id, iid("lingering_potion"))
        XCTAssertEqual(appearance.stack.data.potion, "strong_healing")
        XCTAssertEqual(appearance.size, 0.35)
        XCTAssertEqual(appearance.emission, 0)

        let scene = try collector()
        let first = scene.collect(entities: [potion], camPos: .zero, cam: CamState(),
                                  partial: 1, atlasGeneration: 1)
        potion.potionId = "poison"
        let second = scene.collect(entities: [potion], camPos: .zero, cam: CamState(),
                                   partial: 1, atlasGeneration: 1)
        let a = try XCTUnwrap(first.entities.first?.geometry)
        let b = try XCTUnwrap(second.entities.first?.geometry)
        XCTAssertNotEqual(a.key, b.key)
        XCTAssertFalse(a === b)
        XCTAssertTrue(a.key.contains("strong_healing"))
        XCTAssertTrue(b.key.contains("poison"))
    }

    func testCubesPreserveNativeFaceTexturesWindingUVAndTNTFlashCadence() throws {
        let packedCell = Int(cell(B.tnt))
        let geometry = try XCTUnwrap(RayTracingItemScene.cubeGeometry(cell: packedCell, flash: false, key: "cube"))
        XCTAssertEqual(geometry.vertices.count, 24 * 7)
        XCTAssertEqual(geometry.indices.count, 36)
        let decoded = try XCTUnwrap(RayTracingMeshDecoder.decodePacked(data: geometry.vertices,
                                                                     indices: geometry.indices))
        XCTAssertEqual(decoded.primitives.count, 12)
        let definition = blockDefs[Int(B.tnt)]
        for face in 0..<6 {
            let tile = definition.texFn?(0, face) ?? Int(definition.tex[face])
            XCTAssertEqual(decoded.primitives[face * 2].material.y, UInt32(tile))
            XCTAssertEqual(decoded.primitives[face * 2].uv01, SIMD4<Float>(0, 1, 1, 1))
            XCTAssertEqual(decoded.primitives[face * 2].normalEmission.w, 0)
        }
        XCTAssertEqual(decoded.positions.map(\.x).min(), -0.49)
        XCTAssertEqual(decoded.positions.map(\.x).max(), 0.49)
        XCTAssertEqual(decoded.positions.map(\.y).min(), 0)
        XCTAssertEqual(decoded.positions.map(\.y).max(), 0.98)
        let tnt = TNTEntity(world: World(dim: .overworld, seed: 1))
        for fuse in 0...80 {
            tnt.fuse = fuse
            XCTAssertEqual(RayTracingItemScene.blockAppearance(tnt)?.flash, fuse % 10 < 5)
        }
        let flashing = try XCTUnwrap(RayTracingItemScene.cubeGeometry(cell: packedCell, flash: true, key: "flash"))
        let bright = try XCTUnwrap(RayTracingMeshDecoder.decodePacked(data: flashing.vertices, indices: flashing.indices))
        XCTAssertTrue(bright.primitives.allSatisfy { $0.normalEmission.w == 2 })
        XCTAssertNil(RayTracingItemScene.cubeGeometry(cell: -1, flash: false, key: "invalid"))
    }

    func testPhysicalSceneIncludesOffscreenEntitiesButPreservesRangesAndSkipsDead() throws {
        let scene = try collector()
        let world = World(dim: .overworld, seed: 7)
        let visible = ItemEntity(world: world)
        visible.stack = ItemStack(iid("iron_pickaxe"), 1)
        visible.setPos(0, 0, 4) // Behind the camera: still reflects/casts shadows.
        let distant = ItemEntity(world: world)
        distant.setPos(65, 0, 0)
        let dead = ItemEntity(world: world)
        dead.dead = true
        let block = FallingBlockEntity(world: world)
        block.blockCell = Int(cell(B.sand))
        block.setPos(95, 0, 0)
        let tooFar = TNTEntity(world: world)
        tooFar.setPos(97, 0, 0)
        let result = scene.collect(entities: [visible, distant, dead, block, tooFar],
            camPos: .zero, cam: CamState(), partial: 1, atlasGeneration: 1)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.entities.map(\.identity), ["physical-sprite:\(visible.id)"])
        XCTAssertEqual(result.blocks.map(\.identity), ["physical-block:\(block.id)"])
        XCTAssertEqual(result.blocks.first?.transform.columns.3.x, 95)
    }

    func testImmutableCacheReuseEvictionAndResourceGeneration() throws {
        let scene = try collector()
        let world = World(dim: .overworld, seed: 7)
        let item = ItemEntity(world: world)
        item.stack = ItemStack(iid("iron_pickaxe"), 1)
        func collect(_ items: [Entity], generation: UInt64 = 1) -> RayTracingItemPresentation {
            scene.collect(entities: items, camPos: .zero, cam: CamState(), partial: 1,
                          atlasGeneration: generation)
        }
        let original = try XCTUnwrap(collect([item]).entities.first?.geometry)
        let originalPixels = pixels(original.texture)
        XCTAssertTrue(original === collect([item]).entities.first?.geometry)
        let many = (0..<(RayTracingItemScene.cacheLimit + 1)).map { id -> Entity in
            let extra = ItemEntity(world: world)
            extra.stack = ItemStack(id, 1)
            return extra
        }
        let result = collect(many)
        XCTAssertEqual(result.entities.count, many.count)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(scene.cachedSpriteCount, RayTracingItemScene.cacheLimit)
        XCTAssertEqual(pixels(original.texture), originalPixels, "Eviction never overwrites retained textures")
        let replacement = try XCTUnwrap(collect([item], generation: 2).entities.first?.geometry)
        XCTAssertNotEqual(original.key, replacement.key)
        XCTAssertFalse(original === replacement)
        XCTAssertEqual(scene.cachedSpriteCount, 1)
        XCTAssertEqual(pixels(original.texture), originalPixels)
        scene.reset()
        XCTAssertEqual(scene.cachedSpriteCount, 0)
        XCTAssertEqual(scene.cachedCubeCount, 0)
    }

    func testInvalidPhysicalBlockRequestsWholeSceneFallback() throws {
        let scene = try collector()
        let block = FallingBlockEntity(world: World(dim: .overworld, seed: 1))
        block.blockCell = Int.max
        let result = scene.collect(entities: [block], camPos: .zero, cam: CamState(),
                                   partial: 1, atlasGeneration: 1)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.blocks.isEmpty)
    }
}
