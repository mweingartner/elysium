// Skill-tree progression — pure, deterministic data and balance helpers.
//
// This module deliberately has no dependency on CharacterProgression, World,
// ItemStack, or Foundation.  It is safe to use at save/LAN/UI boundaries after
// the caller has supplied its own authoritative context.  Gameplay code owns
// event provenance (successful hit, valid harvest, host authority, and so on);
// these helpers only normalize state and calculate the resulting progression.

public let SKILL_TREE_PRIMARY_RANK_CAP = 5
public let SKILL_TREE_ADVANCED_RANK_CAP = 5
public let SKILL_TREE_RECIPE_MASTERY_CAP = 100
/// A hard payload bound for the indexed recipe ledger.  Callers should pass
/// their registered recipe count, which is then clamped to this ceiling.
public let SKILL_TREE_MAX_RECIPE_MASTERY_ENTRIES = 4_096
public let SKILL_TREE_BASIS_POINTS = 10_000

/// Cumulative XP required for primary ranks 0...5.  The table is intentionally
/// public so balance can be tuned without changing state semantics.
public let SKILL_TREE_PRIMARY_XP_THRESHOLDS = [0, 100, 250, 450, 700, 1_000]
/// Additional cumulative XP after primary rank five required for advanced
/// ranks 0...5.  Advanced progression is unavailable until primary is maxed.
public let SKILL_TREE_ADVANCED_XP_THRESHOLDS = [0, 200, 450, 750, 1_100, 1_500]

/// Fixed simulation timing for the mechanics specified in the first melee
/// advanced tree.  A normal simulation runs at 20 ticks per second.
public let SKILL_TREE_STUN_DURATION_TICKS = 600
public let SKILL_TREE_BATTLE_CRY_COOLDOWN_TICKS = 2_400

/// The four independently-progressing trees.  This is intentionally separate
/// from old class/path identifiers so a migration can store it in any envelope.
public enum SkillTreeID: String, CaseIterable, Codable, Hashable {
    case mining
    case melee
    case ranged
    case crafting
}

/// Canonical XP/rank state for a non-crafting branch.  Decoded or untrusted
/// instances must pass through `skillTreeValidatedBranchState(_:)`; ranks are
/// derived from XP there rather than trusted independently.
public struct SkillTreeBranchState: Codable, Equatable, Hashable {
    public var xp: Int
    public var primaryRank: Int
    public var advancedRank: Int

    public init(xp: Int = 0, primaryRank: Int = 0, advancedRank: Int = 0) {
        self.xp = xp
        self.primaryRank = primaryRank
        self.advancedRank = advancedRank
    }

    public static func untrained() -> SkillTreeBranchState {
        SkillTreeBranchState()
    }
}

/// Crafting has the same primary/advanced progression plus a compact, stable
/// ledger.  Its serialized slots retain the historical recipe-index shape for
/// compatibility, but the authoritative slot for an output item is the first
/// recipe that produces it; all alternate recipes fold into that one counter.
/// A value is the number of completed craft rounds that can still grant XP for
/// that item type; it is clamped to 0...100.
public struct SkillTreeCraftingBranchState: Codable, Equatable, Hashable {
    public var progress: SkillTreeBranchState
    public var recipeMasteryCounts: [UInt8]

    public init(progress: SkillTreeBranchState = .untrained(),
                recipeMasteryCounts: [UInt8] = []) {
        self.progress = progress
        self.recipeMasteryCounts = recipeMasteryCounts
    }

    public static func untrained(recipeCount: Int = 0) -> SkillTreeCraftingBranchState {
        SkillTreeCraftingBranchState(progress: .untrained(),
                                     recipeMasteryCounts: Array(
                                        repeating: 0,
                                        count: skillTreeBoundedRecipeCount(recipeCount)))
    }
}

/// The standalone aggregate intended to be embedded in the authoritative
/// player/save/LAN envelope by the caller.
public struct SkillTreeState: Codable, Equatable, Hashable {
    public var mining: SkillTreeBranchState
    public var melee: SkillTreeBranchState
    public var ranged: SkillTreeBranchState
    public var crafting: SkillTreeCraftingBranchState

    public init(mining: SkillTreeBranchState = .untrained(),
                melee: SkillTreeBranchState = .untrained(),
                ranged: SkillTreeBranchState = .untrained(),
                crafting: SkillTreeCraftingBranchState = .untrained()) {
        self.mining = mining
        self.melee = melee
        self.ranged = ranged
        self.crafting = crafting
    }

