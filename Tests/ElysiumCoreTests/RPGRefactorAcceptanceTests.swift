import XCTest
@testable import ElysiumCore

/// Finish-line acceptance coverage for the attribute-removal / five-rank refactor: the plan's
/// worked point-accounting example, the security-amendment compatibility vectors (S1, S4), the
/// migration legality-preservation property, and the frozen spell-remap ceiling. These assertions
/// pin the normative invariants the plan enumerated rather than re-deriving them.
final class RPGRefactorAcceptanceTests: XCTestCase {

    private func warden(_ branchID: String = "warden_guardian") -> RPGCharacterState {
        guard case .success(let state) = rpgCreateCharacter(RPGCreationDraft(
            pathID: "warden", branchID: branchID,
            startingSkillIDs: rpgBranchDefinition(branchID)!.skillIDs)) else {
            fatalError("failed to create warden/\(branchID)")
        }
        return state
    }

    // MARK: - Plan §12 worked example

    /// Plan §12: a Level-10 Warden-Guardian holding {guard_stance 3, interpose 2, heavy_cut 1,
    /// shield_bind 1}, with starting skills {guard_stance, heavy_cut, shield_bind}, has spent
    /// exactly 4 points, earned 12, and has 8 available.
    func testLevelTenWardenGuardianWorkedExampleSpendsFourEarnsTwelveLeavesEight() {
        // The worked example uses the DEFAULT starting skills (the path's three sub-class
        // signatures), which is exactly what a Guardian gets when they accept the preselection.
        guard case .success(var state) = rpgCreateCharacter(RPGCreationDraft(
            pathID: "warden", branchID: "warden_guardian",
            startingSkillIDs: rpgDefaultStartingSkillIDs(pathID: "warden"))) else {
            return XCTFail("failed to create Guardian with default starting skills")
        }
        XCTAssertEqual(state.startingSkillIDs, ["guard_stance", "heavy_cut", "shield_bind"])
        state.level = 10
        state.skillRanks = ["guard_stance": 3, "interpose": 2, "heavy_cut": 1, "shield_bind": 1]

        // guard_stance: starting -> rank 1 free, ranks 2-3 cost 1 each = 2.
        // interpose: in-sub-class, not starting -> ranks 1-2 cost 1 each = 2.
        // heavy_cut + shield_bind: starting -> rank 1 free = 0.
        XCTAssertEqual(rpgSpentSkillPoints(state), 4)
        XCTAssertEqual(rpgEarnedSkillPoints(level: 10), 12)
        XCTAssertEqual(rpgAvailableSkillPoints(state), 8)
    }

    // MARK: - Security amendment S1: backward-compatibility attribute vector

