import XCTest
@testable import ElysiumCore

/// The legacy rule remains decodable for old world records, but new worlds must
/// begin with its class system retired and a usage-tree player envelope.
@MainActor
final class RPGClassesToggleTests: XCTestCase {
    private var arcanistDraft: RPGCreationDraft {
        RPGCreationDraft(pathID: "arcanist", branchID: "arcanist_elementalist",
                         startingSkillIDs: rpgBranchDefinition("arcanist_elementalist")!.skillIDs)
    }

    // MARK: - createWorld(rpgClassesEnabled:)

    func testCreateWorldDefaultsToSkillTreesWithLegacyRuleRetired() throws {
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self, label: "classes-default"))
        game.createWorld(name: "Default Skills", seedText: "1", mode: GameMode.survival, difficulty: 2)

        XCTAssertFalse(game.player.rpgClassesEnabled())
        XCTAssertEqual(game.worldRec?.gameRules[RPG_CLASSES_GAME_RULE], 0)
        XCTAssertNotNil(game.player.rpg.skillTrees)
        XCTAssertNotEqual(game.rpgAuthorityPresentation, .unavailable,
                          "a skill-tree world must expose the local action-bar authority projection")
    }

    func testCreateWorldWithClassesDisabledClearsTheGameRuleAndFlipsThePlayerFlag() throws {
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self, label: "classes-off"))
        game.createWorld(name: "No Classes", seedText: "2", mode: GameMode.survival, difficulty: 2,
                         rpgClassesEnabled: false)

        XCTAssertFalse(game.player.rpgClassesEnabled())
        XCTAssertEqual(game.worldRec?.gameRules[RPG_CLASSES_GAME_RULE], 0)
        XCTAssertNotNil(game.player.rpg.skillTrees)
        XCTAssertNotEqual(game.rpgAuthorityPresentation, .unavailable,
                          "the retired legacy rule must not disable usage-tree actions")
    }

    // MARK: - Whole-subsystem no-op when the world rule is off

    func testRPGActionRequestsNoOpAndReportClassesDisabledWhenTheWorldRuleIsOff() throws {
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self, label: "classes-off-actions"))
        game.createWorld(name: "No Classes Actions", seedText: "3", mode: GameMode.survival, difficulty: 2,
                         rpgClassesEnabled: false)

        XCTAssertEqual(game.requestRPGCreateCharacter(arcanistDraft), RPGActionFailure.classesDisabled.description)
        XCTAssertFalse(game.player.rpg.created, "character creation must be a true no-op, not a partial write")

        XCTAssertEqual(game.requestRPGLearnSkill("spell_formula"), RPGActionFailure.classesDisabled.description)
        XCTAssertEqual(game.requestRPGUseSelectedAction(), RPGActionFailure.actionNotPrepared.description)
        XCTAssertEqual(game.requestRPGTogglePreparedSkill("spell_formula"),
                       RPGActionFailure.classesDisabled.description)
    }

    func testGameCoreClassCreationCannotReplaceASkillTreeEvenWhenLegacyRuleIsEnabled() throws {
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self, label: "classes-on-actions"))
        game.createWorld(name: "Stale Rule", seedText: "4", mode: GameMode.survival, difficulty: 2,
                         rpgClassesEnabled: true)

        let before = game.player.rpg
        XCTAssertNotNil(before.skillTrees)
        let result = game.requestRPGCreateCharacter(arcanistDraft)
        XCTAssertEqual(result, RPGActionFailure.classesDisabled.description)
        XCTAssertEqual(game.player.rpg, before,
                       "the UI/GameCore route must not replace a usage tree with a legacy class")
    }

    // MARK: - gameRules persistence round-trip

    func testDisabledClassesRuleRoundTripsThroughSaveDBStorage() throws {
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "classes-persist")
        let game = GameCore(db: database)
        game.createWorld(name: "Persisted Off", seedText: "5", mode: GameMode.survival, difficulty: 2,
                         rpgClassesEnabled: false)
        let worldID = try XCTUnwrap(game.worldRec?.id)

        // Read back through the real storage engine (not the in-memory WorldRecord) to prove the
        // rule survives the actual encode/JSON/SQLite round trip putWorld/getWorld perform.
        let reloadedRecord = try XCTUnwrap(database.getWorld(worldID))
        XCTAssertEqual(reloadedRecord.gameRules[RPG_CLASSES_GAME_RULE], 0)

        // And a fresh GameCore (simulating relaunch) picks the rule back up onto the player.
        let relaunched = GameCore(db: database)
        relaunched.loadWorld(worldID)
        XCTAssertFalse(relaunched.player.rpgClassesEnabled())
    }

    func testEnabledClassesRuleRoundTripsThroughSaveDBStorage() throws {
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "classes-persist-on")
        let game = GameCore(db: database)
        game.createWorld(name: "Persisted On", seedText: "6", mode: GameMode.survival, difficulty: 2,
                         rpgClassesEnabled: true)
        let worldID = try XCTUnwrap(game.worldRec?.id)

        let reloadedRecord = try XCTUnwrap(database.getWorld(worldID))
        XCTAssertEqual(reloadedRecord.gameRules[RPG_CLASSES_GAME_RULE], 1)

        let relaunched = GameCore(db: database)
        relaunched.loadWorld(worldID)
        XCTAssertTrue(relaunched.player.rpgClassesEnabled())
    }

    // MARK: - enterWorld does not force-open a Skills workspace

    func testFreshWorldEntryDoesNotForceOpenTheRPGCharacterScreen() throws {
        let host = RPGClassesToggleTestHost()
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self, label: "no-force-open"))
        game.host = host

        game.createWorld(name: "Fresh Entry", seedText: "7", mode: GameMode.survival, difficulty: 2)

        XCTAssertTrue(game.inWorld)
        XCTAssertFalse(game.player.rpgClassesEnabled())
        XCTAssertFalse(game.player.rpg.created)
        XCTAssertNotNil(game.player.rpg.skillTrees)
        XCTAssertFalse(host.openedScreens.contains("rpg"),
                       "the Skills workspace must stay one click away, not auto-open on world entry")
        XCTAssertTrue(host.closedAllScreens, "entry still clears any stale screen from a prior world")
    }

    func testFreshWorldEntryWithClassesDisabledAlsoDoesNotOpenTheRPGScreen() throws {
        let host = RPGClassesToggleTestHost()
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self, label: "no-force-open-off"))
        game.host = host

        game.createWorld(name: "Fresh Entry Off", seedText: "8", mode: GameMode.survival, difficulty: 2,
                         rpgClassesEnabled: false)

        XCTAssertTrue(game.inWorld)
        XCTAssertFalse(host.openedScreens.contains("rpg"))
    }
}

