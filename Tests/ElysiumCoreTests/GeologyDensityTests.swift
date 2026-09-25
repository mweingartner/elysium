import XCTest
@testable import ElysiumCore

/// Quantitative terrain-only surveys: surface landmarks and decoration cannot
/// manufacture a passing cave/lava count, and bottom-of-world lava is excluded.
final class GeologyDensityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
    }

    private struct Survey {
        var dryAir = 0
        var caveVolume = 0
        var lavaCells = 0
        var lavaColumns = 0
    }

    private let regions: [(seed: UInt32, cx: Int, cz: Int)] = [
        (12_345, 0, 0), (12_345, 24, -18), (12_345, -40, 27),
        (2_024, -4, -4), (2_024, 38, 12), (2_024, -26, 44),
    ]

    private func volcanicLandPreset() throws -> WorldPreset {
        try XCTUnwrap(WorldPreset.normalCycle.first {
            $0.supportsVolcanicTerrain && $0.prehistoricProfile?.profileID == "lostWorld"
        })
    }

    /// A fixed two-by-two chunk patch per region, at least eight blocks below
    /// the solid surface and no cells below -48. This excludes open sky, surface water,
    /// and the universal bottom lava layer from the underground measurements.
    private func survey(_ preset: WorldPreset,
                        regions: [(seed: UInt32, cx: Int, cz: Int)]) -> Survey {
        var result = Survey()
        let settings = WorldGenerationSettings(preset: preset)
        for region in regions {
            for cz in region.cz..<(region.cz + 2) {
                for cx in region.cx..<(region.cx + 2) {
                    let terrain = buildBaseTerrainChunk(seed: region.seed, cx: cx, cz: cz,
                                                        settings: settings)
                    for z in 0..<CHUNK_W {
                        for x in 0..<CHUNK_W {
                            guard let surface = terrain.topSolidY(worldX: cx * CHUNK_W + x,
                                                                  worldZ: cz * CHUNK_W + z) else {
                                continue
                            }
                            let ceiling = min(surface - 8, 48)
                            guard ceiling >= -48 else { continue }
                            var hasLava = false
                            for y in -48...ceiling {
                                let id = terrain.blocks[((y - GEN_MIN_Y) * CHUNK_W + z) * CHUNK_W + x] >> 4
                                if id == B.air {
                                    result.dryAir += 1
                                    result.caveVolume += 1
                                } else if id == B.lava {
                                    result.lavaCells += 1
                                    result.caveVolume += 1
                                    hasLava = true
                                } else if id == B.water {
                                    result.caveVolume += 1
                                }
                            }
                            if hasLava { result.lavaColumns += 1 }
                        }
                    }
                }
            }
        }
        return result
    }

    func testVolcanicProfilesIncreaseRealUndergroundCavesAcrossSeparatedRegions() throws {
        let legacy = survey(.prehistoricLostWorldV2, regions: regions)
        let volcanic = survey(try volcanicLandPreset(), regions: regions)
        let rich = survey(.moderateHillsResourceRich, regions: regions)
        print("Geology survey, 24 chunks across six regions: legacy air=\(legacy.dryAir), void=\(legacy.caveVolume), lavaColumns=\(legacy.lavaColumns); volcanic air=\(volcanic.dryAir), void=\(volcanic.caveVolume), lavaColumns=\(volcanic.lavaColumns); rich air=\(rich.dryAir), void=\(rich.caveVolume), lavaColumns=\(rich.lavaColumns)")

        XCTAssertGreaterThan(legacy.dryAir, 0, "the matched old terrain must contain real caves")
        XCTAssertGreaterThan(volcanic.dryAir, legacy.dryAir * 11 / 10,
                             "the new profile must add usable air caves, not just flooded volume")
        XCTAssertGreaterThan(volcanic.caveVolume, legacy.caveVolume * 11 / 10,
                             "the increase must survive carving and surface materialization")
        XCTAssertGreaterThan(rich.dryAir, legacy.dryAir / 2,
                             "rolling hills must retain substantial ordinary cave habitat")
    }

    func testBroaderAquifersIncreaseLavaRegionsWithoutReplacingWater() throws {
        let presets = [.moderateHillsResourceRich] + WorldPreset.normalCycle.filter(\.supportsVolcanicTerrain)
        XCTAssertEqual(presets.count, 5, "Rich Resources and all four new prehistoric profiles opt in")
        var legacyLava = 0
        var expandedLava = 0
        var waterSamples = 0
        for seed: UInt32 in [2_024, 12_345, 0xCAFE_BABE] {
            let legacy = OverworldGen(seed)
            let generators = presets.map { OverworldGen(seed, settings: .init(preset: $0)) }
            for z in stride(from: -4_096, through: 4_096, by: 256) {
                for x in stride(from: -4_096, through: 4_096, by: 256) {
                    let cl = legacy.climate.at(Double(x), Double(z))
                    let old = legacy.aquiferAt(Double(x), Double(z), cl)
                    if old.lava { legacyLava += 1 }
                    for (index, generator) in generators.enumerated() {
                        let new = generator.aquiferAt(Double(x), Double(z), cl)
                        if new.lava {
                            XCTAssertEqual(new.level, 12, "more frequent lava must not mean higher lava")
                            if index == 0 { expandedLava += 1 }
                        }
                        if old.lava {
                            XCTAssertTrue(new.lava, "the larger lava domain must retain all old provinces")
                        } else if old.level != -1_000 {
                            XCTAssertFalse(new.lava, "ocean and groundwater keep precedence")
                            XCTAssertEqual(new.level, old.level)
                            if index == 0 { waterSamples += 1 }
                        }
                        let reference = generators[0].aquiferAt(Double(x), Double(z), cl)
                        XCTAssertEqual(new.lava, reference.lava,
                                       "all opted-in profiles share the same bounded aquifer expansion")
                        XCTAssertEqual(new.level, reference.level)
                    }
                }
            }
        }
        print("Aquifer survey, 3267 separated samples: legacy lava=\(legacyLava), expanded lava=\(expandedLava), unchanged water=\(waterSamples)")
        XCTAssertGreaterThan(legacyLava, 0)
        XCTAssertGreaterThan(waterSamples, 0)
        XCTAssertGreaterThan(expandedLava, legacyLava * 5 / 4,
                             "lava needs materially more regions, not just one enlarged lake")
    }

    func testExpandedAquiferRegionsMaterializeMidDepthLavaColumns() throws {
        let volcanicPreset = try volcanicLandPreset()
        var transitionRegions: [(seed: UInt32, cx: Int, cz: Int)] = []
        // Locate reproducible aquifer-transition witnesses from a fixed broad
        // survey. Selection only consults the two aquifer contracts, never the
        // resulting block counts, so an empty expanded cave cannot be skipped.
        for seed: UInt32 in [2_024, 12_345, 0xCAFE_BABE] {
            let legacy = OverworldGen(seed)
            let expanded = OverworldGen(seed, settings: .init(preset: volcanicPreset))
            var seedRegions = 0
            search: for z in stride(from: -4_096, through: 4_096, by: 256) {
                for x in stride(from: -4_096, through: 4_096, by: 256) {
                    let cl = legacy.climate.at(Double(x), Double(z))
                    if !legacy.aquiferAt(Double(x), Double(z), cl).lava,
                       expanded.aquiferAt(Double(x), Double(z), cl).lava {
                        transitionRegions.append((seed, floorDiv(x, CHUNK_W), floorDiv(z, CHUNK_W)))
                        seedRegions += 1
                        if seedRegions == 2 { break search }
                    }
                }
            }
            XCTAssertEqual(seedRegions, 2, "each seed must supply two distinct expanded-lava regions")
        }
        let legacy = survey(.prehistoricLostWorldV2, regions: transitionRegions)
        let volcanic = survey(volcanicPreset, regions: transitionRegions)
        let rich = survey(.moderateHillsResourceRich, regions: transitionRegions)
        print("Expanded-region terrain, 24 chunks: legacy lava=\(legacy.lavaCells) in \(legacy.lavaColumns) columns; volcanic lava=\(volcanic.lavaCells) in \(volcanic.lavaColumns) columns; rich lava=\(rich.lavaCells) in \(rich.lavaColumns) columns")
        for (name, expanded) in [("volcanic", volcanic), ("rich", rich)] {
            XCTAssertGreaterThan(expanded.lavaColumns, legacy.lavaColumns + 32,
                                 "\(name) must materialize broader mid-depth lava beyond bottom-bedrock lava")
            XCTAssertGreaterThan(expanded.lavaCells, legacy.lavaCells + 128,
                                 "\(name) must produce actual lakes, not merely an aquifer flag")
        }
    }

    func testLegacyLandProfilesKeepTheExactNormalBaseTerrain() {
        let legacyPresets: [WorldPreset] = [
            .prehistoricLostWorld, .prehistoricJurassicGiants, .prehistoricCretaceousFrontiers,
            .prehistoricLostWorldV2, .prehistoricJurassicGiantsV2, .prehistoricCretaceousFrontiersV2,
        ]
        for fixture in [(UInt32(12_345), 0, 0), (UInt32(0xCAFE_BABE), -2, 3)] {
            let normal = buildBaseTerrainChunk(seed: fixture.0, cx: fixture.1, cz: fixture.2)
            for preset in legacyPresets {
                XCTAssertFalse(preset.supportsVolcanicTerrain)
                let legacy = buildBaseTerrainChunk(seed: fixture.0, cx: fixture.1, cz: fixture.2,
                                                   settings: .init(preset: preset))
                XCTAssertEqual(legacy.blocks, normal.blocks, "\(preset) must retain the golden Default terrain path")
                XCTAssertEqual(legacy.biomes, normal.biomes)
                XCTAssertEqual(legacy.heights, normal.heights)
            }
        }
        XCTAssertFalse(WorldPreset.prehistoricAncientSeas.supportsVolcanicTerrain)
        XCTAssertFalse(WorldPreset.prehistoricAncientSeasV2.supportsVolcanicTerrain)
        // AncientSeasTerrainTests separately pins v1/v2 equality and its
        // connected-water and dry-island contract, which differs from Default.
    }

    func testRichResourcesUsesExactOrdinaryCarversAcrossRegions() {
        for region in regions {
            var normal = [UInt16](repeating: cell(B.stone), count: CHUNK_W * CHUNK_W * WORLD_H)
            var rich = normal
            OverworldGen(region.seed).carve(region.cx, region.cz, &normal)
            OverworldGen(region.seed, settings: .init(preset: .moderateHillsResourceRich))
                .carve(region.cx, region.cz, &rich)
            XCTAssertEqual(rich, normal, "Rich Resources must no longer thin tunnels or ravines")
        }
    }
}
