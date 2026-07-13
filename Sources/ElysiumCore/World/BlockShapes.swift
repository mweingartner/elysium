// Geometry for every block shape — Collision
// boxes and outline boxes in block-local [0,1] space, neighbor-aware
// (fences, panes, walls, stairs). Used by physics, raycasting and the mesher.

import Foundation

public typealias CellGetter = (Int, Int, Int) -> Int

@inline(__always) public func aabb(_ x0: Double, _ y0: Double, _ z0: Double, _ x1: Double, _ y1: Double, _ z1: Double) -> AABB {
    AABB(x0, y0, z0, x1, y1, z1)
}

private let FULL = aabb(0, 0, 0, 1, 1, 1)

/// facing index (0=N -z, 1=S +z, 2=W -x, 3=E +x) → delta
public let FACE_DX = [0, 0, -1, 1]
public let FACE_DZ = [-1, 1, 0, 0]
public let FACE_OPP = [1, 0, 3, 2]

@inline(__always) private func shapeOf(_ id: Int) -> Shape { Shape(rawValue: SHAPE_OF[id])! }

/// Is the given face (Dir: 0=bottom, 1=top, 2-5 sides) of this block solid/full?
public func sturdyFace(_ cell: Int, _ face: Int) -> Bool {
    let id = cell >> 4
    if FULL_CUBE[id] == 1 { return blockDefs[id].solid }
    if face == 1 { return sturdyTop(cell) }
    if face == 0 { return sturdyBottom(cell) }
    return sturdySide(cell)
}
/// can a torch/plant/etc stand on top of this cell?
public func sturdyTop(_ cell: Int) -> Bool {
    let id = cell >> 4, meta = cell & 15
    if FULL_CUBE[id] == 1 && blockDefs[id].solid { return true }
    let shape = shapeOf(id)
    if shape == .slab { return (meta & 3) != 0 } // top slab or double
    if shape == .stairs { return (meta & 4) != 0 }
    if shape == .farmland || shape == .path || shape == .composter || shape == .daylightSensor { return true }
    if id == Int(B.soul_sand) || id == Int(B.mud) || id == Int(B.honey_block) { return true }
    if shape == .hopper { return true }
    return false
}
public func sturdyBottom(_ cell: Int) -> Bool {
    let id = cell >> 4, meta = cell & 15
    if FULL_CUBE[id] == 1 && blockDefs[id].solid { return true }
    let shape = shapeOf(id)
    if shape == .slab { return (meta & 3) != 1 }
    if shape == .stairs { return (meta & 4) == 0 }
    return false
}
public func sturdySide(_ cell: Int) -> Bool {
    let id = cell >> 4
    return FULL_CUBE[id] != 0 && blockDefs[id].solid
}

// connection tests -----------------------------------------------------------
public func fenceConnects(_ selfId: Int, _ other: Int, _ dirFacing: Int) -> Bool {
    let oid = other >> 4
    let oshape = shapeOf(oid)
    if oshape == .fence {
        let selfNether = selfId == Int(B.nether_brick_fence)
        let otherNether = oid == Int(B.nether_brick_fence)
        return selfNether == otherNether
    }
    if oshape == .fenceGate {
        let gFacing = other & 3
        // gate connects on its sides (perpendicular axis)
        let gateAxisX = gFacing >= 2 // facing W/E → gate spans N-S
        let dirIsX = dirFacing >= 2
        return gateAxisX != dirIsX
    }
    return sturdySide(other)
}
public func wallConnects(_ other: Int, _ dirFacing: Int) -> Bool {
    let oid = other >> 4
    let oshape = shapeOf(oid)
    if oshape == .wall || oshape == .pane || oshape == .bars || oshape == .fence { return true }
    if oshape == .fenceGate {
        let gFacing = other & 3
        let gateAxisX = gFacing >= 2
        return gateAxisX != (dirFacing >= 2)
    }
    return sturdySide(other)
}
public func paneConnects(_ selfId: Int, _ other: Int) -> Bool {
    let oid = other >> 4
    let oshape = shapeOf(oid)
    if oshape == .pane || oshape == .bars || oshape == .wall { return true }
    return sturdySide(other)
}

