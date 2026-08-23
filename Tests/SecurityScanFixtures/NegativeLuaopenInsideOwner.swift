// Scanned as Sources/ElysiumScript/Other.swift: `luaopen_` joins the raising-API
// denylist even inside the sole Lua owner (design.md C25 amendment) — library
// opening happens only in `elysium_sandbox.c`, never from Swift.
let luaopen_forbiddenInsideOwner = 1
