// Skill-tree gameplay integration — authoritative usage awards and active
// actions.  The pure balance/state math lives in SkillTreeProgression.swift;
// this file owns only verified world events and guarded mutations.

import Foundation

private func skillTreeEmptyReport(for branch: SkillTreeBranchState) -> SkillTreeProgressionReport {
    let normalized = skillTreeValidatedBranchState(branch)
    return SkillTreeProgressionReport(requestedXP: 0, awardedXP: 0,
                                      previousPrimaryRank: normalized.primaryRank,
                                      primaryRank: normalized.primaryRank,
                                      previousAdvancedRank: normalized.advancedRank,
                                      advancedRank: normalized.advancedRank,
                                      reachedPrimaryCap: false,
                                      reachedAdvancedCap: false)
}

/// Metadata bit marking a mining-resource block that a player placed (like
/// Minecraft's `persistent` leaves).  Worldgen and amethyst growth never set
/// it, and it is free on every such block: ores carry no metadata, redstone
/// ore reads only bit 0x1 ("lit"), and an amethyst cluster stores its facing
/// in values 0-5.  Tiles, light, shape and drops ignore it.
public let SKILL_TREE_PLAYER_PLACED_META_BIT = 0x8

/// The block's own (re-placeable) item, or nil.
private func skillTreeOwnItemID(ofBlock blockID: Int) -> Int? {
    guard blockID > 0, blockID < blockDefs.count, blockID < blockToItem.count,
          blockToItem[blockID] >= 0 else { return nil }
    return Int(blockToItem[blockID])
}

private func skillTreeIsMiningResourceBlock(_ blockID: Int) -> Bool {
    blockID > 0 && blockID < blockDefs.count && skillTreeMiningResource(blockID: blockDefs[blockID].name) != nil
}

/// The cell the world stores when a player places `cell`, by hand, from a
/// LAN guest, or by pasting a template.  A mining-resource block gains the
/// player-placed mark with every other metadata bit (cluster facing, the
/// redstone-ore lit bit) kept, so a LAN guest can neither clear the mark nor
/// lose real state.  Every other block is stored unchanged.
public func skillTreePlayerPlacedCell(_ cell: Int) -> Int {
    guard skillTreeIsMiningResourceBlock(cell >> 4) else { return cell }
    return cell | SKILL_TREE_PLAYER_PLACED_META_BIT
}

/// Whether `cell` is a mining-resource block that a player placed.  Such a
/// block earns no Mining XP and no ore-yield bonus.
public func skillTreeIsPlayerPlacedResourceCell(_ cell: Int) -> Bool {
    (cell & SKILL_TREE_PLAYER_PLACED_META_BIT) != 0 && skillTreeIsMiningResourceBlock(cell >> 4)
}

/// Awards a successful, harvestable mineral break.  The caller supplies only
/// a block that was actually removed after the ordinary harvest gate passed;
/// creative mining never advances a tree.  Mining XP is earned once per
/// naturally occurring resource block: a silk-touch break (which drops the
/// re-placeable block) and a player-placed resource block earn nothing.
@discardableResult
public func skillTreeAwardMiningBreak(_ player: Player, cell: Int, silkTouch: Bool) -> SkillTreeProgressionReport {
    let blockID = cell >> 4
    guard player.rpg.skillTrees != nil, player.gameMode != GameMode.creative,
          blockID >= 0, blockID < blockDefs.count,
          !silkTouch, !skillTreeIsPlayerPlacedResourceCell(cell) else {
        return skillTreeEmptyReport(for: rpgSkillTreeState(player.rpg).mining)
    }
    let award = skillTreeMiningXP(blockID: blockDefs[blockID].name)
    var trees = player.skillTreeState
    let report = skillTreeAwardXP(award, to: .mining, in: &trees)
    if report.awardedXP > 0 { player.skillTreeState = trees }
    return report
}

