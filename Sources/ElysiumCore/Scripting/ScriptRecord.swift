// ScriptRecord.swift — script-runtime (change 1c). design.md §8.1/§8.6/§7.3.
// The persisted shape of one script attached to an object: module or handler
// mode, its triggers (handler mode only), provenance, and the four RandomX
// state words that make `rng()` deterministic and durable (§8.6: "its four
// state words are persisted in the script record's runtime state"). Lives in
// the same `ObjectRecord.entries` bag as `.value` entries (§6.0), under the
// sibling "scripts" JSON section `ObjectRecordCodec` owns (1a reserved the
// key; this change is the first to write it).

import Foundation

/// §8.1: "the chunk runs at load, registers handlers" (`.module`) vs "the
/// chunk *is* the handler for its declared triggers" (`.handler`).
public enum ScriptMode: String, Equatable, Sendable {
    case module
    case handler
}

/// A handler-mode script's persisted trigger filter (§7.3/§8.1): the whole
/// chunk runs as the handler for every event matching one of these. Reuses
/// `SubscriptionTarget` (event-bus, change 1b) — a trigger's `target: self`
/// sugar (§7.3) is resolved to `.object(ownerRef)` at attach time, so this
/// type never needs its own "self" case.
public struct Trigger: Equatable, Sendable {
    public var event: EventKind
    public var attribute: String?
    public var target: SubscriptionTarget

    public init(event: EventKind, attribute: String?, target: SubscriptionTarget) {
        self.event = event
        self.attribute = attribute
        self.target = target
    }
}

/// One script attached to one object (design.md §8.1's `ScriptRecord`). Up to
/// 8 per object (`ScriptStore` enforces the cap), order `(createdTick, name)`.
public struct ScriptRecord: Equatable, Sendable {
    /// `[a-z][a-z0-9_]{0,31}`, unique per object.
    public var name: String
    /// <= 16 KiB UTF-8, validator-clean text (checked by `ScriptStore`/the
    /// validator before a record is ever constructed).
    public var source: String
    public var enabled: Bool
    public var mode: ScriptMode
    /// Handler mode only; empty for module mode (module scripts register
    /// their own handlers at load via `on`/`subscribe`, never persisted —
    /// §7.3).
    public var triggers: [Trigger]
    public var author: Provenance.Author
    public var createdTick: Int64
    /// The Lua API version the source was written against (§8.1); always 1
    /// in this change.
    public var apiVersion: Int
    /// §8.6: the per-script `RandomX`'s four sfc32 state words, persisted so
    /// `rng()` survives unload/reload. `nil` until the script's first draw —
    /// at that point the runtime seeds fresh from `(ref, name, createdTick)`
    /// (design.md's own seed formula additionally folds in `worldSeed`; this
    /// change omits that term — see ARCHITECTURE.md's script-runtime section
    /// for the reasoning — a documented, low-risk simplification since the
    /// stream is already unique per script *within* a world).
    public var rngWords: [UInt32]?

    /// Runtime-only (§6.7: "runtime: lastError, sourceHash" — never
    /// persisted; always `nil` immediately after decode, recomputed/set by
    /// the runtime as the script loads/faults).
    public var lastError: String?

    public init(
        name: String, source: String, enabled: Bool, mode: ScriptMode, triggers: [Trigger] = [],
        author: Provenance.Author, createdTick: Int64, apiVersion: Int = 1,
        rngWords: [UInt32]? = nil, lastError: String? = nil
    ) {
        self.name = name
        self.source = source
        self.enabled = enabled
        self.mode = mode
        self.triggers = triggers
        self.author = author
        self.createdTick = createdTick
        self.apiVersion = apiVersion
        self.rngWords = rngWords
        self.lastError = lastError
    }

