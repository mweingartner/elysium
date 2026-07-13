// Overworld terrain — Climate sampling, spline heights,
// interpolated 3D density with cheese/spaghetti/noodle caves, worm carvers,
// ravines, aquifers, surface rules, deepslate, bedrock, ores.
//
// Bit-exactness notes vs the golden baselines:
//  - Math.round(x) in deterministic rounds half toward +inf → detRound() here
//  - the density lattice is a Float32Array in baseline → [Float] here, interpolation
//    reads back through Double(lattice[i]) to mirror the f32 truncation
//  - all seed offsets use &+ to match deterministic uint32 wrap

import Foundation

public let SEA = 63
public let GEN_MIN_Y = -64
public let WORLD_H = 384

@inline(__always) func detRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }

public final class ClimateSampler {
    let temp: FBM, humid: FBM, cont: FBM, ero: FBM, weird: FBM, rare: FBM
    let coordinateScale: Double

    public init(_ seed: UInt32, coordinateScale: Double = 1) {
        self.coordinateScale = max(0.0001, coordinateScale)
        temp = FBM(seed &+ 11, 4, 1 / 2800, lacunarity: 2, persistence: 0.55)
        humid = FBM(seed &+ 22, 4, 1 / 1600, lacunarity: 2, persistence: 0.55)
        cont = FBM(seed &+ 33, 6, 1 / 2400, lacunarity: 2, persistence: 0.55)
        ero = FBM(seed &+ 44, 4, 1 / 1100, lacunarity: 2, persistence: 0.5)
        weird = FBM(seed &+ 55, 4, 1 / 520, lacunarity: 2, persistence: 0.5)
        rare = FBM(seed &+ 66, 2, 1 / 650, lacunarity: 2, persistence: 0.5)
    }

    public func at(_ x: Double, _ z: Double) -> Climate {
        let sx = x / coordinateScale
        let sz = z / coordinateScale
        let w = clampD(weird.sample2(sx, sz) * 1.6, -1, 1)
        return Climate(
            t: clampD(temp.sample2(sx, sz) * 1.7, -1, 1),
            h: clampD(humid.sample2(sx, sz) * 1.7, -1, 1),
            c: clampD(cont.sample2(sx, sz) * 1.55 + 0.08, -1, 1),
            e: clampD(ero.sample2(sx, sz) * 1.6, -1, 1),
            w: w,
            pv: peaksValleys(w),
            rare: rare.sample2(sx, sz) * 0.5 + 0.5
        )
    }
}

let SPLINE_BASE = Spline([
    (-1.0, 34), (-0.62, 40), (-0.45, 48), (-0.25, 56), (-0.17, 62.5), (-0.1, 66),
    (0.0, 69), (0.22, 75), (0.55, 84), (1.0, 92),
])
let SPLINE_ERO_FLAT = Spline([
    (-1.0, 1.45), (-0.45, 1.0), (0.1, 0.72), (0.55, 0.45), (1.0, 0.32),
])
// amp 110 produced 170-block sheer terrace walls ("cliffs way too large");
// 82 keeps dramatic peaks at vanilla-like ±80 without the mega-cliffs
let SPLINE_PV_AMP = Spline([
    (-1.0, 82), (-0.55, 48), (-0.25, 22), (0.1, 13), (0.55, 6), (1.0, 3.5),
])
let SPLINE_3D_AMP = Spline([
    (-1.0, 24), (-0.45, 15), (0.0, 10), (0.5, 7), (1.0, 5),
])

public func baseHeight(_ cl: Climate) -> Double {
    var h = SPLINE_BASE.at(cl.c)
    if cl.c > -0.16 {
        let inlandGate = clampD(mapRange(cl.c, -0.16, -0.02, 0, 1), 0, 1)
        let flat = SPLINE_ERO_FLAT.at(cl.e)
        h = 63 + (h - 63) * flat
        let pvAmp = SPLINE_PV_AMP.at(cl.e) * inlandGate
        h += cl.pv * pvAmp
        // swamps flatten to sea level
        if cl.e > 0.55 && cl.h > 0.1 && cl.c < 0.35 && cl.t > -0.1 {
            h = lerpD(h, 62.4, clampD(mapRange(cl.e, 0.55, 0.75, 0, 1), 0, 1))
        }
        // river carve
        let riverF = clampD(mapRange(cl.pv, -0.72, -0.85, 0, 1), 0, 1)
        if riverF > 0 && cl.e > -0.4 {
            h = lerpD(h, 58.5, riverF)
        }
    }
    return h
}

public struct AquiferInfo {
    public let level: Int
    public let lava: Bool
}

public struct TerrainResult {
    public let heights: [Int16]
    public let climates: [Climate]
    public let surfaceBiomes: [UInt8]
}

@inline(__always) private func bil(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ fx: Double, _ fz: Double) -> Double {
    lerpD(lerpD(a, b, fx), lerpD(c, d, fx), fz)
}

public final class OverworldGen {
    public let seed: UInt32
    public let settings: WorldGenerationSettings
    public let climate: ClimateSampler
    let detail: FBM
    let cheese: FBM
    let spag1: FBM
    let spag2: FBM
    let noodleA: FBM
    let noodleB: FBM
    let surfNoise: FBM
    let aquiferNoise: FBM
    let caveBiomeNoise: FBM
    let dripstoneNoise: FBM
    let deepDarkNoise: FBM
    let bandOffset: SimplexNoise

