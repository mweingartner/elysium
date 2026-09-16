import XCTest
@testable import ElysiumCore

final class ExactTerrainStructureTests: XCTestCase {
    private let seed: UInt32 = 0x51A7_C0DE

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    private func context(_ settings: WorldGenerationSettings,
                         heightAt: @escaping (Int, Int) -> Int) -> GenCtx {
        let generator = overworldGen(seed, settings: settings)
        return GenCtx(
            seed: seed,
            heightAt: heightAt,
            biomeAt: { x, z in
                generator.surfaceBiomeAt(Double(x), Double(z)).rawValue
            },
            dim: Dim.overworld.rawValue,
            villageDensity: settings.villageDensity,
            generationSettingsIdentity: settings.cacheIdentity,
            baseTerrainOracleVersion: baseTerrainOracleVersion,
            terrainOracle: BaseTerrainOracle(seed: seed, settings: settings,
                                              maxCachedChunks: 512, maxQueries: 1_000_000)
        )
    }

    private func actualContext(_ settings: WorldGenerationSettings) -> GenCtx {
        let generator = overworldGen(seed, settings: settings)
        return context(settings, heightAt: { x, z in
            generator.refinedHeightEstimate(Double(x), Double(z))
        })
    }

    private func deliberatelyWrongHeightContext(_ settings: WorldGenerationSettings) -> GenCtx {
        context(settings, heightAt: { _, _ in -999 })
    }

    private func firstAcceptedPlan(_ id: String, _ context: GenCtx,
                                   regions: ClosedRange<Int>,
                                   qualifying: ((Int, Int, StructurePlan) -> Bool)? = nil) -> (originX: Int, originZ: Int, plan: StructurePlan)? {
        guard let def = STRUCTURES.first(where: { $0.id == id }),
              let placement = def.placement(context) else {
            XCTFail("\(id) must remain registered with an active placement")
            return nil
        }
        for regionZ in regions {
            for regionX in regions {
                let origin = structureOriginFor(def, placement: placement,
                                                 seed: seed, regionX: regionX, regionZ: regionZ)
                if let plan = getPlan(def, context, origin.0, origin.1),
                   qualifying?(origin.0, origin.1, plan) ?? true {
                    return (origin.0, origin.1, plan)
                }
            }
        }
        XCTFail("expected an accepted \(id) plan in reviewed fixed scan")
        return nil
    }

    private func materialize(_ plan: StructurePlan,
                             settings: WorldGenerationSettings) -> [String: GenOutput] {
        guard let minX = plan.pieces.map(\.x0).min(), let maxX = plan.pieces.map(\.x1).max(),
              let minZ = plan.pieces.map(\.z0).min(), let maxZ = plan.pieces.map(\.z1).max() else {
            XCTFail("a materialized structure must contain at least one piece")
            return [:]
        }
        var outputs: [String: GenOutput] = [:]
        for cz in floorDiv(minZ, CHUNK_W)...floorDiv(maxZ, CHUNK_W) {
            for cx in floorDiv(minX, CHUNK_W)...floorDiv(maxX, CHUNK_W) {
                outputs["\(cx),\(cz)"] = generateChunk(.overworld, seed, cx, cz, settings: settings)
            }
        }
        return outputs
    }

    private func generatedCell(_ x: Int, _ y: Int, _ z: Int,
                               outputs: [String: GenOutput]) -> Int {
        guard y >= GEN_MIN_Y, y < GEN_MIN_Y + WORLD_H else { return -1 }
        let cx = floorDiv(x, CHUNK_W), cz = floorDiv(z, CHUNK_W)
        guard let output = outputs["\(cx),\(cz)"] else { return -1 }
        let lx = x - cx * CHUNK_W, lz = z - cz * CHUNK_W
        return Int(output.blocks[((y - GEN_MIN_Y) * CHUNK_W + lz) * CHUNK_W + lx])
    }

    private func isFullSolid(_ value: Int) -> Bool {
        guard value > 0 else { return false }
        let id = value >> 4
        return SOLID.indices.contains(id) && SOLID[id] == 1
    }

    func testExactSurfaceConsumesOneBoundedOracleQuery() throws {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface,
                                               singleBiome: .plains,
                                               villageDensity: .none)
        let oracle = BaseTerrainOracle(seed: seed, settings: settings,
                                       maxCachedChunks: 1, maxQueries: 1)

