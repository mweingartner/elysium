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
    public var appliedEntitySnapshots = 0
    public var removedEntitySnapshots = 0
    public var ignoredInvalidCells = 0
    public var ignoredInvalidSections = 0
    public var ignoredUnloadedBlockChanges = 0
    public var ignoredInvalidEntities = 0

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
        var lifecycle: LANPeerLifecycleState
        var permissions: LANPeerPermissions
        var playerState: LANPlayerState?
        var inventory: LANPlayerInventorySnapshot?
        var lastTemplateUndo: TemplatePlacementUndoSnapshot?
        var lastAckTick = 0
        var lastSeenTick = 0
        var disconnectedTick: Int?
    }

    private var peers: [String: Peer] = [:]
    private var nextOrdinal = 0
    private let changeLog = LANReplicationChangeLog()

    public init() {}

    public var acceptedPeerCount: Int {
        peers.values.filter { $0.lifecycle == .connected || $0.lifecycle == .dead || $0.lifecycle == .respawning }.count
    }

    @discardableResult
    public func acceptPeer(playerID rawPlayerID: String, displayName rawDisplayName: String, tick: Int = 0) -> LANPeerConnectionDisposition {
        let playerID = String(rawPlayerID.prefix(128))
        let displayName = sanitizedLANPlayerName(rawDisplayName)
        if var existing = peers[playerID] {
            existing.displayName = displayName
            existing.lifecycle = existing.playerState?.dead == true ? .dead : .connected
            existing.lastSeenTick = max(existing.lastSeenTick, tick)
            existing.disconnectedTick = nil
            peers[playerID] = existing
            return .reconnected
        }
        peers[playerID] = Peer(
            playerID: playerID,
            displayName: displayName,
            joinedOrdinal: nextOrdinal,
            lifecycle: .connected,
            permissions: LANPeerPermissions(),
            playerState: nil,
            inventory: nil,
            lastTemplateUndo: nil,
            lastSeenTick: max(0, tick),
            disconnectedTick: nil
        )
        nextOrdinal += 1
        return .joined
    }

    public func removePeer(playerID rawPlayerID: String) {
        peers.removeValue(forKey: String(rawPlayerID.prefix(128)))
    }

    public func disconnectPeer(playerID rawPlayerID: String, tick: Int) {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID] else { return }
        peer.lifecycle = .disconnected
        peer.disconnectedTick = max(0, tick)
        peers[playerID] = peer
    }

    @discardableResult
    public func updatePlayerState(_ state: LANPlayerState, currentDimension: Int? = nil, tick: Int = 0) -> LANPlayerState? {
        let playerID = String(state.playerID.prefix(128))
        guard var peer = peers[playerID] else { return nil }
        let priorDimension = peer.playerState?.dimension ?? currentDimension ?? Dim.overworld.rawValue
        let requestedDimension = isValidLANDimension(state.dimension) ? state.dimension : priorDimension
        let allowedDimension = peer.permissions.canChangeDimensions ? requestedDimension : priorDimension
        let allowedGameMode = state.gameMode == GameMode.creative && !peer.permissions.canUseCreative
            ? GameMode.survival
            : state.gameMode
        let requestedAlive = !state.dead && state.health > 0
        let staysDead = peer.lifecycle == .dead && requestedAlive && !peer.permissions.canRespawn
        let sanitized = LANPlayerState(
            playerID: peer.playerID,
            displayName: peer.displayName,
            x: state.x,
            y: state.y,
            z: state.z,
            yaw: state.yaw,
            pitch: state.pitch,
            health: staysDead ? 0 : state.health,
            hunger: state.hunger,
            selectedHotbarSlot: state.selectedHotbarSlot,
            gameMode: allowedGameMode,
            dimension: allowedDimension,
            dead: staysDead || state.dead || state.health <= 0
        )
        peer.playerState = sanitized
        peer.lifecycle = sanitized.dead ? .dead : .connected
        peer.lastSeenTick = max(peer.lastSeenTick, tick)
        peer.disconnectedTick = nil
        peers[playerID] = peer
        return sanitized
    }

    public func recordInventorySnapshot(_ snapshot: LANPlayerInventorySnapshot, from rawPlayerID: String) {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID] else { return }
        peer.inventory = LANPlayerInventorySnapshot(
            playerID: peer.playerID,
            selectedHotbarSlot: snapshot.selectedHotbarSlot,
            slots: snapshot.slots
        )
        peers[playerID] = peer
    }

    public func setPermissions(_ permissions: LANPeerPermissions, for rawPlayerID: String) {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID] else { return }
        peer.permissions = permissions
        if let state = peer.playerState, state.gameMode == GameMode.creative, !permissions.canUseCreative {
            peer.playerState = LANPlayerState(
                playerID: state.playerID,
                displayName: state.displayName,
                x: state.x,
                y: state.y,
                z: state.z,
                yaw: state.yaw,
                pitch: state.pitch,
                health: state.health,
                hunger: state.hunger,
                selectedHotbarSlot: state.selectedHotbarSlot,
                gameMode: GameMode.survival,
                dimension: state.dimension,
                dead: state.dead
            )
        }
        peers[playerID] = peer
    }

    public func permissions(for rawPlayerID: String) -> LANPeerPermissions? {
        peers[String(rawPlayerID.prefix(128))]?.permissions
    }

    public func peerRecord(playerID rawPlayerID: String) -> LANPeerRecordSnapshot? {
        let playerID = String(rawPlayerID.prefix(128))
        guard let peer = peers[playerID] else { return nil }
        return LANPeerRecordSnapshot(
            playerID: peer.playerID,
            displayName: peer.displayName,
            lifecycle: peer.lifecycle,
            permissions: peer.permissions,
            playerState: peer.playerState,
            inventory: peer.inventory,
            lastAckTick: peer.lastAckTick,
            lastSeenTick: peer.lastSeenTick,
            disconnectedTick: peer.disconnectedTick
        )
    }

    public func recordAck(_ ack: LANReplicationAck, from rawPlayerID: String) {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID] else { return }
        peer.lastAckTick = max(peer.lastAckTick, ack.tick)
        peers[playerID] = peer
    }

    public func peerPlayerStates() -> [LANPlayerState] {
        peers.values
            .filter { $0.lifecycle != .disconnected }
            .sorted { lhs, rhs in lhs.joinedOrdinal == rhs.joinedOrdinal ? lhs.playerID < rhs.playerID : lhs.joinedOrdinal < rhs.joinedOrdinal }
            .compactMap(\.playerState)
            .prefix(LAN_MULTIPLAYER_MAX_REPLICATION_PLAYERS)
            .map { $0 }
    }

    public func peerInventorySnapshots() -> [LANPlayerInventorySnapshot] {
        peers.values
            .filter { $0.lifecycle != .disconnected }
            .sorted { lhs, rhs in lhs.joinedOrdinal == rhs.joinedOrdinal ? lhs.playerID < rhs.playerID : lhs.joinedOrdinal < rhs.joinedOrdinal }
            .compactMap(\.inventory)
            .prefix(LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORIES)
            .map { $0 }
    }

    public func authorize(_ permission: LANGameplayPermission, from rawPlayerID: String) -> LANAuthorizationResult {
        let playerID = String(rawPlayerID.prefix(128))
        guard let peer = peers[playerID] else { return .rejected("unknown player") }
        guard peer.lifecycle != .disconnected else { return .rejected("player disconnected") }
        if peer.lifecycle == .dead && permission != .respawn {
            return .rejected("player is dead")
        }
        guard peer.permissions.allows(permission) else {
            return .rejected("permission denied: \(permission.rawValue)")
        }
        return .accepted
    }

    public func authorizeContainerIntent(_ intent: LANContainerIntent, from rawPlayerID: String) -> LANContainerIntentResult {
        switch authorize(.container, from: rawPlayerID) {
        case .rejected(let reason): return .rejected(reason)
        case .accepted:
            guard !intent.containerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .rejected("missing container id")
            }
            return .accepted(intent.action.rawValue)
        }
    }

    public func authorizeCraftingIntent(from rawPlayerID: String) -> LANCraftingIntentResult {
        switch authorize(.crafting, from: rawPlayerID) {
        case .accepted: return .accepted
        case .rejected(let reason): return .rejected(reason)
        }
    }

    public func authorizeCommandIntent(from rawPlayerID: String, ai: Bool = false) -> LANAuthorizationResult {
        authorize(ai ? .ai : .command, from: rawPlayerID)
    }

    public func applyTemplateIntent(
        _ intent: LANTemplateIntent,
        from rawPlayerID: String,
        world: World,
        loadTemplate: (String) throws -> ObjectTemplate?,
        saveTemplate: (ObjectTemplate) throws -> Bool
    ) -> LANTemplateIntentResult {
        let playerID = String(rawPlayerID.prefix(128))
        switch authorize(.template, from: playerID) {
        case .rejected(let reason): return .rejected(reason)
        case .accepted: break
        }
        guard !intent.templateName.isEmpty else { return .rejected("missing template name") }
        if intent.action != .undoPlacement {
            guard let peer = peers[playerID], let playerState = peer.playerState else {
                return .rejected("player state unavailable")
            }
            guard playerState.dimension == world.dim.rawValue else {
                return .rejected("target dimension unavailable")
            }
            guard isWithinLANReach(playerState, x: intent.x, y: intent.y, z: intent.z) else {
                return .rejected("target out of reach")
            }
        }
        switch intent.action {
        case .copyTarget:
            switch authorize(.build, from: playerID) {
            case .rejected(let reason): return .rejected(reason)
            case .accepted: break
            }
            do {
                let result = try cloneObjectTemplate(
                    named: intent.templateName,
                    from: world,
                    targetX: intent.x,
                    targetY: intent.y,
                    targetZ: intent.z
                )
                guard try saveTemplate(result.template) else {
                    return .rejected("template store write failed")
                }
                return .copied(name: result.template.name, blocks: result.template.blocks.count)
            } catch {
                return .rejected(String(describing: error))
            }
        case .placeTemplate:
            switch authorize(.build, from: playerID) {
            case .rejected(let reason): return .rejected(reason)
            case .accepted: break
            }
            do {
                guard let rawTemplate = try loadTemplate(intent.templateName) else {
                    return .rejected("unknown template")
                }
                let template = try rotatedObjectTemplate(rawTemplate, rotationSteps: intent.rotation)
                let undo = try objectTemplatePlacementUndoSnapshot(
                    for: template,
                    in: world,
                    targetX: intent.x,
                    targetY: intent.y,
                    targetZ: intent.z,
                    options: TemplatePlacementOptions(prepareTerrain: true)
                )
                let result = try placeObjectTemplate(
                    template,
                    in: world,
                    targetX: intent.x,
                    targetY: intent.y,
                    targetZ: intent.z,
                    options: TemplatePlacementOptions(prepareTerrain: true)
                )
                for block in template.blocks {
                    changeLog.record(LANBlockChange(
                        dimension: world.dim.rawValue,
                        x: intent.x + block.dx,
                        y: intent.y + block.dy,
                        z: intent.z + block.dz,
                        cell: Int(block.cell)
                    ))
                }
                if var peer = peers[playerID] {
                    peer.lastTemplateUndo = undo
                    peers[playerID] = peer
                }
                return .placed(
                    name: template.name,
                    blocks: result.blocksPlaced,
                    blockEntities: result.blockEntitiesPlaced,
                    cleared: result.blocksCleared,
                    filled: result.supportBlocksFilled
                )
            } catch {
                return .rejected(String(describing: error))
            }
        case .undoPlacement:
            guard var peer = peers[playerID], let undo = peer.lastTemplateUndo else {
                return .rejected("no template placement to undo")
            }
            let restored = restoreObjectTemplatePlacementUndo(undo, in: world)
            for cell in undo.cells {
                changeLog.record(LANBlockChange(dimension: world.dim.rawValue, x: cell.x, y: cell.y, z: cell.z, cell: cell.cell))
            }
            peer.lastTemplateUndo = nil
            peers[playerID] = peer
            return .undone(name: undo.templateName, restored: restored)
        }
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
        switch authorize(.build, from: playerID) {
        case .accepted: break
        case .rejected(let reason): return .rejected(reason)
        }
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
        worldState: LANWorldStateSnapshot?,
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
        var inventories = peerInventorySnapshots()
        inventories.insert(contentsOf: inventorySnapshots, at: 0)
        return LANReplicationBatch(
            tick: tick,
            fullSnapshot: fullSnapshot,
            world: worldSummary,
            worldState: worldState,
            players: players,
            blockChanges: blockChanges,
            chunkSections: chunkSections,
            entities: entitySnapshots,
            entitySnapshotsComplete: true,
            inventories: inventories
        )
    }
}

