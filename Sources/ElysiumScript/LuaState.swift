// LuaState.swift — task 3.1 (+ the dispatcher core of 3.5/3.6). design.md Decision 17:
// `LuaState` is the sole owner of the raw `lua_State *` and the only file in the whole
// package allowed to spell `OpaquePointer` (Condition 3) — every other file in this
// target that needs to touch the pointer type uses the `LuaStatePointer` typealias
// below and reaches it only through `internal` (not `private`) members of this class,
// so the marshaling (ScriptMarshaling.swift), environment (Environment.swift),
// coroutine (Coroutines.swift) and handle (Handles.swift) behavior can live in
// topically-organized files as `extension LuaState { ... }` without ever needing the
// literal token `OpaquePointer` themselves.
//
// The dispatcher (`elysium_set_dispatch`) and the host-function/handle-metamethod
// trampoline table by `fid` live here because they are the one piece every extension
// file's behavior routes through; `dispatch(fid:on:)` itself just switches on `FidRole`
// and calls back into the extension that owns that kind of call.

import CLua
import Foundation

/// The only spelling of `OpaquePointer` in `ElysiumScript` (design.md Condition 3).
/// Every other file names this typealias instead. Deliberately not `public`: nothing
/// outside this module ever needs to name it (design.md Decision 17's public API list
/// never mentions it), and Condition 25's `testPublicSurfaceHasNoRawLuaTypes` requires
/// that no public declaration fragment contain the literal text "OpaquePointer" at
/// all -- a `public typealias ... = OpaquePointer` would put it in the public symbol
/// graph by definition (Builder fix, found while writing that test).
typealias LuaStatePointer = OpaquePointer

/// Errors `LuaState` itself throws — construction and lifecycle refusals, distinct from
/// `ScriptFault` (which represents a *script's* abnormal stop, not a host-API misuse).
public enum LuaRuntimeError: Error, Equatable, Sendable {
    /// `elysium_newstate` refused: the process's locale does not pin `.`-decimal,
    /// byte-order string comparison and a plain-ASCII ctype table (design.md Decision 9).
    case localeNotPinned
    /// `elysium_newstate` refused: `ScriptMath` had a `nil` function pointer.
    case mathIncomplete
    /// `elysium_newstate` refused: host-side allocation failure constructing the state.
    case allocationFailed
    /// `elysium_newstate` refused: the protected sandbox builder (`elysium_openlibs`)
    /// failed (design.md Condition 27).
    case sandboxConstructionFailed
    /// `close()` refused: an `elysium_pcall`/`elysium_resume` entry is still active
    /// (design.md Condition 20, `hostDepth != 1`).
    case stateBusy
    /// `resume` refused: the target coroutine is already running somewhere on the
    /// entry stack (design.md Condition 20).
    case reentrantResume
    /// An entry could not be pushed: the nested `call`/`resume` stack is at its cap
    /// (design.md Condition 21, `ELYSIUM_MAX_ENTRY_DEPTH` = 16).
    case nestingTooDeep
    /// A `ScriptFunction`/`ScriptCoroutine`/`HandleRef`/`ScriptEnvironment` from a
    /// different `LuaState` (or a destroyed environment) was used here (design.md
    /// Condition 30).
    case stateMismatch
    /// `resume` refused: the coroutine already completed, faulted, or was closed.
    case deadCoroutine
    /// Any entry point called after `close()`.
    case dead
    /// `makeHandle` refused: `ref` is already registered under a different
    /// `HandleKind` (design.md Decision 10 note N3 — a ref must be unique per
    /// state; silently rebinding it to a different kind would make every later
    /// `.ref` push resolve to the wrong kind for anyone still holding the old one).
    case handleRefConflict
}

