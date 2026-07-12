import CryptoKit
import Darwin
import Foundation
import Security



public enum ReleaseGateError: Error, Equatable, CustomStringConvertible {
    case invalidIdentity, absent, duplicate, staleSequence, exhausted, invalidTransition
    case malformed, persistence, unavailable, authorization, unsafePath, evidence, artifact

    public var description: String {
        switch self {
        case .invalidIdentity: return "invalid secure-store identity"
        case .absent: return "authoritative receipt absent"
        case .duplicate: return "authoritative receipt already exists"
        case .staleSequence: return "stale receipt transition"
        case .exhausted: return "receipt sequence exhausted"
        case .invalidTransition: return "invalid receipt transition"
        case .malformed: return "malformed authoritative receipt"
        case .persistence: return "secure receipt persistence failed"
        case .unavailable: return "secure receipt store unavailable"
        case .authorization: return "secure receipt authorization failed"
        case .unsafePath: return "unsafe receipt path"
        case .evidence: return "receipt evidence invalid"
        case .artifact: return "release artifact identity invalid"
        }
    }
}

public enum ReleaseGateState: String, Codable, CaseIterable, Sendable {
    case preparing, prepared, observedPendingDesigner, observed, finalized
    case commitArmed, committed, pushArmed, invalidated
}

public struct ReleaseArtifactIdentity: Codable, Equatable, Sendable {
    public var releasePath: String
    public var releaseSHA256: String
    public var installedBundlePath: String
    public var installedExecutablePath: String
    public var installedSHA256: String
    public var installedCDHash: String
    public var bundleID: String
    public var signingRequirement: String
    public var livePID: Int32
    public var liveStartIdentity: String

    public init(releasePath: String, releaseSHA256: String, installedBundlePath: String,
                installedExecutablePath: String, installedSHA256: String,
                installedCDHash: String, bundleID: String,
                signingRequirement: String = "", livePID: Int32 = 0,
                liveStartIdentity: String = "") {
        self.releasePath = releasePath; self.releaseSHA256 = releaseSHA256
        self.installedBundlePath = installedBundlePath
        self.installedExecutablePath = installedExecutablePath
        self.installedSHA256 = installedSHA256; self.installedCDHash = installedCDHash
        self.bundleID = bundleID
        self.signingRequirement = signingRequirement
        self.livePID = livePID; self.liveStartIdentity = liveStartIdentity
    }
}

public struct ReleaseGatePayload: Codable, Equatable, Sendable {
    public var schema = "PebbleReleaseGateAuthorityV1"
    public var receiptID: String
    public var sequence: UInt64
    public var state: ReleaseGateState
    public var repositoryRootDigest: String
    public var contentDigest: String
    public var contentCount: Int
    public var checklistDigest: String
    public var observerDigest: String
    public var automatedGateDigest: String
    public var evidenceDigest: String
    public var observationChallenge: String?
    public var designerChallenge: String?
    public var observerProcessID: Int32?
    public var observerProcessStart: String?
    public var artifacts: ReleaseArtifactIdentity
    public var expiresEpochSeconds: Int64
    public var parentCommit: String?
    public var committedID: String?
    public var pushIdentity: String?

    public init(receiptID: String = UUID().uuidString, sequence: UInt64 = 0,
                state: ReleaseGateState = .prepared, repositoryRootDigest: String,
                contentDigest: String, contentCount: Int, checklistDigest: String,
                observerDigest: String, automatedGateDigest: String,
                evidenceDigest: String = "", observationChallenge: String?,
                designerChallenge: String?, observerProcessID: Int32? = nil,
                observerProcessStart: String? = nil, artifacts: ReleaseArtifactIdentity,
                expiresEpochSeconds: Int64, parentCommit: String? = nil,
                committedID: String? = nil, pushIdentity: String? = nil) {
        self.receiptID = receiptID; self.sequence = sequence; self.state = state
        self.repositoryRootDigest = repositoryRootDigest; self.contentDigest = contentDigest
        self.contentCount = contentCount; self.checklistDigest = checklistDigest
        self.observerDigest = observerDigest; self.automatedGateDigest = automatedGateDigest
        self.evidenceDigest = evidenceDigest; self.observationChallenge = observationChallenge
        self.designerChallenge = designerChallenge; self.observerProcessID = observerProcessID
        self.observerProcessStart = observerProcessStart; self.artifacts = artifacts
        self.expiresEpochSeconds = expiresEpochSeconds; self.parentCommit = parentCommit
        self.committedID = committedID; self.pushIdentity = pushIdentity
    }
}

private struct AuthoritativeEnvelope: Codable, Equatable {
    let payload: ReleaseGatePayload
    let internalMAC: String
}

public enum ReleaseGateCodec {
    private static let payloadKeys: Set<String> = [
        "schema", "receiptID", "sequence", "state", "repositoryRootDigest", "contentDigest",
        "contentCount", "checklistDigest", "observerDigest", "automatedGateDigest",
        "evidenceDigest", "observationChallenge", "designerChallenge", "artifacts",
        "observerProcessID", "observerProcessStart",
        "expiresEpochSeconds", "parentCommit", "committedID", "pushIdentity",
    ]
    private static let optionalPayloadKeys: Set<String> = [
        "observationChallenge", "designerChallenge", "observerProcessID",
        "observerProcessStart", "parentCommit", "committedID", "pushIdentity",
    ]
    private static let envelopeKeys: Set<String> = ["payload", "internalMAC"]
    private static let artifactKeys: Set<String> = [
        "releasePath", "releaseSHA256", "installedBundlePath", "installedExecutablePath",
        "installedSHA256", "installedCDHash", "bundleID", "signingRequirement", "livePID",
        "liveStartIdentity",
    ]

    public static func encode(_ payload: ReleaseGatePayload) throws -> Data {
        let body = try canonicalPayload(payload)
        let mac = SHA256.hash(data: Data("pebble-keychain-authority-v1\0".utf8) + body)
            .map { String(format: "%02x", $0) }.joined()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(AuthoritativeEnvelope(payload: payload, internalMAC: mac))
    }

    public static func decode(_ data: Data) throws -> ReleaseGatePayload {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw ReleaseGateError.malformed }
        guard let root = object as? [String: Any],
              Set(root.keys) == envelopeKeys,
              let payloadObject = root["payload"] as? [String: Any],
              Set(payloadObject.keys).isSubset(of: payloadKeys),
              payloadKeys.subtracting(optionalPayloadKeys).isSubset(of: Set(payloadObject.keys)),
              let artifact = payloadObject["artifacts"] as? [String: Any],
              Set(artifact.keys) == artifactKeys else { throw ReleaseGateError.malformed }
        let envelope: AuthoritativeEnvelope
        do { envelope = try JSONDecoder().decode(AuthoritativeEnvelope.self, from: data) }
        catch { throw ReleaseGateError.malformed }
        let expected = try encode(envelope.payload)
        guard let expectedRoot = try JSONSerialization.jsonObject(with: expected) as? [String: Any],
              expectedRoot["internalMAC"] as? String == envelope.internalMAC,
              envelope.payload.schema == "PebbleReleaseGateAuthorityV1" else {
            throw ReleaseGateError.malformed
        }
        return envelope.payload
    }

    public static func canonicalPayload(_ payload: ReleaseGatePayload) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(payload)
    }
}

public protocol ReceiptStateStore: Sendable {
    func load() throws -> ReleaseGatePayload
    func add(_ value: ReleaseGatePayload) throws
    func checkedUpdate(expectedSequence: UInt64, value: ReleaseGatePayload) throws
    func delete() throws
}

public final class EphemeralReceiptStateStore: ReceiptStateStore, @unchecked Sendable {
    public enum Fault: Hashable { case load, add, beforeUpdate, afterUpdate, delete }
    private let mutex = NSLock()
    private var value: Data?
    public var faults: Set<Fault> = []
    public private(set) var history: [Data] = []

