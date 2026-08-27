// ScriptLanguageSchema.swift — one deterministic authoring catalog for the shipped Lua
// sandbox. The runtime remains the authority that executes calls; this pure-data schema is the
// shared description used by the native editor, generated LuaCATS definitions, documentation,
// snippets, and conformance tests. Keeping the descriptions here prevents each UI surface from
// maintaining another incomplete list of strings.

import Foundation

public enum ScriptLanguageValueType: Sendable, Equatable {
    case any
    case boolean
    case integer
    case number
    case string
    case function
    case table
    case objectHandle
    case attributeProxy
    case event
    case item
    case effectList
    case list
    case map
    case enumeration([String])

    public var displayName: String {
        switch self {
        case .any: return "any"
        case .boolean: return "boolean"
        case .integer: return "integer"
        case .number: return "number"
        case .string: return "string"
        case .function: return "function"
        case .table: return "table"
        case .objectHandle: return "ElysiumObject"
        case .attributeProxy: return "ElysiumAttributes"
        case .event: return "ElysiumEvent"
        case .item: return "ElysiumItem"
        case .effectList: return "ElysiumEffect[]"
        case .list: return "any[]"
        case .map: return "table<string, any>"
        case .enumeration(let values): return values.map { "\"\($0)\"" }.joined(separator: "|")
        }
    }

    public init(attributeKind: AttrKind) {
        switch attributeKind {
        case .bool: self = .boolean
        case .int: self = .integer
        case .number: self = .number
        case .string: self = .string
        case .ref: self = .objectHandle
        case .list: self = .list
        case .map: self = .map
        case .item: self = .item
        case .effectList: self = .effectList
        case .enumeration(let values): self = .enumeration(values)
        }
    }
}

public struct ScriptParameterDescriptor: Sendable, Equatable {
    public let name: String
    public let type: ScriptLanguageValueType
    public let isOptional: Bool
    public let isVariadic: Bool
    public let summary: String

    public init(
        name: String,
        type: ScriptLanguageValueType,
        isOptional: Bool = false,
        isVariadic: Bool = false,
        summary: String = ""
    ) {
        self.name = name
        self.type = type
        self.isOptional = isOptional
        self.isVariadic = isVariadic
        self.summary = summary
    }
}

public struct ScriptReturnDescriptor: Sendable, Equatable {
    public let type: ScriptLanguageValueType
    public let isNullable: Bool
    public let summary: String

    public init(type: ScriptLanguageValueType, isNullable: Bool = false, summary: String = "") {
        self.type = type
        self.isNullable = isNullable
        self.summary = summary
    }
}

public struct ScriptCallableSignature: Sendable, Equatable {
    public let label: String
    public let parameters: [ScriptParameterDescriptor]
    public let returns: [ScriptReturnDescriptor]
    public let isYielding: Bool
    public let summary: String

    public init(
        label: String,
        parameters: [ScriptParameterDescriptor] = [],
        returns: [ScriptReturnDescriptor] = [],
        isYielding: Bool = false,
        summary: String = ""
    ) {
        self.label = label
        self.parameters = parameters
        self.returns = returns
        self.isYielding = isYielding
        self.summary = summary
    }
}

public enum ScriptLanguageAvailability: Sendable, Equatable {
    case available
    /// The parser/runtime accepts the call, but the shipped game currently performs no effect.
    case acceptedNoOp(String)
    /// The name is part of the published event/API namespace but has no shipped producer yet.
    case reserved(String)
    /// Kept for a precise diagnostic and replacement; never offered as ordinary completion.
    case unavailable(reason: String, replacement: String?)

    public var isCompletable: Bool {
        switch self {
        case .available, .acceptedNoOp: return true
        case .reserved, .unavailable: return false
        }
    }
}

public enum ScriptLanguageSymbolKind: String, Sendable, Equatable, Hashable {
    case keyword
    case implicitLocal
    case globalFunction
    case globalValue
    case module
    case moduleFunction
    case moduleValue
    case handleMethod
    case handleProperty
    case unsupported
}

public struct ScriptLanguageSymbol: Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: ScriptLanguageSymbolKind
    public let parent: String?
    public let name: String
    public let signatures: [ScriptCallableSignature]
    public let valueType: ScriptLanguageValueType
    /// Empty for non-handle symbols. Handle members list every object kind on which they are valid.
    public let receiverKinds: Set<ObjectKind>
    public let mutability: Mutability?
    public let availability: ScriptLanguageAvailability
    public let summary: String
    public let insertionText: String

    public init(
        id: String? = nil,
        kind: ScriptLanguageSymbolKind,
        parent: String? = nil,
        name: String,
        signatures: [ScriptCallableSignature] = [],
        valueType: ScriptLanguageValueType,
        receiverKinds: Set<ObjectKind> = [],
        mutability: Mutability? = nil,
        availability: ScriptLanguageAvailability = .available,
        summary: String,
        insertionText: String? = nil
    ) {
        self.id = id ?? [parent, name].compactMap { $0 }.joined(separator: ".")
        self.kind = kind
        self.parent = parent
        self.name = name
        self.signatures = signatures
        self.valueType = valueType
        self.receiverKinds = receiverKinds
        self.mutability = mutability
        self.availability = availability
        self.summary = summary
        self.insertionText = insertionText ?? name
    }
}

