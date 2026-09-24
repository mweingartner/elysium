// Chunk generation orchestrator — every
// dimension, structures included. Returns transferable arrays + block entity /
// entity / structure specs.

import Foundation

public struct GenOutput {
    public let blocks: [UInt16]
    public let biomes: [UInt8]
    public let blockEntities: [BESpec]
    public let entities: [EntitySpec]
    public let structRefs: [StructRef]
    public var naturalTreeCells: [Int: NaturalTreeCell] = [:]
}

/// Immutable terrain state immediately before structures and features. Both
/// ordinary chunk generation and structure validation use this exact function.
public struct BaseTerrainChunk {
    public let cx: Int
    public let cz: Int
    public let blocks: [UInt16]
    public let biomes: [UInt8]
    public let heights: [Int16]
    public let surfaceBiomes: [UInt8]

    @inline(__always)
    public func cell(worldX x: Int, y: Int, worldZ z: Int) -> Int? {
        guard floorDiv(x, 16) == cx, floorDiv(z, 16) == cz,
              y >= GEN_MIN_Y, y < GEN_MIN_Y + WORLD_H else { return nil }
        let lx = x - cx * 16, lz = z - cz * 16
        return Int(blocks[((y - GEN_MIN_Y) * 16 + lz) * 16 + lx])
    }

    public func topSolidY(worldX x: Int, worldZ z: Int) -> Int? {
        guard floorDiv(x, 16) == cx, floorDiv(z, 16) == cz else { return nil }
        let lx = x - cx * 16, lz = z - cz * 16
        for y in stride(from: GEN_MIN_Y + WORLD_H - 1, through: GEN_MIN_Y, by: -1) {
            let c = blocks[((y - GEN_MIN_Y) * 16 + lz) * 16 + lx]
            let id = Int(c >> 4)
            if c != 0, id != Int(B.water), id != Int(B.lava), SOLID[id] == 1 { return y }
        }
        return nil
    }

    public func highestOccupiedCell(worldX x: Int, worldZ z: Int) -> (y: Int, cell: Int)? {
        guard floorDiv(x, 16) == cx, floorDiv(z, 16) == cz else { return nil }
        let lx = x - cx * 16, lz = z - cz * 16
        for y in stride(from: GEN_MIN_Y + WORLD_H - 1, through: GEN_MIN_Y, by: -1) {
            let c = Int(blocks[((y - GEN_MIN_Y) * 16 + lz) * 16 + lx])
            if c != 0 { return (y, c) }
        }
        return nil
    }
}

public let baseTerrainOracleVersion = 1

/// Exact-terrain structure planning is deliberately isolated from the
/// caller's transient oracle work. A generation pass can survey many
/// candidate sites before it reaches a particular plan; letting that shared
/// query budget decide whether the plan is cacheable made the result depend
/// on chunk/evaluation order. Each plan instead receives this fixed, bounded
/// oracle budget derived solely from immutable world settings.
public let structurePlanOracleMaxCachedChunks = 128
public let structurePlanOracleMaxQueries = 128_000

/// Exact pre-structure terrain for one Overworld column. `feetY` is the
/// walkable height directly above the highest solid base-terrain cell. A
/// column is dry only when that solid cell is also the highest occupied cell;
/// this keeps surface structures from treating water or lava as ground.
public struct ExactTerrainSurface: Equatable {
    public let feetY: Int
    public let isDry: Bool
}

/// The superflat layer stack is also the authoritative pre-structure terrain
/// for structure planning.  Keeping it in the base-terrain path gives a
/// village the same exact-ground oracle that a noise-based world receives;
/// otherwise its dry-site validation correctly rejects every flat-world plan
/// because it has no terrain data to inspect.
private func buildFlatBaseTerrainChunk(cx: Int, cz: Int) -> BaseTerrainChunk {
    let info = DIMS[Dim.overworld.rawValue]
    var blocks = [UInt16](repeating: 0, count: CHUNK_W * CHUNK_W * info.height)
    let bedrock = cell(B.bedrock)
    let dirt = cell(B.dirt)
    let grass = cell(B.grass_block)
    for z in 0..<16 {
        for x in 0..<16 {
            blocks[((GEN_MIN_Y - info.minY) * 16 + z) * 16 + x] = bedrock
            blocks[((GEN_MIN_Y + 1 - info.minY) * 16 + z) * 16 + x] = dirt
            blocks[((GEN_MIN_Y + 2 - info.minY) * 16 + z) * 16 + x] = dirt
            blocks[((GEN_MIN_Y + 3 - info.minY) * 16 + z) * 16 + x] = grass
        }
    }
    return BaseTerrainChunk(
        cx: cx,
        cz: cz,
        blocks: blocks,
        biomes: filledBiomeQuarts(.plains, height: info.height),
        heights: [Int16](repeating: Int16(GEN_MIN_Y + 3), count: CHUNK_W * CHUNK_W),
        surfaceBiomes: [UInt8](repeating: UInt8(Biome.plains.rawValue), count: CHUNK_W * CHUNK_W)
    )
}

public func buildBaseTerrainChunk(seed: UInt32, cx: Int, cz: Int,
                                  settings: WorldGenerationSettings = .normal) -> BaseTerrainChunk {
    let recursionKey = "ElysiumCore.buildBaseTerrainChunk.active"
    precondition(Thread.current.threadDictionary[recursionKey] == nil,
                 "base terrain generation must remain a non-reentrant leaf")
    Thread.current.threadDictionary[recursionKey] = true
    defer { Thread.current.threadDictionary.removeObject(forKey: recursionKey) }
    if settings.preset == .flat {
        return buildFlatBaseTerrainChunk(cx: cx, cz: cz)
    }
    precondition(settings.preset != .debugAllBlockStates,
                 "base terrain oracle is not defined for the debug block-state preset")
    let info = DIMS[Dim.overworld.rawValue]
    var blocks = [UInt16](repeating: 0, count: CHUNK_W * CHUNK_W * info.height)
    var biomes = [UInt8](repeating: 0, count: 4 * 4 * ((info.height + 3) / 4))
    let gen = overworldGen(seed, settings: settings)
    let result = gen.fillTerrain(cx, cz, &blocks, &biomes)
    gen.carve(cx, cz, &blocks)
    gen.applySurface(cx, cz, &blocks, result.heights, result.surfaceBiomes)
    gen.placeOres(cx, cz, &blocks, result.surfaceBiomes)
    return BaseTerrainChunk(cx: cx, cz: cz, blocks: blocks, biomes: biomes,
                            heights: result.heights, surfaceBiomes: result.surfaceBiomes)
}

