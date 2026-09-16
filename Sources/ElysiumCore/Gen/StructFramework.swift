// Structure framework — Deterministic
// region-based placement, plan caching, template stamping and build utilities.

import Foundation

/// reference-boxed RandomX so structure plan/build closures can share one
/// advancing stream like the baseline Random class instances do
public final class Rng {
    public var r: RandomX
    public init(_ seed: UInt32) { r = RandomX(seed) }
    public init(_ rx: RandomX) { r = rx }
    @inline(__always) public func nextFloat() -> Double { r.nextFloat() }
    @inline(__always) public func nextInt(_ bound: Int) -> Int { r.nextInt(bound) }
    @inline(__always) public func nextIntBetween(_ a: Int, _ b: Int) -> Int { r.nextIntBetween(a, b) }
    @inline(__always) public func nextBoolean() -> Bool { r.nextBoolean() }
    @inline(__always) public func chance(_ p: Double) -> Bool { r.chance(p) }
    @inline(__always) public func pick<T>(_ arr: [T]) -> T { r.pick(arr) }
    @inline(__always) public func shuffle<T>(_ arr: [T]) -> [T] {
        var a = arr
        r.shuffle(&a)
        return a
    }
}

public struct GenCtx {
    public let seed: UInt32
    /// noise-based surface height estimate (overworld) or floor probe (nether/end)
    public let heightAt: (Int, Int) -> Int
    public let biomeAt: (Int, Int) -> Int
    public let dim: Int
    /// Generation setting carried explicitly because structure placement and
    /// feature exclusion must not infer it from an opaque cache identity.
    public let villageDensity: VillageDensity
    public let generationSettingsIdentity: String
    public let baseTerrainOracleVersion: Int
    public let terrainOracle: BaseTerrainOracle?
    /// The immutable set of definitions that can materialize in this exact
    /// dimension/preset. Planning decisions must never consult disabled
    /// definitions: doing so lets a landmark that generation will not emit
    /// veto a real plan (most visibly flat-world villages).
    public let activeStructureDefinitions: [StructureDef]?
    public let activeStructureDomainIdentity: String

    public init(seed: UInt32, heightAt: @escaping (Int, Int) -> Int,
                biomeAt: @escaping (Int, Int) -> Int, dim: Int,
                villageDensity: VillageDensity = .normal,
                generationSettingsIdentity: String = "legacy",
                baseTerrainOracleVersion: Int = 0,
                terrainOracle: BaseTerrainOracle? = nil,
                activeStructureDefinitions: [StructureDef]? = nil) {
        self.seed = seed
        self.heightAt = heightAt
        self.biomeAt = biomeAt
        self.dim = dim
        self.villageDensity = villageDensity
        self.generationSettingsIdentity = generationSettingsIdentity
        self.baseTerrainOracleVersion = baseTerrainOracleVersion
        self.terrainOracle = terrainOracle
        self.activeStructureDefinitions = activeStructureDefinitions
        self.activeStructureDomainIdentity = activeStructureDefinitions.map(structureDefinitionDomainIdentity) ?? "legacy"
    }
}

/// A structure may select its candidate lattice from immutable generation
/// settings. `nil` disables that structure for the current world; registry
/// definitions are never mutated after registration.
public struct StructurePlacement: Equatable {
    public let spacing: Int
    public let separation: Int

    public init(spacing: Int, separation: Int) {
        precondition(spacing > 0)
        precondition(separation >= 0 && separation < spacing)
        self.spacing = spacing
        self.separation = separation
    }
}

public struct StructPiece {
    public let x0: Int, y0: Int, z0: Int, x1: Int, y1: Int, z1: Int
    public let build: (Builder) -> Void
}

public struct StructRefBox {
    public let x0: Int, y0: Int, z0: Int, x1: Int, y1: Int, z1: Int
    public init(_ x0: Int, _ y0: Int, _ z0: Int, _ x1: Int, _ y1: Int, _ z1: Int) {
        self.x0 = x0; self.y0 = y0; self.z0 = z0
        self.x1 = x1; self.y1 = y1; self.z1 = z1
    }
}

public struct StructurePlan {
    public let id: String
    public let pieces: [StructPiece]
    /// world-space ref box stored on chunks for runtime queries (mob spawning)
    public var ref: StructRefBox?

    public init(id: String, pieces: [StructPiece], ref: StructRefBox? = nil) {
        self.id = id
        self.pieces = pieces
        self.ref = ref
    }
}

