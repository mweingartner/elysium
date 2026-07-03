import Foundation

public let LAN_MULTIPLAYER_PROTOCOL_VERSION: UInt16 = 1
public let LAN_MULTIPLAYER_SERVICE_TYPE = "_pebble-lan._tcp"
public let LAN_MULTIPLAYER_DEFAULT_PORT: UInt16 = 41337
public let LAN_MULTIPLAYER_MAX_CLIENTS = 8
public let LAN_MULTIPLAYER_MAX_FRAME_BYTES = 1_048_576
public let LAN_MULTIPLAYER_MAX_PLAYER_NAME_CHARS = 32
public let LAN_MULTIPLAYER_MAX_CHAT_BYTES = 512
public let LAN_MULTIPLAYER_MAX_WORLD_NAME_CHARS = 64
public let LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES = 4096
public let LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS = 32
public let LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES = 512
public let LAN_MULTIPLAYER_MAX_REPLICATION_PLAYERS = LAN_MULTIPLAYER_MAX_CLIENTS + 1
public let LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORIES = LAN_MULTIPLAYER_MAX_CLIENTS + 1
public let LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORY_SLOTS = 64
public let LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES = 64
public let LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS = 64
public let LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT = CHUNK_W * SECTION_H * CHUNK_W
public let LAN_MULTIPLAYER_MAX_CHUNK_REQUEST_RADIUS = 1
public let LAN_MULTIPLAYER_DEFAULT_CHUNK_REQUEST_RADIUS = 1
public let LAN_MULTIPLAYER_DEFAULT_CHUNK_VERTICAL_RADIUS = 1
private let LAN_MULTIPLAYER_MAX_ENTITY_COORDINATE = 30_000_000.0
public let LAN_MULTIPLAYER_MAX_REPLICATED_ITEM_COUNT = 127
private let LAN_MULTIPLAYER_MAX_REPLICATED_XP_AMOUNT = 4096

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
    case replicationBatch = 14
    case chunkRequest = 15
    case replicationAck = 16
    case gameplayEvent = 17
}

public enum LANPeerLifecycleState: String, Codable, Equatable {
    case connected
    case disconnected
    case dead
    case respawning
}

public enum LANGameplayPermission: String, Codable, Equatable, CaseIterable {
    case build
    case container
    case crafting
    case template
    case command
    case ai
    case dimension
    case respawn
    case creative
}

public struct LANPeerPermissions: Codable, Equatable {
    public var canBuild: Bool
    public var canUseContainers: Bool
    public var canCraft: Bool
    public var canUseTemplates: Bool
    public var canUseCommands: Bool
    public var canUseAI: Bool
    public var canChangeDimensions: Bool
    public var canRespawn: Bool
    public var canUseCreative: Bool

    public init(
        canBuild: Bool = true,
        canUseContainers: Bool = true,
        canCraft: Bool = true,
        canUseTemplates: Bool = true,
        canUseCommands: Bool = false,
        canUseAI: Bool = false,
        canChangeDimensions: Bool = false,
        canRespawn: Bool = true,
        canUseCreative: Bool = false
    ) {
        self.canBuild = canBuild
        self.canUseContainers = canUseContainers
        self.canCraft = canCraft
        self.canUseTemplates = canUseTemplates
        self.canUseCommands = canUseCommands
        self.canUseAI = canUseAI
        self.canChangeDimensions = canChangeDimensions
        self.canRespawn = canRespawn
        self.canUseCreative = canUseCreative
    }

    public func allows(_ permission: LANGameplayPermission) -> Bool {
        switch permission {
        case .build: return canBuild
        case .container: return canUseContainers
        case .crafting: return canCraft
        case .template: return canUseTemplates
        case .command: return canUseCommands
        case .ai: return canUseAI
        case .dimension: return canChangeDimensions
        case .respawn: return canRespawn
        case .creative: return canUseCreative
        }
    }
}

public enum LANGameplayEventKind: String, Codable, Equatable {
    case permissionDenied
    case intentAccepted
    case peerJoined
    case peerDisconnected
    case peerReconnected
    case death
    case respawn
    case dimensionChanged
}

