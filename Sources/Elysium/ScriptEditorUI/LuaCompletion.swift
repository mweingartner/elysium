// LuaCompletion.swift — deterministic completion catalog adapter and ranking. All shipped API
// entries come from `ScriptLanguageSchema`; this file contributes only document-local symbols and
// live editor snapshots, so completion cannot drift from the runtime authoring contract.

import Foundation
import ElysiumCore

struct LuaCatalogSignature: Equatable, Sendable {
    let label: String
    let documentation: String
    let parameterCount: Int
}

enum LuaCompletion {
    static var globalItems: [LuaCompletionItem] {
        ScriptLanguageSchema.allSymbols.filter { symbol in
            symbol.parent == nil
                && symbol.kind != .handleMethod
                && symbol.kind != .handleProperty
                && symbol.kind != .unsupported
                && symbol.availability.isCompletable
        }.map(item(for:))
    }

    static func memberItems(
        receiver: LuaInferredType,
        access: LuaMemberAccess,
        receiverText: String,
        environment: LuaLanguageEnvironment,
        isCurrentTargetReceiver: Bool = false
    ) -> [LuaCompletionItem] {
        switch (receiver, access) {
        case (.module(let module), .dot):
            return ScriptLanguageSchema.moduleMembers(named: module).map(item(for:))

        case (.object(let kind), .colon):
            return ScriptLanguageSchema.handleMethods
                .filter { kind.map($0.receiverKinds.contains) ?? true }
                .map(item(for:))

        case (.exactObject(let kind, _), .colon):
            return ScriptLanguageSchema.handleMethods
                .filter { kind.map($0.receiverKinds.contains) ?? true }
                .map(item(for:))

        case (.object(let kind), .dot):
            var result = ScriptLanguageSchema.handleProperties.map(item(for:))
            if let kind {
                let attributes = ScriptLanguageSchema.attributes(for: kind).filter { attribute in
                    guard !attribute.dotAccessNames.isEmpty else { return false }
                    guard isCurrentTargetReceiver,
                          let applicable = environment.targetApplicableBuiltInAttributes else {
                        return true
                    }
                    return applicable.contains(attribute.name)
                }
                result.append(contentsOf: attributes.flatMap { attribute in
                    attribute.dotAccessNames.map { spelling in
                        item(
                            for: attribute,
                            spelling: spelling,
                            applicabilityIsCertain: isCurrentTargetReceiver
                                && environment.targetApplicableBuiltInAttributes != nil
                        )
                    }
                })
            }
            return result

        case (.exactObject(let kind, let canonicalRef), .dot):
            var result = ScriptLanguageSchema.handleProperties.map(item(for:))
            if let kind {
                let isExactTarget = canonicalRef == environment.targetCanonicalRef
                let attributes = ScriptLanguageSchema.attributes(for: kind).filter { attribute in
                    guard !attribute.dotAccessNames.isEmpty else { return false }
                    guard isExactTarget,
                          let applicable = environment.targetApplicableBuiltInAttributes else {
                        return true
                    }
                    return applicable.contains(attribute.name)
                }
                result.append(contentsOf: attributes.flatMap { attribute in
                    attribute.dotAccessNames.map { spelling in
                        item(
                            for: attribute,
                            spelling: spelling,
                            applicabilityIsCertain: isExactTarget
                                && environment.targetApplicableBuiltInAttributes != nil
                        )
                    }
                })
            }
            return result

        case (.attributes(let kind), .dot):
            // The current editor owns only the target object's live snapshot. Do not pretend those
            // custom names apply to a different same-kind handle.
            let compactReceiver = receiverText.replacingOccurrences(of: " ", with: "")
            guard kind == environment.targetKind, compactReceiver == "self.attrs" else { return [] }
            return customAttributeItems(environment.targetCustomAttributes)

        case (.exactAttributes(_, let canonicalRef), .dot):
            let attributes: [LuaCustomAttributeCompletion]
            if canonicalRef == environment.targetCanonicalRef {
                attributes = environment.targetCustomAttributes
            } else {
                attributes = environment.objectReferences.first {
                    $0.canonicalRef == canonicalRef && $0.isLive
                }?.customAttributes ?? []
            }
            return customAttributeItems(attributes)

        case (.event(let eventName), .dot):
            return eventFieldItems(eventName: eventName, environment: environment)

        case (.table(let fields), .dot):
            return fields.keys.sorted().map { name in
                LuaCompletionItem(
                    label: name,
                    insertionText: name,
                    kind: .field,
                    detail: fields[name]?.displayName ?? "unknown",
                    documentation: "Field inferred from this document's table literal.",
                    source: .local,
                    isReadOnly: false,
                    sortPriority: 0
                )
            }

        default:
            return []
        }
    }

