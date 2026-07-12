import Foundation
import CryptoKit
import Darwin
import PebbleStorage

private func legacyDeviceBitPattern(_ device: dev_t) -> UInt64 {
    UInt64(UInt32(bitPattern: device))
}

#if DEBUG
func legacyDeviceBitPatternForTesting(_ device: dev_t) -> UInt64 {
    legacyDeviceBitPattern(device)
}
#endif

fileprivate struct LegacyFileIdentity: Equatable, Hashable {
    let device: UInt64
    let inode: UInt64
}

private struct LegacyStatIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let owner: UInt32
    let links: UInt64
    let size: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64

    init(_ value: stat) throws {
        guard value.st_size >= 0 else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
        }
        device = legacyDeviceBitPattern(value.st_dev)
        inode = UInt64(value.st_ino)
        mode = UInt16(value.st_mode)
        owner = value.st_uid
        links = UInt64(value.st_nlink)
        size = UInt64(value.st_size)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
    }

    var fileIdentity: LegacyFileIdentity {
        LegacyFileIdentity(device: device, inode: inode)
    }
}

private struct LegacyRenameBoundaryObservation {
    let returnedSuccess: Bool
    let source: LegacyFileIdentity?
    let destination: LegacyFileIdentity?
    let syncSucceeded: Bool
}

private enum LegacyRenameBoundaryBranch {
    case forwardSource
    case reverseSource
    case markerRollback
}

#if DEBUG
enum LegacyMigrationTestRenameBranch: CaseIterable, Equatable {
    case forwardSource
    case reverseSource
    case markerRollback
}

enum LegacyMigrationTestRenameState: CaseIterable, Equatable {
    case source
    case destination
    case both
    case neither
    case foreign
}

enum LegacyMigrationTestCut: String, CaseIterable, Equatable {
    case beforeImport
    case beforeBarrier
    case beforeRename
    case failParentSync
    case afterRenameBeforeSync
    case afterParentSync
    case beforeReopen
    case afterReopenBeforeMarker
}

enum LegacyMigrationTestHashMutation: CaseIterable {
    case truncate
    case grow
    case replace
}
#endif

fileprivate enum LegacyNamespaceState {
    case empty
    case source
    case backup
}

final class LegacyMigrationPreflight {
    fileprivate let parentFD: Int32
    fileprivate let parentIdentity: LegacyFileIdentity
    fileprivate let databaseName: String
    fileprivate let lockFD: Int32
    fileprivate let state: LegacyNamespaceState
    fileprivate let sourceFD: Int32
    fileprivate let backupFD: Int32
    fileprivate let namespaceIdentity: LegacyFileIdentity?
    fileprivate let lockIdentity: LegacyStatIdentity
    fileprivate var namespaceStatIdentity: LegacyStatIdentity?
    private let registryIdentity: LegacyFileIdentity

    fileprivate init(parentFD: Int32, parentIdentity: LegacyFileIdentity, databaseName: String,
                     lockFD: Int32, state: LegacyNamespaceState, sourceFD: Int32,
                     backupFD: Int32, namespaceIdentity: LegacyFileIdentity?,
                     lockIdentity: LegacyStatIdentity,
                     namespaceStatIdentity: LegacyStatIdentity?) {
        self.parentFD = parentFD
        self.parentIdentity = parentIdentity
        self.databaseName = databaseName
        self.lockFD = lockFD
        self.state = state
        self.sourceFD = sourceFD
        self.backupFD = backupFD
        self.namespaceIdentity = namespaceIdentity
        self.lockIdentity = lockIdentity
        self.namespaceStatIdentity = namespaceStatIdentity
        registryIdentity = parentIdentity
    }

    deinit {
        if sourceFD >= 0 { Darwin.close(sourceFD) }
        if backupFD >= 0 { Darwin.close(backupFD) }
        if lockFD >= 0 { Darwin.close(lockFD) }
        if parentFD >= 0 { Darwin.close(parentFD) }
        LegacySaveMigration.releaseProcessLease(registryIdentity)
    }
}

struct LegacyMigrationStorageSession {
    let coordinator: PebbleStorageCoordinator
    let storage: PebbleLegacyCoreStorage
}

private struct LegacyManifestEntry: Equatable {
    enum Kind: UInt8 { case directory = 1, file = 2 }
    let components: [String]
    let rawPath: Data
    let kind: Kind
    let identity: LegacyStatIdentity
    let digest: Data
}

private struct LegacyManifest: Equatable {
    let entries: [LegacyManifestEntry]
    let root: Data
    let sourceBytes: UInt64
    let residentCharge: UInt64

    func entry(_ components: [String]) -> LegacyManifestEntry? {
        entries.first { $0.components == components }
    }

    func children(of components: [String]) -> [LegacyManifestEntry] {
        entries.filter { $0.components.count == components.count + 1
            && Array($0.components.dropLast()) == components }
    }
}

private final class LegacyResidentLedger {
    private var current: UInt64
    private(set) var peakCharge: UInt64

    init(initial: UInt64) throws {
        guard initial <= LegacySaveMigration.residentLimit else {
            throw SaveDBOpenError(stage: .migrationDecode, result: .limitExceeded)
        }
        current = initial
        peakCharge = initial
    }

    func reserve(_ amount: UInt64) throws -> LegacyResidentReservation {
        let (next, overflow) = current.addingReportingOverflow(amount)
        guard !overflow, next <= LegacySaveMigration.residentLimit else {
            throw SaveDBOpenError(stage: .migrationDecode, result: .limitExceeded)
        }
        current = next
        peakCharge = max(peakCharge, next)
        return LegacyResidentReservation(ledger: self, amount: amount)
    }

    fileprivate func release(_ amount: UInt64) {
        precondition(amount <= current)
        current -= amount
    }
    fileprivate var currentCharge: UInt64 { current }
}

private final class LegacyResidentReservation {
    private weak var ledger: LegacyResidentLedger?
    private let amount: UInt64
    init(ledger: LegacyResidentLedger, amount: UInt64) { self.ledger = ledger; self.amount = amount }
    deinit { ledger?.release(amount) }
}

private struct LegacyMaterializedBytes {
    let data: Data
    let reservation: LegacyResidentReservation
}

/// Streaming preflight for every legacy JSON document before Foundation materializes it.
/// The returned value is the conservative graph/container/string resident charge.
func legacyMigrationJSONBudget(_ data: Data) -> UInt64? {
    guard legacyMigrationUTF8Valid(data) else { return nil }
    let bytes = data
    var index = 0
    var depth = 0
    var nodes: UInt64 = 0
    var containers: UInt64 = 0
    var members: UInt64 = 0
    var elements: UInt64 = 0
    var totalStringBytes: UInt64 = 0

    func add(_ value: inout UInt64, _ amount: UInt64, cap: UInt64) -> Bool {
        let (next, overflow) = value.addingReportingOverflow(amount)
        guard !overflow, next <= cap else { return false }
        value = next
        return true
    }

    while index < bytes.count {
        let byte = bytes[index]
        if byte == 32 || byte == 9 || byte == 10 || byte == 13 {
            index += 1
            continue
        }
        if byte == 123 || byte == 91 {
            depth += 1
            guard depth <= 128,
                  add(&containers, 1, cap: 65_536),
                  add(&nodes, 1, cap: 262_144) else { return nil }
            index += 1
            continue
        }
        if byte == 125 || byte == 93 {
            depth -= 1
            guard depth >= 0 else { return nil }
            index += 1
            continue
        }
        if byte == 58 {
            guard add(&members, 1, cap: 131_072) else { return nil }
            index += 1
            continue
        }
        if byte == 44 {
            guard add(&elements, 1, cap: 262_144) else { return nil }
            index += 1
            continue
        }
        if byte == 34 {
            index += 1
            var decodedBytes: UInt64 = 0
            var terminated = false
            while index < bytes.count {
                let current = bytes[index]
                if current == 34 {
                    index += 1
                    terminated = true
                    break
                }
                if current < 0x20 { return nil }
                if current == 92 {
                    index += 1
                    guard index < bytes.count else { return nil }
                    if bytes[index] == 117 {
                        guard index + 4 < bytes.count,
                              bytes[(index + 1)...(index + 4)].allSatisfy({
                                  (48...57).contains($0) || (65...70).contains($0)
                                      || (97...102).contains($0)
                              }) else { return nil }
                        decodedBytes += 4 // conservative UTF-8 maximum for one scalar
                        index += 5
                        continue
                    }
                    guard [34, 92, 47, 98, 102, 110, 114, 116].contains(bytes[index]) else {
                        return nil
                    }
                    decodedBytes += 1
                    index += 1
                    continue
                }
                decodedBytes += 1
                index += 1
            }
            guard terminated, decodedBytes <= 1_048_576,
                  add(&totalStringBytes, decodedBytes, cap: 2_097_152),
                  add(&nodes, 1, cap: 262_144) else { return nil }
            continue
        }
        if byte == 45 || (48...57).contains(byte) {
            let start = index
            index += 1
            while index < bytes.count,
                  (48...57).contains(bytes[index]) || [43, 45, 46, 69, 101].contains(bytes[index]) {
                index += 1
            }
            guard index - start <= 64, add(&nodes, 1, cap: 262_144) else { return nil }
            continue
        }
        let remaining = bytes[index...]
        if remaining.starts(with: [116, 114, 117, 101]) {
            index += 4
        } else if remaining.starts(with: [102, 97, 108, 115, 101]) {
            index += 5
        } else if remaining.starts(with: [110, 117, 108, 108]) {
            index += 4
        } else {
            return nil
        }
        guard add(&nodes, 1, cap: 262_144) else { return nil }
    }
    guard depth == 0 else { return nil }
    let nodeCharge = nodes.multipliedReportingOverflow(by: 256)
    let containerCharge = containers.multipliedReportingOverflow(by: 128)
    let stringCharge = totalStringBytes.multipliedReportingOverflow(by: 4)
    guard !nodeCharge.overflow, !containerCharge.overflow, !stringCharge.overflow else { return nil }
    let (partial, overflow1) = nodeCharge.partialValue.addingReportingOverflow(containerCharge.partialValue)
    let (total, overflow2) = partial.addingReportingOverflow(stringCharge.partialValue)
    return overflow1 || overflow2 ? nil : total
}

private func legacyMigrationUTF8Valid(_ data: Data) -> Bool {
    let bytes = data
    var index = 0
    func continuation(_ offset: Int) -> UInt8? {
        guard offset < bytes.count, (0x80...0xbf).contains(bytes[offset]) else { return nil }
        return bytes[offset]
    }
    while index < bytes.count {
        let first = bytes[index]
        if first <= 0x7f { index += 1; continue }
        if (0xc2...0xdf).contains(first) {
            guard continuation(index + 1) != nil else { return false }
            index += 2
            continue
        }
        if (0xe0...0xef).contains(first) {
            guard let second = continuation(index + 1), continuation(index + 2) != nil,
                  first != 0xe0 || second >= 0xa0,
                  first != 0xed || second <= 0x9f else { return false }
            index += 3
            continue
        }
        if (0xf0...0xf4).contains(first) {
            guard let second = continuation(index + 1), continuation(index + 2) != nil,
                  continuation(index + 3) != nil,
                  first != 0xf0 || second >= 0x90,
                  first != 0xf4 || second <= 0x8f else { return false }
            index += 4
            continue
        }
        return false
    }
    return true
}

private struct PreparedLegacyWorld {
    let record: WorldRecord
    let world: PebbleWorldStorageRow
    let player: PebblePlayerJSONStorageRow?
    let advancements: PebbleAdvancementStorageRow?
    let chunks: [PebbleChunkStorageRow]
    let residentReservations: [LegacyResidentReservation]

    var primitiveImport: PebbleLegacyWorldImport? {
        try? PebbleLegacyWorldImport(world: world, player: player,
                                     advancements: advancements, chunks: chunks)
    }
}

