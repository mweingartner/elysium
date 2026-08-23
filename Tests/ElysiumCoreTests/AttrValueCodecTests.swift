// AttrValueCodecTests.swift — object-graph-attributes (change 1a). Spec
// `object-attribute-store` "AttrValue and its canonical JSON": round trip +
// determinism, int/float distinction, `-0`, caps, `$ref`/key rules, malformed
// corpus, and a random-bytes/mutation fuzz pass that never traps.

import XCTest
@testable import ElysiumCore

final class AttrValueCodecTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private let caps = ScriptingStorageCaps.defaults

    // MARK: - round trip + determinism (property)

    func testRoundTripAndDeterminismOver20000SeededValues() {
        var rng = RandomX(13_579)
        for i in 0..<20_000 {
            let value = randomValue(&rng, depth: 0)
            let text1 = AttrValueCodec.encode(value)
            let text2 = AttrValueCodec.encode(value)
            XCTAssertEqual(text1, text2, "encode must be a pure function of the value (iteration \(i))")
            switch AttrValueCodec.decode(text1, caps: caps) {
            case .success(let decoded):
                XCTAssertEqual(decoded, value, "round trip mismatch at iteration \(i) for '\(text1)'")
            case .failure(let err):
                XCTFail("decode(encode(v)) failed at iteration \(i): \(err) for '\(text1)'")
            }
        }
    }

    func testIntAndFloatSurviveDistinctly() {
        XCTAssertEqual(AttrValueCodec.encode(.int(3)), "3")
        XCTAssertEqual(AttrValueCodec.encode(.number(3.0)), "3.0")
        guard case .success(.int(3)) = AttrValueCodec.decode("3", caps: caps) else { return XCTFail() }
        guard case .success(.number(3.0)) = AttrValueCodec.decode("3.0", caps: caps) else { return XCTFail() }
    }

    func testNegativeZeroNormalizesToZero() {
        XCTAssertEqual(AttrValueCodec.encode(.number(-0.0)), "0.0")
        guard case .success(.int(0)) = AttrValueCodec.decode("-0", caps: caps) else {
            return XCTFail("'-0' should decode as int 0")
        }
    }

    private func randomValue(_ rng: inout RandomX, depth: Int) -> AttrValue {
        let maxCase = depth >= 3 ? 4 : 7
        switch rng.nextInt(maxCase + 1) {
        case 0: return .null
        case 1: return .bool(rng.nextFloat() < 0.5)
        case 2: return .int(Int64(rng.nextInt(2_000_000_001) - 1_000_000_000))
        case 3:
            let d = (Double(rng.nextInt(2_000_000)) - 1_000_000) / 137.0
            return .number(d)
        case 4:
            let len = rng.nextInt(12)
            let alphabet = Array("abcdefghij ._-")
            return .string(String((0..<len).map { _ in alphabet[rng.nextInt(alphabet.count)] }))
        case 5:
            let n = rng.nextInt(4)
            return .list((0..<n).map { _ in randomValue(&rng, depth: depth + 1) })
        case 6:
            let n = rng.nextInt(4)
            var dict: [String: AttrValue] = [:]
            for _ in 0..<n {
                let key = "k" + String(rng.nextInt(1000))
                dict[key] = randomValue(&rng, depth: depth + 1)
            }
            return .map(dict)
        default:
            return .ref("entity:\(1 + rng.nextInt(1000))")
        }
    }

    // MARK: - caps

    func testStringTooLong() {
        let s = String(repeating: "x", count: caps.value.stringBytes + 1)
        XCTAssertEqual(AttrValueCodec.validate(.string(s), caps: caps), .stringTooLong(limit: caps.value.stringBytes))
    }

    func testListTooLong() {
        let list = AttrValue.list(Array(repeating: .null, count: caps.value.listElements + 1))
        XCTAssertEqual(AttrValueCodec.validate(list, caps: caps), .listTooLong(limit: caps.value.listElements))
    }

    func testMapTooLarge() {
        var dict: [String: AttrValue] = [:]
        for i in 0..<(caps.value.mapKeys + 1) { dict["k\(i)"] = .null }
        XCTAssertEqual(AttrValueCodec.validate(.map(dict), caps: caps), .mapTooLarge(limit: caps.value.mapKeys))
    }

    func testTooDeep() {
        var v: AttrValue = .null
        for _ in 0...(caps.value.depth + 1) { v = .list([v]) }
        XCTAssertEqual(AttrValueCodec.validate(v, caps: caps), .tooDeep(limit: caps.value.depth))
    }

    func testMapKeyMayNotStartWithDollar() {
        XCTAssertEqual(AttrValueCodec.validate(.map(["$x": .null]), caps: caps), .mapKeyInvalid)
    }

    func testRefMustParse() {
        XCTAssertEqual(AttrValueCodec.validate(.ref("World"), caps: caps), .invalidRef)
        XCTAssertNil(AttrValueCodec.validate(.ref("world"), caps: caps))
    }

    // MARK: - $ref encoding

    func testRefEncodesAsDollarRefObject() {
        XCTAssertEqual(AttrValueCodec.encode(.ref("player")), "{\"$ref\":\"player\"}")
        guard case .success(.ref("player")) = AttrValueCodec.decode("{\"$ref\":\"player\"}", caps: caps) else {
            return XCTFail()
        }
    }

    func testDollarRefWithInvalidRefStringIsRejected() {
        guard case .failure = AttrValueCodec.decode("{\"$ref\":\"World\"}", caps: caps) else {
            return XCTFail("capitalized 'World' is not a canonical ref and must be rejected")
        }
    }

    func testDollarKeyOtherThanRefIsRejected() {
        guard case .failure = AttrValueCodec.decode("{\"$x\":1}", caps: caps) else { return XCTFail() }
    }

    func testMapKeysSortedByUTF8ByteOrder() {
        let value = AttrValue.map(["b": .int(2), "a": .int(1), "aa": .int(3)])
        XCTAssertEqual(AttrValueCodec.encode(value), "{\"a\":1,\"aa\":3,\"b\":2}")
    }

    // MARK: - malformed corpus (never traps)

    func testMalformedFixedCorpus() {
        let corpus = [
            "{\"a\":1,\"a\":2}", "01", "1.", "NaN", "1e999", " ",
            "[[[[[0]]]]]", // 5-deep list of a non-list leaf... see below for exact depth case
            "{\"$ref\":\"World\"}", "{\"$x\":1}",
            "\"" + String(repeating: "x", count: 5_000) + "\"",
            "\"\u{2028}\"",
            "\"\\uD800\"",
        ]
        for text in corpus {
            switch AttrValueCodec.decode(text, caps: caps) {
            case .failure: break
            case .success(let v):
                // "01" et al must never succeed; if any of these unexpectedly
                // parse, fail loudly rather than silently accept bad input.
                XCTFail("expected '\(text)' to be refused, got \(v)")
            }
        }
    }

    func testDeepListRejected() {
        // depth 5 (cap is 4)
        let text = "[[[[[0]]]]]"
        guard case .failure = AttrValueCodec.decode(text, caps: caps) else {
            return XCTFail("5-deep nesting should exceed the depth-4 cap")
        }
    }

    func test300ElementListRejected() {
        let text = "[" + (0..<300).map { _ in "0" }.joined(separator: ",") + "]"
        guard case .failure = AttrValueCodec.decode(text, caps: caps) else { return XCTFail() }
    }

    func test70KeyMapRejected() {
        let text = "{" + (0..<70).map { "\"k\($0)\":0" }.joined(separator: ",") + "}"
        guard case .failure = AttrValueCodec.decode(text, caps: caps) else { return XCTFail() }
    }

    // MARK: - fuzz: random bytes and mutations never trap

    func testRandomByteStringsNeverTrap() {
        var rng = RandomX(24_680)
        let alphabet = Array("{}[]\":,.0123456789-+eE truNulsfa\\$refx ")
        for _ in 0..<5_000 {
            let len = rng.nextInt(80)
            let s = String((0..<len).map { _ in alphabet[rng.nextInt(alphabet.count)] })
            _ = AttrValueCodec.decode(s, caps: caps) // must not trap regardless of outcome
        }
    }

    // MARK: - coverage gap 1: Int64-overflow integer tokens (Test coverage gap 1)

    func testInt64OverflowTokensRefused() {
        guard case .failure = AttrValueCodec.decode("9223372036854775808", caps: caps) else {
            return XCTFail("one past Int64.max must be refused, never coerced to Double")
        }
        guard case .failure = AttrValueCodec.decode("-9223372036854775809", caps: caps) else {
            return XCTFail("one past Int64.min must be refused, never coerced to Double")
        }
        // The exact boundary values themselves are valid Int64 tokens.
        guard case .success(.int(Int64.max)) = AttrValueCodec.decode("9223372036854775807", caps: caps) else {
            return XCTFail("Int64.max itself must decode")
        }
        guard case .success(.int(Int64.min)) = AttrValueCodec.decode("-9223372036854775808", caps: caps) else {
            return XCTFail("Int64.min itself must decode")
        }
    }

    // MARK: - coverage gap 2: $ref with a second key (Test coverage gap 2)

    func testDollarRefWithASecondKeyIsRejectedInBothOrders() {
        guard case .failure = AttrValueCodec.decode("{\"$ref\":\"player\",\"extra\":1}", caps: caps) else {
            return XCTFail("a $ref object must have exactly one key ($ref first, extra second)")
        }
        guard case .failure = AttrValueCodec.decode("{\"extra\":1,\"$ref\":\"player\"}", caps: caps) else {
            return XCTFail("a $ref object must have exactly one key (extra first, $ref second)")
        }
    }

    // MARK: - coverage gap 3: exponent-edge corpus (Test coverage gap 3)

    func testExponentEdgesDecodeAndEncoderIsLowercaseSignedOnly() {
        for text in ["1e10", "1e+10", "1e-10", "1E10", "1E+10", "1E-10", "1.5e3"] {
            guard case .success(.number) = AttrValueCodec.decode(text, caps: caps) else {
                return XCTFail("'\(text)' must decode as a float")
            }
        }
        // The encoder only ever emits what it emits — no uppercase 'E', and any
        // exponent it does produce carries an explicit sign — never bare "e10".
        for magnitude in [1e10, 1e-10, 1e100, 1e-100, 1.5e20] {
            let text = AttrValueCodec.encode(.number(magnitude))
            XCTAssertFalse(text.contains("E"), "encoder must never emit uppercase E: '\(text)'")
            if let eIndex = text.firstIndex(of: "e") {
                let after = text.index(after: eIndex)
                XCTAssertTrue(after < text.endIndex && (text[after] == "+" || text[after] == "-"),
                              "encoder's exponent must carry an explicit sign: '\(text)'")
            }
        }
    }

    // MARK: - Test N2: the parser itself enforces the node cap, not only `validate()`

    func testDecodeEnforcesNodeCapDirectly() {
        // 1,111 nodes (one over the 1,024 default) — decode must refuse it even
        // though nothing calls `validate()` first. The raw parser collapses every
        // internal failure (including this one) to `.malformed`, the same as any
        // other structurally-refused text — `tooManyNodes` is a `validate()`-only
        // diagnostic, not a decode-time one.
        let text = "[" + Array(repeating: "0", count: 1_111).joined(separator: ",") + "]"
        guard case .failure(.malformed) = AttrValueCodec.decode(text, caps: caps) else {
            return XCTFail("decode must itself enforce the node cap, independent of validate()")
        }
        // Exactly at the cap (1,024 elements = 1,024 leaf nodes + 1 list node = 1,025
        // total... the cap counts every node including containers, so use a size that
        // is safely under it end to end) must still decode.
        let underCap = "[" + Array(repeating: "0", count: 100).joined(separator: ",") + "]"
        guard case .success = AttrValueCodec.decode(underCap, caps: caps) else {
            return XCTFail("a value safely under the node cap must still decode")
        }
    }

    func testMutationsOfValidTextsNeverTrap() {
        var rng = RandomX(97_531)
        let seeds = [
            AttrValueCodec.encode(.map(["mood": .string("happy"), "n": .int(7), "list": .list([.bool(true), .null])])),
            AttrValueCodec.encode(.ref("player")),
            AttrValueCodec.encode(.number(1.5)),
        ]
        for _ in 0..<2_000 {
            var bytes = Array(seeds[rng.nextInt(seeds.count)].utf8)
            guard !bytes.isEmpty else { continue }
            let idx = rng.nextInt(bytes.count)
            bytes[idx] = UInt8(rng.nextInt(256))
            let mutated = String(decoding: bytes, as: UTF8.self)
            _ = AttrValueCodec.decode(mutated, caps: caps) // must not trap
        }
    }
}
