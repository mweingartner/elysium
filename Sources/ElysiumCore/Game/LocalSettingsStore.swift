import Darwin
import Foundation

public let LOCAL_SETTINGS_MAX_BYTES = 256 * 1024
public let LOCAL_KEYBINDS_MAX_BYTES = 16 * 1024

private func boundedUTF8String(_ source: String, maximumBytes: Int) -> String {
    let bytes = Array(source.utf8.prefix(maximumBytes))
    var end = bytes.count
    while end > 0 {
        if let value = String(bytes: bytes[..<end], encoding: .utf8) { return value }
        end -= 1
    }
    return ""
}

public enum LocalSettingsDocument: String, Equatable {
    case settings
    case keybinds
}

public enum LocalSettingsWriteStage: String, CaseIterable, Equatable {
    case temporaryCreate
    case write
    case fileSync
    case rename
    case directorySync
}

public enum LocalSettingsStoreError: Error, Equatable, CustomStringConvertible {
    case readFailed(LocalSettingsDocument, String)
    case documentTooLarge(LocalSettingsDocument, limit: Int)
    case invalidUTF8(LocalSettingsDocument)
    case invalidJSON(LocalSettingsDocument, String)
    case structuralLimit(LocalSettingsDocument, String)
    case invalidSettings(String)
    case invalidKeybinds(String)
    case encodeFailed(LocalSettingsDocument, String)
    case writeFailed(LocalSettingsDocument, LocalSettingsWriteStage, String)
    case staleLiveRevision(expected: UInt64, actual: UInt64)
    case revisionExhausted

    public var description: String {
        switch self {
        case let .readFailed(document, reason): return "Could not read \(document.rawValue): \(reason)"
        case let .documentTooLarge(document, limit): return "\(document.rawValue) exceeds \(limit) bytes"
        case let .invalidUTF8(document): return "\(document.rawValue) is not valid UTF-8"
        case let .invalidJSON(document, reason): return "Invalid \(document.rawValue) JSON: \(reason)"
        case let .structuralLimit(document, reason): return "\(document.rawValue) exceeds JSON limit: \(reason)"
        case let .invalidSettings(reason): return "Invalid settings: \(reason)"
        case let .invalidKeybinds(reason): return "Invalid keybinds: \(reason)"
        case let .encodeFailed(document, reason): return "Could not encode \(document.rawValue): \(reason)"
        case let .writeFailed(document, stage, reason):
            return "Could not persist \(document.rawValue) at \(stage.rawValue): \(reason)"
        case let .staleLiveRevision(expected, actual):
            return "Stale live revision \(expected); current revision is \(actual)"
        case .revisionExhausted: return "Live revision is exhausted"
        }
    }
}

public enum LocalSettingsCommitAwareWrite {
    case committed
    case rejected(LocalSettingsStoreError)
    case durabilityUncertain(Result<Settings, LocalSettingsStoreError>)
}

public struct LocalSettingsDiagnostic: Equatable {
    public let field: String
    public let reason: String

    public init(field: String, reason: String) {
        self.field = boundedUTF8String(field, maximumBytes: 128)
        self.reason = boundedUTF8String(reason, maximumBytes: 160)
    }
}

enum LocalSettingsIOError: Error {
    case operation(String, Int32)
    case notRegularFile
}

#if DEBUG
enum LocalSettingsSystemWriteCut: CaseIterable, Equatable {
    case partialWrite
    case completeWriteThenError
}

private enum LocalSettingsSystemWriteCutError: Error {
    case partialWrite
    case completeWriteThenError
}

private final class LocalSettingsSystemWriteCutBox {
    var value: LocalSettingsSystemWriteCut?
}
#endif

private struct SystemLocalSettingsFiles {
#if DEBUG
    private let currentSystemWriteCut: () -> LocalSettingsSystemWriteCut?
    init(currentSystemWriteCut: @escaping () -> LocalSettingsSystemWriteCut?) {
        self.currentSystemWriteCut = currentSystemWriteCut
    }
#else
    init() {}
#endif

