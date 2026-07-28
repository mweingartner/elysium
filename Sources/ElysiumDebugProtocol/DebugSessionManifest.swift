import CryptoKit
import Darwin
import Foundation

public struct DebugSessionToken: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public static let byteCount = 32

    private let storage: Data

    public init(data: Data) throws {
        guard data.count == Self.byteCount else {
            throw DebugProtocolError.invalidSessionKeyLength(
                actual: data.count,
                minimum: Self.byteCount
            )
        }
        self.storage = data
    }

    private init(uncheckedStorage: Data) {
        self.storage = uncheckedStorage
    }

    public init(hexEncoded: String) throws {
        guard hexEncoded.count == Self.byteCount * 2,
              hexEncoded == hexEncoded.lowercased() else {
            throw DebugProtocolError.invalidMessage("session token")
        }
        var bytes = Data()
        bytes.reserveCapacity(Self.byteCount)
        var index = hexEncoded.startIndex
        for _ in 0..<Self.byteCount {
            let next = hexEncoded.index(index, offsetBy: 2)
            guard let byte = UInt8(hexEncoded[index..<next], radix: 16) else {
                throw DebugProtocolError.invalidMessage("session token")
            }
            bytes.append(byte)
            index = next
        }
        try self.init(data: bytes)
    }

    public static func random() -> Self {
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        return Self(uncheckedStorage: bytes)
    }

    public var data: Data { storage }
    public var hexEncoded: String { storage.map { String(format: "%02x", $0) }.joined() }
    public var description: String { "<redacted debug session token>" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(hexEncoded: container.decode(String.self))
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid debug session token"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexEncoded)
    }
}

public struct DebugProcessIdentity: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let executablePath: String
    public let executableDevice: UInt64
    public let executableInode: UInt64

    public init(
        processIdentifier: Int32,
        startSeconds: UInt64,
        startMicroseconds: UInt64,
        executablePath: String,
        executableDevice: UInt64,
        executableInode: UInt64
    ) {
        self.processIdentifier = processIdentifier
        self.startSeconds = startSeconds
        self.startMicroseconds = startMicroseconds
        self.executablePath = executablePath
        self.executableDevice = executableDevice
        self.executableInode = executableInode
    }
}

public struct DebugSessionManifest: Codable, Equatable, Sendable {
    public static let formatVersion: UInt16 = 1

    public let manifestVersion: UInt16
    public let protocolVersion: UInt16
    public let sessionID: UUID
    public let process: DebugProcessIdentity
    public let port: UInt16
    public let executableSHA256: String
    public let buildIdentifier: String
    public let token: DebugSessionToken
    public let createdAt: Date

    public init(
        manifestVersion: UInt16 = Self.formatVersion,
        protocolVersion: UInt16 = ElysiumDebugProtocolVersion.current,
        sessionID: UUID = UUID(),
        process: DebugProcessIdentity,
        port: UInt16,
        executableSHA256: String,
        buildIdentifier: String,
        token: DebugSessionToken,
        createdAt: Date = Date()
    ) throws {
        self.manifestVersion = manifestVersion
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.process = process
        self.port = port
        self.executableSHA256 = executableSHA256
        self.buildIdentifier = buildIdentifier
        self.token = token
        self.createdAt = createdAt
        try DebugManifestValidator.validateFields(self)
    }

    private enum CodingKeys: String, CodingKey {
        case manifestVersion, protocolVersion, sessionID, process, port
        case executableSHA256, buildIdentifier, token, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            manifestVersion: try container.decode(UInt16.self, forKey: .manifestVersion),
            protocolVersion: try container.decode(UInt16.self, forKey: .protocolVersion),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            process: try container.decode(DebugProcessIdentity.self, forKey: .process),
            port: try container.decode(UInt16.self, forKey: .port),
            executableSHA256: try container.decode(String.self, forKey: .executableSHA256),
            buildIdentifier: try container.decode(String.self, forKey: .buildIdentifier),
            token: try container.decode(DebugSessionToken.self, forKey: .token),
            createdAt: try container.decode(Date.self, forKey: .createdAt)
        )
    }
}

public enum DebugManifestValidator {
    public static let maximumManifestBytes = 8 * 1024

