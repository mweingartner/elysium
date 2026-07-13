// Feature placement — Every tree, plant patch, geode,
// iceberg, dripstone cluster, sculk patch, nether & ocean feature.
// Deterministic per origin chunk; RNG call order mirrors baseline exactly (including
// short-circuit evaluation), so features crossing chunk borders generate
// identically from every side — and identically to the golden baselines.

import Foundation

public enum BEValue: Equatable {
    case num(Double)
    case str(String)
    case bool(Bool)
}

public struct BESpec {
    public let x: Int, y: Int, z: Int
    public let kind: String
    public let data: [String: BEValue]
    public init(x: Int, y: Int, z: Int, kind: String, data: [String: BEValue] = [:]) {
        self.x = x; self.y = y; self.z = z; self.kind = kind; self.data = data
    }
}

public struct EntitySpec {
    public let mob: String
    public let x: Double, y: Double, z: Double
    public let data: [String: BEValue]
    public init(mob: String, x: Double, y: Double, z: Double, data: [String: BEValue] = [:]) {
        self.mob = mob; self.x = x; self.y = y; self.z = z; self.data = data
    }
}

public protocol ChunkSink: AnyObject {
    var cx: Int { get }
    var cz: Int { get }
    var minY: Int { get }
    var maxY: Int { get }
    /// clipped write, world coords
    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16)
    /// read; outside chunk returns -1
    func get(_ x: Int, _ y: Int, _ z: Int) -> Int
    /// top solid y within chunk; outside chunk uses noise estimate
    func topY(_ x: Int, _ z: Int) -> Int
    func addBlockEntity(_ spec: BESpec)
    func addEntity(_ spec: EntitySpec)
}

private let AIR = 0
private var WATER_CELL: Int { Int(cell(B.water)) }

// negative cells (= outside chunk, -1) classify as nothing — mirrors deterministic `>>> 4`
// turning -1 into a huge index whose table lookups are undefined/falsy
private func isSoil(_ c: Int) -> Bool {
    if c < 0 { return false }
    let id = UInt16(c >> 4)
    return id == B.grass_block || id == B.dirt || id == B.coarse_dirt || id == B.podzol ||
        id == B.mycelium || id == B.rooted_dirt || id == B.moss_block || id == B.mud || id == B.farmland
}
private func isSand(_ c: Int) -> Bool {
    if c < 0 { return false }
    let id = UInt16(c >> 4)
    return id == B.sand || id == B.red_sand
}
private func isStoneLike(_ c: Int) -> Bool {
    if c < 0 { return false }
    let id = UInt16(c >> 4)
    return id == B.stone || id == B.deepslate || id == B.andesite || id == B.diorite ||
        id == B.granite || id == B.tuff || id == B.gravel || id == B.dirt
}
@inline(__always) private func idOf(_ c: Int) -> UInt16 { UInt16(truncatingIfNeeded: c >> 4) }
@inline(__always) private func solidId(_ id: UInt16) -> Bool { SOLID[Int(id)] == 1 }
@inline(__always) private func opaqueId(_ id: UInt16) -> Bool { OPAQUE[Int(id)] == 1 }

// ---------------------------------------------------------------------------
// Trees
// ---------------------------------------------------------------------------
private func leafBlob(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int, _ leaves: UInt16, _ rx: Double, _ ry: Int) {
    for dy in -ry...ry {
        let r = rx - Double(abs(dy)) * (rx / Double(ry + 1)) * 0.7
        let cr = Int(r.rounded(.up))
        if cr < 0 { continue }
        for dz in -cr...cr {
            for dx in -cr...cr {
                let d = Double(dx * dx + dz * dz)
                if d > r * r + 0.2 { continue }
                if abs(dx) == cr && abs(dz) == cr && rng.nextFloat() < 0.5 { continue }
                let c = s.get(x + dx, y + dy, z + dz)
                if c == 0 || c == -1 { s.set(x + dx, y + dy, z + dz, leaves) }
            }
        }
    }
}

public func genOakTree(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int, fancy: Bool = false, beeChance: Double = 0) {
    let h = fancy ? 6 + rng.nextInt(5) : 4 + rng.nextInt(3)
    let log = cell(B.oak_log), leaves = cell(B.oak_leaves, 4)
    for i in 0..<h { s.set(x, y + i, z, log) }
    leafBlob(s, &rng, x, y + h - 1, z, leaves, 2.5, 2)
    s.set(x, y + h, z, leaves)
    if fancy {
        // a few branches
        let branches = 2 + rng.nextInt(3)
        for _ in 0..<branches {
            let by = y + 3 + rng.nextInt(h - 4)
            let dx = rng.nextInt(3) - 1, dz = rng.nextInt(3) - 1
            if dx == 0 && dz == 0 { continue }
            s.set(x + dx, by, z + dz, log)
            leafBlob(s, &rng, x + dx * 2, by + 1, z + dz * 2, leaves, 2, 1)
        }
    }
    s.set(x, y - 1, z, cell(B.dirt))
    if beeChance > 0 && rng.nextFloat() < beeChance {
        let bx = x + (rng.nextBoolean() ? 1 : -1)
        if s.get(bx, y + 1, z) <= 0 {
            s.set(bx, y + 1, z, cell(B.bee_nest, 1))
            s.addBlockEntity(BESpec(x: bx, y: y + 1, z: z, kind: "beehive", data: ["bees": .num(3)]))
        }
    }
}

public func genBirchTree(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int, tall: Bool = false) {
    let h = (tall ? 7 : 5) + rng.nextInt(3)
    let log = cell(B.birch_log), leaves = cell(B.birch_leaves, 4)
    for i in 0..<h { s.set(x, y + i, z, log) }
    leafBlob(s, &rng, x, y + h - 1, z, leaves, 2.3, 2)
    s.set(x, y + h, z, leaves)
    s.set(x, y - 1, z, cell(B.dirt))
}

public func genSpruceTree(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int) {
    let h = 6 + rng.nextInt(4)
    let log = cell(B.spruce_log), leaves = cell(B.spruce_leaves, 4)
    for i in 0..<h { s.set(x, y + i, z, log) }
    var r = 1
    var dy = h
    while dy >= 2 {
        let rr = dy == h ? 0 : r
        if rr >= 0 {
            for dz in -rr...rr {
                for dx in -rr...rr {
                    if abs(dx) == rr && abs(dz) == rr && rr > 1 { continue }
                    if dx == 0 && dz == 0 && dy < h { continue }
                    let c = s.get(x + dx, y + dy, z + dz)
                    if c == 0 || c == -1 { s.set(x + dx, y + dy, z + dz, leaves) }
                }
            }
        }
        r = r >= (dy % 2 == 0 ? 2 : 3) ? 1 : r + 1
        if Double(dy) < Double(h) * 0.4 { r = min(r, 2) }
        dy -= 1
    }
    s.set(x, y + h, z, leaves)
    s.set(x, y - 1, z, cell(B.dirt))
}

