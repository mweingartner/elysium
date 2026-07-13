import Foundation
import SQLite3
import XCTest
@testable import ElysiumStorage

final class RPGLocalPreferenceStorageBoundaryTests: XCTestCase {
    private func databaseURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ElysiumRPGStorageBoundary-\(label)-\(UUID().uuidString).sqlite")
    }

    private func preference(world: String, revision: UInt64 = 1,
                            payloadBytes: Int = 18, byte: UInt8 = 1,
                            origin: (Data, UInt64)? = nil) throws
        -> ElysiumRPGLocalPreferenceStorageRow {
        try ElysiumRPGLocalPreferenceStorageRow(
            worldRecordID: world, schemaVersion: 1, revision: revision,
            slotsPayload: Data(repeating: byte, count: payloadBytes),
            payloadDigest: Data(repeating: byte, count: 32),
            migrationOriginDigest: origin?.0, migrationOriginRevision: origin?.1)
    }

    private func execute(_ url: URL, _ sql: String) -> Int32 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { return SQLITE_CANTOPEN }
        defer { sqlite3_close(database) }
        return sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func scalar(_ url: URL, _ sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw ElysiumStorageError.invalidValue }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ElysiumStorageError.invalidValue }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ElysiumStorageError.invalidValue }
        return sqlite3_column_int64(statement, 0)
    }

    private func installWorld(_ id: String, core: ElysiumLegacyCoreStorage) throws {
        try core.putWorldRow(ElysiumWorldStorageRow(id: id, json: "{}", lastPlayed: 0))
    }

    func testWorldIDUTF8ZeroOneSixtyFourSixtyFiveAndBinaryNormalization() throws {
        XCTAssertThrowsError(try preference(world: ""))
        XCTAssertNoThrow(try preference(world: "a"))
        XCTAssertNoThrow(try preference(world: String(repeating: "a", count: 64)))
        XCTAssertThrowsError(try preference(world: String(repeating: "a", count: 65)))

        let url = databaseURL("binary")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        let composed = "\u{00e9}"
        let decomposed = "e\u{0301}"
        XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        try installWorld(composed, core: core)
        try installWorld(decomposed, core: core)
        let facade = try coordinator.rpgLocalPreferences()
        _ = try facade.materializeIfAbsent(candidate: preference(world: composed, byte: 1))
        _ = try facade.materializeIfAbsent(candidate: preference(world: decomposed, byte: 2))
        XCTAssertEqual(try facade.read(worldRecordID: composed)?.payloadDigest,
                       Data(repeating: 1, count: 32))
        XCTAssertEqual(try facade.read(worldRecordID: decomposed)?.payloadDigest,
                       Data(repeating: 2, count: 32))
        try coordinator.close()
    }

    func testWrongSQLiteStorageClassesAreRejectedByExactDDL() throws {
        let url = databaseURL("storage-classes")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        try installWorld("w", core: coordinator.legacyCore())
        _ = try coordinator.rpgLocalPreferences()
        let mutations = [
            "INSERT INTO rpg_local_preferences_v1 VALUES(x'77',1,1,zeroblob(18),zeroblob(32),NULL,NULL)",
            "INSERT INTO rpg_local_preferences_v1 VALUES('w',x'01',1,zeroblob(18),zeroblob(32),NULL,NULL)",
            "INSERT INTO rpg_local_preferences_v1 VALUES('w',1,x'01',zeroblob(18),zeroblob(32),NULL,NULL)",
            "INSERT INTO rpg_local_preferences_v1 VALUES('w',1,1,'payload',zeroblob(32),NULL,NULL)",
            "INSERT INTO rpg_local_preferences_v1 VALUES('w',1,1,zeroblob(18),'digest',NULL,NULL)",
        ]
        for sql in mutations { XCTAssertNotEqual(execute(url, sql), SQLITE_OK, sql) }
        try coordinator.close()
    }

    func testPerRowAccountedBytes4095_4096_4097() throws {
        let world = "w"
        // Nil-origin accounting is 299 bytes plus the exact UTF-8 world ID and payload.
        XCTAssertNoThrow(try preference(world: world, payloadBytes: 3_795))
        XCTAssertNoThrow(try preference(world: world, payloadBytes: 3_796))
        XCTAssertThrowsError(try preference(world: world, payloadBytes: 3_797))
    }

    func testPreferenceRowCount255_256_257AndAggregateCapMinusOneExact() throws {
        let url = databaseURL("count-and-aggregate")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        let facade = try coordinator.rpgLocalPreferences()
        var lastID = ""
        var lastRow: ElysiumRPGLocalPreferenceStorageRow?
        for index in 0..<256 {
            let id = String(format: "%064x", index)
            try installWorld(id, core: core)
            let bytes = index == 255 ? 3_732 : 3_733 // accounted 4095, otherwise 4096
            let row = try preference(world: id, payloadBytes: bytes,
                                     byte: UInt8(truncatingIfNeeded: index + 1))
            _ = try facade.materializeIfAbsent(candidate: row)
            lastID = id; lastRow = row
            if index == 254 { XCTAssertNotNil(try facade.read(worldRecordID: id)) }
        }
        XCTAssertNotNil(try facade.read(worldRecordID: lastID)) // 256 rows, aggregate cap - 1

        let exact = try preference(world: lastID, revision: 2, payloadBytes: 3_733, byte: 77)
        _ = try facade.compareAndSwap(expectedRevision: 1,
                                      expectedDigest: try XCTUnwrap(lastRow).payloadDigest,
                                      candidate: exact)
        XCTAssertEqual(try facade.read(worldRecordID: lastID), exact) // exact 1 MiB cap

        let overflowID = "overflow"
        try installWorld(overflowID, core: core)
        XCTAssertThrowsError(try facade.materializeIfAbsent(
            candidate: preference(world: overflowID)))
        XCTAssertNil(try facade.read(worldRecordID: overflowID))
        try coordinator.close()
    }

    func testExistingDestinationWinsMarkerIsImmutableAndAdvancedRowIsAccepted() throws {
        let url = databaseURL("marker")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        try installWorld("w", core: coordinator.legacyCore())
        let facade = try coordinator.rpgLocalPreferences()
        let existing = try preference(world: "w", byte: 3)
        _ = try facade.materializeIfAbsent(candidate: existing)
        let source = Data(repeating: 9, count: 32)
        let receipt = try facade.materializeLegacy(
            sourceDigest: source, absentDestination: preference(world: "w", byte: 4))
        XCTAssertFalse(receipt.insertedDestination)
        XCTAssertEqual(receipt.preference.payloadDigest, existing.payloadDigest)
        XCTAssertEqual(receipt.marker.destinationDigest, existing.payloadDigest)
        XCTAssertThrowsError(try facade.materializeLegacy(
            sourceDigest: Data(repeating: 8, count: 32),
            absentDestination: preference(world: "w", byte: 5)))

        let advanced = try preference(world: "w", revision: 2, byte: 6,
                                      origin: (existing.payloadDigest, 1))
        _ = try facade.compareAndSwap(expectedRevision: 1,
                                      expectedDigest: existing.payloadDigest,
                                      candidate: advanced)
        let restarted = try facade.materializeLegacy(
            sourceDigest: source, absentDestination: preference(world: "w", byte: 7))
        XCTAssertEqual(restarted.preference, advanced)
        XCTAssertEqual(restarted.marker.destinationRevision, 1)
        XCTAssertThrowsError(try facade.compareAndSwap(
            expectedRevision: 1, expectedDigest: existing.payloadDigest,
            candidate: advanced))
        try coordinator.close()
    }

    func testLegacyMaterializationPrimitiveFailureRollbackAndRestartMatrix() throws {
        for operation: ElysiumStorageOperationID in [
            .beginImmediate, .prepare, .bind, .step, .changes, .finalize, .commit,
        ] {
            let url = databaseURL("migration-fault-\(operation.rawValue)")
            var coordinator: ElysiumStorageCoordinator? = try .open(databaseURL: url)
            try installWorld("w", core: coordinator!.legacyCore())
            let facade = try coordinator!.rpgLocalPreferences()
            try coordinator!._testInject(operation)
            XCTAssertThrowsError(try facade.materializeLegacy(
                sourceDigest: Data(repeating: 7, count: 32),
                absentDestination: preference(world: "w", byte: 8)), operation.rawValue)
            XCTAssertTrue(try coordinator!._testAutocommit(), operation.rawValue)
            XCTAssertNil(try facade.read(worldRecordID: "w"), operation.rawValue)
            try coordinator!.close(); coordinator = nil

            let reopened = try ElysiumStorageCoordinator.open(databaseURL: url)
            XCTAssertNil(try reopened.rpgLocalPreferences().read(worldRecordID: "w"),
                         operation.rawValue)
            let receipt = try reopened.rpgLocalPreferences().materializeLegacy(
                sourceDigest: Data(repeating: 7, count: 32),
                absentDestination: preference(world: "w", byte: 8))
            XCTAssertTrue(receipt.insertedDestination, operation.rawValue)
            try reopened.close()
        }
    }

    func testMigrationRestartIdempotenceAndEqualNamedWorldIDsNeverCross() throws {
        let url = databaseURL("cross-world-restart")
        var coordinator: ElysiumStorageCoordinator? = try .open(databaseURL: url)
        let core = try coordinator!.legacyCore()
        try core.putWorldRow(ElysiumWorldStorageRow(
            id: "world-a", json: #"{"name":"Same"}"#, lastPlayed: 0))
        try core.putWorldRow(ElysiumWorldStorageRow(
            id: "world-b", json: #"{"name":"Same"}"#, lastPlayed: 0))
        let facade = try coordinator!.rpgLocalPreferences()
        let sourceA = Data(repeating: 1, count: 32)
        let sourceB = Data(repeating: 2, count: 32)
        let a = try facade.materializeLegacy(
            sourceDigest: sourceA, absentDestination: preference(world: "world-a", byte: 3))
        let b = try facade.materializeLegacy(
            sourceDigest: sourceB, absentDestination: preference(world: "world-b", byte: 4))
        XCTAssertNotEqual(a.preference.payloadDigest, b.preference.payloadDigest)
        try coordinator!.close(); coordinator = nil

        let reopened = try ElysiumStorageCoordinator.open(databaseURL: url)
        let restarted = try reopened.rpgLocalPreferences()
        let repeatA = try restarted.materializeLegacy(
            sourceDigest: sourceA, absentDestination: preference(world: "world-a", byte: 9))
        let repeatB = try restarted.materializeLegacy(
            sourceDigest: sourceB, absentDestination: preference(world: "world-b", byte: 9))
        XCTAssertFalse(repeatA.insertedDestination)
        XCTAssertFalse(repeatB.insertedDestination)
        XCTAssertEqual(repeatA.preference, a.preference)
        XCTAssertEqual(repeatB.preference, b.preference)
        try reopened.close()
    }

    func testRevisionMaxMinusOneToMaxAndExhaustion() throws {
        let url = databaseURL("revision-max")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        try installWorld("w", core: coordinator.legacyCore())
        let facade = try coordinator.rpgLocalPreferences()
        let initial = try preference(world: "w", byte: 1)
        _ = try facade.materializeIfAbsent(candidate: initial)
        XCTAssertEqual(execute(url, "UPDATE rpg_local_preferences_v1 SET revision=999999999 WHERE world_record_id='w'"), SQLITE_OK)
        let maximum = try preference(world: "w", revision: 1_000_000_000, byte: 2)
        _ = try facade.compareAndSwap(expectedRevision: 999_999_999,
                                      expectedDigest: initial.payloadDigest,
                                      candidate: maximum)
        XCTAssertThrowsError(try facade.compareAndSwap(
            expectedRevision: 1_000_000_000, expectedDigest: maximum.payloadDigest,
            candidate: maximum))
        try coordinator.close()
    }

    func testWorldDeleteRemovesExactScopeAndPreservesEveryUnrelatedCoreTable() throws {
        let url = databaseURL("delete-preservation")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        try installWorld("target", core: core)
        try installWorld("other", core: core)
        _ = try coordinator.rpgLocalPreferences().materializeLegacy(
            sourceDigest: Data(repeating: 4, count: 32),
            absentDestination: preference(world: "target", byte: 5))
        XCTAssertEqual(execute(url, """
            INSERT INTO chunks VALUES('target',0,0,0,x'01');
            INSERT INTO chunks VALUES('other',0,0,0,x'02');
            INSERT INTO player VALUES('target','{}');
            INSERT INTO player VALUES('other','{}');
            INSERT INTO advancements VALUES('target','{}');
            INSERT INTO advancements VALUES('other','{}');
            INSERT INTO lan_player_resume VALUES('resume','{}',1);
            INSERT INTO lan_players VALUES('other','peer','{}',1);
            INSERT INTO templates(name,json) VALUES('template','{}');
            """), SQLITE_OK)
        XCTAssertEqual(try core.deleteWorld(id: "target"), 4)
        XCTAssertEqual(try core.deleteWorld(id: "target"), 0)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM worlds WHERE id='other'"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM chunks WHERE world='other'"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM player WHERE world='other'"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM advancements WHERE world='other'"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM lan_player_resume"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM lan_players"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM templates"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM rpg_local_preferences_v1"), 0)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM rpg_local_preference_migrations_v1"), 0)
        try coordinator.close()
    }

    func testWorldDeletePrimitiveFailureRollsBackEveryAffectedRow() throws {
        for operation: ElysiumStorageOperationID in [
            .beginImmediate, .prepare, .bind, .step, .changes, .finalize, .commit,
        ] {
            let url = databaseURL("delete-fault-\(operation.rawValue)")
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let core = try coordinator.legacyCore()
            try installWorld("target", core: core)
            _ = try coordinator.rpgLocalPreferences().materializeLegacy(
                sourceDigest: Data(repeating: 3, count: 32),
                absentDestination: preference(world: "target", byte: 4))
            XCTAssertEqual(execute(url, """
                INSERT INTO chunks VALUES('target',0,0,0,x'01');
                INSERT INTO player VALUES('target','{}');
                INSERT INTO advancements VALUES('target','{}');
                """), SQLITE_OK)
            try coordinator._testInject(operation)
            XCTAssertThrowsError(try core.deleteWorld(id: "target"), operation.rawValue)
            XCTAssertTrue(try coordinator._testAutocommit(), operation.rawValue)
            XCTAssertEqual(try scalar(url, "SELECT count(*) FROM worlds WHERE id='target'"), 1)
            XCTAssertEqual(try scalar(url, "SELECT count(*) FROM chunks WHERE world='target'"), 1)
            XCTAssertEqual(try scalar(url, "SELECT count(*) FROM player WHERE world='target'"), 1)
            XCTAssertEqual(try scalar(url, "SELECT count(*) FROM advancements WHERE world='target'"), 1)
            XCTAssertEqual(try scalar(url, "SELECT count(*) FROM rpg_local_preferences_v1"), 1)
            XCTAssertEqual(try scalar(url, "SELECT count(*) FROM rpg_local_preference_migrations_v1"), 1)
            try coordinator.close()
        }
    }
}
