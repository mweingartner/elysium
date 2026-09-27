import XCTest
@testable import ElysiumCore

final class PrehistoricVolcanoTests: XCTestCase {
    private let seed: UInt32 = 0x51_E1_5A

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    private func plan(x: Int = -3, z: Int = 15,
                      surfaceAt: ((Int, Int) -> ExactTerrainSurface?)? = nil,
                      cellAt: ((Int, Int, Int) -> Int?)? = nil) -> StructurePlan? {
        planPrehistoricVolcano(seed: seed, x: x, z: z, radius: 12, height: 10, craterRadius: 3,
                               surfaceAt: surfaceAt ?? { _, _ in ExactTerrainSurface(feetY: 72, isDry: true) },
                               cellAt: cellAt ?? { _, _, _ in Int(cell(B.stone)) })
    }

    private func materialize(_ plan: StructurePlan, reversed: Bool = false) -> [String: ArraySink] {
        guard let piece = plan.pieces.first else { return [:] }
        var coordinates: [(Int, Int)] = []
        for cz in floorDiv(piece.z0, CHUNK_W)...floorDiv(piece.z1, CHUNK_W) {
            for cx in floorDiv(piece.x0, CHUNK_W)...floorDiv(piece.x1, CHUNK_W) {
                coordinates.append((cx, cz))
            }
        }
        if reversed { coordinates.reverse() }
        var result: [String: ArraySink] = [:]
        for (cx, cz) in coordinates {
            let sink = ArraySink(cx: cx, cz: cz,
                                 blocks: [UInt16](repeating: 0, count: CHUNK_W * CHUNK_W * WORLD_H),
                                 minY: GEN_MIN_Y, maxY: GEN_MIN_Y + WORLD_H,
                                 heightFallback: { _, _ in 72 })
            for piece in plan.pieces { piece.build(Builder(sink, Rng(seed))) }
            result["\(cx),\(cz)"] = sink
        }
        return result
    }

    private func value(_ x: Int, _ y: Int, _ z: Int, in chunks: [String: ArraySink]) -> Int {
        chunks["\(floorDiv(x, CHUNK_W)),\(floorDiv(z, CHUNK_W))"]?.get(x, y, z) ?? -1
    }

