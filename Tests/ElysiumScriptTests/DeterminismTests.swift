// DeterminismTests.swift — task 6.1/6.4. design.md Decision 9 (determinism: what is
// pinned and why it is sufficient) and spec "script-determinism". Every test here
// proves a *pure function of operation history* claim empirically: run the same
// operations twice (in two independently constructed states, one with a perturbed
// allocation history) and assert byte-identical observable output.

import ElysiumCore
import ElysiumScript
import XCTest

final class DeterminismTests: XCTestCase {
    // MARK: - Shared corpus (used by testTwoStatesPerturbedHeap)

    private static let corpusSource = """
        local out = {}
        local function add(s) out[#out + 1] = tostring(s) end

        -- Iteration order over a table keyed by mixed types (ordinal-hashed).
        local seen = {}
        for i = 1, 40 do
            seen[{}] = i
            seen[(function() return i end)] = i
            seen[i] = i
            seen['k' .. i] = i
        end
        local parts = {}
        for _, v in pairs(seen) do parts[#parts + 1] = tostring(v) end
        add(table.concat(parts, ','))

        -- Math: sin/cos/atan/exp/log/^ through ScriptMath, plus math.random.
        add(string.format('%.17g', math.sin(1.23456)))
        add(string.format('%.17g', math.cos(1.23456)))
        add(string.format('%.17g', math.atan(1.0, 2.0)))
        add(string.format('%.17g', math.exp(2.5)))
        add(string.format('%.17g', math.log(2.5)))
        add(string.format('%.17g', 2 ^ 0.5))
        add(string.format('%.17g', math.random()))

        -- Strings, patterns, format, tostring, errors.
        add(('hello world'):gsub('o', '0'))
        add(string.format('%d-%s-%.2f', 42, 'x', 3.14159))
        add(tostring({}))
        add(tostring(print))
        local ok, err = pcall(function() error('boom') end)
        add(tostring(ok) .. ':' .. tostring(err))

        return table.concat(out, '|')
        """

    private func runCorpus(on state: LuaState) throws -> String {
        let environment = state.makeEnvironment(name: "corpus", random: ScriptTestSupport.randomStream(seed: 42))
        let function = try environment.compile(source: Self.corpusSource, chunkName: "corpusChunk").get()
        guard case .success(let values) = try state.call(function, args: [], slice: 5_000_000) else {
            XCTFail("corpus failed to run")
            return ""
        }
        guard case .string(let joined) = values.first else {
            XCTFail("corpus did not return a string")
            return ""
        }
        return joined
    }

    /// Runs `for i = 1, 1000000 do n = n + 1 end` to a total-cap fault and returns
    /// the number of resumes needed to reach it -- the "trip ordinal".
    private func runToTripOrdinal(on state: LuaState, budgets: ScriptBudgets) throws -> Int {
        let environment = state.makeEnvironment(name: "trip", random: ScriptTestSupport.randomStream(seed: 1))
        let function = try environment.compile(
            source: "local n = 0; while true do n = n + 1 end", chunkName: "tripChunk"
        ).get()
        guard let coroutine = try state.makeCoroutine(function: function) else {
            XCTFail("expected a coroutine")
            return -1
        }
        var resumes = 0
        while true {
            resumes += 1
            XCTAssertLessThan(resumes, 10_000)
            let outcome = try state.resume(coroutine, args: [], slice: budgets.handlerSliceInstructions)
            switch outcome {
            case .yielded(.preempted):
                continue
            case .yielded(let other):
                XCTFail("unexpected yield \(other)")
                return resumes
            case .faulted(let fault):
                XCTAssertEqual(fault.kind, .instructionBudget)
                return resumes
            case .completed:
                XCTFail("the total cap must trip before an infinite loop completes")
                return resumes
            }
        }
    }

    // MARK: - Two-state perturbed heap (spec "Two-state and cross-process determinism evidence")

    func testTwoStatesPerturbedHeap() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 3_000
        budgets.handlerTotalInstructions = 9_000

        // State 1: plain.
        let state1 = try ScriptTestSupport.makeState(budgets: budgets)
        let corpus1 = try runCorpus(on: state1)
        let tripOrdinal1 = try runToTripOrdinal(on: state1, budgets: budgets)

        // Perturb the *process's* heap -- not state2's own -- before state2 is even
        // created: `nextOrdinal` (design.md Decision 3) lives on `elysium_state`,
        // freshly calloc'd per LuaState, so it always starts at the same value
        // regardless of prior unrelated allocations elsewhere in the process. What
        // the "pure function of operation history" claim promises is that a fresh
        // state reproduces the same result no matter what else the process's
        // allocator has done -- not that mutating a *shared* state's own ordinal
        // counter with unrelated garbage leaves later results unchanged (it does
        // not: ordinal hashing legitimately depends on each object's own creation
        // order within its state). A separate, disposable state stands in for
        // "unrelated prior work elsewhere in the process."
        let throwaway = try ScriptTestSupport.makeState(budgets: budgets)
        _ = try ScriptTestSupport.run(
            """
            local junk = {}
            for i = 1, 300 do junk[i] = { tostring(i), {i, i}, i .. 'x' } end
            return #junk
            """, on: throwaway, slice: 5_000_000
        )
        throwaway.collectFull()
        try throwaway.close()

