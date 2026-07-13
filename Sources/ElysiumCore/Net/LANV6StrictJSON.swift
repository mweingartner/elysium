import Foundation

public struct LANV6StrictJSONLimits: Equatable {
    public let maximumBytes: Int
    public let maximumDepth: Int
    public let maximumMembers: Int
    public let maximumStringBytes: Int

    public init(maximumBytes: Int, maximumDepth: Int,
                maximumMembers: Int, maximumStringBytes: Int) {
        self.maximumBytes = maximumBytes
        self.maximumDepth = maximumDepth
        self.maximumMembers = maximumMembers
        self.maximumStringBytes = maximumStringBytes
    }
}

public struct LANV6StrictJSONKey: Hashable {
    /// Exact decoded UTF-8 bytes. Key identity deliberately does not use Swift
    /// `String` equality, which canonically equates some distinct scalar sequences.
    public let utf8: Data

    public var string: String { String(decoding: utf8, as: UTF8.self) }
}

public enum LANV6StrictJSONTopLevelKind: Equatable {
    case object
    case array
    case string
    case number
    case boolean
    case null
}

public enum LANV6StrictJSONPathComponent: Hashable {
    case key(LANV6StrictJSONKey)
    case index(Int)
}

public struct LANV6StrictJSONObjectMetadata: Equatable {
    public let path: [LANV6StrictJSONPathComponent]
    public fileprivate(set) var keys: [LANV6StrictJSONKey]

    public var keyStrings: [String] { keys.map(\.string) }
}

public struct LANV6StrictJSONNumberMetadata: Equatable {
    public let path: [LANV6StrictJSONPathComponent]
    /// Exact UTF-8 number token as received on the wire.
    public let rawValue: Data

    public var string: String { String(decoding: rawValue, as: UTF8.self) }

    public var isCanonicalUnsignedInteger: Bool {
        let bytes = [UInt8](rawValue)
        guard !bytes.isEmpty,
              bytes.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
              !(bytes.count > 1 && bytes[0] == 0x30)
        else { return false }
        return true
    }
}

public enum LANV6StrictJSONHelloAdmissionShape: Equatable {
    case joinNew
    case resume
    case legacyClaim
    case legacyConsume
}

public enum LANV6StrictJSONError: Error, Equatable {
    case invalidLimits
    case byteLimitExceeded(actual: Int, maximum: Int)
    case invalidUTF8
    case unexpectedEnd
    case unexpectedToken(offset: Int)
    case trailingBytes(offset: Int)
    case invalidStringEscape(offset: Int)
    case invalidUnicodeScalar(offset: Int)
    case stringLimitExceeded(maximum: Int)
    case depthLimitExceeded(maximum: Int)
    case memberLimitExceeded(maximum: Int)
    case duplicateObjectKey(LANV6StrictJSONKey)
    case nonFiniteNumber(offset: Int)
    case topLevelNotObject
    case topLevelKeySetMismatch(missing: [String], extra: [String])
    case objectNotFound(keyPath: [String])
    case objectKeySetMismatch(keyPath: [String], missing: [String], extra: [String])
    case invalidHelloAdmissionKeySet(actual: [String])
    case numberNotFound(keyPath: [String])
    case nonCanonicalUnsignedInteger(keyPath: [String], actual: String)
}

public struct LANV6StrictJSONScan: Equatable {
    public let byteCount: Int
    public let totalMemberCount: Int
    public let maximumObservedDepth: Int
    public let topLevelKind: LANV6StrictJSONTopLevelKind
    /// Ordered, duplicate-free metadata captured before any permissive decoder.
    public let topLevelObjectKeys: [LANV6StrictJSONKey]
    /// Every object in document-preorder with its exact decoded key/index path.
    public let objects: [LANV6StrictJSONObjectMetadata]
    /// Every numeric token with its exact path and original lexical form.
    public let numbers: [LANV6StrictJSONNumberMetadata]

