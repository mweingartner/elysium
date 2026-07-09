import Foundation

public enum RPGActionFailure: Error, Equatable, CustomStringConvertible {
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
    case blockedPlacement(String)
    case missingMaterial(String)
    case noRepairTarget

    public var description: String {
        switch self {
        case .characterNotCreated: return "Character has not been created"
        case .actionNotPrepared: return "No prepared action"
        case .unknownSkill(let id): return "Unknown skill: \(id)"
        case .unknownSpell(let id): return "Unknown spell: \(id)"
        case .skillNotPrepared(let id): return "Skill is not prepared: \(id)"
        case .spellNotPrepared(let id): return "Spell is not prepared: \(id)"
        case .skillNotActive(let id): return "Skill is passive: \(id)"
        case .insufficientIntelligence(let value): return "Requires IQ \(value)"
        case .insufficientFatigue(let required, let available):
            return "Requires \(Int(required.rounded(.up))) fatigue; \(Int(available.rounded(.down))) available"
        case .skillOnCooldown(let id): return "Skill is on cooldown: \(id)"
        case .spellOnCooldown(let id): return "Spell is on cooldown: \(id)"
        case .noTarget(let id): return "No target for \(id)"
        case .blockedPlacement(let id): return "Blocked placement for \(id)"
        case .missingMaterial(let id): return "Missing material for \(id)"
        case .noRepairTarget: return "No damaged gear to repair"
        }
    }
}

public struct RPGBlockPosition: Codable, Equatable {
    public var x: Int
    public var y: Int
    public var z: Int

