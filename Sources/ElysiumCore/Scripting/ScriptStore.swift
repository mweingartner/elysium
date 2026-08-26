// ScriptStore.swift — script-runtime (change 1c). design.md §6.0/§8.1: "the
// same executors as the player... AttributeStore/ScriptStore" — the script-
// entry twin of `AttributeStore` (change 1a). Same authority model (no
// permission layer — the sandbox, budgets and journal are the safety net),
// same caps/provenance/LAN-client discipline, same `ObjectRecord` storage.
// Persistence-only: attaching a script here does NOT compile or run it —
// that is `ScriptRuntime`'s job at the next script phase (§8.2 "Pending ->
// live only in the phase").

import Foundation

public enum ScriptStoreError: Error, Equatable {
    case objectNotLive
    case dormant
    case unsupported
    case lanClient
    case invalidName(hint: String?)
    case sourceTooLarge(limit: Int)
    case tooManyScripts(limit: Int)
    case recordTooLarge(limit: Int)
    case chunkTooLarge(limit: Int)
    case documentTooLarge(limit: Int)
    case revisionOverflow
    /// §9.5-adjacent: attach/detach are capped per script per tick (§8.4
    /// "attach/detach <= 2 (world <= 32)") — `ScriptRuntime` enforces the
    /// per-script/per-tick verb budget; this case is what it reports back
    /// through the same executor when a *script* author trips it.
    case verbBudgetExceeded
}

/// design.md §8.1: up to 8 scripts per object.
public let maxScriptsPerObject = 8

/// A plain user-facing sentence for a `ScriptStoreError` — shared by
/// `ScriptingCommands` (`/script`) and `ScreensM.swift`'s `ScriptEditorScreen`
/// (Save button) so the two authoring paths never drift.
public func scriptStoreErrorText(_ err: ScriptStoreError) -> String {
    switch err {
    case .objectNotLive: return "target is not loaded"
    case .dormant: return "target's dimension is not loaded"
    case .unsupported: return "unsupported target"
    case .lanClient: return "scripts do not run on LAN clients"
    case .invalidName(let hint):
        return hint.map { "not a valid script name — try '\($0)'" } ?? "not a valid script name"
    case .sourceTooLarge(let limit): return "script source exceeds \(limit) bytes"
    case .tooManyScripts(let limit): return "too many scripts on this object (limit \(limit))"
    case .recordTooLarge, .chunkTooLarge, .documentTooLarge: return "script storage limit exceeded"
    case .revisionOverflow: return "revision limit reached"
    case .verbBudgetExceeded: return "attach/detach budget exceeded"
    }
}

public struct ScriptStore {
    public let graph: ObjectGraph
    public let caps: ScriptingStorageCaps

    public init(graph: ObjectGraph, caps: ScriptingStorageCaps = .defaults) {
        self.graph = graph
        self.caps = caps
    }

    // MARK: - reads

    /// Sorted `(createdTick, name)` — §8.1's own order.
    public func list(_ ref: ObjectRef) -> [ScriptRecord] {
        guard case .live(let live) = graph.resolve(ref) else { return [] }
        let record = AttributeStore.readRecord(live, host: graph.host)
        var out: [ScriptRecord] = []
        for (_, entry) in record.entries {
            if case .script(let s) = entry { out.append(s) }
        }
        out.sort { $0.createdTick == $1.createdTick ? $0.name < $1.name : $0.createdTick < $1.createdTick }
        return out
    }

    public func get(_ ref: ObjectRef, _ name: String) -> ScriptRecord? {
        guard case .live(let live) = graph.resolve(ref) else { return nil }
        guard case .script(let s)? = AttributeStore.readRecord(live, host: graph.host).entries[name] else { return nil }
        return s
    }

    // MARK: - writes

    /// Attaches (creates or re-attaches) a script. Re-attaching an existing
    /// name replaces its source/mode/triggers but keeps the original
    /// `createdTick` and enabled state (stable ordering and user intent across
    /// edits, §8.2 "editing a script replaces the record and re-runs the
    /// lifecycle"). Callers creating a record may explicitly choose its
    /// initial enabled state; otherwise new records default to enabled.
    public func attach(
        _ ref: ObjectRef, name: String, source: String, mode: ScriptMode, triggers: [Trigger],
        enabled requestedEnabled: Bool? = nil, by author: Provenance.Author, tick: Int64
    ) -> Result<ScriptRecord, ScriptStoreError> {
        if graph.host.isLANClient { return .failure(.lanClient) }
        guard case .live(let live) = graph.resolve(ref) else { return .failure(liveFailure(ref)) }
        guard isValidAttributeName(name) else {
            return .failure(.invalidName(hint: normalizedAttributeNameHint(name)))
        }
        guard source.utf8.count <= 16_384 else { return .failure(.sourceTooLarge(limit: 16_384)) }
        var record = AttributeStore.readRecord(live, host: graph.host)
        let existingScriptCount = record.entries.values.filter { if case .script = $0 { return true }; return false }.count
        let isNew: Bool
        let createdTick: Int64
        let enabled: Bool
        if case .script(let existing)? = record.entries[name] {
            isNew = false
            createdTick = existing.createdTick
            enabled = requestedEnabled ?? existing.enabled
        } else {
            isNew = true
            createdTick = tick
            enabled = requestedEnabled ?? true
        }
        if isNew, existingScriptCount >= maxScriptsPerObject {
            return .failure(.tooManyScripts(limit: maxScriptsPerObject))
        }
        guard let newRevision = bumpedRevision(record.revision) else { return .failure(.revisionOverflow) }
        let newScript = ScriptRecord(
            name: name, source: source, enabled: enabled, mode: mode, triggers: triggers,
            author: author, createdTick: createdTick
        )
        var candidate = record
        candidate.entries[name] = .script(newScript)
        candidate.revision = newRevision
        if let err = checkCaps(candidate, live: live, ref: ref) { return .failure(err) }
        record = candidate
        AttributeStore.writeRecord(record, to: live, host: graph.host)
        return .success(newScript)
    }

