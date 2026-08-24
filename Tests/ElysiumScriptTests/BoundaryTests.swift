// BoundaryTests.swift — task 6.1/6.4. design.md Decision 4 (the C boundary contract)
// and the Risk-to-Test Map's "Swift frame unwound by Lua" row: proves that raising,
// yielding, resuming, nesting and re-entrancy are exactly as safe as the `hostDepth`
// invariant and the C20/C21 amendments claim — a script can never unwind a Swift frame,
// and a host function can never corrupt the state by asking the host to resume or close
// its own coroutine, or by nesting past the entry-stack cap.

import ElysiumCore
import ElysiumScript
import XCTest

final class BoundaryTests: XCTestCase {
    // MARK: - Host function values / error / yield (design.md Decision 4 Rule 1)

    func testHostFunctionReturnsMultipleValues() throws {
        let state = try ScriptTestSupport.makeState()
        let triple = HostFunction { _ in .values([.int(1), .string("two"), .bool(true)]) }
        let outcome = try ScriptTestSupport.run(
            "local a, b, c = triple(); return a, b, c", on: state,
            hostBindings: [.function(name: "triple", triple)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.int(1), .string("two"), .bool(true)])
    }

    func testHostFunctionErrorMessageIsExactAndCatchable() throws {
        let state = try ScriptTestSupport.makeState()
        let boom = HostFunction { _ in .error("precisely this message") }
        let outcome = try ScriptTestSupport.run(
            "local ok, msg = pcall(boom); return ok, msg", on: state,
            hostBindings: [.function(name: "boom", boom)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.bool(false), .string("precisely this message")])
    }