#if DEBUG
struct LegacyMigrationLedgerProbe: Equatable {
    static let residentCap: UInt64 = 1_073_741_824

    static func checkedCharge(current: UInt64, amount: UInt64) -> UInt64? {
        let (next, overflow) = current.addingReportingOverflow(amount)
        guard !overflow, next <= residentCap else { return nil }
        return next
    }

    static func manifestCharge(filenameBytes: UInt64) -> UInt64? {
        let (value, overflow) = UInt64(256).addingReportingOverflow(filenameBytes)
        return overflow ? nil : value
    }

    static func ownedBufferCharge(length: UInt64) -> UInt64? {
        let (roundedSeed, overflow) = length.addingReportingOverflow(15)
        guard !overflow else { return nil }
        let rounded = roundedSeed & ~UInt64(15)
        let (value, finalOverflow) = rounded.addingReportingOverflow(64)
        return finalOverflow ? nil : value
    }
}

struct LegacyMigrationManifestProbe: Equatable {
    let root: Data
    let paths: [Data]
    let sourceBytes: UInt64
    let residentCharge: UInt64
}

enum LegacyMigrationJSONShapeProbe: CaseIterable {
    case world
    case player
    case advancements
}

extension LegacySaveMigration {
    static func _testValidateLease(_ preflight: LegacyMigrationPreflight) throws {
        try validateLease(preflight, namespaceName: namespaceName(for: preflight.state),
                          stage: .migrationLease)
    }

    static func _testResidentReservationLifecycle(initial: UInt64, amount: UInt64)
        -> (before: UInt64, during: UInt64, after: UInt64)? {
        guard let ledger = try? LegacyResidentLedger(initial: initial) else { return nil }
        let before = ledger.currentCharge
        var during: UInt64 = before
        do {
            guard let reservation = try? ledger.reserve(amount) else { return nil }
            during = ledger.currentCharge
            withExtendedLifetime(reservation) {}
        }
        return (before, during, ledger.currentCharge)
    }

    static func _testDiscoveryReservationPeak(initial: UInt64, input: Data,
                                              stem: String, filename: String) -> UInt64? {
        guard let ledger = try? LegacyResidentLedger(initial: initial),
              let graphCharge = legacyMigrationJSONBudget(input) else { return nil }
        do {
            let materialized = try ledger.reserve(roundedBufferCharge(UInt64(input.count)))
            let graph = try ledger.reserve(graphCharge)
            let bridge = try ledger.reserve(try discoveryFoundationBridgeCharge(
                inputBytes: UInt64(input.count)))
            let canonical = stem.precomposedStringWithCanonicalMapping
            let persistent = try ledger.reserve(try discoveryPersistentCharge(
                stemBytes: UInt64(stem.utf8.count),
                canonicalBytes: UInt64(canonical.utf8.count),
                filenameBytes: UInt64(filename.utf8.count)))
            withExtendedLifetime((materialized, graph, bridge, persistent)) {}
            return ledger.peakCharge
        } catch {
            return nil
        }
    }

    static func _testGlobalChunkCandidateCountAllowed(_ count: Int) -> Bool {
        count >= 0 && count <= maximumChunks
    }

    static func _testStreamingUTF8Valid(_ data: Data) -> Bool {
        legacyMigrationUTF8Valid(data)
    }

    static func _testParseChunkName(_ name: String) -> (Int32, Int32, Int32)? {
        parseChunkName(name).map { ($0.dimension, $0.chunkX, $0.chunkZ) }
    }

    static func _testValidateLegacyVCK(_ data: Data, dimension: Int) -> Bool {
        validateLegacyVCKStructure(data, dimension: dimension)
    }

    static func _testJSONShape(_ data: Data, shape: LegacyMigrationJSONShapeProbe) -> Bool {
        guard legacyMigrationJSONBudget(data) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        switch shape {
        case .world: return (try? JSONDecoder().decode(WorldRecord.self, from: data)) != nil
        case .player: return validJSONDomainShape(object, shape: .object)
        case .advancements: return validJSONDomainShape(object, shape: .stringArray)
        }
    }

    static func _testManifestProbe(rootURL: URL) throws -> LegacyMigrationManifestProbe {
        let fd = Darwin.open(rootURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
        }
        defer { Darwin.close(fd) }
        let manifest = try buildManifest(rootFD: fd)
        return LegacyMigrationManifestProbe(
            root: manifest.root, paths: manifest.entries.map(\.rawPath),
            sourceBytes: manifest.sourceBytes, residentCharge: manifest.residentCharge)
    }

}
#endif

enum LegacySaveMigration {
    private static let sourceName = "saves"
    private static let backupName = "saves-legacy-backup"
    private static let lockName = ".pebble-legacy-migration.lock"
    private static let provenanceName = ".pebble-legacy-migration-v2"
    private static let provenanceTempName = ".pebble-legacy-migration-v2.tmp"
    private static let recoveryName = ".pebble-legacy-backup-recovery-required"
    private static let recoveryTempName = ".pebble-legacy-backup-recovery-required.tmp"

    private static let maximumWorldBytes: UInt64 = 1_048_576
    private static let maximumPlayerBytes: UInt64 = 786_432
    private static let maximumAdvancementBytes: UInt64 = 1_048_576
    private static let maximumChunkBytes: UInt64 = 67_108_864
    private static let maximumWorlds = 4_096
    private static let maximumChunks = 1_048_576
    private static let maximumEntries = 1_060_864
    private static let maximumFilenameBytes: UInt64 = 268_435_456
    private static let maximumSourceBytes: UInt64 = 2_147_483_648
    private static let maximumWorldChunkBytes: UInt64 = 268_435_456
    private static let maximumResidentBytes: UInt64 = 1_073_741_824
    fileprivate static var residentLimit: UInt64 { maximumResidentBytes }

    private static func renameBoundaryAccepted(_ branch: LegacyRenameBoundaryBranch,
                                               observation: LegacyRenameBoundaryObservation,
                                               expected: LegacyFileIdentity) -> Bool {
        guard observation.syncSucceeded else { return false }
        switch branch {
        case .forwardSource:
            return observation.source == nil && observation.destination == expected
        case .reverseSource, .markerRollback:
            return observation.source == expected && observation.destination == nil
        }
    }

#if DEBUG
    private static let testCutLock = NSLock()
    private static var armedTestCut: (point: LegacyMigrationTestCut, crash: Bool)?
    private static var armedHashMutation: LegacyMigrationTestHashMutation?

    static func _testArmCut(_ point: LegacyMigrationTestCut, crash: Bool = false) {
        testCutLock.lock()
        armedTestCut = (point, crash)
        testCutLock.unlock()
    }

    private static func consumeTestCut(_ point: LegacyMigrationTestCut) -> Bool {
        testCutLock.lock()
        defer { testCutLock.unlock() }
        guard let armed = armedTestCut, armed.point == point else { return false }
        armedTestCut = nil
        if armed.crash { _exit(86) }
        return true
    }

    static func _testArmHashMutation(_ mutation: LegacyMigrationTestHashMutation) {
        testCutLock.lock()
        armedHashMutation = mutation
        testCutLock.unlock()
    }

    private static func consumeHashMutation() -> LegacyMigrationTestHashMutation? {
        testCutLock.lock()
        defer { testCutLock.unlock() }
        let value = armedHashMutation
        armedHashMutation = nil
        return value
    }

    static func _testInjectRenameBoundary(branch: LegacyMigrationTestRenameBranch,
                                          state: LegacyMigrationTestRenameState,
                                          returnedSuccess: Bool,
                                          syncSucceeded: Bool,
                                          expectedURL: URL,
                                          foreignURL: URL) throws -> Bool {
        func capturedIdentity(_ url: URL) throws -> LegacyFileIdentity {
            var value = stat()
            guard lstat(url.path, &value) == 0 else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
            return LegacyFileIdentity(
                device: legacyDeviceBitPattern(value.st_dev), inode: UInt64(value.st_ino))
        }
        let expected = try capturedIdentity(expectedURL)
        let foreign = try capturedIdentity(foreignURL)
        let source: LegacyFileIdentity?
        let destination: LegacyFileIdentity?
        switch state {
        case .source: (source, destination) = (expected, nil)
        case .destination: (source, destination) = (nil, expected)
        case .both: (source, destination) = (expected, expected)
        case .neither: (source, destination) = (nil, nil)
        case .foreign:
            if branch == .forwardSource { (source, destination) = (nil, foreign) }
            else { (source, destination) = (foreign, nil) }
        }
        let productionBranch: LegacyRenameBoundaryBranch
        switch branch {
        case .forwardSource: productionBranch = .forwardSource
        case .reverseSource: productionBranch = .reverseSource
        case .markerRollback: productionBranch = .markerRollback
        }
        return renameBoundaryAccepted(
            productionBranch,
            observation: LegacyRenameBoundaryObservation(
                returnedSuccess: returnedSuccess, source: source,
                destination: destination, syncSucceeded: syncSucceeded),
            expected: expected)
    }
#endif

    private static let processLeaseLock = NSLock()
    private static var processLeases = Set<LegacyFileIdentity>()

    private static func cleanupMappedError(coordinator: PebbleStorageCoordinator,
                                           primary: SaveDBOpenError) -> SaveDBOpenError {
        do {
            try withPebbleLockRank(.saveDB) { try coordinator.close() }
            return primary
        } catch {
            return SaveDBOpenError(stage: primary.stage, result: .cleanupFailed)
        }
    }
#if DEBUG
    static func _testCleanupMappedError(coordinator: PebbleStorageCoordinator,
                                        primary: SaveDBOpenError) -> SaveDBOpenError {
        cleanupMappedError(coordinator: coordinator, primary: primary)
    }
#endif

    fileprivate static func releaseProcessLease(_ identity: LegacyFileIdentity) {
        processLeaseLock.lock()
        processLeases.remove(identity)
        processLeaseLock.unlock()
    }

