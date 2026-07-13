import Foundation

public enum RPGActionFailure: Error, Equatable, CustomStringConvertible {
    case classesDisabled
    case actorUnavailable
    case characterNotCreated
    case actionNotPrepared
    case unknownSkill(String)
    case unknownSpell(String)
    case skillNotPrepared(String)
    case spellNotPrepared(String)
    case skillNotActive(String)
    case insufficientIntelligence(required: Int)
    case insufficientFatigue(required: Double, available: Double)
    case skillOnCooldown(String)
    case spellOnCooldown(String)
    case noTarget(String)
    case invalidTarget(String)
    case blockedPlacement(String)
    case unloadedTarget(String)
    case missingMaterial(String)
    case missingEquipment(String)
    case permissionDenied(RPGActionPermissionClass)
    case noRepairTarget
    case noEffect(String)
    case inventoryFull
    case temporaryLimit
    case boundedStateLimit
    case staleMutation
    case authorizationMismatch
    case authorityExhausted

    public var description: String {
        switch self {
        case .classesDisabled: return "RPG classes are disabled"
        case .actorUnavailable: return "You cannot act while dead or unavailable"
        case .characterNotCreated: return "Character has not been created"
        case .actionNotPrepared: return "No prepared action"
        case .unknownSkill(let id): return "Unknown skill: \(id)"
        case .unknownSpell(let id): return "Unknown spell: \(id)"
        case .skillNotPrepared(let id): return "Skill is not prepared: \(id)"
        case .spellNotPrepared(let id): return "Spell is not prepared: \(id)"
        case .skillNotActive(let id): return "Skill is passive: \(id)"
        case .insufficientIntelligence(let value): return "Requires INT \(value)"
        case .insufficientFatigue(let required, let available):
            return "Requires \(formatRPGNumber(required)) fatigue; \(formatRPGNumber(available)) available"
        case .skillOnCooldown(let id): return "Skill is on cooldown: \(id)"
        case .spellOnCooldown(let id): return "Spell is on cooldown: \(id)"
        case .noTarget(let id): return "No target for \(id)"
        case .invalidTarget(let id): return "Invalid target for \(id)"
        case .blockedPlacement(let id): return "Blocked placement for \(id)"
        case .unloadedTarget(let id): return "Target area is not loaded for \(id)"
        case .missingMaterial(let id): return "Missing material for \(id)"
        case .missingEquipment(let value): return "Requires \(value)"
        case .permissionDenied(let permission):
            return permission == .container ? "Container permission denied" : "Build permission denied"
        case .noRepairTarget: return "No damaged gear with a matching repair material"
        case .noEffect(let id): return "\(id) would have no effect"
        case .inventoryFull: return "Inventory is full"
        case .temporaryLimit: return "Too many temporary RPG effects are active"
        case .boundedStateLimit: return "RPG bounded state is full"
        case .staleMutation: return "The action target changed; try again"
        case .authorizationMismatch: return "RPG action ownership does not match the acting player"
        case .authorityExhausted: return "RPG action authority is exhausted"
        }
    }
}

private func formatRPGNumber(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
}

public struct RPGBlockPosition: Codable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var z: Int

    public init(_ x: Int, _ y: Int, _ z: Int) {
        self.x = x; self.y = y; self.z = z
    }
}

public struct RPGActionResult: Codable, Equatable {
    public var actionID: String
    public var sequence: Int
    public var message: String
    public var targetEntityID: Int?
    public var blockPosition: RPGBlockPosition?

    public init(actionID: String, sequence: Int, message: String,
                targetEntityID: Int? = nil, blockPosition: RPGBlockPosition? = nil) {
        self.actionID = actionID
        self.sequence = sequence
        self.message = message
        self.targetEntityID = targetEntityID
        self.blockPosition = blockPosition
    }
}

public enum RPGPreparedActionCycleResult: Equatable {
    case noPreparedActions
    case noOp(RPGPreparedAction)
    case selected(RPGPreparedAction)
    case authorityExhausted
}

public enum RPGPreparedSpellCycleResult: Equatable {
    case noPreparedSpells
    case noOp(String)
    case selected(String)
    case authorityExhausted
}

@inline(__always)
public func rpgNormalizedCycleDirection(_ direction: Int) -> Int {
    direction == 0 ? 0 : (direction > 0 ? 1 : -1)
}

public func rpgCyclePreparedAction(_ player: Player,
                                   direction: Int = 1) -> RPGPreparedActionCycleResult {
    player.rpg = repairRPGCharacterState(player.rpg)
    let prepared = rpgPreparedActions(player.rpg)
    guard !prepared.isEmpty else { return .noPreparedActions }
    let currentToken = player.rpg.selectedPreparedActionID
        ?? player.rpg.selectedPreparedSpellID.map { rpgPreparedActionToken(kind: .spell, id: $0) }
    let current = currentToken.flatMap { token in prepared.firstIndex { $0.token == token } } ?? 0
    let step = rpgNormalizedCycleDirection(direction)
    let next = (current + step + prepared.count) % prepared.count
    let selected = prepared[next]
    guard selected.token != currentToken else { return .noOp(selected) }
    guard rpgIncrementAuthorityRevision(&player.rpg) else { return .authorityExhausted }
    player.rpg.selectedPreparedActionID = selected.token
    if selected.kind == .spell { player.rpg.selectedPreparedSpellID = selected.id }
    return .selected(selected)
}

public func rpgCyclePreparedSpell(_ player: Player,
                                  direction: Int = 1) -> RPGPreparedSpellCycleResult {
    player.rpg = repairRPGCharacterState(player.rpg)
    let prepared = player.rpg.preparedSpellIDs
    guard !prepared.isEmpty else { return .noPreparedSpells }
    let current = player.rpg.selectedPreparedSpellID.flatMap { prepared.firstIndex(of: $0) } ?? 0
    let step = rpgNormalizedCycleDirection(direction)
    let next = (current + step + prepared.count) % prepared.count
    let previous = player.rpg.selectedPreparedSpellID
    guard prepared[next] != previous else { return .noOp(prepared[next]) }
    guard rpgIncrementAuthorityRevision(&player.rpg) else { return .authorityExhausted }
    player.rpg.selectedPreparedSpellID = prepared[next]
    player.rpg.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: prepared[next])
    return .selected(prepared[next])
}

public func rpgUseSelectedPreparedAction(_ player: Player) -> Result<RPGActionResult, RPGActionFailure> {
    let state = repairRPGCharacterState(player.rpg)
    guard let action = rpgSelectedPreparedAction(state) else { return .failure(.actionNotPrepared) }
    return rpgExecuteAction(player, kind: action.kind, id: action.id, authorization: .local(for: player))
}

public func rpgUseActionQuickSlot(
    _ player: Player, slot: Int, preferences: RPGQuickSlotPreferences
) -> Result<RPGActionResult, RPGActionFailure> {
    let state = repairRPGCharacterState(player.rpg)
    guard slot >= 0 && slot < RPG_ACTION_QUICK_SLOT_COUNT else { return .failure(.actionNotPrepared) }
    let slots = rpgActionQuickSlotActions(state, preferences: preferences)
    guard slot < slots.count, let action = slots[slot] else { return .failure(.actionNotPrepared) }
    return rpgExecuteAction(player, kind: action.kind, id: action.id, authorization: .local(for: player))
}

public func rpgCastSelectedPreparedSpell(_ player: Player) -> Result<RPGActionResult, RPGActionFailure> {
    let state = repairRPGCharacterState(player.rpg)
    guard let id = state.selectedPreparedSpellID ?? state.preparedSpellIDs.first else {
        return .failure(.spellNotPrepared(""))
    }
    return rpgCastPreparedSpell(player, spellID: id)
}

public func rpgCastPreparedSpell(_ player: Player, spellID: String) -> Result<RPGActionResult, RPGActionFailure> {
    rpgExecuteAction(player, kind: .spell, id: spellID, authorization: .local(for: player))
}

public func rpgUsePreparedSkill(_ player: Player, skillID: String) -> Result<RPGActionResult, RPGActionFailure> {
    rpgExecuteAction(player, kind: .skill, id: skillID, authorization: .local(for: player))
}

public func rpgExecuteAction(_ player: Player,
                             kind: RPGPreparedActionKind,
                             id: String,
                             authorization: RPGActionAuthorization) -> Result<RPGActionResult, RPGActionFailure> {
    switch rpgPrepareAction(player, kind: kind, id: id, authorization: authorization) {
    case .failure(let failure): return .failure(failure)
    case .success(let prepared): return rpgCommitPreparedAction(prepared, for: player)
    }
}

private struct RPGEffectPlan {
    var nextItems: RPGPlayerItemsSnapshot? = nil
    var entityGuards: [RPGEntityGuard] = []
    var blockGuards: [RPGBlockGuard] = []
    var containerGuards: [RPGContainerGuard] = []
    var operations: [RPGMutationOperation] = []
    var feedback: [RPGActionFeedback] = []
    var result: RPGActionResultTemplate
    var fatigueCredit = 0.0
    var xpEvents: [RPGXPEvent] = []
    var menderInjuryClear: (target: RPGEntityTarget, nonce: Int)? = nil
}