    public init(_ x: Int, _ y: Int, _ z: Int) {
        self.x = x
        self.y = y
        self.z = z
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

public func rpgCyclePreparedAction(_ player: Player, direction: Int = 1) -> RPGPreparedAction? {
    player.rpg = repairRPGCharacterState(player.rpg)
    let prepared = rpgPreparedActions(player.rpg)
    guard !prepared.isEmpty else {
        player.rpg.selectedPreparedActionID = nil
        return nil
    }
    let currentToken = player.rpg.selectedPreparedActionID
        ?? player.rpg.selectedPreparedSpellID.map { rpgPreparedActionToken(kind: .spell, id: $0) }
    let currentIndex = currentToken.flatMap { token in prepared.firstIndex(where: { $0.token == token }) } ?? 0
    let next = (currentIndex + direction + prepared.count) % prepared.count
    let selected = prepared[next]
    player.rpg.selectedPreparedActionID = selected.token
    if selected.kind == .spell { player.rpg.selectedPreparedSpellID = selected.id }
    return selected
}

public func rpgCyclePreparedSpell(_ player: Player, direction: Int = 1) -> String? {
    player.rpg = repairRPGCharacterState(player.rpg)
    let prepared = player.rpg.preparedSpellIDs
    guard !prepared.isEmpty else {
        player.rpg.selectedPreparedSpellID = nil
        return nil
    }
    let currentIndex = player.rpg.selectedPreparedSpellID.flatMap { prepared.firstIndex(of: $0) } ?? 0
    let next = (currentIndex + direction + prepared.count) % prepared.count
    player.rpg.selectedPreparedSpellID = prepared[next]
    player.rpg.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: prepared[next])
    return prepared[next]
}

public func rpgUseSelectedPreparedAction(_ player: Player) -> Result<RPGActionResult, RPGActionFailure> {
    player.rpg = repairRPGCharacterState(player.rpg)
    guard let action = rpgSelectedPreparedAction(player.rpg) else {
        return .failure(.actionNotPrepared)
    }
    switch action.kind {
    case .skill:
        return rpgUsePreparedSkill(player, skillID: action.id)
    case .spell:
        return rpgCastPreparedSpell(player, spellID: action.id)
    }
}

public func rpgUseActionQuickSlot(_ player: Player, slot: Int) -> Result<RPGActionResult, RPGActionFailure> {
    player.rpg = repairRPGCharacterState(player.rpg)
    guard slot >= 0 && slot < RPG_ACTION_QUICK_SLOT_COUNT else {
        return .failure(.actionNotPrepared)
    }
    let slots = rpgActionQuickSlotActions(player.rpg)
    guard slot < slots.count, let action = slots[slot] else {
        return .failure(.actionNotPrepared)
    }
    player.rpg.selectedPreparedActionID = action.token
    if action.kind == .spell {
        player.rpg.selectedPreparedSpellID = action.id
    }
    switch action.kind {
    case .skill:
        return rpgUsePreparedSkill(player, skillID: action.id)
    case .spell:
        return rpgCastPreparedSpell(player, spellID: action.id)
    }
}

public func rpgCastSelectedPreparedSpell(_ player: Player) -> Result<RPGActionResult, RPGActionFailure> {
    player.rpg = repairRPGCharacterState(player.rpg)
    guard let spellID = player.rpg.selectedPreparedSpellID ?? player.rpg.preparedSpellIDs.first else {
        return .failure(.spellNotPrepared(""))
    }
    return rpgCastPreparedSpell(player, spellID: spellID)
}

public func rpgCastPreparedSpell(_ player: Player, spellID: String) -> Result<RPGActionResult, RPGActionFailure> {
    player.rpg = repairRPGCharacterState(player.rpg)
    guard player.rpg.created else { return .failure(.characterNotCreated) }
    guard let spell = rpgSpellDefinition(spellID) else { return .failure(.unknownSpell(spellID)) }
    guard player.rpg.preparedSpellIDs.contains(spellID) else { return .failure(.spellNotPrepared(spellID)) }
    guard player.rpg.attributes.intelligence >= spell.minimumIntelligence else {
        return .failure(.insufficientIntelligence(required: spell.minimumIntelligence))
    }
    if player.rpg.activeCooldowns.contains(where: { $0.id == spellID && $0.remainingTicks > 0 }) {
        return .failure(.spellOnCooldown(spellID))
    }
    guard player.rpg.fatigue >= spell.fatigueCost else {
        return .failure(.insufficientFatigue(required: spell.fatigueCost, available: player.rpg.fatigue))
    }

    let dryRun = applyRPGSpell(player, spell, dryRun: true)
    if case .failure(let failure) = dryRun { return .failure(failure) }

    player.rpg.fatigue = max(0, player.rpg.fatigue - spell.fatigueCost)
    player.rpg.actionSequence += 1
    player.rpg.selectedPreparedSpellID = spellID
    player.rpg.selectedPreparedActionID = rpgPreparedActionToken(kind: .spell, id: spellID)
    player.rpg.activeCooldowns.append(RPGCooldown(id: spellID, remainingTicks: max(10, spell.circle * 20)))
    if spell.upkeepCostPerSecond > 0 && spell.durationTicks > 0 {
        player.rpg.activeUpkeeps.removeAll { $0.spellID == spellID }
        player.rpg.activeUpkeeps.append(RPGUpkeep(
            spellID: spellID,
            ownerSequence: player.rpg.actionSequence,
            remainingTicks: spell.durationTicks,
            costPerSecond: spell.upkeepCostPerSecond
        ))
    }
    player.rpg = repairRPGCharacterState(player.rpg)
    return applyRPGSpell(player, spell, dryRun: false)
}

public func rpgUsePreparedSkill(_ player: Player, skillID: String) -> Result<RPGActionResult, RPGActionFailure> {
    player.rpg = repairRPGCharacterState(player.rpg)
    guard player.rpg.created else { return .failure(.characterNotCreated) }
    guard let skill = rpgSkillDefinition(skillID) else { return .failure(.unknownSkill(skillID)) }
    guard skill.kind == .active else { return .failure(.skillNotActive(skillID)) }
    guard (player.rpg.skillRanks[skillID] ?? 0) > 0, player.rpg.preparedSkillIDs.contains(skillID) else {
        return .failure(.skillNotPrepared(skillID))
    }
    if player.rpg.activeCooldowns.contains(where: { $0.id == skillID && $0.remainingTicks > 0 }) {
        return .failure(.skillOnCooldown(skillID))
    }
    guard player.rpg.fatigue >= skill.fatigueCost else {
        return .failure(.insufficientFatigue(required: skill.fatigueCost, available: player.rpg.fatigue))
    }

    let dryRun = applyRPGSkill(player, skill, dryRun: true)
    if case .failure(let failure) = dryRun { return .failure(failure) }

    player.rpg.fatigue = max(0, player.rpg.fatigue - skill.fatigueCost)
    player.rpg.actionSequence += 1
    player.rpg.selectedPreparedActionID = rpgPreparedActionToken(kind: .skill, id: skillID)
    player.rpg.activeCooldowns.append(RPGCooldown(id: skillID, remainingTicks: max(10, skill.cooldownTicks)))
    player.rpg = repairRPGCharacterState(player.rpg)
    return applyRPGSkill(player, skill, dryRun: false)
}

private func applyRPGSpell(_ player: Player, _ spell: RPGSpellDefinition,
                           dryRun: Bool) -> Result<RPGActionResult, RPGActionFailure> {
    switch spell.id {
    case "ignite":
        return castDamageRay(player, spell, damage: 4, effect: { target in
            target.fireTicks = max(target.fireTicks, 120)
        }, blockEffect: { world, hit in
            let pos = adjacentPosition(hit)
            guard canReplace(world, pos.x, pos.y, pos.z) else { return false }
            if !dryRun { world.setBlock(pos.x, pos.y, pos.z, Int(cell(B.fire))) }
            return true
        }, dryRun: dryRun)
    case "frost_ray":
        return castDamageRay(player, spell, damage: 3, effect: { target in
            target.addEffect("slowness", 120, 1)
            target.freezeTicks = max(target.freezeTicks, 160)
        }, dryRun: dryRun)
    case "shock":
        return castDamageRay(player, spell, damage: 5, effect: { target in
            if target.inWater || target.world.isRainingAt(ifloor(target.x), ifloor(target.y), ifloor(target.z)) {
                for e in nearestLivingEntities(from: target, radius: 4, excluding: [player.id, target.id]).prefix(1) {
                    e.hurt(3, "magic", player)
                }
            }
        }, dryRun: dryRun)
    case "storm_aura":
        if !dryRun { player.addEffect("resistance", min(spell.durationTicks, 300), 0) }
        return actionResult(player, spell, "Storm aura")
    case "blur":
        if !dryRun { player.addEffect("invisibility", min(spell.durationTicks, 260), 0) }
        return actionResult(player, spell, "Blur")
    case "decoy":
        let pos = targetPoint(player, range: spell.rangeBlocks)
        if !dryRun {
            let cloud = AreaEffectCloud(world: player.world)
            cloud.setPos(pos.x, pos.y, pos.z)
            cloud.radius = 3
            cloud.duration = max(80, spell.durationTicks)
            cloud.effectId = "glowing"
            cloud.amplifier = 0
            cloud.particleType = "enchant"
            player.world.addEntity(cloud)
        }
        return .success(RPGActionResult(actionID: spell.id, sequence: player.rpg.actionSequence,
                                        message: "Decoy",
                                        blockPosition: RPGBlockPosition(ifloor(pos.x), ifloor(pos.y), ifloor(pos.z))))
    case "shadow_step":
        let destination = shadowStepDestination(player, range: spell.rangeBlocks)
        guard let destination else { return .failure(.noTarget(spell.id)) }
        if !dryRun {
            player.world.hooks.addParticles("portal", player.x, player.y + 1, player.z, 24, 0.5, 0)
            player.setPos(destination.x, destination.y, destination.z)
            player.vx = 0; player.vy = 0; player.vz = 0
            player.fallDistance = 0
            player.world.hooks.addParticles("portal", player.x, player.y + 1, player.z, 24, 0.5, 0)
        }
        return .success(RPGActionResult(actionID: spell.id, sequence: player.rpg.actionSequence,
                                        message: "Shadow Step",
                                        blockPosition: RPGBlockPosition(ifloor(destination.x), ifloor(destination.y), ifloor(destination.z))))
    case "mirror_image":
        if !dryRun {
            player.addEffect("invisibility", min(spell.durationTicks, 260), 0)
            player.addEffect("speed", min(spell.durationTicks, 200), 0)
            player.world.hooks.addParticles("enchant", player.x, player.y + 1, player.z, 30, 1.2, 0)
        }
        return actionResult(player, spell, "Mirror Image")
    case "mage_light":
        guard let hit = player.world.raycast(player.x, player.eyeY(), player.z, lookVector(player).dx,
                                             lookVector(player).dy, lookVector(player).dz, spell.rangeBlocks) else {
            return .failure(.noTarget(spell.id))
        }
        let pos = adjacentPosition(hit)
        guard canReplace(player.world, pos.x, pos.y, pos.z) else { return .failure(.blockedPlacement(spell.id)) }
        if !dryRun {
            player.world.setBlock(pos.x, pos.y, pos.z, Int(cell(B.torch)))
            player.world.hooks.addParticles("glow", Double(pos.x) + 0.5, Double(pos.y) + 0.5, Double(pos.z) + 0.5, 12, 0.3, 0)
        }
        return .success(RPGActionResult(actionID: spell.id, sequence: player.rpg.actionSequence,
                                        message: "Mage Light", blockPosition: pos))
    case "ward", "stone_ward":
        return castWard(player, spell, dryRun: dryRun)
    case "summon_servant":
        if !dryRun {
            let allay = Allay(world: player.world)
            let p = pointInFront(player, distance: 2)
            allay.setPos(p.x, p.y, p.z)
            allay.persistent = false
            player.world.addEntity(allay)
            player.world.hooks.addParticles("happy_villager", allay.x, allay.y + 1, allay.z, 12, 0.4, 0)
        }
        return actionResult(player, spell, "Summon Servant")
    case "mend_wounds":
        return castHeal(player, spell, heal: 5, clearEffects: [], dryRun: dryRun)
    case "restore":
        return castHeal(player, spell, heal: 8, clearEffects: ["poison", "wither", "weakness", "slowness"], dryRun: dryRun)
    case "purify":
        return castHeal(player, spell, heal: 0, clearEffects: ["poison", "hunger", "nausea"], dryRun: dryRun)
    case "aegis":
        if !dryRun {
            player.absorption = max(player.absorption, 4)
            player.addEffect("resistance", min(spell.durationTicks, 240), 0)
        }
        return actionResult(player, spell, "Aegis")
    case "sanctuary":
        if !dryRun {
            for e in nearestLivingEntities(from: player, radius: spell.radiusBlocks, excluding: [player.id]) {
                if e is Monster {
                    e.addEffect("slowness", min(spell.durationTicks, 160), 2)
                    e.addEffect("glowing", min(spell.durationTicks, 160), 0)
                    let dx = e.x - player.x
                    let dz = e.z - player.z
                    let d = max(0.001, (dx * dx + dz * dz).squareRoot())
                    e.vx += dx / d * 0.5
                    e.vz += dz / d * 0.5
                }
            }
            player.world.hooks.addParticles("totem", player.x, player.y + 1, player.z, 32, spell.radiusBlocks / 2, 0)
        }
        return actionResult(player, spell, "Sanctuary")
    default:
        return .failure(.unknownSpell(spell.id))
    }
}

private func applyRPGSkill(_ player: Player, _ skill: RPGSkillDefinition,
                           dryRun: Bool) -> Result<RPGActionResult, RPGActionFailure> {
    let rank = max(1, player.rpg.skillRanks[skill.id] ?? 1)
    switch skill.id {
    case "interpose":
        if !dryRun {
            player.absorption = max(player.absorption, Double(3 + rank))
            player.addEffect("resistance", 120 + rank * 40, 0)
            for ally in nearestLivingEntities(from: player, radius: 5, excluding: [player.id]).prefix(3) where !(ally is Monster) {
                ally.addEffect("resistance", 100 + rank * 30, 0)
            }
            player.world.hooks.addParticles("totem", player.x, player.y + 1, player.z, 18, 1.4, 0)
        }
        return actionResult(player, skill, "Interpose")
    case "anchor_line":
        if !dryRun {
            player.addEffect("resistance", 180, 0)
            if let target = livingEntityInLook(player, range: 6)?.entity {
                let dx = player.x - target.x
                let dz = player.z - target.z
                let d = max(0.001, (dx * dx + dz * dz).squareRoot())
                target.vx += dx / d * 0.45
                target.vz += dz / d * 0.45
                target.addEffect("slowness", 80, 0)
                player.world.hooks.addParticles("crit", target.x, target.y + target.height * 0.5, target.z, 10, 0.35, 0)
                return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                                message: skill.displayName, targetEntityID: target.id))
            }
            player.world.hooks.addParticles("crit", player.x, player.y + 1, player.z, 12, 0.8, 0)
        }
        return actionResult(player, skill, "Anchor Line")
    case "heavy_cut":
        return castSkillDamageRay(player, skill, range: 4.5,
                                  damage: 5 + Double(rank) + Double(max(0, player.rpg.attributes.strength - 10)) * 0.35,
                                  effect: { target in
                                      target.addEffect("slowness", 60 + rank * 20, 0)
                                  },
                                  dryRun: dryRun)
    case "charge_break":
        if !dryRun {
            let look = lookVector(player)
            player.vx += look.dx * 0.65
            player.vz += look.dz * 0.65
            if let target = livingEntityInLook(player, range: 5)?.entity {
                _ = target.hurt(4 + Double(rank), "player", player)
                target.addEffect("weakness", 80, 0)
                target.vx += look.dx * 0.45
                target.vz += look.dz * 0.45
                return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                                message: skill.displayName, targetEntityID: target.id))
            }
            player.world.hooks.addParticles("cloud", player.x, player.y + 0.2, player.z, 12, 0.5, 0)
        }
        return actionResult(player, skill, "Charge Break")
    case "fortify_block":
        guard let hit = player.world.raycast(player.x, player.eyeY(), player.z, lookVector(player).dx,
                                             lookVector(player).dy, lookVector(player).dz, 5) else {
            return .failure(.noTarget(skill.id))
        }
        guard blockDefs[hit.cell >> 4].hardness >= 0 else { return .failure(.blockedPlacement(skill.id)) }
        if !dryRun {
            player.addEffect("resistance", 160, 0)
            player.world.hooks.addParticles("enchant", Double(hit.x) + 0.5, Double(hit.y) + 0.5, Double(hit.z) + 0.5, 18, 0.55, 0)
        }
        return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                        message: skill.displayName,
                                        blockPosition: RPGBlockPosition(hit.x, hit.y, hit.z)))
    case "crippling_shot":
        return castSkillDamageRay(player, skill, range: 18, damage: 4 + Double(rank), effect: { target in
            target.addEffect("slowness", 160, 1)
            target.addEffect("weakness", 100, 0)
        }, dryRun: dryRun)
    case "far_sight":
        if !dryRun {
            player.addEffect("night_vision", 600, 0)
            for target in nearestLivingEntities(from: player, radius: 24, excluding: [player.id]).prefix(8) {
                target.addEffect("glowing", 220, 0)
            }
            player.world.hooks.addParticles("glow", player.x, player.eyeY(), player.z, 18, 1.1, 0)
        }
        return actionResult(player, skill, "Far Sight")
    case "fast_bore":
        if !dryRun {
            player.addEffect("haste", 220 + rank * 60, max(0, rank - 1))
            player.world.hooks.addParticles("block", player.x, player.y + 0.4, player.z, 14, 0.6, Int(cell(B.stone)))
        }
        return actionResult(player, skill, "Fast Bore")
    case "trap_probe":
        guard let found = nearestBlock(from: player, radius: 8, matching: isTrapBlockID) else {
            return .failure(.noTarget(skill.id))
        }
        if !dryRun {
            player.world.hooks.addParticles("redstone", Double(found.x) + 0.5, Double(found.y) + 0.5, Double(found.z) + 0.5, 14, 0.35, 0)
        }
        return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                        message: skill.displayName,
                                        blockPosition: RPGBlockPosition(found.x, found.y, found.z)))
    case "deadfall":
        guard let hit = player.world.raycast(player.x, player.eyeY(), player.z, lookVector(player).dx,
                                             lookVector(player).dy, lookVector(player).dz, 6) else {
            return .failure(.noTarget(skill.id))
        }
        let pos = adjacentPosition(hit)
        guard canReplace(player.world, pos.x, pos.y, pos.z) else { return .failure(.blockedPlacement(skill.id)) }
        if !dryRun {
            player.world.setBlock(pos.x, pos.y, pos.z, Int(cell(B.gravel)))
            player.world.scheduleTick(pos.x, pos.y, pos.z, Int(B.gravel), 2)
            player.world.hooks.addParticles("block", Double(pos.x) + 0.5, Double(pos.y) + 0.5, Double(pos.z) + 0.5, 10, 0.35, Int(cell(B.gravel)))
        }
        return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                        message: skill.displayName,
                                        blockPosition: pos))
    case "lock_touch":
        return inspectContainer(player, skill: skill, effect: "glowing", dryRun: dryRun)
    case "fortune_read":
        return inspectContainer(player, skill: skill, effect: "luck", dryRun: dryRun)
    case "second_breath":
        if !dryRun {
            player.heal(8 + Double(rank) * 2)
            player.addEffect("regeneration", 120, 0)
            player.world.hooks.addParticles("heart", player.x, player.y + player.height, player.z, 12, 0.5, 0)
        }
        return actionResult(player, skill, "Second Breath")
    case "safe_haven":
        if !dryRun {
            let cloud = AreaEffectCloud(world: player.world)
            cloud.setPos(player.x, player.y, player.z)
            cloud.radius = 4
            cloud.duration = 260
            cloud.effectId = "regeneration"
            cloud.amplifier = 0
            cloud.particleType = "happy_villager"
            player.world.addEntity(cloud)
            player.addEffect("regeneration", 120, 0)
            player.world.hooks.addParticles("happy_villager", player.x, player.y + 0.5, player.z, 18, 1.5, 0)
        }
        return actionResult(player, skill, "Safe Haven")
    case "remote_trigger":
        return triggerRedstone(player, skill: skill, dryRun: dryRun)
    case "field_mod":
        if !dryRun {
            player.addEffect("haste", 260 + rank * 40, max(0, rank - 1))
            player.addEffect("speed", 160, 0)
            player.world.hooks.addParticles("enchant", player.x, player.y + 1, player.z, 12, 0.6, 0)
        }
        return actionResult(player, skill, "Field Mod")
    case "quick_repair":
        guard let repaired = repairFirstDamagedGear(player, dryRun: dryRun) else {
            return .failure(.noRepairTarget)
        }
        return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                        message: repaired))
    case "charge_pack":
        guard let hit = player.world.raycast(player.x, player.eyeY(), player.z, lookVector(player).dx,
                                             lookVector(player).dy, lookVector(player).dz, 6) else {
            return .failure(.noTarget(skill.id))
        }
        let pos = adjacentPosition(hit)
        guard canReplace(player.world, pos.x, pos.y, pos.z) else { return .failure(.blockedPlacement(skill.id)) }
        guard let tntItem = iidOpt("tnt") else { return .failure(.missingMaterial(skill.id)) }
        guard player.gameMode == GameMode.creative || player.countItem(tntItem) > 0 else {
            return .failure(.missingMaterial(skill.id))
        }
        if !dryRun {
            if player.gameMode != GameMode.creative { _ = player.removeItems(tntItem, 1) }
            player.world.setBlock(pos.x, pos.y, pos.z, Int(cell(B.tnt)))
            player.world.hooks.addParticles("smoke", Double(pos.x) + 0.5, Double(pos.y) + 0.5, Double(pos.z) + 0.5, 10, 0.35, 0)
        }
        return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                        message: skill.displayName,
                                        blockPosition: pos))
    case "safe_fuse":
        guard let found = targetOrNearestTNT(player) else { return .failure(.noTarget(skill.id)) }
        if !dryRun {
            player.world.setBlock(found.x, found.y, found.z, 0)
            if player.gameMode != GameMode.creative, let tntItem = iidOpt("tnt") {
                _ = player.give(ItemStack(tntItem, 1))
            }
            player.world.hooks.addParticles("smoke", Double(found.x) + 0.5, Double(found.y) + 0.5, Double(found.z) + 0.5, 12, 0.35, 0)
        }
        return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                        message: skill.displayName,
                                        blockPosition: RPGBlockPosition(found.x, found.y, found.z)))
    default:
        return .failure(.unknownSkill(skill.id))
    }
}

