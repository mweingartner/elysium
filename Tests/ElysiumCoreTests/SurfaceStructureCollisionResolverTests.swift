import XCTest
@testable import ElysiumCore

/// Regression coverage for the generic conventional-landmark resolver. These
/// use detached synthetic plans so they can force an overlap across chunk 0/1
/// without depending on a rare terrain/biome coincidence.
final class SurfaceStructureCollisionResolverTests: XCTestCase {
    private let seed: UInt32 = 0xC011_1DE
    private let y = 64

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    private func context() -> GenCtx {
        GenCtx(seed: seed,
               heightAt: { _, _ in 64 },
               biomeAt: { _, _ in Biome.plains.rawValue },
               dim: Dim.overworld.rawValue,
               generationSettingsIdentity: "surface-structure-collision-resolver",
               baseTerrainOracleVersion: baseTerrainOracleVersion)
    }

    private func emptySink(chunkX: Int) -> ArraySink {
        ArraySink(cx: chunkX, cz: 0,
                  blocks: [UInt16](repeating: 0, count: CHUNK_W * CHUNK_W * WORLD_H),
                  minY: GEN_MIN_Y, maxY: GEN_MIN_Y + WORLD_H,
                  heightFallback: { _, _ in self.y })
    }

    /// Materialize a two-chunk seam in the supplied order. Every sample is
    /// gathered from the emitted sink, not from the plan closure.
    private func emittedSeam(definitions: [StructureDef], chunkOrder: [Int]) -> [Int: Int] {
        let ctx = context()
        var cells: [Int: Int] = [:]
        for chunkX in chunkOrder {
            let sink = emptySink(chunkX: chunkX)
            _ = buildStructuresForChunk(ctx, chunkX, 0, sink, definitions)
            for x in (chunkX * CHUNK_W)...(chunkX * CHUNK_W + CHUNK_W - 1) {
                cells[x] = sink.get(x, y, 0)
            }
        }
        return cells
    }

    func testFixedPriorityUsesActualPiecesAndIsIndependentOfArrayAndChunkOrder() {
        let desertMarker = Int(cell(B.stone))
        let jungleMarker = Int(cell(B.dirt))
        func landmark(id: String, marker: Int, salt: UInt32, refX: Int) -> StructureDef {
            StructureDef(id: id, spacing: 1, separation: 0, salt: salt, maxRadiusChunks: 1,
                         check: { _, ocx, ocz, _ in ocx == 0 && ocz == 0 },
                         plan: { _, _, _, _ in
                             // These deliberately disjoint runtime refs prove
                             // that conflict selection follows emitted pieces,
                             // not reference boxes or an origin-radius guess.
                             StructurePlan(id: id, pieces: [
                                 piece(14, 64, 0, 17, 64, 0) { builder in
                                     builder.fill(14, 64, 0, 17, 64, 0, marker)
                                 },
                             ], ref: StructRefBox(refX, 64, 500, refX + 1, 65, 501))
                         })
        }
        let desert = landmark(id: "desert_temple", marker: desertMarker, salt: 0xD35E_27, refX: 1_000)
        let jungle = landmark(id: "jungle_temple", marker: jungleMarker, salt: 0xA11C_E, refX: -1_000)

        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        let forward = emittedSeam(definitions: [jungle, desert], chunkOrder: [0, 1])

        // Start from the opposite side of the seam and reverse the supplied
        // definitions. The same lower-priority jungle plan must be wholly
        // rejected rather than winning only in one target chunk.
        resetStructurePlanCacheForTesting()
        let reverse = emittedSeam(definitions: [desert, jungle], chunkOrder: [1, 0])
        XCTAssertEqual(forward, reverse)
        for x in 14...17 {
            XCTAssertEqual(forward[x], desertMarker, "priority winner must stamp seam cell x=\(x)")
        }
        XCTAssertFalse(forward.values.contains(jungleMarker),
                       "losing conventional plan must not stamp any target chunk")
    }

    func testSameClassOverlapUsesOriginTieBreakAcrossTheWholeSeam() {
        let lowerOriginMarker = Int(cell(B.cobblestone))
        let higherOriginMarker = Int(cell(B.dirt))
        let temples = StructureDef(
            id: "desert_temple", spacing: 1, separation: 0, salt: 0x71E_0FF,
            maxRadiusChunks: 1,
            check: { _, ocx, ocz, _ in ocz == 0 && (ocx == 0 || ocx == 1) },
            plan: { _, ocx, _, _ in
                let marker = ocx == 0 ? lowerOriginMarker : higherOriginMarker
                let startX = ocx == 0 ? 14 : 15
                return StructurePlan(id: "desert_temple", pieces: [
                    piece(startX, 64, 0, startX + 3, 64, 0) { builder in
                        builder.fill(startX, 64, 0, startX + 3, 64, 0, marker)
                    },
                ], ref: StructRefBox(10_000 + ocx, 64, 0, 10_000 + ocx, 64, 0))
            }
        )

        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        let first = emittedSeam(definitions: [temples], chunkOrder: [0, 1])
        resetStructurePlanCacheForTesting()
        let replay = emittedSeam(definitions: [temples], chunkOrder: [1, 0])

        XCTAssertEqual(first, replay)
        for x in 14...17 {
            XCTAssertEqual(first[x], lowerOriginMarker,
                           "lower origin must own every overlapping seam cell x=\(x)")
        }
        XCTAssertEqual(first[18], 0, "entire losing plan, including its non-overlap tail, must be skipped")
        XCTAssertFalse(first.values.contains(higherOriginMarker))
    }