    public static func validateFields(_ manifest: DebugSessionManifest) throws {
        guard manifest.manifestVersion == DebugSessionManifest.formatVersion,
              manifest.protocolVersion == ElysiumDebugProtocolVersion.current,
              manifest.port > 0,
              manifest.process.processIdentifier > 0,
              manifest.process.startSeconds > 0,
              manifest.process.executableDevice > 0,
              manifest.process.executableInode > 0,
              isCanonicalAbsolutePathShape(manifest.process.executablePath),
              isLowercaseSHA256(manifest.executableSHA256),
              isValidBuildIdentifier(manifest.buildIdentifier) else {
            throw DebugProtocolError.invalidManifest(.invalidFields)
        }
    }

    /// Reads a manifest through descriptor-relative, no-follow operations and verifies
    /// its owner-only directory and file before decoding any token-bearing contents.
    public static func loadSecurely(
        from manifestURL: URL,
        expectedUserID: UInt32? = nil,
        verifyLiveProcess: Bool = true
    ) throws -> DebugSessionManifest {
        guard manifestURL.isFileURL else {
            throw DebugProtocolError.invalidManifest(.invalidURL)
        }
        let owner = expectedUserID ?? UInt32(geteuid())
        let directoryURL = manifestURL.deletingLastPathComponent()
        let name = manifestURL.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw DebugProtocolError.invalidManifest(.invalidURL)
        }

        let directoryFD = open(
            directoryURL.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard directoryFD >= 0 else {
            throw DebugProtocolError.invalidManifest(.invalidDirectory)
        }
        defer { close(directoryFD) }

        var directoryStatus = stat()
        guard fstat(directoryFD, &directoryStatus) == 0,
              (directoryStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw DebugProtocolError.invalidManifest(.invalidDirectory)
        }
        guard directoryStatus.st_uid == owner else {
            throw DebugProtocolError.invalidManifest(.directoryOwner)
        }
        guard directoryStatus.st_mode & 0o777 == 0o700 else {
            throw DebugProtocolError.invalidManifest(.directoryPermissions)
        }
        try validateAmbientDirectory(directoryURL, matches: directoryStatus)

        let fileFD = openat(directoryFD, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fileFD >= 0 else {
            throw DebugProtocolError.invalidManifest(.invalidFile)
        }
        defer { close(fileFD) }

        var initialStatus = stat()
        guard fstat(fileFD, &initialStatus) == 0,
              (initialStatus.st_mode & S_IFMT) == S_IFREG,
              initialStatus.st_size > 0 else {
            throw DebugProtocolError.invalidManifest(.invalidFile)
        }
        guard initialStatus.st_uid == owner else {
            throw DebugProtocolError.invalidManifest(.fileOwner)
        }
        guard initialStatus.st_mode & 0o777 == 0o600 else {
            throw DebugProtocolError.invalidManifest(.filePermissions)
        }
        guard initialStatus.st_nlink == 1 else {
            throw DebugProtocolError.invalidManifest(.fileLinkCount)
        }
        guard initialStatus.st_size <= off_t(maximumManifestBytes) else {
            throw DebugProtocolError.invalidManifest(.fileTooLarge)
        }

        let data = try readBounded(fileFD, maximumBytes: maximumManifestBytes)
        var finalStatus = stat()
        guard fstat(fileFD, &finalStatus) == 0,
              finalStatus.st_dev == initialStatus.st_dev,
              finalStatus.st_ino == initialStatus.st_ino,
              finalStatus.st_uid == initialStatus.st_uid,
              finalStatus.st_mode == initialStatus.st_mode,
              finalStatus.st_nlink == initialStatus.st_nlink,
              finalStatus.st_size == initialStatus.st_size,
              data.count == Int(finalStatus.st_size) else {
            throw DebugProtocolError.invalidManifest(.invalidFile)
        }
        try validateAmbientDirectory(directoryURL, matches: directoryStatus)

        let manifest: DebugSessionManifest
        do {
            manifest = try JSONDecoder().decode(DebugSessionManifest.self, from: data)
        } catch let error as DebugProtocolError {
            throw error
        } catch {
            throw DebugProtocolError.invalidManifest(.decodeFailed)
        }
        if verifyLiveProcess {
            try validateLiveExecutableIdentity(manifest)
        }
        return manifest
    }

    public static func currentProcessIdentity() throws -> DebugProcessIdentity {
        try processIdentity(processIdentifier: getpid())
    }

    public static func validateLiveExecutableIdentity(_ manifest: DebugSessionManifest) throws {
        let observed: DebugProcessIdentity
        do {
            observed = try processIdentity(processIdentifier: manifest.process.processIdentifier)
        } catch {
            throw DebugProtocolError.invalidManifest(.processNotRunning)
        }
        guard observed == manifest.process else {
            throw DebugProtocolError.invalidManifest(.invalidProcessIdentity)
        }
        let digest = try executableSHA256(at: URL(fileURLWithPath: observed.executablePath))
        guard digest == manifest.executableSHA256 else {
            throw DebugProtocolError.invalidManifest(.executableHashMismatch)
        }
        guard (try? processIdentity(processIdentifier: manifest.process.processIdentifier)) == observed else {
            throw DebugProtocolError.invalidManifest(.processNotRunning)
        }
    }

    public static func executableSHA256(at executableURL: URL) throws -> String {
        guard executableURL.isFileURL else {
            throw DebugProtocolError.invalidManifest(.executableMismatch)
        }
        let canonical = try canonicalPath(executableURL.path)
        let descriptor = open(canonical, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw DebugProtocolError.invalidManifest(.executableMismatch)
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw DebugProtocolError.invalidManifest(.executableMismatch)
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                hasher.update(data: Data(buffer.prefix(count)))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw DebugProtocolError.fileSystemFailure("hash read")
            }
        }
        return Data(hasher.finalize()).map { String(format: "%02x", $0) }.joined()
    }

