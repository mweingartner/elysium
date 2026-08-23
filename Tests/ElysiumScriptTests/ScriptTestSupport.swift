// ScriptTestSupport.swift — task 6.1's shared state factory (Lane C writes it now so
// its own smoke tests, in `LuaStateSmokeTests.swift`, have something to build on; Lane
// E's exhaustive suites reuse it). Not a `Tests/.../*Fixtures` file and not part of the
// release surface — this is ordinary test-target code, so the release-surface denylist
// (`_test`, `testSet`, ...) does not apply here, but the names below avoid it anyway.

import ElysiumCore
import ElysiumScript
import XCTest

/// Captures every line handed to the sink (`print`, and envId 0 diagnostics from the
/// otherwise-unreachable panic handler) in call order, for content assertions.
final class RecordingLogSink: ScriptLogSink {
    private(set) var lines: [(envId: UInt64, line: String)] = []
    func log(envId: UInt64, line: String) {
        lines.append((envId, line))
    }
}

enum ScriptTestSupport {
    /// A fresh, closeable state using the shipped deterministic math
    /// (`ScriptHostMath.deterministic`, `ElysiumCore/Scripting/ScriptHostBindings.swift`)
    /// so every trig/exp/log/pow value a test observes is bit-for-bit what the real app
    /// would compute.
    static func makeState(
        budgets: ScriptBudgets = .defaults, log: ScriptLogSink = RecordingLogSink()
    ) throws -> LuaState {
        try LuaState(budgets: budgets, math: ScriptHostMath.deterministic, log: log)
    }

    /// Small caps so instruction/memory/allocation trip tests run in milliseconds
    /// without a hand-tuned corpus per test (task 6.1: "small caps for trip tests").
    static var tinyBudgets: ScriptBudgets {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 1_000
        budgets.handlerTotalInstructions = 5_000
        budgets.memoryCapBytes = 128 * 1024
        budgets.hostOverCapDiagnosticBytes = 32 * 1024
        budgets.allocationRatePerSliceBytes = 64 * 1024
        budgets.threadPoolMax = 8
        return budgets
    }

    /// A deterministic random stream for `makeEnvironment(random:)` — a plain `RandomX`
    /// seed (ElysiumCore), which `ScriptHostBindings.swift` already conforms to
    /// `ScriptRandomStream`.
    static func randomStream(seed: UInt32 = 1) -> RandomX { RandomX(seed) }

    /// Compiles `source` in a fresh environment on `state` and unwraps the result,
    /// failing the calling test on a compile fault (the tiny corpus runner task 6.1
    /// asks for — most smoke tests just need "compile this, run it").
    @discardableResult
    static func run(
        _ source: String, chunkName: String = "corpus", on state: LuaState,
        hostBindings: [HostBinding] = [], random: any ScriptRandomStream = RandomX(1),
        slice: Int = 1_000_000
    ) throws -> ScriptCallOutcome {
        let environment = state.makeEnvironment(name: "corpus", hostBindings: hostBindings, random: random)
        let function = try environment.compile(source: source, chunkName: chunkName).get()
        return try state.call(function, args: [], slice: slice)
    }
}