    func read(directory: URL, name: String, maximumReadBytes: Int) throws -> Data? {
        let directoryFD = try openDirectory(directory, create: false)
        if directoryFD == -1 { return nil }
        defer { _ = Darwin.close(directoryFD) }

        let fd = Darwin.openat(directoryFD, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw LocalSettingsIOError.operation("open", errno)
        }
        defer { _ = Darwin.close(fd) }

        var status = stat()
        guard fstat(fd, &status) == 0 else { throw LocalSettingsIOError.operation("fstat", errno) }
        guard (status.st_mode & S_IFMT) == S_IFREG else { throw LocalSettingsIOError.notRegularFile }

        var result = Data()
        result.reserveCapacity(min(maximumReadBytes, max(0, Int(status.st_size))))
        var buffer = [UInt8](repeating: 0, count: min(16 * 1024, maximumReadBytes))
        while result.count < maximumReadBytes {
            let requested = min(buffer.count, maximumReadBytes - result.count)
            let count = buffer.withUnsafeMutableBytes { raw in
                Darwin.read(fd, raw.baseAddress, requested)
            }
            if count > 0 {
                result.append(buffer, count: count)
            } else if count == 0 {
                break
            } else if errno != EINTR {
                throw LocalSettingsIOError.operation("read", errno)
            }
        }
        return result
    }

    func atomicWrite(
        _ data: Data,
        directory: URL,
        name: String,
        before stage: (LocalSettingsWriteStage) throws -> Void
    ) throws {
        let directoryFD = try openDirectory(directory, create: true)
        defer { _ = Darwin.close(directoryFD) }

        try stage(.temporaryCreate)
        let temporaryName = ".\(name).\(UUID().uuidString).tmp"
        let fd = Darwin.openat(directoryFD, temporaryName,
                               O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LocalSettingsIOError.operation("temporary create", errno) }
        var fileOpen = true
        var renamed = false
        defer {
            if fileOpen { _ = Darwin.close(fd) }
            if !renamed { _ = Darwin.unlinkat(directoryFD, temporaryName, 0) }
        }

        try stage(.write)
#if DEBUG
        if currentSystemWriteCut() == .partialWrite {
            let partialCount = max(1, data.count / 2)
            try data.withUnsafeBytes { raw in
                var offset = 0
                while offset < partialCount {
                    let count = Darwin.write(
                        fd, raw.baseAddress!.advanced(by: offset), partialCount - offset)
                    if count > 0 { offset += count }
                    else if count < 0 && errno == EINTR { continue }
                    else { throw LocalSettingsIOError.operation("write", errno) }
                }
            }
            throw LocalSettingsSystemWriteCutError.partialWrite
        }
#endif
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    throw LocalSettingsIOError.operation("write", errno)
                }
            }
        }
#if DEBUG
        if currentSystemWriteCut() == .completeWriteThenError {
            throw LocalSettingsSystemWriteCutError.completeWriteThenError
        }
