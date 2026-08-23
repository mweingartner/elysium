// AttrValueCodec.swift — object-graph-attributes (change 1a). design.md
// Decision 4 / spec `object-attribute-store` "AttrValue and its canonical
// JSON". `AttrValue` is `ScriptValue` (`ElysiumScript`'s Lua<->Swift value
// currency, Appendix E item 5 of the embed-lua-runtime design); Core owns ref
// validation and a canonical, deterministic, strict-round-trip JSON text for
// it — never `JSONSerialization`, which cannot keep `3` and `3.0` distinct and
// silently resolves duplicate keys.

import ElysiumScript

public typealias AttrValue = ScriptValue

/// Every way an `AttrValue` (or its stored text) can be refused. Never names
/// the offending value itself (which could be arbitrarily large or malformed) —
/// only the exceeded cap or the shape of the problem.
public enum AttrValueError: Error, Equatable, Sendable {
    case notFinite
    case stringTooLong(limit: Int)
    case stringNotClean
    case listTooLong(limit: Int)
    case mapTooLarge(limit: Int)
    case mapKeyTooLong(limit: Int)
    case mapKeyInvalid
    case tooDeep(limit: Int)
    case tooManyNodes(limit: Int)
    case invalidRef
    case malformed

    public var message: String {
        switch self {
        case .notFinite: return "number must be finite"
        case .stringTooLong(let limit): return "string exceeds \(limit) bytes"
        case .stringNotClean: return "string contains disallowed characters"
        case .listTooLong(let limit): return "list exceeds \(limit) elements"
        case .mapTooLarge(let limit): return "map exceeds \(limit) keys"
        case .mapKeyTooLong(let limit): return "map key exceeds \(limit) bytes"
        case .mapKeyInvalid: return "map key is invalid"
        case .tooDeep(let limit): return "value nesting exceeds depth \(limit)"
        case .tooManyNodes(let limit): return "value exceeds \(limit) nodes"
        case .invalidRef: return "ref does not parse"
        case .malformed: return "value is malformed"
        }
    }
}

public enum AttrValueCodec {
    // MARK: - validate

    /// Checks `value` against `caps` (finite numbers, hygiene-clean/bounded
    /// strings, list/map/depth/node caps, map keys 1...`maxMapKeyBytes` bytes
    /// and never starting with `$`, `.ref` parses) without encoding it.
    /// Returns the first violation found, or `nil` when valid.
    public static func validate(_ value: AttrValue, caps: ScriptingStorageCaps) -> AttrValueError? {
        var nodeCount = 0
        return validate(value, caps: caps, depth: 0, nodeCount: &nodeCount)
    }

    private static func validate(
        _ value: AttrValue, caps: ScriptingStorageCaps, depth: Int, nodeCount: inout Int
    ) -> AttrValueError? {
        nodeCount += 1
        if nodeCount > caps.value.nodes { return .tooManyNodes(limit: caps.value.nodes) }
        if depth > caps.value.depth { return .tooDeep(limit: caps.value.depth) }
        switch value {
        case .null, .bool, .int:
            return nil
        case .number(let d):
            return d.isFinite ? nil : .notFinite
        case .string(let s):
            guard s.utf8.count <= caps.value.stringBytes else {
                return .stringTooLong(limit: caps.value.stringBytes)
            }
            guard ScriptTextHygiene.isClean(s) else { return .stringNotClean }
            return nil
        case .list(let items):
            guard items.count <= caps.value.listElements else {
                return .listTooLong(limit: caps.value.listElements)
            }
            for item in items {
                if let err = validate(item, caps: caps, depth: depth + 1, nodeCount: &nodeCount) { return err }
            }
            return nil
        case .map(let dict):
            guard dict.count <= caps.value.mapKeys else { return .mapTooLarge(limit: caps.value.mapKeys) }
            for key in dict.keys.sorted(by: utf8Less) {
                let keyBytes = key.utf8.count
                guard keyBytes >= 1, keyBytes <= caps.maxMapKeyBytes else {
                    return .mapKeyTooLong(limit: caps.maxMapKeyBytes)
                }
                guard ScriptTextHygiene.isClean(key), !key.hasPrefix("$") else { return .mapKeyInvalid }
                if let err = validate(dict[key]!, caps: caps, depth: depth + 1, nodeCount: &nodeCount) {
                    return err
                }
            }
            return nil
        case .ref(let r):
            return ObjectRef.parse(r) != nil ? nil : .invalidRef
        }
    }

