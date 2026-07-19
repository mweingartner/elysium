import XCTest
@testable import ElysiumCore

final class RPGProgressionTests: XCTestCase {
    func testXPLevelingUsesV3CurveAndPointMilestones() {
        var state = makeState(pathID: "warden", branchID: "warden_vanguard")

        let report = rpgAddXP(rpgXPRequiredForLevel(4), to: &state)

        XCTAssertTrue(report.leveledUp)
        XCTAssertEqual(report.newLevel, 4)
        XCTAssertEqual(rpgXPRequiredForLevel(20), 7_790)
        // Level 4 is a milestone level: earned = (4-1) base + 1 milestone bonus = 4. All three
        // starting skills (one per node) are free rank-1s, so nothing has been spent yet.
        XCTAssertEqual(rpgAvailableSkillPoints(state), 4)
        // 19 base (levels 2...20) + 6 milestone bonus points (4,7,10,13,16,19) = 25 lifetime.
        XCTAssertEqual(rpgEarnedSkillPoints(level: 20), 25)
    }

    func testStartingSkillRankOneIsFreeAndPrerequisiteGatingIsRemoved() {
        var state = makeState(pathID: "warden", branchID: "warden_vanguard")
        _ = rpgAddXP(rpgXPRequiredForLevel(10), to: &state)

        // All three sub-class skills are free Rank-1 starting skills after creation.
        XCTAssertEqual(state.skillRanks["heavy_cut"], 1)
        XCTAssertEqual(state.skillRanks["charge_break"], 1)
        XCTAssertEqual(state.skillRanks["stagger_chain"], 1)
        XCTAssertEqual(rpgSpentSkillPoints(state), 0)
        XCTAssertEqual(rpgSkillPointCost("heavy_cut", targetRank: 1, in: state), 0)
        XCTAssertEqual(rpgSkillPointCost("heavy_cut", targetRank: 2, in: state), 1)
        // guard_stance is not a chosen starting skill and is off-sub-class here.
        XCTAssertEqual(rpgSkillPointCost("guard_stance", targetRank: 1, in: state), 2)
        // Prerequisite-skill gating is removed entirely (interpretation flag A7): the node-2 skill
        // stagger_chain can advance to Rank 2 while heavy_cut (node 0) stays at Rank 1 -- only the
        // level gate (node 2 Rank 2 needs level 8; we are level 10) and point budget apply.
        XCTAssertNil(rpgLearnSkill("stagger_chain", in: &state))
        XCTAssertEqual(state.skillRanks["stagger_chain"], 2)
        XCTAssertEqual(state.skillRanks["heavy_cut"], 1)
        XCTAssertEqual(rpgSpentSkillPoints(state), 1)
    }

    func testAllEighteenBranchesCanFullyMasterAllThreeNodesByLevelCap() {
        for branch in RPG_BRANCH_DEFINITIONS {
            guard let path = rpgPathDefinition(branch.pathID) else { return XCTFail(branch.id) }
            var state = makeState(pathID: path.id, branchID: branch.id)
            _ = rpgAddXP(rpgXPRequiredForLevel(RPG_LEVEL_CAP) - state.xp, to: &state)
            XCTAssertEqual(state.level, RPG_LEVEL_CAP, branch.id)

            for skillID in branch.skillIDs {
                while (state.skillRanks[skillID] ?? 0) < RPG_SKILL_RANK_CAP {
                    XCTAssertNil(rpgLearnSkill(skillID, in: &state), "\(branch.id) \(skillID)")
                }
            }
            XCTAssertEqual(branch.skillIDs.map { state.skillRanks[$0] ?? 0 },
                           [RPG_SKILL_RANK_CAP, RPG_SKILL_RANK_CAP, RPG_SKILL_RANK_CAP], branch.id)
            // Rank 1 of each of the three own-branch nodes is free (starting skills); ranks 2-5
            // cost 1 point each in-sub-class: 3 nodes * 4 paid ranks = 12.
            XCTAssertEqual(rpgSpentSkillPoints(state), 12, branch.id)

            guard let crossSignature = path.branchIDs
                .first(where: { $0 != branch.id })
                .flatMap(rpgBranchDefinition)?.skillIDs.first else {
                return XCTFail("missing cross sub-class signature for \(branch.id)")
            }
            XCTAssertNil(rpgLearnSkill(crossSignature, in: &state), branch.id)
            XCTAssertEqual(rpgSpentSkillPoints(state), 14, branch.id)
            XCTAssertEqual(rpgAvailableSkillPoints(state),
                           rpgEarnedSkillPoints(level: RPG_LEVEL_CAP) - 14, branch.id)
        }
    }

