import Foundation
import XCTest
@testable import ElysiumCore

final class LANV6CryptoTests: XCTestCase {
    private final class DeterministicEntropy: LANV6EntropySource {
        private var bytesToReturn: [UInt8]
        private var offset = 0

        init(_ bytes: [UInt8]) {
            bytesToReturn = bytes
        }

        func bytes(count: Int) throws -> [UInt8] {
            guard offset + count <= bytesToReturn.count else {
                return []
            }
            defer { offset += count }
            return Array(bytesToReturn[offset..<(offset + count)])
        }
    }

    private struct WrongCountEntropy: LANV6EntropySource {
        func bytes(count: Int) throws -> [UInt8] {
            [UInt8](repeating: 0, count: max(0, count - 1))
        }
    }

    func testSHA256KnownAnswerAndStartupSelfCheck() throws {
        XCTAssertEqual(
            LANV6Crypto.sha256(Data("abc".utf8)).hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertTrue(LANV6Crypto.sha256KnownAnswerSelfCheck())
        XCTAssertNoThrow(try LANV6Crypto.requireSHA256KnownAnswerSelfCheck())
    }

    func testLookupDigestHasFrozenDomainAndRawByteOrdering() throws {
        let hostID = try LANHostInstallationIDV6(bytes: Array(UInt8(0)...UInt8(15)))
        let worldID = try LANWorldIDV6(bytes: Array(UInt8(16)...UInt8(31)))
        XCTAssertEqual(
            LANV6Crypto.lookupDigest(hostInstallationID: hostID, worldLANID: worldID).hex,
            "6f14474ef5682ddd836db5d3923f65e48e2725f4dfedd5086d67b25d6b071bcf"
        )

        let reversed = LANV6Crypto.lookupDigest(hostInstallationID: worldID, worldLANID: hostID)
        XCTAssertNotEqual(reversed.hex,
                          "6f14474ef5682ddd836db5d3923f65e48e2725f4dfedd5086d67b25d6b071bcf")
    }

    func testFixedLengthComparisonChecksEveryPositionAndRejectsWrongLengths() throws {
        let baseline = [UInt8](repeating: 0x5a, count: 32)
        XCTAssertTrue(LANV6Crypto.constantTimeEqual32(Data(baseline), Data(baseline)))
        for index in [0, 15, 31] {
            var changed = baseline
            changed[index] ^= 0xff
            XCTAssertFalse(LANV6Crypto.constantTimeEqual32(Data(baseline), Data(changed)))
        }
        XCTAssertFalse(LANV6Crypto.constantTimeEqual32(Data(baseline.dropLast()), Data(baseline)))
        XCTAssertFalse(LANV6Crypto.constantTimeEqual32(Data(baseline), Data(baseline + [0])))

        let tokenA = try LANV6Token256(bytes: baseline)
        let tokenB = try LANV6Token256(bytes: baseline)
        XCTAssertTrue(LANV6Crypto.constantTimeEqual(tokenA, tokenB))
    }

    func testInjectedEntropyIsExactAndInternalToTestableSurface() throws {
        let source = DeterministicEntropy(Array(UInt8(0)...UInt8(47)))
        let id = try LANV6Crypto.randomID128(using: source)
        let token = try LANV6Crypto.randomToken256(using: source)
        XCTAssertEqual(id.bytes, Array(UInt8(0)...UInt8(15)))
        XCTAssertEqual(token.bytes, Array(UInt8(16)...UInt8(47)))
        XCTAssertThrowsError(try LANV6Crypto.randomBytes(count: -1, using: source))
        XCTAssertThrowsError(try LANV6Crypto.randomBytes(count: 16,
                                                         using: WrongCountEntropy()))
    }

    func testJoinCodeGenerationUsesRejectionSampling() throws {
        let source = DeterministicEntropy([252, 0, 251, 253, 35, 36])
        let code = try LANV6JoinCode.generate(length: 4, using: source)
        XCTAssertEqual(code.value, "A99A")
        XCTAssertThrowsError(try LANV6JoinCode.generate(length: 3, using: source))
        XCTAssertThrowsError(try LANV6JoinCode.generate(length: 9, using: source))
    }

    func testProductionSecureEntropyReturnsExactRequestedSizes() throws {
        XCTAssertEqual(try LANV6Crypto.randomBytes(count: 0), [])
        XCTAssertEqual(try LANV6Crypto.randomID128().bytes.count, 16)
        XCTAssertEqual(try LANV6Crypto.randomToken256().bytes.count, 32)
        XCTAssertEqual(try LANV6JoinCode.generate().value.utf8.count, 6)
    }
}
