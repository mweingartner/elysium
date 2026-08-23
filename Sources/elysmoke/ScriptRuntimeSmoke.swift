// ScriptRuntimeSmoke.swift — task 5.2. design.md Decision 13's "script runtime (vs
// script-runtime goldens)" section: a fixed corpus run entirely through the
// sandboxed ElysiumScript API (LuaState/ScriptEnvironment/HandleKind/HostBinding —
// never CLua directly), hashed with the file's existing FNV-1a convention, and
// compared against `goldens/script-runtime-goldens.json`. `main.swift` calls
// `runScriptRuntimeSmoke()` right after the fdlibm section; this file owns
// everything else, reusing `check`/`section`/`loadJSON`/`goldenPaths` from
// main.swift (ordinary internal top-level declarations, visible module-wide).
//
// Determinism: one fixed hash seed (state-wide, from the vendored patch), one fixed
// RandomX seed per environment, no wall clock anywhere in the corpus, sorted output
// only where the check itself is about hash-order equality (checks 3/4 deliberately
// use raw `pairs` order — that IS the property under test); every other traversal
// (the sandbox-surface walk) sorts explicitly so its hash reflects content, not
// incidental bucket placement.

import ElysiumCore
import ElysiumScript
import Foundation

// MARK: - Corpus result

/// Everything one full corpus run produces, per design.md Decision 13's ten checks.
/// Equatable so "second state with perturbed heap reproduces all hashes" (check 10)
/// is a single struct comparison between two independent runs.
struct ScriptRuntimeCorpusResult: Equatable {
    var stateCreatedOK: Bool
    var sandboxSurfaceHash: UInt32
    var iterationOrderHash: UInt32
    var ordinalKeysHash: UInt32
    var mathPowRandomHash: UInt32
    var mathPowRandomCrossCheckOK: Bool
    var stringsHash: UInt32
    var addressScanOK: Bool
    var instructionTripKindOK: Bool
    var instructionTripOrdinal: UInt64
    var allocationTripKindOK: Bool
    var allocationTripOrdinal: UInt64
}

enum ScriptRuntimeCorpusError: Error, CustomStringConvertible {
    case unexpected(String)
    var description: String {
        switch self { case .unexpected(let s): return s }
    }
}

/// Captures every `print` line (envId >= 1) so it can be folded into the address-scan
/// corpus (check 7) — a real host sink, not a bare no-op, so `print` really does
/// reach somewhere observable the way the shipped app's would.
private final class ScriptRuntimeLogSink: ScriptLogSink {
    private(set) var lines: [String] = []
    func log(envId: UInt64, line: String) { lines.append(line) }
}

// MARK: - Small local helpers (this file's own — main.swift's are scoped inside its
// own `if let g = ...` blocks and are not reachable here)

private func fnvHashString(_ s: String) -> UInt32 {
    var h: UInt32 = 2_166_136_261
    for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
    return h
}

private func scriptHexD(_ x: Double) -> String {
    String(x.bitPattern >> 32, radix: 16) + "-" + String(x.bitPattern & 0xffff_ffff, radix: 16)
}

private func scriptValuesBitExact(_ a: ScriptValue, _ b: ScriptValue) -> Bool {
    switch (a, b) {
    case (.number(let x), .number(let y)):
        return x.bitPattern == y.bitPattern || (x.isNaN && y.isNaN)
    case (.int(let x), .int(let y)):
        return x == y
    default:
        return a == b
    }
}

/// design.md Condition 29 / elysmoke check 7: scans constructed corpus text for an
/// address-shaped token. Never applied as a filter over the corpus — only as a
/// diagnostic assertion that none ever appears.
private func containsAddressLikeToken(_ s: String) -> Bool {
    s.range(of: "0[xX][0-9a-fA-F]+", options: .regularExpression) != nil
}

/// A deterministic, fixed set of allocate-then-free blocks (design.md Decision 9's
/// evidence: "perturbs the heap... creates a second state") — plain Swift/Foundation
/// churn, no ElysiumScript involved, so the *second* corpus run starts from a
/// different process heap layout than the first without changing anything about the
/// corpus itself.
private func elysiumPerturbHeap() {
    var blocks: [[UInt8]] = []
    blocks.reserveCapacity(4_096)
    for i in 0..<4_096 {
        blocks.append([UInt8](repeating: UInt8(truncatingIfNeeded: i), count: (i % 251) + 1))
    }
    blocks.removeAll(keepingCapacity: false)

    var strings: [String] = []
    strings.reserveCapacity(2_048)
    for i in 0..<2_048 {
        strings.append(String(repeating: "z", count: (i % 97) + 1) + String(i))
    }
    strings.removeAll(keepingCapacity: false)
}

