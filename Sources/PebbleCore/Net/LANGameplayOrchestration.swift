import Foundation

public enum LANPeerConnectionDisposition: Equatable {
    case joined
    case reconnected
}

public enum LANAuthorizationResult: Equatable {
    case accepted
    case rejected(String)

    public var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

public enum LANContainerIntentResult: Equatable {
    case accepted(String)
    case rejected(String)
}

public enum LANCraftingIntentResult: Equatable {
    case accepted
    case rejected(String)
}

public enum LANTemplateIntentResult: Equatable {
    case copied(name: String, blocks: Int)
    case placed(name: String, blocks: Int, blockEntities: Int, cleared: Int, filled: Int)
    case undone(name: String, restored: Int)
    case rejected(String)
}

public struct LANPeerRecordSnapshot: Equatable {
    public var playerID: String
    public var displayName: String
    public var lifecycle: LANPeerLifecycleState
    public var permissions: LANPeerPermissions
    public var playerState: LANPlayerState?
    public var inventory: LANPlayerInventorySnapshot?
    public var lastAckTick: Int
    public var lastSeenTick: Int
    public var disconnectedTick: Int?
}

public struct LANRemotePlayerApplyReport: Equatable {
    public var spawned = 0
    public var updated = 0
    public var removed = 0

    public init(spawned: Int = 0, updated: Int = 0, removed: Int = 0) {
        self.spawned = spawned
        self.updated = updated
        self.removed = removed
    }
}

public final class LANRemotePlayerEntity: LivingEntity {
    public let multiplayerPlayerID: String
    public private(set) var displayName: String
    private var remoteGameMode = GameMode.survival

    public override var type: String { "player" }
    public override var isPlayer: Bool { true }
    public override var gameMode: Int { remoteGameMode }

    public init(world: World, state: LANPlayerState) {
        self.multiplayerPlayerID = state.playerID
        self.displayName = state.displayName
        super.init(world: world)
        width = 0.6
        height = PLAYER_HEIGHT
        maxHealth = 20
        health = max(0, min(maxHealth, state.health))
        speed = 0
        persistent = false
        stepHeight = 0.6
        apply(state)
        prevX = x
        prevY = y
        prevZ = z
        prevYaw = yaw
        prevPitch = pitch
    }

    public func apply(_ state: LANPlayerState) {
        displayName = state.displayName
        prevX = x
        prevY = y
        prevZ = z
        prevYaw = yaw
        prevPitch = pitch
        x = state.x
        y = state.y
        z = state.z
        yaw = state.yaw
        pitch = state.pitch
        headYaw = state.yaw
        bodyYaw = state.yaw
        remoteGameMode = state.gameMode
        health = max(0, min(maxHealth, state.health))
        deathTime = state.dead ? max(deathTime, 1) : 0
        dead = state.dead
        noClip = true
        noGravity = true
        fireTicks = 0
        vx = 0
        vy = 0
        vz = 0
    }

    public override func tick() {
        age += 1
    }

    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        false
    }
}

@discardableResult
public func removeLANRemotePlayer(_ playerID: String, from world: World) -> Bool {
    let cleanID = String(playerID.prefix(128))
    guard let existing = world.entities.first(where: {
        ($0 as? LANRemotePlayerEntity)?.multiplayerPlayerID == cleanID
    }) else { return false }
    world.removeEntity(existing)
    return true
}

@discardableResult
public func applyLANRemotePlayers(
    _ states: [LANPlayerState],
    to world: World,
    localPlayerID: String?,
    removeMissing: Bool = true
) -> LANRemotePlayerApplyReport {
    var report = LANRemotePlayerApplyReport()
    let local = localPlayerID.map { String($0.prefix(128)) }
    var wanted = Set<String>()

    for state in states.sorted(by: { $0.playerID < $1.playerID }) {
        if state.playerID == local { continue }
        if state.dead || state.dimension != world.dim.rawValue {
            if removeLANRemotePlayer(state.playerID, from: world) {
                report.removed += 1
            }
            continue
        }
        wanted.insert(state.playerID)
        if let existing = world.entities.first(where: {
            ($0 as? LANRemotePlayerEntity)?.multiplayerPlayerID == state.playerID
        }) as? LANRemotePlayerEntity {
            existing.apply(state)
            report.updated += 1
        } else {
            let remote = LANRemotePlayerEntity(world: world, state: state)
            world.addEntity(remote)
            report.spawned += 1
        }
    }

    if removeMissing {
        for entity in Array(world.entities) {
            guard let remote = entity as? LANRemotePlayerEntity else { continue }
            if local == remote.multiplayerPlayerID || !wanted.contains(remote.multiplayerPlayerID) {
                world.removeEntity(remote)
                report.removed += 1
            }
        }
    }
    return report
}
