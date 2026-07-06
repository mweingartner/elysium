import XCTest
@testable import PebbleCore

final class WorldPresetTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
    }

    func testWorldPresetAliasesNormalizeToMojangIDs() {
        XCTAssertEqual(normalizedWorldPreset(nil), .normal)
        XCTAssertEqual(normalizedWorldPreset("default"), .normal)
        XCTAssertEqual(normalizedWorldPreset("flat"), .flat)
        XCTAssertEqual(normalizedWorldPreset("superflat"), .flat)
        XCTAssertEqual(normalizedWorldPreset("minecraft:large_biomes"), .largeBiomes)
        XCTAssertEqual(normalizedWorldPreset("pebble:moderate_hills_resource_rich"), .moderateHillsResourceRich)
        XCTAssertEqual(normalizedWorldPreset("Moderate Hills - Resource Rich"), .moderateHillsResourceRich)
        XCTAssertEqual(normalizedWorldPreset("Noderate Hills - Resource Rich"), .moderateHillsResourceRich)
        XCTAssertEqual(normalizedWorldPreset("single biome"), .singleBiomeSurface)
        XCTAssertEqual(normalizedWorldPreset("debug"), .debugAllBlockStates)
        XCTAssertEqual(normalizedWorldPreset("not-real"), .normal)
    }

    func testWorldRecordDefaultsLegacyPresetFields() throws {
        let legacy = """
        {
          "id":"w1",
          "name":"Legacy",
          "seed":123,
          "gameMode":0,
          "difficulty":2,
          "lastPlayed":1,
          "version":"pebble-test",
          "dims":{"0":{"time":0,"dayTime":1000,"raining":false,"thundering":false,"weatherTimer":24000}},
          "spawnX":0,
          "spawnY":80,
          "spawnZ":0,
          "gameRules":{},
          "dragonKilled":false,
          "gatewaysSpawned":0,
          "nextEntityId":1
        }
        """
        let rec = try JSONDecoder().decode(WorldRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(rec.generationSettings, .normal)
        XCTAssertEqual(rec.worldPreset, WorldPreset.normal.rawValue)
        XCTAssertEqual(rec.singleBiome, "plains")
    }

    func testWorldRecordSanitizesUnknownPresetFields() throws {
        var rec = WorldRecord(id: "w2", name: "Bad", seed: 7, gameMode: 0, difficulty: 2,
                              worldPreset: .amplified, singleBiome: .desert)
        rec.worldPreset = "minecraft:not_real"
        rec.singleBiome = "minecraft:not_real"
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(WorldRecord.self, from: data)
        XCTAssertEqual(decoded.generationSettings, .normal)
        XCTAssertEqual(decoded.worldPreset, WorldPreset.normal.rawValue)
        XCTAssertEqual(decoded.singleBiome, "plains")
    }

    func testFlatPresetUsesJavaDefaultLayerStack() {
        let out = generateChunk(.overworld, 123, 0, 0,
                                settings: WorldGenerationSettings(preset: .flat))
        func cellAt(_ x: Int, _ y: Int, _ z: Int) -> UInt16 {
            out.blocks[((y - GEN_MIN_Y) * 16 + z) * 16 + x]
        }
        XCTAssertEqual(cellAt(0, -64, 0), cell(B.bedrock))
        XCTAssertEqual(cellAt(0, -63, 0), cell(B.dirt))
        XCTAssertEqual(cellAt(0, -62, 0), cell(B.dirt))
        XCTAssertEqual(cellAt(0, -61, 0), cell(B.grass_block))
        XCTAssertEqual(cellAt(0, -60, 0), 0)
        XCTAssertTrue(out.biomes.allSatisfy { $0 == UInt8(Biome.plains.rawValue) })
    }

    func testSingleBiomePresetPinsOverworldBiomeData() {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface, singleBiome: .desert)
        let out = generateChunk(.overworld, 321, 0, 0, settings: settings)
        XCTAssertTrue(out.biomes.allSatisfy { $0 == UInt8(Biome.desert.rawValue) })
    }

    func testDebugPresetBuildsFloorAndBlockStateGrid() {
        let out = generateChunk(.overworld, 999, 0, 0,
                                settings: WorldGenerationSettings(preset: .debugAllBlockStates))
        func cellAt(_ x: Int, _ y: Int, _ z: Int) -> UInt16 {
            out.blocks[((y - GEN_MIN_Y) * 16 + z) * 16 + x]
        }
        XCTAssertEqual(cellAt(0, 60, 0), cell(B.bedrock))
        XCTAssertNotEqual(cellAt(0, 70, 0), 0)
        XCTAssertEqual(cellAt(0, 69, 0), 0)
    }

    func testModerateHillsResourceRichPresetIsHillyButCapped() {
        let settings = WorldGenerationSettings(preset: .moderateHillsResourceRich)
        let gen = OverworldGen(2468, settings: settings)
        var heights: [Int] = []
        for z in stride(from: -256, through: 256, by: 32) {
            for x in stride(from: -256, through: 256, by: 32) {
                heights.append(gen.heightEstimate(Double(x), Double(z)))
            }
        }
        let minH = heights.min() ?? 0
        let maxH = heights.max() ?? 0
        XCTAssertGreaterThan(maxH - minH, 12)
        XCTAssertGreaterThanOrEqual(minH, 54)
        XCTAssertLessThanOrEqual(maxH, 118)
    }

    func testModerateHillsResourceRichGreatlyIncreasesOreFamiliesOnSolidTerrain() {
        let normal = oreFamilyCounts(settings: .normal)
        let rich = oreFamilyCounts(settings: WorldGenerationSettings(preset: .moderateHillsResourceRich))
        for family in ["coal", "iron", "copper", "gold", "redstone", "lapis", "diamond"] {
            let normalCount = normal[family, default: 0]
            XCTAssertGreaterThan(normalCount, 0, "normal fixture should expose \(family) before comparison")
            XCTAssertGreaterThanOrEqual(rich[family, default: 0], normalCount * 9 / 5, "\(family) should reflect doubled placement attempts after vein collisions")
        }
        XCTAssertGreaterThan(rich["emerald", default: 0], 0)
    }

    func testModerateHillsResourceRichMakesCarvedCavernsRare() {
        let normal = carvedAirCount(settings: .normal)
        let rich = carvedAirCount(settings: WorldGenerationSettings(preset: .moderateHillsResourceRich))
        XCTAssertGreaterThan(normal, 0)
        XCTAssertLessThan(rich, normal / 4)
    }

    private func oreFamilyCounts(settings: WorldGenerationSettings) -> [String: Int] {
        let gen = OverworldGen(77, settings: settings)
        let surfaceBiomes = [UInt8](repeating: UInt8(Biome.plains.rawValue), count: 256)
        let families = oreFamilyByBlockID
        var counts: [String: Int] = [:]
        for cz in 0..<4 {
            for cx in 0..<4 {
                var blocks = solidOreFixtureBlocks()
                gen.placeOres(cx, cz, &blocks, surfaceBiomes)
                for cell in blocks {
                    let id = Int(cell >> 4)
                    if let family = families[id] {
                        counts[family, default: 0] += 1
                    }
                }
            }
        }
        return counts
    }

    private func carvedAirCount(settings: WorldGenerationSettings) -> Int {
        let gen = OverworldGen(12345, settings: settings)
        var total = 0
        for cz in -1...1 {
            for cx in -1...1 {
                var blocks = solidOreFixtureBlocks()
                gen.carve(cx, cz, &blocks)
                total += blocks.reduce(0) { $0 + ($1 == 0 ? 1 : 0) }
            }
        }
        return total
    }

    private func solidOreFixtureBlocks() -> [UInt16] {
        var blocks = [UInt16](repeating: cell(B.stone), count: CHUNK_W * CHUNK_W * WORLD_H)
        for y in GEN_MIN_Y..<0 {
            for z in 0..<16 {
                for x in 0..<16 {
                    blocks[((y - GEN_MIN_Y) * 16 + z) * 16 + x] = cell(B.deepslate)
                }
            }
        }
        return blocks
    }

    private var oreFamilyByBlockID: [Int: String] {
        [
            Int(B.coal_ore): "coal", Int(B.deepslate_coal_ore): "coal",
            Int(B.iron_ore): "iron", Int(B.deepslate_iron_ore): "iron",
            Int(B.copper_ore): "copper", Int(B.deepslate_copper_ore): "copper",
            Int(B.gold_ore): "gold", Int(B.deepslate_gold_ore): "gold",
            Int(B.redstone_ore): "redstone", Int(B.deepslate_redstone_ore): "redstone",
            Int(B.lapis_ore): "lapis", Int(B.deepslate_lapis_ore): "lapis",
            Int(B.diamond_ore): "diamond", Int(B.deepslate_diamond_ore): "diamond",
            Int(B.emerald_ore): "emerald", Int(B.deepslate_emerald_ore): "emerald",
        ]
    }
}
