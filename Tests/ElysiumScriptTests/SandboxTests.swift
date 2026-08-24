// SandboxTests.swift — task 6.1/6.4. design.md Decision 8 (sandbox construction),
// spec "script-sandbox-and-budgets" (the allowlist table, C-side work caps, frozen
// reachability) and the Post-Security(plan) amendments C22-C24. Every C-side cap
// documented in Sources/CLua/elysium_sandbox.c is exercised here through the script
// language itself: this file never imports CLua and never sees a raw pointer.

import ElysiumCore
import ElysiumScript
import XCTest

final class SandboxTests: XCTestCase {
    // MARK: - Pattern bomb terminates (spec "Pattern bomb terminates")

    func testPatternBombTerminates() throws {
        let state = try ScriptTestSupport.makeState()
        let start = Date()
        let outcome = try ScriptTestSupport.run(
            """
            local ok, err = pcall(function()
                return (('a'):rep(8000)):find((('.-'):rep(8)) .. 'b')
            end)
            return ok, err
            """, on: state
        )
        let elapsedMillis = Date().timeIntervalSince(start) * 1000
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values.first, .bool(false), "the pattern bomb must be a catchable error, not a hang or crash")
        guard case .string(let message) = values[1] else { return XCTFail("expected an error message string") }
        XCTAssertTrue(message.contains("pattern too complex"), "unexpected message: \(message)")
        // Diagnostic only (design.md Risk row: "not a budget"): the matcher step
        // counter should make this resolve almost instantly, well inside 200 ms.
        XCTAssertLessThan(elapsedMillis, 200, "pattern-bomb wall-clock diagnostic: \(elapsedMillis) ms")
        XCTAssertFalse(state.isDead)
    }

    // MARK: - Library input caps (spec "Input caps")

    func testInputCaps() throws {
        // Building the fixtures below (a 70,000-element move source, a 9000-byte
        // rep, ...) inside one slice comfortably exceeds the *default* per-slice
        // allocation-rate budget on its own -- this test is about the library
        // input caps, not the allocation-rate budget, so it gets a generous one.
        var budgets = ScriptBudgets.defaults
        budgets.allocationRatePerSliceBytes = 32 * 1024 * 1024
        budgets.memoryCapBytes = 48 * 1024 * 1024
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let outcome = try ScriptTestSupport.run(
            """
            local results = {}
            local function check(name, fn)
                local ok, err = pcall(fn)
                results[#results + 1] = name .. ':' .. tostring(ok) .. ':' .. tostring(err)
            end
            check('rep', function() return ('x'):rep(70000) end)
            check('find', function() return string.find(('a'):rep(9000), 'a') end)
            check('sort', function()
                local big = {}
                for i = 1, 5000 do big[i] = 5001 - i end
                return table.sort(big)
            end)
            check('unpack', function()
                local t = {}
                for i = 1, 300 do t[i] = i end
                return table.unpack(t, 1, 300)
            end)
            check('move', function()
                local t = {}
                for i = 1, 70000 do t[i] = i end
                return table.move(t, 1, 70000, 1, {})
            end)
            check('utf8', function() return utf8.len(('a'):rep(60000) .. ('a'):rep(10000)) end)
            check('formatArgs', function()
                return string.format(('%d'):rep(33), table.unpack((function()
                    local a = {}
                    for i = 1, 33 do a[i] = i end
                    return a
                end)()))
            end)
            check('formatP', function() return string.format('%p', {}) end)
            return table.concat(results, '|')
            """, on: state, slice: 20_000_000
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        guard case .string(let joined) = values.first else { return XCTFail("expected a joined result string") }
        let entries = Dictionary(uniqueKeysWithValues: joined.split(separator: "|").map { entry -> (String, String) in
            let parts = entry.split(separator: ":", maxSplits: 1)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : "")
        })

        func assertRefused(_ name: String, contains substring: String) {
            guard let entry = entries[name] else { return XCTFail("missing entry for \(name)") }
            XCTAssertTrue(entry.hasPrefix("false:"), "\(name) should have been refused, got \(entry)")
            XCTAssertTrue(entry.contains(substring), "\(name) message '\(entry)' should mention '\(substring)'")
        }

        assertRefused("rep", contains: "exceeds 65536 bytes")
        assertRefused("find", contains: "subject exceeds 8192 bytes")
        assertRefused("sort", contains: "table.sort exceeds 4096 elements")
        assertRefused("move", contains: "table.move exceeds 65536 elements")
        assertRefused("utf8", contains: "utf8 subject exceeds 65536 bytes")
        assertRefused("formatArgs", contains: "too many conversions")
        assertRefused("formatP", contains: "not a permitted format conversion")
        // table.unpack(t, 1, 300) exceeds the 256-result cap.
        assertRefused("unpack", contains: "table.unpack exceeds 256 results")
        XCTAssertFalse(state.isDead)
    }

    // MARK: - string.format / string.pack / string.gsub result cap (C36)

    func testFormatPackGsubResultCap() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local function check(fn)
                local ok, err = pcall(fn)
                return ok, tostring(err)
            end

            -- Over cap: format('%s%s', big, big) with big = 40000 bytes -> 80000 bytes.
            local big = ('x'):rep(40000)
            local formatOverOk, formatOverErr = check(function() return string.format('%s%s', big, big) end)

            -- At/below cap: a single 1000-byte %s.
            local formatUnderOk = check(function() return string.format('%s', ('y'):rep(1000)) end)

            -- Over cap: pack('s', big70000) prepends an 8-byte size_t length ->
            -- 70008 bytes total. Built via '..' (not 'rep') since 'rep' itself caps
            -- at 65536 bytes and cannot produce a 70000-byte string directly.
            local big70000 = ('x'):rep(60000) .. ('x'):rep(10000)
            local packOverOk, packOverErr = check(function() return string.pack('s', big70000) end)
            local packUnderOk = check(function() return string.pack('s', ('z'):rep(100)) end)

            -- Over cap: gsub expanding 8000 'a's into 10-byte replacements -> 80000 bytes.
            local gsubOverOk, gsubOverErr = check(function() return ('a'):rep(8000):gsub('a', ('b'):rep(10)) end)
            -- At/below cap: 5000 'a's into 10-byte replacements -> 50000 bytes.
            local gsubUnderOk = check(function() return ('a'):rep(5000):gsub('a', ('b'):rep(10)) end)

            return formatOverOk, formatOverErr, formatUnderOk,
                   packOverOk, packOverErr, packUnderOk,
                   gsubOverOk, gsubOverErr, gsubUnderOk
            """, on: state, slice: 5_000_000
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values.count, 9)
        XCTAssertEqual(values[0], .bool(false), "format over the 65536-byte cap must be refused")
        guard case .string(let formatErr) = values[1] else { return XCTFail() }
        XCTAssertTrue(formatErr.contains("exceeds 65536 bytes"), formatErr)
        XCTAssertEqual(values[2], .bool(true), "format at/below the cap must succeed")

        XCTAssertEqual(values[3], .bool(false), "pack over the 65536-byte cap must be refused")
        guard case .string(let packErr) = values[4] else { return XCTFail() }
        XCTAssertTrue(packErr.contains("exceeds 65536 bytes"), packErr)
        XCTAssertEqual(values[5], .bool(true), "pack at/below the cap must succeed")

        XCTAssertEqual(values[6], .bool(false), "gsub over the 65536-byte result cap must be refused")
        guard case .string(let gsubErr) = values[7] else { return XCTFail() }
        XCTAssertTrue(gsubErr.contains("exceeds 65536 bytes"), gsubErr)
        XCTAssertEqual(values[8], .bool(true), "gsub at/below the cap must succeed")
    }

    // MARK: - Positional table.insert/remove cap (C22)

    func testPositionalInsertRemoveCap() throws {
        // Building a 70,000-element table exceeds the default per-slice
        // allocation-rate budget; this test is about the cap, not the rate budget.
        var budgets = ScriptBudgets.defaults
        budgets.allocationRatePerSliceBytes = 16 * 1024 * 1024
        budgets.memoryCapBytes = 32 * 1024 * 1024
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let outcome = try ScriptTestSupport.run(
            """
            local t = {}
            for i = 1, 70000 do t[i] = i end
            local insertOk, insertErr = pcall(table.insert, t, 1, 0)
            local removeOk, removeErr = pcall(table.remove, t, 1)
            -- Append/pop (non-positional) forms are uncapped.
            local appendOk = pcall(table.insert, t, 999999)
            local popOk = pcall(table.remove, t)
            return insertOk, tostring(insertErr), removeOk, tostring(removeErr), appendOk, popOk
            """, on: state, slice: 5_000_000
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false), "positional insert on a 70,000-element table must be refused")
        guard case .string(let insertErr) = values[1] else { return XCTFail() }
        XCTAssertTrue(insertErr.contains("65536"), insertErr)
        XCTAssertEqual(values[2], .bool(false), "positional remove on a 70,000-element table must be refused")
        guard case .string(let removeErr) = values[3] else { return XCTFail() }
        XCTAssertTrue(removeErr.contains("65536"), removeErr)
        XCTAssertEqual(values[4], .bool(true), "append (table.insert(t, v)) must not be capped")
        XCTAssertEqual(values[5], .bool(true), "pop (table.remove(t)) must not be capped")
    }

    // MARK: - table.concat element-count cap (C22)

    func testConcatElementCountCap() throws {
        // Building a 70,000-element table exceeds the default per-slice
        // allocation-rate budget; this test is about the cap, not the rate budget.
        var budgets = ScriptBudgets.defaults
        budgets.allocationRatePerSliceBytes = 16 * 1024 * 1024
        budgets.memoryCapBytes = 32 * 1024 * 1024
        let state = try ScriptTestSupport.makeState(budgets: budgets)
        let outcome = try ScriptTestSupport.run(
            """
            local t = {}
            for i = 1, 70000 do t[i] = '' end
            local ok, err = pcall(table.concat, t)
            return ok, tostring(err)
            """, on: state, slice: 5_000_000
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false), "table.concat over the 65536-element cap must be refused")
        guard case .string(let message) = values[1] else { return XCTFail() }
        XCTAssertTrue(message.contains("65536"), message)
    }

    // MARK: - table.sort string-length guard (C22)

    func testSortRefusesOversizeStrings() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local t = { ('x'):rep(9000), 'small' }
            local comparatorCalled = false
            local ok, err = pcall(table.sort, t, function(a, b)
                comparatorCalled = true
                return a < b
            end)
            return ok, tostring(err), comparatorCalled
            """, on: state, slice: 5_000_000
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false), "sorting a list with a 9000-byte element must be refused")
        guard case .string(let message) = values[1] else { return XCTFail() }
        XCTAssertTrue(message.contains("8192"), message)
        XCTAssertEqual(values[2], .bool(false), "the comparator must never run once the pre-scan refuses the list")
    }

    // MARK: - Concatenation cap (design.md Decision 3 / script-determinism spec: luaV_concat, ELYSIUM_MAX_STRING)

    func testConcatStringLengthCap() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local a = ('x'):rep(60000)
            local ok, err = pcall(function() return a .. a .. a .. a .. a end)
            local underOk = pcall(function() return a .. a end)
            return ok, tostring(err), underOk
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false), "concatenating past 262,144 bytes must raise \"string too long\"")
        guard case .string(let message) = values[1] else { return XCTFail() }
        XCTAssertTrue(message.contains("string too long"), message)
        XCTAssertEqual(values[2], .bool(true), "concatenation comfortably under the cap must succeed")
        XCTAssertFalse(state.isDead)
    }

    // MARK: - Monkey-patch attempts fail (spec "Monkey-patch attempts fail")

    func testMonkeyPatchAttempts() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local results = {}
            local function attempt(fn)
                local ok = pcall(fn)
                results[#results + 1] = ok
            end
            attempt(function() math.floor = 1 end)
            attempt(function() string.upper = 1 end)
            attempt(function() getmetatable('').__index.upper = 1 end)
            attempt(function() getmetatable(math).__index.floor = 1 end)
            attempt(function() getmetatable(_ENV).__index.print = 1 end)
            attempt(function() rawset(math, 'floor', 1) end)
            return table.unpack(results)
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values.count, 6)
        let labels = ["math.floor=1", "string.upper=1", "getmetatable('').__index.upper=1", "getmetatable(math).__index.floor=1", "getmetatable(_ENV).__index.print=1", "rawset(math,'floor',1)"]
        for (value, label) in zip(values, labels) {
            XCTAssertEqual(value, .bool(false), "\(label) must fail")
        }

        // A second, independent environment must still see the stock behaviour.
        let sink = RecordingLogSink()
        let state2 = try ScriptTestSupport.makeState(log: sink)
        let outcome2 = try ScriptTestSupport.run(
            "print('still stock'); return math.floor(1.9), string.upper('ab')", on: state2
        )
        guard case .success(let values2) = outcome2 else { return XCTFail("expected success on a fresh state, got \(outcome2)") }
        XCTAssertEqual(values2, [.int(1), .string("AB")])
        XCTAssertEqual(sink.lines.first?.line, "still stock")
    }

    // MARK: - Reachability walk (spec "Reachability walk")

    func testFrozenReachabilityWalk() throws {
        // Every table reachable from a fresh environment's known library roots
        // (math/string/table/utf8), other than _ENV itself, must refuse a write;
        // the string metatable must be locked (getmetatable("") returns the literal
        // "locked", never a table); no userdata is reachable from a fresh
        // environment (no handle has been created yet). _ENV itself remains
        // writable, as a sanity control that the probe mechanism actually works.
        //
        // "Every C function reachable is a closure with >= 1 upvalue" (the
        // no-light-C-function invariant, C24) is a fact about the *representation*
        // of a Lua value (LUA_VLCF vs LUA_VCCL) that neither the sandboxed script
        // language nor ElysiumScript's public API can introspect (Lua has no
        // built-in way to distinguish them -- both report type(x) == "function",
        // and `debug` is not sandboxed in) -- ElysiumScript deliberately exposes no
        // raw C API surface to this test target (Condition 25's
        // testPublicSurfaceHasNoRawLuaTypes pins exactly that boundary), so this
        // half is validated at the source level, not here: CLuaSourceTests pins the
        // rewrap pass in elysium_sandbox.c (`elysium_rewrap_table`), and elysmoke's
        // own "sandbox surface hash" check (design.md Decision 13) does the C-level
        // walk with direct access this target does not have.
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local roots = { 'math', 'string', 'table', 'utf8' }
            local visited = {}
            local violations = {}

            local function probe(t, path)
                if visited[t] then return end
                visited[t] = true
                local ok = pcall(function() t.__walkProbe_zzz = 1 end)
                if ok then violations[#violations + 1] = 'writable:' .. path end
                for k, v in pairs(t) do
                    local kk = tostring(k)
                    if type(v) == 'userdata' then
                        violations[#violations + 1] = 'userdata:' .. path .. '.' .. kk
                    elseif type(v) == 'table' then
                        probe(v, path .. '.' .. kk)
                    end
                end
            end

            for _, name in ipairs(roots) do
                probe(_ENV[name], name)
            end

            local envWritable = pcall(function() _ENV.__walkProbe_zzz = 1 end)
            local stringMeta = getmetatable('')

            return #violations, table.concat(violations, '; '), envWritable, stringMeta
            """, on: state, slice: 5_000_000
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .int(0), "violations found: \(values[1])")
        XCTAssertEqual(values[1], .string(""))
        XCTAssertEqual(values[2], .bool(true), "_ENV itself must remain writable (sanity control)")
        XCTAssertEqual(values[3], .string("locked"), "the string metatable must be locked behind the literal '__metatable' value")
    }

    // MARK: - setmetatable: __gc/__mode/__close rejected, script fields kept (C23)

    func testSetmetatableRejectsGcModeClose() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local t = {}
            setmetatable(t, { __gc = function() end, __close = function() end, __mode = 'k', __index = 5 })
            local mt = getmetatable(t)
            return mt.__gc, mt.__close, mt.__mode, mt.__index
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.null, .null, .null, .int(5)], "__gc/__mode/__close must be stripped; other fields survive")
    }

    // MARK: - setmetatable freezes a copy at call time (documented deviation)

    func testSetmetatableFreezesCopy() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local Class = {}
            function Class.greet() return 'hi' end
            local m = { __index = Class }
            local t = setmetatable({}, m)
            -- Sabotaging the *original* metatable table after the fact must not
            -- retroactively change t's already-installed (copied) metatable.
            m.__index = nil
            local stillWorks = (t.greet ~= nil)
            -- But __index's *value* (Class) is a live reference: mutating Class
            -- itself (not m) is visible through the frozen copy.
            function Class.greet2() return 'yo' end
            local liveRef = (t.greet2 ~= nil)
            return stillWorks, liveRef
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.bool(true), .bool(true)])
    }

    // MARK: - setmetatable ownership matrix (C23)

    func testSetmetatableOwnershipMatrix() throws {
        let state = try ScriptTestSupport.makeState()
        let widgetDispatch = HandleDispatch()
        let widgetKind = state.registerHandleKind(name: "widget", dispatch: widgetDispatch, interned: false)
        let handleValue = try state.makeHandle(kind: widgetKind, ref: "widget:1", id: 1)
        let getHandle = HostFunction { _ in .values([handleValue]) }

        let outcome = try ScriptTestSupport.run(
            """
            -- Script-owned frozen copies may be replaced and cleared.
            local t = setmetatable({}, { __index = function() return 'first' end })
            local replaceOk = pcall(setmetatable, t, { __index = function() return 'second' end })
            local clearOk = pcall(setmetatable, t, nil)

            -- Host-owned targets refuse.
            local envOk = pcall(setmetatable, _ENV, {})
            local mathOk = pcall(setmetatable, math, {})
            local stringOk = pcall(setmetatable, '', {})
            local h = getHandle()
            local handleOk = pcall(setmetatable, h, {})

            return replaceOk, clearOk, envOk, mathOk, stringOk, handleOk
            """, on: state, hostBindings: [.function(name: "getHandle", getHandle)]
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(true), "replacing a script-owned frozen copy must succeed")
        XCTAssertEqual(values[1], .bool(true), "clearing a script-owned frozen copy must succeed")
        XCTAssertEqual(values[2], .bool(false), "_ENV's metatable must be refused")
        XCTAssertEqual(values[3], .bool(false), "a library proxy's metatable must be refused")
        XCTAssertEqual(values[4], .bool(false), "the string metatable must be refused")
        XCTAssertEqual(values[5], .bool(false), "a handle's metatable must be refused")
    }

    // MARK: - The read-only view installed as __metatable is itself locked (C23)

    func testGetmetatableOfViewIsLocked() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local t = setmetatable({}, { __index = function() return 1 end })
            local view = getmetatable(t)
            local viewIsTable = (type(view) == 'table')
            local changeViewOk = pcall(setmetatable, view, {})
            return viewIsTable, changeViewOk
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(true), "getmetatable(t) must return the read-only view table")
        XCTAssertEqual(values[1], .bool(false), "the read-only view's own metatable must itself be locked")
    }

    // MARK: - A3-1 (Security (code) attempt 3, HIGH): the per-call read-only-view
    // metatable elysium_setmetatable installs must not be permanently retained

    func testSetmetatableWithoutMetatableFieldDoesNotRetain() throws {
        // security-code.md Finding A3-1: every setmetatable(t, mt) without a
        // script-supplied __metatable field used to mark its fresh read-only-view
        // metatable in the state-wide strong ELYSIUM_HOSTOWNED_KEY registry set --
        // an ordinary table with no manifest entry, so nothing (not collectFull,
        // not any ScriptEnvironment.destroy()) could ever reclaim it: ~336 B
        // retained per call, unboundedly, for the life of the LuaState. The fix
        // marks it structurally inside its own table instead, so once nothing
        // references the view any more it is ordinary garbage.
        let state = try ScriptTestSupport.makeState()
        state.collectFull()
        let baseline = state.memoryStatus.bytesInUse

        let outcome = try ScriptTestSupport.run(
            """
            for i = 1, 1000 do
                setmetatable({}, {})
            end
            return true
            """, on: state, slice: 2_000_000
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.bool(true)])

        state.collectFull()
        let after = state.memoryStatus.bytesInUse
        XCTAssertLessThanOrEqual(
            after, baseline + 16 * 1024,
            "1,000 setmetatable({}, {}) calls must not permanently retain their per-call view metatables (before the fix: ~336 KiB, ~336 B/call, never reclaimed)"
        )
    }

    func testViewMetatableStillRefusedAsHostOwned() throws {
        // The structural-sentinel fix (A3-1) must not weaken C23's ownership
        // refusal: the view's own (locked) metatable is still recognised as
        // host-owned -- now via the sentinel elysium_is_host_owned checks inside
        // the view metatable itself, rather than via the old strong-set lookup --
        // and the view cannot be used to install a new metatable over an
        // already-protected, host-owned target either. The string metatable's
        // check (the unrelated, unchanged strong-registry path for
        // host-constructed metatables) is exercised as a control.
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local t = setmetatable({}, { __index = function() return 1 end })
            local view = getmetatable(t)

            -- The view's own metatable is still host-owned (structural sentinel).
            local changeViewOk = pcall(setmetatable, view, {})

            -- Passing the view as the *proposed* new metatable for an
            -- already-protected target must still refuse, because that target's
            -- own current metatable is host-owned -- unrelated to what the view
            -- is, but confirms the fix did not weaken this refusal.
            local installOnEnvOk = pcall(setmetatable, _ENV, view)

            local lockedString = (getmetatable('') == 'locked')

            return changeViewOk, installOnEnvOk, lockedString
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .bool(false), "the view's own metatable must still be refused as host-owned after the structural-sentinel fix")
        XCTAssertEqual(values[1], .bool(false), "a host-owned target must still refuse a new metatable even when the proposal is the view itself")
        XCTAssertEqual(values[2], .bool(true), "the string metatable's host-owned check (the unchanged strong-registry path) must still hold")
    }

    // MARK: - String metatable: arithmetic metamethods behave deterministically (C24)

    func testStringMetatableHasNoLightCFunctions() throws {
        // As documented on testFrozenReachabilityWalk: pure Lua (and ElysiumScript's
        // public API) cannot distinguish a light C function from a one-upvalue C
        // closure at runtime -- that is a source-level fact CLuaSourceTests pins by
        // reading elysium_sandbox.c's rewrap pass. What this test *can* verify
        // through the language surface: the string metatable is locked, and every
        // arithmetic metamethod it exposes behaves like an ordinary sandboxed
        // function -- callable, deterministic, and address-free -- rather than
        // crashing or leaking anything about its own representation.
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local results = {}
            local function attempt(fn)
                local ok, value = pcall(fn)
                results[#results + 1] = tostring(ok) .. ':' .. tostring(value)
            end
            attempt(function() return ('5') + 1 end)
            attempt(function() return ('5') - 1 end)
            attempt(function() return ('5') * 2 end)
            attempt(function() return -('5') end)
            attempt(function() return ('5') % 2 end)
            attempt(function() return ('2') ^ 2 end)
            attempt(function() return ('4') / 2 end)
            local locked = getmetatable('')
            return table.concat(results, '|'), locked
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        guard case .string(let joined) = values[0] else { return XCTFail() }
        for entry in joined.split(separator: "|") {
            XCTAssertTrue(entry.hasPrefix("true:"), "arithmetic metamethod call failed unexpectedly: \(entry)")
            XCTAssertFalse(entry.contains("0x"), "arithmetic metamethod result must be address-free: \(entry)")
        }
        XCTAssertEqual(values[1], .string("locked"))
    }

    // MARK: - rawset/rawget absent (spec "Removed names are nil")

    func testRawsetAbsent() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run("return rawset, rawget", on: state)
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values, [.null, .null])
    }

    // MARK: - Exact allowlist surface (spec "Exact standard-library allowlist")

    /// scripting-ui-and-replication (change 3): `tan`/`asin`/`acos` move from `mathRemoved`
    /// to `mathMembers` (restored — design.md §8.3 "Removed: tan asin acos (v1)", completed
    /// per §16 row 3/Decision 10) and `log2`/`log10` are new `mathMembers` entries (additive;
    /// `math.log(x, b)` itself is unchanged for every base).
    func testAllowlistSurfaceHash() throws {
        let state = try ScriptTestSupport.makeState()
        let outcome = try ScriptTestSupport.run(
            """
            local function checkPresent(container, names)
                local missing = {}
                for _, n in ipairs(names) do
                    if container[n] == nil then missing[#missing + 1] = n end
                end
                return missing
            end
            local function checkAbsent(container, names)
                local unexpected = {}
                for _, n in ipairs(names) do
                    if container[n] ~= nil then unexpected[#unexpected + 1] = n end
                end
                return unexpected
            end

            local baseMembers = {
                'assert', 'error', 'ipairs', 'next', 'pairs', 'pcall', 'select', 'tonumber',
                'tostring', 'type', 'xpcall', 'rawequal', 'rawlen', 'getmetatable', '_VERSION',
                'print', 'setmetatable',
            }
            local baseRemoved = {
                'load', 'loadfile', 'dofile', 'collectgarbage', 'rawset', 'rawget', 'warn', '_G',
                'loadstring', 'require', 'coroutine', 'os', 'io', 'debug', 'package',
            }
            local stringMembers = {
                'char', 'len', 'lower', 'reverse', 'sub', 'upper', 'packsize', 'unpack',
                'find', 'match', 'gmatch', 'gsub', 'format', 'pack', 'rep', 'byte',
            }
            local stringRemoved = { 'dump' }
            local tableMembers = { 'insert', 'remove', 'pack', 'sort', 'concat', 'unpack', 'move' }
            local mathMembers = {
                'abs', 'ceil', 'deg', 'floor', 'fmod', 'huge', 'maxinteger', 'mininteger', 'modf',
                'pi', 'rad', 'sqrt', 'tointeger', 'type', 'ult', 'min', 'max',
                'random', 'randomseed', 'sin', 'cos', 'atan', 'exp', 'log',
                'tan', 'asin', 'acos', 'log2', 'log10',
            }
            local mathRemoved = { 'pow', 'cosh', 'sinh', 'tanh', 'frexp', 'ldexp' }
            local utf8Members = { 'char', 'charpattern', 'codepoint', 'len', 'offset', 'codes' }

            local problems = {}
            local function report(label, list)
                if #list > 0 then problems[#problems + 1] = label .. ':' .. table.concat(list, ',') end
            end
            report('base-missing', checkPresent(_ENV, baseMembers))
            report('base-unexpected', checkAbsent(_ENV, baseRemoved))
            report('string-missing', checkPresent(string, stringMembers))
            report('string-unexpected', checkAbsent(string, stringRemoved))
            report('table-missing', checkPresent(table, tableMembers))
            report('math-missing', checkPresent(math, mathMembers))
            report('math-unexpected', checkAbsent(math, mathRemoved))
            report('utf8-missing', checkPresent(utf8, utf8Members))

            return #problems, table.concat(problems, '; ')
            """, on: state
        )
        guard case .success(let values) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(values[0], .int(0), "allowlist surface mismatch: \(values[1])")
        XCTAssertEqual(values[1], .string(""))
    }
}
