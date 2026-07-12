import XCTest
import Foundation
import SQLite3
import CryptoKit
@testable import PebbleStorage

final class RPGStorageSurfaceTests: XCTestCase {
    private func databaseURL(_ label: String = UUID().uuidString) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PebbleRPGStorage-\(label)-\(UUID().uuidString).sqlite")
    }

    private func payload(_ byte: UInt8 = 0) -> Data {
        Data(repeating: byte, count: 18)
    }

    private func digest(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }

    private func row(world: String, revision: UInt64 = 1, byte: UInt8 = 1,
                     originDigest: Data? = nil,
                     originRevision: UInt64? = nil) throws
        -> PebbleRPGLocalPreferenceStorageRow {
        try PebbleRPGLocalPreferenceStorageRow(
            worldRecordID: world, schemaVersion: 1, revision: revision,
            slotsPayload: payload(byte), payloadDigest: digest(byte),
            migrationOriginDigest: originDigest, migrationOriginRevision: originRevision)
    }

    func testLocalComponentMaterializeCASAndReopen() throws {
        let url = databaseURL("cas")
        var coordinator: PebbleStorageCoordinator? = try .open(databaseURL: url)
        let core = try coordinator!.legacyCore()
        try core.putWorldRow(PebbleWorldStorageRow(id: "world-a", json: "{}", lastPlayed: 0))
        let storage = try coordinator!.rpgLocalPreferences()
        let initial = try row(world: "world-a")
        XCTAssertEqual(try storage.materializeIfAbsent(candidate: initial), initial)
        XCTAssertEqual(try storage.materializeIfAbsent(
            candidate: row(world: "world-a", byte: 2)), initial)

        let updated = try row(world: "world-a", revision: 2, byte: 3)
        XCTAssertEqual(try storage.compareAndSwap(
            expectedRevision: 1, expectedDigest: initial.payloadDigest,
            candidate: updated), updated)
        XCTAssertThrowsError(try storage.compareAndSwap(
            expectedRevision: 1, expectedDigest: initial.payloadDigest,
            candidate: updated))
        try coordinator!.close()
        coordinator = nil

        let reopened = try PebbleStorageCoordinator.open(databaseURL: url)
        XCTAssertEqual(try reopened.rpgLocalPreferences().read(worldRecordID: "world-a"), updated)
        try reopened.close()
    }

    func testLegacyMaterializationIsIdempotentAndBindsOrigin() throws {
        let url = databaseURL("legacy")
        let coordinator = try PebbleStorageCoordinator.open(databaseURL: url)
        try coordinator.legacyCore().putWorldRow(
            PebbleWorldStorageRow(id: "world-b", json: "{}", lastPlayed: 0))
        let storage = try coordinator.rpgLocalPreferences()
        let source = digest(9)
        let receipt = try storage.materializeLegacy(
            sourceDigest: source, absentDestination: row(world: "world-b", byte: 4))
        XCTAssertTrue(receipt.insertedDestination)
        XCTAssertEqual(receipt.preference.migrationOriginDigest,
                       receipt.marker.destinationDigest)
        XCTAssertEqual(receipt.preference.migrationOriginRevision,
                       receipt.marker.destinationRevision)

        let repeated = try storage.materializeLegacy(
            sourceDigest: source, absentDestination: row(world: "world-b", byte: 7))
        XCTAssertFalse(repeated.insertedDestination)
        XCTAssertEqual(repeated.preference, receipt.preference)
        XCTAssertEqual(repeated.marker, receipt.marker)
        try coordinator.close()
    }

    func testWorldDeleteRemovesRPGRowsWithoutChangingLegacyCount() throws {
        let url = databaseURL("delete")
        let coordinator = try PebbleStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        try core.putWorldRow(PebbleWorldStorageRow(id: "world-c", json: "{}", lastPlayed: 0))
        _ = try coordinator.rpgLocalPreferences().materializeLegacy(
            sourceDigest: digest(8), absentDestination: row(world: "world-c", byte: 5))
        XCTAssertEqual(try core.deleteWorld(id: "world-c"), 1)
        XCTAssertNil(try coordinator.rpgLocalPreferences().read(worldRecordID: "world-c"))
        XCTAssertEqual(try core.deleteWorld(id: "world-c"), 0)
        try coordinator.close()
    }

    func testClientCheckpointSchemaIsDormantAndReopensExactly() throws {
        let url = databaseURL("client")
        let hid = Data(repeating: 1, count: 16)
        let wid = Data(repeating: 2, count: 16)
        var lookupInput = Data("Pebble-LAN-v6".utf8)
        lookupInput.append(hid); lookupInput.append(wid)
        let key = try PebbleLANClientAuthorityStorageKey(
            hostInstallationID: hid, worldLANID: wid,
            lookupDigest: Data(SHA256.hash(data: lookupInput)))

        var coordinator: PebbleStorageCoordinator? = try .open(databaseURL: url)
        XCTAssertThrowsError(try coordinator!.clientAuthorityCheckpointV6())
        try coordinator!._testBootstrapClientAuthoritySchemaForAdmission()
        let facade = try coordinator!.clientAuthorityCheckpointV6()
        XCTAssertThrowsError(try facade.load(key: key)) { error in
            XCTAssertEqual(error as? PebbleStorageError, .invalidValue)
        }
        try coordinator!.close(); coordinator = nil

        let reopened = try PebbleStorageCoordinator.open(databaseURL: url)
        XCTAssertThrowsError(try reopened.clientAuthorityCheckpointV6().load(key: key))
        try reopened.close()
    }

    func testComponentMarkerTamperFailsClosedAtReopen() throws {
        let url = databaseURL("marker-tamper")
        let coordinator = try PebbleStorageCoordinator.open(databaseURL: url)
        _ = try coordinator.rpgLocalPreferences()
        try coordinator.close()

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(sqlite3_exec(database, """
            UPDATE pebble_storage_component_schema_v1
            SET manifest_digest=zeroblob(32) WHERE component='rpgLocalPreferences'
            """, nil, nil, nil), SQLITE_OK)
        if let database { XCTAssertEqual(sqlite3_close(database), SQLITE_OK) }
        database = nil
        XCTAssertThrowsError(try PebbleStorageCoordinator.open(databaseURL: url))
    }
}
