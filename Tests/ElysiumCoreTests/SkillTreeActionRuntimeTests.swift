import XCTest
@testable import ElysiumCore

final class SkillTreeActionRuntimeTests: XCTestCase {
    private var retainedWorlds: [World] = []

    override func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        registerAllEntities()
        registerAllSystems()
        registerAllRecipes()
    }

    func testTreeActionCooldownTicksWithoutRetiredClassStateAndKeepsSelection() {
        let world = makeWorld(seed: 0x51AC)
        let player = Player(world: world)
        var trees = SkillTreeState.untrained()
        trees.melee = skillTreeBranchState(primaryRank: 5, advancedRank: 5)
        player.skillTreeState = trees
        player.rpg.selectedPreparedActionID = rpgPreparedActionToken(
            kind: .skill, id: SkillTreeActionID.battleCry.rawValue
        )
        player.rpg.activeCooldowns = [RPGCooldown(
            id: SkillTreeActionID.battleCry.rawValue, remainingTicks: 2
        )]

        XCTAssertTrue(rpgTickState(&player.rpg).isEmpty)
        XCTAssertEqual(player.rpg.activeCooldowns, [RPGCooldown(
            id: SkillTreeActionID.battleCry.rawValue, remainingTicks: 1
        )])
        XCTAssertEqual(rpgSelectedPreparedAction(player.rpg)?.id,
                       SkillTreeActionID.battleCry.rawValue)

        XCTAssertTrue(rpgTickState(&player.rpg).isEmpty)
        XCTAssertTrue(player.rpg.activeCooldowns.isEmpty)
        XCTAssertEqual(rpgSelectedPreparedAction(player.rpg)?.id,
                       SkillTreeActionID.battleCry.rawValue,
                       "cooldown expiry must not clear the O/L selection")
    }

    func testLethalOrdinaryBowHitAwardsRangedTreeXP() {
        let world = makeWorld(seed: 0x51AD)
        let player = Player(world: world)
        let cow = Cow(world: world)
        let arrow = ArrowEntity(world: world)
        arrow.owner = player
        arrow.damage = 100
        arrow.vz = 1
        arrow.skillTreeRangedShot = true

        arrow.onHitEntity(cow)

        XCTAssertEqual(player.skillTreeState.ranged.xp,
                       skillTreeRangedXP(successfulBowDamage: true))
    }

    func testLethalOrdinarySwordHitAwardsMeleeTreeXP() {
        let world = makeWorld(seed: 0x51AF)
        let player = Player(world: world)
        player.inventory[0] = ItemStack(iid("iron_sword"), 1)
        player.selectedSlot = 0
        let cow = Cow(world: world)
        cow.health = 1

        playerAttack(player, cow)

        XCTAssertGreaterThan(cow.deathTime, 0)
        XCTAssertEqual(player.skillTreeState.melee.xp,
                       skillTreeMeleeXP(successfulSwordDamage: true),
                       "a successful killing sword hit must count as usage")
    }

    func testGenericStunTickPreservesPhysicsButHaltsActionsAndClearsProneStateAtExpiry() {
        let world = makeWorld(seed: 0x51AE)
        let zombie = Zombie(world: world)
        zombie.setPos(0.5, 64, 0.5)
        zombie.skillTreeStunTicks = 2
        zombie.skillTreeStunProne = true
        zombie.sneaking = true
        zombie.moveForward = 1
        zombie.moveStrafe = 1
        zombie.jumping = true
        zombie.sprinting = true
        zombie.vx = 0.4
        zombie.vz = -0.4

        zombie.tickWhileSkillTreeStunned()

        XCTAssertEqual(zombie.skillTreeStunTicks, 1)
        XCTAssertTrue(zombie.skillTreeStunProne)
        XCTAssertTrue(zombie.sneaking)
        XCTAssertEqual(zombie.moveForward, 0)
        XCTAssertEqual(zombie.moveStrafe, 0)
        XCTAssertFalse(zombie.jumping)
        XCTAssertFalse(zombie.sprinting)
        XCTAssertEqual(zombie.vx, 0, accuracy: 0.000_001)
        XCTAssertEqual(zombie.vz, 0, accuracy: 0.000_001)

        zombie.tickWhileSkillTreeStunned()

        XCTAssertEqual(zombie.skillTreeStunTicks, 0)
        XCTAssertFalse(zombie.skillTreeStunProne)
        XCTAssertFalse(zombie.sneaking,
                       "only the crouch state introduced by stun should clear at expiry")
    }

    func testSuccessfulAdvancedWeaponActionsAwardTheirTreeOnce() throws {
        let meleeWorld = makeWorld(seed: 0x51B0)
        let meleePlayer = Player(world: meleeWorld)
        meleePlayer.setPos(0.5, 64, 0.5)
        meleePlayer.inventory[0] = ItemStack(iid("iron_sword"), 1)
        var meleeTrees = SkillTreeState.untrained()
        meleeTrees.melee = skillTreeBranchState(primaryRank: 5, advancedRank: 2)
        meleePlayer.skillTreeState = meleeTrees
        let meleeTarget = Cow(world: meleeWorld)
        meleeTarget.setPos(0.5, 65, 2.5)
        meleeWorld.addEntity(meleeTarget)
        let meleeXPBeforeAction = meleePlayer.skillTreeState.melee.xp

        _ = try skillTreeExecuteAction(
            meleePlayer, id: .spartanKick, authorization: .local(for: meleePlayer)
        ).get()
        XCTAssertEqual(meleePlayer.skillTreeState.melee.xp - meleeXPBeforeAction,
                       skillTreeMeleeXP(successfulSwordDamage: true))

        let rangedWorld = makeWorld(seed: 0x51B1)
        let rangedPlayer = Player(world: rangedWorld)
        rangedPlayer.setPos(0.5, 64, 0.5)
        rangedPlayer.inventory[0] = ItemStack(iid("bow"), 1)
        rangedPlayer.inventory[1] = ItemStack(iid("arrow"), 1)
        var rangedTrees = SkillTreeState.untrained()
        rangedTrees.ranged = skillTreeBranchState(primaryRank: 5, advancedRank: 2)
        rangedPlayer.skillTreeState = rangedTrees
        let rangedTarget = Cow(world: rangedWorld)
        rangedTarget.setPos(0.5, 65, 2.5)
        rangedWorld.addEntity(rangedTarget)
        let rangedXPBeforeAction = rangedPlayer.skillTreeState.ranged.xp

        _ = try skillTreeExecuteAction(
            rangedPlayer, id: .powerShot, authorization: .local(for: rangedPlayer)
        ).get()
        XCTAssertEqual(rangedPlayer.skillTreeState.ranged.xp - rangedXPBeforeAction,
                       skillTreeRangedXP(successfulBowDamage: true))
        XCTAssertEqual(rangedPlayer.countItem(iid("arrow")), 0)
    }

    func testRoundHouseHitsHostilesAroundThePlayerWithoutCrosshairTarget() throws {
        let world = makeWorld(seed: 0x51B4)
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        player.inventory[0] = ItemStack(iid("iron_sword"), 1)
        var trees = SkillTreeState.untrained()
        trees.melee = skillTreeBranchState(primaryRank: 5, advancedRank: 3)
        player.skillTreeState = trees

        // Default yaw points along +Z in this fixture.  The zombie is at the
        // player's side, so a directional target preflight would miss it.
        let zombie = Zombie(world: world)
        zombie.setPos(2.5, 65, 0.5)
        world.addEntity(zombie)
        let beforeHealth = zombie.health

        let result = try skillTreeExecuteAction(
            player, id: .roundHouse, authorization: .local(for: player)
        ).get()

        XCTAssertEqual(result.actionID, SkillTreeActionID.roundHouse.rawValue)
        XCTAssertEqual(result.targetEntityID, zombie.id)
        XCTAssertLessThan(zombie.health, beforeHealth,
                          "Round House must use its 360-degree target set, not the crosshair")
    }

    func testAdvancedBowActionsHonorCraftedQualityDamage() throws {
        func powerShotDamage(qualityRank: Int?) throws -> Double {
            let world = makeWorld(seed: qualityRank == nil ? 0x51B5 : 0x51B6)
            let player = Player(world: world)
            player.setPos(0.5, 64, 0.5)
            let bow = ItemStack(iid("bow"), 1)
            bow.data.craftingQuality = qualityRank
            player.inventory[0] = bow
            player.inventory[1] = ItemStack(iid("arrow"), 1)
            var trees = SkillTreeState.untrained()
            trees.ranged = skillTreeBranchState(primaryRank: 5, advancedRank: 2)
            player.skillTreeState = trees
            let target = Cow(world: world)
            target.setPos(0.5, 65, 2.5)
            world.addEntity(target)
            let beforeHealth = target.health

            _ = try skillTreeExecuteAction(
                player, id: .powerShot, authorization: .local(for: player)
            ).get()
            return beforeHealth - target.health
        }

        let ordinary = try powerShotDamage(qualityRank: nil)
        let masterCrafted = try powerShotDamage(qualityRank: 5)
        XCTAssertGreaterThan(masterCrafted, ordinary)
        XCTAssertEqual(masterCrafted / ordinary, 1.25, accuracy: 0.000_001,
                       "quality scales the bow base before the tree and Power Shot multipliers")
    }

    @MainActor
    func testLANCycleSelectsTreeActionWithoutChangingHostSequence() throws {
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(
            owner: self, label: "tree-cycle-lan"
        ))
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "tree-cycle", worldName: "Tree Cycle", seed: 0x51B2,
            gameMode: GameMode.survival, difficulty: 2,
            dimension: Dim.overworld.rawValue, playerCount: 2,
            rpgClassesEnabled: false
        ))
        var trees = SkillTreeState.untrained()
        trees.melee = skillTreeBranchState(primaryRank: 5, advancedRank: 1)
        game.player.skillTreeState = trees
        let beforeSequence = game.player.rpg.actionSequence
        let beforeRevision = game.player.rpg.authorityRevision
        var intents: [LANRPGIntent] = []
        game.lanRPGIntentHandler = { intents.append($0) }

        XCTAssertEqual(game.requestRPGCyclePreparedAction(), "Selected Stun Enemy")
        XCTAssertEqual(game.player.rpg.selectedPreparedActionID,
                       rpgPreparedActionToken(kind: .skill,
                                              id: SkillTreeActionID.stunEnemy.rawValue))
        XCTAssertEqual(game.player.rpg.actionSequence, beforeSequence)
        XCTAssertEqual(game.player.rpg.authorityRevision, beforeRevision)
        XCTAssertTrue(intents.isEmpty, "selection is client presentation, not a host mutation")

        XCTAssertEqual(game.requestRPGUseSelectedAction(), "Using Stun Enemy")
        XCTAssertEqual(intents, [LANRPGIntent(
            action: .useSkill,
            skillID: SkillTreeActionID.stunEnemy.rawValue,
            actionSequence: beforeSequence + 1
        )])

        var hostState = game.player.rpg
        hostState.selectedPreparedActionID = nil
        hostState.actionSequence = beforeSequence + 1
        game.applyLANRPGState(hostState)
        XCTAssertEqual(game.player.rpg.selectedPreparedActionID,
                       rpgPreparedActionToken(kind: .skill,
                                              id: SkillTreeActionID.stunEnemy.rawValue),
                       "a host response must not erase client-only tree selection")
    }

    @MainActor
    func testLANFastbarSemanticBridgeEmitsOneHostIntentWithoutMirrorMutation() throws {
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(
            owner: self, label: "tree-fastbar-lan"
        ))
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "tree-fastbar", worldName: "Tree Fastbar", seed: 0x51B7,
            gameMode: GameMode.survival, difficulty: 2,
            dimension: Dim.overworld.rawValue, playerCount: 2,
            rpgClassesEnabled: false
        ))
        var trees = SkillTreeState.untrained()
        trees.melee = skillTreeBranchState(primaryRank: 5, advancedRank: 1)
        game.player.skillTreeState = trees
        let beforeState = game.player.rpg
        var intents: [LANRPGIntent] = []
        game.lanRPGIntentHandler = { intents.append($0) }

        XCTAssertTrue(game.dispatchLANUsageTreeWorldSemanticCommand(.useQuickSlot(0)))
        XCTAssertEqual(intents, [LANRPGIntent(
            action: .useSkill,
            skillID: SkillTreeActionID.stunEnemy.rawValue,
            actionSequence: beforeState.actionSequence + 1
        )])
        XCTAssertEqual(game.player.rpg, beforeState,
                       "fastbar activation must not speculate a LAN combat mutation")
        XCTAssertFalse(game.dispatchLANUsageTreeWorldSemanticCommand(
            .create(RPGCreationDraft(pathID: "warden", starterSkillID: "heavy_cut"))
        ), "the bridge must remain closed to retired class commands")
    }

    private func makeWorld(seed: UInt32) -> World {
        let world = World(dim: .overworld, seed: seed)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        world.setChunk(chunk)
        retainedWorlds.append(world)
        return world
    }
}