public struct StructureDef {
    public let id: String
    public let spacing: Int
    public let separation: Int
    public let salt: UInt32
    public let maxRadiusChunks: Int
    public let placement: (GenCtx) -> StructurePlacement?
    public let check: (GenCtx, Int, Int, Rng) -> Bool
    public let plan: (GenCtx, Int, Int, Rng) -> StructurePlan?

    public init(id: String, spacing: Int, separation: Int, salt: UInt32, maxRadiusChunks: Int,
                placement: ((GenCtx) -> StructurePlacement?)? = nil,
                check: @escaping (GenCtx, Int, Int, Rng) -> Bool,
                plan: @escaping (GenCtx, Int, Int, Rng) -> StructurePlan?) {
        self.id = id
        self.spacing = spacing
        self.separation = separation
        self.salt = salt
        self.maxRadiusChunks = maxRadiusChunks
        self.placement = placement ?? { _ in
            StructurePlacement(spacing: spacing, separation: separation)
        }
        self.check = check
        self.plan = plan
    }
}

/// A cache identity for the immutable structure domain. Closures are not
/// comparable, so use the complete frozen placement tuple instead. The
/// production registry has one definition per id; retaining the full tuple
/// also makes synthetic tests independent of input-array order.
public func structureDefinitionDomainIdentity(_ definitions: [StructureDef]) -> String {
    definitions.map { def in
        "\(def.id):\(def.salt):\(def.spacing):\(def.separation):\(def.maxRadiusChunks)"
    }.sorted().joined(separator: "|")
}

public struct StructRef {
    public let id: String
    public let x0: Int, y0: Int, z0: Int, x1: Int, y1: Int, z1: Int
}

// ---------------------------------------------------------------------------
// Builder
// ---------------------------------------------------------------------------
public final class Builder {
    public let s: ChunkSink
    public let rng: Rng

    public init(_ s: ChunkSink, _ rng: Rng) {
        self.s = s
        self.rng = rng
    }

    public func set(_ x: Int, _ y: Int, _ z: Int, _ c: Int) { s.set(x, y, z, UInt16(c)) }
    public func get(_ x: Int, _ y: Int, _ z: Int) -> Int { s.get(x, y, z) }

    public func fill(_ x0: Int, _ y0: Int, _ z0: Int, _ x1: Int, _ y1: Int, _ z1: Int, _ c: Int) {
        var y = y0
        while y <= y1 {
            var z = z0
            while z <= z1 {
                var x = x0
                while x <= x1 { s.set(x, y, z, UInt16(c)); x += 1 }
                z += 1
            }
            y += 1
        }
    }
    public func fillRandom(_ x0: Int, _ y0: Int, _ z0: Int, _ x1: Int, _ y1: Int, _ z1: Int, _ choices: [(Int, Double)]) {
        var total = 0.0
        for ch in choices { total += ch.1 }
        var y = y0
        while y <= y1 {
            var z = z0
            while z <= z1 {
                var x = x0
                while x <= x1 {
                    var r = rng.nextFloat() * total
                    for (c, w) in choices {
                        r -= w
                        if r <= 0 { s.set(x, y, z, UInt16(c)); break }
                    }
                    x += 1
                }
                z += 1
            }
            y += 1
        }
    }
    public func walls(_ x0: Int, _ y0: Int, _ z0: Int, _ x1: Int, _ y1: Int, _ z1: Int, _ wall: Int, _ inner: Int) {
        var y = y0
        while y <= y1 {
            var z = z0
            while z <= z1 {
                var x = x0
                while x <= x1 {
                    let isWall = x == x0 || x == x1 || z == z0 || z == z1 || y == y0 || y == y1
                    s.set(x, y, z, UInt16(isWall ? wall : inner))
                    x += 1
                }
                z += 1
            }
            y += 1
        }
    }
    /// clear box to air
    public func clear(_ x0: Int, _ y0: Int, _ z0: Int, _ x1: Int, _ y1: Int, _ z1: Int) {
        fill(x0, y0, z0, x1, y1, z1, 0)
    }
    /// column of c from y down until solid ground (foundation)
    public func foundation(_ x: Int, _ yTop: Int, _ z: Int, _ c: Int, _ maxDepth: Int = 8) {
        for d in 0..<maxDepth {
            let y = yTop - d
            let cur = s.get(x, y, z)
            if cur > 0 && UInt16(cur >> 4) != B.water && UInt16(cur >> 4) != B.lava && d > 0 { return }
            s.set(x, y, z, UInt16(c))
        }
    }
    public func chest(_ x: Int, _ y: Int, _ z: Int, _ facing: Int, _ lootTable: String) {
        s.set(x, y, z, cell(B.chest, facing))
        s.addBlockEntity(BESpec(x: x, y: y, z: z, kind: "chest_loot",
                                data: ["lootTable": .str(lootTable), "seed": .num(Double(hash2(0, x, z, UInt32(truncatingIfNeeded: y))))]))
    }
    public func barrelLoot(_ x: Int, _ y: Int, _ z: Int, _ lootTable: String) {
        s.set(x, y, z, cell(B.barrel, 1))
        s.addBlockEntity(BESpec(x: x, y: y, z: z, kind: "chest_loot",
                                data: ["lootTable": .str(lootTable), "seed": .num(Double(hash2(0, x, z, UInt32(truncatingIfNeeded: y))))]))
    }
    public func spawner(_ x: Int, _ y: Int, _ z: Int, _ mob: String) {
        s.set(x, y, z, cell(B.spawner))
        s.addBlockEntity(BESpec(x: x, y: y, z: z, kind: "spawner", data: ["mob": .str(mob)]))
    }
    public func mob(_ mobName: String, _ x: Int, _ y: Int, _ z: Int, _ data: [String: BEValue] = [:]) {
        s.addEntity(EntitySpec(mob: mobName, x: Double(x) + 0.5, y: Double(y), z: Double(z) + 0.5, data: data))
    }
    public func suspicious(_ x: Int, _ y: Int, _ z: Int, _ gravel: Bool, _ lootTable: String) {
        s.set(x, y, z, cell(gravel ? B.suspicious_gravel : B.suspicious_sand))
        s.addBlockEntity(BESpec(x: x, y: y, z: z, kind: "brushable", data: ["lootTable": .str(lootTable)]))
    }

