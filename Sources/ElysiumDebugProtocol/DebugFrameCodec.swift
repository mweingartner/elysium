import CryptoKit
import Foundation

public enum DebugFrameKind: UInt16, Codable, CaseIterable, Sendable {
    case clientHello = 1
    case serverHello = 2
    case request = 3
    case response = 4
    case event = 5
    case close = 6
}

/// Direction is authenticated but intentionally omitted from the on-wire header. Each
/// endpoint must explicitly construct its encoder and decoder for opposite directions.
public enum DebugFrameDirection: UInt8, Codable, Sendable {
    case clientToServer = 1
    case serverToClient = 2
}

public struct DebugFrameLimits: Codable, Equatable, Sendable {
    public static let absoluteMaximumPayloadBytes = 1_048_576
    public static let headerBytes = 20
    public static let authenticationTagBytes = 32
    public static let standard = DebugFrameLimits(
        uncheckedMaximumPayloadBytes: absoluteMaximumPayloadBytes
    )

    public let maximumPayloadBytes: Int

    public init(maximumPayloadBytes: Int = Self.absoluteMaximumPayloadBytes) throws {
        guard maximumPayloadBytes > 0,
              maximumPayloadBytes <= Self.absoluteMaximumPayloadBytes else {
            throw DebugProtocolError.payloadTooLarge(
                actual: maximumPayloadBytes,
                maximum: Self.absoluteMaximumPayloadBytes
            )
        }
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    public var maximumFrameBytes: Int {
        Self.headerBytes + maximumPayloadBytes + Self.authenticationTagBytes
    }

    private init(uncheckedMaximumPayloadBytes: Int) {
        self.maximumPayloadBytes = uncheckedMaximumPayloadBytes
    }

    private enum CodingKeys: String, CodingKey { case maximumPayloadBytes }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(maximumPayloadBytes: try container.decode(Int.self, forKey: .maximumPayloadBytes))
    }
}

public struct DebugDecodedFrame: Equatable, Sendable {
    public let kind: DebugFrameKind
    public let sequence: UInt64
    public let payload: Data

    public init(kind: DebugFrameKind, sequence: UInt64, payload: Data) {
        self.kind = kind
        self.sequence = sequence
        self.payload = payload
    }
}

/// Enforces exact monotonic delivery. Duplicate, replayed, skipped, and reordered
/// sequences are all rejected by the same small state machine.
public struct DebugSequenceValidator: Equatable, Sendable {
    public private(set) var expectedSequence: UInt64

    public init(expectedSequence: UInt64 = 1) throws {
        guard expectedSequence > 0, expectedSequence < UInt64.max else {
            throw DebugProtocolError.invalidSequence(expectedSequence)
        }
        self.expectedSequence = expectedSequence
    }

    public mutating func accept(_ sequence: UInt64) throws {
        guard expectedSequence < UInt64.max else {
            throw DebugProtocolError.sequenceExhausted
        }
        guard sequence == expectedSequence else {
            throw DebugProtocolError.unexpectedSequence(expected: expectedSequence, actual: sequence)
        }
        expectedSequence += 1
    }
}

public struct DebugAuthenticatedFrameEncoder {
    public private(set) var nextSequence: UInt64

    private let key: SymmetricKey
    private let direction: DebugFrameDirection
    private let limits: DebugFrameLimits
    private var transcriptDigest: Data

    public init(
        sessionKey: Data,
        direction: DebugFrameDirection,
        initialSequence: UInt64 = 1,
        limits: DebugFrameLimits = .standard
    ) throws {
        guard initialSequence > 0, initialSequence < UInt64.max else {
            throw DebugProtocolError.invalidSequence(initialSequence)
        }
        self.key = try debugDirectionalKey(sessionKey: sessionKey, direction: direction)
        self.direction = direction
        self.nextSequence = initialSequence
        self.limits = limits
        self.transcriptDigest = debugInitialTranscript(direction: direction)
    }