public func rpgTickPlayerUpkeepEffects(_ player: Player) {
    guard player.rpg.created else { return }
    for upkeep in player.rpg.activeUpkeeps {
        guard player.age % 20 == 0 else { continue }
        switch upkeep.spellID {
        case "storm_aura":
            for e in nearestLivingEntities(from: player, radius: 4, excluding: [player.id]) where e is Monster {
                e.hurt(2, "magic", player)
            }
            player.world.hooks.addParticles("crit", player.x, player.y + 1, player.z, 8, 2, 0)
        case "blur":
            player.addEffect("invisibility", 40, 0)
        case "mirror_image":
            player.addEffect("speed", 40, 0)
        case "aegis":
            player.absorption = max(player.absorption, 2)
        default:
            break
        }
    }
}

private func castDamageRay(_ player: Player, _ spell: RPGSpellDefinition, damage: Double,
                           effect: (LivingEntity) -> Void,
                           blockEffect: ((World, RaycastHit) -> Bool)? = nil,
                           dryRun: Bool) -> Result<RPGActionResult, RPGActionFailure> {
    let look = lookVector(player)
    let blockHit = player.world.raycast(player.x, player.eyeY(), player.z, look.dx, look.dy, look.dz, spell.rangeBlocks)
    let entityHit = livingEntityInLook(player, range: spell.rangeBlocks)
    if let entityHit, blockHit == nil || entityHit.t <= blockHit!.t {
        if !dryRun {
            _ = entityHit.entity.hurt(damage + rpgDerivedStats(player.rpg).spellFailureMitigation * 4, "magic", player)
            effect(entityHit.entity)
            player.world.hooks.addParticles("crit", entityHit.entity.x, entityHit.entity.y + entityHit.entity.height * 0.6, entityHit.entity.z, 12, 0.4, 0)
        }
        return .success(RPGActionResult(actionID: spell.id, sequence: player.rpg.actionSequence,
                                        message: spell.displayName, targetEntityID: entityHit.entity.id))
    }
    if let blockHit, let blockEffect {
        guard blockEffect(player.world, blockHit) else { return .failure(.blockedPlacement(spell.id)) }
        return .success(RPGActionResult(actionID: spell.id, sequence: player.rpg.actionSequence,
                                        message: spell.displayName,
                                        blockPosition: RPGBlockPosition(blockHit.x, blockHit.y, blockHit.z)))
    }
    guard blockHit != nil || entityHit != nil else { return .failure(.noTarget(spell.id)) }
    return actionResult(player, spell, spell.displayName)
}