/// A snapshot of the allocator's bookkeeping (design.md Decision 5; provisional field
/// set per Decision 17).
public struct ScriptMemoryStatus: Equatable, Sendable {
    public let bytesInUse: UInt64
    public let cap: UInt64
    public let tripped: Bool
    public let rateTripped: Bool
    public let overCapHost: Bool
    public let allocationCalls: UInt64
    public let emergencyCollections: UInt64
}

/// What a registered `fid` means to `dispatch(fid:on:)`. `fid`s 0/1/2 are reserved
/// (print never reaches Swift at all; random/randomseed are routed by a fixed check
/// before this table is even consulted — see `dispatch(fid:on:)`) so nothing here is
/// ever keyed 0, 1 or 2.
enum FidRole {
    case host(HostFunction, ScriptEnvironment)
    case handleIndex(kindId: Int32)
    case handleNewIndex(kindId: Int32)
    case handleEq(kindId: Int32)
    case handleToString(kindId: Int32)
    case handleMethod(kindId: Int32, name: String)
}

/// Bookkeeping for one `makeEnvironment` result, shared by the reserved-fid dispatch
/// (`math.random`/`randomseed`, which only carry an `envId` upvalue, never a Swift
/// object reference) and `ScriptEnvironment.destroy()` (design.md Condition 30).
final class RandomStreamBox {
    var stream: any ScriptRandomStream
    init(_ stream: any ScriptRandomStream) { self.stream = stream }
}

final class EnvironmentRecord {
    let envId: UInt64
    var envRef: Int32
    let randomBox: RandomStreamBox
    var destroyed = false
    /// F3 (test.md defect, `ScriptEnvironment.destroy()` reclamation): every
    /// registry ref `compile(in:...)` anchored for this environment (each compiled
    /// chunk's `ScriptFunction.ref`). `_ENV`'s own upvalue keeps a compiled chunk's
    /// `_ENV` reachable even after `envRef` itself is released, so these must be
    /// released individually on destroy too.
    var compiledRefs: [Int32] = []
    /// F3 / note N4: every `fid` `installHostBindings` registered in `fidTable` for
    /// this environment's `HostBinding` functions — removed on destroy so the
    /// `HostFunction`/`ScriptEnvironment` they retain are not kept alive forever.
    var hostBindingFids: [Int32] = []
    init(envId: UInt64, envRef: Int32, randomBox: RandomStreamBox) {
        self.envId = envId
        self.envRef = envRef
        self.randomBox = randomBox
    }
}

public final class LuaState {
    // MARK: - Identity

    private static let identityLock = NSLock()
    private static var nextIdentityValue: UInt64 = 1
    private static func allocateIdentity() -> UInt64 {
        identityLock.lock()
        defer { identityLock.unlock() }
        let value = nextIdentityValue
        nextIdentityValue += 1
        return value
    }

    public let identity: UInt64
    let budgets: ScriptBudgets
    let valueLimits: ScriptValueLimits
    let math: ScriptMath
    let logSink: ScriptLogSink
    private let ownerThread: Thread

    var pointer: LuaStatePointer?
    private(set) var isClosed = false

    // Shared dispatch/marshaling bookkeeping — `internal` (default access) so the
    // extensions in ScriptMarshaling.swift, Environment.swift, Coroutines.swift and
    // Handles.swift can reach them directly (design.md Condition 3: only the *type*
    // `OpaquePointer` is confined to this file; ordinary internal state is not).
    var fidTable: [Int32: FidRole] = [:]
    // Handle-kind metamethod/method fids are computed C-side as `3 + kindId*4`
    // (elysium_register_handle_kind, elysium_sandbox.c) — a completely independent
    // allocation from this counter. Starting Swift's own allocation (ordinary
    // HostBinding functions, and the per-(kind,method) fids this file also owns) at a
    // large fixed offset keeps the two schemes from ever colliding without needing
    // them to coordinate; `1 << 20` handle kinds (262,144 C-side fids) is never
    // reachable in practice.
    var nextFid: Int32 = 1 << 20
    var handleKindsById: [Int32: HandleKind] = [:]
    var handleDispatchByKindId: [Int32: HandleDispatch] = [:]
    var methodFidByKindAndName: [Int32: [String: Int32]] = [:]
    var handleResolver: [String: (kind: HandleKind, id: UInt64)] = [:]
    var environments: [UInt64: EnvironmentRecord] = [:]
    var nextEnvId: UInt64 = 1

