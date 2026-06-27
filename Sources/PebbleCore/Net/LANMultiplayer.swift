import Foundation

public let LAN_MULTIPLAYER_PROTOCOL_VERSION: UInt16 = 1
public let LAN_MULTIPLAYER_SERVICE_TYPE = "_pebble-lan._tcp"
public let LAN_MULTIPLAYER_DEFAULT_PORT: UInt16 = 41337
public let LAN_MULTIPLAYER_MAX_CLIENTS = 8
public let LAN_MULTIPLAYER_MAX_FRAME_BYTES = 1_048_576
public let LAN_MULTIPLAYER_MAX_PLAYER_NAME_CHARS = 32
public let LAN_MULTIPLAYER_MAX_CHAT_BYTES = 512
public let LAN_MULTIPLAYER_MAX_WORLD_NAME_CHARS = 64

private let LANFrameMagic: [UInt8] = [0x50, 0x42, 0x4c, 0x4e] // PBLN

public enum LANMultiplayerRole: String, Codable, Equatable {
    case host
    case client
}

public enum LANMultiplayerConnectionState: String, Codable, Equatable {
    case idle
    case browsing
    case hosting
    case connecting
    case connected
    case rejected
    case failed
}

public enum LANMultiplayerMessageKind: UInt16, Codable, Equatable, CaseIterable {
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
}

public struct LANWorldSummary: Codable, Equatable {
    public var worldID: String
    public var worldName: String
    public var seed: Int64
    public var gameMode: Int
    public var difficulty: Int
    public var dimension: Int
    public var playerCount: Int
    public var maxPlayers: Int
    public var pebbleVersion: String

    public init(
        worldID: String,
        worldName: String,
        seed: Int64,
        gameMode: Int,
        difficulty: Int,
        dimension: Int,
        playerCount: Int,
        maxPlayers: Int = LAN_MULTIPLAYER_MAX_CLIENTS,
        pebbleVersion: String = PEBBLE_VERSION
    ) {
        self.worldID = String(worldID.prefix(128))
        self.worldName = sanitizedLANWorldName(worldName)
        self.seed = seed
        self.gameMode = gameMode
        self.difficulty = difficulty
        self.dimension = dimension
        self.playerCount = max(0, min(maxPlayers, playerCount))
        self.maxPlayers = max(1, min(LAN_MULTIPLAYER_MAX_CLIENTS, maxPlayers))
        self.pebbleVersion = pebbleVersion
    }
}

public struct LANPlayerState: Codable, Equatable {
    public var playerID: String
    public var displayName: String
    public var x: Double
    public var y: Double
    public var z: Double
    public var yaw: Double
    public var pitch: Double
    public var health: Double
    public var hunger: Int
    public var selectedHotbarSlot: Int
    public var gameMode: Int

    public init(
        playerID: String,
        displayName: String,
        x: Double,
        y: Double,
        z: Double,
        yaw: Double,
        pitch: Double,
        health: Double,
        hunger: Int,
        selectedHotbarSlot: Int,
        gameMode: Int
    ) {
        self.playerID = String(playerID.prefix(128))
        self.displayName = sanitizedLANPlayerName(displayName)
        self.x = x
        self.y = y
        self.z = z
        self.yaw = yaw
        self.pitch = pitch
        self.health = health
        self.hunger = max(0, min(20, hunger))
        self.selectedHotbarSlot = max(0, min(8, selectedHotbarSlot))
        self.gameMode = gameMode
    }
}

public struct LANInputIntent: Codable, Equatable {
    public var forward: Double
    public var strafe: Double
    public var jump: Bool
    public var sneak: Bool
    public var sprint: Bool
    public var flyingUp: Bool
    public var flyingDown: Bool
    public var yaw: Double
    public var pitch: Double
    public var selectedHotbarSlot: Int

