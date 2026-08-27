// MarshalingTests.swift — task 6.1/6.4. design.md Decision 10 (ScriptValue,
// marshaling and handles) and spec "ScriptValue marshaling with caps" / "Sparse table
// rejected" / "Caps enforced", plus Condition 30's cross-state and destroyed-
// environment refusals.

import ElysiumCore
import ElysiumScript
import XCTest

final class MarshalingTests: XCTestCase {
    /// Pushes `value` as the sole argument to `identity(x) return x end` and pulls
    /// the result back -- a genuine Swift -> Lua -> Swift round trip through the
    /// real marshaler in both directions (design.md Decision 10 / Condition 26
    /// discipline).
    private func roundTrip(_ value: ScriptValue, on state: LuaState, budgets: ScriptBudgets = .defaults) throws -> ScriptCallOutcome {
        let environment = state.makeEnvironment(name: "roundTrip-\(UUID().uuidString)", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "local function identity(x) return x end; return identity(...)", chunkName: "identityChunk").get()
        return try state.call(function, args: [value], slice: 1_000_000)
    }

    // MARK: - list / map / empty / mixed / depth / nodes round trip

    func testListRoundTrip() throws {
        // .null cannot appear as a genuine list element: assigning nil to a Lua
        // table key removes it (a trailing nil shortens the array; an interior nil
        // would create a hole, which the pull-side classifier correctly rejects as
        // sparse) -- so a round-trippable list never contains .null.
        let state = try ScriptTestSupport.makeState()
        let value = ScriptValue.list([.int(1), .string("a"), .bool(true), .number(2.5)])
        guard case .success(let values) = try roundTrip(value, on: state) else { return XCTFail("expected success") }
        XCTAssertEqual(values, [value])
    }

    func testMapRoundTrip() throws {
        let state = try ScriptTestSupport.makeState()
        let value = ScriptValue.map(["a": .int(1), "b": .string("x"), "c": .bool(false)])
        guard case .success(let values) = try roundTrip(value, on: state) else { return XCTFail("expected success") }
        XCTAssertEqual(values, [value])
    }

    func testEmptyTableRoundTripsAsEmptyList() throws {
        // spec: "the empty table is an empty list" -- an empty Lua table has no
        // string keys and no integer keys, so the classifier always resolves it as
        // `.list([])`, even when the *original* Swift value pushed was `.map([:])`.
        let state = try ScriptTestSupport.makeState()
        guard case .success(let listResult) = try roundTrip(.list([]), on: state) else { return XCTFail("expected success") }
        XCTAssertEqual(listResult, [.list([])])
        guard case .success(let mapResult) = try roundTrip(.map([:]), on: state) else { return XCTFail("expected success") }
        XCTAssertEqual(mapResult, [.list([])], "an empty map pushed to Lua must round-trip as an empty list, not an empty map")
    }

    func testSparseTableRejected() throws {
        // spec "Sparse table rejected"
        let state = try ScriptTestSupport.makeState()
        var captured: [ScriptArgument] = []
        let take = HostFunction { call in
            captured = call.arguments
            return .values([])
        }
        let outcome = try ScriptTestSupport.run(
            "local ok, err = pcall(take, {[1]=1,[3]=3}); return ok, err", on: state,
            hostBindings: [.function(name: "take", take)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false), "a sparse table must be a deterministic error, never marshaled")
        guard case .string(let message) = values[1] else { return XCTFail() }
        XCTAssertTrue(message.contains("sparse") || message.contains("mixed"), message)
        XCTAssertTrue(captured.isEmpty, "the host function must never have run")
    }

    func testMixedKeyTableRejected() throws {
        let state = try ScriptTestSupport.makeState()
        let take = HostFunction { _ in .values([]) }
        let outcome = try ScriptTestSupport.run(
            "local ok, err = pcall(take, {[1]='a', foo='bar'}); return ok, err", on: state,
            hostBindings: [.function(name: "take", take)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false))
        guard case .string(let message) = values[1] else { return XCTFail() }
        XCTAssertTrue(message.contains("sparse") || message.contains("mixed"), message)
    }

    func testDepthCapEnforced() throws {
        // spec "Caps enforced": a 5-deep nesting is refused (default cap is 4).
        let state = try ScriptTestSupport.makeState()
        let take = HostFunction { _ in .values([]) }
        let outcome = try ScriptTestSupport.run(
            """
            local t = {1}
            for i = 1, 5 do t = {t} end
            local ok, err = pcall(take, t)
            return ok, err
            """, on: state, hostBindings: [.function(name: "take", take)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false))
        guard case .string(let message) = values[1] else { return XCTFail() }
        XCTAssertTrue(message.contains("depth"), message)
    }