public struct ScriptLanguageAttribute: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let aliases: [String]
    public let kinds: Set<ObjectKind>
    public let applicability: Applicability
    public let type: ScriptLanguageValueType
    public let mutability: Mutability
    public let observable: Bool
    public let aiExposed: Bool
    public let summary: String

    /// Direct `h.name` access is valid only for a Lua identifier. Dotted/indexed registry names
    /// and must not collide with a fixed handle property/method (notably the block registry's
    /// `name` attribute versus the handle's display-name property). Other registry names remain
    /// available through `h:get("name")`/`h:set("name", value)` and must not be inserted after a
    /// literal dot by completion.
    public var supportsDotAccess: Bool {
        supportsDotAccess(name)
    }

    /// Canonical spelling plus the camelCase sugar accepted by ScriptRuntimeAPI, restricted to
    /// identifiers that are safe after a literal Lua dot.
    public var dotAccessNames: [String] {
        ([name] + aliases).filter(supportsDotAccess(_:))
    }

    public func supportsDotAccess(_ candidate: String) -> Bool {
        let fixedHandleMembers: Set<String> = [
            "ref", "kind", "name", "attrs", "exists", "get", "set", "scripts", "define",
            "events", "declareEvent", "undeclareEvent", "on", "onAttribute", "emit",
            "attach", "detach", "setFurnaceOutput", "setBlock", "breakBlock",
        ]
        guard !fixedHandleMembers.contains(candidate) else { return false }
        guard let first = candidate.utf8.first,
              (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z")) || first == UInt8(ascii: "_") else {
            return false
        }
        guard !ScriptLanguageSchema.keywords.contains(candidate) else { return false }
        return candidate.utf8.dropFirst().allSatisfy { byte in
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || byte == UInt8(ascii: "_")
        }
    }

    init(_ descriptor: AttributeDescriptor) {
        id = "attribute.\(descriptor.canonical)"
        name = descriptor.canonical
        var projectedAliases = descriptor.aliases
        if !descriptor.canonical.contains("."), descriptor.canonical.contains("_") {
            let pieces = descriptor.canonical.split(separator: "_", omittingEmptySubsequences: false)
            let camel = pieces.enumerated().map { index, piece in
                index == 0 ? String(piece) : piece.prefix(1).uppercased() + piece.dropFirst()
            }.joined()
            if camel != descriptor.canonical, !projectedAliases.contains(camel) {
                projectedAliases.append(camel)
            }
        }
        aliases = projectedAliases
        kinds = descriptor.kinds
        applicability = descriptor.applicability
        type = ScriptLanguageValueType(attributeKind: descriptor.valueKind)
        mutability = descriptor.mutability
        observable = descriptor.observable
        aiExposed = descriptor.aiExposed
        summary = descriptor.summary
    }
}

public enum ScriptSnippetCategory: String, Sendable, CaseIterable {
    case events = "Events"
    case control = "Control"
    case objects = "Objects"
    case timing = "Timing"
    case ai = "AI"
    case misc = "Misc"
    case attributes = "Attributes"
}

public struct ScriptSnippetDescriptor: Sendable, Equatable, Identifiable {
    public let id: String
    public let category: ScriptSnippetCategory
    public let name: String
    public let code: String
    public let summary: String
    /// `nil` means every owner kind; a non-empty set narrows a snippet such as block mutation.
    public let ownerKinds: Set<ObjectKind>?

    public init(
        id: String,
        category: ScriptSnippetCategory,
        name: String,
        code: String,
        summary: String,
        ownerKinds: Set<ObjectKind>? = nil
    ) {
        self.id = id
        self.category = category
        self.name = name
        self.code = code
        self.summary = summary
        self.ownerKinds = ownerKinds
    }
}

public struct ScriptSnippetSection: Sendable, Equatable, Identifiable {
    public var id: String { category.rawValue }
    public let category: ScriptSnippetCategory
    public let items: [ScriptSnippetDescriptor]

    public init(category: ScriptSnippetCategory, items: [ScriptSnippetDescriptor]) {
        self.category = category
        self.items = items
    }
}

public enum ScriptLanguageSchema {
    /// Character budget used when the editor supplies this generated reference to its local AI.
    /// Keep this bounded, but large enough to include the executable globals and object lookup
    /// surface that follow the object-handle methods.
    public static let editorAIPrefixCharacterLimit = 6_500

