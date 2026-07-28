import Foundation

public struct DebugClientHello: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let sessionID: UUID
    public let buildIdentifier: String

    public init(
        protocolVersion: UInt16 = ElysiumDebugProtocolVersion.current,
        sessionID: UUID,
        buildIdentifier: String
    ) throws {
        guard protocolVersion == ElysiumDebugProtocolVersion.current else {
            throw DebugProtocolError.unsupportedProtocolVersion(protocolVersion)
        }
        guard Self.isValidBuildIdentifier(buildIdentifier) else {
            throw DebugProtocolError.invalidMessage("build identifier")
        }
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.buildIdentifier = buildIdentifier
    }

    private static func isValidBuildIdentifier(_ value: String) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= 128 && bytes.allSatisfy { $0 >= 0x20 && $0 != 0x7f }
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, sessionID, buildIdentifier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: try container.decode(UInt16.self, forKey: .protocolVersion),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            buildIdentifier: try container.decode(String.self, forKey: .buildIdentifier)
        )
    }
}

public struct DebugServerHello: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    public let sessionID: UUID
    public let capabilities: DebugCapabilities

    public init(
        protocolVersion: UInt16 = ElysiumDebugProtocolVersion.current,
        sessionID: UUID,
        capabilities: DebugCapabilities
    ) throws {
        guard protocolVersion == ElysiumDebugProtocolVersion.current,
              capabilities.protocolVersion == protocolVersion else {
            throw DebugProtocolError.unsupportedProtocolVersion(protocolVersion)
        }
        self.protocolVersion = protocolVersion
        self.sessionID = sessionID
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, sessionID, capabilities
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: try container.decode(UInt16.self, forKey: .protocolVersion),
            sessionID: try container.decode(UUID.self, forKey: .sessionID),
            capabilities: try container.decode(DebugCapabilities.self, forKey: .capabilities)
        )
    }
}