    func testSuppressedConventionalPlanDoesNotReserveTreeCanopySpace() {
        func landmark(id: String, salt: UInt32, startX: Int) -> StructureDef {
            StructureDef(id: id, spacing: 1, separation: 0, salt: salt, maxRadiusChunks: 1,
                         check: { _, ocx, ocz, _ in ocx == 0 && ocz == 0 },
                         plan: { _, _, _, _ in
                             StructurePlan(id: id, pieces: [
                                 piece(startX, 64, 0, startX + 3, 64, 0) { _ in },
                             ])
                         })
        }
        // Both plans overlap at x=15...17 and both their six-block canopy
        // margins reach feature-origin chunk 0. The lower-ranked jungle plan
        // additionally extends one block farther east, making a retained
        // loser observable without depending on a tree RNG fixture.
        let desert = landmark(id: "desert_temple", salt: 0xC0A5_E, startX: 14)
        let jungle = landmark(id: "jungle_temple", salt: 0xC0A5_F, startX: 15)

        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        let exclusions = treeCanopyExclusions(forOriginChunk: 0, 0, context: context(),
                                               structures: [jungle, desert],
                                               collisionDefinitions: [desert, jungle])
        XCTAssertEqual(exclusions.count, 1,
                       "only the accepted conventional plan may reserve canopy space")
        guard let winner = exclusions.first else { return }
        XCTAssertEqual(winner.x0, 8)
        XCTAssertEqual(winner.x1, 23)
        XCTAssertTrue(winner.contains(23, 0), "winning landmark must still protect its canopy margin")
        XCTAssertFalse(exclusions.contains { $0.contains(24, 0) },
                       "suppressed landmark's unique canopy tail must not block tree placement")
    }

    func testSuppressedForeignLandmarkDoesNotVetoVillageCollisionCheck() throws {
        func landmark(id: String, salt: UInt32, startX: Int, endX: Int) -> StructureDef {
            StructureDef(id: id, spacing: 1, separation: 0, salt: salt, maxRadiusChunks: 1,
                         check: { _, originX, originZ, _ in originX == 0 && originZ == 0 },
                         plan: { _, _, _, _ in
                             StructurePlan(id: id, pieces: [
                                 piece(startX, 64, 0, endX, 64, 0) { _ in },
                             ])
                         })
        }

        // The jungle plan hits the village but loses to the adjacent desert
        // plan at x=4...5. The desert winner does not touch the village, so
        // village rejection must use the resolver's materializing plans, not
        // every raw foreign candidate.
        let villagePieces = [piece(0, 64, 0, 3, 64, 0) { _ in }]
        let desert = landmark(id: "desert_temple", salt: 0xD35E_27,
                              startX: 4, endX: 7)
        let jungle = landmark(id: "jungle_temple", salt: 0xA11C_E,
                              startX: 0, endX: 5)
        let ctx = context()

        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        let junglePlan = try XCTUnwrap(getPlan(jungle, ctx, 0, 0))
        XCTAssertFalse(surfaceStructurePlanWins(jungle, junglePlan, ctx, 0, 0,
                                                collisionDefinitions: [jungle, desert]),
                       "the overlapping lower-priority landmark must be suppressed")
        XCTAssertTrue(villageOverlapsForeignSurfaceStructure(ctx, villagePieces,
                                                              collisionDefinitions: [jungle]),
                      "the same raw plan is a real village conflict when it has no conventional winner")
        XCTAssertFalse(villageOverlapsForeignSurfaceStructure(ctx, villagePieces,
                                                               collisionDefinitions: [jungle, desert]),
                       "a suppressed foreign landmark must not veto a non-overlapping village")
    }

    func testRuinedPortalLosesActualOverlapWithPillagerOutpost() throws {
        let outpost = try XCTUnwrap(STRUCTURES.first { $0.id == "pillager_outpost" })
        let portal = try XCTUnwrap(STRUCTURES.first { $0.id == "ruined_portal" })
        // Fixed lattice witness: both raw plans are valid on plains and share
        // x=1090. The collision resolver—not structure registration/build
        // order—must retain the established outpost and reject the portal.
        let ctx = GenCtx(seed: 10,
                         heightAt: { _, _ in 64 },
                         biomeAt: { _, _ in Biome.plains.rawValue },
                         dim: Dim.overworld.rawValue,
                         generationSettingsIdentity: "portal-outpost-overlap",
                         baseTerrainOracleVersion: baseTerrainOracleVersion,
                         activeStructureDefinitions: [outpost, portal])
        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        let outpostPlan = try XCTUnwrap(getPlan(outpost, ctx, 67, 148))
        let portalPlan = try XCTUnwrap(getPlan(portal, ctx, 68, 148))
        XCTAssertTrue(surfaceStructurePiecesOverlapXZ(outpostPlan.pieces, portalPlan.pieces),
                      "the reviewed fixture must prove a real emitted-piece overlap")
        XCTAssertTrue(surfaceStructurePlanWins(outpost, outpostPlan, ctx, 67, 148,
                                               collisionDefinitions: [outpost, portal]))
        XCTAssertFalse(surfaceStructurePlanWins(portal, portalPlan, ctx, 68, 148,
                                                collisionDefinitions: [outpost, portal]),
                       "a later ruined portal must not stamp across an accepted outpost")
    }
}
