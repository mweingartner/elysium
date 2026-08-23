// FaultTests.swift — task 6.1/6.4. spec "Error values and tracebacks are sanitized
// and address-free" and "Coroutine resume contract and thread pool", plus Condition
// 29's fault-text-by-construction and host-side invalidYield-flag amendments.

import ElysiumCore
import ElysiumScript
import XCTest

final class FaultTests: XCTestCase {
    // MARK: - Non-string error object (spec "Error object")

    func testNonStringErrorObject() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "nonStringError", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: "error(setmetatable({}, {__tostring = function() error('x') end}))",
            chunkName: "nonStringErrorChunk"
        ).get()
        let outcome = try state.call(function, args: [], slice: 10_000)
        guard case .failure(let fault) = outcome else { return XCTFail("expected .failure, got \(outcome)") }
        XCTAssertEqual(fault.kind, .runtime)
        XCTAssertEqual(fault.message, "<non-string error>", "__tostring must never be invoked on the error object")
        XCTAssertFalse(state.isDead)
    }

    // MARK: - Address-free tracebacks

    func testTracebackAddressFree() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "traceback", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: """
                local function inner() error('deep failure') end
                local function middle() inner() end
                local function outer() middle() end
                outer()
                """,
            chunkName: "tracebackChunk"
        ).get()
        let outcome = try state.call(function, args: [], slice: 10_000)
        guard case .failure(let fault) = outcome else { return XCTFail("expected .failure, got \(outcome)") }
        XCTAssertFalse(fault.traceback.isEmpty)
        XCTAssertFalse(fault.traceback.contains("0x"), fault.traceback)
        XCTAssertTrue(fault.traceback.contains("inner") || fault.traceback.contains("tracebackChunk"), fault.traceback)
        XCTAssertLessThanOrEqual(fault.traceback.utf8.count, 2048)
    }

    // MARK: - Message truncation and sanitization

    func testMessageTruncatedAndSanitized() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "truncated", random: ScriptTestSupport.randomStream())
        let embedded = try environment.compile(
            source: "error(('m'):rep(2000))", chunkName: "truncatedChunk"
        ).get()
        let outcome = try state.call(embedded, args: [], slice: 10_000)
        guard case .failure(let fault) = outcome else { return XCTFail("expected .failure, got \(outcome)") }
        // error() at its default level prepends "chunkname:line: " to a string
        // message, so the capped text is that prefix followed by as many 'm's as
        // fit in the remaining budget -- exactly 512 bytes total, since the
        // untruncated combined text (prefix + 2,000 'm's) is far longer.
        XCTAssertEqual(fault.message.utf8.count, 512, "the fault message must be capped at exactly 512 bytes")
        XCTAssertTrue(fault.message.hasPrefix("[string \"truncatedChunk\"]:1: "), fault.message)
        XCTAssertTrue(fault.message.hasSuffix("m"), fault.message)

        // Sanitization: a control character embedded in the error text must be
        // replaced (U+FFFD), never passed through raw.
        let controlFn = try environment.compile(
            source: "error('bad\\1char')", chunkName: "controlCharChunk"
        ).get()
        let controlOutcome = try state.call(controlFn, args: [], slice: 10_000)
        guard case .failure(let controlFault) = controlOutcome else { return XCTFail("expected .failure, got \(controlOutcome)") }
        XCTAssertTrue(controlFault.message.contains("\u{FFFD}"), controlFault.message)
        XCTAssertFalse(controlFault.message.unicodeScalars.contains { $0.value == 1 }, "the raw C0 control byte must never survive sanitization")
    }

    // MARK: - Fault closes the thread and pools it (spec "Fault closes the thread")

    func testFaultClosesThreadAndPools() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "faultClose", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(source: "error('boom')", chunkName: "faultCloseChunk").get()
        guard let coroutine = try state.makeCoroutine(function: function) else { return XCTFail("expected a coroutine") }

        let outcome = try state.resume(coroutine, args: [], slice: 10_000)
        guard case .faulted(let fault) = outcome else { return XCTFail("expected .faulted, got \(outcome)") }
        XCTAssertEqual(fault.kind, .runtime)
        XCTAssertTrue(fault.message.hasSuffix("boom"), fault.message) // error() prepends "chunkname:line: "

        // The coroutine itself must reject any further resume.
        let secondResume = try state.resume(coroutine, args: [], slice: 10_000)
        guard case .faulted(let secondFault) = secondResume else { return XCTFail("expected a refusal, got \(secondResume)") }
        XCTAssertEqual(secondFault.kind, .hostAbort)

        // The underlying thread was actually reset/pooled (not merely marked dead
        // on the Swift side): a brand-new, unrelated coroutine still runs its own
        // full instruction budget cleanly (mirrors BudgetTests'
        // testFaultedThreadReuseStillBudgeted, but for an *ordinary* runtime fault
        // rather than a hook-raised one -- this is exactly the path the Coroutines
        // .swift Builder fix made call elysium_closethread on every fault, not only
        // a deferred-close one).
        let environment2 = state.makeEnvironment(name: "faultCloseFresh", random: ScriptTestSupport.randomStream())
        let function2 = try environment2.compile(source: "return 1 + 1", chunkName: "faultCloseFreshChunk").get()
        guard let coroutine2 = try state.makeCoroutine(function: function2) else { return XCTFail("expected a second coroutine") }
        let outcome2 = try state.resume(coroutine2, args: [], slice: 10_000)
        guard case .completed(let values2) = outcome2 else { return XCTFail("expected .completed, got \(outcome2)") }
        XCTAssertEqual(values2, [.int(2)])
        XCTAssertFalse(state.isDead)
    }

    // MARK: - Invalid yield: a host function yielding from a non-yieldable point

    func testInvalidYieldFromSynchronousCall() throws {
        let state = try ScriptTestSupport.makeState()
        let mustYield = HostFunction { _ in .yield([], .wait(1)) }
        let environment = state.makeEnvironment(
            name: "invalidYield", hostBindings: [.function(name: "mustYield", mustYield)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(source: "mustYield(); return 'unreachable'", chunkName: "invalidYieldChunk").get()
        // call() is the synchronous, non-yieldable form -- a host function attempt
        // to yield inside it must become .invalidYield, never a silent no-op or a
        // crash.
        let outcome = try state.call(function, args: [], slice: 10_000)
        guard case .failure(let fault) = outcome else { return XCTFail("expected .failure, got \(outcome)") }
        XCTAssertEqual(fault.kind, .invalidYield)
        XCTAssertFalse(state.isDead)
    }

    // MARK: - .invalidYield is a host-side flag, never text matching (Condition 29)

    func testInvalidYieldFlaggedNotParsed() throws {
        let state = try ScriptTestSupport.makeState()

        // An ordinary runtime error whose *text* happens to say "invalid yield"
        // must NOT be misclassified as .invalidYield -- the classification comes
        // from a host-side flag the trampoline sets, never from matching the
        // string.
        let fakeText = HostFunction { _ in .error("invalid yield") }
        let environment = state.makeEnvironment(
            name: "fakeInvalidYield", hostBindings: [.function(name: "fakeText", fakeText)],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(source: "fakeText()", chunkName: "fakeInvalidYieldChunk").get()
        let outcome = try state.call(function, args: [], slice: 10_000)
        guard case .failure(let fault) = outcome else { return XCTFail("expected .failure, got \(outcome)") }
        XCTAssertEqual(fault.kind, .runtime, "an ordinary error whose text says 'invalid yield' must not be reclassified")
        XCTAssertEqual(fault.message, "invalid yield")

        // The converse: a *real* invalid-yield attempt is flagged .invalidYield
        // regardless of what (if anything) accompanies it.
        let realYield = HostFunction { _ in .yield([.string("payload")], .preempted) }
        let environment2 = state.makeEnvironment(
            name: "realInvalidYield", hostBindings: [.function(name: "realYield", realYield)],
            random: ScriptTestSupport.randomStream()
        )
        let function2 = try environment2.compile(source: "realYield()", chunkName: "realInvalidYieldChunk").get()
        let outcome2 = try state.call(function2, args: [], slice: 10_000)
        guard case .failure(let fault2) = outcome2 else { return XCTFail("expected .failure, got \(outcome2)") }
        XCTAssertEqual(fault2.kind, .invalidYield)
    }

    // MARK: - Embedded NUL and invalid UTF-8 in an error value

    func testErrorWithEmbeddedNulAndInvalidUTF8() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "nulUtf8", random: ScriptTestSupport.randomStream())
        let function = try environment.compile(
            source: "error('bad' .. string.char(0) .. 'value' .. string.char(255, 254))",
            chunkName: "nulUtf8Chunk"
        ).get()
        let outcome = try state.call(function, args: [], slice: 10_000)
        guard case .failure(let fault) = outcome else { return XCTFail("expected .failure, got \(outcome)") }
        // Must not crash; the message is a valid (repaired) Swift String containing
        // the surrounding readable text.
        XCTAssertTrue(fault.message.contains("bad"), fault.message)
        XCTAssertTrue(fault.message.contains("value"), fault.message)
        XCTAssertFalse(state.isDead)
    }
}
