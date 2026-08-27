// MemoryTests.swift — task 6.1. design.md Decision 5 (allocator: hard cap,
// allocation-rate budget, host-stepped incremental GC) and the Risk-to-Test Map's
// "Memory model" row.

import ElysiumCore
// @testable: F2's regression test reads LuaState.pooledThreadCount, an internal
// (not public) accessor added solely for this test (design.md Condition 16/17's
// public API is not expanded for it — see Coroutines.swift's doc comment).
@testable import ElysiumScript
import XCTest

final class MemoryTests: XCTestCase {
    // MARK: - Memory cap trips even under pcall

    func testCapTripUnderPcall() throws {
        // spec "Memory cap trips even under pcall": a script that keeps allocating
        // through an inner pcall must still fault (.memoryCap) once the cap is
        // exceeded, the thread is closed, and at most two allocator refusals occur
        // after the trip (D5: the count-1 re-arm bounds the emergency-GC churn to one
        // further collection before the hook raises).
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.memoryCapBytes = 96 * 1024
        budgets.hostOverCapDiagnosticBytes = 32 * 1024
        budgets.allocationRatePerSliceBytes = 1024 * 1024 // large: isolate the cap, not the rate
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "capUnderPcall", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: """
                local t = {}
                local i = 0
                while true do
                    pcall(function()
                        i = i + 1
                        t[i] = ('x'):rep(200)
                    end)
                end
                """,
            chunkName: "capUnderPcallChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        let statusBefore = state.memoryStatus
        let outcome = try state.resume(coroutine, args: [], slice: 5_000_000)
        guard case .faulted(let fault) = outcome else { return XCTFail("expected .faulted, got \(outcome)") }
        XCTAssertEqual(fault.kind, .memoryCap, "pcall around the allocating statement must not turn a cap trip into an ordinary catchable error")
        XCTAssertFalse(state.isDead, "the state itself must survive even though pcall could not revive the coroutine")
        // "at most two allocator refusals after the trip": not independently
        // observable through the public API once a script-level pcall is in the
        // loop (whether the C layer clears `tripped` here depends on which of two
        // internal paths detected the trip first: the hook's own raise, or Lua's
        // luaM_error reached directly from inside the allocator -- both are
        // "the trip was reported and forced .faulted", which is what's asserted
        // above). What we *can* observe: the state stayed responsive throughout
        // (allocationCalls kept advancing, it did not hang or corrupt) and a fresh,
        // unrelated call on the same state still works afterward.
        XCTAssertGreaterThan(state.memoryStatus.allocationCalls, statusBefore.allocationCalls)
        // Builder fix (security-code.md HIGH finding, downgraded Condition 5): the
        // sanity script below used to be "return 11 + 22" -- under 1,000
        // instructions, so the count hook never fired during it and a stale
        // st->tripped/st->rateTripped left set by the trip above would never have
        // been re-read; the test passed "by luck of a short sanity script" even
        // against the buggy C (its own prior comment conceded this). Exceeding one
        // hook granularity (1,000 instructions) here means a leaked flag reliably
        // manifests as a spurious fault instead of silently passing.
        let sanity = try ScriptTestSupport.run("local s = 0 for i = 1, 5000 do s = s + i end return s", on: state)
        guard case .success(let values) = sanity else { return XCTFail("state unusable after the pcall-wrapped cap trip") }
        XCTAssertEqual(values, [.int(12_502_500)])
    }

    // MARK: - call()-side counterpart: state-wide trip flags must not survive a
    // script's own pcall (security-code.md HIGH finding, downgraded Condition 5)