public final class LANMultiplayerClientSession {
    public private(set) var latestTick = 0
    public private(set) var worldSummary: LANWorldSummary?
    public private(set) var worldState: LANWorldStateSnapshot?
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
        if let state = batch.worldState { worldState = state }
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
        var wantedEntityIDs = Set<Int>()
        for entity in batch.entities.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES) {
            guard let snapshot = normalizedLANEntitySnapshot(entity) else {
                report.ignoredInvalidEntities += 1
                continue
            }
            if snapshot.dead {
                if entities.removeValue(forKey: snapshot.entityID) != nil {
                    report.removedEntitySnapshots += 1
                }
            } else {
                entities[snapshot.entityID] = snapshot
                wantedEntityIDs.insert(snapshot.entityID)
                report.appliedEntitySnapshots += 1
            }
        }
        if batch.entitySnapshotsComplete {
            for id in Array(entities.keys).sorted() where !wantedEntityIDs.contains(id) {
                entities.removeValue(forKey: id)
                report.removedEntitySnapshots += 1
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

public func makeLANPlayerState(_ player: Player, playerID: String, displayName: String, dimension: Int = Dim.overworld.rawValue) -> LANPlayerState {
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
        gameMode: player.gameMode,
        dimension: dimension,
        dead: player.dead || player.deathTime > 0
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

public func makeLANWorldStateSnapshot(in world: World) -> LANWorldStateSnapshot {
    LANWorldStateSnapshot(
        dimension: world.dim.rawValue,
        time: world.time,
        dayTime: world.dayTime,
        difficulty: world.difficulty,
        raining: world.raining,
        thundering: world.thundering,
        rainLevel: world.rainLevel,
        thunderLevel: world.thunderLevel,
        weatherTimer: world.weatherTimer
    )
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
        if ref is Player || (ref as? Entity)?.isPlayer == true { continue }
        if let aroundX, let aroundZ {
            let dx = ref.x - aroundX
            let dz = ref.z - aroundZ
            if dx * dx + dz * dz > radius2 { continue }
        }
        let entity = ref as? Entity
        let living = ref as? LivingEntity
        let item = ref as? ItemEntity
        let xp = ref as? XPOrb
        out.append(LANEntitySnapshot(
            entityID: ref.id,
            type: entity?.type ?? "entity",
            x: ref.x,
            y: ref.y,
            z: ref.z,
            yaw: entity?.yaw ?? 0,
            pitch: entity?.pitch ?? 0,
            health: living?.health,
            dead: ref.dead,
            itemID: item?.stack.id,
            itemCount: item?.stack.count,
            itemDamage: item?.stack.damage,
            itemLabel: item?.stack.label,
            xpAmount: xp?.amount
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

private let LAN_MIRRORED_ENTITY_PICKUP_DELAY = 1_000_000_000
private let LAN_MIRRORED_ENTITY_LIFETIME = 1_000_000_000

private func normalizedLANEntitySnapshot(_ raw: LANEntitySnapshot) -> LANEntitySnapshot? {
    let snapshot = LANEntitySnapshot(
        entityID: raw.entityID,
        type: raw.type,
        x: raw.x,
        y: raw.y,
        z: raw.z,
        yaw: raw.yaw,
        pitch: raw.pitch,
        health: raw.health,
        dead: raw.dead,
        itemID: raw.itemID,
        itemCount: raw.itemCount,
        itemDamage: raw.itemDamage,
        itemLabel: raw.itemLabel,
        xpAmount: raw.xpAmount
    )
    guard snapshot.entityID >= 0, snapshot.type != "player" else { return nil }
    if snapshot.dead { return snapshot }
    switch snapshot.type {
    case "item":
        guard let itemID = snapshot.itemID,
              itemID >= 0,
              itemID < itemDefs.count,
              let count = snapshot.itemCount,
              count > 0
        else { return nil }
    case "xp_orb":
        guard let amount = snapshot.xpAmount, amount > 0 else { return nil }
    default:
        guard entityTypes().contains(snapshot.type) else { return nil }
    }
    return snapshot
}

private func mirroredEntity(sourceID: Int, in world: World) -> Entity? {
    world.entities.first(where: {
        ($0 as? Entity)?.lanReplicationSourceID == sourceID
    }) as? Entity
}

private func itemStack(from snapshot: LANEntitySnapshot) -> ItemStack? {
    guard snapshot.type == "item",
          let itemID = snapshot.itemID,
          itemID >= 0,
          itemID < itemDefs.count,
          let count = snapshot.itemCount,
          count > 0
    else { return nil }
    let damage = max(0, snapshot.itemDamage ?? 0)
    let stack = ItemStack(itemID, min(count, maxStackOf(ItemStack(itemID, 1))), damage: damage, label: snapshot.itemLabel)
    return stack
}

private func makeMirroredEntity(from snapshot: LANEntitySnapshot, in world: World) -> Entity? {
    switch snapshot.type {
    case "item":
        guard itemStack(from: snapshot) != nil else { return nil }
        return ItemEntity(world: world)
    case "xp_orb":
        guard (snapshot.xpAmount ?? 0) > 0 else { return nil }
        return XPOrb(world: world)
    default:
        return createEntity(snapshot.type, world)
    }
}

private func applyMirroredEntityPayload(_ snapshot: LANEntitySnapshot, to entity: Entity) -> Bool {
    switch snapshot.type {
    case "item":
        guard let item = entity as? ItemEntity, let stack = itemStack(from: snapshot) else { return false }
        item.stack = stack
        item.pickupDelay = LAN_MIRRORED_ENTITY_PICKUP_DELAY
        item.lifeTime = LAN_MIRRORED_ENTITY_LIFETIME
    case "xp_orb":
        guard let orb = entity as? XPOrb, let amount = snapshot.xpAmount, amount > 0 else { return false }
        orb.amount = amount
        orb.followTarget = nil
        orb.lifeTime = LAN_MIRRORED_ENTITY_LIFETIME
    default:
        break
    }
    return true
}

private func configureMirroredEntity(_ entity: Entity, from snapshot: LANEntitySnapshot) {
    entity.lanReplicationSourceID = snapshot.entityID
    entity.lanReplicatedMirror = true
    entity.persistent = false
    entity.noClip = true
    entity.noGravity = true
    entity.vx = 0
    entity.vy = 0
    entity.vz = 0
    entity.setPos(snapshot.x, snapshot.y, snapshot.z)
    entity.yaw = snapshot.yaw
    entity.prevYaw = snapshot.yaw
    entity.pitch = snapshot.pitch
    entity.prevPitch = snapshot.pitch
    entity.fireTicks = 0
    if let living = entity as? LivingEntity, let health = snapshot.health {
        living.health = max(0, min(living.maxHealth, health))
        living.deathTime = living.health <= 0 ? max(1, living.deathTime) : 0
    }
}

@discardableResult
public func applyLANEntitySnapshots(
    _ snapshots: [LANEntitySnapshot],
    to world: World,
    removeMissing: Bool = true
) -> LANReplicationApplyReport {
    var report = LANReplicationApplyReport()
    var wantedSourceIDs = Set<Int>()

    for raw in snapshots.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES) {
        guard let snapshot = normalizedLANEntitySnapshot(raw) else {
            report.ignoredInvalidEntities += 1
            continue
        }
        if snapshot.dead {
            if let existing = mirroredEntity(sourceID: snapshot.entityID, in: world) {
                world.removeEntity(existing)
                report.removedEntitySnapshots += 1
            }
            continue
        }

        wantedSourceIDs.insert(snapshot.entityID)
        var entity = mirroredEntity(sourceID: snapshot.entityID, in: world)
        if let existing = entity, existing.type != snapshot.type {
            world.removeEntity(existing)
            report.removedEntitySnapshots += 1
            entity = nil
        }
        if entity == nil {
            guard let created = makeMirroredEntity(from: snapshot, in: world) else {
                report.ignoredInvalidEntities += 1
                continue
            }
            entity = created
            world.addEntity(created)
        }
        guard let entity, applyMirroredEntityPayload(snapshot, to: entity) else {
            if let entity { world.removeEntity(entity) }
            report.ignoredInvalidEntities += 1
            continue
        }
        configureMirroredEntity(entity, from: snapshot)
        report.appliedEntitySnapshots += 1
    }

    if removeMissing {
        for ref in Array(world.entities) {
            guard let entity = ref as? Entity,
                  entity.lanReplicatedMirror,
                  let sourceID = entity.lanReplicationSourceID,
                  !wantedSourceIDs.contains(sourceID)
            else { continue }
            world.removeEntity(entity)
            report.removedEntitySnapshots += 1
        }
    }

    return report
}

@discardableResult
public func applyLANReplicationBatch(_ batch: LANReplicationBatch, to world: World) -> LANReplicationApplyReport {
    var report = LANReplicationApplyReport()
    if let worldState = batch.worldState {
        _ = applyLANWorldStateSnapshot(worldState, to: world)
    }
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
    let entityReport = applyLANEntitySnapshots(batch.entities, to: world, removeMissing: batch.entitySnapshotsComplete)
    report.appliedEntitySnapshots += entityReport.appliedEntitySnapshots
    report.removedEntitySnapshots += entityReport.removedEntitySnapshots
    report.ignoredInvalidEntities += entityReport.ignoredInvalidEntities
    return report
}

@discardableResult
public func applyLANWorldStateSnapshot(_ snapshot: LANWorldStateSnapshot, to world: World) -> Bool {
    let normalized = LANWorldStateSnapshot(
        dimension: snapshot.dimension,
        time: snapshot.time,
        dayTime: snapshot.dayTime,
        difficulty: snapshot.difficulty,
        raining: snapshot.raining,
        thundering: snapshot.thundering,
        rainLevel: snapshot.rainLevel,
        thunderLevel: snapshot.thunderLevel,
        weatherTimer: snapshot.weatherTimer
    )
    guard normalized.dimension == world.dim.rawValue else { return false }
    world.time = normalized.time
    world.dayTime = normalized.dayTime
    world.difficulty = normalized.difficulty
    world.raining = normalized.raining
    world.thundering = normalized.thundering
    world.rainLevel = normalized.rainLevel
    world.thunderLevel = normalized.thunderLevel
    world.weatherTimer = normalized.weatherTimer
    return true
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
