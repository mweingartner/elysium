// PatternAndHandleFuzzTests.swift — object-graph-attributes (change 1a) carry-forward,
// task 7.5: promotes the Tester's ephemeral change-0 pattern/handle fuzz suite. Two
// independent surfaces: Lua string-pattern matching (the sandboxed `string.find`/
// `match`/`gmatch`/`gsub` family — `SandboxTests.testPatternBombTerminates` proves one
// specific catastrophic-backtracking shape is capped; this suite widens that to many
// random patterns/subjects) and handle userdata (design.md Decision 10) identity —
// random refs/ids through `makeHandle`/`registerHandleKind`, checking the equality-by-
// ref and `tostring` properties `HandleTests.swift` establishes hold over a much wider
// random sample, not just its few hand-picked cases.

import ElysiumCore
import ElysiumScript
import XCTest

final class PatternAndHandleFuzzTests: XCTestCase {
    private static var iterations: Int {
        if let raw = ProcessInfo.processInfo.environment["ELYSIUM_SCRIPT_FUZZ_ITERATIONS"],
            let n = Int(raw), n > 0 {
            return n
        }
        return 200
    }

    // MARK: - Pattern fuzz

    func testRandomPatternsAgainstRandomSubjectsNeverHangOrCrash() throws {
        var budgets = ScriptTestSupport.tinyBudgets
        budgets.handlerTotalInstructions = 200_000
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        var rng = RandomX(31)
        let patternPieces = ["%a", "%d", "%s", "%w", ".", "*", "+", "-", "?", "^", "$", "a", "b", "(", ")", "%b()", "[a-z]", "%%"]
        let subjectPieces = ["a", "b", "1", " ", "aaaa", "abcabc", "(())", "%", "\n"]

        var faults = 0
        var successes = 0
        for i in 0..<Self.iterations {
            let patternLen = 1 + Int(rng.next() % 6)
            let pattern = (0..<patternLen).map { _ in patternPieces[Int(rng.next()) % patternPieces.count] }.joined()
            let subjectLen = 1 + Int(rng.next() % 40)
            let subject = (0..<subjectLen).map { _ in subjectPieces[Int(rng.next()) % subjectPieces.count] }.joined()

            let source = """
            local ok, result = pcall(function() return (\(luaQuote(subject))):find(\(luaQuote(pattern))) end)
            return ok
            """
            let environment = state.makeEnvironment(name: "pat\(i)", hostBindings: [], random: ScriptTestSupport.randomStream())
            guard case .success(let function) = environment.compile(source: source, chunkName: "patChunk\(i)") else {
                continue
            }
            let outcome = try state.call(function, args: [], slice: 20_000)
            switch outcome {
            case .success: successes += 1
            case .failure: faults += 1
            }
            XCTAssertFalse(state.isDead, "pattern #\(i) (\(pattern)) against subject #\(i) bricked the state")
        }
        XCTAssertGreaterThan(successes + faults, 0)
    }

    private func luaQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: - Handle identity fuzz

    func testRandomHandleRefsPreserveEqualityAndTostringAcrossManyInstances() throws {
        let state = try ScriptTestSupport.makeState()
        let dispatch = HandleDispatch()
        let kind = state.registerHandleKind(name: "fuzzKind", dispatch: dispatch, interned: false)
        var rng = RandomX(55)

        for i in 0..<Self.iterations {
            let ref = "fuzz:\(Int(rng.next() % 100_000)):\(Int(rng.next() % 100_000))"
            let id = UInt64(rng.next())
            let a = try state.makeHandle(kind: kind, ref: ref, id: id)
            let b = try state.makeHandle(kind: kind, ref: ref, id: id)
            let getA = HostFunction { _ in .values([a]) }
            let getB = HostFunction { _ in .values([b]) }
            let outcome = try ScriptTestSupport.run(
                "return (getA() == getB()), tostring(getA())", on: state,
                hostBindings: [.function(name: "getA", getA), .function(name: "getB", getB)]
            )
            guard case .success(let values) = outcome, values.count == 2 else {
                return XCTFail("handle round trip #\(i) did not complete")
            }
            XCTAssertEqual(values[0], .bool(true), "same-ref handles #\(i) must compare equal")
            XCTAssertEqual(values[1], .string(ref), "tostring #\(i) must return the exact ref")
        }
    }

    /// Two handles with different refs must never compare equal, across a wide random
    /// sample (the collision property `HandleTests.swift`'s single hand-picked case
    /// establishes, generalized).
    func testDistinctRandomHandleRefsAreNeverEqual() throws {
        let state = try ScriptTestSupport.makeState()
        let dispatch = HandleDispatch()
        let kind = state.registerHandleKind(name: "fuzzKind2", dispatch: dispatch, interned: false)
        var rng = RandomX(88)

        for i in 0..<Self.iterations {
            let refA = "a:\(Int(rng.next() % 1_000_000))"
            var refB = "b:\(Int(rng.next() % 1_000_000))"
            if refB == refA { refB += "!" } // guarantee distinctness
            let a = try state.makeHandle(kind: kind, ref: refA, id: 1)
            let b = try state.makeHandle(kind: kind, ref: refB, id: 2)
            let getA = HostFunction { _ in .values([a]) }
            let getB = HostFunction { _ in .values([b]) }
            let outcome = try ScriptTestSupport.run(
                "return getA() == getB()", on: state,
                hostBindings: [.function(name: "getA", getA), .function(name: "getB", getB)]
            )
            guard case .success(let values) = outcome else { return XCTFail("handle round trip #\(i) did not complete") }
            XCTAssertEqual(values, [.bool(false)], "distinct-ref handles #\(i) (\(refA) vs \(refB)) compared equal")
        }
    }
}