/// Returns extra physical drops for an ore stack broken from `cell`.  It is
/// stateless: breaking the same block with the same stack and world seed
/// always gives the same result, so the benefit cannot desynchronize the
/// simulation RNG stream.  A player-placed resource block never gains a
/// bonus, and neither does a drop that is the block's own item: it could be
/// placed again, and the stateless roll would then duplicate it every cycle.
public func skillTreeMiningBonusDrops(_ player: Player, cell: Int,
                                      x: Int, y: Int, z: Int,
                                      itemID: Int, baseDropCount: Int) -> Int {
    let blockID = cell >> 4
    guard let trees = player.rpg.skillTrees,
          skillTreeIsMiningResourceBlock(blockID),
          !skillTreeIsPlayerPlacedResourceCell(cell),
          itemID != skillTreeOwnItemID(ofBlock: blockID),
          baseDropCount > 0 else { return 0 }
    let salt = UInt32(truncatingIfNeeded: itemID) ^ 0x51A7_0E11
    let roll = Int(hash3(player.world.seed, x, y, z, salt) % UInt32(SKILL_TREE_BASIS_POINTS))
    return skillTreeMiningBonusDropCount(baseDropCount: baseDropCount,
                                         advancedRank: trees.mining.advancedRank,
                                         deterministicRollBasisPoints: roll)
}

public func skillTreeIsUsageCombatTarget(_ entity: Entity) -> Bool {
    guard let living = entity as? LivingEntity, !living.dead, living.deathTime <= 0 else { return false }
    return living is Animal || rpgIsHostileTarget(living)
}

@discardableResult
public func skillTreeAwardMeleeHit(_ player: Player, successfulSwordDamage: Bool) -> SkillTreeProgressionReport {
    guard player.rpg.skillTrees != nil, player.gameMode != GameMode.creative else {
        return skillTreeEmptyReport(for: rpgSkillTreeState(player.rpg).melee)
    }
    var trees = player.skillTreeState
    let report = skillTreeAwardXP(skillTreeMeleeXP(successfulSwordDamage: successfulSwordDamage),
                                  to: .melee, in: &trees)
    if report.awardedXP > 0 { player.skillTreeState = trees }
    return report
}

@discardableResult
public func skillTreeAwardRangedHit(_ player: Player, successfulBowDamage: Bool) -> SkillTreeProgressionReport {
    guard player.rpg.skillTrees != nil, player.gameMode != GameMode.creative else {
        return skillTreeEmptyReport(for: rpgSkillTreeState(player.rpg).ranged)
    }
    var trees = player.skillTreeState
    let report = skillTreeAwardXP(skillTreeRangedXP(successfulBowDamage: successfulBowDamage),
                                  to: .ranged, in: &trees)
    if report.awardedXP > 0 { player.skillTreeState = trees }
    return report
}

/// Progression rarity is deliberately independent from display rarity.  The
/// registry’s `rarity` is mostly a tooltip/presentation tier, while ordinary
/// iron, gold, redstone, diamonds, and other mining resources are registered
/// as common display items.  Craft XP must still reflect the resources the
/// player actually consumed.
public func skillTreeCraftingMaterialRarity(for itemID: Int) -> Int {
    guard itemID >= 0, itemID < itemDefs.count else { return 0 }
    let registryRarity = max(0, min(5, itemDef(itemID).rarity))
    switch itemDef(itemID).name {
    case "raw_copper", "copper_ingot":
        return max(registryRarity, 1)
    case "raw_iron", "iron_ingot", "iron_nugget":
        return max(registryRarity, 2)
    case "raw_gold", "gold_ingot", "gold_nugget", "redstone", "lapis_lazuli", "quartz", "amethyst_shard":
        return max(registryRarity, 3)
    case "emerald", "diamond", "labradorite":
        return max(registryRarity, 4)
    case "ancient_debris", "netherite_scrap", "netherite_ingot", "echo_shard":
        return max(registryRarity, 5)
    default:
        return registryRarity
    }
}

