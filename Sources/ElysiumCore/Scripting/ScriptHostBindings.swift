// ScriptHostBindings.swift — task 3.4 (the ElysiumCore half; ElysiumScript's own half
// of the seam is `Sources/ElysiumScript/ScriptMath.swift` /
// `ScriptRandomStream.swift`). design.md Decision 11: `ElysiumCore -> ElysiumScript`
// is the dependency direction, so `ElysiumScript` cannot see `DetMath`/`RandomX` —
// this file is the only place in the whole package where the deterministic math
// kernels and the sfc32 generator meet the script runtime's abstract seams.
//
// Nothing else in `ElysiumCore` changes: no `LuaState` is ever constructed by the app
// in this change (design.md Condition 15) — this file exists purely so 1a onward has a
// ready-made `ScriptMath` instance and an `RandomX -> ScriptRandomStream` conformance
// to hand to `LuaState.init`/`makeEnvironment`.

import ElysiumScript

/// `2^19 * (pi/2)` — the exact threshold `DetMath.swift`'s private `remPio2` traps
/// above (`ix > 0x413921fb`, i.e. `|x| > 2^19*(pi/2)`; see `DetMath.swift:143,178`).
/// Recomputed here rather than imported because `remPio2`'s threshold constant is
/// `private` to that file (Swift's `private` is file-scoped, not just type-scoped) —
/// this is the same bound, not an independent guess at it.
private let elysiumTrigTrapThreshold = 524_288.0 * (Double.pi / 2)

/// design.md Decision 9 / Condition 9: script-facing `sin`/`cos` must never trap, so
/// any input at or past the trap threshold is range-reduced first with `fmod` (IEEE-
/// exact, deterministic per design.md Decision 9) before reaching `detSin`/`detCos`.
/// Non-finite inputs are passed straight through — `detSin`/`detCos` already special-
/// case `|x| >= 0x7ff00000` (NaN/Inf) *before* ever calling the trapping reduction, so
/// there is nothing to guard there, and `fmod` of a non-finite value is itself NaN,
/// which would only reroute through the very same special case anyway.
@inline(__always)
private func elysiumReduceForTrig(_ x: Double) -> Double {
    guard x.isFinite, abs(x) >= elysiumTrigTrapThreshold else { return x }
    return x.truncatingRemainder(dividingBy: 2 * Double.pi)
}

/// Non-capturing top-level functions (required to convert to `@convention(c)` —
/// design.md Decision 11: `ScriptMath` is a table of C function pointers, not
/// closures, because `elysium_numpow` reads it from `extraspace(L)` on every `^`
/// evaluation and constant fold).
private func elysiumScriptDetSin(_ x: Double) -> Double { detSin(elysiumReduceForTrig(x)) }
private func elysiumScriptDetCos(_ x: Double) -> Double { detCos(elysiumReduceForTrig(x)) }

/// The deterministic `ScriptMath` every `LuaState` in the shipped app uses (design.md
/// Decision 11).
public enum ScriptHostMath {
    /// scripting-ui-and-replication (change 3), design.md §16 row 3 / Decision 10:
    /// `tan`/`asin`/`acos`/`log2`/`log10` route to the fdlibm ports `de4e78c` already
    /// landed in `DetMath.swift` — this is the wiring, not the port. Unlike `sin`/`cos`,
    /// none of the five need `elysiumReduceForTrig`'s guard: `detTan`'s own doc comment
    /// says it "reduces every finite argument via `tanRemPio2`, including magnitudes
    /// needing the full Payne-Hanek reduction" (never hits `remPio2`'s trap), and
    /// `detAsin`/`detAcos`/`detLog2`/`detLog10` are domain-restricted, not periodic —
    /// each returns NaN/-inf outside its domain rather than trapping (their own doc
    /// comments: "never traps").
    public static let deterministic = ScriptMath(
        sin: elysiumScriptDetSin,
        cos: elysiumScriptDetCos,
        exp: detExp,
        log: detLog,
        atan2: detAtan2,
        pow: detPow,
        tan: detTan,
        asin: detAsin,
        acos: detAcos,
        log2: detLog2,
        log10: detLog10
    )
}

/// `RandomX` (sfc32; `Core/RandomX.swift`) already carries `init(stateWords:)` and
/// `stateWords` for exact state round-tripping (1c's persisted per-script streams);
/// this conformance is the only change here — no method bodies, no new storage.
extension RandomX: ScriptRandomStream {
    public mutating func nextUInt32() -> UInt32 { next() }
    public mutating func reseed(_ seed: UInt32) { self = RandomX(seed) }
}