public struct LANGameplayEvent: Codable, Equatable {
    public var playerID: String
    public var kind: LANGameplayEventKind
    public var message: String
    public var tick: Int

    public init(playerID: String, kind: LANGameplayEventKind, message: String, tick: Int) {
        self.playerID = String(playerID.prefix(128))
        self.kind = kind
        self.message = sanitizedLANChatText(message)
        self.tick = max(0, tick)
    }
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

public func sanitizedLANWorldIdentifier(_ raw: String, maxLength: Int = 48) -> String {
    var clean = ""
    for scalar in raw.unicodeScalars where clean.count < max(1, maxLength) {
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
            clean.unicodeScalars.append(scalar)
        }
    }
    return clean
}

public func lanClientResumeKey(for summary: LANWorldSummary) -> String? {
    let worldID = sanitizedLANWorldIdentifier(summary.worldID)
    guard !worldID.isEmpty, worldID != "unsaved" else { return nil }
    return "\(worldID)#\(summary.seed)"
}

public struct LANPlayerState: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case playerID
        case displayName
        case x
        case y
        case z
        case yaw
        case pitch
        case health
        case hunger
        case selectedHotbarSlot
        case gameMode
        case dimension
        case dead
    }

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
    public var dimension: Int
    public var dead: Bool

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
        gameMode: Int,
        dimension: Int = Dim.overworld.rawValue,
        dead: Bool = false
    ) {
        self.playerID = String(playerID.prefix(128))
        self.displayName = sanitizedLANPlayerName(displayName)
        self.x = x.isFinite ? x : 0
        self.y = y.isFinite ? y : 0
        self.z = z.isFinite ? z : 0
        self.yaw = yaw.isFinite ? yaw : 0
        self.pitch = pitch.isFinite ? max(-.pi / 2, min(.pi / 2, pitch)) : 0
        self.health = health.isFinite ? max(0, min(2048, health)) : 0
        self.hunger = max(0, min(20, hunger))
        self.selectedHotbarSlot = max(0, min(8, selectedHotbarSlot))
        self.gameMode = gameMode == GameMode.creative ? GameMode.creative : GameMode.survival
        self.dimension = isValidLANDimension(dimension) ? dimension : Dim.overworld.rawValue
        self.dead = dead || self.health <= 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            playerID: try c.decode(String.self, forKey: .playerID),
            displayName: try c.decode(String.self, forKey: .displayName),
            x: try c.decode(Double.self, forKey: .x),
            y: try c.decode(Double.self, forKey: .y),
            z: try c.decode(Double.self, forKey: .z),
            yaw: try c.decode(Double.self, forKey: .yaw),
            pitch: try c.decode(Double.self, forKey: .pitch),
            health: try c.decode(Double.self, forKey: .health),
            hunger: try c.decode(Int.self, forKey: .hunger),
            selectedHotbarSlot: try c.decode(Int.self, forKey: .selectedHotbarSlot),
            gameMode: try c.decode(Int.self, forKey: .gameMode),
            dimension: try c.decodeIfPresent(Int.self, forKey: .dimension) ?? Dim.overworld.rawValue,
            dead: try c.decodeIfPresent(Bool.self, forKey: .dead) ?? false
        )
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

    private enum CodingKeys: String, CodingKey {
        case action
        case x
        case y
        case z
        case face
        case selectedHotbarSlot
        case cell
    }

    public var action: Action
    public var x: Int
    public var y: Int
    public var z: Int
    public var face: Int
    public var selectedHotbarSlot: Int
    public var cell: Int

    public init(action: Action, x: Int, y: Int, z: Int, face: Int, selectedHotbarSlot: Int, cell: Int = 0) {
        self.action = action
        self.x = x
        self.y = y
        self.z = z
        self.face = max(0, min(5, face))
        self.selectedHotbarSlot = max(0, min(8, selectedHotbarSlot))
        self.cell = max(0, min(Int(UInt16.max), cell))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            action: try c.decode(Action.self, forKey: .action),
            x: try c.decode(Int.self, forKey: .x),
            y: try c.decode(Int.self, forKey: .y),
            z: try c.decode(Int.self, forKey: .z),
            face: try c.decode(Int.self, forKey: .face),
            selectedHotbarSlot: try c.decode(Int.self, forKey: .selectedHotbarSlot),
            cell: try c.decodeIfPresent(Int.self, forKey: .cell) ?? 0
        )
    }
}