public func rpgPrepareAction(_ player: Player,
                             kind: RPGPreparedActionKind,
                             id: String,
                             authorization: RPGActionAuthorization) -> Result<RPGPreparedMutation, RPGActionFailure> {
    guard player.world.rule(RPG_CLASSES_GAME_RULE) else { return .failure(.classesDisabled) }
    guard !player.dead, player.deathTime <= 0, player.health > 0 else { return .failure(.actorUnavailable) }
    guard rpgIsBoundedID(authorization.ownerAuthorityID),
          authorization.ownerAuthorityID == player.effectiveRPGAuthorityID,
          authorization.worldOwnerEntityID == player.id else { return .failure(.authorizationMismatch) }
    let expectedRPG = player.rpg
    let state = repairRPGCharacterState(expectedRPG)
    guard state.created else { return .failure(.characterNotCreated) }
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION,
          let sequence = rpgNextActionSequence(state) else { return .failure(.authorityExhausted) }
    guard let metadata = rpgActionMetadata(kind: kind, id: id) else {
        return .failure(kind == .skill ? .unknownSkill(id) : .unknownSpell(id))
    }

    let baseFatigue: Double
    let baseCooldown: Int
    let duration: Int
    switch kind {
    case .skill:
        guard let skill = rpgSkillDefinition(id) else { return .failure(.unknownSkill(id)) }
        guard skill.kind == .active else { return .failure(.skillNotActive(id)) }
        guard (state.skillRanks[id] ?? 0) > 0, state.preparedSkillIDs.contains(id) else {
            return .failure(.skillNotPrepared(id))
        }
        if state.activeCooldowns.contains(where: { $0.id == id && $0.remainingTicks > 0 }) {
            return .failure(.skillOnCooldown(id))
        }
        baseFatigue = skill.fatigueCost
        baseCooldown = skill.cooldownTicks
        duration = 0
    case .spell:
        guard let spell = rpgSpellDefinition(id) else { return .failure(.unknownSpell(id)) }
        guard state.knownSpellIDs.contains(id), state.preparedSpellIDs.contains(id) else {
            return .failure(.spellNotPrepared(id))
        }
        guard state.attributes.intelligence >= spell.minimumIntelligence else {
            return .failure(.insufficientIntelligence(required: spell.minimumIntelligence))
        }
        if state.activeCooldowns.contains(where: { $0.id == id && $0.remainingTicks > 0 }) {
            return .failure(.spellOnCooldown(id))
        }
        baseFatigue = spell.fatigueCost
        baseCooldown = max(10, spell.circle * 20)
        duration = effectiveRPGSpellDuration(spell, state: state)
    }
    if let failure = validateEquipment(metadata.equipment, player: player) { return .failure(failure) }
    if metadata.permission == .build, !authorization.canBuild { return .failure(.permissionDenied(.build)) }
    if metadata.permission == .container, !authorization.canUseContainers { return .failure(.permissionDenied(.container)) }

    let cost = effectiveRPGFatigueCost(baseFatigue, identity: metadata.id, state: state)
    guard state.fatigue + 0.000_001 >= cost else {
        return .failure(.insufficientFatigue(required: cost, available: state.fatigue))
    }
    let items = RPGPlayerItemsSnapshot.capture(player)
    let planResult: Result<RPGEffectPlan, RPGActionFailure>
    switch metadata.id {
    case .skill(let effect):
        planResult = prepareSkillEffect(effect, player: player, state: state,
                                        authorization: authorization, sequence: sequence,
                                        items: items)
    case .spell(let effect):
        planResult = prepareSpellEffect(effect, player: player, state: state,
                                        authorization: authorization, sequence: sequence,
                                        duration: duration, items: items)
    }
    guard case .success(var plan) = planResult else {
        if case .failure(let failure) = planResult { return .failure(failure) }
        return .failure(.noTarget(id))
    }

    if metadata.permission == .buildOnlyForBlockTarget,
       plan.operations.contains(where: { if case .setBlock = $0 { return true }; return false }),
       !authorization.canBuild {
        return .failure(.permissionDenied(.build))
    }
    let temporaryDrafts = rpgTemporaryDrafts(in: plan.operations)
    if !temporaryDrafts.isEmpty,
       !player.world.canReserveRPGTemporaryEffects(temporaryDrafts) {
        return .failure(.temporaryLimit)
    }
    for operation in plan.operations {
        guard case .grantWardenAbsorption(let target, let minimum, _) = operation else { continue }
        guard let entity = resolveTarget(target, owner: player),
              entity.canGrantRPGWardenAbsorption(minimum, owner: player) else {
            return .failure(.boundedStateLimit)
        }
    }

    let remainingCooldowns = state.activeCooldowns.filter { $0.id != id }
    guard remainingCooldowns.count < RPG_MAX_COOLDOWNS else { return .failure(.boundedStateLimit) }
    if kind == .spell, let spell = rpgSpellDefinition(id), spell.upkeepCostPerSecond > 0, duration > 0 {
        let remainingUpkeeps = state.activeUpkeeps.filter { $0.spellID != id }
        guard remainingUpkeeps.count < RPG_MAX_UPKEEPS else { return .failure(.boundedStateLimit) }
    }

    var next = state
    next.fatigue = min(rpgDerivedStats(next).maxFatigue,
                       max(0, next.fatigue - cost + plan.fatigueCredit))
    next.actionSequence = sequence
    next.activeCooldowns.removeAll { $0.id == id }
    var cooldown = effectiveRPGCooldown(baseCooldown, state: state)
    if metadata.id == .skill(.remoteTrigger) {
        cooldown = max(10, cooldown - Int(rpgSkillEffectValue(.compactGate, in: state)))
    }
    next.activeCooldowns.append(RPGCooldown(id: id, remainingTicks: cooldown))
    if kind == .spell, let spell = rpgSpellDefinition(id), spell.upkeepCostPerSecond > 0, duration > 0 {
        next.activeUpkeeps.removeAll { $0.spellID == id }
        next.activeUpkeeps.append(RPGUpkeep(spellID: id, ownerSequence: sequence,
                                            remainingTicks: duration,
                                            costPerSecond: spell.upkeepCostPerSecond))
    }
    if player.gameMode != GameMode.creative {
        let xpReport = rpgAwardXPEvents(plan.xpEvents,
                                       simulationTick: player.world.rpgSimulationTick,
                                       worldDay: max(0, player.world.rpgSimulationTick / DAY_LENGTH),
                                       incrementRevision: false, to: &next)
        if xpReport.awardedXP > 0, let clear = plan.menderInjuryClear {
            // Generic healing also reduces outstanding hostile injury. Consume
            // an XP-awarding token first so the following heal cannot turn the
            // explicit clear into a second/failed consumption.
            plan.operations.insert(.clearMenderInjury(clear.target, expectedNonce: clear.nonce), at: 0)
        }
    }
    next.authorityRevision = state.authorityRevision + 1
    next = repairRPGCharacterState(next)

    return .success(RPGPreparedMutation(
        identity: metadata.id, metadata: metadata, authorization: authorization,
        worldIdentity: ObjectIdentifier(player.world), dimension: player.world.dim.rawValue,
        simulationTick: player.world.rpgSimulationTick, ownerEntityID: player.id,
        ownerGuard: RPGEntityGuard.capture(player), expectedRPG: expectedRPG, nextRPG: next,
        expectedItems: items, nextItems: plan.nextItems,
        entityGuards: plan.entityGuards, blockGuards: plan.blockGuards,
        containerGuards: plan.containerGuards, operations: plan.operations,
        feedback: plan.feedback, resultTemplate: plan.result
    ))
}

