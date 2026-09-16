import XCTest
@testable import ElysiumCore

final class SurfaceStructureGenerationTests: XCTestCase {
    private let seed: UInt32 = 0x51A7_C0DE

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
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

    private func firstSurfacePlan(_ id: String, settings: WorldGenerationSettings,
                                  regions: ClosedRange<Int> = -6...6) -> StructurePlan? {
        guard let def = STRUCTURES.first(where: { $0.id == id }) else {
            XCTFail("\(id) must be registered")
            return nil
        }
        let generator = overworldGen(seed, settings: settings)
        let context = GenCtx(
            seed: seed,
            heightAt: { x, z in generator.refinedHeightEstimate(Double(x), Double(z)) },
            biomeAt: { x, z in generator.surfaceBiomeAt(Double(x), Double(z)).rawValue },
            dim: Dim.overworld.rawValue,
            villageDensity: settings.villageDensity,
            generationSettingsIdentity: settings.cacheIdentity,
            baseTerrainOracleVersion: baseTerrainOracleVersion,
            terrainOracle: BaseTerrainOracle(seed: seed, settings: settings,
                                              maxCachedChunks: 512, maxQueries: 1_000_000)
        )
        guard let placement = def.placement(context) else {
            XCTFail("\(id) must expose an active placement lattice")
            return nil
        }
        for regionZ in regions {
            for regionX in regions {
                let origin = structureOriginFor(def, placement: placement,
                                                 seed: seed, regionX: regionX, regionZ: regionZ)
                if let plan = getPlan(def, context, origin.0, origin.1) { return plan }
            }
        }
        XCTFail("expected an accepted \(id) plan in reviewed fixed scan")
        return nil
    }

