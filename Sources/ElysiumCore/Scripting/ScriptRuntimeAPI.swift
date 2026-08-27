// ScriptRuntimeAPI.swift — script-runtime (change 1c). design.md §8.5: the
// Lua API v1 host-binding tree and the two handle kinds ("object" — every
// world/dim/block/entity/player handle; "attrs" — the live custom-attribute
// proxy `h.attrs` returns). Every closure here is `[weak self]`-captured
// (`ScriptRuntime` owns the `LuaState` that retains these closures, so a
// strong capture would be a reference cycle) and reachable only through
// `ScriptRuntime.buildHostBindings()` / the two `makeXDispatch` statics
// called once from `init`.
//
// Deviations from §8.5's literal Lua text, both forced by the shipped
// `ElysiumScript` API surface (no `__pairs`/"read global by name" hook —
// see change 0/1a's `Handles.swift`/`HostFunctions.swift`) and both
// documented in ARCHITECTURE.md's script-runtime section:
//   * `pairs(h.attrs)` iteration is not supported (the handle mechanism has
//     no `__pairs`); `h.attrs.x`/`h.attrs.x = v` (get/set) work exactly as
//     documented.
//   * A named durable timer / `/on` target resolves through a handler this
//     script registered by name via `register(name, fn)` — not a bare
//     global function lookup (Swift cannot read an arbitrary Lua global by
//     name from outside a running call).
//   * `sound(...)`/`particles(...)` are accepted (arguments validated
//     loosely) but are no-ops in 1c — not wired to the renderer/audio layer.
//   * `ai.ask`/`ai.await` are served by an injected, synchronous stub
//     responder (§9.6's own "tests inject a stub broker") rather than the
//     real Ollama tool loop, which is change 2.

import ElysiumScript
import Foundation

extension ScriptRuntime {
    // MARK: - dispatch construction (called once from `init`)

    static func makeObjectDispatch(_ runtime: ScriptRuntime) -> HandleDispatch {
        HandleDispatch(
            methods: [
                "exists": { [weak runtime] handle, _ in runtime?.methodExists(handle) ?? .values([.bool(false)]) },
                "get": { [weak runtime] handle, call in runtime?.methodGet(handle, call) ?? .values([.null]) },
                "set": { [weak runtime] handle, call in runtime?.methodSet(handle, call) ?? .error("runtime unavailable") },
                "scripts": { [weak runtime] handle, _ in runtime?.methodScripts(handle) ?? .values([.list([])]) },
                "define": { [weak runtime] handle, call in runtime?.methodDefine(handle, call) ?? .error("runtime unavailable") },
                "events": { [weak runtime] handle, call in runtime?.methodEvents(handle, call) ?? .values([.list([])]) },
                "declareEvent": { [weak runtime] handle, call in runtime?.methodDeclareEvent(handle, call) ?? .error("runtime unavailable") },
                "undeclareEvent": { [weak runtime] handle, call in runtime?.methodUndeclareEvent(handle, call) ?? .error("runtime unavailable") },
                "on": { [weak runtime] handle, call in runtime?.methodOn(handle, call) ?? .error("runtime unavailable") },
                "onAttribute": { [weak runtime] handle, call in runtime?.methodOnAttribute(handle, call) ?? .error("runtime unavailable") },
                "emit": { [weak runtime] handle, call in runtime?.methodEmit(handle, call) ?? .error("runtime unavailable") },
                "attach": { [weak runtime] handle, call in runtime?.methodAttach(handle, call) ?? .error("runtime unavailable") },
                "detach": { [weak runtime] handle, call in runtime?.methodDetach(handle, call) ?? .error("runtime unavailable") },
                "setBlock": { [weak runtime] handle, call in runtime?.methodSetBlock(handle, call) ?? .error("runtime unavailable") },
                "breakBlock": { [weak runtime] handle, call in runtime?.methodBreakBlock(handle, call) ?? .error("runtime unavailable") },
            ],
            index: { [weak runtime] handle, _, key in runtime?.objectIndex(handle, key) ?? .values([.null]) },
            newIndex: { [weak runtime] handle, _, key, value in runtime?.objectNewIndex(handle, key, value) ?? .error("runtime unavailable") }
        )
    }

    static func makeAttrsDispatch(_ runtime: ScriptRuntime) -> HandleDispatch {
        HandleDispatch(
            index: { [weak runtime] handle, _, key in runtime?.attrsIndex(handle, key) ?? .values([.null]) },
            newIndex: { [weak runtime] handle, _, key, value in runtime?.attrsNewIndex(handle, key, value) ?? .error("runtime unavailable") }
        )
    }

    // MARK: - top-level host bindings (self/world/player are injected as call
    // arguments by the wrapping preamble — see `ScriptRuntime.load`/
    // `compileForRun` — everything else here is a genuine frozen HostBinding)

    func buildHostBindings() -> [HostBinding] {
        [
            .function(name: "on", HostFunction { [weak self] call in self?.hostOn(call) ?? .error("runtime unavailable") }),
            .function(name: "subscribe", HostFunction { [weak self] call in self?.hostSubscribe(call) ?? .error("runtime unavailable") }),
            .function(name: "every", HostFunction { [weak self] call in self?.hostEvery(call) ?? .error("runtime unavailable") }),
            .function(name: "after", HostFunction { [weak self] call in self?.hostAfter(call) ?? .error("runtime unavailable") }),
            .function(name: "wait", HostFunction { [weak self] call in self?.hostWait(call) ?? .error("runtime unavailable") }),
            .function(name: "emit", HostFunction { [weak self] call in self?.hostEmit(call) ?? .error("runtime unavailable") }),
            .function(name: "tick", HostFunction { [weak self] _ in .values([.int(self?.host.currentTick ?? 0)]) }),
            .function(name: "rng", HostFunction { [weak self] call in self?.hostRng(call) ?? .error("runtime unavailable") }),
            .function(name: "say", HostFunction { [weak self] call in self?.hostSay(call) ?? .error("runtime unavailable") }),
            .function(name: "sound", HostFunction { [weak self] _ in
                guard self?.unloadActive != true else { return .error("sound() is not available during unload") }
                return .values([])
            }),
            .function(name: "particles", HostFunction { [weak self] _ in
                guard self?.unloadActive != true else { return .error("particles() is not available during unload") }
                return .values([])
            }),
            .function(name: "dim", HostFunction { [weak self] call in self?.hostDim(call) ?? .values([.null]) }),
            .function(name: "register", HostFunction { [weak self] call in self?.hostRegister(call) ?? .error("runtime unavailable") }),
            .table(name: "objects", [
                .function(name: "get", HostFunction { [weak self] call in self?.objectsGet(call) ?? .values([.null]) }),
                .function(name: "find", HostFunction { [weak self] call in self?.objectsFind(call) ?? .values([.list([])]) }),
                .function(name: "block", HostFunction { [weak self] call in self?.objectsBlock(call) ?? .values([.null]) }),
            ]),
            .table(name: "ai", [
                .function(name: "ask", HostFunction { [weak self] call in self?.hostAIAsk(call) ?? .error("runtime unavailable") }),
                .function(name: "await", HostFunction { [weak self] call in self?.hostAIAwait(call) ?? .error("runtime unavailable") }),
            ]),
        ]
    }

    // MARK: - object handle: property-style index/newIndex

    func objectIndex(_ handle: HandleRef, _ key: ScriptValue) -> HostResult {
        guard case .string(let k) = key, let ref = ObjectRef.parse(handle.ref) else { return .values([.null]) }
        switch k {
        case "ref": return .values([.string(ref.canonical)])
        case "kind": return .values([.string(ref.kind.rawValue)])
        case "name": return .values([.string(graph.displayName(of: ref))])
        case "attrs": return .values([attrsHandleValue(for: ref)])
        default: break
        }
        guard case .live(let live) = graph.resolve(ref) else { return .values([.null]) }
        // Lenient GET (design.md §6.0): an unknown/inapplicable name reads
        // as `nil`, matching `h.attrs`'s own fallback and `/attr get`'s
        // built-in path. §8.5's own Lua examples spell built-ins camelCase
        // (`ev.subject.maxHealth`) while the registry's canonical names are
        // snake_case (`max_health`, `AttributeRegistry.swift`); this runtime
        // accepts either spelling for a built-in name — a snake_case-first
        // lookup, camelCase retried on a miss — documented in
        // ARCHITECTURE.md's script-runtime section.
        if let descriptor = resolveLuaBuiltIn(kind: ref.kind, rawName: k),
           case .value(let value) = BuiltInAttributes.get(
               live, name: descriptor.canonical, host: host
           ) {
            return .values([value])
        }
        return .values([.null])
    }

    func objectNewIndex(_ handle: HandleRef, _ key: ScriptValue, _ value: ScriptValue) -> HostResult {
        guard case .string(let name) = key, let ref = ObjectRef.parse(handle.ref) else { return .error("invalid handle") }
        return performSet(ref: ref, name: name, value: value)
    }

