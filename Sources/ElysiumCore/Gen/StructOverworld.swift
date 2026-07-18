// Overworld surface structures —
// villages (5 styles), desert & jungle temples, igloos, witch huts, pillager
// outposts, shipwrecks, ocean ruins, buried treasure, ruined portals, trail
// ruins and dungeons. The legacy dungeon pass mirrors baseline RNG exactly;
// higher density levels add deterministic independent passes.

import Foundation

private let AIR = 0

// =============================================================================
// VILLAGE
// =============================================================================
struct VillageStyle {
    var planks: Int
    var log: Int
    var stairs: Int
    var slab: Int
    var wall: Int
    var path: Int
    var fence: Int
    var door: UInt16
    var window: Int
    var farmFrame: Int
    var roofStairs: Int
}

private func styleFor(_ biomeId: Int) -> VillageStyle? {
    func mk(_ wood: String, _ wallBlock: Int, _ path: Int, _ window: Int = Int(cell(B.glass_pane))) -> VillageStyle {
        VillageStyle(
            planks: Int(cell(bid("\(wood)_planks"))), log: Int(cell(bid("\(wood)_log"))),
            stairs: Int(cell(bid("\(wood)_stairs"))), slab: Int(cell(bid("\(wood)_slab"))),
            wall: wallBlock, path: path, fence: Int(cell(bid("\(wood)_fence"))), door: bid("\(wood)_door"),
            window: window, farmFrame: Int(cell(bid("\(wood)_log"))),
            roofStairs: Int(cell(bid("\(wood)_stairs")))
        )
    }
    switch biomeId {
    case Biome.plains.rawValue, Biome.sunflowerPlains.rawValue, Biome.meadow.rawValue:
        return mk("oak", Int(cell(B.cobblestone)), Int(cell(B.dirt_path)))
    case Biome.desert.rawValue:
        var st = mk("jungle", Int(cell(B.sandstone)), Int(cell(B.smooth_sandstone)))
        st.planks = Int(cell(B.smooth_sandstone))
        st.log = Int(cell(B.cut_sandstone))
        st.stairs = Int(cell(B.sandstone_stairs))
        st.slab = Int(cell(B.sandstone_slab))
        st.roofStairs = Int(cell(B.sandstone_stairs))
        st.fence = Int(cell(B.sandstone_wall))
        st.door = B.oak_door
        return st
    case Biome.savanna.rawValue, Biome.savannaPlateau.rawValue:
        return mk("acacia", Int(cell(B.cobblestone)), Int(cell(B.dirt_path)))
    case Biome.taiga.rawValue, Biome.oldGrowthPineTaiga.rawValue, Biome.oldGrowthSpruceTaiga.rawValue:
        return mk("spruce", Int(cell(B.cobblestone)), Int(cell(B.dirt_path)))
    case Biome.snowyPlains.rawValue, Biome.snowyTaiga.rawValue:
        return mk("spruce", Int(cell(B.snow_block)), Int(cell(B.snow_block)), Int(cell(B.glass_pane)))
    default:
        return nil
    }
}

private func houseSmall(_ b: Builder, _ x: Int, _ y: Int, _ z: Int, _ st: VillageStyle, _ rot: Int, _ sink: ChunkSink) {
    // 5×5 footprint, walls 3 high, stair roof
    for dz in 0..<5 { for dx in 0..<5 { b.foundation(x + dx, y - 1, z + dz, st.wall) } }
    b.fill(x, y, z, x + 4, y + 2, z + 4, AIR)
    b.fill(x + 1, y + 3, z + 1, x + 3, y + 3, z + 3, AIR)
    // walls
    for h in 0..<3 {
        for d in 0..<5 {
            b.set(x + d, y + h, z, h == 1 && d == 2 ? st.window : st.planks)
            b.set(x + d, y + h, z + 4, h == 1 && d == 2 ? st.window : st.planks)
            b.set(x, y + h, z + d, h == 1 && d == 2 ? st.window : st.planks)
            b.set(x + 4, y + h, z + d, st.planks)
        }
    }
    for (cx2, cz2) in [(0, 0), (4, 0), (0, 4), (4, 4)] {
        for h in 0..<3 { b.set(x + cx2, y + h, z + cz2, st.log) }
    }
    // slab roof with planks core
    for dz in -1...5 { for dx in -1...5 {
        b.set(x + dx, y + 3, z + dz, (dx >= 1 && dx <= 3 && dz >= 1 && dz <= 3) ? st.planks : st.slab)
    } }
    b.set(x + 2, y + 4, z + 2, st.slab)
    // door (south face center)
    let doorFace = rotF(0, rot)
    b.set(x + 2, y, z, Int(cell(st.door, doorFace)))
    b.set(x + 2, y + 1, z, Int(cell(st.door, 8)))
    // interior: bed + crafting
    b.set(x + 3, y, z + 3, Int(cell(B.red_bed, 2 | 4)))
    b.set(x + 3, y, z + 2, Int(cell(B.red_bed, 2)))
    b.set(x + 1, y, z + 3, Int(cell(B.crafting_table)))
    b.set(x + 1, y + 2, z + 1, Int(cell(B.torch)))
    sink.addEntity(EntitySpec(mob: "villager", x: Double(x) + 2.5, y: Double(y), z: Double(z) + 2.5))
}

private func houseJob(_ b: Builder, _ x: Int, _ y: Int, _ z: Int, _ st: VillageStyle, _ jobBlock: Int, _ lootTable: String?, _ sink: ChunkSink) {
    for dz in 0..<6 { for dx in 0..<6 { b.foundation(x + dx, y - 1, z + dz, st.wall) } }
    b.fill(x, y, z, x + 5, y + 3, z + 5, AIR)
    for h in 0..<3 {
        for d in 0..<6 {
            b.set(x + d, y + h, z, h == 1 && (d == 2 || d == 3) ? st.window : st.planks)
            b.set(x + d, y + h, z + 5, h == 1 && d == 2 ? st.window : st.planks)
            b.set(x, y + h, z + d, h == 1 && d == 3 ? st.window : st.planks)
            b.set(x + 5, y + h, z + d, st.planks)
        }
    }
    for (cx2, cz2) in [(0, 0), (5, 0), (0, 5), (5, 5)] {
        for h in 0..<3 { b.set(x + cx2, y + h, z + cz2, st.log) }
    }
    for dz in -1...6 { for dx in -1...6 {
        b.set(x + dx, y + 3, z + dz, (dx >= 1 && dx <= 4 && dz >= 1 && dz <= 4) ? st.planks : st.slab)
    } }
    b.set(x + 2, y, z, Int(cell(st.door, 0)))
    b.set(x + 2, y + 1, z, Int(cell(st.door, 8)))
    b.set(x + 4, y, z + 4, jobBlock)
    if let lootTable { b.chest(x + 1, y, z + 4, 3, lootTable) }
    b.set(x + 1, y + 2, z + 1, Int(cell(B.torch)))
    b.set(x + 4, y + 2, z + 1, Int(cell(B.torch)))
    sink.addEntity(EntitySpec(mob: "villager", x: Double(x) + 3.5, y: Double(y), z: Double(z) + 3.5))
}

private func farm(_ b: Builder, _ x: Int, _ y: Int, _ z: Int, _ st: VillageStyle, _ rng: Rng) {
    for dz in 0..<7 {
        for dx in 0..<9 {
            b.foundation(x + dx, y - 1, z + dz, Int(cell(B.dirt)))
            let edge = dx == 0 || dx == 8 || dz == 0 || dz == 6
            if edge {
                b.set(x + dx, y - 1, z + dz, st.farmFrame)
                b.set(x + dx, y, z + dz, AIR)
            } else if dx == 4 {
                b.set(x + dx, y - 1, z + dz, Int(cell(B.water, 0)))
            } else {
                b.set(x + dx, y - 1, z + dz, Int(cell(B.farmland, 7)))
                let crop = rng.nextFloat()
                b.set(x + dx, y, z + dz, crop < 0.5 ? Int(cell(B.wheat, 4 + rng.nextInt(4))) : crop < 0.75 ? Int(cell(B.carrots, 4 + rng.nextInt(4))) : Int(cell(B.potatoes, 4 + rng.nextInt(4))))
            }
        }
    }
    b.set(x, y, z, Int(cell(B.composter)))
}