public enum ConnKind { case fence, wall, pane }

/// 4-bit mask NSWE of connections
public func connMask(_ cell: Int, _ get: CellGetter, _ kind: ConnKind) -> Int {
    let id = cell >> 4
    var m = 0
    for f in 0..<4 {
        let other = get(FACE_DX[f], 0, FACE_DZ[f])
        let ok: Bool
        switch kind {
        case .fence: ok = fenceConnects(id, other, f)
        case .wall: ok = wallConnects(other, f)
        case .pane: ok = paneConnects(id, other)
        }
        if ok { m |= 1 << f }
    }
    return m
}

/// stairs shape: 0 straight, 1 inner-left, 2 inner-right, 3 outer-left, 4 outer-right
public func stairsShapeOf(_ meta: Int, _ get: CellGetter) -> Int {
    let facing = meta & 3, half = meta & 4
    let behind = get(FACE_DX[facing], 0, FACE_DZ[facing])
    if SHAPE_OF[behind >> 4] == Shape.stairs.rawValue && (behind & 4) == half {
        let bf = behind & 3
        if (bf >= 2) != (facing >= 2) { // perpendicular
            let left = leftOf(facing)
            let sideCell = get(FACE_DX[FACE_OPP[bf]], 0, FACE_DZ[FACE_OPP[bf]])
            if !(SHAPE_OF[sideCell >> 4] == Shape.stairs.rawValue && (sideCell & 3) == facing && (sideCell & 4) == half) {
                return bf == left ? 3 : 4 // outer corner
            }
        }
    }
    let front = get(-FACE_DX[facing], 0, -FACE_DZ[facing])
    if SHAPE_OF[front >> 4] == Shape.stairs.rawValue && (front & 4) == half {
        let ff = front & 3
        if (ff >= 2) != (facing >= 2) {
            let left = leftOf(facing)
            let sideCell = get(FACE_DX[ff], 0, FACE_DZ[ff])
            if !(SHAPE_OF[sideCell >> 4] == Shape.stairs.rawValue && (sideCell & 3) == facing && (sideCell & 4) == half) {
                return ff == left ? 1 : 2 // inner corner
            }
        }
    }
    return 0
}
@inline(__always) public func leftOf(_ facing: Int) -> Int {
    // facing N→left=W, S→E, W→S, E→N
    [2, 3, 1, 0][facing]
}
@inline(__always) public func rightOf(_ facing: Int) -> Int {
    [3, 2, 0, 1][facing]
}