    static func preflight(databaseURL: URL) throws -> LegacyMigrationPreflight {
        guard databaseURL.isFileURL else {
            throw SaveDBOpenError(stage: .migrationParent, result: .invalidSource)
        }
        let databaseName = databaseURL.lastPathComponent
        guard validComponent(databaseName) else {
            throw SaveDBOpenError(stage: .migrationParent, result: .invalidSource)
        }
        let parentPath = databaseURL.deletingLastPathComponent().path
        var canonical = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(parentPath, &canonical) != nil else {
            throw SaveDBOpenError(stage: .migrationParent, result: .unavailable)
        }
        let parentFD = Darwin.open(String(cString: canonical),
                                   O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard parentFD >= 0 else {
            throw SaveDBOpenError(stage: .migrationParent, result: .unavailable)
        }
        var ownsParent = true
        defer { if ownsParent { Darwin.close(parentFD) } }
        let parentStat = try checkedStat(fd: parentFD, kind: S_IFDIR,
                                         stage: .migrationParent)
        let parentIdentity = parentStat.fileIdentity

        processLeaseLock.lock()
        let inserted = processLeases.insert(parentIdentity).inserted
        processLeaseLock.unlock()
        guard inserted else {
            throw SaveDBOpenError(stage: .migrationLease, result: .conflict)
        }
        var ownsRegistry = true
        defer { if ownsRegistry { releaseProcessLease(parentIdentity) } }

        let lockFD = Darwin.openat(parentFD, lockName,
                                   O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
                                   S_IRUSR | S_IWUSR)
        guard lockFD >= 0 else {
            throw SaveDBOpenError(stage: .migrationLease, result: .unavailable)
        }
        var ownsLock = true
        defer { if ownsLock { Darwin.close(lockFD) } }
        let lockStat = try checkedOwnedRegular(fd: lockFD, stage: .migrationLease,
                                               requireMode0600: true)
        try verifyNamedIdentity(parentFD: parentFD, name: lockName,
                                expected: lockStat.fileIdentity, kind: S_IFREG,
                                stage: .migrationLease)
        var fileLock = flock(l_start: 0, l_len: 0, l_pid: 0,
                             l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(lockFD, F_SETLK, &fileLock) == 0 else {
            throw SaveDBOpenError(stage: .migrationLease,
                                  result: errno == EACCES || errno == EAGAIN ? .conflict : .unavailable)
        }

        let sourceClassification = try classify(parentFD: parentFD, name: sourceName)
        let backupClassification = try classify(parentFD: parentFD, name: backupName)
        if sourceClassification != nil && backupClassification != nil {
            throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
        }

        let sourceFD: Int32
        let backupFD: Int32
        let state: LegacyNamespaceState
        let namespaceIdentity: LegacyFileIdentity?
        if let sourceClassification {
            guard sourceClassification.kind == S_IFDIR else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
            sourceFD = try openOwnedLockedDirectory(parentFD: parentFD, name: sourceName,
                                                     expected: sourceClassification.identity)
            backupFD = -1
            state = .source
            namespaceIdentity = sourceClassification.identity
        } else if let backupClassification {
            guard backupClassification.kind == S_IFDIR else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
            sourceFD = -1
            backupFD = try openOwnedLockedDirectory(parentFD: parentFD, name: backupName,
                                                     expected: backupClassification.identity)
            state = .backup
            namespaceIdentity = backupClassification.identity
        } else {
            sourceFD = -1
            backupFD = -1
            state = .empty
            namespaceIdentity = nil
        }
        var ownsNamespaceDescriptors = true
        defer {
            if ownsNamespaceDescriptors {
                if sourceFD >= 0 { Darwin.close(sourceFD) }
                if backupFD >= 0 { Darwin.close(backupFD) }
            }
        }

        let namespaceStatIdentity: LegacyStatIdentity?
        if sourceFD >= 0 {
            namespaceStatIdentity = try checkedStat(fd: sourceFD, kind: S_IFDIR,
                                                     stage: .migrationLease)
        } else if backupFD >= 0 {
            namespaceStatIdentity = try checkedStat(fd: backupFD, kind: S_IFDIR,
                                                     stage: .migrationLease)
        } else {
            namespaceStatIdentity = nil
        }
        try verifyNamedStatIdentity(parentFD: parentFD, name: lockName,
                                    expected: lockStat, kind: S_IFREG,
                                    stage: .migrationLease)

        try validateHeldLease(parentFD: parentFD, parentIdentity: parentIdentity,
                              lockFD: lockFD, lockIdentity: lockStat,
                              namespaceFD: sourceFD >= 0 ? sourceFD : backupFD,
                              namespaceIdentity: namespaceStatIdentity,
                              namespaceName: namespaceName(for: state),
                              stage: .migrationLease)
        let markerExists = try classify(parentFD: parentFD, name: provenanceName) != nil
        let markerTempExists = try classify(parentFD: parentFD, name: provenanceTempName) != nil
        let recoveryExists = try classify(parentFD: parentFD, name: recoveryName) != nil
        let recoveryTempExists = try classify(parentFD: parentFD, name: recoveryTempName) != nil
        try validateHeldLease(parentFD: parentFD, parentIdentity: parentIdentity,
                              lockFD: lockFD, lockIdentity: lockStat,
                              namespaceFD: sourceFD >= 0 ? sourceFD : backupFD,
                              namespaceIdentity: namespaceStatIdentity,
                              namespaceName: namespaceName(for: state),
                              stage: .migrationLease)
        switch state {
        case .source:
            guard !markerExists, !markerTempExists,
                  !recoveryExists, !recoveryTempExists else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
            }
        case .empty:
            guard !markerExists, !markerTempExists,
                  !recoveryExists, !recoveryTempExists else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
        case .backup:
            if markerExists {
                guard !markerTempExists, !recoveryExists, !recoveryTempExists else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
                }
                break
            }
            if markerTempExists {
                guard !recoveryExists, !recoveryTempExists else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
                }
                _ = try readNamedFile(parentFD: parentFD, name: provenanceTempName,
                                      maximum: 128, exact: 128,
                                      stage: .migrationManifest)
                break
            }
            if !markerExists {
                try validateHeldLease(parentFD: parentFD, parentIdentity: parentIdentity,
                                      lockFD: lockFD, lockIdentity: lockStat,
                                      namespaceFD: backupFD,
                                      namespaceIdentity: namespaceStatIdentity,
                                      namespaceName: backupName,
                                      stage: .migrationManifest)
                let manifest = try buildManifest(rootFD: backupFD)
                try validateHeldLease(parentFD: parentFD, parentIdentity: parentIdentity,
                                      lockFD: lockFD, lockIdentity: lockStat,
                                      namespaceFD: backupFD,
                                      namespaceIdentity: namespaceStatIdentity,
                                      namespaceName: backupName,
                                      stage: .migrationManifest)
                let databaseIdentity = try optionalNamedRegularIdentity(
                    parentFD: parentFD, name: databaseName)
                let record = recoveryRecord(databaseIdentity: databaseIdentity,
                                            backupIdentity: namespaceIdentity!,
                                            manifestRoot: manifest.root)
                if recoveryTempExists {
                    guard !recoveryExists else {
                        throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
                    }
                    try removeValidatedTemporaryMarker(
                        parentFD: parentFD, name: recoveryTempName,
                        expectedBytes: record, exact: 80,
                        stage: .migrationDirectorySync)
                    try validateHeldLease(parentFD: parentFD, parentIdentity: parentIdentity,
                                          lockFD: lockFD, lockIdentity: lockStat,
                                          namespaceFD: backupFD,
                                          namespaceIdentity: namespaceStatIdentity,
                                          namespaceName: backupName,
                                          stage: .migrationDirectorySync)
                }
                if recoveryExists {
                    try validateHeldLease(parentFD: parentFD, parentIdentity: parentIdentity,
                                          lockFD: lockFD, lockIdentity: lockStat,
                                          namespaceFD: backupFD,
                                          namespaceIdentity: namespaceStatIdentity,
                                          namespaceName: backupName,
                                          stage: .migrationManifest)
                    let existing = try readNamedFile(parentFD: parentFD, name: recoveryName,
                                                     maximum: 80, exact: 80,
                                                     stage: .migrationManifest)
                    guard existing == record else {
                        throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
                    }
                    try validateHeldLease(parentFD: parentFD, parentIdentity: parentIdentity,
                                          lockFD: lockFD, lockIdentity: lockStat,
                                          namespaceFD: backupFD,
                                          namespaceIdentity: namespaceStatIdentity,
                                          namespaceName: backupName,
                                          stage: .migrationManifest)
                } else {
                    try createDurableMarker(parentFD: parentFD, tempName: recoveryTempName,
                                            finalName: recoveryName, bytes: record,
                                            stage: .migrationDirectorySync)
                    try validateHeldLease(parentFD: parentFD, parentIdentity: parentIdentity,
                                          lockFD: lockFD, lockIdentity: lockStat,
                                          namespaceFD: backupFD,
                                          namespaceIdentity: namespaceStatIdentity,
                                          namespaceName: backupName,
                                          stage: .migrationDirectorySync)
                }
                throw SaveDBOpenError(stage: .legacyBackupRecoveryRequired, result: .conflict)
            }
        }

        let result = LegacyMigrationPreflight(
            parentFD: parentFD, parentIdentity: parentIdentity,
            databaseName: databaseName, lockFD: lockFD, state: state,
            sourceFD: sourceFD, backupFD: backupFD,
            namespaceIdentity: namespaceIdentity, lockIdentity: lockStat,
            namespaceStatIdentity: namespaceStatIdentity)
        ownsParent = false
        ownsLock = false
        ownsRegistry = false
        ownsNamespaceDescriptors = false
        return result
    }

    static func run(databaseURL: URL, coordinator: PebbleStorageCoordinator,
                    storage: PebbleLegacyCoreStorage,
                    preflight: LegacyMigrationPreflight) throws
        -> LegacyMigrationStorageSession {
        try validateLease(preflight, namespaceName: namespaceName(for: preflight.state),
                          stage: .migrationLease)
        let databaseIdentity = try verifyDatabaseBinding(
            coordinator: coordinator, preflight: preflight)
        switch preflight.state {
            case .empty:
                return LegacyMigrationStorageSession(coordinator: coordinator, storage: storage)
            case .backup:
                try validateLease(preflight, namespaceName: backupName, stage: .migrationManifest)
                let manifest = try buildManifest(rootFD: preflight.backupFD)
                try validateLease(preflight, namespaceName: backupName, stage: .migrationManifest)
                let evidence = try migrationEvidence(manifest: manifest,
                                                     rootFD: preflight.backupFD,
                                                     storage: storage,
                                                     preflight: preflight,
                                                     namespaceName: backupName)
                try validateLease(preflight, namespaceName: backupName, stage: .migrationManifest)
                let finalExists = try classify(parentFD: preflight.parentFD,
                                               name: provenanceName) != nil
                let tempExists = try classify(parentFD: preflight.parentFD,
                                              name: provenanceTempName) != nil
                guard finalExists != tempExists else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
                }
                let markerName = finalExists ? provenanceName : provenanceTempName
                let marker = try readNamedFile(parentFD: preflight.parentFD,
                                               name: markerName, maximum: 128,
                                               exact: 128, stage: .migrationManifest)
                guard validateProvenance(marker, databaseIdentity: databaseIdentity,
                                         backupIdentity: preflight.namespaceIdentity!,
                                         worldCount: evidence.worldCount,
                                         chunkCount: evidence.chunkCount,
                                         manifestRoot: manifest.root,
                                         equivalenceRoot: evidence.equivalenceRoot) else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
                }
                if tempExists {
                    try removeValidatedTemporaryMarker(
                        parentFD: preflight.parentFD, name: provenanceTempName,
                        expectedBytes: marker, exact: 128,
                        stage: .migrationDirectorySync)
                    try validateLease(preflight, namespaceName: backupName,
                                      stage: .migrationDirectorySync)
                    try createDurableMarker(parentFD: preflight.parentFD,
                                            tempName: provenanceTempName,
                                            finalName: provenanceName, bytes: marker,
                                            stage: .migrationDirectorySync)
                }
                try validateLease(preflight, namespaceName: backupName, stage: .migrationManifest)
                return LegacyMigrationStorageSession(coordinator: coordinator, storage: storage)
            case .source:
                return try importSource(databaseURL: databaseURL, coordinator: coordinator,
                                        storage: storage, preflight: preflight,
                                        databaseIdentity: databaseIdentity)
        }
    }

    private static func importSource(databaseURL: URL,
                                     coordinator: PebbleStorageCoordinator,
                                     storage: PebbleLegacyCoreStorage,
                                     preflight: LegacyMigrationPreflight,
                                     databaseIdentity: LegacyFileIdentity) throws
        -> LegacyMigrationStorageSession {
        guard fsync(preflight.parentFD) == 0 else {
            throw SaveDBOpenError(stage: .migrationDirectorySync, result: .unsupported)
        }
        try validateLease(preflight, namespaceName: sourceName, stage: .migrationManifest)
        let initialManifest = try buildManifest(rootFD: preflight.sourceFD)
        try validateLease(preflight, namespaceName: sourceName, stage: .migrationManifest)
        try requireDirectoryIfPresent(initialManifest, components: ["worlds"])
        try requireDirectoryIfPresent(initialManifest, components: ["player"])
        try requireDirectoryIfPresent(initialManifest, components: ["advancements"])
        try requireDirectoryIfPresent(initialManifest, components: ["chunks"])
        let worldChildren = initialManifest.children(of: ["worlds"])
        for entry in worldChildren where entry.components.last?.hasSuffix(".json") == true {
            guard entry.kind == .file else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
        }
        let worldEntries = worldChildren.filter {
            $0.kind == .file && $0.components.last?.hasSuffix(".json") == true
        }
        guard worldEntries.count <= maximumWorlds else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
        }

        let validWorldNames: [String] = try {
            var boundIDs = Set<Data>()
            var canonicalIDs = Set<String>()
            var names: [String] = []
            var persistentReservations: [LegacyResidentReservation] = []
            let validationLedger = try LegacyResidentLedger(initial: initialManifest.residentCharge)
            for entry in worldEntries {
                guard let filename = entry.components.last else { continue }
                let stem = String(filename.dropLast(5))
                guard validComponent(stem) else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
                }
                let materialized = try materialize(entry: entry, rootFD: preflight.sourceFD,
                                                   maximum: maximumWorldBytes,
                                                   ledger: validationLedger)
                let bytes = materialized.data
                guard let graphCharge = legacyMigrationJSONBudget(bytes) else { continue }
                let graphReservation = try validationLedger.reserve(graphCharge)
                let bridgeReservation = try validationLedger.reserve(
                    try discoveryFoundationBridgeCharge(inputBytes: UInt64(bytes.count)))
                guard let record = try? JSONDecoder().decode(WorldRecord.self, from: bytes) else {
                    continue
                }
                let stemBytes = Data(stem.utf8)
                let canonicalID = stem.precomposedStringWithCanonicalMapping
                let persistentReservation = try validationLedger.reserve(
                    try discoveryPersistentCharge(
                        stemBytes: UInt64(stemBytes.count),
                        canonicalBytes: UInt64(canonicalID.utf8.count),
                        filenameBytes: UInt64(filename.utf8.count)))
                guard Data(record.id.utf8) == stemBytes,
                      boundIDs.insert(stemBytes).inserted,
                      canonicalIDs.insert(canonicalID).inserted else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
                }
                names.append(filename)
                persistentReservations.append(persistentReservation)
                withExtendedLifetime((graphReservation, bridgeReservation,
                                      materialized.reservation)) {}
            }
            names.sort(by: unsignedUTF8Less)
            withExtendedLifetime(persistentReservations) {}
            return names
        }()
        if validWorldNames.isEmpty {
            return LegacyMigrationStorageSession(coordinator: coordinator, storage: storage)
        }

        var importedWorldCount: UInt64 = 0
        var importedChunkCount: UInt64 = 0
        for filename in validWorldNames {
#if DEBUG
            if consumeTestCut(.beforeImport) {
                throw SaveDBOpenError(stage: .migrationImport, result: .unavailable)
            }
#endif
            try validateLease(preflight, namespaceName: sourceName, stage: .migrationManifest)
            let prepared = try prepareWorld(filename: filename, manifest: initialManifest,
                                            rootFD: preflight.sourceFD)
            guard let value = prepared.primitiveImport else {
                throw SaveDBOpenError(stage: .migrationDecode, result: .invalidSource)
            }
            do {
                _ = try withPebbleLockRank(.saveDB) { try storage.importLegacyWorld(value) }
            } catch {
                throw mapStorage(error, stage: .migrationImport)
            }
            importedWorldCount += 1
            importedChunkCount += UInt64(prepared.chunks.count)
            try validateLease(preflight, namespaceName: sourceName, stage: .migrationImport)
        }

        try validateLease(preflight, namespaceName: sourceName, stage: .migrationManifest)
        let finalManifest = try buildManifest(rootFD: preflight.sourceFD)
        guard finalManifest == initialManifest else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
        }
        _ = try verifyDatabaseBinding(coordinator: coordinator, preflight: preflight)
        try verifyNamedIdentity(parentFD: preflight.parentFD, name: sourceName,
                                expected: preflight.namespaceIdentity!, kind: S_IFDIR,
                                stage: .migrationRename)
