import Foundation
import XCTest
@testable import PebbleCore

final class LANV6ScalarTests: XCTestCase {
    func testID128UsesExactCanonicalUnpaddedBase64URL() throws {
        let value = try LANV6ID128(bytes: [UInt8](repeating: 0, count: 16))
        XCTAssertEqual(value.base64URL, "AAAAAAAAAAAAAAAAAAAAAA")
        XCTAssertEqual(try LANV6ID128(base64URL: value.base64URL), value)
        XCTAssertEqual(String(data: try JSONEncoder().encode(value), encoding: .utf8),
                       "\"AAAAAAAAAAAAAAAAAAAAAA\"")
        XCTAssertEqual(try JSONDecoder().decode(LANV6ID128.self,
                                                from: Data("\"AAAAAAAAAAAAAAAAAAAAAA\"".utf8)),
                       value)

        XCTAssertThrowsError(try LANV6ID128(bytes: [UInt8](repeating: 0, count: 15)))
        XCTAssertThrowsError(try LANV6ID128(base64URL: "AAAAAAAAAAAAAAAAAAAAAA=="))
        XCTAssertThrowsError(try LANV6ID128(base64URL: "AAAAAAAAAAAAAAAAAAAAA+"))
        XCTAssertThrowsError(try LANV6ID128(base64URL: "AAAAAAAAAAAAAAAAAAAAAB"),
                             "unused trailing base64 bits must be canonical")
    }

    func testToken256UsesExactCanonicalUnpaddedBase64URL() throws {
        let token = try LANV6Token256(bytes: [UInt8](repeating: 0, count: 32))
        XCTAssertEqual(token.base64URL, String(repeating: "A", count: 43))
        XCTAssertEqual(token.description, LANV6Token256.redactedDescription)
        XCTAssertFalse(token.description.contains(token.base64URL))
        XCTAssertEqual(try LANV6Token256(base64URL: token.base64URL), token)
        XCTAssertThrowsError(try LANV6Token256(base64URL: token.base64URL + "="))
        XCTAssertThrowsError(try LANV6Token256(base64URL: String(repeating: "A", count: 42)))
        XCTAssertThrowsError(try LANV6Token256(base64URL:
            String(repeating: "A", count: 42) + "B"))
    }

