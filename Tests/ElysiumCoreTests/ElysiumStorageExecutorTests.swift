import XCTest
import Foundation
import SQLite3
import Darwin
@testable import ElysiumStorage

final class ElysiumStorageExecutorTests: XCTestCase {
    private func deviceBitPattern(_ device: dev_t) -> UInt64 {
        UInt64(UInt32(bitPattern: device))
    }

    private func databaseURL(_ name: String = UUID().uuidString) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElysiumStorageExecutorTests-\(name)-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("elysium.db")
    }

    @discardableResult
    private func runSQLite(_ databaseURL: URL, _ sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-noheader", databaseURL.path, sql]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            XCTFail("sqlite subprocess failed: "
                    + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            throw ElysiumStorageError.sqlite(primaryCode: process.terminationStatus,
                                            extendedCode: process.terminationStatus,
                                            operation: .open)
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func descriptorCount(for url: URL) -> Int {
        var identity = stat()
        guard lstat(url.path, &identity) == 0 else { return 0 }
        var count = 0
        for descriptor in 0..<min(Int(getdtablesize()), 8_192) {
            var info = stat()
            if fstat(Int32(descriptor), &info) == 0,
               info.st_dev == identity.st_dev, info.st_ino == identity.st_ino {
                count += 1
            }
        }
        return count
    }

    func testDescriptorCountHandlesNegativeNativeDeviceWithoutTrap() {
        let inode: ino_t = 91
        let positive: dev_t = 7
        let negative = dev_t(bitPattern: 0xb00007ff)
        let distinctNegative = dev_t(bitPattern: 0xb0000800)
        let observations: [(dev_t, ino_t)?] = [
            (positive, inode), (negative, inode), nil,
            (positive, inode), (distinctNegative, inode),
        ]
        XCTAssertEqual(ElysiumStorageDescriptorIdentityProbe.descriptorCount(
            targetDevice: positive, targetInode: inode,
            observations: observations), 2)
        XCTAssertEqual(ElysiumStorageDescriptorIdentityProbe.descriptorCount(
            targetDevice: negative, targetInode: inode,
            observations: observations), 1)
        XCTAssertEqual(ElysiumStorageDescriptorIdentityProbe.descriptorCount(
            targetDevice: distinctNegative, targetInode: inode,
            observations: [(negative, inode)]), 0)
        XCTAssertEqual(ElysiumStorageDescriptorIdentityProbe.deviceBitPattern(negative),
                       0x00000000b00007ff)
        XCTAssertNil(ElysiumStorageDescriptorIdentityProbe.descriptorCount(
            targetDevice: positive, targetInode: inode,
            observations: Array(repeating: nil, count: 65_537)))
    }

    func testOpenConfiguresBootstrapsAndCloses() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        let storage = try coordinator.legacyCore()
        try storage.verifyCoreSchema()
        XCTAssertTrue(try coordinator._testAutocommit())
        XCTAssertTrue(try coordinator._testForeignKeysEnabled())
        try coordinator.close()
        try coordinator.close()
    }

    func testAllNamedLegacyFacadesRoundTripAndMutateAtomically() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()

        let world = try ElysiumWorldStorageRow(id: "w", json: "{}", lastPlayed: 1.5)
        try storage.putWorldRow(world)
        XCTAssertEqual(try storage.getWorldRow(id: "w"), world)
        XCTAssertEqual(try storage.listWorldRows(), [world])

        let key = try ElysiumChunkStorageKey(world: "w", dimension: 0, chunkX: -2, chunkZ: 3)
        let chunk = try ElysiumChunkStorageRow(key: key, data: Data([0, 1, 2]))
        XCTAssertEqual(try storage.putChunkBlobRows([chunk]), 1)
        XCTAssertEqual(try storage.getChunkBlob(key: key), chunk.data)
        XCTAssertEqual(try storage.listChunkKeys(world: "w"), [key])

        let player = try ElysiumPlayerJSONStorageRow(world: "w", json: "{\"p\":1}")
        try storage.putPlayerJSON(player)
        XCTAssertEqual(try storage.getPlayerJSON(world: "w"), player)

        let resume = try ElysiumLANClientResumeStorageRow(hostWorld: "host", json: "{}", updated: 2)
        try storage.putLANClientResumeJSON(resume)
        XCTAssertEqual(try storage.getLANClientResumeJSON(hostWorld: "host"), resume)
        XCTAssertEqual(try storage.deleteLANClientResumeJSON(hostWorld: "host"), 1)

        let lan = try ElysiumLANPlayerStorageRow(world: "w", playerID: "p1", json: "{}", updated: 3)
        try storage.putLANPlayerJSON(lan)
        XCTAssertEqual(try storage.getLANPlayerJSON(world: "w", playerID: "p1"), lan)
        XCTAssertEqual(try storage.listLANPlayerJSON(world: "w"), [lan])
        XCTAssertEqual(try storage.deleteLANPlayerJSON(world: "w", playerID: "p1"), 1)

        let advancement = try ElysiumAdvancementStorageRow(world: "w", json: "[]")
        try storage.putAdvancementJSON(advancement)
        XCTAssertEqual(try storage.getAdvancementJSON(world: "w"), advancement)

        let summary = try ElysiumTemplateSummaryStorageRow(
            name: "house", sizeX: 1, sizeY: 2, sizeZ: 3, blockCount: 6,
            blockEntityCount: 0, dominantBlock: "", dominantDisplay: "")
        let template = try ElysiumTemplateStorageRow(summary: summary, json: "", created: 4,
                                                    format: 2, data: Data([7]))
        XCTAssertEqual(try storage.putTemplateRow(template), 1)
        XCTAssertEqual(try storage.getTemplateRow(name: "house"), template)
        XCTAssertEqual(try storage.listTemplateNames(), ["house"])
        XCTAssertEqual(try storage.listTemplateSummaries(), [summary])
        XCTAssertEqual(try storage.deleteTemplateRow(name: "house"), 1)

        XCTAssertEqual(try storage.deleteWorld(id: "w"), 4)
        XCTAssertNil(try storage.getWorldRow(id: "w"))
        XCTAssertNil(try storage.getChunkBlob(key: key))
        XCTAssertNil(try storage.getPlayerJSON(world: "w"))
        XCTAssertNil(try storage.getAdvancementJSON(world: "w"))
    }

    func testAtomicLegacyWorldImport() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()
        let world = try ElysiumWorldStorageRow(id: "import", json: "{}", lastPlayed: 5)
        let player = try ElysiumPlayerJSONStorageRow(world: "import", json: "{}")
        let advancement = try ElysiumAdvancementStorageRow(world: "import", json: "[]")
        let key = try ElysiumChunkStorageKey(world: "import", dimension: 0, chunkX: 0, chunkZ: 0)
        let chunk = try ElysiumChunkStorageRow(key: key, data: Data([1]))
        let value = try ElysiumLegacyWorldImport(world: world, player: player,
                                                advancements: advancement, chunks: [chunk])
        XCTAssertEqual(try storage.importLegacyWorld(value), 4)
        XCTAssertEqual(try storage.getWorldRow(id: "import"), world)
        XCTAssertEqual(try storage.getPlayerJSON(world: "import"), player)
        XCTAssertEqual(try storage.getAdvancementJSON(world: "import"), advancement)
        XCTAssertEqual(try storage.getChunkBlob(key: key), Data([1]))
    }

    func testThreeHundredConcurrentWritesReadsAndKeysetPagesAreSerialized() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()
        let group = DispatchGroup()
        let lock = NSLock()
        var errors: [String] = []
        for index in 0..<300 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let row = try ElysiumWorldStorageRow(id: String(format: "w-%03d", index),
                                                        json: "{}", lastPlayed: Double(index))
                    try storage.putWorldRow(row)
                    guard try storage.getWorldRow(id: row.id) == row else {
                        throw ElysiumStorageError.invalidValue
                    }
                } catch {
                    lock.lock(); errors.append(String(describing: error)); lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(errors, [])
        XCTAssertEqual(try storage.listWorldRows().count, 300)
    }

    func testFailureInjectionRollsBackAndRestoresAutocommit() throws {
        let operations: [ElysiumStorageOperationID] = [
            .beginImmediate, .prepare, .bind, .step, .changes, .finalize, .commit,
        ]
        for operation in operations {
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL(operation.rawValue))
            defer { try? coordinator.close() }
            let storage = try coordinator.legacyCore()
            try coordinator._testInject(operation)
            let row = try ElysiumWorldStorageRow(id: "never", json: "{}", lastPlayed: 0)
            XCTAssertThrowsError(try storage.putWorldRow(row), operation.rawValue)
            XCTAssertTrue(try coordinator._testAutocommit(), operation.rawValue)
            XCTAssertNil(try storage.getWorldRow(id: "never"), operation.rawValue)
        }
    }

    func testCaughtBindFailureCannotCommit() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()
        let row = try ElysiumWorldStorageRow(id: "caught", json: "{}", lastPlayed: 0)
        XCTAssertThrowsError(try coordinator._testCaughtBindFailureCannotCommit(row))
        XCTAssertTrue(try coordinator._testAutocommit())
        XCTAssertNil(try storage.getWorldRow(id: "caught"))
    }

    func testBodyAndFinalizeFailurePreservesBothWithoutLeakingValues() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        defer { try? coordinator.close() }
        XCTAssertThrowsError(try coordinator._testBodyAndFinalizeFailure()) { error in
            guard let failure = error as? ElysiumStorageStatementFailure else {
                return XCTFail("expected composite statement failure, got \(error)")
            }
            XCTAssertNotNil(failure.primary as? ElysiumStorageTestBodyError)
            guard case let .sqlite(_, _, operation) = failure.finalize else {
                return XCTFail("expected injected finalize failure")
            }
            XCTAssertEqual(operation, .finalize)
        }
        XCTAssertTrue(try coordinator._testAutocommit())
    }

    func testRollbackFailurePoisonsAndPreservesBothFailures() throws {
        let url = try databaseURL()
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let storage = try coordinator.legacyCore()
        try coordinator._testInject(.commit)
        try coordinator._testInject(.rollback)
        let row = try ElysiumWorldStorageRow(id: "poison", json: "{}", lastPlayed: 0)
        XCTAssertThrowsError(try storage.putWorldRow(row)) { error in
            guard let failure = error as? ElysiumStorageTransactionFailure else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertNotNil(failure.rollback)
            XCTAssertEqual(failure.terminal, .transactionStillOpen)
        }
        XCTAssertThrowsError(try storage.listWorldRows())
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url))
    }

    func testScopeReentryEscapeNestedTransactionAndGenerationBoundaryFailClosed() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        XCTAssertTrue(try coordinator._testSameScopeReentry())
        XCTAssertEqual(try coordinator._testEscapedStatementRejects(), .inactiveContext)
        XCTAssertThrowsError(try coordinator._testNestedTransactionProbe())
        XCTAssertTrue(try coordinator._testAutocommit())
        XCTAssertThrowsError(try coordinator._testForceAuthorizationGenerationBoundary())
        XCTAssertThrowsError(try coordinator.legacyCore().listWorldRows())
    }

    func testDeinitClosesHealthyHandleAndAllowsReopen() throws {
        let url = try databaseURL()
        do {
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let storage = try coordinator.legacyCore()
            try storage.putWorldRow(ElysiumWorldStorageRow(id: "w", json: "{}", lastPlayed: 0))
        }
        let reopened = try ElysiumStorageCoordinator.open(databaseURL: url)
        XCTAssertNotNil(try reopened.legacyCore().getWorldRow(id: "w"))
        try reopened.close()
    }

    func testBusyCloseIsTerminalTombstoneAndRepeatedResultIsStable() throws {
        let url = try databaseURL()
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        try coordinator._testLeakRawStatementForClose()
        var first = ""
        XCTAssertThrowsError(try coordinator.close()) { first = String(describing: $0) }
        XCTAssertThrowsError(try coordinator.close()) { XCTAssertEqual(String(describing: $0), first) }
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url))
    }

    func testCloseLinearizesAgainstConcurrentSubmittedWork() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        let storage = try coordinator.legacyCore()
        let group = DispatchGroup()
        let lock = NSLock()
        var unexpected: [String] = []
        for index in 0..<150 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    try storage.putWorldRow(ElysiumWorldStorageRow(
                        id: "race-\(index)", json: "{}", lastPlayed: Double(index)))
                } catch ElysiumStorageError.closed {
                    // Work admitted after close's linearization point is rejected.
                } catch {
                    lock.lock(); unexpected.append(String(describing: error)); lock.unlock()
                }
            }
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try coordinator.close() }
            catch { lock.lock(); unexpected.append(String(describing: error)); lock.unlock() }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(unexpected, [])
        XCTAssertThrowsError(try coordinator.legacyCore()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .closed)
        }
        XCTAssertThrowsError(try storage.listWorldRows()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .closed)
        }
    }

    func testAuthorizationTransitionMatrixStickyDenialAndRejectedWidening() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        defer { try? coordinator.close() }
        XCTAssertEqual(try coordinator._testAuthorizationContract(), 0b1_1111)
        XCTAssertTrue(try coordinator._testAutocommit())
    }

    func testEmptyChunkBatchUsesTransactionAdmissionAndCommitPath() throws {
        for operation in [ElysiumStorageOperationID.beginImmediate, .commit] {
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL(operation.rawValue))
            defer { try? coordinator.close() }
            let storage = try coordinator.legacyCore()
            try coordinator._testInject(operation)
            XCTAssertThrowsError(try storage.putChunkBlobRows([]), operation.rawValue)
            XCTAssertTrue(try coordinator._testAutocommit(), operation.rawValue)
        }

        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("empty-success"))
        defer { try? coordinator.close() }
        XCTAssertEqual(try coordinator.legacyCore().putChunkBlobRows([]), 0)
        XCTAssertTrue(try coordinator._testAutocommit())
    }

    func testExtendedConstraintPreservesPrimaryMaskAndExtendedCode() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL())
        defer { try? coordinator.close() }

        func sqliteFailure(in error: any Error) -> ElysiumStorageError? {
            if let storage = error as? ElysiumStorageError { return storage }
            if let transaction = error as? ElysiumStorageTransactionFailure {
                return sqliteFailure(in: transaction.primary)
            }
            if let statement = error as? ElysiumStorageStatementFailure {
                return sqliteFailure(in: statement.primary)
            }
            return nil
        }

        XCTAssertThrowsError(try coordinator._testExtendedPrimaryKeyConstraint()) { error in
            guard case let .sqlite(primary, extended, operation) = sqliteFailure(in: error) else {
                return XCTFail("expected closed SQLite failure, got \(error)")
            }
            XCTAssertEqual(primary, SQLITE_CONSTRAINT)
            XCTAssertEqual(extended, SQLITE_CONSTRAINT | (6 << 8))
            XCTAssertEqual(operation, .step)
        }
        XCTAssertTrue(try coordinator._testAutocommit())
        XCTAssertNil(try coordinator.legacyCore().getWorldRow(id: "__constraint_probe__"))
    }

    func testDatabaseParentIdentityExactMismatchAliasAndClosedLifecycle() throws {
        let url = try databaseURL("parent-identity")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        var info = stat()
        XCTAssertEqual(lstat(url.deletingLastPathComponent().path, &info), 0)
        let device = deviceBitPattern(info.st_dev)
        let inode = UInt64(info.st_ino)

        XCTAssertNoThrow(try coordinator.verifyDatabaseParentIdentity(device: device, inode: inode))
        XCTAssertThrowsError(try coordinator.verifyDatabaseParentIdentity(
            device: device, inode: inode &+ 1)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .invalidValue)
        }
        XCTAssertNoThrow(try coordinator.legacyCore().listWorldRows(),
                         "a caller mismatch must not poison the coordinator")

        let alias = url.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("parent-alias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: alias, withDestinationURL: url.deletingLastPathComponent())
        var aliasInfo = stat()
        XCTAssertEqual(stat(alias.path, &aliasInfo), 0)
        XCTAssertNoThrow(try coordinator.verifyDatabaseParentIdentity(
            device: deviceBitPattern(aliasInfo.st_dev), inode: UInt64(aliasInfo.st_ino)))

        try coordinator.close()
        XCTAssertThrowsError(try coordinator.verifyDatabaseParentIdentity(device: device, inode: inode)) {
            error in XCTAssertEqual(error as? ElysiumStorageError, .closed)
        }
    }

    func testDatabaseParentReplacementPoisonsAndTombstonesPhysicalDatabase() throws {
        let url = try databaseURL("parent-replacement")
        let parent = url.deletingLastPathComponent()
        let displaced = parent.deletingLastPathComponent()
            .appendingPathComponent(parent.lastPathComponent + "-displaced")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        var info = stat()
        XCTAssertEqual(lstat(parent.path, &info), 0)
        let device = deviceBitPattern(info.st_dev)
        let inode = UInt64(info.st_ino)

        XCTAssertEqual(Darwin.rename(parent.path, displaced.path), 0)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertThrowsError(try coordinator.verifyDatabaseParentIdentity(device: device, inode: inode))
        XCTAssertThrowsError(try coordinator.legacyCore()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .poisoned)
        }
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(
            databaseURL: displaced.appendingPathComponent("elysium.db"))) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .duplicateOpen)
        }
    }

    func testReplaceCompleteImportRemovesStaleOptionalAndChunkStateButPreservesLANRows() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("replace-import"))
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()
        let world = try ElysiumWorldStorageRow(id: "w", json: "old", lastPlayed: 1)
        let oldKey = try ElysiumChunkStorageKey(world: "w", dimension: 0, chunkX: 1, chunkZ: 1)
        let oldChunk = try ElysiumChunkStorageRow(key: oldKey, data: Data([1]))
        _ = try storage.importLegacyWorld(ElysiumLegacyWorldImport(
            world: world,
            player: ElysiumPlayerJSONStorageRow(world: "w", json: "old-player"),
            advancements: ElysiumAdvancementStorageRow(world: "w", json: "old-adv"),
            chunks: [oldChunk]))
        let resume = try ElysiumLANClientResumeStorageRow(hostWorld: "host", json: "resume", updated: 1)
        let peer = try ElysiumLANPlayerStorageRow(
            world: "w", playerID: "peer", json: "peer-json", updated: 2)
        try storage.putLANClientResumeJSON(resume)
        try storage.putLANPlayerJSON(peer)

        let replacement = try ElysiumLegacyWorldImport(
            world: ElysiumWorldStorageRow(id: "w", json: "new", lastPlayed: 2),
            player: nil, advancements: nil, chunks: [])
        _ = try storage.importLegacyWorld(replacement)
        XCTAssertEqual(try storage.getWorldRow(id: "w")?.json, "new")
        XCTAssertNil(try storage.getPlayerJSON(world: "w"))
        XCTAssertNil(try storage.getAdvancementJSON(world: "w"))
        XCTAssertEqual(try storage.listChunkKeys(world: "w"), [])
        XCTAssertEqual(try storage.getLANClientResumeJSON(hostWorld: "host"), resume)
        XCTAssertEqual(try storage.getLANPlayerJSON(world: "w", playerID: "peer"), peer)
    }

    func testEveryReplaceCompleteImportFailureCutRestoresPriorAggregateAndLANRows() throws {
        struct Snapshot: Equatable {
            let world: ElysiumWorldStorageRow?
            let player: ElysiumPlayerJSONStorageRow?
            let advancement: ElysiumAdvancementStorageRow?
            let chunkKeys: [ElysiumChunkStorageKey]
            let chunkData: [Data]
            let resume: ElysiumLANClientResumeStorageRow?
            let peers: [ElysiumLANPlayerStorageRow]
        }

        func snapshot(_ storage: ElysiumLegacyCoreStorage) throws -> Snapshot {
            let keys = try storage.listChunkKeys(world: "w")
            return try Snapshot(
                world: storage.getWorldRow(id: "w"),
                player: storage.getPlayerJSON(world: "w"),
                advancement: storage.getAdvancementJSON(world: "w"),
                chunkKeys: keys,
                chunkData: keys.map { try storage.getChunkBlob(key: $0) ?? Data() },
                resume: storage.getLANClientResumeJSON(hostWorld: "host"),
                peers: storage.listLANPlayerJSON(world: "w"))
        }

        for cut in ElysiumStorageLegacyImportFailurePoint.allCases {
            let url = try databaseURL("import-cut-\(cut)")
            var coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            var storage = try coordinator.legacyCore()
            let oldChunks = try (0..<3).map { index in
                try ElysiumChunkStorageRow(
                    key: ElysiumChunkStorageKey(world: "w", dimension: 0,
                                               chunkX: Int32(index), chunkZ: 0),
                    data: Data([UInt8(index)]))
            }
            _ = try storage.importLegacyWorld(ElysiumLegacyWorldImport(
                world: ElysiumWorldStorageRow(id: "w", json: "old", lastPlayed: 1),
                player: ElysiumPlayerJSONStorageRow(world: "w", json: "old-player"),
                advancements: ElysiumAdvancementStorageRow(world: "w", json: "old-adv"),
                chunks: oldChunks))
            try storage.putLANClientResumeJSON(ElysiumLANClientResumeStorageRow(
                hostWorld: "host", json: "resume", updated: 1))
            try storage.putLANPlayerJSON(ElysiumLANPlayerStorageRow(
                world: "w", playerID: "peer", json: "peer", updated: 2))
            let before = try snapshot(storage)
            let newChunks = try (10..<13).map { index in
                try ElysiumChunkStorageRow(
                    key: ElysiumChunkStorageKey(world: "w", dimension: 1,
                                               chunkX: Int32(index), chunkZ: -1),
                    data: Data([UInt8(index)]))
            }
            let replacement = try ElysiumLegacyWorldImport(
                world: ElysiumWorldStorageRow(id: "w", json: "new", lastPlayed: 2),
                player: ElysiumPlayerJSONStorageRow(world: "w", json: "new-player"),
                advancements: ElysiumAdvancementStorageRow(world: "w", json: "new-adv"),
                chunks: newChunks)
            try coordinator._testSetLegacyImportFailure(cut)
            XCTAssertThrowsError(try storage.importLegacyWorld(replacement), "cut=\(cut)")
            try coordinator.close()

            coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            storage = try coordinator.legacyCore()
            XCTAssertEqual(try snapshot(storage), before, "cut=\(cut)")
            try coordinator.close()
        }
    }

    func testMigrationBarrierSuccessClosedFailuresRetryAndLifecycle() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("barrier"))
        let storage = try coordinator.legacyCore()
        try storage.putWorldRow(ElysiumWorldStorageRow(id: "w", json: "{}", lastPlayed: 0))
        XCTAssertNoThrow(try storage.prepareLegacyMigrationRename())
        XCTAssertEqual(try coordinator._testAuthorizationContract(), 0b1_1111)

        for point in [ElysiumStorageBarrierFailurePoint.checkpointBusy,
                      .checkpointRemainingFrames, .durabilitySyncFailure] {
            try coordinator._testSetBarrierFailure(point)
            XCTAssertThrowsError(try storage.prepareLegacyMigrationRename(), "point=\(point)") {
                error in
                guard case let .sqlite(_, _, operation) = error as? ElysiumStorageError else {
                    return XCTFail("expected closed barrier failure: \(error)")
                }
                XCTAssertEqual(operation,
                               point == .durabilitySyncFailure ? .durabilitySync : .checkpoint)
                XCTAssertFalse(String(describing: error).contains("barrier"))
            }
            XCTAssertNoThrow(try storage.prepareLegacyMigrationRename(), "retry=\(point)")
        }
        try coordinator.close()
        XCTAssertThrowsError(try storage.prepareLegacyMigrationRename()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .closed)
        }
    }

    func testMigrationBarrierRejectsLeakedStatementWithoutChangingScope() throws {
        let url = try databaseURL("barrier-leak")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let storage = try coordinator.legacyCore()
        try coordinator._testLeakRawStatementForClose()
        XCTAssertThrowsError(try storage.prepareLegacyMigrationRename()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .statementLeak)
        }
        XCTAssertThrowsError(try coordinator.close())
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: url))
    }

    func testMigrationBarrierPoisonsOnDatabaseParentReplacementBeforeCheckpoint() throws {
        let url = try databaseURL("barrier-parent-replacement")
        let parent = url.deletingLastPathComponent()
        let displaced = parent.deletingLastPathComponent()
            .appendingPathComponent(parent.lastPathComponent + "-displaced")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let storage = try coordinator.legacyCore()
        try storage.putWorldRow(ElysiumWorldStorageRow(id: "w", json: "{}", lastPlayed: 0))
        XCTAssertEqual(Darwin.rename(parent.path, displaced.path), 0)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        XCTAssertThrowsError(try storage.prepareLegacyMigrationRename())
        XCTAssertThrowsError(try storage.listWorldRows()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .poisoned)
        }
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(
            databaseURL: displaced.appendingPathComponent("elysium.db"))) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .duplicateOpen)
        }
    }

    func testCloseInjectionOneProvesDisposalAndTwoRemainsPoisonedUntilDeinit() throws {
        let disposedURL = try databaseURL("close-disposed")
        let disposed = try ElysiumStorageCoordinator.open(databaseURL: disposedURL)
        let disposedStorage = try disposed.legacyCore()
        XCTAssertGreaterThanOrEqual(descriptorCount(for: disposedURL), 2)
        try disposed._testInject(.close, count: 1)
        var original = ""
        XCTAssertThrowsError(try disposed.close()) { original = String(describing: $0) }
        XCTAssertEqual(descriptorCount(for: disposedURL), 0)
        XCTAssertThrowsError(try disposed.close()) { XCTAssertEqual(String(describing: $0), original) }
        XCTAssertThrowsError(try disposedStorage.listWorldRows()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .closed)
        }
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: disposedURL))

        let poisonedURL = try databaseURL("close-poisoned")
        var poisoned: ElysiumStorageCoordinator? = try ElysiumStorageCoordinator.open(
            databaseURL: poisonedURL)
        XCTAssertGreaterThanOrEqual(descriptorCount(for: poisonedURL), 2)
        try poisoned?._testInject(.close, count: 2)
        XCTAssertThrowsError(try poisoned?.close())
        XCTAssertEqual(descriptorCount(for: poisonedURL), 1,
                       "only the unproven SQLite handle must remain")
        XCTAssertThrowsError(try poisoned?.close()) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .poisoned)
        }
        poisoned = nil
        XCTAssertEqual(descriptorCount(for: poisonedURL), 0)
        XCTAssertThrowsError(try ElysiumStorageCoordinator.open(databaseURL: poisonedURL))
    }

    func testChunkPaginationRejectsEveryExternalCommitAndAcceptsReadOnlyProcess() throws {
        struct Mutation {
            let label: String
            let sql: String
            let mustReject: Bool
        }
        let mutations = [
            Mutation(label: "growth", sql: """
                INSERT INTO chunks(world,dim,cx,cz,data) VALUES('w',0,10000,0,X'00')
                """, mustReject: true),
            Mutation(label: "insert-behind-cursor", sql: """
                INSERT INTO chunks(world,dim,cx,cz,data) VALUES('w',-1,-1,-1,X'00')
                """, mustReject: true),
            Mutation(label: "deletion", sql: """
                DELETE FROM chunks WHERE world='w' AND dim=0 AND cx=10 AND cz=0
                """, mustReject: true),
            Mutation(label: "count-neutral-replace", sql: """
                BEGIN IMMEDIATE;
                DELETE FROM chunks WHERE world='w' AND dim=0 AND cx=10 AND cz=0;
                INSERT INTO chunks(world,dim,cx,cz,data) VALUES('w',0,10000,0,X'00');
                COMMIT;
                """, mustReject: true),
            Mutation(label: "read-only", sql: "SELECT count(*) FROM chunks", mustReject: false),
        ]

        for mutation in mutations {
            let url = try databaseURL("chunk-race-\(mutation.label)")
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let storage = try coordinator.legacyCore()
            let rows = try (0..<256).map { index in
                try ElysiumChunkStorageRow(
                    key: ElysiumChunkStorageKey(world: "w", dimension: 0,
                                               chunkX: Int32(index), chunkZ: 0),
                    data: Data([UInt8(truncatingIfNeeded: index)]))
            }
            XCTAssertEqual(try storage.putChunkBlobRows(rows), 256)
            let latch = try coordinator._testArmStage(.afterChunkKeyPreflight)
            let group = DispatchGroup()
            let resultLock = NSLock()
            var result: [ElysiumChunkStorageKey]?
            var observedError: (any Error)?
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let keys = try storage.listChunkKeys(world: "w")
                    resultLock.lock(); result = keys; resultLock.unlock()
                } catch {
                    resultLock.lock(); observedError = error; resultLock.unlock()
                }
            }
            try latch.waitUntilReached()
            _ = try runSQLite(url, mutation.sql)
            try latch.resume()
            XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            resultLock.lock()
            let capturedResult = result
            let capturedError = observedError
            resultLock.unlock()
            if mutation.mustReject {
                XCTAssertNil(capturedResult, mutation.label)
                XCTAssertEqual(capturedError as? ElysiumStorageError, .schemaMismatch,
                               mutation.label)
            } else {
                XCTAssertNil(capturedError, mutation.label)
                XCTAssertEqual(capturedResult?.count, 256, mutation.label)
            }
            try coordinator.close()
        }
    }

    func testStageEarlyDoubleResumeSingleUseTimeoutRetryAndCancellationRearm() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("stages"))
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()

        let early = try coordinator._testArmStage(.afterDurabilitySyncBeforeIdentityProof)
        try early.resume()
        try early.resume()
        XCTAssertNoThrow(try storage.prepareLegacyMigrationRename())
        XCTAssertNoThrow(try early.waitUntilReached())
        XCTAssertNoThrow(try storage.prepareLegacyMigrationRename(), "stage must be single-use")

        let timeout = try coordinator._testArmStage(.afterDurabilitySyncBeforeIdentityProof)
        let group = DispatchGroup()
        let lock = NSLock()
        var timeoutError: (any Error)?
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try storage.prepareLegacyMigrationRename() }
            catch { lock.lock(); timeoutError = error; lock.unlock() }
        }
        try timeout.waitUntilReached()
        XCTAssertEqual(group.wait(timeout: .now() + 7), .success)
        lock.lock(); let capturedTimeout = timeoutError; lock.unlock()
        XCTAssertEqual(capturedTimeout as? ElysiumStorageTestStageError, .timeout)
        XCTAssertNoThrow(try storage.prepareLegacyMigrationRename(), "intact timeout must be retryable")

        let wrongStage = try coordinator._testArmStage(.afterChunkKeyPreflight)
        try wrongStage._testExpireDeadline(.externalWait)
        XCTAssertThrowsError(try wrongStage.waitUntilReached()) { error in
            XCTAssertEqual(error as? ElysiumStorageTestStageError, .timeout)
        }
        XCTAssertThrowsError(try wrongStage.resume()) { error in
            XCTAssertEqual(error as? ElysiumStorageTestStageError, .timeout)
        }
        let rearmed = try coordinator._testArmStage(.afterDurabilitySyncBeforeIdentityProof)
        try rearmed.resume()
        XCTAssertNoThrow(try storage.prepareLegacyMigrationRename())
        XCTAssertNoThrow(try rearmed.waitUntilReached())
    }

    func testDeadlineEqualityIsTerminalAndMatchingObservationDetaches() throws {
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: databaseURL("deadline-equality"))
        defer { try? coordinator.close() }
        let storage = try coordinator.legacyCore()

        let external = try coordinator._testArmStage(.afterDurabilitySyncBeforeIdentityProof)
        XCTAssertThrowsError(try external._testExpireDeadline(.executorWait)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .invalidValue)
        }
        try external._testExpireDeadline(.externalWait)
        for operation in [external.waitUntilReached, external.resume] {
            XCTAssertThrowsError(try operation()) { error in
                XCTAssertEqual(error as? ElysiumStorageTestStageError, .timeout)
            }
        }
        XCTAssertThrowsError(try storage.prepareLegacyMigrationRename()) { error in
            XCTAssertEqual(error as? ElysiumStorageTestStageError, .timeout)
        }
        XCTAssertThrowsError(try external._testExpireDeadline(.externalWait)) { error in
            XCTAssertEqual(error as? ElysiumStorageTestStageError, .timeout)
        }
        XCTAssertNoThrow(try storage.prepareLegacyMigrationRename(),
                         "matching terminal observation must detach and preserve retry")

        let executor = try coordinator._testArmStage(.afterDurabilitySyncBeforeIdentityProof)
        let group = DispatchGroup()
        let lock = NSLock()
        var observed: (any Error)?
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            do { try storage.prepareLegacyMigrationRename() }
            catch { lock.lock(); observed = error; lock.unlock() }
        }
        try executor.waitUntilReached()
        XCTAssertThrowsError(try executor._testExpireDeadline(.externalWait)) { error in
            XCTAssertEqual(error as? ElysiumStorageError, .invalidValue)
        }
        try executor._testExpireDeadline(.executorWait)
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success,
                       "deadline equality must release the executor group")
        lock.lock(); let captured = observed; lock.unlock()
        XCTAssertEqual(captured as? ElysiumStorageTestStageError, .timeout)
        XCTAssertThrowsError(try executor.resume()) { error in
            XCTAssertEqual(error as? ElysiumStorageTestStageError, .timeout)
        }
        XCTAssertThrowsError(try executor.waitUntilReached()) { error in
            XCTAssertEqual(error as? ElysiumStorageTestStageError, .timeout)
        }
        XCTAssertNoThrow(try storage.prepareLegacyMigrationRename(),
                         "executor terminal observation must detach and preserve retry")
    }

    func testPostSyncIdentityFailureOutranksResumeAndStageTimeout() throws {
        for resume in [true, false] {
            let url = try databaseURL("stage-identity-\(resume)")
            let parent = url.deletingLastPathComponent()
            let displaced = parent.deletingLastPathComponent()
                .appendingPathComponent(parent.lastPathComponent + "-displaced")
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let storage = try coordinator.legacyCore()
            let latch = try coordinator._testArmStage(.afterDurabilitySyncBeforeIdentityProof)
            let group = DispatchGroup()
            let lock = NSLock()
            var observed: (any Error)?
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { try storage.prepareLegacyMigrationRename() }
                catch { lock.lock(); observed = error; lock.unlock() }
            }
            try latch.waitUntilReached()
            XCTAssertEqual(Darwin.rename(parent.path, displaced.path), 0)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            if resume { try latch.resume() }
            else { try latch._testExpireDeadline(.executorWait) }
            XCTAssertEqual(group.wait(timeout: .now() + 7), .success)
            lock.lock(); let captured = observed; lock.unlock()
            XCTAssertNotNil(captured)
            XCTAssertNil(captured as? ElysiumStorageTestStageError,
                         "identity failure must outrank stage timeout")
            XCTAssertThrowsError(try storage.listWorldRows()) { error in
                XCTAssertEqual(error as? ElysiumStorageError, .poisoned)
            }
            XCTAssertThrowsError(try ElysiumStorageCoordinator.open(
                databaseURL: displaced.appendingPathComponent("elysium.db")))
        }
    }
}