#if DEBUG
        if consumeTestCut(.beforeBarrier) {
            throw SaveDBOpenError(stage: .migrationBarrier, result: .durabilityFailure)
        }
#endif
        do {
            try validateLease(preflight, namespaceName: sourceName, stage: .migrationBarrier)
            try withPebbleLockRank(.saveDB) { try storage.prepareLegacyMigrationRename() }
            try validateLease(preflight, namespaceName: sourceName, stage: .migrationBarrier)
        } catch {
            throw mapStorage(error, stage: .migrationBarrier)
        }

#if DEBUG
        if consumeTestCut(.beforeRename) {
            throw SaveDBOpenError(stage: .migrationRename, result: .unavailable)
        }
#endif

        let renameResult = renameatx_np(preflight.parentFD, sourceName,
                                        preflight.parentFD, backupName,
                                        UInt32(RENAME_EXCL))
        let renameError = errno
        let sourceAfter = try classify(parentFD: preflight.parentFD, name: sourceName)
        let backupAfter = try classify(parentFD: preflight.parentFD, name: backupName)
        let renameObservation = LegacyRenameBoundaryObservation(
            returnedSuccess: renameResult == 0,
            source: sourceAfter?.identity, destination: backupAfter?.identity,
            syncSucceeded: true)
        let moved = renameBoundaryAccepted(.forwardSource,
                                           observation: renameObservation,
                                           expected: preflight.namespaceIdentity!)
        guard moved else {
            if sourceAfter?.identity == preflight.namespaceIdentity, backupAfter == nil {
                if renameResult != 0 {
                    let result: SaveDBOpenError.Result
                    switch renameError {
                    case EEXIST: result = .conflict
                    case ENOTSUP, EOPNOTSUPP, ENOSYS, EINVAL: result = .unsupported
                    default: result = .unavailable
                    }
                    throw SaveDBOpenError(stage: .migrationRename, result: result)
                }
            }
            throw SaveDBOpenError(stage: .migrationRename, result: .invalidSource)
        }
        try refreshNamespaceAfterRename(preflight, named: backupName, stage: .migrationRename)
        try validateLease(preflight, namespaceName: backupName, stage: .migrationRename)
#if DEBUG
        if consumeTestCut(.afterRenameBeforeSync) {
            throw SaveDBOpenError(stage: .migrationDirectorySync, result: .durabilityFailure)
        }
#endif
        let directorySyncResult = syncDirectory(preflight.parentFD)
#if DEBUG
        let renameSynced = directorySyncResult && !consumeTestCut(.failParentSync)
#else
        let renameSynced = directorySyncResult
#endif
        let sourceAfterSync = try classify(parentFD: preflight.parentFD, name: sourceName)
        let backupAfterSync = try classify(parentFD: preflight.parentFD, name: backupName)
        let durableObservation = LegacyRenameBoundaryObservation(
            returnedSuccess: renameResult == 0,
            source: sourceAfterSync?.identity, destination: backupAfterSync?.identity,
            syncSucceeded: renameSynced)
        guard renameBoundaryAccepted(.forwardSource,
                                     observation: durableObservation,
                                     expected: preflight.namespaceIdentity!) else {
            try rollbackRename(preflight: preflight)
            throw SaveDBOpenError(stage: .migrationDirectorySync, result: .durabilityFailure)
        }
        try validateLease(preflight, namespaceName: backupName, stage: .migrationDirectorySync)
#if DEBUG
        if consumeTestCut(.afterParentSync) {
            throw SaveDBOpenError(stage: .migrationDirectorySync, result: .durabilityFailure)
        }
#endif

        do {
            try withPebbleLockRank(.saveDB) { try coordinator.close() }
        } catch {
            throw mapStorage(error, stage: .cleanup)
        }

        let reopenedStorage: PebbleLegacyCoreStorage
        var reopenedCoordinator: PebbleStorageCoordinator?
        do {
#if DEBUG
            if consumeTestCut(.beforeReopen) {
                throw SaveDBOpenError(stage: .schemaVerification, result: .unavailable)
            }
#endif
            try validateLease(preflight, namespaceName: backupName, stage: .schemaVerification)
            reopenedCoordinator = try withPebbleLockRank(.saveDB) {
                try PebbleStorageCoordinator.open(databaseURL: databaseURL)
            }
            reopenedStorage = try withPebbleLockRank(.saveDB) {
                let value = try reopenedCoordinator!.legacyCore()
                try value.verifyCoreSchema()
                return value
            }
        } catch {
            let mapped = mapStorage(error, stage: .schemaVerification)
            if let reopenedCoordinator {
                throw cleanupMappedError(coordinator: reopenedCoordinator, primary: mapped)
            }
            throw mapped
        }
        let ownedReopenedCoordinator = reopenedCoordinator!
        do {
            let reopenedIdentity = try verifyDatabaseBinding(
                coordinator: ownedReopenedCoordinator, preflight: preflight)
            guard reopenedIdentity == databaseIdentity else {
                throw SaveDBOpenError(stage: .migrationParent, result: .conflict)
            }
            try validateLease(preflight, namespaceName: backupName, stage: .migrationManifest)
            let backupManifest = try buildManifest(rootFD: preflight.sourceFD)
            guard backupManifest == initialManifest else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
            }
            try validateLease(preflight, namespaceName: backupName, stage: .migrationImport)
            let equivalenceRoot = try proveEquivalence(
                manifest: backupManifest, rootFD: preflight.sourceFD,
                storage: reopenedStorage, worldNames: validWorldNames,
                preflight: preflight, namespaceName: backupName)
            let provenance = provenanceRecord(
                databaseIdentity: reopenedIdentity,
                backupIdentity: preflight.namespaceIdentity!,
                worldCount: importedWorldCount, chunkCount: importedChunkCount,
                manifestRoot: backupManifest.root, equivalenceRoot: equivalenceRoot)
#if DEBUG
            if consumeTestCut(.afterReopenBeforeMarker) {
                throw SaveDBOpenError(stage: .migrationDirectorySync, result: .durabilityFailure)
            }