    // MARK: - encode (canonical text — a pure function of the value)

    /// Canonical JSON text: object keys sorted by UTF-8 byte order, no
    /// whitespace, `Int64` printed decimal, `Double` printed with Swift's
    /// shortest round-trip `description` (`-0` normalized to `0`; non-finite
    /// values are the caller's bug — they print as `0` rather than corrupt the
    /// document), fixed escapes, refs as `{"$ref":"<canonical ref>"}`.
    public static func encode(_ value: AttrValue) -> String {
        var out = ""
        out.reserveCapacity(64)
        encode(value, into: &out)
        return out
    }

    private static func encode(_ value: AttrValue, into out: inout String) {
        switch value {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .number(let d):
            let normalized = d.isFinite ? (d == 0 ? 0.0 : d) : 0.0
            out += normalized.description
        case .string(let s):
            encodeString(s, into: &out)
        case .list(let items):
            out += "["
            for (idx, item) in items.enumerated() {
                if idx > 0 { out += "," }
                encode(item, into: &out)
            }
            out += "]"
        case .map(let dict):
            out += "{"
            let keys = dict.keys.sorted(by: utf8Less)
            for (idx, key) in keys.enumerated() {
                if idx > 0 { out += "," }
                encodeString(key, into: &out)
                out += ":"
                encode(dict[key]!, into: &out)
            }
            out += "}"
        case .ref(let r):
            out += "{\"$ref\":"
            encodeString(r, into: &out)
            out += "}"
        }
    }

