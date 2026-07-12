import Foundation
import Darwin
import XCTest
@testable import PebbleCore

final class LegacySaveMigrationAdversarialTests: XCTestCase {
    func testNegativeDeviceUsesFrozenZeroExtendedRawBitPattern() {
        let positive: dev_t = 0x07ff
        let negative = dev_t(bitPattern: 0xb00007ff)
        let encoded = legacyDeviceBitPatternForTesting(negative)
        XCTAssertEqual(legacyDeviceBitPatternForTesting(positive), UInt64(positive))
        XCTAssertEqual(encoded, 0x00000000b00007ff)
        XCTAssertNotEqual(encoded, UInt64(bitPattern: Int64(negative)))
        XCTAssertNotEqual(encoded, UInt64(UInt32.max) + 1)
        XCTAssertNotEqual(encoded, UInt64.max)
    }

    private func makeRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pebble-migration-adversarial-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func entityOnlyVCK(_ tail: Data) -> Data {
        var data = Data("VCK1".utf8)
        data.append(0)
        var length = UInt32(tail.count).littleEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(tail)
        return data
    }

    private func writeWorld(_ id: String, under source: URL) throws {
        let worlds = source.appendingPathComponent("worlds", isDirectory: true)
        try FileManager.default.createDirectory(at: worlds, withIntermediateDirectories: true)
        let world = WorldRecord(id: id, name: id, seed: 77, gameMode: 0, difficulty: 2)
        try JSONEncoder().encode(world).write(to: worlds.appendingPathComponent("\(id).json"))
    }

    func testCanonicalChunkParserBoundariesAliasesAndJSONStringCaps() {
        let accepted = [
            "-2147483648_-2147483648_-2147483648.vck",
            "2147483647_2147483647_2147483647.vck", "0_0_0.vck", "-1_1_2.vck",
        ]
        accepted.forEach { XCTAssertNotNil(LegacySaveMigration._testParseChunkName($0), $0) }
        let rejected = [
            "2147483648_0_0.vck", "-2147483649_0_0.vck", "+1_0_0.vck",
            "00_0_0.vck", "-0_0_0.vck", "١_0_0.vck", "0_0_0.VCK",
            "0_0_0.vck\u{0}", "0__0.vck", "0_0_0_0.vck",
            String(decoding: [0xff, 0x5f, 0x30, 0x5f, 0x30, 0x2e, 0x76, 0x63, 0x6b], as: UTF8.self),
        ]
        rejected.forEach { XCTAssertNil(LegacySaveMigration._testParseChunkName($0), $0) }

        for delta in [-1, 0, 1] {
            let count = 1_048_576 + delta
            let value = Data(([UInt8(ascii: "\"")] + [UInt8](repeating: 0x61, count: count)
                + [UInt8(ascii: "\"")]))
            XCTAssertEqual(legacyMigrationJSONBudget(value) != nil, delta <= 0, "delta=\(delta)")
        }
    }

