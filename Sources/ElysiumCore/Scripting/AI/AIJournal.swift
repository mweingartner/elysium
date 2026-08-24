// AIJournal.swift — ai-object-graph (change 2). design.md §9.5: "aiJournal in
// the world registry is a ring: <= 64 entries, <= 64 KiB total; each entry =
// tool, args digest, tick, model, before/after hashes; full previous sources
// kept only for the last 4 script edits (<= 64 KiB side list)." Mutations
// made by the AI tool loop (`AIObjectGraphMutationTools`) are journaled here
// and quarantined behind this ring/undo boundary — the model's own
// nondeterminism never touches game state through any path this journal does
// not also record (invariant carried over from §9.7's trust posture).
//
// Undo granularity is the **request**, not the individual entry (§9.1: "<= 4
// mutations per request = one undo group"): every entry created while one
// `/ai` tool-loop invocation ran shares a `requestID`; `/script undo-ai [n]`
// reverts the `n` most recent *requests*' worth of entries (default 1), most
// recent mutation first within each request.
//
// One `AIJournal` per open world session (`GameScriptingState.aiJournal`,
// same class-owned/replace-not-mutate lifecycle as `EventBus`), persisted via
// `WorldRecord.aiJournal` exactly like `scriptRegistry`/`scriptTimers`
// (opaque text, empty when there is nothing to save).

import CryptoKit
import Foundation

/// What one journal entry needs to actually reverse the mutation it records
/// — never a copy of arbitrary state; only what the specific tool's undo
/// requires.
public enum AIJournalUndo: Equatable, Sendable {
    /// `before == nil` means the attribute did not exist before this entry's
    /// tool ran — undo removes it. Otherwise undo restores `before`/
    /// `beforeReadonly` via `AttributeStore.define(..., force: true)` (so a
    /// readonly entry the AI itself just created can always be reverted).
    case attributeValue(ref: ObjectRef, name: String, before: AttrValue?, beforeReadonly: Bool)
    /// `attach_script`/`detach_script`. `wasDetach == false` (an attach):
    /// `hadPrevious == false` means it created a brand-new script — undo
    /// detaches it; `hadPrevious == true` means it replaced an existing one
    /// — undo re-attaches the full previous record (kept in
    /// `AIJournal.previousScriptSources`, keyed by this entry's `id`), gated
    /// by a CAS check against the *current* script's `sourceHash` equalling
    /// this entry's `afterHash` (refuses — does not silently overwrite — if
    /// the player has edited the script since). `wasDetach == true`: undo
    /// re-attaches the deleted record (`hadPrevious` is always `true` in
    /// this case), gated on nothing now occupying `name` (refuses if the
    /// player has since attached a *different* script under the same name).
    case scriptRecord(ref: ObjectRef, name: String, hadPrevious: Bool, wasDetach: Bool)
    /// `enable_script` — undo flips `enabled` back. No CAS: the source
    /// itself did not change, so there is nothing for a concurrent player
    /// edit to conflict with beyond the script still existing.
    case scriptEnabled(ref: ObjectRef, name: String, before: Bool)
    /// A subscription this tool call created — undo unsubscribes it. (The
    /// `subscribe` tool only ever creates; upserting an identical key is a
    /// no-op the mutation tool never journals — see `EventBus.subscribe`'s
    /// own idempotent-upsert contract.)
    case subscriptionCreated(id: UInt64)
    /// Nothing to revert: `emit_event` (the event may already have been
    /// delivered) and `run_script` (ephemeral; whatever it did is a world
    /// effect, not a record) are journaled for visibility only — matches
    /// §9.5's receipt wording: "world effects of scripts that already ran
    /// are not reverted."
    case none

    var kindText: String {
        switch self {
        case .attributeValue: return "attribute"
        case .scriptRecord, .scriptEnabled: return "script"
        case .subscriptionCreated: return "subscription"
        case .none: return "none"
        }
    }
}

/// One entry in the ring. Compact by design — the ring's own byte budget
/// (`AIJournal.maxTotalBytes`) is enforced on the *encoded* form, so every
/// field here is already as small as the undo it backs allows.
public struct AIJournalEntry: Equatable, Sendable {
    public var id: UInt64
    public var requestID: UInt64
    public var tool: String
    public var refText: String
    public var name: String
    public var tick: Int64
    public var model: String
    public var afterHash: String
    public var undo: AIJournalUndo
}

