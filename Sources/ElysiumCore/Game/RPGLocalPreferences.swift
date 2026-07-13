import CryptoKit
import Foundation

public enum RPGLocalPreferenceScopeError: Error, Equatable {
    case invalidLocalWorldRecordID
    case invalidScopeEncoding
}

public enum RPGLocalPreferenceScope: Hashable, Codable, Sendable {
    case localWorld(worldRecordID: String)
    case lanV6(hostInstallationID: LANHostInstallationIDV6, worldLANID: LANWorldIDV6)

    private enum CodingKeys: String, CodingKey { case kind, worldRecordID, hostInstallationID, worldLANID }
    private enum Kind: String, Codable { case localWorld, lanV6 }

    public static func validatedLocalWorld(_ worldRecordID: String) throws -> RPGLocalPreferenceScope {
        guard !worldRecordID.isEmpty, worldRecordID.utf8.count <= 64 else {
            throw RPGLocalPreferenceScopeError.invalidLocalWorldRecordID
        }
        return .localWorld(worldRecordID: worldRecordID)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .localWorld:
            let id = try container.decode(String.self, forKey: .worldRecordID)
            self = try Self.validatedLocalWorld(id)
        case .lanV6:
            self = .lanV6(
                hostInstallationID: try container.decode(LANHostInstallationIDV6.self,
                                                         forKey: .hostInstallationID),
                worldLANID: try container.decode(LANWorldIDV6.self, forKey: .worldLANID)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .localWorld(let id):
            guard !id.isEmpty, id.utf8.count <= 64 else {
                throw EncodingError.invalidValue(id, EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "Local world record ID must contain 1...64 UTF-8 bytes"
                ))
            }
            try container.encode(Kind.localWorld, forKey: .kind)
            try container.encode(id, forKey: .worldRecordID)
        case .lanV6(let hostID, let worldID):
            try container.encode(Kind.lanV6, forKey: .kind)
            try container.encode(hostID, forKey: .hostInstallationID)
            try container.encode(worldID, forKey: .worldLANID)
        }
    }
}

public enum RPGExpectedLivePreferenceRevision: Equatable, Sendable {
    case absent
    case exact(UInt64)
}

/// Process-local provenance for one local quick-slot storage operation. The storage API deliberately
/// does not accept this value: GameCore owns session validity and must revalidate it after I/O.
public struct RPGLocalPreferenceRequestContext: Equatable, Sendable {
    public let scope: RPGLocalPreferenceScope
    public let worldEntryGeneration: UInt64
    public let expectedLiveRevision: RPGExpectedLivePreferenceRevision
    public let operationID: UInt64

    public init(scope: RPGLocalPreferenceScope, worldEntryGeneration: UInt64,
                expectedLiveRevision: RPGExpectedLivePreferenceRevision,
                operationID: UInt64) throws {
        guard worldEntryGeneration > 0, operationID > 0 else {
            throw RPGLocalPreferenceLifecycleError.invalidProvenance
        }
        guard case .localWorld = scope else {
            throw RPGLocalPreferenceLifecycleError.unsupportedScope
        }
        self.scope = scope
        self.worldEntryGeneration = worldEntryGeneration
        self.expectedLiveRevision = expectedLiveRevision
        self.operationID = operationID
    }
}

public struct RPGLocalPreferenceCompletion<Value> {
    public let context: RPGLocalPreferenceRequestContext
    public let result: Result<Value, Error>

    public init(context: RPGLocalPreferenceRequestContext, result: Result<Value, Error>) {
        self.context = context
        self.result = result
    }
}

public enum RPGLocalPreferenceLifecycleError: Error, Equatable {
    case invalidProvenance
    case unsupportedScope
    case generationExhausted
    case operationExhausted
    case revisionExhausted
    case unavailable
}

public struct RPGQuickSlotPreferences: Codable, Equatable, Sendable {
    public let tokens: [String?]

