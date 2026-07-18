import XCTest
@testable import ElysiumCore

private enum PriorBadVillageFixture {
    static let seed: UInt32 = 1
    static let cx = -504
    static let cz = -493
    static let preChangeWaterCells = 1_583
    static let preChangeVillagers = 3
}

private enum PriorClippedOrdinaryDungeonFixture {
    static let seed: UInt32 = 12_345
    static let cx = -16
    static let cz = -71
    static let pass = 0
    static let spawner = (x: -244, y: 11, z: -1_125)
}

private enum PinnedUnderwaterDungeonFixture {
    static let seed: UInt32 = 1
    static let cx = 80
    static let cz = -128
    static let pass = 0
    static let attempt = 1
    static let rawCenter = (x: 1_292, y: 44, z: -2_038)
}

private enum AcceptedDryVillageFixture {
    static let seed: UInt32 = 1
    static let cx = -151
    static let cz = 80
}

private struct CanonicalDungeonRegion {
    let seed: UInt32
    let regionX: Int
    let regionZ: Int
    let settings: WorldGenerationSettings
}

private struct EmittedPosition: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

private struct EmittedChunkKey: Hashable {
    let x: Int
    let z: Int
}

/// Test-only view of the blocks that normal generation actually published.
/// It deliberately has no access to structure candidates or validators.
private struct EmittedRegion {
    let seed: UInt32
    let chunks: [EmittedChunkKey: GenOutput]

    func cell(_ x: Int, _ y: Int, _ z: Int) -> Int {
        guard y >= GEN_MIN_Y, y < GEN_MIN_Y + WORLD_H,
              let output = chunks[EmittedChunkKey(x: floorDiv(x, 16), z: floorDiv(z, 16))] else {
            return -1
        }
        let lx = x - floorDiv(x, 16) * 16
        let lz = z - floorDiv(z, 16) * 16
        return Int(output.blocks[((y - GEN_MIN_Y) * 16 + lz) * 16 + lx])
    }

    var entities: [EntitySpec] { chunks.values.flatMap(\.entities) }
    var blockEntities: [BESpec] { chunks.values.flatMap(\.blockEntities) }
}

/// Reviewed complete aligned region. It is literal input, never discovered by
/// the test runner, and contains well over the required 256 committed dungeons.
private let canonicalDungeonRegions = [
    CanonicalDungeonRegion(seed: 1, regionX: 2, regionZ: -4,
                           settings: WorldGenerationSettings(dungeonDensity: .many)),
]

private final class RejectingDungeonSink: ChunkSink {
    let cx: Int, cz: Int
    let minY = GEN_MIN_Y
    let maxY = GEN_MIN_Y + WORLD_H
    private(set) var writeCount = 0
    private(set) var blockEntityCount = 0
    init(cx: Int, cz: Int) { self.cx = cx; self.cz = cz }
    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) { writeCount += 1 }
    func get(_ x: Int, _ y: Int, _ z: Int) -> Int { Int(cell(B.stone)) }
    func topY(_ x: Int, _ z: Int) -> Int { 64 }
    func addBlockEntity(_ spec: BESpec) { blockEntityCount += 1 }
    func addEntity(_ spec: EntitySpec) {}
}

private final class PublicationOrderSink: ChunkSink {
    let cx = 0, cz = 0, minY = GEN_MIN_Y, maxY = GEN_MIN_Y + WORLD_H
    private(set) var events: [String] = []
    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) { events.append("block:\(x)") }
    func get(_ x: Int, _ y: Int, _ z: Int) -> Int { 0 }
    func topY(_ x: Int, _ z: Int) -> Int { 64 }
    func addBlockEntity(_ spec: BESpec) { events.append("be:\(spec.x)") }
    func addEntity(_ spec: EntitySpec) { events.append("entity:\(spec.x)") }
}