private func well(_ b: Builder, _ x: Int, _ y: Int, _ z: Int, _ st: VillageStyle) {
    // enclosed shaft: stone walls down to a floor, water contained one below the rim
    for dy in -11...(-1) {
        for dz in -1...4 { for dx in -1...4 {
            let edge = dx == -1 || dx == 4 || dz == -1 || dz == 4
            if edge || dy == -11 { b.set(x + dx, y + dy, z + dz, st.wall) }
        } }
    }
    b.fill(x, y - 10, z, x + 3, y - 1, z + 3, Int(cell(B.water, 0)))
    // rim
    for dz in -1...4 { for dx in -1...4 {
        let edge = dx == -1 || dx == 4 || dz == -1 || dz == 4
        if edge {
            b.set(x + dx, y, z + dz, st.wall)
            b.foundation(x + dx, y - 1, z + dz, st.wall)
        }
    } }
    for (px, pz) in [(-1, -1), (4, -1), (-1, 4), (4, 4)] {
        b.set(x + px, y + 1, z + pz, st.fence)
        b.set(x + px, y + 2, z + pz, st.fence)
    }
    b.fill(x - 1, y + 3, z - 1, x + 4, y + 3, z + 4, st.slab)
}

private let villageCenterOffsets: [(Int, Int)] = [
    (0, 0), (-16, 0), (16, 0), (0, -16), (0, 16),
    (-16, -16), (16, -16), (-16, 16), (16, 16),
    (-32, 0), (32, 0), (0, -32), (0, 32),
]

private struct VillageXZFootprint {
    let x0: Int
    let z0: Int
    let x1: Int
    let z1: Int

    init(_ x0: Int, _ z0: Int, _ x1: Int, _ z1: Int) {
        self.x0 = min(x0, x1)
        self.z0 = min(z0, z1)
        self.x1 = max(x0, x1)
        self.z1 = max(z0, z1)
    }

    func intersects(_ other: VillageXZFootprint) -> Bool {
        x0 <= other.x1 && other.x0 <= x1 && z0 <= other.z1 && other.z0 <= z1
    }
}

private func dryVillageSurface(_ ctx: GenCtx, _ x: Int, _ z: Int) -> Int? {
    guard let oracle = ctx.terrainOracle,
          let occupied = oracle.highestOccupiedCell(x, z),
          let solidY = oracle.topSolidY(x, z) else { return nil }
    let id = occupied.cell >> 4
    guard id != Int(B.water), id != Int(B.lava), occupied.y == solidY else { return nil }
    return solidY + 1
}

/// Cheap ordered preflight. The exact occupied piece footprints are checked
/// after planning, so a coarse pass cannot authorize a wet or unsupported plan.
private func chooseVillageCenter(_ ctx: GenCtx, _ originX: Int, _ originZ: Int) -> (Int, Int)? {
    for (dx, dz) in villageCenterOffsets {
        let x = originX + dx, z = originZ + dz
        guard styleFor(ctx.biomeAt(x, z)) != nil else { continue }
        var heights: [Int] = []
        var valid = true
        for sz in stride(from: -40, through: 40, by: 8) {
            for sx in stride(from: -40, through: 40, by: 8) {
                guard let y = dryVillageSurface(ctx, x + sx, z + sz) else {
                    valid = false
                    break
                }
                heights.append(y)
            }
            if !valid { break }
        }
        if valid, let lo = heights.min(), let hi = heights.max(), hi - lo <= 12 { return (x, z) }
    }
    return nil
}

private func validateVillagePieces(_ ctx: GenCtx, _ pieces: [StructPiece]) -> Bool {
    guard !pieces.isEmpty else { return false }
    var checked = 0
    for p in pieces {
        var previousRow: [Int] = []
        for z in p.z0...p.z1 {
            var row: [Int] = []
            for x in p.x0...p.x1 {
                checked += 1
                guard checked <= 24_000, let y = dryVillageSurface(ctx, x, z) else { return false }
                row.append(y)
                if row.count > 1, abs(row[row.count - 1] - row[row.count - 2]) > 1 { return false }
                if !previousRow.isEmpty, abs(y - previousRow[row.count - 1]) > 1 { return false }
            }
            previousRow = row
        }
    }
    return true
}

// =============================================================================
// RUINED PORTAL (shared with nether)
// =============================================================================
public func buildRuinedPortal(_ b: Builder, _ x: Int, _ y: Int, _ z: Int, _ nether: Bool) {
    let OBS = Int(cell(B.obsidian)), CRY = Int(cell(B.crying_obsidian))
    let STONE_FILL = Int(cell(B.netherrack))
    let w = 4, h = 5
    // the nether variant decays less and runs hotter (more magma/lava) —
    // same rng draw count either way, only thresholds differ
    let decay = nether ? 0.15 : 0.25
    let magma = nether ? 0.5 : 0.25
    let lava = nether ? 0.8 : 0.5
    // frame with decay
    for dx in 0..<w {
        for dy in 0..<h {
            let isFrame = dx == 0 || dx == w - 1 || dy == 0 || dy == h - 1
            if !isFrame { continue }
            if b.rng.nextFloat() < decay { continue } // missing
            b.set(x + dx, y + dy, z, b.rng.nextFloat() < 0.18 ? CRY : OBS)
        }
    }
    // netherrack + magma splash
    for _ in 0..<14 {
        let px = x + b.rng.nextInt(7) - 2, pz = z + b.rng.nextInt(5) - 2
        let py = y - 1 + b.rng.nextInt(2) - 1
        let hot = b.rng.nextFloat() < magma
        let cur = b.get(px, py, pz)
        if cur > 0 { b.set(px, py, pz, hot ? Int(cell(B.magma_block)) : STONE_FILL) }
    }
    if b.rng.nextFloat() < lava { b.set(x + 1, y - 1, z + 1, Int(cell(B.lava, 0))) }
    b.chest(x - 2, y, z + 1, 0, "ruined_portal")
}

// =============================================================================
// DUNGEON (placed per-chunk, not region)
// =============================================================================
private struct DungeonRegionKey: Hashable {
    let seed: UInt32
    let settingsIdentity: String
    let rx: Int
    let rz: Int
    let passes: Int
}

private let dungeonRegionSide = 32
private let dungeonRegionCacheLimit = 64
private let dungeonRegionMaximumPasses = 8
private let dungeonRegionMaximumRawCandidates = dungeonRegionSide * dungeonRegionSide
    * dungeonRegionMaximumPasses * 4
private let dungeonRegionMaximumStoredMembers = dungeonRegionSide * dungeonRegionSide
    * dungeonRegionMaximumPasses
private let dungeonRegionMaximumRetainedBytesPerPlan = 512 * 1_024

private struct DungeonBudgetMember: Hashable {
    let cx: Int
    let cz: Int
    let pass: Int
}

private struct DungeonRawCandidate {
    let x: Int
    let y: Int
    let z: Int
    let halfWidth: Int
    let attempt: Int
}

private struct DungeonRegionPlan {
    let rawAcceptedCount: Int
    let underwater: Set<DungeonBudgetMember>
}

private var dungeonRegionPlans: [DungeonRegionKey: DungeonRegionPlan] = [:]
private var dungeonRegionInFlight: Set<DungeonRegionKey> = []
private let dungeonRegionCondition = NSCondition()

private func rawDungeonCandidates(_ seed: UInt32, _ cx: Int, _ cz: Int, pass: Int) -> [DungeonRawCandidate] {
    let salt = pass == 0 ? UInt32(0xD0D6E0) : dungeonPassSalt(pass)
    let rng = Rng(hash2(seed, cx, cz, salt))
    var result: [DungeonRawCandidate] = []
    result.reserveCapacity(4)
    for attempt in 0..<4 {
        guard rng.nextFloat() <= 0.12 else { continue }
        let x = cx * 16 + 3 + rng.nextInt(10)
        let z = cz * 16 + 3 + rng.nextInt(10)
        let y = -40 + rng.nextInt(90)
        let halfWidth = 3 + rng.nextInt(2)
        result.append(DungeonRawCandidate(x: x, y: y, z: z,
                                          halfWidth: halfWidth, attempt: attempt))
    }
    return result
}

@inline(__always)
private func dungeonRarityHash(_ seed: UInt32, _ cx: Int, _ cz: Int, _ pass: Int) -> UInt32 {
    hash2(seed, cx, cz, 0x55D3EA ^ UInt32(truncatingIfNeeded: pass))
}

