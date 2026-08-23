// ObjectRecordCodecTests.swift — object-graph-attributes (change 1a). Spec
// `object-attribute-store` "ObjectRecord, entries and provenance": exact
// round-trip text, bad-entry tolerance, `v != 1`, provenance grammar.

import XCTest
@testable import ElysiumCore

final class ObjectRecordCodecTests: XCTestCase {
    private let caps = ScriptingStorageCaps.defaults

    func testRecordRoundTripExactText() {
        var record = ObjectRecord(revision: 7)
        record.entries["mood"] = .value(.string("happy"), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 42))
        record.entries["owner"] = .value(.ref("player"), readonly: true, provenance: Provenance(createdBy: .player, createdTick: 42))
        let text = ObjectRecordCodec.encode(record)
        XCTAssertEqual(
            text,
            "{\"attrs\":{\"mood\":{\"by\":\"player\",\"ro\":false,\"t\":42,\"v\":\"happy\"},"
                + "\"owner\":{\"by\":\"player\",\"ro\":true,\"t\":42,\"v\":{\"$ref\":\"player\"}}},\"rev\":7,\"v\":1}"
        )
        guard let decoded = ObjectRecordCodec.decode(text, caps: caps) else { return XCTFail("decode failed") }
        XCTAssertEqual(decoded.revision, 7)
        XCTAssertEqual(decoded.entries.count, 2)
        guard case .value(.string("happy"), false, let moodProv)? = decoded.entries["mood"] else {
            return XCTFail("mood entry mismatch")
        }
        XCTAssertEqual(moodProv.createdBy, .player)
        XCTAssertEqual(moodProv.createdTick, 42)
        guard case .value(.ref("player"), true, _)? = decoded.entries["owner"] else {
            return XCTFail("owner entry mismatch")
        }
    }

    func testEmptyRecordRoundTrip() {
        let record = ObjectRecord()
        let text = ObjectRecordCodec.encode(record)
        XCTAssertEqual(text, "{\"attrs\":{},\"rev\":0,\"v\":1}")
        guard let decoded = ObjectRecordCodec.decode(text, caps: caps) else { return XCTFail() }
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(decoded.revision, 0)
    }

    func testBadEntriesAreDroppedRecordSurvives() {
        let text = """
        {"attrs":{\
        "valid":{"by":"player","ro":false,"t":1,"v":1},\
        "scripted":{"k":"s","by":"player","ro":false,"t":1,"v":1},\
        "9lives":{"by":"player","ro":false,"t":1,"v":1},\
        "toolong":{"by":"player","ro":false,"t":1,"v":"\(String(repeating: "x", count: 4_097))"},\
        "badauth":{"by":"robot","ro":false,"t":1,"v":1}\
        },"rev":1,"v":1}
        """
        var diagnostics: [String] = []
        guard let decoded = ObjectRecordCodec.decode(text, caps: caps, diagnostic: { diagnostics.append($0) }) else {
            return XCTFail("the whole record must not be dropped for per-entry problems")
        }
        XCTAssertEqual(decoded.entries.count, 1)
        XCTAssertNotNil(decoded.entries["valid"])
        XCTAssertEqual(diagnostics.count, 4)
    }

    func testVersionOtherThan1DropsWholeRecord() {
        let text = "{\"attrs\":{},\"rev\":0,\"v\":2}"
        XCTAssertNil(ObjectRecordCodec.decode(text, caps: caps))
    }

    func testMissingVersionDropsWholeRecord() {
        let text = "{\"attrs\":{}}"
        XCTAssertNil(ObjectRecordCodec.decode(text, caps: caps))
    }

    func testUnknownTopLevelKeysAreTolerated() {
        // forward-compat (Security (plan) pass note): unknown top-level keys
        // (e.g. a future "scripts" section written by a newer build) are
        // skipped, not fatal.
        let text = "{\"attrs\":{},\"scripts\":{},\"future\":[1,2,3],\"rev\":0,\"v\":1}"
        guard let decoded = ObjectRecordCodec.decode(text, caps: caps) else { return XCTFail() }
        XCTAssertTrue(decoded.isEmpty)
    }

    func testMalformedTextNeverTraps() {
        let corpus = ["", "{", "{}", "{\"attrs\":", "not json at all", "{\"attrs\":{},\"rev\":-1,\"v\":1}"]
        for text in corpus {
            _ = ObjectRecordCodec.decode(text, caps: caps) // must not trap
        }
    }

    // MARK: - name grammar

    func testAttributeNameGrammar() {
        XCTAssertTrue(isValidAttributeName("mood"))
        XCTAssertTrue(isValidAttributeName("a"))
        XCTAssertTrue(isValidAttributeName(String(repeating: "a", count: 32)))
        XCTAssertFalse(isValidAttributeName(""))
        XCTAssertFalse(isValidAttributeName(String(repeating: "a", count: 33)))
        XCTAssertFalse(isValidAttributeName("9lives"))
        XCTAssertFalse(isValidAttributeName("Mood"))
        XCTAssertFalse(isValidAttributeName("mo od"))
    }

    func testNormalizationHint() {
        XCTAssertEqual(normalizedAttributeNameHint("Mood"), "mood")
        XCTAssertEqual(normalizedAttributeNameHint("9lives"), "a9lives")
    }

    // MARK: - revision clamp (Security (plan) C26)

    func testRevisionClampedAtDecodeAndAttrSetStillSucceeds() {
        let text = "{\"attrs\":{},\"rev\":18446744073709551615,\"v\":1}"
        guard let decoded = ObjectRecordCodec.decode(text, caps: caps) else { return XCTFail() }
        XCTAssertLessThanOrEqual(decoded.revision, ObjectRecordCodec.maxStoredRevision)
        // a subsequent bump must not trap
        XCTAssertNoThrow(decoded.revision.addingReportingOverflow(1))
        let (bumped, overflow) = decoded.revision.addingReportingOverflow(1)
        XCTAssertFalse(overflow)
        XCTAssertGreaterThan(bumped, decoded.revision)
    }

    func testStrictIntegerTokensRejectLeadingZeroAndPlus() {
        XCTAssertNil(ObjectRecordCodec.decode("{\"attrs\":{},\"rev\":007,\"v\":1}", caps: caps))
        XCTAssertNil(ObjectRecordCodec.decode("{\"attrs\":{},\"rev\":0,\"v\":+1}", caps: caps))
    }

    // MARK: - coverage gap 4: empty-bag record with revision > 0 persists/reloads

    func testEmptyBagRecordWithNonzeroRevisionRoundTrips() {
        let record = ObjectRecord(revision: 41)
        let text = ObjectRecordCodec.encode(record)
        XCTAssertEqual(text, "{\"attrs\":{},\"rev\":41,\"v\":1}")
        guard let decoded = ObjectRecordCodec.decode(text, caps: caps) else { return XCTFail() }
        XCTAssertTrue(decoded.isEmpty)
        XCTAssertEqual(decoded.revision, 41)
    }

    // MARK: - coverage gap 7 / Test N1: rev/t type-refusals and negative-t refusal

    func testRevisionAsFloatStringOrBoolIsRefused() {
        XCTAssertNil(ObjectRecordCodec.decode("{\"attrs\":{},\"rev\":1.5,\"v\":1}", caps: caps), "float rev must be refused")
        XCTAssertNil(ObjectRecordCodec.decode("{\"attrs\":{},\"rev\":\"1\",\"v\":1}", caps: caps), "string rev must be refused")
        XCTAssertNil(ObjectRecordCodec.decode("{\"attrs\":{},\"rev\":true,\"v\":1}", caps: caps), "bool rev must be refused")
    }

    func testRevisionAboveUInt64MaxIsRefused() {
        XCTAssertNil(
            ObjectRecordCodec.decode("{\"attrs\":{},\"rev\":99999999999999999999,\"v\":1}", caps: caps),
            "a rev token that overflows UInt64 must be refused, not silently clamped or coerced"
        )
    }

    /// Test N1: a negative `"t"` inside an entry is a malformed *entry* — dropped
    /// with the rest, never silently kept (the record itself survives, matching
    /// every other bad-entry case).
    func testNegativeTickInEntryIsDroppedEntrySurvivesRecord() {
        // The codec's parser is strict-canonical (no insignificant whitespace
        // tolerance between tokens) — this text must be a single unbroken line.
        let text = "{\"attrs\":{\"good\":{\"by\":\"player\",\"ro\":false,\"t\":5,\"v\":1},\"bad\":{\"by\":\"player\",\"ro\":false,\"t\":-5,\"v\":2}},\"rev\":0,\"v\":1}"
        guard let decoded = ObjectRecordCodec.decode(text, caps: caps) else { return XCTFail("record must survive") }
        XCTAssertEqual(decoded.entries.count, 1, "the negative-t entry must be dropped, not the whole record")
        guard case .value(.int(1), _, let prov)? = decoded.entries["good"] else {
            return XCTFail("the well-formed entry must survive untouched")
        }
        XCTAssertEqual(prov.createdTick, 5)
        XCTAssertNil(decoded.entries["bad"], "the negative-t entry must not be present")
    }

    func testTypeAsFloatStringOrBoolInEntryIsDroppedEntrySurvivesRecord() {
        for badT in ["1.5", "\"5\"", "true"] {
            let text = "{\"attrs\":{\"good\":{\"by\":\"player\",\"ro\":false,\"t\":5,\"v\":1},\"bad\":{\"by\":\"player\",\"ro\":false,\"t\":\(badT),\"v\":2}},\"rev\":0,\"v\":1}"
            guard let decoded = ObjectRecordCodec.decode(text, caps: caps) else {
                return XCTFail("record must survive for t=\(badT)")
            }
            XCTAssertEqual(decoded.entries.count, 1, "malformed-t entry (\(badT)) must be dropped")
            XCTAssertNil(decoded.entries["bad"])
        }
    }
}
