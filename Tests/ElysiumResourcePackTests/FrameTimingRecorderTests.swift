import Foundation
import XCTest
@testable import Elysium

/// The frame-rate evidence the debug-control snapshot reports: averages, 1% lows and the
/// main-thread/GPU split must be computed the way the documentation says.
final class FrameTimingRecorderTests: XCTestCase {
    private func frame(_ recorder: FrameTimingRecorder, at time: Double, interval: Double,
                       cpu: Double = 2, wait: Double = 0, simulation: Double = 0.5, world: Double = 1,
                       interface: Double = 0.5, gpu: Double? = 4) {
        let ticket = recorder.begin(startTime: time, intervalMs: interval)
        recorder.end(sequence: ticket, cpuMs: cpu, drawableWaitMs: wait, simulationMs: simulation,
                     worldMs: world, interfaceMs: interface)
        if let gpu { recorder.recordGPU(sequence: ticket, milliseconds: gpu) }
    }

    func testAverageAndOnePercentLowComeFromFrameIntervals() {
        let recorder = FrameTimingRecorder()
        // 198 frames of 10 ms and two stutters of 50 ms: 2.08 s, 200 frames.
        var time = 0.0
        for index in 0..<200 {
            let interval = index == 50 || index == 150 ? 50.0 : 10.0
            time += interval / 1000
            frame(recorder, at: time, interval: interval)
        }
        let summary = recorder.summary(trailing: 30, now: time)
        XCTAssertEqual(summary.frames, 200)
        XCTAssertEqual(summary.seconds, 2.08, accuracy: 1e-9)
        XCTAssertEqual(summary.averageFPS, 200 / 2.08, accuracy: 1e-9)
        // The slowest 1% of 200 frames is two frames, both 50 ms: 20 fps.
        XCTAssertEqual(summary.onePercentLowFPS, 20, accuracy: 1e-9)
        XCTAssertEqual(summary.shareOver60FPSFrame, 0.01, accuracy: 1e-12, "two of 200 frames ran over 17.5 ms")
        XCTAssertEqual(summary.shareOver30FPSFrame, 0.01, accuracy: 1e-12)
        XCTAssertEqual(summary.interval.p10, 10)
        XCTAssertEqual(summary.interval.median, 10)
        XCTAssertEqual(summary.interval.p95, 10)
        XCTAssertEqual(summary.interval.p99, 10, "nearest rank: the 198th of 200 sorted frames is the last 10 ms one")
        XCTAssertEqual(summary.interval.maximum, 50)
        XCTAssertEqual(summary.slowest.count, FrameTimingRecorder.slowestFrames)
        XCTAssertEqual(summary.slowest.prefix(2).map(\.intervalMs), [50, 50])
        XCTAssertEqual(summary.gpuFrames, 200)
        XCTAssertEqual(summary.gpu.median, 4)
    }

    func testFewFramesStillYieldAOneFrameLow() {
        let recorder = FrameTimingRecorder()
        frame(recorder, at: 0.010, interval: 10)
        frame(recorder, at: 0.030, interval: 20)
        frame(recorder, at: 0.040, interval: 10)
        let summary = recorder.summary(trailing: 10, now: 0.040)
        XCTAssertEqual(summary.frames, 3)
        XCTAssertEqual(summary.onePercentLowFPS, 50, accuracy: 1e-9, "under 100 frames the slowest single frame is the low")
        XCTAssertEqual(summary.averageFPS, 75, accuracy: 1e-9)
    }

    func testPercentilesUseNearestRank() {
        let distribution = FrameTimingDistribution((1...100).map(Double.init).shuffled())
        XCTAssertEqual(distribution.p10, 10)
        XCTAssertEqual(distribution.median, 50)
        XCTAssertEqual(distribution.p95, 95)
        XCTAssertEqual(distribution.p99, 99)
        XCTAssertEqual(distribution.maximum, 100)
        let single = FrameTimingDistribution([7])
        XCTAssertEqual([single.p10, single.median, single.p99, single.maximum], [7, 7, 7, 7])
        // 60 Hz vsync jitter (16.6 to 16.9 ms) is on time; 17.6 ms and 35.1 ms are not.
        let slow = FrameTimingRecorder.summarize([16.6, 16.9, 17.5, 17.6, 33.4, 35.0, 35.1, 50].map {
            FrameTimingSample(startTime: 0, intervalMs: $0, cpuMs: 1, drawableWaitMs: 0, simulationMs: 0,
                              worldMs: 0, interfaceMs: 0, gpuMs: nil)
        })
        XCTAssertEqual(slow.shareOver60FPSFrame, 5.0 / 8, "17.6, 33.4, 35.0, 35.1 and 50 ms")
        XCTAssertEqual(slow.shareOver30FPSFrame, 2.0 / 8, "35.1 and 50 ms")
    }

