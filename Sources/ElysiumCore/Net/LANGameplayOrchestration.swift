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
    /// Host-internal only — never encoded onto the wire. Returned synchronously the moment
    /// a place/undo intent is admitted into the host's per-peer template job registry; the
    /// eventual `.placed`/`.undone` result arrives later through `drainTemplateIntentResponses`.
    case accepted(action: LANTemplateIntent.Action, name: String)
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
    public var rpg: RPGCharacterState?
    public var inventory: LANPlayerInventorySnapshot?
    public var inventoryRevision: Int
    public var lastAckTick: Int
    public var lastSeenTick: Int
    public var disconnectedTick: Int?
    /// lan-client-parity (change 4), design.md §11: the guest's own
    /// `player:lan:<peerID>` object's `ObjectRecord` (attrs *and* scripts —
    /// one document, exactly like every other object kind's persistence),
    /// `ObjectRecordCodec`-encoded. `nil` when never populated (a peer that
    /// predates this change, or one with an empty record). Seeded from
    /// `lan_players` on reconnect (`seedPeerRecord`); the *live* value while
    /// connected lives on the `LANRemotePlayerEntity.objectRecord` in
    /// `World.entities`, not here — this field is the persistence round-trip
    /// only (see `persistAllHostPeerRecords` in `LANTransport.swift`).
    public var objectRecordText: String?

    public init(
        playerID: String,
        displayName: String,
        lifecycle: LANPeerLifecycleState,
        permissions: LANPeerPermissions,
        playerState: LANPlayerState?,
        rpg: RPGCharacterState? = nil,
        inventory: LANPlayerInventorySnapshot?,
        inventoryRevision: Int = 0,
        lastAckTick: Int,
        lastSeenTick: Int,
        disconnectedTick: Int?,
        objectRecordText: String? = nil
    ) {
        self.playerID = playerID
        self.displayName = displayName
        self.lifecycle = lifecycle
        self.permissions = permissions
        self.playerState = playerState
        self.rpg = rpg.map(repairRPGCharacterState)
        self.inventory = inventory
        self.inventoryRevision = inventoryRevision
        self.lastAckTick = lastAckTick
        self.lastSeenTick = lastSeenTick
        self.disconnectedTick = disconnectedTick
        self.objectRecordText = objectRecordText
    }
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