#endif

        try stage(.fileSync)
        while fsync(fd) != 0 {
            if errno == EINTR { continue }
            throw LocalSettingsIOError.operation("file sync", errno)
        }
        if Darwin.close(fd) != 0 {
            fileOpen = false
            throw LocalSettingsIOError.operation("close", errno)
        }
        fileOpen = false

        try stage(.rename)
        guard renameat(directoryFD, temporaryName, directoryFD, name) == 0 else {
            throw LocalSettingsIOError.operation("rename", errno)
        }
        renamed = true

        try stage(.directorySync)
        while fsync(directoryFD) != 0 {
            if errno == EINTR { continue }
            throw LocalSettingsIOError.operation("directory sync", errno)
        }
    }

    private func openDirectory(_ directory: URL, create: Bool) throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw LocalSettingsIOError.operation("invalid directory path", EINVAL)
        }
        let components = directory.pathComponents
        guard components.first == "/",
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw LocalSettingsIOError.operation("invalid directory path", EINVAL)
        }

        var current = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard current >= 0 else { throw LocalSettingsIOError.operation("open root directory", errno) }
        if components.count == 1 { return current }

        for component in components.dropFirst() {
            var next = Darwin.openat(current, component,
                                     O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            if next < 0, errno == ENOENT, create {
                if mkdirat(current, component, 0o700) != 0, errno != EEXIST {
                    let code = errno
                    _ = Darwin.close(current)
                    throw LocalSettingsIOError.operation("create directory component", code)
                }
                next = Darwin.openat(current, component,
                                     O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            if next < 0 {
                let code = errno
                _ = Darwin.close(current)
                if !create && code == ENOENT { return -1 }
                throw LocalSettingsIOError.operation("open directory component", code)
            }
            _ = Darwin.close(current)
            current = next
        }
        return current
    }
}

private enum BoundedJSONError: Error, CustomStringConvertible {
    case syntax(String)
    case limit(String)

    var description: String {
        switch self {
        case let .syntax(value), let .limit(value): return value
        }
    }
}

private struct BoundedJSONScanner {
    static let maximumDepth = 32
    static let maximumTokens = 2_048
    static let maximumObjectMembers = 512
    static let maximumArrayElements = 256
    static let maximumKeyBytes = 128
    static let maximumStringBytes = 8_192
    static let maximumNumberBytes = 128

    private let bytes: [UInt8]
    private var index = 0
    private var tokenCount = 0
    private var objectMemberCount = 0
    private var arrayElementCount = 0

    init(data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw BoundedJSONError.syntax("invalid UTF-8") }
        bytes = Array(data)
    }

    mutating func validateObjectRoot() throws {
        skipWhitespace()
        guard peek == 0x7b else { throw BoundedJSONError.syntax("root must be an object") }
        try parseObject(depth: 1)
        skipWhitespace()
        guard index == bytes.count else { throw BoundedJSONError.syntax("trailing data") }
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func consumeToken() throws {
        tokenCount += 1
        if tokenCount > Self.maximumTokens { throw BoundedJSONError.limit("more than 2048 tokens") }
    }

    private mutating func parseValue(depth: Int) throws {
        skipWhitespace()
        guard let byte = peek else { throw BoundedJSONError.syntax("missing value") }
        try consumeToken()
        switch byte {
        case 0x7b: try parseObject(depth: depth)
        case 0x5b: try parseArray(depth: depth)
        case 0x22: _ = try parseString(maximumBytes: Self.maximumStringBytes)
        case 0x74: try parseLiteral("true")
        case 0x66: try parseLiteral("false")
        case 0x6e: try parseLiteral("null")
        case 0x2d, 0x30...0x39: try parseNumber()
        default: throw BoundedJSONError.syntax("unexpected value token")
        }
    }

    private mutating func parseObject(depth: Int) throws {
        guard depth <= Self.maximumDepth else { throw BoundedJSONError.limit("nesting exceeds 32") }
        index += 1
        skipWhitespace()
        if peek == 0x7d { index += 1; return }
        while true {
            guard peek == 0x22 else { throw BoundedJSONError.syntax("object key must be a string") }
            try consumeToken()
            _ = try parseString(maximumBytes: Self.maximumKeyBytes)
            objectMemberCount += 1
            if objectMemberCount > Self.maximumObjectMembers {
                throw BoundedJSONError.limit("more than 512 object members")
            }
            skipWhitespace()
            guard peek == 0x3a else { throw BoundedJSONError.syntax("missing colon") }
            index += 1
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if peek == 0x7d { index += 1; return }
            guard peek == 0x2c else { throw BoundedJSONError.syntax("missing object delimiter") }
            index += 1
            skipWhitespace()
        }
    }

    private mutating func parseArray(depth: Int) throws {
        guard depth <= Self.maximumDepth else { throw BoundedJSONError.limit("nesting exceeds 32") }
        index += 1
        skipWhitespace()
        if peek == 0x5d { index += 1; return }
        while true {
            arrayElementCount += 1
            if arrayElementCount > Self.maximumArrayElements {
                throw BoundedJSONError.limit("more than 256 array elements")
            }
            try parseValue(depth: depth + 1)
            skipWhitespace()
            if peek == 0x5d { index += 1; return }
            guard peek == 0x2c else { throw BoundedJSONError.syntax("missing array delimiter") }
            index += 1
            skipWhitespace()
        }
    }

    private mutating func parseString(maximumBytes: Int) throws -> Int {
        guard peek == 0x22 else { throw BoundedJSONError.syntax("missing string") }
        index += 1
        var decodedBytes = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                return decodedBytes
            }
            if byte < 0x20 { throw BoundedJSONError.syntax("unescaped control in string") }
            if byte == 0x5c {
                index += 1
                guard let escape = peek else { throw BoundedJSONError.syntax("truncated escape") }
                if [0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(escape) {
                    index += 1
                    decodedBytes += 1
                } else if escape == 0x75 {
                    index += 1
                    let first = try parseHexQuad()
                    let scalar: UInt32
                    if (0xd800...0xdbff).contains(first) {
                        guard index + 1 < bytes.count, bytes[index] == 0x5c, bytes[index + 1] == 0x75 else {
                            throw BoundedJSONError.syntax("unpaired high surrogate")
                        }
                        index += 2
                        let second = try parseHexQuad()
                        guard (0xdc00...0xdfff).contains(second) else {
                            throw BoundedJSONError.syntax("invalid surrogate pair")
                        }
                        scalar = 0x10000 + ((first - 0xd800) << 10) + second - 0xdc00
                    } else {
                        guard !(0xdc00...0xdfff).contains(first) else {
                            throw BoundedJSONError.syntax("unpaired low surrogate")
                        }
                        scalar = first
                    }
                    decodedBytes += scalar <= 0x7f ? 1 : (scalar <= 0x7ff ? 2 : (scalar <= 0xffff ? 3 : 4))
                } else {
                    throw BoundedJSONError.syntax("invalid string escape")
                }
            } else {
                let width: Int
                switch byte {
                case 0x00...0x7f: width = 1
                case 0xc2...0xdf: width = 2
                case 0xe0...0xef: width = 3
                case 0xf0...0xf4: width = 4
                default: throw BoundedJSONError.syntax("invalid UTF-8 in string")
                }
                guard index + width <= bytes.count else { throw BoundedJSONError.syntax("truncated UTF-8") }
                index += width
                decodedBytes += width
            }
            if decodedBytes > maximumBytes {
                throw BoundedJSONError.limit("string exceeds \(maximumBytes) UTF-8 bytes")
            }
        }
        throw BoundedJSONError.syntax("unterminated string")
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw BoundedJSONError.syntax("truncated unicode escape") }
        var result: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte - 0x30)
            case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
            default: throw BoundedJSONError.syntax("invalid unicode escape")
            }
            result = result * 16 + digit
            index += 1
        }
        return result
    }

    private mutating func parseLiteral(_ literal: StaticString) throws {
        let expected = Array(String(describing: literal).utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw BoundedJSONError.syntax("invalid literal")
        }
        index += expected.count
    }

    private mutating func parseNumber() throws {
        let start = index
        if peek == 0x2d { index += 1 }
        guard let first = peek else { throw BoundedJSONError.syntax("truncated number") }
        if first == 0x30 {
            index += 1
            if let next = peek, (0x30...0x39).contains(next) {
                throw BoundedJSONError.syntax("leading zero in number")
            }
        } else if (0x31...0x39).contains(first) {
            repeat { index += 1 } while peek.map { (0x30...0x39).contains($0) } == true
        } else {
            throw BoundedJSONError.syntax("invalid number")
        }
        if peek == 0x2e {
            index += 1
            guard peek.map({ (0x30...0x39).contains($0) }) == true else {
                throw BoundedJSONError.syntax("fraction has no digits")
            }
            repeat { index += 1 } while peek.map { (0x30...0x39).contains($0) } == true
        }
        if peek == 0x65 || peek == 0x45 {
            index += 1
            if peek == 0x2b || peek == 0x2d { index += 1 }
            guard peek.map({ (0x30...0x39).contains($0) }) == true else {
                throw BoundedJSONError.syntax("exponent has no digits")
            }
            repeat { index += 1 } while peek.map { (0x30...0x39).contains($0) } == true
        }
        if index - start > Self.maximumNumberBytes {
            throw BoundedJSONError.limit("number token exceeds 128 bytes")
        }
    }

    private mutating func skipWhitespace() {
        while let byte = peek, byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d { index += 1 }
    }
}