/// One item the `/ai` loop can undo, addressed by `undo-ai [n]` — a whole
/// request's worth of entries, oldest request last (so `n=1` is "the most
/// recent request").
public struct AIUndoGroupResult {
    public var requestID: UInt64
    public var lines: [String]
}

public final class AIJournal {
    public static let maxEntries = 64
    public static let maxTotalBytes = 64 * 1024
    public static let maxSourceSideListEntries = 4
    public static let maxSourceSideListBytes = 64 * 1024

    public private(set) var entries: [AIJournalEntry] = []
    /// The side list §9.5 calls out separately: the full previous
    /// `ScriptRecord` (encoded via `ScriptRecordCodec`, so mode/triggers/
    /// enabled round-trip losslessly, not just source text) for the last
    /// <= 4 script edits, keyed by the journal entry id whose undo needs it.
    /// Never grows past the entry list itself (an entry dropped from the
    /// ring has its side-list record dropped too).
    public private(set) var previousScriptSources: [UInt64: String] = [:]
    private var nextEntryID: UInt64 = 1
    private var nextRequestID: UInt64 = 1

    public init() {}

    /// One call per `/ai` tool-loop invocation, before any of its mutations
    /// run — every entry that invocation's mutation tools record shares the
    /// returned id.
    public func beginRequest() -> UInt64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    @discardableResult
    public func record(
        requestID: UInt64, tool: String, ref: ObjectRef, name: String, tick: Int64, model: String,
        afterHash: String, undo: AIJournalUndo, previousSource: String? = nil
    ) -> UInt64 {
        let id = nextEntryID
        nextEntryID += 1
        entries.append(AIJournalEntry(
            id: id, requestID: requestID, tool: tool, refText: ref.canonical, name: name,
            tick: tick, model: model, afterHash: afterHash, undo: undo
        ))
        if let previousSource {
            previousScriptSources[id] = previousSource
        }
        trim()
        return id
    }

    /// Enforces both the ring's entry-count cap and its total-byte cap
    /// (dropping the oldest entries first — a ring, not a truncating buffer),
    /// then the side list's own independent caps, then drops any orphaned
    /// side-list source whose entry no longer exists.
    private func trim() {
        while entries.count > Self.maxEntries {
            let dropped = entries.removeFirst()
            previousScriptSources.removeValue(forKey: dropped.id)
        }
        while AIJournalCodec.encode(self).utf8.count > Self.maxTotalBytes, !entries.isEmpty {
            let dropped = entries.removeFirst()
            previousScriptSources.removeValue(forKey: dropped.id)
        }
        let liveIDs = Set(entries.map(\.id))
        previousScriptSources = previousScriptSources.filter { liveIDs.contains($0.key) }
        while previousScriptSources.count > Self.maxSourceSideListEntries {
            guard let oldest = previousScriptSources.keys.min() else { break }
            previousScriptSources.removeValue(forKey: oldest)
        }
        while sideListBytes() > Self.maxSourceSideListBytes, let oldest = previousScriptSources.keys.min() {
            previousScriptSources.removeValue(forKey: oldest)
        }
    }

    private func sideListBytes() -> Int {
        previousScriptSources.values.reduce(0) { $0 + $1.utf8.count }
    }

    /// `/script journal` (§12): most-recent first, capped for display like
    /// every other scripting command listing.
    public func list(limit: Int = 32) -> [AIJournalEntry] {
        Array(entries.reversed().prefix(max(0, limit)))
    }

    /// `/script undo-ai [n]` (default 1): reverts the `n` most-recently-
    /// touched requests, most recent request first, most recent mutation
    /// within a request first. `context` is the live store/graph/eventBus
    /// this world session is using right now. Returns one line per attempted
    /// undo (success or refusal) plus a trailing summary — reverted entries
    /// (and their side-list source, if any) are removed from the ring so a
    /// second `undo-ai` does not re-attempt them.
    public func undo(groups n: Int, context: AIUndoContext) -> [String] {
        guard n > 0, !entries.isEmpty else { return ["nothing to undo"] }
        let requestIDs = Array(Set(entries.map(\.requestID))).sorted(by: >).prefix(n)
        guard !requestIDs.isEmpty else { return ["nothing to undo"] }
        var lines: [String] = []
        var revertedEntryIDs: [UInt64] = []
        for requestID in requestIDs {
            let group = entries.filter { $0.requestID == requestID }.sorted { $0.id > $1.id }
            guard !group.isEmpty else { continue }
            lines.append("request #\(requestID) (\(group.count) mutation\(group.count == 1 ? "" : "s")):")
            for entry in group {
                let (line, reverted) = undoOne(entry, context: context)
                lines.append("  " + line)
                if reverted { revertedEntryIDs.append(entry.id) }
            }
        }
        for id in revertedEntryIDs {
            entries.removeAll { $0.id == id }
            previousScriptSources.removeValue(forKey: id)
        }
        return lines
    }