// MARK: - Golden I/O

private struct ScriptRuntimeGolden {
    let sandboxSurfaceHash: UInt32
    let iterationOrderHash: UInt32
    let ordinalKeysHash: UInt32
    let mathPowRandomHash: UInt32
    let stringsHash: UInt32
    let instructionTripOrdinal: UInt64
    let allocationTripOrdinal: UInt64
}

private func loadScriptRuntimeGolden() -> ScriptRuntimeGolden? {
    guard let g = loadJSON("script-runtime-goldens.json") else { return nil }
    guard
        let sandboxSurfaceHash = (g["sandboxSurfaceHash"] as? NSNumber)?.uint32Value,
        let iterationOrderHash = (g["iterationOrderHash"] as? NSNumber)?.uint32Value,
        let ordinalKeysHash = (g["ordinalKeysHash"] as? NSNumber)?.uint32Value,
        let mathPowRandomHash = (g["mathPowRandomHash"] as? NSNumber)?.uint32Value,
        let stringsHash = (g["stringsHash"] as? NSNumber)?.uint32Value,
        let instructionTripOrdinal = (g["instructionTripOrdinal"] as? NSNumber)?.uint64Value,
        let allocationTripOrdinal = (g["allocationTripOrdinal"] as? NSNumber)?.uint64Value
    else { return nil }
    return ScriptRuntimeGolden(
        sandboxSurfaceHash: sandboxSurfaceHash, iterationOrderHash: iterationOrderHash,
        ordinalKeysHash: ordinalKeysHash, mathPowRandomHash: mathPowRandomHash,
        stringsHash: stringsHash, instructionTripOrdinal: instructionTripOrdinal,
        allocationTripOrdinal: allocationTripOrdinal
    )
}

private func writeScriptRuntimeGolden(_ r: ScriptRuntimeCorpusResult) {
    let obj: [String: Any] = [
        "sandboxSurfaceHash": NSNumber(value: r.sandboxSurfaceHash),
        "iterationOrderHash": NSNumber(value: r.iterationOrderHash),
        "ordinalKeysHash": NSNumber(value: r.ordinalKeysHash),
        "mathPowRandomHash": NSNumber(value: r.mathPowRandomHash),
        "stringsHash": NSNumber(value: r.stringsHash),
        "instructionTripOrdinal": NSNumber(value: r.instructionTripOrdinal),
        "allocationTripOrdinal": NSNumber(value: r.allocationTripOrdinal),
    ]
    guard let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else {
        print("    FAILED to encode script-runtime-goldens.json")
        return
    }
    let path = goldenPaths("script-runtime-goldens.json")[0]
    do {
        try out.write(to: URL(fileURLWithPath: path))
        print("    REGENERATED \(path)")
    } catch {
        print("    FAILED to write \(path): \(error)")
    }
}

// MARK: - The corpus itself

