import CryptoKit
import Foundation
import XCTest
@testable import ElysiumCore

final class RPGLocalPreferenceCodecAdversarialTests: XCTestCase {
    private let empty = RPGQuickSlotPreferences.empty

    private func token(_ scalarCount: Int, kind: String = "skill") -> String {
        "\(kind):" + String(repeating: "a", count: scalarCount - kind.utf8.count - 1)
    }

    private func canonicalDestinationInput(world: String, preferences: RPGQuickSlotPreferences,
                                           schema: UInt16, revision: UInt64) throws -> Data {
        var data = Data("Pebble/RPGLocalQuickSlots/destination/v1".utf8)
        data.append(0)
        func append16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        func append32(_ value: UInt32) {
            data.append(UInt8(truncatingIfNeeded: value >> 24))
            data.append(UInt8(truncatingIfNeeded: value >> 16))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
            data.append(UInt8(truncatingIfNeeded: value))
        }
        append32(UInt32(world.utf8.count)); data.append(contentsOf: world.utf8)
        append16(schema)
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: revision >> UInt64(shift)))
        }
        data.append(try rpgEncodeQuickSlotPreferencesStoragePayload(preferences))
        return data
    }

    func testPBLQS1NilValueTagsNineSlotsAndTokenLengthBoundaries() throws {
        let encodedEmpty = try rpgEncodeQuickSlotPreferencesStoragePayload(empty)
        XCTAssertEqual(encodedEmpty.prefix(9), Data([0x50, 0x42, 0x4c, 0x51, 0x53, 0x31,
                                                     0x00, 0x01, 0x09]))
        XCTAssertEqual(encodedEmpty.count, 18)
        XCTAssertEqual(try rpgDecodeQuickSlotPreferencesStoragePayload(encodedEmpty), empty)

        for length in [7, 70] {
            // Canonical grammar requires a non-empty ID and caps the ID itself at 64 bytes.
            let value = token(length)
            let preferences = RPGQuickSlotPreferences(tokens: [value])
            let encoded = try rpgEncodeQuickSlotPreferencesStoragePayload(preferences)
            XCTAssertEqual(encoded[9], 1)
            XCTAssertEqual(Int(encoded[10]) << 8 | Int(encoded[11]), length)
            XCTAssertEqual(try rpgDecodeQuickSlotPreferencesStoragePayload(encoded), preferences)
        }
        for length in [0, 1, 128, 129] {
            var raw = Data("PBLQS1".utf8); raw.append(contentsOf: [0, 1, 9, 1])
            raw.append(UInt8(truncatingIfNeeded: length >> 8))
            raw.append(UInt8(truncatingIfNeeded: length))
            raw.append(Data(repeating: UInt8(ascii: "a"), count: length))
            raw.append(Data(repeating: 0, count: 8))
            XCTAssertThrowsError(try rpgDecodeQuickSlotPreferencesStoragePayload(raw),
                                 "length=\(length)")
        }
    }

    func testPBLQS1RejectsGrammarDuplicatesTrailingBytesLengthsAndMalformedUTF8() throws {
        let duplicate = RPGQuickSlotPreferences(tokens: ["skill:mining", "skill:mining"])
        XCTAssertThrowsError(try rpgEncodeQuickSlotPreferencesStoragePayload(duplicate))

        let valid = try rpgEncodeQuickSlotPreferencesStoragePayload(
            RPGQuickSlotPreferences(tokens: ["skill:mining"]))
        for mutation: (String, Data) in [
            ("trailing", valid + Data([0])),
            ("bad-tag", Data(valid.enumerated().map { $0.offset == 9 ? 2 : $0.element })),
            ("zero-length", Data(valid.enumerated().map {
                ($0.offset == 10 || $0.offset == 11) ? 0 : $0.element
            })),
            ("oversized-length", Data(valid.enumerated().map {
                $0.offset == 10 ? 0 : ($0.offset == 11 ? 129 : $0.element)
            })),
            ("truncated", valid.dropLast()),
        ] {
            XCTAssertThrowsError(try rpgDecodeQuickSlotPreferencesStoragePayload(mutation.1),
                                 mutation.0)
        }
        var malformedUTF8 = Data("PBLQS1".utf8)
        malformedUTF8.append(contentsOf: [0, 1, 9, 1, 0, 7, 0x73, 0x6b, 0x69, 0x6c,
                                           0x6c, 0x3a, 0xff])
        malformedUTF8.append(Data(repeating: 0, count: 8))
        XCTAssertThrowsError(try rpgDecodeQuickSlotPreferencesStoragePayload(malformedUTF8))
    }

    func testPBLQS1FixedSeedDecodeFuzzIsBoundedAndDeterministic() {
        var state: UInt64 = 0x5042_4c51_5331_f00d
        var accepted = 0
        for _ in 0..<4_096 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let count = Int(state % 260)
            var bytes = [UInt8](); bytes.reserveCapacity(count)
            for _ in 0..<count {
                state = state &* 6_364_136_223_846_793_005 &+ 1
                bytes.append(UInt8(truncatingIfNeeded: state >> 32))
            }
            if (try? rpgDecodeQuickSlotPreferencesStoragePayload(Data(bytes))) != nil {
                accepted += 1
            }
        }
        XCTAssertEqual(accepted, 0, "seed=0x50424c515331f00d")
    }

    func testPBLQS1FixedSeedEncodeDecodeMetamorphism() throws {
        let vocabulary = (0..<36).map { "skill:s\($0)" } + (0..<18).map { "spell:p\($0)" }
        var state: UInt64 = 0x51_53_4d_45_54_41
        for iteration in 0..<2_000 {
            var shuffled = vocabulary
            for index in shuffled.indices.reversed() where index > 0 {
                state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                shuffled.swapAt(index, Int(state % UInt64(index + 1)))
            }
            var slots: [String?] = []
            for index in 0..<9 {
                state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
                slots.append((state & 3) == 0 ? nil : shuffled[index])
            }
            let value = RPGQuickSlotPreferences(tokens: slots)
            let encoded = try rpgEncodeQuickSlotPreferencesStoragePayload(value)
            XCTAssertEqual(try rpgDecodeQuickSlotPreferencesStoragePayload(encoded), value,
                           "seed=0x51534d455441 iteration=\(iteration)")
        }
    }

    func testCanonicalDigestDomainsFieldsEndianAndChunkBoundaries() throws {
        let preferences = RPGQuickSlotPreferences(tokens: ["skill:mining", "spell:arc_bolt"])
        let scope = try RPGLocalPreferenceScope.validatedLocalWorld("world")
        let destination = try rpgQuickSlotDestinationDigest(
            scope: scope, preferences: preferences, schemaVersion: 1,
            revision: 0x0102_0304_0506_0708)
        let source = try rpgLegacyQuickSlotSourceDigest(preferences)
        XCTAssertNotEqual(destination, source)
        XCTAssertNotEqual(destination, try rpgQuickSlotDestinationDigest(
            scope: .validatedLocalWorld("world-2"), preferences: preferences,
            schemaVersion: 1, revision: 0x0102_0304_0506_0708))
        XCTAssertNotEqual(destination, try rpgQuickSlotDestinationDigest(
            scope: scope, preferences: preferences, schemaVersion: 1,
            revision: 0x0807_0605_0403_0201))
        XCTAssertNotEqual(destination, try rpgQuickSlotDestinationDigest(
            scope: scope, preferences: RPGQuickSlotPreferences(tokens: ["skill:logging"]),
            schemaVersion: 1, revision: 0x0102_0304_0506_0708))

        let input = try canonicalDestinationInput(
            world: "world", preferences: preferences, schema: 1,
            revision: 0x0102_0304_0506_0708)
        XCTAssertEqual(destination.data, Data(SHA256.hash(data: input)))
        for chunkSize in [1, 2, 3, 7, 31, 32, 33, 63, 64, 65, input.count] {
            var hasher = SHA256()
            var offset = 0
            while offset < input.count {
                let end = min(input.count, offset + chunkSize)
                hasher.update(data: input.subdata(in: offset..<end)); offset = end
            }
            XCTAssertEqual(destination.data, Data(hasher.finalize()), "chunk=\(chunkSize)")
        }
        var mutated = input
        for index in mutated.indices {
            mutated[index] ^= 1
            XCTAssertNotEqual(Data(SHA256.hash(data: mutated)), destination.data,
                              "field-byte=\(index)")
            mutated[index] ^= 1
        }
        XCTAssertTrue(LANV6Crypto.constantTimeEqual32(destination.data, destination.data))
        var wrong = destination.data; wrong[31] ^= 1
        XCTAssertFalse(LANV6Crypto.constantTimeEqual32(destination.data, wrong))
    }
}
