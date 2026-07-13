import Foundation
import SQLite3
import XCTest
@testable import ElysiumCore

@MainActor
final class RPGStorageV5IsolationTests: XCTestCase {
    private func fixture(_ label: String) throws -> (URL, SaveDB) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ElysiumRPGV5Isolation-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("elysium.db")
        let database = try SaveDB.open(databaseURL: url, migrateLegacy: false)
        addTeardownBlock {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return (url, database)
    }

    private func scalar(_ url: URL, _ sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw CocoaError(.fileReadCorruptFile) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw CocoaError(.fileReadCorruptFile) }
        return sqlite3_column_int64(statement, 0)
    }

    func testV5WorldPlayerResumeAndGuestRoundTripsCreateNoRPGStorage() throws {
        let (url, database) = try fixture("no-bridge")
        database.putWorld(WorldRecord(id: "world", name: "World", seed: 5,
                                      gameMode: 0, difficulty: 2))
        database.putPlayer("world", ["rpgQuickSlots": ["LAN-envelope-must-stay-opaque"],
                                     "health": 17])
        database.putLANClientResume("host/world", ["protocol": 5, "opaque": "PBLQS1"])
        database.putLANPlayer(world: "world", playerID: "guest",
                              ["protocol": 5, "intent": "rpg-slot-assign"])

        XCTAssertEqual(database.getWorld("world")?.name, "World")
        XCTAssertEqual(database.getPlayer("world")?["health"] as? Int, 17)
        XCTAssertEqual(database.getLANClientResume("host/world")?["protocol"] as? Int, 5)
        XCTAssertEqual(database.getLANPlayer(world: "world", playerID: "guest")?["protocol"]
            as? Int, 5)
        XCTAssertEqual(try scalar(url, """
            SELECT count(*) FROM sqlite_master WHERE name IN (
              'pebble_storage_component_schema_v1','rpg_local_preferences_v1',
              'rpg_local_preference_migrations_v1','lan_client_credentials_v6',
              'lan_client_owner_checkpoint_v6','lan_client_pending_disposition_v6',
              'lan_client_notification_inbox_v6')
            """), 0)
    }

    func testLocalPreferenceMaterializationDoesNotConsumeOrMutateV5Rows() throws {
        let (url, database) = try fixture("local-does-not-consume-v5")
        database.putWorld(WorldRecord(id: "world", name: "World", seed: 6,
                                      gameMode: 0, difficulty: 2))
        let player: [String: Any] = [
            "rpgQuickSlots": ["LAN-envelope-must-stay-opaque"], "health": 19,
        ]
        let resume: [String: Any] = ["protocol": 5, "opaque": "PBLQS1"]
        let guest: [String: Any] = ["protocol": 5, "intent": "rpg-slot-assign"]
        database.putPlayer("world", player)
        database.putLANClientResume("host/world", resume)
        database.putLANPlayer(world: "world", playerID: "guest", guest)

        let initial = try database.materializeRPGQuickSlotPreferences(
            worldRecordID: "world",
            defaults: RPGQuickSlotPreferences(tokens: ["skill:mining"]))
        _ = try database.compareAndSwapRPGQuickSlotPreferences(
            worldRecordID: "world", expected: initial,
            candidatePreferences: RPGQuickSlotPreferences(tokens: ["skill:logging"]))

        XCTAssertEqual(database.getPlayer("world")?["health"] as? Int, 19)
        XCTAssertEqual((database.getPlayer("world")?["rpgQuickSlots"] as? [String])?.first,
                       "LAN-envelope-must-stay-opaque")
        XCTAssertEqual(database.getLANClientResume("host/world")?["opaque"] as? String,
                       "PBLQS1")
        XCTAssertEqual(database.getLANPlayer(world: "world", playerID: "guest")?["intent"]
            as? String, "rpg-slot-assign")
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM rpg_local_preferences_v1"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM rpg_local_preference_migrations_v1"), 0)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM lan_player_resume"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM lan_players"), 1)
    }

    func testProtocol5SemanticRequestsCreateNoLocalOrClientRPGStorageRows() throws {
        let (url, database) = try fixture("semantic-zero-fallback")
        let game = GameCore(db: database)
        var localPreferenceIOCount = 0
        game._testRPGLocalPreferenceBeforeIO = { _ in localPreferenceIOCount += 1 }
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "protocol5-world", worldName: "Protocol 5", seed: 5,
            gameMode: GameMode.survival, difficulty: 2, dimension: 0,
            playerCount: 2, rpgClassesEnabled: true
        ))
        let draft = RPGCreationDraft(pathID: "arcanist", attributes: .defaultCreation,
                                     starterSkillID: "spell_formula", starterSpellIDs: [])
        XCTAssertNil(game.player.createRPGCharacter(draft))
        let before = game.player.rpg
        var intents: [LANRPGIntent] = []
        game.lanRPGIntentHandler = { intents.append($0) }

        _ = game.requestRPGCreateCharacter(draft)
        _ = game.requestRPGLearnSkill("spell_formula")
        _ = game.requestRPGAssignPreparedActionToQuickSlot(kind: .skill,
                                                            id: "spell_formula", slot: 0)
        _ = game.requestRPGUseSelectedAction()

        XCTAssertEqual(game.player.rpg, before)
        XCTAssertTrue(intents.isEmpty)
        XCTAssertEqual(localPreferenceIOCount, 0,
                       "protocol 5 must invoke none of the four local SaveDB operations")
        XCTAssertEqual(try scalar(url, """
            SELECT count(*) FROM sqlite_master WHERE name IN (
              'pebble_storage_component_schema_v1','rpg_local_preferences_v1',
              'rpg_local_preference_migrations_v1','lan_client_credentials_v6',
              'lan_client_owner_checkpoint_v6','lan_client_pending_disposition_v6',
              'lan_client_notification_inbox_v6')
            """), 0)
    }

    func testV5NetworkingSourceHasNoRPGStorageBridgeOrV6CheckpointFacade() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let root = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/ElysiumCore/Net/LANMultiplayer.swift"), encoding: .utf8)
        for forbidden in ["rpg_local_preferences_v1", "materializeRPGQuickSlotPreferences",
                          "compareAndSwapRPGQuickSlotPreferences",
                          "clientAuthorityCheckpointV6", "ElysiumRPGLocalPreferencesStorage"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func testAppSyntheticBoundaryCallsLiveProtocol5RejectionAndCheckedCounterFirst() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let root = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let uiSource = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/UIManagerM.swift"), encoding: .utf8)
        let transportSource = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/LANTransport.swift"), encoding: .utf8)
        let call = try XCTUnwrap(uiSource.range(of:
            "LANMultiplayerManager.shared.rejectProtocol5RPGSemanticOperation"))
        let dispatch = try XCTUnwrap(uiSource.range(of:
            "return game.dispatchSyntheticRPGSemanticActivation", range: call.lowerBound..<uiSource.endIndex))
        XCTAssertLessThan(call.lowerBound, dispatch.lowerBound,
                          "transport rejection must be resolved before GameCore submission")
        for required in ["protocol5RPGSemanticRejectionCount",
                         "addingReportingOverflow(1)",
                         "protocol5RPGSemanticRejectionCounterExhausted",
                         "return .unavailable"] {
            XCTAssertTrue(transportSource.contains(required), required)
        }
        XCTAssertFalse(uiSource.contains("lanRPGIntentHandler"),
                       "the semantic app boundary must not translate through the legacy handler")
    }
}
