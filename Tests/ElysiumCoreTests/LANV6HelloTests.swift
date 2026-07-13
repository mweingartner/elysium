import Foundation
import XCTest
@testable import ElysiumCore

final class LANV6HelloTests: XCTestCase {
    private static let propertySeed: UInt64 = 0x5045_4242_4C45_5636

    private struct Fixture {
        let hostID: LANHostInstallationIDV6
        let worldID: LANWorldIDV6
        let lookupDigest: LANV6SHA256Digest
        let otherHostID: LANHostInstallationIDV6
        let otherWorldID: LANWorldIDV6
        let otherLookupDigest: LANV6SHA256Digest
        let playerName: LANV6DisplayName
        let joinCode: LANV6JoinCode
        let token: LANV6Token256
        let nonce: LANV6ClaimNonce
        let legacyHint: LANV6LegacyHint
        let authority: LANV6Authority
        let handshakeID: LANHandshakeIDV6
        let epoch: LANSessionEpochV6
    }

    private struct DeterministicGenerator {
        private(set) var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        mutating func bytes(count: Int) -> [UInt8] {
            (0..<count).map { _ in UInt8(truncatingIfNeeded: next() >> 24) }
        }
    }

    private func makeFixture() throws -> Fixture {
        let hostID = try LANV6ID128(bytes: Array(0..<16))
        let worldID = try LANV6ID128(bytes: Array(16..<32))
        let otherHostID = try LANV6ID128(bytes: Array(32..<48))
        let otherWorldID = try LANV6ID128(bytes: Array(48..<64))
        return Fixture(
            hostID: hostID,
            worldID: worldID,
            lookupDigest: LANV6Crypto.lookupDigest(
                hostInstallationID: hostID,
                worldLANID: worldID
            ),
            otherHostID: otherHostID,
            otherWorldID: otherWorldID,
            otherLookupDigest: LANV6Crypto.lookupDigest(
                hostInstallationID: otherHostID,
                worldLANID: otherWorldID
            ),
            playerName: try LANV6DisplayName("Alex"),
            joinCode: try LANV6JoinCode("AB12CD"),
            token: try LANV6Token256(bytes: Array(64..<96)),
            nonce: try LANV6ClaimNonce(bytes: Array(96..<112)),
            legacyHint: try LANV6LegacyHint("01234567-89AB-CDEF-0123-456789ABCDEF"),
            authority: try LANV6Authority.guest(joinedOrdinal: 7),
            handshakeID: try LANV6ID128(bytes: Array(112..<128)),
            epoch: try LANV6ID128(bytes: Array(128..<144))
        )
    }

    private func helloJSON(
        _ fixture: Fixture,
        admission: String,
        protocolVersion: String = "6",
        hostID: String? = nil,
        worldID: String? = nil,
        lookupDigest: String? = nil,
        playerName: String = "Alex"
    ) -> Data {
        Data(
            "{\"pv\":\(protocolVersion),\"hid\":\"\(hostID ?? fixture.hostID.base64URL)\",\"wid\":\"\(worldID ?? fixture.worldID.base64URL)\",\"lk\":\"\(lookupDigest ?? fixture.lookupDigest.hex)\",\"playerName\":\"\(playerName)\",\"admission\":\(admission)}".utf8
        )
    }

    private func jsonObject(_ data: Data, file: StaticString = #filePath,
                            line: UInt = #line) throws -> [String: Any] {
        let value = try JSONSerialization.jsonObject(with: data)
        guard let object = value as? [String: Any] else {
            XCTFail("expected JSON object", file: file, line: line)
            return [:]
        }
        return object
    }

