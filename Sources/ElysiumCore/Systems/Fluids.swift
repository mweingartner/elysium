// Water & lava flow — Registered as scheduled-tick +
// neighbor handlers. Meta: bits0-2 level (0 = source, 1..7 flowing), bit3 = falling.

import Foundation

private let HDX = [0, 0, -1, 1]
private let HDZ = [-1, 1, 0, 0]

private func tickRate(_ world: World, _ fluidId: Int) -> Int {
    if fluidId == Int(B.water) { return 5 }
    return world.dim == .nether ? 10 : 30
}
private func maxSpread(_ world: World, _ fluidId: Int) -> Int {
    if fluidId == Int(B.water) { return 7 }
    return world.dim == .nether ? 7 : 3
}
private func levelStep(_ world: World, _ fluidId: Int) -> Int {
    if fluidId == Int(B.water) { return 1 }
    return world.dim == .nether ? 1 : 2
}

private func canReplace(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ fluidId: Int) -> Bool {
    let c = world.getBlock(x, y, z)
    let id = c >> 4
    if id == 0 { return true }
    if id == fluidId { return true }
    if id == Int(B.water) || id == Int(B.lava) { return true } // interaction handled separately
    let def = blockDefs[id]
    if REPLACEABLE[id] == 1 { return true }
    if !def.solid && def.piston == .destroy { return true }
    return false
}

private func destroyForFluid(_ world: World, _ x: Int, _ y: Int, _ z: Int) {
    let c = world.getBlock(x, y, z)
    let id = c >> 4
    if id == 0 || id == Int(B.water) || id == Int(B.lava) { return }
    world.breakBlockNaturally(x, y, z)
}

/// effective fluid level at cell for compare: source=0 best; returns -1 if not this fluid
private func levelOf(_ c: Int, _ fluidId: Int) -> Int {
    if (c >> 4) != fluidId { return -1 }
    if c & 8 != 0 { return 0 } // falling acts like source for downward feed
    return c & 7
}

private func lavaWaterContact(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ lavaCell: Int) -> Bool {
    // returns true if converted
    for d in 0..<6 {
        let nx = x + [0, 0, 0, 0, -1, 1][d]
        let ny = y + [-1, 1, 0, 0, 0, 0][d]
        let nz = z + [0, 0, -1, 1, 0, 0][d]
        if d == 0 { continue } // water below lava doesn't convert the lava
        if (world.getBlock(nx, ny, nz) >> 4) == Int(B.water) {
            let isSource = (lavaCell & 15) == 0
            world.setBlock(x, y, z, Int(cell(isSource ? B.obsidian : B.cobblestone)))
            world.hooks.playSound("block.fire.extinguish", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.5, 1)
            world.hooks.addParticles("smoke", Double(x) + 0.5, Double(y) + 1, Double(z) + 0.5, 8, 0.4, 0)
            return true
        }
    }
    return false
}

