import Foundation

public struct LANBlockPosition: Hashable, Equatable, Comparable {
    public var dimension: Int
    public var x: Int
    public var y: Int
    public var z: Int

    public init(dimension: Int, x: Int, y: Int, z: Int) {
        self.dimension = dimension
        self.x = x
        self.y = y
        self.z = z
    }

    public static func < (lhs: LANBlockPosition, rhs: LANBlockPosition) -> Bool {
        if lhs.dimension != rhs.dimension { return lhs.dimension < rhs.dimension }
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

public struct LANChunkSectionPosition: Hashable, Equatable, Comparable {
    public var dimension: Int
    public var cx: Int
    public var cz: Int
    public var sectionY: Int

    public init(dimension: Int, cx: Int, cz: Int, sectionY: Int) {
        self.dimension = dimension
        self.cx = cx
        self.cz = cz
        self.sectionY = sectionY
    }

    public static func < (lhs: LANChunkSectionPosition, rhs: LANChunkSectionPosition) -> Bool {
        if lhs.dimension != rhs.dimension { return lhs.dimension < rhs.dimension }
        if lhs.cx != rhs.cx { return lhs.cx < rhs.cx }
        if lhs.cz != rhs.cz { return lhs.cz < rhs.cz }
        return lhs.sectionY < rhs.sectionY
    }
}

public struct LANReplicationApplyReport: Equatable {
    public var appliedBlockChanges = 0
    public var appliedChunkSections = 0
    public var ignoredInvalidCells = 0
    public var ignoredInvalidSections = 0
    public var ignoredUnloadedBlockChanges = 0

    public init() {}
}

public enum LANBlockIntentResult: Equatable {
    case applied([LANBlockChange])
    case ignored(String)
    case rejected(String)
}

public final class LANReplicationChangeLog {
    private var changesByPosition: [LANBlockPosition: LANBlockChange] = [:]
    private var positionsInOrder: [LANBlockPosition] = []

    public init() {}

    public var count: Int { changesByPosition.count }

    public func record(_ change: LANBlockChange) {
        let position = LANBlockPosition(dimension: change.dimension, x: change.x, y: change.y, z: change.z)
        if changesByPosition[position] == nil {
            if positionsInOrder.count >= LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES {
                let removed = positionsInOrder.removeFirst()
                changesByPosition.removeValue(forKey: removed)
            }
            positionsInOrder.append(position)
        }
        changesByPosition[position] = change
    }

    public func drain(maxCount: Int = LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES) -> [LANBlockChange] {
        let cap = max(0, min(maxCount, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES))
        let selectedPositions = Array(positionsInOrder.prefix(cap))
        let out = selectedPositions.compactMap { changesByPosition[$0] }
        positionsInOrder.removeFirst(selectedPositions.count)
        for position in selectedPositions {
            changesByPosition.removeValue(forKey: position)
        }
        return out
    }

    public func peek(maxCount: Int = LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES) -> [LANBlockChange] {
        let cap = max(0, min(maxCount, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES))
        return positionsInOrder.prefix(cap).compactMap { changesByPosition[$0] }
    }
}

public final class LANMultiplayerHostSession {
    private struct Peer {
        var playerID: String
        var displayName: String
        var joinedOrdinal: Int
        var playerState: LANPlayerState?
        var lastAckTick = 0
    }

    private var peers: [String: Peer] = [:]
    private var nextOrdinal = 0
    private let changeLog = LANReplicationChangeLog()

    public init() {}

    public var acceptedPeerCount: Int { peers.count }

    public func acceptPeer(playerID rawPlayerID: String, displayName rawDisplayName: String) {
        let playerID = String(rawPlayerID.prefix(128))
        let displayName = sanitizedLANPlayerName(rawDisplayName)
        if var existing = peers[playerID] {
            existing.displayName = displayName
            peers[playerID] = existing
            return
        }
        peers[playerID] = Peer(playerID: playerID, displayName: displayName, joinedOrdinal: nextOrdinal, playerState: nil)
        nextOrdinal += 1
    }

    public func removePeer(playerID rawPlayerID: String) {
        peers.removeValue(forKey: String(rawPlayerID.prefix(128)))
    }

    public func updatePlayerState(_ state: LANPlayerState) {
        let playerID = String(state.playerID.prefix(128))
        guard var peer = peers[playerID] else { return }
        peer.playerState = state
        peers[playerID] = peer
    }

    public func recordAck(_ ack: LANReplicationAck, from rawPlayerID: String) {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID] else { return }
        peer.lastAckTick = max(peer.lastAckTick, ack.tick)
        peers[playerID] = peer
    }

    public func peerPlayerStates() -> [LANPlayerState] {
        peers.values
            .sorted { lhs, rhs in lhs.joinedOrdinal == rhs.joinedOrdinal ? lhs.playerID < rhs.playerID : lhs.joinedOrdinal < rhs.joinedOrdinal }
            .compactMap(\.playerState)
            .prefix(LAN_MULTIPLAYER_MAX_REPLICATION_PLAYERS)
            .map { $0 }
    }

    @discardableResult
    public func recordBlockChange(dimension: Int, x: Int, y: Int, z: Int, cell: Int) -> Bool {
        guard isValidLANReplicatedCell(cell) else { return false }
        changeLog.record(LANBlockChange(dimension: dimension, x: x, y: y, z: z, cell: cell))
        return true
    }

    public func pendingBlockChanges() -> [LANBlockChange] {
        changeLog.peek()
    }

    public func drainBlockChanges() -> [LANBlockChange] {
        changeLog.drain()
    }

    public func applyBlockIntent(_ intent: LANBlockIntent, from rawPlayerID: String, to world: World) -> LANBlockIntentResult {
        let playerID = String(rawPlayerID.prefix(128))
        guard let peer = peers[playerID] else { return .rejected("unknown player") }
        guard let playerState = peer.playerState else { return .rejected("player state unavailable") }
        guard isWithinLANReach(playerState, x: intent.x, y: intent.y, z: intent.z) else {
            return .rejected("target out of reach")
        }

        switch intent.action {
        case .breakBlock:
            let old = world.getBlock(intent.x, intent.y, intent.z)
            guard old != 0 else { return .ignored("already air") }
            _ = world.setBlock(intent.x, intent.y, intent.z, 0)
            let change = LANBlockChange(dimension: world.dim.rawValue, x: intent.x, y: intent.y, z: intent.z, cell: 0)
            changeLog.record(change)
            return .applied([change])
        case .placeBlock:
            guard isValidLANReplicatedCell(intent.cell), intent.cell != 0 else {
                return .rejected("invalid placement cell")
            }
            let tx = intent.x + DIR_X[intent.face]
            let ty = intent.y + DIR_Y[intent.face]
            let tz = intent.z + DIR_Z[intent.face]
            let existing = world.getBlock(tx, ty, tz)
            guard isReplaceableLANCell(existing) else { return .ignored("target occupied") }
            _ = world.setBlock(tx, ty, tz, intent.cell)
            let change = LANBlockChange(dimension: world.dim.rawValue, x: tx, y: ty, z: tz, cell: intent.cell)
            changeLog.record(change)
            return .applied([change])
        case .useBlock:
            return .ignored("use-block replication is not a world delta")
        }
    }

    public func makeBatch(
        tick: Int,
        fullSnapshot: Bool,
        worldSummary: LANWorldSummary?,
        localPlayer: LANPlayerState?,
        chunkSections: [LANChunkSectionSnapshot],
        entitySnapshots: [LANEntitySnapshot],
        inventorySnapshots: [LANPlayerInventorySnapshot]
    ) -> LANReplicationBatch {
        var players = peerPlayerStates()
        if let localPlayer {
            players.insert(localPlayer, at: 0)
        }
        let blockChanges = fullSnapshot ? pendingBlockChanges() : drainBlockChanges()
        return LANReplicationBatch(
            tick: tick,
            fullSnapshot: fullSnapshot,
            world: worldSummary,
            players: players,
            blockChanges: blockChanges,
            chunkSections: chunkSections,
            entities: entitySnapshots,
            inventories: inventorySnapshots
        )
    }
}

public final class LANMultiplayerClientSession {
    public private(set) var latestTick = 0
    public private(set) var worldSummary: LANWorldSummary?
    public private(set) var players: [String: LANPlayerState] = [:]
    public private(set) var blockCells: [LANBlockPosition: Int] = [:]
    public private(set) var chunkSections: [LANChunkSectionPosition: LANChunkSectionSnapshot] = [:]
    public private(set) var entities: [Int: LANEntitySnapshot] = [:]
    public private(set) var inventories: [String: LANPlayerInventorySnapshot] = [:]