    public init(initial: ReleaseGatePayload? = nil) throws {
        if let initial { value = try ReleaseGateCodec.encode(initial); history = [value!] }
    }
    public func load() throws -> ReleaseGatePayload { try mutex.withLock {
        if faults.contains(.load) { throw ReleaseGateError.unavailable }
        guard let value else { throw ReleaseGateError.absent }
        return try ReleaseGateCodec.decode(value)
    } }
    public func add(_ newValue: ReleaseGatePayload) throws { try mutex.withLock {
        if faults.contains(.add) { throw ReleaseGateError.persistence }
        guard value == nil else { throw ReleaseGateError.duplicate }
        value = try ReleaseGateCodec.encode(newValue); history.append(value!)
    } }
    public func checkedUpdate(expectedSequence: UInt64, value newValue: ReleaseGatePayload) throws {
        try mutex.withLock {
            if faults.contains(.beforeUpdate) { throw ReleaseGateError.persistence }
            guard let stored = self.value else { throw ReleaseGateError.absent }
            let current = try ReleaseGateCodec.decode(stored)
            guard current.sequence == expectedSequence else { throw ReleaseGateError.staleSequence }
            let encoded = try ReleaseGateCodec.encode(newValue)
            self.value = encoded; history.append(encoded)
            if faults.contains(.afterUpdate) { throw ReleaseGateError.persistence }
        }
    }
    public func delete() throws { try mutex.withLock {
        if faults.contains(.delete) { throw ReleaseGateError.persistence }
        value = nil
    } }
    public func replaceForTest(_ data: Data?) { mutex.withLock { value = data } }
}

public struct KeychainReceiptIdentity: Equatable, Sendable {
    public static let productionService = "com.briangao.pebble.installed-signoff.authority"
    public let service: String
    public let account: String

    public static func production(repositoryRootDigest: String) throws -> Self {
        guard Self.isHexDigest(repositoryRootDigest) else { throw ReleaseGateError.invalidIdentity }
        return Self(service: productionService, account: "repository:\(repositoryRootDigest)")
    }
    public static func isolatedTest(service: String, account: String) throws -> Self {
        guard service.hasPrefix("com.briangao.pebble.test.installed-signoff."),
              account.hasPrefix("test:"), service != productionService,
              !service.contains(productionService), !account.contains("repository:") else {
            throw ReleaseGateError.invalidIdentity
        }
        return Self(service: service, account: account)
    }
    private static func isHexDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

public protocol KeychainSecurityOperating: Sendable {
    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?)
    func add(_ attributes: CFDictionary) -> OSStatus
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

public struct SystemKeychainSecurityOperations: KeychainSecurityOperating {
    public init() {}
    public func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
        var result: CFTypeRef?
        return (SecItemCopyMatching(query, &result), result)
    }
    public func add(_ attributes: CFDictionary) -> OSStatus { SecItemAdd(attributes, nil) }
    public func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        SecItemUpdate(query, attributes)
    }
    public func delete(_ query: CFDictionary) -> OSStatus { SecItemDelete(query) }
}

public final class KeychainReceiptStateStore: ReceiptStateStore, @unchecked Sendable {
    public let identity: KeychainReceiptIdentity
    private let operations: KeychainSecurityOperating
    public init(productionRepositoryRootDigest: String) throws {
        identity = try .production(repositoryRootDigest: productionRepositoryRootDigest)
        operations = SystemKeychainSecurityOperations()
    }
    public init(isolatedTestIdentity: KeychainReceiptIdentity) {
        identity = isolatedTestIdentity
        operations = SystemKeychainSecurityOperations()
    }
    public init(isolatedTestIdentity: KeychainReceiptIdentity,
                operations: KeychainSecurityOperating) {
        identity = isolatedTestIdentity; self.operations = operations
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: identity.service,
         kSecAttrAccount as String: identity.account]
    }
    public func load() throws -> ReleaseGatePayload {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, result) = operations.copyMatching(q as CFDictionary)
        guard status == errSecSuccess, let data = result as? Data else { throw map(status) }
        return try ReleaseGateCodec.decode(data)
    }
    public func add(_ value: ReleaseGatePayload) throws {
        var q = query; q[kSecValueData as String] = try ReleaseGateCodec.encode(value)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = operations.add(q as CFDictionary)
        guard status == errSecSuccess else { throw map(status) }
    }
    public func checkedUpdate(expectedSequence: UInt64, value: ReleaseGatePayload) throws {
        let current = try load()
        guard current.sequence == expectedSequence else { throw ReleaseGateError.staleSequence }
        let status = operations.update(
            query as CFDictionary,
            attributes: [kSecValueData as String: try ReleaseGateCodec.encode(value)] as CFDictionary)
        guard status == errSecSuccess else { throw map(status) }
    }
    public func delete() throws {
        let status = operations.delete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw map(status) }
    }
    public func accessibilityClass() throws -> String {
        var q = query
        // Security does not include `kSecAttrAccessible` in the attributes returned for
        // a legacy generic-password item. Make it part of the match predicate instead:
        // success proves that the persisted item has the required accessibility class.
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, _) = operations.copyMatching(q as CFDictionary)
        guard status == errSecSuccess else { throw map(status) }
        return String(describing: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
    }
    func map(_ status: OSStatus) -> ReleaseGateError {
        switch status {
        case errSecItemNotFound: return .absent
        case errSecDuplicateItem: return .duplicate
        case errSecInteractionNotAllowed, errSecNotAvailable: return .unavailable
        case errSecAuthFailed, errSecUserCanceled: return .authorization
        case errSecDecode: return .malformed
        default: return .persistence
        }
    }
}

public enum ReleaseGatePersistencePoint: String, CaseIterable, Sendable {
    case beforeCacheWrite, afterCacheWrite, beforeCacheFsync, afterCacheFsync
    case beforeCacheRename, afterCacheRename
}

public final class ReleaseGateCoordinator: @unchecked Sendable {
    private let store: ReceiptStateStore
    public let root: URL
    public let cacheURL: URL
    public let lockURL: URL
    private let fault: @Sendable (ReleaseGatePersistencePoint) -> Bool
    private let validator: @Sendable (ReleaseGatePayload) throws -> Void

    public init(store: ReceiptStateStore, root: URL,
                fault: @escaping @Sendable (ReleaseGatePersistencePoint) -> Bool = { _ in false },
                validator: @escaping @Sendable (ReleaseGatePayload) throws -> Void = { _ in }) throws {
        self.store = store; self.root = root
        self.fault = fault
        self.validator = validator
        cacheURL = root.appendingPathComponent("current.json")
        lockURL = root.appendingPathComponent("authority.lock")
        try Self.ensurePrivateDirectory(root)
    }

    public func create(_ payload: ReleaseGatePayload) throws {
        try withLock {
            guard payload.sequence == 0, payload.state == .prepared else {
                throw ReleaseGateError.invalidTransition
            }
            try store.add(payload)
            try writeCache(payload)
        }
    }

    /// Starts a fresh prepared receipt without resetting the monotonic Keychain sequence.
    public func restart(_ proposed: ReleaseGatePayload,
                        initialState: ReleaseGateState = .prepared) throws -> ReleaseGatePayload {
        try withLock {
            guard initialState == .preparing || initialState == .prepared else {
                throw ReleaseGateError.invalidTransition
            }
            do {
                let current = try store.load()
                let addition = current.sequence.addingReportingOverflow(1)
                guard !addition.overflow else { throw ReleaseGateError.exhausted }
                var next = proposed; next.sequence = addition.partialValue; next.state = initialState
                try store.checkedUpdate(expectedSequence: current.sequence, value: next)
                try writeCache(next); return next
            } catch ReleaseGateError.absent {
                var first = proposed; first.sequence = 0; first.state = initialState
                try store.add(first); try writeCache(first); return first
            }
        }
    }

    public func authoritative() throws -> ReleaseGatePayload { try withLock {
        let value = try store.load(); try writeCache(value); return value
    } }

    @discardableResult
    public func transition(from expected: ReleaseGateState, to next: ReleaseGateState,
                           expectedSequence: UInt64? = nil,
                           mutate: (inout ReleaseGatePayload) throws -> Void = { _ in }) throws
        -> ReleaseGatePayload {
        try withLock {
            var current = try store.load()
            guard current.state == expected,
                  expectedSequence == nil || current.sequence == expectedSequence else {
                throw ReleaseGateError.staleSequence
            }
            let addition = current.sequence.addingReportingOverflow(1)
            guard !addition.overflow else { throw ReleaseGateError.exhausted }
            guard Self.allowed(expected, next) else { throw ReleaseGateError.invalidTransition }
            if current.state != .preparing { try validator(current) }
            let oldSequence = current.sequence
            current.sequence = addition.partialValue; current.state = next
            try mutate(&current)
            try store.checkedUpdate(expectedSequence: oldSequence, value: current)
            try validator(current)
            try writeCache(current)
            return current
        }
    }