private func castSkillDamageRay(_ player: Player, _ skill: RPGSkillDefinition, range: Double, damage: Double,
                                effect: (LivingEntity) -> Void,
                                dryRun: Bool) -> Result<RPGActionResult, RPGActionFailure> {
    let look = lookVector(player)
    let blockHit = player.world.raycast(player.x, player.eyeY(), player.z, look.dx, look.dy, look.dz, range)
    let entityHit = livingEntityInLook(player, range: range)
    guard let entityHit, blockHit == nil || entityHit.t <= blockHit!.t else {
        return .failure(.noTarget(skill.id))
    }
    if !dryRun {
        _ = entityHit.entity.hurt(damage + rpgDerivedStats(player.rpg).meleeDamageBonus, "player", player)
        effect(entityHit.entity)
        player.world.hooks.addParticles("crit", entityHit.entity.x, entityHit.entity.y + entityHit.entity.height * 0.6, entityHit.entity.z, 12, 0.4, 0)
    }
    return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                    message: skill.displayName, targetEntityID: entityHit.entity.id))
}

private func castHeal(_ player: Player, _ spell: RPGSpellDefinition, heal: Double,
                      clearEffects: [String], dryRun: Bool) -> Result<RPGActionResult, RPGActionFailure> {
    let target = livingEntityInLook(player, range: spell.rangeBlocks)?.entity ?? player
    if !dryRun {
        if heal > 0 { target.heal(heal) }
        for effect in clearEffects { target.removeEffect(effect) }
        player.world.hooks.addParticles("heart", target.x, target.y + target.height + 0.2, target.z, 8, 0.4, 0)
    }
    return .success(RPGActionResult(actionID: spell.id, sequence: player.rpg.actionSequence,
                                    message: spell.displayName, targetEntityID: target.id))
}

