// LuaStateSmokeTests.swift — task 3.1-3.7's own behavioural proof (Lane C). Lane E's
// exhaustive suites (BoundaryTests, BudgetTests, MemoryTests, ...) cover every
// scenario in design.md's Risk-to-Test Map; this file's job is narrower and more
// literal: prove the binding actually works end to end, one behavior per test, with
// content assertions (never mere "it didn't crash").

import ElysiumCore
import ElysiumScript
import XCTest

final class LuaStateSmokeTests: XCTestCase {
    // MARK: - State creation

    func testStateCreationAndClose() throws {
        let state = try ScriptTestSupport.makeState()
        XCTAssertFalse(state.isDead)
        XCTAssertEqual(state.memoryStatus.tripped, false)
        try state.close()
        XCTAssertTrue(state.isDead)
    }

    // MARK: - Compile and run a chunk

    func testCompileAndRunChunk() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run("return 1 + 2, 'hi' .. '!'", on: state)
        guard case .success(let values) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(values, [.int(3), .string("hi!")])
    }

    // MARK: - Host function: values, error, yield

    func testHostFunctionReturnsValues() throws {
        let state = try ScriptTestSupport.makeState()
        let add = HostFunction { call in
            guard case .value(.int(let a)) = call.arguments[0], case .value(.int(let b)) = call.arguments[1] else {
                return .error("expected two integers")
            }
            return .values([.int(a + b)])
        }
        let outcome = try ScriptTestSupport.run(
            "return add(2, 3)", on: state, hostBindings: [.function(name: "add", add)]
        )
        guard case .success(let values) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(values, [.int(5)])
    }

    func testHostFunctionErrorIsCatchableAndStateStaysUsable() throws {
        let state = try ScriptTestSupport.makeState()
        let fail = HostFunction { _ in .error("always fails") }
        let outcome = try ScriptTestSupport.run(
            "local ok, err = pcall(fail); return ok, err",
            on: state, hostBindings: [.function(name: "fail", fail)]
        )
        guard case .success(let values) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(values, [.bool(false), .string("always fails")])
        XCTAssertFalse(state.isDead, "a caught host-function error must not disturb the state")
    }

    func testHostFunctionYieldSuspendsAndResumeContinues() throws {
        let state = try ScriptTestSupport.makeState()
        let wait = HostFunction { _ in .yield([], .wait(3)) }
        let environment = state.makeEnvironment(
            name: "yield", hostBindings: [.function(name: "wait", wait)], random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(source: "wait(); return 42", chunkName: "waitChunk").get()
        guard let coroutine = try state.makeCoroutine(function: function) else {
            return XCTFail("expected a coroutine")
        }

        let first = try state.resume(coroutine, args: [], slice: 10_000)
        guard case .yielded(.wait(let ticks)) = first else {
            return XCTFail("expected .yielded(.wait), got \(first)")
        }
        XCTAssertEqual(ticks, 3)

        let second = try state.resume(coroutine, args: [], slice: 10_000)
        guard case .completed(let values) = second else {
            return XCTFail("expected .completed, got \(second)")
        }
        XCTAssertEqual(values, [.int(42)])
    }

    // MARK: - Handles: h:m() / h.m(), __index, __newindex, __eq, tostring

    func testHandleMethodsAndMetamethods() throws {
        let state = try ScriptTestSupport.makeState()

        final class NewIndexLog {
            var writes: [(key: String, value: ScriptValue)] = []
        }
        let newIndexLog = NewIndexLog()

        let dispatch = HandleDispatch(
            methods: [
                "get": { handleRef, call in
                    guard case .value(.string(let key)) = call.arguments.first else {
                        return .error("expected a string key")
                    }
                    return .values([.string("\(handleRef.ref):\(key)")])
                }
            ],
            index: { _, _, key in
                guard case .string(let name) = key else { return .values([.null]) }
                return .values([.string("prop:\(name)")])
            },
            newIndex: { _, _, key, value in
                guard case .string(let name) = key else { return .error("unsupported key") }
                newIndexLog.writes.append((name, value))
                return .values([])
            }
        )
        let kind = state.registerHandleKind(name: "widget", dispatch: dispatch, interned: true)
        let handleValue = try state.makeHandle(kind: kind, ref: "widget:1", id: 1)
        let getHandle = HostFunction { _ in .values([handleValue]) }

        let source = """
            local h = getHandle()
            local h2 = getHandle()
            local viaColon = h:get("x")
            local viaDot = h.get("x")
            local prop = h.color
            h.color = "red"
            return viaColon, viaDot, prop, (h == h2), tostring(h)
            """
        let outcome = try ScriptTestSupport.run(
            source, on: state, hostBindings: [.function(name: "getHandle", getHandle)]
        )
        guard case .success(let values) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(values[0], .string("widget:1:x"), "h:get(\"x\") (colon form)")
        XCTAssertEqual(values[1], .string("widget:1:x"), "h.get(\"x\") (dot form) must reach the same closure with the same self")
        XCTAssertEqual(values[2], .string("prop:color"), "__index fallback for a non-method key")
        XCTAssertEqual(values[3], .bool(true), "interned handles for the same ref compare equal")
        XCTAssertEqual(values[4], .string("widget:1"), "__tostring returns the ref")
        XCTAssertEqual(newIndexLog.writes.count, 1)
        XCTAssertEqual(newIndexLog.writes.first?.key, "color")
        XCTAssertEqual(newIndexLog.writes.first?.value, .string("red"))
    }

    // MARK: - Instruction budget: exact preemption and resume

    func testInstructionBudgetPreemptsAndResumesAtTheSameInstruction() throws {
        // The loop body costs more than one VM instruction per iteration, so the
        // coroutine-lifetime total must comfortably exceed 100,000 for this loop to
        // ever finish — only the *slice* (2,000, passed to each `resume` below) needs
        // to be small enough to force several preemptions.
        var budgets = ScriptBudgets.defaults
        budgets.handlerTotalInstructions = 5_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "loop", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: "local n = 0; for i = 1, 100000 do n = n + 1 end; return n", chunkName: "loopChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else {
            return XCTFail("expected a coroutine")
        }

        var completed: ScriptValue?
        var preemptions = 0
        while completed == nil {
            let outcome = try state.resume(coroutine, args: [], slice: 2_000)
            switch outcome {
            case .yielded(.preempted):
                preemptions += 1
                XCTAssertLessThan(preemptions, 1_000, "loop is not making progress across preemptions")
            case .yielded(let other):
                return XCTFail("unexpected yield \(other)")
            case .faulted(let fault):
                return XCTFail("unexpected fault \(fault)")
            case .completed(let values):
                completed = values.first
            }
        }
        // Exact resumption: no counted iteration was skipped or repeated across every
        // preemption boundary.
        XCTAssertEqual(completed, .int(100_000))
        XCTAssertGreaterThan(preemptions, 0, "the loop should have needed more than one slice")
    }

    // MARK: - Memory cap fault

    func testMemoryCapFaultsAndClosesTheCoroutine() throws {
        var budgets = ScriptBudgets.defaults
        budgets.memoryCapBytes = 64 * 1024
        budgets.hostOverCapDiagnosticBytes = 16 * 1024
        budgets.handlerTotalInstructions = 50_000_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "grow", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: "local t = {}; local i = 0; while true do i = i + 1; t[i] = ('x'):rep(100) end",
            chunkName: "growChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else {
            return XCTFail("expected a coroutine")
        }

        let outcome = try state.resume(coroutine, args: [], slice: 50_000_000)
        guard case .faulted(let fault) = outcome else {
            return XCTFail("expected .faulted, got \(outcome)")
        }
        XCTAssertEqual(fault.kind, .memoryCap)
        // The trip is consumed and cleared once reported (elysium_pcall/
        // elysium_resume, design.md Decision 5) so it never leaks into an unrelated
        // later call; the state itself stays usable for other work.
        XCTAssertFalse(state.memoryStatus.tripped)
        XCTAssertFalse(state.isDead)
    }

    // MARK: - pcall cannot revive a budget fault

    func testPcallCannotReviveAnInstructionBudgetFault() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerTotalInstructions = 5_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let environment = state.makeEnvironment(name: "pcallLoop", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: "while true do pcall(function() while true do end end) end",
            chunkName: "pcallLoopChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else {
            return XCTFail("expected a coroutine")
        }

        let outcome = try state.resume(coroutine, args: [], slice: 10_000_000)
        guard case .faulted(let fault) = outcome else {
            return XCTFail("expected .faulted, got \(outcome)")
        }
        XCTAssertEqual(fault.kind, .instructionBudget)
    }

    // MARK: - Frozen API surface

    func testFrozenLibraryTableRejectsAssignment() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            "local ok, err = pcall(function() math.sin = 1 end); return ok, (err ~= nil)", on: state
        )
        guard case .success(let values) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(values, [.bool(false), .bool(true)])
    }

    // MARK: - print reaches the sink

    func testPrintReachesTheLogSink() throws {
        let sink = RecordingLogSink()
        let state = try ScriptTestSupport.makeState(log: sink)
        let outcome = try ScriptTestSupport.run("print('hello', 42)", on: state)
        guard case .success = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(sink.lines.count, 1)
        XCTAssertEqual(sink.lines.first?.line, "hello\t42")
    }

    // MARK: - math.random draws from the configured stream

    func testMathRandomDrawsFromConfiguredStream() throws {
        let state = try ScriptTestSupport.makeState()
        var reference = RandomX(7)
        let expected = Double(reference.nextUInt32()) / 4_294_967_296.0

        let environment = state.makeEnvironment(name: "rand", random: RandomX(7))
        let function = try environment.compile(source: "return math.random()", chunkName: "randChunk").get()
        guard case .success(let values) = try state.call(function, args: [], slice: 10_000) else {
            return XCTFail("expected success")
        }
        guard case .number(let drawn) = values.first else {
            return XCTFail("expected a number result")
        }
        XCTAssertEqual(drawn, expected, accuracy: 1e-12)
    }
}
