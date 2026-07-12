import XCTest
import Foundation
import CryptoKit
import SQLite3
@testable import PebbleCore
@testable import PebbleStorage

final class SaveDBPlayerRowCASTests: XCTestCase {
    private let worldByteCap = 1_048_576
    private let playerJSONByteCap = 786_432

    private func fixture(_ label: String) throws -> (SaveDB, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PebblePlayerCAS-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("pebble.db")
        let database = try SaveDB.open(databaseURL: url, migrateLegacy: false)
        addTeardownBlock {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        database.putWorld(WorldRecord(id: "world", name: "World", seed: 1,
                                      gameMode: 0, difficulty: 1))
        return (database, url)
    }

    private func exactDigest(world: String, json: String) -> Data {
        var digest = SHA256()
        digest.update(data: Data("Pebble/player-row/exact-json/v1\0".utf8))
        let worldBytes = Data(world.utf8), jsonBytes = Data(json.utf8)
        let worldCount = UInt32(worldBytes.count), jsonCount = UInt64(jsonBytes.count)
        digest.update(data: Data([
            UInt8(truncatingIfNeeded: worldCount >> 24),
            UInt8(truncatingIfNeeded: worldCount >> 16),
            UInt8(truncatingIfNeeded: worldCount >> 8), UInt8(truncatingIfNeeded: worldCount),
        ]))
        digest.update(data: worldBytes)
        digest.update(data: Data((0..<8).reversed().map {
            UInt8(truncatingIfNeeded: jsonCount >> UInt64($0 * 8))
        }))
        digest.update(data: jsonBytes)
        return Data(digest.finalize())
    }

    private func raw(_ url: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw PebbleStorageError.invalidValue }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw PebbleStorageError.invalidValue
        }
    }

    func testDigestLengthExactBytesAndStoredJSONIdentity() throws {
        XCTAssertThrowsError(try PebblePlayerJSONRowDigest(
            data: Data(repeating: 0, count: 31))) {
                XCTAssertEqual($0 as? PebbleStorageError, .invalidValue)
        }
        XCTAssertNoThrow(try PebblePlayerJSONRowDigest(data: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try PebblePlayerJSONRowDigest(
            data: Data(repeating: 0, count: 33))) {
                XCTAssertEqual($0 as? PebbleStorageError, .invalidValue)
        }
        XCTAssertThrowsError(try SaveDBPlayerRowDigest(data: Data(repeating: 0, count: 31))) {
            XCTAssertEqual($0 as? SaveDBPlayerRowError, .invalidCandidate)
        }
        XCTAssertNoThrow(try SaveDBPlayerRowDigest(data: Data(repeating: 0, count: 32)))
        XCTAssertThrowsError(try SaveDBPlayerRowDigest(data: Data(repeating: 0, count: 33))) {
            XCTAssertEqual($0 as? SaveDBPlayerRowError, .invalidCandidate)
        }

        let (database, _) = try fixture("digest")
        database.putPlayer("world", ["b": 2, "a": 1])
        let snapshot = try XCTUnwrap(database.getPlayerChecked("world"))
        let exactJSON = #"{"a":1,"b":2}"#
        XCTAssertEqual(snapshot.canonicalDigest.data,
                       exactDigest(world: "world", json: exactJSON))
        XCTAssertEqual(snapshot.data["a"] as? Int, 1)
        XCTAssertEqual(snapshot.data["b"] as? Int, 2)
    }

    func testAbsentPresentConflictAndCommittedSnapshots() throws {
        let (database, _) = try fixture("states")
        let first = try database.compareAndSwapPlayerChecked(
            "world", expected: .absent, candidate: ["revision": 1])
        XCTAssertEqual(first.data["revision"] as? Int, 1)
        XCTAssertEqual(first.worldID, "world")
        XCTAssertThrowsError(try database.compareAndSwapPlayerChecked(
            "world", expected: .absent, candidate: ["revision": 2])) {
                XCTAssertEqual($0 as? SaveDBPlayerRowError, .conflict)
        }
        for index in [0, 31] {
            var wrong = first.canonicalDigest.data; wrong[index] ^= 1
            XCTAssertThrowsError(try database.compareAndSwapPlayerChecked(
                "world", expected: .present(try SaveDBPlayerRowDigest(data: wrong)),
                candidate: ["revision": 2])) {
                    XCTAssertEqual($0 as? SaveDBPlayerRowError, .conflict)
            }
        }
        let second = try database.compareAndSwapPlayerChecked(
            "world", expected: .present(first.canonicalDigest), candidate: ["revision": 2])
        XCTAssertEqual(second.data["revision"] as? Int, 2)
    }

    func testMissingParentAndWorldDeleteOrderingForAbsentAndPresent() throws {
        let (absentBefore, _) = try fixture("delete-absent-before")
        absentBefore.deleteWorld("world")
        XCTAssertThrowsError(try absentBefore.compareAndSwapPlayerChecked(
            "world", expected: .absent, candidate: ["revision": 1])) {
                XCTAssertEqual($0 as? SaveDBPlayerRowError, .conflict)
        }
        XCTAssertNil(absentBefore.getPlayer("world"))

        let (presentBefore, _) = try fixture("delete-present-before")
        presentBefore.putPlayer("world", ["revision": 1])
        let deletedSnapshot = try XCTUnwrap(presentBefore.getPlayerChecked("world"))
        presentBefore.deleteWorld("world")
        XCTAssertThrowsError(try presentBefore.compareAndSwapPlayerChecked(
            "world", expected: .present(deletedSnapshot.canonicalDigest),
            candidate: ["revision": 2])) {
                XCTAssertEqual($0 as? SaveDBPlayerRowError, .conflict)
        }
        XCTAssertNil(presentBefore.getPlayer("world"))

        let (absentAfter, _) = try fixture("delete-absent-after")
        _ = try absentAfter.compareAndSwapPlayerChecked(
            "world", expected: .absent, candidate: ["revision": 1])
        absentAfter.deleteWorld("world")
        XCTAssertNil(absentAfter.getPlayer("world"))

        let (presentAfter, _) = try fixture("delete-present-after")
        presentAfter.putPlayer("world", ["revision": 1])
        let original = try XCTUnwrap(presentAfter.getPlayerChecked("world"))
        _ = try presentAfter.compareAndSwapPlayerChecked(
            "world", expected: .present(original.canonicalDigest),
            candidate: ["revision": 2])
        presentAfter.deleteWorld("world")
        XCTAssertNil(presentAfter.getPlayer("world"))
    }

    func testWorldAndJSONBoundariesStoreExactBytesAndRejectBeforeRank() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PebblePlayerCAS-boundaries-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = try PebbleStorageCoordinator.open(
            databaseURL: directory.appendingPathComponent("pebble.db"))
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()

        for (label, world) in [
            ("one", "w"),
            ("cap", String(repeating: "w", count: worldByteCap)),
        ] {
            try storage.putWorldRow(try PebbleWorldStorageRow(
                id: world, json: "{}", lastPlayed: 0))
            let candidate = try PebblePlayerJSONStorageRow(world: world, json: "{}")
            XCTAssertEqual(try storage.compareAndSwapPlayerJSON(
                expected: .absent, candidate: candidate), .committed(candidate), label)
            XCTAssertEqual(try storage.getPlayerJSON(world: world), candidate, label)
        }
        XCTAssertThrowsError(try PebblePlayerJSONStorageRow(
            world: String(repeating: "w", count: worldByteCap + 1), json: "{}")) {
                XCTAssertEqual($0 as? PebbleStorageError, .limitExceeded)
        }

        for size in [playerJSONByteCap - 1, playerJSONByteCap] {
            let world = "json-\(size)"
            try storage.putWorldRow(try PebbleWorldStorageRow(
                id: world, json: "{}", lastPlayed: 0))
            let json = #"{"v":""# + String(repeating: "x", count: size - 8) + #""}"#
            XCTAssertEqual(json.utf8.count, size)
            let candidate = try PebblePlayerJSONStorageRow(world: world, json: json)
            XCTAssertEqual(try storage.compareAndSwapPlayerJSON(
                expected: .absent, candidate: candidate), .committed(candidate))
            XCTAssertEqual(try storage.getPlayerJSON(world: world)?.json, json)
        }
        XCTAssertThrowsError(try PebblePlayerJSONStorageRow(
            world: "world", json: String(repeating: "x", count: playerJSONByteCap + 1))) {
                XCTAssertEqual($0 as? PebbleStorageError, .limitExceeded)
        }

        let (database, _) = try fixture("candidate-pre-rank")
        XCTAssertThrowsError(try database.compareAndSwapPlayerChecked(
            "", expected: .absent, candidate: [:])) {
            XCTAssertEqual($0 as? SaveDBPlayerRowError, .invalidCandidate)
        }
        XCTAssertEqual(database._testPlayerCASRanks(), [0])
        XCTAssertThrowsError(try database.compareAndSwapPlayerChecked(
            String(repeating: "w", count: worldByteCap + 1),
            expected: .absent, candidate: [:])) {
                XCTAssertEqual($0 as? SaveDBPlayerRowError, .invalidCandidate)
        }
        XCTAssertEqual(database._testPlayerCASRanks(), [0])
        XCTAssertThrowsError(try database.compareAndSwapPlayerChecked(
            "world", expected: .absent,
            candidate: ["v": String(repeating: "x", count: playerJSONByteCap + 1 - 8)])) {
                XCTAssertEqual($0 as? SaveDBPlayerRowError, .invalidCandidate)
        }
        XCTAssertEqual(database._testPlayerCASRanks(), [0])
    }

    func testStoredWrongClassOversizeInvalidUTF8AndNonObjectMapExactly() throws {
        let cases = [
            "42",
            "CAST(zeroblob(786433) AS TEXT)",
            "CAST(X'FF' AS TEXT)",
            "'[]'",
        ]
        for (index, expression) in cases.enumerated() {
            let (database, url) = try fixture("hostile-\(index)")
            try raw(url, "DELETE FROM player; INSERT INTO player(world,json) VALUES('world',\(expression))")
            XCTAssertThrowsError(try database.getPlayerChecked("world"), expression) {
                XCTAssertEqual($0 as? SaveDBPlayerRowError, .invalidStoredRow)
            }
        }

        let keyClasses: [(label: String, expression: String, lookup: String, matches: Bool)] = [
            ("numeric", "42", "42", true),
            ("blob", "X'776F726C64'", "world", true),
            ("null", "NULL", "world", false),
        ]
        for keyClass in keyClasses {
            let (database, url) = try fixture("player-key-\(keyClass.label)")
            try raw(url, """
                DROP TABLE player;
                CREATE TABLE player(world, json);
                INSERT INTO player(world,json) VALUES(\(keyClass.expression),'{}');
                """)
            if keyClass.matches {
                XCTAssertThrowsError(try database.getPlayerChecked(keyClass.lookup), keyClass.label) {
                    XCTAssertEqual($0 as? SaveDBPlayerRowError, .invalidStoredRow)
                }
            } else {
                XCTAssertNil(try database.getPlayerChecked(keyClass.lookup), keyClass.label)
            }
        }

        for (label, expression) in [
            ("numeric", "42"), ("blob", "X'7B7D'"), ("null", "NULL"),
        ] {
            let (database, url) = try fixture("player-json-\(label)")
            try raw(url, """
                DROP TABLE player;
                CREATE TABLE player(world, json);
                INSERT INTO player(world,json) VALUES('world',\(expression));
                """)
            XCTAssertThrowsError(try database.getPlayerChecked("world"), label) {
                XCTAssertEqual($0 as? SaveDBPlayerRowError, .invalidStoredRow)
            }
        }

        let parentClasses: [(label: String, expression: String, candidate: String)] = [
            ("numeric", "42", "42"),
            ("blob", "X'776F726C64'", "world"),
            ("null", "NULL", "world"),
        ]
        for parentClass in parentClasses {
            for present in [false, true] {
                let (database, url) = try fixture(
                    "parent-\(parentClass.label)-\(present ? "present" : "absent")")
                var expectation: SaveDBPlayerRowExpectation = .absent
                if present {
                    database.putPlayer(parentClass.candidate, ["revision": 1])
                    expectation = .present(try XCTUnwrap(
                        database.getPlayerChecked(parentClass.candidate)).canonicalDigest)
                }
                try raw(url, """
                    DROP TABLE worlds;
                    CREATE TABLE worlds(id, json, lastPlayed);
                    INSERT INTO worlds(id,json,lastPlayed)
                    VALUES(\(parentClass.expression),'{}',0.0);
                    """)
                XCTAssertThrowsError(try database.compareAndSwapPlayerChecked(
                    parentClass.candidate, expected: expectation,
                    candidate: ["revision": 2]), "\(parentClass.label)-\(present)") {
                        XCTAssertEqual($0 as? SaveDBPlayerRowError, .conflict)
                }
            }
        }
    }

    func testCompatibilityWriterBeforeFacadeForcesConflict() throws {
        let (database, _) = try fixture("writer-before")
        database.putPlayer("world", ["revision": 1])
        let old = try XCTUnwrap(database.getPlayerChecked("world"))
        let barrier = database._testArmPlayerCASBarrier(.beforeFacade)
        let done = expectation(description: "CAS finished")
        let lock = NSLock()
        var result: Result<SaveDBPlayerRowSnapshot, Error>?
        DispatchQueue.global().async {
            let value = Result {
                try database.compareAndSwapPlayerChecked(
                    "world", expected: .present(old.canonicalDigest),
                    candidate: ["revision": 2])
            }
            lock.lock(); result = value; lock.unlock(); done.fulfill()
        }
        XCTAssertTrue(barrier.waitUntilReached())
        database.putPlayer("world", ["revision": 3])
        barrier.resume()
        wait(for: [done], timeout: 5)
        lock.lock(); let finalResult = result; lock.unlock()
        XCTAssertThrowsError(try finalResult!.get()) {
            XCTAssertEqual($0 as? SaveDBPlayerRowError, .conflict)
        }
        XCTAssertEqual(database.getPlayer("world")?["revision"] as? Int, 3)
    }

    func testCompatibilityWriterBeforeFacadeForAbsentForcesConflict() throws {
        let (database, _) = try fixture("writer-before-absent")
        let barrier = database._testArmPlayerCASBarrier(.beforeFacade)
        let done = expectation(description: "absent CAS finished")
        let lock = NSLock()
        var result: Result<SaveDBPlayerRowSnapshot, Error>?
        DispatchQueue.global().async {
            let value = Result {
                try database.compareAndSwapPlayerChecked(
                    "world", expected: .absent, candidate: ["revision": 2])
            }
            lock.lock(); result = value; lock.unlock(); done.fulfill()
        }
        XCTAssertTrue(barrier.waitUntilReached())
        database.putPlayer("world", ["revision": 3])
        barrier.resume()
        wait(for: [done], timeout: 5)
        lock.lock(); let finalResult = result; lock.unlock()
        XCTAssertThrowsError(try finalResult!.get()) {
            XCTAssertEqual($0 as? SaveDBPlayerRowError, .conflict)
        }
        XCTAssertEqual(database.getPlayer("world")?["revision"] as? Int, 3)
    }

    func testWriterAfterCommitRemainsFinalDurableRow() throws {
        let (database, _) = try fixture("writer-after")
        database.putPlayer("world", ["revision": 1])
        let old = try XCTUnwrap(database.getPlayerChecked("world"))
        let barrier = database._testArmPlayerCASBarrier(.afterCommit)
        let done = expectation(description: "CAS finished")
        let lock = NSLock()
        var result: Result<SaveDBPlayerRowSnapshot, Error>?
        DispatchQueue.global().async {
            let value = Result {
                try database.compareAndSwapPlayerChecked(
                    "world", expected: .present(old.canonicalDigest),
                    candidate: ["revision": 2])
            }
            lock.lock(); result = value; lock.unlock(); done.fulfill()
        }
        XCTAssertTrue(barrier.waitUntilReached())
        database.putPlayer("world", ["revision": 3])
        barrier.resume()
        wait(for: [done], timeout: 5)
        lock.lock(); let committed = try result!.get(); lock.unlock()
        XCTAssertEqual(committed.data["revision"] as? Int, 2)
        XCTAssertEqual(database.getPlayer("world")?["revision"] as? Int, 3)
    }

    func testWriterAfterAbsentCommitRemainsFinalDurableRow() throws {
        let (database, _) = try fixture("writer-after-absent")
        let barrier = database._testArmPlayerCASBarrier(.afterCommit)
        let done = expectation(description: "absent CAS finished")
        let lock = NSLock()
        var result: Result<SaveDBPlayerRowSnapshot, Error>?
        DispatchQueue.global().async {
            let value = Result {
                try database.compareAndSwapPlayerChecked(
                    "world", expected: .absent, candidate: ["revision": 2])
            }
            lock.lock(); result = value; lock.unlock(); done.fulfill()
        }
        XCTAssertTrue(barrier.waitUntilReached())
        database.putPlayer("world", ["revision": 3])
        barrier.resume()
        wait(for: [done], timeout: 5)
        lock.lock(); let committed = try result!.get(); lock.unlock()
        XCTAssertEqual(committed.data["revision"] as? Int, 2)
        XCTAssertEqual(database.getPlayer("world")?["revision"] as? Int, 3)
    }

    func testWorldDeleteAtBothCASBarriersForAbsentAndPresent() throws {
        let barrierCases: [(label: String, stage: SaveDBPlayerCASBarrierStage, commits: Bool)] = [
            ("before", .beforeFacade, false),
            ("after", .afterCommit, true),
        ]
        for barrierCase in barrierCases {
            for present in [false, true] {
                let (database, _) = try fixture(
                    "delete-\(barrierCase.label)-\(present ? "present" : "absent")")
                let expected: SaveDBPlayerRowExpectation
                if present {
                    database.putPlayer("world", ["revision": 1])
                    expected = .present(try XCTUnwrap(
                        database.getPlayerChecked("world")).canonicalDigest)
                } else {
                    expected = .absent
                }
                let barrier = database._testArmPlayerCASBarrier(barrierCase.stage)
                let done = expectation(description: "CAS \(barrierCase.label)-\(present)")
                let lock = NSLock()
                var result: Result<SaveDBPlayerRowSnapshot, Error>?
                DispatchQueue.global().async {
                    let value = Result {
                        try database.compareAndSwapPlayerChecked(
                            "world", expected: expected, candidate: ["revision": 2])
                    }
                    lock.lock(); result = value; lock.unlock(); done.fulfill()
                }
                XCTAssertTrue(barrier.waitUntilReached())
                database.deleteWorld("world")
                barrier.resume()
                wait(for: [done], timeout: 5)
                lock.lock(); let finalResult = result; lock.unlock()
                if barrierCase.commits {
                    XCTAssertEqual(try finalResult!.get().data["revision"] as? Int, 2)
                } else {
                    XCTAssertThrowsError(try finalResult!.get()) {
                        XCTAssertEqual($0 as? SaveDBPlayerRowError, .conflict)
                    }
                }
                XCTAssertNil(database.getWorld("world"))
                XCTAssertNil(database.getPlayer("world"))
            }
        }
    }

    func testEveryStorageOperationFaultRestartsToExactOldState() throws {
        let operations: [PebbleStorageOperationID] = [
            .beginImmediate, .prepare, .bind, .step, .changes, .finalize, .commit,
        ]
        for operation in operations {
            for present in [false, true] {
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "PebblePlayerCASFault-\(operation.rawValue)-\(present)-\(UUID().uuidString)")
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("pebble.db")
                let coordinator = try PebbleStorageCoordinator.open(databaseURL: url)
                let storage = try coordinator.legacyCore()
                try storage.putWorldRow(try PebbleWorldStorageRow(
                    id: "world", json: "{}", lastPlayed: 0))
                let oldRow = try PebblePlayerJSONStorageRow(
                    world: "world", json: #"{"v":0}"#)
                let expectation: PebblePlayerJSONExpectedRowState
                if present {
                    try storage.putPlayerJSON(oldRow)
                    expectation = .present(try PebblePlayerJSONRowDigest(
                        data: exactDigest(world: oldRow.world, json: oldRow.json)))
                } else {
                    expectation = .absent
                }
                try coordinator._testInject(operation)
                let candidate = try PebblePlayerJSONStorageRow(
                    world: "world", json: #"{"v":1}"#)
                XCTAssertThrowsError(try storage.compareAndSwapPlayerJSON(
                    expected: expectation, candidate: candidate),
                    "\(operation.rawValue)-\(present)")
                XCTAssertNoThrow(try coordinator.close())

                let reopened = try PebbleStorageCoordinator.open(databaseURL: url)
                let reopenedStorage = try reopened.legacyCore()
                XCTAssertEqual(try reopenedStorage.getPlayerJSON(world: "world"),
                               present ? oldRow : nil,
                               "\(operation.rawValue)-\(present)")
                XCTAssertNoThrow(try reopened.close())
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    func testHostileTriggerCannotWidenCASScope() throws {
        let (database, url) = try fixture("trigger")
        try raw(url, """
            CREATE TRIGGER hostile_player_insert AFTER INSERT ON player
            BEGIN UPDATE worlds SET json='hostile' WHERE id=NEW.world; END
            """)
        XCTAssertThrowsError(try database.compareAndSwapPlayerChecked(
            "world", expected: .absent, candidate: ["revision": 1])) {
                XCTAssertEqual($0 as? SaveDBPlayerRowError, .persistenceFailed)
        }
        XCTAssertNil(database.getPlayer("world"))
    }

    func testCompatibilityPutPlayerPreservesRank11To12Ordering() throws {
        let (database, _) = try fixture("rank-eleven")
        XCTAssertEqual(pebbleCurrentLockRank(), 0)
        withPebbleLockRank(.saveQueue) {
            XCTAssertEqual(pebbleCurrentLockRank(), PebbleLockRank.saveQueue.rawValue)
            database.putPlayer("world", ["revision": 1])
            XCTAssertEqual(pebbleCurrentLockRank(), PebbleLockRank.saveQueue.rawValue)
        }
        XCTAssertEqual(pebbleCurrentLockRank(), 0)
        XCTAssertEqual(database.getPlayer("world")?["revision"] as? Int, 1)
    }

    func testRankProbeClosedDatabaseAndErrorsAreRedacted() throws {
        let (database, _) = try fixture("rank")
        _ = try database.compareAndSwapPlayerChecked(
            "world", expected: .absent, candidate: ["revision": 1])
        XCTAssertEqual(database._testPlayerCASRanks(), [0, 0, 12, 0])
        try database.close()
        XCTAssertThrowsError(try database.compareAndSwapPlayerChecked(
            "world", expected: .present(try SaveDBPlayerRowDigest(data: Data(repeating: 1, count: 32))),
            candidate: ["secret": "/tmp/private.sqlite UPDATE player"])) {
                XCTAssertEqual($0 as? SaveDBPlayerRowError, .persistenceFailed)
                let description = String(describing: $0)
                XCTAssertFalse(description.contains("private.sqlite"))
                XCTAssertFalse(description.contains("UPDATE player"))
        }
    }
}
