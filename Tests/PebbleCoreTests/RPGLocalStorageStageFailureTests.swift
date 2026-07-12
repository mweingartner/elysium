import XCTest
import Foundation
@testable import PebbleStorage

final class RPGLocalStorageStageFailureTests: XCTestCase {
    private func databaseURL(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "PebbleRPGStage-\(label)-\(UUID().uuidString).sqlite")
    }

    private func preference() throws -> PebbleRPGLocalPreferenceStorageRow {
        try PebbleRPGLocalPreferenceStorageRow(
            worldRecordID: "world", schemaVersion: 1, revision: 1,
            slotsPayload: Data(repeating: 0x41, count: 18),
            payloadDigest: Data(repeating: 0x42, count: 32),
            migrationOriginDigest: nil, migrationOriginRevision: nil)
    }

    private func fixture(_ label: String, migrated: Bool)
        throws -> (PebbleStorageCoordinator, PebbleRPGLocalPreferencesStorage) {
        let coordinator = try PebbleStorageCoordinator.open(databaseURL: databaseURL(label))
        try coordinator.legacyCore().putWorldRow(
            PebbleWorldStorageRow(id: "world", json: "{}", lastPlayed: 0))
        let facade = try coordinator.rpgLocalPreferences()
        if migrated {
            _ = try facade.materializeLegacy(
                sourceDigest: Data(repeating: 0x43, count: 32),
                absentDestination: preference())
        }
        return (coordinator, facade)
    }

    private var materializationRollbackStages: [PebbleStorageRPGLocalFailureStage] {
        var stages: [PebbleStorageRPGLocalFailureStage] = [.begin]
        for statement in 0..<3 {
            stages += [
                .prepare(statement: statement), .bind(statement: statement),
                .step(statement: statement), .changes(statement: statement),
                .finalize(statement: statement),
            ]
        }
        stages += [.postcondition, .commit]
        return stages
    }

    private var worldDeleteRollbackStages: [PebbleStorageRPGLocalFailureStage] {
        var stages: [PebbleStorageRPGLocalFailureStage] = [.begin]
        for statement in 0..<6 {
            stages += [
                .prepare(statement: statement), .bind(statement: statement),
                .step(statement: statement), .changes(statement: statement),
                .finalize(statement: statement),
            ]
        }
        stages += [.postcondition, .commit]
        return stages
    }

    func testLegacyMaterializationEveryScopedPrecommitStageRollsBack() throws {
        for (index, stage) in materializationRollbackStages.enumerated() {
            let (coordinator, facade) = try fixture("materialize-\(index)", migrated: false)
            try coordinator._testSetRPGLocalFailure(
                operation: .legacyMaterialization, stage: stage)
            XCTAssertThrowsError(try facade.materializeLegacy(
                sourceDigest: Data(repeating: 0x43, count: 32),
                absentDestination: preference()), "\(stage)")
            XCTAssertNil(try facade.read(worldRecordID: "world"), "\(stage)")
            try coordinator.close()
        }
    }

    func testLegacyMaterializationAfterCommitCutIsDurableAndIdempotent() throws {
        let (coordinator, facade) = try fixture("materialize-after-commit", migrated: false)
        try coordinator._testSetRPGLocalFailure(
            operation: .legacyMaterialization, stage: .afterCommitBeforePublication)
        XCTAssertThrowsError(try facade.materializeLegacy(
            sourceDigest: Data(repeating: 0x43, count: 32),
            absentDestination: preference()))
        let stored = try XCTUnwrap(facade.read(worldRecordID: "world"))
        XCTAssertEqual(stored.migrationOriginDigest, Data(repeating: 0x42, count: 32))
        let replay = try facade.materializeLegacy(
            sourceDigest: Data(repeating: 0x43, count: 32),
            absentDestination: preference())
        XCTAssertFalse(replay.insertedDestination)
        try coordinator.close()
    }

    func testWorldDeleteEveryScopedPrecommitStageRollsBack() throws {
        for (index, stage) in worldDeleteRollbackStages.enumerated() {
            let (coordinator, facade) = try fixture("delete-\(index)", migrated: true)
            try coordinator._testSetRPGLocalFailure(operation: .worldDelete, stage: stage)
            XCTAssertThrowsError(try coordinator.legacyCore().deleteWorld(id: "world"), "\(stage)")
            XCTAssertNotNil(try coordinator.legacyCore().getWorldRow(id: "world"), "\(stage)")
            XCTAssertNotNil(try facade.read(worldRecordID: "world"), "\(stage)")
            try coordinator.close()
        }
    }

    func testWorldDeleteAfterCommitCutIsDurableAndRestartSafe() throws {
        let databaseURL = databaseURL("delete-after-commit")
        let coordinator = try PebbleStorageCoordinator.open(databaseURL: databaseURL)
        try coordinator.legacyCore().putWorldRow(
            PebbleWorldStorageRow(id: "world", json: "{}", lastPlayed: 0))
        let facade = try coordinator.rpgLocalPreferences()
        _ = try facade.materializeLegacy(
            sourceDigest: Data(repeating: 0x43, count: 32),
            absentDestination: preference())
        try coordinator._testSetRPGLocalFailure(
            operation: .worldDelete, stage: .afterCommitBeforePublication)
        XCTAssertThrowsError(try coordinator.legacyCore().deleteWorld(id: "world"))
        XCTAssertNil(try coordinator.legacyCore().getWorldRow(id: "world"))
        XCTAssertNil(try facade.read(worldRecordID: "world"))
        try coordinator.close()

        let reopened = try PebbleStorageCoordinator.open(databaseURL: databaseURL)
        XCTAssertNil(try reopened.legacyCore().getWorldRow(id: "world"))
        XCTAssertNil(try reopened.rpgLocalPreferences().read(worldRecordID: "world"))
        try reopened.close()
    }
}
