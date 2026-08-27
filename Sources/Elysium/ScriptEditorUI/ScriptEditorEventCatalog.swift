// ScriptEditorEventCatalog.swift — immutable event-authoring metadata for the native editor.
// Built-ins come from the shipped registry and custom events come only from the current target's
// object-scoped declaration store. The catalog never subscribes, emits, or mutates world state.

import ElysiumCore

enum ScriptEditorEventCandidateSource: String, Equatable, Sendable {
    case builtIn = "built_in"
    case declaredCustom = "declared_custom"

    var title: String {
        switch self {
        case .builtIn: "Built-in"
        case .declaredCustom: "Declared custom"
        }
    }
}

struct ScriptEditorEventCandidate: Equatable, Sendable, Identifiable {
    let name: String
    let source: ScriptEditorEventCandidateSource
    let summary: String
    let payload: [ScriptEventFieldDescriptor]
    let provenance: Provenance?

    var id: String { "\(source.rawValue):\(name)" }

    var detail: String {
        let fields = payload.isEmpty
            ? "no event-specific fields"
            : payload.map { $0.name + ": " + $0.type.displayName + ($0.isNullable ? "?" : "") }
                .joined(separator: ", ")
        return "\(source.title) event · \(fields)"
    }

    var accessibilityDescription: String {
        "\(name), \(detail). \(summary)"
    }
}

enum ScriptEditorEventCatalog {
    /// Module source can subscribe to an explicit target of another kind. In those call sites,
    /// retain every shipped event while still exposing declarations known on the editor target.
    /// The native Handler picker uses the target-filtered `candidates` overloads below.
    static func broadlyAvailableCandidates(
        including contextualCandidates: [ScriptEditorEventCandidate]
    ) -> [ScriptEditorEventCandidate] {
        let custom = contextualCandidates.filter { $0.source == .declaredCustom }
        return EventDescriptorRegistry.available.map(candidate(for:)) + custom
    }

    static func candidates(target: ObjectRef, graph: ObjectGraph) -> [ScriptEditorEventCandidate] {
        candidates(
            targetKind: target.kind,
            declarations: CustomEventStore(graph: graph).list(target)
        )
    }

    static func candidates(
        targetKind: ObjectKind,
        declarations: [CustomEventDeclaration] = []
    ) -> [ScriptEditorEventCandidate] {
        let builtIns = builtInCandidates(targetKind: targetKind)
        let builtInNames = Set(EventDescriptorRegistry.all.map { $0.kind.rawValue })
        let custom = declarations
            .filter { !builtInNames.contains($0.kind.rawValue) }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
            .map { declaration in
                ScriptEditorEventCandidate(
                    name: declaration.kind.rawValue,
                    source: .declaredCustom,
                    summary: declaration.summary ?? "Custom event declared on this target.",
                    payload: declaration.fields.map { field in
                        ScriptEventFieldDescriptor(
                            name: field.name,
                            type: field.type.languageType,
                            isNullable: field.isNullable,
                            summary: "Custom event payload field declared on this target."
                        )
                    },
                    provenance: declaration.provenance
                )
            }
        return builtIns + custom
    }

    static func candidates(
        targetKind: ObjectKind,
        mirroredDeclarations: [LANCustomEventMetadata]
    ) -> [ScriptEditorEventCandidate] {
        let builtIns = builtInCandidates(targetKind: targetKind)
        let builtInNames = Set(EventDescriptorRegistry.all.map { $0.kind.rawValue })
        let reservedFields: Set<String> = ["kind", "subject", "tick", "source"]
        let custom = mirroredDeclarations.compactMap { metadata -> ScriptEditorEventCandidate? in
            guard let kind = EventKind.parse(metadata.name),
                  !builtInNames.contains(kind.rawValue) else { return nil }
            let fields = metadata.fields.keys.sorted().compactMap { name -> ScriptEventFieldDescriptor? in
                guard isValidAttributeName(name), !reservedFields.contains(name),
                      let field = CustomEventField(name: name, typeToken: metadata.fields[name] ?? "")
                else { return nil }
                return ScriptEventFieldDescriptor(
                    name: field.name,
                    type: field.type.languageType,
                    isNullable: field.isNullable,
                    summary: "Custom event payload field declared on the host target."
                )
            }
            return ScriptEditorEventCandidate(
                name: kind.rawValue,
                source: .declaredCustom,
                summary: metadata.summary.map(ScriptingDisplayText.line)
                    ?? "Custom event declared on the host target.",
                payload: fields,
                provenance: nil
            )
        }.sorted { $0.name < $1.name }
        return builtIns + custom
    }

