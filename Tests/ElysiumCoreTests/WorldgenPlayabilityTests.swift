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

/// The persisted settings observed in the reported live world. Keep this
/// literal so this probe protects the player-facing configuration rather than
/// a convenient synthetic substitute.
private enum RichResourcesLiveWorldFixture {
    static let seed: UInt32 = 1_965_808_753
    static let playerChunk = (x: -1, z: -50)
    static let settings = WorldGenerationSettings(preset: .moderateHillsResourceRich,
                                                  dungeonDensity: .many)
}

/// A real saved-world style terrain probe, not a synthetic flat sink.  The
/// origin envelope is deliberately fixed in chunk coordinates so every density
/// is measured over the same map area. If a deliberate terrain-algorithm
/// revision invalidates this fixture, review and replace these two literals as
/// a pair; do not substitute a synthetic terrain context.
private enum FixedVillageDensityFixture {
    static let seed: UInt32 = RichResourcesLiveWorldFixture.seed
    static let originChunks = -80...79

    static func settings(_ density: VillageDensity) -> WorldGenerationSettings {
        WorldGenerationSettings(preset: .moderateHillsResourceRich,
                                dungeonDensity: .many,
                                villageDensity: density)
    }
}

private struct PlannedVillageCandidate {
    let originCX: Int
    let originCZ: Int
    let reference: StructRef
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
    let settings: WorldGenerationSettings

    init(seed: UInt32, chunks: [EmittedChunkKey: GenOutput],
         settings: WorldGenerationSettings = .normal) {
        self.seed = seed
        self.chunks = chunks
        self.settings = settings
    }

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

private struct DungeonOwnershipPoint: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

/// A deliberately narrow dungeon fixture: one known cave opening is the only
/// materializable entrance, which makes a cell-ownership rejection observable
/// without relying on a random natural cave.
private final class DungeonFootprintOwnershipSink: ChunkSink {
    let cx: Int
    let cz: Int
    let minY = GEN_MIN_Y
    let maxY = GEN_MIN_Y + WORLD_H
    private let defaultCell: UInt16
    private let openings: Set<DungeonOwnershipPoint>
    private(set) var cells: [DungeonOwnershipPoint: UInt16] = [:]
    private(set) var blockEntities: [BESpec]
    private(set) var writeCount = 0

    init(cx: Int, cz: Int, defaultCell: UInt16,
         openings: Set<DungeonOwnershipPoint> = [],
         initialCells: [DungeonOwnershipPoint: UInt16] = [:],
         existingBlockEntity: BESpec? = nil,
         existingCell: (point: DungeonOwnershipPoint, value: UInt16)? = nil) {
        self.cx = cx
        self.cz = cz
        self.defaultCell = defaultCell
        self.openings = openings
        cells = initialCells
        blockEntities = existingBlockEntity.map { [$0] } ?? []
        if let existingCell {
            cells[existingCell.point] = existingCell.value
        }
    }

    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        guard floorDiv(x, 16) == cx, floorDiv(z, 16) == cz,
              y >= minY, y < maxY else { return }
        writeCount += 1
        cells[DungeonOwnershipPoint(x: x, y: y, z: z)] = c
    }

    func get(_ x: Int, _ y: Int, _ z: Int) -> Int {
        guard floorDiv(x, 16) == cx, floorDiv(z, 16) == cz else { return -1 }
        guard y >= minY, y < maxY else { return 0 }
        let point = DungeonOwnershipPoint(x: x, y: y, z: z)
        return Int(cells[point] ?? (openings.contains(point) ? UInt16(0) : defaultCell))
    }

    func topY(_ x: Int, _ z: Int) -> Int { 64 }

    func hasBlockEntity(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        blockEntities.contains { $0.x == x && $0.y == y && $0.z == z }
    }