    private let AIR: UInt16 = 0
    private let STONE = cell(B.stone)
    private let DEEPSLATE = cell(B.deepslate)
    private let WATER = cell(B.water)
    private let LAVA = cell(B.lava)
    private let BEDROCK = cell(B.bedrock)

    public init(_ seed: UInt32, settings: WorldGenerationSettings = .normal) {
        self.seed = seed
        self.settings = settings
        climate = ClimateSampler(seed, coordinateScale: settings.preset == .largeBiomes ? 4 : 1)
        detail = FBM(seed &+ 101, 4, 1 / 110, lacunarity: 2.2, persistence: 0.5)
        cheese = FBM(seed &+ 202, 3, 1 / 150, lacunarity: 2, persistence: 0.6)
        spag1 = FBM(seed &+ 303, 2, 1 / 92, lacunarity: 2, persistence: 0.5)
        spag2 = FBM(seed &+ 404, 2, 1 / 92, lacunarity: 2, persistence: 0.5)
        noodleA = FBM(seed &+ 505, 2, 1 / 60, lacunarity: 2, persistence: 0.5)
        noodleB = FBM(seed &+ 606, 2, 1 / 60, lacunarity: 2, persistence: 0.5)
        surfNoise = FBM(seed &+ 707, 3, 1 / 48, lacunarity: 2, persistence: 0.5)
        aquiferNoise = FBM(seed &+ 808, 2, 1 / 280, lacunarity: 2, persistence: 0.5)
        caveBiomeNoise = FBM(seed &+ 909, 3, 1 / 240, lacunarity: 2, persistence: 0.5)
        dripstoneNoise = FBM(seed &+ 1010, 3, 1 / 220, lacunarity: 2, persistence: 0.5)
        deepDarkNoise = FBM(seed &+ 1111, 2, 1 / 300, lacunarity: 2, persistence: 0.5)
        bandOffset = SimplexNoise(seed &+ 1212)
    }

    private func terrainBaseHeight(_ cl: Climate) -> Double {
        var h = baseHeight(cl)
        if settings.preset == .moderateHillsResourceRich {
            let seaDelta = h - Double(SEA)
            let inland = clampD(mapRange(cl.c, -0.18, 0.24, 0, 1), 0, 1)
            let compressed = seaDelta >= 0 ? seaDelta * 0.62 : seaDelta * 0.35
            let rolling = max(0, cl.pv) * SPLINE_PV_AMP.at(cl.e) * 0.42 * inland
            let smallVariation = cl.w * 4.0 * inland
            return clampD(Double(SEA) + compressed + rolling + smallVariation, 54, 118)
        }
        guard settings.preset == .amplified else { return h }
        let inland = clampD(mapRange(cl.c, -0.14, 0.2, 0, 1), 0, 1)
        let upward = max(0, cl.pv) * SPLINE_PV_AMP.at(cl.e) * 1.25 * inland
        let seaDelta = h - Double(SEA)
        h = Double(SEA) + seaDelta * 1.45 + upward
        if h > 300 { h = 300 + (h - 300) / 2 }
        return min(h, 340)
    }

    /// terrain height estimate from pure noise — usable anywhere without blocks
    public func heightEstimate(_ x: Double, _ z: Double) -> Int {
        Int(detRound(terrainBaseHeight(climate.at(x, z))))
    }

    /// height estimate INCLUDING the 3D detail term the density function adds —
    /// the spline-only estimate misses ±SPLINE_3D_AMP, which scattered trees and
    /// buried structures relative to the real surface. Two fixed-point passes on
    /// the same detail noise land within a couple of blocks of the actual terrain.
    public func refinedHeightEstimate(_ x: Double, _ z: Double) -> Int {
        let cl = climate.at(x, z)
        let target = terrainBaseHeight(cl)
        let ampBase = SPLINE_3D_AMP.at(cl.e) * clampD(mapRange(cl.c, -0.19, -0.05, 0.35, 1), 0.35, 1)
        let amp: Double
        if settings.preset == .amplified {
            amp = ampBase * 1.65
        } else if settings.preset == .moderateHillsResourceRich {
            amp = ampBase * 0.85
        } else {
            amp = ampBase
        }
        var y = target + detail.sample3(x, target * 1.35, z) * amp
        y = target + detail.sample3(x, y * 1.35, z) * amp
        if y > 170 { y = 170 + (y - 170) / 1.55 }   // density's high-peak rounding term
        return Int(detRound(y))
    }

    public func surfaceBiomeAt(_ x: Double, _ z: Double) -> Biome {
        if settings.preset == .singleBiomeSurface { return settings.singleBiome }
        return selectBiome(climate.at(x, z))
    }

    public func aquiferAt(_ x: Double, _ z: Double, _ cl: Climate) -> AquiferInfo {
        if cl.c < -0.11 { return AquiferInfo(level: SEA, lava: false) }
        let n = aquiferNoise.sample2(x, z)
        if n > 0.28 { return AquiferInfo(level: Int((30 + (n - 0.28) * 60).rounded(.down)), lava: false) }
        if n < -0.4 { return AquiferInfo(level: 12, lava: true) }
        return AquiferInfo(level: -1000, lava: false)
    }

