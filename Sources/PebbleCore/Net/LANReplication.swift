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
    public var deferredBlockChanges = 0
    public var ignoredInvalidEntities = 0
    public var appliedBlockEntities = 0
    public var ignoredInvalidBlockEntities = 0
    public var deferredBlockEntities = 0

    public init() {}

    public mutating func merge(_ other: LANReplicationApplyReport) {
        appliedBlockChanges += other.appliedBlockChanges
        appliedChunkSections += other.appliedChunkSections
        appliedEntitySnapshots += other.appliedEntitySnapshots
        removedEntitySnapshots += other.removedEntitySnapshots
        ignoredInvalidCells += other.ignoredInvalidCells
        ignoredInvalidSections += other.ignoredInvalidSections
        ignoredUnloadedBlockChanges += other.ignoredUnloadedBlockChanges
        deferredBlockChanges += other.deferredBlockChanges
        ignoredInvalidEntities += other.ignoredInvalidEntities
        appliedBlockEntities += other.appliedBlockEntities
        ignoredInvalidBlockEntities += other.ignoredInvalidBlockEntities
        deferredBlockEntities += other.deferredBlockEntities
    }
}

public enum LANBlockIntentResult: Equatable {
    case applied([LANBlockChange])
    case ignored(String)
    case rejected(String)
}

public enum LANContainerEditResult: Equatable {
    case applied(blockEntities: [LANBlockEntitySnapshot])
    case rejected(String)
}

public let LAN_MULTIPLAYER_HOST_ENTITY_REPLICATION_INTERVAL = 0.20
public let LAN_MULTIPLAYER_HOST_COMPLETE_ENTITY_REPLICATION_INTERVAL = 1.0
public let LAN_MULTIPLAYER_HOST_BLOCK_ENTITY_FILL_INTERVAL = 0.50
public let LAN_MULTIPLAYER_HOST_WORLD_STATE_INTERVAL = 1.0
public let LAN_MULTIPLAYER_HOST_INVENTORY_REPLICATION_INTERVAL = 1.0
public let LAN_MULTIPLAYER_HOST_WORLD_SUMMARY_INTERVAL = 1.0

public struct LANHostReplicationBackgroundSelection: Equatable {
    public var includeWorldSummary: Bool
    public var includeWorldState: Bool
    public var includeEntitySnapshots: Bool
    public var entitySnapshotsComplete: Bool
    public var includeBlockEntityFill: Bool
    public var includeInventories: Bool

    public init(
        includeWorldSummary: Bool = false,
        includeWorldState: Bool = false,
        includeEntitySnapshots: Bool = false,
        entitySnapshotsComplete: Bool = false,
        includeBlockEntityFill: Bool = false,
        includeInventories: Bool = false
    ) {
        self.includeWorldSummary = includeWorldSummary
        self.includeWorldState = includeWorldState
        self.includeEntitySnapshots = includeEntitySnapshots
        self.entitySnapshotsComplete = entitySnapshotsComplete
        self.includeBlockEntityFill = includeBlockEntityFill
        self.includeInventories = includeInventories
    }

    public var hasContent: Bool {
        includeWorldSummary || includeWorldState || includeEntitySnapshots || includeBlockEntityFill || includeInventories
    }
}

public struct LANHostReplicationCadence: Equatable {
    public var entityInterval: Double
    public var completeEntityInterval: Double
    public var blockEntityFillInterval: Double
    public var worldStateInterval: Double
    public var inventoryInterval: Double
    public var worldSummaryInterval: Double

    public init(
        entityInterval: Double = LAN_MULTIPLAYER_HOST_ENTITY_REPLICATION_INTERVAL,
        completeEntityInterval: Double = LAN_MULTIPLAYER_HOST_COMPLETE_ENTITY_REPLICATION_INTERVAL,
        blockEntityFillInterval: Double = LAN_MULTIPLAYER_HOST_BLOCK_ENTITY_FILL_INTERVAL,
        worldStateInterval: Double = LAN_MULTIPLAYER_HOST_WORLD_STATE_INTERVAL,
        inventoryInterval: Double = LAN_MULTIPLAYER_HOST_INVENTORY_REPLICATION_INTERVAL,
        worldSummaryInterval: Double = LAN_MULTIPLAYER_HOST_WORLD_SUMMARY_INTERVAL
    ) {
        self.entityInterval = max(0.01, entityInterval)
        self.completeEntityInterval = max(0.01, completeEntityInterval)
        self.blockEntityFillInterval = max(0.01, blockEntityFillInterval)
        self.worldStateInterval = max(0.01, worldStateInterval)
        self.inventoryInterval = max(0.01, inventoryInterval)
        self.worldSummaryInterval = max(0.01, worldSummaryInterval)
    }

    public func backgroundSelection(
        now: Double,
        lastEntitySnapshot: Double,
        lastCompleteEntitySnapshot: Double,
        lastBlockEntityFill: Double,
        lastWorldStateSnapshot: Double,
        lastInventorySnapshot: Double,
        lastWorldSummary: Double
    ) -> LANHostReplicationBackgroundSelection {
        let completeEntities = lastCompleteEntitySnapshot == 0 || now - lastCompleteEntitySnapshot >= completeEntityInterval
        let includeEntities = completeEntities || lastEntitySnapshot == 0 || now - lastEntitySnapshot >= entityInterval
        return LANHostReplicationBackgroundSelection(
            includeWorldSummary: lastWorldSummary == 0 || now - lastWorldSummary >= worldSummaryInterval,
            includeWorldState: lastWorldStateSnapshot == 0 || now - lastWorldStateSnapshot >= worldStateInterval,
            includeEntitySnapshots: includeEntities,
            entitySnapshotsComplete: completeEntities,
            includeBlockEntityFill: lastBlockEntityFill == 0 || now - lastBlockEntityFill >= blockEntityFillInterval,
            includeInventories: lastInventorySnapshot == 0 || now - lastInventorySnapshot >= inventoryInterval
        )
    }
}