/// Converts concrete, consumed crafting inputs into the pure progression
/// payload.  Callers must pass a host/local matched grid rather than UI text;
/// tag choices are already resolved to their actual item names by then.
public func skillTreeCraftingIngredients(_ names: [String?]) -> [SkillTreeCraftingIngredient] {
    names.compactMap { name in
        guard let name, let itemID = iidOpt(name) else { return nil }
        return SkillTreeCraftingIngredient(rarity: skillTreeCraftingMaterialRarity(for: itemID), count: 1)
    }
}

/// Records completed, material-backed recipe rounds.  Recipes that produce
/// the same output item share one 100-round cap before XP is calculated, so
/// alternate ingredient variants cannot carry the crafting tree indefinitely.
/// Repacking recipes (ingot <-> block and the like) earn nothing and consume
/// no mastery rounds; the LAN host applies the same rule.
@discardableResult
public func skillTreeAwardCraftedRecipe(_ player: Player, recipeIndex: Int,
                                        completedRounds: Int,
                                        ingredients: [String?]) -> SkillTreeProgressionReport {
    guard player.rpg.skillTrees != nil, player.gameMode != GameMode.creative,
          recipeIndex >= 0, recipeIndex < craftingRecipes.count,
          !craftingRecipeIsRepacking(recipeIndex: recipeIndex),
          completedRounds > 0 else {
        return skillTreeEmptyReport(for: rpgSkillTreeState(player.rpg).crafting.progress)
    }
    var trees = player.skillTreeState
    let masteryKey = craftingOutputMasteryKey(forRecipeIndex: recipeIndex)
    let mastery = skillTreeRecordCraftedRecipe(recipeIndex: recipeIndex,
                                                completedRounds: completedRounds,
                                                recipeCount: craftingRecipes.count,
                                                masteryIndex: masteryKey?.canonicalRecipeIndex,
                                                equivalentRecipeIndices: masteryKey?.equivalentRecipeIndices ?? [],
                                                in: &trees.crafting)
    guard mastery.accepted else {
        return skillTreeEmptyReport(for: trees.crafting.progress)
    }
    let materialInputs = skillTreeCraftingIngredients(ingredients)
    let report = skillTreeAwardXP(
        skillTreeCraftingXP(for: materialInputs, eligibleRounds: mastery.xpEligibleRounds),
        to: .crafting, in: &trees)
    // Persist the mastery counter even when the tree has reached its XP cap.
    player.skillTreeState = trees
    return report
}

/// Marks newly crafted equipment with the crafter's current advanced quality
/// rank.  Consumables and blocks stay unmarked; quality must be intrinsic to
/// a tool or armor stack so durability/damage remain correct after trading.
public func skillTreeApplyCraftingQuality(to stack: ItemStack, for player: Player) {
    guard let trees = player.rpg.skillTrees else { return }
    let definition = itemDef(stack.id)
    guard definition.tool != nil || definition.armor != nil else { return }
    let quality = skillTreeClampAdvancedRank(trees.crafting.progress.advancedRank)
    stack.data.craftingQuality = quality > 0 ? quality : nil
}

private func skillTreeActionLookVector(_ player: Player) -> (dx: Double, dy: Double, dz: Double) {
    let cp = detCos(player.pitch)
    return (-detSin(player.yaw) * cp, -detSin(player.pitch), detCos(player.yaw) * cp)
}

