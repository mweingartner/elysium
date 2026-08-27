// AIObjectGraphMutationTools.swift — ai-object-graph (change 2). design.md
// §9.3: "set_attribute, define_attribute, remove_attribute, attach_script,
// detach_script, enable_script, subscribe, unsubscribe, emit_event,
// run_script ... all go through the same executors as /script/attr/on; all
// refused on LAN clients; every refusal is {refused:true, stage, message,
// hint, didYouMean[]}." §9.4 (attach_script only): compile+lint+references+
// dry-run before the record is ever stored. §9.5: every successful mutation
// is journaled with provenance `.ai(model:)`, apply-with-undo.

import Foundation

/// The mutable bundle every mutation tool needs — a superset of
/// `AIQueryContext` (mutations also read, via the same stores) plus the
/// journal, the model name for provenance, and this request's journal id.
public struct AIMutationContext {
    public let graph: ObjectGraph
    public let store: AttributeStore
    public let scriptStore: ScriptStore
    public let eventBus: EventBus
    public let scriptRuntime: ScriptRuntime?
    public let target: ObjectTargetContext
    public let tick: Int64
    public let model: String
    public let isLANClient: Bool
    public let journal: AIJournal
    public let requestID: UInt64

    public init(
        graph: ObjectGraph, store: AttributeStore, scriptStore: ScriptStore, eventBus: EventBus,
        scriptRuntime: ScriptRuntime?, target: ObjectTargetContext, tick: Int64, model: String,
        isLANClient: Bool, journal: AIJournal, requestID: UInt64
    ) {
        self.graph = graph
        self.store = store
        self.scriptStore = scriptStore
        self.eventBus = eventBus
        self.scriptRuntime = scriptRuntime
        self.target = target
        self.tick = tick
        self.model = model
        self.isLANClient = isLANClient
        self.journal = journal
        self.requestID = requestID
    }

    var queryContext: AIQueryContext {
        AIQueryContext(graph: graph, store: store, scriptStore: scriptStore, eventBus: eventBus, target: target, scriptRuntime: scriptRuntime)
    }
}

