// LuaLanguageTypes.swift — immutable models shared by the native Lua editor, its
// deterministic language service, and the optional AI-completion presentation layer. None of
// these types execute Lua or mutate game state.

import Foundation
import ElysiumCore

enum LuaCompletionItemKind: String, CaseIterable, Sendable {
    case keyword
    case variable
    case parameter
    case function
    case module
    case method
    case property
    case attribute
    case event
    case field
    case value

    var accessibilityName: String {
        switch self {
        case .keyword: "keyword"
        case .variable: "variable"
        case .parameter: "parameter"
        case .function: "function"
        case .module: "module"
        case .method: "method"
        case .property: "property"
        case .attribute: "attribute"
        case .event: "event"
        case .field: "field"
        case .value: "value"
        }
    }

    var systemImageName: String {
        switch self {
        case .keyword: "textformat"
        case .variable: "v.square"
        case .parameter: "p.square"
        case .function: "function"
        case .module: "shippingbox"
        case .method: "m.square"
        case .property: "slider.horizontal.3"
        case .attribute: "tag"
        case .event: "bolt"
        case .field: "rectangle.split.3x1"
        case .value: "equal.square"
        }
    }
}

enum LuaCompletionItemSource: String, Sendable {
    case local
    case language
    case elysium
    case liveObject
}

struct LuaCompletionItem: Equatable, Sendable, Identifiable {
    let label: String
    let insertionText: String
    let kind: LuaCompletionItemKind
    let detail: String
    let documentation: String
    let source: LuaCompletionItemSource
    let isReadOnly: Bool
    let sortPriority: Int

    var id: String {
        "\(source.rawValue):\(kind.rawValue):\(label):\(insertionText)"
    }

    var accessibilityLabel: String {
        var parts = [label, kind.accessibilityName]
        if !detail.isEmpty { parts.append(detail) }
        if isReadOnly { parts.append("read only") }
        return parts.joined(separator: ", ")
    }
}

/// Live custom attributes are supplied by the editor model. Keeping this snapshot as pure data
/// prevents completion from reaching into `GameCore` or crossing the script executor boundary.
struct LuaCustomAttributeCompletion: Equatable, Sendable {
    let name: String
    let typeName: String
    let isReadOnly: Bool
    let summary: String

    init(name: String, typeName: String = "value", isReadOnly: Bool = false, summary: String = "Custom object attribute") {
        self.name = name
        self.typeName = typeName
        self.isReadOnly = isReadOnly
        self.summary = summary
    }
}

struct LuaObjectReferenceCompletion: Equatable, Sendable {
    let canonicalRef: String
    let displayName: String
    let kind: ObjectKind
    let isLive: Bool
    /// Custom attributes captured with this exact nearby-object snapshot. This lets a binding such
    /// as `local door = objects.get("block:...")` offer `door.attrs.<name>` without pretending the
    /// same names apply to every block in the world.
    let customAttributes: [LuaCustomAttributeCompletion]

    init(
        canonicalRef: String, displayName: String, kind: ObjectKind, isLive: Bool = true,
        customAttributes: [LuaCustomAttributeCompletion] = []
    ) {
        self.canonicalRef = canonicalRef
        self.displayName = displayName
        self.kind = kind
        self.isLive = isLive
        self.customAttributes = customAttributes
    }
}

struct LuaLanguageEnvironment: Equatable, Sendable {
    var targetKind: ObjectKind
    var targetCanonicalRef: String?
    /// Canonical built-in names proven applicable to the current live target. `nil` means the
    /// editor has no authoritative per-object snapshot (for example a LAN guest).
    var targetApplicableBuiltInAttributes: Set<String>?
    var targetCustomAttributes: [LuaCustomAttributeCompletion]
    var objectReferences: [LuaObjectReferenceCompletion]
    var scriptMode: ScriptMode
    var handlerEvent: String?
    var eventCandidates: [ScriptEditorEventCandidate]
    var isYieldable: Bool

