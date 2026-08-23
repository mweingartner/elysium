// ScriptRandomStream.swift — task 3.3. design.md Decision 11: `math.random`/
// `math.randomseed` draw from the environment's own stream, never a process-global
// generator and never libc `random()`/`rand()`. `ElysiumCore/Scripting/
// ScriptHostBindings.swift` conforms `RandomX` to this protocol; `ElysiumScript` itself
// has no notion of which generator backs it.

/// A per-environment, deterministic 32-bit random stream. `next()` alone must fully
/// determine every draw `math.random`/`math.randomseed` produce (spec
/// "Script-visible math, RNG and locale are host-determined": `random()` =
/// `next()/2^32`, spans up to 2^53 combine two draws, `random(0)` combines two draws
/// for 64 bits).
public protocol ScriptRandomStream {
    mutating func nextUInt32() -> UInt32
    /// Deterministically reseeds the stream from a 32-bit seed (design.md: `randomseed(n)`
    /// reseeds from `UInt32(truncatingIfNeeded:)` of the script's argument).
    mutating func reseed(_ seed: UInt32)
}
