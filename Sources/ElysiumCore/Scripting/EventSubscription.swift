// EventSubscription.swift — event-bus (change 1b). design.md §7.3. Two
// subscription flavors share one matching shape (`SubscriptionTarget` +
// `EventKind` + optional attribute filter):
//   - **Persisted** (`Subscription`): created by `/on` or (phase 2) the AI
//     `subscribe` tool, keyed on a natural key (upsert), stored in
//     `WorldRecord.scriptRegistry`, delivered to a *named* handler function in
//     a named script's environment — 1c supplies the environment; this change
//     only ever stores/matches/persists the reference to it.
//   - **Script-owned** (`ScriptOwnedSubscription`): registered by a running
//     script's `on(...)`/`subscribe(...)` call at load, dropped at unload,
//     never persisted. 1c is the only thing that will ever call
//     `EventBus.registerScriptOwned` with a real handler closure; this change
//     represents the data shape and the load/unload bookkeeping (`EventBus`'s
//     unload API) so 1c only has to plug in Lua execution.

import Foundation

/// What a subscription matches against (design.md §7.3). `.kind(.block, _)`
/// requires a non-nil `typeFilter` when the event kind itself requires one
/// (`EventKind.requiresBlockTypeFilter`) — enforced by `EventBus.subscribe`,
/// not by this type itself (a bare value type has no way to see the event
/// kind it will be paired with).
public enum SubscriptionTarget: Hashable, Sendable {
    case object(ObjectRef)
    case kind(ObjectKind, typeFilter: String?)
    case any

    /// Canonical single-token text (design.md-implied — no wire format is
    /// specified in the doc; this change owns it, matching `ObjectRef`'s own
    /// "one parser, one canonical printer" discipline). `obj:<ref>`,
    /// `kind:<kind>` or `kind:<kind>:<typeFilter>`, `any`.
    var canonicalText: String {
        switch self {
        case .object(let ref): return "obj:\(ref.canonical)"
        case .kind(let k, let filter):
            guard let filter else { return "kind:\(k.rawValue)" }
            return "kind:\(k.rawValue):\(filter)"
        case .any: return "any"
        }
    }

    static func parse(_ s: String) -> SubscriptionTarget? {
        if s == "any" { return .any }
        if s.hasPrefix("obj:") {
            guard let ref = ObjectRef.parse(String(s.dropFirst(4))) else { return nil }
            return .object(ref)
        }
        if s.hasPrefix("kind:") {
            let rest = s.dropFirst(5)
            let parts = rest.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard let kind = ObjectKind(rawValue: String(parts[0])) else { return nil }
            if parts.count == 2 {
                guard !parts[1].isEmpty, parts[1].utf8.count <= 32 else { return nil }
                return .kind(kind, typeFilter: String(parts[1]))
            }
            return .kind(kind, typeFilter: nil)
        }
        return nil
    }

    /// Human-readable form for `/events`/`/on` output (Decision 10 display
    /// hygiene is applied by the caller to the whole line, not here).
    public var displayText: String {
        switch self {
        case .object(let ref): return ref.canonical
        case .kind(let k, let filter): return filter.map { "\(k.rawValue):\($0)" } ?? k.rawValue
        case .any: return "any"
        }
    }
}

/// A persisted subscription (design.md §7.3): `Subscription{id, subscriber,
/// scriptName, handler, target, event, attribute, createdBy}`. Natural key
/// `(subscriber, scriptName, handler, target, event, attribute)` — a second
/// `/on` with the same key upserts (keeps the original `id`) rather than
/// creating a duplicate.
public struct Subscription: Equatable, Sendable {
    public var id: UInt64
    public var subscriber: ObjectRef
    public var scriptName: String
    public var handler: String
    public var target: SubscriptionTarget
    public var event: EventKind
    public var attribute: String?
    public var createdBy: Provenance.Author
    public var createdTick: Int64

    public init(
        id: UInt64, subscriber: ObjectRef, scriptName: String, handler: String,
        target: SubscriptionTarget, event: EventKind, attribute: String?,
        createdBy: Provenance.Author, createdTick: Int64
    ) {
        self.id = id
        self.subscriber = subscriber
        self.scriptName = scriptName
        self.handler = handler
        self.target = target
        self.event = event
        self.attribute = attribute
        self.createdBy = createdBy
        self.createdTick = createdTick
    }

    /// The natural key §7.3 upserts on.
    struct NaturalKey: Hashable {
        let subscriber: ObjectRef
        let scriptName: String
        let handler: String
        let target: SubscriptionTarget
        let event: EventKind
        let attribute: String?
    }

    var naturalKey: NaturalKey {
        NaturalKey(
            subscriber: subscriber, scriptName: scriptName, handler: handler,
            target: target, event: event, attribute: attribute
        )
    }
}

/// A script-owned subscription (design.md §7.3): registered while a chunk
/// runs at load, dropped at unload, never persisted — idempotent by
/// construction. 1c is the only owner of real handler closures; this change
/// stores an opaque `token` (the eventual Lua function reference/closure
/// identity) so the shape and the load/unload bookkeeping exist now.
public struct ScriptOwnedSubscription {
    public var id: UInt64
    /// The object whose script registered this (dropped in bulk when this
    /// object unloads).
    public var owner: ObjectRef
    public var scriptName: String
    public var target: SubscriptionTarget
    public var event: EventKind
    public var attribute: String?
    /// Opaque — 1c's Lua closure/function reference. Never inspected by this
    /// change; carried only so `EventBus` can hand it back to the (future)
    /// dispatcher unchanged.
    public var token: AnyObject?

