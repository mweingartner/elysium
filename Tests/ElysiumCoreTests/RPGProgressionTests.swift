import XCTest
@testable import ElysiumCore

final class RPGProgressionTests: XCTestCase {
    func testXPLevelingUsesV2CurveAndPointMilestones() {
        var state = makeState(pathID: "warden", starterSkillID: "heavy_cut")

        let report = rpgAddXP(rpgXPRequiredForLevel(4), to: &state)

        XCTAssertTrue(report.leveledUp)
        XCTAssertEqual(report.newLevel, 4)
        XCTAssertEqual(rpgXPRequiredForLevel(20), 7_790)
        XCTAssertEqual(rpgAvailableSkillPoints(state), 3)
        XCTAssertEqual(rpgAvailableAttributePoints(state), 1)
        XCTAssertEqual(rpgEarnedSkillPoints(level: 20), 19)
        XCTAssertEqual(rpgEarnedAttributePoints(level: 20), 6)
    }

    func testSingleFreeStarterTargetRankCostsAndPrerequisiteRankTwo() {
        var state = makeState(pathID: "warden", starterSkillID: "heavy_cut")
        _ = rpgAddXP(rpgXPRequiredForLevel(10), to: &state)

        XCTAssertEqual(rpgSpentSkillPoints(state), 0)
        XCTAssertEqual(rpgSkillPointCost("heavy_cut", targetRank: 1, in: state), 0)
        XCTAssertEqual(rpgSkillPointCost("heavy_cut", targetRank: 2, in: state), 2)
        XCTAssertEqual(rpgSkillPointCost("guard_stance", targetRank: 1, in: state), 2)
        XCTAssertEqual(rpgLearnSkill("charge_break", in: &state), .missingPrerequisite("heavy_cut"))
        XCTAssertNil(rpgLearnSkill("heavy_cut", in: &state))
        XCTAssertNil(rpgLearnSkill("charge_break", in: &state))
        XCTAssertEqual(state.skillRanks["heavy_cut"], 2)
        XCTAssertEqual(state.skillRanks["charge_break"], 1)
        XCTAssertEqual(rpgSpentSkillPoints(state), 3)
    }

    func testAllEighteenBranchesProgressFromLevelOneThroughTwentyWithoutDeadCapPoints() {
        for branch in RPG_BRANCH_DEFINITIONS {
            guard let path = rpgPathDefinition(branch.pathID) else { return XCTFail(branch.id) }
            let starter = branch.skillIDs[0]
            var state = makeState(pathID: path.id, starterSkillID: starter)

            let schedule: [(level: Int, skill: String)] = [
                (4, branch.skillIDs[0]), (5, branch.skillIDs[1]), (8, branch.skillIDs[0]),
                (10, branch.skillIDs[1]), (12, branch.skillIDs[2]), (14, branch.skillIDs[1]),
                (16, branch.skillIDs[2]), (20, branch.skillIDs[2]),
            ]
            for level in 2...RPG_LEVEL_CAP {
                _ = rpgAddXP(max(0, rpgXPRequiredForLevel(level) - state.xp), to: &state)
                for step in schedule where step.level == level {
                    XCTAssertNil(rpgLearnSkill(step.skill, in: &state), "\(branch.id) level \(level)")
                }
            }

            XCTAssertEqual(branch.skillIDs.map { state.skillRanks[$0] ?? 0 }, [3, 3, 3], branch.id)
            XCTAssertEqual(rpgSpentSkillPoints(state), 17, branch.id)
            guard let crossStarter = path.starterSkillIDs.first(where: { $0 != starter }) else {
                return XCTFail("missing cross branch for \(branch.id)")
            }
            XCTAssertNil(rpgLearnSkill(crossStarter, in: &state), branch.id)
            XCTAssertEqual(rpgSpentSkillPoints(state), 19, branch.id)
            XCTAssertEqual(rpgAvailableSkillPoints(state), 0, branch.id)
        }
    }

    func testCrossBranchGatesAreTwoLevelsLater() {
        let state = makeState(pathID: "ranger", starterSkillID: "quick_draw")
        XCTAssertEqual(rpgMinimumLevel(for: "quick_draw", targetRank: 1,
                                       specializationBranchID: state.specializationBranchID), 1)
        XCTAssertEqual(rpgMinimumLevel(for: "trail_sense", targetRank: 1,
                                       specializationBranchID: state.specializationBranchID), 3)
        XCTAssertEqual(rpgMinimumLevel(for: "far_sight", targetRank: 3,
                                       specializationBranchID: state.specializationBranchID), 22)
    }

    func testPassiveSkillsAreAlwaysOnAndOnlyActivesConsumeFourSlots() {
        var state = makeState(pathID: "warden", starterSkillID: "guard_stance")
        XCTAssertTrue(state.preparedSkillIDs.isEmpty)
        XCTAssertEqual(rpgPrepareSkill("guard_stance", in: &state), .skillNotActive("guard_stance"))

        state = makeState(pathID: "warden", starterSkillID: "heavy_cut")
        XCTAssertEqual(state.preparedSkillIDs, ["heavy_cut"])
        XCTAssertEqual(RPG_MAX_PREPARED_SKILLS, 4)
        XCTAssertEqual(RPG_MAX_PREPARED_SPELLS, 6)
    }

    func testFatigueRegeneratesAndUpkeepExpiresDeterministically() {
        var state = makeState(pathID: "arcanist", starterSkillID: "minor_glamour")
        state.fatigue = 1
        state.activeCooldowns = [RPGCooldown(id: "blur", remainingTicks: 2)]
        state.activeUpkeeps = [RPGUpkeep(spellID: "blur", ownerSequence: 7, remainingTicks: 2, costPerSecond: 0.1)]

        rpgTickState(&state)
        XCTAssertEqual(state.activeCooldowns, [RPGCooldown(id: "blur", remainingTicks: 1)])
        XCTAssertEqual(state.activeUpkeeps.count, 1)

        rpgTickState(&state)
        XCTAssertTrue(state.activeCooldowns.isEmpty)
        XCTAssertTrue(state.activeUpkeeps.isEmpty)
        XCTAssertGreaterThan(state.fatigue, 1)
    }

    private func makeState(pathID: String, starterSkillID: String) -> RPGCharacterState {
        let attributes = rpgCreationPreset(pathID: pathID) ?? .defaultCreation
        let result = rpgCreateCharacter(RPGCreationDraft(pathID: pathID,
                                                         attributes: attributes,
                                                         starterSkillID: starterSkillID))
        guard case .success(let state) = result else { fatalError("failed to create \(pathID)") }
        return state
    }
}
