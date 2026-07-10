// Redstone — power model, wire networks, torches
// (with burnout), repeaters (delay + locking), comparators (compare/subtract +
// container reading), pistons (incl. sticky + slime/honey push sets +
// quasi-connectivity), observers, dispensers/droppers, note blocks, lamps,
// rails, doors, sensors, TNT — with vanilla-style scheduled tick timing.
//
// Uses its own seeded module RNG (0x4ED0) exactly like the frozen baseline.

import Foundation

var redstoneRng = RandomX(0x4ED0)

private let FACING_DX = [0, 0, -1, 1] // 0=N 1=S 2=W 3=E (horizontal facing in meta)
private let FACING_DZ = [-1, 1, 0, 0]

private var WOOD_BUTTONS: [Int] = []
private var WOOD_PLATES: [Int] = []

public struct RPGRedstoneSourceTrace: Equatable {
    public var direction: String
    public var distance: Int
    public var visitedNodes: Int
}

/// Bounded, read-only breadth-first trace from a powered component through
/// connected powered wire/relays to the nearest actual emitter. Direction and
/// tie order use frozen engine tables; unloaded columns are never queried.
public func rpgNearestPoweredRedstoneSource(_ world: World,
                                            x: Int, y: Int, z: Int,
                                            nodeLimit: Int = 64) -> RPGRedstoneSourceTrace? {
    struct Position: Hashable { var x: Int; var y: Int; var z: Int }
    struct Pending { var position: Position; var firstDirection: Int; var distance: Int }
    struct RelayInput { var position: Position; var direction: Int; var terminal: Bool }
    let cap = max(1, min(64, nodeLimit))
    let start = Position(x: x, y: y, z: z)
    guard world.isLoadedAt(x, z) else { return nil }

    func isRelay(_ position: Position) -> Bool {
        let id = world.getBlock(position.x, position.y, position.z) >> 4
        return id == Int(B.repeater) || id == Int(B.repeater_on)
            || id == Int(B.comparator) || id == Int(B.comparator_on)
    }

    func isIntrinsicEmitter(_ position: Position) -> Bool {
        let id = world.getBlock(position.x, position.y, position.z) >> 4
        guard id != Int(B.redstone_wire), !isRelay(position) else { return false }
        return (0..<6).contains {
            emittedPower(world, position.x, position.y, position.z, $0) > 0
        }
    }

    func isPoweredConductor(_ position: Position) -> Bool {
        let id = world.getBlock(position.x, position.y, position.z) >> 4
        guard blockDefs[id].opaque, blockDefs[id].fullCube else { return false }
        for direction in 0..<6 {
            let nx = position.x + DIR_X[direction]
            let nz = position.z + DIR_Z[direction]
            guard world.isLoadedAt(nx, nz) else { continue }
            if strongPowerInto(world, nx, position.y + DIR_Y[direction], nz,
                               DIR_OPPOSITE[direction]) > 0 {
                return true
            }
        }
        return false
    }

    func relayInputs(_ position: Position) -> [RelayInput] {
        let c = world.getBlock(position.x, position.y, position.z)
        let id = c >> 4, facing = c & 3
        let outputDirection = facingToDir(facing)
        let rearDirection = DIR_OPPOSITE[outputDirection]
        let rear = Position(x: position.x + DIR_X[rearDirection], y: position.y,
                            z: position.z + DIR_Z[rearDirection])
        guard world.isLoadedAt(rear.x, rear.z) else { return [] }

        if id == Int(B.repeater) || id == Int(B.repeater_on) {
            guard repeaterInputPower(world, position.x, position.y, position.z, facing) > 0 else {
                return []
            }
            let rearCell = world.getBlock(rear.x, rear.y, rear.z)
            let traceable = (rearCell >> 4) == Int(B.redstone_wire)
                || isRelay(rear) || isIntrinsicEmitter(rear) || isPoweredConductor(rear)
            guard traceable else { return [] }
            return [RelayInput(position: rear, direction: rearDirection, terminal: false)]
        }

        guard id == Int(B.comparator) || id == Int(B.comparator_on) else { return [] }
        var inputs: [RelayInput] = []
        // Comparator containers are analog sources, not redstone emitters. A
        // direct or through-solid nonzero container signal is therefore an
        // exact terminal in the rear direction.
        let directContainer = containerSignal(world, rear.x, rear.y, rear.z)
        if directContainer > 0 {
            inputs.append(RelayInput(position: rear, direction: rearDirection, terminal: true))
        } else {
            let rearCell = world.getBlock(rear.x, rear.y, rear.z)
            let rearID = rearCell >> 4
            let beyond = Position(x: rear.x + DIR_X[rearDirection], y: rear.y,
                                  z: rear.z + DIR_Z[rearDirection])
            if blockDefs[rearID].opaque, world.isLoadedAt(beyond.x, beyond.z),
               containerSignal(world, beyond.x, beyond.y, beyond.z) > 0 {
                inputs.append(RelayInput(position: beyond, direction: rearDirection,
                                         terminal: true))
            } else if comparatorRearSignal(world, position.x, position.y,
                                           position.z, facing) > 0 {
                let traceable = (rearCell >> 4) == Int(B.redstone_wire)
                    || isRelay(rear) || isIntrinsicEmitter(rear) || isPoweredConductor(rear)
                if traceable {
                    inputs.append(RelayInput(position: rear, direction: rearDirection,
                                             terminal: false))
                }
            }
        }
        // Frozen order is rear, then left, then right. Side inputs mirror the
        // exact subset accepted by comparatorSideSignal.
        for side in [leftFacing(facing), rightFacing(facing)] {
            let direction = facingToDir(side)
            let sidePosition = Position(x: position.x + DIR_X[direction], y: position.y,
                                        z: position.z + DIR_Z[direction])
            guard world.isLoadedAt(sidePosition.x, sidePosition.z) else { continue }
            let sideCell = world.getBlock(sidePosition.x, sidePosition.y, sidePosition.z)
            let sideID = sideCell >> 4
            let powered = (sideID == Int(B.redstone_wire) && (sideCell & 15) > 0)
                || sideID == Int(B.redstone_block)
                || (sideID == Int(B.repeater_on) && (sideCell & 3) == oppFacing(side))
                || (sideID == Int(B.comparator_on) && (sideCell & 3) == oppFacing(side)
                    && (world.getBlockEntity(sidePosition.x, sidePosition.y,
                                             sidePosition.z)?.output ?? 0) > 0)
            if powered {
                inputs.append(RelayInput(position: sidePosition, direction: direction,
                                         terminal: false))
            }
        }
        return inputs
    }

    func connectedPoweredWires(from position: Position) -> [(Position, Int)] {
        var result: [(Position, Int)] = []
        for facing in 0..<4 {
            let direction = HORIZONTALS[facing]
            let dx = FACING_DX[facing], dz = FACING_DZ[facing]
            let nx = position.x + dx, nz = position.z + dz
            guard world.isLoadedAt(nx, nz) else { continue }
            let neighbor = world.getBlock(nx, position.y, nz)
            let neighborID = neighbor >> 4
            if neighborID == Int(B.redstone_wire), (neighbor & 15) > 0 {
                result.append((Position(x: nx, y: position.y, z: nz), direction))
                continue
            }
            let aboveCurrentOpaque = blockDefs[
                world.getBlock(position.x, position.y + 1, position.z) >> 4
            ].opaque
            let upper = world.getBlock(nx, position.y + 1, nz)
            if !aboveCurrentOpaque, blockDefs[neighborID].opaque,
               (upper >> 4) == Int(B.redstone_wire), (upper & 15) > 0 {
                result.append((Position(x: nx, y: position.y + 1, z: nz), direction))
                continue
            }
            let lower = world.getBlock(nx, position.y - 1, nz)
            if !blockDefs[neighborID].opaque,
               (lower >> 4) == Int(B.redstone_wire), (lower & 15) > 0 {
                result.append((Position(x: nx, y: position.y - 1, z: nz), direction))
            }
        }
        return result
    }

    var visited: Set<Position> = [start]
    var queue: [Pending] = []
    queue.reserveCapacity(cap)
    var head = 0
    let startID = world.getBlock(x, y, z) >> 4
    if isIntrinsicEmitter(start) {
        return RPGRedstoneSourceTrace(direction: "self", distance: 0, visitedNodes: 1)
    }
    if startID == Int(B.redstone_wire) || isRelay(start) || isPoweredConductor(start) {
        queue.append(Pending(position: start, firstDirection: -1, distance: 0))
    } else {
        // Prefer a direct intrinsic source over a relay whose true source is
        // necessarily farther away.
        for direction in 0..<6 where visited.count < cap {
            let next = Position(x: x + DIR_X[direction], y: y + DIR_Y[direction],
                                z: z + DIR_Z[direction])
            guard world.isLoadedAt(next.x, next.z), isIntrinsicEmitter(next),
                  emittedPower(world, next.x, next.y, next.z,
                               DIR_OPPOSITE[direction]) > 0 else { continue }
            return RPGRedstoneSourceTrace(direction: DIR_NAMES[direction], distance: 1,
                                          visitedNodes: visited.count + 1)
        }
        for direction in 0..<6 where visited.count < cap {
            let next = Position(x: x + DIR_X[direction], y: y + DIR_Y[direction],
                                z: z + DIR_Z[direction])
            guard world.isLoadedAt(next.x, next.z) else { continue }
            let nextCell = world.getBlock(next.x, next.y, next.z)
            let nextID = nextCell >> 4
            let poweredWire = nextID == Int(B.redstone_wire) && (nextCell & 15) > 0
                && emittedPower(world, next.x, next.y, next.z,
                                DIR_OPPOSITE[direction]) > 0
            let emittingRelay = isRelay(next)
                && emittedPower(world, next.x, next.y, next.z,
                                DIR_OPPOSITE[direction]) > 0
            let poweredConductor = isPoweredConductor(next)
            if poweredWire || emittingRelay || poweredConductor,
               visited.insert(next).inserted {
                queue.append(Pending(position: next, firstDirection: direction, distance: 1))
            }
        }
    }

    while head < queue.count && visited.count <= cap {
        let current = queue[head]
        head += 1
        if isRelay(current.position) {
            let inputs = relayInputs(current.position)
            var advanced = false
            for input in inputs where visited.count < cap {
                let firstDirection = current.firstDirection >= 0
                    ? current.firstDirection : input.direction
                if input.terminal || isIntrinsicEmitter(input.position) {
                    return RPGRedstoneSourceTrace(direction: DIR_NAMES[firstDirection],
                                                  distance: current.distance + 1,
                                                  visitedNodes: visited.count + 1)
                }
                let inputCell = world.getBlock(input.position.x, input.position.y,
                                               input.position.z)
                let poweredWire = (inputCell >> 4) == Int(B.redstone_wire)
                    && (inputCell & 15) > 0
                if poweredWire || isRelay(input.position) || isPoweredConductor(input.position),
                   visited.insert(input.position).inserted {
                    queue.append(Pending(position: input.position,
                                         firstDirection: firstDirection,
                                         distance: current.distance + 1))
                    advanced = true
                }
            }
            let currentID = world.getBlock(current.position.x, current.position.y,
                                           current.position.z) >> 4
            if !advanced, inputs.isEmpty,
               currentID == Int(B.comparator) || currentID == Int(B.comparator_on),
               (world.getBlockEntity(current.position.x, current.position.y,
                                     current.position.z)?.output ?? 0) > 0 {
                // A nonzero comparator output with no traversable external
                // input is an intrinsic/legacy block-entity output fallback.
                let direction = current.firstDirection >= 0
                    ? DIR_NAMES[current.firstDirection] : "self"
                return RPGRedstoneSourceTrace(direction: direction,
                                              distance: current.distance,
                                              visitedNodes: visited.count)
            }
            continue
        }

        if isPoweredConductor(current.position) {
            for direction in 0..<6 where visited.count < cap {
                let next = Position(x: current.position.x + DIR_X[direction],
                                    y: current.position.y + DIR_Y[direction],
                                    z: current.position.z + DIR_Z[direction])
                guard world.isLoadedAt(next.x, next.z),
                      strongPowerInto(world, next.x, next.y, next.z,
                                      DIR_OPPOSITE[direction]) > 0 else { continue }
                let firstDirection = current.firstDirection >= 0
                    ? current.firstDirection : direction
                if isIntrinsicEmitter(next) {
                    return RPGRedstoneSourceTrace(direction: DIR_NAMES[firstDirection],
                                                  distance: current.distance + 1,
                                                  visitedNodes: visited.count + 1)
                }
                let nextCell = world.getBlock(next.x, next.y, next.z)
                let poweredWire = (nextCell >> 4) == Int(B.redstone_wire)
                    && (nextCell & 15) > 0
                if poweredWire || isRelay(next), visited.insert(next).inserted {
                    queue.append(Pending(position: next, firstDirection: firstDirection,
                                         distance: current.distance + 1))
                }
            }
            continue
        }

        for direction in 0..<6 where visited.count < cap {
            let next = Position(x: current.position.x + DIR_X[direction],
                                y: current.position.y + DIR_Y[direction],
                                z: current.position.z + DIR_Z[direction])
            guard world.isLoadedAt(next.x, next.z), isIntrinsicEmitter(next),
                  emittedPower(world, next.x, next.y, next.z,
                               DIR_OPPOSITE[direction]) > 0 else { continue }
            let firstDirection = current.firstDirection >= 0 ? current.firstDirection : direction
            return RPGRedstoneSourceTrace(direction: DIR_NAMES[firstDirection],
                                          distance: current.distance + 1,
                                          visitedNodes: visited.count + 1)
        }
        for direction in 0..<6 where visited.count < cap {
            let next = Position(x: current.position.x + DIR_X[direction],
                                y: current.position.y + DIR_Y[direction],
                                z: current.position.z + DIR_Z[direction])
            guard world.isLoadedAt(next.x, next.z), isRelay(next),
                  emittedPower(world, next.x, next.y, next.z,
                               DIR_OPPOSITE[direction]) > 0 else { continue }
            if visited.insert(next).inserted {
                let firstDirection = current.firstDirection >= 0
                    ? current.firstDirection : direction
                queue.append(Pending(position: next, firstDirection: firstDirection,
                                     distance: current.distance + 1))
            }
        }
        for direction in 0..<6 where visited.count < cap {
            let next = Position(x: current.position.x + DIR_X[direction],
                                y: current.position.y + DIR_Y[direction],
                                z: current.position.z + DIR_Z[direction])
            guard world.isLoadedAt(next.x, next.z), isPoweredConductor(next) else { continue }
            if visited.insert(next).inserted {
                let firstDirection = current.firstDirection >= 0
                    ? current.firstDirection : direction
                queue.append(Pending(position: next, firstDirection: firstDirection,
                                     distance: current.distance + 1))
            }
        }
        for (next, horizontalDirection) in connectedPoweredWires(from: current.position) {
            guard visited.count < cap, visited.insert(next).inserted else { continue }
            let firstDirection = current.firstDirection >= 0
                ? current.firstDirection : horizontalDirection
            queue.append(Pending(position: next, firstDirection: firstDirection,
                                 distance: current.distance + 1))
        }
    }
    return nil
}