private func buildDungeonRegionPlan(_ key: DungeonRegionKey) -> DungeonRegionPlan {
    precondition(key.passes >= 0 && key.passes <= dungeonRegionMaximumPasses)
    let x0 = key.rx * dungeonRegionSide, z0 = key.rz * dungeonRegionSide
    var raw: [(member: DungeonBudgetMember, hash: UInt32)] = []
    var rawCandidateCount = 0
    raw.reserveCapacity(512)
    for cz in z0..<(z0 + dungeonRegionSide) {
        for cx in x0..<(x0 + dungeonRegionSide) {
            for pass in 0..<key.passes {
                let candidates = rawDungeonCandidates(key.seed, cx, cz, pass: pass)
                rawCandidateCount += candidates.count
                guard !candidates.isEmpty else { continue }
                let member = DungeonBudgetMember(cx: cx, cz: cz, pass: pass)
                raw.append((member, dungeonRarityHash(key.seed, cx, cz, pass)))
            }
        }
    }
    precondition(rawCandidateCount <= dungeonRegionMaximumRawCandidates)
    precondition(raw.count <= dungeonRegionMaximumStoredMembers)
    let budget = rawCandidateCount / 16
    // 29 mod 64 preserves the reviewed pinned fixture (also 13 mod 16)
    // while keeping actual submerged rooms substantially rarer than the hard
    // regional 1/16 ceiling.
    let eligible = raw.filter { Int($0.hash & 0x3F) == 29 }.sorted {
        if $0.hash != $1.hash { return $0.hash < $1.hash }
        if $0.member.cx != $1.member.cx { return $0.member.cx < $1.member.cx }
        if $0.member.cz != $1.member.cz { return $0.member.cz < $1.member.cz }
        return $0.member.pass < $1.member.pass
    }
    let orderedEligible = eligible.map(\.member)
    let estimatedRetainedBytes = raw.count * 40 + orderedEligible.count * 24
    precondition(estimatedRetainedBytes <= dungeonRegionMaximumRetainedBytesPerPlan)
    return DungeonRegionPlan(rawAcceptedCount: rawCandidateCount,
                             underwater: Set(orderedEligible.prefix(budget)))
}

private func dungeonRegionPlan(seed: UInt32, cx: Int, cz: Int, passes: Int,
                               settingsIdentity: String) -> DungeonRegionPlan {
    let key = DungeonRegionKey(seed: seed, settingsIdentity: settingsIdentity,
                               rx: floorDiv(cx, dungeonRegionSide),
                               rz: floorDiv(cz, dungeonRegionSide), passes: passes)
    dungeonRegionCondition.lock()
    while true {
        if let cached = dungeonRegionPlans[key] {
            dungeonRegionCondition.unlock()
            return cached
        }
        if !dungeonRegionInFlight.contains(key) {
            dungeonRegionInFlight.insert(key)
            dungeonRegionCondition.unlock()
            break
        }
        dungeonRegionCondition.wait()
    }
    let built = buildDungeonRegionPlan(key)
    dungeonRegionCondition.lock()
    if dungeonRegionPlans.count >= dungeonRegionCacheLimit { dungeonRegionPlans.removeAll(keepingCapacity: true) }
    let installed = dungeonRegionPlans[key] ?? built
    dungeonRegionPlans[key] = installed
    dungeonRegionInFlight.remove(key)
    dungeonRegionCondition.broadcast()
    dungeonRegionCondition.unlock()
    return installed
}

func dungeonUnderwaterBudgetSelected(seed: UInt32, cx: Int, cz: Int, pass: Int,
                                     settings: WorldGenerationSettings = .normal) -> Bool {
    let passes = settings.dungeonDensity.dungeonPasses
    guard pass >= 0, pass < passes else { return false }
    let plan = dungeonRegionPlan(seed: seed, cx: cx, cz: cz, passes: passes,
                                 settingsIdentity: settings.cacheIdentity)
    return plan.underwater.contains(DungeonBudgetMember(cx: cx, cz: cz, pass: pass))
}

struct DungeonRegionBudgetSummary: Equatable {
    public let rawAcceptedCount: Int
    public let underwaterSelectedCount: Int
}

struct DungeonRegionPlannerLimits: Equatable {
    public let side: Int
    public let cacheEntries: Int
    public let maximumPasses: Int
    public let maximumRawCandidates: Int
    public let maximumStoredMembers: Int
    public let maximumRetainedBytesPerPlan: Int
}

let dungeonRegionPlannerLimits = DungeonRegionPlannerLimits(
    side: dungeonRegionSide,
    cacheEntries: dungeonRegionCacheLimit,
    maximumPasses: dungeonRegionMaximumPasses,
    maximumRawCandidates: dungeonRegionMaximumRawCandidates,
    maximumStoredMembers: dungeonRegionMaximumStoredMembers,
    maximumRetainedBytesPerPlan: dungeonRegionMaximumRetainedBytesPerPlan)

func dungeonRegionBudgetSummary(seed: UInt32, regionX: Int, regionZ: Int,
                                settings: WorldGenerationSettings = .normal) -> DungeonRegionBudgetSummary {
    let passes = settings.dungeonDensity.dungeonPasses
    let plan = dungeonRegionPlan(seed: seed, cx: regionX * dungeonRegionSide,
                                 cz: regionZ * dungeonRegionSide,
                                 passes: passes, settingsIdentity: settings.cacheIdentity)
    return DungeonRegionBudgetSummary(rawAcceptedCount: plan.rawAcceptedCount,
                                      underwaterSelectedCount: plan.underwater.count)
}

private final class DetachedDungeonSink: ChunkSink {
    let cx: Int, cz: Int, minY: Int, maxY: Int
    private let base: ChunkSink
    private struct Key: Hashable { let x: Int; let y: Int; let z: Int }
    private var orderedWrites: [(Key, UInt16)] = []
    private var latest: [Key: UInt16] = [:]
    private(set) var blockEntities: [BESpec] = []

    init(_ base: ChunkSink) {
        self.base = base
        cx = base.cx; cz = base.cz; minY = base.minY; maxY = base.maxY
    }
    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        guard floorDiv(x, 16) == cx, floorDiv(z, 16) == cz, y >= minY, y < maxY else { return }
        let key = Key(x: x, y: y, z: z)
        orderedWrites.append((key, c)); latest[key] = c
    }
    func get(_ x: Int, _ y: Int, _ z: Int) -> Int {
        latest[Key(x: x, y: y, z: z)].map(Int.init) ?? base.get(x, y, z)
    }
    func topY(_ x: Int, _ z: Int) -> Int { base.topY(x, z) }
    func addBlockEntity(_ spec: BESpec) { blockEntities.append(spec) }
    func addEntity(_ spec: EntitySpec) {}
    func commit() {
        for (key, value) in orderedWrites { base.set(key.x, key.y, key.z, value) }
        for spec in blockEntities { base.addBlockEntity(spec) }
    }
}

private func isFluidCell(_ value: Int) -> Bool {
    guard value >= 0 else { return false }
    let id = value >> 4
    return id == Int(B.water) || id == Int(B.lava)
}

