// Scanned as Sources/ElysiumScript/Other.swift: `lua_error` is on the raising-API
// denylist even inside the sole Lua owner (design.md Decision 4 Rule 1 — only C
// raises; spec "embedded-script-runtime" Swift source denylist).
let lua_error = 1
