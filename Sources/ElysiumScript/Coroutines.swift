// Coroutines.swift — task 3.3. design.md Decision 7 ("Coroutine resume contract and
// thread pool") and Decision 6/17 (`ScriptFunction`, `ScriptCoroutine`, `call`,
// `resume`, `close(coroutine:)`). Every entry point here goes through
// `elysium_pcall`/`elysium_resume` — the two protected entries C provides — never a
// raw `lua_pcall`/`lua_resume` (design.md Condition 3).

import CLua

/// An anchored, callable Lua function value (design.md Decision 17): either a chunk
/// `ScriptEnvironment.compile` produced, or a Lua function a script passed as an
/// argument (`ScriptArgument.function`).
public final class ScriptFunction {
    let stateIdentity: UInt64
    /// The environment that compiled this chunk, or `nil` for a function extracted
    /// from a script argument (not tied to any one environment's lifetime).
    let envId: UInt64?
    let ref: Int32
    fileprivate(set) var invalidated = false

    init(stateIdentity: UInt64, envId: UInt64?, ref: Int32) {
        self.stateIdentity = stateIdentity
        self.envId = envId
        self.ref = ref
    }
}

/// A pooled coroutine thread (design.md Decision 7). Counters are informational —
/// scheduled/enforced by a later change's tick loop, not this one (design.md Decision 6).
public final class ScriptCoroutine {
    let stateIdentity: UInt64
    let envId: UInt64?
    var pointer: LuaStatePointer?
    public internal(set) var instructionsUsed: UInt64 = 0
    public internal(set) var consecutivePreemptions: Int = 0
    public internal(set) var suspendedSinceResume: Bool = false
    fileprivate(set) var invalidated = false
    /// The reason the *previous* `resume` returned `.yielded`, if any — how the next
    /// `resume`'s `args` are validated (design.md Decision 7's resume-argument
    /// contract). `nil` before the first resume and after `.completed`.
    var lastYieldReason: ScriptYieldReason?

    init(stateIdentity: UInt64, envId: UInt64?, pointer: LuaStatePointer) {
        self.stateIdentity = stateIdentity
        self.envId = envId
        self.pointer = pointer
    }
}

/// `LuaState.resume`'s result (design.md Decision 7).
public enum ScriptResumeOutcome {
    case completed([ScriptValue])
    case yielded(ScriptYieldReason)
    case faulted(ScriptFault)
}

/// `LuaState.call`'s result (design.md Decision 6/17: the synchronous, non-yieldable
/// form).
public enum ScriptCallOutcome {
    case success([ScriptValue])
    case failure(ScriptFault)
}

extension LuaState {
    // MARK: - ScriptFunction extraction (used by ScriptMarshaling.pullArgument)

    /// Anchors the function value at `idx` in the registry (design.md: any Lua
    /// function value a script passes as an argument becomes a usable
    /// `ScriptFunction`, not just chunks `ScriptEnvironment.compile` produces).
    func makeScriptFunction(fromStackIndex idx: Int32, on L: LuaStatePointer) -> ScriptFunction {
        lua_pushvalue(L, idx)
        let ref = luaL_ref(L, elysium_registryindex())
        return ScriptFunction(stateIdentity: identity, envId: nil, ref: ref)
    }

    // MARK: - Coroutines

    /// Takes a pooled (or fresh) thread and pushes `function` onto it, ready to run
    /// (design.md Decision 7). Throws `.stateMismatch` for a function from a different
    /// `LuaState` (design.md Condition 30); `nil` for any other reason it cannot be
    /// created (the function's environment was destroyed, or the state has no room for
    /// another entry).
    public func makeCoroutine(function: ScriptFunction) throws -> ScriptCoroutine? {
        assertOwnerThread()
        guard function.stateIdentity == identity else { throw LuaRuntimeError.stateMismatch }
        guard !isClosed, let pointer, !function.invalidated, isEnvironmentAlive(function.envId) else { return nil }
        guard let co = elysium_newthread_with_function(pointer, function.ref) else { return nil }
        return ScriptCoroutine(stateIdentity: identity, envId: function.envId, pointer: co)
    }