    private func surfaceOutpostWithCage() -> (StructurePlan, [String: GenOutput])? {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface,
                                               singleBiome: .plains,
                                               villageDensity: .none)
        guard let outpost = STRUCTURES.first(where: { $0.id == "pillager_outpost" }) else {
            XCTFail("pillager outpost must be registered")
            return nil
        }
        let generator = overworldGen(seed, settings: settings)
        let oracle = BaseTerrainOracle(seed: seed, settings: settings,
                                       maxCachedChunks: 512, maxQueries: 1_000_000)
        let context = GenCtx(seed: seed,
                             heightAt: { x, z in generator.refinedHeightEstimate(Double(x), Double(z)) },
                             biomeAt: { x, z in generator.surfaceBiomeAt(Double(x), Double(z)).rawValue },
                             dim: Dim.overworld.rawValue,
                             villageDensity: .none,
                             generationSettingsIdentity: settings.cacheIdentity,
                             baseTerrainOracleVersion: baseTerrainOracleVersion,
                             terrainOracle: oracle)
        guard let placement = outpost.placement(context) else {
            XCTFail("pillager outpost must expose a placement lattice")
            return nil
        }
        for regionZ in -4...4 {
            for regionX in -4...4 {
                let origin = structureOriginFor(outpost, placement: placement,
                                                 seed: seed, regionX: regionX, regionZ: regionZ)
                guard let plan = getPlan(outpost, context, origin.0, origin.1),
                      let piece = plan.pieces.first else {
                    continue
                }
                let outputs = emittedChunks(for: piece, settings: settings)
                let x = piece.x0 + 6, y = piece.y0 + 6, z = piece.z0 + 6
                if outputs.values.contains(where: { output in
                    output.entities.contains(where: {
                        $0.mob == "iron_golem"
                            && $0.x == Double(x + 12) + 0.5
                            && $0.y == Double(y + 1)
                            && $0.z == Double(z + 3) + 0.5
                    })
                }) {
                    return (plan, outputs)
                }
            }
        }
        XCTFail("deterministic surface fixture must include a caged outpost golem")
        return nil
    }

    func testOutpostGuardAndCagedGolemHaveFootingAndClearance() throws {
        guard let (plan, outputs) = surfaceOutpostWithCage(), let piece = plan.pieces.first else { return }
        let x = piece.x0 + 6, y = piece.y0 + 6, z = piece.z0 + 6

        let entities = outputs.values.flatMap(\.entities)
        let entitySummary = entities.map { "\($0.mob)@\($0.x),\($0.y),\($0.z)" }.joined(separator: "; ")
        guard let indoorGuard = entities.first(where: {
            $0.mob == "pillager"
                && $0.x == Double(x + 2) + 0.5
                && $0.y == Double(y + 1)
                && $0.z == Double(z + 3) + 0.5
        }) else {
            return XCTFail("expected indoor guard at \(x + 2),\(y + 1),\(z + 3); piece=\(piece.x0),\(piece.y0),\(piece.z0); entities=\(entitySummary)")
        }
        let guardX = Int(indoorGuard.x.rounded(.down))
        let guardY = Int(indoorGuard.y.rounded(.down))
        let guardZ = Int(indoorGuard.z.rounded(.down))
        XCTAssertTrue(isFullSolid(generatedCell(guardX, guardY - 1, guardZ, outputs: outputs)),
                      "indoor outpost guard must stand on the lower-room floor")
        XCTAssertEqual(generatedCell(guardX, guardY, guardZ, outputs: outputs), 0)
        XCTAssertEqual(generatedCell(guardX, guardY + 1, guardZ, outputs: outputs), 0)

        let gx = x + 11, gy = y, gz = z + 2
        let golem = try XCTUnwrap(entities.first {
            $0.mob == "iron_golem"
                && $0.x == Double(gx + 1) + 0.5
                && $0.y == Double(gy + 1)
                && $0.z == Double(gz + 1) + 0.5
        })
        let golemX = Int(golem.x.rounded(.down))
        let golemY = Int(golem.y.rounded(.down))
        let golemZ = Int(golem.z.rounded(.down))
        XCTAssertTrue(isFullSolid(generatedCell(golemX, golemY - 1, golemZ, outputs: outputs)),
                      "caged golem must have a full-cube floor rather than a fence collision shape")
        for dy in 0...2 {
            XCTAssertEqual(generatedCell(golemX, golemY + dy, golemZ, outputs: outputs), 0,
                           "caged golem must retain clear headroom at height \(dy)")
        }
        XCTAssertTrue(isFullSolid(generatedCell(golemX, gy + 4, golemZ, outputs: outputs)),
                      "caged golem must have a roof above its three clear interior cells")

        let outpostDoor = bid("dark_oak_door")
        let outpostStair = Int(cell(B.dark_oak_stairs, FACE_OPP[0]))
        for dx in 3...4 {
            XCTAssertEqual(generatedCell(x + dx, y + 1, z, outputs: outputs), Int(cell(outpostDoor, 0)),
                           "tower entry needs a real lower door half over the retained floor")
            XCTAssertEqual(generatedCell(x + dx, y + 2, z, outputs: outputs), Int(cell(outpostDoor, dx == 3 ? 9 : 8)),
                           "tower entry needs the matching upper door half")
            XCTAssertEqual(generatedCell(x + dx, y, z - 1, outputs: outputs), outpostStair,
                           "the exterior step must rise into the elevated tower floor")
            XCTAssertTrue(isFullSolid(generatedCell(x + dx, y - 1, z - 1, outputs: outputs)),
                          "every exterior tower stair needs a grounded support")
            XCTAssertEqual(generatedCell(x + dx, y + 1, z - 1, outputs: outputs), 0)
            XCTAssertEqual(generatedCell(x + dx, y + 2, z - 1, outputs: outputs), 0)
            XCTAssertEqual(generatedCell(x + dx, y + 1, z + 1, outputs: outputs), 0,
                           "the open interior behind the door completes the walkable entry")
        }
        for h in 0..<14 {
            XCTAssertEqual(generatedCell(x + 1, y + h, z + 2, outputs: outputs), Int(cell(B.ladder, 5)),
                           "every ladder rung must retain its north-facing mount")
            XCTAssertTrue(isFullSolid(generatedCell(x + 1, y + h, z + 1, outputs: outputs)),
                          "every ladder rung must have the continuous backing post that its mount requires")
        }
    }

    func testJungleTempleHasGroundedDoorAndVestibule() throws {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface,
                                               singleBiome: .jungle,
                                               villageDensity: .none)
        resetStructurePlanCacheForTesting()
        let plan = try XCTUnwrap(firstSurfacePlan("jungle_temple", settings: settings))
        let piece = try XCTUnwrap(plan.pieces.first)
        let outputs = emittedChunks(for: piece, settings: settings)
        // The piece intentionally reaches two cells north of the temple for
        // its landing, so recover the original structure anchor from it.
        let x = piece.x0 + 1, y = piece.y0 + 6, z = piece.z0 + 2
        let door = bid("jungle_door")
        let stair = Int(cell(B.cobblestone_stairs, FACE_OPP[0]))
        for dx in 5...6 {
            XCTAssertEqual(generatedCell(x + dx, y + 1, z, outputs: outputs), Int(cell(door, 0)),
                           "temple vestibule needs a real lower door half")
            XCTAssertEqual(generatedCell(x + dx, y + 2, z, outputs: outputs), Int(cell(door, dx == 5 ? 9 : 8)),
                           "temple vestibule needs its matching upper door half")
            XCTAssertEqual(generatedCell(x + dx, y, z - 1, outputs: outputs), stair,
                           "the threshold stair must lead to the lower room floor")
            XCTAssertTrue(isFullSolid(generatedCell(x + dx, y - 1, z - 1, outputs: outputs)),
                          "the temple stair must have a complete foundation")
            XCTAssertEqual(generatedCell(x + dx, y - 1, z - 2, outputs: outputs), Int(cell(B.dirt_path)),
                           "the stair must begin from an explicit exterior landing")
            XCTAssertEqual(generatedCell(x + dx, y + 1, z - 1, outputs: outputs), 0)
            XCTAssertEqual(generatedCell(x + dx, y + 2, z - 1, outputs: outputs), 0)
            XCTAssertEqual(generatedCell(x + dx, y + 1, z + 1, outputs: outputs), 0,
                           "the interior behind the door must stay clear into the temple")
        }
        for i in 0..<4 {
            let stairY = y + 4 - i, stairZ = z + 4 + i
            for dx in 5...6 {
                XCTAssertEqual(generatedCell(x + dx, stairY, stairZ, outputs: outputs),
                               Int(cell(B.cobblestone_stairs, 0)),
                               "the interior flight must face north so each ascent meets the preceding step")
                for fillY in y..<stairY {
                    XCTAssertTrue(isFullSolid(generatedCell(x + dx, fillY, stairZ, outputs: outputs)),
                                  "the interior flight needs a continuous grounded wedge below every riser")
                }
            }
        }
    }

    func testIglooCenterEntryIsSupportedNorthFacingRamp() throws {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface,
                                               singleBiome: .snowyPlains,
                                               villageDensity: .none)
        resetStructurePlanCacheForTesting()
        let plan = try XCTUnwrap(firstSurfacePlan("igloo", settings: settings))
        let piece = try XCTUnwrap(plan.pieces.first)
        let outputs = emittedChunks(for: piece, settings: settings)
        // Igloo's materialization box begins one west/north and 24 below its
        // original anchor so it can contain the optional basement shaft.
        let x = piece.x0 + 1, y = piece.y0 + 24, z = piece.z0 + 1

        XCTAssertEqual(generatedCell(x + 3, y, z + 6, outputs: outputs),
                       Int(cell(B.stone_brick_stairs, 0)),
                       "the center tunnel must use a north-facing ascent into the dome")
        XCTAssertTrue(isFullSolid(generatedCell(x + 3, y - 1, z + 6, outputs: outputs)),
                      "the entry ramp must sit directly on its center foundation")

        // This is the explicit player route: tunnel floor at y - 1 -> low
        // side of the ramp -> north high side adjacent to the dome landing at
        // y.  All three feet/head spaces remain clear after materialization.
        for tunnelZ in 7...9 {
            XCTAssertTrue(isFullSolid(generatedCell(x + 3, y - 1, z + tunnelZ, outputs: outputs)),
                          "the south tunnel route must retain a grounded center floor")
            XCTAssertEqual(generatedCell(x + 3, y + 1, z + tunnelZ, outputs: outputs), 0)
            XCTAssertEqual(generatedCell(x + 3, y + 2, z + tunnelZ, outputs: outputs), 0)
        }
        XCTAssertTrue(isFullSolid(generatedCell(x + 3, y, z + 5, outputs: outputs)),
                      "the ramp's north high side must meet the dome landing")
        XCTAssertEqual(generatedCell(x + 3, y + 1, z + 5, outputs: outputs), 0)
        XCTAssertEqual(generatedCell(x + 3, y + 2, z + 5, outputs: outputs), 0)
        XCTAssertEqual(generatedCell(x + 3, y + 1, z + 6, outputs: outputs), 0)
        XCTAssertEqual(generatedCell(x + 3, y + 2, z + 6, outputs: outputs), 0)
    }
}
