// Nether terrain (the frozen baseline) and The End (the frozen baseline).

import Foundation

public let NETHER_H = 128
private let LAVA_SEA = 32
private let AIR = 0

public final class NetherGen {
    public let seed: UInt32
    let density: FBM
    let temp: FBM
    let humid: FBM
    let surf: FBM

    public init(_ seed: UInt32) {
        self.seed = seed
        density = FBM(seed &+ 7001, 4, 1 / 90, lacunarity: 2.1, persistence: 0.55)
        temp = FBM(seed &+ 7002, 3, 1 / 320, lacunarity: 2, persistence: 0.5)
        humid = FBM(seed &+ 7003, 3, 1 / 320, lacunarity: 2, persistence: 0.5)
        surf = FBM(seed &+ 7004, 2, 1 / 40, lacunarity: 2, persistence: 0.5)
    }

    public func biomeAt(_ x: Double, _ z: Double) -> Int {
        let t = temp.sample2(x, z) * 1.5
        let h = humid.sample2(x, z) * 1.5
        if h < -0.42 { return Biome.basaltDeltas.rawValue }
        if h > 0.42 { return Biome.soulSandValley.rawValue }
        if t > 0.3 { return Biome.crimsonForest.rawValue }
        if t < -0.3 { return Biome.warpedForest.rawValue }
        return Biome.netherWastes.rawValue
    }

    /// floor height estimate for structures
    public func heightEstimate(_ x: Double, _ z: Double) -> Int {
        for y in 40..<90 {
            if densityAt(x, y, z) <= 0 && densityAt(x, y - 1, z) > 0 { return y }
        }
        return 40
    }
    private func densityAt(_ x: Double, _ y: Int, _ z: Double) -> Double {
        var d = density.sample3(x, Double(y) * 1.5, z) * 1.15
        d += clampD(Double(38 - y) / 30, 0, 1) * 1.1           // solid toward floor
        d += clampD(Double(y - 96) / 26, 0, 1) * 1.6           // solid toward ceiling
        d -= clampD(Double(y - 60) / 50, 0, 0.25)              // bias open mid
        return d
    }

