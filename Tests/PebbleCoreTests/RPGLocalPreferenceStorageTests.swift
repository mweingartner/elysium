import XCTest
import Foundation
import SQLite3
@testable import PebbleStorage

final class RPGLocalPreferenceStorageTests: XCTestCase {
    private func url(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "PebbleRPGLocalIntegrity-\(label)-\(UUID().uuidString).sqlite")
    }

    private func row(_ world: String, byte: UInt8 = 1) throws
        -> PebbleRPGLocalPreferenceStorageRow {
        try PebbleRPGLocalPreferenceStorageRow(
            worldRecordID: world, schemaVersion: 1, revision: 1,
            slotsPayload: Data(repeating: byte, count: 18),
            payloadDigest: Data(repeating: byte, count: 32),
            migrationOriginDigest: nil, migrationOriginRevision: nil)
    }

    private func fixture(_ label: String, migrated: Bool = true) throws
        -> (URL, PebbleStorageCoordinator, PebbleRPGLocalPreferencesStorage) {
        let databaseURL = url(label)
        let coordinator = try PebbleStorageCoordinator.open(databaseURL: databaseURL)
        try coordinator.legacyCore().putWorldRow(
            PebbleWorldStorageRow(id: "world", json: "{}", lastPlayed: 0))
        let facade = try coordinator.rpgLocalPreferences()
        if migrated {
            _ = try facade.materializeLegacy(
                sourceDigest: Data(repeating: 9, count: 32),
                absentDestination: row("world"))
        } else {
            _ = try facade.materializeIfAbsent(candidate: row("world"))
        }
        return (databaseURL, coordinator, facade)
    }

    private func raw(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw PebbleStorageError.invalidValue }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard rc == SQLITE_OK else { throw PebbleStorageError.invalidValue }
    }

    func testOriginAndMarkerTamperMatrixFailsClosed() throws {
        let mutations = [
            "DELETE FROM rpg_local_preference_migrations_v1 WHERE world_record_id='world'",
            "UPDATE rpg_local_preference_migrations_v1 SET destination_digest=zeroblob(32) WHERE world_record_id='world'",
            "PRAGMA ignore_check_constraints=ON; UPDATE rpg_local_preferences_v1 SET migration_origin_revision=NULL WHERE world_record_id='world'",
            "PRAGMA foreign_keys=OFF; DELETE FROM rpg_local_preferences_v1 WHERE world_record_id='world'",
            "PRAGMA foreign_keys=OFF; DELETE FROM worlds WHERE id='world'",
        ]
        for (index, mutation) in mutations.enumerated() {
            let (databaseURL, coordinator, facade) = try fixture("tamper-\(index)")
            try raw(databaseURL, mutation)
            XCTAssertThrowsError(try facade.read(worldRecordID: "world"), mutation)
            try coordinator.close()
        }
    }

    func testNonlegacyOriginTamperBlocksMaterializeAndCAS() throws {
        let (databaseURL, coordinator, facade) = try fixture("nonlegacy-origin", migrated: false)
        try raw(databaseURL, """
            PRAGMA ignore_check_constraints=ON;
            UPDATE rpg_local_preferences_v1
            SET migration_origin_digest=zeroblob(32),migration_origin_revision=1
            WHERE world_record_id='world'
            """)
        XCTAssertThrowsError(try facade.materializeIfAbsent(candidate: row("world", byte: 2)))
        let candidate = try PebbleRPGLocalPreferenceStorageRow(
            worldRecordID: "world", schemaVersion: 1, revision: 2,
            slotsPayload: Data(repeating: 2, count: 18),
            payloadDigest: Data(repeating: 2, count: 32),
            migrationOriginDigest: Data(repeating: 0, count: 32),
            migrationOriginRevision: 1)
        XCTAssertThrowsError(try facade.compareAndSwap(
            expectedRevision: 1, expectedDigest: Data(repeating: 1, count: 32),
            candidate: candidate))
        try coordinator.close()
    }

    func testAfterAuditTriggerInjectionCannotRunDuringWorldDelete() throws {
        let (databaseURL, coordinator, _) = try fixture("trigger-toctou", migrated: true)
        try raw(databaseURL, """
            CREATE TRIGGER hostile_rpg_delete AFTER DELETE ON rpg_local_preferences_v1
            BEGIN UPDATE worlds SET json='hostile' WHERE id=OLD.world_record_id; END
            """)
        XCTAssertThrowsError(try coordinator.legacyCore().deleteWorld(id: "world"))
        XCTAssertNotNil(try coordinator.legacyCore().getWorldRow(id: "world"))
        try coordinator.close()
    }
}
