// CustomEventDeclaration.swift — persistent, object-scoped authoring metadata
// for open custom EventKind values. Declarations describe payloads for tools
// such as the Lua editor and dry-run validator; they do not authorize, enqueue,
// or otherwise change EventBus routing.

import Foundation
import ElysiumScript

/// The persisted value shapes a custom-event payload field may advertise.
/// Keep this list aligned with values that can cross the ScriptValue boundary.
public enum CustomEventFieldType: String, CaseIterable, Sendable, Equatable {
    case any
    case boolean
    case integer
    case number
    case string
    case object
    case list
    case map

    public var languageType: ScriptLanguageValueType {
        switch self {
        case .any: return .any
        case .boolean: return .boolean
        case .integer: return .integer
        case .number: return .number
        case .string: return .string
        case .object: return .objectHandle
        case .list: return .list
        case .map: return .map
        }
    }
}

public struct CustomEventField: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let type: CustomEventFieldType
    public let isNullable: Bool

    public init(name: String, type: CustomEventFieldType, isNullable: Bool = false) {
        self.name = name
        self.type = type
        self.isNullable = isNullable
    }

    /// Canonical persisted/Lua spelling, for example `string?`.
    public var typeToken: String { type.rawValue + (isNullable ? "?" : "") }

    public init?(name: String, typeToken: String) {
        let nullable = typeToken.hasSuffix("?")
        let raw = nullable ? String(typeToken.dropLast()) : typeToken
        guard let type = CustomEventFieldType(rawValue: raw) else { return nil }
        self.init(name: name, type: type, isNullable: nullable)
    }
}

public struct CustomEventDeclaration: Sendable, Equatable, Identifiable {
    public var id: String { kind.rawValue }
    public let kind: EventKind
    /// Always stored in UTF-8 byte order by `CustomEventStore` and the codec.
    public let fields: [CustomEventField]
    public let summary: String?
    public let provenance: Provenance

    public init(
        kind: EventKind, fields: [CustomEventField], summary: String? = nil,
        provenance: Provenance
    ) {
        self.kind = kind
        self.fields = fields.sorted { utf8Less($0.name, $1.name) }
        self.summary = summary
        self.provenance = provenance
    }

    /// Idempotent redeclaration compares the declared contract, not who first
    /// wrote it or when. Provenance changes only when the contract changes.
    func hasSameContract(fields: [CustomEventField], summary: String?) -> Bool {
        self.fields == fields.sorted { utf8Less($0.name, $1.name) } && self.summary == summary
    }
}

enum CustomEventDeclarationValidationError: Error, Equatable {
    case invalidEventName
    case builtInEventName
    case tooManyFields(limit: Int)
    case invalidFieldName(String)
    case reservedFieldName(String)
    case duplicateFieldName(String)
    case summaryTooLarge(limit: Int)
    case invalidSummary
}

private let customEventEnvelopeFieldNames: Set<String> = ["kind", "subject", "tick", "source"]

func validateCustomEventDeclaration(
    name: String, fields: [CustomEventField], summary: String?, caps: ScriptingStorageCaps
) -> Result<(kind: EventKind, fields: [CustomEventField]), CustomEventDeclarationValidationError> {
    guard let kind = EventKind.parse(name) else { return .failure(.invalidEventName) }
    guard EventDescriptorRegistry.descriptor(for: kind) == nil else { return .failure(.builtInEventName) }
    guard fields.count <= caps.maxEventFieldsPerDeclaration else {
        return .failure(.tooManyFields(limit: caps.maxEventFieldsPerDeclaration))
    }
    var seen = Set<String>()
    let canonicalFields = fields.sorted { utf8Less($0.name, $1.name) }
    for field in canonicalFields {
        guard isValidAttributeName(field.name) else { return .failure(.invalidFieldName(field.name)) }
        guard !customEventEnvelopeFieldNames.contains(field.name) else {
            return .failure(.reservedFieldName(field.name))
        }
        guard seen.insert(field.name).inserted else { return .failure(.duplicateFieldName(field.name)) }
    }
    if let summary {
        guard summary.utf8.count <= caps.maxEventSummaryBytes else {
            return .failure(.summaryTooLarge(limit: caps.maxEventSummaryBytes))
        }
        guard !summary.isEmpty, ScriptTextHygiene.isClean(summary) else { return .failure(.invalidSummary) }
    }
    return .success((kind, canonicalFields))
}

public extension EventDescriptorRegistry {
    /// Resolves built-ins globally and custom declarations only in the supplied
    /// object's record. No mutable/global declaration registry is involved.
    static func descriptor(
        for kind: EventKind, declaredOn owner: ObjectRef, in record: ObjectRecord
    ) -> ScriptEventDescriptor? {
        if let builtIn = descriptor(for: kind) { return builtIn }
        guard let declaration = record.eventDeclarations[kind.rawValue], declaration.kind == kind else {
            return nil
        }
        return ScriptEventDescriptor(
            kind: kind,
            subjectKinds: [owner.kind],
            payload: declaration.fields.map { field in
                ScriptEventFieldDescriptor(
                    name: field.name, type: field.type.languageType,
                    isNullable: field.isNullable,
                    summary: "Custom event payload field declared on \(owner.canonical)."
                )
            },
            summary: declaration.summary ?? "Custom event declared on \(owner.canonical)."
        )
    }

    /// Built-ins retain their frozen order; object-scoped declarations follow
    /// in canonical UTF-8 name order. Malformed built-in shadows are ignored.
    static func descriptors(declaredOn owner: ObjectRef, in record: ObjectRecord) -> [ScriptEventDescriptor] {
        let custom = record.eventDeclarations.keys.sorted(by: utf8Less).compactMap { name -> ScriptEventDescriptor? in
            guard let kind = EventKind.parse(name), descriptor(for: kind) == nil else { return nil }
            return descriptor(for: kind, declaredOn: owner, in: record)
        }
        return all + custom
    }
}
