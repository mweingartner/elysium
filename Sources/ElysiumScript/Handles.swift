// Handles.swift — task 3.3. design.md Decision 10 "Handle userdata dispatch to typed
// Swift closures". This file holds the value types plus the `LuaState` extension that
// builds/routes them; it reaches the raw pointer only through the `LuaStatePointer`
// typealias (never `OpaquePointer` itself — design.md Condition 3).

import CLua

/// One registered handle metatable (design.md: "one metatable per kind"). Carries the
/// owning state's identity so a `HandleKind` (and every `HandleRef` built from it)
/// created by one `LuaState` is refused by another (design.md Condition 30).
public struct HandleKind: Equatable, Sendable {
    public let name: String
    let kindId: Int32
    let baseFid: Int32
    let interned: Bool
    let stateIdentity: UInt64

    init(name: String, kindId: Int32, baseFid: Int32, interned: Bool, stateIdentity: UInt64) {
        self.name = name
        self.kindId = kindId
        self.baseFid = baseFid
        self.interned = interned
        self.stateIdentity = stateIdentity
    }

    public static func == (lhs: HandleKind, rhs: HandleKind) -> Bool {
        lhs.kindId == rhs.kindId && lhs.stateIdentity == rhs.stateIdentity
    }
}

/// A handle userdata's identity as the host sees it: the kind it belongs to, the
/// canonical ref string (`tostring(h)`, `HandleDispatch` callbacks' `self`), and the
/// opaque numeric `id` the host supplied at `makeHandle` time (a fast lookup key so a
/// dispatch closure need not parse `ref`).
public struct HandleRef: Equatable, Sendable {
    public let kind: HandleKind
    public let ref: String
    public let id: UInt64
    let stateIdentity: UInt64

    init(kind: HandleKind, ref: String, id: UInt64, stateIdentity: UInt64) {
        self.kind = kind
        self.ref = ref
        self.id = id
        self.stateIdentity = stateIdentity
    }

    public static func == (lhs: HandleRef, rhs: HandleRef) -> Bool {
        lhs.kind == rhs.kind && lhs.ref == rhs.ref && lhs.stateIdentity == rhs.stateIdentity
    }
}

/// The Swift side of one handle kind's behavior (design.md Decision 10; field set is
/// provisional — 1a may add `call`/`pairs` hooks). `__tostring` needs no entry here: it
/// always returns `ref` directly (spec: "`__tostring` SHALL return the ref"), handled
/// generically by `LuaState` for every kind.
public struct HandleDispatch {
    /// Method name -> closure. Resolved by `__index` and cached per-userdata (design.md:
    /// "`__index` with a method name returns a C closure... cached in user value 1");
    /// reachable as both `h:m(...)` (self dropped from `call.arguments`) and `h.m(...)`.
    public var methods: [String: (HandleRef, HostCall) -> HostResult]
    /// Fallback for `__index` when the key is not a recognized method name (e.g. a
    /// property read). `nil` means every non-method key reads as `nil`.
    public var index: ((HandleRef, HostCall, ScriptValue) -> HostResult)?
    /// `__newindex`. `nil` means every write is refused (handles are read-only by
    /// default).
    public var newIndex: ((HandleRef, HostCall, ScriptValue, ScriptValue) -> HostResult)?

    public init(
        methods: [String: (HandleRef, HostCall) -> HostResult] = [:],
        index: ((HandleRef, HostCall, ScriptValue) -> HostResult)? = nil,
        newIndex: ((HandleRef, HostCall, ScriptValue, ScriptValue) -> HostResult)? = nil
    ) {
        self.methods = methods
        self.index = index
        self.newIndex = newIndex
    }
}

// MARK: - LuaState: handle kind registration, creation, invalidation, dispatch routing

extension LuaState {
    /// Registers one handle metatable (design.md Decision 10). Method names are
    /// assigned fids in sorted order so fid allocation — and therefore every golden
    /// that hashes the sandbox/handle surface — is deterministic across processes.
    public func registerHandleKind(name: String, dispatch: HandleDispatch, interned: Bool) -> HandleKind {
        assertOwnerThread()
        precondition(!isClosed, "LuaState is closed")
        guard let pointer else { fatalError("LuaState has no pointer") }

        var baseFid: Int32 = 0
        let kindId: Int32 = withLuaBytes(name) { ptr, len in
            elysium_register_handle_kind(pointer, ptr, len, interned ? 1 : 0, &baseFid)
        }

        let kind = HandleKind(name: name, kindId: kindId, baseFid: baseFid, interned: interned, stateIdentity: identity)
        handleKindsById[kindId] = kind
        handleDispatchByKindId[kindId] = dispatch

        fidTable[baseFid + 0] = .handleIndex(kindId: kindId)
        fidTable[baseFid + 1] = .handleNewIndex(kindId: kindId)
        fidTable[baseFid + 2] = .handleEq(kindId: kindId)
        fidTable[baseFid + 3] = .handleToString(kindId: kindId)

        var methodFids: [String: Int32] = [:]
        for methodName in dispatch.methods.keys.sorted() {
            let fid = nextFid
            nextFid += 1
            methodFids[methodName] = fid
            fidTable[fid] = .handleMethod(kindId: kindId, name: methodName)
        }
        methodFidByKindAndName[kindId] = methodFids

        return kind
    }

