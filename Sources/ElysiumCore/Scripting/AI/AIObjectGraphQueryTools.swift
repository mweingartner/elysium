// AIObjectGraphQueryTools.swift — ai-object-graph (change 2). design.md §9.2:
// "how the AI sees everything" — list/inspect objects, read attributes/
// scripts/events, deterministic, sorted, bounded output. Every function here
// is pure with respect to game state (never mutates, never journaled) and
// answers from the same `ObjectGraph`/`AttributeStore`/`ScriptStore`/
// `EventBus`/`AttributeRegistry` the player-facing commands use — the AI
// sees exactly what `/inspect`/`/attr`/`/script`/`/events` can show, no more,
// no less (§9.7: nothing here reaches `World`/`SaveDB` directly).

import Foundation

/// The read-only bundle every query tool needs — a strict subset of
/// `ScriptingCommandContext` (no `scriptRuntime`/kill-switch/trust-gate
/// setters; queries never need them).
public struct AIQueryContext {
    public let graph: ObjectGraph
    public let store: AttributeStore
    public let scriptStore: ScriptStore
    public let eventBus: EventBus
    public let target: ObjectTargetContext
    /// `nil` on a LAN client or when `LuaState` construction failed this
    /// session — `check_script` degrades to a size-only summary in that case
    /// (matches `/script run`'s own "no script runtime this session" refusal
    /// discipline rather than pretending validation ran).
    public let scriptRuntime: ScriptRuntime?

    public init(
        graph: ObjectGraph, store: AttributeStore, scriptStore: ScriptStore, eventBus: EventBus,
        target: ObjectTargetContext, scriptRuntime: ScriptRuntime?
    ) {
        self.graph = graph
        self.store = store
        self.scriptStore = scriptStore
        self.eventBus = eventBus
        self.target = target
        self.scriptRuntime = scriptRuntime
    }
}