    public enum PaletteEntry {
        case cell(Int)
        case fn((Rng, Int) -> Int)
    }

    /// Stamp an ASCII template. layers bottom-to-top; row index = z.
    public func template(_ ox: Int, _ oy: Int, _ oz: Int, _ layers: [[String]],
                         _ palette: [Character: PaletteEntry], _ rot: Int = 0) {
        for (ly, rows) in layers.enumerated() {
            for (lz, row) in rows.enumerated() {
                for (lx, ch) in row.enumerated() {
                    if ch == " " { continue }
                    var c: Int
                    if ch == "." { c = 0 }
                    else {
                        guard let p = palette[ch] else { continue }
                        switch p {
                        case .cell(let v): c = v
                        case .fn(let f): c = f(rng, rot)
                        }
                    }
                    var wx: Int, wz: Int
                    switch rot & 3 {
                    case 0: wx = ox + lx; wz = oz + lz
                    case 1: wx = ox - lz; wz = oz + lx
                    case 2: wx = ox - lx; wz = oz - lz
                    default: wx = ox + lz; wz = oz - lx
                    }
                    s.set(wx, oy + ly, wz, UInt16(c))
                }
            }
        }
    }
}

/// Detached per-chunk structure mutation buffer. Structure closures can read
/// staged writes, but the target sink is untouched until every intersecting
/// piece has finished. Commit order installs blocks first, then block entities, then
/// entity spawns so callbacks never observe half-built post-state.
private final class BufferedChunkSink: ChunkSink {
    let cx: Int
    let cz: Int
    let minY: Int
    let maxY: Int
    private let base: ChunkSink

    private struct CellKey: Hashable { let x: Int; let y: Int; let z: Int }
    private struct Write { let key: CellKey; let cell: UInt16 }
    private var writes: [Write] = []
    private var latest: [CellKey: UInt16] = [:]
    private var blockEntities: [BESpec] = []
    private var entities: [EntitySpec] = []