    public init(tokens: [String?]) {
        var normalized = Array(repeating: Optional<String>.none, count: RPG_ACTION_QUICK_SLOT_COUNT)
        for index in 0..<min(tokens.count, RPG_ACTION_QUICK_SLOT_COUNT) {
            guard let token = tokens[index], token.utf8.count <= 128,
                  let parsed = rpgParsePreparedActionToken(token) else { continue }
            normalized[index] = rpgPreparedActionToken(kind: parsed.kind, id: parsed.id)
        }
        self.tokens = normalized
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard container.count == RPG_ACTION_QUICK_SLOT_COUNT else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "RPG quick-slot preferences must contain exactly nine entries")
        }
        var decoded: [String?] = []
        decoded.reserveCapacity(RPG_ACTION_QUICK_SLOT_COUNT)
        var totalBytes = 0
        while !container.isAtEnd {
            if try container.decodeNil() {
                decoded.append(nil)
            } else {
                let value = try container.decode(String.self)
                guard value.utf8.count <= 128, let parsed = rpgParsePreparedActionToken(value) else {
                    throw DecodingError.dataCorruptedError(in: container,
                        debugDescription: "Invalid RPG quick-slot token")
                }
                totalBytes += value.utf8.count
                guard totalBytes <= 1_152 else {
                    throw DecodingError.dataCorruptedError(in: container,
                        debugDescription: "RPG quick-slot token budget exceeded")
                }
                decoded.append(rpgPreparedActionToken(kind: parsed.kind, id: parsed.id))
            }
        }
        self.tokens = decoded
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for token in tokens {
            if let token { try container.encode(token) } else { try container.encodeNil() }
        }
    }

    public static let empty = RPGQuickSlotPreferences(tokens: [])
}

/// The bounded compatibility copy extracted from pre-migration player JSON. It remains resident
/// after a migration receipt so a failed player-row write can never destroy the last durable copy.
/// `omissionEligible` only changes after GameCore validates the exact session and immutable origin.
public struct RPGLegacyQuickSlotEnvelope: Equatable, Sendable {
    public let preferences: RPGQuickSlotPreferences
    public let envelopeVersion: UInt64
    public let sourceDigest: LANV6SHA256Digest
    public private(set) var omissionEligible: Bool

    public init(preferences: RPGQuickSlotPreferences, envelopeVersion: UInt64) throws {
        guard envelopeVersion > 0 else { throw RPGLocalPreferenceLifecycleError.invalidProvenance }
        self.preferences = preferences
        self.envelopeVersion = envelopeVersion
        self.sourceDigest = try rpgLegacyQuickSlotSourceDigest(preferences)
        self.omissionEligible = false
    }

    public mutating func markOmissionEligible(
        envelopeVersion: UInt64, sourceDigest: LANV6SHA256Digest
    ) -> Bool {
        guard self.envelopeVersion == envelopeVersion, self.sourceDigest == sourceDigest else {
            return false
        }
        omissionEligible = true
        return true
    }
}

/// Strictly extracts the legacy field without allowing it to expand the already-bounded player
/// payload. Invalid tokens normalize to nil, matching the historical state repair behavior.
public func rpgExtractLegacyQuickSlotEnvelope(from raw: Any?, envelopeVersion: UInt64 = 1)
    -> RPGLegacyQuickSlotEnvelope? {
    guard envelopeVersion > 0, let values = raw as? [Any], values.count <= RPG_ACTION_QUICK_SLOT_COUNT,
          JSONSerialization.isValidJSONObject(values),
          let encoded = try? JSONSerialization.data(withJSONObject: values), encoded.count <= 2_048
    else { return nil }
    var slots = Array(repeating: Optional<String>.none, count: RPG_ACTION_QUICK_SLOT_COUNT)
    var totalBytes = 0
    for (index, value) in values.enumerated() {
        if value is NSNull { continue }
        guard let token = value as? String, token.utf8.count <= 128 else { return nil }
        totalBytes += token.utf8.count
        guard totalBytes <= 1_152 else { return nil }
        slots[index] = rpgParsePreparedActionToken(token).map {
            rpgPreparedActionToken(kind: $0.kind, id: $0.id)
        }
    }
    return try? RPGLegacyQuickSlotEnvelope(
        preferences: RPGQuickSlotPreferences(tokens: slots), envelopeVersion: envelopeVersion)
}

public enum RPGQuickSlotPreferenceError: Error, Equatable {
    case characterNotCreated
    case invalidSlot(Int)
    case actionNotPrepared(String)
}

private func preparedActionTokens(_ state: RPGCharacterState) -> [String] {
    rpgPreparedActions(state).map(\.token)
}

public func rpgNormalizeQuickSlotPreferences(_ raw: RPGQuickSlotPreferences,
                                             against repairedState: RPGCharacterState) -> RPGQuickSlotPreferences {
    guard repairedState.created else { return .empty }
    let available = Set(preparedActionTokens(repairedState))
    var used = Set<String>()
    var output = Array(repeating: Optional<String>.none, count: RPG_ACTION_QUICK_SLOT_COUNT)
    for index in output.indices {
        guard let token = raw.tokens[index], available.contains(token), used.insert(token).inserted else { continue }
        output[index] = token
    }
    return RPGQuickSlotPreferences(tokens: output)
}

