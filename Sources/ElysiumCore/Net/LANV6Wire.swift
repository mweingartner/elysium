import Foundation

public let LAN_V6_PROTOCOL_VERSION: UInt16 = 6
public let LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT = 1_048_576
public let LAN_V6_NON_REPLICATION_PAYLOAD_LIMIT = 65_536
public let LAN_V6_OWNER_CHUNK_PAYLOAD_LIMIT = 45_000
public let LAN_V6_MAX_FEED_FRAMES = 32
public let LAN_V6_MAX_FEED_FRAMED_BYTES = 2_097_184

private let LANV6FrameMagic: [UInt8] = [0x50, 0x42, 0x4c, 0x4e] // PBLN

/// Parallel protocol-v6 manifest. The live protocol-v5 enum remains untouched
/// until the transport cutover has its own reviewed state machine.
public enum LANV6MessageKind: UInt16, CaseIterable, Codable, Equatable, Hashable {
    case clientHello = 1
    case serverAccept = 2
    case serverReject = 3
    case chat = 4
    case playerState = 5
    case worldSummary = 6
    case ping = 7
    case pong = 8
    case disconnect = 9
    case inputIntent = 10
    case blockIntent = 11
    case containerIntent = 12
    case templateIntent = 13
    case replicationBatch = 14
    case chunkRequest = 15
    case replicationAck = 16
    case gameplayEvent = 17
    case attackIntent = 18
    case tossIntent = 19
    case containerEditIntent = 20
    case inventoryUpdate = 21
    case inventoryGrant = 22
    case restoreState = 23
    case damageEvent = 24
    case keepalive = 25
    case rpgIntent = 26
    case ownerManifest = 27
    case ownerChunk = 28
    case clientReady = 29

    public var payloadLimit: Int {
        switch self {
        case .replicationBatch: return LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT
        case .ownerChunk: return LAN_V6_OWNER_CHUNK_PAYLOAD_LIMIT
        default: return LAN_V6_NON_REPLICATION_PAYLOAD_LIMIT
        }
    }
}

public enum LANV6LocalRole: String, CaseIterable, Equatable, Hashable {
    case host
    case client
}

/// Closed union of the host and client protocol phases. Role/phase consistency
/// belongs to the caller-supplied admission table, not to the raw wire codec.
public enum LANV6ConnectionPhase: String, CaseIterable, Equatable, Hashable {
    case awaitingHello
    case awaitingClientReady
    case readyAwaitingOwnerBudget
    case authenticated
    case closing
    case connecting
    case awaitingServerAccept
    case awaitingInitialOwner
    case connected
    case rejected
}

public enum LANV6FrameFlow: String, CaseIterable, Equatable, Hashable {
    case inbound
    case outbound
}

public struct LANV6FrameAdmissionKey: Equatable, Hashable {
    public var localRole: LANV6LocalRole
    public var phase: LANV6ConnectionPhase
    public var flow: LANV6FrameFlow
    public var kind: LANV6MessageKind

    public init(localRole: LANV6LocalRole, phase: LANV6ConnectionPhase,
                flow: LANV6FrameFlow, kind: LANV6MessageKind) {
        self.localRole = localRole
        self.phase = phase
        self.flow = flow
        self.kind = kind
    }
}

/// Explicit fail-closed lookup supplied by the transport state machine. There
/// is intentionally no allow-all/default policy in production code.
public struct LANV6FrameAdmissionPolicy {
    private let admitted: Set<LANV6FrameAdmissionKey>

    /// The only public foundation policy is fail-closed. Reviewed handshake
    /// phases add named policies; arbitrary tables stay module-internal so an
    /// app caller cannot accidentally ship an allow-all policy.
    public static let denyAll = LANV6FrameAdmissionPolicy([])

    init(_ admitted: Set<LANV6FrameAdmissionKey>) {
        self.admitted = admitted
    }

