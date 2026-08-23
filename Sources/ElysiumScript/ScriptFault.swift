// ScriptFault.swift — task 3.3. design.md Decision 17's kind list and the spec "Error
// values and tracebacks are sanitized and address-free": `.message` <= 512 bytes,
// `.traceback` <= 2 KiB, both hygiene-filtered, address-free by construction — the shim
// (`elysium_traceback`, `luaL_tolstring`'s patched default case, the `%p` rejection in
// the `format` wrapper) never produces an address in the first place, so nothing here
// scrubs script-controlled text after the fact (design.md Condition 29).

/// Why a script stopped, mapped 1:1 from `elysium_shim.h`'s `ELYSIUM_FAULT_*` codes
/// (design.md Decision 17).
public enum ScriptFaultKind: Equatable, Sendable {
    /// `checkSyntax`/`ScriptEnvironment.compile` refused the source.
    case compile
    /// An ordinary uncaught Lua error (`ELYSIUM_ERRRUN`).
    case runtime
    /// `ScriptBudgets.handlerTotalInstructions` exceeded, or a top-level `call()`'s
    /// hard slice exhausted (design.md Condition 35).
    case instructionBudget
    /// `ScriptBudgets.allocationRatePerSliceBytes` exceeded within one slice.
    case allocationRate
    /// `ScriptBudgets.memoryCapBytes` exceeded.
    case memoryCap
    /// A host-recorded condition other than the four above forced a fault (reserved
    /// for future host-initiated aborts; not raised by anything in this change).
    case hostAbort
    /// A host function attempted to yield from a non-yieldable point (design.md
    /// Condition 29) — detected by a host-side flag, never by matching error text.
    case invalidYield
}

/// A script stopping abnormally: a compile refusal, an uncaught error, or a budget/
/// memory trip. Every field is already sanitized and capped by construction (never by
/// this type) — `LuaState` builds one only from shim output that has already passed
/// through the hygiene filter and the length caps.
public struct ScriptFault: Error, Equatable, Sendable {
    public let kind: ScriptFaultKind
    /// <= `ScriptBudgets.faultMessageBytes` (512 by default), address-free.
    public let message: String
    /// <= `ScriptBudgets.tracebackBytes` (2 KiB by default), address-free, names and
    /// lines only. Empty for `.compile` faults (there is no call stack to walk).
    public let traceback: String

    public init(kind: ScriptFaultKind, message: String, traceback: String) {
        self.kind = kind
        self.message = message
        self.traceback = traceback
    }
}