    func testOffSubClassRankOneIsWaivedButHigherRanksPayTheSurcharge() {
        let state = makeState(pathID: "ranger", branchID: "ranger_marksman")
        XCTAssertEqual(rpgMinimumLevel(for: "quick_draw", targetRank: 1,
                                       specializationBranchID: state.specializationBranchID), 1)
        // Off-sub-class rank 1 of any node-0 (signature) skill is always level-1 legal --
        // "rank 1 of every pool skill is level-1 legal" (interpretation flag A6).
        XCTAssertEqual(rpgMinimumLevel(for: "trail_sense", targetRank: 1,
                                       specializationBranchID: state.specializationBranchID), 1)
        // Every other off-sub-class purchase pays the full +2-level surcharge.
        XCTAssertEqual(rpgMinimumLevel(for: "trail_sense", targetRank: 2,
                                       specializationBranchID: state.specializationBranchID), 6)
        XCTAssertEqual(rpgMinimumLevel(for: "far_sight", targetRank: 3,
                                       specializationBranchID: state.specializationBranchID), 14)
    }

    func testPassiveSkillsAreAlwaysOnAndOnlyActivesConsumeFourSlots() {
        var state = makeState(pathID: "warden", branchID: "warden_guardian")
        XCTAssertEqual(rpgPrepareSkill("guard_stance", in: &state), .skillNotActive("guard_stance"))

        state = makeState(pathID: "warden", branchID: "warden_vanguard")
        XCTAssertTrue(state.preparedSkillIDs.contains("heavy_cut"))
        XCTAssertEqual(RPG_MAX_PREPARED_SKILLS, 4)
        XCTAssertEqual(RPG_MAX_PREPARED_SPELLS, 6)
    }

    func testFatigueRegeneratesAndUpkeepExpiresDeterministically() {
        var state = makeState(pathID: "arcanist", branchID: "arcanist_illusionist")
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

    /// Metamorphic property: purchase order does not affect the resulting skill-rank state. Every
    /// rank-up gate is level + point budget only (prerequisite-skill gating is removed entirely,
    /// per plan §3.6), so any legal interleaving of single-rank purchases that reaches the same
    /// target rank multiset must replay to a byte-identical final `skillRanks` and spend total.
    func testPurchaseOrderInvarianceReachesIdenticalStateForTheSameTargetRankMultiset() throws {
        let branch = try XCTUnwrap(RPG_BRANCH_DEFINITIONS.first { $0.id == "warden_guardian" })
        // Rank-1 of each node is a free starting skill; the remaining single-rank purchases are
        // the "steps" that get interleaved in different legal orders below.
        let targets = [branch.skillIDs[0]: 5, branch.skillIDs[1]: 4, branch.skillIDs[2]: 3]
        let streams: [[String]] = branch.skillIDs.map { skillID in
            Array(repeating: skillID, count: (targets[skillID] ?? 1) - 1)
        }

        func apply(_ order: [String]) -> RPGCharacterState {
            var state = makeState(pathID: branch.pathID, branchID: branch.id)
            _ = rpgAddXP(rpgXPRequiredForLevel(RPG_LEVEL_CAP), to: &state)
            for skillID in order {
                XCTAssertNil(rpgLearnSkill(skillID, in: &state),
                             "legal step \(skillID) rejected mid-sequence \(order)")
            }
            return state
        }

        func interleave(_ streams: [[String]], rng: inout RandomX) -> [String] {
            var queues = streams
            var result: [String] = []
            while queues.contains(where: { !$0.isEmpty }) {
                let nonEmpty = queues.indices.filter { !queues[$0].isEmpty }
                let choice = nonEmpty[rng.nextInt(nonEmpty.count)]
                result.append(queues[choice].removeFirst())
            }
            return result
        }

        let forward = streams.flatMap { $0 }
        let reverse = streams.reversed().flatMap { $0 }
        var rngA = RandomX(0x4f52_4445), rngB = RandomX(0x4f52_4446)
        let shuffledA = interleave(streams, rng: &rngA)
        let shuffledB = interleave(streams, rng: &rngB)
        XCTAssertNotEqual(shuffledA, shuffledB, "the two seeded interleavings should actually differ")

        let baseline = apply(forward)
        for (label, order) in [("reverse", reverse), ("shuffledA", shuffledA), ("shuffledB", shuffledB)] {
            let alternate = apply(order)
            XCTAssertEqual(alternate.skillRanks, baseline.skillRanks, label)
            XCTAssertEqual(rpgSpentSkillPoints(alternate), rpgSpentSkillPoints(baseline), label)
            XCTAssertEqual(alternate.knownSpellIDs, baseline.knownSpellIDs, label)
        }
        XCTAssertEqual(branch.skillIDs.map { baseline.skillRanks[$0] }, [5, 4, 3])
    }

    private func makeState(pathID: String, branchID: String) -> RPGCharacterState {
        let result = rpgCreateCharacter(RPGCreationDraft(
            pathID: pathID, branchID: branchID,
            startingSkillIDs: rpgBranchDefinition(branchID)!.skillIDs))
        guard case .success(let state) = result else { fatalError("failed to create \(pathID)/\(branchID)") }
        return state
    }
}