    /// Resumes `coroutine` with `args` (design.md Decision 7's resume-argument
    /// contract: zero values after `.preempted`/`.wait`, the host-supplied values
    /// become an `.await` host call's results — enforced by the caller, not checked
    /// here, since a wrong-shaped resume is a programmer error the spec treats as
    /// such rather than a recoverable one). Throws `.stateMismatch` for a coroutine
    /// from a different `LuaState` (design.md Condition 30).
    public func resume(_ coroutine: ScriptCoroutine, args: [ScriptValue], slice: Int) throws -> ScriptResumeOutcome {
        assertOwnerThread()
        guard coroutine.stateIdentity == identity else { throw LuaRuntimeError.stateMismatch }
        guard !isClosed, let pointer else {
            return .faulted(ScriptFault(kind: .hostAbort, message: "state is closed", traceback: ""))
        }
        guard !coroutine.invalidated, let co = coroutine.pointer else {
            return .faulted(ScriptFault(kind: .hostAbort, message: "coroutine is already closed", traceback: ""))
        }
        guard isEnvironmentAlive(coroutine.envId) else {
            return .faulted(ScriptFault(kind: .hostAbort, message: "coroutine's environment was destroyed", traceback: ""))
        }
        // design.md Decision 7's resume-argument contract: resuming a `.preempted` or
        // `.wait` yield with a non-empty `args` is a caller-contract violation, not a
        // recoverable script-level condition (nothing about the *script* is wrong —
        // the VM will simply re-execute the interrupted instruction either way; only
        // the values the caller thought it was supplying would be silently discarded).
        switch coroutine.lastYieldReason {
        case .preempted, .wait:
            precondition(args.isEmpty, "resume after .preempted/.wait must pass zero arguments")
        case .await, nil:
            break
        }

        // design.md Condition 3: check the stack before a multi-value push — this
        // entry point is driven by the host, not called by Lua, so there is no
        // LUA_MINSTACK guarantee to rely on the way a C function callee gets one.
        //
        // F1 (test.md defect): record the top *before* any push, and on a failed
        // push restore it with elysium_settop (a non-raising API) rather than
        // popping a fixed `pushedCount`. `pushScriptValue` has no local
        // catch/cleanup of its own for a `.list`/`.map` value that throws partway
        // through (it creates the outer table with `lua_createtable` before an
        // inner element's cap check can throw) — popping only the *completed*
        // top-level arguments left that partially built table (and everything
        // pushScriptValue had put on top of it) leaked on the MAIN thread's own
        // stack (arguments are pushed onto `pointer`, the calling thread —
        // elysium_resume's own lua_xmove is what moves them onto `co`). This
        // entry point runs unprotected (before elysium_resume, which is the only
        // thing that opens a protected frame here), so nothing else would have
        // cleaned it up; repeated failures walked the stack straight into a
        // debug-build assertion abort / release-build overrun
        // (testZZReproFailedResumeArgPushLeaksMainStack).
        let savedTop = lua_gettop(pointer)
        // LOW note (Security (code) attempt 3, F1 checkstack amounts): sizing by
        // args.count alone only covers the top-level slots. pushScriptValue's
        // .list/.map cases push tables, keys and leaves as they recurse, so a
        // call with many arguments whose *last* one is nested to valueLimits.depth
        // needs up to ~2 slots per level of transient headroom beyond the
        // top-level count (2 * valueLimits.depth), plus a small constant for the
        // container itself and the leaf value. Not script-reachable in phase 0
        // (no host binding exists to call through), but sized correctly here
        // rather than relying on that.
        if !args.isEmpty, lua_checkstack(pointer, Int32(args.count) + checkstackSlack(for: valueLimits.depth)) == 0 {
            return .faulted(ScriptFault(kind: .hostAbort, message: "stack overflow: cannot push \(args.count) arguments", traceback: ""))
        }
        for arg in args {
            var nodeCount = 0
            do {
                try pushScriptValue(arg, on: pointer, depth: 0, nodeCount: &nodeCount)
            } catch {
                elysium_settop(pointer, savedTop)
                let message = (error as? ScriptValueError)?.message ?? "argument marshaling failed"
                return .faulted(ScriptFault(kind: .hostAbort, message: message, traceback: ""))
            }
        }

        var result = elysium_resume_result()
        let rc = elysium_resume(pointer, co, Int32(args.count), Int64(slice), &result)
        // Read before a fault path might close+pool the thread underneath us.
        coroutine.instructionsUsed = elysium_thread_instructions_used(co)

        switch rc {
        case ELYSIUM_OK:
            coroutine.suspendedSinceResume = false
            coroutine.consecutivePreemptions = 0
            coroutine.lastYieldReason = nil
            let values = readResultValues(count: result.nres, on: co)
            elysium_pop(co, result.nres)
            // design.md Decision 7: "Closed or completed threads go back to the pool
            // ... ScriptCoroutine becomes invalid" — a completed thread must be
            // pooled and invalidated exactly like a faulted one, not left resumable.
            // Builder fix (found by testResumeDeadCoroutineIsError): the C-side dead
            // check in elysium_resume is `lua_status(co) != LUA_OK && != LUA_YIELD`,
            // which does not distinguish "never started" from "already completed"
            // (both leave status == LUA_OK; stock Lua's own coroutine.resume draws
            // that distinction with an additional `lua_gettop(co) == 0` check —
            // lcorolib.c auxresume). Without invalidating here, a second `resume` on
            // an already-completed coroutine would reach `lua_resume` with an empty
            // stack instead of being refused, which is undefined behaviour. Closing
            // and invalidating on the Swift side closes that gap without touching
            // the C dead-check at all.
            elysium_closethread(pointer, co)
            invalidateCoroutine(coroutine)
            return .completed(values)
        case ELYSIUM_YIELD:
            coroutine.suspendedSinceResume = true
            let reason: ScriptYieldReason
            switch result.yieldReason {
            case ELYSIUM_YIELD_WAIT:
                reason = .wait(Int(result.yieldPayloadInt))
                coroutine.consecutivePreemptions = 0
            case ELYSIUM_YIELD_AWAIT:
                reason = .await(result.yieldPayloadToken)
                coroutine.consecutivePreemptions = 0
            default:
                reason = .preempted
                coroutine.consecutivePreemptions += 1
            }
            coroutine.lastYieldReason = reason
            elysium_pop(co, result.nres)
            // C20 outcome rule: the resume reports its natural (.yielded) outcome
            // first; only once that is fully read do we run a close that was
            // requested from inside this coroutine's own host function while it was
            // running — "a .yielded coroutine is therefore closed in its suspended
            // state and becomes invalid" (design.md Post-Security(plan) amendments).
            if result.closeDeferred != 0 {
                elysium_closethread(pointer, co)
                invalidateCoroutine(coroutine)
            }
            return .yielded(reason)
        case ELYSIUM_FAULT, ELYSIUM_ERRRUN:
            // Read the fault/traceback text off 'co's own stack before closing it —
            // elysium_resume no longer resets 'co' internally on our behalf (see the
            // elysium_shim.c comment on 'closeDeferred'); design.md Decision 7:
            // "error status or any trip flag -> .faulted(fault) with
            // elysium_traceback... taken before lua_closethread", and "closes+pools
            // the thread regardless of the underlying Lua status" — done here on the
            // Swift side for every fault, not only a deferred-close one, so a
            // naturally faulted coroutine's thread actually returns to the pool
            // instead of leaking (Builder fix, found while writing FaultTests).
            // N4-1/C28: a refused resume whose target thread had no room even
            // for a one-slot error message (checkstack(co, nargs) *and*
            // checkstack(co, 1) both failed) leaves 'co' completely untouched
            // rather than risk a push past elysium_resume's unprotected
            // frame — recognizable as faultKind == HOST_ABORT with nres == 0
            // (every other FAULT/ERRRUN path leaves a real message on 'co').
            let fault: ScriptFault
            if result.faultKind == ELYSIUM_FAULT_HOST_ABORT, result.nres == 0 {
                fault = ScriptFault(kind: .hostAbort, message: "stack overflow", traceback: "")
            } else {
                fault = faultFromTopOfStack(on: co, faultKindCode: result.faultKind, defaultingTo: .runtime)
            }
            elysium_closethread(pointer, co)
            invalidateCoroutine(coroutine)
            return .faulted(fault)
        case ELYSIUM_ERR_REENTRANT:
            return .faulted(ScriptFault(kind: .hostAbort, message: "coroutine is already running", traceback: ""))
        case ELYSIUM_ERR_DEAD:
            return .faulted(ScriptFault(kind: .hostAbort, message: "coroutine is already dead", traceback: ""))
        case ELYSIUM_ERR_NESTING:
            return .faulted(ScriptFault(kind: .hostAbort, message: "resume nesting too deep", traceback: ""))
        default:
            return .faulted(ScriptFault(kind: .hostAbort, message: "resume failed", traceback: ""))
        }
    }