    public init(
        forward: Double,
        strafe: Double,
        jump: Bool,
        sneak: Bool,
        sprint: Bool,
        flyingUp: Bool,
        flyingDown: Bool,
        yaw: Double,
        pitch: Double,
        selectedHotbarSlot: Int
    ) {
        self.forward = max(-1, min(1, forward.isFinite ? forward : 0))
        self.strafe = max(-1, min(1, strafe.isFinite ? strafe : 0))
        self.jump = jump
        self.sneak = sneak
        self.sprint = sprint
        self.flyingUp = flyingUp
        self.flyingDown = flyingDown
        self.yaw = yaw.isFinite ? yaw : 0
        self.pitch = pitch.isFinite ? max(-.pi / 2, min(.pi / 2, pitch)) : 0
        self.selectedHotbarSlot = max(0, min(8, selectedHotbarSlot))
    }
}

public struct LANBlockIntent: Codable, Equatable {
    public enum Action: String, Codable, Equatable {
        case breakBlock
        case placeBlock
        case useBlock
    }

    public var action: Action
    public var x: Int
    public var y: Int
    public var z: Int
    public var face: Int
    public var selectedHotbarSlot: Int

    public init(action: Action, x: Int, y: Int, z: Int, face: Int, selectedHotbarSlot: Int) {
        self.action = action
        self.x = x
        self.y = y
        self.z = z
        self.face = max(0, min(5, face))
        self.selectedHotbarSlot = max(0, min(8, selectedHotbarSlot))
    }
}

public struct LANContainerIntent: Codable, Equatable {
    public enum Action: String, Codable, Equatable {
        case open
        case clickSlot
        case close
    }

    public var action: Action
    public var containerID: String
    public var slot: Int
    public var button: Int
    public var shift: Bool

    public init(action: Action, containerID: String, slot: Int, button: Int, shift: Bool) {
        self.action = action
        self.containerID = String(containerID.prefix(128))
        self.slot = max(-1, min(1024, slot))
        self.button = max(0, min(2, button))
        self.shift = shift
    }
}

public struct LANTemplateIntent: Codable, Equatable {
    public enum Action: String, Codable, Equatable {
        case copyTarget
        case placeTemplate
        case undoPlacement
    }

    public var action: Action
    public var templateName: String
    public var x: Int
    public var y: Int
    public var z: Int
    public var rotation: Int

    public init(action: Action, templateName: String, x: Int, y: Int, z: Int, rotation: Int) {
        self.action = action
        self.templateName = sanitizedLANTemplateName(templateName)
        self.x = x
        self.y = y
        self.z = z
        self.rotation = ((rotation % 4) + 4) % 4
    }
}

public enum LANMultiplayerMessage: Codable, Equatable {
    case clientHello(playerID: String, playerName: String, joinCode: String, pebbleVersion: String)
    case serverAccept(peerID: String, world: LANWorldSummary)
    case serverReject(reason: String)
    case chat(sender: String, text: String)
    case playerState(LANPlayerState)
    case worldSummary(LANWorldSummary)
    case ping(nonce: UInt64)
    case pong(nonce: UInt64)
    case disconnect(reason: String)
    case inputIntent(playerID: String, intent: LANInputIntent)
    case blockIntent(playerID: String, intent: LANBlockIntent)
    case containerIntent(playerID: String, intent: LANContainerIntent)
    case templateIntent(playerID: String, intent: LANTemplateIntent)

    public var kind: LANMultiplayerMessageKind {
        switch self {
        case .clientHello: return .clientHello
        case .serverAccept: return .serverAccept
        case .serverReject: return .serverReject
        case .chat: return .chat
        case .playerState: return .playerState
        case .worldSummary: return .worldSummary
        case .ping: return .ping
        case .pong: return .pong
        case .disconnect: return .disconnect
        case .inputIntent: return .inputIntent
        case .blockIntent: return .blockIntent
        case .containerIntent: return .containerIntent
        case .templateIntent: return .templateIntent
        }
    }
}

public struct LANMultiplayerFrame: Equatable {
    public var sequence: UInt32
    public var kind: LANMultiplayerMessageKind
    public var message: LANMultiplayerMessage