public struct LANBlockChange: Codable, Equatable {
    public var dimension: Int
    public var x: Int
    public var y: Int
    public var z: Int
    public var cell: Int

    public init(dimension: Int, x: Int, y: Int, z: Int, cell: Int) {
        self.dimension = dimension
        self.x = x
        self.y = y
        self.z = z
        self.cell = max(0, min(Int(UInt16.max), cell))
    }
}

public struct LANChunkSectionSnapshot: Codable, Equatable {
    public var dimension: Int
    public var cx: Int
    public var cz: Int
    public var sectionY: Int
    public var minY: Int
    public var cells: [UInt16]

    public init(dimension: Int, cx: Int, cz: Int, sectionY: Int, minY: Int, cells: [UInt16]) {
        self.dimension = dimension
        self.cx = cx
        self.cz = cz
        self.sectionY = sectionY
        self.minY = minY
        self.cells = cells.count > LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT
            ? Array(cells.prefix(LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT))
            : cells
    }

    public var hasExpectedCellCount: Bool {
        cells.count == LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT
    }
}

public struct LANEntitySnapshot: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case entityID
        case type
        case x
        case y
        case z
        case yaw
        case pitch
        case health
        case dead
        case itemID
        case itemCount
        case itemDamage
        case itemLabel
        case xpAmount
    }

    public var entityID: Int
    public var type: String
    public var x: Double
    public var y: Double
    public var z: Double
    public var yaw: Double
    public var pitch: Double
    public var health: Double?
    public var dead: Bool
    public var itemID: Int?
    public var itemCount: Int?
    public var itemDamage: Int?
    public var itemLabel: String?
    public var xpAmount: Int?

    public init(
        entityID: Int,
        type: String,
        x: Double,
        y: Double,
        z: Double,
        yaw: Double,
        pitch: Double,
        health: Double?,
        dead: Bool,
        itemID: Int? = nil,
        itemCount: Int? = nil,
        itemDamage: Int? = nil,
        itemLabel: String? = nil,
        xpAmount: Int? = nil
    ) {
        self.entityID = entityID
        self.type = sanitizedLANEntityType(type)
        self.x = sanitizedLANEntityCoordinate(x)
        self.y = sanitizedLANEntityCoordinate(y)
        self.z = sanitizedLANEntityCoordinate(z)
        self.yaw = yaw.isFinite ? yaw : 0
        self.pitch = pitch.isFinite ? pitch : 0
        self.health = health?.isFinite == true ? health : nil
        self.dead = dead
        self.itemID = itemID.flatMap { $0 >= 0 ? $0 : nil }
        self.itemCount = itemCount.flatMap { $0 > 0 ? min($0, LAN_MULTIPLAYER_MAX_REPLICATED_ITEM_COUNT) : nil }
        self.itemDamage = itemDamage.flatMap { $0 >= 0 ? $0 : nil }
        self.itemLabel = itemLabel.map { prefixByUTF8Bytes(cleanSingleLine($0), maxBytes: 128) }
        self.xpAmount = xpAmount.flatMap { $0 > 0 ? min($0, LAN_MULTIPLAYER_MAX_REPLICATED_XP_AMOUNT) : nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            entityID: try c.decode(Int.self, forKey: .entityID),
            type: try c.decode(String.self, forKey: .type),
            x: try c.decode(Double.self, forKey: .x),
            y: try c.decode(Double.self, forKey: .y),
            z: try c.decode(Double.self, forKey: .z),
            yaw: try c.decode(Double.self, forKey: .yaw),
            pitch: try c.decode(Double.self, forKey: .pitch),
            health: try c.decodeIfPresent(Double.self, forKey: .health),
            dead: try c.decode(Bool.self, forKey: .dead),
            itemID: try c.decodeIfPresent(Int.self, forKey: .itemID),
            itemCount: try c.decodeIfPresent(Int.self, forKey: .itemCount),
            itemDamage: try c.decodeIfPresent(Int.self, forKey: .itemDamage),
            itemLabel: try c.decodeIfPresent(String.self, forKey: .itemLabel),
            xpAmount: try c.decodeIfPresent(Int.self, forKey: .xpAmount)
        )
    }
}