public func rpgCommitPreparedAction(_ prepared: RPGPreparedMutation,
                                    for player: Player) -> Result<RPGActionResult, RPGActionFailure> {
    let world = player.world
    guard ObjectIdentifier(world) == prepared.worldIdentity,
          world.dim.rawValue == prepared.dimension,
          world.rpgSimulationTick == prepared.simulationTick,
          world.rule(RPG_CLASSES_GAME_RULE),
          player.id == prepared.ownerEntityID,
          prepared.authorization.ownerAuthorityID == player.effectiveRPGAuthorityID,
          prepared.authorization.worldOwnerEntityID == player.id,
          prepared.ownerGuard.matches(player),
          player.rpg == prepared.expectedRPG,
          RPGPlayerItemsSnapshot.capture(player) == prepared.expectedItems else {
        return .failure(.staleMutation)
    }
    for guardValue in prepared.entityGuards {
        guard let entity = world.entityById[guardValue.id] as? LivingEntity,
              guardValue.matches(entity) else { return .failure(.staleMutation) }
    }
    for guardValue in prepared.blockGuards {
        guard world.isLoadedAt(guardValue.position.x, guardValue.position.z),
              world.getBlock(guardValue.position.x, guardValue.position.y, guardValue.position.z) == guardValue.cell else {
            return .failure(.staleMutation)
        }
    }
    for guardValue in prepared.containerGuards {
        guard let be = world.getBlockEntity(guardValue.position.x, guardValue.position.y, guardValue.position.z),
              guardValue.matches(be) else { return .failure(.staleMutation) }
    }
    let temporaryDrafts = rpgTemporaryDrafts(in: prepared.operations)
    for operation in prepared.operations {
        switch operation {
        case .registerTemporary:
            break
        case .spawnAllay(let spawn):
            guard world.isLoadedAt(ifloor(spawn.x), ifloor(spawn.z)),
                  entityAABBIsFree(world: world, x: spawn.x, y: spawn.y, z: spawn.z,
                                   width: 0.35, height: 0.6, excluding: player) else {
                return .failure(.staleMutation)
            }
        case .removeTemporary(let key, _):
            guard world.rpgTemporaryEffect(for: key) != nil else { return .failure(.staleMutation) }
        case .damage(let target, _, let source):
            guard let entity = resolveTarget(target, owner: player), canReceiveRPGDamage(entity, source: source) else {
                return .failure(.staleMutation)
            }
        case .clearMenderInjury(let target, let expectedNonce):
            guard let entity = resolveTarget(target, owner: player),
                  entity.validRPGMenderInjury(at: world.rpgSimulationTick)?.nonce == expectedNonce else {
                return .failure(.staleMutation)
            }
        case .grantWardenAbsorption(let target, let minimum, _):
            guard let entity = resolveTarget(target, owner: player),
                  entity.canGrantRPGWardenAbsorption(minimum, owner: player) else {
                return .failure(.staleMutation)
            }
        case .triggerDevice(let position, let expectedCell):
            let hit = RaycastHit(x: position.x, y: position.y, z: position.z,
                                 face: 0, cell: expectedCell, t: 0,
                                 px: Double(position.x) + 0.5,
                                 py: Double(position.y) + 0.5,
                                 pz: Double(position.z) + 0.5)
            guard deviceTriggerWouldChange(world, hit: hit) else { return .failure(.staleMutation) }
        case .teleportOwner(let mutation):
            guard shadowStepDestinationIsValid(player, mutation: mutation) else {
                return .failure(.staleMutation)
            }
        default: break
        }
    }

    if !temporaryDrafts.isEmpty,
       !world.canReserveRPGTemporaryEffects(temporaryDrafts) {
        return .failure(.staleMutation)
    }

    let reservationKeys = Set(temporaryDrafts.map(\.key))
    if !temporaryDrafts.isEmpty,
       !world.reserveRPGTemporaryEffects(temporaryDrafts) {
        return .failure(.staleMutation)
    }
    var spawnedEntityID: Int?
    var preSpawned: [Allay] = []
    for operation in prepared.operations {
        guard case .spawnAllay(let spawn) = operation else { continue }
        let allay = Allay(world: world)
        allay.setPos(spawn.x, spawn.y, spawn.z)
        allay.ownerId = spawn.ownerEntityID
        allay.persistent = false
        world.addEntity(allay)
        guard world.attachRPGTemporaryEntity(allay.id, to: spawn.temporaryDraft.key) else {
            allay.remove()
            world.removeEntity(allay)
            for prior in preSpawned {
                prior.remove()
                world.removeEntity(prior)
            }
            world.rollbackRPGTemporaryReservations(reservationKeys)
            return .failure(.staleMutation)
        }
        preSpawned.append(allay)
        spawnedEntityID = allay.id
    }
    for operation in prepared.operations {
        guard case .removeTemporary(let key, let restore) = operation else { continue }
        guard world.removeRPGTemporaryEffect(key, restoreGuardedBlock: restore) else {
            for spawned in preSpawned {
                spawned.remove()
                world.removeEntity(spawned)
            }
            world.rollbackRPGTemporaryReservations(reservationKeys)
            return .failure(.staleMutation)
        }
    }
    for operation in prepared.operations {
        guard case .resolveContainerLoot(let position) = operation else { continue }
        guard let be = world.getBlockEntity(position.x, position.y, position.z),
              resolveLoot(world, be) != nil else {
            for spawned in preSpawned {
                spawned.remove()
                world.removeEntity(spawned)
            }
            world.rollbackRPGTemporaryReservations(reservationKeys)
            return .failure(.staleMutation)
        }
    }

    // Every failure-prone guard/reservation has completed. Consume causal
    // provenance before authoritative XP/state publication; the main operation
    // loop treats the typed clear as already committed.
    for operation in prepared.operations {
        guard case .clearMenderInjury(let target, let expectedNonce) = operation else { continue }
        guard let entity = resolveTarget(target, owner: player),
              entity.clearRPGMenderInjury(expectedNonce: expectedNonce) else {
            return .failure(.staleMutation) // unreachable after exact entity/nonce guards
        }
    }
    for operation in prepared.operations {
        guard case .grantWardenAbsorption(let target, let minimum, let sequence) = operation else {
            continue
        }
        guard let entity = resolveTarget(target, owner: player),
              entity.grantRPGWardenAbsorption(minimum, owner: player, sequence: sequence) else {
            return .failure(.staleMutation) // unreachable after exact layer-cap guards
        }
    }

    prepared.nextItems?.apply(to: player)
    player.rpg = prepared.nextRPG
    for operation in prepared.operations {
        switch operation {
        case .heal(let target, let amount): resolveTarget(target, owner: player)?.heal(amount)
        case .damage(let target, let amount, let source):
            _ = resolveTarget(target, owner: player)?.hurt(amount, source, player)
        case .addEffect(let target, let id, let ticks, let amplifier):
            resolveTarget(target, owner: player)?.addEffect(id, ticks, amplifier)
        case .removeEffects(let target, let ids):
            guard let entity = resolveTarget(target, owner: player) else { break }
            for id in ids { entity.removeEffect(id) }
        case .setMinimumAbsorption(let target, let value):
            if let entity = resolveTarget(target, owner: player) { entity.absorption = max(entity.absorption, value) }
        case .grantWardenAbsorption:
            break // prevalidated and committed before RPG publication
        case .clearMenderInjury:
            break // prevalidated and consumed before RPG publication
        case .setArcanistFire(let target, let ticks):
            if let entity = resolveTarget(target, owner: player) {
                entity.fireTicks = max(entity.fireTicks, ticks)
                entity.rpgArcanistFireOwner = player
                entity.rpgArcanistFireExpiryTick = rpgSaturatedAdd(world.rpgSimulationTick,
                                                                   max(0, ticks))
            }
        case .setFreezeTicks(let target, let ticks):
            if let entity = resolveTarget(target, owner: player) { entity.freezeTicks = max(entity.freezeTicks, ticks) }
        case .addVelocity(let target, let dx, let dy, let dz):
            if let entity = resolveTarget(target, owner: player) { entity.vx += dx; entity.vy += dy; entity.vz += dz }
        case .teleportOwner(let mutation):
            player.setPos(mutation.destinationX, mutation.destinationY, mutation.destinationZ)
            player.vx = 0; player.vy = 0; player.vz = 0; player.fallDistance = 0
        case .damageHeld(let amount): player.damageHeld(amount)
        case .setBlock(let mutation):
            world.setBlock(mutation.position.x, mutation.position.y, mutation.position.z, mutation.newCell)
        case .scheduleBlockTick(let position, let id, let delay):
            world.scheduleTick(position.x, position.y, position.z, id, delay)
        case .resolveContainerLoot(let position):
            _ = position // materialized transactionally before publishing player cost
        case .triggerDevice(let position, let expectedCell):
            commitRPGDeviceTrigger(world, player: player, position: position, cell: expectedCell)
        case .registerTemporary, .removeTemporary, .spawnAllay:
            break // handled transactionally before publishing player state
        }
    }
    for effect in prepared.feedback {
        world.hooks.addParticles(effect.particle, effect.x, effect.y, effect.z,
                                 effect.count, effect.spread, effect.data)
    }
    player.applyRPGDerivedStats()
    return .success(makeActionResult(prepared, player: player, spawnedEntityID: spawnedEntityID))
}

private func rpgTemporaryDrafts(in operations: [RPGMutationOperation]) -> [RPGTemporaryEffectDraft] {
    operations.compactMap { operation in
        switch operation {
        case .registerTemporary(let draft): return draft
        case .spawnAllay(let spawn): return spawn.temporaryDraft
        default: return nil
        }
    }
}

private func resolveTarget(_ target: RPGEntityTarget, owner: Player) -> LivingEntity? {
    switch target {
    case .owner: return owner
    case .entity(let id): return owner.world.entityById[id] as? LivingEntity
    }
}

private func makeActionResult(_ prepared: RPGPreparedMutation,
                              player: Player,
                              spawnedEntityID: Int?) -> RPGActionResult {
    let id = prepared.identity.rawValue
    switch prepared.resultTemplate {
    case .fixed(let message, let target, let position):
        return RPGActionResult(actionID: id, sequence: player.rpg.actionSequence,
                               message: message, targetEntityID: target ?? spawnedEntityID,
                               blockPosition: position)
    case .containerOccupancy(let position, let maximum):
        let items = player.world.getBlockEntity(position.x, position.y, position.z)?.items ?? []
        let occupied = items.enumerated().compactMap { $0.element == nil ? nil : $0.offset }
        let shown = occupied.prefix(maximum).map { String($0 + 1) }.joined(separator: ", ")
        let suffix = occupied.count > maximum ? " (+\(occupied.count - maximum) more)" : ""
        let message = occupied.isEmpty ? "Container is empty" : "Occupied slots: \(shown)\(suffix)"
        return RPGActionResult(actionID: id, sequence: player.rpg.actionSequence,
                               message: message, blockPosition: position)
    case .fortuneRead(let position, let precision):
        let items = player.world.getBlockEntity(position.x, position.y, position.z)?.items ?? []
        let occupied = items.enumerated().compactMap { index, stack -> (Int, ItemStack)? in
            stack.map { (index, $0) }
        }
        guard !occupied.isEmpty else {
            return RPGActionResult(actionID: id, sequence: player.rpg.actionSequence,
                                   message: "Container is empty", blockPosition: position)
        }
        let selection = occupied[min(occupied.count - 1,
                                     max(0, player.rpg.attributes.luck - RPGAttributes.minimum) % occupied.count)]
        let fill: String
        if precision <= 1 {
            let fraction = Double(occupied.count) / Double(max(1, items.count))
            fill = fraction < 0.34 ? "mostly empty" : fraction < 0.67 ? "partly filled" : "mostly filled"
        } else if precision == 2 {
            fill = "about \(Int((Double(occupied.count) / Double(max(1, items.count)) * 4).rounded()) * 25)% filled"
        } else {
            fill = "\(occupied.count)/\(items.count) slots filled"
        }
        return RPGActionResult(actionID: id, sequence: player.rpg.actionSequence,
                               message: "\(itemDef(selection.1.id).displayName) ×\(selection.1.count); \(fill)",
                               blockPosition: position)
    }
}

private func validateEquipment(_ requirement: RPGEquipmentRequirement,
                               player: Player) -> RPGActionFailure? {
    switch requirement {
    case .none: return nil
    case .apprenticeFocus:
        guard rpgPlayerHasSpellFocus(player) else {
            return .missingEquipment("an Apprentice Focus")
        }
    case .heldMeleeWeapon:
        guard let held = player.mainHand, let tool = itemDef(held.id).tool,
              tool.type == "sword" || tool.type == "axe" else {
            return .missingEquipment("a sword or axe in your main hand")
        }
    case .heldBowAndArrow:
        guard let held = player.mainHand, itemDef(held.id).tool?.type == "bow" else {
            return .missingEquipment("a bow in your main hand")
        }
        guard player.gameMode == GameMode.creative || (iidOpt("arrow").map { player.countItem($0) > 0 } ?? false) else {
            return .missingMaterial("arrow")
        }
    case .heldPickaxe:
        guard let held = player.mainHand, itemDef(held.id).tool?.type == "pickaxe" else {
            return .missingEquipment("a pickaxe in your main hand")
        }
    case .heldTool:
        guard let held = player.mainHand, itemDef(held.id).tool != nil else {
            return .missingEquipment("a tool in your main hand")
        }
    }
    return nil
}

private func effectiveRPGCooldown(_ base: Int, state: RPGCharacterState) -> Int {
    let multiplier = max(0.80, rpgDerivedStats(state).actionRecoveryMultiplier)
    return max(10, Int((Double(max(0, base)) * multiplier).rounded(.up)))
}

private func effectiveRPGFatigueCost(_ base: Double,
                                     identity: RPGExecutableEffectID,
                                     state: RPGCharacterState) -> Double {
    guard base > 0 else { return 0 }
    let derived = rpgDerivedStats(state)
    var cost = base
    if case .spell(let spell) = identity {
        if [.ignite, .frostRay, .shock, .stormAura].contains(spell) {
            cost = max(0, cost - rpgSkillEffectValue(.sparkWeave, in: state))
        }
        cost *= derived.focusCostMultiplier
    }
    let floor = if case .spell = identity { 1.0 } else { 0.5 }
    return max(floor, (cost * 10).rounded(.up) / 10)
}

private func effectiveRPGSpellDuration(_ spell: RPGSpellDefinition, state: RPGCharacterState) -> Int {
    var multiplier = 1.0
    if spell.categories.contains(.illusion) {
        multiplier *= max(1, rpgSkillEffectValue(.minorGlamour, in: state))
    }
    if spell.categories.contains(.creation) || spell.id == "ward" || spell.id == "stone_ward" {
        multiplier *= max(1, rpgSkillEffectValue(.ritualCircle, in: state))
    }
    return max(0, min(RPG_MAX_EFFECT_TICKS, Int((Double(spell.durationTicks) * multiplier).rounded())))
}