/// Plan-local, bounded memoization over exact pre-structure chunks. A miss is
/// built outside the lock, then installed only if another caller did not win.
public final class BaseTerrainOracle {
    public let seed: UInt32
    public let settings: WorldGenerationSettings
    public let maxCachedChunks: Int
    public let maxQueries: Int

    private let lock = NSLock()
    private var chunks: [ChunkCoord: BaseTerrainChunk] = [:]
    private var order: [ChunkCoord] = []
    private var queryCount = 0

    private struct ChunkCoord: Hashable { let x: Int; let z: Int }

    public init(seed: UInt32, settings: WorldGenerationSettings,
                maxCachedChunks: Int = 128, maxQueries: Int = 32_768) {
        self.seed = seed
        self.settings = settings
        self.maxCachedChunks = max(1, maxCachedChunks)
        self.maxQueries = max(1, maxQueries)
    }

    public var observedQueryCount: Int { lock.withLock { queryCount } }
    public var cachedChunkCount: Int { lock.withLock { chunks.count } }

    public func chunk(cx: Int, cz: Int) -> BaseTerrainChunk? {
        let key = ChunkCoord(x: cx, z: cz)
        if let existing = lock.withLock({ chunks[key] }) { return existing }
        let built = buildBaseTerrainChunk(seed: seed, cx: cx, cz: cz, settings: settings)
        return lock.withLock {
            if let existing = chunks[key] { return existing }
            if chunks.count >= maxCachedChunks, let evicted = order.first {
                order.removeFirst()
                chunks.removeValue(forKey: evicted)
            }
            chunks[key] = built
            order.append(key)
            return built
        }
    }

    public func cell(_ x: Int, _ y: Int, _ z: Int) -> Int? {
        guard consumeQuery() else { return nil }
        return chunk(cx: floorDiv(x, 16), cz: floorDiv(z, 16))?.cell(worldX: x, y: y, worldZ: z)
    }

    public func topSolidY(_ x: Int, _ z: Int) -> Int? {
        guard consumeQuery() else { return nil }
        return chunk(cx: floorDiv(x, 16), cz: floorDiv(z, 16))?.topSolidY(worldX: x, worldZ: z)
    }


    public func highestOccupiedCell(_ x: Int, _ z: Int) -> (y: Int, cell: Int)? {
        guard consumeQuery() else { return nil }
        return chunk(cx: floorDiv(x, 16), cz: floorDiv(z, 16))?.highestOccupiedCell(worldX: x, worldZ: z)
    }

    /// Reads both the highest solid cell and the highest occupied cell from
    /// one cached base-terrain chunk under a single query-budget charge.
    /// Planning uses this instead of composing `topSolidY` and
    /// `highestOccupiedCell`, which would double bounded-oracle cost for
    /// every surveyed column.
    public func exactSurface(_ x: Int, _ z: Int) -> ExactTerrainSurface? {
        guard consumeQuery(),
              let terrain = chunk(cx: floorDiv(x, 16), cz: floorDiv(z, 16)),
              let solidY = terrain.topSolidY(worldX: x, worldZ: z),
              let occupied = terrain.highestOccupiedCell(worldX: x, worldZ: z) else {
            return nil
        }
        let occupiedID = occupied.cell >> 4
        let isDry = occupied.y == solidY
            && occupiedID != Int(B.water)
            && occupiedID != Int(B.lava)
        return ExactTerrainSurface(feetY: solidY + 1, isDry: isDry)
    }

    private func consumeQuery() -> Bool {
        lock.withLock {
            guard queryCount < maxQueries else { return false }
            queryCount += 1
            return true
        }
    }
}

/// Builds the one generation context used for both actual structure emission
/// and read-only structure lookup. Debug grids intentionally have no
/// structures, while each playable dimension retains its own terrain/biome
/// semantics. The exact Overworld oracle is cloned per plan by getPlan, so
/// this context never carries mutable planning history into a cache key.
public func structurePlanningContext(seed: UInt32, dim: Dim,
                                     settings: WorldGenerationSettings = .normal) -> GenCtx? {
    guard !(dim == .overworld && settings.preset == .debugAllBlockStates) else { return nil }
    let activeDefinitions = structureDefinitionsForGeneration(dim: dim, settings: settings)
    switch dim {
    case .overworld:
        if settings.preset == .flat {
            return GenCtx(seed: seed,
                          heightAt: { _, _ in GEN_MIN_Y + 4 },
                          biomeAt: { _, _ in Biome.plains.rawValue },
                          dim: Dim.overworld.rawValue,
                          villageDensity: settings.villageDensity,
                          generationSettingsIdentity: settings.cacheIdentity,
                          baseTerrainOracleVersion: baseTerrainOracleVersion,
                          terrainOracle: BaseTerrainOracle(
                              seed: seed, settings: settings,
                              maxCachedChunks: structurePlanOracleMaxCachedChunks,
                              maxQueries: structurePlanOracleMaxQueries),
                          activeStructureDefinitions: activeDefinitions)
        }
        let gen = overworldGen(seed, settings: settings)
        return GenCtx(seed: seed,
                      heightAt: { x, z in gen.refinedHeightEstimate(Double(x), Double(z)) },
                      biomeAt: { x, z in gen.surfaceBiomeAt(Double(x), Double(z)).rawValue },
                      dim: Dim.overworld.rawValue,
                      villageDensity: settings.villageDensity,
                      generationSettingsIdentity: settings.cacheIdentity,
                      baseTerrainOracleVersion: baseTerrainOracleVersion,
                      terrainOracle: BaseTerrainOracle(
                          seed: seed, settings: settings,
                          maxCachedChunks: structurePlanOracleMaxCachedChunks,
                          maxQueries: structurePlanOracleMaxQueries),
                      activeStructureDefinitions: activeDefinitions)
    case .nether:
        let gen = netherGen(seed)
        return GenCtx(seed: seed,
                      heightAt: { x, z in gen.heightEstimate(Double(x), Double(z)) },
                      biomeAt: { x, z in gen.biomeAt(Double(x), Double(z)) },
                      dim: Dim.nether.rawValue,
                      activeStructureDefinitions: activeDefinitions)
    case .end:
        let gen = endGen(seed)
        return GenCtx(seed: seed,
                      heightAt: { x, z in
                          let factor = gen.islandFactor(Double(x), Double(z))
                          return factor > 0 ? Int((58 + factor * 4).rounded(.down)) : 0
                      },
                      biomeAt: { x, z in gen.biomeColumn(Double(x), Double(z)) },
                      dim: Dim.end.rawValue,
                      activeStructureDefinitions: activeDefinitions)
    }
}