private func fluidTick(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ c: Int) {
    let fluidId = c >> 4
    let meta = c & 15
    let level = meta & 7
    let falling = (meta & 8) != 0
    let rate = tickRate(world, fluidId)
    let step = levelStep(world, fluidId)
    let maxS = maxSpread(world, fluidId)

    if fluidId == Int(B.lava) && lavaWaterContact(world, x, y, z, c) { return }

    // 1. verify this block is still fed (non-sources)
    if level > 0 || falling {
        var fed = false
        let above = world.getBlock(x, y + 1, z)
        if (above >> 4) == fluidId { fed = true }
        if !fed {
            for d in 0..<4 {
                let n = world.getBlock(x + HDX[d], y, z + HDZ[d])
                let nl = levelOf(n, fluidId)
                if nl >= 0 && nl < level { fed = true; break }
                if nl == 0 && (n & 15) == 0 { fed = true; break }
            }
        }
        if !fed {
            // decay
            let newLevel = level + step
            if newLevel > maxS || falling {
                world.setBlock(x, y, z, 0)
            } else {
                world.setBlock(x, y, z, Int(cell(UInt16(fluidId), newLevel)))
                world.scheduleTick(x, y, z, fluidId, rate)
            }
            return
        }
        // falling block with no fluid above turns into spreading flow
        if falling && (above >> 4) != fluidId {
            world.setBlock(x, y, z, Int(cell(UInt16(fluidId), min(maxS, 1))))
            world.scheduleTick(x, y, z, fluidId, rate)
            return
        }
    }

    // 2. infinite water: 2+ adjacent sources over solid/source
    if fluidId == Int(B.water) && level > 0 && !falling {
        var sources = 0
        for d in 0..<4 {
            let n = world.getBlock(x + HDX[d], y, z + HDZ[d])
            if (n >> 4) == Int(B.water) && (n & 15) == 0 { sources += 1 }
        }
        if sources >= 2 {
            let below = world.getBlock(x, y - 1, z)
            let belowId = below >> 4
            if (belowId != 0 && blockDefs[belowId].solid) || ((below >> 4) == Int(B.water) && (below & 15) == 0) {
                world.setBlock(x, y, z, Int(cell(B.water, 0)))
            }
        }
    }

    let selfCell = world.getBlock(x, y, z)
    if (selfCell >> 4) != fluidId { return }
    let selfLevel = selfCell & 7
    let selfFalling = (selfCell & 8) != 0

    // 3. flow down
    let below = world.getBlock(x, y - 1, z)
    let belowId = below >> 4
    if canReplace(world, x, y - 1, z, fluidId) && belowId != fluidId {
        if fluidId == Int(B.water) && belowId == Int(B.lava) {
            let isSrc = (below & 15) == 0
            world.setBlock(x, y - 1, z, Int(cell(isSrc ? B.obsidian : B.cobblestone)))
            world.hooks.playSound("block.fire.extinguish", Double(x) + 0.5, Double(y) - 0.5, Double(z) + 0.5, 0.5, 1)
            return
        }
        if fluidId == Int(B.lava) && belowId == Int(B.water) {
            world.setBlock(x, y - 1, z, Int(cell(B.stone)))
            world.hooks.playSound("block.fire.extinguish", Double(x) + 0.5, Double(y) - 0.5, Double(z) + 0.5, 0.5, 1)
            return
        }
        if belowId != 0 && belowId != fluidId { destroyForFluid(world, x, y - 1, z) }
        world.setBlock(x, y - 1, z, Int(cell(UInt16(fluidId), 8 | 1)))
        world.scheduleTick(x, y - 1, z, fluidId, rate)
        return // water prefers falling; doesn't spread sideways while over a hole
    }
    if belowId == fluidId {
        // keep feeding downward; sources also spread sideways
        if selfLevel != 0 && !selfFalling { return }
    }

    // 4. spread horizontally (path-seek toward nearest drop within 4)
    let spreadLevel = selfFalling ? step : selfLevel + step
    if spreadLevel > maxS { return }
    var dists = [99, 99, 99, 99]
    var best = 99
    for d in 0..<4 {
        let nx = x + HDX[d], nz = z + HDZ[d]
        if !canReplace(world, nx, y, nz, fluidId) { continue }
        dists[d] = dropDistance(world, nx, y, nz, fluidId, 1)
        if dists[d] < best { best = dists[d] }
    }
    for d in 0..<4 {
        if dists[d] != best { continue }
        let nx = x + HDX[d], nz = z + HDZ[d]
        if !canReplace(world, nx, y, nz, fluidId) { continue }
        let ncell = world.getBlock(nx, y, nz)
        let nid = ncell >> 4
        if nid == fluidId {
            let nl = ncell & 7
            if (ncell & 8) == 0 && nl <= spreadLevel { continue } // already as strong
        }
        if fluidId == Int(B.water) && nid == Int(B.lava) {
            world.setBlock(nx, y, nz, Int(cell((ncell & 15) == 0 ? B.obsidian : B.cobblestone)))
            continue
        }
        if fluidId == Int(B.lava) && nid == Int(B.water) {
            world.setBlock(nx, y, nz, Int(cell(B.cobblestone)))
            continue
        }
        if nid != 0 && nid != fluidId { destroyForFluid(world, nx, y, nz) }
        world.setBlock(nx, y, nz, Int(cell(UInt16(fluidId), spreadLevel)))
        world.scheduleTick(nx, y, nz, fluidId, rate)
    }
}

/// distance (1..4) to nearest hole the fluid could fall into; 99 if none
private func dropDistance(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ fluidId: Int, _ depth: Int) -> Int {
    if canReplace(world, x, y - 1, z, fluidId) && (world.getBlock(x, y - 1, z) >> 4) != fluidId { return depth }
    if depth >= 4 { return 99 }
    var best = 99
    for d in 0..<4 {
        let nx = x + HDX[d], nz = z + HDZ[d]
        if !canReplace(world, nx, y, nz, fluidId) { continue }
        let r = dropDistance(world, nx, y, nz, fluidId, depth + 1)
        if r < best { best = r }
    }
    return best
}

private func scheduleFluid(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ c: Int) {
    world.scheduleTick(x, y, z, c >> 4, tickRate(world, c >> 4))
}

private var fluidsRegistered = false
public func registerFluidHandlers() {
    if fluidsRegistered { return }
    fluidsRegistered = true
    blockTickHandlers[Int(B.water)] = fluidTick
    blockTickHandlers[Int(B.lava)] = fluidTick
    neighborHandlers[Int(B.water)] = { w, x, y, z, c, _, _, _ in scheduleFluid(w, x, y, z, c) }
    neighborHandlers[Int(B.lava)] = { w, x, y, z, c, _, _, _ in scheduleFluid(w, x, y, z, c) }
}