    private func assertThrowsHandshakeError<T>(
        _ expected: LANV6HandshakeMessageError,
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            XCTAssertEqual(error as? LANV6HandshakeMessageError, expected,
                           "unexpected error: \(error)", file: file, line: line)
        }
    }

    func testAllFourClosedHelloVariantsRoundTripWithExactKeys() throws {
        let fixture = try makeFixture()
        let variants: [(LANV6ClientAdmissionV6, Set<String>)] = [
            (.joinNew(joinCode: fixture.joinCode), ["kind", "joinCode"]),
            (.resume(rawToken: fixture.token), ["kind", "rawToken"]),
            (.legacyClaim(
                joinCode: fixture.joinCode,
                legacyHint: fixture.legacyHint,
                rawClaimNonce: fixture.nonce
            ), ["kind", "joinCode", "legacyHint", "rawClaimNonce"]),
            (.legacyConsume(rawClaimNonce: fixture.nonce), ["kind", "rawClaimNonce"]),
        ]

        for (admission, expectedAdmissionKeys) in variants {
            let hello = try LANClientHelloV6(
                hostInstallationID: fixture.hostID,
                worldLANID: fixture.worldID,
                playerName: fixture.playerName,
                admission: admission
            )
            let encoded = try hello.encoded()
            XCTAssertEqual(try LANClientHelloV6.decodeStrict(encoded), hello)
            XCTAssertEqual(
                try LANClientHelloV6.decodeStrict(
                    encoded,
                    expectedHostInstallationID: fixture.hostID,
                    expectedWorldLANID: fixture.worldID,
                    expectedLookupDigest: fixture.lookupDigest
                ),
                hello
            )

            let object = try jsonObject(encoded)
            XCTAssertEqual(Set(object.keys), ["pv", "hid", "wid", "lk", "playerName", "admission"])
            let nested = try XCTUnwrap(object["admission"] as? [String: Any])
            XCTAssertEqual(Set(nested.keys), expectedAdmissionKeys)
        }

        let noHint = try LANClientHelloV6(
            hostInstallationID: fixture.hostID,
            worldLANID: fixture.worldID,
            playerName: fixture.playerName,
            admission: .legacyClaim(
                joinCode: fixture.joinCode,
                legacyHint: nil,
                rawClaimNonce: fixture.nonce
            )
        )
        let noHintData = try noHint.encoded()
        XCTAssertEqual(try decodeBoundHello(noHintData, fixture: fixture), noHint)
        let noHintAdmission = try XCTUnwrap(
            try jsonObject(noHintData)["admission"] as? [String: Any]
        )
        XCTAssertTrue(noHintAdmission["legacyHint"] is NSNull)
    }

    func testHelloRejectsMissingExtraDuplicateAndMixedKeysAtBothLayers() throws {
        let fixture = try makeFixture()
        let validAdmission = "{\"kind\":\"joinNew\",\"joinCode\":\"AB12CD\"}"
        let exact = String(decoding: helloJSON(fixture, admission: validAdmission), as: UTF8.self)
        let outerMutations = [
            exact.replacingOccurrences(of: "\"playerName\":\"Alex\",", with: ""),
            String(exact.dropLast()) + ",\"extra\":0}",
            exact.replacingOccurrences(of: "\"pv\":6", with: "\"pv\":6,\"pv\":6"),
            exact.replacingOccurrences(of: "\"admission\":", with: "\"admission\":{},\"admission\":"),
        ]
        for mutation in outerMutations {
            XCTAssertThrowsError(
                try decodeBoundHello(Data(mutation.utf8), fixture: fixture),
                mutation
            )
        }

        let invalidAdmissions = [
            "{\"kind\":\"joinNew\"}",
            "{\"kind\":\"joinNew\",\"joinCode\":\"AB12CD\",\"extra\":0}",
            "{\"kind\":\"joinNew\",\"joinCode\":\"AB12CD\",\"joinCode\":\"AB12CD\"}",
            "{\"kind\":\"resume\",\"rawToken\":\"\(fixture.token.base64URL)\",\"joinCode\":\"AB12CD\"}",
            "{\"kind\":\"legacyConsume\",\"rawClaimNonce\":\"\(fixture.nonce.base64URL)\",\"rawToken\":\"\(fixture.token.base64URL)\"}",
            "{\"kind\":\"legacyClaim\",\"joinCode\":\"AB12CD\",\"legacyHint\":null,\"rawClaimNonce\":\"\(fixture.nonce.base64URL)\",\"rawToken\":\"\(fixture.token.base64URL)\"}",
            "[]",
            "null",
        ]
        for admission in invalidAdmissions {
            XCTAssertThrowsError(
                try decodeBoundHello(
                    helloJSON(fixture, admission: admission), fixture: fixture
                ),
                admission
            )
        }
    }

    func testHelloRejectsAdmissionShapeAndKindMismatch() throws {
        let fixture = try makeFixture()
        let mismatches = [
            "{\"kind\":\"resume\",\"joinCode\":\"AB12CD\"}",
            "{\"kind\":\"joinNew\",\"rawToken\":\"\(fixture.token.base64URL)\"}",
            "{\"kind\":\"legacyConsume\",\"joinCode\":\"AB12CD\",\"legacyHint\":null,\"rawClaimNonce\":\"\(fixture.nonce.base64URL)\"}",
            "{\"kind\":\"legacyClaim\",\"rawClaimNonce\":\"\(fixture.nonce.base64URL)\"}",
            "{\"kind\":\"unknown\",\"rawToken\":\"\(fixture.token.base64URL)\"}",
        ]
        for mismatch in mismatches {
            XCTAssertThrowsError(
                try decodeBoundHello(
                    helloJSON(fixture, admission: mismatch), fixture: fixture
                ),
                mismatch
            )
        }
    }

    func testHelloRejectsNoncanonicalOrWrongLengthSecretsAndLegacyDomains() throws {
        let fixture = try makeFixture()
        let invalidTokens = [
            String(repeating: "A", count: 42),
            String(repeating: "A", count: 44),
            String(repeating: "A", count: 43) + "=",
            String(repeating: "A", count: 42) + "+",
            String(repeating: "A", count: 42) + "B",
        ]
        for token in invalidTokens {
            let admission = "{\"kind\":\"resume\",\"rawToken\":\"\(token)\"}"
            XCTAssertThrowsError(
                try decodeBoundHello(
                    helloJSON(fixture, admission: admission), fixture: fixture
                ),
                token
            )
        }

        let invalidNonces = [
            String(repeating: "A", count: 21),
            String(repeating: "A", count: 23),
            String(repeating: "A", count: 22) + "=",
            String(repeating: "A", count: 21) + "+",
            String(repeating: "A", count: 21) + "B",
        ]
        for nonce in invalidNonces {
            let admission = "{\"kind\":\"legacyConsume\",\"rawClaimNonce\":\"\(nonce)\"}"
            XCTAssertThrowsError(
                try decodeBoundHello(
                    helloJSON(fixture, admission: admission), fixture: fixture
                ),
                nonce
            )
        }

        let invalidLegacyAdmissions = [
            "{\"kind\":\"legacyClaim\",\"joinCode\":\"ab12\",\"legacyHint\":null,\"rawClaimNonce\":\"\(fixture.nonce.base64URL)\"}",
            "{\"kind\":\"legacyClaim\",\"joinCode\":\"AB12CD\",\"legacyHint\":\"01234567-89ab-cdef-0123-456789abcdef\",\"rawClaimNonce\":\"\(fixture.nonce.base64URL)\"}",
            "{\"kind\":\"legacyClaim\",\"joinCode\":\"AB12CD\",\"legacyHint\":12,\"rawClaimNonce\":\"\(fixture.nonce.base64URL)\"}",
        ]
        for admission in invalidLegacyAdmissions {
            XCTAssertThrowsError(
                try decodeBoundHello(
                    helloJSON(fixture, admission: admission), fixture: fixture
                ),
                admission
            )
        }
    }

    func testHelloIdentityTupleVersionAndDisplayNameAreStrict() throws {
        let fixture = try makeFixture()
        let admission = "{\"kind\":\"joinNew\",\"joinCode\":\"AB12CD\"}"

        assertThrowsHandshakeError(
            .unsupportedProtocolVersion(5),
            try decodeBoundHello(
                helloJSON(fixture, admission: admission, protocolVersion: "5"),
                fixture: fixture
            )
        )
        assertThrowsHandshakeError(
            .advertisedIdentityMismatch,
            try decodeBoundHello(
                helloJSON(
                    fixture,
                    admission: admission,
                    lookupDigest: fixture.otherLookupDigest.hex
                ),
                fixture: fixture
            )
        )
        XCTAssertThrowsError(try decodeBoundHello(
            helloJSON(fixture, admission: admission, hostID: "not-base64url"),
            fixture: fixture
        ))
        XCTAssertThrowsError(try decodeBoundHello(
            helloJSON(fixture, admission: admission, playerName: ""),
            fixture: fixture
        ))

        let hello = try LANClientHelloV6(
            hostInstallationID: fixture.hostID,
            worldLANID: fixture.worldID,
            playerName: fixture.playerName,
            admission: .joinNew(joinCode: fixture.joinCode)
        )
        assertThrowsHandshakeError(
            .advertisedIdentityMismatch,
            try LANClientHelloV6.decodeStrict(
                hello.encoded(),
                expectedHostInstallationID: fixture.otherHostID,
                expectedWorldLANID: fixture.otherWorldID,
                expectedLookupDigest: fixture.otherLookupDigest
            )
        )
        assertThrowsHandshakeError(
            .advertisedIdentityMismatch,
            try LANClientHelloV6(
                hostInstallationID: fixture.hostID,
                worldLANID: fixture.worldID,
                lookupDigest: fixture.otherLookupDigest,
                playerName: fixture.playerName,
                admission: .joinNew(joinCode: fixture.joinCode)
            )
        )
    }

    func testHandshakeJSONByteCapAcceptsExactBoundaryAndRejectsOneOver() throws {
        let fixture = try makeFixture()
        let hello = try LANClientHelloV6(
            hostInstallationID: fixture.hostID,
            worldLANID: fixture.worldID,
            playerName: fixture.playerName,
            admission: .joinNew(joinCode: fixture.joinCode)
        )
        let encoded = try hello.encoded()
        XCTAssertLessThan(encoded.count, LAN_V6_HANDSHAKE_JSON_LIMIT)

        var boundary = Data(
            repeating: 0x20,
            count: LAN_V6_HANDSHAKE_JSON_LIMIT - encoded.count
        )
        boundary.append(encoded)
        XCTAssertEqual(boundary.count, LAN_V6_HANDSHAKE_JSON_LIMIT)
        XCTAssertEqual(try decodeBoundHello(boundary, fixture: fixture), hello)

        var over = Data([0x20])
        over.append(boundary)
        XCTAssertEqual(over.count, LAN_V6_HANDSHAKE_JSON_LIMIT + 1)
        XCTAssertThrowsError(try decodeBoundHello(over, fixture: fixture)) { error in
            XCTAssertEqual(
                error as? LANV6StrictJSONError,
                .byteLimitExceeded(
                    actual: LAN_V6_HANDSHAKE_JSON_LIMIT + 1,
                    maximum: LAN_V6_HANDSHAKE_JSON_LIMIT
                )
            )
        }
    }

    func testExpectedIdentityBindingPrecedesCredentialBodyDecode() throws {
        let fixture = try makeFixture()
        let invalidResume = helloJSON(
            fixture,
            admission: "{\"kind\":\"resume\",\"rawToken\":\"invalid\"}"
        )
        assertThrowsHandshakeError(
            .advertisedIdentityMismatch,
            try LANClientHelloV6.decodeStrict(
                invalidResume,
                expectedHostInstallationID: fixture.otherHostID,
                expectedWorldLANID: fixture.otherWorldID,
                expectedLookupDigest: fixture.otherLookupDigest
            )
        )
        XCTAssertThrowsError(try LANClientHelloV6.decodeStrict(
            invalidResume,
            expectedHostInstallationID: fixture.hostID,
            expectedWorldLANID: fixture.worldID,
            expectedLookupDigest: fixture.lookupDigest
        )) { error in
            XCTAssertNotEqual(error as? LANV6HandshakeMessageError, .advertisedIdentityMismatch)
        }

        let accept = try makeAccept(
            fixture, active: nil, pending: 1, socketGeneration: 1,
            credentialDelivery: .issued(rawToken: fixture.token)
        )
        let validAcceptText = try XCTUnwrap(String(data: accept.encoded(), encoding: .utf8))
        let invalidAccept = Data(
            validAcceptText.replacingOccurrences(
                of: fixture.token.base64URL,
                with: "invalid"
            ).utf8
        )
        assertThrowsHandshakeError(
            .advertisedIdentityMismatch,
            try LANServerAcceptV6.decodeStrict(
                invalidAccept,
                expectedHostInstallationID: fixture.otherHostID,
                expectedWorldLANID: fixture.otherWorldID,
                expectedLookupDigest: fixture.otherLookupDigest
            )
        )
        XCTAssertThrowsError(try LANServerAcceptV6.decodeStrict(
            invalidAccept,
            expectedHostInstallationID: fixture.hostID,
            expectedWorldLANID: fixture.worldID,
            expectedLookupDigest: fixture.lookupDigest
        )) { error in
            XCTAssertNotEqual(error as? LANV6HandshakeMessageError, .advertisedIdentityMismatch)
        }
    }

    func testServerAcceptFreshAndPendingResumeShapesAreStrict() throws {
        let fixture = try makeFixture()
        let fresh = try makeAccept(
            fixture, active: nil, pending: 1,
            socketGeneration: 1,
            credentialDelivery: .issued(rawToken: fixture.token)
        )
        let resume = try makeAccept(
            fixture, active: 7, pending: 8,
            socketGeneration: LAN_V6_MAX_COUNTER,
            credentialDelivery: .resumedExisting
        )
        XCTAssertEqual(
            fresh.credentialDelivery,
            .issued(rawToken: fixture.token)
        )
        XCTAssertEqual(resume.credentialDelivery, .resumedExisting)

        let baseKeys: Set<String> = [
            "pv", "hid", "wid", "lk", "authority", "activeGeneration",
            "pendingGeneration", "handshakeID", "opaqueSocketGeneration", "epoch",
        ]
        for (message, expectedKeys) in [
            (fresh, baseKeys.union(["rawPendingToken"])),
            (resume, baseKeys),
        ] {
            let data = try message.encoded()
            XCTAssertEqual(try LANServerAcceptV6.decodeStrict(data), message)
            XCTAssertEqual(
                try LANServerAcceptV6.decodeStrict(
                    data,
                    expectedHostInstallationID: fixture.hostID,
                    expectedWorldLANID: fixture.worldID,
                    expectedLookupDigest: fixture.lookupDigest
                ),
                message
            )
            XCTAssertEqual(Set(try jsonObject(data).keys), expectedKeys)
        }

        let freshObject = try jsonObject(fresh.encoded())
        XCTAssertTrue(freshObject["activeGeneration"] is NSNull)
        XCTAssertEqual(freshObject["rawPendingToken"] as? String, fixture.token.base64URL)
        let resumeObject = try jsonObject(resume.encoded())
        XCTAssertEqual((resumeObject["activeGeneration"] as? NSNumber)?.uint32Value, 7)
        XCTAssertNil(resumeObject["rawPendingToken"])

        let resumeText = try XCTUnwrap(String(data: resume.encoded(), encoding: .utf8))
        let malformedShapes = [
            String(resumeText.dropLast()) + ",\"extra\":0}",
            resumeText.replacingOccurrences(of: "\"activeGeneration\":7,", with: ""),
            resumeText.replacingOccurrences(
                of: "\"authority\":\"lan:7\"",
                with: "\"authority\":\"lan:7\",\"authority\":\"lan:7\""
            ),
            String(resumeText.dropLast()) + ",\"rawPendingToken\":null}",
        ]
        for malformed in malformedShapes {
            XCTAssertThrowsError(
                try LANServerAcceptV6.decodeStrict(
                    Data(malformed.utf8),
                    expectedHostInstallationID: fixture.hostID,
                    expectedWorldLANID: fixture.worldID,
                    expectedLookupDigest: fixture.lookupDigest
                ),
                malformed
            )
        }
    }

    func testServerRejectAndClientReadyUseOnlyExactClosedKeysAndDomains() throws {
        for reason in LANV6ServerRejectReason.allCases {
            let reject = LANServerRejectV6(reason: reason)
            let data = try reject.encoded()
            XCTAssertEqual(try LANServerRejectV6.decodeStrict(data), reject)
            XCTAssertEqual(Set(try jsonObject(data).keys), ["reason"])
        }
        for invalid in [
            "{}",
            "{\"reason\":\"busy\",\"extra\":0}",
            "{\"reason\":\"busy\",\"reason\":\"busy\"}",
            "{\"reason\":\"credentialMissing\"}",
            "{\"reason\":0}",
        ] {
            XCTAssertThrowsError(try LANServerRejectV6.decodeStrict(Data(invalid.utf8)), invalid)
        }

        let fixture = try makeFixture()
        let ready = try makeReady(
            fixture, active: 7, pending: 8,
            socketGeneration: LAN_V6_MAX_COUNTER
        )
        let readyData = try ready.encoded()
        XCTAssertEqual(try LANClientReadyV6.decodeStrict(readyData), ready)
        XCTAssertEqual(Set(try jsonObject(readyData).keys), [
            "authority", "activeGeneration", "pendingGeneration", "epoch",
            "handshakeID", "opaqueSocketGeneration", "rawPendingToken",
        ])

        let readyText = try XCTUnwrap(String(data: readyData, encoding: .utf8))
        let malformed = [
            String(readyText.dropLast()) + ",\"extra\":0}",
            readyText.replacingOccurrences(of: "\"pendingGeneration\":8,", with: ""),
            readyText.replacingOccurrences(
                of: "\"authority\":\"lan:7\"",
                with: "\"authority\":\"lan:7\",\"authority\":\"lan:7\""
            ),
            readyText.replacingOccurrences(of: "\"authority\":\"lan:7\"",
                                           with: "\"authority\":\"host:local\""),
        ]
        for value in malformed {
            XCTAssertThrowsError(try LANClientReadyV6.decodeStrict(Data(value.utf8)), value)
        }
    }

    func testCredentialAndSocketGenerationBoundaries() throws {
        let fixture = try makeFixture()
        XCTAssertNoThrow(try makeAccept(
            fixture, active: nil, pending: 1,
            socketGeneration: 1,
            credentialDelivery: .issued(rawToken: fixture.token)
        ))
        XCTAssertNoThrow(try makeAccept(
            fixture, active: LAN_V6_MAX_COUNTER - 1, pending: LAN_V6_MAX_COUNTER,
            socketGeneration: LAN_V6_MAX_COUNTER,
            credentialDelivery: .issued(rawToken: fixture.token)
        ))
        XCTAssertNoThrow(try makeReady(
            fixture, active: nil, pending: 1, socketGeneration: 1
        ))
        XCTAssertNoThrow(try makeReady(
            fixture, active: LAN_V6_MAX_COUNTER - 1, pending: LAN_V6_MAX_COUNTER,
            socketGeneration: LAN_V6_MAX_COUNTER
        ))
        for authority in [
            try LANV6Authority.guest(joinedOrdinal: 1),
            try LANV6Authority.guest(joinedOrdinal: LAN_V6_MAX_JOINED_ORDINAL),
        ] {
            XCTAssertNoThrow(try makeAccept(
                fixture, active: nil, pending: 1, socketGeneration: 1,
                credentialDelivery: .issued(rawToken: fixture.token),
                authority: authority
            ))
            XCTAssertNoThrow(try makeReady(
                fixture, active: nil, pending: 1,
                socketGeneration: 1, authority: authority
            ))
        }

        let invalidGenerations: [(UInt32?, UInt32)] = [
            (nil, 0), (nil, 2), (0, 1), (1, 1), (1, 3),
            (LAN_V6_MAX_COUNTER, LAN_V6_MAX_COUNTER),
        ]
        for (active, pending) in invalidGenerations {
            assertThrowsHandshakeError(
                .invalidCredentialGeneration,
                try makeAccept(
                    fixture, active: active, pending: pending,
                    socketGeneration: 1,
                    credentialDelivery: .issued(rawToken: fixture.token)
                )
            )
            assertThrowsHandshakeError(
                .invalidCredentialGeneration,
                try makeReady(
                    fixture, active: active, pending: pending,
                    socketGeneration: 1
                )
            )
        }

        for socketGeneration in [UInt32(0), LAN_V6_MAX_COUNTER + 1] {
            assertThrowsHandshakeError(
                .invalidSocketGeneration,
                try makeAccept(
                    fixture, active: nil, pending: 1,
                    socketGeneration: socketGeneration,
                    credentialDelivery: .issued(rawToken: fixture.token)
                )
            )
            assertThrowsHandshakeError(
                .invalidSocketGeneration,
                try makeReady(
                    fixture, active: nil, pending: 1,
                    socketGeneration: socketGeneration
                )
            )
        }

        for invalidOrdinal in [UInt32(0), LAN_V6_MAX_JOINED_ORDINAL + 1] {
            XCTAssertThrowsError(
                try LANV6Authority.guest(joinedOrdinal: invalidOrdinal)
            ) { error in
                XCTAssertEqual(error as? LANV6ScalarError, .invalidAuthority)
            }
        }

        assertThrowsHandshakeError(
            .invalidPeerAuthority,
            try LANServerAcceptV6(
                hostInstallationID: fixture.hostID,
                worldLANID: fixture.worldID,
                lookupDigest: fixture.lookupDigest,
                authority: .hostLocal,
                activeGeneration: nil,
                pendingGeneration: 1,
                handshakeID: fixture.handshakeID,
                opaqueSocketGeneration: 1,
                epoch: fixture.epoch,
                credentialDelivery: .issued(rawToken: fixture.token)
            )
        )
        assertThrowsHandshakeError(
            .invalidPeerAuthority,
            try LANClientReadyV6(
                authority: .hostLocal,
                activeGeneration: nil,
                pendingGeneration: 1,
                epoch: fixture.epoch,
                handshakeID: fixture.handshakeID,
                opaqueSocketGeneration: 1,
                rawPendingToken: fixture.token
            )
        )
    }

    func testHandshakeIntegerFieldsRejectNoncanonicalJSONNumberSpellings() throws {
        let fixture = try makeFixture()
        let hello = helloJSON(
            fixture,
            admission: "{\"kind\":\"joinNew\",\"joinCode\":\"AB12CD\"}"
        )
        let helloText = String(decoding: hello, as: UTF8.self)
        for spelling in ["6.0", "6e0", "6E+0", "-6", "06"] {
            let mutation = helloText.replacingOccurrences(
                of: "\"pv\":6",
                with: "\"pv\":\(spelling)"
            )
            XCTAssertThrowsError(
                try decodeBoundHello(Data(mutation.utf8), fixture: fixture),
                "pv spelling \(spelling)"
            )
        }

        let accept = try makeAccept(
            fixture, active: 7, pending: 8,
            socketGeneration: 9,
            credentialDelivery: .issued(rawToken: fixture.token)
        )
        let ready = try makeReady(
            fixture, active: 7, pending: 8, socketGeneration: 9
        )
        let numericFields = [
            ("pv", "6"),
            ("activeGeneration", "7"),
            ("pendingGeneration", "8"),
            ("opaqueSocketGeneration", "9"),
        ]
        let acceptText = try XCTUnwrap(String(data: accept.encoded(), encoding: .utf8))
        for (field, canonical) in numericFields {
            for spelling in ["\(canonical).0", "\(canonical)e0", "-\(canonical)", "0\(canonical)"] {
                let mutation = acceptText.replacingOccurrences(
                    of: "\"\(field)\":\(canonical)",
                    with: "\"\(field)\":\(spelling)"
                )
                XCTAssertNotEqual(mutation, acceptText, "test must mutate \(field)")
                XCTAssertThrowsError(try LANServerAcceptV6.decodeStrict(
                    Data(mutation.utf8),
                    expectedHostInstallationID: fixture.hostID,
                    expectedWorldLANID: fixture.worldID,
                    expectedLookupDigest: fixture.lookupDigest
                ), "accept \(field) spelling \(spelling)")
            }
        }

        let readyText = try XCTUnwrap(String(data: ready.encoded(), encoding: .utf8))
        for (field, canonical) in numericFields where field != "pv" {
            for spelling in ["\(canonical).0", "\(canonical)e0", "-\(canonical)", "0\(canonical)"] {
                let mutation = readyText.replacingOccurrences(
                    of: "\"\(field)\":\(canonical)",
                    with: "\"\(field)\":\(spelling)"
                )
                XCTAssertNotEqual(mutation, readyText, "test must mutate \(field)")
                XCTAssertThrowsError(
                    try LANClientReadyV6.decodeStrict(Data(mutation.utf8)),
                    "ready \(field) spelling \(spelling)"
                )
            }
        }
    }

    func testAllCredentialBearingDescriptionsAreRedacted() throws {
        let fixture = try makeFixture()
        let hello = try LANClientHelloV6(
            hostInstallationID: fixture.hostID,
            worldLANID: fixture.worldID,
            playerName: fixture.playerName,
            admission: .resume(rawToken: fixture.token)
        )
        let accept = try makeAccept(
            fixture, active: 7, pending: 8,
            socketGeneration: 9,
            credentialDelivery: .issued(rawToken: fixture.token)
        )
        let ready = try makeReady(fixture, active: 7, pending: 8, socketGeneration: 9)

        XCTAssertEqual(fixture.token.description, LANV6Token256.redactedDescription)
        XCTAssertEqual(fixture.nonce.description, LANV6ClaimNonce.redactedDescription)
        XCTAssertEqual(fixture.joinCode.description, LANV6JoinCode.redactedDescription)

        let sensitiveValues = [
            fixture.hostID.base64URL,
            fixture.worldID.base64URL,
            fixture.lookupDigest.hex,
            fixture.playerName.value,
            fixture.joinCode.serialized,
            fixture.token.base64URL,
            fixture.nonce.base64URL,
            fixture.authority.description,
            fixture.handshakeID.base64URL,
            fixture.epoch.base64URL,
        ]
        for description in [hello.description, accept.description, ready.description] {
            for sensitive in sensitiveValues {
                XCTAssertFalse(description.contains(sensitive),
                               "description leaked \(sensitive): \(description)")
            }
        }
    }

    func testEveryNamedFramePolicyIsExactAndFailsClosedForWrongRoleOrPhase() {
        typealias KindSet = Set<LANV6MessageKind>
        let hostAuthenticatedInbound: KindSet = [
            .chat, .ping, .pong, .disconnect, .inputIntent, .blockIntent,
            .containerIntent, .templateIntent, .chunkRequest, .replicationAck,
            .attackIntent, .tossIntent, .containerEditIntent, .keepalive, .rpgIntent,
        ]
        let hostAuthenticatedOutbound: KindSet = [
            .chat, .playerState, .worldSummary, .ping, .pong, .disconnect,
            .replicationBatch, .gameplayEvent, .inventoryUpdate, .inventoryGrant,
            .restoreState, .damageEvent, .keepalive, .ownerManifest, .ownerChunk,
        ]
        let clientConnectedInbound = hostAuthenticatedOutbound
        let clientConnectedOutbound: KindSet = [
            .chat, .ping, .pong, .disconnect, .inputIntent,
            .blockIntent, .containerIntent, .templateIntent, .chunkRequest,
            .replicationAck, .attackIntent, .tossIntent, .containerEditIntent,
            .keepalive, .rpgIntent,
        ]

        assertPolicy(
            .hostAwaitingHelloV6, role: .host, phase: .awaitingHello,
            inbound: [.clientHello], outbound: [.serverReject, .disconnect]
        )
        assertPolicy(
            .hostAwaitingClientReadyV6, role: .host, phase: .awaitingClientReady,
            inbound: [.clientReady, .disconnect],
            outbound: [.serverAccept, .serverReject, .disconnect]
        )
        assertPolicy(
            .hostReadyAwaitingOwnerBudgetV6, role: .host, phase: .readyAwaitingOwnerBudget,
            inbound: [.disconnect],
            outbound: [.serverReject, .disconnect]
        )
        assertPolicy(
            .hostAuthenticatedV6, role: .host, phase: .authenticated,
            inbound: hostAuthenticatedInbound, outbound: hostAuthenticatedOutbound
        )
        assertPolicy(.hostClosingV6, role: .host, phase: .closing)
        assertPolicy(
            .clientConnectingV6, role: .client, phase: .connecting,
            outbound: [.clientHello]
        )
        assertPolicy(
            .clientAwaitingServerAcceptV6, role: .client, phase: .awaitingServerAccept,
            inbound: [.serverAccept, .serverReject, .disconnect], outbound: [.disconnect]
        )
        assertPolicy(
            .clientAwaitingInitialOwnerV6, role: .client, phase: .awaitingInitialOwner,
            inbound: [.serverReject, .disconnect, .ownerManifest, .ownerChunk],
            outbound: [.clientReady, .disconnect]
        )
        assertPolicy(
            .clientConnectedV6, role: .client, phase: .connected,
            inbound: clientConnectedInbound, outbound: clientConnectedOutbound
        )
        assertPolicy(.clientRejectedV6, role: .client, phase: .rejected)

        XCTAssertFalse(LANV6FrameAdmissionPolicy.hostAwaitingClientReadyV6.admits(
            localRole: .host, phase: .awaitingClientReady,
            flow: .inbound, kind: .clientHello
        ), "a repeated hello must be rejected")
        XCTAssertFalse(LANV6FrameAdmissionPolicy.hostAuthenticatedV6.admits(
            localRole: .host, phase: .authenticated,
            flow: .inbound, kind: .clientHello
        ), "an authenticated socket must reject a repeated hello")

        for role in LANV6LocalRole.allCases {
            for phase in LANV6ConnectionPhase.allCases {
                let mapped = LANV6FrameAdmissionPolicy.handshakeV6(
                    localRole: role, phase: phase
                )
                let expected: (inbound: KindSet, outbound: KindSet)
                switch (role, phase) {
                case (.host, .awaitingHello):
                    expected = ([.clientHello], [.serverReject, .disconnect])
                case (.host, .awaitingClientReady):
                    expected = (
                        [.clientReady, .disconnect],
                        [.serverAccept, .serverReject, .disconnect]
                    )
                case (.host, .readyAwaitingOwnerBudget):
                    expected = ([.disconnect], [.serverReject, .disconnect])
                case (.host, .authenticated):
                    expected = (hostAuthenticatedInbound, hostAuthenticatedOutbound)
                case (.client, .connecting):
                    expected = ([], [.clientHello])
                case (.client, .awaitingServerAccept):
                    expected = ([.serverAccept, .serverReject, .disconnect], [.disconnect])
                case (.client, .awaitingInitialOwner):
                    expected = (
                        [.serverReject, .disconnect, .ownerManifest, .ownerChunk],
                        [.clientReady, .disconnect]
                    )
                case (.client, .connected):
                    expected = (clientConnectedInbound, clientConnectedOutbound)
                default:
                    expected = ([], [])
                }
                assertPolicy(
                    mapped, role: role, phase: phase,
                    inbound: expected.inbound, outbound: expected.outbound,
                    requireWrongRoleAndPhaseDenial: false
                )
            }
        }
    }

    func testHandshakeStateTransitionMovesClientReadyAndServerAcceptIntoTheirAdmittedPhases() throws {
        var client = LANV6ClientHandshakeMachine(nowNanoseconds: 0)
        XCTAssertEqual(
            try client.apply(.transportConnectedAndHelloSent, at: 1),
            .awaitServerDecision
        )
        XCTAssertEqual(client.connectionPhase, .awaitingServerAccept)
        XCTAssertFalse(LANV6FrameAdmissionPolicy.handshakeV6(
            localRole: .client,
            phase: client.connectionPhase
        ).admits(
            localRole: .client,
            phase: client.connectionPhase,
            flow: .outbound,
            kind: .clientReady
        ))

        XCTAssertEqual(
            try client.apply(.serverAcceptCredentialPersisted, at: 2),
            .sendClientReadyAndAwaitInitialOwner
        )
        XCTAssertEqual(client.connectionPhase, .awaitingInitialOwner)
        XCTAssertTrue(LANV6FrameAdmissionPolicy.handshakeV6(
            localRole: .client,
            phase: client.connectionPhase
        ).admits(
            localRole: .client,
            phase: client.connectionPhase,
            flow: .outbound,
            kind: .clientReady
        ))

        var host = LANV6HostHandshakeMachine(nowNanoseconds: 0)
        XCTAssertFalse(LANV6FrameAdmissionPolicy.handshakeV6(
            localRole: .host,
            phase: host.connectionPhase
        ).admits(
            localRole: .host,
            phase: host.connectionPhase,
            flow: .outbound,
            kind: .serverAccept
        ))
        XCTAssertEqual(
            try host.apply(.admissionPersisted(.joinNew), at: 1),
            .sendServerAccept
        )
        XCTAssertEqual(host.connectionPhase, .awaitingClientReady)
        XCTAssertTrue(LANV6FrameAdmissionPolicy.handshakeV6(
            localRole: .host,
            phase: host.connectionPhase
        ).admits(
            localRole: .host,
            phase: host.connectionPhase,
            flow: .outbound,
            kind: .serverAccept
        ))
    }

    func testSeededTenThousandValidVariantsAndTenThousandArbitraryMutations() throws {
        let seed = Self.propertySeed
        var generator = DeterministicGenerator(state: seed)
        var validCorpus = [Data]()
        validCorpus.reserveCapacity(256)

        for caseIndex in 0..<10_000 {
            let hostID = try LANV6ID128(bytes: generator.bytes(count: 16))
            let worldID = try LANV6ID128(bytes: generator.bytes(count: 16))
            let name = try LANV6DisplayName("P\(caseIndex)")
            let admission: LANV6ClientAdmissionV6
            switch caseIndex % 4 {
            case 0:
                admission = .joinNew(joinCode: try generatedJoinCode(using: &generator))
            case 1:
                admission = .resume(
                    rawToken: try LANV6Token256(bytes: generator.bytes(count: 32))
                )
            case 2:
                admission = .legacyClaim(
                    joinCode: try generatedJoinCode(using: &generator),
                    legacyHint: caseIndex.isMultiple(of: 8) ? nil :
                        try LANV6LegacyHint("01234567-89AB-CDEF-0123-456789ABCDEF"),
                    rawClaimNonce: try LANV6ClaimNonce(bytes: generator.bytes(count: 16))
                )
            default:
                admission = .legacyConsume(
                    rawClaimNonce: try LANV6ClaimNonce(bytes: generator.bytes(count: 16))
                )
            }
            let hello = try LANClientHelloV6(
                hostInstallationID: hostID,
                worldLANID: worldID,
                playerName: name,
                admission: admission
            )
            let encoded = try hello.encoded()
            XCTAssertEqual(
                try LANClientHelloV6.decodeStrict(
                    encoded,
                    expectedHostInstallationID: hostID,
                    expectedWorldLANID: worldID,
                    expectedLookupDigest: hello.lookupDigest
                ),
                hello,
                "seed=\(seed) validCase=\(caseIndex)"
            )
            if validCorpus.count < 256 { validCorpus.append(encoded) }
        }

        for caseIndex in 0..<10_000 {
            let base = validCorpus[Int(generator.next() % UInt64(validCorpus.count))]
            let payload: Data
            switch caseIndex % 5 {
            case 0:
                payload = Data(generator.bytes(count: Int(generator.next() % 257)))
            case 1:
                var mutation = base
                if !mutation.isEmpty {
                    let index = Int(generator.next() % UInt64(mutation.count))
                    mutation[index] ^= UInt8(truncatingIfNeeded: generator.next()) | 1
                }
                payload = mutation
            case 2:
                payload = base.prefix(Int(generator.next() % UInt64(base.count + 1)))
            case 3:
                var mutation = base
                mutation.append(contentsOf: generator.bytes(count: Int(generator.next() % 17) + 1))
                payload = mutation
            default:
                // A valid control case proves the mutation harness does not only exercise rejection.
                payload = base
            }

            do {
                let decoded = try LANClientHelloV6.decodeStrict(payload)
                XCTAssertEqual(
                    try LANClientHelloV6.decodeStrict(decoded.encoded()),
                    decoded,
                    "seed=\(seed) mutationCase=\(caseIndex)"
                )
            } catch {
                // Arbitrary or structure-derived mutations are expected to fail closed.
            }
        }
    }

    private func makeAccept(
        _ fixture: Fixture,
        active: UInt32?,
        pending: UInt32,
        socketGeneration: UInt32,
        credentialDelivery: LANV6PendingCredentialDelivery,
        authority: LANV6Authority? = nil
    ) throws -> LANServerAcceptV6 {
        try LANServerAcceptV6(
            hostInstallationID: fixture.hostID,
            worldLANID: fixture.worldID,
            lookupDigest: fixture.lookupDigest,
            authority: authority ?? fixture.authority,
            activeGeneration: active,
            pendingGeneration: pending,
            handshakeID: fixture.handshakeID,
            opaqueSocketGeneration: socketGeneration,
            epoch: fixture.epoch,
            credentialDelivery: credentialDelivery
        )
    }

    private func decodeBoundHello(
        _ data: Data,
        fixture: Fixture
    ) throws -> LANClientHelloV6 {
        try LANClientHelloV6.decodeStrict(
            data,
            expectedHostInstallationID: fixture.hostID,
            expectedWorldLANID: fixture.worldID,
            expectedLookupDigest: fixture.lookupDigest
        )
    }

    private func makeReady(
        _ fixture: Fixture,
        active: UInt32?,
        pending: UInt32,
        socketGeneration: UInt32,
        authority: LANV6Authority? = nil
    ) throws -> LANClientReadyV6 {
        try LANClientReadyV6(
            authority: authority ?? fixture.authority,
            activeGeneration: active,
            pendingGeneration: pending,
            epoch: fixture.epoch,
            handshakeID: fixture.handshakeID,
            opaqueSocketGeneration: socketGeneration,
            rawPendingToken: fixture.token
        )
    }

    private func generatedJoinCode(
        using generator: inout DeterministicGenerator
    ) throws -> LANV6JoinCode {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".utf8)
        let bytes = (0..<6).map { _ in
            alphabet[Int(generator.next() % UInt64(alphabet.count))]
        }
        return try LANV6JoinCode(String(decoding: bytes, as: UTF8.self))
    }

    private func assertPolicy(
        _ policy: LANV6FrameAdmissionPolicy,
        role: LANV6LocalRole,
        phase: LANV6ConnectionPhase,
        inbound: Set<LANV6MessageKind> = [],
        outbound: Set<LANV6MessageKind> = [],
        requireWrongRoleAndPhaseDenial: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for candidateRole in LANV6LocalRole.allCases {
            for candidatePhase in LANV6ConnectionPhase.allCases {
                for flow in LANV6FrameFlow.allCases {
                    for kind in LANV6MessageKind.allCases {
                        let expected = candidateRole == role && candidatePhase == phase &&
                            (flow == .inbound ? inbound.contains(kind) : outbound.contains(kind))
                        XCTAssertEqual(
                            policy.admits(
                                localRole: candidateRole,
                                phase: candidatePhase,
                                flow: flow,
                                kind: kind
                            ),
                            expected,
                            "policy mismatch role=\(candidateRole) phase=\(candidatePhase) flow=\(flow) kind=\(kind)",
                            file: file,
                            line: line
                        )
                    }
                }
            }
        }

        if requireWrongRoleAndPhaseDenial {
            let wrongRole: LANV6LocalRole = role == .host ? .client : .host
            for flow in LANV6FrameFlow.allCases where !LANV6MessageKind.allCases.isEmpty {
                XCTAssertFalse(policy.admits(
                    localRole: wrongRole,
                    phase: phase,
                    flow: flow,
                    kind: LANV6MessageKind.allCases[0]
                ), file: file, line: line)
            }
        }
    }
}
