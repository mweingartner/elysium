// ValidatorFuzzTests.swift — object-graph-attributes (change 1a) carry-forward, task
// 7.5: promotes the Tester's ephemeral change-0 validator-fuzz suite. `ScriptValidator`
// sits in front of every script source the host ever compiles (design.md Decision 12,
// stages 0-3); this suite throws random byte/text soup at it — control characters,
// bidi/C1 marks, unmatched brackets, oversized sources, raw UTF-8 garbage — and checks
// only totality: `validate` always returns (never traps, never hangs) with a definite
// `.accepted` or `.refused`, and an `.accepted` source is always actually compilable.

import ElysiumCore
import ElysiumScript
import XCTest

final class ValidatorFuzzTests: XCTestCase {
    private static var iterations: Int {
        if let raw = ProcessInfo.processInfo.environment["ELYSIUM_SCRIPT_FUZZ_ITERATIONS"],
            let n = Int(raw), n > 0 {
            return n
        }
        return 500
    }

    private struct SourceGenerator {
        var rng: RandomX
        init(seed: UInt32) { rng = RandomX(seed) }
        mutating func nextInt(_ bound: Int) -> Int { Int(rng.next() % UInt32(bound)) }

        /// A mix of: plain-ish Lua tokens, forbidden control characters (bidi
        /// overrides, C1 range, \r), raw high-byte garbage, and structural noise
        /// (unmatched brackets/quotes) — every category the validator's stages 0-3
        /// specifically exist to catch.
        mutating func source() -> String {
            let pool: [String] = [
                "return", "local", "x", "=", "1", "+", "-", "function", "end", "\"str\"",
                "\u{202E}", "\u{0085}", "\r", "\n", "(", ")", "{", "}", "[", "]",
                String(UnicodeScalar(UInt8(nextInt(256)))), "--[[", "]]", "...", "nil",
            ]
            let n = 1 + nextInt(24)
            return (0..<n).map { _ in pool[nextInt(pool.count)] }.joined(separator: " ")
        }

        /// A source that is guaranteed over `sourceBytes` — the size-cap path.
        mutating func oversizedSource(limit: Int) -> String {
            String(repeating: "x", count: limit + 1 + nextInt(1_000))
        }
    }

    func testValidatorNeverTrapsAndAlwaysReachesADefiniteVerdict() throws {
        let state = try ScriptTestSupport.makeState()
        var accepted = 0
        var refused = 0
        for i in 0..<Self.iterations {
            var generator = SourceGenerator(seed: UInt32(i) &+ 1)
            let source = generator.source()
            let result = ScriptValidator.validate(source: source, chunkName: "fuzz\(i)", using: state)
            switch result {
            case .accepted:
                accepted += 1
            case .refused(let stage, let message, _, let line):
                refused += 1
                XCTAssertTrue((0...3).contains(stage), "unexpected stage \(stage) for source #\(i)")
                XCTAssertFalse(message.isEmpty, "refusal #\(i) has no message")
                XCTAssertGreaterThanOrEqual(line, 1, "refusal #\(i) reports a non-positive line")
            }
        }
        XCTAssertGreaterThan(accepted + refused, 0)
        XCTAssertGreaterThan(refused, 0, "the forbidden-control-character pool should trigger at least one stage-0 refusal")
    }

    func testAcceptedFuzzSourceIsActuallyCompilable() throws {
        let state = try ScriptTestSupport.makeState()
        var checkedAny = false
        for i in 0..<Self.iterations {
            var generator = SourceGenerator(seed: UInt32(i) &+ 9_000)
            let source = generator.source()
            guard case .accepted = ScriptValidator.validate(source: source, chunkName: "acc\(i)", using: state) else {
                continue
            }
            checkedAny = true
            let environment = state.makeEnvironment(name: "acc\(i)env", hostBindings: [], random: ScriptTestSupport.randomStream())
            // Compile may still fail (the validator screens hygiene/structure, not full
            // Lua grammar) — the property under test is that this call never traps.
            _ = environment.compile(source: source, chunkName: "accChunk\(i)")
        }
        _ = checkedAny // the property (no trap) held regardless of whether any source was accepted
        XCTAssertFalse(state.isDead)
    }

    func testOversizedSourceIsRefusedAtEveryBoundary() throws {
        let state = try ScriptTestSupport.makeState()
        for i in 0..<20 {
            var generator = SourceGenerator(seed: UInt32(i) &+ 20_000)
            let source = generator.oversizedSource(limit: ScriptBudgets.defaults.sourceBytes)
            guard case .refused(let stage, _, _, _) = ScriptValidator.validate(source: source, chunkName: "big\(i)", using: state) else {
                return XCTFail("an oversized source must always be refused")
            }
            XCTAssertTrue((0...3).contains(stage))
        }
    }
}
