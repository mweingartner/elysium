import XCTest
@testable import ElysiumCore

/// Regression coverage for the opt-in Ancient Seas terrain treatment.  The
/// profile must make a meaningful navigable-water habitat without changing the
/// frozen normal terrain path or turning every starting area into open ocean.
final class AncientSeasTerrainTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
    }

    private struct WaterSurvey {
        let totalColumns: Int
        let waterColumns: Int
        let deepWaterColumns: Int
        let largestDeepWaterComponent: Int
    }

    private func fnvU16(_ values: [UInt16]) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for value in values {
            hash = (hash ^ UInt32(value & 0xff)) &* 16_777_619
            hash = (hash ^ UInt32(value >> 8)) &* 16_777_619
        }
        return hash
    }

    /// Samples a fixed 6x6 chunk region and measures cells with at least six
    /// contiguous water blocks below the surface.  That depth is deliberately
    /// lower than the largest roster member's eventual swim envelope; it
    /// measures the terrain's navigable habitat rather than duplicating the
    /// creature controller's stricter spawn gate.
    private func surveyWater(seed: UInt32, settings: WorldGenerationSettings) -> WaterSurvey {
        let chunkRange = -3...2
        let side = chunkRange.count * CHUNK_W
        var water = [Bool](repeating: false, count: side * side)
        var waterColumns = 0
        var deepWaterColumns = 0

        func waterDepth(_ terrain: BaseTerrainChunk, x: Int, z: Int) -> Int {
            guard let top = terrain.highestOccupiedCell(worldX: x, worldZ: z),
                  Int(top.cell >> 4) == Int(B.water) else {
                return 0
            }
            var depth = 0
            var y = top.y
            while y >= GEN_MIN_Y,
                  let cell = terrain.cell(worldX: x, y: y, worldZ: z),
                  Int(cell >> 4) == Int(B.water) {
                depth += 1
                y -= 1
            }
            return depth
        }

        for (chunkZIndex, cz) in chunkRange.enumerated() {
            for (chunkXIndex, cx) in chunkRange.enumerated() {
                let terrain = buildBaseTerrainChunk(seed: seed, cx: cx, cz: cz, settings: settings)
                for localZ in 0..<CHUNK_W {
                    for localX in 0..<CHUNK_W {
                        let worldX = cx * CHUNK_W + localX
                        let worldZ = cz * CHUNK_W + localZ
                        let depth = waterDepth(terrain, x: worldX, z: worldZ)
                        guard depth > 0 else { continue }
                        waterColumns += 1
                        guard depth >= 6 else { continue }
                        deepWaterColumns += 1
                        let index = (chunkZIndex * CHUNK_W + localZ) * side
                            + chunkXIndex * CHUNK_W + localX
                        water[index] = true
                    }
                }
            }
        }

        var visited = [Bool](repeating: false, count: water.count)
        var largestComponent = 0
        for start in water.indices where water[start] && !visited[start] {
            var queue = [start]
            visited[start] = true
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                let x = current % side
                let z = current / side
                let neighbors = [
                    x > 0 ? current - 1 : nil,
                    x + 1 < side ? current + 1 : nil,
                    z > 0 ? current - side : nil,
                    z + 1 < side ? current + side : nil,
                ]
                for candidate in neighbors.compactMap({ $0 }) where water[candidate] && !visited[candidate] {
                    visited[candidate] = true
                    queue.append(candidate)
                }
            }
            largestComponent = max(largestComponent, queue.count)
        }

        return WaterSurvey(totalColumns: side * side, waterColumns: waterColumns,
                           deepWaterColumns: deepWaterColumns,
                           largestDeepWaterComponent: largestComponent)
    }

    /// Mirrors the deterministic candidate criteria used by new-world spawn
    /// selection.  Keeping this probe at the terrain level avoids constructing
    /// a save database merely to establish that the coast-heavy profile still
    /// offers a dry starting island for representative seeds.
    private func hasDryInitialSpawnCandidate(seed: UInt32,
                                            preset: WorldPreset = .prehistoricAncientSeas) -> Bool {
        let settings = WorldGenerationSettings(preset: preset)
        let generator = OverworldGen(seed, settings: settings)
        let seaLevel = DIMS[Dim.overworld.rawValue].seaLevel
        for radius in 0..<40 {
            let x = 8 + radius * 40
            let z = 8 + ((radius * 13) % 7 - 3) * 40
            let biome = generator.surfaceBiomeAt(Double(x), Double(z))
            let name = (BIOMES[biome.rawValue]?.name ?? "").lowercased()
            if generator.heightEstimate(Double(x), Double(z)) > seaLevel + 2,
               !name.contains("ocean"), !name.contains("river"),
               !name.contains("swamp"), !name.contains("beach") {
                return true
            }
        }
        return false
    }

    func testNormalTerrainFillGoldenRemainsPinned() {
        let generator = OverworldGen(12_345)
        var blocks = [UInt16](repeating: 0, count: CHUNK_W * CHUNK_W * WORLD_H)
        var biomes = [UInt8](repeating: 0, count: 4 * 4 * ((WORLD_H + 3) / 4))
        _ = generator.fillTerrain(0, 0, &blocks, &biomes)
        XCTAssertEqual(fnvU16(blocks), 2_587_849_205,
                       "Ancient Seas must not perturb the normal terrain golden path")
    }

    func testAncientSeasCreatesConnectedDeepWaterWhileKeepingIslandLandfalls() {
        let seed: UInt32 = 0x51EA_C0A5
        let normal = surveyWater(seed: seed, settings: .normal)
        let ancient = surveyWater(
            seed: seed,
            settings: WorldGenerationSettings(preset: .prehistoricAncientSeas)
        )

        XCTAssertGreaterThan(ancient.waterColumns, normal.waterColumns + ancient.totalColumns / 4,
                             "the profile must be materially more water-rich than its normal counterpart")
        XCTAssertGreaterThan(ancient.deepWaterColumns, ancient.totalColumns / 4,
                             "a coast-heavy world needs substantial water deep enough to navigate")
        XCTAssertGreaterThan(ancient.largestDeepWaterComponent, ancient.totalColumns / 4,
                             "marine habitat must include a connected body, not isolated puddles")
        XCTAssertLessThan(ancient.waterColumns, ancient.totalColumns * 9 / 10,
                          "Ancient Seas must retain dry island/coast landfalls for a survival spawn")
        for spawnSeed: UInt32 in [0, 1, seed, 0xCAFE_BABE] {
            XCTAssertTrue(hasDryInitialSpawnCandidate(seed: spawnSeed),
                          "Ancient Seas must retain a deterministic dry new-world spawn candidate for \(spawnSeed)")
        }
    }

    func testAncientSeasBaseTerrainAndWaterBiomeSelectionAreDeterministic() {
        let settings = WorldGenerationSettings(preset: .prehistoricAncientSeas)
        let first = buildBaseTerrainChunk(seed: 0xCAFE_BABE, cx: -2, cz: 3, settings: settings)
        let second = buildBaseTerrainChunk(seed: 0xCAFE_BABE, cx: -2, cz: 3, settings: settings)
        XCTAssertEqual(first.blocks, second.blocks)
        XCTAssertEqual(first.biomes, second.biomes)
        XCTAssertEqual(first.heights, second.heights)

        let generator = overworldGen(0xCAFE_BABE, settings: settings)
        let centerBiome = generator.surfaceBiomeAt(Double(-2 * CHUNK_W + 8), Double(3 * CHUNK_W + 8))
        XCTAssertEqual(first.surfaceBiomes[8 * CHUNK_W + 8], UInt8(centerBiome.rawValue))
    }

    func testLegacyV2AncientSeasKeepsTheV1TerrainDomain() {
        let legacy = WorldGenerationSettings(preset: .prehistoricAncientSeas)
        let v2 = WorldGenerationSettings(preset: .prehistoricAncientSeasV2)
        let legacyChunk = buildBaseTerrainChunk(seed: 0xCAFE_BABE, cx: -2, cz: 3, settings: legacy)
        let v2Chunk = buildBaseTerrainChunk(seed: 0xCAFE_BABE, cx: -2, cz: 3, settings: v2)

        XCTAssertEqual(v2Chunk.blocks, legacyChunk.blocks)
        XCTAssertEqual(v2Chunk.biomes, legacyChunk.biomes)
        XCTAssertEqual(v2Chunk.heights, legacyChunk.heights)
    }

    func testCurrentVolcanicAncientSeasRetainsConnectedMarineHabitatAndLandfalls() {
        let seed: UInt32 = 0x51EA_C0A5
        let current = surveyWater(seed: seed,
                                 settings: .init(preset: .prehistoricAncientSeasV3))
        XCTAssertGreaterThan(current.deepWaterColumns, current.totalColumns / 4)
        XCTAssertGreaterThan(current.largestDeepWaterComponent, current.totalColumns / 4,
                             "volcanic terrain must not fragment Ancient Seas into isolated ponds")
        XCTAssertLessThan(current.waterColumns, current.totalColumns * 9 / 10,
                          "the current profile must keep dry island/coast landfalls")
        for spawnSeed: UInt32 in [0, 1, seed, 0xCAFE_BABE] {
            XCTAssertTrue(hasDryInitialSpawnCandidate(seed: spawnSeed,
                                                      preset: .prehistoricAncientSeasV3))
        }
    }
}