    func testConeReplaysAcrossNegativeChunkSeamsAndContainsEveryLavaCell() throws {
        let plan = try XCTUnwrap(plan())
        let forward = materialize(plan)
        let reverse = materialize(plan, reversed: true)
        XCTAssertEqual(forward.mapValues(\.blocks), reverse.mapValues(\.blocks))
        let lavaY = 79
        var lavaCount = 0
        for z in 3...27 { for x in -15...9 {
            for y in 71...82 {
                let c = value(x, y, z, in: forward)
                guard c >> 4 == Int(B.lava) else { continue }
                lavaCount += 1
                XCTAssertEqual(y, lavaY)
                XCTAssertLessThanOrEqual((x + 3) * (x + 3) + (z - 15) * (z - 15), 9)
                XCTAssertEqual(value(x, y - 1, z, in: forward) >> 4, Int(B.basalt))
                XCTAssertEqual(value(x, y + 1, z, in: forward), 0)
                for (dx, dz) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let neighbor = value(x + dx, y, z + dz, in: forward)
                    XCTAssertTrue(neighbor >> 4 == Int(B.lava)
                                    || (neighbor > 0 && SOLID[neighbor >> 4] == 1),
                                  "the source pool cannot have an open side")
                }
            }
        } }
        XCTAssertEqual(lavaCount, 29)
        XCTAssertTrue(forward.values.allSatisfy { $0.naturalTreeCells.isEmpty })
    }

    func testWetSteepUnsupportedAndUnavailableTerrainRejectBeforeEmission() {
        XCTAssertNil(plan(surfaceAt: { x, _ in ExactTerrainSurface(feetY: 72, isDry: x != -3) }))
        XCTAssertNil(plan(surfaceAt: { x, _ in ExactTerrainSurface(feetY: x < -3 ? 72 : 79, isDry: true) }))
        XCTAssertNil(plan(surfaceAt: { _, _ in nil }))
        XCTAssertNil(plan(cellAt: { _, y, _ in y == 69 ? 0 : Int(cell(B.stone)) }))
        XCTAssertNil(plan(surfaceAt: { _, _ in ExactTerrainSurface(feetY: 62, isDry: true) }))
    }

    func testEntireStarterGroveAndDryApproachAreExcluded() {
        let shelter = PrehistoricStarterShelterSite(spawn: .init(x: 8, y: 72, z: -104),
                                                   usesRaisedPlatform: false)
        XCTAssertFalse(prehistoricVolcanoAvoidsShelter(x: 8, z: -104, radius: 12, shelter: shelter))
        XCTAssertFalse(prehistoricVolcanoAvoidsShelter(x: 48, z: -104, radius: 12, shelter: shelter))
        XCTAssertTrue(prehistoricVolcanoAvoidsShelter(x: 49, z: -104, radius: 12, shelter: shelter))
        let settings = WorldGenerationSettings(preset: .prehistoricLostWorldV3)
        let actualShelter = prehistoricStarterShelterSite(seed: seed, settings: settings)
        XCTAssertNotNil(actualShelter)
        if let actualShelter {
            let context = structurePlanningContext(seed: seed, dim: .overworld, settings: settings)!
            let def = prehistoricVolcanoStructureDefinition()
            XCTAssertNil(getPlan(def, context, floorDiv(actualShelter.x, CHUNK_W),
                                 floorDiv(actualShelter.z, CHUNK_W)))
        }
    }

    func testOnlyCurrentOverworldProfilesAdmitVolcanoes() throws {
        let def = prehistoricVolcanoStructureDefinition()
        for preset in WorldPreset.allCases {
            let settings = WorldGenerationSettings(preset: preset)
            let enabled = structureDefinitionsForGeneration(dim: .overworld, settings: settings)
                .contains { $0.id == prehistoricVolcanoStructureID }
            XCTAssertEqual(enabled, preset.supportsVolcanicTerrain, "\(preset)")
            if let context = structurePlanningContext(seed: seed, dim: .overworld, settings: settings) {
                XCTAssertEqual(def.placement(context) != nil, preset.supportsVolcanicTerrain)
            }
            for dimension in [Dim.nether, .end] {
                XCTAssertFalse(structureDefinitionsForGeneration(dim: dimension, settings: settings)
                    .contains { $0.id == prehistoricVolcanoStructureID })
            }
        }
    }

    func testExistingStructuresWinAndRejectedVolcanoReservesNoTrees() throws {
        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        let rawPlan = try XCTUnwrap(plan(x: 8, z: 8))
        let volcano = StructureDef(id: prehistoricVolcanoStructureID, spacing: 1, separation: 0,
                                   salt: 123, maxRadiusChunks: 2,
                                   check: { _, x, z, _ in x == 0 && z == 0 },
                                   plan: { _, _, _, _ in rawPlan })
        // Trail ruins deliberately do not belong to the conventional-surface
        // resolver. Their emitted piece, rather than a broad runtime ref,
        // must still veto a volcano that would erase this chest.
        let ruin = StructureDef(id: "trail_ruins", spacing: 1, separation: 0,
                                salt: 456, maxRadiusChunks: 1,
                                check: { _, x, z, _ in x == 0 && z == 0 },
                                plan: { _, _, _, _ in
                                    StructurePlan(id: "trail_ruins", pieces: [
                                        piece(7, 73, 7, 9, 73, 9) { b in
                                            b.chest(8, 73, 8, 0, "simple_dungeon")
                                        },
                                    ], ref: StructRefBox(1_000, 0, 1_000, 1_001, 1, 1_001))
                                })
        let context = GenCtx(seed: seed, heightAt: { _, _ in 72 },
                             biomeAt: { _, _ in Biome.plains.rawValue }, dim: Dim.overworld.rawValue,
                             generationSettingsIdentity: "volcano-collision-test",
                             activeStructureDefinitions: [volcano, ruin])
        XCTAssertFalse(surfaceStructurePlanWins(volcano, rawPlan, context, 0, 0,
                                                collisionDefinitions: [volcano, ruin]))
        XCTAssertTrue(treeCanopyExclusions(forOriginChunk: 0, 0, context: context,
                                            structures: [volcano],
                                            collisionDefinitions: [ruin, volcano]).isEmpty)
        let sink = ArraySink(cx: 0, cz: 0,
                             blocks: [UInt16](repeating: 0, count: CHUNK_W * CHUNK_W * WORLD_H),
                             minY: GEN_MIN_Y, maxY: GEN_MIN_Y + WORLD_H,
                             heightFallback: { _, _ in 72 })
        _ = buildStructuresForChunk(context, 0, 0, sink, [ruin, volcano])
        XCTAssertEqual(sink.get(8, 73, 8) >> 4, Int(B.chest))
        XCTAssertEqual(sink.blockEntities.count, 1)
        XCTAssertFalse(sink.blocks.contains { $0 >> 4 == B.lava })
        XCTAssertFalse(treeCanopyExclusions(forOriginChunk: 0, 0, context: context,
                                             structures: [volcano], collisionDefinitions: [volcano]).isEmpty)
    }

    func testStrongholdAdmissionUsesOnlyRealRingOriginsWithoutFlushingPlanCache() throws {
        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        let stronghold = try XCTUnwrap(STRUCTURES.first { $0.id == "stronghold" })
        let context = GenCtx(seed: seed, heightAt: { _, _ in 72 },
                             biomeAt: { _, _ in Biome.plains.rawValue }, dim: Dim.overworld.rawValue,
                             generationSettingsIdentity: "volcano-stronghold-bound-test",
                             activeStructureDefinitions: [stronghold])
        let placement = try XCTUnwrap(stronghold.placement(context))
        let nearSpawn = try XCTUnwrap(plan(x: 8, z: 8))
        XCTAssertTrue(prehistoricVolcanoPlanWins(nearSpawn, context, collisionDefinitions: [stronghold]))
        XCTAssertEqual(structurePlanCacheStatsForTesting().computations, 0,
                       "empty spacing-one coordinates must never enter the plan cache")

        let ring = strongholdPositions(seed)
        let first = try XCTUnwrap(ring.first)
        let atStronghold = try XCTUnwrap(plan(x: first.0 * CHUNK_W + 8, z: first.1 * CHUNK_W + 8))
        let origins = prehistoricVolcanoCollisionOrigins(for: stronghold, placement: placement,
                                                          seed: seed, piece: atStronghold.pieces[0])
        XCTAssertEqual(origins.count, 1)
        XCTAssertEqual(origins.first?.0, first.0)
        XCTAssertEqual(origins.first?.1, first.1)
    }

    func testVersionThreeSitingIsFrozenWhileVersionFourIsDenser() throws {
        let v3 = try XCTUnwrap(PrehistoricVolcanoSiting.forPreset(.prehistoricLostWorldV3))
        XCTAssertEqual(v3.placement, StructurePlacement(spacing: 24, separation: 8))
        XCTAssertEqual(v3.siteOffsets.map { [$0.x, $0.z] }, [[0, 0]])
        XCTAssertEqual(v3.maxRelief, 6)
        let v4 = try XCTUnwrap(PrehistoricVolcanoSiting.forPreset(.prehistoricLostWorldV4))
        XCTAssertEqual(v4.placement, StructurePlacement(spacing: 12, separation: 4))
        XCTAssertEqual(v4.siteOffsets.first.map { [$0.x, $0.z] }, [0, 0], "the centred site is tried first")
        XCTAssertEqual(v4.maxRelief, 8)
        XCTAssertNil(PrehistoricVolcanoSiting.forPreset(.prehistoricLostWorldV2))
        XCTAssertNil(PrehistoricVolcanoSiting.forPreset(.normal))

        // Every nearby site keeps the widest cone inside the two-chunk structure radius.
        let def = prehistoricVolcanoStructureDefinition()
        for offset in v4.siteOffsets {
            for edge in [-14, 14] {
                let x = CHUNK_W / 2 + offset.x + edge, z = CHUNK_W / 2 + offset.z + edge
                XCTAssertTrue((-def.maxRadiusChunks...def.maxRadiusChunks).contains(floorDiv(x, CHUNK_W)))
                XCTAssertTrue((-def.maxRadiusChunks...def.maxRadiusChunks).contains(floorDiv(z, CHUNK_W)))
            }
        }
        for preset in [WorldPreset.prehistoricLostWorldV3, .prehistoricAncientSeasV4] {
            let context = try XCTUnwrap(structurePlanningContext(seed: seed, dim: .overworld,
                                                                 settings: .init(preset: preset)))
            XCTAssertEqual(def.placement(context), PrehistoricVolcanoSiting.forPreset(preset)?.placement)
        }
    }

    func testReliefLimitAdmitsAGentleSlopeOnlyWhenTheSitingAllowsIt() {
        // Ground rises one block every three, an eight-block spread across the cone.
        let slope: (Int, Int) -> ExactTerrainSurface? = { x, _ in
            ExactTerrainSurface(feetY: 72 + floorDiv(x + 12, 3), isDry: true)
        }
        XCTAssertNil(planPrehistoricVolcano(seed: seed, x: 0, z: 0, radius: 12, height: 10, craterRadius: 3,
                                            surfaceAt: slope, cellAt: { _, _, _ in Int(cell(B.stone)) }),
                     "v3's six-block limit stays in force")
        XCTAssertNotNil(planPrehistoricVolcano(seed: seed, x: 0, z: 0, radius: 12, height: 10, craterRadius: 3,
                                               maxRelief: 8,
                                               surfaceAt: slope, cellAt: { _, _, _ in Int(cell(B.stone)) }))
    }

    func testVersionFourRaisesManyMoreSurfaceVolcanoesOverTheSameGround() throws {
        let def = prehistoricVolcanoStructureDefinition()
        let sampleSeed: UInt32 = 0x5EED_0002
        var admitted: [WorldPreset: [StructurePlan]] = [:]
        for preset in [WorldPreset.prehistoricLostWorldV3, .prehistoricLostWorldV4] {
            let context = try XCTUnwrap(structurePlanningContext(seed: sampleSeed, dim: .overworld,
                                                                 settings: .init(preset: preset)))
            let placement = try XCTUnwrap(def.placement(context))
            let regions = 96 / placement.spacing  // the same 96x96-chunk ground for both lattices
            var plans: [StructurePlan] = []
            for rz in 0..<regions { for rx in 0..<regions {
                let origin = structureOriginFor(def, placement: placement, seed: sampleSeed, regionX: rx, regionZ: rz)
                guard let plan = getPlan(def, context, origin.0, origin.1),
                      surfaceStructurePlanWins(def, plan, context, origin.0, origin.1,
                                               collisionDefinitions: context.activeStructureDefinitions ?? [])
                else { continue }
                plans.append(plan)
            } }
            admitted[preset] = plans
        }
        let v3Count = admitted[.prehistoricLostWorldV3]?.count ?? 0
        let v4Plans = admitted[.prehistoricLostWorldV4] ?? []
        XCTAssertGreaterThanOrEqual(v4Plans.count, 12, "v4 must admit plenty of surface volcanoes")
        XCTAssertGreaterThanOrEqual(v4Plans.count, 5 * max(v3Count, 1), "v3 \(v3Count), v4 \(v4Plans.count)")

        // A v4 volcano still materializes as a dry cone holding only its crater pool.
        let settings = WorldGenerationSettings(preset: .prehistoricLostWorldV4)
        let bounds = try XCTUnwrap(v4Plans.first?.ref)
        var lavaCount = 0
        for cz in floorDiv(bounds.z0, CHUNK_W)...floorDiv(bounds.z1, CHUNK_W) {
            for cx in floorDiv(bounds.x0, CHUNK_W)...floorDiv(bounds.x1, CHUNK_W) {
                let chunk = generateChunk(.overworld, sampleSeed, cx, cz, settings: settings)
                lavaCount += chunk.blocks.enumerated().filter { index, value in
                    let y = GEN_MIN_Y + index / (CHUNK_W * CHUNK_W)
                    let x = cx * CHUNK_W + index % CHUNK_W, z = cz * CHUNK_W + (index / CHUNK_W) % CHUNK_W
                    return y >= bounds.y0 && y <= bounds.y1 && x >= bounds.x0 && x <= bounds.x1
                        && z >= bounds.z0 && z <= bounds.z1 && value >> 4 == B.lava
                }.count
                XCTAssertTrue(chunk.structRefs.contains { $0.id == prehistoricVolcanoStructureID })
            }
        }
        XCTAssertTrue([13, 29].contains(lavaCount), "only the contained crater pool should hold surface lava")
    }

    func testProductionRegionEmitsACompleteDryVolcano() throws {
        let settings = WorldGenerationSettings(preset: .prehistoricLostWorldV3)
        let context = try XCTUnwrap(structurePlanningContext(seed: seed, dim: .overworld, settings: settings))
        let def = prehistoricVolcanoStructureDefinition()
        let placement = try XCTUnwrap(def.placement(context))
        var found: StructurePlan?
        search: for rz in -3...3 { for rx in -3...3 {
            let origin = structureOriginFor(def, placement: placement, seed: seed, regionX: rx, regionZ: rz)
            guard let plan = getPlan(def, context, origin.0, origin.1),
                  surfaceStructurePlanWins(def, plan, context, origin.0, origin.1,
                                           collisionDefinitions: context.activeStructureDefinitions ?? []) else { continue }
            found = plan
            print("VOLCANO_FIXTURE seed=\(seed) origin=\(origin.0),\(origin.1)")
            break search
        } }
        let plan = try XCTUnwrap(found, "the bounded production sample must contain a volcano")
        let bounds = try XCTUnwrap(plan.ref)
        var lavaCount = 0
        for cz in floorDiv(bounds.z0, CHUNK_W)...floorDiv(bounds.z1, CHUNK_W) {
            for cx in floorDiv(bounds.x0, CHUNK_W)...floorDiv(bounds.x1, CHUNK_W) {
                let chunk = generateChunk(.overworld, seed, cx, cz, settings: settings)
                lavaCount += chunk.blocks.enumerated().filter { index, value in
                    let y = GEN_MIN_Y + index / (CHUNK_W * CHUNK_W)
                    return y >= bounds.y0 && y <= bounds.y1 && value >> 4 == B.lava
                }.count
                XCTAssertTrue(chunk.naturalTreeCells.allSatisfy { chunk.blocks[$0.key] == $0.value.expected })
                XCTAssertTrue(chunk.structRefs.contains { $0.id == prehistoricVolcanoStructureID })
            }
        }
        XCTAssertTrue([13, 29].contains(lavaCount), "only the contained crater pool should hold surface lava")
    }
}