    private static func builtInCandidates(targetKind: ObjectKind) -> [ScriptEditorEventCandidate] {
        EventDescriptorRegistry.available.compactMap { descriptor -> ScriptEditorEventCandidate? in
            guard descriptor.subjectKinds.contains(targetKind) else { return nil }
            return candidate(for: descriptor)
        }
    }

    private static func candidate(
        for descriptor: ScriptEventDescriptor
    ) -> ScriptEditorEventCandidate {
        ScriptEditorEventCandidate(
            name: descriptor.kind.rawValue,
            source: .builtIn,
            summary: descriptor.summary,
            payload: descriptor.payload,
            provenance: nil
        )
    }
}

enum ScriptEditorAuthoringContract {
    static let handlerEventRequired =
        "Choose or enter a handler event before asking AI. No request was sent to Ollama."

    static func modeHelp(_ mode: ScriptMode) -> String {
        switch mode {
        case .module:
            "Module source runs once when loaded. Register EventBus callbacks as on(\"event.name\", function(ev) ... end), target:on(\"event.name\", function(ev) ... end), target:onAttribute(\"name\", function(ev) ... end), or subscribe(target, \"event.name\", function(ev) ... end). Each callback receives exactly one ev; there is no top-level ev. register(\"unload\", fn) is a separate synchronous, no-ev, custom-attribute-only finalizer."
        case .handler:
            "Handler source is already the selected event body. Use implicit ev directly; the runtime supplies exactly one event value. Do not wrap the source in on(...), target:on(...), target:onAttribute(...), subscribe(...), or function(ev)."
        }
    }

    static func handlerEventHelp(
        eventName: String,
        candidates: [ScriptEditorEventCandidate],
        targetKind: ObjectKind
    ) -> String {
        let name = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return "Required for Handler mode. Choose a compatible built-in event or a custom event declared on this target."
        }
        if let error = handlerEventValidationError(
            eventName: name, targetKind: targetKind
        ) { return error }
        if let candidate = candidates.first(where: { $0.name == name }) {
            return "\(candidate.detail). \(candidate.summary)"
        }
        return "'\(name)' is a valid open custom event, but it is not declared on this target; payload completion is unavailable."
    }

    /// Handler triggers keep the custom-event namespace open, but a name that is already reserved
    /// by the engine must describe a produced event for this exact target kind. Keeping this rule in
    /// one editor-side seam prevents Save, Check, and optional AI from disagreeing with the picker.
    static func handlerEventValidationError(
        eventName: String,
        targetKind: ObjectKind
    ) -> String? {
        let name = eventName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return "Choose or enter a handler event."
        }
        guard EventKind.parse(name) != nil else {
            return "'\(name)' is not a valid event name. Use lowercase dotted segments such as machine.ready."
        }
        guard let descriptor = EventDescriptorRegistry.descriptor(named: name) else {
            return nil // Valid open custom event.
        }
        guard descriptor.availability.isCompletable else {
            if descriptor.kind == .unload {
                return "'unload' is not an EventBus handler event. In Module mode, use register(\"unload\", function() ... end) for the synchronous, no-ev, custom-attribute-only finalizer."
            }
            return "'\(name)' is reserved and has no shipped producer."
        }
        guard descriptor.subjectKinds.contains(targetKind) else {
            return "'\(name)' is a built-in event, but it is not raised for \(targetKind.rawValue) targets."
        }
        return nil
    }

    static let handlerRunOnceUnavailable =
        "Run Once does not synthesize an event for Handler source. Use Check for a representative event, or Save and trigger the real event in the game."
}