    func testPostTripSanityScriptExceeds1000Instructions() throws {
        // The call() counterpart of the strengthened testCapTripUnderPcall above:
        // a memory-cap trip the script traps in its *own* pcall (the whole
        // allocating loop is inside the pcall this time, so the chunk returns
        // normally with ok == false rather than propagating an error) must not
        // leave state-wide flags set for a later, unrelated call() whose sanity
        // script runs past 1,000 instructions.
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.memoryCapBytes = 96 * 1024
        budgets.hostOverCapDiagnosticBytes = 32 * 1024
        budgets.allocationRatePerSliceBytes = 1024 * 1024 // isolate the cap, not the rate
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let envA = state.makeEnvironment(name: "capTripCallA", random: ScriptTestSupport.randomStream())
        let scriptA = try envA.compile(
            source: """
                local ok = pcall(function()
                    local t = {}
                    local i = 0
                    while true do
                        i = i + 1
                        t[i] = ('x'):rep(200)
                    end
                end)
                return ok
                """,
            chunkName: "capTripCallAChunk"
        ).get()

        let outcomeA = try state.call(scriptA, args: [], slice: 5_000_000)
        guard case .failure(let faultA) = outcomeA else {
            return XCTFail("a script's own pcall must not be able to revive a memory-cap trip into .success, got \(outcomeA)")
        }
        XCTAssertEqual(faultA.kind, .memoryCap)
        XCTAssertFalse(state.isDead)

        let sanity = try ScriptTestSupport.run("local s = 0 for i = 1, 5000 do s = s + i end return s", on: state)
        guard case .success(let values) = sanity else { return XCTFail("state unusable after the pcall-wrapped cap trip") }
        XCTAssertEqual(values, [.int(12_502_500)])
    }

    // MARK: - Allocation-rate trip caught by the script's own pcall (call())

    func testRateTripCaughtByPcallStillFaultsTheTrippingCall() throws {
        // security-code.md HIGH finding (Refutation): a script that traps its own
        // allocation-rate trip in a *local* pcall and then returns normally must
        // still be reported as .allocationRate at the call() boundary -- "pcall
        // cannot revive it" (design.md 93, 279) -- never as a plain .success(false).
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.allocationRatePerSliceBytes = 8 * 1024
        budgets.memoryCapBytes = 8 * 1024 * 1024 // generous: isolate the rate, not the cap
        budgets.hostOverCapDiagnosticBytes = 1024 * 1024
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "rateTripCaught", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: """
                local ok = pcall(function()
                    local t = {}
                    for i = 1, 100000 do t[i] = ('x'):rep(300) end
                end)
                return ok
                """,
            chunkName: "rateTripCaughtChunk"
        ).get()

