// CustomEventPayloadValidation.swift — deterministic validation at authoring/emit boundaries.
// EventBus intentionally stays open and graph-free so old undeclared custom events continue to
// route exactly as before; callers opt into this check when a subject has published a contract.

public enum CustomEventPayloadError: Error, Equatable, Sendable {
    case missingField(String)
    case unexpectedField(String)
    case nullNotAllowed(String)
    case wrongType(field: String, expected: String)

    public var message: String {
        switch self {
        case .missingField(let name):
            return "missing required payload field '\(name)'"
        case .unexpectedField(let name):
            return "payload field '\(name)' is not declared"
        case .nullNotAllowed(let name):
            return "payload field '\(name)' is not nullable"
        case .wrongType(let field, let expected):
            return "payload field '\(field)' must be \(expected)"
        }
    }
}

public extension CustomEventDeclaration {
    /// Strictly validates a payload against this declaration. Field ordering is irrelevant;
    /// diagnostics are deterministic because both declaration fields and extra keys are checked
    /// in UTF-8 byte order. Nullable fields may be absent or explicit nil. Declarations are
    /// metadata contracts, not EventBus permissions; callers skip this method when no declaration
    /// exists for the subject.
    func validate(payload: [String: AttrValue]) -> Result<Void, CustomEventPayloadError> {
        let allowed = Set(fields.map(\.name))
        if let extra = payload.keys.sorted(by: utf8Less).first(where: { !allowed.contains($0) }) {
            return .failure(.unexpectedField(extra))
        }
        for field in fields {
            guard let value = payload[field.name] else {
                if field.isNullable { continue }
                return .failure(.missingField(field.name))
            }
            if case .null = value {
                if field.isNullable { continue }
                return .failure(.nullNotAllowed(field.name))
            }
            guard field.accepts(value) else {
                return .failure(.wrongType(field: field.name, expected: field.typeToken))
            }
        }
        return .success(())
    }
}

private extension CustomEventField {
    func accepts(_ value: AttrValue) -> Bool {
        switch (type, value) {
        case (.any, _): return true
        case (.boolean, .bool): return true
        case (.integer, .int): return true
        case (.number, .int), (.number, .number): return true
        case (.string, .string): return true
        case (.object, .ref): return true
        case (.list, .list): return true
        case (.map, .map): return true
        default: return false
        }
    }
}

/// One shared validation boundary for player, Lua, and AI event emission. Engine producers use
/// `EventBus.raise` directly because their typed call sites are the authority; untrusted callers
/// must not forge a built-in on the wrong object or omit its documented payload.
public enum ScriptEventEmissionValidator {
    public static func refusal(
        kind: EventKind, subject: ObjectRef, payload: [String: AttrValue],
        declaration: CustomEventDeclaration?
    ) -> String? {
        if let descriptor = EventDescriptorRegistry.descriptor(for: kind) {
            guard descriptor.availability.isCompletable else {
                return "built-in event '\(kind.rawValue)' is reserved and cannot be emitted"
            }
            // Standard events are factual engine signals. Allowing scripts, commands, LAN guests,
            // or AI to synthesize `block.broken`, `entity.died`, and similar names would make every
            // consumer remember to authenticate `ev.source`. Keep the untrusted emission surface
            // exclusively for open custom events; engine producers call EventBus.raise directly.
            return "built-in event '\(kind.rawValue)' is engine-produced and cannot be emitted manually"
        }
        if let declaration, case .failure(let error) = declaration.validate(payload: payload) {
            return error.message
        }
        return nil
    }

}
