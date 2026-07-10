import Foundation
import Dispatch
import SQLite3
import Darwin

// This target is deliberately a single physical persistence boundary. PebbleCore can
// exchange only the primitive row values and named façades declared in this file;
// SQLite handles, SQL, capabilities, contexts, and statements remain private here.

public enum PebbleStorageOperationID: String, Sendable {
    case open, configure, prepare, bind, step, changes, finalize
    case beginImmediate, commit, rollback, authorizer, close
    case checkpoint, durabilitySync
}

public enum PebbleStorageError: Error, Sendable, Equatable {
    case openFailed(primaryCode: Int32, extendedCode: Int32)
    case duplicateOpen
    case sqlite(primaryCode: Int32, extendedCode: Int32, operation: PebbleStorageOperationID)
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
                                operation: PebbleStorageOperationID) -> PebbleStorageError {
    let codes = storageSQLiteCodes(extendedCode)
    return .sqlite(primaryCode: codes.primary, extendedCode: codes.extended,
                   operation: operation)
}

private func storageSQLiteOpenFailure(_ extendedCode: Int32) -> PebbleStorageError {
    let codes = storageSQLiteCodes(extendedCode)
    return .openFailed(primaryCode: codes.primary, extendedCode: codes.extended)
}

extension PebbleStorageError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .openFailed(primary, extended):
            return "PebbleStorage open failed (\(primary)/\(extended))"
        case .duplicateOpen: return "PebbleStorage duplicate open"
        case let .sqlite(primary, extended, operation):
            return "PebbleStorage \(operation.rawValue) failed (\(primary)/\(extended))"
        case .nestedTransaction: return "PebbleStorage nested transaction"
        case .capabilityViolation: return "PebbleStorage capability violation"
        case .inactiveContext: return "PebbleStorage inactive context"
        case .wrongExecutorOrQueue: return "PebbleStorage wrong executor or queue"
        case .statementLeak: return "PebbleStorage statement leak"
        case .transactionStillOpen: return "PebbleStorage transaction still open"
        case .poisoned: return "PebbleStorage poisoned"
        case .closed: return "PebbleStorage closed"
        case .invalidValue: return "PebbleStorage invalid value"
        case .limitExceeded: return "PebbleStorage limit exceeded"
        case .invalidStorageClass: return "PebbleStorage invalid storage class"
        case .invalidUTF8: return "PebbleStorage invalid UTF-8"
        case .schemaMismatch: return "PebbleStorage schema mismatch"
        case .schemaIntegrity: return "PebbleStorage schema integrity failure"
        }
    }
}

public struct PebbleStorageTransactionFailure: Error {
    public let primary: any Error
    public let rollback: PebbleStorageError?
    public let terminal: PebbleStorageError?

    public init(primary: any Error, rollback: PebbleStorageError?, terminal: PebbleStorageError?) {
        self.primary = primary
        self.rollback = rollback
        self.terminal = terminal
    }
}

public struct PebbleStorageStatementFailure: Error {
    public let primary: any Error
    public let finalize: PebbleStorageError

    public init(primary: any Error, finalize: PebbleStorageError) {
        self.primary = primary
        self.finalize = finalize
    }
}

extension PebbleStorageStatementFailure: CustomStringConvertible {
    public var description: String { "PebbleStorage statement and finalize failed" }
}

extension PebbleStorageTransactionFailure: CustomStringConvertible {
    public var description: String {
        // The primary error object is preserved for programmatic inspection but is
        // intentionally never interpolated: caller errors may contain private data.
        "PebbleStorage transaction failed (rollback=\(rollback != nil), terminal=\(terminal != nil))"
    }
}

// MARK: - Primitive storage rows

public struct PebbleWorldStorageRow: Sendable, Equatable {
    public let id: String
    public let json: String
    public let lastPlayed: Double