func lanXPRequiredForLevel(_ level: Int) -> Int {
    if level >= 30 { return 112 + (level - 30) * 9 }
    if level >= 15 { return 37 + (level - 15) * 5 }
    return 7 + level * 2
}

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
    private var pendingDamage: [LANDamageEvent] = []
    private var pendingAuthoritativePickupItems: [LANInventorySlotSnapshot] = []
    private var pendingAuthoritativePickupXP = 0

    var hasPendingAuthoritativePickupMutation: Bool {
        !pendingAuthoritativePickupItems.isEmpty || pendingAuthoritativePickupXP > 0
    }

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

    /// Host-authoritative script grant (`player:give`) to this connected guest.
    ///
    /// A plain ``give(_:)`` only mutates this cosmetic proxy inventory, which the guest's next
    /// published snapshot overwrites — so the guest never actually receives the item. This instead
    /// mirrors the authoritative-pickup accounting: it applies the stack to the proxy inventory AND
    /// enqueues the delivered amount into `pendingAuthoritativePickupItems`, so the host's per-tick
    /// `drainLANAuthoritativePickupMutations` turns it into a `LANInventoryGrant` delivered to the
    /// guest's own client-authoritative inventory, while `hasPendingAuthoritativePickupMutation`
    /// keeps the proxy from being overwritten until that grant lands. Returns whether the whole
    /// stack fit; false when the per-tick grant-batch cap is reached or the proxy inventory is full.
    @discardableResult
    public func grantScriptItem(_ stack: ItemStack) -> Bool {
        let itemID = stack.id
        guard itemID >= 0, itemID < itemDefs.count, stack.count > 0 else { return false }
        let before = stack.count
        let maxStack = max(1, maxStackOf(stack))
        let entries = (before - 1) / maxStack + 1
        guard entries <= LAN_MULTIPLAYER_MAX_GRANT_ITEMS - pendingAuthoritativePickupItems.count else {
            return false
        }
        let placedAll = give(stack)
        let delivered = before - stack.count
        guard delivered > 0 else { return false }
        var remaining = delivered
        while remaining > 0 {
            let count = min(remaining, maxStack)
            pendingAuthoritativePickupItems.append(LANInventorySlotSnapshot(
                slot: 0, itemID: itemID, count: count, damage: stack.damage, label: stack.label
            ))
            remaining -= count
        }
        return placedAll
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
        lanXPRequiredForLevel(level)
    }

    private func tickAuthoritativePickups() {
        guard age % 2 == 0 else { return }
        let actor = ScriptEventActorIdentity.lanPlayer(peerID: multiplayerPlayerID)
        for ref in world.getEntitiesNear(x, y + 0.5, z, 1.6).sorted(by: { $0.id < $1.id }) {
            if ref === self { continue }
            if (ref as? Entity)?.lanReplicatedMirror == true { continue }
            if let item = ref as? ItemEntity, item.pickupDelay <= 0 {
                let itemID = item.stack.id
                guard itemID >= 0, itemID < itemDefs.count else { continue }
                let before = item.stack.count
                let maxStack = max(1, maxStackOf(item.stack))
                let maximumMutationEntries = before > 0 ? (before - 1) / maxStack + 1 : 0
                guard maximumMutationEntries <= LAN_MULTIPLAYER_MAX_GRANT_ITEMS
                        - pendingAuthoritativePickupItems.count else { continue }
                if give(item.stack) {
                    world.hooks.playSound("entity.item.pickup", x, y, z, 0.3, 1.4 + Double.random(in: 0..<1) * 0.6)
                    item.remove()
                } else if item.stack.count != before {
                    world.hooks.playSound("entity.item.pickup", x, y, z, 0.3, 1.4)
                }
                let pickedUp = before - item.stack.count
                if pickedUp > 0 {
                    var remaining = pickedUp
                    while remaining > 0 {
                        let count = min(remaining, maxStack)
                        pendingAuthoritativePickupItems.append(LANInventorySlotSnapshot(
                            slot: 0,
                            itemID: itemID,
                            count: count,
                            damage: item.stack.damage,
                            label: item.stack.label
                        ))
                        remaining -= count
                    }
                    world.hooks.raiseScriptEvent(
                        .playerPickedUp, actor.ref,
                        ["item": .string(itemDef(itemID).name), "count": .int(Int64(pickedUp))],
                        actor.source, nil
                    )
                }
            } else if let orb = ref as? XPOrb {
                let grantedXP = max(0, min(100_000, orb.amount))
                guard grantedXP == 0
                        || pendingAuthoritativePickupXP <= 1_000_000_000 - grantedXP else { continue }
                let oldLevel = xpLevel
                addXP(orb.amount)
                world.hooks.playSound("entity.experience_orb.pickup", x, y, z, 0.4, 0.8 + Double.random(in: 0..<1) * 0.6)
                orb.remove()
                pendingAuthoritativePickupXP += grantedXP
                if xpLevel > oldLevel {
                    world.hooks.raiseScriptEvent(
                        .playerLeveled, actor.ref,
                        ["old": .int(Int64(oldLevel)), "new": .int(Int64(xpLevel))],
                        .engine, nil
                    )
                }
            }
        }
    }

    func authoritativePickupMutation() -> LANAuthoritativePickupMutation? {
        guard hasPendingAuthoritativePickupMutation else { return nil }
        return LANAuthoritativePickupMutation(
            items: pendingAuthoritativePickupItems,
            xp: pendingAuthoritativePickupXP
        )
    }

    func clearAuthoritativePickupMutation() {
        pendingAuthoritativePickupItems.removeAll(keepingCapacity: true)
        pendingAuthoritativePickupXP = 0
    }

    /// Records the hit as a `LANDamageEvent` for the transport to relay to the owning guest, who
    /// applies it locally and self-reports the resulting health (D-K: client-authoritative HP).
    /// Never mutates this cosmetic proxy's health and always returns false (no proxy knockback).
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        guard !dead, amount > 0 else { return false }
        if pendingDamage.count >= LAN_MULTIPLAYER_MAX_GRANT_ITEMS { pendingDamage.removeFirst() }
        pendingDamage.append(LANDamageEvent(
            playerID: multiplayerPlayerID,
            amount: amount,
            source: source,
            knockbackX: attacker.map { x - $0.x } ?? 0,
            knockbackZ: attacker.map { z - $0.z } ?? 0,
            attackerType: attacker?.type
        ))
        return false
    }

    /// Drains all damage events recorded since the last drain, in the order they occurred.
    public func drainPendingDamage() -> [LANDamageEvent] {
        let out = pendingDamage
        pendingDamage.removeAll()
        return out
    }
}