    private func undoOne(_ entry: AIJournalEntry, context: AIUndoContext) -> (line: String, reverted: Bool) {
        switch entry.undo {
        case .none:
            return ("\(entry.tool) \(entry.refText): nothing to revert (world effects already ran)", true)
        case .attributeValue(let ref, let name, let before, let beforeReadonly):
            guard case .live = context.graph.resolve(ref) else {
                return ("\(ref.canonical).\(name): object is not loaded — skipped", false)
            }
            if let before {
                switch context.store.define(ref, name, before, readonly: beforeReadonly, force: true, by: .player) {
                case .success: return ("\(ref.canonical).\(name) restored to its previous value", true)
                case .failure(let err): return ("\(ref.canonical).\(name): \(err) — skipped", false)
                }
            } else {
                _ = context.store.remove(ref, name, force: true)
                return ("\(ref.canonical).\(name) removed (was newly created by the AI)", true)
            }
        case .scriptRecord(let ref, let name, let hadPrevious, let wasDetach):
            guard case .live = context.graph.resolve(ref) else {
                return ("\(ref.canonical).\(name): object is not loaded — skipped", false)
            }
            let current = context.scriptStore.get(ref, name)
            if wasDetach {
                // Undo of a detach expects nothing to occupy `name` now — if
                // something does (the player re-attached, or another AI
                // request did), refuse rather than clobber it.
                guard current == nil else {
                    return ("\(ref.canonical).\(name): a script now exists here — refusing to overwrite", false)
                }
                return restorePrevious(entry: entry, ref: ref, name: name, context: context)
            }
            guard let current else {
                return ("\(ref.canonical).\(name): script no longer exists — skipped", true)
            }
            guard sha256Hex(current.source) == entry.afterHash else {
                return ("\(ref.canonical).\(name): edited since the AI attached it — refusing to undo", false)
            }
            if hadPrevious {
                return restorePrevious(entry: entry, ref: ref, name: name, context: context)
            }
            switch context.scriptStore.detach(ref, name) {
            case .success: return ("\(ref.canonical).\(name) detached (was newly created by the AI)", true)
            case .failure(let err): return ("\(ref.canonical).\(name): \(scriptStoreErrorText(err)) — skipped", false)
            }
        case .scriptEnabled(let ref, let name, let before):
            guard case .live = context.graph.resolve(ref) else {
                return ("\(ref.canonical).\(name): object is not loaded — skipped", false)
            }
            switch context.scriptStore.setEnabled(ref, name, before) {
            case .success: return ("\(ref.canonical).\(name) \(before ? "re-enabled" : "disabled")", true)
            case .failure(let err): return ("\(ref.canonical).\(name): \(scriptStoreErrorText(err)) — skipped", false)
            }
        case .subscriptionCreated(let id):
            guard context.eventBus.unsubscribe(id: id) else {
                return ("subscription #\(id) no longer exists — skipped", true)
            }
            return ("subscription #\(id) removed", true)
        }
    }

    /// Decodes the side-list record for `entry.id` and re-attaches it —
    /// shared by both the "replaced an existing script" attach-undo branch
    /// and the detach-undo branch, which restore the exact same way once
    /// their respective preconditions are satisfied.
    private func restorePrevious(entry: AIJournalEntry, ref: ObjectRef, name: String, context: AIUndoContext) -> (line: String, reverted: Bool) {
        guard let encoded = previousScriptSources[entry.id] else {
            return ("\(ref.canonical).\(name): previous version no longer retained — skipped", false)
        }
        let bytes = Array(encoded.utf8)
        guard let previous = ScriptRecordCodec.decode(bytes, 0, bytes.count, name: name) else {
            return ("\(ref.canonical).\(name): previous version could not be decoded — skipped", false)
        }
        switch context.scriptStore.attach(
            ref, name: name, source: previous.source, mode: previous.mode, triggers: previous.triggers,
            by: .player, tick: context.tick
        ) {
        case .success:
            _ = context.scriptStore.setEnabled(ref, name, previous.enabled)
            return ("\(ref.canonical).\(name) restored to its previous version", true)
        case .failure(let err):
            return ("\(ref.canonical).\(name): \(scriptStoreErrorText(err)) — skipped", false)
        }
    }