    public func fillTerrain(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16], _ biomes: inout [UInt8]) -> [UInt8] {
        let baseX = cx * 16, baseZ = cz * 16
        let NETHERRACK = cell(B.netherrack)
        let LAVA = cell(B.lava)
        let BEDROCK = cell(B.bedrock)
        var surfaceBiomes = [UInt8](repeating: 0, count: 256)
        // density on 5×33×5 lattice, cells 4×4×4
        let NX = 5, NY = NETHER_H / 4 + 1, NZ = 5
        var lattice = [Float](repeating: 0, count: NX * NY * NZ)
        for gz in 0..<NZ {
            for gx in 0..<NX {
                for gy in 0..<NY {
                    lattice[(gy * NZ + gz) * NX + gx] = Float(densityAt(Double(baseX + gx * 4), gy * 4, Double(baseZ + gz * 4)))
                }
            }
        }
        for z in 0..<16 {
            for x in 0..<16 {
                surfaceBiomes[z * 16 + x] = UInt8(biomeAt(Double(baseX + x), Double(baseZ + z)))
                let gx = x >> 2, gz = z >> 2
                let fx = Double(x & 3) / 4, fz = Double(z & 3) / 4
                for gy in 0..<(NY - 1) {
                    let d000 = Double(lattice[(gy * NZ + gz) * NX + gx]), d100 = Double(lattice[(gy * NZ + gz) * NX + gx + 1])
                    let d010 = Double(lattice[(gy * NZ + gz + 1) * NX + gx]), d110 = Double(lattice[(gy * NZ + gz + 1) * NX + gx + 1])
                    let d001 = Double(lattice[((gy + 1) * NZ + gz) * NX + gx]), d101 = Double(lattice[((gy + 1) * NZ + gz) * NX + gx + 1])
                    let d011 = Double(lattice[((gy + 1) * NZ + gz + 1) * NX + gx]), d111 = Double(lattice[((gy + 1) * NZ + gz + 1) * NX + gx + 1])
                    let b0 = lerpD(lerpD(d000, d100, fx), lerpD(d010, d110, fx), fz)
                    let b1 = lerpD(lerpD(d001, d101, fx), lerpD(d011, d111, fx), fz)
                    for sy in 0..<4 {
                        let y = gy * 4 + sy
                        if y >= NETHER_H { break }
                        let d = b0 + (b1 - b0) * (Double(sy) / 4)
                        let idx = (y * 16 + z) * 16 + x
                        if d > 0 { blocks[idx] = NETHERRACK }
                        else if y <= LAVA_SEA { blocks[idx] = LAVA }
                        else { blocks[idx] = UInt16(AIR) }
                    }
                }
                // bedrock floor + ceiling
                let br = hash2(seed, baseX + x, baseZ + z, 31)
                for d in 0..<5 {
                    if d == 0 || (((br >> UInt32(d)) & 3) != 0 && d < 1 + Int(br & 3)) {
                        blocks[(d * 16 + z) * 16 + x] = BEDROCK
                    }
                    let cy = NETHER_H - 1 - d
                    if d == 0 || (((br >> UInt32(d + 8)) & 3) != 0 && d < 1 + Int((br >> 4) & 3)) {
                        blocks[(cy * 16 + z) * 16 + x] = BEDROCK
                    }
                }
                blocks[(0 * 16 + z) * 16 + x] = BEDROCK
                blocks[((NETHER_H - 1) * 16 + z) * 16 + x] = BEDROCK
            }
        }
        // biome grid
        for qz in 0..<4 {
            for qx in 0..<4 {
                let bm = surfaceBiomes[(qz * 4 + 2) * 16 + qx * 4 + 2]
                for qy in 0..<(NETHER_H / 4) {
                    biomes[(qy * 4 + qz) * 4 + qx] = bm
                }
            }
        }
        return surfaceBiomes
    }

    public func applySurface(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16], _ surfaceBiomes: [UInt8]) {
        let NETHERRACK = cell(B.netherrack)
        let LAVAC = cell(B.lava)
        for z in 0..<16 {
            for x in 0..<16 {
                let def = biomeDef(Int(surfaceBiomes[z * 16 + x]))
                let bm = Int(surfaceBiomes[z * 16 + x])
                let sn = surf.sample2(Double(cx * 16 + x), Double(cz * 16 + z))
                let depth = bm == Biome.soulSandValley.rawValue || bm == Biome.basaltDeltas.rawValue
                    ? 2 + Int(((sn + 1) * 1.5).rounded(.down)) : 1
                var below = 0
                var y = NETHER_H - 2
                while y > 1 {
                    let idx = (y * 16 + z) * 16 + x
                    let c = blocks[idx]
                    if c == UInt16(AIR) || c == LAVAC { below = 0; y -= 1; continue }
                    if c != NETHERRACK { below += 1; y -= 1; continue }
                    if below == 0 {
                        blocks[idx] = def.top
                        var d = 1
                        while d < depth {
                            let idx2 = ((y - d) * 16 + z) * 16 + x
                            if blocks[idx2] == NETHERRACK { blocks[idx2] = def.under }
                            d += 1
                        }
                    }
                    below += 1
                    y -= 1
                }
            }
        }
    }

    public func placeOres(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16]) {
        var rng = chunkRandom(seed, cx, cz, 777)
        let NETHERRACK = cell(B.netherrack)
        func blob(_ ore: UInt16, _ x: Int, _ y: Int, _ z: Int, _ size: Int) {
            var px = x, py = y, pz = z
            for _ in 0..<size {
                px += rng.nextInt(3) - 1; py += rng.nextInt(3) - 1; pz += rng.nextInt(3) - 1
                if px < 0 || px > 15 || pz < 0 || pz > 15 || py < 2 || py > NETHER_H - 3 { continue }
                let idx = (py * 16 + pz) * 16 + px
                if blocks[idx] == NETHERRACK { blocks[idx] = ore }
            }
        }
        for _ in 0..<16 { blob(cell(B.nether_quartz_ore), rng.nextInt(16), 10 + rng.nextInt(108), rng.nextInt(16), 10) }
        for _ in 0..<10 { blob(cell(B.nether_gold_ore), rng.nextInt(16), 10 + rng.nextInt(108), rng.nextInt(16), 8) }
        for _ in 0..<4 { blob(cell(B.magma_block), rng.nextInt(16), 27 + rng.nextInt(10), rng.nextInt(16), 18) }
        for _ in 0..<2 { blob(cell(B.blackstone), rng.nextInt(16), 5 + rng.nextInt(28), rng.nextInt(16), 24) }
        for _ in 0..<2 { blob(cell(B.soul_sand), rng.nextInt(16), 30 + rng.nextInt(35), rng.nextInt(16), 14) }
        for _ in 0..<2 { blob(cell(B.gravel), rng.nextInt(16), 30 + rng.nextInt(35), rng.nextInt(16), 14) }
        // ancient debris — buried checks
        func debris(_ y: Int, _ size: Int) {
            let x = rng.nextInt(16), z = rng.nextInt(16)
            var px = x, py = y, pz = z
            for _ in 0..<size {
                px += rng.nextInt(3) - 1; py += rng.nextInt(3) - 1; pz += rng.nextInt(3) - 1
                if px < 0 || px > 15 || pz < 0 || pz > 15 || py < 2 || py > NETHER_H - 3 { continue }
                let idx = (py * 16 + pz) * 16 + px
                if blocks[idx] != NETHERRACK { continue }
                // require no air neighbors (vanilla "in air: 0")
                var buried = true
                for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                    let nx = px + dx, ny = py + dy, nz = pz + dz
                    if nx < 0 || nx > 15 || nz < 0 || nz > 15 { continue }
                    if blocks[(ny * 16 + nz) * 16 + nx] == UInt16(AIR) { buried = false; break }
                }
                if buried { blocks[idx] = cell(B.ancient_debris) }
            }
        }
        debris(8 + rng.nextInt(15), 3)
        if rng.nextFloat() < 0.5 { debris(8 + rng.nextInt(104), 2) }
    }
}

