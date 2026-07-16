import XCTest
import Foundation
import Darwin
import SQLite3
@testable import ElysiumStorage

final class ElysiumStorageAdversarialTests: XCTestCase {
    private func databaseURL(_ label: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElysiumStorageAdversarialTests-\(label)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("elysium.db")
    }

    @discardableResult
    private func runSQLite(_ databaseURL: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-noheader", databaseURL.path]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(sql.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            XCTFail("sqlite fixture failed: \(String(decoding: errorData, as: UTF8.self))")
            throw ElysiumStorageError.sqlite(primaryCode: process.terminationStatus,
                                            extendedCode: process.terminationStatus,
                                            operation: .open)
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func schemaAggregateBytes(_ databaseURL: URL) throws -> Int {
        let value = try runSQLite(databaseURL, """
            SELECT coalesce(sum(
                coalesce(length(CAST(sql AS BLOB)),0)
                +length(CAST(type AS BLOB))+length(CAST(name AS BLOB))
                +length(CAST(tbl_name AS BLOB))),0)
            FROM sqlite_master;
            """)
        guard let bytes = Int(value) else { throw ElysiumStorageError.invalidValue }
        return bytes
    }

    private func makeExactSchemaAggregateFixture(targetBytes: Int, label: String) throws -> URL {
        let url = try databaseURL(label)
        let repeated = String(repeating: "a", count: 14_000)
        let names = (0..<36).map { "idx_\(repeated)_\($0)" }
        var statements = ["""
            CREATE TABLE worlds(id TEXT PRIMARY KEY,json TEXT NOT NULL,
                                lastPlayed REAL NOT NULL DEFAULT 0)
            """]
        statements += names.map { "CREATE INDEX \"\($0)\" ON worlds(lastPlayed)" }
        try runSQLite(url, statements.joined(separator: ";"))

        guard let lastName = names.last else { throw ElysiumStorageError.invalidValue }
        try runSQLite(url, """
            DROP INDEX "\(lastName)";
            CREATE INDEX "\(lastName)" ON worlds(lastPlayed) WHERE '' IS NOT NULL;
            """)
        let emptyPredicateBytes = try schemaAggregateBytes(url)
        let paddingCount = targetBytes - emptyPredicateBytes
        guard paddingCount >= 0, paddingCount < 50_000 else {
            XCTFail("fixture padding outside per-object audit bound: \(paddingCount)")
            throw ElysiumStorageError.invalidValue
        }
        let padding = String(repeating: "x", count: paddingCount)
        try runSQLite(url, """
            DROP INDEX "\(lastName)";
            CREATE INDEX "\(lastName)" ON worlds(lastPlayed)
            WHERE '\(padding)' IS NOT NULL;
            """)
        XCTAssertEqual(try schemaAggregateBytes(url), targetBytes)
        return url
    }

    private func createCanonicalDatabase(_ url: URL, pageSize: Int = 4_096) throws {
        try runSQLite(url, "PRAGMA page_size=\(pageSize);VACUUM;")
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

    func testExactAdvertisedChunkCapCanBePersisted() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("chunk-cap"))
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()
        let key = try ElysiumChunkStorageKey(world: "w", dimension: 0, chunkX: 0, chunkZ: 0)
        let row = try ElysiumChunkStorageRow(key: key, data: Data(count: 67_108_864))

        XCTAssertEqual(try storage.putChunkBlobRows([row]), 1)
        XCTAssertEqual(try storage.getChunkBlob(key: key)?.count, 67_108_864)
    }