public func genMegaSpruce(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int, pine: Bool) {
    let h = 18 + rng.nextInt(10)
    let log = cell(B.spruce_log), leaves = cell(B.spruce_leaves, 4)
    for i in 0..<h {
        s.set(x, y + i, z, log); s.set(x + 1, y + i, z, log)
        s.set(x, y + i, z + 1, log); s.set(x + 1, y + i, z + 1, log)
    }
    let leafStart = pine ? h - 5 : Int((Double(h) * 0.35).rounded(.down))
    var r = pine ? 2 : 1
    var dy = h + 1
    while dy >= leafStart {
        let rr = dy > h ? 1 : r
        for dz in -rr...(rr + 1) {
            for dx in -rr...(rr + 1) {
                let ex = dx > 0 ? dx - 1 : dx, ez = dz > 0 ? dz - 1 : dz
                if ex * ex + ez * ez > rr * rr + 1 { continue }
                let c = s.get(x + dx, y + dy, z + dz)
                if c == 0 || c == -1 { s.set(x + dx, y + dy, z + dz, leaves) }
            }
        }
        if !pine { r = r > 3 ? 1 : r + 1 }
        else { r = min(4, r + (dy % 2)) }
        dy -= 1
    }
    for dx in -1...2 {
        for dz in -1...2 {
            if rng.nextFloat() < 0.5 { s.set(x + dx, y - 1, z + dz, cell(B.podzol)) }
        }
    }
}

public func genJungleTree(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int, mega: Bool) {
    let log = cell(B.jungle_log), leaves = cell(B.jungle_leaves, 4)
    if mega {
        let h = 20 + rng.nextInt(12)
        for i in 0..<h {
            s.set(x, y + i, z, log); s.set(x + 1, y + i, z, log)
            s.set(x, y + i, z + 1, log); s.set(x + 1, y + i, z + 1, log)
            // vines on trunk
            if rng.nextFloat() < 0.3 { s.set(x - 1, y + i, z, cell(B.vine, 8)) }
            if rng.nextFloat() < 0.3 { s.set(x + 2, y + i, z, cell(B.vine, 4)) }
        }
        leafBlob(s, &rng, x, y + h, z, leaves, 4, 2)
        leafBlob(s, &rng, x + 1, y + h - 4 - rng.nextInt(4), z + 1, leaves, 3, 1)
    } else {
        let h = 5 + rng.nextInt(6)
        for i in 0..<h { s.set(x, y + i, z, log) }
        leafBlob(s, &rng, x, y + h, z, leaves, 2.5, 1)
        // cocoa
        if rng.nextFloat() < 0.3 {
            let f = rng.nextInt(4)
            let dx = [0, 0, -1, 1][f], dz = [-1, 1, 0, 0][f]
            let cy = y + h - 2 - rng.nextInt(2)
            if s.get(x + dx, cy, z + dz) <= 0 {
                s.set(x + dx, cy, z + dz, cell(B.cocoa, ([1, 0, 3, 2][f] | (rng.nextInt(3) << 2))))
            }
        }
    }
    s.set(x, y - 1, z, cell(B.dirt))
}

public func genAcaciaTree(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int) {
    let log = cell(B.acacia_log), leaves = cell(B.acacia_leaves, 4)
    let h = 4 + rng.nextInt(3)
    var px = x, pz = z
    let dx = rng.nextInt(3) - 1, dz = rng.nextInt(3) - 1
    for i in 0..<h {
        s.set(px, y + i, pz, log)
        if i >= h - 2 { px += dx; pz += dz }
    }
    // flat canopy
    for lz in -2...2 {
        for lx in -2...2 {
            if abs(lx) == 2 && abs(lz) == 2 { continue }
            let c = s.get(px + lx, y + h, pz + lz)
            if c == 0 || c == -1 { s.set(px + lx, y + h, pz + lz, leaves) }
            if abs(lx) <= 1 && abs(lz) <= 1 && abs(lx) + abs(lz) <= 1 {
                let c2 = s.get(px + lx, y + h + 1, pz + lz)
                if c2 == 0 || c2 == -1 { s.set(px + lx, y + h + 1, pz + lz, leaves) }
            }
        }
    }
    s.set(x, y - 1, z, cell(B.dirt))
}

public func genDarkOakTree(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int) {
    let log = cell(B.dark_oak_log), leaves = cell(B.dark_oak_leaves, 4)
    let h = 6 + rng.nextInt(3)
    for i in 0..<h {
        s.set(x, y + i, z, log); s.set(x + 1, y + i, z, log)
        s.set(x, y + i, z + 1, log); s.set(x + 1, y + i, z + 1, log)
    }
    for dy in 0...2 {
        let r: Double = dy == 2 ? 2 : 3.5
        let cr = Int(r.rounded(.up))
        for dz in -cr...(cr + 1) {
            for dx in -cr...(cr + 1) {
                let ex = dx > 0 ? dx - 1 : dx, ez = dz > 0 ? dz - 1 : dz
                if Double(ex * ex + ez * ez) > r * r { continue }
                let c = s.get(x + dx, y + h - 1 + dy, z + dz)
                if c == 0 || c == -1 { s.set(x + dx, y + h - 1 + dy, z + dz, leaves) }
            }
        }
    }
    for dx in 0...1 { for dz in 0...1 { s.set(x + dx, y - 1, z + dz, cell(B.dirt)) } }
}

public func genCherryTree(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int) {
    let log = cell(B.cherry_log), leaves = cell(B.cherry_leaves, 4)
    let h = 4 + rng.nextInt(3)
    for i in 0..<h { s.set(x, y + i, z, log) }
    // two arched branches
    let branches = 2 + rng.nextInt(2)
    for _ in 0..<branches {
        let ang = rng.nextFloat() * Double.pi * 2
        let len = 2 + rng.nextInt(2)
        var bx = x, bz = z, by = y + h - 1
        for i in 0..<len {
            bx += Int(detRound(detCos(ang)))
            bz += Int(detRound(detSin(ang)))
            by += i == 0 ? 1 : (rng.nextFloat() < 0.5 ? 1 : 0)
            s.set(bx, by, bz, log)
        }
        leafBlob(s, &rng, bx, by + 1, bz, leaves, 2.8, 1)
        leafBlob(s, &rng, bx, by + 2, bz, leaves, 1.6, 0)
    }
    s.set(x, y - 1, z, cell(B.dirt))
}

public func genMangroveTree(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int) {
    let log = cell(B.mangrove_log), leaves = cell(B.mangrove_leaves, 4), roots = cell(B.mangrove_roots)
    let stiltH = 2 + rng.nextInt(2)
    let waterC = WATER_CELL
    // stilt roots
    for (dx, dz) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
        for i in 0...stiltH {
            let c = s.get(x + dx, y + i - 1, z + dz)
            if c == 0 || c == waterC || c == -1 { s.set(x + dx, y + i - 1, z + dz, roots) }
            if i == 0 {
                // anchor down into ground/water
                for dd in 1...2 {
                    let cc = s.get(x + dx, y - 1 - dd, z + dz)
                    if cc == 0 || cc == waterC { s.set(x + dx, y - 1 - dd, z + dz, roots) }
                    else { break }
                }
            }
        }
    }
    let h = stiltH + 4 + rng.nextInt(3)
    for i in (stiltH - 1)..<h { s.set(x, y + i, z, log) }
    leafBlob(s, &rng, x, y + h, z, leaves, 2.8, 1)
    leafBlob(s, &rng, x, y + h + 1, z, leaves, 1.8, 0)
    // hanging propagules
    for _ in 0..<3 {
        let px = x + rng.nextInt(5) - 2, pz = z + rng.nextInt(5) - 2
        let py = y + h - rng.nextInt(2)
        if s.get(px, py, pz) == Int(cell(B.mangrove_leaves, 4)) && s.get(px, py - 1, pz) <= 0 {
            s.set(px, py - 1, pz, cell(B.mangrove_propagule, 8 | 4))
        }
    }
}

