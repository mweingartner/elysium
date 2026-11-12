import Foundation

/// What one frame cost, as the app loop measured it. Times are milliseconds.
struct FrameTimingSample: Equatable {
    /// Host time (seconds) at which the frame's draw call started.
    var startTime: Double
    /// Time since the previous frame's draw call started: what the player sees as frame rate.
    var intervalMs: Double
    /// Main-thread work from the start of the draw call to the command buffer's commit, without
    /// `drawableWaitMs`.
    var cpuMs: Double
    /// Time the draw call spent blocked waiting for a free drawable: the GPU or the display is
    /// the limit when this is large, the main thread when it is near zero.
    var drawableWaitMs: Double
    /// Part of `cpuMs` spent advancing the game (`GameCore.frame`).
    var simulationMs: Double
    /// Part of `cpuMs` spent preparing and encoding the world (`WorldRenderer.render`).
    var worldMs: Double
    /// Part of `cpuMs` spent on the first-person view, the HUD and the open screen.
    var interfaceMs: Double
    /// GPU execution time of the frame's command buffer; nil until the GPU reports it.
    var gpuMs: Double?
}

/// Distribution of one measured quantity over a window of frames.
struct FrameTimingDistribution: Equatable {
    /// The tenth percentile: close to what the quantity costs when nothing else competes for the
    /// CPU or GPU, which is what to compare between builds on a busy machine.
    var p10 = 0.0
    var median = 0.0
    var p95 = 0.0
    var p99 = 0.0
    var maximum = 0.0

    /// Nearest-rank percentiles; an empty input yields zeros.
    init(_ values: [Double]) {
        guard !values.isEmpty else { return }
        let sorted = values.sorted()
        func rank(_ fraction: Double) -> Double {
            let index = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
            return sorted[min(sorted.count - 1, max(0, index))]
        }
        p10 = rank(0.1)
        median = rank(0.5)
        p95 = rank(0.95)
        p99 = rank(0.99)
        maximum = sorted[sorted.count - 1]
    }
}

/// Frame-rate figures for the trailing window of frames.
struct FrameTimingSummary: Equatable {
    var frames = 0
    var seconds = 0.0
    /// Frames divided by the time they took.
    var averageFPS = 0.0
    /// Frame rate of the slowest one percent of frames (at least one frame), the usual "1% low".
    var onePercentLowFPS = 0.0
    /// Share of frames (0...1) that took longer than a 60 fps frame, and than a 30 fps frame.
    var shareOver60FPSFrame = 0.0
    var shareOver30FPSFrame = 0.0
    var interval = FrameTimingDistribution([])
    var cpu = FrameTimingDistribution([])
    var drawableWait = FrameTimingDistribution([])
    var simulation = FrameTimingDistribution([])
    var world = FrameTimingDistribution([])
    var interface = FrameTimingDistribution([])
    /// Only frames whose GPU time has been reported.
    var gpu = FrameTimingDistribution([])
    var gpuFrames = 0
    /// The slowest frames of the window, slowest first, for seeing what a stutter was made of.
    var slowest: [FrameTimingSample] = []

    /// One line for the F3 overlay, or nil before any world frame was drawn. Medians, so one
    /// hitch does not move them; the 1% low is where a hitch shows.
    var overlayLine: String? {
        guard frames > 0 else { return nil }
        func ms(_ value: Double) -> String { String(format: "%.1f", value) }
        let gpuText = gpuFrames > 0 ? ", GPU \(ms(gpu.median)) ms" : ""
        return "Frames: 1% low \(Int(onePercentLowFPS.rounded())) fps, CPU \(ms(cpu.median)) ms "
            + "(sim \(ms(simulation.median)) world \(ms(world.median)) UI \(ms(interface.median)))" + gpuText
    }
}

/// Keeps the most recent frames in a fixed ring. The draw loop records on the main thread; the
/// GPU time of a frame arrives later on Metal's completion thread, hence the lock.
final class FrameTimingRecorder {
    static let capacity = 16_384

    private let lock = NSLock()
    private var ring = [FrameTimingSample?](repeating: nil, count: FrameTimingRecorder.capacity)
    private var sequences = [UInt64](repeating: 0, count: FrameTimingRecorder.capacity)
    private var nextSequence: UInt64 = 1