    // MARK: - Construction / lifecycle

    public init(budgets: ScriptBudgets, math: ScriptMath, log: ScriptLogSink) throws {
        LuaState.installDispatchOnce()

        self.identity = LuaState.allocateIdentity()
        self.budgets = budgets
        self.valueLimits = ScriptValueLimits(
            stringBytes: budgets.valueStringBytes,
            listElements: budgets.valueListElements,
            mapKeys: budgets.valueMapKeys,
            depth: budgets.valueDepth,
            nodes: budgets.valueNodes
        )
        self.math = math
        self.logSink = log
        self.ownerThread = Thread.current
        self.pointer = nil
        // Every stored property is now initialized; `self` may be used from here on.

        var mathTable = elysium_math_table()
        mathTable.sin = math.sin
        mathTable.cos = math.cos
        mathTable.exp = math.exp
        mathTable.log = math.log
        mathTable.atan2 = math.atan2
        mathTable.pow = math.pow

        var config = elysium_config()
        config.math = mathTable
        config.logFn = LuaState.logTrampoline
        config.swiftContext = Unmanaged.passUnretained(self).toOpaque()
        config.identity = identity
        config.memoryCapBytes = UInt64(budgets.memoryCapBytes)
        config.hostOverCapDiagnosticBytes = UInt64(budgets.hostOverCapDiagnosticBytes)
        config.allocationRatePerSliceBytes = UInt64(budgets.allocationRatePerSliceBytes)
        config.handlerTotalInstructions = UInt64(budgets.handlerTotalInstructions)
        config.logLineBytes = Int32(budgets.logLineBytes)
        config.logLinesPerSlice = Int32(budgets.logLinesPerSlice)
        config.threadPoolMax = Int32(budgets.threadPoolMax)

        var errcode: Int32 = 0
        guard let created = elysium_newstate(&config, &errcode) else {
            throw LuaState.runtimeError(forErrcode: errcode)
        }
        self.pointer = created
    }

    deinit {
        // Best effort: an active entry cannot outlive `self` in correct usage (every
        // entry point borrows `self` for its duration), so this only ever observes
        // hostDepth == 1 in practice. `deinit` cannot throw, so a busy refusal here
        // (which would indicate a caller bug elsewhere) is simply not retried.
        if !isClosed, let pointer {
            _ = elysium_close(pointer)
        }
    }

    private static func runtimeError(forErrcode errcode: Int32) -> LuaRuntimeError {
        switch errcode {
        case ELYSIUM_ERR_LOCALE: return .localeNotPinned
        case ELYSIUM_ERR_MATH: return .mathIncomplete
        case ELYSIUM_ERR_OPEN: return .sandboxConstructionFailed
        default: return .allocationFailed
        }
    }

    #if DEBUG
    func assertOwnerThread() {
        assert(
            Thread.current === ownerThread,
            "LuaState is main-thread-confined and was reached from a different thread"
        )
    }
    #else
    @inline(__always) func assertOwnerThread() {}
    #endif

    public var isDead: Bool {
        assertOwnerThread()
        return isClosed || pointer == nil
    }

    public var memoryStatus: ScriptMemoryStatus {
        assertOwnerThread()
        guard let pointer else {
            return ScriptMemoryStatus(
                bytesInUse: 0, cap: UInt64(budgets.memoryCapBytes), tripped: false,
                rateTripped: false, overCapHost: false, allocationCalls: 0, emergencyCollections: 0
            )
        }
        var raw = elysium_memory_status()
        elysium_memory_status_get(pointer, &raw)
        return ScriptMemoryStatus(
            bytesInUse: raw.bytesInUse, cap: raw.cap, tripped: raw.tripped != 0,
            rateTripped: raw.rateTripped != 0, overCapHost: raw.overCapHost != 0,
            allocationCalls: raw.allocationCalls, emergencyCollections: raw.emergencyCollections
        )
    }