public struct LANInventorySlotSnapshot: Codable, Equatable {
    public var slot: Int
    public var itemID: Int
    public var count: Int
    public var damage: Int
    public var label: String?

    public init(slot: Int, itemID: Int, count: Int, damage: Int = 0, label: String? = nil) {
        self.slot = max(0, min(LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORY_SLOTS - 1, slot))
        self.itemID = max(0, itemID)
        self.count = max(0, min(127, count))
        self.damage = max(0, damage)
        self.label = label.map { prefixByUTF8Bytes(cleanSingleLine($0), maxBytes: 128) }
    }
}

public struct LANBlockEntitySlotSnapshot: Codable, Equatable {
    public var slot: Int
    public var itemID: Int
    public var count: Int
    public var damage: Int
    public var label: String?

    public init(slot: Int, itemID: Int, count: Int, damage: Int = 0, label: String? = nil) {
        self.slot = max(0, min(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS - 1, slot))
        self.itemID = max(0, itemID)
        self.count = max(0, min(LAN_MULTIPLAYER_MAX_REPLICATED_ITEM_COUNT, count))
        self.damage = max(0, damage)
        self.label = label.map { prefixByUTF8Bytes(cleanSingleLine($0), maxBytes: 128) }
    }
}

public struct LANBlockEntitySnapshot: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case dimension
        case x
        case y
        case z
        case type
        case slotCount
        case slots
        case kind
        case burnTime
        case burnTotal
        case cookTime
        case cookTotal
        case xpBank
        case brewTime
        case fuel
        case times
    }

    public var dimension: Int
    public var x: Int
    public var y: Int
    public var z: Int
    public var type: String
    public var slotCount: Int
    public var slots: [LANBlockEntitySlotSnapshot]
    public var kind: String?
    public var burnTime: Int?
    public var burnTotal: Int?
    public var cookTime: Int?
    public var cookTotal: Int?
    public var xpBank: Double?
    public var brewTime: Int?
    public var fuel: Int?
    public var times: [Int]?

    public init(
        dimension: Int,
        x: Int,
        y: Int,
        z: Int,
        type: String,
        slotCount: Int,
        slots: [LANBlockEntitySlotSnapshot],
        kind: String? = nil,
        burnTime: Int? = nil,
        burnTotal: Int? = nil,
        cookTime: Int? = nil,
        cookTotal: Int? = nil,
        xpBank: Double? = nil,
        brewTime: Int? = nil,
        fuel: Int? = nil,
        times: [Int]? = nil
    ) {
        self.dimension = isValidLANDimension(dimension) ? dimension : Dim.overworld.rawValue
        self.x = x
        self.y = y
        self.z = z
        self.type = prefixByUTF8Bytes(cleanSingleLine(type), maxBytes: 32)
        self.slotCount = max(0, min(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS, slotCount))
        self.slots = Array(slots.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS))
        self.kind = kind.map { prefixByUTF8Bytes(cleanSingleLine($0), maxBytes: 32) }
        self.burnTime = burnTime.map { max(0, min(240_000, $0)) }
        self.burnTotal = burnTotal.map { max(0, min(240_000, $0)) }
        self.cookTime = cookTime.map { max(0, min(240_000, $0)) }
        self.cookTotal = cookTotal.map { max(0, min(240_000, $0)) }
        self.xpBank = xpBank.flatMap { $0.isFinite ? max(0, min(1_000_000, $0)) : nil }
        self.brewTime = brewTime.map { max(0, min(240_000, $0)) }
        self.fuel = fuel.map { max(0, min(240_000, $0)) }
        self.times = times.map { raw in
            Array(raw.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS)).map { max(0, min(240_000, $0)) }
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dimension: try c.decode(Int.self, forKey: .dimension),
            x: try c.decode(Int.self, forKey: .x),
            y: try c.decode(Int.self, forKey: .y),
            z: try c.decode(Int.self, forKey: .z),
            type: try c.decode(String.self, forKey: .type),
            slotCount: try c.decodeIfPresent(Int.self, forKey: .slotCount) ?? 0,
            slots: try c.decodeIfPresent([LANBlockEntitySlotSnapshot].self, forKey: .slots) ?? [],
            kind: try c.decodeIfPresent(String.self, forKey: .kind),
            burnTime: try c.decodeIfPresent(Int.self, forKey: .burnTime),
            burnTotal: try c.decodeIfPresent(Int.self, forKey: .burnTotal),
            cookTime: try c.decodeIfPresent(Int.self, forKey: .cookTime),
            cookTotal: try c.decodeIfPresent(Int.self, forKey: .cookTotal),
            xpBank: try c.decodeIfPresent(Double.self, forKey: .xpBank),
            brewTime: try c.decodeIfPresent(Int.self, forKey: .brewTime),
            fuel: try c.decodeIfPresent(Int.self, forKey: .fuel),
            times: try c.decodeIfPresent([Int].self, forKey: .times)
        )
    }
}

