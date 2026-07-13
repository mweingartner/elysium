import XCTest
import Foundation
import SQLite3
import CryptoKit
@testable import ElysiumStorage

final class LANV6HostOwnerCheckpointStorageTests: XCTestCase {
    private func url(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ElysiumHostOwnerRows-\(label)-\(UUID().uuidString).sqlite")
    }

    private func scalar(_ url: URL, _ sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw ElysiumStorageError.invalidValue }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ElysiumStorageError.invalidValue }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ElysiumStorageError.invalidValue }
        return sqlite3_column_int64(statement, 0)
    }

    func testHostOwnerRowsRemainAbsentAcrossLocalAndClientBootstrap() throws {
        let databaseURL = url("absent")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL)
        _ = try coordinator.rpgLocalPreferences()
        try coordinator._testBootstrapClientAuthoritySchemaForAdmission()
        XCTAssertEqual(try scalar(databaseURL, """
            SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN (
              'lan_peer_authority_checkpoint_v6',
              'lan_host_local_authority_checkpoint_v6')
            """), 0)
        try coordinator.close()
    }

    func testUnreviewedHostOwnerObjectFailsClosedAtReopen() throws {
        let databaseURL = url("unreviewed")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL)
        try coordinator.close()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database,
                                       SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE lan_peer_authority_checkpoint_v6(
              hid BLOB NOT NULL,wid BLOB NOT NULL,authority TEXT NOT NULL,
              checkpoint_generation BLOB NOT NULL,payload BLOB NOT NULL,
              payload_digest BLOB NOT NULL,world_checkpoint_digest BLOB NOT NULL,
              PRIMARY KEY(hid,wid,authority)) WITHOUT ROWID
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK); database = nil
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: databaseURL))
    }

    func testDormantHostDDLManifestForeignKeysCapsAndNoWriterSourceContract() throws {
        let testURL = URL(fileURLWithPath: #filePath)
        let root = testURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = root.appendingPathComponent("Sources/ElysiumStorage/StorageEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let start = try XCTUnwrap(source.range(
            of: "static let dormantHostOwnerCreateStatements: [StaticString] = ["))
        let end = try XCTUnwrap(source.range(
            of: "static let dormantHostOwnerManifestDigest", range: start.upperBound..<source.endIndex))
        let block = String(source[start.upperBound..<end.lowerBound])
        let expression = try NSRegularExpression(pattern: #"\"\"\"\n([\s\S]*?)\n        \"\"\""#)
        let matches = expression.matches(in: block, range: NSRange(block.startIndex..., in: block))
        let statements = try matches.map { match -> String in
            let range = try XCTUnwrap(Range(match.range(at: 1), in: block))
            return String(block[range]).split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
        XCTAssertEqual(statements.count, 2)
        let peer = statements[0]
        let host = statements[1]
        XCTAssertTrue(peer.contains("CREATE TABLE lan_peer_authority_checkpoint_v6("))
        XCTAssertTrue(peer.contains("PRIMARY KEY(hid,wid,authority)"))
        XCTAssertTrue(peer.contains("REFERENCES lan_peer_identity_v6(hid,wid,authority)"))
        XCTAssertTrue(peer.contains("ON UPDATE RESTRICT ON DELETE RESTRICT"))
        XCTAssertTrue(peer.contains("length(CAST(authority AS BLOB)) BETWEEN 5 AND 24"))
        XCTAssertTrue(host.contains("CREATE TABLE lan_host_local_authority_checkpoint_v6("))
        XCTAssertTrue(host.contains("authority='host:local'"))
        XCTAssertTrue(host.contains("PRIMARY KEY(hid,wid)"))
        XCTAssertTrue(host.contains("REFERENCES lan_world_identity_registry_v1(hid,wid)"))
        for statement in statements {
            XCTAssertTrue(statement.contains("length(checkpoint_generation)=8"))
            XCTAssertTrue(statement.contains("length(payload) BETWEEN 1 AND 786432"))
            XCTAssertEqual(statement.components(separatedBy: "length(payload_digest)=32").count, 2)
            XCTAssertEqual(statement.components(
                separatedBy: "length(world_checkpoint_digest)=32").count, 2)
            XCTAssertTrue(statement.hasSuffix(") WITHOUT ROWID"))
        }

        var manifest = Data("Pebble/storage-schema/v1\0".utf8)
        func append32(_ value: Int) {
            let narrowed = UInt32(value)
            manifest.append(UInt8(truncatingIfNeeded: narrowed >> 24))
            manifest.append(UInt8(truncatingIfNeeded: narrowed >> 16))
            manifest.append(UInt8(truncatingIfNeeded: narrowed >> 8))
            manifest.append(UInt8(truncatingIfNeeded: narrowed))
        }
        let component = Data("lanHostOwnerRows".utf8)
        append32(component.count); manifest.append(component); append32(statements.count)
        for statement in statements {
            let bytes = Data(statement.utf8); append32(bytes.count); manifest.append(bytes)
        }
        XCTAssertEqual(Data(SHA256.hash(data: manifest)).map { String(format: "%02x", $0) }
            .joined(), "d62854adb206bd91fc65a1d18a0bcf8cfdf3d6fa36a2348f33931fef77a6f560")

        XCTAssertFalse(source.contains("public func hostOwnerCheckpoint"))
        XCTAssertFalse(source.contains("public final class ElysiumHostOwner"))
        XCTAssertFalse(source.contains("func bootstrapHostOwner"))
        XCTAssertTrue(source.contains("There is deliberately no bootstrap accessor or runtime scope"))
    }

    func testDormantHostTablesRemainOutsideKnownRuntimeSchemaAndCannotBeInstalledPartially() throws {
        let databaseURL = url("full-dormant-reject")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL)
        _ = try coordinator.rpgLocalPreferences()
        try coordinator.close()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database,
                                       SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(sqlite3_exec(database, """
            CREATE TABLE lan_peer_authority_checkpoint_v6(
              hid BLOB NOT NULL,wid BLOB NOT NULL,authority TEXT NOT NULL,
              checkpoint_generation BLOB NOT NULL,payload BLOB NOT NULL,
              payload_digest BLOB NOT NULL,world_checkpoint_digest BLOB NOT NULL,
              PRIMARY KEY(hid,wid,authority)) WITHOUT ROWID;
            CREATE TABLE lan_host_local_authority_checkpoint_v6(
              hid BLOB NOT NULL,wid BLOB NOT NULL,authority TEXT NOT NULL,
              checkpoint_generation BLOB NOT NULL,payload BLOB NOT NULL,
              payload_digest BLOB NOT NULL,world_checkpoint_digest BLOB NOT NULL,
              PRIMARY KEY(hid,wid)) WITHOUT ROWID;
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(database), SQLITE_OK); database = nil
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: databaseURL))
    }
}
