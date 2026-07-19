import XCTest
@testable import ElysiumCore

@MainActor
final class RPGSemanticGuardIntegrationTests: XCTestCase {
    private struct FailingEncodable: Encodable {
        struct Failure: Error {}
        func encode(to encoder: Encoder) throws { throw Failure() }
    }
    private func localGame(_ label: String = "local") throws -> GameCore {
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self, label: "rpg-guard-\(label)"))
        game.createWorld(name: "RPG Guard \(label)", seedText: "424242",
                         mode: GameMode.survival, difficulty: 2)
        return game
    }

    private func lanGame(_ label: String = "lan") throws -> GameCore {
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self, label: "rpg-guard-\(label)"))
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "protocol5-\(label)", worldName: "Protocol 5", seed: 7,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue,
            playerCount: 2, rpgClassesEnabled: true
        ))
        return game
    }

    private func descriptor(_ command: RPGSemanticCommand,
                            id: String = "synthetic:operation") -> RPGSemanticDescriptor {
        RPGSemanticDescriptor(
            id: RPGUIElementID(rawValue: id)!, role: .button,
            label: "Synthetic operation", enabled: true, isFocusable: true,
            frame: RPGLogicalRect(x: 0, y: 0, width: 20, height: 20),
            actionCommand: command
        )
    }

    private var arcanistDraft: RPGCreationDraft {
        RPGCreationDraft(pathID: "arcanist", starterSkillID: "spell_formula")
    }

    func testAuthorityAndPreferenceScopeProjectOnlyForExactLocalWorld() throws {
        let local = try localGame()
        XCTAssertEqual(local.rpgAuthorityPresentation.phase, .localReady)
        guard case .localWorld(let recordID)? = local.rpgLocalPreferenceScope else {
            return XCTFail("local world must project its exact typed preference scope")
        }
        XCTAssertEqual(recordID, local.worldRec?.id)
        XCTAssertFalse(local.rpgLocalPreferenceWritable,
                       "writability remains closed until the next lifecycle build step")

        let lan = try lanGame()
        XCTAssertEqual(lan.rpgAuthorityPresentation, .unavailable)
        XCTAssertNil(lan.rpgLocalPreferenceScope)
        XCTAssertFalse(lan.rpgLocalPreferenceWritable)
        let input = try XCTUnwrap(lan.rpgSemanticInputSnapshot(for: .create(arcanistDraft)))
        XCTAssertEqual(input.authorityPhase, .unavailable)
        XCTAssertNil(input.localPreferenceScope)
        XCTAssertFalse(input.localPreferenceWritable)
    }

    @MainActor
    func testPassiveRuntimeSnapshotIsStableAndDoesNotMutateGameState() throws {
        let game = try localGame("passive-snapshot")
        let beforeRPG = game.player.rpg
        let beforeSelectedSlot = game.player.selectedSlot
        let beforeQuickSlots = game.rpgQuickSlotPreferences
        let beforeHighContrast = game.settings.highContrast
        let beforeReduceMotion = game.settings.reduceMotion
        let beforeTutorialVersion = game.settings.rpgTutorialVersion

        let first = try XCTUnwrap(game.rpgScreenRuntimeSnapshot())
        let second = try XCTUnwrap(game.rpgScreenRuntimeSnapshot())
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(first.worldEntryGeneration, 0)
        XCTAssertGreaterThan(first.inventoryRevision, 0)
        XCTAssertGreaterThan(first.equipmentFocusRevision, 0)
        XCTAssertEqual(first.authority.phase, .localReady)
        XCTAssertEqual(game.player.rpg, beforeRPG)
        XCTAssertEqual(game.player.selectedSlot, beforeSelectedSlot)
        XCTAssertEqual(game.rpgQuickSlotPreferences, beforeQuickSlots)
        XCTAssertEqual(game.settings.highContrast, beforeHighContrast)
        XCTAssertEqual(game.settings.reduceMotion, beforeReduceMotion)
        XCTAssertEqual(game.settings.rpgTutorialVersion, beforeTutorialVersion)

        let model = rpgBuildPassiveScreenModel(first.modelInput(
            viewportWidth: 700, viewportHeight: 420))
        XCTAssertTrue(model.descriptors.allSatisfy { $0.actionCommand == nil })
        XCTAssertEqual(game.player.rpg, beforeRPG)
        XCTAssertEqual(game.rpgQuickSlotPreferences, beforeQuickSlots)
    }

    @MainActor
    func testPassiveRuntimeSnapshotFailsClosedForProtocolFiveLANAuthority() throws {
        let game = try lanGame("passive-snapshot")
        let snapshot = try XCTUnwrap(game.rpgScreenRuntimeSnapshot())
        XCTAssertEqual(snapshot.authority.phase, .unavailable)
        XCTAssertNil(snapshot.localPreferenceScope)
        XCTAssertFalse(snapshot.localPreferenceWritable)
        XCTAssertGreaterThan(snapshot.worldEntryGeneration, 0)
        let model = rpgBuildPassiveScreenModel(snapshot.modelInput(
            viewportWidth: 700, viewportHeight: 420, tab: .progression))
        XCTAssertEqual(model.authority.visibleTitle,
                       rpgAuthorityPhasePresentation(.unavailable).visibleTitle)
        XCTAssertTrue(model.descriptors.allSatisfy { $0.actionCommand == nil })
    }

    @MainActor
    func testCommittedActionableSnapshotBindsModelToExactRuntimeInputs() throws {
        let game = try localGame("committed-model")
        let runtime = try XCTUnwrap(game.rpgScreenRuntimeSnapshot())
        // A complete, valid draft (path + sub-class + 3 default starting skills) so the Review
        // step's Accept button carries a real .create command.
        var creation = rpgInitialCreationSession()
        creation = try rpgReduceCreationSession(creation, command: .choosePath("warden")).get()
        creation = try rpgReduceCreationSession(creation, command: .chooseBranch("warden_guardian")).get()
        creation = try rpgReduceCreationSession(creation, command: .confirmStartingSkills).get()
        let model = rpgBuildScreenModel(runtime.modelInput(
            viewportWidth: 700, viewportHeight: 420, creation: creation))
        let snapshot = try XCTUnwrap(RPGCommittedSemanticSnapshot(
            screenInstanceID: 71, semanticRevision: 19, model: model, runtime: runtime))
        let actionable = model.descriptors.filter { $0.actionCommand != nil }
        XCTAssertEqual(snapshot.semanticInputs.count, actionable.count)
        for descriptor in actionable {
            let input = try XCTUnwrap(snapshot.semanticInputs[descriptor.id])
            XCTAssertEqual(input.worldEntryGeneration, runtime.worldEntryGeneration)
            XCTAssertEqual(input.inventoryDigest, runtime.inventoryDigest)
            XCTAssertEqual(input.equipmentFocusDigest, runtime.equipmentFocusDigest)
        }
        let create = try XCTUnwrap(actionable.first { descriptor in
            guard let command = descriptor.actionCommand else { return false }
            if case .create = command { return true }
            return false
        })
        let boundary = RPGSemanticActivationBoundary()
        let capture = try XCTUnwrap(boundary.capture(
            screenInstanceID: snapshot.screenInstanceID,
            semanticRevision: snapshot.semanticRevision, descriptor: create,
            input: try XCTUnwrap(snapshot.semanticInputs[create.id])))
        XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
            capture, source: .keyboard, using: boundary,
            screenInstanceID: snapshot.screenInstanceID,
            semanticRevision: snapshot.semanticRevision, descriptor: create),
            .dispatched(serial: 1))
        XCTAssertTrue(game.player.rpg.created)
        XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
            capture, source: .mouse, using: boundary,
            screenInstanceID: snapshot.screenInstanceID,
            semanticRevision: snapshot.semanticRevision, descriptor: create),
            .invalidOrReplayedReceipt)
    }

    @MainActor
    func testFreshLocalActivationDispatchesOnceAndReplayCannotMutate() throws {
        let game = try localGame("fresh")
        let command = RPGSemanticCommand.create(arcanistDraft)
        let operation = descriptor(command)
        let boundary = RPGSemanticActivationBoundary()
        let capture = try XCTUnwrap(game.captureSyntheticRPGSemanticActivation(
            using: boundary, screenInstanceID: 11, semanticRevision: 17,
            descriptor: operation
        ))

        XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
            capture, source: .keyboard, using: boundary,
            screenInstanceID: 11, semanticRevision: 17, descriptor: operation
        ), .dispatched(serial: 1))
        XCTAssertTrue(game.player.rpg.created)
        let committed = game.player.rpg
        XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
            capture, source: .accessibility, using: boundary,
            screenInstanceID: 11, semanticRevision: 17, descriptor: operation
        ), .invalidOrReplayedReceipt)
        XCTAssertEqual(game.player.rpg, committed)
    }

    @MainActor
    func testScreenRuleAndSessionChangesConsumeThenRejectWithoutMutation() throws {
        do {
            let game = try localGame("screen")
            let operation = descriptor(.create(arcanistDraft))
            let boundary = RPGSemanticActivationBoundary()
            let capture = try XCTUnwrap(game.captureSyntheticRPGSemanticActivation(
                using: boundary, screenInstanceID: 1, semanticRevision: 1,
                descriptor: operation))
            XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
                capture, source: .mouse, using: boundary,
                screenInstanceID: 2, semanticRevision: 1, descriptor: operation),
                .staleRequiresFreshActivation)
            XCTAssertFalse(game.player.rpg.created)
            XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
                capture, source: .mouse, using: boundary,
                screenInstanceID: 1, semanticRevision: 1, descriptor: operation),
                .invalidOrReplayedReceipt)
        }

        do {
            let game = try localGame("rule")
            let operation = descriptor(.create(arcanistDraft))
            let boundary = RPGSemanticActivationBoundary()
            let capture = try XCTUnwrap(game.captureSyntheticRPGSemanticActivation(
                using: boundary, screenInstanceID: 1, semanticRevision: 1,
                descriptor: operation))
            game.setGameRule(RPG_CLASSES_GAME_RULE, 0)
            XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
                capture, source: .controller, using: boundary,
                screenInstanceID: 1, semanticRevision: 1, descriptor: operation),
                .staleRequiresFreshActivation)
            XCTAssertFalse(game.player.rpg.created)
        }

        do {
            let game = try localGame("equipment-focus")
            let operation = descriptor(.create(arcanistDraft))
            let boundary = RPGSemanticActivationBoundary()
            let capture = try XCTUnwrap(game.captureSyntheticRPGSemanticActivation(
                using: boundary, screenInstanceID: 1, semanticRevision: 1,
                descriptor: operation))
            game.player.selectedSlot = 1
            XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
                capture, source: .keyboard, using: boundary,
                screenInstanceID: 1, semanticRevision: 1, descriptor: operation),
                .staleRequiresFreshActivation)
            XCTAssertFalse(game.player.rpg.created)
        }

        do {
            let game = try localGame("scope")
            let operation = descriptor(.create(arcanistDraft))
            let boundary = RPGSemanticActivationBoundary()
            let capture = try XCTUnwrap(game.captureSyntheticRPGSemanticActivation(
                using: boundary, screenInstanceID: 1, semanticRevision: 1,
                descriptor: operation))
            game.enterLANClientWorld(LANWorldSummary(
                worldID: "replacement", worldName: "Replacement", seed: 9,
                gameMode: GameMode.survival, difficulty: 2, dimension: 0,
                playerCount: 2, rpgClassesEnabled: true))
            var intents: [LANRPGIntent] = []
            game.lanRPGIntentHandler = { intents.append($0) }
            let before = game.player.rpg
            XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
                capture, source: .accessibility, using: boundary,
                screenInstanceID: 1, semanticRevision: 1, descriptor: operation),
                .staleRequiresFreshActivation)
            XCTAssertEqual(game.player.rpg, before)
            XCTAssertTrue(intents.isEmpty)
        }
    }

    @MainActor
    func testInventoryOnlyAndEquipmentOnlyChangesInvalidateIndependentDigests() throws {
        do {
            let game = try localGame("inventory-digest")
            let operation = descriptor(.create(arcanistDraft))
            let before = try XCTUnwrap(game.rpgSemanticInputSnapshot(for: .create(arcanistDraft)))
            let boundary = RPGSemanticActivationBoundary()
            let capture = try XCTUnwrap(game.captureSyntheticRPGSemanticActivation(
                using: boundary, screenInstanceID: 1, semanticRevision: 1,
                descriptor: operation))
            game.player.inventory[10] = ItemStack(iid("dirt"), 1)
            let after = try XCTUnwrap(game.rpgSemanticInputSnapshot(for: .create(arcanistDraft)))
            XCTAssertNotEqual(before.inventoryDigest, after.inventoryDigest)
            XCTAssertEqual(before.equipmentFocusDigest, after.equipmentFocusDigest)
            XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
                capture, source: .keyboard, using: boundary,
                screenInstanceID: 1, semanticRevision: 1, descriptor: operation),
                .staleRequiresFreshActivation)
            XCTAssertFalse(game.player.rpg.created)
        }

        do {
            let game = try localGame("equipment-digest")
            let operation = descriptor(.create(arcanistDraft))
            let before = try XCTUnwrap(game.rpgSemanticInputSnapshot(for: .create(arcanistDraft)))
            let boundary = RPGSemanticActivationBoundary()
            let capture = try XCTUnwrap(game.captureSyntheticRPGSemanticActivation(
                using: boundary, screenInstanceID: 1, semanticRevision: 1,
                descriptor: operation))
            game.player.selectedSlot = 1
            let after = try XCTUnwrap(game.rpgSemanticInputSnapshot(for: .create(arcanistDraft)))
            XCTAssertEqual(before.inventoryDigest, after.inventoryDigest)
            XCTAssertNotEqual(before.equipmentFocusDigest, after.equipmentFocusDigest)
            XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
                capture, source: .controller, using: boundary,
                screenInstanceID: 1, semanticRevision: 1, descriptor: operation),
                .staleRequiresFreshActivation)
            XCTAssertFalse(game.player.rpg.created)
        }
    }

    func testSemanticDigestEncodingFailureFailsClosedWithoutSentinel() {
        XCTAssertNil(rpgSemanticInventoryDigest(FailingEncodable()))
        XCTAssertNil(rpgSemanticEquipmentFocusDigest(FailingEncodable()))
        XCTAssertNotEqual(rpgSemanticInventoryDigest(["same"]),
                          rpgSemanticEquipmentFocusDigest(["same"]),
                          "digest domains must remain independent")
    }

    func testProtocol5DeniesEveryLegacyAuthoritativeAndSlotEntryBeforeMutation() throws {
        let game = try lanGame("all-operations")
        XCTAssertNil(game.player.createRPGCharacter(arcanistDraft))
        let beforeRPG = game.player.rpg
        let beforeInventory = game.player.inventory
        let beforeCell = game.world.getBlock(0, 64, 0)
        var intents: [LANRPGIntent] = []
        game.lanRPGIntentHandler = { intents.append($0) }

        _ = game.requestRPGCreateCharacter(arcanistDraft)
        _ = game.requestRPGLearnSkill("spell_formula")
        _ = game.requestRPGTogglePreparedSkill("spell_formula")
        _ = game.requestRPGTogglePreparedSpell("ignite")
        _ = game.requestRPGSelectPreparedSkill("spell_formula")
        _ = game.requestRPGSelectPreparedSpell("ignite")
        _ = game.requestRPGAssignPreparedActionToQuickSlot(kind: .skill,
                                                            id: "spell_formula", slot: 0)
        _ = game.requestRPGClearActionQuickSlot(0)
        _ = game.requestRPGCyclePreparedSpell()
        _ = game.requestRPGCyclePreparedAction()
        _ = game.requestRPGCastSelectedSpell()
        _ = game.requestRPGUseSelectedAction()
        _ = game.requestRPGUseActionQuickSlot(0)

        XCTAssertEqual(game.player.rpg, beforeRPG)
        XCTAssertEqual(game.player.inventory, beforeInventory)
        XCTAssertEqual(game.world.getBlock(0, 64, 0), beforeCell)
        XCTAssertTrue(intents.isEmpty)
    }

    @MainActor
    func testProtocol5SemanticCaptureConsumesAndReturnsUnavailableWithZeroFallback() throws {
        let game = try lanGame("semantic")
        var intents: [LANRPGIntent] = []
        game.lanRPGIntentHandler = { intents.append($0) }
        let operation = descriptor(.create(arcanistDraft))
        let boundary = RPGSemanticActivationBoundary()
        let before = game.player.rpg
        let capture = try XCTUnwrap(game.captureSyntheticRPGSemanticActivation(
            using: boundary, screenInstanceID: 5, semanticRevision: 8,
            descriptor: operation))
        XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
            capture, source: .mouse, using: boundary,
            screenInstanceID: 5, semanticRevision: 8, descriptor: operation), .unavailable)
        XCTAssertEqual(game.player.rpg, before)
        XCTAssertTrue(intents.isEmpty)
        XCTAssertEqual(game.dispatchSyntheticRPGSemanticActivation(
            capture, source: .mouse, using: boundary,
            screenInstanceID: 5, semanticRevision: 8, descriptor: operation),
            .invalidOrReplayedReceipt)
    }
}