    public init() {}

    @discardableResult
    public func apply(_ batch: LANReplicationBatch) -> LANReplicationApplyReport {
        var report = LANReplicationApplyReport()
        latestTick = max(latestTick, batch.tick)
        if let world = batch.world { worldSummary = world }
        for player in batch.players.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_PLAYERS) {
            players[player.playerID] = player
        }
        for section in batch.chunkSections.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS) {
            guard section.hasExpectedCellCount, section.cells.allSatisfy({ isValidLANReplicatedCell(Int($0)) }) else {
                report.ignoredInvalidSections += 1
                continue
            }
            let key = LANChunkSectionPosition(
                dimension: section.dimension,
                cx: section.cx,
                cz: section.cz,
                sectionY: section.sectionY
            )
            chunkSections[key] = section
            report.appliedChunkSections += 1
        }
        for change in batch.blockChanges.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES) {
            guard isValidLANReplicatedCell(change.cell) else {
                report.ignoredInvalidCells += 1
                continue
            }
            let key = LANBlockPosition(dimension: change.dimension, x: change.x, y: change.y, z: change.z)
            blockCells[key] = change.cell
            report.appliedBlockChanges += 1
        }
        for entity in batch.entities.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES) {
            if entity.dead {
                entities.removeValue(forKey: entity.entityID)
            } else {
                entities[entity.entityID] = entity
            }
        }
        for inventory in batch.inventories.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORIES) {
            inventories[inventory.playerID] = inventory
        }
        return report
    }
}