public func genSwampOak(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int) {
    let h = 5 + rng.nextInt(3)
    let log = cell(B.oak_log), leaves = cell(B.oak_leaves, 4)
    for i in 0..<h { s.set(x, y + i, z, log) }
    leafBlob(s, &rng, x, y + h - 1, z, leaves, 3, 2)
    // vines hanging off leaves
    for _ in 0..<8 {
        let vx = x + rng.nextInt(7) - 3, vz = z + rng.nextInt(7) - 3
        let vy = y + h - 1 - rng.nextInt(2)
        if idOf(s.get(vx, vy, vz)) == B.oak_leaves && s.get(vx, vy - 1, vz) <= 0 {
            let len = 1 + rng.nextInt(3)
            for v in 1...len {
                if s.get(vx, vy - v, vz) <= 0 { s.set(vx, vy - v, vz, cell(B.vine, (1 << rng.nextInt(4)))) }
            }
        }
    }
    s.set(x, y - 1, z, cell(B.dirt))
}

public func genAzaleaTree(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int) {
    let h = 4 + rng.nextInt(2)
    let log = cell(B.oak_log)
    for i in 0..<h { s.set(x, y + i, z, log) }
    leafBlob(s, &rng, x, y + h - 1, z, cell(B.azalea_leaves, 4), 2.4, 1)
    for _ in 0..<4 {
        let lx = x + rng.nextInt(5) - 2, lz = z + rng.nextInt(5) - 2
        if idOf(s.get(lx, y + h, lz)) == B.azalea_leaves && rng.nextFloat() < 0.5 {
            s.set(lx, y + h, lz, cell(B.flowering_azalea_leaves, 4))
        }
    }
    s.set(x, y - 1, z, cell(B.rooted_dirt))
}

public func genHugeMushroom(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int, red: Bool) {
    let stem = cell(B.mushroom_stem)
    let capBlock = red ? cell(B.red_mushroom_block) : cell(B.brown_mushroom_block)
    let h = 4 + rng.nextInt(3)
    for i in 0..<h { s.set(x, y + i, z, stem) }
    if red {
        for dy in 0..<2 {
            let r = dy == 1 ? 1 : 2
            for dz in -r...r {
                for dx in -r...r {
                    if dy == 0 && abs(dx) == r && abs(dz) == r { continue }
                    if dy == 0 && abs(dx) < r && abs(dz) < r { continue }
                    s.set(x + dx, y + h - 1 + dy, z + dz, capBlock)
                }
            }
        }
        s.set(x, y + h, z, capBlock)
    } else {
        for dz in -3...3 {
            for dx in -3...3 {
                if abs(dx) == 3 && abs(dz) == 3 { continue }
                s.set(x + dx, y + h, z + dz, capBlock)
            }
        }
    }
}

public func genHugeFungus(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int, crimson: Bool) {
    let stem = cell(crimson ? B.crimson_stem : B.warped_stem)
    let wart = cell(crimson ? B.nether_wart_block : B.warped_wart_block)
    let light = cell(B.shroomlight)
    let h = 5 + rng.nextInt(7)
    for i in 0..<h { s.set(x, y + i, z, stem) }
    for dy in -2...1 {
        let r = dy >= 0 ? (dy == 1 ? 1 : 2) : 3
        let rr = dy == -2 ? 3 : dy == -1 ? 3 : r
        for dz in -rr...rr {
            for dx in -rr...rr {
                if dx * dx + dz * dz > rr * rr + 1 { continue }
                let c = s.get(x + dx, y + h + dy, z + dz)
                if c == 0 || c == -1 {
                    s.set(x + dx, y + h + dy, z + dz, rng.nextFloat() < 0.06 ? light : wart)
                }
            }
        }
    }
}

public func genChorus(_ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int) {
    let plant = cell(B.chorus_plant)
    func grow(_ px: Int, _ py: Int, _ pz: Int, _ depth: Int) {
        s.set(px, py, pz, plant)
        let h = 1 + rng.nextInt(3)
        for i in 1...h { s.set(px, py + i, pz, plant) }
        if depth < 3 && rng.nextFloat() < 0.8 {
            let branches = 1 + rng.nextInt(3)
            for _ in 0..<branches {
                let f = rng.nextInt(4)
                let nx = px + [0, 0, -1, 1][f], nz = pz + [-1, 1, 0, 0][f]
                if s.get(nx, py + h, nz) <= 0 { grow(nx, py + h, nz, depth + 1) }
            }
        } else {
            s.set(px, py + h + 1, pz, cell(B.chorus_flower, 0))
        }
    }
    grow(x, y, z, 0)
}

// ---------------------------------------------------------------------------
// Feature dispatch
// ---------------------------------------------------------------------------
private let FLOWER_SETS: [String: [UInt16]] = [
    "plains": [B.dandelion, B.poppy, B.azure_bluet, B.oxeye_daisy, B.cornflower],
    "forest": [B.dandelion, B.poppy, B.lily_of_the_valley],
    "flower_forest": [B.dandelion, B.poppy, B.allium, B.azure_bluet, B.red_tulip, B.orange_tulip,
                      B.white_tulip, B.pink_tulip, B.oxeye_daisy, B.cornflower, B.lily_of_the_valley,
                      B.peony, B.lilac, B.rose_bush],
    "meadow": [B.dandelion, B.poppy, B.allium, B.azure_bluet, B.oxeye_daisy, B.cornflower],
    "jungle": [B.dandelion, B.poppy],
    "cherry": [B.pink_tulip, B.allium],
    "swamp": [B.blue_orchid],
]

