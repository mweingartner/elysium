import Foundation
import Metal

/// Sparse stage-boundary measurements, independent of rendering correctness. Unsupported
/// counters, allocation failures, incomplete samples, and failed commands yield no stage data.
/// Apple documents CPU/GPU calibration here (CPU reference timestamps are nanoseconds):
/// See the Metal timestamp-calibration reference in docs/RAY_TRACING.md.
final class RayTracingGPUProfiler {
    enum Boundary: Int, CaseIterable {
        case accelerationStart, pathStart, pathEnd, surfaceStart, surfaceEnd, mediaStart, mediaEnd
    }

    struct Timings: Sendable {
        let sampleFrameIndex: UInt64
        let accelerationMS: Double?
        let pathMS: Double?
        /// Includes guide conversion and MetalFX, or the complete compatible filter chain.
        let denoiseMS: Double?
        let surfaceMS: Double?
        let mediaMS: Double?
        /// Full command-buffer execution, including later raster/HUD/presentation passes.
        let wholeCommandMS: Double?

        var milliseconds: [String: Double] {
            var values: [String: Double] = [:]
            values["acceleration"] = accelerationMS
            values["path"] = pathMS
            values["denoise"] = denoiseMS
            values["surface"] = surfaceMS
            values["media"] = mediaMS
            values["wholeCommand"] = wholeCommandMS
            return values
        }
    }

    /// Each sampled command owns a distinct buffer until its completion handler resolves it.
    /// Descriptors must be requested during encoding, never after command.commit().
    final class Frame {
        let sampleFrameIndex: UInt64
        private let sampleBuffer: MTLCounterSampleBuffer
        private let lock = NSLock()
        private var recorded: UInt8 = 0

        fileprivate init(sampleFrameIndex: UInt64, sampleBuffer: MTLCounterSampleBuffer) {
            self.sampleFrameIndex = sampleFrameIndex
            self.sampleBuffer = sampleBuffer
        }

        private func reserve(_ boundary: Boundary?) -> Int {
            guard let boundary else { return MTLCounterDontSample }
            lock.lock(); defer { lock.unlock() }
            let bit = UInt8(1 << boundary.rawValue)
            guard recorded & bit == 0 else { return MTLCounterDontSample }
            recorded |= bit
            return boundary.rawValue
        }

        func computePass(start: Boundary? = nil, end: Boundary? = nil) -> MTLComputePassDescriptor {
            let descriptor = MTLComputePassDescriptor()
            let attachment = descriptor.sampleBufferAttachments[0]!
            attachment.sampleBuffer = sampleBuffer
            attachment.startOfEncoderSampleIndex = reserve(start)
            attachment.endOfEncoderSampleIndex = reserve(end)
            return descriptor
        }

        func accelerationPass(start: Boundary? = nil, end: Boundary? = nil) -> MTLAccelerationStructurePassDescriptor {
            let descriptor = MTLAccelerationStructurePassDescriptor()
            let attachment = descriptor.sampleBufferAttachments[0]!
            attachment.sampleBuffer = sampleBuffer
            attachment.startOfEncoderSampleIndex = reserve(start)
            attachment.endOfEncoderSampleIndex = reserve(end)
            return descriptor
        }

        fileprivate func resolve() -> [UInt64?] {
            lock.lock(); let mask = recorded; lock.unlock()
            let count = Boundary.allCases.count
            guard let data = try? sampleBuffer.resolveCounterRange(0..<count),
                  data.count >= count * MemoryLayout<MTLCounterResultTimestamp>.stride else {
                return [UInt64?](repeating: nil, count: count)
            }
            return data.withUnsafeBytes { bytes in
                (0..<count).map { index -> UInt64? in
                    guard mask & UInt8(1 << index) != 0 else { return nil }
                    let stamp = bytes.loadUnaligned(fromByteOffset: index * MemoryLayout<MTLCounterResultTimestamp>.stride,
                                                    as: MTLCounterResultTimestamp.self).timestamp
                    // Preserve invalid recorded values until duration validation, so an
                    // unavailable surface-start counter is not mistaken for an absent pass.
                    return stamp
                }
            }
        }
    }