    func testCreationDraftEncodesFrozenBackwardCompatibilityAttributeVector() throws {
        let draft = RPGCreationDraft(pathID: "warden", branchID: "warden_bulwark",
                                     startingSkillIDs: rpgBranchDefinition("warden_bulwark")!.skillIDs)
        let data = try JSONEncoder().encode(draft)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let attributes = try XCTUnwrap(object["attributes"] as? [String: Any])
        // Fixed vector totalling 42 within the frozen v2 6-14 bounds, satisfying every node-0
        // signature-skill requirement so an old (v2) host accepts a new client's draft.
        XCTAssertEqual(attributes["strength"] as? Int, 9)
        XCTAssertEqual(attributes["dexterity"] as? Int, 9)
        XCTAssertEqual(attributes["intelligence"] as? Int, 9)
        XCTAssertEqual(attributes["endurance"] as? Int, 8)
        XCTAssertEqual(attributes["luck"] as? Int, 7)
        let total = [9, 9, 9, 8, 7].reduce(0, +)
        XCTAssertEqual(total, 42)

        // The frozen v2 node-0 (branch signature) attribute-requirement table, transcribed verbatim
        // from the pre-refactor registry (git 913f445 Sources/ElysiumCore/Game/CharacterProgression.swift).
        // The encoded compatibility vector MUST satisfy every entry so an old v2 host accepting a new
        // client's draft creates a valid character for all 18 sub-classes.
        let encoded: [String: Int] = [
            "strength": try XCTUnwrap(attributes["strength"] as? Int),
            "dexterity": try XCTUnwrap(attributes["dexterity"] as? Int),
            "intelligence": try XCTUnwrap(attributes["intelligence"] as? Int),
            "endurance": try XCTUnwrap(attributes["endurance"] as? Int),
            "luck": try XCTUnwrap(attributes["luck"] as? Int),
        ]
        let frozenV2SignatureRequirements: [(skill: String, attribute: String, minimum: Int)] = [
            ("guard_stance", "strength", 8),
            ("heavy_cut", "strength", 9),
            ("shield_bind", "endurance", 8),
            ("quick_draw", "dexterity", 9),
            ("trail_sense", "luck", 7),
            ("campcraft", "endurance", 8),
            ("vein_reader", "intelligence", 7),
            ("trap_probe", "dexterity", 8),
            ("salvage_eye", "luck", 7),
            ("spell_formula", "intelligence", 9),
            ("minor_glamour", "intelligence", 9),
            ("ritual_circle", "endurance", 8),
            ("field_dressing", "intelligence", 8),
            ("herbal_lore", "luck", 7),
            ("safe_haven", "endurance", 8),
            ("circuit_sense", "intelligence", 8),
            ("field_mod", "dexterity", 8),
            ("charge_pack", "intelligence", 8),
        ]
        // Sanity: the table covers exactly the 18 branch signature (node-0) skills.
        XCTAssertEqual(Set(frozenV2SignatureRequirements.map(\.skill)),
                       Set(RPG_BRANCH_DEFINITIONS.compactMap { $0.skillIDs.first }))
        for requirement in frozenV2SignatureRequirements {
            let value = try XCTUnwrap(encoded[requirement.attribute], requirement.skill)
            XCTAssertGreaterThanOrEqual(value, requirement.minimum,
                "compat vector \(requirement.attribute)=\(value) fails \(requirement.skill)'s v2 requirement \(requirement.minimum)")
        }

        // Frozen kit-grant preimage: the chosen sub-class's node-0 signature skill.
        XCTAssertEqual(object["starterSkillID"] as? String, "shield_bind")
        // This build decodes the draft tolerantly, ignoring the compatibility vector entirely.
        let decoded = try JSONDecoder().decode(RPGCreationDraft.self, from: data)
        XCTAssertEqual(decoded.pathID, "warden")
        XCTAssertEqual(decoded.branchID, "warden_bulwark")
        XCTAssertEqual(decoded.startingSkillIDs, rpgBranchDefinition("warden_bulwark")!.skillIDs)
    }

    // MARK: - Hostile RPGCreationDraft JSON never crashes and always fails closed or succeeds validly

    /// A hostile `RPGCreationDraft` -- missing `branchID` with a bogus `starterSkillID`, an
    /// oversized `startingSkillIDs` JSON array, cross-branch skills, and a payload with every
    /// field absent -- always either fails `rpgCreateCharacter` closed with a typed error or
    /// produces a state that fully satisfies the creation contract. Bounded decode caps
    /// `startingSkillIDs` to 3 before `rpgCreateCharacter` ever sees it, so oversized JSON arrays
    /// are already truncated by the codec; the direct-construction case proves `rpgCreateCharacter`
    /// itself also rejects an over-count draft (defense in depth, not just codec-level bounding).
    func testHostileCreationDraftJSONAndOverCountDirectDraftFailCleanlyWithoutCrashing() throws {
        func decode(_ json: [String: Any]) throws -> RPGCreationDraft {
            try JSONDecoder().decode(RPGCreationDraft.self,
                                     from: try JSONSerialization.data(withJSONObject: json))
        }

        // Missing branchID entirely, plus a starterSkillID that names no real skill: legacy
        // synthesis fails (no branch owns "not-a-real-skill"), so creation fails closed.
        let missingBranchBogusStarter = try decode([
            "pathID": "warden", "starterSkillID": "not-a-real-skill",
        ])
        XCTAssertNil(missingBranchBogusStarter.branchID)
        switch rpgCreateCharacter(missingBranchBogusStarter) {
        case .failure(.invalidStarterSkill): break
        default: XCTFail("missing branchID + bogus starterSkillID must fail closed")
        }

        // An oversized JSON array is truncated to 3 by the bounded decoder before
        // rpgCreateCharacter ever runs; six requested skills across three paths decode down to
        // the first three, which still fail the pool check (none of them share a branch).
        let oversized = try decode([
            "pathID": "warden", "branchID": "warden_guardian",
            "startingSkillIDs": ["guard_stance", "quick_draw", "vein_reader",
                                 "spell_formula", "field_dressing", "circuit_sense"],
        ])
        XCTAssertEqual(oversized.startingSkillIDs.count, RPG_STARTING_SKILL_COUNT,
                       "codec bounds the array to 3 regardless of the 6 requested")
        switch rpgCreateCharacter(oversized) {
        case .failure(.invalidStartingSkillSelection): break
        default: XCTFail("an out-of-pool truncated selection must fail closed")
        }

        // Cross-path skills: three real, unique, same-path (arcanist) skills, but not this
        // chosen warden branch's pool -- fails the pool membership check, not a crash or a silent
        // narrowing to whichever entries happen to validate.
        let crossBranch = try decode([
            "pathID": "warden", "branchID": "warden_guardian",
            "startingSkillIDs": ["spell_formula", "minor_glamour", "ritual_circle"],
        ])
        switch rpgCreateCharacter(crossBranch) {
        case .failure(.invalidStartingSkillSelection(let offered)):
            XCTAssertEqual(Set(offered), ["spell_formula", "minor_glamour", "ritual_circle"])
        default: XCTFail("cross-path skills for the chosen branch must fail closed")
        }

        // Every field absent: decodes to empty/blank defaults, never crashes, and fails closed on
        // the unknown empty pathID.
        let empty = try decode([:])
        XCTAssertEqual(empty.pathID, "")
        XCTAssertTrue(empty.startingSkillIDs.isEmpty)
        switch rpgCreateCharacter(empty) {
        case .failure(.unknownPath("")): break
        default: XCTFail("an entirely empty draft must fail closed on the empty pathID")
        }

        // Defense in depth: even a directly-constructed draft that bypasses the codec's cap
        // entirely (more than 3 skills) is still rejected by rpgCreateCharacter's own count guard.
        let directOverCount = RPGCreationDraft(
            pathID: "warden", branchID: "warden_guardian",
            startingSkillIDs: ["guard_stance", "heavy_cut", "shield_bind", "interpose"])
        switch rpgCreateCharacter(directOverCount) {
        case .failure(.invalidStartingSkillSelection(let offered)):
            XCTAssertEqual(offered.count, 4)
        default: XCTFail("a draft with 4 requested skills must fail closed even bypassing the codec cap")
        }
    }

