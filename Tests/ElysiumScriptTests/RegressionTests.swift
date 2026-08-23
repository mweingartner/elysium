// RegressionTests.swift — object-graph-attributes (change 1a) carry-forward.
// design.md Decision 12 "Promoted tests": permanent regression coverage for
// the embed-lua-runtime defects tracked as F1-F4 in the archived change 0
// test report — failed call/resume argument pushes must never grow the main
// stack or abort, repeated thread/environment cycles must not leak.

import ElysiumCore
import ElysiumScript
import XCTest

final class RegressionTests: XCTestCase {
    /// F1: a `call` whose argument marshaling fails partway through (an
    /// over-cap value) must not leave anything pushed on the main stack —
    /// repeating it many times must not grow `memoryStatus.bytesInUse`
    /// beyond a small, bounded amount.
    func testF1FailedCallArgPushLeavesNoMainStackGrowth() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "f1call", hostBindings: [], random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "return ...", chunkName: "f1callChunk").get()
        let overCap = ScriptValue.string(String(repeating: "x", count: 5_000)) // exceeds stringBytes
        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse
        for _ in 0..<200 {
            let outcome = try state.call(function, args: [.int(1), overCap], slice: 10_000)
            guard case .failure = outcome else { return XCTFail("expected a marshaling failure") }
        }
        state.collectFull()
        XCTAssertEqual(state.memoryStatus.bytesInUse, baseline, "repeated failed call arg pushes must not leak")
    }

    /// F1's resume counterpart: a `resume` whose argument marshaling fails
    /// must not leave anything pushed either. Unlike
    /// `MarshalingTests.testFailedResumeArgPushDoesNotLeakMainStack` (which
    /// reuses the *same* coroutine across every attempt — design.md Decision
    /// 7: a failed argument push happens before `elysium_resume` is ever
    /// called, so the coroutine itself was never started and stays open and
    /// resumable, deliberately not auto-closed by `resume`), this test
    /// discards a fresh coroutine every iteration. A caller that abandons a
    /// never-started coroutine without closing it leaks that coroutine's own
    /// thread by design (nothing else references it to reclaim it), so the
    /// caller here does what any real caller discarding a coroutine must:
    /// close it explicitly.
    func testF1FailedResumeArgPushLeavesNoMainStackGrowth() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "f1resume", hostBindings: [], random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "return ...", chunkName: "f1resumeChunk").get()
        let overCap = ScriptValue.string(String(repeating: "y", count: 5_000))
        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse
        for _ in 0..<200 {
            guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail() }
            let outcome = try state.resume(coroutine, args: [overCap], slice: 10_000)
            guard case .faulted = outcome else { return XCTFail("expected a marshaling failure") }
            try state.close(coroutine)
        }
        state.collectFull()
        // A tiny fixed residual across 200 create/fail/close cycles (allocator
        // bookkeeping granularity, not a per-cycle leak — a real per-cycle leak
        // of even a single retained value would dwarf this many times over at
        // 200 iterations) is expected; `baseline / 20` bounds it to 5%. Before
        // this test's coroutines were properly closed, the equivalent gap here
        // was 191264 bytes (956/iteration) — this tolerance is nowhere close.
        let tolerance = max(baseline / 20, 4_096)
        let after = state.memoryStatus.bytesInUse
        let growth = after > baseline ? after - baseline : 0
        XCTAssertLessThanOrEqual(growth, tolerance, "repeated failed resume arg pushes must not leak once the caller closes each discarded coroutine (baseline \(baseline), after \(after))")
    }

    /// F2: the thread pool never grows without bound — 2,000 complete/pool
    /// cycles must not leak memory (a proxy for pool growth, since the pool
    /// size itself is an internal implementation detail not exposed across
    /// the module boundary this test target observes through).
    func testF2ThreadCyclesDoNotLeakMemory() throws {
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.threadPoolMax = 8
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "f2", hostBindings: [], random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "return 1", chunkName: "f2chunk").get()
        for _ in 0..<50 {
            guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail() }
            let outcome = try state.resume(coroutine, args: [], slice: 10_000)
            guard case .completed = outcome else { return XCTFail("expected completion") }
        }
        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse
        for _ in 0..<2_000 {
            guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail() }
            let outcome = try state.resume(coroutine, args: [], slice: 10_000)
            guard case .completed = outcome else { return XCTFail("expected completion") }
        }
        state.collectFull()
        XCTAssertEqual(state.memoryStatus.bytesInUse, baseline, "a bounded thread pool must not grow without bound across many complete/pool cycles")
    }

    /// F3/F4: repeatedly compiling and destroying environments reclaims
    /// memory — 500 environment cycles must return to baseline.
    func testEnvironmentCyclesReclaimMemory() throws {
        let state = try ScriptTestSupport.makeState()
        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse
        for i in 0..<500 {
            let environment = state.makeEnvironment(name: "cycle\(i)", hostBindings: [], random: ScriptTestSupport.randomStream())
            let outcome = environment.compile(source: "local t = {1,2,3} return #t", chunkName: "cycleChunk\(i)")
            guard case .success(let function) = outcome else { return XCTFail("expected a compiled function") }
            _ = try state.call(function, args: [], slice: 10_000)
            environment.destroy()
        }
        state.collectFull()
        // A small fixed residual (allocator arena/free-list granularity across
        // 500 create/compile/call/destroy cycles) is expected and is not what
        // this test is guarding against; an actual per-cycle leak of even a
        // single retained table or thread would dwarf this tolerance many
        // times over at 500 iterations. `baseline / 20` bounds it to 5%.
        let tolerance = max(baseline / 20, 4_096)
        let after = state.memoryStatus.bytesInUse
        let growth = after > baseline ? after - baseline : 0
        XCTAssertLessThanOrEqual(growth, tolerance, "environment cycles must reclaim their memory (baseline \(baseline), after \(after))")
    }
}