struct LANAuthoritativePickupMutation: Equatable {
    let items: [LANInventorySlotSnapshot]
    let xp: Int
}

/// Commits only the bounded item/XP deltas produced by authoritative guest pickups. The peer's
/// current client-published inventory remains the baseline; unrelated proxy slots never flow back
/// into session authority. Each successful commit also queues the existing idempotent owning-peer
/// additive grant, which the transport drains later in the same tick.
@discardableResult
public func drainLANAuthoritativePickupMutations(
    in world: World,
    into session: LANMultiplayerHostSession
) -> Int {
    let players = world.entities.compactMap { $0 as? LANRemotePlayerEntity }.sorted {
        if $0.multiplayerPlayerID != $1.multiplayerPlayerID {
            return $0.multiplayerPlayerID < $1.multiplayerPlayerID
        }
        return $0.id < $1.id
    }
    var committed = 0
    for player in players {
        guard let mutation = player.authoritativePickupMutation(),
              session.applyAuthoritativePickupMutation(
                mutation, for: player.multiplayerPlayerID
              ) != nil else { continue }
        player.clearAuthoritativePickupMutation()
        committed += 1
    }
    return committed
}

public func lanRemotePlayerRenderYaw(fromPlayerYaw yaw: Double) -> Double {
    let turn = Double.pi * 2
    var value = (yaw + Double.pi).truncatingRemainder(dividingBy: turn)
    if value <= -Double.pi { value += turn }
    if value > Double.pi { value -= turn }
    return value
}