private func castWard(_ player: Player, _ spell: RPGSpellDefinition, dryRun: Bool) -> Result<RPGActionResult, RPGActionFailure> {
    guard let hit = player.world.raycast(player.x, player.eyeY(), player.z, lookVector(player).dx,
                                         lookVector(player).dy, lookVector(player).dz, max(1, spell.rangeBlocks)) else {
        if !dryRun {
            player.absorption = max(player.absorption, spell.id == "stone_ward" ? 6 : 3)
            player.addEffect("resistance", min(spell.durationTicks, 260), 0)
        }
        return actionResult(player, spell, spell.displayName)
    }
    if !dryRun {
        let bid = hit.cell >> 4
        if bid != 0 && blockDefs[bid].hardness >= 0 {
            player.world.hooks.addParticles("enchant", Double(hit.x) + 0.5, Double(hit.y) + 0.5, Double(hit.z) + 0.5, 12, 0.5, 0)
        }
    }
    return .success(RPGActionResult(actionID: spell.id, sequence: player.rpg.actionSequence,
                                    message: spell.displayName,
                                    blockPosition: RPGBlockPosition(hit.x, hit.y, hit.z)))
}

private func actionResult(_ player: Player, _ spell: RPGSpellDefinition, _ message: String) -> Result<RPGActionResult, RPGActionFailure> {
    .success(RPGActionResult(actionID: spell.id, sequence: player.rpg.actionSequence, message: message))
}