// =============================================================================
// THE END
// =============================================================================
public let END_H = 256

public struct PillarSpec {
    public let x: Int, z: Int
    public let height: Int
    public let radius: Int
    public let caged: Bool
}

public func endPillars(_ seed: UInt32) -> [PillarSpec] {
    var rng = RandomX(hash2(seed, 7, 7, 0xE17D))
    var heights: [Int] = []
    for i in 0..<10 { heights.append(76 + i * 3) }
    rng.shuffle(&heights)
    var out: [PillarSpec] = []
    for i in 0..<10 {
        let ang = (Double(i) / 10) * Double.pi * 2
        out.append(PillarSpec(
            x: Int(detRound(detCos(ang) * 42)),
            z: Int(detRound(detSin(ang) * 42)),
            height: heights[i],
            radius: Int(3 + Double(heights[i] - 76) / 9 * 0.34),
            caged: heights[i] <= 79
        ))
    }
    return out
}

/// 20 gateway positions on a r=96 ring (activated after dragon kills)
public func gatewayPositions() -> [(Int, Int)] {
    var out: [(Int, Int)] = []
    for i in 0..<20 {
        let ang = (Double(i) / 20) * Double.pi * 2
        out.append((Int(detRound(detCos(ang) * 96)), Int(detRound(detSin(ang) * 96))))
    }
    return out
}

public final class EndGen {
    public let seed: UInt32
    let islandNoise: FBM
    let detail: FBM

    public init(_ seed: UInt32) {
        self.seed = seed
        islandNoise = FBM(seed &+ 9001, 3, 1 / 180, lacunarity: 2, persistence: 0.55)
        detail = FBM(seed &+ 9002, 3, 1 / 36, lacunarity: 2, persistence: 0.5)
    }

    /// island "presence" 0..1 at a column
    public func islandFactor(_ x: Double, _ z: Double) -> Double {
        let dist = (x * x + z * z).squareRoot()
        if dist < 120 {
            return clampD(1 - dist / 115, 0, 1) * 3 + 0.4 // main island plateau
        }
        if dist < 850 { return 0 } // the void gap
        let n = islandNoise.sample2(x, z)
        return clampD((n - 0.26) * 4.5, 0, 1.2)
    }

    public func heightEstimate(_ x: Double, _ z: Double) -> Int {
        let f = islandFactor(x, z)
        if f <= 0 { return 0 }
        return 60
    }

    public func biomeColumn(_ x: Double, _ z: Double) -> Int {
        let dist = (x * x + z * z).squareRoot()
        if dist < 130 { return Biome.theEnd.rawValue }
        if dist < 850 { return Biome.smallEndIslands.rawValue }
        let f = islandFactor(x, z)
        if f > 0.7 { return Biome.endHighlands.rawValue }
        if f > 0.2 { return Biome.endMidlands.rawValue }
        return Biome.endBarrens.rawValue
    }