    public func invalidate() throws {
        try withLock {
            var current = try store.load()
            guard current.state != .invalidated else { return }
            let addition = current.sequence.addingReportingOverflow(1)
            guard !addition.overflow else { throw ReleaseGateError.exhausted }
            let old = current.sequence
            current.sequence = addition.partialValue; current.state = .invalidated
            try store.checkedUpdate(expectedSequence: old, value: current)
            try writeCache(current)
        }
    }

    private static func allowed(_ from: ReleaseGateState, _ to: ReleaseGateState) -> Bool {
        if to == .invalidated { return from != .invalidated }
        return (from, to) == (.preparing, .prepared) ||
            (from, to) == (.prepared, .observedPendingDesigner) ||
            (from, to) == (.observedPendingDesigner, .observed) ||
            (from, to) == (.observed, .finalized) ||
            (from, to) == (.finalized, .commitArmed) ||
            (from, to) == (.commitArmed, .committed) ||
            (from, to) == (.committed, .pushArmed)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ReleaseGateError.unsafePath }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_nlink == 1,
              info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600,
              flock(fd, LOCK_EX) == 0 else { throw ReleaseGateError.unsafePath }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    private func writeCache(_ payload: ReleaseGatePayload) throws {
        try Self.ensurePrivateDirectory(root)
        if fault(.beforeCacheWrite) { throw ReleaseGateError.persistence }
        let data = try ReleaseGateCodec.encode(payload)
        let temp = root.appendingPathComponent(".cache.\(UUID().uuidString)")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ReleaseGateError.unsafePath }
        let result = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard result == data.count, !fault(.afterCacheWrite), !fault(.beforeCacheFsync),
              fsync(fd) == 0, !fault(.afterCacheFsync) else {
            close(fd); unlink(temp.path); throw ReleaseGateError.persistence
        }
        close(fd)
        guard !fault(.beforeCacheRename), rename(temp.path, cacheURL.path) == 0 else {
            unlink(temp.path); throw ReleaseGateError.persistence
        }
        if fault(.afterCacheRename) { throw ReleaseGateError.persistence }
        try Self.requirePrivateFile(cacheURL)
    }

    public static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw ReleaseGateError.unsafePath }
    }

    public static func requirePrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700 else { throw ReleaseGateError.unsafePath }
    }

    public static func requirePrivateFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1 else {
            throw ReleaseGateError.unsafePath
        }
    }
}

public struct StableFileIdentity: Equatable, Sendable {
    public let canonicalPath: String
    public let sha256: String
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let mode: UInt16
}

public enum StableFileHasher {
    public static func capture(
        _ url: URL, exactCanonicalPath: String? = nil, requireExecutable: Bool = false
    ) throws -> StableFileIdentity {
        let parentURL = url.deletingLastPathComponent()
        let parentFD = open(parentURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentFD >= 0 else { throw ReleaseGateError.unsafePath }
        defer { close(parentFD) }
        var parentBefore = stat(), parentAfter = stat()
        guard fstat(parentFD, &parentBefore) == 0,
              parentBefore.st_mode & S_IFMT == S_IFDIR else {
            throw ReleaseGateError.unsafePath
        }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ReleaseGateError.unsafePath }
        defer { close(fd) }
        var before = stat(), after = stat(), pathAfter = stat()
        guard fstat(fd, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              !requireExecutable || before.st_mode & 0o111 != 0 else {
            throw ReleaseGateError.unsafePath
        }
        var bytes = Data(); bytes.reserveCapacity(Int(clamping: before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw ReleaseGateError.persistence }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, lstat(url.path, &pathAfter) == 0,
              fstat(parentFD, &parentAfter) == 0,
              same(before, after), same(before, pathAfter),
              parentBefore.st_dev == parentAfter.st_dev,
              parentBefore.st_ino == parentAfter.st_ino,
              let resolved = realpath(url.path, nil) else { throw ReleaseGateError.artifact }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        if let exactCanonicalPath, canonical != exactCanonicalPath {
            throw ReleaseGateError.artifact
        }
        return StableFileIdentity(
            canonicalPath: canonical, sha256: AutomatedGateEvidence.sha256(bytes),
            device: UInt64(before.st_dev), inode: UInt64(before.st_ino), size: before.st_size,
            modifiedSeconds: Int64(before.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(before.st_mtimespec.tv_nsec),
            mode: UInt16(before.st_mode & 0o7777))
    }

    public static func revalidate(_ identity: StableFileIdentity) throws {
        guard try capture(URL(fileURLWithPath: identity.canonicalPath),
                          exactCanonicalPath: identity.canonicalPath,
                          requireExecutable: identity.mode & 0o111 != 0) == identity else {
            throw ReleaseGateError.artifact
        }
    }

    private static func same(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino &&
            left.st_size == right.st_size && left.st_nlink == right.st_nlink &&
            left.st_mode == right.st_mode &&
            left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec &&
            left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
    }
}

public struct LiveProcessKernelIdentity: Equatable, Sendable {
    public let pid: Int32
    public let startIdentity: String
    public let executablePath: String
    public init(pid: Int32, startIdentity: String, executablePath: String) {
        self.pid = pid; self.startIdentity = startIdentity
        self.executablePath = executablePath
    }
}

public enum LiveProcessKernelIdentityReader {
    public static func capture(pid: Int32) throws -> LiveProcessKernelIdentity {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var value = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &value, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.stride else { throw ReleaseGateError.evidence }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else {
            throw ReleaseGateError.evidence
        }
        let start = value.kp_proc.p_starttime
        return LiveProcessKernelIdentity(
            pid: pid, startIdentity: "\(start.tv_sec).\(start.tv_usec)",
            executablePath: String(cString: path))
    }

    public static func revalidate(_ expected: LiveProcessKernelIdentity) throws {
        guard try capture(pid: expected.pid) == expected else { throw ReleaseGateError.artifact }
    }
}

public struct RawProcessChannels: Equatable, Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
}

public struct CodesignChannelFixture: Equatable, Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public let expectedExecutable: String

    public init(status: Int32, stdout: Data, stderr: Data, expectedExecutable: String) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
        self.expectedExecutable = expectedExecutable
    }
}

public enum CodesignRawChannelParser {
    public static let maximumRequirementBytes = 4_096

    public static func parse(_ fixture: CodesignChannelFixture) throws -> String {
        guard fixture.status == 0 else { throw ReleaseGateError.artifact }
        try validateEnvelope(fixture.stderr, maximumBytes: 8_192)
        let expectedStderr = Data("Executable=\(fixture.expectedExecutable)\n".utf8)
        guard fixture.stderr == expectedStderr else { throw ReleaseGateError.artifact }
        try validateEnvelope(fixture.stdout, maximumBytes: maximumRequirementBytes + 32)
        let decorated = Data("# designated => ".utf8)
        let legacy = Data("designated => ".utf8)
        let prefix: Data
        if fixture.stdout.starts(with: decorated) { prefix = decorated }
        else if fixture.stdout.starts(with: legacy) { prefix = legacy }
        else { throw ReleaseGateError.artifact }
        let payload = fixture.stdout.dropFirst(prefix.count).dropLast()
        return try validateRequirementPayload(Data(payload))
    }

    public static func validateRequirementPayload(_ data: Data) throws -> String {
        guard !data.isEmpty, data.count <= maximumRequirementBytes,
              !data.contains(0x23),
              data.allSatisfy({ $0 >= 0x20 && $0 != 0x7f }),
              let value = String(data: data, encoding: .utf8),
              value.utf8.count == data.count,
              value.first.map({ !$0.isWhitespace }) == true,
              value.last.map({ !$0.isWhitespace }) == true else {
            throw ReleaseGateError.artifact
        }
        return value
    }

    private static func validateEnvelope(_ data: Data, maximumBytes: Int) throws {
        guard !data.isEmpty, data.count <= maximumBytes,
              data.last == 0x0a, data.filter({ $0 == 0x0a }).count == 1,
              data.dropLast().allSatisfy({ $0 >= 0x20 && $0 != 0x7f }),
              String(data: data, encoding: .utf8) != nil else {
            throw ReleaseGateError.artifact
        }
    }
}

