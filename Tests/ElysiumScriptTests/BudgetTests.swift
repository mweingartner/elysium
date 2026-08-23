// BudgetTests.swift — task 6.1/6.4/6.6. design.md Decision 6 (count hook, budgets,
// preemption) and the Risk-to-Test Map's "Preemption exactness" row: exact instruction
// accounting across preemption/resume, soft slices inside non-yieldable C regions, the
// hard coroutine-lifetime total, the C21 nested-entry amendments and the C35 top-level
// hard-slice amendment.

import ElysiumCore
import ElysiumScript
import XCTest

final class BudgetTests: XCTestCase {
    // MARK: - Preemption resumes at the same instruction (ordinal equality across two states)

    func testPreemptionResumesAtSameInstruction() throws {
        // spec "Preemption resumes at the same instruction": the same loop, run to
        // completion in two independently constructed states with identical budgets,
        // must preempt the same number of times and reach the same final value --
        // the "ordinal" (which iteration each preemption lands on) is a pure function
        // of the instruction stream, not of process/heap state.
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 5_000
        budgets.handlerTotalInstructions = 5_000_000

        func run() throws -> (result: ScriptValue?, preemptions: Int) {
            let state = try ScriptTestSupport.makeState(budgets: budgets)
            let environment = state.makeEnvironment(name: "sameInstr", random: ScriptTestSupport.randomStream())
            let function = try environment.compile(
                source: "local n = 0; for i = 1, 100000 do n = n + 1 end; return n", chunkName: "sameInstrChunk"
            ).get()
            guard let coroutine = try state.makeCoroutine(function: function) else {
                XCTFail("expected a coroutine"); return (nil, 0)
            }
            var completed: ScriptValue?
            var preemptions = 0
            while completed == nil {
                let outcome = try state.resume(coroutine, args: [], slice: budgets.handlerSliceInstructions)
                switch outcome {
                case .yielded(.preempted):
                    preemptions += 1
                    XCTAssertLessThan(preemptions, 1_000)
                case .yielded(let other):
                    XCTFail("unexpected yield \(other)")
                    return (nil, preemptions)
                case .faulted(let fault):
                    XCTFail("unexpected fault \(fault)")
                    return (nil, preemptions)
                case .completed(let values):
                    completed = values.first
                }
            }
            return (completed, preemptions)
        }

        let first = try run()
        let second = try run()
        XCTAssertEqual(first.result, .int(100_000))
        XCTAssertEqual(second.result, .int(100_000))
        XCTAssertEqual(first.preemptions, second.preemptions, "the number of preemptions (and therefore the instruction ordinal each one lands on) must be identical across two independently constructed states")
        XCTAssertGreaterThan(first.preemptions, 0, "the slice must actually have been exceeded at least once")
    }

    // MARK: - Non-yieldable preemption: sort comparator and gsub callback

    func testNonYieldableSortComparator() throws {
        // spec "Non-yieldable preemption": the slice exhausting inside a table.sort
        // comparator must not raise -- the sort completes, and the coroutine yields
        // .preempted only once back in a yieldable Lua frame.
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 4_000
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "sortComparator", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: """
                local t = {}
                for i = 1, 24 do t[i] = 25 - i end
                local function costly(a, b)
                    local x = 0
                    for i = 1, 3000 do x = x + 1 end
                    return a < b
                end
                table.sort(t, costly)
                local ok = true
                for i = 1, 24 do if t[i] ~= i then ok = false end end
                return ok
                """,
            chunkName: "sortComparatorChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        var completed: ScriptValue?
        var preemptions = 0
        var iterations = 0
        while completed == nil {
            iterations += 1
            XCTAssertLessThan(iterations, 10_000, "not making progress")
            let outcome = try state.resume(coroutine, args: [], slice: budgets.handlerSliceInstructions)
            switch outcome {
            case .yielded(.preempted):
                preemptions += 1
            case .yielded(let other):
                return XCTFail("unexpected yield \(other)")
            case .faulted(let fault):
                return XCTFail("the slice overrun inside the comparator must not raise, got \(fault)")
            case .completed(let values):
                completed = values.first
            }
        }
        XCTAssertEqual(completed, .bool(true), "the sort must have actually completed correctly despite the slice overrun inside its comparator")
        XCTAssertGreaterThan(preemptions, 0, "the comparator's own loop must have exceeded the slice at least once")
    }

