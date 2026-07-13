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

    public init(seed: UInt32, heightAt: @escaping (Int, Int) -> Int, biomeAt: @escaping (Int, Int) -> Int, dim: Int) {
        self.seed = seed
        self.heightAt = heightAt
        self.biomeAt = biomeAt
        self.dim = dim
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
    public let check: (GenCtx, Int, Int, Rng) -> Bool
    public let plan: (GenCtx, Int, Int, Rng) -> StructurePlan?

    public init(id: String, spacing: Int, separation: Int, salt: UInt32, maxRadiusChunks: Int,
                check: @escaping (GenCtx, Int, Int, Rng) -> Bool,
                plan: @escaping (GenCtx, Int, Int, Rng) -> StructurePlan?) {
        self.id = id
        self.spacing = spacing
        self.separation = separation
        self.salt = salt
        self.maxRadiusChunks = maxRadiusChunks
        self.check = check
        self.plan = plan
    }
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

private var planCache: [String: StructurePlan?] = [:]
private let planCacheLock = NSLock()

public func structureOriginFor(_ def: StructureDef, _ seed: UInt32, _ rcx: Int, _ rcz: Int) -> (Int, Int) {
    var rng = RandomX(hash2(seed, rcx, rcz, def.salt))
    let range = max(1, def.spacing - def.separation)
    return (rcx * def.spacing + rng.nextInt(range), rcz * def.spacing + rng.nextInt(range))
}

public func getPlan(_ def: StructureDef, _ ctx: GenCtx, _ ocx: Int, _ ocz: Int) -> StructurePlan? {
    let key = "\(ctx.dim):\(def.id):\(ocx):\(ocz)"
    planCacheLock.lock()
    if let cached = planCache[key] {
        planCacheLock.unlock()
        return cached
    }
    planCacheLock.unlock()
    let rng = Rng(hash2(ctx.seed, ocx, ocz, def.salt ^ 0x5757))
    var plan: StructurePlan?
    if def.check(ctx, ocx, ocz, rng) {
        plan = def.plan(ctx, ocx, ocz, Rng(hash2(ctx.seed, ocx, ocz, def.salt ^ 0x1234)))
    }
    planCacheLock.lock()
    if planCache.count > 600 {
        planCache.removeAll(keepingCapacity: true) // recompute is deterministic; policy is correctness-neutral
    }
    planCache[key] = plan
    planCacheLock.unlock()
    return plan
}

public func buildStructuresForChunk(_ ctx: GenCtx, _ cx: Int, _ cz: Int, _ sink: ChunkSink, _ dimStructures: [StructureDef]) -> [StructRef] {
    var refs: [StructRef] = []
    let chunkX0 = cx * 16, chunkZ0 = cz * 16
    for def in dimStructures {
        let r = def.maxRadiusChunks
        let rc0x = floorDiv(cx - r, def.spacing), rc1x = floorDiv(cx + r, def.spacing)
        let rc0z = floorDiv(cz - r, def.spacing), rc1z = floorDiv(cz + r, def.spacing)
        for rcz in rc0z...rc1z {
            for rcx in rc0x...rc1x {
                let (ocx, ocz) = structureOriginFor(def, ctx.seed, rcx, rcz)
                if abs(ocx - cx) > r || abs(ocz - cz) > r { continue }
                guard let plan = getPlan(def, ctx, ocx, ocz) else { continue }
                for (pi, piece) in plan.pieces.enumerated() {
                    // does the piece intersect this chunk?
                    if piece.x1 < chunkX0 || piece.x0 > chunkX0 + 15 || piece.z1 < chunkZ0 || piece.z0 > chunkZ0 + 15 { continue }
                    // rng is a pure function of (structure, piece) — NEVER the
                    // target chunk — so a piece spanning a chunk border draws the
                    // identical stream in both rebuilds (rails/decay/chests used
                    // to discontinue exactly at chunk seams)
                    let b = Builder(sink, Rng(hash2(ctx.seed, ocx &* 1_000_003 &+ pi, ocz &* 31 &- pi, def.salt ^ 0x9999)))
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
