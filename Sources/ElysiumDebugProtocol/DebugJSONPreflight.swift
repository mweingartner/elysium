import Foundation

/// A bounded structural pass performed before Codable sees untrusted JSON. It rejects duplicate
/// object keys (including escape-equivalent spellings), excessive nesting/member counts, large
/// strings, malformed numbers, control characters, and trailing tokens without allocating a JSON
/// object graph. Codable remains the authoritative schema decoder after this pass succeeds.
public enum DebugJSONPreflight {
    public static func validate(
        _ data: Data,
        maximumDepth: Int = 8,
        maximumObjectMembers: Int = 128,
        maximumArrayElements: Int = 65_536,
        maximumStringBytes: Int = 4_096
    ) throws {
        guard maximumDepth > 0, maximumDepth <= 64,
              maximumObjectMembers > 0, maximumObjectMembers <= 65_536,
              maximumArrayElements > 0, maximumArrayElements <= 65_536,
              maximumStringBytes > 0, maximumStringBytes <= 65_536 else {
            throw DebugProtocolError.invalidMessage("json limits")
        }
        var parser = Parser(
            bytes: [UInt8](data), maximumDepth: maximumDepth,
            maximumObjectMembers: maximumObjectMembers,
            maximumArrayElements: maximumArrayElements,
            maximumStringBytes: maximumStringBytes)
        try parser.parse()
    }
}

private struct Parser {
    let bytes: [UInt8]
    let maximumDepth: Int
    let maximumObjectMembers: Int
    let maximumArrayElements: Int
    let maximumStringBytes: Int
    var index = 0

    mutating func parse() throws {
        skipWhitespace()
        try parseValue(depth: 0)
        skipWhitespace()
        guard index == bytes.count else { throw invalid("trailing data") }
    }

    mutating func parseValue(depth: Int) throws {
        guard index < bytes.count else { throw invalid("missing value") }
        switch bytes[index] {
        case 0x7B: try parseObject(depth: depth + 1) // {
        case 0x5B: try parseArray(depth: depth + 1)  // [
        case 0x22: _ = try parseString()
        case 0x74: try takeLiteral("true")
        case 0x66: try takeLiteral("false")
        case 0x6E: try takeLiteral("null")
        case 0x2D, 0x30...0x39: try parseNumber()
        default: throw invalid("invalid value")
        }
    }

    mutating func parseObject(depth: Int) throws {
        guard depth <= maximumDepth else { throw invalid("depth") }
        index += 1
        skipWhitespace()
        if take(0x7D) { return }
        var keys = Set<String>()
        var members = 0
        while true {
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw invalid("object key")
            }
            let key = try parseString()
            guard keys.insert(key).inserted else { throw invalid("duplicate key") }
            members += 1
            guard members <= maximumObjectMembers else { throw invalid("object members") }
            skipWhitespace()
            guard take(0x3A) else { throw invalid("missing colon") }
            skipWhitespace()
            try parseValue(depth: depth)
            skipWhitespace()
            if take(0x7D) { return }
            guard take(0x2C) else { throw invalid("object separator") }
            skipWhitespace()
        }
    }

    mutating func parseArray(depth: Int) throws {
        guard depth <= maximumDepth else { throw invalid("depth") }
        index += 1
        skipWhitespace()
        if take(0x5D) { return }
        var count = 0
        while true {
            count += 1
            guard count <= maximumArrayElements else { throw invalid("array elements") }
            try parseValue(depth: depth)
            skipWhitespace()
            if take(0x5D) { return }
            guard take(0x2C) else { throw invalid("array separator") }
            skipWhitespace()
        }
    }

    mutating func parseString() throws -> String {
        let start = index
        guard take(0x22) else { throw invalid("string") }
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if escaped {
                switch byte {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    break
                case 0x75:
                    guard index <= bytes.count - 4,
                          bytes[index..<(index + 4)].allSatisfy(isHex) else {
                        throw invalid("unicode escape")
                    }
                    index += 4
                default: throw invalid("escape")
                }
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let raw = Data(bytes[start..<index])
                let decoded: String
                do { decoded = try JSONDecoder().decode(String.self, from: raw) }
                catch { throw invalid("string encoding") }
                guard decoded.utf8.count <= maximumStringBytes else {
                    throw invalid("string bytes")
                }
                return decoded
            } else if byte < 0x20 {
                throw invalid("string control")
            }
        }
        throw invalid("unterminated string")
    }

    mutating func parseNumber() throws {
        if take(0x2D), index == bytes.count { throw invalid("number") }
        guard index < bytes.count else { throw invalid("number") }
        if take(0x30) {
            if index < bytes.count, isDigit(bytes[index]) { throw invalid("leading zero") }
        } else {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                throw invalid("number")
            }
            index += 1
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if take(0x2E) {
            guard index < bytes.count, isDigit(bytes[index]) else { throw invalid("fraction") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count && (bytes[index] == 0x65 || bytes[index] == 0x45) {
            index += 1
            if index < bytes.count && (bytes[index] == 0x2B || bytes[index] == 0x2D) {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else { throw invalid("exponent") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
    }

    mutating func takeLiteral(_ value: StaticString) throws {
        let expected = Array(String(describing: value).utf8)
        guard index <= bytes.count - expected.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw invalid("literal")
        }
        index += expected.count
    }

    mutating func skipWhitespace() {
        while index < bytes.count && (bytes[index] == 0x20 || bytes[index] == 0x09
                || bytes[index] == 0x0A || bytes[index] == 0x0D) {
            index += 1
        }
    }

    mutating func take(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    func invalid(_ reason: String) -> DebugProtocolError {
        .invalidMessage("json \(reason)")
    }

    private func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
    private func isHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte)
            || (0x61...0x66).contains(byte)
    }
}
