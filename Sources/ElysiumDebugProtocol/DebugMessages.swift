import Foundation

public enum ElysiumDebugProtocolVersion {
    public static let current: UInt16 = 1
}

/// A JSON-compatible value used by the debug protocol without depending on game types.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Non-finite number")
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Non-finite numbers are not valid JSON"
                ))
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct DebugRequest: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let id: UUID
    public let operation: String
    public let arguments: [String: JSONValue]
    public let expectedEpoch: UInt64?
    public let expectedRevision: UInt64?
    /// An absolute deadline on the machine's monotonic uptime clock.
    public let deadlineUptimeNanoseconds: UInt64?

    public init(
        protocolVersion: UInt16 = ElysiumDebugProtocolVersion.current,
        id: UUID = UUID(),
        operation: String,
        arguments: [String: JSONValue] = [:],
        expectedEpoch: UInt64? = nil,
        expectedRevision: UInt64? = nil,
        deadlineUptimeNanoseconds: UInt64? = nil
    ) throws {
        guard protocolVersion == ElysiumDebugProtocolVersion.current else {
            throw DebugProtocolError.unsupportedProtocolVersion(protocolVersion)
        }
        guard Self.isValidOperation(operation) else {
            throw DebugProtocolError.invalidMessage("operation")
        }
        guard arguments.count <= 128 else {
            throw DebugProtocolError.invalidMessage("argument count")
        }
        if let deadlineUptimeNanoseconds, deadlineUptimeNanoseconds == 0 {
            throw DebugProtocolError.invalidMessage("deadline")
        }
        self.protocolVersion = protocolVersion
        self.id = id
        self.operation = operation
        self.arguments = arguments
        self.expectedEpoch = expectedEpoch
        self.expectedRevision = expectedRevision
        self.deadlineUptimeNanoseconds = deadlineUptimeNanoseconds
    }

    public func isExpired(atUptimeNanoseconds now: UInt64) -> Bool {
        deadlineUptimeNanoseconds.map { now >= $0 } ?? false
    }

    private static func isValidOperation(_ operation: String) -> Bool {
        let bytes = operation.utf8
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7a) ||
                (byte >= 0x30 && byte <= 0x39) ||
                byte == 0x2e || byte == 0x5f || byte == 0x2d
        }
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, id, operation, arguments
        case expectedEpoch, expectedRevision, deadlineUptimeNanoseconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: try container.decode(UInt16.self, forKey: .protocolVersion),
            id: try container.decode(UUID.self, forKey: .id),
            operation: try container.decode(String.self, forKey: .operation),
            arguments: try container.decode([String: JSONValue].self, forKey: .arguments),
            expectedEpoch: try container.decodeIfPresent(UInt64.self, forKey: .expectedEpoch),
            expectedRevision: try container.decodeIfPresent(UInt64.self, forKey: .expectedRevision),
            deadlineUptimeNanoseconds: try container.decodeIfPresent(
                UInt64.self, forKey: .deadlineUptimeNanoseconds
            )
        )
    }
}

public enum DebugErrorCode: String, Codable, CaseIterable, Sendable {
    case unauthenticated
    case unsupportedVersion
    case invalidArguments
    case unknownOperation
    case deadlineExceeded
    case wrongEpoch
    case wrongRevision
    case wrongState
    case noWorld
    case unloaded
    case forbiddenInLANClient
    case notAuthoritative
    case busy
    case timeout
    case boundedLimit
    case staleScreen
    case placementRejected
    case persistenceFailed
    case internalFailure
}

public struct DebugError: Codable, Equatable, Sendable {
    public let code: DebugErrorCode
    public let message: String
    public let retryable: Bool
    public let details: [String: JSONValue]

    public init(
        code: DebugErrorCode,
        message: String,
        retryable: Bool = false,
        details: [String: JSONValue] = [:]
    ) {
        self.code = code
        self.message = String(message.prefix(512))
        self.retryable = retryable
        self.details = details.count <= 32 ? details : [:]
    }

    private enum CodingKeys: String, CodingKey { case code, message, retryable, details }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let message = try container.decode(String.self, forKey: .message)
        let details = try container.decode([String: JSONValue].self, forKey: .details)
        guard message.count <= 512, details.count <= 32 else {
            throw DebugProtocolError.invalidMessage("error payload")
        }
        self.code = try container.decode(DebugErrorCode.self, forKey: .code)
        self.message = message
        self.retryable = try container.decode(Bool.self, forKey: .retryable)
        self.details = details
    }
}