private final class RPGClassesToggleTestHost: GameHost {
    var openedScreens: [String] = []
    var closedAllScreens = false
    func hasScreen() -> Bool { false }
    func screenPausesGame() -> Bool { false }
    func openScreen(_ kind: String, _ data: ScreenData?) { openedScreens.append(kind) }
    func openTrading(_ villager: Mob) {}
    func openVehicleChest(_ kind: String, _ vehicle: Entity) {}
    func openChat(_ prefix: String) {}
    func openDeathScreen(_ message: String) {}
    func openPauseScreen() {}
    func openTitleScreen() {}
    func closeAllScreens() { closedAllScreens = true }
    func releasePointer() {}
    func capturePointer() {}
    func showActionBar(_ text: String, _ time: Int) {}
    func pushChat(_ line: String) {}
    func pushToast(_ adv: AdvancementDef) {}
    func setBossBars(_ bars: [BossBarInfo]) {}
    func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double,
                   _ volume: Double, _ pitch: Double) {}
    func playUI(_ name: String) {}
    func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
    func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {}
    func tickMusic(_ mood: String, _ enabled: Bool) {}
    func stopDisc() {}
    func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double,
                      _ count: Int, _ spread: Double, _ cell: Int) {}
    func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double,
                            _ groundY: Double) {}
    func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {}
    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {}
    func clearAllSections() {}
}
