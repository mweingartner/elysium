import Foundation
import Darwin

enum LANIPAddressCanonicalizerV6 {
    static func canonicalIPv4(_ value: String) -> String? {
        let bytes = [UInt8](value.utf8)
        guard (1...15).contains(bytes.count) else { return nil }

        var componentCount = 0
        var componentStart = 0
        for index in 0...bytes.count where index == bytes.count || bytes[index] == 0x2e {
            guard index > componentStart else { return nil }
            let length = index - componentStart
            if length > 1, bytes[componentStart] == 0x30 { return nil }
            var number: UInt16 = 0
            for byte in bytes[componentStart..<index] {
                guard byte >= 0x30, byte <= 0x39 else { return nil }
                let digit = UInt16(byte - 0x30)
                guard number <= (255 - digit) / 10 else { return nil }
                number = number * 10 + digit
            }
            componentCount += 1
            guard componentCount <= 4 else { return nil }
            componentStart = index + 1
        }
        return componentCount == 4 ? value : nil
    }

    static func canonicalIPv6(_ value: String) -> String? {
        let bytes = value.utf8
        guard (1...253).contains(bytes.count),
              bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e
                                  && $0 != 0x25 && $0 != 0x5b && $0 != 0x5d && $0 != 0 })
        else {
            return nil
        }

        var address = in6_addr()
        let parseResult = value.withCString { pointer in
            inet_pton(AF_INET6, pointer, &address)
        }
        guard parseResult == 1 else { return nil }

        // The legacy platform canonicalizer treats bytes 2...3 as an embedded interface scope for
        // these link-local forms. Its textual result is not byte-identical (or is "?"), so preserve
        // the former equality-guard behavior without consulting interface state.
        let hasNetworkIncompatibleEmbeddedScope = withUnsafeBytes(of: address) { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= 4, bytes[2] != 0 || bytes[3] != 0 else { return false }

            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            let isMulticast = bytes[0] == 0xff
            let multicastFlags = bytes[1] & 0xf0
            let multicastScope = bytes[1] & 0x0f
            let hasNetworkScopedMulticast = isMulticast && (
                multicastScope == 1
                    || (multicastScope == 2 && multicastFlags != 0x30)
            )
            return isLinkLocal || hasNetworkScopedMulticast
        }
        guard !hasNetworkIncompatibleEmbeddedScope else { return nil }

        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let formatted = withUnsafePointer(to: &address) { addressPointer in
            output.withUnsafeMutableBufferPointer { buffer in
                inet_ntop(AF_INET6, UnsafeRawPointer(addressPointer),
                          buffer.baseAddress, socklen_t(buffer.count))
            }
        }
        guard formatted != nil else { return nil }
        return String(cString: output)
    }

    static func isLegacyIPv4Candidate(_ value: String) -> Bool {
        let bytes = [UInt8](value.utf8)
        guard (1...253).contains(bytes.count) else { return false }

        var components: [UInt64] = []
        components.reserveCapacity(4)
        var start = 0
        for index in 0...bytes.count where index == bytes.count || bytes[index] == 0x2e {
            guard index > start, components.count < 4,
                  let component = parseLegacyIPv4Component(bytes[start..<index]) else {
                return false
            }
            components.append(component)
            start = index + 1
        }

        switch components.count {
        case 1:
            return true
        case 2:
            return components[0] <= 0xff && components[1] <= 0xff_ffff
        case 3:
            return components[0] <= 0xff && components[1] <= 0xff
                && components[2] <= 0xffff
        case 4:
            return components.allSatisfy { $0 <= 0xff }
        default:
            return false
        }
    }

    private static func parseLegacyIPv4Component(_ bytes: ArraySlice<UInt8>) -> UInt64? {
        guard !bytes.isEmpty else { return nil }
        let base: UInt64
        let digits: ArraySlice<UInt8>
        if bytes.count >= 2, bytes.first == 0x30,
           (bytes[bytes.index(after: bytes.startIndex)] == 0x78
            || bytes[bytes.index(after: bytes.startIndex)] == 0x58) {
            base = 16
            digits = bytes.dropFirst(2)
        } else if bytes.count > 1, bytes.first == 0x30 {
            base = 8
            digits = bytes.dropFirst()
        } else {
            base = 10
            digits = bytes
        }
        guard !digits.isEmpty else { return nil }

        var result: UInt64 = 0
        for byte in digits {
            let digit: UInt64
            switch byte {
            case 0x30...0x39: digit = UInt64(byte - 0x30)
            case 0x41...0x46: digit = UInt64(byte - 0x41 + 10)
            case 0x61...0x66: digit = UInt64(byte - 0x61 + 10)
            default: return nil
            }
            guard digit < base else { return nil }
            result = result &* base &+ digit
        }
        return result
    }
}