    func performSet(ref: ObjectRef, name rawName: String, value: ScriptValue) -> HostResult {
        // Check/dry-run resolves the same live object and executes the shared built-in/custom
        // preflight below, but commits neither engine state nor an ObjectRecord candidate. A bad
        // name, value, readonly/collision rule, or storage cap therefore fails exactly as it does
        // live instead of being hidden by the read-only facade.
        guard case .live(let live) = graph.resolve(ref) else { return .error("\(ref.canonical) is not loaded") }
        guard let author = currentAuthor() else { return .error("no script context") }
        if let descriptor = resolveLuaBuiltIn(kind: ref.kind, rawName: rawName) {
            guard !unloadActive else {
                return .error("built-in attributes are not writable during unload")
            }
            let name = descriptor.canonical
            let outcome = dryRunActive
                ? BuiltInAttributes.validateSet(live, name: name, value: value, host: host)
                : host.setScriptBuiltInAttribute(
                    live, ref: ref, name: name, value: value, author: author
                )
            switch outcome {
            case .ok: return .values([])
            case .unknownName(let suggestions):
                let hint = suggestions.isEmpty ? "" : " (did you mean: \(suggestions.joined(separator: ", ")))"
                return .error("unknown built-in attribute '\(name)'\(hint)")
            case .notApplicable: return .error("'\(name)' is not an attribute here")
            case .readOnly: return .error("'\(name)' is readonly")
            case .wrongValueKind: return .error("'\(name)' does not accept that value")
            case .outOfRange(let range): return .error("'\(name)' must be in \(range)")
            }
        }
        let name = customAttributeStorageName(for: ref, rawName: rawName)
        let outcome = dryRunActive
            ? attributeStore.validateSet(ref, name, value, by: author)
            : attributeStore.set(ref, name, value, by: author)
        switch outcome {
        case .success: return .values([])
        case .failure(let err): return .error(attrErrorMessage(err, name: name))
        }
    }

    // MARK: - object handle: methods

    func methodExists(_ handle: HandleRef) -> HostResult {
        guard let ref = ObjectRef.parse(handle.ref) else { return .values([.bool(false)]) }
        if case .live = graph.resolve(ref) { return .values([.bool(true)]) }
        return .values([.bool(false)])
    }

    func methodGet(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard case .value(.string(let rawName))? = call.arguments.first, let ref = ObjectRef.parse(handle.ref) else {
            return .values([.null])
        }
        guard case .live(let live) = graph.resolve(ref) else { return .values([.null]) }
        if let descriptor = resolveLuaBuiltIn(kind: ref.kind, rawName: rawName) {
            if case .value(let v) = BuiltInAttributes.get(
                live, name: descriptor.canonical, host: host
            ) { return .values([v]) }
            return .values([.null])
        }
        return .values([customAttributeValue(for: ref, rawName: rawName) ?? .null])
    }

    func methodSet(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard call.arguments.count == 2, case .value(.string(let name)) = call.arguments[0],
            let ref = ObjectRef.parse(handle.ref) else {
            return .error("set(name, value) requires a name and a value")
        }
        guard let value = scriptValueArg(call.arguments[1]) else { return .error("unsupported value type") }
        return performSet(ref: ref, name: name, value: value)
    }

    func methodScripts(_ handle: HandleRef) -> HostResult {
        guard let ref = ObjectRef.parse(handle.ref) else { return .values([.list([])]) }
        let list = scriptStore.list(ref).map { s -> ScriptValue in
            .map([
                "name": .string(s.name), "mode": .string(s.mode.rawValue),
                "enabled": .bool(s.enabled), "author": .string(authorText(s.author)),
                "lastError": s.lastError.map { .string($0) } ?? .null,
            ])
        }
        return .values([.list(list)])
    }

    func methodDefine(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard (2...3).contains(call.arguments.count),
            case .value(.string(let rawName)) = call.arguments[0],
            let ref = ObjectRef.parse(handle.ref) else {
            return .error("define(name, value[, opts])")
        }
        let name = customAttributeStorageName(for: ref, rawName: rawName)
        guard let value = scriptValueArg(call.arguments[1]) else { return .error("unsupported value type") }
        var readonly = false
        var force = false
        if call.arguments.count == 3 {
            let options: [String: ScriptValue]
            switch call.arguments[2] {
            case .value(.list(let values)) where values.isEmpty:
                options = [:]
            case .value(.map(let map)):
                options = map
            default:
                return .error("define options must be a table")
            }
            let allowed = Set(["readonly", "force"])
            if let unknown = options.keys.sorted(by: utf8Less).first(where: { !allowed.contains($0) }) {
                return .error("unknown define option '\(unknown)'")
            }
            if let value = options["readonly"] {
                guard case .bool(let parsed) = value else {
                    return .error("define option 'readonly' must be a boolean")
                }
                readonly = parsed
            }
            if let value = options["force"] {
                guard case .bool(let parsed) = value else {
                    return .error("define option 'force' must be a boolean")
                }
                force = parsed
            }
        }
        guard let author = currentAuthor() else { return .error("no script context") }
        let outcome = dryRunActive
            ? attributeStore.validateDefine(
                ref, name, value, readonly: readonly, force: force, by: author
            )
            : attributeStore.define(
                ref, name, value, readonly: readonly, force: force, by: author
            )
        switch outcome {
        case .success: return .values([])
        case .failure(let err): return .error(attrErrorMessage(err, name: name))
        }
    }

    func methodEvents(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard call.arguments.isEmpty else { return .error("events() takes no arguments") }
        guard let ref = ObjectRef.parse(handle.ref) else { return .values([.list([])]) }
        let declarations = customEventStore.list(ref).map { declaration -> ScriptValue in
            let fields = declaration.fields.map { field -> ScriptValue in
                .map([
                    "name": .string(field.name),
                    "type": .string(field.typeToken),
                    "nullable": .bool(field.isNullable),
                ])
            }
            return .map([
                "name": .string(declaration.kind.rawValue),
                "fields": .list(fields),
                "summary": declaration.summary.map(ScriptValue.string) ?? .null,
                "author": .string(authorText(declaration.provenance.createdBy)),
                "createdTick": .int(declaration.provenance.createdTick),
            ])
        }
        return .values([.list(declarations)])
    }