    public var topLevelObjectKeyStrings: [String] {
        topLevelObjectKeys.map(\.string)
    }

    public func requireTopLevelObject(exactKeys: Set<String>) throws {
        guard topLevelKind == .object else {
            throw LANV6StrictJSONError.topLevelNotObject
        }
        let expected = Set(exactKeys.map { Data($0.utf8) })
        let actual = Set(topLevelObjectKeys.map(\.utf8))
        guard actual == expected else {
            let missing = expected.subtracting(actual)
                .map { String(decoding: $0, as: UTF8.self) }.sorted()
            let extra = actual.subtracting(expected)
                .map { String(decoding: $0, as: UTF8.self) }.sorted()
            throw LANV6StrictJSONError.topLevelKeySetMismatch(
                missing: missing, extra: extra
            )
        }
    }

    public func object(at path: [LANV6StrictJSONPathComponent]) -> LANV6StrictJSONObjectMetadata? {
        objects.first { $0.path == path }
    }

    public func object(atKeyPath keyPath: [String]) -> LANV6StrictJSONObjectMetadata? {
        let path = keyPath.map {
            LANV6StrictJSONPathComponent.key(LANV6StrictJSONKey(utf8: Data($0.utf8)))
        }
        return object(at: path)
    }

    public func requireObject(atKeyPath keyPath: [String], exactKeys: Set<String>) throws {
        guard let object = object(atKeyPath: keyPath) else {
            throw LANV6StrictJSONError.objectNotFound(keyPath: keyPath)
        }
        let expected = Set(exactKeys.map { Data($0.utf8) })
        let actual = Set(object.keys.map(\.utf8))
        guard actual == expected else {
            let missing = expected.subtracting(actual)
                .map { String(decoding: $0, as: UTF8.self) }.sorted()
            let extra = actual.subtracting(expected)
                .map { String(decoding: $0, as: UTF8.self) }.sorted()
            throw LANV6StrictJSONError.objectKeySetMismatch(
                keyPath: keyPath, missing: missing, extra: extra
            )
        }
    }

    public func requireVersionedCounterObject(atKeyPath keyPath: [String]) throws {
        try requireObject(atKeyPath: keyPath, exactKeys: ["generation", "value"])
        try requireCanonicalUnsignedInteger(atKeyPath: keyPath + ["generation"])
        try requireCanonicalUnsignedInteger(atKeyPath: keyPath + ["value"])
    }

    public func number(atKeyPath keyPath: [String]) -> LANV6StrictJSONNumberMetadata? {
        let path = keyPath.map {
            LANV6StrictJSONPathComponent.key(LANV6StrictJSONKey(utf8: Data($0.utf8)))
        }
        return numbers.first { $0.path == path }
    }

    public func requireCanonicalUnsignedInteger(atKeyPath keyPath: [String]) throws {
        guard let number = number(atKeyPath: keyPath) else {
            throw LANV6StrictJSONError.numberNotFound(keyPath: keyPath)
        }
        guard number.isCanonicalUnsignedInteger else {
            throw LANV6StrictJSONError.nonCanonicalUnsignedInteger(
                keyPath: keyPath, actual: number.string
            )
        }
    }

    public func requireCanonicalUnsignedIntegerIfPresent(atKeyPath keyPath: [String]) throws {
        guard let number = number(atKeyPath: keyPath) else { return }
        guard number.isCanonicalUnsignedInteger else {
            throw LANV6StrictJSONError.nonCanonicalUnsignedInteger(
                keyPath: keyPath, actual: number.string
            )
        }
    }