    init(_ base: ChunkSink) {
        self.base = base
        cx = base.cx; cz = base.cz; minY = base.minY; maxY = base.maxY
    }

    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        guard floorDiv(x, 16) == cx, floorDiv(z, 16) == cz, y >= minY, y < maxY else { return }
        let key = CellKey(x: x, y: y, z: z)
        writes.append(Write(key: key, cell: c))
        latest[key] = c
    }

    func get(_ x: Int, _ y: Int, _ z: Int) -> Int {
        latest[CellKey(x: x, y: y, z: z)].map(Int.init) ?? base.get(x, y, z)
    }

    func topY(_ x: Int, _ z: Int) -> Int {
        guard floorDiv(x, 16) == cx, floorDiv(z, 16) == cz else { return base.topY(x, z) }
        for y in stride(from: maxY - 1, through: minY, by: -1) {
            let value = get(x, y, z)
            guard value > 0 else { continue }
            let id = value >> 4
            if id == Int(B.water) || id == Int(B.lava) || SOLID[id] == 1 { return y + 1 }
        }
        return minY + 1
    }

    func hasBlockEntity(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        blockEntities.contains { $0.x == x && $0.y == y && $0.z == z }
            || base.hasBlockEntity(x, y, z)
    }

    func addBlockEntity(_ spec: BESpec) {
        guard floorDiv(spec.x, 16) == cx, floorDiv(spec.z, 16) == cz,
              spec.y >= minY, spec.y < maxY else { return }
        blockEntities.append(spec)
    }

    func addEntity(_ spec: EntitySpec) {
        let x = Int(spec.x.rounded(.down)), z = Int(spec.z.rounded(.down))
        guard floorDiv(x, 16) == cx, floorDiv(z, 16) == cz else { return }
        entities.append(spec)
    }

    func commit() {
        for write in writes { base.set(write.key.x, write.key.y, write.key.z, write.cell) }
        for spec in blockEntities { base.addBlockEntity(spec) }
        for spec in entities { base.addEntity(spec) }
    }
}

/// rotate a horizontal facing (0=N 1=S 2=W 3=E) by template rotation
public func rotF(_ facing: Int, _ rot: Int) -> Int {
    let cw = [3, 2, 0, 1] // N→E, S→W, W→N, E→S
    var f = facing
    for _ in 0..<(rot & 3) { f = cw[f] }
    return f
}

// ---------------------------------------------------------------------------
// Registry + chunk build
// ---------------------------------------------------------------------------
public var STRUCTURES: [StructureDef] = []
public func registerStructure(_ def: StructureDef) { STRUCTURES.append(def) }

// Conventional overworld landmarks share land with one another, so their
// footprint conflict policy must not depend on the order in which chunks (or
// registry entries) happen to be replayed.  Villages retain their older,
// stricter foreign-landmark rejection in StructOverworld: that policy is
// intentionally outside this resolver until it can be revised independently.
//
// The numeric order is frozen deliberately.  It follows the established
// landmark registration order, then origin coordinates and frozen registry
// position make same-class decisions explicit as well.  Do not infer this
// order from an input [StructureDef] array: test harnesses and callers may
// supply equivalent definitions in a different order.
@inline(__always)
private func conventionalSurfaceStructurePriority(_ id: String) -> Int? {
    switch id {
    case "desert_temple": return 0
    case "jungle_temple": return 1
    case "igloo": return 2
    case "witch_hut": return 3
    case "pillager_outpost": return 4
    case "woodland_mansion": return 5
    // Ruined portals are placed after the established landmark classes. They
    // must lose a real overlap instead of stamping across an accepted
    // outpost/mansion (including its block entities).
    case "ruined_portal": return 6
    default: return nil
    }
}

@inline(__always)
private func isConventionalSurfaceStructure(_ def: StructureDef) -> Bool {
    conventionalSurfaceStructurePriority(def.id) != nil
}

/// Compare immutable definition fields rather than an input array position.
/// The registry has exactly one production definition for each conventional
/// id; the complete tuple also keeps synthetic tests independent of closure
/// identity, which Swift cannot compare.
private func sameSurfaceStructureDefinition(_ lhs: StructureDef, _ rhs: StructureDef) -> Bool {
    lhs.id == rhs.id
        && lhs.spacing == rhs.spacing
        && lhs.separation == rhs.separation
        && lhs.salt == rhs.salt
        && lhs.maxRadiusChunks == rhs.maxRadiusChunks
}

/// Registry position is a final, frozen tie-breaker after rank and origin. A
/// stable immutable fallback makes focused tests (whose definitions are not
/// registered globally) just as independent of their supplied array order.
private func frozenSurfaceStructureRegistrationIndex(_ def: StructureDef) -> Int {
    for (index, registered) in STRUCTURES.enumerated()
    where sameSurfaceStructureDefinition(registered, def) {
        return index
    }
    return Int.max
}

private func surfaceDefinitionFallbackPrecedes(_ lhs: StructureDef, _ rhs: StructureDef) -> Bool {
    if lhs.id != rhs.id { return lhs.id < rhs.id }
    if lhs.salt != rhs.salt { return lhs.salt < rhs.salt }
    if lhs.spacing != rhs.spacing { return lhs.spacing < rhs.spacing }
    if lhs.separation != rhs.separation { return lhs.separation < rhs.separation }
    return lhs.maxRadiusChunks < rhs.maxRadiusChunks
}