    public init(sequence: UInt32, message: LANMultiplayerMessage) {
        self.sequence = sequence
        self.kind = message.kind
        self.message = message
    }
}

public enum LANMultiplayerCodecError: Error, Equatable, CustomStringConvertible {
    case truncated
    case invalidMagic
    case unsupportedVersion(UInt16)
    case unknownMessageType(UInt16)
    case oversizedFrame(Int)
    case payloadTypeMismatch(expected: LANMultiplayerMessageKind, actual: LANMultiplayerMessageKind)
    case decodeFailed(String)

    public var description: String {
        switch self {
        case .truncated: return "LAN frame is truncated"
        case .invalidMagic: return "LAN frame magic is invalid"
        case .unsupportedVersion(let version): return "Unsupported LAN protocol version \(version)"
        case .unknownMessageType(let type): return "Unknown LAN message type \(type)"
        case .oversizedFrame(let count): return "LAN frame is too large (\(count) bytes)"
        case .payloadTypeMismatch(let expected, let actual):
            return "LAN payload type mismatch: expected \(expected), got \(actual)"
        case .decodeFailed(let message): return "LAN payload decode failed: \(message)"
        }
    }
}

public struct LANMultiplayerFrameCodec {
    public static let headerByteCount = 16

    public static func encode(_ message: LANMultiplayerMessage, sequence: UInt32 = 0) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(message)
        if payload.count > LAN_MULTIPLAYER_MAX_FRAME_BYTES {
            throw LANMultiplayerCodecError.oversizedFrame(payload.count)
        }
        var data = Data()
        data.reserveCapacity(headerByteCount + payload.count)
        data.append(contentsOf: LANFrameMagic)
        appendUInt16(LAN_MULTIPLAYER_PROTOCOL_VERSION, to: &data)
        appendUInt16(message.kind.rawValue, to: &data)
        appendUInt32(sequence, to: &data)
        appendUInt32(UInt32(payload.count), to: &data)
        data.append(payload)
        return data
    }

    public static func decode(_ data: Data) throws -> LANMultiplayerFrame {
        guard data.count >= headerByteCount else { throw LANMultiplayerCodecError.truncated }
        for i in 0..<LANFrameMagic.count where data[i] != LANFrameMagic[i] {
            throw LANMultiplayerCodecError.invalidMagic
        }
        let version = readUInt16(data, offset: 4)
        guard version == LAN_MULTIPLAYER_PROTOCOL_VERSION else {
            throw LANMultiplayerCodecError.unsupportedVersion(version)
        }
        let rawType = readUInt16(data, offset: 6)
        guard let kind = LANMultiplayerMessageKind(rawValue: rawType) else {
            throw LANMultiplayerCodecError.unknownMessageType(rawType)
        }
        let sequence = readUInt32(data, offset: 8)
        let length = Int(readUInt32(data, offset: 12))
        guard length <= LAN_MULTIPLAYER_MAX_FRAME_BYTES else {
            throw LANMultiplayerCodecError.oversizedFrame(length)
        }
        guard data.count >= headerByteCount + length else {
            throw LANMultiplayerCodecError.truncated
        }
        let payload = data.subdata(in: headerByteCount..<(headerByteCount + length))
        do {
            let message = try JSONDecoder().decode(LANMultiplayerMessage.self, from: payload)
            guard message.kind == kind else {
                throw LANMultiplayerCodecError.payloadTypeMismatch(expected: kind, actual: message.kind)
            }
            return LANMultiplayerFrame(sequence: sequence, message: message)
        } catch let error as LANMultiplayerCodecError {
            throw error
        } catch {
            throw LANMultiplayerCodecError.decodeFailed(error.localizedDescription)
        }
    }

    public static func decodeFrames(from buffer: inout Data) throws -> [LANMultiplayerFrame] {
        var frames: [LANMultiplayerFrame] = []
        while buffer.count >= headerByteCount {
            for i in 0..<LANFrameMagic.count where buffer[i] != LANFrameMagic[i] {
                throw LANMultiplayerCodecError.invalidMagic
            }
            let version = readUInt16(buffer, offset: 4)
            guard version == LAN_MULTIPLAYER_PROTOCOL_VERSION else {
                throw LANMultiplayerCodecError.unsupportedVersion(version)
            }
            let rawType = readUInt16(buffer, offset: 6)
            guard LANMultiplayerMessageKind(rawValue: rawType) != nil else {
                throw LANMultiplayerCodecError.unknownMessageType(rawType)
            }
            let length = Int(readUInt32(buffer, offset: 12))
            guard length <= LAN_MULTIPLAYER_MAX_FRAME_BYTES else {
                throw LANMultiplayerCodecError.oversizedFrame(length)
            }
            let total = headerByteCount + length
            if buffer.count < total { break }
            let frameData = buffer.subdata(in: 0..<total)
            frames.append(try decode(frameData))
            buffer.removeSubrange(0..<total)
        }
        return frames
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
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32(_ data: Data, offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24) |
        (UInt32(data[offset + 1]) << 16) |
        (UInt32(data[offset + 2]) << 8) |
        UInt32(data[offset + 3])
    }
}