    func addBlockEntity(_ spec: BESpec) {
        guard floorDiv(spec.x, 16) == cx, floorDiv(spec.z, 16) == cz,
              spec.y >= minY, spec.y < maxY else { return }
        blockEntities.append(spec)
    }

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
        XCTAssertEqual(RichResourcesLiveWorldFixture.playerChunk.x, -1)
        XCTAssertEqual(RichResourcesLiveWorldFixture.playerChunk.z, -50)
        XCTAssertEqual(RichResourcesLiveWorldFixture.settings.preset, .moderateHillsResourceRich)
        XCTAssertEqual(RichResourcesLiveWorldFixture.settings.dungeonDensity, .many)
    }

    func testReportedRichResourcesWorldHasCommittedDungeonsAnimalsAndVillagePlans() {
        let fixture = RichResourcesLiveWorldFixture.self
        var dungeonCount = 0
        var passiveAnimalCount = 0
        let passiveMobs = Set(BIOMES.compactMap { $0 }.flatMap { $0.creatures.map(\.mob) })
        // This 20×20 probe covers the live player's reported position and a
        // substantial part of the 602 persisted chunks without treating the
        // synthetic fixture sink as evidence of usable terrain.
        for cz in (fixture.playerChunk.z - 10)...(fixture.playerChunk.z + 9) {
            for cx in (fixture.playerChunk.x - 10)...(fixture.playerChunk.x + 9) {
                let output = generateChunk(.overworld, fixture.seed, cx, cz, settings: fixture.settings)
                dungeonCount += committedDungeonSpawners(output).count
                passiveAnimalCount += output.entities.filter { passiveMobs.contains($0.mob) }.count
            }
        }
        XCTAssertGreaterThanOrEqual(dungeonCount, 8,
                                    "Many dungeons must commit in the real Rich Resources terrain probe")
        XCTAssertGreaterThanOrEqual(passiveAnimalCount, 20,
                                    "Rich Resources must bootstrap visible passive animal packs")

        guard let village = STRUCTURES.first(where: { $0.id == "village" }) else {
            return XCTFail("village definition must be registered")
        }
        let gen = overworldGen(fixture.seed, settings: fixture.settings)
        let oracle = BaseTerrainOracle(seed: fixture.seed, settings: fixture.settings,
                                       maxCachedChunks: 512, maxQueries: 500_000)
        let context = GenCtx(seed: fixture.seed,
                             heightAt: { x, z in oracle.topSolidY(x, z).map { $0 + 1 }
                                 ?? gen.refinedHeightEstimate(Double(x), Double(z)) },
                             biomeAt: { x, z in gen.surfaceBiomeAt(Double(x), Double(z)).rawValue },
                             dim: Dim.overworld.rawValue,
                             generationSettingsIdentity: fixture.settings.cacheIdentity,
                             baseTerrainOracleVersion: baseTerrainOracleVersion,
                             terrainOracle: oracle)
        guard let placement = village.placement(context) else {
            return XCTFail("normal village density must expose its active placement lattice")
        }
        var villagePlans = 0
        // Five by five placement regions provide 25 deterministic town sites
        // around the player without materializing a multi-thousand-chunk map.
        for rz in -4...0 {
            for rx in -3...1 {
                let origin = structureOriginFor(village, placement: placement,
                                                 seed: fixture.seed, regionX: rx, regionZ: rz)
                if getPlan(village, context, origin.0, origin.1) != nil { villagePlans += 1 }
            }
        }
        XCTAssertGreaterThanOrEqual(villagePlans, 1,
                                    "Rich Resources must retain at least one grounded village plan near the live world")
    }

    func testReportedRichResourcesCrossChunkTreeCanopiesHaveOwningLogs() {
        let fixture = RichResourcesLiveWorldFixture.self
        let gen = overworldGen(fixture.seed, settings: fixture.settings)
        let leafIDs = Set(blockDefs.enumerated().compactMap { index, def in
            def.name.hasSuffix("_leaves") ? index : nil
        })
        let logIDs = Set(blockDefs.enumerated().compactMap { index, def in
            def.name.hasSuffix("_log") ? index : nil
        })

        // The active player neighbourhood is plains in this literal seed, so
        // choose the first six nearby origin chunks whose biome actually has a
        // tree feature. The search is deterministic and only identifies where
        // to exercise the invariant; normal chunk generation remains the sole
        // source of evidence.
        var candidates: [(Int, Int)] = []
        for dz in -12...12 {
            for dx in -12...12 {
                let cx = fixture.playerChunk.x + dx, cz = fixture.playerChunk.z + dz
                let biome = gen.surfaceBiomeAt(Double(cx * 16 + 8), Double(cz * 16 + 8))
                if biomeDef(biome.rawValue).features.contains(where: { $0.hasPrefix("trees:") }) {
                    candidates.append((cx, cz))
                }
            }
        }
        XCTAssertFalse(candidates.isEmpty, "fixture must retain a nearby tree biome")

        var verifiedSeam = false
        for (centerCX, centerCZ) in candidates.prefix(6) where !verifiedSeam {
            var chunks: [EmittedChunkKey: GenOutput] = [:]
            for cz in (centerCZ - 1)...(centerCZ + 1) {
                for cx in (centerCX - 1)...(centerCX + 1) {
                    chunks[EmittedChunkKey(x: cx, z: cz)] = generateChunk(.overworld, fixture.seed, cx, cz,
                                                                            settings: fixture.settings)
                }
            }
            guard let center = chunks[EmittedChunkKey(x: centerCX, z: centerCZ)] else { continue }
            let region = EmittedRegion(seed: fixture.seed, chunks: chunks, settings: fixture.settings)
            var seamLeaves = 0
            for y in GEN_MIN_Y..<(GEN_MIN_Y + WORLD_H) {
                for z in 0..<16 {
                    for x in 0..<16 where x < 5 || x > 10 || z < 5 || z > 10 {
                        let index = ((y - GEN_MIN_Y) * 16 + z) * 16 + x
                        guard leafIDs.contains(Int(center.blocks[index] >> 4)) else { continue }
                        seamLeaves += 1
                        let worldX = centerCX * 16 + x
                        let worldZ = centerCZ * 16 + z
                        let isAnchored = (-6...6).contains { dx in
                            (-6...6).contains { dz in
                                ((y - 32)...(y + 2)).contains { logY in
                                    logIDs.contains(region.cell(worldX + dx, logY, worldZ + dz) >> 4)
                                }
                            }
                        }
                        XCTAssertTrue(isAnchored,
                                      "seam leaf at \(worldX),\(y),\(worldZ) has no tree log in its owning 3×3 output")
                    }
                }
            }
            verifiedSeam = seamLeaves > 0
        }
        XCTAssertTrue(verifiedSeam, "fixture must exercise a cross-chunk canopy")
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

    func testCanonicalCompleteRegionSelectsAtMostOneUnderwaterMember() {
        let maximumUnderwaterMembers = dungeonRegionPlannerLimits.maximumUnderwaterMembers
        XCTAssertEqual(maximumUnderwaterMembers, 1)
        var total = 0
        var underwater = 0
        for region in canonicalDungeonRegions {
            let summary = dungeonRegionBudgetSummary(seed: region.seed,
                                                     regionX: region.regionX,
                                                     regionZ: region.regionZ,
                                                     settings: region.settings)
            total += summary.rawAcceptedCount
            underwater += summary.underwaterSelectedCount
            XCTAssertLessThanOrEqual(summary.underwaterSelectedCount, maximumUnderwaterMembers,
                                     "the complete aligned region owns its deterministic underwater cap")
        }
        XCTAssertGreaterThanOrEqual(total, 256)
        XCTAssertGreaterThanOrEqual(underwater, 1)
        XCTAssertLessThanOrEqual(underwater, canonicalDungeonRegions.count * maximumUnderwaterMembers)
        XCTAssertTrue(dungeonUnderwaterBudgetSelected(seed: PinnedUnderwaterDungeonFixture.seed,
                                                      cx: PinnedUnderwaterDungeonFixture.cx,
                                                      cz: PinnedUnderwaterDungeonFixture.cz,
                                                      pass: PinnedUnderwaterDungeonFixture.pass))
    }

    func testCanonicalCompleteRegionCapsActualCommittedUnderwaterDungeonsAtOnePerRegion() {
        let maximumUnderwaterMembers = dungeonRegionPlannerLimits.maximumUnderwaterMembers
        var totalCommitted = 0
        var totalUnderwater = 0
        for region in canonicalDungeonRegions {
            var committed = 0
            var underwater = 0
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
            totalCommitted += committed
            totalUnderwater += underwater
            XCTAssertLessThanOrEqual(underwater, maximumUnderwaterMembers,
                                     "region (\(region.regionX),\(region.regionZ)) committed=\(committed) underwater=\(underwater)")
        }
        XCTAssertGreaterThanOrEqual(totalCommitted, 256)
        XCTAssertLessThanOrEqual(totalUnderwater,
                                 canonicalDungeonRegions.count * maximumUnderwaterMembers)
    }

    func testEveryDungeonDensityCapsSelectedUnderwaterMembersPerRegion() {
        let maximumUnderwaterMembers = dungeonRegionPlannerLimits.maximumUnderwaterMembers
        for density in DungeonDensity.allCases {
            let settings = WorldGenerationSettings(dungeonDensity: density)
            let summary = dungeonRegionBudgetSummary(seed: PinnedUnderwaterDungeonFixture.seed,
                                                     regionX: 2, regionZ: -4,
                                                     settings: settings)
            XCTAssertLessThanOrEqual(summary.underwaterSelectedCount, maximumUnderwaterMembers,
                                     "\(density.displayName) must use the same order-independent regional cap")
            if density == .none {
                XCTAssertEqual(summary.rawAcceptedCount, 0)
                XCTAssertEqual(summary.underwaterSelectedCount, 0)
            }
        }
    }

    func testFourBoundaryConcurrentRegionPlansStayWithinFixedResourceCaps() {
        let limits = dungeonRegionPlannerLimits
        XCTAssertEqual(limits.side, 32)
        XCTAssertEqual(limits.maximumPasses, 8)
        XCTAssertEqual(limits.maximumUnderwaterMembers, 1)
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
                    && $0.underwaterSelectedCount <= limits.maximumUnderwaterMembers
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

    func testMaxVillageEmitsAcrossItsCompleteReferenceWithCommunityAndSafeBuildingGeometry() {
        let fixture = FixedVillageDensityFixture.self
        let settings = fixture.settings(.max)
        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        let candidates = plannedVillages(in: fixture.originChunks, seed: fixture.seed,
                                         settings: settings)
        guard let firstCandidate = candidates.first(where: { candidate in
            let centerBiome = overworldGen(fixture.seed, settings: settings).surfaceBiomeAt(
                Double((candidate.reference.x0 + candidate.reference.x1) / 2),
                Double((candidate.reference.z0 + candidate.reference.z1) / 2))
            return centerBiome == .snowyPlains || centerBiome == .snowyTaiga
        }) else {
            return XCTFail("Max must retain a terrain-valid snowy village in the fixed Rich Resources envelope")
        }
        guard let village = STRUCTURES.first(where: { $0.id == "village" }) else {
            return XCTFail("village definition must be registered")
        }
        XCTAssertEqual(village.maxRadiusChunks, 8,
                       "village ref can reach eight chunks after centre selection")
        // Rebuild through normal chunk generation after selection.  This keeps
        // the assertions about production emission rather than the planner's
        // test oracle or cached closures. The first fixed candidate is snowy,
        // which also exercises climate-specific postprocessing over villagers
        // and penned livestock.
        resetStructurePlanCacheForTesting()
        let origin = generateChunk(.overworld, fixture.seed, firstCandidate.originCX, firstCandidate.originCZ,
                                   settings: settings)
        guard let reference = origin.structRefs.first(where: { sameVillageReference($0, firstCandidate.reference) }) else {
            return XCTFail("selected Max village must publish its ref in its origin chunk")
        }
        let emission = emittedVillageRegion(seed: fixture.seed,
                                            originCX: firstCandidate.originCX, originCZ: firstCandidate.originCZ,
                                            reference: reference, origin: origin, settings: settings)
        assertVillageReferenceEmissionIsComplete(emission, reference: reference)
        let centerBiome = overworldGen(fixture.seed, settings: settings).surfaceBiomeAt(
            Double((reference.x0 + reference.x1) / 2), Double((reference.z0 + reference.z1) / 2))
        XCTAssertTrue(centerBiome == .snowyPlains || centerBiome == .snowyTaiga,
                      "fixed first Max village must remain snowy to exercise visible snow-climate paths")
        let dirtPathID = Int(B.dirt_path)
        let emittedDirtPathCells = emission.chunks.values.reduce(into: 0) { total, output in
            total += output.blocks.reduce(into: 0) { count, value in
                if Int(value) >> 4 == dirtPathID { count += 1 }
            }
        }
        XCTAssertGreaterThan(emittedDirtPathCells, 24,
                             "snowy village must emit visible dirt-path cells, not terrain-colored snow roads")
        assertVillageDoesNotOverlapForeignSurfacePlans(seed: fixture.seed, settings: settings,
                                                       villageOriginCX: firstCandidate.originCX,
                                                       villageOriginCZ: firstCandidate.originCZ,
                                                       emission: emission, reference: reference)
        assertVillageEmissionIsPlayable(emission, reference: reference)
        assertVillageCommunityAndSpawnSafety(emission, reference: reference)
        assertVillageBuildingGeometry(emission, reference: reference)
    }

    func testFixedRealWorldVillageDensityIsMonotonicAcrossAllChoices() {
        let fixture = FixedVillageDensityFixture.self
        let densities = VillageDensity.allCases
        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        let plansByDensity = densities.map { density in
            plannedVillages(in: fixture.originChunks, seed: fixture.seed,
                            settings: fixture.settings(density))
        }
        let counts = plansByDensity.map(\.count)
        let countSummary = zip(densities, counts)
            .map { "\($0.0.displayName)=\($0.1)" }
            .joined(separator: ", ")
        XCTAssertEqual(counts.first, 0, "None must disable village planning; \(countSummary)")
        let noneOutput = generateChunk(.overworld, fixture.seed, 0, 0,
                                       settings: fixture.settings(.none))
        XCTAssertFalse(noneOutput.structRefs.contains { $0.id == "village" },
                       "None must suppress village references in ordinary chunk generation")
        for index in 1..<counts.count {
            XCTAssertGreaterThanOrEqual(counts[index], counts[index - 1],
                                        "fixed real-world village count regressed from \(densities[index - 1].displayName) to \(densities[index].displayName); \(countSummary)")
        }
        XCTAssertGreaterThan(counts.last ?? 0, 0,
                             "Max must yield at least one terrain-valid village in the fixed live-world envelope; \(countSummary)")
        guard let manyIndex = densities.firstIndex(of: .many) else {
            return XCTFail("VillageDensity must retain its Many option")
        }
        XCTAssertGreaterThanOrEqual(counts[manyIndex], 5,
                                    "Rich Resources Many must retain five complete grounded settlements in the fixed envelope; \(countSummary)")
        let maxPlans = plansByDensity.last ?? []
        // The deliberately expanded cave fields change terrain-valid sites:
        // this unchanged real seed/envelope now yields 0,0,3,5,7. Keep the
        // grounded-site checks rather than filling caves or weakening village
        // admission to reproduce the former terrain's minimum of eight.
        XCTAssertGreaterThanOrEqual(maxPlans.count, 7,
                                    "Cave-rich Resources Max must retain seven complete grounded settlements in the fixed envelope; \(countSummary)")
        XCTAssertGreaterThan(maxPlans.count, counts[manyIndex],
                             "Max must retain a visible density increase over Many; \(countSummary)")
        for firstIndex in maxPlans.indices {
            for secondIndex in maxPlans.indices where secondIndex > firstIndex {
                XCTAssertFalse(villageReferencesOverlap(maxPlans[firstIndex].reference,
                                                        maxPlans[secondIndex].reference),
                               "Max village refs overlap: \(maxPlans[firstIndex].originCX),\(maxPlans[firstIndex].originCZ) and \(maxPlans[secondIndex].originCX),\(maxPlans[secondIndex].originCZ)")
            }
        }
    }

    func testVillagePlannerUsesLegacyHeightClosureOnlyWithoutAnExactOracle() {
        // Normal chunk generation always supplies BaseTerrainOracle and must
        // therefore stay fail-closed on exact wet/unsupported terrain. This
        // covers the separate legacy/lookup contract: contexts deliberately
        // constructed without an oracle retain their supplied flat-height
        // estimate instead of making every village unlocatable.
        let context = GenCtx(seed: 0x1E6A_C0DE,
                             heightAt: { _, _ in 64 },
                             biomeAt: { _, _ in Biome.plains.rawValue },
                             dim: Dim.overworld.rawValue,
                             villageDensity: .max,
                             generationSettingsIdentity: "legacy-flat-village-no-oracle")
        guard let village = STRUCTURES.first(where: { $0.id == "village" }),
              let placement = village.placement(context) else {
            return XCTFail("Max village lookup must expose an active placement lattice")
        }
        resetStructurePlanCacheForTesting()
        defer { resetStructurePlanCacheForTesting() }
        var plan: StructurePlan?
        search: for regionZ in -2...2 {
            for regionX in -2...2 {
                let origin = structureOriginFor(village, placement: placement,
                                                 seed: context.seed,
                                                 regionX: regionX, regionZ: regionZ)
                if let candidate = getPlan(village, context, origin.0, origin.1) {
                    plan = candidate
                    break search
                }
            }
        }
        XCTAssertFalse(plan?.pieces.isEmpty ?? true,
                       "a flat no-oracle lookup context must retain a bounded village plan")
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

    func testSelectedUnderwaterDungeonRequiresWholeWaterloggedEnvelope() throws {
        let seed = PinnedUnderwaterDungeonFixture.seed
        let cx = PinnedUnderwaterDungeonFixture.cx
        let cz = PinnedUnderwaterDungeonFixture.cz
        let water = cell(B.water)

        // First materialize the deterministic selected candidate in an
        // all-water world. Its spawner is the final clamped room centre, so the
        // follow-up sinks alter exactly the production envelope rather than a
        // guessed raw candidate coordinate.
        let fullyWater = DungeonFootprintOwnershipSink(cx: cx, cz: cz, defaultCell: water)
        XCTAssertEqual(tryDungeons(seed, cx, cz, fullyWater, density: .normal), 1)
        let spawner = try XCTUnwrap(fullyWater.blockEntities.first { $0.kind == "spawner" })
        let center = DungeonOwnershipPoint(x: spawner.x, y: spawner.y, z: spawner.z)
        let upperCenter = DungeonOwnershipPoint(x: spawner.x, y: spawner.y + 1, z: spawner.z)
        let interior = DungeonOwnershipPoint(x: spawner.x + 1, y: spawner.y + 1, z: spawner.z)

        // A native water-filled aquatic plant is part of the valid water
        // envelope. This proves the admission predicate is waterlogged rather
        // than an accidental block-ID test.
        let waterloggedPlant = DungeonFootprintOwnershipSink(
            cx: cx, cz: cz, defaultCell: water,
            initialCells: [interior: cell(B.seagrass)]
        )
        XCTAssertEqual(tryDungeons(seed, cx, cz, waterloggedPlant, density: .normal), 1)

        // This was the former false positive: only the two old centre probes
        // contain water while the floor, shell, and remaining interior are
        // natural stone. No sealed room may now be emitted.
        let centerOnlyWater = DungeonFootprintOwnershipSink(
            cx: cx, cz: cz, defaultCell: cell(B.stone),
            initialCells: [center: water, upperCenter: water]
        )
        XCTAssertEqual(tryDungeons(seed, cx, cz, centerOnlyWater, density: .normal), 0)
        XCTAssertEqual(centerOnlyWater.writeCount, 0)
        XCTAssertTrue(centerOnlyWater.blockEntities.isEmpty)

        for (label, cellValue) in [("stone", cell(B.stone)), ("lava", cell(B.lava))] {
            let mixedEnvelope = DungeonFootprintOwnershipSink(
                cx: cx, cz: cz, defaultCell: water,
                initialCells: [interior: cellValue]
            )
            XCTAssertEqual(tryDungeons(seed, cx, cz, mixedEnvelope, density: .normal), 0,
                           "a \(label) cell in the sealed envelope must reject the room")
            XCTAssertEqual(mixedEnvelope.writeCount, 0)
            XCTAssertTrue(mixedEnvelope.blockEntities.isEmpty)
        }

        let existingOwner = BESpec(x: interior.x, y: interior.y, z: interior.z,
                                   kind: "preexisting_aquatic_structure_owner")
        let blockEntityOwned = DungeonFootprintOwnershipSink(
            cx: cx, cz: cz, defaultCell: water, existingBlockEntity: existingOwner
        )
        XCTAssertEqual(tryDungeons(seed, cx, cz, blockEntityOwned, density: .normal), 0)
        XCTAssertEqual(blockEntityOwned.writeCount, 0)
        XCTAssertEqual(blockEntityOwned.blockEntities.count, 1)
        XCTAssertEqual(blockEntityOwned.blockEntities.first?.kind, existingOwner.kind)
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

    func testDungeonPreflightPreservesExistingBlockEntityAndStructureCellWithoutDuplicates() throws {
        let seed = PriorClippedOrdinaryDungeonFixture.seed
        let cx = PriorClippedOrdinaryDungeonFixture.cx
        let cz = PriorClippedOrdinaryDungeonFixture.cz

        // Let the production pass choose its deterministic centre first. The
        // all-air input is only a discovery fixture; the asserted runs below
        // use a single exact cave entrance in otherwise natural stone.
        let discovery = DungeonFootprintOwnershipSink(cx: cx, cz: cz, defaultCell: 0)
        XCTAssertEqual(tryDungeons(seed, cx, cz, discovery, density: .normal), 1)
        let spawner = try XCTUnwrap(discovery.blockEntities.first { $0.kind == "spawner" })
        let primaryChest = try XCTUnwrap(discovery.blockEntities.first {
            $0.kind == "chest_loot" && $0.x > spawner.x && $0.z > spawner.z
        })
        let halfWidth = primaryChest.x - spawner.x + 1
        XCTAssertTrue((3...4).contains(halfWidth),
                      "the reviewed dungeon fixture must retain a standard room half-width")

        // A two-high west opening at this exact centre is the controlled
        // fixture's sole valid entrance. That turns the next calls into a
        // precise preflight check rather than merely showing that some other
        // candidate happened not to overwrite the target.
        let openingX = spawner.x - halfWidth - 1
        let openings: Set<DungeonOwnershipPoint> = [
            DungeonOwnershipPoint(x: openingX, y: spawner.y, z: spawner.z),
            DungeonOwnershipPoint(x: openingX, y: spawner.y + 1, z: spawner.z),
        ]
        let control = DungeonFootprintOwnershipSink(cx: cx, cz: cz,
                                                    defaultCell: cell(B.stone),
                                                    openings: openings)
        XCTAssertEqual(tryDungeons(seed, cx, cz, control, density: .normal), 1,
                       "the constrained fixture must materialize the discovered candidate before blocking it")

        let existingOwner = BESpec(x: spawner.x, y: spawner.y, z: spawner.z,
                                   kind: "preexisting_structure_owner")
        let ownershipBlocked = DungeonFootprintOwnershipSink(
            cx: cx, cz: cz, defaultCell: cell(B.stone), openings: openings,
            existingBlockEntity: existingOwner
        )
        XCTAssertEqual(tryDungeons(seed, cx, cz, ownershipBlocked, density: .normal), 0,
                       "a preexisting block entity inside the candidate footprint must reject the whole dungeon")
        XCTAssertEqual(ownershipBlocked.writeCount, 0,
                       "a rejected dungeon must not overwrite any owned structure cells")
        XCTAssertEqual(ownershipBlocked.blockEntities.count, 1,
                       "a rejected detached build must not leave stale dungeon block entities behind")
        guard let preservedOwner = ownershipBlocked.blockEntities.first else { return }
        XCTAssertEqual(preservedOwner.kind, existingOwner.kind)
        XCTAssertEqual(preservedOwner.x, existingOwner.x)
        XCTAssertEqual(preservedOwner.y, existingOwner.y)
        XCTAssertEqual(preservedOwner.z, existingOwner.z)
        XCTAssertEqual(ownershipBlocked.get(spawner.x, spawner.y, spawner.z), Int(cell(B.stone)),
                       "the ownership-only case isolates block-entity protection from material filtering")

        let structureCell = cell(B.crafting_table)
        let structureBlocked = DungeonFootprintOwnershipSink(
            cx: cx, cz: cz, defaultCell: cell(B.stone), openings: openings,
            existingCell: (point: DungeonOwnershipPoint(x: spawner.x,
                                                         y: spawner.y,
                                                         z: spawner.z),
                           value: structureCell)
        )
        XCTAssertEqual(tryDungeons(seed, cx, cz, structureBlocked, density: .normal), 0,
                       "a preexisting structure cell inside the candidate footprint must reject the whole dungeon")
        XCTAssertEqual(structureBlocked.writeCount, 0)
        XCTAssertTrue(structureBlocked.blockEntities.isEmpty,
                      "a rejected detached build must not leave stale dungeon block entities behind")
        XCTAssertEqual(structureBlocked.get(spawner.x, spawner.y, spawner.z), Int(structureCell),
                       "the protected structure cell must remain intact")
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

    /// Plans a bounded, literal terrain envelope using the same base-terrain
    /// oracle and placement code as ordinary Overworld generation.  It counts
    /// only origins inside the envelope, rather than allowing an adjacent
    /// lattice cell to inflate one density's result.
    private func realTerrainStructureContext(seed: UInt32,
                                             settings: WorldGenerationSettings) -> GenCtx {
        let gen = overworldGen(seed, settings: settings)
        // This budget allows a bounded test to evaluate every actual
        // terrain-gated candidate without turning a temporary oracle limit
        // into a false density or collision result.
        let oracle = BaseTerrainOracle(seed: seed, settings: settings,
                                       maxCachedChunks: 2_048, maxQueries: 1_500_000)
        return GenCtx(seed: seed,
                      heightAt: { x, z in oracle.topSolidY(x, z).map { $0 + 1 }
                          ?? gen.refinedHeightEstimate(Double(x), Double(z)) },
                      biomeAt: { x, z in gen.surfaceBiomeAt(Double(x), Double(z)).rawValue },
                      dim: Dim.overworld.rawValue,
                      villageDensity: settings.villageDensity,
                      generationSettingsIdentity: settings.cacheIdentity,
                      baseTerrainOracleVersion: baseTerrainOracleVersion,
                      terrainOracle: oracle)
    }

    private func plannedVillages(in originChunks: ClosedRange<Int>, seed: UInt32,
                                 settings: WorldGenerationSettings) -> [PlannedVillageCandidate] {
        guard let village = STRUCTURES.first(where: { $0.id == "village" }) else {
            XCTFail("village definition must be registered")
            return []
        }
        let context = realTerrainStructureContext(seed: seed, settings: settings)
        guard let placement = village.placement(context) else { return [] }
        let regionX = floorDiv(originChunks.lowerBound, placement.spacing)...floorDiv(originChunks.upperBound, placement.spacing)
        let regionZ = floorDiv(originChunks.lowerBound, placement.spacing)...floorDiv(originChunks.upperBound, placement.spacing)
        var planned: [PlannedVillageCandidate] = []
        for rz in regionZ {
            for rx in regionX {
                let origin = structureOriginFor(village, placement: placement,
                                                 seed: seed, regionX: rx, regionZ: rz)
                guard originChunks.contains(origin.0), originChunks.contains(origin.1),
                      let plan = getPlan(village, context, origin.0, origin.1),
                      let box = plan.ref else { continue }
                planned.append(PlannedVillageCandidate(
                    originCX: origin.0, originCZ: origin.1,
                    reference: StructRef(id: "village", x0: box.x0, y0: box.y0, z0: box.z0,
                                         x1: box.x1, y1: box.y1, z1: box.z1)))
            }
        }
        return planned
    }

    private func emittedVillageRegion(seed: UInt32, originCX: Int, originCZ: Int,
                                      reference: StructRef, origin: GenOutput,
                                      settings: WorldGenerationSettings = .normal) -> EmittedRegion {
        let minCX = floorDiv(reference.x0, 16), maxCX = floorDiv(reference.x1, 16)
        let minCZ = floorDiv(reference.z0, 16), maxCZ = floorDiv(reference.z1, 16)
        var chunks: [EmittedChunkKey: GenOutput] = [:]
        for cz in minCZ...maxCZ {
            for cx in minCX...maxCX {
                let key = EmittedChunkKey(x: cx, z: cz)
                chunks[key] = (cx == originCX && cz == originCZ)
                    ? origin
                    : generateChunk(.overworld, seed, cx, cz, settings: settings)
            }
        }
        return EmittedRegion(seed: seed, chunks: chunks, settings: settings)
    }

    private func sameVillageReference(_ lhs: StructRef, _ rhs: StructRef) -> Bool {
        lhs.id == "village" && rhs.id == "village"
            && lhs.x0 == rhs.x0 && lhs.y0 == rhs.y0 && lhs.z0 == rhs.z0
            && lhs.x1 == rhs.x1 && lhs.y1 == rhs.y1 && lhs.z1 == rhs.z1
    }

    /// A village ref is published on every chunk it intersects.  This is the
    /// observable full-radius contract: a player entering from an edge chunk
    /// must see the same village identity as a player at its centre.
    private func assertVillageReferenceEmissionIsComplete(_ emission: EmittedRegion,
                                                           reference: StructRef,
                                                           file: StaticString = #filePath,
                                                           line: UInt = #line) {
        let minCX = floorDiv(reference.x0, 16), maxCX = floorDiv(reference.x1, 16)
        let minCZ = floorDiv(reference.z0, 16), maxCZ = floorDiv(reference.z1, 16)
        XCTAssertEqual(emission.chunks.count, (maxCX - minCX + 1) * (maxCZ - minCZ + 1),
                       "test must materialize every chunk intersecting the village ref", file: file, line: line)
        for cz in minCZ...maxCZ {
            for cx in minCX...maxCX {
                let key = EmittedChunkKey(x: cx, z: cz)
                guard let output = emission.chunks[key] else {
                    XCTFail("missing materialized village edge chunk \(cx),\(cz)", file: file, line: line)
                    continue
                }
                let matching = output.structRefs.filter { sameVillageReference($0, reference) }
                XCTAssertEqual(matching.count, 1,
                               "village ref must be emitted exactly once in full-radius chunk \(cx),\(cz)",
                               file: file, line: line)
            }
        }
    }

    /// Replays the same bounded foreign-surface plan window as normal village
    /// planning, then compares real piece footprints. A reference box alone is
    /// deliberately not treated as a collision: village refs include an
    /// eight-chunk discovery radius and are broader than constructed streets
    /// and buildings. The assertion therefore catches actual overwrites while
    /// allowing nearby, non-overlapping landmarks to remain valid world detail.
    private func assertVillageDoesNotOverlapForeignSurfacePlans(seed: UInt32,
                                                                 settings: WorldGenerationSettings,
                                                                 villageOriginCX: Int,
                                                                 villageOriginCZ: Int,
                                                                 emission: EmittedRegion,
                                                                 reference: StructRef,
                                                                 file: StaticString = #filePath,
                                                                 line: UInt = #line) {
        let foreignSurfaceIDs: Set<String> = [
            "desert_temple", "jungle_temple", "igloo", "witch_hut", "pillager_outpost",
            "shipwreck", "ocean_ruin", "buried_treasure", "ruined_portal", "trail_ruins",
            "ocean_monument", "woodland_mansion",
        ]
        guard let village = STRUCTURES.first(where: { $0.id == "village" }) else {
            return XCTFail("village definition must be registered", file: file, line: line)
        }
        let context = realTerrainStructureContext(seed: seed, settings: settings)
        guard let villagePlan = getPlan(village, context, villageOriginCX, villageOriginCZ) else {
            return XCTFail("published village ref must retain its deterministic plan", file: file, line: line)
        }
        guard let minX = villagePlan.pieces.map(\.x0).min(), let maxX = villagePlan.pieces.map(\.x1).max(),
              let minZ = villagePlan.pieces.map(\.z0).min(), let maxZ = villagePlan.pieces.map(\.z1).max() else {
            return XCTFail("village plan must contain concrete surface pieces", file: file, line: line)
        }
        let minChunkX = floorDiv(minX, 16), maxChunkX = floorDiv(maxX, 16)
        let minChunkZ = floorDiv(minZ, 16), maxChunkZ = floorDiv(maxZ, 16)
        func intersectsXZ(_ lhs: StructPiece, _ rhs: StructPiece) -> Bool {
            !(lhs.x1 < rhs.x0 || rhs.x1 < lhs.x0 || lhs.z1 < rhs.z0 || rhs.z1 < lhs.z0)
        }
        func pieceIntersectsMaterializedRegion(_ piece: StructPiece) -> Bool {
            !(piece.x1 < reference.x0 || reference.x1 < piece.x0
                || piece.z1 < reference.z0 || reference.z1 < piece.z0)
        }
        let emittedForeignReferences = Set(emission.chunks.values.flatMap(\.structRefs).compactMap { ref -> String? in
            guard foreignSurfaceIDs.contains(ref.id) else { return nil }
            return "\(ref.id):\(ref.x0):\(ref.y0):\(ref.z0):\(ref.x1):\(ref.y1):\(ref.z1)"
        }).sorted()

        for foreign in STRUCTURES where foreignSurfaceIDs.contains(foreign.id) {
            guard let placement = foreign.placement(context) else { continue }
            let radius = foreign.maxRadiusChunks
            let regionX = floorDiv(minChunkX - radius, placement.spacing)...floorDiv(maxChunkX + radius, placement.spacing)
            let regionZ = floorDiv(minChunkZ - radius, placement.spacing)...floorDiv(maxChunkZ + radius, placement.spacing)
            for rz in regionZ {
                for rx in regionX {
                    let origin = structureOriginFor(foreign, placement: placement, seed: seed,
                                                     regionX: rx, regionZ: rz)
                    guard origin.0 >= minChunkX - radius, origin.0 <= maxChunkX + radius,
                          origin.1 >= minChunkZ - radius, origin.1 <= maxChunkZ + radius,
                          let foreignPlan = getPlan(foreign, context, origin.0, origin.1),
                          foreignPlan.pieces.contains(where: pieceIntersectsMaterializedRegion) else {
                        continue
                    }
                    let overlaps = villagePlan.pieces.contains { villagePiece in
                        foreignPlan.pieces.contains { foreignPiece in intersectsXZ(villagePiece, foreignPiece) }
                    }
                    XCTAssertFalse(overlaps,
                                   "village pieces overlap emitted surface plan \(foreign.id) at origin \(origin.0),\(origin.1); emitted foreign refs=\(emittedForeignReferences)",
                                   file: file, line: line)
                }
            }
        }
    }

    private func villageReferencesOverlap(_ lhs: StructRef, _ rhs: StructRef) -> Bool {
        !(lhs.x1 < rhs.x0 || rhs.x1 < lhs.x0 || lhs.z1 < rhs.z0 || rhs.z1 < lhs.z0)
    }

    private func villageEntities(in emission: EmittedRegion, reference: StructRef) -> [EntitySpec] {
        let villageMobs: Set<String> = ["villager", "iron_golem", "cat", "camel",
                                        "cow", "sheep", "pig", "chicken", "goat", "donkey"]
        return emission.entities.filter { entity in
            villageMobs.contains(entity.mob)
                && entity.x >= Double(reference.x0) && entity.x <= Double(reference.x1 + 1)
                && entity.z >= Double(reference.z0) && entity.z <= Double(reference.z1 + 1)
        }
    }

    private func assertVillageCommunityAndSpawnSafety(_ emission: EmittedRegion,
                                                       reference: StructRef,
                                                       file: StaticString = #filePath,
                                                       line: UInt = #line) {
        let entities = villageEntities(in: emission, reference: reference)
        let adults = entities.filter { $0.mob == "villager" && $0.data["baby"] != .bool(true) }
        let children = entities.filter { $0.mob == "villager" && $0.data["baby"] == .bool(true) }
        let golems = entities.filter { $0.mob == "iron_golem" }
        let livestockMobs: Set<String> = ["cow", "sheep", "pig", "chicken", "goat", "camel", "donkey"]
        // The dedicated village pen marks its residents persistent.  That
        // prevents coincidental biome-spawned animals in the ref from making a
        // decorative village appear inhabited.
        let livestock = entities.filter {
            livestockMobs.contains($0.mob) && $0.data["persistent"] == .bool(true)
        }
        XCTAssertGreaterThanOrEqual(adults.count, 4,
                                    "accepted village must contain four adult resident homes", file: file, line: line)
        XCTAssertGreaterThanOrEqual(children.count, 1,
                                    "accepted village must contain a child villager", file: file, line: line)
        XCTAssertGreaterThanOrEqual(golems.count, 1,
                                    "accepted village must contain an iron golem", file: file, line: line)
        XCTAssertGreaterThanOrEqual(livestock.count, 2,
                                    "accepted village must contain persistent livestock in its pen", file: file, line: line)

        for entity in adults + children + golems + livestock {
            let x = Int(entity.x.rounded(.down))
            let y = Int(entity.y.rounded(.down))
            let z = Int(entity.z.rounded(.down))
            XCTAssertTrue(isDrySolid(emission.cell(x, y - 1, z)),
                          "village \(entity.mob) lacks dry footing at \(x),\(y - 1),\(z)",
                          file: file, line: line)
            let requiredClearance = entity.mob == "iron_golem" ? 3 : 2
            for dy in 0..<requiredClearance {
                XCTAssertTrue(isOpen(emission.cell(x, y + dy, z)),
                              "village \(entity.mob) intersects a block at \(x),\(y + dy),\(z)",
                              file: file, line: line)
            }
        }
    }

    private func assertVillageBuildingGeometry(_ emission: EmittedRegion,
                                                reference: StructRef,
                                                file: StaticString = #filePath,
                                                line: UInt = #line) {
        var lowerDoors = 0
        var supportedStairs = 0
        for z in reference.z0...reference.z1 {
            for x in reference.x0...reference.x1 {
                for y in reference.y0...reference.y1 {
                    let value = emission.cell(x, y, z)
                    let id = blockID(value)
                    guard id >= 0 && id < blockDefs.count else { continue }
                    let name = blockDefs[id].name
                    if name.hasSuffix("_door") {
                        let isUpper = (value & 8) != 0
                        if isUpper {
                            let lower = emission.cell(x, y - 1, z)
                            XCTAssertEqual(blockID(lower), id,
                                           "upper door half lacks its matching lower half at \(x),\(y),\(z)",
                                           file: file, line: line)
                            XCTAssertEqual(lower & 8, 0,
                                           "upper door half is paired with another upper half at \(x),\(y),\(z)",
                                           file: file, line: line)
                        } else {
                            lowerDoors += 1
                            let upper = emission.cell(x, y + 1, z)
                            XCTAssertEqual(blockID(upper), id,
                                           "lower door half lacks its matching upper half at \(x),\(y),\(z)",
                                           file: file, line: line)
                            XCTAssertNotEqual(upper & 8, 0,
                                              "door upper half is not marked upper at \(x),\(y + 1),\(z)",
                                              file: file, line: line)
                            XCTAssertTrue(isDrySolid(emission.cell(x, y - 1, z)),
                                          "door threshold lacks dry support at \(x),\(y - 1),\(z)",
                                          file: file, line: line)
                            let approachDirections = [(dx: -1, dz: 0), (dx: 1, dz: 0),
                                                      (dx: 0, dz: -1), (dx: 0, dz: 1)]
                            let hasSupportedApproach = approachDirections.contains { direction in
                                let stair = emission.cell(x + direction.dx, y - 1, z + direction.dz)
                                let stairID = blockID(stair)
                                return stairID >= 0 && stairID < blockDefs.count
                                    && blockDefs[stairID].name.hasSuffix("_stairs")
                                    && isDrySolid(emission.cell(x + direction.dx, y - 2, z + direction.dz))
                            }
                            XCTAssertTrue(hasSupportedApproach,
                                          "door lacks a supported adjacent approach stair at \(x),\(y),\(z)",
                                          file: file, line: line)
                        }
                    }
                    if name.hasSuffix("_stairs") {
                        supportedStairs += 1
                        XCTAssertTrue(isDrySolid(emission.cell(x, y - 1, z)),
                                      "building stair lacks direct dry support at \(x),\(y - 1),\(z)",
                                      file: file, line: line)
                    }
                }
            }
        }
        XCTAssertGreaterThanOrEqual(lowerDoors, 4,
                                    "inhabited village must expose paired doors for its resident buildings",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(supportedStairs, lowerDoors,
                                    "every resident door should have a supported approach stair",
                                    file: file, line: line)
    }

    /// Reconstructs village playability exclusively from normal emitted chunks.
    /// Structure candidates, planned pieces, and the production validator are not
    /// consulted. The reference supplies only the finite scan boundary.
    private func assertVillageEmissionIsPlayable(_ emission: EmittedRegion,
                                                  reference: StructRef,
                                                  file: StaticString = #filePath,
                                                  line: UInt = #line) {
        var roadFeet: [EmittedPosition] = []
        var roadBaseHeights: [Int] = []
        var roadByColumn: [EmittedPosition: EmittedPosition] = [:]
        var baseChunks: [EmittedChunkKey: BaseTerrainChunk] = [:]
        let centerX = (reference.x0 + reference.x1) / 2
        let centerZ = (reference.z0 + reference.z1) / 2

        // Road material is style-specific, and desert sandstone can occur
        // naturally. Instead of conflating a block ID with a road, find the
        // emitted three-wide, cardinal, grade-bounded walking corridors
        // radiating from the observable village centre and compare their decks
        // with exact pre-structure terrain. A separate snowy-style assertion
        // above proves the intentionally visible dirt-path material.
        func baseTerrain(at x: Int, _ z: Int) -> BaseTerrainChunk {
            let key = EmittedChunkKey(x: floorDiv(x, 16), z: floorDiv(z, 16))
            if let cached = baseChunks[key] { return cached }
            let built = buildBaseTerrainChunk(seed: emission.seed, cx: key.x, cz: key.z,
                                              settings: emission.settings)
            baseChunks[key] = built
            return built
        }
        func highestWalkableFeet(at x: Int, _ z: Int) -> EmittedPosition? {
            let minFeetY = max(GEN_MIN_Y + 1, reference.y0)
            let maxFeetY = min(GEN_MIN_Y + WORLD_H - 2, reference.y1)
            guard minFeetY <= maxFeetY else { return nil }
            for y in stride(from: maxFeetY, through: minFeetY, by: -1) {
                guard isDrySolid(emission.cell(x, y - 1, z)),
                      isOpen(emission.cell(x, y, z)),
                      isOpen(emission.cell(x, y + 1, z)) else { continue }
                return EmittedPosition(x: x, y: y, z: z)
            }
            return nil
        }

        var radialArms = 0
        var alteredRoadColumns = 0
        for (dx, dz) in [(dx: -1, dz: 0), (dx: 1, dz: 0),
                         (dx: 0, dz: -1), (dx: 0, dz: 1)] {
            var armFeet: [EmittedPosition] = []
            var armBaseHeights: [Int] = []
            var previousLevel: Int?
            var alteredArmColumns = 0
            for distance in 5...40 {
                var row: [EmittedPosition] = []
                for width in -1...1 {
                    let x = centerX + dx * distance + (dz != 0 ? width : 0)
                    let z = centerZ + dz * distance + (dx != 0 ? width : 0)
                    guard let feet = highestWalkableFeet(at: x, z) else {
                        row.removeAll()
                        break
                    }
                    row.append(feet)
                }
                guard row.count == 3,
                      Set(row.map(\.y)).count == 1,
                      previousLevel.map({ abs($0 - row[0].y) <= 1 }) ?? true else {
                    break
                }
                // A frozen lake can form a natural three-wide, level walking
                // surface beyond a compact street's deliberate endpoint.  It
                // is not an emitted road: require the current whole row to
                // differ from exact pre-structure terrain before extending the
                // observable corridor.  This keeps the scanner independent of
                // a particular road material while preventing it from treating
                // native ice/sand/snow as unsafe village construction.
                let rowIsConstructed = row.allSatisfy { feet in
                    let base = baseTerrain(at: feet.x, feet.z)
                    return emission.cell(feet.x, feet.y - 1, feet.z)
                        != base.cell(worldX: feet.x, y: feet.y - 1, worldZ: feet.z)
                }
                guard rowIsConstructed else { break }
                previousLevel = row[0].y
                for feet in row {
                    let base = baseTerrain(at: feet.x, feet.z)
                    guard let baseY = base.topSolidY(worldX: feet.x, worldZ: feet.z) else {
                        XCTFail("road column has no base-terrain support", file: file, line: line)
                        continue
                    }
                    let deckY = feet.y - 1
                    guard deckY >= baseY else {
                        XCTFail("road deck tunnels into base terrain", file: file, line: line)
                        continue
                    }
                    XCTAssertLessThanOrEqual(deckY - baseY, 4,
                                             "road terrace exceeds bounded fill", file: file, line: line)
                    for supportY in baseY...deckY {
                        XCTAssertTrue(isDrySolid(emission.cell(feet.x, supportY, feet.z)),
                                      "road has dry-support gap at \(feet.x),\(supportY),\(feet.z)",
                                      file: file, line: line)
                    }
                    if emission.cell(feet.x, deckY, feet.z)
                        != base.cell(worldX: feet.x, y: deckY, worldZ: feet.z) {
                        alteredArmColumns += 1
                    }
                    armBaseHeights.append(baseY)
                    roadByColumn[EmittedPosition(x: feet.x, y: 0, z: feet.z)] = feet
                }
                armFeet.append(contentsOf: row)
            }
            // A full road is at least 15 three-wide rows.  This validates
            // geometric continuity rather than treating a native snow/sand
            // surface with the same material ID as a settlement road.
            if armFeet.count >= 45 {
                radialArms += 1
                alteredRoadColumns += alteredArmColumns
                roadBaseHeights.append(contentsOf: armBaseHeights)
                XCTAssertGreaterThanOrEqual(alteredArmColumns, 15,
                                              "radial corridor must contain constructed deck cells, not only native terrain",
                                              file: file, line: line)
                roadFeet.append(contentsOf: armFeet)
            }
        }

        // A full village has three or four arms.  Its terrain-safe compact
        // fallback retains two opposing complete streets, which is enough to
        // reach every resident and pen without requiring an unsafe third
        // hillside cut merely to satisfy a decorative layout minimum.
        XCTAssertGreaterThanOrEqual(radialArms, 2,
                                    "accepted village or compact hamlet must expose two emitted radial roads",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(roadFeet.count, 90,
                                    "accepted village or compact hamlet must expose complete three-wide road geometry",
                                    file: file, line: line)
        XCTAssertGreaterThan(alteredRoadColumns, 24,
                             "roads must materially alter their exact base-terrain columns",
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