    /// Registers `(ref -> kind, id)` with the state's handle resolver (spec: "`.ref`
    /// resolves through the state's handle resolver") and returns the `.ref` value a
    /// host function can hand back through `HostResult.values`. Does not itself touch
    /// the Lua stack — the userdata is only actually created when this `.ref` is
    /// pushed (`ScriptMarshaling.pushScriptValue`).
    public func makeHandle(kind: HandleKind, ref: String, id: UInt64) throws -> ScriptValue {
        assertOwnerThread()
        guard kind.stateIdentity == identity else { throw LuaRuntimeError.stateMismatch }
        // N3 (test.md note): the resolver used to be keyed by ref alone, so a later
        // makeHandle for the same ref under a *different* kind silently rebound it —
        // every earlier `.ref` push for that name would then resolve through the new
        // kind instead. Re-registering the same ref under its *own* kind (e.g. to
        // update `id`) is still allowed; only a cross-kind rebind is refused.
        if let existing = handleResolver[ref], existing.kind.kindId != kind.kindId {
            throw LuaRuntimeError.handleRefConflict
        }
        handleResolver[ref] = (kind: kind, id: id)
        return .ref(ref)
    }

    /// Forgets `ref` (design.md Decision 10: interned kinds create a fresh, unequal
    /// userdata for the same ref afterward); safe to call for a ref that was never a
    /// handle or already invalidated.
    public func invalidateHandle(ref: String) {
        assertOwnerThread()
        guard let entry = handleResolver.removeValue(forKey: ref) else { return }
        guard !isClosed, let pointer else { return }
        withLuaBytes(ref) { ptr, len in elysium_invalidate_handle(pointer, entry.kind.kindId, ptr, len) }
    }

    // MARK: Dispatch routing (called from `dispatch(fid:on:)`)

    private func readAnyHandleRef(at idx: Int32, on L: LuaStatePointer) -> HandleRef? {
        let kindId = elysium_handle_kind(L, idx)
        guard kindId >= 0, let kind = handleKindsById[kindId] else { return nil }
        let id = elysium_handle_id(L, idx)
        guard let ref = handleRefString(at: idx, on: L) else { return nil }
        return HandleRef(kind: kind, ref: ref, id: id, stateIdentity: identity)
    }

    private func readLuaString(at idx: Int32, on L: LuaStatePointer) -> String? {
        var len = 0
        guard let cstr = lua_tolstring(L, idx, &len) else { return nil }
        return decodeLuaBytes(cstr, len)
    }

    func dispatchHandleIndex(kindId: Int32, on L: LuaStatePointer) -> Int32 {
        guard let handleRef = readAnyHandleRef(at: 1, on: L), handleRef.kind.kindId == kindId else {
            return pushInternalError("not a valid handle", on: L)
        }
        if lua_type(L, 2) == LUA_TSTRING,
            let methodName = readLuaString(at: 2, on: L),
            let methodFid = methodFidByKindAndName[kindId]?[methodName] {
            return dispatchBoundMethodLookup(methodFid: methodFid, methodName: methodName, on: L)
        }

        guard let indexFn = handleDispatchByKindId[kindId]?.index else {
            lua_pushnil(L)
            return 1
        }
        var nodeCount = 0
        let key: ScriptValue
        do {
            key = try pullScriptValue(at: 2, on: L, depth: 0, nodeCount: &nodeCount)
        } catch let error as ScriptValueError {
            return pushInternalError(error.message, on: L)
        } catch {
            return pushInternalError("key marshaling failed", on: L)
        }
        let call = HostCall(arguments: [], environment: nil, state: self)
        return pushHostResult(indexFn(handleRef, call, key), on: L)
    }

