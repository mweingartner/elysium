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
        let depth: [Float]
        let radiance: [SIMD4<Float>]
        func depthAt(_ x: Int, _ y: Int) -> Float { depth[y * width + x] }
    }

    private let section = SectionKey(cx: 0, sy: 0, cz: 0)

    private func fixture(splitAlpha: Bool = false, slices: Int = 2, redTile: Int? = nil) throws -> Fixture {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsRaytracing else {
            throw XCTSkip("Requires a Metal device with ray tracing support")
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        // Capability is known supported: a shader/pipeline failure is a test
        // failure, not an unsupported-device skip.
        let renderer = try XCTUnwrap(RayTracedWorldRenderer(device: device),
                                    "Production ray-tracing shader pipelines must compile")
        renderer.resize(width: 32, height: 32)
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DArray
        descriptor.pixelFormat = .rgba8Unorm
        descriptor.width = 16; descriptor.height = 16; descriptor.arrayLength = slices
        descriptor.usage = .shaderRead
        let atlas = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        for slice in 0..<slices {
            var pixels = [UInt8](repeating: 255, count: 16 * 16 * 4)
            if slice == redTile {
                for pixel in 0..<(16 * 16) {
                    pixels[pixel * 4 + 1] = 0; pixels[pixel * 4 + 2] = 0
                }
            }
            if splitAlpha && slice == 0 {
                for y in 0..<16 { for x in 0..<8 { pixels[(y * 16 + x) * 4 + 3] = 0 } }
            }
            pixels.withUnsafeBytes { raw in
                atlas.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, slice: slice,
                              withBytes: raw.baseAddress!, bytesPerRow: 16 * 4, bytesPerImage: 16 * 16 * 4)
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
        let colorStride = ((width * 8 + 255) / 256) * 256
        let depthBytes = try XCTUnwrap(fixture.device.makeBuffer(length: depthStride * height,
                                                                options: .storageModeShared))
        let colorBytes = try XCTUnwrap(fixture.device.makeBuffer(length: colorStride * height,
                                                                options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: depth, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: width, height: height, depth: 1), to: depthBytes,
                  destinationOffset: 0, destinationBytesPerRow: depthStride,
                  destinationBytesPerImage: depthStride * height)
        blit.copy(from: color, sourceSlice: 0, sourceLevel: 0, sourceOrigin: .init(x: 0, y: 0, z: 0),
                  sourceSize: .init(width: width, height: height, depth: 1), to: colorBytes,
                  destinationOffset: 0, destinationBytesPerRow: colorStride,
                  destinationBytesPerImage: colorStride * height)
        blit.endEncoding()
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "GPU command failed")
        if command.status != .completed { throw NSError(domain: "RayTracingGPUFixture", code: 1) }
        var depths: [Float] = [], colors: [SIMD4<Float>] = []
        for y in 0..<height {
            let depthRow = depthBytes.contents().advanced(by: y * depthStride).assumingMemoryBound(to: Float.self)
            let colorRow = colorBytes.contents().advanced(by: y * colorStride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                depths.append(depthRow[x])
                colors.append(SIMD4<Float>(Float(Float16(bitPattern: colorRow[x * 4])),
                    Float(Float16(bitPattern: colorRow[x * 4 + 1])),
                    Float(Float16(bitPattern: colorRow[x * 4 + 2])),
                    Float(Float16(bitPattern: colorRow[x * 4 + 3]))))
            }
        }
        XCTAssertTrue(depths.allSatisfy { $0.isFinite && (0...1).contains($0) })
        XCTAssertTrue(colors.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
        return Image(width: width, height: height, depth: depths, radiance: colors)
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
}