public func rpgIsHostileTarget(_ entity: LivingEntity) -> Bool {
    !entity.isPlayer && (entity is Monster || entity.type == "ender_dragon")
}

private func canReceiveRPGDamage(_ entity: LivingEntity, source: String) -> Bool {
    guard !entity.dead, entity.deathTime <= 0, entity.invulnTicks <= 0,
          rpgIsHostileTarget(entity) else { return false }
    if let wither = entity as? WitherBoss, wither.chargeTime > 0 { return false }
    _ = source
    return true
}

private func lookVector(_ player: Player) -> (dx: Double, dy: Double, dz: Double) {
    let cp = detCos(player.pitch)
    return (-detSin(player.yaw) * cp, -detSin(player.pitch), detCos(player.yaw) * cp)
}

private func rayLivingTarget(_ player: Player, range: Double) -> (LivingEntity, Double)? {
    let look = lookVector(player)
    var best: (LivingEntity, Double)?
    for ref in player.world.getEntitiesNear(player.x, player.eyeY(), player.z, range + 2) {
        guard let entity = ref as? LivingEntity, entity !== player, !entity.dead else { continue }
        let vx = entity.x - player.x
        let vy = entity.centerY() - player.eyeY()
        let vz = entity.z - player.z
        let t = vx * look.dx + vy * look.dy + vz * look.dz
        guard t >= 0, t <= range else { continue }
        let dx = entity.x - (player.x + look.dx * t)
        let dy = entity.centerY() - (player.eyeY() + look.dy * t)
        let dz = entity.z - (player.z + look.dz * t)
        let radius = max(0.45, entity.width * 0.5 + 0.35)
        guard dx * dx + dy * dy + dz * dz <= radius * radius else { continue }
        if best == nil || t < best!.1 || (t == best!.1 && entity.id < best!.0.id) { best = (entity, t) }
    }
    return best
}

private func hostileRayTarget(_ player: Player, range: Double, actionID: String) -> Result<LivingEntity, RPGActionFailure> {
    let look = lookVector(player)
    let blockHit = player.world.raycast(player.x, player.eyeY(), player.z,
                                        look.dx, look.dy, look.dz, range)
    guard let (entity, t) = rayLivingTarget(player, range: range),
          blockHit == nil || t <= blockHit!.t else { return .failure(.noTarget(actionID)) }
    guard rpgIsHostileTarget(entity), canReceiveRPGDamage(entity, source: "rpg") else {
        return .failure(.invalidTarget(actionID))
    }
    return .success(entity)
}

private func touchedAllyOrSelf(_ player: Player, range: Double, actionID: String) -> Result<RPGEntityTarget, RPGActionFailure> {
    guard let (entity, t) = rayLivingTarget(player, range: range) else { return .success(.owner) }
    let look = lookVector(player)
    let blockHit = player.world.raycast(player.x, player.eyeY(), player.z,
                                        look.dx, look.dy, look.dz, range)
    guard blockHit == nil || t <= blockHit!.t else { return .failure(.noTarget(actionID)) }
    guard !entity.dead, entity.deathTime <= 0, entity.health.isFinite, entity.health > 0,
          !entity.isPlayer, !rpgIsHostileTarget(entity) else {
        return .failure(.invalidTarget(actionID))
    }
    return .success(.entity(entity.id))
}

private func sortedLivingNear(_ player: Player, radius: Double,
                              predicate: (LivingEntity) -> Bool) -> [LivingEntity] {
    player.world.getEntitiesNear(player.x, player.y + player.height * 0.5, player.z, radius)
        .compactMap { $0 as? LivingEntity }
        .filter {
            $0 !== player && !$0.dead && $0.deathTime <= 0
                && $0.health.isFinite && $0.health > 0 && predicate($0)
        }
        .sorted {
            let ad = player.distanceToSq($0), bd = player.distanceToSq($1)
            return ad == bd ? $0.id < $1.id : ad < bd
        }
}

private func adjacentPosition(_ hit: RaycastHit) -> RPGBlockPosition {
    RPGBlockPosition(hit.x + DIR_X[hit.face], hit.y + DIR_Y[hit.face], hit.z + DIR_Z[hit.face])
}

private func isReplaceable(_ world: World, _ position: RPGBlockPosition) -> Bool {
    guard world.isLoadedAt(position.x, position.z),
          position.y >= world.info.minY,
          position.y < world.info.minY + world.info.height else { return false }
    let id = world.getBlock(position.x, position.y, position.z) >> 4
    return id == 0 || (id >= 0 && id < blockDefs.count && blockDefs[id].replaceable)
}

private func feedback(_ particle: String, _ x: Double, _ y: Double, _ z: Double,
                      _ count: Int = 12, _ spread: Double = 0.4, _ data: Int = 0) -> RPGActionFeedback {
    RPGActionFeedback(particle: particle, x: x, y: y, z: z,
                      count: count, spread: spread, data: data)
}