public func rpgDefaultQuickSlotPreferences(for repairedState: RPGCharacterState) -> RPGQuickSlotPreferences {
    RPGQuickSlotPreferences(tokens: Array(preparedActionTokens(repairedState).prefix(RPG_ACTION_QUICK_SLOT_COUNT)))
}

public func rpgAssignQuickSlot(token: String, slot: Int,
                               preferences: RPGQuickSlotPreferences,
                               state: RPGCharacterState) -> Result<RPGQuickSlotPreferences, RPGQuickSlotPreferenceError> {
    guard state.created else { return .failure(.characterNotCreated) }
    guard (0..<RPG_ACTION_QUICK_SLOT_COUNT).contains(slot) else { return .failure(.invalidSlot(slot)) }
    let canonical = rpgParsePreparedActionToken(token).map { rpgPreparedActionToken(kind: $0.kind, id: $0.id) }
    guard let canonical, preparedActionTokens(state).contains(canonical) else {
        return .failure(.actionNotPrepared(token))
    }
    var tokens = rpgNormalizeQuickSlotPreferences(preferences, against: state).tokens
    for index in tokens.indices where tokens[index] == canonical { tokens[index] = nil }
    tokens[slot] = canonical
    return .success(RPGQuickSlotPreferences(tokens: tokens))
}

public func rpgMoveQuickSlot(from: Int, to: Int,
                             preferences: RPGQuickSlotPreferences,
                             state: RPGCharacterState) -> Result<RPGQuickSlotPreferences, RPGQuickSlotPreferenceError> {
    guard state.created else { return .failure(.characterNotCreated) }
    guard (0..<RPG_ACTION_QUICK_SLOT_COUNT).contains(from) else { return .failure(.invalidSlot(from)) }
    guard (0..<RPG_ACTION_QUICK_SLOT_COUNT).contains(to) else { return .failure(.invalidSlot(to)) }
    var tokens = rpgNormalizeQuickSlotPreferences(preferences, against: state).tokens
    let moved = tokens[from]
    tokens[from] = tokens[to]
    tokens[to] = moved
    return .success(RPGQuickSlotPreferences(tokens: tokens))
}

public func rpgClearQuickSlot(_ slot: Int,
                              preferences: RPGQuickSlotPreferences,
                              state: RPGCharacterState) -> Result<RPGQuickSlotPreferences, RPGQuickSlotPreferenceError> {
    guard state.created else { return .failure(.characterNotCreated) }
    guard (0..<RPG_ACTION_QUICK_SLOT_COUNT).contains(slot) else { return .failure(.invalidSlot(slot)) }
    var tokens = rpgNormalizeQuickSlotPreferences(preferences, against: state).tokens
    tokens[slot] = nil
    return .success(RPGQuickSlotPreferences(tokens: tokens))
}

public func rpgQuickSlotActions(state: RPGCharacterState,
                                preferences: RPGQuickSlotPreferences) -> [RPGPreparedAction?] {
    let actions = rpgPreparedActions(state)
    let byToken = Dictionary(uniqueKeysWithValues: actions.map { ($0.token, $0) })
    return rpgNormalizeQuickSlotPreferences(preferences, against: state).tokens.map { token in
        token.flatMap { byToken[$0] }
    }
}

public enum RPGQuickSlotStorageCodecError: Error, Equatable {
    case invalidSlotCount
    case invalidToken
    case duplicateToken
    case malformedPayload
}

public func rpgEncodeQuickSlotPreferencesStoragePayload(
    _ preferences: RPGQuickSlotPreferences
) throws -> Data {
    guard preferences.tokens.count == RPG_ACTION_QUICK_SLOT_COUNT else {
        throw RPGQuickSlotStorageCodecError.invalidSlotCount
    }
    var payload = Data("PBLQS1".utf8)
    payload.append(0); payload.append(1)
    payload.append(UInt8(RPG_ACTION_QUICK_SLOT_COUNT))
    var used = Set<String>()
    for token in preferences.tokens {
        guard let token else { payload.append(0); continue }
        guard let parsed = rpgParsePreparedActionToken(token),
              token == rpgPreparedActionToken(kind: parsed.kind, id: parsed.id),
              !parsed.id.isEmpty, parsed.id.utf8.count <= 64,
              (1...128).contains(token.utf8.count) else {
            throw RPGQuickSlotStorageCodecError.invalidToken
        }
        guard used.insert(token).inserted else {
            throw RPGQuickSlotStorageCodecError.duplicateToken
        }
        payload.append(1)
        let count = UInt16(token.utf8.count)
        payload.append(UInt8(truncatingIfNeeded: count >> 8))
        payload.append(UInt8(truncatingIfNeeded: count))
        payload.append(contentsOf: token.utf8)
    }
    guard payload.count <= 4_096 else { throw RPGQuickSlotStorageCodecError.invalidToken }
    return payload
}

