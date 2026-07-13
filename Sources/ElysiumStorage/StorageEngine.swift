import Foundation
import Dispatch
import SQLite3
import Darwin
import CryptoKit

// This target is deliberately a single physical persistence boundary. ElysiumCore can
// exchange only the primitive row values and named façades declared in this file;
// SQLite handles, SQL, capabilities, contexts, and statements remain private here.

public enum ElysiumStorageOperationID: String, Sendable {
    case open, configure, prepare, bind, step, changes, finalize
    case beginImmediate, commit, rollback, authorizer, close
    case checkpoint, durabilitySync
}

public enum ElysiumStorageError: Error, Sendable, Equatable {
    case openFailed(primaryCode: Int32, extendedCode: Int32)
    case duplicateOpen
    case sqlite(primaryCode: Int32, extendedCode: Int32, operation: ElysiumStorageOperationID)
    case nestedTransaction
    case capabilityViolation
    case inactiveContext
    case wrongExecutorOrQueue
    case statementLeak
    case transactionStillOpen
    case poisoned
    case closed
    case invalidValue
    case limitExceeded
    case invalidStorageClass
    case invalidUTF8
    case schemaMismatch
    case schemaIntegrity
}

private func storageSQLiteCodes(_ extendedCode: Int32) -> (primary: Int32, extended: Int32) {
    (extendedCode & 0xFF, extendedCode)
}

private func storageSQLiteError(_ extendedCode: Int32,
                                operation: ElysiumStorageOperationID) -> ElysiumStorageError {
    let codes = storageSQLiteCodes(extendedCode)
    return .sqlite(primaryCode: codes.primary, extendedCode: codes.extended,
                   operation: operation)
}

private func storageSQLiteOpenFailure(_ extendedCode: Int32) -> ElysiumStorageError {
    let codes = storageSQLiteCodes(extendedCode)
    return .openFailed(primaryCode: codes.primary, extendedCode: codes.extended)
}

private func storageFixedTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    lhs.withUnsafeBytes { left in
        rhs.withUnsafeBytes { right in
            for index in 0..<lhs.count {
                difference |= left[index] ^ right[index]
            }
        }
    }
    return difference == 0
}

private func storageSHA256(_ input: Data) -> Data {
    let constants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
        0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
        0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
        0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
        0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    var bytes = Array(input)
    let bitCount = UInt64(bytes.count) &* 8
    bytes.append(0x80)
    while bytes.count % 64 != 56 { bytes.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
        bytes.append(UInt8(truncatingIfNeeded: bitCount >> UInt64(shift)))
    }
    var hash: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    for offset in stride(from: 0, to: bytes.count, by: 64) {
        var words = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let base = offset + index * 4
            words[index] = UInt32(bytes[base]) << 24 | UInt32(bytes[base + 1]) << 16
                | UInt32(bytes[base + 2]) << 8 | UInt32(bytes[base + 3])
        }
        for index in 16..<64 {
            let x = words[index - 15]
            let y = words[index - 2]
            let s0 = x.rotateRight(7) ^ x.rotateRight(18) ^ (x >> 3)
            let s1 = y.rotateRight(17) ^ y.rotateRight(19) ^ (y >> 10)
            words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
        }
        var a = hash[0], b = hash[1], c = hash[2], d = hash[3]
        var e = hash[4], f = hash[5], g = hash[6], h = hash[7]
        for index in 0..<64 {
            let upper = e.rotateRight(6) ^ e.rotateRight(11) ^ e.rotateRight(25)
            let choice = (e & f) ^ (~e & g)
            let t1 = h &+ upper &+ choice &+ constants[index] &+ words[index]
            let lower = a.rotateRight(2) ^ a.rotateRight(13) ^ a.rotateRight(22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let t2 = lower &+ majority
            h = g; g = f; f = e; e = d &+ t1
            d = c; c = b; b = a; a = t1 &+ t2
        }
        hash[0] &+= a; hash[1] &+= b; hash[2] &+= c; hash[3] &+= d
        hash[4] &+= e; hash[5] &+= f; hash[6] &+= g; hash[7] &+= h
    }
    var result = Data()
    result.reserveCapacity(32)
    for word in hash {
        result.append(UInt8(truncatingIfNeeded: word >> 24))
        result.append(UInt8(truncatingIfNeeded: word >> 16))
        result.append(UInt8(truncatingIfNeeded: word >> 8))
        result.append(UInt8(truncatingIfNeeded: word))
    }
    return result
}

private struct StorageFramedSHA256 {
    private var value = SHA256()

    init(domain: StaticString) {
        var bytes = Data()
        domain.withUTF8Buffer { bytes.append(contentsOf: $0) }
        appendFrame(bytes)
    }

    mutating func appendUInt64(_ number: UInt64) {
        var value = number.bigEndian
        withUnsafeBytes(of: &value) { self.value.update(data: Data($0)) }
    }

    mutating func appendFrame(_ bytes: Data) {
        appendUInt64(UInt64(bytes.count))
        value.update(data: bytes)
    }

    mutating func appendText(_ text: String) { appendFrame(Data(text.utf8)) }

    mutating func finish() -> Data { Data(value.finalize()) }
}

private func storageRawUTF8Less(_ lhs: String, _ rhs: String) -> Bool {
    Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
}

private func storageWorldRowDigest(id: String, json: String, lastPlayed: Double) -> Data {
    var digest = StorageFramedSHA256(domain: "Pebble.WorldBrowser.Row.v1")
    digest.appendText(id)
    digest.appendText(json)
    digest.appendUInt64(lastPlayed.bitPattern)
    return digest.finish()
}

private func storageWorldCollectionDigest(_ rows: [ElysiumCheckedWorldStorageRow]) -> Data {
    var digest = StorageFramedSHA256(domain: "Pebble.WorldBrowser.Collection.v1")
    digest.appendUInt64(UInt64(rows.count))
    for row in rows {
        digest.appendText(row.storedID)
        digest.appendFrame(row.rowDigest)
    }
    return digest.finish()
}

private func storageWorldBatchRequestDigest(
    collectionDigest: Data, expectations: [ElysiumWorldBatchDeleteExpectation]
) -> Data {
    var digest = StorageFramedSHA256(domain: "Pebble.WorldBrowser.DeleteRequest.v1")
    digest.appendFrame(collectionDigest)
    digest.appendUInt64(UInt64(expectations.count))
    for value in expectations {
        digest.appendText(value.storedID)
        digest.appendFrame(value.rowDigest)
    }
    return digest.finish()
}

private func storageWorldBatchReceiptDigest(
    requestDigest: Data, preAuthorityDigest: Data, postAuthorityDigest: Data,
    unrelatedIdentityDigest: Data, deletedCount: Int
) -> Data {
    var digest = StorageFramedSHA256(domain: "Pebble.WorldBrowser.DeleteReceipt.v1")
    digest.appendFrame(requestDigest)
    digest.appendFrame(preAuthorityDigest)
    digest.appendFrame(postAuthorityDigest)
    digest.appendFrame(unrelatedIdentityDigest)
    digest.appendUInt64(UInt64(deletedCount))
    return digest.finish()
}

private enum StorageWorldBatchAuthorityPhase {
    case pre, post
    var domain: StaticString {
        switch self {
        case .pre: return "Pebble.WorldBrowser.DeleteAuthority.Pre.v1"
        case .post: return "Pebble.WorldBrowser.DeleteAuthority.Post.v1"
        }
    }
}

private func storageWorldBatchAuthorityDigest(
    phase: StorageWorldBatchAuthorityPhase, worldCollectionDigest: Data,
    selectedScopeCounts: [[Int64]], unrelatedIdentityDigest: Data,
    totalScopeCounts: [Int64]
) -> Data {
    var digest = StorageFramedSHA256(domain: phase.domain)
    digest.appendFrame(worldCollectionDigest)
    digest.appendUInt64(UInt64(selectedScopeCounts.count))
    for counts in selectedScopeCounts {
        for value in counts { digest.appendUInt64(UInt64(value)) }
    }
    digest.appendFrame(unrelatedIdentityDigest)
    for value in totalScopeCounts { digest.appendUInt64(UInt64(value)) }
    return digest.finish()
}

private let storageWorldBatchDeleteStatements: [StaticString] = [
    "DELETE FROM rpg_local_preference_migrations_v1 WHERE world_record_id=?",
    "DELETE FROM rpg_local_preferences_v1 WHERE world_record_id=?",
    "DELETE FROM worlds WHERE id=?",
    "DELETE FROM chunks WHERE world=?",
    "DELETE FROM player WHERE world=?",
    "DELETE FROM advancements WHERE world=?",
]

private extension UInt32 {
    func rotateRight(_ count: UInt32) -> UInt32 {
        (self >> count) | (self << (32 - count))
    }
}

extension ElysiumStorageError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .openFailed(primary, extended):
            return "ElysiumStorage open failed (\(primary)/\(extended))"
        case .duplicateOpen: return "ElysiumStorage duplicate open"
        case let .sqlite(primary, extended, operation):
            return "ElysiumStorage \(operation.rawValue) failed (\(primary)/\(extended))"
        case .nestedTransaction: return "ElysiumStorage nested transaction"
        case .capabilityViolation: return "ElysiumStorage capability violation"
        case .inactiveContext: return "ElysiumStorage inactive context"
        case .wrongExecutorOrQueue: return "ElysiumStorage wrong executor or queue"
        case .statementLeak: return "ElysiumStorage statement leak"
        case .transactionStillOpen: return "ElysiumStorage transaction still open"
        case .poisoned: return "ElysiumStorage poisoned"
        case .closed: return "ElysiumStorage closed"
        case .invalidValue: return "ElysiumStorage invalid value"
        case .limitExceeded: return "ElysiumStorage limit exceeded"
        case .invalidStorageClass: return "ElysiumStorage invalid storage class"
        case .invalidUTF8: return "ElysiumStorage invalid UTF-8"
        case .schemaMismatch: return "ElysiumStorage schema mismatch"
        case .schemaIntegrity: return "ElysiumStorage schema integrity failure"
        }
    }
}

public struct ElysiumStorageTransactionFailure: Error {
    public let primary: any Error
    public let rollback: ElysiumStorageError?
    public let terminal: ElysiumStorageError?

    public init(primary: any Error, rollback: ElysiumStorageError?, terminal: ElysiumStorageError?) {
        self.primary = primary
        self.rollback = rollback
        self.terminal = terminal
    }
}

public struct ElysiumStorageStatementFailure: Error {
    public let primary: any Error
    public let finalize: ElysiumStorageError

    public init(primary: any Error, finalize: ElysiumStorageError) {
        self.primary = primary
        self.finalize = finalize
    }
}

public struct ElysiumRPGLocalPreferenceStorageRow: Sendable, Equatable {
    public let worldRecordID: String
    public let schemaVersion: UInt16
    public let revision: UInt64
    public let slotsPayload: Data
    public let payloadDigest: Data
    public let migrationOriginDigest: Data?
    public let migrationOriginRevision: UInt64?

    public init(worldRecordID: String, schemaVersion: UInt16, revision: UInt64,
                slotsPayload: Data, payloadDigest: Data,
                migrationOriginDigest: Data?, migrationOriginRevision: UInt64?) throws {
        try StorageBounds.validateRPGWorldRecordID(worldRecordID)
        guard schemaVersion == 1, (1...1_000_000_000).contains(revision),
              (18...4_096).contains(slotsPayload.count), payloadDigest.count == 32,
              (migrationOriginDigest == nil) == (migrationOriginRevision == nil) else {
            throw ElysiumStorageError.invalidValue
        }
        if let migrationOriginDigest, let migrationOriginRevision {
            guard migrationOriginDigest.count == 32,
                  (1...1_000_000_000).contains(migrationOriginRevision) else {
                throw ElysiumStorageError.invalidValue
            }
        }
        let originBytes = migrationOriginDigest == nil ? 0 : 40
        let accounted = 256 + worldRecordID.utf8.count + 2 + 8 + slotsPayload.count
            + 32 + 1 + originBytes
        guard accounted <= 4_096 else { throw ElysiumStorageError.limitExceeded }
        self.worldRecordID = worldRecordID
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.slotsPayload = slotsPayload
        self.payloadDigest = payloadDigest
        self.migrationOriginDigest = migrationOriginDigest
        self.migrationOriginRevision = migrationOriginRevision
    }
}

public struct ElysiumRPGLegacyQuickSlotMigrationStorageRow: Sendable, Equatable {
    public let worldRecordID: String
    public let schemaVersion: UInt16
    public let sourceDigest: Data
    public let destinationDigest: Data
    public let destinationRevision: UInt64

    public init(worldRecordID: String, schemaVersion: UInt16, sourceDigest: Data,
                destinationDigest: Data, destinationRevision: UInt64) throws {
        try StorageBounds.validateRPGWorldRecordID(worldRecordID)
        guard schemaVersion == 1, sourceDigest.count == 32, destinationDigest.count == 32,
              (1...1_000_000_000).contains(destinationRevision) else {
            throw ElysiumStorageError.invalidValue
        }
        let accounted = 256 + worldRecordID.utf8.count + 2 + 32 + 32 + 8
        guard accounted <= 4_096 else { throw ElysiumStorageError.limitExceeded }
        self.worldRecordID = worldRecordID
        self.schemaVersion = schemaVersion
        self.sourceDigest = sourceDigest
        self.destinationDigest = destinationDigest
        self.destinationRevision = destinationRevision
    }
}

public struct ElysiumRPGLocalPreferenceMigrationReceipt: Sendable, Equatable {
    public let preference: ElysiumRPGLocalPreferenceStorageRow
    public let marker: ElysiumRPGLegacyQuickSlotMigrationStorageRow
    public let insertedDestination: Bool

    public init(preference: ElysiumRPGLocalPreferenceStorageRow,
                marker: ElysiumRPGLegacyQuickSlotMigrationStorageRow,
                insertedDestination: Bool) {
        self.preference = preference
        self.marker = marker
        self.insertedDestination = insertedDestination
    }
}

public struct ElysiumLANClientAuthorityStorageKey: Sendable, Equatable, Hashable {
    public let hostInstallationID: Data
    public let worldLANID: Data
    public let lookupDigest: Data

    public init(hostInstallationID: Data, worldLANID: Data, lookupDigest: Data) throws {
        guard hostInstallationID.count == 16, worldLANID.count == 16,
              lookupDigest.count == 32 else { throw ElysiumStorageError.invalidValue }
        var input = Data("Pebble-LAN-v6".utf8)
        input.append(hostInstallationID)
        input.append(worldLANID)
        guard storageFixedTimeEqual(storageSHA256(input), lookupDigest) else {
            throw ElysiumStorageError.invalidValue
        }
        self.hostInstallationID = hostInstallationID
        self.worldLANID = worldLANID
        self.lookupDigest = lookupDigest
    }
}

public struct ElysiumLANClientCredentialStorageRow: Sendable {
    public let key: ElysiumLANClientAuthorityStorageKey
    public let schemaVersion: UInt16
    public let aggregateGeneration: UInt64
    public let aggregateDigest: Data
    public let authorityBound: Bool
    public let payload: Data
    public let payloadDigest: Data

    public init(key: ElysiumLANClientAuthorityStorageKey, schemaVersion: UInt16,
                aggregateGeneration: UInt64, aggregateDigest: Data,
                authorityBound: Bool, payload: Data, payloadDigest: Data) throws {
        guard schemaVersion == 1, aggregateGeneration <= 1_000_000_000,
              aggregateDigest.count == 32, (1...65_536).contains(payload.count),
              payloadDigest.count == 32,
              (authorityBound ? aggregateGeneration >= 1 : aggregateGeneration == 0) else {
            throw ElysiumStorageError.invalidValue
        }
        self.key = key
        self.schemaVersion = schemaVersion
        self.aggregateGeneration = aggregateGeneration
        self.aggregateDigest = aggregateDigest
        self.authorityBound = authorityBound
        self.payload = payload
        self.payloadDigest = payloadDigest
    }
}

public struct ElysiumLANClientOwnerCheckpointStorageRow: Sendable {
    public let key: ElysiumLANClientAuthorityStorageKey
    public let schemaVersion: UInt16
    public let lastChangeGeneration: UInt64
    public let payload: Data
    public let payloadDigest: Data

    public init(key: ElysiumLANClientAuthorityStorageKey, schemaVersion: UInt16,
                lastChangeGeneration: UInt64, payload: Data, payloadDigest: Data) throws {
        guard schemaVersion == 1, (1...1_000_000_000).contains(lastChangeGeneration),
              (1...786_432).contains(payload.count), payloadDigest.count == 32 else {
            throw ElysiumStorageError.invalidValue
        }
        self.key = key
        self.schemaVersion = schemaVersion
        self.lastChangeGeneration = lastChangeGeneration
        self.payload = payload
        self.payloadDigest = payloadDigest
    }
}

public enum ElysiumLANClientPendingMode: UInt8, Sendable, Equatable {
    case awaitingState = 1
    case dispositionOnly = 2
}

public struct ElysiumLANClientPendingDispositionStorageRow: Sendable {
    public let key: ElysiumLANClientAuthorityStorageKey
    public let schemaVersion: UInt16
    public let lastChangeGeneration: UInt64
    public let mode: ElysiumLANClientPendingMode
    public let payload: Data
    public let payloadDigest: Data

    public init(key: ElysiumLANClientAuthorityStorageKey, schemaVersion: UInt16,
                lastChangeGeneration: UInt64, mode: ElysiumLANClientPendingMode,
                payload: Data, payloadDigest: Data) throws {
        guard schemaVersion == 1, (1...1_000_000_000).contains(lastChangeGeneration),
              (1...131_072).contains(payload.count), payloadDigest.count == 32 else {
            throw ElysiumStorageError.invalidValue
        }
        self.key = key
        self.schemaVersion = schemaVersion
        self.lastChangeGeneration = lastChangeGeneration
        self.mode = mode
        self.payload = payload
        self.payloadDigest = payloadDigest
    }
}

public enum ElysiumLANClientNoticeStatus: UInt8, Sendable, Equatable {
    case accepted = 1
    case rejected = 2
    case outcomeEvicted = 3
    case requestExhausted = 4
}

public enum ElysiumLANClientNoticeAcknowledgement: UInt8, Sendable, Equatable {
    case pendingRender = 0
    case acknowledged = 1
}

public struct ElysiumLANClientNotificationStorageRow: Sendable {
    public let key: ElysiumLANClientAuthorityStorageKey
    public let notificationID: Data
    public let sessionEpoch: Data
    public let requestID: UInt64
    public let snapshotID: Data
    public let status: ElysiumLANClientNoticeStatus
    public let creationGeneration: UInt64
    public let acknowledgement: ElysiumLANClientNoticeAcknowledgement
    public let acknowledgementGeneration: UInt64
    public let payload: Data
    public let payloadDigest: Data

    public init(key: ElysiumLANClientAuthorityStorageKey, notificationID: Data,
                sessionEpoch: Data, requestID: UInt64, snapshotID: Data,
                status: ElysiumLANClientNoticeStatus, creationGeneration: UInt64,
                acknowledgement: ElysiumLANClientNoticeAcknowledgement,
                acknowledgementGeneration: UInt64, payload: Data,
                payloadDigest: Data) throws {
        guard notificationID.count == 32, sessionEpoch.count == 16, snapshotID.count == 16,
              (1...1_000_000_000).contains(requestID),
              (1...1_000_000_000).contains(creationGeneration),
              acknowledgementGeneration == UInt64(acknowledgement.rawValue),
              (1...4_096).contains(payload.count), payloadDigest.count == 32 else {
            throw ElysiumStorageError.invalidValue
        }
        let accounted = 512 + 16 + 16 + 32 + 32 + 16 + 8 + 16 + 8 + 8 + 8
            + payload.count + 32
        guard accounted <= 4_608 else { throw ElysiumStorageError.limitExceeded }
        self.key = key
        self.notificationID = notificationID
        self.sessionEpoch = sessionEpoch
        self.requestID = requestID
        self.snapshotID = snapshotID
        self.status = status
        self.creationGeneration = creationGeneration
        self.acknowledgement = acknowledgement
        self.acknowledgementGeneration = acknowledgementGeneration
        self.payload = payload
        self.payloadDigest = payloadDigest
    }
}

public enum ElysiumLANClientOwnerRowChange: Sendable {
    case unchanged
    case set(ElysiumLANClientOwnerCheckpointStorageRow)
    case remove(expectedDigest: Data)
}

public enum ElysiumLANClientPendingRowChange: Sendable {
    case unchanged
    case set(ElysiumLANClientPendingDispositionStorageRow)
    case remove(expectedDigest: Data)
}

public struct ElysiumLANClientAuthorityCheckpointSnapshot: Sendable {
    public let credential: ElysiumLANClientCredentialStorageRow
    public let owner: ElysiumLANClientOwnerCheckpointStorageRow?
    public let pending: ElysiumLANClientPendingDispositionStorageRow?
    public let oldestPendingNotice: ElysiumLANClientNotificationStorageRow?

    public init(credential: ElysiumLANClientCredentialStorageRow,
                owner: ElysiumLANClientOwnerCheckpointStorageRow?,
                pending: ElysiumLANClientPendingDispositionStorageRow?,
                oldestPendingNotice: ElysiumLANClientNotificationStorageRow?) throws {
        guard owner?.key == nil || owner?.key == credential.key,
              pending?.key == nil || pending?.key == credential.key,
              oldestPendingNotice?.key == nil || oldestPendingNotice?.key == credential.key,
              owner.map({ $0.lastChangeGeneration <= credential.aggregateGeneration }) ?? true,
              pending.map({ $0.lastChangeGeneration <= credential.aggregateGeneration }) ?? true else {
            throw ElysiumStorageError.invalidValue
        }
        self.credential = credential
        self.owner = owner
        self.pending = pending
        self.oldestPendingNotice = oldestPendingNotice
    }
}

public enum ElysiumLANClientAuthorityTransitionKind: UInt8, Sendable, Equatable {
    case firstRequestZeroBind = 1
    case ordinary = 2
}

public struct ElysiumLANClientAuthorityCheckpointCandidate: Sendable {
    public let key: ElysiumLANClientAuthorityStorageKey
    public let transition: ElysiumLANClientAuthorityTransitionKind
    public let expectedAggregateGeneration: UInt64
    public let expectedAggregateDigest: Data
    public let credential: ElysiumLANClientCredentialStorageRow
    public let ownerChange: ElysiumLANClientOwnerRowChange
    public let pendingChange: ElysiumLANClientPendingRowChange
    public let noticeInsert: ElysiumLANClientNotificationStorageRow?

    public init(key: ElysiumLANClientAuthorityStorageKey,
                transition: ElysiumLANClientAuthorityTransitionKind,
                expectedAggregateGeneration: UInt64, expectedAggregateDigest: Data,
                credential: ElysiumLANClientCredentialStorageRow,
                ownerChange: ElysiumLANClientOwnerRowChange,
                pendingChange: ElysiumLANClientPendingRowChange,
                noticeInsert: ElysiumLANClientNotificationStorageRow?) throws {
        guard expectedAggregateGeneration <= 999_999_999, expectedAggregateDigest.count == 32,
              credential.key == key,
              credential.aggregateGeneration == expectedAggregateGeneration + 1,
              noticeInsert?.key == nil || noticeInsert?.key == key else {
            throw ElysiumStorageError.invalidValue
        }
        switch ownerChange {
        case .unchanged: break
        case let .set(row): guard row.key == key else { throw ElysiumStorageError.invalidValue }
        case let .remove(digest): guard digest.count == 32 else {
            throw ElysiumStorageError.invalidValue
        }
        }
        switch pendingChange {
        case .unchanged: break
        case let .set(row): guard row.key == key else { throw ElysiumStorageError.invalidValue }
        case let .remove(digest): guard digest.count == 32 else {
            throw ElysiumStorageError.invalidValue
        }
        }
        self.key = key
        self.transition = transition
        self.expectedAggregateGeneration = expectedAggregateGeneration
        self.expectedAggregateDigest = expectedAggregateDigest
        self.credential = credential
        self.ownerChange = ownerChange
        self.pendingChange = pendingChange
        self.noticeInsert = noticeInsert
    }
}

public struct ElysiumLANClientAuthorityCheckpointReceipt: Sendable {
    public let snapshot: ElysiumLANClientAuthorityCheckpointSnapshot
    public let committedAggregateGeneration: UInt64
    public let committedAggregateDigest: Data

    public init(snapshot: ElysiumLANClientAuthorityCheckpointSnapshot,
                committedAggregateGeneration: UInt64,
                committedAggregateDigest: Data) throws {
        guard committedAggregateGeneration == snapshot.credential.aggregateGeneration,
              committedAggregateDigest.count == 32,
              storageFixedTimeEqual(committedAggregateDigest,
                                    snapshot.credential.aggregateDigest) else {
            throw ElysiumStorageError.invalidValue
        }
        self.snapshot = snapshot
        self.committedAggregateGeneration = committedAggregateGeneration
        self.committedAggregateDigest = committedAggregateDigest
    }
}

extension ElysiumStorageStatementFailure: CustomStringConvertible {
    public var description: String { "ElysiumStorage statement and finalize failed" }
}

extension ElysiumStorageTransactionFailure: CustomStringConvertible {
    public var description: String {
        // The primary error object is preserved for programmatic inspection but is
        // intentionally never interpolated: caller errors may contain private data.
        "ElysiumStorage transaction failed (rollback=\(rollback != nil), terminal=\(terminal != nil))"
    }
}

// MARK: - Primitive storage rows

public struct ElysiumWorldStorageRow: Sendable, Equatable {
    public let id: String
    public let json: String
    public let lastPlayed: Double

    public init(id: String, json: String, lastPlayed: Double) throws {
        try StorageBounds.validateIdentifier(id, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateBoundedText(json, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateAggregateBytes([id.utf8.count, json.utf8.count],
                                                 maximumBytes: StorageBounds.manifestText * 2)
        guard lastPlayed.isFinite else { throw ElysiumStorageError.invalidValue }
        self.id = id
        self.json = json
        self.lastPlayed = lastPlayed
    }
}

public struct ElysiumCheckedWorldStorageRow: Sendable, Equatable {
    public let storedID: String
    public let json: String
    public let lastPlayed: Double
    public let rowDigest: Data

    fileprivate init(storedID: String, json: String, lastPlayed: Double,
                     rowDigest: Data) {
        self.storedID = storedID
        self.json = json
        self.lastPlayed = lastPlayed
        self.rowDigest = rowDigest
    }
}

public struct ElysiumCheckedWorldCollectionSnapshot: Sendable, Equatable {
    public let rows: [ElysiumCheckedWorldStorageRow]
    public let collectionDigest: Data
    public let aggregateRawBytes: Int

    fileprivate init(rows: [ElysiumCheckedWorldStorageRow], collectionDigest: Data,
                     aggregateRawBytes: Int) {
        self.rows = rows
        self.collectionDigest = collectionDigest
        self.aggregateRawBytes = aggregateRawBytes
    }
}

public struct ElysiumWorldBatchDeleteExpectation: Sendable, Equatable {
    public let storedID: String
    public let rowDigest: Data

    public init(storedID: String, rowDigest: Data) throws {
        try StorageBounds.validateIdentifier(storedID, maximumBytes: 256)
        guard rowDigest.count == 32 else { throw ElysiumStorageError.invalidValue }
        self.storedID = storedID
        self.rowDigest = rowDigest
    }
}

public struct ElysiumWorldBatchDeleteRequest: Sendable, Equatable {
    public let expectedCollectionDigest: Data
    public let expectations: [ElysiumWorldBatchDeleteExpectation]
    public let requestDigest: Data

    public init(expectedCollectionDigest: Data,
                expectations: [ElysiumWorldBatchDeleteExpectation]) throws {
        guard expectedCollectionDigest.count == 32,
              (1...StorageBounds.worldRows).contains(expectations.count) else {
            throw ElysiumStorageError.invalidValue
        }
        let ordered = expectations.sorted { storageRawUTF8Less($0.storedID, $1.storedID) }
        guard ordered == expectations,
              Set(ordered.map(\.storedID)).count == ordered.count else {
            throw ElysiumStorageError.invalidValue
        }
        var encodedBytes = 32 + 8
        for expectation in ordered {
            let (next, overflow) = encodedBytes.addingReportingOverflow(
                8 + expectation.storedID.utf8.count + 32)
            guard !overflow, next <= StorageBounds.worldBatchEnvelopeBytes else {
                throw ElysiumStorageError.limitExceeded
            }
            encodedBytes = next
        }
        self.expectedCollectionDigest = expectedCollectionDigest
        self.expectations = ordered
        requestDigest = storageWorldBatchRequestDigest(
            collectionDigest: expectedCollectionDigest, expectations: ordered)
    }
}

public struct ElysiumWorldBatchDeleteReceipt: Sendable, Equatable {
    public let requestDigest: Data
    public let preAuthorityDigest: Data
    public let postAuthorityDigest: Data
    public let unrelatedIdentityDigest: Data
    public let deletedWorldCount: Int
    public let receiptDigest: Data

    fileprivate init(request: ElysiumWorldBatchDeleteRequest,
                     preAuthorityDigest: Data, postAuthorityDigest: Data,
                     unrelatedIdentityDigest: Data,
                     preWorldCount: Int, postWorldCount: Int) throws {
        guard postWorldCount <= preWorldCount,
              preWorldCount - postWorldCount == request.expectations.count,
              preAuthorityDigest.count == 32, postAuthorityDigest.count == 32,
              unrelatedIdentityDigest.count == 32 else {
            throw ElysiumStorageError.schemaIntegrity
        }
        requestDigest = request.requestDigest
        self.preAuthorityDigest = preAuthorityDigest
        self.postAuthorityDigest = postAuthorityDigest
        self.unrelatedIdentityDigest = unrelatedIdentityDigest
        deletedWorldCount = request.expectations.count
        receiptDigest = storageWorldBatchReceiptDigest(
            requestDigest: request.requestDigest,
            preAuthorityDigest: preAuthorityDigest,
            postAuthorityDigest: postAuthorityDigest,
            unrelatedIdentityDigest: unrelatedIdentityDigest,
            deletedCount: deletedWorldCount)
        guard 32 * 5 + 8 <= StorageBounds.worldBatchEnvelopeBytes else {
            throw ElysiumStorageError.limitExceeded
        }
    }
}

public struct ElysiumWorldBatchDeleteRecoveryAuthority: Sendable, Equatable {
    public let request: ElysiumWorldBatchDeleteRequest
    public let receipt: ElysiumWorldBatchDeleteReceipt
    public let preWorlds: ElysiumCheckedWorldCollectionSnapshot
    public let postWorlds: ElysiumCheckedWorldCollectionSnapshot
    public let preSelectedScopeCounts: [[Int64]]
    public let postSelectedScopeCounts: [[Int64]]
    public let unrelatedIdentityDigest: Data
    public let preTotalScopeCounts: [Int64]
    public let postTotalScopeCounts: [Int64]

    fileprivate init(request: ElysiumWorldBatchDeleteRequest,
                     receipt: ElysiumWorldBatchDeleteReceipt,
                     preWorlds: ElysiumCheckedWorldCollectionSnapshot,
                     postWorlds: ElysiumCheckedWorldCollectionSnapshot,
                     preSelectedScopeCounts: [[Int64]],
                     postSelectedScopeCounts: [[Int64]],
                     unrelatedIdentityDigest: Data,
                     preTotalScopeCounts: [Int64],
                     postTotalScopeCounts: [Int64]) {
        self.request = request; self.receipt = receipt
        self.preWorlds = preWorlds; self.postWorlds = postWorlds
        self.preSelectedScopeCounts = preSelectedScopeCounts
        self.postSelectedScopeCounts = postSelectedScopeCounts
        self.unrelatedIdentityDigest = unrelatedIdentityDigest
        self.preTotalScopeCounts = preTotalScopeCounts
        self.postTotalScopeCounts = postTotalScopeCounts
    }
}

public enum ElysiumWorldBatchDeleteOutcome: Sendable, Equatable {
    case direct(ElysiumWorldBatchDeleteReceipt)
    case recovered(ElysiumWorldBatchDeleteReceipt)
    case provenPrecommitFailure
    case stale
    case terminalRecovery(ElysiumWorldBatchDeleteRecoveryAuthority)
    case terminalIntegrity
}

public struct ElysiumChunkStorageKey: Sendable, Equatable, Hashable {
    public let world: String
    public let dimension: Int32
    public let chunkX: Int32
    public let chunkZ: Int32

    public init(world: String, dimension: Int32, chunkX: Int32, chunkZ: Int32) throws {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        self.world = world
        self.dimension = dimension
        self.chunkX = chunkX
        self.chunkZ = chunkZ
    }
}

public struct ElysiumChunkStorageRow: Sendable, Equatable {
    public let key: ElysiumChunkStorageKey
    public let data: Data

    public init(key: ElysiumChunkStorageKey, data: Data) throws {
        guard data.count <= StorageBounds.chunkBlob else { throw ElysiumStorageError.limitExceeded }
        try StorageBounds.validateAggregateBytes([key.world.utf8.count, data.count],
                                                 maximumBytes: StorageBounds.chunkVariableBytes)
        self.key = key
        self.data = data
    }
}

public struct ElysiumPlayerJSONStorageRow: Sendable, Equatable {
    public let world: String
    public let json: String

    public init(world: String, json: String) throws {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateBoundedText(json, maximumBytes: StorageBounds.playerJSON)
        try StorageBounds.validateAggregateBytes([world.utf8.count, json.utf8.count],
                                                 maximumBytes: StorageBounds.manifestText
                                                    + StorageBounds.playerJSON)
        self.world = world
        self.json = json
    }
}

public struct ElysiumPlayerJSONRowDigest: Sendable, Equatable {
    public let data: Data

    public init(data: Data) throws {
        guard data.count == 32 else { throw ElysiumStorageError.invalidValue }
        self.data = data
    }
}

public enum ElysiumPlayerJSONExpectedRowState: Sendable, Equatable {
    case absent
    case present(ElysiumPlayerJSONRowDigest)
}

public enum ElysiumPlayerJSONCompareAndSwapResult: Sendable, Equatable {
    case conflict
    case committed(ElysiumPlayerJSONStorageRow)
}

public struct ElysiumLANClientResumeStorageRow: Sendable, Equatable {
    public let hostWorld: String
    public let json: String
    public let updated: Double

    public init(hostWorld: String, json: String, updated: Double) throws {
        try StorageBounds.validateIdentifier(hostWorld, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateBoundedText(json, maximumBytes: StorageBounds.playerJSON)
        try StorageBounds.validateAggregateBytes([hostWorld.utf8.count, json.utf8.count],
                                                 maximumBytes: StorageBounds.manifestText
                                                    + StorageBounds.playerJSON)
        guard updated.isFinite else { throw ElysiumStorageError.invalidValue }
        self.hostWorld = hostWorld
        self.json = json
        self.updated = updated
    }
}

public struct ElysiumLANPlayerStorageRow: Sendable, Equatable {
    public let world: String
    public let playerID: String
    public let json: String
    public let updated: Double

    public init(world: String, playerID: String, json: String, updated: Double) throws {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateIdentifier(playerID, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateBoundedText(json, maximumBytes: StorageBounds.playerJSON)
        try StorageBounds.validateAggregateBytes(
            [world.utf8.count, playerID.utf8.count, json.utf8.count],
            maximumBytes: StorageBounds.manifestText * 2 + StorageBounds.playerJSON)
        guard updated.isFinite else { throw ElysiumStorageError.invalidValue }
        self.world = world
        self.playerID = playerID
        self.json = json
        self.updated = updated
    }
}

public struct ElysiumAdvancementStorageRow: Sendable, Equatable {
    public let world: String
    public let json: String

    public init(world: String, json: String) throws {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateBoundedText(json, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateAggregateBytes([world.utf8.count, json.utf8.count],
                                                 maximumBytes: StorageBounds.manifestText * 2)
        self.world = world
        self.json = json
    }
}

public struct ElysiumTemplateSummaryStorageRow: Sendable, Equatable {
    public let name: String
    public let sizeX: Int32
    public let sizeY: Int32
    public let sizeZ: Int32
    public let blockCount: Int32
    public let blockEntityCount: Int32
    public let dominantBlock: String
    public let dominantDisplay: String

    public init(name: String, sizeX: Int32, sizeY: Int32, sizeZ: Int32,
                blockCount: Int32, blockEntityCount: Int32,
                dominantBlock: String, dominantDisplay: String) throws {
        try StorageBounds.validateIdentifier(name, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateBoundedText(dominantBlock, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateBoundedText(dominantDisplay, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateAggregateBytes(
            [name.utf8.count, dominantBlock.utf8.count, dominantDisplay.utf8.count],
            maximumBytes: StorageBounds.manifestText * 3)
        guard sizeX >= 0, sizeY >= 0, sizeZ >= 0,
              blockCount >= 0, blockEntityCount >= 0 else {
            throw ElysiumStorageError.invalidValue
        }
        self.name = name
        self.sizeX = sizeX
        self.sizeY = sizeY
        self.sizeZ = sizeZ
        self.blockCount = blockCount
        self.blockEntityCount = blockEntityCount
        self.dominantBlock = dominantBlock
        self.dominantDisplay = dominantDisplay
    }
}

public struct ElysiumTemplateStorageRow: Sendable, Equatable {
    public let summary: ElysiumTemplateSummaryStorageRow
    public let json: String
    public let created: Double
    public let format: Int32
    public let data: Data?

    public init(summary: ElysiumTemplateSummaryStorageRow, json: String, created: Double,
                format: Int32, data: Data?) throws {
        try StorageBounds.validateBoundedText(json, maximumBytes: StorageBounds.templateJSON)
        guard created.isFinite, format >= 1 else { throw ElysiumStorageError.invalidValue }
        if let data, data.count > StorageBounds.templateData {
            throw ElysiumStorageError.limitExceeded
        }
        try StorageBounds.validateAggregateBytes(
            [summary.name.utf8.count, json.utf8.count, data?.count ?? 0,
             summary.dominantBlock.utf8.count, summary.dominantDisplay.utf8.count],
            maximumBytes: StorageBounds.templateVariableBytes)
        self.summary = summary
        self.json = json
        self.created = created
        self.format = format
        self.data = data
    }
}

public struct ElysiumLegacyLANPlayerJSON: Sendable, Equatable {
    public let playerID: String
    public let json: String

    public init(playerID: String, json: String) {
        self.playerID = playerID
        self.json = json
    }
}

public struct ElysiumLegacyTemplateContent: Sendable, Equatable {
    public let format: Int32?
    public let data: Data?
    public let json: String?

    public init(format: Int32?, data: Data?, json: String?) {
        self.format = format
        self.data = data
        self.json = json
    }
}

public struct ElysiumTemplateSummaryCandidate: Sendable, Equatable {
    public let name: String
    public let sizeX: Int32?
    public let sizeY: Int32?
    public let sizeZ: Int32?
    public let blockCount: Int32?
    public let blockEntityCount: Int32?
    public let dominantBlock: String?
    public let dominantDisplay: String?

    public init(name: String, sizeX: Int32?, sizeY: Int32?, sizeZ: Int32?,
                blockCount: Int32?, blockEntityCount: Int32?,
                dominantBlock: String?, dominantDisplay: String?) {
        self.name = name
        self.sizeX = sizeX
        self.sizeY = sizeY
        self.sizeZ = sizeZ
        self.blockCount = blockCount
        self.blockEntityCount = blockEntityCount
        self.dominantBlock = dominantBlock
        self.dominantDisplay = dominantDisplay
    }
}

public struct ElysiumLegacyWorldImport: Sendable, Equatable {
    public let world: ElysiumWorldStorageRow
    public let player: ElysiumPlayerJSONStorageRow?
    public let advancements: ElysiumAdvancementStorageRow?
    public let chunks: [ElysiumChunkStorageRow]

    public init(world: ElysiumWorldStorageRow, player: ElysiumPlayerJSONStorageRow?,
                advancements: ElysiumAdvancementStorageRow?, chunks: [ElysiumChunkStorageRow]) throws {
        guard chunks.count <= StorageBounds.chunkRows else { throw ElysiumStorageError.limitExceeded }
        guard player?.world == world.id || player == nil,
              advancements?.world == world.id || advancements == nil,
              chunks.allSatisfy({ $0.key.world == world.id }) else {
            throw ElysiumStorageError.invalidValue
        }
        self.world = world
        self.player = player
        self.advancements = advancements
        self.chunks = chunks
    }
}

private enum StorageBounds {
    static let manifestText = 1_048_576
    static let playerJSON = 786_432
    static let templateJSON = 24_000_000
    static let templateData = 64_000_000
    static let templateVariableBytes = 91_145_728
    static let chunkBlob = 67_108_864
    static let chunkVariableBytes = 68_157_440
    static let sqliteLengthLimit = 91_146_752
    static let worldRows = 4_096
    static let worldBrowserIDBytes = 256
    static let worldBrowserAggregateBytes = 67_108_864
    static let worldBatchEnvelopeBytes = 1_310_720
    static let worldBatchStatementWorkUnits = 53_248
    static let worldBatchStatementTemplates = 13
    static let templateRows = 1_024
    static let lanPeerRows = 256
    static let chunkRows = 1_048_576
    static let chunkKeyBytes = 268_435_456
    static let pageRows = 256

    static func validateIdentifier(_ value: String, maximumBytes: Int) throws {
        guard !value.utf8.isEmpty else { throw ElysiumStorageError.invalidValue }
        try validateBoundedText(value, maximumBytes: maximumBytes)
    }

    static func validateRPGWorldRecordID(_ value: String) throws {
        guard !value.utf8.isEmpty else { throw ElysiumStorageError.invalidValue }
        guard value.utf8.count <= 64 else { throw ElysiumStorageError.limitExceeded }
    }

    static func validateBoundedText(_ value: String, maximumBytes: Int) throws {
        guard value.utf8.count <= maximumBytes else { throw ElysiumStorageError.limitExceeded }
    }

    static func validateAggregateBytes(_ byteCounts: [Int], maximumBytes: Int) throws {
        var total = 0
        for count in byteCounts {
            guard count >= 0 else { throw ElysiumStorageError.invalidValue }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow, next <= maximumBytes else { throw ElysiumStorageError.limitExceeded }
            total = next
        }
    }
}

/// Shared checked arithmetic for the saved-world browser's aggregate-byte,
/// chunk-row, and statement-work budgets. Keeping the boundary arithmetic in
/// one production kernel prevents test-only replicas from masking overflow or
/// an off-by-one at a destructive-operation cap.
enum StorageWorldBatchCheckedAccumulator {
    /// The checked authority is two world-snapshot reads plus one read for
    /// each of migrations, preferences, chunks, player, and advancements.
    /// RPG-local aggregate accounting is folded into the migration read so it
    /// cannot silently add an eighth authority template.
    static let authorityStatementTemplates = 7
    static let deleteStatementTemplates = 6

    static func statementTemplateCount(deleteTemplateCount: Int) throws -> Int {
        guard deleteTemplateCount == deleteStatementTemplates else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let (total, overflow) = authorityStatementTemplates
            .addingReportingOverflow(deleteTemplateCount)
        guard !overflow, total == StorageBounds.worldBatchStatementTemplates else {
            throw ElysiumStorageError.schemaIntegrity
        }
        return total
    }

    static func adding(_ current: Int, _ increment: Int, maximum: Int) throws -> Int {
        guard current >= 0, increment >= 0, maximum >= 0 else {
            throw ElysiumStorageError.invalidValue
        }
        let (next, overflow) = current.addingReportingOverflow(increment)
        guard !overflow, next <= maximum else { throw ElysiumStorageError.limitExceeded }
        return next
    }

    static func worldAggregate(_ current: Int, adding bytes: Int) throws -> Int {
        try adding(current, bytes, maximum: StorageBounds.worldBrowserAggregateBytes)
    }

    static func chunkRows(_ current: Int, adding rows: Int = 1) throws -> Int {
        try adding(current, rows, maximum: StorageBounds.chunkRows)
    }

    static func statementWork(requestCount: Int) throws -> Int {
        guard requestCount >= 0 else { throw ElysiumStorageError.invalidValue }
        let templates = try statementTemplateCount(
            deleteTemplateCount: deleteStatementTemplates)
        let (work, overflow) = requestCount.multipliedReportingOverflow(
            by: templates)
        guard !overflow, work <= StorageBounds.worldBatchStatementWorkUnits else {
            throw ElysiumStorageError.limitExceeded
        }
        return work
    }
}

private final class StorageWorldBatchAuthorityStatementCounter {
    private(set) var preparedTemplates = 0

    func willPrepare() throws {
        let (next, overflow) = preparedTemplates.addingReportingOverflow(1)
        guard !overflow,
              next <= StorageWorldBatchCheckedAccumulator.authorityStatementTemplates else {
            throw ElysiumStorageError.limitExceeded
        }
        preparedTemplates = next
    }
}

private func withWorldBatchAuthorityStatement<T>(
    _ context: StorageContext, _ sql: StaticString,
    counter: StorageWorldBatchAuthorityStatementCounter?,
    _ body: (StorageStatement) throws -> T
) throws -> T {
    try counter?.willPrepare()
    return try withStatement(context, sql, body)
}

// MARK: - Process-wide physical database lease

private struct StorageFileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
    }

    var deviceBitPattern: UInt64 {
        UInt64(UInt32(bitPattern: device))
    }
}

private let storageDescriptorIdentityObservationLimit = 65_536

/// One bounded native-identity equality/count kernel for production fstat scans and the DEBUG
/// value-only regression seam. A nil observation is absent and can never match.
private func storageDescriptorIdentityCount(
    target: StorageFileIdentity,
    observationCount: Int,
    observation: (Int) -> StorageFileIdentity?
) -> Int? {
    guard (0...storageDescriptorIdentityObservationLimit).contains(observationCount) else {
        return nil
    }
    var count = 0
    for index in 0..<observationCount {
        if observation(index) == target { count += 1 }
    }
    return count
}

#if DEBUG
enum ElysiumStorageDescriptorIdentityProbe {
    static func descriptorCount(targetDevice: dev_t, targetInode: ino_t,
                                observations: [(dev_t, ino_t)?]) -> Int? {
        var targetValue = stat()
        targetValue.st_dev = targetDevice
        targetValue.st_ino = targetInode
        let target = StorageFileIdentity(targetValue)
        return storageDescriptorIdentityCount(
            target: target, observationCount: observations.count) { index in
                guard let value = observations[index] else { return nil }
                var information = stat()
                information.st_dev = value.0
                information.st_ino = value.1
                return StorageFileIdentity(information)
            }
    }

    static func deviceBitPattern(_ device: dev_t) -> UInt64 {
        UInt64(UInt32(bitPattern: device))
    }
}
#endif

#if DEBUG
private enum StorageLegacyImportFailurePoint: Equatable {
    case deleteWorlds, deleteChunks, deletePlayer, deleteAdvancements
    case insertWorld, insertPlayer, insertAdvancement
    case insertFirstChunk, insertMiddleChunk, insertLastChunk
}

enum ElysiumStorageFactoryFailurePoint: Equatable {
    case afterSQLiteOpen
    case beforeBootstrapStatement(Int)
    case quickCheckBudgetExhausted
}

struct ElysiumStorageSQLiteLengthLimitProbe: Equatable {
    let configured: Int32
    let exactBindCode: Int32
    let oneOverBindCode: Int32
}

enum ElysiumStorageLegacyCollectionFailurePoint: Equatable {
    case countDrift
    case nonMonotonicRowID
}

enum ElysiumStorageLegacyImportFailurePoint: Equatable, CaseIterable {
    case deleteWorlds, deleteChunks, deletePlayer, deleteAdvancements
    case insertWorld, insertPlayer, insertAdvancement
    case insertFirstChunk, insertMiddleChunk, insertLastChunk
    case commit
}

enum ElysiumStorageBarrierFailurePoint: Equatable {
    case checkpointBusy
    case checkpointRemainingFrames
    case durabilitySyncFailure
}

enum ElysiumStorageSchemaAuditProbe: CaseIterable {
    case tempPageCount
    case pageCountArgument
    case missingQuickCheckArgument
    case wrongQuickCheckArgument
    case integrityCheck
    case partialQuickCheck
    case tableValuedPageCount
    case dbstat
}

enum ElysiumStorageTestStage: Sendable {
    case afterChunkKeyPreflight
    case afterDurabilitySyncBeforeIdentityProof
}

enum ElysiumStorageRPGLocalTestOperation: Sendable, CaseIterable {
    case legacyMaterialization
    case worldDelete
}

package enum ElysiumStorageRPGLocalFailureStage: Sendable, Equatable {
    case begin
    case prepare(statement: Int)
    case bind(statement: Int)
    case step(statement: Int)
    case changes(statement: Int)
    case reset(statement: Int, requestIndex: Int)
    case clearBindings(statement: Int, requestIndex: Int)
    case finalize(statement: Int)
    case postcondition
    case commit
    case afterCommitBeforePublication
    case afterCommitAuthorityMutation(worldID: String)
}

enum ElysiumStorageTestStageError: Error, Equatable {
    case timeout
}

enum ElysiumStorageTestDeadlineBoundary {
    case externalWait
    case executorWait
}

package struct ElysiumStorageRecoverySideEffectSnapshot: Equatable {
    package let rpgLocalSchemaObjects: [String]
    package let totalChanges: Int32
    package let authorizationGeneration: UInt64
    package let authorizationIsDenyAll: Bool
    package let authorizationDenied: Bool
}

final class ElysiumStorageTestLatch: @unchecked Sendable {
    private enum State {
        case armed
        case reached
        case resumed
        case consumed
        case cancelled
        case executorTimedOut
    }

    private let lock = NSLock()
    private let reached = DispatchGroup()
    private let resumed = DispatchGroup()
    private var state: State = .armed
    private var externalDeadline: UInt64?
    private var resumeDeadline: UInt64?
    private var reachedAt: UInt64?
    private var resumedAt: UInt64?
    private var resumeRequestedAt: UInt64?
    private var reachedSignalled = false
    private var resumedSignalled = false
    private static let timeoutNanoseconds: UInt64 = 5_000_000_000

    fileprivate init() {
        reached.enter()
        resumed.enter()
    }

    func waitUntilReached() throws {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        expireLocked(at: now)
        do {
            try rejectTerminalLocked()
            if externalDeadline == nil {
                guard let deadline = checkedDeadline(after: now) else {
                    transitionToTerminalLocked(.cancelled)
                    throw ElysiumStorageTestStageError.timeout
                }
                externalDeadline = deadline
            }
            guard let deadline = externalDeadline else {
                transitionToTerminalLocked(.cancelled)
                throw ElysiumStorageTestStageError.timeout
            }
            if let reachedAt, reachedAt < deadline {
                lock.unlock()
                return
            }
            lock.unlock()
            _ = reached.wait(timeout: DispatchTime(uptimeNanoseconds: deadline))
        } catch {
            lock.unlock()
            throw error
        }

        lock.lock()
        let completionTick = DispatchTime.now().uptimeNanoseconds
        expireLocked(at: completionTick)
        do {
            try rejectTerminalLocked()
            guard let deadline = externalDeadline,
                  let reachedAt, reachedAt < deadline else {
                if state == .armed { transitionToTerminalLocked(.cancelled) }
                throw ElysiumStorageTestStageError.timeout
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    func resume() throws {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        expireLocked(at: now)
        do {
            try rejectTerminalLocked()
            switch state {
            case .armed:
                if resumeRequestedAt == nil { resumeRequestedAt = now }
            case .reached:
                guard let deadline = resumeDeadline, now < deadline else {
                    transitionToTerminalLocked(.executorTimedOut)
                    throw ElysiumStorageTestStageError.timeout
                }
                if resumedAt == nil { resumedAt = now }
                state = .resumed
                signalResumedLocked()
            case .resumed, .consumed:
                break
            case .cancelled, .executorTimedOut:
                throw ElysiumStorageTestStageError.timeout
            }
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    fileprivate var isReapable: Bool {
        lock.lock()
        defer { lock.unlock() }
        expireLocked(at: DispatchTime.now().uptimeNanoseconds)
        switch state {
        case .consumed, .cancelled, .executorTimedOut: return true
        case .armed, .reached, .resumed: return false
        }
    }

    fileprivate func executorReachAndWait() throws {
        lock.lock()
        let reachedTick = DispatchTime.now().uptimeNanoseconds
        expireLocked(at: reachedTick)
        do {
            try rejectTerminalLocked()
            guard state == .armed else { throw ElysiumStorageTestStageError.timeout }
            reachedAt = reachedTick
            state = .reached
            signalReachedLocked()
            guard let deadline = checkedDeadline(after: reachedTick) else {
                transitionToTerminalLocked(.executorTimedOut)
                throw ElysiumStorageTestStageError.timeout
            }
            resumeDeadline = deadline
            if let requestedAt = resumeRequestedAt {
                guard requestedAt <= reachedTick, reachedTick < deadline else {
                    transitionToTerminalLocked(.executorTimedOut)
                    throw ElysiumStorageTestStageError.timeout
                }
                resumedAt = reachedTick
                state = .resumed
                signalResumedLocked()
                state = .consumed
                lock.unlock()
                return
            }
            lock.unlock()
            _ = resumed.wait(timeout: DispatchTime(uptimeNanoseconds: deadline))
        } catch {
            lock.unlock()
            throw error
        }

        lock.lock()
        let completionTick = DispatchTime.now().uptimeNanoseconds
        expireLocked(at: completionTick)
        do {
            try rejectTerminalLocked()
            guard let deadline = resumeDeadline,
                  let resumedAt, resumedAt < deadline,
                  state == .resumed || state == .consumed else {
                transitionToTerminalLocked(.executorTimedOut)
                throw ElysiumStorageTestStageError.timeout
            }
            state = .consumed
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    func _testExpireDeadline(_ boundary: ElysiumStorageTestDeadlineBoundary) throws {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        expireLocked(at: now)
        do {
            try rejectTerminalLocked()
            switch boundary {
            case .externalWait:
                guard state == .armed else { throw ElysiumStorageError.invalidValue }
                if externalDeadline == nil {
                    guard let deadline = checkedDeadline(after: now) else {
                        transitionToTerminalLocked(.cancelled)
                        throw ElysiumStorageTestStageError.timeout
                    }
                    externalDeadline = deadline
                }
                externalDeadline = now
            case .executorWait:
                guard state == .reached else { throw ElysiumStorageError.invalidValue }
                resumeDeadline = now
            }
            expireLocked(at: now)
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    private func checkedDeadline(after tick: UInt64) -> UInt64? {
        let (deadline, overflow) = tick.addingReportingOverflow(Self.timeoutNanoseconds)
        return overflow ? nil : deadline
    }

    private func expireLocked(at tick: UInt64) {
        switch state {
        case .armed:
            if let deadline = externalDeadline, reachedAt == nil, tick >= deadline {
                transitionToTerminalLocked(.cancelled)
            }
        case .reached:
            if let deadline = resumeDeadline, resumedAt == nil, tick >= deadline {
                transitionToTerminalLocked(.executorTimedOut)
            }
        case .resumed, .consumed, .cancelled, .executorTimedOut:
            break
        }
    }

    private func rejectTerminalLocked() throws {
        if state == .cancelled || state == .executorTimedOut {
            throw ElysiumStorageTestStageError.timeout
        }
    }

    private func transitionToTerminalLocked(_ terminal: State) {
        guard terminal == .cancelled || terminal == .executorTimedOut else {
            preconditionFailure("invalid latch terminal state")
        }
        guard state != .cancelled, state != .executorTimedOut else { return }
        state = terminal
        signalReachedLocked()
        signalResumedLocked()
    }

    private func signalReachedLocked() {
        guard !reachedSignalled else { return }
        reachedSignalled = true
        reached.leave()
    }

    private func signalResumedLocked() {
        guard !resumedSignalled else { return }
        resumedSignalled = true
        resumed.leave()
    }
}
#endif

private final class StoragePathLease {
    private static let registryLock = NSLock()
    private static var reservedPaths = Set<String>()
    private static var reservedFiles = Set<StorageFileIdentity>()
    private static var tombstonePaths = Set<String>()
    private static var tombstoneFiles = Set<StorageFileIdentity>()

    let path: String
    private let parentPath: String
    private let filename: String
    private(set) var identity: StorageFileIdentity?
    private(set) var parentIdentity: StorageFileIdentity?
    private(set) var descriptor: Int32 = -1
    private(set) var parentDescriptor: Int32 = -1
    private var released = false

    private init(path: String, parentPath: String, filename: String) {
        self.path = path
        self.parentPath = parentPath
        self.filename = filename
    }

    static func reserve(databaseURL: URL) throws -> StoragePathLease {
        guard databaseURL.isFileURL else { throw ElysiumStorageError.invalidValue }
        let standardized = databaseURL.standardizedFileURL
        let parent = standardized.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            let nsError = error as NSError
            let code: Int32
            if nsError.domain == NSPOSIXErrorDomain,
               let exactCode = Int32(exactly: nsError.code), exactCode > 0 {
                code = exactCode
            } else {
                code = EIO
            }
            throw ElysiumStorageError.openFailed(primaryCode: code, extendedCode: code)
        }
        var canonicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(parent.path, &canonicalBuffer) != nil else {
            throw ElysiumStorageError.openFailed(primaryCode: Int32(errno), extendedCode: Int32(errno))
        }
        // Do not call URL.standardizedFileURL after POSIX realpath: Foundation maps
        // /private/var back through the /var symlink, which defeats NOFOLLOW.
        let canonicalParentPath = String(cString: canonicalBuffer)
        let canonicalParent = URL(fileURLWithPath: canonicalParentPath, isDirectory: true)
        let filename = standardized.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            throw ElysiumStorageError.invalidValue
        }
        let path = canonicalParent.appendingPathComponent(filename, isDirectory: false).path

        registryLock.lock()
        if reservedPaths.contains(path) || tombstonePaths.contains(path) {
            registryLock.unlock()
            throw ElysiumStorageError.duplicateOpen
        }
        reservedPaths.insert(path)
        registryLock.unlock()

        let lease = StoragePathLease(path: path, parentPath: canonicalParentPath,
                                     filename: filename)
        do {
            let parentFD = Darwin.open(canonicalParentPath,
                                       O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard parentFD >= 0 else {
                throw ElysiumStorageError.openFailed(primaryCode: Int32(errno),
                                                    extendedCode: Int32(errno))
            }
            lease.parentDescriptor = parentFD
            var parentInfo = stat()
            let parentStatRC = fstat(parentFD, &parentInfo)
            guard parentStatRC == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
                let code = parentStatRC == 0 ? EIO : Int32(errno)
                throw ElysiumStorageError.openFailed(primaryCode: code, extendedCode: code)
            }
            lease.parentIdentity = StorageFileIdentity(parentInfo)

            let fd = Darwin.openat(parentFD, filename,
                                   O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                                   S_IRUSR | S_IWUSR)
            guard fd >= 0 else {
                if errno == ELOOP { throw ElysiumStorageError.invalidValue }
                throw ElysiumStorageError.openFailed(primaryCode: Int32(errno), extendedCode: Int32(errno))
            }
            lease.descriptor = fd
            var info = stat()
            let statRC = fstat(fd, &info)
            guard statRC == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                let code = statRC == 0 ? EIO : Int32(errno)
                throw ElysiumStorageError.openFailed(primaryCode: code, extendedCode: code)
            }
            let identity = StorageFileIdentity(info)

            // SQLite is not opened until this identity reservation succeeds. Thus two
            // path aliases can race through path reservation, but only one can bind the
            // shared (device,inode) lease and reach the SQLite factory.
            registryLock.lock()
            if reservedFiles.contains(identity) || tombstoneFiles.contains(identity) {
                registryLock.unlock()
                throw ElysiumStorageError.duplicateOpen
            }
            reservedFiles.insert(identity)
            lease.identity = identity
            registryLock.unlock()
            return lease
        } catch {
            lease.release(tombstone: false)
            throw error
        }
    }

    func verifyPathIdentity() throws {
        guard let identity, let parentIdentity,
              descriptor >= 0, parentDescriptor >= 0 else {
            throw ElysiumStorageError.openFailed(primaryCode: EIO, extendedCode: EIO)
        }
        var retainedParentInfo = stat()
        let retainedParentRC = fstat(parentDescriptor, &retainedParentInfo)
        guard retainedParentRC == 0,
              (retainedParentInfo.st_mode & S_IFMT) == S_IFDIR,
              StorageFileIdentity(retainedParentInfo) == parentIdentity else {
            let code = retainedParentRC == 0 ? EIO : Int32(errno)
            throw ElysiumStorageError.openFailed(primaryCode: code, extendedCode: code)
        }

        var namedParentInfo = stat()
        let namedParentRC = lstat(parentPath, &namedParentInfo)
        guard namedParentRC == 0,
              (namedParentInfo.st_mode & S_IFMT) == S_IFDIR,
              StorageFileIdentity(namedParentInfo) == parentIdentity else {
            let code = namedParentRC == 0 ? EIO : Int32(errno)
            throw ElysiumStorageError.openFailed(primaryCode: code, extendedCode: code)
        }

        var retainedFileInfo = stat()
        let retainedFileRC = fstat(descriptor, &retainedFileInfo)
        guard retainedFileRC == 0, (retainedFileInfo.st_mode & S_IFMT) == S_IFREG,
              StorageFileIdentity(retainedFileInfo) == identity else {
            let code = retainedFileRC == 0 ? EIO : Int32(errno)
            throw ElysiumStorageError.openFailed(primaryCode: code, extendedCode: code)
        }

        var namedFileInfo = stat()
        let namedFileRC = fstatat(parentDescriptor, filename, &namedFileInfo, AT_SYMLINK_NOFOLLOW)
        guard namedFileRC == 0, (namedFileInfo.st_mode & S_IFMT) == S_IFREG,
              StorageFileIdentity(namedFileInfo) == identity else {
            let code = namedFileRC == 0 ? EIO : Int32(errno)
            throw ElysiumStorageError.openFailed(primaryCode: code, extendedCode: code)
        }
    }

    func verifiedParentIdentity() throws -> StorageFileIdentity {
        try verifyPathIdentity()
        guard let parentIdentity else {
            throw ElysiumStorageError.openFailed(primaryCode: EIO, extendedCode: EIO)
        }
        return parentIdentity
    }

    func performVerifiedSQLiteOpen(_ body: () -> Int32,
                                   afterOpen: () throws -> Void) throws -> Int32 {
        StoragePathLease.registryLock.lock()
        defer { StoragePathLease.registryLock.unlock() }
        let before = descriptorCount(for: identity)
        let rc = body()
        guard rc == SQLITE_OK else { return rc }
        try afterOpen()
        try verifyPathIdentity()
        let after = descriptorCount(for: identity)
        guard after > before else {
            throw storageSQLiteOpenFailure(SQLITE_CANTOPEN)
        }
        return rc
    }

    private func descriptorCount(for identity: StorageFileIdentity?) -> Int {
        guard let identity else { return 0 }
        // The SQLite main descriptor is allocated immediately after the retained
        // lease descriptor in this serialized open window. Scan a bounded margin;
        // fail closed above the audited descriptor ceiling rather than scan an
        // attacker-inflated process limit.
        let desiredBound = max(Int(descriptor) + 1_024, 4_096)
        let upperBound = min(Int(getdtablesize()), min(desiredBound, 65_536))
        return storageDescriptorIdentityCount(
            target: identity, observationCount: upperBound) { descriptor in
            var info = stat()
            guard fstat(Int32(descriptor), &info) == 0 else { return nil }
            return StorageFileIdentity(info)
        } ?? 0
    }

    func verifySQLiteDescriptorStillBound() throws {
        try verifyPathIdentity()
        guard descriptorCount(for: identity) >= 2 else {
            throw storageSQLiteOpenFailure(SQLITE_CANTOPEN)
        }
    }

    func release(tombstone: Bool) {
        StoragePathLease.registryLock.lock()
        guard !released else {
            StoragePathLease.registryLock.unlock()
            return
        }
        released = true
        StoragePathLease.reservedPaths.remove(path)
        if let identity {
            StoragePathLease.reservedFiles.remove(identity)
            if tombstone { StoragePathLease.tombstoneFiles.insert(identity) }
        }
        if tombstone { StoragePathLease.tombstonePaths.insert(path) }
        StoragePathLease.registryLock.unlock()
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        if parentDescriptor >= 0 {
            Darwin.close(parentDescriptor)
            parentDescriptor = -1
        }
    }

    deinit {
        release(tombstone: false)
    }
}

// MARK: - Private authorization and executor lifecycle

private enum StorageAuthorizationScope: Equatable {
    case denyAll
    case configuration
    case schemaAudit
    case coreBootstrap
    case coreRead(Set<String>)
    case coreMutation(table: String)
    case coreMultiMutation(Set<String>)
    case rpgLocalPreferencesBootstrap
    case rpgLocalPreferencesReadV1
    case rpgLocalPreferencesWriteV1
    case playerJSONCompareAndSwapV1
    case coreWorldDeleteWithRPGV1
    case lanClientAuthorityBootstrap
    case lanClientAuthorityCheckpointV6
    case lanClientNoticeAcknowledgementV6
    case legacyWorldCollection
    case legacyTemplateCollection
    case legacyLANPlayerCollection
    case legacyChunkKeyCollection
    case transactionControl
}

private final class StorageAuthorizerState {
    var scope: StorageAuthorizationScope = .denyAll
    var denied = false
}

private func cStringEquals(_ pointer: UnsafePointer<CChar>?, _ literal: StaticString) -> Bool {
    guard let pointer else { return false }
    return literal.withUTF8Buffer { buffer in
        guard let base = buffer.baseAddress else { return false }
        let count = buffer.count
        guard strlen(pointer) == count else { return false }
        return memcmp(pointer, base, count) == 0
    }
}

private typealias StorageAuthorizerCallback = @convention(c) (
    UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, UnsafePointer<CChar>?,
    UnsafePointer<CChar>?, UnsafePointer<CChar>?
) -> Int32

private let storageAuthorizerCallback: StorageAuthorizerCallback = {
    rawState, action, argument1, argument2, database, triggerOrView in
    guard let rawState else { return SQLITE_DENY }
    let state = Unmanaged<StorageAuthorizerState>.fromOpaque(rawState).takeUnretainedValue()
    if triggerOrView != nil {
        state.denied = true
        return SQLITE_DENY
    }

    func tableName() -> String? { argument1.map(String.init(cString:)) }
    func columnName() -> String? { argument2.map(String.init(cString:)) }
    func isMainDatabase() -> Bool { cStringEquals(database, "main") }
    func deny() -> Int32 { state.denied = true; return SQLITE_DENY }
    func allowedKnownTable(_ name: String?) -> Bool {
        guard let name else { return false }
        return StorageSchema.knownTables.contains(name)
    }
    func allowedAutomaticIndex() -> Bool {
        guard let index = tableName(), let table = columnName(),
              StorageSchema.knownTables.contains(table) else { return false }
        return index == "sqlite_autoindex_\(table)_1"
            || StorageSchema.componentImplicitIndexes[index] == table
    }
    func allowedSchemaLayoutPragma() -> Bool {
        guard let argument = columnName() else { return false }
        if cStringEquals(argument1, "index_xinfo") {
            return StorageSchema.indexNameByTable.values.contains(argument)
        }
        if cStringEquals(argument1, "table_info")
            || cStringEquals(argument1, "index_list")
            || cStringEquals(argument1, "foreign_key_list")
            || cStringEquals(argument1, "table_list") {
            return StorageSchema.knownTables.contains(argument)
        }
        return false
    }

    switch state.scope {
    case .denyAll:
        return deny()
    case .configuration:
        guard action == SQLITE_PRAGMA else { return deny() }
        let allowed = cStringEquals(argument1, "journal_mode")
            || cStringEquals(argument1, "synchronous")
            || cStringEquals(argument1, "busy_timeout")
            || cStringEquals(argument1, "foreign_keys")
            || (cStringEquals(argument1, "encoding") && argument2 == nil)
        return allowed ? SQLITE_OK : deny()
    case .schemaAudit:
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ {
            guard isMainDatabase() else { return deny() }
            let table = tableName()
            if table == "sqlite_master" {
                return StorageSchema.sqliteMasterColumns.contains(columnName() ?? "") ? SQLITE_OK : deny()
            }
            guard let table, allowedKnownTable(table) else { return deny() }
            return StorageSchema.columns[table]?.contains(columnName() ?? "") == true ? SQLITE_OK : deny()
        }
        if action == SQLITE_FUNCTION {
            let function = columnName()
            return (function == "length" || function == "coalesce" || function == "count" || function == "sum")
                ? SQLITE_OK : deny()
        }
        if action == SQLITE_PRAGMA {
            guard isMainDatabase() else { return deny() }
            let allowed = ((cStringEquals(argument1, "page_count")
                            || cStringEquals(argument1, "page_size")) && argument2 == nil)
                || (cStringEquals(argument1, "quick_check")
                    && cStringEquals(argument2, "1"))
                || allowedSchemaLayoutPragma()
            return allowed ? SQLITE_OK : deny()
        }
        return deny()
    case .coreBootstrap:
        switch action {
        case SQLITE_CREATE_TABLE:
            return StorageSchema.coreTables.contains(tableName() ?? "") ? SQLITE_OK : deny()
        case SQLITE_CREATE_INDEX:
            return allowedAutomaticIndex() ? SQLITE_OK : deny()
        case SQLITE_ALTER_TABLE:
            return StorageSchema.coreTables.contains(columnName() ?? "") ? SQLITE_OK : deny()
        case SQLITE_INSERT, SQLITE_UPDATE, SQLITE_DELETE:
            let table = tableName()
            if table == "sqlite_master", action == SQLITE_UPDATE {
                return StorageSchema.sqliteMasterColumns.contains(columnName() ?? "") ? SQLITE_OK : deny()
            }
            return table == "sqlite_master" ? SQLITE_OK : deny()
        case SQLITE_READ:
            let table = tableName()
            if table == "sqlite_master" {
                return StorageSchema.sqliteMasterColumns.contains(columnName() ?? "") ? SQLITE_OK : deny()
            }
            guard let table, StorageSchema.coreTables.contains(table) else { return deny() }
            return StorageSchema.columns[table]?.contains(columnName() ?? "") == true ? SQLITE_OK : deny()
        case SQLITE_SELECT, SQLITE_TRANSACTION:
            return SQLITE_OK
        case SQLITE_FUNCTION:
            let function = columnName()
            return (function == "printf" || function == "substr" || function == "length")
                ? SQLITE_OK : deny()
        case SQLITE_PRAGMA:
            return isMainDatabase() && cStringEquals(argument1, "table_info")
                && columnName().map(StorageSchema.coreTables.contains) == true ? SQLITE_OK : deny()
        default:
            return deny()
        }
    case let .coreRead(tables):
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ, let table = tableName(), tables.contains(table),
           (columnName() == "" || StorageSchema.columns[table]?
            .contains(columnName() ?? "") == true) {
            return SQLITE_OK
        }
        if action == SQLITE_FUNCTION {
            let function = columnName()
            return (function == "length" || function == "coalesce" || function == "count" || function == "sum")
                ? SQLITE_OK : deny()
        }
        return deny()
    case let .coreMutation(table):
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ, tableName() == table,
           StorageSchema.columns[table]?.contains(columnName() ?? "") == true { return SQLITE_OK }
        if (action == SQLITE_INSERT || action == SQLITE_DELETE), tableName() == table { return SQLITE_OK }
        if action == SQLITE_UPDATE, tableName() == table,
           StorageSchema.columns[table]?.contains(columnName() ?? "") == true { return SQLITE_OK }
        return deny()
    case let .coreMultiMutation(tables):
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ, let table = tableName(), tables.contains(table),
           StorageSchema.columns[table]?.contains(columnName() ?? "") == true { return SQLITE_OK }
        if (action == SQLITE_INSERT || action == SQLITE_DELETE),
           tableName().map(tables.contains) == true { return SQLITE_OK }
        if action == SQLITE_UPDATE, let table = tableName(), tables.contains(table),
           StorageSchema.columns[table]?.contains(columnName() ?? "") == true { return SQLITE_OK }
        return deny()
    case .rpgLocalPreferencesBootstrap:
        switch action {
        case SQLITE_CREATE_TABLE:
            return tableName().map(StorageSchema.rpgLocalTables.contains) == true ? SQLITE_OK : deny()
        case SQLITE_CREATE_INDEX:
            return allowedAutomaticIndex() ? SQLITE_OK : deny()
        case SQLITE_INSERT:
            let table = tableName()
            return table == "sqlite_master" || table == StorageSchema.componentMarkerTable
                ? SQLITE_OK : deny()
        case SQLITE_UPDATE, SQLITE_DELETE:
            return tableName() == "sqlite_master" ? SQLITE_OK : deny()
        case SQLITE_READ:
            guard isMainDatabase(), let table = tableName() else { return deny() }
            if table == "sqlite_master" {
                return StorageSchema.sqliteMasterColumns.contains(columnName() ?? "") ? SQLITE_OK : deny()
            }
            return StorageSchema.rpgLocalTables.contains(table)
                && StorageSchema.columns[table]?.contains(columnName() ?? "") == true
                ? SQLITE_OK : deny()
        case SQLITE_SELECT, SQLITE_TRANSACTION:
            return SQLITE_OK
        case SQLITE_FUNCTION:
            let function = columnName()
            return (function == "typeof" || function == "length") ? SQLITE_OK : deny()
        default:
            return deny()
        }
    case .rpgLocalPreferencesReadV1:
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ, tableName() == "worlds",
           (columnName() == "" || columnName() == "id") { return SQLITE_OK }
        if action == SQLITE_READ, let table = tableName(),
           StorageSchema.rpgLocalRuntimeTables.contains(table),
           (columnName() == "" || StorageSchema.columns[table]?
            .contains(columnName() ?? "") == true) { return SQLITE_OK }
        if action == SQLITE_FUNCTION {
            let function = columnName()
            return (function == "length" || function == "coalesce" || function == "count"
                    || function == "sum") ? SQLITE_OK : deny()
        }
        return deny()
    case .rpgLocalPreferencesWriteV1:
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ, let table = tableName() {
            if table == "worlds" {
                return (columnName() == "" || columnName() == "id") ? SQLITE_OK : deny()
            }
            return StorageSchema.rpgLocalRuntimeTables.contains(table)
                && (columnName() == "" || StorageSchema.columns[table]?
                    .contains(columnName() ?? "") == true)
                ? SQLITE_OK : deny()
        }
        if action == SQLITE_INSERT || action == SQLITE_UPDATE {
            return tableName().map(StorageSchema.rpgLocalRuntimeTables.contains) == true
                ? SQLITE_OK : deny()
        }
        if action == SQLITE_FUNCTION {
            let function = columnName()
            return (function == "length" || function == "coalesce" || function == "count"
                    || function == "sum") ? SQLITE_OK : deny()
        }
        return deny()
    case .playerJSONCompareAndSwapV1:
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ, isMainDatabase(), tableName() == "worlds",
           (columnName() == "" || columnName() == "id") { return SQLITE_OK }
        if action == SQLITE_READ, isMainDatabase(), tableName() == "player",
           (columnName() == "" || columnName() == "world" || columnName() == "json") {
            return SQLITE_OK
        }
        if action == SQLITE_INSERT, isMainDatabase(), tableName() == "player" {
            return SQLITE_OK
        }
        if action == SQLITE_UPDATE, isMainDatabase(), tableName() == "player",
           columnName() == "json" { return SQLITE_OK }
        return deny()
    case .coreWorldDeleteWithRPGV1:
        let tables = StorageSchema.rpgLocalRuntimeTables.union(
            ["worlds", "chunks", "player", "advancements"])
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ, let table = tableName(), tables.contains(table),
           (columnName() == "" || StorageSchema.columns[table]?
            .contains(columnName() ?? "") == true) { return SQLITE_OK }
        if action == SQLITE_DELETE, tableName().map(tables.contains) == true { return SQLITE_OK }
        if action == SQLITE_FUNCTION {
            let function = columnName()
            return (function == "count" || function == "sum" || function == "length"
                    || function == "coalesce") ? SQLITE_OK : deny()
        }
        return deny()
    case .lanClientAuthorityBootstrap:
        switch action {
        case SQLITE_CREATE_TABLE:
            return tableName().map(StorageSchema.clientTables.contains) == true ? SQLITE_OK : deny()
        case SQLITE_CREATE_INDEX:
            return (tableName() == StorageSchema.clientRenderIndex || allowedAutomaticIndex())
                ? SQLITE_OK : deny()
        case SQLITE_REINDEX:
            return tableName() == StorageSchema.clientRenderIndex ? SQLITE_OK : deny()
        case SQLITE_INSERT:
            let table = tableName()
            return table == "sqlite_master" || table == StorageSchema.componentMarkerTable
                ? SQLITE_OK : deny()
        case SQLITE_UPDATE, SQLITE_DELETE:
            return tableName() == "sqlite_master" ? SQLITE_OK : deny()
        case SQLITE_READ:
            guard isMainDatabase(), let table = tableName() else { return deny() }
            if table == "sqlite_master" {
                return StorageSchema.sqliteMasterColumns.contains(columnName() ?? "") ? SQLITE_OK : deny()
            }
            return (StorageSchema.clientTables.contains(table)
                    || table == StorageSchema.componentMarkerTable)
                && StorageSchema.columns[table]?.contains(columnName() ?? "") == true
                ? SQLITE_OK : deny()
        case SQLITE_SELECT, SQLITE_TRANSACTION:
            return SQLITE_OK
        case SQLITE_FUNCTION:
            let function = columnName()
            return (function == "typeof" || function == "length") ? SQLITE_OK : deny()
        default:
            return deny()
        }
    case .lanClientAuthorityCheckpointV6:
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ, let table = tableName(), StorageSchema.clientTables.contains(table),
           (columnName() == "" || StorageSchema.columns[table]?
            .contains(columnName() ?? "") == true) { return SQLITE_OK }
        if action == SQLITE_INSERT || action == SQLITE_UPDATE || action == SQLITE_DELETE {
            return tableName().map(StorageSchema.clientTables.contains) == true ? SQLITE_OK : deny()
        }
        if action == SQLITE_FUNCTION {
            let function = columnName()
            return (function == "length" || function == "coalesce" || function == "count"
                    || function == "sum") ? SQLITE_OK : deny()
        }
        return deny()
    case .lanClientNoticeAcknowledgementV6:
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_READ, tableName() == "lan_client_notification_inbox_v6",
           StorageSchema.columns["lan_client_notification_inbox_v6"]?
            .contains(columnName() ?? "") == true { return SQLITE_OK }
        if action == SQLITE_UPDATE, tableName() == "lan_client_notification_inbox_v6",
           ["acknowledgement_state", "acknowledgement_generation"]
            .contains(columnName() ?? "") { return SQLITE_OK }
        return deny()
    case .legacyWorldCollection:
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_FUNCTION { return columnName() == "count" ? SQLITE_OK : deny() }
        if action == SQLITE_READ, tableName() == "worlds", let column = columnName(),
           ["", "ROWID", "json"].contains(column) { return SQLITE_OK }
        return deny()
    case .legacyTemplateCollection:
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_FUNCTION { return columnName() == "count" ? SQLITE_OK : deny() }
        if action == SQLITE_READ, tableName() == "templates", let column = columnName(),
           ["", "ROWID", "name", "sizeX", "sizeY", "sizeZ", "blockCount",
            "blockEntityCount", "dominantBlock", "dominantDisplay"]
            .contains(column) { return SQLITE_OK }
        return deny()
    case .legacyLANPlayerCollection:
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_FUNCTION { return columnName() == "count" ? SQLITE_OK : deny() }
        if action == SQLITE_READ, tableName() == "lan_players", let column = columnName(),
           ["", "ROWID", "world", "playerID", "json"].contains(column) {
            return SQLITE_OK
        }
        return deny()
    case .legacyChunkKeyCollection:
        if action == SQLITE_SELECT { return SQLITE_OK }
        if action == SQLITE_FUNCTION {
            let function = columnName()
            return (function == "count" || function == "sum" || function == "length")
                ? SQLITE_OK : deny()
        }
        if action == SQLITE_READ, isMainDatabase(), tableName() == "chunks",
           let column = columnName(), ["", "world", "dim", "cx", "cz"].contains(column) {
            return SQLITE_OK
        }
        if action == SQLITE_PRAGMA, isMainDatabase(),
           cStringEquals(argument1, "data_version"), argument2 == nil {
            return SQLITE_OK
        }
        return deny()
    case .transactionControl:
        return action == SQLITE_TRANSACTION ? SQLITE_OK : deny()
    }
}

private final class StorageQueueIdentity {}

private final class StorageQuickCheckBudget {
    var remainingTicks: UInt64
    var exhausted: Bool

    init(remainingTicks: UInt64, exhausted: Bool = false) {
        self.remainingTicks = remainingTicks
        self.exhausted = exhausted
    }
}

private typealias StorageProgressCallback = @convention(c) (UnsafeMutableRawPointer?) -> Int32

private let storageQuickCheckProgressCallback: StorageProgressCallback = { rawBudget in
    guard let rawBudget else { return 1 }
    let budget = Unmanaged<StorageQuickCheckBudget>.fromOpaque(rawBudget).takeUnretainedValue()
    guard budget.remainingTicks > 0 else {
        budget.exhausted = true
        return 1
    }
    budget.remainingTicks -= 1
    if budget.remainingTicks == 0 {
        budget.exhausted = true
        return 1
    }
    return 0
}

private enum StorageStepResult {
    case row
    case done
}

#if DEBUG
enum ElysiumStorageTestBodyError: Error { case expected }
#endif

private let storageSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class StorageContext {
    weak var executor: StorageExecutor?
    let executorGeneration: UInt64
    let authorizationGeneration: UInt64
    let scope: StorageAuthorizationScope
    var active = true
    var firstFailure: (any Error)?
    var statements: [ObjectIdentifier: StorageStatement] = [:]

    init(executor: StorageExecutor, executorGeneration: UInt64,
         authorizationGeneration: UInt64, scope: StorageAuthorizationScope) {
        self.executor = executor
        self.executorGeneration = executorGeneration
        self.authorizationGeneration = authorizationGeneration
        self.scope = scope
    }

    func validate() throws {
        guard active else { throw ElysiumStorageError.inactiveContext }
        guard let executor else { throw ElysiumStorageError.inactiveContext }
        try executor.validate(context: self)
    }

    func latch(_ error: any Error) {
        if firstFailure == nil { firstFailure = error }
    }

    func prepare(_ sql: StaticString) throws -> StorageStatement {
        do {
            try validate()
            guard let executor else { throw ElysiumStorageError.inactiveContext }
            let statement = try executor.prepare(context: self, sql: sql)
            statements[ObjectIdentifier(statement)] = statement
            return statement
        } catch {
            latch(error)
            throw error
        }
    }

    func changes() throws -> Int {
        do {
            try validate()
            guard let executor else { throw ElysiumStorageError.inactiveContext }
            return try executor.changes(context: self)
        } catch {
            latch(error)
            throw error
        }
    }

    func invalidateAndFinalizeLeaks() -> (any Error)? {
        let leaked = !statements.isEmpty
        for statement in statements.values {
            if let finalizeFailure = statement.forceFinalize() { latch(finalizeFailure) }
        }
        statements.removeAll(keepingCapacity: false)
        active = false
        if leaked {
            let error = ElysiumStorageError.statementLeak
            if firstFailure == nil { firstFailure = error }
        }
        return firstFailure
    }
}

private final class StorageStatement {
    weak var executor: StorageExecutor?
    weak var context: StorageContext?
    private(set) var pointer: OpaquePointer?
    let executorGeneration: UInt64
    let authorizationGeneration: UInt64

    init(executor: StorageExecutor, context: StorageContext, pointer: OpaquePointer) {
        self.executor = executor
        self.context = context
        self.pointer = pointer
        executorGeneration = context.executorGeneration
        authorizationGeneration = context.authorizationGeneration
    }

    private func checkedPointer() throws -> OpaquePointer {
        guard let context else { throw ElysiumStorageError.inactiveContext }
        try context.validate()
        guard executorGeneration == context.executorGeneration,
              authorizationGeneration == context.authorizationGeneration,
              let pointer else { throw ElysiumStorageError.inactiveContext }
        return pointer
    }

    private func checkedBind(_ body: (OpaquePointer) -> Int32) throws {
        do {
            guard let executor else { throw ElysiumStorageError.inactiveContext }
            let pointer = try checkedPointer()
            try executor.injectIfRequested(.bind)
            let rc = body(pointer)
            guard rc == SQLITE_OK else { throw executor.error(.bind, code: rc) }
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func bindText(_ index: Int32, _ value: String) throws {
        try checkedBind { statement in
            value.utf8CString.withUnsafeBufferPointer { buffer in
                sqlite3_bind_text(statement, index, buffer.baseAddress,
                                  Int32(buffer.count - 1), storageSQLiteTransient)
            }
        }
    }

    func bindData(_ index: Int32, _ value: Data) throws {
        try checkedBind { statement in
            if value.isEmpty { return sqlite3_bind_zeroblob(statement, index, 0) }
            return value.withUnsafeBytes { bytes in
                sqlite3_bind_blob64(statement, index, bytes.baseAddress,
                                    sqlite3_uint64(bytes.count), storageSQLiteTransient)
            }
        }
    }

    func bindNull(_ index: Int32) throws {
        try checkedBind { sqlite3_bind_null($0, index) }
    }

    func bindInt32(_ index: Int32, _ value: Int32) throws {
        try checkedBind { sqlite3_bind_int($0, index, value) }
    }

    func bindInt64(_ index: Int32, _ value: Int64) throws {
        try checkedBind { sqlite3_bind_int64($0, index, value) }
    }

    func bindDouble(_ index: Int32, _ value: Double) throws {
        guard value.isFinite else {
            let error = ElysiumStorageError.invalidValue
            context?.latch(error)
            throw error
        }
        try checkedBind { sqlite3_bind_double($0, index, value) }
    }

    func step() throws -> StorageStepResult {
        do {
            guard let executor else { throw ElysiumStorageError.inactiveContext }
            let pointer = try checkedPointer()
            try executor.injectIfRequested(.step)
            let rc = sqlite3_step(pointer)
            switch rc {
            case SQLITE_ROW: return .row
            case SQLITE_DONE: return .done
            default: throw executor.error(.step, code: rc)
            }
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func text(_ column: Int32, maximumBytes: Int, nullable: Bool = false) throws -> String? {
        do {
            let pointer = try checkedPointer()
            let type = sqlite3_column_type(pointer, column)
            if type == SQLITE_NULL, nullable { return nil }
            guard type == SQLITE_TEXT else { throw ElysiumStorageError.invalidStorageClass }
            let byteCount = Int(sqlite3_column_bytes(pointer, column))
            guard byteCount >= 0, byteCount <= maximumBytes else { throw ElysiumStorageError.limitExceeded }
            guard let bytes = sqlite3_column_text(pointer, column) else {
                if byteCount == 0 { return "" }
                throw ElysiumStorageError.invalidStorageClass
            }
            let data = Data(bytes: bytes, count: byteCount)
            guard let value = String(data: data, encoding: .utf8) else {
                throw ElysiumStorageError.invalidUTF8
            }
            return value
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func data(_ column: Int32, maximumBytes: Int, nullable: Bool = false) throws -> Data? {
        do {
            let pointer = try checkedPointer()
            let type = sqlite3_column_type(pointer, column)
            if type == SQLITE_NULL, nullable { return nil }
            guard type == SQLITE_BLOB else { throw ElysiumStorageError.invalidStorageClass }
            let byteCount = Int(sqlite3_column_bytes(pointer, column))
            guard byteCount >= 0, byteCount <= maximumBytes else { throw ElysiumStorageError.limitExceeded }
            guard byteCount > 0 else { return Data() }
            guard let bytes = sqlite3_column_blob(pointer, column) else {
                throw ElysiumStorageError.invalidStorageClass
            }
            return Data(bytes: bytes, count: byteCount)
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func legacyText(_ column: Int32, maximumBytes: Int) throws -> String? {
        do {
            let pointer = try checkedPointer()
            guard sqlite3_column_type(pointer, column) == SQLITE_TEXT else { return nil }
            let byteCount = Int(sqlite3_column_bytes(pointer, column))
            guard byteCount >= 0, byteCount <= maximumBytes else { return nil }
            guard let bytes = sqlite3_column_text(pointer, column) else {
                return byteCount == 0 ? "" : nil
            }
            let raw = Data(bytes: bytes, count: byteCount)
            let visible = raw.prefix { $0 != 0 }
            let value = String(decoding: visible, as: UTF8.self)
            guard value.utf8.count <= maximumBytes else { return nil }
            return value
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func legacyData(_ column: Int32, maximumBytes: Int) throws -> Data? {
        do {
            let pointer = try checkedPointer()
            guard sqlite3_column_type(pointer, column) == SQLITE_BLOB else { return nil }
            let byteCount = Int(sqlite3_column_bytes(pointer, column))
            guard byteCount >= 0, byteCount <= maximumBytes else { return nil }
            guard byteCount > 0 else { return Data() }
            guard let bytes = sqlite3_column_blob(pointer, column) else { return nil }
            return Data(bytes: bytes, count: byteCount)
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func legacyInt32(_ column: Int32, nonnegative: Bool = false) throws -> Int32? {
        do {
            let pointer = try checkedPointer()
            guard sqlite3_column_type(pointer, column) == SQLITE_INTEGER,
                  let value = Int32(exactly: sqlite3_column_int64(pointer, column)),
                  !nonnegative || value >= 0 else { return nil }
            return value
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func int32(_ column: Int32) throws -> Int32 {
        let value = try int64(column)
        guard let narrowed = Int32(exactly: value) else {
            let error = ElysiumStorageError.invalidValue
            context?.latch(error)
            throw error
        }
        return narrowed
    }

    func isNull(_ column: Int32) throws -> Bool {
        do {
            let pointer = try checkedPointer()
            return sqlite3_column_type(pointer, column) == SQLITE_NULL
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func int64(_ column: Int32) throws -> Int64 {
        do {
            let pointer = try checkedPointer()
            guard sqlite3_column_type(pointer, column) == SQLITE_INTEGER else {
                throw ElysiumStorageError.invalidStorageClass
            }
            return sqlite3_column_int64(pointer, column)
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func double(_ column: Int32) throws -> Double {
        do {
            let pointer = try checkedPointer()
            guard sqlite3_column_type(pointer, column) == SQLITE_FLOAT else {
                throw ElysiumStorageError.invalidStorageClass
            }
            let value = sqlite3_column_double(pointer, column)
            guard value.isFinite else { throw ElysiumStorageError.invalidValue }
            return value
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func finalize() throws {
        do {
            guard let context, let executor else { throw ElysiumStorageError.inactiveContext }
            try context.validate()
            guard let pointer else { return }
            self.pointer = nil
            context.statements.removeValue(forKey: ObjectIdentifier(self))
            let rc = sqlite3_finalize(pointer)
            try executor.injectIfRequested(.finalize)
            guard rc == SQLITE_OK else { throw executor.error(.finalize, code: rc) }
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func resetForReuse() throws {
        do {
            let pointer = try checkedPointer()
            let reset = sqlite3_reset(pointer)
            guard reset == SQLITE_OK else {
                throw executor?.error(.step, code: reset)
                    ?? storageSQLiteError(reset, operation: .step)
            }
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func clearBindingsForReuse() throws {
        do {
            let pointer = try checkedPointer()
            let clear = sqlite3_clear_bindings(pointer)
            guard clear == SQLITE_OK else {
                throw executor?.error(.bind, code: clear)
                    ?? storageSQLiteError(clear, operation: .bind)
            }
        } catch {
            context?.latch(error)
            throw error
        }
    }

    @discardableResult
    func forceFinalize() -> ElysiumStorageError? {
        if let pointer {
            self.pointer = nil
            let rc = sqlite3_finalize(pointer)
            guard rc == SQLITE_OK else {
                return executor?.error(.finalize, code: rc)
                    ?? storageSQLiteError(rc, operation: .finalize)
            }
        }
        return nil
    }

    deinit {
        _ = forceFinalize()
    }
}

private final class StorageExecutor {
    private enum Lifecycle {
        case opening
        case open
        case closing
        case poisoned
        case closed(Result<Void, ElysiumStorageError>)
    }

    private let queue = DispatchQueue(label: "dev.elysium.storage.sqlite", qos: .utility)
    private let queueKey = DispatchSpecificKey<ObjectIdentifier>()
    private let queueIdentity = StorageQueueIdentity()
    private let lifecycleLock = NSLock()
    private var lifecycle: Lifecycle = .opening
    private var handle: OpaquePointer?
    private let authorizer = StorageAuthorizerState()
    private var authorizerCallbackRetained = false
    private let lease: StoragePathLease
    private var executorGeneration: UInt64 = 1
    private var authorizationGeneration: UInt64 = 0
    private var currentContext: StorageContext?
    private var transactionActive = false
    private var configurationVerified = false
#if DEBUG
    private let factoryProbe: (kind: Int, index: Int)?
    private var injectedFailures: [ElysiumStorageOperationID: Int] = [:]
    private var testLeakedRawStatement: OpaquePointer?
    private var authorizationTransitionCoverage: UInt8 = 0
    private var legacyCollectionFailurePoint: ElysiumStorageLegacyCollectionFailurePoint?
    private var legacyImportFailurePoint: StorageLegacyImportFailurePoint?
    private var barrierFailurePoint: ElysiumStorageBarrierFailurePoint?
    private var activeTestStage: (stage: ElysiumStorageTestStage, latch: ElysiumStorageTestLatch)?
    private var rpgLocalFailurePoint: (
        operation: ElysiumStorageRPGLocalTestOperation,
        stage: ElysiumStorageRPGLocalFailureStage
    )?
    private var activeRPGLocalTestOperation: ElysiumStorageRPGLocalTestOperation?
#endif

    static func open(databaseURL: URL) throws -> StorageExecutor {
        let lease = try StoragePathLease.reserve(databaseURL: databaseURL)
        do {
            return try StorageExecutor(lease: lease)
        } catch {
            lease.release(tombstone: false)
            throw error
        }
    }

#if DEBUG
    static func testOpen(databaseURL: URL,
                         failurePoint: ElysiumStorageFactoryFailurePoint) throws -> StorageExecutor {
        let closedProbe: (kind: Int, index: Int)
        switch failurePoint {
        case .afterSQLiteOpen:
            closedProbe = (1, 0)
        case let .beforeBootstrapStatement(index):
            guard (0...15).contains(index) else { throw ElysiumStorageError.invalidValue }
            closedProbe = (2, index)
        case .quickCheckBudgetExhausted:
            closedProbe = (3, 0)
        }
        let lease = try StoragePathLease.reserve(databaseURL: databaseURL)
        do {
            return try StorageExecutor(lease: lease, factoryProbe: closedProbe)
        } catch {
            lease.release(tombstone: false)
            throw error
        }
    }
#endif

    private init(lease: StoragePathLease) throws {
        self.lease = lease
#if DEBUG
        factoryProbe = nil
#endif
        try initializeOnQueue()
    }

#if DEBUG
    private init(lease: StoragePathLease,
                 factoryProbe: (kind: Int, index: Int)?) throws {
        self.lease = lease
        self.factoryProbe = factoryProbe
        try initializeOnQueue()
    }
#endif

    private func initializeOnQueue() throws {
        queue.setSpecific(key: queueKey, value: ObjectIdentifier(queueIdentity))
        do {
            try queue.sync { try openAndConfigure() }
            lifecycle = .open
        } catch {
            _ = queue.sync { terminalClose(tombstone: false) }
            throw error
        }
    }

    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == ObjectIdentifier(queueIdentity)
    }

    private func sqliteError(_ operation: ElysiumStorageOperationID, code: Int32? = nil) -> ElysiumStorageError {
        let extended = code ?? handle.map(sqlite3_extended_errcode) ?? SQLITE_ERROR
        return storageSQLiteError(extended, operation: operation)
    }

    fileprivate func error(_ operation: ElysiumStorageOperationID, code: Int32? = nil) -> ElysiumStorageError {
        sqliteError(operation, code: code)
    }

    fileprivate func injectIfRequested(_ operation: ElysiumStorageOperationID) throws {
#if DEBUG
        if let count = injectedFailures[operation], count > 0 {
            if count == 1 { injectedFailures.removeValue(forKey: operation) }
            else { injectedFailures[operation] = count - 1 }
            throw storageSQLiteError(SQLITE_IOERR, operation: operation)
        }
#endif
    }

    fileprivate func validate(context: StorageContext) throws {
        guard isOnQueue else { throw ElysiumStorageError.wrongExecutorOrQueue }
        guard context.active else { throw ElysiumStorageError.inactiveContext }
        guard currentContext === context,
              context.executor === self,
              context.executorGeneration == executorGeneration,
              context.authorizationGeneration == authorizationGeneration,
              context.scope == authorizer.scope else {
            throw ElysiumStorageError.wrongExecutorOrQueue
        }
    }

    fileprivate func prepare(context: StorageContext, sql: StaticString) throws -> StorageStatement {
        try validate(context: context)
        try injectIfRequested(.prepare)
        let pointer = try prepareRaw(sql, operation: .prepare)
        return StorageStatement(executor: self, context: context, pointer: pointer)
    }

    fileprivate func changes(context: StorageContext) throws -> Int {
        try validate(context: context)
        try injectIfRequested(.changes)
        guard let handle else { throw ElysiumStorageError.closed }
        return Int(sqlite3_changes(handle))
    }

    private func openAndConfigure() throws {
        precondition(isOnQueue)
        try lease.verifyPathIdentity()
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW
        do {
            let rc = try lease.performVerifiedSQLiteOpen({
                sqlite3_open_v2(lease.path, &opened, flags, nil)
            }, afterOpen: {
#if DEBUG
                if factoryProbe?.kind == 1 {
                    throw storageSQLiteOpenFailure(SQLITE_IOERR)
                }
#endif
            })
            guard rc == SQLITE_OK, let localHandle = opened else {
                let extended = opened.map(sqlite3_extended_errcode) ?? rc
                throw storageSQLiteOpenFailure(extended)
            }
            handle = localHandle
            opened = nil
        } catch {
            if let localHandle = opened {
                opened = nil
                let closeRC = sqlite3_close_v2(localHandle)
                if closeRC != SQLITE_OK { lease.release(tombstone: true) }
            }
            throw error
        }
        guard let handle else { throw ElysiumStorageError.closed }
        guard sqlite3_extended_result_codes(handle, 1) == SQLITE_OK else {
            throw sqliteError(.configure)
        }
        let retainedCallbackState = Unmanaged.passRetained(authorizer).toOpaque()
        guard sqlite3_set_authorizer(handle, storageAuthorizerCallback, retainedCallbackState) == SQLITE_OK else {
            Unmanaged<StorageAuthorizerState>.fromOpaque(retainedCallbackState).release()
            throw sqliteError(.authorizer)
        }
        authorizerCallbackRetained = true
        try configureLimits(handle)
        try withAuthorization(.configuration) {
            try verifyTextPragma("PRAGMA encoding", expected: "UTF-8")
        }
        try preflightCompatibleCoreSchema()
        try withAuthorization(.configuration) {
            try executePragma("PRAGMA journal_mode=WAL", operation: .configure)
            try verifyTextPragma("PRAGMA journal_mode", expected: "wal")
            try executePragma("PRAGMA synchronous=NORMAL", operation: .configure)
            try verifyIntegerPragma("PRAGMA synchronous", expected: 1)
            try executePragma("PRAGMA busy_timeout=5000", operation: .configure)
            try verifyIntegerPragma("PRAGMA busy_timeout", expected: 5_000)
            try executePragma("PRAGMA foreign_keys=ON", operation: .configure)
            try verifyIntegerPragma("PRAGMA foreign_keys", expected: 1)
        }
        configurationVerified = true
        try bootstrapAndAuditCoreSchema()
    }

    private func configureLimits(_ db: OpaquePointer) throws {
        let settings: [(Int32, Int32)] = [
            (SQLITE_LIMIT_LENGTH, Int32(StorageBounds.sqliteLengthLimit)),
            (SQLITE_LIMIT_SQL_LENGTH, 1_048_576),
            (SQLITE_LIMIT_COLUMN, 128),
            (SQLITE_LIMIT_VARIABLE_NUMBER, 128),
            (SQLITE_LIMIT_ATTACHED, 0),
            // SQLite implements foreign-key actions with internal trigger programs. One
            // bounded level permits the reviewed CASCADE/RESTRICT contracts; schema audit
            // still rejects every user-defined trigger.
            (SQLITE_LIMIT_TRIGGER_DEPTH, 1),
            (SQLITE_LIMIT_LIKE_PATTERN_LENGTH, 1_024),
            (SQLITE_LIMIT_FUNCTION_ARG, 32),
            (SQLITE_LIMIT_COMPOUND_SELECT, 8),
            (SQLITE_LIMIT_EXPR_DEPTH, 64),
            (SQLITE_LIMIT_VDBE_OP, 1_000_000),
            (SQLITE_LIMIT_WORKER_THREADS, 0),
        ]
        for (identifier, value) in settings {
            _ = sqlite3_limit(db, identifier, value)
            guard sqlite3_limit(db, identifier, -1) == value else {
                throw storageSQLiteError(SQLITE_ERROR, operation: .configure)
            }
        }
    }

    private enum CoreSchemaAuditMode: Equatable {
        case compatiblePreBootstrap
        case exactReady
    }

    private func preflightCompatibleCoreSchema() throws {
        try withAuthorization(.schemaAudit) {
            try auditCoreSchema(mode: .compatiblePreBootstrap, runGlobalQuickCheck: false)
        }
    }

    private func bootstrapAndAuditCoreSchema() throws {
        try withAuthorization(.coreBootstrap) {
            do {
                try executeTransactionControl("BEGIN IMMEDIATE", operation: .beginImmediate)
                transactionActive = true
                try withAuthorization(.schemaAudit) {
                    try auditCoreSchema(mode: .compatiblePreBootstrap,
                                        runGlobalQuickCheck: true)
                }
                for (index, statement) in StorageSchema.createStatements.enumerated() {
#if DEBUG
                    try injectFactoryFailureBeforeBootstrapStatement(index)
#endif
                    try executeBootstrap(statement)
                }
                let existingTemplateColumns = try rawTableColumnNames("templates")
                for (migrationIndex, migration) in StorageSchema.templateMigrations.enumerated()
                    where !existingTemplateColumns.contains(migration.name) {
#if DEBUG
                    try injectFactoryFailureBeforeBootstrapStatement(7 + migrationIndex)
#endif
                    try executeBootstrap(migration.sql)
                }
                try withAuthorization(.schemaAudit) {
                    try auditCoreSchema(mode: .exactReady, runGlobalQuickCheck: false)
                }
                try executeTransactionControl("COMMIT", operation: .commit)
                transactionActive = false
                guard let handle, sqlite3_get_autocommit(handle) != 0 else {
                    throw ElysiumStorageError.transactionStillOpen
                }
            } catch {
                let failure = recoverTransactionFailure(primary: error)
                transactionActive = false
                throw failure
            }
        }

        try withAuthorization(.schemaAudit) {
            try auditCoreSchema(mode: .exactReady, runGlobalQuickCheck: false)
        }
        authorizer.scope = .denyAll
        authorizer.denied = false
    }

#if DEBUG
    private func injectFactoryFailureBeforeBootstrapStatement(_ index: Int) throws {
        guard factoryProbe?.kind == 2, factoryProbe?.index == index else { return }
        throw storageSQLiteError(SQLITE_IOERR, operation: .step)
    }
#endif

    private func executeBootstrap(_ sql: StaticString) throws {
        try withRawStatement(sql) { statement in
            let stepRC = sqlite3_step(statement)
            guard stepRC == SQLITE_DONE else { throw sqliteError(.step, code: stepRC) }
        }
    }

    private func rawTableColumnNames(_ table: StaticString) throws -> Set<String> {
        let sql: StaticString
        switch table.description {
        case "templates": sql = "PRAGMA main.table_info('templates')"
        case "worlds": sql = "PRAGMA main.table_info('worlds')"
        case "chunks": sql = "PRAGMA main.table_info('chunks')"
        case "player": sql = "PRAGMA main.table_info('player')"
        case "lan_player_resume": sql = "PRAGMA main.table_info('lan_player_resume')"
        case "lan_players": sql = "PRAGMA main.table_info('lan_players')"
        case "advancements": sql = "PRAGMA main.table_info('advancements')"
        default: throw ElysiumStorageError.schemaMismatch
        }
        return try withRawStatement(sql) { statement in
            var names = Set<String>()
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw sqliteError(.step, code: rc) }
                names.insert(try copyRawText(statement, column: 1, maximumBytes: 65_536))
            }
            return names
        }
    }

    private func copyRawText(_ statement: OpaquePointer, column: Int32,
                             maximumBytes: Int) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else {
            throw ElysiumStorageError.invalidStorageClass
        }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount >= 0, byteCount <= maximumBytes else { throw ElysiumStorageError.limitExceeded }
        guard let bytes = sqlite3_column_text(statement, column) else {
            if byteCount == 0 { return "" }
            throw ElysiumStorageError.invalidStorageClass
        }
        let data = Data(bytes: bytes, count: byteCount)
        guard let value = String(data: data, encoding: .utf8) else {
            throw ElysiumStorageError.invalidUTF8
        }
        return value
    }

    private func bindRawText(_ statement: OpaquePointer, index: Int32, value: String) throws {
        let rc = value.utf8CString.withUnsafeBufferPointer { buffer in
            sqlite3_bind_text(statement, index, buffer.baseAddress,
                              Int32(buffer.count - 1), storageSQLiteTransient)
        }
        guard rc == SQLITE_OK else { throw sqliteError(.bind, code: rc) }
    }

    private func bindRawData(_ statement: OpaquePointer, index: Int32, value: Data) throws {
        let rc: Int32
        if value.isEmpty {
            rc = sqlite3_bind_zeroblob(statement, index, 0)
        } else {
            rc = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob64(statement, index, bytes.baseAddress,
                                    sqlite3_uint64(bytes.count), storageSQLiteTransient)
            }
        }
        guard rc == SQLITE_OK else { throw sqliteError(.bind, code: rc) }
    }

    private func auditCoreSchema(mode: CoreSchemaAuditMode,
                                 runGlobalQuickCheck: Bool) throws {
        let pageCount = try exactSchemaIntegerPragma("PRAGMA main.page_count")
        let pageSize = try exactSchemaIntegerPragma("PRAGMA main.page_size")
        guard pageCount >= 0,
              pageSize >= 512, pageSize <= 65_536,
              pageSize.nonzeroBitCount == 1 else {
            throw ElysiumStorageError.schemaMismatch
        }
        let layouts = try auditSchemaObjects(mode: mode, pageCount: pageCount)
        try auditCoreTableLayouts(layouts)
        try auditComponentMarkers()
        if runGlobalQuickCheck {
            try globalQuickCheck(pageCount: pageCount, pageSize: pageSize)
        }
    }

    private func auditComponentMarkers() throws {
        let tables: Set<String> = try withRawStatement("""
            SELECT name FROM sqlite_master WHERE type='table' AND name IN (
              'pebble_storage_component_schema_v1','rpg_local_preferences_v1',
              'rpg_local_preference_migrations_v1','lan_client_credentials_v6',
              'lan_client_owner_checkpoint_v6','lan_client_pending_disposition_v6',
              'lan_client_notification_inbox_v6') ORDER BY name
            """) { statement in
            var result = Set<String>()
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw ElysiumStorageError.schemaIntegrity }
                result.insert(try copyRawText(statement, column: 0, maximumBytes: 64))
            }
            return result
        }
        guard tables.contains(StorageSchema.componentMarkerTable) else {
            guard tables.isDisjoint(with: StorageSchema.rpgLocalRuntimeTables),
                  tables.isDisjoint(with: StorageSchema.clientTables) else {
                throw ElysiumStorageError.schemaIntegrity
            }
            return
        }
        let expected: [String: Data]
        if StorageSchema.clientTables.isSubset(of: tables) {
            guard StorageSchema.rpgLocalRuntimeTables.isSubset(of: tables) else {
                throw ElysiumStorageError.schemaIntegrity
            }
            expected = ["rpgLocalPreferences": StorageSchema.rpgLocalManifestDigest,
                        "lanClientAuthority": StorageSchema.clientManifestDigest]
        } else {
            guard StorageSchema.rpgLocalRuntimeTables.isSubset(of: tables),
                  tables.isDisjoint(with: StorageSchema.clientTables) else {
                throw ElysiumStorageError.schemaIntegrity
            }
            expected = ["rpgLocalPreferences": StorageSchema.rpgLocalManifestDigest]
        }
        try withRawStatement("""
            SELECT component,revision,manifest_digest
            FROM pebble_storage_component_schema_v1 ORDER BY component LIMIT 4
            """) { statement in
            var observed: [String: Data] = [:]
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW,
                      sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                      sqlite3_column_int64(statement, 1) == 1,
                      sqlite3_column_type(statement, 2) == SQLITE_BLOB,
                      sqlite3_column_bytes(statement, 2) == 32,
                      let bytes = sqlite3_column_blob(statement, 2) else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                let name = try copyRawText(statement, column: 0, maximumBytes: 32)
                guard observed.updateValue(Data(bytes: bytes, count: 32), forKey: name) == nil else {
                    throw ElysiumStorageError.schemaIntegrity
                }
            }
            guard observed.count == expected.count,
                  expected.allSatisfy({ name, digest in
                      observed[name].map { storageFixedTimeEqual($0, digest) } == true
                  }) else { throw ElysiumStorageError.schemaIntegrity }
        }
    }

    private func exactSchemaIntegerPragma(_ sql: StaticString) throws -> Int64 {
        try withRawStatement(sql) { statement in
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                throw ElysiumStorageError.schemaMismatch
            }
            let value = sqlite3_column_int64(statement, 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ElysiumStorageError.schemaMismatch
            }
            return value
        }
    }

    private func auditSchemaObjects(mode: CoreSchemaAuditMode,
                                    pageCount: Int64) throws -> [StorageSchema.Layout] {
        let expectedObjectCount: Int = try withRawStatement("""
            SELECT count(*), coalesce(sum(
                coalesce(length(CAST(sql AS BLOB)),0)
                + length(CAST(type AS BLOB))
                + length(CAST(name AS BLOB))
                + length(CAST(tbl_name AS BLOB))),0)
            FROM sqlite_master
            """) { aggregate in
            let aggregateRC = sqlite3_step(aggregate)
            guard aggregateRC == SQLITE_ROW,
                  sqlite3_column_type(aggregate, 0) == SQLITE_INTEGER,
                  sqlite3_column_type(aggregate, 1) == SQLITE_INTEGER else {
                throw ElysiumStorageError.schemaMismatch
            }
            let objectCount = sqlite3_column_int64(aggregate, 0)
            let totalBytes = sqlite3_column_int64(aggregate, 1)
            guard objectCount >= 0, objectCount <= 512,
                  totalBytes >= 0, totalBytes <= 1_048_576 else {
                throw ElysiumStorageError.limitExceeded
            }
            guard sqlite3_step(aggregate) == SQLITE_DONE else {
                throw ElysiumStorageError.schemaMismatch
            }
            return Int(objectCount)
        }

        var observedTables = Set<String>()
        var observedTableSQL: [String: String] = [:]
        var observedObjects = Set<StorageSchema.PhysicalObject>()
        var observedRoots = Set<Int64>()
        var observedObjectCount = 0
        var cursor = ""
        while true {
            let pageRows: Int = try withRawStatement("""
                SELECT type,name,tbl_name,rootpage,sql FROM sqlite_master
                WHERE name>? ORDER BY name LIMIT 64
                """) { page in
                try bindRawText(page, index: 1, value: cursor)
                var count = 0
                while true {
                    let rc = sqlite3_step(page)
                    if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW else { throw sqliteError(.step, code: rc) }
                    let type = try copyRawText(page, column: 0, maximumBytes: 16)
                    let name = try copyRawText(page, column: 1, maximumBytes: 65_536)
                    let table = try copyRawText(page, column: 2, maximumBytes: 65_536)
                    guard sqlite3_column_type(page, 3) == SQLITE_INTEGER else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    let rootpage = sqlite3_column_int64(page, 3)
                    guard rootpage >= 2, rootpage <= pageCount,
                          observedRoots.insert(rootpage).inserted else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    let sqlType = sqlite3_column_type(page, 4)
                    let schemaSQL: String?
                    if sqlType == SQLITE_TEXT {
                        schemaSQL = try copyRawText(page, column: 4, maximumBytes: 65_536)
                    } else if sqlType != SQLITE_NULL {
                        throw ElysiumStorageError.invalidStorageClass
                    } else { schemaSQL = nil }

                    switch type {
                    case "table":
                        guard StorageSchema.knownTables.contains(name), name == table,
                              sqlType == SQLITE_TEXT else {
                            throw ElysiumStorageError.schemaMismatch
                        }
                        observedTables.insert(name)
                        observedTableSQL[name] = schemaSQL
                    case "index":
                        if StorageSchema.indexNameByTable[table] == name,
                           StorageSchema.coreTables.contains(table) {
                            guard sqlType == SQLITE_NULL else {
                                throw ElysiumStorageError.schemaMismatch
                            }
                        } else if StorageSchema.componentImplicitIndexes[name] == table {
                            guard sqlType == SQLITE_NULL else {
                                throw ElysiumStorageError.schemaMismatch
                            }
                        } else if let expectedSQL = StorageSchema.componentIndexSQL[name],
                                  table == "lan_client_notification_inbox_v6" {
                            guard let schemaSQL,
                                  normalizedSchemaSQL(schemaSQL)
                                    == normalizedSchemaSQL(expectedSQL) else {
                                throw ElysiumStorageError.schemaMismatch
                            }
                        } else {
                            throw ElysiumStorageError.schemaMismatch
                        }
                    default:
                        throw ElysiumStorageError.schemaMismatch
                    }
                    guard observedObjects.insert(.init(type: type, name: name,
                                                       table: table)).inserted else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    cursor = name
                    count += 1
                    observedObjectCount += 1
                }
                return count
            }
            if pageRows < 64 { break }
        }
        guard observedObjectCount == expectedObjectCount else {
            throw ElysiumStorageError.schemaMismatch
        }
        if observedObjectCount == 0 {
            guard mode == .compatiblePreBootstrap, pageCount == 0 || pageCount == 1 else {
                throw ElysiumStorageError.schemaMismatch
            }
        } else if pageCount < 2 {
            throw ElysiumStorageError.schemaMismatch
        }
        let observedComponents = observedTables.subtracting(StorageSchema.coreTables)
        let legalComponentPrefix = observedComponents.isEmpty
            || observedComponents == StorageSchema.rpgLocalTables
            || observedComponents == StorageSchema.rpgLocalTables.union(StorageSchema.clientTables)
        guard legalComponentPrefix else { throw ElysiumStorageError.schemaMismatch }
        if mode == .exactReady, !StorageSchema.coreTables.isSubset(of: observedTables) {
            throw ElysiumStorageError.schemaMismatch
        }
        let expectedObjects = StorageSchema.expectedPhysicalObjects(for: observedTables)
        guard observedObjects == expectedObjects else {
            throw ElysiumStorageError.schemaMismatch
        }

        var layouts: [StorageSchema.Layout] = []
        for table in observedTables.sorted() {
            guard let actualSQL = observedTableSQL[table] else {
                throw ElysiumStorageError.schemaMismatch
            }
            if table == "templates" {
                guard let prefix = StorageSchema.templateRevisionSQL.firstIndex(where: {
                    normalizedSchemaSQL($0) == normalizedSchemaSQL(actualSQL)
                }), mode == .compatiblePreBootstrap || prefix == StorageSchema.templateMigrations.count else {
                    throw ElysiumStorageError.schemaMismatch
                }
                layouts.append(StorageSchema.templateLayout(prefixCount: prefix))
            } else {
                guard let expectedSQL = StorageSchema.canonicalTableSQL[table],
                      normalizedSchemaSQL(actualSQL) == normalizedSchemaSQL(expectedSQL) else {
                    throw ElysiumStorageError.schemaMismatch
                }
                if let layout = StorageSchema.layouts.first(where: { $0.name == table }) {
                    layouts.append(layout)
                }
            }
        }
        return layouts
    }

    private func globalQuickCheck(pageCount: Int64, pageSize: Int64) throws {
        guard let handle,
              let unsignedPageCount = UInt64(exactly: pageCount),
              let unsignedPageSize = UInt64(exactly: pageSize) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let (pageBytes, pageBytesOverflow) = unsignedPageCount
            .multipliedReportingOverflow(by: unsignedPageSize)
        let (scaledBudget, scaleOverflow) = pageBytes.multipliedReportingOverflow(by: 64)
        let (budget, budgetOverflow) = scaledBudget.addingReportingOverflow(1_000_000)
        guard !pageBytesOverflow, !scaleOverflow, !budgetOverflow else {
            throw ElysiumStorageError.schemaIntegrity
        }
        var callbackTicks = budget / 1_000
        if budget % 1_000 != 0 {
            let (incremented, overflow) = callbackTicks.addingReportingOverflow(1)
            guard !overflow else { throw ElysiumStorageError.schemaIntegrity }
            callbackTicks = incremented
        }

        var forceExhaustion = false
#if DEBUG
        forceExhaustion = factoryProbe?.kind == 3 && pageCount > 0
#endif
        let progress = StorageQuickCheckBudget(
            remainingTicks: forceExhaustion ? 0 : callbackTicks,
            exhausted: forceExhaustion)
        let progressPointer = Unmanaged.passUnretained(progress).toOpaque()
        sqlite3_progress_handler(handle, 1_000, storageQuickCheckProgressCallback, progressPointer)
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }

        do {
            try withRawStatement("PRAGMA main.quick_check(1)") { statement in
                let rc = sqlite3_step(statement)
                guard rc == SQLITE_ROW,
                      sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                      sqlite3_column_bytes(statement, 0) == 2,
                      let bytes = sqlite3_column_text(statement, 0),
                      bytes[0] == 0x6F, bytes[1] == 0x6B,
                      sqlite3_step(statement) == SQLITE_DONE,
                      !progress.exhausted else {
                    throw ElysiumStorageError.schemaIntegrity
                }
            }
        } catch {
            throw ElysiumStorageError.schemaIntegrity
        }
    }

    private func auditCoreTableLayouts(_ layouts: [StorageSchema.Layout]) throws {
        for layout in layouts {
            let observed: [StorageSchema.Column] = try withRawStatement(layout.pragma) { statement in
                var rows: [StorageSchema.Column] = []
                while true {
                    let rc = sqlite3_step(statement)
                    if rc == SQLITE_DONE { break }
                    guard rc == SQLITE_ROW,
                          sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                          sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
                          sqlite3_column_type(statement, 5) == SQLITE_INTEGER else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    let name = try copyRawText(statement, column: 1, maximumBytes: 65_536)
                    let type = try copyRawText(statement, column: 2, maximumBytes: 32)
                    let notNull = sqlite3_column_int(statement, 3) != 0
                    let defaultType = sqlite3_column_type(statement, 4)
                    let defaultValue: String?
                    if defaultType == SQLITE_NULL { defaultValue = nil }
                    else if defaultType == SQLITE_TEXT {
                        defaultValue = try copyRawText(statement, column: 4, maximumBytes: 1_024)
                    } else { throw ElysiumStorageError.schemaMismatch }
                    let primaryKey = Int(sqlite3_column_int(statement, 5))
                    rows.append(.init(name: name, type: type, notNull: notNull,
                                      defaultValue: defaultValue, primaryKey: primaryKey))
                }
                return rows
            }
            guard observed == layout.columns else { throw ElysiumStorageError.schemaMismatch }
            try auditTableFlags(layout)
            try auditPrimaryKeyIndex(layout)
            try auditNoForeignKeys(layout)
        }
    }

    private func normalizedSchemaSQL(_ sql: String) -> String {
        sql.lowercased()
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: "ifnotexists", with: "")
    }

    private func auditTableFlags(_ layout: StorageSchema.Layout) throws {
        try withRawStatement(layout.tableListPragma) { statement in
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_ROW,
                  sqlite3_column_type(statement, 1) == SQLITE_TEXT,
                  try copyRawText(statement, column: 1, maximumBytes: 65_536) == layout.name,
                  sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
                  sqlite3_column_int(statement, 3) == Int32(layout.columns.count),
                  sqlite3_column_type(statement, 4) == SQLITE_INTEGER,
                  sqlite3_column_int(statement, 4) == (layout.withoutRowID ? 1 : 0),
                  sqlite3_column_type(statement, 5) == SQLITE_INTEGER,
                  sqlite3_column_int(statement, 5) == 0,
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ElysiumStorageError.schemaMismatch
            }
        }
    }

    private func auditPrimaryKeyIndex(_ layout: StorageSchema.Layout) throws {
        try withRawStatement(layout.indexListPragma) { list in
            let rc = sqlite3_step(list)
            guard rc == SQLITE_ROW,
                  sqlite3_column_type(list, 0) == SQLITE_INTEGER, sqlite3_column_int(list, 0) == 0,
                  sqlite3_column_type(list, 1) == SQLITE_TEXT,
                  try copyRawText(list, column: 1, maximumBytes: 65_536) == layout.indexName,
                  sqlite3_column_type(list, 2) == SQLITE_INTEGER, sqlite3_column_int(list, 2) == 1,
                  sqlite3_column_type(list, 3) == SQLITE_TEXT,
                  try copyRawText(list, column: 3, maximumBytes: 16) == "pk",
                  sqlite3_column_type(list, 4) == SQLITE_INTEGER, sqlite3_column_int(list, 4) == 0,
                  sqlite3_step(list) == SQLITE_DONE else {
                throw ElysiumStorageError.schemaMismatch
            }
        }

        typealias IndexInfoRow = (sequence: Int, columnID: Int, name: String?, descending: Bool,
                                  collation: String, key: Bool)
        let rows: [IndexInfoRow] = try withRawStatement(layout.indexXInfoPragma) { xinfo in
            var values: [IndexInfoRow] = []
            while true {
                let xrc = sqlite3_step(xinfo)
                if xrc == SQLITE_DONE { break }
                guard xrc == SQLITE_ROW,
                      sqlite3_column_type(xinfo, 0) == SQLITE_INTEGER,
                      sqlite3_column_type(xinfo, 1) == SQLITE_INTEGER,
                      sqlite3_column_type(xinfo, 3) == SQLITE_INTEGER,
                      sqlite3_column_type(xinfo, 4) == SQLITE_TEXT,
                      sqlite3_column_type(xinfo, 5) == SQLITE_INTEGER else {
                    throw ElysiumStorageError.schemaMismatch
                }
                let name: String?
                if sqlite3_column_type(xinfo, 2) == SQLITE_NULL { name = nil }
                else { name = try copyRawText(xinfo, column: 2, maximumBytes: 65_536) }
                let collation = try copyRawText(xinfo, column: 4, maximumBytes: 32)
                values.append((Int(sqlite3_column_int(xinfo, 0)),
                               Int(sqlite3_column_int(xinfo, 1)), name,
                               sqlite3_column_int(xinfo, 3) != 0, collation,
                               sqlite3_column_int(xinfo, 5) != 0))
            }
            return values
        }
        let expectedKeyNames = layout.columns.filter { $0.primaryKey > 0 }
            .sorted { $0.primaryKey < $1.primaryKey }.map(\.name)
        let actualKeyNames = rows.filter(\.key).compactMap(\.name)
        guard actualKeyNames == expectedKeyNames else { throw ElysiumStorageError.schemaMismatch }
        if layout.withoutRowID {
            guard rows.count == layout.columns.count else { throw ElysiumStorageError.schemaMismatch }
            for (index, row) in rows.enumerated() {
                let expected = layout.columns[index]
                guard row.sequence == index, row.columnID == index, row.name == expected.name,
                      !row.descending, row.collation == "BINARY",
                      row.key == (expected.primaryKey > 0) else {
                    throw ElysiumStorageError.schemaMismatch
                }
            }
        } else {
            guard rows.count == expectedKeyNames.count + 1,
                  rows.last?.sequence == expectedKeyNames.count,
                  rows.last?.columnID == -1,
                  rows.last?.name == nil, rows.last?.descending == false,
                  rows.last?.collation == "BINARY", rows.last?.key == false else {
                throw ElysiumStorageError.schemaMismatch
            }
            for (index, name) in expectedKeyNames.enumerated() {
                guard rows[index].sequence == index,
                      rows[index].columnID == layout.columns.firstIndex(where: { $0.name == name }),
                      rows[index].name == name, !rows[index].descending,
                      rows[index].collation == "BINARY", rows[index].key else {
                    throw ElysiumStorageError.schemaMismatch
                }
            }
        }
    }

    private func auditNoForeignKeys(_ layout: StorageSchema.Layout) throws {
        try withRawStatement(layout.foreignKeyPragma) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw ElysiumStorageError.schemaMismatch
            }
        }
    }

    private func withAuthorization<T>(_ scope: StorageAuthorizationScope,
                                      _ body: () throws -> T) throws -> T {
        precondition(isOnQueue)
        let prior = authorizer.scope
        let priorDenied = authorizer.denied
        guard authorizationTransitionAllowed(from: prior, to: scope) else {
            throw ElysiumStorageError.capabilityViolation
        }
#if DEBUG
        switch (prior, scope) {
        case (.denyAll, .configuration): authorizationTransitionCoverage |= 1 << 0
        case (.denyAll, .schemaAudit): authorizationTransitionCoverage |= 1 << 1
        case (.denyAll, .coreBootstrap): authorizationTransitionCoverage |= 1 << 2
        case (.coreBootstrap, .schemaAudit): authorizationTransitionCoverage |= 1 << 3
        case let (from, to) where from == to: authorizationTransitionCoverage |= 1 << 4
        default: break
        }
#endif
        authorizer.scope = scope
        authorizer.denied = false
        defer {
            authorizer.scope = prior
            authorizer.denied = priorDenied
        }
        do {
            let value = try body()
            guard !authorizer.denied else { throw ElysiumStorageError.capabilityViolation }
            return value
        } catch {
            if authorizer.denied { throw ElysiumStorageError.capabilityViolation }
            throw error
        }
    }

    private func authorizationTransitionAllowed(from: StorageAuthorizationScope,
                                                to: StorageAuthorizationScope) -> Bool {
        if from == to { return true }
        switch (from, to) {
        case (.denyAll, .configuration), (.denyAll, .coreBootstrap):
            guard case .opening = lifecycle else { return false }
            return true
        case (.denyAll, .schemaAudit):
            switch lifecycle {
            case .opening, .open: return true
            case .closing, .poisoned, .closed: return false
            }
        case (.coreBootstrap, .schemaAudit):
            guard case .opening = lifecycle else { return false }
            return transactionActive
        default:
            return false
        }
    }

    private func admitted<T>(_ body: () throws -> T) throws -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        switch lifecycle {
        case .open: break
        case .poisoned: throw ElysiumStorageError.poisoned
        case .opening, .closing, .closed: throw ElysiumStorageError.closed
        }
        if isOnQueue { return try body() }
        return try queue.sync { try body() }
    }

    fileprivate func read<T>(tables: Set<String>, _ body: (StorageContext) throws -> T) throws -> T {
        let scope = StorageAuthorizationScope.coreRead(tables)
        if isOnQueue { return try runContext(scope: scope, body) }
        return try admitted { try runContext(scope: scope, body) }
    }

    fileprivate func mutate<T>(table: String, _ body: (StorageContext) throws -> T) throws -> T {
        let scope = StorageAuthorizationScope.coreMutation(table: table)
        if isOnQueue { return try runImmediateTransaction(scope: scope, body) }
        return try admitted { try runImmediateTransaction(scope: scope, body) }
    }

    fileprivate func mutate<T>(tables: Set<String>, _ body: (StorageContext) throws -> T) throws -> T {
        let scope = StorageAuthorizationScope.coreMultiMutation(tables)
        if isOnQueue { return try runImmediateTransaction(scope: scope, body) }
        return try admitted { try runImmediateTransaction(scope: scope, body) }
    }

    fileprivate func rpgLocalPreferencesRead<T>(
        _ body: (StorageContext) throws -> T
    ) throws -> T {
        if isOnQueue { return try runContext(scope: .rpgLocalPreferencesReadV1, body) }
        return try admitted { try runContext(scope: .rpgLocalPreferencesReadV1, body) }
    }

    fileprivate func rpgLocalPreferencesWrite<T>(
        _ body: (StorageContext) throws -> T
    ) throws -> T {
        if isOnQueue {
            return try runImmediateTransaction(scope: .rpgLocalPreferencesWriteV1, body)
        }
        return try admitted {
            try runImmediateTransaction(scope: .rpgLocalPreferencesWriteV1, body)
        }
    }

    fileprivate func playerJSONCompareAndSwap<T>(
        _ body: (StorageContext) throws -> T
    ) throws -> T {
        if isOnQueue {
            return try runImmediateTransaction(scope: .playerJSONCompareAndSwapV1, body)
        }
        return try admitted {
            try runImmediateTransaction(scope: .playerJSONCompareAndSwapV1, body)
        }
    }

#if DEBUG
    fileprivate func testRPGLocalPreferencesWrite<T>(
        operation: ElysiumStorageRPGLocalTestOperation,
        _ body: (StorageContext) throws -> T
    ) throws -> T {
        try admitted {
            try withActiveRPGLocalTestOperation(operation) {
                try runImmediateTransaction(
                    scope: .rpgLocalPreferencesWriteV1, body)
            }
        }
    }
#endif

    fileprivate func rpgLocalPreferencesLegacyMaterialization<T>(
        _ body: (StorageContext) throws -> T
    ) throws -> T {
#if DEBUG
        try testRPGLocalPreferencesWrite(operation: .legacyMaterialization, body)
#else
        try rpgLocalPreferencesWrite(body)
#endif
    }

    fileprivate func coreWorldDeleteWithRPG<T>(
        _ body: (StorageContext) throws -> T
    ) throws -> T {
        if isOnQueue {
            return try runImmediateTransaction(scope: .coreWorldDeleteWithRPGV1, body)
        }
        return try admitted {
            try runImmediateTransaction(scope: .coreWorldDeleteWithRPGV1, body)
        }
    }

#if DEBUG
    fileprivate func testCoreWorldDeleteWithRPG<T>(
        operation: ElysiumStorageRPGLocalTestOperation,
        _ body: (StorageContext) throws -> T
    ) throws -> T {
        try admitted {
            try withActiveRPGLocalTestOperation(operation) {
                try runImmediateTransaction(scope: .coreWorldDeleteWithRPGV1, body)
            }
        }
    }
#endif

    fileprivate func coreWorldDeleteWithRPGAtomic<T>(
        _ body: (StorageContext) throws -> T
    ) throws -> T {
#if DEBUG
        try testCoreWorldDeleteWithRPG(operation: .worldDelete, body)
#else
        try coreWorldDeleteWithRPG(body)
#endif
    }

    fileprivate func clientAuthorityRead<T>(
        _ body: (StorageContext) throws -> T
    ) throws -> T {
        if isOnQueue { return try runContext(scope: .lanClientAuthorityCheckpointV6, body) }
        return try admitted { try runContext(scope: .lanClientAuthorityCheckpointV6, body) }
    }

    fileprivate func clientAuthorityWrite<T>(
        _ body: (StorageContext) throws -> T
    ) throws -> T {
        if isOnQueue {
            return try runImmediateTransaction(scope: .lanClientAuthorityCheckpointV6, body)
        }
        return try admitted {
            try runImmediateTransaction(scope: .lanClientAuthorityCheckpointV6, body)
        }
    }

    fileprivate func clientNoticeAcknowledgement<T>(
        _ body: (StorageContext) throws -> T
    ) throws -> T {
        if isOnQueue {
            return try runImmediateTransaction(scope: .lanClientNoticeAcknowledgementV6, body)
        }
        return try admitted {
            try runImmediateTransaction(scope: .lanClientNoticeAcknowledgementV6, body)
        }
    }

    fileprivate func legacyWorldCollection<T>(_ body: (StorageContext) throws -> T) throws -> T {
        try legacyCollection(scope: .legacyWorldCollection, body)
    }

    fileprivate func legacyTemplateCollection<T>(_ body: (StorageContext) throws -> T) throws -> T {
        try legacyCollection(scope: .legacyTemplateCollection, body)
    }

    fileprivate func legacyLANPlayerCollection<T>(_ body: (StorageContext) throws -> T) throws -> T {
        try legacyCollection(scope: .legacyLANPlayerCollection, body)
    }

    fileprivate func legacyChunkKeyCollection<T>(_ body: (StorageContext) throws -> T) throws -> T {
        try legacyCollection(scope: .legacyChunkKeyCollection, body)
    }

    private func legacyCollection<T>(scope: StorageAuthorizationScope,
                                     _ body: (StorageContext) throws -> T) throws -> T {
        if isOnQueue { return try runLegacyCollectionOnQueue(scope: scope, body) }
        return try admitted { try runLegacyCollectionOnQueue(scope: scope, body) }
    }

    private func runLegacyCollectionOnQueue<T>(scope: StorageAuthorizationScope,
                                               _ body: (StorageContext) throws -> T) throws -> T {
        guard authorizer.scope == .denyAll, !authorizer.denied,
              currentContext == nil, !transactionActive else {
            throw ElysiumStorageError.capabilityViolation
        }
        return try runContext(scope: scope, body)
    }

    fileprivate func verifyCoreSchema() throws {
        try admitted { try schemaVerificationSnapshot() }
    }

    private func schemaVerificationSnapshot() throws {
        precondition(isOnQueue)
        guard authorizer.scope == .denyAll, !authorizer.denied,
              currentContext == nil, !transactionActive,
              let handle, sqlite3_get_autocommit(handle) != 0 else {
            throw ElysiumStorageError.capabilityViolation
        }
        do {
            try executeTransactionControl("BEGIN", operation: .beginImmediate)
            transactionActive = true
            try withAuthorization(.schemaAudit) {
                try auditCoreSchema(mode: .exactReady, runGlobalQuickCheck: true)
            }
            try executeTransactionControl("COMMIT", operation: .commit)
            transactionActive = false
            guard sqlite3_get_autocommit(handle) != 0 else {
                throw ElysiumStorageError.transactionStillOpen
            }
        } catch {
            let failure = recoverTransactionFailure(primary: error)
            transactionActive = false
            throw failure
        }
    }

    fileprivate func ensureOpen() throws {
        try admitted { () }
    }

    fileprivate func ensureRPGLocalPreferencesSchema() throws {
        try admitted {
            guard authorizer.scope == .denyAll, !authorizer.denied,
                  currentContext == nil, !transactionActive else {
                throw ElysiumStorageError.capabilityViolation
            }
            let installed = try withAuthorization(.schemaAudit) {
                try withRawStatement("""
                    SELECT count(*) FROM sqlite_master
                    WHERE type='table' AND name IN (
                      'pebble_storage_component_schema_v1',
                      'rpg_local_preferences_v1',
                      'rpg_local_preference_migrations_v1')
                    """) { statement in
                    guard sqlite3_step(statement) == SQLITE_ROW,
                          sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    let count = sqlite3_column_int(statement, 0)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    guard count == 0 || count == 3 else {
                        throw ElysiumStorageError.schemaIntegrity
                    }
                    return count == 3
                }
            }
            if !installed {
                _ = try runImmediateTransaction(scope: .rpgLocalPreferencesBootstrap) { context in
                    for sql in StorageSchema.rpgLocalCreateStatements {
                        let statement = try context.prepare(sql)
                        guard try statement.step() == .done else {
                            throw ElysiumStorageError.schemaIntegrity
                        }
                        try statement.finalize()
                    }
                    let marker = try context.prepare("""
                        INSERT INTO pebble_storage_component_schema_v1(
                          component,revision,manifest_digest) VALUES('rpgLocalPreferences',1,?)
                        """)
                    try marker.bindData(1, StorageSchema.rpgLocalManifestDigest)
                    guard try marker.step() == .done else { throw ElysiumStorageError.schemaIntegrity }
                    try marker.finalize()
                }
            }
            try withAuthorization(.schemaAudit) {
                try auditCoreSchema(mode: .exactReady, runGlobalQuickCheck: false)
                try verifyRPGLocalComponentMarker()
            }
        }
    }

    /// Recovery is classification-only. Unlike ordinary RPG-local admission,
    /// this audit never bootstraps a missing component or opens a transaction;
    /// absent, partial, or corrupt schema leaves the retained authority
    /// unresolved and unchanged.
    fileprivate func verifyRPGLocalPreferencesSchemaForRecovery() throws {
        try admitted {
            guard authorizer.scope == .denyAll, !authorizer.denied,
                  currentContext == nil, !transactionActive else {
                throw ElysiumStorageError.capabilityViolation
            }
            try withAuthorization(.schemaAudit) {
                let objects: Set<String> = try withRawStatement("""
                    SELECT name FROM sqlite_master
                    WHERE type='table' AND name IN (
                      'pebble_storage_component_schema_v1',
                      'rpg_local_preferences_v1',
                      'rpg_local_preference_migrations_v1')
                    ORDER BY name
                    """) { statement in
                    var observed = Set<String>()
                    while true {
                        let rc = sqlite3_step(statement)
                        if rc == SQLITE_DONE { break }
                        guard rc == SQLITE_ROW else {
                            throw ElysiumStorageError.schemaIntegrity
                        }
                        let name = try copyRawText(
                            statement, column: 0, maximumBytes: 64)
                        guard observed.insert(name).inserted else {
                            throw ElysiumStorageError.schemaIntegrity
                        }
                    }
                    return observed
                }
                guard objects == StorageSchema.rpgLocalTables else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                try auditCoreSchema(mode: .exactReady, runGlobalQuickCheck: false)
                try verifyRPGLocalComponentMarker()
            }
        }
    }

    fileprivate func bootstrapClientAuthoritySchemaForAdmission() throws {
        try ensureRPGLocalPreferencesSchema()
        try admitted {
            guard authorizer.scope == .denyAll, !authorizer.denied,
                  currentContext == nil, !transactionActive else {
                throw ElysiumStorageError.capabilityViolation
            }
            let objectCount = try withAuthorization(.schemaAudit) {
                try withRawStatement("""
                    SELECT count(*) FROM sqlite_master WHERE
                      (type='table' AND name IN (
                        'lan_client_credentials_v6','lan_client_owner_checkpoint_v6',
                        'lan_client_pending_disposition_v6','lan_client_notification_inbox_v6'))
                      OR (type='index' AND name='lan_client_notification_inbox_v6_render_order')
                    """) { statement in
                    guard sqlite3_step(statement) == SQLITE_ROW,
                          sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    let count = sqlite3_column_int(statement, 0)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    return count
                }
            }
            guard objectCount == 0 || objectCount == 5 else {
                throw ElysiumStorageError.schemaIntegrity
            }
            if objectCount == 0 {
                _ = try runImmediateTransaction(scope: .lanClientAuthorityBootstrap) { context in
                    for sql in StorageSchema.clientCreateStatements {
                        let statement = try context.prepare(sql)
                        guard try statement.step() == .done else {
                            throw ElysiumStorageError.schemaIntegrity
                        }
                        try statement.finalize()
                    }
                    let marker = try context.prepare("""
                        INSERT INTO pebble_storage_component_schema_v1(
                          component,revision,manifest_digest) VALUES('lanClientAuthority',1,?)
                        """)
                    try marker.bindData(1, StorageSchema.clientManifestDigest)
                    guard try marker.step() == .done else {
                        throw ElysiumStorageError.schemaIntegrity
                    }
                    try marker.finalize()
                }
            }
            try withAuthorization(.schemaAudit) {
                try auditCoreSchema(mode: .exactReady, runGlobalQuickCheck: false)
                try verifyClientComponentMarker()
            }
        }
    }

    fileprivate func verifyClientAuthoritySchemaInstalled() throws {
        try admitted {
            guard authorizer.scope == .denyAll, !authorizer.denied,
                  currentContext == nil, !transactionActive else {
                throw ElysiumStorageError.capabilityViolation
            }
            let objectCount = try withAuthorization(.schemaAudit) {
                try withRawStatement("""
                    SELECT count(*) FROM sqlite_master WHERE
                      (type='table' AND name IN (
                        'lan_client_credentials_v6','lan_client_owner_checkpoint_v6',
                        'lan_client_pending_disposition_v6','lan_client_notification_inbox_v6'))
                      OR (type='index' AND name='lan_client_notification_inbox_v6_render_order')
                    """) { statement in
                    guard sqlite3_step(statement) == SQLITE_ROW,
                          sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                        throw ElysiumStorageError.schemaIntegrity
                    }
                    let count = sqlite3_column_int(statement, 0)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw ElysiumStorageError.schemaIntegrity
                    }
                    return count
                }
            }
            guard objectCount == 5 else { throw ElysiumStorageError.invalidValue }
            try withAuthorization(.schemaAudit) {
                try auditCoreSchema(mode: .exactReady, runGlobalQuickCheck: false)
                try verifyClientComponentMarker()
            }
        }
    }

    private func verifyRPGLocalComponentMarker() throws {
        try withRawStatement("""
            SELECT revision,manifest_digest FROM pebble_storage_component_schema_v1
            WHERE component='rpgLocalPreferences'
            """) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 0) == 1,
                  sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                  sqlite3_column_bytes(statement, 1) == 32,
                  let bytes = sqlite3_column_blob(statement, 1) else {
                throw ElysiumStorageError.schemaIntegrity
            }
            let digest = Data(bytes: bytes, count: 32)
            guard storageFixedTimeEqual(digest, StorageSchema.rpgLocalManifestDigest),
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ElysiumStorageError.schemaIntegrity
            }
        }
    }

    private func verifyClientComponentMarker() throws {
        try withRawStatement("""
            SELECT revision,manifest_digest FROM pebble_storage_component_schema_v1
            WHERE component='lanClientAuthority'
            """) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 0) == 1,
                  sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                  sqlite3_column_bytes(statement, 1) == 32,
                  let bytes = sqlite3_column_blob(statement, 1),
                  storageFixedTimeEqual(Data(bytes: bytes, count: 32),
                                        StorageSchema.clientManifestDigest),
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw ElysiumStorageError.schemaIntegrity
            }
        }
    }

    fileprivate func verifyDatabaseParentIdentity(device: UInt64, inode: UInt64) throws {
        try admitted {
            let retained = try verifyRetainedIdentityOrPoison()
            guard retained.deviceBitPattern == device,
                  UInt64(retained.inode) == inode else {
                throw ElysiumStorageError.invalidValue
            }
        }
    }

    fileprivate func prepareLegacyMigrationRename() throws {
        if isOnQueue { return try prepareLegacyMigrationRenameOnQueue() }
        try admitted { try prepareLegacyMigrationRenameOnQueue() }
    }

    private func prepareLegacyMigrationRenameOnQueue() throws {
        precondition(isOnQueue)
        guard authorizer.scope == .denyAll, !authorizer.denied,
              currentContext == nil, !transactionActive,
              let handle, sqlite3_get_autocommit(handle) != 0 else {
            throw ElysiumStorageError.capabilityViolation
        }
        guard sqlite3_next_stmt(handle, nil) == nil else {
            throw ElysiumStorageError.statementLeak
        }
        _ = try verifyRetainedIdentityOrPoison()

#if DEBUG
        if consumeBarrierFailure(.checkpointBusy) {
            throw storageSQLiteError(SQLITE_BUSY, operation: .checkpoint)
        }
#endif
        var logFrames: Int32 = -1
        var checkpointedFrames: Int32 = -1
        let checkpointRC = sqlite3_wal_checkpoint_v2(
            handle, "main", SQLITE_CHECKPOINT_FULL, &logFrames, &checkpointedFrames)
        guard checkpointRC == SQLITE_OK else {
            throw sqliteError(.checkpoint, code: checkpointRC)
        }
#if DEBUG
        if consumeBarrierFailure(.checkpointRemainingFrames) {
            logFrames = max(logFrames, 1)
            checkpointedFrames = 0
        }
#endif
        guard logFrames >= 0, checkpointedFrames >= 0,
              logFrames == checkpointedFrames else {
            throw storageSQLiteError(SQLITE_BUSY, operation: .checkpoint)
        }

#if DEBUG
        if consumeBarrierFailure(.durabilitySyncFailure) {
            throw storageSQLiteError(EIO, operation: .durabilitySync)
        }
#endif
        while true {
            let syncRC = Darwin.fcntl(lease.descriptor, F_FULLFSYNC)
            if syncRC == 0 { break }
            let code = Int32(errno)
            if code == EINTR { continue }
            throw storageSQLiteError(code, operation: .durabilitySync)
        }
        var stageFailure: (any Error)?
#if DEBUG
        do {
            try observeTestStage(.afterDurabilitySyncBeforeIdentityProof)
        } catch {
            stageFailure = error
        }
#endif
        _ = try verifyRetainedIdentityOrPoison()
        if let stageFailure { throw stageFailure }
    }

    private func verifyRetainedIdentityOrPoison() throws -> StorageFileIdentity {
        precondition(isOnQueue)
        do {
            return try lease.verifiedParentIdentity()
        } catch {
            poisonOnQueue()
            throw error
        }
    }

    private func runContext<T>(scope: StorageAuthorizationScope,
                               _ body: (StorageContext) throws -> T) throws -> T {
        precondition(isOnQueue)
        if let currentContext {
            guard currentContext.scope == scope else { throw ElysiumStorageError.capabilityViolation }
            try currentContext.validate()
            return try body(currentContext)
        }

        try advanceAuthorizationGeneration()
        let context = StorageContext(executor: self,
                                     executorGeneration: executorGeneration,
                                     authorizationGeneration: authorizationGeneration,
                                     scope: scope)
        currentContext = context
        let priorScope = authorizer.scope
        let priorDenied = authorizer.denied
        authorizer.scope = scope
        authorizer.denied = false

        var value: T?
        var primary: (any Error)?
        do {
            value = try body(context)
            if let latched = context.firstFailure { throw latched }
        } catch {
            if error is ElysiumStorageStatementFailure { primary = error }
            else { primary = context.firstFailure ?? error }
        }

        if let cleanupFailure = context.invalidateAndFinalizeLeaks(), primary == nil {
            primary = cleanupFailure
        }
        currentContext = nil
        authorizer.scope = priorScope
        authorizer.denied = priorDenied
        try advanceAuthorizationGeneration()

        if let primary { throw primary }
        guard let value else { throw ElysiumStorageError.invalidValue }
        return value
    }

    private func runImmediateTransaction<T>(scope: StorageAuthorizationScope,
                                            _ body: (StorageContext) throws -> T) throws -> T {
        precondition(isOnQueue)
        guard currentContext == nil, !transactionActive else {
            throw ElysiumStorageError.nestedTransaction
        }
#if DEBUG
        try injectActiveRPGLocalFailure(.begin)
#endif
        do {
            try executeTransactionControl("BEGIN IMMEDIATE", operation: .beginImmediate)
        } catch {
            throw recoverTransactionFailure(primary: error)
        }
        transactionActive = true

        var value: T?
        var primary: (any Error)?
        do {
            value = try runContext(scope: scope, body)
#if DEBUG
            try injectActiveRPGLocalFailure(.commit)
#endif
            try executeTransactionControl("COMMIT", operation: .commit)
            transactionActive = false
            guard let handle, sqlite3_get_autocommit(handle) != 0 else {
                throw ElysiumStorageError.transactionStillOpen
            }
        } catch {
            primary = error
        }

        if let primary {
            transactionActive = false
            throw recoverTransactionFailure(primary: primary)
        }
        guard let value else { throw ElysiumStorageError.invalidValue }
        return value
    }

    private func executeTransactionControl(_ sql: StaticString,
                                           operation: ElysiumStorageOperationID) throws {
        precondition(isOnQueue)
        let priorScope = authorizer.scope
        let priorDenied = authorizer.denied
        authorizer.scope = .transactionControl
        authorizer.denied = false
        defer {
            authorizer.scope = priorScope
            authorizer.denied = priorDenied
        }
        try injectIfRequested(operation)
        try withRawStatement(sql, operation: operation) { statement in
            let stepRC = sqlite3_step(statement)
            guard stepRC == SQLITE_DONE else { throw sqliteError(operation, code: stepRC) }
        }
    }

    private func poisonOnQueue() {
        precondition(isOnQueue)
        executorGeneration = .max
        authorizationGeneration = .max
        currentContext?.active = false
        _ = currentContext?.invalidateAndFinalizeLeaks()
        currentContext = nil
        lifecycle = .poisoned
        terminalClose(tombstone: true)
    }

    private func advanceAuthorizationGeneration() throws {
        guard authorizationGeneration < UInt64.max else {
            poisonOnQueue()
            throw ElysiumStorageError.poisoned
        }
        authorizationGeneration += 1
    }

    private func recoverTransactionFailure(primary: any Error) -> ElysiumStorageTransactionFailure {
        var rollbackFailure: ElysiumStorageError?
        var terminalFailure: ElysiumStorageError?
        if let handle, sqlite3_get_autocommit(handle) == 0 {
            do {
                try executeTransactionControl("ROLLBACK", operation: .rollback)
            } catch let error as ElysiumStorageError {
                rollbackFailure = error
            } catch {
                rollbackFailure = storageSQLiteError(SQLITE_ERROR, operation: .rollback)
            }
        }
        if let handle, sqlite3_get_autocommit(handle) == 0 {
            terminalFailure = .transactionStillOpen
            poisonOnQueue()
        }
        return ElysiumStorageTransactionFailure(primary: primary,
                                               rollback: rollbackFailure,
                                               terminal: terminalFailure)
    }

#if DEBUG
    fileprivate func testInject(_ operation: ElysiumStorageOperationID, count: Int) throws {
        guard count > 0 else { throw ElysiumStorageError.invalidValue }
        try admitted { injectedFailures[operation] = count }
    }

    fileprivate func testSetRPGLocalFailure(
        operation: ElysiumStorageRPGLocalTestOperation,
        stage: ElysiumStorageRPGLocalFailureStage
    ) throws {
        switch stage {
        case let .prepare(statement), let .bind(statement), let .step(statement),
             let .changes(statement), let .finalize(statement):
            guard statement >= 0 else { throw ElysiumStorageError.invalidValue }
        case let .reset(statement, requestIndex),
             let .clearBindings(statement, requestIndex):
            guard statement >= 0, requestIndex >= 0 else {
                throw ElysiumStorageError.invalidValue
            }
        case let .afterCommitAuthorityMutation(worldID):
            try StorageBounds.validateIdentifier(
                worldID, maximumBytes: StorageBounds.worldBrowserIDBytes)
        case .begin, .postcondition, .commit, .afterCommitBeforePublication:
            break
        }
        try admitted {
            guard rpgLocalFailurePoint == nil,
                  activeRPGLocalTestOperation == nil else {
                throw ElysiumStorageError.invalidValue
            }
            rpgLocalFailurePoint = (operation, stage)
        }
    }

    fileprivate func injectActiveRPGLocalFailure(
        _ stage: ElysiumStorageRPGLocalFailureStage
    ) throws {
        precondition(isOnQueue)
        guard let activeRPGLocalTestOperation,
              let point = rpgLocalFailurePoint,
              point.operation == activeRPGLocalTestOperation,
              point.stage == stage else { return }
        rpgLocalFailurePoint = nil
        throw ElysiumStorageError.invalidValue
    }

    private func consumeAfterCommitAuthorityMutation() -> String? {
        precondition(isOnQueue)
        guard let activeRPGLocalTestOperation,
              activeRPGLocalTestOperation == .worldDelete,
              let point = rpgLocalFailurePoint,
              point.operation == .worldDelete,
              case .afterCommitAuthorityMutation(let worldID) = point.stage else {
            return nil
        }
        rpgLocalFailurePoint = nil
        return worldID
    }

    private func testMutateWorldAuthorityAfterCommit(worldID: String) throws {
        try runImmediateTransaction(scope: .coreMutation(table: "worlds")) { context in
            let statement = try context.prepare(
                "UPDATE worlds SET lastPlayed=9007199254740991.0 WHERE id=?")
            defer { try? statement.finalize() }
            try statement.bindText(1, worldID)
            guard try statement.step() == .done, try context.changes() == 1 else {
                throw ElysiumStorageError.invalidValue
            }
        }
    }

    private func withActiveRPGLocalTestOperation<T>(
        _ operation: ElysiumStorageRPGLocalTestOperation,
        _ body: () throws -> T
    ) throws -> T {
        precondition(isOnQueue)
        guard activeRPGLocalTestOperation == nil else {
            throw ElysiumStorageError.invalidValue
        }
        activeRPGLocalTestOperation = operation
        defer {
            activeRPGLocalTestOperation = nil
            rpgLocalFailurePoint = nil
        }
        let value = try body()
        try injectActiveRPGLocalFailure(.afterCommitBeforePublication)
        if let worldID = consumeAfterCommitAuthorityMutation() {
            try testMutateWorldAuthorityAfterCommit(worldID: worldID)
            throw ElysiumStorageError.invalidValue
        }
        return value
    }

    fileprivate func testSetLegacyCollectionFailure(
        _ point: ElysiumStorageLegacyCollectionFailurePoint
    ) throws {
        try admitted { legacyCollectionFailurePoint = point }
    }

    fileprivate func consumeLegacyCollectionFailure(
        _ point: ElysiumStorageLegacyCollectionFailurePoint
    ) -> Bool {
        precondition(isOnQueue)
        guard legacyCollectionFailurePoint == point else { return false }
        legacyCollectionFailurePoint = nil
        return true
    }

    fileprivate func testSetLegacyImportFailure(
        _ point: ElysiumStorageLegacyImportFailurePoint
    ) throws {
        try admitted {
            if point == .commit { injectedFailures[.commit] = 1 }
            else {
                switch point {
                case .deleteWorlds: legacyImportFailurePoint = .deleteWorlds
                case .deleteChunks: legacyImportFailurePoint = .deleteChunks
                case .deletePlayer: legacyImportFailurePoint = .deletePlayer
                case .deleteAdvancements: legacyImportFailurePoint = .deleteAdvancements
                case .insertWorld: legacyImportFailurePoint = .insertWorld
                case .insertPlayer: legacyImportFailurePoint = .insertPlayer
                case .insertAdvancement: legacyImportFailurePoint = .insertAdvancement
                case .insertFirstChunk: legacyImportFailurePoint = .insertFirstChunk
                case .insertMiddleChunk: legacyImportFailurePoint = .insertMiddleChunk
                case .insertLastChunk: legacyImportFailurePoint = .insertLastChunk
                case .commit: break
                }
            }
        }
    }

    fileprivate func consumeLegacyImportFailure(
        _ point: StorageLegacyImportFailurePoint
    ) -> Bool {
        precondition(isOnQueue)
        guard legacyImportFailurePoint == point else { return false }
        legacyImportFailurePoint = nil
        return true
    }

    fileprivate func testSetBarrierFailure(_ point: ElysiumStorageBarrierFailurePoint) throws {
        try admitted { barrierFailurePoint = point }
    }

    fileprivate func testArmStage(_ stage: ElysiumStorageTestStage) throws
        -> ElysiumStorageTestLatch {
        try admitted {
            if let activeTestStage {
                guard activeTestStage.latch.isReapable else {
                    throw ElysiumStorageError.invalidValue
                }
                self.activeTestStage = nil
            }
            let latch = ElysiumStorageTestLatch()
            activeTestStage = (stage, latch)
            return latch
        }
    }

    fileprivate func observeTestStage(_ stage: ElysiumStorageTestStage) throws {
        precondition(isOnQueue)
        guard let active = activeTestStage, active.stage == stage else { return }
        defer {
            if activeTestStage?.latch === active.latch { activeTestStage = nil }
        }
        try active.latch.executorReachAndWait()
    }

    fileprivate func consumeBarrierFailure(_ point: ElysiumStorageBarrierFailurePoint) -> Bool {
        precondition(isOnQueue)
        guard barrierFailurePoint == point else { return false }
        barrierFailurePoint = nil
        return true
    }

    fileprivate func testAutocommit() throws -> Bool {
        try admitted {
            guard let handle else { throw ElysiumStorageError.closed }
            return sqlite3_get_autocommit(handle) != 0
        }
    }

    fileprivate func testForeignKeysEnabled() throws -> Bool {
        try admitted { configurationVerified }
    }

    fileprivate func testPhysicalIdentityBound() throws -> Bool {
        try admitted {
            try lease.verifySQLiteDescriptorStillBound()
            return true
        }
    }

    fileprivate func testSameScopeReentry() throws -> Bool {
        try admitted {
            try runContext(scope: .coreRead(["worlds"])) { outer in
                try runContext(scope: .coreRead(["worlds"])) { inner in outer === inner }
            }
        }
    }

    fileprivate func testEscapedStatementRejects() throws -> ElysiumStorageError {
        var escaped: StorageStatement?
        do {
            _ = try admitted {
                try runContext(scope: .coreRead(["worlds"])) { context in
                    escaped = try context.prepare("SELECT id FROM worlds ORDER BY id LIMIT 1")
                }
            }
        } catch ElysiumStorageError.statementLeak {
            // Expected: the scope force-finalized and invalidated the escaped value.
        }
        do {
            _ = try escaped?.step()
            throw ElysiumStorageError.invalidValue
        } catch let error as ElysiumStorageError {
            return error
        }
    }

    fileprivate func testReadScopeWriteProbe() throws {
        try admitted {
            try runContext(scope: .coreRead(["worlds"])) { context in
                _ = try context.prepare("DELETE FROM worlds")
            }
        }
    }

    fileprivate func testLegacyWorldScopeDeniedProbe() throws {
        _ = try legacyWorldCollection { context in
            _ = try context.prepare("SELECT count(*) FROM templates")
        }
    }

    fileprivate func testLegacyTemplateScopeDeniedProbe() throws {
        _ = try legacyTemplateCollection { context in
            _ = try context.prepare("SELECT count(*) FROM worlds")
        }
    }

    fileprivate func testLegacyLANScopeDeniedProbe() throws {
        _ = try legacyLANPlayerCollection { context in
            _ = try context.prepare("SELECT count(*) FROM worlds")
        }
    }

    fileprivate func testCrossTableMutationProbe() throws {
        _ = try admitted {
            try runImmediateTransaction(scope: .coreMutation(table: "worlds")) { context in
                try executeMutation(context, "DELETE FROM player") { _ in }
            }
        }
    }

    fileprivate func testBootstrapAfterReadinessProbe() throws {
        try admitted { try withAuthorization(.coreBootstrap) {} }
    }

    fileprivate func testNestedTransactionProbe() throws {
        _ = try admitted {
            try runImmediateTransaction(scope: .coreMutation(table: "worlds")) { _ in
                try runImmediateTransaction(scope: .coreMutation(table: "worlds")) { _ in () }
            }
        }
    }

    fileprivate func testCaughtBindFailureCannotCommit(_ row: ElysiumWorldStorageRow) throws {
        try testInject(.bind, count: 1)
        _ = try mutate(table: "worlds") { context in
            do {
                _ = try executeMutation(context, """
                    INSERT OR REPLACE INTO worlds(id,json,lastPlayed) VALUES(?,?,?)
                    """) {
                    try $0.bindText(1, row.id)
                    try $0.bindText(2, row.json)
                    try $0.bindDouble(3, row.lastPlayed)
                }
            } catch { /* the context latch must still force rollback */ }
        }
    }

    fileprivate func testForceAuthorizationGenerationBoundary() throws {
        try admitted { authorizationGeneration = .max }
        _ = try read(tables: ["worlds"]) { _ in () }
    }

    fileprivate func testLeakRawStatementForClose() throws {
        try admitted {
            _ = try runContext(scope: .coreRead(["worlds"])) { _ in
                testLeakedRawStatement = try prepareRaw("SELECT id FROM worlds", operation: .prepare)
            }
        }
    }

    fileprivate func testBodyAndFinalizeFailure() throws {
        try testInject(.finalize, count: 1)
        _ = try read(tables: ["worlds"]) { context in
            try withStatement(context, "SELECT id FROM worlds ORDER BY id LIMIT 1") { _ in
                throw ElysiumStorageTestBodyError.expected
            }
        }
    }

    fileprivate func testAuthorizationContract() throws -> UInt8 {
        try admitted {
            let generationBefore = authorizationGeneration
            guard authorizer.scope == .denyAll else { throw ElysiumStorageError.invalidValue }

            try withAuthorization(.schemaAudit) {
                try withAuthorization(.schemaAudit) {}
                let scopeBeforeRejection = authorizer.scope
                let denialBeforeRejection = authorizer.denied
                do {
                    try withAuthorization(.configuration) {}
                    throw ElysiumStorageError.invalidValue
                } catch ElysiumStorageError.capabilityViolation {
                    // Exact expected forbidden widening.
                }
                guard authorizer.scope == scopeBeforeRejection,
                      authorizer.denied == denialBeforeRejection else {
                    throw ElysiumStorageError.invalidValue
                }
            }

            do {
                try withAuthorization(.schemaAudit) {
                    do { _ = try prepareRaw("DELETE FROM worlds", operation: .prepare) }
                    catch { /* sticky denial must outlive the caught prepare error */ }
                    try withAuthorization(.schemaAudit) {}
                    guard authorizer.denied else { throw ElysiumStorageError.invalidValue }
                }
                throw ElysiumStorageError.invalidValue
            } catch ElysiumStorageError.capabilityViolation {
                // Exact expected sticky denial.
            }

            guard authorizer.scope == .denyAll, !authorizer.denied,
                  authorizationGeneration == generationBefore else {
                throw ElysiumStorageError.invalidValue
            }
            return authorizationTransitionCoverage
        }
    }

    fileprivate func testRecoverySideEffectSnapshot()
        throws -> ElysiumStorageRecoverySideEffectSnapshot {
        try admitted {
            guard let handle else { throw ElysiumStorageError.closed }
            let names = try withAuthorization(.schemaAudit) {
                try withRawStatement("""
                    SELECT name FROM sqlite_master
                    WHERE name IN ('pebble_storage_component_schema_v1',
                      'rpg_local_preferences_v1',
                      'rpg_local_preference_migrations_v1')
                    ORDER BY name
                    """) { statement in
                    var result: [String] = []
                    while true {
                        let rc = sqlite3_step(statement)
                        if rc == SQLITE_DONE { break }
                        guard rc == SQLITE_ROW else {
                            throw ElysiumStorageError.schemaIntegrity
                        }
                        result.append(try copyRawText(
                            statement, column: 0, maximumBytes: 64))
                    }
                    return result
                }
            }
            return ElysiumStorageRecoverySideEffectSnapshot(
                rpgLocalSchemaObjects: names,
                totalChanges: sqlite3_total_changes(handle),
                authorizationGeneration: authorizationGeneration,
                authorizationIsDenyAll: authorizer.scope == .denyAll,
                authorizationDenied: authorizer.denied)
        }
    }

    fileprivate func testSchemaAuditDeniedProbe(_ probe: ElysiumStorageSchemaAuditProbe) throws {
        let sql: StaticString
        switch probe {
        case .tempPageCount: sql = "PRAGMA temp.page_count"
        case .pageCountArgument: sql = "PRAGMA main.page_count(1)"
        case .missingQuickCheckArgument: sql = "PRAGMA main.quick_check"
        case .wrongQuickCheckArgument: sql = "PRAGMA main.quick_check(2)"
        case .integrityCheck: sql = "PRAGMA main.integrity_check"
        case .partialQuickCheck: sql = "PRAGMA main.quick_check('worlds')"
        case .tableValuedPageCount: sql = "SELECT * FROM pragma_page_count"
        case .dbstat: sql = "SELECT * FROM dbstat"
        }
        try admitted {
            try withAuthorization(.schemaAudit) {
                try withRawStatement(sql) { statement in
                    var rc = sqlite3_step(statement)
                    while rc == SQLITE_ROW { rc = sqlite3_step(statement) }
                    guard rc == SQLITE_DONE else { throw sqliteError(.step, code: rc) }
                }
            }
        }
    }

    fileprivate func testSQLiteLengthLimitProbe() throws -> ElysiumStorageSQLiteLengthLimitProbe {
        try admitted {
            guard let handle else { throw ElysiumStorageError.closed }
            let configured = sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, -1)
            return try withAuthorization(.schemaAudit) {
                try withRawStatement("SELECT ?") { statement in
                    let exact = sqlite3_bind_zeroblob64(
                        statement, 1, sqlite3_uint64(StorageBounds.sqliteLengthLimit))
                    _ = sqlite3_reset(statement)
                    _ = sqlite3_clear_bindings(statement)
                    let oneOver = sqlite3_bind_zeroblob64(
                        statement, 1, sqlite3_uint64(StorageBounds.sqliteLengthLimit + 1))
                    return ElysiumStorageSQLiteLengthLimitProbe(
                        configured: configured, exactBindCode: exact,
                        oneOverBindCode: oneOver)
                }
            }
        }
    }

    fileprivate func testExtendedPrimaryKeyConstraint() throws {
        _ = try mutate(table: "worlds") { context in
            _ = try executeMutation(context, "DELETE FROM worlds WHERE id='__constraint_probe__'") { _ in }
            _ = try executeMutation(context, """
                INSERT INTO worlds(id,json,lastPlayed) VALUES('__constraint_probe__','{}',0.0)
                """) { _ in }
            return try executeMutation(context, """
                INSERT INTO worlds(id,json,lastPlayed) VALUES('__constraint_probe__','{}',0.0)
                """) { _ in }
        }
    }
#endif

    private func prepareRaw(_ sql: StaticString, operation: ElysiumStorageOperationID) throws -> OpaquePointer {
        guard let handle else { throw ElysiumStorageError.closed }
        var statement: OpaquePointer?
        let rc = sql.withUTF8Buffer { bytes -> Int32 in
            guard let base = bytes.baseAddress else { return SQLITE_MISUSE }
            return sqlite3_prepare_v2(handle,
                                      UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self),
                                      Int32(bytes.count), &statement, nil)
        }
        guard rc == SQLITE_OK, let statement else {
            if authorizer.denied { throw ElysiumStorageError.capabilityViolation }
            throw sqliteError(operation, code: rc)
        }
        return statement
    }

    private func withRawStatement<T>(_ sql: StaticString,
                                     operation: ElysiumStorageOperationID = .prepare,
                                     _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement = try prepareRaw(sql, operation: operation)
        let value: T
        do {
            value = try body(statement)
        } catch {
            let primary = error
            let finalizeRC = sqlite3_finalize(statement)
            if finalizeRC != SQLITE_OK {
                throw ElysiumStorageStatementFailure(primary: primary,
                                                    finalize: sqliteError(.finalize, code: finalizeRC))
            }
            throw primary
        }
        let finalizeRC = sqlite3_finalize(statement)
        guard finalizeRC == SQLITE_OK else { throw sqliteError(.finalize, code: finalizeRC) }
        return value
    }

    private func executePragma(_ sql: StaticString, operation: ElysiumStorageOperationID) throws {
        try withRawStatement(sql, operation: operation) { statement in
            var rc = sqlite3_step(statement)
            while rc == SQLITE_ROW { rc = sqlite3_step(statement) }
            guard rc == SQLITE_DONE else { throw sqliteError(operation, code: rc) }
        }
    }

    private func verifyIntegerPragma(_ sql: StaticString, expected: Int64) throws {
        try withRawStatement(sql, operation: .configure) { statement in
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_ROW else { throw sqliteError(.configure, code: rc) }
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
                  sqlite3_column_int64(statement, 0) == expected else {
                throw storageSQLiteError(SQLITE_ERROR, operation: .configure)
            }
            let doneRC = sqlite3_step(statement)
            guard doneRC == SQLITE_DONE else { throw sqliteError(.configure, code: doneRC) }
        }
    }

    private func verifyTextPragma(_ sql: StaticString, expected: StaticString) throws {
        try withRawStatement(sql, operation: .configure) { statement in
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_ROW else { throw sqliteError(.configure, code: rc) }
            let textPointer = sqlite3_column_text(statement, 0).map {
                UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
            }
            guard sqlite3_column_type(statement, 0) == SQLITE_TEXT,
                  cStringEquals(textPointer, expected) else {
                throw storageSQLiteError(SQLITE_ERROR, operation: .configure)
            }
            let doneRC = sqlite3_step(statement)
            guard doneRC == SQLITE_DONE else { throw sqliteError(.configure, code: doneRC) }
        }
    }

    func close() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        switch lifecycle {
        case let .closed(result): return try result.get()
        case .poisoned:
            throw ElysiumStorageError.poisoned
        case .opening, .closing:
            throw ElysiumStorageError.closed
        case .open:
            lifecycle = .closing
        }

        do {
            if isOnQueue { try closeOnQueue() }
            else { try queue.sync { try closeOnQueue() } }
            guard handle == nil else {
                lifecycle = .poisoned
                throw ElysiumStorageError.poisoned
            }
            lifecycle = .closed(.success(()))
        } catch let error as ElysiumStorageError {
            if handle == nil { lifecycle = .closed(.failure(error)) }
            else { lifecycle = .poisoned }
            throw error
        } catch {
            let closedError = storageSQLiteError(SQLITE_ERROR, operation: .close)
            if handle == nil { lifecycle = .closed(.failure(closedError)) }
            else { lifecycle = .poisoned }
            throw closedError
        }
    }

    private func closeOnQueue() throws {
        precondition(isOnQueue)
        do {
            try ordinaryCloseOnQueue()
        } catch let error as ElysiumStorageError {
            _ = terminalClose(tombstone: true)
            throw error
        } catch {
            let closedError = storageSQLiteError(SQLITE_ERROR, operation: .close)
            _ = terminalClose(tombstone: true)
            throw closedError
        }
    }

    private func ordinaryCloseOnQueue() throws {
        precondition(isOnQueue)
        guard let handle else {
            lease.release(tombstone: false)
            return
        }
        guard sqlite3_get_autocommit(handle) != 0 else {
            throw ElysiumStorageError.transactionStillOpen
        }
        try injectIfRequested(.close)
        authorizer.scope = .denyAll
        guard sqlite3_set_authorizer(handle, nil, nil) == SQLITE_OK else {
            throw sqliteError(.authorizer)
        }
        let rc = sqlite3_close(handle)
        guard rc == SQLITE_OK else { throw storageSQLiteError(rc, operation: .close) }
        self.handle = nil
        releaseAuthorizerCallbackRetain()
        lease.release(tombstone: false)
    }

    @discardableResult
    private func terminalClose(tombstone: Bool) -> Bool {
        precondition(isOnQueue)
        if let handle {
            authorizer.scope = .denyAll
            var statement = sqlite3_next_stmt(handle, nil)
            var finalizeFailed = false
            while let current = statement {
                statement = sqlite3_next_stmt(handle, current)
                if sqlite3_finalize(current) != SQLITE_OK { finalizeFailed = true }
            }
#if DEBUG
            do {
                try injectIfRequested(.close)
            } catch {
                lease.release(tombstone: true)
                return false
            }
#endif
            let authorizerRC = sqlite3_set_authorizer(handle, nil, nil)
            let closeRC = sqlite3_close(handle)
            if closeRC == SQLITE_OK {
                self.handle = nil
                releaseAuthorizerCallbackRetain()
                lease.release(tombstone: tombstone || authorizerRC != SQLITE_OK
                              || finalizeFailed)
                return true
            }
            lease.release(tombstone: true)
            return false
        } else {
            lease.release(tombstone: tombstone)
            return true
        }
    }

    private func releaseAuthorizerCallbackRetain() {
        guard authorizerCallbackRetained else { return }
        authorizerCallbackRetained = false
        Unmanaged.passUnretained(authorizer).release()
    }

    deinit {
        if handle != nil {
            let finish = {
                do { try self.closeOnQueue() }
                catch { if self.handle != nil { self.terminalClose(tombstone: true) } }
            }
            if isOnQueue { finish() }
            else { queue.sync(execute: finish) }
        }
    }
}

// MARK: - Closed core schema manifest (implementation follows below)

private enum StorageSchema {
    struct PhysicalObject: Hashable {
        let type: String
        let name: String
        let table: String
    }

    struct Column: Equatable {
        let name: String
        let type: String
        let notNull: Bool
        let defaultValue: String?
        let primaryKey: Int
    }

    struct Layout {
        let name: String
        let pragma: StaticString
        let tableListPragma: StaticString
        let indexListPragma: StaticString
        let indexXInfoPragma: StaticString
        let foreignKeyPragma: StaticString
        let indexName: String
        let withoutRowID: Bool
        let columns: [Column]
    }

    static let coreTables: Set<String> = [
        "worlds", "chunks", "player", "lan_player_resume", "lan_players",
        "advancements", "templates",
    ]
    static let componentMarkerTable = "pebble_storage_component_schema_v1"
    static let rpgLocalRuntimeTables: Set<String> = [
        "rpg_local_preferences_v1", "rpg_local_preference_migrations_v1",
    ]
    static let rpgLocalTables = rpgLocalRuntimeTables.union([componentMarkerTable])
    static let clientTables: Set<String> = [
        "lan_client_credentials_v6", "lan_client_owner_checkpoint_v6",
        "lan_client_pending_disposition_v6", "lan_client_notification_inbox_v6",
    ]
    static let clientRenderIndex = "lan_client_notification_inbox_v6_render_order"
    static let knownTables = coreTables.union(rpgLocalTables).union(clientTables)
    static let sqliteMasterColumns: Set<String> = ["type", "name", "tbl_name", "rootpage", "sql", "ROWID"]
    static let columns: [String: Set<String>] = [
        "worlds": ["id", "json", "lastPlayed"],
        "chunks": ["world", "dim", "cx", "cz", "data"],
        "player": ["world", "json"],
        "lan_player_resume": ["hostWorld", "json", "updated"],
        "lan_players": ["world", "playerID", "json", "updated"],
        "advancements": ["world", "json"],
        "templates": ["name", "json", "created", "format", "data", "sizeX", "sizeY", "sizeZ",
                      "blockCount", "blockEntityCount", "dominantBlock", "dominantDisplay"],
        "pebble_storage_component_schema_v1": ["component", "revision", "manifest_digest"],
        "rpg_local_preferences_v1": ["world_record_id", "schema_version", "revision",
            "slots_payload", "payload_digest", "migration_origin_digest",
            "migration_origin_revision"],
        "rpg_local_preference_migrations_v1": ["world_record_id", "schema_version",
            "source_digest", "destination_digest", "destination_revision"],
        "lan_client_credentials_v6": ["hid", "wid", "lookup_digest", "schema_version",
            "aggregate_generation", "aggregate_digest", "authority_bound", "payload",
            "payload_digest"],
        "lan_client_owner_checkpoint_v6": ["hid", "wid", "lookup_digest", "schema_version",
            "last_change_generation", "payload", "payload_digest"],
        "lan_client_pending_disposition_v6": ["hid", "wid", "lookup_digest", "schema_version",
            "last_change_generation", "mode", "payload", "payload_digest"],
        "lan_client_notification_inbox_v6": ["hid", "wid", "lookup_digest",
            "notification_id", "session_epoch", "request_id", "snapshot_id", "status",
            "creation_generation", "acknowledgement_state", "acknowledgement_generation",
            "payload", "payload_digest"],
    ]

    static let rpgLocalCreateStatements: [StaticString] = [
        """
        CREATE TABLE pebble_storage_component_schema_v1(
          component TEXT NOT NULL COLLATE BINARY,
          revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision=1),
          manifest_digest BLOB NOT NULL CHECK(typeof(manifest_digest)='blob' AND length(manifest_digest)=32),
          PRIMARY KEY(component),
          CHECK(component IN ('rpgLocalPreferences','lanClientAuthority','lanHostOwnerRows'))
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE rpg_local_preferences_v1(
          world_record_id TEXT NOT NULL COLLATE BINARY
            CHECK(typeof(world_record_id)='text'
              AND length(CAST(world_record_id AS BLOB)) BETWEEN 1 AND 64),
          schema_version INTEGER NOT NULL
            CHECK(typeof(schema_version)='integer' AND schema_version=1),
          revision INTEGER NOT NULL
            CHECK(typeof(revision)='integer' AND revision BETWEEN 1 AND 1000000000),
          slots_payload BLOB NOT NULL
            CHECK(typeof(slots_payload)='blob' AND length(slots_payload) BETWEEN 18 AND 4096),
          payload_digest BLOB NOT NULL
            CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
          migration_origin_digest BLOB
            CHECK(migration_origin_digest IS NULL
              OR (typeof(migration_origin_digest)='blob' AND length(migration_origin_digest)=32)),
          migration_origin_revision INTEGER
            CHECK(migration_origin_revision IS NULL
              OR (typeof(migration_origin_revision)='integer'
                AND migration_origin_revision BETWEEN 1 AND 1000000000)),
          CHECK((migration_origin_digest IS NULL AND migration_origin_revision IS NULL)
             OR (migration_origin_digest IS NOT NULL AND migration_origin_revision IS NOT NULL)),
          PRIMARY KEY(world_record_id)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE rpg_local_preference_migrations_v1(
          world_record_id TEXT NOT NULL COLLATE BINARY
            CHECK(typeof(world_record_id)='text'
              AND length(CAST(world_record_id AS BLOB)) BETWEEN 1 AND 64),
          schema_version INTEGER NOT NULL
            CHECK(typeof(schema_version)='integer' AND schema_version=1),
          source_digest BLOB NOT NULL
            CHECK(typeof(source_digest)='blob' AND length(source_digest)=32),
          destination_digest BLOB NOT NULL
            CHECK(typeof(destination_digest)='blob' AND length(destination_digest)=32),
          destination_revision INTEGER NOT NULL
            CHECK(typeof(destination_revision)='integer'
              AND destination_revision BETWEEN 1 AND 1000000000),
          PRIMARY KEY(world_record_id),
          FOREIGN KEY(world_record_id) REFERENCES rpg_local_preferences_v1(world_record_id)
            ON UPDATE RESTRICT ON DELETE CASCADE
        ) WITHOUT ROWID
        """,
    ]
    static let rpgLocalManifestDigest: Data = {
        let component = Data("rpgLocalPreferences".utf8)
        let statements = rpgLocalCreateStatements.map { statement -> Data in
            let canonical = statement.description.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return Data(canonical.utf8)
        }
        var manifest = Data("Pebble/storage-schema/v1\0".utf8)
        func appendUInt32(_ value: Int) {
            let narrowed = UInt32(value)
            manifest.append(UInt8(truncatingIfNeeded: narrowed >> 24))
            manifest.append(UInt8(truncatingIfNeeded: narrowed >> 16))
            manifest.append(UInt8(truncatingIfNeeded: narrowed >> 8))
            manifest.append(UInt8(truncatingIfNeeded: narrowed))
        }
        appendUInt32(component.count)
        manifest.append(component)
        appendUInt32(statements.count)
        for statement in statements {
            appendUInt32(statement.count)
            manifest.append(statement)
        }
        return storageSHA256(manifest)
    }()

    static let clientCreateStatements: [StaticString] = [
        """
        CREATE TABLE lan_client_credentials_v6(
          hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
          wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
          lookup_digest BLOB NOT NULL CHECK(typeof(lookup_digest)='blob' AND length(lookup_digest)=32),
          schema_version INTEGER NOT NULL CHECK(typeof(schema_version)='integer' AND schema_version=1),
          aggregate_generation INTEGER NOT NULL
            CHECK(typeof(aggregate_generation)='integer' AND aggregate_generation BETWEEN 0 AND 1000000000),
          aggregate_digest BLOB NOT NULL
            CHECK(typeof(aggregate_digest)='blob' AND length(aggregate_digest)=32),
          authority_bound INTEGER NOT NULL
            CHECK(typeof(authority_bound)='integer' AND authority_bound IN (0,1)),
          payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 65536),
          payload_digest BLOB NOT NULL
            CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
          CHECK((authority_bound=0 AND aggregate_generation=0)
             OR (authority_bound=1 AND aggregate_generation BETWEEN 1 AND 1000000000)),
          PRIMARY KEY(hid,wid,lookup_digest),
          UNIQUE(hid,wid)
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE lan_client_owner_checkpoint_v6(
          hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
          wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
          lookup_digest BLOB NOT NULL CHECK(typeof(lookup_digest)='blob' AND length(lookup_digest)=32),
          schema_version INTEGER NOT NULL CHECK(typeof(schema_version)='integer' AND schema_version=1),
          last_change_generation INTEGER NOT NULL
            CHECK(typeof(last_change_generation)='integer' AND last_change_generation BETWEEN 1 AND 1000000000),
          payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 786432),
          payload_digest BLOB NOT NULL CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
          PRIMARY KEY(hid,wid,lookup_digest),
          FOREIGN KEY(hid,wid,lookup_digest)
            REFERENCES lan_client_credentials_v6(hid,wid,lookup_digest)
            ON UPDATE RESTRICT ON DELETE CASCADE
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE lan_client_pending_disposition_v6(
          hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
          wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
          lookup_digest BLOB NOT NULL CHECK(typeof(lookup_digest)='blob' AND length(lookup_digest)=32),
          schema_version INTEGER NOT NULL CHECK(typeof(schema_version)='integer' AND schema_version=1),
          last_change_generation INTEGER NOT NULL
            CHECK(typeof(last_change_generation)='integer' AND last_change_generation BETWEEN 1 AND 1000000000),
          mode INTEGER NOT NULL CHECK(typeof(mode)='integer' AND mode IN (1,2)),
          payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 131072),
          payload_digest BLOB NOT NULL CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
          PRIMARY KEY(hid,wid,lookup_digest),
          FOREIGN KEY(hid,wid,lookup_digest)
            REFERENCES lan_client_credentials_v6(hid,wid,lookup_digest)
            ON UPDATE RESTRICT ON DELETE CASCADE
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE lan_client_notification_inbox_v6(
          hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
          wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
          lookup_digest BLOB NOT NULL CHECK(typeof(lookup_digest)='blob' AND length(lookup_digest)=32),
          notification_id BLOB NOT NULL CHECK(typeof(notification_id)='blob' AND length(notification_id)=32),
          session_epoch BLOB NOT NULL CHECK(typeof(session_epoch)='blob' AND length(session_epoch)=16),
          request_id INTEGER NOT NULL CHECK(typeof(request_id)='integer' AND request_id BETWEEN 1 AND 1000000000),
          snapshot_id BLOB NOT NULL CHECK(typeof(snapshot_id)='blob' AND length(snapshot_id)=16),
          status INTEGER NOT NULL CHECK(typeof(status)='integer' AND status BETWEEN 1 AND 4),
          creation_generation INTEGER NOT NULL
            CHECK(typeof(creation_generation)='integer' AND creation_generation BETWEEN 1 AND 1000000000),
          acknowledgement_state INTEGER NOT NULL
            CHECK(typeof(acknowledgement_state)='integer' AND acknowledgement_state IN (0,1)),
          acknowledgement_generation INTEGER NOT NULL
            CHECK(typeof(acknowledgement_generation)='integer' AND acknowledgement_generation IN (0,1)),
          payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 4096),
          payload_digest BLOB NOT NULL CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
          CHECK(acknowledgement_state=acknowledgement_generation),
          PRIMARY KEY(hid,wid,notification_id),
          UNIQUE(hid,wid,session_epoch,request_id),
          FOREIGN KEY(hid,wid,lookup_digest)
            REFERENCES lan_client_credentials_v6(hid,wid,lookup_digest)
            ON UPDATE RESTRICT ON DELETE CASCADE
        ) WITHOUT ROWID
        """,
        """
        CREATE INDEX lan_client_notification_inbox_v6_render_order
        ON lan_client_notification_inbox_v6(
          hid,wid,lookup_digest,acknowledgement_state,creation_generation,notification_id
        )
        """,
    ]
    static let clientManifestDigest: Data = componentManifestDigest(
        component: "lanClientAuthority", statements: clientCreateStatements)
    // Compiled now so the later coherent host-checkpoint phase cannot silently drift the
    // approved row contract. There is deliberately no bootstrap accessor or runtime scope:
    // the reviewed parent identity tables do not exist in this amendment.
    static let dormantHostOwnerCreateStatements: [StaticString] = [
        """
        CREATE TABLE lan_peer_authority_checkpoint_v6(
          hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
          wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
          authority TEXT NOT NULL COLLATE BINARY
            CHECK(typeof(authority)='text' AND length(CAST(authority AS BLOB)) BETWEEN 5 AND 24),
          checkpoint_generation BLOB NOT NULL
            CHECK(typeof(checkpoint_generation)='blob' AND length(checkpoint_generation)=8),
          payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 786432),
          payload_digest BLOB NOT NULL CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
          world_checkpoint_digest BLOB NOT NULL
            CHECK(typeof(world_checkpoint_digest)='blob' AND length(world_checkpoint_digest)=32),
          PRIMARY KEY(hid,wid,authority),
          FOREIGN KEY(hid,wid,authority)
            REFERENCES lan_peer_identity_v6(hid,wid,authority)
            ON UPDATE RESTRICT ON DELETE RESTRICT
        ) WITHOUT ROWID
        """,
        """
        CREATE TABLE lan_host_local_authority_checkpoint_v6(
          hid BLOB NOT NULL CHECK(typeof(hid)='blob' AND length(hid)=16),
          wid BLOB NOT NULL CHECK(typeof(wid)='blob' AND length(wid)=16),
          authority TEXT NOT NULL COLLATE BINARY
            CHECK(typeof(authority)='text' AND authority='host:local'),
          checkpoint_generation BLOB NOT NULL
            CHECK(typeof(checkpoint_generation)='blob' AND length(checkpoint_generation)=8),
          payload BLOB NOT NULL CHECK(typeof(payload)='blob' AND length(payload) BETWEEN 1 AND 786432),
          payload_digest BLOB NOT NULL CHECK(typeof(payload_digest)='blob' AND length(payload_digest)=32),
          world_checkpoint_digest BLOB NOT NULL
            CHECK(typeof(world_checkpoint_digest)='blob' AND length(world_checkpoint_digest)=32),
          PRIMARY KEY(hid,wid),
          FOREIGN KEY(hid,wid)
            REFERENCES lan_world_identity_registry_v1(hid,wid)
            ON UPDATE RESTRICT ON DELETE RESTRICT
        ) WITHOUT ROWID
        """,
    ]
    static let dormantHostOwnerManifestDigest: Data = componentManifestDigest(
        component: "lanHostOwnerRows", statements: dormantHostOwnerCreateStatements)

    private static func componentManifestDigest(component: String,
                                                statements: [StaticString]) -> Data {
        let componentData = Data(component.utf8)
        let canonicalStatements = statements.map {
            Data($0.description.split(whereSeparator: \.isWhitespace).joined(separator: " ").utf8)
        }
        var manifest = Data("Pebble/storage-schema/v1\0".utf8)
        func appendUInt32(_ value: Int) {
            let narrowed = UInt32(value)
            manifest.append(UInt8(truncatingIfNeeded: narrowed >> 24))
            manifest.append(UInt8(truncatingIfNeeded: narrowed >> 16))
            manifest.append(UInt8(truncatingIfNeeded: narrowed >> 8))
            manifest.append(UInt8(truncatingIfNeeded: narrowed))
        }
        appendUInt32(componentData.count); manifest.append(componentData)
        appendUInt32(canonicalStatements.count)
        for statement in canonicalStatements {
            appendUInt32(statement.count); manifest.append(statement)
        }
        return storageSHA256(manifest)
    }

    static let createStatements: [StaticString] = [
        """
        CREATE TABLE IF NOT EXISTS worlds(
            id TEXT PRIMARY KEY, json TEXT NOT NULL, lastPlayed REAL NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE IF NOT EXISTS chunks(
            world TEXT NOT NULL, dim INTEGER NOT NULL, cx INTEGER NOT NULL, cz INTEGER NOT NULL,
            data BLOB NOT NULL, PRIMARY KEY(world, dim, cx, cz)) WITHOUT ROWID
        """,
        "CREATE TABLE IF NOT EXISTS player(world TEXT PRIMARY KEY, json TEXT NOT NULL)",
        """
        CREATE TABLE IF NOT EXISTS lan_player_resume(
            hostWorld TEXT PRIMARY KEY, json TEXT NOT NULL, updated REAL NOT NULL DEFAULT 0)
        """,
        """
        CREATE TABLE IF NOT EXISTS lan_players(
            world TEXT NOT NULL, playerID TEXT NOT NULL, json TEXT NOT NULL,
            updated REAL NOT NULL DEFAULT 0, PRIMARY KEY(world, playerID))
        """,
        "CREATE TABLE IF NOT EXISTS advancements(world TEXT PRIMARY KEY, json TEXT NOT NULL)",
        """
        CREATE TABLE IF NOT EXISTS templates(
            name TEXT PRIMARY KEY, json TEXT NOT NULL, created REAL NOT NULL DEFAULT 0,
            format INTEGER NOT NULL DEFAULT 1, data BLOB,
            sizeX INTEGER NOT NULL DEFAULT 0, sizeY INTEGER NOT NULL DEFAULT 0,
            sizeZ INTEGER NOT NULL DEFAULT 0, blockCount INTEGER NOT NULL DEFAULT 0,
            blockEntityCount INTEGER NOT NULL DEFAULT 0,
            dominantBlock TEXT NOT NULL DEFAULT '', dominantDisplay TEXT NOT NULL DEFAULT '')
        """,
    ]

    static let templateMigrations: [(name: String, sql: StaticString)] = [
        ("format", "ALTER TABLE templates ADD COLUMN format INTEGER NOT NULL DEFAULT 1"),
        ("data", "ALTER TABLE templates ADD COLUMN data BLOB"),
        ("sizeX", "ALTER TABLE templates ADD COLUMN sizeX INTEGER NOT NULL DEFAULT 0"),
        ("sizeY", "ALTER TABLE templates ADD COLUMN sizeY INTEGER NOT NULL DEFAULT 0"),
        ("sizeZ", "ALTER TABLE templates ADD COLUMN sizeZ INTEGER NOT NULL DEFAULT 0"),
        ("blockCount", "ALTER TABLE templates ADD COLUMN blockCount INTEGER NOT NULL DEFAULT 0"),
        ("blockEntityCount", "ALTER TABLE templates ADD COLUMN blockEntityCount INTEGER NOT NULL DEFAULT 0"),
        ("dominantBlock", "ALTER TABLE templates ADD COLUMN dominantBlock TEXT NOT NULL DEFAULT ''"),
        ("dominantDisplay", "ALTER TABLE templates ADD COLUMN dominantDisplay TEXT NOT NULL DEFAULT ''"),
    ]

    private static let templateBaseColumnSQL = [
        "name TEXT PRIMARY KEY",
        "json TEXT NOT NULL",
        "created REAL NOT NULL DEFAULT 0",
    ]
    private static let templateMigrationColumnSQL = [
        "format INTEGER NOT NULL DEFAULT 1",
        "data BLOB",
        "sizeX INTEGER NOT NULL DEFAULT 0",
        "sizeY INTEGER NOT NULL DEFAULT 0",
        "sizeZ INTEGER NOT NULL DEFAULT 0",
        "blockCount INTEGER NOT NULL DEFAULT 0",
        "blockEntityCount INTEGER NOT NULL DEFAULT 0",
        "dominantBlock TEXT NOT NULL DEFAULT ''",
        "dominantDisplay TEXT NOT NULL DEFAULT ''",
    ]
    static let templateRevisionSQL: [String] = (0...templateMigrations.count).map { prefixCount in
        let columns = templateBaseColumnSQL + templateMigrationColumnSQL.prefix(prefixCount)
        return "CREATE TABLE templates(\(columns.joined(separator: ", ")))"
    }

    static let canonicalTableSQL: [String: String] = [
        "worlds": "CREATE TABLE worlds(id TEXT PRIMARY KEY, json TEXT NOT NULL, lastPlayed REAL NOT NULL DEFAULT 0)",
        "chunks": "CREATE TABLE chunks(world TEXT NOT NULL, dim INTEGER NOT NULL, cx INTEGER NOT NULL, cz INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(world, dim, cx, cz)) WITHOUT ROWID",
        "player": "CREATE TABLE player(world TEXT PRIMARY KEY, json TEXT NOT NULL)",
        "lan_player_resume": "CREATE TABLE lan_player_resume(hostWorld TEXT PRIMARY KEY, json TEXT NOT NULL, updated REAL NOT NULL DEFAULT 0)",
        "lan_players": "CREATE TABLE lan_players(world TEXT NOT NULL, playerID TEXT NOT NULL, json TEXT NOT NULL, updated REAL NOT NULL DEFAULT 0, PRIMARY KEY(world, playerID))",
        "advancements": "CREATE TABLE advancements(world TEXT PRIMARY KEY, json TEXT NOT NULL)",
        "templates": "CREATE TABLE templates(name TEXT PRIMARY KEY, json TEXT NOT NULL, created REAL NOT NULL DEFAULT 0, format INTEGER NOT NULL DEFAULT 1, data BLOB, sizeX INTEGER NOT NULL DEFAULT 0, sizeY INTEGER NOT NULL DEFAULT 0, sizeZ INTEGER NOT NULL DEFAULT 0, blockCount INTEGER NOT NULL DEFAULT 0, blockEntityCount INTEGER NOT NULL DEFAULT 0, dominantBlock TEXT NOT NULL DEFAULT '', dominantDisplay TEXT NOT NULL DEFAULT '')",
        "pebble_storage_component_schema_v1": rpgLocalCreateStatements[0].description,
        "rpg_local_preferences_v1": rpgLocalCreateStatements[1].description,
        "rpg_local_preference_migrations_v1": rpgLocalCreateStatements[2].description,
        "lan_client_credentials_v6": clientCreateStatements[0].description,
        "lan_client_owner_checkpoint_v6": clientCreateStatements[1].description,
        "lan_client_pending_disposition_v6": clientCreateStatements[2].description,
        "lan_client_notification_inbox_v6": clientCreateStatements[3].description,
    ]
    static let componentIndexSQL: [String: String] = [
        clientRenderIndex: clientCreateStatements[4].description,
    ]
    static let componentImplicitIndexes: [String: String] = [
        "sqlite_autoindex_lan_client_credentials_v6_2": "lan_client_credentials_v6",
        "sqlite_autoindex_lan_client_notification_inbox_v6_2":
            "lan_client_notification_inbox_v6",
    ]

    static let layouts: [Layout] = [
        Layout(name: "worlds", pragma: "PRAGMA main.table_info('worlds')",
               tableListPragma: "PRAGMA main.table_list('worlds')",
               indexListPragma: "PRAGMA main.index_list('worlds')",
               indexXInfoPragma: "PRAGMA main.index_xinfo('sqlite_autoindex_worlds_1')",
               foreignKeyPragma: "PRAGMA main.foreign_key_list('worlds')",
               indexName: "sqlite_autoindex_worlds_1", withoutRowID: false, columns: [
            .init(name: "id", type: "TEXT", notNull: false, defaultValue: nil, primaryKey: 1),
            .init(name: "json", type: "TEXT", notNull: true, defaultValue: nil, primaryKey: 0),
            .init(name: "lastPlayed", type: "REAL", notNull: true, defaultValue: "0", primaryKey: 0),
        ]),
        Layout(name: "chunks", pragma: "PRAGMA main.table_info('chunks')",
               tableListPragma: "PRAGMA main.table_list('chunks')",
               indexListPragma: "PRAGMA main.index_list('chunks')",
               indexXInfoPragma: "PRAGMA main.index_xinfo('sqlite_autoindex_chunks_1')",
               foreignKeyPragma: "PRAGMA main.foreign_key_list('chunks')",
               indexName: "sqlite_autoindex_chunks_1", withoutRowID: true, columns: [
            .init(name: "world", type: "TEXT", notNull: true, defaultValue: nil, primaryKey: 1),
            .init(name: "dim", type: "INTEGER", notNull: true, defaultValue: nil, primaryKey: 2),
            .init(name: "cx", type: "INTEGER", notNull: true, defaultValue: nil, primaryKey: 3),
            .init(name: "cz", type: "INTEGER", notNull: true, defaultValue: nil, primaryKey: 4),
            .init(name: "data", type: "BLOB", notNull: true, defaultValue: nil, primaryKey: 0),
        ]),
        Layout(name: "player", pragma: "PRAGMA main.table_info('player')",
               tableListPragma: "PRAGMA main.table_list('player')",
               indexListPragma: "PRAGMA main.index_list('player')",
               indexXInfoPragma: "PRAGMA main.index_xinfo('sqlite_autoindex_player_1')",
               foreignKeyPragma: "PRAGMA main.foreign_key_list('player')",
               indexName: "sqlite_autoindex_player_1", withoutRowID: false, columns: [
            .init(name: "world", type: "TEXT", notNull: false, defaultValue: nil, primaryKey: 1),
            .init(name: "json", type: "TEXT", notNull: true, defaultValue: nil, primaryKey: 0),
        ]),
        Layout(name: "lan_player_resume", pragma: "PRAGMA main.table_info('lan_player_resume')",
               tableListPragma: "PRAGMA main.table_list('lan_player_resume')",
               indexListPragma: "PRAGMA main.index_list('lan_player_resume')",
               indexXInfoPragma: "PRAGMA main.index_xinfo('sqlite_autoindex_lan_player_resume_1')",
               foreignKeyPragma: "PRAGMA main.foreign_key_list('lan_player_resume')",
               indexName: "sqlite_autoindex_lan_player_resume_1", withoutRowID: false, columns: [
            .init(name: "hostWorld", type: "TEXT", notNull: false, defaultValue: nil, primaryKey: 1),
            .init(name: "json", type: "TEXT", notNull: true, defaultValue: nil, primaryKey: 0),
            .init(name: "updated", type: "REAL", notNull: true, defaultValue: "0", primaryKey: 0),
        ]),
        Layout(name: "lan_players", pragma: "PRAGMA main.table_info('lan_players')",
               tableListPragma: "PRAGMA main.table_list('lan_players')",
               indexListPragma: "PRAGMA main.index_list('lan_players')",
               indexXInfoPragma: "PRAGMA main.index_xinfo('sqlite_autoindex_lan_players_1')",
               foreignKeyPragma: "PRAGMA main.foreign_key_list('lan_players')",
               indexName: "sqlite_autoindex_lan_players_1", withoutRowID: false, columns: [
            .init(name: "world", type: "TEXT", notNull: true, defaultValue: nil, primaryKey: 1),
            .init(name: "playerID", type: "TEXT", notNull: true, defaultValue: nil, primaryKey: 2),
            .init(name: "json", type: "TEXT", notNull: true, defaultValue: nil, primaryKey: 0),
            .init(name: "updated", type: "REAL", notNull: true, defaultValue: "0", primaryKey: 0),
        ]),
        Layout(name: "advancements", pragma: "PRAGMA main.table_info('advancements')",
               tableListPragma: "PRAGMA main.table_list('advancements')",
               indexListPragma: "PRAGMA main.index_list('advancements')",
               indexXInfoPragma: "PRAGMA main.index_xinfo('sqlite_autoindex_advancements_1')",
               foreignKeyPragma: "PRAGMA main.foreign_key_list('advancements')",
               indexName: "sqlite_autoindex_advancements_1", withoutRowID: false, columns: [
            .init(name: "world", type: "TEXT", notNull: false, defaultValue: nil, primaryKey: 1),
            .init(name: "json", type: "TEXT", notNull: true, defaultValue: nil, primaryKey: 0),
        ]),
        Layout(name: "templates", pragma: "PRAGMA main.table_info('templates')",
               tableListPragma: "PRAGMA main.table_list('templates')",
               indexListPragma: "PRAGMA main.index_list('templates')",
               indexXInfoPragma: "PRAGMA main.index_xinfo('sqlite_autoindex_templates_1')",
               foreignKeyPragma: "PRAGMA main.foreign_key_list('templates')",
               indexName: "sqlite_autoindex_templates_1", withoutRowID: false, columns: [
            .init(name: "name", type: "TEXT", notNull: false, defaultValue: nil, primaryKey: 1),
            .init(name: "json", type: "TEXT", notNull: true, defaultValue: nil, primaryKey: 0),
            .init(name: "created", type: "REAL", notNull: true, defaultValue: "0", primaryKey: 0),
            .init(name: "format", type: "INTEGER", notNull: true, defaultValue: "1", primaryKey: 0),
            .init(name: "data", type: "BLOB", notNull: false, defaultValue: nil, primaryKey: 0),
            .init(name: "sizeX", type: "INTEGER", notNull: true, defaultValue: "0", primaryKey: 0),
            .init(name: "sizeY", type: "INTEGER", notNull: true, defaultValue: "0", primaryKey: 0),
            .init(name: "sizeZ", type: "INTEGER", notNull: true, defaultValue: "0", primaryKey: 0),
            .init(name: "blockCount", type: "INTEGER", notNull: true, defaultValue: "0", primaryKey: 0),
            .init(name: "blockEntityCount", type: "INTEGER", notNull: true, defaultValue: "0", primaryKey: 0),
            .init(name: "dominantBlock", type: "TEXT", notNull: true, defaultValue: "''", primaryKey: 0),
            .init(name: "dominantDisplay", type: "TEXT", notNull: true, defaultValue: "''", primaryKey: 0),
        ]),
    ]

    static let indexNameByTable: [String: String] = Dictionary(
        uniqueKeysWithValues: layouts.map { ($0.name, $0.indexName) })

    static func expectedPhysicalObjects(for tables: Set<String>) -> Set<PhysicalObject> {
        var objects = Set<PhysicalObject>()
        for table in tables {
            objects.insert(.init(type: "table", name: table, table: table))
            if table != "chunks", let indexName = indexNameByTable[table] {
                objects.insert(.init(type: "index", name: indexName, table: table))
            }
        }
        for (name, table) in componentImplicitIndexes where tables.contains(table) {
            objects.insert(.init(type: "index", name: name, table: table))
        }
        if tables.contains("lan_client_notification_inbox_v6") {
            objects.insert(.init(type: "index", name: clientRenderIndex,
                                 table: "lan_client_notification_inbox_v6"))
        }
        return objects
    }

    static func templateLayout(prefixCount: Int) -> Layout {
        precondition((0...templateMigrations.count).contains(prefixCount))
        guard let full = layouts.first(where: { $0.name == "templates" }) else {
            preconditionFailure("closed template layout missing")
        }
        return Layout(name: full.name, pragma: full.pragma,
                      tableListPragma: full.tableListPragma,
                      indexListPragma: full.indexListPragma,
                      indexXInfoPragma: full.indexXInfoPragma,
                      foreignKeyPragma: full.foreignKeyPragma,
                      indexName: full.indexName, withoutRowID: full.withoutRowID,
                      columns: Array(full.columns.prefix(3 + prefixCount)))
    }
}

public final class ElysiumStorageCoordinator {
    private let executor: StorageExecutor

    private init(executor: StorageExecutor) {
        self.executor = executor
    }

    public static func open(databaseURL: URL) throws -> ElysiumStorageCoordinator {
        ElysiumStorageCoordinator(executor: try StorageExecutor.open(databaseURL: databaseURL))
    }

    public func legacyCore() throws -> ElysiumLegacyCoreStorage {
        try executor.ensureOpen()
        return ElysiumLegacyCoreStorage(executor: executor)
    }

    public func rpgLocalPreferences() throws -> ElysiumRPGLocalPreferencesStorage {
        try executor.ensureRPGLocalPreferencesSchema()
        return ElysiumRPGLocalPreferencesStorage(executor: executor)
    }

    public func clientAuthorityCheckpointV6() throws
        -> ElysiumClientAuthorityCheckpointV6Storage {
        try executor.verifyClientAuthoritySchemaInstalled()
        return ElysiumClientAuthorityCheckpointV6Storage(executor: executor)
    }

    public func close() throws {
        try executor.close()
    }

    public func verifyDatabaseParentIdentity(device: UInt64, inode: UInt64) throws {
        try executor.verifyDatabaseParentIdentity(device: device, inode: inode)
    }

#if DEBUG
    func _testBootstrapClientAuthoritySchemaForAdmission() throws {
        try executor.bootstrapClientAuthoritySchemaForAdmission()
    }

    static func _testOpen(databaseURL: URL,
                          failurePoint: ElysiumStorageFactoryFailurePoint) throws
        -> ElysiumStorageCoordinator {
        ElysiumStorageCoordinator(
            executor: try StorageExecutor.testOpen(databaseURL: databaseURL,
                                                    failurePoint: failurePoint))
    }

    func _testInject(_ operation: ElysiumStorageOperationID, count: Int = 1) throws {
        try executor.testInject(operation, count: count)
    }
    func _testSetRPGLocalFailure(
        operation: ElysiumStorageRPGLocalTestOperation,
        stage: ElysiumStorageRPGLocalFailureStage
    ) throws {
        try executor.testSetRPGLocalFailure(operation: operation, stage: stage)
    }
    package func _testSetSavedWorldDeleteFailure(
        _ stage: ElysiumStorageRPGLocalFailureStage
    ) throws {
        try executor.testSetRPGLocalFailure(operation: .worldDelete, stage: stage)
    }
    func _testSetLegacyCollectionFailure(
        _ point: ElysiumStorageLegacyCollectionFailurePoint
    ) throws {
        try executor.testSetLegacyCollectionFailure(point)
    }
    func _testSetLegacyImportFailure(_ point: ElysiumStorageLegacyImportFailurePoint) throws {
        try executor.testSetLegacyImportFailure(point)
    }
    func _testSetBarrierFailure(_ point: ElysiumStorageBarrierFailurePoint) throws {
        try executor.testSetBarrierFailure(point)
    }
    func _testArmStage(_ stage: ElysiumStorageTestStage) throws -> ElysiumStorageTestLatch {
        try executor.testArmStage(stage)
    }

    func _testAutocommit() throws -> Bool { try executor.testAutocommit() }
    package func _testRecoverySideEffectSnapshot()
        throws -> ElysiumStorageRecoverySideEffectSnapshot {
        try executor.testRecoverySideEffectSnapshot()
    }
    func _testForeignKeysEnabled() throws -> Bool { try executor.testForeignKeysEnabled() }
    func _testPhysicalIdentityBound() throws -> Bool { try executor.testPhysicalIdentityBound() }
    func _testSameScopeReentry() throws -> Bool { try executor.testSameScopeReentry() }
    func _testEscapedStatementRejects() throws -> ElysiumStorageError {
        try executor.testEscapedStatementRejects()
    }
    func _testReadScopeWriteProbe() throws { try executor.testReadScopeWriteProbe() }
    func _testLegacyWorldScopeDeniedProbe() throws {
        try executor.testLegacyWorldScopeDeniedProbe()
    }
    func _testLegacyTemplateScopeDeniedProbe() throws {
        try executor.testLegacyTemplateScopeDeniedProbe()
    }
    func _testLegacyLANScopeDeniedProbe() throws {
        try executor.testLegacyLANScopeDeniedProbe()
    }
    func _testCrossTableMutationProbe() throws { try executor.testCrossTableMutationProbe() }
    func _testBootstrapAfterReadinessProbe() throws { try executor.testBootstrapAfterReadinessProbe() }
    func _testNestedTransactionProbe() throws { try executor.testNestedTransactionProbe() }
    func _testCaughtBindFailureCannotCommit(_ row: ElysiumWorldStorageRow) throws {
        try executor.testCaughtBindFailureCannotCommit(row)
    }
    func _testForceAuthorizationGenerationBoundary() throws {
        try executor.testForceAuthorizationGenerationBoundary()
    }
    func _testLeakRawStatementForClose() throws { try executor.testLeakRawStatementForClose() }
    func _testBodyAndFinalizeFailure() throws { try executor.testBodyAndFinalizeFailure() }
    func _testAuthorizationContract() throws -> UInt8 {
        try executor.testAuthorizationContract()
    }
    func _testSchemaAuditDeniedProbe(_ probe: ElysiumStorageSchemaAuditProbe) throws {
        try executor.testSchemaAuditDeniedProbe(probe)
    }
    func _testSQLiteLengthLimitProbe() throws -> ElysiumStorageSQLiteLengthLimitProbe {
        try executor.testSQLiteLengthLimitProbe()
    }
    func _testExtendedPrimaryKeyConstraint() throws {
        try executor.testExtendedPrimaryKeyConstraint()
    }
#endif
}

private struct RPGLocalStorageAccounting {
    let preferenceCount: Int64
    let markerCount: Int64
    let totalBytes: Int64
}

private func rpgPreferenceAccountedBytes(_ row: ElysiumRPGLocalPreferenceStorageRow) -> Int64 {
    Int64(256 + row.worldRecordID.utf8.count + 2 + 8 + row.slotsPayload.count + 32 + 1
          + (row.migrationOriginDigest == nil ? 0 : 40))
}

private func rpgMarkerAccountedBytes(
    _ row: ElysiumRPGLegacyQuickSlotMigrationStorageRow
) -> Int64 {
    Int64(256 + row.worldRecordID.utf8.count + 2 + 32 + 32 + 8)
}

private func readRPGLocalAccounting(_ context: StorageContext) throws
    -> RPGLocalStorageAccounting {
    try withStatement(context, """
        SELECT
          (SELECT count(*) FROM rpg_local_preferences_v1),
          (SELECT count(*) FROM rpg_local_preference_migrations_v1),
          coalesce((SELECT sum(256+length(CAST(world_record_id AS BLOB))+2+8+
            length(slots_payload)+32+1+coalesce(length(migration_origin_digest),0)+
            CASE WHEN migration_origin_revision IS NULL THEN 0 ELSE 8 END)
            FROM rpg_local_preferences_v1),0)+
          coalesce((SELECT sum(256+length(CAST(world_record_id AS BLOB))+2+32+32+8)
            FROM rpg_local_preference_migrations_v1),0)
        """) { statement in
        guard try statement.step() == .row else { throw ElysiumStorageError.schemaIntegrity }
        let accounting = RPGLocalStorageAccounting(
            preferenceCount: try statement.int64(0), markerCount: try statement.int64(1),
            totalBytes: try statement.int64(2))
        guard try statement.step() == .done,
              (0...256).contains(accounting.preferenceCount),
              (0...256).contains(accounting.markerCount),
              (0...1_048_576).contains(accounting.totalBytes) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        return accounting
    }
}

private func readRPGPreference(_ context: StorageContext, worldRecordID: String) throws
    -> ElysiumRPGLocalPreferenceStorageRow? {
    try withStatement(context, """
        SELECT world_record_id,schema_version,revision,slots_payload,payload_digest,
               migration_origin_digest,migration_origin_revision
        FROM rpg_local_preferences_v1 WHERE world_record_id=?
        """) { statement in
        try statement.bindText(1, worldRecordID)
        guard try statement.step() == .row else { return nil }
        guard let storedWorld = try statement.text(0, maximumBytes: 64),
              let schemaVersion = UInt16(exactly: try statement.int64(1)),
              let revision = UInt64(exactly: try statement.int64(2)),
              let payload = try statement.data(3, maximumBytes: 4_096),
              let digest = try statement.data(4, maximumBytes: 32) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let originDigest = try statement.data(5, maximumBytes: 32, nullable: true)
        let originRevision: UInt64?
        if try statement.isNull(6) { originRevision = nil }
        else { originRevision = UInt64(exactly: try statement.int64(6)) }
        let row = try ElysiumRPGLocalPreferenceStorageRow(
            worldRecordID: storedWorld, schemaVersion: schemaVersion, revision: revision,
            slotsPayload: payload, payloadDigest: digest,
            migrationOriginDigest: originDigest, migrationOriginRevision: originRevision)
        guard storedWorld == worldRecordID, try statement.step() == .done else {
            throw ElysiumStorageError.schemaIntegrity
        }
        return row
    }
}

private func readRPGMigrationMarker(_ context: StorageContext, worldRecordID: String) throws
    -> ElysiumRPGLegacyQuickSlotMigrationStorageRow? {
    try withStatement(context, """
        SELECT world_record_id,schema_version,source_digest,destination_digest,
               destination_revision
        FROM rpg_local_preference_migrations_v1 WHERE world_record_id=?
        """) { statement in
        try statement.bindText(1, worldRecordID)
        guard try statement.step() == .row else { return nil }
        guard let storedWorld = try statement.text(0, maximumBytes: 64),
              let schemaVersion = UInt16(exactly: try statement.int64(1)),
              let source = try statement.data(2, maximumBytes: 32),
              let destination = try statement.data(3, maximumBytes: 32),
              let revision = UInt64(exactly: try statement.int64(4)) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let row = try ElysiumRPGLegacyQuickSlotMigrationStorageRow(
            worldRecordID: storedWorld, schemaVersion: schemaVersion, sourceDigest: source,
            destinationDigest: destination, destinationRevision: revision)
        guard storedWorld == worldRecordID, try statement.step() == .done else {
            throw ElysiumStorageError.schemaIntegrity
        }
        return row
    }
}

private func proveRPGWorldParent(_ context: StorageContext, worldRecordID: String) throws {
    try withStatement(context, "SELECT count(*) FROM worlds WHERE id=?") { statement in
        try statement.bindText(1, worldRecordID)
        guard try statement.step() == .row, try statement.int64(0) == 1,
              try statement.step() == .done else {
            throw ElysiumStorageError.invalidValue
        }
    }
}

private struct RPGLocalIntegrityState {
    let preference: ElysiumRPGLocalPreferenceStorageRow?
    let marker: ElysiumRPGLegacyQuickSlotMigrationStorageRow?
    let accounting: RPGLocalStorageAccounting
    let parentExists: Bool
}

private func validateRPGLocalIntegrity(
    _ context: StorageContext, worldRecordID: String, requireParent: Bool
) throws -> RPGLocalIntegrityState {
    let accounting = try readRPGLocalAccounting(context)
    let preference = try readRPGPreference(context, worldRecordID: worldRecordID)
    let marker = try readRPGMigrationMarker(context, worldRecordID: worldRecordID)
    let parentCount: Int64 = try withStatement(
        context, "SELECT count(*) FROM worlds WHERE id=?"
    ) { statement in
        try statement.bindText(1, worldRecordID)
        guard try statement.step() == .row else { throw ElysiumStorageError.schemaIntegrity }
        let value = try statement.int64(0)
        guard try statement.step() == .done, (0...1).contains(value) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        return value
    }
    if requireParent, parentCount != 1 { throw ElysiumStorageError.invalidValue }
    guard preference == nil || parentCount == 1,
          marker == nil || preference != nil else {
        throw ElysiumStorageError.schemaIntegrity
    }
    switch (preference, marker) {
    case (nil, nil): break
    case let (preference?, nil):
        guard preference.migrationOriginDigest == nil,
              preference.migrationOriginRevision == nil else {
            throw ElysiumStorageError.schemaIntegrity
        }
    case let (preference?, marker?):
        guard preference.schemaVersion == marker.schemaVersion,
              preference.worldRecordID == marker.worldRecordID,
              preference.migrationOriginDigest != nil,
              preference.migrationOriginRevision != nil,
              preference.migrationOriginDigest.map({
                storageFixedTimeEqual($0, marker.destinationDigest)
              }) == true,
              preference.migrationOriginRevision == marker.destinationRevision else {
            throw ElysiumStorageError.schemaIntegrity
        }
    case (nil, _?):
        throw ElysiumStorageError.schemaIntegrity
    }
    return RPGLocalIntegrityState(
        preference: preference, marker: marker, accounting: accounting,
        parentExists: parentCount == 1)
}

private func insertRPGPreference(_ context: StorageContext,
                                 _ row: ElysiumRPGLocalPreferenceStorageRow,
                                 legacyMaterializationStatementIndex: Int? = nil) throws {
    let sql: StaticString = """
        INSERT INTO rpg_local_preferences_v1(
          world_record_id,schema_version,revision,slots_payload,payload_digest,
          migration_origin_digest,migration_origin_revision) VALUES(?,?,?,?,?,?,?)
        """
    let bind: (StorageStatement) throws -> Void = { statement in
        try statement.bindText(1, row.worldRecordID)
        try statement.bindInt64(2, Int64(row.schemaVersion))
        try statement.bindInt64(3, Int64(row.revision))
        try statement.bindData(4, row.slotsPayload)
        try statement.bindData(5, row.payloadDigest)
        if let digest = row.migrationOriginDigest { try statement.bindData(6, digest) }
        else { try statement.bindNull(6) }
        if let revision = row.migrationOriginRevision {
            try statement.bindInt64(7, Int64(revision))
        } else { try statement.bindNull(7) }
    }
    let changes: Int
    if let statementIndex = legacyMaterializationStatementIndex {
        changes = try executeLegacyMaterializationMutation(
            context, statementIndex: statementIndex, sql, bind: bind)
    } else {
        changes = try executeMutation(context, sql, bind: bind)
    }
    guard changes == 1 else { throw ElysiumStorageError.schemaIntegrity }
}

public final class ElysiumRPGLocalPreferencesStorage {
    private let executor: StorageExecutor

    fileprivate init(executor: StorageExecutor) { self.executor = executor }

    public func read(worldRecordID: String) throws -> ElysiumRPGLocalPreferenceStorageRow? {
        try StorageBounds.validateRPGWorldRecordID(worldRecordID)
        return try executor.rpgLocalPreferencesRead { context in
            try validateRPGLocalIntegrity(
                context, worldRecordID: worldRecordID, requireParent: false).preference
        }
    }

    public func materializeIfAbsent(
        candidate: ElysiumRPGLocalPreferenceStorageRow
    ) throws -> ElysiumRPGLocalPreferenceStorageRow {
        guard candidate.revision == 1, candidate.migrationOriginDigest == nil,
              candidate.migrationOriginRevision == nil else {
            throw ElysiumStorageError.invalidValue
        }
        return try executor.rpgLocalPreferencesWrite { context in
            let state = try validateRPGLocalIntegrity(
                context, worldRecordID: candidate.worldRecordID, requireParent: true)
            let accounting = state.accounting
            if let existing = state.preference {
                return existing
            }
            guard accounting.preferenceCount < 256,
                  accounting.totalBytes + rpgPreferenceAccountedBytes(candidate) <= 1_048_576 else {
                throw ElysiumStorageError.limitExceeded
            }
            try insertRPGPreference(context, candidate)
            let post = try validateRPGLocalIntegrity(
                context, worldRecordID: candidate.worldRecordID, requireParent: true)
            guard let stored = post.preference,
                  stored == candidate else { throw ElysiumStorageError.schemaIntegrity }
            return stored
        }
    }

    public func compareAndSwap(
        expectedRevision: UInt64, expectedDigest: Data,
        candidate: ElysiumRPGLocalPreferenceStorageRow
    ) throws -> ElysiumRPGLocalPreferenceStorageRow {
        guard (1...999_999_999).contains(expectedRevision), expectedDigest.count == 32,
              candidate.revision == expectedRevision + 1 else {
            throw ElysiumStorageError.invalidValue
        }
        return try executor.rpgLocalPreferencesWrite { context in
            let state = try validateRPGLocalIntegrity(
                context, worldRecordID: candidate.worldRecordID, requireParent: true)
            let accounting = state.accounting
            guard let existing = state.preference,
                  existing.revision == expectedRevision,
                  storageFixedTimeEqual(existing.payloadDigest, expectedDigest),
                  existing.migrationOriginDigest == candidate.migrationOriginDigest,
                  existing.migrationOriginRevision == candidate.migrationOriginRevision else {
                throw ElysiumStorageError.invalidValue
            }
            let newTotal = accounting.totalBytes - rpgPreferenceAccountedBytes(existing)
                + rpgPreferenceAccountedBytes(candidate)
            guard (0...1_048_576).contains(newTotal) else {
                throw ElysiumStorageError.limitExceeded
            }
            let changes = try executeMutation(context, """
                UPDATE rpg_local_preferences_v1 SET
                  schema_version=?,revision=?,slots_payload=?,payload_digest=?,
                  migration_origin_digest=?,migration_origin_revision=?
                WHERE world_record_id=? AND revision=? AND payload_digest=?
                """) { statement in
                try statement.bindInt64(1, Int64(candidate.schemaVersion))
                try statement.bindInt64(2, Int64(candidate.revision))
                try statement.bindData(3, candidate.slotsPayload)
                try statement.bindData(4, candidate.payloadDigest)
                if let digest = candidate.migrationOriginDigest { try statement.bindData(5, digest) }
                else { try statement.bindNull(5) }
                if let revision = candidate.migrationOriginRevision {
                    try statement.bindInt64(6, Int64(revision))
                } else { try statement.bindNull(6) }
                try statement.bindText(7, candidate.worldRecordID)
                try statement.bindInt64(8, Int64(expectedRevision))
                try statement.bindData(9, expectedDigest)
            }
            let post = try validateRPGLocalIntegrity(
                context, worldRecordID: candidate.worldRecordID, requireParent: true)
            guard changes == 1, let stored = post.preference, stored == candidate else {
                throw ElysiumStorageError.schemaIntegrity
            }
            return stored
        }
    }

    public func materializeLegacy(
        sourceDigest: Data, absentDestination: ElysiumRPGLocalPreferenceStorageRow
    ) throws -> ElysiumRPGLocalPreferenceMigrationReceipt {
        guard sourceDigest.count == 32, absentDestination.revision == 1,
              absentDestination.migrationOriginDigest == nil,
              absentDestination.migrationOriginRevision == nil else {
            throw ElysiumStorageError.invalidValue
        }
        return try executor.rpgLocalPreferencesLegacyMaterialization { context in
            let initial = try validateRPGLocalIntegrity(
                context, worldRecordID: absentDestination.worldRecordID,
                requireParent: true)
            var accounting = initial.accounting
            var preference = initial.preference
            var marker = initial.marker
            var insertedDestination = false
            if preference == nil {
                guard accounting.preferenceCount < 256,
                      accounting.totalBytes + rpgPreferenceAccountedBytes(absentDestination)
                        <= 1_048_576 else { throw ElysiumStorageError.limitExceeded }
                try insertRPGPreference(
                    context, absentDestination, legacyMaterializationStatementIndex: 0)
                preference = absentDestination
                insertedDestination = true
                accounting = RPGLocalStorageAccounting(
                    preferenceCount: accounting.preferenceCount + 1,
                    markerCount: accounting.markerCount,
                    totalBytes: accounting.totalBytes
                        + rpgPreferenceAccountedBytes(absentDestination))
            }
            guard var chosen = preference else { throw ElysiumStorageError.schemaIntegrity }
            if marker == nil {
                guard chosen.migrationOriginDigest == nil,
                      chosen.migrationOriginRevision == nil else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                let originAddedBytes: Int64 = 40
                let newMarker = try ElysiumRPGLegacyQuickSlotMigrationStorageRow(
                    worldRecordID: chosen.worldRecordID, schemaVersion: 1,
                    sourceDigest: sourceDigest, destinationDigest: chosen.payloadDigest,
                    destinationRevision: chosen.revision)
                guard accounting.markerCount < 256,
                      accounting.totalBytes + originAddedBytes
                        + rpgMarkerAccountedBytes(newMarker) <= 1_048_576 else {
                    throw ElysiumStorageError.limitExceeded
                }
                let updated = try executeLegacyMaterializationMutation(
                    context, statementIndex: 1, """
                    UPDATE rpg_local_preferences_v1 SET
                      migration_origin_digest=?,migration_origin_revision=?
                    WHERE world_record_id=? AND migration_origin_digest IS NULL
                      AND migration_origin_revision IS NULL
                    """) { statement in
                    try statement.bindData(1, chosen.payloadDigest)
                    try statement.bindInt64(2, Int64(chosen.revision))
                    try statement.bindText(3, chosen.worldRecordID)
                }
                guard updated == 1 else { throw ElysiumStorageError.schemaIntegrity }
                let inserted = try executeLegacyMaterializationMutation(
                    context, statementIndex: 2, """
                    INSERT INTO rpg_local_preference_migrations_v1(
                      world_record_id,schema_version,source_digest,destination_digest,
                      destination_revision) VALUES(?,?,?,?,?)
                    """) { statement in
                    try statement.bindText(1, newMarker.worldRecordID)
                    try statement.bindInt64(2, Int64(newMarker.schemaVersion))
                    try statement.bindData(3, newMarker.sourceDigest)
                    try statement.bindData(4, newMarker.destinationDigest)
                    try statement.bindInt64(5, Int64(newMarker.destinationRevision))
                }
                guard inserted == 1 else { throw ElysiumStorageError.schemaIntegrity }
                marker = newMarker
                guard let reread = try readRPGPreference(
                    context, worldRecordID: chosen.worldRecordID) else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                chosen = reread
            }
#if DEBUG
            try context.executor?.injectActiveRPGLocalFailure(.postcondition)
#endif
            let post = try validateRPGLocalIntegrity(
                context, worldRecordID: chosen.worldRecordID, requireParent: true)
            guard let finalMarker = marker,
                  storageFixedTimeEqual(finalMarker.sourceDigest, sourceDigest),
                  chosen.migrationOriginDigest == finalMarker.destinationDigest,
                  chosen.migrationOriginRevision == finalMarker.destinationRevision,
                  let finalPreference = post.preference,
                  let rereadMarker = post.marker,
                  finalPreference == chosen, rereadMarker == finalMarker else {
                throw ElysiumStorageError.schemaIntegrity
            }
            return ElysiumRPGLocalPreferenceMigrationReceipt(
                preference: finalPreference, marker: finalMarker,
                insertedDestination: insertedDestination)
        }
    }
}

public final class ElysiumClientAuthorityCheckpointV6Storage {
    private let executor: StorageExecutor

    fileprivate init(executor: StorageExecutor) { self.executor = executor }

    public func load(
        key: ElysiumLANClientAuthorityStorageKey
    ) throws -> ElysiumLANClientAuthorityCheckpointSnapshot {
        try loadClientAuthoritySnapshot(executor: executor, key: key)
    }

    public func commit(
        _ candidate: ElysiumLANClientAuthorityCheckpointCandidate
    ) throws -> ElysiumLANClientAuthorityCheckpointReceipt {
        try commitClientAuthorityCheckpoint(executor: executor, candidate: candidate)
    }

    public func oldestPendingNotice(
        key: ElysiumLANClientAuthorityStorageKey
    ) throws -> ElysiumLANClientNotificationStorageRow? {
        try loadOldestClientNotice(executor: executor, key: key)
    }

    public func acknowledgeNotice(
        key: ElysiumLANClientAuthorityStorageKey, notificationID: Data,
        expectedPayloadDigest: Data, expectedAcknowledgementGeneration: UInt64
    ) throws -> ElysiumLANClientNotificationStorageRow {
        try acknowledgeClientNotice(
            executor: executor, key: key, notificationID: notificationID,
            expectedPayloadDigest: expectedPayloadDigest,
            expectedAcknowledgementGeneration: expectedAcknowledgementGeneration)
    }
}

private func loadClientAuthoritySnapshot(
    executor: StorageExecutor, key: ElysiumLANClientAuthorityStorageKey
) throws -> ElysiumLANClientAuthorityCheckpointSnapshot {
    try executor.clientAuthorityRead { context in
        try verifyClientAuthorityCaps(context, key: key)
        guard let credential = try readClientCredential(context, key: key) else {
            throw ElysiumStorageError.invalidValue
        }
        let owner = try readClientOwner(context, key: key)
        let pending = try readClientPending(context, key: key)
        try validateClientAuthorityRowDigests(
            credential: credential, owner: owner, pending: pending)
        let notice = try readOldestClientNotice(context, key: key)
        let expectedAggregate = clientAggregateDigest(
            credential: credential, owner: owner, pending: pending)
        guard storageFixedTimeEqual(expectedAggregate, credential.aggregateDigest) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        return try ElysiumLANClientAuthorityCheckpointSnapshot(
            credential: credential, owner: owner, pending: pending,
            oldestPendingNotice: notice)
    }
}

private func commitClientAuthorityCheckpoint(
    executor: StorageExecutor, candidate: ElysiumLANClientAuthorityCheckpointCandidate
) throws -> ElysiumLANClientAuthorityCheckpointReceipt {
    try executor.clientAuthorityWrite { context in
        try verifyClientAuthorityCaps(context, key: candidate.key)
        guard let oldCredential = try readClientCredential(context, key: candidate.key),
              oldCredential.aggregateGeneration == candidate.expectedAggregateGeneration,
              storageFixedTimeEqual(oldCredential.aggregateDigest,
                                    candidate.expectedAggregateDigest) else {
            throw ElysiumStorageError.invalidValue
        }
        let oldOwner = try readClientOwner(context, key: candidate.key)
        let oldPending = try readClientPending(context, key: candidate.key)
        guard oldOwner.map({ oldCredential.aggregateGeneration >= 1
            && $0.lastChangeGeneration >= 1
            && $0.lastChangeGeneration <= oldCredential.aggregateGeneration }) ?? true,
              oldPending.map({ oldCredential.aggregateGeneration >= 1
                && $0.lastChangeGeneration >= 1
                && $0.lastChangeGeneration <= oldCredential.aggregateGeneration }) ?? true else {
            throw ElysiumStorageError.schemaIntegrity
        }
        try validateClientAuthorityRowDigests(
            credential: oldCredential, owner: oldOwner, pending: oldPending)
        guard storageFixedTimeEqual(
            clientAggregateDigest(credential: oldCredential, owner: oldOwner,
                                  pending: oldPending),
            oldCredential.aggregateDigest) else {
            throw ElysiumStorageError.schemaIntegrity
        }

        let newGeneration = candidate.credential.aggregateGeneration
        let finalOwner: ElysiumLANClientOwnerCheckpointStorageRow?
        switch candidate.ownerChange {
        case .unchanged:
            finalOwner = oldOwner
        case let .set(row):
            guard row.lastChangeGeneration == newGeneration else {
                throw ElysiumStorageError.invalidValue
            }
            finalOwner = row
        case let .remove(expectedDigest):
            guard let oldOwner,
                  storageFixedTimeEqual(oldOwner.payloadDigest, expectedDigest) else {
                throw ElysiumStorageError.invalidValue
            }
            finalOwner = nil
        }
        let finalPending: ElysiumLANClientPendingDispositionStorageRow?
        switch candidate.pendingChange {
        case .unchanged:
            finalPending = oldPending
        case let .set(row):
            guard row.lastChangeGeneration == newGeneration else {
                throw ElysiumStorageError.invalidValue
            }
            finalPending = row
        case let .remove(expectedDigest):
            guard let oldPending,
                  storageFixedTimeEqual(oldPending.payloadDigest, expectedDigest) else {
                throw ElysiumStorageError.invalidValue
            }
            finalPending = nil
        }

        switch candidate.transition {
        case .firstRequestZeroBind:
            guard !oldCredential.authorityBound,
                  oldCredential.aggregateGeneration == 0,
                  candidate.credential.authorityBound,
                  newGeneration == 1,
                  oldOwner == nil, oldPending == nil,
                  candidate.noticeInsert == nil,
                  case .set = candidate.ownerChange,
                  case .unchanged = candidate.pendingChange else {
                throw ElysiumStorageError.invalidValue
            }
            try verifyFirstClientAuthorityBind(
                oldPayload: oldCredential.payload,
                candidatePayload: candidate.credential.payload)
        case .ordinary:
            guard oldCredential.authorityBound,
                  oldCredential.aggregateGeneration >= 1,
                  candidate.credential.authorityBound else {
                throw ElysiumStorageError.invalidValue
            }
        }
        guard storageFixedTimeEqual(
            clientAggregateDigest(credential: candidate.credential, owner: finalOwner,
                                  pending: finalPending),
            candidate.credential.aggregateDigest) else {
            throw ElysiumStorageError.invalidValue
        }
        try validateClientAuthorityRowDigests(
            credential: candidate.credential, owner: finalOwner, pending: finalPending)
        let pruneNotificationIDs = try preflightClientCandidateCaps(
            context, oldCredential: oldCredential, oldOwner: oldOwner,
            oldPending: oldPending, candidate: candidate, finalOwner: finalOwner,
            finalPending: finalPending)

        for notificationID in pruneNotificationIDs {
            let changes = try executeMutation(context, """
                DELETE FROM lan_client_notification_inbox_v6
                WHERE hid=? AND wid=? AND lookup_digest=? AND notification_id=?
                  AND acknowledgement_state=1 AND acknowledgement_generation=1
                """) { statement in
                try bindClientKey(statement, key: candidate.key)
                try statement.bindData(4, notificationID)
            }
            guard changes == 1 else { throw ElysiumStorageError.schemaIntegrity }
        }

        switch candidate.ownerChange {
        case .unchanged: break
        case let .set(row):
            if let oldOwner {
                let changes = try executeMutation(context, """
                    UPDATE lan_client_owner_checkpoint_v6 SET
                      schema_version=?,last_change_generation=?,payload=?,payload_digest=?
                    WHERE hid=? AND wid=? AND lookup_digest=? AND payload_digest=?
                    """) { statement in
                    try statement.bindInt64(1, Int64(row.schemaVersion))
                    try statement.bindInt64(2, Int64(row.lastChangeGeneration))
                    try statement.bindData(3, row.payload)
                    try statement.bindData(4, row.payloadDigest)
                    try bindClientKey(statement, key: row.key, startingAt: 5)
                    try statement.bindData(8, oldOwner.payloadDigest)
                }
                guard changes == 1 else { throw ElysiumStorageError.invalidValue }
            } else {
                try insertClientOwner(context, row: row)
            }
        case let .remove(expectedDigest):
            let changes = try executeMutation(context, """
                DELETE FROM lan_client_owner_checkpoint_v6
                WHERE hid=? AND wid=? AND lookup_digest=? AND payload_digest=?
                """) { statement in
                try bindClientKey(statement, key: candidate.key)
                try statement.bindData(4, expectedDigest)
            }
            guard changes == 1 else { throw ElysiumStorageError.invalidValue }
        }

        switch candidate.pendingChange {
        case .unchanged: break
        case let .set(row):
            if let oldPending {
                let changes = try executeMutation(context, """
                    UPDATE lan_client_pending_disposition_v6 SET
                      schema_version=?,last_change_generation=?,mode=?,payload=?,payload_digest=?
                    WHERE hid=? AND wid=? AND lookup_digest=? AND payload_digest=?
                    """) { statement in
                    try statement.bindInt64(1, Int64(row.schemaVersion))
                    try statement.bindInt64(2, Int64(row.lastChangeGeneration))
                    try statement.bindInt64(3, Int64(row.mode.rawValue))
                    try statement.bindData(4, row.payload)
                    try statement.bindData(5, row.payloadDigest)
                    try bindClientKey(statement, key: row.key, startingAt: 6)
                    try statement.bindData(9, oldPending.payloadDigest)
                }
                guard changes == 1 else { throw ElysiumStorageError.invalidValue }
            } else {
                try insertClientPending(context, row: row)
            }
        case let .remove(expectedDigest):
            let changes = try executeMutation(context, """
                DELETE FROM lan_client_pending_disposition_v6
                WHERE hid=? AND wid=? AND lookup_digest=? AND payload_digest=?
                """) { statement in
                try bindClientKey(statement, key: candidate.key)
                try statement.bindData(4, expectedDigest)
            }
            guard changes == 1 else { throw ElysiumStorageError.invalidValue }
        }

        if let notice = candidate.noticeInsert {
            if let existing = try readClientNotice(
                context, key: notice.key, notificationID: notice.notificationID) {
                guard storageFixedTimeEqual(existing.payloadDigest, notice.payloadDigest) else {
                    throw ElysiumStorageError.invalidValue
                }
            } else {
                try insertClientNotice(context, row: notice)
            }
        }
        let credentialChanges = try executeMutation(context, """
            UPDATE lan_client_credentials_v6 SET
              schema_version=?,aggregate_generation=?,aggregate_digest=?,authority_bound=?,
              payload=?,payload_digest=?
            WHERE hid=? AND wid=? AND lookup_digest=?
              AND aggregate_generation=? AND aggregate_digest=?
            """) { statement in
            let row = candidate.credential
            try statement.bindInt64(1, Int64(row.schemaVersion))
            try statement.bindInt64(2, Int64(row.aggregateGeneration))
            try statement.bindData(3, row.aggregateDigest)
            try statement.bindInt64(4, row.authorityBound ? 1 : 0)
            try statement.bindData(5, row.payload)
            try statement.bindData(6, row.payloadDigest)
            try bindClientKey(statement, key: row.key, startingAt: 7)
            try statement.bindInt64(10, Int64(candidate.expectedAggregateGeneration))
            try statement.bindData(11, candidate.expectedAggregateDigest)
        }
        guard credentialChanges == 1 else { throw ElysiumStorageError.invalidValue }
        try verifyClientAuthorityCaps(context, key: candidate.key)
        guard let storedCredential = try readClientCredential(context, key: candidate.key),
              clientCredentialMatches(storedCredential, candidate.credential) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let storedOwner = try readClientOwner(context, key: candidate.key)
        let storedPending = try readClientPending(context, key: candidate.key)
        guard clientOwnerMatches(storedOwner, finalOwner),
              clientPendingMatches(storedPending, finalPending),
              storageFixedTimeEqual(
                clientAggregateDigest(credential: storedCredential, owner: storedOwner,
                                      pending: storedPending),
                storedCredential.aggregateDigest) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let snapshot = try ElysiumLANClientAuthorityCheckpointSnapshot(
            credential: storedCredential, owner: storedOwner, pending: storedPending,
            oldestPendingNotice: try readOldestClientNotice(context, key: candidate.key))
        return try ElysiumLANClientAuthorityCheckpointReceipt(
            snapshot: snapshot, committedAggregateGeneration: newGeneration,
            committedAggregateDigest: storedCredential.aggregateDigest)
    }
}

private func loadOldestClientNotice(
    executor: StorageExecutor, key: ElysiumLANClientAuthorityStorageKey
) throws -> ElysiumLANClientNotificationStorageRow? {
    try executor.clientAuthorityRead { context in
        try verifyClientAuthorityCaps(context, key: key)
        return try readOldestClientNotice(context, key: key)
    }
}

private func acknowledgeClientNotice(
    executor: StorageExecutor, key: ElysiumLANClientAuthorityStorageKey,
    notificationID: Data, expectedPayloadDigest: Data,
    expectedAcknowledgementGeneration: UInt64
) throws -> ElysiumLANClientNotificationStorageRow {
    guard notificationID.count == 32, expectedPayloadDigest.count == 32,
          expectedAcknowledgementGeneration == 0 else {
        throw ElysiumStorageError.invalidValue
    }
    return try executor.clientNoticeAcknowledgement { context in
        let changes = try executeMutation(context, """
            UPDATE lan_client_notification_inbox_v6 SET
              acknowledgement_state=1,acknowledgement_generation=1
            WHERE hid=? AND wid=? AND lookup_digest=? AND notification_id=?
              AND payload_digest=? AND acknowledgement_state=0
              AND acknowledgement_generation=?
            """) { statement in
            try bindClientKey(statement, key: key)
            try statement.bindData(4, notificationID)
            try statement.bindData(5, expectedPayloadDigest)
            try statement.bindInt64(6, Int64(expectedAcknowledgementGeneration))
        }
        guard changes == 1,
              let row = try readClientNotice(
                context, key: key, notificationID: notificationID),
              row.acknowledgement == .acknowledged,
              row.acknowledgementGeneration == 1,
              storageFixedTimeEqual(row.payloadDigest, expectedPayloadDigest) else {
            throw ElysiumStorageError.invalidValue
        }
        return row
    }
}

private func bindClientKey(_ statement: StorageStatement,
                           key: ElysiumLANClientAuthorityStorageKey,
                           startingAt index: Int32 = 1) throws {
    try statement.bindData(index, key.hostInstallationID)
    try statement.bindData(index + 1, key.worldLANID)
    try statement.bindData(index + 2, key.lookupDigest)
}

private func clientUInt64BE(_ value: UInt64) -> Data {
    var result = Data()
    for shift in stride(from: 56, through: 0, by: -8) {
        result.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
    }
    return result
}

private func clientAggregateDigest(
    credential: ElysiumLANClientCredentialStorageRow,
    owner: ElysiumLANClientOwnerCheckpointStorageRow?,
    pending: ElysiumLANClientPendingDispositionStorageRow?
) -> Data {
    var input = Data("Pebble/LANv6/client-checkpoint-aggregate/v1\0".utf8)
    input.append(credential.key.hostInstallationID)
    input.append(credential.key.worldLANID)
    input.append(credential.key.lookupDigest)
    input.append(clientUInt64BE(credential.aggregateGeneration))
    input.append(credential.payloadDigest)
    if let owner {
        input.append(1); input.append(clientUInt64BE(owner.lastChangeGeneration))
        input.append(owner.payloadDigest)
    } else { input.append(0) }
    if let pending {
        input.append(1); input.append(clientUInt64BE(pending.lastChangeGeneration))
        input.append(pending.payloadDigest)
    } else { input.append(0) }
    return storageSHA256(input)
}

private func clientKeyBytes(_ key: ElysiumLANClientAuthorityStorageKey) -> Data {
    var bytes = key.hostInstallationID
    bytes.append(key.worldLANID); bytes.append(key.lookupDigest)
    return bytes
}

private func clientRowDigest(domain: String, key: ElysiumLANClientAuthorityStorageKey,
                             generation: UInt64, suffix: Data) -> Data {
    var input = Data((domain + "\0").utf8)
    input.append(clientKeyBytes(key)); input.append(clientUInt64BE(generation)); input.append(suffix)
    return storageSHA256(input)
}

private func validateClientAuthorityRowDigests(
    credential: ElysiumLANClientCredentialStorageRow,
    owner: ElysiumLANClientOwnerCheckpointStorageRow?,
    pending: ElysiumLANClientPendingDispositionStorageRow?
) throws {
    guard storageFixedTimeEqual(
        clientRowDigest(domain: "Pebble/LANv6/client-credential/v1",
                        key: credential.key, generation: credential.aggregateGeneration,
                        suffix: credential.payload), credential.payloadDigest) else {
        throw ElysiumStorageError.schemaIntegrity
    }
    if let owner {
        guard storageFixedTimeEqual(
            clientRowDigest(domain: "Pebble/LANv6/client-owner/v1", key: owner.key,
                            generation: owner.lastChangeGeneration, suffix: owner.payload),
            owner.payloadDigest) else { throw ElysiumStorageError.schemaIntegrity }
    }
    if let pending {
        var suffix = Data([pending.mode.rawValue]); suffix.append(pending.payload)
        guard storageFixedTimeEqual(
            clientRowDigest(domain: "Pebble/LANv6/client-pending/v1", key: pending.key,
                            generation: pending.lastChangeGeneration, suffix: suffix),
            pending.payloadDigest) else { throw ElysiumStorageError.schemaIntegrity }
    }
}

private func clientCredentialMatches(
    _ lhs: ElysiumLANClientCredentialStorageRow,
    _ rhs: ElysiumLANClientCredentialStorageRow
) -> Bool {
    lhs.key == rhs.key && lhs.schemaVersion == rhs.schemaVersion
        && lhs.aggregateGeneration == rhs.aggregateGeneration
        && storageFixedTimeEqual(lhs.aggregateDigest, rhs.aggregateDigest)
        && lhs.authorityBound == rhs.authorityBound
        && storageFixedTimeEqual(lhs.payload, rhs.payload)
        && storageFixedTimeEqual(lhs.payloadDigest, rhs.payloadDigest)
}

private func clientOwnerMatches(
    _ lhs: ElysiumLANClientOwnerCheckpointStorageRow?,
    _ rhs: ElysiumLANClientOwnerCheckpointStorageRow?
) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (lhs?, rhs?):
        return lhs.key == rhs.key && lhs.schemaVersion == rhs.schemaVersion
            && lhs.lastChangeGeneration == rhs.lastChangeGeneration
            && storageFixedTimeEqual(lhs.payload, rhs.payload)
            && storageFixedTimeEqual(lhs.payloadDigest, rhs.payloadDigest)
    default: return false
    }
}

private func clientPendingMatches(
    _ lhs: ElysiumLANClientPendingDispositionStorageRow?,
    _ rhs: ElysiumLANClientPendingDispositionStorageRow?
) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (lhs?, rhs?):
        return lhs.key == rhs.key && lhs.schemaVersion == rhs.schemaVersion
            && lhs.lastChangeGeneration == rhs.lastChangeGeneration && lhs.mode == rhs.mode
            && storageFixedTimeEqual(lhs.payload, rhs.payload)
            && storageFixedTimeEqual(lhs.payloadDigest, rhs.payloadDigest)
    default: return false
    }
}

private struct ClientCredentialEnvelope {
    let activeGeneration: UInt64?
    let activeToken: Data?
    let pendingGeneration: UInt64?
    let pendingToken: Data?
}

private func decodeClientCredentialEnvelope(_ payload: Data) throws
    -> ClientCredentialEnvelope {
    let bytes = [UInt8](payload)
    guard bytes.count >= 9, Array(bytes[0..<6]) == Array("PBLCC1".utf8),
          bytes[6] == 0, bytes[7] == 1, bytes[8] & 0xFC == 0 else {
        throw ElysiumStorageError.invalidValue
    }
    var cursor = 9
    func readUInt64() throws -> UInt64 {
        guard cursor + 8 <= bytes.count else { throw ElysiumStorageError.invalidValue }
        var value: UInt64 = 0
        for byte in bytes[cursor..<(cursor + 8)] { value = value << 8 | UInt64(byte) }
        cursor += 8
        return value
    }
    func readData(_ count: Int) throws -> Data {
        guard cursor + count <= bytes.count else { throw ElysiumStorageError.invalidValue }
        defer { cursor += count }
        return Data(bytes[cursor..<(cursor + count)])
    }
    var activeGeneration: UInt64?
    var activeToken: Data?
    if bytes[8] & 1 != 0 {
        activeGeneration = try readUInt64()
        activeToken = try readData(32)
    }
    var pendingGeneration: UInt64?
    var pendingToken: Data?
    if bytes[8] & 2 != 0 {
        pendingGeneration = try readUInt64()
        pendingToken = try readData(32)
        _ = try readData(16)
        _ = try readUInt64()
    }
    guard cursor == bytes.count,
          activeGeneration.map({ (1...1_000_000_000).contains($0) }) ?? true,
          pendingGeneration.map({ (1...1_000_000_000).contains($0) }) ?? true else {
        throw ElysiumStorageError.invalidValue
    }
    return ClientCredentialEnvelope(
        activeGeneration: activeGeneration, activeToken: activeToken,
        pendingGeneration: pendingGeneration, pendingToken: pendingToken)
}

private func verifyFirstClientAuthorityBind(oldPayload: Data,
                                            candidatePayload: Data) throws {
    let old = try decodeClientCredentialEnvelope(oldPayload)
    let new = try decodeClientCredentialEnvelope(candidatePayload)
    guard old.activeGeneration == nil, old.activeToken == nil,
          old.pendingGeneration == 1, let pendingToken = old.pendingToken,
          new.activeGeneration == 1, let activeToken = new.activeToken,
          new.pendingGeneration == nil, new.pendingToken == nil,
          storageFixedTimeEqual(pendingToken, activeToken) else {
        throw ElysiumStorageError.invalidValue
    }
}

private func insertClientOwner(
    _ context: StorageContext, row: ElysiumLANClientOwnerCheckpointStorageRow
) throws {
    let changes = try executeMutation(context, """
        INSERT INTO lan_client_owner_checkpoint_v6(
          hid,wid,lookup_digest,schema_version,last_change_generation,payload,payload_digest)
        VALUES(?,?,?,?,?,?,?)
        """) { statement in
        try bindClientKey(statement, key: row.key)
        try statement.bindInt64(4, Int64(row.schemaVersion))
        try statement.bindInt64(5, Int64(row.lastChangeGeneration))
        try statement.bindData(6, row.payload)
        try statement.bindData(7, row.payloadDigest)
    }
    guard changes == 1 else { throw ElysiumStorageError.schemaIntegrity }
}

private func insertClientPending(
    _ context: StorageContext, row: ElysiumLANClientPendingDispositionStorageRow
) throws {
    let changes = try executeMutation(context, """
        INSERT INTO lan_client_pending_disposition_v6(
          hid,wid,lookup_digest,schema_version,last_change_generation,mode,payload,payload_digest)
        VALUES(?,?,?,?,?,?,?,?)
        """) { statement in
        try bindClientKey(statement, key: row.key)
        try statement.bindInt64(4, Int64(row.schemaVersion))
        try statement.bindInt64(5, Int64(row.lastChangeGeneration))
        try statement.bindInt64(6, Int64(row.mode.rawValue))
        try statement.bindData(7, row.payload)
        try statement.bindData(8, row.payloadDigest)
    }
    guard changes == 1 else { throw ElysiumStorageError.schemaIntegrity }
}

private func insertClientNotice(
    _ context: StorageContext, row: ElysiumLANClientNotificationStorageRow
) throws {
    let changes = try executeMutation(context, """
        INSERT INTO lan_client_notification_inbox_v6(
          hid,wid,lookup_digest,notification_id,session_epoch,request_id,snapshot_id,status,
          creation_generation,acknowledgement_state,acknowledgement_generation,payload,
          payload_digest) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        """) { statement in
        try bindClientKey(statement, key: row.key)
        try statement.bindData(4, row.notificationID)
        try statement.bindData(5, row.sessionEpoch)
        try statement.bindInt64(6, Int64(row.requestID))
        try statement.bindData(7, row.snapshotID)
        try statement.bindInt64(8, Int64(row.status.rawValue))
        try statement.bindInt64(9, Int64(row.creationGeneration))
        try statement.bindInt64(10, Int64(row.acknowledgement.rawValue))
        try statement.bindInt64(11, Int64(row.acknowledgementGeneration))
        try statement.bindData(12, row.payload)
        try statement.bindData(13, row.payloadDigest)
    }
    guard changes == 1 else { throw ElysiumStorageError.schemaIntegrity }
}

private func verifyClientAuthorityCaps(
    _ context: StorageContext, key: ElysiumLANClientAuthorityStorageKey
) throws {
    try withStatement(context, """
        SELECT
          (SELECT count(*) FROM lan_client_credentials_v6),
          coalesce((SELECT sum(length(payload)) FROM lan_client_credentials_v6),0),
          (SELECT count(*) FROM lan_client_owner_checkpoint_v6),
          coalesce((SELECT sum(length(payload)) FROM lan_client_owner_checkpoint_v6),0),
          (SELECT count(*) FROM lan_client_pending_disposition_v6),
          coalesce((SELECT sum(length(payload)) FROM lan_client_pending_disposition_v6),0),
          (SELECT count(*) FROM lan_client_notification_inbox_v6),
          coalesce((SELECT sum(704+length(payload))
                    FROM lan_client_notification_inbox_v6),0)
        """) { statement in
        guard try statement.step() == .row else { throw ElysiumStorageError.schemaIntegrity }
        let values = try (0..<8).map { try statement.int64(Int32($0)) }
        guard try statement.step() == .done,
              values[0] <= 256, values[1] <= 16_777_216,
              values[2] <= 256, values[3] <= 201_326_592,
              values[4] <= 256, values[5] <= 33_554_432,
              values[6] <= 65_536, values[7] <= 268_435_456,
              values.allSatisfy({ $0 >= 0 }) else {
            throw ElysiumStorageError.schemaIntegrity
        }
    }
    try withStatement(context, """
        SELECT count(*),coalesce(sum(704+length(payload)),0)
        FROM lan_client_notification_inbox_v6
        WHERE hid=? AND wid=? AND lookup_digest=?
        """) { statement in
        try bindClientKey(statement, key: key)
        guard try statement.step() == .row,
              try statement.int64(0) <= 256, try statement.int64(1) <= 1_048_576,
              try statement.step() == .done else {
            throw ElysiumStorageError.schemaIntegrity
        }
    }
}

private func checkedClientAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow, value >= 0 else { throw ElysiumStorageError.limitExceeded }
    return value
}

private func checkedClientSubtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
    guard !overflow, value >= 0 else { throw ElysiumStorageError.schemaIntegrity }
    return value
}

private func replacingClientBytes(current: Int64, old: Data?, new: Data?) throws -> Int64 {
    var result = current
    if let old { result = try checkedClientSubtract(result, Int64(old.count)) }
    if let new { result = try checkedClientAdd(result, Int64(new.count)) }
    return result
}

private func preflightClientCandidateCaps(
    _ context: StorageContext,
    oldCredential: ElysiumLANClientCredentialStorageRow,
    oldOwner: ElysiumLANClientOwnerCheckpointStorageRow?,
    oldPending: ElysiumLANClientPendingDispositionStorageRow?,
    candidate: ElysiumLANClientAuthorityCheckpointCandidate,
    finalOwner: ElysiumLANClientOwnerCheckpointStorageRow?,
    finalPending: ElysiumLANClientPendingDispositionStorageRow?
) throws -> [Data] {
    let totals: [Int64] = try withStatement(context, """
        SELECT
          (SELECT count(*) FROM lan_client_credentials_v6),
          coalesce((SELECT sum(length(payload)) FROM lan_client_credentials_v6),0),
          (SELECT count(*) FROM lan_client_owner_checkpoint_v6),
          coalesce((SELECT sum(length(payload)) FROM lan_client_owner_checkpoint_v6),0),
          (SELECT count(*) FROM lan_client_pending_disposition_v6),
          coalesce((SELECT sum(length(payload)) FROM lan_client_pending_disposition_v6),0),
          (SELECT count(*) FROM lan_client_notification_inbox_v6),
          coalesce((SELECT sum(704+length(payload))
                    FROM lan_client_notification_inbox_v6),0)
        """) { statement in
        guard try statement.step() == .row else { throw ElysiumStorageError.schemaIntegrity }
        let values = try (0..<8).map { try statement.int64(Int32($0)) }
        guard try statement.step() == .done, values.allSatisfy({ $0 >= 0 }) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        return values
    }
    let credentialBytes = try replacingClientBytes(
        current: totals[1], old: oldCredential.payload,
        new: candidate.credential.payload)
    let ownerBytes = try replacingClientBytes(
        current: totals[3], old: oldOwner?.payload, new: finalOwner?.payload)
    let pendingBytes = try replacingClientBytes(
        current: totals[5], old: oldPending?.payload, new: finalPending?.payload)
    let ownerCount = try checkedClientAdd(
        try checkedClientSubtract(totals[2], oldOwner == nil ? 0 : 1),
        finalOwner == nil ? 0 : 1)
    let pendingCount = try checkedClientAdd(
        try checkedClientSubtract(totals[4], oldPending == nil ? 0 : 1),
        finalPending == nil ? 0 : 1)
    guard totals[0] <= 256, credentialBytes <= 16_777_216,
          ownerCount <= 256, ownerBytes <= 201_326_592,
          pendingCount <= 256, pendingBytes <= 33_554_432 else {
        throw ElysiumStorageError.limitExceeded
    }

    guard let notice = candidate.noticeInsert else { return [] }
    guard notice.acknowledgement == .pendingRender,
          notice.acknowledgementGeneration == 0,
          notice.creationGeneration == candidate.credential.aggregateGeneration else {
        throw ElysiumStorageError.invalidValue
    }
    if let existing = try readClientNotice(
        context, key: notice.key, notificationID: notice.notificationID) {
        guard storageFixedTimeEqual(existing.payloadDigest, notice.payloadDigest),
              storageFixedTimeEqual(existing.payload, notice.payload) else {
            throw ElysiumStorageError.invalidValue
        }
        return []
    }
    let addition = Int64(704 + notice.payload.count)
    let scope: (count: Int64, bytes: Int64) = try withStatement(context, """
        SELECT count(*),coalesce(sum(704+length(payload)),0)
        FROM lan_client_notification_inbox_v6
        WHERE hid=? AND wid=? AND lookup_digest=?
        """) { statement in
        try bindClientKey(statement, key: candidate.key)
        guard try statement.step() == .row else { throw ElysiumStorageError.schemaIntegrity }
        let value = (try statement.int64(0), try statement.int64(1))
        guard try statement.step() == .done, value.0 >= 0, value.1 >= 0 else {
            throw ElysiumStorageError.schemaIntegrity
        }
        return value
    }
    var projectedScopeCount = try checkedClientAdd(scope.count, 1)
    var projectedScopeBytes = try checkedClientAdd(scope.bytes, addition)
    var projectedGlobalCount = try checkedClientAdd(totals[6], 1)
    var projectedGlobalBytes = try checkedClientAdd(totals[7], addition)
    var pruned: [Data] = []
    if projectedScopeCount > 256 || projectedScopeBytes > 1_048_576 {
        let acknowledged: [(Data, Int64)] = try withStatement(context, """
            SELECT notification_id,704+length(payload)
            FROM lan_client_notification_inbox_v6
            WHERE hid=? AND wid=? AND lookup_digest=?
              AND acknowledgement_state=1 AND acknowledgement_generation=1
            ORDER BY acknowledgement_generation,notification_id LIMIT 257
            """) { statement in
            try bindClientKey(statement, key: candidate.key)
            var rows: [(Data, Int64)] = []
            while try statement.step() == .row {
                guard let id = try statement.data(0, maximumBytes: 32), id.count == 32 else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                let bytes = try statement.int64(1)
                guard (704...4_608).contains(bytes) else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                rows.append((id, bytes))
            }
            return rows
        }
        for (id, bytes) in acknowledged
            where projectedScopeCount > 256 || projectedScopeBytes > 1_048_576 {
            pruned.append(id)
            projectedScopeCount = try checkedClientSubtract(projectedScopeCount, 1)
            projectedScopeBytes = try checkedClientSubtract(projectedScopeBytes, bytes)
            projectedGlobalCount = try checkedClientSubtract(projectedGlobalCount, 1)
            projectedGlobalBytes = try checkedClientSubtract(projectedGlobalBytes, bytes)
        }
    }
    guard projectedScopeCount <= 256, projectedScopeBytes <= 1_048_576,
          projectedGlobalCount <= 65_536, projectedGlobalBytes <= 268_435_456 else {
        throw ElysiumStorageError.limitExceeded
    }
    return pruned
}

private func readClientCredential(
    _ context: StorageContext, key: ElysiumLANClientAuthorityStorageKey
) throws -> ElysiumLANClientCredentialStorageRow? {
    try withStatement(context, """
        SELECT schema_version,aggregate_generation,aggregate_digest,authority_bound,
               payload,payload_digest FROM lan_client_credentials_v6
        WHERE hid=? AND wid=? AND lookup_digest=?
        """) { statement in
        try bindClientKey(statement, key: key)
        guard try statement.step() == .row else { return nil }
        guard let schema = UInt16(exactly: try statement.int64(0)),
              let generation = UInt64(exactly: try statement.int64(1)),
              let aggregate = try statement.data(2, maximumBytes: 32),
              let payload = try statement.data(4, maximumBytes: 65_536),
              let digest = try statement.data(5, maximumBytes: 32) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let boundValue = try statement.int64(3)
        guard boundValue == 0 || boundValue == 1 else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let row = try ElysiumLANClientCredentialStorageRow(
            key: key, schemaVersion: schema, aggregateGeneration: generation,
            aggregateDigest: aggregate, authorityBound: boundValue == 1,
            payload: payload, payloadDigest: digest)
        guard try statement.step() == .done else { throw ElysiumStorageError.schemaIntegrity }
        return row
    }
}

private func readClientOwner(
    _ context: StorageContext, key: ElysiumLANClientAuthorityStorageKey
) throws -> ElysiumLANClientOwnerCheckpointStorageRow? {
    try withStatement(context, """
        SELECT schema_version,last_change_generation,payload,payload_digest
        FROM lan_client_owner_checkpoint_v6 WHERE hid=? AND wid=? AND lookup_digest=?
        """) { statement in
        try bindClientKey(statement, key: key)
        guard try statement.step() == .row else { return nil }
        guard let schema = UInt16(exactly: try statement.int64(0)),
              let generation = UInt64(exactly: try statement.int64(1)),
              let payload = try statement.data(2, maximumBytes: 786_432),
              let digest = try statement.data(3, maximumBytes: 32) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let row = try ElysiumLANClientOwnerCheckpointStorageRow(
            key: key, schemaVersion: schema, lastChangeGeneration: generation,
            payload: payload, payloadDigest: digest)
        guard try statement.step() == .done else { throw ElysiumStorageError.schemaIntegrity }
        return row
    }
}

private func readClientPending(
    _ context: StorageContext, key: ElysiumLANClientAuthorityStorageKey
) throws -> ElysiumLANClientPendingDispositionStorageRow? {
    try withStatement(context, """
        SELECT schema_version,last_change_generation,mode,payload,payload_digest
        FROM lan_client_pending_disposition_v6 WHERE hid=? AND wid=? AND lookup_digest=?
        """) { statement in
        try bindClientKey(statement, key: key)
        guard try statement.step() == .row else { return nil }
        guard let schema = UInt16(exactly: try statement.int64(0)),
              let generation = UInt64(exactly: try statement.int64(1)),
              let modeRaw = UInt8(exactly: try statement.int64(2)),
              let mode = ElysiumLANClientPendingMode(rawValue: modeRaw),
              let payload = try statement.data(3, maximumBytes: 131_072),
              let digest = try statement.data(4, maximumBytes: 32) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let row = try ElysiumLANClientPendingDispositionStorageRow(
            key: key, schemaVersion: schema, lastChangeGeneration: generation,
            mode: mode, payload: payload, payloadDigest: digest)
        guard try statement.step() == .done else { throw ElysiumStorageError.schemaIntegrity }
        return row
    }
}

private func materializeClientNotice(
    _ statement: StorageStatement, key: ElysiumLANClientAuthorityStorageKey
) throws -> ElysiumLANClientNotificationStorageRow {
    guard let notificationID = try statement.data(0, maximumBytes: 32),
          let sessionEpoch = try statement.data(1, maximumBytes: 16),
          let requestID = UInt64(exactly: try statement.int64(2)),
          let snapshotID = try statement.data(3, maximumBytes: 16),
          let statusRaw = UInt8(exactly: try statement.int64(4)),
          let status = ElysiumLANClientNoticeStatus(rawValue: statusRaw),
          let creation = UInt64(exactly: try statement.int64(5)),
          let acknowledgementRaw = UInt8(exactly: try statement.int64(6)),
          let acknowledgement = ElysiumLANClientNoticeAcknowledgement(
            rawValue: acknowledgementRaw),
          let acknowledgementGeneration = UInt64(exactly: try statement.int64(7)),
          let payload = try statement.data(8, maximumBytes: 4_096),
          let digest = try statement.data(9, maximumBytes: 32) else {
        throw ElysiumStorageError.schemaIntegrity
    }
    return try ElysiumLANClientNotificationStorageRow(
        key: key, notificationID: notificationID, sessionEpoch: sessionEpoch,
        requestID: requestID, snapshotID: snapshotID, status: status,
        creationGeneration: creation, acknowledgement: acknowledgement,
        acknowledgementGeneration: acknowledgementGeneration, payload: payload,
        payloadDigest: digest)
}

private func readClientNotice(
    _ context: StorageContext, key: ElysiumLANClientAuthorityStorageKey,
    notificationID: Data
) throws -> ElysiumLANClientNotificationStorageRow? {
    try withStatement(context, """
        SELECT notification_id,session_epoch,request_id,snapshot_id,status,
               creation_generation,acknowledgement_state,acknowledgement_generation,
               payload,payload_digest
        FROM lan_client_notification_inbox_v6
        WHERE hid=? AND wid=? AND lookup_digest=? AND notification_id=?
        """) { statement in
        try bindClientKey(statement, key: key)
        try statement.bindData(4, notificationID)
        guard try statement.step() == .row else { return nil }
        let row = try materializeClientNotice(statement, key: key)
        guard try statement.step() == .done else { throw ElysiumStorageError.schemaIntegrity }
        return row
    }
}

private func readOldestClientNotice(
    _ context: StorageContext, key: ElysiumLANClientAuthorityStorageKey
) throws -> ElysiumLANClientNotificationStorageRow? {
    try withStatement(context, """
        SELECT notification_id,session_epoch,request_id,snapshot_id,status,
               creation_generation,acknowledgement_state,acknowledgement_generation,
               payload,payload_digest
        FROM lan_client_notification_inbox_v6
        WHERE hid=? AND wid=? AND lookup_digest=? AND acknowledgement_state=0
        ORDER BY creation_generation,notification_id LIMIT 1
        """) { statement in
        try bindClientKey(statement, key: key)
        guard try statement.step() == .row else { return nil }
        let row = try materializeClientNotice(statement, key: key)
        guard try statement.step() == .done else { throw ElysiumStorageError.schemaIntegrity }
        return row
    }
}

public final class ElysiumLegacyCoreStorage {
    private let executor: StorageExecutor

    fileprivate init(executor: StorageExecutor) {
        self.executor = executor
    }

    public func verifyCoreSchema() throws {
        try executor.verifyCoreSchema()
    }

    public func prepareLegacyMigrationRename() throws {
        try executor.prepareLegacyMigrationRename()
    }

    // MARK: Narrow legacy compatibility reads

    public func listLegacyWorldJSON() throws -> [String] {
        try executor.legacyWorldCollection { context in
            let actualCount = try legacyCollectionCount(
                context, sql: "SELECT count(ROWID) FROM worlds",
                maximumRows: StorageBounds.worldRows)
            let expectedCount = try adjustedLegacyCollectionCount(actualCount, executor: executor)
            var scanned = 0
            var priorRowID: Int64?
            var accepted: [String] = []
            var acceptedBytes: Int64 = 0
            while true {
                let pageCount: Int
                if let cursor = priorRowID {
                    pageCount = try withStatement(context, """
                        SELECT ROWID,json FROM worlds WHERE ROWID>? ORDER BY ROWID LIMIT 256
                        """) { statement in
                        try statement.bindInt64(1, cursor)
                        return try scanLegacyWorldJSONPage(
                            statement, executor: executor, priorRowID: &priorRowID,
                            scanned: &scanned, expectedCount: expectedCount,
                            accepted: &accepted, acceptedBytes: &acceptedBytes)
                    }
                } else {
                    pageCount = try withStatement(context, """
                        SELECT ROWID,json FROM worlds ORDER BY ROWID LIMIT 256
                        """) { statement in
                        try scanLegacyWorldJSONPage(
                            statement, executor: executor, priorRowID: &priorRowID,
                            scanned: &scanned, expectedCount: expectedCount,
                            accepted: &accepted, acceptedBytes: &acceptedBytes)
                    }
                }
                if pageCount < StorageBounds.pageRows { break }
            }
            guard scanned == expectedCount else { throw ElysiumStorageError.schemaMismatch }
            return accepted
        }
    }

    public func getLegacyWorldJSON(id: String) throws -> String? {
        try StorageBounds.validateIdentifier(id, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["worlds"]) { context in
            try withStatement(context, "SELECT json FROM worlds WHERE id=?") { statement in
                try statement.bindText(1, id)
                guard try statement.step() == .row else { return nil }
                let value = try statement.legacyText(0, maximumBytes: StorageBounds.manifestText)
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return value
            }
        }
    }

    public func getLegacyPlayerJSON(world: String) throws -> String? {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["player"]) { context in
            try withStatement(context, "SELECT json FROM player WHERE world=?") { statement in
                try statement.bindText(1, world)
                guard try statement.step() == .row else { return nil }
                let value = try statement.legacyText(0, maximumBytes: StorageBounds.playerJSON)
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return value
            }
        }
    }

    public func getLegacyLANClientResumeJSON(hostWorld: String) throws -> String? {
        try StorageBounds.validateIdentifier(hostWorld, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["lan_player_resume"]) { context in
            try withStatement(context, "SELECT json FROM lan_player_resume WHERE hostWorld=?") { statement in
                try statement.bindText(1, hostWorld)
                guard try statement.step() == .row else { return nil }
                let value = try statement.legacyText(0, maximumBytes: StorageBounds.playerJSON)
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return value
            }
        }
    }

    public func getLegacyLANPlayerJSON(world: String, playerID: String) throws -> String? {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateIdentifier(playerID, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["lan_players"]) { context in
            try withStatement(context, """
                SELECT json FROM lan_players WHERE world=? AND playerID=?
                """) { statement in
                try statement.bindText(1, world)
                try statement.bindText(2, playerID)
                guard try statement.step() == .row else { return nil }
                let value = try statement.legacyText(0, maximumBytes: StorageBounds.playerJSON)
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return value
            }
        }
    }

    public func listLegacyLANPlayerJSON(world: String) throws -> [ElysiumLegacyLANPlayerJSON] {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.legacyLANPlayerCollection { context in
            let actualCount = try legacyCollectionCount(
                context, sql: "SELECT count(ROWID) FROM lan_players WHERE world=?",
                maximumRows: StorageBounds.lanPeerRows) { try $0.bindText(1, world) }
            let expectedCount = try adjustedLegacyCollectionCount(actualCount, executor: executor)
            var scanned = 0
            var priorRowID: Int64?
            var accepted: [(rowID: Int64, value: ElysiumLegacyLANPlayerJSON)] = []
            var acceptedBytes: Int64 = 0
            try withStatement(context, """
                SELECT ROWID,playerID,json FROM lan_players
                WHERE world=? ORDER BY ROWID LIMIT 257
                """) { statement in
                try statement.bindText(1, world)
                while try statement.step() == .row {
                    let rowID = try statement.int64(0)
                    try validateLegacyRowID(rowID, prior: &priorRowID, executor: executor)
                    try incrementLegacyScanned(&scanned, expectedCount: expectedCount)
                    guard let playerID = try statement.legacyText(
                        1, maximumBytes: StorageBounds.manifestText),
                          let json = try statement.legacyText(
                            2, maximumBytes: StorageBounds.playerJSON) else { continue }
                    try addLegacyBytes([playerID.utf8.count, json.utf8.count],
                                       total: &acceptedBytes,
                                       maximum: Int64(StorageBounds.lanPeerRows)
                                        * Int64(StorageBounds.manifestText + StorageBounds.playerJSON))
                    accepted.append((rowID, .init(playerID: playerID, json: json)))
                }
            }
            guard scanned == expectedCount else { throw ElysiumStorageError.schemaMismatch }
            accepted.sort { legacyUTF8Ordered($0.value.playerID, rowID: $0.rowID,
                                               before: $1.value.playerID, rowID: $1.rowID) }
            return accepted.map(\.value)
        }
    }

    public func getLegacyAdvancementJSON(world: String) throws -> String? {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["advancements"]) { context in
            try withStatement(context, "SELECT json FROM advancements WHERE world=?") { statement in
                try statement.bindText(1, world)
                guard try statement.step() == .row else { return nil }
                let value = try statement.legacyText(0, maximumBytes: StorageBounds.manifestText)
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return value
            }
        }
    }

    public func listLegacyTemplateNames() throws -> [String] {
        try executor.legacyTemplateCollection { context in
            let actualCount = try legacyCollectionCount(
                context, sql: "SELECT count(ROWID) FROM templates",
                maximumRows: StorageBounds.templateRows)
            let expectedCount = try adjustedLegacyCollectionCount(actualCount, executor: executor)
            var scanned = 0
            var priorRowID: Int64?
            var accepted: [(rowID: Int64, value: String)] = []
            var acceptedBytes: Int64 = 0
            while true {
                let pageCount: Int
                if let cursor = priorRowID {
                    pageCount = try withStatement(context, """
                        SELECT ROWID,name FROM templates WHERE ROWID>? ORDER BY ROWID LIMIT 256
                        """) { statement in
                        try statement.bindInt64(1, cursor)
                        return try scanLegacyTemplateNamePage(
                            statement, executor: executor, priorRowID: &priorRowID,
                            scanned: &scanned, expectedCount: expectedCount,
                            accepted: &accepted, acceptedBytes: &acceptedBytes)
                    }
                } else {
                    pageCount = try withStatement(context, """
                        SELECT ROWID,name FROM templates ORDER BY ROWID LIMIT 256
                        """) { statement in
                        try scanLegacyTemplateNamePage(
                            statement, executor: executor, priorRowID: &priorRowID,
                            scanned: &scanned, expectedCount: expectedCount,
                            accepted: &accepted, acceptedBytes: &acceptedBytes)
                    }
                }
                if pageCount < StorageBounds.pageRows { break }
            }
            guard scanned == expectedCount else { throw ElysiumStorageError.schemaMismatch }
            accepted.sort { legacyUTF8Ordered($0.value, rowID: $0.rowID,
                                               before: $1.value, rowID: $1.rowID) }
            return accepted.map(\.value)
        }
    }

    public func getLegacyTemplateContent(name: String) throws -> ElysiumLegacyTemplateContent? {
        try StorageBounds.validateIdentifier(name, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["templates"]) { context in
            try withStatement(context, "SELECT format,data,json FROM templates WHERE name=?") { statement in
                try statement.bindText(1, name)
                guard try statement.step() == .row else { return nil }
                let value = ElysiumLegacyTemplateContent(
                    format: try statement.legacyInt32(0),
                    data: try statement.legacyData(1, maximumBytes: StorageBounds.templateData),
                    json: try statement.legacyText(2, maximumBytes: StorageBounds.templateJSON))
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return value
            }
        }
    }

    public func listLegacyTemplateSummaryCandidates() throws
        -> [ElysiumTemplateSummaryCandidate] {
        try executor.legacyTemplateCollection { context in
            let actualCount = try legacyCollectionCount(
                context, sql: "SELECT count(ROWID) FROM templates",
                maximumRows: StorageBounds.templateRows)
            let expectedCount = try adjustedLegacyCollectionCount(actualCount, executor: executor)
            var scanned = 0
            var priorRowID: Int64?
            var accepted: [(rowID: Int64, value: ElysiumTemplateSummaryCandidate)] = []
            var acceptedBytes: Int64 = 0
            while true {
                let pageCount: Int
                if let cursor = priorRowID {
                    pageCount = try withStatement(context, """
                        SELECT ROWID,name,sizeX,sizeY,sizeZ,blockCount,blockEntityCount,
                               dominantBlock,dominantDisplay
                        FROM templates WHERE ROWID>? ORDER BY ROWID LIMIT 256
                        """) { statement in
                        try statement.bindInt64(1, cursor)
                        return try scanLegacyTemplateCandidatePage(
                            statement, executor: executor, priorRowID: &priorRowID,
                            scanned: &scanned, expectedCount: expectedCount,
                            accepted: &accepted, acceptedBytes: &acceptedBytes)
                    }
                } else {
                    pageCount = try withStatement(context, """
                        SELECT ROWID,name,sizeX,sizeY,sizeZ,blockCount,blockEntityCount,
                               dominantBlock,dominantDisplay
                        FROM templates ORDER BY ROWID LIMIT 256
                        """) { statement in
                        try scanLegacyTemplateCandidatePage(
                            statement, executor: executor, priorRowID: &priorRowID,
                            scanned: &scanned, expectedCount: expectedCount,
                            accepted: &accepted, acceptedBytes: &acceptedBytes)
                    }
                }
                if pageCount < StorageBounds.pageRows { break }
            }
            guard scanned == expectedCount else { throw ElysiumStorageError.schemaMismatch }
            accepted.sort { legacyUTF8Ordered($0.value.name, rowID: $0.rowID,
                                               before: $1.value.name, rowID: $1.rowID) }
            return accepted.map(\.value)
        }
    }

    // MARK: Worlds

    private func checkedWorldSnapshot(
        _ context: StorageContext,
        templateCounter: StorageWorldBatchAuthorityStatementCounter? = nil
    ) throws -> ElysiumCheckedWorldCollectionSnapshot {
        let expectedCount: Int64 = try withWorldBatchAuthorityStatement(
            context, "SELECT count(*) FROM worlds", counter: templateCounter
        ) { statement in
            guard try statement.step() == .row else { throw ElysiumStorageError.schemaIntegrity }
            let count = try statement.int64(0)
            guard try statement.step() == .done, count >= 0,
                  count <= Int64(StorageBounds.worldRows) else {
                throw ElysiumStorageError.limitExceeded
            }
            return count
        }
        let rows: [ElysiumCheckedWorldStorageRow] = try withWorldBatchAuthorityStatement(context, """
            SELECT id,json,lastPlayed FROM worlds ORDER BY CAST(id AS BLOB) LIMIT 4097
            """, counter: templateCounter) { statement in
            var result: [ElysiumCheckedWorldStorageRow] = []
            var aggregateBytes = 0
            var previousID: String?
            while try statement.step() == .row {
                guard result.count < StorageBounds.worldRows,
                      let id = try statement.text(
                        0, maximumBytes: StorageBounds.worldBrowserIDBytes),
                      let json = try statement.text(
                        1, maximumBytes: StorageBounds.manifestText) else {
                    throw ElysiumStorageError.limitExceeded
                }
                if let previousID, !storageRawUTF8Less(previousID, id) {
                    throw ElysiumStorageError.schemaIntegrity
                }
                aggregateBytes = try StorageWorldBatchCheckedAccumulator.worldAggregate(
                    aggregateBytes, adding: id.utf8.count + json.utf8.count)
                let lastPlayed = try statement.double(2)
                result.append(ElysiumCheckedWorldStorageRow(
                    storedID: id, json: json, lastPlayed: lastPlayed,
                    rowDigest: storageWorldRowDigest(
                        id: id, json: json, lastPlayed: lastPlayed)))
                previousID = id
            }
            guard result.count == Int(expectedCount) else {
                throw ElysiumStorageError.schemaMismatch
            }
            return result
        }
        let aggregate = try rows.reduce(into: 0) { total, row in
            total = try StorageWorldBatchCheckedAccumulator.worldAggregate(
                total, adding: row.storedID.utf8.count + row.json.utf8.count)
        }
        return ElysiumCheckedWorldCollectionSnapshot(
            rows: rows, collectionDigest: storageWorldCollectionDigest(rows),
            aggregateRawBytes: aggregate)
    }

    public func checkedWorldSnapshot() throws -> ElysiumCheckedWorldCollectionSnapshot {
        try executor.read(tables: ["worlds"]) { try checkedWorldSnapshot($0) }
    }

    private struct WorldBatchAuthority: Equatable {
        let worlds: ElysiumCheckedWorldCollectionSnapshot
        let selectedScopeCounts: [[Int64]]
        let unrelatedIdentityDigest: Data
        let totalScopeCounts: [Int64]

        func digest(_ phase: StorageWorldBatchAuthorityPhase) -> Data {
            storageWorldBatchAuthorityDigest(
                phase: phase, worldCollectionDigest: worlds.collectionDigest,
                selectedScopeCounts: selectedScopeCounts,
                unrelatedIdentityDigest: unrelatedIdentityDigest,
                totalScopeCounts: totalScopeCounts)
        }
    }

    private func batchDeleteAuthority(
        _ context: StorageContext, request: ElysiumWorldBatchDeleteRequest
    ) throws -> WorldBatchAuthority {
        let templateCounter = StorageWorldBatchAuthorityStatementCounter()
        let worlds = try checkedWorldSnapshot(context, templateCounter: templateCounter)
        let selectedIDs = request.expectations.map(\.storedID)
        let selectedIndex = Dictionary(
            uniqueKeysWithValues: selectedIDs.enumerated().map { ($0.element, $0.offset) })
        var selectedCounts = Array(
            repeating: [Int64](repeating: 0, count: 6), count: selectedIDs.count)
        var totals = [Int64](repeating: 0, count: 6)
        var unrelated = StorageFramedSHA256(
            domain: "Pebble.WorldBrowser.DeleteAuthority.UnrelatedKeys.v1")

        func consume(_ id: String, scope: Int, components: [Data] = []) throws {
            let (total, totalOverflow) = totals[scope].addingReportingOverflow(1)
            guard !totalOverflow else { throw ElysiumStorageError.limitExceeded }
            totals[scope] = total
            if let index = selectedIndex[id] {
                let (count, countOverflow) = selectedCounts[index][scope]
                    .addingReportingOverflow(1)
                guard !countOverflow else { throw ElysiumStorageError.limitExceeded }
                selectedCounts[index][scope] = count
            } else {
                unrelated.appendUInt64(UInt64(scope))
                unrelated.appendText(id)
                unrelated.appendUInt64(UInt64(components.count))
                for component in components { unrelated.appendFrame(component) }
            }
        }

        try withWorldBatchAuthorityStatement(context, """
            SELECT 0 AS row_kind,'' AS world_record_id,
              (SELECT count(*) FROM rpg_local_preferences_v1) AS preference_count,
              (SELECT count(*) FROM rpg_local_preference_migrations_v1) AS marker_count,
              coalesce((SELECT sum(256+length(CAST(world_record_id AS BLOB))+2+8+
                length(slots_payload)+32+1+coalesce(length(migration_origin_digest),0)+
                CASE WHEN migration_origin_revision IS NULL THEN 0 ELSE 8 END)
                FROM rpg_local_preferences_v1),0)+
              coalesce((SELECT sum(256+length(CAST(world_record_id AS BLOB))+2+32+32+8)
                FROM rpg_local_preference_migrations_v1),0) AS total_bytes,
              CAST('' AS BLOB) AS sort_key
            UNION ALL
            SELECT 1,world_record_id,0,0,0,CAST(world_record_id AS BLOB)
              FROM rpg_local_preference_migrations_v1
            ORDER BY row_kind,sort_key LIMIT 4098
            """, counter: templateCounter) { statement in
            guard try statement.step() == .row,
                  try statement.int64(0) == 0,
                  try statement.text(1, maximumBytes: 0) == "" else {
                throw ElysiumStorageError.schemaIntegrity
            }
            let preferenceCount = try statement.int64(2)
            let markerCount = try statement.int64(3)
            let totalBytes = try statement.int64(4)
            guard (0...256).contains(preferenceCount),
                  (0...256).contains(markerCount),
                  (0...1_048_576).contains(totalBytes) else {
                throw ElysiumStorageError.schemaIntegrity
            }
            var rows = 0
            while try statement.step() == .row {
                guard try statement.int64(0) == 1,
                      rows < StorageBounds.worldRows,
                      let id = try statement.text(1, maximumBytes: 64) else {
                    throw ElysiumStorageError.limitExceeded
                }
                try consume(id, scope: 0); rows += 1
            }
        }
        try withWorldBatchAuthorityStatement(context, """
            SELECT world_record_id FROM rpg_local_preferences_v1
            ORDER BY CAST(world_record_id AS BLOB) LIMIT 4097
            """, counter: templateCounter) { statement in
            var rows = 0
            while try statement.step() == .row {
                guard rows < StorageBounds.worldRows,
                      let id = try statement.text(0, maximumBytes: 64) else {
                    throw ElysiumStorageError.limitExceeded
                }
                try consume(id, scope: 1); rows += 1
            }
        }
        for row in worlds.rows { try consume(row.storedID, scope: 2) }
        try withWorldBatchAuthorityStatement(context, """
            SELECT world,dim,cx,cz FROM chunks
            ORDER BY CAST(world AS BLOB),dim,cx,cz LIMIT 1048577
            """, counter: templateCounter) { statement in
            var rows = 0
            while try statement.step() == .row {
                guard rows < StorageBounds.chunkRows,
                      let id = try statement.text(
                        0, maximumBytes: StorageBounds.worldBrowserIDBytes) else {
                    throw ElysiumStorageError.limitExceeded
                }
                let values = try (1...3).map { try statement.int64(Int32($0)) }
                guard values.allSatisfy({ Int32(exactly: $0) != nil }) else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                let components = values.map { value -> Data in
                    var bits = UInt64(bitPattern: value).bigEndian
                    return withUnsafeBytes(of: &bits) { Data($0) }
                }
                try consume(id, scope: 3, components: components)
                rows = try StorageWorldBatchCheckedAccumulator.chunkRows(rows)
            }
        }
        try withWorldBatchAuthorityStatement(context, """
            SELECT world FROM player ORDER BY CAST(world AS BLOB) LIMIT 4097
            """, counter: templateCounter) { statement in
            var rows = 0
            while try statement.step() == .row {
                guard rows < StorageBounds.worldRows,
                      let id = try statement.text(
                        0, maximumBytes: StorageBounds.worldBrowserIDBytes) else {
                    throw ElysiumStorageError.limitExceeded
                }
                try consume(id, scope: 4); rows += 1
            }
        }
        try withWorldBatchAuthorityStatement(context, """
            SELECT world FROM advancements ORDER BY CAST(world AS BLOB) LIMIT 4097
            """, counter: templateCounter) { statement in
            var rows = 0
            while try statement.step() == .row {
                guard rows < StorageBounds.worldRows,
                      let id = try statement.text(
                        0, maximumBytes: StorageBounds.worldBrowserIDBytes) else {
                    throw ElysiumStorageError.limitExceeded
                }
                try consume(id, scope: 5); rows += 1
            }
        }
        for counts in selectedCounts {
            guard counts[0] <= 1, counts[1] <= 1, counts[2] <= 1,
                  counts[3] <= Int64(StorageBounds.chunkRows),
                  counts[4] <= 1, counts[5] <= 1,
                  counts[0] <= counts[1], counts[1] <= counts[2] else {
                throw ElysiumStorageError.schemaIntegrity
            }
        }
        guard templateCounter.preparedTemplates ==
                StorageWorldBatchCheckedAccumulator.authorityStatementTemplates,
              totals[0] <= 4_096, totals[1] <= 4_096, totals[2] <= 4_096,
              totals[3] <= Int64(StorageBounds.chunkRows),
              totals[4] <= 4_096, totals[5] <= 4_096 else {
            throw ElysiumStorageError.limitExceeded
        }
        return WorldBatchAuthority(
            worlds: worlds, selectedScopeCounts: selectedCounts,
            unrelatedIdentityDigest: unrelated.finish(), totalScopeCounts: totals)
    }

    private func batchDeleteAuthority(
        request: ElysiumWorldBatchDeleteRequest
    ) throws -> WorldBatchAuthority {
        try executor.read(tables: [
            "rpg_local_preference_migrations_v1", "rpg_local_preferences_v1",
            "worlds", "chunks", "player", "advancements",
        ]) { try batchDeleteAuthority($0, request: request) }
    }

    public func deleteWorldsChecked(
        _ request: ElysiumWorldBatchDeleteRequest
    ) -> ElysiumWorldBatchDeleteOutcome {
        do { try executor.ensureRPGLocalPreferencesSchema() }
        catch { return .terminalIntegrity }
        let pre: WorldBatchAuthority
        do { pre = try batchDeleteAuthority(request: request) }
        catch { return .terminalIntegrity }
        guard storageFixedTimeEqual(
            pre.worlds.collectionDigest, request.expectedCollectionDigest) else {
            return .stale
        }
        let byID = Dictionary(
            uniqueKeysWithValues: pre.worlds.rows.map { ($0.storedID, $0) })
        for expectation in request.expectations {
            guard let row = byID[expectation.storedID],
                  storageFixedTimeEqual(row.rowDigest, expectation.rowDigest) else {
                return .stale
            }
        }
        guard (try? StorageWorldBatchCheckedAccumulator.statementWork(
                requestCount: request.expectations.count)) != nil,
              (try? StorageWorldBatchCheckedAccumulator.statementTemplateCount(
                deleteTemplateCount: storageWorldBatchDeleteStatements.count)) == 13 else {
            return .terminalIntegrity
        }
        let selected = Set(request.expectations.map(\.storedID))
        let postRows = pre.worlds.rows.filter { !selected.contains($0.storedID) }
        let postAggregate: Int
        do {
            postAggregate = try postRows.reduce(into: 0) { total, row in
                total = try StorageWorldBatchCheckedAccumulator.worldAggregate(
                    total, adding: row.storedID.utf8.count + row.json.utf8.count)
            }
        } catch { return .terminalIntegrity }
        let postWorlds = ElysiumCheckedWorldCollectionSnapshot(
            rows: postRows, collectionDigest: storageWorldCollectionDigest(postRows),
            aggregateRawBytes: postAggregate)
        var postTotals = pre.totalScopeCounts
        for counts in pre.selectedScopeCounts {
            for scope in 0..<6 {
                let (next, overflow) = postTotals[scope]
                    .subtractingReportingOverflow(counts[scope])
                guard !overflow, next >= 0 else { return .terminalIntegrity }
                postTotals[scope] = next
            }
        }
        let post = WorldBatchAuthority(
            worlds: postWorlds,
            selectedScopeCounts: Array(
                repeating: [Int64](repeating: 0, count: 6),
                count: request.expectations.count),
            unrelatedIdentityDigest: pre.unrelatedIdentityDigest,
            totalScopeCounts: postTotals)
        let preDigest = pre.digest(.pre)
        let postDigest = post.digest(.post)
        let receipt: ElysiumWorldBatchDeleteReceipt
        do {
            receipt = try ElysiumWorldBatchDeleteReceipt(
                request: request, preAuthorityDigest: preDigest,
                postAuthorityDigest: postDigest,
                unrelatedIdentityDigest: pre.unrelatedIdentityDigest,
                preWorldCount: pre.worlds.rows.count,
                postWorldCount: post.worlds.rows.count)
        }
        catch { return .terminalIntegrity }
        let recoveryAuthority = ElysiumWorldBatchDeleteRecoveryAuthority(
            request: request, receipt: receipt,
            preWorlds: pre.worlds, postWorlds: post.worlds,
            preSelectedScopeCounts: pre.selectedScopeCounts,
            postSelectedScopeCounts: post.selectedScopeCounts,
            unrelatedIdentityDigest: pre.unrelatedIdentityDigest,
            preTotalScopeCounts: pre.totalScopeCounts,
            postTotalScopeCounts: post.totalScopeCounts)

        do {
            let committed = try executor.coreWorldDeleteWithRPGAtomic { context in
                let current = try batchDeleteAuthority(context, request: request)
                guard current == pre,
                      storageFixedTimeEqual(current.digest(.pre), preDigest) else {
                    return false
                }
                var statements: [StorageStatement] = []
                statements.reserveCapacity(storageWorldBatchDeleteStatements.count)
                do {
                    for (index, sql) in storageWorldBatchDeleteStatements.enumerated() {
#if DEBUG
                        try context.executor?.injectActiveRPGLocalFailure(.prepare(statement: index))
#endif
                        statements.append(try context.prepare(sql))
                    }
                } catch {
                    for statement in statements { try? statement.finalize() }
                    throw error
                }
                defer { for statement in statements { try? statement.finalize() } }
                for (idIndex, expectation) in request.expectations.enumerated() {
                    for statementIndex in 0..<statements.count {
                        let statement = statements[statementIndex]
#if DEBUG
                        try context.executor?.injectActiveRPGLocalFailure(
                            .bind(statement: statementIndex))
#endif
                        try statement.bindText(1, expectation.storedID)
#if DEBUG
                        try context.executor?.injectActiveRPGLocalFailure(
                            .step(statement: statementIndex))
#endif
                        guard try statement.step() == .done else {
                            throw ElysiumStorageError.schemaIntegrity
                        }
#if DEBUG
                        try context.executor?.injectActiveRPGLocalFailure(
                            .changes(statement: statementIndex))
#endif
                        let changes = try context.changes()
                        guard Int64(changes) == pre.selectedScopeCounts[idIndex][statementIndex] else {
                            throw ElysiumStorageError.schemaIntegrity
                        }
#if DEBUG
                        try context.executor?.injectActiveRPGLocalFailure(
                            .reset(statement: statementIndex, requestIndex: idIndex))
#endif
                        try statement.resetForReuse()
#if DEBUG
                        try context.executor?.injectActiveRPGLocalFailure(
                            .clearBindings(statement: statementIndex, requestIndex: idIndex))
#endif
                        try statement.clearBindingsForReuse()
                    }
                }
                for (index, statement) in statements.enumerated() {
                    try statement.finalize()
#if DEBUG
                    try context.executor?.injectActiveRPGLocalFailure(
                        .finalize(statement: index))
#endif
                }
                let observedPost = try batchDeleteAuthority(context, request: request)
#if DEBUG
                try context.executor?.injectActiveRPGLocalFailure(.postcondition)
#endif
                guard observedPost == post,
                      storageFixedTimeEqual(observedPost.digest(.post), postDigest),
                      storageFixedTimeEqual(
                        observedPost.unrelatedIdentityDigest,
                        pre.unrelatedIdentityDigest) else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                _ = receipt.receiptDigest
                return true
            }
            return committed ? .direct(receipt) : .stale
        } catch {
            guard let observed = try? batchDeleteAuthority(request: request) else {
                return .terminalRecovery(recoveryAuthority)
            }
            if observed == post,
               storageFixedTimeEqual(observed.digest(.post), postDigest),
               storageFixedTimeEqual(
                observed.unrelatedIdentityDigest, pre.unrelatedIdentityDigest) {
                return .recovered(receipt)
            }
            if observed == pre,
               storageFixedTimeEqual(observed.digest(.pre), preDigest),
               storageFixedTimeEqual(
                observed.unrelatedIdentityDigest, pre.unrelatedIdentityDigest) {
                return .provenPrecommitFailure
            }
            return .terminalRecovery(recoveryAuthority)
        }
    }

    /// Read-only continuation for an ambiguous post-commit publication cut.
    /// It never executes DELETE and can classify only the exact six-scope pre
    /// or post authority captured by the original admitted operation.
    public func recoverWorldsChecked(
        _ authority: ElysiumWorldBatchDeleteRecoveryAuthority
    ) -> ElysiumWorldBatchDeleteOutcome {
        do { try executor.verifyRPGLocalPreferencesSchemaForRecovery() }
        catch { return .terminalRecovery(authority) }
        guard let observed = try? batchDeleteAuthority(request: authority.request) else {
            return .terminalRecovery(authority)
        }
        let pre = WorldBatchAuthority(
            worlds: authority.preWorlds,
            selectedScopeCounts: authority.preSelectedScopeCounts,
            unrelatedIdentityDigest: authority.unrelatedIdentityDigest,
            totalScopeCounts: authority.preTotalScopeCounts)
        let post = WorldBatchAuthority(
            worlds: authority.postWorlds,
            selectedScopeCounts: authority.postSelectedScopeCounts,
            unrelatedIdentityDigest: authority.unrelatedIdentityDigest,
            totalScopeCounts: authority.postTotalScopeCounts)
        if observed == post,
           storageFixedTimeEqual(
            observed.digest(.post), authority.receipt.postAuthorityDigest) {
            return .recovered(authority.receipt)
        }
        if observed == pre,
           storageFixedTimeEqual(
            observed.digest(.pre), authority.receipt.preAuthorityDigest) {
            return .provenPrecommitFailure
        }
        return .terminalRecovery(authority)
    }

    public func listWorldRows() throws -> [ElysiumWorldStorageRow] {
        try executor.read(tables: ["worlds"]) { context in
            let expectedCount = try checkCollection(context, sql: """
                SELECT count(*),coalesce(sum(
                    length(CAST(id AS BLOB))+length(CAST(json AS BLOB))),0) FROM worlds
                """, maximumRows: StorageBounds.worldRows,
                maximumBytes: Int64(StorageBounds.worldRows) * Int64(StorageBounds.manifestText * 2))
            let result = try withStatement(context, """
                SELECT id,json,lastPlayed FROM worlds ORDER BY id LIMIT 4097
                """) { statement in
                var rows: [ElysiumWorldStorageRow] = []
                while try statement.step() == .row {
                    guard rows.count < StorageBounds.worldRows else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                        guard let id = try statement.text(0, maximumBytes: StorageBounds.manifestText),
                              let json = try statement.text(1, maximumBytes: StorageBounds.manifestText) else {
                            throw ElysiumStorageError.invalidStorageClass
                        }
                        rows.append(try ElysiumWorldStorageRow(id: id, json: json,
                                                             lastPlayed: statement.double(2)))
                }
                return rows
            }
            guard result.count == expectedCount else { throw ElysiumStorageError.schemaMismatch }
            return result
        }
    }

#if DEBUG
    func _testWorldCollectionThreeByteBudget() throws -> Int {
        try executor.read(tables: ["worlds"]) { context in
            try checkCollection(context, sql: """
                SELECT count(*),coalesce(sum(
                    length(CAST(id AS BLOB))+length(CAST(json AS BLOB))),0) FROM worlds
                """, maximumRows: StorageBounds.worldRows, maximumBytes: 3)
        }
    }
#endif

    public func getWorldRow(id: String) throws -> ElysiumWorldStorageRow? {
        try StorageBounds.validateIdentifier(id, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["worlds"]) { context in
            try withStatement(context, "SELECT id,json,lastPlayed FROM worlds WHERE id=?") { statement in
                try statement.bindText(1, id)
                guard try statement.step() == .row else { return nil }
                guard let storedID = try statement.text(0, maximumBytes: StorageBounds.manifestText),
                      let json = try statement.text(1, maximumBytes: StorageBounds.manifestText) else {
                    throw ElysiumStorageError.invalidStorageClass
                }
                let row = try ElysiumWorldStorageRow(id: storedID, json: json,
                                                    lastPlayed: statement.double(2))
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return row
            }
        }
    }

    public func putWorldRow(_ row: ElysiumWorldStorageRow) throws {
        _ = try executor.mutate(table: "worlds") { context in
            try executeMutation(context, """
                INSERT OR REPLACE INTO worlds(id,json,lastPlayed) VALUES(?,?,?)
                """) { statement in
                try statement.bindText(1, row.id)
                try statement.bindText(2, row.json)
                try statement.bindDouble(3, row.lastPlayed)
            }
        }
    }

    public func deleteWorld(id: String) throws -> Int {
        try StorageBounds.validateIdentifier(id, maximumBytes: StorageBounds.manifestText)
        try executor.ensureRPGLocalPreferencesSchema()
        return try executor.coreWorldDeleteWithRPGAtomic { context in
            _ = try readRPGLocalAccounting(context)
            let counts: [Int64] = try withStatement(context, """
                SELECT
                  (SELECT count(*) FROM rpg_local_preference_migrations_v1 WHERE world_record_id=?),
                  (SELECT count(*) FROM rpg_local_preferences_v1 WHERE world_record_id=?),
                  (SELECT count(*) FROM worlds WHERE id=?),
                  (SELECT count(*) FROM chunks WHERE world=?),
                  (SELECT count(*) FROM player WHERE world=?),
                  (SELECT count(*) FROM advancements WHERE world=?)
                """) { statement in
                for index in 1...6 { try statement.bindText(Int32(index), id) }
                guard try statement.step() == .row else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                let values = try (0..<6).map { try statement.int64(Int32($0)) }
                guard try statement.step() == .done else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                return values
            }
            guard counts[0] <= 1, counts[1] <= 1, counts[2] <= 1,
                  counts[3] <= 1_048_576, counts[4] <= 1, counts[5] <= 1,
                  counts.allSatisfy({ $0 >= 0 }),
                  counts[0] <= counts[1], counts[1] <= counts[2] else {
                throw ElysiumStorageError.schemaIntegrity
            }
            let statements: [(StaticString, Int64)] = [
                ("DELETE FROM rpg_local_preference_migrations_v1 WHERE world_record_id=?", counts[0]),
                ("DELETE FROM rpg_local_preferences_v1 WHERE world_record_id=?", counts[1]),
                ("DELETE FROM worlds WHERE id=?", counts[2]),
                ("DELETE FROM chunks WHERE world=?", counts[3]),
                ("DELETE FROM player WHERE world=?", counts[4]),
                ("DELETE FROM advancements WHERE world=?", counts[5]),
            ]
            var observed: [Int] = []
            for (statementIndex, element) in statements.enumerated() {
                let (sql, expected) = element
                let changes = try executeWorldDeleteMutation(
                    context, statementIndex: statementIndex, sql
                ) { try $0.bindText(1, id) }
                guard Int64(changes) == expected else { throw ElysiumStorageError.schemaIntegrity }
                observed.append(changes)
            }
            let postcondition: Int64 = try withStatement(context, """
                SELECT
                  (SELECT count(*) FROM rpg_local_preference_migrations_v1 WHERE world_record_id=?)+
                  (SELECT count(*) FROM rpg_local_preferences_v1 WHERE world_record_id=?)+
                  (SELECT count(*) FROM worlds WHERE id=?)+
                  (SELECT count(*) FROM chunks WHERE world=?)+
                  (SELECT count(*) FROM player WHERE world=?)+
                  (SELECT count(*) FROM advancements WHERE world=?)
                """) { statement in
                for index in 1...6 { try statement.bindText(Int32(index), id) }
                guard try statement.step() == .row else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                let value = try statement.int64(0)
                guard try statement.step() == .done else {
                    throw ElysiumStorageError.schemaIntegrity
                }
                return value
            }
#if DEBUG
            try context.executor?.injectActiveRPGLocalFailure(.postcondition)
#endif
            guard postcondition == 0 else { throw ElysiumStorageError.schemaIntegrity }
            return observed[2] + observed[3] + observed[4] + observed[5]
        }
    }

    // MARK: Chunks

    public func listChunkKeys(world: String) throws -> [ElysiumChunkStorageKey] {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.legacyChunkKeyCollection { context in
            let dataVersionBefore = try readDataVersion(context)
            let expectedCount = try checkChunkKeyCollection(context, world: world)
#if DEBUG
            try executor.observeTestStage(.afterChunkKeyPreflight)
#endif
            var result: [ElysiumChunkStorageKey] = []
            var cursor: ElysiumChunkStorageKey?
            while true {
                let page: [ElysiumChunkStorageKey]
                if let cursor {
                    page = try withStatement(context, """
                        SELECT dim,cx,cz FROM chunks WHERE world=? AND
                        (dim>? OR (dim=? AND cx>?) OR (dim=? AND cx=? AND cz>?))
                        ORDER BY dim,cx,cz LIMIT 256
                        """) { statement in
                        try statement.bindText(1, world)
                        try statement.bindInt32(2, cursor.dimension)
                        try statement.bindInt32(3, cursor.dimension)
                        try statement.bindInt32(4, cursor.chunkX)
                        try statement.bindInt32(5, cursor.dimension)
                        try statement.bindInt32(6, cursor.chunkX)
                        try statement.bindInt32(7, cursor.chunkZ)
                        return try readChunkKeyPage(statement, world: world)
                    }
                } else {
                    page = try withStatement(context, """
                        SELECT dim,cx,cz FROM chunks WHERE world=? ORDER BY dim,cx,cz LIMIT 256
                        """) { statement in
                        try statement.bindText(1, world)
                        return try readChunkKeyPage(statement, world: world)
                    }
                }
                guard page.count <= StorageBounds.pageRows,
                      result.count <= expectedCount,
                      page.count <= expectedCount - result.count else {
                    throw ElysiumStorageError.schemaMismatch
                }
                var prior = cursor
                for key in page {
                    if let prior, !chunkKeyTupleLess(prior, key) {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    prior = key
                }
                let (nextCount, overflow) = result.count.addingReportingOverflow(page.count)
                guard !overflow, nextCount <= StorageBounds.chunkRows else {
                    throw ElysiumStorageError.schemaMismatch
                }
                result.append(contentsOf: page)
                guard page.count == StorageBounds.pageRows, let last = page.last else { break }
                cursor = last
            }
            let dataVersionAfter = try readDataVersion(context)
            guard dataVersionAfter == dataVersionBefore,
                  result.count == expectedCount else {
                throw ElysiumStorageError.schemaMismatch
            }
            return result
        }
    }

    public func getChunkBlob(key: ElysiumChunkStorageKey) throws -> Data? {
        try executor.read(tables: ["chunks"]) { context in
            try withStatement(context, """
                SELECT data FROM chunks WHERE world=? AND dim=? AND cx=? AND cz=?
                """) { statement in
                try bindChunkKey(statement, key)
                guard try statement.step() == .row else { return nil }
                guard let data = try statement.data(0, maximumBytes: StorageBounds.chunkBlob) else {
                    throw ElysiumStorageError.invalidStorageClass
                }
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return data
            }
        }
    }

    @discardableResult
    public func putChunkBlobRows(_ rows: [ElysiumChunkStorageRow]) throws -> Int {
        guard rows.count <= StorageBounds.chunkRows else { throw ElysiumStorageError.limitExceeded }
        return try executor.mutate(table: "chunks") { context in
            var changes = 0
            for row in rows {
                changes += try executeMutation(context, """
                    INSERT OR REPLACE INTO chunks(world,dim,cx,cz,data) VALUES(?,?,?,?,?)
                    """) { statement in
                    try bindChunkKey(statement, row.key)
                    try statement.bindData(5, row.data)
                }
            }
            return changes
        }
    }

    // MARK: Player, LAN v5, and advancements

    public func getPlayerJSON(world: String) throws -> ElysiumPlayerJSONStorageRow? {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["player"]) { context in
            try withStatement(context, """
                SELECT world,json FROM player
                WHERE CAST(world AS BLOB)=CAST(? AS BLOB) LIMIT 2
                """) { statement in
                try statement.bindText(1, world)
                guard try statement.step() == .row else { return nil }
                guard let storedWorld = try statement.text(0, maximumBytes: StorageBounds.manifestText),
                      let json = try statement.text(1, maximumBytes: StorageBounds.playerJSON) else {
                    throw ElysiumStorageError.invalidStorageClass
                }
                let row = try ElysiumPlayerJSONStorageRow(world: storedWorld, json: json)
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return row
            }
        }
    }

    public func putPlayerJSON(_ row: ElysiumPlayerJSONStorageRow) throws {
        _ = try executor.mutate(table: "player") { context in
            try executeMutation(context, "INSERT OR REPLACE INTO player(world,json) VALUES(?,?)") {
                try $0.bindText(1, row.world)
                try $0.bindText(2, row.json)
            }
        }
    }

    public func getLANClientResumeJSON(hostWorld: String) throws -> ElysiumLANClientResumeStorageRow? {
        try StorageBounds.validateIdentifier(hostWorld, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["lan_player_resume"]) { context in
            try withStatement(context, """
                SELECT hostWorld,json,updated FROM lan_player_resume WHERE hostWorld=?
                """) { statement in
                try statement.bindText(1, hostWorld)
                guard try statement.step() == .row else { return nil }
                guard let key = try statement.text(0, maximumBytes: StorageBounds.manifestText),
                      let json = try statement.text(1, maximumBytes: StorageBounds.playerJSON) else {
                    throw ElysiumStorageError.invalidStorageClass
                }
                let row = try ElysiumLANClientResumeStorageRow(hostWorld: key, json: json,
                                                              updated: statement.double(2))
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return row
            }
        }
    }

    public func putLANClientResumeJSON(_ row: ElysiumLANClientResumeStorageRow) throws {
        _ = try executor.mutate(table: "lan_player_resume") { context in
            try executeMutation(context, """
                INSERT OR REPLACE INTO lan_player_resume(hostWorld,json,updated) VALUES(?,?,?)
                """) {
                try $0.bindText(1, row.hostWorld)
                try $0.bindText(2, row.json)
                try $0.bindDouble(3, row.updated)
            }
        }
    }

    @discardableResult
    public func deleteLANClientResumeJSON(hostWorld: String) throws -> Int {
        try StorageBounds.validateIdentifier(hostWorld, maximumBytes: StorageBounds.manifestText)
        return try executor.mutate(table: "lan_player_resume") { context in
            try executeMutation(context, "DELETE FROM lan_player_resume WHERE hostWorld=?") {
                try $0.bindText(1, hostWorld)
            }
        }
    }

    public func getLANPlayerJSON(world: String, playerID: String) throws -> ElysiumLANPlayerStorageRow? {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateIdentifier(playerID, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["lan_players"]) { context in
            try withStatement(context, """
                SELECT world,playerID,json,updated FROM lan_players WHERE world=? AND playerID=?
                """) { statement in
                try statement.bindText(1, world)
                try statement.bindText(2, playerID)
                guard try statement.step() == .row else { return nil }
                let row = try readLANPlayer(statement)
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return row
            }
        }
    }

    public func putLANPlayerJSON(_ row: ElysiumLANPlayerStorageRow) throws {
        _ = try executor.mutate(table: "lan_players") { context in
            try executeMutation(context, """
                INSERT OR REPLACE INTO lan_players(world,playerID,json,updated) VALUES(?,?,?,?)
                """) {
                try $0.bindText(1, row.world)
                try $0.bindText(2, row.playerID)
                try $0.bindText(3, row.json)
                try $0.bindDouble(4, row.updated)
            }
        }
    }

    public func listLANPlayerJSON(world: String) throws -> [ElysiumLANPlayerStorageRow] {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["lan_players"]) { context in
            let expectedCount = try checkCollection(context, sql: """
                SELECT count(*),coalesce(sum(
                    length(CAST(world AS BLOB))+length(CAST(playerID AS BLOB))
                    +length(CAST(json AS BLOB))),0)
                FROM lan_players WHERE world=?
                """, maximumRows: StorageBounds.lanPeerRows,
                maximumBytes: Int64(StorageBounds.lanPeerRows)
                    * Int64(StorageBounds.playerJSON + StorageBounds.manifestText * 2)) {
                try $0.bindText(1, world)
            }
            let result = try withStatement(context, """
                SELECT world,playerID,json,updated FROM lan_players
                WHERE world=? ORDER BY playerID LIMIT 257
                """) { statement -> [ElysiumLANPlayerStorageRow] in
                try statement.bindText(1, world)
                var rows: [ElysiumLANPlayerStorageRow] = []
                while try statement.step() == .row {
                    guard rows.count < StorageBounds.lanPeerRows else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    rows.append(try readLANPlayer(statement))
                }
                return rows
            }
            guard result.count == expectedCount else { throw ElysiumStorageError.schemaMismatch }
            return result
        }
    }

    @discardableResult
    public func deleteLANPlayerJSON(world: String, playerID: String) throws -> Int {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateIdentifier(playerID, maximumBytes: StorageBounds.manifestText)
        return try executor.mutate(table: "lan_players") { context in
            try executeMutation(context, "DELETE FROM lan_players WHERE world=? AND playerID=?") {
                try $0.bindText(1, world)
                try $0.bindText(2, playerID)
            }
        }
    }

    public func getAdvancementJSON(world: String) throws -> ElysiumAdvancementStorageRow? {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["advancements"]) { context in
            try withStatement(context, "SELECT world,json FROM advancements WHERE world=?") { statement in
                try statement.bindText(1, world)
                guard try statement.step() == .row else { return nil }
                guard let key = try statement.text(0, maximumBytes: StorageBounds.manifestText),
                      let json = try statement.text(1, maximumBytes: StorageBounds.manifestText) else {
                    throw ElysiumStorageError.invalidStorageClass
                }
                let row = try ElysiumAdvancementStorageRow(world: key, json: json)
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return row
            }
        }
    }

    public func putAdvancementJSON(_ row: ElysiumAdvancementStorageRow) throws {
        _ = try executor.mutate(table: "advancements") { context in
            try executeMutation(context, """
                INSERT OR REPLACE INTO advancements(world,json) VALUES(?,?)
                """) {
                try $0.bindText(1, row.world)
                try $0.bindText(2, row.json)
            }
        }
    }

    // MARK: Templates

    public func listTemplateNames() throws -> [String] {
        try executor.read(tables: ["templates"]) { context in
            let expectedCount = try checkCollection(context, sql: """
                SELECT count(*),coalesce(sum(length(CAST(name AS BLOB))),0) FROM templates
                """, maximumRows: StorageBounds.templateRows,
                maximumBytes: Int64(StorageBounds.templateRows * StorageBounds.manifestText))
            let result = try withStatement(context, """
                SELECT name FROM templates ORDER BY name LIMIT 1025
                """) { statement -> [String] in
                var rows: [String] = []
                while try statement.step() == .row {
                    guard rows.count < StorageBounds.templateRows else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    guard let name = try statement.text(0, maximumBytes: StorageBounds.manifestText) else {
                        throw ElysiumStorageError.invalidStorageClass
                    }
                    rows.append(name)
                }
                return rows
            }
            guard result.count == expectedCount else { throw ElysiumStorageError.schemaMismatch }
            return result
        }
    }

    public func listTemplateSummaries() throws -> [ElysiumTemplateSummaryStorageRow] {
        try executor.read(tables: ["templates"]) { context in
            let expectedCount = try checkCollection(context, sql: """
                SELECT count(*),coalesce(sum(
                    length(CAST(name AS BLOB))+length(CAST(dominantBlock AS BLOB))
                    +length(CAST(dominantDisplay AS BLOB))),0)
                FROM templates
                """, maximumRows: StorageBounds.templateRows,
                maximumBytes: Int64(StorageBounds.templateRows * StorageBounds.manifestText * 3))
            let result = try withStatement(context, """
                SELECT name,sizeX,sizeY,sizeZ,blockCount,blockEntityCount,dominantBlock,dominantDisplay
                FROM templates ORDER BY name LIMIT 1025
                """) { statement -> [ElysiumTemplateSummaryStorageRow] in
                var rows: [ElysiumTemplateSummaryStorageRow] = []
                while try statement.step() == .row {
                    guard rows.count < StorageBounds.templateRows else {
                        throw ElysiumStorageError.schemaMismatch
                    }
                    rows.append(try readTemplateSummary(statement))
                }
                return rows
            }
            guard result.count == expectedCount else { throw ElysiumStorageError.schemaMismatch }
            return result
        }
    }

    public func getTemplateRow(name: String) throws -> ElysiumTemplateStorageRow? {
        try StorageBounds.validateIdentifier(name, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["templates"]) { context in
            try withStatement(context, """
                SELECT name,json,created,format,data,sizeX,sizeY,sizeZ,blockCount,blockEntityCount,
                       dominantBlock,dominantDisplay FROM templates WHERE name=?
                """) { statement in
                try statement.bindText(1, name)
                guard try statement.step() == .row else { return nil }
                let row = try readTemplate(statement)
                guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
                return row
            }
        }
    }

    @discardableResult
    public func putTemplateRow(_ row: ElysiumTemplateStorageRow) throws -> Int {
        try executor.mutate(table: "templates") { context in
            try executeMutation(context, """
                INSERT OR REPLACE INTO templates(
                    name,json,created,format,data,sizeX,sizeY,sizeZ,blockCount,blockEntityCount,
                    dominantBlock,dominantDisplay) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
                """) { statement in
                try statement.bindText(1, row.summary.name)
                try statement.bindText(2, row.json)
                try statement.bindDouble(3, row.created)
                try statement.bindInt32(4, row.format)
                if let data = row.data { try statement.bindData(5, data) }
                else { try statement.bindNull(5) }
                try statement.bindInt32(6, row.summary.sizeX)
                try statement.bindInt32(7, row.summary.sizeY)
                try statement.bindInt32(8, row.summary.sizeZ)
                try statement.bindInt32(9, row.summary.blockCount)
                try statement.bindInt32(10, row.summary.blockEntityCount)
                try statement.bindText(11, row.summary.dominantBlock)
                try statement.bindText(12, row.summary.dominantDisplay)
            }
        }
    }

    @discardableResult
    public func deleteTemplateRow(name: String) throws -> Int {
        try StorageBounds.validateIdentifier(name, maximumBytes: StorageBounds.manifestText)
        return try executor.mutate(table: "templates") { context in
            try executeMutation(context, "DELETE FROM templates WHERE name=?") {
                try $0.bindText(1, name)
            }
        }
    }

    // One closed aggregate is the only loose-save import entry point. The caller
    // renames its source directory only after this method returns successfully.
    @discardableResult
    public func importLegacyWorld(_ value: ElysiumLegacyWorldImport) throws -> Int {
        try executor.mutate(tables: ["worlds", "player", "advancements", "chunks"]) { context in
            var changes = 0
#if DEBUG
            try injectLegacyImportFailure(executor, .deleteWorlds)
#endif
            changes += try executeMutation(context, "DELETE FROM worlds WHERE id=?") {
                try $0.bindText(1, value.world.id)
            }
#if DEBUG
            try injectLegacyImportFailure(executor, .deleteChunks)
#endif
            changes += try executeMutation(context, "DELETE FROM chunks WHERE world=?") {
                try $0.bindText(1, value.world.id)
            }
#if DEBUG
            try injectLegacyImportFailure(executor, .deletePlayer)
#endif
            changes += try executeMutation(context, "DELETE FROM player WHERE world=?") {
                try $0.bindText(1, value.world.id)
            }
#if DEBUG
            try injectLegacyImportFailure(executor, .deleteAdvancements)
#endif
            changes += try executeMutation(context, "DELETE FROM advancements WHERE world=?") {
                try $0.bindText(1, value.world.id)
            }

#if DEBUG
            try injectLegacyImportFailure(executor, .insertWorld)
#endif
            changes += try executeMutation(context, """
                INSERT OR REPLACE INTO worlds(id,json,lastPlayed) VALUES(?,?,?)
                """) {
                try $0.bindText(1, value.world.id)
                try $0.bindText(2, value.world.json)
                try $0.bindDouble(3, value.world.lastPlayed)
            }
            if let player = value.player {
#if DEBUG
                try injectLegacyImportFailure(executor, .insertPlayer)
#endif
                changes += try executeMutation(context, """
                    INSERT OR REPLACE INTO player(world,json) VALUES(?,?)
                    """) {
                    try $0.bindText(1, player.world)
                    try $0.bindText(2, player.json)
                }
            }
            if let advancements = value.advancements {
#if DEBUG
                try injectLegacyImportFailure(executor, .insertAdvancement)
#endif
                changes += try executeMutation(context, """
                    INSERT OR REPLACE INTO advancements(world,json) VALUES(?,?)
                    """) {
                    try $0.bindText(1, advancements.world)
                    try $0.bindText(2, advancements.json)
                }
            }
            for (index, chunk) in value.chunks.enumerated() {
#if DEBUG
                if index == 0 { try injectLegacyImportFailure(executor, .insertFirstChunk) }
                if index == value.chunks.count / 2 {
                    try injectLegacyImportFailure(executor, .insertMiddleChunk)
                }
                if index == value.chunks.count - 1 {
                    try injectLegacyImportFailure(executor, .insertLastChunk)
                }
#endif
                changes += try executeMutation(context, """
                    INSERT OR REPLACE INTO chunks(world,dim,cx,cz,data) VALUES(?,?,?,?,?)
                    """) {
                    try bindChunkKey($0, chunk.key)
                    try $0.bindData(5, chunk.data)
                }
            }
            return changes
        }
    }
}

private func playerJSONDigestUInt32BE(_ value: UInt32) -> Data {
    Data([
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
    ])
}

private func playerJSONDigestUInt64BE(_ value: UInt64) -> Data {
    Data((0..<8).reversed().map {
        UInt8(truncatingIfNeeded: value >> UInt64($0 * 8))
    })
}

private func playerJSONExactDigest(_ row: ElysiumPlayerJSONStorageRow) -> Data {
    let worldBytes = Data(row.world.utf8)
    let jsonBytes = Data(row.json.utf8)
    var digest = SHA256()
    digest.update(data: Data("Pebble/player-row/exact-json/v1\0".utf8))
    digest.update(data: playerJSONDigestUInt32BE(UInt32(worldBytes.count)))
    digest.update(data: worldBytes)
    digest.update(data: playerJSONDigestUInt64BE(UInt64(jsonBytes.count)))
    digest.update(data: jsonBytes)
    return Data(digest.finalize())
}

private func readExactPlayerJSONRow(
    _ context: StorageContext, world: String
) throws -> ElysiumPlayerJSONStorageRow? {
    try withStatement(context, """
        SELECT world,json FROM player
        WHERE CAST(world AS BLOB)=CAST(? AS BLOB) LIMIT 2
        """) { statement in
        try statement.bindText(1, world)
        guard try statement.step() == .row else { return nil }
        guard let storedWorld = try statement.text(
            0, maximumBytes: StorageBounds.manifestText),
              let json = try statement.text(1, maximumBytes: StorageBounds.playerJSON) else {
            throw ElysiumStorageError.invalidStorageClass
        }
        let row = try ElysiumPlayerJSONStorageRow(world: storedWorld, json: json)
        guard row.world == world, try statement.step() == .done else {
            throw ElysiumStorageError.schemaIntegrity
        }
        return row
    }
}

public extension ElysiumLegacyCoreStorage {
    func compareAndSwapPlayerJSON(
        expected: ElysiumPlayerJSONExpectedRowState,
        candidate: ElysiumPlayerJSONStorageRow
    ) throws -> ElysiumPlayerJSONCompareAndSwapResult {
        try executor.playerJSONCompareAndSwap { context in
            let parentExists: Bool = try withStatement(context, """
                SELECT id FROM worlds
                WHERE CAST(id AS BLOB)=CAST(? AS BLOB) LIMIT 2
                """) { statement in
                    try statement.bindText(1, candidate.world)
                    guard try statement.step() == .row,
                          try statement.legacyText(
                            0, maximumBytes: StorageBounds.manifestText) == candidate.world,
                          try statement.step() == .done else { return false }
                    return true
                }
            guard parentExists else { return .conflict }

            let existing = try readExactPlayerJSONRow(context, world: candidate.world)
            switch (expected, existing) {
            case (.absent, nil):
                break
            case let (.present(expectedDigest), existing?):
                guard storageFixedTimeEqual(
                    expectedDigest.data, playerJSONExactDigest(existing)) else {
                    return .conflict
                }
            case (.absent, _?), (.present, nil):
                return .conflict
            }

            let changes: Int
            switch expected {
            case .absent:
                changes = try executeMutation(
                    context, "INSERT INTO player(world,json) VALUES(?,?)"
                ) { statement in
                    try statement.bindText(1, candidate.world)
                    try statement.bindText(2, candidate.json)
                }
            case .present:
                changes = try executeMutation(
                    context, "UPDATE player SET json=? WHERE world=?"
                ) { statement in
                    try statement.bindText(1, candidate.json)
                    try statement.bindText(2, candidate.world)
                }
            }
            guard changes == 1,
                  let stored = try readExactPlayerJSONRow(context, world: candidate.world),
                  stored == candidate,
                  storageFixedTimeEqual(
                    playerJSONExactDigest(stored), playerJSONExactDigest(candidate)) else {
                throw ElysiumStorageError.schemaIntegrity
            }
            return .committed(stored)
        }
    }
}

// MARK: - Private façade helpers

private func legacyCollectionCount(
    _ context: StorageContext, sql: StaticString, maximumRows: Int,
    bind: ((StorageStatement) throws -> Void)? = nil
) throws -> Int {
    try withStatement(context, sql) { statement in
        try bind?(statement)
        guard try statement.step() == .row else { throw ElysiumStorageError.schemaMismatch }
        let count = try statement.int64(0)
        guard count >= 0, count <= Int64(maximumRows) else {
            throw ElysiumStorageError.limitExceeded
        }
        guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
        return Int(count)
    }
}

#if DEBUG
private func injectLegacyImportFailure(_ executor: StorageExecutor,
                                       _ point: StorageLegacyImportFailurePoint) throws {
    if executor.consumeLegacyImportFailure(point) {
        throw storageSQLiteError(SQLITE_IOERR, operation: .step)
    }
}
#endif

private func adjustedLegacyCollectionCount(_ actual: Int,
                                           executor: StorageExecutor) throws -> Int {
#if DEBUG
    if executor.consumeLegacyCollectionFailure(.countDrift) {
        let (adjusted, overflow) = actual.addingReportingOverflow(1)
        guard !overflow else { throw ElysiumStorageError.limitExceeded }
        return adjusted
    }
#endif
    return actual
}

private func validateLegacyRowID(_ rowID: Int64, prior: inout Int64?,
                                 executor: StorageExecutor) throws {
#if DEBUG
    if executor.consumeLegacyCollectionFailure(.nonMonotonicRowID) { prior = rowID }
#endif
    if let prior, rowID <= prior { throw ElysiumStorageError.schemaMismatch }
    prior = rowID
}

private func incrementLegacyScanned(_ scanned: inout Int, expectedCount: Int) throws {
    let (next, overflow) = scanned.addingReportingOverflow(1)
    guard !overflow, next <= expectedCount else { throw ElysiumStorageError.schemaMismatch }
    scanned = next
}

private func addLegacyBytes(_ byteCounts: [Int], total: inout Int64,
                            maximum: Int64) throws {
    var next = total
    for count in byteCounts {
        guard count >= 0 else { throw ElysiumStorageError.invalidValue }
        let (value, overflow) = next.addingReportingOverflow(Int64(count))
        guard !overflow, value <= maximum else { throw ElysiumStorageError.limitExceeded }
        next = value
    }
    total = next
}

private func legacyUTF8Ordered(_ lhs: String, rowID lhsRowID: Int64,
                               before rhs: String, rowID rhsRowID: Int64) -> Bool {
    if lhs.utf8.elementsEqual(rhs.utf8) { return lhsRowID < rhsRowID }
    return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
}

private func scanLegacyWorldJSONPage(
    _ statement: StorageStatement, executor: StorageExecutor,
    priorRowID: inout Int64?, scanned: inout Int, expectedCount: Int,
    accepted: inout [String], acceptedBytes: inout Int64
) throws -> Int {
    var pageCount = 0
    while try statement.step() == .row {
        let rowID = try statement.int64(0)
        try validateLegacyRowID(rowID, prior: &priorRowID, executor: executor)
        try incrementLegacyScanned(&scanned, expectedCount: expectedCount)
        pageCount += 1
        guard let json = try statement.legacyText(
            1, maximumBytes: StorageBounds.manifestText) else { continue }
        try addLegacyBytes([json.utf8.count], total: &acceptedBytes,
                           maximum: Int64(StorageBounds.worldRows)
                            * Int64(StorageBounds.manifestText))
        accepted.append(json)
    }
    return pageCount
}

private func scanLegacyTemplateNamePage(
    _ statement: StorageStatement, executor: StorageExecutor,
    priorRowID: inout Int64?, scanned: inout Int, expectedCount: Int,
    accepted: inout [(rowID: Int64, value: String)], acceptedBytes: inout Int64
) throws -> Int {
    var pageCount = 0
    while try statement.step() == .row {
        let rowID = try statement.int64(0)
        try validateLegacyRowID(rowID, prior: &priorRowID, executor: executor)
        try incrementLegacyScanned(&scanned, expectedCount: expectedCount)
        pageCount += 1
        guard let name = try statement.legacyText(
            1, maximumBytes: StorageBounds.manifestText) else { continue }
        try addLegacyBytes([name.utf8.count], total: &acceptedBytes,
                           maximum: Int64(StorageBounds.templateRows)
                            * Int64(StorageBounds.manifestText))
        accepted.append((rowID, name))
    }
    return pageCount
}

private func scanLegacyTemplateCandidatePage(
    _ statement: StorageStatement, executor: StorageExecutor,
    priorRowID: inout Int64?, scanned: inout Int, expectedCount: Int,
    accepted: inout [(rowID: Int64, value: ElysiumTemplateSummaryCandidate)],
    acceptedBytes: inout Int64
) throws -> Int {
    var pageCount = 0
    while try statement.step() == .row {
        let rowID = try statement.int64(0)
        try validateLegacyRowID(rowID, prior: &priorRowID, executor: executor)
        try incrementLegacyScanned(&scanned, expectedCount: expectedCount)
        pageCount += 1
        guard let name = try statement.legacyText(
            1, maximumBytes: StorageBounds.manifestText) else { continue }
        let dominantBlock = try statement.legacyText(
            7, maximumBytes: StorageBounds.manifestText)
        let dominantDisplay = try statement.legacyText(
            8, maximumBytes: StorageBounds.manifestText)
        try addLegacyBytes([name.utf8.count, dominantBlock?.utf8.count ?? 0,
                            dominantDisplay?.utf8.count ?? 0],
                           total: &acceptedBytes,
                           maximum: Int64(StorageBounds.templateRows)
                            * Int64(StorageBounds.manifestText * 3))
        accepted.append((rowID, .init(
            name: name,
            sizeX: try statement.legacyInt32(2, nonnegative: true),
            sizeY: try statement.legacyInt32(3, nonnegative: true),
            sizeZ: try statement.legacyInt32(4, nonnegative: true),
            blockCount: try statement.legacyInt32(5, nonnegative: true),
            blockEntityCount: try statement.legacyInt32(6, nonnegative: true),
            dominantBlock: dominantBlock, dominantDisplay: dominantDisplay)))
    }
    return pageCount
}

private func withStatement<T>(_ context: StorageContext, _ sql: StaticString,
                              _ body: (StorageStatement) throws -> T) throws -> T {
    let statement = try context.prepare(sql)
    do {
        let value = try body(statement)
        try statement.finalize()
        return value
    } catch {
        let primary = error
        do {
            try statement.finalize()
        } catch let finalize as ElysiumStorageError {
            throw ElysiumStorageStatementFailure(primary: primary, finalize: finalize)
        } catch {
            throw ElysiumStorageStatementFailure(
                primary: primary,
                finalize: storageSQLiteError(SQLITE_ERROR, operation: .finalize))
        }
        throw primary
    }
}

private func executeMutation(_ context: StorageContext, _ sql: StaticString,
                             bind: (StorageStatement) throws -> Void) throws -> Int {
    try withStatement(context, sql) { statement in
        try bind(statement)
        guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
        return try context.changes()
    }
}

#if DEBUG
private func executeRPGLocalTestMutation(
    _ context: StorageContext, statementIndex: Int, _ sql: StaticString,
    bind: (StorageStatement) throws -> Void
) throws -> Int {
    guard let executor = context.executor else { throw ElysiumStorageError.inactiveContext }
    try executor.injectActiveRPGLocalFailure(.prepare(statement: statementIndex))
    let statement = try context.prepare(sql)
    do {
        try executor.injectActiveRPGLocalFailure(.bind(statement: statementIndex))
        try bind(statement)
        try executor.injectActiveRPGLocalFailure(.step(statement: statementIndex))
        guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
        try executor.injectActiveRPGLocalFailure(.changes(statement: statementIndex))
        let changes = try context.changes()
        try statement.finalize()
        try executor.injectActiveRPGLocalFailure(.finalize(statement: statementIndex))
        return changes
    } catch {
        if statement.pointer != nil { try? statement.finalize() }
        throw error
    }
}
#endif

private func executeLegacyMaterializationMutation(
    _ context: StorageContext, statementIndex: Int, _ sql: StaticString,
    bind: (StorageStatement) throws -> Void
) throws -> Int {
#if DEBUG
    try executeRPGLocalTestMutation(
        context, statementIndex: statementIndex, sql, bind: bind)
#else
    try executeMutation(context, sql, bind: bind)
#endif
}

private func executeWorldDeleteMutation(
    _ context: StorageContext, statementIndex: Int, _ sql: StaticString,
    bind: (StorageStatement) throws -> Void
) throws -> Int {
#if DEBUG
    try executeRPGLocalTestMutation(
        context, statementIndex: statementIndex, sql, bind: bind)
#else
    try executeMutation(context, sql, bind: bind)
#endif
}

private func checkCollection(_ context: StorageContext, sql: StaticString,
                             maximumRows: Int, maximumBytes: Int64,
                             bind: ((StorageStatement) throws -> Void)? = nil) throws -> Int {
    try withStatement(context, sql) { statement in
        try bind?(statement)
        guard try statement.step() == .row else { throw ElysiumStorageError.schemaMismatch }
        let rows = try statement.int64(0)
        let bytes = try statement.int64(1)
        guard rows >= 0, rows <= Int64(maximumRows), bytes >= 0, bytes <= maximumBytes else {
            throw ElysiumStorageError.limitExceeded
        }
        guard try statement.step() == .done else { throw ElysiumStorageError.schemaMismatch }
        return Int(rows)
    }
}

private func checkChunkKeyCollection(_ context: StorageContext, world: String) throws -> Int {
    try withStatement(context, """
        SELECT count(*),sum(length(CAST(world AS BLOB))+24)
        FROM chunks WHERE world=?
        """) { statement in
        try statement.bindText(1, world)
        guard try statement.step() == .row else { throw ElysiumStorageError.schemaMismatch }
        let rows = try statement.int64(0)
        let bytes: Int64
        if rows == 0, try statement.isNull(1) {
            bytes = 0
        } else {
            bytes = try statement.int64(1)
        }
        guard rows >= 0, rows <= Int64(StorageBounds.chunkRows),
              bytes >= 0, bytes <= Int64(StorageBounds.chunkKeyBytes),
              try statement.step() == .done else {
            throw ElysiumStorageError.limitExceeded
        }
        return Int(rows)
    }
}

private func bindChunkKey(_ statement: StorageStatement, _ key: ElysiumChunkStorageKey) throws {
    try statement.bindText(1, key.world)
    try statement.bindInt32(2, key.dimension)
    try statement.bindInt32(3, key.chunkX)
    try statement.bindInt32(4, key.chunkZ)
}

private func readChunkKeyPage(_ statement: StorageStatement,
                              world: String) throws -> [ElysiumChunkStorageKey] {
    var rows: [ElysiumChunkStorageKey] = []
    while try statement.step() == .row {
        rows.append(try ElysiumChunkStorageKey(world: world,
                                              dimension: statement.int32(0),
                                              chunkX: statement.int32(1),
                                              chunkZ: statement.int32(2)))
    }
    return rows
}

private func readDataVersion(_ context: StorageContext) throws -> Int64 {
    try withStatement(context, "PRAGMA main.data_version") { statement in
        guard try statement.step() == .row else { throw ElysiumStorageError.schemaMismatch }
        let value = try statement.int64(0)
        guard value >= 0, try statement.step() == .done else {
            throw ElysiumStorageError.schemaMismatch
        }
        return value
    }
}

private func chunkKeyTupleLess(_ lhs: ElysiumChunkStorageKey,
                               _ rhs: ElysiumChunkStorageKey) -> Bool {
    if lhs.dimension != rhs.dimension { return lhs.dimension < rhs.dimension }
    if lhs.chunkX != rhs.chunkX { return lhs.chunkX < rhs.chunkX }
    return lhs.chunkZ < rhs.chunkZ
}

private func readLANPlayer(_ statement: StorageStatement) throws -> ElysiumLANPlayerStorageRow {
    guard let world = try statement.text(0, maximumBytes: StorageBounds.manifestText),
          let playerID = try statement.text(1, maximumBytes: StorageBounds.manifestText),
          let json = try statement.text(2, maximumBytes: StorageBounds.playerJSON) else {
        throw ElysiumStorageError.invalidStorageClass
    }
    return try ElysiumLANPlayerStorageRow(world: world, playerID: playerID, json: json,
                                         updated: statement.double(3))
}

private func readTemplateSummary(_ statement: StorageStatement,
                                 offset: Int32 = 0) throws -> ElysiumTemplateSummaryStorageRow {
    guard let name = try statement.text(offset, maximumBytes: StorageBounds.manifestText),
          let dominantBlock = try statement.text(offset + 6, maximumBytes: StorageBounds.manifestText),
          let dominantDisplay = try statement.text(offset + 7, maximumBytes: StorageBounds.manifestText) else {
        throw ElysiumStorageError.invalidStorageClass
    }
    return try ElysiumTemplateSummaryStorageRow(name: name,
                                               sizeX: statement.int32(offset + 1),
                                               sizeY: statement.int32(offset + 2),
                                               sizeZ: statement.int32(offset + 3),
                                               blockCount: statement.int32(offset + 4),
                                               blockEntityCount: statement.int32(offset + 5),
                                               dominantBlock: dominantBlock,
                                               dominantDisplay: dominantDisplay)
}

private func readTemplate(_ statement: StorageStatement) throws -> ElysiumTemplateStorageRow {
    guard let name = try statement.text(0, maximumBytes: StorageBounds.manifestText),
          let json = try statement.text(1, maximumBytes: StorageBounds.templateJSON),
          let dominantBlock = try statement.text(10, maximumBytes: StorageBounds.manifestText),
          let dominantDisplay = try statement.text(11, maximumBytes: StorageBounds.manifestText) else {
        throw ElysiumStorageError.invalidStorageClass
    }
    let summary = try ElysiumTemplateSummaryStorageRow(name: name,
                                                      sizeX: statement.int32(5),
                                                      sizeY: statement.int32(6),
                                                      sizeZ: statement.int32(7),
                                                      blockCount: statement.int32(8),
                                                      blockEntityCount: statement.int32(9),
                                                      dominantBlock: dominantBlock,
                                                      dominantDisplay: dominantDisplay)
    return try ElysiumTemplateStorageRow(summary: summary, json: json,
                                        created: statement.double(2),
                                        format: statement.int32(3),
                                        data: statement.data(4, maximumBytes: StorageBounds.templateData,
                                                             nullable: true))
}