private func prepareSkillEffect(_ effect: RPGSkillEffectID,
                                player: Player,
                                state: RPGCharacterState,
                                authorization: RPGActionAuthorization,
                                sequence: Int,
                                items: RPGPlayerItemsSnapshot) -> Result<RPGEffectPlan, RPGActionFailure> {
    let id = effect.rawValue
    let rankValue = rpgSkillEffectValue(effect, in: state)
    switch effect {
    case .interpose:
        let allies = Array(sortedLivingNear(player, radius: 5) { !$0.isPlayer && !rpgIsHostileTarget($0) }.prefix(3))
        var plan = RPGEffectPlan(result: .fixed("Interpose"))
        plan.operations.append(.grantWardenAbsorption(.owner, rankValue, ownerSequence: sequence))
        plan.operations.append(.addEffect(.owner, id: "resistance", ticks: 120, amplifier: 0))
        for ally in allies {
            plan.entityGuards.append(.capture(ally))
            plan.operations.append(.grantWardenAbsorption(.entity(ally.id), rankValue,
                                                           ownerSequence: sequence))
            plan.operations.append(.addEffect(.entity(ally.id), id: "resistance", ticks: 100, amplifier: 0))
        }
        plan.feedback.append(feedback("totem", player.x, player.y + 1, player.z, 18, 1.4))
        return .success(plan)

    case .anchorLine:
        let targetResult = touchedAllyOrSelf(player, range: 6, actionID: id)
        guard case .success(let targetKind) = targetResult else { return mapTargetFailure(targetResult) }
        guard case .entity(let targetID) = targetKind,
              let target = player.world.entityById[targetID] as? LivingEntity else { return .failure(.noTarget(id)) }
        let dx = player.x - target.x, dz = player.z - target.z
        let distance = max(0.001, detHyp(dx, dz))
        var plan = RPGEffectPlan(result: .fixed("Anchor Line", targetEntityID: target.id))
        plan.entityGuards = [.capture(target)]
        plan.operations = [
            .addEffect(.owner, id: "resistance", ticks: 180, amplifier: 0),
            .addVelocity(.entity(target.id), dx / distance * rankValue, 0, dz / distance * rankValue),
            .addEffect(.entity(target.id), id: "slowness", ticks: 80, amplifier: 0),
        ]
        plan.feedback.append(feedback("crit", target.x, target.centerY(), target.z))
        return .success(plan)

    case .heavyCut:
        let targetResult = hostileRayTarget(player, range: 4.5, actionID: id)
        guard case .success(let target) = targetResult else { return mapTargetFailure(targetResult) }
        let weaponDamage = player.mainHand.flatMap { itemDef($0.id).tool?.attackDamage } ?? 0
        let damage = 1 + weaponDamage + rankValue + rpgDerivedStats(state).meleeDamageBonus
        let slow = 60 + Int(rpgSkillEffectValue(.staggerChain, in: state))
        var plan = damagePlan(id: id, name: "Heavy Cut", player: player, target: target,
                              damage: damage, source: RPG_DAMAGE_SOURCE_WARDEN_MELEE)
        plan.operations.append(.addEffect(.entity(target.id), id: "slowness", ticks: slow, amplifier: 0))
        plan.operations.append(.damageHeld(1))
        return .success(plan)

    case .chargeBreak:
        let targetResult = hostileRayTarget(player, range: 5, actionID: id)
        guard case .success(let target) = targetResult else { return mapTargetFailure(targetResult) }
        let look = lookVector(player)
        var plan = damagePlan(id: id, name: "Charge Break", player: player, target: target,
                              damage: rankValue, source: RPG_DAMAGE_SOURCE_WARDEN_MELEE)
        plan.operations.insert(.addVelocity(.owner, look.dx * 0.65, 0, look.dz * 0.65), at: 0)
        plan.operations.append(.addEffect(.entity(target.id), id: "weakness", ticks: 80, amplifier: 0))
        plan.operations.append(.addVelocity(.entity(target.id), look.dx * 0.45, 0, look.dz * 0.45))
        return .success(plan)

    case .fortifyBlock:
        guard let hit = blockRay(player, range: 5) else { return .failure(.noTarget(id)) }
        let blockID = hit.cell >> 4
        guard blockID > 0, blockID < blockDefs.count, blockDefs[blockID].hardness >= 0 else {
            return .failure(.blockedPlacement(id))
        }
        let position = RPGBlockPosition(hit.x, hit.y, hit.z)
        let draft = temporaryDraft(.fortifiedBlock, player: player, authorization: authorization,
                                   sequence: sequence, center: position, radius: 0,
                                   duration: 600, charges: Int(rankValue))
        var plan = RPGEffectPlan(result: .fixed("Fortify Block", blockPosition: position))
        plan.blockGuards = [RPGBlockGuard(position: position, cell: hit.cell)]
        plan.operations = [.registerTemporary(draft)]
        plan.feedback.append(feedback("enchant", Double(hit.x) + 0.5, Double(hit.y) + 0.5, Double(hit.z) + 0.5, 18, 0.55))
        return .success(plan)

    case .cripplingShot:
        let targetResult = hostileRayTarget(player, range: 18, actionID: id)
        guard case .success(let target) = targetResult else { return mapTargetFailure(targetResult) }
        guard let nextItems = removingItem(named: "arrow", count: 1, from: items,
                                           creative: player.gameMode == GameMode.creative) else {
            return .failure(.missingMaterial(id))
        }
        let damage = 4 + Double(max(0, state.attributes.dexterity - 10)) * 0.25
        var plan = damagePlan(id: id, name: "Crippling Shot", player: player, target: target,
                              damage: damage, source: RPG_DAMAGE_SOURCE_RANGER_PROJECTILE)
        plan.nextItems = nextItems
        plan.operations.append(.addEffect(.entity(target.id), id: "slowness", ticks: Int(rankValue), amplifier: 1))
        plan.operations.append(.damageHeld(1))
        return .success(plan)

    case .farSight:
        let targets = Array(sortedLivingNear(player, radius: rankValue, predicate: rpgIsHostileTarget).prefix(8))
        var plan = RPGEffectPlan(result: .fixed("Far Sight"))
        plan.operations.append(.addEffect(.owner, id: "night_vision", ticks: 600, amplifier: 0))
        for target in targets {
            plan.entityGuards.append(.capture(target))
            plan.operations.append(.addEffect(.entity(target.id), id: "glowing", ticks: 220, amplifier: 0))
        }
        plan.feedback.append(feedback("glow", player.x, player.eyeY(), player.z, 18, 1.1))
        return .success(plan)

    case .fastBore:
        var plan = RPGEffectPlan(result: .fixed("Fast Bore"))
        plan.operations = [.addEffect(.owner, id: "haste", ticks: 280, amplifier: max(0, Int(rankValue) - 1))]
        plan.feedback.append(feedback("block", player.x, player.y + 0.4, player.z, 14, 0.6, Int(cell(B.stone))))
        return .success(plan)

    case .trapProbe:
        guard let found = nearestBlock(from: player, radius: Int(rankValue), matching: isTrapBlockID) else {
            return .failure(.noTarget(id))
        }
        let position = RPGBlockPosition(found.x, found.y, found.z)
        var plan = RPGEffectPlan(result: .fixed("Trap Probe", blockPosition: position))
        plan.blockGuards = [RPGBlockGuard(position: position, cell: player.world.getBlock(found.x, found.y, found.z))]
        plan.feedback.append(feedback("redstone", Double(found.x) + 0.5, Double(found.y) + 0.5, Double(found.z) + 0.5, 14, 0.35))
        return .success(plan)

    case .deadfall:
        guard let hit = blockRay(player, range: 6) else { return .failure(.noTarget(id)) }
        let position = adjacentPosition(hit)
        guard player.world.isLoadedAt(position.x, position.z) else { return .failure(.unloadedTarget(id)) }
        guard isReplaceable(player.world, position) else { return .failure(.blockedPlacement(id)) }
        guard let gravel = iidOpt("gravel"), let gravelBlock = itemDef(gravel).block else { return .failure(.missingMaterial(id)) }
        guard let nextItems = removingItem(named: "gravel", count: 1, from: items,
                                           creative: player.gameMode == GameMode.creative) else {
            return .failure(.missingMaterial(id))
        }
        let old = player.world.getBlock(position.x, position.y, position.z)
        let temporary = Int(cell(gravelBlock))
        let guardBlock = RPGGuardedTemporaryBlock(position: position, originalCell: old, temporaryCell: temporary)
        let draft = temporaryDraft(.gravelTrap, player: player, authorization: authorization,
                                   sequence: sequence, center: position, duration: Int(rankValue), guarded: guardBlock)
        var plan = RPGEffectPlan(nextItems: nextItems, result: .fixed("Deadfall", blockPosition: position))
        plan.blockGuards = [RPGBlockGuard(position: position, cell: old)]
        plan.operations = [.setBlock(RPGBlockMutation(position: position, expectedCell: old, newCell: temporary)),
                           .registerTemporary(draft)]
        plan.feedback.append(feedback("block", Double(position.x) + 0.5, Double(position.y) + 0.5,
                                      Double(position.z) + 0.5, 10, 0.35, temporary))
        return .success(plan)

    case .lockTouch, .fortuneRead:
        guard let hit = blockRay(player, range: 5), isContainerBlockID(hit.cell >> 4) else {
            return .failure(.noTarget(id))
        }
        let position = RPGBlockPosition(hit.x, hit.y, hit.z)
        guard let be = player.world.getBlockEntity(hit.x, hit.y, hit.z) else { return .failure(.noTarget(id)) }
        var plan = RPGEffectPlan(result: effect == .lockTouch
                                 ? .containerOccupancy(position, maximumSlots: Int(rankValue))
                                 : .fortuneRead(position, precision: Int(rankValue)))
        plan.blockGuards = [RPGBlockGuard(position: position, cell: hit.cell)]
        plan.containerGuards = [.capture(be, at: position)]
        let hasMaterializableLoot = be.type == "container" && !(be.items?.isEmpty ?? true)
            && be.lootTable != nil
        if hasMaterializableLoot { plan.operations.append(.resolveContainerLoot(position)) }
        plan.feedback.append(feedback("enchant", Double(hit.x) + 0.5, Double(hit.y) + 0.7, Double(hit.z) + 0.5))
        if hasMaterializableLoot, let key = be.rpgGeneratedContainerKey, rpgIsBoundedID(key) {
            plan.xpEvents.append(RPGXPEvent(kind: .delverDungeonMilestone, key: key))
        }
        return .success(plan)

    case .secondBreath:
        guard player.health < player.maxHealth else { return .failure(.noEffect(id)) }
        var plan = RPGEffectPlan(result: .fixed("Second Breath"))
        plan.operations = [.heal(.owner, rankValue)]
        plan.feedback.append(feedback("heart", player.x, player.y + player.height, player.z))
        return .success(plan)

    case .safeHaven:
        let center = RPGBlockPosition(ifloor(player.x), ifloor(player.y), ifloor(player.z))
        let draft = temporaryDraft(.safeHaven, player: player, authorization: authorization,
                                   sequence: sequence, center: center, radius: 4, duration: 260)
        var plan = RPGEffectPlan(result: .fixed("Safe Haven", blockPosition: center))
        plan.fatigueCredit = rankValue
        plan.operations = [.addEffect(.owner, id: "regeneration", ticks: 120, amplifier: 0),
                           .registerTemporary(draft)]
        plan.feedback.append(feedback("happy_villager", player.x, player.y + 0.5, player.z, 18, 1.5))
        return .success(plan)

    case .remoteTrigger:
        let range = rpgSkillEffectValue(.remoteTrigger, in: state)
        guard let hit = blockRay(player, range: range), isRemoteTriggerBlockID(hit.cell >> 4),
              deviceTriggerWouldChange(player.world, hit: hit) else { return .failure(.noTarget(id)) }
        let position = RPGBlockPosition(hit.x, hit.y, hit.z)
        var plan = RPGEffectPlan(result: .fixed("Remote Trigger", blockPosition: position))
        plan.blockGuards = [RPGBlockGuard(position: position, cell: hit.cell)]
        plan.operations = [.triggerDevice(position, expectedCell: hit.cell)]
        return .success(plan)

    case .fieldMod:
        var plan = RPGEffectPlan(result: .fixed("Field Mod"))
        plan.operations = [.addEffect(.owner, id: "haste", ticks: 300, amplifier: max(0, Int(rankValue) - 1))]
        plan.feedback.append(feedback("enchant", player.x, player.y + 1, player.z))
        return .success(plan)

    case .quickRepair:
        guard let repair = plannedQuickRepair(player: player, state: state, items: items) else {
            return .failure(.noRepairTarget)
        }
        return .success(RPGEffectPlan(nextItems: repair.items, result: .fixed(repair.message)))

    case .chargePack:
        guard let hit = blockRay(player, range: 6) else { return .failure(.noTarget(id)) }
        let position = adjacentPosition(hit)
        guard player.world.isLoadedAt(position.x, position.z) else { return .failure(.unloadedTarget(id)) }
        guard isReplaceable(player.world, position) else { return .failure(.blockedPlacement(id)) }
        guard let nextItems = removingItem(named: "tnt", count: 1, from: items,
                                           creative: player.gameMode == GameMode.creative) else {
            return .failure(.missingMaterial(id))
        }
        let old = player.world.getBlock(position.x, position.y, position.z)
        let temporary = Int(cell(B.tnt))
        let guardBlock = RPGGuardedTemporaryBlock(position: position, originalCell: old, temporaryCell: temporary)
        let draft = temporaryDraft(.controlledCharge, player: player, authorization: authorization,
                                   sequence: sequence, center: position, duration: Int(rankValue), guarded: guardBlock)
        var plan = RPGEffectPlan(nextItems: nextItems, result: .fixed("Charge Pack", blockPosition: position))
        plan.blockGuards = [RPGBlockGuard(position: position, cell: old)]
        plan.operations = [.setBlock(RPGBlockMutation(position: position, expectedCell: old, newCell: temporary)),
                           .registerTemporary(draft)]
        return .success(plan)

    case .safeFuse:
        let range = rpgSkillEffectValue(.safeFuse, in: state)
        guard let charge = player.world.nearestOwnedRPGCharge(ownerID: authorization.ownerAuthorityID,
                                                               x: player.x, eyeY: player.eyeY(),
                                                               y: player.y, z: player.z,
                                                               radius: range),
              let guardBlock = charge.draft.guardedBlock else { return .failure(.noTarget(id)) }
        var nextItems = items.deepCopy()
        if player.gameMode != GameMode.creative {
            guard let tnt = iidOpt("tnt"), insertItem(ItemStack(tnt, 1), into: &nextItems.inventory) else {
                return .failure(.inventoryFull)
            }
        }
        var plan = RPGEffectPlan(nextItems: nextItems,
                                 result: .fixed("Safe Fuse", blockPosition: guardBlock.position))
        plan.blockGuards = [RPGBlockGuard(position: guardBlock.position, cell: guardBlock.temporaryCell)]
        plan.operations = [.removeTemporary(charge.key, restoreGuardedBlock: true)]
        return .success(plan)

    case .guardStance, .staggerChain, .shieldBind, .plateTraining,
         .quickDraw, .steadyAim, .trailSense, .softStep, .campcraft, .weatherEye, .beastKinship,
         .veinReader, .deepReserves, .tripwireMind, .salvageEye,
         .spellFormula, .sparkWeave, .stormFocus, .minorGlamour, .falseStep, .mirrorWork,
         .ritualCircle, .boundServant, .wardScribe,
         .fieldDressing, .triage, .herbalLore, .cleanBrew, .greenThumb,
         .protectiveMark, .sanctuaryBell, .circuitSense, .compactGate, .toolTune, .blastShape:
        return .failure(.skillNotActive(id))
    }
}