    public static let keywords = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto",
        "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
    ]

    public static let implicitLocals: [ScriptLanguageSymbol] = [
        value(.implicitLocal, "self", .objectHandle, "The object that owns this script."),
        value(.implicitLocal, "world", .objectHandle, "The current world's handle."),
        value(.implicitLocal, "player", .objectHandle, "The local player's handle."),
        value(.implicitLocal, "ev", .event, "The current event. Present in handlers and event callbacks."),
    ]

    /// The Elysium-defined top-level functions. Conformance tests compare these exact names with
    /// `ScriptRuntime.buildHostBindings()` so an implementation change cannot silently outrun the editor.
    public static let engineGlobals: [ScriptLanguageSymbol] = [
        function(
            .globalFunction, "on",
            signatures: [
                signature("on(event, fn)", [p("event", .string), p("fn", .function)]),
                signature("on(event, opts, fn)", [p("event", .string), p("opts", .table), p("fn", .function)]),
            ],
            summary: "Subscribe this script's owner to an event. The callback receives only ev."
        ),
        function(
            .globalFunction, "subscribe",
            signatures: [
                signature("subscribe(target, event, fn)", [p("target", .any), p("event", .string), p("fn", .function)]),
                signature("subscribe(target, event, opts, fn)", [p("target", .any), p("event", .string), p("opts", .table), p("fn", .function)]),
            ],
            summary: "Subscribe to an event on a handle, canonical ref, kind filter, or any target."
        ),
        function(
            .globalFunction, "every",
            signatures: [
                signature("every(ticks, handlerName)", [p("ticks", .integer), p("handlerName", .string)]),
                signature("every(ticks, fn)", [p("ticks", .integer), p("fn", .function)]),
            ],
            summary: "Schedule a named durable repeating timer. A function callback is live-only and fires once."
        ),
        function(
            .globalFunction, "after",
            signatures: [
                signature("after(ticks, handlerName)", [p("ticks", .integer), p("handlerName", .string)]),
                signature("after(ticks, fn)", [p("ticks", .integer), p("fn", .function)]),
            ],
            summary: "Schedule a one-shot named durable timer or live callback."
        ),
        function(
            .globalFunction, "wait",
            signatures: [signature("wait(ticks)", [p("ticks", .integer)], isYielding: true)],
            summary: "Yield the current handler for the requested number of ticks."
        ),
        function(
            .globalFunction, "emit",
            signatures: [signature(
                "emit(name[, payload][, target])",
                [p("name", .string), p("payload", .map, optional: true), p("target", .objectHandle, optional: true)],
                returns: [r(.boolean, "Whether the event was enqueued.")]
            )],
            summary: "Emit a custom event (1–3 args); target defaults to self and, if supplied, must be a handle."
        ),
        function(
            .globalFunction, "tick",
            signatures: [signature("tick()", returns: [r(.integer, "Current world tick.")])],
            summary: "Return the current deterministic world tick."
        ),
        function(
            .globalFunction, "rng",
            signatures: [
                signature("rng()", returns: [r(.number, "A value in [0, 1).")]),
                signature("rng(max)", [p("max", .integer)], returns: [r(.integer, "An integer in [1, max].")]),
                signature("rng(min, max)", [p("min", .integer), p("max", .integer)], returns: [r(.integer, "An integer in [min, max].")]),
            ],
            summary: "Draw from this script's persisted deterministic random stream."
        ),
        function(.globalFunction, "say", signatures: [signature("say(text)", [p("text", .string)])], summary: "Post a bounded, filtered chat line from this object."),
        function(
            .globalFunction, "sound",
            signatures: [signature("sound(...)", [p("arguments", .any, variadic: true)])],
            availability: .acceptedNoOp("Audio wiring is not implemented yet."),
            summary: "Accepted for forward compatibility, but currently produces no sound."
        ),
        function(
            .globalFunction, "particles",
            signatures: [signature("particles(...)", [p("arguments", .any, variadic: true)])],
            availability: .acceptedNoOp("Renderer particle wiring is not implemented yet."),
            summary: "Accepted for forward compatibility, but currently produces no particles."
        ),
        function(
            .globalFunction, "dim",
            signatures: [signature(
                "dim(name)", [p("name", .enumeration(["overworld", "nether", "end"]))],
                returns: [r(.objectHandle, "The requested dimension handle.")]
            )],
            summary: "Create a dimension handle from a canonical dimension name."
        ),
        function(.globalFunction, "register", signatures: [signature("register(name, fn)", [p("name", .string), p("fn", .function)])], summary: "Name a callback for durable timers or persisted subscriptions. The reserved name unload installs a synchronous, no-ev, custom-attribute-only finalizer; unload is not an EventBus event."),
    ]

    /// Sandboxed Lua base globals that remain reachable in every environment. Deliberately absent:
    /// `_G`, `load`, `loadfile`, `dofile`, `collectgarbage`, `rawget`, `rawset`, and `warn`.
    public static let luaBaseGlobals: [ScriptLanguageSymbol] = [
        function(.globalFunction, "assert", labels: ["assert(value[, message])"], returns: [.any], summary: "Raise an error when value is false or nil."),
        function(.globalFunction, "error", labels: ["error(message[, level])"], summary: "Raise a Lua error."),
        function(.globalFunction, "getmetatable", labels: ["getmetatable(object)"], returns: [.any], summary: "Return an object's protected metatable value."),
        function(.globalFunction, "ipairs", labels: ["ipairs(table)"], returns: [.function, .table, .integer], summary: "Iterate consecutive integer keys."),
        function(.globalFunction, "next", labels: ["next(table[, index])"], returns: [.any, .any], summary: "Return the next table key and value."),
        function(.globalFunction, "pairs", labels: ["pairs(table)"], returns: [.function, .table, .any], summary: "Iterate a table. Attribute proxies do not support pairs."),
        function(.globalFunction, "pcall", labels: ["pcall(fn, ...)"], returns: [.boolean, .any], summary: "Call a function and capture an ordinary Lua error."),
        function(.globalFunction, "print", labels: ["print(...)"], summary: "Write only to the host console; use say() for player-visible text."),
        function(.globalFunction, "rawequal", labels: ["rawequal(a, b)"], returns: [.boolean], summary: "Compare values without invoking __eq."),
        function(.globalFunction, "rawlen", labels: ["rawlen(value)"], returns: [.integer], summary: "Return a table or string length without metamethods."),
        function(.globalFunction, "select", labels: ["select(index, ...)"], returns: [.any], summary: "Return values beginning at an index in a variadic argument list."),
        function(.globalFunction, "setmetatable", labels: ["setmetatable(table, metatable)"], returns: [.table], summary: "Set a filtered, protected metatable on a script-owned table."),
        function(.globalFunction, "tonumber", labels: ["tonumber(value[, base])"], returns: [.number], summary: "Convert a value to a number when possible."),
        function(.globalFunction, "tostring", labels: ["tostring(value)"], returns: [.string], summary: "Convert a value to its address-free string form."),
        function(.globalFunction, "type", labels: ["type(value)"], returns: [.string], summary: "Return a Lua value's type name."),
        function(.globalFunction, "xpcall", labels: ["xpcall(fn, messageHandler, ...)"], returns: [.boolean, .any], summary: "Protected call with an error transformer."),
        value(.globalValue, "_VERSION", .string, "The embedded Lua version string."),
    ]

    public static let modules: [ScriptLanguageSymbol] = [
        value(.module, "objects", .table, "Resolve and discover scriptable game objects."),
        value(.module, "ai", .table, "Ask the configured Ollama model for text without tools."),
        value(.module, "math", .table, "Deterministic numeric functions and this script's RNG."),
        value(.module, "string", .table, "Bounded Lua string operations."),
        value(.module, "table", .table, "Bounded Lua table operations."),
        value(.module, "utf8", .table, "Bounded UTF-8 inspection and construction."),
    ]

    public static let engineModuleMembers: [ScriptLanguageSymbol] = [
        function(
            .moduleFunction, "get", parent: "objects",
            signatures: [signature("objects.get(ref)", [p("ref", .any)], returns: [r(.objectHandle, "A live object handle, or nil.", nullable: true)])],
            summary: "Resolve a live handle or return nil."
        ),
        function(
            .moduleFunction, "find", parent: "objects",
            signatures: [signature("objects.find{kind=, type=, near=, radius=, limit=}", [p("options", .map)], returns: [r(.list, "Nearby handles in deterministic order.")])],
            summary: "Find bounded nearby handles sorted by distance then canonical ref."
        ),
        function(
            .moduleFunction, "block", parent: "objects",
            signatures: [signature(
                "objects.block(dim, x, y, z)",
                [p("dim", .enumeration(["overworld", "nether", "end"])), p("x", .integer), p("y", .integer), p("z", .integer)],
                returns: [r(.objectHandle, "Bounds-checked block handle.")]
            )],
            summary: "Create a bounds-checked block handle."
        ),
        function(
            .moduleFunction, "ask", parent: "ai",
            signatures: [signature("ai.ask(prompt[, opts])", [p("prompt", .string), p("opts", .table, optional: true)], returns: [r(.integer, "Request identifier.")])],
            summary: "Queue a text-only model request; reply arrives as ai.replied."
        ),
        function(.moduleFunction, "await", parent: "ai", signatures: [signature("ai.await(prompt[, opts])", [p("prompt", .string), p("opts", .table, optional: true)], returns: [r(.string, "Reply text.", nullable: true), r(.string, "timeout or budget error.", nullable: true)], isYielding: true)], summary: "Yield until a text-only model reply or error arrives."),
    ]

    public static let luaModuleMembers: [ScriptLanguageSymbol] =
        library("math", functions: [
            ("abs", "math.abs(x)"), ("acos", "math.acos(x)"), ("asin", "math.asin(x)"),
            ("atan", "math.atan(y[, x])"), ("ceil", "math.ceil(x)"), ("cos", "math.cos(x)"),
            ("deg", "math.deg(x)"), ("exp", "math.exp(x)"), ("floor", "math.floor(x)"),
            ("fmod", "math.fmod(x, y)"), ("log", "math.log(x[, base])"), ("log2", "math.log2(x)"),
            ("log10", "math.log10(x)"), ("max", "math.max(x, ...)"), ("min", "math.min(x, ...)"),
            ("modf", "math.modf(x)"), ("rad", "math.rad(x)"), ("random", "math.random([m[, n]])"),
            ("randomseed", "math.randomseed(seed)"), ("sin", "math.sin(x)"), ("sqrt", "math.sqrt(x)"),
            ("tan", "math.tan(x)"), ("tointeger", "math.tointeger(x)"), ("type", "math.type(x)"),
            ("ult", "math.ult(m, n)"),
        ], returnType: .number, returnOverrides: [
            "ceil": [.integer],
            "floor": [.integer],
            "modf": [.number, .number],
            "randomseed": [],
            "tointeger": [.integer],
            "type": [.string],
            "ult": [.boolean],
        ], summary: "Sandboxed deterministic math function.")
        + [
            value(.moduleValue, "huge", .number, "Positive infinity.", parent: "math"),
            value(.moduleValue, "maxinteger", .integer, "Largest Lua integer.", parent: "math"),
            value(.moduleValue, "mininteger", .integer, "Smallest Lua integer.", parent: "math"),
            value(.moduleValue, "pi", .number, "Pi.", parent: "math"),
        ]
        + library("string", functions: [
            ("byte", "string.byte(s[, i[, j]])"), ("char", "string.char(...)"),
            ("find", "string.find(s, pattern[, init[, plain]])"), ("format", "string.format(format, ...)"),
            ("gmatch", "string.gmatch(s, pattern[, init])"), ("gsub", "string.gsub(s, pattern, replacement[, n])"),
            ("len", "string.len(s)"), ("lower", "string.lower(s)"), ("match", "string.match(s, pattern[, init])"),
            ("pack", "string.pack(format, values...)"), ("packsize", "string.packsize(format)"),
            ("rep", "string.rep(s, n[, separator])"), ("reverse", "string.reverse(s)"),
            ("sub", "string.sub(s, i[, j])"), ("unpack", "string.unpack(format, s[, pos])"),
            ("upper", "string.upper(s)"),
        ], returnType: .any, summary: "Sandboxed, bounded Lua string function; see the signature for its result shape.")
        + library("table", functions: [
            ("concat", "table.concat(list[, separator[, i[, j]]])"),
            ("move", "table.move(a1, f, e, t[, a2])"), ("pack", "table.pack(...)"),
            ("remove", "table.remove(list[, pos])"), ("sort", "table.sort(list[, comp])"),
            ("unpack", "table.unpack(list[, i[, j]])"),
        ], returnType: .any, summary: "Sandboxed, bounded Lua table function.")
        + [function(
            .moduleFunction, "insert", parent: "table",
            signatures: [
                signature("table.insert(list, value)", [p("list", .table), p("value", .any)]),
                signature(
                    "table.insert(list, pos, value)",
                    [p("list", .table), p("pos", .integer), p("value", .any)]
                ),
            ],
            summary: "Insert a value at the end of a table or at an explicit position."
        )]
        + library("utf8", functions: [
            ("char", "utf8.char(...)"), ("codes", "utf8.codes(s[, lax])"),
            ("codepoint", "utf8.codepoint(s[, i[, j[, lax]]])"), ("len", "utf8.len(s[, i[, j[, lax]]])"),
            ("offset", "utf8.offset(s, n[, i])"),
        ], returnType: .any, summary: "Sandboxed, bounded UTF-8 function.")
        + [value(.moduleValue, "charpattern", .string, "Pattern matching exactly one UTF-8 byte sequence.", parent: "utf8")]

    public static let handleProperties: [ScriptLanguageSymbol] = [
        property("ref", .string, .readOnly, "Canonical stable object reference."),
        property("kind", .enumeration(ObjectKind.allCases.map(\.rawValue)), .readOnly, "Object kind."),
        property("name", .string, .readOnly, "Current display name."),
        property("attrs", .attributeProxy, .readOnly, "Live custom-attribute proxy. Named access only; pairs() is unsupported."),
    ]

    public static let handleMethods: [ScriptLanguageSymbol] = [
        method("exists", signatures: [signature("h:exists()", returns: [r(.boolean)])], summary: "Whether the handle currently resolves live."),
        method("get", signatures: [signature("h:get(name)", [p("name", .string)], returns: [r(.any, "Attribute value, or nil.", nullable: true)])], summary: "Read a built-in or custom attribute by name; unknown reads return nil."),
        method("set", signatures: [signature("h:set(name, value)", [p("name", .string), p("value", .any)])], summary: "Write a mutable built-in attribute, or create/update a mutable custom attribute."),
        method("scripts", signatures: [signature("h:scripts()", returns: [r(.list)])], summary: "List scripts attached to this object."),
        method("define", signatures: [signature("h:define(name, value[, opts])", [p("name", .string), p("value", .any), p("opts", .table, optional: true)])], summary: "Define an attribute; opts accepts only boolean readonly and force fields."),
        method("events", signatures: [signature("h:events()", returns: [r(.list)])], summary: "List custom event declarations owned by this object, including typed payload fields."),
        method("declareEvent", signatures: [signature("h:declareEvent(name[, fields][, summary])", [p("name", .string), p("fields", .table, optional: true), p("summary", .string, optional: true)], returns: [r(.boolean)])], summary: "Declare or update this object's custom event schema. Field values are any, boolean, integer, number, string, object, list, or map, with ? for nullable."),
        method("undeclareEvent", signatures: [signature("h:undeclareEvent(name)", [p("name", .string)], returns: [r(.boolean)])], summary: "Remove this object's custom event declaration; existing open-name subscriptions continue to work."),
        method("on", signatures: [signature("h:on(event[, opts], fn)", [p("event", .string), p("opts", .table, optional: true), p("fn", .function)])], summary: "Subscribe on this exact object; opts accepts only attr and name."),
        method("onAttribute", signatures: [signature("h:onAttribute(name, fn)", [p("name", .string), p("fn", .function)])], summary: "Subscribe the current module to attribute.changed for one attribute on this object."),
        method("emit", signatures: [signature("h:emit(name[, payload])", [p("name", .string), p("payload", .map, optional: true)], returns: [r(.boolean)])], summary: "Emit a custom event on this object (1–2 args); built-ins are rejected."),
        method("attach", signatures: [signature("h:attach(name, source[, opts])", [p("name", .string), p("source", .string), p("opts", .table, optional: true)], returns: [r(.boolean)])], summary: "Attach module source when options are omitted, or a handler when a valid opts.on is supplied; opts.attr filters attribute.changed and opts.target is a handle. There is no opts.mode option."),
        method("detach", signatures: [signature("h:detach(name)", [p("name", .string)], returns: [r(.boolean)])], summary: "Detach a named script."),
        method("setFurnaceOutput", signatures: [signature("furnace:setFurnaceOutput(item)", [p("item", .string)], returns: [r(.boolean)])], receiverKinds: [.block], summary: "While this attached script is live, replace this furnace family's existing and future recipe output with a registered item; use default to clear."),
        method("setBlock", signatures: [signature("block:setBlock(name[, opts])", [p("name", .string), p("opts", .table, optional: true)], returns: [r(.boolean)])], receiverKinds: [.block], summary: "Replace this block and optionally apply built-in block attributes."),
        method("breakBlock", signatures: [signature("block:breakBlock()", returns: [r(.boolean)])], receiverKinds: [.block], summary: "Break this block naturally, including normal drops."),
    ]

    public static let unsupportedSymbols: [ScriptLanguageSymbol] = [
        ScriptLanguageSymbol(
            kind: .unsupported, name: "log", signatures: [], valueType: .function,
            availability: .unavailable(reason: "There is no log() global in the shipped sandbox.", replacement: "say"),
            summary: "Use say(text) for player-visible output.", insertionText: "say"
        ),
    ]

    /// Stable catalog order: keywords, implicit locals, Lua base, Elysium globals, modules,
    /// module members, handle properties, handle methods, then diagnostic-only names.
    public static let allSymbols: [ScriptLanguageSymbol] =
        keywords.map { value(.keyword, $0, .any, "Lua keyword.") }
        + implicitLocals + luaBaseGlobals + engineGlobals + modules + engineModuleMembers
        + luaModuleMembers + handleProperties + handleMethods + unsupportedSymbols

    public static func symbol(named name: String, parent: String? = nil) -> ScriptLanguageSymbol? {
        allSymbols.first { $0.name == name && $0.parent == parent }
    }

    public static func moduleMembers(named module: String) -> [ScriptLanguageSymbol] {
        allSymbols.filter { $0.parent == module && $0.availability.isCompletable }
    }

    public static func attributes(for kind: ObjectKind) -> [ScriptLanguageAttribute] {
        AttributeRegistry.descriptors(for: kind).map(ScriptLanguageAttribute.init)
    }

    public static var eventDescriptors: [ScriptEventDescriptor] { EventDescriptorRegistry.all }

    public static func event(named name: String) -> ScriptEventDescriptor? {
        EventDescriptorRegistry.descriptor(named: name)
    }

    public static let snippets: [ScriptSnippetDescriptor] = [
        snippet("event.on", .events, "on(event, fn)", "on(\"load\", function(ev)\n  \nend)", "Subscribe this object; self, world, and player remain lexical locals."),
        snippet("event.subscribe", .events, "subscribe(target, event, fn)", "subscribe(self, \"attribute.changed\", function(ev)\n  \nend)", "Subscribe to an explicit target."),
        snippet("event.emit", .events, "emit(name, payload, target)", "emit(\"custom.event\", {}, self)", "Emit a custom event; target is the third argument."),
        snippet("event.register", .events, "register(name, fn)", "register(\"on_loaded\", function(ev)\n  \nend)", "Name a callback for timers or persisted subscriptions."),
        snippet("lifecycle.unload", .events, "register(\"unload\", fn)", "register(\"unload\", function()\n  self.attrs.last_state = \"stopped\"\nend)", "Install the synchronous no-ev unload finalizer. Only final custom-attribute writes are allowed."),
        snippet("event.object_on", .events, "self:on(event, fn)", "self:on(\"attribute.changed\", function(ev)\n  \nend)", "Subscribe this module to one object's event."),
        snippet("event.object_attribute", .events, "self:onAttribute(name, fn)", "self:onAttribute(\"state\", function(ev)\n  local new_value = ev.new\nend)", "React when one custom or observable built-in attribute changes."),
        snippet("event.declare", .events, "self:declareEvent(name, fields)", "self:declareEvent(\"machine.ready\", { item = \"string\", count = \"integer\" }, \"A machine finished its work\")", "Publish a typed, discoverable custom event contract on this object."),
        snippet("event.object_emit", .events, "self:emit(name, payload)", "self:emit(\"machine.ready\", { item = \"iron_ingot\", count = 1 })", "Emit a custom event on this object with declaration-aware payload checking."),

        snippet("control.if", .control, "if / then / end", "if condition then\n  \nend", "Conditional block."),
        snippet("control.if_else", .control, "if / else / end", "if condition then\n  \nelse\n  \nend", "Conditional block with an alternate branch."),
        snippet("control.for", .control, "for i = 1, n", "for i = 1, 10 do\n  \nend", "Numeric loop."),
        snippet("control.while", .control, "while", "while condition do\n  \nend", "Condition-controlled loop."),
        snippet("control.repeat", .control, "repeat / until", "repeat\n  \nuntil condition", "Post-condition loop."),
        snippet("control.function", .control, "function", "local function name(ev)\n  \nend", "Local function declaration."),

        snippet("object.get", .objects, "self:get(name)", "self:get(\"name\")", "Read a built-in or custom attribute."),
        snippet("object.set", .objects, "self:set(name, value)", "self:set(\"custom_state\", \"active\")", "Write a mutable built-in or custom attribute."),
        snippet("object.exists", .objects, "self:exists()", "self:exists()", "Test liveness."),
        snippet("object.scripts", .objects, "self:scripts()", "self:scripts()", "List attached scripts."),
        snippet("object.events", .objects, "self:events()", "self:events()", "List typed custom events declared by this object."),
        snippet("object.define", .objects, "self:define(name, value)", "self:define(\"custom_state\", \"active\")", "Define a custom attribute."),
        snippet("object.attach", .objects, "self:attach(name, source)", "self:attach(\"name\", \"return\")", "Attach module source; use opts.on for handler mode."),
        snippet("object.detach", .objects, "self:detach(name)", "self:detach(\"name\")", "Detach a script."),
        snippet("object.furnace_output", .objects, "self:setFurnaceOutput(item)", "self:setFurnaceOutput(\"iron_ingot\")", "Override this furnace's output while the attached script is live.", ownerKinds: [.block]),
        snippet("object.set_block", .objects, "self:setBlock(name)", "self:setBlock(\"stone\")", "Replace this block.", ownerKinds: [.block]),
        snippet("object.break_block", .objects, "self:breakBlock()", "self:breakBlock()", "Break this block naturally.", ownerKinds: [.block]),
        snippet("object.attrs", .objects, "self.attrs", "local attrs = self.attrs", "Access named custom attributes."),
        snippet("object.ref", .objects, "self.ref", "local object_ref = self.ref", "Canonical reference."),
        snippet("object.kind", .objects, "self.kind", "local object_kind = self.kind", "Object kind."),
        snippet("objects.get", .objects, "objects.get(ref)", "objects.get(\"player\")", "Resolve a live object handle."),
        snippet("objects.find", .objects, "objects.find{...}", "objects.find{kind = \"entity\", radius = 16, limit = 32}", "Find bounded nearby objects with an options table."),
        snippet("objects.block", .objects, "objects.block(dim, x, y, z)", "objects.block(\"overworld\", x, y, z)", "Create a block handle with an explicit dimension."),

        snippet("timing.wait", .timing, "wait(ticks)", "wait(20)", "Yield the current handler."),
        snippet("timing.every", .timing, "every(ticks, handlerName)", "register(\"on_interval\", function(ev)\n  \nend)\nevery(20, \"on_interval\")", "A named durable timer is the only repeating every form."),
        snippet("timing.after", .timing, "after(ticks, fn)", "after(20, function()\n  \nend)", "Schedule a live one-shot callback. Closure timers receive no arguments."),
        snippet("timing.tick", .timing, "tick()", "tick()", "Current world tick."),

        snippet("ai.ask", .ai, "ai.ask(prompt)", "ai.ask(\"describe the scene\")", "Queue a text-only model request."),
        snippet("ai.await", .ai, "ai.await(prompt)", "local reply, err = ai.await(\"describe the scene\")", "Yield for a text-only model reply."),

        snippet("misc.rng", .misc, "rng()", "rng()", "Draw from this script's deterministic random stream."),
        snippet("misc.say", .misc, "say(text)", "say(\"hello\")", "Show player-visible text."),
        snippet("misc.sound", .misc, "sound(...)", "sound(\"block.stone.break\")", "Accepted but currently a no-op."),
        snippet("misc.particles", .misc, "particles(...)", "particles(\"smoke\", x, y, z)", "Accepted but currently a no-op."),
        snippet("misc.dim", .misc, "dim(name)", "dim(\"overworld\")", "Resolve a dimension handle."),
    ]

    public static func snippetSections(for kind: ObjectKind) -> [ScriptSnippetSection] {
        var sections = ScriptSnippetCategory.allCases.filter { $0 != .attributes }.compactMap { category -> ScriptSnippetSection? in
            let items = snippets.filter { item in
                item.category == category && (item.ownerKinds == nil || item.ownerKinds?.contains(kind) == true)
            }
            return items.isEmpty ? nil : ScriptSnippetSection(category: category, items: items)
        }
        let attributeItems = attributes(for: kind).flatMap { attribute -> [ScriptSnippetDescriptor] in
            var items = [snippet(
                "attribute.get.\(kind.rawValue).\(attribute.name)", .attributes, "get \(attribute.name)",
                "self:get(\"\(attribute.name)\")", "Read \(attribute.summary)"
            )]
            if attribute.mutability == .getSet {
                items.append(snippet(
                    "attribute.set.\(kind.rawValue).\(attribute.name)", .attributes, "set \(attribute.name)",
                    "self:set(\"\(attribute.name)\", value)", "Write \(attribute.summary)"
                ))
            }
            return items
        }
        sections.append(ScriptSnippetSection(category: .attributes, items: attributeItems))
        return sections
    }

    /// A deterministic, tooling-only LuaCATS definition document generated from this schema.
    /// `---@meta` tells LuaLS it describes an external API; Elysium never loads or executes it.
    public static var luaCATSDefinitions: String {
        var lines = [
            "---@meta",
            "",
            "---@alias ElysiumObjectKind \"world\"|\"dim\"|\"block\"|\"entity\"|\"player\"",
            "---@class ElysiumEvent",
            "---@field kind string",
            "---@field tick integer",
            "---@field subject ElysiumObject",
            "---@field source string",
            "---@class ElysiumAttributes",
            "---@class ElysiumObject",
        ]
        for property in handleProperties {
            lines.append("---@field \(property.name) \(luaCATSName(property.valueType)) \(property.summary)")
        }
        for method in handleMethods {
            lines.append(contentsOf: luaCATSFunctionLines(method, name: "ElysiumObject:\(method.name)"))
        }

        // The editor AI receives a bounded prefix of this document. Keep executable Elysium
        // globals and modules ahead of the much longer per-kind attribute/event catalog.
        lines.append("")
        for symbol in engineGlobals {
            lines.append(contentsOf: luaCATSFunctionLines(symbol, name: symbol.name))
        }
        for module in ["objects", "ai"] {
            lines.append("")
            lines.append("---@class Elysium\(module.capitalized)Module")
            lines.append("\(module) = {}")
            for member in engineModuleMembers.filter({ $0.parent == module }) {
                lines.append(contentsOf: luaCATSFunctionLines(member, name: "\(module).\(member.name)"))
            }
        }
        lines.append("")
        lines.append("---@type ElysiumObject")
        lines.append("self = nil")
        lines.append("---@type ElysiumObject")
        lines.append("world = nil")
        lines.append("---@type ElysiumObject")
        lines.append("player = nil")
        lines.append("---@type ElysiumEvent")
        lines.append("ev = nil")

        for kind in ObjectKind.allCases {
            lines.append("")
            lines.append("---@class \(luaCATSClassName(for: kind)): ElysiumObject")
            for attribute in attributes(for: kind) {
                if !attribute.dotAccessNames.isEmpty {
                    for spelling in attribute.dotAccessNames {
                        let aliasNote = spelling == attribute.name ? "" : " Runtime camelCase alias."
                        lines.append("---@field \(spelling) \(luaCATSName(attribute.type)) \(attribute.summary)\(aliasNote)")
                    }
                } else {
                    lines.append("---Use h:get(\"\(attribute.name)\") for \(attribute.summary)")
                }
            }
        }
        for event in eventDescriptors {
            lines.append("")
            lines.append("---@class \(luaCATSEventClassName(event.kind)): ElysiumEvent")
            for field in event.payload {
                let nullable = field.isNullable ? "|nil" : ""
                lines.append("---@field \(field.name) \(luaCATSName(field.type))\(nullable) \(field.summary)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func luaCATSFunctionLines(
        _ symbol: ScriptLanguageSymbol, name: String
    ) -> [String] {
        guard let primary = symbol.signatures.first else {
            return ["---\(symbol.summary)", "function \(name)(...) end"]
        }
        var lines = ["---\(symbol.summary)"]
        for overload in symbol.signatures.dropFirst() {
            let parameters = overload.parameters.map { parameter in
                let type = luaCATSName(parameter.type)
                let optional = parameter.isOptional ? "?" : ""
                return parameter.isVariadic ? "...: \(type)" : "\(parameter.name)\(optional): \(type)"
            }.joined(separator: ", ")
            let returns = overload.returns.map {
                luaCATSName($0.type) + ($0.isNullable ? "|nil" : "")
            }
            let suffix = returns.isEmpty ? "" : ": " + returns.joined(separator: ", ")
            lines.append("---@overload fun(\(parameters))\(suffix)")
        }
        for parameter in primary.parameters {
            let parameterName = parameter.isVariadic ? "..." : parameter.name
            let optional = parameter.isOptional ? "?" : ""
            lines.append("---@param \(parameterName)\(optional) \(luaCATSName(parameter.type))")
        }
        for value in primary.returns {
            let nullable = value.isNullable ? "|nil" : ""
            let summary = value.summary.isEmpty ? "" : " \(value.summary)"
            lines.append("---@return \(luaCATSName(value.type))\(nullable)\(summary)")
        }
        let parameters = primary.parameters.map { $0.isVariadic ? "..." : $0.name }
            .joined(separator: ", ")
        lines.append("function \(name)(\(parameters)) end")
        return lines
    }

    private static let allObjectKinds = Set(ObjectKind.allCases)

    private static func p(
        _ name: String, _ type: ScriptLanguageValueType, optional: Bool = false, variadic: Bool = false
    ) -> ScriptParameterDescriptor {
        ScriptParameterDescriptor(name: name, type: type, isOptional: optional, isVariadic: variadic)
    }

    private static func r(
        _ type: ScriptLanguageValueType, _ summary: String = "", nullable: Bool = false
    ) -> ScriptReturnDescriptor {
        ScriptReturnDescriptor(type: type, isNullable: nullable, summary: summary)
    }

    private static func signature(
        _ label: String,
        _ parameters: [ScriptParameterDescriptor] = [],
        returns: [ScriptReturnDescriptor] = [],
        isYielding: Bool = false
    ) -> ScriptCallableSignature {
        ScriptCallableSignature(
            label: label, parameters: parameters, returns: returns, isYielding: isYielding
        )
    }

    private static func function(
        _ kind: ScriptLanguageSymbolKind,
        _ name: String,
        parent: String? = nil,
        signatures: [ScriptCallableSignature],
        availability: ScriptLanguageAvailability = .available,
        summary: String
    ) -> ScriptLanguageSymbol {
        ScriptLanguageSymbol(
            kind: kind, parent: parent, name: name, signatures: signatures, valueType: .function,
            availability: availability, summary: summary
        )
    }

    private static func function(
        _ kind: ScriptLanguageSymbolKind,
        _ name: String,
        parent: String? = nil,
        labels: [String],
        returns: [ScriptLanguageValueType] = [],
        summary: String
    ) -> ScriptLanguageSymbol {
        function(
            kind, name, parent: parent,
            signatures: labels.map {
                signature($0, parametersFromLabel($0), returns: returns.map { r($0) })
            },
            summary: summary
        )
    }

    private static func value(
        _ kind: ScriptLanguageSymbolKind,
        _ name: String,
        _ type: ScriptLanguageValueType,
        _ summary: String,
        parent: String? = nil
    ) -> ScriptLanguageSymbol {
        ScriptLanguageSymbol(kind: kind, parent: parent, name: name, valueType: type, summary: summary)
    }

    private static func property(
        _ name: String, _ type: ScriptLanguageValueType, _ mutability: Mutability, _ summary: String
    ) -> ScriptLanguageSymbol {
        ScriptLanguageSymbol(
            kind: .handleProperty, parent: "handle", name: name, valueType: type,
            receiverKinds: allObjectKinds, mutability: mutability, summary: summary
        )
    }

    private static func method(
        _ name: String,
        signatures: [ScriptCallableSignature],
        receiverKinds: Set<ObjectKind>? = nil,
        summary: String
    ) -> ScriptLanguageSymbol {
        ScriptLanguageSymbol(
            kind: .handleMethod, parent: "handle", name: name,
            signatures: signatures, valueType: .function,
            receiverKinds: receiverKinds ?? allObjectKinds, summary: summary
        )
    }

    private static func library(
        _ parent: String,
        functions: [(String, String)],
        returnType: ScriptLanguageValueType,
        returnOverrides: [String: [ScriptLanguageValueType]] = [:],
        summary: String
    ) -> [ScriptLanguageSymbol] {
        functions.map { name, label in
            function(
                .moduleFunction, name, parent: parent, labels: [label],
                returns: returnOverrides[name] ?? [returnType], summary: summary
            )
        }
    }

    /// Recover parameter names/counts from the compact human-readable Lua signatures used for
    /// the standard library. Types remain `any`, but active-parameter help is then useful instead
    /// of every standard-library call looking like a zero-argument function.
    private static func parametersFromLabel(_ label: String) -> [ScriptParameterDescriptor] {
        guard let open = label.firstIndex(of: "("), let close = label.lastIndex(of: ")"), open < close else {
            return []
        }
        let body = label[label.index(after: open)..<close]
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var optionalDepth = 0
        var segment = ""
        var segmentWasOptional = false
        var rawParameters: [(String, Bool)] = []
        func appendSegment() {
            let cleaned = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { rawParameters.append((cleaned, segmentWasOptional)) }
            segment = ""
            segmentWasOptional = optionalDepth > 0
        }
        for character in body {
            if character == "[" { optionalDepth += 1; segmentWasOptional = true; continue }
            if character == "]" { optionalDepth = max(0, optionalDepth - 1); continue }
            if character == "," { appendSegment(); continue }
            if optionalDepth > 0 { segmentWasOptional = true }
            segment.append(character)
        }
        appendSegment()
        return rawParameters.enumerated().map { index, raw in
            let variadic = raw.0.contains("...")
            var name = raw.0
                .replacingOccurrences(of: "...", with: "")
                .replacingOccurrences(of: " ", with: "_")
            if name.isEmpty { name = "arguments" }
            if name.contains("=") { name = String(name.prefix { $0 != "=" }) }
            if !name.utf8.allSatisfy({ byte in
                (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
                    || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || byte == UInt8(ascii: "_")
            }) {
                name = "argument\(index + 1)"
            }
            return p(name, .any, optional: raw.1, variadic: variadic)
        }
    }

    private static func snippet(
        _ id: String,
        _ category: ScriptSnippetCategory,
        _ name: String,
        _ code: String,
        _ summary: String,
        ownerKinds: Set<ObjectKind>? = nil
    ) -> ScriptSnippetDescriptor {
        ScriptSnippetDescriptor(
            id: id, category: category, name: name, code: code, summary: summary, ownerKinds: ownerKinds
        )
    }

    private static func luaCATSName(_ type: ScriptLanguageValueType) -> String {
        switch type {
        case .boolean: return "boolean"
        case .integer: return "integer"
        case .number: return "number"
        case .string: return "string"
        case .function: return "function"
        case .table, .map: return "table"
        case .objectHandle: return "ElysiumObject"
        case .attributeProxy: return "ElysiumAttributes"
        case .event: return "ElysiumEvent"
        case .item: return "ElysiumItem"
        case .effectList, .list: return "table"
        case .enumeration(let values): return values.map { "\"\($0)\"" }.joined(separator: "|")
        case .any: return "any"
        }
    }

    private static func luaCATSClassName(for kind: ObjectKind) -> String {
        switch kind {
        case .world: return "ElysiumWorld"
        case .dim: return "ElysiumDimension"
        case .block: return "ElysiumBlock"
        case .entity: return "ElysiumEntity"
        case .player: return "ElysiumPlayer"
        }
    }

    private static func luaCATSEventClassName(_ kind: EventKind) -> String {
        let suffix = kind.rawValue.map { character in
            character.isLetter || character.isNumber ? character : "_"
        }
        return "ElysiumEvent_" + String(suffix)
    }
}
