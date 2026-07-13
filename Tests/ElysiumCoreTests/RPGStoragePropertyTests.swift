import CryptoKit
import Foundation
import XCTest
@testable import ElysiumCore
@testable import ElysiumStorage

final class RPGStoragePropertyTests: XCTestCase {
    private func fixture(_ label: String) throws -> SaveDB {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ElysiumRPGProperty-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try SaveDB.open(databaseURL: directory.appendingPathComponent("elysium.db"),
                                       migrateLegacy: false)
        addTeardownBlock {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return database
    }

    func testFixedSeedTwoLocalWorldInterleavingConflictAndCorruptPayloadProperty() throws {
        let database = try fixture("two-local-worlds")
        let worlds = ["local-a", "local-b"]
        for (index, world) in worlds.enumerated() {
            database.putWorld(WorldRecord(id: world, name: world, seed: Int32(index),
                                          gameMode: 0, difficulty: 2))
        }
        var snapshots = try worlds.map { world in
            try database.materializeRPGQuickSlotPreferences(
                worldRecordID: world, defaults: RPGQuickSlotPreferences.empty)
        }
        var previous = snapshots
        var state: UInt64 = 0x5250_4750_524f_5031
        let vocabulary = (0..<32).map { "skill:s\($0)" } + (0..<16).map { "spell:p\($0)" }
        for step in 0..<1_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let worldIndex = Int((state >> 17) & 1)
            let otherIndex = 1 - worldIndex
            let beforeOther = snapshots[otherIndex]
            switch Int(state % 4) {
            case 0, 1:
                var tokens = Array(repeating: Optional<String>.none, count: 9)
                var used = Set<String>()
                for slot in tokens.indices {
                    state = state &* 6_364_136_223_846_793_005 &+ 1
                    if state & 3 == 0 { continue }
                    var value = vocabulary[Int(state % UInt64(vocabulary.count))]
                    while !used.insert(value).inserted {
                        state = state &* 6_364_136_223_846_793_005 &+ 1
                        value = vocabulary[Int(state % UInt64(vocabulary.count))]
                    }
                    tokens[slot] = value
                }
                previous[worldIndex] = snapshots[worldIndex]
                snapshots[worldIndex] = try database.compareAndSwapRPGQuickSlotPreferences(
                    worldRecordID: worlds[worldIndex], expected: snapshots[worldIndex],
                    candidatePreferences: RPGQuickSlotPreferences(tokens: tokens))
            case 2:
                if previous[worldIndex].revision < snapshots[worldIndex].revision {
                    XCTAssertThrowsError(try database.compareAndSwapRPGQuickSlotPreferences(
                        worldRecordID: worlds[worldIndex], expected: previous[worldIndex],
                        candidatePreferences: RPGQuickSlotPreferences(tokens: ["skill:stale"])),
                        "seed=0x52504750524f5031 step=\(step)")
                } else {
                    XCTAssertThrowsError(try database.compareAndSwapRPGQuickSlotPreferences(
                        worldRecordID: worlds[worldIndex], expected: snapshots[worldIndex],
                        candidatePreferences: RPGQuickSlotPreferences(
                            tokens: ["skill:duplicate", "skill:duplicate"])),
                        "seed=0x52504750524f5031 step=\(step)")
                }
            default:
                XCTAssertThrowsError(try database.compareAndSwapRPGQuickSlotPreferences(
                    worldRecordID: worlds[worldIndex], expected: snapshots[worldIndex],
                    candidatePreferences: RPGQuickSlotPreferences(
                        tokens: ["skill:duplicate", "skill:duplicate"])),
                    "seed=0x52504750524f5031 step=\(step)")
            }
            XCTAssertEqual(try database.loadRPGQuickSlotPreferences(
                worldRecordID: worlds[worldIndex]), snapshots[worldIndex],
                "seed=0x52504750524f5031 step=\(step)")
            XCTAssertEqual(try database.loadRPGQuickSlotPreferences(
                worldRecordID: worlds[otherIndex]), beforeOther,
                "cross-world leak seed=0x52504750524f5031 step=\(step)")
        }
    }

    func testFixedSeedFourByFourLANScopeDomainAndFailureIsolationProperty() throws {
        var keys = Set<ElysiumLANClientAuthorityStorageKey>()
        var encodedScopes = Set<Data>()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        for hostIndex in 0..<4 {
            for worldIndex in 0..<4 {
                let host = try LANHostInstallationIDV6(
                    bytes: [UInt8(hostIndex + 1)] + Array(repeating: 0xa5, count: 15))
                let world = try LANWorldIDV6(
                    bytes: [UInt8(worldIndex + 1)] + Array(repeating: 0x5a, count: 15))
                let scope = RPGLocalPreferenceScope.lanV6(
                    hostInstallationID: host, worldLANID: world)
                let encoded = try encoder.encode(scope)
                XCTAssertEqual(try decoder.decode(RPGLocalPreferenceScope.self, from: encoded), scope)
                XCTAssertTrue(encodedScopes.insert(encoded).inserted,
                              "host=\(hostIndex) world=\(worldIndex)")
                XCTAssertThrowsError(try rpgQuickSlotDestinationDigest(
                    scope: scope, preferences: .empty, revision: 1)) {
                    XCTAssertEqual($0 as? RPGLocalPreferenceScopeError, .invalidScopeEncoding)
                }

                let lookup = LANV6Crypto.lookupDigest(
                    hostInstallationID: host, worldLANID: world)
                let key = try ElysiumLANClientAuthorityStorageKey(
                    hostInstallationID: host.data, worldLANID: world.data,
                    lookupDigest: lookup.data)
                XCTAssertTrue(keys.insert(key).inserted,
                              "host=\(hostIndex) world=\(worldIndex)")
                var corrupt = lookup.data; corrupt[(hostIndex * 4 + worldIndex) % 32] ^= 1
                XCTAssertThrowsError(try ElysiumLANClientAuthorityStorageKey(
                    hostInstallationID: host.data, worldLANID: world.data,
                    lookupDigest: corrupt),
                    "corrupt lookup host=\(hostIndex) world=\(worldIndex)")
            }
        }
        XCTAssertEqual(keys.count, 16)
        XCTAssertEqual(encodedScopes.count, 16)
    }
}