    /// `__index` resolving a recognized method name: cache the bound closure (upvalues
    /// `fid, handle`) in the userdata's user value 1, per design.md Decision 10.
    private func dispatchBoundMethodLookup(methodFid: Int32, methodName: String, on L: LuaStatePointer) -> Int32 {
        guard lua_getiuservalue(L, 1, 1) == LUA_TTABLE else {
            elysium_pop(L, 1)
            return pushInternalError("handle is missing its method cache", on: L)
        }
        let cacheIdx = lua_gettop(L)

        withLuaBytes(methodName) { ptr, len in _ = lua_pushlstring(L, ptr, len) }
        lua_rawget(L, cacheIdx)
        if lua_type(L, -1) == LUA_TFUNCTION {
            elysium_replace(L, cacheIdx)
            return 1
        }
        elysium_pop(L, 1)

        lua_pushinteger(L, lua_Integer(methodFid))
        lua_pushvalue(L, 1)
        lua_pushcclosure(L, elysium_tramp, 2)

        withLuaBytes(methodName) { ptr, len in _ = lua_pushlstring(L, ptr, len) }
        lua_pushvalue(L, -2)
        lua_rawset(L, cacheIdx)

        elysium_replace(L, cacheIdx)
        return 1
    }

    func dispatchHandleNewIndex(kindId: Int32, on L: LuaStatePointer) -> Int32 {
        guard let handleRef = readAnyHandleRef(at: 1, on: L), handleRef.kind.kindId == kindId else {
            return pushInternalError("not a valid handle", on: L)
        }
        guard let newIndexFn = handleDispatchByKindId[kindId]?.newIndex else {
            return pushInternalError("attempt to modify a handle of kind '\(handleRef.kind.name)'", on: L)
        }
        let key: ScriptValue
        let value: ScriptValue
        do {
            var keyNodeCount = 0
            key = try pullScriptValue(at: 2, on: L, depth: 0, nodeCount: &keyNodeCount)
            var valueNodeCount = 0
            value = try pullScriptValue(at: 3, on: L, depth: 0, nodeCount: &valueNodeCount)
        } catch let error as ScriptValueError {
            return pushInternalError(error.message, on: L)
        } catch {
            return pushInternalError("value marshaling failed", on: L)
        }
        let call = HostCall(arguments: [], environment: nil, state: self)
        return pushHostResult(newIndexFn(handleRef, call, key, value), on: L)
    }

    func dispatchHandleEq(kindId: Int32, on L: LuaStatePointer) -> Int32 {
        guard let a = readAnyHandleRef(at: 1, on: L), let b = readAnyHandleRef(at: 2, on: L) else {
            lua_pushboolean(L, 0)
            return 1
        }
        lua_pushboolean(L, (a.kind.kindId == b.kind.kindId && a.ref == b.ref) ? 1 : 0)
        return 1
    }

    func dispatchHandleToString(kindId: Int32, on L: LuaStatePointer) -> Int32 {
        guard let ref = handleRefString(at: 1, on: L) else {
            return pushInternalError("not a valid handle", on: L)
        }
        withLuaBytes(ref) { ptr, len in _ = lua_pushlstring(L, ptr, len) }
        return 1
    }

    func dispatchHandleMethod(kindId: Int32, name: String, on L: LuaStatePointer) -> Int32 {
        // design.md Decision 10: "handle method closures add upvalue 2 = the bound
        // handle" — this closure's own upvalue 2, not argument 1, is the source of
        // truth for `self`.
        guard let handleRef = readAnyHandleRef(at: elysium_upvalueindex(2), on: L), handleRef.kind.kindId == kindId else {
            return pushInternalError("not a valid handle", on: L)
        }
        guard let method = handleDispatchByKindId[kindId]?.methods[name] else {
            return pushInternalError("unknown method '\(name)'", on: L)
        }
        let nargs = lua_gettop(L)
        var startIdx: Int32 = 1
        // `h:m(...)` passes self as argument 1 (rawequal to the bound handle); drop it
        // so `h.m(...)` and `h:m(...)` reach the closure with identical arguments
        // (design.md: "a leading argument identical to the bound handle is dropped").
        if nargs >= 1, lua_rawequal(L, 1, elysium_upvalueindex(2)) != 0 {
            startIdx = 2
        }
        var arguments: [ScriptArgument] = []
        if startIdx <= nargs {
            var index = startIdx
            while index <= nargs {
                var nodeCount = 0
                do {
                    arguments.append(try pullArgument(at: index, on: L, depth: 0, nodeCount: &nodeCount))
                } catch let error as ScriptValueError {
                    return pushInternalError(error.message, on: L)
                } catch {
                    return pushInternalError("argument marshaling failed", on: L)
                }
                index += 1
            }
        }
        let call = HostCall(arguments: arguments, environment: nil, state: self)
        return pushHostResult(method(handleRef, call), on: L)
    }
}
