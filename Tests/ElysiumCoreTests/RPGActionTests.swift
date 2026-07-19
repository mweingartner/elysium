import XCTest
@testable import ElysiumCore

final class RPGActionTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        registerAllSystems()
    }

    func testPreparedDamageSpellConsumesFatigueAddsCooldownAndHurtsTarget() {
        let world = makeWorld(seed: 1)
        let player = makeArcanist(in: world, starterSpells: ["ignite"])
        player.setPos(0.5, 64, 0.5)
        player.yaw = 0
        player.pitch = 0
        let zombie = Zombie(world: world)
        zombie.setPos(0.5, 64, 5)
        world.addEntity(player)
        world.addEntity(zombie)
        let fatigueBefore = player.rpg.fatigue
        let expectedCost = igniteCost(player.rpg)

        let result = rpgCastPreparedSpell(player, spellID: "ignite")

        guard case .success(let action) = result else {
            return XCTFail("expected spell to cast")
        }
        XCTAssertEqual(action.actionID, "ignite")
        XCTAssertEqual(action.sequence, 1)
        XCTAssertEqual(action.targetEntityID, zombie.id)
        XCTAssertLessThan(zombie.health, zombie.maxHealth)
        XCTAssertGreaterThan(zombie.fireTicks, 0)
        XCTAssertEqual(player.rpg.fatigue, fatigueBefore - expectedCost, accuracy: 0.0001)
        XCTAssertTrue(player.rpg.activeCooldowns.contains { $0.id == "ignite" && $0.remainingTicks > 0 })
    }

    func testSpellRejectsInsufficientFatigueWithoutMutatingSequence() {
        let world = makeWorld(seed: 2)
        let player = makeArcanist(in: world, starterSpells: ["ignite"])
        player.rpg.fatigue = 1
        let expectedCost = igniteCost(player.rpg)

        let result = rpgCastPreparedSpell(player, spellID: "ignite")

        XCTAssertEqual(result.failure, .insufficientFatigue(required: expectedCost, available: 1))
        XCTAssertEqual(player.rpg.actionSequence, 0)
        XCTAssertTrue(player.rpg.activeCooldowns.isEmpty)
    }

    private func igniteCost(_ state: RPGCharacterState) -> Double {
        // Mirrors production effectiveRPGFatigueCost: elemental spells subtract the Spark Weave
        // discount, scale by the focus-cost multiplier, then floor at 0.5 fatigue.
        let base = rpgSpellDefinition("ignite")!.fatigueCost
        let discounted = max(0, base - rpgSkillEffectValue(.sparkWeave, in: state))
        let scaled = discounted * rpgDerivedStats(state).focusCostMultiplier
        return max(0.5, (scaled * 10).rounded(.up) / 10)
    }

    func testMageLightPlacesTorchOnHitFace() {
        let world = makeWorld(seed: 3)
        let player = makeArcanist(in: world, starterSpells: ["mage_light"])
        player.setPos(0.5, 64, 0.5)
        player.yaw = 0
        player.pitch = 0
        world.setBlock(0, 65, 4, Int(cell(B.stone)))

        let result = rpgCastPreparedSpell(player, spellID: "mage_light")

        guard case .success(let action) = result else {
            return XCTFail("expected mage light to cast, got \(String(describing: result.failure))")
        }
        XCTAssertEqual(action.blockPosition, RPGBlockPosition(0, 65, 3))
        XCTAssertEqual(world.getBlock(0, 65, 3) >> 4, Int(B.torch))
    }

    func testPreparedSpellCyclingUpdatesSelectedSpell() {
        let world = makeWorld(seed: 4)
        let player = makeArcanist(in: world, starterSpells: ["ignite", "mage_light"])

        XCTAssertEqual(player.rpg.selectedPreparedSpellID, "ignite")
        XCTAssertEqual(rpgCyclePreparedSpell(player), .selected("mage_light"))
        XCTAssertEqual(player.rpg.selectedPreparedSpellID, "mage_light")
        XCTAssertEqual(rpgCyclePreparedSpell(player), .selected("ignite"))
    }

    func testPreparedActiveSkillUsesUnifiedSelectedAction() {
        let world = makeWorld(seed: 5)
        let player = makeWarden(in: world, starterSkillID: "heavy_cut")
        player.setPos(0.5, 64, 0.5)
        player.yaw = 0
        player.pitch = 0
        let zombie = Zombie(world: world)
        zombie.setPos(0.5, 64, 3.5)
        world.addEntity(player)
        world.addEntity(zombie)
        let fatigueBefore = player.rpg.fatigue

        XCTAssertEqual(rpgSelectedPreparedAction(player.rpg)?.id, "heavy_cut")
        let result = rpgUseSelectedPreparedAction(player)

        guard case .success(let action) = result else {
            return XCTFail("expected active skill to resolve, got \(String(describing: result.failure))")
        }
        XCTAssertEqual(action.actionID, "heavy_cut")
        XCTAssertEqual(action.sequence, 1)
        XCTAssertEqual(action.targetEntityID, zombie.id)
        XCTAssertLessThan(zombie.health, zombie.maxHealth)
        XCTAssertEqual(player.rpg.fatigue, fatigueBefore - 2, accuracy: 0.0001)
        XCTAssertNil(player.rpg.selectedPreparedActionID)
        XCTAssertTrue(player.rpg.activeCooldowns.contains { $0.id == "heavy_cut" && $0.remainingTicks > 0 })
    }

    func testActionQuickSlotUsesSlottedPreparedSpell() {
        let world = makeWorld(seed: 7)
        let player = makeArcanist(in: world, starterSpells: ["ignite", "mage_light"])
        player.setPos(0.5, 64, 0.5)
        player.yaw = 0
        player.pitch = 0
        world.setBlock(0, 65, 4, Int(cell(B.stone)))
        let beforeSelection = player.rpg.selectedPreparedActionID
        let preferences = try! rpgAssignQuickSlot(
            token: rpgPreparedActionToken(kind: .spell, id: "mage_light"), slot: 3,
            preferences: .empty, state: player.rpg).get()

        let result = rpgUseActionQuickSlot(player, slot: 3, preferences: preferences)

        guard case .success(let action) = result else {
            return XCTFail("expected slotted spell to cast, got \(String(describing: result.failure))")
        }
        XCTAssertEqual(action.actionID, "mage_light")
        XCTAssertEqual(player.rpg.selectedPreparedActionID, beforeSelection)
        XCTAssertEqual(world.getBlock(0, 65, 3) >> 4, Int(B.torch))
    }

    func testActionQuickSlotRejectsEmptySlotWithoutMutatingSequence() {
        let world = makeWorld(seed: 8)
        let player = makeArcanist(in: world, starterSpells: ["ignite"])
        XCTAssertEqual(rpgUseActionQuickSlot(
            player, slot: 0, preferences: .empty).failure, .actionNotPrepared)
        XCTAssertEqual(player.rpg.actionSequence, 0)
    }

    func testActiveSkillRejectsPassivePreparedSkillAsAction() {
        let world = makeWorld(seed: 6)
        let player = makeWarden(in: world, starterSkillID: "guard_stance")
        // Guardian's other two starting skills (interpose, anchor_line) are active and would
        // otherwise auto-prepare; unprepare everything to isolate the passive-only scenario.
        for skillID in player.rpg.preparedSkillIDs {
            _ = rpgUnprepareSkill(skillID, in: &player.rpg)
        }

        XCTAssertNil(rpgSelectedPreparedAction(player.rpg))
        XCTAssertEqual(rpgUseSelectedPreparedAction(player).failure, .actionNotPrepared)
    }

    /// Constructs an Arcanist whose known spells are exactly `starterSpells`, by choosing a
    /// starting-skill selection whose rank-1 unlocks are exactly that set (spells come only from
    /// skill ranks -- there is no separate starter-spell input anymore).
    private func makeArcanist(in world: World, starterSpells: [String]) -> Player {
        let player = Player(world: world)
        let branchID: String
        let startingSkillIDs: [String]
        switch Set(starterSpells) {
        case ["ignite"]:
            branchID = "arcanist_elementalist"
            startingSkillIDs = ["spell_formula", "spark_weave", "storm_focus"]
        case ["mage_light"]:
            branchID = "arcanist_ritualist"
            startingSkillIDs = ["ritual_circle", "bound_servant", "ward_scribe"]
        case ["ignite", "mage_light"]:
            branchID = "arcanist_elementalist"
            startingSkillIDs = ["spell_formula", "ritual_circle", "spark_weave"]
        default:
            branchID = "arcanist_elementalist"
            startingSkillIDs = rpgDefaultStartingSkillIDs(pathID: "arcanist")
        }
        let error = player.createRPGCharacter(RPGCreationDraft(
            pathID: "arcanist", branchID: branchID, startingSkillIDs: startingSkillIDs))
        XCTAssertNil(error)
        XCTAssertEqual(Set(player.rpg.knownSpellIDs), Set(starterSpells))
        return player
    }

    private func makeWarden(in world: World, starterSkillID: String) -> Player {
        let player = Player(world: world)
        let branchID = rpgSkillDefinition(starterSkillID)!.branchID
        let startingSkillIDs = rpgBranchDefinition(branchID)!.skillIDs
        let error = player.createRPGCharacter(RPGCreationDraft(
            pathID: "warden", branchID: branchID, startingSkillIDs: startingSkillIDs))
        XCTAssertNil(error)
        return player
    }

    private func makeWorld(seed: UInt32) -> World {
        let world = World(dim: .overworld, seed: seed)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        world.setChunk(chunk)
        return world
    }
}

private extension Result where Failure == RPGActionFailure {
    var failure: RPGActionFailure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