public struct LANPlayerInventorySnapshot: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case playerID
        case selectedHotbarSlot
        case slots
        case xp
        case xpLevel
        case xpProgress
    }

    public var playerID: String
    public var selectedHotbarSlot: Int
    public var slots: [LANInventorySlotSnapshot]
    public var xp: Int
    public var xpLevel: Int
    public var xpProgress: Double

    public init(
        playerID: String,
        selectedHotbarSlot: Int,
        slots: [LANInventorySlotSnapshot],
        xp: Int = 0,
        xpLevel: Int = 0,
        xpProgress: Double = 0
    ) {
        self.playerID = String(playerID.prefix(128))
        self.selectedHotbarSlot = max(0, min(8, selectedHotbarSlot))
        self.slots = slots.count > LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORY_SLOTS
            ? Array(slots.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORY_SLOTS))
            : slots
        self.xp = max(0, min(1_000_000_000, xp))
        self.xpLevel = max(0, min(100_000, xpLevel))
        self.xpProgress = xpProgress.isFinite ? max(0, min(1, xpProgress)) : 0
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            playerID: try c.decode(String.self, forKey: .playerID),
            selectedHotbarSlot: try c.decode(Int.self, forKey: .selectedHotbarSlot),
            slots: try c.decodeIfPresent([LANInventorySlotSnapshot].self, forKey: .slots) ?? [],
            xp: try c.decodeIfPresent(Int.self, forKey: .xp) ?? 0,
            xpLevel: try c.decodeIfPresent(Int.self, forKey: .xpLevel) ?? 0,
            xpProgress: try c.decodeIfPresent(Double.self, forKey: .xpProgress) ?? 0
        )
    }
}

public struct LANWorldStateSnapshot: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case dimension
        case time
        case dayTime
        case difficulty
        case raining
        case thundering
        case rainLevel
        case thunderLevel
        case weatherTimer
    }

    public var dimension: Int
    public var time: Int
    public var dayTime: Int
    public var difficulty: Int
    public var raining: Bool
    public var thundering: Bool
    public var rainLevel: Double
    public var thunderLevel: Double
    public var weatherTimer: Int

    public init(
        dimension: Int,
        time: Int,
        dayTime: Int,
        difficulty: Int,
        raining: Bool,
        thundering: Bool,
        rainLevel: Double,
        thunderLevel: Double,
        weatherTimer: Int
    ) {
        self.dimension = isValidLANDimension(dimension) ? dimension : Dim.overworld.rawValue
        self.time = max(0, time)
        self.dayTime = ((dayTime % DAY_LENGTH) + DAY_LENGTH) % DAY_LENGTH
        self.difficulty = max(0, min(3, difficulty))
        self.raining = raining
        self.thundering = thundering
        self.rainLevel = rainLevel.isFinite ? max(0, min(1, rainLevel)) : 0
        self.thunderLevel = thunderLevel.isFinite ? max(0, min(1, thunderLevel)) : 0
        self.weatherTimer = max(0, min(240_000, weatherTimer))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dimension: try c.decode(Int.self, forKey: .dimension),
            time: try c.decode(Int.self, forKey: .time),
            dayTime: try c.decode(Int.self, forKey: .dayTime),
            difficulty: try c.decode(Int.self, forKey: .difficulty),
            raining: try c.decode(Bool.self, forKey: .raining),
            thundering: try c.decode(Bool.self, forKey: .thundering),
            rainLevel: try c.decode(Double.self, forKey: .rainLevel),
            thunderLevel: try c.decode(Double.self, forKey: .thunderLevel),
            weatherTimer: try c.decode(Int.self, forKey: .weatherTimer)
        )
    }
}

