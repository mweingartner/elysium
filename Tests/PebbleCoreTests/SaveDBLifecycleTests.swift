import Foundation
import XCTest
@testable import PebbleCore
@testable import PebbleStorage

final class SaveDBLifecycleTests: XCTestCase {
    private func makeURL(_ label: String) throws -> (directory: URL, database: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pebble-save-lifecycle-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, directory.appendingPathComponent("pebble.db"))
    }

    func testThrowingFactoryAndDuplicateOpenHaveClosedErrors() throws {
        let location = try makeURL("duplicate")
        let first = try SaveDB.open(databaseURL: location.database, migrateLegacy: false)
        defer { try? first.close() }
        XCTAssertThrowsError(try SaveDB.open(databaseURL: location.database, migrateLegacy: false)) {
            XCTAssertEqual($0 as? SaveDBOpenError,
                           SaveDBOpenError(stage: .storageOpen, result: .conflict))
        }
    }

    func testMigrationEnabledFactoryCreatesMissingParentBeforePreflight() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pebble-save-missing-parent-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("nested/pebble.db")
        let database = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: databaseURL.path))
        try database.close()
    }

    func testExplicitCloseIsIdempotentAndPostCloseMatrixFailsClosed() throws {
        let location = try makeURL("close")
        let database = try SaveDB.open(databaseURL: location.database, migrateLegacy: false)
        database.putWorld(WorldRecord(id: "world", name: "World", seed: 1,
                                      gameMode: GameMode.survival, difficulty: 2))
        try database.close()
        try database.close()

        XCTAssertEqual(database.listWorlds().count, 0)
        XCTAssertNil(database.getWorld("world"))
        XCTAssertEqual(database.getChunkKeys("world"), [])
        XCTAssertNil(database.getChunk("world", 0, 0, 0))
        XCTAssertFalse(database.putChunks([]))
        XCTAssertNil(database.getPlayer("world"))
        XCTAssertNil(database.getLANClientResume("host"))
        XCTAssertNil(database.getLANPlayer(world: "world", playerID: "peer"))
        XCTAssertEqual(database.listLANPlayers(world: "world").count, 0)
        XCTAssertNil(database.getAdvancements("world"))
        XCTAssertEqual(database.listTemplates(), [])
        XCTAssertEqual(database.listTemplateSummaries(), [])
        XCTAssertNil(try database.getTemplate(named: "valid"))
        XCTAssertThrowsError(try database.getTemplate(named: "")) {
            XCTAssertEqual($0 as? TemplateError, .invalidName)
        }
    }

    func testConcurrentCloseReadAndWriteRemainBounded() throws {
        let location = try makeURL("concurrent")
        let database = try SaveDB.open(databaseURL: location.database, migrateLegacy: false)
        let queue = DispatchQueue(label: "pebble.lifecycle.test", attributes: .concurrent)
        let group = DispatchGroup()
        for index in 0..<64 {
            group.enter()
            queue.async {
                if index % 3 == 0 {
                    try? database.close()
                } else if index % 3 == 1 {
                    _ = database.listWorlds()
                } else {
                    database.putWorld(WorldRecord(id: "w-\(index)", name: "World", seed: 1,
                                                  gameMode: 0, difficulty: 2))
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        try database.close()
    }

    func testDeferredDeinitEventuallyReleasesHealthyLease() throws {
        let location = try makeURL("deinit")
        autoreleasepool {
            _ = try? SaveDB.open(databaseURL: location.database, migrateLegacy: false)
        }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let reopened = try? SaveDB.open(databaseURL: location.database, migrateLegacy: false) {
                try? reopened.close()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("deferred cleanup did not release the physical database lease")
    }

    func testOpenErrorDescriptionContainsOnlyClosedValues() {
        let value = SaveDBOpenError(stage: .migrationDecode, result: .invalidSource)
        XCTAssertEqual(value.description,
                       "Pebble save open failed: migrationDecode/invalidSource")
    }

    func testResumeUpdatedNormalizationPreservesFrozenCases() {
        XCTAssertEqual(SaveDB._testNormalizeResumeUpdated(false, now: 99), 0)
        XCTAssertEqual(SaveDB._testNormalizeResumeUpdated(true, now: 99), 1)
        XCTAssertEqual(SaveDB._testNormalizeResumeUpdated(-42.5, now: 99), -42.5)
        XCTAssertEqual(SaveDB._testNormalizeResumeUpdated(Double.nan, now: 99), 0)
        XCTAssertEqual(SaveDB._testNormalizeResumeUpdated(Double.infinity, now: 99),
                       .greatestFiniteMagnitude)
        XCTAssertEqual(SaveDB._testNormalizeResumeUpdated(-Double.infinity, now: 99),
                       -.greatestFiniteMagnitude)
        XCTAssertEqual(SaveDB._testNormalizeResumeUpdated("not numeric", now: 99), 99)
        XCTAssertEqual(SaveDB._testNormalizeResumeUpdated(nil, now: .nan), 0)
    }

    func testStorageErrorMappingIsExhaustiveForOpenAndSchemaStages() {
        let cases: [(PebbleStorageError, SaveDBOpenError.Result)] = [
            (.duplicateOpen, .conflict),
            (.invalidValue, .invalidSource), (.invalidStorageClass, .invalidSource),
            (.invalidUTF8, .invalidSource), (.schemaMismatch, .invalidSource),
            (.schemaIntegrity, .invalidSource), (.limitExceeded, .limitExceeded),
            (.openFailed(primaryCode: 1, extendedCode: 2), .unavailable),
            (.sqlite(primaryCode: 1, extendedCode: 2, operation: .open), .unavailable),
            (.nestedTransaction, .unavailable), (.capabilityViolation, .unavailable),
            (.inactiveContext, .unavailable), (.wrongExecutorOrQueue, .unavailable),
            (.statementLeak, .unavailable), (.transactionStillOpen, .unavailable),
            (.poisoned, .unavailable), (.closed, .unavailable),
        ]
        for stage in [SaveDBOpenError.Stage.storageOpen, .schemaVerification] {
            for (input, result) in cases {
                XCTAssertEqual(SaveDB._testMapStorageError(input, stage: stage),
                               SaveDBOpenError(stage: stage, result: result),
                               "stage=\(stage) input=\(input)")
            }
        }
    }

    func testCompatibilityInitializerFatalErrorIsPathRedactedInSubprocess() throws {
        if ProcessInfo.processInfo.environment["PEBBLE_COMPAT_INIT_CHILD"] == "1" {
            _ = SaveDB()
            return XCTFail("compatibility initializer unexpectedly returned")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pebble-compat-redaction-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blocker = root.appendingPathComponent("Library/Application Support/Pebble")
        try FileManager.default.createDirectory(
            at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("block".utf8).write(to: blocker)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let testName = "PebbleCoreTests.SaveDBLifecycleTests/testCompatibilityInitializerFatalErrorIsPathRedactedInSubprocess"
        if let bundle = CommandLine.arguments.last, bundle.hasSuffix(".xctest") {
            child.arguments = ["-XCTest", testName, bundle]
        } else {
            child.arguments = [testName]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PEBBLE_COMPAT_INIT_CHILD"] = "1"
        environment["CFFIXED_USER_HOME"] = root.path
        let secret = "compat-secret-\(UUID().uuidString)"
        environment["PEBBLE_SECRET_SENTINEL"] = secret
        child.environment = environment
        child.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        child.standardError = errors
        let captureLock = NSLock()
        var captured = Data()
        var overflow = false
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            captureLock.lock()
            if captured.count + chunk.count > 65_536 {
                overflow = true
                captureLock.unlock()
                if child.isRunning { child.terminate() }
                return
            }
            captured.append(chunk)
            captureLock.unlock()
        }
        try child.run()
        child.waitUntilExit()
        errors.fileHandleForReading.readabilityHandler = nil
        let tail = errors.fileHandleForReading.readDataToEndOfFile()
        captureLock.lock()
        if captured.count + tail.count > 65_536 {
            overflow = true
        } else {
            captured.append(tail)
        }
        let bounded = captured
        captureLock.unlock()
        XCTAssertFalse(overflow, "compatibility initializer stderr exceeded 65,536 bytes")
        let text = String(decoding: bounded, as: UTF8.self)
        XCTAssertNotEqual(child.terminationStatus, 0)
        let stable = "Pebble save database initialization failed"
        XCTAssertEqual(text.components(separatedBy: stable).count - 1, 1)
        XCTAssertFalse(text.contains(root.path), text)
        XCTAssertFalse(text.contains("pebble.db"), text)
        XCTAssertFalse(text.contains("SELECT"), text)
        XCTAssertFalse(text.contains("PRAGMA"), text)
        XCTAssertFalse(text.contains("CREATE TABLE"), text)
        XCTAssertFalse(text.contains(secret), text)
    }

    func testSourceSurfaceHasOneDelegatingGameCoreCompatibilityInitializerAndNoSilentAlternative() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let gameCore = try String(contentsOf: root.appendingPathComponent(
            "Sources/PebbleCore/Game/GameCore.swift"), encoding: .utf8)
        let saves = try String(contentsOf: root.appendingPathComponent(
            "Sources/PebbleCore/Game/Saves.swift"), encoding: .utf8)
        XCTAssertEqual(gameCore.components(separatedBy: "SaveDB()").count - 1, 1)
        let compatibility = "public convenience init(db: SaveDB = SaveDB())"
        XCTAssertEqual(gameCore.components(separatedBy: compatibility).count - 1, 1)
        XCTAssertEqual(saves.components(separatedBy: "public convenience init()").count - 1, 1)
        XCTAssertTrue(saves.contains("fatalError(\"Pebble save database initialization failed\")"))
    }
}
