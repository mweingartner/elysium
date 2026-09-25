import XCTest
import Metal
@testable import Elysium
@testable import ElysiumCore

final class RenderLocalLightingTests: XCTestCase {
    private func sections(size: Int = 64, source: SIMD3<Int> = .init(32, 32, 32), level: UInt8 = 15,
                          wallX: Int? = nil, doorway: Bool = false) -> [RenderLocalLightSection] {
        var result: [RenderLocalLightSection] = []
        for z in stride(from: 0, to: size, by: 16) {
            for y in stride(from: 0, to: size, by: 16) {
                for x in stride(from: 0, to: size, by: 16) {
                    let origin = SIMD3(x, y, z)
                    var opacity = [UInt8](repeating: 0, count: 4096)
                    if let wallX, wallX >= x, wallX < x + 16 {
                        for zz in 0..<16 { for yy in 0..<16 {
                            if !doorway || y + yy != 32 || z + zz != 32 {
                                opacity[wallX - x + 16 * (yy + 16 * zz)] = 15
                            }
                        } }
                    }
                    let p = source &- origin
                    let emitters: [MeshLightEmitter] = p.x >= 0 && p.y >= 0 && p.z >= 0 && p.x < 16 && p.y < 16 && p.z < 16 && level > 0
                        ? [.init(position: .init(UInt8(p.x), UInt8(p.y), UInt8(p.z)), level: level, color: .init(1, 0.8, 0.5))] : []
                    result.append(.init(origin: origin, metadata: .init(opacity: opacity, emitters: emitters)))
                }
            }
        }
        return result
    }

    private func level(_ field: RenderLocalLightField, _ p: SIMD3<Int>) -> Int {
        let sample = field.sample(worldPosition: .init(Double(p.x) + 0.5, Double(p.y) + 0.5, Double(p.z) + 0.5))
        return Int((sample.w * 30).rounded())
    }

    func testDoubledTorchAndLanternReachCrossesSectionSeams() throws {
        let torch = try XCTUnwrap(RenderLocalLightField.build(origin: .zero, size: 64,
            sections: sections(source: .init(31, 32, 32), level: 14)))
        XCTAssertEqual(level(torch, .init(31, 32, 32)), 28)
        XCTAssertEqual(level(torch, .init(32, 32, 32)), 27)
        XCTAssertEqual(level(torch, .init(45, 32, 32)), 14, "The former radius is now halfway through the visual reach")
        XCTAssertEqual(level(torch, .init(58, 32, 32)), 1)
        XCTAssertEqual(level(torch, .init(59, 32, 32)), 0)
        let lantern = try XCTUnwrap(RenderLocalLightField.build(origin: .zero, size: 64,
            sections: sections(source: .init(31, 32, 32))))
        XCTAssertEqual(level(lantern, .init(60, 32, 32)), 1)
        XCTAssertEqual(level(lantern, .init(61, 32, 32)), 0)
    }

    func testSolidWallStopsLevelThirtyAndDoorwayAdmitsIt() throws {
        let blocked = try XCTUnwrap(RenderLocalLightField.build(origin: .zero, size: 64,
            sections: sections(source: .init(30, 32, 32), wallX: 32)))
        XCTAssertGreaterThan(level(blocked, .init(31, 32, 32)), 0)
        XCTAssertEqual(level(blocked, .init(32, 32, 32)), 0)
        XCTAssertEqual(level(blocked, .init(33, 32, 32)), 0)
        let open = try XCTUnwrap(RenderLocalLightField.build(origin: .zero, size: 64,
            sections: sections(source: .init(30, 32, 32), wallX: 32, doorway: true)))
        XCTAssertEqual(level(open, .init(33, 32, 32)), 27)
        XCTAssertGreaterThan(level(open, .init(34, 33, 32)), 0, "Light may bend around an open doorway")
    }

    func testMissingSectionsDoNotTransmitAndSourceOrderIsStable() throws {
        var input = sections(source: .init(15, 32, 32))
        input.removeAll { $0.origin.x == 16 }
        let field = try XCTUnwrap(RenderLocalLightField.build(origin: .zero, size: 64, sections: input))
        XCTAssertEqual(level(field, .init(32, 32, 32)), 0)
        XCTAssertEqual(field.sample(worldPosition: .init(20, 32, 32)), .zero)
        let backwards = try XCTUnwrap(RenderLocalLightField.build(origin: .zero, size: 64, sections: input.reversed()))
        XCTAssertEqual(field.rgba, backwards.rgba)
        XCTAssertNil(RenderLocalLightField.build(origin: .zero, size: 1024, sections: []))
        XCTAssertEqual(field.sample(worldPosition: .init(.nan, 0, 0)), .zero)
    }

    private func waitForVolume(_ cache: RenderLocalLighting, camera: SIMD3<Double> = .init(32, 32, 32),
                               origin: SIMD3<Int>? = nil,
                               file: StaticString = #filePath, line: UInt = #line) throws -> RenderLocalLightVolume {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let volume = cache.prepare(camera: camera), origin == nil || volume.origin == origin { return volume }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        } while Date() < deadline
        XCTFail("Presentation light worker did not finish", file: file, line: line)
        throw NSError(domain: "RenderLocalLightingTests", code: 1)
    }