private func skillTreeRayTarget(_ player: Player, range: Double,
                                actionID: SkillTreeActionID) -> Result<LivingEntity, RPGActionFailure> {
    let look = skillTreeActionLookVector(player)
    let blockHit = player.world.raycast(player.x, player.eyeY(), player.z,
                                        look.dx, look.dy, look.dz, range)
    var best: (entity: LivingEntity, distance: Double)?
    for reference in player.world.getEntitiesNear(player.x, player.eyeY(), player.z, range + 2) {
        guard let entity = reference as? LivingEntity, entity !== player,
              skillTreeIsUsageCombatTarget(entity) else { continue }
        let vx = entity.x - player.x
        let vy = entity.centerY() - player.eyeY()
        let vz = entity.z - player.z
        let distance = vx * look.dx + vy * look.dy + vz * look.dz
        guard distance >= 0, distance <= range else { continue }
        let dx = entity.x - (player.x + look.dx * distance)
        let dy = entity.centerY() - (player.eyeY() + look.dy * distance)
        let dz = entity.z - (player.z + look.dz * distance)
        let radius = max(0.45, entity.width * 0.5 + 0.35)
        guard dx * dx + dy * dy + dz * dz <= radius * radius else { continue }
        if best == nil || distance < best!.distance
            || (distance == best!.distance && entity.id < best!.entity.id) {
            best = (entity, distance)
        }
    }
    guard let best, blockHit == nil || best.distance <= blockHit!.t else {
        return .failure(.noTarget(actionID.rawValue))
    }
    guard best.entity.invulnTicks <= 0 else { return .failure(.invalidTarget(actionID.rawValue)) }
    return .success(best.entity)
}

/// Whether `mob` is currently hunting `actor`.  A LAN guest acts through a
/// detached host ghost while mobs target that guest's in-world proxy, so the
/// proxy is matched by the ghost's authoritative LAN peer identity.
private func skillTreeMob(_ mob: Mob, isTargeting actor: Player) -> Bool {
    guard let target = mob.target else { return false }
    if target === actor { return true }
    guard case .lanPlayer(let peerID) = actor.scriptEventActorIdentity.ref,
          let proxy = target as? LANRemotePlayerEntity else { return false }
    return proxy.multiplayerPlayerID == peerID
}

/// Whether an area technique (Round House, Volley) may hit `entity`:
/// Monsters and the Ender Dragon, predatory prehistoric creatures, and any
/// mob currently targeting the acting player.  Players, tamed pets,
/// villagers, golems and passive livestock are never hit, so a pen or a
/// village cannot become area-of-effect collateral.
public func skillTreeIsAreaTechniqueTarget(_ entity: LivingEntity, actor: Player) -> Bool {
    guard entity !== actor, !entity.isPlayer, !(entity.dead || entity.deathTime > 0),
          entity.invulnTicks <= 0 else { return false }
    if rpgIsHostileTarget(entity) { return true }
    guard let mob = entity as? Mob, mob.ownerId == nil,
          !((mob as? TamableAnimal)?.tamed ?? false), !((mob as? HorseBase)?.tamed ?? false),
          !(mob is Villager), !(mob is IronGolem), !(mob is SnowGolem) else { return false }
    if let creature = mob as? PrehistoricCreature, creature.definition.isPredatory { return true }
    return skillTreeMob(mob, isTargeting: actor)
}

private func skillTreeSortedAreaTargets(near x: Double, y: Double, z: Double,
                                        radius: Double, actor player: Player) -> [LivingEntity] {
    player.world.getEntitiesNear(x, y, z, radius)
        .compactMap { $0 as? LivingEntity }
        .filter { skillTreeIsAreaTechniqueTarget($0, actor: player) }
        .sorted {
            let adx = $0.x - x, ady = $0.centerY() - y, adz = $0.z - z
            let bdx = $1.x - x, bdy = $1.centerY() - y, bdz = $1.z - z
            let ad = adx * adx + ady * ady + adz * adz
            let bd = bdx * bdx + bdy * bdy + bdz * bdz
            return ad == bd ? $0.id < $1.id : ad < bd
        }
}

/// The arrow a bow technique spends: `nil` when none is spent (Creative, or
/// an Infinity bow, which fires a plain arrow), otherwise the first owned of
/// plain, spectral, then tipped arrows, so special arrows are not wasted on
/// a technique that does not apply their effect.  `.failure` when the player
/// has no arrow to spend.
private func skillTreeTechniqueArrow(_ player: Player, bow: ItemStack) -> Result<Int?, RPGActionFailure> {
    if player.gameMode == GameMode.creative || enchLevel(bow, "infinity") > 0 { return .success(nil) }
    for name in ["arrow", "spectral_arrow", "tipped_arrow"] {
        if let itemID = iidOpt(name), player.countItem(itemID) > 0 { return .success(itemID) }
    }
    return .failure(.missingMaterial("arrow"))
}