    static func eventItems(
        quoted: Bool, candidates: [ScriptEditorEventCandidate]
    ) -> [LuaCompletionItem] {
        candidates.map { event in
            LuaCompletionItem(
                label: event.name,
                insertionText: quoted ? event.name : "\"\(event.name)\"",
                kind: .event,
                detail: event.detail,
                documentation: event.summary,
                source: event.source == .builtIn ? .elysium : .liveObject,
                isReadOnly: true,
                sortPriority: 0
            )
        }
    }

    static func objectReferenceItems(
        references: [LuaObjectReferenceCompletion], quoted: Bool, asHandleLookup: Bool = false
    ) -> [LuaCompletionItem] {
        references.filter(\.isLive).enumerated().map { index, object in
            return LuaCompletionItem(
                label: object.canonicalRef,
                insertionText: asHandleLookup
                    ? "objects.get(\"\(object.canonicalRef)\")"
                    : (quoted ? object.canonicalRef : "\"\(object.canonicalRef)\""),
                kind: .value,
                detail: "\(object.kind.rawValue) • \(object.displayName) • live",
                documentation: "Canonical \(object.kind.rawValue) reference for \(object.displayName).",
                source: .liveObject,
                isReadOnly: true,
                // The model supplies target/crosshair/distance/canonical order. Preserve it while
                // still placing stale handles behind every live handle.
                sortPriority: index
            )
        }
    }

    static func signature(for callee: String, activeParameter: Int = 0) -> LuaCatalogSignature? {
        let normalized: (parent: String?, name: String)
        if let separator = callee.lastIndex(where: { $0 == "." || $0 == ":" }) {
            let parent = String(callee[..<separator])
            let normalizedParent = callee[separator] == ":"
                ? "handle"
                : (["self", "world", "player"].contains(parent) ? "handle" : parent)
            normalized = (normalizedParent, String(callee[callee.index(after: separator)...]))
        } else {
            normalized = (nil, callee)
        }
        guard let symbol = ScriptLanguageSchema.symbol(named: normalized.name, parent: normalized.parent),
              !symbol.signatures.isEmpty else { return nil }
        let signature = symbol.signatures.first(where: { $0.parameters.count > activeParameter })
            ?? symbol.signatures.max { $0.parameters.count < $1.parameters.count }
            ?? symbol.signatures[0]
        return LuaCatalogSignature(
            label: signature.label,
            documentation: documentation(for: symbol, signature: signature),
            parameterCount: signature.parameters.count
        )
    }

    static func returnType(moduleOrReceiver: String, member: String) -> LuaInferredType {
        guard let symbol = ScriptLanguageSchema.symbol(named: member, parent: moduleOrReceiver) else { return .unknown }
        return inferredType(symbol.signatures.first?.returns.first?.type ?? symbol.valueType)
    }

    static func returnType(
        forHandleMember member: String, kind: ObjectKind?, canonicalRef: String? = nil
    ) -> LuaInferredType {
        if let property = ScriptLanguageSchema.handleProperties.first(where: { $0.name == member }) {
            if property.name == "attrs" {
                return canonicalRef.map { .exactAttributes(kind, canonicalRef: $0) }
                    ?? .attributes(kind)
            }
            return inferredType(property.valueType)
        }
        if let kind, let attribute = ScriptLanguageSchema.attributes(for: kind).first(where: {
            $0.name == member || $0.aliases.contains(member)
        }) {
            return inferredType(attribute.type)
        }
        return .unknown
    }

