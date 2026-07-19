import XCTest
@testable import ElysiumCore

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
            for targetRank in 1...RPG_SKILL_RANK_CAP {
                let path = try XCTUnwrap(rpgPathDefinition(skill.pathID))
                let otherBranch = path.branchIDs.first { $0 != skill.branchID } ?? skill.branchID
                var candidate = try XCTUnwrap(rpgScreenFixture(pathID: skill.pathID, branchID: otherBranch))
                candidate.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
                candidate.level = RPG_LEVEL_CAP
                candidate.skillRanks[skill.id] = targetRank - 1
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

    /// Node 0's rank 1 is free (the branch's own signature is always a default starting skill);
    /// every other rank in-sub-class costs a flat 1 point.
    func testRoadmapsAndGuidanceAreRegistryDerived() throws {
        for path in RPG_PATH_DEFINITIONS {
            for branchID in path.branchIDs {
                let state = try XCTUnwrap(rpgScreenFixture(pathID: path.id, branchID: branchID))
                let roadmap = try XCTUnwrap(rpgSpecializationRoadmap(branchID: branchID, in: state))
                XCTAssertEqual(roadmap.milestones.map(\.level),
                               [1, 1, 1, 4, 6, 8, 8, 10, 12, 12, 14, 16, 16, 18, 20], branchID)
                XCTAssertEqual(roadmap.milestones.map(\.cost),
                               [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], branchID)
                XCTAssertEqual(roadmap.milestones.reduce(0) { $0 + $1.cost }, 14, branchID)
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
        state = repairRPGCharacterState(state)

        // heavy_cut is warden_vanguard's signature -- off-sub-class here, but it is already a
        // default starting skill (rank 1 free); ranking it up costs the flat off-sub-class rate.
        let evaluation = rpgEvaluateSkillPurchase("heavy_cut", in: state)
        XCTAssertTrue(evaluation.permitted)
        XCTAssertEqual(evaluation.targetRank, 2)
        XCTAssertEqual(evaluation.cost, 2)
        XCTAssertEqual(evaluation.specializationImpact.remainingSpecializationCost, 14)
        XCTAssertEqual(evaluation.specializationImpact.totalPointsStillEarnableThroughLevel20, 23)
        XCTAssertTrue(evaluation.specializationImpact.canStillCompleteSelectedSpecialization)

        var mutated = state
        XCTAssertNil(rpgLearnSkill("heavy_cut", in: &mutated))
        XCTAssertTrue(rpgProgressionSummaryProjection(mutated).specializationCanComplete)
    }
}
