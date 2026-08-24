// MathTests.swift — task 6.1. design.md Decision 11 (ScriptMath/ScriptRandomStream
// seams) and spec "Script-visible math, RNG and locale are host-determined". Every
// script-visible transcendental must be bit-identical to calling `DetMath`/`RandomX`
// directly in Swift -- there is no libm fallback anywhere in the runtime.

import ElysiumCore
import ElysiumScript
import XCTest

final class MathTests: XCTestCase {
    private func number(_ value: ScriptValue?) -> Double? {
        switch value {
        case .number(let d): return d
        case .int(let i): return Double(i)
        default: return nil
        }
    }

    // MARK: - math.* routes through ScriptMath (bit-identical to DetMath)

    func testMathRoutesToScriptMath() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            return math.sin(1.23456), math.cos(1.23456), math.atan(1.0, 2.0),
                   math.exp(2.5), math.log(2.5), 2 ^ 0.5
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values.count, 6)

        let expectedSin = detSin(1.23456)
        let expectedCos = detCos(1.23456)
        let expectedAtan2 = detAtan2(1.0, 2.0)
        let expectedExp = detExp(2.5)
        let expectedLog = detLog(2.5)
        let expectedPow = detPow(2.0, 0.5) // 2^0.5, exponent != 2 so it is not the a*a fast path

        XCTAssertEqual(number(values[0])?.bitPattern, expectedSin.bitPattern, "math.sin must be bit-identical to detSin")
        XCTAssertEqual(number(values[1])?.bitPattern, expectedCos.bitPattern, "math.cos must be bit-identical to detCos")
        XCTAssertEqual(number(values[2])?.bitPattern, expectedAtan2.bitPattern, "math.atan(y,x) must be bit-identical to detAtan2")
        XCTAssertEqual(number(values[3])?.bitPattern, expectedExp.bitPattern, "math.exp must be bit-identical to detExp")
        XCTAssertEqual(number(values[4])?.bitPattern, expectedLog.bitPattern, "math.log must be bit-identical to detLog")
        XCTAssertEqual(number(values[5])?.bitPattern, expectedPow.bitPattern, "'^' (constant-folded at compile time) must be bit-identical to detPow")

        // The same expression written as a *runtime* computation (not a compile-time
        // constant) must agree with the folded constant bit-for-bit -- proving
        // compile-time folding and runtime '^' share the exact same ScriptMath path
        // (design.md Decision 9's "compile-time and run-time '^' agree").
        let runtimeOutcome = try ScriptTestSupport.run("local b = 2; local e = 0.5; return b ^ e", on: state)
        guard case .success(let runtimeValues) = runtimeOutcome else { return XCTFail("expected success") }
        XCTAssertEqual(number(runtimeValues.first)?.bitPattern, expectedPow.bitPattern)
    }

    // MARK: - tan/asin/acos/log2/log10 route through ScriptMath (change 3 wiring)

    /// design.md §16 row 3 / Decision 10: `tan`/`asin`/`acos` were removed outright
    /// through change 0-2 (§8.3) and are restored here as shim wrappers over the
    /// fdlibm ports `de4e78c` landed; `log2`/`log10` are new, additive `math` entries.
    func testTanAsinAcosLog2Log10RouteToScriptMath() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            return math.tan(0.6), math.asin(0.3), math.acos(0.3), math.log2(8), math.log10(1000)
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(number(values[0])?.bitPattern, detTan(0.6).bitPattern, "math.tan must be bit-identical to detTan")
        XCTAssertEqual(number(values[1])?.bitPattern, detAsin(0.3).bitPattern, "math.asin must be bit-identical to detAsin")
        XCTAssertEqual(number(values[2])?.bitPattern, detAcos(0.3).bitPattern, "math.acos must be bit-identical to detAcos")
        XCTAssertEqual(number(values[3])?.bitPattern, detLog2(8.0).bitPattern, "math.log2 must be bit-identical to detLog2")
        XCTAssertEqual(number(values[4])?.bitPattern, detLog10(1000.0).bitPattern, "math.log10 must be bit-identical to detLog10")
    }

    /// `math.log(x, b)` itself must stay untouched by the log2/log10 wiring
    /// (Appendix E point 4 / `testLogBaseRatio` above) — restated here with base 2
    /// and base 10 specifically, since those are exactly the bases a naive
    /// "special-case log2/log10" implementation would have diverted.
    func testLogBaseTwoAndTenStillUseRatio() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run("return math.log(8, 2), math.log(1000, 10)", on: state)
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        let expectedLog2Ratio = detLog(8.0) / detLog(2.0)
        let expectedLog10Ratio = detLog(1000.0) / detLog(10.0)
        XCTAssertEqual(number(values[0])?.bitPattern, expectedLog2Ratio.bitPattern)
        XCTAssertEqual(number(values[1])?.bitPattern, expectedLog10Ratio.bitPattern)
    }

    /// `detAsin`/`detAcos` never trap outside [-1, 1]; `math.log2`/`log10` never
    /// trap for x <= 0 — all four return NaN/-inf, matching their own doc comments
    /// ("never traps"), so no `ScriptHostBindings` guard is needed for them (unlike
    /// `sin`/`cos`). NaN/infinite doubles cannot cross back to Swift as a return
    /// value (`ScriptValue.notFinite` — `Coroutines.swift`'s `readResultValues`
    /// turns them into `.null`, the same "cannot represent" path a bare function/
    /// thread return takes; this is pre-existing marshaling behavior, not something
    /// this change touches), so this proves the NaN-ness and the non-trapping
    /// entirely inside Lua, `x ~= x` being the standard Lua NaN test.
    func testDomainRestrictedMathNeverTraps() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            return math.asin(2.0) ~= math.asin(2.0), math.acos(-2.0) ~= math.acos(-2.0),
                   math.log2(-1.0) ~= math.log2(-1.0), math.log2(0.0) == -math.huge,
                   math.log10(-1.0) ~= math.log10(-1.0)
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.bool(true), .bool(true), .bool(true), .bool(true), .bool(true)],
                        "asin/acos outside [-1,1] and log2/log10 of a non-positive must be NaN/-inf, never trap")
        XCTAssertFalse(state.isDead)
    }

    // MARK: - math.random matches RandomX directly

    func testRandomMatchesRandomX() throws {
        let state = try ScriptTestSupport.makeState()
        var reference = RandomX(99)
        let expectedDraws = (0..<5).map { _ in Double(reference.nextUInt32()) / 4_294_967_296.0 }

        let environment = state.makeEnvironment(name: "randomMatch", random: RandomX(99))
        let function = try environment.compile(
            source: "return math.random(), math.random(), math.random(), math.random(), math.random()",
            chunkName: "randomMatchChunk"
        ).get()
        guard case .success(let values) = try state.call(function, args: [], slice: 10_000) else {
            return XCTFail("expected success")
        }
        XCTAssertEqual(values.count, 5)
        for (index, expected) in expectedDraws.enumerated() {
            guard let actual = number(values[index]) else { XCTFail("expected a numeric draw at \(index)"); continue }
            XCTAssertEqual(actual.bitPattern, expected.bitPattern, "draw \(index) mismatched RandomX directly")
        }
    }

    // MARK: - math.randomseed reseeds deterministically (matches RandomX(seed) exactly)

    func testRandomseedDeterministic() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "reseed", random: RandomX(1))
        let function = try environment.compile(
            source: "math.randomseed(777); return math.random(), math.random(), math.random()",
            chunkName: "reseedChunk"
        ).get()
        guard case .success(let values) = try state.call(function, args: [], slice: 10_000) else {
            return XCTFail("expected success")
        }

        var reference = RandomX(777)
        let expected = (0..<3).map { _ in Double(reference.nextUInt32()) / 4_294_967_296.0 }
        for (index, exp) in expected.enumerated() {
            guard let actual = number(values[index]) else { XCTFail("expected a numeric draw at \(index)"); continue }
            XCTAssertEqual(actual.bitPattern, exp.bitPattern, "post-reseed draw \(index) mismatched RandomX(777) exactly")
        }
    }

    // MARK: - math.log(x, b) == log(x)/log(b) for every base (Decision 9)

    func testLogBaseRatio() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            return math.log(8, 2), math.log(100, 10), math.log(27, 3), math.log(5, 5)
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        let pairs: [(Double, Double)] = [(8, 2), (100, 10), (27, 3), (5, 5)]
        for (index, (x, b)) in pairs.enumerated() {
            let expected = detLog(x) / detLog(b)
            XCTAssertEqual(number(values[index])?.bitPattern, expected.bitPattern, "math.log(\(x), \(b)) must equal detLog(x)/detLog(b) exactly")
        }
    }

    // MARK: - Huge trig inputs never trap (Decision 9's remPio2 guard)

    func testHugeSinDoesNotTrap() throws {
        let state = try ScriptTestSupport.makeState()
        // Values at/around the tick-scale a running simulation might reach, plus
        // the extremes explicitly named in the design (1e18, -1e300).
        let inputs: [Double] = [1e18, -1e300, 1_000_000.0, 3_600.0 * 24 * 365 * 50, 2_147_483_647.0]
        for x in inputs {
            let outcome = try ScriptTestSupport.run("return math.sin(\(x)), math.cos(\(x))", on: state)
            guard case .success(let values) = outcome else { return XCTFail("math.sin/cos(\(x)) must not fault, got \(outcome)") }
            guard let sinValue = number(values[0]), let cosValue = number(values[1]) else {
                return XCTFail("expected numeric results for x=\(x)")
            }
            XCTAssertTrue(sinValue.isFinite, "sin(\(x)) must be finite, got \(sinValue)")
            XCTAssertTrue(cosValue.isFinite, "cos(\(x)) must be finite, got \(cosValue)")
            XCTAssertLessThanOrEqual(abs(sinValue), 1.0 + 1e-9)
            XCTAssertLessThanOrEqual(abs(cosValue), 1.0 + 1e-9)

            // Matches ScriptHostBindings.swift's own reduction for the trap range:
            // fmod(x, 2*pi) before detSin/detCos (bit-identical, since both this test
            // and the production wrapper use the same IEEE-exact truncatingRemainder).
            let reduced = x.truncatingRemainder(dividingBy: 2 * Double.pi)
            XCTAssertEqual(sinValue.bitPattern, detSin(reduced).bitPattern, "sin(\(x)) mismatched the documented range-reduction")
            XCTAssertEqual(cosValue.bitPattern, detCos(reduced).bitPattern, "cos(\(x)) mismatched the documented range-reduction")
        }
        XCTAssertFalse(state.isDead)
    }
}
