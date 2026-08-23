// Scanned as Sources/ElysiumScript/Other.swift: `OpaquePointer` is confined to
// `Sources/ElysiumScript/LuaState.swift` (design.md Condition 3) — every other file
// in the sole Lua owner must reach the pointer type through the `LuaStatePointer`
// typealias instead.
let forbiddenOpaquePointerOutsideLuaOwner: OpaquePointer? = nil