    func testNodesCapEnforced() throws {
        var budgets = ScriptBudgets.defaults
        // Shrink the node cap so the test does not need to build 1,025 real values.
        budgets.valueNodes = 20
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let take = HostFunction { _ in .values([]) }
        let outcome = try ScriptTestSupport.run(
            """
            local t = {}
            for i = 1, 25 do t[i] = i end
            local ok, err = pcall(take, t)
            return ok, err
            """, on: state, hostBindings: [.function(name: "take", take)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false))
        guard case .string(let message) = values[1] else { return XCTFail() }
        XCTAssertTrue(message.contains("node") || message.contains("20"), message)
    }

    func testListAndMapCountCaps() throws {
        // spec "Caps enforced": a 257-element list and a 65-key map are refused.
        let state = try ScriptTestSupport.makeState()
        let take = HostFunction { _ in .values([]) }
        let outcome = try ScriptTestSupport.run(
            """
            local list = {}
            for i = 1, 257 do list[i] = i end
            local listOk, listErr = pcall(take, list)

            local map = {}
            for i = 1, 65 do map['k' .. i] = i end
            local mapOk, mapErr = pcall(take, map)

            return listOk, tostring(listErr), mapOk, tostring(mapErr)
            """, on: state, hostBindings: [.function(name: "take", take)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false))
        guard case .string(let listErr) = values[1] else { return XCTFail() }
        XCTAssertTrue(listErr.contains("256"), listErr)
        XCTAssertEqual(values[2], .bool(false))
        guard case .string(let mapErr) = values[3] else { return XCTFail() }
        XCTAssertTrue(mapErr.contains("64"), mapErr)
    }

    // MARK: - String cap on push and pull

    func testStringTooLongOnPushAndPull() throws {
        let state = try ScriptTestSupport.makeState()
        // Pull direction: a Lua string over the cap, passed to a host function.
        let take = HostFunction { _ in .values([]) }
        let pullOutcome = try ScriptTestSupport.run(
            "local ok, err = pcall(take, ('x'):rep(5000)); return ok, tostring(err)", on: state,
            hostBindings: [.function(name: "take", take)]
        )
        guard case .success(let values) = pullOutcome else { return XCTFail("expected success, got \(pullOutcome)") }
        XCTAssertEqual(values[0], .bool(false))
        guard case .string(let message) = values[1] else { return XCTFail() }
        XCTAssertTrue(message.contains("4096"), message)

        // Push direction: a host function tries to return an over-cap string.
        let overLong = String(repeating: "y", count: 5000)
        let pushOutcome = try ScriptTestSupport.run(
            "local ok, err = pcall(giveBig); return ok, tostring(err)", on: state,
            hostBindings: [.function(name: "giveBig", HostFunction { _ in .values([.string(overLong)]) })]
        )
        guard case .success(let values2) = pushOutcome else { return XCTFail("expected success, got \(pushOutcome)") }
        XCTAssertEqual(values2[0], .bool(false))
        guard case .string(let message2) = values2[1] else { return XCTFail() }
        XCTAssertTrue(message2.contains("4096"), message2)
    }

    func testMapKeysCannotBypassTheStringByteCapOnPushOrPull() throws {
        var budgets = ScriptBudgets.defaults
        budgets.valueStringBytes = 64
        let state = try ScriptTestSupport.makeState(budgets: budgets)

        var hostWasCalled = false
        let pullOutcome = try ScriptTestSupport.run(
            "local k = ('x'):rep(65); local ok, err = pcall(take, {[k] = 1}); return ok, tostring(err)",
            on: state,
            hostBindings: [.function(name: "take", HostFunction { _ in
                hostWasCalled = true
                return .values([])
            })]
        )
        guard case .success(let pullValues) = pullOutcome else {
            return XCTFail("expected caught pull failure, got \(pullOutcome)")
        }
        XCTAssertEqual(pullValues[0], .bool(false))
        guard case .string(let pullMessage) = pullValues[1] else { return XCTFail() }
        XCTAssertTrue(pullMessage.contains("64"), pullMessage)
        XCTAssertFalse(hostWasCalled, "an oversized map key must be refused before host dispatch")

        let oversizedKey = String(repeating: "y", count: 65)
        let pushOutcome = try ScriptTestSupport.run(
            "local ok, err = pcall(giveMap); return ok, tostring(err)", on: state,
            hostBindings: [.function(name: "giveMap", HostFunction { _ in
                .values([.map([oversizedKey: .int(1)])])
            })]
        )
        guard case .success(let pushValues) = pushOutcome else {
            return XCTFail("expected caught push failure, got \(pushOutcome)")
        }
        XCTAssertEqual(pushValues[0], .bool(false))
        guard case .string(let pushMessage) = pushValues[1] else { return XCTFail() }
        XCTAssertTrue(pushMessage.contains("64"), pushMessage)
    }