public enum RawTwoChannelProcessCapture {
    public static func capture(
        executable: String, arguments: [String], timeoutSeconds: TimeInterval = 30
    ) throws -> RawProcessChannels {
        guard timeoutSeconds > 0 else { throw ReleaseGateError.evidence }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pebble-raw-channels-\(UUID().uuidString)")
        try ReleaseGateCoordinator.ensurePrivateDirectory(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout.raw")
        let stderrURL = directory.appendingPathComponent("stderr.raw")
        let stdoutFD = open(stdoutURL.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard stdoutFD >= 0 else { throw ReleaseGateError.persistence }
        let stderrFD = open(stderrURL.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard stderrFD >= 0 else { close(stdoutFD); throw ReleaseGateError.persistence }
        let stdoutHandle = FileHandle(fileDescriptor: stdoutFD, closeOnDealloc: false)
        let stderrHandle = FileHandle(fileDescriptor: stderrFD, closeOnDealloc: false)
        var handlesClosed = false
        defer {
            if !handlesClosed { try? stdoutHandle.close(); try? stderrHandle.close() }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutHandle; process.standardError = stderrHandle
        try process.run()
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw ReleaseGateError.evidence
        }
        try stdoutHandle.synchronize(); try stderrHandle.synchronize()
        try stdoutHandle.close(); try stderrHandle.close(); handlesClosed = true
        try ReleaseGateCoordinator.requirePrivateFile(stdoutURL)
        try ReleaseGateCoordinator.requirePrivateFile(stderrURL)
        return RawProcessChannels(
            status: process.terminationStatus,
            stdout: try Data(contentsOf: stdoutURL, options: .mappedIfSafe),
            stderr: try Data(contentsOf: stderrURL, options: .mappedIfSafe))
    }
}

public enum CodesignRawCapture {
    public static func capture(canonicalBundlePath: String) throws -> String {
        let expectedExecutable = canonicalBundlePath + "/Contents/MacOS/Pebble"
        let channels = try RawTwoChannelProcessCapture.capture(
            executable: "/usr/bin/codesign", arguments: ["-d", "-r-", canonicalBundlePath])
        return try CodesignRawChannelParser.parse(.init(
            status: channels.status, stdout: channels.stdout, stderr: channels.stderr,
            expectedExecutable: expectedExecutable))
    }
}

public struct ClosedCommandSpec: Equatable, Sendable {
    public let commandID: String
    public let executable: String
    public let arguments: [String]
    public let versionArguments: [String]
    public let expectedVersionPrefix: String
    public let timeoutSeconds: TimeInterval

    public init(commandID: String, executable: String, arguments: [String],
                versionArguments: [String] = ["--version"], expectedVersionPrefix: String = "",
                timeoutSeconds: TimeInterval = 900) {
        self.commandID = commandID; self.executable = executable; self.arguments = arguments
        self.versionArguments = versionArguments; self.timeoutSeconds = timeoutSeconds
        self.expectedVersionPrefix = expectedVersionPrefix
    }
}

public struct ClosedCommandResult: Equatable, Sendable {
    public let spec: ClosedCommandSpec
    public let status: Int32
    public let output: Data
    public let executableIdentity: StableFileIdentity
    public let toolVersion: String
}

public protocol ClosedCommandRunning: Sendable {
    func run(_ spec: ClosedCommandSpec, repositoryRoot: URL) throws -> ClosedCommandResult
}

public final class FoundationClosedCommandRunner: ClosedCommandRunning, @unchecked Sendable {
    public init() {}

    public func run(_ spec: ClosedCommandSpec, repositoryRoot: URL) throws -> ClosedCommandResult {
        guard spec.timeoutSeconds > 0, AutomatedGateEvidence.requiredIDs.contains(spec.commandID),
              spec.arguments.allSatisfy({ !$0.contains("\0") }) else {
            throw ReleaseGateError.evidence
        }
        let executable = try StableFileHasher.capture(
            URL(fileURLWithPath: spec.executable), requireExecutable: true)
        let version = try launch(executable: executable.canonicalPath,
                                 arguments: spec.versionArguments,
                                 repositoryRoot: repositoryRoot, timeout: 30)
        let versionText = String(decoding: version.output.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard version.status == 0,
              spec.expectedVersionPrefix.isEmpty ||
                versionText.hasPrefix(spec.expectedVersionPrefix) else {
            throw ReleaseGateError.evidence
        }
        let result = try launch(executable: executable.canonicalPath, arguments: spec.arguments,
                                repositoryRoot: repositoryRoot, timeout: spec.timeoutSeconds)
        guard result.status == 0 else { throw ReleaseGateError.evidence }
        try StableFileHasher.revalidate(executable)
        return ClosedCommandResult(
            spec: spec, status: result.status, output: result.output,
            executableIdentity: executable,
            toolVersion: versionText)
    }

    private func launch(executable: String, arguments: [String], repositoryRoot: URL,
                        timeout: TimeInterval) throws -> (status: Int32, output: Data) {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("pebble-closed-command-\(UUID().uuidString)")
        let fd = open(output.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ReleaseGateError.persistence }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = repositoryRoot
        var environment: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(), "LANG": "C", "LC_ALL": "C",
            "TMPDIR": FileManager.default.temporaryDirectory.path,
        ]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            environment["DEVELOPER_DIR"] = developer
        }
        process.environment = environment
        process.standardOutput = handle; process.standardError = handle
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline { usleep(10_000) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw ReleaseGateError.evidence
        }
        try handle.synchronize(); try handle.seek(toOffset: 0)
        return (process.terminationStatus, try handle.readToEnd() ?? Data())
    }
}

public enum DurableFilePoint: String, CaseIterable, Sendable {
    case beforeWrite, afterWrite, beforeFsync, afterFsync, beforeRename, afterRename
}

public enum DurablePrivateFileWriter {
    public static func write(
        _ data: Data, to url: URL,
        fault: (DurableFilePoint) -> Bool = { _ in false }
    ) throws {
        try ReleaseGateCoordinator.ensurePrivateDirectory(url.deletingLastPathComponent())
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".durable.\(UUID().uuidString)")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ReleaseGateError.persistence }
        if fault(.beforeWrite) { close(fd); unlink(temp.path); throw ReleaseGateError.persistence }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard count == data.count, !fault(.afterWrite), !fault(.beforeFsync),
              fsync(fd) == 0, !fault(.afterFsync) else {
            close(fd); unlink(temp.path); throw ReleaseGateError.persistence
        }
        close(fd)
        guard !fault(.beforeRename), rename(temp.path, url.path) == 0 else {
            unlink(temp.path); throw ReleaseGateError.persistence
        }
        if fault(.afterRename) { throw ReleaseGateError.persistence }
        try ReleaseGateCoordinator.requirePrivateFile(url)
    }
}

public enum ClosedGateOutputParser {
    public static func counts(commandID: String, output: String) throws -> (passed: Int, failed: Int) {
        switch commandID {
        case "source-security":
            guard output.contains("security: passed") else { throw ReleaseGateError.evidence }
            return (1, 0)
        case "release-build":
            guard output.contains("Build complete!"), !output.contains("warning:") else {
                throw ReleaseGateError.evidence
            }
            return (1, 0)
        case "release-surface":
            guard output.contains("release surface verified") else { throw ReleaseGateError.evidence }
            return (1, 0)
        case "binary-scan":
            guard output.contains("binary: passed") else { throw ReleaseGateError.evidence }
            return (1, 0)
        case "appkit-text-entry":
            guard output.contains("fields=2"), output.contains("clipboard_access=0"),
                  output.contains("cleanup=verified") else { throw ReleaseGateError.evidence }
            return (2, 0)
        case "xctest":
            let regex = try NSRegularExpression(
                pattern: "Executed ([0-9]+) tests?, with ([0-9]+) failures")
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            let values: [(Int, Int)] = regex.matches(in: output, range: range).compactMap {
                guard let totalRange = Range($0.range(at: 1), in: output),
                      let failedRange = Range($0.range(at: 2), in: output),
                      let total = Int(output[totalRange]),
                      let failed = Int(output[failedRange]) else { return nil }
                return (total, failed)
            }
            guard let largest = values.max(by: { $0.0 < $1.0 }), largest.0 > 0,
                  largest.1 == 0 else { throw ReleaseGateError.evidence }
            return largest
        case "pebsmoke":
            guard output.contains("457 passed, 0 failed") else {
                throw ReleaseGateError.evidence
            }
            return (457, 0)
        default: throw ReleaseGateError.evidence
        }
    }
}