    public func fillTerrain(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16], _ biomes: inout [UInt8]) -> [UInt8] {
        let baseX = cx * 16, baseZ = cz * 16
        let ENDSTONE = cell(B.end_stone)
        var surfaceBiomes = [UInt8](repeating: 0, count: 256)
        for z in 0..<16 {
            for x in 0..<16 {
                let wx = baseX + x, wz = baseZ + z
                surfaceBiomes[z * 16 + x] = UInt8(biomeColumn(Double(wx), Double(wz)))
                let f = islandFactor(Double(wx), Double(wz))
                if f <= 0.02 {
                    // tiny floating islands in the gap, rare
                    let h = Double(hash2(seed, wx >> 4, wz >> 4, 0x51A)) / 4294967296
                    if h < 0.03 {
                        let ox = (wx & 15) - 8, oz = (wz & 15) - 8
                        if ox * ox + oz * oz < 12 {
                            for y in 58...60 { blocks[(y * 16 + z) * 16 + x] = ENDSTONE }
                        }
                    }
                    continue
                }
                let surfBump = detail.sample2(Double(wx), Double(wz)) * 4
                let top = min(Double(END_H - 40), 58 + f * 4 + surfBump)
                let thickness = 8 + f * 26
                let bottom = max(2, top - thickness - detail.sample2(Double(wx) + 999, Double(wz) - 999) * 10)
                var y = Int(bottom.rounded(.down))
                let yTop = Int(top.rounded(.down))
                while y <= yTop {
                    blocks[(y * 16 + z) * 16 + x] = ENDSTONE
                    y += 1
                }
            }
        }
        for qz in 0..<4 {
            for qx in 0..<4 {
                let bm = surfaceBiomes[(qz * 4 + 2) * 16 + qx * 4 + 2]
                for qy in 0..<(END_H / 4) { biomes[(qy * 4 + qz) * 4 + qx] = bm }
            }
        }
        return surfaceBiomes
    }

    /// central island fixtures: pillars + exit portal base
    public func placeFixtures(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16],
                              _ addEntity: (String, Double, Double, Double, [String: BEValue]) -> Void) {
        let baseX = cx * 16, baseZ = cz * 16
        func inChunk(_ x: Int, _ z: Int) -> Bool { x >= baseX && x < baseX + 16 && z >= baseZ && z < baseZ + 16 }
        func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
            if !inChunk(x, z) || y < 0 || y >= END_H { return }
            blocks[(y * 16 + (z - baseZ)) * 16 + (x - baseX)] = c
        }
        let OBS = cell(B.obsidian), BEDROCK = cell(B.bedrock), BARS = cell(B.iron_bars)

        // pillars
        for p in endPillars(seed) {
            if p.x + p.radius < baseX - 1 || p.x - p.radius > baseX + 16 || p.z + p.radius < baseZ - 1 || p.z - p.radius > baseZ + 16 { continue }
            for y in 40...p.height {
                for dz in -p.radius...p.radius {
                    for dx in -p.radius...p.radius {
                        if Double(dx * dx + dz * dz) <= Double(p.radius * p.radius) + 0.5 { set(p.x + dx, y, p.z + dz, OBS) }
                    }
                }
            }
            set(p.x, p.height + 1, p.z, BEDROCK)
            if p.caged {
                for dy in 0...3 {
                    for dz in -2...2 {
                        for dx in -2...2 {
                            let edge = abs(dx) == 2 || abs(dz) == 2
                            if dy == 3 || edge {
                                if !(dx == 0 && dz == 0 && dy < 3) {
                                    set(p.x + dx, p.height + 1 + dy, p.z + dz, dy == 3 ? BARS : (edge ? BARS : 0))
                                }
                            }
                        }
                    }
                }
            }
            // crystal entity on top
            if inChunk(p.x, p.z) {
                addEntity("end_crystal", Double(p.x) + 0.5, Double(p.height + 2), Double(p.z) + 0.5,
                          ["pillar": .bool(true), "caged": .bool(p.caged), "showBottom": .bool(true)])
            }
        }

        // exit portal base (inactive): bedrock fountain at 0,0
        if abs(baseX) <= 16 && abs(baseZ) <= 16 {
            let py = 62
            for dz in -3...3 {
                for dx in -3...3 {
                    let d = abs(dx) + abs(dz)
                    if d <= 4 && !(dx == 0 && dz == 0) {
                        set(dx, py, dz, BEDROCK)
                    }
                }
            }
            for dy in 1...3 { set(0, py + dy, 0, BEDROCK) }
            set(0, py + 4, 0, cell(B.torch, 0))
            // platform under fountain
            for dz in -2...2 { for dx in -2...2 { set(dx, py - 1, dz, cell(B.end_stone)) } }
        }
    }
}
