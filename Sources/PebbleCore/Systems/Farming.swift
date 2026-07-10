// Random-tick behaviors — crop growth, saplings,
// grass/mycelium spread, leaf decay, fire spread, ice/snow, copper oxidation,
// cane/cactus/bamboo/kelp/vines/berries, farmland moisture, turtle eggs,
// frogspawn, amethyst, dripstone, sculk, chorus, gravity blocks, weather.
//
// Uses its own seeded module RNG (0xFA01) exactly like the frozen baseline.

import Foundation

var farmingRng = RandomX(0xFA01)

// world-backed sink for tree growth
final class WorldSink: ChunkSink {
    var cx = 0
    var cz = 0
    let minY: Int
    let maxY: Int
    private let world: World

    init(_ world: World) {
        self.world = world
        minY = world.info.minY
        maxY = world.info.minY + world.info.height
    }
    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        let cur = world.getBlock(x, y, z) >> 4
        let curName = cur != 0 ? blockDefs[cur].name : ""
        if cur == 0 || blockDefs[cur].replaceable || curName.contains("leaves") || c == 0 {
            world.setBlock(x, y, z, Int(c))
        } else if (c >> 4) != 0 {
            let newName = blockDefs[Int(c >> 4)].name
            if newName.contains("log") || newName.contains("dirt") || newName.contains("mangrove_roots") {
                world.setBlock(x, y, z, Int(c))
            }
        }
    }
    func get(_ x: Int, _ y: Int, _ z: Int) -> Int { world.getBlock(x, y, z) }
    func topY(_ x: Int, _ z: Int) -> Int { world.surfaceY(x, z) }
    func addBlockEntity(_ spec: BESpec) {}
    func addEntity(_ spec: EntitySpec) {
        var opts = SpawnOpts()
        if case .bool(true)? = spec.data["baby"] { opts.baby = true }
        _ = spawnMob(world, spec.mob, spec.x, spec.y, spec.z, opts)
    }
}

@discardableResult
public func growTreeAt(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ sapId: Int) -> Bool {
    let sink = WorldSink(world)
    world.setBlock(x, y, z, 0)
    if sapId == Int(B.oak_sapling) { genOakTree(sink, &farmingRng, x, y, z, fancy: farmingRng.nextFloat() < 0.1) }
    else if sapId == Int(B.birch_sapling) { genBirchTree(sink, &farmingRng, x, y, z) }
    else if sapId == Int(B.spruce_sapling) { genSpruceTree(sink, &farmingRng, x, y, z) }
    else if sapId == Int(B.jungle_sapling) { genJungleTree(sink, &farmingRng, x, y, z, mega: false) }
    else if sapId == Int(B.acacia_sapling) { genAcaciaTree(sink, &farmingRng, x, y, z) }
    else if sapId == Int(B.dark_oak_sapling) { genDarkOakTree(sink, &farmingRng, x, y, z) }
    else if sapId == Int(B.cherry_sapling) { genCherryTree(sink, &farmingRng, x, y, z) }
    else if sapId == Int(B.mangrove_propagule) { genMangroveTree(sink, &farmingRng, x, y, z) }
    else if sapId == Int(B.crimson_fungus) { genHugeFungus(sink, &farmingRng, x, y, z, crimson: true) }
    else if sapId == Int(B.warped_fungus) { genHugeFungus(sink, &farmingRng, x, y, z, crimson: false) }
    else { world.setBlock(x, y, z, Int(cell(UInt16(sapId)))); return false }
    return true
}

public func igniteTNT(_ world: World, _ x: Int, _ y: Int, _ z: Int) {
    let tnt = TNTEntity(world: world)
    _ = world.transferRPGControlledCharge(at: RPGBlockPosition(x, y, z), to: tnt)
    world.setBlock(x, y, z, 0)
    tnt.setPos(Double(x) + 0.5, Double(y), Double(z) + 0.5)
    world.addEntity(tnt)
    world.hooks.playSound("entity.tnt.primed", Double(x) + 0.5, Double(y), Double(z) + 0.5, 1, 1)
}

// sculk spreading from catalysts handled at mob death (Game hook)
public func sculkBloom(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ xp: Int) {
    // find catalyst nearby
    for dy in -4...4 {
        for dz in -8...8 {
            for dx in -8...8 {
                if (world.getBlock(x + dx, y + dy, z + dz) >> 4) == Int(B.sculk_catalyst) {
                    // spread sculk around death point
                    let n = min(20, 2 + xp)
                    for _ in 0..<n {
                        let sx = x + farmingRng.nextInt(7) - 3
                        let sz = z + farmingRng.nextInt(7) - 3
                        var sy = y + 3
                        while sy > y - 4 {
                            let ground = world.getBlock(sx, sy - 1, sz) >> 4
                            let at = world.getBlock(sx, sy, sz) >> 4
                            if at == 0 && ground != 0 && blockDefs[ground].solid && ground != Int(B.sculk) {
                                world.setBlock(sx, sy - 1, sz, Int(cell(B.sculk)))
                                if farmingRng.nextFloat() < 0.09 { world.setBlock(sx, sy, sz, Int(cell(B.sculk_vein, 0))) }
                                break
                            }
                            sy -= 1
                        }
                    }
                    world.hooks.playSound("block.sculk_catalyst.bloom", Double(x + dx), Double(y + dy), Double(z + dz), 1, 1)
                    world.hooks.addParticles("sculk_soul", Double(x), Double(y) + 0.5, Double(z), 6, 0.4, 0)
                    return
                }
            }
        }
    }
}

