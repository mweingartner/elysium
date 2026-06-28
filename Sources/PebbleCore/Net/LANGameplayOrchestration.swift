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

private let LAN_REMOTE_PLAYER_PRESENTATION_RESPONSE = 12.0
private let LAN_REMOTE_PLAYER_TELEPORT_DISTANCE_SQUARED = 16.0 * 16.0

private func wrapLANRemoteAngle(_ angle: Double) -> Double {
    let turn = Double.pi * 2
    var value = angle.truncatingRemainder(dividingBy: turn)
    if value <= -Double.pi { value += turn }
    if value > Double.pi { value -= turn }
    return value
}

public struct LANRemotePlayerPresentationPose: Equatable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var yaw: Double
    public var pitch: Double
    public var headYaw: Double
    public var bodyYaw: Double

    public init(x: Double, y: Double, z: Double, yaw: Double, pitch: Double, headYaw: Double, bodyYaw: Double) {
        self.x = x
        self.y = y
        self.z = z
        self.yaw = yaw
        self.pitch = pitch
        self.headYaw = headYaw
        self.bodyYaw = bodyYaw
    }
}

public final class LANRemotePlayerEntity: LivingEntity {
    public let multiplayerPlayerID: String
    public private(set) var displayName: String
    private var remoteGameMode = GameMode.survival
    private var presentationX = 0.0
    private var presentationY = 0.0
    private var presentationZ = 0.0
    private var presentationYaw = 0.0
    private var presentationPitch = 0.0
    private var presentationHeadYaw = 0.0
    private var presentationBodyYaw = 0.0
    private var lastPresentationTime: Double?
    public var inventory: [ItemStack?] = Array(repeating: nil, count: 36)
    public var selectedSlot = 0
    public var hunger = 20
    public var xp = 0
    public var xpLevel = 0
    public var xpProgress = 0.0

