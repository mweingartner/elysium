import XCTest
import Foundation
import Darwin
import SQLite3
@testable import ElysiumStorage

final class LANV6SchemaAuthorizerTests: XCTestCase {
    private func databaseURL(_ label: String = "db") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LANV6SchemaAuthorizerTests-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("elysium.db")
    }

    @discardableResult
    private func runSQLite(_ databaseURL: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-noheader", databaseURL.path, sql]
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ElysiumStorageError.sqlite(primaryCode: process.terminationStatus,
                                            extendedCode: process.terminationStatus,
                                            operation: .open)
        }
        return String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func templateFixtureSQL(prefixCount: Int) -> String {
        let migrations = [
            "ALTER TABLE templates ADD COLUMN format INTEGER NOT NULL DEFAULT 1",
            "ALTER TABLE templates ADD COLUMN data BLOB",
            "ALTER TABLE templates ADD COLUMN sizeX INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE templates ADD COLUMN sizeY INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE templates ADD COLUMN sizeZ INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE templates ADD COLUMN blockCount INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE templates ADD COLUMN blockEntityCount INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE templates ADD COLUMN dominantBlock TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE templates ADD COLUMN dominantDisplay TEXT NOT NULL DEFAULT ''",
        ]
        return (["""
            CREATE TABLE templates(
                name TEXT PRIMARY KEY,json TEXT NOT NULL,created REAL NOT NULL DEFAULT 0)
            """] + migrations.prefix(prefixCount)).joined(separator: ";")
    }

    private func schemaSnapshot(_ databaseURL: URL) throws -> String {
        try runSQLite(databaseURL, """
            SELECT type||'|'||name||'|'||tbl_name||'|'||coalesce(hex(CAST(sql AS BLOB)),'NULL')
            FROM sqlite_master ORDER BY type,name;
            SELECT 'templates|'||cid||'|'||name||'|'||type||'|'||"notnull"||'|'
                   ||coalesce(dflt_value,'NULL')||'|'||pk
            FROM pragma_table_info('templates') ORDER BY cid;
            SELECT 'worlds|'||cid||'|'||name||'|'||type||'|'||"notnull"||'|'
                   ||coalesce(dflt_value,'NULL')||'|'||pk
            FROM pragma_table_info('worlds') ORDER BY cid;
            SELECT 'chunks|'||cid||'|'||name||'|'||type||'|'||"notnull"||'|'
                   ||coalesce(dflt_value,'NULL')||'|'||pk
            FROM pragma_table_info('chunks') ORDER BY cid;
            """)
    }

    private func fileIdentity(_ url: URL) -> (device: dev_t, inode: ino_t)? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return (info.st_dev, info.st_ino)
    }

    private func descriptorCount(device: dev_t, inode: ino_t) -> Int {
        var count = 0
        for descriptor in 0..<min(Int(getdtablesize()), 8_192) {
            var info = stat()
            if fstat(Int32(descriptor), &info) == 0,
               info.st_dev == device, info.st_ino == inode {
                count += 1
            }
        }
        return count
    }

    private func createCanonicalDatabase(_ url: URL) throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        try coordinator.close()
    }

    private func primaryStorageError(_ error: any Error) -> ElysiumStorageError? {
        if let error = error as? ElysiumStorageError { return error }
        if let error = error as? ElysiumStorageTransactionFailure {
            return primaryStorageError(error.primary)
        }
        if let error = error as? ElysiumStorageStatementFailure {
            return primaryStorageError(error.primary)
        }
        return nil
    }

    func testRuntimeScopesDenyWriteWideningCrossTableAndBootstrapReuse() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        defer { try? coordinator.close() }
        XCTAssertThrowsError(try coordinator._testReadScopeWriteProbe()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .capabilityViolation)
        }
        XCTAssertThrowsError(try coordinator._testCrossTableMutationProbe()) { error in
            guard let failure = error as? ElysiumStorageTransactionFailure else {
                return XCTFail("expected transaction failure")
            }
            XCTAssertEqual(failure.primary as? ElysiumStorageError, .capabilityViolation)
        }
        XCTAssertThrowsError(try coordinator._testBootstrapAfterReadinessProbe()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .capabilityViolation)
        }
        XCTAssertTrue(try coordinator._testAutocommit())
    }

    func testCanonicalDotDotSymlinkAndHardLinkAliasesCannotDoubleOpen() throws {
        let url = try databaseURL()
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        defer { try? coordinator.close() }
        XCTAssertTrue(try coordinator._testPhysicalIdentityBound())

        let dotDot = url.deletingLastPathComponent()
            .appendingPathComponent("child/../elysium.db")
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: dotDot)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .duplicateOpen)
        }

        let hardLink = url.deletingLastPathComponent().appendingPathComponent("hard.db")
        try FileManager.default.linkItem(at: url, to: hardLink)
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: hardLink)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .duplicateOpen)
        }

        let symlink = url.deletingLastPathComponent().appendingPathComponent("link.db")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: url)
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: symlink))
    }

    func testConcurrentHardLinkAliasOpenHasExactlyOneWinner() throws {
        let firstURL = try databaseURL()
        XCTAssertTrue(FileManager.default.createFile(atPath: firstURL.path, contents: Data()))
        let secondURL = firstURL.deletingLastPathComponent().appendingPathComponent("alias.db")
        try FileManager.default.linkItem(at: firstURL, to: secondURL)

        let group = DispatchGroup()
        let attempted = DispatchSemaphore(value: 0)
        let releaseWinner = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var successes = 0
        var duplicateFailures = 0
        for url in [firstURL, secondURL] {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
                    lock.lock(); successes += 1; lock.unlock()
                    attempted.signal()
                    _ = releaseWinner.wait(timeout: .now() + 10)
                    try coordinator.close()
                } catch ElysiumStorageError.duplicateOpen {
                    lock.lock(); duplicateFailures += 1; lock.unlock()
                    attempted.signal()
                } catch {
                    attempted.signal()
                }
            }
        }
        XCTAssertEqual(attempted.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(attempted.wait(timeout: .now() + 10), .success)
        releaseWinner.signal()
        releaseWinner.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(duplicateFailures, 1)
    }

    func testHostileTriggerViewAndUnmanifestedIndexAreRejected() throws {
        let fixtures: [(String, String)] = [
            ("trigger", """
                CREATE TABLE worlds(id TEXT PRIMARY KEY,json TEXT NOT NULL,lastPlayed REAL NOT NULL DEFAULT 0);
                CREATE TRIGGER hostile AFTER INSERT ON worlds BEGIN DELETE FROM worlds; END;
                """),
            ("view", """
                CREATE TABLE worlds(id TEXT PRIMARY KEY,json TEXT NOT NULL,lastPlayed REAL NOT NULL DEFAULT 0);
                CREATE VIEW hostile AS SELECT id FROM worlds;
                """),
            ("index", """
                CREATE TABLE worlds(id TEXT PRIMARY KEY,json TEXT NOT NULL,lastPlayed REAL NOT NULL DEFAULT 0);
                CREATE INDEX hostile ON worlds(lastPlayed);
                """),
        ]
        for (label, sql) in fixtures {
            let url = try databaseURL(label)
            try runSQLite(url, sql)
            XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url), label) { error in
                XCTAssertEqual(error as? ElysiumStorageError, .schemaMismatch)
            }
        }
    }

    func testFailedFactoryReleasesPathAndInodeReservation() throws {
        let url = try databaseURL()
        try runSQLite(url, "CREATE TABLE hostile(value TEXT)")
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url))
        try FileManager.default.removeItem(at: url)
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        XCTAssertTrue(try coordinator._testPhysicalIdentityBound())
        try coordinator.close()
    }

    func testSameColumnsWithMaliciousConstraintAndWrongWithoutRowIDAreRejected() throws {
        let constrainedURL = try databaseURL("constraint")
        try runSQLite(constrainedURL, """
            CREATE TABLE worlds(id TEXT PRIMARY KEY,json TEXT NOT NULL CHECK(length(json)<10),
                                lastPlayed REAL NOT NULL DEFAULT 0);
            """)
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: constrainedURL)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .schemaMismatch)
        }

        let rowIDURL = try databaseURL("rowid")
        try runSQLite(rowIDURL, """
            CREATE TABLE chunks(world TEXT NOT NULL,dim INTEGER NOT NULL,cx INTEGER NOT NULL,
                                cz INTEGER NOT NULL,data BLOB NOT NULL,
                                PRIMARY KEY(world,dim,cx,cz));
            """)
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: rowIDURL)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .schemaMismatch)
        }
    }

    func testLegacyTemplateSchemaUpgradesToExactManifest() throws {
        let url = try databaseURL()
        try runSQLite(url, """
            CREATE TABLE templates(name TEXT PRIMARY KEY,json TEXT NOT NULL,created REAL NOT NULL DEFAULT 0);
            """)
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        defer { try? coordinator.close() }
        try coordinator.legacyCore().verifyCoreSchema()
        let summary = try ElysiumTemplateSummaryStorageRow(
            name: "legacy", sizeX: 0, sizeY: 0, sizeZ: 0, blockCount: 0,
            blockEntityCount: 0, dominantBlock: "", dominantDisplay: "")
        let row = try ElysiumTemplateStorageRow(summary: summary, json: "{}", created: 0,
                                               format: 1, data: nil)
        XCTAssertEqual(try coordinator.legacyCore().putTemplateRow(row), 1)
    }

    func testWrongStorageClassAndOversizedTextRejectBeforeMaterialization() throws {
        let wrongTypeURL = try databaseURL("type")
        var coordinator = try ElysiumStorageCoordinator.open(databaseURL: wrongTypeURL)
        try coordinator.close()
        try runSQLite(wrongTypeURL, "INSERT INTO worlds(id,json,lastPlayed) VALUES('w',X'00',0.0)")
        coordinator = try ElysiumStorageCoordinator.open(databaseURL: wrongTypeURL)
        XCTAssertThrowsError(try coordinator.legacyCore().getWorldRow(id: "w")) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .invalidStorageClass)
        }
        try coordinator.close()

        let oversizedURL = try databaseURL("oversized")
        coordinator = try ElysiumStorageCoordinator.open(databaseURL: oversizedURL)
        try coordinator.close()
        try runSQLite(oversizedURL, """
            INSERT INTO worlds(id,json,lastPlayed)
            VALUES('w',printf('%.*c',1048577,'x'),0.0)
            """)
        coordinator = try ElysiumStorageCoordinator.open(databaseURL: oversizedURL)
        XCTAssertThrowsError(try coordinator.legacyCore().getWorldRow(id: "w")) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded)
        }
        try coordinator.close()
    }

    func testWriteBoundsAtCapAndOneOver() throws {
        let atCap = String(repeating: "x", count: 786_432)
        XCTAssertNoThrow(try ElysiumPlayerJSONStorageRow(world: "w", json: atCap))
        let oneOver = atCap + "x"
        XCTAssertThrowsError(try ElysiumPlayerJSONStorageRow(world: "w", json: oneOver)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded)
        }
        XCTAssertThrowsError(try ElysiumWorldStorageRow(id: "", json: "{}", lastPlayed: 0)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .invalidValue)
        }
        XCTAssertThrowsError(try ElysiumWorldStorageRow(id: "w", json: "{}", lastPlayed: .nan)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .invalidValue)
        }
    }

    func testCollectionRowCapRejectsBeforePaginationAccumulation() throws {
        let url = try databaseURL("row-cap")
        var coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        try coordinator.close()
        try runSQLite(url, """
            WITH RECURSIVE values_cte(i) AS (
                SELECT 1 UNION ALL SELECT i+1 FROM values_cte WHERE i<4097
            )
            INSERT INTO worlds(id,json,lastPlayed)
            SELECT printf('w-%05d',i),'{}',i*1.0 FROM values_cte;
            """)
        coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        XCTAssertThrowsError(try coordinator.legacyCore().listWorldRows()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded)
        }
        try coordinator.close()
    }

    func testErrorsAndCompositeErrorsAreRedacted() throws {
        let sentinel = "SECRET-PATH-PAYLOAD-ID"
        let primary = NSError(domain: sentinel, code: 1,
                              userInfo: [NSLocalizedDescriptionKey: sentinel])
        let transaction = ElysiumStorageTransactionFailure(primary: primary,
                                                          rollback: .capabilityViolation,
                                                          terminal: nil)
        let statement = ElysiumStorageStatementFailure(primary: primary, finalize: .statementLeak)
        XCTAssertFalse(String(describing: transaction).contains(sentinel))
        XCTAssertFalse(String(describing: statement).contains(sentinel))
        XCTAssertFalse(String(describing: ElysiumStorageError.invalidValue).contains(sentinel))
    }

    func testDeterministicPostOpenFailureClosesLocalHandleAndAllowsSafeReopen() throws {
        let url = try databaseURL("deterministic-post-open")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
        guard let identity = fileIdentity(url) else { return XCTFail("fixture identity missing") }
        let before = descriptorCount(device: identity.device, inode: identity.inode)

        XCTAssertThrowsError(try ElysiumStorageCoordinator._testOpen(
            databaseURL: url, failurePoint: .afterSQLiteOpen))
        XCTAssertEqual(descriptorCount(device: identity.device, inode: identity.inode), before)

        let reopened = try ElysiumStorageCoordinator.open(databaseURL: url)
        XCTAssertTrue(try reopened._testPhysicalIdentityBound())
        try reopened.close()
        XCTAssertEqual(descriptorCount(device: identity.device, inode: identity.inode), before)
    }

    func testFilesystemFailureIsClosedAndDoesNotRevealSentinelPath() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElysiumStorage-SECRET-PATH-PAYLOAD-ID-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let regularParent = root.appendingPathComponent("not-a-directory")
        XCTAssertTrue(FileManager.default.createFile(atPath: regularParent.path, contents: Data()))
        let url = regularParent.appendingPathComponent("elysium.db")

        let capturedPipe = Pipe()
        let savedStandardError = dup(STDERR_FILENO)
        XCTAssertGreaterThanOrEqual(savedStandardError, 0)
        XCTAssertEqual(dup2(capturedPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO),
                       STDERR_FILENO)
        var observed: (any Error)?
        do { _ = try ElysiumStorageCoordinator.open(databaseURL: url) }
        catch { observed = error }
        fflush(nil)
        XCTAssertEqual(dup2(savedStandardError, STDERR_FILENO), STDERR_FILENO)
        Darwin.close(savedStandardError)
        capturedPipe.fileHandleForWriting.closeFile()
        let capturedOutput = String(
            decoding: capturedPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)

        guard let observed else { return XCTFail("missing closed error") }
        XCTAssertEqual(observed as? ElysiumStorageError,
                       .openFailed(primaryCode: EIO, extendedCode: EIO))
        let rendered = [String(describing: observed), String(reflecting: observed),
                        String(describing: Mirror(reflecting: observed).children.map(\.label)),
                        capturedOutput]
            .joined(separator: "|")
        XCTAssertFalse(rendered.contains("SECRET-PATH-PAYLOAD-ID"))
        XCTAssertFalse(rendered.contains(regularParent.path))
    }

    func testUTF16DatabaseIsRejectedWithoutConversionOrSchemaMutation() throws {
        let url = try databaseURL("utf16")
        try runSQLite(url, """
            PRAGMA encoding='UTF-16';
            CREATE TABLE worlds(id TEXT PRIMARY KEY,json TEXT NOT NULL,
                                lastPlayed REAL NOT NULL DEFAULT 0);
            """)
        let before = try schemaSnapshot(url)
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url))
        XCTAssertEqual(try schemaSnapshot(url), before)
        XCTAssertTrue(try runSQLite(url, "PRAGMA encoding").hasPrefix("UTF-16"))
    }

    func testAllTenCanonicalTemplatePrefixesUpgradeToExactReadySchema() throws {
        for prefix in 0...9 {
            let url = try databaseURL("template-prefix-\(prefix)")
            try runSQLite(url, templateFixtureSQL(prefixCount: prefix))
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            try coordinator.legacyCore().verifyCoreSchema()
            try coordinator.close()
            let columns = try runSQLite(url, """
                SELECT group_concat(name,'|') FROM pragma_table_info('templates')
                """)
            XCTAssertEqual(columns,
                           "name|json|created|format|data|sizeX|sizeY|sizeZ|blockCount|"
                           + "blockEntityCount|dominantBlock|dominantDisplay", "prefix=\(prefix)")
        }
    }

    func testRejectedSchemaShapesRemainByteIdentical() throws {
        let fixtures: [(String, String)] = [
            ("extra-column", """
                CREATE TABLE worlds(id TEXT PRIMARY KEY,json TEXT NOT NULL,
                    lastPlayed REAL NOT NULL DEFAULT 0, extra TEXT)
                """),
            ("missing-column", "CREATE TABLE worlds(id TEXT PRIMARY KEY,json TEXT NOT NULL)"),
            ("reordered-column", """
                CREATE TABLE worlds(json TEXT NOT NULL,id TEXT PRIMARY KEY,
                    lastPlayed REAL NOT NULL DEFAULT 0)
                """),
            ("wrong-primary-key", """
                CREATE TABLE worlds(id TEXT NOT NULL,json TEXT PRIMARY KEY,
                    lastPlayed REAL NOT NULL DEFAULT 0)
                """),
            ("wrong-rowid", """
                CREATE TABLE chunks(world TEXT NOT NULL,dim INTEGER NOT NULL,cx INTEGER NOT NULL,
                    cz INTEGER NOT NULL,data BLOB NOT NULL,PRIMARY KEY(world,dim,cx,cz))
                """),
            ("out-of-prefix-template", """
                CREATE TABLE templates(name TEXT PRIMARY KEY,json TEXT NOT NULL,
                    created REAL NOT NULL DEFAULT 0,data BLOB)
                """),
        ]
        for (label, sql) in fixtures {
            let url = try databaseURL(label)
            try runSQLite(url, sql)
            let before = try schemaSnapshot(url)
            XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url), label) { error in
                XCTAssertEqual(error as? ElysiumStorageError, .schemaMismatch)
            }
            XCTAssertEqual(try schemaSnapshot(url), before, label)
        }
    }

    func testEveryBootstrapDDLFailureRollsBackToExactPriorSnapshot() throws {
        for statementIndex in 0...15 {
            let url = try databaseURL("ddl-cut-\(statementIndex)")
            if statementIndex >= 7 {
                try runSQLite(url, templateFixtureSQL(prefixCount: statementIndex - 7))
            } else {
                _ = try runSQLite(url, "PRAGMA encoding")
            }
            let before = try schemaSnapshot(url)
            XCTAssertThrowsError(try ElysiumStorageCoordinator._testOpen(
                databaseURL: url,
                failurePoint: .beforeBootstrapStatement(statementIndex)),
                "statement=\(statementIndex)")
            XCTAssertEqual(try schemaSnapshot(url), before, "statement=\(statementIndex)")

            let restarted = try ElysiumStorageCoordinator.open(databaseURL: url)
            try restarted.legacyCore().verifyCoreSchema()
            try restarted.close()
        }
    }

    func testLegacyCollectionScopesAllowFrozenReadsAndDenyAdjacentColumns() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("legacy-scopes"))
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()
        try storage.putWorldRow(ElysiumWorldStorageRow(id: "w", json: "{}", lastPlayed: 0))
        XCTAssertEqual(try storage.listLegacyWorldJSON(), ["{}"])
        XCTAssertEqual(try storage.listLegacyTemplateNames(), [])
        XCTAssertEqual(try storage.listLegacyTemplateSummaryCandidates(), [])
        XCTAssertEqual(try storage.listLegacyLANPlayerJSON(world: "w"), [])

        for probe in [coordinator._testLegacyWorldScopeDeniedProbe,
                      coordinator._testLegacyTemplateScopeDeniedProbe,
                      coordinator._testLegacyLANScopeDeniedProbe] {
            XCTAssertThrowsError(try probe()) { error in
                XCTAssertEqual(error as? ElysiumStorageError, .capabilityViolation)
            }
        }
        XCTAssertTrue(try coordinator._testAutocommit())
    }

    func testLegacySingleReadsIgnoreEveryUnselectedCorruptColumn() throws {
        let url = try databaseURL("legacy-projections")
        var coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        var storage = try coordinator.legacyCore()
        try storage.putWorldRow(ElysiumWorldStorageRow(id: "w", json: "world-json", lastPlayed: 1))
        try storage.putPlayerJSON(ElysiumPlayerJSONStorageRow(world: "w", json: "player-json"))
        try storage.putLANClientResumeJSON(ElysiumLANClientResumeStorageRow(
            hostWorld: "host", json: "resume-json", updated: 2))
        try storage.putLANPlayerJSON(ElysiumLANPlayerStorageRow(
            world: "w", playerID: "p", json: "peer-json", updated: 3))
        try storage.putAdvancementJSON(ElysiumAdvancementStorageRow(world: "w", json: "adv-json"))
        let summary = try ElysiumTemplateSummaryStorageRow(
            name: "template", sizeX: 1, sizeY: 2, sizeZ: 3,
            blockCount: 4, blockEntityCount: 5,
            dominantBlock: "stone", dominantDisplay: "Stone")
        _ = try storage.putTemplateRow(ElysiumTemplateStorageRow(
            summary: summary, json: "template-json", created: 4, format: 2,
            data: Data([1, 2])))
        try coordinator.close()

        try runSQLite(url, """
            UPDATE worlds SET lastPlayed=X'00' WHERE id='w';
            UPDATE lan_player_resume SET updated=X'00' WHERE hostWorld='host';
            UPDATE lan_players SET updated=X'00' WHERE world='w' AND playerID='p';
            UPDATE templates SET created=X'00',sizeX=X'00',sizeY=X'00',sizeZ=X'00',
                blockCount=X'00',blockEntityCount=X'00',dominantBlock=X'00',
                dominantDisplay=X'00' WHERE name='template';
            """)
        coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        storage = try coordinator.legacyCore()
        XCTAssertEqual(try storage.getLegacyWorldJSON(id: "w"), "world-json")
        XCTAssertEqual(try storage.getLegacyPlayerJSON(world: "w"), "player-json")
        XCTAssertEqual(try storage.getLegacyLANClientResumeJSON(hostWorld: "host"), "resume-json")
        XCTAssertEqual(try storage.getLegacyLANPlayerJSON(world: "w", playerID: "p"), "peer-json")
        XCTAssertEqual(try storage.getLegacyAdvancementJSON(world: "w"), "adv-json")
        XCTAssertEqual(try storage.getLegacyTemplateContent(name: "template"),
                       ElysiumLegacyTemplateContent(format: 2, data: Data([1, 2]),
                                                   json: "template-json"))
        XCTAssertThrowsError(try storage.getWorldRow(id: "w"))
        XCTAssertThrowsError(try storage.getLANClientResumeJSON(hostWorld: "host"))
        XCTAssertThrowsError(try storage.getLANPlayerJSON(world: "w", playerID: "p"))
        XCTAssertThrowsError(try storage.getTemplateRow(name: "template"))
        try coordinator.close()
    }

    func testLegacyTextMatrixRowLocalSkipRepairTruncateAndOptionalFallback() throws {
        let url = try databaseURL("legacy-text-matrix")
        var coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        try coordinator.close()
        try runSQLite(url, """
            INSERT INTO worlds(id,json,lastPlayed) VALUES('a','alpha',0.0);
            INSERT INTO worlds(id,json,lastPlayed) VALUES('b',X'626c6f62',0.0);
            INSERT INTO worlds(id,json,lastPlayed)
                VALUES('c',CAST(X'66ff6f0068696464656e' AS TEXT),0.0);
            INSERT INTO worlds(id,json,lastPlayed)
                VALUES('d',printf('%.*c',1048577,'x'),0.0);

            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES('a','{}',0.0,1,NULL,1,2,3,4,5,'stone','Stone');
            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES('b','{}',0.0,1,NULL,'bad',2,3,4,5,X'00',
                       CAST(X'44ff0068696464656e' AS TEXT));
            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES(X'626c6f62','{}',0.0,1,NULL,1,1,1,1,1,'x','x');
            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES(NULL,'{}',0.0,1,NULL,1,1,1,1,1,'x','x');
            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES(printf('%.*c',1048577,'n'),'{}',0.0,1,NULL,1,1,1,1,1,'x','x');
            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES(CAST(X'7aff0071' AS TEXT),'{}',0.0,1,X'',1,1,1,1,1,
                       printf('%.*c',1048577,'x'),'ok');
            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES('content',X'00',0.0,'bad','not-a-blob',1,1,1,1,1,'x','x');
            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES('legacy','legacy-json',0.0,1,NULL,1,1,1,1,1,'x','x');
            """)
        coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()
        XCTAssertEqual(try storage.listLegacyWorldJSON(), ["alpha", "f\u{FFFD}o"])
        XCTAssertNil(try storage.getLegacyWorldJSON(id: "b"))
        XCTAssertEqual(try storage.getLegacyWorldJSON(id: "c"), "f\u{FFFD}o")
        XCTAssertNil(try storage.getLegacyWorldJSON(id: "d"))
        XCTAssertThrowsError(try storage.listWorldRows(),
                             "strict collection must reject the corrupt BLOB row")

        let names = try storage.listLegacyTemplateNames()
        XCTAssertTrue(names.contains("a"))
        XCTAssertTrue(names.contains("b"))
        XCTAssertTrue(names.contains("z\u{FFFD}"))
        XCTAssertFalse(names.contains("blob"))
        let candidates = try storage.listLegacyTemplateSummaryCandidates()
        guard let corrupt = candidates.first(where: { $0.name == "b" }) else {
            return XCTFail("missing row-local candidate")
        }
        XCTAssertNil(corrupt.sizeX)
        XCTAssertNil(corrupt.dominantBlock)
        XCTAssertEqual(corrupt.dominantDisplay, "D\u{FFFD}")
        guard let truncated = candidates.first(where: { $0.name == "z\u{FFFD}" }) else {
            return XCTFail("missing repaired/truncated candidate")
        }
        XCTAssertNil(truncated.dominantBlock)
        XCTAssertEqual(truncated.dominantDisplay, "ok")
        XCTAssertEqual(try storage.getLegacyTemplateContent(name: "content"),
                       ElysiumLegacyTemplateContent(format: nil, data: nil, json: nil))
        XCTAssertEqual(try storage.getLegacyTemplateContent(name: "legacy"),
                       ElysiumLegacyTemplateContent(format: 1, data: nil,
                                                   json: "legacy-json"))
        XCTAssertThrowsError(try storage.listTemplateNames(),
                             "strict collection must reject NULL/BLOB names")
    }

    func testLegacyROWIDPagingTerminatesAcrossMixedKeysAndSortsUTF8Bytes() throws {
        let url = try databaseURL("legacy-rowid")
        var coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        try coordinator.close()
        try runSQLite(url, """
            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES('é','{}',0.0,1,NULL,1,1,1,1,1,'x','x');
            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES('z','{}',0.0,1,NULL,1,1,1,1,1,'x','x');
            INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                VALUES('a','{}',0.0,1,NULL,1,1,1,1,1,'x','x');
            WITH RECURSIVE values_cte(i) AS (
                SELECT 1 UNION ALL SELECT i+1 FROM values_cte WHERE i<300
            ) INSERT INTO templates(name,json,created,format,data,sizeX,sizeY,sizeZ,
                blockCount,blockEntityCount,dominantBlock,dominantDisplay)
                SELECT CAST(printf('blob-%03d',i) AS BLOB),'{}',0.0,1,NULL,
                       1,1,1,1,1,'x','x' FROM values_cte;

            WITH RECURSIVE worlds_cte(i) AS (
                SELECT 1 UNION ALL SELECT i+1 FROM worlds_cte WHERE i<300
            ) INSERT INTO worlds(id,json,lastPlayed)
                SELECT CAST(printf('world-%03d',i) AS BLOB),printf('json-%03d',i),0.0
                FROM worlds_cte;
            INSERT INTO worlds(id,json,lastPlayed) VALUES('text-before','before',0.0);
            INSERT INTO worlds(id,json,lastPlayed) VALUES('text-after','after',0.0);
            """)
        coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()
        XCTAssertEqual(try storage.listLegacyTemplateNames(), ["a", "e\u{301}", "z"])
        XCTAssertEqual(try storage.listLegacyWorldJSON().count, 302)
        XCTAssertThrowsError(try storage.listTemplateNames())
        XCTAssertThrowsError(try storage.listWorldRows())

        try coordinator._testSetLegacyCollectionFailure(.countDrift)
        XCTAssertThrowsError(try storage.listLegacyWorldJSON()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .schemaMismatch)
        }
        try coordinator._testSetLegacyCollectionFailure(.nonMonotonicRowID)
        XCTAssertThrowsError(try storage.listLegacyTemplateNames()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .schemaMismatch)
        }
    }

    func testLegacyLANOneQuerySkipsCorruptRowsSortsUTF8AndEnforces256Cap() throws {
        let url = try databaseURL("legacy-lan-one-query")
        var coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        try coordinator.close()
        try runSQLite(url, """
            INSERT INTO lan_players(world,playerID,json,updated) VALUES('w','é','e',0.0);
            INSERT INTO lan_players(world,playerID,json,updated) VALUES('w','z','z',0.0);
            INSERT INTO lan_players(world,playerID,json,updated) VALUES('w','a','a',0.0);
            INSERT INTO lan_players(world,playerID,json,updated)
                VALUES('w',CAST(X'626c6f62' AS BLOB),'ignored-id',0.0);
            INSERT INTO lan_players(world,playerID,json,updated)
                VALUES('w','ignored-json',X'00',0.0);
            INSERT INTO lan_players(world,playerID,json,updated)
                VALUES('w','q',CAST(X'71ff0078' AS TEXT),0.0);
            """)
        coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        var storage = try coordinator.legacyCore()
        XCTAssertEqual(try storage.listLegacyLANPlayerJSON(world: "w"), [
            ElysiumLegacyLANPlayerJSON(playerID: "a", json: "a"),
            ElysiumLegacyLANPlayerJSON(playerID: "e\u{301}", json: "e"),
            ElysiumLegacyLANPlayerJSON(playerID: "q", json: "q\u{FFFD}"),
            ElysiumLegacyLANPlayerJSON(playerID: "z", json: "z"),
        ])
        XCTAssertNil(try storage.getLegacyLANPlayerJSON(world: "w", playerID: "ignored-json"))
        XCTAssertThrowsError(try storage.listLANPlayerJSON(world: "w"))
        try coordinator.close()

        let capURL = try databaseURL("legacy-lan-cap")
        coordinator = try ElysiumStorageCoordinator.open(databaseURL: capURL)
        try coordinator.close()
        try runSQLite(capURL, """
            WITH RECURSIVE values_cte(i) AS (
                SELECT 1 UNION ALL SELECT i+1 FROM values_cte WHERE i<257
            ) INSERT INTO lan_players(world,playerID,json,updated)
                SELECT 'w',printf('p-%03d',i),'{}',0.0 FROM values_cte;
            """)
        coordinator = try ElysiumStorageCoordinator.open(databaseURL: capURL)
        storage = try coordinator.legacyCore()
        XCTAssertThrowsError(try storage.listLegacyLANPlayerJSON(world: "w")) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded)
        }
        try coordinator.close()
    }

    func testFreshZeroByteAndOnePageEmptyDatabasesBootstrap() throws {
        for (label, prepare) in [
            ("nonexistent", { (_: URL) throws in }),
            ("zero-byte", { (url: URL) throws in
                XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data()))
            }),
            ("one-page", { [unowned self] (url: URL) throws in
                _ = try self.runSQLite(url, "PRAGMA user_version=0")
            }),
        ] {
            let url = try databaseURL(label)
            try prepare(url)
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            try coordinator.legacyCore().verifyCoreSchema()
            try coordinator.close()
            XCTAssertEqual(try runSQLite(url, "SELECT count(*) FROM sqlite_master"), "13")
        }
    }

    func testCanonicalPhysicalManifestHasThirteenUniqueInRangeRoots() throws {
        let url = try databaseURL("root-manifest")
        try createCanonicalDatabase(url)
        let manifest = try runSQLite(url, """
            SELECT count(*)||'|'||count(DISTINCT rootpage)||'|'||min(rootpage)||'|'
                   ||max(rootpage)||'|'||(SELECT page_count FROM pragma_page_count)
            FROM sqlite_master;
            """)
        let values = manifest.split(separator: "|").compactMap { Int($0) }
        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(values[0], 13)
        XCTAssertEqual(values[1], 13)
        XCTAssertGreaterThanOrEqual(values[2], 2)
        XCTAssertLessThanOrEqual(values[3], values[4])
        XCTAssertEqual(try runSQLite(url, """
            SELECT count(*) FROM sqlite_master WHERE name='sqlite_autoindex_chunks_1'
            """), "0")
        XCTAssertEqual(try runSQLite(url, """
            SELECT count(*) FROM pragma_index_list('chunks')
            WHERE name='sqlite_autoindex_chunks_1'
            """), "1")
    }

    func testWrongClassZeroOneOutOfRangeAndDuplicateRootsRejectWithoutMutation() throws {
        let mutations: [(String, String)] = [
            ("wrong-class", "UPDATE sqlite_master SET rootpage='not-an-integer' WHERE name='advancements'"),
            ("zero", "UPDATE sqlite_master SET rootpage=0 WHERE name='advancements'"),
            ("one", "UPDATE sqlite_master SET rootpage=1 WHERE name='advancements'"),
            ("out-of-range", "UPDATE sqlite_master SET rootpage=(SELECT page_count+1 FROM pragma_page_count) WHERE name='advancements'"),
            ("duplicate", "UPDATE sqlite_master SET rootpage=(SELECT rootpage FROM sqlite_master WHERE name='worlds') WHERE name='advancements'"),
        ]
        for (index, mutation) in mutations.enumerated() {
            let url = try databaseURL(mutation.0)
            try createCanonicalDatabase(url)
            try runSQLite(url, """
                PRAGMA writable_schema=ON;
                \(mutation.1);
                PRAGMA schema_version=\(900 + index);
                """)
            let before = try Data(contentsOf: url)
            XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url), mutation.0)
            XCTAssertEqual(try Data(contentsOf: url), before, mutation.0)
        }
    }

    func testSchemaAuditAuthorizerDeniesAdjacentPragmasAndVirtualTables() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("audit-adjacent"))
        defer { try? coordinator.close() }
        for probe in ElysiumStorageSchemaAuditProbe.allCases {
            XCTAssertThrowsError(try coordinator._testSchemaAuditDeniedProbe(probe), "probe=\(probe)")
            XCTAssertTrue(try coordinator._testAutocommit(), "probe=\(probe)")
        }
        XCTAssertNoThrow(try coordinator.legacyCore().verifyCoreSchema())
    }

    func testQuickCheckBudgetExhaustionPrecedesTemplateDDLAndRedactsDiagnostics() throws {
        let url = try databaseURL("quick-check-budget")
        try runSQLite(url, templateFixtureSQL(prefixCount: 0))
        let before = try schemaSnapshot(url)
        XCTAssertThrowsError(try ElysiumStorageCoordinator._testOpen(
            databaseURL: url, failurePoint: .quickCheckBudgetExhausted)) { error in
            XCTAssertEqual(self.primaryStorageError(error), .schemaIntegrity)
            XCTAssertFalse(String(describing: error).contains("templates"))
            XCTAssertFalse(String(describing: error).contains("quick_check"))
        }
        XCTAssertEqual(try schemaSnapshot(url), before)
        XCTAssertEqual(try runSQLite(url, "SELECT count(*) FROM pragma_table_info('templates')"), "3")
    }

    func testRestoredNotNullSchemaOverNullLegacyRowFailsClosedAtOpen() throws {
        let url = try databaseURL("restored-not-null")
        try createCanonicalDatabase(url)
        try runSQLite(url, """
            PRAGMA writable_schema=ON;
            UPDATE sqlite_master SET sql=
                'CREATE TABLE worlds(id TEXT PRIMARY KEY, json TEXT, lastPlayed REAL NOT NULL DEFAULT 0)'
                WHERE name='worlds';
            PRAGMA schema_version=1300;
            """)
        try runSQLite(url, "INSERT INTO worlds(id,json,lastPlayed) VALUES('null-json',NULL,0.0)")
        try runSQLite(url, """
            PRAGMA writable_schema=ON;
            UPDATE sqlite_master SET sql=
                'CREATE TABLE worlds(id TEXT PRIMARY KEY, json TEXT NOT NULL, lastPlayed REAL NOT NULL DEFAULT 0)'
                WHERE name='worlds';
            PRAGMA schema_version=1301;
            """)
        XCTAssertNotEqual(try runSQLite(url, "PRAGMA quick_check(1)"), "ok")
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url)) { error in
            XCTAssertEqual(self.primaryStorageError(error), .schemaIntegrity)
            XCTAssertFalse(String(describing: error).contains("null-json"))
        }
    }

    func testCommittedUncheckpointedWALIsIncludedInCoherentAudit() throws {
        let url = try databaseURL("wal-coherent-audit")
        try createCanonicalDatabase(url)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &raw,
                                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        guard let raw else { return XCTFail("missing raw SQLite handle") }
        defer { sqlite3_close(raw) }
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA journal_mode=WAL;PRAGMA wal_autocheckpoint=0;",
                                    nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, """
            BEGIN IMMEDIATE;
            INSERT INTO worlds(id,json,lastPlayed) VALUES('wal-world','{}',1.0);
            COMMIT;
            """, nil, nil, nil), SQLITE_OK)
        XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")).count, 0)
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        XCTAssertEqual(try coordinator.legacyCore().getWorldRow(id: "wal-world")?.id, "wal-world")
        XCTAssertNoThrow(try coordinator.legacyCore().verifyCoreSchema())
        try coordinator.close()
    }
}
