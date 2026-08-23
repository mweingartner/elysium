// Scanned as Sources/ElysiumScript/LuaState.swift: mirrors the real file's shape
// (design.md Condition 3, Decision 4) to confirm the scanner accepts legitimate
// sole-owner code — `import CLua`, the one permitted `OpaquePointer` spelling, a
// non-raising `lua_`-prefixed introspection call, and the non-capturing
// `@convention(c)` dispatcher — rather than merely rejecting everything.
import CLua

public typealias LuaStatePointer = OpaquePointer

func topOfStack(_ L: LuaStatePointer) -> Int32 {
    lua_gettop(L)
}

let dispatchStub: @convention(c) (OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Int32 = { _, _, _ in 0 }
