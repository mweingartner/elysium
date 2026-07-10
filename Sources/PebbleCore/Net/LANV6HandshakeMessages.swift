import Foundation

public let LAN_V6_HANDSHAKE_JSON_LIMIT = 4_096

public enum LANV6HandshakeMessageError: Error, Equatable, CustomStringConvertible {
    case unsupportedProtocolVersion(UInt16)
    case advertisedIdentityMismatch
    case admissionShapeMismatch
    case invalidLegacyHint
    case invalidCredentialGeneration
    case invalidSocketGeneration
    case invalidPeerAuthority
    case invalidRejectReason

    public var description: String {
        switch self {
        case .unsupportedProtocolVersion(let version):
            return "Unsupported LAN handshake protocol version \(version)"
        case .advertisedIdentityMismatch:
            return "LAN handshake identity does not match its advertised digest"
        case .admissionShapeMismatch:
            return "LAN handshake admission variant is inconsistent"
        case .invalidLegacyHint:
            return "LAN legacy hint is not a canonical UUID"
        case .invalidCredentialGeneration:
            return "LAN credential generation is invalid"
        case .invalidSocketGeneration:
            return "LAN socket generation is invalid"
        case .invalidPeerAuthority:
            return "LAN peer authority is invalid"
        case .invalidRejectReason:
            return "LAN rejection reason is invalid"
        }
    }
}

/// A v5 client identifier is only an untrusted migration hint. Canonical form
/// intentionally matches Foundation's uppercase 36-byte UUID serialization,
/// which is the representation emitted by the sealed v5 client path.
public struct LANV6LegacyHint: Hashable, Codable, CustomStringConvertible, Sendable {
    public let value: String

    public init(_ value: String) throws {
        guard value.utf8.count == 36,
              let uuid = UUID(uuidString: value),
              uuid.uuidString == value
        else {
            throw LANV6HandshakeMessageError.invalidLegacyHint
        }
        self.value = value
    }