// snow/ice formation during snowfall (called from weather tick)
public func weatherRandomTick(_ world: World, _ x: Int, _ z: Int) {
    if world.rainLevel < 0.5 { return }
    let y = world.heightAt(x, z) + 1
    let biome = world.biomeAt(x, y, z)
    if snowsAt(biome, y) {
        let at = world.getBlock(x, y, z)
        let below = world.getBlock(x, y - 1, z)
        if at == 0 && (below >> 4) != 0 && blockDefs[below >> 4].fullCube {
            world.setBlock(x, y, z, Int(cell(B.snow, 0)))
        }
        if (below >> 4) == Int(B.water) && (below & 15) == 0 {
            world.setBlock(x, y - 1, z, Int(cell(B.ice)))
        }
    } else {
        // cauldron rain fill
        let at = world.getBlock(x, y - 1, z)
        if (at >> 4) == Int(B.cauldron) && ((at >> 2) & 3) == 0 && (at & 3) < 3 && farmingRng.nextFloat() < 0.3 {
            world.setBlock(x, y - 1, z, Int(cell(B.cauldron, (at & 3) + 1)))
        }
    }
}

private var farmingRegistered = false

public func registerFarmingHandlers() {
    if farmingRegistered { return }
    farmingRegistered = true

    func reg(_ id: UInt16, _ fn: @escaping BlockTickFn) {
        randomTickHandlers[Int(id)] = fn
    }

    // crops -------------------------------------------------------------------
    func cropTick(_ maxStage: Int, _ metaBits: Int) -> BlockTickFn {
        return { world, x, y, z, c in
            let stage = c & metaBits
            if stage >= maxStage { return }
            if world.lightAt(x, y, z) < 9 { return }
            // moist farmland boosts
            let below = world.getBlock(x, y - 1, z)
            let moist = (below >> 4) == Int(B.farmland) && (below & 7) >= 7
            if farmingRng.nextFloat() < (moist ? 0.33 : 0.14) {
                world.setBlock(x, y, z, Int(cell(UInt16(c >> 4), stage + 1)))
            }
        }
    }
    reg(B.wheat, cropTick(7, 7))
    reg(B.carrots, cropTick(7, 7))
    reg(B.potatoes, cropTick(7, 7))
    reg(B.beetroots, cropTick(3, 3))
    reg(B.torchflower_crop) { world, x, y, z, c in
        let stage = c & 1
        if world.lightAt(x, y, z) < 9 { return }
        if farmingRng.nextFloat() < 0.2 {
            if stage == 0 { world.setBlock(x, y, z, Int(cell(B.torchflower_crop, 1))) }
            else { world.setBlock(x, y, z, Int(cell(B.torchflower))) }
        }
    }
    reg(B.pitcher_crop) { world, x, y, z, c in
        let stage = c & 7
        if world.lightAt(x, y, z) < 9 || (c & 8) != 0 { return }
        if farmingRng.nextFloat() < 0.2 {
            if stage < 4 { world.setBlock(x, y, z, Int(cell(B.pitcher_crop, stage + 1))) }
            else {
                world.setBlock(x, y, z, Int(cell(B.pitcher_plant, 0)))
                if world.getBlock(x, y + 1, z) == 0 { world.setBlock(x, y + 1, z, Int(cell(B.pitcher_plant, 1))) }
            }
        }
    }
    for stem in [B.melon_stem, B.pumpkin_stem] {
        reg(stem) { world, x, y, z, c in
            if world.lightAt(x, y, z) < 9 { return }
            let stage = c & 7
            if (c & 8) != 0 { return } // attached
            if farmingRng.nextFloat() > 0.2 { return }
            if stage < 7 {
                world.setBlock(x, y, z, Int(cell(stem, stage + 1)))
            } else {
                // grow fruit
                let fruit = stem == B.melon_stem ? B.melon : B.pumpkin
                let dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
                // already has fruit?
                for (dx, dz) in dirs {
                    if (world.getBlock(x + dx, y, z + dz) >> 4) == Int(fruit) { return }
                }
                let (dx, dz) = dirs[farmingRng.nextInt(4)]
                let target = world.getBlock(x + dx, y, z + dz)
                let ground = world.getBlock(x + dx, y - 1, z + dz) >> 4
                if target == 0 && (ground == Int(B.grass_block) || ground == Int(B.dirt) || ground == Int(B.farmland) || ground == Int(B.coarse_dirt)) {
                    world.setBlock(x + dx, y, z + dz, Int(cell(fruit)))
                    world.setBlock(x, y, z, Int(cell(stem, 8 | 7)))
                }
            }
        }
    }
    reg(B.nether_wart) { world, x, y, z, c in
        let stage = c & 3
        if stage < 3 && farmingRng.nextFloat() < 0.1 { world.setBlock(x, y, z, Int(cell(B.nether_wart, stage + 1))) }
    }
    reg(B.sweet_berry_bush) { world, x, y, z, c in
        let stage = c & 3
        if stage < 3 && world.lightAt(x, y, z) >= 9 && farmingRng.nextFloat() < 0.2 {
            world.setBlock(x, y, z, Int(cell(B.sweet_berry_bush, stage + 1)))
        }
    }
    reg(B.cocoa) { world, x, y, z, c in
        let age = (c >> 2) & 3
        if age < 2 && farmingRng.nextFloat() < 0.2 { world.setBlock(x, y, z, Int(cell(B.cocoa, (c & 3) | ((age + 1) << 2)))) }
    }
    reg(B.farmland) { world, x, y, z, c in
        // hydration scan
        var wet = false
        outer: for dz in -4...4 {
            for dx in -4...4 {
                for dy in 0...1 {
                    if (world.getBlock(x + dx, y + dy, z + dz) >> 4) == Int(B.water) { wet = true; break outer }
                }
            }
        }
        let moisture = c & 7
        if wet || world.isRainingAt(x, y + 1, z) {
            if moisture < 7 { world.setBlock(x, y, z, Int(cell(B.farmland, 7))) }
        } else if moisture > 0 {
            world.setBlock(x, y, z, Int(cell(B.farmland, moisture - 1)))
        } else {
            // dry: revert to dirt if no crop
            let above = world.getBlock(x, y + 1, z) >> 4
            if above != Int(B.wheat) && above != Int(B.carrots) && above != Int(B.potatoes) && above != Int(B.beetroots) && above != Int(B.melon_stem) && above != Int(B.pumpkin_stem) {
                world.setBlock(x, y, z, Int(cell(B.dirt)))
            }
        }
    }

    // saplings / fungi --------------------------------------------------------
    for sap in [B.oak_sapling, B.birch_sapling, B.spruce_sapling, B.jungle_sapling, B.acacia_sapling, B.dark_oak_sapling, B.cherry_sapling] {
        reg(sap) { world, x, y, z, c in
            if world.lightAt(x, y, z) < 9 { return }
            if (c & 8) == 0 {
                if farmingRng.nextFloat() < 0.15 { world.setBlock(x, y, z, Int(cell(UInt16(c >> 4), c & 7 | 8))) }
            } else if farmingRng.nextFloat() < 0.15 {
                growTreeAt(world, x, y, z, c >> 4)
            }
        }
    }
    reg(B.mangrove_propagule) { world, x, y, z, c in
        if (c & 8) != 0 {
            // hanging: grow age then drop
            let age = c & 7
            if age < 4 && farmingRng.nextFloat() < 0.15 { world.setBlock(x, y, z, Int(cell(B.mangrove_propagule, (age + 1) | 8))) }
            return
        }
        if world.lightAt(x, y, z) >= 9 && farmingRng.nextFloat() < 0.12 { growTreeAt(world, x, y, z, Int(B.mangrove_propagule)) }
    }

    // grass spread / decay ------------------------------------------------------
    reg(B.grass_block) { world, x, y, z, _ in
        let above = world.getBlock(x, y + 1, z)
        let aboveId = above >> 4
        if blockDefs[aboveId].lightOpacity >= 15 && aboveId != 0 {
            world.setBlock(x, y, z, Int(cell(B.dirt)))
            return
        }
        if world.lightAt(x, y + 1, z) >= 9 {
            for _ in 0..<4 {
                let tx = x + farmingRng.nextInt(3) - 1
                let ty = y + farmingRng.nextInt(5) - 3
                let tz = z + farmingRng.nextInt(3) - 1
                if (world.getBlock(tx, ty, tz) >> 4) == Int(B.dirt) {
                    let tAbove = world.getBlock(tx, ty + 1, tz) >> 4
                    if blockDefs[tAbove].lightOpacity < 15 && world.lightAt(tx, ty + 1, tz) >= 4 {
                        world.setBlock(tx, ty, tz, Int(cell(B.grass_block)))
                    }
                }
            }
        }
    }
    reg(B.mycelium) { world, x, y, z, _ in
        let above = world.getBlock(x, y + 1, z) >> 4
        if blockDefs[above].lightOpacity >= 15 && above != 0 { world.setBlock(x, y, z, Int(cell(B.dirt))) }
    }
    for nylium in [B.crimson_nylium, B.warped_nylium] {
        reg(nylium) { world, x, y, z, _ in
            let above = world.getBlock(x, y + 1, z) >> 4
            if blockDefs[above].lightOpacity >= 15 && above != 0 { world.setBlock(x, y, z, Int(cell(B.netherrack))) }
        }
    }

    // leaves decay ----------------------------------------------------------------
    for leaf in ["oak_leaves", "spruce_leaves", "birch_leaves", "jungle_leaves", "acacia_leaves", "dark_oak_leaves", "mangrove_leaves", "cherry_leaves", "azalea_leaves", "flowering_azalea_leaves"] {
        reg(bid(leaf)) { world, x, y, z, c in
            if (c & 8) != 0 { return } // persistent
            // distance to log scan (BFS depth 5)
            var foundLog = false
            struct K: Hashable { let x: Int, y: Int, z: Int }
            var seen = Set<K>()
            var queue: [(Int, Int, Int, Int)] = [(x, y, z, 0)]
            var head = 0
            while head < queue.count {
                let (qx, qy, qz, d) = queue[head]
                head += 1
                if d > 5 { continue }
                for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                    let nx = qx + dx, ny = qy + dy, nz = qz + dz
                    let k = K(x: nx, y: ny, z: nz)
                    if seen.contains(k) { continue }
                    seen.insert(k)
                    let id = world.getBlock(nx, ny, nz) >> 4
                    let name = id >= 0 && id < blockDefs.count ? blockDefs[id].name : ""
                    if name.hasSuffix("_log") || name.hasSuffix("_stem") || name.hasSuffix("_wood") || name.contains("hyphae") { foundLog = true; break }
                    if name.contains("leaves") && d < 5 { queue.append((nx, ny, nz, d + 1)) }
                }
                if foundLog { break }
            }
            if !foundLog {
                world.breakBlockNaturally(x, y, z)
            }
        }
    }

    // fire spread -------------------------------------------------------------------
    blockTickHandlers[Int(B.fire)] = { world, x, y, z, c in
        if !world.rule("doFireTick") { return }
        let below = world.getBlock(x, y - 1, z) >> 4
        let infiniburn = below == Int(B.netherrack) || below == Int(B.magma_block) || below == Int(B.bedrock)
        // rain extinguish
        if world.isRainingAt(x, y, z) && !infiniburn {
            world.setBlock(x, y, z, 0)
            return
        }
        let age = c & 15
        if age < 15 { world.setBlock(x, y, z, Int(cell(B.fire, age + 1)), 2 | 4) }
        // burn neighbors
        var anyFlammable = infiniburn
        for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
            let n = world.getBlock(x + dx, y + dy, z + dz)
            let nid = n >> 4
            if nid == 0 { continue }
            let def = blockDefs[nid]
            if def.flammable > 0 {
                anyFlammable = true
                if farmingRng.nextInt(100) < def.burnOdds {
                    world.setBlock(x + dx, y + dy, z + dz, farmingRng.nextFloat() < 0.75 ? Int(cell(B.fire)) : 0)
                    if nid == Int(B.tnt) {
                        igniteTNT(world, x + dx, y + dy, z + dz)
                    }
                }
            }
        }
        if !anyFlammable && (below == 0 || !blockDefs[below].solid) {
            world.setBlock(x, y, z, 0)
            return
        }
        if age >= 15 && !infiniburn && farmingRng.nextFloat() < 0.3 {
            world.setBlock(x, y, z, 0)
            return
        }
        // spread to nearby flammables
        if world.difficulty > 0 {
            for _ in 0..<3 {
                let tx = x + farmingRng.nextInt(3) - 1
                let ty = y + farmingRng.nextInt(4) - 1
                let tz = z + farmingRng.nextInt(3) - 1
                if world.getBlock(tx, ty, tz) != 0 { continue }
                // flammable neighbor?
                for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                    let def = blockDefs[world.getBlock(tx + dx, ty + dy, tz + dz) >> 4]
                    if def.flammable > 0 && farmingRng.nextInt(200) < def.flammable {
                        world.setBlock(tx, ty, tz, Int(cell(B.fire)))
                        break
                    }
                }
            }
        }
        world.scheduleTick(x, y, z, Int(B.fire), 30 + farmingRng.nextInt(10))
    }
    neighborHandlers[Int(B.fire)] = { world, x, y, z, c, _, _, _ in
        if !world.hasScheduledTick(x, y, z, Int(B.fire)) { world.scheduleTick(x, y, z, Int(B.fire), 30) }
        let below = world.getBlock(x, y - 1, z) >> 4
        if below == 0 || (!blockDefs[below].solid && below != Int(B.netherrack)) {
            var anyNeighbor = false
            for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1), (0, 1, 0)] {
                if blockDefs[world.getBlock(x + dx, y + dy, z + dz) >> 4].flammable > 0 { anyNeighbor = true; break }
            }
            if !anyNeighbor { world.setBlock(x, y, z, 0) }
        }
    }

    // ice / snow -------------------------------------------------------------------
    reg(B.ice) { world, x, y, z, _ in
        if world.lightAt(x, y, z) > 11 {
            world.setBlock(x, y, z, world.dim == .overworld ? Int(cell(B.water, 0)) : 0)
        }
    }
    reg(B.frosted_ice) { world, x, y, z, c in
        let age = c & 3
        if age < 3 { world.setBlock(x, y, z, Int(cell(B.frosted_ice, age + 1))) }
        else { world.setBlock(x, y, z, Int(cell(B.water, 0))) }
    }
    reg(B.snow) { world, x, y, z, _ in
        if world.lightAt(x, y, z) > 11 { world.setBlock(x, y, z, 0) }
    }

    // copper oxidation ----------------------------------------------------------------
    var copperChain: [(String, String)] = []
    for base in ["copper_block", "cut_copper", "cut_copper_stairs", "cut_copper_slab"] {
        let stem = base == "copper_block" ? "copper_block" : base
        copperChain.append((base, "exposed_\(stem)"))
        copperChain.append(("exposed_\(stem)", "weathered_\(stem)"))
        copperChain.append(("weathered_\(stem)", "oxidized_\(stem)"))
    }
    for (from, to) in copperChain {
        guard let fromId = bidOpt(from), let toId = bidOpt(to) else { continue }
        reg(fromId) { world, x, y, z, c in
            if farmingRng.nextFloat() < 0.05 {
                world.setBlock(x, y, z, Int(cell(toId, c & 15)))
            }
        }
    }

    // cane / cactus / bamboo / kelp / vines ---------------------------------------------
    reg(B.sugar_cane) { world, x, y, z, _ in
        if world.getBlock(x, y + 1, z) != 0 { return }
        var h = 1
        while (world.getBlock(x, y - h, z) >> 4) == Int(B.sugar_cane) { h += 1 }
        if h < 3 && farmingRng.nextFloat() < 0.18 { world.setBlock(x, y + 1, z, Int(cell(B.sugar_cane))) }
    }
    reg(B.cactus) { world, x, y, z, _ in
        if world.getBlock(x, y + 1, z) != 0 { return }
        var h = 1
        while (world.getBlock(x, y - h, z) >> 4) == Int(B.cactus) { h += 1 }
        if h < 3 && farmingRng.nextFloat() < 0.18 { world.setBlock(x, y + 1, z, Int(cell(B.cactus))) }
    }
    reg(B.bamboo) { world, x, y, z, _ in
        if world.getBlock(x, y + 1, z) != 0 { return }
        var h = 1
        while (world.getBlock(x, y - h, z) >> 4) == Int(B.bamboo) { h += 1 }
        if h < 14 && farmingRng.nextFloat() < 0.3 {
            world.setBlock(x, y + 1, z, Int(cell(B.bamboo, h > 4 ? 2 | 4 : 1 | 4)))
        }
    }
    reg(B.bamboo_sapling) { world, x, y, z, _ in
        if world.getBlock(x, y + 1, z) == 0 && farmingRng.nextFloat() < 0.3 {
            world.setBlock(x, y, z, Int(cell(B.bamboo, 4)))
            world.setBlock(x, y + 1, z, Int(cell(B.bamboo, 1)))
        }
    }
    reg(B.kelp) { world, x, y, z, c in
        let age = c & 15
        if age >= 14 { return }
        if (world.getBlock(x, y + 1, z) >> 4) == Int(B.water) && farmingRng.nextFloat() < 0.14 {
            world.setBlock(x, y, z, Int(cell(B.kelp_plant)))
            world.setBlock(x, y + 1, z, Int(cell(B.kelp, age + 1)))
        }
    }
    reg(B.vine) { world, x, y, z, c in
        if farmingRng.nextFloat() > 0.25 { return }
        // grow downward
        if world.getBlock(x, y - 1, z) == 0 {
            world.setBlock(x, y - 1, z, Int(cell(B.vine, c & 15)))
        }
    }
    for vines in [B.weeping_vines, B.twisting_vines] {
        reg(vines) { world, x, y, z, _ in
            let dir = vines == B.weeping_vines ? -1 : 1
            if world.getBlock(x, y + dir, z) == 0 && farmingRng.nextFloat() < 0.1 {
                world.setBlock(x, y + dir, z, Int(cell(vines)))
            }
        }
    }
    reg(B.cave_vines) { world, x, y, z, c in
        if world.getBlock(x, y - 1, z) == 0 && farmingRng.nextFloat() < 0.1 {
            world.setBlock(x, y, z, Int(cell(B.cave_vines_plant, c & 8)))
            world.setBlock(x, y - 1, z, Int(cell(B.cave_vines, farmingRng.nextFloat() < 0.11 ? 8 : 0)))
        } else if (c & 8) == 0 && farmingRng.nextFloat() < 0.06 {
            world.setBlock(x, y, z, Int(cell(B.cave_vines, 8)))
        }
    }

    // azalea growth
    for az in [B.azalea, B.flowering_azalea] {
        reg(az) { world, x, y, z, _ in
            if world.lightAt(x, y, z) >= 9 && farmingRng.nextFloat() < 0.1 {
                let sink = WorldSink(world)
                world.setBlock(x, y, z, 0)
                genAzaleaTree(sink, &farmingRng, x, y, z)
            }
        }
    }

    // turtle eggs / frogspawn / sniffer egg ----------------------------------------
    reg(B.turtle_egg) { world, x, y, z, c in
        let hatch = (c >> 2) & 3
        if !world.isDay() && farmingRng.nextFloat() < 0.2 {
            if hatch < 2 {
                world.setBlock(x, y, z, Int(cell(B.turtle_egg, (c & 3) | ((hatch + 1) << 2))))
                world.hooks.playSound("entity.turtle.egg_crack", Double(x) + 0.5, Double(y), Double(z) + 0.5, 0.7, 1)
            } else {
                let count = (c & 3) + 1
                world.setBlock(x, y, z, 0)
                world.hooks.playSound("entity.turtle.egg_hatch", Double(x) + 0.5, Double(y), Double(z) + 0.5, 0.7, 1)
                for _ in 0..<count {
                    _ = spawnMob(world, "turtle", Double(x) + 0.3 + farmingRng.nextFloat() * 0.4, Double(y), Double(z) + 0.3 + farmingRng.nextFloat() * 0.4, SpawnOpts(baby: true))
                }
            }
        }
    }
    reg(B.frogspawn) { world, x, y, z, _ in
        if farmingRng.nextFloat() < 0.25 {
            world.setBlock(x, y, z, 0)
            // baseline: rng-in-loop-condition — rerolls every iteration check
            var i = 0
            while i < 3 + farmingRng.nextInt(4) {
                _ = spawnMob(world, "tadpole", Double(x) + farmingRng.nextFloat(), Double(y) - 0.5, Double(z) + farmingRng.nextFloat(), SpawnOpts())
                i += 1
            }
        }
    }
    reg(B.sniffer_egg) { world, x, y, z, c in
        let crack = c & 3
        let onMoss = (world.getBlock(x, y - 1, z) >> 4) == Int(B.moss_block)
        if farmingRng.nextFloat() < (onMoss ? 0.3 : 0.15) {
            if crack < 2 {
                world.setBlock(x, y, z, Int(cell(B.sniffer_egg, crack + 1)))
                world.hooks.playSound("entity.sniffer.egg_crack", Double(x) + 0.5, Double(y), Double(z) + 0.5, 0.7, 1)
            } else {
                world.setBlock(x, y, z, 0)
                _ = spawnMob(world, "sniffer", Double(x) + 0.5, Double(y), Double(z) + 0.5, SpawnOpts(baby: true))
                world.hooks.playSound("entity.sniffer.egg_hatch", Double(x) + 0.5, Double(y), Double(z) + 0.5, 1, 1)
            }
        }
    }

    // amethyst growth ----------------------------------------------------------------
    reg(B.budding_amethyst) { world, x, y, z, _ in
        if farmingRng.nextFloat() > 0.2 { return }
        let f = farmingRng.nextInt(6)
        let dx = [0, 0, 0, 0, -1, 1][f], dy = [-1, 1, 0, 0, 0, 0][f], dz = [0, 0, -1, 1, 0, 0][f]
        let target = world.getBlock(x + dx, y + dy, z + dz)
        let tid = target >> 4
        var next = -1
        if tid == 0 { next = Int(B.small_amethyst_bud) }
        else if tid == Int(B.small_amethyst_bud) { next = Int(B.medium_amethyst_bud) }
        else if tid == Int(B.medium_amethyst_bud) { next = Int(B.large_amethyst_bud) }
        else if tid == Int(B.large_amethyst_bud) { next = Int(B.amethyst_cluster) }
        if next >= 0 {
            world.setBlock(x + dx, y + dy, z + dz, Int(cell(UInt16(next), f ^ 1)))
            world.hooks.playSound("block.amethyst_cluster.step", Double(x + dx), Double(y + dy), Double(z + dz), 0.5, 1)
        }
    }

    // pointed dripstone: growth + dripping into cauldrons ----------------------------
    reg(B.pointed_dripstone) { world, x, y, z, c in
        let pointingDown = (c & 1) != 0
        if !pointingDown { return }
        // find water above the ceiling block
        var ceilY = y
        while (world.getBlock(x, ceilY, z) >> 4) == Int(B.pointed_dripstone) { ceilY += 1 }
        let aboveCeil = world.getBlock(x, ceilY + 1, z) >> 4
        let fluid: String? = aboveCeil == Int(B.water) ? "water" : aboveCeil == Int(B.lava) ? "lava" : nil
        if farmingRng.nextFloat() < 0.12 {
            world.hooks.addParticles(fluid == "lava" ? "drip_lava" : "drip_water", Double(x) + 0.5, Double(y) - 0.3, Double(z) + 0.5, 1, 0.05, 0)
        }
        guard let fluid else { return }
        // drip into cauldron below
        if farmingRng.nextFloat() < 0.06 {
            for dy in 1..<11 {
                let below = world.getBlock(x, y - dy, z)
                let bidv = below >> 4
                if bidv == 0 { continue }
                if bidv == Int(B.cauldron) {
                    let level = below & 3
                    let kind = (below >> 2) & 3
                    if fluid == "water" && (level == 0 || kind == 0) && level < 3 {
                        world.setBlock(x, y - dy, z, Int(cell(B.cauldron, (level + 1) | (0 << 2))))
                    } else if fluid == "lava" && level == 0 {
                        world.setBlock(x, y - dy, z, Int(cell(B.cauldron, 3 | (1 << 2))))
                    }
                }
                break
            }
        }
        // grow longer (rare, water only)
        if fluid == "water" && farmingRng.nextFloat() < 0.011 {
            let tip = world.getBlock(x, y - 1, z)
            if tip == 0 {
                world.setBlock(x, y, z, Int(cell(B.pointed_dripstone, 1 | (1 << 1))))
                world.setBlock(x, y - 1, z, Int(cell(B.pointed_dripstone, 1 | (0 << 1))))
            }
        }
    }

    // chorus flower growth ----------------------------------------------------------
    reg(B.chorus_flower) { world, x, y, z, c in
        let age = c & 7
        if age >= 5 { return }
        let above = world.getBlock(x, y + 1, z)
        if above == 0 && farmingRng.nextFloat() < 0.3 {
            // grow up or branch
            var height = 1
            while (world.getBlock(x, y - height, z) >> 4) == Int(B.chorus_plant) { height += 1 }
            if height < 4 && farmingRng.nextFloat() < 0.7 {
                world.setBlock(x, y, z, Int(cell(B.chorus_plant)))
                world.setBlock(x, y + 1, z, Int(cell(B.chorus_flower, age)))
            } else {
                // branch sideways
                world.setBlock(x, y, z, Int(cell(B.chorus_plant)))
                var branched = false
                for _ in 0..<4 {
                    let f = farmingRng.nextInt(4)
                    let dx = [1, -1, 0, 0][f], dz = [0, 0, 1, -1][f]
                    if world.getBlock(x + dx, y, z + dz) == 0 {
                        world.setBlock(x + dx, y, z + dz, Int(cell(B.chorus_flower, age + 1)))
                        branched = true
                    }
                }
                if !branched { world.setBlock(x, y, z, Int(cell(B.chorus_flower, 5))) }
            }
        }
    }

    // gravity blocks (scheduled by neighbor updates in World) -------------------------
    let fallTick: BlockTickFn = { world, x, y, z, c in
        let below = world.getBlock(x, y - 1, z)
        let bidv = below >> 4
        if bidv == 0 || blockDefs[bidv].replaceable || bidv == Int(B.water) || bidv == Int(B.lava) || bidv == Int(B.fire) {
            world.setBlock(x, y, z, 0)
            let fb = FallingBlockEntity(world: world)
            fb.setPos(Double(x) + 0.5, Double(y), Double(z) + 0.5)
            fb.blockCell = c
            world.addEntity(fb)
        }
    }
    let gravityBlocks = ["sand", "red_sand", "gravel", "suspicious_sand", "suspicious_gravel", "anvil", "chipped_anvil", "damaged_anvil", "dragon_egg"]
    for grav in gravityBlocks {
        blockTickHandlers[Int(bid(grav))] = fallTick
    }
    for c in COLORS {
        blockTickHandlers[Int(bid("\(c)_concrete_powder"))] = fallTick
    }
    let fallTickSchedule: NeighborFn = { world, x, y, z, c, _, _, _ in
        world.scheduleTick(x, y, z, c >> 4, 2)
    }
    // concrete powder + water = concrete (neighbor update)
    for col in COLORS {
        let concrete = bid("\(col)_concrete")
        neighborHandlers[Int(bid("\(col)_concrete_powder"))] = { world, x, y, z, c, nx, ny, nz in
            for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 0, -1)] {
                if (world.getBlock(x + dx, y + dy, z + dz) >> 4) == Int(B.water) {
                    world.setBlock(x, y, z, Int(cell(concrete)))
                    return
                }
            }
            fallTickSchedule(world, x, y, z, c, nx, ny, nz)
        }
    }
    for grav in gravityBlocks {
        neighborHandlers[Int(bid(grav))] = fallTickSchedule
    }
}