public enum LANDirectInviteV6Error: Error, Equatable {
    case invalidLength
    case nonASCIIOrForbiddenCharacter
    case invalidScheme
    case invalidAuthority
    case invalidHost
    case invalidPort
    case invalidQuery
    case invalidHostInstallationID
    case invalidWorldID
    case invalidLookupDigest
    case lookupDigestMismatch
    case invalidJoinCode
}

public struct LANDirectHostV6: Hashable, CustomStringConvertible, Sendable {
    public enum Kind: Hashable, Sendable {
        case ipv4
        case ipv6
        case dns
    }

    public let kind: Kind
    public let value: String

    public init(_ canonicalHost: String) throws {
        var hostByteCount = 0
        for byte in canonicalHost.utf8 {
            hostByteCount += 1
            guard hostByteCount <= 253,
                  byte >= 0x21, byte <= 0x7e, byte != 0x25 else {
                throw LANDirectInviteV6Error.invalidHost
            }
        }
        guard hostByteCount >= 1 else { throw LANDirectInviteV6Error.invalidHost }

        if LANIPAddressCanonicalizerV6.canonicalIPv4(canonicalHost) == canonicalHost {
            kind = .ipv4
            value = canonicalHost
            return
        }

        if LANIPAddressCanonicalizerV6.isLegacyIPv4Candidate(canonicalHost) {
            throw LANDirectInviteV6Error.invalidHost
        }

        if LANIPAddressCanonicalizerV6.canonicalIPv6(canonicalHost) == canonicalHost {
            kind = .ipv6
            value = canonicalHost
            return
        }

        // A digit-and-dot input is an attempted IPv4 address, never a DNS fallback.
        if canonicalHost.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || $0 == 46 }) {
            throw LANDirectInviteV6Error.invalidHost
        }

        guard Self.isCanonicalDNSName(canonicalHost) else {
            throw LANDirectInviteV6Error.invalidHost
        }
        kind = .dns
        value = canonicalHost
    }

    public var serialized: String {
        kind == .ipv6 ? "[\(value)]" : value
    }

    public var description: String { serialized }

    private static func isCanonicalDNSName(_ value: String) -> Bool {
        let bytes = [UInt8](value.utf8)
        guard bytes.count >= 1, bytes.count <= 253 else { return false }

        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            let labelBytes = [UInt8](label.utf8)
            guard labelBytes.count >= 1,
                  labelBytes.count <= 63,
                  isLowercaseAlphaNumeric(labelBytes[0]),
                  isLowercaseAlphaNumeric(labelBytes[labelBytes.count - 1]),
                  labelBytes.allSatisfy({ isLowercaseAlphaNumeric($0) || $0 == 45 })
            else {
                return false
            }
        }
        return true
    }

    private static func isLowercaseAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 97 && byte <= 122) || (byte >= 48 && byte <= 57)
    }
}