    // MARK: - persistence (WorldRecord.aiJournal)

    public func loadPersisted(from text: String, diagnostic: (String) -> Void = { _ in }) {
        guard let decoded = AIJournalCodec.decode(text, diagnostic: diagnostic) else {
            entries = []
            previousScriptSources = [:]
            nextEntryID = 1
            nextRequestID = 1
            return
        }
        entries = decoded.entries
        previousScriptSources = decoded.previousScriptSources
        nextEntryID = (entries.map(\.id).max() ?? 0) + 1
        nextRequestID = (entries.map(\.requestID).max() ?? 0) + 1
    }

    public func encodePersisted() -> String {
        entries.isEmpty ? "" : AIJournalCodec.encode(self)
    }

    public var isEmpty: Bool { entries.isEmpty }
}

/// The live context `AIJournal.undo` needs to actually perform a reversal —
/// mirrors `ScriptingCommandContext`'s own bundle, kept smaller since undo
/// only ever touches attributes/scripts/subscriptions.
public struct AIUndoContext {
    public let graph: ObjectGraph
    public let store: AttributeStore
    public let scriptStore: ScriptStore
    public let eventBus: EventBus
    public let tick: Int64

    public init(graph: ObjectGraph, store: AttributeStore, scriptStore: ScriptStore, eventBus: EventBus, tick: Int64) {
        self.graph = graph
        self.store = store
        self.scriptStore = scriptStore
        self.eventBus = eventBus
        self.tick = tick
    }
}

// MARK: - codec

enum AIJournalCodec {
    static func encode(_ journal: AIJournal) -> String {
        var out = "{\"entries\":["
        var first = true
        for entry in journal.entries {
            if !first { out += "," }
            first = false
            out += encodeEntry(entry)
        }
        out += "],\"src\":{"
        var firstSrc = true
        for id in journal.previousScriptSources.keys.sorted() {
            if !firstSrc { out += "," }
            firstSrc = false
            out += "\"\(id)\":" + jsonString(journal.previousScriptSources[id]!)
        }
        out += "},\"v\":1}"
        return out
    }

    private static func encodeEntry(_ e: AIJournalEntry) -> String {
        var out = "{\"id\":\(e.id),\"req\":\(e.requestID)"
        out += ",\"tool\":" + jsonString(e.tool)
        out += ",\"ref\":" + jsonString(e.refText)
        out += ",\"name\":" + jsonString(e.name)
        out += ",\"t\":\(e.tick)"
        out += ",\"model\":" + jsonString(e.model)
        out += ",\"after\":" + jsonString(e.afterHash)
        out += ",\"undo\":" + encodeUndo(e.undo)
        out += "}"
        return out
    }

    private static func encodeUndo(_ undo: AIJournalUndo) -> String {
        switch undo {
        case .none:
            return "{\"k\":\"none\"}"
        case .attributeValue(let ref, let name, let before, let readonly):
            var out = "{\"k\":\"attr\",\"ref\":" + jsonString(ref.canonical) + ",\"name\":" + jsonString(name)
            out += ",\"ro\":" + (readonly ? "true" : "false")
            if let before { out += ",\"before\":" + AttrValueCodec.encode(before) }
            out += "}"
            return out
        case .scriptRecord(let ref, let name, let hadPrevious, let wasDetach):
            var out = "{\"k\":\"script\",\"ref\":" + jsonString(ref.canonical) + ",\"name\":" + jsonString(name)
            out += ",\"had\":" + (hadPrevious ? "true" : "false")
            out += ",\"detach\":" + (wasDetach ? "true" : "false")
            out += "}"
            return out
        case .scriptEnabled(let ref, let name, let before):
            var out = "{\"k\":\"scripten\",\"ref\":" + jsonString(ref.canonical) + ",\"name\":" + jsonString(name)
            out += ",\"before\":" + (before ? "true" : "false")
            out += "}"
            return out
        case .subscriptionCreated(let id):
            return "{\"k\":\"sub\",\"id\":\(id)}"
        }
    }

