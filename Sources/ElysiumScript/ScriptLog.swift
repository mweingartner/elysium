// ScriptLog.swift — task 3.3. design.md Decision 17 (provisional): where `print` lines
// land. The shim already enforces the shape (<= `logLineBytes` bytes, <=
// `logLinesPerSlice` lines per slice, "print budget exceeded" past that — design.md
// Condition 33); this protocol is purely the host-side sink.

/// Receives one already-capped, already hygiene-filtered `print` line (or a
/// state-level diagnostic, `envId == 0`, from the otherwise-unreachable panic handler —
/// design.md Decision 4 Rule 4). `line` is decoded with repair from the shim's raw
/// bytes (design.md Condition 26: never `String(cString:)`, truncated on a scalar
/// boundary), so it is always a valid (if possibly repaired) Swift `String`.
public protocol ScriptLogSink {
    func log(envId: UInt64, line: String)
}
