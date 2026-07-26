import Foundation
import XCTest
@testable import ElysiumCore

final class RealityDerivedImportTests: XCTestCase {
    private var cleanup: [URL] = []

    override func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if BIOMES.isEmpty || BIOMES[Biome.plains.rawValue] == nil { registerAllBiomes() }
    }

    override func tearDown() {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
        cleanup.removeAll()
        super.tearDown()
    }

    private func append<T>(_ value: T, to data: inout Data) {
        var value = value
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func fixture(complete: Bool = true, overflowRun: Bool = false,
                         unknownBlock: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-reality-test-\(UUID().uuidString)")
        cleanup.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        var payload = Data()
        append(Int32(0).littleEndian, to: &payload)
        append(Int32(0).littleEndian, to: &payload)
        append(UInt16(1).littleEndian, to: &payload)
        append(Int8(0), to: &payload)
        append(UInt16(3).littleEndian, to: &payload)
        append(UInt16(overflowRun ? 4096 : 1).littleEndian, to: &payload)
        append(UInt16(84).littleEndian, to: &payload)
        append(UInt16(1).littleEndian, to: &payload)
        append(UInt16(unknownBlock ? 500 : 17).littleEndian, to: &payload)
        append(UInt16(4094).littleEndian, to: &payload)
        append(UInt16(1).littleEndian, to: &payload)
        let properties = try JSONSerialization.data(
            withJSONObject: ["facing": "east", "half": "top"], options: [.sortedKeys])
        append(UInt16(1).littleEndian, to: &payload)
        append(UInt16(1).littleEndian, to: &payload)
        append(UInt32(properties.count).littleEndian, to: &payload)
        payload.append(properties)
        for _ in 0..<256 { append(Int16(0).littleEndian, to: &payload) }

        var stream = Data("ELEXSTR3".utf8)
        append(UInt32(1).littleEndian, to: &stream)
        append(UInt32(payload.count).littleEndian, to: &stream)
        stream.append(payload)
        try stream.write(to: root.appendingPathComponent("chunks.elxstream"))

        let unknown: [[String: Any]] = unknownBlock ? [["id": 500, "name": "future_city_block"]] : []
        let manifest: [String: Any] = [
            "format": REALITY_EXCHANGE_FORMAT, "version": REALITY_EXCHANGE_VERSION,
            "complete": complete, "generator": "Arnis test adapter", "chunkCount": 1,
            "minChunkX": 0, "maxChunkX": 0, "minChunkZ": 0, "maxChunkZ": 0,
            "minGeoLat": 21.30, "maxGeoLat": 21.31,
            "minGeoLon": -157.86, "maxGeoLon": -157.85,
            "projection": "EPSG:4326", "scale": 1.0,
            "spawnX": 0, "spawnY": 1, "spawnZ": 0, "streamBytes": stream.count,
            "blocks": [["id": 1, "name": "air"], ["id": 17, "name": "cobblestone_stairs"],
                       ["id": 84, "name": "stone"]] + unknown,
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("manifest.json"))
        return root
    }

    private func world(for plan: RealityDerivedImportPlan, id: String = "reality") -> WorldRecord {
        var world = WorldRecord(id: id, name: "Honolulu", seed: 42,
                                gameMode: 0, difficulty: 2, mapSize: .small)
        world.spawnX = plan.spawnX; world.spawnY = plan.spawnY; world.spawnZ = plan.spawnZ
        world.mapCenterX = plan.mapCenterX; world.mapCenterZ = plan.mapCenterZ
        world.realityDerivedSource = plan.source
        return world
    }

    func testStreamsArnisExchangePreservesMetadataAndBuildsTransition() throws {
        let plan = try makeRealityDerivedImportPlan(at: fixture(), worldID: "reality")
        XCTAssertEqual(plan.importedChunkCount, 1)
        XCTAssertEqual(plan.transitionChunkCount, 80)
        XCTAssertEqual(plan.spawnY, 1)
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "reality-stream")
        var progress: [(Int, Int)] = []
        XCTAssertEqual(try database.putRealityDerivedWorldStreaming(
            world(for: plan), plan: plan,
            progress: { progress.append(($0, $1)) }), 82)
        XCTAssertEqual(database.getChunkKeys("reality").count, 81)
        let imported = try XCTUnwrap(database.getChunk("reality", 0, 0, 0))
        let blocks = try XCTUnwrap(imported.blocks)
        let y0 = -dimInfo(.overworld).minY
        XCTAssertEqual(blocks[y0 * 256] >> 4, B.stone)
        XCTAssertEqual(blocks[y0 * 256 + 1] >> 4, B.cobblestone_stairs)
        XCTAssertEqual(blocks[y0 * 256 + 1] & 15, 7)
        XCTAssertEqual(progress.last?.0, 81)
        XCTAssertEqual(progress.last?.1, 81)

        let firstEast = try XCTUnwrap(database.getChunk("reality", 0, 1, 0))
        let eastBlocks = try XCTUnwrap(firstEast.blocks)
        for y in stride(from: GEN_MIN_Y + WORLD_H - 1, through: GEN_MIN_Y, by: -1) {
            let cell = eastBlocks[((y - GEN_MIN_Y) * 16 + 8) * 16]
            let id = Int(cell >> 4)
            if cell != 0, id != Int(B.water), id != Int(B.lava), SOLID[id] == 1 {
                XCTAssertEqual(y, 0, "the first transition column meets imported ground")
                break
            }
        }
    }

    func testUnknownFutureBlockFallsBackToStone() throws {
        let plan = try makeRealityDerivedImportPlan(
            at: fixture(unknownBlock: true), worldID: "reality")
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "reality-unknown")
        _ = try database.putRealityDerivedWorldStreaming(world(for: plan), plan: plan)
        let blocks = try XCTUnwrap(database.getChunk("reality", 0, 0, 0)?.blocks)
        XCTAssertEqual(blocks[-dimInfo(.overworld).minY * 256 + 1] >> 4, B.stone)
    }

    func testRejectsIncompleteManifestAndRollsBackMalformedStream() throws {
        XCTAssertThrowsError(try makeRealityDerivedImportPlan(
            at: fixture(complete: false), worldID: "reality"))
        let plan = try makeRealityDerivedImportPlan(
            at: fixture(overflowRun: true), worldID: "reality")
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "reality-malformed")
        XCTAssertThrowsError(try database.putRealityDerivedWorldStreaming(world(for: plan), plan: plan))
        XCTAssertNil(database.getWorld("reality"))
        XCTAssertTrue(database.getChunkKeys("reality").isEmpty)
    }

    func testRejectsSymlinkedStream() throws {
        let root = try fixture()
        let stream = root.appendingPathComponent("chunks.elxstream")
        let target = root.appendingPathComponent("outside.elxstream")
        try FileManager.default.moveItem(at: stream, to: target)
        try FileManager.default.createSymbolicLink(at: stream, withDestinationURL: target)
        XCTAssertThrowsError(try makeRealityDerivedImportPlan(at: root, worldID: "reality"))
    }

    func testCancellationRollsBackAndPlanIsSingleUse() throws {
        let plan = try makeRealityDerivedImportPlan(at: fixture(), worldID: "reality")
        let database = try PersistenceTestSupport.makeDatabase(owner: self, label: "reality-cancel")
        XCTAssertThrowsError(try database.putRealityDerivedWorldStreaming(
            world(for: plan), plan: plan, cancelled: { true }))
        XCTAssertNil(database.getWorld("reality"))
        XCTAssertThrowsError(try database.putRealityDerivedWorldStreaming(world(for: plan), plan: plan))
    }

    func testRealitySourceAndMapSizeRoundTripWithLegacyCompatibility() throws {
        let plan = try makeRealityDerivedImportPlan(at: fixture(), worldID: "reality")
        let original = world(for: plan)
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WorldRecord.self, from: encoded)
        XCTAssertEqual(decoded.realityDerivedSource, plan.source)
        XCTAssertEqual(decoded.mapSize, .small)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "mapSize")
        legacy.removeValue(forKey: "mapCenterX")
        legacy.removeValue(forKey: "mapCenterZ")
        let legacyDecoded = try JSONDecoder().decode(
            WorldRecord.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(legacyDecoded.mapSize, .max)
    }

    func testRealityDerivedUsesEstablishedWorldSeedContract() {
        XCTAssertEqual(GameCore.worldSeed(from: "4242"), 4242)
        XCTAssertEqual(GameCore.worldSeed(from: "Elysium"), 20_469_504)
        XCTAssertEqual(GameCore.worldSeed(from: " 4242 "), 4242)
    }

    func testVCK2CompactCodecRoundTripsWithoutFullChunkSizedStorage() throws {
        let biomes = [UInt8](repeating: UInt8(Biome.plains.rawValue),
                             count: 4 * 4 * ((WORLD_H + 3) / 4))
        let sections = [CompactChunkSectionV2(
            y: 0, runs: [CompactChunkRunV2(length: 4096, value: B.stone << 4)])]
        let data = try XCTUnwrap(encodeCompactVCK2(
            dimension: Dim.overworld.rawValue, sections: sections, biomes: biomes))
        XCTAssertLessThan(data.count, 100, "uniform terrain should remain compact")
        let decoded = try XCTUnwrap(decodeLegacyVCK(
            data, key: "w:0:0,0", worldId: "w", dimension: 0, chunkX: 0, chunkZ: 0))
        let blocks = try XCTUnwrap(decoded.blocks)
        XCTAssertEqual(blocks[-GEN_MIN_Y * 256], B.stone << 4)
        XCTAssertEqual(blocks[(-GEN_MIN_Y + 16) * 256], 0)
    }

    func testPlayerTravelBoundaryIsInvisibleAndExact() {
        let world = World(dim: .overworld, seed: 1)
        world.playableMinX = -500; world.playableMaxX = 499
        world.playableMinZ = -500; world.playableMaxZ = 499
        let player = Player(world: world)
        player.setPos(499.5, 100, 0)
        player.move(10, 0, 0)
        XCTAssertLessThan(player.x, 500)
        XCTAssertEqual(player.vx, 0)
        player.setPos(0, 100, -499.5)
        player.move(0, 0, -10)
        XCTAssertGreaterThan(player.z, -500)
        XCTAssertEqual(player.vz, 0)
    }
}