private func actionResult(_ player: Player, _ skill: RPGSkillDefinition, _ message: String) -> Result<RPGActionResult, RPGActionFailure> {
    .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence, message: message))
}

private func inspectContainer(_ player: Player, skill: RPGSkillDefinition, effect: String,
                              dryRun: Bool) -> Result<RPGActionResult, RPGActionFailure> {
    guard let hit = player.world.raycast(player.x, player.eyeY(), player.z, lookVector(player).dx,
                                         lookVector(player).dy, lookVector(player).dz, 5) else {
        return .failure(.noTarget(skill.id))
    }
    guard isContainerBlockID(hit.cell >> 4) else { return .failure(.noTarget(skill.id)) }
    if !dryRun {
        if effect == "luck" {
            player.addEffect("night_vision", 220, 0)
        }
        player.world.hooks.addParticles(effect == "luck" ? "enchant" : "glow",
                                        Double(hit.x) + 0.5, Double(hit.y) + 0.7, Double(hit.z) + 0.5,
                                        14, 0.35, 0)
    }
    return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                    message: skill.displayName,
                                    blockPosition: RPGBlockPosition(hit.x, hit.y, hit.z)))
}

private func triggerRedstone(_ player: Player, skill: RPGSkillDefinition,
                             dryRun: Bool) -> Result<RPGActionResult, RPGActionFailure> {
    guard let hit = player.world.raycast(player.x, player.eyeY(), player.z, lookVector(player).dx,
                                         lookVector(player).dy, lookVector(player).dz, 10) else {
        return .failure(.noTarget(skill.id))
    }
    let id = hit.cell >> 4
    guard isRemoteTriggerBlockID(id) else { return .failure(.noTarget(skill.id)) }
    if !dryRun {
        if id == Int(B.dispenser) || id == Int(B.dropper) {
            player.world.scheduleTick(hit.x, hit.y, hit.z, id, 1)
            player.world.hooks.playSound("block.lever.click", Double(hit.x) + 0.5, Double(hit.y) + 0.5, Double(hit.z) + 0.5, 0.35, 1.2)
        } else {
            _ = useBlock(InteractCtx(world: player.world, player: player), hit)
        }
        player.world.hooks.addParticles("redstone", Double(hit.x) + 0.5, Double(hit.y) + 0.5, Double(hit.z) + 0.5, 10, 0.3, 0)
    }
    return .success(RPGActionResult(actionID: skill.id, sequence: player.rpg.actionSequence,
                                    message: skill.displayName,
                                    blockPosition: RPGBlockPosition(hit.x, hit.y, hit.z)))
}