    func testOverlayLineReportsMediansAndOmitsWhatIsNotMeasured() {
        XCTAssertNil(FrameTimingSummary().overlayLine, "no world frame, no line")
        let recorder = FrameTimingRecorder()
        for index in 0..<120 {
            frame(recorder, at: Double(index) / 120, interval: 1000.0 / 120, cpu: 3.64, simulation: 0.02,
                  world: 3.3, interface: 0.11, gpu: 5.79)
        }
        XCTAssertEqual(recorder.summary(trailing: 10, now: 1).overlayLine,
                       "Frames: 1% low 120 fps, CPU 3.6 ms (sim 0.0 world 3.3 UI 0.1), GPU 5.8 ms")
        let unreported = FrameTimingRecorder()
        frame(unreported, at: 1, interval: 20, cpu: 4, simulation: 1, world: 2, interface: 1, gpu: nil)
        XCTAssertEqual(unreported.summary(trailing: 10, now: 1).overlayLine,
                       "Frames: 1% low 50 fps, CPU 4.0 ms (sim 1.0 world 2.0 UI 1.0)")
    }

    func testAPauseInDrawingIsReportedOnceAndIsNotAFrame() {
        let recorder = FrameTimingRecorder()
        XCTAssertFalse(recorder.takeInterruption(), "nothing stopped yet")
        frame(recorder, at: 1, interval: 8)
        // The app sat in the background for 20 s; the display link kept calling.
        for _ in 0..<2_400 { recorder.noteInterruption() }
        XCTAssertTrue(recorder.takeInterruption(), "the draw loop leaves the resuming frame out")
        XCTAssertFalse(recorder.takeInterruption(), "and records again from the next one")
        frame(recorder, at: 21.008, interval: 8)
        let summary = recorder.summary(trailing: 30, now: 21.008)
        XCTAssertEqual(summary.frames, 2)
        XCTAssertEqual(summary.interval.maximum, 8, "the 20 s pause is not anybody's frame time")
        XCTAssertEqual(summary.onePercentLowFPS, 125, accuracy: 1e-9)
    }

    func testEmptyWindowIsAllZerosAndNeverDivides() {
        let recorder = FrameTimingRecorder()
        XCTAssertEqual(recorder.summary(trailing: 10, now: 100), FrameTimingSummary())
        frame(recorder, at: 1, interval: 8)
        XCTAssertEqual(recorder.summary(trailing: 10, now: 100).frames, 0, "a frame older than the window is not in it")
        XCTAssertEqual(FrameTimingDistribution([]), FrameTimingDistribution([]))
        XCTAssertEqual(FrameTimingDistribution([]).maximum, 0)
    }

    func testWindowTakesOnlyTheTrailingSecondsInOrder() {
        let recorder = FrameTimingRecorder()
        for index in 1...100 { frame(recorder, at: Double(index), interval: Double(index)) }
        let samples = recorder.samples(trailing: 10, now: 100)
        XCTAssertEqual(samples.map(\.intervalMs), (90...100).map(Double.init), "oldest first, the boundary frame included")
    }

    func testRingKeepsTheNewestFramesAndIgnoresLateCostsForReplacedOnes() {
        let recorder = FrameTimingRecorder()
        let first = recorder.begin(startTime: 0, intervalMs: 1)
        let total = FrameTimingRecorder.capacity + 10
        for index in 1..<total {
            frame(recorder, at: Double(index) * 0.001, interval: 1, gpu: nil)
        }
        // The first frame's slot now belongs to a later frame: its late costs must not land there.
        recorder.end(sequence: first, cpuMs: 999, drawableWaitMs: 999, simulationMs: 999, worldMs: 999, interfaceMs: 999)
        recorder.recordGPU(sequence: first, milliseconds: 999)
        let samples = recorder.samples(trailing: 1_000, now: Double(total) * 0.001)
        XCTAssertEqual(samples.count, FrameTimingRecorder.capacity)
        XCTAssertFalse(samples.contains { $0.cpuMs == 999 || $0.gpuMs == 999 })
        XCTAssertEqual(samples.first?.startTime ?? -1, Double(total - FrameTimingRecorder.capacity) * 0.001, accuracy: 1e-9)
    }