private func skillTreeWeaponDamage(_ player: Player,
                                   descriptor: SkillTreeActionDescriptor,
                                   trees: SkillTreeState) -> Double {
    guard let held = player.mainHand else { return 0 }
    var damage: Double
    switch descriptor.equipment {
    case .sword:
        // Keep the same order as ordinary sword combat: quality and the
        // usage-tree rank scale the equipped weapon contribution, while
        // enchantments remain additive.  This is important both for the
        // crafting promise and so a Sharpness enchantment does not receive an
        // undocumented second multiplier in an advanced move.
        damage = 1 + effectiveWeaponDamageOf(held) * skillTreeWeaponDamageMultiplier(
            primaryRank: trees.melee.primaryRank)
        damage += Double(enchLevel(held, "sharpness")) * 0.5
            + (enchLevel(held, "sharpness") > 0 ? 0.5 : 0)
    case .bow:
        // An instant bow technique hits exactly like an ordinary fully drawn,
        // non-critical arrow from the same bow and rank; `shootBow` uses the
        // same owner, so the two cannot drift apart.
        damage = bowFullDrawHitDamage(player, bow: held)
    case .none:
        return 0
    }
    return max(0, damage)
}

/// Bow techniques use the ordinary arrow damage source, so arrow immunity,
/// the Enderman's dodge and Projectile Protection apply to them as well.
private func skillTreeTechniqueDamageSource(_ descriptor: SkillTreeActionDescriptor) -> String {
    descriptor.equipment == .bow ? "projectile" : "skill_tree_\(descriptor.id.rawValue)"
}

private func skillTreeDisarm(_ target: LivingEntity) -> Bool {
    var dropped = false
    if let main = target.mainHand {
        target.dropStack(main)
        target.mainHand = nil
        dropped = true
    }
    if let off = target.offHand {
        target.dropStack(off)
        target.offHand = nil
        dropped = true
    }
    for index in target.armor.indices {
        guard let stack = target.armor[index] else { continue }
        target.dropStack(stack)
        target.armor[index] = nil
        dropped = true
    }
    return dropped
}

/// Records the action's cooldown and sequence.  `skillTreeExecuteAction`
/// preflights every condition checked here before it mutates anything, so
/// this commit cannot fail after an action's effect has been applied.
private func skillTreeCommitActionState(_ player: Player,
                                        descriptor: SkillTreeActionDescriptor) -> Result<Int, RPGActionFailure> {
    var state = repairRPGCharacterState(player.rpg)
    guard state.skillTrees != nil,
          state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION,
          let sequence = rpgNextActionSequence(state) else {
        return .failure(.authorityExhausted)
    }
    guard let cooldowns = skillTreeCooldownsAfterUse(descriptor.id, in: state.activeCooldowns) else {
        return .failure(.boundedStateLimit)
    }
    state.activeCooldowns = cooldowns
    state.actionSequence = sequence
    state.authorityRevision += 1
    player.rpg = repairRPGCharacterState(state)
    return .success(sequence)
}