public enum AIObjectGraphMutationTools {
    public static let definitions: [AIToolDefinition] = [
        AIToolDefinition(
            name: "set_attribute", kind: .mutation, summary: "Set a mutable custom attribute (or a built-in getSet attribute) to a value.",
            parameters: [
                .init(name: "ref", type: "string", summary: "Object ref or alias."),
                .init(name: "key", type: "string", summary: "Attribute name."),
                .init(name: "value", type: "string", summary: "The value (any JSON scalar, list, or object)."),
            ], required: ["ref", "key", "value"]
        ),
        AIToolDefinition(
            name: "define_attribute", kind: .mutation, summary: "Create or overwrite a custom attribute, optionally readonly.",
            parameters: [
                .init(name: "ref", type: "string", summary: "Object ref or alias."),
                .init(name: "key", type: "string", summary: "Attribute name."),
                .init(name: "value", type: "string", summary: "The value."),
                .init(name: "readonly", type: "boolean", summary: "Make the entry immutable."),
                .init(name: "force", type: "boolean", summary: "Overwrite an existing readonly entry."),
            ], required: ["ref", "key", "value"]
        ),
        AIToolDefinition(
            name: "remove_attribute", kind: .mutation, summary: "Remove a custom attribute.",
            parameters: [
                .init(name: "ref", type: "string", summary: "Object ref or alias."),
                .init(name: "key", type: "string", summary: "Attribute name."),
            ], required: ["ref", "key"]
        ),
        AIToolDefinition(
            name: "attach_script", kind: .mutation, summary: "Validate and attach a Lua script to an object (module mode, or handler mode with triggers).",
            parameters: [
                .init(name: "ref", type: "string", summary: "Object ref or alias."),
                .init(name: "name", type: "string", summary: "Script name."),
                .init(name: "source", type: "string", summary: "Lua source, <= 16 KiB."),
                .init(name: "mode", type: "string", summary: "module | handler (default module).", enumValues: ["module", "handler"]),
                .init(name: "triggers", type: "string", summary: "For handler mode: a JSON array of {event, attr?, target?}."),
            ], required: ["ref", "name", "source"]
        ),
        AIToolDefinition(
            name: "detach_script", kind: .mutation, summary: "Remove a script from an object.",
            parameters: [
                .init(name: "ref", type: "string", summary: "Object ref or alias."),
                .init(name: "name", type: "string", summary: "Script name."),
            ], required: ["ref", "name"]
        ),
        AIToolDefinition(
            name: "enable_script", kind: .mutation, summary: "Enable or disable a script without changing its source.",
            parameters: [
                .init(name: "ref", type: "string", summary: "Object ref or alias."),
                .init(name: "name", type: "string", summary: "Script name."),
                .init(name: "enabled", type: "boolean", summary: "true to enable, false to disable."),
            ], required: ["ref", "name", "enabled"]
        ),
        AIToolDefinition(
            name: "subscribe", kind: .mutation, summary: "Register a persisted event subscription that calls a named handler in a script.",
            parameters: [
                .init(name: "subscriber", type: "string", summary: "The object whose script owns the handler (usually 'player')."),
                .init(name: "target", type: "string", summary: "What to watch: a ref, a bare kind (block/entity/player), or 'any'."),
                .init(name: "event", type: "string", summary: "Event kind, e.g. 'attribute.changed'."),
                .init(name: "attr", type: "string", summary: "Attribute name filter (for attribute.changed)."),
                .init(name: "handler", type: "string", summary: "'<script>.<handlerName>' on the subscriber."),
            ], required: ["subscriber", "target", "event", "handler"]
        ),
        AIToolDefinition(
            name: "unsubscribe", kind: .mutation, summary: "Remove a persisted subscription by id.",
            parameters: [.init(name: "id", type: "integer", summary: "Subscription id.")], required: ["id"]
        ),
        AIToolDefinition(
            name: "emit_event", kind: .mutation,
            summary: "Emit, declare, or remove an object-scoped custom event. Built-in events are engine-produced and cannot be emitted manually. Omit action for backward-compatible custom emit.",
            parameters: [
                .init(name: "ref", type: "string", summary: "Object ref or alias."),
                .init(name: "name", type: "string", summary: "Event name (e.g. 'lumber.milestone')."),
                .init(name: "action", type: "string", summary: "emit | declare | remove (default emit).", enumValues: ["emit", "declare", "remove"]),
                .init(name: "payload", type: "string", summary: "JSON object payload."),
                .init(name: "fields", type: "string", summary: "For declare: JSON object mapping field names to type tokens such as string, integer, or object?."),
                .init(name: "summary", type: "string", summary: "For declare: short human-readable meaning."),
            ], required: ["ref", "name"]
        ),
        AIToolDefinition(
            name: "run_script", kind: .mutation, summary: "Run Lua source once, immediately, ephemerally (not saved; no subscribe/timers/ai).",
            parameters: [
                .init(name: "source", type: "string", summary: "Lua source."),
                .init(name: "ref", type: "string", summary: "Object to run it against (default player)."),
            ], required: ["source"]
        ),
    ]

    public static func run(_ name: String, args: AIToolArguments, context: AIMutationContext) -> AIToolOutcome {
        if context.isLANClient {
            return .refuse(stage: "execute", message: "this command runs on the LAN host only (guests get access in a later update)")
        }
        switch name {
        case "set_attribute": return setAttribute(args, context)
        case "define_attribute": return defineAttribute(args, context)
        case "remove_attribute": return removeAttribute(args, context)
        case "attach_script": return attachScript(args, context)
        case "detach_script": return detachScript(args, context)
        case "enable_script": return enableScript(args, context)
        case "subscribe": return subscribe(args, context)
        case "unsubscribe": return unsubscribe(args, context)
        case "emit_event": return emitEvent(args, context)
        case "run_script": return runScript(args, context)
        default: return .refuse(stage: "args", message: "'\(name)' is not a known tool")
        }
    }

    // MARK: - shared

    private static func resolveRefArg(_ args: AIToolArguments, _ key: String, _ context: AIMutationContext) -> Result<(ObjectRef, LiveObject), AIToolOutcome> {
        guard let token = args.string(key) else { return .failure(.refuse(stage: "args", message: "'\(key)' is required")) }
        guard let ref = context.target.resolve(alias: token) else {
            return .failure(.refuse(stage: "args", message: "no such object '\(token)'"))
        }
        switch context.graph.resolve(ref) {
        case .live(let live): return .success((ref, live))
        case .dormant: return .failure(.refuse(stage: "args", message: "\(ref.canonical) is not in the loaded dimension"))
        case .notLoaded: return .failure(.refuse(stage: "args", message: "\(ref.canonical) is not loaded"))
        case .unsupported: return .failure(.refuse(stage: "args", message: "guest player objects arrive in a later update"))
        case .unknown: return .failure(.refuse(stage: "args", message: "no such object \(ref.canonical)"))
        }
    }

