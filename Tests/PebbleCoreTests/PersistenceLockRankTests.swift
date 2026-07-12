import XCTest
@testable import PebbleCore

final class PersistenceLockRankTests: XCTestCase {
    func testSupportedRankTransitionsRestoreExactPriorRank() {
        XCTAssertEqual(pebbleCurrentLockRank(), 0)
        let direct = withPebbleLockRank(.saveDB) { pebbleCurrentLockRank() }
        XCTAssertEqual(direct, PebbleLockRank.saveDB.rawValue)
        XCTAssertEqual(pebbleCurrentLockRank(), 0)

        let migration = withPebbleLockRank(.migrationSource) {
            XCTAssertEqual(pebbleCurrentLockRank(), PebbleLockRank.migrationSource.rawValue)
            return withPebbleLockRank(.saveDB) { pebbleCurrentLockRank() }
        }
        XCTAssertEqual(migration, PebbleLockRank.saveDB.rawValue)

        let save = withPebbleLockRank(.saveQueue) {
            withPebbleLockRank(.saveDB) { pebbleCurrentLockRank() }
        }
        XCTAssertEqual(save, PebbleLockRank.saveDB.rawValue)
        XCTAssertEqual(pebbleCurrentLockRank(), 0)
    }

    func testSaveQueueSelfEntryRunsInlineWithoutDeadlock() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "rank-self-entry")
        XCTAssertEqual(game._testSaveQueueSelfEntry(), PebbleLockRank.saveQueue.rawValue)
    }

    func testLedgerProbeExactCapAndOverflow() {
        XCTAssertEqual(LegacyMigrationLedgerProbe.checkedCharge(
            current: LegacyMigrationLedgerProbe.residentCap - 1, amount: 1),
            LegacyMigrationLedgerProbe.residentCap)
        XCTAssertNil(LegacyMigrationLedgerProbe.checkedCharge(
            current: LegacyMigrationLedgerProbe.residentCap, amount: 1))
        XCTAssertNil(LegacyMigrationLedgerProbe.checkedCharge(current: UInt64.max, amount: 1))
        XCTAssertEqual(LegacyMigrationLedgerProbe.manifestCharge(filenameBytes: 10), 266)
        XCTAssertEqual(LegacyMigrationLedgerProbe.ownedBufferCharge(length: 1), 80)
        let lifecycle = LegacySaveMigration._testResidentReservationLifecycle(
            initial: LegacyMigrationLedgerProbe.residentCap - 80, amount: 80)
        XCTAssertEqual(lifecycle?.before, LegacyMigrationLedgerProbe.residentCap - 80)
        XCTAssertEqual(lifecycle?.during, LegacyMigrationLedgerProbe.residentCap)
        XCTAssertEqual(lifecycle?.after, LegacyMigrationLedgerProbe.residentCap - 80)
        XCTAssertNil(LegacySaveMigration._testResidentReservationLifecycle(
            initial: LegacyMigrationLedgerProbe.residentCap, amount: 1))
        XCTAssertTrue(LegacySaveMigration._testGlobalChunkCandidateCountAllowed(1_048_576))
        XCTAssertFalse(LegacySaveMigration._testGlobalChunkCandidateCountAllowed(1_048_577))
    }

    func testDiscoveryProductionLedgerAcceptsExactPeakAndRejectsOneByteOver() throws {
        let input = Data(#"{"id":"a","name":"A","seed":1,"gameMode":0,"difficulty":2}"#.utf8)
        let required = try XCTUnwrap(LegacySaveMigration._testDiscoveryReservationPeak(
            initial: 0, input: input, stem: "a", filename: "a.json"))
        XCTAssertLessThan(required, LegacyMigrationLedgerProbe.residentCap)
        let exactInitial = LegacyMigrationLedgerProbe.residentCap - required
        XCTAssertEqual(LegacySaveMigration._testDiscoveryReservationPeak(
            initial: exactInitial, input: input, stem: "a", filename: "a.json"),
            LegacyMigrationLedgerProbe.residentCap)
        XCTAssertNil(LegacySaveMigration._testDiscoveryReservationPeak(
            initial: exactInitial + 1, input: input, stem: "a", filename: "a.json"))
    }

    func testForwardReverseAndMarkerRollbackBoundariesUseCapturedIdentityAndSyncState() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pebble-rename-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let expectedURL = parent.appendingPathComponent("expected")
        let foreignURL = parent.appendingPathComponent("foreign")
        try Data("expected".utf8).write(to: expectedURL)
        try Data("foreign".utf8).write(to: foreignURL)

        for branch in LegacyMigrationTestRenameBranch.allCases {
            for state in LegacyMigrationTestRenameState.allCases {
                for returnedSuccess in [false, true] {
                    for syncSucceeded in [false, true] {
                        let identityAtSuccessLocation: Bool
                        switch branch {
                        case .forwardSource: identityAtSuccessLocation = state == .destination
                        case .reverseSource, .markerRollback: identityAtSuccessLocation = state == .source
                        }
                        let expected = identityAtSuccessLocation && syncSucceeded
                        XCTAssertEqual(try LegacySaveMigration._testInjectRenameBoundary(
                            branch: branch, state: state,
                            returnedSuccess: returnedSuccess,
                            syncSucceeded: syncSucceeded,
                            expectedURL: expectedURL, foreignURL: foreignURL),
                            expected,
                            "branch=\(branch) state=\(state) return=\(returnedSuccess) sync=\(syncSucceeded)")
                    }
                }
            }
        }
    }

    func testStreamingUTF8ValidatorAcceptsScalarBoundariesAndRejectsMalformedForms() {
        let valid: [[UInt8]] = [
            [0x00], [0x7f], [0xc2, 0x80], [0xdf, 0xbf],
            [0xe0, 0xa0, 0x80], [0xed, 0x9f, 0xbf], [0xee, 0x80, 0x80],
            [0xf0, 0x90, 0x80, 0x80], [0xf4, 0x8f, 0xbf, 0xbf],
        ]
        let invalid: [[UInt8]] = [
            [0x80], [0xc0, 0x80], [0xc2], [0xe0, 0x9f, 0x80],
            [0xed, 0xa0, 0x80], [0xf0, 0x8f, 0x80, 0x80],
            [0xf4, 0x90, 0x80, 0x80], [0xf5, 0x80, 0x80, 0x80],
        ]
        valid.forEach { XCTAssertTrue(LegacySaveMigration._testStreamingUTF8Valid(Data($0)), "\($0)") }
        invalid.forEach { XCTAssertFalse(LegacySaveMigration._testStreamingUTF8Valid(Data($0)), "\($0)") }
    }

    func testRankInversionsTrapInIsolatedSubprocesses() {
        if let scenario = ProcessInfo.processInfo.environment["PEBBLE_RANK_TRAP_SCENARIO"] {
            switch scenario {
            case "12to11": withPebbleLockRank(.saveDB) { withPebbleLockRank(.saveQueue) {} }
            case "12to12": withPebbleLockRank(.saveDB) { withPebbleLockRank(.saveDB) {} }
            case "20to12": withPebbleLockRank(.publication) { withPebbleLockRank(.saveDB) {} }
            default: XCTFail("unknown child scenario")
            }
            return XCTFail("rank inversion did not trap")
        }
        for scenario in ["12to11", "12to12", "20to12"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = ["PebbleCoreTests.PersistenceLockRankTests/testRankInversionsTrapInIsolatedSubprocesses"]
            var environment = ProcessInfo.processInfo.environment
            environment["PEBBLE_RANK_TRAP_SCENARIO"] = scenario
            child.environment = environment
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            XCTAssertNoThrow(try child.run())
            child.waitUntilExit()
            XCTAssertNotEqual(child.terminationStatus, 0, scenario)
        }
    }
}