/// Runs the whole fixed corpus once end to end and returns every value the ten
/// checks need. Called twice by `runScriptRuntimeSmoke()` — once for the first
/// state, once more after `elysiumPerturbHeap()` for check 10 — so this function's
/// own determinism (same seeds, same budgets, same script text every time) is what
/// makes the two-state comparison meaningful.
func runScriptRuntimeCorpus() throws -> ScriptRuntimeCorpusResult {
    // ---- Main state: checks 1, 2, 3, 4 (main-thread half), 5, 6, 7 -------------
    let sink = ScriptRuntimeLogSink()
    let state = try LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: sink)
    let stateCreatedStructurallyOK = !state.isDead

    // A handle kind registered once per state, used only by check 4's "getHandle"
    // host binding (design.md Decision 10: handles are the one key/value shape a
    // script cannot construct on its own — every handle a script ever sees came
    // from a host function).
    let handleKind = state.registerHandleKind(name: "probe", dispatch: HandleDispatch(), interned: true)
    let getHandle = HostFunction { call -> HostResult in
        guard case .value(.int(let idValue)) = call.arguments.first else {
            return .error("expected an integer id")
        }
        guard let handleValue = try? call.state.makeHandle(kind: handleKind, ref: "probe:\(idValue)", id: UInt64(idValue)) else {
            return .error("could not make handle")
        }
        return .values([handleValue])
    }

    let mainEnv = state.makeEnvironment(
        name: "corpus", hostBindings: [.function(name: "getHandle", getHandle)], random: RandomX(9_001)
    )

    var producedStrings: [String] = []

    // ---- Check 1: state created (math installed, locale pinned) ---------------
    // A state with an incomplete ScriptMath table or an unpinned locale never
    // reaches this line at all (LuaState.init throws first) — the locale probe
    // below is the *content* half of the assertion (spec "Locale pin" scenario).
    let localeFn = try mainEnv.compile(
        source: "return tostring(1.5), tonumber(\"1.5\"), (\"a\" < \"B\")", chunkName: "localeProbe"
    ).get()
    let localeOutcome = try state.call(localeFn, args: [], slice: 100_000)
    var stateCreatedOK = stateCreatedStructurallyOK
    if case .success(let values) = localeOutcome {
        stateCreatedOK = stateCreatedOK && values == [.string("1.5"), .number(1.5), .bool(false)]
    } else {
        stateCreatedOK = false
    }

    // ---- Check 2: sandbox surface hash -----------------------------------------
    // Explicit allowlist probe (design.md Decision 8's D8 comment: "base/string/
    // table/math/utf8 only — never coroutine/os/io/package/debug") plus a sorted
    // recursive walk of the four library tables, which — unlike bare `_ENV` itself
    // (an empty table reached only through `__index`, with no `__pairs`) — really
    // are enumerable via `pairs` (each is a frozen proxy with a `__pairs`
    // iterator). `_ENV[name]` is a plain indexing operation (never a metamethod
    // *call*) so probing an absent name is safe and returns "nil".
    let surfaceSource = """
        local function walk(t, prefix, out)
          local keys = {}
          for k in pairs(t) do keys[#keys + 1] = k end
          table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
          for _, k in ipairs(keys) do
            local v = t[k]
            local name = prefix .. tostring(k)
            out[#out + 1] = name .. ":" .. type(v)
            if type(v) == "table" then
              walk(v, name .. ".", out)
            end
          end
        end
        local topNames = {
          "assert", "collectgarbage", "dofile", "error", "ipairs", "load", "loadfile",
          "next", "pairs", "pcall", "print", "rawequal", "rawget", "rawlen", "rawset",
          "require", "select", "setmetatable", "tonumber", "tostring", "type", "warn",
          "xpcall", "_G", "_VERSION", "string", "table", "math", "utf8",
          "coroutine", "os", "io", "package", "debug"
        }
        local out = {}
        for _, name in ipairs(topNames) do
          out[#out + 1] = name .. ":" .. type(_ENV[name])
        end
        walk(string, "string.", out)
        walk(table, "table.", out)
        walk(math, "math.", out)
        walk(utf8, "utf8.", out)
        return table.concat(out, "\\n")
        """
    let surfaceFn = try mainEnv.compile(source: surfaceSource, chunkName: "sandboxSurface").get()
    guard case .success(let surfaceValues) = try state.call(surfaceFn, args: [], slice: 2_000_000),
        surfaceValues.count == 1, case .string(let surfaceTrace) = surfaceValues[0]
    else {
        throw ScriptRuntimeCorpusError.unexpected("sandbox surface corpus did not return a string")
    }
    producedStrings.append(surfaceTrace)
    let sandboxSurfaceHash = fnvHashString(surfaceTrace)

    // ---- Check 3: iteration order (string/int/mixed keys) ---------------------
    // spec "String-keyed iteration": many generated string keys, plus a fixed set
    // of int/string mixed keys, iterated in raw (unsorted) `pairs` order — the
    // property under test is exactly that this order is a pure function of
    // operation history (ordinal hashing + the fixed hash seed), so nothing here
    // sorts before hashing. Returned as a *list* of small per-entry strings, one
    // marshaled `ScriptValue` each, rather than one `table.concat`-ed blob — a
    // single string is capped at `ScriptValueLimits.stringBytes` (4 KiB by
    // design.md Decision 6), which several hundred "kNNN=NNN" entries would
    // exceed; the list cap (256 elements) is why the key count below is 229, not
    // the spec illustration's round 1,000.
    let iterationSource = """
        local t = {}
        for i = 1, 220 do
          t["k" .. i] = i
        end
        t[1] = "one"; t[2] = "two"; t[3] = "three"
        t["alpha"] = 111; t["beta"] = 222; t["gamma"] = 333
        t[300] = "threehundred"; t[-5] = "neg5"; t[0] = "zero"
        local out = {}
        for k, v in pairs(t) do
          out[#out + 1] = tostring(k) .. "=" .. tostring(v)
        end
        return out
        """
    let iterationFn = try mainEnv.compile(source: iterationSource, chunkName: "iterationOrder").get()
    let iterationOutcome = try state.call(iterationFn, args: [], slice: 2_000_000)
    guard case .success(let iterationValues) = iterationOutcome,
        iterationValues.count == 1, case .list(let iterationItems) = iterationValues[0]
    else {
        throw ScriptRuntimeCorpusError.unexpected("iteration-order corpus did not return a list: \(iterationOutcome)")
    }
    var iterationParts: [String] = []
    iterationParts.reserveCapacity(iterationItems.count)
    for item in iterationItems {
        guard case .string(let entry) = item else {
            throw ScriptRuntimeCorpusError.unexpected("iteration-order corpus produced a non-string element")
        }
        iterationParts.append(entry)
    }
    let iterationTrace = iterationParts.joined(separator: ",")
    producedStrings.append(iterationTrace)
    let iterationOrderHash = fnvHashString(iterationTrace)

    // ---- Check 4: ordinal keys (tables/closures/handles/threads) --------------
    // "threads" here means the corpus is run once as a plain top-level call (the
    // main thread) and once more as a resumed coroutine (a genuinely different
    // `lua_State *`) — the `coroutine` library itself is not sandbox-visible (D8),
    // so a script can never hold a first-class thread value; what *is* testable,
    // and is exactly what the vendored patch's shared `global_State.nextOrdinal`
    // promises, is that objects created on either thread of the same state share
    // one ordinal sequence and therefore one deterministic iteration order.
    let ordinalMainSource = """
        local seen = {}
        for i = 1, 60 do
          local key
          local kind = i % 3
          if kind == 0 then key = {}
          elseif kind == 1 then key = function() end
          else key = getHandle(i) end
          seen[key] = i
        end
        local out = {}
        for k, v in pairs(seen) do
          out[#out + 1] = tostring(v)
        end
        return table.concat(out, ",")
        """
    let ordinalCoroSource = """
        local seen2 = {}
        for i = 1, 60 do
          local key
          local kind = i % 3
          if kind == 0 then key = {}
          elseif kind == 1 then key = function() end
          else key = getHandle(1000 + i) end
          seen2[key] = i
        end
        local out = {}
        for k, v in pairs(seen2) do
          out[#out + 1] = tostring(v)
        end
        return table.concat(out, ",")
        """
    let ordinalMainFn = try mainEnv.compile(source: ordinalMainSource, chunkName: "ordinalMain").get()
    guard case .success(let ordinalMainValues) = try state.call(ordinalMainFn, args: [], slice: 2_000_000),
        ordinalMainValues.count == 1, case .string(let ordinalMainTrace) = ordinalMainValues[0]
    else {
        throw ScriptRuntimeCorpusError.unexpected("ordinal-keys (main thread) corpus did not return a string")
    }

    let ordinalCoroFn = try mainEnv.compile(source: ordinalCoroSource, chunkName: "ordinalCoro").get()
    guard let ordinalCoroutine = try state.makeCoroutine(function: ordinalCoroFn) else {
        throw ScriptRuntimeCorpusError.unexpected("could not create the ordinal-keys coroutine")
    }
    guard case .completed(let ordinalCoroValues) = try state.resume(ordinalCoroutine, args: [], slice: 2_000_000),
        ordinalCoroValues.count == 1, case .string(let ordinalCoroTrace) = ordinalCoroValues[0]
    else {
        throw ScriptRuntimeCorpusError.unexpected("ordinal-keys (coroutine) corpus did not complete with a string")
    }
    try state.close(ordinalCoroutine)

    producedStrings.append(ordinalMainTrace)
    producedStrings.append(ordinalCoroTrace)
    let ordinalKeysHash = fnvHashString(ordinalMainTrace + "|" + ordinalCoroTrace)

    // ---- Check 5: math/pow/random ----------------------------------------------
    // spec "Math corpus golden": sin/cos/atan/exp/log over fixed inputs, `x^y`,
    // `2^0.5` as a compile-time-folded literal, then math.random from the
    // environment's own fixed-seed stream — cross-checked bit-for-bit against
    // `detSin/detCos/detAtan2/detExp/detLog/detPow` and an independent `RandomX`
    // replica, not just hashed and trusted.
    let xs: [Double] = [0.5, 1.0, 1.5707963267948966, -2.5, 3.14159, 10.0, 0.001, 100.0]
    let mathSource = """
        local xs = {0.5, 1.0, 1.5707963267948966, -2.5, 3.14159, 10.0, 0.001, 100.0}
        local out = {}
        for _, x in ipairs(xs) do
          out[#out + 1] = math.sin(x)
          out[#out + 1] = math.cos(x)
          out[#out + 1] = math.atan(x)
          out[#out + 1] = math.exp(x / 10)
          out[#out + 1] = math.log(x + 10)
          out[#out + 1] = x ^ 3.0
        end
        out[#out + 1] = 2 ^ 0.5
        for i = 1, 20 do
          out[#out + 1] = math.random()
        end
        for i = 1, 10 do
          out[#out + 1] = math.random(1, 1000)
        end
        return out
        """
    let mathFn = try mainEnv.compile(source: mathSource, chunkName: "mathPowRandom").get()
    let mathOutcome = try state.call(mathFn, args: [], slice: 2_000_000)
    guard case .success(let mathOuterValues) = mathOutcome,
        mathOuterValues.count == 1, case .list(let mathItems) = mathOuterValues[0], mathItems.count == 79
    else {
        throw ScriptRuntimeCorpusError.unexpected("math/pow/random corpus did not return a 79-element list: \(mathOutcome)")
    }

    var expected: [ScriptValue] = []
    expected.reserveCapacity(79)
    for x in xs {
        expected.append(.number(detSin(x)))
        expected.append(.number(detCos(x)))
        expected.append(.number(detAtan2(x, 1.0)))
        expected.append(.number(detExp(x / 10)))
        expected.append(.number(detLog(x + 10)))
        expected.append(.number(detPow(x, 3.0)))
    }
    expected.append(.number(detPow(2.0, 0.5)))
    var referenceRNG = RandomX(9_001)
    for _ in 0..<20 {
        let draw = Double(referenceRNG.next()) / 4_294_967_296.0
        expected.append(.number(draw))
    }
    for _ in 0..<10 {
        let draw = Double(referenceRNG.next()) / 4_294_967_296.0
        let span: UInt64 = 1_000
        let offset = min(UInt64(draw * Double(span)), span - 1)
        expected.append(.int(1 + Int64(offset)))
    }

    var mathCrossCheckOK = expected.count == mathItems.count
    if mathCrossCheckOK {
        for (a, b) in zip(mathItems, expected) where !scriptValuesBitExact(a, b) {
            mathCrossCheckOK = false
            break
        }
    }
    let mathTrace = mathItems.map { item -> String in
        switch item {
        case .number(let d): return "n:" + scriptHexD(d)
        case .int(let i): return "i:\(i)"
        default: return "?"
        }
    }.joined(separator: ",")
    let mathPowRandomHash = fnvHashString(mathTrace)

    // ---- Check 6: strings/format/patterns/tostring/errors ---------------------
    // Includes C34's NaN-formatting cases (`tostring(0/0)`, `string.format("%q",
    // 0/0)`) so the golden pins the arm64 NaN text exactly as design.md Decision 9
    // requires.
    let stringsSource = """
        local out = {}
        local function add(s) out[#out + 1] = s end
        add(string.format("%d-%s-%.3f", 42, "hi", 3.14159))
        add(string.format("%5d|%-5d|%05d", 7, 7, 7))
        add(("hello world"):upper())
        add(("HELLO"):lower())
        local fs, fe = ("abcabcabc"):find("bc")
        add(fs .. "," .. fe)
        add((("abc123def456"):gsub("%d+", "#")))
        add(("  trim me  "):match("^%s*(.-)%s*$"))
        add(("x"):rep(5))
        add(table.concat({"a", "b", "c"}, "-"))
        add(tostring(nil))
        add(tostring(true))
        add(tostring(false))
        add(tostring(42))
        add(tostring(3.5))
        add(tostring(0/0))
        add(tostring(1/0))
        add(tostring(-1/0))
        add(string.format("%q", 0/0))
        add(string.format("%q", "line1\\nline2\\"quote\\""))
        local ok1, err1 = pcall(function() error("deliberate error") end)
        add(tostring(err1))
        local ok2, err2 = pcall(function() local n = nil; return n() end)
        add(tostring(err2))
        local ok3, err3 = pcall(function()
          local t = setmetatable({}, { __index = function() error("boom") end })
          return t.x
        end)
        add(tostring(err3))
        print("nan-check: " .. tostring(0/0))
        return out
        """
    let stringsFn = try mainEnv.compile(source: stringsSource, chunkName: "stringsCorpus").get()
    guard case .success(let stringsOuterValues) = try state.call(stringsFn, args: [], slice: 2_000_000),
        stringsOuterValues.count == 1, case .list(let stringItems) = stringsOuterValues[0]
    else {
        throw ScriptRuntimeCorpusError.unexpected("strings corpus did not return a list")
    }
    var stringTraceParts: [String] = []
    for item in stringItems {
        guard case .string(let s) = item else {
            throw ScriptRuntimeCorpusError.unexpected("strings corpus produced a non-string element")
        }
        producedStrings.append(s)
        stringTraceParts.append(s)
    }
    producedStrings.append(contentsOf: sink.lines)
    let stringsHash = fnvHashString(stringTraceParts.joined(separator: "\u{1}"))

    // A genuinely uncaught top-level error (not pcall-caught) so its message and
    // traceback text are also swept by the address scan below — the fault path
    // (elysium_msgh / luaL_traceback) is a different code path than the pcall'd
    // errors above and deserves its own coverage here.
    let uncaughtFn = try mainEnv.compile(
        source: "local function inner() error(\"uncaught corpus error\") end; inner()", chunkName: "uncaught"
    ).get()
    if case .failure(let fault) = try state.call(uncaughtFn, args: [], slice: 2_000_000) {
        producedStrings.append(fault.message)
        producedStrings.append(fault.traceback)
    }

    // ---- Check 7: no address-like output in script-visible text ---------------
    let addressScanOK = !producedStrings.contains(where: containsAddressLikeToken)

    // ---- Check 8: instruction budget trip ordinal ------------------------------
    // A coroutine (not a top-level `call()`) so the exact instruction count at the
    // moment of the trip is observable afterward via `ScriptCoroutine.instructionsUsed`
    // (design.md Condition 21) — the slice passed to `resume` is deliberately far
    // larger than the lifetime total so the *total* cap trips deterministically,
    // never the per-slice one.
    var instructionBudgets = ScriptBudgets.defaults
    instructionBudgets.handlerTotalInstructions = 4_000
    let instructionState = try LuaState(
        budgets: instructionBudgets, math: ScriptHostMath.deterministic, log: ScriptRuntimeLogSink()
    )
    let instructionEnv = instructionState.makeEnvironment(name: "instructionTrip", random: RandomX(101))
    let instructionFn = try instructionEnv.compile(
        source: "local i = 0; while true do i = i + 1 end", chunkName: "instructionTripLoop"
    ).get()
    guard let instructionCoroutine = try instructionState.makeCoroutine(function: instructionFn) else {
        throw ScriptRuntimeCorpusError.unexpected("could not create the instruction-trip coroutine")
    }
    let instructionOutcome = try instructionState.resume(instructionCoroutine, args: [], slice: 1_000_000)
    var instructionTripKindOK = false
    if case .faulted(let fault) = instructionOutcome, fault.kind == .instructionBudget {
        instructionTripKindOK = true
    }
    let instructionTripOrdinal = instructionCoroutine.instructionsUsed

    // ---- Check 9: allocation trip ordinal --------------------------------------
    // A top-level `call()` this time (design.md Condition 35's hard slice applies
    // and is irrelevant here — the allocation-rate cap trips first, in the first
    // few dozen iterations, long before any slice/total instruction count could
    // matter). The ordinal is the state-wide `allocationCalls` counter (task 1.3:
    // state-wide, never per-coroutine) at the moment of the trip.
    var allocationBudgets = ScriptBudgets.defaults
    allocationBudgets.allocationRatePerSliceBytes = 4_096
    let allocationState = try LuaState(
        budgets: allocationBudgets, math: ScriptHostMath.deterministic, log: ScriptRuntimeLogSink()
    )
    let allocationEnv = allocationState.makeEnvironment(name: "allocationTrip", random: RandomX(202))
    let allocationFn = try allocationEnv.compile(
        source: "local t = {}; local i = 0; while true do i = i + 1; t[i] = (\"x\"):rep(64) end",
        chunkName: "allocationTripLoop"
    ).get()
    let allocationOutcome = try allocationState.call(allocationFn, args: [], slice: 2_000_000)
    var allocationTripKindOK = false
    if case .failure(let fault) = allocationOutcome, fault.kind == .allocationRate {
        allocationTripKindOK = true
    }
    let allocationTripOrdinal = allocationState.memoryStatus.allocationCalls

    return ScriptRuntimeCorpusResult(
        stateCreatedOK: stateCreatedOK,
        sandboxSurfaceHash: sandboxSurfaceHash,
        iterationOrderHash: iterationOrderHash,
        ordinalKeysHash: ordinalKeysHash,
        mathPowRandomHash: mathPowRandomHash,
        mathPowRandomCrossCheckOK: mathCrossCheckOK,
        stringsHash: stringsHash,
        addressScanOK: addressScanOK,
        instructionTripKindOK: instructionTripKindOK,
        instructionTripOrdinal: instructionTripOrdinal,
        allocationTripKindOK: allocationTripKindOK,
        allocationTripOrdinal: allocationTripOrdinal
    )
}