#endif
            try createDurableMarker(parentFD: preflight.parentFD,
                                    tempName: provenanceTempName,
                                    finalName: provenanceName, bytes: provenance,
                                    stage: .migrationDirectorySync)
            try validateLease(preflight, namespaceName: backupName, stage: .migrationDirectorySync)
            print("[saves] migrated \(importedWorldCount) worlds, \(importedChunkCount) chunks into pebble.db (old files kept in saves-legacy-backup)")
            fflush(stdout)
            return LegacyMigrationStorageSession(coordinator: ownedReopenedCoordinator,
                                                 storage: reopenedStorage)
        } catch {
            let mapped = (error as? SaveDBOpenError) ?? mapStorage(error, stage: .migrationImport)
            throw cleanupMappedError(coordinator: ownedReopenedCoordinator, primary: mapped)
        }
    }

    private static func prepareWorld(filename: String, manifest: LegacyManifest,
                                     rootFD: Int32) throws -> PreparedLegacyWorld {
        let ledger = try LegacyResidentLedger(initial: manifest.residentCharge)
        var reservations: [LegacyResidentReservation] = []
        guard let worldEntry = manifest.entry(["worlds", filename]) else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
        }
        let materializedWorld = try materialize(entry: worldEntry, rootFD: rootFD,
                                                maximum: maximumWorldBytes, ledger: ledger)
        let worldBytes = materializedWorld.data
        reservations.append(materializedWorld.reservation)
        guard let graphCharge = legacyMigrationJSONBudget(worldBytes),
              residentFits(base: manifest.residentCharge,
                           additions: [UInt64(worldBytes.count) * 2 + 1_048_576,
                                       graphCharge, 3_145_728]) else {
            throw SaveDBOpenError(stage: .migrationDecode, result: .limitExceeded)
        }
        reservations.append(try ledger.reserve(graphCharge))
        reservations.append(try ledger.reserve(try sumResidentCharges([
            roundedBufferCharge(maximumWorldBytes), roundedBufferCharge(maximumWorldBytes),
            3_145_728,
        ])))
        let record: WorldRecord
        do { record = try JSONDecoder().decode(WorldRecord.self, from: worldBytes) }
        catch { throw SaveDBOpenError(stage: .migrationDecode, result: .invalidSource) }
        guard let encodedWorld = encodeWorldRecordJSON(record),
              let worldJSON = String(data: encodedWorld, encoding: .utf8) else {
            throw SaveDBOpenError(stage: .migrationDecode, result: .invalidSource)
        }
        let worldRow: PebbleWorldStorageRow
        do {
            worldRow = try PebbleWorldStorageRow(id: record.id, json: worldJSON,
                                                 lastPlayed: record.lastPlayed)
        } catch { throw mapStorage(error, stage: .migrationDecode) }

        let player = try optionalJSONRow(
            manifest: manifest, rootFD: rootFD,
            components: ["player", "\(record.id).json"],
            maximum: maximumPlayerBytes, shape: .object,
            ledger: ledger, reservations: &reservations) { json in
                try PebblePlayerJSONStorageRow(world: record.id, json: json)
            }
        let advancements = try optionalJSONRow(
            manifest: manifest, rootFD: rootFD,
            components: ["advancements", "\(record.id).json"],
            maximum: maximumAdvancementBytes, shape: .stringArray,
            ledger: ledger, reservations: &reservations) { json in
                try PebbleAdvancementStorageRow(world: record.id, json: json)
            }

        let chunkParent = ["chunks", record.id]
        try requireDirectoryIfPresent(manifest, components: chunkParent)
        let chunkChildren = manifest.children(of: chunkParent)
        for entry in chunkChildren where entry.components.last?.hasSuffix(".vck") == true {
            guard entry.kind == .file else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
        }
        let candidates = chunkChildren.filter { entry in
            entry.kind == .file && entry.components.last?.hasSuffix(".vck") == true
        }
        guard candidates.count <= maximumChunks else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
        }
        var keys = Set<PebbleChunkStorageKey>()
        var chunks: [PebbleChunkStorageRow] = []
        var worldChunkBytes: UInt64 = 0
        for candidate in candidates.sorted(by: { unsignedUTF8Less($0.components.last!, $1.components.last!) }) {
            guard let name = candidate.components.last,
                  let tuple = parseChunkName(name) else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
            let materializedChunk = try materialize(entry: candidate, rootFD: rootFD,
                                                    maximum: maximumChunkBytes, ledger: ledger)
            let bytes = materializedChunk.data
            guard validateLegacyVCKStructure(bytes, dimension: Int(tuple.dimension)) else {
                continue
            }
            let rowCopyCharge = try sumResidentCharges([
                roundedBufferCharge(UInt64(bytes.count)), 256,
            ])
            reservations.append(try ledger.reserve(rowCopyCharge))
            reservations.append(materializedChunk.reservation)
            let (next, overflow) = worldChunkBytes.addingReportingOverflow(UInt64(bytes.count))
            guard !overflow, next <= maximumWorldChunkBytes else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
            }
            worldChunkBytes = next
            let key: PebbleChunkStorageKey
            let row: PebbleChunkStorageRow
            do {
                key = try PebbleChunkStorageKey(world: record.id,
                                                dimension: tuple.dimension,
                                                chunkX: tuple.chunkX, chunkZ: tuple.chunkZ)
                guard keys.insert(key).inserted else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
                }
                row = try PebbleChunkStorageRow(key: key, data: bytes)
            } catch let error as SaveDBOpenError { throw error }
            catch { throw mapStorage(error, stage: .migrationDecode) }
            chunks.append(row)
        }
        return PreparedLegacyWorld(record: record, world: worldRow, player: player,
                                   advancements: advancements, chunks: chunks,
                                   residentReservations: reservations)
    }

    private enum LegacyJSONShape { case object, stringArray }

    private static func optionalJSONRow<Row>(manifest: LegacyManifest, rootFD: Int32,
                                              components: [String], maximum: UInt64,
                                              shape: LegacyJSONShape,
                                              ledger: LegacyResidentLedger,
                                              reservations: inout [LegacyResidentReservation],
                                              make: (String) throws -> Row) throws -> Row? {
        guard let entry = manifest.entry(components) else { return nil }
        guard entry.kind == .file else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
        }
        let materialized = try materialize(entry: entry, rootFD: rootFD,
                                           maximum: maximum, ledger: ledger)
        let bytes = materialized.data
        reservations.append(materialized.reservation)
        guard let graphCharge = legacyMigrationJSONBudget(bytes),
              residentFits(base: manifest.residentCharge,
                           additions: [UInt64(bytes.count) * 2 + 1_048_576, graphCharge]) else {
            return nil
        }
        reservations.append(try ledger.reserve(try sumResidentCharges([
            graphCharge, roundedBufferCharge(maximum), roundedBufferCharge(maximum), 1_048_576,
        ])))
        guard let object = try? JSONSerialization.jsonObject(with: bytes),
              validJSONDomainShape(object, shape: shape),
              JSONSerialization.isValidJSONObject(object),
              let normalized = try? JSONSerialization.data(
                withJSONObject: sanitizeJSON(object), options: [.sortedKeys]),
              let json = String(data: normalized, encoding: .utf8) else { return nil }
        do { return try make(json) }
        catch { throw mapStorage(error, stage: .migrationDecode) }
    }

    private static func validJSONDomainShape(_ object: Any, shape: LegacyJSONShape) -> Bool {
        switch shape {
        case .object: return object is [String: Any]
        case .stringArray: return object is [String]
        }
    }

    private static func requireDirectoryIfPresent(_ manifest: LegacyManifest,
                                                  components: [String]) throws {
        guard let entry = manifest.entry(components) else { return }
        guard entry.kind == .directory else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
        }
    }

    private static func proveEquivalence(manifest: LegacyManifest, rootFD: Int32,
                                         storage: PebbleLegacyCoreStorage,
                                         worldNames: [String],
                                         preflight: LegacyMigrationPreflight?,
                                         namespaceName: String?) throws -> Data {
        var hasher = SHA256()
        for filename in worldNames {
            if let preflight {
                try validateLease(preflight, namespaceName: namespaceName,
                                  stage: .migrationImport)
            }
            let prepared = try prepareWorld(filename: filename, manifest: manifest, rootFD: rootFD)
            let world: PebbleWorldStorageRow?
            let player: PebblePlayerJSONStorageRow?
            let advancements: PebbleAdvancementStorageRow?
            let keys: [PebbleChunkStorageKey]
            do {
                if let preflight {
                    try validateLease(preflight, namespaceName: namespaceName,
                                      stage: .migrationImport)
                }
                (world, player, advancements, keys) = try withPebbleLockRank(.saveDB) {
                    (try storage.getWorldRow(id: prepared.record.id),
                     try storage.getPlayerJSON(world: prepared.record.id),
                     try storage.getAdvancementJSON(world: prepared.record.id),
                     try storage.listChunkKeys(world: prepared.record.id))
                }
                if let preflight {
                    try validateLease(preflight, namespaceName: namespaceName,
                                      stage: .migrationImport)
                }
            } catch { throw mapStorage(error, stage: .migrationImport) }
            guard world == prepared.world, player == prepared.player,
                  advancements == prepared.advancements,
                  Set(keys) == Set(prepared.chunks.map(\.key)) else {
                throw SaveDBOpenError(stage: .migrationImport, result: .conflict)
            }
            appendHashField(Data("world".utf8), to: &hasher)
            appendHashField(Data(prepared.world.id.utf8), to: &hasher)
            appendHashField(Data(prepared.world.json.utf8), to: &hasher)
            appendHashUInt64(prepared.world.lastPlayed.bitPattern, to: &hasher)
            appendOptionalJSON(tag: "player", prepared.player?.json, to: &hasher)
            appendOptionalJSON(tag: "advancements", prepared.advancements?.json, to: &hasher)
            for chunk in prepared.chunks.sorted(by: { chunkKeyLess($0.key, $1.key) }) {
                if let preflight {
                    try validateLease(preflight, namespaceName: namespaceName,
                                      stage: .migrationImport)
                }
                let stored: Data?
                do {
                    stored = try withPebbleLockRank(.saveDB) {
                        try storage.getChunkBlob(key: chunk.key)
                    }
                } catch { throw mapStorage(error, stage: .migrationImport) }
                guard stored == chunk.data else {
                    throw SaveDBOpenError(stage: .migrationImport, result: .conflict)
                }
                if let preflight {
                    try validateLease(preflight, namespaceName: namespaceName,
                                      stage: .migrationImport)
                }
                appendHashField(Data("chunk".utf8), to: &hasher)
                appendHashField(Data(chunk.key.world.utf8), to: &hasher)
                appendHashUInt64(UInt64(bitPattern: Int64(chunk.key.dimension)), to: &hasher)
                appendHashUInt64(UInt64(bitPattern: Int64(chunk.key.chunkX)), to: &hasher)
                appendHashUInt64(UInt64(bitPattern: Int64(chunk.key.chunkZ)), to: &hasher)
                appendHashField(chunk.data, to: &hasher)
            }
            if let preflight {
                try validateLease(preflight, namespaceName: namespaceName,
                                  stage: .migrationImport)
            }
        }
        return Data(hasher.finalize())
    }

    private static func appendOptionalJSON(tag: String, _ json: String?,
                                           to hasher: inout SHA256) {
        appendHashField(Data(tag.utf8), to: &hasher)
        if let json {
            appendHashUInt64(1, to: &hasher)
            appendHashField(Data(json.utf8), to: &hasher)
        } else {
            appendHashUInt64(0, to: &hasher)
        }
    }

    private static func migrationEvidence(manifest: LegacyManifest, rootFD: Int32,
                                          storage: PebbleLegacyCoreStorage,
                                          preflight: LegacyMigrationPreflight,
                                          namespaceName: String) throws
        -> (worldCount: UInt64, chunkCount: UInt64, equivalenceRoot: Data) {
        try requireDirectoryIfPresent(manifest, components: ["worlds"])
        let children = manifest.children(of: ["worlds"])
        for entry in children where entry.components.last?.hasSuffix(".json") == true {
            guard entry.kind == .file else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
        }
        let names = children.compactMap { entry -> String? in
            guard entry.kind == .file,
                  let name = entry.components.last, name.hasSuffix(".json") else { return nil }
            return name
        }.sorted(by: unsignedUTF8Less)
        guard names.count <= maximumWorlds else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
        }
        var chunks: UInt64 = 0
        var rawIDs = Set<Data>()
        var canonicalIDs = Set<String>()
        for name in names {
            try validateLease(preflight, namespaceName: namespaceName, stage: .migrationManifest)
            let prepared = try prepareWorld(filename: name, manifest: manifest, rootFD: rootFD)
            try validateLease(preflight, namespaceName: namespaceName, stage: .migrationManifest)
            let stem = String(name.dropLast(5))
            guard Data(prepared.record.id.utf8) == Data(stem.utf8),
                  rawIDs.insert(Data(stem.utf8)).inserted,
                  canonicalIDs.insert(stem.precomposedStringWithCanonicalMapping).inserted else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
            let (next, overflow) = chunks.addingReportingOverflow(UInt64(prepared.chunks.count))
            guard !overflow else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
            }
            chunks = next
        }
        return (UInt64(names.count), chunks,
                try proveEquivalence(manifest: manifest, rootFD: rootFD,
                                     storage: storage, worldNames: names,
                                     preflight: preflight, namespaceName: namespaceName))
    }

    private static func buildManifest(rootFD: Int32) throws -> LegacyManifest {
        var entries: [LegacyManifestEntry] = []
        var entryCount = 0
        var filenameBytes: UInt64 = 0
        var sourceBytes: UInt64 = 0
        var residentCharge: UInt64 = 0
        try collectManifest(rootFD: rootFD, directoryFD: rootFD, components: [], depth: 0,
                            entries: &entries, entryCount: &entryCount,
                            filenameBytes: &filenameBytes, sourceBytes: &sourceBytes,
                            residentCharge: &residentCharge)
        entries.sort { $0.rawPath.lexicographicallyPrecedes($1.rawPath) }
        var hasher = SHA256()
        for entry in entries {
            hasher.update(data: Data([entry.kind.rawValue]))
            appendHashField(entry.rawPath, to: &hasher)
            appendStat(entry.identity, to: &hasher)
            appendHashField(entry.digest, to: &hasher)
        }
        let manifest = LegacyManifest(entries: entries, root: Data(hasher.finalize()),
                                      sourceBytes: sourceBytes, residentCharge: residentCharge)
        try validateGlobalChunkCandidates(manifest)
        return manifest
    }

    private static func validateGlobalChunkCandidates(_ manifest: LegacyManifest) throws {
        var count = 0
        for entry in manifest.entries where entry.components.count == 3
            && entry.components.first == "chunks"
            && entry.components.last?.hasSuffix(".vck") == true {
            guard entry.kind == .file else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
            count += 1
            guard count <= maximumChunks else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
            }
        }
    }

    private static func collectManifest(rootFD: Int32, directoryFD: Int32,
                                        components: [String], depth: Int,
                                        entries: inout [LegacyManifestEntry],
                                        entryCount: inout Int,
                                        filenameBytes: inout UInt64,
                                        sourceBytes: inout UInt64,
                                        residentCharge: inout UInt64) throws {
        guard depth <= 16 else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
        }
        let names = try enumerate(directoryFD: directoryFD)
        for name in names {
            entryCount += 1
            guard entryCount <= maximumEntries else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
            }
            let nameByteCount = UInt64(name.utf8.count)
            let (nextNames, nameOverflow) = filenameBytes.addingReportingOverflow(nameByteCount)
            guard !nameOverflow, nextNames <= maximumFilenameBytes else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
            }
            filenameBytes = nextNames
            var info = stat()
            guard fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .unavailable)
            }
            let identity = try LegacyStatIdentity(info)
            guard identity.owner == geteuid() else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
            let childComponents = components + [name]
            let rawPath = Data(childComponents.joined(separator: "/").utf8)
            var componentCharge: UInt64 = 0
            for component in childComponents {
                let (stringBytes, multiplicationOverflow) = UInt64(component.utf8.count)
                    .multipliedReportingOverflow(by: 4)
                let (next, additionOverflow) = componentCharge.addingReportingOverflow(
                    64 + stringBytes)
                guard !multiplicationOverflow, !additionOverflow else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
                }
                componentCharge = next
            }
            let componentSlots = UInt64(childComponents.count).multipliedReportingOverflow(by: 192)
            guard !componentSlots.overflow else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
            }
            let baseCharge = 256 + nameByteCount + roundedBufferCharge(UInt64(rawPath.count))
                + componentCharge + componentSlots.partialValue
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                guard residentFits(base: residentCharge, additions: [baseCharge]) else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
                }
                residentCharge += baseCharge
                let childFD = Darwin.openat(directoryFD, name,
                                            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard childFD >= 0 else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
                }
                defer { Darwin.close(childFD) }
                let opened = try checkedStat(fd: childFD, kind: S_IFDIR,
                                             stage: .migrationManifest)
                guard opened.fileIdentity == identity.fileIdentity else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
                }
                entries.append(LegacyManifestEntry(components: childComponents,
                                                   rawPath: rawPath, kind: .directory,
                                                   identity: identity, digest: Data()))
                try collectManifest(rootFD: rootFD, directoryFD: childFD,
                                    components: childComponents, depth: depth + 1,
                                    entries: &entries, entryCount: &entryCount,
                                    filenameBytes: &filenameBytes, sourceBytes: &sourceBytes,
                                    residentCharge: &residentCharge)
            case S_IFREG:
                guard identity.links == 1 else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
                }
                let (nextSource, sourceOverflow) = sourceBytes.addingReportingOverflow(identity.size)
                guard !sourceOverflow, nextSource <= maximumSourceBytes else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
                }
                sourceBytes = nextSource
                guard residentFits(base: residentCharge,
                                   additions: [baseCharge, 32,
                                               roundedBufferCharge(65_536)]) else {
                    throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
                }
                residentCharge += baseCharge + 32
                let digest = try hashFile(directoryFD: directoryFD, name: name,
                                          expected: identity)
                entries.append(LegacyManifestEntry(components: childComponents,
                                                   rawPath: rawPath, kind: .file,
                                                   identity: identity, digest: digest))
            default:
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
        }
    }

    private static func enumerate(directoryFD: Int32) throws -> [String] {
        let freshFD = Darwin.openat(directoryFD, ".",
                                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard freshFD >= 0, let directory = fdopendir(freshFD) else {
            if freshFD >= 0 { Darwin.close(freshFD) }
            throw SaveDBOpenError(stage: .migrationManifest, result: .unavailable)
        }
        defer { closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
            if name == "." || name == ".." { continue }
            guard validComponent(name) else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
            names.append(name)
        }
        guard errno == 0 else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .unavailable)
        }
        names.sort(by: unsignedUTF8Less)
        return names
    }

    private static func hashFile(directoryFD: Int32, name: String,
                                 expected: LegacyStatIdentity) throws -> Data {
        let fd = Darwin.openat(directoryFD, name,
                               O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
        }
        defer { Darwin.close(fd) }
        let before = try checkedOwnedRegular(fd: fd, stage: .migrationManifest,
                                             requireMode0600: false)
        guard before == expected else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
        }
        var hasher = SHA256()
        var offset: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while offset < expected.size {
            let requested = min(UInt64(buffer.count), expected.size - offset)
            let count: Int = try buffer.withUnsafeMutableBytes { bytes in
                try checkedPread(fd: fd, buffer: bytes.baseAddress!,
                                 count: Int(requested), offset: offset)
            }
            guard count == requested else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
            }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(
                    start: raw.baseAddress, count: count))
            }
            offset += UInt64(count)
