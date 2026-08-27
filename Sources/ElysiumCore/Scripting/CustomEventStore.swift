// CustomEventStore.swift — the sole mutation boundary for persistent,
// object-scoped custom-event declarations. It mirrors AttributeStore's host
// authority, liveness, revision, and aggregate persistence-cap discipline.

import Foundation

public enum CustomEventStoreError: Error, Equatable {
    case objectNotLive
    case dormant
    case unsupported
    case lanClient
    case invalidEventName
    case builtInEventName
    case tooManyDeclarations(limit: Int)
    case tooManyFields(limit: Int)
    case invalidFieldName(String)
    case reservedFieldName(String)
    case duplicateFieldName(String)
    case summaryTooLarge(limit: Int)
    case invalidSummary
    case tooManyEntries(limit: Int)
    case recordTooLarge(limit: Int)
    case chunkTooLarge(limit: Int)
    case documentTooLarge(limit: Int)
    case revisionOverflow
}

public struct CustomEventStore {
    public let graph: ObjectGraph
    public let caps: ScriptingStorageCaps

    public init(graph: ObjectGraph, caps: ScriptingStorageCaps = .defaults) {
        self.graph = graph
        self.caps = caps
    }

    public func get(_ ref: ObjectRef, _ name: String) -> CustomEventDeclaration? {
        guard case .live(let live) = graph.resolve(ref) else { return nil }
        return AttributeStore.readRecord(live, host: graph.host).eventDeclarations[name]
    }

    public func list(_ ref: ObjectRef) -> [CustomEventDeclaration] {
        guard case .live(let live) = graph.resolve(ref) else { return [] }
        let record = AttributeStore.readRecord(live, host: graph.host)
        return record.eventDeclarations.keys.sorted(by: utf8Less).compactMap { record.eventDeclarations[$0] }
    }

    /// Creates or replaces one declaration. An identical contract is a true
    /// idempotent no-op: it preserves provenance/revision and does not dirty a
    /// chunk merely because a module re-declared its API at load.
    public func declare(
        _ ref: ObjectRef, name: String, fields: [CustomEventField], summary: String? = nil,
        by author: Provenance.Author = .player
    ) -> Result<CustomEventDeclaration, CustomEventStoreError> {
        if graph.host.isLANClient { return .failure(.lanClient) }
        guard case .live(let live) = graph.resolve(ref) else { return .failure(liveFailure(ref)) }
        let validated: (kind: EventKind, fields: [CustomEventField])
        switch validateCustomEventDeclaration(name: name, fields: fields, summary: summary, caps: caps) {
        case .success(let value): validated = value
        case .failure(let error): return .failure(storeError(for: error))
        }

        var record = AttributeStore.readRecord(live, host: graph.host)
        if let existing = record.eventDeclarations[name],
           existing.kind == validated.kind,
           existing.hasSameContract(fields: validated.fields, summary: summary) {
            return .success(existing)
        }
        let isNew = record.eventDeclarations[name] == nil
        if isNew, record.eventDeclarations.count >= caps.maxEventDeclarationsPerObject {
            return .failure(.tooManyDeclarations(limit: caps.maxEventDeclarationsPerObject))
        }
        guard let newRevision = bumpedRevision(record.revision) else { return .failure(.revisionOverflow) }
        let declaration = CustomEventDeclaration(
            kind: validated.kind, fields: validated.fields, summary: summary,
            provenance: Provenance(createdBy: author, createdTick: graph.host.currentTick)
        )
        var candidate = record
        candidate.eventDeclarations[name] = declaration
        candidate.revision = newRevision
        if let error = checkCaps(candidate, live: live, ref: ref) { return .failure(error) }
        record = candidate
        AttributeStore.writeRecord(record, to: live, host: graph.host)
        return .success(declaration)
    }

    public func undeclare(_ ref: ObjectRef, _ name: String) -> Result<Bool, CustomEventStoreError> {
        if graph.host.isLANClient { return .failure(.lanClient) }
        guard case .live(let live) = graph.resolve(ref) else { return .failure(liveFailure(ref)) }
        var record = AttributeStore.readRecord(live, host: graph.host)
        guard record.eventDeclarations[name] != nil else { return .success(false) }
        guard let newRevision = bumpedRevision(record.revision) else { return .failure(.revisionOverflow) }
        record.eventDeclarations.removeValue(forKey: name)
        record.revision = newRevision
        AttributeStore.writeRecord(record, to: live, host: graph.host)
        return .success(true)
    }

    private func bumpedRevision(_ revision: UInt64) -> UInt64? {
        let (value, overflow) = revision.addingReportingOverflow(1)
        return overflow ? nil : value
    }

    private func checkCaps(
        _ candidate: ObjectRecord, live: LiveObject, ref: ObjectRef
    ) -> CustomEventStoreError? {
        guard candidate.storageEntryCount <= caps.maxEntriesPerObject else {
            return .tooManyEntries(limit: caps.maxEntriesPerObject)
        }
        guard candidate.eventDeclarations.count <= caps.maxEventDeclarationsPerObject else {
            return .tooManyDeclarations(limit: caps.maxEventDeclarationsPerObject)
        }
        let text = ObjectRecordCodec.encode(candidate)
        let isWorldOrDim = ref.kind == .world || ref.kind == .dim
        let recordLimit = isWorldOrDim ? caps.maxWorldDimRecordTextBytes : caps.maxRecordTextBytes
        guard text.utf8.count <= recordLimit else { return .recordTooLarge(limit: recordLimit) }
        if case .block(_, let chunk, let cellIndex, _, _, _) = live {
            var total = text.utf8.count
            for (index, record) in chunk.objectRecords where index != cellIndex {
                total += ObjectRecordCodec.encode(record).utf8.count
            }
            guard total <= caps.maxChunkObjectBytes else {
                return .chunkTooLarge(limit: caps.maxChunkObjectBytes)
            }
        }
        if isWorldOrDim {
            var total = text.utf8.count
            let siblings: [ObjectRef] = [.world, .dimension(.overworld), .dimension(.nether), .dimension(.end)]
            for sibling in siblings where sibling != ref {
                total += ObjectRecordCodec.encode(graph.host.worldObjectRecord(for: sibling)).utf8.count
            }
            guard total <= caps.maxWorldDocumentBytes else {
                return .documentTooLarge(limit: caps.maxWorldDocumentBytes)
            }
        }
        return nil
    }

    private func liveFailure(_ ref: ObjectRef) -> CustomEventStoreError {
        switch graph.resolve(ref) {
        case .dormant: return .dormant
        case .unsupported: return .unsupported
        default: return .objectNotLive
        }
    }

    private func storeError(for error: CustomEventDeclarationValidationError) -> CustomEventStoreError {
        switch error {
        case .invalidEventName: return .invalidEventName
        case .builtInEventName: return .builtInEventName
        case .tooManyFields(let limit): return .tooManyFields(limit: limit)
        case .invalidFieldName(let name): return .invalidFieldName(name)
        case .reservedFieldName(let name): return .reservedFieldName(name)
        case .duplicateFieldName(let name): return .duplicateFieldName(name)
        case .summaryTooLarge(let limit): return .summaryTooLarge(limit: limit)
        case .invalidSummary: return .invalidSummary
        }
    }
}
