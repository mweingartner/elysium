// ScriptingCommands.swift — object-graph-attributes (change 1a). design.md
// Decision 10 / spec `scripting-commands`. Core-side pure functions (lines +
// ok, no chat/UI calls) consumed by `CommandsM.runCommand` and by
// `ELYSIUM_CMD`/tests through the same path. `/attr`, `/inspect`, `/objects`;
// every scripting command (and `/ai`) is refused on a LAN client.

import Foundation

public struct ScriptingCommandContext {
    public let graph: ObjectGraph
    public let store: AttributeStore
    public let target: ObjectTargetContext
    public let isLANClient: Bool
    public let tick: Int64
    /// event-bus (change 1b): `/on`, `/unsubscribe`, `/events`.
    public let eventBus: EventBus
    /// script-runtime (change 1c): `/script`'s own executors.
    public let scriptStore: ScriptStore
    /// `nil` when no `LuaState` exists this session (LAN client, or
    /// construction failed) — `/script run` refuses cleanly in that case.
    public let scriptRuntime: ScriptRuntime?
    /// `WorldRecord.scriptsEnabled` — the trust gate `/script trust` flips.
    public let scriptsTrusted: Bool
    /// The `doScripts` gamerule read fresh — the kill switch `/script off|on`
    /// flips.
    public let killSwitchOn: Bool
    public let trustWorld: () -> Void
    public let setKillSwitch: (Bool) -> Void
    /// Session summary hint (`GameScriptingState.anyScriptsAttached`). Exact lifecycle discovery is
    /// independent: `ScriptStore` records the mutated ref in the host's bounded dirty queue.
    public let markScriptAttached: () -> Void
    /// ai-object-graph (change 2), design.md §9.5/§12: `/script journal` and
    /// `/script undo-ai`. `nil` only in a test/context that predates this
    /// change and never exercises those two subcommands (they refuse
    /// cleanly with "no AI journal this session" rather than trapping).
    public let aiJournal: AIJournal?
    /// lan-client-parity (change 4): the provenance every mutating executor
    /// this context reaches (`store.set/define/remove`, `scriptStore.attach`,
    /// `eventBus.subscribe`/`.raise`) records. `.player` for every context
    /// built before this change (the host's own commands); `.lan(peer:)` for
    /// a guest `scriptIntent` executed through `GameCore.scriptingCommandContext
    /// (guestPeerID:)`.
    public let author: Provenance.Author

    public init(
        graph: ObjectGraph, store: AttributeStore, target: ObjectTargetContext, isLANClient: Bool, tick: Int64,
        eventBus: EventBus, scriptStore: ScriptStore, scriptRuntime: ScriptRuntime?, scriptsTrusted: Bool,
        killSwitchOn: Bool, trustWorld: @escaping () -> Void, setKillSwitch: @escaping (Bool) -> Void,
        markScriptAttached: @escaping () -> Void = {}, aiJournal: AIJournal? = nil,
        author: Provenance.Author = .player
    ) {
        self.graph = graph
        self.store = store
        self.target = target
        self.isLANClient = isLANClient
        self.tick = tick
        self.eventBus = eventBus
        self.scriptStore = scriptStore
        self.scriptRuntime = scriptRuntime
        self.scriptsTrusted = scriptsTrusted
        self.killSwitchOn = killSwitchOn
        self.trustWorld = trustWorld
        self.setKillSwitch = setKillSwitch
        self.markScriptAttached = markScriptAttached
        self.aiJournal = aiJournal
        self.author = author
    }
}

public struct ScriptingCommandResult {
    public let lines: [String]
    public let ok: Bool
}

/// A plain user-facing refusal sentence, wrapped so it can flow through
/// `Result` (`String` alone does not conform to `Error`).
private struct TargetMessage: Error {
    let text: String
}

public enum ScriptingCommands {
    private static let usageAttr = "Usage: /attr list|get|set|define|remove <target> [name] [value] [readonly] [--force]"
    private static let usageOn = "Usage: /on <target> <event> [attr] <script.handler>"
    private static let usageUnsubscribe = "Usage: /unsubscribe <id>"
    private static let usageEvents =
        "Usage: /events recent [limit] | list <target> | define <target> <event> [field:type ...] [--summary text] | remove <target> <event> | emit <target> <event> [payload-json]"
    private static let refusal = "This command runs on the LAN host only (guests get access in a later update)."
    // event-bus (change 1b): `/on`, `/unsubscribe`, `/events` join the
    // host-only gate the same way `/attr`/`/inspect`/`/objects` did in 1a —
    // every one of them mutates or reads world/subscription state that a LAN
    // client never authoritatively holds.
    private static let lanGatedCommands: Set<String> = [
        "attr", "inspect", "objects", "ai", "agent", "on", "unsubscribe", "events", "script",
    ]

    /// Decision 10's Core-owned refusal decision — `CommandsM` consults this
    /// before any other work; `nil` for a command this change does not gate.
    public static func lanClientRefusal(command: String) -> String? {
        lanGatedCommands.contains(command.lowercased()) ? refusal : nil
    }

    public static func helpSummary() -> String { "attr, inspect, objects, on, unsubscribe, events, script" }

