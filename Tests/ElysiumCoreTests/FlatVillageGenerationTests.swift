import XCTest
@testable import ElysiumCore

final class FlatVillageGenerationTests: XCTestCase {
    private let seed: UInt32 = 0x51A7_C0DE
    private let desertCamelPenOrigin = (x: 0, z: 21)

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    /// Locate an actually accepted low-density settlement rather than baking a
    /// fragile region coordinate into the test.  On flat plains every accepted
    /// candidate has exact, level terrain, so this isolates the settings and
    /// flat-oracle path from ordinary biome/terrain rejection.
    private func firstFlatVillagePlan(density: VillageDensity) -> (WorldGenerationSettings, StructurePlan)? {
        let settings = WorldGenerationSettings(preset: .flat, villageDensity: density)
        guard let village = STRUCTURES.first(where: { $0.id == "village" }) else {
            XCTFail("village structure must be registered")
            return nil
        }
        guard let context = structurePlanningContext(seed: seed, dim: .overworld,
                                                     settings: settings) else {
            XCTFail("flat worlds must expose their production planning context")
            return nil
        }
        guard let placement = village.placement(context) else {
            XCTFail("active village density must expose a placement lattice")
            return nil
        }
        for regionZ in -4...4 {
            for regionX in -4...4 {
                let origin = structureOriginFor(village, placement: placement,
                                                 seed: seed, regionX: regionX, regionZ: regionZ)
                if let plan = getPlan(village, context, origin.0, origin.1) {
                    return (settings, plan)
                }
            }
        }
        XCTFail("flat plains must admit at least one nearby \(density.displayName) village")
        return nil
    }

    func testFlatGenerationIgnoresDisabledForeignLandmarksWhenPlanningVillages() throws {
        let settings = WorldGenerationSettings(preset: .flat, villageDensity: .max)
        let village = try XCTUnwrap(STRUCTURES.first { $0.id == "village" })
        let active = try XCTUnwrap(structurePlanningContext(seed: seed, dim: .overworld,
                                                            settings: settings))
        XCTAssertEqual(active.activeStructureDefinitions?.map(\.id).sorted(),
                       ["stronghold", "village"],
                       "flat planning must use exactly the structures its generator emits")
        let placement = try XCTUnwrap(village.placement(active))

        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        for regionZ in -4...4 {
            for regionX in -4...4 {
                let origin = structureOriginFor(village, placement: placement,
                                                 seed: seed, regionX: regionX, regionZ: regionZ)
                guard let activePlan = getPlan(village, active, origin.0, origin.1),
                      let ref = activePlan.ref,
                      let minX = activePlan.pieces.map(\.x0).min(),
                      let maxX = activePlan.pieces.map(\.x1).max(),
                      let minZ = activePlan.pieces.map(\.z0).min(),
                      let maxZ = activePlan.pieces.map(\.z1).max() else { continue }

                // The compact-village fallback can safely choose a smaller
                // footprint instead of recreating the old all-registry veto.
                // Prove the active-domain rule directly: this synthetic
                // desert temple overlaps every candidate footprint for this
                // village origin, but flat generation excludes it because it
                // cannot materialize in a flat world.
                let disabledLandmark = StructureDef(
                    id: "desert_temple", spacing: 1, separation: 0,
                    salt: 0xD15A_B1ED, maxRadiusChunks: 16,
                    check: { _, candidateX, candidateZ, _ in
                        candidateX == origin.0 && candidateZ == origin.1
                    },
                    plan: { _, _, _, _ in
                        StructurePlan(id: "desert_temple", pieces: [
                            piece(minX - 256, GEN_MIN_Y, minZ - 256,
                                  maxX + 256, GEN_MIN_Y + 1, maxZ + 256) { _ in }
                        ])
                    }
                )
                let blockedDomain = GenCtx(
                    seed: seed,
                    heightAt: { _, _ in GEN_MIN_Y + 4 },
                    biomeAt: { _, _ in Biome.plains.rawValue },
                    dim: Dim.overworld.rawValue,
                    villageDensity: .max,
                    generationSettingsIdentity: settings.cacheIdentity + ".disabled-foreign-fixture",
                    baseTerrainOracleVersion: baseTerrainOracleVersion,
                    terrainOracle: BaseTerrainOracle(seed: seed, settings: settings,
                                                     maxCachedChunks: 128, maxQueries: 500_000),
                    activeStructureDefinitions: [disabledLandmark]
                )
                XCTAssertNil(getPlan(village, blockedDomain, origin.0, origin.1),
                                 "an actually active foreign landmark must still veto every overlapping village footprint")
                let centerChunkX = floorDiv((ref.x0 + ref.x1) / 2, CHUNK_W)
                let centerChunkZ = floorDiv((ref.z0 + ref.z1) / 2, CHUNK_W)
                let output = generateChunk(.overworld, seed, centerChunkX, centerChunkZ,
                                           settings: settings)
                XCTAssertTrue(output.structRefs.contains { $0.id == "village" },
                              "the actual flat generator must emit a village despite disabled foreign landmarks")
                return
            }
        }
        XCTFail("fixture must find a terrain-valid flat village in the active generation domain")
    }