@discardableResult
private func tryDungeonPass(_ seed: UInt32, _ ocx: Int, _ ocz: Int, _ sink: ChunkSink,
                            pass: Int, settings: WorldGenerationSettings,
                            oracle: BaseTerrainOracle?) -> Int {
    let salt = pass == 0 ? UInt32(0xD0D6E0) : dungeonPassSalt(pass)
    let rng = Rng(hash2(seed, ocx, ocz, salt))
    let underwaterBudgeted = dungeonUnderwaterBudgetSelected(seed: seed, cx: ocx, cz: ocz,
                                                              pass: pass, settings: settings)
    for _ in 0..<4 {
        if rng.nextFloat() > 0.12 { continue }
        let rawX = ocx * 16 + 3 + rng.nextInt(10)
        let rawZ = ocz * 16 + 3 + rng.nextInt(10)
        let y = -40 + rng.nextInt(90)
        let hw = 3 + rng.nextInt(2)
        let minLocal = hw + 1, maxLocal = 15 - hw - 1
        let x = ocx * 16 + min(max(rawX - ocx * 16, minLocal), maxLocal)
        let z = ocz * 16 + min(max(rawZ - ocz * 16, minLocal), maxLocal)
        let read: (Int, Int, Int) -> Int = { x, y, z in
            oracle?.cell(x, y, z) ?? sink.get(x, y, z)
        }
        let genuinelySubmerged = isFluidCell(read(rawX, y, rawZ))
        let underwater = underwaterBudgeted && genuinelySubmerged
        var entrance: (dx: Int, dz: Int)?
        if !underwater {
            var fluidFound = false
            for py in (y - 1)...(y + 3) {
                for pz in (z - hw - 1)...(z + hw + 1) {
                    for px in (x - hw - 1)...(x + hw + 1) where isFluidCell(read(px, py, pz)) {
                        fluidFound = true
                    }
                }
            }
            if fluidFound { continue }
            for direction in [(dx: -1, dz: 0), (dx: 1, dz: 0), (dx: 0, dz: -1), (dx: 0, dz: 1)] {
                let ex = x + direction.dx * (hw + 1), ez = z + direction.dz * (hw + 1)
                if read(ex, y, ez) == 0, read(ex, y + 1, ez) == 0 {
                    entrance = direction
                    break
                }
            }
            if entrance == nil { continue }
        }

        let detached = DetachedDungeonSink(sink)
        let b = Builder(detached, rng)
        let mossy: [(Int, Double)] = [(Int(cell(B.cobblestone)), 5), (Int(cell(B.mossy_cobblestone)), 5)]
        b.fillRandom(x - hw, y - 1, z - hw, x + hw, y - 1, z + hw, mossy)
        for dy in 0...3 {
            for dz in -hw...hw {
                for dx in -hw...hw {
                    let shell = abs(dx) == hw || abs(dz) == hw || dy == 3
                    b.set(x + dx, y + dy, z + dz,
                          shell ? (b.rng.nextFloat() < 0.5 ? Int(cell(B.cobblestone)) : Int(cell(B.mossy_cobblestone))) : AIR)
                }
            }
        }
        if let entrance {
            for distance in hw...(hw + 1) {
                let ex = x + entrance.dx * distance, ez = z + entrance.dz * distance
                b.set(ex, y, ez, AIR); b.set(ex, y + 1, ez, AIR)
            }
        }
        let mobRoll = rng.nextFloat()
        b.spawner(x, y, z, mobRoll < 0.5 ? "zombie" : mobRoll < 0.75 ? "skeleton" : "spider")
        b.chest(x + hw - 1, y, z + hw - 1, 0, "dungeon")
        if rng.nextBoolean() { b.chest(x - hw + 1, y, z - hw + 1, 0, "dungeon") }
        guard detached.blockEntities.allSatisfy({ spec in
            let id = detached.get(spec.x, spec.y, spec.z) >> 4
            return (spec.kind == "spawner" && id == Int(B.spawner))
                || (spec.kind == "chest_loot" && id == Int(B.chest))
        }) else { continue }
        detached.commit()
        return 1 // max one per chunk per pass
    }
    return 0
}

private func dungeonPassSalt(_ pass: Int) -> UInt32 {
    0xD0D6E0 &+ UInt32(truncatingIfNeeded: pass) &* 0x9E3779B9
}

@discardableResult
public func tryDungeons(_ seed: UInt32, _ ocx: Int, _ ocz: Int, _ sink: ChunkSink,
                        density: DungeonDensity = .normal,
                        settings: WorldGenerationSettings? = nil,
                        terrainOracle: BaseTerrainOracle? = nil) -> Int {
    let passes = density.dungeonPasses
    guard passes > 0 else { return 0 }
    var effectiveSettings = settings ?? WorldGenerationSettings(dungeonDensity: density)
    effectiveSettings.dungeonDensity = density
    var placed = 0
    for pass in 0..<passes {
        placed += tryDungeonPass(seed, ocx, ocz, sink, pass: pass,
                                 settings: effectiveSettings, oracle: terrainOracle)
    }
    return placed
}