    public mutating func encode(kind: DebugFrameKind, payload: Data) throws -> Data {
        guard payload.count <= limits.maximumPayloadBytes else {
            throw DebugProtocolError.payloadTooLarge(
                actual: payload.count,
                maximum: limits.maximumPayloadBytes
            )
        }
        guard nextSequence < UInt64.max else {
            throw DebugProtocolError.sequenceExhausted
        }

        var frame = Data()
        frame.reserveCapacity(
            DebugFrameLimits.headerBytes + payload.count + DebugFrameLimits.authenticationTagBytes
        )
        debugAppendBigEndian(DebugFrameHeader.magic, to: &frame)
        debugAppendBigEndian(ElysiumDebugProtocolVersion.current, to: &frame)
        debugAppendBigEndian(kind.rawValue, to: &frame)
        debugAppendBigEndian(nextSequence, to: &frame)
        debugAppendBigEndian(UInt32(payload.count), to: &frame)
        frame.append(payload)

        let tag = HMAC<SHA256>.authenticationCode(
            for: debugAuthenticationInput(
                direction: direction,
                transcriptDigest: transcriptDigest,
                authenticatedBytes: frame
            ),
            using: key
        )
        frame.append(contentsOf: tag)
        transcriptDigest = debugNextTranscript(previous: transcriptDigest, frame: frame)
        nextSequence += 1
        return frame
    }
}

/// Incrementally authenticates a byte stream while retaining at most one bounded frame.
/// Any malformed header, authentication failure, or sequence violation poisons the decoder.
public struct DebugAuthenticatedFrameDecoder {
    public private(set) var isFailed = false
    public var pendingByteCount: Int { pending.count }
    public var expectedSequence: UInt64 { sequenceValidator.expectedSequence }

    private let key: SymmetricKey
    private let direction: DebugFrameDirection
    private let limits: DebugFrameLimits
    private var transcriptDigest: Data
    private var sequenceValidator: DebugSequenceValidator
    private var pending = Data()
    private var expectedFrameBytes: Int?

    public init(
        sessionKey: Data,
        direction: DebugFrameDirection,
        initialSequence: UInt64 = 1,
        limits: DebugFrameLimits = .standard
    ) throws {
        self.key = try debugDirectionalKey(sessionKey: sessionKey, direction: direction)
        self.direction = direction
        self.limits = limits
        self.transcriptDigest = debugInitialTranscript(direction: direction)
        self.sequenceValidator = try DebugSequenceValidator(expectedSequence: initialSequence)
    }

    public mutating func append(_ chunk: Data) throws -> [DebugDecodedFrame] {
        guard !isFailed else { throw DebugProtocolError.decoderFailed }
        do {
            return try appendValidated(chunk)
        } catch {
            isFailed = true
            pending.removeAll(keepingCapacity: false)
            expectedFrameBytes = nil
            throw error
        }
    }

    public mutating func finish() throws {
        guard !isFailed else { throw DebugProtocolError.decoderFailed }
        guard pending.isEmpty, expectedFrameBytes == nil else {
            let count = pending.count
            isFailed = true
            pending.removeAll(keepingCapacity: false)
            expectedFrameBytes = nil
            throw DebugProtocolError.truncatedFrame(pendingBytes: count)
        }
    }

    private mutating func appendValidated(_ chunk: Data) throws -> [DebugDecodedFrame] {
        var frames: [DebugDecodedFrame] = []
        var offset = 0

        while offset < chunk.count {
            if expectedFrameBytes == nil {
                let needed = DebugFrameLimits.headerBytes - pending.count
                let count = min(needed, chunk.count - offset)
                debugAppendSlice(chunk, offset: offset, count: count, to: &pending)
                offset += count
                if pending.count == DebugFrameLimits.headerBytes {
                    let header = try DebugFrameHeader.decode(pending)
                    guard header.sequence == sequenceValidator.expectedSequence else {
                        throw DebugProtocolError.unexpectedSequence(
                            expected: sequenceValidator.expectedSequence,
                            actual: header.sequence
                        )
                    }
                    guard header.payloadLength <= limits.maximumPayloadBytes else {
                        throw DebugProtocolError.payloadTooLarge(
                            actual: header.payloadLength,
                            maximum: limits.maximumPayloadBytes
                        )
                    }
                    expectedFrameBytes = DebugFrameLimits.headerBytes + header.payloadLength +
                        DebugFrameLimits.authenticationTagBytes
                }
            }

            if let expectedFrameBytes, pending.count < expectedFrameBytes, offset < chunk.count {
                let needed = expectedFrameBytes - pending.count
                let count = min(needed, chunk.count - offset)
                debugAppendSlice(chunk, offset: offset, count: count, to: &pending)
                offset += count
            }

            if let expectedFrameBytes, pending.count == expectedFrameBytes {
                frames.append(try authenticatePendingFrame())
                pending.removeAll(keepingCapacity: true)
                self.expectedFrameBytes = nil
            }
        }
        return frames
    }

