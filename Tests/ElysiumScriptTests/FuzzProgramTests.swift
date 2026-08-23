// FuzzProgramTests.swift — object-graph-attributes (change 1a) carry-forward, task
// 7.5: promotes the Tester's ephemeral change-0 program-fuzz suite to a permanent
// regression. A seeded grammar generates small Lua programs (arithmetic, table,
// string, and control-flow shapes, some deliberately malformed) and every one is
// compiled and run under a small slice budget; the only assertion that matters is
// totality — every program yields a definite outcome (compile refusal, a fault, or
// a completed call) with no crash, no hang, and no state corruption that would break
// a later program on the same `LuaState`.

import ElysiumCore
import ElysiumScript
import XCTest

final class FuzzProgramTests: XCTestCase {
    /// `ELYSIUM_SCRIPT_FUZZ_ITERATIONS` raises the corpus size for a deeper local
    /// run; the default keeps the whole promoted suite well under 30 s.
    private static var iterations: Int {
        if let raw = ProcessInfo.processInfo.environment["ELYSIUM_SCRIPT_FUZZ_ITERATIONS"],
            let n = Int(raw), n > 0 {
            return n
        }
        return 400
    }

    /// A tiny recursive-descent Lua-*shaped* program generator. Not a real grammar —
    /// just enough structural variety (nested expressions, table literals, loops,
    /// string ops, occasional broken syntax) to exercise the lexer/parser/compiler
    /// and the runtime's own caps without ever being able to escape the sandbox.
    private struct ProgramGenerator {
        var rng: RandomX
        init(seed: UInt32) { rng = RandomX(seed) }

        mutating func nextInt(_ bound: Int) -> Int { Int(rng.next() % UInt32(bound)) }

        mutating func expr(depth: Int) -> String {
            if depth <= 0 || nextInt(4) == 0 {
                switch nextInt(5) {
                case 0: return String(nextInt(1_000) - 500)
                case 1: return "\(nextInt(1_000)).\(nextInt(999))"
                case 2: return "\"s\(nextInt(999))\""
                case 3: return nextInt(2) == 0 ? "true" : "false"
                default: return "nil"
                }
            }
            switch nextInt(6) {
            case 0:
                let op = ["+", "-", "*", "/", "%", "^", "..", "==", "<", "and", "or"][nextInt(11)]
                return "(\(expr(depth: depth - 1)) \(op) \(expr(depth: depth - 1)))"
            case 1:
                return "(-\(expr(depth: depth - 1)))"
            case 2:
                return "(#\(expr(depth: depth - 1)))"
            case 3:
                let n = nextInt(4)
                let items = (0..<n).map { _ in expr(depth: depth - 1) }.joined(separator: ", ")
                return "{\(items)}"
            case 4:
                return "tostring(\(expr(depth: depth - 1)))"
            default:
                return "(\(expr(depth: depth - 1)))"
            }
        }

        mutating func statement(depth: Int) -> String {
            switch nextInt(6) {
            case 0:
                return "local v\(nextInt(8)) = \(expr(depth: depth))"
            case 1:
                return "for i = 1, \(nextInt(6)) do local x = \(expr(depth: depth)) end"
            case 2:
                return "if \(expr(depth: depth)) then local y = \(expr(depth: depth)) end"
            case 3:
                return "local t\(nextInt(4)) = \(expr(depth: depth))"
            case 4:
                // Deliberately malformed, for parser-refusal coverage.
                return "local ,, = )("
            default:
                return "-- noop"
            }
        }

        mutating func program() -> String {
            let n = 1 + nextInt(6)
            let body = (0..<n).map { _ in statement(depth: 3) }.joined(separator: "\n")
            return "\(body)\nreturn \(expr(depth: 3))"
        }
    }

    func testFuzzedProgramsAlwaysReachADefiniteOutcome() throws {
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.handlerTotalInstructions = 20_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        var successes = 0
        var refusals = 0
        var faults = 0

        for i in 0..<Self.iterations {
            var generator = ProgramGenerator(seed: UInt32(i) &+ 1)
            let source = generator.program()
            let environment = state.makeEnvironment(
                name: "fuzz\(i)", hostBindings: [], random: ScriptTestSupport.randomStream(seed: UInt32(i) &+ 1)
            )
            switch environment.compile(source: source, chunkName: "fuzzChunk\(i)") {
            case .failure:
                refusals += 1
                continue
            case .success(let function):
                let outcome = try state.call(function, args: [], slice: 5_000)
                switch outcome {
                case .success: successes += 1
                case .failure: faults += 1
                }
            }
            XCTAssertFalse(state.isDead, "program \(i) must not brick the state:\n\(source)")
        }

        XCTAssertGreaterThan(successes + refusals + faults, 0)
        // The malformed-syntax branch guarantees at least some compile refusals; the
        // arithmetic/table branches guarantee at least some completions. A run that
        // produced only one category would mean the generator (or the runtime) isn't
        // exercising the range this test exists to cover.
        XCTAssertGreaterThan(refusals, 0, "expected at least one malformed-program refusal in \(Self.iterations) programs")
        XCTAssertGreaterThan(successes, 0, "expected at least one successful completion in \(Self.iterations) programs")
    }

    /// The state must still work normally after the whole fuzz corpus — no cumulative
    /// corruption from any of the refused/faulted programs above.
    func testStateUsableAfterFuzzCorpus() throws {
        let state = try ScriptTestSupport.makeState()
        for i in 0..<50 {
            var generator = ProgramGenerator(seed: UInt32(i) &+ 1000)
            let source = generator.program()
            let environment = state.makeEnvironment(name: "post\(i)", hostBindings: [], random: ScriptTestSupport.randomStream())
            if case .success(let function) = environment.compile(source: source, chunkName: "postChunk\(i)") {
                _ = try state.call(function, args: [], slice: 5_000)
            }
        }
        let outcome = try ScriptTestSupport.run("return 1 + 1", on: state)
        guard case .success(let values) = outcome else { return XCTFail("state unusable after fuzz corpus") }
        XCTAssertEqual(values, [.int(2)])
    }
}