/// The exact set that can materialize in a dimension/preset. Keeping this
/// alongside structurePlanningContext prevents /locate from reporting a plan
/// that the matching world-generation branch never emits.
public func structureDefinitionsForGeneration(dim: Dim,
                                              settings: WorldGenerationSettings = .normal) -> [StructureDef] {
    registerAllStructures()
    switch dim {
    case .overworld:
        if settings.preset == .debugAllBlockStates { return [] }
        // A prehistoric profile has no human settlement plans. Keep this
        // decision here, alongside the generation domain filter, so `/locate`
        // cannot report a village that its matching world-generation branch
        // would never materialize. Other Overworld landmarks remain intact.
        if settings.preset.isPrehistoric {
            return STRUCTURES.filter { !["village", "pillager_outpost"].contains($0.id) }
        }
        if settings.preset == .flat {
            return STRUCTURES.filter { $0.id == "village" || $0.id == "stronghold" }
        }
        return STRUCTURES.filter { !["fortress", "bastion", "end_city"].contains($0.id) }
    case .nether:
        return STRUCTURES.filter { ["fortress", "bastion", "ruined_portal"].contains($0.id) }
    case .end:
        return STRUCTURES.filter { $0.id == "end_city" }
    }
}

/// Returns exact base-terrain state for an ordinary Overworld column. Other
/// dimensions intentionally have no base-terrain oracle and retain their
/// dimension-specific floor semantics.
public func exactTerrainSurface(_ ctx: GenCtx, _ x: Int, _ z: Int) -> ExactTerrainSurface? {
    guard ctx.dim == Dim.overworld.rawValue, let oracle = ctx.terrainOracle else { return nil }
    return oracle.exactSurface(x, z)
}

/// Validates every column of a conventional above-ground structure footprint.
/// The returned feet height is its high edge so existing bounded foundations
/// support lower columns without burying the structure in a crest. `nil`
/// means wet, unsupported, over-varied, outside the exact oracle, or over the
/// oracle query budget; callers must only use a height-estimate fallback when
/// the context has no oracle at all (legacy tests/non-Overworld contexts).
public func exactDryTerrainPadY(_ ctx: GenCtx,
                                 _ x0: Int, _ z0: Int,
                                 _ x1: Int, _ z1: Int,
                                 maxVariation: Int) -> Int? {
    guard x0 <= x1, z0 <= z1, maxVariation >= 0 else { return nil }
    var low: Int?
    var high: Int?
    for z in z0...z1 {
        for x in x0...x1 {
            guard let surface = exactTerrainSurface(ctx, x, z), surface.isDry else { return nil }
            low = min(low ?? surface.feetY, surface.feetY)
            high = max(high ?? surface.feetY, surface.feetY)
        }
    }
    guard let low, let high, high - low <= maxVariation else { return nil }
    return high
}

public final class ArraySink: ChunkSink {
    public let cx: Int
    public let cz: Int
    public let minY: Int
    public let maxY: Int
    public var blocks: [UInt16]
    public var blockEntities: [BESpec] = []
    public var entities: [EntitySpec] = []
    public var naturalTreeCells: [Int: NaturalTreeCell] = [:]
    private let heightFallback: (Int, Int) -> Int

    public init(cx: Int, cz: Int, blocks: [UInt16], minY: Int, maxY: Int, heightFallback: @escaping (Int, Int) -> Int) {
        self.cx = cx
        self.cz = cz
        self.blocks = blocks
        self.minY = minY
        self.maxY = maxY
        self.heightFallback = heightFallback
    }

