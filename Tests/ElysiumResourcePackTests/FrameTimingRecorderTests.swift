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
        XCTAssertEqual(summary.shareOver60FPSFrame, 0.01, accuracy: 1e-12, "two of 200 frames ran over 16.7 ms")
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
        let slow = FrameTimingRecorder.summarize([16.6, 16.7, 33.3, 33.4].map {
            FrameTimingSample(startTime: 0, intervalMs: $0, cpuMs: 1, drawableWaitMs: 0, simulationMs: 0,
                              worldMs: 0, interfaceMs: 0, gpuMs: nil)
        })
        XCTAssertEqual(slow.shareOver60FPSFrame, 0.75, "16.7 ms is over a 60 fps frame, 16.6 is not")
        XCTAssertEqual(slow.shareOver30FPSFrame, 0.25)
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