        let outcome = try state.call(function, args: [], slice: 5_000_000)
        guard case .failure(let fault) = outcome else {
            return XCTFail("expected .failure -- a script's own pcall must not be able to revive an allocation-rate trip into .success, got \(outcome)")
        }
        XCTAssertEqual(fault.kind, .allocationRate)
        XCTAssertFalse(state.isDead)
    }

    func testRateTripCaughtByPcallDoesNotLeakIntoNextCall() throws {
        // security-code.md HIGH finding: once script A's own pcall traps its
        // allocation-rate trip, the state-wide flag must not survive into a later,
        // unrelated call() -- a clean, allocation-light script B (over 1,000
        // instructions, so the count hook actually fires and would re-read a
        // leaked flag) must not be spuriously faulted with .allocationRate.
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.allocationRatePerSliceBytes = 8 * 1024
        budgets.memoryCapBytes = 8 * 1024 * 1024
        budgets.hostOverCapDiagnosticBytes = 1024 * 1024
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let envA = state.makeEnvironment(name: "rateTripLeakA", random: ScriptTestSupport.randomStream())
        let scriptA = try envA.compile(
            source: """
                local ok = pcall(function()
                    local t = {}
                    for i = 1, 100000 do t[i] = ('x'):rep(300) end
                end)
                return ok
                """,
            chunkName: "rateTripLeakAChunk"
        ).get()
        let outcomeA = try state.call(scriptA, args: [], slice: 5_000_000)
        guard case .failure(let faultA) = outcomeA else { return XCTFail("expected script A to fault, got \(outcomeA)") }
        XCTAssertEqual(faultA.kind, .allocationRate)

        let envB = state.makeEnvironment(name: "rateTripLeakB", random: ScriptTestSupport.randomStream())
        let scriptB = try envB.compile(
            source: "local s = 0 for i = 1, 37566 do s = s + i end return s",
            chunkName: "rateTripLeakBChunk"
        ).get()
        let outcomeB = try state.call(scriptB, args: [], slice: 1_000_000)
        guard case .success(let valuesB) = outcomeB else {
            return XCTFail("script B allocates nothing and trips no budget of its own -- it must succeed, not inherit script A's trip; got \(outcomeB)")
        }
        XCTAssertEqual(valuesB, [.int(705_620_961)])
    }

    // MARK: - Allocation-rate trip

    func testAllocationRateTrip() throws {
        // spec "Allocation-rate trip": a script that requests more than the
        // per-slice allocation budget without exceeding the hard cap must fault
        // (.allocationRate), and the memory accounting stays consistent -- after a
        // full collection, bytesInUse returns to (near) the pre-script baseline
        // plus the retained environment footprint (nothing was permanently lost or
        // double-counted).
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.allocationRatePerSliceBytes = 8 * 1024
        budgets.memoryCapBytes = 8 * 1024 * 1024 // generous: isolate the rate, not the cap
        budgets.hostOverCapDiagnosticBytes = 1024 * 1024
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse

        let environment = state.makeEnvironment(name: "rateTrip", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: "local t = {}; local i = 0; while true do i = i + 1; t[i] = ('y'):rep(200) end",
            chunkName: "rateTripChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        let outcome = try state.resume(coroutine, args: [], slice: 5_000_000)
        guard case .faulted(let fault) = outcome else { return XCTFail("expected .faulted, got \(outcome)") }
        XCTAssertEqual(fault.kind, .allocationRate)
        XCTAssertLessThan(
            state.memoryStatus.bytesInUse, UInt64(budgets.memoryCapBytes),
            "an allocation-rate trip must fire well below the hard cap"
        )

        // Discard the faulted coroutine's own retained garbage (its stack/locals are
        // already gone once closed+pooled) and confirm the allocator's bookkeeping is
        // internally consistent, not merely "close to" some number picked in advance.
        state.collectFull()
        let after = state.memoryStatus.bytesInUse
        XCTAssertLessThan(
            after, baseline + UInt64(budgets.memoryCapBytes) / 4,
            "bytesInUse after a full collection must not have run away far past the pre-script baseline"
        )
    }

    // MARK: - GC determinism

    func testGCStepDeterminism() throws {
        // spec "GC determinism": the same script sequence, with collectStep called
        // at the same points, must leave memoryStatus.bytesInUse identical across
        // two independently constructed states.
        func run() throws -> [UInt64] {
            let state = try ScriptTestSupport.makeState()
            var samples: [UInt64] = []
            let environment = state.makeEnvironment(name: "gcStep", random: ScriptTestSupport.randomStream())
            let function = try environment.compile(
                source: """
                    local t = {}
                    for i = 1, 200 do t[i] = { value = i, tag = tostring(i) } end
                    return #t
                    """,
                chunkName: "gcStepChunk"
            ).get()
            state.collectStep(kilobytes: 4)
            samples.append(state.memoryStatus.bytesInUse)
            let outcome = try state.call(function, args: [], slice: 1_000_000)
            guard case .success = outcome else { XCTFail("expected success"); return samples }
            state.collectStep(kilobytes: 4)
            samples.append(state.memoryStatus.bytesInUse)
            state.collectFull()
            samples.append(state.memoryStatus.bytesInUse)
            return samples
        }

        let first = try run()
        let second = try run()
        XCTAssertEqual(first, second, "identical scripts with collectStep called at the same points must produce identical bytesInUse at every sampled point")
    }

    // MARK: - Host section never returns NULL (D5 Rule 4)

    func testHostSectionNeverNull() throws {
        // design.md Decision 5 / Rule 4: while hostDepth > 0 (inside a host
        // function), the allocator always satisfies the request -- pushing a value
        // even at/over the cap succeeds; only overCapHost (a diagnostic) is set,
        // never a refusal, and the script only faults *after* the resume returns.
        // Note: constructing the state + environment + coroutine already costs on
        // the order of 25 KiB (host sections, never capped -- Decision 5) before the
        // script runs a single instruction; the cap below must clear that baseline
        // comfortably or the very first script-frame allocation would already be
        // over cap.
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.memoryCapBytes = 96 * 1024
        budgets.hostOverCapDiagnosticBytes = 256 * 1024 // generous slack so the host push itself never trips overCapHost's own ceiling
        budgets.allocationRatePerSliceBytes = 1024 * 1024 // isolate the cap, not the rate
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        var hostPushSucceeded = false
        // Stay under ScriptValueLimits.defaults.listElements (256) -- this test is
        // about the allocator's host-section discipline, not the marshaling caps.
        let big = ScriptValue.list((0..<200).map { .string("padding-\($0)-\(String(repeating: "z", count: 32))") })
        let pushBig = HostFunction { _ in
            hostPushSucceeded = true
            return .values([big])
        }
        let environment = state.makeEnvironment(
            name: "hostNeverNull", hostBindings: [.function(name: "pushBig", pushBig)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(
            source: """
                local t = {}
                local i = 0
                while true do
                    i = i + 1
                    if i == 1 then
                        local v = pushBig()
                        if v then end
                    end
                    t[i] = ('x'):rep(80)
                end
                """,
            chunkName: "hostNeverNullChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        let outcome = try state.resume(coroutine, args: [], slice: 5_000_000)
        XCTAssertTrue(hostPushSucceeded, "the host function's own push must have completed without the allocator ever refusing it")
        guard case .faulted(let fault) = outcome else { return XCTFail("expected the script to eventually fault after crossing the cap, got \(outcome)") }
        XCTAssertTrue(fault.kind == .memoryCap || fault.kind == .allocationRate)
        XCTAssertFalse(state.isDead)
    }

    // MARK: - collectFull baseline

    func testCollectFullBaseline() throws {
        // A minimal, closed loop of allocate-then-drop-references followed by
        // collectFull must return bytesInUse to (at most) the pre-loop baseline --
        // proving collectFull actually reclaims everything reachable only from the
        // loop's own now-dead locals, with nothing pinned by a leak in the runtime.
        // A generous allocation-rate budget: this test is about collectFull's
        // reclamation, not about tripping the rate budget along the way.
        var budgets = ScriptBudgets.defaults
        budgets.allocationRatePerSliceBytes = 16 * 1024 * 1024
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        // Build the environment (and its own lasting ~4 KiB footprint) *before*
        // sampling the baseline, so the comparison below is apples-to-apples --
        // ScriptTestSupport.run's own convenience environment is never destroyed
        // and would otherwise show up as unreclaimed "garbage" of its own.
        let environment = state.makeEnvironment(name: "collectFullBaseline", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: """
                for round = 1, 20 do
                    local garbage = {}
                    for i = 1, 500 do garbage[i] = { tostring(i), i * 2, {i, i, i} } end
                end
                return true
                """,
            chunkName: "collectFullBaselineChunk"
        ).get()
        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse

        let outcome = try state.call(function, args: [], slice: 5_000_000)
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.bool(true)])

        state.collectFull()
        let after = state.memoryStatus.bytesInUse
        XCTAssertLessThanOrEqual(
            after, baseline + 4 * 1024,
            "collectFull must reclaim the loop's own dead garbage down to (about) the pre-loop baseline"
        )
    }

    // MARK: - F2 (test.md defect): the thread pool bounds repeated coroutine churn

    func testThreadCyclesDoNotGrowState() throws {
        // test.md testZZThreadCycles10000NoGrowth: before the fix, elysium_newthread
        // always created a brand-new thread + ctx regardless of the pool, so
        // makeCoroutine -> resume(complete) -> close cycles grew bytesInUse without
        // bound (722 B/cycle observed) and threadPoolMax was never honoured at all.
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.threadPoolMax = 8
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "threadCycles", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "return ...", chunkName: "threadCyclesChunk").get()

        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse

        for i in 0..<10_000 {
            guard let coroutine = try state.makeCoroutine(function: function) else {
                return XCTFail("expected a coroutine (iteration \(i))")
            }
            let outcome = try state.resume(coroutine, args: [.int(1)], slice: 1_000)
            guard case .completed(let values) = outcome else {
                return XCTFail("expected completion at iteration \(i), got \(outcome)")
            }
            XCTAssertEqual(values, [.int(1)])
            // A completed coroutine is closed+pooled internally by resume() itself
            // (design.md Decision 7: "Closed or completed threads go back to the
            // pool"); the idle pool must never exceed threadPoolMax.
            XCTAssertLessThanOrEqual(state.pooledThreadCount, budgets.threadPoolMax, "iteration \(i)")
        }

        state.collectFull()
        let after = state.memoryStatus.bytesInUse
        XCTAssertLessThanOrEqual(
            after, baseline + 64 * 1024,
            "10,000 makeCoroutine -> resume(complete) -> close cycles must not grow the state's bytesInUse without bound"
        )
        XCTAssertLessThanOrEqual(state.pooledThreadCount, budgets.threadPoolMax)
    }

    // MARK: - F3 (test.md defect): ScriptEnvironment.destroy() reclaims everything

    func testEnvironmentCyclesReclaim() throws {
        // test.md testZZEnvironmentCycles2000Reclaim: before the fix,
        // elysium_destroy_environment only released _ENV's own registry ref; the
        // state-wide host-owned marker table's strong reference to every
        // per-environment proxy/metatable (plus the never-released compiled-chunk
        // refs) kept the whole per-environment object graph reachable forever
        // (5,573 B/cycle observed with no compile, 6,056 B/cycle with one).
        let state = try ScriptTestSupport.makeState()
        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse

        for i in 0..<2_000 {
            let environment = state.makeEnvironment(name: "envCycle", random: ScriptTestSupport.randomStream())
            let function = try environment.compile(source: "return 1", chunkName: "envCycleChunk").get()
            _ = function // compiled but never called -- exercises the compiled-chunk ref release too
            environment.destroy()
            if i % 200 == 0 {
                XCTAssertLessThanOrEqual(
                    state.memoryStatus.bytesInUse, baseline + 512 * 1024,
                    "must not grow unboundedly mid-run (iteration \(i))"
                )
            }
        }

        state.collectFull()
        let after = state.memoryStatus.bytesInUse
        XCTAssertLessThanOrEqual(
            after, baseline + 64 * 1024,
            "2,000 makeEnvironment -> compile -> destroy cycles must not grow the state's bytesInUse without bound"
        )
    }

    func testDestroyedEnvironmentFunctionIsInvalid() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "destroyedFn", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "return 42", chunkName: "destroyedFnChunk").get()
        environment.destroy()

        let outcome = try state.call(function, args: [], slice: 1_000)
        guard case .failure(let fault) = outcome else {
            return XCTFail("expected a call on a destroyed environment's function to fail, got \(outcome)")
        }
        XCTAssertEqual(fault.kind, .hostAbort)
        XCTAssertEqual(fault.message, "function's environment was destroyed")
        XCTAssertFalse(state.isDead, "the state itself must remain usable after an environment is destroyed")
    }

    func testCallbackRefsAreOwnedByEnvironmentAndReclaimedUnderBoundedChurn() throws {
        let state = try ScriptTestSupport.makeState()
        var lastCallback: ScriptFunction?
        var sawStateWideHandleBoundary = false
        let dispatch = HandleDispatch(methods: ["capture": { _, call in
            sawStateWideHandleBoundary = sawStateWideHandleBoundary || call.environment == nil
            guard case .function(let callback)? = call.arguments.first else {
                return .error("expected callback")
            }
            lastCallback = callback
            return .values([])
        }])
        let kind = state.registerHandleKind(name: "callbackSink", dispatch: dispatch, interned: true)
        let sink = try state.makeHandle(kind: kind, ref: "callbackSink:1", id: 1)
        let getSink = HostFunction { _ in .values([sink]) }

        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse
        for i in 0..<500 {
            let environment = state.makeEnvironment(
                name: "callbackCycle\(i)",
                hostBindings: [.function(name: "getSink", getSink)],
                random: ScriptTestSupport.randomStream()
            )
            let function = try environment.compile(
                source: "local sink = getSink(); for n = 1, 16 do sink:capture(function() return n end) end",
                chunkName: "callbackCycleChunk"
            ).get()
            if i.isMultiple(of: 2) {
                guard case .success = try state.call(function, args: [], slice: 100_000) else {
                    environment.destroy()
                    return XCTFail("callback churn call failed at iteration \(i)")
                }
            } else {
                guard let coroutine = try state.makeCoroutine(function: function),
                      case .completed = try state.resume(coroutine, args: [], slice: 100_000) else {
                    environment.destroy()
                    return XCTFail("callback churn resume failed at iteration \(i)")
                }
            }
            environment.destroy()
            if i % 50 == 0 {
                state.collectFull()
                XCTAssertLessThanOrEqual(
                    state.memoryStatus.bytesInUse, baseline + 256 * 1024,
                    "callback registry refs must not accumulate across destroyed environments (iteration \(i))"
                )
            }
        }

        state.collectFull()
        XCTAssertLessThanOrEqual(
            state.memoryStatus.bytesInUse, baseline + 64 * 1024,
            "destroying callback-heavy environments must reclaim their Lua registry refs"
        )
        XCTAssertTrue(sawStateWideHandleBoundary)

        guard let lastCallback else { return XCTFail("expected a captured callback") }
        guard case .failure(let fault) = try state.call(lastCallback, args: [], slice: 1_000) else {
            return XCTFail("a callback must become unusable when its owning environment is destroyed")
        }
        XCTAssertEqual(fault.kind, .hostAbort)
        XCTAssertEqual(fault.message, "function's environment was destroyed")
    }

    // MARK: - A3-1 (Security (code) attempt 3, HIGH): a setmetatable storm at a tiny
    // memory cap must not permanently brick the shared state

    func testSetmetatableStormDoesNotBrickState() throws {
        // security-code.md Finding A3-1's "brick" reproduction: before the fix, every
        // setmetatable(t, mt) call without a __metatable field permanently retained
        // its fresh view metatable in the state-wide strong host-owned set (no
        // manifest entry, unreclaimable by collectFull) regardless of whether the
        // script itself kept any reference to t/mt. At a small cap this exhausted
        // the budget within a handful of runs and, even after collectFull, a later
        // allocation-light script faulted .memoryCap forever -- the shared state was
        // permanently bricked; only closing the LuaState recovered it. After the
        // fix, an individual storm run may still trip .memoryCap (the budget really
        // is tiny) or complete, but nothing it retains outlives collectFull, and the
        // state stays usable afterward.
        var budgets = ScriptTestSupport.tinyBudgets // memoryCapBytes = 128 * 1024
        budgets.allocationRatePerSliceBytes = 8 * 1024 * 1024 // isolate the cap, not the per-slice rate
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "storm", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: "for i = 1, 400 do setmetatable({}, {}) end return true",
            chunkName: "stormChunk"
        ).get()

        for i in 0..<30 {
            let outcome = try state.call(function, args: [], slice: 2_000_000)
            switch outcome {
            case .success(let values):
                XCTAssertEqual(values, [.bool(true)], "iteration \(i)")
            case .failure(let fault):
                XCTAssertEqual(
                    fault.kind, .memoryCap,
                    "iteration \(i): only a memory-cap trip is an acceptable failure, got \(fault.kind)"
                )
            }
        }

        state.collectFull()

        // The decisive assertion: an allocation-light script well over 1,000
        // instructions (past the count hook's own granularity) must succeed here,
        // not fault .memoryCap forever the way the pre-fix, permanently bricked
        // state would.
        let sanity = try ScriptTestSupport.run(
            "local s = 0 for i = 1, 5000 do s = s + i end return s", on: state
        )
        guard case .success(let values) = sanity else {
            return XCTFail("state must not be permanently bricked by a setmetatable storm at a tiny memory cap, got \(sanity)")
        }
        XCTAssertEqual(values, [.int(12_502_500)])
    }
}