    public func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        let lx = x - cx * 16, lz = z - cz * 16
        if lx < 0 || lx > 15 || lz < 0 || lz > 15 || y < minY || y >= maxY { return }
        let index = ((y - minY) * 16 + lz) * 16 + lx
        blocks[index] = c
        naturalTreeCells.removeValue(forKey: index)
    }

    public func setNaturalTreeCell(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16, origin: NaturalTreeOrigin) {
        set(x, y, z, c)
        let lx = x - cx * 16, lz = z - cz * 16
        guard (0..<16).contains(lx), (0..<16).contains(lz), y >= minY, y < maxY else { return }
        let index = ((y - minY) * 16 + lz) * 16 + lx
        naturalTreeCells[index] = NaturalTreeCell(origin: origin, expected: c)
    }

    /// Snow and a few bulk generators edit the array directly. Stale sidecar
    /// records can never confer natural provenance on their replacement cells.
    var validatedNaturalTreeCells: [Int: NaturalTreeCell] {
        naturalTreeCells.filter { blocks[$0.key] == $0.value.expected }
    }

    public func get(_ x: Int, _ y: Int, _ z: Int) -> Int {
        let lx = x - cx * 16, lz = z - cz * 16
        if lx < 0 || lx > 15 || lz < 0 || lz > 15 { return -1 }
        if y < minY || y >= maxY { return 0 }
        return Int(blocks[((y - minY) * 16 + lz) * 16 + lx])
    }

    public func topY(_ x: Int, _ z: Int) -> Int {
        let lx = x - cx * 16, lz = z - cz * 16
        if lx < 0 || lx > 15 || lz < 0 || lz > 15 { return heightFallback(x, z) }
        var y = maxY - 1
        while y > minY {
            let c = blocks[((y - minY) * 16 + lz) * 16 + lx]
            if c != 0 {
                let id = c >> 4
                if id == B.water { return y + 1 }
                if SOLID[Int(id)] == 1 || id == B.lava { return y + 1 }
            }
            y -= 1
        }
        return minY + 1
    }

    public func hasBlockEntity(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        blockEntities.contains { $0.x == x && $0.y == y && $0.z == z }
    }

    public func addBlockEntity(_ spec: BESpec) {
        let lx = spec.x - cx * 16, lz = spec.z - cz * 16
        if lx < 0 || lx > 15 || lz < 0 || lz > 15 { return }
        blockEntities.append(spec)
    }

    public func addEntity(_ spec: EntitySpec) {
        let lx = Int(spec.x.rounded(.down)) - cx * 16, lz = Int(spec.z.rounded(.down)) - cz * 16
        if lx < 0 || lx > 15 || lz < 0 || lz > 15 { return }
        entities.append(spec)
    }
}

/// Bootstrap generation has only one output chunk in hand, unlike runtime
/// spawning which can inspect a live World. Keep large prehistoric specs
/// safely inside that chunk and apply the same body-envelope rule before an
/// `EntitySpec` is emitted. A footprint crossing an unknown chunk is rejected
/// rather than guessed; runtime adoption repeats the authoritative check.
func prehistoricBootstrapHasClearance(
    _ sink: ChunkSink,
    definition: PrehistoricCreatureDefinition,
    x: Int,
    y: Int,
    z: Int
) -> Bool {
    let radius = definition.bodyClearanceRadius
    let supportRadius = definition.groundSupportRadius
    let vertical = definition.bodyClearanceHeight
    guard y > sink.minY, y + vertical <= sink.maxY else { return false }
    for zz in (z - radius)...(z + radius) {
        for xx in (x - radius)...(x + radius) {
            let insideChunk = floorDiv(xx, CHUNK_W) == sink.cx && floorDiv(zz, CHUNK_W) == sink.cz
            guard insideChunk else { return false }
            if abs(xx - x) <= supportRadius, abs(zz - z) <= supportRadius {
                let below = sink.get(xx, y - 1, zz)
                let belowID = below >> 4
                guard below > 0, belowID < blockDefs.count, blockDefs[belowID].solid else { return false }
            }
            for yy in y..<(y + vertical) {
                let cell = sink.get(xx, yy, zz)
                let block = cell >> 4
                guard cell >= 0,
                      block == 0 || (block < blockDefs.count && blockDefs[block].replaceable)
                else { return false }
            }
        }
    }
    return true
}

private struct OverworldGenKey: Hashable {
    let seed: UInt32
    let presetID: String
    let singleBiomeID: String
    let dungeonDensityLevel: Int
    let villageDensityLevel: Int
}

private var overworldGens: [OverworldGenKey: OverworldGen] = [:]
private var netherGens: [UInt32: NetherGen] = [:]
private var endGens: [UInt32: EndGen] = [:]
private let genLock = NSLock()

/// Tree roots are replayed by every chunk their canopy reaches. Cache the
/// small structure exclusion list for an entire feature-origin chunk, rather
/// than asking the structure planner once per candidate root.
private struct TreeStructureExclusionKey: Hashable {
    let seed: UInt32
    let dim: Int
    let settingsIdentity: String
    let baseTerrainOracleVersion: Int
    let activeStructureDomainIdentity: String
    let treeStructureSignature: String
    let collisionStructureSignature: String
    let cx: Int
    let cz: Int
}
/// Internal so deterministic structure tests can verify that a rejected
/// landmark does not reserve feature space. Production callers stay within
/// this file and use `treeCanopyExclusions` below.
struct TreeStructureExclusion {
    let x0: Int
    let z0: Int
    let x1: Int
    let z1: Int

    func contains(_ x: Int, _ z: Int) -> Bool {
        x >= x0 && x <= x1 && z >= z0 && z <= z1
    }
}

/// Surface features run after structures.  They must not repopulate a cleared
/// house, pen, road, or doorway with grass, a flower, bamboo, or a tree.  The
/// wrapper preserves feature RNG and reads while making protected writes a
/// no-op, so chunk-order determinism is unchanged.
private final class StructureProtectedFeatureSink: ChunkSink {
    private let base: ChunkSink
    private let protected: (Int, Int) -> Bool

    init(_ base: ChunkSink, protected: @escaping (Int, Int) -> Bool) {
        self.base = base
        self.protected = protected
    }

    var cx: Int { base.cx }
    var cz: Int { base.cz }
    var minY: Int { base.minY }
    var maxY: Int { base.maxY }
    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        if !protected(x, z) { base.set(x, y, z, c) }
    }
    func setNaturalTreeCell(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16, origin: NaturalTreeOrigin) {
        if !protected(x, z) { base.setNaturalTreeCell(x, y, z, c, origin: origin) }
    }
    func get(_ x: Int, _ y: Int, _ z: Int) -> Int { base.get(x, y, z) }
    func topY(_ x: Int, _ z: Int) -> Int { base.topY(x, z) }
    func hasBlockEntity(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        base.hasBlockEntity(x, y, z)
    }
    func addBlockEntity(_ spec: BESpec) {
        if !protected(spec.x, spec.z) { base.addBlockEntity(spec) }
    }
    func addEntity(_ spec: EntitySpec) {
        if !protected(Int(spec.x.rounded(.down)), Int(spec.z.rounded(.down))) {
            base.addEntity(spec)
        }
    }
}
private let treeStructureExclusionsLock = NSLock()
private var treeStructureExclusions: [TreeStructureExclusionKey: [TreeStructureExclusion]] = [:]
private let treeStructureExclusionsLimit = 2_048

