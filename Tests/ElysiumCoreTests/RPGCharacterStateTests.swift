import XCTest
@testable import ElysiumCore

final class RPGCharacterStateTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        registerAllRecipes()
        registerAllSystems()
    }

    func testCharacterCreationBuildsPreparedArcanistWithFullFatigue() {
        let draft = RPGCreationDraft(
            pathID: "arcanist",
            branchID: "arcanist_elementalist",
            startingSkillIDs: rpgDefaultStartingSkillIDs(pathID: "arcanist")
        )

        let result = rpgCreateCharacter(draft)
        guard case .success(let state) = result else {
            return XCTFail("expected character creation to succeed")
        }

        XCTAssertTrue(state.created)
        XCTAssertEqual(state.pathID, "arcanist")
        XCTAssertEqual(state.level, 1)
        XCTAssertEqual(state.skillRanks["spell_formula"], 1)
        XCTAssertEqual(state.skillRanks["minor_glamour"], 1)
        XCTAssertEqual(state.skillRanks["ritual_circle"], 1)
        XCTAssertEqual(state.starterSkillID, "spell_formula")
        XCTAssertEqual(state.specializationBranchID, "arcanist_elementalist")
        XCTAssertEqual(Set(state.startingSkillIDs), ["spell_formula", "minor_glamour", "ritual_circle"])
        // The single rule "spells come only from skill ranks" reproduces the legacy auto-grant.
        XCTAssertEqual(Set(state.knownSpellIDs), ["ignite", "blur", "mage_light"])
        XCTAssertEqual(Set(state.preparedSpellIDs), ["ignite", "blur", "mage_light"])
        XCTAssertNil(state.selectedPreparedActionID)
        XCTAssertFalse(state.migrationNoticePending)
        XCTAssertEqual(state.fatigue, rpgDerivedStats(state).maxFatigue, accuracy: 0.0001)
    }

    func testCharacterCreationRejectsInvalidStartingSkillSelection() {
        let tooFew = RPGCreationDraft(
            pathID: "arcanist", branchID: "arcanist_elementalist",
            startingSkillIDs: ["spell_formula"])
        XCTAssertEqual(tryFailure(rpgCreateCharacter(tooFew)),
                       .invalidStartingSkillSelection(["spell_formula"]))

        let outsidePool = RPGCreationDraft(
            pathID: "arcanist", branchID: "arcanist_elementalist",
            startingSkillIDs: ["spell_formula", "minor_glamour", "guard_stance"])
        XCTAssertEqual(tryFailure(rpgCreateCharacter(outsidePool)),
                       .invalidStartingSkillSelection(["spell_formula", "minor_glamour", "guard_stance"]))

        let duplicated = RPGCreationDraft(
            pathID: "arcanist", branchID: "arcanist_elementalist",
            startingSkillIDs: ["spell_formula", "spell_formula", "minor_glamour"])
        XCTAssertEqual(tryFailure(rpgCreateCharacter(duplicated)),
                       .invalidStartingSkillSelection(["spell_formula", "spell_formula", "minor_glamour"]))
    }

    /// A custom (non-default) selection is honored verbatim as long as it is a legal pool subset,
    /// and `starterSkillID` stays the branch signature regardless of whether it was chosen.
    func testCharacterCreationHonorsCustomStartingSkillSelection() {
        let draft = RPGCreationDraft(
            pathID: "warden", branchID: "warden_guardian",
            startingSkillIDs: ["interpose", "anchor_line", "heavy_cut"])
        guard case .success(let state) = rpgCreateCharacter(draft) else {
            return XCTFail("expected character creation to succeed")
        }
        XCTAssertEqual(Set(state.startingSkillIDs), ["interpose", "anchor_line", "heavy_cut"])
        XCTAssertEqual(state.skillRanks["interpose"], 1)
        XCTAssertEqual(state.skillRanks["anchor_line"], 1)
        XCTAssertEqual(state.skillRanks["heavy_cut"], 1)
        // The chosen branch's own signature was NOT picked; starterSkillID is still its identity.
        XCTAssertEqual(state.starterSkillID, "guard_stance")
        XCTAssertNil(state.skillRanks["guard_stance"])
    }

    func testRepairDropsUnknownAndCrossPathStateButKeepsSynthesizedStartingSkills() {
        let raw = RPGCharacterState(
            version: 0,
            created: true,
            pathID: "arcanist",
            xp: -40,
            level: 99,
            skillRanks: [
                "spell_formula": 99,
                "minor_glamour": 1,
                "guard_stance": 1,
                "not_real": 1,
            ],
            preparedSkillIDs: ["not_real", "guard_stance", "spell_formula"],
            knownSpellIDs: ["ignite", "mend_wounds", "not_real"],
            preparedSpellIDs: ["not_real", "mend_wounds", "ignite"],
            fatigue: .infinity,
            actionSequence: -5,
            activeCooldowns: [
                RPGCooldown(id: "ignite", remainingTicks: 12),
                RPGCooldown(id: "not_real", remainingTicks: 12),
            ],
            activeUpkeeps: [
                RPGUpkeep(spellID: "blur", ownerSequence: 4, remainingTicks: 100, costPerSecond: 8),
                RPGUpkeep(spellID: "mend_wounds", ownerSequence: 5, remainingTicks: 100, costPerSecond: 8),
            ]
        )

        let repaired = repairRPGCharacterState(raw)

        XCTAssertTrue(repaired.created)
        XCTAssertEqual(repaired.version, RPG_STATE_CURRENT_VERSION)
        XCTAssertEqual(repaired.pathID, "arcanist")
        XCTAssertEqual(repaired.xp, 0)
        XCTAssertEqual(repaired.level, 1)
        XCTAssertEqual(repaired.starterSkillID, "spell_formula")
        XCTAssertEqual(repaired.specializationBranchID, "arcanist_elementalist")
        // Legacy saves never recorded startingSkillIDs; repair fails open to the path defaults
        // (the three sub-class signatures), then backfills rank 1 for any not already learned.
        XCTAssertEqual(Set(repaired.startingSkillIDs), ["spell_formula", "minor_glamour", "ritual_circle"])
        XCTAssertEqual(repaired.skillRanks["spell_formula"], 1)
        XCTAssertEqual(repaired.skillRanks["minor_glamour"], 1)
        XCTAssertEqual(repaired.skillRanks["ritual_circle"], 1)
        XCTAssertNil(repaired.skillRanks["guard_stance"])
        XCTAssertNil(repaired.skillRanks["not_real"])
        XCTAssertTrue(repaired.preparedSkillIDs.isEmpty)
        XCTAssertTrue(repaired.knownSpellIDs.contains("ignite"))
        XCTAssertTrue(repaired.knownSpellIDs.contains("blur"))
        XCTAssertTrue(repaired.knownSpellIDs.contains("mage_light"))
        XCTAssertFalse(repaired.knownSpellIDs.contains("mend_wounds"))
        XCTAssertEqual(repaired.preparedSpellIDs, ["ignite"])
        XCTAssertNil(repaired.selectedPreparedActionID)
        XCTAssertGreaterThanOrEqual(repaired.fatigue, 0)
        XCTAssertLessThanOrEqual(repaired.fatigue, rpgDerivedStats(repaired).maxFatigue)
        XCTAssertEqual(repaired.actionSequence, 0)
        XCTAssertEqual(repaired.activeCooldowns, [RPGCooldown(id: "ignite", remainingTicks: 12)])
        XCTAssertTrue(repaired.activeUpkeeps.isEmpty)
        XCTAssertEqual(rpgSpentSkillPoints(repaired), rpgEarnedSkillPoints(level: repaired.level))
        XCTAssertTrue(repaired.migrationNoticePending)
    }

    func testPlayerSaveLoadPersistsRPGStateAndKeepsOldPlayersVanilla() {
        let world = World(dim: .overworld, seed: 1234)
        let oldPlayer = Player(world: world)
        let oldSnapshot = oldPlayer.save()
        let loadedOld = Player(world: world)
        loadedOld.load(oldSnapshot)

        XCTAssertFalse(loadedOld.rpg.created)
        XCTAssertEqual(loadedOld.maxHealth, 20)

        let player = Player(world: world)
        let error = player.createRPGCharacter(RPGCreationDraft(
            pathID: "warden", branchID: "warden_guardian",
            startingSkillIDs: rpgDefaultStartingSkillIDs(pathID: "warden")))
        XCTAssertNil(error)
        player.health = player.maxHealth
        let saved = player.save()

        let loaded = Player(world: world)
        loaded.load(saved)

        XCTAssertTrue(loaded.rpg.created)
        XCTAssertEqual(loaded.rpg.pathID, "warden")
        XCTAssertEqual(loaded.rpg.skillRanks["guard_stance"], 1)
        XCTAssertEqual(loaded.rpg.kitGrantVersion, RPG_STARTER_KIT_VERSION)
        XCTAssertEqual(loaded.rpg.kitGrantID, rpgStarterKitGrantID(pathID: "warden", starterSkillID: "guard_stance"))
        XCTAssertNil((saved["rpg"] as? [String: Any])?["actionQuickSlots"])
        XCTAssertEqual(loaded.maxHealth, rpgDerivedStats(loaded.rpg).maxHealth)
        XCTAssertEqual(loaded.health, loaded.maxHealth)
    }

    func testLegacyActionQuickSlotsRemainInPlayerSaveUntilReceipt() throws {
        let world = World(dim: .overworld, seed: 4321)
        let player = Player(world: world)
        XCTAssertNil(player.createRPGCharacter(RPGCreationDraft(
            pathID: "arcanist", branchID: "arcanist_elementalist",
            startingSkillIDs: rpgDefaultStartingSkillIDs(pathID: "arcanist"))))

        let loaded = Player(world: world)
        var legacy = player.save()
        var legacyRPG = try XCTUnwrap(legacy["rpg"] as? [String: Any])
        legacyRPG["actionQuickSlots"] = [NSNull(), NSNull(), NSNull(), NSNull(),
                                           "spell:ignite"]
        legacy["rpg"] = legacyRPG
        loaded.load(legacy)
        let retained = try XCTUnwrap(loaded.rpgLegacyQuickSlotEnvelope)
        XCTAssertEqual(retained.preferences.tokens[4], "spell:ignite")
        XCTAssertNotNil((loaded.save()["rpg"] as? [String: Any])?["actionQuickSlots"])
        XCTAssertTrue(loaded.markRPGLegacyQuickSlotsOmittable(
            envelopeVersion: retained.envelopeVersion, sourceDigest: retained.sourceDigest))
        XCTAssertNil((loaded.save()["rpg"] as? [String: Any])?["actionQuickSlots"])
    }

    func testDetachedOmissionCandidateDoesNotMutateLiveEnvelopeOrOrdinarySave() throws {
        let world = World(dim: .overworld, seed: 4_322)
        let source = Player(world: world)
        source.rpg = try rpgCreateCharacter(RPGCreationDraft(
            pathID: "arcanist", branchID: "arcanist_elementalist",
            startingSkillIDs: rpgDefaultStartingSkillIDs(pathID: "arcanist"))).get()
        var legacy = source.save()
        var rpg = try XCTUnwrap(legacy["rpg"] as? [String: Any])
        rpg["actionQuickSlots"] = ["spell:ignite"]
        legacy["rpg"] = rpg
        let loaded = Player(world: world); loaded.load(legacy)
        let envelopeBefore = try XCTUnwrap(loaded.rpgLegacyQuickSlotEnvelope)

        let candidate = loaded.save(omitLegacyQuickSlots: true)
        XCTAssertNil((candidate["rpg"] as? [String: Any])?["actionQuickSlots"])
        XCTAssertNotNil((loaded.save()["rpg"] as? [String: Any])?["actionQuickSlots"])
        XCTAssertEqual(loaded.rpgLegacyQuickSlotEnvelope, envelopeBefore)
        XCTAssertFalse(try XCTUnwrap(loaded.rpgLegacyQuickSlotEnvelope).omissionEligible)
    }

    func testLegacyRPGStateDecodesWithoutSelectedPreparedAction() throws {
        let data = """
        {
          "version": 1,
          "created": true,
          "pathID": "arcanist",
          "attributes": { "strength": 9, "dexterity": 9, "intelligence": 9, "endurance": 9, "luck": 6 },
          "xp": 0,
          "level": 1,
          "skillRanks": { "spell_formula": 1 },
          "preparedSkillIDs": ["spell_formula"],
          "knownSpellIDs": ["ignite"],
          "preparedSpellIDs": ["ignite"],
          "selectedPreparedSpellID": "ignite",
          "fatigue": 12,
          "actionSequence": 0,
          "activeCooldowns": [],
          "activeUpkeeps": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(RPGCharacterState.self, from: data)
        let repaired = repairRPGCharacterState(decoded)

        XCTAssertEqual(repaired.selectedPreparedSpellID, "ignite")
        XCTAssertNil(repaired.selectedPreparedActionID)
        XCTAssertEqual(repaired.kitGrantVersion, 0)
        XCTAssertNil(repaired.kitGrantID)
        XCTAssertTrue(repaired.migrationNoticePending)
    }

    private func tryFailure(_ result: Result<RPGCharacterState, RPGCreationError>) -> RPGCreationError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}
