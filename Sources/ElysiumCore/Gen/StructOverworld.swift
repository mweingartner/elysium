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
    var fenceGate: Int
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
            wall: wallBlock, path: path, fence: Int(cell(bid("\(wood)_fence"))),
            fenceGate: Int(cell(bid("\(wood)_fence_gate"))), door: bid("\(wood)_door"),
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
        // A snow-block road is visually indistinguishable from its terrain.
        // Snow is deliberately excluded after structures are stamped, so a
        // dirt path remains a readable and walkable route through the village.
        return mk("spruce", Int(cell(B.snow_block)), Int(cell(B.dirt_path)), Int(cell(B.glass_pane)))
    default:
        return nil
    }
}

/// Maps a square house's local coordinates to world space. Local negative Z is
/// the front of the house; aligning it with the adjacent radial road prevents
/// a connector from ever crossing the house it serves.
private func villageHousePoint(_ centerX: Int, _ centerZ: Int,
                               _ localX: Int, _ localZ: Int, _ facing: Int) -> (Int, Int) {
    let right = rightOf(facing)
    return (centerX + localX * FACE_DX[right] - localZ * FACE_DX[facing],
            centerZ + localX * FACE_DZ[right] - localZ * FACE_DZ[facing])
}

/// A complete square dwelling centred on a grounded pad. It is deliberately
/// rotated as a single unit: foundation, door pair, outward-facing stair,
/// roof, furniture and residents always agree on the same front.
private func houseSmall(_ b: Builder, _ centerX: Int, _ y: Int, _ centerZ: Int,
                        _ st: VillageStyle, _ facing: Int, child: Bool = false) {
    func p(_ localX: Int, _ localZ: Int) -> (Int, Int) {
        villageHousePoint(centerX, centerZ, localX, localZ, facing)
    }
    for localZ in -2...2 {
        for localX in -2...2 {
            let point = p(localX, localZ)
            b.foundation(point.0, y - 1, point.1, st.wall)
            b.set(point.0, y, point.1, AIR)
            b.set(point.0, y + 1, point.1, AIR)
            b.set(point.0, y + 2, point.1, AIR)
        }
    }
    for h in 0..<3 {
        for localZ in -2...2 {
            for localX in -2...2 where abs(localX) == 2 || abs(localZ) == 2 {
                let point = p(localX, localZ)
                let window = h == 1 && ((localZ == -2 && localX == 0)
                    || (localZ == 2 && localX == 0) || (localX == -2 && localZ == 0))
                b.set(point.0, y + h, point.1, window ? st.window : st.planks)
            }
        }
    }
    for (localX, localZ) in [(-2, -2), (2, -2), (-2, 2), (2, 2)] {
        let point = p(localX, localZ)
        for h in 0..<3 { b.set(point.0, y + h, point.1, st.log) }
    }
    for localZ in -3...3 {
        for localX in -3...3 {
            let point = p(localX, localZ)
            b.set(point.0, y + 3, point.1,
                  abs(localX) <= 1 && abs(localZ) <= 1 ? st.planks : st.slab)
        }
    }
    b.set(centerX, y + 4, centerZ, st.slab)

    let door = p(0, -2)
    b.set(door.0, y, door.1, Int(cell(st.door, facing)))
    b.set(door.0, y + 1, door.1, Int(cell(st.door, 8)))
    let step = p(0, -3)
    b.foundation(step.0, y - 2, step.1, st.wall)
    // The stair's high half belongs beside the door, so it faces back toward
    // the house rather than away from the approach.
    b.set(step.0, y - 1, step.1, st.stairs | FACE_OPP[facing])

    let bedFoot = p(1, 0), bedHead = p(1, 1), crafting = p(-1, 1), torch = p(-1, -1)
    let bedFacing = FACE_OPP[facing]
    b.set(bedFoot.0, y, bedFoot.1, Int(cell(B.red_bed, bedFacing)))
    b.set(bedHead.0, y, bedHead.1, Int(cell(B.red_bed, bedFacing | 4)))
    b.set(crafting.0, y, crafting.1, Int(cell(B.crafting_table)))
    b.set(torch.0, y, torch.1, Int(cell(B.torch)))
    b.mob("villager", centerX, y, centerZ)
    if child {
        let childPoint = p(-1, 0)
        b.mob("villager", childPoint.0, y, childPoint.1,
              ["baby": .bool(true), "persistent": .bool(true)])
    }
}

