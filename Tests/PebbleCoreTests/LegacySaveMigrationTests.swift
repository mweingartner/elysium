import Foundation
import Darwin
import XCTest
@testable import PebbleCore
@testable import PebbleStorage

final class LegacySaveMigrationTests: XCTestCase {
    private func makeParent(_ label: String) throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pebble-legacy-migration-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return parent
    }

    private func writeWorld(_ world: WorldRecord, under source: URL) throws {
        let worlds = source.appendingPathComponent("worlds", isDirectory: true)
        try FileManager.default.createDirectory(at: worlds, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(world)
        try data.write(to: worlds.appendingPathComponent("\(world.id).json"), options: .atomic)
    }

    private func makeRecoveryRestart(_ label: String) throws -> (URL, URL, URL) {
        let parent = try makeParent("recovery-restart-\(label)")
        let databaseURL = parent.appendingPathComponent("pebble.db")
        let initial = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false)
        try initial.close()
        let backup = parent.appendingPathComponent("saves-legacy-backup", isDirectory: true)
        try writeWorld(WorldRecord(id: "recovery", name: "Recovery", seed: 31,
                                   gameMode: 0, difficulty: 2), under: backup)
        XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)) {
            XCTAssertEqual($0 as? SaveDBOpenError,
                           SaveDBOpenError(stage: .legacyBackupRecoveryRequired,
                                           result: .conflict))
        }
        return (parent, databaseURL,
                parent.appendingPathComponent(".pebble-legacy-backup-recovery-required"))
    }

    private func makeProvenanceRestart(_ label: String) throws -> (URL, URL, URL) {
        let parent = try makeParent("provenance-restart-\(label)")
        let source = parent.appendingPathComponent("saves", isDirectory: true)
        try writeWorld(WorldRecord(id: "provenance", name: "Provenance", seed: 32,
                                   gameMode: 0, difficulty: 2), under: source)
        let databaseURL = parent.appendingPathComponent("pebble.db")
        let initial = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)
        try initial.close()
        return (parent, databaseURL,
                parent.appendingPathComponent(".pebble-legacy-migration-v2"))
    }

    func testSourceOnlyMigratesThroughBarrierRenameRestartAndProvenance() throws {
        let parent = try makeParent("success")
        let source = parent.appendingPathComponent("saves", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let world = WorldRecord(id: "world-one", name: "World One", seed: 123,
                                gameMode: GameMode.survival, difficulty: 2)
        try writeWorld(world, under: source)
        let databaseURL = parent.appendingPathComponent("pebble.db")

        let database = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)
        XCTAssertEqual(database.getWorld("world-one")?.name, "World One")
        try database.close()

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("saves-legacy-backup").path))
        let marker = parent.appendingPathComponent(".pebble-legacy-migration-v2")
        XCTAssertEqual(try Data(contentsOf: marker).count, 128)

        let reopened = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)
        XCTAssertEqual(reopened.getWorld("world-one")?.id, "world-one")
        try reopened.close()
    }

    func testUnmarkedBackupOnlyCreatesDurableRecoveryRecordBeforeOpen() throws {
        let parent = try makeParent("recovery")
        let databaseURL = parent.appendingPathComponent("pebble.db")
        let initial = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false)
        initial.putWorld(WorldRecord(id: "existing", name: "Existing", seed: 7,
                                     gameMode: 0, difficulty: 2))
        try initial.close()
        let before = try Data(contentsOf: databaseURL)

        let backup = parent.appendingPathComponent("saves-legacy-backup", isDirectory: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try writeWorld(WorldRecord(id: "old", name: "Old", seed: 8,
                                   gameMode: 0, difficulty: 2), under: backup)

        XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)) {
            XCTAssertEqual($0 as? SaveDBOpenError,
                           SaveDBOpenError(stage: .legacyBackupRecoveryRequired,
                                           result: .conflict))
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
        let recovery = parent.appendingPathComponent(
            ".pebble-legacy-backup-recovery-required")
        XCTAssertEqual(try Data(contentsOf: recovery).count, 80)

        XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)) {
            XCTAssertEqual($0 as? SaveDBOpenError,
                           SaveDBOpenError(stage: .legacyBackupRecoveryRequired,
                                           result: .conflict))
        }
    }

    func testWorldStemMismatchFailsBeforeDatabasePublication() throws {
        let parent = try makeParent("stem-mismatch")
        let source = parent.appendingPathComponent("saves", isDirectory: true)
        let worlds = source.appendingPathComponent("worlds", isDirectory: true)
        try FileManager.default.createDirectory(at: worlds, withIntermediateDirectories: true)
        let world = WorldRecord(id: "actual", name: "Actual", seed: 9,
                                gameMode: 0, difficulty: 2)
        try JSONEncoder().encode(world).write(to: worlds.appendingPathComponent("different.json"))

        XCTAssertThrowsError(try SaveDB.open(
            databaseURL: parent.appendingPathComponent("pebble.db"), migrateLegacy: true)) {
            XCTAssertEqual(($0 as? SaveDBOpenError)?.stage, .migrationManifest)
            XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .invalidSource)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testCanonicalChunkNameParserAndStructuralValidatorRejectMalformedInputs() throws {
        let parent = try makeParent("malformed-chunk")
        let source = parent.appendingPathComponent("saves", isDirectory: true)
        let world = WorldRecord(id: "chunks", name: "Chunks", seed: 10,
                                gameMode: 0, difficulty: 2)
        try writeWorld(world, under: source)
        let chunks = source.appendingPathComponent("chunks/chunks", isDirectory: true)
        try FileManager.default.createDirectory(at: chunks, withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: chunks.appendingPathComponent("0_0_0.vck"))

        let database = try SaveDB.open(
            databaseURL: parent.appendingPathComponent("pebble.db"), migrateLegacy: true)
        XCTAssertEqual(database.getChunkKeys("chunks"), [])
        try database.close()
    }

    func testWrongFixedDirectoryAndExactCandidateTypesFailClosed() throws {
        for variant in 0..<3 {
            let parent = try makeParent("wrong-type-\(variant)")
            let source = parent.appendingPathComponent("saves", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            switch variant {
            case 0:
                try Data("not a directory".utf8).write(to: source.appendingPathComponent("worlds"))
            case 1:
                let worlds = source.appendingPathComponent("worlds", isDirectory: true)
                try FileManager.default.createDirectory(at: worlds.appendingPathComponent("bad.json"),
                                                        withIntermediateDirectories: true)
            default:
                let world = WorldRecord(id: "typed", name: "Typed", seed: 1, gameMode: 0, difficulty: 2)
                try writeWorld(world, under: source)
                try FileManager.default.createDirectory(
                    at: source.appendingPathComponent("chunks/typed/0_0_0.vck"),
                    withIntermediateDirectories: true)
            }
            XCTAssertThrowsError(try SaveDB.open(
                databaseURL: parent.appendingPathComponent("pebble.db"), migrateLegacy: true)) {
                XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .invalidSource)
            }
        }
    }

    func testPlayerAndAdvancementWrongDomainShapesAreSkippedIndependently() throws {
        let parent = try makeParent("json-shapes")
        let source = parent.appendingPathComponent("saves", isDirectory: true)
        try writeWorld(WorldRecord(id: "shape", name: "Shape", seed: 2,
                                   gameMode: 0, difficulty: 2), under: source)
        let player = source.appendingPathComponent("player", isDirectory: true)
        let advancements = source.appendingPathComponent("advancements", isDirectory: true)
        try FileManager.default.createDirectory(at: player, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: advancements, withIntermediateDirectories: true)
        try Data("[]".utf8).write(to: player.appendingPathComponent("shape.json"))
        try Data("{}".utf8).write(to: advancements.appendingPathComponent("shape.json"))
        let database = try SaveDB.open(databaseURL: parent.appendingPathComponent("pebble.db"),
                                       migrateLegacy: true)
        XCTAssertNil(database.getPlayer("shape"))
        XCTAssertNil(database.getAdvancements("shape"))
        try database.close()
    }

    func testEveryProvenanceCountAndEquivalenceRegionCorruptionIsRejectedOnRestart() throws {
        for offset in [48, 56, 64, 95, 96, 127] {
            let parent = try makeParent("marker-\(offset)")
            let source = parent.appendingPathComponent("saves", isDirectory: true)
            try writeWorld(WorldRecord(id: "marker", name: "Marker", seed: 3,
                                       gameMode: 0, difficulty: 2), under: source)
            let databaseURL = parent.appendingPathComponent("pebble.db")
            let database = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)
            try database.close()
            let marker = parent.appendingPathComponent(".pebble-legacy-migration-v2")
            var bytes = try Data(contentsOf: marker)
            bytes[offset] ^= 0xff
            try bytes.write(to: marker)
            chmod(marker.path, S_IRUSR | S_IWUSR)
            XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)) {
                XCTAssertEqual(($0 as? SaveDBOpenError)?.stage, .migrationManifest)
                XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .invalidSource)
            }
        }
    }

    func testHeldLeaseRejectsNamedLockAndNamespaceReplacement() throws {
        let parent = try makeParent("lease-race")
        let source = parent.appendingPathComponent("saves", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let databaseURL = parent.appendingPathComponent("pebble.db")
        let preflight = try LegacySaveMigration.preflight(databaseURL: databaseURL)
        XCTAssertNoThrow(try LegacySaveMigration._testValidateLease(preflight))

        let displaced = parent.appendingPathComponent("displaced", isDirectory: true)
        try FileManager.default.moveItem(at: source, to: displaced)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        XCTAssertThrowsError(try LegacySaveMigration._testValidateLease(preflight)) {
            XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .conflict)
        }
    }

    func testSecondOwnerAndSpecialFileNamespaceFailWithoutBlocking() throws {
        let parent = try makeParent("lease-owner")
        let source = parent.appendingPathComponent("saves", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let databaseURL = parent.appendingPathComponent("pebble.db")
        let first = try LegacySaveMigration.preflight(databaseURL: databaseURL)
        XCTAssertThrowsError(try LegacySaveMigration.preflight(databaseURL: databaseURL)) {
            XCTAssertEqual(($0 as? SaveDBOpenError)?.stage, .migrationLease)
            XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .conflict)
        }
        withExtendedLifetime(first) {}

        let fifoParent = try makeParent("fifo")
        let fifoSource = fifoParent.appendingPathComponent("saves", isDirectory: true)
        try FileManager.default.createDirectory(at: fifoSource, withIntermediateDirectories: true)
        let fifoPath = fifoSource.appendingPathComponent("hostile.json").path
        XCTAssertEqual(mkfifo(fifoPath, S_IRUSR | S_IWUSR), 0)
        let start = Date()
        XCTAssertThrowsError(try SaveDB.open(
            databaseURL: fifoParent.appendingPathComponent("pebble.db"), migrateLegacy: true))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    func testSeededJSONBudgetFuzzIsDeterministicAndBounded() {
        var state: UInt64 = 0x5eed_cafe_f00d_beef
        var accepted = 0
        for _ in 0..<2_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let count = Int((state >> 56) & 0x7f)
            var bytes = [UInt8]()
            bytes.reserveCapacity(count)
            for _ in 0..<count {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: state >> 24))
            }
            if legacyMigrationJSONBudget(Data(bytes)) != nil { accepted += 1 }
        }
        XCTAssertEqual(accepted, 27, "seed=0x5eedcafef00dbeef")
        XCTAssertNotNil(legacyMigrationJSONBudget(Data(#"{"ok":["x",1,true,null]}"#.utf8)))
        XCTAssertNil(legacyMigrationJSONBudget(Data(repeating: UInt8(ascii: "["), count: 129)))
    }

    func testStaleMarkerTempsAndMarkerIdentityViolationsFailClosed() throws {
        for tempName in [".pebble-legacy-migration-v2.tmp",
                         ".pebble-legacy-backup-recovery-required.tmp"] {
            let parent = try makeParent("stale-temp-\(tempName.count)")
            try FileManager.default.createDirectory(
                at: parent.appendingPathComponent("saves", isDirectory: true),
                withIntermediateDirectories: true)
            let temp = parent.appendingPathComponent(tempName)
            try Data("stale".utf8).write(to: temp)
            chmod(temp.path, S_IRUSR | S_IWUSR)
            XCTAssertThrowsError(try SaveDB.open(
                databaseURL: parent.appendingPathComponent("pebble.db"), migrateLegacy: true)) {
                XCTAssertEqual(($0 as? SaveDBOpenError)?.stage, .migrationManifest)
            }
        }

        let parent = try makeParent("marker-hardlink")
        let source = parent.appendingPathComponent("saves", isDirectory: true)
        try writeWorld(WorldRecord(id: "linked", name: "Linked", seed: 9,
                                   gameMode: 0, difficulty: 2), under: source)
        let databaseURL = parent.appendingPathComponent("pebble.db")
        let database = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)
        try database.close()
        let marker = parent.appendingPathComponent(".pebble-legacy-migration-v2")
        try FileManager.default.linkItem(at: marker,
                                        to: parent.appendingPathComponent("marker-hardlink-copy"))
        XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)) {
            XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .invalidSource)
        }
    }

    func testRecoveryTemporaryRestartValidatesRemovesSyncsAndRecreates() throws {
        let (parent, databaseURL, marker) = try makeRecoveryRestart("valid")
        let temp = parent.appendingPathComponent(
            ".pebble-legacy-backup-recovery-required.tmp")
        try FileManager.default.moveItem(at: marker, to: temp)

        XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)) {
            XCTAssertEqual($0 as? SaveDBOpenError,
                           SaveDBOpenError(stage: .legacyBackupRecoveryRequired,
                                           result: .conflict))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertEqual(try Data(contentsOf: marker).count, 80)
    }

    func testRecoveryTemporaryRestartRejectsMalformedForeignAndMismatchedRecords() throws {
        for variant in ["malformed", "foreign", "mismatch"] {
            let (parent, databaseURL, marker) = try makeRecoveryRestart(variant)
            let temp = parent.appendingPathComponent(
                ".pebble-legacy-backup-recovery-required.tmp")
            switch variant {
            case "malformed":
                try FileManager.default.moveItem(at: marker, to: temp)
                try Data("short".utf8).write(to: temp)
            case "foreign":
                try FileManager.default.linkItem(at: marker,
                    to: parent.appendingPathComponent("recovery-foreign-link"))
                try FileManager.default.moveItem(at: marker, to: temp)
            default:
                try FileManager.default.moveItem(at: marker, to: temp)
                var bytes = try Data(contentsOf: temp)
                bytes[16] ^= 0xff
                try bytes.write(to: temp)
            }
            XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)) {
                XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .invalidSource, variant)
            }
        }
    }

    func testProvenanceTemporaryRestartNeverPromotesAndRecreatesAfterEquivalenceProof() throws {
        let (parent, databaseURL, marker) = try makeProvenanceRestart("valid")
        let temp = parent.appendingPathComponent(".pebble-legacy-migration-v2.tmp")
        try FileManager.default.moveItem(at: marker, to: temp)
        let retainedTempFD = Darwin.open(temp.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(retainedTempFD, 0)
        defer { if retainedTempFD >= 0 { Darwin.close(retainedTempFD) } }
        var originalInfo = stat()
        XCTAssertEqual(fstat(retainedTempFD, &originalInfo), 0)

        let reopened = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)
        XCTAssertEqual(reopened.getWorld("provenance")?.name, "Provenance")
        try reopened.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
        XCTAssertEqual(try Data(contentsOf: marker).count, 128)
        var replacementInfo = stat()
        XCTAssertEqual(lstat(marker.path, &replacementInfo), 0)
        XCTAssertNotEqual(originalInfo.st_ino, replacementInfo.st_ino)
    }

    func testProvenanceTemporaryRestartRejectsMalformedForeignAndMismatchedRecords() throws {
        for variant in ["malformed", "foreign", "mismatch"] {
            let (parent, databaseURL, marker) = try makeProvenanceRestart(variant)
            let temp = parent.appendingPathComponent(".pebble-legacy-migration-v2.tmp")
            switch variant {
            case "malformed":
                try FileManager.default.moveItem(at: marker, to: temp)
                try Data("short".utf8).write(to: temp)
            case "foreign":
                try FileManager.default.linkItem(at: marker,
                    to: parent.appendingPathComponent("provenance-foreign-link"))
                try FileManager.default.moveItem(at: marker, to: temp)
            default:
                try FileManager.default.moveItem(at: marker, to: temp)
                var bytes = try Data(contentsOf: temp)
                bytes[96] ^= 0xff
                try bytes.write(to: temp)
            }
            XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)) {
                XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .invalidSource, variant)
            }
        }
    }

    func testCleanupMappingPreservesStageAndCloseFailureTombstonesLease() throws {
        let parent = try makeParent("cleanup-mapping")
        let databaseURL = parent.appendingPathComponent("pebble.db")
        let coordinator = try PebbleStorageCoordinator.open(databaseURL: databaseURL)
        try coordinator._testInject(.close, count: 2)
        let primary = SaveDBOpenError(stage: .migrationImport, result: .conflict)
        XCTAssertEqual(LegacySaveMigration._testCleanupMappedError(
            coordinator: coordinator, primary: primary),
            SaveDBOpenError(stage: .migrationImport, result: .cleanupFailed))
        XCTAssertThrowsError(try PebbleStorageCoordinator.open(databaseURL: databaseURL)) {
            XCTAssertEqual($0 as? PebbleStorageError, .duplicateOpen)
        }
    }
}