    func testAsyncSourceRemovalRejectsStaleCompletionAndCameraOnlyDoesNotChangeGeneration() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        XCTAssertTrue(Thread.isMainThread)
        let queue = DispatchQueue(label: "test.local-light.suspended")
        queue.suspend()
        var resumed = false
        defer { if !resumed { queue.resume() } }
        let cache = RenderLocalLighting(device: device, queue: queue)
        let input = sections()
        for section in input { cache.upload(origin: section.origin, metadata: section.metadata) }
        XCTAssertNil(cache.prepare(camera: .init(32, 32, 32)))
        let emitterSection = try XCTUnwrap(input.first { !$0.metadata.emitters.isEmpty })
        cache.upload(origin: emitterSection.origin, metadata: .init(opacity: emitterSection.metadata.opacity, emitters: []))
        queue.resume()
        resumed = true
        let unlit = try waitForVolume(cache)
        XCTAssertEqual(unlit.sample(worldPosition: .init(33, 32, 32)).w, 0)
        cache.upload(origin: emitterSection.origin, metadata: emitterSection.metadata)
        XCTAssertNil(cache.prepare(camera: .init(32, 32, 32)), "Mutations must immediately invalidate stale displayed light")
        let lit = try waitForVolume(cache)
        XCTAssertGreaterThan(lit.sample(worldPosition: .init(33, 32, 32)).w, 0)
        XCTAssertGreaterThan(lit.generation, unlit.generation)
        cache.upload(origin: .init(4096, 0, 4096), metadata: emitterSection.metadata)
        XCTAssertEqual(cache.prepare(camera: .init(32, 32, 32))?.generation, lit.generation)
        XCTAssertTrue(cache.prepare(camera: .init(48, 32, 32))?.texture === lit.texture,
                      "Ordinary camera recenter must retain the mature field while its replacement builds")
        let moved = try waitForVolume(cache, camera: .init(48, 32, 32), origin: .init(-16, -32, -32))
        XCTAssertEqual(moved.generation, lit.generation)
        XCTAssertFalse(moved.texture === lit.texture, "Each finished upload owns a new immutable texture")
        cache.removeChunk(cx: 2, cz: 2)
        XCTAssertNil(cache.prepare(camera: .init(48, 32, 32)))
        let removed = try waitForVolume(cache, camera: .init(48, 32, 32))
        XCTAssertEqual(removed.sample(worldPosition: .init(31, 32, 32)).w, 0)
        cache.clear()
        XCTAssertNil(cache.prepare(camera: .init(48, 32, 32)))
    }

    func testActualMetalSamplingUsesTunedRadianceWithoutCrossWallInterpolation() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal unavailable")
        }
        XCTAssertEqual(MemoryLayout<RenderLocalLightUniforms>.stride, 32)
        let field = try XCTUnwrap(RenderLocalLightField.build(origin: .zero, size: 64,
            sections: sections(source: .init(31, 32, 32), wallX: 32)))
        let volume = try XCTUnwrap(RenderLocalLightVolume(device: device, field: field, generation: 1))
        let source = renderLocalLightingShaderSource + #"""
        kernel void lightingProbe(device float4 *out [[buffer(0)]],
            constant RenderLocalLightUniforms &u [[buffer(1)]], texture3d<float> light [[texture(0)]],
            uint i [[thread_position_in_grid]]) {
            float3 p = i < 2 ? float3(32,32.5,32.5) : i == 2 ? float3(-1,32,32) : float3(4,32,32);
            float3 n = i == 0 ? float3(-1,0,0) : i == 1 ? float3(1,0,0) : float3(0);
            out[i] = sampleRenderLocalLight(p,n,u,light);
        }
        """#
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "lightingProbe")))
        let output = try XCTUnwrap(device.makeBuffer(length: 4 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
        var u = RenderLocalLightUniforms(originAndSize: .init(0, 0, 0, 64),
            params: .init(1, RenderLocalLightPolicy.outputMultiplier, 0, 0))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.setBytes(&u, length: MemoryLayout<RenderLocalLightUniforms>.stride, index: 1)
        encoder.setTexture(volume.texture, index: 0)
        encoder.dispatchThreads(.init(width: 4, height: 1, depth: 1), threadsPerThreadgroup: .init(width: 4, height: 1, depth: 1))
        encoder.endEncoding(); command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))")
        let values = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: 4)
        XCTAssertEqual(values[0].x, 1.7, accuracy: 0.0001)
        XCTAssertEqual(values[0].w, 1, accuracy: 0.0001)
        XCTAssertEqual(values[1].x, 0, accuracy: 0.0001, "The opaque neighbor must not interpolate the bright source")
        XCTAssertEqual(values[2], .zero)
        XCTAssertGreaterThan(values[3].w, 0)
        XCTAssertLessThan(values[3].w, 1, "The outer16 blocks blend into the existing light cache")
    }

    func testClearDuringInFlightWorkCannotPublishPreviousWorldLight() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        let queue = DispatchQueue(label: "test.local-light.world-switch")
        queue.suspend()
        var resumed = false
        defer { if !resumed { queue.resume() } }
        let cache = RenderLocalLighting(device: device, queue: queue)
        for section in sections() { cache.upload(origin: section.origin, metadata: section.metadata) }
        XCTAssertNil(cache.prepare(camera: .init(32, 32, 32)))
        cache.clear()
        for section in sections(level: 0) { cache.upload(origin: section.origin, metadata: section.metadata) }
        XCTAssertNil(cache.prepare(camera: .init(32, 32, 32)))
        queue.resume()
        resumed = true
        let replacement = try waitForVolume(cache)
        XCTAssertEqual(replacement.sample(worldPosition: .init(32, 32, 32)), .init(1, 1, 1, 0))
    }
}
