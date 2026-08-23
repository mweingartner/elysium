// Environment.swift — task 3.3. design.md Decision 8 (per-environment sandbox
// construction) and Decision 17 (`ScriptEnvironment`: `compile`, `destroy`, `name`).
// The actual table-building happens in `elysium_make_environment`
// (elysium_sandbox.c); this file wires that into `LuaState.makeEnvironment` and adds
// the host-binding tree (design.md Decision 17's `hostBindings` parameter — empty in
// every caller until 1a registers real host API tables).

import CLua

/// A private, sandboxed global scope (design.md Decision 8): its own `_ENV`, its own
/// copies of the library tables, its own `print`/`math.random` stream. Carries the
/// owning state's identity and its own `envId` so a function/coroutine compiled here
/// is refused by another `LuaState` (design.md Condition 30).
public final class ScriptEnvironment {
    public let name: String
    let stateIdentity: UInt64
    let envId: UInt64
    var envRef: Int32
    weak var state: LuaState?
    private(set) var destroyed = false

    init(name: String, stateIdentity: UInt64, envId: UInt64, envRef: Int32, state: LuaState) {
        self.name = name
        self.stateIdentity = stateIdentity
        self.envId = envId
        self.envRef = envRef
        self.state = state
    }

    /// Compiles `source` against this environment's private `_ENV` (design.md
    /// Decision 4: `elysium_loadtext`, text mode only). `.failure` carries a
    /// `ScriptFault(kind: .compile, ...)`.
    public func compile(source: String, chunkName: String) -> Result<ScriptFunction, ScriptFault> {
        guard let state, !destroyed else {
            return .failure(ScriptFault(kind: .compile, message: "environment is destroyed", traceback: ""))
        }
        return state.compile(in: self, source: source, chunkName: chunkName)
    }

    /// Invalidates every `ScriptFunction`/`ScriptCoroutine` this environment produced
    /// and makes its reserved-fid dispatch (`print`, `random`, `randomseed`) fail
    /// deterministically from then on (design.md Condition 30). Idempotent.
    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        state?.destroyEnvironment(self)
    }
}

extension LuaState {
    /// Builds a fresh sandboxed environment (design.md Decision 8). `hostBindings`
    /// nodes are installed into `_ENV` directly (functions) or as a frozen proxy
    /// table (nested tables — sandboxed exactly like every library table, Condition
    /// 7); an empty array (every call in this change) leaves `_ENV` exactly as
    /// `elysium_make_environment` builds it.
    public func makeEnvironment(
        name: String, hostBindings: [HostBinding] = [], random: any ScriptRandomStream
    ) -> ScriptEnvironment {
        assertOwnerThread()
        precondition(!isClosed, "LuaState is closed")
        guard let pointer else { fatalError("LuaState has no pointer") }

        let envId = nextEnvId
        nextEnvId += 1
        let envRef = elysium_make_environment(pointer, envId)
        let envTableIdx = lua_gettop(pointer) // elysium_make_environment left _ENV on top

        environments[envId] = EnvironmentRecord(envId: envId, envRef: envRef, randomBox: RandomStreamBox(random))
        let environment = ScriptEnvironment(name: name, stateIdentity: identity, envId: envId, envRef: envRef, state: self)

        installHostBindings(hostBindings, into: envTableIdx, environment: environment, on: pointer)
        elysium_pop(pointer, 1) // drop the stack copy; envRef keeps _ENV alive in the registry

        return environment
    }

    private func installHostBindings(
        _ bindings: [HostBinding], into tableIdx: Int32, environment: ScriptEnvironment, on L: LuaStatePointer
    ) {
        guard !bindings.isEmpty else { return }
        // F1 (test.md defect, "host-binding installation"): design.md Condition 3 —
        // check the stack before this level's pushes. Every call in this change
        // passes an empty `hostBindings` (1a is the first caller with a non-empty
        // tree), so this is unexercised today; skipping the whole level on a
        // (currently unreachable) failure is safer than pushing past LUA_MINSTACK
        // with no growth guarantee at this call depth.
        guard lua_checkstack(L, Int32(bindings.count) * 4 + 16) != 0 else { return }
        for binding in bindings {
            switch binding {
            case .function(let name, let function):
                let fid = nextFid
                nextFid += 1
                fidTable[fid] = .host(function, environment)
                environments[environment.envId]?.hostBindingFids.append(fid)
                elysium_push_host_function(L, fid)
                withLuaBytes(name) { ptr, len in _ = lua_pushlstring(L, ptr, len) }
                elysium_insert(L, -2) // stack: ..., name, closure (key, value order for rawset)
                lua_rawset(L, tableIdx)
            case .table(let name, let children):
                lua_createtable(L, 0, Int32(children.count))
                let childIdx = lua_gettop(L)
                installHostBindings(children, into: childIdx, environment: environment, on: L)
                elysium_freeze_table(L, childIdx, environment.envId)
                withLuaBytes(name) { ptr, len in _ = lua_pushlstring(L, ptr, len) }
                elysium_insert(L, -2)
                lua_rawset(L, tableIdx)
            }
        }
    }

