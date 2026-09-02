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

    func testEveryPathHasDistinctPurposeAndCompleteExactProgressionCriteria() throws {
        let identities = try RPG_PATH_DEFINITIONS.map { path in
            try XCTUnwrap(rpgPathIdentity(pathID: path.id), path.id)
        }
        XCTAssertEqual(Set(identities.map(\.purpose)).count, RPG_PATH_DEFINITIONS.count)
        XCTAssertEqual(Set(identities.map(\.playLoop)).count, RPG_PATH_DEFINITIONS.count)

        let presentedKinds = identities.flatMap(\.progressionCriteria).map(\.eventKind)
        XCTAssertEqual(presentedKinds.count, RPGXPEventKind.allCases.count)
        XCTAssertEqual(Set(presentedKinds.map(\.rawValue)).count, RPGXPEventKind.allCases.count)
        XCTAssertEqual(Set(presentedKinds.map(\.rawValue)),
                       Set(RPGXPEventKind.allCases.map(\.rawValue)))

        for identity in identities {
            XCTAssertGreaterThanOrEqual(identity.progressionCriteria.count, 2, identity.pathID)
            for criterion in identity.progressionCriteria {
                XCTAssertEqual(criterion.eventKind.pathID, identity.pathID)
                XCTAssertFalse(criterion.title.isEmpty)
                XCTAssertFalse(criterion.criterion.isEmpty)
                XCTAssertTrue(criterion.criterion.hasSuffix("."), criterion.eventKind.rawValue)
                XCTAssertTrue(criterion.reward.contains("XP"), criterion.eventKind.rawValue)
                XCTAssertTrue(criterion.limit.contains("1,200 simulation ticks"),
                              criterion.eventKind.rawValue)
            }
        }
    }

    func testVisibleProgressionRewardsAreTheAuthoritativeAwardRules() {
        for kind in RPGXPEventKind.allCases {
            let magnitude = kind == .menderEffectiveHealing ? 20 : 1
            let award = kind.reward.award(forMagnitude: magnitude)
            XCTAssertNotNil(award, kind.rawValue)
            XCTAssertTrue(kind.progressionReward.contains("\(award!)"), kind.rawValue)
        }
        XCTAssertNil(RPGXPEventKind.menderEffectiveHealing.reward.award(forMagnitude: 1))
        XCTAssertEqual(RPGXPEventKind.menderEffectiveHealing.reward.award(forMagnitude: 16), 8)
        XCTAssertEqual(RPGXPEventKind.menderEffectiveHealing.reward.award(forMagnitude: 200), 8)
    }

    func testCausalSupportAndEngineeringCriteriaStateTheirCheckedAdmissionRules() {
        XCTAssertEqual(
            RPGXPEventKind.menderEffectiveHealing.progressionCriterion,
            "Restore at least 2 health attributable to a live, unconsumed hostile-injury record on a non-player ally before 1,200 simulation ticks have elapsed since that ally's latest hostile injury."
        )
        XCTAssertTrue(RPGXPEventKind.menderEffectiveHealing.progressionReward.contains("causal health"))

        let cleanse = RPGXPEventKind.menderCleanseRescue.progressionCriterion
        XCTAssertTrue(cleanse.contains("Before 1,200 simulation ticks have elapsed"))
        XCTAssertTrue(cleanse.contains("non-player ally's latest hostile injury"))
        XCTAssertTrue(cleanse.contains("record must remain live and unconsumed"))
        XCTAssertTrue(cleanse.contains("Restore to remove poison, wither, weakness, or slowness"))
        XCTAssertTrue(cleanse.contains("Purify to remove poison, hunger, or nausea"))
        XCTAssertTrue(cleanse.contains("Mend Wounds or Restore"))
        XCTAssertTrue(cleanse.contains("hostile-attributable portion of the heal alone"))
        XCTAssertTrue(cleanse.contains("at most 25% health to above 25%"))
        XCTAssertTrue(cleanse.contains("at most one fixed bonus"))

        let mechanism = RPGXPEventKind.tinkerMechanismTransition.progressionCriterion
        for required in ["Immediately after placing", "sticky piston", "redstone lamp",
                         "button", "power above 0"] {
            XCTAssertTrue(mechanism.contains(required), required)
        }

        let engineering = RPGXPEventKind.tinkerEngineeringCraft.progressionCriterion
        for required in ["crafting-grid recipe", "redstone wire", "sticky piston", "daylight sensor",
                         "calibrated sculk sensor", "TNT",
                         "registered tool output", "unless it is a sword, bow, crossbow, or trident"] {
            XCTAssertTrue(engineering.contains(required), required)
        }

        XCTAssertTrue(RPGXPEventKind.menderProvisionCraft.progressionCriterion
            .contains("crafting-grid recipe"))
        XCTAssertTrue(RPGXPEventKind.tinkerFirstRecipe.progressionCriterion
            .contains("registered crafting-grid recipe"))
        XCTAssertTrue(RPGXPEventKind.rangerFieldDiscovery.progressionCriterion
            .contains("Be in a loaded chunk"))
        XCTAssertEqual(RPGXPEventKind.delverDungeonMilestone.progressionCriterion,
                       "Materialize loot from a newly generated world-structure container.")
        XCTAssertTrue(RPGXPEventKind.delverDungeonMilestone.progressionLimit
            .contains("materializes its loot only once"))
        XCTAssertTrue(RPGXPEventKind.delverDungeonMilestone.progressionLimit
            .contains("rolling world-location key is an additional duplicate guard"))
        XCTAssertTrue(rpgLevelOneProgressionGuidance(pathID: "warden")?.visibleText
            .contains("Warden's normal melee attack or melee action") == true)
        XCTAssertTrue(rpgLevelOneProgressionGuidance(pathID: "warden")?.visibleText
            .contains("Warden protection effect absorbs at least 2 hostile damage") == true)
        XCTAssertTrue(rpgLevelOneProgressionGuidance(pathID: "delver")?.visibleText
            .contains("generated world-structure treasure") == true)
        XCTAssertFalse(rpgLevelOneProgressionGuidance(pathID: "delver")?.visibleText
            .contains("dungeon treasure") == true)
        XCTAssertTrue(rpgLevelOneProgressionGuidance(pathID: "mender")?.visibleText
            .contains("before 1,200 simulation ticks have elapsed") == true)
        XCTAssertTrue(rpgLevelOneProgressionGuidance(pathID: "mender")?.visibleText
            .contains("live, unconsumed injury record") == true)
    }

    func testEverySubclassHasAUniquePurposeAndCompleteThreeSkillRoute() throws {
        XCTAssertEqual(Set(RPG_BRANCH_DEFINITIONS.map(\.summary)).count,
                       RPG_BRANCH_DEFINITIONS.count)
        for branch in RPG_BRANCH_DEFINITIONS {
            XCTAssertEqual(branch.skillIDs.count, 3, branch.id)
            XCTAssertEqual(Set(branch.skillIDs).count, 3, branch.id)
            XCTAssertTrue(branch.skillIDs.allSatisfy {
                rpgSkillDefinition($0)?.branchID == branch.id
            }, branch.id)
            let state = try XCTUnwrap(rpgScreenFixture(
                pathID: branch.pathID, branchID: branch.id))
            let roadmap = try XCTUnwrap(rpgSpecializationRoadmap(
                branchID: branch.id, in: state))
            XCTAssertEqual(roadmap.milestones.count, 15, branch.id)
        }
        XCTAssertEqual(rpgBranchDefinition("ranger_scout")?.summary,
                       "Sneaking mobility and hostile detection for reconnaissance and ambushes.")
        XCTAssertEqual(rpgBranchDefinition("delver_miner")?.summary,
                       "Faster excavation, mining bursts, and fatigue recovery from deep blocks.")
        XCTAssertEqual(rpgBranchDefinition("delver_trapper")?.summary,
                       "Detect traps, reduce trap and explosion damage, and place timed deadfalls.")
        XCTAssertEqual(rpgBranchDefinition("arcanist_elementalist")?.summary,
                       "Fire, frost, lightning, and storm magic.")
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
