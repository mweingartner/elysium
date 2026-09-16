import XCTest
@testable import ElysiumCore

final class SkillTreeProgressionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        if craftingRecipes.isEmpty { registerAllRecipes() }
    }

    func testUsageTreesKeepActionFastBarVisibleAfterClassRuleRetires() {
        let world = World(dim: .overworld, seed: 9_021)
        let player = Player(world: world)
        world.gameRules[RPG_CLASSES_GAME_RULE] = 0

        XCTAssertNotNil(player.rpg.skillTrees)
        XCTAssertFalse(player.rpgClassesEnabled())
        XCTAssertTrue(rpgHUDVisible(player))

        let plan = rpgHUDDrawPlan(player, screenOpen: false)
        XCTAssertTrue(plan.showQuickSlots,
                      "unlocked usage techniques need the world-facing fast bar")
        XCTAssertTrue(plan.liftSurvivalHUD)
        XCTAssertFalse(plan.showInsights)
    }

    func testXPIsCanonicalAndAdvancedProgressRequiresPrimaryCap() {
        let forged = SkillTreeBranchState(xp: 0, primaryRank: 5, advancedRank: 5)
        XCTAssertEqual(skillTreeValidatedBranchState(forged), .untrained())

        var branch = SkillTreeBranchState.untrained()
        let primary = skillTreeAwardXP(skillTreePrimaryXPRequired(forRank: 5), to: &branch)
        XCTAssertEqual(primary.awardedXP, 1_000)
        XCTAssertEqual(branch.primaryRank, 5)
        XCTAssertEqual(branch.advancedRank, 0)
        XCTAssertTrue(primary.reachedPrimaryCap)

        let advanced = skillTreeAwardXP(skillTreeAdvancedXPRequired(forRank: 5), to: &branch)
        XCTAssertEqual(branch.advancedRank, 5)
        XCTAssertTrue(advanced.reachedAdvancedCap)
        XCTAssertEqual(branch.xp, skillTreeMaximumXP())
        XCTAssertEqual(skillTreeAwardXP(1, to: &branch).awardedXP, 0)

        XCTAssertEqual(skillTreeBranchState(primaryRank: 4, advancedRank: 5).advancedRank, 0)
        XCTAssertEqual(skillTreeBranchState(primaryRank: 5, advancedRank: 3).advancedRank, 3)
    }

    func testRecipeMasteryIsIndexedCappedAndOnlyCreditsUnmasteredRounds() {
        var crafting = SkillTreeCraftingBranchState(
            progress: .untrained(), recipeMasteryCounts: [255, 50, 9]
        )
        crafting = skillTreeValidatedCraftingBranchState(crafting, recipeCount: 2)
        XCTAssertEqual(crafting.recipeMasteryCounts, [100, 50])

        let completion = skillTreeRecordCraftedRecipe(recipeIndex: 1, completedRounds: 60,
                                                       recipeCount: 2, in: &crafting)
        XCTAssertTrue(completion.accepted)
        XCTAssertEqual(completion.previousCount, 50)
        XCTAssertEqual(completion.count, 100)
        XCTAssertEqual(completion.xpEligibleRounds, 50)
        XCTAssertTrue(completion.masteredNow)

        let repeated = skillTreeRecordCraftedRecipe(recipeIndex: 1, completedRounds: 1,
                                                     recipeCount: 2, in: &crafting)
        XCTAssertTrue(repeated.accepted)
        XCTAssertEqual(repeated.xpEligibleRounds, 0)
        XCTAssertFalse(repeated.masteredNow)

        let invalid = skillTreeRecordCraftedRecipe(recipeIndex: 2, completedRounds: 1,
                                                    recipeCount: 2, in: &crafting)
        XCTAssertFalse(invalid.accepted)
        XCTAssertEqual(crafting.recipeMasteryCounts, [100, 100])
    }

    func testOutputItemMasterySharesCapAcrossAlternateRecipesAndFoldsLegacySlots() throws {
        let mossyID = iid("mossy_cobblestone")
        let indexes = craftingRecipes.enumerated().compactMap { index, recipe in
            craftingRecipeOutput(recipe).id == mossyID ? index : nil
        }
        XCTAssertGreaterThanOrEqual(indexes.count, 2,
                                    "The registry fixture needs two mossy-cobblestone recipes.")
        let first = try XCTUnwrap(indexes.first)
        let second = try XCTUnwrap(indexes.dropFirst().first)
        let firstKey = try XCTUnwrap(craftingOutputMasteryKey(forRecipeIndex: first))
        let secondKey = try XCTUnwrap(craftingOutputMasteryKey(forRecipeIndex: second))
        XCTAssertEqual(firstKey.outputItemID, mossyID)
        XCTAssertEqual(firstKey, secondKey)
        XCTAssertEqual(firstKey.canonicalRecipeIndex, first)
        XCTAssertEqual(firstKey.equivalentRecipeIndices, indexes)

        var crafting = SkillTreeCraftingBranchState.untrained(recipeCount: craftingRecipes.count)
        let firstCommit = skillTreeRecordCraftedRecipe(
            recipeIndex: first,
            completedRounds: 60,
            recipeCount: craftingRecipes.count,
            masteryIndex: firstKey.canonicalRecipeIndex,
            equivalentRecipeIndices: firstKey.equivalentRecipeIndices,
            in: &crafting
        )
        XCTAssertEqual(firstCommit.previousCount, 0)
        XCTAssertEqual(firstCommit.xpEligibleRounds, 60)

        let alternateCommit = skillTreeRecordCraftedRecipe(
            recipeIndex: second,
            completedRounds: 60,
            recipeCount: craftingRecipes.count,
            masteryIndex: secondKey.canonicalRecipeIndex,
            equivalentRecipeIndices: secondKey.equivalentRecipeIndices,
            in: &crafting
        )
        XCTAssertEqual(alternateCommit.previousCount, 60)
        XCTAssertEqual(alternateCommit.count, SKILL_TREE_RECIPE_MASTERY_CAP)
        XCTAssertEqual(alternateCommit.xpEligibleRounds, 40,
                       "The alternate recipe must spend the same output-item allowance.")
        XCTAssertEqual(crafting.recipeMasteryCounts[first], UInt8(SKILL_TREE_RECIPE_MASTERY_CAP))
        XCTAssertEqual(crafting.recipeMasteryCounts[second], 0)

        // Old decoded states may have written both recipe indexes. Their first
        // subsequent committed craft folds the total (bounded) into the same
        // canonical output slot instead of granting another XP allowance.
        var legacy = SkillTreeCraftingBranchState.untrained(recipeCount: craftingRecipes.count)
        legacy.recipeMasteryCounts[first] = 55
        legacy.recipeMasteryCounts[second] = 60
        let folded = skillTreeRecordCraftedRecipe(
            recipeIndex: second,
            completedRounds: 1,
            recipeCount: craftingRecipes.count,
            masteryIndex: secondKey.canonicalRecipeIndex,
            equivalentRecipeIndices: secondKey.equivalentRecipeIndices,
            in: &legacy
        )
        XCTAssertEqual(folded.previousCount, SKILL_TREE_RECIPE_MASTERY_CAP)
        XCTAssertEqual(folded.xpEligibleRounds, 0)
        XCTAssertEqual(legacy.recipeMasteryCounts[first], UInt8(SKILL_TREE_RECIPE_MASTERY_CAP))
        XCTAssertEqual(legacy.recipeMasteryCounts[second], 0)
    }

    func testMiningTableAndBonusUseNoRNGState() {
        XCTAssertEqual(skillTreeMiningResource(blockID: "deepslate_diamond_ore"), .diamond)
        XCTAssertEqual(skillTreeMiningXP(blockID: "coal_ore"), 2)
        XCTAssertEqual(skillTreeMiningXP(blockID: "nether_gold_ore"), 6)
        XCTAssertEqual(skillTreeMiningXP(blockID: "redstone_ore"), 6)
        XCTAssertEqual(skillTreeMiningXP(blockID: "labradorite_ore"), 6)
        XCTAssertEqual(skillTreeMiningXP(blockID: "stone"), 0)
        XCTAssertEqual(skillTreeMiningSpeedMultiplier(primaryRank: 5), 1.5, accuracy: 0.000_001)
        let world = World(dim: .overworld, seed: 0x51B3)
        let player = Player(world: world)
        var miningTrees = SkillTreeState.untrained()
        miningTrees.mining = skillTreeBranchState(primaryRank: 5)
        player.skillTreeState = miningTrees
        XCTAssertEqual(rpgMiningSpeedMultiplier(player, blockID: Int(B.stone)), 1.5,
                       "primary mining speed applies to ordinary excavation as well as ore")
        XCTAssertEqual(rpgMiningSpeedMultiplier(player, blockID: Int(B.dirt)), 1,
                       "the mining tree does not accelerate unrelated soft blocks")
        XCTAssertEqual(skillTreeWeaponDamageMultiplier(primaryRank: 5), 1.5, accuracy: 0.000_001)

        // A supplied stateless 0...9999 roll distributes a 10% rank-one
        // bonus without consuming a world RNG draw.
        XCTAssertEqual(skillTreeMiningBonusDropCount(baseDropCount: 1, advancedRank: 1,
                                                      deterministicRollBasisPoints: 0), 1)
        XCTAssertEqual(skillTreeMiningBonusDropCount(baseDropCount: 1, advancedRank: 1,
                                                      deterministicRollBasisPoints: 9_999), 0)
        XCTAssertEqual(skillTreeMiningBonusDropCount(baseDropCount: 10, advancedRank: 1,
                                                      deterministicRollBasisPoints: 9_999), 1)
    }

    func testMeleeActionsUnlockInAdvancedOrderAndQualityMathIsCentralized() {
        var state = SkillTreeState.untrained()
        state.melee = skillTreeBranchState(primaryRank: 5, advancedRank: 3)
        XCTAssertEqual(skillTreeUnlockedActions(in: state).map(\.id),
                       [.stunEnemy, .spartanKick, .roundHouse])
        XCTAssertFalse(skillTreeActionIsUnlocked(.battleCry, in: state))

        state.melee = skillTreeBranchState(primaryRank: 5, advancedRank: 5)
        let battleCry = skillTreeActionDescriptor(.battleCry)
        XCTAssertEqual(battleCry.cooldownTicks, SKILL_TREE_BATTLE_CRY_COOLDOWN_TICKS)
        XCTAssertEqual(battleCry.weaponDamageMultiplier, 3)
        XCTAssertTrue(skillTreeActionIsUnlocked(.battleCry, in: state))
        XCTAssertEqual(skillTreeActionID(fastbarToken: battleCry.fastbarToken), .battleCry)

        state = SkillTreeState.untrained()
        state.ranged = skillTreeBranchState(primaryRank: 5, advancedRank: 3)
        XCTAssertEqual(skillTreeUnlockedActions(in: state).map(\.id),
                       [.pinningShot, .powerShot, .volley])
        XCTAssertFalse(skillTreeActionIsUnlocked(.eagleEye, in: state))
        let eagleEye = skillTreeActionDescriptor(.eagleEye)
        XCTAssertEqual(eagleEye.equipment, .bow)
        XCTAssertEqual(eagleEye.weaponDamageMultiplier, 3)
        XCTAssertEqual(eagleEye.cooldownTicks, SKILL_TREE_BATTLE_CRY_COOLDOWN_TICKS)
        XCTAssertEqual(SKILL_TREE_ACTION_DESCRIPTORS.map(\.advancedRankRequired),
                       [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 5])
        state.crafting.progress = skillTreeBranchState(primaryRank: 5, advancedRank: 5)
        XCTAssertTrue(skillTreeActionIsUnlocked(.fieldRepair, in: state))

        XCTAssertEqual(skillTreeCraftingSpeedMultiplier(primaryRank: 5), 1.5, accuracy: 0.000_001)
        XCTAssertEqual((0...5).map(skillTreeCraftingBatchRoundLimit), [1, 2, 4, 8, 16, 32])
        XCTAssertEqual(skillTreeCraftingBatchRoundLimit(primaryRank: 99), 32)
        XCTAssertEqual(skillTreeEffectiveMaxDurability(base: 100, qualityRank: 5), 180)
        XCTAssertEqual(skillTreeEffectiveWeaponDamage(base: 8, qualityRank: 5), 10, accuracy: 0.000_001)
        XCTAssertEqual(skillTreeEffectiveRepairAmount(base: 100, qualityRank: 5), 130)
        XCTAssertEqual(skillTreeCraftingXP(for: []), 0)
        XCTAssertEqual(skillTreeCraftingXP(for: [
            SkillTreeCraftingIngredient(rarity: 0, count: 1),
            SkillTreeCraftingIngredient(rarity: 5, count: 2),
        ]), 13)
    }

    func testCraftingResourceRarityUsesConsumedMaterialsRatherThanDisplayRarity() throws {
        let common = try XCTUnwrap(iidOpt("stick"))
        let iron = try XCTUnwrap(iidOpt("iron_ingot"))
        let gold = try XCTUnwrap(iidOpt("gold_ingot"))
        let redstone = try XCTUnwrap(iidOpt("redstone"))
        let diamond = try XCTUnwrap(iidOpt("diamond"))

        XCTAssertEqual(skillTreeCraftingMaterialRarity(for: common), 0)
        XCTAssertGreaterThan(skillTreeCraftingMaterialRarity(for: iron),
                             skillTreeCraftingMaterialRarity(for: common))
        XCTAssertGreaterThan(skillTreeCraftingMaterialRarity(for: gold),
                             skillTreeCraftingMaterialRarity(for: iron))
        XCTAssertGreaterThanOrEqual(skillTreeCraftingMaterialRarity(for: redstone),
                                    skillTreeCraftingMaterialRarity(for: gold))
        XCTAssertGreaterThan(skillTreeCraftingMaterialRarity(for: diamond),
                             skillTreeCraftingMaterialRarity(for: gold))

        let commonXP = skillTreeCraftingXP(for: skillTreeCraftingIngredients(["stick"]))
        let diamondXP = skillTreeCraftingXP(for: skillTreeCraftingIngredients(["diamond"]))
        XCTAssertGreaterThan(diamondXP, commonXP,
                             "rare consumed resources must award more Crafting XP")
    }
}