public struct LANDirectInviteV6: Hashable, CustomStringConvertible, Sendable {
    public static let schemePrefix = "pebble-lan-v6://"
    public static let maximumASCIIByteCount = 1_024
    public static let redactedDescription = "<redacted Pebble LAN direct invite>"

    public let host: LANDirectHostV6
    public let port: UInt16
    public let hostInstallationID: LANHostInstallationIDV6
    public let worldLANID: LANWorldIDV6
    public let lookupDigest: LANV6SHA256Digest
    public let joinCode: LANV6JoinCode

    public init(
        host: LANDirectHostV6,
        port: UInt16,
        hostInstallationID: LANHostInstallationIDV6,
        worldLANID: LANWorldIDV6,
        joinCode: LANV6JoinCode
    ) throws {
        guard port >= 1 else { throw LANDirectInviteV6Error.invalidPort }
        let lookupDigest = LANV6Crypto.lookupDigest(
            hostInstallationID: hostInstallationID,
            worldLANID: worldLANID
        )
        try self.init(
            validatedHost: host,
            port: port,
            hostInstallationID: hostInstallationID,
            worldLANID: worldLANID,
            lookupDigest: lookupDigest,
            joinCode: joinCode
        )
    }

    public init(
        host: String,
        port: UInt16,
        hostInstallationID: LANHostInstallationIDV6,
        worldLANID: LANWorldIDV6,
        joinCode: LANV6JoinCode
    ) throws {
        try self.init(
            host: LANDirectHostV6(host),
            port: port,
            hostInstallationID: hostInstallationID,
            worldLANID: worldLANID,
            joinCode: joinCode
        )
    }