    private static func attributeErrorOutcome(_ err: AttributeError, name: String) -> AIToolOutcome {
        switch err {
        case .objectNotLive: return .refuse(stage: "execute", message: "object is not loaded")
        case .dormant: return .refuse(stage: "execute", message: "object's dimension is not loaded")
        case .unsupported: return .refuse(stage: "execute", message: "unsupported object")
        case .invalidName(let hint):
            return .refuse(stage: "execute", message: "'\(name)' is not a valid attribute name", hint: hint ?? "")
        case .nameIsBuiltIn: return .refuse(stage: "execute", message: "'\(name)' is a built-in attribute — set it directly")
        case .nameIsScript: return .refuse(stage: "execute", message: "'\(name)' is an attached script — detach it first")
        case .invalidValue(let e): return .refuse(stage: "execute", message: "value rejected (\(e.message))")
        case .readonly: return .refuse(stage: "execute", message: "'\(name)' is readonly", hint: "pass force:true to define_attribute to overwrite it")
        case .tooManyEntries(let limit): return .refuse(stage: "execute", message: "too many attributes (limit \(limit))")
        case .recordTooLarge, .chunkTooLarge, .documentTooLarge: return .refuse(stage: "execute", message: "attribute storage limit exceeded")
        case .lanClient: return .refuse(stage: "execute", message: "scripts do not run on LAN clients")
        case .revisionOverflow: return .refuse(stage: "execute", message: "revision limit reached")
        }
    }

    private static func scriptErrorOutcome(_ err: ScriptStoreError, name: String) -> AIToolOutcome {
        .refuse(stage: "execute", message: "'\(name)' " + scriptStoreErrorText(err))
    }

    /// AI-authored camelCase creates canonical snake_case, but an existing pre-upgrade collapsed
    /// key remains the mutation target so a tool call cannot silently fork one logical value.
    private static func customAttributeKey(
        _ raw: String, ref: ObjectRef, context: AIMutationContext
    ) -> String {
        let canonical = normalizedScriptCustomAttributeName(raw)
        let entries = context.store.record(ref)?.entries ?? [:]
        if entries[canonical] != nil { return canonical }
        if let legacy = normalizedAttributeNameHint(raw), entries[legacy] != nil { return legacy }
        return canonical
    }

    private static func attributeFilter(
        _ raw: String, target: SubscriptionTarget, context: AIMutationContext
    ) -> String? {
        if let builtIn = ergonomicBuiltInAttribute(raw, target: target) {
            return builtIn.canonical
        }
        let normalized: String
        if case .object(let ref) = target {
            normalized = customAttributeKey(raw, ref: ref, context: context)
        } else {
            normalized = normalizedScriptCustomAttributeName(raw)
        }
        return canonicalEventBusAttributeFilter(normalized, target: target)
    }

    // MARK: - set_attribute

