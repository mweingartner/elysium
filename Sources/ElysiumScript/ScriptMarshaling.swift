// ScriptMarshaling.swift — task 3.2 (the other half of ScriptValue.swift). Lua<->Swift
// value conversion with the caps from spec "ScriptValue marshaling with caps"
// (design.md Decision 10). Every function here is an `extension LuaState` so it can
// reach `pointer`'s raw stack through the `LuaStatePointer` typealias without ever
// spelling `OpaquePointer` itself (design.md Condition 3).
//
// design.md Condition 26 discipline throughout: every table walk uses `lua_next`
// read-only, resuming only with the key that same walk produced; every string read
// uses `lua_tolstring` + explicit length (never `String(cString:)`), decoded with
// repair (`String(decoding:as:)`), never truncated mid-scalar.

import CLua

extension LuaState {
    // MARK: - Swift -> Lua (push)

    /// Pushes `value` onto `L`'s stack, enforcing `valueLimits` at every level.
    /// `depth` counts *container* nesting only (a string/int/number/bool/null/ref at
    /// any depth is a leaf, never itself charged against the depth cap). `nodeCount`
    /// enforces the same total-node cap as the pull direction (note N2: the push
    /// side used to let a host push more than `valueLimits.nodes` nodes while the
    /// pull side refused them symmetrically) -- callers start it at 0 per top-level
    /// value being pushed, matching `pullScriptValue`'s own per-value reset.
    func pushScriptValue(_ value: ScriptValue, on L: LuaStatePointer, depth: Int, nodeCount: inout Int) throws {
        nodeCount += 1
        guard nodeCount <= valueLimits.nodes else { throw ScriptValueError.tooManyNodes(limit: valueLimits.nodes) }

        switch value {
        case .null:
            lua_pushnil(L)
        case .bool(let b):
            lua_pushboolean(L, b ? 1 : 0)
        case .int(let i):
            lua_pushinteger(L, lua_Integer(i))
        case .number(let d):
            guard d.isFinite else { throw ScriptValueError.notFinite }
            lua_pushnumber(L, d == 0 ? 0 : d)
        case .string(let s):
            let byteCount = s.utf8.count
            guard byteCount <= valueLimits.stringBytes else {
                throw ScriptValueError.stringTooLong(limit: valueLimits.stringBytes)
            }
            withLuaBytes(s) { ptr, len in _ = lua_pushlstring(L, ptr, len) }
        case .list(let items):
            guard items.count <= valueLimits.listElements else {
                throw ScriptValueError.listTooLong(limit: valueLimits.listElements)
            }
            if !items.isEmpty {
                guard depth < valueLimits.depth else { throw ScriptValueError.tooDeep(limit: valueLimits.depth) }
            }
            lua_createtable(L, Int32(items.count), 0)
            let tableIdx = lua_gettop(L)
            for (offset, item) in items.enumerated() {
                try pushScriptValue(item, on: L, depth: depth + 1, nodeCount: &nodeCount)
                lua_rawseti(L, tableIdx, lua_Integer(offset + 1))
            }
        case .map(let dict):
            guard dict.count <= valueLimits.mapKeys else {
                throw ScriptValueError.mapTooLarge(limit: valueLimits.mapKeys)
            }
            if !dict.isEmpty {
                guard depth < valueLimits.depth else { throw ScriptValueError.tooDeep(limit: valueLimits.depth) }
            }
            lua_createtable(L, 0, Int32(dict.count))
            let tableIdx = lua_gettop(L)
            // design.md Decision 10 / spec: maps are pushed in sorted key order.
            for key in dict.keys.sorted() {
                guard key.utf8.count <= valueLimits.stringBytes else {
                    throw ScriptValueError.stringTooLong(limit: valueLimits.stringBytes)
                }
                withLuaBytes(key) { ptr, len in _ = lua_pushlstring(L, ptr, len) }
                try pushScriptValue(dict[key]!, on: L, depth: depth + 1, nodeCount: &nodeCount)
                lua_rawset(L, tableIdx)
            }
        case .ref(let name):
            if let entry = handleResolver[name] {
                withLuaBytes(name) { ptr, len in
                    elysium_make_handle(L, entry.kind.kindId, entry.id, ptr, len, entry.kind.interned ? 1 : 0)
                }
            } else {
                lua_pushnil(L)
            }
        }
    }

    // MARK: - Lua -> Swift (pull)

    /// Pulls the value at `idx` as a `ScriptValue`; functions/threads/non-handle
    /// userdata are marshaling errors here (spec: "functions, threads and non-handle
    /// userdata are errors") — use `pullArgument` at the top level of a host-function
    /// call to receive those explicitly instead.
    func pullScriptValue(at idx: Int32, on L: LuaStatePointer, depth: Int, nodeCount: inout Int) throws -> ScriptValue {
        nodeCount += 1
        guard nodeCount <= valueLimits.nodes else { throw ScriptValueError.tooManyNodes(limit: valueLimits.nodes) }

        switch lua_type(L, idx) {
        case LUA_TNIL:
            return .null
        case LUA_TBOOLEAN:
            return .bool(lua_toboolean(L, idx) != 0)
        case LUA_TNUMBER:
            if lua_isinteger(L, idx) != 0 {
                return .int(Int64(elysium_tointeger(L, idx)))
            }
            let d = Double(elysium_tonumber(L, idx))
            guard d.isFinite else { throw ScriptValueError.notFinite }
            return .number(d == 0 ? 0 : d)
        case LUA_TSTRING:
            var len = 0
            let cstr = lua_tolstring(L, idx, &len)
            guard len <= valueLimits.stringBytes else {
                throw ScriptValueError.stringTooLong(limit: valueLimits.stringBytes)
            }
            return .string(decodeLuaBytes(cstr, len))
        case LUA_TTABLE:
            return try pullTable(at: idx, on: L, depth: depth, nodeCount: &nodeCount)
        case LUA_TUSERDATA:
            if elysium_handle_kind(L, idx) >= 0, let ref = handleRefString(at: idx, on: L) {
                return .ref(ref)
            }
            throw ScriptValueError.unsupportedType("userdata")
        default:
            throw ScriptValueError.unsupportedType(luaTypeName(lua_type(L, idx)))
        }
    }

