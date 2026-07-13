import Foundation
import SQLite3
import XCTest
@testable import ElysiumCore
@testable import ElysiumStorage
@testable import ElysiumTextInput

@MainActor
final class SavedWorldBatchDeleteTests: XCTestCase {
    private func databaseURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "ElysiumSavedWorldBatch-\(label)-\(UUID().uuidString).sqlite")
    }

    @discardableResult
    private func execute(_ url: URL, _ sql: String) throws -> Int32 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw ElysiumStorageError.invalidValue }
        defer { sqlite3_close(database) }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw ElysiumStorageError.invalidValue }
        return result
    }

    private func scalar(_ url: URL, _ sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database else { throw ElysiumStorageError.invalidValue }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ElysiumStorageError.invalidValue }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ElysiumStorageError.invalidValue }
        return sqlite3_column_int64(statement, 0)
    }

    private func world(_ id: String, name: String? = nil, lastPlayed: Double) throws
        -> ElysiumWorldStorageRow {
        var record = WorldRecord(
            id: id, name: name ?? id, seed: 1, gameMode: GameMode.survival, difficulty: 2)
        record.lastPlayed = lastPlayed
        let data = try JSONEncoder().encode(record)
        return try ElysiumWorldStorageRow(
            id: id, json: String(decoding: data, as: UTF8.self), lastPlayed: lastPlayed)
    }

    private func worldRecord(_ id: String, lastPlayed: Double) -> WorldRecord {
        var record = WorldRecord(
            id: id, name: id, seed: 1,
            gameMode: GameMode.survival, difficulty: 2)
        record.lastPlayed = lastPlayed
        return record
    }

    private func request(_ core: ElysiumLegacyCoreStorage, ids: Set<String>) throws
        -> ElysiumWorldBatchDeleteRequest {
        let snapshot = try core.checkedWorldSnapshot()
        let expectations = try snapshot.rows.filter { ids.contains($0.storedID) }
            .sorted { Data($0.storedID.utf8).lexicographicallyPrecedes(Data($1.storedID.utf8)) }
            .map { try ElysiumWorldBatchDeleteExpectation(
                storedID: $0.storedID, rowDigest: $0.rowDigest) }
        return try ElysiumWorldBatchDeleteRequest(
            expectedCollectionDigest: snapshot.collectionDigest, expectations: expectations)
    }

    private func checked(_ snapshot: ElysiumCheckedWorldCollectionSnapshot) throws
        -> CheckedSavedWorldSnapshot {
        try CheckedSavedWorldSnapshot(authoritySnapshot: SavedWorldAuthoritySnapshot(
            rows: snapshot.rows.map {
                SavedWorldAuthorityRow(
                    storedID: $0.storedID, json: $0.json, lastPlayed: $0.lastPlayed,
                    rowDigest: $0.rowDigest)
            }, collectionDigest: snapshot.collectionDigest,
            aggregateRawBytes: snapshot.aggregateRawBytes))
    }

    private func admittedOperation(
        _ game: GameCore, token: SavedWorldMaintenanceCoordinator.Token,
        request: SavedWorldDeleteRequest, screenIdentity: UInt64 = 1,
        launchContextIdentity: UUID = UUID()
    ) throws -> SavedWorldDeleteOperation {
        try XCTUnwrap(game.admitSavedWorldDelete(
            token, request: request, screenIdentity: screenIdentity,
            launchContextIdentity: launchContextIdentity))
    }

    @discardableResult
    private func finish(
        _ game: GameCore, operation: SavedWorldDeleteOperation,
        outcome: SavedWorldDeleteOutcome
    ) -> SavedWorldDeleteOutcome {
        XCTAssertTrue(game.finishSavedWorldDeleteOperation(
            operation, outcome: outcome,
            screenIdentity: operation.screenIdentity,
            launchContextIdentity: operation.launchContextIdentity))
        return outcome
    }

    func testSelectionReducerUsesStableIDsAndRepairsFocus() {
        var state = SavedWorldSelectionState()
        state.refresh(orderedIDs: ["a", "b", "c", "d"])
        state.select(id: "b", gesture: .plain)
        state.select(id: "d", gesture: .extendRange)
        XCTAssertEqual(state.selectedIDs, ["b", "c", "d"])
        XCTAssertEqual(state.rangeAnchorID, "b")
        state.refresh(orderedIDs: ["d", "c", "a"])
        XCTAssertEqual(state.selectedIDs, ["c", "d"])
        XCTAssertEqual(state.focusedID, "d")
        XCTAssertEqual(state.rangeAnchorID, "d")
        state.select(id: "c", gesture: .toggle)
        XCTAssertEqual(state.selectedIDs, ["d"])

        let selectionBeforeAXFocus = state.selectedIDs
        let anchorBeforeAXFocus = state.rangeAnchorID
        XCTAssertTrue(state.focus(id: "a"))
        XCTAssertEqual(state.focusedID, "a")
        XCTAssertEqual(state.selectedIDs, selectionBeforeAXFocus,
                       "focus-only AX movement must not change delete authority")
        XCTAssertEqual(state.rangeAnchorID, anchorBeforeAXFocus)
        XCTAssertFalse(state.focus(id: "missing"))
        XCTAssertEqual(state.focusedID, "a")
    }

    func testSelectionAccessibilityProjectionCommitsEveryInteractionStateAndRetiresStaleIdentity()
        throws {
        var selection = SavedWorldSelectionState()
        selection.refresh(orderedIDs: ["alpha", "beta", "gamma"])
        var clock = ElysiumTextPresentationClock(value: 40)
        let screenIdentity: UInt64 = 91

        func identity(_ generation: UInt64, _ descriptorID: String)
            -> ElysiumTextAccessibilityIdentity {
            ElysiumTextAccessibilityIdentity(
                screenIdentity: screenIdentity,
                presentationGeneration: generation,
                descriptorID: descriptorID)
        }

        var semantic = SavedWorldSelectionAccessibilitySnapshot(selection: selection)
        XCTAssertEqual(semantic.bulkActionID, "worlds.selectAll")
        XCTAssertEqual(semantic.bulkActionLabel, "Select All")
        XCTAssertTrue(semantic.bulkActionEnabled)
        XCTAssertEqual(semantic.rowValue("alpha"), "Not selected")
        XCTAssertFalse(semantic.rowSelected("alpha"))
        XCTAssertFalse(semantic.playEnabled)
        XCTAssertFalse(semantic.deleteEnabled)
        let initialGeneration = try XCTUnwrap(clock.next())
        let staleSelectAll = identity(initialGeneration, semantic.bulkActionID)

        selection.selectAll()
        semantic = SavedWorldSelectionAccessibilitySnapshot(selection: selection)
        let allGeneration = try XCTUnwrap(clock.next())
        XCTAssertEqual(semantic.bulkActionID, "worlds.clearAll")
        XCTAssertEqual(semantic.bulkActionLabel, "Clear All")
        for id in selection.orderedIDs {
            XCTAssertEqual(semantic.rowValue(id), "Selected")
            XCTAssertTrue(semantic.rowSelected(id))
        }
        XCTAssertFalse(semantic.playEnabled)
        XCTAssertTrue(semantic.deleteEnabled)
        XCTAssertFalse(elysiumTextAccessibilityIdentityIsCurrent(
            origin: staleSelectAll,
            current: identity(allGeneration, staleSelectAll.descriptorID)))
        let staleClearAll = identity(allGeneration, semantic.bulkActionID)

        selection.clearAll()
        semantic = SavedWorldSelectionAccessibilitySnapshot(selection: selection)
        let clearGeneration = try XCTUnwrap(clock.next())
        XCTAssertEqual(semantic.bulkActionID, "worlds.selectAll")
        XCTAssertEqual(semantic.bulkActionLabel, "Select All")
        XCTAssertTrue(selection.orderedIDs.allSatisfy { !semantic.rowSelected($0) })
        XCTAssertFalse(semantic.playEnabled)
        XCTAssertFalse(semantic.deleteEnabled)
        XCTAssertFalse(elysiumTextAccessibilityIdentityIsCurrent(
            origin: staleClearAll,
            current: identity(clearGeneration, staleClearAll.descriptorID)))

        selection.select(id: "alpha", gesture: .toggle)
        semantic = SavedWorldSelectionAccessibilitySnapshot(selection: selection)
        let rowToggleGeneration = try XCTUnwrap(clock.next())
        XCTAssertEqual(semantic.rowValue("alpha"), "Selected")
        XCTAssertTrue(semantic.rowSelected("alpha"))
        XCTAssertTrue(semantic.playEnabled)
        XCTAssertTrue(semantic.deleteEnabled)
        let staleAlpha = identity(rowToggleGeneration, "worlds.row.alpha")

        selection.moveFocus(delta: 1, extendRange: true)
        semantic = SavedWorldSelectionAccessibilitySnapshot(selection: selection)
        let keyboardGeneration = try XCTUnwrap(clock.next())
        XCTAssertTrue(semantic.rowSelected("alpha"))
        XCTAssertTrue(semantic.rowSelected("beta"))
        XCTAssertEqual(semantic.rowValue("beta"), "Selected")
        XCTAssertFalse(semantic.playEnabled)
        XCTAssertTrue(semantic.deleteEnabled)
        XCTAssertFalse(elysiumTextAccessibilityIdentityIsCurrent(
            origin: staleAlpha,
            current: identity(keyboardGeneration, staleAlpha.descriptorID)))
        XCTAssertTrue(elysiumTextAccessibilityIdentityIsCurrent(
            origin: identity(keyboardGeneration, "worlds.row.beta"),
            current: identity(keyboardGeneration, "worlds.row.beta")))
    }

    func testCompactLayoutHasThreeCompleteRowsAndExactFooterGeometry() {
        let layout = SavedWorldSelectionLayout(width: 360, height: 224)
        XCTAssertEqual(layout.toolbar, .init(x: 26, y: 22, width: 308, height: 20))
        XCTAssertEqual(layout.list, .init(x: 26, y: 46, width: 308, height: 90))
        XCTAssertEqual(layout.visibleCompleteRows, 3)
        XCTAssertEqual(layout.primaryButtons, [
            .init(x: 26, y: 142, width: 100, height: 20),
            .init(x: 130, y: 142, width: 100, height: 20),
            .init(x: 234, y: 142, width: 100, height: 20),
        ])
        XCTAssertEqual(layout.backButton, .init(x: 80, y: 166, width: 200, height: 20))
        XCTAssertEqual(layout.statusY, 190)

        let modal = SavedWorldDeleteModalLayout(width: 360, height: 224)
        XCTAssertEqual(modal.panel, .init(x: 24, y: 28, width: 312, height: 168))
        XCTAssertEqual(modal.title, .init(x: 36, y: 40, width: 288, height: 10))
        XCTAssertEqual(modal.warning, .init(x: 36, y: 56, width: 288, height: 10))
        XCTAssertEqual(modal.names, .init(x: 36, y: 80, width: 288, height: 62))
        XCTAssertEqual(modal.status, .init(x: 36, y: 146, width: 288, height: 10))
        XCTAssertEqual(modal.leftButton, .init(x: 62, y: 166, width: 100, height: 20))
        XCTAssertEqual(modal.rightButton, .init(x: 198, y: 166, width: 100, height: 20))
        XCTAssertEqual(modal.singleButton, .init(x: 130, y: 166, width: 100, height: 20))

        for (width, height) in [(520.0, 330.0), (700.0, 420.0)] {
            let large = SavedWorldSelectionLayout(width: width, height: height)
            XCTAssertEqual(large.list.height.truncatingRemainder(dividingBy: 30), 0)
            XCTAssertEqual(large.list.height, Double(large.visibleCompleteRows) * 30)
            XCTAssertLessThanOrEqual(large.list.y + large.list.height,
                                     large.primaryButtons[0].y - 6)
            XCTAssertLessThan(large.primaryButtons[0].y + 20, large.backButton.y)
            XCTAssertLessThan(large.backButton.y + 20, large.statusY)
        }
    }

    func testPointerEventConsumptionIsOneShotGenerationAndWindowBound() {
        var gate = SavedWorldPointerEventConsumption()
        XCTAssertFalse(gate.consume(screenIdentity: 0, windowNumber: 7, eventNumber: 1))
        XCTAssertFalse(gate.consume(screenIdentity: 1, windowNumber: 0, eventNumber: 1))
        XCTAssertFalse(gate.consume(screenIdentity: 1, windowNumber: 7, eventNumber: -1))
        XCTAssertTrue(gate.consume(screenIdentity: 1, windowNumber: 7, eventNumber: 10))
        XCTAssertFalse(gate.consume(screenIdentity: 1, windowNumber: 7, eventNumber: 10))
        XCTAssertFalse(gate.consume(screenIdentity: 1, windowNumber: 7, eventNumber: 9))
        XCTAssertTrue(gate.consume(screenIdentity: 1, windowNumber: 7, eventNumber: 11))
        XCTAssertTrue(gate.consume(screenIdentity: 2, windowNumber: 7, eventNumber: 1))
        XCTAssertTrue(gate.consume(screenIdentity: 2, windowNumber: 8, eventNumber: 1))

        var state: UInt64 = 0x706f_696e_7465_7273
        var accepted = -1
        var propertyGate = SavedWorldPointerEventConsumption()
        for _ in 0..<4_096 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let candidate = Int(state % 512)
            let expected = candidate > accepted
            XCTAssertEqual(propertyGate.consume(
                screenIdentity: 9, windowNumber: 11, eventNumber: candidate), expected)
            if expected { accepted = candidate }
        }
    }

    func testCheckedBatchDeleteRemovesSixScopesAndPreservesUnrelatedRows() throws {
        let url = databaseURL("six-scopes")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        try core.putWorldRow(world("target", lastPlayed: 2))
        try core.putWorldRow(world("survivor", lastPlayed: 1))
        _ = try coordinator.rpgLocalPreferences()
        try execute(url, """
            INSERT INTO rpg_local_preferences_v1 VALUES(
              'target',1,1,zeroblob(18),zeroblob(32),zeroblob(32),1);
            INSERT INTO rpg_local_preference_migrations_v1 VALUES(
              'target',1,zeroblob(32),zeroblob(32),1);
            INSERT INTO chunks VALUES('target',0,0,0,x'01');
            INSERT INTO player VALUES('target','{}');
            INSERT INTO advancements VALUES('target','{}');
            INSERT INTO chunks VALUES('survivor',0,0,0,x'02');
            INSERT INTO player VALUES('survivor','{}');
            INSERT INTO advancements VALUES('survivor','{}');
            INSERT INTO lan_player_resume VALUES('sentinel','{}',1);
            INSERT INTO templates(name,json) VALUES('sentinel','{}');
            """)
        let outcome = core.deleteWorldsChecked(try request(core, ids: ["target"]))
        guard case .direct(let receipt) = outcome else {
            return XCTFail("expected direct outcome, got \(outcome)")
        }
        XCTAssertEqual(receipt.deletedWorldCount, 1)
        for table in ["worlds", "chunks", "player", "advancements"] {
            XCTAssertEqual(try scalar(url, "SELECT count(*) FROM \(table) WHERE \(table == "worlds" ? "id" : "world")='target'"), 0)
        }
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM rpg_local_preferences_v1"), 0)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM rpg_local_preference_migrations_v1"), 0)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM worlds WHERE id='survivor'"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM chunks WHERE world='survivor'"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM lan_player_resume"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM templates"), 1)
        try coordinator.close()
    }

    func testStaleCollectionAndReplayAreRejectedWithoutMutation() throws {
        let url = databaseURL("stale")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        try core.putWorldRow(world("a", lastPlayed: 2))
        let original = try request(core, ids: ["a"])
        try core.putWorldRow(world("b", lastPlayed: 1))
        XCTAssertEqual(core.deleteWorldsChecked(original), .stale)
        XCTAssertNotNil(try core.getWorldRow(id: "a"))
        let fresh = try request(core, ids: ["a"])
        guard case .direct = core.deleteWorldsChecked(fresh) else {
            return XCTFail("fresh request did not commit")
        }
        XCTAssertEqual(core.deleteWorldsChecked(fresh), .stale)
        XCTAssertNotNil(try core.getWorldRow(id: "b"))
        try coordinator.close()
    }

    func testExternalWriteLockFailsWithinBusyBoundWithoutMutation() throws {
        let url = databaseURL("external-lock")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        try core.putWorldRow(world("target", lastPlayed: 2))
        try core.putWorldRow(world("survivor", lastPlayed: 1))
        let checkedRequest = try request(core, ids: ["target"])

        var locker: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(
            url.path, &locker, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        guard let locker else { return XCTFail("external lock connection") }
        defer { sqlite3_close(locker) }
        XCTAssertEqual(sqlite3_exec(locker, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        let started = ContinuousClock.now
        XCTAssertEqual(core.deleteWorldsChecked(checkedRequest), .terminalIntegrity,
                       "schema admission must fail closed while the external writer owns SQLite")
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .seconds(7), "busy handling must be bounded by 5s plus margin")
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM worlds WHERE id='target'"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM worlds WHERE id='survivor'"), 1)
        XCTAssertEqual(sqlite3_exec(locker, "ROLLBACK", nil, nil, nil), SQLITE_OK)
        try coordinator.close()
    }

    func testEveryScopedFaultIsAtomicAndAfterCommitRecovers() throws {
        var precommit: [ElysiumStorageRPGLocalFailureStage] = [.begin]
        for statement in 0..<6 {
            precommit += [
                .prepare(statement: statement), .bind(statement: statement),
                .step(statement: statement), .changes(statement: statement),
                .finalize(statement: statement),
            ]
        }
        precommit += [.postcondition, .commit]
        for (index, stage) in precommit.enumerated() {
            let url = databaseURL("fault-\(index)")
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let core = try coordinator.legacyCore()
            try core.putWorldRow(world("target", lastPlayed: 1))
            let checkedRequest = try request(core, ids: ["target"])
            try coordinator._testSetRPGLocalFailure(operation: .worldDelete, stage: stage)
            XCTAssertEqual(core.deleteWorldsChecked(checkedRequest), .provenPrecommitFailure,
                           "\(stage)")
            XCTAssertNotNil(try core.getWorldRow(id: "target"), "\(stage)")
            XCTAssertTrue(try coordinator._testAutocommit(), "\(stage)")
            try coordinator.close()
        }

        let url = databaseURL("post-commit")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        try core.putWorldRow(world("target", lastPlayed: 1))
        let checkedRequest = try request(core, ids: ["target"])
        try coordinator._testSetRPGLocalFailure(
            operation: .worldDelete, stage: .afterCommitBeforePublication)
        guard case .recovered(let receipt) = core.deleteWorldsChecked(checkedRequest) else {
            return XCTFail("post-commit cut was not recovered")
        }
        XCTAssertEqual(receipt.deletedWorldCount, 1)
        XCTAssertNil(try core.getWorldRow(id: "target"))
        try coordinator.close()
        let reopened = try ElysiumStorageCoordinator.open(databaseURL: url)
        XCTAssertNil(try reopened.legacyCore().getWorldRow(id: "target"),
                     "post-commit cut must remain exact after restart")
        try reopened.close()

        let preURL = databaseURL("pre-commit-restart")
        let preCoordinator = try ElysiumStorageCoordinator.open(databaseURL: preURL)
        let preCore = try preCoordinator.legacyCore()
        try preCore.putWorldRow(world("target", lastPlayed: 2))
        try preCore.putWorldRow(world("survivor", lastPlayed: 1))
        let preRequest = try request(preCore, ids: ["target"])
        try preCoordinator._testSetRPGLocalFailure(
            operation: .worldDelete, stage: .commit)
        XCTAssertEqual(preCore.deleteWorldsChecked(preRequest), .provenPrecommitFailure)
        try preCoordinator.close()
        let preReopened = try ElysiumStorageCoordinator.open(databaseURL: preURL)
        XCTAssertNotNil(try preReopened.legacyCore().getWorldRow(id: "target"))
        XCTAssertNotNil(try preReopened.legacyCore().getWorldRow(id: "survivor"))
        try preReopened.close()
    }

    func testCheckedSnapshotRejectsCorruptJSONIDTimeAndSQLiteClasses() throws {
        for corruption in 0..<4 {
            let url = databaseURL("corrupt-\(corruption)")
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let core = try coordinator.legacyCore()
            if corruption == 0 {
                try core.putWorldRow(ElysiumWorldStorageRow(id: "a", json: "not-json", lastPlayed: 1))
                XCTAssertThrowsError(try checked(core.checkedWorldSnapshot()))
            } else if corruption == 1 {
                try core.putWorldRow(world("a", name: "A", lastPlayed: 1))
                try execute(url, "UPDATE worlds SET json=replace(json,'\"id\":\"a\"','\"id\":\"b\"')")
                XCTAssertThrowsError(try checked(core.checkedWorldSnapshot()))
            } else if corruption == 2 {
                try core.putWorldRow(world("a", lastPlayed: 1))
                try execute(url, "UPDATE worlds SET lastPlayed=2.0")
                XCTAssertThrowsError(try checked(core.checkedWorldSnapshot()))
            } else {
                try core.putWorldRow(world("a", lastPlayed: 1))
                try execute(url, "PRAGMA ignore_check_constraints=ON; UPDATE worlds SET lastPlayed='bad'")
                XCTAssertThrowsError(try core.checkedWorldSnapshot())
            }
            try coordinator.close()
        }
    }

    func testWorldCount4096AcceptedAnd4097Rejected() throws {
        let url = databaseURL("count")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        _ = try coordinator.legacyCore()
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database,
                                      SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil), SQLITE_OK)
        guard let database else { return XCTFail("sqlite open") }
        XCTAssertEqual(sqlite3_exec(database, "BEGIN", nil, nil, nil), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            database, "INSERT INTO worlds(id,json,lastPlayed) VALUES(?,?,?)", -1,
            &statement, nil), SQLITE_OK)
        guard let statement else { sqlite3_close(database); return XCTFail("prepare") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for index in 0..<4_096 {
            let id = String(format: "w%04d", index)
            sqlite3_bind_text(statement, 1, id, -1, transient)
            sqlite3_bind_text(statement, 2, "{}", -1, transient)
            sqlite3_bind_double(statement, 3, Double(index))
            XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
            sqlite3_reset(statement); sqlite3_clear_bindings(statement)
        }
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_exec(database, "COMMIT", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)
        XCTAssertEqual(try coordinator.legacyCore().checkedWorldSnapshot().rows.count, 4_096)
        try coordinator.legacyCore().putWorldRow(ElysiumWorldStorageRow(
            id: "overflow", json: "{}", lastPlayed: 5_000))
        XCTAssertThrowsError(try coordinator.legacyCore().checkedWorldSnapshot())
        try coordinator.close()
    }

    func testMultiIDDeleteBindsDistinctAuthorityDomainsAndPreservesUnrelatedIdentity() throws {
        let url = databaseURL("multi-authority")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        for (index, id) in ["alpha", "beta", "survivor"].enumerated() {
            try core.putWorldRow(world(id, lastPlayed: Double(10 - index)))
        }
        _ = try coordinator.rpgLocalPreferences()
        for id in ["alpha", "beta"] {
            try execute(url, """
                INSERT INTO rpg_local_preferences_v1 VALUES(
                  '\(id)',1,1,zeroblob(18),zeroblob(32),zeroblob(32),1);
                INSERT INTO rpg_local_preference_migrations_v1 VALUES(
                  '\(id)',1,zeroblob(32),zeroblob(32),1);
                INSERT INTO chunks VALUES('\(id)',0,0,0,x'01');
                INSERT INTO chunks VALUES('\(id)',0,1,0,x'02');
                INSERT INTO player VALUES('\(id)','{}');
                INSERT INTO advancements VALUES('\(id)','{}');
                """)
        }
        try execute(url, """
            INSERT INTO chunks VALUES('survivor',0,99,99,x'AA');
            INSERT INTO player VALUES('survivor','{"sentinel":true}');
            INSERT INTO advancements VALUES('survivor','{"sentinel":true}');
            """)
        let outcome = core.deleteWorldsChecked(try request(core, ids: ["alpha", "beta"]))
        guard case .direct(let receipt) = outcome else {
            return XCTFail("multi-id delete failed: \(outcome)")
        }
        XCTAssertEqual(receipt.deletedWorldCount, 2)
        XCTAssertEqual(receipt.preAuthorityDigest.count, 32)
        XCTAssertEqual(receipt.postAuthorityDigest.count, 32)
        XCTAssertEqual(receipt.unrelatedIdentityDigest.count, 32)
        XCTAssertNotEqual(receipt.preAuthorityDigest, receipt.postAuthorityDigest)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM worlds"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM chunks WHERE world='survivor'"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM player WHERE world='survivor'"), 1)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM advancements WHERE world='survivor'"), 1)
        try coordinator.close()
    }

    func testMultiIDRepresentativeFaultsRollbackAllSixScopes() throws {
        let stages: [ElysiumStorageRPGLocalFailureStage] = [
            .begin, .prepare(statement: 0), .prepare(statement: 5),
            .bind(statement: 0), .bind(statement: 5),
            .step(statement: 2), .changes(statement: 3),
            .finalize(statement: 0), .finalize(statement: 5),
            .postcondition, .commit,
        ]
        for (index, stage) in stages.enumerated() {
            let url = databaseURL("multi-fault-\(index)")
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let core = try coordinator.legacyCore()
            for id in ["a", "b"] { try core.putWorldRow(world(id, lastPlayed: 1)) }
            _ = try coordinator.rpgLocalPreferences()
            for id in ["a", "b"] {
                try execute(url, """
                    INSERT INTO rpg_local_preferences_v1 VALUES(
                      '\(id)',1,1,zeroblob(18),zeroblob(32),zeroblob(32),1);
                    INSERT INTO rpg_local_preference_migrations_v1 VALUES(
                      '\(id)',1,zeroblob(32),zeroblob(32),1);
                    INSERT INTO chunks VALUES('\(id)',0,0,0,x'01');
                    INSERT INTO player VALUES('\(id)','{}');
                    INSERT INTO advancements VALUES('\(id)','{}');
                    """)
            }
            let checkedRequest = try request(core, ids: ["a", "b"])
            try coordinator._testSetRPGLocalFailure(operation: .worldDelete, stage: stage)
            XCTAssertEqual(core.deleteWorldsChecked(checkedRequest), .provenPrecommitFailure,
                           "\(stage)")
            for table in ["worlds", "chunks", "player", "advancements"] {
                XCTAssertEqual(try scalar(url, "SELECT count(*) FROM \(table)"), 2, "\(stage)")
            }
            XCTAssertEqual(try scalar(url, "SELECT count(*) FROM rpg_local_preferences_v1"), 2)
            XCTAssertEqual(try scalar(url, "SELECT count(*) FROM rpg_local_preference_migrations_v1"), 2)
            try coordinator.close()
        }
    }

    @MainActor
    func testMaintenanceLeaseIsNonNestableAndDeleteAdmissionIsOneShot() {
        let coordinator = SavedWorldMaintenanceCoordinator()
        let request = SavedWorldDeleteRequest(
            expectedCollectionDigest: Data(repeating: 1, count: 32),
            expectations: [SavedWorldDeleteExpectation(
                storedID: "world", rowDigest: Data(repeating: 2, count: 32))])
        let token = coordinator.acquire()
        XCTAssertNotNil(token)
        XCTAssertNil(coordinator.acquire())
        guard let token else { return }
        XCTAssertTrue(coordinator.revalidate(token))
        let identity = savedWorldDeleteRequestIdentity(request)
        let launch = UUID()
        XCTAssertNotNil(coordinator.admitDelete(
            token, requestIdentity: identity, screenIdentity: 7,
            launchContextIdentity: launch))
        XCTAssertNil(coordinator.admitDelete(
            token, requestIdentity: identity, screenIdentity: 7,
            launchContextIdentity: launch))
        coordinator.release(token)
        XCTAssertFalse(coordinator.revalidate(token))
        let replacement = coordinator.acquire()
        XCTAssertNotEqual(replacement, token)
        XCTAssertNil(coordinator.admitDelete(
            token, requestIdentity: identity, screenIdentity: 7,
            launchContextIdentity: launch))
    }

    func testConstantTimeDigestBoundaryRejectsEveryPrefixPositionAndWrongLength() {
        let baseline = Data(0..<32)
        XCTAssertTrue(savedWorldConstantTimeEqual32(baseline, baseline))
        for position in 0..<32 {
            var candidate = baseline
            candidate[position] ^= 0x80
            XCTAssertFalse(savedWorldConstantTimeEqual32(baseline, candidate),
                           "accepted mismatch at digest byte \(position)")
            XCTAssertFalse(savedWorldConstantTimeEqual32(candidate, baseline),
                           "comparison must be symmetric at digest byte \(position)")
        }
        XCTAssertFalse(savedWorldConstantTimeEqual32(baseline, baseline.dropLast()))
        XCTAssertFalse(savedWorldConstantTimeEqual32(baseline.dropLast(), baseline))
        XCTAssertFalse(savedWorldConstantTimeEqual32(Data(), Data()))
    }

    func testCoreDeleteAdmissionShapeRejectsMalformedAndNoncanonicalRequests() {
        let digest = Data(repeating: 1, count: 32)
        let a = SavedWorldDeleteExpectation(storedID: "a", rowDigest: digest)
        let b = SavedWorldDeleteExpectation(storedID: "b", rowDigest: digest)
        XCTAssertTrue(savedWorldDeleteRequestHasBoundedCanonicalShape(
            SavedWorldDeleteRequest(expectedCollectionDigest: digest, expectations: [a, b])))
        XCTAssertFalse(savedWorldDeleteRequestHasBoundedCanonicalShape(
            SavedWorldDeleteRequest(expectedCollectionDigest: digest.dropLast(),
                                    expectations: [a])))
        XCTAssertFalse(savedWorldDeleteRequestHasBoundedCanonicalShape(
            SavedWorldDeleteRequest(expectedCollectionDigest: digest, expectations: [])))
        XCTAssertFalse(savedWorldDeleteRequestHasBoundedCanonicalShape(
            SavedWorldDeleteRequest(expectedCollectionDigest: digest, expectations: [b, a])))
        XCTAssertFalse(savedWorldDeleteRequestHasBoundedCanonicalShape(
            SavedWorldDeleteRequest(expectedCollectionDigest: digest, expectations: [a, a])))
        XCTAssertFalse(savedWorldDeleteRequestHasBoundedCanonicalShape(
            SavedWorldDeleteRequest(expectedCollectionDigest: digest, expectations: [
                SavedWorldDeleteExpectation(
                    storedID: String(repeating: "x", count: 257), rowDigest: digest),
            ])))
        XCTAssertFalse(savedWorldDeleteRequestHasBoundedCanonicalShape(
            SavedWorldDeleteRequest(expectedCollectionDigest: digest, expectations: [
                SavedWorldDeleteExpectation(storedID: "a", rowDigest: digest.dropLast()),
            ])))
    }

    func testOutcomeReductionBindingRejectsEveryStaleUIIdentityAcrossResizePhases() {
        let launch = UUID()
        let requestIdentity = Data(0..<32)
        let phases: [SavedWorldOutcomeReductionPhase] = [
            .prechecking, .confirming, .deleting, .terminal, .terminalReloading,
        ]
        for phase in phases {
            let expected = SavedWorldOutcomeReductionBinding(
                screenIdentity: 7, operationGeneration: 11,
                phase: phase, leaseToken: 13,
                requestIdentity: requestIdentity,
                launchContextIdentity: launch)
            XCTAssertTrue(savedWorldOutcomeReductionMatches(
                expected: expected, current: expected), "resize changed \(phase)")
            let stale: [SavedWorldOutcomeReductionBinding] = [
                .init(screenIdentity: 8, operationGeneration: 11, phase: phase,
                      leaseToken: 13, requestIdentity: requestIdentity,
                      launchContextIdentity: launch),
                .init(screenIdentity: 7, operationGeneration: 12, phase: phase,
                      leaseToken: 13, requestIdentity: requestIdentity,
                      launchContextIdentity: launch),
                .init(screenIdentity: 7, operationGeneration: 11,
                      phase: phase == .terminal ? .terminalReloading : .terminal,
                      leaseToken: 13, requestIdentity: requestIdentity,
                      launchContextIdentity: launch),
                .init(screenIdentity: 7, operationGeneration: 11, phase: phase,
                      leaseToken: 14, requestIdentity: requestIdentity,
                      launchContextIdentity: launch),
                .init(screenIdentity: 7, operationGeneration: 11, phase: phase,
                      leaseToken: 13, requestIdentity: Data(repeating: 0, count: 32),
                      launchContextIdentity: launch),
                .init(screenIdentity: 7, operationGeneration: 11, phase: phase,
                      leaseToken: 13, requestIdentity: requestIdentity,
                      launchContextIdentity: UUID()),
            ]
            for candidate in stale {
                XCTAssertFalse(savedWorldOutcomeReductionMatches(
                    expected: expected, current: candidate),
                    "stale binding admitted during \(phase)")
            }
        }
    }

    @MainActor
    func testOpaqueDeleteOperationBindsContextRejectsInWorldAndIsOneShot() throws {
        let url = databaseURL("opaque-operation")
        let db = try SaveDB.open(databaseURL: url, migrateLegacy: false)
        let game = GameCore(db: db)
        db.putWorld(worldRecord("target", lastPlayed: 1))
        let inWorldRequest = try game.checkedWorldSnapshot()
            .deleteRequest(selectedIDs: ["target"])

        game.loadWorld("target")
        XCTAssertTrue(game.inWorld)
        let inWorldToken = try XCTUnwrap(game.acquireSavedWorldMaintenance())
        XCTAssertNil(game.admitSavedWorldDelete(
            inWorldToken, request: inWorldRequest, screenIdentity: 7,
            launchContextIdentity: UUID()))
        game.releaseSavedWorldMaintenance(inWorldToken)
        game.exitToTitle()

        let request = try game.checkedWorldSnapshot().deleteRequest(selectedIDs: ["target"])
        let token = try XCTUnwrap(game.acquireSavedWorldMaintenance())
        let launch = UUID()
        let operation = try admittedOperation(
            game, token: token, request: request,
            screenIdentity: 7, launchContextIdentity: launch)
        XCTAssertFalse(game.finishSavedWorldDeleteOperation(
            operation, outcome: .stale,
            screenIdentity: 8, launchContextIdentity: launch))
        XCTAssertFalse(game.finishSavedWorldDeleteOperation(
            operation, outcome: .stale,
            screenIdentity: 7, launchContextIdentity: UUID()))
        let outcome = operation.execute()
        guard case .direct = outcome else { return XCTFail("expected direct delete") }
        XCTAssertEqual(operation.execute(), .stale,
                       "an admitted storage operation must be one-shot")
        XCTAssertTrue(game.finishSavedWorldDeleteOperation(
            operation, outcome: outcome,
            screenIdentity: 7, launchContextIdentity: launch))
        XCTAssertFalse(game.finishSavedWorldDeleteOperation(
            operation, outcome: outcome,
            screenIdentity: 7, launchContextIdentity: launch),
            "a completion classification must not be replayable")
        game.releaseSavedWorldMaintenance(token)
        try db.close()
    }

    func testDestructiveAccessibilityIdentityIsGenerationLeaseAndRequestBound() {
        let requestA = SavedWorldDeleteRequest(
            expectedCollectionDigest: Data(repeating: 1, count: 32),
            expectations: [SavedWorldDeleteExpectation(
                storedID: "a", rowDigest: Data(repeating: 2, count: 32))])
        let requestB = SavedWorldDeleteRequest(
            expectedCollectionDigest: Data(repeating: 1, count: 32),
            expectations: [SavedWorldDeleteExpectation(
                storedID: "b", rowDigest: Data(repeating: 2, count: 32))])
        let a = savedWorldDeleteRequestIdentity(requestA)
        let b = savedWorldDeleteRequestIdentity(requestB)
        let baseline = savedWorldDestructiveAccessibilityID(
            kind: "delete", screenIdentity: 7, actionGeneration: 9,
            leaseToken: 11, requestIdentity: a)
        XCTAssertNotNil(baseline)
        XCTAssertNotEqual(baseline, savedWorldDestructiveAccessibilityID(
            kind: "delete", screenIdentity: 8, actionGeneration: 9,
            leaseToken: 11, requestIdentity: a))
        XCTAssertNotEqual(baseline, savedWorldDestructiveAccessibilityID(
            kind: "delete", screenIdentity: 7, actionGeneration: 10,
            leaseToken: 11, requestIdentity: a))
        XCTAssertNotEqual(baseline, savedWorldDestructiveAccessibilityID(
            kind: "delete", screenIdentity: 7, actionGeneration: 9,
            leaseToken: 12, requestIdentity: a))
        XCTAssertNotEqual(baseline, savedWorldDestructiveAccessibilityID(
            kind: "delete", screenIdentity: 7, actionGeneration: 9,
            leaseToken: 11, requestIdentity: b))
        XCTAssertNil(savedWorldDestructiveAccessibilityID(
            kind: "unknown", screenIdentity: 7, actionGeneration: 9,
            leaseToken: 11, requestIdentity: a))
        XCTAssertNil(savedWorldDestructiveAccessibilityID(
            kind: "delete", screenIdentity: 0, actionGeneration: 9,
            leaseToken: 11, requestIdentity: a))
    }

    func testSavedWorldNameEscapingSeededControlsAndFormattingMarkers() {
        var state: UInt64 = 0x5eed_cafe_f00d_beef
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        for _ in 0..<2_000 {
            var scalars: [UnicodeScalar] = []
            for _ in 0..<64 {
                let choices: [UInt32] = [
                    UInt32(next() % 0x20), 0x7F, 0x00A7,
                    0x80 + UInt32(next() % 0x20),
                    0x2028, 0x2029, 0x202A + UInt32(next() % 5),
                    0x2066 + UInt32(next() % 4), 0x200B, 0xFEFF,
                    0x20 + UInt32(next() % 0x5F),
                    0x80 + UInt32(next() % 0x700),
                    0x1F300 + UInt32(next() % 0x100),
                ]
                if let scalar = UnicodeScalar(choices[Int(next() % UInt64(choices.count))]) {
                    scalars.append(scalar)
                }
            }
            let escaped = savedWorldDisplayName(String(String.UnicodeScalarView(scalars)))
            XCTAssertFalse(escaped.unicodeScalars.contains { scalar in
                scalar.value == 0x00A7 || scalar.value < 0x20
                    || (0x7F...0x9F).contains(scalar.value)
                    || scalar.value == 0x2028 || scalar.value == 0x2029
                    || scalar.properties.generalCategory == .format
            })
            XCTAssertLessThanOrEqual(escaped.utf8.count, 512)
            XCTAssertFalse(escaped.isEmpty)
        }
        XCTAssertEqual(savedWorldDisplayName("§\n\t"), "\\u{00A7}\\u{000A}\\u{0009}")
        XCTAssertEqual(
            savedWorldDisplayName("a\u{202E}b\u{2067}c\u{2028}d\u{0085}e\u{FEFF}"),
            "a\\u{202E}b\\u{2067}c\\u{2028}d\\u{0085}e\\u{FEFF}")
    }

    func testProductionCheckedAccumulatorAcceptsCapAndRejectsCapPlusOneAndOverflow() throws {
        XCTAssertEqual(StorageWorldBatchCheckedAccumulator.authorityStatementTemplates, 7)
        XCTAssertEqual(StorageWorldBatchCheckedAccumulator.deleteStatementTemplates, 6)
        XCTAssertEqual(try StorageWorldBatchCheckedAccumulator.statementTemplateCount(
            deleteTemplateCount: 6), 13)
        XCTAssertThrowsError(try StorageWorldBatchCheckedAccumulator.statementTemplateCount(
            deleteTemplateCount: 5))
        XCTAssertThrowsError(try StorageWorldBatchCheckedAccumulator.statementTemplateCount(
            deleteTemplateCount: 7))
        XCTAssertEqual(try StorageWorldBatchCheckedAccumulator.worldAggregate(
            0, adding: 67_108_863), 67_108_863)
        XCTAssertEqual(try StorageWorldBatchCheckedAccumulator.worldAggregate(
            67_108_863, adding: 1), 67_108_864)
        XCTAssertThrowsError(try StorageWorldBatchCheckedAccumulator.worldAggregate(
            67_108_864, adding: 1))
        XCTAssertThrowsError(try StorageWorldBatchCheckedAccumulator.adding(
            Int.max, 1, maximum: Int.max))

        XCTAssertEqual(try StorageWorldBatchCheckedAccumulator.chunkRows(
            1_048_574), 1_048_575)
        XCTAssertEqual(try StorageWorldBatchCheckedAccumulator.chunkRows(
            1_048_575), 1_048_576)
        XCTAssertThrowsError(try StorageWorldBatchCheckedAccumulator.chunkRows(1_048_576))

        XCTAssertEqual(try StorageWorldBatchCheckedAccumulator.statementWork(
            requestCount: 4_095), 53_235)
        XCTAssertEqual(try StorageWorldBatchCheckedAccumulator.statementWork(
            requestCount: 4_096), 53_248)
        XCTAssertThrowsError(try StorageWorldBatchCheckedAccumulator.statementWork(
            requestCount: 4_097))
        XCTAssertThrowsError(try StorageWorldBatchCheckedAccumulator.statementWork(
            requestCount: Int.max))
    }

    func testReusableStatementResetAndClearBindingFaultsRollbackFirstMiddleAndFinal() throws {
        let stages: [ElysiumStorageRPGLocalFailureStage] = [
            .reset(statement: 0, requestIndex: 0),
            .reset(statement: 3, requestIndex: 1),
            .reset(statement: 5, requestIndex: 2),
            .clearBindings(statement: 0, requestIndex: 0),
            .clearBindings(statement: 3, requestIndex: 1),
            .clearBindings(statement: 5, requestIndex: 2),
        ]
        for (index, stage) in stages.enumerated() {
            let url = databaseURL("reuse-fault-\(index)")
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let core = try coordinator.legacyCore()
            for id in ["a", "b", "c", "survivor"] {
                try core.putWorldRow(world(id, lastPlayed: 1))
            }
            let checkedRequest = try request(core, ids: ["a", "b", "c"])
            try coordinator._testSetRPGLocalFailure(
                operation: .worldDelete, stage: stage)
            XCTAssertEqual(core.deleteWorldsChecked(checkedRequest),
                           .provenPrecommitFailure, "\(stage)")
            XCTAssertEqual(try scalar(url, "SELECT count(*) FROM worlds"), 4)
            try coordinator.close()
        }
    }

    func testAmbiguousRecoveryIsReadOnlyRepeatedAndClassifiesExactPostAndPre() throws {
        do {
            let url = databaseURL("terminal-post")
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let core = try coordinator.legacyCore()
            try core.putWorldRow(world("target", lastPlayed: 1))
            try core.putWorldRow(world("survivor", lastPlayed: 2))
            let checkedRequest = try request(core, ids: ["target"])
            try coordinator._testSetRPGLocalFailure(
                operation: .worldDelete,
                stage: .afterCommitAuthorityMutation(worldID: "survivor"))
            guard case .terminalRecovery(let authority) =
                    core.deleteWorldsChecked(checkedRequest) else {
                return XCTFail("expected terminal recovery authority")
            }
            XCTAssertNil(try core.getWorldRow(id: "target"))
            for _ in 0..<3 {
                XCTAssertEqual(core.recoverWorldsChecked(authority),
                               .terminalRecovery(authority))
                XCTAssertNil(try core.getWorldRow(id: "target"),
                             "read-only recovery must not re-delete")
            }
            try execute(url, "UPDATE worlds SET lastPlayed=2.0 WHERE id='survivor'")
            guard case .recovered(let receipt) = core.recoverWorldsChecked(authority) else {
                return XCTFail("exact post authority was not recovered")
            }
            XCTAssertEqual(receipt.deletedWorldCount, 1)
            try coordinator.close()
        }

        do {
            let url = databaseURL("terminal-pre")
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let core = try coordinator.legacyCore()
            let target = try world("target", lastPlayed: 1)
            try core.putWorldRow(target)
            try core.putWorldRow(world("survivor", lastPlayed: 2))
            let checkedRequest = try request(core, ids: ["target"])
            try coordinator._testSetRPGLocalFailure(
                operation: .worldDelete,
                stage: .afterCommitAuthorityMutation(worldID: "survivor"))
            guard case .terminalRecovery(let authority) =
                    core.deleteWorldsChecked(checkedRequest) else {
                return XCTFail("expected terminal recovery authority")
            }
            try execute(url, "UPDATE worlds SET lastPlayed=2.0 WHERE id='survivor'")
            try core.putWorldRow(target)
            XCTAssertEqual(core.recoverWorldsChecked(authority), .provenPrecommitFailure)
            XCTAssertNotNil(try core.getWorldRow(id: "target"))
            try coordinator.close()
        }
    }

    @MainActor
    func testGameRecoveryRetiresOnlyExactPostOmissionsAndPreservesPreAndUnresolved() throws {
        let url = databaseURL("game-recovery-post")
        let db = try SaveDB.open(databaseURL: url, migrateLegacy: false)
        let game = GameCore(db: db)
        db.putWorld(worldRecord("target", lastPlayed: 1))
        db.putWorld(worldRecord("survivor", lastPlayed: 2))
        game._testInstallSavedWorldOmission(worldID: "target")
        game._testInstallSavedWorldOmission(worldID: "unrelated")
        let request = try game.checkedWorldSnapshot().deleteRequest(selectedIDs: ["target"])
        let token = try XCTUnwrap(game.acquireSavedWorldMaintenance())
        let operation = try admittedOperation(game, token: token, request: request)
        try db._testSetSavedWorldDeleteFailure(
            .afterCommitAuthorityMutation(worldID: "survivor"))
        guard case .terminalRecovery(let authority) =
                finish(game, operation: operation, outcome: operation.execute()) else {
            return XCTFail("expected terminal recovery authority")
        }
        XCTAssertTrue(game.revalidateSavedWorldMaintenance(token),
                      "screen retirement must leave admitted ambiguity leased")
        XCTAssertTrue(game._testHasSavedWorldOmission(worldID: "target"))
        let forged = SavedWorldDeleteRecoveryAuthority(
            handleID: authority.handleID,
            requestIdentity: authority.requestIdentity,
            selectedWorldIDs: ["unrelated"])
        XCTAssertEqual(db.recoverWorldsChecked(forged), .terminalIntegrity)
        XCTAssertTrue(game._testHasSavedWorldOmission(worldID: "target"))
        XCTAssertTrue(game._testHasSavedWorldOmission(worldID: "unrelated"))
        for _ in 0..<2 {
            XCTAssertEqual(finish(
                game, operation: operation, outcome: operation.recover()),
                .terminalRecovery(authority))
        }
        XCTAssertTrue(game._testHasSavedWorldOmission(worldID: "target"))

        let foreignURL = databaseURL("game-recovery-foreign")
        let foreignDB = try SaveDB.open(databaseURL: foreignURL, migrateLegacy: false)
        let foreignGame = GameCore(db: foreignDB)
        foreignDB.putWorld(worldRecord("foreign", lastPlayed: 3))
        let foreignBefore = try foreignGame.checkedWorldSnapshot().authoritySnapshot
        XCTAssertEqual(foreignDB.recoverWorldsChecked(authority), .terminalIntegrity)
        XCTAssertEqual(try foreignGame.checkedWorldSnapshot().authoritySnapshot, foreignBefore,
                       "cross-SaveDB recovery must be terminal and mutation-free")
        try foreignDB.close()

        try execute(url, "UPDATE worlds SET lastPlayed=2.0 WHERE id='survivor'")
        let recovered = operation.recover()
        guard case .recovered = finish(game, operation: operation, outcome: recovered) else {
            return XCTFail("exact post did not recover")
        }
        XCTAssertEqual(operation.recover(), .terminalIntegrity,
                       "a resolved handle is one-shot and cannot be replayed")
        XCTAssertFalse(game._testHasSavedWorldOmission(worldID: "target"))
        XCTAssertTrue(game._testHasSavedWorldOmission(worldID: "unrelated"))
        XCTAssertTrue(game.revalidateSavedWorldMaintenance(token))
        game.releaseSavedWorldMaintenance(token)
        XCTAssertFalse(game.revalidateSavedWorldMaintenance(token))
        try db.close()

        let preURL = databaseURL("game-recovery-pre")
        let preDB = try SaveDB.open(databaseURL: preURL, migrateLegacy: false)
        let preGame = GameCore(db: preDB)
        let target = worldRecord("target", lastPlayed: 1)
        preDB.putWorld(target)
        preDB.putWorld(worldRecord("survivor", lastPlayed: 2))
        preGame._testInstallSavedWorldOmission(worldID: "target")
        let preRequest = try preGame.checkedWorldSnapshot()
            .deleteRequest(selectedIDs: ["target"])
        let preToken = try XCTUnwrap(preGame.acquireSavedWorldMaintenance())
        let preOperation = try admittedOperation(
            preGame, token: preToken, request: preRequest)
        try preDB._testSetSavedWorldDeleteFailure(
            .afterCommitAuthorityMutation(worldID: "survivor"))
        guard case .terminalRecovery =
                finish(preGame, operation: preOperation,
                       outcome: preOperation.execute()) else {
            return XCTFail("expected pre authority")
        }
        try execute(preURL, "UPDATE worlds SET lastPlayed=2.0 WHERE id='survivor'")
        preDB.putWorld(target)
        let preOutcome = preOperation.recover()
        XCTAssertEqual(finish(preGame, operation: preOperation, outcome: preOutcome),
                       .provenPrecommitFailure)
        XCTAssertTrue(preGame._testHasSavedWorldOmission(worldID: "target"))
        preGame.releaseSavedWorldMaintenance(preToken)
        try preDB.close()
    }

    func testRecoveryAuthorityIsRestartStaleAndMutationFree() throws {
        let url = databaseURL("game-recovery-restart")
        var authority: SavedWorldDeleteRecoveryAuthority?
        do {
            let db = try SaveDB.open(databaseURL: url, migrateLegacy: false)
            let game = GameCore(db: db)
            db.putWorld(worldRecord("target", lastPlayed: 1))
            db.putWorld(worldRecord("survivor", lastPlayed: 2))
            let request = try game.checkedWorldSnapshot().deleteRequest(selectedIDs: ["target"])
            let token = try XCTUnwrap(game.acquireSavedWorldMaintenance())
            let operation = try admittedOperation(game, token: token, request: request)
            try db._testSetSavedWorldDeleteFailure(
                .afterCommitAuthorityMutation(worldID: "survivor"))
            guard case .terminalRecovery(let retained) =
                    finish(game, operation: operation, outcome: operation.execute()) else {
                return XCTFail("expected terminal recovery authority")
            }
            authority = retained
            try execute(url, "UPDATE worlds SET lastPlayed=2.0 WHERE id='survivor'")
            try db.close()
        }

        let restarted = try SaveDB.open(databaseURL: url, migrateLegacy: false)
        let restartedGame = GameCore(db: restarted)
        let before = try restartedGame.checkedWorldSnapshot().authoritySnapshot
        XCTAssertEqual(restarted.recoverWorldsChecked(try XCTUnwrap(authority)),
                       .terminalIntegrity)
        XCTAssertEqual(try restartedGame.checkedWorldSnapshot().authoritySnapshot, before,
                       "process/session-stale recovery must not mutate authority")
        try restarted.close()
    }

    func testTerminalRecoveryNeverBootstrapsMissingRPGLocalSchema() throws {
        let url = databaseURL("recovery-schema-absent")
        let db = try SaveDB.open(databaseURL: url, migrateLegacy: false)
        let game = GameCore(db: db)
        db.putWorld(worldRecord("target", lastPlayed: 1))
        db.putWorld(worldRecord("survivor", lastPlayed: 2))
        game._testInstallSavedWorldOmission(worldID: "target")
        game._testInstallSavedWorldOmission(worldID: "unrelated")
        let request = try game.checkedWorldSnapshot().deleteRequest(selectedIDs: ["target"])
        let token = try XCTUnwrap(game.acquireSavedWorldMaintenance())
        let operation = try admittedOperation(game, token: token, request: request)
        try db._testSetSavedWorldDeleteFailure(
            .afterCommitAuthorityMutation(worldID: "survivor"))
        guard case .terminalRecovery(let authority) =
                finish(game, operation: operation, outcome: operation.execute()) else {
            return XCTFail("expected terminal recovery authority")
        }

        try execute(url, """
            DROP TABLE rpg_local_preference_migrations_v1;
            DROP TABLE rpg_local_preferences_v1;
            DROP TABLE pebble_storage_component_schema_v1;
            """)
        let before = try db._testSavedWorldRecoverySideEffectSnapshot()
        XCTAssertEqual(before.rpgLocalSchemaObjects, [])
        XCTAssertTrue(before.authorizationIsDenyAll)
        XCTAssertFalse(before.authorizationDenied)

        for _ in 0..<4 {
            XCTAssertEqual(finish(
                game, operation: operation, outcome: operation.recover()),
                .terminalRecovery(authority))
            XCTAssertTrue(game.revalidateSavedWorldMaintenance(token))
            XCTAssertTrue(game._testHasSavedWorldOmission(worldID: "target"))
            XCTAssertTrue(game._testHasSavedWorldOmission(worldID: "unrelated"))
        }

        let after = try db._testSavedWorldRecoverySideEffectSnapshot()
        XCTAssertEqual(after, before,
                       "classification-only recovery must not change schema, rows, or authorization")
        XCTAssertEqual(try scalar(url, """
            SELECT count(*) FROM sqlite_master WHERE name IN (
              'pebble_storage_component_schema_v1',
              'rpg_local_preferences_v1',
              'rpg_local_preference_migrations_v1')
            """), 0)
        game.releaseSavedWorldMaintenance(token)
        try db.close()
    }

    func testTerminalRecoveryRejectsPartialAndCorruptRPGSchemaWithoutSideEffects() throws {
        for scenario in 0..<2 {
            let url = databaseURL("recovery-schema-invalid-\(scenario)")
            let db = try SaveDB.open(databaseURL: url, migrateLegacy: false)
            let game = GameCore(db: db)
            db.putWorld(worldRecord("target", lastPlayed: 1))
            db.putWorld(worldRecord("survivor", lastPlayed: 2))
            game._testInstallSavedWorldOmission(worldID: "target")
            let request = try game.checkedWorldSnapshot()
                .deleteRequest(selectedIDs: ["target"])
            let token = try XCTUnwrap(game.acquireSavedWorldMaintenance())
            let operation = try admittedOperation(
                game, token: token, request: request)
            try db._testSetSavedWorldDeleteFailure(
                .afterCommitAuthorityMutation(worldID: "survivor"))
            guard case .terminalRecovery(let authority) =
                    finish(game, operation: operation, outcome: operation.execute()) else {
                return XCTFail("expected terminal authority for scenario \(scenario)")
            }

            if scenario == 0 {
                try execute(url, "DROP TABLE rpg_local_preference_migrations_v1")
            } else {
                try execute(url, """
                    DROP TABLE rpg_local_preferences_v1;
                    CREATE TABLE rpg_local_preferences_v1(world TEXT PRIMARY KEY);
                    """)
            }
            let before = try db._testSavedWorldRecoverySideEffectSnapshot()
            for _ in 0..<3 {
                XCTAssertEqual(finish(
                    game, operation: operation, outcome: operation.recover()),
                    .terminalRecovery(authority))
                XCTAssertTrue(game.revalidateSavedWorldMaintenance(token))
                XCTAssertTrue(game._testHasSavedWorldOmission(worldID: "target"))
            }
            XCTAssertEqual(try db._testSavedWorldRecoverySideEffectSnapshot(), before,
                           "verify-only recovery changed partial/corrupt schema state")
            game.releaseSavedWorldMaintenance(token)
            try db.close()
        }
    }

    func testIdentifierAndRequestCountCapsAndPermutationRejection() throws {
        for count in [255, 256] {
            let url = databaseURL("id-\(count)")
            let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
            let core = try coordinator.legacyCore()
            let id = String(repeating: "a", count: count)
            try core.putWorldRow(ElysiumWorldStorageRow(id: id, json: "{}", lastPlayed: 1))
            XCTAssertEqual(try core.checkedWorldSnapshot().rows.first?.storedID, id)
            try coordinator.close()
        }
        let url = databaseURL("id-257")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        try core.putWorldRow(ElysiumWorldStorageRow(
            id: String(repeating: "a", count: 257), json: "{}", lastPlayed: 1))
        XCTAssertThrowsError(try core.checkedWorldSnapshot())
        try coordinator.close()

        let expectations = try (0..<4_096).map { index in
            try ElysiumWorldBatchDeleteExpectation(
                storedID: String(format: "w%04d", index),
                rowDigest: Data(repeating: UInt8(truncatingIfNeeded: index), count: 32))
        }
        XCTAssertNoThrow(try ElysiumWorldBatchDeleteRequest(
            expectedCollectionDigest: Data(repeating: 1, count: 32),
            expectations: expectations))
        XCTAssertThrowsError(try ElysiumWorldBatchDeleteRequest(
            expectedCollectionDigest: Data(repeating: 1, count: 32),
            expectations: expectations + [try ElysiumWorldBatchDeleteExpectation(
                storedID: "z-overflow", rowDigest: Data(repeating: 1, count: 32))]))
        XCTAssertThrowsError(try ElysiumWorldBatchDeleteRequest(
            expectedCollectionDigest: Data(repeating: 1, count: 32),
            expectations: Array(expectations.prefix(2).reversed())))
    }

    func testInvalidUTF8AndStorageCorruptionProduceTerminalOutcomeWithoutMutation() throws {
        let url = databaseURL("terminal-corrupt")
        let coordinator = try ElysiumStorageCoordinator.open(databaseURL: url)
        let core = try coordinator.legacyCore()
        try core.putWorldRow(world("target", lastPlayed: 1))
        let checkedRequest = try request(core, ids: ["target"])
        try execute(url, """
            PRAGMA ignore_check_constraints=ON;
            UPDATE worlds SET lastPlayed='corrupt' WHERE id='target';
            """)
        XCTAssertEqual(core.deleteWorldsChecked(checkedRequest), .terminalIntegrity)
        XCTAssertEqual(try scalar(url, "SELECT count(*) FROM worlds WHERE id='target'"), 1)
        try coordinator.close()

        let utfURL = databaseURL("invalid-utf8")
        let utfCoordinator = try ElysiumStorageCoordinator.open(databaseURL: utfURL)
        _ = try utfCoordinator.legacyCore()
        try execute(utfURL, """
            PRAGMA ignore_check_constraints=ON;
            INSERT INTO worlds(id,json,lastPlayed) VALUES(CAST(x'80' AS TEXT),'{}',1.0);
            """)
        XCTAssertThrowsError(try utfCoordinator.legacyCore().checkedWorldSnapshot())
        try utfCoordinator.close()
    }

    func testPointerKeyboardAndAXSourceContractsRemainExplicit() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let menus = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/MenusM.swift"), encoding: .utf8)
        let ui = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/UIManagerM.swift"), encoding: .utf8)
        let bridge = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/TextEntryAccessibilityM.swift"), encoding: .utf8)
        let main = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/main.swift"), encoding: .utf8)
        let saves = try String(contentsOf: root.appendingPathComponent(
            "Sources/ElysiumCore/Game/Saves.swift"), encoding: .utf8)
        let selection = try String(contentsOf: root.appendingPathComponent(
            "Sources/ElysiumCore/Game/SavedWorldSelection.swift"), encoding: .utf8)
        let gameCore = try String(contentsOf: root.appendingPathComponent(
            "Sources/ElysiumCore/Game/GameCore.swift"), encoding: .utf8)
        let storage = try String(contentsOf: root.appendingPathComponent(
            "Sources/ElysiumStorage/StorageEngine.swift"), encoding: .utf8)
        let lan = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/LANTransport.swift"), encoding: .utf8)

        XCTAssertTrue(main.contains("eventType: event.type"))
        XCTAssertTrue(main.contains("clickCount: event.clickCount"))
        XCTAssertTrue(main.contains("appKitButtonNumber: event.buttonNumber"))
        XCTAssertTrue(main.contains("windowNumber: event.windowNumber"))
        XCTAssertTrue(main.contains("eventNumber: event.eventNumber"))
        XCTAssertTrue(main.contains("modifierFlags: event.modifierFlags"))
        XCTAssertTrue(ui.contains("clickCount == 2"))
        XCTAssertTrue(ui.contains("current.eventNumber == event.eventNumber"))
        XCTAssertTrue(ui.contains("current.windowNumber == event.windowNumber"))
        XCTAssertTrue(ui.contains("current.buttonNumber == event.appKitButtonNumber"))
        XCTAssertTrue(ui.contains("current.type == event.eventType"))
        XCTAssertTrue(ui.contains("canonicalDownType("))
        XCTAssertTrue(ui.contains("canonicalElysiumButton("))
        XCTAssertTrue(ui.contains("window.isKeyWindow"))
        XCTAssertTrue(ui.contains("NSApp.isActive"))
        XCTAssertTrue(ui.contains("!command && !shift && !option && !control"))
        let keyStart = try XCTUnwrap(menus.range(of:
            "if key == \"Delete\" || key == \"Backspace\""))
        let keyTail = menus[keyStart.lowerBound...]
        let keyEnd = try XCTUnwrap(keyTail.range(of: "if handleModalKey"))
        let deleteBlock = String(keyTail[..<keyEnd.lowerBound])
        XCTAssertFalse(deleteBlock.contains("beginDeletePrecheck"))
        XCTAssertTrue(deleteBlock.contains("return true"))

        XCTAssertTrue(menus.contains("savedWorldDestructiveAccessibilityID("))
        XCTAssertTrue(menus.contains("renewTextAccessibilityPresentation"))
        XCTAssertTrue(menus.contains(
            "if !destructiveAdmissionAccepted { releaseMaintenanceLease() }"))
        XCTAssertTrue(menus.contains("deferredOutcome = outcome"))
        XCTAssertTrue(menus.contains(
            "publishPhase(.terminal(request, names, authority, true)"))
        XCTAssertTrue(ui.contains("MainActor.preconditionIsolated()"))
        XCTAssertTrue(ui.contains("MainActor.assumeIsolated(body)"))
        XCTAssertTrue(bridge.contains("elements.contains(where: { $0 === element })"))
        XCTAssertTrue(bridge.contains("$0.id == element.descriptor.id && $0.enabled && $0.actionable"))
        XCTAssertTrue(bridge.contains("presentationGeneration: screen.textPresentationGeneration"))

        let authorityStart = try XCTUnwrap(selection.range(
            of: "public struct SavedWorldDeleteRecoveryAuthority"))
        let authorityTail = selection[authorityStart.lowerBound...]
        let authorityEnd = try XCTUnwrap(authorityTail.range(
            of: "public enum SavedWorldDeleteOutcome"))
        let authorityBlock = String(authorityTail[..<authorityEnd.lowerBound])
        XCTAssertFalse(authorityBlock.contains("public let"))
        XCTAssertFalse(authorityBlock.contains("Codable"))
        XCTAssertTrue(authorityBlock.contains("let handleID: UUID"))

        func boundedSlice(_ source: String, from start: String, to end: String) throws -> String {
            let startRange = try XCTUnwrap(source.range(of: start))
            let tail = source[startRange.lowerBound...]
            let endRange = try XCTUnwrap(tail.range(of: end))
            return String(tail[..<endRange.lowerBound])
        }
        let pointerAction = try boundedSlice(
            menus, from: "override func onPointerDown", to: "override func onKeyEvent")
        let consumeOffset = try XCTUnwrap(pointerAction.range(
            of: "openingPointerEvents.consume")).lowerBound
        XCTAssertLessThan(consumeOffset, try XCTUnwrap(pointerAction.range(
            of: "handleModalPointer")).lowerBound)
        XCTAssertLessThan(consumeOffset, try XCTUnwrap(pointerAction.range(
            of: "super.onPointerDown")).lowerBound)
        XCTAssertTrue(pointerAction.contains("commitSelectionMutation(ui: ui, game: game)"))

        let selectionCommit = try boundedSlice(
            menus, from: "private func commitSelectionMutation(", to: "private var isReady")
        XCTAssertTrue(selectionCommit.contains("let previous = selection"))
        XCTAssertTrue(selectionCommit.contains(
            "guard selection != previous else { return false }"))
        XCTAssertEqual(selectionCommit.components(separatedBy:
            "ui.renewTextAccessibilityPresentation(screen: self, game: game)").count - 1, 1)

        let controls = try boundedSlice(
            menus, from: "private func installControls(",
            to: "/// The sole user-selection commit boundary")
        XCTAssertGreaterThanOrEqual(controls.components(separatedBy:
            "[weak self, weak ui, weak game]").count - 1, 2)
        XCTAssertEqual(controls.components(separatedBy:
            "commitSelectionMutation(ui: ui, game: game)").count - 1, 2)

        let keyboardAction = try boundedSlice(
            menus, from: "override func onKeyEvent", to: "override func onClose")
        XCTAssertGreaterThanOrEqual(keyboardAction.components(separatedBy:
            "commitSelectionMutation").count - 1, 4)

        let axFocus = try boundedSlice(
            menus, from: "override func focusTextAccessibilityElement",
            to: "override func performTextAccessibilityAction")
        XCTAssertTrue(axFocus.contains("$0.focus(id: row.storedID)"))
        XCTAssertFalse(axFocus.contains("selection.select("))
        XCTAssertTrue(axFocus.contains("commitSelectionMutation("))

        let axAction = try boundedSlice(
            menus, from: "override func performTextAccessibilityAction",
            to: "private func worldAccessibilityID")
        XCTAssertGreaterThanOrEqual(axAction.components(separatedBy:
            "commitSelectionMutation(ui: ui, game: game)").count - 1, 2)
        XCTAssertTrue(axAction.contains("id == accessibility.bulkActionID"))
        XCTAssertTrue(bridge.contains("elements.forEach { $0.retire() }"))
        XCTAssertTrue(bridge.contains("!element.retired"))
        XCTAssertTrue(bridge.contains("elements.contains(where: { $0 === element })"))

        let operation = try boundedSlice(
            selection, from: "public final class SavedWorldDeleteOperation",
            to: "public func savedWorldDeleteRequestIdentity")
        XCTAssertFalse(operation.contains("GameCore"))
        XCTAssertTrue(operation.contains("private let db: SaveDB"))
        XCTAssertTrue(gameCore.contains("@MainActor\n    public func admitSavedWorldDelete("))

        for (start, end, networkConstructor) in [
            ("func startBrowsing(game: GameCore)", "func connectToDiscovered(", "NWBrowser("),
            ("func connectToDiscovered(", "func directConnect(", "NWConnection(to:"),
            ("func directConnect(", "func sendChat(", "NWConnection(host:"),
        ] {
            let admission = try boundedSlice(lan, from: start, to: end)
            XCTAssertTrue(admission.contains(
                "guard game.savedWorldMaintenanceAllowsTransitions()"))
            let guardOffset = try XCTUnwrap(admission.range(
                of: "guard game.savedWorldMaintenanceAllowsTransitions()")).lowerBound
            let constructorOffset = try XCTUnwrap(admission.range(of: networkConstructor)).lowerBound
            XCTAssertLessThan(guardOffset, constructorOffset,
                              "LAN lease guard must run before \(networkConstructor)")
        }
        let menuMaintenance = try boundedSlice(
            menus, from: "private func beginDeletePrecheck", to: "private func worldAccessibilityID")
        let saveMaintenance = try boundedSlice(
            saves, from: "public func deleteWorldsChecked(", to: "public func getWorld(")
        let storageDelete = try boundedSlice(
            storage, from: "public func deleteWorldsChecked(", to: "public func recoverWorldsChecked(")
        let storageRecovery = try boundedSlice(
            storage, from: "public func recoverWorldsChecked(", to: "public func getWorldRow(")
        XCTAssertFalse(storageDelete.contains("readRPGLocalAccounting(context)"))
        XCTAssertTrue(storageDelete.contains("statementTemplateCount("))

        let resize = try boundedSlice(
            ui, from: "func resize(", to: "func retainSavedWorldMaintenanceOperation(")
        XCTAssertTrue(resize.contains("s.relayoutScreen(self, game)"))
        XCTAssertFalse(resize.contains("s.initScreen(self, game)"))
        let relayout = try boundedSlice(
            menus, from: "override func relayoutScreen(",
            to: "/// Layout-only control reconstruction")
        XCTAssertTrue(relayout.contains("installControls(ui, game)"))
        let install = try boundedSlice(
            menus, from: "private func installControls(", to: "private var isReady")
        for phase in ["Precheck", "Confirmation", "Deleting", "Terminal", "Terminal Reload"] {
            for forbidden in [
                "phase =", "selection =", "selection.refresh(",
                "keyboardFocus =", "modalFocus =",
                "operationGeneration", "activeDeleteOperation", "deferredOutcome",
                "maintenanceToken", "releaseMaintenanceLease", "reload(",
                "checkedWorldSnapshot", "DispatchQueue", "admitSavedWorldDelete",
                "retainSavedWorldMaintenanceOperation",
            ] {
                XCTAssertFalse(install.contains(forbidden),
                               "resize during \(phase) mutates invariant via \(forbidden)")
            }
        }
        XCTAssertTrue(menus.contains(
            "destructiveAccessibilityID(\"terminalReload\", request: request)"))
        XCTAssertTrue(menus.contains(
            "id == destructiveAccessibilityID(\"terminalReload\", request: request)"))

        let outcomeReducer = try boundedSlice(
            menus, from: "private func claimOutcomeIfCurrent(", to: "private func maxScroll")
        for required in [
            "ui.current() === self", "maintenanceToken == token",
            "activeDeleteOperation === operation", "savedWorldOutcomeReductionMatches(",
            "currentRequest.expectations == request.expectations",
            "game.revalidateSavedWorldMaintenance(token)",
            "game.finishSavedWorldDeleteOperation(", "preserveUnclaimedOutcome(",
        ] {
            XCTAssertTrue(outcomeReducer.contains(required),
                          "outcome reducer lost exact check: \(required)")
        }
        let matchOffset = try XCTUnwrap(outcomeReducer.range(
            of: "savedWorldOutcomeReductionMatches(")).lowerBound
        let claimOffset = try XCTUnwrap(outcomeReducer.range(
            of: "game.finishSavedWorldDeleteOperation(")).lowerBound
        XCTAssertLessThan(matchOffset, claimOffset,
                          "operation result was claimed before live UI validation")
        XCTAssertEqual(menus.components(
            separatedBy: "game.finishSavedWorldDeleteOperation(").count - 1, 1)
        XCTAssertTrue(menus.contains("deferredOutcome = outcome"))
        XCTAssertTrue(menus.contains(
            "publishPhase(.terminal(request, names, authority, true)"))
        let forbiddenExternalActivity = [
            "URLSession", "NWConnection", "NWListener", "Bonjour", "Ollama",
            "SecItem", "Keychain", "NSPasteboard", "Process(", "Telemetry",
            "pushChat(", "print(", "os_log(", "Logger(",
        ]
        for sourceSlice in [menuMaintenance, saveMaintenance, storageDelete, storageRecovery] {
            for forbidden in forbiddenExternalActivity {
                XCTAssertFalse(sourceSlice.contains(forbidden),
                               "saved-world maintenance introduced external activity: \(forbidden)")
            }
        }
    }
}