public struct LANDirectConnectTarget: Equatable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public static func parse(host rawHost: String, port rawPort: String) -> LANDirectConnectTarget? {
        let host = sanitizedLANDirectHost(rawHost)
        guard !host.isEmpty, let portValue = UInt16(rawPort), portValue > 0 else { return nil }
        return LANDirectConnectTarget(host: host, port: portValue)
    }
}

public func sanitizedLANPlayerName(_ raw: String) -> String {
    let cleaned = cleanSingleLine(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    let clipped = prefixByUTF8Bytes(String(cleaned.prefix(LAN_MULTIPLAYER_MAX_PLAYER_NAME_CHARS)), maxBytes: 96)
    return clipped.isEmpty ? "Player" : clipped
}

public func sanitizedLANWorldName(_ raw: String) -> String {
    let cleaned = cleanSingleLine(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    let clipped = prefixByUTF8Bytes(String(cleaned.prefix(LAN_MULTIPLAYER_MAX_WORLD_NAME_CHARS)), maxBytes: 192)
    return clipped.isEmpty ? "Pebble World" : clipped
}

public func sanitizedLANTemplateName(_ raw: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _-")
    let cleaned = cleanSingleLine(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        .filter { allowed.contains($0) }
    return prefixByUTF8Bytes(String(cleaned.prefix(64)), maxBytes: 192)
}

public func normalizedLANJoinCode(_ raw: String) -> String {
    let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    let upper = raw.uppercased()
    return String(upper.filter { allowed.contains($0) }.prefix(8))
}

public func isValidLANJoinCode(_ raw: String) -> Bool {
    let code = normalizedLANJoinCode(raw)
    return code.count >= 4 && code.count <= 8 && code == raw.uppercased()
}

public func generateLANJoinCode() -> String {
    let chars = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    var rng = SystemRandomNumberGenerator()
    var out = ""
    for _ in 0..<6 {
        out.append(chars[Int.random(in: 0..<chars.count, using: &rng)])
    }
    return out
}

public func sanitizedLANChatText(_ raw: String) -> String {
    let cleaned = cleanSingleLine(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    return prefixByUTF8Bytes(cleaned, maxBytes: LAN_MULTIPLAYER_MAX_CHAT_BYTES)
}

public func sanitizedLANDirectHost(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 253 else { return "" }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_[]:")
    guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
    return trimmed
}

private func cleanSingleLine(_ raw: String) -> String {
    String(raw.filter { ch in
        !ch.isNewline && ch.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7f
        }
    })
}

private func prefixByUTF8Bytes(_ raw: String, maxBytes: Int) -> String {
    var out = ""
    out.reserveCapacity(min(raw.count, maxBytes))
    for ch in raw {
        if out.utf8.count + ch.utf8.count > maxBytes { break }
        out.append(ch)
    }
    return out
}