private func prepareSpellEffect(_ effect: RPGSpellEffectID,
                                player: Player,
                                state: RPGCharacterState,
                                authorization: RPGActionAuthorization,
                                sequence: Int,
                                duration: Int,
                                items: RPGPlayerItemsSnapshot) -> Result<RPGEffectPlan, RPGActionFailure> {
    let id = effect.rawValue
    _ = items
    guard let spell = rpgSpellDefinition(id) else { return .failure(.unknownSpell(id)) }
    let potency = rpgDerivedStats(state).spellPotencyBonus
    var result: Result<RPGEffectPlan, RPGActionFailure>
    switch effect {
    case .ignite:
        let look = lookVector(player)
        let blockHit = player.world.raycast(player.x, player.eyeY(), player.z,
                                            look.dx, look.dy, look.dz, spell.rangeBlocks)
        let entityHit = rayLivingTarget(player, range: spell.rangeBlocks)
        if let (target, t) = entityHit, blockHit == nil || t <= blockHit!.t {
            guard canReceiveRPGDamage(target, source: RPG_DAMAGE_SOURCE_ARCANIST_SPELL) else {
                return .failure(.invalidTarget(id))
            }
            var plan = damagePlan(id: id, name: spell.displayName, player: player, target: target,
                                  damage: 4 + potency + rpgSkillEffectValue(.spellFormula, in: state),
                                  source: RPG_DAMAGE_SOURCE_ARCANIST_SPELL)
            plan.operations.append(.setArcanistFire(.entity(target.id), 120))
            result = .success(plan)
        } else if let hit = blockHit {
            let position = adjacentPosition(hit)
            guard authorization.canBuild else { return .failure(.permissionDenied(.build)) }
            guard player.world.isLoadedAt(position.x, position.z) else { return .failure(.unloadedTarget(id)) }
            guard isReplaceable(player.world, position) else { return .failure(.blockedPlacement(id)) }
            let old = player.world.getBlock(position.x, position.y, position.z)
            var plan = RPGEffectPlan(result: .fixed(spell.displayName, blockPosition: position))
            plan.blockGuards = [RPGBlockGuard(position: position, cell: old)]
            plan.operations = [.setBlock(RPGBlockMutation(position: position, expectedCell: old,
                                                           newCell: Int(cell(B.fire))))]
            result = .success(plan)
        } else {
            return .failure(.noTarget(id))
        }

    case .frostRay:
        let targetResult = hostileRayTarget(player, range: spell.rangeBlocks, actionID: id)
        guard case .success(let target) = targetResult else { return mapTargetFailure(targetResult) }
        var plan = damagePlan(id: id, name: spell.displayName, player: player, target: target,
                              damage: 3 + potency + rpgSkillEffectValue(.spellFormula, in: state),
                              source: RPG_DAMAGE_SOURCE_ARCANIST_SPELL)
        plan.operations.append(.addEffect(.entity(target.id), id: "slowness", ticks: 120, amplifier: 1))
        plan.operations.append(.setFreezeTicks(.entity(target.id), 160))
        result = .success(plan)

    case .shock:
        let targetResult = hostileRayTarget(player, range: spell.rangeBlocks, actionID: id)
        guard case .success(let target) = targetResult else { return mapTargetFailure(targetResult) }
        var plan = damagePlan(id: id, name: spell.displayName, player: player, target: target,
                              damage: 5 + potency + rpgSkillEffectValue(.spellFormula, in: state),
                              source: RPG_DAMAGE_SOURCE_ARCANIST_SPELL)
        let primaryWet = target.inWater || target.world.isRainingAt(ifloor(target.x), ifloor(target.y), ifloor(target.z))
        if primaryWet, let chain = nearestWetHostile(from: target, excluding: [player.id, target.id], radius: 4) {
            plan.entityGuards.append(.capture(chain))
            plan.operations.append(.damage(.entity(chain.id), 3 + potency,
                                           source: RPG_DAMAGE_SOURCE_ARCANIST_SPELL))
        }
        result = .success(plan)

    case .stormAura:
        result = .success(RPGEffectPlan(result: .fixed(spell.displayName)))

    case .blur:
        var plan = RPGEffectPlan(result: .fixed(spell.displayName))
        plan.operations = [.addEffect(.owner, id: "invisibility", ticks: min(40, duration), amplifier: 0)]
        result = .success(plan)

    case .decoy:
        let point = targetPoint(player, range: spell.rangeBlocks)
        let center = RPGBlockPosition(ifloor(point.x), ifloor(point.y), ifloor(point.z))
        guard player.world.isLoadedAt(center.x, center.z),
              center.y >= player.world.info.minY,
              center.y < player.world.info.minY + player.world.info.height else { return .failure(.unloadedTarget(id)) }
        let draft = temporaryDraft(.decoy, player: player, authorization: authorization,
                                   sequence: sequence, center: center, radius: 3,
                                   duration: max(80, duration))
        var plan = RPGEffectPlan(result: .fixed(spell.displayName, blockPosition: center))
        plan.operations = [.registerTemporary(draft)]
        plan.feedback.append(feedback("enchant", point.x, point.y, point.z, 18, 1.2))
        result = .success(plan)

    case .shadowStep:
        let range = spell.rangeBlocks + rpgSkillEffectValue(.falseStep, in: state)
        guard let destination = shadowStepDestination(player, range: range) else {
            return .failure(.blockedPlacement(id))
        }
        var plan = RPGEffectPlan(result: .fixed(spell.displayName,
                                                blockPosition: RPGBlockPosition(ifloor(destination.x),
                                                                                ifloor(destination.y),
                                                                                ifloor(destination.z))))
        plan.operations = [.teleportOwner(RPGTeleportMutation(expectedX: player.x, expectedY: player.y,
                                                               expectedZ: player.z,
                                                               destinationX: destination.x,
                                                               destinationY: destination.y,
                                                               destinationZ: destination.z))]
        plan.feedback = [feedback("portal", player.x, player.y + 1, player.z, 24, 0.5),
                         feedback("portal", destination.x, destination.y + 1, destination.z, 24, 0.5)]
        result = .success(plan)

    case .mirrorImage:
        let absorption = rpgSkillEffectValue(.mirrorWork, in: state)
        var plan = RPGEffectPlan(result: .fixed(spell.displayName))
        plan.operations = [
            .addEffect(.owner, id: "invisibility", ticks: min(duration, 260), amplifier: 0),
            .addEffect(.owner, id: "speed", ticks: min(duration, 260), amplifier: 0),
            .setMinimumAbsorption(.owner, absorption),
        ]
        plan.feedback.append(feedback("enchant", player.x, player.y + 1, player.z, 30, 1.2))
        result = .success(plan)

    case .mageLight:
        guard let hit = blockRay(player, range: spell.rangeBlocks),
              let placement = temporaryLightPlacement(world: player.world, hit: hit) else {
            return .failure(.blockedPlacement(id))
        }
        let position = placement.position
        let old = player.world.getBlock(position.x, position.y, position.z)
        let guarded = RPGGuardedTemporaryBlock(position: position, originalCell: old,
                                               temporaryCell: placement.cell)
        let draft = temporaryDraft(.mageLight, player: player, authorization: authorization,
                                   sequence: sequence, center: position,
                                   duration: max(1, duration), guarded: guarded)
        var plan = RPGEffectPlan(result: .fixed(spell.displayName, blockPosition: position))
        plan.blockGuards = [RPGBlockGuard(position: position, cell: old)]
        plan.operations = [.setBlock(RPGBlockMutation(position: position, expectedCell: old, newCell: placement.cell)),
                           .registerTemporary(draft)]
        result = .success(plan)

    case .ward, .stoneWard:
        guard let hit = blockRay(player, range: spell.rangeBlocks),
              hit.cell != 0, blockDefs[hit.cell >> 4].hardness >= 0 else { return .failure(.noTarget(id)) }
        let center = RPGBlockPosition(hit.x, hit.y, hit.z)
        let wardRank = max(1, Int(rpgSkillEffectValue(.wardScribe, in: state)))
        let kind: RPGTemporaryEffectKind = effect == .ward ? .ward : .stoneWard
        let radius = effect == .ward ? 1.0 : max(1, spell.radiusBlocks)
        let draft = temporaryDraft(kind, player: player, authorization: authorization,
                                   sequence: sequence, center: center, radius: radius,
                                   duration: max(1, duration), charges: wardRank)
        var plan = RPGEffectPlan(result: .fixed(spell.displayName, blockPosition: center))
        plan.blockGuards = [RPGBlockGuard(position: center, cell: hit.cell)]
        plan.operations = [.registerTemporary(draft)]
        let mark = rpgSkillEffectValue(.protectiveMark, in: state)
        if mark > 0 { plan.operations.append(.setMinimumAbsorption(.owner, mark)) }
        result = .success(plan)

    case .summonServant:
        let point = pointInFront(player, distance: 2)
        let center = RPGBlockPosition(ifloor(point.x), ifloor(point.y), ifloor(point.z))
        guard player.world.isLoadedAt(center.x, center.z),
              entityAABBIsFree(world: player.world, x: point.x, y: point.y, z: point.z,
                               width: 0.35, height: 0.6, excluding: player) else {
            return .failure(.blockedPlacement(id))
        }
        let servantDuration = max(1, Int(rpgSkillEffectValue(.boundServant, in: state)))
        let draft = temporaryDraft(.servant, player: player, authorization: authorization,
                                   sequence: sequence, center: center, duration: servantDuration)
        let spawn = RPGSpawnAllayMutation(x: point.x, y: point.y, z: point.z,
                                          ownerEntityID: authorization.worldOwnerEntityID,
                                          temporaryDraft: draft)
        var plan = RPGEffectPlan(result: .fixed(spell.displayName, blockPosition: center))
        plan.operations = [.spawnAllay(spawn)]
        result = .success(plan)

    case .mendWounds, .restore, .purify, .aegis:
        let targetResult = touchedAllyOrSelf(player, range: spell.rangeBlocks, actionID: id)
        guard case .success(let targetKind) = targetResult else { return mapTargetFailure(targetResult) }
        let target = resolveTarget(targetKind, owner: player)!
        var plan = RPGEffectPlan(result: .fixed(spell.displayName,
                                                targetEntityID: targetKind == .owner ? player.id : target.id))
        if targetKind != .owner { plan.entityGuards = [.capture(target)] }
        switch effect {
        case .mendWounds, .restore:
            let base = effect == .mendWounds ? 5.0 : 8.0
            var heal = base + rpgSkillEffectValue(.fieldDressing, in: state) + potency
            if target.health < target.maxHealth / 2 {
                heal *= 1 + rpgSkillEffectValue(.triage, in: state)
            }
            let effective = max(0, min(heal, target.maxHealth - target.health))
            let restoreEffect = effect == .restore
                ? ["poison", "wither", "weakness", "slowness"].first(where: { target.hasEffect($0) })
                : nil
            guard effective > 0 || restoreEffect != nil else { return .failure(.noEffect(id)) }
            if effective > 0 { plan.operations.append(.heal(targetKind, heal)) }
            let injury = targetKind != .owner
                ? target.validRPGMenderInjury(at: player.world.rpgSimulationTick)
                : nil
            let causalHeal = min(effective, injury?.remaining ?? 0)
            let rescued = injury != nil
                && target.health <= target.maxHealth * 0.25
                && target.health + causalHeal > target.maxHealth * 0.25
            var cleansed = false
            if effect == .restore {
                if let first = restoreEffect {
                    plan.operations.append(.removeEffects(targetKind, ids: [first]))
                    cleansed = injury != nil
                }
            }
            // Restore may earn at most one fixed rescue/cleanse bonus even
            // when both predicates are true. Both require live hostile-injury
            // provenance; arbitrary or self-inflicted damage is ineligible.
            if rescued || cleansed, let injury {
                plan.xpEvents.append(RPGXPEvent(kind: .menderCleanseRescue,
                                               key: "support:\(target.id):\(injury.nonce)"))
            }
            if let injury, causalHeal >= 2 {
                plan.xpEvents.append(RPGXPEvent(kind: .menderEffectiveHealing,
                                               key: "heal:\(target.id):\(injury.nonce)",
                                               magnitude: Int(causalHeal.rounded(.down))))
            }
            if let injury, !plan.xpEvents.isEmpty {
                plan.menderInjuryClear = (targetKind, injury.nonce)
            }
        case .purify:
            let clear = ["poison", "hunger", "nausea"].filter { target.hasEffect($0) }
            guard !clear.isEmpty else { return .failure(.noEffect(id)) }
            plan.operations.append(.removeEffects(targetKind, ids: clear))
            if targetKind != .owner,
               let injury = target.validRPGMenderInjury(at: player.world.rpgSimulationTick) {
                plan.xpEvents.append(RPGXPEvent(kind: .menderCleanseRescue,
                                               key: "cleanse:\(target.id):\(injury.nonce)"))
                plan.menderInjuryClear = (targetKind, injury.nonce)
            }
        case .aegis:
            let absorption = 4 + rpgSkillEffectValue(.protectiveMark, in: state)
            plan.operations.append(.setMinimumAbsorption(targetKind, absorption))
            plan.operations.append(.addEffect(targetKind, id: "resistance", ticks: min(duration, 240), amplifier: 0))
        default: break
        }
        plan.feedback.append(feedback(effect == .aegis ? "totem" : "heart",
                                      target.x, target.y + target.height, target.z))
        result = .success(plan)

    case .sanctuary:
        let radius = max(1, rpgSkillEffectValue(.sanctuaryBell, in: state))
        let center = RPGBlockPosition(ifloor(player.x), ifloor(player.y), ifloor(player.z))
        let draft = temporaryDraft(.sanctuary, player: player, authorization: authorization,
                                   sequence: sequence, center: center, radius: radius,
                                   duration: max(40, duration))
        var plan = RPGEffectPlan(result: .fixed(spell.displayName, blockPosition: center))
        plan.operations = [.registerTemporary(draft)]
        result = .success(plan)
    }

    if case .success(var plan) = result,
       state.pathID == "arcanist",
       let index = RPG_SPELL_DEFINITIONS.firstIndex(where: { $0.id == id }) {
        plan.xpEvents.append(RPGXPEvent(kind: .arcanistSpellPractice,
                                       key: "cast:\(index):\(player.world.rpgSimulationTick)",
                                       registryIndex: index))
        return .success(plan)
    }
    return result
}

