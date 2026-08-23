// ScriptMath.swift — task 3.3. design.md Decision 11: every script-visible transcendental
// (`math.sin/cos/atan/exp/log`, `^`) routes through this table so no libm fallback ever
// exists inside CLua/ElysiumScript. `ElysiumCore/Scripting/ScriptHostBindings.swift`
// supplies the deterministic instance (`ScriptHostMath.deterministic`, wrapping
// `DetMath`'s `detSin/detCos/detAtan2/detExp/detLog/detPow`); ElysiumScript itself
// never imports ElysiumCore (Decision 17), so this type stays a bare table of C
// function pointers with no notion of what backs them.
//
// The function-pointer shape (not a protocol/closure) matters: `elysium_config.math` is
// a C struct of six raw function pointers (`elysium_math_table` in elysium_shim.h) that
// `elysium_numpow` reads directly from `extraspace(L)` on every `^` evaluation and
// constant fold — a Swift closure with captured state could not cross that boundary at
// all, and a *non-capturing* one is exactly what `@convention(c)` requires.

/// A complete, required set of deterministic transcendental functions for one
/// `LuaState` (design.md Decision 11). `LuaState.init` refuses to construct a state
/// without one — there is no default and no libm fallback anywhere in the runtime.
public struct ScriptMath: Sendable {
    public var sin: @convention(c) (Double) -> Double
    public var cos: @convention(c) (Double) -> Double
    public var exp: @convention(c) (Double) -> Double
    public var log: @convention(c) (Double) -> Double
    /// `atan(y[, x])` in Lua is `atan2(y, x or 1)`.
    public var atan2: @convention(c) (Double, Double) -> Double
    /// Backs both `^`/`elysium_numpow` (via `luai_numpow`'s `b == 2` fast path staying
    /// in C) and `math.pow`... (v1 does not expose `math.pow`; `^` only).
    public var pow: @convention(c) (Double, Double) -> Double

    public init(
        sin: @escaping @convention(c) (Double) -> Double,
        cos: @escaping @convention(c) (Double) -> Double,
        exp: @escaping @convention(c) (Double) -> Double,
        log: @escaping @convention(c) (Double) -> Double,
        atan2: @escaping @convention(c) (Double, Double) -> Double,
        pow: @escaping @convention(c) (Double, Double) -> Double
    ) {
        self.sin = sin
        self.cos = cos
        self.exp = exp
        self.log = log
        self.atan2 = atan2
        self.pow = pow
    }
}