public func isValidLANReplicatedCell(_ cell: Int) -> Bool {
    guard cell >= 0, cell <= Int(UInt16.max) else { return false }
    let id = cell >> 4
    return id >= 0 && id < blockDefs.count
}

public func makeLANPlayerState(_ player: Player, playerID: String, displayName: String) -> LANPlayerState {
    LANPlayerState(
        playerID: playerID,
        displayName: displayName,
        x: player.x,
        y: player.y,
        z: player.z,
        yaw: player.yaw,
        pitch: player.pitch,
        health: player.health,
        hunger: player.hunger,
        selectedHotbarSlot: player.selectedSlot,
        gameMode: player.gameMode
    )
}

public func makeLANInventorySnapshot(_ player: Player, playerID: String) -> LANPlayerInventorySnapshot {
    let slots = player.inventory.enumerated().compactMap { index, stack -> LANInventorySlotSnapshot? in
        guard let stack, stack.count > 0, stack.id >= 0, stack.id < itemDefs.count else { return nil }
        return LANInventorySlotSnapshot(
            slot: index,
            itemID: stack.id,
            count: stack.count,
            damage: stack.damage,
            label: stack.label
        )
    }
    return LANPlayerInventorySnapshot(playerID: playerID, selectedHotbarSlot: player.selectedSlot, slots: slots)
}

public func makeLANEntitySnapshots(
    in world: World,
    aroundX: Double? = nil,
    aroundZ: Double? = nil,
    radius: Double = 160,
    maxCount: Int = LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES
) -> [LANEntitySnapshot] {
    let radius2 = radius * radius
    let entities = world.entities.sorted { $0.id < $1.id }
    var out: [LANEntitySnapshot] = []
    for ref in entities {
        if out.count >= max(0, min(maxCount, LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES)) { break }
        if ref is Player { continue }
        if let aroundX, let aroundZ {
            let dx = ref.x - aroundX
            let dz = ref.z - aroundZ
            if dx * dx + dz * dz > radius2 { continue }
        }
        let entity = ref as? Entity
        let living = ref as? LivingEntity
        out.append(LANEntitySnapshot(
            entityID: ref.id,
            type: entity?.type ?? "entity",
            x: ref.x,
            y: ref.y,
            z: ref.z,
            yaw: entity?.yaw ?? 0,
            pitch: entity?.pitch ?? 0,
            health: living?.health,
            dead: ref.dead
        ))
    }
    return out
}