    init(_ admitted: [LANV6FrameAdmissionKey]) {
        self.admitted = Set(admitted)
    }

    public func admits(localRole: LANV6LocalRole, phase: LANV6ConnectionPhase,
                       flow: LANV6FrameFlow, kind: LANV6MessageKind) -> Bool {
        admitted.contains(LANV6FrameAdmissionKey(
            localRole: localRole, phase: phase, flow: flow, kind: kind
        ))
    }
}

public struct LANV6Frame: Equatable {
    public var sequence: UInt32
    public var kind: LANV6MessageKind
    public var rawPayload: Data

    public init(sequence: UInt32, kind: LANV6MessageKind, rawPayload: Data) {
        self.sequence = sequence
        self.kind = kind
        self.rawPayload = rawPayload
    }
}

/// One bounded prefix accepted from a caller-owned input buffer. The caller
/// retains `input.dropFirst(consumedInputByteCount)` unchanged and may resubmit
/// it after handling the emitted frames/rate limits. No input suffix is stored
/// by this value or by the stream decoder.
public struct LANV6FrameFeedResult: Equatable {
    public let frames: [LANV6Frame]
    public let consumedInputByteCount: Int
    public let unconsumedInputByteCount: Int
    public let framedByteCount: Int
    public let payloadByteCount: Int

    init(frames: [LANV6Frame], consumedInputByteCount: Int,
         unconsumedInputByteCount: Int, framedByteCount: Int,
         payloadByteCount: Int) {
        self.frames = frames
        self.consumedInputByteCount = consumedInputByteCount
        self.unconsumedInputByteCount = unconsumedInputByteCount
        self.framedByteCount = framedByteCount
        self.payloadByteCount = payloadByteCount
    }
}

public enum LANV6SequenceDirection: String, Equatable {
    case inbound
    case outbound
}

/// Per-connection frame sequences. Both directions start at one, accept the
/// UInt32.max frame exactly once, and then enter an explicit terminal state.
public struct LANV6FrameSequenceState: Equatable {
    public private(set) var nextInbound: UInt32?
    public private(set) var nextOutbound: UInt32?

    public init() {
        nextInbound = 1
        nextOutbound = 1
    }

    /// White-box boundary seam; production connections always use `init()`.
    init(nextInbound: UInt32?, nextOutbound: UInt32?) {
        self.nextInbound = nextInbound
        self.nextOutbound = nextOutbound
    }

    public var inboundExhausted: Bool { nextInbound == nil }
    public var outboundExhausted: Bool { nextOutbound == nil }

    func validateInbound(_ actual: UInt32) throws {
        guard let expected = nextInbound else {
            throw LANV6FrameCodecError.sequenceExhausted(.inbound)
        }
        guard actual == expected else {
            throw LANV6FrameCodecError.invalidSequence(
                direction: .inbound, expected: expected, actual: actual
            )
        }
    }

    mutating func consumeInbound(_ actual: UInt32) throws {
        try validateInbound(actual)
        nextInbound = actual == UInt32.max ? nil : actual + 1
    }

    mutating func reserveOutbound() throws -> UInt32 {
        guard let sequence = nextOutbound else {
            throw LANV6FrameCodecError.sequenceExhausted(.outbound)
        }
        nextOutbound = sequence == UInt32.max ? nil : sequence + 1
        return sequence
    }
}

public enum LANV6FrameCodecError: Error, Equatable, CustomStringConvertible {
    case truncated
    case trailingBytes(Int)
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unknownMessageKind(UInt16)
    case payloadTooLarge(kind: LANV6MessageKind, count: Int, limit: Int)
    case streamBufferTooLarge(Int)
    case admissionDenied(localRole: LANV6LocalRole, phase: LANV6ConnectionPhase,
                         flow: LANV6FrameFlow, kind: LANV6MessageKind)
    case invalidSequence(direction: LANV6SequenceDirection, expected: UInt32, actual: UInt32)
    case sequenceExhausted(LANV6SequenceDirection)