    public func collectStep(kilobytes: Int) {
        assertOwnerThread()
        guard let pointer else { return }
        elysium_gc_step(pointer, Int32(kilobytes))
    }

    public func collectFull() {
        assertOwnerThread()
        guard let pointer else { return }
        elysium_gc_full(pointer)
    }

    /// Refused with `.stateBusy` while any `elysium_pcall`/`elysium_resume` entry is
    /// active (design.md Condition 20).
    public func close() throws {
        assertOwnerThread()
        guard !isClosed else { return }
        guard let pointer else {
            isClosed = true
            return
        }
        let rc = elysium_close(pointer)
        if rc == ELYSIUM_OK {
            isClosed = true
            self.pointer = nil
        } else {
            throw LuaRuntimeError.stateBusy
        }
    }

    /// Compiles `source` for syntax only and discards the result. Per design.md
    /// Condition 30, this still allocates in the state (the compiled prototype briefly
    /// exists before being popped/collected) — 1a/1c that need to validate untrusted
    /// scripts at a high rate should do so on a dedicated, disposable `LuaState`.
    public func checkSyntax(source: String, chunkName: String) -> ScriptFault? {
        assertOwnerThread()
        guard !isClosed, let pointer else {
            return ScriptFault(kind: .compile, message: "state is closed", traceback: "")
        }
        if let capFault = validateSourceAndChunkName(source: source, chunkName: chunkName) {
            return capFault
        }
        let rc: Int32 = withLuaBytes(source) { sPtr, sLen in
            chunkName.withCString { cName in
                elysium_loadtext(pointer, sPtr, sLen, cName)
            }
        }
        defer { elysium_pop(pointer, 1) }
        if rc == LUA_OK {
            return nil
        }
        let message = readTopString(cap: budgets.faultMessageBytes)
        return ScriptFault(kind: .compile, message: ScriptTextHygiene.sanitize(message), traceback: "")
    }

    /// Shared by `checkSyntax` and `ScriptEnvironment.compile` (design.md Condition 29:
    /// chunk names pass hygiene before `elysium_loadtext` is ever called).
    func validateSourceAndChunkName(source: String, chunkName: String) -> ScriptFault? {
        guard source.utf8.count <= budgets.sourceBytes else {
            return ScriptFault(
                kind: .compile, message: "source exceeds \(budgets.sourceBytes) bytes", traceback: ""
            )
        }
        guard chunkName.utf8.count <= budgets.chunkNameBytes else {
            return ScriptFault(
                kind: .compile, message: "chunk name exceeds \(budgets.chunkNameBytes) bytes", traceback: ""
            )
        }
        if let violation = ScriptTextHygiene.firstViolation(in: chunkName) {
            return ScriptFault(
                kind: .compile,
                message: "chunk name contains an invalid character at \(violation.line):\(violation.column)",
                traceback: ""
            )
        }
        return nil
    }

    // MARK: - Dispatcher installation (process-global; design.md Decision 4 Rule 1)

    private static let dispatchInstallLock = NSLock()
    private static var dispatchInstalled = false

    private static func installDispatchOnce() {
        dispatchInstallLock.lock()
        defer { dispatchInstallLock.unlock() }
        guard !dispatchInstalled else { return }
        elysium_set_dispatch(dispatchTrampoline)
        dispatchInstalled = true
    }

