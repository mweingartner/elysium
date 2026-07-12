import XCTest
import Foundation
import CryptoKit
import SQLite3
@testable import PebbleStorage
@testable import PebbleCore

final class LANV6ClientAuthorityCheckpointStorageTests: XCTestCase {
    func testStorageAmendmentDoesNotActivateProtocolV6() {
        XCTAssertEqual(LAN_MULTIPLAYER_PROTOCOL_VERSION, 5)
    }
    private func url(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "PebbleClientCheckpoint-\(label)-\(UUID().uuidString).sqlite")
    }

    private func sha(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
    private func u64(_ value: UInt64) -> Data {
        Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: value >> UInt64($0 * 8)) })
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private func key(hidByte: UInt8 = 1, widByte: UInt8 = 2) throws
        -> PebbleLANClientAuthorityStorageKey {
        let hid = Data(repeating: hidByte, count: 16)
        let wid = Data(repeating: widByte, count: 16)
        var input = Data("Pebble-LAN-v6".utf8); input.append(hid); input.append(wid)
        return try PebbleLANClientAuthorityStorageKey(
            hostInstallationID: hid, worldLANID: wid, lookupDigest: sha(input))
    }
    private func keyBytes(_ key: PebbleLANClientAuthorityStorageKey) -> Data {
        var data = key.hostInstallationID; data.append(key.worldLANID); data.append(key.lookupDigest)
        return data
    }
    private func credentialPayload(token: Data, pending: Bool) -> Data {
        var data = Data("PBLCC1".utf8); data.append(contentsOf: [0, 1, pending ? 2 : 1])
        data.append(u64(1)); data.append(token)
        if pending { data.append(Data(repeating: 3, count: 16)); data.append(u64(1_000)) }
        return data
    }
    private func credentialDigest(key: PebbleLANClientAuthorityStorageKey,
                                  generation: UInt64, payload: Data) -> Data {
        var data = Data("Pebble/LANv6/client-credential/v1\0".utf8)
        data.append(keyBytes(key)); data.append(u64(generation)); data.append(payload)
        return sha(data)
    }
    private func ownerDigest(key: PebbleLANClientAuthorityStorageKey,
                             generation: UInt64, payload: Data) -> Data {
        var data = Data("Pebble/LANv6/client-owner/v1\0".utf8)
        data.append(keyBytes(key)); data.append(u64(generation)); data.append(payload)
        return sha(data)
    }
    private func aggregate(key: PebbleLANClientAuthorityStorageKey, generation: UInt64,
                           credentialDigest: Data,
                           owner: (UInt64, Data)? = nil,
                           pending: (UInt64, Data)? = nil) -> Data {
        var data = Data("Pebble/LANv6/client-checkpoint-aggregate/v1\0".utf8)
        data.append(keyBytes(key)); data.append(u64(generation)); data.append(credentialDigest)
        if let owner { data.append(1); data.append(u64(owner.0)); data.append(owner.1) }
        else { data.append(0) }
        if let pending { data.append(1); data.append(u64(pending.0)); data.append(pending.1) }
        else { data.append(0) }
        return sha(data)
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
    private func scalar(_ url: URL, _ sql: String) throws -> Int64 {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else { throw PebbleStorageError.invalidValue }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw PebbleStorageError.invalidValue }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw PebbleStorageError.invalidValue }
        return sqlite3_column_int64(statement, 0)
    }
    private func bootstrap(_ label: String) throws
        -> (URL, PebbleStorageCoordinator, PebbleClientAuthorityCheckpointV6Storage,
            PebbleLANClientAuthorityStorageKey) {
        let databaseURL = url(label)
        let coordinator = try PebbleStorageCoordinator.open(databaseURL: databaseURL)
        XCTAssertThrowsError(try coordinator.clientAuthorityCheckpointV6())
        try coordinator._testBootstrapClientAuthoritySchemaForAdmission()
        return (databaseURL, coordinator, try coordinator.clientAuthorityCheckpointV6(), try key())
    }
    private func seedPendingCredential(_ url: URL,
                                       key: PebbleLANClientAuthorityStorageKey,
                                       token: Data) throws -> (Data, Data) {
        let payload = credentialPayload(token: token, pending: true)
        let digest = credentialDigest(key: key, generation: 0, payload: payload)
        let aggregateDigest = aggregate(key: key, generation: 0,
                                        credentialDigest: digest)
        try raw(url, """
            INSERT INTO lan_client_credentials_v6(
              hid,wid,lookup_digest,schema_version,aggregate_generation,aggregate_digest,
              authority_bound,payload,payload_digest) VALUES(
              X'\(hex(key.hostInstallationID))',X'\(hex(key.worldLANID))',
              X'\(hex(key.lookupDigest))',1,0,X'\(hex(aggregateDigest))',0,
              X'\(hex(payload))',X'\(hex(digest))')
            """)
        return (digest, aggregateDigest)
    }
    private func firstBindCandidate(key: PebbleLANClientAuthorityStorageKey, token: Data,
                                    oldAggregate: Data) throws
        -> PebbleLANClientAuthorityCheckpointCandidate {
        let credentialPayload = credentialPayload(token: token, pending: false)
        let credentialDigest = credentialDigest(
            key: key, generation: 1, payload: credentialPayload)
        let ownerPayload = Data([7])
        let ownerDigest = ownerDigest(key: key, generation: 1, payload: ownerPayload)
        let aggregateDigest = aggregate(
            key: key, generation: 1, credentialDigest: credentialDigest,
            owner: (1, ownerDigest))
        let credential = try PebbleLANClientCredentialStorageRow(
            key: key, schemaVersion: 1, aggregateGeneration: 1,
            aggregateDigest: aggregateDigest, authorityBound: true,
            payload: credentialPayload, payloadDigest: credentialDigest)
        let owner = try PebbleLANClientOwnerCheckpointStorageRow(
            key: key, schemaVersion: 1, lastChangeGeneration: 1,
            payload: ownerPayload, payloadDigest: ownerDigest)
        return try PebbleLANClientAuthorityCheckpointCandidate(
            key: key, transition: .firstRequestZeroBind,
            expectedAggregateGeneration: 0, expectedAggregateDigest: oldAggregate,
            credential: credential, ownerChange: .set(owner),
            pendingChange: .unchanged, noticeInsert: nil)
    }

    func testPreBootstrapAuthorityFacadeIsUnavailableAndFirstBindIsAtomic() throws {
        let (databaseURL, coordinator, facade, key) = try bootstrap("first-bind")
        let token = Data(repeating: 4, count: 32)
        let (_, oldAggregate) = try seedPendingCredential(databaseURL, key: key, token: token)
        let receipt = try facade.commit(
            firstBindCandidate(key: key, token: token, oldAggregate: oldAggregate))
        XCTAssertEqual(receipt.committedAggregateGeneration, 1)
        XCTAssertTrue(receipt.snapshot.credential.authorityBound)
        XCTAssertNotNil(receipt.snapshot.owner)
        XCTAssertNil(receipt.snapshot.pending)
        try coordinator.close()
    }

    func testAfterAuditTriggerInjectionCannotRunDuringClientCommit() throws {
        let (databaseURL, coordinator, facade, key) = try bootstrap("trigger")
        let token = Data(repeating: 5, count: 32)
        let (_, oldAggregate) = try seedPendingCredential(databaseURL, key: key, token: token)
        try raw(databaseURL, """
            CREATE TRIGGER hostile_client_update AFTER UPDATE ON lan_client_credentials_v6
            BEGIN DELETE FROM lan_client_owner_checkpoint_v6; END
            """)
        XCTAssertThrowsError(try facade.commit(
            firstBindCandidate(key: key, token: token, oldAggregate: oldAggregate)))
        XCTAssertEqual(try facade.load(key: key).credential.aggregateGeneration, 0)
        try coordinator.close()
    }

    func testOldChildGenerationBeyondAnchorFailsBeforeCandidateMutation() throws {
        let (databaseURL, coordinator, facade, key) = try bootstrap("old-child")
        let token = Data(repeating: 6, count: 32)
        let payload = credentialPayload(token: token, pending: false)
        let credentialDigest = credentialDigest(key: key, generation: 1, payload: payload)
        let ownerPayload = Data([8]), ownerDigest = ownerDigest(
            key: key, generation: 2, payload: ownerPayload)
        let aggregateDigest = aggregate(
            key: key, generation: 1, credentialDigest: credentialDigest,
            owner: (2, ownerDigest))
        try raw(databaseURL, """
            INSERT INTO lan_client_credentials_v6 VALUES(
              X'\(hex(key.hostInstallationID))',X'\(hex(key.worldLANID))',X'\(hex(key.lookupDigest))',
              1,1,X'\(hex(aggregateDigest))',1,X'\(hex(payload))',X'\(hex(credentialDigest))');
            INSERT INTO lan_client_owner_checkpoint_v6 VALUES(
              X'\(hex(key.hostInstallationID))',X'\(hex(key.worldLANID))',X'\(hex(key.lookupDigest))',
              1,2,X'\(hex(ownerPayload))',X'\(hex(ownerDigest))')
            """)
        XCTAssertThrowsError(try facade.load(key: key))
        try coordinator.close()
    }

    func testCoreClientAuthorityAdapterIsAbsentUntilReviewedPhase25CodecsExist() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: repository.appendingPathComponent(
            "Sources/PebbleCore/Game/LANV6ClientCheckpointCodec.swift").path))
        let saves = try String(contentsOf: repository.appendingPathComponent(
            "Sources/PebbleCore/Game/Saves.swift"), encoding: .utf8)
        for forbidden in [
            "LANV6ClientAuthoritySaveAdapterV1", "makeCandidate(",
            "clientAuthorityCheckpointV6()",
        ] {
            XCTAssertFalse(saves.contains(forbidden), forbidden)
        }
    }

    func testNoticeAcknowledgementIsOnlyZeroZeroToOneOneAndPreservesPayload() throws {
        let (databaseURL, coordinator, facade, key) = try bootstrap("ack")
        let token = Data(repeating: 0x31, count: 32)
        let credentialPayload = credentialPayload(token: token, pending: false)
        let credentialDigest = credentialDigest(
            key: key, generation: 1, payload: credentialPayload)
        let aggregateDigest = aggregate(
            key: key, generation: 1, credentialDigest: credentialDigest)
        let notificationID = Data(repeating: 0x32, count: 32)
        let epoch = Data(repeating: 0x33, count: 16)
        let snapshotID = Data(repeating: 0x34, count: 16)
        let payload = Data("terminal-payload-sentinel".utf8)
        let payloadDigest = Data(repeating: 0x35, count: 32)
        try raw(databaseURL, """
            INSERT INTO lan_client_credentials_v6 VALUES(
              X'\(hex(key.hostInstallationID))',X'\(hex(key.worldLANID))',
              X'\(hex(key.lookupDigest))',1,1,X'\(hex(aggregateDigest))',1,
              X'\(hex(credentialPayload))',X'\(hex(credentialDigest))');
            INSERT INTO lan_client_notification_inbox_v6 VALUES(
              X'\(hex(key.hostInstallationID))',X'\(hex(key.worldLANID))',
              X'\(hex(key.lookupDigest))',X'\(hex(notificationID))',X'\(hex(epoch))',7,
              X'\(hex(snapshotID))',1,1,0,0,X'\(hex(payload))',X'\(hex(payloadDigest))')
            """)
        let before = try XCTUnwrap(facade.oldestPendingNotice(key: key))
        XCTAssertThrowsError(try facade.acknowledgeNotice(
            key: key, notificationID: notificationID,
            expectedPayloadDigest: payloadDigest, expectedAcknowledgementGeneration: 1))
        var wrongDigest = payloadDigest; wrongDigest[0] ^= 1
        XCTAssertThrowsError(try facade.acknowledgeNotice(
            key: key, notificationID: notificationID,
            expectedPayloadDigest: wrongDigest, expectedAcknowledgementGeneration: 0))
        XCTAssertThrowsError(try raw(databaseURL, """
            UPDATE lan_client_notification_inbox_v6
            SET acknowledgement_state=1,acknowledgement_generation=0
            WHERE notification_id=X'\(hex(notificationID))'
            """))

        let after = try facade.acknowledgeNotice(
            key: key, notificationID: notificationID,
            expectedPayloadDigest: payloadDigest, expectedAcknowledgementGeneration: 0)
        XCTAssertEqual(after.acknowledgement, .acknowledged)
        XCTAssertEqual(after.acknowledgementGeneration, 1)
        XCTAssertEqual(after.key.hostInstallationID, before.key.hostInstallationID)
        XCTAssertEqual(after.key.worldLANID, before.key.worldLANID)
        XCTAssertEqual(after.key.lookupDigest, before.key.lookupDigest)
        XCTAssertEqual(after.notificationID, before.notificationID)
        XCTAssertEqual(after.sessionEpoch, before.sessionEpoch)
        XCTAssertEqual(after.requestID, before.requestID)
        XCTAssertEqual(after.snapshotID, before.snapshotID)
        XCTAssertEqual(after.status, before.status)
        XCTAssertEqual(after.creationGeneration, before.creationGeneration)
        XCTAssertEqual(after.payload, payload)
        XCTAssertEqual(after.payloadDigest, payloadDigest)
        XCTAssertThrowsError(try facade.acknowledgeNotice(
            key: key, notificationID: notificationID,
            expectedPayloadDigest: payloadDigest, expectedAcknowledgementGeneration: 0))
        XCTAssertThrowsError(try raw(databaseURL, """
            UPDATE lan_client_notification_inbox_v6
            SET acknowledgement_state=0,acknowledgement_generation=1
            WHERE notification_id=X'\(hex(notificationID))'
            """))
        try coordinator.close()
    }

    func testPerScopePressurePrunesMinimumAcknowledgedRowInStableOrder() throws {
        let (databaseURL, coordinator, facade, key) = try bootstrap("prune")
        let otherKey = try self.key(hidByte: 31, widByte: 32)
        let token = Data(repeating: 10, count: 32)
        let oldPayload = credentialPayload(token: token, pending: false)
        let oldDigest = credentialDigest(key: key, generation: 1, payload: oldPayload)
        let oldAggregate = aggregate(key: key, generation: 1, credentialDigest: oldDigest)
        let otherDigest = credentialDigest(key: otherKey, generation: 1, payload: oldPayload)
        let otherAggregate = aggregate(
            key: otherKey, generation: 1, credentialDigest: otherDigest)
        var sql = """
            BEGIN;
            INSERT INTO lan_client_credentials_v6 VALUES(
              X'\(hex(key.hostInstallationID))',X'\(hex(key.worldLANID))',X'\(hex(key.lookupDigest))',
              1,1,X'\(hex(oldAggregate))',1,X'\(hex(oldPayload))',X'\(hex(oldDigest))');
            INSERT INTO lan_client_credentials_v6 VALUES(
              X'\(hex(otherKey.hostInstallationID))',X'\(hex(otherKey.worldLANID))',
              X'\(hex(otherKey.lookupDigest))',1,1,X'\(hex(otherAggregate))',1,
              X'\(hex(oldPayload))',X'\(hex(otherDigest))');
            INSERT INTO lan_client_notification_inbox_v6 VALUES(
              X'\(hex(otherKey.hostInstallationID))',X'\(hex(otherKey.worldLANID))',
              X'\(hex(otherKey.lookupDigest))',X'\(String(repeating: "00", count: 32))',
              X'\(String(repeating: "21", count: 16))',999,
              X'\(String(repeating: "22", count: 16))',1,1,1,1,X'00',
              X'\(String(repeating: "23", count: 32))');
            """
        for requestID in 1...256 {
            var id = Data(repeating: 0, count: 32)
            id[28] = UInt8(truncatingIfNeeded: requestID >> 24)
            id[29] = UInt8(truncatingIfNeeded: requestID >> 16)
            id[30] = UInt8(truncatingIfNeeded: requestID >> 8)
            id[31] = UInt8(truncatingIfNeeded: requestID)
            sql += """
                INSERT INTO lan_client_notification_inbox_v6 VALUES(
                  X'\(hex(key.hostInstallationID))',X'\(hex(key.worldLANID))',X'\(hex(key.lookupDigest))',
                  X'\(hex(id))',X'\(String(repeating: "0b", count: 16))',\(requestID),
                  X'\(String(repeating: "0c", count: 16))',1,1,0,0,X'00',
                  X'\(String(repeating: "0d", count: 32))');
                """
        }
        sql += "COMMIT;"
        try raw(databaseURL, sql)

        let newPayload = credentialPayload(token: token, pending: false)
        let newDigest = credentialDigest(key: key, generation: 2, payload: newPayload)
        let newAggregate = aggregate(key: key, generation: 2, credentialDigest: newDigest)
        let credential = try PebbleLANClientCredentialStorageRow(
            key: key, schemaVersion: 1, aggregateGeneration: 2,
            aggregateDigest: newAggregate, authorityBound: true,
            payload: newPayload, payloadDigest: newDigest)
        let newID = Data(repeating: 0xff, count: 32)
        let notice = try PebbleLANClientNotificationStorageRow(
            key: key, notificationID: newID, sessionEpoch: Data(repeating: 14, count: 16),
            requestID: 999, snapshotID: Data(repeating: 15, count: 16),
            status: .accepted, creationGeneration: 2,
            acknowledgement: .pendingRender, acknowledgementGeneration: 0,
            payload: Data([1]), payloadDigest: Data(repeating: 16, count: 32))
        let candidate = try PebbleLANClientAuthorityCheckpointCandidate(
            key: key, transition: .ordinary, expectedAggregateGeneration: 1,
            expectedAggregateDigest: oldAggregate, credential: credential,
            ownerChange: .unchanged, pendingChange: .unchanged, noticeInsert: notice)
        XCTAssertThrowsError(try facade.commit(candidate))
        XCTAssertEqual(try facade.load(key: key).credential.aggregateGeneration, 1)
        XCTAssertEqual(try scalar(databaseURL, """
            SELECT count(*) FROM lan_client_notification_inbox_v6
            WHERE hid=X'\(hex(key.hostInstallationID))' AND wid=X'\(hex(key.worldLANID))'
            """), 256)
        try raw(databaseURL, """
            UPDATE lan_client_notification_inbox_v6
            SET acknowledgement_state=1,acknowledgement_generation=1
            """)
        _ = try facade.commit(candidate)
        XCTAssertEqual(try scalar(databaseURL, """
            SELECT count(*) FROM lan_client_notification_inbox_v6
            WHERE hid=X'\(hex(key.hostInstallationID))' AND wid=X'\(hex(key.worldLANID))'
            """), 256)
        XCTAssertEqual(try scalar(databaseURL, """
            SELECT count(*) FROM lan_client_notification_inbox_v6
            WHERE notification_id=X'\(String(repeating: "00", count: 31))01'
            """), 0)
        XCTAssertEqual(try scalar(databaseURL, """
            SELECT count(*) FROM lan_client_notification_inbox_v6
            WHERE notification_id=X'\(hex(newID))'
            """), 1)
        XCTAssertEqual(try scalar(databaseURL, """
            SELECT count(*) FROM lan_client_notification_inbox_v6
            WHERE hid=X'\(hex(otherKey.hostInstallationID))'
              AND wid=X'\(hex(otherKey.worldLANID))'
            """), 1)
        try coordinator.close()
    }

    func testStaleConcurrentCommitHasOneWinnerAndCommitFaultRollsBack() throws {
        let (databaseURL, coordinator, facade, key) = try bootstrap("concurrency")
        let token = Data(repeating: 21, count: 32)
        let (_, pendingAggregate) = try seedPendingCredential(databaseURL, key: key, token: token)
        let first = try facade.commit(
            firstBindCandidate(key: key, token: token, oldAggregate: pendingAggregate))
        let payload = credentialPayload(token: token, pending: false)
        let digest = credentialDigest(key: key, generation: 2, payload: payload)
        let aggregateDigest = aggregate(key: key, generation: 2, credentialDigest: digest,
                                        owner: (1, first.snapshot.owner!.payloadDigest))
        let credential = try PebbleLANClientCredentialStorageRow(
            key: key, schemaVersion: 1, aggregateGeneration: 2,
            aggregateDigest: aggregateDigest, authorityBound: true,
            payload: payload, payloadDigest: digest)
        let candidate = try PebbleLANClientAuthorityCheckpointCandidate(
            key: key, transition: .ordinary, expectedAggregateGeneration: 1,
            expectedAggregateDigest: first.committedAggregateDigest,
            credential: credential, ownerChange: .unchanged,
            pendingChange: .unchanged, noticeInsert: nil)

        let group = DispatchGroup(), lock = NSLock()
        var successes = 0, failures = 0
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { _ = try facade.commit(candidate); lock.lock(); successes += 1; lock.unlock() }
                catch { lock.lock(); failures += 1; lock.unlock() }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(successes, 1); XCTAssertEqual(failures, 1)
        XCTAssertEqual(try facade.load(key: key).credential.aggregateGeneration, 2)

        let payload3 = credentialPayload(token: token, pending: false)
        let digest3 = credentialDigest(key: key, generation: 3, payload: payload3)
        let aggregate3 = aggregate(key: key, generation: 3, credentialDigest: digest3,
                                   owner: (1, first.snapshot.owner!.payloadDigest))
        let credential3 = try PebbleLANClientCredentialStorageRow(
            key: key, schemaVersion: 1, aggregateGeneration: 3,
            aggregateDigest: aggregate3, authorityBound: true,
            payload: payload3, payloadDigest: digest3)
        let candidate3 = try PebbleLANClientAuthorityCheckpointCandidate(
            key: key, transition: .ordinary, expectedAggregateGeneration: 2,
            expectedAggregateDigest: aggregateDigest, credential: credential3,
            ownerChange: .unchanged, pendingChange: .unchanged, noticeInsert: nil)
        try coordinator._testInject(.commit)
        XCTAssertThrowsError(try facade.commit(candidate3))
        XCTAssertEqual(try facade.load(key: key).credential.aggregateGeneration, 2)
        try coordinator.close()
    }
}