    /// Opens a frame and returns the ticket under which its costs are added. The GPU time can
    /// arrive before or after `end`, so the frame exists from here on.
    func begin(startTime: Double, intervalMs: Double) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        let sequence = nextSequence
        nextSequence &+= 1
        let slot = Int(sequence % UInt64(Self.capacity))
        ring[slot] = FrameTimingSample(startTime: startTime, intervalMs: intervalMs, cpuMs: 0,
                                       drawableWaitMs: 0, simulationMs: 0, worldMs: 0, interfaceMs: 0,
                                       gpuMs: nil)
        sequences[slot] = sequence
        return sequence
    }

    /// Adds the main-thread costs to an open frame. A frame the ring has already replaced is ignored.
    func end(sequence: UInt64, cpuMs: Double, drawableWaitMs: Double, simulationMs: Double,
             worldMs: Double, interfaceMs: Double) {
        lock.lock(); defer { lock.unlock() }
        let slot = Int(sequence % UInt64(Self.capacity))
        guard sequences[slot] == sequence else { return }
        ring[slot]?.cpuMs = cpuMs
        ring[slot]?.drawableWaitMs = drawableWaitMs
        ring[slot]?.simulationMs = simulationMs
        ring[slot]?.worldMs = worldMs
        ring[slot]?.interfaceMs = interfaceMs
    }

    /// Adds the GPU time to a recorded frame. A frame the ring has already replaced is ignored.
    func recordGPU(sequence: UInt64, milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.lock(); defer { lock.unlock() }
        let slot = Int(sequence % UInt64(Self.capacity))
        guard sequences[slot] == sequence else { return }
        ring[slot]?.gpuMs = milliseconds
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        ring = [FrameTimingSample?](repeating: nil, count: Self.capacity)
        sequences = [UInt64](repeating: 0, count: Self.capacity)
    }

    /// Frames whose draw call started within `seconds` before `now`, oldest first.
    func samples(trailing seconds: Double, now: Double) -> [FrameTimingSample] {
        lock.lock(); defer { lock.unlock() }
        var result: [FrameTimingSample] = []
        var sequence = nextSequence &- 1
        while sequence >= 1, result.count < Self.capacity {
            let slot = Int(sequence % UInt64(Self.capacity))
            guard sequences[slot] == sequence, let sample = ring[slot],
                  now - sample.startTime <= seconds else { break }
            result.append(sample)
            sequence &-= 1
        }
        return result.reversed()
    }

    func summary(trailing seconds: Double, now: Double) -> FrameTimingSummary {
        Self.summarize(samples(trailing: seconds, now: now))
    }

    static let slowestFrames = 8

    static func summarize(_ samples: [FrameTimingSample]) -> FrameTimingSummary {
        var summary = FrameTimingSummary()
        guard !samples.isEmpty else { return summary }
        let intervals = samples.map(\.intervalMs)
        let total = intervals.reduce(0, +)
        summary.frames = samples.count
        summary.seconds = total / 1000
        summary.averageFPS = total > 0 ? Double(samples.count) * 1000 / total : 0
        let slowestCount = max(1, samples.count / 100)
        let slowest = intervals.sorted(by: >).prefix(slowestCount)
        let slowestMean = slowest.reduce(0, +) / Double(slowestCount)
        summary.onePercentLowFPS = slowestMean > 0 ? 1000 / slowestMean : 0
        summary.shareOver60FPSFrame = Double(intervals.filter { $0 > 1000.0 / 60 }.count) / Double(samples.count)
        summary.shareOver30FPSFrame = Double(intervals.filter { $0 > 1000.0 / 30 }.count) / Double(samples.count)
        summary.interval = FrameTimingDistribution(intervals)
        summary.cpu = FrameTimingDistribution(samples.map(\.cpuMs))
        summary.drawableWait = FrameTimingDistribution(samples.map(\.drawableWaitMs))
        summary.simulation = FrameTimingDistribution(samples.map(\.simulationMs))
        summary.world = FrameTimingDistribution(samples.map(\.worldMs))
        summary.interface = FrameTimingDistribution(samples.map(\.interfaceMs))
        let gpu = samples.compactMap(\.gpuMs)
        summary.gpu = FrameTimingDistribution(gpu)
        summary.gpuFrames = gpu.count
        summary.slowest = Array(samples.sorted { $0.intervalMs > $1.intervalMs }.prefix(slowestFrames))
        return summary
    }
}