/// Returns the precise feature-protection rectangles for plans that won their
/// conventional-surface collision decision. Kept internal for a focused
/// regression; it is not a general structure-planning API.
func treeCanopyExclusions(forOriginChunk cx: Int, _ cz: Int, context: GenCtx,
                          structures: [StructureDef],
                          collisionDefinitions: [StructureDef]) -> [TreeStructureExclusion] {
    // The cache must reflect both the structures whose footprints reserve
    // canopy space and the full conventional collision domain that decides
    // whether each footprint won. Sort immutable fields rather than trusting
    // caller-array order.
    func signature(_ definitions: [StructureDef]) -> String {
        definitions.map { def in
            "\(def.id):\(def.salt):\(def.spacing):\(def.separation):\(def.maxRadiusChunks)"
        }.sorted().joined(separator: "|")
    }
    let key = TreeStructureExclusionKey(seed: context.seed,
                                        dim: context.dim,
                                        settingsIdentity: context.generationSettingsIdentity,
                                        baseTerrainOracleVersion: context.baseTerrainOracleVersion,
                                        activeStructureDomainIdentity: context.activeStructureDomainIdentity,
                                        treeStructureSignature: signature(structures),
                                        collisionStructureSignature: conventionalSurfaceCollisionSignature(collisionDefinitions),
                                        cx: cx, cz: cz)
    if let cached = treeStructureExclusionsLock.withLock({ treeStructureExclusions[key] }) {
        return cached
    }
    let rootX0 = cx * 16, rootZ0 = cz * 16
    let rootX1 = rootX0 + 15, rootZ1 = rootZ0 + 15
    var exclusions: [TreeStructureExclusion] = []
    for def in structures {
        guard let placement = def.placement(context) else { continue }
        // A structure piece can extend `maxRadiusChunks` from its origin; add
        // one chunk for the six-block canopy margin around this feature origin.
        let radius = def.maxRadiusChunks + 1
        let minRegionX = floorDiv(cx - radius, placement.spacing)
        let maxRegionX = floorDiv(cx + radius, placement.spacing)
        let minRegionZ = floorDiv(cz - radius, placement.spacing)
        let maxRegionZ = floorDiv(cz + radius, placement.spacing)
        for regionZ in minRegionZ...maxRegionZ {
            for regionX in minRegionX...maxRegionX {
                let origin = structureOriginFor(def, placement: placement,
                                                 seed: context.seed,
                                                 regionX: regionX, regionZ: regionZ)
                guard abs(origin.0 - cx) <= radius,
                      abs(origin.1 - cz) <= radius,
                      let plan = getPlan(def, context, origin.0, origin.1),
                      surfaceStructurePlanWins(def, plan, context, origin.0, origin.1,
                                               collisionDefinitions: collisionDefinitions) else { continue }
                for piece in plan.pieces {
                    let exclusion = TreeStructureExclusion(x0: piece.x0 - 6, z0: piece.z0 - 6,
                                                            x1: piece.x1 + 6, z1: piece.z1 + 6)
                    if !(exclusion.x1 < rootX0 || exclusion.x0 > rootX1 ||
                         exclusion.z1 < rootZ0 || exclusion.z0 > rootZ1) {
                        exclusions.append(exclusion)
                    }
                }
            }
        }
    }
    treeStructureExclusionsLock.withLock {
        if treeStructureExclusions.count >= treeStructureExclusionsLimit {
            treeStructureExclusions.removeAll(keepingCapacity: true)
        }
        treeStructureExclusions[key] = exclusions
    }
    return exclusions
}

public func overworldGen(_ seed: UInt32, settings: WorldGenerationSettings = .normal) -> OverworldGen {
    genLock.lock()
    defer { genLock.unlock() }
    let key = OverworldGenKey(seed: seed, presetID: settings.preset.rawValue,
                              singleBiomeID: biomeID(settings.singleBiome),
                              dungeonDensityLevel: settings.dungeonDensity.rawValue,
                              villageDensityLevel: settings.villageDensity.rawValue)
    if let g = overworldGens[key] { return g }
    let g = OverworldGen(seed, settings: settings)
    overworldGens[key] = g
    return g
}
public func netherGen(_ seed: UInt32) -> NetherGen {
    genLock.lock()
    defer { genLock.unlock() }
    if let g = netherGens[seed] { return g }
    let g = NetherGen(seed)
    netherGens[seed] = g
    return g
}
public func endGen(_ seed: UInt32) -> EndGen {
    genLock.lock()
    defer { genLock.unlock() }
    if let g = endGens[seed] { return g }
    let g = EndGen(seed)
    endGens[seed] = g
    return g
}

private func filledBiomeQuarts(_ biome: Biome, height: Int) -> [UInt8] {
    [UInt8](repeating: UInt8(biome.rawValue), count: 4 * 4 * ((height + 3) / 4))
}

private func generateFlatOverworldChunk(_ seed: UInt32, _ cx: Int, _ cz: Int,
                                        settings: WorldGenerationSettings) -> GenOutput {
    let info = DIMS[Dim.overworld.rawValue]
    let base = buildBaseTerrainChunk(seed: seed, cx: cx, cz: cz, settings: settings)
    let sink = ArraySink(cx: cx, cz: cz, blocks: base.blocks, minY: info.minY, maxY: info.minY + info.height,
                         heightFallback: { _, _ in GEN_MIN_Y + 4 })
    guard let ctx = structurePlanningContext(seed: seed, dim: .overworld, settings: settings) else {
        preconditionFailure("flat worlds must have a structure-planning context")
    }
    let flatStructs = structureDefinitionsForGeneration(dim: .overworld, settings: settings)
    let structRefs = buildStructuresForChunk(ctx, cx, cz, sink, flatStructs)
    return GenOutput(blocks: sink.blocks, biomes: base.biomes,
                     blockEntities: sink.blockEntities, entities: sink.entities, structRefs: structRefs,
                     naturalTreeCells: sink.validatedNaturalTreeCells)
}