    func testDigestUsesExactLowercaseHex() throws {
        let bytes = Array(UInt8(0)...UInt8(31))
        let digest = try LANV6SHA256Digest(bytes: bytes)
        XCTAssertEqual(digest.hex,
                       "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        XCTAssertEqual(try LANV6SHA256Digest(hex: digest.hex), digest)
        XCTAssertThrowsError(try LANV6SHA256Digest(hex: digest.hex.uppercased()))
        XCTAssertThrowsError(try LANV6SHA256Digest(hex: String(repeating: "0", count: 63)))
        XCTAssertThrowsError(try LANV6SHA256Digest(hex: String(repeating: "g", count: 64)))
    }

    func testAuthorityIsStrictAndCanonical() throws {
        XCTAssertEqual(try LANV6Authority("host:local"), .hostLocal)
        XCTAssertEqual(try LANV6Authority("lan:1"), try .guest(joinedOrdinal: 1))
        XCTAssertEqual(try LANV6Authority("lan:1000000000"),
                       try .guest(joinedOrdinal: 1_000_000_000))
        XCTAssertThrowsError(try LANV6Authority.guest(joinedOrdinal: 0))
        XCTAssertThrowsError(
            try LANV6Authority.guest(joinedOrdinal: LAN_V6_MAX_JOINED_ORDINAL + 1)
        )
        XCTAssertEqual(try LANV6Authority("lan:42").description, "lan:42")

        for invalid in ["", "host", "host:Local", "lan:", "lan:0", "lan:01", "lan:+1",
                        "lan:-1", "lan:1000000001", " lan:1", "lan:1 ", "LAN:1"] {
            XCTAssertThrowsError(try LANV6Authority(invalid), "unexpectedly accepted \(invalid)")
        }
    }

    func testDisplayNameEnforcesScalarAndSingleLineBounds() throws {
        XCTAssertEqual(try LANV6DisplayName("A").value, "A")
        XCTAssertEqual(try LANV6DisplayName(String(repeating: "a", count: 32)).value.count, 32)
        let emojiBoundary = String(repeating: "😀", count: 32)
        XCTAssertEqual(emojiBoundary.utf8.count, 128)
        XCTAssertNoThrow(try LANV6DisplayName(emojiBoundary))

        for invalid in ["", String(repeating: "a", count: 33), "a\nb", "a\rb", "a\tb",
                        "a\u{0}b", "a\u{1f}b", "a\u{7f}b", "a\u{80}b", "a\u{85}b",
                        "a\u{9f}b", "a\u{200b}b", "a\u{2028}b", "a\u{2029}b"] {
            XCTAssertThrowsError(try LANV6DisplayName(invalid))
        }
    }

    func testRegistryIDRequiresValidShapeAndClosedRegistryMembership() throws {
        let boundary = String(repeating: "a", count: 64)
        let allowed: Set<String> = ["pebble:stone", boundary]
        XCTAssertEqual(try LANV6RegistryID("pebble:stone", allowedIDs: allowed).value,
                       "pebble:stone")
        XCTAssertNoThrow(try LANV6RegistryID(boundary, allowedIDs: allowed))
        XCTAssertFalse(LANV6RegistryID.isShapeValid(""))
        XCTAssertFalse(LANV6RegistryID.isShapeValid(String(repeating: "a", count: 65)))
        XCTAssertThrowsError(try LANV6RegistryID("", allowedIDs: allowed))
        XCTAssertThrowsError(try LANV6RegistryID("pebble:dirt", allowedIDs: allowed))
    }

    func testJoinCodeShapeIsStrict() throws {
        for valid in ["AB12", "ABC123", "ABCDEFG8"] {
            let code = try LANV6JoinCode(valid)
            XCTAssertEqual(code.serialized, valid)
            XCTAssertEqual(code.description, LANV6JoinCode.redactedDescription)
            XCTAssertFalse(code.description.contains(valid))
        }
        for invalid in ["ABC", "ABCDEFGHI", "abc1", "AB-1", "AB 1", "ÅBCD"] {
            XCTAssertThrowsError(try LANV6JoinCode(invalid))
        }
    }

    func testRevisionAndScalarRangesIncludeOnlySpecifiedBoundaries() throws {
        XCTAssertEqual(try LANV6RevisionV1(0).value, 0)
        XCTAssertEqual(try LANV6RevisionV1(1_000_000_000).value, 1_000_000_000)
        XCTAssertThrowsError(try LANV6RevisionV1(1_000_000_001))
        XCTAssertThrowsError(try JSONDecoder().decode(
            LANV6RevisionV1.self,
            from: Data("1000000001".utf8)
        ))

        XCTAssertTrue(LANV6ScalarValidator.isRevision(0))
        XCTAssertTrue(LANV6ScalarValidator.isRevision(1_000_000_000))
        XCTAssertFalse(LANV6ScalarValidator.isRevision(-1))
        XCTAssertFalse(LANV6ScalarValidator.isRevision(1_000_000_001))
        XCTAssertTrue(LANV6ScalarValidator.isRequestID(1))
        XCTAssertTrue(LANV6ScalarValidator.isRequestID(1_000_000_000))
        XCTAssertFalse(LANV6ScalarValidator.isRequestID(0))
        XCTAssertFalse(LANV6ScalarValidator.isRequestID(1_000_000_001))
        XCTAssertTrue(LANV6ScalarValidator.isNextExpectedRequestID(1_000_000_001))
        XCTAssertFalse(LANV6ScalarValidator.isNextExpectedRequestID(1_000_000_002))
        XCTAssertTrue(LANV6ScalarValidator.isJoinedOrdinal(1))
        XCTAssertTrue(LANV6ScalarValidator.isJoinedOrdinal(1_000_000_000))
        XCTAssertFalse(LANV6ScalarValidator.isJoinedOrdinal(0))
    }

    func testVersionedCounterSuccessorAndTerminalSemantics() throws {
        XCTAssertEqual(LANVersionedCounterV1.zero.checkedSuccessor(),
                       try LANVersionedCounterV1(generation: 0, value: 1))
        XCTAssertEqual(try LANVersionedCounterV1(generation: 0, value: 1_000_000_000)
            .checkedSuccessor(), try LANVersionedCounterV1(generation: 1, value: 0))
        XCTAssertEqual(try LANVersionedCounterV1(generation: 999_999_999, value: 1_000_000_000)
            .checkedSuccessor(), .terminal)
        XCTAssertTrue(LANVersionedCounterV1.terminal.isTerminal)
        XCTAssertNil(LANVersionedCounterV1.terminal.checkedSuccessor())
        XCTAssertThrowsError(try LANVersionedCounterV1(generation: 1_000_000_000, value: 1))
        XCTAssertThrowsError(try LANVersionedCounterV1(generation: 1_000_000_001, value: 0))
        XCTAssertThrowsError(try LANVersionedCounterV1(generation: 0, value: 1_000_000_001))
        XCTAssertThrowsError(try JSONDecoder().decode(
            LANVersionedCounterV1.self,
            from: Data("{\"generation\":1000000000,\"value\":1}".utf8)
        ))
    }

    func testWallAndMonotonicClocksAreSeparateInjectableContracts() {
        struct Wall: LANV6WallClock {
            func nowMillisecondsSince1970() -> Int64 { 123_456 }
        }
        struct Monotonic: LANV6MonotonicClock {
            func nowNanoseconds() -> UInt64 { 987_654 }
        }
        XCTAssertEqual(Wall().nowMillisecondsSince1970(), 123_456)
        XCTAssertEqual(Monotonic().nowNanoseconds(), 987_654)
        XCTAssertGreaterThan(LANV6SystemWallClock().nowMillisecondsSince1970(), 0)
        let first = LANV6SystemMonotonicClock().nowNanoseconds()
        let second = LANV6SystemMonotonicClock().nowNanoseconds()
        XCTAssertGreaterThanOrEqual(second, first)
    }
}