// =============================================================================
// SUPPORT POPS — vanilla neighbor-update behavior: plants/layers break (with
// drops) when the block they stand on vanishes. Cascades up columns
// (sugarcane/bamboo/cactus/kelp) because each pop re-notifies its neighbors.
// =============================================================================

/// break a block from a neighbor update — no player, no tool, normal drops
public func popBlock(_ world: World, _ x: Int, _ y: Int, _ z: Int) {
    let c = world.getBlock(x, y, z)
    let id = c >> 4
    if id == 0 { return }
    let def = blockDefs[id]
    world.hooks.playSound("block." + def.sound + ".break", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.8, 1)
    world.hooks.addParticles("block", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 10, 0.4, c)
    world.setBlock(x, y, z, 0)
    if !world.rule("doTileDrops") { return }
    let ctx = DropCtx(fortune: 0, silkTouch: false, toolType: .none, toolTier: 0,
                      shears: false, random: { gameRng.nextFloat() })
    let drops: [Drop]
    if let dropsFn = def.drops {
        drops = dropsFn(c & 15, ctx)
    } else if let itemId = blockToItem[id] as Int32?, itemId >= 0 {
        drops = [Drop(itemDefs[Int(itemId)].name)]
    } else {
        drops = []
    }
    for d in drops {
        guard let itemId = iidOpt(d.item) else { continue }
        var count = d.countMin
        if d.countMax > d.countMin { count = d.countMin + gameRng.nextInt(d.countMax - d.countMin + 1) }
        if d.chance != 1 && gameRng.nextFloat() > d.chance { continue }
        if count > 0 { spawnItem(world, Double(x) + 0.5, Double(y) + 0.3, Double(z) + 0.5, ItemStack(itemId, count)) }
    }
}

