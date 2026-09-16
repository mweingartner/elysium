import XCTest
@testable import ElysiumCore

final class SkillTreeGameplayIntegrationTests: XCTestCase {
    // Entity.world is unowned. Keeping each world alive for the entire test
    // prevents the test fixture's player or dropped items outliving it.
    private var retainedWorlds: [World] = []

    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        registerAllEntities()
        registerAllSystems()
        registerAllRecipes()
    }

    func testLegacyClassEnvelopeMigratesToCanonicalIndependentTrees() throws {
        var legacy = RPGCharacterState.uncreated()
        legacy.version = 3
        legacy.created = true
        legacy.pathID = "delver"
        legacy.starterSkillID = "vein_reader"
        legacy.specializationBranchID = "delver_excavator"
        legacy.startingSkillIDs = ["vein_reader", "fast_bore", "heavy_cut"]
        legacy.xp = 4_000
        legacy.level = 12
        legacy.skillRanks = [
            "vein_reader": 5,
            "fast_bore": 2,
            "heavy_cut": 5,
            "stagger_chain": 1,
            "quick_draw": 5,
            "steady_aim": 4,
            "crippling_shot": 5,
            "field_mod": 1,
            "tool_tune": 5,
            "quick_repair": 4,
        ]

        let migrated = rpgMigrateLegacyStateToSkillTrees(legacy)
        let trees = try XCTUnwrap(migrated.skillTrees)
        XCTAssertEqual(migrated.version, RPG_STATE_CURRENT_VERSION)
        XCTAssertFalse(migrated.created)
        XCTAssertEqual(migrated.pathID, "")
        XCTAssertTrue(migrated.skillRanks.isEmpty)
        XCTAssertEqual(trees.mining.primaryRank, 5)
        XCTAssertEqual(trees.mining.advancedRank, 2)
        XCTAssertEqual(trees.melee.primaryRank, 5)
        XCTAssertEqual(trees.melee.advancedRank, 1)
        XCTAssertEqual(trees.ranged.primaryRank, 5,
                       "the closest legacy ranged primary rank must survive")
        XCTAssertEqual(trees.ranged.advancedRank, 5)
        XCTAssertEqual(trees.crafting.progress.primaryRank, 5)
        XCTAssertEqual(trees.crafting.progress.advancedRank, 4)

        let decoded = try JSONDecoder().decode(
            RPGCharacterState.self, from: JSONEncoder().encode(migrated)
        )
        XCTAssertEqual(repairRPGCharacterState(decoded), migrated,
                       "the persisted migrated envelope must be a fixed point")
    }

    func testSuccessfulOreBreakAwardsMiningTreeOnlyAfterHarvestGate() {
        let world = makeWorld(seed: 0x51A7)
        let player = Player(world: world)
        player.inventory[0] = ItemStack(iid("iron_pickaxe"), 1)
        player.selectedSlot = 0
        world.setBlock(1, 64, 1, Int(cell(B.diamond_ore)))

        finishBreaking(InteractCtx(world: world, player: player), 1, 64, 1)

        XCTAssertEqual(world.getBlock(1, 64, 1) >> 4, 0)
        XCTAssertEqual(player.skillTreeState.mining.xp, skillTreeMiningXP(blockID: "diamond_ore"))

        player.setGameMode(GameMode.creative)
        world.setBlock(2, 64, 1, Int(cell(B.diamond_ore)))
        finishBreaking(InteractCtx(world: world, player: player), 2, 64, 1)
        XCTAssertEqual(player.skillTreeState.mining.xp, skillTreeMiningXP(blockID: "diamond_ore"),
                       "creative ore breaks must not advance a usage tree")
    }

    func testSwordHitAndProductionCraftCommitAdvanceTheirUsageTrees() throws {
        let world = makeWorld(seed: 0x51A8)
        let player = Player(world: world)
        player.inventory[0] = ItemStack(iid("stone_sword"), 1)
        player.selectedSlot = 0
        let cow = Cow(world: world)
        cow.setPos(0.5, 64, 2.5)

        playerAttack(player, cow)
        XCTAssertEqual(player.skillTreeState.melee.xp, skillTreeMeleeXP(successfulSwordDamage: true),
                       "a successful sword hit on an animal is the combat XP admission path")

        let crafter = Player(world: world)
        var resources: [ItemStack?] = [
            ItemStack(iid("cobblestone"), 2),
            ItemStack(iid("stick"), 1),
        ]
        var grid = [ItemStack?](repeating: nil, count: 9)
        let swordPlan = try XCTUnwrap(craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "stone_sword"
        })
        XCTAssertTrue(populateCraftingGrid(swordPlan, grid: &grid, inventory: &resources))
        let commit = try XCTUnwrap(commitCraftingOutputRounds(
            player: crafter, grid: &grid, gridWidth: 3, gridHeight: 3,
            plan: swordPlan, displayedOutput: swordPlan.output, requestedRounds: 1
        ) { _ in false })

        let expectedXP = skillTreeCraftingXP(for: skillTreeCraftingIngredients(swordPlan.ingredients))
        XCTAssertEqual(commit.completedRounds, 1)
        XCTAssertEqual(commit.progression.awardedXP, expectedXP)
        XCTAssertEqual(crafter.skillTreeState.crafting.progress.xp, expectedXP)
        XCTAssertEqual(crafter.skillTreeState.crafting.recipeMasteryCounts[swordPlan.recipeIndex], 1)
        XCTAssertNil(commit.output.data.craftingQuality,
                     "untrained crafters must not mint a quality marker")
    }

    func testCraftingThroughputIsEnforcedAtTheAuthoritativeCommitBoundary() throws {
        let world = makeWorld(seed: 0x51A8_1)

        func verticalPlankGrid() -> [ItemStack?] {
            var grid = [ItemStack?](repeating: nil, count: 4)
            // Two complete vertical-plank rounds, each producing four sticks.
            grid[0] = ItemStack(iid("oak_planks"), 2)
            grid[2] = ItemStack(iid("oak_planks"), 2)
            return grid
        }

        let novice = Player(world: world)
        var noviceGrid = verticalPlankGrid()
        let novicePlan = try XCTUnwrap(currentCraftingPlan(
            from: noviceGrid, gridWidth: 2, gridHeight: 2
        ))
        XCTAssertEqual(itemDef(novicePlan.output.id).name, "stick")
        let noviceCommit = try XCTUnwrap(commitCraftingOutputRounds(
            player: novice,
            grid: &noviceGrid,
            gridWidth: 2,
            gridHeight: 2,
            plan: novicePlan,
            displayedOutput: novicePlan.output,
            requestedRounds: 2,
            refill: { _ in false }
        ))
        XCTAssertEqual(noviceCommit.completedRounds, 1)
        XCTAssertEqual(noviceCommit.output.count, novicePlan.output.count)

        let master = Player(world: world)
        var trees = SkillTreeState.untrained()
        trees.crafting.progress = skillTreeBranchState(primaryRank: 5)
        master.skillTreeState = trees
        var masterGrid = verticalPlankGrid()
        let masterPlan = try XCTUnwrap(currentCraftingPlan(
            from: masterGrid, gridWidth: 2, gridHeight: 2
        ))
        let displayed = masterPlan.output.copy()
        displayed.count = masterPlan.output.count * 2
        let masterCommit = try XCTUnwrap(commitCraftingOutputRounds(
            player: master,
            grid: &masterGrid,
            gridWidth: 2,
            gridHeight: 2,
            plan: masterPlan,
            displayedOutput: displayed,
            requestedRounds: 2,
            refill: { _ in false }
        ))
        XCTAssertEqual(masterCommit.completedRounds, 2)
        XCTAssertEqual(masterCommit.output.count, displayed.count)
    }

    func testCraftCommitUsesTheMatchedGridRatherThanForgedPlanIngredients() throws {
        let world = makeWorld(seed: 0x51A8_2)
        let player = Player(world: world)
        var grid = [ItemStack?](repeating: nil, count: 4)
        grid[0] = ItemStack(iid("oak_planks"), 1)
        grid[2] = ItemStack(iid("oak_planks"), 1)
        let actualPlan = try XCTUnwrap(currentCraftingPlan(
            from: grid, gridWidth: 2, gridHeight: 2
        ))
        XCTAssertEqual(itemDef(actualPlan.output.id).name, "stick")
        let forgedPlan = CraftingRecipePlan(
            recipeIndex: actualPlan.recipeIndex,
            recipe: actualPlan.recipe,
            output: actualPlan.output,
            ingredients: ["diamond", "diamond", nil, nil]
        )

        let commit = try XCTUnwrap(commitCraftingOutputRounds(
            player: player, grid: &grid, gridWidth: 2, gridHeight: 2,
            plan: forgedPlan, displayedOutput: actualPlan.output, requestedRounds: 1
        ) { _ in false })

        let actualXP = skillTreeCraftingXP(
            for: skillTreeCraftingIngredients(actualPlan.ingredients)
        )
        let forgedXP = skillTreeCraftingXP(
            for: skillTreeCraftingIngredients(forgedPlan.ingredients)
        )
        XCTAssertGreaterThan(forgedXP, actualXP)
        XCTAssertEqual(commit.progression.awardedXP, actualXP)
        XCTAssertEqual(player.skillTreeState.crafting.progress.xp, actualXP,
                       "only resources actually consumed from the matched grid may award Crafting XP")
    }

    func testMasterCrafterFieldRepairConsumesCorrectMaterialAndStartsCooldown() throws {
        let world = makeWorld(seed: 0x51A9)
        let player = Player(world: world)
        var trees = SkillTreeState.untrained()
        trees.crafting.progress = skillTreeBranchState(primaryRank: 5, advancedRank: 5)
        player.skillTreeState = trees
        let sword = ItemStack(iid("iron_sword"), 1, damage: 100)
        player.inventory[0] = sword
        player.inventory[1] = ItemStack(iid("iron_ingot"), 1)
        player.selectedSlot = 0

        let result = try skillTreeExecuteAction(
            player, id: .fieldRepair, authorization: .local(for: player)
        ).get()

        let baseRepair = max(1, Int((Double(maxDamageOf(sword)) / 4).rounded(.up)))
        let expectedRepair = skillTreeEffectiveRepairAmount(base: baseRepair, qualityRank: 5)
        XCTAssertEqual(result.actionID, SkillTreeActionID.fieldRepair.rawValue)
        XCTAssertEqual(sword.damage, max(0, 100 - expectedRepair))
        XCTAssertEqual(player.countItem(iid("iron_ingot")), 0)
        XCTAssertEqual(player.rpg.actionSequence, 1)
        XCTAssertEqual(player.rpg.activeCooldowns.first { $0.id == SkillTreeActionID.fieldRepair.rawValue }?.remainingTicks,
                       skillTreeActionDescriptor(.fieldRepair).cooldownTicks)
        XCTAssertEqual(
            skillTreeExecuteAction(player, id: .fieldRepair, authorization: .local(for: player)).failureValue,
            .skillOnCooldown(SkillTreeActionID.fieldRepair.rawValue)
        )
    }

    func testFullCooldownEnvelopeRejectsFieldRepairBeforeMutatingGearOrInventory() {
        let world = makeWorld(seed: 0x51AB)
        let player = Player(world: world)
        var trees = SkillTreeState.untrained()
        trees.crafting.progress = skillTreeBranchState(primaryRank: 5, advancedRank: 5)
        player.skillTreeState = trees
        let sword = ItemStack(iid("iron_sword"), 1, damage: 100)
        player.inventory[0] = sword
        player.inventory[1] = ItemStack(iid("iron_ingot"), 1)
        player.selectedSlot = 0
        // Decoded state can contain a bounded list of other valid tree
        // cooldowns. It must fail before repair spends material or durability.
        player.rpg.activeCooldowns = Array(repeating: RPGCooldown(
            id: SkillTreeActionID.stunEnemy.rawValue, remainingTicks: 1
        ), count: RPG_MAX_COOLDOWNS)

        XCTAssertEqual(
            skillTreeExecuteAction(player, id: .fieldRepair,
                                   authorization: .local(for: player)).failureValue,
            .boundedStateLimit
        )
        XCTAssertEqual(sword.damage, 100)
        XCTAssertEqual(player.countItem(iid("iron_ingot")), 1)
        XCTAssertEqual(player.rpg.actionSequence, 0)
    }

    func testSelectedTreeActionSurvivesStateRepairForCycleAndUseBindings() {
        let world = makeWorld(seed: 0x51AA)
        let player = Player(world: world)
        var trees = SkillTreeState.untrained()
        trees.melee = skillTreeBranchState(primaryRank: 5, advancedRank: 1)
        player.skillTreeState = trees

        switch rpgCyclePreparedAction(player, direction: 1) {
        case .selected(let action):
            XCTAssertEqual(action.id, SkillTreeActionID.stunEnemy.rawValue)
        default:
            XCTFail("the first unlocked tree action should be selectable")
        }

        let repaired = repairRPGCharacterState(player.rpg)
        XCTAssertEqual(repaired.selectedPreparedActionID,
                       rpgPreparedActionToken(kind: .skill,
                                              id: SkillTreeActionID.stunEnemy.rawValue))
        XCTAssertEqual(rpgSelectedPreparedAction(repaired)?.id,
                       SkillTreeActionID.stunEnemy.rawValue,
                       "repair must not erase the action selected by O/controller before L uses it")
    }

    private func makeWorld(seed: UInt32) -> World {
        let world = World(dim: .overworld, seed: seed)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        world.setChunk(chunk)
        retainedWorlds.append(world)
        return world
    }
}

private extension Result where Failure == RPGActionFailure {
    var failureValue: RPGActionFailure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