public enum AIObjectGraphQueryTools {
    /// The full declared tool list a "scripting"-lane request can call —
    /// consumed by the app layer to build the Ollama tool schema and by
    /// `AIToolLoop` to validate a call names something real before dispatch.
    public static let definitions: [AIToolDefinition] = [
        AIToolDefinition(
            name: "list_objects", kind: .query,
            summary: "List nearby objects (blocks with attrs/scripts, entities, players), optionally filtered by kind/type.",
            parameters: [
                .init(name: "kind", type: "string", summary: "block | entity | player | world | dim", enumValues: ["block", "entity", "player", "world", "dim"]),
                .init(name: "near", type: "string", summary: "A ref or 'player' to center the search on (default player)."),
                .init(name: "radius", type: "integer", summary: "Search radius, <= 48 (default 16).", minimum: 0, maximum: 48),
                .init(name: "type", type: "string", summary: "Family name filter (block id, entity type)."),
                .init(name: "hasScripts", type: "boolean", summary: "Only objects that have at least one script."),
                .init(name: "limit", type: "integer", summary: "Max results, <= 64 (default 16).", minimum: 1, maximum: 64),
            ]
        ),
        AIToolDefinition(
            name: "get_object", kind: .query, summary: "Get a single object's built-in attributes, custom attrs, script summaries, and subscription count.",
            parameters: [.init(name: "ref", type: "string", summary: "Object ref or alias (looking, self, player, world, dim:<name>, or a canonical ref).")],
            required: ["ref"]
        ),
        AIToolDefinition(
            name: "describe_attributes", kind: .query, summary: "List built-in attribute descriptors for a kind or a specific object.",
            parameters: [
                .init(name: "kind", type: "string", summary: "block | entity | player | world | dim"),
                .init(name: "ref", type: "string", summary: "An object ref, to also show applicability for that specific object."),
            ]
        ),
        AIToolDefinition(
            name: "describe_events", kind: .query, summary: "List the v1 event catalog, optionally filtered by prefix.",
            parameters: [.init(name: "kind", type: "string", summary: "Prefix filter, e.g. 'block' or 'player'.")]
        ),
        // design.md §9.1's tool-lane budget ("<= 20 tools"): `list_scripts`
        // and `get_script` are one tool here (matching the design's own
        // one-table-row grouping of the two) — omit `name` to list every
        // script on `ref`; pass it to get that one script's full source.
        AIToolDefinition(
            name: "list_scripts", kind: .query, summary: "List the scripts on an object, or (with 'name') get one script's full source/triggers/last error.",
            parameters: [
                .init(name: "ref", type: "string", summary: "Object ref or alias."),
                .init(name: "name", type: "string", summary: "Script name — when given, returns that one script's full detail instead of the list."),
            ], required: ["ref"]
        ),
        AIToolDefinition(
            name: "check_script", kind: .query, summary: "Validate Lua source (compile + lint) without attaching or storing it.",
            parameters: [.init(name: "source", type: "string", summary: "Lua source text, <= 16 KiB.")], required: ["source"]
        ),
        AIToolDefinition(
            name: "list_subscriptions", kind: .query, summary: "List persisted event subscriptions for an object.",
            parameters: [.init(name: "ref", type: "string", summary: "Object ref or alias.")], required: ["ref"]
        ),
        AIToolDefinition(
            name: "search_registry", kind: .query, summary: "Search block/item/entity/effect registries by substring.",
            parameters: [
                .init(name: "kind", type: "string", summary: "block | item | entity | effect", enumValues: ["block", "item", "entity", "effect"]),
                .init(name: "query", type: "string", summary: "Substring to search for."),
            ], required: ["kind", "query"]
        ),
        AIToolDefinition(
            name: "inspect_event_path", kind: .query, summary: "List who would receive an event raised on an object right now.",
            parameters: [
                .init(name: "ref", type: "string", summary: "Object ref or alias."),
                .init(name: "event", type: "string", summary: "Event kind, e.g. 'attribute.changed'."),
            ], required: ["ref", "event"]
        ),
        AIToolDefinition(
            name: "recent_events", kind: .query, summary: "List recent events (bounded ring; position changes excluded).",
            parameters: [
                .init(name: "ref", type: "string", summary: "Filter to one object's ref."),
                .init(name: "kind", type: "string", summary: "Filter to one event kind."),
                .init(name: "limit", type: "integer", summary: "Max results, <= 32 (default 16).", minimum: 1, maximum: 32),
            ]
        ),
    ]

    static let byteCap = 8 * 1024
    static let scriptByteCap = 16 * 1024

    public static func run(_ name: String, args: AIToolArguments, context: AIQueryContext) -> AIToolOutcome {
        switch name {
        case "list_objects": return listObjects(args, context)
        case "get_object": return getObject(args, context)
        case "describe_attributes": return describeAttributes(args, context)
        case "describe_events": return describeEvents(args, context)
        case "list_scripts": return args.string("name") != nil ? getScript(args, context) : listScripts(args, context)
        case "check_script": return checkScript(args, context)
        case "list_subscriptions": return listSubscriptions(args, context)
        case "search_registry": return searchRegistry(args, context)
        case "inspect_event_path": return inspectEventPath(args, context)
        case "recent_events": return recentEvents(args, context)
        default: return .refuse(stage: "args", message: "'\(name)' is not a known tool")
        }
    }

    // MARK: - shared

