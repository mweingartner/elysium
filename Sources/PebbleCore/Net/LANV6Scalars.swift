import CryptoKit
import Dispatch
import Foundation
import Security

public let LAN_V6_MAX_COUNTER: UInt32 = 1_000_000_000
public let LAN_V6_MAX_JOINED_ORDINAL: UInt32 = 1_000_000_000
public let LAN_V6_MAX_REQUEST_ID: UInt32 = 1_000_000_000

public enum LANV6ScalarError: Error, Equatable {
    case invalidByteCount(expected: Int, actual: Int)
    case invalidBase64URL
    case invalidHex
    case invalidAuthority
    case invalidDisplayName
    case invalidRegistryID
    case unknownRegistryID
    case invalidJoinCode
    case invalidRevision
    case invalidCounter
    case invalidEntropyCount
    case entropyProviderReturnedWrongByteCount(expected: Int, actual: Int)
    case entropyFailure(Int32)
    case sha256KnownAnswerFailed
}

enum LANV6CanonicalEncoding {
    static func encodeBase64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeBase64URL(_ value: String, expectedByteCount: Int) throws -> [UInt8] {
        let expectedCharacterCount = (expectedByteCount * 8 + 5) / 6
        guard value.utf8.count == expectedCharacterCount,
              value.utf8.allSatisfy(isBase64URLByte),
              value.utf8.count % 4 != 1
        else {
            throw LANV6ScalarError.invalidBase64URL
        }

        var standard = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        standard.append(String(repeating: "=", count: (4 - standard.utf8.count % 4) % 4))
        guard let decoded = Data(base64Encoded: standard),
              decoded.count == expectedByteCount
        else {
            throw LANV6ScalarError.invalidBase64URL
        }
        let bytes = [UInt8](decoded)
        guard encodeBase64URL(bytes) == value else {
            throw LANV6ScalarError.invalidBase64URL
        }
        return bytes
    }

    static func encodeLowercaseHex(_ bytes: [UInt8]) -> String {
        let alphabet = Array("0123456789abcdef".utf8)
        var encoded = [UInt8]()
        encoded.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            encoded.append(alphabet[Int(byte >> 4)])
            encoded.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    static func decodeLowercaseHex(_ value: String, expectedByteCount: Int) throws -> [UInt8] {
        let input = [UInt8](value.utf8)
        guard input.count == expectedByteCount * 2 else {
            throw LANV6ScalarError.invalidHex
        }
        var bytes = [UInt8]()
        bytes.reserveCapacity(expectedByteCount)
        var index = 0
        while index < input.count {
            guard let high = hexNibble(input[index]), let low = hexNibble(input[index + 1]) else {
                throw LANV6ScalarError.invalidHex
            }
            bytes.append((high << 4) | low)
            index += 2
        }
        guard encodeLowercaseHex(bytes) == value else {
            throw LANV6ScalarError.invalidHex
        }
        return bytes
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) ||
            (byte >= 48 && byte <= 57) || byte == 45 || byte == 95
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        if byte >= 48 && byte <= 57 { return byte - 48 }
        if byte >= 97 && byte <= 102 { return byte - 87 }
        return nil
    }
}

public struct LANV6ID128: Hashable, Codable, CustomStringConvertible, Sendable {
    private let storage: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 16 else {
            throw LANV6ScalarError.invalidByteCount(expected: 16, actual: bytes.count)
        }
        storage = bytes
    }

    public init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    public init(base64URL: String) throws {
        storage = try LANV6CanonicalEncoding.decodeBase64URL(base64URL, expectedByteCount: 16)
    }

    public var bytes: [UInt8] { storage }
    public var data: Data { Data(storage) }
    public var base64URL: String { LANV6CanonicalEncoding.encodeBase64URL(storage) }
    public var description: String { base64URL }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(base64URL: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected a canonical 22-character LAN v6 base64url identifier"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64URL)
    }
}

public struct LANV6Token256: Hashable, Codable, CustomStringConvertible, Sendable {
    public static let redactedDescription = "<redacted LAN v6 token>"

    private let storage: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else {
            throw LANV6ScalarError.invalidByteCount(expected: 32, actual: bytes.count)
        }
        storage = bytes
    }

    public init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    public init(base64URL: String) throws {
        storage = try LANV6CanonicalEncoding.decodeBase64URL(base64URL, expectedByteCount: 32)
    }

    public var bytes: [UInt8] { storage }
    public var data: Data { Data(storage) }
    public var base64URL: String { LANV6CanonicalEncoding.encodeBase64URL(storage) }
    public var description: String { Self.redactedDescription }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(base64URL: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected a canonical 43-character LAN v6 base64url token"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64URL)
    }
}

