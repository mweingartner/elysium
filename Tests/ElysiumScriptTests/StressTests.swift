// StressTests.swift — object-graph-attributes (change 1a) carry-forward, task 7.5:
// promotes the Tester's ephemeral change-0 stress suite. Where `RegressionTests.swift`
// checks the F1-F4 defects at a scale designed to *reveal* a leak, this file runs the
// same shapes at a scale designed to prove the runtime holds up under sustained load —
// thousands of coroutine cycles, deep call chains, and large value trees in one
// continuous run, bounded to stay well under 30 s at the default iteration count.

import ElysiumCore
import ElysiumScript
import XCTest

final class StressTests: XCTestCase {
    private static var scale: Int {
        if let raw = ProcessInfo.processInfo.environment["ELYSIUM_SCRIPT_FUZZ_ITERATIONS"],
            let n = Int(raw), n > 0 {
            return n
        }
        return 3_000
    }

    func testSustainedCoroutineCycleDoesNotDegradeOrLeak() throws {
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.threadPoolMax = 16
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "stress", hostBindings: [], random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "return select('#', ...)", chunkName: "stressChunk").get()

        // Warm the pool first (see BoundaryTests.testManyResumeArgumentsOnFreshCoroutineComplete's
        // comment: a pooled thread's stack high-water mark is retained by design, a
        // one-time cost that must not be charged against the sustained-load baseline).
        for _ in 0..<8 {
            guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail() }
            let outcome = try state.resume(coroutine, args: [.int(1), .int(2), .int(3)], slice: 10_000)
            guard case .completed = outcome else { return XCTFail() }
        }
        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse

        for _ in 0..<Self.scale {
            guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail() }
            let outcome = try state.resume(coroutine, args: [.int(1), .int(2), .int(3)], slice: 10_000)
            guard case .completed(let values) = outcome, values == [.int(3)] else {
                return XCTFail("stress cycle produced an unexpected outcome: \(outcome)")
            }
        }
        state.collectFull()
        let after = state.memoryStatus.bytesInUse
        let tolerance = max(baseline / 20, 4_096)
        let growth = after > baseline ? after - baseline : 0
        XCTAssertLessThanOrEqual(growth, tolerance, "\(Self.scale) coroutine cycles must not leak (baseline \(baseline), after \(after))")
        XCTAssertFalse(state.isDead)
    }

    func testSustainedCallLoopStaysWithinInstructionAndMemoryBudgets() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "stressCall", hostBindings: [], random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: "local t = {} for i = 1, 32 do t[i] = i * i end return #t", chunkName: "stressCallChunk"
        ).get()

        var completions = 0
        for _ in 0..<Self.scale {
            let outcome = try state.call(function, args: [], slice: 10_000)
            if case .success(let values) = outcome, values == [.int(32)] { completions += 1 }
        }
        XCTAssertEqual(completions, Self.scale)
        XCTAssertFalse(state.isDead)
    }

    /// A large, deeply-nested-but-in-cap value round-tripped many times in a row —
    /// the marshaling boundary's own sustained-load counterpart to
    /// `MarshalingPropertyTests`' single-shot property.
    func testSustainedLargeValueRoundTripsStayBounded() throws {
        let state = try ScriptTestSupport.makeState()
        let echo = HostFunction { call in
            .values(call.arguments.compactMap { arg -> ScriptValue? in
                if case .value(let v) = arg { return v }
                return nil
            })
        }
        let big = ScriptValue.list((0..<50).map { .map(["i": .int(Int64($0)), "s": .string("v\($0)")]) })
        let environment = state.makeEnvironment(
            name: "stressValue", hostBindings: [.function(name: "echo", echo)], random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(source: "return echo(...)", chunkName: "stressValueChunk").get()

        let cycles = min(Self.scale, 500) // this scenario is O(list size) per cycle; cap the wall-clock cost
        for i in 0..<cycles {
            let outcome = try state.call(function, args: [big], slice: 50_000)
            guard case .success(let values) = outcome, values.count == 1, values[0] == big else {
                return XCTFail("large-value round trip #\(i) changed the value or did not complete")
            }
        }
    }
}
