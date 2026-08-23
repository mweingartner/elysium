// HandleTests.swift — task 6.1. design.md Decision 10 (handle userdata dispatch to
// typed Swift closures) and spec "Handle userdata dispatch to typed Swift closures".
// LuaStateSmokeTests already proves the basic h:m()/h.m()/__index/__newindex/tostring
// shape end to end; this file goes deeper on the parts that shape carries an implicit
// claim about: transient (non-interned) equality-by-ref, interning/invalidation,
// deterministic iteration when a handle is a table key, and method-closure caching.

import ElysiumCore
import ElysiumScript
import XCTest

final class HandleTests: XCTestCase {
    // MARK: - __eq by ref for a transient (non-interned) kind

    func testTransientHandleEqualityIsByRefNotIdentity() throws {
        // spec "Transient handle equality": a non-interned kind creates a *fresh*
        // userdata every makeHandle call, yet two such userdata for the same ref
        // must still compare equal (kind, ref), and tostring must agree.
        let state = try ScriptTestSupport.makeState()
        let dispatch = HandleDispatch()
        let kind = state.registerHandleKind(name: "block", dispatch: dispatch, interned: false)
        let a = try state.makeHandle(kind: kind, ref: "block:overworld:1,2,3", id: 1)
        let b = try state.makeHandle(kind: kind, ref: "block:overworld:1,2,3", id: 1)
        let c = try state.makeHandle(kind: kind, ref: "block:overworld:9,9,9", id: 2)
        let getA = HostFunction { _ in .values([a]) }
        let getB = HostFunction { _ in .values([b]) }
        let getC = HostFunction { _ in .values([c]) }

        let outcome = try ScriptTestSupport.run(
            """
            local x, y, z = getA(), getB(), getC()
            local sameRefEqual = (x == y)
            local differentRefEqual = (x == z)
            local sameRefIdentical = rawequal(x, y)
            local tostringMatches = (tostring(x) == 'block:overworld:1,2,3') and (tostring(y) == tostring(x))
            return sameRefEqual, differentRefEqual, sameRefIdentical, tostringMatches
            """, on: state,
            hostBindings: [.function(name: "getA", getA), .function(name: "getB", getB), .function(name: "getC", getC)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(true), "two transient userdata for the same ref must compare equal")
        XCTAssertEqual(values[1], .bool(false), "userdata for different refs must not compare equal")
        XCTAssertEqual(values[2], .bool(false), "transient userdata for the same ref must still be *distinct* Lua identities (rawequal false)")
        XCTAssertEqual(values[3], .bool(true))
    }

    // MARK: - Interning and invalidation

    func testInternedHandleIdentityAndInvalidation() throws {
        let state = try ScriptTestSupport.makeState()
        let dispatch = HandleDispatch()
        let kind = state.registerHandleKind(name: "widget", dispatch: dispatch, interned: true)

        _ = try state.makeHandle(kind: kind, ref: "widget:7", id: 7)
        let getFirst = HostFunction { call -> HostResult in
            .values([try! call.state.makeHandle(kind: kind, ref: "widget:7", id: 7)])
        }
        let outcome1 = try ScriptTestSupport.run(
            "local a, b = getFirst(), getFirst(); return rawequal(a, b)", on: state,
            hostBindings: [.function(name: "getFirst", getFirst)]
        )
        guard case .success(let values1) = outcome1 else { return XCTFail("expected success, got \(outcome1)") }
        XCTAssertEqual(values1, [.bool(true)], "an interned kind must return the identical userdata for the same ref")

        state.invalidateHandle(ref: "widget:7")

        let outcome2 = try ScriptTestSupport.run(
            "local a = getFirst(); local b = getFirst(); return rawequal(a, b)", on: state,
            hostBindings: [.function(name: "getFirst", getFirst)]
        )
        guard case .success(let values2) = outcome2 else { return XCTFail("expected success, got \(outcome2)") }
        // After invalidation, makeHandle is called fresh for *each* getFirst() call
        // inside this new script run, so both are freshly interned together and are
        // identical to each other -- the meaningful assertion is against the value
        // captured *before* invalidation.
        XCTAssertEqual(values2, [.bool(true)])

        // Compare a handle actually *pushed to Lua* before invalidation against one
        // pushed after: ScriptValue.ref resolves through the intern table only at
        // push time (Coroutines.swift/pushScriptValue), not at makeHandle() time --
        // so "before" and "after" must be observed within one script run, with the
        // invalidation itself happening (from a host function) in between the two
        // pushes.
        let invalidateNow = HostFunction { call in
            call.state.invalidateHandle(ref: "widget:7")
            return .values([])
        }
        let outcome3 = try ScriptTestSupport.run(
            """
            local x = getFirst()
            invalidateNow()
            local y = getFirst()
            return rawequal(x, y), (x == y)
            """, on: state,
            hostBindings: [.function(name: "getFirst", getFirst), .function(name: "invalidateNow", invalidateNow)]
        )
        guard case .success(let values3) = outcome3 else { return XCTFail("expected success, got \(outcome3)") }
        XCTAssertEqual(values3[0], .bool(false), "a handle pushed before invalidateHandle must be a distinct userdata from one pushed after")
        XCTAssertEqual(values3[1], .bool(true), "they still compare equal by (kind, ref) even though they are distinct userdata")
    }

    func testInvalidateHandleIsSafeForUnknownRef() throws {
        let state = try ScriptTestSupport.makeState()
        // Must not throw or crash for a ref that was never a handle.
        state.invalidateHandle(ref: "never-existed")
        state.invalidateHandle(ref: "never-existed") // idempotent
        XCTAssertFalse(state.isDead)
    }

    // MARK: - Handle as a table key iterates deterministically

    func testHandleAsTableKeyIteratesDeterministically() throws {
        func run() throws -> String {
            let state = try ScriptTestSupport.makeState()
            let dispatch = HandleDispatch()
            let kind = state.registerHandleKind(name: "keyed", dispatch: dispatch, interned: true)
            var handles: [ScriptValue] = []
            for i in 0..<30 {
                handles.append(try state.makeHandle(kind: kind, ref: "keyed:\(i)", id: UInt64(i)))
            }
            var index = 0
            let nextHandle = HostFunction { _ in
                defer { index += 1 }
                return .values([handles[index % handles.count]])
            }
            let outcome = try ScriptTestSupport.run(
                """
                local seen = {}
                for i = 1, 30 do
                    seen[nextHandle()] = i
                end
                local parts = {}
                for k, v in pairs(seen) do parts[#parts + 1] = tostring(k) .. '=' .. v end
                return table.concat(parts, ',')
                """, on: state, hostBindings: [.function(name: "nextHandle", nextHandle)], slice: 1_000_000
            )
            guard case .success(let values) = outcome, case .string(let joined) = values.first else {
                XCTFail("expected a joined string, got \(outcome)")
                return ""
            }
            return joined
        }
        let first = try run()
        let second = try run()
        XCTAssertEqual(first, second, "iterating a table keyed by handles must be identical across independently constructed states")
        XCTAssertEqual(first.split(separator: ",").count, 30)
    }

    // MARK: - Method cache identity (design.md Decision 10: "cached in user value 1")

    func testMethodClosureIsCachedNotRebuiltPerLookup() throws {
        let state = try ScriptTestSupport.makeState()
        var callCount = 0
        let dispatch = HandleDispatch(methods: [
            "get": { _, _ in callCount += 1; return .values([.int(Int64(callCount))]) }
        ])
        let kind = state.registerHandleKind(name: "cached", dispatch: dispatch, interned: true)
        let handle = try state.makeHandle(kind: kind, ref: "cached:1", id: 1)
        let getHandle = HostFunction { _ in .values([handle]) }

        let outcome = try ScriptTestSupport.run(
            """
            local h = getHandle()
            local a = h.get
            local b = h.get
            local identical = rawequal(a, b)
            local r1 = a()
            local r2 = b()
            return identical, r1, r2
            """, on: state, hostBindings: [.function(name: "getHandle", getHandle)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(true), "two `h.get` lookups on the same handle must return the identical cached closure")
        XCTAssertEqual(values[1], .int(1))
        XCTAssertEqual(values[2], .int(2), "the underlying Swift method must still actually run each call, not memoize its *result*")
    }

    func testUnrecognizedIndexKeyFallsThroughToIndexClosure() throws {
        // __index fallthrough for a non-method key (design.md: "then call the
        // kind's index closure"), and the default (no index closure) case reads nil.
        let state = try ScriptTestSupport.makeState()
        let dispatch = HandleDispatch(
            methods: ["m": { _, _ in .values([.string("method")]) }],
            index: { _, _, key in
                guard case .string(let name) = key else { return .values([.null]) }
                return .values([.string("prop:\(name)")])
            }
        )
        let kind = state.registerHandleKind(name: "fallthrough", dispatch: dispatch, interned: true)
        let handle = try state.makeHandle(kind: kind, ref: "fallthrough:1", id: 1)
        let getHandle = HostFunction { _ in .values([handle]) }

        let outcome = try ScriptTestSupport.run(
            "local h = getHandle(); return h.m, h.notAMethod", on: state,
            hostBindings: [.function(name: "getHandle", getHandle)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        // h.m resolves as a bound method closure, not the index fallback -- a bare
        // Lua function is not representable as a ScriptValue, so it marshals to
        // .null on the way back to Swift (LuaState.readResultValues); what matters
        // here is that it is *not* "prop:m" (proof the method lookup won, not the
        // index fallback).
        XCTAssertEqual(values[0], .null)
        XCTAssertEqual(values[1], .string("prop:notAMethod"))
    }

    // MARK: - No index/newIndex closures: reads nil, writes refused

    func testHandleWithoutIndexOrNewIndexClosures() throws {
        let state = try ScriptTestSupport.makeState()
        let dispatch = HandleDispatch()
        let kind = state.registerHandleKind(name: "bare", dispatch: dispatch, interned: true)
        let handle = try state.makeHandle(kind: kind, ref: "bare:1", id: 1)
        let getHandle = HostFunction { _ in .values([handle]) }

        let outcome = try ScriptTestSupport.run(
            """
            local h = getHandle()
            local prop = h.anything
            local ok, err = pcall(function() h.anything = 1 end)
            return prop, ok, tostring(err)
            """, on: state, hostBindings: [.function(name: "getHandle", getHandle)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .null, "no index closure: every non-method read is nil")
        XCTAssertEqual(values[1], .bool(false), "no newIndex closure: every write is refused")
        guard case .string(let message) = values[2] else { return XCTFail() }
        XCTAssertTrue(message.contains("modify") || message.contains("bare"), message)
    }

    // MARK: - N3 (test.md note): a ref reused under a different kind is refused,
    // not silently rebound

    func testMakeHandleRejectsRefReusedUnderADifferentKind() throws {
        let state = try ScriptTestSupport.makeState()
        let dispatchA = HandleDispatch(methods: ["which": { _, _ in .values([.string("A")]) }])
        let dispatchB = HandleDispatch(methods: ["which": { _, _ in .values([.string("B")]) }])
        let kindA = state.registerHandleKind(name: "kindA", dispatch: dispatchA, interned: true)
        let kindB = state.registerHandleKind(name: "kindB", dispatch: dispatchB, interned: true)

        _ = try state.makeHandle(kind: kindA, ref: "shared:1", id: 1)
        XCTAssertThrowsError(try state.makeHandle(kind: kindB, ref: "shared:1", id: 2)) { error in
            XCTAssertEqual(error as? LuaRuntimeError, .handleRefConflict)
        }

        // Re-registering under the *same* kind (e.g. to update id) is still fine.
        let handle = try state.makeHandle(kind: kindA, ref: "shared:1", id: 3)

        // The original registration must be completely unaffected by the refused
        // conflicting call -- .ref("shared:1") still resolves through kindA, not
        // the kind the refused call tried to rebind it to.
        let getHandle = HostFunction { _ in .values([handle]) }
        let outcome = try ScriptTestSupport.run(
            "return getHandle():which()", on: state,
            hostBindings: [.function(name: "getHandle", getHandle)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.string("A")])
    }
}