final class WorldgenPlayabilityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    func testReviewedFixtureIdentitiesAreLiteralAndDistinct() {
        XCTAssertEqual(PriorBadVillageFixture.seed, 1)
        XCTAssertEqual(PriorBadVillageFixture.cx, -504)
        XCTAssertEqual(PriorBadVillageFixture.cz, -493)
        XCTAssertEqual(PriorBadVillageFixture.preChangeWaterCells, 1_583)
        XCTAssertEqual(PriorBadVillageFixture.preChangeVillagers, 3)
        XCTAssertEqual(PriorClippedOrdinaryDungeonFixture.seed, 12_345)
        XCTAssertEqual(PriorClippedOrdinaryDungeonFixture.cx, -16)
        XCTAssertEqual(PriorClippedOrdinaryDungeonFixture.cz, -71)
        XCTAssertEqual(PriorClippedOrdinaryDungeonFixture.spawner.x, -244)
        XCTAssertEqual(PinnedUnderwaterDungeonFixture.cx, 80)
        XCTAssertEqual(PinnedUnderwaterDungeonFixture.cz, -128)
        XCTAssertEqual(PinnedUnderwaterDungeonFixture.rawCenter.y, 44)
    }

    func testBaseTerrainFunctionMatchesLegacyStageOrderAcrossPresets() {
        let settings: [WorldGenerationSettings] = [
            .normal,
            WorldGenerationSettings(preset: .moderateHillsResourceRich),
            WorldGenerationSettings(preset: .singleBiomeSurface, singleBiome: .desert),
        ]
        for (index, setting) in settings.enumerated() {
            let cx = -3 + index, cz = 5 - index
            let actual = buildBaseTerrainChunk(seed: 0xC0FFEE, cx: cx, cz: cz, settings: setting)
            let gen = overworldGen(0xC0FFEE, settings: setting)
            var blocks = [UInt16](repeating: 0, count: CHUNK_W * CHUNK_W * WORLD_H)
            var biomes = [UInt8](repeating: 0, count: 4 * 4 * ((WORLD_H + 3) / 4))
            let terrain = gen.fillTerrain(cx, cz, &blocks, &biomes)
            gen.carve(cx, cz, &blocks)
            gen.applySurface(cx, cz, &blocks, terrain.heights, terrain.surfaceBiomes)
            gen.placeOres(cx, cz, &blocks, terrain.surfaceBiomes)
            XCTAssertEqual(actual.blocks, blocks, "preset \(setting.preset.rawValue)")
            XCTAssertEqual(actual.biomes, biomes, "preset \(setting.preset.rawValue)")
        }
    }

    func testBaseTerrainOracleIsBoundedAndOrderIndependent() {
        let a = BaseTerrainOracle(seed: 91, settings: .normal, maxCachedChunks: 2, maxQueries: 4)
        let first = a.cell(0, 60, 0)
        let second = a.cell(32, 60, 0)
        let third = a.cell(16, 60, 0)
        XCTAssertEqual(a.cachedChunkCount, 2)
        XCTAssertEqual(a.observedQueryCount, 3)
        let b = BaseTerrainOracle(seed: 91, settings: .normal, maxCachedChunks: 2, maxQueries: 4)
        XCTAssertEqual(b.cell(16, 60, 0), third)
        XCTAssertEqual(b.cell(32, 60, 0), second)
        XCTAssertEqual(b.cell(0, 60, 0), first)
        _ = a.cell(48, 60, 0)
        XCTAssertNil(a.cell(64, 60, 0))
        XCTAssertEqual(a.observedQueryCount, 4)
    }

    func testContextCompletePlanCacheSeparatesKeysAndSingleFlights() {
        resetStructurePlanCacheForTesting()
        let lock = NSLock()
        var calls = 0
        let definition = StructureDef(id: "cache_probe", spacing: 1, separation: 0,
                                      salt: 771, maxRadiusChunks: 0,
                                      check: { _, _, _, _ in true },
                                      plan: { _, x, z, _ in
                                          lock.lock(); calls += 1; lock.unlock()
                                          Thread.sleep(forTimeInterval: 0.01)
                                          return StructurePlan(id: "cache_probe", pieces: [],
                                                               ref: StructRefBox(x, 0, z, x, 0, z))
                                      })
        let ctx = GenCtx(seed: 7, heightAt: { _, _ in 64 }, biomeAt: { _, _ in 0 }, dim: 0,
                         generationSettingsIdentity: "normal", baseTerrainOracleVersion: 1)
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            XCTAssertNotNil(getPlan(definition, ctx, 4, 9))
        }
        XCTAssertEqual(calls, 1)
        let otherSeed = GenCtx(seed: 8, heightAt: { _, _ in 64 }, biomeAt: { _, _ in 0 }, dim: 0,
                               generationSettingsIdentity: "normal", baseTerrainOracleVersion: 1)
        let otherSettings = GenCtx(seed: 7, heightAt: { _, _ in 64 }, biomeAt: { _, _ in 0 }, dim: 0,
                                   generationSettingsIdentity: "amplified", baseTerrainOracleVersion: 1)
        XCTAssertNotNil(getPlan(definition, otherSeed, 4, 9))
        XCTAssertNotNil(getPlan(definition, otherSettings, 4, 9))
        XCTAssertEqual(calls, 3)
        let stats = structurePlanCacheStatsForTesting()
        XCTAssertEqual(stats.entries, 3)
        XCTAssertEqual(stats.computations, 3)
    }

    func testCanonicalCompleteRegionBoundsRawUnderwaterPermissions() {
        var total = 0
        var underwater = 0
        for region in canonicalDungeonRegions {
            let summary = dungeonRegionBudgetSummary(seed: region.seed,
                                                     regionX: region.regionX,
                                                     regionZ: region.regionZ,
                                                     settings: region.settings)
            total += summary.rawAcceptedCount
            underwater += summary.underwaterSelectedCount
        }
        XCTAssertGreaterThanOrEqual(total, 256)
        XCTAssertGreaterThanOrEqual(underwater, 1)
        XCTAssertLessThanOrEqual(underwater, total / 16)
        XCTAssertTrue(dungeonUnderwaterBudgetSelected(seed: PinnedUnderwaterDungeonFixture.seed,
                                                      cx: PinnedUnderwaterDungeonFixture.cx,
                                                      cz: PinnedUnderwaterDungeonFixture.cz,
                                                      pass: PinnedUnderwaterDungeonFixture.pass))
    }

    func testCanonicalCompleteRegionCapsActualCommittedUnderwaterDungeons() {
        var committed = 0
        var underwater = 0
        for region in canonicalDungeonRegions {
            let x0 = region.regionX * dungeonRegionPlannerLimits.side
            let z0 = region.regionZ * dungeonRegionPlannerLimits.side
            for cz in z0..<(z0 + dungeonRegionPlannerLimits.side) {
                for cx in x0..<(x0 + dungeonRegionPlannerLimits.side) {
                    let output = generateChunk(.overworld, region.seed, cx, cz,
                                               settings: region.settings)
                    for spawner in committedDungeonSpawners(output) {
                        committed += 1
                        if dungeonHasNoEmittedEntrance(output, cx: cx, cz: cz, spawner: spawner) {
                            underwater += 1
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(committed, 256)
        XCTAssertGreaterThanOrEqual(underwater, 1)
        XCTAssertLessThanOrEqual(underwater, committed / 16)
    }

    func testFourBoundaryConcurrentRegionPlansStayWithinFixedResourceCaps() {
        let limits = dungeonRegionPlannerLimits
        XCTAssertEqual(limits.side, 32)
        XCTAssertEqual(limits.maximumPasses, 8)
        XCTAssertEqual(limits.cacheEntries, 64)
        XCTAssertEqual(limits.maximumRawCandidates, 32 * 32 * 8 * 4)
        XCTAssertEqual(limits.maximumStoredMembers, 32 * 32 * 8)
        XCTAssertEqual(limits.maximumRetainedBytesPerPlan, 512 * 1_024)

        let regions = [(-1, -1), (0, -1), (-1, 0), (0, 0)]
        let lock = NSLock()
        var summaries: [String: [DungeonRegionBudgetSummary]] = [:]
        let settings = WorldGenerationSettings(dungeonDensity: .many)
        DispatchQueue.concurrentPerform(iterations: 32) { index in
            let region = regions[index % regions.count]
            let summary = dungeonRegionBudgetSummary(seed: 0xB0A7_DA7A,
                                                     regionX: region.0,
                                                     regionZ: region.1,
                                                     settings: settings)
            lock.lock(); summaries["\(region.0):\(region.1)", default: []].append(summary); lock.unlock()
        }
        XCTAssertEqual(summaries.values.reduce(0) { $0 + $1.count }, 32)
        XCTAssertEqual(summaries.count, 4)
        for values in summaries.values {
            XCTAssertEqual(Set(values.map { "\($0.rawAcceptedCount):\($0.underwaterSelectedCount)" }).count, 1)
            XCTAssertTrue(values.allSatisfy {
                $0.rawAcceptedCount <= limits.maximumRawCandidates
                    && $0.underwaterSelectedCount <= $0.rawAcceptedCount / 16
            })
        }
    }

    func testPriorFloodedVillageIsOmittedOrItsEmissionPassesIndependentScanner() {
        let origin = generateChunk(.overworld, PriorBadVillageFixture.seed,
                                   PriorBadVillageFixture.cx, PriorBadVillageFixture.cz)
        guard let reference = origin.structRefs.first(where: { $0.id == "village" }) else {
            XCTAssertFalse(origin.structRefs.contains { $0.id == "village" })
            return
        }
        let emission = emittedVillageRegion(seed: PriorBadVillageFixture.seed,
                                            originCX: PriorBadVillageFixture.cx,
                                            originCZ: PriorBadVillageFixture.cz,
                                            reference: reference,
                                            origin: origin)
        assertVillageEmissionIsPlayable(emission, reference: reference)
    }

    func testAcceptedVillageEmissionHasConnectedRoadsDryBoundedSupportAndSafeSpawns() {
        let origin = generateChunk(.overworld, AcceptedDryVillageFixture.seed,
                                   AcceptedDryVillageFixture.cx, AcceptedDryVillageFixture.cz)
        guard let reference = origin.structRefs.first(where: { $0.id == "village" }) else {
            return XCTFail("literal accepted fixture must emit a village")
        }
        let emission = emittedVillageRegion(seed: AcceptedDryVillageFixture.seed,
                                            originCX: AcceptedDryVillageFixture.cx,
                                            originCZ: AcceptedDryVillageFixture.cz,
                                            reference: reference,
                                            origin: origin)
        assertVillageEmissionIsPlayable(emission, reference: reference)
    }

    func testPriorClippedOrdinaryDungeonEmissionIsWholeDryAndCaveConnected() {
        let ordinary = generateChunk(.overworld, PriorClippedOrdinaryDungeonFixture.seed,
                                     PriorClippedOrdinaryDungeonFixture.cx,
                                     PriorClippedOrdinaryDungeonFixture.cz)
        guard let spawner = committedDungeonSpawners(ordinary).first else {
            return XCTFail("literal prior-clipped fixture must emit an ordinary dungeon")
        }
        assertEmittedDungeon(ordinary,
                             seed: PriorClippedOrdinaryDungeonFixture.seed,
                             cx: PriorClippedOrdinaryDungeonFixture.cx,
                             cz: PriorClippedOrdinaryDungeonFixture.cz,
                             spawner: spawner,
                             expectedUnderwater: false)
    }

    func testPinnedUnderwaterDungeonEmissionIsSealedDryUsableAndColocated() {
        let underwater = generateChunk(.overworld, PinnedUnderwaterDungeonFixture.seed,
                                       PinnedUnderwaterDungeonFixture.cx,
                                       PinnedUnderwaterDungeonFixture.cz)
        guard let spawner = underwater.blockEntities.first(where: { $0.kind == "spawner" }) else {
            return XCTFail("pinned underwater fixture must place a dungeon")
        }
        assertEmittedDungeon(underwater,
                             seed: PinnedUnderwaterDungeonFixture.seed,
                             cx: PinnedUnderwaterDungeonFixture.cx,
                             cz: PinnedUnderwaterDungeonFixture.cz,
                             spawner: spawner,
                             expectedUnderwater: true)
    }

    func testRejectedDungeonCandidatePerformsNoWrites() {
        let sink = RejectingDungeonSink(cx: PriorClippedOrdinaryDungeonFixture.cx,
                                        cz: PriorClippedOrdinaryDungeonFixture.cz)
        XCTAssertEqual(tryDungeons(PriorClippedOrdinaryDungeonFixture.seed,
                                   PriorClippedOrdinaryDungeonFixture.cx,
                                   PriorClippedOrdinaryDungeonFixture.cz,
                                   sink), 0)
        XCTAssertEqual(sink.writeCount, 0)
        XCTAssertEqual(sink.blockEntityCount, 0)
    }

    func testGenerationOrderDoesNotChangeStructureOutput() {
        let fixtures = [
            (PriorClippedOrdinaryDungeonFixture.seed,
             PriorClippedOrdinaryDungeonFixture.cx, PriorClippedOrdinaryDungeonFixture.cz),
            (PinnedUnderwaterDungeonFixture.seed,
             PinnedUnderwaterDungeonFixture.cx, PinnedUnderwaterDungeonFixture.cz),
            (AcceptedDryVillageFixture.seed,
             AcceptedDryVillageFixture.cx, AcceptedDryVillageFixture.cz),
        ]
        resetStructurePlanCacheForTesting()
        var forward: [String: GenOutput] = [:]
        for fixture in fixtures {
            forward["\(fixture.0):\(fixture.1):\(fixture.2)"] =
                generateChunk(.overworld, fixture.0, fixture.1, fixture.2)
        }
        resetStructurePlanCacheForTesting()
        for fixture in fixtures.reversed() {
            let key = "\(fixture.0):\(fixture.1):\(fixture.2)"
            let expected = forward[key]
            let actual = generateChunk(.overworld, fixture.0, fixture.1, fixture.2)
            XCTAssertEqual(actual.blocks, expected?.blocks, key)
            XCTAssertEqual(actual.biomes, expected?.biomes, key)
            XCTAssertEqual(blockEntitySignature(actual), expected.map(blockEntitySignature), key)
            XCTAssertEqual(entitySignature(actual), expected.map(entitySignature), key)
            XCTAssertEqual(referenceSignature(actual), expected.map(referenceSignature), key)
        }
    }

    func testStructureChunkPostStatePublishesBlocksBeforeBlockEntitiesAndEntities() {
        resetStructurePlanCacheForTesting()
        let definition = StructureDef(id: "publication_order", spacing: 1, separation: 0,
                                      salt: 0x7711, maxRadiusChunks: 0,
                                      check: { _, _, _, _ in true },
                                      plan: { _, _, _, _ in
                                          StructurePlan(id: "publication_order", pieces: [
                                            piece(0, 64, 0, 0, 64, 0) { builder in
                                                builder.set(0, 64, 0, Int(cell(B.chest)))
                                                builder.s.addBlockEntity(BESpec(x: 0, y: 64, z: 0,
                                                                                kind: "probe"))
                                                builder.s.addEntity(EntitySpec(mob: "pig", x: 0.5,
                                                                              y: 65, z: 0.5))
                                            },
                                            piece(1, 64, 0, 1, 64, 0) { builder in
                                                builder.set(1, 64, 0, Int(cell(B.stone)))
                                            },
                                          ])
                                      })
        let sink = PublicationOrderSink()
        let ctx = GenCtx(seed: 1, heightAt: { _, _ in 64 }, biomeAt: { _, _ in 0 }, dim: 0)
        _ = buildStructuresForChunk(ctx, 0, 0, sink, [definition])
        XCTAssertEqual(sink.events, ["block:0", "block:1", "be:0", "entity:0.5"])
    }

    private func emittedVillageRegion(seed: UInt32, originCX: Int, originCZ: Int,
                                      reference: StructRef, origin: GenOutput) -> EmittedRegion {
        let minCX = floorDiv(reference.x0, 16), maxCX = floorDiv(reference.x1, 16)
        let minCZ = floorDiv(reference.z0, 16), maxCZ = floorDiv(reference.z1, 16)
        var chunks: [EmittedChunkKey: GenOutput] = [:]
        for cz in minCZ...maxCZ {
            for cx in minCX...maxCX {
                let key = EmittedChunkKey(x: cx, z: cz)
                chunks[key] = (cx == originCX && cz == originCZ)
                    ? origin
                    : generateChunk(.overworld, seed, cx, cz)
            }
        }
        return EmittedRegion(seed: seed, chunks: chunks)
    }

    /// Reconstructs village playability exclusively from normal emitted chunks.
    /// Structure candidates, planned pieces, and the production validator are not
    /// consulted. The reference supplies only the finite scan boundary.
    private func assertVillageEmissionIsPlayable(_ emission: EmittedRegion,
                                                  reference: StructRef,
                                                  file: StaticString = #filePath,
                                                  line: UInt = #line) {
        let roadID = Int(B.dirt_path)
        var roadFeet: [EmittedPosition] = []
        var roadBaseHeights: [Int] = []
        var roadByColumn: [EmittedPosition: EmittedPosition] = [:]
        var baseChunks: [EmittedChunkKey: BaseTerrainChunk] = [:]

        for z in reference.z0...reference.z1 {
            for x in reference.x0...reference.x1 {
                for y in reference.y0...reference.y1 where blockID(emission.cell(x, y, z)) == roadID {
                    let key = EmittedChunkKey(x: floorDiv(x, 16), z: floorDiv(z, 16))
                    let base: BaseTerrainChunk
                    if let cached = baseChunks[key] {
                        base = cached
                    } else {
                        let built = buildBaseTerrainChunk(seed: emission.seed, cx: key.x, cz: key.z)
                        baseChunks[key] = built
                        base = built
                    }
                    let feet = EmittedPosition(x: x, y: y + 1, z: z)
                    roadFeet.append(feet)
                    if let baseY = base.topSolidY(worldX: x, worldZ: z) {
                        roadBaseHeights.append(baseY)
                        XCTAssertLessThanOrEqual(abs(y - baseY), 4,
                                                 "road terrace exceeds bounded fill", file: file, line: line)
                        for supportY in min(y, baseY)...max(y, baseY) {
                            let support = emission.cell(x, supportY, z)
                            XCTAssertTrue(isDrySolid(support),
                                          "road has dry-support gap at \(x),\(supportY),\(z)",
                                          file: file, line: line)
                        }
                    } else {
                        XCTFail("road column has no base-terrain support", file: file, line: line)
                    }
                    XCTAssertTrue(isDrySolid(emission.cell(x, y - 1, z)),
                                  "road lacks immediate dry support", file: file, line: line)
                    let firstHeadroom = emission.cell(x, y + 1, z)
                    let secondHeadroom = emission.cell(x, y + 2, z)
                    XCTAssertTrue(isOpen(firstHeadroom),
                                  "road lacks first headroom at \(x),\(y + 1),\(z): cell \(firstHeadroom)",
                                  file: file, line: line)
                    XCTAssertTrue(isOpen(secondHeadroom),
                                  "road lacks second headroom at \(x),\(y + 2),\(z): cell \(secondHeadroom)",
                                  file: file, line: line)
                    roadByColumn[EmittedPosition(x: x, y: 0, z: z)] = feet
                }
            }
        }

        XCTAssertGreaterThan(roadFeet.count, 24, "accepted village must expose emitted roads",
                             file: file, line: line)
        XCTAssertGreaterThan(Set(roadFeet.map(\.y)).count, 1,
                             "roads must follow terrain instead of creating one settlement plateau",
                             file: file, line: line)
        XCTAssertGreaterThan(Set(roadBaseHeights).count, 1,
                             "literal fixture must exercise non-flat base terrain", file: file, line: line)

        for feet in roadFeet {
            for (dx, dz) in [(1, 0), (0, 1)] {
                let neighborKey = EmittedPosition(x: feet.x + dx, y: 0, z: feet.z + dz)
                if let neighbor = roadByColumn[neighborKey] {
                    XCTAssertLessThanOrEqual(abs(feet.y - neighbor.y), 1,
                                             "adjacent emitted road step exceeds one block",
                                             file: file, line: line)
                }
            }
        }

        let centerX = (reference.x0 + reference.x1) / 2
        let centerZ = (reference.z0 + reference.z1) / 2
        guard let start = roadFeet.min(by: {
            abs($0.x - centerX) + abs($0.z - centerZ) < abs($1.x - centerX) + abs($1.z - centerZ)
        }) else { return XCTFail("village center has no reachable road", file: file, line: line) }
        XCTAssertLessThanOrEqual(abs(start.x - centerX) + abs(start.z - centerZ), 8,
                                 "road graph does not reach the emitted well/bell center",
                                 file: file, line: line)

        let residents = emission.entities.filter {
            ["villager", "iron_golem", "cat", "camel"].contains($0.mob)
                && Double(reference.x0) <= $0.x && $0.x <= Double(reference.x1 + 1)
                && Double(reference.z0) <= $0.z && $0.z <= Double(reference.z1 + 1)
        }
        XCTAssertFalse(residents.isEmpty, "accepted village must emit residents", file: file, line: line)
        var goals: Set<EmittedPosition> = []
        var goalOwners: [EmittedPosition: [String]] = [:]
        for resident in residents {
            let x = Int(resident.x.rounded(.down))
            let y = Int(resident.y.rounded(.down))
            let z = Int(resident.z.rounded(.down))
            let footing = emission.cell(x, y - 1, z)
            let body = emission.cell(x, y, z)
            let head = emission.cell(x, y + 1, z)
            XCTAssertTrue(isDrySolid(footing),
                          "resident \(resident.mob) lacks safe dry footing at \(x),\(y - 1),\(z): cell \(footing)",
                          file: file, line: line)
            XCTAssertTrue(isOpen(body),
                          "resident \(resident.mob) body is obstructed at \(x),\(y),\(z): cell \(body)",
                          file: file, line: line)
            XCTAssertTrue(isOpen(head),
                          "resident \(resident.mob) lacks headroom at \(x),\(y + 1),\(z): cell \(head)",
                          file: file, line: line)
            guard let entrance = roadFeet.min(by: {
                abs($0.x - x) + abs($0.z - z) < abs($1.x - x) + abs($1.z - z)
            }) else { continue }
            XCTAssertLessThanOrEqual(abs(entrance.x - x) + abs(entrance.z - z), 8,
                                     "occupied building has no emitted road entrance",
                                     file: file, line: line)
            goals.insert(entrance)
            goalOwners[entrance, default: []].append("\(resident.mob)@\(x),\(y),\(z)")
        }

        let reachable = emittedWalkableBFS(from: start, emission: emission, bounds: reference)
        for goal in goals {
            let nearest = reachable.min {
                abs($0.x - goal.x) + abs($0.y - goal.y) + abs($0.z - goal.z)
                    < abs($1.x - goal.x) + abs($1.y - goal.y) + abs($1.z - goal.z)
            }
            let nearbyRoads = roadFeet.filter {
                abs($0.x - goal.x) <= 5 && abs($0.z - goal.z) <= 5
            }.sorted {
                ($0.z, $0.x, $0.y) < ($1.z, $1.x, $1.y)
            }.map { "\($0.x),\($0.y),\($0.z):\(reachable.contains($0) ? "R" : "X")" }
            XCTAssertTrue(reachable.contains(goal),
                          "emitted road/terrain BFS cannot reach occupied entrance \(goal) for \(goalOwners[goal, default: []]); nearest=\(String(describing: nearest)); nearbyRoads=\(nearbyRoads)",
                          file: file, line: line)
        }
    }

    private func emittedWalkableBFS(from start: EmittedPosition, emission: EmittedRegion,
                                     bounds: StructRef) -> Set<EmittedPosition> {
        var visited: Set<EmittedPosition> = [start]
        var queue: [EmittedPosition] = [start]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            for (dx, dz) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let x = current.x + dx, z = current.z + dz
                guard x >= bounds.x0, x <= bounds.x1, z >= bounds.z0, z <= bounds.z1 else { continue }
                for y in (current.y - 1)...(current.y + 1) {
                    let candidate = EmittedPosition(x: x, y: y, z: z)
                    guard !visited.contains(candidate),
                          isDrySolid(emission.cell(x, y - 1, z)),
                          isOpen(emission.cell(x, y, z)),
                          isOpen(emission.cell(x, y + 1, z)) else { continue }
                    visited.insert(candidate)
                    queue.append(candidate)
                }
            }
        }
        return visited
    }

    /// Independently infers room size and entrance from emitted shell cells.
    /// It then scans containment, shell continuity, dry volume, cave provenance,
    /// no-leak behavior, usable neighbors, and block-entity ownership.
    private func assertEmittedDungeon(_ output: GenOutput, seed: UInt32, cx: Int, cz: Int,
                                      spawner: BESpec, expectedUnderwater: Bool,
                                      file: StaticString = #filePath,
                                      line: UInt = #line) {
        let shellIDs: Set<Int> = [Int(B.cobblestone), Int(B.mossy_cobblestone)]
        let directions = [(dx: -1, dz: 0), (dx: 1, dz: 0),
                          (dx: 0, dz: -1), (dx: 0, dz: 1)]
        let inferred = (3...4).compactMap { halfWidth -> (Int, [(dx: Int, dz: Int)])? in
            var openings: [(dx: Int, dz: Int)] = []
            for direction in directions {
                let wallOpen = (spawner.y...(spawner.y + 1)).allSatisfy { y in
                    outputCell(output, cx: cx, cz: cz,
                               x: spawner.x + direction.dx * halfWidth, y: y,
                               z: spawner.z + direction.dz * halfWidth) == 0
                }
                let outerOpen = (spawner.y...(spawner.y + 1)).allSatisfy { y in
                    outputCell(output, cx: cx, cz: cz,
                               x: spawner.x + direction.dx * (halfWidth + 1), y: y,
                               z: spawner.z + direction.dz * (halfWidth + 1)) == 0
                }
                if wallOpen && outerOpen { openings.append(direction) }
            }
            let expectedOpeningCount = expectedUnderwater ? 0 : 1
            guard openings.count == expectedOpeningCount else { return nil }
            for dz in -halfWidth...halfWidth {
                for dx in -halfWidth...halfWidth {
                    let onSide = abs(dx) == halfWidth || abs(dz) == halfWidth
                    for dy in -1...3 {
                        let floorOrCeiling = dy == -1 || dy == 3
                        guard onSide || floorOrCeiling else { continue }
                        let isOpening = dy >= 0 && dy <= 1 && openings.contains {
                            dx == $0.dx * halfWidth && dz == $0.dz * halfWidth
                        }
                        if !isOpening {
                            let value = outputCell(output, cx: cx, cz: cz,
                                                   x: spawner.x + dx, y: spawner.y + dy,
                                                   z: spawner.z + dz)
                            guard shellIDs.contains(blockID(value)) else { return nil }
                        }
                    }
                }
            }
            return (halfWidth, openings)
        }.first
        guard let (halfWidth, openings) = inferred else {
            return XCTFail("cannot infer one complete emitted dungeon shell", file: file, line: line)
        }

        let minX = cx * 16, maxX = minX + 15, minZ = cz * 16, maxZ = minZ + 15
        XCTAssertGreaterThanOrEqual(spawner.x - halfWidth, minX, file: file, line: line)
        XCTAssertLessThanOrEqual(spawner.x + halfWidth, maxX, file: file, line: line)
        XCTAssertGreaterThanOrEqual(spawner.z - halfWidth, minZ, file: file, line: line)
        XCTAssertLessThanOrEqual(spawner.z + halfWidth, maxZ, file: file, line: line)
        for opening in openings {
            XCTAssertTrue((minX...maxX).contains(spawner.x + opening.dx * (halfWidth + 1)),
                          file: file, line: line)
            XCTAssertTrue((minZ...maxZ).contains(spawner.z + opening.dz * (halfWidth + 1)),
                          file: file, line: line)
        }

        for z in (spawner.z - halfWidth + 1)...(spawner.z + halfWidth - 1) {
            for x in (spawner.x - halfWidth + 1)...(spawner.x + halfWidth - 1) {
                for y in spawner.y...(spawner.y + 2) {
                    XCTAssertFalse(isFluid(outputCell(output, cx: cx, cz: cz, x: x, y: y, z: z)),
                                   "dungeon interior is not dry", file: file, line: line)
                }
            }
        }

        assertDungeonBlockEntitiesAreOwned(output, cx: cx, cz: cz, file: file, line: line)
        let owned = output.blockEntities.filter {
            $0.kind == "spawner" || ($0.kind == "chest_loot" && $0.data["lootTable"] == .str("dungeon"))
        }
        XCTAssertFalse(owned.isEmpty, file: file, line: line)

        let start: EmittedPosition
        if let opening = openings.first {
            start = EmittedPosition(x: spawner.x + opening.dx * (halfWidth + 1),
                                    y: spawner.y,
                                    z: spawner.z + opening.dz * (halfWidth + 1))
            let base = buildBaseTerrainChunk(seed: seed, cx: cx, cz: cz)
            XCTAssertEqual(base.cell(worldX: start.x, y: start.y, worldZ: start.z), 0,
                           "ordinary entrance did not connect to pre-existing cave air",
                           file: file, line: line)
            XCTAssertEqual(base.cell(worldX: start.x, y: start.y + 1, worldZ: start.z), 0,
                           "ordinary entrance lacks two-high cave provenance",
                           file: file, line: line)
        } else {
            start = EmittedPosition(x: spawner.x + 1, y: spawner.y, z: spawner.z)
        }

        var reached: Set<EmittedPosition> = [start]
        var queue = [start]
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            for (dx, dz) in directions {
                let next = EmittedPosition(x: current.x + dx, y: current.y, z: current.z + dz)
                guard !reached.contains(next),
                      outputCell(output, cx: cx, cz: cz, x: next.x, y: next.y, z: next.z) == 0,
                      outputCell(output, cx: cx, cz: cz, x: next.x, y: next.y + 1, z: next.z) == 0 else {
                    continue
                }
                reached.insert(next)
                queue.append(next)
            }
        }

        for spec in owned {
            let hasUsableNeighbor = directions.contains { direction in
                reached.contains(EmittedPosition(x: spec.x + direction.dx,
                                                 y: spec.y,
                                                 z: spec.z + direction.dz))
            }
            XCTAssertTrue(hasUsableNeighbor,
                          "dungeon block entity has no dry reachable usable neighbor",
                          file: file, line: line)
        }
        if expectedUnderwater {
            XCTAssertTrue(reached.allSatisfy {
                $0.x > spawner.x - halfWidth && $0.x < spawner.x + halfWidth
                    && $0.z > spawner.z - halfWidth && $0.z < spawner.z + halfWidth
            }, "sealed underwater room leaks through emitted shell", file: file, line: line)
        } else {
            XCTAssertTrue(reached.contains(start), "ordinary entrance is unusable", file: file, line: line)
            XCTAssertTrue(reached.contains(EmittedPosition(x: spawner.x + 1,
                                                          y: spawner.y,
                                                          z: spawner.z)),
                          "ordinary entrance cannot reach room interior", file: file, line: line)
        }
    }

    private func blockID(_ value: Int) -> Int {
        value < 0 ? -1 : value >> 4
    }

    private func isDrySolid(_ value: Int) -> Bool {
        let id = blockID(value)
        return id >= 0 && id < SOLID.count && SOLID[id] == 1 && id != Int(B.water) && id != Int(B.lava)
    }

    private func isOpen(_ value: Int) -> Bool {
        let id = blockID(value)
        return value == 0 || (id >= 0 && id < SOLID.count && SOLID[id] == 0
            && id != Int(B.water) && id != Int(B.lava))
    }

    private func outputCell(_ out: GenOutput, cx: Int, cz: Int,
                            x: Int, y: Int, z: Int) -> Int {
        guard floorDiv(x, 16) == cx, floorDiv(z, 16) == cz,
              y >= GEN_MIN_Y, y < GEN_MIN_Y + WORLD_H else { return -1 }
        return Int(out.blocks[((y - GEN_MIN_Y) * 16 + (z - cz * 16)) * 16 + (x - cx * 16)])
    }

    private func isFluid(_ value: Int) -> Bool {
        value >= 0 && (value >> 4 == Int(B.water) || value >> 4 == Int(B.lava))
    }

    private func committedDungeonSpawners(_ out: GenOutput) -> [BESpec] {
        out.blockEntities.filter { spec in
            guard spec.kind == "spawner", case let .str(mob)? = spec.data["mob"] else { return false }
            return mob == "zombie" || mob == "skeleton" || mob == "spider"
        }
    }

    /// Production emits a two-high, two-deep cardinal opening for every ordinary
    /// dungeon and no opening for a sealed underwater variant. Inspecting the
    /// committed cells keeps this classification independent of permission and
    /// candidate-selection internals.
    private func dungeonHasNoEmittedEntrance(_ out: GenOutput, cx: Int, cz: Int,
                                             spawner: BESpec) -> Bool {
        let directions = [(dx: -1, dz: 0), (dx: 1, dz: 0),
                          (dx: 0, dz: -1), (dx: 0, dz: 1)]
        let hasEntrance = directions.contains { direction in
            (3...4).contains { distance in
                (distance...(distance + 1)).allSatisfy { offset in
                    outputCell(out, cx: cx, cz: cz,
                               x: spawner.x + direction.dx * offset,
                               y: spawner.y, z: spawner.z + direction.dz * offset) == 0
                        && outputCell(out, cx: cx, cz: cz,
                                      x: spawner.x + direction.dx * offset,
                                      y: spawner.y + 1,
                                      z: spawner.z + direction.dz * offset) == 0
                }
            }
        }
        return !hasEntrance
    }

    private func assertDungeonBlockEntitiesAreOwned(_ out: GenOutput, cx: Int, cz: Int,
                                                     file: StaticString = #filePath,
                                                     line: UInt = #line) {
        for spec in out.blockEntities where spec.kind == "spawner"
            || (spec.kind == "chest_loot" && spec.data["lootTable"] == .str("dungeon")) {
            let id = outputCell(out, cx: cx, cz: cz, x: spec.x, y: spec.y, z: spec.z) >> 4
            if spec.kind == "spawner" {
                XCTAssertEqual(id, Int(B.spawner), file: file, line: line)
            } else {
                XCTAssertEqual(id, Int(B.chest), file: file, line: line)
            }
        }
    }


    private func blockEntitySignature(_ out: GenOutput) -> [String] {
        out.blockEntities.map { "\($0.kind):\($0.x):\($0.y):\($0.z)" }.sorted()
    }

    private func entitySignature(_ out: GenOutput) -> [String] {
        out.entities.map { "\($0.mob):\($0.x):\($0.y):\($0.z)" }.sorted()
    }

    private func referenceSignature(_ out: GenOutput) -> [String] {
        out.structRefs.map { "\($0.id):\($0.x0):\($0.y0):\($0.z0):\($0.x1):\($0.y1):\($0.z1)" }.sorted()
    }
}
