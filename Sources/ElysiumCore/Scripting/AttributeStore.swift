// AttributeStore.swift — object-graph-attributes (change 1a). design.md
// Decision 6 / spec `object-attribute-store` "AttributeStore is the single
// executor". The only writer of any `ObjectRecord` (chunk cell, entity/
// player, world/dimension bag). Reads are lenient and side-effect-free;
// writes validate name/value/readonly/caps, bump the revision, record
// provenance, mark the owning chunk `modified`, and call the `onChange` seam.

import Foundation

/// Every way a mutation can be refused. Carries only the context a generic
/// caller needs (an exceeded limit, or the underlying `AttrValueError`) —
/// `ScriptingCommands` composes the final user-facing sentence with the ref/
/// name it already has (Decision 10 owns display text).
public enum AttributeError: Error, Equatable {
    case objectNotLive
    case dormant
    case unsupported
    case invalidName(hint: String?)
    case nameIsBuiltIn
    /// The shared ObjectRecord namespace already contains an attached script with this name.
    /// Attribute APIs never replace it; callers must detach the script explicitly first.
    case nameIsScript
    case invalidValue(AttrValueError)
    case readonly
    case tooManyEntries(limit: Int)
    case recordTooLarge(limit: Int)
    case chunkTooLarge(limit: Int)
    case documentTooLarge(limit: Int)
    /// Security (plan) C27: refused before any Core mutation work runs — the
    /// host is a transient LAN client (guest); only the host is authoritative.
    case lanClient
    /// Security (plan) C26: the revision counter is already at its clamped
    /// ceiling (practically unreachable — `ObjectRecordCodec.decode` clamps
    /// `rev` to leave 1,000,000 bumps of headroom) — refused rather than
    /// silently skipping the bump.
    case revisionOverflow
}

public struct AttributeStore {
    public let graph: ObjectGraph
    public let caps: ScriptingStorageCaps
    /// The event-bus `attribute.changed` seam (change 1b). Called with
    /// `(ref, name, oldValue, newValue, revision, author)` after every
    /// successful mutation; `newValue == nil` on `remove`. `author` is the
    /// same `Provenance.Author` recorded on the entry — 1b's caller maps it
    /// to an `EventSource` so `attribute.changed`'s `source` is accurate once
    /// scripts/the AI (1c/phase 2) also write through this store.
    public var onChange: ((ObjectRef, String, AttrValue?, AttrValue?, UInt64, Provenance.Author) -> Void)?

    public init(
        graph: ObjectGraph, caps: ScriptingStorageCaps = .defaults,
        onChange: ((ObjectRef, String, AttrValue?, AttrValue?, UInt64, Provenance.Author) -> Void)? = nil
    ) {
        self.graph = graph
        self.caps = caps
        self.onChange = onChange
    }

    // MARK: - reads (lenient, side-effect-free)

    public func get(_ ref: ObjectRef, _ name: String) -> AttrValue? {
        guard case .live(let live) = graph.resolve(ref) else { return nil }
        guard case .value(let v, _, _)? = Self.readRecord(live, host: graph.host).entries[name] else { return nil }
        return v
    }

    /// Sorted by name (spec "list(ref) (sorted by name)").
    public func list(_ ref: ObjectRef) -> [(name: String, value: AttrValue, readonly: Bool)] {
        guard case .live(let live) = graph.resolve(ref) else { return [] }
        let record = Self.readRecord(live, host: graph.host)
        return record.entries.keys.sorted(by: utf8Less).compactMap { name in
            guard case .value(let v, let ro, _)? = record.entries[name] else { return nil }
            return (name, v, ro)
        }
    }

    public func record(_ ref: ObjectRef) -> ObjectRecord? {
        guard case .live(let live) = graph.resolve(ref) else { return nil }
        return Self.readRecord(live, host: graph.host)
    }

    // MARK: - writes

    private struct SetPlan {
        var live: LiveObject
        var candidate: ObjectRecord?
        var oldValue: AttrValue?
        var value: AttrValue
    }

    private struct DefinePlan {
        var live: LiveObject
        var candidate: ObjectRecord?
        var oldValue: AttrValue?
        var value: AttrValue
        var forced: Bool
    }

    private struct RemovePlan {
        var live: LiveObject
        var candidate: ObjectRecord?
        var oldValue: AttrValue?
        var existed: Bool
        var forced: Bool
    }

    /// Creates or updates a *mutable* custom entry. Refuses a built-in name,
    /// an invalid name/value, a readonly entry, or a cap.
    public func set(
        _ ref: ObjectRef, _ name: String, _ value: AttrValue, by author: Provenance.Author = .player
    ) -> Result<AttrValue, AttributeError> {
        switch planSet(ref, name, value, by: author) {
        case .failure(let error):
            return .failure(error)
        case .success(let plan):
            guard let candidate = plan.candidate else { return .success(plan.value) }
            Self.writeRecord(candidate, to: plan.live, host: graph.host)
            onChange?(ref, name, plan.oldValue, plan.value, candidate.revision, author)
            return .success(plan.value)
        }
    }

