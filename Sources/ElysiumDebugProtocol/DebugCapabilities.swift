import Foundation

/// Extensible capability identifier. Unknown identifiers can be preserved during negotiation.
public struct DebugCapabilityID: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard debugIdentifierIsValid(rawValue) else {
            throw DebugProtocolError.invalidMessage("capability identifier")
        }
        self.init(rawValue: rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let readSnapshots = Self(rawValue: "state.snapshot")
    public static let subscribeEvents = Self(rawValue: "events.subscribe")
    public static let replayEvents = Self(rawValue: "events.replay")
    public static let captureFrames = Self(rawValue: "render.capture")
    public static let worldLifecycle = Self(rawValue: "world.lifecycle")
    public static let simulationControl = Self(rawValue: "simulation.control")
    public static let playerControl = Self(rawValue: "player.control")
    public static let environmentMutation = Self(rawValue: "world.mutate")
    public static let entityControl = Self(rawValue: "entity.control")
    public static let interactionControl = Self(rawValue: "interaction.control")
    public static let screenControl = Self(rawValue: "screen.control")
    public static let templateControl = Self(rawValue: "template.control")
    public static let rpgControl = Self(rawValue: "rpg.control")
    public static let lanControl = Self(rawValue: "lan.control")
}

public struct DebugCapabilities: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let capabilities: [DebugCapabilityID]
    public let maximumRequestPayloadBytes: Int
    public let maximumSnapshotPayloadBytes: Int
    public let maximumEventReplayCount: Int

    public init(
        protocolVersion: UInt16 = ElysiumDebugProtocolVersion.current,
        capabilities: [DebugCapabilityID],
        maximumRequestPayloadBytes: Int = 64 * 1024,
        maximumSnapshotPayloadBytes: Int = DebugFrameLimits.absoluteMaximumPayloadBytes,
        maximumEventReplayCount: Int = 4_096
    ) throws {
        guard protocolVersion == ElysiumDebugProtocolVersion.current else {
            throw DebugProtocolError.unsupportedProtocolVersion(protocolVersion)
        }
        guard maximumRequestPayloadBytes > 0,
              maximumRequestPayloadBytes <= DebugFrameLimits.absoluteMaximumPayloadBytes,
              maximumSnapshotPayloadBytes > 0,
              maximumSnapshotPayloadBytes <= DebugFrameLimits.absoluteMaximumPayloadBytes,
              maximumEventReplayCount > 0,
              maximumEventReplayCount <= 65_536 else {
            throw DebugProtocolError.invalidMessage("capability limits")
        }
        let unique = Set(capabilities)
        guard unique.count == capabilities.count,
              capabilities.allSatisfy({ debugIdentifierIsValid($0.rawValue) }) else {
            throw DebugProtocolError.invalidMessage("capabilities")
        }
        self.protocolVersion = protocolVersion
        self.capabilities = unique.sorted()
        self.maximumRequestPayloadBytes = maximumRequestPayloadBytes
        self.maximumSnapshotPayloadBytes = maximumSnapshotPayloadBytes
        self.maximumEventReplayCount = maximumEventReplayCount
    }

    public func supports(_ capability: DebugCapabilityID) -> Bool {
        capabilities.binarySearch(capability)
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, capabilities, maximumRequestPayloadBytes
        case maximumSnapshotPayloadBytes, maximumEventReplayCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: try container.decode(UInt16.self, forKey: .protocolVersion),
            capabilities: try container.decode([DebugCapabilityID].self, forKey: .capabilities),
            maximumRequestPayloadBytes: try container.decode(Int.self, forKey: .maximumRequestPayloadBytes),
            maximumSnapshotPayloadBytes: try container.decode(
                Int.self, forKey: .maximumSnapshotPayloadBytes
            ),
            maximumEventReplayCount: try container.decode(Int.self, forKey: .maximumEventReplayCount)
        )
    }
}

private extension Array where Element: Comparable {
    func binarySearch(_ value: Element) -> Bool {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let distance = self.distance(from: lower, to: upper)
            let middle = index(lower, offsetBy: distance / 2)
            if self[middle] == value { return true }
            if self[middle] < value {
                lower = index(after: middle)
            } else {
                upper = middle
            }
        }
        return false
    }
}