public struct AutomatedGateEntry: Codable, Equatable, Sendable {
    public let commandID: String
    public let status: Int32
    public let passedCount: Int
    public let failedCount: Int
    public let logFile: String
    public let logSHA256: String
    public let artifactSHA256: String?
    public let executablePath: String
    public let executableSHA256: String
    public let arguments: [String]
    public let toolVersion: String

    public init(commandID: String, status: Int32, passedCount: Int, failedCount: Int,
                logFile: String, logSHA256: String, artifactSHA256: String?,
                executablePath: String = "", executableSHA256: String = "",
                arguments: [String] = [], toolVersion: String = "") {
        self.commandID = commandID; self.status = status; self.passedCount = passedCount
        self.failedCount = failedCount; self.logFile = logFile; self.logSHA256 = logSHA256
        self.artifactSHA256 = artifactSHA256; self.executablePath = executablePath
        self.executableSHA256 = executableSHA256; self.arguments = arguments
        self.toolVersion = toolVersion
    }
}

public struct AutomatedGateEvidence: Codable, Equatable, Sendable {
    public let schema: String
    public let entries: [AutomatedGateEntry]
    public static let requiredIDs: Set<String> = [
        "source-security", "release-build", "release-surface", "binary-scan",
        "appkit-text-entry", "xctest", "pebsmoke",
    ]

    public init(schema: String, entries: [AutomatedGateEntry]) {
        self.schema = schema; self.entries = entries
    }

    public func validate(in directory: URL) throws -> String {
        try ReleaseGateCoordinator.requirePrivateDirectory(directory)
        guard schema == "AutomatedGateEvidenceV1", entries.count == Self.requiredIDs.count,
              Set(entries.map(\.commandID)) == Self.requiredIDs,
              entries.allSatisfy({ $0.status == 0 && $0.failedCount == 0 }),
              entries.allSatisfy({ !$0.executablePath.isEmpty &&
                  $0.executableSHA256.utf8.count == 64 && !$0.toolVersion.isEmpty }),
              entries.first(where: { $0.commandID == "appkit-text-entry" })?.passedCount == 2,
              entries.first(where: { $0.commandID == "xctest" })?.passedCount ?? 0 > 0,
              entries.first(where: { $0.commandID == "pebsmoke" })?.passedCount == 457 else {
            throw ReleaseGateError.evidence
        }
        var stream = Data("automated-gates-v1\0".utf8)
        for entry in entries.sorted(by: { $0.commandID < $1.commandID }) {
            let url = directory.appendingPathComponent(entry.logFile)
            try ReleaseGateCoordinator.requirePrivateFile(url)
            let data = try Data(contentsOf: url)
            guard Self.sha256(data) == entry.logSHA256 else { throw ReleaseGateError.evidence }
            stream.append(try JSONEncoder.sorted.encode(entry)); stream.append(0)
        }
        return Self.sha256(stream)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }
}

public struct PackageManifest: Equatable, Sendable {
    public let values: [String: String]
    public init(data: Data) throws {
        var parsed: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parsed.updateValue(parts[1], forKey: parts[0]) == nil else {
                throw ReleaseGateError.malformed
            }
        }
        let expected: Set<String> = ["release_path", "bundle_path", "executable_path",
            "pre_sign_input_sha256", "pre_sign_staged_sha256", "post_sign_executable_sha256",
            "bundle_id", "cdhash", "designated_requirement", "sealed_resources"]
        guard Set(parsed.keys) == expected else { throw ReleaseGateError.malformed }
        values = parsed
    }
    public func validate(capturedReleaseSHA256: String) throws {
        guard let requirement = values["designated_requirement"] else {
            throw ReleaseGateError.artifact
        }
        _ = try CodesignRawChannelParser.validateRequirementPayload(Data(requirement.utf8))
        guard values["pre_sign_input_sha256"] == capturedReleaseSHA256,
              values["pre_sign_staged_sha256"] == capturedReleaseSHA256,
              values["bundle_path"]?.hasSuffix("/dist/Pebble.app") == true,
              values["executable_path"] == values["bundle_path"]! + "/Contents/MacOS/Pebble",
              values["bundle_id"] == "com.briangao.pebble",
              values["sealed_resources"] == "true",
              !(values["post_sign_executable_sha256"] ?? "").isEmpty,
              !(values["cdhash"] ?? "").isEmpty,
              !requirement.isEmpty else {
            throw ReleaseGateError.artifact
        }
    }
}

/// Closed command surface shared by the stable production CLI and the excluded workflow probe.
/// The enum deliberately carries no paths, evidence, statuses, counts, digests, or PASS values.
public enum ReleaseGateCommand: Equatable, Sendable {
    case preflight
    case runPrepareGates
    case verifyCurrent
    case observeInteractive
    case designerAttest
    case finalize
    case precommit
    case postcommit
    case resumeCommit
    case prepush(localObject: String, updateIdentity: String)
    case status

    public static func parse(_ arguments: [String]) throws -> Self {
        guard let command = arguments.first else { throw ReleaseGateError.malformed }
        switch command {
        case "preflight": guard arguments.count == 1 else { throw ReleaseGateError.malformed }; return .preflight
        case "run-prepare-gates": guard arguments.count == 1 else { throw ReleaseGateError.malformed }; return .runPrepareGates
        case "verify-current": guard arguments.count == 1 else { throw ReleaseGateError.malformed }; return .verifyCurrent
        case "observe-interactive": guard arguments.count == 1 else { throw ReleaseGateError.malformed }; return .observeInteractive
        case "designer-attest": guard arguments.count == 1 else { throw ReleaseGateError.malformed }; return .designerAttest
        case "finalize": guard arguments.count == 1 else { throw ReleaseGateError.malformed }; return .finalize
        case "precommit": guard arguments.count == 1 else { throw ReleaseGateError.malformed }; return .precommit
        case "postcommit": guard arguments.count == 1 else { throw ReleaseGateError.malformed }; return .postcommit
        case "resume-commit": guard arguments.count == 1 else { throw ReleaseGateError.malformed }; return .resumeCommit
        case "prepush":
            guard arguments.count == 3,
                  Self.isGitObject(arguments[1]), Self.isUpdateIdentity(arguments[2]) else {
                throw ReleaseGateError.malformed
            }
            return .prepush(localObject: arguments[1], updateIdentity: arguments[2])
        case "status": guard arguments.count == 1 else { throw ReleaseGateError.malformed }; return .status
        default: throw ReleaseGateError.malformed
        }
    }

    private static func isGitObject(_ value: String) -> Bool {
        [40, 64].contains(value.utf8.count) && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private static func isUpdateIdentity(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.utf8.contains(0) &&
            !value.utf8.contains(10) && !value.utf8.contains(13)
    }
}

public struct ReleaseGateWorkflowContext: Equatable, Sendable {
    public let repository: URL
    public let evidenceRoot: URL
    public let releaseExecutable: URL
    public let stagedBundle: URL
    public let installedBundle: URL
    public let installedExecutable: URL
    public let bundleID: String
    public let expirySeconds: Int64

