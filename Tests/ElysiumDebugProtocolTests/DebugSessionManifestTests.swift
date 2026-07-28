import Darwin
import CryptoKit
import Foundation
import XCTest
@testable import ElysiumDebugProtocol

final class DebugSessionManifestTests: XCTestCase {
    private let tokenBytes = Data((0..<DebugSessionToken.byteCount).map(UInt8.init))

    func testTokenHasCanonicalCodableFormAndRedactedDescription() throws {
        let token = try DebugSessionToken(data: tokenBytes)
        XCTAssertEqual(token.hexEncoded.count, 64)
        XCTAssertFalse(token.description.contains(token.hexEncoded))
        XCTAssertEqual(
            try JSONDecoder().decode(DebugSessionToken.self, from: JSONEncoder().encode(token)),
            token
        )
        XCTAssertThrowsError(try DebugSessionToken(data: Data(repeating: 0, count: 31)))
        XCTAssertThrowsError(try DebugSessionToken(hexEncoded: token.hexEncoded.uppercased()))
    }

    func testConnectionKeyDerivationIsDeterministicAndContextSeparated() throws {
        let token = try DebugSessionToken(data: tokenBytes)
        let challenge = Data(repeating: 0x5a, count: DebugSessionKeyDerivation.challengeByteCount)
        let session = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let baseline = try DebugSessionKeyDerivation.deriveConnectionKey(
            token: token,
            serverChallenge: challenge,
            sessionID: session,
            buildIdentifier: "build-a"
        )
        XCTAssertEqual(baseline.count, DebugSessionKeyDerivation.derivedKeyByteCount)
        XCTAssertEqual(baseline, try DebugSessionKeyDerivation.deriveConnectionKey(
            token: token,
            serverChallenge: challenge,
            sessionID: session,
            buildIdentifier: "build-a"
        ))
        XCTAssertNotEqual(baseline, try DebugSessionKeyDerivation.deriveConnectionKey(
            token: token,
            serverChallenge: Data(repeating: 0x5b, count: 32),
            sessionID: session,
            buildIdentifier: "build-a"
        ))
        XCTAssertNotEqual(baseline, try DebugSessionKeyDerivation.deriveConnectionKey(
            token: token,
            serverChallenge: challenge,
            sessionID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            buildIdentifier: "build-a"
        ))
        XCTAssertNotEqual(baseline, try DebugSessionKeyDerivation.deriveConnectionKey(
            token: token,
            serverChallenge: challenge,
            sessionID: session,
            buildIdentifier: "build-b"
        ))

        let wrongDomain = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: token.data),
            salt: challenge,
            info: Data("another-protocol-domain".utf8),
            outputByteCount: 32
        ).withUnsafeBytes { Data($0) }
        XCTAssertNotEqual(baseline, wrongDomain)
    }

    func testConnectionKeyDerivationRejectsInvalidChallengeLength() throws {
        let token = try DebugSessionToken(data: tokenBytes)
        for count in [0, 31, 33] {
            XCTAssertThrowsError(try DebugSessionKeyDerivation.deriveConnectionKey(
                token: token,
                serverChallenge: Data(repeating: 0, count: count),
                sessionID: UUID(),
                buildIdentifier: "test-build"
            )) {
                XCTAssertEqual(
                    $0 as? DebugProtocolError,
                    .invalidMessage("server challenge length")
                )
            }
        }
        XCTAssertEqual(
            DebugSessionKeyDerivation.randomServerChallenge().count,
            DebugSessionKeyDerivation.challengeByteCount
        )
    }

    func testSecureLoadRequiresOwnerOnlyDirectoryAndRegularManifest() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        let manifest = try makeManifest(process: fakeProcessIdentity())
        try fixture.write(manifest)

        XCTAssertEqual(
            try DebugManifestValidator.loadSecurely(
                from: fixture.manifestURL,
                verifyLiveProcess: false
            ),
            manifest
        )

        XCTAssertEqual(chmod(fixture.manifestURL.path, 0o644), 0)
        assertManifestError(.filePermissions) {
            _ = try DebugManifestValidator.loadSecurely(
                from: fixture.manifestURL,
                verifyLiveProcess: false
            )
        }
        XCTAssertEqual(chmod(fixture.manifestURL.path, 0o600), 0)

        XCTAssertEqual(chmod(fixture.directoryURL.path, 0o755), 0)
        assertManifestError(.directoryPermissions) {
            _ = try DebugManifestValidator.loadSecurely(
                from: fixture.manifestURL,
                verifyLiveProcess: false
            )
        }
        XCTAssertEqual(chmod(fixture.directoryURL.path, 0o700), 0)

        let targetURL = fixture.directoryURL.appendingPathComponent("target.json")
        try FileManager.default.removeItem(at: fixture.manifestURL)
        try JSONEncoder().encode(manifest).write(to: targetURL)
        XCTAssertEqual(chmod(targetURL.path, 0o600), 0)
        XCTAssertEqual(symlink(targetURL.path, fixture.manifestURL.path), 0)
        assertManifestError(.invalidFile) {
            _ = try DebugManifestValidator.loadSecurely(
                from: fixture.manifestURL,
                verifyLiveProcess: false
            )
        }
    }

    func testSecureLoadRejectsOversizedManifestBeforeDecode() throws {
        let fixture = try ManifestFixture()
        defer { fixture.remove() }
        try Data(
            repeating: 0x20,
            count: DebugManifestValidator.maximumManifestBytes + 1
        ).write(to: fixture.manifestURL)
        XCTAssertEqual(chmod(fixture.manifestURL.path, 0o600), 0)
        assertManifestError(.fileTooLarge) {
            _ = try DebugManifestValidator.loadSecurely(
                from: fixture.manifestURL,
                verifyLiveProcess: false
            )
        }
    }

    func testCurrentProcessIdentityAndExecutableHashValidateTogether() throws {
        let process = try DebugManifestValidator.currentProcessIdentity()
        let digest = try DebugManifestValidator.executableSHA256(
            at: URL(fileURLWithPath: process.executablePath)
        )
        let manifest = try makeManifest(process: process, executableSHA256: digest)
        XCTAssertNoThrow(try DebugManifestValidator.validateLiveExecutableIdentity(manifest))

        let wrongIdentity = DebugProcessIdentity(
            processIdentifier: process.processIdentifier,
            startSeconds: process.startSeconds,
            startMicroseconds: process.startMicroseconds,
            executablePath: process.executablePath,
            executableDevice: process.executableDevice,
            executableInode: process.executableInode + 1
        )
        let wrongManifest = try makeManifest(
            process: wrongIdentity,
            executableSHA256: digest
        )
        assertManifestError(.invalidProcessIdentity) {
            try DebugManifestValidator.validateLiveExecutableIdentity(wrongManifest)
        }
    }

    func testManifestFieldValidationRejectsUnsafeValues() throws {
        XCTAssertThrowsError(try makeManifest(process: fakeProcessIdentity(), port: 0)) {
            XCTAssertEqual(
                $0 as? DebugProtocolError,
                .invalidManifest(.invalidFields)
            )
        }
        XCTAssertThrowsError(try makeManifest(
            process: fakeProcessIdentity(),
            executableSHA256: String(repeating: "A", count: 64)
        ))
        XCTAssertThrowsError(try makeManifest(
            process: fakeProcessIdentity(),
            buildIdentifier: "build\nidentifier"
        ))
    }

    private func makeManifest(
        process: DebugProcessIdentity,
        port: UInt16 = 43_123,
        executableSHA256: String = String(repeating: "a", count: 64),
        buildIdentifier: String = "test-build"
    ) throws -> DebugSessionManifest {
        try DebugSessionManifest(
            sessionID: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            process: process,
            port: port,
            executableSHA256: executableSHA256,
            buildIdentifier: buildIdentifier,
            token: DebugSessionToken(data: tokenBytes),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func fakeProcessIdentity() -> DebugProcessIdentity {
        DebugProcessIdentity(
            processIdentifier: 42,
            startSeconds: 1,
            startMicroseconds: 2,
            executablePath: "/Applications/Elysium.app/Contents/MacOS/Elysium",
            executableDevice: 3,
            executableInode: 4
        )
    }

    private func assertManifestError(
        _ expected: DebugManifestValidationFailure,
        operation: () throws -> Void
    ) {
        XCTAssertThrowsError(try operation()) { error in
            XCTAssertEqual(error as? DebugProtocolError, .invalidManifest(expected))
        }
    }
}

private final class ManifestFixture {
    let directoryURL: URL
    let manifestURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-debug-manifest-\(UUID().uuidString)", isDirectory: true)
        manifestURL = directoryURL.appendingPathComponent("session.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: false)
        guard chmod(directoryURL.path, 0o700) == 0 else {
            throw DebugProtocolError.fileSystemFailure("fixture directory permissions")
        }
    }

    func write(_ manifest: DebugSessionManifest) throws {
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        guard chmod(manifestURL.path, 0o600) == 0 else {
            throw DebugProtocolError.fileSystemFailure("fixture manifest permissions")
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