    /// Equality over the *persisted* shape only — `lastError` is runtime
    /// bookkeeping (matches its own doc comment) and `rngWords` advances on
    /// every `rng()` draw, so neither belongs in a value-equality comparison
    /// callers use for "is this the same script" (persistence round-trip
    /// tests compare fields individually where the RNG state matters).
    public static func == (lhs: ScriptRecord, rhs: ScriptRecord) -> Bool {
        lhs.name == rhs.name && lhs.source == rhs.source && lhs.enabled == rhs.enabled
            && lhs.mode == rhs.mode && lhs.triggers == rhs.triggers && lhs.author == rhs.author
            && lhs.createdTick == rhs.createdTick && lhs.apiVersion == rhs.apiVersion
    }
}

// MARK: - codec (the "scripts" section, sibling of "attrs" in `ObjectRecordCodec`)

public enum ScriptRecordCodec {
    public static func encode(_ record: ScriptRecord) -> String {
        var out = "{\"src\":"
        out += AttrValueCodec.encode(.string(record.source))
        out += ",\"en\":"
        out += record.enabled ? "true" : "false"
        out += ",\"mode\":\""
        out += record.mode.rawValue
        out += "\",\"by\":"
        out += AttrValueCodec.encode(.string(encodeAuthor(record.author)))
        out += ",\"t\":\(record.createdTick)"
        out += ",\"api\":\(record.apiVersion)"
        if !record.triggers.isEmpty {
            out += ",\"trig\":["
            for (i, trigger) in record.triggers.enumerated() {
                if i > 0 { out += "," }
                out += "{\"ev\":"
                out += AttrValueCodec.encode(.string(trigger.event.rawValue))
                if let attribute = trigger.attribute {
                    out += ",\"attr\":"
                    out += AttrValueCodec.encode(.string(attribute))
                }
                out += ",\"tgt\":"
                out += AttrValueCodec.encode(.string(trigger.target.canonicalText))
                out += "}"
            }
            out += "]"
        }
        if let rngWords = record.rngWords, rngWords.count == 4 {
            out += ",\"rng\":[\(rngWords[0]),\(rngWords[1]),\(rngWords[2]),\(rngWords[3])]"
        }
        out += "}"
        return out
    }

    /// Tolerant decode: a malformed script entry returns `nil` (the caller —
    /// `ObjectRecordCodec` — drops it with a diagnostic, exactly like a
    /// malformed `.value` entry; never the containing record).
    public static func decode(_ text: [UInt8], _ start: Int, _ end: Int, name: String) -> ScriptRecord? {
        guard let root = try? JSONSerialization.jsonObject(
            with: Data(text[start..<end]), options: [.fragmentsAllowed]
        ) as? [String: Any] else { return nil }
        guard let source = root["src"] as? String, source.utf8.count <= 16_384 else { return nil }
        guard let enabled = root["en"] as? Bool else { return nil }
        guard let modeText = root["mode"] as? String, let mode = ScriptMode(rawValue: modeText) else { return nil }
        guard let byText = root["by"] as? String, let author = decodeAuthor(byText) else { return nil }
        guard let tickNumber = root["t"] as? NSNumber, tickNumber.int64Value >= 0 else { return nil }
        let apiVersion = (root["api"] as? NSNumber)?.intValue ?? 1
        var triggers: [Trigger] = []
        if let rawTriggers = root["trig"] as? [[String: Any]] {
            for raw in rawTriggers {
                guard let evText = raw["ev"] as? String, let event = EventKind.parse(evText) else { return nil }
                guard let tgtText = raw["tgt"] as? String, let target = SubscriptionTarget.parse(tgtText) else { return nil }
                var attribute: String?
                if let attrText = raw["attr"] as? String {
                    guard isValidAttributeName(attrText) else { return nil }
                    attribute = attrText
                }
                triggers.append(Trigger(event: event, attribute: attribute, target: target))
            }
        }
        var rngWords: [UInt32]?
        if let rawRng = root["rng"] as? [NSNumber], rawRng.count == 4 {
            rngWords = rawRng.map { UInt32(truncatingIfNeeded: $0.int64Value) }
        }
        return ScriptRecord(
            name: name, source: source, enabled: enabled, mode: mode, triggers: triggers,
            author: author, createdTick: tickNumber.int64Value, apiVersion: apiVersion, rngWords: rngWords
        )
    }

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
}