    /// Closes and pools `coroutine` (design.md Decision 7/Condition 20: if it is
    /// currently running — e.g. this is called from inside one of its own host
    /// functions — the close is deferred to its outermost `resume`, and this call
    /// returns immediately either way). Throws `.stateMismatch` for a coroutine from a
    /// different `LuaState` (design.md Condition 30).
    public func close(_ coroutine: ScriptCoroutine) throws {
        assertOwnerThread()
        guard coroutine.stateIdentity == identity else { throw LuaRuntimeError.stateMismatch }
        guard !isClosed, let pointer, let co = coroutine.pointer, !coroutine.invalidated else { return }
        elysium_closethread(pointer, co)
        invalidateCoroutine(coroutine)
    }

    func invalidateCoroutine(_ coroutine: ScriptCoroutine) {
        coroutine.invalidated = true
        coroutine.pointer = nil
    }

    /// F2 (test.md defect, thread pool): the state's current idle pooled-thread
    /// count (design.md Decision 7) — never exceeds `budgets.threadPoolMax`.
    /// Internal, not part of the public API (Decision 17); the test target reaches
    /// it through Swift's usual internal-visibility import annotation for testing
    /// (no `_test` substring in this identifier, per Condition 13's release-
    /// surface denylist).
    var pooledThreadCount: Int {
        assertOwnerThread()
        guard let pointer else { return 0 }
        return Int(elysium_pool_count(pointer))
    }