    /// Removes a script. Existed=false is a no-op, not an error (matches
    /// `AttributeStore.remove`'s own contract).
    public func detach(_ ref: ObjectRef, _ name: String) -> Result<Bool, ScriptStoreError> {
        if graph.host.isLANClient { return .failure(.lanClient) }
        guard case .live(let live) = graph.resolve(ref) else { return .failure(liveFailure(ref)) }
        var record = AttributeStore.readRecord(live, host: graph.host)
        guard case .script? = record.entries[name] else { return .success(false) }
        guard let newRevision = bumpedRevision(record.revision) else { return .failure(.revisionOverflow) }
        record.entries.removeValue(forKey: name)
        record.revision = newRevision
        AttributeStore.writeRecord(record, to: live, host: graph.host)
        return .success(true)
    }

    /// `/script enable|disable`-style toggle without touching the source.
    public func setEnabled(_ ref: ObjectRef, _ name: String, _ enabled: Bool) -> Result<ScriptRecord, ScriptStoreError> {
        if graph.host.isLANClient { return .failure(.lanClient) }
        guard case .live(let live) = graph.resolve(ref) else { return .failure(liveFailure(ref)) }
        var record = AttributeStore.readRecord(live, host: graph.host)
        guard case .script(var s)? = record.entries[name] else { return .failure(.invalidName(hint: nil)) }
        s.enabled = enabled
        guard let newRevision = bumpedRevision(record.revision) else { return .failure(.revisionOverflow) }
        record.entries[name] = .script(s)
        record.revision = newRevision
        AttributeStore.writeRecord(record, to: live, host: graph.host)
        return .success(s)
    }

    /// Persists updated runtime state (RNG words) after a script draws from
    /// `rng()` — called by `ScriptRuntime`, not a player/AI/script path, so
    /// it does not bump `revision` or refuse on a LAN client re-check (the
    /// caller already established liveness this tick) and never fails
    /// silently: an absent record is simply a no-op (the object unloaded
    /// mid-tick).
    public func storeRNGWords(_ ref: ObjectRef, _ name: String, _ words: [UInt32]) {
        guard case .live(let live) = graph.resolve(ref) else { return }
        var record = AttributeStore.readRecord(live, host: graph.host)
        guard case .script(var s)? = record.entries[name] else { return }
        s.rngWords = words
        record.entries[name] = .script(s)
        AttributeStore.writeRecord(record, to: live, host: graph.host)
    }

    /// Records the last fault/compile-error line (runtime-only, §6.7) —
    /// never bumps `revision` (not a durable change) and is a no-op if the
    /// script no longer exists.
    public func storeLastError(_ ref: ObjectRef, _ name: String, _ message: String?) {
        guard case .live(let live) = graph.resolve(ref) else { return }
        var record = AttributeStore.readRecord(live, host: graph.host)
        guard case .script(var s)? = record.entries[name] else { return }
        s.lastError = message
        record.entries[name] = .script(s)
        AttributeStore.writeRecord(record, to: live, host: graph.host)
    }

    // MARK: - helpers

    private func bumpedRevision(_ rev: UInt64) -> UInt64? {
        let (bumped, overflow) = rev.addingReportingOverflow(1)
        return overflow ? nil : bumped
    }

    private func checkCaps(_ candidate: ObjectRecord, live: LiveObject, ref: ObjectRef) -> ScriptStoreError? {
        guard candidate.entries.count <= caps.maxEntriesPerObject else {
            return .tooManyScripts(limit: maxScriptsPerObject)
        }
        let text = ObjectRecordCodec.encode(candidate)
        let isWorldOrDim = ref.kind == .world || ref.kind == .dim
        let recordLimit = isWorldOrDim ? caps.maxWorldDimRecordTextBytes : caps.maxRecordTextBytes
        guard text.utf8.count <= recordLimit else { return .recordTooLarge(limit: recordLimit) }
        if case .block(_, let chunk, let cellIndex, _, _, _) = live {
            var sum = text.utf8.count
            for (idx, rec) in chunk.objectRecords where idx != cellIndex {
                sum += ObjectRecordCodec.encode(rec).utf8.count
            }
            guard sum <= caps.maxChunkObjectBytes else { return .chunkTooLarge(limit: caps.maxChunkObjectBytes) }
        }
        if isWorldOrDim {
            var total = text.utf8.count
            let siblingRefs: [ObjectRef] = [.world, .dimension(.overworld), .dimension(.nether), .dimension(.end)]
            for sibling in siblingRefs where sibling != ref {
                total += ObjectRecordCodec.encode(graph.host.worldObjectRecord(for: sibling)).utf8.count
            }
            guard total <= caps.maxWorldDocumentBytes else { return .documentTooLarge(limit: caps.maxWorldDocumentBytes) }
        }
        return nil
    }

    private func liveFailure(_ ref: ObjectRef) -> ScriptStoreError {
        switch graph.resolve(ref) {
        case .dormant: return .dormant
        case .unsupported: return .unsupported
        default: return .objectNotLive
        }
    }
}