    public static func untrained(recipeCount: Int = 0) -> SkillTreeState {
        SkillTreeState(crafting: .untrained(recipeCount: recipeCount))
    }
}

/// Result of a bounded XP award.  `awardedXP` can be lower than `requestedXP`
/// at the rank cap and is zero for invalid/non-positive awards.
public struct SkillTreeProgressionReport: Equatable {
    public var requestedXP: Int
    public var awardedXP: Int
    public var previousPrimaryRank: Int
    public var primaryRank: Int
    public var previousAdvancedRank: Int
    public var advancedRank: Int
    public var reachedPrimaryCap: Bool
    public var reachedAdvancedCap: Bool

    public init(requestedXP: Int, awardedXP: Int,
                previousPrimaryRank: Int, primaryRank: Int,
                previousAdvancedRank: Int, advancedRank: Int,
                reachedPrimaryCap: Bool, reachedAdvancedCap: Bool) {
        self.requestedXP = requestedXP
        self.awardedXP = awardedXP
        self.previousPrimaryRank = previousPrimaryRank
        self.primaryRank = primaryRank
        self.previousAdvancedRank = previousAdvancedRank
        self.advancedRank = advancedRank
        self.reachedPrimaryCap = reachedPrimaryCap
        self.reachedAdvancedCap = reachedAdvancedCap
    }
}

@inline(__always)
public func skillTreeClampPrimaryRank(_ rank: Int) -> Int {
    max(0, min(SKILL_TREE_PRIMARY_RANK_CAP, rank))
}

@inline(__always)
public func skillTreeClampAdvancedRank(_ rank: Int) -> Int {
    max(0, min(SKILL_TREE_ADVANCED_RANK_CAP, rank))
}

public func skillTreePrimaryXPRequired(forRank rank: Int) -> Int {
    SKILL_TREE_PRIMARY_XP_THRESHOLDS[skillTreeClampPrimaryRank(rank)]
}

public func skillTreeAdvancedXPRequired(forRank rank: Int) -> Int {
    SKILL_TREE_ADVANCED_XP_THRESHOLDS[skillTreeClampAdvancedRank(rank)]
}

public func skillTreeMaximumXP() -> Int {
    skillTreePrimaryXPRequired(forRank: SKILL_TREE_PRIMARY_RANK_CAP)
        + skillTreeAdvancedXPRequired(forRank: SKILL_TREE_ADVANCED_RANK_CAP)
}

@inline(__always)
public func skillTreeClampXP(_ xp: Int) -> Int {
    max(0, min(skillTreeMaximumXP(), xp))
}

public func skillTreePrimaryRank(forXP rawXP: Int) -> Int {
    let xp = skillTreeClampXP(rawXP)
    for rank in stride(from: SKILL_TREE_PRIMARY_RANK_CAP, through: 0, by: -1) {
        if xp >= skillTreePrimaryXPRequired(forRank: rank) { return rank }
    }
    return 0
}

public func skillTreeAdvancedRank(forXP rawXP: Int) -> Int {
    let xp = skillTreeClampXP(rawXP)
    guard skillTreePrimaryRank(forXP: xp) == SKILL_TREE_PRIMARY_RANK_CAP else { return 0 }
    let advancedXP = max(0, xp - skillTreePrimaryXPRequired(forRank: SKILL_TREE_PRIMARY_RANK_CAP))
    for rank in stride(from: SKILL_TREE_ADVANCED_RANK_CAP, through: 0, by: -1) {
        if advancedXP >= skillTreeAdvancedXPRequired(forRank: rank) { return rank }
    }
    return 0
}

/// Canonicalizes a branch by treating XP as authoritative.  This intentionally
/// strips independently forged rank fields from decoded state.
public func skillTreeValidatedBranchState(_ raw: SkillTreeBranchState) -> SkillTreeBranchState {
    let xp = skillTreeClampXP(raw.xp)
    return SkillTreeBranchState(xp: xp,
                                primaryRank: skillTreePrimaryRank(forXP: xp),
                                advancedRank: skillTreeAdvancedRank(forXP: xp))
}