    func methodDeclareEvent(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("declareEvent() outside script context") }
        guard !unloadActive else { return .error("declareEvent() is not available during unload") }
        guard !ephemeralRunActive else {
            return .error("declareEvent() is not available during ephemeral run")
        }
        guard (1...3).contains(call.arguments.count),
              case .value(.string(let name)) = call.arguments[0],
              let ref = ObjectRef.parse(handle.ref) else {
            return .error("declareEvent(name[, fields][, summary])")
        }
        var fields: [CustomEventField] = []
        if call.arguments.count >= 2 {
            switch call.arguments[1] {
            case .value(.list(let values)) where values.isEmpty:
                break // Lua's empty table crosses the boundary as an empty list.
            case .value(.map(let schema)):
                for fieldName in schema.keys.sorted(by: utf8Less) {
                    guard case .string(let token)? = schema[fieldName],
                          let field = CustomEventField(name: fieldName, typeToken: token) else {
                        return .error("event field '\(fieldName)' requires a valid type token")
                    }
                    fields.append(field)
                }
            default:
                return .error("declareEvent fields must be a table mapping names to type tokens")
            }
        }
        var summary: String?
        if call.arguments.count >= 3 {
            guard case .value(.string(let text)) = call.arguments[2] else {
                return .error("declareEvent summary must be a string")
            }
            summary = text
        }
        // Check validates the exact contract but never writes it or spends the real lifecycle
        // budget. The store's shared validator is exercised through a throwaway declaration call
        // only in live mode, so perform the pure validation explicitly here.
        if case .failure(let error) = validateCustomEventDeclaration(
            name: name, fields: fields, summary: summary, caps: customEventStore.caps
        ) {
            return .error(customEventValidationMessage(error, name: name))
        }
        guard !dryRunActive else { return .values([.bool(true)]) }
        if let existing = customEventStore.get(ref, name),
           existing.hasSameContract(fields: fields, summary: summary) {
            // Modules commonly publish their contract on every load. An identical declaration is
            // metadata idempotence, not a lifecycle mutation, so it must not consume the shared
            // attach/detach budget during a large world reload.
            return .values([.bool(true)])
        }
        guard incrementEventDeclarations(ctx) else {
            return .error("event declaration mutation budget exceeded this tick")
        }
        switch customEventStore.declare(
            ref, name: name, fields: fields, summary: summary,
            by: .script(owner: ctx.owner, name: ctx.name)
        ) {
        case .success: return .values([.bool(true)])
        case .failure(let error): return .error(customEventStoreErrorMessage(error, name: name))
        }
    }

    func methodUndeclareEvent(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("undeclareEvent() outside script context") }
        guard !unloadActive else { return .error("undeclareEvent() is not available during unload") }
        guard !ephemeralRunActive else {
            return .error("undeclareEvent() is not available during ephemeral run")
        }
        guard call.arguments.count == 1 else { return .error("undeclareEvent(name)") }
        guard case .value(.string(let name)) = call.arguments[0],
              EventKind.parse(name) != nil, let ref = ObjectRef.parse(handle.ref) else {
            return .error("undeclareEvent(name) requires a valid event name")
        }
        guard !dryRunActive else { return .values([.bool(false)]) }
        guard customEventStore.get(ref, name) != nil else { return .values([.bool(false)]) }
        guard incrementEventDeclarations(ctx) else {
            return .error("event declaration mutation budget exceeded this tick")
        }
        switch customEventStore.undeclare(ref, name) {
        case .success(let existed): return .values([.bool(existed)])
        case .failure(let error): return .error(customEventStoreErrorMessage(error, name: name))
        }
    }

    func methodOn(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard let target = ObjectRef.parse(handle.ref) else { return .error("invalid object handle") }
        return registerObjectHandler(target: target, call: call, attributeOverride: nil)
    }

    func methodOnAttribute(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard let target = ObjectRef.parse(handle.ref),
              call.arguments.count == 2,
              case .value(.string(let rawName)) = call.arguments[0],
              case .function = call.arguments[1] else {
            return .error("onAttribute(name, fn)")
        }
        guard let name = attributeFilterNames(
            rawName, target: .object(target)
        ).first else { return .error("'\(rawName)' is not a valid attribute name") }
        return registerObjectHandler(target: target, call: HostCall(
            arguments: [.value(.string(EventKind.attributeChanged.rawValue)), call.arguments[1]],
            environment: call.environment, state: call.state
        ), attributeOverride: name)
    }

    private func registerObjectHandler(
        target: ObjectRef, call: HostCall, attributeOverride: String?
    ) -> HostResult {
        guard let ctx = currentScript else { return .error("on() outside script context") }
        guard !unloadActive else { return .error("on() is not available during unload") }
        guard !ephemeralRunActive else { return .error("on() is not available during ephemeral run") }
        guard (2...3).contains(call.arguments.count),
              case .value(.string(let eventName)) = call.arguments[0] else {
            return .error("on(event[, opts], fn)")
        }
        guard let event = EventKind.parse(eventName) else {
            return .error("'\(eventName)' is not a valid event name")
        }
        guard case .function(let fn)? = call.arguments.last else {
            return .error("on() requires a function")
        }

        let options: TopLevelHandlerOptions
        if let attributeOverride {
            // `onAttribute` has already resolved its shorthand name. It still crosses the same
            // EventBus shape validator as `h:on`, including during Check/dry-run.
            let target = SubscriptionTarget.object(target)
            if let error = EventBus.validateSubscriptionShape(
                target, event: event, attribute: attributeOverride
            ) {
                return .error(scriptOwnedSubscriptionErrorMessage(error, owner: ctx.owner))
            }
            options = TopLevelHandlerOptions(
                target: target, attributes: [attributeOverride], namedHandler: nil
            )
        } else {
            let validatedOptions = validateTopLevelHandlerOptions(
                call.arguments.count == 3 ? call.arguments[1] : nil,
                callName: "h:on", defaultTarget: .object(target), event: event, owner: ctx.owner,
                allowsTarget: false, allowsName: true
            )
            switch validatedOptions {
            case .accepted(let accepted): options = accepted
            case .refused(let message): return .error(message)
            }
        }

        guard !dryRunActive else { return .values([]) }
        let token = ScriptHandlerToken(.closure(fn, owner: ctx.owner, scriptName: ctx.name))
        if let error = registerScriptOwnedHandlers(
            owner: ctx.owner, scriptName: ctx.name, target: options.target, event: event,
            attributes: options.attributes, token: token
        ) {
            return .error(scriptOwnedSubscriptionErrorMessage(error, owner: ctx.owner))
        }
        if let namedHandler = options.namedHandler {
            namedHandlers[ctx.owner.canonical + "#" + ctx.name + "#" + namedHandler] = fn
        }
        return .values([])
    }

    func methodEmit(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard (1...2).contains(call.arguments.count) else {
            return .error("h:emit(name[, payload])")
        }
        guard let target = ObjectRef.parse(handle.ref) else { return .error("invalid object handle") }
        return emitEvent(call, target: target)
    }

    private enum NestedAttachOptionsValidation {
        case accepted(mode: ScriptMode, triggers: [Trigger])
        case refused(String)
    }

    /// Parses the complete `h:attach` option surface before either dry-run success or live
    /// lifecycle accounting. Lua's empty table marshals as an empty list, so that one list shape
    /// is the only non-map accepted here. Everything else fails closed instead of silently
    /// degrading a mistyped handler request into a module attachment.
    private func validateNestedAttachOptions(
        _ argument: ScriptArgument?, receiver: ObjectRef, owner: ObjectRef
    ) -> NestedAttachOptionsValidation {
        guard let argument else { return .accepted(mode: .module, triggers: []) }

        let options: [String: ScriptValue]
        switch argument {
        case .value(.list(let values)) where values.isEmpty:
            return .accepted(mode: .module, triggers: [])
        case .value(.map(let map)):
            options = map
        default:
            return .refused("attach options must be a table")
        }
        guard !options.isEmpty else { return .accepted(mode: .module, triggers: []) }

        let allowed = Set(["on", "attr", "target"])
        if let unknown = options.keys.sorted(by: utf8Less).first(where: { !allowed.contains($0) }) {
            return .refused("unknown attach option '\(unknown)'")
        }
        guard let onValue = options["on"] else {
            return .refused("nonempty attach options require opts.on")
        }
        guard case .string(let eventName) = onValue else {
            return .refused("attach option 'on' must be an event name string")
        }
        guard let event = EventKind.parse(eventName) else {
            return .refused("'\(eventName)' is not a valid event name")
        }

        var targetRef = receiver
        if let targetValue = options["target"] {
            guard case .ref(let targetText) = targetValue,
                  let parsedTarget = ObjectRef.parse(targetText) else {
                return .refused("attach option 'target' must be an object handle")
            }
            targetRef = parsedTarget
        }

        var attribute: String?
        if let attributeValue = options["attr"] {
            guard case .string(let raw) = attributeValue else {
                return .refused("attach option 'attr' must be an attribute name string")
            }
            guard let resolved = attributeFilterNames(raw, target: .object(targetRef)).first else {
                return .refused("'\(raw)' is not a valid attribute name")
            }
            attribute = resolved
        }

        let target = SubscriptionTarget.object(targetRef)
        if let error = EventBus.validateSubscriptionShape(target, event: event, attribute: attribute) {
            return .refused(scriptOwnedSubscriptionErrorMessage(error, owner: owner))
        }
        return .accepted(
            mode: .handler,
            triggers: [Trigger(event: event, attribute: attribute, target: target)]
        )
    }

    func methodAttach(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("attach() outside script context") }
        guard !unloadActive else { return .error("attach() is not available during unload") }
        guard !ephemeralRunActive else { return .error("attach() is not available during ephemeral run") }
        guard (2...3).contains(call.arguments.count),
            case .value(.string(let name)) = call.arguments[0],
            case .value(.string(let source)) = call.arguments[1], let ref = ObjectRef.parse(handle.ref) else {
            return .error("attach(name, source[, opts])")
        }
        let validatedOptions = validateNestedAttachOptions(
            call.arguments.count == 3 ? call.arguments[2] : nil,
            receiver: ref, owner: ctx.owner
        )
        let mode: ScriptMode
        let triggers: [Trigger]
        switch validatedOptions {
        case .accepted(let acceptedMode, let acceptedTriggers):
            mode = acceptedMode
            triggers = acceptedTriggers
        case .refused(let message):
            return .error(message)
        }
        guard case .accepted = ScriptValidator.validate(source: source, chunkName: name, using: lua) else {
            return .error("script source failed validation")
        }
        // Check/dry-run validates exactly the same nested source and options as live execution,
        // but never persists the child or spends the real attach/detach budget.
        guard !dryRunActive else { return .values([.bool(true)]) }
        guard incrementAttachDetach(ctx) else { return .error("attach/detach budget exceeded this tick") }
        switch scriptStore.attach(
            ref, name: name, source: source, mode: mode, triggers: triggers,
            by: .script(owner: ctx.owner, name: ctx.name), tick: host.currentTick
        ) {
        case .success:
            state.anyScriptsAttached = true
            state.eventBus.raise(
                kind: Self.scriptAttachedEventKind, subject: ref,
                payload: ["name": .string(name)], source: .script(owner: ctx.owner, name: ctx.name),
                tick: host.currentTick, subjectType: eventSubjectType(for: ref)
            )
            return .values([.bool(true)])
        case .failure(let err):
            return .error(scriptErrorMessage(err))
        }
    }

    func methodDetach(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("detach() outside script context") }
        guard !unloadActive else { return .error("detach() is not available during unload") }
        guard !ephemeralRunActive else { return .error("detach() is not available during ephemeral run") }
        guard call.arguments.count == 1,
              case .value(.string(let name)) = call.arguments[0],
              let ref = ObjectRef.parse(handle.ref) else {
            return .error("detach(name)")
        }
        guard !dryRunActive else { return .values([.bool(false)]) }
        guard incrementAttachDetach(ctx) else { return .error("attach/detach budget exceeded this tick") }
        switch scriptStore.detach(ref, name) {
        case .success(let existed):
            return .values([.bool(existed)])
        case .failure(let err): return .error(scriptErrorMessage(err))
        }
    }

    private struct PrevalidatedBlockMutation {
        var y: Int
        var cell: Int
    }

    private enum BlockMutationPlanValidation {
        case accepted([PrevalidatedBlockMutation])
        case refused(String)
    }

    private enum BlockOptionValueValidation {
        case accepted(Int)
        case wrongValueKind
        case outOfRange(String)
    }

    /// Validates one mutable block-state field against a prospective cell and returns the next
    /// cell without touching the world. Applicability and mutability are checked by the caller;
    /// this layer separates type/enum failures from the bounded integer ranges the codec encodes.
    private func preflightBlockOptionValue(
        cell currentCell: Int, descriptor: AttributeDescriptor, value: ScriptValue
    ) -> BlockOptionValueValidation {
        switch descriptor.valueKind {
        case .bool:
            guard case .bool = value else { return .wrongValueKind }
        case .int:
            guard case .int(let integer) = value else { return .wrongValueKind }
            let range: ClosedRange<Int64>?
            let displayRange: String?
            switch descriptor.canonical {
            case "meta": (range, displayRange) = (0...15, "0...15")
            case "delay": (range, displayRange) = (1...4, "1...4")
            case "age": (range, displayRange) = (0...7, "0...7")
            case "layers": (range, displayRange) = (1...8, "1...8")
            case "count": (range, displayRange) = (1...4, "1...4")
            default: (range, displayRange) = (nil, nil)
            }
            if let range, let displayRange, !range.contains(integer) {
                return .outOfRange(displayRange)
            }
        case .enumeration:
            // The descriptor carries the union used for authoring help, while the codec owns the
            // narrower concrete-cell enum (and the door-specific upper/lower half spellings).
            guard case .string = value else { return .wrongValueKind }
        default:
            return .wrongValueKind
        }

        let encoded: UInt16?
        if descriptor.canonical == "lit" {
            guard case .bool(let on) = value else { return .wrongValueKind }
            encoded = BlockStateCodec.encodeLitSwap(currentCell, on: on)
        } else {
            encoded = BlockStateCodec.encode(
                currentCell, field: descriptor.canonical, value: value
            )
        }
        guard let encoded else { return .wrongValueKind }
        return .accepted(Int(encoded))
    }

    /// Builds every cell write for `block:setBlock` in memory. The target replacement and every
    /// sorted option see the same prospective state that the former mutate-then-validate loop
    /// exposed, including door open/hinge redirection, but no world hook runs until the complete
    /// option set has passed name, applicability, mutability, type, and range checks.
    private func preflightBlockMutation(
        world: World, chunk: Chunk, x: Int, y: Int, z: Int, newID: UInt16,
        options: [String: ScriptValue]
    ) -> BlockMutationPlanValidation {
        let oldCell = world.getBlock(x, y, z)
        let oldID = oldCell >> 4
        let baseCell = Int(cell(newID, 0))
        let newIDInt = Int(newID)

        var blockEntityType = chunk.getBlockEntity(
            posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)
        )?.type
        if oldID != newIDInt,
           oldID >= 0, oldID < blockDefs.count,
           newIDInt >= 0, newIDInt < blockDefs.count,
           (blockDefs[oldID].shape != blockDefs[newIDInt].shape || !blockDefs[newIDInt].solid) {
            blockEntityType = nil
        }

        var plannedCells: [Int: Int] = [y: baseCell]
        var touchedY: [Int] = [y]
        for key in options.keys.sorted(by: utf8Less) where key != "notify" {
            guard let value = options[key],
                  let descriptor = resolveLuaBuiltIn(kind: .block, rawName: key) else {
                return .refused("'\(key)' is not a block attribute")
            }
            guard let targetCell = plannedCells[y] else {
                return .refused("block mutation preflight lost its target cell")
            }
            let targetID = targetCell >> 4
            guard targetID >= 0, targetID < blockDefs.count else {
                return .refused("'\(descriptor.canonical)' does not apply to this block")
            }
            let applicability = AttributeApplicabilityContext.block(
                shape: blockDefs[targetID].shape,
                name: blockDefs[targetID].name,
                blockEntityType: blockEntityType
            )
            guard AttributeRegistry.applies(descriptor, in: applicability) else {
                return .refused("'\(descriptor.canonical)' does not apply to this block")
            }
            guard descriptor.mutability == .getSet else {
                return .refused("'\(descriptor.canonical)' is readonly")
            }

            var mutationY = y
            if blockDefs[targetID].shape == .door {
                let isUpper = BlockStateCodec.isDoorUpperHalf(targetCell)
                if descriptor.canonical == "open", isUpper { mutationY = y - 1 }
                if descriptor.canonical == "hinge", !isUpper { mutationY = y + 1 }
            }
            let currentMutationCell = plannedCells[mutationY] ?? world.getBlock(x, mutationY, z)
            switch preflightBlockOptionValue(
                cell: currentMutationCell, descriptor: descriptor, value: value
            ) {
            case .accepted(let nextCell):
                if plannedCells[mutationY] == nil { touchedY.append(mutationY) }
                plannedCells[mutationY] = nextCell
            case .wrongValueKind:
                return .refused("'\(descriptor.canonical)' does not accept that value")
            case .outOfRange(let range):
                return .refused("'\(descriptor.canonical)' must be in \(range)")
            }
        }
        return .accepted(touchedY.compactMap { mutationY in
            plannedCells[mutationY].map {
                PrevalidatedBlockMutation(y: mutationY, cell: $0)
            }
        })
    }

    func methodSetBlock(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard (1...2).contains(call.arguments.count),
            case .value(.string(let name))? = call.arguments.first, let ref = ObjectRef.parse(handle.ref),
            case .block(let dim, let x, let y, let z) = ref else {
            return .error("setBlock(name[, opts]) is only valid on a block handle")
        }
        guard !unloadActive else { return .error("setBlock() is not available during unload") }
        guard let w = host.world(for: dim) else { return .error("dimension not loaded") }
        guard let id = name == "air" ? UInt16(0) : bidOpt(name) else { return .error("unknown block '\(name)'") }
        let options: [String: ScriptValue]
        if call.arguments.count == 2 {
            switch call.arguments[1] {
            case .value(.list(let values)) where values.isEmpty:
                options = [:]
            case .value(.map(let map)):
                options = map
            default:
                return .error("setBlock options must be a table")
            }
        } else {
            options = [:]
        }
        guard case .live(.block(_, let chunk, _, _, _, _)) = graph.resolve(ref) else {
            return .error("block is not loaded")
        }
        let validatedPlan = preflightBlockMutation(
            world: w, chunk: chunk, x: x, y: y, z: z, newID: id, options: options
        )
        let plan: [PrevalidatedBlockMutation]
        switch validatedPlan {
        case .accepted(let accepted): plan = accepted
        case .refused(let message): return .error(message)
        }
        guard !dryRunActive else { return .values([.bool(true)]) }
        guard let author = currentAuthor() else { return .error("no script context") }
        for mutation in plan {
            host.commitPrevalidatedScriptBlockCell(
                w, x: x, y: mutation.y, z: z, cell: mutation.cell, author: author
            )
        }
        return .values([.bool(true)])
    }

    func methodBreakBlock(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard call.arguments.isEmpty else { return .error("breakBlock() takes no arguments") }
        guard let ref = ObjectRef.parse(handle.ref), case .block(let dim, let x, let y, let z) = ref,
            let w = host.world(for: dim) else {
            return .error("breakBlock() is only valid on a block handle")
        }
        guard !unloadActive else { return .error("breakBlock() is not available during unload") }
        guard !dryRunActive else { return .values([.bool(true)]) }
        w.breakBlockNaturally(x, y, z)
        return .values([.bool(true)])
    }

    // MARK: - attrs handle

    func attrsIndex(_ handle: HandleRef, _ key: ScriptValue) -> HostResult {
        guard case .string(let rawName) = key, let owner = ownerRef(fromAttrsRef: handle.ref) else { return .values([.null]) }
        return .values([customAttributeValue(for: owner, rawName: rawName) ?? .null])
    }

    func attrsNewIndex(_ handle: HandleRef, _ key: ScriptValue, _ value: ScriptValue) -> HostResult {
        guard case .string(let rawName) = key, let owner = ownerRef(fromAttrsRef: handle.ref) else {
            return .error("invalid attrs key")
        }
        let name = customAttributeStorageName(for: owner, rawName: rawName)
        guard let author = currentAuthor() else { return .error("no script context") }
        if case .null = value {
            let outcome = dryRunActive
                ? attributeStore.validateRemove(owner, name)
                : attributeStore.remove(owner, name, by: author)
            switch outcome {
            case .success: return .values([])
            case .failure(let err): return .error(attrErrorMessage(err, name: name))
            }
        }
        let outcome = dryRunActive
            ? attributeStore.validateSet(owner, name, value, by: author)
            : attributeStore.set(owner, name, value, by: author)
        switch outcome {
        case .success: return .values([])
        case .failure(let err): return .error(attrErrorMessage(err, name: name))
        }
    }

    /// §6.1: "AI-supplied names are normalized (`HealthLamp` -> `health_lamp`)
    /// rather than refused" — Appendix A's own scripts lean on the same
    /// leniency for the `h.attrs.<name>` sugar (`self.attrs.lastHealth`),
    /// so this runtime extends it to every script-authored custom attribute
    /// name, not only the AI tool loop's. Falls back to the raw name (which
    /// will then be refused with the usual diagnostic) only in the
    /// unreachable case where normalization itself produces nothing valid.
    func normalizedCustomAttributeName(_ raw: String) -> String {
        normalizedScriptCustomAttributeName(raw)
    }

    /// New Lua-authored names persist as canonical snake_case. Before that rule shipped,
    /// camelCase sugar was folded to collapsed lowercase (`doorRef` -> `doorref`). Keep the
    /// legacy spelling as a deterministic second candidate so existing worlds remain readable;
    /// an exact canonical entry always wins when both exist.
    func customAttributeNameCandidates(_ raw: String) -> [String] {
        let canonical = normalizedCustomAttributeName(raw)
        var names: [String] = []
        if isValidAttributeName(canonical) { names.append(canonical) }
        if let legacy = normalizedAttributeNameHint(raw), isValidAttributeName(legacy),
           !names.contains(legacy) {
            names.append(legacy)
        }
        return names
    }

    func resolveLuaBuiltIn(kind: ObjectKind, rawName: String) -> AttributeDescriptor? {
        if let descriptor = AttributeRegistry.resolve(kind: kind, name: rawName) {
            return descriptor
        }
        let canonical = camelToSnakeAttributeName(rawName)
        guard canonical != rawName else { return nil }
        return AttributeRegistry.resolve(kind: kind, name: canonical)
    }

    func occupiedCustomAttributeName(for ref: ObjectRef, rawName: String) -> String? {
        guard let record = attributeStore.record(ref) else { return nil }
        return customAttributeNameCandidates(rawName).first { record.entries[$0] != nil }
    }

    func customAttributeValue(for ref: ObjectRef, rawName: String) -> AttrValue? {
        guard let name = occupiedCustomAttributeName(for: ref, rawName: rawName),
              let record = attributeStore.record(ref),
              case .value(let value, _, _)? = record.entries[name] else { return nil }
        return value
    }

    /// Writes keep using an existing canonical or legacy value entry instead of forking one
    /// logical camelCase name into two persisted keys. With no prior entry, the first (canonical)
    /// candidate is used. Script records do participate in name selection so the shared namespace
    /// collision is refused at the same canonical-or-legacy key the prior runtime would have used.
    func customAttributeStorageName(for ref: ObjectRef, rawName: String) -> String {
        let candidates = customAttributeNameCandidates(rawName)
        if let occupied = occupiedCustomAttributeName(for: ref, rawName: rawName) { return occupied }
        return candidates.first ?? rawName
    }

    /// Exact-object filters follow the first occupied canonical/legacy slot. Kind-wide filters
    /// store one canonical spelling; EventBus performs its bounded legacy-collapsed comparison at
    /// delivery so compatibility never doubles subscription capacity or index entries.
    func attributeFilterNames(_ raw: String, target: SubscriptionTarget) -> [String] {
        if let kind = subscriptionTargetKind(target),
           let descriptor = resolveLuaBuiltIn(kind: kind, rawName: raw) {
            return [descriptor.canonical]
        }
        let candidates = customAttributeNameCandidates(raw)
        if case .object(let ref) = target,
           let occupied = occupiedCustomAttributeName(for: ref, rawName: raw) {
            return [occupied]
        }
        if let canonical = candidates.first {
            return [canonical]
        }
        return []
    }

    // MARK: - on / subscribe / every / after / wait / emit / rng / say / dim

    private struct TopLevelHandlerOptions {
        var target: SubscriptionTarget
        var attributes: [String?]
        var namedHandler: String?
    }

    private enum TopLevelHandlerOptionsValidation {
        case accepted(TopLevelHandlerOptions)
        case refused(String)
    }

    /// Global `on` and `subscribe` share this pure parser so Check/dry-run reaches the same option
    /// and EventBus-shape boundary as live registration without retaining a throwaway closure.
    private func validateTopLevelHandlerOptions(
        _ argument: ScriptArgument?, callName: String, defaultTarget: SubscriptionTarget,
        event: EventKind, owner: ObjectRef, allowsTarget: Bool, allowsName: Bool
    ) -> TopLevelHandlerOptionsValidation {
        var options: [String: ScriptValue] = [:]
        if let argument {
            switch argument {
            case .value(.list(let values)) where values.isEmpty:
                break
            case .value(.map(let map)):
                options = map
            default:
                return .refused("\(callName) options must be a table")
            }
        }

        var allowed = Set(["attr"])
        if allowsTarget { allowed.insert("target") }
        if allowsName { allowed.insert("name") }
        if let unknown = options.keys.sorted(by: utf8Less).first(where: { !allowed.contains($0) }) {
            return .refused("unknown \(callName) option '\(unknown)'")
        }

        var target = defaultTarget
        if let targetValue = options["target"] {
            guard case .ref(let targetText) = targetValue,
                  let targetRef = ObjectRef.parse(targetText) else {
                return .refused("\(callName) option 'target' must be an object handle")
            }
            target = .object(targetRef)
        }

        var attributes: [String?] = [nil]
        if let attributeValue = options["attr"] {
            guard case .string(let raw) = attributeValue else {
                return .refused("\(callName) option 'attr' must be an attribute name string")
            }
            let names = attributeFilterNames(raw, target: target)
            guard !names.isEmpty else { return .refused("'\(raw)' is not a valid attribute name") }
            attributes = names.map(Optional.some)
        }

        var namedHandler: String?
        if let nameValue = options["name"] {
            guard case .string(let name) = nameValue, isValidAttributeName(name) else {
                return .refused("\(callName) option 'name' must be a valid handler name")
            }
            namedHandler = name
        }

        for attribute in attributes {
            if let error = EventBus.validateSubscriptionShape(
                target, event: event, attribute: attribute
            ) {
                return .refused(scriptOwnedSubscriptionErrorMessage(error, owner: owner))
            }
        }
        return .accepted(TopLevelHandlerOptions(
            target: target, attributes: attributes, namedHandler: namedHandler
        ))
    }

    func hostOn(_ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("on() outside script context") }
        guard !unloadActive else { return .error("on() is not available during unload") }
        guard !ephemeralRunActive else { return .error("on() is not available during ephemeral run") }
        guard (2...3).contains(call.arguments.count),
              case .value(.string(let eventName)) = call.arguments[0] else {
            return .error("on(event[, opts], fn)")
        }
        guard let event = EventKind.parse(eventName) else { return .error("'\(eventName)' is not a valid event name") }
        guard case .function(let fn)? = call.arguments.last else { return .error("on() requires a function") }
        let validatedOptions = validateTopLevelHandlerOptions(
            call.arguments.count == 3 ? call.arguments[1] : nil,
            callName: "on", defaultTarget: .object(ctx.owner), event: event, owner: ctx.owner,
            allowsTarget: true, allowsName: true
        )
        let options: TopLevelHandlerOptions
        switch validatedOptions {
        case .accepted(let accepted): options = accepted
        case .refused(let message): return .error(message)
        }
        // A dry run's closure dies with its throwaway environment — never
        // register it on the real (persistent) event bus. Parsing and shape
        // validation above are still authoritative Check failures.
        guard !dryRunActive else { return .values([]) }
        let token = ScriptHandlerToken(.closure(fn, owner: ctx.owner, scriptName: ctx.name))
        if let error = registerScriptOwnedHandlers(
            owner: ctx.owner, scriptName: ctx.name, target: options.target, event: event,
            attributes: options.attributes, token: token
        ) {
            return .error(scriptOwnedSubscriptionErrorMessage(error, owner: ctx.owner))
        }
        if let namedHandler = options.namedHandler {
            namedHandlers[ctx.owner.canonical + "#" + ctx.name + "#" + namedHandler] = fn
        }
        return .values([])
    }

    func hostSubscribe(_ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("subscribe() outside script context") }
        guard !unloadActive else { return .error("subscribe() is not available during unload") }
        guard !ephemeralRunActive else { return .error("subscribe() is not available during ephemeral run") }
        guard (3...4).contains(call.arguments.count),
              case .function(let fn)? = call.arguments.last else {
            return .error("subscribe(target, event[, opts], fn)")
        }
        guard let target = subscriptionTargetArg(call.arguments[0]) else { return .error("subscribe() requires a valid target") }
        guard case .value(.string(let eventName)) = call.arguments[1], let event = EventKind.parse(eventName) else {
            return .error("subscribe() requires a valid event name")
        }
        let validatedOptions = validateTopLevelHandlerOptions(
            call.arguments.count == 4 ? call.arguments[2] : nil,
            callName: "subscribe", defaultTarget: target, event: event, owner: ctx.owner,
            allowsTarget: false, allowsName: false
        )
        let options: TopLevelHandlerOptions
        switch validatedOptions {
        case .accepted(let accepted): options = accepted
        case .refused(let message): return .error(message)
        }
        guard !dryRunActive else { return .values([]) }
        let token = ScriptHandlerToken(.closure(fn, owner: ctx.owner, scriptName: ctx.name))
        if let error = registerScriptOwnedHandlers(
            owner: ctx.owner, scriptName: ctx.name, target: options.target, event: event,
            attributes: options.attributes, token: token
        ) {
            return .error(scriptOwnedSubscriptionErrorMessage(error, owner: ctx.owner))
        }
        return .values([])
    }

    /// Registers the already-resolved filter list atomically. The current compatibility model uses
    /// one physical filter, but keeping this transactional boundary prevents future multi-filter
    /// extensions from leaving a partially active handler after an admission refusal.
    func registerScriptOwnedHandlers(
        owner: ObjectRef, scriptName: String, target: SubscriptionTarget, event: EventKind,
        attributes: [String?], token: AnyObject?
    ) -> EventBus.SubscribeError? {
        var registeredIDs: [UInt64] = []
        for attribute in attributes {
            switch state.eventBus.registerScriptOwnedChecked(
                owner: owner, scriptName: scriptName, target: target, event: event,
                attribute: attribute, token: token
            ) {
            case .success(let subscription):
                registeredIDs.append(subscription.id)
            case .failure(let error):
                for id in registeredIDs { state.eventBus.unregisterScriptOwned(id: id) }
                return error
            }
        }
        return nil
    }

    func scriptOwnedSubscriptionErrorMessage(
        _ error: EventBus.SubscribeError, owner: ObjectRef
    ) -> String {
        switch error {
        case .tooManyForWorld:
            return "too many subscriptions in this world (limit \(state.eventBus.caps.maxSubscriptionsPerWorld))"
        case .tooManyForObject:
            return "too many subscriptions on \(owner.canonical) (limit \(state.eventBus.caps.maxSubscriptionsPerObject))"
        case .targetRequiresTypeFilter:
            return "block.changed and attribute.changed require a block type filter"
        case .anyNotAllowedForThisEvent:
            return "any is not allowed for block.changed or attribute.changed"
        case .attributeFilterNotAllowed:
            return "an attribute filter is valid only for attribute.changed"
        case .invalidAttributeFilter:
            return "the attribute filter is not a canonical built-in or custom attribute name"
        case .eventNotApplicable:
            return "the event does not apply to that target kind"
        case .eventNotAvailable:
            return "the event is reserved and has no producer"
        }
    }

    private func subscriptionTargetArg(_ arg: ScriptArgument) -> SubscriptionTarget? {
        switch arg {
        case .handle(let h): return ObjectRef.parse(h.ref).map { .object($0) }
        case .value(.ref(let s)): return ObjectRef.parse(s).map { .object($0) }
        case .value(.map(let m)):
            guard case .string(let k)? = m["kind"], let kind = ObjectKind(rawValue: k) else { return nil }
            if case .string(let t)? = m["type"] { return .kind(kind, typeFilter: t) }
            return .kind(kind, typeFilter: nil)
        case .value(.string("any")): return .any
        default: return nil
        }
    }

    func hostAfter(_ call: HostCall) -> HostResult { scheduleTimer(call, repeating: false) }
    func hostEvery(_ call: HostCall) -> HostResult { scheduleTimer(call, repeating: true) }

    private func scheduleTimer(_ call: HostCall, repeating: Bool) -> HostResult {
        guard let ctx = currentScript else { return .error("timer outside script context") }
        guard !unloadActive else { return .error("timers are not available during unload") }
        guard !ephemeralRunActive else { return .error("timers are not available during ephemeral run") }
        guard call.arguments.count >= 2, let n = intArg(call.arguments[0]), n > 0 else {
            return .error("after/every(n, handler) requires a positive tick count")
        }
        // A dry run must never leave a durable timer, or a live scheduled
        // coroutine referencing its throwaway (about-to-be-destroyed)
        // environment, behind — both branches below are no-ops here.
        guard !dryRunActive else { return .values([]) }
        switch call.arguments[1] {
        case .value(.string(let name)):
            guard isValidAttributeName(name) else { return .error("invalid timer handler name") }
            let interval = repeating ? Int64(n) : nil
            let scriptKey = ctx.owner.canonical + "#" + ctx.name
            if let instance = instances[scriptKey], !instance.live,
               timers.contains(where: {
                   $0.owner == ctx.owner && $0.scriptName == ctx.name
                       && $0.handlerName == name && $0.intervalTicks == interval
                        && instance.timerIDsAtLoadStart.contains($0.id)
               }) {
                // Module reloads repopulate handler functions but must not duplicate the durable
                // registry entry that survived chunk/app unload.
                return .values([])
            }
            guard timers.count < DurableTimerRegistryCodec.maxTimersPerWorld else { return .error("too many durable timers") }
            let id = allocateTimerID()
            let wake = scheduledTick(after: Int64(n))
            timers.append(DurableTimer(
                id: id, owner: ctx.owner, scriptName: ctx.name, handlerName: name, wakeTick: wake,
                intervalTicks: interval
            ))
            return .values([])
        case .function(let fn):
            // Closure timers are live-only (design.md §17-8); this change
            // implements them as a one-shot `wait`-equivalent scheduled run
            // regardless of `after` vs `every` — see this file's header.
            let key = ctx.owner.canonical + "#" + ctx.name + "#timer#\(scheduleOrdinal())"
            guard let coroutine = try? lua.makeCoroutine(function: fn) else { return .error("could not schedule timer") }
            guard appendScheduled(
                key: key, coroutine: coroutine, wakeTick: scheduledTick(after: Int64(n))
            ) else {
                return .error("suspended coroutine limit exceeded")
            }
            return .values([])
        default:
            return .error("after/every requires a handler name or function")
        }
    }

    func hostWait(_ call: HostCall) -> HostResult {
        guard !unloadActive else { return .error("wait() is not available during unload") }
        guard !ephemeralRunActive else { return .error("wait() is not available during ephemeral run") }
        let n = call.arguments.first.flatMap(intArg) ?? 0
        return .yield([], .wait(max(0, n)))
    }

    func hostEmit(_ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("emit() outside script context") }
        guard (1...3).contains(call.arguments.count) else {
            return .error("emit(name[, payload][, target])")
        }
        var target = ctx.owner
        if call.arguments.count == 3 {
            guard case .handle(let handle) = call.arguments[2],
                  let explicitTarget = ObjectRef.parse(handle.ref) else {
                return .error("emit target must be an object handle")
            }
            target = explicitTarget
        }
        return emitEvent(call, target: target)
    }

    private func emitEvent(_ call: HostCall, target: ObjectRef) -> HostResult {
        guard let ctx = currentScript else { return .error("emit() outside script context") }
        guard !unloadActive else { return .error("emit() is not available during unload") }
        guard case .value(.string(let name))? = call.arguments.first, let kind = EventKind.parse(name) else {
            return .error("emit(name[, payload][, target])")
        }
        guard case .live(let live) = graph.resolve(target) else {
            return .error("cannot emit on \(target.canonical) because it is not loaded")
        }
        var payload: [String: AttrValue] = [:]
        if call.arguments.count >= 2 {
            switch call.arguments[1] {
            case .value(.map(let map)): payload = map
            case .value(.list(let values)) where values.isEmpty: break
            default: return .error("event payload must be a string-keyed table")
            }
        }
        if let error = AttrValueCodec.validate(.map(payload), caps: customEventStore.caps) {
            return .error("event payload rejected (\(error.message))")
        }
        if let refusal = ScriptEventEmissionValidator.refusal(
            kind: kind, subject: target, payload: payload,
            declaration: customEventStore.get(target, name)
        ) {
            return .error(refusal)
        }
        guard !dryRunActive else { return .values([.bool(true)]) }
        let outcome = state.eventBus.raise(
            kind: kind, subject: target, payload: payload, source: .script(owner: ctx.owner, name: ctx.name),
            tick: host.currentTick, subjectType: familyName(live)
        )
        return .values([.bool(outcome.wasEnqueued)])
    }

    func hostRng(_ call: HostCall) -> HostResult {
        guard !unloadActive else { return .error("rng() is not available during unload") }
        guard let ctx = currentScript else {
            return .error("rng() outside script context")
        }
        let adapter: RandomStreamBoxAdapter
        if let transientExecutionRandom {
            adapter = transientExecutionRandom
        } else if let instance = instances[ctx.owner.canonical + "#" + ctx.name] {
            adapter = instance.randomAdapter
        } else {
            return .error("rng() outside script context")
        }
        func draw01() -> Double { Double(adapter.inner.next()) / 4_294_967_296.0 }
        switch call.arguments.count {
        case 0:
            return .values([.number(draw01())])
        case 1:
            guard let n = intArg(call.arguments[0]), n > 0 else { return .error("rng(n) requires a positive integer") }
            return .values([.int(Int64(adapter.inner.nextInt(n)) + 1)])
        default:
            guard let a = intArg(call.arguments[0]), let b = intArg(call.arguments[1]), a <= b else {
                return .error("rng(a, b) requires a <= b")
            }
            let (distance, subtractOverflow) = b.subtractingReportingOverflow(a)
            let (span, addOverflow) = distance.addingReportingOverflow(1)
            guard !subtractOverflow, !addOverflow, span > 0 else {
                return .error("rng(a, b) range is too large")
            }
            return .values([.int(Int64(a) + Int64(adapter.inner.nextInt(span)))])
        }
    }

    func hostSay(_ call: HostCall) -> HostResult {
        guard case .value(.string(let text))? = call.arguments.first else { return .error("say(text)") }
        guard !unloadActive else { return .error("say() is not available during unload") }
        guard !dryRunActive else { return .values([]) }
        sayFn(ScriptingDisplayText.line(text))
        return .values([])
    }

    func hostDim(_ call: HostCall) -> HostResult {
        guard case .value(.string(let name))? = call.arguments.first, let d = dimFromCanonicalName(name) else {
            return .error("dim(name) expects 'overworld', 'nether' or 'end'")
        }
        return .values([handleValue(for: .dimension(d))])
    }

    func hostRegister(_ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("register() outside script context") }
        guard !unloadActive else { return .error("register() is not available during unload") }
        guard !ephemeralRunActive else { return .error("register() is not available during ephemeral run") }
        guard case .value(.string(let name))? = call.arguments.first, isValidAttributeName(name) else {
            return .error("register(name, fn)")
        }
        guard case .function(let fn)? = call.arguments.dropFirst().first else {
            return .error("register(name, fn) requires a function")
        }
        // A dry run's registered function is tied to a throwaway
        // environment that is destroyed the instant `dryRun` returns —
        // never remember it (nothing durable would ever be able to call it
        // anyway; `after`/`every`/`/on` are themselves no-ops here).
        guard !dryRunActive else { return .values([]) }
        namedHandlers[ctx.owner.canonical + "#" + ctx.name + "#" + name] = fn
        return .values([])
    }

    // MARK: - objects.get / objects.find / objects.block

    func objectsGet(_ call: HostCall) -> HostResult {
        guard let arg = call.arguments.first else { return .values([.null]) }
        let ref: ObjectRef?
        switch arg {
        case .value(.string(let s)): ref = resolveAlias(s)
        case .handle(let h): ref = ObjectRef.parse(h.ref)
        default: ref = nil
        }
        guard let ref, case .live = graph.resolve(ref) else { return .values([.null]) }
        return .values([handleValue(for: ref)])
    }

    private func resolveAlias(_ s: String) -> ObjectRef? {
        switch s {
        case "self": return currentScript?.owner
        case "player": return .player
        case "world": return .world
        default: return ObjectRef.parse(s)
        }
    }

    func objectsBlock(_ call: HostCall) -> HostResult {
        guard call.arguments.count >= 4, case .value(.string(let dimName)) = call.arguments[0],
            let dim = dimFromCanonicalName(dimName), let x = intArg(call.arguments[1]),
            let y = intArg(call.arguments[2]), let z = intArg(call.arguments[3]) else {
            return .error("objects.block(dim, x, y, z)")
        }
        let ref = ObjectRef.block(dim: dim, x: x, y: y, z: z)
        guard ref.isWithinBounds else { return .error("block position is out of bounds") }
        return .values([handleValue(for: ref)])
    }

    func objectsFind(_ call: HostCall) -> HostResult {
        guard case .value(.map(let opts))? = call.arguments.first else { return .values([.list([])]) }
        var kinds: Set<ObjectKind>?
        if case .string(let k)? = opts["kind"], let ok = ObjectKind(rawValue: k) { kinds = [ok] }
        var typeFilter: String?
        if case .string(let t)? = opts["type"] { typeFilter = t }
        var center: (Double, Double, Double)?
        if case .ref(let nearRef)? = opts["near"], let parsed = ObjectRef.parse(nearRef) {
            center = position(of: parsed)
        } else if let ctx = currentScript {
            center = position(of: ctx.owner)
        }
        guard let center else { return .values([.list([])]) }
        var radius = 16.0
        if case .int(let r)? = opts["radius"] { radius = Double(r) }
        if case .number(let r)? = opts["radius"] { radius = r }
        var limit = 32
        if case .int(let l)? = opts["limit"] { limit = Int(l) }

        // `ObjectGraph.objectsNear` (change 1a) only enumerates blocks that
        // already carry a non-empty `ObjectRecord` — correct for "objects
        // with scripts/attrs near me", but Appendix A script 4 ("equip
        // nearby plain oak signs") needs *any* block of a given type,
        // scripted or not. Rather than widen 1a's already-shipped/tested
        // `objectsNear` (a materially more expensive scan for its existing
        // callers too), a type-filtered block search does its own bounded
        // raw-block scan here — additive, and only taken when `type` is
        // given (an unfiltered block search still goes through
        // `objectsNear`'s cheaper record-only path, matching design.md's
        // own "objects with a record" reading of a bare `kind="block"`
        // query).
        if kinds == [.block], let typeFilter {
            return .values([.list(findRawBlocksByType(
                typeFilter, near: center, radius: min(max(radius, 0), 16), limit: min(max(limit, 0), 64)
            ))])
        }

        let entries = graph.objectsNear(x: center.0, y: center.1, z: center.2, radius: radius, limit: limit, kinds: kinds)
        var results: [ScriptValue] = []
        for entry in entries {
            if let typeFilter, familyName(entry.liveObject) != typeFilter { continue }
            results.append(handleValue(for: entry.ref))
        }
        return .values([.list(results)])
    }

    /// Bounded cube scan (see `objectsFind`'s own comment) over every block
    /// in `radius` of `center`, sorted by squared distance then canonical
    /// ref (matching `ObjectGraph.objectsNear`'s own tie-break) — never
    /// loads a chunk, skips positions in an unloaded one.
    private func findRawBlocksByType(
        _ typeFilter: String, near center: (Double, Double, Double), radius: Double, limit: Int
    ) -> [ScriptValue] {
        guard let w = host.world(for: host.currentDimension), radius > 0, limit > 0 else { return [] }
        let r2 = radius * radius
        let minX = Int((center.0 - radius).rounded(.down)), maxX = Int((center.0 + radius).rounded(.up))
        let minY = Int((center.1 - radius).rounded(.down)), maxY = Int((center.1 + radius).rounded(.up))
        let minZ = Int((center.2 - radius).rounded(.down)), maxZ = Int((center.2 + radius).rounded(.up))
        var found: [(ref: ObjectRef, d2: Double)] = []
        guard minX <= maxX, minY <= maxY, minZ <= maxZ else { return [] }
        for x in minX...maxX {
            for z in minZ...maxZ {
                let cx = floorDiv(x, CHUNK_W), cz = floorDiv(z, CHUNK_W)
                guard let chunk = w.getChunk(cx, cz) else { continue }
                for y in minY...maxY {
                    guard y >= w.info.minY, y < w.info.minY + w.info.height else { continue }
                    let dx = Double(x) + 0.5 - center.0, dy = Double(y) + 0.5 - center.1, dz = Double(z) + 0.5 - center.2
                    let d2 = dx * dx + dy * dy + dz * dz
                    guard d2 <= r2 else { continue }
                    let cell = Int(chunk.get(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)))
                    let id = cell >> 4
                    guard id > 0, id < blockDefs.count, blockDefs[id].name == typeFilter else { continue }
                    found.append((.block(dim: host.currentDimension, x: x, y: y, z: z), d2))
                }
            }
        }
        found.sort { a, b in a.d2 == b.d2 ? a.ref.canonical < b.ref.canonical : a.d2 < b.d2 }
        return found.prefix(limit).map { handleValue(for: $0.ref) }
    }

    // MARK: - ai.ask / ai.await

    func hostAIAsk(_ call: HostCall) -> HostResult {
        guard !unloadActive else { return .error("ai.ask() is not available during unload") }
        guard !ephemeralRunActive else { return .error("ai.ask() is not available during ephemeral run") }
        guard case .value(.string(let prompt))? = call.arguments.first, prompt.utf8.count <= 4_096 else {
            return .error("ai.ask(prompt[, opts])")
        }
        // design.md §9.4 stage 6: "no AI" during a dry run.
        guard !dryRunActive else { return .values([.int(0)]) }
        // design.md §8.4: over budget -> `ai.replied{error="budget"}`,
        // delivered the same way a timed-out reply would be (no request is
        // ever actually made) — `ai.ask` is fire-and-forget, so this fires
        // immediately rather than waiting for a phase to drain anything.
        guard aiBudgetAvailable() else {
            state.eventBus.raise(
                kind: .aiReplied, subject: .world,
                payload: ["requestId": .int(0), "text": .null, "error": .string("budget")],
                source: .engine, tick: host.currentTick
            )
            return .values([.int(0)])
        }
        return .values([.int(Int64(enqueueAIRequest(
            prompt: prompt, mode: .ask
        )))])
    }

    func hostAIAwait(_ call: HostCall) -> HostResult {
        guard !unloadActive else { return .error("ai.await() is not available during unload") }
        guard !ephemeralRunActive else { return .error("ai.await() is not available during ephemeral run") }
        guard case .value(.string(let prompt))? = call.arguments.first, prompt.utf8.count <= 4_096 else {
            return .error("ai.await(prompt[, opts])")
        }
        // Never contact AI from validation. Yield a synthetic token so dryRun can recognize the
        // attached script's legal suspension point and close its throwaway coroutine immediately.
        guard !dryRunActive else { return .yield([], .await(0)) }
        guard aiBudgetAvailable() else { return .values([.null, .string("budget")]) }
        let id = enqueueAIRequest(prompt: prompt, mode: .await)
        return .yield([], .await(id))
    }

    // MARK: - small shared helpers

    /// "maxHealth" -> "max_health" (lowercase, `_` inserted at a lower-to-
    /// upper boundary) — mirrors `AttributeRegistry`'s own private
    /// `normalizeForMatch` (duplicated rather than shared/exposed, per this
    /// package's existing precedent for small per-file helpers of this
    /// shape).
    func camelToSnakeAttributeName(_ s: String) -> String {
        var out = ""
        var previousLower = false
        for ch in s {
            if ch.isUppercase && previousLower { out.append("_") }
            out.append(Character(ch.lowercased()))
            previousLower = ch.isLowercase
        }
        return out
    }

    func scriptValueArg(_ arg: ScriptArgument) -> ScriptValue? {
        switch arg {
        case .value(let v): return v
        case .handle(let h): return .ref(h.ref)
        default: return nil
        }
    }

    func intArg(_ a: ScriptArgument) -> Int? {
        guard case .value(let v) = a else { return nil }
        switch v {
        case .int(let i): return Int(i)
        case .number(let d):
            // `Int(Double)` traps for finite-but-out-of-range values. Numeric script input is
            // untrusted; reject it before conversion. `Double(Int.max)` rounds upward on 64-bit,
            // hence the strict upper comparison. Exact large integers travel as `.int` above.
            guard d.isFinite, d >= Double(Int.min), d < Double(Int.max) else { return nil }
            return Int(d)
        default: return nil
        }
    }

    func currentAuthor() -> Provenance.Author? {
        currentScript.map { .script(owner: $0.owner, name: $0.name) }
    }

    func incrementAttachDetach(_ ctx: (owner: ObjectRef, name: String)) -> Bool {
        refreshAttachDetachBudget()
        let key = ctx.owner.canonical + "#" + ctx.name
        let count = attachDetachCounts[key, default: 0]
        guard count < 2, attachDetachWorldCount < 32 else { return false }
        attachDetachCounts[key] = count + 1
        attachDetachWorldCount += 1
        return true
    }

    func incrementEventDeclarations(_ ctx: (owner: ObjectRef, name: String)) -> Bool {
        refreshEventDeclarationBudget()
        let key = ctx.owner.canonical + "#" + ctx.name
        let count = eventDeclarationCounts[key, default: 0]
        guard count < customEventStore.caps.maxEventDeclarationsPerObject else { return false }
        eventDeclarationCounts[key] = count + 1
        return true
    }

    func position(of ref: ObjectRef) -> (Double, Double, Double)? {
        switch graph.resolve(ref) {
        case .live(.block(_, _, _, let x, let y, let z)): return (Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5)
        case .live(.entity(let e, _)): return (e.x, e.y, e.z)
        case .live(.player(let p, _)): return (p.x, p.y, p.z)
        default: return nil
        }
    }

    /// The raw family name a `type=` filter matches against — a block's
    /// registered id name, an entity's `type`, `"player"` — mirrors
    /// `ScriptingCommands`'s own private `familyName` (duplicated rather
    /// than shared, matching this package's existing precedent for small
    /// per-file helpers of this shape).
    func familyName(_ live: LiveObject) -> String {
        switch live {
        case .world: return "world"
        case .dimension(let w): return dimCanonicalName(w.dim)
        case .block(_, let chunk, _, let x, let y, let z):
            let cell = Int(chunk.get(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)))
            let id = cell >> 4
            return (id >= 0 && id < blockDefs.count) ? blockDefs[id].name : "block"
        case .entity(let e, _): return e.type
        case .player: return "player"
        }
    }

    /// EventBus kind subscriptions with a `type=` filter match the concrete family carried at
    /// raise time. Lifecycle events are emitted from several runtime paths, so centralizing the
    /// live lookup prevents block/entity load, fault, timer, and attach events from silently losing
    /// their type identity.
    func eventSubjectType(for ref: ObjectRef) -> String? {
        guard case .live(let live) = graph.resolve(ref) else { return nil }
        return familyName(live)
    }

    func authorText(_ a: Provenance.Author) -> String {
        switch a {
        case .player: return "player"
        case .ai(let m): return "ai:\(m)"
        case .script(let owner, let name): return "script:\(owner.canonical):\(name)"
        case .lan(let peer): return "lan:\(peer)"
        }
    }

    func attrErrorMessage(_ err: AttributeError, name: String) -> String {
        switch err {
        case .objectNotLive: return "object is not loaded"
        case .dormant: return "object's dimension is not loaded"
        case .unsupported: return "unsupported object"
        case .invalidName(let hint):
            return hint.map { "'\(name)' is not a valid attribute name — try '\($0)'" } ?? "'\(name)' is not a valid attribute name"
        case .nameIsBuiltIn: return "'\(name)' is a built-in attribute — set it directly"
        case .nameIsScript: return "'\(name)' is an attached script — detach it first"
        case .invalidValue(let e): return "value rejected (\(e.message))"
        case .readonly: return "'\(name)' is readonly"
        case .tooManyEntries(let limit): return "too many attributes (limit \(limit))"
        case .recordTooLarge, .chunkTooLarge, .documentTooLarge: return "attribute storage limit exceeded"
        case .lanClient: return "scripts do not run on LAN clients"
        case .revisionOverflow: return "revision limit reached"
        }
    }

    func scriptErrorMessage(_ err: ScriptStoreError) -> String {
        scriptStoreErrorText(err)
    }

    func customEventValidationMessage(
        _ error: CustomEventDeclarationValidationError, name: String
    ) -> String {
        switch error {
        case .invalidEventName: return "'\(name)' is not a valid custom event name"
        case .builtInEventName: return "'\(name)' is a built-in event and cannot be redeclared"
        case .tooManyFields(let limit): return "event schema exceeds \(limit) fields"
        case .invalidFieldName(let field): return "'\(field)' is not a valid event field name"
        case .reservedFieldName(let field): return "'\(field)' is a reserved event envelope field"
        case .duplicateFieldName(let field): return "event field '\(field)' is duplicated"
        case .summaryTooLarge(let limit): return "event summary exceeds \(limit) UTF-8 bytes"
        case .invalidSummary: return "event summary contains unsupported text"
        }
    }

    func customEventStoreErrorMessage(_ error: CustomEventStoreError, name: String) -> String {
        switch error {
        case .objectNotLive: return "object is not loaded"
        case .dormant: return "object's dimension is not loaded"
        case .unsupported: return "unsupported object"
        case .lanClient: return "event declarations are host-authoritative"
        case .invalidEventName: return "'\(name)' is not a valid custom event name"
        case .builtInEventName: return "'\(name)' is a built-in event and cannot be redeclared"
        case .tooManyDeclarations(let limit): return "too many event declarations (limit \(limit))"
        case .tooManyFields(let limit): return "event schema exceeds \(limit) fields"
        case .invalidFieldName(let field): return "'\(field)' is not a valid event field name"
        case .reservedFieldName(let field): return "'\(field)' is a reserved event envelope field"
        case .duplicateFieldName(let field): return "event field '\(field)' is duplicated"
        case .summaryTooLarge(let limit): return "event summary exceeds \(limit) UTF-8 bytes"
        case .invalidSummary: return "event summary contains unsupported text"
        case .tooManyEntries(let limit): return "object scripting storage exceeds \(limit) entries"
        case .recordTooLarge, .chunkTooLarge, .documentTooLarge:
            return "event declaration storage limit exceeded"
        case .revisionOverflow: return "revision limit reached"
        }
    }
}