    /// Validates both closed object layers before a typed hello decoder runs.
    /// The admission key set uniquely identifies its structural variant; the
    /// typed decoder subsequently verifies the corresponding `kind` scalar.
    public func requireClosedHelloObjectShape() throws -> LANV6StrictJSONHelloAdmissionShape {
        try requireTopLevelObject(exactKeys: ["pv", "hid", "wid", "lk", "playerName", "admission"])
        guard let admission = object(atKeyPath: ["admission"]) else {
            throw LANV6StrictJSONError.objectNotFound(keyPath: ["admission"])
        }
        let actual = Set(admission.keys.map(\.utf8))
        let variants: [(LANV6StrictJSONHelloAdmissionShape, Set<Data>)] = [
            (.joinNew, Set(["kind", "joinCode"].map { Data($0.utf8) })),
            (.resume, Set(["kind", "rawToken"].map { Data($0.utf8) })),
            (.legacyClaim, Set(["kind", "joinCode", "legacyHint", "rawClaimNonce"].map { Data($0.utf8) })),
            (.legacyConsume, Set(["kind", "rawClaimNonce"].map { Data($0.utf8) })),
        ]
        if let match = variants.first(where: { $0.1 == actual }) { return match.0 }
        throw LANV6StrictJSONError.invalidHelloAdmissionKeySet(
            actual: admission.keyStrings.sorted()
        )
    }
}

public enum LANV6StrictJSON {
    public static func scan(_ data: Data, limits: LANV6StrictJSONLimits) throws -> LANV6StrictJSONScan {
        var scanner = try Scanner(data: data, limits: limits)
        return try scanner.run()
    }

    private struct Scanner {
        enum FrameState {
            case objectKeyOrEnd
            case objectKey
            case objectColon
            case objectValue
            case objectCommaOrEnd
            case arrayValueOrEnd
            case arrayValue
            case arrayCommaOrEnd
        }

        struct Frame {
            var state: FrameState
            var keys = Set<Data>()
            var path: [LANV6StrictJSONPathComponent]
            var objectMetadataIndex: Int?
            var pendingObjectKey: LANV6StrictJSONKey?
            var nextArrayIndex = 0
        }

        let bytes: [UInt8]
        let limits: LANV6StrictJSONLimits
        var index = 0
        var stack: [Frame] = []
        var rootStarted = false
        var rootFinished = false
        var rootKind: LANV6StrictJSONTopLevelKind?
        var objects: [LANV6StrictJSONObjectMetadata] = []
        var numbers: [LANV6StrictJSONNumberMetadata] = []
        var totalMembers = 0
        var observedDepth = 0

        init(data: Data, limits: LANV6StrictJSONLimits) throws {
            guard limits.maximumBytes >= 0, limits.maximumDepth >= 0,
                  limits.maximumMembers >= 0, limits.maximumStringBytes >= 0 else {
                throw LANV6StrictJSONError.invalidLimits
            }
            guard data.count <= limits.maximumBytes else {
                throw LANV6StrictJSONError.byteLimitExceeded(
                    actual: data.count, maximum: limits.maximumBytes
                )
            }
            guard String(data: data, encoding: .utf8) != nil else {
                throw LANV6StrictJSONError.invalidUTF8
            }
            self.bytes = Array(data)
            self.limits = limits
        }