private func lanFacingMeta(fromPlayerYaw yaw: Double) -> Int {
    let direction = yawToDir(yaw * 180 / .pi)
    return [0, 0, 0, 1, 2, 3][direction]
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
        var inventoryRevision = 0
        var lastGrantID = 0
        var deathEpoch = 0
        var deathHandledEpoch = 0
        var lastTemplateUndo: TemplatePlacementUndoSnapshot?
        var lastAckTick = 0
        var lastAckSequence: UInt32 = 0
        var lastSeenTick = 0
        var disconnectedTick: Int?
    }

    /// snapshot captured once per epoch by `consumeDeathDrops(for:)`; keyed by playerID for deterministic lookup.
    private struct PendingDeathDrop {
        var inventory: LANPlayerInventorySnapshot
        var x: Double
        var y: Double
        var z: Double
    }

    private var peers: [String: Peer] = [:]
    private var nextOrdinal = 0
    private let changeLog = LANReplicationChangeLog()
    private var pendingGrants: [String: [LANInventoryGrant]] = [:]
    private var pendingDeathDrops: [String: PendingDeathDrop] = [:]
    private var dirtyBlockEntityPositions: [LANBlockPosition] = []
    private var dirtyBlockEntitySet: Set<LANBlockPosition> = []

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
            inventory: LANPlayerInventorySnapshot(playerID: playerID, selectedHotbarSlot: 0, slots: []),
            lastTemplateUndo: nil,
            lastAckSequence: 0,
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
        let wasAlive = peer.lifecycle != .dead
        if wasAlive && sanitized.dead {
            peer.deathEpoch += 1
            pendingDeathDrops[playerID] = PendingDeathDrop(
                inventory: peer.inventory ?? LANPlayerInventorySnapshot(playerID: peer.playerID, selectedHotbarSlot: 0, slots: []),
                x: sanitized.x,
                y: sanitized.y,
                z: sanitized.z
            )
            peer.inventory = LANPlayerInventorySnapshot(playerID: peer.playerID, selectedHotbarSlot: 0, slots: [])
        }
        peer.playerState = sanitized
        peer.lifecycle = sanitized.dead ? .dead : .connected
        peer.lastSeenTick = max(peer.lastSeenTick, tick)
        peer.disconnectedTick = nil
        peers[playerID] = peer
        return sanitized
    }

    /// Consumes the death-drop payload recorded on the most recent alive->dead transition, exactly
    /// once per `deathEpoch`. Returns nil if no drop is pending or it was already handled this epoch.
    @discardableResult
    public func consumeDeathDrops(for rawPlayerID: String) -> (inventory: LANPlayerInventorySnapshot, x: Double, y: Double, z: Double)? {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID], peer.deathHandledEpoch < peer.deathEpoch,
              let drop = pendingDeathDrops[playerID]
        else { return nil }
        peer.deathHandledEpoch = peer.deathEpoch
        peers[playerID] = peer
        pendingDeathDrops.removeValue(forKey: playerID)
        return (drop.inventory, drop.x, drop.y, drop.z)
    }

    public func recordInventorySnapshot(_ snapshot: LANPlayerInventorySnapshot, from rawPlayerID: String) {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID],
              let normalized = normalizedLANInventorySnapshot(snapshot)
        else { return }
        peer.inventory = LANPlayerInventorySnapshot(
            playerID: peer.playerID,
            selectedHotbarSlot: normalized.selectedHotbarSlot,
            slots: normalized.slots,
            xp: normalized.xp,
            xpLevel: normalized.xpLevel,
            xpProgress: normalized.xpProgress
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
            inventoryRevision: peer.inventoryRevision,
            lastAckTick: peer.lastAckTick,
            lastSeenTick: peer.lastSeenTick,
            disconnectedTick: peer.disconnectedTick
        )
    }

    /// Preloads a peer record from persisted storage (e.g. `SaveDB.getLANPlayer`) so a
    /// reconnecting guest's position/inventory/permissions survive a host restart.
    /// No-ops if a peer with the same ID is already tracked (a live session always wins).
    public func seedPeerRecord(_ record: LANPeerRecordSnapshot) {
        let playerID = String(record.playerID.prefix(128))
        guard peers[playerID] == nil else { return }
        peers[playerID] = Peer(
            playerID: playerID,
            displayName: sanitizedLANPlayerName(record.displayName),
            joinedOrdinal: nextOrdinal,
            lifecycle: .disconnected,
            permissions: record.permissions,
            playerState: record.playerState,
            inventory: record.inventory,
            inventoryRevision: max(0, record.inventoryRevision),
            lastGrantID: 0,
            deathEpoch: 0,
            deathHandledEpoch: 0,
            lastTemplateUndo: nil,
            lastAckTick: max(0, record.lastAckTick),
            lastAckSequence: 0,
            lastSeenTick: max(0, record.lastSeenTick),
            disconnectedTick: record.disconnectedTick
        )
        nextOrdinal += 1
    }

    public func recordAck(_ ack: LANReplicationAck, from rawPlayerID: String) {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID] else { return }
        peer.lastAckTick = max(peer.lastAckTick, ack.tick)
        peer.lastAckSequence = max(peer.lastAckSequence, ack.receivedSequence)
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

    public func peerInventorySnapshotsByPlayerID() -> [String: LANPlayerInventorySnapshot] {
        var out: [String: LANPlayerInventorySnapshot] = [:]
        for snapshot in peerInventorySnapshots() {
            out[snapshot.playerID] = snapshot
        }
        return out
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

    private func applyOpenableBlockUseIntent(_ intent: LANBlockIntent, playerState: LANPlayerState, to world: World) -> LANBlockIntentResult {
        let targetCell = world.getBlock(intent.x, intent.y, intent.z)
        guard isValidLANReplicatedCell(targetCell), targetCell != 0 else {
            return .ignored("missing use target")
        }
        let id = targetCell >> 4
        guard id > 0, id < blockDefs.count else { return .rejected("invalid use target") }
        let meta = targetCell & 15
        let shape = Shape(rawValue: SHAPE_OF[id]) ?? .cube

        if shape == .door {
            guard id != Int(B.iron_door) else { return .ignored("unsupported use target") }
            let lowerY = (meta & 8) != 0 ? intent.y - 1 : intent.y
            let lowerCell = world.getBlock(intent.x, lowerY, intent.z)
            guard isValidLANReplicatedCell(lowerCell), (lowerCell >> 4) == id else {
                return .ignored("missing door base")
            }
            let updatedCell = Int(cell(UInt16(id), (lowerCell & 15) ^ 4))
            _ = world.setBlock(intent.x, lowerY, intent.z, updatedCell)
            world.hooks.playSound((lowerCell & 4) != 0 ? "block.wooden_door.close" : "block.wooden_door.open", Double(intent.x) + 0.5, Double(intent.y) + 0.5, Double(intent.z) + 0.5, 1, 1)
            let change = LANBlockChange(dimension: world.dim.rawValue, x: intent.x, y: lowerY, z: intent.z, cell: updatedCell)
            changeLog.record(change)
            return .applied([change])
        }

        if shape == .trapdoor {
            guard id != Int(B.iron_trapdoor) else { return .ignored("unsupported use target") }
            let updatedCell = Int(cell(UInt16(id), meta ^ 4))
            _ = world.setBlock(intent.x, intent.y, intent.z, updatedCell)
            world.hooks.playSound((meta & 4) != 0 ? "block.wooden_trapdoor.close" : "block.wooden_trapdoor.open", Double(intent.x) + 0.5, Double(intent.y) + 0.5, Double(intent.z) + 0.5, 1, 1)
            let change = LANBlockChange(dimension: world.dim.rawValue, x: intent.x, y: intent.y, z: intent.z, cell: updatedCell)
            changeLog.record(change)
            return .applied([change])
        }

        if shape == .fenceGate {
            var updatedMeta = meta ^ 4
            if (updatedMeta & 4) != 0 {
                let facing = lanFacingMeta(fromPlayerYaw: playerState.yaw)
                updatedMeta = (updatedMeta & 12) | facing
                if (meta & 3) == ((facing + 2) % 4) {
                    updatedMeta = (updatedMeta & 12) | facing
                }
            }
            let updatedCell = Int(cell(UInt16(id), updatedMeta))
            _ = world.setBlock(intent.x, intent.y, intent.z, updatedCell)
            world.hooks.playSound((meta & 4) != 0 ? "block.fence_gate.close" : "block.fence_gate.open", Double(intent.x) + 0.5, Double(intent.y) + 0.5, Double(intent.z) + 0.5, 1, 1)
            let change = LANBlockChange(dimension: world.dim.rawValue, x: intent.x, y: intent.y, z: intent.z, cell: updatedCell)
            changeLog.record(change)
            return .applied([change])
        }

        return .ignored("unsupported use target")
    }

    public func applyBlockIntent(_ intent: LANBlockIntent, from rawPlayerID: String, to world: World) -> LANBlockIntentResult {
        let playerID = String(rawPlayerID.prefix(128))
        guard let peer = peers[playerID] else { return .rejected("unknown player") }
        switch authorize(.build, from: playerID) {
        case .accepted: break
        case .rejected(let reason): return .rejected(reason)
        }
        guard let playerState = peer.playerState else { return .rejected("player state unavailable") }
        guard playerState.dimension == world.dim.rawValue else {
            return .rejected("target dimension unavailable")
        }
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
            return applyOpenableBlockUseIntent(intent, playerState: playerState, to: world)
        }
    }

    /// Validates and applies a block-entity container edit (D-C): authorizes `.container`,
    /// reach-checks every target, verifies the submitted snapshot is compatible with the block
    /// actually at each position, gates the edit by a host content revision, then applies the
    /// submitted block entities as one transaction. Also stores the peer's published inventory,
    /// revision-gated. Fails closed on any validation error.
    public func applyContainerEditIntent(
        _ intent: LANContainerEditIntent,
        from rawPlayerID: String,
        to world: World
    ) -> LANContainerEditResult {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID] else { return .rejected("unknown player") }
        switch authorize(.container, from: playerID) {
        case .accepted: break
        case .rejected(let reason): return .rejected(reason)
        }
        guard let playerState = peer.playerState else { return .rejected("player state unavailable") }
        guard playerState.dimension == world.dim.rawValue else {
            return .rejected("target dimension unavailable")
        }
        guard let normalizedInventory = normalizedLANInventorySnapshot(intent.inventory) else {
            return .rejected("invalid inventory payload")
        }
        guard let beforeInventory = peer.inventory else {
            return .rejected("player inventory baseline unavailable")
        }
        let rawBlockEntities = [intent.blockEntity] + intent.additionalBlockEntities
        guard rawBlockEntities.count <= LAN_MULTIPLAYER_MAX_CONTAINER_EDIT_BLOCK_ENTITIES else {
            return .rejected("too many container targets")
        }
        var seenPositions = Set<LANBlockPosition>()
        var beforeBlockEntities: [LANBlockEntitySnapshot] = []
        var afterBlockEntities: [LANBlockEntitySnapshot] = []
        var targets: [BlockEntityData] = []
        for raw in rawBlockEntities {
            guard let normalized = normalizedLANBlockEntitySnapshot(raw) else {
                return .rejected("invalid container payload")
            }
            let key = LANBlockPosition(dimension: normalized.dimension, x: normalized.x, y: normalized.y, z: normalized.z)
            guard seenPositions.insert(key).inserted else {
                return .rejected("duplicate container target")
            }
            guard isWithinLANReach(playerState, x: normalized.x, y: normalized.y, z: normalized.z) else {
                return .rejected("target out of reach")
            }
            guard normalized.dimension == world.dim.rawValue else {
                return .rejected("target dimension unavailable")
            }
            let targetCell = world.getBlock(normalized.x, normalized.y, normalized.z)
            guard isLANBlockEntitySnapshotCompatible(normalized, cell: targetCell) else {
                return .rejected("incompatible container target")
            }
            let existing = world.getBlockEntity(normalized.x, normalized.y, normalized.z)
            let target = existing?.type == normalized.type ? existing! : makeBlockEntity(from: normalized)
            guard let beforeBlockEntity = makeLANBlockEntitySnapshot(target, dimension: world.dim.rawValue),
                  beforeBlockEntity.type == normalized.type
            else {
                return .rejected("container edit is not host-verifiable")
            }
            beforeBlockEntities.append(beforeBlockEntity)
            afterBlockEntities.append(normalized)
            targets.append(target)
        }
        guard lanBlockEntityRevision(beforeBlockEntities) == intent.blockEntityRevision else {
            return .rejected("stale container revision")
        }
        guard isLANContainerEditItemTransitionAllowed(
            beforeInventory: beforeInventory,
            afterInventory: normalizedInventory,
            beforeBlockEntities: beforeBlockEntities,
            afterBlockEntities: afterBlockEntities
        ) else {
            return .rejected("container edit is not host-verifiable")
        }
        for normalized in afterBlockEntities {
            let probe = makeBlockEntity(from: normalized)
            guard applyLANBlockEntityPayload(normalized, to: probe) else {
                return .rejected("invalid container payload")
            }
        }
        for (normalized, target) in zip(afterBlockEntities, targets) {
            _ = applyLANBlockEntityPayload(normalized, to: target)
            world.setBlockEntity(target)
            recordDirtyBlockEntity(LANBlockPosition(dimension: normalized.dimension, x: normalized.x, y: normalized.y, z: normalized.z))
        }

        if intent.revision > peer.inventoryRevision {
            peer.inventory = LANPlayerInventorySnapshot(
                playerID: peer.playerID,
                selectedHotbarSlot: normalizedInventory.selectedHotbarSlot,
                slots: normalizedInventory.slots,
                xp: normalizedInventory.xp,
                xpLevel: normalizedInventory.xpLevel,
                xpProgress: normalizedInventory.xpProgress
            )
            peer.inventoryRevision = intent.revision
            peers[playerID] = peer
        }
        return .applied(blockEntities: afterBlockEntities)
    }

    /// Applies a client-published inventory update if strictly newer than the stored revision
    /// (monotone; stale/regressed updates are ignored). Validates every slot; rejects the whole
    /// update (fail closed) if any slot is malformed.
    @discardableResult
    public func applyInventoryUpdate(_ update: LANInventoryUpdate, from rawPlayerID: String) -> Bool {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID] else { return false }
        guard update.revision > peer.inventoryRevision else { return false }
        guard let normalized = normalizedLANInventorySnapshot(update.snapshot) else { return false }
        peer.inventory = LANPlayerInventorySnapshot(
            playerID: peer.playerID,
            selectedHotbarSlot: normalized.selectedHotbarSlot,
            slots: normalized.slots,
            xp: normalized.xp,
            xpLevel: normalized.xpLevel,
            xpProgress: normalized.xpProgress
        )
        peer.inventoryRevision = update.revision
        peers[playerID] = peer
        return true
    }

    /// Enqueues a host-originated inventory grant (pickup/correction/death-clear) for delivery to
    /// the given peer. `items` merge additively; `slots`/`clearedSlots` replace exact slot indices
    /// (arrangement-preserving corrections). `grantID` is monotone per peer for de-duplication.
    @discardableResult
    public func enqueueGrant(
        items: [LANInventorySlotSnapshot],
        xp: Int,
        clearAll: Bool,
        to rawPlayerID: String,
        slots: [LANInventorySlotSnapshot] = [],
        clearedSlots: [Int] = []
    ) -> LANInventoryGrant? {
        let playerID = String(rawPlayerID.prefix(128))
        guard var peer = peers[playerID] else { return nil }
        peer.lastGrantID += 1
        let grant = LANInventoryGrant(
            playerID: peer.playerID,
            grantID: peer.lastGrantID,
            items: items,
            xp: xp,
            clearAll: clearAll,
            slots: slots,
            clearedSlots: clearedSlots
        )
        peers[playerID] = peer
        pendingGrants[playerID, default: []].append(grant)
        return grant
    }

    /// Drains queued grants for one peer, in enqueue order.
    public func drainGrants(for rawPlayerID: String) -> [LANInventoryGrant] {
        let playerID = String(rawPlayerID.prefix(128))
        guard let queued = pendingGrants[playerID], !queued.isEmpty else { return [] }
        pendingGrants[playerID] = []
        return queued
    }

    /// Drains all queued grants across every peer, in deterministic playerID order.
    public func drainAllGrants() -> [LANInventoryGrant] {
        var out: [LANInventoryGrant] = []
        for playerID in pendingGrants.keys.sorted() {
            out.append(contentsOf: pendingGrants[playerID] ?? [])
        }
        pendingGrants.removeAll()
        return out
    }

    /// Marks a block entity position dirty for prioritized replication (container edits, ghost
    /// break spills). Deduplicated; drained in first-marked order.
    public func recordDirtyBlockEntity(_ position: LANBlockPosition) {
        guard dirtyBlockEntitySet.insert(position).inserted else { return }
        dirtyBlockEntityPositions.append(position)
    }

    /// Drains the dirty block-entity position queue in the order positions were first marked.
    public func drainDirtyBlockEntities() -> [LANBlockPosition] {
        let out = dirtyBlockEntityPositions
        dirtyBlockEntityPositions.removeAll()
        dirtyBlockEntitySet.removeAll()
        return out
    }

    public func requeueDirtyBlockEntities(_ positions: [LANBlockPosition]) {
        for position in positions {
            recordDirtyBlockEntity(position)
        }
    }

    /// Builds the restore payload sent to a reconnecting/joining peer so its client authoritatively
    /// re-adopts its last known position + inventory + revision + grant baseline.
    public func peerRestoreState(playerID rawPlayerID: String) -> LANRestoreState? {
        let playerID = String(rawPlayerID.prefix(128))
        guard let peer = peers[playerID], let playerState = peer.playerState else { return nil }
        let inventory = peer.inventory ?? LANPlayerInventorySnapshot(playerID: peer.playerID, selectedHotbarSlot: 0, slots: [])
        return LANRestoreState(
            playerState: playerState,
            inventory: inventory,
            revision: peer.inventoryRevision,
            grantID: peer.lastGrantID
        )
    }

    /// Re-records previously drained block changes (amendment A4): used when an encode attempt
    /// fails so the drained deltas are never silently lost. Preserves the change log's normal
    /// per-position coalescing/ordering semantics as if the changes had never been drained.
    public func requeueBlockChanges(_ changes: [LANBlockChange]) {
        for change in changes {
            changeLog.record(change)
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
        entitySnapshotsComplete: Bool,
        inventorySnapshots: [LANPlayerInventorySnapshot],
        blockEntitySnapshots: [LANBlockEntitySnapshot] = [],
        includePeerInventories: Bool = true
    ) -> LANReplicationBatch {
        var players = peerPlayerStates()
        if let localPlayer {
            players.insert(localPlayer, at: 0)
        }
        let blockChanges = fullSnapshot ? pendingBlockChanges() : drainBlockChanges()
        var inventories = includePeerInventories ? peerInventorySnapshots() : []
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
            entitySnapshotsComplete: entitySnapshotsComplete,
            inventories: inventories,
            blockEntities: blockEntitySnapshots
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
    public private(set) var blockEntities: [LANBlockPosition: LANBlockEntitySnapshot] = [:]
    /// Baseline tracking for client-authoritative inventory (D-A): the last host grant this client
    /// has merged, and the client's own published inventory revision. `apply(_:)` never mutates
    /// local player inventory from a normal batch — only `applyRestore(_:)` / grant merges do.
    public private(set) var lastAppliedGrantID = 0
    public private(set) var localRevision = 0

    public init() {}

    /// Establishes the authoritative baseline from a host `LANRestoreState` (join/reconnect).
    /// Host restore always wins over any local resume state; caller is responsible for applying
    /// `restore.playerState`/`restore.inventory` to the local `Player` (GameCore concern).
    public func applyRestore(_ restore: LANRestoreState) {
        localRevision = restore.revision
        lastAppliedGrantID = restore.grantID
    }

    /// Records that a grant has been merged locally, guarding against duplicate/regressed grants.
    /// Returns false (no-op) if `grantID` is not strictly newer than the last applied grant.
    @discardableResult
    public func markGrantApplied(_ grantID: Int) -> Bool {
        guard grantID > lastAppliedGrantID else { return false }
        lastAppliedGrantID = grantID
        return true
    }

    /// Bumps and returns the local inventory revision after a client-side inventory change.
    @discardableResult
    public func bumpLocalRevision() -> Int {
        localRevision += 1
        return localRevision
    }

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
            guard let normalized = normalizedLANInventorySnapshot(inventory) else { continue }
            inventories[normalized.playerID] = normalized
        }
        for blockEntity in batch.blockEntities.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES) {
            guard let normalized = normalizedLANBlockEntitySnapshot(blockEntity) else {
                report.ignoredInvalidBlockEntities += 1
                continue
            }
            let key = LANBlockPosition(dimension: normalized.dimension, x: normalized.x, y: normalized.y, z: normalized.z)
            blockEntities[key] = normalized
            report.appliedBlockEntities += 1
        }
        return report
    }
}

