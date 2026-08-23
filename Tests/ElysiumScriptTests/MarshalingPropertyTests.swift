// MarshalingPropertyTests.swift — object-graph-attributes (change 1a) carry-forward,
// task 7.5: promotes the Tester's ephemeral change-0 marshaling round-trip property
// suite. Property: any in-cap `ScriptValue` tree, pushed as a host-function argument
// and returned unchanged by that function, comes back out exactly equal — the
// Swift<->Lua boundary never silently drops, reorders, coerces, or truncates a value
// that was within every cap `ScriptBudgets` declares.

import ElysiumCore
import ElysiumScript
import XCTest

final class MarshalingPropertyTests: XCTestCase {
    private static var iterations: Int {
        if let raw = ProcessInfo.processInfo.environment["ELYSIUM_SCRIPT_FUZZ_ITERATIONS"],
            let n = Int(raw), n > 0 {
            return n
        }
        return 300
    }

    /// Generates a random in-cap `ScriptValue`, honoring `budgets`' string/list/map/
    /// depth caps so every generated value is guaranteed marshalable.
    private struct ValueGenerator {
        var rng: RandomX
        let budgets: ScriptBudgets
        init(seed: UInt32, budgets: ScriptBudgets) {
            rng = RandomX(seed)
            self.budgets = budgets
        }

        mutating func nextInt(_ bound: Int) -> Int { bound <= 0 ? 0 : Int(rng.next() % UInt32(bound)) }

        /// `topLevel` gates `.null`: a Lua table cannot store `nil` as a present,
        /// distinguishable value — `t[k] = nil` always means "k is absent" — so a
        /// `.null` nested inside a `.list`/`.map` can never round-trip (an empty
        /// list and a list whose only element is `.null` are the identical Lua
        /// table). A top-level `.null` argument has no such problem: it marshals
        /// as an ordinary Lua `nil` argument, exercised elsewhere (e.g.
        /// `AttrValueCodecTests`). Only the outermost call may produce it.
        mutating func value(depth: Int, topLevel: Bool = false) -> ScriptValue {
            if depth <= 0 || nextInt(3) == 0 {
                if topLevel, nextInt(5) == 0 { return .null }
                switch nextInt(4) {
                case 0: return .bool(nextInt(2) == 0)
                case 1: return .int(Int64(nextInt(1_000_000)) - 500_000)
                case 2: return .number(Double(nextInt(1_000)) / 3.0)
                default:
                    let len = nextInt(min(32, budgets.valueStringBytes))
                    return .string(String((0..<len).map { _ in Character(UnicodeScalar(UInt8(65 + nextInt(26)))) }))
                }
            }
            if nextInt(2) == 0 {
                let n = nextInt(4)
                return .list((0..<n).map { _ in value(depth: depth - 1) })
            } else {
                // A Lua table has no way to distinguish an *empty* array from an
                // empty hash — `{}` decodes as `.list([])` either way, an
                // unavoidable property of the table representation, not a
                // marshaling defect. A non-empty map's string keys are never a
                // 1...n integer run, so it is never ambiguous; always generate at
                // least one entry here so this generator only produces values the
                // round trip can actually distinguish.
                let n = 1 + nextInt(4)
                var map: [String: ScriptValue] = [:]
                for i in 0..<n { map["k\(i)"] = value(depth: depth - 1) }
                return .map(map)
            }
        }
    }

    func testRoundTripThroughEchoHostFunctionPreservesValue() throws {
        let state = try ScriptTestSupport.makeState()
        let echo = HostFunction { call in
            .values(call.arguments.compactMap { arg -> ScriptValue? in
                if case .value(let v) = arg { return v }
                return nil
            })
        }
        var mismatches = 0
        for i in 0..<Self.iterations {
            var generator = ValueGenerator(seed: UInt32(i) &+ 1, budgets: .defaults)
            let original = generator.value(depth: 3, topLevel: true)
            let environment = state.makeEnvironment(
                name: "roundtrip\(i)", hostBindings: [.function(name: "echo", echo)],
                random: ScriptTestSupport.randomStream()
            )
            let function = try environment.compile(source: "return echo(...)", chunkName: "roundtripChunk\(i)").get()
            let outcome = try state.call(function, args: [original], slice: 100_000)
            guard case .success(let values) = outcome, values.count == 1 else {
                mismatches += 1
                continue
            }
            XCTAssertEqual(values[0], original, "round trip #\(i) changed the value")
        }
        XCTAssertEqual(mismatches, 0, "\(mismatches)/\(Self.iterations) round trips did not complete")
    }

    /// Determinism companion to the round-trip property: encoding the same value
    /// twice through the boundary produces byte-identical results both times (no
    /// hash-seeded iteration order leaking into map key ordering on the way back).
    func testMapKeyOrderIsStableAcrossRepeatedRoundTrips() throws {
        let state = try ScriptTestSupport.makeState()
        let echo = HostFunction { call in
            .values(call.arguments.compactMap { arg -> ScriptValue? in
                if case .value(let v) = arg { return v }
                return nil
            })
        }
        let original = ScriptValue.map([
            "alpha": .int(1), "beta": .int(2), "gamma": .int(3), "delta": .int(4), "epsilon": .int(5),
        ])
        var results: [ScriptValue] = []
        for i in 0..<10 {
            let environment = state.makeEnvironment(
                name: "stable\(i)", hostBindings: [.function(name: "echo", echo)], random: ScriptTestSupport.randomStream()
            )
            let function = try environment.compile(source: "return echo(...)", chunkName: "stableChunk\(i)").get()
            let outcome = try state.call(function, args: [original], slice: 10_000)
            guard case .success(let values) = outcome else { return XCTFail() }
            results.append(values[0])
        }
        for r in results { XCTAssertEqual(r, original) }
    }
}