public struct LANReplicationBatch: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case tick
        case fullSnapshot
        case world
        case worldState
        case players
        case blockChanges
        case chunkSections
        case entities
        case entitySnapshotsComplete
        case inventories
        case blockEntities
    }

    public var tick: Int
    public var fullSnapshot: Bool
    public var world: LANWorldSummary?
    public var worldState: LANWorldStateSnapshot?
    public var players: [LANPlayerState]
    public var blockChanges: [LANBlockChange]
    public var chunkSections: [LANChunkSectionSnapshot]
    public var entities: [LANEntitySnapshot]
    public var entitySnapshotsComplete: Bool
    public var inventories: [LANPlayerInventorySnapshot]
    public var blockEntities: [LANBlockEntitySnapshot]

    public init(
        tick: Int,
        fullSnapshot: Bool,
        world: LANWorldSummary? = nil,
        worldState: LANWorldStateSnapshot? = nil,
        players: [LANPlayerState] = [],
        blockChanges: [LANBlockChange] = [],
        chunkSections: [LANChunkSectionSnapshot] = [],
        entities: [LANEntitySnapshot] = [],
        entitySnapshotsComplete: Bool = false,
        inventories: [LANPlayerInventorySnapshot] = [],
        blockEntities: [LANBlockEntitySnapshot] = []
    ) {
        self.tick = max(0, tick)
        self.fullSnapshot = fullSnapshot
        self.world = world
        self.worldState = worldState
        self.players = Array(players.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_PLAYERS))
        self.blockChanges = Array(blockChanges.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES))
        self.chunkSections = Array(chunkSections.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS))
        self.entities = Array(entities.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES))
        self.entitySnapshotsComplete = entitySnapshotsComplete
        self.inventories = Array(inventories.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORIES))
        self.blockEntities = Array(blockEntities.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            tick: try c.decode(Int.self, forKey: .tick),
            fullSnapshot: try c.decode(Bool.self, forKey: .fullSnapshot),
            world: try c.decodeIfPresent(LANWorldSummary.self, forKey: .world),
            worldState: try c.decodeIfPresent(LANWorldStateSnapshot.self, forKey: .worldState),
            players: try c.decodeIfPresent([LANPlayerState].self, forKey: .players) ?? [],
            blockChanges: try c.decodeIfPresent([LANBlockChange].self, forKey: .blockChanges) ?? [],
            chunkSections: try c.decodeIfPresent([LANChunkSectionSnapshot].self, forKey: .chunkSections) ?? [],
            entities: try c.decodeIfPresent([LANEntitySnapshot].self, forKey: .entities) ?? [],
            entitySnapshotsComplete: try c.decodeIfPresent(Bool.self, forKey: .entitySnapshotsComplete) ?? false,
            inventories: try c.decodeIfPresent([LANPlayerInventorySnapshot].self, forKey: .inventories) ?? [],
            blockEntities: try c.decodeIfPresent([LANBlockEntitySnapshot].self, forKey: .blockEntities) ?? []
        )
    }

    public var isWithinReplicationCaps: Bool {
        players.count <= LAN_MULTIPLAYER_MAX_REPLICATION_PLAYERS &&
            blockChanges.count <= LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES &&
            chunkSections.count <= LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS &&
            entities.count <= LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES &&
            inventories.count <= LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORIES &&
            blockEntities.count <= LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES &&
            chunkSections.allSatisfy(\.hasExpectedCellCount) &&
            inventories.allSatisfy { $0.slots.count <= LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORY_SLOTS } &&
            blockEntities.allSatisfy { $0.slots.count <= LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS }
    }
}