    public init(repository: URL, evidenceRoot: URL, releaseExecutable: URL,
                stagedBundle: URL, installedBundle: URL, installedExecutable: URL,
                bundleID: String, expirySeconds: Int64 = 86_400) {
        self.repository = repository; self.evidenceRoot = evidenceRoot
        self.releaseExecutable = releaseExecutable; self.stagedBundle = stagedBundle
        self.installedBundle = installedBundle; self.installedExecutable = installedExecutable
        self.bundleID = bundleID; self.expirySeconds = expirySeconds
    }
}

/// Factual preparation inputs. This type deliberately contains no receipt id, state, sequence,
/// challenge, verdict, transition, or evidence digest.
public struct ReleaseGatePreparationFacts: Equatable, Sendable {
    public let repositoryRootDigest: String
    public let contentDigest: String
    public let contentCount: Int
    public let checklistDigest: String
    public let observerDigest: String
    public init(repositoryRootDigest: String, contentDigest: String, contentCount: Int,
                checklistDigest: String, observerDigest: String) {
        self.repositoryRootDigest = repositoryRootDigest; self.contentDigest = contentDigest
        self.contentCount = contentCount; self.checklistDigest = checklistDigest
        self.observerDigest = observerDigest
    }
}

/// Raw package/install/process observations. The dispatcher-owned workflow reopens and validates
/// every referenced object before it can become authority.
public struct ReleaseGateInstalledFacts: Equatable, Sendable {
    public let manifest: Data
    public let installedIdentity: StableFileIdentity
    public let identifier: String
    public let cdhash: String
    public let signingRequirement: String
    public let liveProcess: LiveProcessKernelIdentity
    public init(manifest: Data, installedIdentity: StableFileIdentity, identifier: String,
                cdhash: String, signingRequirement: String,
                liveProcess: LiveProcessKernelIdentity) {
        self.manifest = manifest; self.installedIdentity = installedIdentity
        self.identifier = identifier; self.cdhash = cdhash
        self.signingRequirement = signingRequirement; self.liveProcess = liveProcess
    }
}

public struct ReleaseGateObservationFacts: Equatable, Sendable {
    public let processID: Int32
    public let processStart: String
    public init(processID: Int32, processStart: String) {
        self.processID = processID; self.processStart = processStart
    }
}

public struct ReleaseGateDesignerFacts: Equatable, Sendable {
    public let rawLine: String?
    public let processID: Int32
    public let processStart: String
    public let timestamp: Int64
    public init(rawLine: String?, processID: Int32, processStart: String, timestamp: Int64) {
        self.rawLine = rawLine; self.processID = processID
        self.processStart = processStart; self.timestamp = timestamp
    }
}

/// Narrow production services. Dependencies expose operations and observations only. They never
/// receive a coordinator/store/payload mutation closure and cannot choose a receipt transition.
public protocol ReleaseGateCommandDependencies: AnyObject {
    func coordinator() throws -> ReleaseGateCoordinator
    func workflowContext() throws -> ReleaseGateWorkflowContext
    func preparationFacts() throws -> ReleaseGatePreparationFacts
    func commandRunner() -> any ClosedCommandRunning
    func installAndObserve(release: StableFileIdentity, manifestURL: URL,
                           context: ReleaseGateWorkflowContext) throws -> ReleaseGateInstalledFacts
    func randomChallengeBytes() throws -> [UInt8]
    func nowEpochSeconds() -> Int64
    func preflightSummary() throws -> [String]
    func validateCurrent(_ payload: ReleaseGatePayload) throws
    func readObservationConsent(prompt: String) throws -> String?
    func captureInstalledObservation(payload: ReleaseGatePayload,
                                     directory: URL) throws -> ReleaseGateObservationFacts
    func reviewInstalledObservation(payload: ReleaseGatePayload, directory: URL,
                                    prompt: String) throws -> ReleaseGateDesignerFacts
    func emitPublicLine(_ line: String)
    func requireIndexMatchesWorktree() throws
    func currentHead() throws -> String
    func parent(of commit: String) throws -> String
}

private struct ValidatedPreparedEvidence {
    let automatedGateDigest: String
    let evidenceDigest: String
    let artifacts: ReleaseArtifactIdentity
}

private struct ValidatedObservationEvidence {
    let evidenceDigest: String
    let processID: Int32
    let processStart: String
}

public enum ReleaseGatePrivateEvidence {
    public static func digest(_ directory: URL) throws -> String {
        try ReleaseGateCoordinator.requirePrivateDirectory(directory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil) else {
            throw ReleaseGateError.evidence
        }
        let values = (enumerator.allObjects as? [URL] ?? []).sorted { $0.path < $1.path }
        var stream = Data("pebble-private-evidence-v2\0".utf8)
        for url in values {
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw ReleaseGateError.evidence }
            let relative = String(url.path.dropFirst(directory.path.count + 1))
            if info.st_mode & S_IFMT == S_IFDIR {
                guard info.st_mode & 0o777 == 0o700 else { throw ReleaseGateError.unsafePath }
            } else {
                try ReleaseGateCoordinator.requirePrivateFile(url)
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                stream.append(Data("\(relative)\0".utf8))
                stream.append(Data("0600\0\(data.count)\0".utf8))
                stream.append(Data("\(AutomatedGateEvidence.sha256(data))\0".utf8))
            }
        }
        return AutomatedGateEvidence.sha256(stream)
    }
}

private final class ReleaseGatePreparationWorkflow {
    private let dependencies: ReleaseGateCommandDependencies
    private let context: ReleaseGateWorkflowContext
    init(dependencies: ReleaseGateCommandDependencies, context: ReleaseGateWorkflowContext) {
        self.dependencies = dependencies; self.context = context
    }

    private func specs(releaseHash: String?) -> [ClosedCommandSpec] {
        let release = context.releaseExecutable.path
        let hash = releaseHash ?? "__PENDING_RELEASE_SHA256__"
        return [
            .init(commandID: "source-security", executable: "/bin/bash",
                  arguments: ["scripts/security-scan.sh"], versionArguments: ["--version"]),
            .init(commandID: "release-build", executable: "/bin/bash",
                  arguments: ["-c", "swift package clean && swift build -c release"],
                  versionArguments: ["--version"], timeoutSeconds: 1_800),
            .init(commandID: "release-surface", executable: "/bin/bash",
                  arguments: ["scripts/verify-pebble-storage-release-surface.sh"]),
            .init(commandID: "binary-scan", executable: "/bin/bash",
                  arguments: ["scripts/security-check-binary.sh", release]),
            .init(commandID: "appkit-text-entry", executable: "/bin/bash",
                  arguments: ["scripts/appkit-text-entry-integration.sh", "--no-build",
                              "--executable", release, "--expected-hash", hash,
                              "--timeout", "90"], timeoutSeconds: 180),
            .init(commandID: "xctest", executable: "/usr/bin/xcrun",
                  arguments: ["swift", "test"], versionArguments: ["swift", "--version"],
                  timeoutSeconds: 1_800),
            .init(commandID: "pebsmoke", executable: "/usr/bin/xcrun",
                  arguments: ["swift", "run", "-c", "release", "pebsmoke"],
                  versionArguments: ["swift", "--version"], timeoutSeconds: 900),
        ]
    }