public func rpgDecodeQuickSlotPreferencesStoragePayload(_ payload: Data) throws
    -> RPGQuickSlotPreferences {
    let bytes = [UInt8](payload)
    guard bytes.count >= 18, bytes.count <= 4_096,
          Array(bytes[0..<6]) == Array("PBLQS1".utf8),
          bytes[6] == 0, bytes[7] == 1,
          bytes[8] == UInt8(RPG_ACTION_QUICK_SLOT_COUNT) else {
        throw RPGQuickSlotStorageCodecError.malformedPayload
    }
    var cursor = 9
    var tokens: [String?] = []
    var used = Set<String>()
    for _ in 0..<RPG_ACTION_QUICK_SLOT_COUNT {
        guard cursor < bytes.count else { throw RPGQuickSlotStorageCodecError.malformedPayload }
        let tag = bytes[cursor]; cursor += 1
        if tag == 0 { tokens.append(nil); continue }
        guard tag == 1, cursor + 2 <= bytes.count else {
            throw RPGQuickSlotStorageCodecError.malformedPayload
        }
        let count = Int(bytes[cursor]) << 8 | Int(bytes[cursor + 1]); cursor += 2
        guard (1...128).contains(count), cursor + count <= bytes.count,
              let token = String(data: Data(bytes[cursor..<(cursor + count)]), encoding: .utf8),
              let parsed = rpgParsePreparedActionToken(token),
              token == rpgPreparedActionToken(kind: parsed.kind, id: parsed.id),
              !parsed.id.isEmpty, parsed.id.utf8.count <= 64 else {
            throw RPGQuickSlotStorageCodecError.invalidToken
        }
        guard used.insert(token).inserted else {
            throw RPGQuickSlotStorageCodecError.duplicateToken
        }
        tokens.append(token); cursor += count
    }
    guard cursor == bytes.count else { throw RPGQuickSlotStorageCodecError.malformedPayload }
    return RPGQuickSlotPreferences(tokens: tokens)
}

private struct RPGCanonicalDigestEncoder {
    var data = Data()

    mutating func appendDomain(_ value: String) {
        data.append(contentsOf: value.utf8)
        data.append(0)
    }

    mutating func append(_ value: UInt32) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    mutating func append(_ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    mutating func append(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    mutating func appendBytes(_ bytes: [UInt8]) {
        append(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    mutating func appendString(_ value: String) { appendBytes(Array(value.utf8)) }

    mutating func appendSlots(_ preferences: RPGQuickSlotPreferences) {
        for token in preferences.tokens {
            if let token {
                data.append(1)
                appendString(token)
            } else {
                data.append(0)
            }
        }
    }
}

private func digest(_ data: Data) -> LANV6SHA256Digest {
    // CryptoKit's SHA256 output is fixed at 32 bytes, so this cannot fail.
    try! LANV6SHA256Digest(bytes: Array(SHA256.hash(data: data)))
}

public func rpgLegacyQuickSlotSourceDigest(_ preferences: RPGQuickSlotPreferences,
                                           envelopeVersion: UInt16 = 1) throws
    -> LANV6SHA256Digest {
    var encoder = RPGCanonicalDigestEncoder()
    encoder.appendDomain("Pebble/RPGLegacyQuickSlots/source/v1")
    encoder.append(envelopeVersion)
    encoder.data.append(try rpgEncodeQuickSlotPreferencesStoragePayload(preferences))
    return digest(encoder.data)
}

public func rpgQuickSlotDestinationDigest(scope: RPGLocalPreferenceScope,
                                          preferences: RPGQuickSlotPreferences,
                                          schemaVersion: UInt16 = 1,
                                          revision: UInt64) throws -> LANV6SHA256Digest {
    var encoder = RPGCanonicalDigestEncoder()
    encoder.appendDomain("Pebble/RPGLocalQuickSlots/destination/v1")
    switch scope {
    case .localWorld(let id):
        guard !id.isEmpty, id.utf8.count <= 64 else {
            throw RPGLocalPreferenceScopeError.invalidLocalWorldRecordID
        }
        encoder.appendString(id)
    case .lanV6:
        throw RPGLocalPreferenceScopeError.invalidScopeEncoding
    }
    encoder.append(schemaVersion)
    encoder.append(revision)
    encoder.data.append(try rpgEncodeQuickSlotPreferencesStoragePayload(preferences))
    return digest(encoder.data)
}