public func runFeature(_ key: String, _ s: ChunkSink, _ rng: inout RandomX, _ ocx: Int, _ ocz: Int, _ seed: UInt32, _ biomeAt: (Int, Int) -> Int) {
    let parts = key.split(separator: ":").map(String.init)
    let name = parts[0]
    let baseX = ocx * 16, baseZ = ocz * 16
    func intArg(_ i: Int, _ def: Int = 0) -> Int { parts.count > i ? (Int(parts[i]) ?? def) : def }
    func randPos(_ rng: inout RandomX) -> (Int, Int) {
        let x = baseX + rng.nextInt(16)
        let z = baseZ + rng.nextInt(16)
        return (x, z)
    }

    switch name {
    case "trees":
        let kind = parts[1]
        let count = intArg(2)
        let extra = parts.count > 3 ? (Double(parts[3]) ?? 0.1) : 0.1
        var n = count
        if rng.nextFloat() < extra { n += 1 }
        if count == 0 && n == 0 && rng.nextFloat() < extra * 2 { n = 1 }
        for _ in 0..<n {
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            if y <= s.minY || y > 250 { continue }
            let ground = s.get(x, y - 1, z)
            if ground != -1 && !isSoil(ground) { continue }
            if ground == -1 {
                // base lies outside this sink: the soil can't be read, so be
                // conservative — at/below sea level it's water or beach, and a
                // blind paint here is exactly the floating-canopy fragment bug
                if y <= SEA + 1 { continue }
                let biome = biomeAt(x, z)
                if biome == Biome.river.rawValue || biome == Biome.beach.rawValue
                    || biome == Biome.snowyBeach.rawValue || biome == Biome.stonyShore.rawValue { continue }
            }
            placeTreeKind(kind, s, &rng, x, y, z)
        }

    case "patch":
        let blockName = parts[1]
        let count = intArg(2)
        guard let id = bidOpt(blockName) else { return }
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            let ground = s.get(x, y - 1, z)
            if ground == -1 || (!isSoil(ground) && !(blockName == "dead_bush" && (isSand(ground) || idOf(ground) == B.terracotta))) { continue }
            if s.get(x, y, z) != 0 { continue }
            if blockName == "tall_grass" || blockName == "large_fern" || blockName == "sunflower" {
                s.set(x, y, z, cell(id, 0))
                s.set(x, y + 1, z, cell(id, 1))
            } else {
                s.set(x, y, z, cell(id))
            }
        }

    case "flowers":
        let set = FLOWER_SETS[parts[1]] ?? FLOWER_SETS["plains"]!
        let count = intArg(2)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            let ground = s.get(x, y - 1, z)
            if ground == -1 || !isSoil(ground) || s.get(x, y, z) != 0 { continue }
            // flower gradient: same flower in local area (seeded — a fixed
            // salt made every world grow the identical flower map)
            let fl = set[Int(hash2(seed, x >> 3, z >> 3, 7)) % set.count]
            if fl == B.peony || fl == B.lilac || fl == B.rose_bush {
                s.set(x, y, z, cell(fl, 0))
                s.set(x, y + 1, z, cell(fl, 1))
            } else {
                s.set(x, y, z, cell(fl))
            }
        }

    case "sugar_cane":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            let ground = s.get(x, y - 1, z)
            if ground == -1 || (!isSoil(ground) && !isSand(ground)) { continue }
            // needs adjacent water
            var nearWater = false
            for (dx, dz) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                if idOf(s.get(x + dx, y - 1, z + dz)) == B.water { nearWater = true; break }
            }
            if !nearWater || s.get(x, y, z) != 0 { continue }
            let h = 2 + rng.nextInt(3)
            for j in 0..<h { s.set(x, y + j, z, cell(B.sugar_cane)) }
        }

    case "cactus":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            if !isSand(s.get(x, y - 1, z)) { continue }
            var clear = true
            for (dx, dz) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let c = s.get(x + dx, y, z + dz)
                if c > 0 && solidId(idOf(c)) { clear = false; break }
            }
            if !clear || s.get(x, y, z) != 0 { continue }
            let h = 1 + rng.nextInt(3)
            for j in 0..<h { s.set(x, y + j, z, cell(B.cactus)) }
        }

    case "pumpkin", "melon":
        let rarity = intArg(1)
        if rng.nextInt(rarity) != 0 { return }
        let (x, z) = randPos(&rng)
        let y = s.topY(x, z)
        if !isSoil(s.get(x, y - 1, z)) || s.get(x, y, z) != 0 { return }
        s.set(x, y, z, cell(name == "pumpkin" ? B.pumpkin : B.melon))

    case "lily_pad":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            for y in 62...64 {
                if idOf(s.get(x, y, z)) == B.water && s.get(x, y + 1, z) == 0 {
                    s.set(x, y + 1, z, cell(B.lily_pad))
                    break
                }
            }
        }

    case "vines":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = 64 + rng.nextInt(50)
            for f in 0..<4 {
                let dx = [0, 0, -1, 1][f], dz = [-1, 1, 0, 0][f]
                let wall = s.get(x + dx, y, z + dz)
                if wall > 0 && opaqueId(idOf(wall)) && s.get(x, y, z) == 0 {
                    let len = 1 + rng.nextInt(4)
                    for v in 0..<len {
                        if s.get(x, y - v, z) == 0 { s.set(x, y - v, z, cell(B.vine, (1 << f))) }
                    }
                    break
                }
            }
        }

    case "berry_bush":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            if isSoil(s.get(x, y - 1, z)) && s.get(x, y, z) == 0 {
                s.set(x, y, z, cell(B.sweet_berry_bush, (2 + rng.nextInt(2))))
            }
        }

    case "bamboo":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            if !isSoil(s.get(x, y - 1, z)) { continue }
            let h = 6 + rng.nextInt(10)
            for j in 0..<h {
                if s.get(x, y + j, z) != 0 && s.get(x, y + j, z) != -1 { break }
                let leavesMeta = j > h - 3 ? 2 : j > h - 5 ? 1 : 0
                s.set(x, y + j, z, cell(B.bamboo, (leavesMeta | 4)))
            }
        }

    case "bee_nest", "cocoa", "badlands_gold", "emerald_ore":
        return

    case "huge_mushroom":
        let count = intArg(1)
        for _ in 0..<count {
            if rng.nextFloat() < 0.6 { continue }
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            let g = s.get(x, y - 1, z)
            if g == -1 || (!isSoil(g) && idOf(g) != B.mycelium) { continue }
            let red = rng.nextBoolean()
            genHugeMushroom(s, &rng, x, y, z, red: red)
        }

    case "huge_fungus":
        let crimson = parts[1] == "crimson"
        let count = intArg(2)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = netherFloorY(s, x, z, &rng)
            if y < 0 { continue }
            let g = idOf(s.get(x, y - 1, z))
            if g != (crimson ? B.crimson_nylium : B.warped_nylium) { continue }
            if rng.nextFloat() < 0.4 { genHugeFungus(s, &rng, x, y, z, crimson: crimson) }
        }

    case "nether_vegetation":
        let crimson = parts[1] == "crimson"
        let count = intArg(2)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = netherFloorY(s, x, z, &rng)
            if y < 0 { continue }
            let g = idOf(s.get(x, y - 1, z))
            if g != B.crimson_nylium && g != B.warped_nylium { continue }
            let r = rng.nextFloat()
            if crimson {
                s.set(x, y, z, cell(r < 0.7 ? B.crimson_roots : r < 0.9 ? B.crimson_fungus : B.warped_fungus))
            } else {
                s.set(x, y, z, cell(r < 0.55 ? B.warped_roots : r < 0.8 ? B.nether_sprouts : B.warped_fungus))
            }
        }

    case "weeping_vines":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = 40 + rng.nextInt(70)
            let ceil = s.get(x, y + 1, z)
            if ceil > 0 && opaqueId(idOf(ceil)) && s.get(x, y, z) == 0 {
                let len = 2 + rng.nextInt(6)
                for v in 0..<len {
                    if s.get(x, y - v, z) == 0 { s.set(x, y - v, z, cell(B.weeping_vines)) }
                    else { break }
                }
            }
        }

    case "twisting_vines":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = netherFloorY(s, x, z, &rng)
            if y < 0 || s.get(x, y, z) != 0 { continue }
            let len = 2 + rng.nextInt(5)
            for v in 0..<len {
                if s.get(x, y + v, z) == 0 { s.set(x, y + v, z, cell(B.twisting_vines)) }
                else { break }
            }
        }

    case "glowstone_cluster":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = 30 + rng.nextInt(80)
            let ceil = s.get(x, y + 1, z)
            if ceil > 0 && idOf(ceil) == B.netherrack && s.get(x, y, z) == 0 {
                s.set(x, y, z, cell(B.glowstone))
                for _ in 0..<6 {
                    let gx = x + rng.nextInt(3) - 1, gy = y - rng.nextInt(2), gz = z + rng.nextInt(3) - 1
                    if s.get(gx, gy, gz) == 0 && rng.nextFloat() < 0.7 { s.set(gx, gy, gz, cell(B.glowstone)) }
                }
            }
        }

    case "lava_spring":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = s.minY + 6 + rng.nextInt(100)
            let c = s.get(x, y, z)
            if c > 0 && opaqueId(idOf(c)) {
                var airSides = 0
                for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1)] {
                    if s.get(x + dx, y + dy, z + dz) == 0 { airSides += 1 }
                }
                if airSides == 1 { s.set(x, y, z, cell(B.lava, 0)) }
            }
        }

    case "fire_patch", "fire_patch_soul":
        let count = intArg(1)
        let soul = name == "fire_patch_soul"
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = netherFloorY(s, x, z, &rng)
            if y < 0 { continue }
            let g = idOf(s.get(x, y - 1, z))
            if soul ? (g == B.soul_sand || g == B.soul_soil) : g == B.netherrack {
                s.set(x, y, z, cell(soul ? B.soul_fire : B.fire))
            }
        }

    case "magma_blob":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = 24 + rng.nextInt(16)
            for _ in 0..<8 {
                let bx = x + rng.nextInt(3) - 1, by = y + rng.nextInt(2) - 1, bz = z + rng.nextInt(3) - 1
                let c = s.get(bx, by, bz)
                if c > 0 && (idOf(c) == B.netherrack || idOf(c) == B.basalt) { s.set(bx, by, bz, cell(B.magma_block)) }
            }
        }

    case "basalt_pillar", "basalt_column":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = netherFloorY(s, x, z, &rng)
            if y < 0 { continue }
            let h = name == "basalt_pillar" ? 4 + rng.nextInt(8) : 1 + rng.nextInt(4)
            for j in 0..<h { s.set(x, y + j, z, cell(B.basalt)) }
        }

    case "bone_spire":
        let count = intArg(1)
        for _ in 0..<count {
            if rng.nextFloat() < 0.7 { continue }
            let (x, z) = randPos(&rng)
            let y = netherFloorY(s, x, z, &rng)
            if y < 0 { continue }
            let h = 3 + rng.nextInt(5)
            for j in 0..<h { s.set(x, y + j, z, cell(B.bone_block)) }
        }

    case "delta":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = netherFloorY(s, x, z, &rng)
            if y < 0 { continue }
            let r = 2 + rng.nextInt(4)
            for dz in -r...r {
                for dx in -r...r {
                    if dx * dx + dz * dz > r * r { continue }
                    let g = s.get(x + dx, y - 1, z + dz)
                    if g > 0 && opaqueId(idOf(g)) && s.get(x + dx, y, z + dz) == 0 {
                        s.set(x + dx, y - 1, z + dz, rng.nextFloat() < 0.85 ? cell(B.lava, 0) : cell(B.magma_block))
                    }
                }
            }
        }

    case "brown_mushroom_nether", "red_mushroom_nether":
        let count = intArg(1)
        let id = name.hasPrefix("brown") ? B.brown_mushroom : B.red_mushroom
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = netherFloorY(s, x, z, &rng)
            if y > 0 && s.get(x, y, z) == 0 { s.set(x, y, z, cell(id)) }
        }

    // --- ocean ---
    case "patch_water":
        let blockName = parts[1]
        let count = intArg(2)
        let id = bid(blockName)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = seafloorY(s, x, z)
            if y < 0 { continue }
            if idOf(s.get(x, y, z)) == B.water {
                if blockName == "seagrass" && rng.nextFloat() < 0.3 && idOf(s.get(x, y + 1, z)) == B.water {
                    s.set(x, y, z, cell(B.tall_seagrass, 0))
                    s.set(x, y + 1, z, cell(B.tall_seagrass, 1))
                } else {
                    s.set(x, y, z, cell(id))
                }
            }
        }

    case "kelp":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = seafloorY(s, x, z)
            if y < 0 { continue }
            let maxH = 62 - y
            if maxH < 3 { continue }
            let h = 3 + rng.nextInt(min(14, maxH))
            for j in 0..<h {
                if idOf(s.get(x, y + j, z)) != B.water { break }
                s.set(x, y + j, z, j == h - 1 ? cell(B.kelp, (rng.nextInt(16))) : cell(B.kelp_plant))
            }
        }

    case "sea_pickle":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = seafloorY(s, x, z)
            if y < 0 { continue }
            let g = s.get(x, y - 1, z)
            if g > 0 && solidId(idOf(g)) { s.set(x, y, z, cell(B.sea_pickle, (rng.nextInt(4)))) }
        }

    case "coral_reef":
        let count = intArg(1)
        let corals = ["tube", "brain", "bubble", "fire", "horn"]
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = seafloorY(s, x, z)
            if y < 0 || y > 56 { continue }
            let coral = corals[rng.nextInt(5)]
            let blockC = cell(bid("\(coral)_coral_block"))
            let kind = rng.nextInt(3)
            if kind == 0 {
                // claw/tree
                let h = 2 + rng.nextInt(3)
                for j in 0..<h { s.set(x, y + j, z, blockC) }
                for _ in 0..<3 {
                    let f = rng.nextInt(4)
                    let bx = x + [0, 0, -1, 1][f], bz = z + [-1, 1, 0, 0][f]
                    s.set(bx, y + h - 1, bz, blockC)
                    if rng.nextBoolean() { s.set(bx, y + h, bz, blockC) }
                }
            } else if kind == 1 {
                // mushroom
                for dz in -1...1 {
                    for dx in -1...1 {
                        s.set(x + dx, y + 1, z + dz, blockC)
                        if rng.nextFloat() < 0.6 { s.set(x + dx, y + 2, z + dz, blockC) }
                    }
                }
                s.set(x, y, z, blockC)
            } else {
                s.set(x, y, z, blockC)
                s.set(x, y + 1, z, blockC)
            }
            // decorate with corals + fans
            for _ in 0..<6 {
                let dx2 = rng.nextInt(5) - 2, dz2 = rng.nextInt(5) - 2
                let ty = seafloorY(s, x + dx2, z + dz2)
                if ty > 0 && idOf(s.get(x + dx2, ty, z + dz2)) == B.water {
                    let c2 = corals[rng.nextInt(5)]
                    let pick = rng.nextBoolean()
                    s.set(x + dx2, ty, z + dz2, cell(bid(pick ? "\(c2)_coral" : "\(c2)_coral_fan")))
                }
            }
        }

    case "iceberg":
        let count = intArg(1)
        for _ in 0..<count {
            if rng.nextFloat() < 0.94 { continue }
            let (x, z) = randPos(&rng)
            let r = 4 + rng.nextInt(6)
            let peak = 4 + rng.nextInt(8)
            let blue = rng.nextFloat() < 0.2
            for dy in -r...peak {
                let rr = dy < 0 ? Double(r) * (1 + Double(dy) / Double(r + 1) * 0.5) : Double(r) * (1 - Double(dy) / Double(peak + 1))
                let cr = Int(rr.rounded(.up))
                if cr < 0 { continue }
                for dz in -cr...cr {
                    for dx in -cr...cr {
                        if Double(dx * dx + dz * dz) > rr * rr { continue }
                        let y = 63 + dy
                        let c = s.get(x + dx, y, z + dz)
                        if c == WATER_CELL || c == 0 || c == -1 {
                            s.set(x + dx, y, z + dz, blue ? cell(B.blue_ice) : (rng.nextFloat() < 0.1 ? cell(B.snow_block) : cell(B.packed_ice)))
                        }
                    }
                }
            }
        }

    case "ice_spike":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            if idOf(s.get(x, y - 1, z)) != B.snow_block { continue }
            let tall = rng.nextFloat() < 0.1
            let h = tall ? 12 + rng.nextInt(20) : 6 + rng.nextInt(6)
            let r = tall ? 2 : 1 + rng.nextInt(2)
            for dy in 0..<h {
                let rr = max(0, Double(r) * (1 - Double(dy) / Double(h)))
                let cr = Int(rr.rounded(.up))
                for dz in -cr...cr {
                    for dx in -cr...cr {
                        if Double(dx * dx + dz * dz) > rr * rr + 0.3 { continue }
                        s.set(x + dx, y + dy, z + dz, cell(B.packed_ice))
                    }
                }
            }
        }

    case "ice_patch", "powder_snow":
        let count = intArg(1)
        let blk = name == "ice_patch" ? cell(B.packed_ice) : cell(B.powder_snow)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            let r = 2 + rng.nextInt(3)
            for dz in -r...r {
                for dx in -r...r {
                    if dx * dx + dz * dz > r * r { continue }
                    let ty = s.topY(x + dx, z + dz)
                    if abs(ty - y) <= 1 && idOf(s.get(x + dx, ty - 1, z + dz)) == B.snow_block {
                        s.set(x + dx, ty - 1, z + dz, blk)
                    }
                }
            }
        }

    case "mossy_boulder":
        let count = intArg(1)
        for _ in 0..<count {
            if rng.nextFloat() < 0.7 { continue }
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            let r = 1 + rng.nextInt(2)
            for dy in -1...r {
                for dz in -r...r {
                    for dx in -r...r {
                        if dx * dx + dy * dy + dz * dz > r * r + 1 { continue }
                        s.set(x + dx, y + dy, z + dz, cell(B.mossy_cobblestone))
                    }
                }
            }
        }

    case "hoodoo":
        let count = intArg(1)
        for _ in 0..<count {
            if rng.nextFloat() < 0.5 { continue }
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            let h = 6 + rng.nextInt(14)
            let bands: [UInt16] = [B.terracotta, B.orange_terracotta, B.red_terracotta, B.white_terracotta, B.yellow_terracotta]
            for dy in 0..<h {
                let r = dy > h - 3 ? 0 : 1
                for dz in -r...r {
                    for dx in -r...r {
                        s.set(x + dx, y + dy, z + dz, cell(bands[(y + dy) % bands.count]))
                    }
                }
            }
        }

    case "desert_well":
        if rng.nextInt(500) != 0 { return }
        let (x, z) = randPos(&rng)
        let y = s.topY(x, z)
        if !isSand(s.get(x, y - 1, z)) { return }
        let ss = cell(B.sandstone), slab = cell(B.sandstone_slab)
        for dz in -2...2 {
            for dx in -2...2 {
                s.set(x + dx, y - 1, z + dz, dx == 0 && dz == 0 ? cell(B.water, 0) : ss)
                if abs(dx) == 2 || abs(dz) == 2 { s.set(x + dx, y, z + dz, slab) }
            }
        }
        // suspicious sand for archaeology
        s.set(x + 1, y - 2, z, cell(B.suspicious_sand))
        s.addBlockEntity(BESpec(x: x + 1, y: y - 2, z: z, kind: "brushable", data: ["lootTable": .str("desert_well_archaeology")]))
        for (px, pz) in [(-1, -1), (1, 1)] {
            s.set(x + px, y, z + pz, ss)
            s.set(x + px, y + 1, z + pz, ss)
            s.set(x + px, y + 2, z + pz, ss)
        }
        for dz in -1...1 { for dx in -1...1 { s.set(x + dx, y + 3, z + dz, slab) } }

    // --- caves ---
    case "dripstone_cluster", "pointed_dripstone", "dripstone_pool",
         "moss_patch", "lush_vegetation", "glow_berries", "spore_blossom",
         "azalea_tree", "big_dripleaf", "small_dripleaf", "clay_pool",
         "sculk_patch", "sculk_vein", "sculk_shrieker", "sculk_sensor":
        caveFeature(name, intArg(1), s, &rng, ocx, ocz, biomeAt)

    case "chorus":
        let count = intArg(1)
        for _ in 0..<count {
            if rng.nextFloat() < 0.7 { continue }
            let (x, z) = randPos(&rng)
            let y = s.topY(x, z)
            if idOf(s.get(x, y - 1, z)) == B.end_stone && s.get(x, y, z) == 0 {
                genChorus(s, &rng, x, y, z)
            }
        }

    case "clay_disk":
        let count = intArg(1)
        for _ in 0..<count {
            let (x, z) = randPos(&rng)
            let y = seafloorY(s, x, z)
            if y < 0 { continue }
            let r = 2 + rng.nextInt(3)
            for dz in -r...r {
                for dx in -r...r {
                    if dx * dx + dz * dz > r * r { continue }
                    let g = s.get(x + dx, y - 1, z + dz)
                    if g > 0 && (idOf(g) == B.sand || idOf(g) == B.dirt || idOf(g) == B.gravel) {
                        s.set(x + dx, y - 1, z + dz, cell(B.clay))
                    }
                }
            }
        }

    default:
        return
    }
}