/// Creates canonical progress from ranks for a trusted migration.  Advanced
/// ranks are ignored until primary rank five has been reached.
public func skillTreeBranchState(primaryRank rawPrimaryRank: Int,
                                 advancedRank rawAdvancedRank: Int = 0) -> SkillTreeBranchState {
    let primaryRank = skillTreeClampPrimaryRank(rawPrimaryRank)
    let advancedRank = primaryRank == SKILL_TREE_PRIMARY_RANK_CAP
        ? skillTreeClampAdvancedRank(rawAdvancedRank) : 0
    let xp = skillTreePrimaryXPRequired(forRank: primaryRank)
        + (primaryRank == SKILL_TREE_PRIMARY_RANK_CAP
            ? skillTreeAdvancedXPRequired(forRank: advancedRank) : 0)
    return skillTreeValidatedBranchState(SkillTreeBranchState(xp: xp,
                                                               primaryRank: primaryRank,
                                                               advancedRank: advancedRank))
}

@discardableResult
public func skillTreeAwardXP(_ rawAward: Int,
                             to state: inout SkillTreeBranchState) -> SkillTreeProgressionReport {
    let before = skillTreeValidatedBranchState(state)
    state = before
    let requested = max(0, rawAward)
    let available = max(0, skillTreeMaximumXP() - before.xp)
    let awarded = min(requested, available)
    if awarded > 0 {
        state = skillTreeValidatedBranchState(SkillTreeBranchState(
            xp: before.xp + awarded,
            primaryRank: before.primaryRank,
            advancedRank: before.advancedRank
        ))
    }
    return SkillTreeProgressionReport(
        requestedXP: requested,
        awardedXP: awarded,
        previousPrimaryRank: before.primaryRank,
        primaryRank: state.primaryRank,
        previousAdvancedRank: before.advancedRank,
        advancedRank: state.advancedRank,
        reachedPrimaryCap: before.primaryRank < SKILL_TREE_PRIMARY_RANK_CAP
            && state.primaryRank == SKILL_TREE_PRIMARY_RANK_CAP,
        reachedAdvancedCap: before.advancedRank < SKILL_TREE_ADVANCED_RANK_CAP
            && state.advancedRank == SKILL_TREE_ADVANCED_RANK_CAP
    )
}

@discardableResult
public func skillTreeAwardXP(_ award: Int, to tree: SkillTreeID,
                             in state: inout SkillTreeState) -> SkillTreeProgressionReport {
    switch tree {
    case .mining: return skillTreeAwardXP(award, to: &state.mining)
    case .melee: return skillTreeAwardXP(award, to: &state.melee)
    case .ranged: return skillTreeAwardXP(award, to: &state.ranged)
    case .crafting: return skillTreeAwardXP(award, to: &state.crafting.progress)
    }
}

public func skillTreeBoundedRecipeCount(_ rawRecipeCount: Int) -> Int {
    max(0, min(SKILL_TREE_MAX_RECIPE_MASTERY_ENTRIES, rawRecipeCount))
}

/// Normalizes the serialized craft ledger to the current registry size.
/// Registry order must remain stable across compatible releases, just like
/// other game registries.  Output-equivalent legacy slots are folded at the
/// authoritative craft boundary, where the caller can supply the current
/// registry's deterministic output mapping.
public func skillTreeValidatedCraftingBranchState(_ raw: SkillTreeCraftingBranchState,
                                                  recipeCount rawRecipeCount: Int) -> SkillTreeCraftingBranchState {
    let recipeCount = skillTreeBoundedRecipeCount(rawRecipeCount)
    var counts = Array(raw.recipeMasteryCounts.prefix(recipeCount))
    counts = counts.map { UInt8(min(SKILL_TREE_RECIPE_MASTERY_CAP, Int($0))) }
    if counts.count < recipeCount {
        counts.append(contentsOf: repeatElement(0, count: recipeCount - counts.count))
    }
    return SkillTreeCraftingBranchState(progress: skillTreeValidatedBranchState(raw.progress),
                                        recipeMasteryCounts: counts)
}

public func skillTreeValidatedState(_ raw: SkillTreeState,
                                    recipeCount: Int) -> SkillTreeState {
    SkillTreeState(mining: skillTreeValidatedBranchState(raw.mining),
                   melee: skillTreeValidatedBranchState(raw.melee),
                   ranged: skillTreeValidatedBranchState(raw.ranged),
                   crafting: skillTreeValidatedCraftingBranchState(raw.crafting,
                                                                   recipeCount: recipeCount))
}