    private static func processIdentity(processIdentifier: pid_t) throws -> DebugProcessIdentity {
        guard processIdentifier > 0 else {
            throw DebugProtocolError.invalidManifest(.invalidProcessIdentity)
        }
        var info = proc_bsdinfo()
        let infoSize = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(infoSize)
        ) == infoSize else {
            throw DebugProtocolError.invalidManifest(.processNotRunning)
        }
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count)) > 0 else {
            throw DebugProtocolError.invalidManifest(.processNotRunning)
        }
        let terminator = pathBuffer.firstIndex(of: 0) ?? pathBuffer.endIndex
        let pathBytes = pathBuffer[..<terminator].map { UInt8(bitPattern: $0) }
        let executablePath = try canonicalPath(String(decoding: pathBytes, as: UTF8.self))
        var status = stat()
        guard lstat(executablePath, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw DebugProtocolError.invalidManifest(.executableMismatch)
        }
        return DebugProcessIdentity(
            processIdentifier: processIdentifier,
            startSeconds: UInt64(info.pbi_start_tvsec),
            startMicroseconds: UInt64(info.pbi_start_tvusec),
            executablePath: executablePath,
            executableDevice: UInt64(truncatingIfNeeded: status.st_dev),
            executableInode: UInt64(truncatingIfNeeded: status.st_ino)
        )
    }

    private static func validateAmbientDirectory(_ url: URL, matches expected: stat) throws {
        var observed = stat()
        guard lstat(url.path, &observed) == 0,
              (observed.st_mode & S_IFMT) == S_IFDIR,
              observed.st_dev == expected.st_dev,
              observed.st_ino == expected.st_ino,
              observed.st_uid == expected.st_uid,
              observed.st_mode == expected.st_mode else {
            throw DebugProtocolError.invalidManifest(.directoryReplaced)
        }
    }

    private static func readBounded(_ descriptor: Int32, maximumBytes: Int) throws -> Data {
        var result = Data()
        result.reserveCapacity(maximumBytes)
        var buffer = [UInt8](repeating: 0, count: 4 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard result.count <= maximumBytes - count else {
                    throw DebugProtocolError.invalidManifest(.fileTooLarge)
                }
                result.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return result
            } else if errno != EINTR {
                throw DebugProtocolError.invalidManifest(.readFailed)
            }
        }
    }

    private static func canonicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw DebugProtocolError.invalidManifest(.executableMismatch)
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func isCanonicalAbsolutePathShape(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"),
              path.utf8.count <= Int(MAXPATHLEN) * 4 else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { character in
            (character >= "0" && character <= "9") || (character >= "a" && character <= "f")
        }
    }

    private static func isValidBuildIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= 128 && bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
    }
}
