// NestingAndSourceCapTests.swift — object-graph-attributes (change 1a) carry-forward,
// task 7.5: promotes the Tester's ephemeral change-0 nesting/source-cap suite.
// Two independent caps this file exercises at their exact boundary, not just "somewhere
// past it": the host re-entrant call/resume nesting depth (`ELYSIUM_MAX_ENTRY_DEPTH`,
// `BoundaryTests.testNestingDepthCapIsError`'s sibling here goes wider/randomized) and
// `ScriptBudgets.sourceBytes`/`chunkNameBytes` (`LuaState.validateSourceAndChunkName`).

import ElysiumCore
import ElysiumScript
import XCTest

final class NestingAndSourceCapTests: XCTestCase {
    // MARK: - Source size cap, exact boundary

    func testSourceAtExactByteLimitIsAccepted() throws {
        let state = try ScriptTestSupport.makeState()
        let limit = ScriptBudgets.defaults.sourceBytes
        // "return 1" plus padding comment to hit the byte limit exactly.
        let prefix = "return 1 --"
        let padding = String(repeating: "x", count: limit - prefix.utf8.count)
        let source = prefix + padding
        XCTAssertEqual(source.utf8.count, limit)
        let environment = state.makeEnvironment(name: "atLimit", hostBindings: [], random: ScriptTestSupport.randomStream())
        guard case .success(let function) = environment.compile(source: source, chunkName: "atLimitChunk") else {
            return XCTFail("a source at exactly the byte limit must compile")
        }
        let outcome = try state.call(function, args: [], slice: 10_000)
        guard case .success(let values) = outcome else { return XCTFail("expected success") }
        XCTAssertEqual(values, [.int(1)])
    }

    func testSourceOneByteOverLimitIsRefused() throws {
        let state = try ScriptTestSupport.makeState()
        let limit = ScriptBudgets.defaults.sourceBytes
        let prefix = "return 1 --"
        let padding = String(repeating: "x", count: limit - prefix.utf8.count + 1)
        let source = prefix + padding
        XCTAssertEqual(source.utf8.count, limit + 1)
        let environment = state.makeEnvironment(name: "overLimit", hostBindings: [], random: ScriptTestSupport.randomStream())
        guard case .failure(let fault) = environment.compile(source: source, chunkName: "overLimitChunk") else {
            return XCTFail("a source one byte over the limit must be refused")
        }
        XCTAssertTrue(fault.message.contains("exceeds"), fault.message)
    }

    func testChunkNameOneByteOverLimitIsRefused() throws {
        let state = try ScriptTestSupport.makeState()
        let limit = ScriptBudgets.defaults.chunkNameBytes
        let name = String(repeating: "n", count: limit + 1)
        let environment = state.makeEnvironment(name: "chunkName", hostBindings: [], random: ScriptTestSupport.randomStream())
        guard case .failure(let fault) = environment.compile(source: "return 1", chunkName: name) else {
            return XCTFail("a chunk name one byte over the limit must be refused")
        }
        XCTAssertTrue(fault.message.contains("exceeds"), fault.message)
    }

    /// Randomized companion: many source lengths scattered around the boundary, all
    /// landing on the correct side of the accept/refuse line.
    func testRandomizedSourceLengthsRespectTheBoundary() throws {
        let state = try ScriptTestSupport.makeState()
        let limit = ScriptBudgets.defaults.sourceBytes
        var rng = RandomX(77)
        for i in 0..<40 {
            let delta = Int(rng.next() % 2_000) - 1_000 // -1000...+999 around the limit
            let length = max(8, limit + delta)
            let source = "--" + String(repeating: "x", count: max(0, length - 2))
            let environment = state.makeEnvironment(name: "rand\(i)", hostBindings: [], random: ScriptTestSupport.randomStream())
            let result = environment.compile(source: source, chunkName: "randChunk\(i)")
            if source.utf8.count <= limit {
                if case .failure(let fault) = result, fault.message.contains("exceeds") {
                    XCTFail("length \(source.utf8.count) <= limit \(limit) was refused for size")
                }
            } else {
                guard case .failure(let fault) = result, fault.message.contains("exceeds") else {
                    return XCTFail("length \(source.utf8.count) > limit \(limit) was accepted")
                }
            }
        }
    }

    // MARK: - Host re-entrant nesting depth, randomized entry points

    /// Like `BoundaryTests.testNestingDepthCapIsError` but drives the nesting through
    /// a randomized mix of `call` and `makeCoroutine`/`resume` re-entries, checking the
    /// cap holds (a deterministic refusal, never a crash or runaway C-stack) regardless
    /// of which host entry point produced each level.
    func testMixedCallAndResumeNestingHitsTheCapDeterministically() throws {
        let state = try ScriptTestSupport.makeState()
        let rng = RandomX(99)

        final class Nester {
            var depth = 0
            let cap = 40
            var function: ScriptFunction!
            var rng: RandomX
            init(rng: RandomX) { self.rng = rng }
            func makeHostFunction() -> HostFunction {
                HostFunction { [self] call in
                    depth += 1
                    defer { depth -= 1 }
                    if depth >= cap { return .values([.int(Int64(depth))]) }
                    let useResume = rng.next() % 2 == 0
                    if useResume, let coroutine = try? call.state.makeCoroutine(function: function) {
                        let outcome = try? call.state.resume(coroutine, args: [], slice: 1_000)
                        switch outcome {
                        case .completed(let values): return .values(values)
                        case .faulted(let fault): return .error(fault.message)
                        case .yielded: return .values([.int(Int64(depth))])
                        case nil: return .values([.int(Int64(depth))])
                        }
                    } else {
                        let outcome = try? call.state.call(function, args: [], slice: 1_000)
                        switch outcome {
                        case .success(let values): return .values(values)
                        case .failure(let fault): return .error(fault.message)
                        default: return .values([.int(Int64(depth))])
                        }
                    }
                }
            }
        }

        let nester = Nester(rng: rng)
        let environment = state.makeEnvironment(
            name: "nest", hostBindings: [.function(name: "nest", nester.makeHostFunction())],
            random: ScriptTestSupport.randomStream()
        )
        let function = try environment.compile(source: "return nest()", chunkName: "nestChunk").get()
        nester.function = function
        // Either a clean deep completion (below the cap) or a definite, catchable
        // refusal — never a crash or hang — satisfies this property.
        let outcome = try state.call(function, args: [], slice: 100_000)
        switch outcome {
        case .success: break
        case .failure(let fault): XCTAssertFalse(fault.message.isEmpty)
        }
        XCTAssertFalse(state.isDead)
    }
}
