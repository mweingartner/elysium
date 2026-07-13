import Foundation
import Security
import XCTest
@testable import ElysiumReleaseGate

final class KeychainReceiptStateStoreIntegrationTests: XCTestCase {
    private final class InjectedSecurityOperations: KeychainSecurityOperating, @unchecked Sendable {
        var copyStatus: OSStatus = errSecItemNotFound
        var copyValue: CFTypeRef?
        var addStatus: OSStatus = errSecSuccess
        var updateStatus: OSStatus = errSecSuccess
        var deleteStatus: OSStatus = errSecSuccess
        func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
            (copyStatus, copyValue)
        }
        func add(_ attributes: CFDictionary) -> OSStatus { addStatus }
        func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus { updateStatus }
        func delete(_ query: CFDictionary) -> OSStatus { deleteStatus }
    }
    private func payload() -> ReleaseGatePayload {
        ReleaseGatePayload(
            repositoryRootDigest: String(repeating: "1", count: 64),
            contentDigest: String(repeating: "2", count: 64), contentCount: 1,
            checklistDigest: String(repeating: "3", count: 64),
            observerDigest: String(repeating: "4", count: 64),
            automatedGateDigest: String(repeating: "5", count: 64),
            observationChallenge: UUID().uuidString, designerChallenge: UUID().uuidString,
            artifacts: ReleaseArtifactIdentity(
                releasePath: "/tmp/release", releaseSHA256: String(repeating: "6", count: 64),
                installedBundlePath: "/Applications/Elysium.app",
                installedExecutablePath: "/Applications/Elysium.app/Contents/MacOS/Elysium",
                installedSHA256: String(repeating: "7", count: 64),
                installedCDHash: "abc", bundleID: "com.briangao.elysium"),
            expiresEpochSeconds: Int64(Date().timeIntervalSince1970) + 600)
    }

    private func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 10) throws
        -> (Int32, String) {
        let process = Process(), pipe = Pipe()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning { process.terminate(); throw ReleaseGateError.unavailable }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output)
    }

    func testAdversarialCategory10ProductionKeychainCrossProcessAccessibilityAndCleanup() throws {
        let token = UUID().uuidString
        let identity = try KeychainReceiptIdentity.isolatedTest(
            service: "com.briangao.elysium.test.installed-signoff.\(token)", account: "test:\(token)")
        XCTAssertNotEqual(identity.service, KeychainReceiptIdentity.productionService)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let products = root.appendingPathComponent(".build/out/Products/Debug")
        let helper = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-keychain-probe-\(token)")
        defer { try? FileManager.default.removeItem(at: helper) }
        let compile = try run(URL(fileURLWithPath: "/usr/bin/xcrun"), [
            "swiftc", root.appendingPathComponent(
                "Tests/ElysiumReleaseGateTests/Fixtures/KeychainStoreProbe/main.swift").path,
            "-I", products.path, products.appendingPathComponent("ElysiumReleaseGate.o").path,
            "-framework", "Security", "-o", helper.path,
        ], timeout: 30)
        XCTAssertEqual(compile.0, 0, compile.1)

        var value = payload()
        defer { _ = try? run(helper, [identity.service, identity.account, "delete"]) }
        XCTAssertEqual(try run(helper, [identity.service, identity.account, "delete"]).0, 0)
        XCTAssertEqual(try run(helper, [identity.service, identity.account, "absent"]).0, 0)
        let encoded = try ReleaseGateCodec.encode(value).base64EncodedString()
        XCTAssertEqual(try run(helper, [identity.service, identity.account, "add", encoded]).0, 0)
        let childLoad = try run(helper, [identity.service, identity.account, "load"])
        XCTAssertEqual(childLoad.0, 0, childLoad.1)
        XCTAssertTrue(childLoad.1.contains("sequence=0 state=prepared"))
        let access = try run(helper, [identity.service, identity.account, "accessibility"])
        XCTAssertEqual(access.0, 0, access.1)
        XCTAssertTrue(access.1.contains("AfterFirstUnlockThisDeviceOnly") ||
                      access.1.trimmingCharacters(in: .whitespacesAndNewlines) == "cku",
                      access.1)

        value.sequence = 1; value.state = .observed
        XCTAssertEqual(try run(helper, [identity.service, identity.account, "update", "0", "observed"]).0, 0)
        XCTAssertNotEqual(try run(helper, [identity.service, identity.account, "update", "0", "finalized"]).0, 0)
        XCTAssertTrue(try run(helper, [identity.service, identity.account, "load"]).1
            .contains("sequence=1 state=observed"))
        XCTAssertEqual(try run(helper, [identity.service, identity.account, "delete"]).0, 0)
        XCTAssertEqual(try run(helper, [identity.service, identity.account, "absent"]).0, 0)
        XCTAssertEqual(try run(helper, [identity.service, identity.account, "add", encoded]).0, 0)
        XCTAssertEqual(try run(helper, [identity.service, identity.account, "delete"]).0, 0)
        XCTAssertEqual(try run(helper, [identity.service, identity.account, "absent"]).0, 0)
        AdversarialRowsV16.emit(category: 10)
    }

    func testProductionAdapterBoundariesInduceEveryFailureWithoutStatusMapperShortcut() throws {
        let token = UUID().uuidString
        let identity = try KeychainReceiptIdentity.isolatedTest(
            service: "com.briangao.elysium.test.installed-signoff.\(token)",
            account: "test:\(token)")
        let operations = InjectedSecurityOperations()
        let store = KeychainReceiptStateStore(
            isolatedTestIdentity: identity, operations: operations)

        for (status, expected) in [
            (errSecInteractionNotAllowed, ReleaseGateError.unavailable),
            (errSecNotAvailable, .unavailable), (errSecAuthFailed, .authorization),
            (errSecUserCanceled, .authorization), (errSecIO, .persistence),
        ] {
            operations.copyStatus = status; operations.copyValue = nil
            XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? ReleaseGateError, expected) }
        }
        operations.copyStatus = errSecSuccess
        operations.copyValue = Data("malformed".utf8) as CFData
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? ReleaseGateError, .malformed)
        }
        operations.addStatus = errSecDuplicateItem
        XCTAssertThrowsError(try store.add(payload())) {
            XCTAssertEqual($0 as? ReleaseGateError, .duplicate)
        }
        operations.addStatus = errSecSuccess
        operations.copyValue = try ReleaseGateCodec.encode(payload()) as CFData
        operations.updateStatus = errSecIO
        XCTAssertThrowsError(try store.checkedUpdate(expectedSequence: 0, value: payload())) {
            XCTAssertEqual($0 as? ReleaseGateError, .persistence)
        }
        operations.deleteStatus = errSecAuthFailed
        XCTAssertThrowsError(try store.delete()) {
            XCTAssertEqual($0 as? ReleaseGateError, .authorization)
        }
    }

    func testRealKeychainCoordinatorsSerializeStaleConcurrencyAndLeaveNoResidue() throws {
        let token = UUID().uuidString
        let identity = try KeychainReceiptIdentity.isolatedTest(
            service: "com.briangao.elysium.test.installed-signoff.\(token)",
            account: "test:\(token)")
        let store = KeychainReceiptStateStore(isolatedTestIdentity: identity)
        defer { try? store.delete() }
        try store.delete()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-keychain-coordinator-\(token)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ReleaseGateCoordinator(store: store, root: root)
        let second = try ReleaseGateCoordinator(store: store, root: root)
        try first.create(payload())
        let queue = DispatchQueue(label: "keychain-race", attributes: .concurrent)
        let group = DispatchGroup(), lock = NSLock()
        var successes = 0
        for coordinator in [first, second] {
            group.enter(); queue.async {
                defer { group.leave() }
                if (try? coordinator.transition(
                    from: .prepared, to: .observedPendingDesigner,
                    expectedSequence: 0)) != nil {
                    lock.withLock { successes += 1 }
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try first.authoritative().state, .observedPendingDesigner)
        try store.delete()
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual($0 as? ReleaseGateError, .absent)
        }
    }
}