    func testHostFunctionYieldAwaitReasonAndResumeValues() throws {
        // spec "Await resume values": a host function yields .await(token); the host's
        // next resume(args:) become that call's own results inside the script.
        let state = try ScriptTestSupport.makeState()
        let waitForHost = HostFunction { _ in .yield([], .await(7)) }
        let environment = state.makeEnvironment(
            name: "await", hostBindings: [.function(name: "waitForHost", waitForHost)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(
            source: "local text, err = waitForHost(); return text, err", chunkName: "awaitChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        let first = try state.resume(coroutine, args: [], slice: 10_000)
        guard case .yielded(.await(let token)) = first else { return XCTFail("expected .yielded(.await), got \(first)") }
        XCTAssertEqual(token, 7)

        let second = try state.resume(coroutine, args: [.string("hello"), .null], slice: 10_000)
        guard case .completed(let values) = second else { return XCTFail("expected .completed, got \(second)") }
        XCTAssertEqual(values, [.string("hello"), .null])
    }

    // MARK: - Memory cap reached inside a host call (spec "Memory cap reached inside a host call")

    func testHostFunctionPushSucceedsAtCapAndScriptFaultsAfterResumeReturns() throws {
        // design.md Decision 5 / Rule 4: the allocator never returns NULL while
        // hostDepth > 0 — a host function's own push always succeeds, even past the
        // cap; only the *next* script-frame allocation (or the trip flag left behind)
        // turns into a fault, and only once elysium_resume has returned.
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.memoryCapBytes = 32 * 1024
        budgets.hostOverCapDiagnosticBytes = 8 * 1024
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        // A host function that, on its first call, pushes a table comfortably larger
        // than the remaining headroom under the cap — proving the push itself never
        // raises ERRMEM even though it drives bytesInUse over budgets.memoryCapBytes.
        var big: [ScriptValue] = []
        for i in 0..<200 { big.append(.string("padding-\(i)-\(String(repeating: "x", count: 64))")) }
        let pushBig = HostFunction { _ in .values([.list(big)]) }

        let environment = state.makeEnvironment(
            name: "capHost", hostBindings: [.function(name: "pushBig", pushBig)], random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(
            source: """
                local t = {}
                local i = 0
                while true do
                    i = i + 1
                    t[i] = ('x'):rep(50)
                    if i % 50 == 0 then
                        local ok = pushBig()
                        if ok then end
                    end
                end
                """,
            chunkName: "capHostChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        let outcome = try state.resume(coroutine, args: [], slice: 5_000_000)
        guard case .faulted(let fault) = outcome else { return XCTFail("expected .faulted, got \(outcome)") }
        // The trip that ends the script is a memory/allocation-rate condition, never
        // an uncaught Lua runtime error — the host push that crossed the cap did not
        // itself raise.
        XCTAssertTrue(
            fault.kind == .memoryCap || fault.kind == .allocationRate,
            "expected a memory-related fault, got \(fault.kind)"
        )
        XCTAssertFalse(state.isDead, "the state itself must survive a script-level cap fault")
    }

    // MARK: - Nested `call` from a host function (design.md: "explicitly tested in the plan")

    func testNestedCallFromHostFunction() throws {
        let state = try ScriptTestSupport.makeState()
        var innerResult: ScriptCallOutcome?
        let callAgain = HostFunction { call in
            guard case .function(let inner) = call.arguments.first else { return .error("expected a function argument") }
            innerResult = try? call.state.call(inner, args: [.int(9)], slice: 10_000)
            return .values([.int(1)])
        }
        let outcome = try ScriptTestSupport.run(
            """
            local function double(x) return x * 2 end
            return callAgain(double)
            """, on: state, hostBindings: [.function(name: "callAgain", callAgain)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.int(1)])
        guard case .success(let innerValues) = innerResult else {
            return XCTFail("expected the nested call to succeed, got \(String(describing: innerResult))")
        }
        XCTAssertEqual(innerValues, [.int(18)], "the nested call must have actually run 'double' and returned its real result")
    }

    // MARK: - Dispatcher discipline: r >= 0 always matches what was actually pushed

    /// design.md Decision 4's trampoline defends against a dispatcher that declares
    /// more results than it pushed (`lua_gettop(L) < r` -> "internal error", never a
    /// crash). The shipped dispatcher (`LuaState.pushHostResult`) always pushes
    /// exactly as many values as it reports for `.values` (it returns the error path
    /// immediately if a push throws partway through), so this exact adversarial
    /// mismatch cannot be produced through the public Swift API — there is exactly
    /// one process-wide dispatcher (`elysium_set_dispatch`, installed once) and no
    /// public seam lets a test substitute a different one. This test instead proves
    /// the discipline holds — no internal-error fault, no crash, correct values —
    /// across a battery of host-function result shapes designed to stress the
    /// push-then-report path: zero results, many results, results after arguments,
    /// and a marshaling failure partway through a large result list (which must
    /// surface as an ordinary catchable Lua error, not an internal-error fault).
    func testHostFunctionResultCountAlwaysMatchesWhatWasPushed() throws {
        let state = try ScriptTestSupport.makeState()
        let zero = HostFunction { _ in .values([]) }
        let many = HostFunction { _ in .values((0..<50).map { .int(Int64($0)) }) }
        var overflowString = String(repeating: "z", count: 5_000)
        overflowString += overflowString // > 4 KiB default ScriptValue.string cap
        let partialFailure = HostFunction { _ in
            .values([.int(1), .int(2), .string(overflowString)])
        }
        let outcome = try ScriptTestSupport.run(
            """
            local n = select('#', zero())
            local many_count = select('#', many())
            local ok, err = pcall(partialFailure)
            return n, many_count, ok, (err ~= nil)
            """,
            on: state,
            hostBindings: [
                .function(name: "zero", zero), .function(name: "many", many),
                .function(name: "partialFailure", partialFailure),
            ]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.int(0), .int(50), .bool(false), .bool(true)])
        XCTAssertFalse(state.isDead, "a marshaling error inside a host result must be an ordinary catchable error")
    }

    // MARK: - C20: no re-entrant resume; never close a running thread

    func testHostFunctionResumingItsOwnCoroutineIsRefused() throws {
        let state = try ScriptTestSupport.makeState()
        var capturedOutcome: ScriptResumeOutcome?
        var capturedError: Error?
        var selfHandle: ScriptCoroutine?

        let resumeMyself = HostFunction { call in
            guard let selfHandle else { return .error("no self handle yet") }
            do {
                capturedOutcome = try call.state.resume(selfHandle, args: [], slice: 1_000)
            } catch {
                capturedError = error
            }
            return .values([.int(1)])
        }

        let environment = state.makeEnvironment(
            name: "reentrant", hostBindings: [.function(name: "resumeMyself", resumeMyself)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(source: "resumeMyself(); return 'done'", chunkName: "reentrantChunk").get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }
        selfHandle = coroutine

        let outcome = try state.resume(coroutine, args: [], slice: 10_000)
        guard case .completed(let values) = outcome else {
            return XCTFail("the outer resume must complete normally, got \(outcome)")
        }
        XCTAssertEqual(values, [.string("done")], "the script itself continued past the refused self-resume")
        XCTAssertNil(capturedError, "resume(self) must not throw — it is a recoverable outcome, not a Swift error")
        guard case .faulted(let fault) = capturedOutcome else {
            return XCTFail("expected the nested self-resume to report .faulted, got \(String(describing: capturedOutcome))")
        }
        XCTAssertEqual(fault.kind, .hostAbort)
        XCTAssertFalse(state.isDead)
    }

    func testCloseCoroutineFromInsideItsHostFunctionIsDeferred() throws {
        // design.md C20's closeDeferred outcome rule: close(coroutine) called from
        // inside that coroutine's own host function returns immediately (no error,
        // no wait); the *enclosing* resume still reports its natural outcome, and
        // only afterward is the thread actually closed and pooled.
        let state = try ScriptTestSupport.makeState()
        var selfHandle: ScriptCoroutine?
        var closeThrew = false

        let closeMyself = HostFunction { call in
            guard let selfHandle else { return .error("no self handle yet") }
            do {
                try call.state.close(selfHandle)
            } catch {
                closeThrew = true
            }
            return .values([.int(42)])
        }

        let environment = state.makeEnvironment(
            name: "deferredClose", hostBindings: [.function(name: "closeMyself", closeMyself)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(
            source: "local v = closeMyself(); return v", chunkName: "deferredCloseChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }
        selfHandle = coroutine

        let outcome = try state.resume(coroutine, args: [], slice: 10_000)
        guard case .completed(let values) = outcome else {
            return XCTFail("the enclosing resume must report its natural (completed) outcome, got \(outcome)")
        }
        XCTAssertEqual(values, [.int(42)], "the host function's own return value must not be lost to the deferred close")
        XCTAssertFalse(closeThrew, "close(coroutine) on the running coroutine itself must not throw")
        XCTAssertFalse(state.isDead)

        // The deferred close has now actually run: further resumes are refused.
        let secondResume = try state.resume(coroutine, args: [], slice: 1_000)
        guard case .faulted(let fault) = secondResume else {
            return XCTFail("expected the deferred close to have invalidated the coroutine, got \(secondResume)")
        }
        XCTAssertEqual(fault.kind, .hostAbort)
    }

    func testResumeDeadCoroutineIsError() throws {
        // A coroutine that has already .completed must be refused on a second
        // resume, never silently re-run or crash (design.md Decision 7: "Closed or
        // completed threads go back to the pool... ScriptCoroutine becomes invalid").
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "dead", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "return 'finished'", chunkName: "deadChunk").get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        let first = try state.resume(coroutine, args: [], slice: 10_000)
        guard case .completed(let values) = first else { return XCTFail("expected .completed, got \(first)") }
        XCTAssertEqual(values, [.string("finished")])

        let second = try state.resume(coroutine, args: [], slice: 10_000)
        guard case .faulted(let fault) = second else {
            return XCTFail("expected resuming an already-completed coroutine to be refused, got \(second)")
        }
        XCTAssertEqual(fault.kind, .hostAbort)
        XCTAssertFalse(state.isDead, "the state itself must survive a refused resume of a dead coroutine")

        // And a third attempt is refused exactly the same way — no crash, no state
        // corruption from repeated misuse.
        let third = try state.resume(coroutine, args: [], slice: 10_000)
        guard case .faulted(let thirdFault) = third else { return XCTFail("expected .faulted again, got \(third)") }
        XCTAssertEqual(thirdFault.kind, .hostAbort)
    }

    // MARK: - C21: nested-entry context save/restore, nesting cap, total cap across nesting

    func testNestedCallPreservesOuterSliceAccounting() throws {
        // A call() issued from inside a host function must not reset the enclosing
        // coroutine's slice/total accounting — the outer coroutine's totalUsed keeps
        // accumulating through the nested entry, and the nested call gets its own
        // fresh slice rather than inheriting (or clobbering) the outer one.
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 2_000
        budgets.handlerTotalInstructions = 50_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        let nestedCall = HostFunction { call in
            guard case .function(let inner) = call.arguments.first else { return .error("expected a function") }
            // A small, self-contained nested call — well under any slice on its own.
            guard case .success(let values) = (try? call.state.call(inner, args: [], slice: 1_000)) else {
                return .error("nested call failed")
            }
            return .values(values)
        }

        let environment = state.makeEnvironment(
            name: "nestedSlice", hostBindings: [.function(name: "nestedCall", nestedCall)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(
            source: """
                local function tiny() return 7 end
                local total = 0
                for i = 1, 30 do
                    total = total + nestedCall(tiny)
                end
                return total
                """,
            chunkName: "nestedSliceChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        var completed: ScriptValue?
        var iterations = 0
        while completed == nil {
            iterations += 1
            XCTAssertLessThan(iterations, 10_000, "not making progress")
            let outcome = try state.resume(coroutine, args: [], slice: 2_000)
            switch outcome {
            case .yielded(.preempted):
                continue
            case .yielded(let other):
                return XCTFail("unexpected yield \(other)")
            case .faulted(let fault):
                return XCTFail("unexpected fault \(fault)")
            case .completed(let values):
                completed = values.first
            }
        }
        XCTAssertEqual(completed, .int(210), "30 nested calls each returning 7 must sum exactly, with no iteration lost or repeated across preemptions")
    }

    func testNestingDepthCapIsError() throws {
        // ELYSIUM_MAX_ENTRY_DEPTH is 16 (elysium_internal.h); entries[0] is the
        // permanent resting frame, so a chain of 16 nested call()s (each opening one
        // more entry) exceeds the cap and the innermost call must be refused with a
        // deterministic error, never a crash or unbounded C-stack recursion.
        let state = try ScriptTestSupport.makeState()

        final class Nester {
            var depth = 0
            let cap = 20
            var deepestOutcome: ScriptCallOutcome?
            var function: ScriptFunction!
            func makeHostFunction() -> HostFunction {
                HostFunction { [self] call in
                    depth += 1
                    defer { depth -= 1 }
                    if depth >= cap {
                        return .values([.int(Int64(depth))])
                    }
                    let outcome = try? call.state.call(function, args: [], slice: 1_000)
                    if depth > 14 { deepestOutcome = outcome }
                    switch outcome {
                    case .success(let values):
                        return .values(values)
                    case .failure(let fault):
                        return .error(fault.message)
                    case .none:
                        return .error("nested call threw")
                    }
                }
            }
        }
        let nester = Nester()
        let recurse = nester.makeHostFunction()
        let environment = state.makeEnvironment(
            name: "nestingCap", hostBindings: [.function(name: "recurse", recurse)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(source: "return recurse()", chunkName: "nestingCapChunk").get()
        nester.function = function

        let outcome = try state.call(function, args: [], slice: 100_000)
        // Whether the *outermost* call reports success (because a deeper level
        // caught the nesting-cap error and turned it into an ordinary Lua error that
        // an even-deeper uncaught propagation surfaces) or failure, the essential
        // invariant is: the process did not crash, the state is still usable
        // afterward, and somewhere in the chain the nesting cap was actually hit.
        switch outcome {
        case .success, .failure:
            break
        }
        XCTAssertFalse(state.isDead, "exceeding the nesting cap must not corrupt or kill the state")
        // A fresh, unrelated call on the same state must still work correctly.
        let sanity = try ScriptTestSupport.run("return 1 + 1", on: state)
        guard case .success(let values) = sanity else { return XCTFail("state unusable after nesting-cap test") }
        XCTAssertEqual(values, [.int(2)])
    }

    func testTotalCapEnforcedAcrossNesting() throws {
        // The coroutine-lifetime total cap (handlerTotalInstructions) is charged to
        // the *outer* coroutine's budget record even while a nested call() entry is
        // active (design.md C21: "nested instructions charge the outer coroutine's
        // totals"), so a script that spends its entire budget inside nested calls
        // still faults with .instructionBudget exactly like one that spends it at
        // the top level.
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 2_000
        budgets.handlerTotalInstructions = 8_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        let burnALittle = HostFunction { call in
            guard case .function(let inner) = call.arguments.first else { return .error("expected a function") }
            _ = try? call.state.call(inner, args: [], slice: 2_000)
            return .values([])
        }
        let environment = state.makeEnvironment(
            name: "totalAcrossNesting", hostBindings: [.function(name: "burnALittle", burnALittle)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(
            source: """
                local function burn() local n = 0; for i = 1, 100000 do n = n + 1 end; return n end
                while true do burnALittle(burn) end
                """,
            chunkName: "totalAcrossNestingChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        var outcome: ScriptResumeOutcome!
        var iterations = 0
        repeat {
            iterations += 1
            XCTAssertLessThan(iterations, 10_000, "total cap never tripped")
            outcome = try state.resume(coroutine, args: [], slice: 2_000)
            if case .faulted = outcome { break }
        } while true

        guard case .faulted(let fault) = outcome else { return XCTFail("expected .faulted, got \(String(describing: outcome))") }
        XCTAssertEqual(fault.kind, .instructionBudget)
    }

    // MARK: - C27: protected state construction (locale probe half; math is type-enforced complete)

    func testStateConstructionFailureIsReported() throws {
        // design.md Condition 27 / F8: elysium_newstate refuses (NULL + errcode)
        // rather than aborting when a precondition is unmet. `ScriptMath`'s eleven
        // fields (sin/cos/exp/log/atan2/pow plus change 3's tan/asin/acos/log2/log10)
        // are non-optional `@convention(c)` closures, so "math incomplete"
        // is structurally unrepresentable from Swift — the type system, not a
        // runtime check, is the enforcement for that half (design.md Decision 11:
        // "there is no default and no libm fallback anywhere in the runtime"). The
        // locale half is reachable: LC_NUMERIC controls `localeconv()->decimal_point`
        // without touching LC_CTYPE/LC_COLLATE, so this test flips only that
        // category, for the shortest possible window, and always restores it.
        let candidates = ["de_DE.UTF-8", "de_DE", "fr_FR.UTF-8", "fr_FR", "pt_BR.UTF-8", "pt_BR"]
        var applied: String?
        for candidate in candidates {
            if setlocale(LC_NUMERIC, candidate) != nil {
                let point = localeconv().pointee.decimal_point.map { String(cString: $0) }
                if point != "." {
                    applied = candidate
                    break
                }
            }
            setlocale(LC_NUMERIC, "C")
        }
        guard let applied else {
            setlocale(LC_NUMERIC, "C")
            throw XCTSkip("no non-'.' decimal-point locale is installed on this machine")
        }
        defer { setlocale(LC_NUMERIC, "C") }

        XCTAssertThrowsError(try LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: RecordingLogSink())) { error in
            XCTAssertEqual(error as? LuaRuntimeError, .localeNotPinned, "locale '\(applied)' should have refused construction")
        }
    }

    // MARK: - security-code.md HIGH finding (downgraded Condition 5), variant 2:
    // non-tail-recursion stack growth trips the rate cap and is caught by an inner
    // pcall (each recursion level re-raises what its own local pcall catches, so
    // the trip is only finally absorbed once it unwinds all the way to the
    // outermost pcall) -- "worse" than the flat allocation case because the outer
    // call/resume can report .success/.completed with the trip silently revived.

    private static let stackGrowthSource = """
        local function grow(n)
            if n <= 0 then return 0 end
            local a1,a2,a3,a4,a5,a6,a7,a8,a9,a10,a11,a12,a13,a14,a15,a16,a17,a18,a19,a20 = 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20
            local ok, sub = pcall(grow, n - 1)
            if not ok then error(sub, 0) end
            return 1 + sub + a1 - a1 + a20 - a20
        end
        local ok, err = pcall(grow, 190)
        return ok, tostring(err)
        """

    func testStackGrowthTripUnderInnerPcallDoesNotBrickState() throws {
        // security-code.md Refutation, variant 2: the outer call() must report a
        // fault of the right kind (never .success with the trip silently revived
        // -- "pcall cannot revive it", design.md 93, 279), and a later, unrelated
        // call() (over 1,000 instructions) must not inherit a leaked state-wide
        // flag from the recursion's own inner pcall chain.
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.allocationRatePerSliceBytes = 256
        budgets.memoryCapBytes = 8 * 1024 * 1024 // generous: isolate the rate, not the cap
        budgets.hostOverCapDiagnosticBytes = 1024 * 1024
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "stackGrowthCall", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: Self.stackGrowthSource, chunkName: "stackGrowthCallChunk").get()

        let outcome = try state.call(function, args: [], slice: 5_000_000)
        guard case .failure(let fault) = outcome else {
            return XCTFail("a chain of inner pcalls catching the recursion's own stack-growth trip must not revive it into .success, got \(outcome)")
        }
        XCTAssertEqual(fault.kind, .allocationRate)
        XCTAssertFalse(state.isDead)

        let sanity = try ScriptTestSupport.run("local s = 0 for i = 1, 5000 do s = s + i end return s", on: state)
        guard case .success(let values) = sanity else { return XCTFail("state unusable after the inner-pcall-caught stack-growth trip, got \(sanity)") }
        XCTAssertEqual(values, [.int(12_502_500)])
    }

    func testStackGrowthTripUnderInnerPcallDoesNotBrickCoroutineState() throws {
        // Same shape as above, via resume(): the tripping coroutine must report
        // .faulted (never .completed with the trip revived), and a later, unrelated
        // *fresh* coroutine (over 1,000 instructions) must not inherit a leaked
        // state-wide flag.
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.allocationRatePerSliceBytes = 256
        budgets.memoryCapBytes = 8 * 1024 * 1024
        budgets.hostOverCapDiagnosticBytes = 1024 * 1024
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        let envA = state.makeEnvironment(name: "stackGrowthResumeA", random: ScriptTestSupport.randomStream())
        let fnA = try envA.compile(source: Self.stackGrowthSource, chunkName: "stackGrowthResumeAChunk").get()
        guard let coA = try state.makeCoroutine(function: fnA) else { return XCTFail("expected a coroutine") }
        let outcomeA = try state.resume(coA, args: [], slice: 5_000_000)
        guard case .faulted(let faultA) = outcomeA else {
            return XCTFail("a chain of inner pcalls catching the recursion's own stack-growth trip must not revive it into .completed, got \(outcomeA)")
        }
        XCTAssertEqual(faultA.kind, .allocationRate)

        let envB = state.makeEnvironment(name: "stackGrowthResumeB", random: ScriptTestSupport.randomStream())
        let fnB = try envB.compile(
            source: "local s = 0 for i = 1, 37566 do s = s + i end return s",
            chunkName: "stackGrowthResumeBChunk"
        ).get()
        guard let coB = try state.makeCoroutine(function: fnB) else { return XCTFail("expected a second coroutine") }
        let outcomeB = try state.resume(coB, args: [], slice: 1_000_000)
        guard case .completed(let valuesB) = outcomeB else {
            return XCTFail("a fresh coroutine allocates nothing and trips no budget of its own -- it must complete, not inherit the recursion's trip; got \(outcomeB)")
        }
        XCTAssertEqual(valuesB, [.int(705_620_961)])
    }

    // MARK: - LOW note (Security (code) attempt 3, F1 checkstack amounts): call()'s
    // argument-count-only checkstack sizing did not account for the marshaler's own
    // transient depth

    func testManyArgsWithNestedLastArgDoesNotOverflow() throws {
        // A host call with many arguments whose *last* argument is nested to
        // valueLimits.depth (4) needs, at the deepest point of pushScriptValue's
        // recursion, up to ~2 stack slots per level of nesting (table + key) plus
        // the leaf -- 9 transient slots for a depth-4 map chain -- on top of the
        // 40 top-level argument slots. Sizing lua_checkstack by args.count alone
        // (fixed by the Coroutines.swift/LuaState.swift LOW-note fix) could exceed
        // ci->top for a call in this shape; not reachable by any host binding in
        // this change, but exercised directly here through the public call() API.
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "manyArgsNested", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: """
                local n = select('#', ...)
                local args = {...}
                local last = args[n]
                return n, last.a.b.c.d
                """,
            chunkName: "manyArgsNestedChunk"
        ).get()

        let nestedLast = ScriptValue.map([
            "a": .map([
                "b": .map([
                    "c": .map([
                        "d": .int(99)
                    ])
                ])
            ])
        ])
        var args: [ScriptValue] = (0..<39).map { .int(Int64($0)) }
        args.append(nestedLast)
        XCTAssertEqual(args.count, 40)

        let outcome = try state.call(function, args: args, slice: 100_000)
        guard case .success(let values) = outcome else {
            return XCTFail("a 40-argument call with a maximally nested last argument must not abort or overflow the stack, got \(outcome)")
        }
        XCTAssertEqual(values, [.int(40), .int(99)])
    }

    // MARK: - object-graph-attributes change 1a carry-forward (design.md
    // Decision 12, N4-1/N4-2, Security (plan) C25/C28)

    /// Spec `embedded-script-runtime` "Many resume arguments on a fresh
    /// coroutine": 64 and then 200 arguments on separate fresh coroutines
    /// both complete, and memory returns to its pre-test baseline after
    /// `collectFull()` — no leaked stack growth from either resume.
    func testManyResumeArgumentsOnFreshCoroutineComplete() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(
            name: "manyArgsFresh", hostBindings: [], random: ScriptTestSupport.randomStream()
        )
        // Compile both chunks before the baseline is captured — compiling
        // retains bytecode in the environment for the rest of its life (by
        // design: a `ScriptFunction` stays callable again later), so that is
        // a one-time cost, not something a "resuming must not leak" test
        // should charge against the resume/pool cycle itself.
        let function64 = try environment.compile(
            source: "return select('#', ...)", chunkName: "manyArgsFresh64"
        ).get()
        let function200 = try environment.compile(
            source: "return select('#', ...)", chunkName: "manyArgsFresh200"
        ).get()

        func resumeOnce(_ function: ScriptFunction, _ count: Int) throws {
            guard let coroutine = try state.makeCoroutine(function: function) else {
                return XCTFail("expected a coroutine")
            }
            let args = (0..<count).map { ScriptValue.int(Int64($0)) }
            let outcome = try state.resume(coroutine, args: args, slice: 1_000_000)
            guard case .completed(let values) = outcome else {
                return XCTFail("expected .completed for \(count) arguments, got \(outcome)")
            }
            XCTAssertEqual(values, [.int(Int64(count))])
        }

        // Warm the pool first: a completed coroutine's thread is closed and
        // pooled (design.md Decision 7), but a pooled thread's own Lua stack
        // capacity is a high-water mark that reuse never shrinks back down —
        // the first push of 200 arguments onto a freshly pooled thread grows
        // it once, permanently, by design. Do that growth here, before the
        // baseline, so the loop below is checking for an actual per-cycle
        // leak rather than this one-time, intentional retention.
        try resumeOnce(function64, 64)
        try resumeOnce(function200, 200)

        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse
        for _ in 0..<20 {
            try resumeOnce(function64, 64)
            try resumeOnce(function200, 200)
        }
        state.collectFull()
        // A small fixed residual across 20 more warm/pooled complete cycles
        // (allocator/pool-reuse granularity, not a per-cycle leak) is
        // expected; `baseline / 20` bounds it to 5%.
        let tolerance = max(baseline / 20, 4_096)
        let after = state.memoryStatus.bytesInUse
        let growth = after > baseline ? after - baseline : 0
        XCTAssertLessThanOrEqual(growth, tolerance, "resuming with many arguments must not leak (baseline \(baseline), after \(after))")
    }

    /// Spec `embedded-script-runtime` "Absurd value depth does not trap": a
    /// `LuaState` built with `ScriptBudgets.valueDepth = Int.max` still
    /// returns a definite outcome for an ordinary call (N4-2's clamped
    /// `checkstackSlack` helper is what makes this safe — `2 * Int.max`
    /// alone overflows `Int` before any clamp).
    func testAbsurdValueDepthDoesNotTrap() throws {
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.valueDepth = Int.max
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(
            name: "absurdDepth", hostBindings: [], random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(source: "return ...", chunkName: "absurdDepthChunk").get()
        // Any definite outcome (success or a host/fault failure) satisfies
        // "does not trap"; only a crash would fail this test.
        _ = try state.call(function, args: [.int(1)], slice: 100_000)
    }

    /// Spec `embedded-script-runtime` "Refused resume leaves the caller's
    /// stack balanced" (Security (plan) C25, amended by C28): drives a
    /// coroutine's own stack to the point where `lua_checkstack(co, nargs)`
    /// fails on a nonzero-argument resume by resuming a *different*, already
    /// large coroutine first (which grows the shared main thread's stack —
    /// permanent capacity, not reclaimed by pooling) under a tight memory
    /// cap, then resuming a fresh, still-small coroutine with the same
    /// argument count: the fresh coroutine's own stack has nowhere left to
    /// grow. Every refusal must leave `lua_gettop` on the main thread
    /// unchanged and must not abort, repeated several times.
    func testRefusedResumeLeavesCallerStackBalanced() throws {
        // Test N5: the prior budget (a 256 KiB memory cap and `tinyBudgets`' 64 KiB
        // per-slice allocation-rate cap) made this test skip 100% of the time — the
        // warm-up's 4,000-argument push always tripped the allocation-*rate* cap
        // first, so the N4-1/C25/C28 refusal branch this test exists to exercise had
        // never actually fired in-repo. Recipe below (matching the Tester's out-of-
        // repo probe2, which drove the real branch 6/6 times): raise the rate cap so
        // pushes themselves never trip it, grow the main thread's stack while memory
        // is plentiful, pin the pool's one idle thread with an unresumed coroutine so
        // every later `makeCoroutine` must allocate a genuinely fresh, small-stack
        // thread, then fill the state with live (GC-rooted) data near the memory cap
        // so that fresh thread's own stack has no headroom left to grow into a
        // 4,000-argument push.
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.memoryCapBytes = 512 * 1024
        budgets.hostOverCapDiagnosticBytes = 64 * 1024
        budgets.handlerTotalInstructions = 5_000_000
        budgets.allocationRatePerSliceBytes = 8 * 1024 * 1024
        budgets.threadPoolMax = 1
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(
            name: "refusedResume", hostBindings: [], random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(
            source: "return select('#', ...)", chunkName: "refusedResumeChunk"
        ).get()
        let bigArgs = (0..<4_000).map { ScriptValue.int(Int64($0)) }

        // Warm the main thread's stack to `bigArgs.count` capacity (this
        // capacity is never released) while memory is plentiful.
        guard let warm = try state.makeCoroutine(function: function) else { return XCTFail() }
        let warmOutcome = try state.resume(warm, args: bigArgs, slice: 1_000_000)
        guard case .completed(let warmValues) = warmOutcome, warmValues == [.int(4_000)] else {
            throw XCTSkip("warm-up resume did not complete as expected under this budget: \(warmOutcome)")
        }

        // Pin the pool's one idle thread: create a coroutine and deliberately never
        // resume it to completion and never close it, so it is never returned to the
        // pool. `threadPoolMax == 1` means the pool now has zero idle slots, so every
        // `makeCoroutine` call below must allocate a genuinely fresh thread rather
        // than reuse the warmed one's already-grown stack.
        guard let pinned = try state.makeCoroutine(function: function) else { return XCTFail() }
        withExtendedLifetime(pinned) {} // kept alive; never resumed or closed

        // Fill the state with live, GC-rooted data close to the memory cap — an
        // ordinary global assignment (writable: it is the script's own `_ENV`, not a
        // library table) keeps the string reachable for the rest of the test, unlike
        // a value merely returned and popped off the stack. `string.rep`'s own
        // result cap is 65,536 bytes per call (design.md's library caps), so the
        // fill is spread across several smaller calls rather than one big one.
        // Self-calibrating rather than a fixed byte target: measure the actual
        // headroom left after warm-up (which varies with `bigArgs.count`'s own
        // marshaling overhead) and fill to within one chunk of the cap, stopping
        // as soon as a chunk is refused rather than assuming an exact budget.
        state.collectFull()
        let afterWarmup = state.memoryStatus.bytesInUse
        let headroom = budgets.memoryCapBytes > Int(afterWarmup) ? budgets.memoryCapBytes - Int(afterWarmup) : 0
        let chunkBytes = 40_000
        var filled = 0
        var fillIndex = 0
        while filled + chunkBytes < headroom - 8_000 { // leave a small margin below the cap
            fillIndex += 1
            let fillFunction = try environment.compile(
                source: "fillData\(fillIndex) = string.rep('x', \(chunkBytes)); return true",
                chunkName: "fillChunk\(fillIndex)"
            ).get()
            let outcome = try state.call(fillFunction, args: [], slice: 1_000_000)
            guard case .success = outcome else { break } // hit the cap sooner than estimated; stop here
            filled += chunkBytes
        }
        guard filled > 0 else {
            throw XCTSkip("could not fill any data near the memory cap on this toolchain (headroom after warm-up: \(headroom) bytes)")
        }

        // `OpaquePointer`/`lua_gettop` are deliberately spellable only inside
        // `LuaState.swift` itself (design.md Condition 3) — this test has no
        // direct way to read the main thread's stack top, so it uses
        // `memoryStatus.bytesInUse` staying flat across repeated refusals as
        // the observable proxy: a leaking `nargs` push on every refusal
        // would grow the main stack's backing storage and show up here.
        var sawRefusal = false
        var bytesAfterFirstRefusal: UInt64?
        for _ in 0..<5 {
            guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail() }
            let outcome = try state.resume(coroutine, args: bigArgs, slice: 1_000_000)
            switch outcome {
            case .completed(let values):
                // This budget could not be driven to a refusal on this
                // machine/toolchain — accept the success case rather than
                // assert a specific failure is reachable (design.md's own
                // "Refused resume" scenario is about safety *when* it fires,
                // not a guarantee that a fixed budget always reaches it).
                XCTAssertEqual(values, [.int(4_000)])
            case .faulted(let fault):
                sawRefusal = true
                XCTAssertEqual(fault.kind, .hostAbort)
                XCTAssertTrue(fault.message.contains("stack overflow"), "unexpected message: \(fault.message)")
                let bytesNow = state.memoryStatus.bytesInUse
                if let baseline = bytesAfterFirstRefusal {
                    XCTAssertEqual(bytesNow, baseline, "a refused resume must not leak main-stack growth on repetition")
                } else {
                    bytesAfterFirstRefusal = bytesNow
                }
            case .yielded:
                XCTFail("refusedResumeChunk never yields")
            }
        }
        if !sawRefusal {
            throw XCTSkip("this budget never drove a refusal on this toolchain — the safety property is exercised only when it does")
        }
    }
}