        mutating func run() throws -> LANV6StrictJSONScan {
            while true {
                skipWhitespace()
                if stack.isEmpty {
                    if !rootStarted {
                        guard index < bytes.count else { throw LANV6StrictJSONError.unexpectedEnd }
                        rootStarted = true
                        try parseValue(isRoot: true, path: [])
                        if stack.isEmpty { rootFinished = true }
                        continue
                    }
                    if rootFinished {
                        guard index == bytes.count else {
                            throw LANV6StrictJSONError.trailingBytes(offset: index)
                        }
                        guard let rootKind else { throw LANV6StrictJSONError.unexpectedEnd }
                        return LANV6StrictJSONScan(
                            byteCount: bytes.count,
                            totalMemberCount: totalMembers,
                            maximumObservedDepth: observedDepth,
                            topLevelKind: rootKind,
                            topLevelObjectKeys: objects.first(where: { $0.path.isEmpty })?.keys ?? [],
                            objects: objects,
                            numbers: numbers
                        )
                    }
                }

                guard !stack.isEmpty else { continue }
                let top = stack.count - 1
                switch stack[top].state {
                case .objectKeyOrEnd:
                    if consume(0x7D) { try closeContainer(); continue } // }
                    try parseObjectKey(at: top)
                case .objectKey:
                    try parseObjectKey(at: top)
                case .objectColon:
                    guard consume(0x3A) else { try failToken() } // :
                    stack[top].state = .objectValue
                case .objectValue:
                    guard let key = stack[top].pendingObjectKey else { try failToken() }
                    let childPath = stack[top].path + [.key(key)]
                    stack[top].pendingObjectKey = nil
                    stack[top].state = .objectCommaOrEnd
                    try parseValue(isRoot: false, path: childPath)
                case .objectCommaOrEnd:
                    if consume(0x2C) { stack[top].state = .objectKey; continue } // ,
                    if consume(0x7D) { try closeContainer(); continue }
                    try failToken()
                case .arrayValueOrEnd:
                    if consume(0x5D) { try closeContainer(); continue } // ]
                    try addMember()
                    let childPath = stack[top].path + [.index(stack[top].nextArrayIndex)]
                    stack[top].nextArrayIndex += 1
                    stack[top].state = .arrayCommaOrEnd
                    try parseValue(isRoot: false, path: childPath)
                case .arrayValue:
                    try addMember()
                    let childPath = stack[top].path + [.index(stack[top].nextArrayIndex)]
                    stack[top].nextArrayIndex += 1
                    stack[top].state = .arrayCommaOrEnd
                    try parseValue(isRoot: false, path: childPath)
                case .arrayCommaOrEnd:
                    if consume(0x2C) { stack[top].state = .arrayValue; continue }
                    if consume(0x5D) { try closeContainer(); continue }
                    try failToken()
                }
            }
        }

        mutating func parseObjectKey(at frameIndex: Int) throws {
            guard peek() == 0x22 else { try failToken() }
            let key = try parseString(capture: true)
            try addMember()
            guard stack[frameIndex].keys.insert(key).inserted else {
                throw LANV6StrictJSONError.duplicateObjectKey(LANV6StrictJSONKey(utf8: key))
            }
            let strictKey = LANV6StrictJSONKey(utf8: key)
            stack[frameIndex].pendingObjectKey = strictKey
            if let metadataIndex = stack[frameIndex].objectMetadataIndex {
                objects[metadataIndex].keys.append(strictKey)
            }
            stack[frameIndex].state = .objectColon
        }

        mutating func parseValue(isRoot: Bool,
                                 path: [LANV6StrictJSONPathComponent]) throws {
            guard let byte = peek() else { throw LANV6StrictJSONError.unexpectedEnd }
            let kind: LANV6StrictJSONTopLevelKind
            switch byte {
            case 0x7B: // {
                index += 1
                kind = .object
                try push(.objectKeyOrEnd, path: path, isObject: true)
            case 0x5B: // [
                index += 1
                kind = .array
                try push(.arrayValueOrEnd, path: path, isObject: false)
            case 0x22:
                _ = try parseString(capture: false)
                kind = .string
            case 0x74: // true
                try consumeLiteral([0x74, 0x72, 0x75, 0x65])
                kind = .boolean
            case 0x66: // false
                try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
                kind = .boolean
            case 0x6E: // null
                try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
                kind = .null
            case 0x2D, 0x30...0x39:
                let rawValue = try parseNumber()
                numbers.append(LANV6StrictJSONNumberMetadata(
                    path: path, rawValue: rawValue
                ))
                kind = .number
            default:
                try failToken()
            }
            if isRoot { rootKind = kind }
        }