    // MARK: - Invalid UTF-8 is decoded with repair, never crashes or throws

    func testInvalidUTF8DecodedWithRepair() throws {
        let state = try ScriptTestSupport.makeState()
        var captured: String?
        let take = HostFunction { call in
            guard case .value(.string(let s)) = call.arguments.first else { return .error("expected a string") }
            captured = s
            return .values([])
        }
        // string.char(255, 254) is two bytes that are not valid UTF-8 on their own.
        let outcome = try ScriptTestSupport.run(
            "take(string.char(255, 254))", on: state, hostBindings: [.function(name: "take", take)]
        )
        guard case .success = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertNotNil(captured)
        XCTAssertTrue(captured?.contains("\u{FFFD}") == true, "invalid UTF-8 must decode with U+FFFD repair, got \(String(describing: captured))")
    }

    // MARK: - NaN / -0 / int-float distinction

    func testNaNRefusedOnPushAndPull() throws {
        let state = try ScriptTestSupport.makeState()
        // Push direction.
        let outcome1 = try ScriptTestSupport.run(
            "local ok, err = pcall(giveNaN); return ok, tostring(err)", on: state,
            hostBindings: [.function(name: "giveNaN", HostFunction { _ in .values([.number(.nan)]) })]
        )
        guard case .success(let values1) = outcome1 else { return XCTFail("expected success, got \(outcome1)") }
        XCTAssertEqual(values1[0], .bool(false))
        guard case .string(let message1) = values1[1] else { return XCTFail() }
        XCTAssertTrue(message1.contains("finite"), message1)

        // Pull direction: 0/0 computed inside the script.
        let take = HostFunction { _ in .values([]) }
        let outcome2 = try ScriptTestSupport.run(
            "local ok, err = pcall(take, 0/0); return ok, tostring(err)", on: state,
            hostBindings: [.function(name: "take", take)]
        )
        guard case .success(let values2) = outcome2 else { return XCTFail("expected success, got \(outcome2)") }
        XCTAssertEqual(values2[0], .bool(false))
        guard case .string(let message2) = values2[1] else { return XCTFail() }
        XCTAssertTrue(message2.contains("finite"), message2)
    }

    func testNegativeZeroNormalizedToZero() throws {
        let state = try ScriptTestSupport.makeState()
        guard case .success(let values) = try roundTrip(.number(-0.0), on: state) else { return XCTFail("expected success") }
        guard case .number(let d) = values.first else { return XCTFail("expected a .number result") }
        XCTAssertEqual(d, 0.0)
        XCTAssertFalse(d.sign == .minus, "-0.0 must be normalized to +0.0 on push")
    }

    func testIntFloatDistinctionRoundTrips() throws {
        let state = try ScriptTestSupport.makeState()
        guard case .success(let intResult) = try roundTrip(.int(5), on: state) else { return XCTFail("expected success") }
        XCTAssertEqual(intResult, [.int(5)], "an integer must round-trip as .int, not .number")

        guard case .success(let floatResult) = try roundTrip(.number(5.0), on: state) else { return XCTFail("expected success") }
        XCTAssertEqual(floatResult, [.number(5.0)], "a float with an integral value must still round-trip as .number, not .int")
    }

    // MARK: - .ref resolves through the handle resolver, nil when unknown

    func testUnknownRefResolvesToNull() throws {
        let state = try ScriptTestSupport.makeState()
        guard case .success(let values) = try roundTrip(.ref("no-such-handle"), on: state) else { return XCTFail("expected success") }
        XCTAssertEqual(values, [.null], "an unresolved .ref must push as nil and pull back as .null")
    }

    // MARK: - Function argument via ScriptArgument.function

