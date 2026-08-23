// ScriptValue.swift — task 3.2. The Lua<->Swift value currency (design.md Decision 10,
// spec "ScriptValue marshaling with caps"). This file carries no Lua state and no raw
// pointer: it is a pure value type plus the cap/error vocabulary the marshaler (task
// 3.2's other half, ScriptMarshaling.swift) and every host function enforce.

/// One Lua value crossing the C boundary, restricted to the shapes design.md Decision
/// 10 allows: `null | bool | int | number | string | list | map | ref`. A Lua table is
/// either a `list` (keys exactly `1...n`, nothing else — the empty table is an empty
/// list) or a `map` (string keys only); any other table shape is a marshaling error,
/// never a `ScriptValue` case of its own (design.md: "any other table is an error").
public enum ScriptValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    /// Always finite; `-0.0` is normalized to `+0.0` by the marshaler in both
    /// directions (spec: "-0 normalized to 0"). Constructing this case directly with a
    /// non-finite or `-0.0` value is a programmer error the marshaler will reject on
    /// the way out — `ScriptMarshaling.push` re-validates rather than trusting callers.
    case number(Double)
    /// Valid UTF-8, ≤ `ScriptValueLimits.stringBytes` (checked at marshal time, not
    /// construction — a Swift host function may legitimately build a longer String
    /// only to have it length-capped as an error result).
    case string(String)
    case list([ScriptValue])
    case map([String: ScriptValue])
    /// A handle's canonical ref string (design.md Decision 10 / 1a's `AttrValue`
    /// seam). Resolution back to a live object is the host resolver's job, not this
    /// type's — an unknown ref becomes Lua `nil` on push (spec: "`.ref` resolves
    /// through the state's handle resolver and becomes `nil` when the object is
    /// unknown").
    case ref(String)
}

/// The fixed marshaling caps from `specs/script-sandbox-and-budgets/spec.md` and
/// design.md Decision 6, as a small standalone value type: `LuaState` derives one from
/// its `ScriptBudgets` at construction (so budget-shrinking tests get correspondingly
/// smaller marshaling caps) and threads it through every push/pull, but the type
/// itself carries no dependency on `ScriptBudgets` or `LuaState` — `ScriptValue`
/// construction code elsewhere in the package can reason about the caps without
/// pulling in the whole runtime.
public struct ScriptValueLimits: Sendable, Equatable {
    public var stringBytes: Int
    public var listElements: Int
    public var mapKeys: Int
    public var depth: Int
    public var nodes: Int

    public init(stringBytes: Int, listElements: Int, mapKeys: Int, depth: Int, nodes: Int) {
        self.stringBytes = stringBytes
        self.listElements = listElements
        self.mapKeys = mapKeys
        self.depth = depth
        self.nodes = nodes
    }

    /// design.md Decision 6's value caps: string 4 KiB, list 256, map 64, depth 4,
    /// nodes 1,024.
    public static let defaults = ScriptValueLimits(
        stringBytes: 4 * 1024, listElements: 256, mapKeys: 64, depth: 4, nodes: 1_024
    )
}

/// Every way a value crossing the boundary can be refused. Each case names the
/// exceeded cap or the reason (spec: "a deterministic error that names the exceeded
/// cap"); `LuaState` turns these into a Lua error string via `.message`.
public enum ScriptValueError: Error, Equatable, Sendable {
    case stringTooLong(limit: Int)
    case listTooLong(limit: Int)
    case mapTooLarge(limit: Int)
    case tooDeep(limit: Int)
    case tooManyNodes(limit: Int)
    case invalidUTF8
    case notFinite
    case sparseOrMixedTable
    case unsupportedType(String)

    /// Address-free, deterministic, and names the exceeded cap or reason (never the
    /// offending value itself, which could be arbitrarily large or ill-formed).
    public var message: String {
        switch self {
        case .stringTooLong(let limit): return "string exceeds \(limit) bytes"
        case .listTooLong(let limit): return "list exceeds \(limit) elements"
        case .mapTooLarge(let limit): return "map exceeds \(limit) keys"
        case .tooDeep(let limit): return "value nesting exceeds depth \(limit)"
        case .tooManyNodes(let limit): return "value exceeds \(limit) nodes"
        case .invalidUTF8: return "string is not valid UTF-8"
        case .notFinite: return "number must be finite"
        case .sparseOrMixedTable: return "table is sparse or has mixed key types"
        case .unsupportedType(let typeName): return "unsupported value type '\(typeName)'"
        }
    }
}