private func repairFirstDamagedGear(_ player: Player, dryRun: Bool) -> String? {
    var stacks: [(label: String, stack: ItemStack)] = []
    if let main = player.mainHand { stacks.append(("Held", main)) }
    if let off = player.offHand { stacks.append(("Offhand", off)) }
    for (index, stack) in player.armor.enumerated() where stack != nil {
        stacks.append(("Armor \(index + 1)", stack!))
    }
    for (index, stack) in player.inventory.enumerated() where stack != nil {
        stacks.append(("Slot \(index + 1)", stack!))
    }
    for entry in stacks {
        let maxD = maxDamageOf(entry.stack)
        guard maxD > 0, entry.stack.damage > 0 else { continue }
        if !dryRun {
            let repair = max(1, maxD / 4)
            entry.stack.damage = max(0, entry.stack.damage - repair)
            player.world.hooks.addParticles("enchant", player.x, player.y + 1, player.z, 10, 0.4, 0)
        }
        return "Quick Repair \(entry.label)"
    }
    return nil
}

private func targetOrNearestTNT(_ player: Player) -> (x: Int, y: Int, z: Int)? {
    if let hit = player.world.raycast(player.x, player.eyeY(), player.z, lookVector(player).dx,
                                      lookVector(player).dy, lookVector(player).dz, 8),
       (hit.cell >> 4) == Int(B.tnt) {
        return (hit.x, hit.y, hit.z)
    }
    return nearestBlock(from: player, radius: 6) { $0 == Int(B.tnt) }.map { ($0.x, $0.y, $0.z) }
}

private func nearestBlock(from player: Player, radius: Int,
                          matching predicate: (Int) -> Bool) -> (x: Int, y: Int, z: Int, id: Int)? {
    let bx = ifloor(player.x)
    let by = ifloor(player.y)
    let bz = ifloor(player.z)
    let minY = player.world.info.minY
    let maxY = player.world.info.minY + player.world.info.height - 1
    let y0 = max(minY, by - radius)
    let y1 = min(maxY, by + radius)
    guard y0 <= y1 else { return nil }
    var best: (x: Int, y: Int, z: Int, id: Int, d: Int)?
    for y in y0...y1 {
        for z in (bz - radius)...(bz + radius) {
            for x in (bx - radius)...(bx + radius) {
                let id = player.world.getBlock(x, y, z) >> 4
                guard predicate(id) else { continue }
                let dx = x - bx
                let dy = y - by
                let dz = z - bz
                let dist = dx * dx + dy * dy + dz * dz
                if let current = best {
                    if dist < current.d
                        || (dist == current.d
                            && (y < current.y
                                || (y == current.y && (z < current.z || (z == current.z && x < current.x))))) {
                        best = (x, y, z, id, dist)
                    }
                } else {
                    best = (x, y, z, id, dist)
                }
            }
        }
    }
    guard let best else { return nil }
    return (best.x, best.y, best.z, best.id)
}