private func debugBlockStateCells() -> [UInt16] {
    var cells: [UInt16] = []
    for id in blockDefs.indices where blockDefs[id].shape != .air {
        for meta in 0..<16 {
            cells.append(UInt16((id << 4) | meta))
        }
    }
    return cells
}

private func generateDebugOverworldChunk(_ cx: Int, _ cz: Int) -> GenOutput {
    let info = DIMS[Dim.overworld.rawValue]
    var blocks = [UInt16](repeating: 0, count: CHUNK_W * CHUNK_W * info.height)
    let bedrock = cell(B.bedrock)
    let floorY = 60
    if floorY >= info.minY, floorY < info.minY + info.height {
        for z in 0..<16 {
            for x in 0..<16 {
                blocks[((floorY - info.minY) * 16 + z) * 16 + x] = bedrock
            }
        }
    }
    let states = debugBlockStateCells()
    let side = max(1, Int(ceil(Double(states.count).squareRoot())))
    let y = 70
    for z in 0..<16 {
        for x in 0..<16 {
            let wx = cx * 16 + x
            let wz = cz * 16 + z
            guard wx >= 0, wz >= 0 else { continue }
            let idx = wz * side + wx
            if idx < states.count {
                blocks[((y - info.minY) * 16 + z) * 16 + x] = states[idx]
            }
        }
    }
    return GenOutput(blocks: blocks, biomes: filledBiomeQuarts(.plains, height: info.height),
                     blockEntities: [], entities: [], structRefs: [])
}

