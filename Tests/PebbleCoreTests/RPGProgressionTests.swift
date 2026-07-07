import XCTest
@testable import PebbleCore

final class RPGProgressionTests: XCTestCase {
    func testXPLevelingGrantsSkillAndAttributePoints() {
        var state = makeWarden(starterSkillID: "heavy_cut")

        let report = rpgAddXP(rpgXPRequiredForLevel(4), to: &state)

        XCTAssertTrue(report.leveledUp)
        XCTAssertEqual(report.previousLevel, 1)
        XCTAssertEqual(report.newLevel, 4)
        XCTAssertEqual(state.level, 4)
        XCTAssertEqual(rpgAvailableSkillPoints(state), 6)
        XCTAssertEqual(rpgAvailableAttributePoints(state), 1)
    }

    func testLearningSkillConsumesPointAndUnlocksPrerequisiteChain() {
        var state = makeWarden(starterSkillID: "heavy_cut")
        _ = rpgAddXP(rpgXPRequiredForLevel(4), to: &state)

        XCTAssertNil(rpgLearnSkill("charge_break", in: &state))

        XCTAssertEqual(state.skillRanks["charge_break"], 1)
        XCTAssertEqual(rpgAvailableSkillPoints(state), 5)
        XCTAssertEqual(rpgLearnSkill("stagger_chain", in: &state), .insufficientLevel(required: 8))
    }

    func testLearningRejectsCrossPathAndMissingPrerequisite() {
        var state = makeWarden(starterSkillID: "guard_stance")
        _ = rpgAddXP(rpgXPRequiredForLevel(8), to: &state)

        XCTAssertEqual(rpgLearnSkill("quick_draw", in: &state), .unknownSkill("quick_draw"))
        XCTAssertEqual(rpgLearnSkill("charge_break", in: &state), .missingPrerequisite("heavy_cut"))
    }

    func testAttributeSpendUpdatesDerivedStatsAndRejectsWhenSpent() {
        var state = makeWarden(starterSkillID: "guard_stance")
        _ = rpgAddXP(rpgXPRequiredForLevel(4), to: &state)
        let before = rpgDerivedStats(state)

        XCTAssertNil(rpgSpendAttributePoint(.strength, in: &state))

        let after = rpgDerivedStats(state)
        XCTAssertEqual(state.attributes.strength, RPGAttributes.defaultCreation.strength + 1)
        XCTAssertGreaterThan(after.maxHealth, before.maxHealth)
        XCTAssertEqual(rpgSpendAttributePoint(.strength, in: &state), .insufficientAttributePoints)
    }

    func testPreparedSpellAndSkillLimitsAreEnforced() {
        var state = makeArcanist()
        _ = rpgAddXP(rpgXPRequiredForLevel(20), to: &state)
        for id in ["minor_glamour", "ritual_circle", "spark_weave", "false_step", "bound_servant", "storm_focus", "mirror_work", "ward_scribe"] {
            _ = rpgLearnSkill(id, in: &state)
        }

        XCTAssertNil(rpgPrepareSpell("blur", in: &state))
        XCTAssertEqual(rpgPrepareSpell("mend_wounds", in: &state), .spellNotKnown("mend_wounds"))
        XCTAssertNil(rpgPrepareSkill("minor_glamour", in: &state))
        XCTAssertEqual(rpgPrepareSkill("guard_stance", in: &state), .skillNotKnown("guard_stance"))
    }

    func testFatigueRegeneratesAndUpkeepExpiresDeterministically() {
        var state = makeArcanist()
        state.fatigue = 1
        state.activeCooldowns = [RPGCooldown(id: "ignite", remainingTicks: 2)]
        state.activeUpkeeps = [RPGUpkeep(spellID: "blur", ownerSequence: 7, remainingTicks: 2, costPerSecond: 0.1)]
        state.knownSpellIDs.append("blur")
        state.preparedSpellIDs.append("blur")

        rpgTickState(&state)
        XCTAssertEqual(state.activeCooldowns, [RPGCooldown(id: "ignite", remainingTicks: 1)])
        XCTAssertEqual(state.activeUpkeeps.count, 1)

        rpgTickState(&state)
        XCTAssertTrue(state.activeCooldowns.isEmpty)
        XCTAssertTrue(state.activeUpkeeps.isEmpty)
        XCTAssertGreaterThan(state.fatigue, 1)
        XCTAssertLessThanOrEqual(state.fatigue, rpgDerivedStats(state).maxFatigue)
    }

    private func makeWarden(starterSkillID: String) -> RPGCharacterState {
        let result = rpgCreateCharacter(RPGCreationDraft(
            pathID: "warden",
            attributes: .defaultCreation,
            starterSkillID: starterSkillID
        ))
        guard case .success(let state) = result else {
            fatalError("failed to create warden")
        }
        return state
    }

    private func makeArcanist() -> RPGCharacterState {
        let result = rpgCreateCharacter(RPGCreationDraft(
            pathID: "arcanist",
            attributes: .defaultCreation,
            starterSkillID: "spell_formula",
            starterSpellIDs: ["ignite", "blur"]
        ))
        guard case .success(let state) = result else {
            fatalError("failed to create arcanist")
        }
        return state
    }
}