public final class LocalSettingsStore {
#if DEBUG
    typealias FaultInjector = (LocalSettingsWriteStage) -> Error?
#endif

    let directoryURL: URL
#if DEBUG
    var faultInjector: FaultInjector?
    var encodeFaultInjector: ((LocalSettingsDocument) -> Error?)?
    var commitAwareCanonicalRereadOverride: (() -> Result<Data, LocalSettingsStoreError>)?
    private let systemWriteCutBox: LocalSettingsSystemWriteCutBox
    var systemWriteCut: LocalSettingsSystemWriteCut? {
        get { systemWriteCutBox.value }
        set { systemWriteCutBox.value = newValue }
    }
#endif

    private let io: SystemLocalSettingsFiles
    private let diagnosticLock = NSLock()
    private var storedDiagnostics: [LocalSettingsDiagnostic] = []

    public var lastDiagnostics: [LocalSettingsDiagnostic] {
        diagnosticLock.lock()
        defer { diagnosticLock.unlock() }
        return storedDiagnostics
    }

    public init() {
        directoryURL = Self.defaultDirectoryURL()
#if DEBUG
        let writeCutBox = LocalSettingsSystemWriteCutBox()
        systemWriteCutBox = writeCutBox
        faultInjector = nil
        encodeFaultInjector = nil
        commitAwareCanonicalRereadOverride = nil
        io = SystemLocalSettingsFiles(currentSystemWriteCut: { writeCutBox.value })
#else
        io = SystemLocalSettingsFiles()
#endif
    }

#if DEBUG
    init(directoryURL: URL, faultInjector: FaultInjector? = nil) {
        self.directoryURL = directoryURL
        let writeCutBox = LocalSettingsSystemWriteCutBox()
        systemWriteCutBox = writeCutBox
        self.faultInjector = faultInjector
        encodeFaultInjector = nil
        commitAwareCanonicalRereadOverride = nil
        io = SystemLocalSettingsFiles(currentSystemWriteCut: { writeCutBox.value })
    }
#endif