    public init(id: String, json: String, lastPlayed: Double) throws {
        try StorageBounds.validateIdentifier(id, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateBoundedText(json, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateAggregateBytes([id.utf8.count, json.utf8.count],
                                                 maximumBytes: StorageBounds.manifestText * 2)
        guard lastPlayed.isFinite else { throw PebbleStorageError.invalidValue }
        self.id = id
        self.json = json
        self.lastPlayed = lastPlayed
    }
}

public struct PebbleChunkStorageKey: Sendable, Equatable, Hashable {
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

public struct PebbleChunkStorageRow: Sendable, Equatable {
    public let key: PebbleChunkStorageKey
    public let data: Data

    public init(key: PebbleChunkStorageKey, data: Data) throws {
        guard data.count <= StorageBounds.chunkBlob else { throw PebbleStorageError.limitExceeded }
        try StorageBounds.validateAggregateBytes([key.world.utf8.count, data.count],
                                                 maximumBytes: StorageBounds.chunkVariableBytes)
        self.key = key
        self.data = data
    }
}

public struct PebblePlayerJSONStorageRow: Sendable, Equatable {
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

public struct PebbleLANClientResumeStorageRow: Sendable, Equatable {
    public let hostWorld: String
    public let json: String
    public let updated: Double

    public init(hostWorld: String, json: String, updated: Double) throws {
        try StorageBounds.validateIdentifier(hostWorld, maximumBytes: StorageBounds.manifestText)
        try StorageBounds.validateBoundedText(json, maximumBytes: StorageBounds.playerJSON)
        try StorageBounds.validateAggregateBytes([hostWorld.utf8.count, json.utf8.count],
                                                 maximumBytes: StorageBounds.manifestText
                                                    + StorageBounds.playerJSON)
        guard updated.isFinite else { throw PebbleStorageError.invalidValue }
        self.hostWorld = hostWorld
        self.json = json
        self.updated = updated
    }
}

public struct PebbleLANPlayerStorageRow: Sendable, Equatable {
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
        guard updated.isFinite else { throw PebbleStorageError.invalidValue }
        self.world = world
        self.playerID = playerID
        self.json = json
        self.updated = updated
    }
}

public struct PebbleAdvancementStorageRow: Sendable, Equatable {
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

public struct PebbleTemplateSummaryStorageRow: Sendable, Equatable {
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
            throw PebbleStorageError.invalidValue
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

public struct PebbleTemplateStorageRow: Sendable, Equatable {
    public let summary: PebbleTemplateSummaryStorageRow
    public let json: String
    public let created: Double
    public let format: Int32
    public let data: Data?

    public init(summary: PebbleTemplateSummaryStorageRow, json: String, created: Double,
                format: Int32, data: Data?) throws {
        try StorageBounds.validateBoundedText(json, maximumBytes: StorageBounds.templateJSON)
        guard created.isFinite, format >= 1 else { throw PebbleStorageError.invalidValue }
        if let data, data.count > StorageBounds.templateData {
            throw PebbleStorageError.limitExceeded
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

public struct PebbleLegacyLANPlayerJSON: Sendable, Equatable {
    public let playerID: String
    public let json: String

    public init(playerID: String, json: String) {
        self.playerID = playerID
        self.json = json
    }
}

public struct PebbleLegacyTemplateContent: Sendable, Equatable {
    public let format: Int32?
    public let data: Data?
    public let json: String?

    public init(format: Int32?, data: Data?, json: String?) {
        self.format = format
        self.data = data
        self.json = json
    }
}

public struct PebbleTemplateSummaryCandidate: Sendable, Equatable {
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

public struct PebbleLegacyWorldImport: Sendable, Equatable {
    public let world: PebbleWorldStorageRow
    public let player: PebblePlayerJSONStorageRow?
    public let advancements: PebbleAdvancementStorageRow?
    public let chunks: [PebbleChunkStorageRow]

    public init(world: PebbleWorldStorageRow, player: PebblePlayerJSONStorageRow?,
                advancements: PebbleAdvancementStorageRow?, chunks: [PebbleChunkStorageRow]) throws {
        guard chunks.count <= StorageBounds.chunkRows else { throw PebbleStorageError.limitExceeded }
        guard player?.world == world.id || player == nil,
              advancements?.world == world.id || advancements == nil,
              chunks.allSatisfy({ $0.key.world == world.id }) else {
            throw PebbleStorageError.invalidValue
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
    static let templateRows = 1_024
    static let lanPeerRows = 256
    static let chunkRows = 1_048_576
    static let chunkKeyBytes = 268_435_456
    static let pageRows = 256

    static func validateIdentifier(_ value: String, maximumBytes: Int) throws {
        guard !value.utf8.isEmpty else { throw PebbleStorageError.invalidValue }
        try validateBoundedText(value, maximumBytes: maximumBytes)
    }

    static func validateBoundedText(_ value: String, maximumBytes: Int) throws {
        guard value.utf8.count <= maximumBytes else { throw PebbleStorageError.limitExceeded }
    }

    static func validateAggregateBytes(_ byteCounts: [Int], maximumBytes: Int) throws {
        var total = 0
        for count in byteCounts {
            guard count >= 0 else { throw PebbleStorageError.invalidValue }
            let (next, overflow) = total.addingReportingOverflow(count)
            guard !overflow, next <= maximumBytes else { throw PebbleStorageError.limitExceeded }
            total = next
        }
    }
}

// MARK: - Process-wide physical database lease

private struct StorageFileIdentity: Hashable {
    let device: UInt64
    let inode: UInt64
}

#if DEBUG
private enum StorageLegacyImportFailurePoint: Equatable {
    case deleteWorlds, deleteChunks, deletePlayer, deleteAdvancements
    case insertWorld, insertPlayer, insertAdvancement
    case insertFirstChunk, insertMiddleChunk, insertLastChunk
}

enum PebbleStorageFactoryFailurePoint: Equatable {
    case afterSQLiteOpen
    case beforeBootstrapStatement(Int)
    case quickCheckBudgetExhausted
}

struct PebbleStorageSQLiteLengthLimitProbe: Equatable {
    let configured: Int32
    let exactBindCode: Int32
    let oneOverBindCode: Int32
}

enum PebbleStorageLegacyCollectionFailurePoint: Equatable {
    case countDrift
    case nonMonotonicRowID
}

enum PebbleStorageLegacyImportFailurePoint: Equatable, CaseIterable {
    case deleteWorlds, deleteChunks, deletePlayer, deleteAdvancements
    case insertWorld, insertPlayer, insertAdvancement
    case insertFirstChunk, insertMiddleChunk, insertLastChunk
    case commit
}

enum PebbleStorageBarrierFailurePoint: Equatable {
    case checkpointBusy
    case checkpointRemainingFrames
    case durabilitySyncFailure
}

enum PebbleStorageSchemaAuditProbe: CaseIterable {
    case tempPageCount
    case pageCountArgument
    case missingQuickCheckArgument
    case wrongQuickCheckArgument
    case integrityCheck
    case partialQuickCheck
    case tableValuedPageCount
    case dbstat
}

enum PebbleStorageTestStage: Sendable {
    case afterChunkKeyPreflight
    case afterDurabilitySyncBeforeIdentityProof
}

enum PebbleStorageTestStageError: Error, Equatable {
    case timeout
}

enum PebbleStorageTestDeadlineBoundary {
    case externalWait
    case executorWait
}

final class PebbleStorageTestLatch: @unchecked Sendable {
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
                    throw PebbleStorageTestStageError.timeout
                }
                externalDeadline = deadline
            }
            guard let deadline = externalDeadline else {
                transitionToTerminalLocked(.cancelled)
                throw PebbleStorageTestStageError.timeout
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
                throw PebbleStorageTestStageError.timeout
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
                    throw PebbleStorageTestStageError.timeout
                }
                if resumedAt == nil { resumedAt = now }
                state = .resumed
                signalResumedLocked()
            case .resumed, .consumed:
                break
            case .cancelled, .executorTimedOut:
                throw PebbleStorageTestStageError.timeout
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
            guard state == .armed else { throw PebbleStorageTestStageError.timeout }
            reachedAt = reachedTick
            state = .reached
            signalReachedLocked()
            guard let deadline = checkedDeadline(after: reachedTick) else {
                transitionToTerminalLocked(.executorTimedOut)
                throw PebbleStorageTestStageError.timeout
            }
            resumeDeadline = deadline
            if let requestedAt = resumeRequestedAt {
                guard requestedAt <= reachedTick, reachedTick < deadline else {
                    transitionToTerminalLocked(.executorTimedOut)
                    throw PebbleStorageTestStageError.timeout
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
                throw PebbleStorageTestStageError.timeout
            }
            state = .consumed
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }
    }

    func _testExpireDeadline(_ boundary: PebbleStorageTestDeadlineBoundary) throws {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        expireLocked(at: now)
        do {
            try rejectTerminalLocked()
            switch boundary {
            case .externalWait:
                guard state == .armed else { throw PebbleStorageError.invalidValue }
                if externalDeadline == nil {
                    guard let deadline = checkedDeadline(after: now) else {
                        transitionToTerminalLocked(.cancelled)
                        throw PebbleStorageTestStageError.timeout
                    }
                    externalDeadline = deadline
                }
                externalDeadline = now
            case .executorWait:
                guard state == .reached else { throw PebbleStorageError.invalidValue }
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
            throw PebbleStorageTestStageError.timeout
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
        guard databaseURL.isFileURL else { throw PebbleStorageError.invalidValue }
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
            throw PebbleStorageError.openFailed(primaryCode: code, extendedCode: code)
        }
        var canonicalBuffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard Darwin.realpath(parent.path, &canonicalBuffer) != nil else {
            throw PebbleStorageError.openFailed(primaryCode: Int32(errno), extendedCode: Int32(errno))
        }
        // Do not call URL.standardizedFileURL after POSIX realpath: Foundation maps
        // /private/var back through the /var symlink, which defeats NOFOLLOW.
        let canonicalParentPath = String(cString: canonicalBuffer)
        let canonicalParent = URL(fileURLWithPath: canonicalParentPath, isDirectory: true)
        let filename = standardized.lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else {
            throw PebbleStorageError.invalidValue
        }
        let path = canonicalParent.appendingPathComponent(filename, isDirectory: false).path

        registryLock.lock()
        if reservedPaths.contains(path) || tombstonePaths.contains(path) {
            registryLock.unlock()
            throw PebbleStorageError.duplicateOpen
        }
        reservedPaths.insert(path)
        registryLock.unlock()

        let lease = StoragePathLease(path: path, parentPath: canonicalParentPath,
                                     filename: filename)
        do {
            let parentFD = Darwin.open(canonicalParentPath,
                                       O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard parentFD >= 0 else {
                throw PebbleStorageError.openFailed(primaryCode: Int32(errno),
                                                    extendedCode: Int32(errno))
            }
            lease.parentDescriptor = parentFD
            var parentInfo = stat()
            let parentStatRC = fstat(parentFD, &parentInfo)
            guard parentStatRC == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
                let code = parentStatRC == 0 ? EIO : Int32(errno)
                throw PebbleStorageError.openFailed(primaryCode: code, extendedCode: code)
            }
            lease.parentIdentity = StorageFileIdentity(device: UInt64(parentInfo.st_dev),
                                                       inode: UInt64(parentInfo.st_ino))

            let fd = Darwin.openat(parentFD, filename,
                                   O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                                   S_IRUSR | S_IWUSR)
            guard fd >= 0 else {
                if errno == ELOOP { throw PebbleStorageError.invalidValue }
                throw PebbleStorageError.openFailed(primaryCode: Int32(errno), extendedCode: Int32(errno))
            }
            lease.descriptor = fd
            var info = stat()
            let statRC = fstat(fd, &info)
            guard statRC == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                let code = statRC == 0 ? EIO : Int32(errno)
                throw PebbleStorageError.openFailed(primaryCode: code, extendedCode: code)
            }
            let identity = StorageFileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))

            // SQLite is not opened until this identity reservation succeeds. Thus two
            // path aliases can race through path reservation, but only one can bind the
            // shared (device,inode) lease and reach the SQLite factory.
            registryLock.lock()
            if reservedFiles.contains(identity) || tombstoneFiles.contains(identity) {
                registryLock.unlock()
                throw PebbleStorageError.duplicateOpen
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
            throw PebbleStorageError.openFailed(primaryCode: EIO, extendedCode: EIO)
        }
        var retainedParentInfo = stat()
        let retainedParentRC = fstat(parentDescriptor, &retainedParentInfo)
        guard retainedParentRC == 0,
              (retainedParentInfo.st_mode & S_IFMT) == S_IFDIR,
              UInt64(retainedParentInfo.st_dev) == parentIdentity.device,
              UInt64(retainedParentInfo.st_ino) == parentIdentity.inode else {
            let code = retainedParentRC == 0 ? EIO : Int32(errno)
            throw PebbleStorageError.openFailed(primaryCode: code, extendedCode: code)
        }

        var namedParentInfo = stat()
        let namedParentRC = lstat(parentPath, &namedParentInfo)
        guard namedParentRC == 0,
              (namedParentInfo.st_mode & S_IFMT) == S_IFDIR,
              UInt64(namedParentInfo.st_dev) == parentIdentity.device,
              UInt64(namedParentInfo.st_ino) == parentIdentity.inode else {
            let code = namedParentRC == 0 ? EIO : Int32(errno)
            throw PebbleStorageError.openFailed(primaryCode: code, extendedCode: code)
        }

        var retainedFileInfo = stat()
        let retainedFileRC = fstat(descriptor, &retainedFileInfo)
        guard retainedFileRC == 0, (retainedFileInfo.st_mode & S_IFMT) == S_IFREG,
              UInt64(retainedFileInfo.st_dev) == identity.device,
              UInt64(retainedFileInfo.st_ino) == identity.inode else {
            let code = retainedFileRC == 0 ? EIO : Int32(errno)
            throw PebbleStorageError.openFailed(primaryCode: code, extendedCode: code)
        }

        var namedFileInfo = stat()
        let namedFileRC = fstatat(parentDescriptor, filename, &namedFileInfo, AT_SYMLINK_NOFOLLOW)
        guard namedFileRC == 0, (namedFileInfo.st_mode & S_IFMT) == S_IFREG,
              UInt64(namedFileInfo.st_dev) == identity.device,
              UInt64(namedFileInfo.st_ino) == identity.inode else {
            let code = namedFileRC == 0 ? EIO : Int32(errno)
            throw PebbleStorageError.openFailed(primaryCode: code, extendedCode: code)
        }
    }

    func verifiedParentIdentity() throws -> StorageFileIdentity {
        try verifyPathIdentity()
        guard let parentIdentity else {
            throw PebbleStorageError.openFailed(primaryCode: EIO, extendedCode: EIO)
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
        var count = 0
        for descriptor in 0..<upperBound {
            var info = stat()
            if fstat(Int32(descriptor), &info) == 0,
               UInt64(info.st_dev) == identity.device,
               UInt64(info.st_ino) == identity.inode {
                count += 1
            }
        }
        return count
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
    guard triggerOrView == nil else {
        state.denied = true
        return SQLITE_DENY
    }

    func tableName() -> String? { argument1.map(String.init(cString:)) }
    func columnName() -> String? { argument2.map(String.init(cString:)) }
    func isMainDatabase() -> Bool { cStringEquals(database, "main") }
    func deny() -> Int32 { state.denied = true; return SQLITE_DENY }
    func allowedCoreTable(_ name: String?) -> Bool {
        guard let name else { return false }
        return StorageSchema.coreTables.contains(name)
    }
    func allowedAutomaticIndex() -> Bool {
        guard let index = tableName(), let table = columnName(),
              StorageSchema.coreTables.contains(table) else { return false }
        return index == "sqlite_autoindex_\(table)_1"
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
            return StorageSchema.coreTables.contains(argument)
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
            guard let table, allowedCoreTable(table) else { return deny() }
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
            return allowedCoreTable(tableName()) ? SQLITE_OK : deny()
        case SQLITE_CREATE_INDEX:
            return allowedAutomaticIndex() ? SQLITE_OK : deny()
        case SQLITE_ALTER_TABLE:
            return allowedCoreTable(columnName()) ? SQLITE_OK : deny()
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
            guard let table, allowedCoreTable(table) else { return deny() }
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
           StorageSchema.columns[table]?.contains(columnName() ?? "") == true {
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
enum PebbleStorageTestBodyError: Error { case expected }
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
        guard active else { throw PebbleStorageError.inactiveContext }
        guard let executor else { throw PebbleStorageError.inactiveContext }
        try executor.validate(context: self)
    }

    func latch(_ error: any Error) {
        if firstFailure == nil { firstFailure = error }
    }

    func prepare(_ sql: StaticString) throws -> StorageStatement {
        do {
            try validate()
            guard let executor else { throw PebbleStorageError.inactiveContext }
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
            guard let executor else { throw PebbleStorageError.inactiveContext }
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
            let error = PebbleStorageError.statementLeak
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
        guard let context else { throw PebbleStorageError.inactiveContext }
        try context.validate()
        guard executorGeneration == context.executorGeneration,
              authorizationGeneration == context.authorizationGeneration,
              let pointer else { throw PebbleStorageError.inactiveContext }
        return pointer
    }

    private func checkedBind(_ body: (OpaquePointer) -> Int32) throws {
        do {
            guard let executor else { throw PebbleStorageError.inactiveContext }
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
            let error = PebbleStorageError.invalidValue
            context?.latch(error)
            throw error
        }
        try checkedBind { sqlite3_bind_double($0, index, value) }
    }

    func step() throws -> StorageStepResult {
        do {
            guard let executor else { throw PebbleStorageError.inactiveContext }
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
            guard type == SQLITE_TEXT else { throw PebbleStorageError.invalidStorageClass }
            let byteCount = Int(sqlite3_column_bytes(pointer, column))
            guard byteCount >= 0, byteCount <= maximumBytes else { throw PebbleStorageError.limitExceeded }
            guard let bytes = sqlite3_column_text(pointer, column) else {
                if byteCount == 0 { return "" }
                throw PebbleStorageError.invalidStorageClass
            }
            let data = Data(bytes: bytes, count: byteCount)
            guard let value = String(data: data, encoding: .utf8) else {
                throw PebbleStorageError.invalidUTF8
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
            guard type == SQLITE_BLOB else { throw PebbleStorageError.invalidStorageClass }
            let byteCount = Int(sqlite3_column_bytes(pointer, column))
            guard byteCount >= 0, byteCount <= maximumBytes else { throw PebbleStorageError.limitExceeded }
            guard byteCount > 0 else { return Data() }
            guard let bytes = sqlite3_column_blob(pointer, column) else {
                throw PebbleStorageError.invalidStorageClass
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
            let error = PebbleStorageError.invalidValue
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
                throw PebbleStorageError.invalidStorageClass
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
                throw PebbleStorageError.invalidStorageClass
            }
            let value = sqlite3_column_double(pointer, column)
            guard value.isFinite else { throw PebbleStorageError.invalidValue }
            return value
        } catch {
            context?.latch(error)
            throw error
        }
    }

    func finalize() throws {
        do {
            guard let context, let executor else { throw PebbleStorageError.inactiveContext }
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

    @discardableResult
    func forceFinalize() -> PebbleStorageError? {
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
        case closed(Result<Void, PebbleStorageError>)
    }

    private let queue = DispatchQueue(label: "dev.pebble.storage.sqlite", qos: .utility)
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
    private var injectedFailures: [PebbleStorageOperationID: Int] = [:]
    private var testLeakedRawStatement: OpaquePointer?
    private var authorizationTransitionCoverage: UInt8 = 0
    private var legacyCollectionFailurePoint: PebbleStorageLegacyCollectionFailurePoint?
    private var legacyImportFailurePoint: StorageLegacyImportFailurePoint?
    private var barrierFailurePoint: PebbleStorageBarrierFailurePoint?
    private var activeTestStage: (stage: PebbleStorageTestStage, latch: PebbleStorageTestLatch)?
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
                         failurePoint: PebbleStorageFactoryFailurePoint) throws -> StorageExecutor {
        let closedProbe: (kind: Int, index: Int)
        switch failurePoint {
        case .afterSQLiteOpen:
            closedProbe = (1, 0)
        case let .beforeBootstrapStatement(index):
            guard (0...15).contains(index) else { throw PebbleStorageError.invalidValue }
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

    private func sqliteError(_ operation: PebbleStorageOperationID, code: Int32? = nil) -> PebbleStorageError {
        let extended = code ?? handle.map(sqlite3_extended_errcode) ?? SQLITE_ERROR
        return storageSQLiteError(extended, operation: operation)
    }

    fileprivate func error(_ operation: PebbleStorageOperationID, code: Int32? = nil) -> PebbleStorageError {
        sqliteError(operation, code: code)
    }

    fileprivate func injectIfRequested(_ operation: PebbleStorageOperationID) throws {
#if DEBUG
        if let count = injectedFailures[operation], count > 0 {
            if count == 1 { injectedFailures.removeValue(forKey: operation) }
            else { injectedFailures[operation] = count - 1 }
            throw storageSQLiteError(SQLITE_IOERR, operation: operation)
        }
#endif
    }

    fileprivate func validate(context: StorageContext) throws {
        guard isOnQueue else { throw PebbleStorageError.wrongExecutorOrQueue }
        guard context.active else { throw PebbleStorageError.inactiveContext }
        guard currentContext === context,
              context.executor === self,
              context.executorGeneration == executorGeneration,
              context.authorizationGeneration == authorizationGeneration,
              context.scope == authorizer.scope else {
            throw PebbleStorageError.wrongExecutorOrQueue
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
        guard let handle else { throw PebbleStorageError.closed }
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
        guard let handle else { throw PebbleStorageError.closed }
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
            (SQLITE_LIMIT_TRIGGER_DEPTH, 0),
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
                    throw PebbleStorageError.transactionStillOpen
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
        default: throw PebbleStorageError.schemaMismatch
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
            throw PebbleStorageError.invalidStorageClass
        }
        let byteCount = Int(sqlite3_column_bytes(statement, column))
        guard byteCount >= 0, byteCount <= maximumBytes else { throw PebbleStorageError.limitExceeded }
        guard let bytes = sqlite3_column_text(statement, column) else {
            if byteCount == 0 { return "" }
            throw PebbleStorageError.invalidStorageClass
        }
        let data = Data(bytes: bytes, count: byteCount)
        guard let value = String(data: data, encoding: .utf8) else {
            throw PebbleStorageError.invalidUTF8
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

    private func auditCoreSchema(mode: CoreSchemaAuditMode,
                                 runGlobalQuickCheck: Bool) throws {
        let pageCount = try exactSchemaIntegerPragma("PRAGMA main.page_count")
        let pageSize = try exactSchemaIntegerPragma("PRAGMA main.page_size")
        guard pageCount >= 0,
              pageSize >= 512, pageSize <= 65_536,
              pageSize.nonzeroBitCount == 1 else {
            throw PebbleStorageError.schemaMismatch
        }
        let layouts = try auditSchemaObjects(mode: mode, pageCount: pageCount)
        try auditCoreTableLayouts(layouts)
        if runGlobalQuickCheck {
            try globalQuickCheck(pageCount: pageCount, pageSize: pageSize)
        }
    }

    private func exactSchemaIntegerPragma(_ sql: StaticString) throws -> Int64 {
        try withRawStatement(sql) { statement in
            let rc = sqlite3_step(statement)
            guard rc == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                throw PebbleStorageError.schemaMismatch
            }
            let value = sqlite3_column_int64(statement, 0)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw PebbleStorageError.schemaMismatch
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
                throw PebbleStorageError.schemaMismatch
            }
            let objectCount = sqlite3_column_int64(aggregate, 0)
            let totalBytes = sqlite3_column_int64(aggregate, 1)
            guard objectCount >= 0, objectCount <= 512,
                  totalBytes >= 0, totalBytes <= 1_048_576 else {
                throw PebbleStorageError.limitExceeded
            }
            guard sqlite3_step(aggregate) == SQLITE_DONE else {
                throw PebbleStorageError.schemaMismatch
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
                        throw PebbleStorageError.schemaMismatch
                    }
                    let rootpage = sqlite3_column_int64(page, 3)
                    guard rootpage >= 2, rootpage <= pageCount,
                          observedRoots.insert(rootpage).inserted else {
                        throw PebbleStorageError.schemaMismatch
                    }
                    let sqlType = sqlite3_column_type(page, 4)
                    let schemaSQL: String?
                    if sqlType == SQLITE_TEXT {
                        schemaSQL = try copyRawText(page, column: 4, maximumBytes: 65_536)
                    } else if sqlType != SQLITE_NULL {
                        throw PebbleStorageError.invalidStorageClass
                    } else { schemaSQL = nil }

                    switch type {
                    case "table":
                        guard StorageSchema.coreTables.contains(name), name == table,
                              sqlType == SQLITE_TEXT else {
                            throw PebbleStorageError.schemaMismatch
                        }
                        observedTables.insert(name)
                        observedTableSQL[name] = schemaSQL
                    case "index":
                        guard StorageSchema.indexNameByTable[table] == name,
                              StorageSchema.coreTables.contains(table), sqlType == SQLITE_NULL else {
                            throw PebbleStorageError.schemaMismatch
                        }
                    default:
                        throw PebbleStorageError.schemaMismatch
                    }
                    guard observedObjects.insert(.init(type: type, name: name,
                                                       table: table)).inserted else {
                        throw PebbleStorageError.schemaMismatch
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
            throw PebbleStorageError.schemaMismatch
        }
        if observedObjectCount == 0 {
            guard mode == .compatiblePreBootstrap, pageCount == 0 || pageCount == 1 else {
                throw PebbleStorageError.schemaMismatch
            }
        } else if pageCount < 2 {
            throw PebbleStorageError.schemaMismatch
        }
        if mode == .exactReady, observedTables != StorageSchema.coreTables {
            throw PebbleStorageError.schemaMismatch
        }
        let expectedObjects = StorageSchema.expectedPhysicalObjects(for: observedTables)
        guard observedObjects == expectedObjects,
              mode != .exactReady || observedObjects.count == 13 else {
            throw PebbleStorageError.schemaMismatch
        }

        var layouts: [StorageSchema.Layout] = []
        for table in observedTables.sorted() {
            guard let actualSQL = observedTableSQL[table] else {
                throw PebbleStorageError.schemaMismatch
            }
            if table == "templates" {
                guard let prefix = StorageSchema.templateRevisionSQL.firstIndex(where: {
                    normalizedSchemaSQL($0) == normalizedSchemaSQL(actualSQL)
                }), mode == .compatiblePreBootstrap || prefix == StorageSchema.templateMigrations.count else {
                    throw PebbleStorageError.schemaMismatch
                }
                layouts.append(StorageSchema.templateLayout(prefixCount: prefix))
            } else {
                guard let expectedSQL = StorageSchema.canonicalTableSQL[table],
                      normalizedSchemaSQL(actualSQL) == normalizedSchemaSQL(expectedSQL),
                      let layout = StorageSchema.layouts.first(where: { $0.name == table }) else {
                    throw PebbleStorageError.schemaMismatch
                }
                layouts.append(layout)
            }
        }
        return layouts
    }

    private func globalQuickCheck(pageCount: Int64, pageSize: Int64) throws {
        guard let handle,
              let unsignedPageCount = UInt64(exactly: pageCount),
              let unsignedPageSize = UInt64(exactly: pageSize) else {
            throw PebbleStorageError.schemaIntegrity
        }
        let (pageBytes, pageBytesOverflow) = unsignedPageCount
            .multipliedReportingOverflow(by: unsignedPageSize)
        let (scaledBudget, scaleOverflow) = pageBytes.multipliedReportingOverflow(by: 64)
        let (budget, budgetOverflow) = scaledBudget.addingReportingOverflow(1_000_000)
        guard !pageBytesOverflow, !scaleOverflow, !budgetOverflow else {
            throw PebbleStorageError.schemaIntegrity
        }
        var callbackTicks = budget / 1_000
        if budget % 1_000 != 0 {
            let (incremented, overflow) = callbackTicks.addingReportingOverflow(1)
            guard !overflow else { throw PebbleStorageError.schemaIntegrity }
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
                    throw PebbleStorageError.schemaIntegrity
                }
            }
        } catch {
            throw PebbleStorageError.schemaIntegrity
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
                        throw PebbleStorageError.schemaMismatch
                    }
                    let name = try copyRawText(statement, column: 1, maximumBytes: 65_536)
                    let type = try copyRawText(statement, column: 2, maximumBytes: 32)
                    let notNull = sqlite3_column_int(statement, 3) != 0
                    let defaultType = sqlite3_column_type(statement, 4)
                    let defaultValue: String?
                    if defaultType == SQLITE_NULL { defaultValue = nil }
                    else if defaultType == SQLITE_TEXT {
                        defaultValue = try copyRawText(statement, column: 4, maximumBytes: 1_024)
                    } else { throw PebbleStorageError.schemaMismatch }
                    let primaryKey = Int(sqlite3_column_int(statement, 5))
                    rows.append(.init(name: name, type: type, notNull: notNull,
                                      defaultValue: defaultValue, primaryKey: primaryKey))
                }
                return rows
            }
            guard observed == layout.columns else { throw PebbleStorageError.schemaMismatch }
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
                throw PebbleStorageError.schemaMismatch
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
                throw PebbleStorageError.schemaMismatch
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
                    throw PebbleStorageError.schemaMismatch
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
        guard actualKeyNames == expectedKeyNames else { throw PebbleStorageError.schemaMismatch }
        if layout.withoutRowID {
            guard rows.count == layout.columns.count else { throw PebbleStorageError.schemaMismatch }
            for (index, row) in rows.enumerated() {
                let expected = layout.columns[index]
                guard row.sequence == index, row.columnID == index, row.name == expected.name,
                      !row.descending, row.collation == "BINARY",
                      row.key == (expected.primaryKey > 0) else {
                    throw PebbleStorageError.schemaMismatch
                }
            }
        } else {
            guard rows.count == expectedKeyNames.count + 1,
                  rows.last?.sequence == expectedKeyNames.count,
                  rows.last?.columnID == -1,
                  rows.last?.name == nil, rows.last?.descending == false,
                  rows.last?.collation == "BINARY", rows.last?.key == false else {
                throw PebbleStorageError.schemaMismatch
            }
            for (index, name) in expectedKeyNames.enumerated() {
                guard rows[index].sequence == index,
                      rows[index].columnID == layout.columns.firstIndex(where: { $0.name == name }),
                      rows[index].name == name, !rows[index].descending,
                      rows[index].collation == "BINARY", rows[index].key else {
                    throw PebbleStorageError.schemaMismatch
                }
            }
        }
    }

    private func auditNoForeignKeys(_ layout: StorageSchema.Layout) throws {
        try withRawStatement(layout.foreignKeyPragma) { statement in
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw PebbleStorageError.schemaMismatch
            }
        }
    }

    private func withAuthorization<T>(_ scope: StorageAuthorizationScope,
                                      _ body: () throws -> T) throws -> T {
        precondition(isOnQueue)
        let prior = authorizer.scope
        let priorDenied = authorizer.denied
        guard authorizationTransitionAllowed(from: prior, to: scope) else {
            throw PebbleStorageError.capabilityViolation
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
            guard !authorizer.denied else { throw PebbleStorageError.capabilityViolation }
            return value
        } catch {
            if authorizer.denied { throw PebbleStorageError.capabilityViolation }
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
        case .poisoned: throw PebbleStorageError.poisoned
        case .opening, .closing, .closed: throw PebbleStorageError.closed
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
            throw PebbleStorageError.capabilityViolation
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
            throw PebbleStorageError.capabilityViolation
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
                throw PebbleStorageError.transactionStillOpen
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

    fileprivate func verifyDatabaseParentIdentity(device: UInt64, inode: UInt64) throws {
        try admitted {
            let retained = try verifyRetainedIdentityOrPoison()
            guard retained.device == device, retained.inode == inode else {
                throw PebbleStorageError.invalidValue
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
            throw PebbleStorageError.capabilityViolation
        }
        guard sqlite3_next_stmt(handle, nil) == nil else {
            throw PebbleStorageError.statementLeak
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
            guard currentContext.scope == scope else { throw PebbleStorageError.capabilityViolation }
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
            if error is PebbleStorageStatementFailure { primary = error }
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
        guard let value else { throw PebbleStorageError.invalidValue }
        return value
    }

    private func runImmediateTransaction<T>(scope: StorageAuthorizationScope,
                                            _ body: (StorageContext) throws -> T) throws -> T {
        precondition(isOnQueue)
        guard currentContext == nil, !transactionActive else {
            throw PebbleStorageError.nestedTransaction
        }
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
            try executeTransactionControl("COMMIT", operation: .commit)
            transactionActive = false
            guard let handle, sqlite3_get_autocommit(handle) != 0 else {
                throw PebbleStorageError.transactionStillOpen
            }
        } catch {
            primary = error
        }

        if let primary {
            transactionActive = false
            throw recoverTransactionFailure(primary: primary)
        }
        guard let value else { throw PebbleStorageError.invalidValue }
        return value
    }

    private func executeTransactionControl(_ sql: StaticString,
                                           operation: PebbleStorageOperationID) throws {
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
            throw PebbleStorageError.poisoned
        }
        authorizationGeneration += 1
    }

    private func recoverTransactionFailure(primary: any Error) -> PebbleStorageTransactionFailure {
        var rollbackFailure: PebbleStorageError?
        var terminalFailure: PebbleStorageError?
        if let handle, sqlite3_get_autocommit(handle) == 0 {
            do {
                try executeTransactionControl("ROLLBACK", operation: .rollback)
            } catch let error as PebbleStorageError {
                rollbackFailure = error
            } catch {
                rollbackFailure = storageSQLiteError(SQLITE_ERROR, operation: .rollback)
            }
        }
        if let handle, sqlite3_get_autocommit(handle) == 0 {
            terminalFailure = .transactionStillOpen
            poisonOnQueue()
        }
        return PebbleStorageTransactionFailure(primary: primary,
                                               rollback: rollbackFailure,
                                               terminal: terminalFailure)
    }

#if DEBUG
    fileprivate func testInject(_ operation: PebbleStorageOperationID, count: Int) throws {
        guard count > 0 else { throw PebbleStorageError.invalidValue }
        try admitted { injectedFailures[operation] = count }
    }

    fileprivate func testSetLegacyCollectionFailure(
        _ point: PebbleStorageLegacyCollectionFailurePoint
    ) throws {
        try admitted { legacyCollectionFailurePoint = point }
    }

    fileprivate func consumeLegacyCollectionFailure(
        _ point: PebbleStorageLegacyCollectionFailurePoint
    ) -> Bool {
        precondition(isOnQueue)
        guard legacyCollectionFailurePoint == point else { return false }
        legacyCollectionFailurePoint = nil
        return true
    }

    fileprivate func testSetLegacyImportFailure(
        _ point: PebbleStorageLegacyImportFailurePoint
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

    fileprivate func testSetBarrierFailure(_ point: PebbleStorageBarrierFailurePoint) throws {
        try admitted { barrierFailurePoint = point }
    }

    fileprivate func testArmStage(_ stage: PebbleStorageTestStage) throws
        -> PebbleStorageTestLatch {
        try admitted {
            if let activeTestStage {
                guard activeTestStage.latch.isReapable else {
                    throw PebbleStorageError.invalidValue
                }
                self.activeTestStage = nil
            }
            let latch = PebbleStorageTestLatch()
            activeTestStage = (stage, latch)
            return latch
        }
    }

    fileprivate func observeTestStage(_ stage: PebbleStorageTestStage) throws {
        precondition(isOnQueue)
        guard let active = activeTestStage, active.stage == stage else { return }
        defer {
            if activeTestStage?.latch === active.latch { activeTestStage = nil }
        }
        try active.latch.executorReachAndWait()
    }

    fileprivate func consumeBarrierFailure(_ point: PebbleStorageBarrierFailurePoint) -> Bool {
        precondition(isOnQueue)
        guard barrierFailurePoint == point else { return false }
        barrierFailurePoint = nil
        return true
    }

    fileprivate func testAutocommit() throws -> Bool {
        try admitted {
            guard let handle else { throw PebbleStorageError.closed }
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

    fileprivate func testEscapedStatementRejects() throws -> PebbleStorageError {
        var escaped: StorageStatement?
        do {
            _ = try admitted {
                try runContext(scope: .coreRead(["worlds"])) { context in
                    escaped = try context.prepare("SELECT id FROM worlds ORDER BY id LIMIT 1")
                }
            }
        } catch PebbleStorageError.statementLeak {
            // Expected: the scope force-finalized and invalidated the escaped value.
        }
        do {
            _ = try escaped?.step()
            throw PebbleStorageError.invalidValue
        } catch let error as PebbleStorageError {
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

    fileprivate func testCaughtBindFailureCannotCommit(_ row: PebbleWorldStorageRow) throws {
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
                throw PebbleStorageTestBodyError.expected
            }
        }
    }

    fileprivate func testAuthorizationContract() throws -> UInt8 {
        try admitted {
            let generationBefore = authorizationGeneration
            guard authorizer.scope == .denyAll else { throw PebbleStorageError.invalidValue }

            try withAuthorization(.schemaAudit) {
                try withAuthorization(.schemaAudit) {}
                let scopeBeforeRejection = authorizer.scope
                let denialBeforeRejection = authorizer.denied
                do {
                    try withAuthorization(.configuration) {}
                    throw PebbleStorageError.invalidValue
                } catch PebbleStorageError.capabilityViolation {
                    // Exact expected forbidden widening.
                }
                guard authorizer.scope == scopeBeforeRejection,
                      authorizer.denied == denialBeforeRejection else {
                    throw PebbleStorageError.invalidValue
                }
            }

            do {
                try withAuthorization(.schemaAudit) {
                    do { _ = try prepareRaw("DELETE FROM worlds", operation: .prepare) }
                    catch { /* sticky denial must outlive the caught prepare error */ }
                    try withAuthorization(.schemaAudit) {}
                    guard authorizer.denied else { throw PebbleStorageError.invalidValue }
                }
                throw PebbleStorageError.invalidValue
            } catch PebbleStorageError.capabilityViolation {
                // Exact expected sticky denial.
            }

            guard authorizer.scope == .denyAll, !authorizer.denied,
                  authorizationGeneration == generationBefore else {
                throw PebbleStorageError.invalidValue
            }
            return authorizationTransitionCoverage
        }
    }

    fileprivate func testSchemaAuditDeniedProbe(_ probe: PebbleStorageSchemaAuditProbe) throws {
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

    fileprivate func testSQLiteLengthLimitProbe() throws -> PebbleStorageSQLiteLengthLimitProbe {
        try admitted {
            guard let handle else { throw PebbleStorageError.closed }
            let configured = sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, -1)
            return try withAuthorization(.schemaAudit) {
                try withRawStatement("SELECT ?") { statement in
                    let exact = sqlite3_bind_zeroblob64(
                        statement, 1, sqlite3_uint64(StorageBounds.sqliteLengthLimit))
                    _ = sqlite3_reset(statement)
                    _ = sqlite3_clear_bindings(statement)
                    let oneOver = sqlite3_bind_zeroblob64(
                        statement, 1, sqlite3_uint64(StorageBounds.sqliteLengthLimit + 1))
                    return PebbleStorageSQLiteLengthLimitProbe(
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

    private func prepareRaw(_ sql: StaticString, operation: PebbleStorageOperationID) throws -> OpaquePointer {
        guard let handle else { throw PebbleStorageError.closed }
        var statement: OpaquePointer?
        let rc = sql.withUTF8Buffer { bytes -> Int32 in
            guard let base = bytes.baseAddress else { return SQLITE_MISUSE }
            return sqlite3_prepare_v2(handle,
                                      UnsafeRawPointer(base).assumingMemoryBound(to: CChar.self),
                                      Int32(bytes.count), &statement, nil)
        }
        guard rc == SQLITE_OK, let statement else {
            if authorizer.denied { throw PebbleStorageError.capabilityViolation }
            throw sqliteError(operation, code: rc)
        }
        return statement
    }

    private func withRawStatement<T>(_ sql: StaticString,
                                     operation: PebbleStorageOperationID = .prepare,
                                     _ body: (OpaquePointer) throws -> T) throws -> T {
        let statement = try prepareRaw(sql, operation: operation)
        let value: T
        do {
            value = try body(statement)
        } catch {
            let primary = error
            let finalizeRC = sqlite3_finalize(statement)
            if finalizeRC != SQLITE_OK {
                throw PebbleStorageStatementFailure(primary: primary,
                                                    finalize: sqliteError(.finalize, code: finalizeRC))
            }
            throw primary
        }
        let finalizeRC = sqlite3_finalize(statement)
        guard finalizeRC == SQLITE_OK else { throw sqliteError(.finalize, code: finalizeRC) }
        return value
    }

    private func executePragma(_ sql: StaticString, operation: PebbleStorageOperationID) throws {
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
            throw PebbleStorageError.poisoned
        case .opening, .closing:
            throw PebbleStorageError.closed
        case .open:
            lifecycle = .closing
        }

        do {
            if isOnQueue { try closeOnQueue() }
            else { try queue.sync { try closeOnQueue() } }
            guard handle == nil else {
                lifecycle = .poisoned
                throw PebbleStorageError.poisoned
            }
            lifecycle = .closed(.success(()))
        } catch let error as PebbleStorageError {
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
        } catch let error as PebbleStorageError {
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
            throw PebbleStorageError.transactionStillOpen
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
    ]

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

public final class PebbleStorageCoordinator {
    private let executor: StorageExecutor

    private init(executor: StorageExecutor) {
        self.executor = executor
    }

    public static func open(databaseURL: URL) throws -> PebbleStorageCoordinator {
        PebbleStorageCoordinator(executor: try StorageExecutor.open(databaseURL: databaseURL))
    }

    public func legacyCore() throws -> PebbleLegacyCoreStorage {
        try executor.ensureOpen()
        return PebbleLegacyCoreStorage(executor: executor)
    }

    public func close() throws {
        try executor.close()
    }

    public func verifyDatabaseParentIdentity(device: UInt64, inode: UInt64) throws {
        try executor.verifyDatabaseParentIdentity(device: device, inode: inode)
    }

#if DEBUG
    static func _testOpen(databaseURL: URL,
                          failurePoint: PebbleStorageFactoryFailurePoint) throws
        -> PebbleStorageCoordinator {
        PebbleStorageCoordinator(
            executor: try StorageExecutor.testOpen(databaseURL: databaseURL,
                                                    failurePoint: failurePoint))
    }

    func _testInject(_ operation: PebbleStorageOperationID, count: Int = 1) throws {
        try executor.testInject(operation, count: count)
    }
    func _testSetLegacyCollectionFailure(
        _ point: PebbleStorageLegacyCollectionFailurePoint
    ) throws {
        try executor.testSetLegacyCollectionFailure(point)
    }
    func _testSetLegacyImportFailure(_ point: PebbleStorageLegacyImportFailurePoint) throws {
        try executor.testSetLegacyImportFailure(point)
    }
    func _testSetBarrierFailure(_ point: PebbleStorageBarrierFailurePoint) throws {
        try executor.testSetBarrierFailure(point)
    }
    func _testArmStage(_ stage: PebbleStorageTestStage) throws -> PebbleStorageTestLatch {
        try executor.testArmStage(stage)
    }

    func _testAutocommit() throws -> Bool { try executor.testAutocommit() }
    func _testForeignKeysEnabled() throws -> Bool { try executor.testForeignKeysEnabled() }
    func _testPhysicalIdentityBound() throws -> Bool { try executor.testPhysicalIdentityBound() }
    func _testSameScopeReentry() throws -> Bool { try executor.testSameScopeReentry() }
    func _testEscapedStatementRejects() throws -> PebbleStorageError {
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
    func _testCaughtBindFailureCannotCommit(_ row: PebbleWorldStorageRow) throws {
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
    func _testSchemaAuditDeniedProbe(_ probe: PebbleStorageSchemaAuditProbe) throws {
        try executor.testSchemaAuditDeniedProbe(probe)
    }
    func _testSQLiteLengthLimitProbe() throws -> PebbleStorageSQLiteLengthLimitProbe {
        try executor.testSQLiteLengthLimitProbe()
    }
    func _testExtendedPrimaryKeyConstraint() throws {
        try executor.testExtendedPrimaryKeyConstraint()
    }
#endif
}

public final class PebbleLegacyCoreStorage {
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
            guard scanned == expectedCount else { throw PebbleStorageError.schemaMismatch }
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
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
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
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
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
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
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
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
                return value
            }
        }
    }

    public func listLegacyLANPlayerJSON(world: String) throws -> [PebbleLegacyLANPlayerJSON] {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.legacyLANPlayerCollection { context in
            let actualCount = try legacyCollectionCount(
                context, sql: "SELECT count(ROWID) FROM lan_players WHERE world=?",
                maximumRows: StorageBounds.lanPeerRows) { try $0.bindText(1, world) }
            let expectedCount = try adjustedLegacyCollectionCount(actualCount, executor: executor)
            var scanned = 0
            var priorRowID: Int64?
            var accepted: [(rowID: Int64, value: PebbleLegacyLANPlayerJSON)] = []
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
            guard scanned == expectedCount else { throw PebbleStorageError.schemaMismatch }
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
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
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
            guard scanned == expectedCount else { throw PebbleStorageError.schemaMismatch }
            accepted.sort { legacyUTF8Ordered($0.value, rowID: $0.rowID,
                                               before: $1.value, rowID: $1.rowID) }
            return accepted.map(\.value)
        }
    }

    public func getLegacyTemplateContent(name: String) throws -> PebbleLegacyTemplateContent? {
        try StorageBounds.validateIdentifier(name, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["templates"]) { context in
            try withStatement(context, "SELECT format,data,json FROM templates WHERE name=?") { statement in
                try statement.bindText(1, name)
                guard try statement.step() == .row else { return nil }
                let value = PebbleLegacyTemplateContent(
                    format: try statement.legacyInt32(0),
                    data: try statement.legacyData(1, maximumBytes: StorageBounds.templateData),
                    json: try statement.legacyText(2, maximumBytes: StorageBounds.templateJSON))
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
                return value
            }
        }
    }

    public func listLegacyTemplateSummaryCandidates() throws
        -> [PebbleTemplateSummaryCandidate] {
        try executor.legacyTemplateCollection { context in
            let actualCount = try legacyCollectionCount(
                context, sql: "SELECT count(ROWID) FROM templates",
                maximumRows: StorageBounds.templateRows)
            let expectedCount = try adjustedLegacyCollectionCount(actualCount, executor: executor)
            var scanned = 0
            var priorRowID: Int64?
            var accepted: [(rowID: Int64, value: PebbleTemplateSummaryCandidate)] = []
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
            guard scanned == expectedCount else { throw PebbleStorageError.schemaMismatch }
            accepted.sort { legacyUTF8Ordered($0.value.name, rowID: $0.rowID,
                                               before: $1.value.name, rowID: $1.rowID) }
            return accepted.map(\.value)
        }
    }

    // MARK: Worlds

    public func listWorldRows() throws -> [PebbleWorldStorageRow] {
        try executor.read(tables: ["worlds"]) { context in
            let expectedCount = try checkCollection(context, sql: """
                SELECT count(*),coalesce(sum(
                    length(CAST(id AS BLOB))+length(CAST(json AS BLOB))),0) FROM worlds
                """, maximumRows: StorageBounds.worldRows,
                maximumBytes: Int64(StorageBounds.worldRows) * Int64(StorageBounds.manifestText * 2))
            let result = try withStatement(context, """
                SELECT id,json,lastPlayed FROM worlds ORDER BY id LIMIT 4097
                """) { statement in
                var rows: [PebbleWorldStorageRow] = []
                while try statement.step() == .row {
                    guard rows.count < StorageBounds.worldRows else {
                        throw PebbleStorageError.schemaMismatch
                    }
                        guard let id = try statement.text(0, maximumBytes: StorageBounds.manifestText),
                              let json = try statement.text(1, maximumBytes: StorageBounds.manifestText) else {
                            throw PebbleStorageError.invalidStorageClass
                        }
                        rows.append(try PebbleWorldStorageRow(id: id, json: json,
                                                             lastPlayed: statement.double(2)))
                }
                return rows
            }
            guard result.count == expectedCount else { throw PebbleStorageError.schemaMismatch }
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

    public func getWorldRow(id: String) throws -> PebbleWorldStorageRow? {
        try StorageBounds.validateIdentifier(id, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["worlds"]) { context in
            try withStatement(context, "SELECT id,json,lastPlayed FROM worlds WHERE id=?") { statement in
                try statement.bindText(1, id)
                guard try statement.step() == .row else { return nil }
                guard let storedID = try statement.text(0, maximumBytes: StorageBounds.manifestText),
                      let json = try statement.text(1, maximumBytes: StorageBounds.manifestText) else {
                    throw PebbleStorageError.invalidStorageClass
                }
                let row = try PebbleWorldStorageRow(id: storedID, json: json,
                                                    lastPlayed: statement.double(2))
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
                return row
            }
        }
    }

    public func putWorldRow(_ row: PebbleWorldStorageRow) throws {
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
        return try executor.mutate(tables: ["worlds", "chunks", "player", "advancements"]) { context in
            var changes = 0
            changes += try executeMutation(context, "DELETE FROM worlds WHERE id=?") {
                try $0.bindText(1, id)
            }
            changes += try executeMutation(context, "DELETE FROM chunks WHERE world=?") {
                try $0.bindText(1, id)
            }
            changes += try executeMutation(context, "DELETE FROM player WHERE world=?") {
                try $0.bindText(1, id)
            }
            changes += try executeMutation(context, "DELETE FROM advancements WHERE world=?") {
                try $0.bindText(1, id)
            }
            return changes
        }
    }

    // MARK: Chunks

    public func listChunkKeys(world: String) throws -> [PebbleChunkStorageKey] {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.legacyChunkKeyCollection { context in
            let dataVersionBefore = try readDataVersion(context)
            let expectedCount = try checkChunkKeyCollection(context, world: world)
#if DEBUG
            try executor.observeTestStage(.afterChunkKeyPreflight)
#endif
            var result: [PebbleChunkStorageKey] = []
            var cursor: PebbleChunkStorageKey?
            while true {
                let page: [PebbleChunkStorageKey]
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
                    throw PebbleStorageError.schemaMismatch
                }
                var prior = cursor
                for key in page {
                    if let prior, !chunkKeyTupleLess(prior, key) {
                        throw PebbleStorageError.schemaMismatch
                    }
                    prior = key
                }
                let (nextCount, overflow) = result.count.addingReportingOverflow(page.count)
                guard !overflow, nextCount <= StorageBounds.chunkRows else {
                    throw PebbleStorageError.schemaMismatch
                }
                result.append(contentsOf: page)
                guard page.count == StorageBounds.pageRows, let last = page.last else { break }
                cursor = last
            }
            let dataVersionAfter = try readDataVersion(context)
            guard dataVersionAfter == dataVersionBefore,
                  result.count == expectedCount else {
                throw PebbleStorageError.schemaMismatch
            }
            return result
        }
    }

    public func getChunkBlob(key: PebbleChunkStorageKey) throws -> Data? {
        try executor.read(tables: ["chunks"]) { context in
            try withStatement(context, """
                SELECT data FROM chunks WHERE world=? AND dim=? AND cx=? AND cz=?
                """) { statement in
                try bindChunkKey(statement, key)
                guard try statement.step() == .row else { return nil }
                guard let data = try statement.data(0, maximumBytes: StorageBounds.chunkBlob) else {
                    throw PebbleStorageError.invalidStorageClass
                }
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
                return data
            }
        }
    }

    @discardableResult
    public func putChunkBlobRows(_ rows: [PebbleChunkStorageRow]) throws -> Int {
        guard rows.count <= StorageBounds.chunkRows else { throw PebbleStorageError.limitExceeded }
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

    public func getPlayerJSON(world: String) throws -> PebblePlayerJSONStorageRow? {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["player"]) { context in
            try withStatement(context, "SELECT world,json FROM player WHERE world=?") { statement in
                try statement.bindText(1, world)
                guard try statement.step() == .row else { return nil }
                guard let storedWorld = try statement.text(0, maximumBytes: StorageBounds.manifestText),
                      let json = try statement.text(1, maximumBytes: StorageBounds.playerJSON) else {
                    throw PebbleStorageError.invalidStorageClass
                }
                let row = try PebblePlayerJSONStorageRow(world: storedWorld, json: json)
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
                return row
            }
        }
    }

    public func putPlayerJSON(_ row: PebblePlayerJSONStorageRow) throws {
        _ = try executor.mutate(table: "player") { context in
            try executeMutation(context, "INSERT OR REPLACE INTO player(world,json) VALUES(?,?)") {
                try $0.bindText(1, row.world)
                try $0.bindText(2, row.json)
            }
        }
    }

    public func getLANClientResumeJSON(hostWorld: String) throws -> PebbleLANClientResumeStorageRow? {
        try StorageBounds.validateIdentifier(hostWorld, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["lan_player_resume"]) { context in
            try withStatement(context, """
                SELECT hostWorld,json,updated FROM lan_player_resume WHERE hostWorld=?
                """) { statement in
                try statement.bindText(1, hostWorld)
                guard try statement.step() == .row else { return nil }
                guard let key = try statement.text(0, maximumBytes: StorageBounds.manifestText),
                      let json = try statement.text(1, maximumBytes: StorageBounds.playerJSON) else {
                    throw PebbleStorageError.invalidStorageClass
                }
                let row = try PebbleLANClientResumeStorageRow(hostWorld: key, json: json,
                                                              updated: statement.double(2))
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
                return row
            }
        }
    }

    public func putLANClientResumeJSON(_ row: PebbleLANClientResumeStorageRow) throws {
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

    public func getLANPlayerJSON(world: String, playerID: String) throws -> PebbleLANPlayerStorageRow? {
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
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
                return row
            }
        }
    }

    public func putLANPlayerJSON(_ row: PebbleLANPlayerStorageRow) throws {
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

    public func listLANPlayerJSON(world: String) throws -> [PebbleLANPlayerStorageRow] {
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
                """) { statement -> [PebbleLANPlayerStorageRow] in
                try statement.bindText(1, world)
                var rows: [PebbleLANPlayerStorageRow] = []
                while try statement.step() == .row {
                    guard rows.count < StorageBounds.lanPeerRows else {
                        throw PebbleStorageError.schemaMismatch
                    }
                    rows.append(try readLANPlayer(statement))
                }
                return rows
            }
            guard result.count == expectedCount else { throw PebbleStorageError.schemaMismatch }
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

    public func getAdvancementJSON(world: String) throws -> PebbleAdvancementStorageRow? {
        try StorageBounds.validateIdentifier(world, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["advancements"]) { context in
            try withStatement(context, "SELECT world,json FROM advancements WHERE world=?") { statement in
                try statement.bindText(1, world)
                guard try statement.step() == .row else { return nil }
                guard let key = try statement.text(0, maximumBytes: StorageBounds.manifestText),
                      let json = try statement.text(1, maximumBytes: StorageBounds.manifestText) else {
                    throw PebbleStorageError.invalidStorageClass
                }
                let row = try PebbleAdvancementStorageRow(world: key, json: json)
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
                return row
            }
        }
    }

    public func putAdvancementJSON(_ row: PebbleAdvancementStorageRow) throws {
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
                        throw PebbleStorageError.schemaMismatch
                    }
                    guard let name = try statement.text(0, maximumBytes: StorageBounds.manifestText) else {
                        throw PebbleStorageError.invalidStorageClass
                    }
                    rows.append(name)
                }
                return rows
            }
            guard result.count == expectedCount else { throw PebbleStorageError.schemaMismatch }
            return result
        }
    }

    public func listTemplateSummaries() throws -> [PebbleTemplateSummaryStorageRow] {
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
                """) { statement -> [PebbleTemplateSummaryStorageRow] in
                var rows: [PebbleTemplateSummaryStorageRow] = []
                while try statement.step() == .row {
                    guard rows.count < StorageBounds.templateRows else {
                        throw PebbleStorageError.schemaMismatch
                    }
                    rows.append(try readTemplateSummary(statement))
                }
                return rows
            }
            guard result.count == expectedCount else { throw PebbleStorageError.schemaMismatch }
            return result
        }
    }

    public func getTemplateRow(name: String) throws -> PebbleTemplateStorageRow? {
        try StorageBounds.validateIdentifier(name, maximumBytes: StorageBounds.manifestText)
        return try executor.read(tables: ["templates"]) { context in
            try withStatement(context, """
                SELECT name,json,created,format,data,sizeX,sizeY,sizeZ,blockCount,blockEntityCount,
                       dominantBlock,dominantDisplay FROM templates WHERE name=?
                """) { statement in
                try statement.bindText(1, name)
                guard try statement.step() == .row else { return nil }
                let row = try readTemplate(statement)
                guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
                return row
            }
        }
    }

    @discardableResult
    public func putTemplateRow(_ row: PebbleTemplateStorageRow) throws -> Int {
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
    public func importLegacyWorld(_ value: PebbleLegacyWorldImport) throws -> Int {
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

// MARK: - Private façade helpers

private func legacyCollectionCount(
    _ context: StorageContext, sql: StaticString, maximumRows: Int,
    bind: ((StorageStatement) throws -> Void)? = nil
) throws -> Int {
    try withStatement(context, sql) { statement in
        try bind?(statement)
        guard try statement.step() == .row else { throw PebbleStorageError.schemaMismatch }
        let count = try statement.int64(0)
        guard count >= 0, count <= Int64(maximumRows) else {
            throw PebbleStorageError.limitExceeded
        }
        guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
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
        guard !overflow else { throw PebbleStorageError.limitExceeded }
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
    if let prior, rowID <= prior { throw PebbleStorageError.schemaMismatch }
    prior = rowID
}

private func incrementLegacyScanned(_ scanned: inout Int, expectedCount: Int) throws {
    let (next, overflow) = scanned.addingReportingOverflow(1)
    guard !overflow, next <= expectedCount else { throw PebbleStorageError.schemaMismatch }
    scanned = next
}

private func addLegacyBytes(_ byteCounts: [Int], total: inout Int64,
                            maximum: Int64) throws {
    var next = total
    for count in byteCounts {
        guard count >= 0 else { throw PebbleStorageError.invalidValue }
        let (value, overflow) = next.addingReportingOverflow(Int64(count))
        guard !overflow, value <= maximum else { throw PebbleStorageError.limitExceeded }
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
    accepted: inout [(rowID: Int64, value: PebbleTemplateSummaryCandidate)],
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
        } catch let finalize as PebbleStorageError {
            throw PebbleStorageStatementFailure(primary: primary, finalize: finalize)
        } catch {
            throw PebbleStorageStatementFailure(
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
        guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
        return try context.changes()
    }
}

private func checkCollection(_ context: StorageContext, sql: StaticString,
                             maximumRows: Int, maximumBytes: Int64,
                             bind: ((StorageStatement) throws -> Void)? = nil) throws -> Int {
    try withStatement(context, sql) { statement in
        try bind?(statement)
        guard try statement.step() == .row else { throw PebbleStorageError.schemaMismatch }
        let rows = try statement.int64(0)
        let bytes = try statement.int64(1)
        guard rows >= 0, rows <= Int64(maximumRows), bytes >= 0, bytes <= maximumBytes else {
            throw PebbleStorageError.limitExceeded
        }
        guard try statement.step() == .done else { throw PebbleStorageError.schemaMismatch }
        return Int(rows)
    }
}

private func checkChunkKeyCollection(_ context: StorageContext, world: String) throws -> Int {
    try withStatement(context, """
        SELECT count(*),sum(length(CAST(world AS BLOB))+24)
        FROM chunks WHERE world=?
        """) { statement in
        try statement.bindText(1, world)
        guard try statement.step() == .row else { throw PebbleStorageError.schemaMismatch }
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
            throw PebbleStorageError.limitExceeded
        }
        return Int(rows)
    }
}

private func bindChunkKey(_ statement: StorageStatement, _ key: PebbleChunkStorageKey) throws {
    try statement.bindText(1, key.world)
    try statement.bindInt32(2, key.dimension)
    try statement.bindInt32(3, key.chunkX)
    try statement.bindInt32(4, key.chunkZ)
}

private func readChunkKeyPage(_ statement: StorageStatement,
                              world: String) throws -> [PebbleChunkStorageKey] {
    var rows: [PebbleChunkStorageKey] = []
    while try statement.step() == .row {
        rows.append(try PebbleChunkStorageKey(world: world,
                                              dimension: statement.int32(0),
                                              chunkX: statement.int32(1),
                                              chunkZ: statement.int32(2)))
    }
    return rows
}

private func readDataVersion(_ context: StorageContext) throws -> Int64 {
    try withStatement(context, "PRAGMA main.data_version") { statement in
        guard try statement.step() == .row else { throw PebbleStorageError.schemaMismatch }
        let value = try statement.int64(0)
        guard value >= 0, try statement.step() == .done else {
            throw PebbleStorageError.schemaMismatch
        }
        return value
    }
}

private func chunkKeyTupleLess(_ lhs: PebbleChunkStorageKey,
                               _ rhs: PebbleChunkStorageKey) -> Bool {
    if lhs.dimension != rhs.dimension { return lhs.dimension < rhs.dimension }
    if lhs.chunkX != rhs.chunkX { return lhs.chunkX < rhs.chunkX }
    return lhs.chunkZ < rhs.chunkZ
}

private func readLANPlayer(_ statement: StorageStatement) throws -> PebbleLANPlayerStorageRow {
    guard let world = try statement.text(0, maximumBytes: StorageBounds.manifestText),
          let playerID = try statement.text(1, maximumBytes: StorageBounds.manifestText),
          let json = try statement.text(2, maximumBytes: StorageBounds.playerJSON) else {
        throw PebbleStorageError.invalidStorageClass
    }
    return try PebbleLANPlayerStorageRow(world: world, playerID: playerID, json: json,
                                         updated: statement.double(3))
}

private func readTemplateSummary(_ statement: StorageStatement,
                                 offset: Int32 = 0) throws -> PebbleTemplateSummaryStorageRow {
    guard let name = try statement.text(offset, maximumBytes: StorageBounds.manifestText),
          let dominantBlock = try statement.text(offset + 6, maximumBytes: StorageBounds.manifestText),
          let dominantDisplay = try statement.text(offset + 7, maximumBytes: StorageBounds.manifestText) else {
        throw PebbleStorageError.invalidStorageClass
    }
    return try PebbleTemplateSummaryStorageRow(name: name,
                                               sizeX: statement.int32(offset + 1),
                                               sizeY: statement.int32(offset + 2),
                                               sizeZ: statement.int32(offset + 3),
                                               blockCount: statement.int32(offset + 4),
                                               blockEntityCount: statement.int32(offset + 5),
                                               dominantBlock: dominantBlock,
                                               dominantDisplay: dominantDisplay)
}

private func readTemplate(_ statement: StorageStatement) throws -> PebbleTemplateStorageRow {
    guard let name = try statement.text(0, maximumBytes: StorageBounds.manifestText),
          let json = try statement.text(1, maximumBytes: StorageBounds.templateJSON),
          let dominantBlock = try statement.text(10, maximumBytes: StorageBounds.manifestText),
          let dominantDisplay = try statement.text(11, maximumBytes: StorageBounds.manifestText) else {
        throw PebbleStorageError.invalidStorageClass
    }
    let summary = try PebbleTemplateSummaryStorageRow(name: name,
                                                      sizeX: statement.int32(5),
                                                      sizeY: statement.int32(6),
                                                      sizeZ: statement.int32(7),
                                                      blockCount: statement.int32(8),
                                                      blockEntityCount: statement.int32(9),
                                                      dominantBlock: dominantBlock,
                                                      dominantDisplay: dominantDisplay)
    return try PebbleTemplateStorageRow(summary: summary, json: json,
                                        created: statement.double(2),
                                        format: statement.int32(3),
                                        data: statement.data(4, maximumBytes: StorageBounds.templateData,
                                                             nullable: true))
}