        // State 2: freshly constructed *after* that unrelated perturbation.
        let state2 = try ScriptTestSupport.makeState(budgets: budgets)
        let corpus2 = try runCorpus(on: state2)
        let tripOrdinal2 = try runToTripOrdinal(on: state2, budgets: budgets)

        XCTAssertEqual(corpus1, corpus2, "the corpus output must be byte-identical across a perturbed heap")
        XCTAssertEqual(tripOrdinal1, tripOrdinal2, "the instruction-budget trip must land on the same resume ordinal regardless of prior allocation history")
    }

    // MARK: - Ordinal-keyed iteration (tables, closures, handles)

    func testOrdinalKeyedIteration() throws {
        func run() throws -> String {
            let state = try ScriptTestSupport.makeState()
            let dispatch = HandleDispatch()
            let kind = state.registerHandleKind(name: "ordkey", dispatch: dispatch, interned: true)
            let handle = try state.makeHandle(kind: kind, ref: "ordkey:1", id: 1)
            let getHandle = HostFunction { _ in .values([handle]) }
            let outcome = try ScriptTestSupport.run(
                """
                local h = getHandle()
                local seen = {}
                for i = 1, 60 do
                    seen[{}] = i
                    seen[(function() return i end)] = i
                end
                seen[h] = 999
                seen[pairs] = 1000
                local parts = {}
                for _, v in pairs(seen) do parts[#parts + 1] = tostring(v) end
                return table.concat(parts, ',')
                """, on: state, hostBindings: [.function(name: "getHandle", getHandle)], slice: 5_000_000
            )
            guard case .success(let values) = outcome, case .string(let joined) = values.first else {
                XCTFail("expected a joined string, got \(outcome)")
                return ""
            }
            return joined
        }
        // design.md Decision 8/10: coroutine.* is never opened, so a script has no
        // way to obtain a `thread` value at all -- only table/closure/handle keys
        // are reachable through the sandboxed language surface.
        let first = try run()
        let second = try run()
        XCTAssertEqual(first, second, "iteration order over table/closure/handle keys must be identical across independently constructed states")
        XCTAssertFalse(first.isEmpty)
    }

    // MARK: - String-keyed iteration

    func testStringKeyedIteration() throws {
        func run() throws -> String {
            // The joined "key=value,..." result for 1,000 entries runs well past
            // ScriptValueLimits.defaults.stringBytes (4 KiB) -- this test is about
            // iteration-order determinism, not the marshaling cap, so it widens the
            // string limit via a larger valueStringBytes budget.
            var budgets = ScriptBudgets.defaults
            budgets.valueStringBytes = 64 * 1024
            let outcome = try ScriptTestSupport.run(
                """
                local seen = {}
                for i = 1, 1000 do
                    seen['generated-key-' .. i] = i
                end
                local parts = {}
                for k, v in pairs(seen) do parts[#parts + 1] = k .. '=' .. v end
                return table.concat(parts, ',')
                """, on: try ScriptTestSupport.makeState(budgets: budgets), slice: 5_000_000
            )
            guard case .success(let values) = outcome, case .string(let joined) = values.first else {
                XCTFail("expected a joined string, got \(outcome)")
                return ""
            }
            return joined
        }
        let first = try run()
        let second = try run()
        XCTAssertEqual(first, second, "iteration order over 1,000 string keys must be identical across independently constructed states")
        XCTAssertEqual(first.split(separator: ",").count, 1000)
    }

    // MARK: - Locale pin (spec "Locale pin")

    func testLocalePinned() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            "return tostring(1.5), tonumber('1.5'), ('a' < 'B')", on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .string("1.5"))
        XCTAssertEqual(values[1], .number(1.5))
        XCTAssertEqual(values[2], .bool(false), "byte-order comparison: 'a' (0x61) is not < 'B' (0x42)")
    }

    // MARK: - Number formatting (%.14g, int vs float, -0)

    func testNumberFormatting() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            return tostring(1), tostring(1.0), tostring(1/3), tostring(-0.0), tostring(100), tostring(100.0)
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .string("1"), "an integer never shows a decimal point")
        XCTAssertEqual(values[1], .string("1.0"), "a float always shows at least one decimal digit")
        guard case .string(let third) = values[2] else { return XCTFail() }
        XCTAssertTrue(third.hasPrefix("0.333333333333"), "expected %.14g precision, got \(third)")
        guard case .string(let negZero) = values[3] else { return XCTFail() }
        XCTAssertTrue(negZero == "-0.0" || negZero == "0.0", "unexpected -0.0 formatting: \(negZero)")
        XCTAssertEqual(values[4], .string("100"))
        XCTAssertEqual(values[5], .string("100.0"))
    }

    // MARK: - NaN formatting (C34: arm64 caveat)

    func testNaNFormattingMatchesGolden() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run("return tostring(0/0), string.format('%q', 0/0)", on: state)
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        // arm64's %.14g of the default quiet-NaN bit pattern is "nan" (not "-nan",
        // which is the x86_64 value the design explicitly disclaims).
        XCTAssertEqual(values[0], .string("nan"), "the arm64-only assumption covers NaN sign formatting")
        guard case .string(let quoted) = values[1] else { return XCTFail() }
        XCTAssertFalse(quoted.contains("0x"), "no address may leak through %q of NaN")
    }

    // MARK: - Address-free output (spec "Address-free output")

    func testAddressFreeOutput() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local ok, err = pcall(function() error('deliberate failure') end)
            return tostring({}), tostring(print), string.format('%s', {}), tostring(err)
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .string("table"))
        XCTAssertEqual(values[1], .string("function"))
        XCTAssertEqual(values[2], .string("table"))
        for value in values {
            guard case .string(let s) = value else { continue }
            XCTAssertFalse(s.contains("0x"), "unexpected address-like text: \(s)")
        }

        // An actual uncaught fault's message and traceback must also be address-free.
        let faultOutcome = try ScriptTestSupport.run("error(setmetatable({}, {}))", on: state)
        guard case .failure(let fault) = faultOutcome else { return XCTFail("expected .failure, got \(faultOutcome)") }
        XCTAssertFalse(fault.message.contains("0x"), fault.message)
        XCTAssertFalse(fault.traceback.contains("0x"), fault.traceback)
    }

    // MARK: - math.random edge semantics (C33)

    func testRandomEdgeCases() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local mgtnOk, mgtnErr = pcall(math.random, 5, 3)
            local spanOk, spanErr = pcall(math.random, 1, math.maxinteger)
            local seedOk, seedErr = pcall(math.randomseed)
            local zeroOk, zeroValue = pcall(math.random, 0)
            return mgtnOk, tostring(mgtnErr), spanOk, tostring(spanErr), seedOk, tostring(seedErr), zeroOk, type(zeroValue)
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false), "random(m > n) must be a deterministic error")
        guard case .string(let mgtnErr) = values[1] else { return XCTFail() }
        XCTAssertTrue(mgtnErr.contains("interval is empty") || mgtnErr.contains("interval"), mgtnErr)

        XCTAssertEqual(values[2], .bool(false), "a span > 2^53 must be a deterministic error")
        guard case .string(let spanErr) = values[3] else { return XCTFail() }
        XCTAssertTrue(spanErr.contains("interval"), spanErr)

        XCTAssertEqual(values[4], .bool(false), "randomseed() with no argument must be a deterministic error")
        guard case .string(let seedErr) = values[5] else { return XCTFail() }
        XCTAssertTrue(seedErr.contains("randomseed"), seedErr)

        XCTAssertEqual(values[6], .bool(true), "random(0) must succeed (two draws combined into 64 bits)")
        XCTAssertEqual(values[7], .string("number"))
    }

    // MARK: - print budget (C33)

    func testPrintBudget() throws {
        // A line over 512 bytes truncates (never a silent drop of the whole line).
        let sink = RecordingLogSink()
        let state = try ScriptTestSupport.makeState(log: sink)
        let longOutcome = try ScriptTestSupport.run(
            "print(('z'):rep(1000))", on: state
        )
        guard case .success = longOutcome else { return XCTFail("expected success, got \(longOutcome)") }
        XCTAssertEqual(sink.lines.count, 1)
        XCTAssertEqual(sink.lines[0].line.utf8.count, 512, "a print line over the cap must be truncated to exactly logLineBytes, never dropped")
        XCTAssertEqual(sink.lines[0].line, String(repeating: "z", count: 512))

        // More than 256 lines in one slice raises a deterministic, catchable error
        // -- never a silent drop.
        let budgetSink = RecordingLogSink()
        let budgetState = try ScriptTestSupport.makeState(log: budgetSink)
        let budgetOutcome = try ScriptTestSupport.run(
            """
            local ok, err
            for i = 1, 300 do
                ok, err = pcall(print, i)
                if not ok then break end
            end
            return ok, tostring(err)
            """, on: budgetState, slice: 1_000_000
        )
        guard case .success(let values) = budgetOutcome else { return XCTFail("expected success, got \(budgetOutcome)") }
        XCTAssertEqual(values[0], .bool(false), "printing past the per-slice line budget must be a catchable error")
        guard case .string(let message) = values[1] else { return XCTFail() }
        XCTAssertTrue(message.contains("print budget exceeded"), message)
        XCTAssertEqual(budgetSink.lines.count, 256, "exactly logLinesPerSlice (256) lines must have reached the sink before the budget error")
    }
}