private func isTrapBlockID(_ id: Int) -> Bool {
    let name = id >= 0 && id < blockDefs.count ? blockDefs[id].name : ""
    return id == Int(B.tripwire) || id == Int(B.tripwire_hook) || id == Int(B.dispenser)
        || id == Int(B.dropper) || id == Int(B.trapped_chest) || id == Int(B.tnt)
        || name.hasSuffix("_pressure_plate")
}

private func isContainerBlockID(_ id: Int) -> Bool {
    let name = id >= 0 && id < blockDefs.count ? blockDefs[id].name : ""
    return name == "chest" || name == "trapped_chest" || name == "barrel"
        || name == "dispenser" || name == "dropper"
}

private func isRemoteTriggerBlockID(_ id: Int) -> Bool {
    let name = id >= 0 && id < blockDefs.count ? blockDefs[id].name : ""
    return id == Int(B.lever) || id == Int(B.dispenser) || id == Int(B.dropper)
        || id == Int(B.repeater) || id == Int(B.repeater_on)
        || id == Int(B.comparator) || id == Int(B.comparator_on)
        || id == Int(B.daylight_detector) || id == Int(B.daylight_detector_inverted)
        || name.hasSuffix("_button")
}

private func lookVector(_ player: Player) -> (dx: Double, dy: Double, dz: Double) {
    let cp = detCos(player.pitch)
    return (-detSin(player.yaw) * cp, -detSin(player.pitch), detCos(player.yaw) * cp)
}

private func pointInFront(_ player: Player, distance: Double) -> (x: Double, y: Double, z: Double) {
    let look = lookVector(player)
    return (player.x + look.dx * distance, player.y, player.z + look.dz * distance)
}

private func targetPoint(_ player: Player, range: Double) -> (x: Double, y: Double, z: Double) {
    let look = lookVector(player)
    if let hit = player.world.raycast(player.x, player.eyeY(), player.z, look.dx, look.dy, look.dz, range) {
        return (hit.px, hit.py, hit.pz)
    }
    return (player.x + look.dx * range, player.eyeY() + look.dy * range, player.z + look.dz * range)
}

private func adjacentPosition(_ hit: RaycastHit) -> RPGBlockPosition {
    RPGBlockPosition(hit.x + DIR_X[hit.face], hit.y + DIR_Y[hit.face], hit.z + DIR_Z[hit.face])
}

private func canReplace(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    let bid = world.getBlock(x, y, z) >> 4
    return bid == 0 || blockDefs[bid].replaceable
}

private func livingEntityInLook(_ player: Player, range: Double) -> (entity: LivingEntity, t: Double)? {
    let look = lookVector(player)
    var best: (entity: LivingEntity, t: Double, id: Int)?
    for e in player.world.getEntitiesNear(player.x, player.eyeY(), player.z, range + 2) {
        guard let liv = e as? LivingEntity, liv !== player, !liv.dead else { continue }
        let vx = liv.x - player.x
        let vy = liv.centerY() - player.eyeY()
        let vz = liv.z - player.z
        let t = vx * look.dx + vy * look.dy + vz * look.dz
        if t < 0 || t > range { continue }
        let cx = player.x + look.dx * t
        let cy = player.eyeY() + look.dy * t
        let cz = player.z + look.dz * t
        let dx = liv.x - cx
        let dy = liv.centerY() - cy
        let dz = liv.z - cz
        let radius = max(0.45, liv.width * 0.5 + 0.35)
        if dx * dx + dy * dy + dz * dz > radius * radius { continue }
        if let current = best {
            if t < current.t || (abs(t - current.t) < 0.0001 && liv.id < current.id) {
                best = (liv, t, liv.id)
            }
        } else {
            best = (liv, t, liv.id)
        }
    }
    guard let best else { return nil }
    return (best.entity, best.t)
}

private func nearestLivingEntities(from entity: Entity, radius: Double, excluding excluded: [Int]) -> [LivingEntity] {
    let excludedSet = Set(excluded)
    return entity.world.getEntitiesNear(entity.x, entity.y + entity.height * 0.5, entity.z, radius)
        .compactMap { $0 as? LivingEntity }
        .filter { !$0.dead && !excludedSet.contains($0.id) }
        .sorted {
            let da = entity.distanceToSq($0)
            let db = entity.distanceToSq($1)
            if abs(da - db) > 0.0001 { return da < db }
            return $0.id < $1.id
        }
}

private func shadowStepDestination(_ player: Player, range: Double) -> (x: Double, y: Double, z: Double)? {
    let look = lookVector(player)
    if let hit = player.world.raycast(player.x, player.eyeY(), player.z, look.dx, look.dy, look.dz, range) {
        let x = hit.px - look.dx * 0.8
        let y = max(Double(player.world.info.minY + 1), hit.py - player.height * 0.5)
        let z = hit.pz - look.dz * 0.8
        return (x, y, z)
    }
    return (player.x + look.dx * range, player.y + look.dy * range, player.z + look.dz * range)
}
