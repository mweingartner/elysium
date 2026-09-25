import Foundation
import Metal
import XCTest
@testable import Elysium

final class RayTracingGPUProfilerTests: XCTestCase {
    private func samples(_ timestamps: [RayTracingGPUProfiler.Boundary: UInt64]) -> [UInt64?] {
        var result = [UInt64?](repeating: nil, count: RayTracingGPUProfiler.Boundary.allCases.count)
        for (boundary, timestamp) in timestamps { result[boundary.rawValue] = timestamp }
        return result
    }

    func testCalibrationUsesClockRatioAndRejectsMissingOrInvalidSamples() {
        let start = UInt64.max - 10_000_000
        let timings = RayTracingGPUProfiler.makeTimings(frameIndex: 60,
            samples: samples([.accelerationStart: start, .pathStart: start + 10, .pathEnd: start + 110,
                              .mediaStart: start + 160, .mediaEnd: start + 180]),
            cpuStart: start, gpuStart: start, cpuEnd: start + 2_000_000, gpuEnd: start + 1_000,
            commandStart: 100, commandEnd: 100.003)
        XCTAssertEqual(timings.sampleFrameIndex, 60)
        XCTAssertEqual(timings.accelerationMS!, 0.02, accuracy: 0.000001)
        XCTAssertEqual(timings.pathMS!, 0.2, accuracy: 0.000001)
        XCTAssertEqual(timings.denoiseMS!, 0.1, accuracy: 0.000001)
        XCTAssertNil(timings.surfaceMS)
        XCTAssertNil(timings.milliseconds["surface"])
        XCTAssertEqual(timings.mediaMS!, 0.04, accuracy: 0.000001)
        XCTAssertEqual(timings.wholeCommandMS!, 3, accuracy: 0.000001)
        let withSurface = RayTracingGPUProfiler.makeTimings(frameIndex: 120,
            samples: samples([.accelerationStart: start, .pathStart: start + 10, .pathEnd: start + 110,
                              .surfaceStart: start + 160, .surfaceEnd: start + 210,
                              .mediaStart: start + 220, .mediaEnd: start + 240]),
            cpuStart: start, gpuStart: start, cpuEnd: start + 2_000_000, gpuEnd: start + 1_000,
            commandStart: 100, commandEnd: 100.003)
        XCTAssertEqual(withSurface.denoiseMS!, 0.1, accuracy: 0.000001,
                       "The native surface pass must not be counted as denoising")
        XCTAssertEqual(withSurface.surfaceMS!, 0.1, accuracy: 0.000001)
        XCTAssertEqual(withSurface.milliseconds["surface"]!, 0.1, accuracy: 0.000001)
        XCTAssertEqual(withSurface.mediaMS!, 0.04, accuracy: 0.000001)
        let missing = RayTracingGPUProfiler.makeTimings(frameIndex: 1,
            samples: samples([.pathStart: 30, .pathEnd: 20, .surfaceStart: UInt64.max,
                              .surfaceEnd: 0, .mediaStart: UInt64.max, .mediaEnd: 0]),
            cpuStart: 1, gpuStart: 1, cpuEnd: 2, gpuEnd: 2,
            commandStart: .nan, commandEnd: 1)
        XCTAssertTrue(missing.milliseconds.isEmpty)
        let invalidSurface = RayTracingGPUProfiler.makeTimings(frameIndex: 2,
            samples: samples([.pathEnd: 10, .surfaceStart: 0, .surfaceEnd: 20,
                              .mediaStart: 30, .mediaEnd: 40]),
            cpuStart: 1, gpuStart: 1, cpuEnd: 2, gpuEnd: 2,
            commandStart: .nan, commandEnd: 1)
        XCTAssertNil(invalidSurface.denoiseMS,
                     "An invalid recorded surface timestamp must not silently fold surface work into denoising")
        XCTAssertNil(invalidSurface.surfaceMS)
        XCTAssertNotNil(invalidSurface.mediaMS)
        let invalidCalibration = RayTracingGPUProfiler.makeTimings(frameIndex: 2,
            samples: samples([.accelerationStart: 1, .pathStart: 2, .pathEnd: 3,
                              .surfaceStart: 4, .surfaceEnd: 5, .mediaStart: 6, .mediaEnd: 7]),
            cpuStart: 1, gpuStart: 5, cpuEnd: 2, gpuEnd: 5,
            commandStart: 1, commandEnd: 1.001)
        XCTAssertNil(invalidCalibration.pathMS)
        XCTAssertEqual(invalidCalibration.milliseconds.count, 1)
    }