    /// The Lua->Swift table classifier (spec: a table with exactly integer keys
    /// `1...n` and nothing else is a `list`, string-keyed-only is a `map`, anything
    /// else — mixed key types, non-integer numeric keys, a gap — is an error).
    private func pullTable(at idx: Int32, on L: LuaStatePointer, depth: Int, nodeCount: inout Int) throws -> ScriptValue {
        guard depth < valueLimits.depth else { throw ScriptValueError.tooDeep(limit: valueLimits.depth) }
        let tableIdx = lua_absindex(L, idx)
        // F1 (test.md defect, "make the Lua->Swift marshaler's failure path
        // symmetric"): record the top on entry, exactly like the push-side fix, so
        // a thrown error restores the stack by index rather than by a fixed pop
        // count that a future change to this loop could silently invalidate.
        let savedTop = lua_gettop(L)

        var intEntries: [Int64: ScriptValue] = [:]
        var stringEntries: [String: ScriptValue] = [:]
        var otherKeySeen = false

        lua_pushnil(L)
        while lua_next(L, tableIdx) != 0 {
            // stack: ... key value
            let keyType = lua_type(L, -2)
            let valueIdx = lua_gettop(L)
            do {
                let value = try pullScriptValue(at: valueIdx, on: L, depth: depth + 1, nodeCount: &nodeCount)
                if keyType == LUA_TSTRING {
                    var len = 0
                    let cstr = lua_tolstring(L, -2, &len)
                    guard len <= valueLimits.stringBytes else {
                        throw ScriptValueError.stringTooLong(limit: valueLimits.stringBytes)
                    }
                    stringEntries[decodeLuaBytes(cstr, len)] = value
                } else if keyType == LUA_TNUMBER, lua_isinteger(L, -2) != 0 {
                    intEntries[Int64(elysium_tointeger(L, -2))] = value
                } else {
                    otherKeySeen = true
                }
            } catch {
                elysium_settop(L, savedTop) // keep the caller's stack balanced before rethrow
                throw error
            }
            elysium_pop(L, 1) // pop value, keep key on top for the next lua_next
        }

        if otherKeySeen || (!intEntries.isEmpty && !stringEntries.isEmpty) {
            throw ScriptValueError.sparseOrMixedTable
        }
        if !stringEntries.isEmpty {
            guard stringEntries.count <= valueLimits.mapKeys else {
                throw ScriptValueError.mapTooLarge(limit: valueLimits.mapKeys)
            }
            return .map(stringEntries)
        }
        if intEntries.isEmpty {
            return .list([])
        }
        guard intEntries.count <= valueLimits.listElements else {
            throw ScriptValueError.listTooLong(limit: valueLimits.listElements)
        }
        var list: [ScriptValue] = []
        list.reserveCapacity(intEntries.count)
        for i in 1...Int64(intEntries.count) {
            guard let value = intEntries[i] else { throw ScriptValueError.sparseOrMixedTable }
            list.append(value)
        }
        return .list(list)
    }

    /// Top-level argument extraction for a host-function call: functions become
    /// `.function`, handles become `.handle`, threads/non-handle userdata become
    /// `.unsupported`, everything else marshals as an ordinary `.value(ScriptValue)`
    /// (design.md Decision 10).
    func pullArgument(at idx: Int32, on L: LuaStatePointer, depth: Int, nodeCount: inout Int) throws -> ScriptArgument {
        switch lua_type(L, idx) {
        case LUA_TFUNCTION:
            return .function(makeScriptFunction(fromStackIndex: idx, on: L))
        case LUA_TUSERDATA:
            let kindId = elysium_handle_kind(L, idx)
            if kindId >= 0, let kind = handleKindsById[kindId] {
                let id = elysium_handle_id(L, idx)
                let ref = handleRefString(at: idx, on: L) ?? ""
                return .handle(HandleRef(kind: kind, ref: ref, id: id, stateIdentity: identity))
            }
            return .unsupported("userdata")
        case LUA_TTHREAD:
            return .unsupported("thread")
        default:
            return .value(try pullScriptValue(at: idx, on: L, depth: depth, nodeCount: &nodeCount))
        }
    }

    /// Reads a handle userdata's ref string (user value 2 — design.md Decision 10:
    /// "user values: method cache table, ref string").
    func handleRefString(at idx: Int32, on L: LuaStatePointer) -> String? {
        guard lua_getiuservalue(L, idx, 2) == LUA_TSTRING else {
            elysium_pop(L, 1)
            return nil
        }
        var len = 0
        let cstr = lua_tolstring(L, -1, &len)
        let s = decodeLuaBytes(cstr, len)
        elysium_pop(L, 1)
        return s
    }
}

func luaTypeName(_ t: Int32) -> String {
    switch t {
    case LUA_TNIL: return "nil"
    case LUA_TBOOLEAN: return "boolean"
    case LUA_TNUMBER: return "number"
    case LUA_TSTRING: return "string"
    case LUA_TTABLE: return "table"
    case LUA_TFUNCTION: return "function"
    case LUA_TUSERDATA: return "userdata"
    case LUA_TTHREAD: return "thread"
    default: return "value"
    }
}