// ---------------------------------------------------------------------------
// Power queries
// ---------------------------------------------------------------------------
/// power a cell emits toward direction `dir` (pointing FROM the emitter TO the queried neighbor)
public func emittedPower(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ dir: Int) -> Int {
    let c = world.getBlock(x, y, z)
    let id = c >> 4, meta = c & 15
    if id == Int(B.redstone_block) { return 15 }
    if id == Int(B.redstone_torch) {
        // emits 15 except toward its support block
        let attach = meta == 0 ? Dir.down : meta
        return dir == attach ? 0 : 15
    }
    if id == Int(B.lever) || id == Int(B.stone_button) || id == Int(B.polished_blackstone_button) {
        return (meta & 8) != 0 ? 15 : 0
    }
    for w in WOOD_BUTTONS where id == w { return (meta & 8) != 0 ? 15 : 0 }
    if id == Int(B.redstone_wire) {
        if dir == Dir.up { return 0 }
        if dir == Dir.down { return meta }
        // emits to the sides its visual shape points at: connected sides, plus
        // the far end of a single-connection line. A bare dot powers no sides.
        let f = dirToFacing(dir)
        if f < 0 { return 0 }
        var mask = 0, count = 0
        for i in 0..<4 {
            if wireConnectsDir(world, x, y, z, i) { mask |= 1 << i; count += 1 }
        }
        if (mask & (1 << f)) != 0 { return meta }
        if count == 1 && (mask & (1 << (f ^ 1))) != 0 { return meta }
        return 0
    }
    if id == Int(B.repeater_on) {
        let facing = meta & 3
        return dir == facingToDir(facing) ? 15 : 0
    }
    if id == Int(B.comparator_on) || id == Int(B.comparator) {
        let facing = meta & 3
        if dir == facingToDir(facing) {
            return world.getBlockEntity(x, y, z)?.output ?? 0
        }
        return 0
    }
    if id == Int(B.observer) {
        return (meta & 8) != 0 && dir == ((meta & 7) ^ 1) ? 15 : 0
    }
    if isPressurePlate(id) { return (meta & 8) != 0 ? 15 : 0 }
    if id == Int(B.detector_rail) { return (meta & 8) != 0 ? 15 : 0 }
    if id == Int(B.daylight_detector) || id == Int(B.daylight_detector_inverted) { return meta }
    if id == Int(B.target) { return meta }
    if id == Int(B.sculk_sensor) || id == Int(B.calibrated_sculk_sensor) { return meta }
    if id == Int(B.tripwire_hook) { return (meta & 8) != 0 ? 15 : 0 }
    if id == Int(B.lightning_rod) { return (meta & 8) != 0 ? 15 : 0 }
    if id == Int(B.lectern) { return 0 }
    if id == Int(B.trapped_chest) {
        // emits weak power scaled by viewers — approximated via BE flag
        if let v = world.getBlockEntity(x, y, z)?.viewers, v > 0 { return min(15, v) }
        return 0
    }
    return 0
}