/// Strict total ordering for accepted conventional landmark plans. This must
/// remain independent of target chunk and `dimStructures` traversal order.
private func surfacePlanPrecedes(_ lhsDef: StructureDef, _ lhsOriginX: Int, _ lhsOriginZ: Int,
                                 _ rhsDef: StructureDef, _ rhsOriginX: Int, _ rhsOriginZ: Int) -> Bool {
    guard let lhsPriority = conventionalSurfaceStructurePriority(lhsDef.id),
          let rhsPriority = conventionalSurfaceStructurePriority(rhsDef.id) else {
        return false
    }
    if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
    if lhsOriginX != rhsOriginX { return lhsOriginX < rhsOriginX }
    if lhsOriginZ != rhsOriginZ { return lhsOriginZ < rhsOriginZ }
    let lhsIndex = frozenSurfaceStructureRegistrationIndex(lhsDef)
    let rhsIndex = frozenSurfaceStructureRegistrationIndex(rhsDef)
    if lhsIndex != rhsIndex { return lhsIndex < rhsIndex }
    return surfaceDefinitionFallbackPrecedes(lhsDef, rhsDef)
}

private func orderedConventionalSurfaceDefinitions(_ definitions: [StructureDef]) -> [StructureDef] {
    definitions.filter(isConventionalSurfaceStructure).sorted {
        surfacePlanPrecedes($0, 0, 0, $1, 0, 0)
    }
}

/// Collision evidence is only the pieces that can really emit blocks. Ref
/// boxes are runtime metadata and candidate lattice bounds merely make the
/// search finite; neither is allowed to decide an overlap.
func surfaceStructurePiecesOverlapXZ(_ lhs: [StructPiece], _ rhs: [StructPiece]) -> Bool {
    for first in lhs {
        for second in rhs where !(first.x1 < second.x0 || second.x1 < first.x0
                                  || first.z1 < second.z0 || second.z1 < first.z0) {
            return true
        }
    }
    return false
}

/// Deterministic signature for the collision domain. It intentionally ignores
/// non-conventional structures, whose placement remains governed by their
/// own semantics (notably the village planner).
func conventionalSurfaceCollisionSignature(_ definitions: [StructureDef]) -> String {
    orderedConventionalSurfaceDefinitions(definitions).map { def in
        "\(conventionalSurfaceStructurePriority(def.id) ?? Int.max):\(frozenSurfaceStructureRegistrationIndex(def)):" +
            "\(def.id):\(def.salt):\(def.spacing):\(def.separation):\(def.maxRadiusChunks)"
    }.joined(separator: "|")
}

private struct StructurePlanCacheKey: Hashable {
    let seed: UInt32
    let dim: Int
    let generationSettingsIdentity: String
    let baseTerrainOracleVersion: Int
    let activeStructureDomainIdentity: String
    let structureID: String
    let ocx: Int
    let ocz: Int
}

private enum StructurePlanCacheValue {
    case accepted(StructurePlan)
    case rejected

    var plan: StructurePlan? {
        switch self {
        case .accepted(let plan): return plan
        case .rejected: return nil
        }
    }
}

struct StructurePlanCacheStats: Equatable {
    public let entries: Int
    public let computations: Int
    public let waits: Int
}

private var planCache: [StructurePlanCacheKey: StructurePlanCacheValue] = [:]
private var planCacheInFlight: Set<StructurePlanCacheKey> = []
private var planCacheComputations = 0
private var planCacheWaits = 0
private let planCacheCondition = NSCondition()

/// A conventional-landmark decision is keyed by its candidate origin and
/// complete generation context, never by the chunk currently being stamped.
/// That prevents a cross-chunk plan from winning on one side of a seam and
/// losing on the other. Duplicate calculations are harmless: all plan reads
/// are deterministic and the installed Boolean is the same result.
private struct SurfacePlanWinnerCacheKey: Hashable {
    let seed: UInt32
    let dim: Int
    let generationSettingsIdentity: String
    let baseTerrainOracleVersion: Int
    let activeStructureDomainIdentity: String
    let structureID: String
    let structureSalt: UInt32
    let structureSpacing: Int
    let structureSeparation: Int
    let structureRadius: Int
    let ocx: Int
    let ocz: Int
    let collisionSignature: String
}