    /// lan-client-parity (change 4), design.md §11: the guest `scriptIntent`
    /// family — "author/attach/detach/run-script, attr set/define/remove,
    /// subscribe/unsubscribe". Read commands (`inspect`, `objects`,
    /// `events recent`) and world-level settings (`script trust|off|on`,
    /// `script journal|undo-ai|list|show`) stay host-only always — a guest
    /// reads through the replicated mirror, never a live host query, and
    /// never touches the trust/kill-switch gate. Shared by both sides of the
    /// wire: `CommandsM` (client) calls it to decide whether a normally-
    /// refused command should instead be sent as a `scriptIntent`, and the
    /// host re-validates the exact same predicate before dispatch — a
    /// `scriptIntent` is never trusted to only ever carry an allowed shape.
    public static func lanForwardableCommand(_ command: String, _ arguments: [String]) -> Bool {
        switch command.lowercased() {
        case "attr":
            switch arguments.first?.lowercased() {
            case "set", "define", "remove": return true
            default: return false
            }
        case "script":
            switch arguments.first?.lowercased() {
            case "attach", "detach", "run": return true
            default: return false
            }
        case "on", "unsubscribe":
            return true
        case "events":
            switch arguments.first?.lowercased() {
            case "emit", "define", "remove": return true
            default: return false
            }
        default:
            return false
        }
    }

    /// Returns the object-target token in a guest-forwardable command's real grammar. Commands
    /// with a subcommand put the target at `arguments[1]`; `/on` puts it at `arguments[0]`, and
    /// `/unsubscribe` has no object target. The host transport uses this same parser seam before
    /// dispatch so a block mutation cannot evade its reach check by hiding behind a subcommand.
    public static func lanForwardedObjectTargetToken(
        command: String, arguments: [String]
    ) -> String? {
        switch command.lowercased() {
        case "attr", "script", "events":
            return arguments.count > 1 ? arguments[1] : nil
        case "on":
            return arguments.first
        default:
            return nil
        }
    }

    public static func run(command: String, arguments: [String], context: ScriptingCommandContext) -> ScriptingCommandResult {
        let cmd = command.lowercased()
        // Security (plan) C27: refuse here too (defense in depth) even though
        // the real enforcement point is the `CommandsM` call site this
        // function's caller is expected to gate first.
        if context.isLANClient, lanClientRefusal(command: cmd) != nil {
            return ScriptingCommandResult(lines: [refusal], ok: false)
        }
        switch cmd {
        case "attr": return capResult(runAttr(arguments, context))
        case "inspect": return capResult(runInspect(arguments, context))
        case "objects": return capResult(runObjects(arguments, context))
        case "on": return capResult(runOn(arguments, context))
        case "unsubscribe": return capResult(runUnsubscribe(arguments, context))
        case "events": return capResult(runEvents(arguments, context))
        case "script": return capResult(runScript(arguments, context))
        default: return ScriptingCommandResult(lines: ["unknown scripting command '\(command)'"], ok: false)
        }
    }

    // MARK: - shared helpers

    private static func ok(_ lines: [String]) -> ScriptingCommandResult { ScriptingCommandResult(lines: lines, ok: true) }
    private static func fail(_ line: String) -> ScriptingCommandResult { ScriptingCommandResult(lines: [line], ok: false) }

    private static func capResult(_ r: ScriptingCommandResult) -> ScriptingCommandResult {
        let sanitized = r.lines.map(ScriptingDisplayText.line)
        guard sanitized.count > 40 else { return ScriptingCommandResult(lines: sanitized, ok: r.ok) }
        let shown = Array(sanitized.prefix(39))
        return ScriptingCommandResult(lines: shown + ["… (+\(sanitized.count - 39) more)"], ok: r.ok)
    }

    private static func dimNameOf(_ ref: ObjectRef) -> String? {
        switch ref {
        case .dimension(let d): return dimCanonicalName(d)
        case .block(let d, _, _, _): return dimCanonicalName(d)
        default: return nil
        }
    }

    private static func notLiveMessage(_ ref: ObjectRef, _ resolution: ObjectResolution) -> String {
        switch resolution {
        case .dormant:
            if let name = dimNameOf(ref) { return "dimension \(name) is not loaded" }
            return "\(ref.canonical) is not loaded"
        case .notLoaded:
            return "\(ref.canonical) is not loaded"
        case .unsupported:
            return "guest player objects arrive in a later update"
        default:
            return "no such object \(ref.canonical)"
        }
    }

    /// Resolves a target token (alias or canonical ref) to a live object, or
    /// the exact refusal sentence to print.
    private static func resolveTarget(_ token: String, _ context: ScriptingCommandContext) -> Result<(ObjectRef, LiveObject), TargetMessage> {
        guard let ref = context.target.resolve(alias: token) else {
            if token == "looking" || token == "cursor" { return .failure(TargetMessage(text: "nothing under the cursor")) }
            return .failure(TargetMessage(text: "no such object \(token)"))
        }
        switch context.graph.resolve(ref) {
        case .live(let live): return .success((ref, live))
        case let resolution: return .failure(TargetMessage(text: notLiveMessage(ref, resolution)))
        }
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

    // MARK: - value grammar (`null true false 12 1.5 ref:<…> str:<…> [json] {json} <string>`)

    static func parseValueTokens(_ tokens: [String], context: ScriptingCommandContext) -> AttrValue? {
        guard let first = tokens.first else { return nil }
        if tokens.count == 1 {
            switch first {
            case "null": return .null
            case "true": return .bool(true)
            case "false": return .bool(false)
            default: break
            }
            if let i = Int64(first) { return .int(i) }
            if let d = Double(first), !d.isNaN { return .number(d) }
            if first.hasPrefix("ref:") {
                guard let ref = context.target.resolve(alias: String(first.dropFirst(4))) else { return nil }
                return .ref(ref.canonical)
            }
            if first.hasPrefix("str:") { return .string(String(first.dropFirst(4))) }
            if first.hasPrefix("[") || first.hasPrefix("{") {
                guard case .success(let v) = AttrValueCodec.decode(first, caps: .defaults) else { return nil }
                return v
            }
            return .string(first)
        }
        if first.hasPrefix("[") || first.hasPrefix("{") {
            let joined = tokens.joined(separator: " ")
            guard case .success(let v) = AttrValueCodec.decode(joined, caps: .defaults) else { return nil }
            return v
        }
        return .string(tokens.joined(separator: " "))
    }

    // MARK: - /attr

    private static func runAttr(_ args: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard let sub = args.first else { return fail(usageAttr) }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":
            guard let targetToken = rest.first else { return fail(usageAttr) }
            return attrList(targetToken, context)
        case "get":
            guard rest.count >= 2 else { return fail(usageAttr) }
            return attrGet(rest[0], rest[1], context)
        case "set":
            guard rest.count >= 3 else { return fail(usageAttr) }
            return attrSet(rest[0], rest[1], Array(rest.dropFirst(2)), context)
        case "define":
            guard rest.count >= 3 else { return fail(usageAttr) }
            return attrDefine(rest[0], rest[1], Array(rest.dropFirst(2)), context)
        case "remove":
            guard rest.count >= 2 else { return fail(usageAttr) }
            return attrRemove(rest[0], rest[1], Array(rest.dropFirst(2)), context)
        default:
            return fail(usageAttr)
        }
    }

