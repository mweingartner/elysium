import Darwin
import Foundation
import Network
import XCTest
@testable import PebbleCore

final class LANDirectInviteV6Tests: XCTestCase {
    private enum ReferenceHost: Equatable {
        case accepted(kind: LANDirectHostV6.Kind, value: String)
        case rejected
    }

    private let hostIDText = "AAECAwQFBgcICQoLDA0ODw"
    private let worldIDText = "EBESExQVFhcYGRobHB0eHw"
    private let lookupText =
        "6f14474ef5682ddd836db5d3923f65e48e2725f4dfedd5086d67b25d6b071bcf"

    private var query: String {
        "hid=\(hostIDText)&wid=\(worldIDText)&lk=\(lookupText)&code=ABC123"
    }

    private func raw(host: String = "192.168.1.20", port: String = "41337",
                     query: String? = nil) -> String {
        "pebble-lan-v6://\(host):\(port)?\(query ?? self.query)"
    }

    private func makeInvite(host: String = "192.168.1.20", port: UInt16 = 41_337) throws
        -> LANDirectInviteV6 {
        try LANDirectInviteV6(
            host: host,
            port: port,
            hostInstallationID: LANHostInstallationIDV6(base64URL: hostIDText),
            worldLANID: LANWorldIDV6(base64URL: worldIDText),
            joinCode: LANV6JoinCode("ABC123")
        )
    }