private func skillTreeFieldRepair(_ player: Player,
                                  descriptor: SkillTreeActionDescriptor) -> Result<RPGActionResult, RPGActionFailure> {
    guard let held = player.mainHand, held.damage > 0,
          let materialName = repairMaterialName(for: held),
          let materialID = iidOpt(materialName), player.countItem(materialID) > 0 else {
        return .failure(.noRepairTarget)
    }
    let maximum = maxDamageOf(held)
    guard maximum > 0 else { return .failure(.noRepairTarget) }
    // Spend the material first: it is the only step that can still refuse,
    // and it fails without side effects.  The commit below was preflighted.
    guard player.gameMode == GameMode.creative || player.removeItems(materialID, 1) else {
        return .failure(.missingMaterial(materialName))
    }
    guard case .success(let sequence) = skillTreeCommitActionState(player, descriptor: descriptor) else {
        return .failure(.authorityExhausted)
    }
    let base = max(1, Int((Double(maximum) / 4).rounded(.up)))
    let repair = skillTreeEffectiveRepairAmount(base: base,
                                                qualityRank: player.skillTreeState.crafting.progress.advancedRank)
    held.damage = max(0, held.damage - repair)
    player.world.hooks.playSound("block.anvil.use", player.x, player.y, player.z, 0.8, 1.15)
    return .success(RPGActionResult(actionID: descriptor.id.rawValue, sequence: sequence,
                                    message: "Field-repaired \(itemDef(held.id).displayName)"))
}

