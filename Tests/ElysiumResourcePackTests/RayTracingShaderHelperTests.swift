import Metal
import simd
import XCTest
@testable import Elysium

/// Pure-math ray-tracing shader helpers (RayTracingShaders.swift), exercised on the real GPU via a
/// probe kernel compiled from ELYSIUM_ENVIRONMENT_MSL+RAY_TRACING_MSL, the same two strings the
/// production `rt_pathtrace`/`rt_surface_resolve` kernels compile from. None of these helpers touch
/// an acceleration structure, so no BLAS/TLAS is built here (contrast RayTracingAlphaIntersectionTests).
final class RayTracingShaderHelperTests: XCTestCase {
    private static let probeMSL = """
    kernel void rt_helper_probe(device float4* result [[buffer(0)]], uint index [[thread_position_in_grid]]) {
        if (index < 9) {
            // rtAboveHorizon sampled at t = dot(direction, planeNormal) across and around the
            // 0.05 threshold. planeNormal = (0,1,0); direction is a unit vector with direction.y = t.
            float ts[9] = {-0.9, -0.5, -0.1, 0.0, 0.02, 0.0499, 0.05, 0.2, 0.9};
            float t = ts[index];
            float3 direction = float3(sqrt(max(0.0, 1.0 - t * t)), t, 0.0);
            float3 corrected = rtAboveHorizon(direction, float3(0, 1, 0));
            result[index] = float4(corrected, dot(corrected, float3(0, 1, 0)));
            return;
        }
        if (index == 9) {
            // rtClampLuminance over the limit: hue preserved, luminance capped exactly.
            float3 c = float3(6.0, 3.0, 1.0);
            float3 clamped = rtClampLuminance(c, 2.0);
            result[index] = float4(clamped, dot(clamped, float3(0.2126, 0.7152, 0.0722)));
            return;
        }
        if (index == 10) {
            // rtClampLuminance under the limit: passthrough, unchanged.
            float3 c = float3(0.1, 0.2, 0.3);
            result[index] = float4(rtClampLuminance(c, 5.0), 0);
            return;
        }
        if (index < 14) {
            // rtR2: a handful of (index, rotation) pairs, including a large index.
            uint2 samples[3] = { uint2(0, 0), uint2(1, 0), uint2(1000000, 7) };
            uint2 s = samples[index - 11];
            float2 xi = rtR2(s.x, float2(0.31, 0.77) * float(max(1u, s.y)));
            result[index] = float4(xi, 0, 0);
            return;
        }
        // rtSkyCoordinate / rtSkyDirection round trip, including both poles.
        float3 directions[6] = {
            float3(0, 1, 0), float3(0, -1, 0), normalize(float3(1, 1, 1)),
            normalize(float3(-1, 0.4, 0.3)), normalize(float3(0.2, -0.6, 0.9)), normalize(float3(1, 0, 0))
        };
        float3 d = directions[index - 14];
        float2 uv = rtSkyCoordinate(d);
        result[index] = float4(rtSkyDirection(uv), 0);
    }
    """

    private static let sampleCount = 20

