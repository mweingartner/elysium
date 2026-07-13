// Ghost actor — the host applies guest intents (break/place/attack/toss) through the REAL
// singleplayer interaction routines (finishBreaking/applyBlockIntent/playerAttack) driven by a
// per-peer detached "ghost" Player. The ghost is never added to the world and never persisted;
// it exists only long enough to authoritatively resolve one intent and read back the resulting
// inventory/XP delta for the transport to relay as a correction/grant. See D-B in the LAN
// multiplayer remediation plan.

import Foundation

/// Outcome of a ghost-driven block break: whether it happened, the ghost's post-break inventory
/// (durability consumption / bare-hand no-op reflected here), and whether a broken container's
/// contents were spilled (so the caller can prioritize replicating that block entity's clearing).
public struct LANGhostBreakOutcome: Equatable {
    public var broke: Bool
    public var inventory: LANPlayerInventorySnapshot
    public var spilledContainerAt: LANBlockPosition?
    public var reason: String?
}

/// Outcome of a ghost-driven block placement.
public struct LANGhostPlaceOutcome: Equatable {
    public var placed: Bool
    public var inventory: LANPlayerInventorySnapshot
    public var reason: String?
}

/// Outcome of a ghost-driven melee attack.
public struct LANGhostAttackOutcome: Equatable {
    public var attacked: Bool
    public var inventory: LANPlayerInventorySnapshot
    public var reason: String?
}

/// Outcome of a ghost-driven item toss.
public struct LANGhostTossOutcome: Equatable {
    public var tossed: Bool
    public var inventory: LANPlayerInventorySnapshot
    public var reason: String?
}

/// Reach used to validate ghost-driven attacks against the peer's last known position, mirroring
/// `isWithinLANReach`'s block-break/place reach (attacks use the same trust model: host validates
/// against the peer's last-published state, not a live raycast).
private let LAN_GHOST_ATTACK_REACH_SURVIVAL = 6.0
private let LAN_GHOST_ATTACK_REACH_CREATIVE = 8.0

/// Current-protocol LAN spell removal is host-authoritative in the peer's
/// recorded dimension. Keeping state mutation and exact transient cleanup in
/// one helper prevents the transport from publishing an unprepare while its
/// servant remains alive in another loaded world.
@discardableResult
public func rpgUnprepareHostedLANSpell(_ spellID: String,
                                       state: inout RPGCharacterState,
                                       playerID: String,
                                       record: LANPeerRecordSnapshot,
                                       world: World,
                                       ghostRegistry: LANHostGhostRegistry) -> RPGProgressionError? {
    let endedUpkeeps = state.activeUpkeeps.filter { $0.spellID == spellID }
    if let error = rpgUnprepareSpell(spellID, in: &state) { return error }
    if !endedUpkeeps.isEmpty {
        let ghost = ghostRegistry.ghost(for: playerID, record: record, in: world)
        rpgCleanupEndedUpkeeps(ghost, endedUpkeeps)
    }
    return nil
}

/// Lazily creates and reuses ONE detached `Player` "ghost" per LAN peer so the host can drive the
/// real singleplayer interaction routines (`finishBreaking`, `playerAttack`, `applyBlockIntent`)
/// on the guest's behalf. Ghosts are NEVER added to `world.entities` and NEVER marked persistent —
/// they are invisible actors that exist only to authoritatively resolve one intent at a time.
public final class LANHostGhostRegistry {
    private var ghosts: [String: Player] = [:]

    public init() {}

    public func advanceSimulationTicks(_ ticks: Int, for playerID: String) {
        guard ticks > 0, ticks <= LANMultiplayerHostSession.maxRPGClockCatchUpTicks else { return }
        ghosts[String(playerID.prefix(128))]?.advanceAttackStrengthRecovery(ticks: ticks)
    }

    /// Ends the lifetime of a detached authority actor. Warden provenance uses
    /// weak ownership, so removing the registry's strong reference makes any
    /// missed layer fail closed on the next world RPG tick.
    @discardableResult
    public func removeGhost(for playerID: String) -> Bool {
        ghosts.removeValue(forKey: String(playerID.prefix(128))) != nil
    }

    /// Returns the cached ghost for `playerID` (creating it once, lazily) hydrated from the given
    /// peer record. Hydration sets position/orientation/game mode/health/hunger/inventory/selected
    /// slot, primes the attack cooldown to full strength, and clears fall distance (no crit bonus
    /// from a ghost that never actually fell).
    public func ghost(for playerID: String, record: LANPeerRecordSnapshot, in world: World) -> Player {
        let cleanID = String(playerID.prefix(128))
        let player: Player
        if let existing = ghosts[cleanID] {
            player = existing
        } else {
            let created = Player(world: world)
            created.persistent = false
            ghosts[cleanID] = created
            player = created
        }
        hydrate(player, from: record, in: world)
        return player
    }