private var surfacePlanWinnerCache: [SurfacePlanWinnerCacheKey: Bool] = [:]
private let surfacePlanWinnerCacheLock = NSLock()
private let surfacePlanWinnerCacheLimit = 4_096

func resetStructurePlanCacheForTesting() {
    planCacheCondition.lock()
    while !planCacheInFlight.isEmpty { planCacheCondition.wait() }
    planCache.removeAll(keepingCapacity: false)
    planCacheComputations = 0
    planCacheWaits = 0
    planCacheCondition.unlock()

    surfacePlanWinnerCacheLock.lock()
    surfacePlanWinnerCache.removeAll(keepingCapacity: false)
    surfacePlanWinnerCacheLock.unlock()
}

func structurePlanCacheStatsForTesting() -> StructurePlanCacheStats {
    planCacheCondition.lock()
    defer { planCacheCondition.unlock() }
    return StructurePlanCacheStats(entries: planCache.count,
                                   computations: planCacheComputations,
                                   waits: planCacheWaits)
}

public func structureOriginFor(_ def: StructureDef, _ seed: UInt32, _ rcx: Int, _ rcz: Int) -> (Int, Int) {
    structureOriginFor(def, placement: StructurePlacement(spacing: def.spacing,
                                                           separation: def.separation),
                       seed: seed, regionX: rcx, regionZ: rcz)
}

public func structureOriginFor(_ def: StructureDef, placement: StructurePlacement,
                               seed: UInt32, regionX: Int, regionZ: Int) -> (Int, Int) {
    var rng = RandomX(hash2(seed, regionX, regionZ, def.salt))
    let range = max(1, placement.spacing - placement.separation)
    return (regionX * placement.spacing + rng.nextInt(range),
            regionZ * placement.spacing + rng.nextInt(range))
}

public func getPlan(_ def: StructureDef, _ ctx: GenCtx, _ ocx: Int, _ ocz: Int) -> StructurePlan? {
    let key = StructurePlanCacheKey(seed: ctx.seed, dim: ctx.dim,
                                    generationSettingsIdentity: ctx.generationSettingsIdentity,
                                    baseTerrainOracleVersion: ctx.baseTerrainOracleVersion,
                                    activeStructureDomainIdentity: ctx.activeStructureDomainIdentity,
                                    structureID: def.id, ocx: ocx, ocz: ocz)
    planCacheCondition.lock()
    while true {
        if let cached = planCache[key] {
            planCacheCondition.unlock()
            return cached.plan
        }
        if !planCacheInFlight.contains(key) {
            planCacheInFlight.insert(key)
            planCacheComputations += 1
            planCacheCondition.unlock()
            break
        }
        planCacheWaits += 1
        planCacheCondition.wait()
    }
    // A GenCtx may be shared by a caller that has already spent some of its
    // oracle budget on unrelated candidates. Plans are global-cache values,
    // so they must never inherit that mutable history. Exact Overworld plans
    // therefore receive a fresh bounded oracle whose seed/settings are the
    // only inputs; non-Overworld and legacy contexts keep their original
    // height/floor semantics.
    let planCtx: GenCtx
    if ctx.dim == Dim.overworld.rawValue, let oracle = ctx.terrainOracle {
        planCtx = GenCtx(seed: ctx.seed,
                         heightAt: ctx.heightAt,
                         biomeAt: ctx.biomeAt,
                         dim: ctx.dim,
                         villageDensity: ctx.villageDensity,
                         generationSettingsIdentity: ctx.generationSettingsIdentity,
                         baseTerrainOracleVersion: ctx.baseTerrainOracleVersion,
                         terrainOracle: BaseTerrainOracle(
                             seed: ctx.seed, settings: oracle.settings,
                             maxCachedChunks: structurePlanOracleMaxCachedChunks,
                             maxQueries: structurePlanOracleMaxQueries),
                         activeStructureDefinitions: ctx.activeStructureDefinitions)
    } else {
        planCtx = ctx
    }
    let rng = Rng(hash2(planCtx.seed, ocx, ocz, def.salt ^ 0x5757))
    var plan: StructurePlan?
    if def.check(planCtx, ocx, ocz, rng) {
        plan = def.plan(planCtx, ocx, ocz, Rng(hash2(planCtx.seed, ocx, ocz, def.salt ^ 0x1234)))
    }
    if plan?.pieces.count ?? 0 > 256 { plan = nil }
    let computed: StructurePlanCacheValue = plan.map(StructurePlanCacheValue.accepted) ?? .rejected
    planCacheCondition.lock()
    if planCache.count >= 600 {
        planCache.removeAll(keepingCapacity: true) // recompute is deterministic; policy is correctness-neutral
    }
    let installed = planCache[key] ?? computed
    planCache[key] = installed
    planCacheInFlight.remove(key)
    planCacheCondition.broadcast()
    planCacheCondition.unlock()
    return installed.plan
}