/// Executes one unlocked fast-bar action.  Every check (actor authority,
/// equipment, ammunition, target line-of-sight, cooldown, and bounded
/// sequence) runs before anything is mutated; a technique that the target
/// negates fails without spending ammunition, durability or its cooldown.
/// No class game rule is consulted: the tree is the authoritative
/// advancement system for envelopes that contain it.
public func skillTreeExecuteAction(_ player: Player, id: SkillTreeActionID,
                                   authorization: RPGActionAuthorization) -> Result<RPGActionResult, RPGActionFailure> {
    guard !player.dead, player.deathTime <= 0, player.health > 0 else {
        return .failure(.actorUnavailable)
    }
    guard authorization.ownerAuthorityID == player.effectiveRPGAuthorityID,
          authorization.worldOwnerEntityID == player.id else {
        return .failure(.authorizationMismatch)
    }
    let state = repairRPGCharacterState(player.rpg)
    guard let rawTrees = state.skillTrees else { return .failure(.characterNotCreated) }
    let trees = skillTreeValidatedState(rawTrees, recipeCount: craftingRecipes.count)
    let descriptor = skillTreeActionDescriptor(id)
    guard skillTreeActionIsUnlocked(id, in: trees) else { return .failure(.skillNotPrepared(id.rawValue)) }
    // Stun Enemy and Pinning Shot share one cooldown (`skillTreeCooldownGroup`).
    guard skillTreeCooldownRemainingTicks(id, in: state.activeCooldowns) == 0 else {
        return .failure(.skillOnCooldown(id.rawValue))
    }
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION,
          rpgNextActionSequence(state) != nil else { return .failure(.authorityExhausted) }
    // Preflight the bounded cooldown write (one entry per action in the
    // cooldown group) before any target, item, or world mutation.  A
    // malformed-but-repaired envelope can legitimately carry a full cooldown
    // list; in that case an action must fail atomically rather than
    // damage/push a target and only then discover it cannot record its own
    // cooldown.
    guard skillTreeCooldownsAfterUse(id, in: state.activeCooldowns) != nil else {
        return .failure(.boundedStateLimit)
    }

    if id == .fieldRepair {
        return skillTreeFieldRepair(player, descriptor: descriptor)
    }

    let requiredTool: String
    switch descriptor.equipment {
    case .sword: requiredTool = "sword"
    case .bow: requiredTool = "bow"
    case .none: requiredTool = ""
    }
    guard let held = player.mainHand, itemDef(held.id).tool?.type == requiredTool else {
        return .failure(.missingEquipment("a \(requiredTool) in your main hand"))
    }
    var arrowItemID: Int?
    if descriptor.equipment == .bow {
        switch skillTreeTechniqueArrow(player, bow: held) {
        case .success(let itemID): arrowItemID = itemID
        case .failure(let failure): return .failure(failure)
        }
    }

    // Round House is a genuine 360-degree melee move. It deliberately does
    // not require an entity under the crosshair; its own deterministic area
    // query below is the target admission check. Every other technique is a
    // directional sword/bow action and retains the line-of-sight preflight.
    var primary: LivingEntity?
    if id != .roundHouse {
        let range = descriptor.equipment == .bow ? 18.0 : 4.5
        switch skillTreeRayTarget(player, range: range, actionID: id) {
        case .success(let target): primary = target
        case .failure(let failure): return .failure(failure)
        }
    }
    let damage = skillTreeWeaponDamage(player, descriptor: descriptor, trees: trees)
    let damageSource = skillTreeTechniqueDamageSource(descriptor)
    var affected: [LivingEntity] = []
    var dealtDamage = false
    switch id {
    case .stunEnemy, .pinningShot:
        guard let primary else { return .failure(.noTarget(id.rawValue)) }
        let duration = descriptor.stunDurationTicks(bossTier: isBossTierEntityType(primary.type))
        primary.skillTreeStunTicks = max(primary.skillTreeStunTicks, duration)
        primary.skillTreeStunProne = true
        primary.sneaking = true
        primary.vx = 0; primary.vz = 0
        affected = [primary]
    case .spartanKick, .powerShot:
        guard let primary else { return .failure(.noTarget(id.rawValue)) }
        dealtDamage = primary.hurt(damage * descriptor.weaponDamageMultiplier, damageSource, player)
        if dealtDamage {
            let look = skillTreeActionLookVector(player)
            // `move` performs a swept collision check and respects finite-map
            // bounds, so a kick cannot phase an entity through geometry.
            primary.move(look.dx * Double(descriptor.pushDistanceBlocks), 0,
                         look.dz * Double(descriptor.pushDistanceBlocks))
            primary.vx = 0; primary.vz = 0
            affected = [primary]
        }
    case .roundHouse, .volley:
        let center = id == .roundHouse ? player : primary
        guard let center else { return .failure(.noTarget(id.rawValue)) }
        let targets = skillTreeSortedAreaTargets(near: center.x, y: center.centerY(), z: center.z,
                                                 radius: id == .roundHouse ? 3 : 3.5, actor: player)
        for target in targets.prefix(16)
            where target.hurt(damage * descriptor.weaponDamageMultiplier, damageSource, player) {
            affected.append(target)
        }
        dealtDamage = !affected.isEmpty
    case .disarmEnemy, .disarmingShot:
        guard let primary else { return .failure(.noTarget(id.rawValue)) }
        affected = skillTreeDisarm(primary) ? [primary] : []
    case .battleCry, .eagleEye:
        guard let primary else { return .failure(.noTarget(id.rawValue)) }
        dealtDamage = primary.hurt(damage * descriptor.weaponDamageMultiplier, damageSource, player)
        affected = dealtDamage ? [primary] : []
    case .fieldRepair:
        return skillTreeFieldRepair(player, descriptor: descriptor)
    }
    // Nothing above has spent anything when the action had no effect: the
    // only mutation so far is the target's own response to a hit it negated.
    guard !affected.isEmpty else { return .failure(.noEffect(descriptor.displayName)) }
    guard case .success(let sequence) = skillTreeCommitActionState(player, descriptor: descriptor) else {
        return .failure(.authorityExhausted)
    }
    if let arrowItemID { player.removeItems(arrowItemID, 1) }
    player.damageHeld(1)
    // A technique is weapon use only when it actually damaged a qualifying
    // living target.  Award once per committed technique, rather than once
    // per AoE victim, so grouped enemies are not an XP multiplier; stuns and
    // disarms deal no damage and award nothing.
    if dealtDamage {
        switch descriptor.equipment {
        case .sword:
            _ = skillTreeAwardMeleeHit(player, successfulSwordDamage: true)
        case .bow:
            _ = skillTreeAwardRangedHit(player, successfulBowDamage: true)
        case .none:
            break
        }
    }
    player.world.hooks.playSound(descriptor.equipment == .bow ? "entity.arrow.shoot" : "entity.player.attack.strong",
                                 player.x, player.y, player.z, 0.9, 1)
    return .success(RPGActionResult(actionID: descriptor.id.rawValue, sequence: sequence,
                                    message: "Used \(descriptor.displayName)",
                                    targetEntityID: affected.first?.id))
}
