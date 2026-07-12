import XCTest
@testable import PebbleCore

final class RPGSkillPurchaseEvaluationTests: XCTestCase {
    func testFailurePrecedenceAndMutatorParity() throws {
        let uncreated = RPGCharacterState.uncreated()
        XCTAssertEqual(rpgEvaluateSkillPurchase("missing", in: uncreated).failure, .characterNotCreated)

        var state = try XCTUnwrap(rpgScreenFixture(pathID: "warden", branchID: "warden_guardian"))
        XCTAssertEqual(rpgEvaluateSkillPurchase("quick_draw", in: state).failure,
                       .unknownOrCrossPathSkill("quick_draw"))
        state.authorityRevision = RPG_MAX_NORMAL_AUTHORITY_REVISION
        XCTAssertEqual(rpgEvaluateSkillPurchase("guard_stance", in: state).failure,
                       .authorityRevisionExhausted)

        for skill in RPG_SKILL_DEFINITIONS {
            for targetRank in 1...3 {
                let path = try XCTUnwrap(rpgPathDefinition(skill.pathID))
                let otherBranch = path.branchIDs.first { $0 != skill.branchID } ?? skill.branchID
                var candidate = try XCTUnwrap(rpgScreenFixture(pathID: skill.pathID, branchID: otherBranch))
                candidate.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
                candidate.level = RPG_LEVEL_CAP
                candidate.skillRanks[skill.id] = targetRank - 1
                if let node = rpgSkillNodeIndex(skill.id), node > 0,
                   let branch = rpgBranchDefinition(skill.branchID) {
                    candidate.skillRanks[branch.skillIDs[node - 1]] = 2
                }
                candidate = repairRPGCharacterState(candidate)
                let before = candidate
                let evaluation = rpgEvaluateSkillPurchase(skill.id, in: candidate)
                let error = rpgLearnSkill(skill.id, in: &candidate)
                if evaluation.permitted {
                    XCTAssertNil(error, "\(skill.id) rank \(targetRank)")
                    XCTAssertEqual(candidate.skillRanks[skill.id], evaluation.targetRank)
                } else {
                    XCTAssertNotNil(error, "\(skill.id) rank \(targetRank)")
                    XCTAssertEqual(candidate, before, "rejected purchase mutated \(skill.id) rank \(targetRank)")
                }
            }
        }
    }

    func testRoadmapsAndGuidanceAreRegistryDerived() throws {
        for path in RPG_PATH_DEFINITIONS {
            for branchID in path.branchIDs {
                let state = try XCTUnwrap(rpgScreenFixture(pathID: path.id, branchID: branchID))
                let roadmap = try XCTUnwrap(rpgSpecializationRoadmap(branchID: branchID, in: state))
                XCTAssertEqual(roadmap.milestones.map(\.level), [1, 4, 5, 8, 10, 12, 14, 16, 20])
                XCTAssertEqual(roadmap.milestones.map(\.cost), [0, 2, 1, 3, 2, 1, 3, 2, 3])
                XCTAssertEqual(roadmap.milestones.reduce(0) { $0 + $1.cost }, 17)
            }
            let guidance = try XCTUnwrap(rpgLevelOneProgressionGuidance(pathID: path.id))
            XCTAssertEqual(guidance.targetXP, 50)
            let total = guidance.pathID == "tinker"
                ? 4 + guidance.eventCount * guidance.xpPerEvent + guidance.rolloverEventCount * guidance.xpPerEvent
                : guidance.eventCount * guidance.xpPerEvent
            XCTAssertGreaterThanOrEqual(total, guidance.targetXP)
        }
    }

    func testSpecializationImpactUsesProposedPostPurchaseState() throws {
        var state = try XCTUnwrap(rpgScreenFixture(pathID: "warden", branchID: "warden_guardian"))
        state.level = RPG_LEVEL_CAP
        state.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        state.skillRanks["heavy_cut"] = 1
        state = repairRPGCharacterState(state)

        let evaluation = rpgEvaluateSkillPurchase("heavy_cut", in: state)
        XCTAssertTrue(evaluation.permitted)
        XCTAssertEqual(evaluation.targetRank, 2)
        XCTAssertEqual(evaluation.cost, 3)
        XCTAssertEqual(evaluation.specializationImpact.remainingSpecializationCost, 17)
        XCTAssertEqual(evaluation.specializationImpact.totalPointsStillEarnableThroughLevel20, 14)
        XCTAssertFalse(evaluation.specializationImpact.canStillCompleteSelectedSpecialization)

        var mutated = state
        XCTAssertNil(rpgLearnSkill("heavy_cut", in: &mutated))
        XCTAssertFalse(rpgProgressionSummaryProjection(mutated).specializationCanComplete)
    }
}