    public var description: String {
        switch self {
        case .truncated: return "LAN v6 frame is truncated"
        case .trailingBytes(let count): return "LAN v6 frame has \(count) trailing bytes"
        case .invalidMagic: return "LAN v6 frame magic is invalid"
        case .unsupportedVersion(let version): return "Unsupported LAN protocol version \(version)"
        case .unknownMessageKind(let raw): return "Unknown LAN v6 message kind \(raw)"
        case .payloadTooLarge(let kind, let count, let limit):
            return "LAN v6 \(kind) payload is \(count) bytes; limit is \(limit)"
        case .streamBufferTooLarge(let count):
            return "LAN v6 stream buffer exceeds its bound (\(count) bytes)"
        case .admissionDenied(let role, let phase, let flow, let kind):
            return "LAN v6 \(role.rawValue) \(phase.rawValue) rejects \(flow.rawValue) \(kind)"
        case .invalidSequence(let direction, let expected, let actual):
            return "LAN v6 \(direction.rawValue) sequence expected \(expected), got \(actual)"
        case .sequenceExhausted(let direction):
            return "LAN v6 \(direction.rawValue) sequence is exhausted"
        }
    }
}

public struct LANV6FrameCodec {
    public static let headerByteCount = 16
    public static let maximumBufferedBytes = headerByteCount + LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT

    private struct Header {
        var kind: LANV6MessageKind
        var sequence: UInt32
        var payloadLength: Int
    }

    public static func frame(
        kind: LANV6MessageKind,
        rawPayload: Data,
        localRole: LANV6LocalRole,
        phase: LANV6ConnectionPhase,
        policy: LANV6FrameAdmissionPolicy,
        sequences: inout LANV6FrameSequenceState
    ) throws -> Data {
        try validateAdmission(localRole: localRole, phase: phase, flow: .outbound,
                              kind: kind, policy: policy)
        try validatePayloadLength(rawPayload.count, kind: kind)
        let sequence = try sequences.reserveOutbound()
        return makeFrame(kind: kind, rawPayload: rawPayload, sequence: sequence)
    }

    public static func decode(
        _ data: Data,
        localRole: LANV6LocalRole,
        phase: LANV6ConnectionPhase,
        policy: LANV6FrameAdmissionPolicy,
        sequences: inout LANV6FrameSequenceState
    ) throws -> LANV6Frame {
        let header = try parseHeader(data, localRole: localRole, phase: phase,
                                     flow: .inbound, policy: policy)
        try sequences.validateInbound(header.sequence)
        let total = headerByteCount + header.payloadLength
        guard data.count >= total else { throw LANV6FrameCodecError.truncated }
        guard data.count == total else {
            throw LANV6FrameCodecError.trailingBytes(data.count - total)
        }
        let payload = data.subdata(in: headerByteCount..<total)
        try sequences.consumeInbound(header.sequence)
        return LANV6Frame(sequence: header.sequence, kind: header.kind, rawPayload: payload)
    }

    /// Drains complete frames while retaining one bounded partial frame. Header
    /// admission and sequence validation happen as soon as 16 bytes exist,
    /// before waiting for or copying the declared payload.
    public static func decodeFrames(
        from buffer: inout Data,
        localRole: LANV6LocalRole,
        phase: LANV6ConnectionPhase,
        policy: LANV6FrameAdmissionPolicy,
        sequences: inout LANV6FrameSequenceState
    ) throws -> [LANV6Frame] {
        try feed(Data(), into: &buffer, localRole: localRole, phase: phase,
                 policy: policy, sequences: &sequences).frames
    }