public struct LANV6SHA256Digest: Hashable, Codable, CustomStringConvertible, Sendable {
    private let storage: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 32 else {
            throw LANV6ScalarError.invalidByteCount(expected: 32, actual: bytes.count)
        }
        storage = bytes
    }

    public init(data: Data) throws {
        try self.init(bytes: [UInt8](data))
    }

    public init(hex: String) throws {
        storage = try LANV6CanonicalEncoding.decodeLowercaseHex(hex, expectedByteCount: 32)
    }

    fileprivate init(validatedSHA256Bytes: [UInt8]) {
        storage = validatedSHA256Bytes
    }

    public var bytes: [UInt8] { storage }
    public var data: Data { Data(storage) }
    public var hex: String { LANV6CanonicalEncoding.encodeLowercaseHex(storage) }
    public var description: String { hex }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(hex: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected a canonical 64-character lowercase LAN v6 SHA-256 digest"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

public typealias LANHostInstallationIDV6 = LANV6ID128
public typealias LANWorldIDV6 = LANV6ID128
public typealias LANWorldStorageIDV6 = LANV6ID128
public typealias LANMutationLineageIDV6 = LANV6ID128
public typealias LANSessionEpochV6 = LANV6ID128
public typealias LANHandshakeIDV6 = LANV6ID128
public typealias LANSnapshotIDV6 = LANV6ID128
public typealias LANDescriptorIDV6 = LANV6ID128
public typealias LANResumeTokenV6 = LANV6Token256

public struct LANV6Authority: Hashable, Codable, CustomStringConvertible, Sendable {
    private enum Storage: Hashable, Sendable {
        case hostLocal
        case guest(joinedOrdinal: UInt32)
    }

    private let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    public static let hostLocal = LANV6Authority(storage: .hostLocal)

    public static func guest(joinedOrdinal: UInt32) throws -> LANV6Authority {
        guard joinedOrdinal >= 1,
              joinedOrdinal <= LAN_V6_MAX_JOINED_ORDINAL
        else { throw LANV6ScalarError.invalidAuthority }
        return LANV6Authority(storage: .guest(joinedOrdinal: joinedOrdinal))
    }

    public var joinedOrdinal: UInt32? {
        guard case .guest(let joinedOrdinal) = storage else { return nil }
        return joinedOrdinal
    }

    public var isHostLocal: Bool { storage == .hostLocal }

    public init(_ value: String) throws {
        if value == "host:local" {
            storage = .hostLocal
            return
        }
        let prefix = "lan:"
        guard value.hasPrefix(prefix),
              let ordinal = LANV6Decimal.parseCanonical(value.dropFirst(prefix.count)),
              ordinal >= 1,
              ordinal <= UInt64(LAN_V6_MAX_JOINED_ORDINAL)
        else {
            throw LANV6ScalarError.invalidAuthority
        }
        storage = .guest(joinedOrdinal: UInt32(ordinal))
    }

    public var description: String {
        switch storage {
        case .hostLocal: return "host:local"
        case .guest(let ordinal): return "lan:\(ordinal)"
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected host:local or canonical lan:<joinedOrdinal>"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct LANV6DisplayName: Hashable, Codable, CustomStringConvertible, Sendable {
    public let value: String

    public init(_ value: String) throws {
        let scalars = value.unicodeScalars
        guard scalars.count >= 1,
              scalars.count <= 32,
              value.utf8.count <= 128,
              scalars.allSatisfy(LANV6DisplayName.isAllowedScalar)
        else {
            throw LANV6ScalarError.invalidDisplayName
        }
        self.value = value
    }

    public var description: String { value }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected a single-line LAN v6 display name"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func isAllowedScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator:
            return false
        default:
            return true
        }
    }
}

public struct LANV6RegistryID: Hashable, CustomStringConvertible, Sendable {
    public let value: String

    public init(_ value: String, allowedIDs: Set<String>) throws {
        guard Self.isShapeValid(value) else { throw LANV6ScalarError.invalidRegistryID }
        guard allowedIDs.contains(value) else { throw LANV6ScalarError.unknownRegistryID }
        self.value = value
    }

    public static func isShapeValid(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64
    }

    public var description: String { value }

}

public struct LANV6JoinCode: Hashable, Codable, CustomStringConvertible, Sendable {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
    public static let redactedDescription = "<redacted LAN v6 join code>"
    public let value: String

    public init(_ value: String) throws {
        let bytes = [UInt8](value.utf8)
        guard bytes.count >= 4,
              bytes.count <= 8,
              bytes.allSatisfy({ byte in
                  (byte >= 65 && byte <= 90) || (byte >= 48 && byte <= 57)
              })
        else {
            throw LANV6ScalarError.invalidJoinCode
        }
        self.value = value
    }

    public static func generate(length: Int = 6) throws -> LANV6JoinCode {
        try generate(length: length, using: LANV6SystemEntropySource())
    }

    static func generate(length: Int, using source: LANV6EntropySource) throws -> LANV6JoinCode {
        guard length >= 4 && length <= 8 else { throw LANV6ScalarError.invalidJoinCode }
        var output = [UInt8]()
        output.reserveCapacity(length)
        while output.count < length {
            let random = try source.bytes(count: 1)
            guard random.count == 1 else {
                throw LANV6ScalarError.entropyProviderReturnedWrongByteCount(
                    expected: 1,
                    actual: random.count
                )
            }
            let byte = random[0]
            guard byte < 252 else { continue }
            output.append(alphabet[Int(byte % 36)])
        }
        return try LANV6JoinCode(String(decoding: output, as: UTF8.self))
    }

    public var serialized: String { value }
    public var description: String { Self.redactedDescription }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        do {
            try self.init(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Expected [A-Z0-9]{4,8}"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct LANV6RevisionV1: Hashable, Codable, Comparable, Sendable {
    public let value: UInt32

    public init(_ value: UInt32) throws {
        guard value <= LAN_V6_MAX_COUNTER else { throw LANV6ScalarError.invalidRevision }
        self.value = value
    }

    public static func < (lhs: LANV6RevisionV1, rhs: LANV6RevisionV1) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(UInt32.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid LAN v6 revision"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct LANVersionedCounterV1: Hashable, Codable, Comparable, Sendable {
    public let generation: UInt32
    public let value: UInt32

    public init(generation: UInt32, value: UInt32) throws {
        guard generation <= LAN_V6_MAX_COUNTER,
              value <= LAN_V6_MAX_COUNTER,
              generation != LAN_V6_MAX_COUNTER || value == 0
        else {
            throw LANV6ScalarError.invalidCounter
        }
        self.generation = generation
        self.value = value
    }

    public static let zero = LANVersionedCounterV1(validatedGeneration: 0, value: 0)
    public static let terminal = LANVersionedCounterV1(
        validatedGeneration: LAN_V6_MAX_COUNTER,
        value: 0
    )

    public var isTerminal: Bool { generation == LAN_V6_MAX_COUNTER }

    public func checkedSuccessor() -> LANVersionedCounterV1? {
        if isTerminal { return nil }
        if value < LAN_V6_MAX_COUNTER {
            return LANVersionedCounterV1(validatedGeneration: generation, value: value + 1)
        }
        if generation < LAN_V6_MAX_COUNTER - 1 {
            return LANVersionedCounterV1(validatedGeneration: generation + 1, value: 0)
        }
        return .terminal
    }

    public static func < (lhs: LANVersionedCounterV1, rhs: LANVersionedCounterV1) -> Bool {
        if lhs.generation != rhs.generation { return lhs.generation < rhs.generation }
        return lhs.value < rhs.value
    }

    private init(validatedGeneration: UInt32, value: UInt32) {
        generation = validatedGeneration
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case generation
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let generation = try container.decode(UInt32.self, forKey: .generation)
        let value = try container.decode(UInt32.self, forKey: .value)
        do {
            try self.init(generation: generation, value: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .generation,
                in: container,
                debugDescription: "Invalid LAN v6 versioned counter"
            )
        }
    }
}

public enum LANV6ScalarValidator {
    public static func isRevision(_ value: Int64) -> Bool {
        value >= 0 && value <= Int64(LAN_V6_MAX_COUNTER)
    }

    public static func isRequestID(_ value: Int64) -> Bool {
        value >= 1 && value <= Int64(LAN_V6_MAX_REQUEST_ID)
    }

    public static func isNextExpectedRequestID(_ value: Int64) -> Bool {
        value >= 1 && value <= Int64(LAN_V6_MAX_REQUEST_ID) + 1
    }

    public static func isJoinedOrdinal(_ value: Int64) -> Bool {
        value >= 1 && value <= Int64(LAN_V6_MAX_JOINED_ORDINAL)
    }
}

protocol LANV6EntropySource {
    func bytes(count: Int) throws -> [UInt8]
}

private struct LANV6SystemEntropySource: LANV6EntropySource {
    func bytes(count: Int) throws -> [UInt8] {
        guard count >= 0 else { throw LANV6ScalarError.invalidEntropyCount }
        if count == 0 { return [] }
        var output = [UInt8](repeating: 0, count: count)
        let status = output.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw LANV6ScalarError.entropyFailure(Int32(status))
        }
        return output
    }
}

public enum LANV6Crypto {
    public static func randomBytes(count: Int) throws -> [UInt8] {
        try randomBytes(count: count, using: LANV6SystemEntropySource())
    }

    public static func randomID128() throws -> LANV6ID128 {
        try randomID128(using: LANV6SystemEntropySource())
    }

    public static func randomToken256() throws -> LANV6Token256 {
        try randomToken256(using: LANV6SystemEntropySource())
    }

    static func randomBytes(count: Int, using source: LANV6EntropySource) throws -> [UInt8] {
        guard count >= 0 else { throw LANV6ScalarError.invalidEntropyCount }
        let output = try source.bytes(count: count)
        guard output.count == count else {
            throw LANV6ScalarError.entropyProviderReturnedWrongByteCount(
                expected: count,
                actual: output.count
            )
        }
        return output
    }

    static func randomID128(using source: LANV6EntropySource) throws -> LANV6ID128 {
        try LANV6ID128(bytes: randomBytes(count: 16, using: source))
    }

    static func randomToken256(using source: LANV6EntropySource) throws -> LANV6Token256 {
        try LANV6Token256(bytes: randomBytes(count: 32, using: source))
    }

    public static func sha256(_ data: Data) -> LANV6SHA256Digest {
        LANV6SHA256Digest(validatedSHA256Bytes: Array(SHA256.hash(data: data)))
    }

    public static func lookupDigest(
        hostInstallationID: LANHostInstallationIDV6,
        worldLANID: LANWorldIDV6
    ) -> LANV6SHA256Digest {
        var data = Data("Pebble-LAN-v6".utf8)
        data.append(hostInstallationID.data)
        data.append(worldLANID.data)
        return sha256(data)
    }

    public static func sha256KnownAnswerSelfCheck() -> Bool {
        sha256(Data("abc".utf8)).hex ==
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    }

    public static func requireSHA256KnownAnswerSelfCheck() throws {
        guard sha256KnownAnswerSelfCheck() else {
            throw LANV6ScalarError.sha256KnownAnswerFailed
        }
    }

    @inline(never)
    public static func constantTimeEqual32(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == 32, rhs.count == 32 else { return false }
        let left = [UInt8](lhs)
        let right = [UInt8](rhs)
        var difference: UInt8 = 0
        for index in 0..<32 {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    public static func constantTimeEqual(_ lhs: LANV6Token256, _ rhs: LANV6Token256) -> Bool {
        constantTimeEqual32(lhs.data, rhs.data)
    }

    public static func constantTimeEqual(
        _ lhs: LANV6SHA256Digest,
        _ rhs: LANV6SHA256Digest
    ) -> Bool {
        constantTimeEqual32(lhs.data, rhs.data)
    }
}

public protocol LANV6WallClock {
    func nowMillisecondsSince1970() -> Int64
}

public protocol LANV6MonotonicClock {
    func nowNanoseconds() -> UInt64
}

public struct LANV6SystemWallClock: LANV6WallClock, Sendable {
    public init() {}

    public func nowMillisecondsSince1970() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

public struct LANV6SystemMonotonicClock: LANV6MonotonicClock, Sendable {
    public init() {}

    public func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}

enum LANV6Decimal {
    static func parseCanonical<S: StringProtocol>(_ value: S) -> UInt64? {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty,
              !(bytes.count > 1 && bytes[0] == 48),
              bytes.allSatisfy({ $0 >= 48 && $0 <= 57 })
        else {
            return nil
        }
        var result: UInt64 = 0
        for byte in bytes {
            let digit = UInt64(byte - 48)
            guard result <= (UInt64.max - digit) / 10 else { return nil }
            result = result * 10 + digit
        }
        return result
    }
}