    // MARK: - Security amendment S4: any legal purchase survives replay

    /// Any rank a player can legally purchase under the v3 rules is preserved by the replay that
    /// repair performs (new-purchase ⊆ new-replay), across every sub-class and its own three nodes.
    func testEveryLegallyPurchasedRankIsPreservedByReplay() {
        for branch in RPG_BRANCH_DEFINITIONS {
            var state = warden(branch.pathID == "warden" ? branch.id : "warden_guardian")
            if branch.pathID != "warden" {
                guard case .success(let created) = rpgCreateCharacter(RPGCreationDraft(
                    pathID: branch.pathID, branchID: branch.id,
                    startingSkillIDs: rpgBranchDefinition(branch.id)!.skillIDs)) else {
                    return XCTFail(branch.id)
                }
                state = created
            }
            _ = rpgAddXP(rpgXPRequiredForLevel(RPG_LEVEL_CAP), to: &state)
            // Purchase every own-sub-class rank the rules allow.
            for skillID in branch.skillIDs {
                while (state.skillRanks[skillID] ?? 0) < RPG_SKILL_RANK_CAP {
                    if rpgLearnSkill(skillID, in: &state) != nil { break }
                }
            }
            let purchased = state.skillRanks
            let replayed = repairRPGCharacterState(state)
            for (skillID, rank) in purchased where rank > 0 {
                XCTAssertGreaterThanOrEqual(replayed.skillRanks[skillID] ?? 0, rank,
                                            "\(branch.id) \(skillID): replay dropped a legal rank")
            }
        }
    }

    // MARK: - Migration: old legality ⊆ new legality

    /// A pre-v3 (v2) save's legally-held ranks are never dropped by migration into v3: the new
    /// level gates are <= the old gates and the new point budget is >= the old, so replay keeps
    /// every rank the old save held.
    func testMigrationPreservesEveryLegallyHeldRankFromV2() {
        var legacy = warden("warden_guardian")
        legacy.version = 2
        legacy.level = 20
        legacy.xp = rpgXPRequiredForLevel(RPG_LEVEL_CAP)
        legacy.skillRanks = ["guard_stance": 5, "interpose": 3, "anchor_line": 2]
        let migrated = repairRPGCharacterState(legacy)
        XCTAssertTrue(migrated.created)
        XCTAssertEqual(migrated.version, RPG_STATE_CURRENT_VERSION)
        XCTAssertGreaterThanOrEqual(migrated.skillRanks["guard_stance"] ?? 0, 5)
        XCTAssertGreaterThanOrEqual(migrated.skillRanks["interpose"] ?? 0, 3)
        XCTAssertGreaterThanOrEqual(migrated.skillRanks["anchor_line"] ?? 0, 2)
    }

