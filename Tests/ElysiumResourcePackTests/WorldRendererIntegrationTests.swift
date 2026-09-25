import Foundation
import Metal
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// Runs the real pass graph, not a look-alike test renderer: shadow/HDR opaque, cloud depth
/// sampling/upsampling, behind-water translucency, refraction copies, water, bloom and composite.
@MainActor
final class WorldRendererIntegrationTests: XCTestCase {
    func testHeldLightUsesPackedBlockStateAndTunedOutputWithDoubledRadius() {
        registerAllBlocks(); registerAllItems()
        let torch = WorldRenderer.heldLightVector(mainHand: ItemStack(iid("torch"), 1), offHand: nil)
        XCTAssertEqual(torch.w, 28)
        XCTAssertEqual(torch.x, (14.0 / 15) * 0.9 * 1.7, accuracy: 0.00001)
        let soul = WorldRenderer.heldLightVector(mainHand: nil, offHand: ItemStack(iid("soul_torch"), 1))
        XCTAssertEqual(soul.w, 20)
        XCTAssertGreaterThan(soul.z, soul.x)
        XCTAssertEqual(WorldRenderer.heldLightVector(mainHand: ItemStack(iid("iron_pickaxe"), 1), offHand: nil), .zero)
        let strongest = WorldRenderer.heldLightVector(mainHand: ItemStack(iid("soul_torch"), 1),
                                                     offHand: ItemStack(iid("lantern"), 1))
        XCTAssertEqual(strongest.w, 30)
        XCTAssertEqual(strongest.x, 1.53, accuracy: 0.00001)
    }

    private func plane(z: Float, halfSize: Float, tile: UInt32, animation: UInt32 = 0,
                       tint: UInt32 = 0x00ffffff) -> MeshLayer {
        // Section (0,4,0), minY=0: camera (8,70,0) faces +Z, local Y=6 is eye height.
        let positions: [SIMD3<Float>] = [SIMD3(8 - halfSize, 6 - halfSize, z),
            SIMD3(8 + halfSize, 6 - halfSize, z), SIMD3(8 + halfSize, 6 + halfSize, z),
            SIMD3(8 - halfSize, 6 + halfSize, z)]
        let uv: [SIMD2<Float>] = [SIMD2(0,1), SIMD2(1,1), SIMD2(1,0), SIMD2(0,0)]
        let packedA = tile | (2 << 12) | (3 << 15) | (15 << 17)
        var words: [UInt32] = []
        for i in positions.indices {
            words += [positions[i].x.bitPattern, positions[i].y.bitPattern, positions[i].z.bitPattern,
                      uv[i].x.bitPattern, uv[i].y.bitPattern, packedA, tint | (animation << 24)]
        }
        // Explicit front/back pairs match liquid surface sidedness and exercise depth equality.
        return MeshLayer(data: words, idx: [0,2,1,0,3,2, 0,1,2,0,2,3], count: 4)
    }

    private func combine(_ layers: [MeshLayer]) -> MeshLayer {
        var words: [UInt32] = [], indices: [UInt32] = [], count = 0
        for layer in layers {
            let base = UInt32(count)
            words += layer.data
            indices += layer.idx.map { $0 + base }
            count += layer.count
        }
        return MeshLayer(data: words, idx: indices, count: count)
    }