public struct SkillTreeRecipeMasteryReport: Equatable {
    public var accepted: Bool
    public var recipeIndex: Int
    public var previousCount: Int
    public var count: Int
    /// Completed craft rounds that were still eligible for XP before the cap.
    public var xpEligibleRounds: Int
    public var masteredNow: Bool

    public init(accepted: Bool, recipeIndex: Int, previousCount: Int,
                count: Int, xpEligibleRounds: Int, masteredNow: Bool) {
        self.accepted = accepted
        self.recipeIndex = recipeIndex
        self.previousCount = previousCount
        self.count = count
        self.xpEligibleRounds = xpEligibleRounds
        self.masteredNow = masteredNow
    }
}

/// Records actual committed craft rounds.  Invalid indices or non-positive
/// round counts never consume a mastery slot.  `masteryIndex` and
/// `equivalentRecipeIndices` permit the crafting boundary to use a canonical
/// output-item slot and fold any decoded pre-canonical alternatives into it.
/// The state is still normalized so malformed saved counters cannot survive a
/// later write.
@discardableResult
public func skillTreeRecordCraftedRecipe(recipeIndex: Int, completedRounds: Int,
                                         recipeCount: Int,
                                         masteryIndex: Int? = nil,
                                         equivalentRecipeIndices: [Int] = [],
                                         in state: inout SkillTreeCraftingBranchState) -> SkillTreeRecipeMasteryReport {
    state = skillTreeValidatedCraftingBranchState(state, recipeCount: recipeCount)
    guard recipeIndex >= 0, recipeIndex < state.recipeMasteryCounts.count,
          completedRounds > 0 else {
        return SkillTreeRecipeMasteryReport(accepted: false, recipeIndex: recipeIndex,
                                            previousCount: 0, count: 0,
                                            xpEligibleRounds: 0, masteredNow: false)
    }

    // The default preserves the old one-recipe caller contract.  For a shared
    // output item, normalize the supplied bounded aliases into ascending order
    // and keep the lowest one as the durable canonical slot.  This avoids an
    // unordered collection influencing persisted state.
    var aliases: [Int] = []
    let preferredIndex = masteryIndex ?? recipeIndex
    if preferredIndex >= 0 && preferredIndex < state.recipeMasteryCounts.count {
        aliases.append(preferredIndex)
    }
    for index in equivalentRecipeIndices
        where index >= 0 && index < state.recipeMasteryCounts.count && !aliases.contains(index) {
        aliases.append(index)
    }
    if !aliases.contains(recipeIndex) { aliases.append(recipeIndex) }
    aliases.sort()
    guard let canonicalIndex = aliases.first else {
        return SkillTreeRecipeMasteryReport(accepted: false, recipeIndex: recipeIndex,
                                            previousCount: 0, count: 0,
                                            xpEligibleRounds: 0, masteredNow: false)
    }

    // A prior build stored alternatives separately.  Fold their bounded
    // values exactly once when the output is next crafted, cap the aggregate,
    // and clear aliases so an alternate ingredient recipe cannot reopen XP.
    var total = 0
    for index in aliases {
        total = min(SKILL_TREE_RECIPE_MASTERY_CAP,
                    total + Int(state.recipeMasteryCounts[index]))
    }
    let before = total
    let eligibleRounds = min(SKILL_TREE_RECIPE_MASTERY_CAP - before, completedRounds)
    let after = before + max(0, eligibleRounds)
    for index in aliases where index != canonicalIndex {
        state.recipeMasteryCounts[index] = 0
    }
    state.recipeMasteryCounts[canonicalIndex] = UInt8(after)
    return SkillTreeRecipeMasteryReport(
        accepted: true,
        recipeIndex: recipeIndex,
        previousCount: before,
        count: after,
        xpEligibleRounds: max(0, eligibleRounds),
        masteredNow: before < SKILL_TREE_RECIPE_MASTERY_CAP && after == SKILL_TREE_RECIPE_MASTERY_CAP
    )
}

/// Existing and future mineral resource categories.  `labradorite` is a
/// progression-table entry only; it does not create a block/item/worldgen asset.
public enum SkillTreeMiningResource: String, CaseIterable, Codable, Hashable {
    case coal
    case copper
    case iron
    case netherQuartz = "nether_quartz"
    case netherGold = "nether_gold"
    case lapis
    case amethyst
    case gold
    case redstone
    case emerald
    case diamond
    case ancientDebris = "ancient_debris"
    case labradorite
}