@inline(__always)
private func isDirtish(_ id: Int) -> Bool {
    id == Int(B.grass_block) || id == Int(B.dirt) || id == Int(B.coarse_dirt)
        || id == Int(B.podzol) || id == Int(B.mycelium) || id == Int(B.rooted_dirt)
        || id == Int(B.moss_block) || id == Int(B.mud) || id == Int(B.farmland)
        || id == Int(B.muddy_mangrove_roots)
}
@inline(__always)
private func isSandy(_ id: Int) -> Bool {
    id == Int(B.sand) || id == Int(B.red_sand) || id == Int(B.gravel)
        || id == Int(B.suspicious_sand) || id == Int(B.suspicious_gravel)
}

/// can this cell keep standing where it is?
private func canSurvive(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ c: Int) -> Bool {
    let id = c >> 4
    let below = world.getBlock(x, y - 1, z) >> 4
    if id == Int(B.sugar_cane) {
        if below == id { return true }
        guard isDirtish(below) || isSandy(below) else { return false }
        // needs water (or frosted ice) next to the supporting block
        for (dx, dz) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let n = world.getBlock(x + dx, y - 1, z + dz) >> 4
            if n == Int(B.water) || n == Int(B.frosted_ice) { return true }
        }
        return false
    }
    if id == Int(B.cactus) {
        guard below == id || isSandy(below) else { return false }
        // no solid horizontal neighbors at the base
        for (dx, dz) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let n = world.getBlock(x + dx, y, z + dz) >> 4
            if n != 0 && blockDefs[n].solid { return false }
        }
        return true
    }
    if id == Int(B.bamboo) || id == Int(B.bamboo_sapling) {
        return below == Int(B.bamboo) || below == Int(B.bamboo_sapling)
            || isDirtish(below) || isSandy(below)
    }
    if id == Int(B.kelp) || id == Int(B.kelp_plant) {
        return below == Int(B.kelp) || below == Int(B.kelp_plant)
            || (below != 0 && blockDefs[below].solid)
    }
    if id == Int(B.lily_pad) || id == Int(B.frogspawn) {
        return below == Int(B.water) || below == Int(B.ice) || below == Int(B.frosted_ice)
    }
    let shape = Shape(rawValue: SHAPE_OF[id]) ?? .cube
    if shape == .crop || id == Int(B.melon_stem) || id == Int(B.pumpkin_stem) {
        return below == Int(B.farmland)
    }
    if shape == .layer || shape == .carpet || shape == .pressurePlate {
        return below != 0 && blockDefs[below].solid
    }
    // generic floor plants (flowers, saplings, grasses, mushrooms, roots…)
    return below != 0 && (blockDefs[below].solid || isDirtish(below))
}

public func registerSupportPops() {
    let popHandler: NeighborFn = { world, x, y, z, c, _, fy, _ in
        // only support-relevant updates (below for everything; sides matter
        // for cactus, so it re-checks on any neighbor change)
        let id = c >> 4
        if fy != y - 1 && id != Int(B.cactus) { return }
        if !canSurvive(world, x, y, z, c) {
            popBlock(world, x, y, z)
        }
    }
    let floorShapes: Set<Shape> = [.cross, .crop, .tallCross, .rootsShape, .netherWart,
                                   .sweetBerry, .bambooSapling, .smallDripleafShape,
                                   .pitcherCropShape, .lilyPad, .frogspawn, .bamboo,
                                   .layer, .carpet, .propagule]
    for def in blockDefs where def.id != 0 {
        let shape = Shape(rawValue: SHAPE_OF[def.id]) ?? .cube
        let special = def.id == Int(B.cactus) || def.id == Int(B.sugar_cane)
        if (floorShapes.contains(shape) || special), neighborHandlers[def.id] == nil {
            neighborHandlers[def.id] = popHandler
        }
    }
}