    /// Property (seeded, reproducible): migration monotonicity across many pre-v3 states rather
    /// than one worked example. Each seed builds a state whose held ranks are provably legal (
    /// purchased through the current engine at a random level, so they satisfy the v3 gates the
    /// old save would have satisfied a fortiori), relabels it version 2, and checks that repair
    /// (a) never drops a legally-held rank and (b) never leaves the migrated v3 state with
    /// negative available skill points. Seed is fixed (sfc32) so a failure reproduces exactly.
    func testSeededMigrationMonotonicityPreservesRanksAndNeverProducesNegativeAvailablePoints() throws {
        var rng = RandomX(0x4d49_4752) // "MIGR"
        for seed in 0..<40 {
            let branch = RPG_BRANCH_DEFINITIONS[rng.nextInt(RPG_BRANCH_DEFINITIONS.count)]
            let path = try XCTUnwrap(rpgPathDefinition(branch.pathID), "seed \(seed)")
            let pathSkills = RPG_SKILL_DEFINITIONS.filter { $0.pathID == path.id }
            let level = 1 + rng.nextInt(RPG_LEVEL_CAP)

            guard case .success(var state) = rpgCreateCharacter(RPGCreationDraft(
                pathID: path.id, branchID: branch.id, startingSkillIDs: branch.skillIDs)) else {
                return XCTFail("seed \(seed) failed to create \(branch.id)")
            }
            _ = rpgAddXP(rpgXPRequiredForLevel(level), to: &state)
            XCTAssertEqual(state.level, level, "seed \(seed)")

            // Best-effort purchase a handful of random ranks (in-branch and cross-branch); every
            // rank actually held afterward is, by construction, legal at this level.
            for _ in 0..<(1 + rng.nextInt(12)) {
                let candidate = pathSkills[rng.nextInt(pathSkills.count)]
                _ = rpgLearnSkill(candidate.id, in: &state)
            }
            let legallyHeld = state.skillRanks

            var legacy = state
            legacy.version = 2
            let migrated = repairRPGCharacterState(legacy)

            XCTAssertTrue(migrated.created, "seed \(seed)")
            XCTAssertEqual(migrated.version, RPG_STATE_CURRENT_VERSION, "seed \(seed)")
            for (skillID, rank) in legallyHeld where rank > 0 {
                XCTAssertGreaterThanOrEqual(migrated.skillRanks[skillID] ?? 0, rank,
                                            "seed \(seed) \(skillID): migration dropped a legal rank")
            }
            XCTAssertGreaterThanOrEqual(rpgAvailableSkillPoints(migrated), 0, "seed \(seed)")
        }
    }

    // MARK: - Frozen spell remap ceiling

    /// The spell remap keeps every spell unlock at rank 3 or below (never above), so ranks 1-3 stay
    /// byte-identical to the shipped v2 registry for spell-granting purposes.
    func testEverySpellUnlockIsAtRankThreeOrBelow() {
        var unlockCount = 0
        for skill in RPG_SKILL_DEFINITIONS {
            for unlock in skill.spellUnlocks {
                unlockCount += 1
                XCTAssertLessThanOrEqual(unlock.rank, 3,
                    "\(skill.id) unlocks \(unlock.spellID) above rank 3")
                XCTAssertGreaterThanOrEqual(unlock.rank, 1, "\(skill.id) \(unlock.spellID)")
            }
        }
        XCTAssertGreaterThan(unlockCount, 0)
        XCTAssertEqual(Set(RPG_SKILL_DEFINITIONS.flatMap { $0.spellUnlocks.map(\.spellID) }).count,
                       RPG_SPELL_DEFINITIONS.count,
                       "every registered spell is unlocked by some skill")
    }

    // MARK: - Codec round-trip fidelity for the v3 state shape

    func testV3StateEncodeDecodeRepairIsAFixedPoint() throws {
        var state = warden("warden_vanguard")
        _ = rpgAddXP(rpgXPRequiredForLevel(RPG_LEVEL_CAP), to: &state)
        for skillID in rpgBranchDefinition("warden_vanguard")!.skillIDs {
            while (state.skillRanks[skillID] ?? 0) < RPG_SKILL_RANK_CAP {
                if rpgLearnSkill(skillID, in: &state) != nil { break }
            }
        }
        state = repairRPGCharacterState(state)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(RPGCharacterState.self, from: data)
        XCTAssertEqual(decoded, state, "v3 state round-trips through the codec unchanged")
        XCTAssertEqual(repairRPGCharacterState(decoded), state, "decode∘repair is a fixed point")
        // The kit-grant identity is stable across the round trip.
        XCTAssertEqual(decoded.kitGrantID, state.kitGrantID)
    }
}