    /// Uses the actual desert terrain/oracle path so the assertions below
    /// cover structure replay, feature protection, and entity publication—not
    /// merely the village closure in isolation.
    private func desertVillagePlan() -> (WorldGenerationSettings, StructurePlan)? {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface,
                                               singleBiome: .desert,
                                               villageDensity: .max)
        guard let village = STRUCTURES.first(where: { $0.id == "village" }) else {
            XCTFail("village structure must be registered")
            return nil
        }
        let generator = overworldGen(seed, settings: settings)
        let oracle = BaseTerrainOracle(seed: seed, settings: settings,
                                       maxCachedChunks: 512, maxQueries: 1_000_000)
        let context = GenCtx(
            seed: seed,
            heightAt: { x, z in generator.refinedHeightEstimate(Double(x), Double(z)) },
            biomeAt: { x, z in generator.surfaceBiomeAt(Double(x), Double(z)).rawValue },
            dim: Dim.overworld.rawValue,
            villageDensity: .max,
            generationSettingsIdentity: settings.cacheIdentity,
            baseTerrainOracleVersion: baseTerrainOracleVersion,
            terrainOracle: oracle
        )
        guard let plan = getPlan(village, context, desertCamelPenOrigin.x, desertCamelPenOrigin.z) else {
            XCTFail("reviewed desert Max fixture must retain its accepted village")
            return nil
        }
        return (settings, plan)
    }

    private func generatedCell(_ x: Int, _ y: Int, _ z: Int,
                               outputs: [String: GenOutput]) -> Int {
        guard y >= GEN_MIN_Y, y < GEN_MIN_Y + WORLD_H else { return -1 }
        let cx = floorDiv(x, CHUNK_W), cz = floorDiv(z, CHUNK_W)
        guard let output = outputs["\(cx),\(cz)"] else { return -1 }
        let lx = x - cx * CHUNK_W, lz = z - cz * CHUNK_W
        return Int(output.blocks[((y - GEN_MIN_Y) * CHUNK_W + lz) * CHUNK_W + lx])
    }

    private func emittedChunks(for piece: StructPiece,
                               settings: WorldGenerationSettings) -> [String: GenOutput] {
        var outputs: [String: GenOutput] = [:]
        for cz in floorDiv(piece.z0, CHUNK_W)...floorDiv(piece.z1, CHUNK_W) {
            for cx in floorDiv(piece.x0, CHUNK_W)...floorDiv(piece.x1, CHUNK_W) {
                outputs["\(cx),\(cz)"] = generateChunk(.overworld, seed, cx, cz, settings: settings)
            }
        }
        return outputs
    }

    func testFlatVillagesHonorEveryActiveDensityAndPublishResidents() throws {
        guard let (_, fewPlan) = firstFlatVillagePlan(density: .few),
              let fewRef = fewPlan.ref else {
            return
        }
        let centerX = (fewRef.x0 + fewRef.x1) / 2
        let centerZ = (fewRef.z0 + fewRef.z1) / 2
        let centerCX = floorDiv(centerX, CHUNK_W)
        let centerCZ = floorDiv(centerZ, CHUNK_W)

        for density in [VillageDensity.few, .normal, .many, .max] {
            let settings = WorldGenerationSettings(preset: .flat, villageDensity: density)
            let output = generateChunk(.overworld, seed, centerCX, centerCZ, settings: settings)
            XCTAssertTrue(output.structRefs.contains { $0.id == "village" },
                          "\(density.displayName) must materialize a flat-world village")
            XCTAssertTrue(output.entities.contains { $0.mob == "iron_golem" },
                          "village residents must survive the flat generation output path")
        }

        let disabled = generateChunk(.overworld, seed, centerCX, centerCZ,
                                     settings: WorldGenerationSettings(preset: .flat, villageDensity: .none))
        XCTAssertFalse(disabled.structRefs.contains { $0.id == "village" },
                       "None must disable flat-world village placement")
    }

    func testFlatWorldRetainsStrongholdsWhenVillagesAreDisabled() throws {
        let stronghold = try XCTUnwrap(strongholdPositions(seed).first)
        let output = generateChunk(
            .overworld,
            seed,
            stronghold.0,
            stronghold.1,
            settings: WorldGenerationSettings(preset: .flat, villageDensity: .none)
        )
        XCTAssertTrue(output.structRefs.contains { $0.id == "stronghold" },
                      "flat generation must retain its existing stronghold behavior")
        XCTAssertFalse(output.structRefs.contains { $0.id == "village" })
    }

    func testDesertVillagePenEmitsCamelSafeRailsAndGateLintel() throws {
        guard let (settings, plan) = desertVillagePlan() else { return }
        // The livestock pen is the only 7×7, nine-block-tall village piece.
        // Locate it from the accepted plan only to bound normal chunk replay;
        // every assertion below reads emitted GenOutput rather than invoking a
        // piece directly.
        let penPieces = plan.pieces.filter {
            $0.x1 - $0.x0 == 6 && $0.z1 - $0.z0 == 6 && $0.y1 - $0.y0 == 9
        }
        XCTAssertEqual(penPieces.count, 1, "village must publish one bounded livestock pen piece")
        let pen = try XCTUnwrap(penPieces.first)
        let outputs = emittedChunks(for: pen, settings: settings)

        let camels = outputs.values.flatMap(\.entities).filter {
            $0.mob == "camel" && $0.data["persistent"] == .bool(true)
        }
        XCTAssertEqual(camels.count, 1, "desert livestock pen must publish one persistent camel")
        let camel = try XCTUnwrap(camels.first)
        let camelX = Int(camel.x.rounded(.down))
        let camelY = Int(camel.y.rounded(.down))
        let camelZ = Int(camel.z.rounded(.down))
        XCTAssertTrue((pen.x0 + 1...pen.x1 - 1).contains(camelX))
        XCTAssertTrue((pen.z0 + 1...pen.z1 - 1).contains(camelZ))
        XCTAssertTrue(SOLID[generatedCell(camelX, camelY - 1, camelZ, outputs: outputs) >> 4] == 1,
                      "emitted camel must have dry structural footing")
        for dy in 0...2 {
            XCTAssertEqual(generatedCell(camelX, camelY + dy, camelZ, outputs: outputs), 0,
                           "emitted camel must retain clear headroom at height \(dy)")
        }

        func blockName(_ value: Int) -> String {
            guard value >= 0 else { return "outside" }
            let id = value >> 4
            return blockDefs.indices.contains(id) ? blockDefs[id].name : "invalid"
        }
        func isRail(_ value: Int) -> Bool {
            guard value >= 0 else { return false }
            let id = value >> 4
            guard blockDefs.indices.contains(id) else { return false }
            return blockDefs[id].shape == .fence || blockDefs[id].shape == .wall
        }
        func isFenceGate(_ value: Int) -> Bool { blockName(value).hasSuffix("_fence_gate") }

        // The gate faces north at the pen's centre. Every other perimeter
        // column has a second rail; the openable gate receives a high lintel
        // so an opened gate cannot become a camel escape route.
        for dz in 0...6 {
            for dx in 0...6 where dx == 0 || dx == 6 || dz == 0 || dz == 6 {
                let x = pen.x0 + dx, z = pen.z0 + dz
                if dx == 3 && dz == 0 {
                    XCTAssertTrue(isFenceGate(generatedCell(x, camelY, z, outputs: outputs)),
                                  "pen must expose its interactive centre gate")
                    XCTAssertEqual(generatedCell(x, camelY + 1, z, outputs: outputs), 0,
                                   "gate must retain pedestrian clearance")
                    XCTAssertTrue(isRail(generatedCell(x, camelY + 2, z, outputs: outputs)),
                                  "gate must have a camel-containment lintel")
                } else {
                    XCTAssertTrue(isRail(generatedCell(x, camelY, z, outputs: outputs)),
                                  "pen perimeter must have a lower rail")
                    XCTAssertTrue(isRail(generatedCell(x, camelY + 1, z, outputs: outputs)),
                                  "pen perimeter must have a camel-safe raised rail")
                }
            }
        }
    }

}