/// lan-client-parity (change 4): the live `LANRemotePlayerEntity` mirroring a
/// connected guest in `world`, if any — the lookup `ObjectGraphHost.
/// lanRemotePlayer(peerID:)` delegates to on the host. `world` is always the
/// *current* dimension's world (mirroring `removeLANRemotePlayer`'s own
/// scope); `applyLANRemotePlayers` never materializes a ghost entity in a
/// dimension the host isn't currently in, so a peer connected but elsewhere
/// simply has none to find here.
public func lanRemotePlayerEntity(peerID: String, in world: World) -> LANRemotePlayerEntity? {
    let cleanID = String(peerID.prefix(128))
    return world.entities.first(where: {
        ($0 as? LANRemotePlayerEntity)?.multiplayerPlayerID == cleanID
    }) as? LANRemotePlayerEntity
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

/// Raises semantic player lifecycle events only for transitions the host session already accepted.
/// The caller supplies the pre-update session state, so rejected dimension changes/respawns collapse
/// to equal states and cannot produce an event. Dimension precedes respawn, matching `respawnPlayer`
/// when a local player respawns in a different dimension.
public func raiseLANAcceptedPlayerLifecycleEvents(
    previous: LANPlayerState?,
    accepted: LANPlayerState,
    in world: World
) {
    guard let previous,
          previous.playerID == accepted.playerID,
          let oldDimension = Dim(rawValue: previous.dimension),
          let newDimension = Dim(rawValue: accepted.dimension)
    else { return }
    let actor = ScriptEventActorIdentity.lanPlayer(peerID: accepted.playerID)
    if oldDimension != newDimension {
        world.hooks.raiseScriptEvent(
            .playerDimensionChanged, actor.ref,
            [
                "old": .string(dimCanonicalName(oldDimension)),
                "new": .string(dimCanonicalName(newDimension)),
            ],
            actor.source, nil
        )
    }
    if previous.dead && !accepted.dead {
        world.hooks.raiseScriptEvent(
            .playerRespawned, actor.ref, [:], actor.source, nil
        )
    }
}

/// A `LANPlayerState` intentionally carries no client-claimed damage cause or attacker. Health
/// deltas therefore use an explicit synchronization cause and LAN provenance rather than inventing
/// an engine attacker. The accepted before/after health values still provide the exact loss/heal.
private func raiseLANRemotePlayerHealthEvents(
    for player: LANRemotePlayerEntity,
    accepting state: LANPlayerState
) {
    guard !player.dead else { return }
    let actor = ScriptEventActorIdentity.lanPlayer(peerID: player.multiplayerPlayerID)
    let oldHealth = max(0, min(player.maxHealth, player.health))
    let newHealth = max(0, min(player.maxHealth, state.health))
    if newHealth < oldHealth {
        player.world.hooks.raiseScriptEvent(
            .entityDamaged, actor.ref,
            [
                "amount": .number(oldHealth - newHealth),
                "cause": .string("lan_state"),
                "attacker": .null,
            ],
            actor.source, player.type
        )
    } else if newHealth > oldHealth, !state.dead {
        player.world.hooks.raiseScriptEvent(
            .entityHealed, actor.ref,
            ["amount": .number(newHealth - oldHealth)],
            actor.source, player.type
        )
    }
    if state.dead {
        player.world.hooks.raiseScriptEvent(
            .entityDied, actor.ref,
            ["cause": .string("lan_state"), "attacker": .null],
            actor.source, player.type
        )
    }
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
    inventorySnapshots: [String: LANPlayerInventorySnapshot] = [:],
    /// lan-client-parity (change 4): `objectRecordTexts` are applied once, only when a *new*
    /// `LANRemotePlayerEntity` is created — a live entity's `objectRecord` is its own source of
    /// truth afterward. Client-published inventory snapshots may refresh an existing proxy in the
    /// authority-safe peer -> proxy direction, except while an exact host pickup delta awaits its
    /// same-tick session/grant commit.
    objectRecordTexts: [String: String] = [:]
) -> LANRemotePlayerApplyReport {
    var report = LANRemotePlayerApplyReport()
    let local = localPlayerID.map { String($0.prefix(128)) }
    var wanted = Set<String>()

    for state in states.sorted(by: { $0.playerID < $1.playerID }) {
        if state.playerID == local { continue }
        let existing = world.entities.first(where: {
            ($0 as? LANRemotePlayerEntity)?.multiplayerPlayerID == state.playerID
        }) as? LANRemotePlayerEntity
        if state.dead || state.dimension != world.dim.rawValue {
            if let existing {
                raiseLANRemotePlayerHealthEvents(for: existing, accepting: state)
                world.removeEntity(existing)
                report.removed += 1
            }
            continue
        }
        wanted.insert(state.playerID)
        if let existing {
            raiseLANRemotePlayerHealthEvents(for: existing, accepting: state)
            existing.apply(state)
            if !existing.hasPendingAuthoritativePickupMutation,
               let inventory = inventorySnapshots[state.playerID] {
                _ = applyLANInventorySnapshot(inventory, to: existing)
            }
            report.updated += 1
        } else {
            let remote = LANRemotePlayerEntity(world: world, state: state)
            if let inventory = inventorySnapshots[state.playerID] {
                _ = applyLANInventorySnapshot(inventory, to: remote)
            }
            if let text = objectRecordTexts[state.playerID],
               let record = ObjectRecordCodec.decode(text, caps: .defaults) {
                remote.objectRecord = record
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