    private func referenceHost(_ candidate: String) -> ReferenceHost {
        let bytes = [UInt8](candidate.utf8)
        guard (1...253).contains(bytes.count),
              bytes.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e && $0 != 0x25 }) else {
            return .rejected
        }
        if let address = IPv4Address(candidate) {
            return String(describing: address) == candidate
                ? .accepted(kind: .ipv4, value: candidate) : .rejected
        }
        if let address = IPv6Address(candidate) {
            return String(describing: address) == candidate
                ? .accepted(kind: .ipv6, value: candidate) : .rejected
        }
        if bytes.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2e }) {
            return .rejected
        }
        return referenceDNS(candidate)
            ? .accepted(kind: .dns, value: candidate) : .rejected
    }

    private func referenceDNS(_ value: String) -> Bool {
        let bytes = [UInt8](value.utf8)
        guard (1...253).contains(bytes.count) else { return false }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            let labelBytes = [UInt8](label.utf8)
            guard (1...63).contains(labelBytes.count),
                  referenceDNSAlphaNumeric(labelBytes[0]),
                  referenceDNSAlphaNumeric(labelBytes[labelBytes.count - 1]),
                  labelBytes.allSatisfy({ referenceDNSAlphaNumeric($0) || $0 == 0x2d }) else {
                return false
            }
        }
        return true
    }

    private func referenceDNSAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x61 && byte <= 0x7a) || (byte >= 0x30 && byte <= 0x39)
    }

    private func actualHost(_ candidate: String) -> ReferenceHost {
        guard let host = try? LANDirectHostV6(candidate) else { return .rejected }
        return .accepted(kind: host.kind, value: host.value)
    }

    private func escapedBytes(_ value: String) -> String {
        value.utf8.map { String(format: "%02x", $0) }.joined()
    }

    private func escapedRawBytes(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func referenceCanonicalIPv6(_ candidate: String) -> String? {
        guard let address = IPv6Address(candidate) else { return nil }
        let description = String(describing: address)
        guard description != "?", !description.contains("%") else { return nil }
        return description
    }

    private func posixIPv6Text(_ bytes: [UInt8]) -> String? {
        guard bytes.count == MemoryLayout<in6_addr>.size else { return nil }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { destination in
            destination.copyBytes(from: bytes)
        }
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

    private func referenceHasNetworkIncompatibleEmbeddedScope(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16, bytes[2] != 0 || bytes[3] != 0 else { return false }
        let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let isMulticast = bytes[0] == 0xff
        let multicastFlags = bytes[1] & 0xf0
        let multicastScope = bytes[1] & 0x0f
        return isLinkLocal || (isMulticast && (
            multicastScope == 1 || (multicastScope == 2 && multicastFlags != 0x30)
        ))
    }

    private func redundantLeadingZeroIPv6(_ canonical: String) -> String? {
        var groups = canonical.split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
        for index in groups.indices where !groups[index].isEmpty
            && !groups[index].contains(".") && groups[index].utf8.count < 4 {
            groups[index] = "0" + groups[index]
            return groups.joined(separator: ":")
        }
        return nil
    }

    private func nonminimalIPv6Expansion(_ canonical: String) -> String? {
        guard let compressedRange = canonical.range(of: "::") else { return nil }
        let left = canonical[..<compressedRange.lowerBound]
            .split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        let right = canonical[compressedRange.upperBound...]
            .split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        let explicitGroupCount = (left + right).reduce(0) { count, group in
            count + (group.contains(".") ? 2 : 1)
        }
        guard explicitGroupCount < 8 else { return nil }
        let zeros = Array(repeating: "0", count: 8 - explicitGroupCount)
        return (left + zeros + right).joined(separator: ":")
    }

    private func assertIPv6MutationRejected(
        _ candidate: String,
        canonical: String,
        index: Int,
        mutation: String
    ) {
        guard candidate != canonical else { return }
        let evidence = "index=\(index) mutation=\(mutation) candidateHex=\(escapedBytes(candidate))"
        guard let oracle = IPv6Address(candidate) else {
            XCTFail("Network rejected same-address mutation: \(evidence)")
            return
        }
        XCTAssertEqual(String(describing: oracle), canonical, evidence)
        XCTAssertEqual(LANIPAddressCanonicalizerV6.canonicalIPv6(candidate), canonical, evidence)
        XCTAssertThrowsError(try LANDirectHostV6(candidate), evidence) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidHost, evidence)
        }
    }

    func testIPv4SerializationIsExactAndRoundTrips() throws {
        let invite = try makeInvite()
        let expected = raw()
        XCTAssertEqual(invite.serialized, expected)
        XCTAssertEqual(invite.description, LANDirectInviteV6.redactedDescription)
        XCTAssertFalse(invite.description.contains("ABC123"))
        XCTAssertFalse(invite.description.contains(hostIDText))

        let parsed = try LANDirectInviteV6(parsing: expected)
        XCTAssertEqual(parsed, invite)
        XCTAssertEqual(parsed.host, try LANDirectHostV6("192.168.1.20"))
        XCTAssertEqual(parsed.host.kind, .ipv4)
        XCTAssertEqual(parsed.lookupDigest.hex, lookupText)
    }

    func testCanonicalDNSAndBracketedIPv6RoundTrip() throws {
        let dns = try makeInvite(host: "host-2.lan")
        XCTAssertEqual(dns.host, try LANDirectHostV6("host-2.lan"))
        XCTAssertEqual(dns.host.kind, .dns)
        XCTAssertEqual(try LANDirectInviteV6(parsing: dns.serialized), dns)

        let ipv6 = try makeInvite(host: "2001:db8::1")
        XCTAssertEqual(ipv6.host, try LANDirectHostV6("2001:db8::1"))
        XCTAssertEqual(ipv6.host.kind, .ipv6)
        XCTAssertTrue(ipv6.serialized.hasPrefix("pebble-lan-v6://[2001:db8::1]:41337?"))
        XCTAssertEqual(try LANDirectInviteV6(parsing: ipv6.serialized), ipv6)

        let loopback = try makeInvite(host: "::1")
        XCTAssertEqual(try LANDirectInviteV6(parsing: loopback.serialized), loopback)
    }

    func testIPv4MustBeCanonicalDottedDecimal() {
        for invalid in ["127.00.0.1", "127.0.0.01", "256.0.0.1", "1.2.3", "1.2.3.4.",
                        ".1.2.3.4", "01.2.3.4", "1.2.3.-1"] {
            XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(host: invalid)),
                                 "unexpectedly accepted \(invalid)")
        }
    }

    func testIPv4CanonicalBoundariesAndLegacyOracleParity() throws {
        let accepted = [
            "0.0.0.0", "0.0.0.1", "127.0.0.1", "192.168.1.20", "255.255.255.255",
        ]
        for candidate in accepted {
            XCTAssertEqual(LANIPAddressCanonicalizerV6.canonicalIPv4(candidate), candidate)
            XCTAssertEqual(try LANDirectHostV6(candidate).kind, .ipv4)
            XCTAssertEqual(actualHost(candidate), referenceHost(candidate))
        }

        let rejected = [
            "", ".1.2.3", "1..2.3", "1.2.3.", "1.2.3", "1.2.3.4.5",
            "256.0.0.1", "1.2.3.256", "+1.2.3.4", "-1.2.3.4", "1.2.3.-1",
            " 1.2.3.4", "1.2.3.4 ", "00.0.0.0", "127.00.0.1", "127.0.0.01",
            "127.1", "2130706433", "0x7f000001", "0xffffffff", "0177.0.0.1",
            "0300.0250.0001.0024", "0x10000000000000000.1",
        ]
        for candidate in rejected {
            XCTAssertNil(LANIPAddressCanonicalizerV6.canonicalIPv4(candidate),
                         "unexpected strict IPv4: \(escapedBytes(candidate))")
            XCTAssertEqual(actualHost(candidate), .rejected,
                           "unexpected host: \(escapedBytes(candidate))")
            XCTAssertEqual(actualHost(candidate), referenceHost(candidate),
                           "Network parity mismatch: \(escapedBytes(candidate))")
        }

        let legacy = [
            "0", "00", "127.1", "1.2.3", "2130706433", "4294967296",
            "0x7f000001", "0xffffffff", "0177.0.0.1", "0300.0250.0001.0024",
            "0x10000000000000000.1",
        ]
        for candidate in legacy {
            XCTAssertNotNil(IPv4Address(candidate), "oracle changed for \(candidate)")
            XCTAssertTrue(LANIPAddressCanonicalizerV6.isLegacyIPv4Candidate(candidate),
                          "missed legacy candidate \(escapedBytes(candidate))")
            XCTAssertThrowsError(try LANDirectHostV6(candidate)) { error in
                XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidHost)
            }
        }
        for dns in ["deadbeef", "0xg", "host-2.lan"] {
            XCTAssertNil(IPv4Address(dns))
            XCTAssertFalse(LANIPAddressCanonicalizerV6.isLegacyIPv4Candidate(dns))
            XCTAssertEqual(try LANDirectHostV6(dns).kind, .dns)
        }
    }

    func testIPv6MustBeBracketedAndNetworkCanonical() {
        let invalidHosts = [
            "[0:0:0:0:0:0:0:1]",
            "[2001:0DB8::1]",
            "[2001:db8::01]",
            "[::1%lo0]",
            "[]",
            "[::1",
            "::1",
        ]
        for invalid in invalidHosts {
            XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(host: invalid)),
                                 "unexpectedly accepted \(invalid)")
        }
    }

    func testIPv6CanonicalBoundariesAndNoncanonicalForms() throws {
        let accepted = [
            "::", "::1", "1::", "2001:db8::1",
            "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
            "2001::1:0:0:1:1", "::ffff:192.0.2.128", "64:ff9b::c000:221",
            "fe80::1", "ff00::", "ff01::1", "ff02::1", "ff0e::1",
            "ff22::1234", "ff32:1::1",
        ]
        for candidate in accepted {
            let oracle = try XCTUnwrap(IPv6Address(candidate))
            XCTAssertEqual(String(describing: oracle), candidate)
            XCTAssertEqual(LANIPAddressCanonicalizerV6.canonicalIPv6(candidate), candidate)
            XCTAssertEqual(try LANDirectHostV6(candidate).kind, .ipv6)
            let invite = try makeInvite(host: candidate)
            XCTAssertEqual(try LANDirectInviteV6(parsing: invite.serialized), invite)
        }

        let rejected = [
            "2001:DB8::1", "2001:0db8::1", "0:0:0:0:0:0:0:1",
            "2001:0:0:1::1:1", "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9",
            "1::2::3", "[::1]", "::ffff:c000:280", "::1%lo0", "fe80::1%en0",
            "fe80:1::1", "febf:2::1", "ff01:1::1", "ff02:2::1",
            "ff12:1::1", "ff22:a0:64ce:cd3f:6c10:1809:8788:ad58",
        ]
        for candidate in rejected {
            XCTAssertEqual(actualHost(candidate), .rejected,
                           "unexpected host: \(escapedBytes(candidate))")
            XCTAssertThrowsError(try LANDirectHostV6(candidate)) { error in
                XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidHost)
            }
        }
        for candidate in [
            "fe80:1::1", "febf:2::1", "ff01:1::1", "ff02:2::1",
            "ff12:1::1", "ff22:a0:64ce:cd3f:6c10:1809:8788:ad58",
        ] {
            XCTAssertNil(LANIPAddressCanonicalizerV6.canonicalIPv6(candidate),
                         "unexpected scoped canonical IPv6: \(escapedBytes(candidate))")
        }
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(host: "::1"))) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidAuthority)
        }
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(host: "[host.lan]"))) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidHost)
        }
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(host: "[::1%lo0]"))) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error,
                           .nonASCIIOrForbiddenCharacter)
        }
    }

    func testFixedAddressCorpusMatchesTestOnlyNetworkOracle() {
        let corpus = [
            "0.0.0.0", "0.0.0.1", "127.0.0.1", "192.168.1.20", "255.255.255.255",
            "", ".1.2.3", "1..2.3", "1.2.3.", "1.2.3", "1.2.3.4.5",
            "256.0.0.1", "1.2.3.256", "+1.2.3.4", "-1.2.3.4", "1.2.3.-1",
            " 1.2.3.4", "1.2.3.4 ", "00.0.0.0", "127.00.0.1", "127.0.0.01",
            "127.1", "2130706433", "0x7f000001", "0xffffffff", "0177.0.0.1",
            "0300.0250.0001.0024", "0x10000000000000000.1",
            "::", "::1", "1::", "2001:db8::1",
            "ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", "2001::1:0:0:1:1",
            "::ffff:192.0.2.128", "64:ff9b::c000:221", "2001:DB8::1",
            "2001:0db8::1", "0:0:0:0:0:0:0:1", "2001:0:0:1::1:1",
            "1:2:3:4:5:6:7", "1:2:3:4:5:6:7:8:9", "1::2::3", "[::1]",
            "::ffff:c000:280", "::1%lo0", "fe80::1%en0", "fe80::1",
            "ff00::", "ff01::1", "ff02::1", "ff0e::1", "ff22::1234", "ff32:1::1",
            "fe80:1::1", "febf:2::1", "ff01:1::1", "ff02:2::1", "ff12:1::1",
            "ff22:a0:64ce:cd3f:6c10:1809:8788:ad58",
            "host-2.lan", "deadbeef", "0xg", "Host.local", "host..local",
        ]

        for candidate in corpus {
            let evidence = "candidateHex=\(escapedBytes(candidate))"
            XCTAssertEqual(actualHost(candidate), referenceHost(candidate), evidence)

            let networkIPv4 = IPv4Address(candidate)
            let exactIPv4 = networkIPv4.flatMap { address -> String? in
                String(describing: address) == candidate ? candidate : nil
            }
            XCTAssertEqual(LANIPAddressCanonicalizerV6.canonicalIPv4(candidate),
                           exactIPv4, evidence)
            XCTAssertEqual(
                LANIPAddressCanonicalizerV6.canonicalIPv4(candidate) != nil
                    || LANIPAddressCanonicalizerV6.isLegacyIPv4Candidate(candidate),
                networkIPv4 != nil,
                evidence
            )

            let expectedIPv6 = candidate.contains("%") ? nil
                : referenceCanonicalIPv6(candidate)
            XCTAssertEqual(LANIPAddressCanonicalizerV6.canonicalIPv6(candidate),
                           expectedIPv6, evidence)
        }
    }

    func testAcceptedHostConstructorAndParserAreEquivalentAtBounds() throws {
        let maximumDNS = String(repeating: "a", count: 63) + "." +
            String(repeating: "b", count: 63) + "." +
            String(repeating: "c", count: 63) + "." +
            String(repeating: "d", count: 61)
        let accepted = [
            "0.0.0.0", "192.168.1.20", "255.255.255.255",
            "::", "::1", "2001:db8::1", "::ffff:192.0.2.128",
            "host-2.lan", maximumDNS,
        ]
        for candidate in accepted {
            let host = try LANDirectHostV6(candidate)
            let invite = try makeInvite(host: candidate)
            let reparsed = try LANDirectInviteV6(parsing: invite.serialized)
            XCTAssertEqual(reparsed.serialized, invite.serialized)
            XCTAssertEqual(reparsed.host.kind, host.kind)
            XCTAssertEqual(reparsed.host.value, host.value)
        }

        XCTAssertEqual(maximumDNS.utf8.count, 253)
        let oversizedHost = String(repeating: "a", count: 254)
        XCTAssertThrowsError(try LANDirectHostV6(oversizedHost)) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidHost)
        }
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(host: oversizedHost))) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidHost)
        }
        XCTAssertThrowsError(try LANDirectHostV6("fe80::1%lo0")) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidHost)
        }
    }

    func testSeededHostClassificationMatchesIndependentNetworkOracle() {
        let seed: UInt64 = 0x4c41_4e36_484f_5354
        var state = seed
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
        func randomString(alphabet: [UInt8], length: Int) -> String {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(length)
            for _ in 0..<length {
                bytes.append(alphabet[Int(next() % UInt64(alphabet.count))])
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        func numericComponent() -> String {
            let decimal = Array("0123456789".utf8)
            let octal = Array("01234567".utf8)
            let hexadecimal = Array("0123456789abcdefABCDEF".utf8)
            switch next() % 3 {
            case 0:
                return randomString(alphabet: decimal, length: Int(next() % 61) + 1)
            case 1:
                return "0" + randomString(alphabet: octal, length: Int(next() % 60) + 1)
            default:
                let prefix = next().isMultiple(of: 2) ? "0x" : "0X"
                return prefix + randomString(alphabet: hexadecimal,
                                             length: Int(next() % 59) + 1)
            }
        }

        let generic = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZxX.-:_[]%+~".utf8)
        let dns = Array("0123456789abcdefghijklmnopqrstuvwxyz-.".utf8)
        let ipv6 = Array("0123456789abcdefABCDEF:.".utf8)
        let digitDot = Array("0123456789.".utf8)

        for index in 0..<12_000 {
            let candidate: String
            switch index % 6 {
            case 0:
                candidate = randomString(alphabet: generic, length: Int(next() % 253) + 1)
            case 1:
                candidate = (0..<(Int(next() % 4) + 1))
                    .map { _ in numericComponent() }.joined(separator: ".")
            case 2:
                candidate = randomString(alphabet: dns, length: Int(next() % 253) + 1)
            case 3:
                candidate = randomString(alphabet: ipv6, length: Int(next() % 96) + 1)
            case 4:
                candidate = (0..<4).map { _ in String(next() % 256) }.joined(separator: ".")
            default:
                candidate = randomString(alphabet: digitDot, length: Int(next() % 64) + 1)
            }

            let evidence = "seed=0x4c414e36484f5354 index=\(index) candidateHex=\(escapedBytes(candidate))"
            XCTAssertEqual(actualHost(candidate), referenceHost(candidate), evidence)

            let networkIPv4 = IPv4Address(candidate)
            let exactIPv4 = networkIPv4.flatMap { address -> String? in
                String(describing: address) == candidate ? candidate : nil
            }
            let strictIPv4 = LANIPAddressCanonicalizerV6.canonicalIPv4(candidate)
            XCTAssertEqual(strictIPv4, exactIPv4, evidence)
            XCTAssertEqual(strictIPv4 != nil
                               || LANIPAddressCanonicalizerV6.isLegacyIPv4Candidate(candidate),
                           networkIPv4 != nil, evidence)

            let expectedIPv6 = candidate.contains("%") ? nil
                : referenceCanonicalIPv6(candidate)
            XCTAssertEqual(LANIPAddressCanonicalizerV6.canonicalIPv6(candidate),
                           expectedIPv6, evidence)
        }
    }

    func testGeneratedRawIPv6OracleAndMetamorphicRoundTrips() throws {
        var state: UInt64 = 0x4950_7636_5241_5734
        func next() -> UInt64 {
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            return state
        }

        var rejectedEmbeddedScopeCount = 0
        for index in 0..<4_096 {
            var bytes = [UInt8](repeating: 0, count: 16)
            for byteIndex in bytes.indices {
                bytes[byteIndex] = UInt8(truncatingIfNeeded: next() >> 24)
            }
            let oracle = try XCTUnwrap(IPv6Address(Data(bytes)), "index=\(index)")
            let oracleText = String(describing: oracle)
            let canonical = try XCTUnwrap(posixIPv6Text(bytes), "index=\(index)")
            let hasIncompatibleScope = referenceHasNetworkIncompatibleEmbeddedScope(bytes)
            let evidence = "index=\(index) rawHex=\(escapedRawBytes(bytes))"
            XCTAssertEqual(oracleText != canonical, hasIncompatibleScope, evidence)

            if hasIncompatibleScope {
                rejectedEmbeddedScopeCount += 1
                XCTAssertNil(LANIPAddressCanonicalizerV6.canonicalIPv6(canonical), evidence)
                XCTAssertThrowsError(try LANDirectHostV6(canonical), evidence) { error in
                    XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidHost, evidence)
                }
                continue
            }

            XCTAssertEqual(oracleText, canonical, evidence)
            XCTAssertEqual(LANIPAddressCanonicalizerV6.canonicalIPv6(canonical),
                           canonical, evidence)

            let host = try LANDirectHostV6(canonical)
            XCTAssertEqual(host.kind, .ipv6, evidence)
            let invite = try makeInvite(host: canonical)
            let reparsed = try LANDirectInviteV6(parsing: invite.serialized)
            XCTAssertEqual(reparsed, invite, evidence)
            XCTAssertEqual(reparsed.serialized, invite.serialized, evidence)

            assertIPv6MutationRejected(canonical.uppercased(), canonical: canonical,
                                       index: index, mutation: "uppercase")
            if let leadingZero = redundantLeadingZeroIPv6(canonical) {
                assertIPv6MutationRejected(leadingZero, canonical: canonical,
                                           index: index, mutation: "leading-zero")
            }
            if let expanded = nonminimalIPv6Expansion(canonical) {
                assertIPv6MutationRejected(expanded, canonical: canonical,
                                           index: index, mutation: "nonminimal-expansion")
            }
        }
        XCTAssertGreaterThan(rejectedEmbeddedScopeCount, 0)
    }

    func testSeededHundredThousandRawIPv6ScopePredicateMatchesNetworkOracle() throws {
        var state: UInt64 = 0x4950_7636_5241_5734
        func next() -> UInt64 {
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            return state
        }

        var incompatibleScopeCount = 0
        for index in 0..<100_000 {
            var bytes = [UInt8](repeating: 0, count: 16)
            for byteIndex in bytes.indices {
                bytes[byteIndex] = UInt8(truncatingIfNeeded: next() >> 24)
            }
            let oracle = try XCTUnwrap(IPv6Address(Data(bytes)), "index=\(index)")
            let oracleText = String(describing: oracle)
            let posixText = try XCTUnwrap(posixIPv6Text(bytes), "index=\(index)")
            let expectedRejection = referenceHasNetworkIncompatibleEmbeddedScope(bytes)
            if expectedRejection { incompatibleScopeCount += 1 }

            let evidence = "seed=0x4950763652415734 index=\(index) raw=" +
                escapedRawBytes(bytes)
            XCTAssertEqual(oracleText != posixText, expectedRejection, evidence)
            XCTAssertEqual(LANIPAddressCanonicalizerV6.canonicalIPv6(posixText),
                           expectedRejection ? nil : posixText, evidence)
        }
        XCTAssertEqual(incompatibleScopeCount, 147)
    }

    func testDNSShapeAndLengthAreStrict() throws {
        let maximum = String(repeating: "a", count: 63) + "." +
            String(repeating: "b", count: 63) + "." +
            String(repeating: "c", count: 63) + "." +
            String(repeating: "d", count: 61)
        XCTAssertEqual(maximum.utf8.count, 253)
        XCTAssertNoThrow(try LANDirectHostV6(maximum))

        let invalidHosts = [
            "Host.local", "host.local.", ".host.local", "host..local", "-host.local",
            "host-.local", "host_name.local", "host local", "hé.local",
            String(repeating: "a", count: 64) + ".local",
            maximum + "a",
        ]
        for invalid in invalidHosts {
            XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(host: invalid)),
                                 "unexpectedly accepted \(invalid)")
        }
    }

    func testPortIsCanonicalDecimalWithinUInt16Range() {
        XCTAssertNoThrow(try LANDirectInviteV6(parsing: raw(port: "1")))
        XCTAssertNoThrow(try LANDirectInviteV6(parsing: raw(port: "65535")))
        for invalid in ["", "0", "00", "01", "+1", "-1", "65536", "999999999999999999999"] {
            XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(port: invalid)),
                                 "unexpectedly accepted port \(invalid)")
        }
    }

    func testQueryKeysAndOrderAreExact() {
        let fields = query.split(separator: "&").map(String.init)
        let invalidQueries = [
            fields[1] + "&" + fields[0] + "&" + fields[2] + "&" + fields[3],
            fields.dropLast().joined(separator: "&"),
            query + "&extra=x",
            fields[0] + "&" + fields[1] + "&" + fields[2] + "&" + fields[3] + "&" + fields[3],
            query.replacingOccurrences(of: "hid=", with: "host="),
            query.replacingOccurrences(of: "wid=", with: "world="),
            query.replacingOccurrences(of: "lk=", with: "lookup="),
            query.replacingOccurrences(of: "code=", with: "joinCode="),
            query.replacingOccurrences(of: "&wid=", with: "&&wid="),
        ]
        for invalid in invalidQueries {
            XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(query: invalid)))
        }
    }

    func testEveryCryptographicAndCodeFieldIsValidatedBeforeUse() {
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(query:
            query.replacingOccurrences(of: hostIDText,
                                       with: String(repeating: "A", count: 21)))))
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(query:
            query.replacingOccurrences(of: worldIDText,
                                       with: String(repeating: "A", count: 23)))))
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(query:
            query.replacingOccurrences(of: lookupText, with: lookupText.uppercased()))))

        let mismatchedLookup = "0" + lookupText.dropFirst()
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(query:
            query.replacingOccurrences(of: lookupText, with: mismatchedLookup)))) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error, .lookupDigestMismatch)
        }
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(query:
            query.replacingOccurrences(of: "ABC123", with: "abc123"))))
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: raw(query:
            query.replacingOccurrences(of: "ABC123", with: "ABC"))))
    }

    func testNoAlternativeURISyntaxWhitespaceOrPercentEscapesAreAccepted() {
        let valid = raw()
        let invalidValues = [
            "http" + valid.dropFirst("pebble-lan-v6".count),
            "PEBBLE-LAN-V6" + valid.dropFirst("pebble-lan-v6".count),
            valid + "/",
            valid + "#fragment",
            valid + " ",
            " " + valid,
            valid.replacingOccurrences(of: "ABC123", with: "ABC%31%32%33"),
            valid.replacingOccurrences(of: "192.168.1.20", with: "user@192.168.1.20"),
            valid.replacingOccurrences(of: "192.168.1.20", with: "192.168.1.20/path"),
            "192.168.1.20 41337 ABC123",
            "pebble-lan-v6://192.168.1.20:41337",
            valid + "?again=x",
        ]
        for invalid in invalidValues {
            XCTAssertThrowsError(try LANDirectInviteV6(parsing: String(invalid)))
        }
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: valid + "\n"))
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: valid + "\u{7f}"))
        XCTAssertThrowsError(try LANDirectInviteV6(parsing: valid + "é"))
        XCTAssertThrowsError(try LANDirectInviteV6(parsing:
            String(repeating: "A", count: 1_024))) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidScheme)
        }
        XCTAssertThrowsError(try LANDirectInviteV6(parsing:
            String(repeating: "A", count: 1_025))) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidLength)
        }
        XCTAssertThrowsError(try LANDirectInviteV6(parsing:
            String(repeating: "A", count: 10_000_000))) { error in
            XCTAssertEqual(error as? LANDirectInviteV6Error, .invalidLength)
        }
    }

    func testSeededPrintableASCIIPropertyAcceptedValuesAreAlwaysCanonical() throws {
        var state: UInt64 = 0x6c61_6e2d_7636
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }

        for _ in 0..<500 {
            let length = Int(next() % 180) + 1
            let bytes = (0..<length).map { _ in UInt8(0x21 + next() % 0x5e) }
            let candidate = String(decoding: bytes, as: UTF8.self)
            if let parsed = try? LANDirectInviteV6(parsing: candidate) {
                XCTAssertEqual(parsed.serialized, candidate)
            }
        }
    }
}