    // MARK: - Synchronous call

    /// The synchronous host->Lua call form (design.md Decision 4: "the only
    /// synchronous host->Lua call form" — never yieldable; an attempted yield inside
    /// becomes `.invalidYield`). A top-level call (no enclosing coroutine) has a
    /// *hard* slice (design.md Condition 35). Throws `.stateMismatch` for a function
    /// from a different `LuaState` (design.md Condition 30).
    public func call(_ function: ScriptFunction, args: [ScriptValue], slice: Int) throws -> ScriptCallOutcome {
        assertOwnerThread()
        guard function.stateIdentity == identity else { throw LuaRuntimeError.stateMismatch }
        guard !isClosed, let pointer else {
            return .failure(ScriptFault(kind: .hostAbort, message: "state is closed", traceback: ""))
        }
        guard !function.invalidated, isEnvironmentAlive(function.envId) else {
            return .failure(ScriptFault(kind: .hostAbort, message: "function's environment was destroyed", traceback: ""))
        }

        // F1 (test.md defect): record the top *before* pushing the function itself
        // so a failed argument push — including any partially built nested table
        // a `.list`/`.map` value left behind, which `pushScriptValue` never cleans
        // up itself — can be discarded in one elysium_settop covering the function
        // and every argument, instead of a fixed pop count that only accounted for
        // *completed* top-level arguments (see resume(_:args:slice:)'s matching
        // fix and testZZReproFailedCallArgPushLeaksMainStack).
        let savedTop = lua_gettop(pointer)
        lua_rawgeti(pointer, elysium_registryindex(), lua_Integer(function.ref))
        // design.md Condition 3: same stack-growth discipline as resume(_:args:slice:).
        // LOW note (Security (code) attempt 3): sized by the marshaler's transient
        // depth, not just args.count — see the matching comment in resume(_:args:slice:).
        if !args.isEmpty, lua_checkstack(pointer, Int32(args.count) + checkstackSlack(for: valueLimits.depth)) == 0 {
            elysium_settop(pointer, savedTop) // drop the function pushed above
            return .failure(ScriptFault(kind: .hostAbort, message: "stack overflow: cannot push \(args.count) arguments", traceback: ""))
        }
        for arg in args {
            var nodeCount = 0
            do {
                try pushScriptValue(arg, on: pointer, depth: 0, nodeCount: &nodeCount)
            } catch {
                elysium_settop(pointer, savedTop) // drops the function itself too
                let message = (error as? ScriptValueError)?.message ?? "argument marshaling failed"
                return .failure(ScriptFault(kind: .hostAbort, message: message, traceback: ""))
            }
        }

        var result = elysium_resume_result()
        let rc = elysium_pcall(pointer, Int32(args.count), -1, Int64(slice), &result)

        switch rc {
        case ELYSIUM_OK:
            let values = readResultValues(count: result.nres, on: pointer)
            elysium_pop(pointer, result.nres)
            return .success(values)
        case ELYSIUM_ERRRUN, ELYSIUM_FAULT:
            let fault = faultFromTopOfStack(on: pointer, faultKindCode: result.faultKind, defaultingTo: .runtime)
            return .failure(fault)
        case ELYSIUM_ERR_NESTING:
            return .failure(ScriptFault(kind: .hostAbort, message: "call nesting too deep", traceback: ""))
        default:
            return .failure(ScriptFault(kind: .hostAbort, message: "call failed", traceback: ""))
        }
    }