        let surface = try XCTUnwrap(oracle.exactSurface(0, 0))
        XCTAssertGreaterThan(surface.feetY, GEN_MIN_Y)
        XCTAssertEqual(oracle.observedQueryCount, 1,
                       "one exact-surface observation must consume one bounded oracle query")
        XCTAssertNil(oracle.exactSurface(1, 0),
                     "the helper must not silently exceed the caller's oracle budget")
        XCTAssertEqual(oracle.observedQueryCount, 1)
    }

    func testSpentLowBudgetOracleCannotPoisonCachedPlanOrTreeExclusions() throws {
        // A caller can arrive after its own lookup budget was spent elsewhere.
        // That transient history must neither reject the exact-terrain plan
        // stored in getPlan's global cache nor leave an empty tree-clearance
        // entry for a later generous caller with the same immutable context.
        let settings = WorldGenerationSettings(preset: .flat, villageDensity: .none)
        let planID = "oracle_budget_plan_cache"
        let canopyID = "desert_temple"

        func context(oracle: BaseTerrainOracle, identity: String) -> GenCtx {
            GenCtx(seed: seed,
                   heightAt: { _, _ in GEN_MIN_Y + 4 },
                   biomeAt: { _, _ in Biome.plains.rawValue },
                   dim: Dim.overworld.rawValue,
                   villageDensity: .none,
                   generationSettingsIdentity: identity,
                   baseTerrainOracleVersion: baseTerrainOracleVersion,
                   terrainOracle: oracle)
        }

        func exactTerrainDefinition(id: String) -> StructureDef {
            StructureDef(
                id: id, spacing: 1, separation: 0,
                salt: id == canopyID ? 0xCA10_0C1E : 0xCA10_0C1F,
                maxRadiusChunks: 0,
                check: { ctx, originX, originZ, _ in
                    originX == 0 && originZ == 0
                        && exactTerrainSurface(ctx, 0, 0)?.isDry == true
                        && exactTerrainSurface(ctx, 1, 0)?.isDry == true
                },
                plan: { ctx, _, _, _ in
                    guard let first = exactTerrainSurface(ctx, 0, 0),
                          let second = exactTerrainSurface(ctx, 1, 0),
                          first.isDry, second.isDry else {
                        return nil
                    }
                    return StructurePlan(id: id, pieces: [
                        piece(0, first.feetY, 0, 0, second.feetY, 0) { _ in },
                    ])
                }
            )
        }

        let lowOracle = BaseTerrainOracle(seed: seed, settings: settings,
                                          maxCachedChunks: 1, maxQueries: 1)
        XCTAssertNotNil(lowOracle.exactSurface(-1, -1),
                        "fixture must deliberately exhaust the caller-local budget")
        let generousOracle = BaseTerrainOracle(seed: seed, settings: settings,
                                               maxCachedChunks: 32, maxQueries: 10_000)

        let planContextID = "spent-low-oracle-plan-cache"
        let lowPlanContext = context(oracle: lowOracle, identity: planContextID)
        let generousPlanContext = context(oracle: generousOracle, identity: planContextID)
        let planDefinition = exactTerrainDefinition(id: planID)
        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }

        let plannedBySpentCaller = try XCTUnwrap(getPlan(planDefinition, lowPlanContext, 0, 0))
        let plannedByGenerousCaller = try XCTUnwrap(getPlan(planDefinition, generousPlanContext, 0, 0))
        XCTAssertEqual(plannedBySpentCaller.id, plannedByGenerousCaller.id)
        XCTAssertEqual(plannedBySpentCaller.pieces.count, plannedByGenerousCaller.pieces.count)
        XCTAssertEqual(lowOracle.observedQueryCount, 1,
                       "getPlan must not draw through the caller's already exhausted oracle")
        XCTAssertEqual(generousOracle.observedQueryCount, 0,
                       "the generous replay must use the cached immutable plan, not caller state")
        XCTAssertEqual(structurePlanCacheStatsForTesting().computations, 1)

        let lowCanopyOracle = BaseTerrainOracle(seed: seed, settings: settings,
                                                maxCachedChunks: 1, maxQueries: 1)
        XCTAssertNotNil(lowCanopyOracle.exactSurface(-2, -2))
        let generousCanopyOracle = BaseTerrainOracle(seed: seed, settings: settings,
                                                     maxCachedChunks: 32, maxQueries: 10_000)
        let canopyContextID = "spent-low-oracle-tree-exclusions"
        let lowCanopyContext = context(oracle: lowCanopyOracle, identity: canopyContextID)
        let generousCanopyContext = context(oracle: generousCanopyOracle, identity: canopyContextID)
        let canopyDefinition = exactTerrainDefinition(id: canopyID)

        let lowExclusions = treeCanopyExclusions(forOriginChunk: 0, 0,
                                                  context: lowCanopyContext,
                                                  structures: [canopyDefinition],
                                                  collisionDefinitions: [canopyDefinition])
        let generousExclusions = treeCanopyExclusions(forOriginChunk: 0, 0,
                                                       context: generousCanopyContext,
                                                       structures: [canopyDefinition],
                                                       collisionDefinitions: [canopyDefinition])
        let signature: ([TreeStructureExclusion]) -> [String] = { exclusions in
            exclusions.map { "\($0.x0):\($0.z0):\($0.x1):\($0.z1)" }.sorted()
        }
        XCTAssertEqual(signature(lowExclusions), ["-6:-6:6:6"],
                       "the spent caller must still publish the exact plan's canopy clearance")
        XCTAssertEqual(signature(generousExclusions), signature(lowExclusions),
                       "low-then-generous tree exclusion lookup must be cache-order independent")
        XCTAssertEqual(lowCanopyOracle.observedQueryCount, 1)
        XCTAssertEqual(generousCanopyOracle.observedQueryCount, 0)
    }

    func testDryOutpostPadUsesExactTerrainAndMaterializesSafeFooting() throws {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface,
                                               singleBiome: .plains,
                                               villageDensity: .none)
        resetStructurePlanCacheForTesting()
        let planned = try XCTUnwrap(firstAcceptedPlan("pillager_outpost",
                                                       deliberatelyWrongHeightContext(settings),
                                                       regions: -5...5))
        let x = planned.originX * 16 + 4
        let z = planned.originZ * 16 + 4
        let outpostY = try XCTUnwrap(planned.plan.pieces.first).y0 + 6

        let exact = actualContext(settings)
        let expectedY = try XCTUnwrap(exactDryTerrainPadY(exact,
                                                           x - 5, z, x + 14, z + 10,
                                                           maxVariation: 3))
        XCTAssertEqual(outpostY, expectedY,
                       "a real Overworld outpost must use the exact full-pad height, not GenCtx.heightAt")
        XCTAssertNotEqual(outpostY, -999)
        for zc in z...(z + 10) {
            for xc in (x - 5)...(x + 14) {
                let surface = try XCTUnwrap(exactTerrainSurface(exact, xc, zc))
                XCTAssertTrue(surface.isDry, "every planned outpost column must be dry")
                XCTAssertLessThanOrEqual(outpostY - surface.feetY, 3,
                                         "outpost foundations only accept their reviewed contour range")
            }
        }

        resetStructurePlanCacheForTesting()
        let outputs = materialize(planned.plan, settings: settings)
        let guardEntity = try XCTUnwrap(outputs.values.flatMap(\.entities).first {
            $0.mob == "pillager"
                && $0.x == Double(x + 2) + 0.5
                && $0.y == Double(outpostY + 1)
                && $0.z == Double(z + 3) + 0.5
        })
        let guardX = Int(guardEntity.x.rounded(.down))
        let guardY = Int(guardEntity.y.rounded(.down))
        let guardZ = Int(guardEntity.z.rounded(.down))
        XCTAssertTrue(isFullSolid(generatedCell(guardX, guardY - 1, guardZ, outputs: outputs)),
                      "the materialized guard needs a full solid floor")
        XCTAssertEqual(generatedCell(guardX, guardY, guardZ, outputs: outputs), 0)
        XCTAssertEqual(generatedCell(guardX, guardY + 1, guardZ, outputs: outputs), 0)
    }

    func testStiltedWitchHutUsesExactTerrainAndReachesItsGround() throws {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface,
                                               singleBiome: .swamp)
        resetStructurePlanCacheForTesting()
        let exact = actualContext(settings)
        let planned = try XCTUnwrap(firstAcceptedPlan("witch_hut",
                                                       deliberatelyWrongHeightContext(settings),
                                                       regions: -6...6,
                                                       qualifying: { originX, originZ, _ in
                                                           let x = originX * 16 + 5
                                                           let z = originZ * 16 + 5
                                                           return [(1, 1), (5, 1), (1, 7), (5, 7)].contains { sx, sz in
                                                               exactTerrainSurface(exact, x + sx, z + sz)?.isDry == false
                                                           }
                                                       }))
        let originX = planned.originX
        let originZ = planned.originZ
        let plan = planned.plan
        let piece = try XCTUnwrap(plan.pieces.first)
        let x = originX * 16 + 5
        let z = originZ * 16 + 5
        let y = piece.y1 - 7

        var highestFeet = Int.min
        for zc in z...(z + 8) {
            for xc in x...(x + 6) {
                highestFeet = max(highestFeet, try XCTUnwrap(exactTerrainSurface(exact, xc, zc)).feetY)
            }
        }
        XCTAssertEqual(y, max(64, highestFeet + 1),
                       "the hut floor must use the exact platform footprint, not the fake height closure")
        XCTAssertNotEqual(y, -998)
        XCTAssertTrue([(1, 1), (5, 1), (1, 7), (5, 7)].contains { sx, sz in
            exactTerrainSurface(exact, x + sx, z + sz)?.isDry == false
        }, "the reviewed fixture must retain an ordinary swamp-water stilt")

        resetStructurePlanCacheForTesting()
        // This reviewed hut fits wholly in its origin chunk, so direct replay
        // proves the real chunk path rather than only invoking the piece.
        let outputs = ["\(originX),\(originZ)": generateChunk(.overworld, seed, originX, originZ, settings: settings)]
        let witch = try XCTUnwrap(outputs.values.flatMap(\.entities).first { $0.mob == "witch" })
        XCTAssertEqual(witch.y, Double(y + 3))
        XCTAssertTrue(isFullSolid(generatedCell(x + 3, y + 2, z + 4, outputs: outputs)))
        XCTAssertEqual(generatedCell(x + 3, y + 3, z + 4, outputs: outputs), 0)
        XCTAssertEqual(generatedCell(x + 3, y + 4, z + 4, outputs: outputs), 0)

        for (sx, sz) in [(1, 1), (5, 1), (1, 7), (5, 7)] {
            let feetY = try XCTUnwrap(exactTerrainSurface(exact, x + sx, z + sz)).feetY
            for stiltY in feetY...y {
                XCTAssertEqual(generatedCell(x + sx, stiltY, z + sz, outputs: outputs), Int(cell(B.oak_log)),
                               "each stilt must reach the exact solid ground through normal swamp water")
            }
        }
    }

    func testAquaticAndBuriedStructuresKeepTheirExactTerrainOffsets() throws {
        let oceanSettings = WorldGenerationSettings(preset: .singleBiomeSurface,
                                                    singleBiome: .ocean,
                                                    villageDensity: .none)
        resetStructurePlanCacheForTesting()
        let oceanExact = actualContext(oceanSettings)
        let ocean = try XCTUnwrap(firstAcceptedPlan("ocean_ruin",
                                                     deliberatelyWrongHeightContext(oceanSettings),
                                                     regions: -6...6,
                                                     qualifying: { originX, originZ, _ in
                                                         exactTerrainSurface(oceanExact,
                                                                             originX * 16 + 7,
                                                                             originZ * 16 + 7)?.isDry == false
                                                     }))
        let oceanX = ocean.originX * 16 + 4
        let oceanZ = ocean.originZ * 16 + 4
        let oceanY = try XCTUnwrap(ocean.plan.pieces.first).y0 + 2
        let oceanSurface = try XCTUnwrap(exactTerrainSurface(oceanExact, oceanX + 3, oceanZ + 3))
        XCTAssertFalse(oceanSurface.isDry, "ocean ruins must preserve their underwater placement semantics")
        XCTAssertEqual(oceanY, oceanSurface.feetY)
        XCTAssertNotEqual(oceanY, -999)

        resetStructurePlanCacheForTesting()
        let oceanOutputs = materialize(ocean.plan, settings: oceanSettings)
        XCTAssertTrue(oceanOutputs.values.flatMap(\.blockEntities).contains {
            $0.kind == "chest_loot" && $0.x == oceanX + 3 && $0.y == oceanY && $0.z == oceanZ + 3
        }, "the exact underwater anchor must still materialize the ruin chest")

        let beachSettings = WorldGenerationSettings(preset: .singleBiomeSurface,
                                                    singleBiome: .beach,
                                                    villageDensity: .none)
        resetStructurePlanCacheForTesting()
        let treasure = try XCTUnwrap(firstAcceptedPlan("buried_treasure",
                                                        deliberatelyWrongHeightContext(beachSettings),
                                                        regions: -12...12))
        let treasureX = treasure.originX * 16 + 9
        let treasureZ = treasure.originZ * 16 + 9
        let treasureY = try XCTUnwrap(treasure.plan.pieces.first).y0
        let beachExact = actualContext(beachSettings)
        let beachSurface = try XCTUnwrap(exactTerrainSurface(beachExact, treasureX, treasureZ))
        XCTAssertEqual(treasureY, beachSurface.feetY - 4,
                       "buried treasure must retain its documented exact-surface depth")
        XCTAssertNotEqual(treasureY, -1_003)

        resetStructurePlanCacheForTesting()
        let treasureOutputs = materialize(treasure.plan, settings: beachSettings)
        XCTAssertTrue(treasureOutputs.values.flatMap(\.blockEntities).contains {
            $0.kind == "chest_loot" && $0.x == treasureX && $0.y == treasureY && $0.z == treasureZ
        }, "the exact buried anchor must still materialize its chest")
    }
}