    func testFunctionArgumentIsCallableBack() throws {
        let state = try ScriptTestSupport.makeState()
        var capturedFunction: ScriptFunction?
        let take = HostFunction { call in
            guard case .function(let fn) = call.arguments.first else { return .error("expected a function argument") }
            capturedFunction = fn
            return .values([])
        }
        let outcome = try ScriptTestSupport.run(
            "take(function(x) return x * 10 end)", on: state, hostBindings: [.function(name: "take", take)]
        )
        guard case .success = outcome else { return XCTFail("expected success, got \(outcome)") }
        guard let fn = capturedFunction else { return XCTFail("expected a captured ScriptFunction") }
        guard case .success(let values) = try state.call(fn, args: [.int(7)], slice: 10_000) else {
            return XCTFail("expected the captured function to be callable")
        }
        XCTAssertEqual(values, [.int(70)])
    }

    // MARK: - Cross-state objects refused (Condition 30)

    func testCrossStateObjectsRefused() throws {
        let stateA = try ScriptTestSupport.makeState()
        let stateB = try ScriptTestSupport.makeState()

        let environmentA = stateA.makeEnvironment(name: "a", random: ScriptTestSupport.randomStream())
        let functionA = try environmentA.compile(source: "return 1", chunkName: "aChunk").get()

        XCTAssertThrowsError(try stateB.call(functionA, args: [], slice: 1_000)) { error in
            XCTAssertEqual(error as? LuaRuntimeError, .stateMismatch)
        }
        XCTAssertThrowsError(try stateB.makeCoroutine(function: functionA)) { error in
            XCTAssertEqual(error as? LuaRuntimeError, .stateMismatch)
        }

        guard let coroutineA = try stateA.makeCoroutine(function: functionA) else { return XCTFail("expected a coroutine") }
        XCTAssertThrowsError(try stateB.resume(coroutineA, args: [], slice: 1_000)) { error in
            XCTAssertEqual(error as? LuaRuntimeError, .stateMismatch)
        }
        XCTAssertThrowsError(try stateB.close(coroutineA)) { error in
            XCTAssertEqual(error as? LuaRuntimeError, .stateMismatch)
        }

        let dispatchA = HandleDispatch()
        let kindA = stateA.registerHandleKind(name: "crossKind", dispatch: dispatchA, interned: false)
        XCTAssertThrowsError(try stateB.makeHandle(kind: kindA, ref: "x", id: 1)) { error in
            XCTAssertEqual(error as? LuaRuntimeError, .stateMismatch)
        }

        // stateA itself must remain perfectly usable throughout.
        guard case .success(let values) = try stateA.call(functionA, args: [], slice: 1_000) else {
            return XCTFail("stateA must remain usable after every cross-state refusal")
        }
        XCTAssertEqual(values, [.int(1)])
    }

    // MARK: - F1 (test.md defect): a failed argument push must not leak partially
    // built nested tables onto the main thread's own Lua stack

    func testFailedCallArgPushDoesNotLeakMainStack() throws {
        // Reproduction from test.md's F1 finding: a depth-5 nested list exceeds
        // the default depth cap of 4, so pushScriptValue always throws partway
        // through building the nested tables -- before the fix, `call`'s catch
        // popped only the *completed* top-level arguments (zero, here, since the
        // sole argument itself is the one that fails), leaving every nested table
        // pushScriptValue had already created on the main stack. 20 repeats used
        // to abort a debug build (LUAI_ASSERT "stack overflow") well before the
        // 20th, and overrun past ci->top in a release build.
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "callLeakGuard", random: ScriptTestSupport.randomStream())
        let identity = try environment.compile(source: "return ...", chunkName: "callLeakGuardChunk").get()
        let depth5: ScriptValue = .list([.list([.list([.list([.list([.int(1)])])])])])

        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse

        for _ in 0..<20 {
            let outcome = try state.call(identity, args: [depth5], slice: 1_000)
            guard case .failure(let fault) = outcome else {
                return XCTFail("expected the over-depth argument to be refused, got \(outcome)")
            }
            XCTAssertEqual(fault.kind, .hostAbort)
        }

        state.collectFull()
        XCTAssertLessThanOrEqual(
            state.memoryStatus.bytesInUse, baseline + 2048,
            "20 failed argument pushes must not leave partially built tables reachable from the main stack"
        )