    /// Non-capturing `@convention(c)` closure registered exactly once, by value
    /// (design.md Condition 3). Recovers the owning `LuaState` from `swiftContext` via
    /// `Unmanaged` — the same pattern as `StorageEngine.swift`'s SQLite callbacks
    /// (`storageAuthorizerCallback`, `storageQuickCheckProgressCallback`).
    private static let dispatchTrampoline: elysium_dispatch_fn = { L, fid, ctx in
        guard let L, let ctx else { return -1 }
        let state = Unmanaged<LuaState>.fromOpaque(ctx).takeUnretainedValue()
        return state.dispatch(fid: fid, on: L)
    }

    private static let logTrampoline: elysium_log_fn = { ctx, envId, utf8, len in
        guard let ctx else { return }
        let state = Unmanaged<LuaState>.fromOpaque(ctx).takeUnretainedValue()
        state.logSink.log(envId: envId, line: decodeLuaBytes(utf8, len))
    }

    // MARK: - Dispatch routing

    func dispatch(fid: Int32, on L: LuaStatePointer) -> Int32 {
        if fid == 1 { return dispatchRandom(on: L) }
        if fid == 2 { return dispatchRandomSeed(on: L) }
        guard let role = fidTable[fid] else {
            return pushInternalError("unknown host function id \(fid)", on: L)
        }
        switch role {
        case .host(let function, let environment):
            return runHostFunction(function, environment: environment, on: L)
        case .handleIndex(let kindId):
            return dispatchHandleIndex(kindId: kindId, on: L)
        case .handleNewIndex(let kindId):
            return dispatchHandleNewIndex(kindId: kindId, on: L)
        case .handleEq(let kindId):
            return dispatchHandleEq(kindId: kindId, on: L)
        case .handleToString(let kindId):
            return dispatchHandleToString(kindId: kindId, on: L)
        case .handleMethod(let kindId, let name):
            return dispatchHandleMethod(kindId: kindId, name: name, on: L)
        }
    }