    // MARK: - Shared result/fault helpers

    /// Reads the top `count` values off `L`'s stack as `ScriptValue`s. A result a
    /// script returned that `ScriptValue` cannot represent (a bare function, thread,
    /// or non-handle userdata — design.md Decision 10 lists these as marshaling
    /// errors, not part of `ScriptValue`'s shape) becomes `.null` rather than failing
    /// the whole call; nothing in this change's own corpus returns one.
    func readResultValues(count: Int32, on L: LuaStatePointer) -> [ScriptValue] {
        guard count > 0 else { return [] }
        let top = lua_gettop(L)
        let start = top - count + 1
        var values: [ScriptValue] = []
        values.reserveCapacity(Int(count))
        var idx = start
        while idx <= top {
            var nodeCount = 0
            if let value = try? pullScriptValue(at: idx, on: L, depth: 0, nodeCount: &nodeCount) {
                values.append(value)
            } else {
                values.append(.null)
            }
            idx += 1
        }
        return values
    }

    /// Builds a `ScriptFault` from the combined `message\nstack traceback:\n...`
    /// string `elysium_msgh` leaves on top of `L` (`lauxlib.c luaL_traceback`'s fixed
    /// format — see design.md Condition 29: address-free by construction, this only
    /// splits the shim's own well-formed output, never scrubs script text) and pops it.
    func faultFromTopOfStack(on L: LuaStatePointer, faultKindCode: Int32, defaultingTo fallback: ScriptFaultKind) -> ScriptFault {
        let combined = readTopString(on: L, cap: budgets.faultMessageBytes + budgets.tracebackBytes)
        elysium_pop(L, 1)
        let (message, traceback) = splitMessageAndTraceback(combined)
        let kind = faultKind(fromShimCode: faultKindCode, defaultingTo: fallback)
        return ScriptFault(
            kind: kind,
            message: ScriptTextHygiene.sanitize(truncateUTF8(message, toByteCount: budgets.faultMessageBytes)),
            traceback: ScriptTextHygiene.sanitize(truncateUTF8(traceback, toByteCount: budgets.tracebackBytes))
        )
    }

    private func readTopString(on L: LuaStatePointer, cap: Int) -> String {
        var len = 0
        guard let cstr = lua_tolstring(L, -1, &len) else { return "" }
        return decodeAndCap(cstr, len, cap: cap)
    }
}

/// `elysium_msgh` (elysium_shim.c) always emits `message` then, if a traceback was
/// appended, the literal marker `"\nstack traceback:"` (`lauxlib.c luaL_traceback`'s
/// fixed format) before the frame list.
func splitMessageAndTraceback(_ combined: String) -> (message: String, traceback: String) {
    let marker = "\nstack traceback:"
    guard let range = combined.range(of: marker) else { return (combined, "") }
    let message = String(combined[combined.startIndex..<range.lowerBound])
    let traceback = String(combined[range.lowerBound...]).trimmingCharacters(in: .newlines)
    return (message, traceback)
}

func faultKind(fromShimCode code: Int32, defaultingTo fallback: ScriptFaultKind) -> ScriptFaultKind {
    switch code {
    case ELYSIUM_FAULT_INSTRUCTION_BUDGET: return .instructionBudget
    case ELYSIUM_FAULT_ALLOCATION_RATE: return .allocationRate
    case ELYSIUM_FAULT_MEMORY_CAP: return .memoryCap
    case ELYSIUM_FAULT_INVALID_YIELD: return .invalidYield
    case ELYSIUM_FAULT_HOST_ABORT: return .hostAbort
    case ELYSIUM_FAULT_RUNTIME: return .runtime
    default: return fallback
    }
}