public let RPG_DAMAGE_SOURCE_WARDEN_MELEE = "rpg_warden_melee"
public let RPG_DAMAGE_SOURCE_RANGER_PROJECTILE = "rpg_ranger_projectile"
public let RPG_DAMAGE_SOURCE_ARCANIST_SPELL = "rpg_arcanist_spell"
public let RPG_DAMAGE_SOURCE_ARCANIST_FIRE = "rpg_arcanist_spell_fire"

private func mapTargetFailure<T>(_ result: Result<T, RPGActionFailure>) -> Result<RPGEffectPlan, RPGActionFailure> {
    switch result {
    case .success: return .failure(.staleMutation)
    case .failure(let failure): return .failure(failure)
    }
}

private func damagePlan(id: String, name: String, player: Player, target: LivingEntity,
                        damage: Double, source: String) -> RPGEffectPlan {
    var plan = RPGEffectPlan(result: .fixed(name, targetEntityID: target.id))
    plan.entityGuards = [.capture(target)]
    plan.operations = [.damage(.entity(target.id), damage, source: source)]
    plan.feedback = [feedback("crit", target.x, target.y + target.height * 0.6, target.z)]
    _ = id; _ = player
    return plan
}

private func blockRay(_ player: Player, range: Double) -> RaycastHit? {
    let look = lookVector(player)
    return player.world.raycast(player.x, player.eyeY(), player.z,
                                look.dx, look.dy, look.dz, range)
}

private func pointInFront(_ player: Player, distance: Double) -> (x: Double, y: Double, z: Double) {
    let look = lookVector(player)
    return (player.x + look.dx * distance, player.y, player.z + look.dz * distance)
}

private func targetPoint(_ player: Player, range: Double) -> (x: Double, y: Double, z: Double) {
    let look = lookVector(player)
    if let hit = blockRay(player, range: range) { return (hit.px, hit.py, hit.pz) }
    return (player.x + look.dx * range, player.eyeY() + look.dy * range, player.z + look.dz * range)
}

private func temporaryDraft(_ kind: RPGTemporaryEffectKind,
                            player: Player,
                            authorization: RPGActionAuthorization,
                            sequence: Int,
                            center: RPGBlockPosition,
                            radius: Double = 0,
                            duration: Int,
                            charges: Int = 0,
                            guarded: RPGGuardedTemporaryBlock? = nil,
                            magnitude: Double = 0) -> RPGTemporaryEffectDraft {
    RPGTemporaryEffectDraft(kind: kind, ownerAuthorityID: authorization.ownerAuthorityID,
                            ownerEntityID: authorization.worldOwnerEntityID,
                            ownerSequence: sequence, center: center, radius: radius,
                            durationTicks: duration, remainingCharges: charges,
                            guardedBlock: guarded, magnitude: magnitude)
}

private func nearestBlock(from player: Player, radius: Int,
                          matching predicate: (Int) -> Bool) -> (x: Int, y: Int, z: Int, id: Int)? {
    let bx = ifloor(player.x), by = ifloor(player.y), bz = ifloor(player.z)
    let y0 = max(player.world.info.minY, by - radius)
    let y1 = min(player.world.info.minY + player.world.info.height - 1, by + radius)
    guard y0 <= y1 else { return nil }
    var best: (x: Int, y: Int, z: Int, id: Int, distance: Int)?
    for y in y0...y1 {
        for z in (bz - radius)...(bz + radius) {
            for x in (bx - radius)...(bx + radius) {
                guard player.world.isLoadedAt(x, z) else { continue }
                let id = player.world.getBlock(x, y, z) >> 4
                guard predicate(id) else { continue }
                let dx = x - bx, dy = y - by, dz = z - bz
                let distance = dx * dx + dy * dy + dz * dz
                let tieWins = best.map {
                    y < $0.y || (y == $0.y && (z < $0.z || (z == $0.z && x < $0.x)))
                } ?? true
                if best == nil || distance < best!.distance || (distance == best!.distance && tieWins) {
                    best = (x, y, z, id, distance)
                }
            }
        }
    }
    return best.map { ($0.x, $0.y, $0.z, $0.id) }
}

private func isTrapBlockID(_ id: Int) -> Bool {
    let name = id >= 0 && id < blockDefs.count ? blockDefs[id].name : ""
    return id == Int(B.tripwire) || id == Int(B.tripwire_hook) || id == Int(B.dispenser)
        || id == Int(B.dropper) || id == Int(B.trapped_chest) || id == Int(B.tnt)
        || name.hasSuffix("_pressure_plate")
}

private func isContainerBlockID(_ id: Int) -> Bool {
    guard id >= 0, id < blockDefs.count else { return false }
    let name = blockDefs[id].name
    return name == "chest" || name == "trapped_chest" || name == "barrel"
        || name == "dispenser" || name == "dropper" || name.hasSuffix("shulker_box")
}

private func isRemoteTriggerBlockID(_ id: Int) -> Bool {
    guard id >= 0, id < blockDefs.count else { return false }
    let name = blockDefs[id].name
    return id == Int(B.lever) || id == Int(B.dispenser) || id == Int(B.dropper)
        || id == Int(B.repeater) || id == Int(B.repeater_on)
        || id == Int(B.comparator) || id == Int(B.comparator_on)
        || id == Int(B.daylight_detector) || id == Int(B.daylight_detector_inverted)
        || name.hasSuffix("_button")
}

private func deviceTriggerWouldChange(_ world: World, hit: RaycastHit) -> Bool {
    let id = hit.cell >> 4, meta = hit.cell & 15
    if id == Int(B.lever) { return true }
    if id == Int(B.dispenser) || id == Int(B.dropper) {
        return !world.hasScheduledTick(hit.x, hit.y, hit.z, id)
    }
    if id == Int(B.repeater) || id == Int(B.repeater_on)
        || id == Int(B.comparator) || id == Int(B.comparator_on)
        || id == Int(B.daylight_detector) || id == Int(B.daylight_detector_inverted) {
        return true
    }
    return blockDefs[id].name.hasSuffix("_button") && (meta & 8) == 0
}

private func commitRPGDeviceTrigger(_ world: World, player: Player,
                                    position: RPGBlockPosition, cell expectedCell: Int) {
    let id = expectedCell >> 4
    if id == Int(B.dispenser) || id == Int(B.dropper) {
        world.scheduleTick(position.x, position.y, position.z, id, 1)
        world.hooks.playSound("block.lever.click", Double(position.x) + 0.5,
                              Double(position.y) + 0.5, Double(position.z) + 0.5, 0.35, 1.2)
        return
    }
    let hit = RaycastHit(x: position.x, y: position.y, z: position.z,
                         face: 0, cell: expectedCell, t: 0,
                         px: Double(position.x) + 0.5,
                         py: Double(position.y) + 0.5,
                         pz: Double(position.z) + 0.5)
    _ = useBlock(InteractCtx(world: world, player: player), hit)
}