public func makeLANChunkSectionSnapshot(from chunk: Chunk, dimension: Int, sectionY: Int) -> LANChunkSectionSnapshot? {
    guard sectionY >= 0, sectionY < chunk.sections else { return nil }
    let minY = chunk.minY + sectionY * SECTION_H
    var cells: [UInt16] = []
    cells.reserveCapacity(LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
    for localY in 0..<SECTION_H {
        let y = minY + localY
        for z in 0..<CHUNK_W {
            for x in 0..<CHUNK_W {
                cells.append(chunk.get(x, y, z))
            }
        }
    }
    return LANChunkSectionSnapshot(
        dimension: dimension,
        cx: chunk.cx,
        cz: chunk.cz,
        sectionY: sectionY,
        minY: minY,
        cells: cells
    )
}

public func makeLANChunkSectionSnapshots(
    around player: Player,
    in world: World,
    chunkRadius: Int = 1,
    verticalSectionRadius: Int = 2,
    maxCount: Int = LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS
) -> [LANChunkSectionSnapshot] {
    let centerCX = floorDiv(ifloor(player.x), CHUNK_W)
    let centerCZ = floorDiv(ifloor(player.z), CHUNK_W)
    let playerSection = max(0, min(world.info.height / SECTION_H - 1, (ifloor(player.y) - world.info.minY) >> 4))
    var out: [LANChunkSectionSnapshot] = []
    let radius = max(0, min(2, chunkRadius))
    for dz in -radius...radius {
        for dx in -radius...radius {
            guard let chunk = world.getChunk(centerCX + dx, centerCZ + dz) else { continue }
            let minSection = max(0, playerSection - verticalSectionRadius)
            let maxSection = min(chunk.sections - 1, playerSection + verticalSectionRadius)
            for sectionY in minSection...maxSection {
                if out.count >= max(0, min(maxCount, LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS)) { return out }
                if let snapshot = makeLANChunkSectionSnapshot(from: chunk, dimension: world.dim.rawValue, sectionY: sectionY) {
                    out.append(snapshot)
                }
            }
        }
    }
    return out
}

@discardableResult
public func applyLANReplicationBatch(_ batch: LANReplicationBatch, to world: World) -> LANReplicationApplyReport {
    var report = LANReplicationApplyReport()
    for section in batch.chunkSections.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS) {
        if applyLANChunkSectionSnapshot(section, to: world) {
            report.appliedChunkSections += 1
        } else {
            report.ignoredInvalidSections += 1
        }
    }
    for change in batch.blockChanges.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES) {
        guard change.dimension == world.dim.rawValue, isValidLANReplicatedCell(change.cell) else {
            report.ignoredInvalidCells += 1
            continue
        }
        guard world.getChunkAt(change.x, change.z) != nil else {
            report.ignoredUnloadedBlockChanges += 1
            continue
        }
        _ = world.setBlock(change.x, change.y, change.z, change.cell)
        report.appliedBlockChanges += 1
    }
    return report
}

@discardableResult
public func applyLANChunkSectionSnapshot(_ snapshot: LANChunkSectionSnapshot, to world: World) -> Bool {
    guard snapshot.dimension == world.dim.rawValue,
          snapshot.hasExpectedCellCount,
          snapshot.cells.allSatisfy({ isValidLANReplicatedCell(Int($0)) }),
          snapshot.minY >= world.info.minY,
          snapshot.minY + SECTION_H <= world.info.minY + world.info.height,
          (snapshot.minY - world.info.minY) % SECTION_H == 0
    else { return false }
    let expectedSection = (snapshot.minY - world.info.minY) / SECTION_H
    guard expectedSection == snapshot.sectionY else { return false }

    let chunk = world.getChunk(snapshot.cx, snapshot.cz) ?? Chunk(cx: snapshot.cx, cz: snapshot.cz, minY: world.info.minY, height: world.info.height)
    var index = 0
    for localY in 0..<SECTION_H {
        let y = snapshot.minY + localY
        for z in 0..<CHUNK_W {
            for x in 0..<CHUNK_W {
                chunk.set(x, y, z, snapshot.cells[index])
                index += 1
            }
        }
    }
    chunk.status = .generated
    chunk.modified = true
    chunk.buildHeightmap()
    chunk.scanSpecials()
    if world.getChunk(snapshot.cx, snapshot.cz) == nil {
        world.setChunk(chunk)
    }
    chunk.markDirtyAt(snapshot.minY)
    world.hooks.onSectionDirty(snapshot.cx, snapshot.cz, snapshot.sectionY)
    return true
}

private func isWithinLANReach(_ player: LANPlayerState, x: Int, y: Int, z: Int) -> Bool {
    let eyeY = player.y + PLAYER_EYE
    let dx = Double(x) + 0.5 - player.x
    let dy = Double(y) + 0.5 - eyeY
    let dz = Double(z) + 0.5 - player.z
    let reach = player.gameMode == GameMode.creative ? 8.0 : 6.0
    return dx * dx + dy * dy + dz * dz <= reach * reach
}

private func isReplaceableLANCell(_ cell: Int) -> Bool {
    guard isValidLANReplicatedCell(cell) else { return false }
    return blockDefs[cell >> 4].replaceable
}