    func testNonYieldableGsubCallback() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 4_000
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "gsubCallback", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: """
                local function costly(m)
                    local x = 0
                    for i = 1, 3000 do x = x + 1 end
                    return 'b'
                end
                local result = ('a'):rep(20):gsub('a', costly)
                -- Burn enough further real instructions that the preemption pending
                -- since the gsub call actually gets delivered as a .preempted yield
                -- (a hook fire only converts a pending preemption once it happens,
                -- and a script that finished immediately after gsub could complete
                -- before the hook ever fires again).
                local y = 0
                for i = 1, 4000 do y = y + 1 end
                return result
                """,
            chunkName: "gsubCallbackChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        var completed: ScriptValue?
        var preemptions = 0
        var iterations = 0
        while completed == nil {
            iterations += 1
            XCTAssertLessThan(iterations, 10_000, "not making progress")
            let outcome = try state.resume(coroutine, args: [], slice: budgets.handlerSliceInstructions)
            switch outcome {
            case .yielded(.preempted):
                preemptions += 1
            case .yielded(let other):
                return XCTFail("unexpected yield \(other)")
            case .faulted(let fault):
                return XCTFail("the slice overrun inside the gsub callback must not raise, got \(fault)")
            case .completed(let values):
                completed = values.first
            }
        }
        XCTAssertEqual(completed, .string(String(repeating: "b", count: 20)))
        XCTAssertGreaterThan(preemptions, 0, "the callback's own loop must have exceeded the slice at least once")
    }

    // MARK: - pcall loops cannot revive a total-cap fault

    func testPcallLoopFaultsAtTotal() throws {
        // spec "pcall cannot revive a budget fault": a script that endlessly retries
        // an infinite inner loop through pcall still faults once the coroutine's
        // lifetime total is exceeded, and the thread is closed regardless.
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 3_000
        budgets.handlerTotalInstructions = 12_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "pcallLoopTotal", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: "local n = 0; while true do n = n + 1; pcall(function() while true do end end) end",
            chunkName: "pcallLoopTotalChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        var outcome: ScriptResumeOutcome = try state.resume(coroutine, args: [], slice: budgets.handlerSliceInstructions)
        var iterations = 0
        while true {
            if case .faulted = outcome { break }
            guard case .yielded(.preempted) = outcome else {
                return XCTFail("expected only .preempted yields before the fault, got \(outcome)")
            }
            iterations += 1
            XCTAssertLessThan(iterations, 1_000, "the total cap never tripped")
            outcome = try state.resume(coroutine, args: [], slice: budgets.handlerSliceInstructions)
        }
        guard case .faulted(let fault) = outcome else { return XCTFail("expected .faulted") }
        XCTAssertEqual(fault.kind, .instructionBudget)
        XCTAssertFalse(state.isDead)

        // The state itself is unaffected by the one faulted coroutine -- a fresh,
        // unrelated call still works.
        let sanity = try ScriptTestSupport.run("return 3 + 4", on: state)
        guard case .success(let values) = sanity else { return XCTFail("state unusable after the pcall-loop fault") }
        XCTAssertEqual(values, [.int(7)])
    }

    // MARK: - Consecutive-preemption counter (design.md Decision 6: maxConsecutivePreemptions)

    func testTwentyConsecutivePreemptionsCounter() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 500
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let wait = HostFunction { _ in .yield([], .wait(1)) }
        let environment = state.makeEnvironment(
            name: "consecutivePreempt", hostBindings: [.function(name: "wait", wait)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(
            source: """
                local n = 0
                for i = 1, 300000 do n = n + 1 end
                wait()
                return n
                """,
            chunkName: "consecutivePreemptChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        var expectedCount = 0
        var sawWait = false
        var iterations = 0
        while !sawWait {
            iterations += 1
            XCTAssertLessThan(iterations, 5_000, "not making progress")
            let outcome = try state.resume(coroutine, args: [], slice: budgets.handlerSliceInstructions)
            switch outcome {
            case .yielded(.preempted):
                expectedCount += 1
                XCTAssertEqual(coroutine.consecutivePreemptions, expectedCount, "the counter must increment by exactly one per consecutive .preempted yield")
            case .yielded(.wait(let ticks)):
                sawWait = true
                XCTAssertEqual(ticks, 1)
                XCTAssertEqual(coroutine.consecutivePreemptions, 0, "a non-preempted yield must reset the consecutive-preemption counter")
            case .yielded(let other):
                return XCTFail("unexpected yield \(other)")
            case .faulted(let fault):
                return XCTFail("unexpected fault \(fault)")
            case .completed:
                return XCTFail("the script should have yielded .wait before completing")
            }
        }
        XCTAssertGreaterThanOrEqual(expectedCount, 20, "the loop must have produced at least the default maxConsecutivePreemptions (20) before the wait")

        let final = try state.resume(coroutine, args: [], slice: budgets.handlerSliceInstructions)
        guard case .completed(let values) = final else { return XCTFail("expected .completed, got \(final)") }
        XCTAssertEqual(values, [.int(300_000)])
    }

    // MARK: - C35: top-level call() has a hard slice; nested call() keeps the soft slice

    func testTopLevelCallSliceIsHard() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 5_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "hardSlice", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: "return (function() while true do end end)()", chunkName: "hardSliceChunk"
        ).get()

        let outcome = try state.call(function, args: [], slice: budgets.handlerSliceInstructions)
        guard case .failure(let fault) = outcome else { return XCTFail("expected .failure, got \(outcome)") }
        XCTAssertEqual(fault.kind, .instructionBudget)
        XCTAssertFalse(state.isDead, "a hard top-level slice fault must leave the state usable")

        // A completely independent, well-behaved call must still succeed afterward.
        let sanity = try ScriptTestSupport.run("return 5 * 5", on: state)
        guard case .success(let values) = sanity else { return XCTFail("state unusable after a hard-slice fault") }
        XCTAssertEqual(values, [.int(25)])
    }

    func testNestedCallSliceStaysSoft() throws {
        // C21/C35: a call() issued from a host function running inside a coroutine's
        // resume inherits that coroutine's budget record, so its own slice is soft --
        // it does not fault the instant its (small) slice is exceeded; it keeps
        // running (charging the outer coroutine's hard total) until *that* trips.
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 5_000
        budgets.handlerTotalInstructions = 20_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        var nestedOutcome: ScriptCallOutcome?
        let runForever = HostFunction { call in
            guard case .function(let inner) = call.arguments.first else { return .error("expected a function") }
            // A tiny nested slice (1,000): if this were hard, the nested call would
            // fail at ~1,000 instructions -- far below the 20,000 total. Since it is
            // soft here, it must run well past 1,000 before failing at all.
            nestedOutcome = try? call.state.call(inner, args: [], slice: 1_000)
            return .values([])
        }
        let environment = state.makeEnvironment(
            name: "softNestedSlice", hostBindings: [.function(name: "runForever", runForever)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(
            source: """
                local function forever() while true do end end
                runForever(forever)
                return 'unreachable'
                """,
            chunkName: "softNestedSliceChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        let outcome = try state.resume(coroutine, args: [], slice: budgets.handlerSliceInstructions)
        guard case .faulted(let fault) = outcome else { return XCTFail("expected the outer coroutine to fault once its total was exceeded, got \(outcome)") }
        XCTAssertEqual(fault.kind, .instructionBudget)

        guard case .failure(let nestedFault) = nestedOutcome else {
            return XCTFail("expected the nested call to have failed too, got \(String(describing: nestedOutcome))")
        }
        XCTAssertEqual(nestedFault.kind, .instructionBudget)
        XCTAssertGreaterThan(
            coroutine.instructionsUsed, UInt64(1_000),
            "the nested call's own 1,000-instruction slice must not have stopped it on its own -- only the coroutine's larger total did"
        )
    }

    // MARK: - C19: a faulted thread's hook re-arm must not leak into a differently-issued coroutine

    func testFaultedThreadReuseStillBudgeted() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 2_000
        budgets.handlerTotalInstructions = 5_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        // A coroutine whose loop has no yield points: the hook itself raises the
        // total-cap error directly (hostDepth == 0, non-preemptible path) --
        // exactly the "hook-raised fault" C19 is about, as opposed to reaching the
        // cap via an ordinary .preempted resume cycle.
        let env1 = state.makeEnvironment(name: "hookRaisedFault", random: ScriptTestSupport.randomStream())
        let fn1 = try env1.compile(source: "while true do end", chunkName: "hookRaisedFaultChunk").get()
        guard let co1 = try state.makeCoroutine(function: fn1) else { return XCTFail("expected a coroutine") }

        var outcome1: ScriptResumeOutcome = try state.resume(co1, args: [], slice: budgets.handlerSliceInstructions)
        var iterations = 0
        while true {
            if case .faulted = outcome1 { break }
            guard case .yielded(.preempted) = outcome1 else { return XCTFail("unexpected outcome \(outcome1)") }
            iterations += 1
            XCTAssertLessThan(iterations, 1_000)
            outcome1 = try state.resume(co1, args: [], slice: budgets.handlerSliceInstructions)
        }
        guard case .faulted(let fault1) = outcome1 else { return XCTFail("expected the first coroutine to fault") }
        XCTAssertEqual(fault1.kind, .instructionBudget)

        // A brand-new, unrelated coroutine must run its own full budget from zero:
        // no residual count-1 re-arm or stale total leaks in (C19).
        let env2 = state.makeEnvironment(name: "freshAfterFault", random: ScriptTestSupport.randomStream())
        let fn2 = try env2.compile(
            source: "local n = 0; for i = 1, 400 do n = n + 1 end; return n", chunkName: "freshAfterFaultChunk"
        ).get()
        guard let co2 = try state.makeCoroutine(function: fn2) else { return XCTFail("expected a second coroutine") }
        let outcome2 = try state.resume(co2, args: [], slice: budgets.handlerSliceInstructions)
        guard case .completed(let values2) = outcome2 else {
            return XCTFail("expected the second coroutine to complete cleanly, got \(outcome2)")
        }
        XCTAssertEqual(values2, [.int(400)])
    }

    // MARK: - C19/D5: the allocation-rate re-arm (count 1) must not leak into an unrelated coroutine

    func testAllocationTripRearmDoesNotLeakIntoPool() throws {
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.allocationRatePerSliceBytes = 4 * 1024
        budgets.memoryCapBytes = 4 * 1024 * 1024
        budgets.hostOverCapDiagnosticBytes = 1024 * 1024
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        let env1 = state.makeEnvironment(name: "rateTrip", random: ScriptTestSupport.randomStream())
        let fn1 = try env1.compile(
            source: "local t = {}; local i = 0; while true do i = i + 1; t[i] = ('x'):rep(200) end",
            chunkName: "rateTripChunk"
        ).get()
        guard let co1 = try state.makeCoroutine(function: fn1) else { return XCTFail("expected a coroutine") }
        let outcome1 = try state.resume(co1, args: [], slice: 5_000_000)
        guard case .faulted(let fault1) = outcome1 else { return XCTFail("expected an allocation-rate fault, got \(outcome1)") }
        XCTAssertEqual(fault1.kind, .allocationRate)

        // The re-arm-to-count-1 the allocator installs on trip (D5) must be undone
        // before the thread is reused (C19): a fresh, tiny loop -- far fewer real
        // instructions than the slice -- must complete in a single resume with zero
        // preemptions. If the count-1 leaked, every real instruction would fire the
        // hook and the slice would appear exhausted almost immediately.
        let env2 = state.makeEnvironment(name: "freshAfterRate", random: ScriptTestSupport.randomStream())
        let fn2 = try env2.compile(
            source: "local n = 0; for i = 1, 50 do n = n + 1 end; return n", chunkName: "freshAfterRateChunk"
        ).get()
        guard let co2 = try state.makeCoroutine(function: fn2) else { return XCTFail("expected a second coroutine") }
        let outcome2 = try state.resume(co2, args: [], slice: 100_000)
        guard case .completed(let values2) = outcome2 else {
            return XCTFail("expected a clean, unpreempted completion, got \(outcome2)")
        }
        XCTAssertEqual(values2, [.int(50)])
    }

    // MARK: - security-code.md HIGH finding (downgraded Condition 5): state-wide
    // trip flags must not survive a coroutine's own pcall, and cannot be revived

    func testRateTripCaughtByPcallDoesNotLeakIntoNextResume() throws {
        // The resume() counterpart of MemoryTests' call()-based regressions
        // (testRateTripCaughtByPcallStillFaultsTheTrippingCall/
        // testRateTripCaughtByPcallDoesNotLeakIntoNextCall): a coroutine that
        // traps its own allocation-rate trip in a *local* pcall and then returns
        // normally must still be reported as .faulted(.allocationRate) for that
        // resume -- "pcall cannot revive it" (design.md 93, 279) -- and the
        // state-wide flag must not survive into a later, unrelated coroutine's
        // resume (over 1,000 instructions, so the count hook actually fires and
        // would re-read a leaked flag).
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.allocationRatePerSliceBytes = 8 * 1024
        budgets.memoryCapBytes = 8 * 1024 * 1024 // generous: isolate the rate, not the cap
        budgets.hostOverCapDiagnosticBytes = 1024 * 1024
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        let envA = state.makeEnvironment(name: "rateTripResumeA", random: ScriptTestSupport.randomStream())
        let fnA = try envA.compile(
            source: """
                local ok = pcall(function()
                    local t = {}
                    for i = 1, 100000 do t[i] = ('x'):rep(300) end
                end)
                return ok
                """,
            chunkName: "rateTripResumeAChunk"
        ).get()
        guard let coA = try state.makeCoroutine(function: fnA) else { return XCTFail("expected a coroutine") }
        let outcomeA = try state.resume(coA, args: [], slice: 5_000_000)
        guard case .faulted(let faultA) = outcomeA else {
            return XCTFail("a coroutine's own pcall must not be able to revive an allocation-rate trip into .completed, got \(outcomeA)")
        }
        XCTAssertEqual(faultA.kind, .allocationRate)

        // A brand-new, unrelated coroutine must run clean: the leaked state-wide
        // flag must not spuriously fault it once it crosses one hook granularity.
        let envB = state.makeEnvironment(name: "rateTripResumeB", random: ScriptTestSupport.randomStream())
        let fnB = try envB.compile(
            source: "local s = 0 for i = 1, 37566 do s = s + i end return s",
            chunkName: "rateTripResumeBChunk"
        ).get()
        guard let coB = try state.makeCoroutine(function: fnB) else { return XCTFail("expected a second coroutine") }
        let outcomeB = try state.resume(coB, args: [], slice: 1_000_000)
        guard case .completed(let valuesB) = outcomeB else {
            return XCTFail("a fresh coroutine allocates nothing and trips no budget of its own -- it must complete, not inherit the trip; got \(outcomeB)")
        }
        XCTAssertEqual(valuesB, [.int(705_620_961)])
    }

    // MARK: - F4 (test.md defect): a top-level call()'s hard slice is a pure
    // function of the call, independent of what ran on the main thread before it

    func testCallHardSliceIsIndependentOfPriorCalls() throws {
        // test.md testZZCallHardSliceDependsOnMainThreadHookPhase: elysium_pcall
        // only reset the main thread's hook (lua_sethook, which resets hookcount)
        // when a trip had left it mis-armed; on the ordinary path the 1,000-
        // instruction counter carried its phase over from whatever the *previous*
        // top-level call() left it at, so the same program at the same slice could
        // complete or fault depending on prior, completely unrelated work. Fix:
        // the reset is now unconditional.
        //
        // "Binary-search-free": test.md's reproduction found these exact
        // thresholds for this program at slice 4,000 by binary search on
        // independent fresh states (smallest faulting N = 1,997 fresh; 1,744/1,594/
        // 1,994 after a prior 250/400/1,000-iteration call). Reusing those two
        // known values directly -- rather than re-deriving them here -- is what
        // makes this a fixed-probe check instead of another search.
        let slice = 4_000
        let succeedsN = 1_996
        let faultsN = 1_997

        func loopSource(_ n: Int) -> String {
            "local n = 0 for i = 1, \(n) do n = n + 1 end return n"
        }

        // Runs `priorIterations` of unrelated top-level work first (skipped when
        // 0), then probes `n` -- both against a state used for nothing else, so
        // each measurement is isolated exactly like test.md's per-scenario states.
        func probe(_ n: Int, afterPriorIterations priorIterations: Int) throws -> ScriptCallOutcome {
            let state = try ScriptTestSupport.makeState()
            if priorIterations > 0 {
                let warmupEnv = state.makeEnvironment(name: "hardSliceWarmup", random: ScriptTestSupport.randomStream())
                let warmup = try warmupEnv.compile(source: loopSource(priorIterations), chunkName: "hardSliceWarmupChunk").get()
                _ = try state.call(warmup, args: [], slice: slice)
            }
            let probeEnv = state.makeEnvironment(name: "hardSliceProbe", random: ScriptTestSupport.randomStream())
            let function = try probeEnv.compile(source: loopSource(n), chunkName: "hardSliceProbeChunk").get()
            return try state.call(function, args: [], slice: slice)
        }

        func assertSucceeds(_ n: Int, afterPriorIterations priorIterations: Int) throws {
            guard case .success(let values) = try probe(n, afterPriorIterations: priorIterations) else {
                return XCTFail("N=\(n) must complete after \(priorIterations) prior iterations")
            }
            XCTAssertEqual(values, [.int(Int64(n))])
        }

        func assertFaults(_ n: Int, afterPriorIterations priorIterations: Int) throws {
            guard case .failure(let fault) = try probe(n, afterPriorIterations: priorIterations) else {
                return XCTFail("N=\(n) must fault after \(priorIterations) prior iterations")
            }
            XCTAssertEqual(fault.kind, .instructionBudget)
        }

        // Fresh-state baseline (zero prior top-level work).
        try assertSucceeds(succeedsN, afterPriorIterations: 0)
        try assertFaults(faultsN, afterPriorIterations: 0)

        // The identical two thresholds must hold after any amount of unrelated
        // prior top-level work -- exactly what elysium_pcall's unconditional hook
        // reset guarantees and the conditional reset (F4) broke.
        for priorIterations in [250, 400, 1_000] {
            try assertSucceeds(succeedsN, afterPriorIterations: priorIterations)
            try assertFaults(faultsN, afterPriorIterations: priorIterations)
        }
    }
}