    init(
        targetKind: ObjectKind,
        targetCanonicalRef: String? = nil,
        targetApplicableBuiltInAttributes: Set<String>? = nil,
        targetCustomAttributes: [LuaCustomAttributeCompletion] = [],
        objectReferences: [LuaObjectReferenceCompletion] = [],
        scriptMode: ScriptMode = .module,
        handlerEvent: String? = nil,
        eventCandidates: [ScriptEditorEventCandidate]? = nil,
        isYieldable: Bool = true
    ) {
        self.targetKind = targetKind
        self.targetCanonicalRef = targetCanonicalRef
        self.targetApplicableBuiltInAttributes = targetApplicableBuiltInAttributes
        self.targetCustomAttributes = targetCustomAttributes
        self.objectReferences = objectReferences
        self.scriptMode = scriptMode
        self.handlerEvent = handlerEvent
        self.eventCandidates = eventCandidates
            ?? ScriptEditorEventCatalog.candidates(targetKind: targetKind)
        self.isYieldable = isYieldable
    }
}

indirect enum LuaInferredType: Equatable, Sendable {
    case unknown
    case nilValue
    case boolean
    case integer
    case number
    case string
    case function(signature: String)
    case module(String)
    case object(ObjectKind?)
    case exactObject(ObjectKind?, canonicalRef: String)
    case attributes(ObjectKind?)
    case exactAttributes(ObjectKind?, canonicalRef: String)
    case event(String?)
    case table([String: LuaInferredType])
    case list(LuaInferredType)

    var displayName: String {
        switch self {
        case .unknown: "unknown"
        case .nilValue: "nil"
        case .boolean: "boolean"
        case .integer: "integer"
        case .number: "number"
        case .string: "string"
        case .function(let signature): signature
        case .module(let name): "\(name) module"
        case .object(let kind), .exactObject(let kind, _):
            kind.map { "\($0.rawValue) handle" } ?? "object handle"
        case .attributes(let kind), .exactAttributes(let kind, _):
            kind.map { "\($0.rawValue) attributes" } ?? "custom attributes"
        case .event(let name): name.map { "\($0) event" } ?? "event"
        case .table: "table"
        case .list(let element): "list<\(element.displayName)>"
        }
    }
}

enum LuaLanguageSymbolKind: String, Sendable {
    case variable
    case parameter
    case function
}

struct LuaLanguageSymbol: Equatable, Sendable {
    let name: String
    let kind: LuaLanguageSymbolKind
    let type: LuaInferredType
    let declarationRange: NSRange
}

enum LuaSemanticRole: Equatable, Sendable {
    case declaration
    case variable
    case parameter
    case function
    case engineGlobal
    case module
    case method
    case property
    case attribute(readOnly: Bool)
    case eventName
    case eventField
    case unavailable
}

struct LuaSemanticToken: Equatable, Sendable {
    let role: LuaSemanticRole
    let range: NSRange
}

enum LuaDiagnosticSeverity: String, Sendable {
    case information
    case warning
    case error
}

struct LuaQuickFix: Equatable, Sendable {
    let title: String
    let replacementRange: NSRange
    let replacementText: String
}

/// One model-originated source replacement that the AppKit editor should perform through
/// `NSTextView.insertText` so palette, quick-fix, object, and AI-panel actions participate in the
/// native undo manager instead of replacing the text storage wholesale.
struct LuaEditorExternalEdit: Equatable, Sendable {
    let id: UInt64
    let replacementRange: NSRange
    let replacementText: String
}

struct LuaDiagnostic: Equatable, Sendable, Identifiable {
    let id: String
    let severity: LuaDiagnosticSeverity
    let message: String
    let range: NSRange
    let quickFixes: [LuaQuickFix]
}

struct LuaSignatureHelp: Equatable, Sendable {
    let label: String
    let documentation: String
    let activeParameter: Int
}

struct LuaLanguageAnalysis: Equatable, Sendable {
    let semanticTokens: [LuaSemanticToken]
    let symbols: [LuaLanguageSymbol]
    let diagnostics: [LuaDiagnostic]
}

enum LuaMemberAccess: Equatable, Sendable {
    case dot
    case colon
}

enum LuaCompletionContext: Equatable, Sendable {
    case members(receiver: String, access: LuaMemberAccess)
    case eventName
    case objectReference
    case keywordsAndGlobals
}

struct LuaCompletionResult: Equatable, Sendable {
    let context: LuaCompletionContext
    let prefix: String
    let replacementRange: NSRange
    let items: [LuaCompletionItem]
}