    let isSupported: Bool
    let sampleInterval: UInt64
    private let device: MTLDevice
    private let timestampSet: MTLCounterSet?
    private let lock = NSLock()
    private var latestValue: Timings?

    var latest: Timings? {
        lock.lock(); defer { lock.unlock() }
        return latestValue
    }

    init(device: MTLDevice, sampleInterval: UInt64 = 60) {
        self.device = device
        self.sampleInterval = max(1, sampleInterval)
        let set = device.counterSets?.first { $0.name == MTLCommonCounterSet.timestamp.rawValue }
        timestampSet = set
        isSupported = set != nil && device.supportsCounterSampling(.atStageBoundary)
    }

    func beginFrame(command: MTLCommandBuffer, frameIndex: UInt64, force: Bool = false) -> Frame? {
        guard isSupported, command.device.registryID == device.registryID,
              command.status == .notEnqueued || command.status == .enqueued,
              force || frameIndex % sampleInterval == 0, let timestampSet else { return nil }
        let descriptor = MTLCounterSampleBufferDescriptor()
        descriptor.counterSet = timestampSet
        descriptor.storageMode = .shared
        descriptor.sampleCount = Boundary.allCases.count
        descriptor.label = "RT stage timestamps frame \(frameIndex)"
        guard let buffer = try? device.makeCounterSampleBuffer(descriptor: descriptor) else { return nil }
        let frame = Frame(sampleFrameIndex: frameIndex, sampleBuffer: buffer)
        let baseline = device.sampleTimestamps()
        command.addCompletedHandler { [weak self, frame, device] completed in
            guard completed.status == .completed else { return }
            let final = device.sampleTimestamps()
            let timings = Self.makeTimings(frameIndex: frameIndex, samples: frame.resolve(),
                cpuStart: baseline.cpu, gpuStart: baseline.gpu, cpuEnd: final.cpu, gpuEnd: final.gpu,
                commandStart: completed.gpuStartTime, commandEnd: completed.gpuEndTime)
            guard let self else { return }
            self.lock.lock()
            if self.latestValue == nil || frameIndex >= self.latestValue!.sampleFrameIndex {
                self.latestValue = timings
            }
            self.lock.unlock()
        }
        return frame
    }

    /// Difference-first UInt64 arithmetic avoids losing short durations in large uptime values.
    static func makeTimings(frameIndex: UInt64, samples: [UInt64?], cpuStart: UInt64, gpuStart: UInt64,
                            cpuEnd: UInt64, gpuEnd: UInt64, commandStart: Double, commandEnd: Double) -> Timings {
        let scale: Double? = cpuEnd > cpuStart && gpuEnd > gpuStart
            ? Double(cpuEnd - cpuStart) / Double(gpuEnd - gpuStart) / 1_000_000 : nil
        func duration(_ start: Boundary, _ end: Boundary) -> Double? {
            guard let scale, scale.isFinite, scale > 0,
                  samples.indices.contains(start.rawValue), samples.indices.contains(end.rawValue),
                  let a = samples[start.rawValue], let b = samples[end.rawValue],
                  a != 0, b != 0, a != UInt64.max, b != UInt64.max, b >= a else { return nil }
            let result = Double(b - a) * scale
            return result.isFinite && result >= 0 ? result : nil
        }
        let whole = commandStart.isFinite && commandEnd.isFinite && commandStart > 0 && commandEnd >= commandStart
            ? (commandEnd - commandStart) * 1000 : nil
        // Legacy/compatible frames have no separate native surface pass. A recorded but
        // invalid surface timestamp stays invalid rather than inflating denoising time.
        let surfaceIndex = Boundary.surfaceStart.rawValue
        let denoiseEnd: Boundary = samples.indices.contains(surfaceIndex) && samples[surfaceIndex] != nil
            ? .surfaceStart : .mediaStart
        return .init(sampleFrameIndex: frameIndex,
            accelerationMS: duration(.accelerationStart, .pathStart),
            pathMS: duration(.pathStart, .pathEnd), denoiseMS: duration(.pathEnd, denoiseEnd),
            surfaceMS: duration(.surfaceStart, .surfaceEnd),
            mediaMS: duration(.mediaStart, .mediaEnd), wholeCommandMS: whole)
    }
}