    func run(receiptDirectory: URL) throws -> ValidatedPreparedEvidence {
        try removeValidatedGeneratedReleaseIfPresent()
        let automated = receiptDirectory.appendingPathComponent("automated")
        try ReleaseGateCoordinator.ensurePrivateDirectory(receiptDirectory)
        try ReleaseGateCoordinator.ensurePrivateDirectory(automated)
        var entries: [AutomatedGateEntry] = []
        var releaseIdentity: StableFileIdentity?
        for (index, original) in specs(releaseHash: nil).enumerated() {
            let stage = index + 1
            dependencies.emitPublicLine("\(stage)/7 \(stageLabel(stage)): running")
            var spec = original
            if original.commandID == "appkit-text-entry" {
                guard let releaseIdentity else { throw ReleaseGateError.artifact }
                spec = specs(releaseHash: releaseIdentity.sha256)[index]
            }
            let result = try dependencies.commandRunner().run(spec, repositoryRoot: context.repository)
            guard result.status == 0, result.output.count <= 16 * 1_024 * 1_024 else {
                throw ReleaseGateError.evidence
            }
            if spec.commandID == "release-build" {
                releaseIdentity = try StableFileHasher.capture(
                    context.releaseExecutable, exactCanonicalPath: context.releaseExecutable.path,
                    requireExecutable: true)
            }
            let counts = try ClosedGateOutputParser.counts(
                commandID: spec.commandID,
                output: String(decoding: result.output, as: UTF8.self))
            let logName = "\(spec.commandID).log"
            try DurablePrivateFileWriter.write(result.output, to: automated.appendingPathComponent(logName))
            entries.append(.init(
                commandID: spec.commandID, status: result.status, passedCount: counts.passed,
                failedCount: counts.failed, logFile: logName,
                logSHA256: AutomatedGateEvidence.sha256(result.output),
                artifactSHA256: releaseIdentity?.sha256,
                executablePath: result.executableIdentity.canonicalPath,
                executableSHA256: result.executableIdentity.sha256,
                arguments: spec.arguments, toolVersion: result.toolVersion))
            dependencies.emitPublicLine("\(stage)/7 \(stageLabel(stage)): passed")
        }
        guard let releaseIdentity,
              entries.map(\.commandID) == specs(releaseHash: releaseIdentity.sha256).map(\.commandID),
              entries.first?.artifactSHA256 == nil,
              entries.dropFirst().allSatisfy({ $0.artifactSHA256 == releaseIdentity.sha256 }) else {
            throw ReleaseGateError.evidence
        }
        let gateEvidence = AutomatedGateEvidence(schema: "AutomatedGateEvidenceV1", entries: entries)
        let encoded = try JSONEncoder.sorted.encode(gateEvidence)
        try DurablePrivateFileWriter.write(encoded, to: automated.appendingPathComponent("automated-gates.json"))
        let gateDigest = try gateEvidence.validate(in: automated)
        let manifestURL = receiptDirectory.appendingPathComponent("package-manifest.txt")
        let raw = try dependencies.installAndObserve(
            release: releaseIdentity, manifestURL: manifestURL, context: context)
        let manifest = try PackageManifest(data: raw.manifest)
        try manifest.validate(capturedReleaseSHA256: releaseIdentity.sha256)
        guard manifest.values["release_path"] == releaseIdentity.canonicalPath,
              manifest.values["bundle_path"] == context.stagedBundle.path,
              manifest.values["executable_path"] == context.stagedBundle
                .appendingPathComponent("Contents/MacOS/Pebble").path,
              raw.installedIdentity.canonicalPath == context.installedExecutable.path,
              raw.installedIdentity.sha256 == manifest.values["post_sign_executable_sha256"],
              raw.identifier == context.bundleID,
              raw.cdhash == manifest.values["cdhash"],
              raw.signingRequirement == manifest.values["designated_requirement"],
              raw.liveProcess.executablePath == raw.installedIdentity.canonicalPath else {
            throw ReleaseGateError.artifact
        }
        try StableFileHasher.revalidate(releaseIdentity)
        try StableFileHasher.revalidate(raw.installedIdentity)
        try LiveProcessKernelIdentityReader.revalidate(raw.liveProcess)
        return ValidatedPreparedEvidence(
            automatedGateDigest: gateDigest,
            evidenceDigest: try ReleaseGatePrivateEvidence.digest(receiptDirectory),
            artifacts: .init(
                releasePath: releaseIdentity.canonicalPath,
                releaseSHA256: releaseIdentity.sha256,
                installedBundlePath: context.installedBundle.path,
                installedExecutablePath: raw.installedIdentity.canonicalPath,
                installedSHA256: raw.installedIdentity.sha256,
                installedCDHash: raw.cdhash, bundleID: raw.identifier,
                signingRequirement: raw.signingRequirement, livePID: raw.liveProcess.pid,
                liveStartIdentity: raw.liveProcess.startIdentity))
    }

    private func removeValidatedGeneratedReleaseIfPresent() throws {
        let path = context.releaseExecutable.path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let relative = String(path.dropFirst(context.repository.path.count + 1))
        guard path.hasPrefix(context.repository.path + "/"),
              relative.hasPrefix(".build/"),
              (relative.contains("/Release/") || relative.contains("/release/")),
              relative.hasSuffix("/Pebble") else {
            throw ReleaseGateError.unsafePath
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_mode & 0o111 != 0,
              let resolved = realpath(path, nil) else {
            throw ReleaseGateError.unsafePath
        }
        defer { free(resolved) }
        let canonical = String(cString: resolved)
        guard canonical.hasPrefix(context.repository.path + "/.build/"),
              canonical.hasSuffix("/Pebble"), unlink(path) == 0 else {
            throw ReleaseGateError.persistence
        }
    }

    private func stageLabel(_ stage: Int) -> String {
        ["Source security", "Release build", "Release surface", "Binary scan",
         "AppKit text entry", "XCTest", "pebsmoke"][stage - 1]
    }
}

public struct ReleaseGateDispatchResult: Equatable, Sendable {
    public let lines: [String]
    public init(lines: [String] = []) { self.lines = lines }
}

public final class ReleaseGateCommandDispatcher {
    private let dependencies: ReleaseGateCommandDependencies
    public init(dependencies: ReleaseGateCommandDependencies) { self.dependencies = dependencies }