    private func hydrate(_ player: Player, from record: LANPeerRecordSnapshot, in world: World) {
        player.persistent = false
        player.world = world
        player.rpgAuthorityID = "lan:\(record.playerID)"
        if let state = record.playerState {
            player.rpg = repairRPGCharacterState(record.rpg ?? state.rpg ?? .uncreated())
            player.applyRPGDerivedStats()
            player.setPos(state.x, state.y, state.z)
            player.yaw = state.yaw
            player.pitch = state.pitch
            player.setGameMode(state.gameMode)
            player.health = max(0, min(player.maxHealth, state.health))
            player.hunger = max(0, min(20, state.hunger))
            player.selectedSlot = max(0, min(8, state.selectedHotbarSlot))
        } else {
            player.rpg = repairRPGCharacterState(record.rpg ?? .uncreated())
            player.applyRPGDerivedStats()
        }
        if let inventory = record.inventory, let materialized = makeInventoryForGhost(inventory) {
            player.inventory = materialized
            player.xp = inventory.xp
            player.xpLevel = inventory.xpLevel
            player.xpProgress = inventory.xpProgress
        } else {
            player.inventory = Array(repeating: nil, count: 36)
        }
        player.fallDistance = 0
        player.sprinting = false
        player.onGround = true
        player.inWater = false
    }

    /// Authoritatively breaks a block on the guest's behalf via the real `finishBreaking` routine
    /// (drops/XP/durability all flow through the exact singleplayer path — elysmoke-safe). Reach,
    /// authorization, and dimension checks MUST happen before calling this (mirrors
    /// `LANMultiplayerHostSession.applyBlockIntent`'s validation order). The world's own
    /// `hooks.onBlockChanged` -> `recordBlockChange` wiring replicates the resulting block change;
    /// this function does not duplicate that.
    public func applyBreak(
        for playerID: String,
        x: Int,
        y: Int,
        z: Int,
        world: World,
        session: LANMultiplayerHostSession
    ) -> LANGhostBreakOutcome {
        let cleanID = String(playerID.prefix(128))
        guard let record = session.peerRecord(playerID: cleanID) else {
            return LANGhostBreakOutcome(broke: false, inventory: emptyInventory(cleanID), reason: "unknown player")
        }
        let target = world.getBlock(x, y, z)
        guard target != 0 else {
            return LANGhostBreakOutcome(broke: false, inventory: record.inventory ?? emptyInventory(cleanID), reason: "already air")
        }
        let containerBE = world.getBlockEntity(x, y, z)
        let hadContainerContents = containerBE?.items?.contains(where: { $0 != nil }) == true

        let ghost = ghost(for: cleanID, record: record, in: world)
        let ctx = InteractCtx(world: world, player: ghost)
        finishBreaking(ctx, x, y, z)

        var spilled: LANBlockPosition?
        if hadContainerContents, world.getBlockEntity(x, y, z) == nil {
            spilled = LANBlockPosition(dimension: world.dim.rawValue, x: x, y: y, z: z)
            session.recordDirtyBlockEntity(spilled!)
        }
        return LANGhostBreakOutcome(
            broke: true,
            inventory: makeLANInventorySnapshot(ghost, playerID: cleanID),
            spilledContainerAt: spilled
        )
    }

    /// Authoritatively places a block via the existing `applyBlockIntent(.placeBlock)` host-session
    /// path (reach/authorization/replacement checks already implemented there), then decrements one
    /// matching item from the peer's stored inventory. If the peer's stored inventory doesn't have
    /// a matching item, the placement still succeeds (host is authoritative for the world; the
    /// client's own inventory bookkeeping will reconcile on its next publish) — this is reflected
    /// in `reason` for observability, never as a rejection.
    public func applyPlace(
        for playerID: String,
        intent: LANBlockIntent,
        world: World,
        session: LANMultiplayerHostSession
    ) -> LANGhostPlaceOutcome {
        let cleanID = String(playerID.prefix(128))
        guard let record = session.peerRecord(playerID: cleanID) else {
            return LANGhostPlaceOutcome(placed: false, inventory: emptyInventory(cleanID), reason: "unknown player")
        }
        let result = session.applyBlockIntent(intent, from: cleanID, to: world)
        switch result {
        case .rejected(let reason):
            return LANGhostPlaceOutcome(placed: false, inventory: record.inventory ?? emptyInventory(cleanID), reason: reason)
        case .ignored(let reason):
            return LANGhostPlaceOutcome(placed: false, inventory: record.inventory ?? emptyInventory(cleanID), reason: reason)
        case .applied:
            break
        }

        var inventory = record.inventory ?? emptyInventory(cleanID)
        let placedBlockID = intent.cell >> 4
        guard placedBlockID >= 0, placedBlockID < blockToItem.count else {
            return LANGhostPlaceOutcome(placed: true, inventory: inventory, reason: "unmapped block")
        }
        let matchingItemID = Int(blockToItem[placedBlockID])
        guard matchingItemID >= 0 else {
            return LANGhostPlaceOutcome(placed: true, inventory: inventory, reason: "no matching item")
        }
        guard var slots = decrementOneMatchingItem(in: inventory.slots, itemID: matchingItemID) else {
            return LANGhostPlaceOutcome(placed: true, inventory: inventory, reason: "peer inventory lacked placed item")
        }
        slots.sort { $0.slot < $1.slot }
        inventory = LANPlayerInventorySnapshot(
            playerID: cleanID,
            selectedHotbarSlot: inventory.selectedHotbarSlot,
            slots: slots,
            xp: inventory.xp,
            xpLevel: inventory.xpLevel,
            xpProgress: inventory.xpProgress
        )
        return LANGhostPlaceOutcome(placed: true, inventory: inventory)
    }