public struct LANDeferredReplicationBuffer {
    private var blockChangesByPosition: [LANBlockPosition: LANBlockChange] = [:]
    private var blockChangeOrder: [LANBlockPosition] = []
    private var blockEntitiesByPosition: [LANBlockPosition: LANBlockEntitySnapshot] = [:]
    private var blockEntityOrder: [LANBlockPosition] = []

    public init() {}

    public var pendingBlockChangeCount: Int { blockChangesByPosition.count }
    public var pendingBlockEntityCount: Int { blockEntitiesByPosition.count }

    public mutating func removeAll() {
        blockChangesByPosition.removeAll()
        blockChangeOrder.removeAll()
        blockEntitiesByPosition.removeAll()
        blockEntityOrder.removeAll()
    }

    public mutating func queue(_ change: LANBlockChange) {
        let position = LANBlockPosition(dimension: change.dimension, x: change.x, y: change.y, z: change.z)
        if blockChangesByPosition[position] == nil {
            if blockChangeOrder.count >= LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES {
                let removed = blockChangeOrder.removeFirst()
                blockChangesByPosition.removeValue(forKey: removed)
            }
            blockChangeOrder.append(position)
        }
        blockChangesByPosition[position] = change
    }

    public mutating func queue(_ snapshot: LANBlockEntitySnapshot) {
        let position = LANBlockPosition(dimension: snapshot.dimension, x: snapshot.x, y: snapshot.y, z: snapshot.z)
        if blockEntitiesByPosition[position] == nil {
            if blockEntityOrder.count >= LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES {
                let removed = blockEntityOrder.removeFirst()
                blockEntitiesByPosition.removeValue(forKey: removed)
            }
            blockEntityOrder.append(position)
        }
        blockEntitiesByPosition[position] = snapshot
    }