public func generateChunk(_ dim: Dim, _ seed: UInt32, _ cx: Int, _ cz: Int,
                          settings: WorldGenerationSettings = .normal) -> GenOutput {
    registerAllStructures()
    let info = DIMS[dim.rawValue]
    let n = CHUNK_W * CHUNK_W * info.height
    var blocks = [UInt16](repeating: 0, count: n)
    var biomes = [UInt8](repeating: 0, count: 4 * 4 * ((info.height + 3) / 4))

    if dim == .overworld {
        if settings.preset == .flat {
            return generateFlatOverworldChunk(seed, cx, cz, settings: settings)
        }
        if settings.preset == .debugAllBlockStates {
            return generateDebugOverworldChunk(cx, cz)
        }
        let gen = overworldGen(seed, settings: settings)
        let base = buildBaseTerrainChunk(seed: seed, cx: cx, cz: cz, settings: settings)
        blocks = base.blocks
        biomes = base.biomes

        // refined estimate (incl. 3D detail) — the spline-only one diverged ±34
        // from real terrain, scattering trees and burying/hovering structures
        let sink = ArraySink(cx: cx, cz: cz, blocks: blocks, minY: GEN_MIN_Y, maxY: GEN_MIN_Y + WORLD_H,
                             heightFallback: { x, z in gen.refinedHeightEstimate(Double(x), Double(z)) })
        guard let ctx = structurePlanningContext(seed: seed, dim: dim, settings: settings) else {
            preconditionFailure("playable Overworld worlds must have a structure-planning context")
        }
        let overworldStructs = structureDefinitionsForGeneration(dim: dim, settings: settings)
        let structRefs = buildStructuresForChunk(ctx, cx, cz, sink, overworldStructs)

        // Features from 3×3 origin chunks. Trees validate their root against
        // exact owning terrain, so every target chunk makes the same decision
        // before clipping its canopy cells.
        let surfaceBiomeAt: (Int, Int) -> Int = { x, z in gen.surfaceBiomeAt(Double(x), Double(z)).rawValue }
        let treeBlockingStructures = overworldStructs.filter { def in
            ["village", "desert_temple", "jungle_temple", "igloo", "witch_hut",
             "pillager_outpost", "woodland_mansion", "ruined_portal", "trail_ruins"].contains(def.id)
        }
        for oz in (cz - 1)...(cz + 1) {
            for ox in (cx - 1)...(cx + 1) {
                // Every target chunk replays a tree from this same origin. Its
                // origin-local exclusion list therefore gives every clipped
                // canopy the same structure-clearance answer at constant cost.
                let treeExclusions = treeCanopyExclusions(forOriginChunk: ox, oz, context: ctx,
                                                           structures: treeBlockingStructures,
                                                           collisionDefinitions: overworldStructs)
                let protectedTreeSite: (Int, Int) -> Bool = { x, z in
                    !treeExclusions.contains { $0.contains(x, z) }
                }
                let featureSink: ChunkSink = treeExclusions.isEmpty
                    ? sink
                    : StructureProtectedFeatureSink(sink, protected: { x, z in
                        !protectedTreeSite(x, z)
                    })
                let centerBiome = gen.surfaceBiomeAt(Double(ox * 16 + 8), Double(oz * 16 + 8))
                let feats = biomeDef(centerBiome.rawValue).features
                var salt: UInt32 = 9000
                for f in feats {
                    var rng = chunkRandom(seed, ox, oz, salt)
                    salt += 1
                    if f.hasPrefix("trees:") {
                        runFeature(f, featureSink, &rng, ox, oz, seed, surfaceBiomeAt,
                                   treeSiteAllowed: protectedTreeSite,
                                   treeRootSite: { x, z in
                                       guard let top = ctx.terrainOracle?.topSolidY(x, z),
                                             let ground = ctx.terrainOracle?.cell(x, top, z) else { return nil }
                                       return (top + 1, ground)
                                   })
                    } else {
                        runFeature(f, featureSink, &rng, ox, oz, seed, surfaceBiomeAt)
                    }
                }
                if settings.preset != .singleBiomeSurface {
                    // cave biome features from the full 3×3 origins — running them
                    // only for the target chunk clipped dripstone/moss/sculk flat
                    // at every chunk face (their radius reaches up to 5 blocks)
                    for cb in [Biome.lushCaves, .dripstoneCaves, .deepDark] {
                        let feats2 = biomeDef(cb.rawValue).features
                        var salt2 = UInt32(12000 + cb.rawValue * 100)
                        for f in feats2 {
                            var rng = chunkRandom(seed, ox, oz, salt2)
                            salt2 += 1
                            runFeature(f, sink, &rng, ox, oz, seed, { x, z in
                                let cbb = gen.caveBiomeAt(Double(x), -10, Double(z), gen.heightEstimate(Double(x), Double(z)))
                                return cbb == -1 ? gen.surfaceBiomeAt(Double(x), Double(z)).rawValue : cbb
                            })
                        }
                    }
                }
                tryGeode(seed, ox, oz, sink)
            }
        }
        tryDungeons(seed, cx, cz, sink, density: settings.dungeonDensity,
                    settings: settings, terrainOracle: ctx.terrainOracle)
        // Snow is intentionally applied after features, but it must not refill
        // the open body space of a planned village pen or stamp over a door,
        // road, or roof.  The same deterministic structure buffer used by
        // vegetation is authoritative for this final surface pass as well.
        let snowExclusions = treeCanopyExclusions(forOriginChunk: cx, cz, context: ctx,
                                                  structures: treeBlockingStructures,
                                                  collisionDefinitions: overworldStructs)
        gen.applySnowAndIce(cx, cz, &sink.blocks, base.surfaceBiomes,
                            snowSiteAllowed: { x, z in
                                !snowExclusions.contains { $0.contains(x, z) }
                            })

        // Version-two prehistoric maps own a physical first-night shelter.
        // Stamp only after every terrain, feature, and snow pass so no later
        // generator stage can fill the hut, cover its roof, or erase its
        // deterministic nearby wood grove.
        if settings.preset.supportsStarterShelter {
            stampPrehistoricStarterShelter(seed: seed, settings: settings, sink: sink)
        }

        // worldgen passive mobs
        var mobRng = chunkRandom(seed, cx, cz, 0xAB1E)
        // Rich Resources promises a living, resource-rich surface. It receives
        // enough deterministic bootstrap packs to be noticeable before the
        // runtime natural-spawn loop has had time to fill the area.
        let passiveBootstrapChance = settings.preset == .moderateHillsResourceRich ? 0.35
            : settings.preset.isPrehistoric ? 0.28 : 0.1
        // Do not bootstrap an animal or dinosaur inside the first-night hut
        // itself. The site is pure/cached and therefore agrees with the stamp
        // on hosts, LAN clients, and independently generated neighbor chunks.
        let starterShelter = settings.preset.supportsStarterShelter
            ? prehistoricStarterShelterSite(seed: seed, settings: settings) : nil
        if mobRng.nextFloat() < passiveBootstrapChance {
            let centerBiome = gen.surfaceBiomeAt(Double(cx * 16 + 8), Double(cz * 16 + 8))
            let list = settings.preset.prehistoricProfile.map {
                prehistoricSpawnEntries(profile: $0, category: "creature")
            } ?? biomeDef(centerBiome.rawValue).creatures
            if !list.isEmpty {
                let entry = mobRng.pickWeighted(list) { $0.weight }
                let pack = entry.minPack + mobRng.nextInt(entry.maxPack - entry.minPack + 1)
                for spawnOrdinal in 0..<pack {
                    let px = cx * 16 + mobRng.nextInt(16), pz = cz * 16 + mobRng.nextInt(16)
                    let py = sink.topY(px, pz)
                    // require real ground — topY over oceans returned the water
                    // surface and shipped chickens standing on the sea
                    let ground = sink.get(px, py - 1, pz)
                    let gid = ground >> 4
                    let grounded = ground != -1 && gid != Int(B.water) && gid != Int(B.lava)
                        && gid != 0 && blockDefs[gid].solid
                    let prehistoricDefinition = PrehistoricCreatureDefinition.named(entry.mob)
                    let envelopeClear = prehistoricDefinition.map {
                        prehistoricBootstrapHasClearance(sink, definition: $0, x: px, y: py, z: pz)
                    } ?? true
                    let inStarterShelter = starterShelter?.containsProtectedSpawnColumn(px, pz) ?? false
                    if py > 50 && py < 200 && grounded && envelopeClear && !inStarterShelter {
                        let data: [String: BEValue]
                        if prehistoricDefinition != nil {
                            // The generated pack ordinal is stable for this
                            // chunk/spec and distinguishes even a rare pair
                            // that lands on the same quantized coordinate.
                            data = ["prehistoricSeedSalt": .num(Double(spawnOrdinal + 1))]
                        } else {
                            data = [:]
                        }
                        sink.addEntity(EntitySpec(mob: entry.mob, x: Double(px) + 0.5, y: Double(py), z: Double(pz) + 0.5, data: data))
                    }
                }
            }
        }
        return GenOutput(blocks: sink.blocks, biomes: biomes,
                         blockEntities: sink.blockEntities, entities: sink.entities, structRefs: structRefs,
                         naturalTreeCells: sink.validatedNaturalTreeCells)
    }

    if dim == .nether {
        let gen = netherGen(seed)
        let surfaceBiomes = gen.fillTerrain(cx, cz, &blocks, &biomes)
        gen.applySurface(cx, cz, &blocks, surfaceBiomes)
        gen.placeOres(cx, cz, &blocks)
        let sink = ArraySink(cx: cx, cz: cz, blocks: blocks, minY: 0, maxY: NETHER_H,
                             heightFallback: { x, z in gen.heightEstimate(Double(x), Double(z)) })
        guard let ctx = structurePlanningContext(seed: seed, dim: dim, settings: settings) else {
            preconditionFailure("Nether worlds must have a structure-planning context")
        }
        let netherStructs = structureDefinitionsForGeneration(dim: dim, settings: settings)
        let structRefs = buildStructuresForChunk(ctx, cx, cz, sink, netherStructs)
        let biomeAt: (Int, Int) -> Int = { x, z in gen.biomeAt(Double(x), Double(z)) }
        for oz in (cz - 1)...(cz + 1) {
            for ox in (cx - 1)...(cx + 1) {
                let centerBiome = gen.biomeAt(Double(ox * 16 + 8), Double(oz * 16 + 8))
                let feats = biomeDef(centerBiome).features
                var salt: UInt32 = 9500
                for f in feats {
                    var rng = chunkRandom(seed, ox, oz, salt)
                    salt += 1
                    runFeature(f, sink, &rng, ox, oz, seed, biomeAt)
                }
            }
        }
        if settings.preset == .netherWorld {
            placeNetherWorldGateway(seed: seed, cx: cx, cz: cz, generator: gen, sink: sink)
        }
        return GenOutput(blocks: sink.blocks, biomes: biomes,
                         blockEntities: sink.blockEntities, entities: sink.entities, structRefs: structRefs,
                         naturalTreeCells: sink.validatedNaturalTreeCells)
    }

    // End
    let gen = endGen(seed)
    let surfaceBiomes = gen.fillTerrain(cx, cz, &blocks, &biomes)
    _ = surfaceBiomes
    let sink = ArraySink(cx: cx, cz: cz, blocks: blocks, minY: 0, maxY: END_H, heightFallback: { _, _ in 60 })
    var fixtureBlocks = sink.blocks
    gen.placeFixtures(cx, cz, &fixtureBlocks) { mob, x, y, z, data in
        sink.entities.append(EntitySpec(mob: mob, x: x, y: y, z: z, data: data))
    }
    sink.blocks = fixtureBlocks
    guard let ctx = structurePlanningContext(seed: seed, dim: dim, settings: settings) else {
        preconditionFailure("End worlds must have a structure-planning context")
    }
    let endStructs = structureDefinitionsForGeneration(dim: dim, settings: settings)
    let structRefs = buildStructuresForChunk(ctx, cx, cz, sink, endStructs)
    let biomeColumnAt: (Int, Int) -> Int = { x, z in gen.biomeColumn(Double(x), Double(z)) }
    for oz in (cz - 1)...(cz + 1) {
        for ox in (cx - 1)...(cx + 1) {
            let centerBiome = gen.biomeColumn(Double(ox * 16 + 8), Double(oz * 16 + 8))
            let feats = biomeDef(centerBiome).features
            var salt: UInt32 = 9900
            for f in feats {
                var rng = chunkRandom(seed, ox, oz, salt)
                salt += 1
                runFeature(f, sink, &rng, ox, oz, seed, biomeColumnAt)
            }
        }
    }
    return GenOutput(blocks: sink.blocks, biomes: biomes,
                     blockEntities: sink.blockEntities, entities: sink.entities, structRefs: structRefs,
                     naturalTreeCells: sink.validatedNaturalTreeCells)
}

