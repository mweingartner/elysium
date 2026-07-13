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
            attributes: .defaultCreation,
            starterSkillID: "spell_formula",
            starterSpellIDs: ["ignite"]
        )

        let result = rpgCreateCharacter(draft)
        guard case .success(let state) = result else {
            return XCTFail("expected character creation to succeed")
        }

        XCTAssertTrue(state.created)
        XCTAssertEqual(state.pathID, "arcanist")
        XCTAssertEqual(state.level, 1)
        XCTAssertEqual(state.skillRanks["spell_formula"], 1)
        XCTAssertEqual(state.starterSkillID, "spell_formula")
        XCTAssertEqual(state.specializationBranchID, "arcanist_elementalist")
        XCTAssertEqual(state.knownSpellIDs, ["ignite"])
        XCTAssertEqual(state.preparedSpellIDs, ["ignite"])
        XCTAssertNil(state.selectedPreparedActionID)
        XCTAssertEqual(rpgDefaultQuickSlotPreferences(for: state).tokens[0],
                       rpgPreparedActionToken(kind: .spell, id: "ignite"))
        XCTAssertEqual(state.fatigue, rpgDerivedStats(state).maxFatigue, accuracy: 0.0001)
    }

    func testCharacterCreationRejectsBadBudgetAndInvalidStarterSpell() {
        let badBudget = RPGCreationDraft(
            pathID: "arcanist",
            attributes: RPGAttributes(strength: 8, dexterity: 8, intelligence: 9, endurance: 9, luck: 6),
            starterSkillID: "spell_formula"
        )
        XCTAssertEqual(tryFailure(rpgCreateCharacter(badBudget)),
                       .invalidAttributeBudget(total: 40, expected: RPGAttributes.creationBudget))

        let badSpell = RPGCreationDraft(
            pathID: "arcanist",
            attributes: .defaultCreation,
            starterSkillID: "spell_formula",
            starterSpellIDs: ["mend_wounds"]
        )
        XCTAssertEqual(tryFailure(rpgCreateCharacter(badSpell)), .invalidStarterSpell("mend_wounds"))
    }

    func testRepairDropsUnknownAndCrossPathStateWithoutDroppingCharacter() {
        let raw = RPGCharacterState(
            version: 0,
            created: true,
            pathID: "arcanist",
            attributes: RPGAttributes(strength: 100, dexterity: 3, intelligence: 16, endurance: 9, luck: 6),
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
        XCTAssertEqual(repaired.attributes.total, RPGAttributes.creationBudget)
        XCTAssertEqual(repaired.skillRanks["spell_formula"], 1)
        XCTAssertNil(repaired.skillRanks["minor_glamour"])
        XCTAssertNil(repaired.skillRanks["guard_stance"])
        XCTAssertNil(repaired.skillRanks["not_real"])
        XCTAssertTrue(repaired.preparedSkillIDs.isEmpty)
        XCTAssertTrue(repaired.knownSpellIDs.contains("ignite"))
        XCTAssertFalse(repaired.knownSpellIDs.contains("blur"))
        XCTAssertFalse(repaired.knownSpellIDs.contains("mend_wounds"))
        XCTAssertEqual(repaired.preparedSpellIDs, ["ignite"])
        XCTAssertNil(repaired.selectedPreparedActionID)
        XCTAssertGreaterThanOrEqual(repaired.fatigue, 0)
        XCTAssertLessThanOrEqual(repaired.fatigue, rpgDerivedStats(repaired).maxFatigue)
        XCTAssertEqual(repaired.actionSequence, 0)
        XCTAssertEqual(repaired.activeCooldowns, [RPGCooldown(id: "ignite", remainingTicks: 12)])
        XCTAssertTrue(repaired.activeUpkeeps.isEmpty)
        XCTAssertEqual(rpgSpentSkillPoints(repaired), rpgEarnedSkillPoints(level: repaired.level))
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
            pathID: "warden",
            attributes: .defaultCreation,
            starterSkillID: "guard_stance"
        ))
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
            pathID: "arcanist",
            attributes: .defaultCreation,
            starterSkillID: "spell_formula",
            starterSpellIDs: ["ignite"]
        )))

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
            pathID: "arcanist", attributes: .defaultCreation,
            starterSkillID: "spell_formula", starterSpellIDs: ["ignite"])).get()
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
    }

    private func tryFailure(_ result: Result<RPGCharacterState, RPGCreationError>) -> RPGCreationError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}