    func testGPUTimeMayArriveBeforeOrAfterTheFrameEndsAndBadValuesAreDropped() {
        let recorder = FrameTimingRecorder()
        let early = recorder.begin(startTime: 1, intervalMs: 8)
        recorder.recordGPU(sequence: early, milliseconds: 6)
        recorder.end(sequence: early, cpuMs: 3, drawableWaitMs: 1, simulationMs: 1, worldMs: 1, interfaceMs: 1)
        let late = recorder.begin(startTime: 1.008, intervalMs: 8)
        recorder.end(sequence: late, cpuMs: 3, drawableWaitMs: 1, simulationMs: 1, worldMs: 1, interfaceMs: 1)
        recorder.recordGPU(sequence: late, milliseconds: 7)
        let pending = recorder.begin(startTime: 1.016, intervalMs: 8)
        recorder.recordGPU(sequence: pending, milliseconds: .nan)
        recorder.recordGPU(sequence: pending, milliseconds: -1)
        recorder.recordGPU(sequence: pending, milliseconds: .infinity)
        let samples = recorder.samples(trailing: 10, now: 1.016)
        XCTAssertEqual(samples.map(\.gpuMs), [6, 7, nil])
        XCTAssertEqual(samples[0].cpuMs, 3)
        let summary = recorder.summary(trailing: 10, now: 1.016)
        XCTAssertEqual(summary.gpuFrames, 2, "frames the GPU has not reported are left out of the GPU figures")
        XCTAssertEqual(summary.drawableWait.maximum, 1)
    }

    func testResetForgetsEarlierFrames() {
        let recorder = FrameTimingRecorder()
        frame(recorder, at: 1, interval: 8)
        recorder.reset()
        XCTAssertEqual(recorder.summary(trailing: 10, now: 1).frames, 0)
        frame(recorder, at: 2, interval: 8)
        XCTAssertEqual(recorder.summary(trailing: 10, now: 2).frames, 1)
    }

    // MARK: - Independent review

    /// Every figure of `summarize` against an independent computation: nearest rank in integer
    /// arithmetic (ceil(p * n) without floating point), the 1% low as the mean of the slowest
    /// max(1, n / 100) intervals, and shares counted above 17.5 and 35 ms (a frame of exactly
    /// 1000/60 ms, which the generator produces, is on time).
    func testSummaryMatchesAnIndependentComputationOverRandomWindows() {
        var seed: UInt64 = 0xF4A3_17E5
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        func rank(_ sorted: [Double], _ numerator: Int, _ denominator: Int) -> Double {
            let n = sorted.count
            return sorted[max(0, (numerator * n + denominator - 1) / denominator - 1)]
        }
        var stutterWindows = 0, partialGPUWindows = 0
        for round in 0..<300 {
            let n = 1 + Int(next() * Double([5, 120, 1_500][round % 3]))
            let samples: [FrameTimingSample] = (0..<n).map { index in
                let stutter = next() < 0.03
                // Quantized values make ties, the case where rank arithmetic goes wrong first.
                let interval = stutter ? 20 + (next() * 200).rounded() : 1000.0 / [60, 120, 144][Int(next() * 3)]
                return FrameTimingSample(startTime: Double(index), intervalMs: interval,
                    cpuMs: (next() * 40).rounded() / 4, drawableWaitMs: next() * 3, simulationMs: next(),
                    worldMs: next() * 5, interfaceMs: next(), gpuMs: next() < 0.2 ? nil : next() * 9)
            }
            let summary = FrameTimingRecorder.summarize(samples)
            let intervals = samples.map(\.intervalMs), sorted = intervals.sorted()
            XCTAssertEqual(summary.frames, n)
            let total = intervals.reduce(0, +)
            XCTAssertEqual(summary.seconds, total / 1000, accuracy: 1e-9)
            XCTAssertEqual(summary.averageFPS, Double(n) * 1000 / total, accuracy: 1e-9)
            let slowestCount = max(1, n / 100)
            let slowestMean = sorted.suffix(slowestCount).reduce(0, +) / Double(slowestCount)
            XCTAssertEqual(summary.onePercentLowFPS, 1000 / slowestMean, accuracy: 1e-9, "round \(round)")
            XCTAssertEqual(summary.shareOver60FPSFrame,
                           Double(intervals.filter { $0 > 17.5 }.count) / Double(n), accuracy: 1e-12)
            XCTAssertEqual(summary.shareOver30FPSFrame,
                           Double(intervals.filter { $0 > 35.0 }.count) / Double(n), accuracy: 1e-12)
            for (distribution, values) in [(summary.interval, intervals), (summary.cpu, samples.map(\.cpuMs)),
                                           (summary.drawableWait, samples.map(\.drawableWaitMs)),
                                           (summary.gpu, samples.compactMap(\.gpuMs))] {
                let sortedValues = values.sorted()
                guard !sortedValues.isEmpty else { XCTAssertEqual(distribution, FrameTimingDistribution([])); continue }
                XCTAssertEqual(distribution.p10, rank(sortedValues, 1, 10), "round \(round) n \(n)")
                XCTAssertEqual(distribution.median, rank(sortedValues, 1, 2), "round \(round) n \(n)")
                XCTAssertEqual(distribution.p95, rank(sortedValues, 95, 100), "round \(round) n \(n)")
                XCTAssertEqual(distribution.p99, rank(sortedValues, 99, 100), "round \(round) n \(n)")
                XCTAssertEqual(distribution.maximum, sortedValues.last)
            }
            XCTAssertEqual(summary.gpuFrames, samples.compactMap(\.gpuMs).count)
            XCTAssertEqual(summary.slowest.map(\.intervalMs), Array(sorted.reversed().prefix(FrameTimingRecorder.slowestFrames)))
            if summary.shareOver30FPSFrame > 0 { stutterWindows += 1 }
            if summary.gpuFrames < n { partialGPUWindows += 1 }
        }
        XCTAssertGreaterThan(stutterWindows, 100)
        XCTAssertGreaterThan(partialGPUWindows, 100)
    }