func placeTreeKind(_ kind: String, _ s: ChunkSink, _ rng: inout RandomX, _ x: Int, _ y: Int, _ z: Int) {
    switch kind {
    case "oak_sparse", "oak_small": genOakTree(s, &rng, x, y, z, fancy: false)
    case "oak_bee": genOakTree(s, &rng, x, y, z, fancy: false, beeChance: 0.3)
    case "oak_birch":
        if rng.nextFloat() < 0.2 { genBirchTree(s, &rng, x, y, z) }
        else {
            let fancy = rng.nextFloat() < 0.1
            genOakTree(s, &rng, x, y, z, fancy: fancy, beeChance: 0.01)
        }
    case "oak_spruce":
        if rng.nextBoolean() { genSpruceTree(s, &rng, x, y, z) }
        else { genOakTree(s, &rng, x, y, z, fancy: false) }
    case "birch": genBirchTree(s, &rng, x, y, z)
    case "tall_birch": genBirchTree(s, &rng, x, y, z, tall: true)
    case "spruce": genSpruceTree(s, &rng, x, y, z)
    case "mega_spruce":
        if rng.nextFloat() < 0.33 { genMegaSpruce(s, &rng, x, y, z, pine: false) }
        else { genSpruceTree(s, &rng, x, y, z) }
    case "mega_pine":
        if rng.nextFloat() < 0.33 { genMegaSpruce(s, &rng, x, y, z, pine: true) }
        else { genSpruceTree(s, &rng, x, y, z) }
    case "jungle":
        if rng.nextFloat() < 0.1 { genJungleTree(s, &rng, x, y, z, mega: true) }
        else if rng.nextFloat() < 0.15 { genOakTree(s, &rng, x, y, z, fancy: false) }
        else { genJungleTree(s, &rng, x, y, z, mega: false) }
    case "jungle_sparse": genJungleTree(s, &rng, x, y, z, mega: false)
    case "acacia": genAcaciaTree(s, &rng, x, y, z)
    case "dark_oak": genDarkOakTree(s, &rng, x, y, z)
    case "cherry": genCherryTree(s, &rng, x, y, z)
    case "mangrove": genMangroveTree(s, &rng, x, y, z)
    case "swamp_oak": genSwampOak(s, &rng, x, y, z)
    default: break
    }
}

