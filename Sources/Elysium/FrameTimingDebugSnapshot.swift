#if ELYSIUM_DEBUG_CONTROL
import Foundation
import ElysiumDebugProtocol

extension FrameTimingRecorder {
    /// Frame-rate evidence for the `renderer` snapshot scope: the trailing 10 and 30 seconds of
    /// world frames, each with its distributions and its slowest frames.
    func debugSnapshotValue(now: Double) -> JSONValue {
        func distribution(_ value: FrameTimingDistribution) -> JSONValue {
            .object(["p10": .number(value.p10), "median": .number(value.median), "p95": .number(value.p95),
                     "p99": .number(value.p99), "maximum": .number(value.maximum)])
        }
        func frame(_ frame: FrameTimingSample) -> JSONValue {
            .object([
                "secondsAgo": .number(now - frame.startTime),
                "intervalMilliseconds": .number(frame.intervalMs),
                "cpuMilliseconds": .number(frame.cpuMs),
                "drawableWaitMilliseconds": .number(frame.drawableWaitMs),
                "simulationMilliseconds": .number(frame.simulationMs),
                "worldMilliseconds": .number(frame.worldMs),
                "interfaceMilliseconds": .number(frame.interfaceMs),
                "gpuMilliseconds": frame.gpuMs.map { .number($0) } ?? .null,
            ])
        }
        func window(_ seconds: Double) -> JSONValue {
            let summary = summary(trailing: seconds, now: now)
            return .object([
                "frames": .integer(Int64(summary.frames)), "seconds": .number(summary.seconds),
                "averageFPS": .number(summary.averageFPS),
                "onePercentLowFPS": .number(summary.onePercentLowFPS),
                "shareOver60FPSFrame": .number(summary.shareOver60FPSFrame),
                "shareOver30FPSFrame": .number(summary.shareOver30FPSFrame),
                "intervalMilliseconds": distribution(summary.interval),
                "cpuMilliseconds": distribution(summary.cpu),
                "drawableWaitMilliseconds": distribution(summary.drawableWait),
                "simulationMilliseconds": distribution(summary.simulation),
                "worldMilliseconds": distribution(summary.world),
                "interfaceMilliseconds": distribution(summary.interface),
                "gpuMilliseconds": distribution(summary.gpu),
                "gpuFrames": .integer(Int64(summary.gpuFrames)),
                "slowestFrames": .array(summary.slowest.map(frame)),
            ])
        }
        return .object(["trailing10Seconds": window(10), "trailing30Seconds": window(30)])
    }
}
#endif