    func testEmptyChunkBatchStillHonorsClosedLifecycle() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("closed-empty"))
        let storage = try coordinator.legacyCore()
        try coordinator.close()

        XCTAssertThrowsError(try coordinator.legacyCore()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .closed)
        }
        XCTAssertThrowsError(try storage.putChunkBlobRows([])) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .closed)
        }
    }

    func testFailedHostileLegacyTemplateUpgradeLeavesPriorSchemaUntouched() throws {
        let url = try databaseURL("hostile-legacy-template")
        try runSQLite(url, """
            CREATE TABLE templates(
                name TEXT PRIMARY KEY,
                json TEXT NOT NULL CHECK(length(json)<10),
                created REAL NOT NULL DEFAULT 0
            );
            """)
        let before = try runSQLite(url, "SELECT group_concat(name,'|') FROM pragma_table_info('templates')")
        XCTAssertEqual(before, "name|json|created")

        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .schemaMismatch)
        }

        let after = try runSQLite(url, "SELECT group_concat(name,'|') FROM pragma_table_info('templates')")
        XCTAssertEqual(after, before, "failed factory committed a partial legacy schema migration")
    }

    func testSchemaManifestAggregateUsesUTF8BytesNotUnicodeScalarCount() throws {
        let url = try databaseURL("schema-utf8-byte-budget")
        try runSQLite(url, """
            CREATE TABLE worlds(
                id TEXT PRIMARY KEY,
                json TEXT NOT NULL,
                lastPlayed REAL NOT NULL DEFAULT 0
            );
            """)
        let multibyteComment = String(repeating: "\u{1F642}", count: 15_000)
        for index in 0..<18 {
            try runSQLite(url, """
                CREATE INDEX "\(multibyteComment)_\(index)"
                ON worlds(lastPlayed);
                """)
        }

        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded,
                           "the aggregate must reject >1 MiB of UTF-8 before object inspection")
        }
    }

    func testPostSQLiteOpenIdentityRaceDoesNotLeakAnUntrackedHandle() throws {
        struct Identity: Hashable {
            let device: dev_t
            let inode: ino_t
        }

        func identity(at path: String) -> Identity? {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return Identity(device: info.st_dev, inode: info.st_ino)
        }

        func openDescriptorCount(for identities: Set<Identity>) -> Int {
            var count = 0
            for descriptor in 0..<min(Int(getdtablesize()), 8_192) {
                var info = stat()
                if fstat(Int32(descriptor), &info) == 0,
                   identities.contains(Identity(device: info.st_dev,
                                                inode: info.st_ino)) {
                    count += 1
                }
            }
            return count
        }

        let delays: [useconds_t] = [0, 10, 25, 50, 100, 200, 400, 800, 1_600, 3_200]
        var reproducedLeak = false
        var reproducedAttempt = -1
        var reproducedDelay: useconds_t = 0
        for attempt in 0..<200 where !reproducedLeak {
            let url = try databaseURL("identity-race-\(attempt)")
            let replacement = url.deletingLastPathComponent().appendingPathComponent("replacement.db")
            let displaced = url.deletingLastPathComponent().appendingPathComponent("displaced.db")
            XCTAssertTrue(FileManager.default.createFile(atPath: replacement.path, contents: Data()))
            let race = DispatchGroup()
            race.enter()
            DispatchQueue.global().async {
                defer { race.leave() }
                while !FileManager.default.fileExists(atPath: url.path) { usleep(5) }
                usleep(delays[attempt % delays.count])
                _ = Darwin.rename(url.path, displaced.path)
                _ = Darwin.rename(replacement.path, url.path)
            }

            var coordinator: ElysiumStorageCoordinator?
            var factoryFailed = false
            do {
                coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            } catch {
                factoryFailed = true
            }
            XCTAssertEqual(race.wait(timeout: .now() + 5), .success)
            try? coordinator?.close()
            coordinator = nil

            let identities = Set([identity(at: url.path), identity(at: displaced.path)].compactMap { $0 })
            reproducedLeak = factoryFailed && openDescriptorCount(for: identities) > 0
            if reproducedLeak {
                reproducedAttempt = attempt
                reproducedDelay = delays[attempt % delays.count]
                // The lease was released despite the untracked handle, so the same
                // physical database can be published through a second coordinator.
                let reopened = try ElysiumStorageCoordinator.open(databaseURL: url)
                try reopened.close()
            }
            if !reproducedLeak {
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            }
        }
        XCTAssertFalse(reproducedLeak,
                       "failed factory leaked a SQLite descriptor after identity verification "
                       + "(attempt=\(reproducedAttempt), delay=\(reproducedDelay)us)")
    }

    func testCollectionByteAccountingIncludesAllUTF8OctetsAndEmbeddedNUL() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("utf8-octets"))
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()
        let id = "a\u{00E9}\u{1F642}\0z"
        let json = "\0\u{00E9}\u{1F642}"
        XCTAssertEqual(id.utf8.count, 9)
        XCTAssertEqual(json.utf8.count, 7)
        let row = try ElysiumWorldStorageRow(id: id, json: json, lastPlayed: 1)
        try storage.putWorldRow(row)
        XCTAssertEqual(try storage.getWorldRow(id: id), row)
        XCTAssertEqual(try storage.listWorldRows(), [row])
        XCTAssertThrowsError(try storage._testWorldCollectionThreeByteBudget()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded)
        }
    }

    func testSchemaManifestAggregateAcceptsExactMiBAndRejectsOneByteOverBeforeInspection() throws {
        let exactURL = try makeExactSchemaAggregateFixture(
            targetBytes: 1_048_576, label: "manifest-exact")
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: exactURL)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .schemaMismatch,
                           "the exact aggregate must reach object inspection")
        }

        let oneOverURL = try makeExactSchemaAggregateFixture(
            targetBytes: 1_048_577, label: "manifest-one-over")
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: oneOverURL)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded,
                           "one byte over must fail before object inspection")
        }
    }

    func testWorstCaseChunkRowCapsAndExtremeCoordinatesPersistAtOnce() throws {
        let url = try databaseURL("chunk-simultaneous-max")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        defer {
            try? coordinator.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let storage = try coordinator.legacyCore()
        let world = String(repeating: "w", count: 1_048_576)
        let key = try ElysiumChunkStorageKey(
            world: world, dimension: .max, chunkX: .min, chunkZ: .max)
        let below = try ElysiumChunkStorageRow(key: key, data: Data(count: 67_108_863))
        XCTAssertEqual(try storage.putChunkBlobRows([below]), 1)
        XCTAssertEqual(try storage.getChunkBlob(key: key)?.count, 67_108_863)
        let exact = try ElysiumChunkStorageRow(key: key, data: Data(count: 67_108_864))
        XCTAssertEqual(try storage.putChunkBlobRows([exact]), 1)
        XCTAssertEqual(try storage.getChunkBlob(key: key)?.count, 67_108_864)

        XCTAssertThrowsError(try ElysiumChunkStorageRow(
            key: key, data: Data(count: 67_108_865))) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded)
        }
        XCTAssertThrowsError(try ElysiumChunkStorageKey(
            world: world + "w", dimension: 0, chunkX: 0, chunkZ: 0)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded)
        }
    }

    func testTemplateShippedCapsSimultaneousAggregateAndNumericExtremesPersist() throws {
        let url = try databaseURL("template-simultaneous-max")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        defer {
            try? coordinator.close()
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        let storage = try coordinator.legacyCore()
        let maximumText = String(repeating: "t", count: 1_048_576)
        let json = String(repeating: "j", count: 24_000_000)
        let data = Data(count: 64_000_000)
        let summary = try ElysiumTemplateSummaryStorageRow(
            name: maximumText, sizeX: 0, sizeY: .max, sizeZ: 0,
            blockCount: .max, blockEntityCount: 0,
            dominantBlock: maximumText, dominantDisplay: maximumText)
        let row = try ElysiumTemplateStorageRow(
            summary: summary, json: json, created: -Double.greatestFiniteMagnitude,
            format: .max, data: data)
        XCTAssertEqual(try storage.putTemplateRow(row), 1)
        XCTAssertEqual(try storage.getTemplateRow(name: maximumText), row)

        let smallSummary = try ElysiumTemplateSummaryStorageRow(
            name: "small", sizeX: 0, sizeY: 0, sizeZ: 0,
            blockCount: 0, blockEntityCount: 0,
            dominantBlock: "", dominantDisplay: "")
        XCTAssertThrowsError(try ElysiumTemplateStorageRow(
            summary: smallSummary, json: json + "x", created: 0,
            format: 1, data: nil)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded)
        }
        XCTAssertThrowsError(try ElysiumTemplateStorageRow(
            summary: smallSummary, json: "", created: 0,
            format: 2, data: Data(count: 64_000_001))) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .limitExceeded)
        }
    }

    func testPrivateSQLiteWholeRecordCeilingIsExact() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("row-ceiling"))
        defer { try? coordinator.close() }
        let probe = try coordinator._testSQLiteLengthLimitProbe()
        XCTAssertEqual(probe.configured, 91_146_752)
        XCTAssertEqual(probe.exactBindCode, SQLITE_OK)
        XCTAssertEqual(probe.oneOverBindCode, SQLITE_TOOBIG)
    }

    func testUniqueInteriorLeafAutoindexAndWithoutRowIDChildAliasesAreRejected() throws {
        struct AliasCase {
            let label: String
            let populationSQL: String
            let dbstatName: String
            let pageType: String
        }
        let worldRows = """
            WITH RECURSIVE c(i) AS (
                SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<50000
            ) INSERT INTO worlds(id,json,lastPlayed)
              SELECT printf('world-%08d',i),printf('%0300d',i),i*1.0 FROM c;
            """
        let chunkRows = """
            WITH RECURSIVE c(i) AS (
                SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<8000
            ) INSERT INTO chunks(world,dim,cx,cz,data)
              SELECT 'w',0,i,0,randomblob(80) FROM c;
            """
        let cases = [
            AliasCase(label: "table-interior", populationSQL: worldRows,
                      dbstatName: "worlds", pageType: "internal"),
            AliasCase(label: "table-leaf", populationSQL: worldRows,
                      dbstatName: "worlds", pageType: "leaf"),
            AliasCase(label: "autoindex-child", populationSQL: worldRows,
                      dbstatName: "sqlite_autoindex_worlds_1", pageType: "leaf"),
            AliasCase(label: "without-rowid-child", populationSQL: chunkRows,
                      dbstatName: "chunks", pageType: "leaf"),
        ]

        for (index, value) in cases.enumerated() {
            let url = try databaseURL(value.label)
            try createCanonicalDatabase(url, pageSize: 512)
            try runSQLite(url, value.populationSQL)
            let childText = try runSQLite(url, """
                SELECT pageno FROM dbstat
                WHERE name='\(value.dbstatName)' AND pagetype='\(value.pageType)'
                  AND path<>'/'
                  AND pageno NOT IN (SELECT rootpage FROM sqlite_master)
                ORDER BY pageno LIMIT 1;
                """)
            guard let childPage = Int64(childText), childPage >= 2 else {
                return XCTFail("missing \(value.label) child page")
            }
            try runSQLite(url, """
                PRAGMA writable_schema=ON;
                UPDATE sqlite_master SET rootpage=\(childPage) WHERE name='advancements';
                PRAGMA schema_version=\(1400 + index);
                """)
            XCTAssertEqual(try runSQLite(url, """
                SELECT rootpage FROM sqlite_master WHERE name='advancements'
                """), String(childPage), "the hostile root alias was not retained")
            XCTAssertNotEqual(try runSQLite(url, "SELECT count(*) FROM advancements"), "",
                              "an unprotected connection rejected the aliased tree before scanning")
            let diagnostic = try runSQLite(url, "PRAGMA quick_check(1)")
            XCTAssertNotEqual(diagnostic, "ok")
            let before = try Data(contentsOf: url)
            XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url), value.label) {
                error in
                XCTAssertEqual(self.primaryStorageError(error), .schemaIntegrity)
                XCTAssertFalse(String(describing: error).contains(diagnostic))
            }
            XCTAssertEqual(try Data(contentsOf: url), before, value.label)
        }
    }

    func testDenseValidFixturesAcrossSupportedPageSizesRemainUsable() throws {
        for pageSize in [512, 4_096, 65_536] {
            let url = try databaseURL("dense-\(pageSize)")
            try createCanonicalDatabase(url, pageSize: pageSize)
            try runSQLite(url, """
                WITH RECURSIVE c(i) AS (
                    SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<3000
                ) INSERT INTO worlds(id,json,lastPlayed)
                  SELECT printf('world-%06d',i),printf('%0200d',i),i*1.0 FROM c;
                """)
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            XCTAssertNoThrow(try coordinator.legacyCore().verifyCoreSchema())
            XCTAssertEqual(try coordinator.legacyCore().listWorldRows().count, 3_000)
            try coordinator.close()
            XCTAssertEqual(try runSQLite(url, "PRAGMA page_size"), String(pageSize))
        }
    }

    func testTerminalSQLiteSurfaceSourceGate() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceURL = repository.appendingPathComponent("Sources/ElysiumStorage/StorageEngine.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        XCTAssertFalse(source.contains("sqlite3_blob_"))
        XCTAssertFalse(source.contains("sqlite3_backup_"))
        XCTAssertEqual(source.components(separatedBy: "sqlite3_close_v2(").count - 1, 1,
                       "close_v2 is allowed only for pre-publication factory cleanup")
        XCTAssertTrue(source.contains("let closeRC = sqlite3_close_v2(localHandle)"))
        guard let cleanup = source.range(of: "let closeRC = sqlite3_close_v2(localHandle)") else {
            return XCTFail("missing approved factory cleanup")
        }
        let prefix = source[..<cleanup.lowerBound].suffix(1_200)
        XCTAssertTrue(prefix.contains("if let localHandle = opened"))
        XCTAssertTrue(prefix.contains("sqlite3_open_v2"))
    }

    func testCloseV2UndefinedSymbolParserRejectsSpoofsAndAdjacentNames() throws {
        func runAWK(_ program: String, input: String) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/awk")
            process.arguments = [program]
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            return (process.terminationStatus,
                    String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                           as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let exactProgram = #"$NF == "_sqlite3_close_v2"{n++} END{print n+0}"#
        let adjacentProgram = #"$NF != "_sqlite3_close_v2" && index($NF,"sqlite3_close_v2"){bad=1} END{exit bad ? 0 : 1}"#
        let legitimate = "                 U _sqlite3_close_v2\n"
        let spoof = "                 U _sqlite3_close_v2_evil\n"

        XCTAssertEqual(try runAWK(exactProgram, input: spoof).output, "0",
                       "an adjacent name must not satisfy the exact import count")
        XCTAssertEqual(try runAWK(adjacentProgram, input: spoof).status, 0,
                       "an adjacent-only symbol must trigger explicit rejection")
        XCTAssertEqual(try runAWK(exactProgram, input: legitimate + spoof).output, "1")
        XCTAssertEqual(try runAWK(adjacentProgram, input: legitimate + spoof).status, 0,
                       "one legitimate import cannot hide an adjacent symbol")
        XCTAssertEqual(try runAWK(adjacentProgram, input: legitimate).status, 1)

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let verifier = try String(contentsOf: repository.appendingPathComponent(
            "scripts/verify-elysium-storage-release-surface.sh"), encoding: .utf8)
        XCTAssertTrue(verifier.contains(exactProgram))
        XCTAssertTrue(verifier.contains(adjacentProgram))
    }
}