    private static func resolveRefArg(_ args: AIToolArguments, _ key: String, _ context: AIQueryContext) -> Result<(ObjectRef, LiveObject), AIToolOutcome> {
        guard let token = args.string(key) else {
            return .failure(.refuse(stage: "args", message: "'\(key)' is required"))
        }
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

    private static func bounded(_ text: String, cap: Int) -> String {
        guard text.utf8.count > cap else { return text }
        // Truncate on a UTF-8-safe boundary and note it, rather than emit
        // invalid UTF-8 or silently drop bytes off a JSON structure — the
        // caller (`list_objects`/`recent_events`) already keeps result
        // counts within `limit`, so this only ever fires on pathological
        // input (e.g. an oversize `get_object` display name); documented as
        // a last-resort backstop, not the primary bounding mechanism (that
        // is `limit`/`radius` clamps on every tool that can grow unbounded).
        var truncated = text
        while truncated.utf8.count > cap, let last = truncated.unicodeScalars.last {
            truncated.unicodeScalars.removeLast()
            _ = last
        }
        return truncated + "…(truncated)"
    }

    private static func familyName(_ live: LiveObject) -> String {
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

    // MARK: - list_objects

    private static func listObjects(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        var kinds: Set<ObjectKind>?
        if let k = args.string("kind") {
            guard let kind = ObjectKind(rawValue: k) else {
                return .refuse(stage: "args", message: "'\(k)' is not a valid kind", hint: "block, entity, player, world, dim")
            }
            kinds = [kind]
        }
        var center: (ObjectRef, LiveObject)?
        let nearToken = args.string("near") ?? "player"
        switch resolveRefArg(AIToolArguments(object: ["ref": nearToken]), "ref", context) {
        case .success(let c): center = c
        case .failure(let outcome): return outcome
        }
        guard let (_, centerLive) = center, let pos = position(of: centerLive) else {
            return .refuse(stage: "args", message: "'\(nearToken)' has no position to search near")
        }
        let radius = min(max(Double(args.int("radius") ?? 16), 0), 48)
        let limit = min(max(args.int("limit") ?? 16, 1), 64)
        let typeFilter = args.string("type")
        let hasScriptsOnly = args.bool("hasScripts") ?? false
        let entries = context.graph.objectsNear(x: pos.0, y: pos.1, z: pos.2, radius: radius, limit: limit * 4, kinds: kinds)
        var out = "{\"objects\":["
        var first = true
        var count = 0
        for entry in entries where count < limit {
            if let typeFilter, familyName(entry.liveObject) != typeFilter { continue }
            let scripts = context.scriptStore.list(entry.ref)
            if hasScriptsOnly, scripts.isEmpty { continue }
            if !first { out += "," }
            first = false
            count += 1
            out += "{\"ref\":\(jsonString(entry.ref.canonical))"
            out += ",\"kind\":\(jsonString(entry.ref.kind.rawValue))"
            out += ",\"name\":\(jsonString(context.graph.displayName(of: entry.ref)))"
            out += ",\"distance\":\(String(format: "%.1f", entry.distanceSq.squareRoot()))"
            out += ",\"scripts\":\(scripts.count)"
            out += "}"
        }
        out += "]}"
        return .ok(bounded(out, cap: byteCap))
    }

    private static func position(of live: LiveObject) -> (Double, Double, Double)? {
        switch live {
        case .block(_, _, _, let x, let y, let z): return (Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5)
        case .entity(let e, _): return (e.x, e.y, e.z)
        case .player(let p, _): return (p.x, p.y, p.z)
        default: return nil
        }
    }

    // MARK: - get_object

    private static func getObject(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, live)):
            var out = "{\"ref\":\(jsonString(ref.canonical)),\"kind\":\(jsonString(ref.kind.rawValue))"
            out += ",\"name\":\(jsonString(context.graph.displayName(of: ref)))"
            out += ",\"builtins\":{"
            var firstBuiltin = true
            for descriptor in AttributeRegistry.descriptors(for: ref.kind) where descriptor.aiExposed {
                guard !descriptor.canonical.contains("[") else { continue }
                guard case .value(let v) = BuiltInAttributes.get(live, name: descriptor.canonical, host: context.graph.host) else { continue }
                if !firstBuiltin { out += "," }
                firstBuiltin = false
                out += "\(jsonString(descriptor.canonical)):\(AttrValueCodec.encode(v))"
            }
            out += "},\"attrs\":{"
            var firstAttr = true
            for (name, value, readonly) in context.store.list(ref) {
                if !firstAttr { out += "," }
                firstAttr = false
                out += "\(jsonString(name)):{\"value\":\(AttrValueCodec.encode(value)),\"readonly\":\(readonly)}"
            }
            out += "},\"scripts\":["
            out += context.scriptStore.list(ref).map { s in
                "{\"name\":\(jsonString(s.name)),\"mode\":\(jsonString(s.mode.rawValue))" +
                    ",\"enabled\":\(s.enabled),\"author\":\(jsonString(authorText(s.author)))" +
                    ",\"lastError\":\(s.lastError.map(jsonString) ?? "null")}"
            }.joined(separator: ",")
            out += "],\"subscriptions\":\(context.eventBus.listSubscriptions(for: ref).count)}"
            return .ok(bounded(out, cap: byteCap))
        }
    }

    private static func authorText(_ a: Provenance.Author) -> String {
        switch a {
        case .player: return "player"
        case .ai(let m): return "ai:\(m)"
        case .script(let owner, let name): return "script:\(owner.canonical):\(name)"
        }
    }

    // MARK: - describe_attributes

    private static func describeAttributes(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        var kind: ObjectKind?
        var live: LiveObject?
        if let refToken = args.string("ref") {
            switch resolveRefArg(args, "ref", context) {
            case .failure(let outcome): return outcome
            case .success(let (ref, l)): kind = ref.kind; live = l
            }
            _ = refToken
        } else if let k = args.string("kind") {
            guard let parsed = ObjectKind(rawValue: k) else {
                return .refuse(stage: "args", message: "'\(k)' is not a valid kind", hint: "block, entity, player, world, dim")
            }
            kind = parsed
        } else {
            return .refuse(stage: "args", message: "'kind' or 'ref' is required")
        }
        guard let kind else { return .refuse(stage: "args", message: "'kind' or 'ref' is required") }
        var out = "{\"attributes\":["
        var first = true
        for descriptor in AttributeRegistry.descriptors(for: kind) where descriptor.aiExposed {
            if let live, !AttributeRegistry.applies(descriptor, in: applicabilityContext(live)) { continue }
            if !first { out += "," }
            first = false
            out += "{\"name\":\(jsonString(descriptor.canonical))"
            out += ",\"mutable\":\(descriptor.mutability == .getSet)"
            out += ",\"observable\":\(descriptor.observable)"
            out += ",\"summary\":\(jsonString(descriptor.summary))}"
        }
        out += "]}"
        return .ok(bounded(out, cap: byteCap))
    }

    private static func applicabilityContext(_ live: LiveObject) -> AttributeApplicabilityContext {
        switch live {
        case .world: return .world
        case .dimension: return .dimension
        case .block(_, let chunk, _, let x, let y, let z):
            let cell = Int(chunk.get(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)))
            let id = cell >> 4
            let shape = (id >= 0 && id < blockDefs.count) ? blockDefs[id].shape : .air
            let name = (id >= 0 && id < blockDefs.count) ? blockDefs[id].name : ""
            let beType = chunk.getBlockEntity(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W))?.type
            return .block(shape: shape, name: name, blockEntityType: beType)
        case .entity(let e, _): return .entity(type: e.type, isPlayer: false, isLiving: e is LivingEntity, isMob: e is Mob)
        case .player(let p, _): return .entity(type: p.type, isPlayer: true, isLiving: true, isMob: false)
        }
    }

    // MARK: - describe_events

    private static let eventCatalog: [String] = [
        "attribute.changed", "block.placed", "block.broken", "block.replaced", "block.changed", "block.used",
        "block.neighborChanged", "block.scheduledTick", "entity.spawned", "entity.removed", "entity.damaged",
        "entity.died", "entity.healed", "entity.interacted", "entity.targetChanged", "player.joined", "player.left",
        "player.respawned", "player.dimensionChanged", "player.pickedUp", "player.dropped", "player.attacked",
        "player.slept", "player.leveled", "player.advancement", "dim.dayPhaseChanged", "dim.weatherChanged",
        "world.gameruleChanged", "world.difficultyChanged", "explosion", "load", "unload", "timer.fired",
        "ai.replied", "script.faulted", "script.overBudget",
    ]

    private static func describeEvents(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        let prefix = args.string("kind")
        let matches = eventCatalog.filter { prefix == nil || $0.hasPrefix(prefix!) }
        var out = "{\"events\":["
        out += matches.map(jsonString).joined(separator: ",")
        out += "]}"
        return .ok(bounded(out, cap: byteCap))
    }

    // MARK: - list_scripts / get_script

    private static func listScripts(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, _)):
            let scripts = context.scriptStore.list(ref)
            var out = "{\"scripts\":["
            out += scripts.map { s in
                "{\"name\":\(jsonString(s.name)),\"mode\":\(jsonString(s.mode.rawValue))" +
                    ",\"enabled\":\(s.enabled),\"author\":\(jsonString(authorText(s.author)))" +
                    ",\"bytes\":\(s.source.utf8.count),\"lastError\":\(s.lastError.map(jsonString) ?? "null")}"
            }.joined(separator: ",")
            out += "]}"
            return .ok(bounded(out, cap: byteCap))
        }
    }

    private static func getScript(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, _)):
            guard let name = args.string("name") else { return .refuse(stage: "args", message: "'name' is required") }
            guard let s = context.scriptStore.get(ref, name) else {
                return .refuse(stage: "args", message: "no script '\(name)' on \(ref.canonical)")
            }
            var out = "{\"ref\":\(jsonString(ref.canonical)),\"name\":\(jsonString(s.name))"
            out += ",\"mode\":\(jsonString(s.mode.rawValue)),\"enabled\":\(s.enabled)"
            out += ",\"author\":\(jsonString(authorText(s.author))),\"createdTick\":\(s.createdTick)"
            out += ",\"source\":\(jsonString(s.source))"
            out += ",\"triggers\":[" + s.triggers.map { t in
                "{\"event\":\(jsonString(t.event.rawValue))" +
                    ",\"attr\":\(t.attribute.map(jsonString) ?? "null")" +
                    ",\"target\":\(jsonString(t.target.displayText))}"
            }.joined(separator: ",") + "]"
            out += ",\"lastError\":\(s.lastError.map(jsonString) ?? "null")}"
            // §9.2: "get_script <= 16 KiB never truncated" — refuse rather
            // than silently cut a script's own source if it somehow exceeds
            // the cap (it cannot: `ScriptStore.attach` already refuses a
            // source over 16 KiB before this tool could ever see it).
            guard out.utf8.count <= scriptByteCap else {
                return .refuse(stage: "execute", message: "script text exceeds the tool result cap")
            }
            return .ok(out)
        }
    }

    // MARK: - check_script

    private static func checkScript(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        guard let source = args.string("source") else { return .refuse(stage: "args", message: "'source' is required") }
        guard let runtime = context.scriptRuntime else {
            return .ok(AIScriptValidationSummary.checkOnly(source: source))
        }
        switch AIScriptValidationGate.validate(source: source, chunkName: "check", runtime: runtime) {
        case .accepted(let sha):
            return .ok("{\"accepted\":true,\"sha256\":\(jsonString(sha)),\"bytes\":\(source.utf8.count)}")
        case .refused(let result):
            return .ok(
                "{\"accepted\":false,\"stage\":\(result.stage),\"message\":\(jsonString(result.message))" +
                    ",\"hint\":\(jsonString(result.hint)),\"line\":\(result.line)}"
            )
        }
    }

    // MARK: - list_subscriptions

    private static func listSubscriptions(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, _)):
            let subs = context.eventBus.listSubscriptions(for: ref)
            var out = "{\"subscriptions\":["
            out += subs.map { s in
                "{\"id\":\(s.id),\"event\":\(jsonString(s.event.rawValue))" +
                    ",\"target\":\(jsonString(s.target.displayText))" +
                    ",\"attr\":\(s.attribute.map(jsonString) ?? "null")" +
                    ",\"handler\":\(jsonString(s.scriptName + "." + s.handler))}"
            }.joined(separator: ",")
            out += "]}"
            return .ok(bounded(out, cap: byteCap))
        }
    }

    // MARK: - search_registry

    private static func searchRegistry(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        guard let kind = args.string("kind") else { return .refuse(stage: "args", message: "'kind' is required") }
        guard let query = args.string("query"), !query.isEmpty else { return .refuse(stage: "args", message: "'query' is required") }
        let needle = query.lowercased()
        var names: [String] = []
        switch kind {
        case "block":
            names = blockDefs.filter { $0.name.lowercased().contains(needle) || $0.displayName.lowercased().contains(needle) }.map(\.name)
        case "item":
            names = itemDefs.map(\.name).filter { $0.lowercased().contains(needle) }
        case "entity":
            names = spawnableMobs().filter { $0.lowercased().contains(needle) }
        case "effect":
            names = EFFECTS.map(\.id).filter { $0.lowercased().contains(needle) }
        default:
            return .refuse(stage: "args", message: "'\(kind)' is not a searchable registry", hint: "block, item, entity, effect")
        }
        let limited = Array(Set(names)).sorted().prefix(32)
        var out = "{\"results\":["
        out += limited.map(jsonString).joined(separator: ",")
        out += "]}"
        return .ok(bounded(out, cap: byteCap))
    }

    // MARK: - inspect_event_path

    private static func inspectEventPath(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        switch resolveRefArg(args, "ref", context) {
        case .failure(let outcome): return outcome
        case .success(let (ref, live)):
            guard let eventText = args.string("event"), let event = EventKind.parse(eventText) else {
                return .refuse(stage: "args", message: "'\(args.string("event") ?? "")' is not a valid event name")
            }
            var recipients: [String] = []
            for s in context.scriptStore.list(ref) where s.mode == .handler {
                for t in s.triggers where t.event == event { recipients.append("\(ref.canonical).\(s.name)") }
            }
            for sub in context.eventBus.listSubscriptions() where sub.event == event {
                if matchesTarget(sub.target, ref: ref, type: familyName(live)) {
                    recipients.append("\(sub.subscriber.canonical).\(sub.scriptName).\(sub.handler)")
                }
            }
            var out = "{\"recipients\":["
            out += recipients.map(jsonString).joined(separator: ",")
            out += "]}"
            return .ok(bounded(out, cap: byteCap))
        }
    }

    private static func matchesTarget(_ target: SubscriptionTarget, ref: ObjectRef, type: String) -> Bool {
        switch target {
        case .object(let r): return r == ref
        case .kind(let k, let filter):
            guard k == ref.kind else { return false }
            guard let filter else { return true }
            return filter == type
        case .any: return true
        }
    }

    // MARK: - recent_events

    private static func recentEvents(_ args: AIToolArguments, _ context: AIQueryContext) -> AIToolOutcome {
        let limit = min(max(args.int("limit") ?? 16, 1), 32)
        var refFilter: ObjectRef?
        if let refToken = args.string("ref") {
            guard let ref = context.target.resolve(alias: refToken) else {
                return .refuse(stage: "args", message: "no such object '\(refToken)'")
            }
            refFilter = ref
        }
        let kindFilter = args.string("kind").flatMap(EventKind.parse)
        let events = context.eventBus.recentEvents(limit: nil)
            .filter { refFilter == nil || $0.subject == refFilter }
            .filter { kindFilter == nil || $0.kind == kindFilter }
            .suffix(limit)
        var out = "{\"events\":["
        out += events.map { e in
            "{\"seq\":\(e.seq),\"tick\":\(e.tick),\"kind\":\(jsonString(e.kind.rawValue))" +
                ",\"subject\":\(jsonString(e.subject.canonical))}"
        }.joined(separator: ",")
        out += "]}"
        return .ok(bounded(out, cap: byteCap))
    }

    static func jsonString(_ s: String) -> String { AttrValueCodec.encode(.string(s)) }
}
