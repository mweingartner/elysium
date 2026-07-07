import Foundation

public enum RPGActionFailure: Error, Equatable, CustomStringConvertible {
    case characterNotCreated
    case unknownSpell(String)
    case spellNotPrepared(String)
    case insufficientIntelligence(required: Int)
    case insufficientFatigue(required: Double, available: Double)
    case spellOnCooldown(String)
    case noTarget(String)
    case blockedPlacement(String)

    public var description: String {
        switch self {
        case .characterNotCreated: return "Character has not been created"
        case .unknownSpell(let id): return "Unknown spell: \(id)"
        case .spellNotPrepared(let id): return "Spell is not prepared: \(id)"
        case .insufficientIntelligence(let value): return "Requires IQ \(value)"
        case .insufficientFatigue(let required, let available):
            return "Requires \(Int(required.rounded(.up))) fatigue; \(Int(available.rounded(.down))) available"
        case .spellOnCooldown(let id): return "Spell is on cooldown: \(id)"
        case .noTarget(let id): return "No target for \(id)"
        case .blockedPlacement(let id): return "Blocked placement for \(id)"
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
    return prepared[next]
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
