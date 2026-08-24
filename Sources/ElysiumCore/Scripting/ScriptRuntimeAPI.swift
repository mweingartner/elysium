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
                "attach": { [weak runtime] handle, call in runtime?.methodAttach(handle, call) ?? .error("runtime unavailable") },
                "detach": { [weak runtime] handle, call in runtime?.methodDetach(handle, call) ?? .error("runtime unavailable") },
                "setBlock": { [weak runtime] handle, call in runtime?.methodSetBlock(handle, call) ?? .error("runtime unavailable") },
                "breakBlock": { [weak runtime] handle, _ in runtime?.methodBreakBlock(handle) ?? .error("runtime unavailable") },
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
            .function(name: "sound", HostFunction { _ in .values([]) }),
            .function(name: "particles", HostFunction { _ in .values([]) }),
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
        if case .value(let v) = BuiltInAttributes.get(live, name: k, host: host) { return .values([v]) }
        let snake = camelToSnakeAttributeName(k)
        if snake != k, case .value(let v) = BuiltInAttributes.get(live, name: snake, host: host) { return .values([v]) }
        return .values([.null])
    }

    func objectNewIndex(_ handle: HandleRef, _ key: ScriptValue, _ value: ScriptValue) -> HostResult {
        guard case .string(let name) = key, let ref = ObjectRef.parse(handle.ref) else { return .error("invalid handle") }
        return performSet(ref: ref, name: name, value: value)
    }

    func performSet(ref: ObjectRef, name rawName: String, value: ScriptValue) -> HostResult {
        guard case .live(let live) = graph.resolve(ref) else { return .error("\(ref.canonical) is not loaded") }
        let name = AttributeRegistry.resolve(kind: ref.kind, name: rawName) != nil
            ? rawName : camelToSnakeAttributeName(rawName)
        if AttributeRegistry.resolve(kind: ref.kind, name: name) != nil {
            switch BuiltInAttributes.set(live, name: name, value: value, host: host) {
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
        guard let author = currentAuthor() else { return .error("no script context") }
        switch attributeStore.set(ref, name, value, by: author) {
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
        let name = AttributeRegistry.resolve(kind: ref.kind, name: rawName) != nil
            ? rawName : camelToSnakeAttributeName(rawName)
        if AttributeRegistry.resolve(kind: ref.kind, name: name) != nil {
            if case .value(let v) = BuiltInAttributes.get(live, name: name, host: host) { return .values([v]) }
            return .values([.null])
        }
        return .values([attributeStore.get(ref, rawName) ?? .null])
    }

    func methodSet(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard call.arguments.count >= 2, case .value(.string(let name)) = call.arguments[0],
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
        guard call.arguments.count >= 2, case .value(.string(let rawName)) = call.arguments[0],
            let ref = ObjectRef.parse(handle.ref) else {
            return .error("define(name, value[, opts])")
        }
        let name = normalizedCustomAttributeName(rawName)
        guard let value = scriptValueArg(call.arguments[1]) else { return .error("unsupported value type") }
        var readonly = false
        var force = false
        if call.arguments.count >= 3, case .value(.map(let opts)) = call.arguments[2] {
            if case .bool(let b)? = opts["readonly"] { readonly = b }
            if case .bool(let b)? = opts["force"] { force = b }
        }
        guard let author = currentAuthor() else { return .error("no script context") }
        switch attributeStore.define(ref, name, value, readonly: readonly, force: force, by: author) {
        case .success: return .values([])
        case .failure(let err): return .error(attrErrorMessage(err, name: name))
        }
    }

    func methodAttach(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("attach() outside script context") }
        guard incrementAttachDetach(ctx) else { return .error("attach/detach budget exceeded this tick") }
        guard call.arguments.count >= 2, case .value(.string(let name)) = call.arguments[0],
            case .value(.string(let source)) = call.arguments[1], let ref = ObjectRef.parse(handle.ref) else {
            return .error("attach(name, source[, opts])")
        }
        var triggers: [Trigger] = []
        var isModule = true
        if call.arguments.count >= 3, case .value(.map(let opts)) = call.arguments[2] {
            if case .string(let eventName)? = opts["on"], let event = EventKind.parse(eventName) {
                var attribute: String?
                if case .string(let a)? = opts["attr"] { attribute = a }
                var target: SubscriptionTarget = .object(ref)
                if case .ref(let t)? = opts["target"], let parsedRef = ObjectRef.parse(t) { target = .object(parsedRef) }
                triggers = [Trigger(event: event, attribute: attribute, target: target)]
                isModule = false
            }
        }
        guard case .accepted = ScriptValidator.validate(source: source, chunkName: name, using: lua) else {
            return .error("script source failed validation")
        }
        let mode: ScriptMode = isModule ? .module : .handler
        switch scriptStore.attach(
            ref, name: name, source: source, mode: mode, triggers: triggers,
            by: .script(owner: ctx.owner, name: ctx.name), tick: host.currentTick
        ) {
        case .success:
            state.anyScriptsAttached = true
            state.eventBus.raise(
                kind: Self.scriptAttachedEventKind, subject: ref,
                payload: ["name": .string(name)], source: .script(owner: ctx.owner, name: ctx.name), tick: host.currentTick
            )
            return .values([.bool(true)])
        case .failure(let err):
            return .error(scriptErrorMessage(err))
        }
    }

    func methodDetach(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("detach() outside script context") }
        guard incrementAttachDetach(ctx) else { return .error("attach/detach budget exceeded this tick") }
        guard case .value(.string(let name))? = call.arguments.first, let ref = ObjectRef.parse(handle.ref) else {
            return .error("detach(name)")
        }
        switch scriptStore.detach(ref, name) {
        case .success(let existed):
            if existed { unloadScripts(for: [ref]) }
            return .values([.bool(existed)])
        case .failure(let err): return .error(scriptErrorMessage(err))
        }
    }

    func methodSetBlock(_ handle: HandleRef, _ call: HostCall) -> HostResult {
        guard case .value(.string(let name))? = call.arguments.first, let ref = ObjectRef.parse(handle.ref),
            case .block(let dim, let x, let y, let z) = ref else {
            return .error("setBlock(name[, opts]) is only valid on a block handle")
        }
        guard let w = host.world(for: dim) else { return .error("dimension not loaded") }
        guard let id = name == "air" ? UInt16(0) : bidOpt(name) else { return .error("unknown block '\(name)'") }
        _ = w.setBlock(x, y, z, id == 0 ? 0 : Int(cell(id, 0)), SET_DEFAULT)
        if call.arguments.count >= 2, case .value(.map(let opts)) = call.arguments[1],
            case .live(let live) = graph.resolve(ref) {
            for (key, value) in opts where key != "notify" {
                _ = BuiltInAttributes.set(live, name: key, value: value, host: host)
            }
        }
        return .values([.bool(true)])
    }

    func methodBreakBlock(_ handle: HandleRef) -> HostResult {
        guard let ref = ObjectRef.parse(handle.ref), case .block(let dim, let x, let y, let z) = ref,
            let w = host.world(for: dim) else {
            return .error("breakBlock() is only valid on a block handle")
        }
        w.breakBlockNaturally(x, y, z)
        return .values([.bool(true)])
    }

    // MARK: - attrs handle

    func attrsIndex(_ handle: HandleRef, _ key: ScriptValue) -> HostResult {
        guard case .string(let rawName) = key, let owner = ownerRef(fromAttrsRef: handle.ref) else { return .values([.null]) }
        let name = normalizedCustomAttributeName(rawName)
        return .values([attributeStore.get(owner, name) ?? .null])
    }

    func attrsNewIndex(_ handle: HandleRef, _ key: ScriptValue, _ value: ScriptValue) -> HostResult {
        guard case .string(let rawName) = key, let owner = ownerRef(fromAttrsRef: handle.ref) else {
            return .error("invalid attrs key")
        }
        let name = normalizedCustomAttributeName(rawName)
        guard let author = currentAuthor() else { return .error("no script context") }
        if case .null = value {
            _ = attributeStore.remove(owner, name)
            return .values([])
        }
        switch attributeStore.set(owner, name, value, by: author) {
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
        guard !isValidAttributeName(raw) else { return raw }
        return normalizedAttributeNameHint(raw) ?? raw
    }

    // MARK: - on / subscribe / every / after / wait / emit / rng / say / dim

    func hostOn(_ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("on() outside script context") }
        guard call.arguments.count >= 2, case .value(.string(let eventName)) = call.arguments[0] else {
            return .error("on(event[, opts], fn)")
        }
        guard let event = EventKind.parse(eventName) else { return .error("'\(eventName)' is not a valid event name") }
        guard case .function(let fn)? = call.arguments.last else { return .error("on() requires a function") }
        var attribute: String?
        var targetRef = ctx.owner
        if call.arguments.count == 3, case .value(.map(let opts)) = call.arguments[1] {
            if case .string(let a)? = opts["attr"] { attribute = a }
            if case .ref(let t)? = opts["target"], let parsed = ObjectRef.parse(t) { targetRef = parsed }
            if case .string(let name)? = opts["name"], isValidAttributeName(name) {
                namedHandlers[ctx.owner.canonical + "#" + ctx.name + "#" + name] = fn
            }
        }
        let token = ScriptHandlerToken(.closure(fn, owner: ctx.owner, scriptName: ctx.name))
        state.eventBus.registerScriptOwned(
            owner: ctx.owner, scriptName: ctx.name, target: .object(targetRef), event: event,
            attribute: attribute, token: token
        )
        return .values([])
    }

    func hostSubscribe(_ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("subscribe() outside script context") }
        guard call.arguments.count >= 3, case .function(let fn)? = call.arguments.last else {
            return .error("subscribe(target, event[, opts], fn)")
        }
        guard let target = subscriptionTargetArg(call.arguments[0]) else { return .error("subscribe() requires a valid target") }
        guard case .value(.string(let eventName)) = call.arguments[1], let event = EventKind.parse(eventName) else {
            return .error("subscribe() requires a valid event name")
        }
        var attribute: String?
        if call.arguments.count == 4, case .value(.map(let opts)) = call.arguments[2] {
            if case .string(let a)? = opts["attr"] { attribute = a }
        }
        let token = ScriptHandlerToken(.closure(fn, owner: ctx.owner, scriptName: ctx.name))
        state.eventBus.registerScriptOwned(
            owner: ctx.owner, scriptName: ctx.name, target: target, event: event, attribute: attribute, token: token
        )
        return .values([])
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
        guard call.arguments.count >= 2, let n = intArg(call.arguments[0]), n > 0 else {
            return .error("after/every(n, handler) requires a positive tick count")
        }
        switch call.arguments[1] {
        case .value(.string(let name)):
            guard isValidAttributeName(name) else { return .error("invalid timer handler name") }
            guard timers.count < DurableTimerRegistryCodec.maxTimersPerWorld else { return .error("too many durable timers") }
            let id = allocateTimerID()
            let wake = host.currentTick + Int64(n)
            timers.append(DurableTimer(
                id: id, owner: ctx.owner, scriptName: ctx.name, handlerName: name, wakeTick: wake,
                intervalTicks: repeating ? Int64(n) : nil
            ))
            return .values([])
        case .function(let fn):
            // Closure timers are live-only (design.md §17-8); this change
            // implements them as a one-shot `wait`-equivalent scheduled run
            // regardless of `after` vs `every` — see this file's header.
            let key = ctx.owner.canonical + "#" + ctx.name + "#timer#\(scheduleOrdinal())"
            guard let coroutine = try? lua.makeCoroutine(function: fn) else { return .error("could not schedule timer") }
            appendScheduled(key: key, coroutine: coroutine, wakeTick: host.currentTick + Int64(n))
            return .values([])
        default:
            return .error("after/every requires a handler name or function")
        }
    }

    func hostWait(_ call: HostCall) -> HostResult {
        let n = call.arguments.first.flatMap(intArg) ?? 0
        return .yield([], .wait(max(0, n)))
    }

    func hostEmit(_ call: HostCall) -> HostResult {
        guard let ctx = currentScript else { return .error("emit() outside script context") }
        guard case .value(.string(let name))? = call.arguments.first, let kind = EventKind.parse(name) else {
            return .error("emit(name[, payload][, target])")
        }
        var payload: [String: AttrValue] = [:]
        var target = ctx.owner
        if call.arguments.count >= 2, case .value(.map(let m)) = call.arguments[1] { payload = m }
        if call.arguments.count >= 3 {
            switch call.arguments[2] {
            case .handle(let h): if let r = ObjectRef.parse(h.ref) { target = r }
            case .value(.ref(let s)): if let r = ObjectRef.parse(s) { target = r }
            default: break
            }
        }
        let outcome = state.eventBus.raise(
            kind: kind, subject: target, payload: payload, source: .script(owner: ctx.owner, name: ctx.name),
            tick: host.currentTick
        )
        return .values([.bool(outcome.wasEnqueued)])
    }

    func hostRng(_ call: HostCall) -> HostResult {
        guard let ctx = currentScript, let instance = instances[ctx.owner.canonical + "#" + ctx.name] else {
            return .error("rng() outside script context")
        }
        let adapter = instance.randomAdapter
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
            return .values([.int(Int64(a) + Int64(adapter.inner.nextInt(b - a + 1)))])
        }
    }

    func hostSay(_ call: HostCall) -> HostResult {
        guard case .value(.string(let text))? = call.arguments.first else { return .error("say(text)") }
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
        guard case .value(.string(let name))? = call.arguments.first, isValidAttributeName(name) else {
            return .error("register(name, fn)")
        }
        guard case .function(let fn)? = call.arguments.dropFirst().first else {
            return .error("register(name, fn) requires a function")
        }
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
        case "player", "self": return .player
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
        guard case .value(.string(let prompt))? = call.arguments.first, prompt.utf8.count <= 4_096 else {
            return .error("ai.ask(prompt[, opts])")
        }
        return .values([.int(Int64(enqueueAIRequest(prompt: prompt)))])
    }

    func hostAIAwait(_ call: HostCall) -> HostResult {
        guard case .value(.string(let prompt))? = call.arguments.first, prompt.utf8.count <= 4_096 else {
            return .error("ai.await(prompt[, opts])")
        }
        let id = enqueueAIRequest(prompt: prompt)
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
        case .number(let d): return d.isFinite ? Int(d) : nil
        default: return nil
        }
    }

    func currentAuthor() -> Provenance.Author? {
        currentScript.map { .script(owner: $0.owner, name: $0.name) }
    }

    func incrementAttachDetach(_ ctx: (owner: ObjectRef, name: String)) -> Bool {
        let key = ctx.owner.canonical + "#" + ctx.name
        let count = attachDetachCounts[key, default: 0]
        guard count < 2 else { return false }
        attachDetachCounts[key] = count + 1
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

    func authorText(_ a: Provenance.Author) -> String {
        switch a {
        case .player: return "player"
        case .ai(let m): return "ai:\(m)"
        case .script(let owner, let name): return "script:\(owner.canonical):\(name)"
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
}