/// Extensible snapshot scope identifier.
public struct DebugSnapshotScope: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard debugIdentifierIsValid(rawValue) else {
            throw DebugProtocolError.invalidMessage("snapshot scope")
        }
        self.init(rawValue: rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let app = Self(rawValue: "app")
    public static let world = Self(rawValue: "world")
    public static let player = Self(rawValue: "player")
    public static let target = Self(rawValue: "target")
    public static let inventory = Self(rawValue: "inventory")
    public static let rpg = Self(rawValue: "rpg")
    public static let screen = Self(rawValue: "screen")
    public static let region = Self(rawValue: "region")
    public static let entities = Self(rawValue: "entities")
    public static let renderer = Self(rawValue: "renderer")
    public static let network = Self(rawValue: "network")
}

public struct DebugSnapshotQuery: Codable, Equatable, Sendable {
    public let scopes: [DebugSnapshotScope]
    public let maximumItemsPerScope: Int
    public let cursor: String?

    public init(
        scopes: [DebugSnapshotScope],
        maximumItemsPerScope: Int = 1_024,
        cursor: String? = nil
    ) throws {
        guard !scopes.isEmpty, scopes.count <= 32, Set(scopes).count == scopes.count,
              maximumItemsPerScope > 0, maximumItemsPerScope <= 65_536,
              cursor?.utf8.count ?? 0 <= 512 else {
            throw DebugProtocolError.invalidMessage("snapshot query")
        }
        self.scopes = scopes.sorted()
        self.maximumItemsPerScope = maximumItemsPerScope
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey { case scopes, maximumItemsPerScope, cursor }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            scopes: try container.decode([DebugSnapshotScope].self, forKey: .scopes),
            maximumItemsPerScope: try container.decode(Int.self, forKey: .maximumItemsPerScope),
            cursor: try container.decodeIfPresent(String.self, forKey: .cursor)
        )
    }
}

public struct DebugSnapshotIdentity: Codable, Equatable, Sendable {
    public let snapshotID: UUID
    public let sessionID: UUID
    public let epoch: UInt64
    public let revision: UInt64
    public let eventSequence: UInt64
    public let simulationTick: UInt64?
    public let dimensionID: String?
    public let screenGeneration: UInt64?
    public let registryGeneration: UInt64

    public init(
        snapshotID: UUID = UUID(),
        sessionID: UUID,
        epoch: UInt64,
        revision: UInt64,
        eventSequence: UInt64,
        simulationTick: UInt64? = nil,
        dimensionID: String? = nil,
        screenGeneration: UInt64? = nil,
        registryGeneration: UInt64
    ) {
        self.snapshotID = snapshotID
        self.sessionID = sessionID
        self.epoch = epoch
        self.revision = revision
        self.eventSequence = eventSequence
        self.simulationTick = simulationTick
        self.dimensionID = dimensionID
        self.screenGeneration = screenGeneration
        self.registryGeneration = registryGeneration
    }
}

public struct DebugSnapshot: Codable, Equatable, Sendable {
    public let identity: DebugSnapshotIdentity
    public let sections: [String: JSONValue]
    public let truncatedScopes: [DebugSnapshotScope]
    public let nextCursor: String?

    public init(
        identity: DebugSnapshotIdentity,
        sections: [String: JSONValue],
        truncatedScopes: [DebugSnapshotScope] = [],
        nextCursor: String? = nil
    ) {
        self.identity = identity
        self.sections = sections
        self.truncatedScopes = Array(Set(truncatedScopes)).sorted()
        self.nextCursor = nextCursor
    }
}

private func debugIdentifierIsValid(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= 128 else { return false }
    return bytes.allSatisfy { byte in
        (byte >= 0x61 && byte <= 0x7a) ||
            (byte >= 0x30 && byte <= 0x39) ||
            byte == 0x2e || byte == 0x5f || byte == 0x2d
    }
}