    /// Runs the exact `set` admission path without committing the candidate record or publishing
    /// `attribute.changed`. Script Check/dry-run uses this instead of accepting mutations blindly.
    public func validateSet(
        _ ref: ObjectRef, _ name: String, _ value: AttrValue,
        by author: Provenance.Author = .player
    ) -> Result<AttrValue, AttributeError> {
        planSet(ref, name, value, by: author).map(\.value)
    }

    private func planSet(
        _ ref: ObjectRef, _ name: String, _ value: AttrValue, by author: Provenance.Author
    ) -> Result<SetPlan, AttributeError> {
        if graph.host.isLANClient { return .failure(.lanClient) } // Security (plan) C27
        guard case .live(let live) = graph.resolve(ref) else { return .failure(liveFailure(ref)) }
        if let err = validateNameAndValue(name: name, value: value, kind: ref.kind) { return .failure(err) }
        let record = Self.readRecord(live, host: graph.host)
        if case .script? = record.entries[name] { return .failure(.nameIsScript) }
        if case .value(let existing, let readonly, _)? = record.entries[name] {
            if readonly { return .failure(.readonly) }
            if existing == value {
                return .success(SetPlan(
                    live: live, candidate: nil, oldValue: existing, value: value
                ))
            }
        }
        guard let newRevision = bumpedRevision(record.revision) else { return .failure(.revisionOverflow) }
        var candidate = record
        candidate.entries[name] = .value(value, readonly: false, provenance: Provenance(createdBy: author, createdTick: graph.host.currentTick))
        candidate.revision = newRevision
        if let err = checkCaps(candidate, live: live, ref: ref) { return .failure(err) }
        return .success(SetPlan(
            live: live, candidate: candidate,
            oldValue: Self.extractValue(record.entries[name]), value: value
        ))
    }

    /// Creates or overwrites an entry, optionally `readonly`. `force` is
    /// required to overwrite an existing readonly entry and is always
    /// reported back as a notice.
    public func define(
        _ ref: ObjectRef, _ name: String, _ value: AttrValue, readonly: Bool, force: Bool = false,
        by author: Provenance.Author = .player
    ) -> Result<(value: AttrValue, forced: Bool), AttributeError> {
        switch planDefine(ref, name, value, readonly: readonly, force: force, by: author) {
        case .failure(let error):
            return .failure(error)
        case .success(let plan):
            guard let candidate = plan.candidate else {
                return .success((plan.value, plan.forced))
            }
            Self.writeRecord(candidate, to: plan.live, host: graph.host)
            if plan.oldValue != plan.value {
                onChange?(ref, name, plan.oldValue, plan.value, candidate.revision, author)
            }
            return .success((plan.value, plan.forced))
        }
    }

    /// Runs the exact `define` admission path without committing its candidate record.
    public func validateDefine(
        _ ref: ObjectRef, _ name: String, _ value: AttrValue, readonly: Bool,
        force: Bool = false, by author: Provenance.Author = .player
    ) -> Result<(value: AttrValue, forced: Bool), AttributeError> {
        planDefine(ref, name, value, readonly: readonly, force: force, by: author).map {
            ($0.value, $0.forced)
        }
    }

    private func planDefine(
        _ ref: ObjectRef, _ name: String, _ value: AttrValue, readonly: Bool, force: Bool,
        by author: Provenance.Author
    ) -> Result<DefinePlan, AttributeError> {
        if graph.host.isLANClient { return .failure(.lanClient) } // Security (plan) C27
        guard case .live(let live) = graph.resolve(ref) else { return .failure(liveFailure(ref)) }
        if let err = validateNameAndValue(name: name, value: value, kind: ref.kind) { return .failure(err) }
        let record = Self.readRecord(live, host: graph.host)
        if case .script? = record.entries[name] { return .failure(.nameIsScript) }
        var forced = false
        if case .value(let existingValue, let existingReadonly, _)? = record.entries[name] {
            if existingValue == value, existingReadonly == readonly {
                return .success(DefinePlan(
                    live: live, candidate: nil, oldValue: existingValue, value: value,
                    forced: false
                ))
            }
            if existingReadonly {
                guard force else { return .failure(.readonly) }
                forced = true
            }
        }
        guard let newRevision = bumpedRevision(record.revision) else { return .failure(.revisionOverflow) }
        var candidate = record
        candidate.entries[name] = .value(
            value, readonly: readonly, provenance: Provenance(createdBy: author, createdTick: graph.host.currentTick)
        )
        candidate.revision = newRevision
        if let err = checkCaps(candidate, live: live, ref: ref) { return .failure(err) }
        return .success(DefinePlan(
            live: live, candidate: candidate,
            oldValue: Self.extractValue(record.entries[name]), value: value, forced: forced
        ))
    }