// MARK: - Section entry point (called from main.swift right after the fdlibm section)

private let scriptRuntimeCheckNames = [
    "script runtime state created",
    "sandbox surface hash",
    "corpus hash: iteration order (string/int/mixed keys)",
    "corpus hash: ordinal keys (tables/closures/handles/threads)",
    "corpus hash: math/pow/random",
    "corpus hash: strings/format/patterns/tostring/errors",
    "no address-like output in script-visible text",
    "instruction budget trip ordinal",
    "allocation trip ordinal",
    "second state with perturbed heap reproduces all hashes",
]

func runScriptRuntimeSmoke() {
    section("script runtime (vs script-runtime goldens)")

    do {
        let result1 = try runScriptRuntimeCorpus()
        elysiumPerturbHeap()
        let result2 = try runScriptRuntimeCorpus()

        if ProcessInfo.processInfo.environment["ELYSIUM_REGOLD"] != nil {
            writeScriptRuntimeGolden(result1)
            check("script runtime: goldens regenerated (native baseline)", true)
            return
        }

        guard let g = loadScriptRuntimeGolden() else {
            for name in scriptRuntimeCheckNames {
                check(name, false, "not found — run from the repo root (goldens/)")
            }
            return
        }

        check("script runtime state created", result1.stateCreatedOK)
        check("sandbox surface hash", result1.sandboxSurfaceHash == g.sandboxSurfaceHash)
        check(
            "corpus hash: iteration order (string/int/mixed keys)",
            result1.iterationOrderHash == g.iterationOrderHash
        )
        check(
            "corpus hash: ordinal keys (tables/closures/handles/threads)",
            result1.ordinalKeysHash == g.ordinalKeysHash
        )
        check(
            "corpus hash: math/pow/random",
            result1.mathPowRandomHash == g.mathPowRandomHash && result1.mathPowRandomCrossCheckOK
        )
        check(
            "corpus hash: strings/format/patterns/tostring/errors",
            result1.stringsHash == g.stringsHash
        )
        check("no address-like output in script-visible text", result1.addressScanOK && result2.addressScanOK)
        check(
            "instruction budget trip ordinal",
            result1.instructionTripKindOK && result1.instructionTripOrdinal == g.instructionTripOrdinal
        )
        check(
            "allocation trip ordinal",
            result1.allocationTripKindOK && result1.allocationTripOrdinal == g.allocationTripOrdinal
        )
        check("second state with perturbed heap reproduces all hashes", result1 == result2)
    } catch {
        for name in scriptRuntimeCheckNames {
            check(name, false, "\(error)")
        }
    }
}
