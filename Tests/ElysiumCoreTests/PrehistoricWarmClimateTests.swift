import XCTest
@testable import ElysiumCore

/// Version-four dinosaur worlds have a warm climate: no generated snow or ice
/// section, and weather never snows or freezes water. v3 stays frozen.
final class PrehistoricWarmClimateTests: XCTestCase {
    private let seed: UInt32 = 0x5EED_0002

    private static let coldBiomes: [Biome] = [
        .frozenOcean, .deepFrozenOcean, .frozenRiver, .snowyBeach, .snowyPlains, .iceSpikes,
        .snowyTaiga, .grove, .snowySlopes, .jaggedPeaks, .frozenPeaks,
    ]

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    private func snowOrIceCount(_ blocks: [UInt16]) -> Int {
        let frozen = [B.snow, B.snow_block, B.powder_snow, B.ice, B.packed_ice, B.blue_ice]
        // Below y 0 only the ancient city's ice-box room uses packed ice.
        let firstSurfaceIndex = (0 - GEN_MIN_Y) * CHUNK_W * CHUNK_W
        return blocks[firstSurfaceIndex...].filter { frozen.contains($0 >> 4) }.count
    }

    func testWarmBiomeRemapNeverSelectsASnowingOrIcyBiome() {
        let overworld = Biome.allCases.filter { $0.rawValue < Biome.netherWastes.rawValue }
        for biome in overworld {
            let warm = prehistoricWarmBiome(biome)
            XCTAssertFalse(Self.coldBiomes.contains(warm), "\(biome) -> \(warm)")
            XCTAssertFalse(snowsAt(warm.rawValue, 64), "\(biome) -> \(warm) snows at sea level")
            let def = biomeDef(warm.rawValue)
            XCTAssertNotEqual(def.top >> 4, B.snow_block, "\(warm)")
            XCTAssertFalse(def.features.contains { ["iceberg", "ice_spike", "ice_patch", "powder_snow"]
                .contains($0.split(separator: ":").first.map(String.init) ?? "") }, "\(warm)")
        }
        for biome in overworld where !Self.coldBiomes.contains(biome) {
            XCTAssertEqual(prehistoricWarmBiome(biome), biome, "warm biomes are not reshuffled")
        }
    }

    func testV4GeneratesNoSnowOrIceWhereV3HasFrozenTerrain() throws {
        let v3 = WorldGenerationSettings(preset: .prehistoricLostWorldV3)
        let v4 = WorldGenerationSettings(preset: .prehistoricLostWorldV4)
        let v3Gen = OverworldGen(seed, settings: v3)
        let v4Gen = OverworldGen(seed, settings: v4)

        // Find distinct cold v3 biomes (snowy lowland, frozen water, peaks)
        // on a coarse deterministic grid, then generate the same chunks in
        // both revisions.
        var sites: [(cx: Int, cz: Int, biome: Biome)] = []
        search: for z in stride(from: -6144, through: 6144, by: 96) {
            for x in stride(from: -6144, through: 6144, by: 96) {
                let biome = v3Gen.surfaceBiomeAt(Double(x), Double(z))
                guard Self.coldBiomes.contains(biome), !sites.contains(where: { $0.biome == biome }) else { continue }
                sites.append((floorDiv(x, CHUNK_W), floorDiv(z, CHUNK_W), biome))
                XCTAssertFalse(Self.coldBiomes.contains(v4Gen.surfaceBiomeAt(Double(x), Double(z))), "\(biome)")
                if sites.count == 5 { break search }
            }
        }
        XCTAssertGreaterThanOrEqual(sites.count, 3, "the sample must cover several cold v3 biomes")

        var v3Frozen = 0
        for site in sites {
            for cz in site.cz...(site.cz + 1) {
                for cx in site.cx...(site.cx + 1) {
                    let frozen = generateChunk(.overworld, seed, cx, cz, settings: v3)
                    v3Frozen += snowOrIceCount(frozen.blocks)
                    let warm = generateChunk(.overworld, seed, cx, cz, settings: v4)
                    XCTAssertEqual(snowOrIceCount(warm.blocks), 0, "v4 chunk \(cx),\(cz) near \(site.biome)")
                    XCTAssertFalse(warm.biomes.contains { biome in
                        Self.coldBiomes.contains { $0.rawValue == Int(biome) }
                    }, "v4 chunk \(cx),\(cz) stores a cold biome")
                }
            }
        }
        XCTAssertGreaterThan(v3Frozen, 0, "control: the same v3 chunks keep their snow and ice")
    }

    func testWarmClimateWeatherNeverSnowsOrFreezesWater() {
        func tickedColumn(_ preset: WorldPreset) -> (snow: Bool, ice: Bool) {
            let world = World(dim: .overworld, seed: seed, generationSettings: .init(preset: preset))
            let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
            chunk.status = .lit
            for z in 0..<CHUNK_W {
                for x in 0..<CHUNK_W {
                    chunk.set(x, 170, z, cell(x < 8 ? B.stone : B.water))
                }
            }
            for index in chunk.biomes.indices { chunk.biomes[index] = UInt8(Biome.snowyTaiga.rawValue) }
            chunk.buildHeightmap()
            world.setChunk(chunk)
            world.light.initChunkLight(chunk)
            world.rainLevel = 1
            XCTAssertEqual(world.precipitationIsSnow(biome: Biome.snowyTaiga.rawValue, y: 171),
                           !preset.supportsWarmClimate)
            weatherRandomTick(world, 2, 2)
            weatherRandomTick(world, 12, 12)
            return (world.getBlockId(2, 171, 2) == Int(B.snow), world.getBlockId(12, 170, 12) == Int(B.ice))
        }
        let frozen = tickedColumn(.prehistoricLostWorldV3)
        XCTAssertTrue(frozen.snow && frozen.ice, "control: v3 weather still snows and freezes")
        let warm = tickedColumn(.prehistoricLostWorldV4)
        XCTAssertFalse(warm.snow, "v4 weather must not layer snow")
        XCTAssertFalse(warm.ice, "v4 weather must not freeze water")
    }
}