    private static func setAttribute(_ args: AIToolArguments, _ context: AIMutationContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, live)):
            guard let rawKey = args.string("key") else { return .refuse(stage: "args", message: "'key' is required") }
            guard let value = args.attrValue("value", caps: .defaults) else {
                return .refuse(stage: "args", message: "'value' could not be parsed")
            }
            let normalizedKey = normalizedScriptCustomAttributeName(rawKey)
            if let descriptor = AttributeRegistry.resolve(kind: ref.kind, name: rawKey)
                ?? AttributeRegistry.resolve(kind: ref.kind, name: normalizedKey) {
                let canonical = descriptor.canonical
                guard case .value(let before) = BuiltInAttributes.get(
                    live, name: canonical, host: context.graph.host
                ) else {
                    return .refuse(stage: "execute", message: "'\(canonical)' is not an attribute here")
                }
                switch context.graph.host.setScriptBuiltInAttribute(
                    live, ref: ref, name: canonical, value: value, author: .ai(model: context.model)
                ) {
                case .ok(let v):
                    if before != v {
                        context.journal.record(
                            requestID: context.requestID, tool: "set_attribute", ref: ref,
                            name: canonical, tick: context.tick, model: context.model,
                            afterHash: sha256Hex(AttrValueCodec.encode(v)),
                            undo: .builtInAttributeValue(ref: ref, name: canonical, before: before)
                        )
                    }
                    return .ok("{\"ref\":\(jsonString(ref.canonical)),\"key\":\(jsonString(canonical)),\"value\":\(AttrValueCodec.encode(v))}")
                case .unknownName(let suggestions):
                    return .refuse(stage: "execute", message: "unknown built-in attribute '\(rawKey)'", didYouMean: suggestions)
                case .notApplicable: return .refuse(stage: "execute", message: "'\(rawKey)' is not an attribute here")
                case .readOnly: return .refuse(stage: "execute", message: "'\(rawKey)' is readonly")
                case .wrongValueKind: return .refuse(stage: "execute", message: "'\(rawKey)' does not accept that value")
                case .outOfRange(let range): return .refuse(stage: "execute", message: "'\(rawKey)' must be in \(range)")
                }
            }
            let key = customAttributeKey(rawKey, ref: ref, context: context)
            let before = context.store.list(ref).first { $0.name == key }
            switch context.store.set(ref, key, value, by: .ai(model: context.model)) {
            case .success(let v):
                context.journal.record(
                    requestID: context.requestID, tool: "set_attribute", ref: ref, name: key, tick: context.tick,
                    model: context.model, afterHash: sha256Hex(AttrValueCodec.encode(v)),
                    undo: .attributeValue(ref: ref, name: key, before: before?.value, beforeReadonly: false)
                )
                return .ok("{\"ref\":\(jsonString(ref.canonical)),\"key\":\(jsonString(key)),\"value\":\(AttrValueCodec.encode(v))}")
            case .failure(let err):
                return attributeErrorOutcome(err, name: key)
            }
        }
    }

    // MARK: - define_attribute

    private static func defineAttribute(_ args: AIToolArguments, _ context: AIMutationContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, _)):
            guard let rawKey = args.string("key") else { return .refuse(stage: "args", message: "'key' is required") }
            guard let value = args.attrValue("value", caps: .defaults) else {
                return .refuse(stage: "args", message: "'value' could not be parsed")
            }
            let key = customAttributeKey(rawKey, ref: ref, context: context)
            let readonly = args.bool("readonly") ?? false
            let force = args.bool("force") ?? false
            let before = context.store.list(ref).first { $0.name == key }
            switch context.store.define(ref, key, value, readonly: readonly, force: force, by: .ai(model: context.model)) {
            case .success(let result):
                context.journal.record(
                    requestID: context.requestID, tool: "define_attribute", ref: ref, name: key, tick: context.tick,
                    model: context.model, afterHash: sha256Hex(AttrValueCodec.encode(result.value)),
                    undo: .attributeValue(ref: ref, name: key, before: before?.value, beforeReadonly: before?.readonly ?? false)
                )
                return .ok(
                    "{\"ref\":\(jsonString(ref.canonical)),\"key\":\(jsonString(key)),\"value\":\(AttrValueCodec.encode(result.value))" +
                        ",\"readonly\":\(readonly),\"forced\":\(result.forced)}"
                )
            case .failure(let err):
                return attributeErrorOutcome(err, name: key)
            }
        }
    }

    // MARK: - remove_attribute

    private static func removeAttribute(_ args: AIToolArguments, _ context: AIMutationContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, _)):
            guard let rawKey = args.string("key") else { return .refuse(stage: "args", message: "'key' is required") }
            let key = customAttributeKey(rawKey, ref: ref, context: context)
            let before = context.store.list(ref).first { $0.name == key }
            switch context.store.remove(ref, key, force: true, by: .ai(model: context.model)) {
            case .success(let result):
                guard result.existed else { return .refuse(stage: "execute", message: "'\(key)' is not set on \(ref.canonical)") }
                if let before {
                    context.journal.record(
                        requestID: context.requestID, tool: "remove_attribute", ref: ref, name: key, tick: context.tick,
                        model: context.model, afterHash: "", undo: .attributeValue(ref: ref, name: key, before: before.value, beforeReadonly: before.readonly)
                    )
                }
                return .ok("{\"ref\":\(jsonString(ref.canonical)),\"key\":\(jsonString(key)),\"removed\":true}")
            case .failure(let err):
                return attributeErrorOutcome(err, name: key)
            }
        }
    }

    // MARK: - attach_script (design.md §9.4 full gate)

    private static func attachScript(_ args: AIToolArguments, _ context: AIMutationContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, _)):
            guard let name = args.string("name") else { return .refuse(stage: "args", message: "'name' is required") }
            guard let source = args.string("source") else { return .refuse(stage: "args", message: "'source' is required") }
            guard let runtime = context.scriptRuntime else {
                return .refuse(stage: "execute", message: "no script runtime this session")
            }
            let modeText = args.string("mode") ?? "module"
            guard let mode = ScriptMode(rawValue: modeText) else {
                return .refuse(stage: "args", message: "'mode' must be 'module' or 'handler'")
            }
            var triggers: [Trigger] = []
            if mode == .handler {
                guard let triggersText = args.string("triggers"), let parsed = parseTriggers(
                    triggersText, defaultTarget: ref, context: context
                ) else {
                    return .refuse(stage: "args", message: "handler mode requires 'triggers': a JSON array of {event, attr?, target?}")
                }
                triggers = parsed
            }
            switch AIScriptValidationGate.validate(source: source, chunkName: name, runtime: runtime) {
            case .refused(let result):
                return .refuse(stage: "validate", message: result.message, hint: result.hint)
            case .accepted(let sha):
                var warnings: [String] = []
                let dryRunSubject: ObjectRef?
                let dryRunSubjectIsExact: Bool
                if mode == .handler, case .object(let subject)? = triggers.first?.target {
                    dryRunSubject = subject
                    dryRunSubjectIsExact = true
                } else {
                    dryRunSubject = nil
                    dryRunSubjectIsExact = mode != .handler
                }
                switch runtime.dryRunOutcome(
                    source: source, owner: ref, mode: mode, handlerEvent: triggers.first?.event,
                    handlerSubject: dryRunSubject, handlerSubjectIsExact: dryRunSubjectIsExact
                ) {
                case .completed:
                    break
                case .suspended(let boundary):
                    warnings.append("dry run stopped at \(boundary); later code was not executed")
                case .compiledOnly(let reason):
                    warnings.append("dry run compiled only: \(reason)")
                case .failure(let message):
                    warnings.append("dry run: \(message)")
                }
                let previousRecord = context.scriptStore.get(ref, name)
                switch context.scriptStore.attach(
                    ref, name: name, source: source, mode: mode, triggers: triggers,
                    by: .ai(model: context.model), tick: context.tick
                ) {
                case .success:
                    let previousEncoded = previousRecord.map(ScriptRecordCodec.encode)
                    context.journal.record(
                        requestID: context.requestID, tool: "attach_script", ref: ref, name: name, tick: context.tick,
                        model: context.model, afterHash: sha,
                        undo: .scriptRecord(ref: ref, name: name, hadPrevious: previousRecord != nil, wasDetach: false),
                        previousSource: previousEncoded
                    )
                    return .ok(
                        "{\"ref\":\(jsonString(ref.canonical)),\"name\":\(jsonString(name)),\"mode\":\(jsonString(mode.rawValue))" +
                            ",\"loaded\":\"pending\",\"note\":\"takes effect next script phase\"}",
                        warnings: warnings
                    )
                case .failure(let err):
                    return scriptErrorOutcome(err, name: name)
                }
            }
        }
    }

    private static func parseTriggers(
        _ json: String, defaultTarget: ObjectRef, context: AIMutationContext
    ) -> [Trigger]? {
        guard let data = json.data(using: .utf8), let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        var out: [Trigger] = []
        for entry in raw {
            guard let eventText = entry["event"] as? String, let event = EventKind.parse(eventText) else { return nil }
            var target: SubscriptionTarget = .object(defaultTarget)
            if let t = entry["target"] as? String {
                if t == "any" { target = .any }
                else if let ref = ObjectRef.parse(t) { target = .object(ref) }
                else if let kind = ObjectKind(rawValue: t) { target = .kind(kind, typeFilter: nil) }
                else { return nil }
            }
            var attribute: String?
            if let rawAttribute = entry["attr"] as? String {
                guard let canonical = attributeFilter(
                    rawAttribute, target: target, context: context
                ) else { return nil }
                attribute = canonical
            }
            out.append(Trigger(event: event, attribute: attribute, target: target))
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - detach_script

    private static func detachScript(_ args: AIToolArguments, _ context: AIMutationContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, _)):
            guard let name = args.string("name") else { return .refuse(stage: "args", message: "'name' is required") }
            guard let previous = context.scriptStore.get(ref, name) else {
                return .refuse(stage: "execute", message: "no script '\(name)' on \(ref.canonical)")
            }
            switch context.scriptStore.detach(ref, name) {
            case .success(let existed):
                if existed {
                    context.journal.record(
                        requestID: context.requestID, tool: "detach_script", ref: ref, name: name, tick: context.tick,
                        model: context.model, afterHash: "",
                        undo: .scriptRecord(ref: ref, name: name, hadPrevious: true, wasDetach: true),
                        previousSource: ScriptRecordCodec.encode(previous)
                    )
                }
                return .ok("{\"ref\":\(jsonString(ref.canonical)),\"name\":\(jsonString(name)),\"detached\":\(existed)}")
            case .failure(let err):
                return scriptErrorOutcome(err, name: name)
            }
        }
    }

    // MARK: - enable_script

    private static func enableScript(_ args: AIToolArguments, _ context: AIMutationContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, _)):
            guard let name = args.string("name") else { return .refuse(stage: "args", message: "'name' is required") }
            guard let enabled = args.bool("enabled") else { return .refuse(stage: "args", message: "'enabled' is required") }
            guard let before = context.scriptStore.get(ref, name) else {
                return .refuse(stage: "execute", message: "no script '\(name)' on \(ref.canonical)")
            }
            switch context.scriptStore.setEnabled(ref, name, enabled) {
            case .success:
                context.journal.record(
                    requestID: context.requestID, tool: "enable_script", ref: ref, name: name, tick: context.tick,
                    model: context.model, afterHash: enabled ? "1" : "0",
                    undo: .scriptEnabled(ref: ref, name: name, before: before.enabled)
                )
                return .ok("{\"ref\":\(jsonString(ref.canonical)),\"name\":\(jsonString(name)),\"enabled\":\(enabled)}")
            case .failure(let err):
                return scriptErrorOutcome(err, name: name)
            }
        }
    }

    // MARK: - subscribe / unsubscribe

    private static func subscribe(_ args: AIToolArguments, _ context: AIMutationContext) -> AIToolOutcome {
        guard let subscriberToken = args.string("subscriber"), let subscriber = context.target.resolve(alias: subscriberToken) else {
            return .refuse(stage: "args", message: "'subscriber' is required and must resolve to an object")
        }
        guard let targetToken = args.string("target"), let target = parseSubscriptionTargetToken(targetToken, context: context) else {
            return .refuse(stage: "args", message: "'target' is required (a ref, a bare kind, or 'any')")
        }
        guard let eventText = args.string("event"), let event = EventKind.parse(eventText) else {
            return .refuse(stage: "args", message: "'event' is required and must be a valid event name")
        }
        guard let handlerToken = args.string("handler"), let dot = handlerToken.lastIndex(of: "."), dot != handlerToken.startIndex else {
            return .refuse(stage: "args", message: "'handler' must be '<script>.<handlerName>'")
        }
        let scriptName = String(handlerToken[handlerToken.startIndex..<dot])
        let handler = String(handlerToken[handlerToken.index(after: dot)...])
        guard isValidAttributeName(scriptName), isValidAttributeName(handler) else {
            return .refuse(stage: "args", message: "'\(handlerToken)' is not a valid '<script>.<handler>'")
        }
        let attribute: String?
        if let rawAttribute = args.string("attr") {
            guard let canonical = attributeFilter(
                rawAttribute, target: target, context: context
            ) else {
                return .refuse(stage: "args", message: "'attr' is not a valid attribute filter")
            }
            attribute = canonical
        } else {
            attribute = nil
        }
        let before = context.eventBus.listSubscriptions().count
        switch context.eventBus.subscribe(
            subscriber: subscriber, scriptName: scriptName, handler: handler, target: target, event: event,
            attribute: attribute, createdBy: .ai(model: context.model), tick: context.tick
        ) {
        case .success(let sub):
            let after = context.eventBus.listSubscriptions().count
            if after > before {
                context.journal.record(
                    requestID: context.requestID, tool: "subscribe", ref: subscriber, name: "#\(sub.id)", tick: context.tick,
                    model: context.model, afterHash: "\(sub.id)", undo: .subscriptionCreated(id: sub.id)
                )
            }
            return .ok("{\"id\":\(sub.id),\"event\":\(jsonString(event.rawValue)),\"target\":\(jsonString(target.displayText))}")
        case .failure(let err):
            switch err {
            case .tooManyForWorld: return .refuse(stage: "execute", message: "too many subscriptions in this world")
            case .tooManyForObject: return .refuse(stage: "execute", message: "too many subscriptions on \(subscriber.canonical)")
            case .targetRequiresTypeFilter: return .refuse(stage: "execute", message: "'\(eventText)' on a block target requires a type filter")
            case .anyNotAllowedForThisEvent: return .refuse(stage: "execute", message: "'any' is not a valid target for '\(eventText)'")
            case .attributeFilterNotAllowed: return .refuse(stage: "execute", message: "an attribute filter is valid only for 'attribute.changed'")
            case .invalidAttributeFilter: return .refuse(stage: "execute", message: "'attr' is not a valid attribute filter")
            case .eventNotApplicable: return .refuse(stage: "execute", message: "'\(eventText)' does not apply to that target kind")
            case .eventNotAvailable: return .refuse(stage: "execute", message: "'\(eventText)' is reserved and has no event producer")
            }
        }
    }

    private static func parseSubscriptionTargetToken(_ token: String, context: AIMutationContext) -> SubscriptionTarget? {
        if token == "any" { return .any }
        if let kind = ObjectKind(rawValue: token) { return .kind(kind, typeFilter: nil) }
        if token.hasPrefix("entity:"), Int(token.dropFirst(7)) == nil {
            let rest = String(token.dropFirst(7))
            if !rest.isEmpty, rest.utf8.count <= 32, !rest.contains(":") { return .kind(.entity, typeFilter: rest) }
        }
        if token.hasPrefix("block:") {
            let rest = String(token.dropFirst(6))
            if !rest.isEmpty, rest.utf8.count <= 32, !rest.contains(":") { return .kind(.block, typeFilter: rest) }
        }
        if let ref = context.target.resolve(alias: token) { return .object(ref) }
        return nil
    }

    private static func unsubscribe(_ args: AIToolArguments, _ context: AIMutationContext) -> AIToolOutcome {
        guard let id = args.int("id") else { return .refuse(stage: "args", message: "'id' is required") }
        guard context.eventBus.unsubscribe(id: UInt64(id)) else {
            return .refuse(stage: "execute", message: "no subscription #\(id)")
        }
        // Not undoable in this change (would require re-deriving the exact
        // original subscription shape) — journaled for visibility only,
        // matching §9.5's "world effects... not reverted" wording for
        // actions this gate cannot cleanly reverse.
        context.journal.record(
            requestID: context.requestID, tool: "unsubscribe", ref: .world, name: "#\(id)", tick: context.tick,
            model: context.model, afterHash: "", undo: .none
        )
        return .ok("{\"id\":\(id),\"unsubscribed\":true}")
    }

    // MARK: - emit_event

    private static func emitEvent(_ args: AIToolArguments, _ context: AIMutationContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, live)):
            guard let name = args.string("name"), let kind = EventKind.parse(name) else {
                return .refuse(stage: "args", message: "'name' is required and must be a valid event name")
            }
            let action = args.string("action") ?? "emit"
            let declarations = CustomEventStore(graph: context.graph)
            switch action {
            case "declare":
                var fields: [CustomEventField] = []
                if let fieldsText = args.string("fields") {
                    guard case .success(.map(let schema)) = AttrValueCodec.decode(fieldsText, caps: .defaults) else {
                        return .refuse(stage: "args", message: "'fields' must be a JSON object mapping field names to type tokens")
                    }
                    for fieldName in schema.keys.sorted(by: utf8Less) {
                        guard case .string(let token)? = schema[fieldName],
                              let field = CustomEventField(name: fieldName, typeToken: token) else {
                            return .refuse(stage: "args", message: "event field '\(fieldName)' has an invalid type token")
                        }
                        fields.append(field)
                    }
                }
                switch declarations.declare(
                    ref, name: name, fields: fields, summary: args.string("summary"),
                    by: .ai(model: context.model)
                ) {
                case .failure(let error): return customEventOutcome(error, name: name)
                case .success(let declaration):
                    context.journal.record(
                        requestID: context.requestID, tool: "emit_event", ref: ref,
                        name: "declare:\(name)", tick: context.tick, model: context.model,
                        afterHash: sha256Hex(declaration.kind.rawValue + declaration.fields.map(\.typeToken).joined()),
                        undo: .none
                    )
                    return .ok("{\"ref\":\(jsonString(ref.canonical)),\"name\":\(jsonString(name)),\"declared\":true}")
                }
            case "remove":
                switch declarations.undeclare(ref, name) {
                case .failure(let error): return customEventOutcome(error, name: name)
                case .success(let existed):
                    context.journal.record(
                        requestID: context.requestID, tool: "emit_event", ref: ref,
                        name: "remove:\(name)", tick: context.tick, model: context.model,
                        afterHash: existed ? "removed" : "absent", undo: .none
                    )
                    return .ok("{\"ref\":\(jsonString(ref.canonical)),\"name\":\(jsonString(name)),\"removed\":\(existed)}")
                }
            case "emit": break
            default:
                return .refuse(stage: "args", message: "'action' must be emit, declare, or remove")
            }
            var payload: [String: AttrValue] = [:]
            if let payloadText = args.string("payload") {
                guard case .success(.map(let map)) = AttrValueCodec.decode(payloadText, caps: .defaults) else {
                    return .refuse(stage: "args", message: "'payload' must be a valid JSON object")
                }
                payload = map
            }
            if let refusal = ScriptEventEmissionValidator.refusal(
                kind: kind, subject: ref, payload: payload,
                declaration: declarations.get(ref, name)
            ) {
                return .refuse(stage: "validate", message: refusal)
            }
            let outcome = context.eventBus.raise(
                kind: kind, subject: ref, payload: payload,
                source: .ai(model: context.model), tick: context.tick,
                subjectType: eventSubjectType(live)
            )
            switch outcome {
            case .enqueued(let seq), .coalesced(let seq):
                context.journal.record(
                    requestID: context.requestID, tool: "emit_event", ref: ref, name: name, tick: context.tick,
                    model: context.model, afterHash: "\(seq)", undo: .none
                )
                return .ok("{\"ref\":\(jsonString(ref.canonical)),\"name\":\(jsonString(name)),\"seq\":\(seq)}")
            case .droppedQueueFull:
                return .refuse(stage: "execute", message: "event queue is full — dropped")
            case .droppedCascadeDepth, .droppedHandlerBudget:
                return .refuse(stage: "execute", message: "dropped (budget exceeded)")
            }
        }
    }

    private static func customEventOutcome(
        _ error: CustomEventStoreError, name: String
    ) -> AIToolOutcome {
        let message: String
        switch error {
        case .objectNotLive: message = "object is not loaded"
        case .dormant: message = "object's dimension is not loaded"
        case .unsupported: message = "unsupported object"
        case .lanClient: message = "event declarations are host-authoritative"
        case .invalidEventName: message = "'\(name)' is not a valid custom event name"
        case .builtInEventName: message = "'\(name)' is a built-in event and cannot be redeclared"
        case .tooManyDeclarations(let limit): message = "too many event declarations (limit \(limit))"
        case .tooManyFields(let limit): message = "event schema exceeds \(limit) fields"
        case .invalidFieldName(let field): message = "'\(field)' is not a valid event field name"
        case .reservedFieldName(let field): message = "'\(field)' is a reserved event envelope field"
        case .duplicateFieldName(let field): message = "event field '\(field)' is duplicated"
        case .summaryTooLarge(let limit): message = "event summary exceeds \(limit) UTF-8 bytes"
        case .invalidSummary: message = "event summary contains unsupported text"
        case .tooManyEntries(let limit): message = "object scripting storage exceeds \(limit) entries"
        case .recordTooLarge, .chunkTooLarge, .documentTooLarge:
            message = "event declaration storage limit exceeded"
        case .revisionOverflow: message = "revision limit reached"
        }
        return .refuse(stage: "execute", message: message)
    }

    private static func eventSubjectType(_ live: LiveObject) -> String? {
        switch live {
        case .world: return nil
        case .dimension: return nil
        case .block(_, let chunk, _, let x, let y, let z):
            let cell = Int(chunk.get(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)))
            let id = cell >> 4
            return (id >= 0 && id < blockDefs.count) ? blockDefs[id].name : nil
        case .entity(let entity, _): return entity.type
        case .player: return nil
        }
    }

    // MARK: - run_script

    private static func runScript(_ args: AIToolArguments, _ context: AIMutationContext) -> AIToolOutcome {
        guard let source = args.string("source") else { return .refuse(stage: "args", message: "'source' is required") }
        guard let runtime = context.scriptRuntime else { return .refuse(stage: "execute", message: "no script runtime this session") }
        let ownerToken = args.string("ref") ?? "player"
        guard let owner = context.target.resolve(alias: ownerToken) else {
            return .refuse(stage: "args", message: "no such object '\(ownerToken)'")
        }
        switch runtime.runEphemeral(source: source, owner: owner) {
        case .success(let message):
            context.journal.record(
                requestID: context.requestID, tool: "run_script", ref: owner, name: "run", tick: context.tick,
                model: context.model, afterHash: sha256Hex(source), undo: .none
            )
            return .ok("{\"ref\":\(jsonString(owner.canonical)),\"result\":\(jsonString(message))}")
        case .failure(let message):
            return .refuse(stage: "execute", message: message)
        }
    }

    static func jsonString(_ s: String) -> String { AttrValueCodec.encode(.string(s)) }
}