#if DEBUG
            if let mutation = consumeHashMutation() {
                switch mutation {
                case .truncate:
                    let writable = Darwin.openat(directoryFD, name,
                                                 O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                    if writable >= 0 {
                        _ = ftruncate(writable, 0)
                        Darwin.close(writable)
                    }
                case .grow:
                    let writable = Darwin.openat(directoryFD, name,
                                                 O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
                    if writable >= 0 {
                        var byte: UInt8 = 0x7f
                        _ = Darwin.write(writable, &byte, 1)
                        Darwin.close(writable)
                    }
                case .replace:
                    let displaced = ".pebble-test-displaced"
                    _ = unlinkat(directoryFD, displaced, 0)
                    if renameatx_np(directoryFD, name, directoryFD, displaced,
                                    UInt32(RENAME_EXCL)) == 0 {
                        let replacement = Darwin.openat(
                            directoryFD, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                            S_IRUSR | S_IWUSR)
                        if replacement >= 0 { Darwin.close(replacement) }
                    }
                }
            }
#endif
        }
        var probe: UInt8 = 0
        let extra = try checkedPread(fd: fd, buffer: &probe, count: 1, offset: offset)
        guard extra == 0 else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
        }
        let after = try checkedOwnedRegular(fd: fd, stage: .migrationManifest,
                                            requireMode0600: false)
        guard before == after else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
        }
        return Data(hasher.finalize())
    }

    private static func materialize(entry: LegacyManifestEntry, rootFD: Int32,
                                    maximum: UInt64,
                                    ledger: LegacyResidentLedger) throws -> LegacyMaterializedBytes {
        guard entry.kind == .file, entry.identity.size <= maximum,
              entry.identity.size <= UInt64(Int.max) else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
        }
        let reservation = try ledger.reserve(roundedBufferCharge(entry.identity.size))
        let (parentFD, name) = try openParent(rootFD: rootFD, components: entry.components)
        defer { if parentFD != rootFD { Darwin.close(parentFD) } }
        let fd = Darwin.openat(parentFD, name,
                               O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
        }
        defer { Darwin.close(fd) }
        let before = try checkedOwnedRegular(fd: fd, stage: .migrationManifest,
                                             requireMode0600: false)
        guard before == entry.identity else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
        }
        if entry.identity.size == 0 {
            var probe: UInt8 = 0
            let after = try checkedOwnedRegular(fd: fd, stage: .migrationManifest,
                                                requireMode0600: false)
            guard try checkedPread(fd: fd, buffer: &probe, count: 1, offset: 0) == 0,
                  before == after,
                  Data(SHA256.hash(data: Data())) == entry.digest else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
            }
            return LegacyMaterializedBytes(data: Data(), reservation: reservation)
        }
        let byteCount = Int(entry.identity.size)
        let allocation = UnsafeMutableRawBufferPointer.allocate(byteCount: byteCount, alignment: 16)
        var transferred = false
        defer { if !transferred { allocation.deallocate() } }
        var hasher = SHA256()
        var offset = 0
        while offset < byteCount {
            let requested = min(65_536, byteCount - offset)
            let count = try checkedPread(
                fd: fd, buffer: allocation.baseAddress!.advanced(by: offset),
                count: requested, offset: UInt64(offset))
            guard count == requested else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
            }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                start: allocation.baseAddress!.advanced(by: offset), count: count))
            offset += count
        }
        var probe: UInt8 = 0
        guard try checkedPread(fd: fd, buffer: &probe, count: 1,
                               offset: UInt64(offset)) == 0 else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
        }
        let after = try checkedOwnedRegular(fd: fd, stage: .migrationManifest,
                                            requireMode0600: false)
        guard before == after, Data(hasher.finalize()) == entry.digest else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .conflict)
        }
        transferred = true
        let data = Data(bytesNoCopy: allocation.baseAddress!, count: byteCount,
                        deallocator: .custom { pointer, _ in pointer.deallocate() })
        return LegacyMaterializedBytes(data: data, reservation: reservation)
    }

    private static func openParent(rootFD: Int32, components: [String]) throws -> (Int32, String) {
        guard let name = components.last, validComponent(name) else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
        }
        var current = rootFD
        for component in components.dropLast() {
            let next = Darwin.openat(current, component,
                                     O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if current != rootFD { Darwin.close(current) }
            guard next >= 0 else {
                throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
            }
            current = next
        }
        return (current, name)
    }

    private static func parseChunkName(_ name: String)
        -> (dimension: Int32, chunkX: Int32, chunkZ: Int32)? {
        guard name.hasSuffix(".vck") else { return nil }
        let stem = name.dropLast(4)
        let parts = stem.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let dimension = canonicalInt32(parts[0]),
              let chunkX = canonicalInt32(parts[1]),
              let chunkZ = canonicalInt32(parts[2]) else { return nil }
        return (dimension, chunkX, chunkZ)
    }

    private static func canonicalInt32(_ source: Substring) -> Int32? {
        guard !source.isEmpty else { return nil }
        let string = String(source)
        guard string == "0" || (!string.hasPrefix("+") && !string.hasPrefix("-0")
            && string.first != "0") else { return nil }
        guard string.allSatisfy({ $0 == "-" || $0.isASCII && $0.isNumber }),
              let value = Int32(string), String(value) == string else { return nil }
        return value
    }

    private static func verifyDatabaseBinding(coordinator: PebbleStorageCoordinator,
                                              preflight: LegacyMigrationPreflight) throws
        -> LegacyFileIdentity {
        let identity = try optionalNamedRegularIdentity(parentFD: preflight.parentFD,
                                                        name: preflight.databaseName)
        guard let identity else {
            throw SaveDBOpenError(stage: .migrationParent, result: .invalidSource)
        }
        do {
            try withPebbleLockRank(.saveDB) {
                try coordinator.verifyDatabaseParentIdentity(
                    device: preflight.parentIdentity.device,
                    inode: preflight.parentIdentity.inode)
            }
        } catch { throw mapStorage(error, stage: .migrationParent) }
        return identity
    }

    private static func provenanceRecord(databaseIdentity: LegacyFileIdentity,
                                         backupIdentity: LegacyFileIdentity,
                                         worldCount: UInt64, chunkCount: UInt64,
                                         manifestRoot: Data,
                                         equivalenceRoot: Data) -> Data {
        var data = Data([0x50, 0x42, 0x4c, 0x4d, 0x32, 0, 0, 0])
        appendLittleEndian(UInt32(1), to: &data)
        appendLittleEndian(UInt32(0), to: &data)
        for value in [databaseIdentity.device, databaseIdentity.inode,
                      backupIdentity.device, backupIdentity.inode,
                      worldCount, chunkCount] {
            appendLittleEndian(value, to: &data)
        }
        data.append(manifestRoot)
        data.append(equivalenceRoot)
        precondition(data.count == 128)
        return data
    }

    private static func recoveryRecord(databaseIdentity: LegacyFileIdentity?,
                                       backupIdentity: LegacyFileIdentity,
                                       manifestRoot: Data) -> Data {
        var data = Data([0x50, 0x42, 0x4c, 0x52, 0x32, 0, 0, 0])
        appendLittleEndian(UInt32(1), to: &data)
        appendLittleEndian(UInt32(0), to: &data)
        appendLittleEndian(databaseIdentity?.device ?? 0, to: &data)
        appendLittleEndian(databaseIdentity?.inode ?? 0, to: &data)
        appendLittleEndian(backupIdentity.device, to: &data)
        appendLittleEndian(backupIdentity.inode, to: &data)
        data.append(manifestRoot)
        precondition(data.count == 80)
        return data
    }

    private static func validateProvenance(_ data: Data,
                                           databaseIdentity: LegacyFileIdentity,
                                           backupIdentity: LegacyFileIdentity,
                                           worldCount: UInt64,
                                           chunkCount: UInt64,
                                           manifestRoot: Data,
                                           equivalenceRoot: Data) -> Bool {
        guard data.count == 128,
              data.prefix(8) == Data([0x50, 0x42, 0x4c, 0x4d, 0x32, 0, 0, 0]),
              readU32(data, 8) == 1, readU32(data, 12) == 0,
              readU64(data, 16) == databaseIdentity.device,
              readU64(data, 24) == databaseIdentity.inode,
              readU64(data, 32) == backupIdentity.device,
              readU64(data, 40) == backupIdentity.inode,
              readU64(data, 48) == worldCount,
              readU64(data, 56) == chunkCount,
              data[64..<96] == manifestRoot[...],
              data[96..<128] == equivalenceRoot[...] else { return false }
        return true
    }

    private static func createDurableMarker(parentFD: Int32, tempName: String,
                                            finalName: String, bytes: Data,
                                            stage: SaveDBOpenError.Stage) throws {
        guard try namedStatIdentity(parentFD: parentFD, name: tempName, stage: stage) == nil,
              try namedStatIdentity(parentFD: parentFD, name: finalName, stage: stage) == nil else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        let fd = Darwin.openat(parentFD, tempName,
                               O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                               S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw SaveDBOpenError(stage: stage,
                                  result: errno == EEXIST ? .conflict : .unavailable)
        }
        var closeFD = true
        defer { if closeFD { Darwin.close(fd) } }
        try bytes.withUnsafeBytes { raw in
            try checkedWrite(fd: fd, bytes: raw)
        }
        guard fcntl(fd, F_FULLFSYNC) == 0 else {
            throw SaveDBOpenError(stage: stage, result: .durabilityFailure)
        }
        let identity = try checkedOwnedRegular(fd: fd, stage: stage, requireMode0600: true)
        try verifyNamedIdentity(parentFD: parentFD, name: tempName,
                                expected: identity.fileIdentity, kind: S_IFREG, stage: stage)
        let tempBeforeRename = try namedStatIdentity(parentFD: parentFD, name: tempName, stage: stage)
        guard tempBeforeRename == identity,
              try namedStatIdentity(parentFD: parentFD, name: finalName, stage: stage) == nil else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        Darwin.close(fd)
        closeFD = false
        let renameResult = renameatx_np(parentFD, tempName, parentFD, finalName,
                                        UInt32(RENAME_EXCL))
        let renameError = errno
        let tempAfterRename = try namedStatIdentity(parentFD: parentFD, name: tempName, stage: stage)
        let finalAfterRename = try namedStatIdentity(parentFD: parentFD, name: finalName, stage: stage)
        let markerForwardObservation = LegacyRenameBoundaryObservation(
            returnedSuccess: renameResult == 0,
            source: tempAfterRename?.fileIdentity,
            destination: finalAfterRename?.fileIdentity,
            syncSucceeded: true)
        let moved = renameBoundaryAccepted(.forwardSource,
                                           observation: markerForwardObservation,
                                           expected: identity.fileIdentity)
        if !moved {
            guard tempAfterRename == tempBeforeRename, finalAfterRename == nil else {
                throw SaveDBOpenError(stage: stage, result: .conflict)
            }
            throw SaveDBOpenError(stage: stage,
                                  result: renameError == EEXIST ? .conflict : .unavailable)
        }
        guard renameResult == 0 || moved, let capturedFinal = finalAfterRename else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        guard syncDirectory(parentFD) else {
            guard try namedStatIdentity(parentFD: parentFD, name: finalName, stage: stage) == capturedFinal,
                  try namedStatIdentity(parentFD: parentFD, name: tempName, stage: stage) == nil else {
                throw SaveDBOpenError(stage: stage, result: .durabilityFailure)
            }
            let rollbackRenameResult = renameatx_np(
                parentFD, finalName, parentFD, tempName, UInt32(RENAME_EXCL))
            let rolledBackTemp = try namedStatIdentity(parentFD: parentFD, name: tempName, stage: stage)
            guard rolledBackTemp?.fileIdentity == identity.fileIdentity,
                  try namedStatIdentity(parentFD: parentFD, name: finalName, stage: stage) == nil else {
                throw SaveDBOpenError(stage: stage, result: .durabilityFailure)
            }
            let rollbackSynced = syncDirectory(parentFD)
            let tempAfterSync = try namedStatIdentity(parentFD: parentFD, name: tempName, stage: stage)
            let finalAfterSync = try namedStatIdentity(parentFD: parentFD, name: finalName, stage: stage)
            let rollbackObservation = LegacyRenameBoundaryObservation(
                returnedSuccess: rollbackRenameResult == 0,
                source: tempAfterSync?.fileIdentity,
                destination: finalAfterSync?.fileIdentity,
                syncSucceeded: rollbackSynced)
            guard tempAfterSync == rolledBackTemp,
                  renameBoundaryAccepted(.markerRollback,
                                         observation: rollbackObservation,
                                         expected: identity.fileIdentity) else {
                throw SaveDBOpenError(stage: stage, result: .durabilityFailure)
            }
            throw SaveDBOpenError(stage: stage, result: .durabilityFailure)
        }
        guard try namedStatIdentity(parentFD: parentFD, name: finalName, stage: stage) == capturedFinal,
              try namedStatIdentity(parentFD: parentFD, name: tempName, stage: stage) == nil else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
    }

    private static func removeValidatedTemporaryMarker(parentFD: Int32, name: String,
                                                       expectedBytes: Data, exact: Int,
                                                       stage: SaveDBOpenError.Stage) throws {
        guard let before = try namedStatIdentity(parentFD: parentFD, name: name, stage: stage) else {
            throw SaveDBOpenError(stage: stage, result: .invalidSource)
        }
        let bytes = try readNamedFile(parentFD: parentFD, name: name,
                                      maximum: exact, exact: exact, stage: stage)
        guard bytes == expectedBytes,
              try namedStatIdentity(parentFD: parentFD, name: name, stage: stage) == before else {
            throw SaveDBOpenError(stage: stage, result: .invalidSource)
        }
        _ = unlinkat(parentFD, name, 0)
        guard try namedStatIdentity(parentFD: parentFD, name: name, stage: stage) == nil else {
            throw SaveDBOpenError(stage: stage, result: .durabilityFailure)
        }
        let synced = syncDirectory(parentFD)
        let afterSync = try namedStatIdentity(parentFD: parentFD, name: name, stage: stage)
        guard synced, afterSync == nil else {
            throw SaveDBOpenError(stage: stage, result: .durabilityFailure)
        }
    }

    private static func readNamedFile(parentFD: Int32, name: String,
                                      maximum: Int, exact: Int,
                                      stage: SaveDBOpenError.Stage) throws -> Data {
        let fd = Darwin.openat(parentFD, name,
                               O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            throw SaveDBOpenError(stage: stage, result: .invalidSource)
        }
        defer { Darwin.close(fd) }
        let identity = try checkedOwnedRegular(fd: fd, stage: stage, requireMode0600: true)
        guard identity.size == exact, identity.size <= maximum else {
            throw SaveDBOpenError(stage: stage, result: .invalidSource)
        }
        var bytes = [UInt8](repeating: 0, count: exact)
        let count = try bytes.withUnsafeMutableBytes {
            try checkedPread(fd: fd, buffer: $0.baseAddress!, count: exact, offset: 0)
        }
        guard count == exact else {
            throw SaveDBOpenError(stage: stage, result: .invalidSource)
        }
        var probe: UInt8 = 0
        guard try checkedPread(fd: fd, buffer: &probe, count: 1,
                               offset: UInt64(exact)) == 0 else {
            throw SaveDBOpenError(stage: stage, result: .invalidSource)
        }
        let after = try checkedOwnedRegular(fd: fd, stage: stage, requireMode0600: true)
        guard after == identity,
              try namedStatIdentity(parentFD: parentFD, name: name, stage: stage) == identity else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        return Data(bytes)
    }

    private static func classify(parentFD: Int32, name: String) throws
        -> (kind: mode_t, identity: LegacyFileIdentity)? {
        var value = stat()
        if fstatat(parentFD, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw SaveDBOpenError(stage: .migrationManifest, result: .unavailable)
        }
        let identity = try LegacyStatIdentity(value)
        guard identity.owner == geteuid() else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .invalidSource)
        }
        return (value.st_mode & S_IFMT, identity.fileIdentity)
    }

    private static func namedStatIdentity(parentFD: Int32, name: String,
                                          stage: SaveDBOpenError.Stage) throws
        -> LegacyStatIdentity? {
        var value = stat()
        if fstatat(parentFD, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw SaveDBOpenError(stage: stage, result: .unavailable)
        }
        let identity = try LegacyStatIdentity(value)
        guard identity.owner == geteuid(), value.st_mode & S_IFMT == S_IFREG,
              identity.links == 1 else {
            throw SaveDBOpenError(stage: stage, result: .invalidSource)
        }
        return identity
    }

    private static func namespaceName(for state: LegacyNamespaceState) -> String? {
        switch state {
        case .empty: return nil
        case .source: return sourceName
        case .backup: return backupName
        }
    }

    private static func validateLease(_ preflight: LegacyMigrationPreflight,
                                      namespaceName: String?,
                                      stage: SaveDBOpenError.Stage) throws {
        let parent = try checkedStat(fd: preflight.parentFD, kind: S_IFDIR, stage: stage)
        guard parent.fileIdentity == preflight.parentIdentity else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        let lock = try checkedOwnedRegular(fd: preflight.lockFD, stage: stage,
                                           requireMode0600: true)
        guard lock == preflight.lockIdentity else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        try verifyNamedStatIdentity(parentFD: preflight.parentFD, name: lockName,
                                    expected: preflight.lockIdentity, kind: S_IFREG, stage: stage)

        guard let namespaceName else {
            guard try classify(parentFD: preflight.parentFD, name: sourceName) == nil,
                  try classify(parentFD: preflight.parentFD, name: backupName) == nil else {
                throw SaveDBOpenError(stage: stage, result: .conflict)
            }
            return
        }
        guard let expected = preflight.namespaceStatIdentity else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        let fd = preflight.sourceFD >= 0 ? preflight.sourceFD : preflight.backupFD
        let held = try checkedStat(fd: fd, kind: S_IFDIR, stage: stage)
        guard held == expected else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        try verifyNamedStatIdentity(parentFD: preflight.parentFD, name: namespaceName,
                                    expected: expected, kind: S_IFDIR, stage: stage)
        let other = namespaceName == sourceName ? backupName : sourceName
        guard try classify(parentFD: preflight.parentFD, name: other) == nil else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
    }

    private static func validateHeldLease(parentFD: Int32,
                                          parentIdentity: LegacyFileIdentity,
                                          lockFD: Int32,
                                          lockIdentity: LegacyStatIdentity,
                                          namespaceFD: Int32,
                                          namespaceIdentity: LegacyStatIdentity?,
                                          namespaceName: String?,
                                          stage: SaveDBOpenError.Stage) throws {
        let parent = try checkedStat(fd: parentFD, kind: S_IFDIR, stage: stage)
        let lock = try checkedOwnedRegular(fd: lockFD, stage: stage, requireMode0600: true)
        guard parent.fileIdentity == parentIdentity, lock == lockIdentity else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        try verifyNamedStatIdentity(parentFD: parentFD, name: lockName,
                                    expected: lockIdentity, kind: S_IFREG, stage: stage)
        guard let namespaceName else {
            guard try classify(parentFD: parentFD, name: sourceName) == nil,
                  try classify(parentFD: parentFD, name: backupName) == nil else {
                throw SaveDBOpenError(stage: stage, result: .conflict)
            }
            return
        }
        guard namespaceFD >= 0, let namespaceIdentity else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        let held = try checkedStat(fd: namespaceFD, kind: S_IFDIR, stage: stage)
        guard held == namespaceIdentity else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        try verifyNamedStatIdentity(parentFD: parentFD, name: namespaceName,
                                    expected: namespaceIdentity, kind: S_IFDIR, stage: stage)
        let other = namespaceName == sourceName ? backupName : sourceName
        guard try classify(parentFD: parentFD, name: other) == nil else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
    }

    private static func rollbackRename(preflight: LegacyMigrationPreflight) throws {
        try validateLease(preflight, namespaceName: backupName, stage: .migrationDirectorySync)
        let reverseRenameResult = renameatx_np(
            preflight.parentFD, backupName,
            preflight.parentFD, sourceName, UInt32(RENAME_EXCL))
        let source = try classify(parentFD: preflight.parentFD, name: sourceName)
        let backup = try classify(parentFD: preflight.parentFD, name: backupName)
        let locationObservation = LegacyRenameBoundaryObservation(
            returnedSuccess: reverseRenameResult == 0,
            source: source?.identity, destination: backup?.identity,
            syncSucceeded: true)
        guard renameBoundaryAccepted(.reverseSource,
                                     observation: locationObservation,
                                     expected: preflight.namespaceIdentity!) else {
            throw SaveDBOpenError(stage: .migrationDirectorySync, result: .durabilityFailure)
        }
        try refreshNamespaceAfterRename(preflight, named: sourceName, stage: .migrationDirectorySync)
        let synced = syncDirectory(preflight.parentFD)
        let sourceAfterSync = try classify(parentFD: preflight.parentFD, name: sourceName)
        let backupAfterSync = try classify(parentFD: preflight.parentFD, name: backupName)
        let durableObservation = LegacyRenameBoundaryObservation(
            returnedSuccess: reverseRenameResult == 0,
            source: sourceAfterSync?.identity, destination: backupAfterSync?.identity,
            syncSucceeded: synced)
        guard renameBoundaryAccepted(.reverseSource,
                                     observation: durableObservation,
                                     expected: preflight.namespaceIdentity!) else {
            throw SaveDBOpenError(stage: .migrationDirectorySync, result: .durabilityFailure)
        }
        try validateLease(preflight, namespaceName: sourceName, stage: .migrationDirectorySync)
    }

    private static func refreshNamespaceAfterRename(_ preflight: LegacyMigrationPreflight,
                                                    named name: String,
                                                    stage: SaveDBOpenError.Stage) throws {
        let fd = preflight.sourceFD >= 0 ? preflight.sourceFD : preflight.backupFD
        let refreshed = try checkedStat(fd: fd, kind: S_IFDIR, stage: stage)
        guard refreshed.fileIdentity == preflight.namespaceIdentity else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
        try verifyNamedStatIdentity(parentFD: preflight.parentFD, name: name,
                                    expected: refreshed, kind: S_IFDIR, stage: stage)
        preflight.namespaceStatIdentity = refreshed
    }

    private static func openOwnedLockedDirectory(parentFD: Int32, name: String,
                                                 expected: LegacyFileIdentity) throws -> Int32 {
        let fd = Darwin.openat(parentFD, name,
                               O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw SaveDBOpenError(stage: .migrationLease, result: .invalidSource)
        }
        do {
            let identity = try checkedStat(fd: fd, kind: S_IFDIR, stage: .migrationLease)
            guard identity.owner == geteuid(), identity.fileIdentity == expected,
                  flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                throw SaveDBOpenError(stage: .migrationLease, result: .conflict)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private static func checkedStat(fd: Int32, kind: mode_t,
                                    stage: SaveDBOpenError.Stage) throws -> LegacyStatIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == kind else {
            throw SaveDBOpenError(stage: stage, result: .invalidSource)
        }
        return try LegacyStatIdentity(value)
    }

    private static func checkedOwnedRegular(fd: Int32, stage: SaveDBOpenError.Stage,
                                            requireMode0600: Bool) throws -> LegacyStatIdentity {
        let value = try checkedStat(fd: fd, kind: S_IFREG, stage: stage)
        guard value.owner == geteuid(), value.links == 1,
              !requireMode0600 || value.mode & 0o777 == 0o600 else {
            throw SaveDBOpenError(stage: stage, result: .invalidSource)
        }
        return value
    }

    private static func verifyNamedIdentity(parentFD: Int32, name: String,
                                            expected: LegacyFileIdentity, kind: mode_t,
                                            stage: SaveDBOpenError.Stage) throws {
        var value = stat()
        guard fstatat(parentFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_mode & S_IFMT == kind,
              legacyDeviceBitPattern(value.st_dev) == expected.device,
              UInt64(value.st_ino) == expected.inode else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
    }

    private static func verifyNamedStatIdentity(parentFD: Int32, name: String,
                                                expected: LegacyStatIdentity, kind: mode_t,
                                                stage: SaveDBOpenError.Stage) throws {
        var value = stat()
        guard fstatat(parentFD, name, &value, AT_SYMLINK_NOFOLLOW) == 0,
              value.st_mode & S_IFMT == kind,
              try LegacyStatIdentity(value) == expected else {
            throw SaveDBOpenError(stage: stage, result: .conflict)
        }
    }

    private static func optionalNamedRegularIdentity(parentFD: Int32, name: String) throws
        -> LegacyFileIdentity? {
        var value = stat()
        if fstatat(parentFD, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw SaveDBOpenError(stage: .migrationParent, result: .unavailable)
        }
        guard value.st_mode & S_IFMT == S_IFREG else {
            throw SaveDBOpenError(stage: .migrationParent, result: .invalidSource)
        }
        return LegacyFileIdentity(
            device: legacyDeviceBitPattern(value.st_dev), inode: UInt64(value.st_ino))
    }

    private static func checkedPread(fd: Int32, buffer: UnsafeMutableRawPointer,
                                     count: Int, offset: UInt64) throws -> Int {
        guard offset <= UInt64(Int64.max) else {
            throw SaveDBOpenError(stage: .migrationManifest, result: .limitExceeded)
        }
        while true {
            let result = pread(fd, buffer, count, off_t(offset))
            if result >= 0 { return result }
            if errno == EINTR { continue }
            throw SaveDBOpenError(stage: .migrationManifest, result: .unavailable)
        }
    }

    private static func checkedWrite(fd: Int32, bytes: UnsafeRawBufferPointer) throws {
        var offset = 0
        while offset < bytes.count {
            let result = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset),
                                      bytes.count - offset)
            if result > 0 { offset += result; continue }
            if result < 0 && errno == EINTR { continue }
            throw SaveDBOpenError(stage: .migrationDirectorySync, result: .unavailable)
        }
    }

    private static func syncDirectory(_ fd: Int32) -> Bool {
        while true {
            if fsync(fd) == 0 { return true }
            if errno != EINTR { return false }
        }
    }

    private static func roundedBufferCharge(_ length: UInt64) -> UInt64 {
        let (seed, overflow) = length.addingReportingOverflow(15)
        guard !overflow else { return UInt64.max }
        let rounded = seed & ~UInt64(15)
        let (charge, finalOverflow) = rounded.addingReportingOverflow(64)
        return finalOverflow ? UInt64.max : charge
    }

    private static func discoveryFoundationBridgeCharge(inputBytes: UInt64) throws -> UInt64 {
        let (doubled, multiplyOverflow) = inputBytes.multipliedReportingOverflow(by: 2)
        let (charge, addOverflow) = doubled.addingReportingOverflow(1_048_576)
        guard !multiplyOverflow, !addOverflow, charge <= maximumResidentBytes else {
            throw SaveDBOpenError(stage: .migrationDecode, result: .limitExceeded)
        }
        return charge
    }

    private static func discoveryPersistentCharge(stemBytes: UInt64,
                                                  canonicalBytes: UInt64,
                                                  filenameBytes: UInt64) throws -> UInt64 {
        try sumResidentCharges([
            roundedBufferCharge(stemBytes), 256,
            roundedBufferCharge(canonicalBytes), 256,
            roundedBufferCharge(filenameBytes), 256,
        ])
    }

    private static func residentFits(base: UInt64, additions: [UInt64]) -> Bool {
        var total = base
        for addition in additions {
            let (next, overflow) = total.addingReportingOverflow(addition)
            guard !overflow, next <= maximumResidentBytes else { return false }
            total = next
        }
        return true
    }

    private static func sumResidentCharges(_ values: [UInt64]) throws -> UInt64 {
        var total: UInt64 = 0
        for value in values {
            let (next, overflow) = total.addingReportingOverflow(value)
            guard !overflow, next <= maximumResidentBytes else {
                throw SaveDBOpenError(stage: .migrationDecode, result: .limitExceeded)
            }
            total = next
        }
        return total
    }

    private static func validComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.utf8.contains(0) && !value.contains("/")
    }

    private static func unsignedUTF8Less(_ lhs: String, _ rhs: String) -> Bool {
        Data(lhs.utf8).lexicographicallyPrecedes(Data(rhs.utf8))
    }

    private static func chunkKeyLess(_ lhs: PebbleChunkStorageKey,
                                     _ rhs: PebbleChunkStorageKey) -> Bool {
        if lhs.dimension != rhs.dimension { return lhs.dimension < rhs.dimension }
        if lhs.chunkX != rhs.chunkX { return lhs.chunkX < rhs.chunkX }
        return lhs.chunkZ < rhs.chunkZ
    }

    private static func appendHashField(_ data: Data, to hasher: inout SHA256) {
        appendHashUInt64(UInt64(data.count), to: &hasher)
        hasher.update(data: data)
    }

    private static func appendStat(_ value: LegacyStatIdentity, to hasher: inout SHA256) {
        for field in [value.device, value.inode, UInt64(value.mode), UInt64(value.owner),
                      value.links, value.size, UInt64(bitPattern: value.modifiedSeconds),
                      UInt64(bitPattern: value.modifiedNanoseconds),
                      UInt64(bitPattern: value.changedSeconds),
                      UInt64(bitPattern: value.changedNanoseconds)] {
            appendHashUInt64(field, to: &hasher)
        }
    }

    private static func appendHashUInt64(_ value: UInt64, to hasher: inout SHA256) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { hasher.update(bufferPointer: $0) }
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func readU32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].enumerated().reduce(0) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
    }

    private static func readU64(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].enumerated().reduce(0) {
            $0 | (UInt64($1.element) << UInt64($1.offset * 8))
        }
    }

    private static func mapStorage(_ error: Error,
                                   stage: SaveDBOpenError.Stage) -> SaveDBOpenError {
        let result: SaveDBOpenError.Result
        switch error as? PebbleStorageError {
        case .duplicateOpen: result = .conflict
        case .invalidValue, .invalidStorageClass, .invalidUTF8,
             .schemaMismatch, .schemaIntegrity: result = .invalidSource
        case .limitExceeded: result = .limitExceeded
        default: result = stage == .migrationBarrier ? .durabilityFailure : .unavailable
        }
        return SaveDBOpenError(stage: stage, result: result)
    }
}