/// Converts the current block-registry names (including deepslate variants)
/// to a resource category.  Unknown blocks deliberately receive no mining XP.
public func skillTreeMiningResource(blockID: String) -> SkillTreeMiningResource? {
    switch blockID {
    case "coal_ore", "deepslate_coal_ore": return .coal
    case "copper_ore", "deepslate_copper_ore": return .copper
    case "iron_ore", "deepslate_iron_ore": return .iron
    case "nether_quartz_ore": return .netherQuartz
    case "nether_gold_ore": return .netherGold
    case "lapis_ore", "deepslate_lapis_ore": return .lapis
    case "amethyst_cluster": return .amethyst
    case "gold_ore", "deepslate_gold_ore": return .gold
    case "redstone_ore", "deepslate_redstone_ore": return .redstone
    case "emerald_ore", "deepslate_emerald_ore": return .emerald
    case "diamond_ore", "deepslate_diamond_ore": return .diamond
    case "ancient_debris": return .ancientDebris
    case "labradorite_ore", "deepslate_labradorite_ore": return .labradorite
    default: return nil
    }
}

/// Per successful harvested block.  Every current ore earns at least one
/// point; gem-like and specifically requested high-value resources earn more.
public func skillTreeMiningXP(for resource: SkillTreeMiningResource) -> Int {
    switch resource {
    case .coal, .copper, .iron, .netherQuartz:
        return 2
    case .lapis, .amethyst, .emerald:
        return 4
    case .gold, .netherGold, .redstone, .diamond, .ancientDebris, .labradorite:
        return 6
    }
}

public func skillTreeMiningXP(blockID: String) -> Int {
    skillTreeMiningResource(blockID: blockID).map(skillTreeMiningXP(for:)) ?? 0
}

/// Five 10-percent speed steps, matching the existing Delver speed cadence but
/// independent of class state.
public func skillTreeMiningSpeedMultiplier(primaryRank: Int) -> Double {
    1 + Double(skillTreeClampPrimaryRank(primaryRank)) * 0.10
}

/// Five 10-percent yield-bonus steps.  The caller supplies a deterministic
/// basis-point roll (for example, a stateless hash of seed/block/player), so
/// this function neither owns nor advances a simulation RNG stream.
public func skillTreeMiningBonusDropCount(baseDropCount rawBaseDropCount: Int,
                                          advancedRank: Int,
                                          deterministicRollBasisPoints rawRoll: Int) -> Int {
    let baseDropCount = max(0, min(4_096, rawBaseDropCount))
    let bonusBasisPoints = skillTreeClampAdvancedRank(advancedRank) * 1_000
    guard baseDropCount > 0, bonusBasisPoints > 0 else { return 0 }
    let numerator = baseDropCount * bonusBasisPoints
    let guaranteed = numerator / SKILL_TREE_BASIS_POINTS
    let remainder = numerator % SKILL_TREE_BASIS_POINTS
    let roll = max(0, min(SKILL_TREE_BASIS_POINTS - 1, rawRoll))
    return guaranteed + (roll < remainder ? 1 : 0)
}

/// Successful-damage awards.  Callers must first establish the relevant weapon
/// and target conditions; a swing, miss, or blocked hit should pass `false`.
public func skillTreeMeleeXP(successfulSwordDamage: Bool) -> Int {
    successfulSwordDamage ? 4 : 0
}

public func skillTreeRangedXP(successfulBowDamage: Bool) -> Int {
    successfulBowDamage ? 4 : 0
}

/// Five ten-percent weapon-damage steps. This scales only the equipped
/// weapon's base contribution; enchantments, criticals, and special-move
/// multipliers are applied by combat afterwards.
public func skillTreeWeaponDamageMultiplier(primaryRank: Int) -> Double {
    1 + Double(skillTreeClampPrimaryRank(primaryRank)) * 0.10
}

/// Ingredient information extracted by the crafting system after tags are
/// resolved.  Rarity is intentionally a scalar so this pure layer does not
/// depend on the item registry's concrete representation.
public struct SkillTreeCraftingIngredient: Codable, Equatable, Hashable {
    public var rarity: Int
    public var count: Int

    public init(rarity: Int, count: Int) {
        self.rarity = rarity
        self.count = count
    }
}