private func surfacePlanWinnerCacheKey(_ def: StructureDef, _ ctx: GenCtx,
                                       _ ocx: Int, _ ocz: Int,
                                       collisionSignature: String) -> SurfacePlanWinnerCacheKey {
    SurfacePlanWinnerCacheKey(seed: ctx.seed, dim: ctx.dim,
                              generationSettingsIdentity: ctx.generationSettingsIdentity,
                              baseTerrainOracleVersion: ctx.baseTerrainOracleVersion,
                              activeStructureDomainIdentity: ctx.activeStructureDomainIdentity,
                              structureID: def.id, structureSalt: def.salt,
                              structureSpacing: def.spacing, structureSeparation: def.separation,
                              structureRadius: def.maxRadiusChunks,
                              ocx: ocx, ocz: ocz,
                              collisionSignature: collisionSignature)
}

/// Returns whether this already-planned conventional landmark is the one
/// allowed to materialize among actually overlapping conventional surface
/// plans. Candidate lattice/radius math only bounds which raw plans we inspect;
/// actual StructPiece XZ overlap is the sole collision evidence.
///
/// The function deliberately lives outside `getPlan`: calling it while plans
/// are being constructed would recurse through nearby candidates and make the
/// result depend on cache timing. Callers invoke it after obtaining a raw plan,
/// before either emitting pieces or reserving feature-clearance space.
public func surfaceStructurePlanWins(_ def: StructureDef, _ plan: StructurePlan,
                                     _ ctx: GenCtx, _ ocx: Int, _ ocz: Int,
                                     collisionDefinitions: [StructureDef]) -> Bool {
    guard isConventionalSurfaceStructure(def), !plan.pieces.isEmpty else { return true }
    let conventionalDefinitions = orderedConventionalSurfaceDefinitions(collisionDefinitions)
    guard !conventionalDefinitions.isEmpty else { return true }

    let signature = conventionalSurfaceCollisionSignature(conventionalDefinitions)
    let key = surfacePlanWinnerCacheKey(def, ctx, ocx, ocz, collisionSignature: signature)
    surfacePlanWinnerCacheLock.lock()
    if let cached = surfacePlanWinnerCache[key] {
        surfacePlanWinnerCacheLock.unlock()
        return cached
    }
    surfacePlanWinnerCacheLock.unlock()

    var minX = Int.max, maxX = Int.min
    var minZ = Int.max, maxZ = Int.min
    for piece in plan.pieces {
        minX = min(minX, piece.x0); maxX = max(maxX, piece.x1)
        minZ = min(minZ, piece.z0); maxZ = max(maxZ, piece.z1)
    }
    let minChunkX = floorDiv(minX, 16)
    let maxChunkX = floorDiv(maxX, 16)
    let minChunkZ = floorDiv(minZ, 16)
    let maxChunkZ = floorDiv(maxZ, 16)

    var winner = true
    candidateLoop: for candidate in conventionalDefinitions {
        guard let placement = candidate.placement(ctx) else { continue }
        // `maxRadiusChunks` is a conservative enumeration bound supplied by
        // the definition. We still inspect every returned piece below; a
        // candidate inside this search window wins only on real XZ overlap.
        let radius = candidate.maxRadiusChunks
        let regionX0 = floorDiv(minChunkX - radius, placement.spacing)
        let regionX1 = floorDiv(maxChunkX + radius, placement.spacing)
        let regionZ0 = floorDiv(minChunkZ - radius, placement.spacing)
        let regionZ1 = floorDiv(maxChunkZ + radius, placement.spacing)
        for regionZ in regionZ0...regionZ1 {
            for regionX in regionX0...regionX1 {
                let origin = structureOriginFor(candidate, placement: placement,
                                                 seed: ctx.seed, regionX: regionX, regionZ: regionZ)
                if sameSurfaceStructureDefinition(candidate, def)
                    && origin.0 == ocx && origin.1 == ocz {
                    continue
                }
                guard let otherPlan = getPlan(candidate, ctx, origin.0, origin.1),
                      surfaceStructurePiecesOverlapXZ(plan.pieces, otherPlan.pieces) else {
                    continue
                }
                if surfacePlanPrecedes(candidate, origin.0, origin.1, def, ocx, ocz) {
                    winner = false
                    break candidateLoop
                }
            }
        }
    }

    surfacePlanWinnerCacheLock.lock()
    if surfacePlanWinnerCache.count >= surfacePlanWinnerCacheLimit {
        surfacePlanWinnerCache.removeAll(keepingCapacity: true)
    }
    let installed = surfacePlanWinnerCache[key] ?? winner
    surfacePlanWinnerCache[key] = installed
    surfacePlanWinnerCacheLock.unlock()
    return installed
}