    @discardableResult
    public mutating func applyReadyBlockChanges(to world: World) -> LANReplicationApplyReport {
        var report = LANReplicationApplyReport()
        for position in blockChangeOrder {
            guard let change = blockChangesByPosition[position] else { continue }
            guard change.dimension == world.dim.rawValue, isValidLANReplicatedCell(change.cell) else {
                report.ignoredInvalidCells += 1
                blockChangesByPosition.removeValue(forKey: position)
                continue
            }
            guard world.getChunkAt(change.x, change.z) != nil else { continue }
            _ = world.setBlock(change.x, change.y, change.z, change.cell)
            report.appliedBlockChanges += 1
            blockChangesByPosition.removeValue(forKey: position)
        }
        blockChangeOrder.removeAll { blockChangesByPosition[$0] == nil }
        return report
    }

    @discardableResult
    public mutating func applyReadyBlockEntities(to world: World) -> LANReplicationApplyReport {
        var report = LANReplicationApplyReport()
        for position in blockEntityOrder {
            guard let snapshot = blockEntitiesByPosition[position] else { continue }
            guard snapshot.dimension == world.dim.rawValue,
                  let normalized = normalizedLANBlockEntitySnapshot(snapshot)
            else {
                report.ignoredInvalidBlockEntities += 1
                blockEntitiesByPosition.removeValue(forKey: position)
                continue
            }
            guard let chunk = world.getChunkAt(normalized.x, normalized.z) else { continue }
            guard chunk.inYRange(normalized.y),
                  isLANBlockEntitySnapshotCompatible(normalized, cell: world.getBlock(normalized.x, normalized.y, normalized.z))
            else {
                report.ignoredInvalidBlockEntities += 1
                blockEntitiesByPosition.removeValue(forKey: position)
                continue
            }
            let existing = world.getBlockEntity(normalized.x, normalized.y, normalized.z)
            let target = existing?.type == normalized.type ? existing! : makeBlockEntity(from: normalized)
            guard applyLANBlockEntityPayload(normalized, to: target) else {
                report.ignoredInvalidBlockEntities += 1
                blockEntitiesByPosition.removeValue(forKey: position)
                continue
            }
            world.setBlockEntity(target)
            report.appliedBlockEntities += 1
            blockEntitiesByPosition.removeValue(forKey: position)
        }
        blockEntityOrder.removeAll { blockEntitiesByPosition[$0] == nil }
        return report
    }

