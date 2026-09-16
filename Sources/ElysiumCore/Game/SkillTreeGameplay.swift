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

/// Awards a successful, harvestable mineral break.  The caller supplies only
/// a block that was actually removed after the ordinary harvest gate passed;
/// creative mining never advances a tree.
@discardableResult
public func skillTreeAwardMiningBreak(_ player: Player, blockID: Int) -> SkillTreeProgressionReport {
    guard player.rpg.skillTrees != nil, player.gameMode != GameMode.creative,
          blockID >= 0, blockID < blockDefs.count else {
        return skillTreeEmptyReport(for: rpgSkillTreeState(player.rpg).mining)
    }
    let award = skillTreeMiningXP(blockID: blockDefs[blockID].name)
    var trees = player.skillTreeState
    let report = skillTreeAwardXP(award, to: .mining, in: &trees)
    if report.awardedXP > 0 { player.skillTreeState = trees }
    return report
}

/// Returns extra physical drops for an ore stack.  It is stateless: breaking
/// the same block with the same stack and world seed always gives the same
/// result, so the benefit cannot desynchronize the simulation RNG stream.
public func skillTreeMiningBonusDrops(_ player: Player, blockID: Int,
                                      x: Int, y: Int, z: Int,
                                      itemID: Int, baseDropCount: Int) -> Int {
    guard let trees = player.rpg.skillTrees,
          blockID >= 0, blockID < blockDefs.count,
          skillTreeMiningResource(blockID: blockDefs[blockID].name) != nil,
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
@discardableResult
public func skillTreeAwardCraftedRecipe(_ player: Player, recipeIndex: Int,
                                        completedRounds: Int,
                                        ingredients: [String?]) -> SkillTreeProgressionReport {
    guard player.rpg.skillTrees != nil, player.gameMode != GameMode.creative,
          recipeIndex >= 0, recipeIndex < craftingRecipes.count,
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

private func skillTreeSortedHostileTargets(near x: Double, y: Double, z: Double,
                                           radius: Double, excluding player: Player) -> [LivingEntity] {
    player.world.getEntitiesNear(x, y, z, radius)
        .compactMap { $0 as? LivingEntity }
        // Ordinary weapon use may train against animals, but the specified
        // circular/volley techniques hit enemies only; a livestock pen must
        // never become incidental area-of-effect collateral.
        .filter { $0 !== player && !($0.dead || $0.deathTime > 0)
            && rpgIsHostileTarget($0) && $0.invulnTicks <= 0 }
        .sorted {
            let adx = $0.x - x, ady = $0.centerY() - y, adz = $0.z - z
            let bdx = $1.x - x, bdy = $1.centerY() - y, bdz = $1.z - z
            let ad = adx * adx + ady * ady + adz * adz
            let bd = bdx * bdx + bdy * bdy + bdz * bdz
            return ad == bd ? $0.id < $1.id : ad < bd
        }
}

private func skillTreeConsumeArrow(_ player: Player) -> Bool {
    guard player.gameMode != GameMode.creative else { return true }
    for name in ["tipped_arrow", "spectral_arrow", "arrow"] {
        guard let itemID = iidOpt(name), player.countItem(itemID) > 0 else { continue }
        return player.removeItems(itemID, 1)
    }
    return false
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
        // Bows use their ordinary projectile base rather than ToolDef's
        // melee damage. Apply crafted quality before the ranged rank bonus,
        // exactly as `shootBow` does; Power Shot, Volley, and Eagle Eye must
        // not quietly ignore a master-crafted bow.
        let bowBaseDamage = 2 + Double(enchLevel(held, "power")) * 0.5
            + (enchLevel(held, "power") > 0 ? 0.5 : 0)
        damage = skillTreeEffectiveWeaponDamage(
            base: bowBaseDamage, qualityRank: held.data.craftingQuality ?? 0
        ) * skillTreeWeaponDamageMultiplier(primaryRank: trees.ranged.primaryRank)
    case .none:
        return 0
    }
    return max(0, damage)
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

private func skillTreeCommitActionState(_ player: Player,
                                        descriptor: SkillTreeActionDescriptor) -> Result<Int, RPGActionFailure> {
    var state = repairRPGCharacterState(player.rpg)
    guard state.skillTrees != nil,
          state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION,
          let sequence = rpgNextActionSequence(state) else {
        return .failure(.authorityExhausted)
    }
    if descriptor.cooldownTicks > 0 {
        let others = state.activeCooldowns.filter { $0.id != descriptor.id.rawValue }
        guard others.count < RPG_MAX_COOLDOWNS else { return .failure(.boundedStateLimit) }
        state.activeCooldowns = others
        state.activeCooldowns.append(RPGCooldown(id: descriptor.id.rawValue,
                                                 remainingTicks: descriptor.cooldownTicks))
    }
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
    guard case .success(let sequence) = skillTreeCommitActionState(player, descriptor: descriptor) else {
        return .failure(.authorityExhausted)
    }
    guard player.gameMode == GameMode.creative || player.removeItems(materialID, 1) else {
        return .failure(.missingMaterial(materialName))
    }
    let base = max(1, Int((Double(maximum) / 4).rounded(.up)))
    let repair = skillTreeEffectiveRepairAmount(base: base,
                                                qualityRank: player.skillTreeState.crafting.progress.advancedRank)
    held.damage = max(0, held.damage - repair)
    player.world.hooks.playSound("block.anvil.use", player.x, player.y, player.z, 0.8, 1.15)
    return .success(RPGActionResult(actionID: descriptor.id.rawValue, sequence: sequence,
                                    message: "Field-repaired \(itemDef(held.id).displayName)"))
}

/// Executes one unlocked fast-bar action.  It verifies actor authority,
/// equipment, target line-of-sight, cooldown, and bounded sequence before
/// mutating the world.  No class game rule is consulted: the tree is the
/// authoritative advancement system for envelopes that contain it.
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
    guard !state.activeCooldowns.contains(where: { $0.id == id.rawValue && $0.remainingTicks > 0 }) else {
        return .failure(.skillOnCooldown(id.rawValue))
    }
    guard state.authorityRevision < RPG_MAX_NORMAL_AUTHORITY_REVISION,
          rpgNextActionSequence(state) != nil else { return .failure(.authorityExhausted) }
    // Preflight the bounded cooldown write before any target, item, or world
    // mutation.  A malformed-but-repaired envelope can legitimately carry a
    // full cooldown list; in that case an action must fail atomically rather
    // than damage/push a target and only then discover it cannot record its
    // own cooldown.
    if descriptor.cooldownTicks > 0,
       state.activeCooldowns.filter({ $0.id != descriptor.id.rawValue }).count >= RPG_MAX_COOLDOWNS {
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
    if descriptor.equipment == .bow, player.gameMode != GameMode.creative,
       !["tipped_arrow", "spectral_arrow", "arrow"].contains(where: {
           iidOpt($0).map { player.countItem($0) > 0 } ?? false
       }) {
        return .failure(.missingMaterial("arrow"))
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
    var affected: [LivingEntity] = []
    var didWork = false
    switch id {
    case .stunEnemy, .pinningShot:
        guard let primary else { return .failure(.noTarget(id.rawValue)) }
        primary.skillTreeStunTicks = max(primary.skillTreeStunTicks, descriptor.stunDurationTicks)
        primary.skillTreeStunProne = true
        primary.sneaking = true
        primary.vx = 0; primary.vz = 0
        affected = [primary]
        didWork = true
    case .spartanKick, .powerShot:
        guard let primary else { return .failure(.noTarget(id.rawValue)) }
        didWork = primary.hurt(damage * descriptor.weaponDamageMultiplier,
                               "skill_tree_\(id.rawValue)", player)
        if didWork {
            let look = skillTreeActionLookVector(player)
            // `move` performs a swept collision check and respects finite-map
            // bounds, so a kick cannot phase an entity through geometry.
            primary.move(look.dx * Double(descriptor.pushDistanceBlocks), 0,
                         look.dz * Double(descriptor.pushDistanceBlocks))
            primary.vx = 0; primary.vz = 0
            affected = [primary]
        }
    case .roundHouse:
        let targets = skillTreeSortedHostileTargets(near: player.x, y: player.centerY(), z: player.z,
                                                    radius: 3, excluding: player)
        for target in targets.prefix(16) where target.hurt(damage, "skill_tree_round_house", player) {
            affected.append(target)
        }
        didWork = !affected.isEmpty
    case .volley:
        guard let primary else { return .failure(.noTarget(id.rawValue)) }
        let targets = skillTreeSortedHostileTargets(near: primary.x, y: primary.centerY(), z: primary.z,
                                                    radius: 3.5, excluding: player)
        for target in targets.prefix(16) where target.hurt(damage, "skill_tree_volley", player) {
            affected.append(target)
        }
        didWork = !affected.isEmpty
    case .disarmEnemy, .disarmingShot:
        guard let primary else { return .failure(.noTarget(id.rawValue)) }
        didWork = skillTreeDisarm(primary)
        affected = didWork ? [primary] : []
    case .battleCry, .eagleEye:
        guard let primary else { return .failure(.noTarget(id.rawValue)) }
        didWork = primary.hurt(damage * descriptor.weaponDamageMultiplier,
                               "skill_tree_\(id.rawValue)", player)
        affected = didWork ? [primary] : []
    case .fieldRepair:
        return skillTreeFieldRepair(player, descriptor: descriptor)
    }
    guard didWork else { return .failure(.noEffect(descriptor.displayName)) }
    // Advanced techniques are still actual sword/bow use against a qualifying
    // living target. Award once per committed technique, rather than once per
    // AoE victim, so using an unlocked move advances the matching tree without
    // turning grouped enemies into an XP multiplier.
    switch descriptor.equipment {
    case .sword:
        _ = skillTreeAwardMeleeHit(player, successfulSwordDamage: true)
    case .bow:
        _ = skillTreeAwardRangedHit(player, successfulBowDamage: true)
    case .none:
        break
    }
    if descriptor.equipment == .bow, !skillTreeConsumeArrow(player) {
        return .failure(.missingMaterial("arrow"))
    }
    player.damageHeld(1)
    guard case .success(let sequence) = skillTreeCommitActionState(player, descriptor: descriptor) else {
        return .failure(.authorityExhausted)
    }
    player.world.hooks.playSound(descriptor.equipment == .bow ? "entity.arrow.shoot" : "entity.player.attack.strong",
                                 player.x, player.y, player.z, 0.9, 1)
    return .success(RPGActionResult(actionID: descriptor.id.rawValue, sequence: sequence,
                                    message: "Used \(descriptor.displayName)",
                                    targetEntityID: affected.first?.id))
}