    public func loadSettings() -> Result<Settings, LocalSettingsStoreError> {
        setDiagnostics([])
        switch readDocument(.settings, name: "settings.json", cap: LOCAL_SETTINGS_MAX_BYTES) {
        case let .failure(error): return .failure(error)
        case .success(nil): return .success(sanitizedSettings(Settings()))
        case let .success(.some(data)):
            do {
                let object = try decodeObject(data, document: .settings)
                var value = Settings()
                var diagnostics: [LocalSettingsDiagnostic] = []
                decodeField("renderDistance", from: object, into: &value.renderDistance, diagnostics: &diagnostics)
                decodeField("fov", from: object, into: &value.fov, diagnostics: &diagnostics)
                decodeField("fancyGraphics", from: object, into: &value.fancyGraphics, diagnostics: &diagnostics)
                decodeField("smoothLighting", from: object, into: &value.smoothLighting, diagnostics: &diagnostics)
                decodeField("bloom", from: object, into: &value.bloom, diagnostics: &diagnostics)
                decodeField("shadows", from: object, into: &value.shadows, diagnostics: &diagnostics)
                decodeField("clouds", from: object, into: &value.clouds, diagnostics: &diagnostics)
                decodeField("particles", from: object, into: &value.particles, diagnostics: &diagnostics)
                decodeField("gamma", from: object, into: &value.gamma, diagnostics: &diagnostics)
                decodeField("viewBobbing", from: object, into: &value.viewBobbing, diagnostics: &diagnostics)
                decodeField("guiScale", from: object, into: &value.guiScale, diagnostics: &diagnostics)
                decodeField("maxFps", from: object, into: &value.maxFps, diagnostics: &diagnostics)
                decodeField("entityDistance", from: object, into: &value.entityDistance, diagnostics: &diagnostics)
                decodeField("volumes", from: object, into: &value.volumes, diagnostics: &diagnostics)
                decodeField("sensitivity", from: object, into: &value.sensitivity, diagnostics: &diagnostics)
                decodeField("invertY", from: object, into: &value.invertY, diagnostics: &diagnostics)
                decodeField("subtitles", from: object, into: &value.subtitles, diagnostics: &diagnostics)
                decodeField("autoJump", from: object, into: &value.autoJump, diagnostics: &diagnostics)
                decodeField("reduceMotion", from: object, into: &value.reduceMotion, diagnostics: &diagnostics)
                decodeField("reducedFlashes", from: object, into: &value.reducedFlashes, diagnostics: &diagnostics)
                decodeField("highContrast", from: object, into: &value.highContrast, diagnostics: &diagnostics)
                decodeField("darknessPulse", from: object, into: &value.darknessPulse, diagnostics: &diagnostics)
                decodeField("simpleMesh", from: object, into: &value.simpleMesh, diagnostics: &diagnostics)
                decodeOptionalField("resourcePacks", from: object, into: &value.resourcePacks, diagnostics: &diagnostics)
                decodeOptionalField("bundledResourcePackAddOns", from: object,
                                    into: &value.bundledResourcePackAddOns, diagnostics: &diagnostics)
                decodeOptionalField("shader", from: object, into: &value.shader, diagnostics: &diagnostics)
                decodeField("aiOllamaModel", from: object, into: &value.aiOllamaModel, diagnostics: &diagnostics)
                decodeOptionalField("rpgTutorialVersion", from: object, into: &value.rpgTutorialVersion, diagnostics: &diagnostics)
                setDiagnostics(diagnostics)
                return .success(sanitizedSettings(value))
            } catch let error as LocalSettingsStoreError {
                return .failure(error)
            } catch {
                return .failure(.invalidJSON(.settings, boundedReason(error)))
            }
        }
    }