    /// design.md Condition 30: invalidates every function/coroutine this environment
    /// produced and makes its reserved-fid dispatch fail from then on. Removing the
    /// record from `environments` is what actually does the invalidating — `call`,
    /// `makeCoroutine` and `resume` all check `isEnvironmentAlive(_:)` against this
    /// same dictionary before running anything tied to an environment id, and
    /// `dispatchRandom`/`dispatchRandomSeed` (LuaState.swift) already look the envId up
    /// here on every call — so there is no separate list of functions/coroutines to
    /// walk and mark individually.
    func destroyEnvironment(_ environment: ScriptEnvironment) {
        assertOwnerThread()
        guard let record = environments[environment.envId] else { return }
        record.destroyed = true
        environments.removeValue(forKey: environment.envId)
        guard !isClosed, let pointer else { return }
        // F3 (test.md defect): release every registry ref this environment anchored
        // on the Swift side (compiled chunks — each keeps _ENV reachable through its
        // own upvalue, independent of envRef) before dropping the environment's own
        // ref, and drop the fidTable entries for its host-binding closures (note N4)
        // so the `HostFunction`/`ScriptEnvironment` they retain are not kept alive
        // forever. elysium_destroy_environment (C) then reclaims the rest of the
        // per-environment object graph (hidden tables, proxies, _ENV's metatable) by
        // un-marking it from the host-owned set before unref'ing envRef itself.
        for ref in record.compiledRefs {
            luaL_unref(pointer, elysium_registryindex(), ref)
        }
        record.compiledRefs.removeAll()
        for fid in record.hostBindingFids {
            fidTable.removeValue(forKey: fid)
        }
        record.hostBindingFids.removeAll()
        elysium_destroy_environment(pointer, record.envRef, environment.envId)
    }

    /// `true` for a function/coroutine not tied to any one environment (an arbitrary
    /// `ScriptArgument.function` extracted from a script call, `envId == nil`); `false`
    /// once the owning environment has been destroyed (design.md Condition 30).
    func isEnvironmentAlive(_ envId: UInt64?) -> Bool {
        guard let envId else { return true }
        return environments[envId] != nil
    }

    // MARK: - Compilation

    func compile(in environment: ScriptEnvironment, source: String, chunkName: String) -> Result<ScriptFunction, ScriptFault> {
        assertOwnerThread()
        guard environment.stateIdentity == identity else {
            return .failure(ScriptFault(kind: .compile, message: "environment belongs to a different LuaState", traceback: ""))
        }
        guard !isClosed, let pointer else {
            return .failure(ScriptFault(kind: .compile, message: "state is closed", traceback: ""))
        }
        guard let record = environments[environment.envId], !record.destroyed else {
            return .failure(ScriptFault(kind: .compile, message: "environment is destroyed", traceback: ""))
        }
        if let capFault = validateSourceAndChunkName(source: source, chunkName: chunkName) {
            return .failure(capFault)
        }

        let rc: Int32 = withLuaBytes(source) { sPtr, sLen in
            chunkName.withCString { cName in
                elysium_loadtext(pointer, sPtr, sLen, cName)
            }
        }
        guard rc == LUA_OK else {
            let message = readTopString(cap: budgets.faultMessageBytes)
            elysium_pop(pointer, 1)
            return .failure(ScriptFault(kind: .compile, message: ScriptTextHygiene.sanitize(message), traceback: ""))
        }

        // Bind the chunk's first upvalue (_ENV) to this environment's private table
        // (design.md: "ScriptEnvironment.compile(source:chunkName:) SHALL bind the
        // chunk's first upvalue _ENV to the environment's private writable table").
        let fnIdx = lua_gettop(pointer)
        lua_rawgeti(pointer, elysium_registryindex(), lua_Integer(environment.envRef))
        // lua_setupvalue assigns the value on top of the stack to the chunk's Nth
        // upvalue and pops it, regardless of success; a chunk with no upvalues at all
        // (an empty/constant-only chunk) returns NULL here, which is not an error.
        _ = lua_setupvalue(pointer, fnIdx, 1)

        let ref = luaL_ref(pointer, elysium_registryindex())
        // F3 (test.md defect): track this ref so destroyEnvironment can release it.
        // A compiled chunk's upvalue 1 is this environment's _ENV table (bound just
        // above), so as long as this ref survives, _ENV stays reachable through it
        // regardless of the environment's own envRef being unref'd on destroy.
        environments[environment.envId]?.compiledRefs.append(ref)
        return .success(ScriptFunction(stateIdentity: identity, envId: environment.envId, ref: ref))
    }
}