/// XP for one committed craft round.  A rarity tier contributes progressively
/// more, while ingredient count matters without allowing malformed recipes to
/// overflow an award.  The caller multiplies this by the report's
/// `xpEligibleRounds`, never the requested batch size.
public func skillTreeCraftingXP(for ingredients: [SkillTreeCraftingIngredient]) -> Int {
    var total = 0
    for ingredient in ingredients.prefix(64) {
        let rarity = max(0, min(5, ingredient.rarity))
        let count = max(0, min(64, ingredient.count))
        let contribution = count * (1 + rarity)
        total = min(skillTreeMaximumXP(), total + contribution)
    }
    return total
}

/// Multiplies a per-round crafting award by the accepted unmastered rounds.
/// This is bounded to a single tree's remaining useful XP rather than an
/// unbounded batch total.
public func skillTreeCraftingXP(for ingredients: [SkillTreeCraftingIngredient],
                                eligibleRounds: Int) -> Int {
    let rounds = max(0, min(SKILL_TREE_RECIPE_MASTERY_CAP, eligibleRounds))
    guard rounds > 0 else { return 0 }
    let perRound = skillTreeCraftingXP(for: ingredients)
    return min(skillTreeMaximumXP(), perRound * rounds)
}

/// Fastbar-ready advanced melee and ranged actions.  Each tree unlocks one
/// descriptor at advanced ranks one through five.
public enum SkillTreeActionID: String, CaseIterable, Codable, Hashable {
    case stunEnemy = "melee_stun_enemy"
    case spartanKick = "melee_spartan_kick"
    case roundHouse = "melee_round_house"
    case disarmEnemy = "melee_disarm_enemy"
    case battleCry = "melee_battle_cry"
    case pinningShot = "ranged_pinning_shot"
    case powerShot = "ranged_power_shot"
    case volley = "ranged_volley"
    case disarmingShot = "ranged_disarming_shot"
    case eagleEye = "ranged_eagle_eye"
    case fieldRepair = "crafting_field_repair"
}

public enum SkillTreeActionEquipment: String, Codable, Equatable, Hashable {
    case sword
    case bow
    case none
}

public enum SkillTreeActionTargeting: String, Codable, Equatable, Hashable {
    case hostileRay
    case hostileArea
}

/// Declarative mechanics for an action.  Combat integration must apply these
/// through its host-authoritative transaction layer and independently enforce
/// line-of-sight, target validity, collision-safe displacement, and cooldowns.
public struct SkillTreeActionDescriptor: Codable, Equatable, Hashable {
    public var id: SkillTreeActionID
    public var tree: SkillTreeID
    public var displayName: String
    public var advancedRankRequired: Int
    public var equipment: SkillTreeActionEquipment
    public var targeting: SkillTreeActionTargeting
    public var weaponDamageMultiplier: Double
    public var stunDurationTicks: Int
    public var pushDistanceBlocks: Int
    public var disarmsTarget: Bool
    public var cooldownTicks: Int

    public init(id: SkillTreeActionID, tree: SkillTreeID, displayName: String,
                advancedRankRequired: Int, equipment: SkillTreeActionEquipment,
                targeting: SkillTreeActionTargeting, weaponDamageMultiplier: Double,
                stunDurationTicks: Int = 0, pushDistanceBlocks: Int = 0,
                disarmsTarget: Bool = false, cooldownTicks: Int = 0) {
        self.id = id
        self.tree = tree
        self.displayName = displayName
        self.advancedRankRequired = skillTreeClampAdvancedRank(advancedRankRequired)
        self.equipment = equipment
        self.targeting = targeting
        self.weaponDamageMultiplier = weaponDamageMultiplier.isFinite
            ? max(0, weaponDamageMultiplier) : 0
        self.stunDurationTicks = max(0, stunDurationTicks)
        self.pushDistanceBlocks = max(0, pushDistanceBlocks)
        self.disarmsTarget = disarmsTarget
        self.cooldownTicks = max(0, cooldownTicks)
    }

    public var fastbarToken: String { "skilltree.action.\(id.rawValue)" }
    public var iconAssetID: String { "skilltree.action.\(id.rawValue)" }
}