    public init(parsing rawValue: String) throws {
        let byteCount = rawValue.utf8.count
        guard byteCount >= 1, byteCount <= Self.maximumASCIIByteCount else {
            throw LANDirectInviteV6Error.invalidLength
        }
        guard rawValue.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e && $0 != 0x25 }) else {
            throw LANDirectInviteV6Error.nonASCIIOrForbiddenCharacter
        }
        guard rawValue.hasPrefix(Self.schemePrefix) else {
            throw LANDirectInviteV6Error.invalidScheme
        }

        let remainder = rawValue.dropFirst(Self.schemePrefix.count)
        let topLevel = remainder.split(separator: "?", omittingEmptySubsequences: false)
        guard topLevel.count == 2, !topLevel[0].isEmpty, !topLevel[1].isEmpty else {
            throw LANDirectInviteV6Error.invalidQuery
        }

        let (parsedHost, parsedPort) = try Self.parseAuthority(topLevel[0])
        let query = topLevel[1].split(separator: "&", omittingEmptySubsequences: false)
        guard query.count == 4,
              query[0].hasPrefix("hid="),
              query[1].hasPrefix("wid="),
              query[2].hasPrefix("lk="),
              query[3].hasPrefix("code=")
        else {
            throw LANDirectInviteV6Error.invalidQuery
        }

        let hidRaw = query[0].dropFirst(4)
        let widRaw = query[1].dropFirst(4)
        let lookupRaw = query[2].dropFirst(3)
        let codeRaw = query[3].dropFirst(5)
        guard !hidRaw.isEmpty, !widRaw.isEmpty, !lookupRaw.isEmpty, !codeRaw.isEmpty,
              !hidRaw.contains("="), !widRaw.contains("="),
              !lookupRaw.contains("="), !codeRaw.contains("=")
        else {
            throw LANDirectInviteV6Error.invalidQuery
        }

        let hostInstallationID: LANHostInstallationIDV6
        do {
            hostInstallationID = try LANHostInstallationIDV6(base64URL: String(hidRaw))
        } catch {
            throw LANDirectInviteV6Error.invalidHostInstallationID
        }

        let worldLANID: LANWorldIDV6
        do {
            worldLANID = try LANWorldIDV6(base64URL: String(widRaw))
        } catch {
            throw LANDirectInviteV6Error.invalidWorldID
        }

        let suppliedLookupDigest: LANV6SHA256Digest
        do {
            suppliedLookupDigest = try LANV6SHA256Digest(hex: String(lookupRaw))
        } catch {
            throw LANDirectInviteV6Error.invalidLookupDigest
        }

        let joinCode: LANV6JoinCode
        do {
            joinCode = try LANV6JoinCode(String(codeRaw))
        } catch {
            throw LANDirectInviteV6Error.invalidJoinCode
        }

        let expectedLookupDigest = LANV6Crypto.lookupDigest(
            hostInstallationID: hostInstallationID,
            worldLANID: worldLANID
        )
        guard LANV6Crypto.constantTimeEqual(expectedLookupDigest, suppliedLookupDigest) else {
            throw LANDirectInviteV6Error.lookupDigestMismatch
        }

        try self.init(
            validatedHost: parsedHost,
            port: parsedPort,
            hostInstallationID: hostInstallationID,
            worldLANID: worldLANID,
            lookupDigest: expectedLookupDigest,
            joinCode: joinCode
        )
        guard serialized == rawValue else {
            throw LANDirectInviteV6Error.invalidQuery
        }
    }

    public var serialized: String {
        Self.schemePrefix + host.serialized + ":\(port)" +
            "?hid=\(hostInstallationID.base64URL)" +
            "&wid=\(worldLANID.base64URL)" +
            "&lk=\(lookupDigest.hex)" +
            "&code=\(joinCode.serialized)"
    }

    public var description: String { Self.redactedDescription }

    private init(
        validatedHost host: LANDirectHostV6,
        port: UInt16,
        hostInstallationID: LANHostInstallationIDV6,
        worldLANID: LANWorldIDV6,
        lookupDigest: LANV6SHA256Digest,
        joinCode: LANV6JoinCode
    ) throws {
        guard port >= 1 else { throw LANDirectInviteV6Error.invalidPort }
        self.host = host
        self.port = port
        self.hostInstallationID = hostInstallationID
        self.worldLANID = worldLANID
        self.lookupDigest = lookupDigest
        self.joinCode = joinCode
        guard serialized.utf8.count <= Self.maximumASCIIByteCount else {
            throw LANDirectInviteV6Error.invalidLength
        }
    }

    private static func parseAuthority(
        _ authority: Substring
    ) throws -> (LANDirectHostV6, UInt16) {
        let hostString: String
        let portString: Substring

        if authority.first == "[" {
            guard let closingBracket = authority.firstIndex(of: "]"),
                  closingBracket > authority.startIndex
            else {
                throw LANDirectInviteV6Error.invalidAuthority
            }
            let afterBracket = authority.index(after: closingBracket)
            guard afterBracket < authority.endIndex,
                  authority[afterBracket] == ":"
            else {
                throw LANDirectInviteV6Error.invalidAuthority
            }
            let portStart = authority.index(after: afterBracket)
            hostString = String(authority[authority.index(after: authority.startIndex)..<closingBracket])
            portString = authority[portStart...]

        } else {
            let separators = authority.indices.filter { authority[$0] == ":" }
            guard separators.count == 1, let separator = separators.first else {
                throw LANDirectInviteV6Error.invalidAuthority
            }
            hostString = String(authority[..<separator])
            portString = authority[authority.index(after: separator)...]
        }

        let host: LANDirectHostV6
        do {
            host = try LANDirectHostV6(hostString)
        } catch {
            throw LANDirectInviteV6Error.invalidHost
        }
        if authority.first == "[", host.kind != .ipv6 {
            throw LANDirectInviteV6Error.invalidHost
        }

        guard let parsedPort = LANV6Decimal.parseCanonical(portString),
              parsedPort >= 1,
              parsedPort <= UInt64(UInt16.max)
        else {
            throw LANDirectInviteV6Error.invalidPort
        }
        return (host, UInt16(parsedPort))
    }
}