    static func typeOfEventField(
        _ field: String,
        eventName: String? = nil,
        environment: LuaLanguageEnvironment? = nil
    ) -> LuaInferredType {
        switch field {
        case "kind", "source": return .string
        case "tick": return .integer
        case "subject": return .object(nil)
        default:
            let contextualDescriptor = environment?.eventCandidates
                .first(where: { $0.name == eventName })?.payload
                .first(where: { $0.name == field })
            let staticDescriptor = eventName.flatMap { name in
                ScriptLanguageSchema.event(named: name)?.payload.first(where: { $0.name == field })
            }
            if let fieldDescriptor = contextualDescriptor ?? staticDescriptor {
                return inferredType(fieldDescriptor.type)
            }
            return .unknown
        }
    }

    /// Fuzzy ranking is deterministic: local/catalog priority, then exact/prefix/word-boundary/
    /// subsequence quality, then case-insensitive label and stable identity.
    static func rank(items: [LuaCompletionItem], prefix: String, limit: Int = 50) -> [LuaCompletionItem] {
        var unique: [String: LuaCompletionItem] = [:]
        for item in items {
            if let current = unique[item.label], current.sortPriority <= item.sortPriority { continue }
            unique[item.label] = item
        }
        let scored = unique.values.compactMap { item -> (LuaCompletionItem, Int)? in
            guard let match = matchScore(label: item.label, prefix: prefix) else { return nil }
            return (item, item.sortPriority * 100 + match)
        }
        return scored.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
            let compare = lhs.0.label.localizedCaseInsensitiveCompare(rhs.0.label)
            if compare != .orderedSame { return compare == .orderedAscending }
            return lhs.0.id < rhs.0.id
        }.prefix(limit).map(\.0)
    }

    private static func matchScore(label: String, prefix: String) -> Int? {
        guard !prefix.isEmpty else { return 0 }
        let lowerLabel = label.lowercased()
        let lowerPrefix = prefix.lowercased()
        if label == prefix { return 0 }
        if lowerLabel == lowerPrefix { return 1 }
        if label.hasPrefix(prefix) { return 2 }
        if lowerLabel.hasPrefix(lowerPrefix) { return 3 }
        if wordInitials(label).lowercased().hasPrefix(lowerPrefix) { return 5 }
        if lowerLabel.contains(lowerPrefix) { return 8 }
        if isSubsequence(lowerPrefix, of: lowerLabel) { return 12 }
        return nil
    }

    private static func wordInitials(_ text: String) -> String {
        var result = ""
        var previousWasSeparator = true
        var previousWasLowercase = false
        for character in text {
            if character == "_" || character == "." || character == "-" {
                previousWasSeparator = true
                previousWasLowercase = false
                continue
            }
            if previousWasSeparator || (character.isUppercase && previousWasLowercase) { result.append(character) }
            previousWasSeparator = false
            previousWasLowercase = character.isLowercase
        }
        return result
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var iterator = haystack.makeIterator()
        for character in needle {
            var matched = false
            while let candidate = iterator.next() {
                if candidate == character { matched = true; break }
            }
            if !matched { return false }
        }
        return true
    }

    private static func item(for symbol: ScriptLanguageSymbol) -> LuaCompletionItem {
        let kind: LuaCompletionItemKind
        switch symbol.kind {
        case .keyword: kind = .keyword
        case .implicitLocal: kind = .variable
        case .globalFunction, .moduleFunction: kind = .function
        case .globalValue, .moduleValue: kind = .value
        case .module: kind = .module
        case .handleMethod: kind = .method
        case .handleProperty: kind = .property
        case .unsupported: kind = .function
        }
        let detail = symbol.signatures.first?.label ?? symbol.valueType.displayName
        let source: LuaCompletionItemSource =
            symbol.kind == .keyword || symbol.kind == .globalValue ? .language : .elysium
        return LuaCompletionItem(
            label: symbol.name,
            insertionText: symbol.insertionText,
            kind: kind,
            detail: detail,
            documentation: documentation(for: symbol, signature: symbol.signatures.first),
            source: source,
            isReadOnly: symbol.mutability == .readOnly,
            sortPriority: {
                switch symbol.kind {
                case .handleProperty, .handleMethod: return 0
                case .implicitLocal: return 1
                case .keyword: return 8
                default: return 4
                }
            }()
        )
    }

    private static func item(
        for attribute: ScriptLanguageAttribute,
        spelling: String? = nil,
        applicabilityIsCertain: Bool = false
    ) -> LuaCompletionItem {
        let spelling = spelling ?? attribute.name
        let kindDependent = attribute.applicability != .any && !applicabilityIsCertain
        let aliasNote = spelling == attribute.name ? "" : " Runtime alias for \(attribute.name)."
        let applicabilityNote = kindDependent
            ? " Availability depends on the specific live \(attribute.kinds.first?.rawValue ?? "object")."
            : ""
        return LuaCompletionItem(
            label: spelling,
            insertionText: spelling,
            kind: .attribute,
            detail: attribute.type.displayName + (kindDependent ? " • object-dependent" : ""),
            documentation: attribute.summary + aliasNote + applicabilityNote
                + (attribute.observable ? " Changes emit attribute.changed." : ""),
            source: .elysium,
            isReadOnly: attribute.mutability == .readOnly,
            sortPriority: 2
        )
    }

    private static func customAttributeItems(
        _ attributes: [LuaCustomAttributeCompletion]
    ) -> [LuaCompletionItem] {
        let keywords = Set(ScriptLanguageSchema.keywords)
        return attributes.filter { attribute in
            guard !keywords.contains(attribute.name), let first = attribute.name.utf8.first else {
                return false
            }
            guard (first >= UInt8(ascii: "a") && first <= UInt8(ascii: "z"))
                    || first == UInt8(ascii: "_") else {
                return false
            }
            return attribute.name.utf8.dropFirst().allSatisfy { byte in
                (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                    || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                    || byte == UInt8(ascii: "_")
            }
        }.map { attribute in
            LuaCompletionItem(
                label: attribute.name,
                insertionText: attribute.name,
                kind: .attribute,
                detail: attribute.typeName,
                documentation: attribute.summary,
                source: .liveObject,
                isReadOnly: attribute.isReadOnly,
                sortPriority: 0
            )
        }
    }

    private static func eventFieldItems(
        eventName: String?, environment: LuaLanguageEnvironment
    ) -> [LuaCompletionItem] {
        var fields = EventDescriptorRegistry.commonFields
        if let eventName,
           let event = environment.eventCandidates.first(where: { $0.name == eventName }) {
            fields.append(contentsOf: event.payload)
        } else if let eventName, let event = ScriptLanguageSchema.event(named: eventName) {
            fields.append(contentsOf: event.payload)
        }
        var seen: Set<String> = []
        return fields.filter { seen.insert($0.name).inserted }.map { field in
            LuaCompletionItem(
                label: field.name,
                insertionText: field.name,
                kind: .field,
                detail: field.type.displayName + (field.isNullable ? "?" : ""),
                documentation: field.summary,
                source: .elysium,
                isReadOnly: true,
                sortPriority: 0
            )
        }
    }

    private static func documentation(
        for symbol: ScriptLanguageSymbol, signature: ScriptCallableSignature?
    ) -> String {
        var parts = [symbol.summary]
        if let signature, !signature.summary.isEmpty { parts.append(signature.summary) }
        switch symbol.availability {
        case .available: break
        case .acceptedNoOp(let note): parts.append("Currently a no-op: \(note)")
        case .reserved(let note): parts.append("Reserved: \(note)")
        case .unavailable(let reason, let replacement):
            parts.append(reason)
            if let replacement { parts.append("Use \(replacement) instead.") }
        }
        return parts.joined(separator: "\n\n")
    }

    private static func inferredType(_ type: ScriptLanguageValueType) -> LuaInferredType {
        switch type {
        case .any, .item, .effectList: .unknown
        case .boolean: .boolean
        case .integer: .integer
        case .number: .number
        case .string, .enumeration: .string
        case .function: .function(signature: "function")
        case .table, .map: .table([:])
        case .objectHandle: .object(nil)
        case .attributeProxy: .attributes(nil)
        case .event: .event(nil)
        case .list: .list(.unknown)
        }
    }
}