    public override var type: String { "player" }
    public override var isPlayer: Bool { true }
    public override var gameMode: Int { remoteGameMode }
    public override var mainHand: ItemStack? {
        get { inventory[selectedSlot] }
        set { inventory[selectedSlot] = newValue }
    }

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
        resetPresentationPose()
    }

    public func apply(_ state: LANPlayerState) {
        displayName = state.displayName
        let oldX = x
        let oldZ = z
        prevX = x
        prevY = y
        prevZ = z
        prevYaw = yaw
        prevPitch = pitch
        x = state.x
        y = state.y
        z = state.z
        let renderYaw = lanRemotePlayerRenderYaw(fromPlayerYaw: state.yaw)
        yaw = renderYaw
        pitch = state.pitch
        headYaw = renderYaw
        bodyYaw = renderYaw
        selectedSlot = max(0, min(8, state.selectedHotbarSlot))
        remoteGameMode = state.gameMode
        health = max(0, min(maxHealth, state.health))
        hunger = max(0, min(20, state.hunger))
        deathTime = state.dead ? max(deathTime, 1) : 0
        dead = state.dead
        noClip = true
        noGravity = true
        fireTicks = 0
        vx = 0
        vy = 0
        vz = 0
        let moved = min(1, detHyp(x - oldX, z - oldZ) * 4)
        limbAmp += (moved - limbAmp) * 0.35
        limbSwing += limbAmp * 1.2
    }

    public override func tick() {
        prevX = x
        prevY = y
        prevZ = z
        prevYaw = yaw
        prevPitch = pitch
        age += 1
        guard !dead else { return }
        tickAuthoritativePickups()
    }

    private var hasFiniteAuthoritativePose: Bool {
        x.isFinite && y.isFinite && z.isFinite && yaw.isFinite && pitch.isFinite && headYaw.isFinite && bodyYaw.isFinite
    }

    public func resetPresentationPose() {
        guard hasFiniteAuthoritativePose else {
            lastPresentationTime = nil
            return
        }
        presentationX = x
        presentationY = y
        presentationZ = z
        presentationYaw = yaw
        presentationPitch = pitch
        presentationHeadYaw = headYaw
        presentationBodyYaw = bodyYaw
        lastPresentationTime = nil
    }

    public func presentationPose(timeSec: Double) -> LANRemotePlayerPresentationPose {
        guard timeSec.isFinite else {
            resetPresentationPose()
            return LANRemotePlayerPresentationPose(
                x: presentationX,
                y: presentationY,
                z: presentationZ,
                yaw: presentationYaw,
                pitch: presentationPitch,
                headYaw: presentationHeadYaw,
                bodyYaw: presentationBodyYaw
            )
        }
        guard hasFiniteAuthoritativePose else {
            lastPresentationTime = timeSec
            return LANRemotePlayerPresentationPose(
                x: presentationX,
                y: presentationY,
                z: presentationZ,
                yaw: presentationYaw,
                pitch: presentationPitch,
                headYaw: presentationHeadYaw,
                bodyYaw: presentationBodyYaw
            )
        }
        let dx = x - presentationX
        let dy = y - presentationY
        let dz = z - presentationZ
        let distanceSquared = dx * dx + dy * dy + dz * dz
        if lastPresentationTime == nil || distanceSquared > LAN_REMOTE_PLAYER_TELEPORT_DISTANCE_SQUARED {
            resetPresentationPose()
            lastPresentationTime = timeSec
        } else {
            let dt = max(0, min(0.1, timeSec - (lastPresentationTime ?? timeSec)))
            lastPresentationTime = timeSec
            let alpha = 1 - exp(-LAN_REMOTE_PLAYER_PRESENTATION_RESPONSE * dt)
            presentationX += dx * alpha
            presentationY += dy * alpha
            presentationZ += dz * alpha
            presentationYaw += wrapLANRemoteAngle(yaw - presentationYaw) * alpha
            presentationPitch += (pitch - presentationPitch) * alpha
            presentationHeadYaw += wrapLANRemoteAngle(headYaw - presentationHeadYaw) * alpha
            presentationBodyYaw += wrapLANRemoteAngle(bodyYaw - presentationBodyYaw) * alpha
        }
        return LANRemotePlayerPresentationPose(
            x: presentationX,
            y: presentationY,
            z: presentationZ,
            yaw: presentationYaw,
            pitch: presentationPitch,
            headYaw: presentationHeadYaw,
            bodyYaw: presentationBodyYaw
        )
    }

    @discardableResult
    public override func give(_ stackIn: ItemStack?) -> Bool {
        guard let stack = stackIn, stack.id >= 0, stack.id < itemDefs.count, stack.count > 0 else { return false }
        for i in 0..<inventory.count where stack.count > 0 {
            if let existing = inventory[i], canMerge(existing, stack) {
                let take = min(maxStackOf(existing) - existing.count, stack.count)
                if take > 0 {
                    existing.count += take
                    stack.count -= take
                }
            }
        }
        if stack.count <= 0 { return true }
        for i in 0..<inventory.count where inventory[i] == nil {
            let copy = stack.copy()
            copy.count = min(stack.count, maxStackOf(copy))
            inventory[i] = copy
            stack.count -= copy.count
            return stack.count <= 0
        }
        return false
    }

    public func addXP(_ pointsIn: Int) {
        let points = max(0, min(100_000, pointsIn))
        guard points > 0 else { return }
        xp = max(0, min(1_000_000_000, xp + points))
        var need = Double(xpForLevel(xpLevel))
        var cur = xpProgress * need + Double(points)
        while cur >= need {
            cur -= need
            xpLevel = min(100_000, xpLevel + 1)
            need = Double(xpForLevel(xpLevel))
        }
        xpProgress = need > 0 ? max(0, min(1, cur / need)) : 0
    }

    public func xpForLevel(_ level: Int) -> Int {
        if level >= 30 { return 112 + (level - 30) * 9 }
        if level >= 15 { return 37 + (level - 15) * 5 }
        return 7 + level * 2
    }

    private func tickAuthoritativePickups() {
        guard age % 2 == 0 else { return }
        for ref in world.getEntitiesNear(x, y + 0.5, z, 1.6).sorted(by: { $0.id < $1.id }) {
            if ref === self { continue }
            if (ref as? Entity)?.lanReplicatedMirror == true { continue }
            if let item = ref as? ItemEntity, item.pickupDelay <= 0 {
                let before = item.stack.count
                if give(item.stack) {
                    world.hooks.playSound("entity.item.pickup", x, y, z, 0.3, 1.4 + Double.random(in: 0..<1) * 0.6)
                    item.remove()
                } else if item.stack.count != before {
                    world.hooks.playSound("entity.item.pickup", x, y, z, 0.3, 1.4)
                }
            } else if let orb = ref as? XPOrb {
                addXP(orb.amount)
                world.hooks.playSound("entity.experience_orb.pickup", x, y, z, 0.4, 0.8 + Double.random(in: 0..<1) * 0.6)
                orb.remove()
            }
        }
    }

    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        false
    }
}

public func lanRemotePlayerRenderYaw(fromPlayerYaw yaw: Double) -> Double {
    let turn = Double.pi * 2
    var value = (yaw + Double.pi).truncatingRemainder(dividingBy: turn)
    if value <= -Double.pi { value += turn }
    if value > Double.pi { value -= turn }
    return value
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
public func removeLANClientNonAuthoritativeEntities(from world: World, localPlayer: Player?) -> Int {
    var removed = 0
    for entityRef in Array(world.entities) {
        if let localPlayer, entityRef === localPlayer { continue }
        guard let entity = entityRef as? Entity else { continue }
        if entity is LANRemotePlayerEntity { continue }
        if entity.lanReplicatedMirror { continue }
        if entity.isPlayer { continue }
        world.removeEntity(entityRef)
        removed += 1
    }
    return removed
}

@discardableResult
public func applyLANRemotePlayers(
    _ states: [LANPlayerState],
    to world: World,
    localPlayerID: String?,
    removeMissing: Bool = true,
    inventorySnapshots: [String: LANPlayerInventorySnapshot] = [:]
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
            if let inventory = inventorySnapshots[state.playerID] {
                _ = applyLANInventorySnapshot(inventory, to: remote)
            }
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