private let netherWorldGatewayRegionChunks = 8

/// One deterministic, active gateway per 8x8-chunk region. The origin gateway is pinned to
/// chunk 0,0 so a new Nether-first player always has a visible route to the Overworld; all other
/// regions use seed-jittered chunk positions to avoid an artificial-looking global grid.
public func isNetherWorldGatewayChunk(seed: UInt32, cx: Int, cz: Int) -> Bool {
    let rx = floorDiv(cx, netherWorldGatewayRegionChunks)
    let rz = floorDiv(cz, netherWorldGatewayRegionChunks)
    if rx == 0 && rz == 0 { return cx == 0 && cz == 0 }
    let mixed = hash2(seed ^ 0x4E57_4741, rx, rz, 0x5941)
    let ox = Int(mixed & 7)
    let oz = Int((mixed >> 8) & 7)
    return cx == rx * netherWorldGatewayRegionChunks + ox
        && cz == rz * netherWorldGatewayRegionChunks + oz
}

/// Stable floor used by both world generation and fresh-player spawn selection.
public func netherWorldGatewayFloorY(seed: UInt32, cx: Int, cz: Int) -> Int {
    let gen = netherGen(seed)
    let x = cx * 16 + 6
    let z = cz * 16 + 7
    return max(36, min(96, gen.heightEstimate(Double(x), Double(z))))
}

private func placeNetherWorldGateway(seed: UInt32, cx: Int, cz: Int,
                                     generator: NetherGen, sink: ArraySink) {
    guard isNetherWorldGatewayChunk(seed: seed, cx: cx, cz: cz) else { return }
    let x = cx * 16 + 5
    let z = cz * 16 + 7
    let y = max(36, min(96, generator.heightEstimate(Double(x + 1), Double(z))))
    let air = UInt16(0)
    let floor = cell(B.blackstone)
    let obsidian = cell(B.obsidian)
    let portal = cell(B.nether_portal, 0)
    let light = cell(B.shroomlight)

    // A compact, fully excavated chamber keeps the route usable even when the density sampler
    // selects a floor beside solid terrain. Everything stays inside one chunk, preserving the
    // generator's chunk-local deterministic write contract.
    for pz in (z - 2)...(z + 2) {
        for px in (x - 2)...(x + 5) {
            sink.set(px, y - 1, pz, floor)
            for py in y...(y + 5) { sink.set(px, py, pz, air) }
        }
    }
    for dy in 0...4 {
        for dx in 0...3 {
            let frame = dy == 0 || dy == 4 || dx == 0 || dx == 3
            sink.set(x + dx, y + dy, z, frame ? obsidian : portal)
        }
    }
    sink.set(x - 2, y, z - 2, light)
    sink.set(x + 5, y, z + 2, light)
}

/// back-compat shim for callers built against the pre-structures pipeline
public func generateOverworldChunk(_ seed: UInt32, _ cx: Int, _ cz: Int) -> GenOutput {
    generateChunk(.overworld, seed, cx, cz)
}