// ---------------------------------------------------------------------------
// Boxes
// ---------------------------------------------------------------------------
public func shapeBoxes(_ cell: Int, _ get: CellGetter, _ out: inout [AABB], _ forCollision: Bool) {
    let id = cell >> 4, meta = cell & 15
    let shape = shapeOf(id)
    switch shape {
    case .air, .liquid, .fire, .portalShape, .endPortalShape:
        return
    case .cube:
        if id == Int(B.soul_sand) || id == Int(B.mud) { out.append(aabb(0, 0, 0, 1, 14 / 16, 1)); return }
        if id == Int(B.honey_block) || id == Int(B.powder_snow) {
            if id == Int(B.powder_snow) && forCollision { return } // entities sink (special physics)
            out.append(aabb(1 / 16, 0, 1 / 16, 15 / 16, 15 / 16, 15 / 16))
            return
        }
        out.append(FULL)
    case .cross, .tallCross, .crop, .netherWart, .sweetBerry, .rootsShape, .web,
         .caveVinesShape, .hangingRoots, .sporeBlossom:
        if forCollision { return }
        out.append(aabb(2 / 16, 0, 2 / 16, 14 / 16, 13 / 16, 14 / 16))
    case .slab:
        let t = meta & 3
        if t == 2 { out.append(FULL) }
        else if t == 1 { out.append(aabb(0, 0.5, 0, 1, 1, 1)) }
        else { out.append(aabb(0, 0, 0, 1, 0.5, 1)) }
    case .stairs:
        let facing = meta & 3, top = (meta & 4) != 0
        let sshape = stairsShapeOf(meta, get)
        // base slab
        out.append(top ? aabb(0, 0.5, 0, 1, 1, 1) : aabb(0, 0, 0, 1, 0.5, 1))
        let y0 = top ? 0.0 : 0.5, y1 = top ? 0.5 : 1.0
        func quad(_ f: Int) -> AABB {
            switch f {
            case 0: return aabb(0, y0, 0, 1, y1, 0.5)        // N
            case 1: return aabb(0, y0, 0.5, 1, y1, 1)        // S
            case 2: return aabb(0, y0, 0, 0.5, y1, 1)        // W
            default: return aabb(0.5, y0, 0, 1, y1, 1)       // E
            }
        }
        func corner(_ f1: Int, _ f2: Int) -> AABB {
            let a = quad(f1), b = quad(f2)
            return aabb(max(a.x0, b.x0), y0, max(a.z0, b.z0), min(a.x1, b.x1), y1, min(a.z1, b.z1))
        }
        if sshape == 0 { out.append(quad(facing)) }
        else if sshape == 1 { out.append(quad(facing)); out.append(corner(FACE_OPP[facing], leftOf(facing))) }
        else if sshape == 2 { out.append(quad(facing)); out.append(corner(FACE_OPP[facing], rightOf(facing))) }
        else if sshape == 3 { out.append(corner(facing, leftOf(facing))) }
        else { out.append(corner(facing, rightOf(facing))) }
    case .fence:
        let m = connMask(cell, get, .fence)
        let h = forCollision ? 1.5 : 1.0
        out.append(aabb(6 / 16, 0, 6 / 16, 10 / 16, h, 10 / 16))
        if m & 1 != 0 { out.append(aabb(7 / 16, 0, 0, 9 / 16, h, 6 / 16)) }
        if m & 2 != 0 { out.append(aabb(7 / 16, 0, 10 / 16, 9 / 16, h, 1)) }
        if m & 4 != 0 { out.append(aabb(0, 0, 7 / 16, 6 / 16, h, 9 / 16)) }
        if m & 8 != 0 { out.append(aabb(10 / 16, 0, 7 / 16, 1, h, 9 / 16)) }
    case .wall:
        let m = connMask(cell, get, .wall)
        let h = forCollision ? 1.5 : 1.0
        let above = get(0, 1, 0)
        let post = (above != 0 && (above >> 4) != Int(B.air)) || m == 0 || (m != 3 && m != 12)
        if post { out.append(aabb(4 / 16, 0, 4 / 16, 12 / 16, h, 12 / 16)) }
        let wh = forCollision ? 1.5 : 14.0 / 16
        if m & 1 != 0 { out.append(aabb(5 / 16, 0, 0, 11 / 16, wh, 8 / 16)) }
        if m & 2 != 0 { out.append(aabb(5 / 16, 0, 8 / 16, 11 / 16, wh, 1)) }
        if m & 4 != 0 { out.append(aabb(0, 0, 5 / 16, 8 / 16, wh, 11 / 16)) }
        if m & 8 != 0 { out.append(aabb(8 / 16, 0, 5 / 16, 1, wh, 11 / 16)) }
    case .pane, .bars:
        let m = connMask(cell, get, .pane)
        if m == 0 { out.append(aabb(7 / 16, 0, 7 / 16, 9 / 16, 1, 9 / 16)); return }
        out.append(aabb(7 / 16, 0, 7 / 16, 9 / 16, 1, 9 / 16))
        if m & 1 != 0 { out.append(aabb(7 / 16, 0, 0, 9 / 16, 1, 7 / 16)) }
        if m & 2 != 0 { out.append(aabb(7 / 16, 0, 9 / 16, 9 / 16, 1, 1)) }
        if m & 4 != 0 { out.append(aabb(0, 0, 7 / 16, 7 / 16, 1, 9 / 16)) }
        if m & 8 != 0 { out.append(aabb(9 / 16, 0, 7 / 16, 1, 1, 9 / 16)) }
    case .door:
        // figure facing+open+hinge from both halves
        var lower = meta, upper = meta
        if meta & 8 != 0 { lower = get(0, -1, 0) & 15 }
        else { upper = get(0, 1, 0) & 15 }
        let facing = lower & 3, open = (lower & 4) != 0, hingeRight = (upper & 1) != 0
        let side: Int
        if !open { side = facing }
        else { side = hingeRight ? leftOf(facing) : rightOf(facing) }
        switch side {
        case 0: out.append(aabb(0, 0, 0, 1, 1, 3 / 16))
        case 1: out.append(aabb(0, 0, 13 / 16, 1, 1, 1))
        case 2: out.append(aabb(0, 0, 0, 3 / 16, 1, 1))
        default: out.append(aabb(13 / 16, 0, 0, 1, 1, 1))
        }
    case .trapdoor:
        let facing = meta & 3, open = (meta & 4) != 0, top = (meta & 8) != 0
        if !open {
            out.append(top ? aabb(0, 13 / 16, 0, 1, 1, 1) : aabb(0, 0, 0, 1, 3 / 16, 1))
        } else {
            switch facing {
            case 0: out.append(aabb(0, 0, 13 / 16, 1, 1, 1))
            case 1: out.append(aabb(0, 0, 0, 1, 1, 3 / 16))
            case 2: out.append(aabb(13 / 16, 0, 0, 1, 1, 1))
            default: out.append(aabb(0, 0, 0, 3 / 16, 1, 1))
            }
        }
    case .fenceGate:
        let facing = meta & 3, open = (meta & 4) != 0
        if open && forCollision { return }
        if forCollision {
            if facing < 2 { out.append(aabb(0, 0, 6 / 16, 1, 1.5, 10 / 16)) }
            else { out.append(aabb(6 / 16, 0, 0, 10 / 16, 1.5, 1)) }
            return
        }
        // render: end posts + two bars + center upright (gate across X or Z)
        if facing < 2 {
            out.append(aabb(0, 5 / 16, 6 / 16, 2 / 16, 1, 10 / 16))
            out.append(aabb(14 / 16, 5 / 16, 6 / 16, 1, 1, 10 / 16))
            if !open {
                out.append(aabb(2 / 16, 6 / 16, 7 / 16, 14 / 16, 9 / 16, 9 / 16))
                out.append(aabb(2 / 16, 12 / 16, 7 / 16, 14 / 16, 15 / 16, 9 / 16))
                out.append(aabb(6 / 16, 9 / 16, 7 / 16, 10 / 16, 12 / 16, 9 / 16))
            } else {
                // swung halves folded back to the posts
                out.append(aabb(0, 6 / 16, 10 / 16, 2 / 16, 15 / 16, 1))
                out.append(aabb(14 / 16, 6 / 16, 10 / 16, 1, 15 / 16, 1))
            }
        } else {
            out.append(aabb(6 / 16, 5 / 16, 0, 10 / 16, 1, 2 / 16))
            out.append(aabb(6 / 16, 5 / 16, 14 / 16, 10 / 16, 1, 1))
            if !open {
                out.append(aabb(7 / 16, 6 / 16, 2 / 16, 9 / 16, 9 / 16, 14 / 16))
                out.append(aabb(7 / 16, 12 / 16, 2 / 16, 9 / 16, 15 / 16, 14 / 16))
                out.append(aabb(7 / 16, 9 / 16, 6 / 16, 9 / 16, 12 / 16, 10 / 16))
            } else {
                out.append(aabb(10 / 16, 6 / 16, 0, 1, 15 / 16, 2 / 16))
                out.append(aabb(10 / 16, 6 / 16, 14 / 16, 1, 15 / 16, 2 / 16))
            }
        }
    case .layer:
        let layers = (meta & 7) + 1
        if forCollision {
            if layers == 1 { return }
            out.append(aabb(0, 0, 0, 1, Double(layers - 1) * 2 / 16, 1))
        } else {
            out.append(aabb(0, 0, 0, 1, Double(layers) * 2 / 16, 1))
        }
    case .farmland, .path:
        out.append(aabb(0, 0, 0, 1, 15 / 16, 1))
    case .carpet, .lilyPad, .frogspawn:
        if forCollision && shape == .frogspawn { return }
        out.append(aabb(0, 0, 0, 1, shape == .carpet ? 1.0 / 16 : 1.5 / 16, 1))
    case .torch:
        if forCollision { return }
        if meta >= 2 && meta <= 5 {
            // wall torch leaning out of wall at meta dir
            let f = meta - 2 // 0=N wall...
            let dx = Double([0, 0, -1, 1][f]), dz = Double([-1, 1, 0, 0][f])
            out.append(aabb(
                0.5 - 1.5 / 16 + dx * 5 / 16, 3 / 16, 0.5 - 1.5 / 16 + dz * 5 / 16,
                0.5 + 1.5 / 16 + dx * 5 / 16, 13 / 16, 0.5 + 1.5 / 16 + dz * 5 / 16
            ))
        } else if id == Int(B.lightning_rod) {
            out.append(aabb(6 / 16, 0, 6 / 16, 10 / 16, 1, 10 / 16))
        } else if id == Int(B.end_rod) {
            out.append(aabb(6 / 16, 0, 6 / 16, 10 / 16, 1, 10 / 16))
        } else {
            out.append(aabb(6 / 16, 0, 6 / 16, 10 / 16, 10 / 16, 10 / 16))
        }
    case .lever, .button:
        if forCollision { return }
        out.append(aabb(5 / 16, 0, 5 / 16, 11 / 16, 6 / 16, 11 / 16))
    case .pressurePlate:
        if forCollision { return }
        out.append(aabb(1 / 16, 0, 1 / 16, 15 / 16, 1 / 16, 15 / 16))
    case .rail:
        if forCollision { return }
        out.append(aabb(0, 0, 0, 1, 2 / 16, 1))
    case .redstoneWire, .tripwire:
        if forCollision { return }
        out.append(aabb(0, 0, 0, 1, 1 / 16, 1))
    case .tripwireHook:
        if forCollision { return }
        out.append(aabb(5 / 16, 0, 5 / 16, 11 / 16, 10 / 16, 11 / 16))
    case .repeater, .comparator, .daylightSensor:
        out.append(aabb(0, 0, 0, 1, shape == .daylightSensor ? 6.0 / 16 : 2.0 / 16, 1))
    case .chest:
        out.append(aabb(1 / 16, 0, 1 / 16, 15 / 16, 14 / 16, 15 / 16))
    case .ladder:
        let f = meta & 3
        switch f {
        case 0: out.append(aabb(0, 0, 13 / 16, 1, 1, 1))
        case 1: out.append(aabb(0, 0, 0, 1, 1, 3 / 16))
        case 2: out.append(aabb(13 / 16, 0, 0, 1, 1, 1))
        default: out.append(aabb(0, 0, 0, 3 / 16, 1, 1))
        }
        if forCollision { out.removeLast() } // no collision
    case .sign:
        if forCollision { return }
        let alongX = ((meta + 4) & 15) < 8   // rotation buckets → board axis
        out.append(aabb(7 / 16, 0, 7 / 16, 9 / 16, 9 / 16, 9 / 16))
        if alongX { out.append(aabb(0, 9 / 16, 6.5 / 16, 1, 1, 9.5 / 16)) }
        else { out.append(aabb(6.5 / 16, 9 / 16, 0, 9.5 / 16, 1, 1)) }
    case .wallSign:
        if forCollision { return }
        switch meta & 3 {
        case 0: out.append(aabb(0, 4.5 / 16, 14 / 16, 1, 12.5 / 16, 1))
        case 1: out.append(aabb(0, 4.5 / 16, 0, 1, 12.5 / 16, 2 / 16))
        case 2: out.append(aabb(14 / 16, 4.5 / 16, 0, 1, 12.5 / 16, 1))
        default: out.append(aabb(0, 4.5 / 16, 0, 2 / 16, 12.5 / 16, 1))
        }
    case .hangingSign:
        if forCollision { return }
        let alongX = (meta & 1) == 0
        if alongX {
            out.append(aabb(1 / 16, 0, 7 / 16, 15 / 16, 10 / 16, 9 / 16))
            out.append(aabb(0, 14 / 16, 6 / 16, 1, 1, 10 / 16))
        } else {
            out.append(aabb(7 / 16, 0, 1 / 16, 9 / 16, 10 / 16, 15 / 16))
            out.append(aabb(6 / 16, 14 / 16, 0, 10 / 16, 1, 1))
        }
    case .cake:
        let bites = meta & 7
        out.append(aabb(Double(1 + bites * 2) / 16, 0, 1 / 16, 15 / 16, 0.5, 15 / 16))
    case .bed:
        out.append(aabb(0, 0, 0, 1, 9 / 16, 1))
    case .anvil:
        let facing = meta & 3
        if facing < 2 { out.append(aabb(3 / 16, 0, 0, 13 / 16, 1, 1)) }
        else { out.append(aabb(0, 0, 3 / 16, 1, 1, 13 / 16)) }
    case .hopper:
        out.append(aabb(0, 10 / 16, 0, 1, 1, 1))
        out.append(aabb(4 / 16, 4 / 16, 4 / 16, 12 / 16, 10 / 16, 12 / 16))
    case .cauldron, .composter:
        out.append(aabb(0, 0, 0, 1, 1, 1))
    case .brewingStand:
        out.append(aabb(7 / 16, 0, 7 / 16, 9 / 16, 14 / 16, 9 / 16))
        out.append(aabb(0, 0, 0, 1, 2 / 16, 1))
    case .enchantTable:
        out.append(aabb(0, 0, 0, 1, 12 / 16, 1))
    case .lectern:
        if forCollision { out.append(aabb(0, 0, 0, 1, 12 / 16, 1)); return }
        out.append(aabb(0, 0, 0, 1, 2 / 16, 1))
        out.append(aabb(4 / 16, 2 / 16, 4 / 16, 12 / 16, 12 / 16, 12 / 16))
        out.append(aabb(1 / 16, 12 / 16, 1 / 16, 15 / 16, 15 / 16, 15 / 16))
    case .lantern:
        let hang = (meta & 1) != 0
        let y0 = hang ? 1.0 / 16 : 0
        out.append(aabb(5 / 16, y0, 5 / 16, 11 / 16, y0 + 8 / 16, 11 / 16))
    case .chain:
        let axis = meta & 3
        if axis == 0 { out.append(aabb(6.5 / 16, 0, 6.5 / 16, 9.5 / 16, 1, 9.5 / 16)) }
        else if axis == 1 { out.append(aabb(0, 6.5 / 16, 6.5 / 16, 1, 9.5 / 16, 9.5 / 16)) }
        else { out.append(aabb(6.5 / 16, 6.5 / 16, 0, 9.5 / 16, 9.5 / 16, 1)) }
    case .flowerPot:
        if forCollision { return }
        out.append(aabb(5 / 16, 0, 5 / 16, 11 / 16, 6 / 16, 11 / 16))
    case .endPortalFrame:
        out.append(aabb(0, 0, 0, 1, 13 / 16, 1))
        if meta & 4 != 0 { out.append(aabb(4 / 16, 13 / 16, 4 / 16, 12 / 16, 1, 12 / 16)) }
    case .dragonEgg:
        out.append(aabb(1 / 16, 0, 1 / 16, 15 / 16, 1, 15 / 16))
    case .conduit:
        out.append(aabb(5 / 16, 5 / 16, 5 / 16, 11 / 16, 11 / 16, 11 / 16))
    case .grindstone:
        out.append(aabb(2 / 16, 2 / 16, 2 / 16, 14 / 16, 14 / 16, 14 / 16))
    case .stonecutter:
        out.append(aabb(0, 0, 0, 1, 9 / 16, 1))
    case .bamboo:
        out.append(aabb(6.5 / 16, 0, 6.5 / 16, 9.5 / 16, 1, 9.5 / 16))
    case .cactusShape:
        out.append(aabb(1 / 16, 0, 1 / 16, 15 / 16, forCollision ? 15.0 / 16 : 1, 15 / 16))
    case .bambooSapling:
        if forCollision { return }
        out.append(aabb(4 / 16, 0, 4 / 16, 12 / 16, 12 / 16, 12 / 16))
    case .candle:
        if forCollision { return }
        let count = (meta & 3) + 1
        let w = Double(count == 1 ? 2 : count == 2 ? 5 : 6)
        out.append(aabb((8 - w) / 16, 0, (8 - w) / 16, (8 + w) / 16, 6 / 16, (8 + w) / 16))
    case .seaPickle:
        if forCollision { return }
        out.append(aabb(3 / 16, 0, 3 / 16, 13 / 16, 6 / 16, 13 / 16))
    case .turtleEgg, .snifferEgg:
        out.append(aabb(3 / 16, 0, 3 / 16, 13 / 16, shape == .snifferEgg ? 12.0 / 16 : 7.0 / 16, 13 / 16))
    case .dripstone:
        let thickness = (meta >> 1) & 7
        let w = Double(thickness == 0 ? 3 : thickness == 1 ? 5 : thickness == 4 ? 3 : 7)
        out.append(aabb((8 - w) / 16, 0, (8 - w) / 16, (8 + w) / 16, 1, (8 + w) / 16))
    case .amethystCluster:
        out.append(aabb(3 / 16, 0, 3 / 16, 13 / 16, 7 / 16, 13 / 16))
    case .decoratedPot:
        if forCollision { out.append(aabb(1 / 16, 0, 1 / 16, 15 / 16, 1, 15 / 16)); return }
        out.append(aabb(1 / 16, 0, 1 / 16, 15 / 16, 13 / 16, 15 / 16))
        out.append(aabb(5 / 16, 13 / 16, 5 / 16, 11 / 16, 1, 11 / 16))
    case .campfire:
        if forCollision { out.append(aabb(0, 0, 0, 1, 7 / 16, 1)); return }
        out.append(aabb(1 / 16, 0, 1 / 16, 15 / 16, 1 / 16, 15 / 16))
        out.append(aabb(0, 0, 1 / 16, 1, 4 / 16, 5 / 16))
        out.append(aabb(0, 0, 11 / 16, 1, 4 / 16, 15 / 16))
        out.append(aabb(1 / 16, 3 / 16, 0, 5 / 16, 7 / 16, 1))
        out.append(aabb(11 / 16, 3 / 16, 0, 15 / 16, 7 / 16, 1))
    case .scaffolding:
        out.append(aabb(0, 14 / 16, 0, 1, 1, 1))
        if (meta & 8) != 0 { out.append(aabb(0, 0, 0, 1, 2 / 16, 1)) }
        if !forCollision {
            // corner posts make the lattice frame visible
            out.append(aabb(0, 0, 0, 2 / 16, 14 / 16, 2 / 16))
            out.append(aabb(14 / 16, 0, 0, 1, 14 / 16, 2 / 16))
            out.append(aabb(0, 0, 14 / 16, 2 / 16, 14 / 16, 1))
            out.append(aabb(14 / 16, 0, 14 / 16, 1, 14 / 16, 1))
        }
    case .piston:
        let extended = (meta & 8) != 0
        if !extended { out.append(FULL); return }
        let f = meta & 7
        switch f {
        case 0: out.append(aabb(0, 4 / 16, 0, 1, 1, 1))
        case 1: out.append(aabb(0, 0, 0, 1, 12 / 16, 1))
        case 2: out.append(aabb(0, 0, 4 / 16, 1, 1, 1))
        case 3: out.append(aabb(0, 0, 0, 1, 1, 12 / 16))
        case 4: out.append(aabb(4 / 16, 0, 0, 1, 1, 1))
        default: out.append(aabb(0, 0, 0, 12 / 16, 1, 1))
        }
    case .pistonHead:
        let f = meta & 7
        switch f {
        case 0: out.append(aabb(0, 0, 0, 1, 4 / 16, 1))
        case 1: out.append(aabb(0, 12 / 16, 0, 1, 1, 1))
        case 2: out.append(aabb(0, 0, 0, 1, 1, 4 / 16))
        case 3: out.append(aabb(0, 0, 12 / 16, 1, 1, 1))
        case 4: out.append(aabb(0, 0, 0, 4 / 16, 1, 1))
        default: out.append(aabb(12 / 16, 0, 0, 1, 1, 1))
        }
    case .chorus:
        out.append(aabb(4 / 16, 4 / 16, 4 / 16, 12 / 16, 12 / 16, 12 / 16))
        let dirs = [(0, -1, 0), (0, 1, 0), (0, 0, -1), (0, 0, 1), (-1, 0, 0), (1, 0, 0)]
        for (dx, dy, dz) in dirs {
            let o = get(dx, dy, dz)
            let oid = o >> 4
            if oid == Int(B.chorus_plant) || oid == Int(B.chorus_flower) || (dy == -1 && oid == Int(B.end_stone)) {
                out.append(aabb(
                    4.0 / 16 + Double(dx) * 4 / 16, 4.0 / 16 + Double(dy) * 4 / 16, 4.0 / 16 + Double(dz) * 4 / 16,
                    12.0 / 16 + Double(dx) * 4 / 16, 12.0 / 16 + Double(dy) * 4 / 16, 12.0 / 16 + Double(dz) * 4 / 16
                ))
            }
        }
    case .chorusFlower:
        out.append(aabb(2 / 16, 2 / 16, 2 / 16, 14 / 16, 14 / 16, 14 / 16))
    case .cocoa:
        let age = (meta >> 2) & 3
        let f = meta & 3
        let size = Double(4 + age * 2)
        let dx = Double(FACE_DX[f]), dz = Double(FACE_DZ[f])
        let cx = 0.5 + dx * Double(6 - age) / 16, cz = 0.5 + dz * Double(6 - age) / 16
        out.append(aabb(cx - size / 32, (12 - size) / 16 - 1 / 16, cz - size / 32, cx + size / 32, 12 / 16, cz + size / 32))
    case .vine, .glowLichen, .sculkVein:
        if forCollision { return }
        out.append(aabb(1 / 16, 0, 1 / 16, 15 / 16, 1, 15 / 16))
    case .bigDripleaf:
        let tilt = (meta >> 2) & 3
        if forCollision && tilt >= 2 { return }
        out.append(aabb(0, 11 / 16, 0, 1, 15 / 16, 1))
        if !forCollision {
            out.append(aabb(6 / 16, 0, 6 / 16, 10 / 16, 11 / 16, 10 / 16))   // stem
        }
    case .smallDripleafShape, .pitcherCropShape:
        if forCollision { return }
        out.append(aabb(2 / 16, 0, 2 / 16, 14 / 16, 14 / 16, 14 / 16))
    case .propagule:
        if forCollision { return }
        out.append(aabb(5 / 16, 0, 5 / 16, 11 / 16, 1, 11 / 16))
    case .bell:
        if forCollision { out.append(aabb(4 / 16, 4 / 16, 4 / 16, 12 / 16, 1, 12 / 16)); return }
        // floor bell: two posts + crossbar + bell body with flared lip
        out.append(aabb(2 / 16, 0, 7 / 16, 4 / 16, 15 / 16, 9 / 16))
        out.append(aabb(12 / 16, 0, 7 / 16, 14 / 16, 15 / 16, 9 / 16))
        out.append(aabb(2 / 16, 13 / 16, 7 / 16, 14 / 16, 15 / 16, 9 / 16))
        out.append(aabb(5 / 16, 6 / 16, 5 / 16, 11 / 16, 13 / 16, 11 / 16))
        out.append(aabb(4 / 16, 4 / 16, 4 / 16, 12 / 16, 6 / 16, 12 / 16))
    case .beacon:
        out.append(FULL)
    case .head:
        out.append(aabb(4 / 16, 0, 4 / 16, 12 / 16, 8 / 16, 12 / 16))
    case .pointedAttach, .muddyMangroveRoots, .structureVoid:
        out.append(FULL)
    }
}

public func hasAnyCollision(_ cell: Int, _ get: CellGetter) -> Bool {
    var scratch: [AABB] = []
    shapeBoxes(cell, get, &scratch, true)
    return !scratch.isEmpty
}