public struct DebugResponse: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let requestID: UUID
    public let result: [String: JSONValue]?
    public let error: DebugError?
    public let epoch: UInt64?
    public let revision: UInt64?
    public let eventSequence: UInt64?

    public init(
        protocolVersion: UInt16 = ElysiumDebugProtocolVersion.current,
        requestID: UUID,
        result: [String: JSONValue] = [:],
        epoch: UInt64? = nil,
        revision: UInt64? = nil,
        eventSequence: UInt64? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = result
        self.error = nil
        self.epoch = epoch
        self.revision = revision
        self.eventSequence = eventSequence
    }

    public init(
        protocolVersion: UInt16 = ElysiumDebugProtocolVersion.current,
        requestID: UUID,
        error: DebugError,
        epoch: UInt64? = nil,
        revision: UInt64? = nil,
        eventSequence: UInt64? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.result = nil
        self.error = error
        self.epoch = epoch
        self.revision = revision
        self.eventSequence = eventSequence
    }

    public var isSuccess: Bool { result != nil && error == nil }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, requestID, result, error, epoch, revision, eventSequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(UInt16.self, forKey: .protocolVersion)
        guard version == ElysiumDebugProtocolVersion.current else {
            throw DebugProtocolError.unsupportedProtocolVersion(version)
        }
        let requestID = try container.decode(UUID.self, forKey: .requestID)
        let result = try container.decodeIfPresent([String: JSONValue].self, forKey: .result)
        let error = try container.decodeIfPresent(DebugError.self, forKey: .error)
        guard (result != nil) != (error != nil) else {
            throw DebugProtocolError.invalidMessage("response must contain exactly one of result or error")
        }
        self.protocolVersion = version
        self.requestID = requestID
        self.result = result
        self.error = error
        self.epoch = try container.decodeIfPresent(UInt64.self, forKey: .epoch)
        self.revision = try container.decodeIfPresent(UInt64.self, forKey: .revision)
        self.eventSequence = try container.decodeIfPresent(UInt64.self, forKey: .eventSequence)
    }
}

public struct DebugEvent: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let name: String
    public let sequence: UInt64
    public let epoch: UInt64
    public let revision: UInt64
    public let simulationTick: UInt64?
    public let payload: [String: JSONValue]

    public init(
        protocolVersion: UInt16 = ElysiumDebugProtocolVersion.current,
        name: String,
        sequence: UInt64,
        epoch: UInt64,
        revision: UInt64,
        simulationTick: UInt64? = nil,
        payload: [String: JSONValue] = [:]
    ) throws {
        guard protocolVersion == ElysiumDebugProtocolVersion.current else {
            throw DebugProtocolError.unsupportedProtocolVersion(protocolVersion)
        }
        guard sequence > 0, Self.isValidName(name), payload.count <= 128 else {
            throw DebugProtocolError.invalidMessage("event")
        }
        self.protocolVersion = protocolVersion
        self.name = name
        self.sequence = sequence
        self.epoch = epoch
        self.revision = revision
        self.simulationTick = simulationTick
        self.payload = payload
    }

    private static func isValidName(_ name: String) -> Bool {
        let bytes = name.utf8
        guard !bytes.isEmpty, bytes.count <= 128 else { return false }
        return bytes.allSatisfy { byte in
            (byte >= 0x61 && byte <= 0x7a) ||
                (byte >= 0x30 && byte <= 0x39) ||
                byte == 0x2e || byte == 0x5f || byte == 0x2d
        }
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, name, sequence, epoch, revision, simulationTick, payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: try container.decode(UInt16.self, forKey: .protocolVersion),
            name: try container.decode(String.self, forKey: .name),
            sequence: try container.decode(UInt64.self, forKey: .sequence),
            epoch: try container.decode(UInt64.self, forKey: .epoch),
            revision: try container.decode(UInt64.self, forKey: .revision),
            simulationTick: try container.decodeIfPresent(UInt64.self, forKey: .simulationTick),
            payload: try container.decode([String: JSONValue].self, forKey: .payload)
        )
    }
}