    /// Removes a custom entry. `force` is required for a readonly entry and
    /// is reported back as `forced`. Removing an absent entry is a no-op
    /// (`existed == false`, not an error).
    public func remove(
        _ ref: ObjectRef, _ name: String, force: Bool = false, by author: Provenance.Author = .player
    ) -> Result<(existed: Bool, forced: Bool), AttributeError> {
        switch planRemove(ref, name, force: force) {
        case .failure(let error):
            return .failure(error)
        case .success(let plan):
            guard let candidate = plan.candidate else {
                return .success((plan.existed, plan.forced))
            }
            Self.writeRecord(candidate, to: plan.live, host: graph.host)
            onChange?(ref, name, plan.oldValue, nil, candidate.revision, author)
            return .success((plan.existed, plan.forced))
        }
    }

    /// Runs the exact `remove` admission path without committing its candidate record.
    public func validateRemove(
        _ ref: ObjectRef, _ name: String, force: Bool = false
    ) -> Result<(existed: Bool, forced: Bool), AttributeError> {
        planRemove(ref, name, force: force).map { ($0.existed, $0.forced) }
    }

    private func planRemove(
        _ ref: ObjectRef, _ name: String, force: Bool
    ) -> Result<RemovePlan, AttributeError> {
        if graph.host.isLANClient { return .failure(.lanClient) } // Security (plan) C27
        guard case .live(let live) = graph.resolve(ref) else { return .failure(liveFailure(ref)) }
        let record = Self.readRecord(live, host: graph.host)
        if case .script? = record.entries[name] { return .failure(.nameIsScript) }
        guard case .value(let oldValue, let readonly, _)? = record.entries[name] else {
            return .success(RemovePlan(
                live: live, candidate: nil, oldValue: nil, existed: false, forced: false
            ))
        }
        if readonly, !force { return .failure(.readonly) }
        guard let newRevision = bumpedRevision(record.revision) else { return .failure(.revisionOverflow) }
        var candidate = record
        candidate.entries.removeValue(forKey: name)
        candidate.revision = newRevision
        return .success(RemovePlan(
            live: live, candidate: candidate, oldValue: oldValue, existed: true,
            forced: readonly && force
        ))
    }

    // MARK: - validation / caps

    private func validateNameAndValue(name: String, value: AttrValue, kind: ObjectKind) -> AttributeError? {
        guard isValidAttributeName(name) else { return .invalidName(hint: normalizedAttributeNameHint(name)) }
        if nameIsBuiltIn(kind: kind, name: name) { return .nameIsBuiltIn }
        if let err = AttrValueCodec.validate(value, caps: caps) { return .invalidValue(err) }
        return nil
    }

    /// A custom name may not shadow a registry built-in or alias of that kind
    /// (spec "Built-in names are protected").
    private func nameIsBuiltIn(kind: ObjectKind, name: String) -> Bool {
        AttributeRegistry.resolve(kind: kind, name: name) != nil
    }

    private func bumpedRevision(_ rev: UInt64) -> UInt64? {
        let (bumped, overflow) = rev.addingReportingOverflow(1)
        return overflow ? nil : bumped
    }

    private func checkCaps(_ candidate: ObjectRecord, live: LiveObject, ref: ObjectRef) -> AttributeError? {
        guard candidate.storageEntryCount <= caps.maxEntriesPerObject else {
            return .tooManyEntries(limit: caps.maxEntriesPerObject)
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

    private func liveFailure(_ ref: ObjectRef) -> AttributeError {
        switch graph.resolve(ref) {
        case .dormant: return .dormant
        case .unsupported: return .unsupported
        default: return .objectNotLive
        }
    }

    private static func extractValue(_ entry: AttributeEntry?) -> AttrValue? {
        guard case .value(let v, _, _)? = entry else { return nil }
        return v
    }

    // MARK: - record storage location per `LiveObject` case

    static func readRecord(_ live: LiveObject, host: ObjectGraphHost) -> ObjectRecord {
        switch live {
        case .world:
            return host.worldObjectRecord(for: .world)
        case .dimension(let world):
            return host.worldObjectRecord(for: .dimension(world.dim))
        case .block(_, let chunk, let cellIndex, _, _, _):
            return chunk.objectRecords[cellIndex] ?? ObjectRecord()
        case .entity(let entity, _):
            return entity.objectRecord
        case .player(let player, _):
            return player.objectRecord
        }
    }

    static func writeRecord(_ record: ObjectRecord, to live: LiveObject, host: ObjectGraphHost) {
        switch live {
        case .world:
            host.setWorldObjectRecord(record, for: .world)
        case .dimension(let world):
            host.setWorldObjectRecord(record, for: .dimension(world.dim))
        case .block(_, let chunk, let cellIndex, _, _, _):
            if record.isEmpty {
                chunk.objectRecords.removeValue(forKey: cellIndex)
            } else {
                chunk.objectRecords[cellIndex] = record
            }
            chunk.modified = true
        case .entity(let entity, _):
            entity.objectRecord = record
        case .player(let player, _):
            player.objectRecord = record
        }
    }
}