    func testSamplingCadenceAndCompletedGPUStagesUseIndependentBuffers() throws {
        try verifyCompletedGPUStages(includeSurface: false)
    }

    func testCompletedGPUStagesSeparateNativeSurfaceFromDenoising() throws {
        try verifyCompletedGPUStages(includeSurface: true)
    }

    private func verifyCompletedGPUStages(includeSurface: Bool) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("Metal unavailable")
        }
        let profiler = RayTracingGPUProfiler(device: device)
        let skipped = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertNil(profiler.beginFrame(command: skipped, frameIndex: 1))
        guard profiler.isSupported else {
            XCTAssertNil(profiler.beginFrame(command: skipped, frameIndex: 60, force: true))
            throw XCTSkip("GPU timestamp stage counters unavailable")
        }
        let library = try device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            kernel void profilerWork(device uint *values [[buffer(0)]], uint i [[thread_position_in_grid]]) {
                uint v = values[i];
                for (uint j=0;j<128;++j) { v = (v ^ (j + i)) * 1664525u + 1013904223u; }
                values[i] = v;
            }
            """, options: nil)
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "profilerWork")))
        let buffer = try XCTUnwrap(device.makeBuffer(length: 4096 * MemoryLayout<UInt32>.stride, options: .storageModeShared))
        memset(buffer.contents(), 0, buffer.length)
        let completed = expectation(description: "Both independent sampled commands complete")
        completed.expectedFulfillmentCount = 2
        var commands: [MTLCommandBuffer] = []
        for index in [UInt64(60), UInt64(120)] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let frame = try XCTUnwrap(profiler.beginFrame(command: command, frameIndex: index))
            func work(_ descriptor: MTLComputePassDescriptor) throws {
                let encoder = try XCTUnwrap(command.makeComputeCommandEncoder(descriptor: descriptor))
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(buffer, offset: 0, index: 0)
                encoder.dispatchThreads(.init(width: 4096, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: 64, height: 1, depth: 1))
                encoder.endEncoding()
            }
            try work(frame.computePass(start: .pathStart, end: .pathEnd))
            try work(MTLComputePassDescriptor()) // Stand-in for the externally encoded denoiser.
            if includeSurface { try work(frame.computePass(start: .surfaceStart, end: .surfaceEnd)) }
            try work(frame.computePass(start: .mediaStart, end: .mediaEnd))
            command.addCompletedHandler { _ in completed.fulfill() }
            command.commit()
            commands.append(command)
        }
        wait(for: [completed], timeout: 15)
        for command in commands { XCTAssertEqual(command.status, .completed, "\(String(describing: command.error))") }
        let value = try XCTUnwrap(profiler.latest)
        XCTAssertEqual(value.sampleFrameIndex, 120)
        XCTAssertNil(value.accelerationMS, "Unrecorded counters must not appear as a zero-millisecond measurement")
        XCTAssertGreaterThan(try XCTUnwrap(value.pathMS), 0)
        XCTAssertGreaterThan(try XCTUnwrap(value.denoiseMS), 0)
        if includeSurface {
            XCTAssertGreaterThan(try XCTUnwrap(value.surfaceMS), 0)
            XCTAssertEqual(value.milliseconds["surface"], value.surfaceMS)
        } else {
            XCTAssertNil(value.surfaceMS)
            XCTAssertNil(value.milliseconds["surface"])
        }
        XCTAssertGreaterThan(try XCTUnwrap(value.mediaMS), 0)
        XCTAssertGreaterThan(try XCTUnwrap(value.wholeCommandMS), 0)
        XCTAssertLessThanOrEqual(value.pathMS! + value.denoiseMS! + (value.surfaceMS ?? 0) + value.mediaMS!,
                                 value.wholeCommandMS! * 1.2 + 0.1)
    }
}