    /// Transactionally feeds arbitrary TCP bytes into one bounded partial-frame
    /// buffer. Input is copied only as far as the next header/frame boundary;
    /// each complete frame is drained before more input is admitted. If any
    /// later coalesced header/frame fails, neither the caller's prior buffer nor
    /// either sequence counter advances and no partial output is returned.
    public static func feed(
        _ input: Data,
        into buffer: inout Data,
        localRole: LANV6LocalRole,
        phase: LANV6ConnectionPhase,
        policy: LANV6FrameAdmissionPolicy,
        sequences: inout LANV6FrameSequenceState
    ) throws -> LANV6FrameFeedResult {
        guard buffer.count <= maximumBufferedBytes else {
            throw LANV6FrameCodecError.streamBufferTooLarge(buffer.count)
        }
        var workingBuffer = buffer
        var workingSequences = sequences
        var frames: [LANV6Frame] = []
        var consumedInput = 0
        var bufferCursor = 0
        var framedByteCount = 0
        var payloadByteCount = 0

        while consumedInput < input.count
                || workingBuffer.count - bufferCursor >= headerByteCount {
            guard frames.count < LAN_V6_MAX_FEED_FRAMES,
                  framedByteCount <= LAN_V6_MAX_FEED_FRAMED_BYTES - headerByteCount
            else { break }

            let frameStartBufferCount = workingBuffer.count
            let frameStartConsumedInput = consumedInput
            let availableAtCursor = workingBuffer.count - bufferCursor
            if availableAtCursor < headerByteCount {
                let needed = headerByteCount - availableAtCursor
                let available = input.count - consumedInput
                let count = min(needed, available)
                guard count > 0 else { break }
                appendSlice(input, offset: consumedInput, count: count,
                            to: &workingBuffer)
                consumedInput += count
                guard workingBuffer.count - bufferCursor >= headerByteCount else { break }
            }

            let header = try parseHeader(workingBuffer, offset: bufferCursor,
                                         localRole: localRole, phase: phase,
                                         flow: .inbound, policy: policy)
            let total = headerByteCount + header.payloadLength
            if framedByteCount > LAN_V6_MAX_FEED_FRAMED_BYTES - total {
                // This frame belongs wholly to the untouched caller suffix.
                // Discard only header bytes tentatively admitted from this call.
                if workingBuffer.count > frameStartBufferCount {
                    workingBuffer.removeSubrange(frameStartBufferCount..<workingBuffer.count)
                }
                consumedInput = frameStartConsumedInput
                break
            }
            try workingSequences.validateInbound(header.sequence)

            let availableFrameBytes = workingBuffer.count - bufferCursor
            if availableFrameBytes < total {
                let needed = total - availableFrameBytes
                let available = input.count - consumedInput
                let count = min(needed, available)
                if count > 0 {
                    appendSlice(input, offset: consumedInput, count: count,
                                to: &workingBuffer)
                    consumedInput += count
                }
                guard workingBuffer.count - bufferCursor >= total else { break }
            }

            let payloadStart = bufferCursor + headerByteCount
            let payloadEnd = bufferCursor + total
            let payload = workingBuffer.subdata(in: payloadStart..<payloadEnd)
            try workingSequences.consumeInbound(header.sequence)
            frames.append(LANV6Frame(sequence: header.sequence, kind: header.kind,
                                     rawPayload: payload))
            bufferCursor += total
            framedByteCount += total
            payloadByteCount += header.payloadLength
        }

        if bufferCursor > 0 {
            workingBuffer.removeSubrange(0..<bufferCursor)
        }
        // A successful call retains at most one partial legal frame. This check
        // is deliberately after incremental draining: a maximum replication
        // frame followed by bytes of the next header is valid and bounded.
        guard workingBuffer.count <= maximumBufferedBytes else {
            throw LANV6FrameCodecError.streamBufferTooLarge(workingBuffer.count)
        }
        buffer = workingBuffer
        sequences = workingSequences
        return LANV6FrameFeedResult(
            frames: frames,
            consumedInputByteCount: consumedInput,
            unconsumedInputByteCount: input.count - consumedInput,
            framedByteCount: framedByteCount,
            payloadByteCount: payloadByteCount
        )
    }