/// Stable descriptor order is advanced rank, then tree.  UI/fastbar code can
/// filter this common registry without losing each tree's rank-order sequence.
public let SKILL_TREE_ACTION_DESCRIPTORS: [SkillTreeActionDescriptor] = [
    SkillTreeActionDescriptor(id: .stunEnemy, tree: .melee, displayName: "Stun Enemy",
                              advancedRankRequired: 1, equipment: .sword, targeting: .hostileRay,
                              weaponDamageMultiplier: 0, stunDurationTicks: SKILL_TREE_STUN_DURATION_TICKS),
    SkillTreeActionDescriptor(id: .pinningShot, tree: .ranged, displayName: "Pinning Shot",
                              advancedRankRequired: 1, equipment: .bow, targeting: .hostileRay,
                              weaponDamageMultiplier: 0, stunDurationTicks: SKILL_TREE_STUN_DURATION_TICKS),
    SkillTreeActionDescriptor(id: .spartanKick, tree: .melee, displayName: "Spartan Kick",
                              advancedRankRequired: 2, equipment: .sword, targeting: .hostileRay,
                              weaponDamageMultiplier: 1.5, pushDistanceBlocks: 5),
    SkillTreeActionDescriptor(id: .powerShot, tree: .ranged, displayName: "Power Shot",
                              advancedRankRequired: 2, equipment: .bow, targeting: .hostileRay,
                              weaponDamageMultiplier: 1.5, pushDistanceBlocks: 5),
    SkillTreeActionDescriptor(id: .roundHouse, tree: .melee, displayName: "Round House",
                              advancedRankRequired: 3, equipment: .sword, targeting: .hostileArea,
                              weaponDamageMultiplier: 1),
    SkillTreeActionDescriptor(id: .volley, tree: .ranged, displayName: "Volley",
                              advancedRankRequired: 3, equipment: .bow, targeting: .hostileArea,
                              weaponDamageMultiplier: 1),
    SkillTreeActionDescriptor(id: .disarmEnemy, tree: .melee, displayName: "Disarm Enemy",
                              advancedRankRequired: 4, equipment: .sword, targeting: .hostileRay,
                              weaponDamageMultiplier: 0, disarmsTarget: true),
    SkillTreeActionDescriptor(id: .disarmingShot, tree: .ranged, displayName: "Disarming Shot",
                              advancedRankRequired: 4, equipment: .bow, targeting: .hostileRay,
                              weaponDamageMultiplier: 0, disarmsTarget: true),
    SkillTreeActionDescriptor(id: .battleCry, tree: .melee, displayName: "Battle Cry",
                              advancedRankRequired: 5, equipment: .sword, targeting: .hostileRay,
                              weaponDamageMultiplier: 3,
                              cooldownTicks: SKILL_TREE_BATTLE_CRY_COOLDOWN_TICKS),
    SkillTreeActionDescriptor(id: .eagleEye, tree: .ranged, displayName: "Eagle Eye",
                              advancedRankRequired: 5, equipment: .bow, targeting: .hostileRay,
                              weaponDamageMultiplier: 3,
                              cooldownTicks: SKILL_TREE_BATTLE_CRY_COOLDOWN_TICKS),
    // Crafting's advanced track is primarily passive quality progression. Its
    // capstone is intentionally an active field repair so a mastered crafter
    // can repair eligible worn gear away from an anvil.
    SkillTreeActionDescriptor(id: .fieldRepair, tree: .crafting, displayName: "Field Repair",
                              advancedRankRequired: 5, equipment: .none, targeting: .hostileRay,
                              weaponDamageMultiplier: 0, cooldownTicks: 600),
]

public func skillTreeActionDescriptor(_ id: SkillTreeActionID) -> SkillTreeActionDescriptor {
    // The enum and descriptor array are deliberately closed.  This fallback is
    // unreachable for shipped IDs and keeps call sites non-optional.
    SKILL_TREE_ACTION_DESCRIPTORS.first { $0.id == id }
        ?? SKILL_TREE_ACTION_DESCRIPTORS[0]
}

public func skillTreeActionID(fastbarToken: String) -> SkillTreeActionID? {
    let prefix = "skilltree.action."
    guard fastbarToken.hasPrefix(prefix) else { return nil }
    return SkillTreeActionID(rawValue: String(fastbarToken.dropFirst(prefix.count)))
}