func netherFloorY(_ s: ChunkSink, _ x: Int, _ z: Int, _ rng: inout RandomX) -> Int {
    // random air column probe between 32..100
    let start = 32 + rng.nextInt(68)
    var y = start
    while y > 6 {
        let c = s.get(x, y, z)
        let below = s.get(x, y - 1, z)
        if c == 0 && below > 0 && solidId(idOf(below)) { return y }
        y -= 1
    }
    return -1
}

func seafloorY(_ s: ChunkSink, _ x: Int, _ z: Int) -> Int {
    var y = 62
    while y > 8 {
        let c = s.get(x, y, z)
        if c == -1 { return -1 }
        if idOf(c) == B.water {
            let below = s.get(x, y - 1, z)
            if below > 0 && solidId(idOf(below)) { return y }
        } else if c != 0 {
            return -1
        }
        y -= 1
    }
    return -1
}

// cave features operate within the target chunk only
private func caveFeature(_ name: String, _ count: Int, _ s: ChunkSink, _ rng: inout RandomX, _ ocx: Int, _ ocz: Int, _ biomeAt: (Int, Int) -> Int) {
    let baseX = ocx * 16, baseZ = ocz * 16
    for _ in 0..<count {
        let x = baseX + rng.nextInt(16), z = baseZ + rng.nextInt(16)
        let yTop = min(58, s.topY(x, z) - 8)
        if yTop <= s.minY + 6 { continue }
        let y = s.minY + 6 + rng.nextInt(max(1, yTop - s.minY - 6))
        let c = s.get(x, y, z)
        if c != 0 { continue }
        // find floor & ceiling of this air pocket
        var floor = -10000, ceil = 10000
        for d in 1..<12 {
            if floor == -10000 {
                let b = s.get(x, y - d, z)
                if b > 0 && solidId(idOf(b)) { floor = y - d + 1 }
                else if b == -1 { break }
            }
            if ceil == 10000 {
                let b = s.get(x, y + d, z)
                if b > 0 && solidId(idOf(b)) { ceil = y + d - 1 }
            }
            if floor != -10000 && ceil != 10000 { break }
        }
        switch name {
        case "dripstone_cluster":
            if floor == -10000 { break }
            for _ in 0..<6 {
                let dx = rng.nextInt(5) - 2, dz = rng.nextInt(5) - 2
                let g = s.get(x + dx, floor - 1, z + dz)
                if g > 0 && isStoneLike(g) {
                    s.set(x + dx, floor - 1, z + dz, cell(B.dripstone_block))
                    if rng.nextFloat() < 0.6 && s.get(x + dx, floor, z + dz) == 0 {
                        let h = 1 + rng.nextInt(3)
                        for k in 0..<h {
                            let thickness = k == h - 1 ? 0 : (k == h - 2 ? 1 : 3)
                            if s.get(x + dx, floor + k, z + dz) == 0 {
                                s.set(x + dx, floor + k, z + dz, cell(B.pointed_dripstone, (thickness << 1)))
                            }
                        }
                    }
                }
            }

        case "pointed_dripstone":
            let up = rng.nextBoolean()
            if up && floor != -10000 {
                let g = s.get(x, floor - 1, z)
                if g > 0 && isStoneLike(g) && s.get(x, floor, z) == 0 {
                    s.set(x, floor, z, cell(B.pointed_dripstone, 0))
                }
            } else if ceil != 10000 {
                let g = s.get(x, ceil + 1, z)
                if g > 0 && isStoneLike(g) && s.get(x, ceil, z) == 0 {
                    let len = 1 + rng.nextInt(3)
                    for k in 0..<len {
                        let thickness = k == len - 1 ? 0 : (k == len - 2 ? 1 : 3)
                        if s.get(x, ceil - k, z) == 0 {
                            s.set(x, ceil - k, z, cell(B.pointed_dripstone, (1 | (thickness << 1))))
                        }
                    }
                }
            }

        case "dripstone_pool":
            if floor == -10000 { break }
            let g = s.get(x, floor - 1, z)
            if g > 0 && isStoneLike(g) { s.set(x, floor - 1, z, cell(B.water, 0)) }

        case "moss_patch":
            if floor == -10000 || (biomeAt(x, z) != Biome.lushCaves.rawValue && rng.nextFloat() < 0.5) { break }
            let r = 2 + rng.nextInt(3)
            for dz in -r...r {
                for dx in -r...r {
                    if dx * dx + dz * dz > r * r { continue }
                    let g = s.get(x + dx, floor - 1, z + dz)
                    if g > 0 && isStoneLike(g) {
                        s.set(x + dx, floor - 1, z + dz, cell(B.moss_block))
                        let above = s.get(x + dx, floor, z + dz)
                        if above == 0 && rng.nextFloat() < 0.5 {
                            let r2 = rng.nextFloat()
                            s.set(x + dx, floor, z + dz, r2 < 0.5 ? cell(B.short_grass) : r2 < 0.7 ? cell(B.moss_carpet) : r2 < 0.9 ? cell(B.tall_grass, 0) : cell(B.azalea))
                        }
                    }
                }
            }

        case "lush_vegetation":
            if floor == -10000 { break }
            let g = s.get(x, floor - 1, z)
            if g > 0 && (idOf(g) == B.moss_block || isSoil(g)) && s.get(x, floor, z) == 0 {
                let r = rng.nextFloat()
                s.set(x, floor, z, r < 0.6 ? cell(B.short_grass) : r < 0.8 ? cell(B.moss_carpet) : cell(B.flowering_azalea))
            }

        case "glow_berries":
            if ceil == 10000 { break }
            let g = s.get(x, ceil + 1, z)
            if g > 0 && opaqueId(idOf(g)) && s.get(x, ceil, z) == 0 {
                let len = 2 + rng.nextInt(5)
                for k in 0..<len {
                    if s.get(x, ceil - k, z) != 0 { break }
                    let lit = rng.nextFloat() < 0.3 ? 8 : 0
                    s.set(x, ceil - k, z, k == len - 1 ? cell(B.cave_vines, lit) : cell(B.cave_vines_plant, lit))
                }
            }

        case "spore_blossom":
            if ceil == 10000 { break }
            let g = s.get(x, ceil + 1, z)
            if g > 0 && (idOf(g) == B.moss_block || opaqueId(idOf(g))) && s.get(x, ceil, z) == 0 {
                s.set(x, ceil, z, cell(B.spore_blossom))
            }

        case "azalea_tree":
            if floor == -10000 || rng.nextFloat() < 0.8 { break }
            let g = s.get(x, floor - 1, z)
            if g > 0 && (idOf(g) == B.moss_block || isSoil(g)) { genAzaleaTree(s, &rng, x, floor, z) }

        case "big_dripleaf":
            if floor == -10000 { break }
            let g = s.get(x, floor - 1, z)
            if g > 0 && (idOf(g) == B.moss_block || idOf(g) == B.clay || isSoil(g)) && s.get(x, floor, z) == 0 {
                let h = 1 + rng.nextInt(3)
                let facing = rng.nextInt(4)
                for k in 0..<(h - 1) { s.set(x, floor + k, z, cell(B.big_dripleaf_stem, (facing))) }
                s.set(x, floor + h - 1, z, cell(B.big_dripleaf, (facing)))
            }

        case "small_dripleaf":
            if floor == -10000 { break }
            let g = s.get(x, floor - 1, z)
            if g > 0 && (idOf(g) == B.moss_block || idOf(g) == B.clay) && s.get(x, floor, z) == 0 {
                let facing = rng.nextInt(4)
                s.set(x, floor, z, cell(B.small_dripleaf, (facing << 1)))
                s.set(x, floor + 1, z, cell(B.small_dripleaf, (1 | (facing << 1))))
            }

        case "clay_pool":
            if floor == -10000 { break }
            let r = 1 + rng.nextInt(2)
            for dz in -r...r {
                for dx in -r...r {
                    let g = s.get(x + dx, floor - 1, z + dz)
                    if g > 0 && isStoneLike(g) {
                        s.set(x + dx, floor - 1, z + dz, dx == 0 && dz == 0 ? cell(B.water, 0) : cell(B.clay))
                    }
                }
            }

        case "sculk_patch":
            if floor == -10000 || biomeAt(x, z) != Biome.deepDark.rawValue { break }
            let r = 2 + rng.nextInt(4)
            for dz in -r...r {
                for dx in -r...r {
                    if dx * dx + dz * dz > r * r { continue }
                    let g = s.get(x + dx, floor - 1, z + dz)
                    if g > 0 && isStoneLike(g) { s.set(x + dx, floor - 1, z + dz, cell(B.sculk)) }
                }
            }

        case "sculk_vein":
            if floor == -10000 || biomeAt(x, z) != Biome.deepDark.rawValue { break }
            let g = s.get(x, floor - 1, z)
            if g > 0 && s.get(x, floor, z) == 0 { s.set(x, floor, z, cell(B.sculk_vein, 0)) }

        case "sculk_shrieker":
            if floor == -10000 || biomeAt(x, z) != Biome.deepDark.rawValue || rng.nextFloat() < 0.7 { break }
            if idOf(s.get(x, floor - 1, z)) == B.sculk && s.get(x, floor, z) == 0 {
                s.set(x, floor, z, cell(B.sculk_shrieker))
                s.addBlockEntity(BESpec(x: x, y: floor, z: z, kind: "shrieker", data: ["canSummon": .bool(true)]))
            }

        case "sculk_sensor":
            if floor == -10000 || biomeAt(x, z) != Biome.deepDark.rawValue || rng.nextFloat() < 0.5 { break }
            if idOf(s.get(x, floor - 1, z)) == B.sculk && s.get(x, floor, z) == 0 {
                s.set(x, floor, z, cell(B.sculk_sensor))
            }

        default:
            break
        }
    }
}