    private static func parseHeader(
        _ data: Data,
        offset baseOffset: Int = 0,
        localRole: LANV6LocalRole,
        phase: LANV6ConnectionPhase,
        flow: LANV6FrameFlow,
        policy: LANV6FrameAdmissionPolicy
    ) throws -> Header {
        guard baseOffset >= 0, baseOffset <= data.count,
              data.count - baseOffset >= headerByteCount else {
            throw LANV6FrameCodecError.truncated
        }
        for magicOffset in LANV6FrameMagic.indices
            where byte(data, baseOffset + magicOffset) != LANV6FrameMagic[magicOffset] {
            throw LANV6FrameCodecError.invalidMagic
        }
        let version = readUInt16(data, offset: baseOffset + 4)
        guard version == LAN_V6_PROTOCOL_VERSION else {
            throw LANV6FrameCodecError.unsupportedVersion(version)
        }
        let rawKind = readUInt16(data, offset: baseOffset + 6)
        guard let kind = LANV6MessageKind(rawValue: rawKind) else {
            throw LANV6FrameCodecError.unknownMessageKind(rawKind)
        }
        try validateAdmission(localRole: localRole, phase: phase, flow: flow,
                              kind: kind, policy: policy)
        let payloadLength = Int(readUInt32(data, offset: baseOffset + 12))
        try validatePayloadLength(payloadLength, kind: kind)
        return Header(kind: kind, sequence: readUInt32(data, offset: baseOffset + 8),
                      payloadLength: payloadLength)
    }

    private static func validateAdmission(
        localRole: LANV6LocalRole,
        phase: LANV6ConnectionPhase,
        flow: LANV6FrameFlow,
        kind: LANV6MessageKind,
        policy: LANV6FrameAdmissionPolicy
    ) throws {
        guard policy.admits(localRole: localRole, phase: phase, flow: flow, kind: kind) else {
            throw LANV6FrameCodecError.admissionDenied(
                localRole: localRole, phase: phase, flow: flow, kind: kind
            )
        }
    }

    private static func validatePayloadLength(_ count: Int,
                                              kind: LANV6MessageKind) throws {
        let limit = min(LAN_V6_GLOBAL_FRAME_PAYLOAD_LIMIT, kind.payloadLimit)
        guard count <= limit else {
            throw LANV6FrameCodecError.payloadTooLarge(
                kind: kind, count: count, limit: limit
            )
        }
    }

    private static func makeFrame(kind: LANV6MessageKind, rawPayload: Data,
                                  sequence: UInt32) -> Data {
        var data = Data()
        data.reserveCapacity(headerByteCount + rawPayload.count)
        data.append(contentsOf: LANV6FrameMagic)
        appendUInt16(LAN_V6_PROTOCOL_VERSION, to: &data)
        appendUInt16(kind.rawValue, to: &data)
        appendUInt32(sequence, to: &data)
        appendUInt32(UInt32(rawPayload.count), to: &data)
        data.append(rawPayload)
        return data
    }

    private static func appendSlice(_ input: Data, offset: Int, count: Int,
                                    to output: inout Data) {
        guard count > 0 else { return }
        let start = input.index(input.startIndex, offsetBy: offset)
        let end = input.index(start, offsetBy: count)
        output.append(contentsOf: input[start..<end])
    }

    private static func byte(_ data: Data, _ offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func readUInt16(_ data: Data, offset: Int) -> UInt16 {
        (UInt16(byte(data, offset)) << 8) | UInt16(byte(data, offset + 1))
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        (UInt32(byte(data, offset)) << 24)
            | (UInt32(byte(data, offset + 1)) << 16)
            | (UInt32(byte(data, offset + 2)) << 8)
            | UInt32(byte(data, offset + 3))
    }
}