public func skillTreeActionIsUnlocked(_ id: SkillTreeActionID,
                                      in state: SkillTreeState) -> Bool {
    let descriptor = skillTreeActionDescriptor(id)
    let branch: SkillTreeBranchState
    switch descriptor.tree {
    case .mining: branch = skillTreeValidatedBranchState(state.mining)
    case .melee: branch = skillTreeValidatedBranchState(state.melee)
    case .ranged: branch = skillTreeValidatedBranchState(state.ranged)
    case .crafting: branch = skillTreeValidatedBranchState(state.crafting.progress)
    }
    return branch.primaryRank == SKILL_TREE_PRIMARY_RANK_CAP
        && branch.advancedRank >= descriptor.advancedRankRequired
}

public func skillTreeUnlockedActions(in state: SkillTreeState) -> [SkillTreeActionDescriptor] {
    SKILL_TREE_ACTION_DESCRIPTORS.filter { skillTreeActionIsUnlocked($0.id, in: state) }
}

/// Crafting primary ranks improve throughput.  Quality rank is deliberately an
/// explicit input to the remaining helpers so integration can attach it to the
/// chosen crafting-node/advanced-rank policy without changing item math.
///
/// The existing immediate crafting UI can use this as its maximum committed
/// rounds per request: ranks 0...5 map to 1, 2, 4, 8, 16, and 32 rounds.
/// Input is clamped before indexing so decoded or UI-provided ranks are safe.
public func skillTreeCraftingBatchRoundLimit(primaryRank: Int) -> Int {
    [1, 2, 4, 8, 16, 32][skillTreeClampPrimaryRank(primaryRank)]
}

public func skillTreeCraftingSpeedMultiplier(primaryRank: Int) -> Double {
    1 + Double(skillTreeClampPrimaryRank(primaryRank)) * 0.10
}

/// Quality effects use integer basis points to keep durability calculations
/// deterministic and to make save/UI display independent of floating-point
/// formatting.  Rank 5 is materially better without changing the item registry.
public func skillTreeCraftingDurabilityBonusBasisPoints(qualityRank: Int) -> Int {
    [0, 1_000, 2_000, 3_500, 5_500, 8_000][skillTreeClampPrimaryRank(qualityRank)]
}

public func skillTreeCraftingDamageBonusBasisPoints(qualityRank: Int) -> Int {
    [0, 250, 500, 1_000, 1_500, 2_500][skillTreeClampPrimaryRank(qualityRank)]
}

public func skillTreeCraftingRepairBonusBasisPoints(qualityRank: Int) -> Int {
    [0, 500, 1_000, 1_500, 2_000, 3_000][skillTreeClampPrimaryRank(qualityRank)]
}

private func skillTreeScaledPositiveInt(_ rawBase: Int, bonusBasisPoints: Int) -> Int {
    let base = max(0, rawBase)
    guard base > 0, bonusBasisPoints > 0 else { return base }
    let (product, overflow) = base.multipliedReportingOverflow(by: bonusBasisPoints)
    if overflow { return Int.max }
    let roundedBonus = product / SKILL_TREE_BASIS_POINTS
        + (product % SKILL_TREE_BASIS_POINTS == 0 ? 0 : 1)
    let (result, addOverflow) = base.addingReportingOverflow(roundedBonus)
    return addOverflow ? Int.max : result
}

/// Applies quality to a base maximum durability.  The caller should preserve
/// the item’s damage value and use this same helper everywhere that compares a
/// stack against its break threshold.
public func skillTreeEffectiveMaxDurability(base: Int, qualityRank: Int) -> Int {
    skillTreeScaledPositiveInt(base,
                               bonusBasisPoints: skillTreeCraftingDurabilityBonusBasisPoints(
                                qualityRank: qualityRank))
}

/// Applies quality to the weapon’s registry damage, not total incoming damage.
/// Enchantments, criticals, and special-move multipliers remain separate.
public func skillTreeEffectiveWeaponDamage(base: Double, qualityRank: Int) -> Double {
    guard base.isFinite, base > 0 else { return 0 }
    let bonus = skillTreeCraftingDamageBonusBasisPoints(qualityRank: qualityRank)
    return base * Double(SKILL_TREE_BASIS_POINTS + bonus) / Double(SKILL_TREE_BASIS_POINTS)
}

public func skillTreeEffectiveRepairAmount(base: Int, qualityRank: Int) -> Int {
    skillTreeScaledPositiveInt(base,
                               bonusBasisPoints: skillTreeCraftingRepairBonusBasisPoints(
                                qualityRank: qualityRank))
}