// ---------------------------------------------------------------------------
// Geodes (cross-chunk capable, rare)
// ---------------------------------------------------------------------------
public func tryGeode(_ seed: UInt32, _ ocx: Int, _ ocz: Int, _ s: ChunkSink) {
    var rng = chunkRandom(seed, ocx, ocz, 0xCE0DE)
    if rng.nextFloat() > 1.0 / 26 { return }
    let x = ocx * 16 + rng.nextInt(16)
    let z = ocz * 16 + rng.nextInt(16)
    let y = -52 + rng.nextInt(76)
    let r = 4 + rng.nextInt(3)
    for dy in (-r - 1)...(r + 1) {
        for dz in (-r - 1)...(r + 1) {
            for dx in (-r - 1)...(r + 1) {
                let d = Double(dx * dx + dy * dy + dz * dz).squareRoot() + Double(hash2(seed, x + dx + dy, z + dz, 5) % 100) / 220
                if d > Double(r) + 1.2 { continue }
                let wx = x + dx, wy = y + dy, wz = z + dz
                if d > Double(r) + 0.3 {
                    let c = s.get(wx, wy, wz)
                    if c > 0 { s.set(wx, wy, wz, cell(B.smooth_basalt)) }
                } else if d > Double(r) - 0.9 {
                    s.set(wx, wy, wz, cell(B.calcite))
                } else if d > Double(r) - 1.9 {
                    s.set(wx, wy, wz, rng.nextFloat() < 0.08 ? cell(B.budding_amethyst) : cell(B.amethyst_block))
                } else {
                    s.set(wx, wy, wz, 0)
                }
            }
        }
    }
    // clusters inside
    for _ in 0..<8 {
        let dx = rng.nextInt(r * 2 - 2) - (r - 1), dy = rng.nextInt(r * 2 - 2) - (r - 1), dz = rng.nextInt(r * 2 - 2) - (r - 1)
        let wx = x + dx, wy = y + dy, wz = z + dz
        if s.get(wx, wy, wz) == 0 {
            // attach to a neighboring amethyst wall
            for f in 0..<6 {
                let nx = wx + [0, 0, 0, 0, -1, 1][f], ny = wy + [-1, 1, 0, 0, 0, 0][f], nz = wz + [0, 0, -1, 1, 0, 0][f]
                let nb = idOf(s.get(nx, ny, nz))
                if nb == B.amethyst_block || nb == B.budding_amethyst {
                    s.set(wx, wy, wz, cell(B.amethyst_cluster, (f ^ 1)))
                    break
                }
            }
        }
    }
}