/// strong power INTO a solid block from a component attached/facing it
private func strongPowerInto(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ dir: Int) -> Int {
    let c = world.getBlock(x, y, z)
    let id = c >> 4, meta = c & 15
    if id == Int(B.redstone_torch) { return dir == Dir.up ? 15 : 0 } // powers block above
    if id == Int(B.repeater_on) {
        return dir == facingToDir(meta & 3) ? 15 : 0
    }
    if id == Int(B.comparator_on) {
        if dir == facingToDir(meta & 3) {
            return world.getBlockEntity(x, y, z)?.output ?? 0
        }
        return 0
    }
    if id == Int(B.lever) || isButton(id) {
        let attach = meta & 7
        return dir == (attach ^ 1) ? ((meta & 8) != 0 ? 15 : 0) : 0
    }
    if isPressurePlate(id) { return dir == Dir.down ? ((meta & 8) != 0 ? 15 : 0) : 0 }
    if id == Int(B.detector_rail) { return dir == Dir.down ? ((meta & 8) != 0 ? 15 : 0) : 0 }
    if id == Int(B.redstone_wire) {
        if dir == Dir.down { return meta } // treat as weak (matches baseline comment)
        return 0
    }
    if id == Int(B.observer) { return (meta & 8) != 0 && dir == ((meta & 7) ^ 1) ? 15 : 0 }
    if id == Int(B.tripwire_hook) {
        let facing = meta & 3
        return ((meta & 8) != 0 && dir == facingToDir(facing)) ? 15 : 0
    }
    return 0
}