    public var description: String { value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a canonical uppercase 36-character UUID"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

/// A raw legacy-claim nonce has identifier-sized bytes but is a credential,
/// so its description is always redacted rather than inheriting ID rendering.
public struct LANV6ClaimNonce: Hashable, Codable, CustomStringConvertible, Sendable {
    public static let redactedDescription = "<redacted LAN v6 claim nonce>"
    private let value: LANV6ID128

    public init(bytes: [UInt8]) throws {
        value = try LANV6ID128(bytes: bytes)
    }

    public init(base64URL: String) throws {
        value = try LANV6ID128(base64URL: base64URL)
    }

    public var bytes: [UInt8] { value.bytes }
    public var data: Data { value.data }
    public var base64URL: String { value.base64URL }
    public var description: String { Self.redactedDescription }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        do {
            try self.init(base64URL: encoded)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a canonical 22-character LAN v6 claim nonce"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(base64URL)
    }
}

public enum LANV6ClientAdmissionV6: Equatable, Hashable, Sendable {
    case joinNew(joinCode: LANV6JoinCode)
    case resume(rawToken: LANV6Token256)
    case legacyClaim(
        joinCode: LANV6JoinCode,
        legacyHint: LANV6LegacyHint?,
        rawClaimNonce: LANV6ClaimNonce
    )
    case legacyConsume(rawClaimNonce: LANV6ClaimNonce)

    fileprivate var strictShape: LANV6StrictJSONHelloAdmissionShape {
        switch self {
        case .joinNew: return .joinNew
        case .resume: return .resume
        case .legacyClaim: return .legacyClaim
        case .legacyConsume: return .legacyConsume
        }
    }
}

/// The only protocol-v6 client hello. Public construction and decoding both
/// validate the advertised host/world digest; no admission variant carries an
/// authority, generation, permission, or owner state.
public struct LANClientHelloV6: Equatable, CustomStringConvertible, Sendable {
    public let protocolVersion: UInt16
    public let hostInstallationID: LANHostInstallationIDV6
    public let worldLANID: LANWorldIDV6
    public let lookupDigest: LANV6SHA256Digest
    public let playerName: LANV6DisplayName
    public let admission: LANV6ClientAdmissionV6

    public init(
        hostInstallationID: LANHostInstallationIDV6,
        worldLANID: LANWorldIDV6,
        lookupDigest: LANV6SHA256Digest,
        playerName: LANV6DisplayName,
        admission: LANV6ClientAdmissionV6
    ) throws {
        guard LANV6Crypto.constantTimeEqual(
            lookupDigest,
            LANV6Crypto.lookupDigest(
                hostInstallationID: hostInstallationID,
                worldLANID: worldLANID
            )
        ) else {
            throw LANV6HandshakeMessageError.advertisedIdentityMismatch
        }
        protocolVersion = LAN_V6_PROTOCOL_VERSION
        self.hostInstallationID = hostInstallationID
        self.worldLANID = worldLANID
        self.lookupDigest = lookupDigest
        self.playerName = playerName
        self.admission = admission
    }

    public init(
        hostInstallationID: LANHostInstallationIDV6,
        worldLANID: LANWorldIDV6,
        playerName: LANV6DisplayName,
        admission: LANV6ClientAdmissionV6
    ) throws {
        try self.init(
            hostInstallationID: hostInstallationID,
            worldLANID: worldLANID,
            lookupDigest: LANV6Crypto.lookupDigest(
                hostInstallationID: hostInstallationID,
                worldLANID: worldLANID
            ),
            playerName: playerName,
            admission: admission
        )
    }

    /// Unbound decoding is module-internal for deterministic parser tests.
    /// Production callers must use the expected-tuple overload below.
    static func decodeStrict(_ data: Data) throws -> LANClientHelloV6 {
        let (scannedShape, common) = try decodeValidatedCommon(data)
        try LANV6HandshakeValidation.requireIdentity(
            hostInstallationID: common.hid,
            worldLANID: common.wid,
            lookupDigest: common.lk
        )
        return try decodeBody(data, scannedShape: scannedShape)
    }

    private static func decodeValidatedCommon(
        _ data: Data
    ) throws -> (LANV6StrictJSONHelloAdmissionShape, ClientHelloCommonWire) {
        let scan = try LANV6StrictJSON.scan(data, limits: .lanV6Handshake)
        let shape = try scan.requireClosedHelloObjectShape()
        try scan.requireCanonicalUnsignedInteger(atKeyPath: ["pv"])
        let common = try LANV6HandshakeJSON.decode(ClientHelloCommonWire.self, from: data)
        guard common.pv == LAN_V6_PROTOCOL_VERSION else {
            throw LANV6HandshakeMessageError.unsupportedProtocolVersion(common.pv)
        }
        return (shape, common)
    }

    private static func decodeBody(
        _ data: Data,
        scannedShape: LANV6StrictJSONHelloAdmissionShape
    ) throws -> LANClientHelloV6 {
        let wire = try LANV6HandshakeJSON.decode(ClientHelloWire.self, from: data)
        guard scannedShape == wire.admission.value.strictShape else {
            throw LANV6HandshakeMessageError.admissionShapeMismatch
        }
        return try LANClientHelloV6(
            hostInstallationID: wire.hid,
            worldLANID: wire.wid,
            lookupDigest: wire.lk,
            playerName: wire.playerName,
            admission: wire.admission.value
        )
    }

    /// Host-side binding check. Structure and public identity fields are
    /// validated before the credential-bearing admission body is decoded.
    public static func decodeStrict(
        _ data: Data,
        expectedHostInstallationID: LANHostInstallationIDV6,
        expectedWorldLANID: LANWorldIDV6,
        expectedLookupDigest: LANV6SHA256Digest
    ) throws -> LANClientHelloV6 {
        let (scannedShape, common) = try decodeValidatedCommon(data)
        try LANV6HandshakeValidation.requireIdentity(
            hostInstallationID: common.hid,
            worldLANID: common.wid,
            lookupDigest: common.lk
        )
        guard common.hid == expectedHostInstallationID,
              common.wid == expectedWorldLANID,
              LANV6Crypto.constantTimeEqual(common.lk, expectedLookupDigest)
        else {
            throw LANV6HandshakeMessageError.advertisedIdentityMismatch
        }
        return try decodeBody(data, scannedShape: scannedShape)
    }

    public func encoded() throws -> Data {
        try LANV6HandshakeJSON.encode(ClientHelloWire(self))
    }

    public var description: String {
        "LANClientHelloV6(pv: 6, hid: <redacted>, wid: <redacted>, " +
            "lk: <redacted>, playerName: <redacted>, admission: <redacted>)"
    }
}

public enum LANV6ServerRejectReason: String, CaseIterable, Codable, Sendable {
    /// All credential, join-code, claim, expiry, and lookup failures collapse
    /// to this one non-oracular response.
    case admissionFailed
    case busy
    case incompatibleProtocol
}

public struct LANServerRejectV6: Equatable, CustomStringConvertible, Sendable {
    public let reason: LANV6ServerRejectReason

    public init(reason: LANV6ServerRejectReason) {
        self.reason = reason
    }

    public static func decodeStrict(_ data: Data) throws -> LANServerRejectV6 {
        let scan = try LANV6StrictJSON.scan(data, limits: .lanV6Handshake)
        try scan.requireTopLevelObject(exactKeys: ["reason"])
        return LANServerRejectV6(
            reason: try LANV6HandshakeJSON.decode(ServerRejectWire.self, from: data).reason
        )
    }

    public func encoded() throws -> Data {
        try LANV6HandshakeJSON.encode(ServerRejectWire(reason: reason))
    }

    public var description: String { "LANServerRejectV6(reason: \(reason.rawValue))" }
}

/// A pending credential accept is a closed two-shape object. Fresh/rotated
/// credentials include `rawPendingToken`; a pending-token resume omits that
/// key entirely because the client necessarily already holds the token.
public enum LANV6PendingCredentialDelivery: Equatable, Sendable {
    case issued(rawToken: LANV6Token256)
    case resumedExisting

    fileprivate var rawPendingToken: LANV6Token256? {
        switch self {
        case .issued(let rawToken): return rawToken
        case .resumedExisting: return nil
        }
    }
}

public struct LANServerAcceptV6: Equatable, CustomStringConvertible, Sendable {
    public let protocolVersion: UInt16
    public let hostInstallationID: LANHostInstallationIDV6
    public let worldLANID: LANWorldIDV6
    public let lookupDigest: LANV6SHA256Digest
    public let authority: LANV6Authority
    public let activeGeneration: UInt32?
    public let pendingGeneration: UInt32
    public let handshakeID: LANHandshakeIDV6
    public let opaqueSocketGeneration: UInt32
    public let epoch: LANSessionEpochV6
    public let credentialDelivery: LANV6PendingCredentialDelivery

    public init(
        hostInstallationID: LANHostInstallationIDV6,
        worldLANID: LANWorldIDV6,
        lookupDigest: LANV6SHA256Digest,
        authority: LANV6Authority,
        activeGeneration: UInt32?,
        pendingGeneration: UInt32,
        handshakeID: LANHandshakeIDV6,
        opaqueSocketGeneration: UInt32,
        epoch: LANSessionEpochV6,
        credentialDelivery: LANV6PendingCredentialDelivery
    ) throws {
        try LANV6HandshakeValidation.requireIdentity(
            hostInstallationID: hostInstallationID,
            worldLANID: worldLANID,
            lookupDigest: lookupDigest
        )
        try LANV6HandshakeValidation.requireGenerations(
            active: activeGeneration,
            pending: pendingGeneration
        )
        try LANV6HandshakeValidation.requireGuestAuthority(authority)
        guard opaqueSocketGeneration > 0,
              opaqueSocketGeneration <= LAN_V6_MAX_COUNTER
        else {
            throw LANV6HandshakeMessageError.invalidSocketGeneration
        }
        protocolVersion = LAN_V6_PROTOCOL_VERSION
        self.hostInstallationID = hostInstallationID
        self.worldLANID = worldLANID
        self.lookupDigest = lookupDigest
        self.authority = authority
        self.activeGeneration = activeGeneration
        self.pendingGeneration = pendingGeneration
        self.handshakeID = handshakeID
        self.opaqueSocketGeneration = opaqueSocketGeneration
        self.epoch = epoch
        self.credentialDelivery = credentialDelivery
    }

    /// Unbound decoding is module-internal for deterministic parser tests.
    /// Production callers must use the expected-tuple overload below.
    static func decodeStrict(_ data: Data) throws -> LANServerAcceptV6 {
        let (actual, common) = try decodeValidatedCommon(data)
        try LANV6HandshakeValidation.requireIdentity(
            hostInstallationID: common.hid,
            worldLANID: common.wid,
            lookupDigest: common.lk
        )
        return try decodeBody(data, actualKeys: actual)
    }

    private static func decodeValidatedCommon(
        _ data: Data
    ) throws -> (Set<String>, ServerAcceptCommonWire) {
        let scan = try LANV6StrictJSON.scan(data, limits: .lanV6Handshake)
        let baseKeys: Set<String> = [
            "pv", "hid", "wid", "lk", "authority", "activeGeneration",
            "pendingGeneration", "handshakeID", "opaqueSocketGeneration", "epoch",
        ]
        let actual = Set(scan.topLevelObjectKeyStrings)
        guard actual == baseKeys || actual == baseKeys.union(["rawPendingToken"]) else {
            try scan.requireTopLevelObject(exactKeys: baseKeys)
            throw LANV6HandshakeMessageError.admissionShapeMismatch
        }
        try scan.requireTopLevelObject(exactKeys: actual)
        try scan.requireCanonicalUnsignedInteger(atKeyPath: ["pv"])
        try scan.requireCanonicalUnsignedIntegerIfPresent(
            atKeyPath: ["activeGeneration"]
        )
        try scan.requireCanonicalUnsignedInteger(atKeyPath: ["pendingGeneration"])
        try scan.requireCanonicalUnsignedInteger(atKeyPath: ["opaqueSocketGeneration"])
        let common = try LANV6HandshakeJSON.decode(ServerAcceptCommonWire.self, from: data)
        guard common.pv == LAN_V6_PROTOCOL_VERSION else {
            throw LANV6HandshakeMessageError.unsupportedProtocolVersion(common.pv)
        }
        return (actual, common)
    }

    private static func decodeBody(
        _ data: Data,
        actualKeys: Set<String>
    ) throws -> LANServerAcceptV6 {
        let wire = try LANV6HandshakeJSON.decode(ServerAcceptWire.self, from: data)
        guard actualKeys.contains("rawPendingToken") == (wire.rawPendingToken != nil) else {
            throw LANV6HandshakeMessageError.admissionShapeMismatch
        }
        return try LANServerAcceptV6(
            hostInstallationID: wire.hid,
            worldLANID: wire.wid,
            lookupDigest: wire.lk,
            authority: wire.authority,
            activeGeneration: wire.activeGeneration,
            pendingGeneration: wire.pendingGeneration,
            handshakeID: wire.handshakeID,
            opaqueSocketGeneration: wire.opaqueSocketGeneration,
            epoch: wire.epoch,
            credentialDelivery: wire.rawPendingToken.map {
                .issued(rawToken: $0)
            } ?? .resumedExisting
        )
    }

    /// Client-side echo binding for Bonjour and Direct Invite connections.
    public static func decodeStrict(
        _ data: Data,
        expectedHostInstallationID: LANHostInstallationIDV6,
        expectedWorldLANID: LANWorldIDV6,
        expectedLookupDigest: LANV6SHA256Digest
    ) throws -> LANServerAcceptV6 {
        let (actual, common) = try decodeValidatedCommon(data)
        try LANV6HandshakeValidation.requireIdentity(
            hostInstallationID: common.hid,
            worldLANID: common.wid,
            lookupDigest: common.lk
        )
        guard common.hid == expectedHostInstallationID,
              common.wid == expectedWorldLANID,
              LANV6Crypto.constantTimeEqual(common.lk, expectedLookupDigest)
        else {
            throw LANV6HandshakeMessageError.advertisedIdentityMismatch
        }
        return try decodeBody(data, actualKeys: actual)
    }

    public func encoded() throws -> Data {
        try LANV6HandshakeJSON.encode(ServerAcceptWire(self))
    }

    public var description: String {
        "LANServerAcceptV6(pv: 6, hid: <redacted>, wid: <redacted>, " +
            "lk: <redacted>, authority: <redacted>, " +
            "activeGeneration: \(String(describing: activeGeneration)), " +
            "pendingGeneration: \(pendingGeneration), handshakeID: <redacted>, " +
            "opaqueSocketGeneration: <redacted>, epoch: <redacted>, " +
            "rawPendingToken: <redacted>)"
    }
}

public struct LANClientReadyV6: Equatable, CustomStringConvertible, Sendable {
    public let authority: LANV6Authority
    public let activeGeneration: UInt32?
    public let pendingGeneration: UInt32
    public let epoch: LANSessionEpochV6
    public let handshakeID: LANHandshakeIDV6
    public let opaqueSocketGeneration: UInt32
    public let rawPendingToken: LANV6Token256

    public init(
        authority: LANV6Authority,
        activeGeneration: UInt32?,
        pendingGeneration: UInt32,
        epoch: LANSessionEpochV6,
        handshakeID: LANHandshakeIDV6,
        opaqueSocketGeneration: UInt32,
        rawPendingToken: LANV6Token256
    ) throws {
        try LANV6HandshakeValidation.requireGenerations(
            active: activeGeneration,
            pending: pendingGeneration
        )
        try LANV6HandshakeValidation.requireGuestAuthority(authority)
        guard opaqueSocketGeneration > 0,
              opaqueSocketGeneration <= LAN_V6_MAX_COUNTER
        else {
            throw LANV6HandshakeMessageError.invalidSocketGeneration
        }
        self.authority = authority
        self.activeGeneration = activeGeneration
        self.pendingGeneration = pendingGeneration
        self.epoch = epoch
        self.handshakeID = handshakeID
        self.opaqueSocketGeneration = opaqueSocketGeneration
        self.rawPendingToken = rawPendingToken
    }

    public static func decodeStrict(_ data: Data) throws -> LANClientReadyV6 {
        let scan = try LANV6StrictJSON.scan(data, limits: .lanV6Handshake)
        try scan.requireTopLevelObject(exactKeys: [
            "authority", "activeGeneration", "pendingGeneration", "epoch",
            "handshakeID", "opaqueSocketGeneration", "rawPendingToken",
        ])
        try scan.requireCanonicalUnsignedIntegerIfPresent(
            atKeyPath: ["activeGeneration"]
        )
        try scan.requireCanonicalUnsignedInteger(atKeyPath: ["pendingGeneration"])
        try scan.requireCanonicalUnsignedInteger(atKeyPath: ["opaqueSocketGeneration"])
        let wire = try LANV6HandshakeJSON.decode(ClientReadyWire.self, from: data)
        return try LANClientReadyV6(
            authority: wire.authority,
            activeGeneration: wire.activeGeneration,
            pendingGeneration: wire.pendingGeneration,
            epoch: wire.epoch,
            handshakeID: wire.handshakeID,
            opaqueSocketGeneration: wire.opaqueSocketGeneration,
            rawPendingToken: wire.rawPendingToken
        )
    }

    public func encoded() throws -> Data {
        try LANV6HandshakeJSON.encode(ClientReadyWire(self))
    }

    public var description: String {
        "LANClientReadyV6(authority: <redacted>, " +
            "activeGeneration: \(String(describing: activeGeneration)), " +
            "pendingGeneration: \(pendingGeneration), epoch: <redacted>, " +
            "handshakeID: <redacted>, " +
            "opaqueSocketGeneration: <redacted>, " +
            "rawPendingToken: <redacted>)"
    }
}

// MARK: - Named fail-closed frame policies

public extension LANV6FrameAdmissionPolicy {
    static var hostAwaitingHelloV6: LANV6FrameAdmissionPolicy {
        lanV6Policy(
            role: .host, phase: .awaitingHello,
            inbound: [.clientHello], outbound: [.serverReject, .disconnect]
        )
    }

    static var hostAwaitingClientReadyV6: LANV6FrameAdmissionPolicy {
        lanV6Policy(
            role: .host, phase: .awaitingClientReady,
            inbound: [.clientReady, .disconnect],
            outbound: [.serverAccept, .serverReject, .disconnect]
        )
    }

    static var hostReadyAwaitingOwnerBudgetV6: LANV6FrameAdmissionPolicy {
        lanV6Policy(
            role: .host, phase: .readyAwaitingOwnerBudget,
            inbound: [.disconnect],
            outbound: [.serverReject, .disconnect]
        )
    }

    static var hostAuthenticatedV6: LANV6FrameAdmissionPolicy {
        lanV6Policy(
            role: .host, phase: .authenticated,
            inbound: [
                .chat, .ping, .pong, .disconnect, .inputIntent,
                .blockIntent, .containerIntent, .templateIntent, .chunkRequest,
                .replicationAck, .attackIntent, .tossIntent, .containerEditIntent,
                .keepalive, .rpgIntent,
            ],
            outbound: [
                .chat, .playerState, .worldSummary, .ping, .pong, .disconnect,
                .replicationBatch, .gameplayEvent, .inventoryUpdate, .inventoryGrant,
                .restoreState, .damageEvent, .keepalive, .ownerManifest, .ownerChunk,
            ]
        )
    }

    static var hostClosingV6: LANV6FrameAdmissionPolicy { .denyAll }

    static var clientConnectingV6: LANV6FrameAdmissionPolicy {
        lanV6Policy(role: .client, phase: .connecting, outbound: [.clientHello])
    }

    static var clientAwaitingServerAcceptV6: LANV6FrameAdmissionPolicy {
        lanV6Policy(
            role: .client, phase: .awaitingServerAccept,
            inbound: [.serverAccept, .serverReject, .disconnect],
            outbound: [.disconnect]
        )
    }

    static var clientAwaitingInitialOwnerV6: LANV6FrameAdmissionPolicy {
        lanV6Policy(
            role: .client, phase: .awaitingInitialOwner,
            inbound: [.serverReject, .disconnect, .ownerManifest, .ownerChunk],
            outbound: [.clientReady, .disconnect]
        )
    }

    static var clientConnectedV6: LANV6FrameAdmissionPolicy {
        lanV6Policy(
            role: .client, phase: .connected,
            inbound: [
                .chat, .playerState, .worldSummary, .ping, .pong, .disconnect,
                .replicationBatch, .gameplayEvent, .inventoryUpdate, .inventoryGrant,
                .restoreState, .damageEvent, .keepalive, .ownerManifest, .ownerChunk,
            ],
            outbound: [
                .chat, .ping, .pong, .disconnect, .inputIntent,
                .blockIntent, .containerIntent, .templateIntent, .chunkRequest,
                .replicationAck, .attackIntent, .tossIntent, .containerEditIntent,
                .keepalive, .rpgIntent,
            ]
        )
    }

    static var clientRejectedV6: LANV6FrameAdmissionPolicy { .denyAll }

    static func handshakeV6(
        localRole: LANV6LocalRole,
        phase: LANV6ConnectionPhase
    ) -> LANV6FrameAdmissionPolicy {
        switch (localRole, phase) {
        case (.host, .awaitingHello): return .hostAwaitingHelloV6
        case (.host, .awaitingClientReady): return .hostAwaitingClientReadyV6
        case (.host, .readyAwaitingOwnerBudget): return .hostReadyAwaitingOwnerBudgetV6
        case (.host, .authenticated): return .hostAuthenticatedV6
        case (.host, .closing): return .hostClosingV6
        case (.client, .connecting): return .clientConnectingV6
        case (.client, .awaitingServerAccept): return .clientAwaitingServerAcceptV6
        case (.client, .awaitingInitialOwner): return .clientAwaitingInitialOwnerV6
        case (.client, .connected): return .clientConnectedV6
        case (.client, .rejected): return .clientRejectedV6
        default: return .denyAll
        }
    }
}

// MARK: - Private typed wire forms

private extension LANV6StrictJSONLimits {
    static let lanV6Handshake = LANV6StrictJSONLimits(
        maximumBytes: LAN_V6_HANDSHAKE_JSON_LIMIT,
        maximumDepth: 4,
        maximumMembers: 32,
        maximumStringBytes: 256
    )
}

private enum LANV6HandshakeJSON {
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

private enum LANV6HandshakeValidation {
    static func requireIdentity(
        hostInstallationID: LANHostInstallationIDV6,
        worldLANID: LANWorldIDV6,
        lookupDigest: LANV6SHA256Digest
    ) throws {
        let expected = LANV6Crypto.lookupDigest(
            hostInstallationID: hostInstallationID,
            worldLANID: worldLANID
        )
        guard LANV6Crypto.constantTimeEqual(lookupDigest, expected) else {
            throw LANV6HandshakeMessageError.advertisedIdentityMismatch
        }
    }

    static func requireGenerations(active: UInt32?, pending: UInt32) throws {
        guard pending >= 1, pending <= LAN_V6_MAX_COUNTER else {
            throw LANV6HandshakeMessageError.invalidCredentialGeneration
        }
        if let active {
            guard active >= 1,
                  active < LAN_V6_MAX_COUNTER,
                  pending == active + 1
            else {
                throw LANV6HandshakeMessageError.invalidCredentialGeneration
            }
        } else if pending != 1 {
            throw LANV6HandshakeMessageError.invalidCredentialGeneration
        }
    }

    static func requireGuestAuthority(_ authority: LANV6Authority) throws {
        guard authority.joinedOrdinal != nil else {
            throw LANV6HandshakeMessageError.invalidPeerAuthority
        }
    }
}

private struct ClientHelloWire: Codable {
    let pv: UInt16
    let hid: LANHostInstallationIDV6
    let wid: LANWorldIDV6
    let lk: LANV6SHA256Digest
    let playerName: LANV6DisplayName
    let admission: AdmissionWire

    init(_ value: LANClientHelloV6) {
        pv = value.protocolVersion
        hid = value.hostInstallationID
        wid = value.worldLANID
        lk = value.lookupDigest
        playerName = value.playerName
        admission = AdmissionWire(value.admission)
    }
}

/// Deliberately omits `admission`, allowing the host to bind the advertised
/// public tuple before any raw token or nonce is semantically decoded.
private struct ClientHelloCommonWire: Decodable {
    let pv: UInt16
    let hid: LANHostInstallationIDV6
    let wid: LANWorldIDV6
    let lk: LANV6SHA256Digest
    let playerName: LANV6DisplayName
}

private struct ServerRejectWire: Codable {
    let reason: LANV6ServerRejectReason
}

private struct AdmissionWire: Codable {
    enum Kind: String, Codable {
        case joinNew
        case resume
        case legacyClaim
        case legacyConsume
    }

    let value: LANV6ClientAdmissionV6

    init(_ value: LANV6ClientAdmissionV6) {
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case joinCode
        case rawToken
        case legacyHint
        case rawClaimNonce
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .joinNew:
            value = .joinNew(joinCode: try container.decode(LANV6JoinCode.self, forKey: .joinCode))
        case .resume:
            value = .resume(rawToken: try container.decode(LANV6Token256.self, forKey: .rawToken))
        case .legacyClaim:
            value = .legacyClaim(
                joinCode: try container.decode(LANV6JoinCode.self, forKey: .joinCode),
                legacyHint: try container.decodeIfPresent(LANV6LegacyHint.self, forKey: .legacyHint),
                rawClaimNonce: try container.decode(LANV6ClaimNonce.self, forKey: .rawClaimNonce)
            )
        case .legacyConsume:
            value = .legacyConsume(
                rawClaimNonce: try container.decode(LANV6ClaimNonce.self, forKey: .rawClaimNonce)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch value {
        case .joinNew(let joinCode):
            try container.encode(Kind.joinNew, forKey: .kind)
            try container.encode(joinCode, forKey: .joinCode)
        case .resume(let rawToken):
            try container.encode(Kind.resume, forKey: .kind)
            try container.encode(rawToken, forKey: .rawToken)
        case .legacyClaim(let joinCode, let legacyHint, let rawClaimNonce):
            try container.encode(Kind.legacyClaim, forKey: .kind)
            try container.encode(joinCode, forKey: .joinCode)
            if let legacyHint {
                try container.encode(legacyHint, forKey: .legacyHint)
            } else {
                try container.encodeNil(forKey: .legacyHint)
            }
            try container.encode(rawClaimNonce, forKey: .rawClaimNonce)
        case .legacyConsume(let rawClaimNonce):
            try container.encode(Kind.legacyConsume, forKey: .kind)
            try container.encode(rawClaimNonce, forKey: .rawClaimNonce)
        }
    }
}

private struct ServerAcceptWire: Codable {
    let pv: UInt16
    let hid: LANHostInstallationIDV6
    let wid: LANWorldIDV6
    let lk: LANV6SHA256Digest
    let authority: LANV6Authority
    let activeGeneration: UInt32?
    let pendingGeneration: UInt32
    let handshakeID: LANHandshakeIDV6
    let opaqueSocketGeneration: UInt32
    let epoch: LANSessionEpochV6
    let rawPendingToken: LANV6Token256?

    private enum CodingKeys: String, CodingKey {
        case pv, hid, wid, lk, authority, activeGeneration, pendingGeneration
        case handshakeID, opaqueSocketGeneration, epoch, rawPendingToken
    }

    init(_ value: LANServerAcceptV6) {
        pv = value.protocolVersion
        hid = value.hostInstallationID
        wid = value.worldLANID
        lk = value.lookupDigest
        authority = value.authority
        activeGeneration = value.activeGeneration
        pendingGeneration = value.pendingGeneration
        handshakeID = value.handshakeID
        opaqueSocketGeneration = value.opaqueSocketGeneration
        epoch = value.epoch
        rawPendingToken = value.credentialDelivery.rawPendingToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pv = try container.decode(UInt16.self, forKey: .pv)
        hid = try container.decode(LANHostInstallationIDV6.self, forKey: .hid)
        wid = try container.decode(LANWorldIDV6.self, forKey: .wid)
        lk = try container.decode(LANV6SHA256Digest.self, forKey: .lk)
        authority = try container.decode(LANV6Authority.self, forKey: .authority)
        activeGeneration = try container.decodeIfPresent(UInt32.self, forKey: .activeGeneration)
        pendingGeneration = try container.decode(UInt32.self, forKey: .pendingGeneration)
        handshakeID = try container.decode(LANHandshakeIDV6.self, forKey: .handshakeID)
        opaqueSocketGeneration = try container.decode(UInt32.self, forKey: .opaqueSocketGeneration)
        epoch = try container.decode(LANSessionEpochV6.self, forKey: .epoch)
        rawPendingToken = try container.decodeIfPresent(LANV6Token256.self, forKey: .rawPendingToken)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pv, forKey: .pv)
        try container.encode(hid, forKey: .hid)
        try container.encode(wid, forKey: .wid)
        try container.encode(lk, forKey: .lk)
        try container.encode(authority, forKey: .authority)
        if let activeGeneration {
            try container.encode(activeGeneration, forKey: .activeGeneration)
        } else {
            try container.encodeNil(forKey: .activeGeneration)
        }
        try container.encode(pendingGeneration, forKey: .pendingGeneration)
        try container.encode(handshakeID, forKey: .handshakeID)
        try container.encode(opaqueSocketGeneration, forKey: .opaqueSocketGeneration)
        try container.encode(epoch, forKey: .epoch)
        if let rawPendingToken {
            try container.encode(rawPendingToken, forKey: .rawPendingToken)
        }
    }
}

/// Deliberately omits the optional raw pending token so an invite/Bonjour
/// client can bind the echoed public tuple before decoding credential bytes.
private struct ServerAcceptCommonWire: Decodable {
    let pv: UInt16
    let hid: LANHostInstallationIDV6
    let wid: LANWorldIDV6
    let lk: LANV6SHA256Digest
}

private struct ClientReadyWire: Codable {
    let authority: LANV6Authority
    let activeGeneration: UInt32?
    let pendingGeneration: UInt32
    let epoch: LANSessionEpochV6
    let handshakeID: LANHandshakeIDV6
    let opaqueSocketGeneration: UInt32
    let rawPendingToken: LANV6Token256

    private enum CodingKeys: String, CodingKey {
        case authority, activeGeneration, pendingGeneration, epoch, handshakeID
        case opaqueSocketGeneration, rawPendingToken
    }

    init(_ value: LANClientReadyV6) {
        authority = value.authority
        activeGeneration = value.activeGeneration
        pendingGeneration = value.pendingGeneration
        epoch = value.epoch
        handshakeID = value.handshakeID
        opaqueSocketGeneration = value.opaqueSocketGeneration
        rawPendingToken = value.rawPendingToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authority = try container.decode(LANV6Authority.self, forKey: .authority)
        activeGeneration = try container.decodeIfPresent(UInt32.self, forKey: .activeGeneration)
        pendingGeneration = try container.decode(UInt32.self, forKey: .pendingGeneration)
        epoch = try container.decode(LANSessionEpochV6.self, forKey: .epoch)
        handshakeID = try container.decode(LANHandshakeIDV6.self, forKey: .handshakeID)
        opaqueSocketGeneration = try container.decode(UInt32.self, forKey: .opaqueSocketGeneration)
        rawPendingToken = try container.decode(LANV6Token256.self, forKey: .rawPendingToken)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authority, forKey: .authority)
        if let activeGeneration {
            try container.encode(activeGeneration, forKey: .activeGeneration)
        } else {
            try container.encodeNil(forKey: .activeGeneration)
        }
        try container.encode(pendingGeneration, forKey: .pendingGeneration)
        try container.encode(epoch, forKey: .epoch)
        try container.encode(handshakeID, forKey: .handshakeID)
        try container.encode(opaqueSocketGeneration, forKey: .opaqueSocketGeneration)
        try container.encode(rawPendingToken, forKey: .rawPendingToken)
    }
}

private func lanV6Policy(
    role: LANV6LocalRole,
    phase: LANV6ConnectionPhase,
    inbound: [LANV6MessageKind] = [],
    outbound: [LANV6MessageKind] = []
) -> LANV6FrameAdmissionPolicy {
    let inboundKeys = inbound.map {
        LANV6FrameAdmissionKey(localRole: role, phase: phase, flow: .inbound, kind: $0)
    }
    let outboundKeys = outbound.map {
        LANV6FrameAdmissionKey(localRole: role, phase: phase, flow: .outbound, kind: $0)
    }
    return LANV6FrameAdmissionPolicy(inboundKeys + outboundKeys)
}
