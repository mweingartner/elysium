// LoadingTests.swift — task 6.1/6.4. design.md "Text-only loading with a private
// writable _ENV" and spec's matching requirement, plus Condition 29's chunk-name
// hygiene amendment.

import ElysiumCore
import ElysiumScript
import XCTest

final class LoadingTests: XCTestCase {
    // MARK: - Bytecode refused (spec "Bytecode refused")

    func testBytecodeRefused() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "bytecode", random: ScriptTestSupport.randomStream())
        let signature = "\u{1B}Lua" + String(repeating: "\u{0}", count: 20)
        let result = environment.compile(source: signature, chunkName: "bytecodeChunk")
        guard case .failure(let fault) = result else { return XCTFail("expected a compile fault, got \(result)") }
        XCTAssertEqual(fault.kind, .compile)
        XCTAssertTrue(fault.message.lowercased().contains("binary"), fault.message)
        XCTAssertFalse(state.isDead)
    }

    // MARK: - Globals are private per environment (spec "Globals are private per environment")

    func testEnvIsPrivate() throws {
        let state = try ScriptTestSupport.makeState()
        let env1 = state.makeEnvironment(name: "env1", random: ScriptTestSupport.randomStream())
        let env2 = state.makeEnvironment(name: "env2", random: ScriptTestSupport.randomStream())
        let source = "counter = (counter or 0) + 1; return counter"
        let fn1 = try env1.compile(source: source, chunkName: "counterChunk").get()
        let fn2 = try env2.compile(source: source, chunkName: "counterChunk").get()

        guard case .success(let a1) = try state.call(fn1, args: [], slice: 10_000) else { return XCTFail() }
        guard case .success(let a2) = try state.call(fn1, args: [], slice: 10_000) else { return XCTFail() }
        guard case .success(let b1) = try state.call(fn2, args: [], slice: 10_000) else { return XCTFail() }

        XCTAssertEqual(a1, [.int(1)])
        XCTAssertEqual(a2, [.int(2)], "env1's counter must keep incrementing independently")
        XCTAssertEqual(b1, [.int(1)], "env2 must not see env1's counter at all")

        // Both environments still see the same frozen API surface.
        let apiFn1 = try env1.compile(source: "return type(math.floor)", chunkName: "apiChunk1").get()
        let apiFn2 = try env2.compile(source: "return type(math.floor)", chunkName: "apiChunk2").get()
        guard case .success(let apiV1) = try state.call(apiFn1, args: [], slice: 10_000) else { return XCTFail() }
        guard case .success(let apiV2) = try state.call(apiFn2, args: [], slice: 10_000) else { return XCTFail() }
        XCTAssertEqual(apiV1, [.string("function")])
        XCTAssertEqual(apiV2, [.string("function")])
    }

    // MARK: - Chunk name length cap

    func testChunkNameCap() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "chunkCap", random: ScriptTestSupport.randomStream())
        let longName = String(repeating: "n", count: 100)
        let result = environment.compile(source: "return 1", chunkName: longName)
        guard case .failure(let fault) = result else { return XCTFail("expected a compile fault, got \(result)") }
        XCTAssertEqual(fault.kind, .compile)
        XCTAssertTrue(fault.message.contains("64"), fault.message)

        let okResult = environment.compile(source: "return 1", chunkName: String(repeating: "n", count: 64))
        guard case .success = okResult else { return XCTFail("a chunk name at exactly the cap must be accepted, got \(okResult)") }
    }

    // MARK: - Chunk name hygiene (Condition 29: checked before elysium_loadtext, not by matching Lua text)

    func testChunkNameHygiene() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "chunkHygiene", random: ScriptTestSupport.randomStream())
        for badName in ["bad\rname", "bad\u{202E}name"] {
            let result = environment.compile(source: "return 1", chunkName: badName)
            guard case .failure(let fault) = result else {
                XCTFail("expected chunk name '\(badName.debugDescription)' to be refused, got \(result)")
                continue
            }
            XCTAssertEqual(fault.kind, .compile)
            XCTAssertTrue(fault.message.contains("invalid character"), fault.message)
        }
        // A clean chunk name at the cap boundary is unaffected by the hygiene check.
        let cleanResult = environment.compile(source: "return 1", chunkName: "clean-chunk-name")
        guard case .success = cleanResult else { return XCTFail("expected success, got \(cleanResult)") }
    }

    // MARK: - Compile-time nesting depth is a controlled error, not a crash

    func testDepthLimitIsError() throws {
        let state = try ScriptTestSupport.makeState()
        let environment = state.makeEnvironment(name: "depthLimit", random: ScriptTestSupport.randomStream())
        // 250 levels of nested parentheses exceed LUAI_MAXCCALLS (200), which the
        // recursive-descent parser itself guards against with `enterlevel`/
        // `luaE_incCstack` -- this must surface as an ordinary compile fault, never
        // a native C-stack overflow crash.
        let deeplyNested = String(repeating: "(", count: 250) + "1" + String(repeating: ")", count: 250)
        let result = environment.compile(source: "return \(deeplyNested)", chunkName: "depthChunk")
        guard case .failure(let fault) = result else { return XCTFail("expected a compile fault, got \(result)") }
        XCTAssertEqual(fault.kind, .compile)
        XCTAssertTrue(fault.message.lowercased().contains("stack") || fault.message.lowercased().contains("level"), fault.message)
        XCTAssertFalse(state.isDead)

        // The state remains fully usable after a controlled parser depth refusal.
        let sanity = try ScriptTestSupport.run("return 1 + 1", on: state)
        guard case .success(let values) = sanity else { return XCTFail("state unusable after a depth-limit refusal") }
        XCTAssertEqual(values, [.int(2)])
    }
}