    /// Integer nearest rank and the floating-point rank must pick the same element for window
    /// sizes up to what the ring holds (every size to 2,400, then a stride to the capacity).
    func testNearestRankPicksTheSameElementAsIntegerArithmeticForEveryWindowSize() {
        let capacity = FrameTimingRecorder.capacity
        for n in Array(1...2_400) + Array(stride(from: 2_401, through: capacity, by: 97)) + [capacity - 1, capacity] {
            let values = (1...n).map(Double.init)
            let distribution = FrameTimingDistribution(values)
            func expected(_ numerator: Int, _ denominator: Int) -> Double { Double((numerator * n + denominator - 1) / denominator) }
            if distribution.p10 != expected(1, 10) || distribution.median != expected(1, 2)
                || distribution.p95 != expected(95, 100) || distribution.p99 != expected(99, 100) {
                XCTFail("nearest rank differs at n = \(n)"); break
            }
        }
    }

    func testResetHidesFramesFromBeforeItEvenAfterTheRingWrapped() {
        let recorder = FrameTimingRecorder()
        var stale: UInt64 = 0
        for index in 0..<(FrameTimingRecorder.capacity * 2 + 5) {
            stale = recorder.begin(startTime: Double(index) * 0.001, intervalMs: 1)
        }
        recorder.reset()
        XCTAssertTrue(recorder.samples(trailing: 1e9, now: 1e6).isEmpty)
        // A frame opened before the reset may still report; it must not reappear.
        recorder.end(sequence: stale, cpuMs: 9, drawableWaitMs: 9, simulationMs: 9, worldMs: 9, interfaceMs: 9)
        recorder.recordGPU(sequence: stale, milliseconds: 9)
        XCTAssertTrue(recorder.samples(trailing: 1e9, now: 1e6).isEmpty)
        for index in 0..<3 { frame(recorder, at: 100 + Double(index), interval: 8) }
        let after = recorder.samples(trailing: 1e9, now: 103)
        XCTAssertEqual(after.map(\.startTime), [100, 101, 102])
        XCTAssertFalse(after.contains { $0.cpuMs == 9 || $0.gpuMs == 9 })
    }

    func testOverlayRoundsTheLowToTheNearestWholeFrameRate() {
        let recorder = FrameTimingRecorder()
        // A 59.6 fps low shows as 60 and a 59.4 fps low as 59: rounded, not truncated.
        frame(recorder, at: 1, interval: 1000 / 59.6, cpu: 1, simulation: 0, world: 0, interface: 0, gpu: nil)
        XCTAssertEqual(recorder.summary(trailing: 10, now: 1).overlayLine?.hasPrefix("Frames: 1% low 60 fps,"), true)
        let other = FrameTimingRecorder()
        frame(other, at: 1, interval: 1000 / 59.4, cpu: 1, simulation: 0, world: 0, interface: 0, gpu: nil)
        XCTAssertEqual(other.summary(trailing: 10, now: 1).overlayLine?.hasPrefix("Frames: 1% low 59 fps,"), true)
    }

    func testGPUCompletionsFromAnotherThreadDoNotCorruptTheRing() {
        let recorder = FrameTimingRecorder()
        let frames = 4_000
        let done = expectation(description: "completions")
        var tickets: [UInt64] = []
        for index in 0..<frames {
            tickets.append(recorder.begin(startTime: Double(index) * 0.001, intervalMs: 1))
        }
        DispatchQueue.global().async {
            for ticket in tickets { recorder.recordGPU(sequence: ticket, milliseconds: 5) }
            done.fulfill()
        }
        for ticket in tickets {
            recorder.end(sequence: ticket, cpuMs: 2, drawableWaitMs: 0, simulationMs: 0, worldMs: 1, interfaceMs: 1)
        }
        wait(for: [done], timeout: 10)
        let summary = recorder.summary(trailing: 100, now: Double(frames) * 0.001)
        XCTAssertEqual(summary.frames, frames)
        XCTAssertEqual(summary.gpuFrames, frames)
        XCTAssertEqual(summary.cpu.median, 2)
        XCTAssertEqual(summary.gpu.maximum, 5)
    }
}