    public func persistSettings(_ candidate: Settings) -> Result<Void, LocalSettingsStoreError> {
        encodeAndPersist(sanitizedSettings(candidate), document: .settings,
                         name: "settings.json", cap: LOCAL_SETTINGS_MAX_BYTES)
    }

    /// The byte identity used at the post-rename uncertainty boundary. This is
    /// deliberately the same sorted-key encoding written by `persistSettings`.
    func canonicalSettingsDocument(_ candidate: Settings) -> Result<Data, LocalSettingsStoreError> {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(sanitizedSettings(candidate))
            guard data.count <= LOCAL_SETTINGS_MAX_BYTES else {
                return .failure(.documentTooLarge(.settings, limit: LOCAL_SETTINGS_MAX_BYTES))
            }
            return .success(data)
        } catch {
            return .failure(.encodeFailed(.settings, boundedReason(error)))
        }
    }

    private func readSettingsDocumentBytes() -> Result<Data, LocalSettingsStoreError> {
        switch readDocument(.settings, name: "settings.json", cap: LOCAL_SETTINGS_MAX_BYTES) {
        case .failure(let error):
            return .failure(error)
        case .success(nil):
            return .failure(.readFailed(.settings, "document missing after rename"))
        case .success(.some(let data)):
            return .success(data)
        }
    }

    /// Directory fsync happens after rename, so its failure cannot honestly be
    /// reported as an unchanged document. Re-read the canonical bounded file.
    public func persistSettingsCommitAware(_ candidate: Settings) -> LocalSettingsCommitAwareWrite {
        let canonicalCandidate = sanitizedSettings(candidate)
        let prior = loadSettings()
        let priorDocument = prior.flatMap(canonicalSettingsDocument)
        let candidateDocument = canonicalSettingsDocument(canonicalCandidate)
        switch persistSettings(canonicalCandidate) {
        case .success:
            return .committed
        case .failure(let error):
            if case .writeFailed(.settings, .directorySync, _) = error {
                let reread: Result<Data, LocalSettingsStoreError>
#if DEBUG
                if let override = commitAwareCanonicalRereadOverride {
                    reread = override()
                } else {
                    reread = readSettingsDocumentBytes()
                }
#else
                reread = readSettingsDocumentBytes()
#endif
                switch reread {
                case .failure(let rereadError):
                    return .durabilityUncertain(.failure(rereadError))
                case .success(let observed):
                    if case .success(let expectedCandidate) = candidateDocument,
                       observed == expectedCandidate {
                        return .durabilityUncertain(.success(canonicalCandidate))
                    }
                    if case .success(let expectedPrior) = priorDocument,
                       case .success(let priorSettings) = prior,
                       observed == expectedPrior {
                        return .durabilityUncertain(.success(priorSettings))
                    }
                    return .durabilityUncertain(.failure(.invalidJSON(
                        .settings, "canonical document identity mismatch after rename")))
                }
            }
            return .rejected(error)
        }
    }

    public func loadKeybinds() -> Result<[String: String], LocalSettingsStoreError> {
        setDiagnostics([])
        let defaults = rpgDefaultChordBindings()
        switch readDocument(.keybinds, name: "keybinds.json", cap: LOCAL_KEYBINDS_MAX_BYTES) {
        case let .failure(error): return .failure(error)
        case .success(nil): return .success(defaults)
        case let .success(.some(data)):
            do {
                let object = try decodeObject(data, document: .keybinds)
                var result = defaults
                var diagnostics: [LocalSettingsDiagnostic] = []
                for definition in KEYBIND_DEFINITIONS {
                    guard let rawValue = object[definition.actionID] else { continue }
                    guard let raw = rawValue as? String, raw.utf8.count <= 64,
                          let chord = try? ElysiumKeyChord(parsing: raw),
                          !isProtectedAppChord(chord) else {
                        appendDiagnostic(field: definition.actionID, reason: "invalid chord", to: &diagnostics)
                        continue
                    }
                    result[definition.actionID] = chord.description
                }
                setDiagnostics(diagnostics)
                return .success(result)
            } catch let error as LocalSettingsStoreError {
                return .failure(error)
            } catch {
                return .failure(.invalidJSON(.keybinds, boundedReason(error)))
            }
        }
    }

    public func persistKeybinds(_ candidate: [String: String]) -> Result<Void, LocalSettingsStoreError> {
        let expected = KEYBIND_DEFINITIONS.map(\.actionID)
        guard candidate.count == expected.count, Set(candidate.keys) == Set(expected) else {
            return .failure(.invalidKeybinds("candidate must contain exactly the 25 known actions"))
        }
        guard Set(KEYBIND_DEFINITIONS.map { commandIdentity($0.command) }).count == KEYBIND_DEFINITIONS.count else {
            return .failure(.invalidKeybinds("duplicate semantic command definitions"))
        }
        var canonical: [String: String] = [:]
        for actionID in expected {
            guard let raw = candidate[actionID], raw.utf8.count <= 64,
                  let chord = try? ElysiumKeyChord(parsing: raw), !isProtectedAppChord(chord),
                  chord.description == raw else {
                return .failure(.invalidKeybinds("\(actionID) has a noncanonical or protected chord"))
            }
            canonical[actionID] = chord.description
        }
        return encodeAndPersist(canonical, document: .keybinds,
                                name: "keybinds.json", cap: LOCAL_KEYBINDS_MAX_BYTES)
    }

    private func readDocument(_ document: LocalSettingsDocument, name: String, cap: Int)
        -> Result<Data?, LocalSettingsStoreError> {
        do {
            let data = try io.read(directory: directoryURL, name: name, maximumReadBytes: cap + 1)
            if let data, data.count > cap { return .failure(.documentTooLarge(document, limit: cap)) }
            return .success(data)
        } catch {
            return .failure(.readFailed(document, boundedReason(error)))
        }
    }

    private func decodeObject(_ data: Data, document: LocalSettingsDocument) throws -> [String: Any] {
        guard String(data: data, encoding: .utf8) != nil else { throw LocalSettingsStoreError.invalidUTF8(document) }
        do {
            var scanner = try BoundedJSONScanner(data: data)
            try scanner.validateObjectRoot()
        } catch let error as BoundedJSONError {
            switch error {
            case let .limit(reason): throw LocalSettingsStoreError.structuralLimit(document, reason)
            case let .syntax(reason): throw LocalSettingsStoreError.invalidJSON(document, reason)
            }
        }
        do {
            let value = try JSONSerialization.jsonObject(with: data, options: [])
            guard let object = value as? [String: Any] else {
                throw LocalSettingsStoreError.invalidJSON(document, "root must be an object")
            }
            return object
        } catch let error as LocalSettingsStoreError {
            throw error
        } catch {
            throw LocalSettingsStoreError.invalidJSON(document, boundedReason(error))
        }
    }

    private func decodeField<T: Decodable>(_ name: String, from object: [String: Any], into target: inout T,
                                            diagnostics: inout [LocalSettingsDiagnostic]) {
        guard let raw = object[name] else { return }
        do {
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
            target = try JSONDecoder().decode(T.self, from: data)
        } catch {
            appendDiagnostic(field: name, reason: "invalid value", to: &diagnostics)
        }
    }

    private func decodeOptionalField<T: Decodable>(_ name: String, from object: [String: Any],
                                                    into target: inout T?,
                                                    diagnostics: inout [LocalSettingsDiagnostic]) {
        guard let raw = object[name] else { return }
        if raw is NSNull { target = nil; return }
        do {
            let data = try JSONSerialization.data(withJSONObject: raw, options: [.fragmentsAllowed])
            target = try JSONDecoder().decode(T.self, from: data)
        } catch {
            appendDiagnostic(field: name, reason: "invalid value", to: &diagnostics)
        }
    }

    private func encodeAndPersist<T: Encodable>(_ value: T, document: LocalSettingsDocument,
                                                 name: String, cap: Int)
        -> Result<Void, LocalSettingsStoreError> {
        let data: Data
        do {
#if DEBUG
            if let error = encodeFaultInjector?(document) { throw error }
#endif
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(value)
        } catch {
            return .failure(.encodeFailed(document, boundedReason(error)))
        }
        guard data.count <= cap else { return .failure(.documentTooLarge(document, limit: cap)) }
        do {
#if DEBUG
            try io.atomicWrite(data, directory: directoryURL, name: name) { stage in
                if self.faultInjector?(stage) != nil {
                    throw InjectedLocalSettingsFailure(stage: stage)
                }
            }
#else
            try io.atomicWrite(data, directory: directoryURL, name: name) { _ in }
#endif
            return .success(())
        } catch {
#if DEBUG
            let stage = (error as? InjectedLocalSettingsFailure)?.stage ?? inferredStage(from: error)
#else
            let stage = inferredStage(from: error)
#endif
            return .failure(.writeFailed(document, stage, boundedReason(error)))
        }
    }

    private func commandIdentity(_ command: ResolvedKeyCommand) -> String {
        switch command {
        case let .semantic(value): return "semantic:\(String(describing: value))"
        case let .binding(value): return "binding:\(value.rawValue)"
        case let .worldAction(value): return "world:\(value)"
        }
    }

    private func appendDiagnostic(field: String, reason: String,
                                  to diagnostics: inout [LocalSettingsDiagnostic]) {
        if diagnostics.count < 32 { diagnostics.append(LocalSettingsDiagnostic(field: field, reason: reason)) }
    }

    private func setDiagnostics(_ value: [LocalSettingsDiagnostic]) {
        diagnosticLock.lock()
        storedDiagnostics = Array(value.prefix(32))
        diagnosticLock.unlock()
    }

    private func inferredStage(from error: Error) -> LocalSettingsWriteStage {
        let reason = String(describing: error).lowercased()
        if reason.contains("directory sync") { return .directorySync }
        if reason.contains("rename") { return .rename }
        if reason.contains("file sync") || reason.contains("close") { return .fileSync }
        if reason.contains("write") { return .write }
        return .temporaryCreate
    }

    private func boundedReason(_ error: Error) -> String {
        boundedUTF8String(String(describing: error), maximumBytes: 160)
    }

    private static func defaultDirectoryURL() -> URL {
        _ = LegacyBrandMigration.runOnce // fold any former "Pebble" data across before first use
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Elysium", isDirectory: true)
    }
}

#if DEBUG
/// Test-only fault value that keeps stage attribution exact before a filesystem call.
struct InjectedLocalSettingsFailure: Error, Equatable {
    let stage: LocalSettingsWriteStage
    init(stage: LocalSettingsWriteStage) { self.stage = stage }
}
#endif