    public init(
        id: UInt64, owner: ObjectRef, scriptName: String, target: SubscriptionTarget,
        event: EventKind, attribute: String?, token: AnyObject? = nil
    ) {
        self.id = id
        self.owner = owner
        self.scriptName = scriptName
        self.target = target
        self.event = event
        self.attribute = attribute
        self.token = token
    }
}

// MARK: - persistence (WorldRecord.scriptRegistry)

/// Encodes/decodes the full persisted-subscription list as one canonical
/// document (design.md §7.3: "stored in `WorldRecord.scriptRegistry`"),
/// matching `ObjectRecordCodec`'s discipline: sorted keys, tolerant per-entry
/// decode (a malformed entry is dropped with a diagnostic, never the whole
/// registry), a `"v"` version gate on the container itself.
public enum SubscriptionRegistryCodec {
    public static func encode(_ subs: [Subscription]) -> String {
        var out = "{\"subs\":["
        var first = true
        // Sorted by id — the registration/ascending-id order §7.4 delivery
        // relies on, and determinism for the encoded text itself.
        for sub in subs.sorted(by: { $0.id < $1.id }) {
            if !first { out += "," }
            first = false
            out += "{\"id\":\(sub.id)"
            out += ",\"who\":" + jsonString(sub.subscriber.canonical)
            out += ",\"script\":" + jsonString(sub.scriptName)
            out += ",\"handler\":" + jsonString(sub.handler)
            out += ",\"tgt\":" + jsonString(sub.target.canonicalText)
            out += ",\"ev\":" + jsonString(sub.event.rawValue)
            if let attribute = sub.attribute { out += ",\"attr\":" + jsonString(attribute) }
            out += ",\"by\":" + jsonString(encodeAuthor(sub.createdBy))
            out += ",\"t\":\(sub.createdTick)"
            out += "}"
        }
        out += "],\"v\":1}"
        return out
    }

    /// `diagnostic` is called once per dropped entry (never for a whole-
    /// document refusal — a `nil` return is that case, exactly like
    /// `ObjectRecordCodec.decode`).
    public static func decode(
        _ text: String, caps: ScriptingStorageCaps, diagnostic: (String) -> Void = { _ in }
    ) -> [Subscription]? {
        guard text.utf8.count <= caps.maxWorldDocumentBytes else { return nil }
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        guard (root["v"] as? NSNumber)?.intValue == 1 else { return nil }
        guard let rawSubs = root["subs"] as? [[String: Any]] else { return [] }
        var result: [Subscription] = []
        var seenIDs = Set<UInt64>()
        for raw in rawSubs {
            guard let sub = decodeOne(raw), !seenIDs.contains(sub.id) else {
                diagnostic("dropped malformed or duplicate-id subscription entry")
                continue
            }
            seenIDs.insert(sub.id)
            result.append(sub)
        }
        return result
    }

    private static func decodeOne(_ raw: [String: Any]) -> Subscription? {
        guard let idNumber = raw["id"] as? NSNumber, idNumber.int64Value >= 0 else { return nil }
        let id = UInt64(idNumber.uint64Value)
        guard let whoText = raw["who"] as? String, let subscriber = ObjectRef.parse(whoText) else { return nil }
        guard let scriptName = raw["script"] as? String, isValidAttributeName(scriptName) else { return nil }
        guard let handler = raw["handler"] as? String, isValidAttributeName(handler) else { return nil }
        guard let tgtText = raw["tgt"] as? String, let target = SubscriptionTarget.parse(tgtText) else { return nil }
        guard let evText = raw["ev"] as? String, let event = EventKind.parse(evText) else { return nil }
        var attribute: String?
        if let attrText = raw["attr"] as? String {
            guard isValidAttributeName(attrText) else { return nil }
            attribute = attrText
        }
        guard let byText = raw["by"] as? String, let createdBy = decodeAuthor(byText) else { return nil }
        guard let tickNumber = raw["t"] as? NSNumber, tickNumber.int64Value >= 0 else { return nil }
        return Subscription(
            id: id, subscriber: subscriber, scriptName: scriptName, handler: handler,
            target: target, event: event, attribute: attribute, createdBy: createdBy,
            createdTick: tickNumber.int64Value
        )
    }

    // MARK: - Author text (mirrors `ObjectRecordCodec`'s private encode/decode
    // — duplicated rather than shared to keep 1a's file untouched)

    private static func encodeAuthor(_ author: Provenance.Author) -> String {
        switch author {
        case .player: return "player"
        case .ai(let model): return "ai:\(model)"
        case .script(let owner, let name): return "script:\(owner.canonical):\(name)"
        case .lan(let peer): return "lan:\(peer)"
        }
    }

    private static func decodeAuthor(_ s: String) -> Provenance.Author? {
        if s == "player" { return .player }
        if s.hasPrefix("ai:") {
            let model = String(s.dropFirst(3))
            guard !model.isEmpty, model.utf8.count <= 64 else { return nil }
            return .ai(model: model)
        }
        if s.hasPrefix("script:") {
            let rest = s.dropFirst(7)
            guard let lastColon = rest.lastIndex(of: ":") else { return nil }
            let refText = String(rest[rest.startIndex..<lastColon])
            let name = String(rest[rest.index(after: lastColon)...])
            guard let ref = ObjectRef.parse(refText), isValidAttributeName(name) else { return nil }
            return .script(owner: ref, name: name)
        }
        if s.hasPrefix("lan:") {
            let peer = String(s.dropFirst(4))
            guard !peer.isEmpty, peer.utf8.count <= 128 else { return nil }
            return .lan(peer: peer)
        }
        return nil
    }

    private static func jsonString(_ s: String) -> String {
        AttrValueCodec.encode(.string(s))
    }
}