private func houseJob(_ b: Builder, _ centerX: Int, _ y: Int, _ centerZ: Int,
                      _ st: VillageStyle, _ facing: Int, _ jobBlock: Int, _ lootTable: String?) {
    func p(_ localX: Int, _ localZ: Int) -> (Int, Int) {
        villageHousePoint(centerX, centerZ, localX, localZ, facing)
    }
    for localZ in -2...2 {
        for localX in -2...2 {
            let point = p(localX, localZ)
            b.foundation(point.0, y - 1, point.1, st.wall)
            b.set(point.0, y, point.1, AIR)
            b.set(point.0, y + 1, point.1, AIR)
            b.set(point.0, y + 2, point.1, AIR)
        }
    }
    for h in 0..<3 {
        for localZ in -2...2 {
            for localX in -2...2 where abs(localX) == 2 || abs(localZ) == 2 {
                let point = p(localX, localZ)
                let window = h == 1 && ((localZ == -2 && localX == 0)
                    || (localZ == 2 && localX == 0) || (localX == -2 && localZ == 0))
                b.set(point.0, y + h, point.1, window ? st.window : st.planks)
            }
        }
    }
    for (localX, localZ) in [(-2, -2), (2, -2), (-2, 2), (2, 2)] {
        let point = p(localX, localZ)
        for h in 0..<3 { b.set(point.0, y + h, point.1, st.log) }
    }
    for localZ in -3...3 {
        for localX in -3...3 {
            let point = p(localX, localZ)
            b.set(point.0, y + 3, point.1,
                  abs(localX) <= 1 && abs(localZ) <= 1 ? st.planks : st.slab)
        }
    }
    b.set(centerX, y + 4, centerZ, st.slab)

    let door = p(0, -2)
    b.set(door.0, y, door.1, Int(cell(st.door, facing)))
    b.set(door.0, y + 1, door.1, Int(cell(st.door, 8)))
    let step = p(0, -3)
    b.foundation(step.0, y - 2, step.1, st.wall)
    b.set(step.0, y - 1, step.1, st.stairs | FACE_OPP[facing])
    let job = p(1, 1), chest = p(-1, 1), torchA = p(-1, -1), torchB = p(1, -1)
    b.set(job.0, y, job.1, jobBlock)
    if let lootTable { b.chest(chest.0, y, chest.1, facing, lootTable) }
    b.set(torchA.0, y, torchA.1, Int(cell(B.torch)))
    b.set(torchB.0, y, torchB.1, Int(cell(B.torch)))
    b.mob("villager", centerX, y, centerZ)
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

private func villageLivestockPen(_ b: Builder, _ x: Int, _ y: Int, _ z: Int,
                                 _ st: VillageStyle, _ livestock: [String]) {
    for dz in 0...6 {
        for dx in 0...6 {
            let px = x + dx, pz = z + dz
            let edge = dx == 0 || dx == 6 || dz == 0 || dz == 6
            b.foundation(px, y - 1, pz, st.wall, 6)
            if edge {
                b.set(px, y, pz, st.fence)
                // A camel has a 1.5-block step height.  A second rail makes
                // the enclosure actually contain every livestock type rather
                // than letting desert camels walk over a nominal one-high
                // fence.
                b.set(px, y + 1, pz, st.fence)
            } else {
                b.set(px, y, pz, AIR)
                b.set(px, y + 1, pz, AIR)
                // Camels are taller than the ordinary two-block livestock;
                // clearing a third interior cell keeps desert pens genuinely
                // usable rather than spawning their riders into a roof.
                b.set(px, y + 2, pz, AIR)
            }
        }
    }
    // A real, interactive gate faces the path rather than an invisible gap.
    b.set(x + 3, y, z, st.fenceGate)
    // Leave a two-block pedestrian opening when the gate is opened, while the
    // lintel keeps a 2.375-block camel from stepping over the gate itself.
    b.set(x + 3, y + 1, z, AIR)
    b.set(x + 3, y + 2, z, st.fence)
    let spawnSites = [(2, 2), (4, 2), (2, 4), (4, 4)]
    for (index, mob) in livestock.enumerated() {
        let site = spawnSites[index % spawnSites.count]
        b.mob(mob, x + site.0, y, z + site.1, ["persistent": .bool(true)])
    }
}

private func villageLivestock(_ biomeID: Int, _ rng: Rng) -> [String] {
    switch biomeID {
    case Biome.desert.rawValue:
        return ["camel", "donkey"]
    case Biome.snowyPlains.rawValue, Biome.snowyTaiga.rawValue:
        return ["goat", "sheep"]
    default:
        let choices = ["cow", "sheep", "pig", "chicken"]
        return [choices[rng.nextInt(choices.count)], choices[rng.nextInt(choices.count)],
                choices[rng.nextInt(choices.count)]]
    }
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
    (-48, 0), (48, 0), (0, -48), (0, 48),
    (-32, -32), (32, -32), (-32, 32), (32, 32),
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

/// A radial village street.  Keeping the road's build box independent from
/// lamps lets a rejected lamp site stay out of terrain validation instead of
/// incorrectly discarding an otherwise sound settlement.
private struct VillageRoadSpec {
    let dx: Int
    let dz: Int
    let start: Int
    let length: Int
    /// One common walking elevation for the full three-block road width at
    /// each radial position.  It is a minimal one-block-grade envelope above
    /// the real terrain, so a road never tunnels into a contour or asks the
    /// player to jump a whole block.
    let levels: [Int]
    let footprint: VillageXZFootprint
}

/// Builds the smallest road deck that sits on or above every terrain column
/// beneath the three-wide street while changing by at most one block per
/// forward step.  This is the discrete upper Lipschitz envelope of the ground
/// profile.  A bounded four-block foundation keeps it a hillside road rather
/// than an implausible elevated bridge.
private func villageRoadLevels(_ ctx: GenCtx, _ centerX: Int, _ centerZ: Int,
                               _ dx: Int, _ dz: Int, _ start: Int, _ length: Int,
                               _ plazaY: Int) -> [Int]? {
    let end = start + length
    var surface: [Int] = []
    var laneSurfaces: [[Int]] = []
    surface.reserveCapacity(length + 1)
    laneSurfaces.reserveCapacity(length + 1)
    for i in start...end {
        var row: [Int] = []
        row.reserveCapacity(3)
        for w in -1...1 {
            let x = centerX + dx * i + (dz != 0 ? w : 0)
            let z = centerZ + dz * i + (dx != 0 ? w : 0)
            guard let y = dryVillageSurface(ctx, x, z) else { return nil }
            row.append(y)
        }
        guard let rowTop = row.max() else { return nil }
        surface.append(rowTop)
        laneSurfaces.append(row)
    }
    var levels = surface
    for target in levels.indices {
        for source in surface.indices {
            levels[target] = max(levels[target], surface[source] - abs(source - target))
        }
    }
    guard abs(levels[0] - plazaY) <= 1,
          zip(levels, laneSurfaces).allSatisfy({ level, row in
              row.allSatisfy { ground in level >= ground && level - ground <= 4 }
          }) else {
        return nil
    }
    return levels
}

/// Returns a walkable grade for a short, one-block-wide connector.  Endpoints
/// are anchored to their doorway/gate and adjoining road elevations, and every
/// deck cell is bounded over the actual terrain so foundations never stop in
/// midair below a path.
private func villageStraightPathLevels(_ ctx: GenCtx, _ startX: Int, _ startZ: Int,
                                       _ endX: Int, _ endZ: Int,
                                       _ startY: Int, _ endY: Int,
                                       exactEndpoints: Bool = false) -> [Int]? {
    let horizontal = startZ == endZ
    guard horizontal || startX == endX else { return nil }
    let count = horizontal ? abs(endX - startX) + 1 : abs(endZ - startZ) + 1
    let stepX = horizontal ? (endX >= startX ? 1 : -1) : 0
    let stepZ = horizontal ? 0 : (endZ >= startZ ? 1 : -1)
    var ground: [Int] = []
    ground.reserveCapacity(count)
    for index in 0..<count {
        guard let y = dryVillageSurface(ctx, startX + stepX * index, startZ + stepZ * index) else {
            return nil
        }
        ground.append(y)
    }
    var levels = ground
    levels[0] = max(levels[0], startY)
    levels[levels.count - 1] = max(levels[levels.count - 1], endY)
    let constraints = levels
    for target in levels.indices {
        for source in constraints.indices {
            levels[target] = max(levels[target], constraints[source] - abs(source - target))
        }
    }
    let endpointsMatch = exactEndpoints
        ? levels[0] == startY && levels[levels.count - 1] == endY
        : abs(levels[0] - startY) <= 1 && abs(levels[levels.count - 1] - endY) <= 1
    guard endpointsMatch,
          zip(levels, ground).allSatisfy({ level, terrain in level >= terrain && level - terrain <= 4 }) else {
        return nil
    }
    return levels
}

private func villagePathFacing(_ x0: Int, _ z0: Int, _ x1: Int, _ z1: Int) -> Int {
    if x1 > x0 { return 3 }
    if x1 < x0 { return 2 }
    return z1 > z0 ? 1 : 0
}

private struct VillageLivestockSite {
    let x: Int
    let y: Int
    let z: Int
    let roadLevel: Int
    let footprint: VillageXZFootprint
    let connector: VillageXZFootprint
}

/// Places the pen beside an accepted east/west street, with its north-facing
/// gate connected to that street.  This replaces the former distant diagonal
/// pen: it could be technically valid yet inaccessible, and one rough 7×7
/// patch arbitrarily cancelled an entire village before roads were known.
private func villageLivestockPenSite(_ ctx: GenCtx, _ centerX: Int, _ centerZ: Int,
                                     _ roads: [VillageRoadSpec],
                                     _ reserved: [VillageXZFootprint]) -> VillageLivestockSite? {
    for road in roads where road.dx != 0 {
        let end = road.start + road.length
        let candidateAlong = [end - 3, road.start + 10, end - 8]
        for along in candidateAlong where along >= road.start && along <= end {
            let gateX = centerX + road.dx * along
            let penX = gateX - 3
            let penZ = centerZ + 4
            let footprint = VillageXZFootprint(penX, penZ, penX + 6, penZ + 6)
            // The road already occupies z=center±1.  Start just beyond its
            // southern edge so the pen spur meets it without overwriting a
            // road stair or path block during later piece replay.
            let connector = VillageXZFootprint(gateX, centerZ + 2, gateX, penZ - 1)
            guard !reserved.contains(where: { footprint.intersects($0) || connector.intersects($0) }),
                  let y = dryStructurePadY(ctx, footprint.x0, footprint.z0,
                                            footprint.x1, footprint.z1,
                                            maxVariation: 3) else {
                continue
            }
            var routeIsDry = true
            for z in connector.z0...connector.z1 where dryVillageSurface(ctx, gateX, z) == nil {
                routeIsDry = false
            }
            if routeIsDry {
                return VillageLivestockSite(x: penX, y: y, z: penZ,
                                            roadLevel: road.levels[along - road.start],
                                            footprint: footprint, connector: connector)
            }
        }
    }
    return nil
}

private func dryVillageSurface(_ ctx: GenCtx, _ x: Int, _ z: Int) -> Int? {
    exactDrySurfaceFeetYOrEstimate(ctx, x, z)
}

/// Production Overworld planning must use exact base terrain. Legacy tests and
/// non-Overworld plans deliberately lack that oracle, so retain their existing
/// height closure only when no exact terrain is available by design—not when a
/// bounded oracle rejects a real site.
private func exactSurfaceFeetYOrEstimate(_ ctx: GenCtx, _ x: Int, _ z: Int) -> Int? {
    guard ctx.dim == Dim.overworld.rawValue, ctx.terrainOracle != nil else {
        return ctx.heightAt(x, z)
    }
    return exactTerrainSurface(ctx, x, z)?.feetY
}

private func exactDrySurfaceFeetYOrEstimate(_ ctx: GenCtx, _ x: Int, _ z: Int) -> Int? {
    guard ctx.dim == Dim.overworld.rawValue, ctx.terrainOracle != nil else {
        return ctx.heightAt(x, z)
    }
    guard let surface = exactTerrainSurface(ctx, x, z), surface.isDry else { return nil }
    return surface.feetY
}

private func exactDryPadYOrEstimate(_ ctx: GenCtx,
                                     _ x0: Int, _ z0: Int, _ x1: Int, _ z1: Int,
                                     anchorX: Int, anchorZ: Int,
                                     maxVariation: Int) -> Int? {
    guard ctx.dim == Dim.overworld.rawValue, ctx.terrainOracle != nil else {
        return ctx.heightAt(anchorX, anchorZ)
    }
    return exactDryTerrainPadY(ctx, x0, z0, x1, z1, maxVariation: maxVariation)
}

/// Witch huts deliberately tolerate water beneath their stilts, unlike a
/// conventional dry building. They still need every platform column sampled
/// exactly, plus a reachable solid footing for each stilt; otherwise a hill
/// can bury the room or deep water can leave it suspended in air.
private let witchHutMaxStiltDepth = 32

private func stiltedWitchHutYOrEstimate(_ ctx: GenCtx, _ x: Int, _ z: Int) -> Int? {
    guard ctx.dim == Dim.overworld.rawValue, ctx.terrainOracle != nil else {
        return max(64, ctx.heightAt(x + 3, z + 4) + 1)
    }
    var highFeet: Int?
    for zc in z...(z + 8) {
        for xc in x...(x + 6) {
            guard let surface = exactTerrainSurface(ctx, xc, zc) else { return nil }
            highFeet = max(highFeet ?? surface.feetY, surface.feetY)
        }
    }
    guard let highFeet else { return nil }
    let y = max(64, highFeet + 1)
    for (sx, sz) in [(1, 1), (5, 1), (1, 7), (5, 7)] {
        guard let surface = exactTerrainSurface(ctx, x + sx, z + sz),
              // The final sampled position must reach the top solid cell
              // (`feetY - 1`), not merely stop in a water column.
              y - surface.feetY <= witchHutMaxStiltDepth - 2 else {
            return nil
        }
    }
    return y
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
        // Roads and buildings follow their local dry surface and use bounded
        // foundations. Requiring one 80-block survey to fit inside 12 vertical
        // blocks disproportionately eliminated villages on the deliberately
        // rolling Rich Resources preset, despite its individual plots being
        // sound. Keep the local piece-by-piece grounding gate below.
        if valid, let lo = heights.min(), let hi = heights.max(), hi - lo <= 28 { return (x, z) }
    }
    return nil
}

private func validateVillagePieces(_ ctx: GenCtx, _ pieces: [StructPiece]) -> Bool {
    guard !pieces.isEmpty else { return false }
    var checked = 0
    for p in pieces {
        for z in p.z0...p.z1 {
            for x in p.x0...p.x1 {
                checked += 1
                guard checked <= 24_000, dryVillageSurface(ctx, x, z) != nil else { return false }
            }
        }
    }
    return true
}

private let villageForeignSurfaceStructureIDs: Set<String> = [
    "desert_temple", "jungle_temple", "igloo", "witch_hut", "pillager_outpost",
    "shipwreck", "ocean_ruin", "buried_treasure", "ruined_portal", "trail_ruins",
    "ocean_monument", "woodland_mansion",
]

/// Structure plans are stamped in frozen registry order.  Villages are first,
/// so a later temple/outpost/etc. could otherwise overwrite a door, roof, or
/// resident on dense maps.  Reject only the village candidate when its actual
/// pieces overlap an actual surface-structure piece; this preserves the older
/// landmark and keeps generation order-independent without reserving an
/// overly broad reference box.
func villageOverlapsForeignSurfaceStructure(_ ctx: GenCtx, _ villagePieces: [StructPiece],
                                            collisionDefinitions: [StructureDef] = STRUCTURES) -> Bool {
    guard let minX = villagePieces.map(\.x0).min(), let maxX = villagePieces.map(\.x1).max(),
          let minZ = villagePieces.map(\.z0).min(), let maxZ = villagePieces.map(\.z1).max() else {
        return true
    }
    let minChunkX = floorDiv(minX, 16), maxChunkX = floorDiv(maxX, 16)
    let minChunkZ = floorDiv(minZ, 16), maxChunkZ = floorDiv(maxZ, 16)
    for def in collisionDefinitions where villageForeignSurfaceStructureIDs.contains(def.id) {
        guard let placement = def.placement(ctx) else { continue }
        let radius = def.maxRadiusChunks
        let regionX = floorDiv(minChunkX - radius, placement.spacing)...floorDiv(maxChunkX + radius, placement.spacing)
        let regionZ = floorDiv(minChunkZ - radius, placement.spacing)...floorDiv(maxChunkZ + radius, placement.spacing)
        for rz in regionZ {
            for rx in regionX {
                let origin = structureOriginFor(def, placement: placement, seed: ctx.seed,
                                                 regionX: rx, regionZ: rz)
                guard origin.0 >= minChunkX - radius, origin.0 <= maxChunkX + radius,
                      origin.1 >= minChunkZ - radius, origin.1 <= maxChunkZ + radius,
                      let plan = getPlan(def, ctx, origin.0, origin.1),
                      surfaceStructurePlanWins(def, plan, ctx, origin.0, origin.1,
                                               collisionDefinitions: collisionDefinitions) else {
                    continue
                }
                if surfaceStructurePiecesOverlapXZ(villagePieces, plan.pieces) { return true }
            }
        }
    }
    return false
}

/// A temple is a single architectural mass, unlike a village's individually
/// grounded roads and buildings. It therefore needs one dry, gently sloped pad
/// before any block is emitted; otherwise a one-point height estimate can bury
/// its body and leave only decorative fragments visible.
private func dryStructurePadY(_ ctx: GenCtx, _ x0: Int, _ z0: Int, _ x1: Int, _ z1: Int,
                               maxVariation: Int) -> Int? {
    exactDryPadYOrEstimate(ctx, x0, z0, x1, z1,
                            anchorX: (x0 + x1) / 2, anchorZ: (z0 + z1) / 2,
                            maxVariation: maxVariation)
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
/// A selected member has one deterministic underwater attempt and may emit at
/// most one room. Keeping this bound per region, rather than tracking mutable
/// commits, makes lazy/concurrent chunk generation independent of load order.
private let dungeonRegionMaximumUnderwaterMembers = 1
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
    // A mutable "committed so far" counter would make a seed depend on the
    // order in which chunks arrive. Select at most one member from the full
    // aligned region instead. The selected member has one underwater attempt
    // and `tryDungeonPass` returns after one commit, so this is an
    // actual-output cap of one sealed underwater room per region.
    //
    // The hash subset preserves the deliberately rare underwater form while
    // the sorted tie-break makes the choice independent of iteration order.
    let eligible = raw.filter { Int($0.hash & 0xFF) == 29 }.sorted {
        if $0.hash != $1.hash { return $0.hash < $1.hash }
        if $0.member.cx != $1.member.cx { return $0.member.cx < $1.member.cx }
        if $0.member.cz != $1.member.cz { return $0.member.cz < $1.member.cz }
        return $0.member.pass < $1.member.pass
    }
    let orderedEligible = eligible.map(\.member)
    let estimatedRetainedBytes = raw.count * 40 + orderedEligible.count * 24
    precondition(estimatedRetainedBytes <= dungeonRegionMaximumRetainedBytesPerPlan)
    return DungeonRegionPlan(rawAcceptedCount: rawCandidateCount,
                             underwater: Set(orderedEligible.prefix(dungeonRegionMaximumUnderwaterMembers)))
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
    public let maximumUnderwaterMembers: Int
    public let maximumRawCandidates: Int
    public let maximumStoredMembers: Int
    public let maximumRetainedBytesPerPlan: Int
}

let dungeonRegionPlannerLimits = DungeonRegionPlannerLimits(
    side: dungeonRegionSide,
    cacheEntries: dungeonRegionCacheLimit,
    maximumPasses: dungeonRegionMaximumPasses,
    maximumUnderwaterMembers: dungeonRegionMaximumUnderwaterMembers,
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
    func hasBlockEntity(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        blockEntities.contains { $0.x == x && $0.y == y && $0.z == z }
            || base.hasBlockEntity(x, y, z)
    }
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

/// Unlike `isFluidCell`, this deliberately excludes lava. The registry marks
/// water itself and native water-filled aquatic flora as waterlogged, which is
/// the exact admissible precondition for a sealed underwater room.
private func isSubmergedWaterCell(_ value: Int) -> Bool {
    guard value >= 0, value <= Int(UInt16.max) else { return false }
    return isWaterlogged(UInt16(value))
}

/// Dungeons run after surface and underground structures. A room may replace
/// only dry cave void, natural geology/resources, and water for the
/// deliberately sealed underwater variant. In particular, ores must be
/// eligible: Rich Resources deliberately raises their frequency enough that a
/// whole-room preflight which rejects every ore almost never finds a room.
/// Construction blocks (including temple sandstone variants, mineshaft wood,
/// rails, and all block entities) remain ineligible before a detached buffer
/// can stamp through a landmark, road, or mineshaft.
private let dungeonNaturalTerrainNames: Set<String> = [
    "stone", "deepslate", "andesite", "diorite", "granite", "tuff",
    "gravel", "grass_block", "dirt", "coarse_dirt", "rooted_dirt", "clay", "mud",
    "calcite", "dripstone_block", "moss_block",
]

/// Natural cave decoration is safe to clear while forming a room. This is
/// deliberately a name allowlist rather than a generic `replaceable` test so
/// mineshaft cobwebs and other construction remnants cannot turn into an
/// implicit permission to overwrite a structure.
private let dungeonNaturalCaveDecorationNames: Set<String> = [
    "cave_vines", "cave_vines_plant", "glow_lichen", "hanging_roots",
    "moss_carpet", "pointed_dripstone", "spore_blossom", "small_dripleaf",
    "big_dripleaf", "big_dripleaf_stem",
]

private func dungeonMayReplace(_ value: Int, allowsWater: Bool) -> Bool {
    guard value >= 0 else { return false }
    if value == 0 { return true }
    // `isWaterlogged` is intentionally limited by the block registry to water
    // and native aquatic flora (including coral/sea pickles), never lava or a
    // generic replaceable construction block. Block entities remain rejected
    // by the footprint preflight below.
    if allowsWater && isSubmergedWaterCell(value) { return true }
    let id = value >> 4
    guard blockDefs.indices.contains(id) else { return false }
    let name = blockDefs[id].name
    return dungeonNaturalTerrainNames.contains(name)
        || dungeonNaturalCaveDecorationNames.contains(name)
        || name.hasSuffix("_ore")
}

/// Per-chunk dungeon passes share one terrain sink. Reserve every accepted
/// room's complete shell and doorway margin before the next pass searches so
/// a higher density can add a distinct dungeon instead of overwriting a
/// previously committed entrance or block entity.
private struct DungeonFootprint {
    let x0: Int
    let y0: Int
    let z0: Int
    let x1: Int
    let y1: Int
    let z1: Int

    func intersects(_ other: DungeonFootprint) -> Bool {
        !(x1 < other.x0 || x0 > other.x1 ||
          y1 < other.y0 || y0 > other.y1 ||
          z1 < other.z0 || z0 > other.z1)
    }
}

private func dungeonFootprint(x: Int, y: Int, z: Int, halfWidth: Int) -> DungeonFootprint {
    // The extra block in both horizontal directions covers whichever cardinal
    // doorway is selected. Keeping that margin in every direction makes the
    // result independent of pass order and prevents a later room from sealing
    // an earlier room's cave connection.
    DungeonFootprint(x0: x - halfWidth - 1, y0: y - 1, z0: z - halfWidth - 1,
                     x1: x + halfWidth + 1, y1: y + 3, z1: z + halfWidth + 1)
}

private func dungeonFootprintIsUnclaimed(_ sink: ChunkSink, _ footprint: DungeonFootprint,
                                         allowsWater: Bool) -> Bool {
    for y in footprint.y0...footprint.y1 {
        for z in footprint.z0...footprint.z1 {
            for x in footprint.x0...footprint.x1 {
                guard !sink.hasBlockEntity(x, y, z),
                      dungeonMayReplace(sink.get(x, y, z), allowsWater: allowsWater) else {
                    return false
                }
            }
        }
    }
    return true
}

/// A sealed room has no entrance: its complete future floor, dry interior,
/// and ceiling must start submerged. The surrounding footprint includes a
/// one-cell doorway margin for reservation/ownership only, so it is not part
/// of this water-envelope requirement.
private func dungeonRoomIsFullySubmerged(_ read: (Int, Int, Int) -> Int,
                                         x: Int, y: Int, z: Int,
                                         halfWidth: Int) -> Bool {
    for py in (y - 1)...(y + 3) {
        for pz in (z - halfWidth)...(z + halfWidth) {
            for px in (x - halfWidth)...(x + halfWidth) {
                guard isSubmergedWaterCell(read(px, py, pz)) else { return false }
            }
        }
    }
    return true
}

@discardableResult
private func tryDungeonPass(_ seed: UInt32, _ ocx: Int, _ ocz: Int, _ sink: ChunkSink,
                            pass: Int, settings: WorldGenerationSettings,
                            oracle: BaseTerrainOracle?,
                            occupied: inout [DungeonFootprint]) -> Int {
    let salt = pass == 0 ? UInt32(0xD0D6E0) : dungeonPassSalt(pass)
    let rng = Rng(hash2(seed, ocx, ocz, salt))
    for attempt in 0..<4 {
        if rng.nextFloat() > 0.12 { continue }
        let rawX = ocx * 16 + 3 + rng.nextInt(10)
        let rawZ = ocz * 16 + 3 + rng.nextInt(10)
        // Keep one deterministic vertical starting point, but walk the local
        // cave column from there. Previously a room had to land at one random
        // Y *and* have a two-block cave opening on its exact wall, causing
        // "many" to mean eight mostly-rejected attempts rather than dungeons.
        let sampledY = -40 + rng.nextInt(90)
        let hw = 3 + rng.nextInt(2)
        let minLocal = hw + 1, maxLocal = 15 - hw - 1
        let x = ocx * 16 + min(max(rawX - ocx * 16, minLocal), maxLocal)
        let z = ocz * 16 + min(max(rawZ - ocz * 16, minLocal), maxLocal)
        let read: (Int, Int, Int) -> Int = { x, y, z in
            // The complete room is intentionally clamped inside its origin
            // chunk. Read that finished local terrain so a dungeon cannot
            // overlap a structure that already owns this terrain.
            sink.get(x, y, z)
        }
        // The regional plan selects one attempt for an eligible member. Test
        // the final clamped room (not the discarded raw coordinate) across its
        // full sealed shell and future occupiable volume before admitting it.
        let underwaterAttempt = Int(dungeonRarityHash(seed, ocx, ocz, pass) & 0x3)
        let fullySubmerged = dungeonUnderwaterBudgetSelected(seed: seed, cx: ocx, cz: ocz,
                                                               pass: pass, settings: settings)
            && attempt == underwaterAttempt
            && dungeonRoomIsFullySubmerged(read, x: x, y: sampledY, z: z, halfWidth: hw)
        let surfaceCeiling = min(64, sink.topY(x, z) - 4)
        let lowestY = max(sink.minY + 2, -48)
        let highestY = max(lowestY, min(surfaceCeiling, sink.maxY - 5))
        let span = highestY - lowestY + 1
        let start = lowestY + ((sampledY - lowestY) % span + span) % span
        var selected: (y: Int, entrance: (dx: Int, dz: Int)?, footprint: DungeonFootprint)?
        for offset in 0..<span {
            let y = lowestY + ((start - lowestY + offset) % span)
            let footprint = dungeonFootprint(x: x, y: y, z: z, halfWidth: hw)
            guard !occupied.contains(where: { $0.intersects(footprint) }) else { continue }
            if fullySubmerged {
                if y == sampledY,
                   dungeonFootprintIsUnclaimed(sink, footprint, allowsWater: true) {
                    selected = (y, nil, footprint)
                    break
                }
                continue
            }
            var entrance: (dx: Int, dz: Int)?
            for direction in [(dx: -1, dz: 0), (dx: 1, dz: 0), (dx: 0, dz: -1), (dx: 0, dz: 1)] {
                let ex = x + direction.dx * (hw + 1), ez = z + direction.dz * (hw + 1)
                if read(ex, y, ez) == 0, read(ex, y + 1, ez) == 0 {
                    entrance = direction
                    break
                }
            }
            guard let entrance else { continue }
            var fluidFound = false
            for py in (y - 1)...(y + 3) {
                for pz in (z - hw - 1)...(z + hw + 1) {
                    for px in (x - hw - 1)...(x + hw + 1) where isFluidCell(read(px, py, pz)) {
                        fluidFound = true
                    }
                }
            }
            if !fluidFound {
                if dungeonFootprintIsUnclaimed(sink, footprint, allowsWater: false) {
                    selected = (y, entrance, footprint)
                    break
                }
            }
        }
        guard let selected else { continue }
        let y = selected.y
        let entrance = selected.entrance

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
        occupied.append(selected.footprint)
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
    var occupied: [DungeonFootprint] = []
    occupied.reserveCapacity(passes)
    for pass in 0..<passes {
        placed += tryDungeonPass(seed, ocx, ocz, sink, pass: pass,
                                 settings: effectiveSettings, oracle: terrainOracle,
                                 occupied: &occupied)
    }
    return placed
}

// =============================================================================
// registration
// =============================================================================
/// A deterministic, complete hamlet used only when the larger village cannot
/// find enough individually grounded roads and plots.  It deliberately keeps
/// the same safety contract as the full settlement: every emitted piece is
/// dry, every dwelling and pen has a bounded pad, each doorway/pen gate has a
/// grade-limited path, and the finished footprint is checked against other
/// conventional surface structures.  The shorter opposing streets make a
/// useful settlement possible on rolling resource-rich terrain without
/// reducing candidate separation or treating a broad terrain survey as a
/// foundation.
private func compactVillagePlan(_ ctx: GenCtx, _ ocx: Int, _ ocz: Int,
                                startingAt centerOffsetStart: Int = 0) -> StructurePlan? {
    let originX = ocx * 16 + 8
    let originZ = ocz * 16 + 8
    var center: (x: Int, z: Int, y: Int, biomeID: Int, style: VillageStyle, offsetIndex: Int)?
    // Unlike the full village's broad preflight, the fallback is intentionally
    // admitted by its actual nine-by-nine plaza pad.  Every later road,
    // dwelling, connector, and pen remains individually exact-validated.
    for (offsetIndex, (dx, dz)) in villageCenterOffsets.enumerated() where offsetIndex >= centerOffsetStart {
        let x = originX + dx
        let z = originZ + dz
        let biomeID = ctx.biomeAt(x, z)
        guard let style = styleFor(biomeID),
              let y = dryStructurePadY(ctx, x - 4, z - 4, x + 4, z + 4,
                                        maxVariation: 3) else {
            continue
        }
        center = (x, z, y, biomeID, style, offsetIndex)
        break
    }
    guard let center else { return nil }

    let centerX = center.x
    let centerZ = center.z
    let cy = center.y
    let st = center.style
    let livestock = villageLivestock(center.biomeID,
                                     Rng(hash2(ctx.seed, ocx, ocz, 0xC0A4_11E7)))
    var pieces: [StructPiece] = []
    var buildingFootprints: [VillageXZFootprint] = []
    var connectorCorridors: [VillageXZFootprint] = []
    var connectorPieces: [StructPiece] = []

    // This is the exact same supported community centre used by a full
    // village.  The well, bell, golem, and cat therefore never become a
    // decorative unsupported remnant when a larger plan was rejected.
    pieces.append(piece(centerX - 4, cy - 8, centerZ - 4,
                        centerX + 4, cy + 2, centerZ + 4) { b in
        for z in (centerZ - 4)...(centerZ + 4) {
            for x in (centerX - 4)...(centerX + 4) {
                b.foundation(x, cy - 1, z, st.path)
                b.set(x, cy, z, AIR)
                b.set(x, cy + 1, z, AIR)
                b.set(x, cy + 2, z, AIR)
            }
        }
    })
    pieces.append(piece(centerX - 1, cy - 11, centerZ - 1,
                        centerX + 4, cy + 3, centerZ + 4) { b in
        well(b, centerX, cy, centerZ, st)
    })
    pieces.append(piece(centerX - 4, cy - 8, centerZ,
                        centerX - 4, cy + 2, centerZ) { b in
        b.foundation(centerX - 4, cy - 1, centerZ, st.wall)
        b.set(centerX - 4, cy, centerZ, st.wall)
        b.set(centerX - 4, cy + 1, centerZ, Int(cell(B.bell, 0)))
    })
    let camelY = center.biomeID == Biome.desert.rawValue ? cy : nil
    let residentMinX = camelY == nil ? centerX : centerX - 3
    let residentMinZ = camelY == nil ? centerZ - 3 : centerZ - 4
    pieces.append(piece(residentMinX, cy, residentMinZ,
                        centerX + 2, cy + 2, centerZ - 3) { b in
        b.mob("iron_golem", centerX, cy, centerZ - 3)
        b.mob("cat", centerX + 2, cy, centerZ - 3)
        if let camelY { b.mob("camel", centerX - 3, camelY, centerZ - 4) }
    })

    // The compact layout uses two opposing, east/west roads.  This makes room
    // for a pen on the clear south side while retaining a second independent
    // route for four residents.  The road length still gives each arm a
    // complete 17-row, three-wide, grade-bounded walking corridor.
    let roadStart = 5
    let roadLength = 16
    let directionOrder = Rng(hash2(ctx.seed, ocx, ocz, 0xC0A4_11E8)).shuffle([1, -1])
    var roads: [VillageRoadSpec] = []
    for dx in directionOrder {
        guard let levels = villageRoadLevels(ctx, centerX, centerZ, dx, 0,
                                              roadStart, roadLength, cy) else {
            return compactVillagePlan(ctx, ocx, ocz, startingAt: center.offsetIndex + 1)
        }
        let end = roadStart + roadLength
        roads.append(VillageRoadSpec(
            dx: dx, dz: 0, start: roadStart, length: roadLength, levels: levels,
            footprint: VillageXZFootprint(min(centerX + dx * roadStart, centerX + dx * end),
                                          centerZ - 1,
                                          max(centerX + dx * roadStart, centerX + dx * end),
                                          centerZ + 1)
        ))
    }

    let jobs: [(Int, String?)] = [
        (Int(cell(B.smithing_table)), "village_weaponsmith"),
        (Int(cell(B.lectern, 0)), nil),
        (Int(cell(B.blast_furnace, 0)), "village_toolsmith"),
        (Int(cell(B.fletching_table)), nil),
    ]
    var jobIndex = Rng(hash2(ctx.seed, ocx, ocz, 0xC0A4_11E9)).nextInt(jobs.count)
    var houseIndex = 0
    for road in roads {
        // Both homes stay on the north side; the south side is intentionally
        // kept clear for the animal pen and its traversable gate path.
        for along in [roadStart + 4, roadStart + 11] {
            let side = -1
            let houseX = centerX + road.dx * along
            let houseZ = centerZ + side * 7
            let facing = 1
            let footprint = VillageXZFootprint(houseX - 3, houseZ - 3,
                                               houseX + 3, houseZ + 3)
            guard let y = dryStructurePadY(ctx, footprint.x0, footprint.z0,
                                            footprint.x1, footprint.z1,
                                            maxVariation: 3) else {
                return compactVillagePlan(ctx, ocx, ocz, startingAt: center.offsetIndex + 1)
            }
            let pathStart = villageHousePoint(houseX, houseZ, 0, -4, facing)
            let roadX = pathStart.0
            let roadZ = centerZ + side * 2
            let connector = VillageXZFootprint(pathStart.0, pathStart.1, roadX, roadZ)
            guard let pathLevels = villageStraightPathLevels(ctx, pathStart.0, pathStart.1,
                                                              roadX, roadZ, y,
                                                              road.levels[along - roadStart],
                                                              exactEndpoints: true),
                  !buildingFootprints.contains(where: { footprint.intersects($0) }),
                  !connectorCorridors.contains(where: { footprint.intersects($0) }),
                  !buildingFootprints.contains(where: { connector.intersects($0) }),
                  !connectorCorridors.contains(where: { connector.intersects($0) }) else {
                return compactVillagePlan(ctx, ocx, ocz, startingAt: center.offsetIndex + 1)
            }
            buildingFootprints.append(footprint)
            connectorCorridors.append(connector)
            let emitsChild = houseIndex == 0
            if emitsChild {
                pieces.append(piece(footprint.x0, y - 9, footprint.z0,
                                    footprint.x1, y + 6, footprint.z1) { b in
                    houseSmall(b, houseX, y, houseZ, st, facing, child: true)
                })
            } else {
                let job = jobs[jobIndex % jobs.count]
                jobIndex += 1
                pieces.append(piece(footprint.x0, y - 9, footprint.z0,
                                    footprint.x1, y + 6, footprint.z1) { b in
                    houseJob(b, houseX, y, houseZ, st, facing, job.0, job.1)
                })
            }
            let pathFacing = villagePathFacing(pathStart.0, pathStart.1, roadX, roadZ)
            let pathStepZ = roadZ > pathStart.1 ? 1 : -1
            connectorPieces.append(piece(connector.x0, (pathLevels.min() ?? y) - 8, connector.z0,
                                        connector.x1, (pathLevels.max() ?? y) + 3, connector.z1) { b in
                for index in pathLevels.indices {
                    let pz = pathStart.1 + pathStepZ * index
                    let py = pathLevels[index]
                    let previousY = pathLevels[max(0, index - 1)]
                    let nextY = pathLevels[min(pathLevels.count - 1, index + 1)]
                    b.foundation(pathStart.0, py - 1, pz, st.path, 8)
                    if nextY == py + 1 {
                        b.set(pathStart.0, py, pz, st.stairs | pathFacing)
                    } else if previousY == py + 1 {
                        b.set(pathStart.0, py, pz, st.stairs | FACE_OPP[pathFacing])
                    } else {
                        b.set(pathStart.0, py, pz, AIR)
                    }
                    b.set(pathStart.0, py + 1, pz, AIR)
                }
            })
            houseIndex += 1
        }
    }

    guard houseIndex == 4,
          let livestockPen = villageLivestockPenSite(ctx, centerX, centerZ,
                                                      roads, buildingFootprints + connectorCorridors) else {
        return compactVillagePlan(ctx, ocx, ocz, startingAt: center.offsetIndex + 1)
    }
    pieces.append(piece(livestockPen.footprint.x0, livestockPen.y - 6, livestockPen.footprint.z0,
                        livestockPen.footprint.x1, livestockPen.y + 3, livestockPen.footprint.z1) { b in
        villageLivestockPen(b, livestockPen.x, livestockPen.y, livestockPen.z, st, livestock)
    })
    let penGateX = livestockPen.x + 3
    let penPathStartZ = livestockPen.z - 1
    let penPathEndZ = livestockPen.connector.z0
    guard let penPathLevels = villageStraightPathLevels(ctx, penGateX, penPathStartZ,
                                                         penGateX, penPathEndZ,
                                                         livestockPen.y, livestockPen.roadLevel,
                                                         exactEndpoints: true) else {
        return compactVillagePlan(ctx, ocx, ocz, startingAt: center.offsetIndex + 1)
    }
    let penPathFacing = villagePathFacing(penGateX, penPathStartZ, penGateX, penPathEndZ)
    let penPathStepZ = penPathEndZ > penPathStartZ ? 1 : -1
    connectorPieces.append(piece(livestockPen.connector.x0, (penPathLevels.min() ?? livestockPen.y) - 8,
                                livestockPen.connector.z0, livestockPen.connector.x1,
                                (penPathLevels.max() ?? livestockPen.y) + 3, livestockPen.connector.z1) { b in
        for index in penPathLevels.indices {
            let pz = penPathStartZ + penPathStepZ * index
            let py = penPathLevels[index]
            let previousY = penPathLevels[max(0, index - 1)]
            let nextY = penPathLevels[min(penPathLevels.count - 1, index + 1)]
            b.foundation(penGateX, py - 1, pz, st.path, 8)
            if nextY == py + 1 {
                b.set(penGateX, py, pz, st.stairs | penPathFacing)
            } else if previousY == py + 1 {
                b.set(penGateX, py, pz, st.stairs | FACE_OPP[penPathFacing])
            } else {
                b.set(penGateX, py, pz, AIR)
            }
            b.set(penGateX, py + 1, pz, AIR)
        }
    })

    for road in roads {
        let end = road.start + road.length
        pieces.append(piece(road.footprint.x0, cy - 6, road.footprint.z0,
                            road.footprint.x1, cy + 30, road.footprint.z1) { b in
            let roadFacing = road.dx < 0 ? 2 : 3
            for i in road.start...end {
                let px = centerX + road.dx * i
                let levelIndex = i - road.start
                let wy = road.levels[levelIndex]
                let previousY = levelIndex == 0 ? cy : road.levels[levelIndex - 1]
                let nextY = road.levels[min(road.levels.count - 1, levelIndex + 1)]
                let risesFromPlaza = levelIndex == 0 && wy == cy + 1
                for width in -1...1 {
                    let wz = centerZ + width
                    b.foundation(px, (risesFromPlaza ? cy : wy) - 1, wz, st.path, 8)
                    if risesFromPlaza {
                        b.set(px, cy, wz, st.stairs | roadFacing)
                    } else if nextY == wy + 1 {
                        b.set(px, wy, wz, st.stairs | roadFacing)
                    } else if previousY == wy + 1 {
                        b.set(px, wy, wz, st.stairs | FACE_OPP[roadFacing])
                    } else {
                        b.set(px, wy, wz, AIR)
                    }
                    b.set(px, wy + 1, wz, AIR)
                }
            }
        })
    }
    pieces.append(contentsOf: connectorPieces)
    guard validateVillagePieces(ctx, pieces),
          !villageOverlapsForeignSurfaceStructure(
              ctx, pieces,
              collisionDefinitions: ctx.activeStructureDefinitions ?? STRUCTURES
          ) else {
        return compactVillagePlan(ctx, ocx, ocz, startingAt: center.offsetIndex + 1)
    }
    return StructurePlan(id: "village", pieces: pieces,
                         ref: StructRefBox(centerX - 80, cy - 20, centerZ - 80,
                                           centerX + 80, cy + 40, centerZ + 80))
}

private func villageStructureDefinition() -> StructureDef {
    StructureDef(
        id: "village", spacing: 34, separation: 18, salt: 10387312, maxRadiusChunks: 8,
        placement: { context in context.villageDensity.structurePlacement },
        check: { ctx, ocx, ocz, _ in
            ctx.villageDensity != .none
                && ctx.villageDensity.includesCandidate(seed: ctx.seed, originX: ocx, originZ: ocz)
                && styleFor(ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8)) != nil
        },
        plan: { ctx, ocx, ocz, rng in
            guard let (centerX, centerZ) = chooseVillageCenter(ctx, ocx * 16 + 8, ocz * 16 + 8) else {
                return compactVillagePlan(ctx, ocx, ocz)
            }
            let biomeId = ctx.biomeAt(centerX, centerZ)
            guard let st = styleFor(biomeId) else { return compactVillagePlan(ctx, ocx, ocz) }
            var pieces: [StructPiece] = []
            var acceptedBuildingFootprints: [VillageXZFootprint] = []
            var acceptedConnectorCorridors: [VillageXZFootprint] = []
            acceptedBuildingFootprints.reserveCapacity(16)
            acceptedConnectorCorridors.reserveCapacity(16)
            // The well, bell, residents, and the first blocks of every road
            // share this plaza.  Treat it as one actual pad rather than using
            // a centre sample, otherwise a bell or a well rim can be buried
            // on the adjacent contour.
            guard let cy = dryStructurePadY(ctx, centerX - 4, centerZ - 4,
                                            centerX + 4, centerZ + 4,
                                            maxVariation: 3) else {
                return compactVillagePlan(ctx, ocx, ocz)
            }
            // Village planning already rejects a piece with an unavailable or
            // wet exact surface. A transient later probe should therefore use
            // the accepted plaza level, never revive the approximate closure.
            let siteHeight: (Int, Int) -> Int = { x, z in
                dryVillageSurface(ctx, x, z) ?? cy
            }
            let livestock = villageLivestock(biomeId,
                                             Rng(hash2(ctx.seed, ocx, ocz, 0x71A5EED)))

            // A real plaza pad supports the well, bell, golem, cat, and desert
            // camel.  `cy` is the high edge of a gently sloped survey; without
            // this mass the residents on lower columns were merely placed in
            // air beside a decorative well.
            pieces.append(piece(centerX - 4, cy - 8, centerZ - 4,
                                centerX + 4, cy + 2, centerZ + 4) { b in
                for z in (centerZ - 4)...(centerZ + 4) {
                    for x in (centerX - 4)...(centerX + 4) {
                        b.foundation(x, cy - 1, z, st.path)
                        b.set(x, cy, z, AIR)
                        b.set(x, cy + 1, z, AIR)
                        b.set(x, cy + 2, z, AIR)
                    }
                }
            })
            // well at center
            pieces.append(piece(centerX - 1, cy - 11, centerZ - 1, centerX + 4, cy + 3, centerZ + 4) { b in
                well(b, centerX, cy, centerZ, st)
            })
            // bell next to well
            pieces.append(piece(centerX - 4, cy - 8, centerZ, centerX - 4, cy + 2, centerZ) { b in
                b.foundation(centerX - 4, cy - 1, centerZ, st.wall)
                b.set(centerX - 4, cy, centerZ, st.wall)
                b.set(centerX - 4, cy + 1, centerZ, Int(cell(B.bell, 0)))
            })
            // iron golem + extras at center
            let golemY = cy
            let catY = cy
            let camelY = biomeId == Biome.desert.rawValue
                ? cy
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
            // Roads start just beyond the well and bell plaza.  Beginning at
            // four used to stamp over the south/east well rim and west bell
            // after those pieces had been built.
            let roadStart = 5
            var roadSpecs: [VillageRoadSpec] = []
            var roadPieces: [StructPiece] = []
            var lampPieces: [StructPiece] = []
            var connectorPieces: [StructPiece] = []

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
            let arms = ctx.villageDensity.armCount.lowerBound == ctx.villageDensity.armCount.upperBound
                ? ctx.villageDensity.armCount.lowerBound
                : ctx.villageDensity.armCount.lowerBound
                    + rng.nextInt(ctx.villageDensity.armCount.count)
            let dirOrder = rng.shuffle([0, 1, 2, 3])
            // A settlement is only a village when it has a small resident
            // community, rather than one family surrounded by decorative
            // farms.  Count actual accepted homes/job-houses (each emits one
            // adult), not attempted plots, because rejected footprints must
            // never satisfy the population invariant.
            var childAssigned = false
            var adultResidentBuildings = 0
            for a in 0..<arms {
                let dir = dirOrder[a]
                let dx = [0, 0, -1, 1][dir], dz = [-1, 1, 0, 0][dir]
                let len = 14 + rng.nextInt(16)
                let roadEnd = roadStart + len
                let rx0 = min(centerX + dx * roadStart, centerX + dx * roadEnd) - (dz != 0 ? 1 : 0)
                let rx1 = max(centerX + dx * roadStart, centerX + dx * roadEnd) + (dz != 0 ? 1 : 0)
                let rz0 = min(centerZ + dz * roadStart, centerZ + dz * roadEnd) - (dx != 0 ? 1 : 0)
                let rz1 = max(centerZ + dz * roadStart, centerZ + dz * roadEnd) + (dx != 0 ? 1 : 0)
                guard let roadLevels = villageRoadLevels(ctx, centerX, centerZ, dx, dz,
                                                         roadStart, len, cy) else {
                    continue
                }
                roadSpecs.append(VillageRoadSpec(dx: dx, dz: dz, start: roadStart, length: len,
                                                  levels: roadLevels,
                                                  footprint: VillageXZFootprint(rx0, rz0, rx1, rz1)))
                // buildings along the arm
                let buildingCount = ctx.villageDensity.buildingCountPerArm
                let bcount = buildingCount.lowerBound == buildingCount.upperBound
                    ? buildingCount.lowerBound
                    : buildingCount.lowerBound + rng.nextInt(buildingCount.count)
                for _ in 0..<bcount {
                    let along = roadStart + 4 + rng.nextInt(max(1, len - 3))
                    let side = rng.nextBoolean() ? 1 : -1
                    var kind = rng.nextFloat()
                    // Every accepted settlement has a family, then enough
                    // inhabited homes to support a village rather than an
                    // empty agricultural layout.  Farms resume only after
                    // four adult residents are guaranteed.
                    if !childAssigned {
                        kind = 0.2
                    } else if adultResidentBuildings < 4 {
                        kind = 0.8
                    }
                    // A house is centred seven blocks from the three-wide road:
                    // its outer roof begins at distance three, its door/step
                    // face the road, and its two-cell connector begins only
                    // after the step.  Six made the connector a one-cell
                    // path whose house and road endpoints could disagree by
                    // one level on rolling terrain; seven preserves both
                    // exact endpoint elevations without reclaiming a street
                    // cell. The old one-sided anchors left several rotations
                    // with a road through the house interior.
                    let sideDistance = 7
                    let buildingCenterX = centerX + dx * along + (dz != 0 ? side * sideDistance : 0)
                    let buildingCenterZ = centerZ + dz * along + (dx != 0 ? side * sideDistance : 0)
                    let facing: Int
                    if dz != 0 {
                        facing = side > 0 ? 2 : 3
                    } else {
                        facing = side > 0 ? 0 : 1
                    }
                    let buildingFootprint: VillageXZFootprint
                    let by: Int
                    if kind < 0.4 || kind >= 0.62 {
                        buildingFootprint = VillageXZFootprint(buildingCenterX - 3, buildingCenterZ - 3,
                                                               buildingCenterX + 3, buildingCenterZ + 3)
                        guard let padY = dryStructurePadY(ctx, buildingFootprint.x0, buildingFootprint.z0,
                                                           buildingFootprint.x1, buildingFootprint.z1,
                                                           maxVariation: 3) else {
                            continue
                        }
                        by = padY
                    } else {
                        let farmX = buildingCenterX - 4, farmZ = buildingCenterZ - 3
                        buildingFootprint = VillageXZFootprint(farmX, farmZ, farmX + 8, farmZ + 6)
                        guard let padY = dryStructurePadY(ctx, buildingFootprint.x0, buildingFootprint.z0,
                                                           buildingFootprint.x1, buildingFootprint.z1,
                                                           maxVariation: 3) else {
                            continue
                        }
                        by = padY
                    }
                    let connectorFootprint: VillageXZFootprint?
                    let connectorLevels: [Int]?
                    let connectorStart = villageHousePoint(buildingCenterX, buildingCenterZ, 0, -4, facing)
                    let pathStartX = connectorStart.0, pathStartZ = connectorStart.1
                    // Stop at the block immediately outside the three-wide
                    // street.  The adjacent road edge remains owned by the
                    // grade-aware road piece rather than being reset to raw
                    // terrain height by the connector replay.
                    let roadX = dz != 0 ? centerX + side * 2 : pathStartX
                    let roadZ = dx != 0 ? centerZ + side * 2 : pathStartZ
                    if kind < 0.4 || kind >= 0.62 {
                        connectorFootprint = VillageXZFootprint(pathStartX, pathStartZ, roadX, roadZ)
                        guard let pathLevels = villageStraightPathLevels(ctx, pathStartX, pathStartZ,
                                                                          roadX, roadZ,
                                                                          // The doorstep stair is stored one cell
                                                                          // lower, but its walking surface reaches
                                                                          // the house floor at `by`.
                                                                          by,
                                                                          roadLevels[along - roadStart],
                                                                          exactEndpoints: true) else {
                            continue
                        }
                        connectorLevels = pathLevels
                    } else {
                        connectorFootprint = nil
                        connectorLevels = nil
                    }
                    // A later plot may not overwrite either an earlier home
                    // or its walkable front connection.  The old check only
                    // compared plots to connectors, which still allowed two
                    // houses on crossing arms to stamp through each other's
                    // doors, floors, or roof.
                    let buildingConflicts = acceptedBuildingFootprints.contains {
                        buildingFootprint.intersects($0)
                    } || acceptedConnectorCorridors.contains {
                        buildingFootprint.intersects($0)
                    }
                    let connectorConflicts = connectorFootprint.map { connector in
                        acceptedBuildingFootprints.contains { connector.intersects($0) }
                            || acceptedConnectorCorridors.contains { connector.intersects($0) }
                    } ?? false
                    guard !buildingConflicts && !connectorConflicts else {
                        continue
                    }
                    precondition(acceptedBuildingFootprints.count < 16)
                    acceptedBuildingFootprints.append(buildingFootprint)
                    if let connectorFootprint {
                        precondition(acceptedConnectorCorridors.count < 16)
                        acceptedConnectorCorridors.append(connectorFootprint)
                    }
                    if kind < 0.4 {
                        let emitsChild = !childAssigned
                        pieces.append(piece(buildingFootprint.x0, by - 9, buildingFootprint.z0,
                                            buildingFootprint.x1, by + 6, buildingFootprint.z1) { b in
                            houseSmall(b, buildingCenterX, by, buildingCenterZ, st, facing, child: emitsChild)
                        })
                        childAssigned = true
                        adultResidentBuildings += 1
                    } else if kind < 0.62 {
                        let farmX = buildingCenterX - 4, farmZ = buildingCenterZ - 3
                        pieces.append(piece(buildingFootprint.x0, by - 8, buildingFootprint.z0,
                                            buildingFootprint.x1, by + 3, buildingFootprint.z1) { b in
                            farm(b, farmX, by, farmZ, st, b.rng)
                        })
                    } else {
                        let job = jobs[jobIdx % jobs.count]
                        jobIdx += 1
                        pieces.append(piece(buildingFootprint.x0, by - 9, buildingFootprint.z0,
                                            buildingFootprint.x1, by + 6, buildingFootprint.z1) { b in
                            houseJob(b, buildingCenterX, by, buildingCenterZ, st, facing, job.0, job.1)
                        })
                        adultResidentBuildings += 1
                    }
                    if let connectorFootprint, let connectorLevels {
                        let x0 = connectorFootprint.x0, x1 = connectorFootprint.x1
                        let z0 = connectorFootprint.z0, z1 = connectorFootprint.z1
                        let pathFacing = villagePathFacing(pathStartX, pathStartZ, roadX, roadZ)
                        let stepX = roadX == pathStartX ? 0 : (roadX > pathStartX ? 1 : -1)
                        let stepZ = roadZ == pathStartZ ? 0 : (roadZ > pathStartZ ? 1 : -1)
                        connectorPieces.append(piece(x0, (connectorLevels.min() ?? by) - 8, z0,
                                                    x1, (connectorLevels.max() ?? by) + 3, z1) { b in
                            for index in connectorLevels.indices {
                                let px = pathStartX + stepX * index
                                let pz = pathStartZ + stepZ * index
                                let py = connectorLevels[index]
                                let previousY = connectorLevels[max(0, index - 1)]
                                let nextY = connectorLevels[min(connectorLevels.count - 1, index + 1)]
                                b.foundation(px, py - 1, pz, st.path, 8)
                                if nextY == py + 1 {
                                    b.set(px, py, pz, st.stairs | pathFacing)
                                } else if previousY == py + 1 {
                                    b.set(px, py, pz, st.stairs | FACE_OPP[pathFacing])
                                } else {
                                    b.set(px, py, pz, AIR)
                                }
                                b.set(px, py + 1, pz, AIR)
                            }
                        })
                    }
                }
            }
            let penReservations = acceptedBuildingFootprints + acceptedConnectorCorridors
            guard let livestockPen = villageLivestockPenSite(ctx, centerX, centerZ,
                                                              roadSpecs, penReservations) else {
                return compactVillagePlan(ctx, ocx, ocz)
            }
            acceptedBuildingFootprints.append(livestockPen.footprint)
            acceptedConnectorCorridors.append(livestockPen.connector)
            pieces.append(piece(livestockPen.footprint.x0, livestockPen.y - 6, livestockPen.footprint.z0,
                                livestockPen.footprint.x1, livestockPen.y + 3, livestockPen.footprint.z1) { b in
                villageLivestockPen(b, livestockPen.x, livestockPen.y, livestockPen.z, st, livestock)
            })
            let penGateX = livestockPen.x + 3
            let penPathStartZ = livestockPen.z - 1
            let penPathEndZ = livestockPen.connector.z0
            guard let penPathLevels = villageStraightPathLevels(ctx, penGateX, penPathStartZ,
                                                                 penGateX, penPathEndZ,
                                                                 livestockPen.y, livestockPen.roadLevel,
                                                                 exactEndpoints: true) else {
                return compactVillagePlan(ctx, ocx, ocz)
            }
            let penPathFacing = villagePathFacing(penGateX, penPathStartZ, penGateX, penPathEndZ)
            let penPathStepZ = penPathEndZ > penPathStartZ ? 1 : -1
            connectorPieces.append(piece(livestockPen.connector.x0, (penPathLevels.min() ?? livestockPen.y) - 8,
                                         livestockPen.connector.z0, livestockPen.connector.x1,
                                         (penPathLevels.max() ?? livestockPen.y) + 3, livestockPen.connector.z1) { b in
                for index in penPathLevels.indices {
                    let pz = penPathStartZ + penPathStepZ * index
                    let py = penPathLevels[index]
                    let previousY = penPathLevels[max(0, index - 1)]
                    let nextY = penPathLevels[min(penPathLevels.count - 1, index + 1)]
                    b.foundation(penGateX, py - 1, pz, st.path, 8)
                    if nextY == py + 1 {
                        b.set(penGateX, py, pz, st.stairs | penPathFacing)
                    } else if previousY == py + 1 {
                        b.set(penGateX, py, pz, st.stairs | FACE_OPP[penPathFacing])
                    } else {
                        b.set(penGateX, py, pz, AIR)
                    }
                    b.set(penGateX, py + 1, pz, AIR)
                }
            })
            // Roads are stamped after houses but before their connectors.  A
            // road never reaches a roof, while connector paths deliberately
            // meet its edge.  Lamps are their own pieces and are omitted only
            // when a complete roof, farm, or connector reserves that column.
            for road in roadSpecs {
                let end = road.start + road.length
                roadPieces.append(piece(road.footprint.x0, cy - 6, road.footprint.z0,
                                        road.footprint.x1, cy + 30, road.footprint.z1) { b in
                    let roadFacing = road.dz < 0 ? 0 : road.dz > 0 ? 1 : road.dx < 0 ? 2 : 3
                    for i in road.start...end {
                        let px = centerX + road.dx * i, pz = centerZ + road.dz * i
                        for w in -1...1 {
                            let wx = px + (road.dz != 0 ? w : 0)
                            let wz = pz + (road.dx != 0 ? w : 0)
                            let levelIndex = i - road.start
                            let wy = road.levels[levelIndex]
                            let previousY = levelIndex == 0 ? cy : road.levels[levelIndex - 1]
                            let nextY = road.levels[min(road.levels.count - 1, levelIndex + 1)]
                            let risesFromPlaza = levelIndex == 0 && wy == cy + 1
                            b.foundation(wx, (risesFromPlaza ? cy : wy) - 1, wz, st.path, 8)
                            // A one-block rise receives a real stair whose
                            // high half points to the higher neighbour.  This
                            // keeps the road traversable by the player's
                            // 0.6-block auto-step instead of turning every
                            // terrain contour into a jump.
                            if risesFromPlaza {
                                // The first road block is also the ramp from
                                // the adjacent plaza: its stair base belongs
                                // one cell below the deck it reaches.
                                b.set(wx, cy, wz, st.stairs | roadFacing)
                            } else if nextY == wy + 1 {
                                b.set(wx, wy, wz, st.stairs | roadFacing)
                            } else if previousY == wy + 1 {
                                b.set(wx, wy, wz, st.stairs | FACE_OPP[roadFacing])
                            } else {
                                b.set(wx, wy, wz, AIR)
                            }
                            b.set(wx, wy + 1, wz, AIR)
                        }
                    }
                })
                for i in road.start...end where i % 7 == 0 {
                    let px = centerX + road.dx * i, pz = centerZ + road.dz * i
                    let lx = px + (road.dz != 0 ? 2 : 0)
                    let lz = pz + (road.dx != 0 ? 2 : 0)
                    let lampFootprint = VillageXZFootprint(lx, lz, lx, lz)
                    guard !acceptedBuildingFootprints.contains(where: { lampFootprint.intersects($0) }),
                          !acceptedConnectorCorridors.contains(where: { lampFootprint.intersects($0) }) else {
                        continue
                    }
                    let ly = siteHeight(lx, lz)
                    lampPieces.append(piece(lx, ly - 8, lz, lx, ly + 3, lz) { b in
                        b.foundation(lx, ly - 1, lz, st.wall)
                        b.set(lx, ly, lz, st.fence)
                        b.set(lx, ly + 1, lz, st.fence)
                        b.set(lx, ly + 2, lz, Int(cell(B.torch)))
                    })
                }
            }
            pieces.append(contentsOf: roadPieces)
            pieces.append(contentsOf: lampPieces)
            pieces.append(contentsOf: connectorPieces)
            guard childAssigned, adultResidentBuildings >= 4 else { return compactVillagePlan(ctx, ocx, ocz) }
            guard validateVillagePieces(ctx, pieces) else { return compactVillagePlan(ctx, ocx, ocz) }
            guard !villageOverlapsForeignSurfaceStructure(
                ctx, pieces,
                collisionDefinitions: ctx.activeStructureDefinitions ?? STRUCTURES
            ) else { return compactVillagePlan(ctx, ocx, ocz) }
            return StructurePlan(id: "village", pieces: pieces,
                                 ref: StructRefBox(centerX - 80, cy - 20, centerZ - 80, centerX + 80, cy + 40, centerZ + 80))
        }
    )
}

func registerOverworldStructures() {
    registerStructure(villageStructureDefinition())

    registerStructure(StructureDef(
        id: "desert_temple", spacing: 32, separation: 9, salt: 14357617, maxRadiusChunks: 2,
        check: { ctx, ocx, ocz, _ in
            ctx.biomeAt(ocx * 16 + 8, ocz * 16 + 8) == Biome.desert.rawValue
        },
        plan: { ctx, ocx, ocz, _ in
            let x = ocx * 16, z = ocz * 16
            // Do not assemble a pyramid from a single centre-height sample.
            // A dry, nearly level footprint prevents its body from being
            // swallowed by a hill while isolated decorative pieces remain.
            guard let y = dryStructurePadY(ctx, x, z, x + 20, z + 20, maxVariation: 4) else {
                return nil
            }
            let SS = Int(cell(B.sandstone)), CUT = Int(cell(B.cut_sandstone)), CHIS = Int(cell(B.chiseled_sandstone))
            let BL = Int(cell(B.blue_terracotta))
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
                    b.fill(cx2 - 1, y - 1, cz2 - 1, cx2 + 1, y - 1, cz2 + 1, CUT)
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
                    // archaeology
                    b.suspicious(cx2 - 2, y - 14, cz2 - 2, false, "desert_pyramid_archaeology")
                    b.suspicious(cx2 + 2, y - 14, cz2 + 2, false, "desert_pyramid_archaeology")
                    b.suspicious(cx2 + 2, y - 14, cz2 - 2, false, "desert_pyramid_archaeology")
                    b.suspicious(cx2 - 2, y - 14, cz2 + 2, false, "desert_pyramid_archaeology")
                },
            ], ref: StructRefBox(x - 1, y - 16, z - 1, x + 21, y + 22, z + 21))
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
            guard let y = exactDryPadYOrEstimate(ctx,
                                                 x, z - 2, x + 11, z + 14,
                                                 anchorX: x + 6, anchorZ: z + 7,
                                                 maxVariation: 4) else {
                return nil
            }
            let C = Int(cell(B.cobblestone)), M = Int(cell(B.mossy_cobblestone))
            let STAIR = Int(cell(B.cobblestone_stairs)), DOOR = bid("jungle_door")
            let mossy: [(Int, Double)] = [(C, 6), (M, 4)]
            return StructurePlan(id: "jungle_temple", pieces: [
                piece(x - 1, y - 6, z - 2, x + 12, y + 14, z + 15) { b in
                    for dz in 0..<15 { for dx in 0..<12 { b.foundation(x + dx, y - 1, z + dz, C, 6) } }
                    b.fillRandom(x, y, z, x + 11, y, z + 14, mossy)
                    b.fillRandom(x, y + 1, z, x + 11, y + 4, z + 14, mossy)
                    b.fill(x + 1, y + 1, z + 1, x + 10, y + 3, z + 13, AIR)
                    b.fillRandom(x + 1, y + 4, z + 1, x + 10, y + 4, z + 13, mossy)
                    b.fillRandom(x + 2, y + 5, z + 2, x + 9, y + 8, z + 12, mossy)
                    b.fill(x + 3, y + 5, z + 3, x + 8, y + 7, z + 11, AIR)
                    b.fillRandom(x + 3, y + 9, z + 3, x + 8, y + 10, z + 11, mossy)
                    // The tall north arch remains part of the ruin silhouette,
                    // but it used to be the only "entrance": it began four
                    // blocks above the surrounding ground and never met the
                    // interior stairs.  Give the lower room a real, supported
                    // north vestibule: a two-wide jungle door over its floor,
                    // a stair whose high half reaches that threshold, and a
                    // short ground-level landing.
                    b.fill(x + 5, y + 5, z, x + 6, y + 7, z + 3, AIR)
                    b.fill(x + 5, y + 1, z + 1, x + 6, y + 4, z + 1, AIR)
                    for dx in 5...6 {
                        b.foundation(x + dx, y - 1, z - 2, C, 6)
                        b.set(x + dx, y - 1, z - 2, Int(cell(B.dirt_path)))
                        b.foundation(x + dx, y - 1, z - 1, C, 6)
                        b.set(x + dx, y, z - 1, STAIR | FACE_OPP[0])
                        b.clear(x + dx, y + 1, z - 2, x + dx, y + 3, z)
                        b.set(x + dx, y + 1, z, Int(cell(DOOR, 0)))
                        // The west leaf hinges right and the east leaf hinges
                        // left, so the paired doors swing away from their seam.
                        b.set(x + dx, y + 2, z, Int(cell(DOOR, dx == 5 ? 9 : 8)))
                    }
                    // stairs down inside
                    for i in 0..<4 {
                        let stairY = y + 4 - i, stairZ = z + 4 + i
                        // The descending flight runs south, so its high half
                        // must face north toward the preceding step.  Fill the
                        // complete wedge below it, not merely its top support,
                        // so no riser or support cell is left floating.
                        b.fill(x + 5, y, stairZ, x + 6, stairY - 1, stairZ, C)
                        b.set(x + 5, stairY, stairZ, Int(cell(B.cobblestone_stairs, 0)))
                        b.set(x + 6, stairY, stairZ, Int(cell(B.cobblestone_stairs, 0)))
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
            // The dome and its entrance tunnel are one land structure. Check
            // their entire occupied footprint, then keep its four-deep
            // foundations within the allowed contour variation.
            guard let y = exactDryPadYOrEstimate(ctx,
                                                 x, z, x + 6, z + 9,
                                                 anchorX: x + 3, anchorZ: z + 3,
                                                 maxVariation: 3) else {
                return nil
            }
            let SNOW = Int(cell(B.snow_block)), RAMP = Int(cell(B.stone_brick_stairs, 0))
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
                    // The tunnel extends past the seven-by-seven dome, so it
                    // needs its own foundations on a contoured (but accepted)
                    // pad instead of depending on an arbitrary centre sample.
                    for dz in 6...9 {
                        b.foundation(x + 2, y, z + dz, SNOW, 4)
                        b.foundation(x + 3, y - 1, z + dz, SNOW, 4)
                        b.foundation(x + 4, y, z + dz, SNOW, 4)
                    }
                    b.fill(x + 3, y + 1, z + 6, x + 3, y + 2, z + 9, AIR)
                    b.fill(x + 2, y + 1, z + 6, x + 2, y + 3, z + 9, SNOW)
                    b.fill(x + 4, y + 1, z + 6, x + 4, y + 3, z + 9, SNOW)
                    b.fill(x + 2, y + 3, z + 6, x + 4, y + 3, z + 9, SNOW)
                    // The center tunnel floor is one block below the dome's
                    // south floor.  Its north-facing high half meets that
                    // landing, while the center foundation directly supports
                    // the ramp instead of leaving a one-block dead end.
                    b.set(x + 3, y, z + 6, RAMP)
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
            guard let y = stiltedWitchHutYOrEstimate(ctx, x, z) else { return nil }
            let P = Int(cell(B.spruce_planks)), L = Int(cell(B.oak_log))
            return StructurePlan(id: "witch_hut", pieces: [
                piece(x - 1, y - witchHutMaxStiltDepth, z - 1, x + 8, y + 7, z + 10) { b in
                    // stilts
                    for (sx, sz) in [(1, 1), (5, 1), (1, 7), (5, 7)] {
                        for d in 0..<witchHutMaxStiltDepth {
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
                    // `walls` supplies a solid room floor at y+2.  Spawn the
                    // residents on its upper surface instead of embedding
                    // them in that floor; the two cells through the roof stay
                    // explicitly clear for their normal bodies.
                    b.mob("witch", x + 3, y + 3, z + 4, ["persistent": .bool(true)])
                    b.mob("cat", x + 2, y + 3, z + 5,
                          ["variant": .num(Double(CatVariant.allBlack.rawValue)), "persistent": .bool(true)])
                },
            ], ref: StructRefBox(x - 8, y - witchHutMaxStiltDepth, z - 8, x + 14, y + 12, z + 16))
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
            // The tower, cage, tent, and both patrol positions form one
            // ordinary land outpost. Survey that full occupied area rather
            // than placing the tower from a centre estimate and leaving its
            // detached pieces floating across a contour.
            guard let y = exactDryPadYOrEstimate(ctx,
                                                 x - 5, z - 2, x + 14, z + 10,
                                                 anchorX: x + 4, anchorZ: z + 4,
                                                 maxVariation: 3) else {
                return nil
            }
            let eastPatrolY = exactDrySurfaceFeetYOrEstimate(ctx, x + 9, z + 8)
            let westPatrolY = exactDrySurfaceFeetYOrEstimate(ctx, x - 2, z + 2)
            let P = Int(cell(B.dark_oak_planks)), L = Int(cell(B.dark_oak_log)), C = Int(cell(B.cobblestone))
            let STAIR = Int(cell(B.dark_oak_stairs)), DOOR = bid("dark_oak_door")
            return StructurePlan(id: "pillager_outpost", pieces: [
                piece(x - 6, y - 6, z - 6, x + 14, y + 22, z + 14) { b in
                    for dz in 0..<8 { for dx in 0..<8 { b.foundation(x + dx, y - 1, z + dz, C, 6) } }
                    b.walls(x, y, z, x + 7, y + 3, z + 7, C, AIR)
                    b.walls(x + 1, y + 4, z + 1, x + 6, y + 9, z + 6, P, AIR)
                    b.walls(x, y + 10, z, x + 7, y + 14, z + 7, P, AIR)
                    for (cx2, cz2) in [(0, 0), (7, 0), (0, 7), (7, 7)] {
                        for h in 0..<15 { b.set(x + cx2, y + h, z + cz2, L) }
                    }
                    // A conventional tower needs a usable entry rather than
                    // a two-wide void through its raised floor.  Keep the
                    // floor beneath the door, clear its body, then join the
                    // natural grade to it with a supported two-wide stair.
                    for dx in 3...4 {
                        b.clear(x + dx, y + 1, z, x + dx, y + 2, z)
                        b.set(x + dx, y + 1, z, Int(cell(DOOR, 0)))
                        // Mirror the hinge bit across the double-door seam.
                        b.set(x + dx, y + 2, z, Int(cell(DOOR, dx == 3 ? 9 : 8)))
                        b.foundation(x + dx, y - 1, z - 2, C, 6)
                        b.set(x + dx, y - 1, z - 2, Int(cell(B.dirt_path)))
                        b.foundation(x + dx, y - 1, z - 1, C, 6)
                        b.set(x + dx, y, z - 1, STAIR | FACE_OPP[0])
                        b.clear(x + dx, y + 1, z - 2, x + dx, y + 2, z - 1)
                    }
                    // floors + ladders
                    b.fill(x + 1, y + 4, z + 1, x + 6, y + 4, z + 6, P)
                    b.fill(x + 1, y + 10, z + 1, x + 6, y + 10, z + 6, P)
                    b.set(x + 1, y + 4, z + 1, AIR); b.set(x + 1, y + 10, z + 1, AIR)
                    for h in 0..<14 {
                        // Ladder meta 5 mounts on the north face of z + 2;
                        // restore a continuous backing post after the floor
                        // openings above, rather than leaving several rungs
                        // visibly unsupported.
                        b.set(x + 1, y + h, z + 1, L)
                        b.set(x + 1, y + h, z + 2, Int(cell(B.ladder, 5)))
                    }
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
                    // `walls` owns a solid lower floor at y, so the indoor
                    // guard must stand above it rather than spawn embedded.
                    b.mob("pillager", x + 2, y + 1, z + 3, ["persistent": .bool(true)])
                    if let eastPatrolY {
                        b.mob("pillager", x + 9, eastPatrolY, z + 8, ["persistent": .bool(true)])
                    }
                    if let westPatrolY {
                        b.mob("pillager", x - 2, westPatrolY, z + 2, ["persistent": .bool(true)])
                    }
                    // golem cage (50%)
                    if b.rng.nextBoolean() {
                        let gx = x + 11, gz = z + 2
                        let gy = y
                        // `walls` would make a fence-shaped lower plane: a
                        // 1.4-wide golem standing above that 1.5-high shape
                        // still overlaps it. Build a full-cube floor, raised
                        // fence rails, three clear interior cells, and a roof
                        // explicitly so the captive has genuine footing and
                        // headroom.
                        for cageZ in gz...(gz + 3) {
                            for cageX in gx...(gx + 3) {
                                b.foundation(cageX, gy, cageZ, P, 4)
                            }
                        }
                        b.fill(gx, gy, gz, gx + 3, gy, gz + 3, P)
                        for cageY in (gy + 1)...(gy + 3) {
                            for cageZ in gz...(gz + 3) {
                                for cageX in gx...(gx + 3) {
                                    let edge = cageX == gx || cageX == gx + 3 || cageZ == gz || cageZ == gz + 3
                                    b.set(cageX, cageY, cageZ, edge ? Int(cell(B.dark_oak_fence)) : AIR)
                                }
                            }
                        }
                        b.fill(gx, gy + 4, gz, gx + 3, gy + 4, gz + 3, P)
                        // The cage's `walls` helper likewise emits its floor
                        // at gy; put the captive on that floor's top surface.
                        b.mob("iron_golem", gx + 1, gy + 1, gz + 1)
                    }
                    // tent
                    let tx = x - 5, tz = z + 8
                    let ty = y
                    for tentZ in tz...(tz + 2) {
                        for tentX in tx...(tx + 2) {
                            b.foundation(tentX, ty, tentZ, P, 4)
                        }
                    }
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
            // Wrecks are intentionally beach/ocean-integrated, so preserve
            // their water semantics while anchoring to exact base terrain.
            guard let seafloor = exactSurfaceFeetYOrEstimate(ctx, x + 5, z + 4) else {
                return nil
            }
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
            // Ocean ruins intentionally remain underwater when this exact
            // terrain column is covered; do not apply a dry-pad filter here.
            guard let y = exactSurfaceFeetYOrEstimate(ctx, x + 3, z + 3) else {
                return nil
            }
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
            // Treasure is intentionally buried below its exact surface.
            guard let surfaceY = exactSurfaceFeetYOrEstimate(ctx, x, z) else { return nil }
            let y = surfaceY - 4
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
            // The Overworld frame has no general foundation, so only accept a
            // fully dry, level landing patch. The Nether has no base-terrain
            // oracle and deliberately preserves its existing floor probe.
            guard let y = exactDryPadYOrEstimate(ctx,
                                                 x - 2, z - 2, x + 4, z + 2,
                                                 anchorX: x + 2, anchorZ: z,
                                                 maxVariation: 0) else {
                return nil
            }
            return StructurePlan(id: "ruined_portal", pieces: [
                piece(x - 3, y - 3, z - 3, x + 7, y + 6, z + 4) { b in
                    buildRuinedPortal(b, x, y, z, ctx.dim == Dim.nether.rawValue)
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
            // Trail ruins are intentionally buried, but their depth must be
            // relative to the exact local terrain rather than an estimate.
            guard let surfaceY = exactSurfaceFeetYOrEstimate(ctx, cxw, czw) else {
                return nil
            }
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