// =============================================================================
// registration
// =============================================================================
func registerOverworldStructures() {
    registerStructure(StructureDef(
        id: "village", spacing: 34, separation: 8, salt: 10387312, maxRadiusChunks: 5,
        check: { ctx, ocx, ocz, _ in
            styleFor(ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8)) != nil
        },
        plan: { ctx, ocx, ocz, rng in
            guard let (centerX, centerZ) = chooseVillageCenter(ctx, ocx * 16 + 8, ocz * 16 + 8) else {
                return nil
            }
            let biomeId = ctx.biomeAt(centerX, centerZ)
            guard let st = styleFor(biomeId) else { return nil }
            let siteHeight: (Int, Int) -> Int = { x, z in
                dryVillageSurface(ctx, x, z) ?? ctx.heightAt(x, z)
            }
            var pieces: [StructPiece] = []
            var acceptedBuildingFootprints: [VillageXZFootprint] = []
            var acceptedConnectorCorridors: [VillageXZFootprint] = []
            acceptedBuildingFootprints.reserveCapacity(16)
            acceptedConnectorCorridors.reserveCapacity(16)
            let cy = siteHeight(centerX, centerZ)

            // well at center
            pieces.append(piece(centerX - 2, cy - 12, centerZ - 2, centerX + 5, cy + 4, centerZ + 5) { b in
                well(b, centerX, cy, centerZ, st)
            })
            // bell next to well
            pieces.append(piece(centerX - 4, cy, centerZ, centerX - 4, cy + 2, centerZ) { b in
                b.foundation(centerX - 4, cy - 1, centerZ, st.wall)
                b.set(centerX - 4, cy, centerZ, st.wall)
                b.set(centerX - 4, cy + 1, centerZ, Int(cell(B.bell, 0)))
            })
            // iron golem + extras at center
            let golemY = siteHeight(centerX, centerZ - 3)
            let catY = siteHeight(centerX + 2, centerZ - 3)
            let camelY = biomeId == Biome.desert.rawValue
                ? siteHeight(centerX - 3, centerZ - 4)
                : nil
            let residentMinX = camelY == nil ? centerX : centerX - 3
            let residentMinZ = camelY == nil ? centerZ - 3 : centerZ - 4
            let residentMinY = min(golemY, catY, camelY ?? golemY)
            let residentMaxY = max(golemY, catY, camelY ?? golemY)
            pieces.append(piece(residentMinX, residentMinY, residentMinZ,
                                centerX + 2, residentMaxY + 2, centerZ - 3) { b in
                b.mob("iron_golem", centerX, golemY, centerZ - 3)
                b.mob("cat", centerX + 2, catY, centerZ - 3)
                if let camelY { b.mob("camel", centerX - 3, camelY, centerZ - 4) }
            })

            // roads in 4 directions with buildings
            let jobs: [(Int, String?)] = [
                (Int(cell(B.smithing_table)), "village_weaponsmith"),
                (Int(cell(B.lectern, 0)), nil),
                (Int(cell(B.blast_furnace, 0)), "village_toolsmith"),
                (Int(cell(B.brewing_stand)), "village_temple"),
                (Int(cell(B.loom)), nil),
                (Int(cell(B.cauldron)), nil),
                (Int(cell(B.stonecutter, 0)), nil),
                (Int(cell(B.barrel, 1)), nil),
                (Int(cell(B.grindstone, 0)), nil),
                (Int(cell(B.fletching_table)), nil),
                (Int(cell(B.cartography_table)), nil),
            ]
            var jobIdx = rng.nextInt(jobs.count)
            let arms = 3 + rng.nextInt(2)
            let dirOrder = rng.shuffle([0, 1, 2, 3])
            for a in 0..<arms {
                let dir = dirOrder[a]
                let dx = [0, 0, -1, 1][dir], dz = [-1, 1, 0, 0][dir]
                let len = 14 + rng.nextInt(16)
                // road piece
                let rx0 = min(centerX + dx * 4, centerX + dx * (4 + len)) - 1
                let rx1 = max(centerX + dx * 4, centerX + dx * (4 + len)) + 1
                let rz0 = min(centerZ + dz * 4, centerZ + dz * (4 + len)) - 1
                let rz1 = max(centerZ + dz * 4, centerZ + dz * (4 + len)) + 1
                pieces.append(piece(rx0, cy - 6, rz0, rx1, cy + 30, rz1) { b in
                    for i in 4...(4 + len) {
                        let px = centerX + dx * i, pz = centerZ + dz * i
                        _ = siteHeight(px, pz)
                        for w in -1...1 {
                            let wx = px + (dz != 0 ? w : 0), wz = pz + (dx != 0 ? w : 0)
                            let wy = siteHeight(wx, wz)
                            b.foundation(wx, wy - 1, wz, st.path, 4)
                            b.set(wx, wy, wz, AIR)
                            b.set(wx, wy + 1, wz, AIR)
                        }
                        // lamp posts
                        if i % 7 == 0 {
                            let lx = px + (dz != 0 ? 2 : 0), lz = pz + (dx != 0 ? 2 : 0)
                            let ly = siteHeight(lx, lz)
                            b.set(lx, ly, lz, st.fence)
                            b.set(lx, ly + 1, lz, st.fence)
                            b.set(lx, ly + 2, lz, Int(cell(B.torch)))
                        }
                    }
                })
                // buildings along the arm
                let bcount = 2 + rng.nextInt(3)
                for _ in 0..<bcount {
                    let along = 7 + rng.nextInt(max(1, len - 6))
                    let side = rng.nextBoolean() ? 1 : -1
                    let off = 3 + rng.nextInt(2)
                    let kind = rng.nextFloat()
                    let pieceReach = kind < 0.4 ? 6 : kind < 0.62 ? 10 : 7
                    let lateralOffset = side > 0 ? off : -(off + pieceReach)
                    let bx = centerX + dx * along + (dz != 0 ? lateralOffset : 0)
                    let bz = centerZ + dz * along + (dx != 0 ? lateralOffset : 0)
                    let by = siteHeight(bx + 3, bz + 3)
                    let buildingFootprint: VillageXZFootprint
                    if kind < 0.4 {
                        buildingFootprint = VillageXZFootprint(bx - 1, bz - 1, bx + 6, bz + 6)
                    } else if kind < 0.62 {
                        buildingFootprint = VillageXZFootprint(bx - 1, bz - 1, bx + 10, bz + 8)
                    } else {
                        buildingFootprint = VillageXZFootprint(bx - 1, bz - 1, bx + 7, bz + 7)
                    }
                    let connectorFootprint: VillageXZFootprint?
                    let doorX = bx + 2, doorZ = bz
                    let roadX = dz != 0 ? centerX : doorX
                    let roadZ = dx != 0 ? centerZ : doorZ
                    if kind < 0.4 || kind >= 0.62 {
                        connectorFootprint = VillageXZFootprint(doorX, doorZ, roadX, roadZ)
                    } else {
                        connectorFootprint = nil
                    }
                    let selectedJob: (block: Int, loot: String?)?
                    if kind >= 0.62 {
                        let job = jobs[jobIdx % jobs.count]
                        jobIdx += 1
                        selectedJob = (job.0, job.1)
                    } else {
                        selectedJob = nil
                    }
                    let buildingConflicts = acceptedConnectorCorridors.contains {
                        buildingFootprint.intersects($0)
                    }
                    let connectorConflicts = connectorFootprint.map { connector in
                        acceptedBuildingFootprints.contains { connector.intersects($0) }
                    } ?? false
                    guard !buildingConflicts && !connectorConflicts else {
                        let placeholder = piece(centerX, cy, centerZ,
                                                centerX, cy, centerZ) { _ in }
                        pieces.append(placeholder)
                        if connectorFootprint != nil { pieces.append(placeholder) }
                        continue
                    }
                    precondition(acceptedBuildingFootprints.count < 16)
                    acceptedBuildingFootprints.append(buildingFootprint)
                    if let connectorFootprint {
                        precondition(acceptedConnectorCorridors.count < 16)
                        acceptedConnectorCorridors.append(connectorFootprint)
                    }
                    if kind < 0.4 {
                        pieces.append(piece(bx - 1, by - 8, bz - 1, bx + 6, by + 6, bz + 6) { b in
                            houseSmall(b, bx, by, bz, st, 0, b.s)
                        })
                    } else if kind < 0.62 {
                        pieces.append(piece(bx - 1, by - 8, bz - 1, bx + 10, by + 3, bz + 8) { b in
                            farm(b, bx, by, bz, st, b.rng)
                        })
                    } else {
                        guard let selectedJob else { preconditionFailure("job offer must be resolved") }
                        pieces.append(piece(bx - 1, by - 8, bz - 1, bx + 7, by + 6, bz + 7) { b in
                            houseJob(b, bx, by, bz, st, selectedJob.block, selectedJob.loot, b.s)
                        })
                    }
                    if connectorFootprint != nil {
                        let x0 = min(doorX, roadX), x1 = max(doorX, roadX)
                        let z0 = min(doorZ, roadZ), z1 = max(doorZ, roadZ)
                        pieces.append(piece(x0, by - 4, z0, x1, by + 2, z1) { b in
                            if x0 == x1 {
                                for pz in z0...z1 {
                                    let py = siteHeight(x0, pz)
                                    b.foundation(x0, py - 1, pz, st.path, 4)
                                    b.set(x0, py, pz, AIR)
                                    b.set(x0, py + 1, pz, AIR)
                                }
                            } else {
                                for px in x0...x1 {
                                    let py = siteHeight(px, z0)
                                    b.foundation(px, py - 1, z0, st.path, 4)
                                    b.set(px, py, z0, AIR)
                                    b.set(px, py + 1, z0, AIR)
                                }
                            }
                        })
                    }
                }
            }
            guard validateVillagePieces(ctx, pieces) else { return nil }
            return StructurePlan(id: "village", pieces: pieces,
                                 ref: StructRefBox(centerX - 80, cy - 20, centerZ - 80, centerX + 80, cy + 40, centerZ + 80))
        }
    ))

    registerStructure(StructureDef(
        id: "desert_temple", spacing: 32, separation: 9, salt: 14357617, maxRadiusChunks: 2,
        check: { ctx, ocx, ocz, _ in
            ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8) == Biome.desert.rawValue
        },
        plan: { ctx, ocx, ocz, _ in
            let x = ocx * 16, z = ocz * 16
            let y = ctx.heightAt(x + 10, z + 10)
            let SS = Int(cell(B.sandstone)), CUT = Int(cell(B.cut_sandstone)), CHIS = Int(cell(B.chiseled_sandstone))
            let OR = Int(cell(B.orange_terracotta)), BL = Int(cell(B.blue_terracotta))
            return StructurePlan(id: "desert_temple", pieces: [
                piece(x - 1, y - 16, z - 1, x + 21, y + 22, z + 21) { b in
                    for dz in 0..<21 { for dx in 0..<21 { b.foundation(x + dx, y - 1, z + dz, SS, 10) } }
                    for layer in 0..<10 {
                        let i = layer
                        b.fill(x + i, y + layer, z + i, x + 20 - i, y + layer, z + 20 - i, SS)
                    }
                    b.fill(x + 1, y, z + 1, x + 19, y + 3, z + 19, AIR)
                    for dz in 1..<20 { for dx in 1..<20 { b.set(x + dx, y - 1, z + dz, SS) } }
                    let cx2 = x + 10, cz2 = z + 10
                    b.fill(cx2 - 1, y - 1, cz2 - 1, cx2 + 1, y - 1, cz2 + 1, OR)
                    b.set(cx2, y - 1, cz2, BL)
                    // treasure pit — clears/floors FIRST, trap LAST (the plate
                    // used to be wiped by the later fills: dead trap, sealed TNT)
                    b.fill(cx2 - 2, y - 14, cz2 - 2, cx2 + 2, y - 2, cz2 + 2, AIR)
                    b.fill(cx2 - 3, y - 15, cz2 - 3, cx2 + 3, y - 15, cz2 + 3, SS)
                    b.fill(cx2 - 3, y - 14, cz2 - 3, cx2 + 3, y - 10, cz2 + 3, AIR)
                    b.fill(cx2 - 3, y - 14, cz2 - 3, cx2 + 3, y - 14, cz2 + 3, SS)
                    b.set(cx2 - 3, y - 14, cz2 - 3, AIR); b.set(cx2 + 3, y - 14, cz2 + 3, AIR)
                    b.fill(cx2 - 1, y - 16, cz2 - 1, cx2 + 1, y - 16, cz2 + 1, Int(cell(B.tnt)))
                    b.set(cx2, y - 13, cz2, AIR)
                    b.set(cx2, y - 14, cz2, Int(cell(B.stone_pressure_plate)))
                    b.chest(cx2 - 2, y - 13, cz2, 5, "desert_temple")
                    b.chest(cx2 + 2, y - 13, cz2, 4, "desert_temple")
                    b.chest(cx2, y - 13, cz2 - 2, 1, "desert_temple")
                    b.chest(cx2, y - 13, cz2 + 2, 0, "desert_temple")
                    // towers
                    for (tx, tz) in [(x + 2, z + 2), (x + 16, z + 2)] {
                        b.fill(tx, y, tz, tx + 2, y + 9, tz + 2, SS)
                        b.fill(tx, y + 10, tz, tx + 2, y + 10, tz + 2, CUT)
                        b.set(tx + 1, y + 6, tz + 1, CHIS)
                    }
                    // entrance
                    b.fill(x + 9, y, z, x + 11, y + 2, z + 1, AIR)
                    b.set(x + 9, y + 2, z, CUT); b.set(x + 11, y + 2, z, CUT)
                    // orange decoration band
                    var d = 0
                    while d < 21 {
                        b.set(x + d, y + 4, z, OR)
                        b.set(x + d, y + 4, z + 20, OR)
                        d += 2
                    }
                    // archaeology
                    b.suspicious(cx2 - 2, y - 14, cz2 - 2, false, "desert_pyramid_archaeology")
                    b.suspicious(cx2 + 2, y - 14, cz2 + 2, false, "desert_pyramid_archaeology")
                    b.suspicious(cx2 + 2, y - 14, cz2 - 2, false, "desert_pyramid_archaeology")
                    b.suspicious(cx2 - 2, y - 14, cz2 + 2, false, "desert_pyramid_archaeology")
                },
            ])
        }
    ))

    registerStructure(StructureDef(
        id: "jungle_temple", spacing: 32, separation: 9, salt: 14357619, maxRadiusChunks: 2,
        check: { ctx, ocx, ocz, _ in
            let bm = ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8)
            return bm == Biome.jungle.rawValue || bm == Biome.bambooJungle.rawValue
        },
        plan: { ctx, ocx, ocz, _ in
            let x = ocx * 16 + 2, z = ocz * 16 + 2
            let y = ctx.heightAt(x + 6, z + 7)
            let C = Int(cell(B.cobblestone)), M = Int(cell(B.mossy_cobblestone))
            let mossy: [(Int, Double)] = [(C, 6), (M, 4)]
            return StructurePlan(id: "jungle_temple", pieces: [
                piece(x - 1, y - 6, z - 1, x + 12, y + 14, z + 15) { b in
                    for dz in 0..<15 { for dx in 0..<12 { b.foundation(x + dx, y - 1, z + dz, C, 6) } }
                    b.fillRandom(x, y, z, x + 11, y, z + 14, mossy)
                    b.fillRandom(x, y + 1, z, x + 11, y + 4, z + 14, mossy)
                    b.fill(x + 1, y + 1, z + 1, x + 10, y + 3, z + 13, AIR)
                    b.fillRandom(x + 1, y + 4, z + 1, x + 10, y + 4, z + 13, mossy)
                    b.fillRandom(x + 2, y + 5, z + 2, x + 9, y + 8, z + 12, mossy)
                    b.fill(x + 3, y + 5, z + 3, x + 8, y + 7, z + 11, AIR)
                    b.fillRandom(x + 3, y + 9, z + 3, x + 8, y + 10, z + 11, mossy)
                    // entrance (north)
                    b.fill(x + 5, y + 5, z, x + 6, y + 7, z + 3, AIR)
                    b.fill(x + 5, y + 1, z + 1, x + 6, y + 4, z + 1, AIR)
                    // stairs down inside
                    for i in 0..<4 {
                        b.set(x + 5, y + 4 - i, z + 4 + i, Int(cell(B.cobblestone_stairs, 1)))
                        b.set(x + 6, y + 4 - i, z + 4 + i, Int(cell(B.cobblestone_stairs, 1)))
                        b.fill(x + 5, y + 5 - i, z + 4 + i, x + 6, y + 7 - i, z + 4 + i, AIR)
                    }
                    // tripwire trap corridor
                    b.set(x + 1, y + 1, z + 8, Int(cell(B.tripwire_hook, 3)))
                    b.set(x + 10, y + 1, z + 8, Int(cell(B.tripwire_hook, 2)))
                    for dx in 2...9 { b.set(x + dx, y + 1, z + 8, Int(cell(B.tripwire))) }
                    b.set(x + 1, y + 1, z + 9, Int(cell(B.dispenser, 3)))
                    b.s.addBlockEntity(BESpec(x: x + 1, y: y + 1, z: z + 9, kind: "dispenser_arrows"))
                    // puzzle levers + hidden chest room
                    b.set(x + 2, y + 2, z + 12, Int(cell(B.lever, 4)))
                    b.set(x + 9, y + 2, z + 12, Int(cell(B.lever, 5)))
                    b.chest(x + 2, y + 1, z + 13, 0, "jungle_temple")
                    b.chest(x + 9, y + 5, z + 2, 1, "jungle_temple")
                    // vines on walls
                    for _ in 0..<30 {
                        let vx = x + b.rng.nextInt(12), vy = y + 1 + b.rng.nextInt(9), vz = z + b.rng.nextInt(15)
                        if b.get(vx, vy, vz) == 0 {
                            for f in 0..<4 {
                                let wx = vx + [0, 0, -1, 1][f], wz = vz + [-1, 1, 0, 0][f]
                                let w = b.get(wx, vy, wz)
                                if w > 0 && (w == C || w == M) {
                                    b.set(vx, vy, vz, Int(cell(B.vine, 1 << f)))
                                    break
                                }
                            }
                        }
                    }
                },
            ])
        }
    ))

    registerStructure(StructureDef(
        id: "igloo", spacing: 32, separation: 8, salt: 14357618, maxRadiusChunks: 1,
        check: { ctx, ocx, ocz, _ in
            let bm = ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8)
            return bm == Biome.snowyPlains.rawValue || bm == Biome.snowyTaiga.rawValue
        },
        plan: { ctx, ocx, ocz, rng in
            let x = ocx * 16 + 4, z = ocz * 16 + 4
            let y = ctx.heightAt(x + 3, z + 3)
            let SNOW = Int(cell(B.snow_block))
            let hasBasement = rng.nextFloat() < 0.5
            return StructurePlan(id: "igloo", pieces: [
                piece(x - 1, y - 24, z - 1, x + 8, y + 5, z + 10) { b in
                    // dome 7×7
                    for dz in 0..<7 { for dx in 0..<7 {
                        b.foundation(x + dx, y - 1, z + dz, SNOW, 4)
                        let d2 = (dx - 3) * (dx - 3) + (dz - 3) * (dz - 3)
                        if d2 <= 10 { b.set(x + dx, y + 3, z + dz, d2 <= 4 ? SNOW : AIR) }
                        if d2 <= 4 { b.set(x + dx, y + 4, z + dz, d2 <= 1 ? SNOW : AIR) }
                        if d2 > 4 && d2 <= 10 { b.set(x + dx, y + 1, z + dz, SNOW); b.set(x + dx, y + 2, z + dz, SNOW) }
                        if d2 <= 4 { b.set(x + dx, y + 1, z + dz, AIR); b.set(x + dx, y + 2, z + dz, AIR) }
                        if d2 <= 10 { b.set(x + dx, y, z + dz, SNOW) }
                    } }
                    b.fill(x + 2, y + 3, z + 2, x + 4, y + 3, z + 4, SNOW)
                    b.set(x + 3, y + 3, z + 3, Int(cell(B.snow_block)))
                    // entrance tunnel south
                    b.fill(x + 3, y + 1, z + 6, x + 3, y + 2, z + 9, AIR)
                    b.fill(x + 2, y + 1, z + 6, x + 2, y + 3, z + 9, SNOW)
                    b.fill(x + 4, y + 1, z + 6, x + 4, y + 3, z + 9, SNOW)
                    b.fill(x + 2, y + 3, z + 6, x + 4, y + 3, z + 9, SNOW)
                    // furnishings
                    b.set(x + 1, y + 1, z + 3, Int(cell(B.red_bed, 2 | 4)))
                    b.set(x + 1, y + 1, z + 2, Int(cell(B.red_bed, 2)))
                    b.set(x + 5, y + 1, z + 2, Int(cell(B.furnace, 2)))
                    b.set(x + 5, y + 1, z + 4, Int(cell(B.crafting_table)))
                    b.set(x + 3, y + 2, z + 1, Int(cell(B.torch, 3)))
                    if hasBasement {
                        b.set(x + 3, y + 1, z + 4, Int(cell(B.white_carpet)))
                        // trapdoor under the carpet — the shaft used to be sealed
                        // by solid snow with nothing hinting at the basement
                        b.set(x + 3, y, z + 4, Int(cell(B.oak_trapdoor, 0)))
                        let by = y - 20
                        b.walls(x - 1, by - 1, z - 1, x + 7, by + 3, z + 5, Int(cell(B.stone_bricks)), AIR)
                        // ladder shaft — carved AFTER the basement box: walls()
                        // writes its top plane solid and AIRs the interior,
                        // which would plug the shaft and delete the rungs
                        for d in 1...20 {
                            b.set(x + 3, y - d, z + 4, Int(cell(B.ladder, 0)))
                            b.set(x + 3, y - d, z + 5, Int(cell(B.stone)))
                        }
                        b.set(x + 1, by, z + 1, Int(cell(B.brewing_stand)))
                        b.set(x + 1, by, z + 2, Int(cell(B.cauldron, 3)))
                        b.chest(x + 6, by, z + 1, 2, "igloo")
                        // prisoner cells
                        b.set(x + 5, by, z + 4, Int(cell(B.iron_bars)))
                        b.set(x + 6, by, z + 4, Int(cell(B.iron_bars)))
                        b.mob("villager", x + 5, by, z + 3)
                        b.mob("zombie_villager", x + 6, by, z + 3)
                        b.set(x + 2, by + 2, z + 2, Int(cell(B.torch)))
                    }
                },
            ])
        }
    ))

    registerStructure(StructureDef(
        id: "witch_hut", spacing: 32, separation: 8, salt: 14357620, maxRadiusChunks: 1,
        check: { ctx, ocx, ocz, _ in
            ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8) == Biome.swamp.rawValue
        },
        plan: { ctx, ocx, ocz, _ in
            let x = ocx * 16 + 5, z = ocz * 16 + 5
            let y = max(64, ctx.heightAt(x + 3, z + 4) + 1)
            let P = Int(cell(B.spruce_planks)), L = Int(cell(B.oak_log))
            return StructurePlan(id: "witch_hut", pieces: [
                piece(x - 1, y - 8, z - 1, x + 8, y + 7, z + 10) { b in
                    // stilts
                    for (sx, sz) in [(1, 1), (5, 1), (1, 7), (5, 7)] {
                        for d in 0..<8 {
                            let yy = y - d
                            let cur = b.get(x + sx, yy, z + sz)
                            if cur > 0 && UInt16(cur >> 4) != B.water { break }
                            b.set(x + sx, yy, z + sz, L)
                        }
                    }
                    // platform + room
                    b.fill(x, y + 1, z, x + 6, y + 1, z + 8, P)
                    b.walls(x, y + 2, z + 1, x + 6, y + 5, z + 8, P, AIR)
                    b.fill(x + 1, y + 5, z + 2, x + 5, y + 5, z + 7, P)
                    // door gap + windows
                    b.set(x + 3, y + 2, z + 1, AIR); b.set(x + 3, y + 3, z + 1, AIR)
                    b.set(x + 1, y + 3, z + 4, AIR); b.set(x + 5, y + 3, z + 4, AIR)
                    // furnishings
                    b.set(x + 5, y + 2, z + 7, Int(cell(B.cauldron, 2 | 0)))
                    b.set(x + 1, y + 2, z + 7, Int(cell(B.crafting_table)))
                    b.set(x + 1, y + 2, z + 2, Int(cell(B.flower_pot)))
                    b.s.addBlockEntity(BESpec(x: x + 1, y: y + 2, z: z + 2, kind: "pot_plant", data: ["plant": .str("red_mushroom")]))
                    b.mob("witch", x + 3, y + 2, z + 4, ["persistent": .bool(true)])
                    b.mob("cat", x + 2, y + 2, z + 5, ["variant": .str("black"), "persistent": .bool(true)])
                },
            ], ref: StructRefBox(x - 8, y - 8, z - 8, x + 14, y + 12, z + 16))
        }
    ))

    registerStructure(StructureDef(
        id: "pillager_outpost", spacing: 32, separation: 9, salt: 165745296, maxRadiusChunks: 2,
        check: { ctx, ocx, ocz, rng in
            let bm = ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8)
            let ok = bm == Biome.plains.rawValue || bm == Biome.desert.rawValue || bm == Biome.savanna.rawValue ||
                bm == Biome.taiga.rawValue || bm == Biome.snowyPlains.rawValue || bm == Biome.meadow.rawValue
            return ok && rng.nextFloat() < 0.5
        },
        plan: { ctx, ocx, ocz, _ in
            let x = ocx * 16 + 4, z = ocz * 16 + 4
            let y = ctx.heightAt(x + 4, z + 4)
            let P = Int(cell(B.dark_oak_planks)), L = Int(cell(B.dark_oak_log)), C = Int(cell(B.cobblestone))
            return StructurePlan(id: "pillager_outpost", pieces: [
                piece(x - 6, y - 6, z - 6, x + 14, y + 22, z + 14) { b in
                    for dz in 0..<8 { for dx in 0..<8 { b.foundation(x + dx, y - 1, z + dz, C, 6) } }
                    b.walls(x, y, z, x + 7, y + 3, z + 7, C, AIR)
                    b.walls(x + 1, y + 4, z + 1, x + 6, y + 9, z + 6, P, AIR)
                    b.walls(x, y + 10, z, x + 7, y + 14, z + 7, P, AIR)
                    for (cx2, cz2) in [(0, 0), (7, 0), (0, 7), (7, 7)] {
                        for h in 0..<15 { b.set(x + cx2, y + h, z + cz2, L) }
                    }
                    // door
                    b.set(x + 3, y, z, AIR); b.set(x + 4, y, z, AIR)
                    b.set(x + 3, y + 1, z, AIR); b.set(x + 4, y + 1, z, AIR)
                    // floors + ladders
                    b.fill(x + 1, y + 4, z + 1, x + 6, y + 4, z + 6, P)
                    b.fill(x + 1, y + 10, z + 1, x + 6, y + 10, z + 6, P)
                    b.set(x + 1, y + 4, z + 1, AIR); b.set(x + 1, y + 10, z + 1, AIR)
                    for h in 0..<14 { b.set(x + 1, y + h, z + 2, Int(cell(B.ladder, 5))) }
                    // crenellations + windows
                    var d = 0
                    while d < 8 {
                        b.set(x + d, y + 15, z, P); b.set(x + d, y + 15, z + 7, P)
                        b.set(x, y + 15, z + d, P); b.set(x + 7, y + 15, z + d, P)
                        d += 2
                    }
                    for wy in [6, 12] {
                        b.set(x + 3, y + wy, z, AIR); b.set(x + 4, y + wy, z + 7, AIR)
                        b.set(x, y + wy, z + 3, AIR); b.set(x + 7, y + wy, z + 4, AIR)
                    }
                    b.chest(x + 5, y + 11, z + 5, 2, "pillager_outpost")
                    // mobs: captain on top + patrols
                    b.mob("pillager", x + 4, y + 11, z + 4, ["captain": .bool(true), "persistent": .bool(true)])
                    b.mob("pillager", x + 2, y, z + 3, ["persistent": .bool(true)])
                    b.mob("pillager", x + 9, y, z + 8, ["persistent": .bool(true)])
                    b.mob("pillager", x - 2, y, z + 2, ["persistent": .bool(true)])
                    // golem cage (50%)
                    if b.rng.nextBoolean() {
                        let gx = x + 11, gz = z + 2
                        let gy = ctx.heightAt(gx + 1, gz + 1)
                        b.walls(gx, gy, gz, gx + 3, gy + 3, gz + 3, Int(cell(B.dark_oak_fence)), AIR)
                        b.fill(gx, gy + 3, gz, gx + 3, gy + 3, gz + 3, P)
                        b.mob("iron_golem", gx + 1, gy, gz + 1)
                    }
                    // tent
                    let tx = x - 5, tz = z + 8
                    let ty = ctx.heightAt(tx + 1, tz + 1)
                    b.fill(tx, ty, tz, tx + 2, ty, tz + 2, Int(cell(B.white_wool)))
                    b.fill(tx, ty + 1, tz + 1, tx + 2, ty + 1, tz + 1, Int(cell(B.white_wool)))
                },
            ], ref: StructRefBox(x - 16, y - 8, z - 16, x + 24, y + 24, z + 24))
        }
    ))

    registerStructure(StructureDef(
        id: "shipwreck", spacing: 24, separation: 4, salt: 165745295, maxRadiusChunks: 2,
        check: { ctx, ocx, ocz, rng in
            let bm = ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8)
            return (isOceanBiome(bm) || bm == Biome.beach.rawValue) && rng.nextFloat() < 0.3
        },
        plan: { ctx, ocx, ocz, rng in
            let x = ocx * 16 + 2, z = ocz * 16 + 4
            let seafloor = ctx.heightAt(x + 5, z + 4)
            let y = max(seafloor, 35)
            let variantRoll = rng.nextFloat()
            let variant = variantRoll < 0.4 ? "full" : variantRoll < 0.7 ? "bow" : "stern"
            let P = Int(cell(rng.nextBoolean() ? B.oak_planks : B.spruce_planks))
            let L = Int(cell(B.spruce_log))
            let len = 20
            return StructurePlan(id: "shipwreck", pieces: [
                piece(x - 1, y - 2, z - 1, x + len + 1, y + 12, z + 8) { b in
                    let tilt = b.rng.nextInt(3) - 1
                    let x0 = variant == "bow" ? 8 : 0
                    let x1 = variant == "stern" ? 12 : len
                    // hull
                    for dx in x0...x1 {
                        let w = dx < 3 || dx > len - 3 ? 2 : 3 // taper ends
                        let yy = y + Int((Double(dx * tilt) * 0.1).rounded(.down))
                        for dz in (4 - w)...(3 + w - 1) {
                            b.set(x + dx, yy, z + dz, P)
                            b.set(x + dx, yy + 1, z + 4 - w, P)
                            b.set(x + dx, yy + 1, z + 3 + w - 1, P)
                            b.set(x + dx, yy + 2, z + 4 - w, P)
                            b.set(x + dx, yy + 2, z + 3 + w - 1, P)
                        }
                        if dx == x0 || dx == x1 {
                            for dz in (4 - w)...(3 + w - 1) {
                                b.set(x + dx, yy + 1, z + dz, P)
                                b.set(x + dx, yy + 2, z + dz, P)
                            }
                        }
                        // deck
                        if dx > x0 + 1 && dx < x1 - 1 && b.rng.nextFloat() < 0.8 {
                            for dz in 2...5 { b.set(x + dx, yy + 3, z + dz, P) }
                        }
                    }
                    // mast
                    if variant != "stern" {
                        for h in 0..<9 { b.set(x + 12, y + 3 + h, z + 4, L) }
                    }
                    // chests
                    if variant != "bow" { b.chest(x + 3, y + 1, z + 4, 1, "shipwreck_supply") }
                    if variant != "stern" { b.chest(x + len - 3, y + 1, z + 4, 0, "shipwreck_treasure") }
                },
            ])
        }
    ))

    registerStructure(StructureDef(
        id: "ocean_ruin", spacing: 20, separation: 8, salt: 14357621, maxRadiusChunks: 1,
        check: { ctx, ocx, ocz, _ in
            isOceanBiome(ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8))
        },
        plan: { ctx, ocx, ocz, _ in
            let x = ocx * 16 + 4, z = ocz * 16 + 4
            let bm = ctx.biomeAt(x, z)
            let warm = bm == Biome.warmOcean.rawValue || bm == Biome.lukewarmOcean.rawValue || bm == Biome.deepLukewarmOcean.rawValue
            let y = ctx.heightAt(x + 3, z + 3)
            let W = warm ? Int(cell(B.sandstone)) : Int(cell(B.stone_bricks))
            let W2 = warm ? Int(cell(B.cut_sandstone)) : Int(cell(B.cracked_stone_bricks))
            return StructurePlan(id: "ocean_ruin", pieces: [
                piece(x - 1, y - 2, z - 1, x + 8, y + 6, z + 8) { b in
                    // ruined shell
                    for dz in 0..<7 { for dx in 0..<7 {
                        if dx == 0 || dx == 6 || dz == 0 || dz == 6 {
                            let h = b.rng.nextInt(4)
                            for dy in 0...h {
                                b.set(x + dx, y + dy, z + dz, b.rng.nextFloat() < 0.7 ? W : W2)
                            }
                        } else {
                            b.set(x + dx, y - 1, z + dz, W)
                        }
                    } }
                    let big = b.rng.nextFloat() < 0.3
                    b.chest(x + 3, y, z + 3, 0, big ? "underwater_ruin_big" : "underwater_ruin_small")
                    b.mob("drowned", x + 2, y + 1, z + 2, ["persistent": .bool(true)])
                    if big { b.mob("drowned", x + 4, y + 1, z + 4, ["persistent": .bool(true)]) }
                    // archaeology
                    b.suspicious(x + 1, y - 1, z + 5, !warm, warm ? "ocean_ruin_warm_archaeology" : "ocean_ruin_cold_archaeology")
                    b.suspicious(x + 5, y - 1, z + 1, !warm, warm ? "ocean_ruin_warm_archaeology" : "ocean_ruin_cold_archaeology")
                },
            ])
        }
    ))

    registerStructure(StructureDef(
        id: "buried_treasure", spacing: 8, separation: 4, salt: 10387320, maxRadiusChunks: 1,
        check: { ctx, ocx, ocz, rng in
            let bm = ctx.biomeAt(ocx * 16 + 9, ocz * 16 + 9)
            return (bm == Biome.beach.rawValue || bm == Biome.snowyBeach.rawValue) && rng.nextFloat() < 0.01 * 8
        },
        plan: { ctx, ocx, ocz, _ in
            let x = ocx * 16 + 9, z = ocz * 16 + 9
            let y = ctx.heightAt(x, z) - 4
            return StructurePlan(id: "buried_treasure", pieces: [
                piece(x, y, z, x, y, z) { b in
                    b.chest(x, y, z, 0, "buried_treasure")
                },
            ])
        }
    ))

    registerStructure(StructureDef(
        id: "ruined_portal", spacing: 28, separation: 10, salt: 34222645, maxRadiusChunks: 1,
        check: { ctx, ocx, ocz, _ in
            !isOceanBiome(ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8))
        },
        plan: { ctx, ocx, ocz, _ in
            let x = ocx * 16 + 5, z = ocz * 16 + 7
            let y = ctx.heightAt(x + 2, z)
            return StructurePlan(id: "ruined_portal", pieces: [
                piece(x - 3, y - 3, z - 3, x + 7, y + 6, z + 4) { b in
                    buildRuinedPortal(b, x, y, z, false)
                },
            ])
        }
    ))

    registerStructure(StructureDef(
        id: "trail_ruins", spacing: 34, separation: 8, salt: 83469867, maxRadiusChunks: 2,
        check: { ctx, ocx, ocz, _ in
            let bm = ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8)
            return bm == Biome.taiga.rawValue || bm == Biome.snowyTaiga.rawValue || bm == Biome.oldGrowthBirchForest.rawValue ||
                bm == Biome.oldGrowthPineTaiga.rawValue || bm == Biome.jungle.rawValue
        },
        plan: { ctx, ocx, ocz, rng in
            let cxw = ocx * 16 + 8, czw = ocz * 16 + 8
            let surfaceY = ctx.heightAt(cxw, czw)
            let y = surfaceY - 6
            var pieces: [StructPiece] = []
            let mats = [Int(cell(B.mud_bricks)), Int(cell(B.packed_mud)), Int(cell(B.terracotta)), Int(cell(B.cobblestone)), Int(cell(B.bricks))]
            let buildings = 3 + rng.nextInt(3)
            for _ in 0..<buildings {
                let bx = cxw + rng.nextInt(24) - 12, bz = czw + rng.nextInt(24) - 12
                let w = 5 + rng.nextInt(4), d = 5 + rng.nextInt(4), h = 3 + rng.nextInt(2)
                pieces.append(piece(bx - 1, y - 2, bz - 1, bx + w + 1, y + h + 1, bz + d + 1) { b in
                    for dz in 0...d {
                        for dx in 0...w {
                            let isWall = dx == 0 || dx == w || dz == 0 || dz == d
                            b.set(bx + dx, y - 1, bz + dz, mats[b.rng.nextInt(mats.count)])
                            if isWall {
                                let wh = b.rng.nextInt(h + 1)
                                for dy in 0...wh {
                                    if b.rng.nextFloat() < 0.85 { b.set(bx + dx, y + dy, bz + dz, mats[b.rng.nextInt(mats.count)]) }
                                }
                            }
                        }
                    }
                    // suspicious gravel with archaeology loot
                    for _ in 0..<3 {
                        let sx = bx + 1 + b.rng.nextInt(max(1, w - 1))
                        let sz = bz + 1 + b.rng.nextInt(max(1, d - 1))
                        b.suspicious(sx, y, sz, true, b.rng.nextFloat() < 0.18 ? "trail_ruins_rare" : "trail_ruins_archaeology")
                    }
                    // decorated pot + lamps
                    if b.rng.nextBoolean() {
                        b.set(bx + 2, y, bz + 2, Int(cell(B.decorated_pot)))
                        b.s.addBlockEntity(BESpec(x: bx + 2, y: y, z: bz + 2, kind: "pot_sherds"))
                    }
                })
            }
            return StructurePlan(id: "trail_ruins", pieces: pieces)
        }
    ))
}
