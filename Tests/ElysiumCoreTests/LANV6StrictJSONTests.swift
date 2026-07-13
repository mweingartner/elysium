import Foundation
import XCTest
@testable import ElysiumCore

final class LANV6StrictJSONTests: XCTestCase {
    private let limits = LANV6StrictJSONLimits(
        maximumBytes: 4_096,
        maximumDepth: 16,
        maximumMembers: 128,
        maximumStringBytes: 512
    )

    private func scan(_ text: String,
                      limits: LANV6StrictJSONLimits? = nil) throws -> LANV6StrictJSONScan {
        try LANV6StrictJSON.scan(Data(text.utf8), limits: limits ?? self.limits)
    }

    private func assertRejected(_ text: String, file: StaticString = #filePath,
                                line: UInt = #line) {
        XCTAssertThrowsError(try scan(text), file: file, line: line) { error in
            XCTAssertTrue(error is LANV6StrictJSONError,
                          "unexpected error \(error)", file: file, line: line)
        }
    }

    private func hello(admission: String) -> String {
        "{\"pv\":6,\"hid\":\"host\",\"wid\":\"world\",\"lk\":\"digest\",\"playerName\":\"Alex\",\"admission\":\(admission)}"
    }

    func testValidJSONKindsSyntaxAndDecodedStringBytes() throws {
        let cases: [(String, LANV6StrictJSONTopLevelKind)] = [
            ("{}", .object), ("[]", .array), ("\"text\"", .string),
            ("-12.5e+2", .number), ("true", .boolean), ("false", .boolean),
            ("null", .null),
        ]
        for (json, kind) in cases {
            XCTAssertEqual(try scan(" \n\t\(json)\r ").topLevelKind, kind, json)
        }

        let object = try scan(#"{"plain":"é","escaped":"\uD83D\uDE00","nested":[null,{"ok":true}]}"#)
        XCTAssertEqual(object.topLevelObjectKeyStrings, ["plain", "escaped", "nested"])
        XCTAssertEqual(object.totalMemberCount, 6)
        XCTAssertEqual(object.maximumObservedDepth, 3)
    }

    func testDuplicateKeysUseExactDecodedUTF8RatherThanPermissiveDecoderSemantics() throws {
        assertRejected(#"{"a":1,"a":2}"#)
        assertRejected(#"{"a":1,"\u0061":2}"#)
        assertRejected(#"{"\uD83D\uDE00":1,"😀":2}"#)

        // Canonically equivalent but byte-distinct scalar sequences are distinct
        // JSON member names; Swift String equality must not collapse them.
        let distinct = try scan(#"{"\u00E9":1,"e\u0301":2}"#)
        XCTAssertEqual(distinct.topLevelObjectKeys.count, 2)
        XCTAssertNotEqual(distinct.topLevelObjectKeys[0].utf8,
                          distinct.topLevelObjectKeys[1].utf8)
    }

    func testExactTopLevelKeySetsSupportClosedHelloAndAdmissionVariants() throws {
        let common: Set<String> = ["pv", "hid", "wid", "lk", "playerName", "admission"]
        let helloReport = try scan(#"{"admission":{"joinCode":"ABC123","kind":"joinNew"},"playerName":"Alex","lk":"digest","wid":"world","hid":"host","pv":6}"#)
        try helloReport.requireTopLevelObject(exactKeys: common)
        XCTAssertEqual(try helloReport.requireClosedHelloObjectShape(), .joinNew)
        try helloReport.requireObject(atKeyPath: ["admission"],
                                      exactKeys: ["kind", "joinCode"])
        XCTAssertThrowsError(try helloReport.requireTopLevelObject(exactKeys: common.union(["extra"])))
        XCTAssertThrowsError(try scan("[]").requireTopLevelObject(exactKeys: []))

        let variants: [(String, Set<String>, LANV6StrictJSONHelloAdmissionShape)] = [
            (#"{"kind":"joinNew","joinCode":"ABC123"}"#, ["kind", "joinCode"], .joinNew),
            (#"{"rawToken":"token","kind":"resume"}"#, ["kind", "rawToken"], .resume),
            (#"{"legacyHint":"00000000-0000-0000-0000-000000000000","rawClaimNonce":"nonce","joinCode":"ABC123","kind":"legacyClaim"}"#,
             ["kind", "joinCode", "legacyHint", "rawClaimNonce"], .legacyClaim),
            (#"{"kind":"legacyConsume","rawClaimNonce":"nonce"}"#, ["kind", "rawClaimNonce"], .legacyConsume),
        ]
        for (json, keys, shape) in variants {
            try scan(json).requireTopLevelObject(exactKeys: keys)
            XCTAssertEqual(try scan(hello(admission: json)).requireClosedHelloObjectShape(), shape)
        }
        assertRejected(#"{"kind":"resume","rawToken":"a","rawToken":"b"}"#)
    }

    func testFullHelloRejectsNestedMixedExtraMissingAndDuplicateAdmissionFields() throws {
        let invalidAdmissions = [
            #"{"kind":"joinNew"}"#,
            #"{"kind":"joinNew","joinCode":"ABC123","extra":0}"#,
            #"{"kind":"resume","rawToken":"token","joinCode":"ABC123"}"#,
            #"{"kind":"legacyConsume","rawClaimNonce":"nonce","rawToken":"token"}"#,
            #"[]"#,
        ]
        for admission in invalidAdmissions {
            let report = try scan(hello(admission: admission))
            try report.requireTopLevelObject(
                exactKeys: ["pv", "hid", "wid", "lk", "playerName", "admission"]
            )
            XCTAssertThrowsError(try report.requireClosedHelloObjectShape(), admission)
        }
        assertRejected(hello(admission: #"{"kind":"resume","kind":"joinNew","rawToken":"token"}"#))
    }

    func testPathAwareObjectsRequireStrictVersionedCounterKeys() throws {
        let report = try scan(#"{"counter":{"value":1,"generation":0},"nested":{"counter":{"generation":2,"value":3}},"rows":[{"generation":4,"value":5}]}"#)
        try report.requireVersionedCounterObject(atKeyPath: ["counter"])
        try report.requireVersionedCounterObject(atKeyPath: ["nested", "counter"])
        XCTAssertEqual(report.object(atKeyPath: ["nested"])?.keyStrings, ["counter"])
        XCTAssertEqual(report.objects.count, 5)

        let extra = try scan(#"{"counter":{"generation":0,"value":1,"extra":2}}"#)
        XCTAssertThrowsError(try extra.requireVersionedCounterObject(atKeyPath: ["counter"]))
        let missing = try scan(#"{"counter":{"generation":0}}"#)
        XCTAssertThrowsError(try missing.requireVersionedCounterObject(atKeyPath: ["counter"]))
        let scalar = try scan(#"{"counter":1}"#)
        XCTAssertThrowsError(try scalar.requireVersionedCounterObject(atKeyPath: ["counter"]))
        assertRejected(#"{"counter":{"generation":0,"generation":1,"value":2}}"#)
    }

    func testRejectsMalformedUTF8EscapesUnicodeNumbersAndTrailingBytes() {
        let invalidUTF8 = Data([0x22, 0xC0, 0xAF, 0x22])
        XCTAssertThrowsError(try LANV6StrictJSON.scan(invalidUTF8, limits: limits))

        for json in [
            "", " ", "{", "[", #""unterminated"#, #""\x""#,
            #""\u12G4""#, #""\uD800""#, #""\uDC00""#,
            #""\uD800\u0041""#, "\"line\nfeed\"",
            "+1", "01", "-01", "1.", "1e", "1e+", ".1",
            "NaN", "Infinity", "-Infinity", "1e400",
            "true false", "{}[]", "{}\u{0}", "[1,]", "{\"a\":1,}",
            "{a:1}", "{\"a\" 1}", "[1 2]",
        ] {
            assertRejected(json)
        }
    }

    func testEveryConfiguredCapAcceptsBoundaryAndRejectsOneOver() throws {
        let exactBytes = Data("{\"a\":1}".utf8)
        _ = try LANV6StrictJSON.scan(exactBytes, limits: LANV6StrictJSONLimits(
            maximumBytes: exactBytes.count, maximumDepth: 1,
            maximumMembers: 1, maximumStringBytes: 1
        ))
        XCTAssertThrowsError(try LANV6StrictJSON.scan(exactBytes, limits: LANV6StrictJSONLimits(
            maximumBytes: exactBytes.count - 1, maximumDepth: 1,
            maximumMembers: 1, maximumStringBytes: 1
        )))
        XCTAssertThrowsError(try scan("[[0]]", limits: LANV6StrictJSONLimits(
            maximumBytes: 5, maximumDepth: 1,
            maximumMembers: 2, maximumStringBytes: 0
        )))
        XCTAssertThrowsError(try scan("[0,1]", limits: LANV6StrictJSONLimits(
            maximumBytes: 5, maximumDepth: 1,
            maximumMembers: 1, maximumStringBytes: 0
        )))
        _ = try scan(#""\uD83D\uDE00""#, limits: LANV6StrictJSONLimits(
            maximumBytes: 14, maximumDepth: 0,
            maximumMembers: 0, maximumStringBytes: 4
        ))
        XCTAssertThrowsError(try scan(#""\uD83D\uDE00""#, limits: LANV6StrictJSONLimits(
            maximumBytes: 14, maximumDepth: 0,
            maximumMembers: 0, maximumStringBytes: 3
        )))
        XCTAssertThrowsError(try scan("{}", limits: LANV6StrictJSONLimits(
            maximumBytes: -1, maximumDepth: 1,
            maximumMembers: 1, maximumStringBytes: 1
        )))
    }

    func testSeededTenThousandArbitraryPayloadsNeverTrapAndAcceptanceImpliesFoundationSyntax() throws {
        let rootSeed: UInt64 = 0x5045_4242_4C45_5636
        var state = rootSeed
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        let fuzzLimits = LANV6StrictJSONLimits(
            maximumBytes: 96, maximumDepth: 8,
            maximumMembers: 32, maximumStringBytes: 48
        )

        for caseIndex in 0..<10_000 {
            let length = Int(next() % 97)
            var payload = Data(capacity: length)
            for _ in 0..<length { payload.append(UInt8(truncatingIfNeeded: next() >> 24)) }
            do {
                let report = try LANV6StrictJSON.scan(payload, limits: fuzzLimits)
                XCTAssertLessThanOrEqual(report.byteCount, fuzzLimits.maximumBytes,
                                         "seed=\(rootSeed) case=\(caseIndex) bytes=\(payload as NSData)")
                XCTAssertLessThanOrEqual(report.totalMemberCount, fuzzLimits.maximumMembers)
                XCTAssertLessThanOrEqual(report.maximumObservedDepth, fuzzLimits.maximumDepth)
                XCTAssertNoThrow(try JSONSerialization.jsonObject(
                    with: payload, options: [.fragmentsAllowed]
                ), "seed=\(rootSeed) case=\(caseIndex) bytes=\(payload as NSData)")
            } catch is LANV6StrictJSONError {
                // Rejection is the expected outcome for arbitrary bytes.
            } catch {
                XCTFail("unexpected error seed=\(rootSeed) case=\(caseIndex) bytes=\(payload as NSData): \(error)")
            }
        }
    }
}