    private mutating func authenticatePendingFrame() throws -> DebugDecodedFrame {
        let headerData = Data(pending.prefix(DebugFrameLimits.headerBytes))
        let header = try DebugFrameHeader.decode(headerData)
        let payloadStart = DebugFrameLimits.headerBytes
        let payloadEnd = payloadStart + header.payloadLength
        let payload = Data(pending[payloadStart..<payloadEnd])
        let tag = Data(pending.suffix(DebugFrameLimits.authenticationTagBytes))
        let authenticatedBytes = Data(pending.prefix(payloadEnd))
        let input = debugAuthenticationInput(
            direction: direction,
            transcriptDigest: transcriptDigest,
            authenticatedBytes: authenticatedBytes
        )
        guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: input, using: key) else {
            throw DebugProtocolError.authenticationFailed
        }
        try sequenceValidator.accept(header.sequence)
        transcriptDigest = debugNextTranscript(previous: transcriptDigest, frame: pending)
        return DebugDecodedFrame(kind: header.kind, sequence: header.sequence, payload: payload)
    }
}

private struct DebugFrameHeader {
    static let magic: UInt32 = 0x454C5944 // "ELYD"

    let kind: DebugFrameKind
    let sequence: UInt64
    let payloadLength: Int

    static func decode(_ data: Data) throws -> Self {
        guard data.count == DebugFrameLimits.headerBytes else {
            throw DebugProtocolError.invalidFrameLength(
                actual: data.count,
                expected: DebugFrameLimits.headerBytes
            )
        }
        var cursor = 0
        let magic: UInt32 = debugTakeBigEndian(data, cursor: &cursor)
        guard magic == Self.magic else { throw DebugProtocolError.invalidMagic(magic) }
        let version: UInt16 = debugTakeBigEndian(data, cursor: &cursor)
        guard version == ElysiumDebugProtocolVersion.current else {
            throw DebugProtocolError.unsupportedProtocolVersion(version)
        }
        let rawKind: UInt16 = debugTakeBigEndian(data, cursor: &cursor)
        guard let kind = DebugFrameKind(rawValue: rawKind) else {
            throw DebugProtocolError.unknownFrameKind(rawKind)
        }
        let sequence: UInt64 = debugTakeBigEndian(data, cursor: &cursor)
        guard sequence > 0 else { throw DebugProtocolError.invalidSequence(sequence) }
        let payloadLength: UInt32 = debugTakeBigEndian(data, cursor: &cursor)
        return Self(kind: kind, sequence: sequence, payloadLength: Int(payloadLength))
    }
}

private func debugDirectionalKey(
    sessionKey: Data,
    direction: DebugFrameDirection
) throws -> SymmetricKey {
    let minimumBytes = 32
    guard sessionKey.count >= minimumBytes else {
        throw DebugProtocolError.invalidSessionKeyLength(
            actual: sessionKey.count,
            minimum: minimumBytes
        )
    }
    return HKDF<SHA256>.deriveKey(
        inputKeyMaterial: SymmetricKey(data: sessionKey),
        salt: Data("ElysiumDebugProtocol/v1/HKDF".utf8),
        info: Data("direction/\(direction.rawValue)".utf8),
        outputByteCount: 32
    )
}

private func debugInitialTranscript(direction: DebugFrameDirection) -> Data {
    Data(SHA256.hash(data: Data("ElysiumDebugProtocol/v1/transcript/\(direction.rawValue)".utf8)))
}

private func debugAuthenticationInput(
    direction: DebugFrameDirection,
    transcriptDigest: Data,
    authenticatedBytes: Data
) -> Data {
    var input = Data([direction.rawValue])
    input.reserveCapacity(1 + transcriptDigest.count + authenticatedBytes.count)
    input.append(transcriptDigest)
    input.append(authenticatedBytes)
    return input
}

private func debugNextTranscript(previous: Data, frame: Data) -> Data {
    var input = Data()
    input.reserveCapacity(previous.count + frame.count)
    input.append(previous)
    input.append(frame)
    return Data(SHA256.hash(data: input))
}

private func debugAppendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var bigEndian = value.bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

private func debugTakeBigEndian<T: FixedWidthInteger>(_ data: Data, cursor: inout Int) -> T {
    let size = MemoryLayout<T>.size
    defer { cursor += size }
    return data[cursor..<(cursor + size)].reduce(T.zero) { ($0 << 8) | T($1) }
}

private func debugAppendSlice(_ source: Data, offset: Int, count: Int, to destination: inout Data) {
    guard count > 0 else { return }
    let start = source.index(source.startIndex, offsetBy: offset)
    let end = source.index(start, offsetBy: count)
    destination.append(contentsOf: source[start..<end])
}