public struct LANChunkRequest: Codable, Equatable {
    private enum CodingKeys: String, CodingKey {
        case dimension
        case cx
        case cz
        case radius
        case centerY
        case verticalRadius
    }

    public var dimension: Int
    public var cx: Int
    public var cz: Int
    public var radius: Int
    public var centerY: Int?
    public var verticalRadius: Int

    public init(
        dimension: Int,
        cx: Int,
        cz: Int,
        radius: Int,
        centerY: Int? = nil,
        verticalRadius: Int = LAN_MULTIPLAYER_DEFAULT_CHUNK_VERTICAL_RADIUS
    ) {
        self.dimension = dimension
        self.cx = cx
        self.cz = cz
        self.radius = max(0, min(LAN_MULTIPLAYER_MAX_CHUNK_REQUEST_RADIUS, radius))
        self.centerY = centerY
        self.verticalRadius = max(0, min(4, verticalRadius))
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dimension: try c.decode(Int.self, forKey: .dimension),
            cx: try c.decode(Int.self, forKey: .cx),
            cz: try c.decode(Int.self, forKey: .cz),
            radius: try c.decode(Int.self, forKey: .radius),
            centerY: try c.decodeIfPresent(Int.self, forKey: .centerY),
            verticalRadius: try c.decodeIfPresent(Int.self, forKey: .verticalRadius) ?? LAN_MULTIPLAYER_DEFAULT_CHUNK_VERTICAL_RADIUS
        )
    }
}

public struct LANReplicationAck: Codable, Equatable {
    public var tick: Int
    public var receivedSequence: UInt32

    public init(tick: Int, receivedSequence: UInt32) {
        self.tick = max(0, tick)
        self.receivedSequence = receivedSequence
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
    case replicationBatch(LANReplicationBatch)
    case chunkRequest(playerID: String, request: LANChunkRequest)
    case replicationAck(playerID: String, ack: LANReplicationAck)
    case gameplayEvent(LANGameplayEvent)

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
        case .replicationBatch: return .replicationBatch
        case .chunkRequest: return .chunkRequest
        case .replicationAck: return .replicationAck
        case .gameplayEvent: return .gameplayEvent
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

public struct LANAutoJoinSpec: Equatable {
    public let target: LANDirectConnectTarget
    public let joinCode: String
    public let playerName: String

    public init(target: LANDirectConnectTarget, joinCode: String, playerName: String) {
        self.target = target
        self.joinCode = joinCode
        self.playerName = sanitizedLANPlayerName(playerName)
    }

    public static func parse(_ raw: String) -> LANAutoJoinSpec? {
        let parts = splitCommandLineArguments(raw)
        guard parts.count >= 3,
              let target = LANDirectConnectTarget.parse(host: parts[0], port: parts[1])
        else { return nil }
        let code = normalizedLANJoinCode(parts[2])
        guard isValidLANJoinCode(code) else { return nil }
        let name = parts.count > 3 ? parts[3...].joined(separator: " ") : "LAN Probe"
        return LANAutoJoinSpec(target: target, joinCode: code, playerName: name)
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

public func sanitizedLANEntityType(_ raw: String) -> String {
    var cleaned = ""
    for scalar in raw.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == ":" {
            cleaned.unicodeScalars.append(scalar)
        }
    }
    let clipped = prefixByUTF8Bytes(String(cleaned.prefix(64)), maxBytes: 96)
    return clipped.isEmpty ? "entity" : clipped
}

private func sanitizedLANEntityCoordinate(_ raw: Double) -> Double {
    guard raw.isFinite else { return 0 }
    return max(-LAN_MULTIPLAYER_MAX_ENTITY_COORDINATE, min(LAN_MULTIPLAYER_MAX_ENTITY_COORDINATE, raw))
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

public func isValidLANDimension(_ dimension: Int) -> Bool {
    Dim(rawValue: dimension) != nil
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