private func removingItem(named name: String, count: Int,
                          from snapshot: RPGPlayerItemsSnapshot,
                          creative: Bool) -> RPGPlayerItemsSnapshot? {
    if creative { return snapshot }
    guard let id = iidOpt(name) else { return nil }
    var next = snapshot.deepCopy()
    guard next.inventory.compactMap({ $0 }).filter({ $0.id == id }).reduce(0, { $0 + $1.count }) >= count else {
        return nil
    }
    var remaining = count
    for index in next.inventory.indices where remaining > 0 {
        guard let stack = next.inventory[index], stack.id == id else { continue }
        let take = min(stack.count, remaining)
        stack.count -= take
        remaining -= take
        if stack.count <= 0 { next.inventory[index] = nil }
    }
    return next
}

private func insertItem(_ stack: ItemStack, into inventory: inout [ItemStack?]) -> Bool {
    let remaining = stack.copy()
    for index in inventory.indices where remaining.count > 0 {
        guard let existing = inventory[index], canMerge(existing, remaining) else { continue }
        let take = min(max(0, maxStackOf(existing) - existing.count), remaining.count)
        existing.count += take; remaining.count -= take
    }
    while remaining.count > 0 {
        guard let empty = inventory.firstIndex(where: { $0 == nil }) else { return false }
        let placed = remaining.copy()
        placed.count = min(maxStackOf(placed), remaining.count)
        remaining.count -= placed.count
        inventory[empty] = placed
    }
    return true
}

private struct RPGRepairPlan {
    var items: RPGPlayerItemsSnapshot
    var message: String
}

private enum RPGRepairSlot {
    case inventory(Int), offHand, armor(Int)
}

private func plannedQuickRepair(player: Player, state: RPGCharacterState,
                                items: RPGPlayerItemsSnapshot) -> RPGRepairPlan? {
    var candidates: [(String, RPGRepairSlot, ItemStack)] = []
    if items.selectedSlot >= 0, items.selectedSlot < items.inventory.count,
       let stack = items.inventory[items.selectedSlot] {
        candidates.append(("Held", .inventory(items.selectedSlot), stack))
    }
    if let stack = items.offHand { candidates.append(("Offhand", .offHand, stack)) }
    for index in items.armor.indices { if let stack = items.armor[index] { candidates.append(("Armor \(index + 1)", .armor(index), stack)) } }
    for index in items.inventory.indices where index != items.selectedSlot {
        if let stack = items.inventory[index] { candidates.append(("Slot \(index + 1)", .inventory(index), stack)) }
    }
    for (label, slot, stack) in candidates {
        let maxDamage = maxDamageOf(stack)
        guard maxDamage > 0, stack.damage > 0,
              let materialIDs = repairMaterialIDs(for: stack) else { continue }
        var next = items.deepCopy()
        if player.gameMode != GameMode.creative {
            guard let materialSlot = next.inventory.indices.first(where: { index in
                next.inventory[index].map { materialIDs.contains($0.id) && $0.count > 0 } ?? false
            }), let material = next.inventory[materialSlot] else { continue }
            material.count -= 1
            if material.count <= 0 { next.inventory[materialSlot] = nil }
        }
        let fraction = rpgSkillEffectValue(.quickRepair, in: state)
        let repair = max(1, Int((Double(maxDamage) * fraction).rounded(.up)))
        let target: ItemStack?
        switch slot {
        case .inventory(let index): target = next.inventory[index]
        case .offHand: target = next.offHand
        case .armor(let index): target = next.armor[index]
        }
        target?.damage = max(0, (target?.damage ?? 0) - repair)
        return RPGRepairPlan(items: next, message: "Quick Repair \(label)")
    }
    return nil
}

private func repairMaterialIDs(for stack: ItemStack) -> Set<Int>? {
    let definition = itemDef(stack.id)
    let name = definition.name
    func ids(_ names: [String]) -> Set<Int> { Set(names.compactMap(iidOpt)) }
    if name.hasPrefix("wooden_") { return Set(itemDefs.filter { $0.name.hasSuffix("_planks") }.map(\.id)) }
    if name.hasPrefix("stone_") { return ids(["cobblestone", "cobbled_deepslate", "blackstone"]) }
    if name.hasPrefix("copper_") { return ids(["copper_ingot"]) }
    if name.hasPrefix("iron_") || name.hasPrefix("chainmail_") || ["shears", "flint_and_steel"].contains(name) { return ids(["iron_ingot"]) }
    if name.hasPrefix("golden_") { return ids(["gold_ingot"]) }
    if name.hasPrefix("diamond_") { return ids(["diamond"]) }
    if name.hasPrefix("netherite_") { return ids(["netherite_ingot"]) }
    if name.hasPrefix("leather_") { return ids(["leather"]) }
    if name == "turtle_helmet" { return ids(["scute"]) }
    if name == "elytra" { return ids(["phantom_membrane"]) }
    if ["bow", "crossbow", "fishing_rod"].contains(name) { return ids(["string"]) }
    if name == "trident" { return ids(["prismarine_shard"]) }
    return nil
}

private func nearestWetHostile(from target: LivingEntity, excluding: [Int], radius: Double) -> LivingEntity? {
    let excluded = Set(excluding)
    return target.world.getEntitiesNear(target.x, target.y, target.z, radius)
        .compactMap { $0 as? LivingEntity }
        .filter { !excluded.contains($0.id) && rpgIsHostileTarget($0)
            && ($0.inWater || $0.world.isRainingAt(ifloor($0.x), ifloor($0.y), ifloor($0.z)))
            && canReceiveRPGDamage($0, source: RPG_DAMAGE_SOURCE_ARCANIST_SPELL) }
        .sorted {
            let ad = target.distanceToSq($0), bd = target.distanceToSq($1)
            return ad == bd ? $0.id < $1.id : ad < bd
        }.first
}

private func entityAABBIsFree(world: World, x: Double, y: Double, z: Double,
                              width: Double, height: Double, excluding: Entity?) -> Bool {
    let half = width / 2
    let box = AABB(x - half, y, z - half, x + half, y + height, z + half)
    var collision = false
    world.forEachCollisionBox(box) { if $0.intersects(box) { collision = true } }
    if collision { return false }
    return world.getEntitiesInBox(box, except: excluding).isEmpty
}

private func shadowStepDestination(_ player: Player, range: Double) -> (x: Double, y: Double, z: Double)? {
    guard let hit = blockRay(player, range: range) else { return nil }
    let adjacent = adjacentPosition(hit)
    let feet = RPGBlockPosition(adjacent.x, adjacent.y, adjacent.z)
    guard player.world.isLoadedAt(feet.x, feet.z),
          feet.y > player.world.info.minY,
          feet.y + 2 < player.world.info.minY + player.world.info.height,
          player.world.lightAt(feet.x, feet.y, feet.z) <= 7 else { return nil }
    let below = player.world.getBlock(feet.x, feet.y - 1, feet.z) >> 4
    guard below > 0, below < blockDefs.count, blockDefs[below].solid else { return nil }
    let x = Double(feet.x) + 0.5, y = Double(feet.y), z = Double(feet.z) + 0.5
    return entityAABBIsFree(world: player.world, x: x, y: y, z: z,
                            width: player.width, height: PLAYER_HEIGHT, excluding: player) ? (x, y, z) : nil
}

private func shadowStepDestinationIsValid(_ player: Player, mutation: RPGTeleportMutation) -> Bool {
    guard player.x == mutation.expectedX, player.y == mutation.expectedY, player.z == mutation.expectedZ else {
        return false
    }
    let world = player.world
    let feet = RPGBlockPosition(ifloor(mutation.destinationX), ifloor(mutation.destinationY),
                                ifloor(mutation.destinationZ))
    guard world.isLoadedAt(feet.x, feet.z),
          feet.y > world.info.minY,
          feet.y + 2 < world.info.minY + world.info.height,
          world.lightAt(feet.x, feet.y, feet.z) <= 7 else { return false }
    let below = world.getBlock(feet.x, feet.y - 1, feet.z) >> 4
    guard below > 0, below < blockDefs.count, blockDefs[below].solid else { return false }
    let feetID = world.getBlock(feet.x, feet.y, feet.z) >> 4
    let headID = world.getBlock(feet.x, feet.y + 1, feet.z) >> 4
    guard (feetID == 0 || blockDefs[feetID].replaceable),
          (headID == 0 || blockDefs[headID].replaceable) else { return false }
    let dx = mutation.destinationX - player.x
    let dy = mutation.destinationY + player.height * 0.5 - player.eyeY()
    let dz = mutation.destinationZ - player.z
    let distance = detHyp(detHyp(dx, dz), dy)
    if distance > 0.001,
       let hit = world.raycast(player.x, player.eyeY(), player.z,
                               dx / distance, dy / distance, dz / distance, distance),
       hit.t + 0.05 < distance {
        return false
    }
    return entityAABBIsFree(world: world, x: mutation.destinationX, y: mutation.destinationY,
                            z: mutation.destinationZ, width: player.width,
                            height: PLAYER_HEIGHT, excluding: player)
}

private func temporaryLightPlacement(world: World, hit: RaycastHit) -> (position: RPGBlockPosition, cell: Int)? {
    let position = adjacentPosition(hit)
    guard isReplaceable(world, position) else { return nil }
    let support = hit.cell >> 4
    guard support > 0, support < blockDefs.count, blockDefs[support].fullCube else { return nil }
    // Mage Light uses the shipped upright torch cell even beside a support; it
    // is a magical temporary light, and Elysium has no wall_torch registry entry.
    return (position, Int(cell(B.torch)))
}

public func rpgTickPlayerUpkeepEffects(_ player: Player) {
    guard player.rpg.created, player.world.rule(RPG_CLASSES_GAME_RULE),
          player.world.rpgSimulationTick % 20 == 0 else { return }
    for upkeep in player.rpg.activeUpkeeps {
        switch upkeep.spellID {
        case RPGSpellEffectID.stormAura.rawValue:
            let damage = max(1.5, rpgSkillEffectValue(.stormFocus, in: player.rpg))
            for target in sortedLivingNear(player, radius: 4, predicate: rpgIsHostileTarget).prefix(32) {
                if canReceiveRPGDamage(target, source: RPG_DAMAGE_SOURCE_ARCANIST_SPELL) {
                    _ = target.hurt(damage, RPG_DAMAGE_SOURCE_ARCANIST_SPELL, player)
                }
            }
        case RPGSpellEffectID.blur.rawValue:
            player.addEffect("invisibility", 40, 0)
        case RPGSpellEffectID.mirrorImage.rawValue:
            player.addEffect("invisibility", 40, 0)
            player.addEffect("speed", 40, 0)
        default: break
        }
    }
}