    private func render(_ renderer: WorldRenderer, game: GameCore, device: MTLDevice,
                        width: Int, height: Int) throws {
        renderer.resize(width, height)
        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .private
        let target = try XCTUnwrap(device.makeTexture(descriptor: targetDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        var camera = CamState()
        camera.x = 8; camera.y = 70; camera.z = 0; camera.fov = 70
        let composite = renderer.render(cmd: command, rpd: pass, game: game,
                                         cam: camera, partial: 0.5, timeSec: 12)
        composite.endEncoding()
        XCTAssertEqual(renderer.sceneColor.pixelFormat, .rgba16Float)
        XCTAssertEqual(renderer.sceneDepth.pixelFormat, .depth32Float)
        XCTAssertEqual(renderer.opaqueSceneColor.pixelFormat, .rgba16Float)
        XCTAssertEqual(renderer.opaqueSceneDepth.pixelFormat, .depth32Float)
        let colorStride = ((width * 8 + 255) / 256) * 256
        let depthStride = ((width * 4 + 255) / 256) * 256
        let displayStride = ((width * 4 + 255) / 256) * 256
        let colorBytes = try XCTUnwrap(device.makeBuffer(length: colorStride * height, options: .storageModeShared))
        let depthBytes = try XCTUnwrap(device.makeBuffer(length: depthStride * height, options: .storageModeShared))
        let displayBytes = try XCTUnwrap(device.makeBuffer(length: displayStride * height, options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        for (texture, buffer, stride) in [(renderer.sceneColor!, colorBytes, colorStride),
                                          (renderer.sceneDepth!, depthBytes, depthStride),
                                          (target, displayBytes, displayStride)] {
            blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                      sourceOrigin: .init(x: 0, y: 0, z: 0),
                      sourceSize: .init(width: width, height: height, depth: 1),
                      to: buffer, destinationOffset: 0, destinationBytesPerRow: stride,
                      destinationBytesPerImage: stride * height)
        }
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "")
        var geometryPixels = 0, litPixels = 0
        for y in 0..<height {
            let color = colorBytes.contents().advanced(by: y * colorStride).assumingMemoryBound(to: UInt16.self)
            let depth = depthBytes.contents().advanced(by: y * depthStride).assumingMemoryBound(to: Float.self)
            let display = displayBytes.contents().advanced(by: y * displayStride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                XCTAssertTrue(depth[x].isFinite && (0...1).contains(depth[x]))
                if depth[x] < 0.99999 { geometryPixels += 1 }
                for channel in 0..<4 {
                    let value = Float(Float16(bitPattern: color[x * 4 + channel]))
                    XCTAssertTrue(value.isFinite, "No pass may publish a NaN/Inf to the HDR scene")
                }
                if Int(display[x * 4]) + Int(display[x * 4 + 1]) + Int(display[x * 4 + 2]) > 8 { litPixels += 1 }
                XCTAssertEqual(display[x * 4 + 3], 255)
            }
        }
        XCTAssertGreaterThan(geometryPixels, width * height / 8, "The actual uploaded fixture must be visible")
        XCTAssertGreaterThan(litPixels, width * height / 4, "A successful command must not silently produce a black frame")
    }

    func testActualPassGraphRendersWaterGlassHDRAndResizeInEverySupportedMode() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ElysiumWorldRendererTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try SaveDB.open(databaseURL: root.appendingPathComponent("worlds.sqlite"), migrateLegacy: false)
        defer {
            try? database.close()
            try? FileManager.default.removeItem(at: root)
        }
        let store = LocalSettingsStore(directoryURL: root.appendingPathComponent("settings", isDirectory: true))
        let game = GameCore(db: database, localSettingsStore: store)
        let world = World(dim: .overworld, seed: 1)
        world.dayTime = 6000
        game.worlds[.overworld] = world
        let renderer = WorldRenderer(device: device)
        let empty = MeshLayer(data: [], idx: [], count: 0)
        let opaque = plane(z: 12, halfSize: 5, tile: UInt32(tileId("stone")))
        let glass = plane(z: 8, halfSize: 2.5, tile: UInt32(tileId("glass")), tint: 0x00ffbba0)
        let water = plane(z: 5, halfSize: 3, tile: UInt32(tileId("water")), animation: 1, tint: 0x003f76e4)
        let foregroundGlass = plane(z: 3, halfSize: 0.6, tile: UInt32(tileId("glass")))
        renderer.uploadMesh(0, 4, 0, 0, MeshOutput(opaque: opaque, cutout: empty,
            translucent: combine([glass, water, foregroundGlass])))
        XCTAssertNotNil(renderer.sections[SectionKey(cx: 0, sy: 4, cz: 0)]?.water)
        XCTAssertNotNil(renderer.sections[SectionKey(cx: 0, sy: 4, cz: 0)]?.translucent)
        for mode in GraphicsMode.allCases {
            if mode == .rayTraced && !device.supportsRaytracing { continue }
            var settings = game.settings
            settings.shader = mode.shader
            settings.clouds = true; settings.bloom = true; settings.shadows = true
            _ = try game.persistAndPublishSettingsCandidate(settings, expectedLiveRevision: game.settingsRevision).get()
            try render(renderer, game: game, device: device, width: 64, height: 64)
            XCTAssertEqual(renderer.rayTracingActive, mode == .rayTraced, renderer.rayTracingDiagnostics.status)
            // Odd dimensions catch reciprocal viewport/depth-copy and half-resolution edge bugs.
            try render(renderer, game: game, device: device, width: 96, height: 55)
            XCTAssertEqual(renderer.rayTracingActive, mode == .rayTraced, renderer.rayTracingDiagnostics.status)
        }
        renderer.clearAllSections()
        XCTAssertTrue(renderer.sections.isEmpty)
    }
}