        mutating func push(_ state: FrameState,
                           path: [LANV6StrictJSONPathComponent],
                           isObject: Bool) throws {
            let depth = stack.count + 1
            guard depth <= limits.maximumDepth else {
                throw LANV6StrictJSONError.depthLimitExceeded(maximum: limits.maximumDepth)
            }
            observedDepth = max(observedDepth, depth)
            let metadataIndex: Int?
            if isObject {
                metadataIndex = objects.count
                objects.append(LANV6StrictJSONObjectMetadata(path: path, keys: []))
            } else {
                metadataIndex = nil
            }
            stack.append(Frame(state: state, path: path,
                               objectMetadataIndex: metadataIndex))
        }

        mutating func closeContainer() throws {
            stack.removeLast()
            if stack.isEmpty { rootFinished = true }
        }

        mutating func addMember() throws {
            guard totalMembers < limits.maximumMembers else {
                throw LANV6StrictJSONError.memberLimitExceeded(maximum: limits.maximumMembers)
            }
            totalMembers += 1
        }

        mutating func parseString(capture: Bool) throws -> Data {
            guard consume(0x22) else { try failToken() }
            var decoded: [UInt8] = []
            if capture { decoded.reserveCapacity(min(32, limits.maximumStringBytes)) }
            var decodedCount = 0

            func utf8Length(_ scalar: UInt32) -> Int {
                scalar <= 0x7F ? 1 : scalar <= 0x7FF ? 2 : scalar <= 0xFFFF ? 3 : 4
            }

            func appendScalar(_ scalar: UInt32) throws {
                let count = utf8Length(scalar)
                guard decodedCount <= limits.maximumStringBytes - count else {
                    throw LANV6StrictJSONError.stringLimitExceeded(maximum: limits.maximumStringBytes)
                }
                decodedCount += count
                guard capture else { return }
                if scalar <= 0x7F {
                    decoded.append(UInt8(scalar))
                } else if scalar <= 0x7FF {
                    decoded.append(0xC0 | UInt8(scalar >> 6))
                    decoded.append(0x80 | UInt8(scalar & 0x3F))
                } else if scalar <= 0xFFFF {
                    decoded.append(0xE0 | UInt8(scalar >> 12))
                    decoded.append(0x80 | UInt8((scalar >> 6) & 0x3F))
                    decoded.append(0x80 | UInt8(scalar & 0x3F))
                } else {
                    decoded.append(0xF0 | UInt8(scalar >> 18))
                    decoded.append(0x80 | UInt8((scalar >> 12) & 0x3F))
                    decoded.append(0x80 | UInt8((scalar >> 6) & 0x3F))
                    decoded.append(0x80 | UInt8(scalar & 0x3F))
                }
            }

            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    return Data(decoded)
                }
                if byte < 0x20 {
                    throw LANV6StrictJSONError.unexpectedToken(offset: index)
                }
                if byte == 0x5C { // \
                    let escapeOffset = index
                    index += 1
                    guard index < bytes.count else { throw LANV6StrictJSONError.unexpectedEnd }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case 0x22, 0x5C, 0x2F: try appendScalar(UInt32(escape))
                    case 0x62: try appendScalar(0x08)
                    case 0x66: try appendScalar(0x0C)
                    case 0x6E: try appendScalar(0x0A)
                    case 0x72: try appendScalar(0x0D)
                    case 0x74: try appendScalar(0x09)
                    case 0x75:
                        let first = try parseHexQuad(escapeOffset: escapeOffset)
                        if (0xD800...0xDBFF).contains(first) {
                            guard index + 6 <= bytes.count,
                                  bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                                throw LANV6StrictJSONError.invalidUnicodeScalar(offset: escapeOffset)
                            }
                            index += 2
                            let second = try parseHexQuad(escapeOffset: escapeOffset)
                            guard (0xDC00...0xDFFF).contains(second) else {
                                throw LANV6StrictJSONError.invalidUnicodeScalar(offset: escapeOffset)
                            }
                            let scalar = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                            try appendScalar(scalar)
                        } else if (0xDC00...0xDFFF).contains(first) {
                            throw LANV6StrictJSONError.invalidUnicodeScalar(offset: escapeOffset)
                        } else {
                            try appendScalar(first)
                        }
                    default:
                        throw LANV6StrictJSONError.invalidStringEscape(offset: escapeOffset)
                    }
                    continue
                }

                if byte < 0x80 {
                    index += 1
                    try appendScalar(UInt32(byte))
                    continue
                }
                let length: Int
                if byte & 0xE0 == 0xC0 { length = 2 }
                else if byte & 0xF0 == 0xE0 { length = 3 }
                else if byte & 0xF8 == 0xF0 { length = 4 }
                else { throw LANV6StrictJSONError.invalidUTF8 }
                guard index + length <= bytes.count else { throw LANV6StrictJSONError.invalidUTF8 }
                guard decodedCount <= limits.maximumStringBytes - length else {
                    throw LANV6StrictJSONError.stringLimitExceeded(maximum: limits.maximumStringBytes)
                }
                decodedCount += length
                if capture { decoded.append(contentsOf: bytes[index..<(index + length)]) }
                index += length
            }
            throw LANV6StrictJSONError.unexpectedEnd
        }

        mutating func parseHexQuad(escapeOffset: Int) throws -> UInt32 {
            guard index + 4 <= bytes.count else { throw LANV6StrictJSONError.unexpectedEnd }
            var value: UInt32 = 0
            for _ in 0..<4 {
                let byte = bytes[index]
                index += 1
                let digit: UInt32
                switch byte {
                case 0x30...0x39: digit = UInt32(byte - 0x30)
                case 0x41...0x46: digit = UInt32(byte - 0x41 + 10)
                case 0x61...0x66: digit = UInt32(byte - 0x61 + 10)
                default:
                    throw LANV6StrictJSONError.invalidStringEscape(offset: escapeOffset)
                }
                value = value * 16 + digit
            }
            return value
        }

        mutating func parseNumber() throws -> Data {
            let start = index
            if consume(0x2D), index == bytes.count { throw LANV6StrictJSONError.unexpectedEnd }
            guard let first = peek() else { throw LANV6StrictJSONError.unexpectedEnd }
            if first == 0x30 {
                index += 1
                if let next = peek(), (0x30...0x39).contains(next) { try failToken() }
            } else if (0x31...0x39).contains(first) {
                index += 1
                while let next = peek(), (0x30...0x39).contains(next) { index += 1 }
            } else {
                try failToken()
            }
            if consume(0x2E) {
                guard let next = peek(), (0x30...0x39).contains(next) else { try failToken() }
                repeat { index += 1 } while peek().map { (0x30...0x39).contains($0) } == true
            }
            if let next = peek(), next == 0x65 || next == 0x45 {
                index += 1
                if let sign = peek(), sign == 0x2B || sign == 0x2D { index += 1 }
                guard let digit = peek(), (0x30...0x39).contains(digit) else { try failToken() }
                repeat { index += 1 } while peek().map { (0x30...0x39).contains($0) } == true
            }
            let raw = String(decoding: bytes[start..<index], as: UTF8.self)
            guard let number = Double(raw), number.isFinite else {
                throw LANV6StrictJSONError.nonFiniteNumber(offset: start)
            }
            return Data(bytes[start..<index])
        }

        mutating func consumeLiteral(_ literal: [UInt8]) throws {
            guard index + literal.count <= bytes.count else { throw LANV6StrictJSONError.unexpectedEnd }
            guard Array(bytes[index..<(index + literal.count)]) == literal else { try failToken() }
            index += literal.count
        }

        mutating func skipWhitespace() {
            while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            }
        }

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard peek() == byte else { return false }
            index += 1
            return true
        }

        func failToken() throws -> Never {
            guard index < bytes.count else { throw LANV6StrictJSONError.unexpectedEnd }
            throw LANV6StrictJSONError.unexpectedToken(offset: index)
        }
    }
}