    private func runHostFunction(_ function: HostFunction, environment: ScriptEnvironment, on L: LuaStatePointer) -> Int32 {
        let nargs = lua_gettop(L)
        var arguments: [ScriptArgument] = []
        if nargs > 0 {
            arguments.reserveCapacity(Int(nargs))
            var index: Int32 = 1
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
        let call = HostCall(arguments: arguments, environment: environment, state: self)
        return pushHostResult(function.body(call), on: L)
    }

    /// Turns a `HostResult` into the trampoline status protocol (design.md Decision 4):
    /// `r >= 0` results already pushed, `r == -1` one error object pushed, `r <= -2`
    /// yield `-(r + 2)` values.
    func pushHostResult(_ result: HostResult, on L: LuaStatePointer) -> Int32 {
        switch result {
        case .values(let values):
            // design.md Condition 3: "Call lua_checkstack before multi-value pushes
            // and convert false to a host error." A C function is only guaranteed
            // LUA_MINSTACK (20) free slots on entry; a host function returning more
            // values than that without growing the stack first would corrupt it
            // past api_check's "stack overflow" assertion (Builder fix, found by
            // testHostFunctionResultCountAlwaysMatchesWhatWasPushed).
            // LOW note (Security (code) attempt 3): sized by the marshaler's
            // transient depth, not just values.count — see the matching comment
            // in Coroutines.swift's call/resume.
            if !values.isEmpty, lua_checkstack(L, Int32(values.count) + Int32(2 * valueLimits.depth + 4)) == 0 {
                return pushInternalError("stack overflow: cannot return \(values.count) values", on: L)
            }
            // F1 (test.md defect): record the top before pushing so a failing value
            // partway through (its own partially built nested tables included) can
            // be discarded by index rather than by a fixed pop count. This call
            // runs inside the trampoline, under the enclosing elysium_pcall/
            // elysium_resume's protected frame, so a raise from pushInternalError
            // below would already unwind the stack on its own -- this settop is
            // defence-in-depth symmetry with call/resume's own fix, not a
            // correctness requirement here.
            let savedTop = lua_gettop(L)
            for value in values {
                var nodeCount = 0
                do {
                    try pushScriptValue(value, on: L, depth: 0, nodeCount: &nodeCount)
                } catch let error as ScriptValueError {
                    elysium_settop(L, savedTop)
                    return pushInternalError(error.message, on: L)
                } catch {
                    elysium_settop(L, savedTop)
                    return pushInternalError("result marshaling failed", on: L)
                }
            }
            return Int32(values.count)
        case .error(let message):
            pushLuaErrorString(message, on: L)
            return -1
        case .yield(let values, let reason):
            // LOW note (Security (code) attempt 3): same transient-depth sizing
            // as the .values case above.
            if !values.isEmpty, lua_checkstack(L, Int32(values.count) + Int32(2 * valueLimits.depth + 4)) == 0 {
                return pushInternalError("stack overflow: cannot yield \(values.count) values", on: L)
            }
            let savedTop = lua_gettop(L)
            for value in values {
                var nodeCount = 0
                do {
                    try pushScriptValue(value, on: L, depth: 0, nodeCount: &nodeCount)
                } catch let error as ScriptValueError {
                    elysium_settop(L, savedTop)
                    return pushInternalError(error.message, on: L)
                } catch {
                    elysium_settop(L, savedTop)
                    return pushInternalError("result marshaling failed", on: L)
                }
            }
            switch reason {
            case .preempted:
                elysium_set_yield_reason(L, ELYSIUM_YIELD_PREEMPT, 0, 0)
            case .wait(let ticks):
                elysium_set_yield_reason(L, ELYSIUM_YIELD_WAIT, Int64(ticks), 0)
            case .await(let token):
                elysium_set_yield_reason(L, ELYSIUM_YIELD_AWAIT, 0, token)
            }
            return Int32(-(Int(values.count) + 2))
        }
    }

    func pushInternalError(_ message: String, on L: LuaStatePointer) -> Int32 {
        withLuaBytes(message) { ptr, len in _ = lua_pushlstring(L, ptr, len) }
        return -1
    }

    private func pushLuaErrorString(_ message: String, on L: LuaStatePointer) {
        var nodeCount = 0
        do {
            try pushScriptValue(.string(message), on: L, depth: 0, nodeCount: &nodeCount)
        } catch {
            withLuaBytes("host error") { ptr, len in _ = lua_pushlstring(L, ptr, len) }
        }
    }

    // MARK: - Reserved fids 1/2: math.random / math.randomseed

    /// Every environment's `random`/`randomseed` closures share the fixed fids 1/2
    /// process-wide; the closure's own upvalue 2 (not the fid, not a Swift-side table)
    /// carries which environment is calling (design.md Decision 8's
    /// `elysium_make_environment`, upvalue layout `(fid, envId)`).
    private func currentEnvId(on L: LuaStatePointer) -> UInt64 {
        UInt64(bitPattern: Int64(elysium_tointeger(L, elysium_upvalueindex(2))))
    }

    private func dispatchRandom(on L: LuaStatePointer) -> Int32 {
        let envId = currentEnvId(on: L)
        guard let record = environments[envId], !record.destroyed else {
            return pushInternalError("environment is destroyed", on: L)
        }
        let nargs = lua_gettop(L)
        let maxSpan: UInt64 = 1 << 53

        func draw01() -> Double {
            Double(record.randomBox.stream.nextUInt32()) / 4_294_967_296.0
        }

        switch nargs {
        case 0:
            lua_pushnumber(L, draw01())
            return 1
        case 1:
            let m = elysium_tointeger(L, 1)
            if m == 0 {
                let hi = UInt64(record.randomBox.stream.nextUInt32())
                let lo = UInt64(record.randomBox.stream.nextUInt32())
                lua_pushinteger(L, lua_Integer(bitPattern: (hi << 32) | lo))
                return 1
            }
            guard m >= 1, UInt64(m) <= maxSpan else {
                return pushInternalError("bad argument #1 to 'random' (interval is empty)", on: L)
            }
            let span = UInt64(m)
            let offset = min(UInt64(draw01() * Double(span)), span - 1)
            lua_pushinteger(L, lua_Integer(1) + lua_Integer(offset))
            return 1
        case 2:
            let m = elysium_tointeger(L, 1)
            let n = elysium_tointeger(L, 2)
            guard m <= n else {
                return pushInternalError("bad argument #2 to 'random' (interval is empty)", on: L)
            }
            let spanI = n &- m &+ 1
            guard spanI > 0, UInt64(spanI) <= maxSpan else {
                return pushInternalError("bad argument #2 to 'random' (interval too large)", on: L)
            }
            let span = UInt64(spanI)
            let offset = min(UInt64(draw01() * Double(span)), span - 1)
            lua_pushinteger(L, m + lua_Integer(offset))
            return 1
        default:
            return pushInternalError("wrong number of arguments to 'random'", on: L)
        }
    }

    private func dispatchRandomSeed(on L: LuaStatePointer) -> Int32 {
        let envId = currentEnvId(on: L)
        guard let record = environments[envId], !record.destroyed else {
            return pushInternalError("environment is destroyed", on: L)
        }
        guard lua_gettop(L) >= 1 else {
            return pushInternalError("randomseed requires an argument", on: L)
        }
        let raw = elysium_tointeger(L, 1)
        record.randomBox.stream.reseed(UInt32(truncatingIfNeeded: raw))
        return 0
    }
}

// MARK: - Shared low-level string helpers (used across every extension file)

/// Runs `body` with `s`'s UTF-8 bytes as a `(pointer, length)` pair, matching every
/// `elysium_*` entry that takes a length-prefixed buffer rather than a NUL-terminated
/// C string.
@inline(__always)
func withLuaBytes<R>(_ s: String, _ body: (UnsafePointer<CChar>?, Int) -> R) -> R {
    var bytes = Array(s.utf8)
    return bytes.withUnsafeMutableBufferPointer { buf -> R in
        guard let base = buf.baseAddress else { return body(nil, 0) }
        return base.withMemoryRebound(to: CChar.self, capacity: buf.count) { body($0, buf.count) }
    }
}

/// Decodes with repair (never traps on invalid UTF-8) — design.md Condition 26: script-
/// controlled text is always read this way, never `String(cString:)`.
func decodeLuaBytes(_ ptr: UnsafePointer<CChar>?, _ len: Int) -> String {
    guard let ptr, len > 0 else { return "" }
    return ptr.withMemoryRebound(to: UInt8.self, capacity: len) { p in
        String(decoding: UnsafeBufferPointer(start: p, count: len), as: UTF8.self)
    }
}

/// Truncates on a Unicode scalar boundary (never mid-encoding) — design.md Condition 26.
func truncateUTF8(_ s: String, toByteCount cap: Int) -> String {
    guard cap >= 0, s.utf8.count > cap else { return s }
    var result = ""
    var used = 0
    for scalar in s.unicodeScalars {
        let n = String(scalar).utf8.count
        if used + n > cap { break }
        result.unicodeScalars.append(scalar)
        used += n
    }
    return result
}

func decodeAndCap(_ ptr: UnsafePointer<CChar>?, _ len: Int, cap: Int) -> String {
    truncateUTF8(decodeLuaBytes(ptr, len), toByteCount: cap)
}

extension LuaState {
    /// Reads and pops the string on top of `pointer`'s stack, decoded with repair and
    /// capped on a scalar boundary. Every caller already knows the top is a string
    /// (Lua compile/runtime error objects normalized by `luaL_tolstring`'s patch or by
    /// `elysium_msgh`) or accepts `""` for a non-string top.
    func readTopString(cap: Int) -> String {
        guard let pointer else { return "" }
        var len = 0
        guard let cstr = lua_tolstring(pointer, -1, &len) else { return "" }
        return decodeAndCap(cstr, len, cap: cap)
    }
}