    /// Authoritatively resolves a melee attack via the real `playerAttack` routine. Rejects attacks
    /// on players/proxies (PvE only, D-K), dead targets, or targets beyond the peer's reach.
    public func applyAttack(
        for playerID: String,
        targetEntityID: Int,
        world: World,
        session: LANMultiplayerHostSession
    ) -> LANGhostAttackOutcome {
        let cleanID = String(playerID.prefix(128))
        guard let record = session.peerRecord(playerID: cleanID) else {
            return LANGhostAttackOutcome(attacked: false, inventory: emptyInventory(cleanID), reason: "unknown player")
        }
        guard let playerState = record.playerState else {
            return LANGhostAttackOutcome(attacked: false, inventory: record.inventory ?? emptyInventory(cleanID), reason: "player state unavailable")
        }
        guard let targetRef = world.entityById[targetEntityID], let target = targetRef as? Entity, !target.dead else {
            return LANGhostAttackOutcome(attacked: false, inventory: record.inventory ?? emptyInventory(cleanID), reason: "target not found")
        }
        guard !(target is Player), !(target is LANRemotePlayerEntity), !target.isPlayer else {
            return LANGhostAttackOutcome(attacked: false, inventory: record.inventory ?? emptyInventory(cleanID), reason: "PvP not supported")
        }
        let reach = playerState.gameMode == GameMode.creative ? LAN_GHOST_ATTACK_REACH_CREATIVE : LAN_GHOST_ATTACK_REACH_SURVIVAL
        let dx = target.x - playerState.x
        let dy = target.y - playerState.y
        let dz = target.z - playerState.z
        guard dx * dx + dy * dy + dz * dz <= reach * reach else {
            return LANGhostAttackOutcome(attacked: false, inventory: record.inventory ?? emptyInventory(cleanID), reason: "target out of reach")
        }

        let ghost = ghost(for: cleanID, record: record, in: world)
        playerAttack(ghost, target)
        return LANGhostAttackOutcome(attacked: true, inventory: makeLANInventorySnapshot(ghost, playerID: cleanID))
    }

