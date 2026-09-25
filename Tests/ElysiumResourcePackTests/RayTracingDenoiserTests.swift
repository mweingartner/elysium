import Foundation
import Metal
import MetalFX
import simd
import XCTest
@testable import Elysium

final class RayTracingDenoiserTests: XCTestCase {
    private struct Fixture {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let denoiser: RayTracingDenoiser
        let size: Int
        let color: MTLTexture
        let depth: MTLTexture
        let motion: MTLTexture
        let normal: MTLTexture
        let diffuse: MTLTexture
        let specular: MTLTexture
        let guide: [Float16]
        let projection: simd_float4x4

        func upload(_ pixels: [Float16], to texture: MTLTexture) {
            pixels.withUnsafeBytes { bytes in
                texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                                withBytes: bytes.baseAddress!, bytesPerRow: size * 8)
            }
        }

        func encode(_ command: MTLCommandBuffer, reset: Bool = false,
                    depthOverride: MTLTexture? = nil) -> MTLTexture? {
            denoiser.encode(command: command, color: color, depth: depthOverride ?? depth,
                motion: motion, normals: normal, diffuseAlbedo: diffuse, specularAlbedo: specular,
                worldToView: matrix_identity_float4x4, viewToClip: projection, reset: reset)
        }
    }

    private func fixture(size: Int = 128, existing: RayTracingDenoiser? = nil) throws -> Fixture {
        guard #available(macOS 26.0, *), let device = MTLCreateSystemDefaultDevice(),
              MTLFXTemporalDenoisedScalerDescriptor.supportsDevice(device) else {
            throw XCTSkip("Requires a device supporting MetalFX temporal denoising")
        }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let denoiser = try XCTUnwrap(existing ?? RayTracingDenoiser(device: device))
        func texture(_ format: MTLPixelFormat) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format,
                width: size, height: size, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite]
            return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        }
        let color = try texture(.rgba16Float), depth = try texture(.r32Float)
        let motion = try texture(.rgba16Float), normal = try texture(.rgba16Float)
        let diffuse = try texture(.rgba16Float), specular = try texture(.rgba16Float)
        let depthValues = [Float](repeating: 0.975, count: size * size)
        depthValues.withUnsafeBytes { bytes in
            depth.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                          withBytes: bytes.baseAddress!, bytesPerRow: size * 4)
        }
        var guide: [Float16] = [], normals: [Float16] = [], motions: [Float16] = [], speculars: [Float16] = []
        for y in 0..<size { for x in 0..<size {
            let base: Float16 = ((x / 8 + y / 8) % 2 == 0) ? 0.25 : 0.8
            guide += [base, base, base, 1]
            normals += [0, 0, 1, 2]
            motions += [Float16((Float(x) + 0.5) / Float(size)),
                        Float16((Float(y) + 0.5) / Float(size)), 0.975, 1]
            speculars += [0.04, 0.04, 0.04, 0]
        }}
        let projection = Elysium.mat4Perspective(fovYRad: .pi / 3, aspect: 1, near: 0.05, far: 100)
        let fixture = Fixture(device: device, queue: queue, denoiser: denoiser, size: size,
            color: color, depth: depth, motion: motion, normal: normal, diffuse: diffuse,
            specular: specular, guide: guide, projection: projection)
        fixture.upload(guide, to: color)
        fixture.upload(guide, to: diffuse)
        fixture.upload(normals, to: normal)
        fixture.upload(motions, to: motion)
        fixture.upload(speculars, to: specular)
        return fixture
    }

    private func readback(_ output: MTLTexture, fixture: Fixture,
                          command: MTLCommandBuffer) throws -> [Float16] {
        let rowBytes = fixture.size * 8 // Test sizes are multiples of 32: 256-byte alignment.
        let buffer = try XCTUnwrap(fixture.device.makeBuffer(length: rowBytes * fixture.size,
                                                            options: .storageModeShared))
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from: output, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: fixture.size, height: fixture.size, depth: 1),
            to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
            destinationBytesPerImage: rowBytes * fixture.size)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, String(describing: command.error))
        return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: Float16.self,
            capacity: fixture.size * fixture.size * 4), count: fixture.size * fixture.size * 4))
    }

    func testNativeGPUReconstructionRemovesNoiseAndPreservesPixelArtContrast() throws {
        let fixture = try fixture()
        var last: [Float16] = [], noisy: [Float16] = []
        for frame in 0..<12 {
            noisy = fixture.guide
            for i in 0..<(fixture.size * fixture.size) {
                var hash = UInt32(i) &* 0x9e3779b9 &+ UInt32(frame) &* 0x85ebca6b
                hash ^= hash >> 16; hash &*= 0x7feb352d; hash ^= hash >> 15
                let noise = (Float(hash & 65535) / 65535 - 0.5) * 0.44
                for channel in 0..<3 {
                    noisy[i * 4 + channel] = Float16(max(0, Float(fixture.guide[i * 4 + channel]) + noise))
                }
            }
            fixture.upload(noisy, to: fixture.color)
            let command = try XCTUnwrap(fixture.queue.makeCommandBuffer())
            let output = try XCTUnwrap(fixture.encode(command, reset: frame == 0))
            XCTAssertEqual(output.width, fixture.size)
            XCTAssertEqual(output.height, fixture.size)
            last = try readback(output, fixture: fixture, command: command)
        }
        var rawError = 0.0, outputError = 0.0, low = 0.0, high = 0.0, lowCount = 0, highCount = 0
        for y in 8..<(fixture.size - 8) { for x in 8..<(fixture.size - 8) {
            let index = (y * fixture.size + x) * 4
            let expected = Double(fixture.guide[index]), value = Double(last[index])
            XCTAssertTrue(value.isFinite)
            rawError += pow(Double(noisy[index]) - expected, 2)
            outputError += pow(value - expected, 2)
            if expected < 0.5 { low += value; lowCount += 1 } else { high += value; highCount += 1 }
        }}
        XCTAssertLessThan(outputError, rawError * 0.5, "Denoising must improve actual ray-like noise")
        XCTAssertGreaterThan(high / Double(highCount) - low / Double(lowCount), 0.45,
                             "A blurred checkerboard is not acceptable noise reduction")
    }

    func testInvalidGuidesFallBackAndResizeResetRemainUsable() throws {
        let first = try fixture(size: 64)
        let invalid = try XCTUnwrap(first.queue.makeCommandBuffer())
        XCTAssertNil(first.encode(invalid, depthOverride: first.color), "Reject a non-depth texture before MetalFX validation")
        let firstCommand = try XCTUnwrap(first.queue.makeCommandBuffer())
        let firstOutput = try XCTUnwrap(first.encode(firstCommand))
        let a = try readback(firstOutput, fixture: first, command: firstCommand)
        XCTAssertTrue(a.allSatisfy(\.isFinite))
        first.denoiser.reset()
        let second = try fixture(size: 128, existing: first.denoiser)
        let secondCommand = try XCTUnwrap(second.queue.makeCommandBuffer())
        let secondOutput = try XCTUnwrap(second.encode(secondCommand, reset: true))
        let b = try readback(secondOutput, fixture: second, command: secondCommand)
        XCTAssertEqual(secondOutput.width, 128)
        XCTAssertFalse(firstOutput === secondOutput)
        XCTAssertTrue(b.allSatisfy(\.isFinite))
    }
}