    private static func encodeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += "\\u00" + hex2(scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    private static func hex2(_ v: UInt32) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int((v >> 4) & 0xF)], digits[Int(v & 0xF)]])
    }

    // MARK: - decode (strict recursive-descent, no JSONSerialization)

    /// Parses `text` as the canonical grammar this codec's own `encode`
    /// produces (plus the ordinary JSON literal spellings): no whitespace
    /// anywhere, no duplicate map keys, no leading zeros, `Int64` vs `Double`
    /// tokens distinguished by the presence of `.`/`e`/`E`, `{"$ref":"..."}`
    /// decoded only as a ref (any other `$`-prefixed key is refused), string
    /// escapes limited to the fixed set `encode` emits (`\u` only ever spells
    /// `\u00XX` for a control byte — this alone rejects every non-canonical
    /// `\u` escape, including an unpaired surrogate like `\uD800`). Caps are
    /// enforced as each token is built, never after unbounded accumulation.
    /// Never traps; always returns `nil`/a named `AttrValueError`.
    public static func decode(_ text: String, caps: ScriptingStorageCaps) -> Result<AttrValue, AttrValueError> {
        var parser = Parser(text: text, caps: caps)
        guard let value = parser.parseValue(depth: 0), parser.atEnd else {
            return .failure(.malformed)
        }
        return .success(value)
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        let caps: ScriptingStorageCaps
        // Test N2: the parser itself must enforce the node cap, not only the separate
        // post-decode `validate()` pass — a value can reach `decode` directly (entity/
        // player/world-record document paths, command-typed values) without ever going
        // through `validate()` first.
        var nodeCount = 0

        init(text: String, caps: ScriptingStorageCaps) {
            self.bytes = Array(text.utf8)
            self.caps = caps
        }

        var atEnd: Bool { i >= bytes.count }
        func peek() -> UInt8? { i < bytes.count ? bytes[i] : nil }

        mutating func parseValue(depth: Int) -> AttrValue? {
            guard depth <= caps.value.depth, let c = peek() else { return nil }
            nodeCount += 1
            guard nodeCount <= caps.value.nodes else { return nil }
            switch c {
            case UInt8(ascii: "n"): return parseLiteral("null", .null)
            case UInt8(ascii: "t"): return parseLiteral("true", .bool(true))
            case UInt8(ascii: "f"): return parseLiteral("false", .bool(false))
            case UInt8(ascii: "\""):
                return parseString().map { .string($0) }
            case UInt8(ascii: "["):
                return parseList(depth: depth)
            case UInt8(ascii: "{"):
                return parseMapOrRef(depth: depth)
            case UInt8(ascii: "-"), 0x30...0x39:
                return parseNumber()
            default:
                return nil
            }
        }

        private mutating func parseLiteral(_ text: String, _ value: AttrValue) -> AttrValue? {
            let tokenBytes = Array(text.utf8)
            guard i + tokenBytes.count <= bytes.count else { return nil }
            for k in 0..<tokenBytes.count where bytes[i + k] != tokenBytes[k] { return nil }
            i += tokenBytes.count
            return value
        }

        private mutating func parseNumber() -> AttrValue? {
            let start = i
            if peek() == UInt8(ascii: "-") { i += 1 }
            guard let d0 = peek(), d0 >= 0x30, d0 <= 0x39 else { return nil }
            if d0 == UInt8(ascii: "0") {
                i += 1
                if let n = peek(), n >= 0x30, n <= 0x39 { return nil } // leading zero
            } else {
                while let d = peek(), d >= 0x30, d <= 0x39 { i += 1 }
            }
            var isFloat = false
            if peek() == UInt8(ascii: ".") {
                isFloat = true
                i += 1
                guard let d = peek(), d >= 0x30, d <= 0x39 else { return nil }
                while let d = peek(), d >= 0x30, d <= 0x39 { i += 1 }
            }
            if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
                isFloat = true
                i += 1
                if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { i += 1 }
                guard let d = peek(), d >= 0x30, d <= 0x39 else { return nil }
                while let d = peek(), d >= 0x30, d <= 0x39 { i += 1 }
            }
            let token = String(decoding: bytes[start..<i], as: UTF8.self)
            if isFloat {
                guard let d = Double(token), d.isFinite else { return nil }
                return .number(d)
            }
            guard let iv = Int64(token) else { return nil }
            return .int(iv)
        }

        private static func utf8SequenceLength(_ lead: UInt8) -> Int {
            if lead < 0x80 { return 1 }
            if lead & 0xE0 == 0xC0 { return 2 }
            if lead & 0xF0 == 0xE0 { return 3 }
            if lead & 0xF8 == 0xF0 { return 4 }
            return 0
        }

        private static func hexVal(_ b: UInt8) -> UInt32? {
            switch b {
            case 0x30...0x39: return UInt32(b - 0x30)
            case 0x61...0x66: return UInt32(b - 0x61 + 10)
            case 0x41...0x46: return UInt32(b - 0x41 + 10)
            default: return nil
            }
        }

        /// The input `text: String` is already valid Unicode by construction
        /// (Swift `String`s cannot hold invalid UTF-8), so once a literal byte
        /// run's leading byte is recognized, copying exactly its declared
        /// length through — never re-validating continuation bytes — always
        /// yields valid UTF-8: JSON structural/escape characters are all
        /// single-byte ASCII, so the cursor can only ever sit at a real
        /// sequence boundary.
        mutating func parseString() -> String? {
            guard peek() == UInt8(ascii: "\"") else { return nil }
            i += 1
            var out: [UInt8] = []
            while true {
                guard let c = peek() else { return nil }
                if c == UInt8(ascii: "\"") { i += 1; break }
                if c < 0x20 { return nil }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard let e = peek() else { return nil }
                    switch e {
                    case UInt8(ascii: "\""): out.append(0x22); i += 1
                    case UInt8(ascii: "\\"): out.append(0x5C); i += 1
                    case UInt8(ascii: "b"): out.append(0x08); i += 1
                    case UInt8(ascii: "f"): out.append(0x0C); i += 1
                    case UInt8(ascii: "n"): out.append(0x0A); i += 1
                    case UInt8(ascii: "r"): out.append(0x0D); i += 1
                    case UInt8(ascii: "t"): out.append(0x09); i += 1
                    case UInt8(ascii: "u"):
                        i += 1
                        guard i + 4 <= bytes.count,
                              bytes[i] == UInt8(ascii: "0"), bytes[i + 1] == UInt8(ascii: "0"),
                              let hi = Self.hexVal(bytes[i + 2]), let lo = Self.hexVal(bytes[i + 3])
                        else { return nil }
                        let value = (hi << 4) | lo
                        guard value < 0x20 else { return nil } // encode only ever emits \u00XX
                        out.append(UInt8(value))
                        i += 4
                    default:
                        return nil
                    }
                } else {
                    let len = Self.utf8SequenceLength(c)
                    guard len > 0, i + len <= bytes.count else { return nil }
                    out.append(contentsOf: bytes[i..<(i + len)])
                    i += len
                }
                if out.count > caps.value.stringBytes { return nil }
            }
            guard out.count <= caps.value.stringBytes else { return nil }
            let s = String(decoding: out, as: UTF8.self)
            guard ScriptTextHygiene.isClean(s) else { return nil }
            return s
        }

        mutating func parseList(depth: Int) -> AttrValue? {
            i += 1 // '['
            if peek() == UInt8(ascii: "]") { i += 1; return .list([]) }
            var items: [AttrValue] = []
            while true {
                guard let v = parseValue(depth: depth + 1) else { return nil }
                items.append(v)
                guard items.count <= caps.value.listElements else { return nil }
                if peek() == UInt8(ascii: ",") { i += 1; continue }
                if peek() == UInt8(ascii: "]") { i += 1; break }
                return nil
            }
            return .list(items)
        }

        mutating func parseMapOrRef(depth: Int) -> AttrValue? {
            i += 1 // '{'
            if peek() == UInt8(ascii: "}") { i += 1; return .map([:]) }
            var dict: [String: AttrValue] = [:]
            var order: [String] = []
            while true {
                guard let key = parseString() else { return nil }
                guard dict[key] == nil else { return nil } // duplicate key
                guard peek() == UInt8(ascii: ":") else { return nil }
                i += 1
                guard let value = parseValue(depth: depth + 1) else { return nil }
                dict[key] = value
                order.append(key)
                guard order.count <= max(caps.value.mapKeys, 1) else { return nil }
                if peek() == UInt8(ascii: ",") { i += 1; continue }
                if peek() == UInt8(ascii: "}") { i += 1; break }
                return nil
            }
            if order.contains(where: { $0.hasPrefix("$") }) {
                guard order == ["$ref"], case .string(let refText)? = dict["$ref"],
                      ObjectRef.parse(refText) != nil
                else { return nil }
                return .ref(refText)
            }
            guard dict.count <= caps.value.mapKeys else { return nil }
            for key in order {
                let keyBytes = key.utf8.count
                guard keyBytes >= 1, keyBytes <= caps.maxMapKeyBytes else { return nil }
            }
            return .map(dict)
        }
    }
}

/// UTF-8 byte-order comparator — Swift's default `String` `<` is Unicode-aware
/// and not guaranteed to match raw byte order for every input; every sort that
/// feeds persisted or displayed bytes uses this instead (design.md Condition 3:
/// "UTF-8-byte-order sorted keys").
func utf8Less(_ a: String, _ b: String) -> Bool {
    let ab = a.utf8
    let bb = b.utf8
    var ai = ab.startIndex
    var bi = bb.startIndex
    while ai != ab.endIndex && bi != bb.endIndex {
        if ab[ai] != bb[bi] { return ab[ai] < bb[bi] }
        ai = ab.index(after: ai)
        bi = bb.index(after: bi)
    }
    return ai == ab.endIndex && bi != bb.endIndex
}