    func testWorldParserFileCapMinusOneExactAndPlusOne() throws {
        let cap = 1_048_576
        for delta in [-1, 0, 1] {
            let root = try makeRoot("world-cap-\(delta)")
            let source = root.appendingPathComponent("saves", isDirectory: true)
            let worlds = source.appendingPathComponent("worlds", isDirectory: true)
            try FileManager.default.createDirectory(at: worlds, withIntermediateDirectories: true)
            let base = try JSONEncoder().encode(WorldRecord(
                id: "w", name: "W", seed: 1, gameMode: 0, difficulty: 2))
            var bytes = Data(base.dropLast())
            let target = cap + delta
            bytes.append(Data(",\"padding\":\"".utf8))
            bytes.append(Data(repeating: 0x61, count: target - bytes.count - 2))
            bytes.append(Data("\"}".utf8))
            XCTAssertEqual(bytes.count, target)
            try bytes.write(to: worlds.appendingPathComponent("w.json"))
            if delta <= 0 {
                let database = try SaveDB.open(
                    databaseURL: root.appendingPathComponent("pebble.db"), migrateLegacy: true)
                XCTAssertEqual(database.getWorld("w")?.id, "w")
                try database.close()
            } else {
                XCTAssertThrowsError(try SaveDB.open(
                    databaseURL: root.appendingPathComponent("pebble.db"), migrateLegacy: true)) {
                    XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .limitExceeded)
                }
            }
        }
    }

    func testManifestFingerprintTracksOrderingDigestIdentityAndChunkBoundaries() throws {
        let root = try makeRoot("fingerprint")
        let empty = try LegacySaveMigration._testManifestProbe(rootURL: root)
        XCTAssertEqual(empty.paths, [])
        XCTAssertEqual(empty.sourceBytes, 0)

        let file = root.appendingPathComponent("b.bin")
        try Data(repeating: 0x41, count: 65_536).write(to: file)
        let one = try LegacySaveMigration._testManifestProbe(rootURL: root)
        XCTAssertEqual(one.paths, [Data("b.bin".utf8)])
        XCTAssertEqual(one.sourceBytes, 65_536)
        XCTAssertGreaterThan(one.residentCharge, 0)
        XCTAssertNotEqual(one.root, empty.root)

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let modification = try XCTUnwrap(attributes[.modificationDate] as? Date)
        try Data(repeating: 0x42, count: 65_536).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modification], ofItemAtPath: file.path)
        let sameSizeRestoredTime = try LegacySaveMigration._testManifestProbe(rootURL: root)
        XCTAssertNotEqual(sameSizeRestoredTime.root, one.root)

        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0x41, count: 65_536).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modification], ofItemAtPath: file.path)
        let replaced = try LegacySaveMigration._testManifestProbe(rootURL: root)
        XCTAssertNotEqual(replaced.root, one.root)

        try Data([0x41]).write(to: root.appendingPathComponent("a.bin"))
        let ordered = try LegacySaveMigration._testManifestProbe(rootURL: root)
        XCTAssertEqual(ordered.paths, [Data("a.bin".utf8), Data("b.bin".utf8)])
        XCTAssertEqual(ordered.sourceBytes, 65_537)
        XCTAssertNotEqual(ordered.root, replaced.root)
    }

    func testManifestRejectsHardlinksAndDeterministicTruncateGrowReplaceRaces() throws {
        do {
            let root = try makeRoot("hardlink")
            let original = root.appendingPathComponent("original")
            try Data("linked".utf8).write(to: original)
            try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("alias"))
            XCTAssertThrowsError(try LegacySaveMigration._testManifestProbe(rootURL: root)) {
                XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .invalidSource)
            }
        }
        for mutation in LegacyMigrationTestHashMutation.allCases {
            let root = try makeRoot("hash-race-\(mutation)")
            try Data(repeating: 0x5a, count: 131_072).write(
                to: root.appendingPathComponent("payload"))
            LegacySaveMigration._testArmHashMutation(mutation)
            XCTAssertThrowsError(try LegacySaveMigration._testManifestProbe(rootURL: root),
                                 "\(mutation)")
        }
    }

    func testSeededFilenameWorldPlayerAdvancementAndVCKTailFuzzIsBounded() {
        var state: UInt64 = 0x4d49_4752_4154_4532
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return state
        }
        var acceptedNames = 0
        var acceptedWorlds = 0
        var acceptedPlayers = 0
        var acceptedAdvancements = 0
        var acceptedVCK = 0
        for index in 0..<2_000 {
            let count = Int(next() % 96)
            let bytes = (0..<count).map { _ in UInt8(truncatingIfNeeded: next() >> 24) }
            let text = String(decoding: bytes, as: UTF8.self)
            if LegacySaveMigration._testParseChunkName(text) != nil { acceptedNames += 1 }
            let data = Data(bytes)
            if LegacySaveMigration._testJSONShape(data, shape: .world) { acceptedWorlds += 1 }
            if LegacySaveMigration._testJSONShape(data, shape: .player) { acceptedPlayers += 1 }
            if LegacySaveMigration._testJSONShape(data, shape: .advancements) {
                acceptedAdvancements += 1
            }
            if LegacySaveMigration._testValidateLegacyVCK(entityOnlyVCK(data), dimension: 0) {
                acceptedVCK += 1
            }
            if index % 257 == 0 {
                XCTAssertTrue(LegacySaveMigration._testValidateLegacyVCK(
                    entityOnlyVCK(Data(#"{"entities":[]}"#.utf8)), dimension: 0))
            }
        }
        XCTAssertEqual([acceptedNames, acceptedWorlds, acceptedPlayers,
                        acceptedAdvancements, acceptedVCK], [0, 0, 0, 0, 0],
                       "seed=0x4d49475241544532")
    }

    func testFreshRegistrySubprocessAndTwoDatabaseAliasLeaseRace() throws {
        if let path = ProcessInfo.processInfo.environment["PEBBLE_EMPTY_REGISTRY_CHILD"] {
            let database = try SaveDB.open(
                databaseURL: URL(fileURLWithPath: path), migrateLegacy: true)
            try database.close()
            return
        }
        let childRoot = try makeRoot("empty-registry")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let testName = "PebbleCoreTests.LegacySaveMigrationAdversarialTests/testFreshRegistrySubprocessAndTwoDatabaseAliasLeaseRace"
        if let bundle = CommandLine.arguments.last, bundle.hasSuffix(".xctest") {
            child.arguments = ["-XCTest", testName, bundle]
        } else {
            child.arguments = [testName]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PEBBLE_EMPTY_REGISTRY_CHILD"] = childRoot.appendingPathComponent("pebble.db").path
        child.environment = environment
        let childOutput = Pipe()
        let childErrors = Pipe()
        child.standardOutput = childOutput
        child.standardError = childErrors
        try child.run()
        child.waitUntilExit()
        let diagnostics = String(decoding: childErrors.fileHandleForReading.readDataToEndOfFile(),
                                 as: UTF8.self)
        XCTAssertEqual(child.terminationStatus, 0, diagnostics)

        let root = try makeRoot("two-database")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("saves", isDirectory: true),
            withIntermediateDirectories: true)
        let held = try LegacySaveMigration.preflight(
            databaseURL: root.appendingPathComponent("one.db"))
        XCTAssertThrowsError(try LegacySaveMigration.preflight(
            databaseURL: root.appendingPathComponent("two.db"))) {
            XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .conflict)
        }
        let aliasDirectory = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: aliasDirectory, withDestinationURL: root)
        XCTAssertThrowsError(try LegacySaveMigration.preflight(
            databaseURL: aliasDirectory.appendingPathComponent("three.db"))) {
            XCTAssertEqual(($0 as? SaveDBOpenError)?.result, .conflict)
        }
        withExtendedLifetime(held) {}
    }

    func testEveryFixedDirectoryRejectsFIFOAndUnixSocketWithoutBlocking() throws {
        for directory in ["worlds", "player", "advancements", "chunks"] {
            for kind in ["fifo", "socket"] {
                let root = URL(fileURLWithPath: "/tmp/pbsp-\(getpid())-\(directory)-\(kind)",
                               isDirectory: true)
                try? FileManager.default.removeItem(at: root)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let source = root.appendingPathComponent("saves", isDirectory: true)
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                let path = source.appendingPathComponent(directory).path
                var listener: Process?
                if kind == "fifo" {
                    XCTAssertEqual(mkfifo(path, S_IRUSR | S_IWUSR), 0)
                } else {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
                    process.arguments = ["-lU", path]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    listener = process
                    let deadline = Date().addingTimeInterval(2)
                    while !FileManager.default.fileExists(atPath: path), Date() < deadline {
                        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
                    }
                    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
                }
                defer { listener?.terminate(); listener?.waitUntilExit() }
                let start = Date()
                XCTAssertThrowsError(try SaveDB.open(
                    databaseURL: root.appendingPathComponent("pebble.db"), migrateLegacy: true))
                XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
            }
        }
    }

    func testImportBarrierRenameSyncReopenAndMarkerFailureRetryMatrix() throws {
        let retryableSourceCuts: [LegacyMigrationTestCut] = [
            .beforeImport, .beforeBarrier, .beforeRename, .failParentSync,
        ]
        for cut in retryableSourceCuts {
            let root = try makeRoot("throw-cut-\(cut.rawValue)")
            let source = root.appendingPathComponent("saves", isDirectory: true)
            try writeWorld("cut", under: source)
            let databaseURL = root.appendingPathComponent("pebble.db")
            LegacySaveMigration._testArmCut(cut)
            XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true),
                                 cut.rawValue)
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), cut.rawValue)
            let retried = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)
            XCTAssertEqual(retried.getWorld("cut")?.id, "cut", cut.rawValue)
            try retried.close()
        }

        for cut in [LegacyMigrationTestCut.afterRenameBeforeSync, .afterParentSync,
                    .beforeReopen, .afterReopenBeforeMarker] {
            let root = try makeRoot("backup-cut-\(cut.rawValue)")
            let source = root.appendingPathComponent("saves", isDirectory: true)
            try writeWorld("cut", under: source)
            let databaseURL = root.appendingPathComponent("pebble.db")
            LegacySaveMigration._testArmCut(cut)
            XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true),
                                 cut.rawValue)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: root.appendingPathComponent("saves-legacy-backup").path), cut.rawValue)
            XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)) {
                XCTAssertEqual($0 as? SaveDBOpenError,
                               SaveDBOpenError(stage: .legacyBackupRecoveryRequired,
                                               result: .conflict), cut.rawValue)
            }
        }
    }

    func testRealProcessRestartCutsBeforeAndAfterBarrierRenameAndParentSync() throws {
        if let rootPath = ProcessInfo.processInfo.environment["PEBBLE_RESTART_CUT_ROOT"],
           let rawCut = ProcessInfo.processInfo.environment["PEBBLE_RESTART_CUT"],
           let cut = LegacyMigrationTestCut(rawValue: rawCut) {
            LegacySaveMigration._testArmCut(cut, crash: true)
            _ = try SaveDB.open(databaseURL: URL(fileURLWithPath: rootPath)
                .appendingPathComponent("pebble.db"), migrateLegacy: true)
            return XCTFail("cut did not terminate process")
        }
        let cuts: [LegacyMigrationTestCut] = [
            .beforeBarrier, .beforeRename, .afterRenameBeforeSync, .afterParentSync,
        ]
        for cut in cuts {
            let root = try makeRoot("restart-cut-\(cut.rawValue)")
            try writeWorld("restart", under: root.appendingPathComponent("saves"))
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            let testName = "PebbleCoreTests.LegacySaveMigrationAdversarialTests/testRealProcessRestartCutsBeforeAndAfterBarrierRenameAndParentSync"
            if let bundle = CommandLine.arguments.last, bundle.hasSuffix(".xctest") {
                child.arguments = ["-XCTest", testName, bundle]
            } else {
                child.arguments = [testName]
            }
            var environment = ProcessInfo.processInfo.environment
            environment["PEBBLE_RESTART_CUT_ROOT"] = root.path
            environment["PEBBLE_RESTART_CUT"] = cut.rawValue
            child.environment = environment
            let output = Pipe()
            let errors = Pipe()
            child.standardOutput = output
            child.standardError = errors
            try child.run()
            child.waitUntilExit()
            XCTAssertEqual(child.terminationStatus, 86, cut.rawValue)

            let databaseURL = root.appendingPathComponent("pebble.db")
            if cut == .beforeBarrier || cut == .beforeRename {
                let restarted = try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)
                XCTAssertEqual(restarted.getWorld("restart")?.id, "restart")
                try restarted.close()
            } else {
                XCTAssertThrowsError(try SaveDB.open(databaseURL: databaseURL, migrateLegacy: true)) {
                    XCTAssertEqual(($0 as? SaveDBOpenError)?.stage,
                                   .legacyBackupRecoveryRequired, cut.rawValue)
                }
            }
        }
    }
}