public func buildStructuresForChunk(_ ctx: GenCtx, _ cx: Int, _ cz: Int, _ sink: ChunkSink, _ dimStructures: [StructureDef]) -> [StructRef] {
    var refs: [StructRef] = []
    let chunkX0 = cx * 16, chunkZ0 = cz * 16
    let buffered = BufferedChunkSink(sink)
    for def in dimStructures {
        guard let placement = def.placement(ctx) else { continue }
        let r = def.maxRadiusChunks
        let rc0x = floorDiv(cx - r, placement.spacing), rc1x = floorDiv(cx + r, placement.spacing)
        let rc0z = floorDiv(cz - r, placement.spacing), rc1z = floorDiv(cz + r, placement.spacing)
        for rcz in rc0z...rc1z {
            for rcx in rc0x...rc1x {
                let (ocx, ocz) = structureOriginFor(def, placement: placement,
                                                     seed: ctx.seed, regionX: rcx, regionZ: rcz)
                if abs(ocx - cx) > r || abs(ocz - cz) > r { continue }
                guard let plan = getPlan(def, ctx, ocx, ocz) else { continue }
                guard surfaceStructurePlanWins(def, plan, ctx, ocx, ocz,
                                               collisionDefinitions: dimStructures) else { continue }
                for (pi, piece) in plan.pieces.enumerated() {
                    // does the piece intersect this chunk?
                    if piece.x1 < chunkX0 || piece.x0 > chunkX0 + 15 || piece.z1 < chunkZ0 || piece.z0 > chunkZ0 + 15 { continue }
                    // rng is a pure function of (structure, piece) — NEVER the
                    // target chunk — so a piece spanning a chunk border draws the
                    // identical stream in both rebuilds (rails/decay/chests used
                    // to discontinue exactly at chunk seams)
                    let b = Builder(buffered, Rng(hash2(ctx.seed, ocx &* 1_000_003 &+ pi, ocz &* 31 &- pi, def.salt ^ 0x9999)))
                    piece.build(b)
                }
                if let rf = plan.ref {
                    if !(rf.x1 < chunkX0 || rf.x0 > chunkX0 + 15 || rf.z1 < chunkZ0 || rf.z0 > chunkZ0 + 15) {
                        refs.append(StructRef(id: def.id, x0: rf.x0, y0: rf.y0, z0: rf.z0, x1: rf.x1, y1: rf.y1, z1: rf.z1))
                    }
                }
            }
        }
    }
    buffered.commit()
    return refs
}

/// simple piece helper
public func piece(_ x0: Int, _ y0: Int, _ z0: Int, _ x1: Int, _ y1: Int, _ z1: Int, _ build: @escaping (Builder) -> Void) -> StructPiece {
    StructPiece(x0: x0, y0: y0, z0: z0, x1: x1, y1: y1, z1: z1, build: build)
}

/// stronghold ring positions — pure function of seed, also used by eyes of ender
public func strongholdPositions(_ seed: UInt32) -> [(Int, Int)] {
    var rng = RandomX(hash2(seed, 0, 0, 0x57A0))
    var out: [(Int, Int)] = []
    let baseAngle = rng.nextFloat() * Double.pi * 2
    for ring in 0..<3 {
        let count = ring == 0 ? 3 : ring == 1 ? 6 : 10
        let radius = Double(1280 + ring * 3072 + rng.nextInt(640))
        for i in 0..<count {
            let ang = baseAngle + Double(ring) * 0.7 + (Double(i) / Double(count)) * Double.pi * 2 + (rng.nextFloat() - 0.5) * 0.3
            let dist = radius + Double(rng.nextInt(512))
            out.append((Int((detCos(ang) * dist / 16).rounded(.down)), Int((detSin(ang) * dist / 16).rounded(.down))))
        }
    }
    return out
}