/// is this solid block strongly powered (can conduct to wires)
public func strongPowerAt(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Int {
    var p = 0
    for d in 0..<6 {
        let nx = x + DIR_X[d], ny = y + DIR_Y[d], nz = z + DIR_Z[d]
        p = max(p, strongPowerInto(world, nx, ny, nz, DIR_OPPOSITE[d]))
        if p >= 15 { return 15 }
    }
    return p
}

/// power level received at a position (for components)
public func powerAt(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ ignoreWire: Bool = false) -> Int {
    var p = 0
    for d in 0..<6 {
        let nx = x + DIR_X[d], ny = y + DIR_Y[d], nz = z + DIR_Z[d]
        let nc = world.getBlock(nx, ny, nz)
        let nid = nc >> 4
        if ignoreWire && nid == Int(B.redstone_wire) { continue }
        p = max(p, emittedPower(world, nx, ny, nz, DIR_OPPOSITE[d]))
        // conduction through solid block
        if blockDefs[nid].opaque && blockDefs[nid].fullCube {
            p = max(p, strongPowerAt(world, nx, ny, nz))
        }
        if p >= 15 { return 15 }
    }
    return p
}

private func facingToDir(_ facing: Int) -> Int {
    [Dir.north, Dir.south, Dir.west, Dir.east][facing]
}
private func dirToFacing(_ dir: Int) -> Int {
    [Dir.north, Dir.south, Dir.west, Dir.east].firstIndex(of: dir) ?? -1
}
private func isButton(_ id: Int) -> Bool {
    id == Int(B.stone_button) || id == Int(B.polished_blackstone_button) || WOOD_BUTTONS.contains(id)
}
private func isPressurePlate(_ id: Int) -> Bool {
    id == Int(B.stone_pressure_plate) || id == Int(B.polished_blackstone_pressure_plate) ||
        id == Int(B.light_weighted_pressure_plate) || id == Int(B.heavy_weighted_pressure_plate) ||
        WOOD_PLATES.contains(id)
}

// ---------------------------------------------------------------------------
// Wire networks
// ---------------------------------------------------------------------------
public func wireConnectsDir(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ facing: Int) -> Bool {
    let dx = FACING_DX[facing], dz = FACING_DZ[facing]
    let n = world.getBlock(x + dx, y, z + dz)
    let nid = n >> 4
    if connectsToWire(nid, n & 15, facing) { return true }
    // up a block
    let upBlocked = blockDefs[world.getBlock(x, y + 1, z) >> 4].opaque
    if !upBlocked && blockDefs[nid].opaque && (world.getBlock(x + dx, y + 1, z + dz) >> 4) == Int(B.redstone_wire) { return true }
    // down a block
    if !blockDefs[nid].opaque && (world.getBlock(x + dx, y - 1, z + dz) >> 4) == Int(B.redstone_wire) { return true }
    return false
}
private func connectsToWire(_ id: Int, _ meta: Int, _ facingToward: Int) -> Bool {
    if id == Int(B.redstone_wire) || id == Int(B.redstone_torch) || id == Int(B.redstone_torch_off) ||
        id == Int(B.lever) || isButton(id) || id == Int(B.redstone_block) || id == Int(B.target) ||
        id == Int(B.daylight_detector) || id == Int(B.daylight_detector_inverted) ||
        id == Int(B.sculk_sensor) || id == Int(B.calibrated_sculk_sensor) || id == Int(B.tripwire_hook) ||
        isPressurePlate(id) || id == Int(B.detector_rail) || id == Int(B.trapped_chest) || id == Int(B.lightning_rod) || id == Int(B.observer) { return true }
    if id == Int(B.repeater) || id == Int(B.repeater_on) || id == Int(B.comparator) || id == Int(B.comparator_on) {
        let f = meta & 3
        // connects on its input/output axis
        return (f <= 1) == (facingToward <= 1)
    }
    return false
}

/// recompute the wire network containing (x,y,z)
public func updateWireNetwork(_ world: World, _ x: Int, _ y: Int, _ z: Int) {
    struct K: Hashable { let x: Int, y: Int, z: Int }
    // collect network (insertion-ordered like the baseline Map)
    var networkOrder: [K] = []
    var networkSet = Set<K>()
    var queue: [(Int, Int, Int)] = [(x, y, z)]
    if (world.getBlock(x, y, z) >> 4) != Int(B.redstone_wire) { return }
    let k0 = K(x: x, y: y, z: z)
    networkOrder.append(k0)
    networkSet.insert(k0)
    while !queue.isEmpty && networkSet.count < 1024 {
        let (qx, qy, qz) = queue.removeLast()
        for f in 0..<4 {
            let dx = FACING_DX[f], dz = FACING_DZ[f]
            for dy in [0, 1, -1] {
                let nx = qx + dx, ny = qy + dy, nz = qz + dz
                if (world.getBlock(nx, ny, nz) >> 4) != Int(B.redstone_wire) { continue }
                if dy == 1 && blockDefs[world.getBlock(qx, qy + 1, qz) >> 4].opaque { continue }
                if dy == -1 && blockDefs[world.getBlock(nx, ny + 1, nz) >> 4].opaque { continue }
                let k = K(x: nx, y: ny, z: nz)
                if !networkSet.contains(k) {
                    networkSet.insert(k)
                    networkOrder.append(k)
                    queue.append((nx, ny, nz))
                }
            }
        }
    }
    // source power at each wire
    var levels: [K: Int] = [:]
    var bfs: [(K, Int)] = []
    for k in networkOrder {
        let p = powerAt(world, k.x, k.y, k.z, true)
        levels[k] = p
        if p > 0 { bfs.append((k, p)) }
    }
    // propagate decrementing
    while !bfs.isEmpty {
        let (k, p) = bfs.removeLast()
        if (levels[k] ?? 0) > p { continue }
        for f in 0..<4 {
            let dx = FACING_DX[f], dz = FACING_DZ[f]
            for dy in [0, 1, -1] {
                let nk = K(x: k.x + dx, y: k.y + dy, z: k.z + dz)
                if !networkSet.contains(nk) { continue }
                let np = p - 1
                if np > (levels[nk] ?? 0) {
                    levels[nk] = np
                    bfs.append((nk, np))
                }
            }
        }
    }
    // apply
    for k in networkOrder {
        let cur = world.getBlock(k.x, k.y, k.z)
        let newMeta = levels[k] ?? 0
        if (cur & 15) != newMeta {
            world.setBlock(k.x, k.y, k.z, Int(cell(B.redstone_wire, newMeta)), 1 | 4)
            // also update diagonal neighbors' components (block below wire)
            world.notifyBlock(k.x, k.y - 1, k.z, k.x, k.y, k.z)
        }
    }
}

// ---------------------------------------------------------------------------
// Torch (with burnout)
// ---------------------------------------------------------------------------
private var torchBurnout: [Int64: [Int]] = [:]
private func torchKey(_ x: Int, _ y: Int, _ z: Int) -> Int64 {
    (Int64(x) << 40) ^ (Int64(y) << 20) ^ Int64(z)
}
private func torchSupportPos(_ x: Int, _ y: Int, _ z: Int, _ meta: Int) -> (Int, Int, Int) {
    if meta == 0 { return (x, y - 1, z) }
    return (x + DIR_X[meta], y + DIR_Y[meta], z + DIR_Z[meta])
}
private func torchShouldBeOff(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ meta: Int) -> Bool {
    let (sx, sy, sz) = torchSupportPos(x, y, z, meta)
    // powered support → torch off
    let sc = world.getBlock(sx, sy, sz)
    if blockDefs[sc >> 4].opaque {
        if strongPowerAt(world, sx, sy, sz) > 0 { return true }
        // also direct emission into the support
        for d in 0..<6 {
            let nx = sx + DIR_X[d], ny = sy + DIR_Y[d], nz = sz + DIR_Z[d]
            if nx == x && ny == y && nz == z { continue }
            if emittedPower(world, nx, ny, nz, DIR_OPPOSITE[d]) > 0 { return true }
        }
    }
    return false
}
private func torchTick(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ c: Int) {
    let id = c >> 4, meta = c & 15
    let shouldOff = torchShouldBeOff(world, x, y, z, meta)
    let isOn = id == Int(B.redstone_torch)
    if isOn == !shouldOff { return }
    // burnout: 8 toggles in 60 ticks
    let k = torchKey(x, y, z)
    var hist = torchBurnout[k] ?? []
    let now = world.time
    while !hist.isEmpty && now - hist[0] > 60 { hist.removeFirst() }
    if shouldOff || hist.count < 8 {
        hist.append(now)
        torchBurnout[k] = hist
        world.setBlock(x, y, z, Int(cell(shouldOff ? B.redstone_torch_off : B.redstone_torch, meta)))
        if hist.count >= 8 && !shouldOff {
            // burned out — re-light later
            world.scheduleTick(x, y, z, Int(B.redstone_torch_off), 160)
        }
    }
}

// ---------------------------------------------------------------------------
// Repeater
// ---------------------------------------------------------------------------
private func repeaterInputPower(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ facing: Int) -> Int {
    // input is BEHIND (opposite of facing)
    let dx = -FACING_DX[facing], dz = -FACING_DZ[facing]
    let nx = x + dx, nz = z + dz
    let nc = world.getBlock(nx, y, nz)
    let nid = nc >> 4
    var p = emittedPower(world, nx, y, nz, facingToDir(facing))
    if nid == Int(B.redstone_wire) { p = max(p, nc & 15) }
    if blockDefs[nid].opaque && blockDefs[nid].fullCube { p = max(p, strongPowerAt(world, nx, y, nz)) }
    return p
}
private func repeaterLocked(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ facing: Int) -> Bool {
    // side repeaters/comparators pointing into this lock it
    for side in [leftFacing(facing), rightFacing(facing)] {
        let dx = FACING_DX[side], dz = FACING_DZ[side]
        let nc = world.getBlock(x + dx, y, z + dz)
        let nid = nc >> 4
        if (nid == Int(B.repeater_on) || nid == Int(B.comparator_on)) && (nc & 3) == oppFacing(side) { return true }
    }
    return false
}
private func leftFacing(_ f: Int) -> Int { [2, 3, 1, 0][f] }
private func rightFacing(_ f: Int) -> Int { [3, 2, 0, 1][f] }
private func oppFacing(_ f: Int) -> Int { [1, 0, 3, 2][f] }

private func repeaterNeighbor(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ c: Int) {
    let id = c >> 4
    if !world.hasScheduledTick(x, y, z, id) {
        let meta = c & 15
        let facing = meta & 3
        if repeaterLocked(world, x, y, z, facing) { return }
        let powered = repeaterInputPower(world, x, y, z, facing) > 0
        let isOn = id == Int(B.repeater_on)
        if powered != isOn {
            let delay = ((meta >> 2) & 3) + 1
            world.scheduleTick(x, y, z, id, delay * 2, isOn ? 0 : -1)
        }
    }
}

// ---------------------------------------------------------------------------
// Comparator
// ---------------------------------------------------------------------------
public func containerSignal(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Int {
    let be = world.getBlockEntity(x, y, z)
    let c = world.getBlock(x, y, z)
    let id = c >> 4
    if id == Int(B.cake) { return (7 - (c & 7)) * 2 }
    if id == Int(B.cauldron) { return c & 3 }
    if id == Int(B.composter) { return min(8, c & 15) }
    if id == Int(B.jukebox) {
        return be?.disc != nil ? 15 : 0
    }
    if id == Int(B.chiseled_bookshelf) {
        if let items = be?.items {
            var n = 0
            for s in items where s != nil { n += 1 }
            return n > 0 ? min(15, n * 2 + 3) : 0
        }
        return 0
    }
    guard let be else { return -1 }
    var items: [ItemStack?]? = nil
    if be.type == "container" || be.type == "hopper" || be.type == "furnace" || be.type == "brewing" {
        items = be.items
    }
    guard let items else { return -1 }
    var filled = 0.0
    var any = false
    for s in items {
        if let s {
            any = true
            filled += Double(s.count) / Double(maxStackOf(s))
        }
    }
    if !any { return 0 }
    return Int((1 + (filled / Double(items.count)) * 14).rounded(.down))
}

private func comparatorRearSignal(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ facing: Int) -> Int {
    let dx = -FACING_DX[facing], dz = -FACING_DZ[facing]
    let nx = x + dx, nz = z + dz
    let cs = containerSignal(world, nx, y, nz)
    if cs >= 0 { return cs }
    // block behind a solid block can be a container too (reading through)
    let nc = world.getBlock(nx, y, nz)
    if blockDefs[nc >> 4].opaque {
        let cs2 = containerSignal(world, nx + dx, y, nz + dz)
        if cs2 >= 0 { return cs2 }
    }
    let wire = world.getBlock(nx, y, nz)
    var p = emittedPower(world, nx, y, nz, facingToDir(facing))
    if (wire >> 4) == Int(B.redstone_wire) { p = max(p, wire & 15) }
    if blockDefs[nc >> 4].opaque && blockDefs[nc >> 4].fullCube { p = max(p, strongPowerAt(world, nx, y, nz)) }
    return p
}
private func comparatorSideSignal(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ facing: Int) -> Int {
    var p = 0
    for side in [leftFacing(facing), rightFacing(facing)] {
        let dx = FACING_DX[side], dz = FACING_DZ[side]
        let nc = world.getBlock(x + dx, y, z + dz)
        let nid = nc >> 4
        if nid == Int(B.redstone_wire) { p = max(p, nc & 15) }
        else if nid == Int(B.repeater_on) && (nc & 3) == oppFacing(side) { p = max(p, 15) }
        else if nid == Int(B.redstone_block) { p = max(p, 15) }
        else if nid == Int(B.comparator_on) && (nc & 3) == oppFacing(side) {
            p = max(p, world.getBlockEntity(x + dx, y, z + dz)?.output ?? 0)
        }
    }
    return p
}
private func comparatorTick(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ c: Int) {
    let meta = c & 15
    let facing = meta & 3
    let subtract = (meta & 4) != 0
    let rear = comparatorRearSignal(world, x, y, z, facing)
    let side = comparatorSideSignal(world, x, y, z, facing)
    let out = subtract ? max(0, rear - side) : (rear >= side ? rear : 0)
    var be = world.getBlockEntity(x, y, z)
    if be == nil || be!.type != "comparator" {
        be = BlockEntityData(type: "comparator", x: x, y: y, z: z)
        be!.output = 0
        world.setBlockEntity(be!)
    }
    if be!.output != out {
        be!.output = out
        let newId = out > 0 ? B.comparator_on : B.comparator
        if (c >> 4) != Int(newId) {
            world.setBlock(x, y, z, Int(cell(newId, meta)))
            world.setBlockEntity(be!)
        } else {
            world.updateNeighbors(x, y, z)
        }
    }
}

// ---------------------------------------------------------------------------
// Entity-driven triggers (plates, tripwire, detector rails) — called per tick
// ---------------------------------------------------------------------------
private func plateAccepts(_ plateId: Int, _ e: EntityRef) -> Bool {
    if plateId == Int(B.stone_pressure_plate) || plateId == Int(B.polished_blackstone_pressure_plate) {
        return e is LivingEntity // mobs + players only
    }
    return true // wood + weighted accept all
}

public func tickEntityTriggers(_ world: World) {
    for e in world.entities {
        guard let ent = e as? Entity, !ent.dead else { continue }
        let bx = ifloor(ent.x), by = ifloor(ent.y), bz = ifloor(ent.z)
        let c = world.getBlock(bx, by, bz)
        let id = c >> 4
        if isPressurePlate(id) && plateAccepts(id, ent) {
            if (c & 8) == 0 {
                world.setBlock(bx, by, bz, Int(cell(UInt16(id), (c & 7) | 8)))
                world.hooks.playSound("block.stone_pressure_plate.click_on", Double(bx) + 0.5, Double(by), Double(bz) + 0.5, 0.4, 0.8)
                world.updateNeighbors(bx, by - 1, bz)
            }
            world.scheduleTick(bx, by, bz, id, 20)
        } else if id == Int(B.tripwire) {
            if (c & 8) == 0 {
                world.setBlock(bx, by, bz, Int(cell(B.tripwire, (c & 7) | 8)))
                // find + power hooks at both ends
                for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    for i in 1...40 {
                        let tc = world.getBlock(bx + dx * i, by, bz + dz * i)
                        if (tc >> 4) == Int(B.tripwire) { continue }
                        if (tc >> 4) == Int(B.tripwire_hook) {
                            world.setBlock(bx + dx * i, by, bz + dz * i, Int(cell(B.tripwire_hook, (tc & 7) | 8)))
                            world.scheduleTick(bx + dx * i, by, bz + dz * i, Int(B.tripwire_hook), 10)
                        }
                        break
                    }
                }
                world.scheduleTick(bx, by, bz, Int(B.tripwire), 10)
            }
        } else if ent.type == "minecart" {
            let rc = world.getBlock(bx, by, bz)
            if (rc >> 4) == Int(B.detector_rail) && (rc & 8) == 0 {
                world.setBlock(bx, by, bz, Int(cell(B.detector_rail, (rc & 7) | 8)))
                world.updateNeighbors(bx, by, bz)
                world.updateNeighbors(bx, by - 1, bz)
                world.scheduleTick(bx, by, bz, Int(B.detector_rail), 20)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Note block
// ---------------------------------------------------------------------------
public func playNoteBlock(_ world: World, _ x: Int, _ y: Int, _ z: Int) {
    if world.getBlock(x, y + 1, z) != 0 { return }
    let note = world.getBlockEntity(x, y, z)?.note ?? 0
    let below = world.getBlock(x, y - 1, z) >> 4
    let name = blockDefs[below].name
    var instrument = "harp"
    if name.contains("wool") { instrument = "guitar" }
    else if name.contains("sand") || name.contains("gravel") { instrument = "snare" }
    else if name.contains("glass") || name.contains("sea_lantern") { instrument = "hat" }
    else if name.contains("stone") || name.contains("netherrack") || name.contains("obsidian") || name.contains("quartz") || name.contains("sandstone") || name.contains("prismarine") || name.contains("brick") || name.contains("deepslate") || name.contains("blackstone") { instrument = "basedrum" }
    else if name.contains("gold_block") { instrument = "bell" }
    else if name.contains("clay") { instrument = "flute" }
    else if name.contains("packed_ice") { instrument = "chime" }
    else if name.contains("bone_block") { instrument = "xylophone" }
    else if name.contains("iron_block") { instrument = "iron_xylophone" }
    else if name.contains("soul_sand") { instrument = "cow_bell" }
    else if name.contains("pumpkin") { instrument = "didgeridoo" }
    else if name.contains("emerald_block") { instrument = "bit" }
    else if name.contains("hay_block") { instrument = "banjo" }
    else if name.contains("glowstone") { instrument = "pling" }
    else if name.contains("planks") || name.contains("log") || name.contains("wood") { instrument = "bass" }
    world.hooks.playSound("note.\(instrument).\(note)", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
    world.hooks.addParticles("note", Double(x) + 0.5, Double(y) + 1.1, Double(z) + 0.5, 1, 0, note)
    world.emitVibration(Double(x), Double(y), Double(z), 10, nil)
}

// ---------------------------------------------------------------------------
// Dispenser / dropper
// ---------------------------------------------------------------------------
private func dispense(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ c: Int, _ isDispenser: Bool) {
    guard let be = world.getBlockEntity(x, y, z), be.type == "container" else { return }
    var items = be.items ?? []
    // pick random non-empty slot
    var slots: [Int] = []
    for i in 0..<items.count where items[i] != nil { slots.append(i) }
    if slots.isEmpty {
        world.hooks.playSound("block.dispenser.fail", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1.2)
        return
    }
    let slot = slots[redstoneRng.nextInt(slots.count)]
    let stack = items[slot]!
    let facing = c & 7
    let name = itemDef(stack.id).name

    if isDispenser {
        let handled = dispenseBehavior(world, x, y, z, facing, stack, be, slot, name)
        if handled {
            world.hooks.playSound("block.dispenser.dispense", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            return
        }
        items = be.items ?? items
    }
    // default: spit the item out
    stack.count -= 1
    if stack.count <= 0 { items[slot] = nil }
    be.items = items
    let one = stack.copy()
    one.count = 1
    let item = spawnItem(world, Double(x) + 0.5 + Double(DIR_X[facing]) * 0.7, Double(y) + 0.5 + Double(DIR_Y[facing]) * 0.7, Double(z) + 0.5 + Double(DIR_Z[facing]) * 0.7, one)
    item.vx = Double(DIR_X[facing]) * 0.2 + (redstoneRng.nextFloat() - 0.5) * 0.05
    item.vy = Double(DIR_Y[facing]) * 0.2 + 0.1
    item.vz = Double(DIR_Z[facing]) * 0.2 + (redstoneRng.nextFloat() - 0.5) * 0.05
    world.hooks.playSound("block.dispenser.dispense", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
}

private func dispenseBehavior(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ facing: Int,
                              _ stack: ItemStack, _ be: BlockEntityData, _ slot: Int, _ name: String) -> Bool {
    let fx = x + DIR_X[facing], fy = y + DIR_Y[facing], fz = z + DIR_Z[facing]
    func consume() {
        stack.count -= 1
        if stack.count <= 0 {
            var items = be.items ?? []
            items[slot] = nil
            be.items = items
        }
    }
    func clearSlot() {
        var items = be.items ?? []
        items[slot] = nil
        be.items = items
    }
    func replaceSlot(_ s: ItemStack) {
        var items = be.items ?? []
        items[slot] = s
        be.items = items
    }
    func shoot(_ p: Projectile, _ power: Double) {
        p.setPos(Double(x) + 0.5 + Double(DIR_X[facing]) * 0.8, Double(y) + 0.5 + Double(DIR_Y[facing]) * 0.8, Double(z) + 0.5 + Double(DIR_Z[facing]) * 0.8)
        p.shoot(Double(DIR_X[facing]), Double(DIR_Y[facing]) + 0.1, Double(DIR_Z[facing]), power, 6)
        world.addEntity(p)
    }
    if name == "arrow" || name == "spectral_arrow" || name == "tipped_arrow" {
        let a = ArrowEntity(world: world)
        a.pickupable = true
        a.spectral = name == "spectral_arrow"
        a.potionId = name == "tipped_arrow" ? stack.data.potion : nil
        shoot(a, 1.1)
        consume()
        return true
    }
    if name == "snowball" { shoot(ThrownSnowball(world: world), 1.1); consume(); return true }
    if name == "egg" { shoot(ThrownEgg(world: world), 1.1); consume(); return true }
    if name == "splash_potion" || name == "lingering_potion" {
        let p = ThrownPotion(world: world)
        p.potionId = stack.data.potion ?? "water"
        p.lingering = name == "lingering_potion"
        shoot(p, 1.1)
        consume()
        return true
    }
    if name == "fire_charge" {
        let f = Fireball(world: world)
        f.small = true
        shoot(f, 1.0)
        consume()
        return true
    }
    if name == "tnt" {
        igniteTNT(world, fx, fy, fz)
        consume()
        return true
    }
    if name == "flint_and_steel" {
        if world.getBlock(fx, fy, fz) == 0 {
            world.setBlock(fx, fy, fz, Int(cell(B.fire)))
            stack.damage += 1
            if stack.damage >= 64 { clearSlot() }
            return true
        }
        return false
    }
    if name == "water_bucket" || name == "lava_bucket" {
        let target = world.getBlock(fx, fy, fz)
        if target == 0 || blockDefs[target >> 4].replaceable {
            world.setBlock(fx, fy, fz, Int(cell(name == "water_bucket" ? B.water : B.lava, 0)))
            replaceSlot(ItemStack(iid("bucket"), 1))
            return true
        }
        return false
    }
    if name == "bucket" {
        let target = world.getBlock(fx, fy, fz)
        let tid = target >> 4
        if (tid == Int(B.water) || tid == Int(B.lava)) && (target & 15) == 0 {
            world.setBlock(fx, fy, fz, 0)
            replaceSlot(ItemStack(iid(tid == Int(B.water) ? "water_bucket" : "lava_bucket"), 1))
            return true
        }
        return false
    }
    if name == "bone_meal" {
        let ok = applyBonemealFn?(world, fx, fy, fz) ?? false
        if ok { consume() }
        return ok
    }
    if name.hasSuffix("_spawn_egg") {
        let mob = String(name.dropLast(10))
        _ = spawnMob(world, mob, Double(fx) + 0.5, Double(fy), Double(fz) + 0.5, SpawnOpts())
        consume()
        return true
    }
    if name == "firework_rocket" {
        let fw = FireworkEntity(world: world)
        fw.setPos(Double(fx) + 0.5, Double(fy) + 0.5, Double(fz) + 0.5)
        fw.vy = 0.5
        world.addEntity(fw)
        consume()
        return true
    }
    if name == "shears" {
        // shear sheep in front
        for e in world.getEntitiesNear(Double(fx) + 0.5, Double(fy) + 0.5, Double(fz) + 0.5, 1.2, filter: { e2 in
            guard let sheep = e2 as? Sheep else { return false }
            return !sheep.sheared
        }) {
            guard let sheep = e as? Sheep else { continue }
            sheep.sheared = true
            // baseline: rng-in-loop-condition — rerolls every iteration check
            var i = 0
            while i < 1 + redstoneRng.nextInt(3) {
                spawnItem(world, sheep.x, sheep.y + 0.5, sheep.z, ItemStack(iid("white_wool"), 1))
                i += 1
            }
            stack.damage += 1
            if stack.damage >= 238 { clearSlot() }
            return true
        }
        return false
    }
    return false
}

public var applyBonemealFn: ((World, Int, Int, Int) -> Bool)?
public func bindBonemeal(_ fn: ((World, Int, Int, Int) -> Bool)?) { applyBonemealFn = fn }

// ---------------------------------------------------------------------------
// Powered rails (chain propagation)
// ---------------------------------------------------------------------------
private func railChainPowered(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ railId: Int, _ depth: Int) -> Bool {
    if powerAt(world, x, y, z) > 0 { return true }
    if depth >= 8 { return false }
    // follow the rail line both ways
    let c = world.getBlock(x, y, z)
    let shape = c & 7
    let axisX = shape == 1 || shape == 2 || shape == 3
    let dirs = axisX ? [(1, 0), (-1, 0)] : [(0, 1), (0, -1)]
    for (dx, dz) in dirs {
        for dy in [0, 1, -1] {
            let nc = world.getBlock(x + dx, y + dy, z + dz)
            if (nc >> 4) == railId {
                if powerAt(world, x + dx, y + dy, z + dz) > 0 { return true }
                if depth < 8 && railChainPoweredShallow(world, x + dx, y + dy, z + dz, railId, depth + 1, dx, dz) { return true }
                break
            }
        }
    }
    return false
}
private func railChainPoweredShallow(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ railId: Int, _ depth: Int, _ dx: Int, _ dz: Int) -> Bool {
    if powerAt(world, x, y, z) > 0 { return true }
    if depth >= 8 { return false }
    for dy in [0, 1, -1] {
        let nc = world.getBlock(x + dx, y + dy, z + dz)
        if (nc >> 4) == railId {
            return railChainPoweredShallow(world, x + dx, y + dy, z + dz, railId, depth + 1, dx, dz)
        }
    }
    return false
}

// ---------------------------------------------------------------------------
// Sculk sensors & shriekers
// ---------------------------------------------------------------------------
public func handleVibration(_ world: World, _ x: Double, _ y: Double, _ z: Double, _ freq: Int) {
    // find sensors within 8 blocks via chunk-tracked sets
    let cx0 = ifloor((x - 8) / 16), cx1 = ifloor((x + 8) / 16)
    let cz0 = ifloor((z - 8) / 16), cz1 = ifloor((z + 8) / 16)
    for cz in cz0...cz1 {
        for cx in cx0...cx1 {
            guard let chunk = world.getChunk(cx, cz) else { continue }
            // Set iteration is hash-ordered — sort so multi-sensor activations
            // schedule their ticks in a deterministic order
            for idx in chunk.sculkSensors.sorted() {
                let (sx, sy, sz) = chunk.idxToWorld(idx)
                let ddx = Double(sx) - x, ddy = Double(sy) - y, ddz = Double(sz) - z
                let dSq = ddx * ddx + ddy * ddy + ddz * ddz
                if dSq > 64 { continue }
                let c = world.getBlock(sx, sy, sz)
                let id = c >> 4
                if id == Int(B.sculk_sensor) || id == Int(B.calibrated_sculk_sensor) {
                    if (c & 15) > 0 { continue } // cooldown
                    // calibrated filters by side input
                    if id == Int(B.calibrated_sculk_sensor) {
                        let inputPower = powerAt(world, sx, sy, sz)
                        if inputPower > 0 && inputPower != freq { continue }
                    }
                    let dist = dSq.squareRoot()
                    let power = max(1, min(15, Int(detRound((1 - dist / 8) * 15))))
                    world.setBlock(sx, sy, sz, Int(cell(UInt16(id), power)))
                    world.scheduleTick(sx, sy, sz, id, 40)
                    world.hooks.playSound("block.sculk_sensor.clicking", Double(sx) + 0.5, Double(sy) + 0.5, Double(sz) + 0.5, 1, 1)
                    world.hooks.addParticles("sculk_soul", Double(sx) + 0.5, Double(sy) + 0.5, Double(sz) + 0.5, 3, 0.3, 0)
                } else if id == Int(B.sculk_shrieker) {
                    shriek(world, sx, sy, sz)
                }
            }
        }
    }
}

public var wardenWarnings = 0
public func shriek(_ world: World, _ x: Int, _ y: Int, _ z: Int) {
    let c = world.getBlock(x, y, z)
    if (c & 1) != 0 { return } // already shrieking
    world.setBlock(x, y, z, Int(cell(B.sculk_shrieker, 1)), 4)
    world.scheduleTick(x, y, z, Int(B.sculk_shrieker), 60)
    world.hooks.playSound("block.sculk_shrieker.shriek", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 3, 1)
    world.hooks.addParticles("sculk_soul", Double(x) + 0.5, Double(y) + 1, Double(z) + 0.5, 10, 0.3, 0)
    if world.getBlockEntity(x, y, z)?.canSummon == true {
        wardenWarnings += 1
        for p in world.getEntitiesNear(Double(x), Double(y), Double(z), 16, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
            (p as? LivingEntity)?.addEffect("darkness", 200, 0)
        }
        if wardenWarnings >= 4 {
            wardenWarnings = 0
            // summon warden if none nearby
            let wardens = world.getEntitiesNear(Double(x), Double(y), Double(z), 48, filter: { ($0 as? Entity)?.type == "warden" })
            if wardens.isEmpty {
                _ = spawnMob(world, "warden", Double(x) + 0.5, Double(y), Double(z) + 0.5, SpawnOpts())
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Pistons
// ---------------------------------------------------------------------------
private func pistonPowered(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ facing: Int) -> Bool {
    for d in 0..<6 {
        if d == facing { continue }
        let nx = x + DIR_X[d], ny = y + DIR_Y[d], nz = z + DIR_Z[d]
        if emittedPower(world, nx, ny, nz, DIR_OPPOSITE[d]) > 0 { return true }
        let nc = world.getBlock(nx, ny, nz)
        if blockDefs[nc >> 4].opaque && blockDefs[nc >> 4].fullCube && strongPowerAt(world, nx, ny, nz) > 0 { return true }
    }
    // quasi-connectivity: check the block above (powered there counts)
    if powerAt(world, x, y + 1, z) > 0 { return true }
    return false
}

private func gatherPushSet(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ facing: Int) -> [(Int, Int, Int)]? {
    struct K: Hashable { let x: Int, y: Int, z: Int }
    let dx = DIR_X[facing], dy = DIR_Y[facing], dz = DIR_Z[facing]
    var set: [(Int, Int, Int)] = []
    var seen = Set<K>()
    var toCheck: [(Int, Int, Int)] = [(x + dx, y + dy, z + dz)]
    var head = 0
    while head < toCheck.count {
        let (px, py, pz) = toCheck[head]
        head += 1
        let k = K(x: px, y: py, z: pz)
        if seen.contains(k) { continue }
        let c = world.getBlock(px, py, pz)
        let id = c >> 4
        if id == 0 || blockDefs[id].replaceable { continue }
        let behavior = blockDefs[id].piston
        if behavior == .destroy { continue } // destroyed on push, not part of set
        if behavior == .block || behavior == .blockEntity || blockDefs[id].hardness < 0 { return nil }
        seen.insert(k)
        set.append((px, py, pz))
        if set.count > 12 { return nil }
        // block in front must move too
        toCheck.append((px + dx, py + dy, pz + dz))
        // slime/honey adhesion
        if id == Int(B.slime_block) || id == Int(B.honey_block) {
            for d in 0..<6 {
                let nx = px + DIR_X[d], ny = py + DIR_Y[d], nz = pz + DIR_Z[d]
                let nc = world.getBlock(nx, ny, nz) >> 4
                if nc == 0 { continue }
                // slime doesn't stick to honey
                if (id == Int(B.slime_block) && nc == Int(B.honey_block)) || (id == Int(B.honey_block) && nc == Int(B.slime_block)) { continue }
                if blockDefs[nc].piston == .normal && !seen.contains(K(x: nx, y: ny, z: nz)) {
                    toCheck.append((nx, ny, nz))
                }
            }
        }
    }
    return set
}

private func pistonTick(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ c: Int) {
    let id = c >> 4
    let facing = c & 7
    let extended = (c & 8) != 0
    let powered = pistonPowered(world, x, y, z, facing)
    let dx = DIR_X[facing], dy = DIR_Y[facing], dz = DIR_Z[facing]
    if powered && !extended {
        // EXTEND
        guard var set = gatherPushSet(world, x, y, z, facing) else { return }
        // sort: move farthest first (stable mirror of deterministic sort on distance)
        set = set.enumerated()
            .sorted { a, b in
                let da = (a.element.0 - x) * dx + (a.element.1 - y) * dy + (a.element.2 - z) * dz
                let db = (b.element.0 - x) * dx + (b.element.1 - y) * dy + (b.element.2 - z) * dz
                return da != db ? da > db : a.offset < b.offset
            }
            .map { $0.element }
        for (px, py, pz) in set {
            let destX = px + dx, destY = py + dy, destZ = pz + dz
            let destC = world.getBlock(destX, destY, destZ)
            if destC != 0 && blockDefs[destC >> 4].piston == .destroy {
                world.breakBlockNaturally(destX, destY, destZ)
            }
            world.setBlock(destX, destY, destZ, world.getBlock(px, py, pz))
            world.setBlock(px, py, pz, 0)
        }
        // destroy block directly in front if Destroy-type and not moved
        let frontC = world.getBlock(x + dx, y + dy, z + dz)
        if frontC != 0 && blockDefs[frontC >> 4].piston == .destroy {
            world.breakBlockNaturally(x + dx, y + dy, z + dz)
        }
        world.setBlock(x, y, z, Int(cell(UInt16(id), facing | 8)))
        world.setBlock(x + dx, y + dy, z + dz, Int(cell(B.piston_head, facing | (id == Int(B.sticky_piston) ? 8 : 0))))
        world.hooks.playSound("block.piston.extend", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.6, 0.8)
        // push entities
        let box = AABB(Double(x + dx), Double(y + dy), Double(z + dz), Double(x + dx + 1), Double(y + dy) + 1.5, Double(z + dz + 1))
        for e in world.getEntitiesInBox(box) {
            guard let ent = e as? Entity else { continue }
            ent.x += Double(dx) * 1.01
            ent.y += Double(dy) * 1.01
            ent.z += Double(dz) * 1.01
            if dy > 0 { ent.vy = max(ent.vy, 0.3) }
        }
    } else if !powered && extended {
        // RETRACT
        world.setBlock(x + dx, y + dy, z + dz, 0) // remove head
        world.setBlock(x, y, z, Int(cell(UInt16(id), facing)))
        if id == Int(B.sticky_piston) {
            // pull the block 2 ahead
            let px = x + dx * 2, py = y + dy * 2, pz = z + dz * 2
            let pc = world.getBlock(px, py, pz)
            let pid = pc >> 4
            if pid != 0 && blockDefs[pid].piston == .normal && blockDefs[pid].hardness >= 0 {
                world.setBlock(x + dx, y + dy, z + dz, pc)
                world.setBlock(px, py, pz, 0)
            }
        }
        world.hooks.playSound("block.piston.contract", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.6, 0.7)
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------
private var redstoneRegistered = false

public func registerRedstoneHandlers() {
    if redstoneRegistered { return }
    redstoneRegistered = true

    WOOD_BUTTONS = WOODS.map { Int(bid("\($0)_button")) }
    WOOD_PLATES = WOODS.map { Int(bid("\($0)_pressure_plate")) }

    neighborHandlers[Int(B.redstone_wire)] = { world, x, y, z, _, _, _, _ in
        // support check
        let below = world.getBlock(x, y - 1, z)
        if !blockDefs[below >> 4].fullCube {
            world.breakBlockNaturally(x, y, z)
            return
        }
        updateWireNetwork(world, x, y, z)
    }
    onPlacedHandlers[Int(B.redstone_wire)] = { world, x, y, z, _ in updateWireNetwork(world, x, y, z) }

    blockTickHandlers[Int(B.redstone_torch)] = torchTick
    blockTickHandlers[Int(B.redstone_torch_off)] = torchTick
    neighborHandlers[Int(B.redstone_torch)] = { world, x, y, z, _, _, _, _ in
        if !world.hasScheduledTick(x, y, z, Int(B.redstone_torch)) { world.scheduleTick(x, y, z, Int(B.redstone_torch), 2) }
    }
    neighborHandlers[Int(B.redstone_torch_off)] = { world, x, y, z, _, _, _, _ in
        if !world.hasScheduledTick(x, y, z, Int(B.redstone_torch_off)) { world.scheduleTick(x, y, z, Int(B.redstone_torch_off), 2) }
    }

    neighborHandlers[Int(B.repeater)] = { world, x, y, z, c, _, _, _ in repeaterNeighbor(world, x, y, z, c) }
    neighborHandlers[Int(B.repeater_on)] = { world, x, y, z, c, _, _, _ in repeaterNeighbor(world, x, y, z, c) }
    blockTickHandlers[Int(B.repeater)] = { world, x, y, z, c in
        let meta = c & 15
        if repeaterLocked(world, x, y, z, meta & 3) { return }
        if repeaterInputPower(world, x, y, z, meta & 3) > 0 {
            world.setBlock(x, y, z, Int(cell(B.repeater_on, meta)))
        }
    }
    blockTickHandlers[Int(B.repeater_on)] = { world, x, y, z, c in
        let meta = c & 15
        if repeaterLocked(world, x, y, z, meta & 3) { return }
        if repeaterInputPower(world, x, y, z, meta & 3) == 0 {
            world.setBlock(x, y, z, Int(cell(B.repeater, meta)))
        }
    }

    blockTickHandlers[Int(B.comparator)] = comparatorTick
    blockTickHandlers[Int(B.comparator_on)] = comparatorTick
    let comparatorNeighbor: NeighborFn = { world, x, y, z, c, _, _, _ in
        if !world.hasScheduledTick(x, y, z, c >> 4) { world.scheduleTick(x, y, z, c >> 4, 2) }
    }
    neighborHandlers[Int(B.comparator)] = comparatorNeighbor
    neighborHandlers[Int(B.comparator_on)] = comparatorNeighbor

    neighborHandlers[Int(B.observer)] = { world, x, y, z, c, fx, fy, fz in
        let meta = c & 15
        let facing = meta & 7
        // only triggers when the WATCHED block (in facing dir) changed
        if fx == x + DIR_X[facing] && fy == y + DIR_Y[facing] && fz == z + DIR_Z[facing] {
            if (meta & 8) == 0 && !world.hasScheduledTick(x, y, z, Int(B.observer)) {
                world.scheduleTick(x, y, z, Int(B.observer), 2)
            }
        }
    }
    blockTickHandlers[Int(B.observer)] = { world, x, y, z, c in
        let meta = c & 15
        if (meta & 8) != 0 {
            world.setBlock(x, y, z, Int(cell(B.observer, meta & 7)))
        } else {
            world.setBlock(x, y, z, Int(cell(B.observer, meta | 8)))
            world.scheduleTick(x, y, z, Int(B.observer), 2)
        }
    }

    // buttons / plates ----------------------------------------------------------
    for btn in [Int(B.stone_button), Int(B.polished_blackstone_button)] + WOOD_BUTTONS {
        blockTickHandlers[btn] = { world, x, y, z, c in
            // unpress
            if (c & 8) != 0 {
                world.setBlock(x, y, z, Int(cell(UInt16(btn), c & 7)))
                world.hooks.playSound("block.stone_button.click_off", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.5, 0.8)
                let attach = c & 7
                world.updateNeighbors(x + DIR_X[attach], y + DIR_Y[attach], z + DIR_Z[attach])
            }
        }
    }
    for plate in [Int(B.stone_pressure_plate), Int(B.polished_blackstone_pressure_plate), Int(B.light_weighted_pressure_plate), Int(B.heavy_weighted_pressure_plate)] + WOOD_PLATES {
        blockTickHandlers[plate] = { world, x, y, z, c in
            // re-check entities; release if none
            let box = AABB(Double(x), Double(y), Double(z), Double(x + 1), Double(y) + 0.3, Double(z + 1))
            let entities = world.getEntitiesInBox(box)
            let filtered = entities.filter { plateAccepts(plate, $0) }
            if filtered.isEmpty {
                if (c & 8) != 0 {
                    world.setBlock(x, y, z, Int(cell(UInt16(plate), c & 7)))
                    world.hooks.playSound("block.stone_pressure_plate.click_off", Double(x) + 0.5, Double(y), Double(z) + 0.5, 0.4, 0.7)
                    world.updateNeighbors(x, y - 1, z)
                }
            } else {
                world.scheduleTick(x, y, z, plate, 20)
            }
        }
    }

    blockTickHandlers[Int(B.tripwire)] = { world, x, y, z, c in
        // release if no entity
        let box = AABB(Double(x), Double(y), Double(z), Double(x + 1), Double(y) + 0.5, Double(z + 1))
        if world.getEntitiesInBox(box).isEmpty {
            world.setBlock(x, y, z, Int(cell(B.tripwire, c & 7)))
        } else {
            world.scheduleTick(x, y, z, Int(B.tripwire), 10)
        }
    }
    blockTickHandlers[Int(B.tripwire_hook)] = { world, x, y, z, c in
        if (c & 8) != 0 {
            world.setBlock(x, y, z, Int(cell(B.tripwire_hook, c & 7)))
            let facing = c & 3
            world.updateNeighbors(x - FACING_DX[facing], y, z - FACING_DZ[facing])
        }
    }
    blockTickHandlers[Int(B.detector_rail)] = { world, x, y, z, c in
        let box = AABB(Double(x), Double(y), Double(z), Double(x + 1), Double(y + 1), Double(z + 1))
        let carts = world.getEntitiesInBox(box, except: nil, filter: { ($0 as? Entity)?.type == "minecart" })
        if carts.isEmpty && (c & 8) != 0 {
            world.setBlock(x, y, z, Int(cell(B.detector_rail, c & 7)))
            world.updateNeighbors(x, y, z)
            world.updateNeighbors(x, y - 1, z)
        } else if !carts.isEmpty {
            world.scheduleTick(x, y, z, Int(B.detector_rail), 20)
        }
    }
    blockTickHandlers[Int(B.target)] = { world, x, y, z, c in
        if (c & 15) != 0 {
            world.setBlock(x, y, z, Int(cell(B.target, 0)))
        }
    }

    // lamp / doors / gates / hopper / TNT / note ----------------------------------
    neighborHandlers[Int(B.redstone_lamp)] = { world, x, y, z, _, _, _, _ in
        if powerAt(world, x, y, z) > 0 { world.setBlock(x, y, z, Int(cell(B.redstone_lamp_on))) }
    }
    neighborHandlers[Int(B.redstone_lamp_on)] = { world, x, y, z, _, _, _, _ in
        if powerAt(world, x, y, z) == 0 && !world.hasScheduledTick(x, y, z, Int(B.redstone_lamp_on)) {
            world.scheduleTick(x, y, z, Int(B.redstone_lamp_on), 4)
        }
    }
    blockTickHandlers[Int(B.redstone_lamp_on)] = { world, x, y, z, _ in
        if powerAt(world, x, y, z) == 0 { world.setBlock(x, y, z, Int(cell(B.redstone_lamp))) }
    }

    // doors/trapdoors/gates respond to power TRANSITIONS, not absolute state —
    // an absolute check slams a hand-opened door shut on the very next
    // neighbor update (including the self-notify from opening it)
    let doors = WOODS.map { Int(bid("\($0)_door")) } + [Int(B.iron_door)]
    for door in doors {
        neighborHandlers[door] = { world, x, y, z, c, _, _, _ in
            let meta = c & 15
            let isUpper = (meta & 8) != 0
            let lowerY = isUpper ? y - 1 : y
            let powered = powerAt(world, x, lowerY, z) > 0 || powerAt(world, x, lowerY + 1, z) > 0
            let lower = world.getBlock(x, lowerY, z)
            if (lower >> 4) != door { return }
            let key = OpenablePos(x, lowerY, z)
            let wasPowered = world.poweredOpenables.contains(key)
            if powered != wasPowered {
                if powered { world.poweredOpenables.insert(key) } else { world.poweredOpenables.remove(key) }
                let open = (lower & 4) != 0
                if powered != open {
                    world.setBlock(x, lowerY, z, Int(cell(UInt16(door), (lower & 15) ^ 4)))
                    world.hooks.playSound(powered ? "block.wooden_door.open" : "block.wooden_door.close", Double(x) + 0.5, Double(lowerY + 1), Double(z) + 0.5, 1, 1)
                }
            }
            // support check
            let below = world.getBlock(x, lowerY - 1, z)
            if !blockDefs[below >> 4].fullCube && !isUpper {
                world.breakBlockNaturally(x, lowerY, z)
                world.setBlock(x, lowerY + 1, z, 0)
            }
        }
    }
    let trapdoors = WOODS.map { Int(bid("\($0)_trapdoor")) } + [Int(B.iron_trapdoor)]
    for td in trapdoors {
        neighborHandlers[td] = { world, x, y, z, c, _, _, _ in
            let powered = powerAt(world, x, y, z) > 0
            let key = OpenablePos(x, y, z)
            let wasPowered = world.poweredOpenables.contains(key)
            if powered != wasPowered {
                if powered { world.poweredOpenables.insert(key) } else { world.poweredOpenables.remove(key) }
                let open = (c & 4) != 0
                if powered != open {
                    world.setBlock(x, y, z, Int(cell(UInt16(td), (c & 15) ^ 4)))
                }
            }
        }
    }
    for gate in WOODS.map({ Int(bid("\($0)_fence_gate")) }) {
        neighborHandlers[gate] = { world, x, y, z, c, _, _, _ in
            let powered = powerAt(world, x, y, z) > 0
            let key = OpenablePos(x, y, z)
            let wasPowered = world.poweredOpenables.contains(key)
            if powered != wasPowered {
                if powered { world.poweredOpenables.insert(key) } else { world.poweredOpenables.remove(key) }
                let open = (c & 4) != 0
                if powered != open {
                    world.setBlock(x, y, z, Int(cell(UInt16(gate), (c & 15) ^ 4)))
                    world.hooks.playSound(powered ? "block.fence_gate.open" : "block.fence_gate.close", Double(x) + 0.5, Double(y), Double(z) + 0.5, 1, 1)
                }
            }
        }
    }
    neighborHandlers[Int(B.hopper)] = { world, x, y, z, c, _, _, _ in
        let powered = powerAt(world, x, y, z) > 0
        let locked = (c & 8) != 0
        if powered != locked { world.setBlock(x, y, z, Int(cell(B.hopper, (c & 7) | (powered ? 8 : 0))), 4) }
    }
    neighborHandlers[Int(B.tnt)] = { world, x, y, z, _, _, _, _ in
        if powerAt(world, x, y, z) > 0 { igniteTNT(world, x, y, z) }
    }
    neighborHandlers[Int(B.note_block)] = { world, x, y, z, c, _, _, _ in
        let powered = powerAt(world, x, y, z) > 0
        let was = (c & 1) != 0
        if powered && !was {
            world.setBlock(x, y, z, Int(cell(B.note_block, 1)), 4)
            playNoteBlock(world, x, y, z)
        } else if !powered && was {
            world.setBlock(x, y, z, Int(cell(B.note_block, 0)), 4)
        }
    }

    // dispenser / dropper ---------------------------------------------------------
    let dispenserNeighbor: NeighborFn = { world, x, y, z, c, _, _, _ in
        let id = c >> 4
        // quasi-connectivity: also check block above
        let powered = powerAt(world, x, y, z) > 0 || powerAt(world, x, y + 1, z) > 0
        let triggered = (c & 8) != 0
        if powered && !triggered {
            world.scheduleTick(x, y, z, id, 4)
            world.setBlock(x, y, z, Int(cell(UInt16(id), (c & 7) | 8)), 4)
        } else if !powered && triggered {
            world.setBlock(x, y, z, Int(cell(UInt16(id), c & 7)), 4)
        }
    }
    neighborHandlers[Int(B.dispenser)] = dispenserNeighbor
    neighborHandlers[Int(B.dropper)] = dispenserNeighbor
    blockTickHandlers[Int(B.dispenser)] = { world, x, y, z, c in dispense(world, x, y, z, c, true) }
    blockTickHandlers[Int(B.dropper)] = { world, x, y, z, c in dispense(world, x, y, z, c, false) }

    // powered rails --------------------------------------------------------------
    for railId in [Int(B.powered_rail), Int(B.activator_rail)] {
        neighborHandlers[railId] = { world, x, y, z, c, _, _, _ in
            // support check
            let below = world.getBlock(x, y - 1, z)
            if !blockDefs[below >> 4].fullCube {
                world.breakBlockNaturally(x, y, z)
                return
            }
            let powered = railChainPowered(world, x, y, z, railId, 0)
            let was = (c & 8) != 0
            if powered != was {
                world.setBlock(x, y, z, Int(cell(UInt16(railId), (c & 7) | (powered ? 8 : 0))), 1 | 4)
            }
        }
    }
    neighborHandlers[Int(B.rail)] = { world, x, y, z, _, _, _, _ in
        let below = world.getBlock(x, y - 1, z)
        if !blockDefs[below >> 4].fullCube { world.breakBlockNaturally(x, y, z) }
    }

    // sculk sensors / shrieker ------------------------------------------------------
    for sid in [Int(B.sculk_sensor), Int(B.calibrated_sculk_sensor)] {
        blockTickHandlers[sid] = { world, x, y, z, c in
            if (c & 15) != 0 {
                world.setBlock(x, y, z, Int(cell(UInt16(sid), 0)))
            }
        }
    }
    blockTickHandlers[Int(B.sculk_shrieker)] = { world, x, y, z, c in
        if (c & 1) != 0 { world.setBlock(x, y, z, Int(cell(B.sculk_shrieker, 0)), 4) }
    }

    // daylight detector --------------------------------------------------------------
    for dd in [Int(B.daylight_detector), Int(B.daylight_detector_inverted)] {
        blockTickHandlers[dd] = { world, x, y, z, c in
            let sky = world.getSkyLight(x, y + 1, z)
            let dayF = max(0, 1 - world.skyDarken() / 11)
            var power = Int(detRound(Double(sky) * dayF))
            if (c >> 4) == Int(B.daylight_detector_inverted) { power = Int(detRound(Double(sky) * (1 - dayF))) }
            power = max(0, min(15, power))
            if (c & 15) != power {
                world.setBlock(x, y, z, Int(cell(UInt16(c >> 4), power)), 1 | 4)
            }
            world.scheduleTick(x, y, z, c >> 4, 20)
        }
        onPlacedHandlers[dd] = { world, x, y, z, _ in world.scheduleTick(x, y, z, dd, 20) }
    }

    // pistons --------------------------------------------------------------------
    let pistonNeighbor: NeighborFn = { world, x, y, z, c, _, _, _ in
        let id = c >> 4
        let facing = c & 7
        let extended = (c & 8) != 0
        let powered = pistonPowered(world, x, y, z, facing)
        if powered != extended && !world.hasScheduledTick(x, y, z, id) {
            world.scheduleTick(x, y, z, id, 2)
        }
    }
    neighborHandlers[Int(B.piston)] = pistonNeighbor
    neighborHandlers[Int(B.sticky_piston)] = pistonNeighbor
    blockTickHandlers[Int(B.piston)] = pistonTick
    blockTickHandlers[Int(B.sticky_piston)] = pistonTick

    // lightning rod power-off
    blockTickHandlers[Int(B.lightning_rod)] = { world, x, y, z, c in
        if (c & 8) != 0 { world.setBlock(x, y, z, Int(cell(B.lightning_rod, c & 7))) }
    }
}