    public func dispatch(arguments: [String]) throws -> ReleaseGateDispatchResult {
        let command = try ReleaseGateCommand.parse(arguments)
        if command == .preflight {
            return ReleaseGateDispatchResult(lines: try dependencies.preflightSummary())
        }
        let gate = try dependencies.coordinator()
        switch command {
        case .preflight:
            throw ReleaseGateError.invalidTransition
        case .runPrepareGates:
            let context = try dependencies.workflowContext()
            let facts = try dependencies.preparationFacts()
            let now = dependencies.nowEpochSeconds()
            guard context.expirySeconds > 0,
                  context.expirySeconds <= 7 * 86_400,
                  facts.contentCount >= 0 else { throw ReleaseGateError.evidence }
            let placeholder = ReleaseArtifactIdentity(
                releasePath: context.releaseExecutable.path, releaseSHA256: "",
                installedBundlePath: context.installedBundle.path,
                installedExecutablePath: context.installedExecutable.path,
                installedSHA256: "", installedCDHash: "", bundleID: context.bundleID)
            let attempt = try gate.restart(.init(
                state: .preparing, repositoryRootDigest: facts.repositoryRootDigest,
                contentDigest: facts.contentDigest, contentCount: facts.contentCount,
                checklistDigest: facts.checklistDigest, observerDigest: facts.observerDigest,
                automatedGateDigest: "", evidenceDigest: "",
                observationChallenge: try challenge(), designerChallenge: try challenge(),
                artifacts: placeholder, expiresEpochSeconds: now + context.expirySeconds),
                initialState: .preparing)
            let receiptDirectory = context.evidenceRoot.appendingPathComponent(attempt.receiptID)
            do {
                let validated = try ReleaseGatePreparationWorkflow(
                    dependencies: dependencies, context: context).run(receiptDirectory: receiptDirectory)
                let current = try gate.authoritative()
                guard current == attempt else { throw ReleaseGateError.staleSequence }
                let prepared = try gate.transition(
                    from: .preparing, to: .prepared, expectedSequence: attempt.sequence) {
                        $0.automatedGateDigest = validated.automatedGateDigest
                        $0.evidenceDigest = validated.evidenceDigest
                        $0.artifacts = validated.artifacts
                    }
                try dependencies.validateCurrent(prepared)
                return .init(lines: [
                    "PENDING_INSTALLED_SIGNOFF",
                    "Automated preparation is complete; installed observation and independent Designer review remain.",
                    "This is not deployment completion.",
                    "Next: scripts/observe-installed-signoff.sh",
                ])
            } catch {
                try? gate.invalidate()
                dependencies.emitPublicLine("Preparation failed. No prepared authority was published.")
                dependencies.emitPublicLine("Next: scripts/pipeline.sh --prepare-installed-signoff")
                throw error
            }
        case .verifyCurrent:
            try dependencies.validateCurrent(try gate.authoritative())
            return .init(lines: ["RECEIPT_CURRENT"])
        case .observeInteractive:
            let current = try gate.authoritative()
            guard current.state == .prepared, let expected = current.observationChallenge else {
                throw ReleaseGateError.invalidTransition
            }
            try dependencies.validateCurrent(current)
            let raw = try dependencies.readObservationConsent(
                prompt: "Type OBSERVE-\(expected) to begin:")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw == "OBSERVE-\(expected)" else { throw ReleaseGateError.evidence }
            let directory = try observationDirectory(for: current)
            let rawFacts = try dependencies.captureInstalledObservation(
                payload: current, directory: directory)
            let validated = try validateObservation(
                rawFacts, directory: directory, expectedPayload: current)
            guard try gate.authoritative() == current else { throw ReleaseGateError.staleSequence }
            _ = try gate.transition(
                from: .prepared, to: .observedPendingDesigner,
                expectedSequence: current.sequence) {
                    $0.evidenceDigest = validated.evidenceDigest
                    $0.observationChallenge = nil
                    $0.observerProcessID = validated.processID
                    $0.observerProcessStart = validated.processStart
                }
            return .init(lines: [
                "Fourteen installed observation records were sealed.",
                "Independent Designer review remains.",
                "Next: scripts/designer-attest-installed-signoff.sh",
            ])
        case .designerAttest:
            let current = try gate.authoritative()
            guard current.state == .observedPendingDesigner,
                  let expected = current.designerChallenge,
                  let observerPID = current.observerProcessID,
                  let observerStart = current.observerProcessStart else {
                throw ReleaseGateError.invalidTransition
            }
            try dependencies.validateCurrent(current)
            let directory = try observationDirectory(for: current)
            let before = try ReleaseGatePrivateEvidence.digest(
                directory.deletingLastPathComponent())
            guard before == current.evidenceDigest else { throw ReleaseGateError.evidence }
            let review = try dependencies.reviewInstalledObservation(
                payload: current, directory: directory,
                prompt: "Type DESIGN-\(expected) to attest PASS, or FAIL to invalidate:")
            guard review.processID != observerPID || review.processStart != observerStart else {
                throw ReleaseGateError.authorization
            }
            let answer = review.rawLine?.trimmingCharacters(in: .whitespacesAndNewlines)
            if answer == "FAIL" {
                try gate.invalidate()
                throw ReleaseGateError.evidence
            }
            guard answer == "DESIGN-\(expected)", review.timestamp > 0 else {
                throw ReleaseGateError.evidence
            }
            let attestation: [String: Any] = [
                "schema": "PebbleDesignerAttestationV2", "verdict": "PASS",
                "checklistPassed": 14, "checklistTotal": 14,
                "sealedEvidenceSHA256": current.evidenceDigest,
                "designerPID": review.processID,
                "designerProcessStart": review.processStart,
                "timestamp": review.timestamp,
            ]
            let attestationURL = directory.appendingPathComponent("designer-attestation.json")
            try DurablePrivateFileWriter.write(
                try JSONSerialization.data(withJSONObject: attestation, options: [.sortedKeys]),
                to: attestationURL)
            try ReleaseGateCoordinator.requirePrivateFile(attestationURL)
            guard let reopened = try JSONSerialization.jsonObject(
                with: Data(contentsOf: attestationURL)) as? [String: Any],
                  reopened["schema"] as? String == "PebbleDesignerAttestationV2",
                  reopened["verdict"] as? String == "PASS" else {
                throw ReleaseGateError.evidence
            }
            let finalDigest = try ReleaseGatePrivateEvidence.digest(
                directory.deletingLastPathComponent())
            guard try gate.authoritative() == current else { throw ReleaseGateError.staleSequence }
            _ = try gate.transition(
                from: .observedPendingDesigner, to: .observed,
                expectedSequence: current.sequence) {
                    $0.evidenceDigest = finalDigest; $0.designerChallenge = nil
                }
            return .init(lines: [
                "Independent Designer review recorded.",
                "Next: scripts/finalize-installed-signoff.sh",
            ])
        case .finalize:
            let current = try gate.authoritative()
            try dependencies.validateCurrent(current)
            _ = try gate.transition(from: .observed, to: .finalized,
                                    expectedSequence: current.sequence)
            return .init(lines: ["INSTALLED_SIGNOFF_COMPLETE state=finalized"])
        case .precommit:
            let current = try gate.authoritative()
            try dependencies.validateCurrent(current)
            try dependencies.requireIndexMatchesWorktree()
            let head = try dependencies.currentHead()
            if current.state == .commitArmed {
                guard current.parentCommit == head else { throw ReleaseGateError.invalidTransition }
                return .init()
            }
            _ = try gate.transition(from: .finalized, to: .commitArmed,
                                    expectedSequence: current.sequence) { $0.parentCommit = head }
            return .init()
        case .postcommit, .resumeCommit:
            let current = try gate.authoritative()
            try dependencies.validateCurrent(current)
            let head = try dependencies.currentHead()
            if current.state == .committed {
                guard current.committedID == head else { throw ReleaseGateError.invalidTransition }
                return .init(lines: ["INSTALLED_SIGNOFF_COMMIT_RECORDED"])
            }
            guard current.state == .commitArmed, let expectedParent = current.parentCommit,
                  try dependencies.parent(of: head) == expectedParent else {
                throw ReleaseGateError.invalidTransition
            }
            _ = try gate.transition(from: .commitArmed, to: .committed,
                                    expectedSequence: current.sequence) { $0.committedID = head }
            return .init(lines: ["INSTALLED_SIGNOFF_COMMIT_RECORDED"])
        case .prepush(let localObject, let updateIdentity):
            let current = try gate.authoritative()
            try dependencies.validateCurrent(current)
            if current.state == .pushArmed {
                guard current.committedID == localObject,
                      current.pushIdentity == updateIdentity else {
                    throw ReleaseGateError.invalidTransition
                }
                return .init()
            }
            guard current.state == .committed, current.committedID == localObject else {
                throw ReleaseGateError.invalidTransition
            }
            _ = try gate.transition(from: .committed, to: .pushArmed,
                                    expectedSequence: current.sequence) {
                $0.pushIdentity = updateIdentity
            }
            return .init()
        case .status:
            let current = try gate.authoritative()
            return .init(lines: [
                "state=\(current.state.rawValue) sequence=\(current.sequence) expires=\(current.expiresEpochSeconds)",
                "next=\(Self.nextCommand(current.state))",
            ])
        }
    }

    private func challenge() throws -> String {
        let bytes = try dependencies.randomChallengeBytes()
        guard bytes.count == 32 else { throw ReleaseGateError.evidence }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func observationDirectory(for payload: ReleaseGatePayload) throws -> URL {
        let context = try dependencies.workflowContext()
        let receipt = context.evidenceRoot.appendingPathComponent(payload.receiptID)
        try ReleaseGateCoordinator.requirePrivateDirectory(receipt)
        return receipt.appendingPathComponent("installed")
    }

    private func validateObservation(
        _ facts: ReleaseGateObservationFacts, directory: URL,
        expectedPayload: ReleaseGatePayload
    ) throws -> ValidatedObservationEvidence {
        try ReleaseGateCoordinator.requirePrivateDirectory(directory)
        guard facts.processID > 0, !facts.processStart.isEmpty,
              expectedPayload.artifacts.livePID > 0 else {
            throw ReleaseGateError.evidence
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let commandFiles = names.filter { $0.hasSuffix(".command.json") }.sorted()
        let screenshots = names.filter { $0.hasSuffix(".png") }.sorted()
        let operations = names.filter { $0.hasSuffix(".operation.log") }.sorted()
        guard commandFiles.count == 14, screenshots.count == 14, operations.count == 14 else {
            throw ReleaseGateError.evidence
        }
        for name in commandFiles {
            let url = directory.appendingPathComponent(name)
            try ReleaseGateCoordinator.requirePrivateFile(url)
            let data = try Data(contentsOf: url)
            guard data.count <= 64 * 1_024,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schema"] as? String == "PebbleInstalledCommandEvidenceV1",
                  object["captureStatus"] as? Int == 0 else {
                throw ReleaseGateError.evidence
            }
        }
        for name in screenshots {
            let data = try Data(contentsOf: directory.appendingPathComponent(name),
                                options: .mappedIfSafe)
            guard data.count <= 64 * 1_024 * 1_024,
                  data.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
                throw ReleaseGateError.evidence
            }
        }
        return .init(
            evidenceDigest: try ReleaseGatePrivateEvidence.digest(
                directory.deletingLastPathComponent()),
            processID: facts.processID, processStart: facts.processStart)
    }

    private static func nextCommand(_ state: ReleaseGateState) -> String {
        switch state {
        case .preparing: return "scripts/pipeline.sh --prepare-installed-signoff"
        case .prepared: return "scripts/observe-installed-signoff.sh"
        case .observedPendingDesigner: return "scripts/designer-attest-installed-signoff.sh"
        case .observed: return "scripts/finalize-installed-signoff.sh"
        case .finalized: return "stage exact content, then git commit"
        case .commitArmed: return "scripts/resume-installed-signoff-commit.sh"
        case .committed, .pushArmed: return "git push"
        case .invalidated: return "scripts/pipeline.sh --prepare-installed-signoff"
        }
    }
}