    private func evaluate() throws -> [SIMD4<Float>] {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsRaytracing else {
            throw XCTSkip("Compiling RAY_TRACING_MSL requires a ray-tracing-capable device")
        }
        let options = MTLCompileOptions(); options.languageVersion = .version3_1
        let library = try device.makeLibrary(source: ELYSIUM_ENVIRONMENT_MSL + RAY_TRACING_MSL + Self.probeMSL, options: options)
        let function = try XCTUnwrap(library.makeFunction(name: "rt_helper_probe"))
        let pipeline = try device.makeComputePipelineState(function: function)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let output = try XCTUnwrap(device.makeBuffer(length: Self.sampleCount * MemoryLayout<SIMD4<Float>>.stride,
                                                    options: .storageModeShared))
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: Self.sampleCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(Self.sampleCount, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertNil(command.error)
        XCTAssertEqual(command.status, .completed)
        return Array(UnsafeBufferPointer(start: output.contents().assumingMemoryBound(to: SIMD4<Float>.self), count: Self.sampleCount))
    }

    func testAboveHorizonNeverDropsBelowTheTwoPercentFloor() throws {
        let result = try evaluate()
        // t = -0.9,-0.5,-0.1,0.0,0.02,0.0499 (indices 0...5): every one is corrected upward.
        // The floor is approached, not exactly hit, at t=0 (the denominator normalizes slightly
        // above 1), so the assertion allows that ~0.0004 shortfall rather than a bare 0.02.
        for index in 0...5 {
            XCTAssertGreaterThanOrEqual(result[index].w, 0.0199,
                "Sample \(index): a reflected/refracted direction must never dip back below the water plane")
            let n = SIMD3(result[index].x, result[index].y, result[index].z)
            XCTAssertEqual(simd_length(n), 1, accuracy: 0.0001, "Sample \(index) must remain a unit vector")
        }
    }

    func testAboveHorizonIsContinuousAtTheThresholdAndInertAboveIt() throws {
        let result = try evaluate()
        // t=0.05 (index 6) sits exactly on the branch boundary and must return the direction
        // unchanged; t=0.0499 (index 5) is corrected but the ramp must meet it without a jump.
        XCTAssertEqual(result[6].w, 0.05, accuracy: 0.00001)
        XCTAssertEqual(result[5].w, result[6].w, accuracy: 0.005,
            "The correction ramp must be continuous approaching the 0.05 threshold, not a step")
        // t=0.2 and t=0.9 (indices 7,8) are above the threshold: passed through untouched.
        XCTAssertEqual(result[7].w, 0.2, accuracy: 0.00001)
        XCTAssertEqual(result[8].w, 0.9, accuracy: 0.00001)
    }

    func testClampLuminancePreservesHueAndCapsExactlyAtTheLimit() throws {
        let result = try evaluate()
        let original = SIMD3<Float>(6, 3, 1)
        let clamped = SIMD3(result[9].x, result[9].y, result[9].z)
        let ratios = clamped / original
        XCTAssertEqual(ratios.x, ratios.y, accuracy: 0.0001, "Every channel must be scaled by the same factor")
        XCTAssertEqual(ratios.y, ratios.z, accuracy: 0.0001)
        XCTAssertLessThan(ratios.x, 1, "An over-limit color must actually be attenuated")
        XCTAssertEqual(result[9].w, 2.0, accuracy: 0.0001, "The resulting luminance must land exactly on the cap")
    }

    func testClampLuminanceIsANoOpBelowTheLimit() throws {
        let result = try evaluate()
        XCTAssertEqual(result[10].x, 0.1, accuracy: 0.00001)
        XCTAssertEqual(result[10].y, 0.2, accuracy: 0.00001)
        XCTAssertEqual(result[10].z, 0.3, accuracy: 0.00001)
    }

    func testR2ValuesStayInTheUnitSquare() throws {
        let result = try evaluate()
        for index in 11...13 {
            for channel in 0..<2 {
                XCTAssertGreaterThanOrEqual(result[index][channel], 0, "rtR2 sample \(index)")
                XCTAssertLessThan(result[index][channel], 1, "rtR2 sample \(index)")
            }
        }
        // Consecutive lattice indices under the same rotation must actually decorrelate:
        // sample 11 (index 0) and sample 12 (index 1) must not coincide.
        XCTAssertNotEqual(result[11].x, result[12].x)
    }

    func testSkyCoordinateAndDirectionRoundTripIncludingBothPoles() throws {
        let result = try evaluate()
        let directions: [SIMD3<Float>] = [
            SIMD3(0, 1, 0), SIMD3(0, -1, 0), simd_normalize(SIMD3(1, 1, 1)),
            simd_normalize(SIMD3(-1, 0.4, 0.3)), simd_normalize(SIMD3(0.2, -0.6, 0.9)), simd_normalize(SIMD3(1, 0, 0)),
        ]
        for (offset, expected) in directions.enumerated() {
            let index = offset + 14
            let roundtrip = SIMD3(result[index].x, result[index].y, result[index].z)
            XCTAssertEqual(simd_length(roundtrip), 1, accuracy: 0.001, "Sample \(index) must stay a unit direction")
            for channel in 0..<3 {
                XCTAssertEqual(roundtrip[channel], expected[channel], accuracy: 0.001, "Sample \(index) channel \(channel)")
            }
        }
    }
}