    @discardableResult
    public mutating func applyReady(to world: World) -> LANReplicationApplyReport {
        var report = applyReadyBlockChanges(to: world)
        report.merge(applyReadyBlockEntities(to: world))
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

private func makeLANInventorySlotSnapshots(_ inventory: [ItemStack?]) -> [LANInventorySlotSnapshot] {
    inventory.enumerated().compactMap { index, stack -> LANInventorySlotSnapshot? in
        guard let stack, stack.count > 0, stack.id >= 0, stack.id < itemDefs.count else { return nil }
        return LANInventorySlotSnapshot(
            slot: index,
            itemID: stack.id,
            count: stack.count,
            damage: stack.damage,
            label: stack.label
        )
    }
}

public func makeLANInventorySnapshot(_ player: Player, playerID: String) -> LANPlayerInventorySnapshot {
    LANPlayerInventorySnapshot(
        playerID: playerID,
        selectedHotbarSlot: player.selectedSlot,
        slots: makeLANInventorySlotSnapshots(player.inventory),
        xp: player.xp,
        xpLevel: player.xpLevel,
        xpProgress: player.xpProgress
    )
}

public func makeLANInventorySnapshot(_ player: LANRemotePlayerEntity) -> LANPlayerInventorySnapshot {
    LANPlayerInventorySnapshot(
        playerID: player.multiplayerPlayerID,
        selectedHotbarSlot: player.selectedSlot,
        slots: makeLANInventorySlotSnapshots(player.inventory),
        xp: player.xp,
        xpLevel: player.xpLevel,
        xpProgress: player.xpProgress
    )
}

public func makeLANRemotePlayerInventorySnapshots(in world: World) -> [LANPlayerInventorySnapshot] {
    world.entities
        .compactMap { $0 as? LANRemotePlayerEntity }
        .filter { !$0.dead }
        .sorted { $0.multiplayerPlayerID < $1.multiplayerPlayerID }
        .prefix(LAN_MULTIPLAYER_MAX_REPLICATION_INVENTORIES)
        .map { makeLANInventorySnapshot($0) }
}

private let LAN_REPLICATED_BLOCK_ENTITY_TYPES: Set<String> = [
    "container",
    "hopper",
    "furnace",
    "brewing",
    "shelf",
    "campfire",
    "crafting",
]

private func makeLANBlockEntitySlotSnapshots(_ items: [ItemStack?]) -> [LANBlockEntitySlotSnapshot] {
    items.enumerated().compactMap { index, stack -> LANBlockEntitySlotSnapshot? in
        guard let stack,
              stack.count > 0,
              stack.id >= 0,
              stack.id < itemDefs.count,
              index < LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS
        else { return nil }
        return LANBlockEntitySlotSnapshot(
            slot: index,
            itemID: stack.id,
            count: min(stack.count, maxStackOf(ItemStack(stack.id, 1))),
            damage: stack.damage,
            label: stack.label
        )
    }
}

public func makeLANBlockEntitySnapshot(_ be: BlockEntityData, dimension: Int) -> LANBlockEntitySnapshot? {
    guard let items = be.items,
          !items.isEmpty,
          items.count <= LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS,
          LAN_REPLICATED_BLOCK_ENTITY_TYPES.contains(be.type)
    else { return nil }

    return LANBlockEntitySnapshot(
        dimension: dimension,
        x: be.x,
        y: be.y,
        z: be.z,
        type: be.type,
        slotCount: items.count,
        slots: makeLANBlockEntitySlotSnapshots(items),
        kind: be.kind,
        burnTime: be.burnTime,
        burnTotal: be.burnTotal,
        cookTime: be.cookTime,
        cookTotal: be.cookTotal,
        xpBank: be.xpBank,
        brewTime: be.brewTime,
        fuel: be.fuel,
        times: be.times
    )
}

private func sortedLANBlockEntities(in chunk: Chunk) -> [BlockEntityData] {
    chunk.blockEntities.values.sorted {
        if $0.y != $1.y { return $0.y < $1.y }
        if $0.z != $1.z { return $0.z < $1.z }
        if $0.x != $1.x { return $0.x < $1.x }
        return $0.type < $1.type
    }
}

public func makeLANBlockEntitySnapshots(
    in world: World,
    maxCount: Int = LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES
) -> [LANBlockEntitySnapshot] {
    let cappedCount = max(0, min(maxCount, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES))
    if cappedCount == 0 { return [] }
    var out: [LANBlockEntitySnapshot] = []
    let chunks = world.chunks.values.sorted {
        if $0.cx != $1.cx { return $0.cx < $1.cx }
        return $0.cz < $1.cz
    }
    for chunk in chunks {
        for be in sortedLANBlockEntities(in: chunk) {
            if out.count >= cappedCount { return out }
            guard let snapshot = makeLANBlockEntitySnapshot(be, dimension: world.dim.rawValue) else { continue }
            out.append(snapshot)
        }
    }
    return out
}

public func makeLANBlockEntitySnapshots(
    in world: World,
    prioritizedAround points: [(x: Double, z: Double)],
    maxCount: Int = LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES
) -> [LANBlockEntitySnapshot] {
    guard !points.isEmpty else {
        return makeLANBlockEntitySnapshots(in: world, maxCount: maxCount)
    }
    let cappedCount = max(0, min(maxCount, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES))
    if cappedCount == 0 { return [] }

    var entries: [(snapshot: LANBlockEntitySnapshot, distance: Double)] = []
    let chunks = world.chunks.values.sorted {
        if $0.cx != $1.cx { return $0.cx < $1.cx }
        return $0.cz < $1.cz
    }
    for chunk in chunks {
        for be in sortedLANBlockEntities(in: chunk) {
            guard let snapshot = makeLANBlockEntitySnapshot(be, dimension: world.dim.rawValue) else { continue }
            let bx = Double(be.x) + 0.5
            let bz = Double(be.z) + 0.5
            let distance = points.reduce(Double.greatestFiniteMagnitude) { best, point in
                let dx = bx - point.x
                let dz = bz - point.z
                return min(best, dx * dx + dz * dz)
            }
            entries.append((snapshot, distance))
        }
    }
    entries.sort {
        if $0.distance != $1.distance { return $0.distance < $1.distance }
        if $0.snapshot.x != $1.snapshot.x { return $0.snapshot.x < $1.snapshot.x }
        if $0.snapshot.y != $1.snapshot.y { return $0.snapshot.y < $1.snapshot.y }
        if $0.snapshot.z != $1.snapshot.z { return $0.snapshot.z < $1.snapshot.z }
        return $0.snapshot.type < $1.snapshot.type
    }
    return entries.prefix(cappedCount).map(\.snapshot)
}

public func makeLANBlockEntitySnapshots(
    for request: LANChunkRequest,
    in world: World,
    maxCount: Int = LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES
) -> [LANBlockEntitySnapshot] {
    guard request.dimension == world.dim.rawValue else { return [] }
    let cappedCount = max(0, min(maxCount, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES))
    if cappedCount == 0 { return [] }
    var out: [LANBlockEntitySnapshot] = []
    for coord in orderedLANChunkRequestCoordinates(cx: request.cx, cz: request.cz, radius: request.radius) {
        guard let chunk = world.getChunk(coord.cx, coord.cz) else { continue }
        for be in sortedLANBlockEntities(in: chunk) {
            if out.count >= cappedCount { return out }
            guard let snapshot = makeLANBlockEntitySnapshot(be, dimension: world.dim.rawValue) else { continue }
            out.append(snapshot)
        }
    }
    return out
}

private let LAN_PLAYER_INVENTORY_SLOT_COUNT = 36

private func normalizedLANInventorySnapshot(_ snapshot: LANPlayerInventorySnapshot) -> LANPlayerInventorySnapshot? {
    var seenSlots = Set<Int>()
    var slots: [LANInventorySlotSnapshot] = []
    slots.reserveCapacity(snapshot.slots.count)
    for slot in snapshot.slots {
        guard slot.slot >= 0,
              slot.slot < LAN_PLAYER_INVENTORY_SLOT_COUNT,
              seenSlots.insert(slot.slot).inserted,
              slot.itemID >= 0,
              slot.itemID < itemDefs.count,
              slot.count > 0,
              slot.damage >= 0
        else { return nil }
        slots.append(LANInventorySlotSnapshot(
            slot: slot.slot,
            itemID: slot.itemID,
            count: min(slot.count, maxStackOf(ItemStack(slot.itemID, 1))),
            damage: slot.damage,
            label: slot.label
        ))
    }
    return LANPlayerInventorySnapshot(
        playerID: snapshot.playerID,
        selectedHotbarSlot: snapshot.selectedHotbarSlot,
        slots: slots,
        xp: snapshot.xp,
        xpLevel: snapshot.xpLevel,
        xpProgress: snapshot.xpProgress
    )
}

private func makeInventory(from snapshot: LANPlayerInventorySnapshot) -> [ItemStack?]? {
    guard let snapshot = normalizedLANInventorySnapshot(snapshot) else { return nil }
    var inventory: [ItemStack?] = Array(repeating: nil, count: LAN_PLAYER_INVENTORY_SLOT_COUNT)
    for slot in snapshot.slots {
        let stack = ItemStack(
            slot.itemID,
            slot.count,
            damage: slot.damage,
            label: slot.label
        )
        inventory[slot.slot] = stack
    }
    return inventory
}

private func normalizedLANBlockEntitySnapshot(_ raw: LANBlockEntitySnapshot) -> LANBlockEntitySnapshot? {
    guard LAN_REPLICATED_BLOCK_ENTITY_TYPES.contains(raw.type),
          raw.slotCount > 0,
          raw.slotCount <= LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS,
          raw.slots.count <= LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITY_SLOTS
    else { return nil }

    var seenSlots = Set<Int>()
    var slots: [LANBlockEntitySlotSnapshot] = []
    slots.reserveCapacity(raw.slots.count)
    for slot in raw.slots {
        guard slot.slot >= 0,
              slot.slot < raw.slotCount,
              seenSlots.insert(slot.slot).inserted,
              slot.itemID >= 0,
              slot.itemID < itemDefs.count,
              slot.count > 0,
              slot.count <= LAN_MULTIPLAYER_MAX_REPLICATED_ITEM_COUNT,
              slot.damage >= 0
        else { return nil }
        let cappedCount = min(slot.count, maxStackOf(ItemStack(slot.itemID, 1)))
        slots.append(LANBlockEntitySlotSnapshot(
            slot: slot.slot,
            itemID: slot.itemID,
            count: cappedCount,
            damage: slot.damage,
            label: slot.label
        ))
    }
    slots.sort { $0.slot < $1.slot }
    let normalizedTimes = raw.times.map {
        Array($0.prefix(raw.slotCount)).map { max(0, min(240_000, $0)) }
    }
    return LANBlockEntitySnapshot(
        dimension: raw.dimension,
        x: raw.x,
        y: raw.y,
        z: raw.z,
        type: raw.type,
        slotCount: raw.slotCount,
        slots: slots,
        kind: raw.kind,
        burnTime: raw.burnTime,
        burnTotal: raw.burnTotal,
        cookTime: raw.cookTime,
        cookTotal: raw.cookTotal,
        xpBank: raw.xpBank,
        brewTime: raw.brewTime,
        fuel: raw.fuel,
        times: normalizedTimes
    )
}

private func items(from snapshot: LANBlockEntitySnapshot) -> [ItemStack?]? {
    guard let snapshot = normalizedLANBlockEntitySnapshot(snapshot) else { return nil }
    var items: [ItemStack?] = Array(repeating: nil, count: snapshot.slotCount)
    for slot in snapshot.slots {
        items[slot.slot] = ItemStack(
            slot.itemID,
            slot.count,
            damage: slot.damage,
            label: slot.label
        )
    }
    return items
}

private struct LANItemMultisetKey: Hashable {
    var itemID: Int
    var damage: Int
    var label: String?
}

private func addLANItem(
    itemID: Int,
    count: Int,
    damage: Int,
    label: String?,
    to totals: inout [LANItemMultisetKey: Int]
) {
    guard itemID >= 0, itemID < itemDefs.count, count != 0 else { return }
    let key = LANItemMultisetKey(itemID: itemID, damage: max(0, damage), label: label)
    totals[key, default: 0] += count
    if totals[key] == 0 { totals.removeValue(forKey: key) }
}

private func removeLANItem(_ stack: ItemStack, from totals: inout [LANItemMultisetKey: Int]) {
    addLANItem(itemID: stack.id, count: -1, damage: stack.damage, label: stack.label, to: &totals)
}

private func addLANItem(_ stack: ItemStack, to totals: inout [LANItemMultisetKey: Int]) {
    addLANItem(itemID: stack.id, count: stack.count, damage: stack.damage, label: stack.label, to: &totals)
}

private func addLANInventorySnapshot(_ snapshot: LANPlayerInventorySnapshot, to totals: inout [LANItemMultisetKey: Int]) {
    for slot in snapshot.slots {
        addLANItem(itemID: slot.itemID, count: slot.count, damage: slot.damage, label: slot.label, to: &totals)
    }
}

private func addLANBlockEntitySnapshot(_ snapshot: LANBlockEntitySnapshot, to totals: inout [LANItemMultisetKey: Int]) {
    for slot in snapshot.slots {
        addLANItem(itemID: slot.itemID, count: slot.count, damage: slot.damage, label: slot.label, to: &totals)
    }
}

public func lanBlockEntityRevision(_ snapshots: [LANBlockEntitySnapshot]) -> Int {
    func mix(_ value: UInt64, into hash: inout UInt64) {
        hash ^= value
        hash &*= 1_099_511_628_211
    }
    var hash: UInt64 = 14_695_981_039_346_656_037
    let normalized = snapshots.compactMap(normalizedLANBlockEntitySnapshot).sorted {
        if $0.dimension != $1.dimension { return $0.dimension < $1.dimension }
        if $0.x != $1.x { return $0.x < $1.x }
        if $0.y != $1.y { return $0.y < $1.y }
        if $0.z != $1.z { return $0.z < $1.z }
        return $0.type < $1.type
    }
    mix(UInt64(normalized.count), into: &hash)
    for snapshot in normalized {
        mix(UInt64(bitPattern: Int64(snapshot.dimension)), into: &hash)
        mix(UInt64(bitPattern: Int64(snapshot.x)), into: &hash)
        mix(UInt64(bitPattern: Int64(snapshot.y)), into: &hash)
        mix(UInt64(bitPattern: Int64(snapshot.z)), into: &hash)
        for byte in snapshot.type.utf8 { mix(UInt64(byte), into: &hash) }
        mix(UInt64(snapshot.slotCount), into: &hash)
        for slot in snapshot.slots {
            mix(UInt64(slot.slot), into: &hash)
            mix(UInt64(slot.itemID), into: &hash)
            mix(UInt64(slot.count), into: &hash)
            mix(UInt64(slot.damage), into: &hash)
            if let label = slot.label {
                for byte in label.utf8 { mix(UInt64(byte), into: &hash) }
            }
            mix(0xff, into: &hash)
        }
        if let kind = snapshot.kind {
            for byte in kind.utf8 { mix(UInt64(byte), into: &hash) }
        } else {
            mix(UInt64.max, into: &hash)
        }
        for value in [snapshot.burnTime, snapshot.burnTotal, snapshot.cookTime, snapshot.cookTotal, snapshot.brewTime, snapshot.fuel] {
            mix(UInt64(bitPattern: Int64(value ?? -1)), into: &hash)
        }
        let xpScaled = Int64(((snapshot.xpBank ?? -1) * 1000).rounded())
        mix(UInt64(bitPattern: xpScaled), into: &hash)
        if let times = snapshot.times {
            for value in times { mix(UInt64(max(0, value)), into: &hash) }
        } else {
            mix(UInt64.max, into: &hash)
        }
    }
    return Int(hash & 0x7fff_ffff)
}

private func lanContainerEditTotals(
    inventory: LANPlayerInventorySnapshot,
    blockEntities: [LANBlockEntitySnapshot]
) -> [LANItemMultisetKey: Int] {
    var totals: [LANItemMultisetKey: Int] = [:]
    addLANInventorySnapshot(inventory, to: &totals)
    for blockEntity in blockEntities {
        addLANBlockEntitySnapshot(blockEntity, to: &totals)
    }
    return totals
}

private let LAN_CONTAINER_EDIT_MAX_CRAFT_ROUNDS = 64

private func isLANCraftingTableTransformAllowed(
    beforeBlockEntity: LANBlockEntitySnapshot,
    beforeTotals: [LANItemMultisetKey: Int],
    afterTotals: [LANItemMultisetKey: Int]
) -> Bool {
    guard beforeBlockEntity.type == "crafting",
          var grid = items(from: beforeBlockEntity),
          grid.count == 9
    else { return false }

    var totals = beforeTotals
    for _ in 0..<LAN_CONTAINER_EDIT_MAX_CRAFT_ROUNDS {
        guard let plan = currentCraftingPlan(from: grid, gridWidth: 3, gridHeight: 3) else {
            return false
        }
        for stack in grid {
            guard let stack else { continue }
            removeLANItem(stack, from: &totals)
        }
        let returns = consumeCraftingGrid(&grid)
        addLANItem(plan.output, to: &totals)
        for stack in returns { addLANItem(stack, to: &totals) }
        if totals == afterTotals { return true }
    }
    return false
}

private func isLANContainerEditItemTransitionAllowed(
    beforeInventory: LANPlayerInventorySnapshot,
    afterInventory: LANPlayerInventorySnapshot,
    beforeBlockEntities: [LANBlockEntitySnapshot],
    afterBlockEntities: [LANBlockEntitySnapshot]
) -> Bool {
    guard beforeBlockEntities.count == afterBlockEntities.count, !beforeBlockEntities.isEmpty else { return false }
    for (before, after) in zip(beforeBlockEntities, afterBlockEntities) {
        guard before.dimension == after.dimension,
              before.x == after.x,
              before.y == after.y,
              before.z == after.z,
              before.type == after.type,
              before.slotCount == after.slotCount
        else { return false }
    }

    let beforeTotals = lanContainerEditTotals(inventory: beforeInventory, blockEntities: beforeBlockEntities)
    let afterTotals = lanContainerEditTotals(inventory: afterInventory, blockEntities: afterBlockEntities)
    if beforeTotals == afterTotals { return true }
    guard beforeBlockEntities.count == 1, let beforeBlockEntity = beforeBlockEntities.first else { return false }
    return isLANCraftingTableTransformAllowed(
        beforeBlockEntity: beforeBlockEntity,
        beforeTotals: beforeTotals,
        afterTotals: afterTotals
    )
}

private func isLANContainerBlockID(_ id: Int) -> Bool {
    guard id >= 0, id < blockDefs.count else { return false }
    let name = blockDefs[id].name
    return name == "chest" ||
        name == "trapped_chest" ||
        name == "barrel" ||
        name == "dispenser" ||
        name == "dropper" ||
        name == "shulker_box" ||
        name.hasSuffix("_shulker_box")
}

private func isLANFurnaceBlockID(_ id: Int) -> Bool {
    id == Int(B.furnace) ||
        id == Int(B.furnace_lit) ||
        id == Int(B.blast_furnace) ||
        id == Int(B.blast_furnace_lit) ||
        id == Int(B.smoker) ||
        id == Int(B.smoker_lit)
}

private func isLANBlockEntitySnapshotCompatible(_ snapshot: LANBlockEntitySnapshot, cell: Int) -> Bool {
    guard isValidLANReplicatedCell(cell) else { return false }
    let id = cell >> 4
    guard id > 0 else { return false }
    switch snapshot.type {
    case "container":
        return isLANContainerBlockID(id) && snapshot.slotCount == containerSizeFor(blockDefs[id].name)
    case "hopper":
        return id == Int(B.hopper) && snapshot.slotCount == 5
    case "furnace":
        return isLANFurnaceBlockID(id) && snapshot.slotCount == 3
    case "brewing":
        return id == Int(B.brewing_stand) && snapshot.slotCount == 5
    case "shelf":
        return id == Int(B.chiseled_bookshelf) && snapshot.slotCount == 6
    case "campfire":
        return (id == Int(B.campfire) || id == Int(B.soul_campfire)) && snapshot.slotCount == 4
    case "crafting":
        return id == Int(B.crafting_table) && snapshot.slotCount == 9
    default:
        return false
    }
}

private func makeBlockEntity(from snapshot: LANBlockEntitySnapshot) -> BlockEntityData {
    switch snapshot.type {
    case "container":
        return makeContainerBE(snapshot.x, snapshot.y, snapshot.z, snapshot.slotCount)
    case "hopper":
        return makeHopperBE(snapshot.x, snapshot.y, snapshot.z)
    case "furnace":
        return makeFurnaceBE(snapshot.x, snapshot.y, snapshot.z, snapshot.kind ?? "furnace")
    case "brewing":
        return makeBrewingBE(snapshot.x, snapshot.y, snapshot.z)
    case "crafting":
        return makeCraftingTableBE(snapshot.x, snapshot.y, snapshot.z)
    case "shelf":
        let be = BlockEntityData(type: "shelf", x: snapshot.x, y: snapshot.y, z: snapshot.z)
        be.items = Array(repeating: nil, count: snapshot.slotCount)
        be.lastSlot = -1
        return be
    case "campfire":
        let be = BlockEntityData(type: "campfire", x: snapshot.x, y: snapshot.y, z: snapshot.z)
        be.items = Array(repeating: nil, count: snapshot.slotCount)
        be.times = Array(repeating: 0, count: snapshot.slotCount)
        return be
    default:
        let be = BlockEntityData(type: snapshot.type, x: snapshot.x, y: snapshot.y, z: snapshot.z)
        be.items = Array(repeating: nil, count: snapshot.slotCount)
        return be
    }
}

private func applyLANBlockEntityPayload(_ snapshot: LANBlockEntitySnapshot, to be: BlockEntityData) -> Bool {
    guard let snapshot = normalizedLANBlockEntitySnapshot(snapshot),
          let snapshotItems = items(from: snapshot)
    else { return false }
    be.type = snapshot.type
    be.x = snapshot.x
    be.y = snapshot.y
    be.z = snapshot.z
    be.items = snapshotItems
    switch snapshot.type {
    case "furnace":
        be.kind = snapshot.kind
        be.burnTime = snapshot.burnTime ?? 0
        be.burnTotal = snapshot.burnTotal ?? 0
        be.cookTime = snapshot.cookTime ?? 0
        be.cookTotal = snapshot.cookTotal ?? 200
        be.xpBank = snapshot.xpBank ?? 0
    case "brewing":
        be.brewTime = snapshot.brewTime ?? 0
        be.fuel = snapshot.fuel ?? 0
    case "campfire":
        be.times = snapshot.times ?? Array(repeating: 0, count: snapshot.slotCount)
    case "shelf":
        be.lastSlot = be.lastSlot ?? -1
    default:
        break
    }
    return true
}

@discardableResult
public func applyLANInventorySnapshot(_ snapshot: LANPlayerInventorySnapshot, to player: Player) -> Bool {
    guard let inventory = makeInventory(from: snapshot) else { return false }
    player.inventory = inventory
    player.selectedSlot = snapshot.selectedHotbarSlot
    player.xp = snapshot.xp
    player.xpLevel = snapshot.xpLevel
    player.xpProgress = snapshot.xpProgress
    return true
}

@discardableResult
public func applyLANInventorySnapshot(_ snapshot: LANPlayerInventorySnapshot, to player: LANRemotePlayerEntity) -> Bool {
    guard snapshot.playerID == player.multiplayerPlayerID,
          let inventory = makeInventory(from: snapshot)
    else { return false }
    player.inventory = inventory
    player.selectedSlot = snapshot.selectedHotbarSlot
    player.xp = snapshot.xp
    player.xpLevel = snapshot.xpLevel
    player.xpProgress = snapshot.xpProgress
    return true
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
    if let aroundX, let aroundZ {
        return makeLANEntitySnapshots(
            in: world,
            around: [(x: aroundX, z: aroundZ)],
            radius: radius,
            maxCount: maxCount
        )
    }
    return makeLANEntitySnapshots(in: world, around: [], radius: radius, maxCount: maxCount)
}

public func makeLANEntitySnapshots(
    in world: World,
    around points: [(x: Double, z: Double)],
    radius: Double = 160,
    maxCount: Int = LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES
) -> [LANEntitySnapshot] {
    let radius2 = radius * radius
    let entities = world.entities.sorted { $0.id < $1.id }
    var out: [LANEntitySnapshot] = []
    for ref in entities {
        if out.count >= max(0, min(maxCount, LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES)) { break }
        if ref is Player || (ref as? Entity)?.isPlayer == true { continue }
        if !points.isEmpty {
            var withinRadius = false
            for point in points {
                let dx = ref.x - point.x
                let dz = ref.z - point.z
                if dx * dx + dz * dz <= radius2 {
                    withinRadius = true
                    break
                }
            }
            if !withinRadius { continue }
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
            xpAmount: xp?.amount,
            vx: entity?.vx ?? 0,
            vy: entity?.vy ?? 0,
            vz: entity?.vz ?? 0,
            onGround: entity?.onGround ?? false,
            fire: (entity?.fireTicks ?? 0) > 0,
            dimension: world.dim.rawValue
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

public func orderedLANChunkRequestCoordinates(cx: Int, cz: Int, radius rawRadius: Int) -> [(cx: Int, cz: Int)] {
    let radius = max(0, min(LAN_MULTIPLAYER_MAX_CHUNK_REQUEST_RADIUS, rawRadius))
    var out: [(cx: Int, cz: Int, d: Int)] = []
    out.reserveCapacity((radius * 2 + 1) * (radius * 2 + 1))
    for dz in -radius...radius {
        for dx in -radius...radius {
            out.append((cx + dx, cz + dz, max(abs(dx), abs(dz))))
        }
    }
    out.sort { lhs, rhs in
        if lhs.d != rhs.d { return lhs.d < rhs.d }
        if lhs.cz != rhs.cz { return lhs.cz < rhs.cz }
        return lhs.cx < rhs.cx
    }
    return out.map { ($0.cx, $0.cz) }
}

private func clampedLANSectionY(forWorldY y: Int, in world: World) -> Int {
    max(0, min(world.info.height / SECTION_H - 1, (y - world.info.minY) >> 4))
}

private func surfaceSectionY(in chunk: Chunk) -> Int? {
    guard let rawTop = chunk.heightmap.max() else { return nil }
    let top = Int(rawTop)
    guard top >= chunk.minY else { return nil }
    return max(0, min(chunk.sections - 1, (Int(top) - chunk.minY) >> 4))
}

private func requestedLANSectionYs(for chunk: Chunk, request: LANChunkRequest, world: World) -> [Int] {
    if request.centerY == nil && request.radius == 0 {
        return Array(0..<chunk.sections)
    }

    var out: [Int] = []
    var seen = Set<Int>()
    func append(_ sy: Int) {
        let clamped = max(0, min(chunk.sections - 1, sy))
        if seen.insert(clamped).inserted {
            out.append(clamped)
        }
    }

    if let centerY = request.centerY {
        let centerSection = clampedLANSectionY(forWorldY: centerY, in: world)
        let verticalRadius = max(0, min(4, request.verticalRadius))
        for sy in max(0, centerSection - verticalRadius)...min(chunk.sections - 1, centerSection + verticalRadius) {
            append(sy)
        }
    }
    if let surface = surfaceSectionY(in: chunk) {
        append(surface)
    }
    if out.isEmpty {
        append(max(0, min(chunk.sections - 1, chunk.sections / 2)))
    }
    return out
}

public func makeLANChunkSectionSnapshots(
    for request: LANChunkRequest,
    in world: World,
    maxCount: Int = LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS
) -> [LANChunkSectionSnapshot] {
    guard request.dimension == world.dim.rawValue else { return [] }
    let cappedCount = max(0, min(maxCount, LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS))
    if cappedCount == 0 { return [] }
    var out: [LANChunkSectionSnapshot] = []
    for coord in orderedLANChunkRequestCoordinates(cx: request.cx, cz: request.cz, radius: request.radius) {
        guard let chunk = world.getChunk(coord.cx, coord.cz) else { continue }
        for sectionY in requestedLANSectionYs(for: chunk, request: request, world: world) {
            if out.count >= cappedCount { return out }
            if let snapshot = makeLANChunkSectionSnapshot(from: chunk, dimension: world.dim.rawValue, sectionY: sectionY) {
                out.append(snapshot)
            }
        }
    }
    return out
}

public func makeLANChunkSectionSnapshots(
    around player: Player,
    in world: World,
    chunkRadius: Int = 1,
    verticalSectionRadius: Int = 2,
    maxCount: Int = LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS
) -> [LANChunkSectionSnapshot] {
    let request = LANChunkRequest(
        dimension: world.dim.rawValue,
        cx: floorDiv(ifloor(player.x), CHUNK_W),
        cz: floorDiv(ifloor(player.z), CHUNK_W),
        radius: chunkRadius,
        centerY: ifloor(player.y),
        verticalRadius: verticalSectionRadius
    )
    return makeLANChunkSectionSnapshots(for: request, in: world, maxCount: maxCount)
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
        xpAmount: raw.xpAmount,
        vx: raw.vx,
        vy: raw.vy,
        vz: raw.vz,
        onGround: raw.onGround,
        fire: raw.fire,
        dimension: raw.dimension
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
    entity.vx = snapshot.vx
    entity.vy = snapshot.vy
    entity.vz = snapshot.vz
    entity.setPos(snapshot.x, snapshot.y, snapshot.z)
    entity.yaw = snapshot.yaw
    entity.prevYaw = snapshot.yaw
    entity.pitch = snapshot.pitch
    entity.prevPitch = snapshot.pitch
    entity.onGround = snapshot.onGround
    entity.fireTicks = snapshot.fire ? max(entity.fireTicks, 1) : 0
    if let living = entity as? LivingEntity, let health = snapshot.health {
        living.health = max(0, min(living.maxHealth, health))
        living.deathTime = living.health <= 0 ? max(1, living.deathTime) : 0
    }
}

/// Builds a one-pass `[sourceID: Entity]` index of currently-mirrored entities in `world` (amendment
/// A13) so `applyLANEntitySnapshots` resolves each snapshot in O(1) instead of an O(N) linear scan
/// per snapshot (avoiding O(N^2) behavior for large batches).
private func indexMirroredEntities(in world: World) -> [Int: Entity] {
    var index: [Int: Entity] = [:]
    for ref in world.entities {
        guard let entity = ref as? Entity, let sourceID = entity.lanReplicationSourceID else { continue }
        index[sourceID] = entity
    }
    return index
}

@discardableResult
public func applyLANEntitySnapshots(
    _ snapshots: [LANEntitySnapshot],
    to world: World,
    removeMissing: Bool = true
) -> LANReplicationApplyReport {
    var report = LANReplicationApplyReport()
    var wantedSourceIDs = Set<Int>()
    var mirrorsBySourceID = indexMirroredEntities(in: world)

    for raw in snapshots.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES) {
        guard let snapshot = normalizedLANEntitySnapshot(raw) else {
            report.ignoredInvalidEntities += 1
            continue
        }
        guard snapshot.dimension == world.dim.rawValue else {
            report.ignoredInvalidEntities += 1
            continue
        }
        if snapshot.dead {
            if let existing = mirrorsBySourceID[snapshot.entityID] {
                world.removeEntity(existing)
                mirrorsBySourceID.removeValue(forKey: snapshot.entityID)
                report.removedEntitySnapshots += 1
            }
            continue
        }

        wantedSourceIDs.insert(snapshot.entityID)
        var entity = mirrorsBySourceID[snapshot.entityID]
        if let existing = entity, existing.type != snapshot.type {
            world.removeEntity(existing)
            mirrorsBySourceID.removeValue(forKey: snapshot.entityID)
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
            if let entity {
                world.removeEntity(entity)
                mirrorsBySourceID.removeValue(forKey: snapshot.entityID)
            }
            report.ignoredInvalidEntities += 1
            continue
        }
        configureMirroredEntity(entity, from: snapshot)
        mirrorsBySourceID[snapshot.entityID] = entity
        report.appliedEntitySnapshots += 1
    }

    if removeMissing {
        // Scoped to same-dimension mirrors only (amendment A1): a mirror sourced from a snapshot
        // in another dimension was never applied here (dropped above), so it must not be purged
        // by this world's completion pass.
        for (sourceID, entity) in mirrorsBySourceID where !wantedSourceIDs.contains(sourceID) {
            world.removeEntity(entity)
            report.removedEntitySnapshots += 1
        }
    }

    return report
}

@discardableResult
public func applyLANBlockEntitySnapshots(
    _ snapshots: [LANBlockEntitySnapshot],
    to world: World,
    deferred: UnsafeMutablePointer<LANDeferredReplicationBuffer>? = nil
) -> LANReplicationApplyReport {
    var report = LANReplicationApplyReport()
    for raw in snapshots.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES) {
        guard let snapshot = normalizedLANBlockEntitySnapshot(raw), snapshot.dimension == world.dim.rawValue else {
            report.ignoredInvalidBlockEntities += 1
            continue
        }
        guard let chunk = world.getChunkAt(snapshot.x, snapshot.z) else {
            if let deferred {
                deferred.pointee.queue(snapshot)
                report.deferredBlockEntities += 1
            } else {
                report.ignoredInvalidBlockEntities += 1
            }
            continue
        }
        guard chunk.inYRange(snapshot.y),
              isLANBlockEntitySnapshotCompatible(snapshot, cell: world.getBlock(snapshot.x, snapshot.y, snapshot.z))
        else {
            report.ignoredInvalidBlockEntities += 1
            continue
        }

        let existing = world.getBlockEntity(snapshot.x, snapshot.y, snapshot.z)
        let target = existing?.type == snapshot.type ? existing! : makeBlockEntity(from: snapshot)
        guard applyLANBlockEntityPayload(snapshot, to: target) else {
            report.ignoredInvalidBlockEntities += 1
            continue
        }
        world.setBlockEntity(target)
        report.appliedBlockEntities += 1
    }
    return report
}

@discardableResult
public func applyLANReplicationBatch(_ batch: LANReplicationBatch, to world: World) -> LANReplicationApplyReport {
    var deferred: LANDeferredReplicationBuffer? = nil
    return applyLANReplicationBatch(batch, to: world, deferred: &deferred)
}

@discardableResult
public func applyLANReplicationBatch(
    _ batch: LANReplicationBatch,
    to world: World,
    deferred: inout LANDeferredReplicationBuffer?
) -> LANReplicationApplyReport {
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
    if deferred != nil {
        report.merge(deferred!.applyReadyBlockChanges(to: world))
    }
    for change in batch.blockChanges.prefix(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES) {
        guard change.dimension == world.dim.rawValue, isValidLANReplicatedCell(change.cell) else {
            report.ignoredInvalidCells += 1
            continue
        }
        guard world.getChunkAt(change.x, change.z) != nil else {
            if deferred != nil {
                deferred!.queue(change)
                report.deferredBlockChanges += 1
            } else {
                report.ignoredUnloadedBlockChanges += 1
            }
            continue
        }
        _ = world.setBlock(change.x, change.y, change.z, change.cell)
        report.appliedBlockChanges += 1
    }
    if deferred != nil {
        report.merge(deferred!.applyReadyBlockEntities(to: world))
    }
    let blockEntityReport: LANReplicationApplyReport
    if deferred != nil {
        var buffer = deferred!
        blockEntityReport = withUnsafeMutablePointer(to: &buffer) { buffer in
            applyLANBlockEntitySnapshots(batch.blockEntities, to: world, deferred: buffer)
        }
        deferred = buffer
    } else {
        blockEntityReport = applyLANBlockEntitySnapshots(batch.blockEntities, to: world)
    }
    report.merge(blockEntityReport)
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

/// true iff the block at (x,y,z) is within the peer's interaction reach given its last-published
/// state (host trusts the peer's reported position, not a live raycast — matches the reach model
/// used throughout `LANMultiplayerHostSession`). Exposed (was file-private) so `LANTransport.swift`
/// can reach-check ghost-driven break intents before invoking `LANHostGhostRegistry.applyBreak`,
/// which — unlike `applyBlockIntent` — does not reach-check internally (deviation, flagged by W4).
public func isWithinLANReach(_ player: LANPlayerState, x: Int, y: Int, z: Int) -> Bool {
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
