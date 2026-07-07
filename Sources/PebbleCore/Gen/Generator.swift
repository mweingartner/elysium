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
}

public final class ArraySink: ChunkSink {
    public let cx: Int
    public let cz: Int
    public let minY: Int
    public let maxY: Int
    public var blocks: [UInt16]
    public var blockEntities: [BESpec] = []
    public var entities: [EntitySpec] = []
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
        blocks[((y - minY) * 16 + lz) * 16 + lx] = c
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

private struct OverworldGenKey: Hashable {
    let seed: UInt32
    let presetID: String
    let singleBiomeID: String
    let dungeonDensityLevel: Int
}

private var overworldGens: [OverworldGenKey: OverworldGen] = [:]
private var netherGens: [UInt32: NetherGen] = [:]
private var endGens: [UInt32: EndGen] = [:]
private let genLock = NSLock()

public func overworldGen(_ seed: UInt32, settings: WorldGenerationSettings = .normal) -> OverworldGen {
    genLock.lock()
    defer { genLock.unlock() }
    let key = OverworldGenKey(seed: seed, presetID: settings.preset.rawValue,
                              singleBiomeID: biomeID(settings.singleBiome),
                              dungeonDensityLevel: settings.dungeonDensity.rawValue)
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

private func generateFlatOverworldChunk(_ seed: UInt32, _ cx: Int, _ cz: Int) -> GenOutput {
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
    let biomes = filledBiomeQuarts(.plains, height: info.height)
    let sink = ArraySink(cx: cx, cz: cz, blocks: blocks, minY: info.minY, maxY: info.minY + info.height,
                         heightFallback: { _, _ in GEN_MIN_Y + 4 })
    let ctx = GenCtx(seed: seed, heightAt: { _, _ in GEN_MIN_Y + 4 },
                     biomeAt: { _, _ in Biome.plains.rawValue }, dim: Dim.overworld.rawValue)
    let flatStructs = STRUCTURES.filter { $0.id == "village" || $0.id == "stronghold" }
    let structRefs = buildStructuresForChunk(ctx, cx, cz, sink, flatStructs)
    return GenOutput(blocks: sink.blocks, biomes: biomes,
                     blockEntities: sink.blockEntities, entities: [], structRefs: structRefs)
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
            return generateFlatOverworldChunk(seed, cx, cz)
        }
        if settings.preset == .debugAllBlockStates {
            return generateDebugOverworldChunk(cx, cz)
        }
        let gen = overworldGen(seed, settings: settings)
        let res = gen.fillTerrain(cx, cz, &blocks, &biomes)
        gen.carve(cx, cz, &blocks)
        gen.applySurface(cx, cz, &blocks, res.heights, res.surfaceBiomes)
        gen.placeOres(cx, cz, &blocks, res.surfaceBiomes)

        // refined estimate (incl. 3D detail) — the spline-only one diverged ±34
        // from real terrain, scattering trees and burying/hovering structures
        let sink = ArraySink(cx: cx, cz: cz, blocks: blocks, minY: GEN_MIN_Y, maxY: GEN_MIN_Y + WORLD_H,
                             heightFallback: { x, z in gen.refinedHeightEstimate(Double(x), Double(z)) })
        let ctx = GenCtx(seed: seed,
                         heightAt: { x, z in gen.refinedHeightEstimate(Double(x), Double(z)) },
                         biomeAt: { x, z in gen.surfaceBiomeAt(Double(x), Double(z)).rawValue },
                         dim: dim.rawValue)
        let overworldStructs = STRUCTURES.filter { !["fortress", "bastion", "end_city"].contains($0.id) }
        let structRefs = buildStructuresForChunk(ctx, cx, cz, sink, overworldStructs)

        // features from 3×3 origin chunks
        let surfaceBiomeAt: (Int, Int) -> Int = { x, z in gen.surfaceBiomeAt(Double(x), Double(z)).rawValue }
        for oz in (cz - 1)...(cz + 1) {
            for ox in (cx - 1)...(cx + 1) {
                let centerBiome = gen.surfaceBiomeAt(Double(ox * 16 + 8), Double(oz * 16 + 8))
                let feats = biomeDef(centerBiome.rawValue).features
                var salt: UInt32 = 9000
                for f in feats {
                    var rng = chunkRandom(seed, ox, oz, salt)
                    salt += 1
                    runFeature(f, sink, &rng, ox, oz, seed, surfaceBiomeAt)
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
        tryDungeons(seed, cx, cz, sink, density: settings.dungeonDensity)
        gen.applySnowAndIce(cx, cz, &sink.blocks, res.surfaceBiomes)

        // worldgen passive mobs
        var mobRng = chunkRandom(seed, cx, cz, 0xAB1E)
        if mobRng.nextFloat() < 0.1 {
            let centerBiome = gen.surfaceBiomeAt(Double(cx * 16 + 8), Double(cz * 16 + 8))
            let list = biomeDef(centerBiome.rawValue).creatures
            if !list.isEmpty {
                let entry = mobRng.pickWeighted(list) { $0.weight }
                let pack = entry.minPack + mobRng.nextInt(entry.maxPack - entry.minPack + 1)
                for _ in 0..<pack {
                    let px = cx * 16 + mobRng.nextInt(16), pz = cz * 16 + mobRng.nextInt(16)
                    let py = sink.topY(px, pz)
                    // require real ground — topY over oceans returned the water
                    // surface and shipped chickens standing on the sea
                    let ground = sink.get(px, py - 1, pz)
                    let gid = ground >> 4
                    let grounded = ground != -1 && gid != Int(B.water) && gid != Int(B.lava)
                        && gid != 0 && blockDefs[gid].solid
                    if py > 50 && py < 200 && grounded {
                        sink.addEntity(EntitySpec(mob: entry.mob, x: Double(px) + 0.5, y: Double(py), z: Double(pz) + 0.5))
                    }
                }
            }
        }
        return GenOutput(blocks: sink.blocks, biomes: biomes,
                         blockEntities: sink.blockEntities, entities: sink.entities, structRefs: structRefs)
    }

    if dim == .nether {
        let gen = netherGen(seed)
        let surfaceBiomes = gen.fillTerrain(cx, cz, &blocks, &biomes)
        gen.applySurface(cx, cz, &blocks, surfaceBiomes)
        gen.placeOres(cx, cz, &blocks)
        let sink = ArraySink(cx: cx, cz: cz, blocks: blocks, minY: 0, maxY: NETHER_H,
                             heightFallback: { x, z in gen.heightEstimate(Double(x), Double(z)) })
        let ctx = GenCtx(seed: seed,
                         heightAt: { x, z in gen.heightEstimate(Double(x), Double(z)) },
                         biomeAt: { x, z in gen.biomeAt(Double(x), Double(z)) },
                         dim: dim.rawValue)
        let netherStructs = STRUCTURES.filter { $0.id == "fortress" || $0.id == "bastion" || $0.id == "ruined_portal" }
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
        return GenOutput(blocks: sink.blocks, biomes: biomes,
                         blockEntities: sink.blockEntities, entities: sink.entities, structRefs: structRefs)
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
    let ctx = GenCtx(seed: seed,
                     heightAt: { x, z in
                         let f = gen.islandFactor(Double(x), Double(z))
                         return f > 0 ? Int((58 + f * 4).rounded(.down)) : 0
                     },
                     biomeAt: { x, z in gen.biomeColumn(Double(x), Double(z)) },
                     dim: dim.rawValue)
    let endStructs = STRUCTURES.filter { $0.id == "end_city" }
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
                     blockEntities: sink.blockEntities, entities: sink.entities, structRefs: structRefs)
}

/// back-compat shim for callers built against the pre-structures pipeline
public func generateOverworldChunk(_ seed: UInt32, _ cx: Int, _ cz: Int) -> GenOutput {
    generateChunk(.overworld, seed, cx, cz)
}
