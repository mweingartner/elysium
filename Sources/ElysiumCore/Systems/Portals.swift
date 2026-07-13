// Portals — nether portal frame validation +
// ignition, portal search/creation on the far side, end portal travel
// positions, end exit/gateway activation.

import Foundation

private struct Frame {
    let x0: Int, y0: Int, w: Int, h: Int, zc: Int, xc: Int
}

/// try to ignite a nether portal with fire placed at (x,y,z) inside a frame
@discardableResult
public func tryIgnitePortal(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    for axis in [0, 1] {
        if let frame = findPortalFrame(world, x, y, z, axis) {
            for dy in 0..<frame.h {
                for dw in 0..<frame.w {
                    if axis == 0 { world.setBlock(frame.x0 + dw, frame.y0 + dy, frame.zc, Int(cell(B.nether_portal, 0))) }
                    else { world.setBlock(frame.xc, frame.y0 + dy, frame.x0 + dw, Int(cell(B.nether_portal, 1))) }
                }
            }
            world.hooks.playSound("block.portal.trigger", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            return true
        }
    }
    return false
}

private func findPortalFrame(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ axis: Int) -> Frame? {
    func isObsidian(_ bx: Int, _ by: Int, _ bz: Int) -> Bool {
        (world.getBlock(bx, by, bz) >> 4) == Int(B.obsidian)
    }
    func isInterior(_ bx: Int, _ by: Int, _ bz: Int) -> Bool {
        let c = world.getBlock(bx, by, bz) >> 4
        return c == 0 || c == Int(B.fire) || c == Int(B.nether_portal)
    }
    // descend
    var by = y
    while isInterior(x, by - 1, z) && by > world.info.minY + 1 { by -= 1 }
    if !isObsidian(x, by - 1, z) { return nil }
    // find left edge
    let start = axis == 0 ? x : z
    var probe = start
    for _ in 0..<22 {
        let px = axis == 0 ? probe - 1 : x
        let pz = axis == 0 ? z : probe - 1
        if isInterior(px, by, pz) { probe -= 1 }
        else { break }
    }
    let leftX = axis == 0 ? probe : x
    let leftZ = axis == 0 ? z : probe
    if !isObsidian(axis == 0 ? leftX - 1 : x, by, axis == 0 ? z : leftZ - 1) { return nil }
    // width
    var w = 0
    while w < 21 {
        let px = axis == 0 ? leftX + w : x
        let pz = axis == 0 ? z : leftZ + w
        if isInterior(px, by, pz) {
            if !isObsidian(px, by - 1, pz) { return nil }
            w += 1
        } else { break }
    }
    if w < 2 || w > 21 { return nil }
    if !isObsidian(axis == 0 ? leftX + w : x, by, axis == 0 ? z : leftZ + w) { return nil }
    // height
    var h = 0
    outer: while h < 21 {
        for dw in 0..<w {
            let px = axis == 0 ? leftX + dw : x
            let pz = axis == 0 ? z : leftZ + dw
            if !isInterior(px, by + h, pz) { break outer }
            // side rails
            if dw == 0 && !isObsidian(axis == 0 ? leftX - 1 : x, by + h, axis == 0 ? z : leftZ - 1) { break outer }
            if dw == w - 1 && !isObsidian(axis == 0 ? leftX + w : x, by + h, axis == 0 ? z : leftZ + w) { break outer }
        }
        h += 1
    }
    if h < 3 || h > 21 { return nil }
    // top rail
    for dw in 0..<w {
        let px = axis == 0 ? leftX + dw : x
        let pz = axis == 0 ? z : leftZ + dw
        if !isObsidian(px, by + h, pz) { return nil }
    }
    return Frame(x0: axis == 0 ? leftX : leftZ, y0: by, w: w, h: h, zc: z, xc: x)
}

/// find or build a portal near target coords in destination world; returns spawn pos
public func findOrCreatePortal(_ dest: World, _ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
    if let existing = dest.findPortalNear(ifloor(x), ifloor(y), ifloor(z), 8, Int(B.nether_portal)) {
        return (Double(existing.0) + 0.5, Double(existing.1), Double(existing.2) + 0.5)
    }
    // build a fresh portal on a platform
    let px = ifloor(x), pz = ifloor(z)
    var py = max(dest.info.minY + 16, min(dest.info.minY + dest.info.height - 24, dest.surfaceY(px, pz)))
    if dest.dim == .nether {
        // find an air pocket
        py = 32
        for ty in 36..<96 {
            if dest.getBlock(px, ty, pz) == 0 && dest.getBlock(px, ty + 1, pz) == 0 && dest.getBlock(px, ty + 2, pz) == 0 {
                py = ty
                break
            }
        }
    }
    // platform + frame (axis X)
    for dz in -1...2 {
        for dx in -1...3 {
            dest.setBlock(px + dx, py - 1, pz + dz, Int(cell(B.obsidian)))
            for dy in 0..<5 {
                if dz == 0 { continue }
                dest.setBlock(px + dx, py + dy, pz + dz, 0)
            }
        }
    }
    for dy in 0..<5 {
        for dx in 0...3 {
            let isFrame = dy == 0 || dy == 4 || dx == 0 || dx == 3
            dest.setBlock(px + dx, py + dy, pz, isFrame ? Int(cell(B.obsidian)) : Int(cell(B.nether_portal, 0)))
        }
    }
    return (Double(px) + 1.5, Double(py + 1), Double(pz) + 0.5)
}

/// activate the End exit portal (after dragon death)
public func activateEndPortal(_ world: World) {
    // the fountain (gen/end) is solid bedrock at py=62; the inner ring becomes
    // portal surface, the d=4 rim and corner cells stay bedrock
    let py = 62
    for dz in -3...3 {
        for dx in -3...3 {
            let d = abs(dx) + abs(dz)
            if d >= 1 && d <= 3 && !(abs(dx) == 2 && abs(dz) == 2) {
                world.setBlock(dx, py, dz, Int(cell(B.end_portal)))
            }
        }
    }
    // dragon egg rests on the bedrock pillar top, replacing the torch
    world.setBlock(0, py + 4, 0, Int(cell(B.dragon_egg)))
}

/// spawn an end gateway after a dragon kill
public func spawnEndGateway(_ world: World, _ index: Int) {
    let ang = Double(index) / 20 * .pi * 2
    let gx = Int(detRound(detCos(ang) * 96))
    let gz = Int(detRound(detSin(ang) * 96))
    let gy = 75
    // bedrock shell with gateway core
    for (dx, dy, dz) in [(0, 1, 0), (0, -1, 0), (1, 0, 0), (-1, 0, 0), (0, 0, 1), (0, 0, -1)] {
        world.setBlock(gx + dx, gy + dy, gz + dz, Int(cell(B.bedrock)))
    }
    world.setBlock(gx, gy, gz, Int(cell(B.end_gateway)))
    let be = BlockEntityData(type: "end_gateway", x: gx, y: gy, z: gz)
    be.exitX = gx * 12
    be.exitY = 70
    be.exitZ = gz * 12
    be.exactTeleport = false
    world.setBlockEntity(be)
}

/// obsidian platform in the End for arriving players
@discardableResult
public func buildEndSpawnPlatform(_ world: World) -> (Double, Double, Double) {
    let px = 100, py = 48, pz = 0
    for dz in -2...2 {
        for dx in -2...2 {
            world.setBlock(px + dx, py, pz + dz, Int(cell(B.obsidian)))
            for dy in 1...3 { world.setBlock(px + dx, py + dy, pz + dz, 0) }
        }
    }
    return (Double(px) + 0.5, Double(py + 1), Double(pz) + 0.5)
}