    static func decode(_ text: String, diagnostic: (String) -> Void) -> (entries: [AIJournalEntry], previousScriptSources: [UInt64: String])? {
        guard text.utf8.count <= AIJournal.maxTotalBytes * 2 else { return nil } // generous pre-decode backstop
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
        guard (root["v"] as? NSNumber)?.intValue == 1 else { return nil }
        guard let rawEntries = root["entries"] as? [[String: Any]] else { return nil }
        var entries: [AIJournalEntry] = []
        var seenIDs = Set<UInt64>()
        for raw in rawEntries {
            guard let entry = decodeEntry(raw), !seenIDs.contains(entry.id) else {
                diagnostic("dropped malformed or duplicate-id AI journal entry")
                continue
            }
            seenIDs.insert(entry.id)
            entries.append(entry)
        }
        var sources: [UInt64: String] = [:]
        if let rawSrc = root["src"] as? [String: Any] {
            for (key, value) in rawSrc {
                guard let id = UInt64(key), seenIDs.contains(id), let text = value as? String else { continue }
                sources[id] = text
            }
        }
        return (entries, sources)
    }

    private static func decodeEntry(_ raw: [String: Any]) -> AIJournalEntry? {
        guard let idNumber = raw["id"] as? NSNumber, idNumber.int64Value >= 0 else { return nil }
        guard let reqNumber = raw["req"] as? NSNumber, reqNumber.int64Value >= 0 else { return nil }
        guard let tool = raw["tool"] as? String, !tool.isEmpty, tool.utf8.count <= 64 else { return nil }
        guard let refText = raw["ref"] as? String, ObjectRef.parse(refText) != nil else { return nil }
        guard let name = raw["name"] as? String, name.utf8.count <= 64 else { return nil }
        guard let tickNumber = raw["t"] as? NSNumber, tickNumber.int64Value >= 0 else { return nil }
        guard let model = raw["model"] as? String, model.utf8.count <= 64 else { return nil }
        guard let after = raw["after"] as? String, after.utf8.count <= 128 else { return nil }
        guard let rawUndo = raw["undo"] as? [String: Any], let undo = decodeUndo(rawUndo) else { return nil }
        return AIJournalEntry(
            id: UInt64(idNumber.uint64Value), requestID: UInt64(reqNumber.uint64Value), tool: tool,
            refText: refText, name: name, tick: tickNumber.int64Value, model: model, afterHash: after, undo: undo
        )
    }

    private static func decodeUndo(_ raw: [String: Any]) -> AIJournalUndo? {
        guard let kind = raw["k"] as? String else { return nil }
        switch kind {
        case "none":
            return AIJournalUndo.none
        case "attr":
            guard let refText = raw["ref"] as? String, let ref = ObjectRef.parse(refText) else { return nil }
            guard let name = raw["name"] as? String, isValidAttributeName(name) else { return nil }
            guard let readonly = raw["ro"] as? Bool else { return nil }
            var before: AttrValue?
            if let beforeRaw = raw["before"] {
                let text = (try? JSONSerialization.data(withJSONObject: beforeRaw)).flatMap { String(data: $0, encoding: .utf8) }
                // The value was originally produced by `AttrValueCodec.encode`, so
                // re-encode via `JSONSerialization` round-trip only as a bridge —
                // decode strictly through the canonical codec, never trust the bridge.
                guard let text, case .success(let v) = AttrValueCodec.decode(text, caps: .defaults) else { return nil }
                before = v
            }
            return .attributeValue(ref: ref, name: name, before: before, beforeReadonly: readonly)
        case "script":
            guard let refText = raw["ref"] as? String, let ref = ObjectRef.parse(refText) else { return nil }
            guard let name = raw["name"] as? String, isValidAttributeName(name) else { return nil }
            guard let had = raw["had"] as? Bool else { return nil }
            let wasDetach = (raw["detach"] as? Bool) ?? false
            return .scriptRecord(ref: ref, name: name, hadPrevious: had, wasDetach: wasDetach)
        case "scripten":
            guard let refText = raw["ref"] as? String, let ref = ObjectRef.parse(refText) else { return nil }
            guard let name = raw["name"] as? String, isValidAttributeName(name) else { return nil }
            guard let before = raw["before"] as? Bool else { return nil }
            return .scriptEnabled(ref: ref, name: name, before: before)
        case "sub":
            guard let idNumber = raw["id"] as? NSNumber, idNumber.int64Value >= 0 else { return nil }
            return .subscriptionCreated(id: UInt64(idNumber.uint64Value))
        default:
            return nil
        }
    }

    private static func jsonString(_ s: String) -> String { AttrValueCodec.encode(.string(s)) }
}

/// SHA-256 hex, used for `sourceHash` CAS checks (matches
/// `ScriptValidator.accepted(sourceSHA256:)`'s own hex format — duplicated
/// here rather than exposed from `ElysiumScript` because the journal only
/// ever needs to *compare* hashes, never produce the validator's own).
func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}