        // The state must still be perfectly usable -- not merely "did not crash".
        let sanity = try state.call(identity, args: [.int(7)], slice: 1_000)
        guard case .success(let values) = sanity else { return XCTFail("state unusable after repeated failed pushes") }
        XCTAssertEqual(values, [.int(7)])
    }

    func testFailedResumeArgPushDoesNotLeakMainStack() throws {
        // Reproduction from test.md's F1 finding: a NaN nested one level deep --
        // pushScriptValue builds the outer list's table before the inner NaN
        // throws .notFinite. The coroutine itself is reused across all 20
        // attempts: every failure happens *before* elysium_resume is ever called
        // (the argument push runs on the main thread, ahead of the coroutine
        // move), so the coroutine is never started and remains perfectly valid
        // to try again.
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "resumeLeakGuard", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "return ...", chunkName: "resumeLeakGuardChunk").get()
        guard let coroutine = try state.makeCoroutine(function: function) else {
            return XCTFail("expected a coroutine")
        }
        let nanPayload: ScriptValue = .list([.int(1), .list([.int(2), .number(.nan)])])

        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse

        for _ in 0..<20 {
            let outcome = try state.resume(coroutine, args: [nanPayload], slice: 1_000)
            guard case .faulted(let fault) = outcome else {
                return XCTFail("expected the NaN argument to be refused, got \(outcome)")
            }
            XCTAssertEqual(fault.kind, .hostAbort)
        }

        state.collectFull()
        XCTAssertLessThanOrEqual(
            state.memoryStatus.bytesInUse, baseline + 2048,
            "20 failed resume argument pushes must not leave partially built tables reachable from the main stack"
        )

        // The coroutine was never actually started -- a real resume must still work.
        let sanity = try state.resume(coroutine, args: [.int(9)], slice: 1_000)
        guard case .completed(let values) = sanity else { return XCTFail("coroutine unusable after repeated failed pushes") }
        XCTAssertEqual(values, [.int(9)])
    }

    // MARK: - N2 (test.md note): the push side enforces the same 1,024-node cap
    // as the pull side

    func testNodesCapEnforcedOnPush() throws {
        // The push-side counterpart of testNodesCapEnforced above: before the fix,
        // pushScriptValue never counted nodes at all, so a host function could
        // return an over-cap value the pull side would have refused.
        var budgets = ScriptBudgets.defaults
        budgets.valueNodes = 20
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        var big: [ScriptValue] = []
        for i in 0..<25 { big.append(.int(Int64(i))) }
        let giveBig = HostFunction { _ in .values([.list(big)]) }
        let outcome = try ScriptTestSupport.run(
            "local ok, err = pcall(giveBig); return ok, tostring(err)", on: state,
            hostBindings: [.function(name: "giveBig", giveBig)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false), "an over-cap list returned from a host function must be refused, not silently accepted")
        guard case .string(let message) = values[1] else { return XCTFail() }
        XCTAssertTrue(message.contains("node") || message.contains("20"), message)
    }

    // MARK: - Destroyed environment refuses further calls (Condition 30)

    func testDestroyedEnvironmentRefusesCalls() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "toDestroy", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "return 42", chunkName: "toDestroyChunk").get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        environment.destroy()

        // compile() on the destroyed environment is refused.
        let recompile = environment.compile(source: "return 1", chunkName: "afterDestroy")
        guard case .failure(let compileFault) = recompile else { return XCTFail("expected compile to fail after destroy") }
        XCTAssertEqual(compileFault.kind, .compile)
        XCTAssertTrue(compileFault.message.contains("destroyed"), compileFault.message)

        // A function/coroutine produced *before* destroy is refused deterministically.
        let callOutcome = try state.call(function, args: [], slice: 1_000)
        guard case .failure(let callFault) = callOutcome else { return XCTFail("expected call to fail after environment destroy") }
        XCTAssertEqual(callFault.kind, .hostAbort)

        let resumeOutcome = try state.resume(coroutine, args: [], slice: 1_000)
        guard case .faulted(let resumeFault) = resumeOutcome else { return XCTFail("expected resume to fault after environment destroy") }
        XCTAssertEqual(resumeFault.kind, .hostAbort)

        // destroy() is idempotent.
        environment.destroy()
        XCTAssertFalse(state.isDead, "the state itself must remain usable after an environment is destroyed")
        let sanity = try ScriptTestSupport.run("return 'still alive'", on: state)
        guard case .success(let values) = sanity else { return XCTFail("state unusable after environment destroy") }
        XCTAssertEqual(values, [.string("still alive")])
    }
}