    /// -1 when no cave biome applies
    public func caveBiomeAt(_ x: Double, _ y: Int, _ z: Double, _ surfaceH: Int) -> Int {
        if settings.preset == .singleBiomeSurface { return -1 }
        if y > surfaceH - 9 { return -1 }
        if y < 12 {
            let dd = deepDarkNoise.sample2(x, z)
            if dd > 0.42 && y < 0 { return Biome.deepDark.rawValue }
        }
        let lush = caveBiomeNoise.sample3(x, Double(y) * 1.5, z)
        if lush > 0.4 && y < 60 { return Biome.lushCaves.rawValue }
        let drip = dripstoneNoise.sample3(x + 1000, Double(y) * 1.5, z - 1000)
        if drip > 0.45 && y < 70 { return Biome.dripstoneCaves.rawValue }
        return -1
    }

    /// Fill terrain for a chunk. blocks indexed ((y-minY)*16+z)*16+x.
    public func fillTerrain(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16], _ biomes: inout [UInt8]) -> TerrainResult {
        let baseX = cx * CHUNK_W, baseZ = cz * CHUNK_W
        // climate per column (16×16) — sample at 4-block grid and bilerp
        var climGrid: [Climate] = []
        climGrid.reserveCapacity(25)
        for gz in 0...4 {
            for gx in 0...4 {
                climGrid.append(climate.at(Double(baseX + gx * 4), Double(baseZ + gz * 4)))
            }
        }
        var climates = [Climate](repeating: Climate(t: 0, h: 0, c: 0, e: 0, w: 0, pv: 0, rare: 0), count: 256)
        var heights = [Int16](repeating: 0, count: 256)
        var surfaceBiomes = [UInt8](repeating: 0, count: 256)
        for z in 0..<16 {
            for x in 0..<16 {
                let gx = x >> 2, gz = z >> 2
                let fx = Double(x & 3) / 4, fz = Double(z & 3) / 4
                let c00 = climGrid[gz * 5 + gx], c10 = climGrid[gz * 5 + gx + 1]
                let c01 = climGrid[(gz + 1) * 5 + gx], c11 = climGrid[(gz + 1) * 5 + gx + 1]
                var cl = Climate(
                    t: bil(c00.t, c10.t, c01.t, c11.t, fx, fz),
                    h: bil(c00.h, c10.h, c01.h, c11.h, fx, fz),
                    c: bil(c00.c, c10.c, c01.c, c11.c, fx, fz),
                    e: bil(c00.e, c10.e, c01.e, c11.e, fx, fz),
                    w: bil(c00.w, c10.w, c01.w, c11.w, fx, fz),
                    pv: 0, rare: bil(c00.rare, c10.rare, c01.rare, c11.rare, fx, fz)
                )
                cl.pv = peaksValleys(cl.w)
                climates[z * 16 + x] = cl
                heights[z * 16 + x] = Int16(detRound(terrainBaseHeight(cl)))
                let surfaceBiome: Biome = settings.preset == .singleBiomeSurface ? settings.singleBiome : selectBiome(cl)
                surfaceBiomes[z * 16 + x] = UInt8(surfaceBiome.rawValue)
            }
        }

        // density sampling on a 5 × 49 × 5 lattice (4×8×4 cells)
        let NX = 5, NY = WORLD_H / 8 + 1, NZ = 5
        var lattice = [Float](repeating: 0, count: NX * NY * NZ)
        for gz in 0..<NZ {
            for gx in 0..<NX {
                let wx = Double(baseX + gx * 4), wz = Double(baseZ + gz * 4)
                // sample climate at the lattice point's TRUE position — the old
                // min(15,…) clamp reused the x/z=15 column for the x/z=16 edge,
                // so adjacent chunks disagreed about their shared boundary
                let cl = climate.at(wx, wz)
                let target = terrainBaseHeight(cl)
                let ampBase = SPLINE_3D_AMP.at(cl.e) * clampD(mapRange(cl.c, -0.19, -0.05, 0.35, 1), 0.35, 1)
                let amp: Double
                if settings.preset == .amplified {
                    amp = ampBase * 1.65
                } else if settings.preset == .moderateHillsResourceRich {
                    amp = ampBase * 0.85
                } else {
                    amp = ampBase
                }
                for gy in 0..<NY {
                    let y = Double(GEN_MIN_Y + gy * 8)
                    var d = (target - y) + detail.sample3(wx, y * 1.35, wz) * amp
                    // round high peaks, solidify deeps
                    if y > 170 { d -= (y - 170) * 0.55 }
                    if y < -40 { d += (-40 - y) * 0.35 }
                    // cheese caves
                    if y < 58 {
                        let ch = cheese.sample3(wx * 0.9, y * 2.0, wz * 0.9)
                        let fade = clampD((58 - y) / 14, 0, 1) * clampD((y - Double(GEN_MIN_Y + 4)) / 10, 0, 1)
                        let cheeseThreshold = settings.preset == .moderateHillsResourceRich ? 0.74 : 0.42
                        let cheeseStrength = settings.preset == .moderateHillsResourceRich ? 120.0 : 260.0
                        if ch > cheeseThreshold && fade > 0 {
                            d = min(d, lerpD(d, (cheeseThreshold - ch) * cheeseStrength, fade))
                        }
                    }
                    // spaghetti caves
                    if y < 110 {
                        let s1 = spag1.sample3(wx, y * 1.6, wz)
                        let s2 = spag2.sample3(wx, y * 1.6, wz)
                        let tube = max(abs(s1), abs(s2))
                        let thresh = settings.preset == .moderateHillsResourceRich
                            ? 0.025 + clampD((y - 60) / 240, 0, 0.012)
                            : 0.065 + clampD((y - 60) / 240, 0, 0.03)
                        if tube < thresh {
                            let fade = clampD((y - Double(GEN_MIN_Y + 3)) / 8, 0, 1)
                            if fade > 0 { d = min(d, (tube - thresh) * 900 * fade) }
                        }
                    }
                    // noodle caves (thin, deep)
                    if y < 28 {
                        let n1 = noodleA.sample3(wx, y * 1.8, wz)
                        let n2 = noodleB.sample3(wx, y * 1.8, wz)
                        let tube = max(abs(n1), abs(n2))
                        let thresh = settings.preset == .moderateHillsResourceRich ? 0.014 : 0.038
                        if tube < thresh {
                            let fade = clampD((y - Double(GEN_MIN_Y + 3)) / 8, 0, 1)
                            let strength = settings.preset == .moderateHillsResourceRich ? 650.0 : 1200.0
                            if fade > 0 { d = min(d, (tube - thresh) * strength * fade) }
                        }
                    }
                    lattice[(gy * NZ + gz) * NX + gx] = Float(d)
                }
            }
        }

        // fill blocks by trilinear interpolation
        for z in 0..<16 {
            for x in 0..<16 {
                let ci = z * 16 + x
                let cl = climates[ci]
                let aq = aquiferAt(Double(baseX + x), Double(baseZ + z), cl)
                let gx = x >> 2, gz = z >> 2
                let fx = Double(x & 3) / 4, fz = Double(z & 3) / 4
                var topSolid = GEN_MIN_Y - 1
                for gy in 0..<(NY - 1) {
                    let d000 = Double(lattice[(gy * NZ + gz) * NX + gx])
                    let d100 = Double(lattice[(gy * NZ + gz) * NX + gx + 1])
                    let d010 = Double(lattice[(gy * NZ + gz + 1) * NX + gx])
                    let d110 = Double(lattice[(gy * NZ + gz + 1) * NX + gx + 1])
                    let d001 = Double(lattice[((gy + 1) * NZ + gz) * NX + gx])
                    let d101 = Double(lattice[((gy + 1) * NZ + gz) * NX + gx + 1])
                    let d011 = Double(lattice[((gy + 1) * NZ + gz + 1) * NX + gx])
                    let d111 = Double(lattice[((gy + 1) * NZ + gz + 1) * NX + gx + 1])
                    let b0 = bil(d000, d100, d010, d110, fx, fz)
                    let b1 = bil(d001, d101, d011, d111, fx, fz)
                    for sy in 0..<8 {
                        let y = GEN_MIN_Y + gy * 8 + sy
                        let d = b0 + (b1 - b0) * (Double(sy) / 8)
                        let idx = ((y - GEN_MIN_Y) * 16 + z) * 16 + x
                        if d > 0 {
                            blocks[idx] = STONE
                            topSolid = y
                        } else if y <= SEA && cl.c < -0.11 {
                            blocks[idx] = WATER
                        } else if y <= aq.level {
                            // lava aquifers are lava throughout — the old `y < 0`
                            // condition capped them with a layer of water
                            blocks[idx] = aq.lava ? LAVA : WATER
                        } else if y <= GEN_MIN_Y + 10 && y < -54 {
                            blocks[idx] = y <= -56 ? LAVA : AIR
                        } else {
                            blocks[idx] = AIR
                        }
                    }
                }
                // open-water rules, column-complete:
                // 1) every open cell at/below SEA floods — the climate-gated fill
                //    left dry pits and sheer water walls where ocean met "inland"
                //    columns whose terrain dips under sea level
                // 2) aquifer fluid the noise put in OPEN AIR above SEA is scrubbed
                //    (aquifers are subterranean; valleys got 9-deep ponds)
                if topSolid < SEA {
                    var y = max(topSolid + 1, GEN_MIN_Y)
                    while y <= SEA {
                        let idx = ((y - GEN_MIN_Y) * 16 + z) * 16 + x
                        if blocks[idx] == AIR { blocks[idx] = WATER }
                        y += 1
                    }
                }
                if aq.level > SEA && cl.c >= -0.11 && topSolid < aq.level {
                    var y = max(topSolid + 1, SEA + 1)
                    let yMax = min(aq.level, GEN_MIN_Y + WORLD_H - 1)
                    while y <= yMax {
                        let idx = ((y - GEN_MIN_Y) * 16 + z) * 16 + x
                        if blocks[idx] == WATER || blocks[idx] == LAVA { blocks[idx] = AIR }
                        y += 1
                    }
                }
            }
        }

        // biomes (quart resolution, with cave biome overrides)
        for qz in 0..<4 {
            for qx in 0..<4 {
                let ci = (qz * 4 + 2) * 16 + qx * 4 + 2
                let surfB = surfaceBiomes[ci]
                let surfH = Int(heights[ci])
                let wx = Double(baseX + qx * 4 + 2), wz = Double(baseZ + qz * 4 + 2)
                for qy in 0..<(WORLD_H / 4) {
                    let y = GEN_MIN_Y + qy * 4 + 2
                    let cb = caveBiomeAt(wx, y, wz, surfH)
                    biomes[(qy * 4 + qz) * 4 + qx] = cb == -1 ? surfB : UInt8(cb)
                }
            }
        }

        return TerrainResult(heights: heights, climates: climates, surfaceBiomes: surfaceBiomes)
    }

    /// worm carvers + ravines, deterministic per source chunk, range 4
    public func carve(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16]) {
        let RANGE = 4
        let rareCaverns = settings.preset == .moderateHillsResourceRich
        for ocz in (cz - RANGE)...(cz + RANGE) {
            for ocx in (cx - RANGE)...(cx + RANGE) {
                var rng = chunkRandom(seed, ocx, ocz, 1337)
                // worm caves: 1 in 3 chunks spawn a system
                if rng.nextFloat() < (rareCaverns ? 0.06 : 0.3) {
                    let tunnels = rareCaverns ? 1 : 1 + rng.nextInt(3)
                    for _ in 0..<tunnels {
                        var x = Double(ocx * 16 + rng.nextInt(16))
                        var y = Double(GEN_MIN_Y + 8 + rng.nextInt(100))
                        var z = Double(ocz * 16 + rng.nextInt(16))
                        var yaw = rng.nextFloat() * Double.pi * 2
                        var pitch = (rng.nextFloat() - 0.5) * 0.6
                        let length = rareCaverns ? 24 + rng.nextInt(24) : 40 + rng.nextInt(60)
                        var radius = rareCaverns ? 0.9 + rng.nextFloat() * 1.0 : 1.4 + rng.nextFloat() * 1.8
                        for i in 0..<length {
                            x += detCos(yaw) * detCos(pitch)
                            y += detSin(pitch) * 0.7
                            z += detSin(yaw) * detCos(pitch)
                            yaw += (rng.nextFloat() - 0.5) * 0.5
                            pitch = clampD(pitch + (rng.nextFloat() - 0.5) * 0.3, -0.9, 0.9)
                            let r = radius * (1 + detSin(Double(i) / Double(length) * Double.pi) * 0.8)
                            if rng.nextFloat() < (rareCaverns ? 0.006 : 0.02) {
                                radius = rareCaverns ? 0.8 + rng.nextFloat() * 1.1 : 1.2 + rng.nextFloat() * 2.2
                            }
                            carveSphere(cx, cz, &blocks, x, y, z, r)
                            // occasional branching
                            if i > 10 && rng.nextFloat() < (rareCaverns ? 0.004 : 0.02) && tunnels < 4 {
                                yaw += (rng.nextBoolean() ? 1 : -1) * (0.8 + rng.nextFloat())
                            }
                        }
                    }
                }
                // ravines: rare
                if rng.nextFloat() < (rareCaverns ? 0.003 : 0.02) {
                    var x = Double(ocx * 16 + rng.nextInt(16))
                    var z = Double(ocz * 16 + rng.nextInt(16))
                    let y = 20 + rng.nextInt(40)
                    var yaw = rng.nextFloat() * Double.pi * 2
                    let length = rareCaverns ? 32 + rng.nextInt(35) : 60 + rng.nextInt(50)
                    let depth = rareCaverns ? 14 + rng.nextInt(22) : 24 + rng.nextInt(36)
                    let width = rareCaverns ? 1.4 + rng.nextFloat() * 1.4 : 2.2 + rng.nextFloat() * 2.4
                    for i in 0..<length {
                        x += detCos(yaw)
                        z += detSin(yaw)
                        yaw += (rng.nextFloat() - 0.5) * 0.18
                        let w = width * (1 + detSin(Double(i) / Double(length) * Double.pi) * 0.6)
                        for dy in 0..<depth {
                            let yy = y - dy
                            let taper = 1 - (Double(dy) / Double(depth)) * 0.55
                            carveSphereFlat(cx, cz, &blocks, x, Double(yy), z, w * taper, 1.4)
                        }
                    }
                }
            }
        }
    }

    private func carveSphere(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16], _ x: Double, _ y: Double, _ z: Double, _ r: Double) {
        carveSphereFlat(cx, cz, &blocks, x, y, z, r, 0.72)
    }

    /// is this carved cell under a water body (open water above within the
    /// column, no solid roof in between)? decides water-fill vs air carve
    @inline(__always)
    private func columnHasWaterAbove(_ blocks: [UInt16], _ idx: Int, _ lx: Int, _ y: Int, _ lz: Int) -> Bool {
        var yy = y + 1
        while yy <= SEA {
            let i = ((yy - GEN_MIN_Y) * 16 + lz) * 16 + lx
            let c = blocks[i]
            if c == WATER { return true }
            if c != AIR && c != LAVA { return false }   // solid roof → dry cave
            yy += 1
        }
        return false
    }

    private func carveSphereFlat(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16], _ x: Double, _ y: Double, _ z: Double, _ r: Double, _ yScale: Double) {
        let baseX = cx * 16, baseZ = cz * 16
        let x0 = max(baseX, Int((x - r).rounded(.down))), x1 = min(baseX + 15, Int((x + r).rounded(.up)))
        if x1 < x0 { return }
        let z0 = max(baseZ, Int((z - r).rounded(.down))), z1 = min(baseZ + 15, Int((z + r).rounded(.up)))
        if z1 < z0 { return }
        let ry = r * yScale
        let y0 = max(GEN_MIN_Y + 2, Int((y - ry).rounded(.down))), y1 = min(GEN_MIN_Y + WORLD_H - 1, Int((y + ry).rounded(.up)))
        if y1 < y0 { return }
        for yy in y0...y1 {
            for zz in z0...z1 {
                for xx in x0...x1 {
                    let dx = (Double(xx) + 0.5 - x) / r
                    let dy = (Double(yy) + 0.5 - y) / ry
                    let dz = (Double(zz) + 0.5 - z) / r
                    if dx * dx + dy * dy + dz * dz < 1 {
                        let idx = ((yy - GEN_MIN_Y) * 16 + (zz - baseZ)) * 16 + (xx - baseX)
                        let cur = blocks[idx]
                        if cur == WATER || cur == LAVA { continue } // don't breach water
                        if cur != AIR {
                            // below sea level a carver fills with fluid (vanilla
                            // 1.18 semantics) — air ravines through the seafloor
                            // left dry trenches walled by static water faces
                            blocks[idx] = yy <= -55 ? LAVA : (yy <= SEA && columnHasWaterAbove(blocks, idx, xx - baseX, yy, zz - baseZ) ? WATER : AIR)
                        }
                    }
                }
            }
        }
    }

    /// surface pass: biome top/under blocks, deepslate, bedrock, snow/ice
    public func applySurface(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16], _ heights: [Int16], _ surfaceBiomes: [UInt8]) {
        let baseX = cx * 16, baseZ = cz * 16
        _ = heights
        let TERRA_BANDS: [UInt16] = [
            B.terracotta, B.orange_terracotta, B.terracotta, B.yellow_terracotta,
            B.white_terracotta, B.light_gray_terracotta, B.orange_terracotta, B.red_terracotta,
            B.terracotta, B.brown_terracotta, B.orange_terracotta, B.terracotta,
        ]
        let SAND = cell(B.sand), RED_SAND = cell(B.red_sand)
        let SANDSTONE = cell(B.sandstone), RED_SANDSTONE = cell(B.red_sandstone)
        let nBands = TERRA_BANDS.count
        @inline(__always) func band(_ y: Int, _ shift: Int) -> UInt16 {
            cell(TERRA_BANDS[(((y + shift) % nBands) + nBands) % nBands])
        }
        for z in 0..<16 {
            for x in 0..<16 {
                let wx = baseX + x, wz = baseZ + z
                let b = Int(surfaceBiomes[z * 16 + x])
                let def = biomeDef(b)
                let sn = surfNoise.sample2(Double(wx), Double(wz))
                let surfDepth = 3 + Int(((sn * 0.5 + 0.5) * 2).rounded(.down))
                var depth = -1
                let isBadlands = b == Biome.badlands.rawValue || b == Biome.erodedBadlands.rawValue || b == Biome.woodedBadlands.rawValue
                let bandShift = Int((bandOffset.noise2(Double(wx) / 90, Double(wz) / 90) * 4).rounded(.down))
                let deepY = 8 - Int(((sn * 0.5 + 0.5) * 8).rounded(.down))
                var y = GEN_MIN_Y + WORLD_H - 1
                while y >= GEN_MIN_Y {
                    let idx = ((y - GEN_MIN_Y) * 16 + z) * 16 + x
                    let c = blocks[idx]
                    if c == AIR || c == WATER || c == LAVA { depth = -1; y -= 1; continue }
                    if c != STONE { depth = -1; y -= 1; continue }
                    depth += 1
                    // deepslate transition
                    if y < deepY {
                        blocks[idx] = DEEPSLATE
                        if depth >= surfDepth { y -= 1; continue }
                    }
                    if depth == 0 {
                        let above = y + 1 <= GEN_MIN_Y + WORLD_H - 1 ? blocks[idx + 256] : AIR
                        let underwater = above == WATER
                        if isBadlands {
                            blocks[idx] = underwater ? RED_SAND : (y > 74 ? band(y, bandShift) : def.top)
                        } else if underwater {
                            blocks[idx] = def.underwaterTop
                        } else {
                            blocks[idx] = def.top
                        }
                    } else if depth < surfDepth {
                        if isBadlands && y > 74 {
                            blocks[idx] = band(y, bandShift)
                        } else {
                            blocks[idx] = def.under
                        }
                    } else if isBadlands && y > 60 && depth < 16 {
                        blocks[idx] = band(y, bandShift)
                    }
                    // sandstone under sand
                    if depth >= 1 && depth < surfDepth + 3 {
                        let above = blocks[idx + 256]
                        if (above == SAND || above == RED_SAND) && blocks[idx] == def.under {
                            blocks[idx] = above == SAND ? SANDSTONE : RED_SANDSTONE
                        }
                    }
                    y -= 1
                }
                // bedrock floor
                let brand = hash2(seed, wx, wz, 99)
                for by in GEN_MIN_Y..<(GEN_MIN_Y + 5) {
                    if by == GEN_MIN_Y || (((brand >> UInt32(by - GEN_MIN_Y)) & 3) != 0 && by < GEN_MIN_Y + 1 + Int((brand >> 8) & 3) + 1) {
                        blocks[((by - GEN_MIN_Y) * 16 + z) * 16 + x] = BEDROCK
                    }
                }
                blocks[(0 * 16 + z) * 16 + x] = BEDROCK
            }
        }
    }

    /// freeze + snow-layer pass after features
    public func applySnowAndIce(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16], _ surfaceBiomes: [UInt8]) {
        let ICE = cell(B.ice)
        for z in 0..<16 {
            for x in 0..<16 {
                let b = Int(surfaceBiomes[z * 16 + x])
                // find top
                var y = GEN_MIN_Y + WORLD_H - 1
                while y > GEN_MIN_Y {
                    let idx = ((y - GEN_MIN_Y) * 16 + z) * 16 + x
                    let c = blocks[idx]
                    if c == AIR { y -= 1; continue }
                    if c == WATER {
                        if snowsAt(b, y) { blocks[idx] = ICE }
                        break
                    }
                    let id = c >> 4
                    if id == B.lava || id == B.ice { break }
                    if snowsAt(b, y + 1) && y + 1 <= GEN_MIN_Y + WORLD_H - 1 {
                        // snow layer on solid full-ish blocks
                        let above = blocks[idx + 256]
                        if above == AIR && solidForSnow(id) {
                            blocks[idx + 256] = cell(B.snow, 0)
                        }
                    }
                    break
                }
            }
        }
    }

    /// ore placement
    public func placeOres(_ cx: Int, _ cz: Int, _ blocks: inout [UInt16], _ surfaceBiomes: [UInt8]) {
        var rng = chunkRandom(seed, cx, cz, 4242)
        let resourceRich = settings.preset == .moderateHillsResourceRich
        func place(_ oreStone: UInt16, _ oreDeep: UInt16, _ attempts: Int, _ minY: Int, _ maxY: Int, _ size: Int, _ triangular: Bool, _ discardOnAir: Double = 0) {
            for _ in 0..<attempts {
                let x = rng.nextInt(16), z = rng.nextInt(16)
                let y: Int
                if triangular {
                    let mid = Double(minY + maxY) / 2
                    y = Int(rng.nextTriangular(mid, Double(maxY - minY) / 2).rounded(.down))
                } else {
                    y = minY + rng.nextInt(max(1, maxY - minY))
                }
                if y < GEN_MIN_Y + 1 || y >= GEN_MIN_Y + WORLD_H - 1 { continue }
                oreBlob(&blocks, &rng, x, y - GEN_MIN_Y, z, size, oreStone, oreDeep, discardOnAir)
            }
        }
        func placeResource(_ oreStone: UInt16, _ oreDeep: UInt16, _ attempts: Int, _ minY: Int, _ maxY: Int, _ size: Int, _ triangular: Bool, _ discardOnAir: Double = 0) {
            place(oreStone, oreDeep, attempts * (resourceRich ? 2 : 1), minY, maxY, size, triangular, discardOnAir)
        }
        // vanilla 1.20 attempts/sizes/bands (the old numbers left mountains
        // nearly iron-free — 8 attempts vs vanilla's 90 — and misplaced coal)
        placeResource(cell(B.coal_ore), cell(B.deepslate_coal_ore), 30, 136, 320, 17, false)
        placeResource(cell(B.coal_ore), cell(B.deepslate_coal_ore), 20, 0, 192, 17, true, 0.5)
        placeResource(cell(B.iron_ore), cell(B.deepslate_iron_ore), 10, -24, 56, 9, true)
        placeResource(cell(B.iron_ore), cell(B.deepslate_iron_ore), 90, 80, 384, 9, true)
        placeResource(cell(B.iron_ore), cell(B.deepslate_iron_ore), 10, -64, 72, 4, false)
        placeResource(cell(B.copper_ore), cell(B.deepslate_copper_ore), 16, -16, 112, 10, true)
        placeResource(cell(B.gold_ore), cell(B.deepslate_gold_ore), 4, -64, 32, 9, true)
        placeResource(cell(B.gold_ore), cell(B.deepslate_gold_ore), 1, -64, -48, 9, false, 0.5)
        placeResource(cell(B.redstone_ore), cell(B.deepslate_redstone_ore), 4, -64, 15, 8, false)
        placeResource(cell(B.redstone_ore), cell(B.deepslate_redstone_ore), 8, -96, -32, 8, true)
        placeResource(cell(B.lapis_ore), cell(B.deepslate_lapis_ore), 2, -32, 32, 7, true)
        placeResource(cell(B.lapis_ore), cell(B.deepslate_lapis_ore), 4, -64, 64, 7, false, 1.0)
        placeResource(cell(B.diamond_ore), cell(B.deepslate_diamond_ore), 7, -144, 16, 8, true, 0.5)
        let largeDiamondRolls = resourceRich ? 2 : 1
        for _ in 0..<largeDiamondRolls where rng.nextInt(9) == 0 {   // vanilla "large diamond" - 1 in 9 chunks
            place(cell(B.diamond_ore), cell(B.deepslate_diamond_ore), 1, -144, 16, 12, true, 0.7)
        }
        placeResource(cell(B.diamond_ore), cell(B.deepslate_diamond_ore), 4, -64, -48, 8, false, 1.0)
        // badlands bonus gold (was a feature no-op — badlands had no extra gold)
        let cBiome = Int(surfaceBiomes[8 * 16 + 8])
        if resourceRich || cBiome == Biome.badlands.rawValue || cBiome == Biome.woodedBadlands.rawValue
            || cBiome == Biome.erodedBadlands.rawValue {
            place(cell(B.gold_ore), cell(B.deepslate_gold_ore), resourceRich ? 100 : 50, 32, 256, 9, false)
        }
        // emeralds in mountains
        let centerBiome = Int(surfaceBiomes[8 * 16 + 8])
        let emeraldBiomes = [Biome.windsweptHills, .windsweptGravellyHills, .meadow, .grove, .snowySlopes,
                             .jaggedPeaks, .frozenPeaks, .stonyPeaks, .cherryGrove, .windsweptForest].map { $0.rawValue }
        if resourceRich || emeraldBiomes.contains(centerBiome) {
            place(cell(B.emerald_ore), cell(B.deepslate_emerald_ore), resourceRich ? 200 : 100, -16, 480, 3, true)
        }
        // stone variety blobs
        let TUFF = cell(B.tuff)
        let varieties: [(UInt16, Int, Int, Int, Int)] = [
            (cell(B.granite), 2, 0, 60, 32), (cell(B.diorite), 2, 0, 60, 32), (cell(B.andesite), 2, 0, 60, 32),
            (cell(B.granite), 2, 64, 128, 32), (cell(B.diorite), 2, 64, 128, 32), (cell(B.andesite), 2, 64, 128, 32),
            (TUFF, 3, -64, 0, 24), (cell(B.dirt), 4, 0, 128, 20), (cell(B.gravel), 3, -32, 128, 22),
        ]
        for (blk, attempts, lo, hi, size) in varieties {
            for _ in 0..<attempts {
                let x = rng.nextInt(16), z = rng.nextInt(16)
                let y = lo + rng.nextInt(hi - lo)
                if y < GEN_MIN_Y + 1 || y >= GEN_MIN_Y + WORLD_H - 1 { continue }
                oreBlob(&blocks, &rng, x, y - GEN_MIN_Y, z, size, blk, blk == TUFF ? blk : DEEPSLATE, 0)
            }
        }
    }

    private func oreBlob(_ blocks: inout [UInt16], _ rng: inout RandomX, _ x: Int, _ ry: Int, _ z: Int, _ size: Int, _ oreStone: UInt16, _ oreDeep: UInt16, _ discardOnAir: Double) {
        // vanilla spheroid vein: ellipsoids strung along a random diagonal —
        // the old ±1 random walk left 1-2 block scatter instead of real veins
        let TUFF = cell(B.tuff), GRANITE = cell(B.granite), DIORITE = cell(B.diorite), ANDESITE = cell(B.andesite)
        let ang = rng.nextFloat() * .pi
        let fs = Double(size) / 8.0
        let sx = Double(x) + 0.5 + detSin(ang) * fs
        let ex = Double(x) + 0.5 - detSin(ang) * fs
        let sz2 = Double(z) + 0.5 + detCos(ang) * fs
        let ez = Double(z) + 0.5 - detCos(ang) * fs
        let sy = Double(ry) + Double(rng.nextInt(3)) - 2
        let ey = Double(ry) + Double(rng.nextInt(3)) - 2
        let steps = max(1, size)
        for i in 0..<steps {
            let t = Double(i) / Double(steps)
            let cxp = sx + (ex - sx) * t
            let cyp = sy + (ey - sy) * t
            let czp = sz2 + (ez - sz2) * t
            // bulging radius along the strand, vanilla-style
            let d = Double(rng.nextFloat()) * Double(size) / 16.0
            let r = (detSin(t * .pi) + 1) * d * 0.6 + 0.5
            let x0 = Int((cxp - r).rounded(.down)), x1 = Int((cxp + r).rounded(.up))
            let y0 = Int((cyp - r).rounded(.down)), y1 = Int((cyp + r).rounded(.up))
            let z0 = Int((czp - r).rounded(.down)), z1 = Int((czp + r).rounded(.up))
            for py in y0...y1 {
                if py < 1 || py >= WORLD_H - 1 { continue }
                let dy = (Double(py) + 0.5 - cyp) / r
                if dy * dy >= 1 { continue }
                for pz in z0...z1 {
                    if pz < 0 || pz > 15 { continue }
                    let dz = (Double(pz) + 0.5 - czp) / r
                    if dy * dy + dz * dz >= 1 { continue }
                    for px in x0...x1 {
                        if px < 0 || px > 15 { continue }
                        let dx = (Double(px) + 0.5 - cxp) / r
                        if dx * dx + dy * dy + dz * dz >= 1 { continue }
                        let idx = (py * 16 + pz) * 16 + px
                        let cur = blocks[idx]
                        guard cur == STONE || cur == DEEPSLATE || cur == TUFF
                            || cur == GRANITE || cur == DIORITE || cur == ANDESITE else { continue }
                        if discardOnAir > 0 {
                            var exposed = false
                            for (ddx, ddy, ddz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                                let nx2 = px + ddx, ny2 = py + ddy, nz2 = pz + ddz
                                if nx2 < 0 || nx2 > 15 || nz2 < 0 || nz2 > 15 || ny2 < 0 || ny2 >= WORLD_H { continue }
                                if blocks[(ny2 * 16 + nz2) * 16 + nx2] == AIR { exposed = true; break }
                            }
                            if exposed && rng.nextFloat() < discardOnAir { continue }
                        }
                        blocks[idx] = (cur == DEEPSLATE) ? oreDeep : oreStone
                    }
                }
            }
        }
    }
}

func solidForSnow(_ id: UInt16) -> Bool {
    // only sturdy tops carry snow layers — landing snow on grass tufts/flowers
    // (placed by the feature pass that runs first) left layers floating on plants
    if id == B.ice || id == B.packed_ice || id == B.air || id == B.water || id == B.lava { return false }
    return blockDefs[Int(id)].solid
}