    /// Authoritatively resolves a toss: removes `count` items from the given inventory slot and
    /// spawns them in front of the peer's last-known position with a small forward velocity
    /// derived from the peer's yaw (deterministic — no randomness beyond `spawnItem`'s existing
    /// `gameRng` jitter). Fails closed on out-of-range slots or an empty/mismatched stack.
    public func applyToss(
        for playerID: String,
        intent: LANTossIntent,
        world: World,
        session: LANMultiplayerHostSession
    ) -> LANGhostTossOutcome {
        let cleanID = String(playerID.prefix(128))
        guard let record = session.peerRecord(playerID: cleanID) else {
            return LANGhostTossOutcome(tossed: false, inventory: emptyInventory(cleanID), reason: "unknown player")
        }
        guard let playerState = record.playerState else {
            return LANGhostTossOutcome(tossed: false, inventory: record.inventory ?? emptyInventory(cleanID), reason: "player state unavailable")
        }
        let inventory = record.inventory ?? emptyInventory(cleanID)
        guard intent.slot >= 0, intent.slot < LAN_PLAYER_INVENTORY_SLOT_COUNT_FOR_GHOST else {
            return LANGhostTossOutcome(tossed: false, inventory: inventory, reason: "invalid slot")
        }
        guard let existingSlot = inventory.slots.first(where: { $0.slot == intent.slot }), existingSlot.count > 0 else {
            return LANGhostTossOutcome(tossed: false, inventory: inventory, reason: "slot empty")
        }
        let tossCount = intent.all ? existingSlot.count : min(intent.count, existingSlot.count)
        guard tossCount > 0 else {
            return LANGhostTossOutcome(tossed: false, inventory: inventory, reason: "invalid count")
        }

        var slots = inventory.slots
        if let idx = slots.firstIndex(where: { $0.slot == intent.slot }) {
            let remaining = existingSlot.count - tossCount
            if remaining <= 0 {
                slots.remove(at: idx)
            } else {
                slots[idx] = LANInventorySlotSnapshot(
                    slot: existingSlot.slot,
                    itemID: existingSlot.itemID,
                    count: remaining,
                    damage: existingSlot.damage,
                    label: existingSlot.label
                )
            }
        }
        let updated = LANPlayerInventorySnapshot(
            playerID: cleanID,
            selectedHotbarSlot: inventory.selectedHotbarSlot,
            slots: slots,
            xp: inventory.xp,
            xpLevel: inventory.xpLevel,
            xpProgress: inventory.xpProgress
        )

        let stack = ItemStack(existingSlot.itemID, tossCount, damage: existingSlot.damage, label: existingSlot.label)
        let eyeY = playerState.y + PLAYER_EYE
        let forwardX = -detSin(playerState.yaw) * 0.3
        let forwardZ = detCos(playerState.yaw) * 0.3
        let thrown = spawnItem(world, playerState.x, eyeY - 0.3, playerState.z, stack, forwardX, 0.1, forwardZ)
        thrown.pickupDelay = 40

        return LANGhostTossOutcome(tossed: true, inventory: updated)
    }
}

/// Ghost inventories always materialize the full 36-slot array (unlike wire snapshots, which omit
/// empty slots) so `finishBreaking`/`playerAttack` can freely index `player.inventory[selectedSlot]`.
private let LAN_PLAYER_INVENTORY_SLOT_COUNT_FOR_GHOST = 36

private func emptyInventory(_ playerID: String) -> LANPlayerInventorySnapshot {
    LANPlayerInventorySnapshot(playerID: playerID, selectedHotbarSlot: 0, slots: [])
}

private func makeInventoryForGhost(_ snapshot: LANPlayerInventorySnapshot) -> [ItemStack?]? {
    var inventory: [ItemStack?] = Array(repeating: nil, count: LAN_PLAYER_INVENTORY_SLOT_COUNT_FOR_GHOST)
    for slot in snapshot.slots {
        guard slot.slot >= 0, slot.slot < LAN_PLAYER_INVENTORY_SLOT_COUNT_FOR_GHOST,
              slot.itemID >= 0, slot.itemID < itemDefs.count, slot.count > 0
        else { continue }
        inventory[slot.slot] = ItemStack(slot.itemID, slot.count, damage: slot.damage, label: slot.label)
    }
    return inventory
}

/// Removes one unit of the first matching item found (lowest slot index first, deterministic),
/// mirroring `Player.consumeHeld`'s single-unit decrement semantics. Returns nil (fail closed —
/// no mutation) if no matching item exists.
private func decrementOneMatchingItem(in slots: [LANInventorySlotSnapshot], itemID: Int) -> [LANInventorySlotSnapshot]? {
    let ordered = slots.sorted { $0.slot < $1.slot }
    guard let index = ordered.firstIndex(where: { $0.itemID == itemID && $0.count > 0 }) else { return nil }
    var out = ordered
    let existing = out[index]
    if existing.count > 1 {
        out[index] = LANInventorySlotSnapshot(
            slot: existing.slot,
            itemID: existing.itemID,
            count: existing.count - 1,
            damage: existing.damage,
            label: existing.label
        )
    } else {
        out.remove(at: index)
    }
    return out
}

/// Spawns death drops from a stored inventory snapshot at the given position, mirroring
/// `Player.die()`'s drop behavior (spawnItem per non-empty slot, spawnXP from level*7 capped at
/// 100) but driven from a snapshot rather than a live `Player` — no ghost required. Determinism:
/// `spawnItem`/`spawnXP` already source their jitter from `gameRng`.
public func spawnPlayerDeathDrops(inventory: LANPlayerInventorySnapshot, at x: Double, _ y: Double, _ z: Double, in world: World) {
    for slot in inventory.slots.sorted(by: { $0.slot < $1.slot }) where slot.count > 0 {
        guard slot.itemID >= 0, slot.itemID < itemDefs.count else { continue }
        let stack = ItemStack(slot.itemID, slot.count, damage: slot.damage, label: slot.label)
        spawnItem(world, x, y + 0.5, z, stack)
    }
    let xp = min(inventory.xpLevel * 7, 100)
    if xp > 0 {
        spawnXP(world, x, y, z, xp)
    }
}
