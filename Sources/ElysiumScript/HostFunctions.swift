// HostFunctions.swift — task 3.3. design.md Decision 17: `HostBinding`, `HostFunction`,
// `HostCall`, `ScriptArgument`, `HostResult`, `ScriptYieldReason` — the vocabulary a
// later change (1a onward) uses to attach real host API surface to an environment.
// Nothing in this change registers a non-empty `HostBinding` tree against a real game
// object (that is 1a's job); this file exists so the shape is stable and exercised by
// this change's own smoke test.

/// Why a coroutine yielded from inside a host function (design.md Decision 7 / spec
/// "Coroutine resume contract and thread pool"). `.preempted` is produced only by the
/// count hook, never by a host function.
public enum ScriptYieldReason: Equatable, Sendable {
    case preempted
    /// Resume after `ticks` scheduler ticks; the next `resume` call must pass zero
    /// arguments (design.md Decision 7).
    case wait(Int)
    /// Resume when the host completes the async operation identified by `token`; the
    /// next `resume` call's arguments become this call's results (design.md Decision 7
    /// / spec "Await resume values").
    case await(UInt64)
}

/// One argument a script passed to a host function, before `ScriptValue`'s shape
/// restrictions are applied — a host function that specifically wants a Lua function
/// or a handle (rather than the marshaling error a bare `ScriptValue` extraction would
/// produce for either) receives it as one of these instead (design.md Decision 10).
public enum ScriptArgument {
    case value(ScriptValue)
    case function(ScriptFunction)
    case handle(HandleRef)
    /// A Lua thread, non-handle userdata, or any other type `ScriptValue` cannot
    /// represent; `typeName` is the Lua type name (`"thread"`, `"userdata"`, ...).
    case unsupported(String)
}

/// One host-function invocation: the marshaled arguments, which environment placed the
/// call (design.md Decision 17), and the owning state. `environment` is `nil` only for
/// a handle-kind dispatch closure (`HandleDispatch`) — a handle kind is registered
/// state-wide, not per-environment, and a handle method can be reached from any
/// environment's script, so the caller's environment is not always determinable;
/// every `HostBinding` function (registered against one specific environment) always
/// has a non-`nil` environment here.
public struct HostCall {
    public let arguments: [ScriptArgument]
    public let environment: ScriptEnvironment?
    public let state: LuaState

    public init(arguments: [ScriptArgument], environment: ScriptEnvironment?, state: LuaState) {
        self.arguments = arguments
        self.environment = environment
        self.state = state
    }
}

/// What a host function produced (design.md Decision 10). `.error` becomes an ordinary
/// catchable Lua error with exactly this message (spec "Host function error"); `.yield`
/// is refused with `ScriptFaultKind.invalidYield` unless the call is running inside a
/// yieldable coroutine (design.md Condition 29).
public enum HostResult {
    case values([ScriptValue])
    case error(String)
    case yield([ScriptValue], ScriptYieldReason)
}

/// One host function's Swift body (design.md Decision 17). A plain wrapper (not a bare
/// closure typealias) so `HostBinding.function` and `LuaState`'s internal fid table have
/// a named type to store.
public struct HostFunction {
    public var body: (HostCall) -> HostResult

    public init(_ body: @escaping (HostCall) -> HostResult) {
        self.body = body
    }
}

/// One node of a host API tree attached to an environment via
/// `LuaState.makeEnvironment(name:hostBindings:random:)` (design.md Decision 8/17).
/// `.table` nodes are frozen the same way every sandbox library table is (Condition 7)
/// — nothing reachable from `_ENV` is writable except `_ENV` itself.
public indirect enum HostBinding {
    case function(name: String, HostFunction)
    case table(name: String, [HostBinding])
}