    private static func attrList(_ targetToken: String, _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        switch resolveTarget(targetToken, context) {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, _)):
            let entries = context.store.list(ref)
            var lines = entries.map { name, value, readonly -> String in
                "\(name) = \(AttrValueCodec.encode(value))" + (readonly ? " (readonly)" : "")
            }
            let record = context.store.record(ref) ?? ObjectRecord()
            let bytes = ObjectRecordCodec.encode(record).utf8.count
            lines.append("\(entries.count) attributes, \(bytes) bytes, revision \(record.revision)")
            return ok(lines)
        }
    }

    private static func attrGet(_ targetToken: String, _ name: String, _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        switch resolveTarget(targetToken, context) {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, live)):
            if let v = context.store.get(ref, name) { return ok([AttrValueCodec.encode(v)]) }
            switch BuiltInAttributes.get(live, name: name, host: context.graph.host) {
            case .value(let v): return ok([AttrValueCodec.encode(v)])
            case .notApplicable: return ok(["\(name) is not an attribute of \(familyName(live))"])
            case .unknownName: return fail("no attribute '\(name)' on \(ref.canonical)")
            }
        }
    }

    private static func attrSet(
        _ targetToken: String, _ name: String, _ valueTokens: [String], _ context: ScriptingCommandContext
    ) -> ScriptingCommandResult {
        switch resolveTarget(targetToken, context) {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, live)):
            guard let value = parseValueTokens(valueTokens, context: context) else {
                return fail("could not parse value '\(valueTokens.joined(separator: " "))'")
            }
            if AttributeRegistry.resolve(kind: ref.kind, name: name) != nil {
                switch context.graph.host.setScriptBuiltInAttribute(
                    live, ref: ref, name: name, value: value, author: context.author
                ) {
                case .ok(let v): return ok(["\(ref.canonical).\(name) = \(AttrValueCodec.encode(v))"])
                case .unknownName(let suggestions):
                    return fail(unknownBuiltinMessage(name: name, kind: ref.kind, suggestions: suggestions))
                case .notApplicable: return fail("\(name) is not an attribute of \(familyName(live))")
                case .readOnly: return fail("\(name) is readonly — use /attr define --force")
                case .wrongValueKind: return fail("\(name) does not accept that value")
                case .outOfRange(let range): return fail("\(name) must be in \(range)")
                }
            }
            switch context.store.set(ref, name, value, by: context.author) {
            case .success(let v): return ok(["\(ref.canonical).\(name) = \(AttrValueCodec.encode(v))"])
            case .failure(let err): return fail(message(for: err, ref: ref, name: name))
            }
        }
    }

    private static func attrDefine(
        _ targetToken: String, _ nameAndRest: String, _ rest: [String], _ context: ScriptingCommandContext
    ) -> ScriptingCommandResult {
        switch resolveTarget(targetToken, context) {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, _)):
            var tokens = rest
            var readonly = false
            var force = false
            while let last = tokens.last, last == "readonly" || last == "--force" {
                if last == "readonly" { readonly = true } else { force = true }
                tokens.removeLast()
            }
            guard let value = parseValueTokens(tokens, context: context) else {
                return fail("could not parse value '\(tokens.joined(separator: " "))'")
            }
            switch context.store.define(ref, nameAndRest, value, readonly: readonly, force: force, by: context.author) {
            case .success(let result):
                var line = "\(ref.canonical).\(nameAndRest) = \(AttrValueCodec.encode(result.value))"
                if readonly { line += " (readonly)" }
                if result.forced { line += " (forced)" }
                return ok([line])
            case .failure(let err):
                return fail(message(for: err, ref: ref, name: nameAndRest))
            }
        }
    }

    private static func attrRemove(
        _ targetToken: String, _ name: String, _ rest: [String], _ context: ScriptingCommandContext
    ) -> ScriptingCommandResult {
        switch resolveTarget(targetToken, context) {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, _)):
            let force = rest.contains("--force")
            switch context.store.remove(ref, name, force: force, by: context.author) {
            case .success(let result):
                guard result.existed else { return fail("\(name) is not set on \(ref.canonical)") }
                return ok([result.forced ? "removed \(name) (forced)" : "removed \(name)"])
            case .failure(let err):
                return fail(message(for: err, ref: ref, name: name))
            }
        }
    }

    private static func unknownBuiltinMessage(name: String, kind: ObjectKind, suggestions: [String]) -> String {
        var msg = "no built-in attribute '\(name)' on \(kind.rawValue)"
        if !suggestions.isEmpty { msg += " — did you mean: \(suggestions.joined(separator: ", "))" }
        return msg
    }

    private static func message(for err: AttributeError, ref: ObjectRef, name: String) -> String {
        switch err {
        case .objectNotLive: return "\(ref.canonical) is not loaded"
        case .dormant: return dimNameOf(ref).map { "dimension \($0) is not loaded" } ?? "\(ref.canonical) is not loaded"
        case .unsupported: return "guest player objects arrive in a later update"
        case .invalidName(let hint):
            return hint.map { "'\(name)' is not a valid attribute name — try '\($0)'" }
                ?? "'\(name)' is not a valid attribute name"
        case .nameIsBuiltIn: return "\(name) is a built-in attribute of \(ref.kind.rawValue) — use /attr set \(ref.canonical) \(name)"
        case .nameIsScript: return "\(name) is an attached script — detach it before creating an attribute with that name"
        case .invalidValue(let attrErr): return "value too large (\(attrErr.message))"
        case .readonly: return "\(name) is readonly — use /attr define --force"
        case .tooManyEntries(let limit): return "too many attributes on \(ref.canonical) (limit \(limit))"
        case .recordTooLarge(let limit): return "attributes on \(ref.canonical) would exceed \(limit / 1024) KiB"
        case .chunkTooLarge(let limit): return "attributes in this chunk would exceed \(limit / (1024 * 1024)) MiB"
        case .documentTooLarge(let limit): return "world attributes would exceed \(limit / 1024) KiB"
        case .lanClient: return refusal
        case .revisionOverflow: return "\(ref.canonical) has reached its revision limit"
        }
    }

    // MARK: - /inspect

    private static func runInspect(_ args: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        let expandAll = args.contains("--all")
        let explicitTarget = args.first { $0 != "--all" }
        let targetToken = explicitTarget ?? "looking"
        // "default looking, then self" (spec `scripting-commands`) means:
        // only fall back to "self" when no target argument was given *and*
        // "looking" names nothing at all (`context.target.resolve` itself
        // returns nil — "nothing under the cursor"). A "looking" that
        // resolves to a real ref which merely isn't live right now (dormant/
        // not loaded) reports that specific refusal, not a silent retry.
        let resolved: Result<(ObjectRef, LiveObject), TargetMessage>
        if explicitTarget == nil, context.target.resolve(alias: "looking") == nil {
            resolved = resolveTarget("self", context)
        } else {
            resolved = resolveTarget(targetToken, context)
        }
        switch resolved {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, live)):
            var lines: [String] = []
            lines.append("\(ref.canonical) (\(ref.kind.rawValue)) \(context.graph.displayName(of: ref))")
            for descriptor in AttributeRegistry.descriptors(for: ref.kind) {
                guard !descriptor.canonical.contains("["),
                      AttributeRegistry.applies(descriptor, in: applicabilityContext(live)) else { continue }
                if !expandAll, isFamilySummarized(descriptor.canonical) { continue }
                guard case .value(let v) = BuiltInAttributes.get(live, name: descriptor.canonical, host: context.graph.host)
                else { continue }
                lines.append("\(descriptor.canonical): \(rawInspectText(v))")
            }
            if !expandAll {
                lines.append(contentsOf: familySummaryLines(live, context))
            } else {
                lines.append(contentsOf: familyExpandedLines(live, ref, context))
            }
            let record = context.store.record(ref) ?? ObjectRecord()
            lines.append("attrs (\(record.entries.count), revision \(record.revision)):")
            for (name, value, readonly) in context.store.list(ref) {
                lines.append("  \(name) = \(AttrValueCodec.encode(value))" + (readonly ? " (readonly)" : ""))
            }
            lines.append("scripts: 0")
            return ok(lines)
        }
    }

    /// `/inspect`'s built-in field lines show a bare value (`facing: west`,
    /// `name: furnace_lit`), not the quoted canonical JSON `/attr`'s custom
    /// `attrs` section uses (`mood = "happy"`) — spec `scripting-commands`
    /// "Inspect a furnace". Only `.string` differs from `AttrValueCodec`'s
    /// canonical text; every other shape reuses it (composite shapes like
    /// `.list`/`.map` keep their canonical form, which is already readable).
    private static func rawInspectText(_ v: AttrValue) -> String {
        if case .string(let s) = v { return s }
        return AttrValueCodec.encode(v)
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

    /// Indexed/keyed families are summarized as one line unless `--all`.
    private static func isFamilySummarized(_ canonical: String) -> Bool {
        ["armor", "effects"].contains(canonical) == false
            && (canonical.hasPrefix("inventory") || canonical.hasPrefix("be.items"))
    }

    private static func familySummaryLines(_ live: LiveObject, _ context: ScriptingCommandContext) -> [String] {
        switch live {
        case .player(let p, _):
            let filled = p.inventory.compactMap { $0 }.count
            return ["inventory: \(filled)/\(p.inventory.count) stacks"]
        case .block(_, let chunk, _, let x, let y, let z):
            guard let be = chunk.getBlockEntity(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)), let items = be.items else { return [] }
            let filled = items.compactMap { $0 }.count
            return ["be.items: \(filled)/\(items.count)"]
        default:
            return []
        }
    }

    private static func familyExpandedLines(_ live: LiveObject, _ ref: ObjectRef, _ context: ScriptingCommandContext) -> [String] {
        switch live {
        case .player(let p, _):
            return p.inventory.indices.map { i in
                "inventory[\(i)]: \(AttrValueCodec.encode((BuiltInAttributes.get(live, name: "inventory[\(i)]", host: context.graph.host).valueOrNull)))"
            }
        case .block(_, let chunk, _, let x, let y, let z):
            guard let be = chunk.getBlockEntity(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)), let items = be.items else { return [] }
            return items.indices.map { i in
                "be.items[\(i)]: \(AttrValueCodec.encode(BuiltInAttributes.get(live, name: "be.items[\(i)]", host: context.graph.host).valueOrNull))"
            }
        default:
            return []
        }
    }

    // MARK: - /objects

    private static func runObjects(_ args: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard args.first == "near" || args.isEmpty else {
            return fail("Usage: /objects near [radius] [--kind entity|block]")
        }
        let rest = args.first == "near" ? Array(args.dropFirst()) : args
        var radius = 8.0
        var kinds: Set<ObjectKind>?
        var i = 0
        while i < rest.count {
            if rest[i] == "--kind", i + 1 < rest.count {
                switch rest[i + 1] {
                case "entity": kinds = [.entity]
                case "block": kinds = [.block]
                default: break
                }
                i += 2
                continue
            }
            if let r = Double(rest[i]) { radius = r }
            i += 1
        }
        guard case .live(.player(let player, _)) = context.graph.resolve(.player) else {
            return fail("no such object player")
        }
        // The querying player's own entity is never listed as an object
        // "near" itself (spec `object-graph-refs`'s worked example lists only
        // the block and the two other entities, never the local player). Since
        // the SC-1/DEF-2 fix, `objectsNear` now emits the local player under
        // `.player` (never `.entity(uid:)`, per `specs/object-graph-refs`'s
        // "Player objects in the entity index" scenario) — filter on that ref
        // shape instead of a uid comparison that can no longer match it.
        let entries = context.graph
            .objectsNear(x: player.x, y: player.y, z: player.z, radius: radius, limit: 32 + 1, kinds: kinds)
            .filter { entry in
                if entry.ref == .player { return false }
                if case .entity(let uid) = entry.ref { return uid != player.id }
                return true
            }
            .prefix(32)
        guard !entries.isEmpty else { return ok(["no objects within \(radius)"]) }
        let lines = entries.map { entry -> String in
            let distance = entry.distanceSq.squareRoot()
            let attrsCount = attributeCount(entry.liveObject, context)
            let displayName = context.graph.displayName(of: entry.ref)
            return "\(entry.ref.canonical) \(entry.ref.kind.rawValue) \(displayName) d=\(oneDecimal(distance)) attrs=\(attrsCount)"
        }
        return ok(lines)
    }

    private static func attributeCount(_ live: LiveObject, _ context: ScriptingCommandContext) -> Int {
        AttributeStore.readRecord(live, host: context.graph.host).entries.count
    }

    private static func oneDecimal(_ d: Double) -> String {
        let scaled = (d * 10).rounded() / 10
        return String(format: "%.1f", scaled)
    }

    // MARK: - /on, /unsubscribe (event-bus, change 1b)

    /// A `/on`/subscription-tool target token: `any`; a bare kind name
    /// (`entity`/`player`/`block`/`world`/`dim`, matching `ObjectKind`'s own
    /// spelling — a kind-wildcard with no type filter); `entity:<type>` /
    /// `block:<name>` (a kind-wildcard with a type filter — checked for a
    /// *second* colon first so a canonical `block:<dim>:<x>,<y>,<z>` ref, or
    /// a numeric `entity:<uid>`, always falls through to ordinary ref/alias
    /// resolution below instead); everything else resolves exactly like
    /// `/attr`'s target token (`looking`/`self`/`player`/`world`/`dim`/a
    /// canonical ref) as `.object(ref)`. Design.md §7.3 fixes the shapes
    /// (`self | ref | {kind, type?}` / `.any`); this change owns the exact
    /// command spelling, matching `ObjectTargetContext`'s own "one parser"
    /// discipline for the object-ref half.
    static func parseSubscriptionTarget(_ token: String, context: ScriptingCommandContext) -> SubscriptionTarget? {
        if token == "any" { return .any }
        if let kind = ObjectKind(rawValue: token) { return .kind(kind, typeFilter: nil) }
        if token.hasPrefix("entity:") {
            let rest = String(token.dropFirst(7))
            if Int(rest) == nil, !rest.isEmpty, rest.utf8.count <= 32, !rest.contains(":") {
                return .kind(.entity, typeFilter: rest)
            }
        }
        if token.hasPrefix("block:") {
            let rest = String(token.dropFirst(6))
            if !rest.isEmpty, rest.utf8.count <= 32, !rest.contains(":") {
                return .kind(.block, typeFilter: rest)
            }
        }
        if let ref = context.target.resolve(alias: token) { return .object(ref) }
        return nil
    }

    /// `/on <target> <event> [attr] <script.handler>` (§12). The subscriber
    /// is always `self` (`.player`) — the command is issued by the player and
    /// registers the subscription on the player's own script record (a
    /// grammar reading forced by the command having only one target token;
    /// §7.3's `Subscription.subscriber`/`.target` are deliberately distinct
    /// fields, and `<target>` here is unambiguously the *watch* target per
    /// its own worked shapes). 1c is what makes `<script.handler>` resolve to
    /// a real handler function — this change only validates its grammar and
    /// stores it.
    private static func runOn(_ args: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard args.count == 3 || args.count == 4 else { return fail(usageOn) }
        guard let target = parseSubscriptionTarget(args[0], context: context) else {
            return fail("no such object or target kind '\(args[0])'")
        }
        guard let event = EventKind.parse(args[1]) else { return fail("'\(args[1])' is not a valid event name") }
        let attribute: String?
        let handlerToken: String
        if args.count == 4 {
            guard let canonical = canonicalAuthoredAttributeFilter(
                args[2], target: target
            ) else { return fail("'\(args[2])' is not a valid attribute name") }
            attribute = canonical
            handlerToken = args[3]
        } else {
            attribute = nil
            handlerToken = args[2]
        }
        guard let dot = handlerToken.lastIndex(of: "."), dot != handlerToken.startIndex else {
            return fail("expected '<script>.<handler>', got '\(handlerToken)'")
        }
        let scriptName = String(handlerToken[handlerToken.startIndex..<dot])
        let handler = String(handlerToken[handlerToken.index(after: dot)...])
        guard isValidAttributeName(scriptName), isValidAttributeName(handler) else {
            return fail("'\(handlerToken)' is not a valid '<script>.<handler>'")
        }
        switch context.eventBus.subscribe(
            subscriber: context.target.selfRef, scriptName: scriptName, handler: handler, target: target, event: event,
            attribute: attribute, createdBy: context.author, tick: context.tick
        ) {
        case .success(let sub):
            return ok(["subscribed #\(sub.id): \(event.rawValue) on \(target.displayText) -> \(scriptName).\(handler)"])
        case .failure(let err):
            switch err {
            case .tooManyForWorld: return fail("too many subscriptions in this world (limit \(context.eventBus.caps.maxSubscriptionsPerWorld))")
            case .tooManyForObject: return fail("too many subscriptions on self (limit \(context.eventBus.caps.maxSubscriptionsPerObject))")
            case .targetRequiresTypeFilter: return fail("'\(args[1])' on a block target requires a type filter (block:<name>)")
            case .anyNotAllowedForThisEvent: return fail("'any' is not a valid target for '\(args[1])'")
            case .attributeFilterNotAllowed: return fail("an attribute filter is valid only for 'attribute.changed'")
            case .invalidAttributeFilter: return fail("'\(args.count == 4 ? args[2] : "")' is not a valid attribute filter")
            case .eventNotApplicable: return fail("'\(args[1])' does not apply to that target kind")
            case .eventNotAvailable: return fail("'\(args[1])' is reserved and has no event producer")
            }
        }
    }

    private static func runUnsubscribe(_ args: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard let idText = args.first, let id = UInt64(idText) else { return fail(usageUnsubscribe) }
        let removed: Bool
        if case .lan(let peer) = context.author {
            removed = context.eventBus.unsubscribe(id: id, ownedBy: .lanPlayer(peerID: peer))
        } else {
            removed = context.eventBus.unsubscribe(id: id)
        }
        guard removed else { return fail("no subscription #\(id)") }
        return ok(["unsubscribed #\(id)"])
    }

    // MARK: - /events (event-bus, change 1b)

    private static func runEvents(_ args: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard let sub = args.first else { return fail(usageEvents) }
        switch sub {
        case "recent":
            guard args.count <= 2 else { return fail("Usage: /events recent [nonnegative-limit]") }
            let limit: Int?
            if args.count == 2 {
                guard let parsed = Int(args[1]), parsed >= 0 else {
                    return fail("event limit must be a nonnegative integer")
                }
                limit = parsed
            } else {
                limit = nil
            }
            let events = context.eventBus.recentEvents(limit: limit)
            guard !events.isEmpty else { return ok(["no recent events"]) }
            return ok(events.map(eventLine))
        case "list":
            guard args.count == 2 else { return fail("Usage: /events list <target>") }
            switch resolveTarget(args[1], context) {
            case .failure(let message): return fail(message.text)
            case .success(let (ref, live)):
                var lines = EventDescriptorRegistry.available
                    .filter { $0.subjectKinds.contains(ref.kind) }
                    .map { descriptor in
                        let fields = descriptor.payload.map {
                            "\($0.name):\($0.type.displayName)\($0.isNullable ? "?" : "")"
                        }.joined(separator: ", ")
                        return "built-in \(descriptor.kind.rawValue)" + (fields.isEmpty ? "" : " {\(fields)}")
                    }
                let declarations = CustomEventStore(graph: context.graph).list(ref)
                lines += declarations.map { declaration in
                    let fields = declaration.fields.map { "\($0.name):\($0.typeToken)" }.joined(separator: ", ")
                    let summary = declaration.summary.map { " — \($0)" } ?? ""
                    return "custom \(declaration.kind.rawValue)" + (fields.isEmpty ? " {}" : " {\(fields)}") + summary
                }
                _ = live
                return ok(lines.isEmpty ? ["no events available on \(ref.canonical)"] : lines)
            }
        case "define":
            guard args.count >= 3 else {
                return fail("Usage: /events define <target> <event> [field:type ...] [--summary text]")
            }
            let ref: ObjectRef
            switch resolveTarget(args[1], context) {
            case .failure(let message): return fail(message.text)
            case .success(let resolved): ref = resolved.0
            }
            let name = args[2]
            var fields: [CustomEventField] = []
            var summary: String?
            var index = 3
            while index < args.count {
                if args[index] == "--summary" {
                    guard index + 1 < args.count, index + 2 == args.count else {
                        return fail("--summary requires one quoted argument at the end")
                    }
                    summary = args[index + 1]
                    index += 2
                    continue
                }
                let token = args[index]
                guard let colon = token.firstIndex(of: ":"), colon != token.startIndex else {
                    return fail("expected field:type, got '\(token)'")
                }
                let fieldName = String(token[..<colon])
                let typeToken = String(token[token.index(after: colon)...])
                guard let field = CustomEventField(name: fieldName, typeToken: typeToken) else {
                    return fail("'\(typeToken)' is not a valid event field type")
                }
                fields.append(field)
                index += 1
            }
            switch CustomEventStore(graph: context.graph).declare(
                ref, name: name, fields: fields, summary: summary, by: context.author
            ) {
            case .success(let declaration):
                return ok(["declared \(declaration.kind.rawValue) on \(ref.canonical)"])
            case .failure(let error):
                return fail(customEventErrorText(error, name: name))
            }
        case "remove":
            guard args.count == 3 else { return fail("Usage: /events remove <target> <event>") }
            let ref: ObjectRef
            switch resolveTarget(args[1], context) {
            case .failure(let message): return fail(message.text)
            case .success(let resolved): ref = resolved.0
            }
            switch CustomEventStore(graph: context.graph).undeclare(ref, args[2]) {
            case .success(true): return ok(["removed event declaration \(args[2]) from \(ref.canonical)"])
            case .success(false): return ok(["no event declaration \(args[2]) on \(ref.canonical)"])
            case .failure(let error): return fail(customEventErrorText(error, name: args[2]))
            }
        case "emit":
            let rest = Array(args.dropFirst())
            guard rest.count == 2 || rest.count == 3 else {
                return fail("Usage: /events emit <target> <custom-event> [payload-json]")
            }
            let ref: ObjectRef
            let live: LiveObject
            switch resolveTarget(rest[0], context) {
            case .failure(let message): return fail(message.text)
            case .success(let resolved): (ref, live) = resolved
            }
            guard let event = EventKind.parse(rest[1]) else { return fail("'\(rest[1])' is not a valid event name") }
            var payload: [String: AttrValue] = [:]
            if rest.count == 3 {
                guard case .success(.map(let decoded)) = AttrValueCodec.decode(rest[2], caps: .defaults) else {
                    return fail("event payload must be a valid JSON object")
                }
                payload = decoded
            }
            let declaration = CustomEventStore(graph: context.graph).get(ref, event.rawValue)
            if let refusal = ScriptEventEmissionValidator.refusal(
                kind: event, subject: ref, payload: payload, declaration: declaration
            ) {
                return fail(refusal)
            }
            switch context.eventBus.raise(
                kind: event, subject: ref, payload: payload,
                source: eventSource(for: context.author), tick: context.tick,
                subjectType: familyName(live)
            ) {
            case .enqueued, .coalesced:
                return ok(["emitted \(event.rawValue) on \(ref.canonical)"])
            case .droppedQueueFull:
                return fail("event queue is full — \(event.rawValue) was dropped")
            case .droppedCascadeDepth, .droppedHandlerBudget:
                return fail("\(event.rawValue) was dropped (budget exceeded)")
            }
        default:
            return fail(usageEvents)
        }
    }

    private static func eventLine(_ e: ScriptEvent) -> String {
        "#\(e.seq) t\(e.tick) \(e.kind.rawValue) \(e.subject.canonical)"
    }

    private static func customEventErrorText(_ error: CustomEventStoreError, name: String) -> String {
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

    // MARK: - /script (script-runtime, change 1c, §12)

    private static let usageScript =
        "Usage: /script list [target] | show <target> <name> | attach <target> <name> module <source...> "
            + "| attach <target> <name> handler <event> <source...> | detach <target> <name> | run <target> <source...> "
            + "| stats | journal | undo-ai [n] | trust | off | on"

    private static func runScript(_ args: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard let sub = args.first else { return fail(usageScript) }
        let rest = Array(args.dropFirst())
        switch sub {
        case "list": return scriptList(rest, context)
        case "show": return scriptShow(rest, context)
        case "attach": return scriptAttach(rest, context)
        case "detach": return scriptDetach(rest, context)
        case "run": return scriptRun(rest, context)
        case "stats": return scriptStats(rest, context)
        case "journal": return scriptJournal(rest, context)
        case "undo-ai": return scriptUndoAI(rest, context)
        case "trust": return scriptTrust(context)
        case "off": return scriptKillSwitch(false, context)
        case "on": return scriptKillSwitch(true, context)
        default: return fail(usageScript)
        }
    }

    // MARK: - /script journal, /script undo-ai (ai-object-graph, change 2, §9.5/§12)

    private static func scriptStats(
        _ rest: [String], _ context: ScriptingCommandContext
    ) -> ScriptingCommandResult {
        guard rest.isEmpty else { return fail("Usage: /script stats") }
        guard let runtime = context.scriptRuntime else { return fail("no script runtime this session") }
        let summary = runtime.summary
        return ok([
            "scripts: \(summary.liveScripts) live, \(summary.suspendedCoroutines) suspended, \(summary.durableTimers) durable timers",
            "instructions: \(summary.instructionsUsedThisTick) charged this tick, \(summary.instructionBudgetRemaining)/\(summary.instructionBucketCapacity) tokens available",
            "events: \(context.eventBus.pendingCount) pending",
        ])
    }

    private static func scriptJournal(_ rest: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard let journal = context.aiJournal else { return fail("no AI journal this session") }
        let limit = rest.first.flatMap(Int.init) ?? 32
        let entries = journal.list(limit: limit)
        guard !entries.isEmpty else { return ok(["AI journal is empty"]) }
        return ok(entries.map { e in
            "req#\(e.requestID) entry#\(e.id) t\(e.tick) \(e.tool) \(e.refText) \(e.name) [\(e.undo.kindText)] (\(e.model))"
        })
    }

    private static func scriptUndoAI(_ rest: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard let journal = context.aiJournal else { return fail("no AI journal this session") }
        let n = rest.first.flatMap(Int.init) ?? 1
        guard n > 0 else { return fail("Usage: /script undo-ai [n]") }
        let undoContext = AIUndoContext(graph: context.graph, store: context.store, scriptStore: context.scriptStore, eventBus: context.eventBus, tick: context.tick)
        let lines = journal.undo(groups: n, context: undoContext)
        return ok(lines)
    }

    private static func scriptTargetToken(_ rest: [String]) -> (token: String, remainder: [String]) {
        guard let first = rest.first else { return ("looking", rest) }
        return (first, Array(rest.dropFirst()))
    }

    private static func scriptList(_ rest: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        let (token, _) = rest.isEmpty ? ("self", rest) : scriptTargetToken(rest)
        switch resolveTarget(token, context) {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, _)):
            let scripts = context.scriptStore.list(ref)
            guard !scripts.isEmpty else { return ok(["no scripts on \(ref.canonical)"]) }
            return ok(scripts.map { s in
                "\(s.name) [\(s.mode.rawValue)]\(s.enabled ? "" : " (disabled)")"
                    + (s.lastError.map { " — \($0)" } ?? "")
            })
        }
    }

    private static func scriptShow(_ rest: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard rest.count >= 2 else { return fail(usageScript) }
        switch resolveTarget(rest[0], context) {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, _)):
            guard let s = context.scriptStore.get(ref, rest[1]) else { return fail("no script '\(rest[1])' on \(ref.canonical)") }
            var lines = [
                "\(ref.canonical).\(s.name) [\(s.mode.rawValue)]\(s.enabled ? "" : " (disabled)")",
                "author: \(authorLine(s.author))  created: t\(s.createdTick)  api: \(s.apiVersion)",
            ]
            if !s.triggers.isEmpty {
                lines.append(contentsOf: s.triggers.map { t in
                    "trigger: \(t.event.rawValue)" + (t.attribute.map { " attr=\($0)" } ?? "") + " on \(t.target.displayText)"
                })
            }
            if let lastError = s.lastError { lines.append("lastError: \(lastError)") }
            lines.append("source (\(s.source.utf8.count) bytes):")
            lines.append(contentsOf: s.source.split(separator: "\n", omittingEmptySubsequences: false).prefix(30).map(String.init))
            return ok(lines)
        }
    }

    private static func authorLine(_ a: Provenance.Author) -> String {
        switch a {
        case .player: return "player"
        case .ai(let model): return "ai:\(model)"
        case .script(let owner, let name): return "script:\(owner.canonical):\(name)"
        case .lan(let peer): return "lan:\(peer)"
        }
    }

    /// lan-client-parity (change 4): `/events emit`'s `EventSource` — mirrors
    /// the identical `Provenance.Author` -> `EventSource` mapping duplicated
    /// in `GameCore+Scripting.swift`/`ScriptRuntime.swift` (attribute-change
    /// funnels), so a guest-forwarded `/events emit` records `.lan(peerID:)`
    /// on the raised event exactly like a guest-forwarded `/attr set`
    /// records `.lan(peer:)` on the attribute write.
    private static func eventSource(for author: Provenance.Author) -> EventSource {
        switch author {
        case .player: return .player
        case .ai(let model): return .ai(model: model)
        case .script(let owner, let name): return .script(owner: owner, name: name)
        case .lan(let peer): return .lan(peerID: peer)
        }
    }

    private static func scriptAttach(_ rest: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard rest.count >= 4 else { return fail(usageScript) }
        let targetToken = rest[0]
        let name = rest[1]
        let modeToken = rest[2]
        switch resolveTarget(targetToken, context) {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, _)):
            let mode: ScriptMode
            var triggers: [Trigger] = []
            var sourceTokens: [String]
            switch modeToken {
            case "module":
                mode = .module
                sourceTokens = Array(rest.dropFirst(3))
            case "handler":
                mode = .handler
                guard rest.count >= 5, let event = EventKind.parse(rest[3]) else {
                    return fail("'\(rest.count >= 4 ? rest[3] : "")' is not a valid event name")
                }
                triggers = [Trigger(event: event, attribute: nil, target: .object(ref))]
                sourceTokens = Array(rest.dropFirst(4))
            default:
                return fail(usageScript)
            }
            guard !sourceTokens.isEmpty else { return fail(usageScript) }
            let source = sourceTokens.joined(separator: " ")
            switch context.scriptStore.attach(
                ref, name: name, source: source, mode: mode, triggers: triggers, by: context.author, tick: context.tick
            ) {
            case .success:
                context.markScriptAttached()
                return ok(["attached \(name) [\(mode.rawValue)] to \(ref.canonical) — takes effect next script phase"])
            case .failure(let err):
                return fail(scriptStoreErrorMessage(err, name: name))
            }
        }
    }

    private static func scriptDetach(_ rest: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard rest.count >= 2 else { return fail(usageScript) }
        switch resolveTarget(rest[0], context) {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, _)):
            switch context.scriptStore.detach(ref, rest[1]) {
            case .success(let existed):
                guard existed else { return fail("no script '\(rest[1])' on \(ref.canonical)") }
                return ok(["detached \(rest[1]) from \(ref.canonical)"])
            case .failure(let err):
                return fail(scriptStoreErrorMessage(err, name: rest[1]))
            }
        }
    }

    /// §9.3's `run_script`: ephemeral, runs once immediately (this change's
    /// documented simplification of "next phase" — see ARCHITECTURE.md).
    private static func scriptRun(_ rest: [String], _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard rest.count >= 2 else { return fail(usageScript) }
        guard let runtime = context.scriptRuntime else { return fail("no script runtime this session") }
        switch resolveTarget(rest[0], context) {
        case .failure(let msg): return fail(msg.text)
        case .success(let (ref, _)):
            let source = rest.dropFirst().joined(separator: " ")
            switch runtime.runEphemeral(source: source, owner: ref) {
            case .success(let outcome): return ok([outcome])
            case .failure(let message): return fail(message)
            }
        }
    }

    private static func scriptTrust(_ context: ScriptingCommandContext) -> ScriptingCommandResult {
        guard !context.scriptsTrusted else { return ok(["this world is already trusted to run scripts"]) }
        context.trustWorld()
        return ok(["scripting trusted for this world"])
    }

    private static func scriptKillSwitch(_ on: Bool, _ context: ScriptingCommandContext) -> ScriptingCommandResult {
        context.setKillSwitch(on)
        return ok([on ? "scripting enabled (doScripts on)" : "scripting disabled (doScripts off)"])
    }

    private static func scriptStoreErrorMessage(_ err: ScriptStoreError, name: String) -> String {
        "'\(name)' " + scriptStoreErrorText(err)
    }
}

private extension BuiltInGetOutcome {
    var valueOrNull: AttrValue {
        if case .value(let v) = self { return v }
        return .null
    }
}
