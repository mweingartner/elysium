// Boats (with chest variants) and minecarts (with chest/hopper/TNT/furnace)
// including rail physics

import Foundation

public final class Boat: Entity {
    public override var type: String { "boat" }
    public var wood = "oak"
    public var hasChest = false
    public var chestItems: [ItemStack?] = Array(repeating: nil, count: 27)
    public var paddleAnim = 0.0
    public override init(world: World) {
        super.init(world: world)
        width = 1.375
        height = 0.5625
    }
    public override func tick() {
        baseTick()
        let inWaterNow = inWater
        // buoyancy
        if let waterTop = waterSurface() {
            let depth = waterTop - y
            if depth > 0.1 { vy += 0.06 }
            else if depth > 0 { vy += depth * 0.5 + 0.005 }
            vy *= 0.7
        } else if !onGround {
            vy -= 0.04
        }
        // rider control
        if let rider = passengers.first as? LivingEntity, rider.isPlayer {
            yaw += rider.moveStrafe * -0.05
            let f = rider.moveForward
            if f != 0 {
                let sp = inWaterNow ? 0.04 : (onGround ? 0.008 : 0.02)
                vx += -detSin(yaw) * f * sp
                vz += detCos(yaw) * f * sp
                paddleAnim += 0.3
            }
        }
        move(vx, vy, vz)
        let drag = inWaterNow ? 0.94 : onGround ? 0.6 : 0.96
        vx *= drag; vz *= drag
        if onGround && !inWaterNow { vx *= 0.6; vz *= 0.6 }
    }
    // move() zeroes fallDistance on touchdown, so the fall check must hook
    // onLand (a post-move check always saw 0 and boats never broke)
    public override func onLand(_ fallDistance: Double) {
        if fallDistance > 3 { breakBoat() }
    }
    private func waterSurface() -> Double? {
        let bx = ifloor(x), bz = ifloor(z)
        var dy = 1
        while dy >= -1 {
            let by = ifloor(y) + dy
            let c = world.getBlock(bx, by, bz)
            if (c >> 4) == Int(B.water) {
                return Double(by) + world.fluidHeight(bx, by, bz)
            }
            dy -= 1
        }
        return nil
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if dead { return false }
        breakBoat()
        return true
    }
    private func breakBoat() {
        let itemName = hasChest
            ? (wood == "bamboo" ? "bamboo_chest_raft" : wood + "_chest_boat")
            : (wood == "bamboo" ? "bamboo_raft" : wood + "_boat")
        spawnItem(world, x, y + 0.5, z, ItemStack(iid(itemName), 1))
        if hasChest {
            for s in chestItems { if let s { spawnItem(world, x, y + 0.5, z, s) } }
        }
        remove()
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        if hasChest && ((player as? LivingEntity)?.sneaking ?? false) {
            openContainerScreenFn?(player, "boat_chest", self)
            return true
        }
        if passengers.count < (hasChest ? 1 : 2) {
            player.mount(self)
            return true
        }
        return false
    }
    public override func save() -> [String: Any] {
        var d = super.save()
        d["wood"] = wood
        d["hasChest"] = hasChest
        if let enc = try? JSONEncoder().encode(chestItems),
           let obj = try? JSONSerialization.jsonObject(with: enc) {
            d["chestItems"] = obj
        }
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        wood = (d["wood"] as? String) ?? "oak"
        hasChest = (d["hasChest"] as? Bool) ?? false
        if let raw = d["chestItems"],
           let bytes = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode([ItemStack?].self, from: bytes) {
            chestItems = decoded
        } else {
            chestItems = Array(repeating: nil, count: 27)
        }
    }
}

/// late-bound container UI hook (player.openContainerScreen in baseline)
public var openContainerScreenFn: ((Entity, String, Entity) -> Void)?
public func bindOpenContainerScreen(_ fn: ((Entity, String, Entity) -> Void)?) { openContainerScreenFn = fn }

// rails ----------------------------------------------------------------------
private let RAIL_DIRS: [Int: (Int, Int, Int, Int)] = [
    // shape → (dx0, dz0, dx1, dz1) (the two connected directions)
    0: (0, -1, 0, 1),   // NS
    1: (-1, 0, 1, 0),   // EW
    2: (-1, 0, 1, 0),   // asc E
    3: (-1, 0, 1, 0),   // asc W
    4: (0, -1, 0, 1),   // asc N
    5: (0, -1, 0, 1),   // asc S
    6: (0, 1, 1, 0),    // SE curve
    7: (0, 1, -1, 0),   // SW
    8: (0, -1, -1, 0),  // NW
    9: (0, -1, 1, 0),   // NE
]

public final class Minecart: Entity {
    public override var type: String { "minecart" }
    public var variant = "empty"   // empty | chest | hopper | tnt | furnace
    public var chestItems: [ItemStack?] = Array(repeating: nil, count: 27)
    public var fuel = 0
    public var tntFuse = -1
    public override init(world: World) {
        super.init(world: world)
        width = 0.98
        height = 0.7
    }
    private func railAt(_ x: Int, _ y: Int, _ z: Int) -> Int {
        let c = world.getBlock(x, y, z)
        let bid = c >> 4
        if bid >= 0 && bid < SHAPE_OF.count && SHAPE_OF[bid] == Shape.rail.rawValue { return c }
        return -1
    }
    public override func tick() {
        baseTick()
        if tntFuse >= 0 {
            tntFuse -= 1
            if age % 4 == 0 { world.hooks.addParticles("smoke", x, y + 0.8, z, 1, 0.1, 0) }
            if tntFuse <= 0 {
                remove()
                explodeFn?(world, x, y, z, 4 + gameRng.nextFloat() * 1.5, false, self)
                return
            }
        }
        let bx = ifloor(x), bz = ifloor(z)
        var by = ifloor(y)
        var rail = railAt(bx, by, bz)
        if rail == -1 { rail = railAt(bx, by - 1, bz) }
        if rail != -1 {
            by = ifloor(y)
            if railAt(bx, by, bz) == -1 { by -= 1 }
            tickOnRail(bx, by, bz, rail)
        } else {
            // off rail
            vy -= 0.04
            move(vx, vy, vz)
            vx *= onGround ? 0.5 : 0.95
            vz *= onGround ? 0.5 : 0.95
        }
        // rider input minor push
        if let rider = passengers.first as? LivingEntity, rider.isPlayer, rider.moveForward != 0, rail != -1 {
            let sp = (vx * vx + vz * vz).squareRoot()
            if sp < 0.01 {
                vx += -detSin(rider.yaw) * 0.02
                vz += detCos(rider.yaw) * 0.02
            }
        }
        // hopper cart: pick up items
        if variant == "hopper" && age % 4 == 0 {
            for e in world.getEntitiesNear(x, y, z, 1.2, filter: { ($0 as? Entity)?.type == "item" }) {
                guard let item = e as? ItemEntity else { continue }
                if item.pickupDelay > 0 { continue }
                for i in 0..<chestItems.count {
                    if chestItems[i] == nil { chestItems[i] = item.stack; item.remove(); break }
                }
            }
        }
    }
    private func tickOnRail(_ bx: Int, _ by: Int, _ bz: Int, _ rail: Int) {
        let bid = rail >> 4
        let meta = rail & 15
        let shape = bid == Int(B.rail) ? meta : (meta & 7)
        let powered = bid == Int(B.powered_rail) && (meta & 8) != 0
        let dirs = RAIL_DIRS[shape] ?? RAIL_DIRS[0]!
        // gravity on slopes
        if shape >= 2 && shape <= 5 {
            let downX: Double = shape == 2 ? -1 : shape == 3 ? 1 : 0
            let downZ: Double = shape == 4 ? 1 : shape == 5 ? -1 : 0
            vx += downX * 0.0078
            vz += downZ * 0.0078
        }
        // snap velocity to rail axis
        let axisX = Double(dirs.2 - dirs.0), axisZ = Double(dirs.3 - dirs.1)
        var alen = (axisX * axisX + axisZ * axisZ).squareRoot()
        if alen == 0 { alen = 1 }
        let ax = axisX / alen, az = axisZ / alen
        var speed = vx * ax + vz * az
        // friction / boost
        if bid == Int(B.powered_rail) {
            if powered {
                speed = speed == 0 ? 0 : (speed > 0 ? 1.0 : -1.0) * min(0.6, abs(speed) + 0.06)
                if abs(speed) < 0.03 {
                    // launch from solid block behind
                    let behind = world.getBlock(bx - Int(detRound(ax)), by, bz - Int(detRound(az)))
                    if (behind >> 4) != 0 && blockDefs[behind >> 4].solid { speed = 0.3 }
                    let front = world.getBlock(bx + Int(detRound(ax)), by, bz + Int(detRound(az)))
                    if (front >> 4) != 0 && blockDefs[front >> 4].solid { speed = -0.3 }
                }
            } else {
                speed *= 0.6 // unpowered = brake
            }
        } else {
            speed *= passengers.isEmpty ? 0.96 : 0.997
        }
        if variant == "furnace" && fuel > 0 {
            fuel -= 1
            let sgn: Double = (speed != 0 ? speed : 1) > 0 ? 1 : -1
            speed = sgn * min(0.4, abs(speed) + 0.02)
            if age % 20 == 0 { world.hooks.addParticles("smoke", x, y + 0.9, z, 1, 0.1, 0) }
        }
        speed = clampD(speed, -0.6, 0.6)
        vx = ax * speed
        vz = az * speed
        // center on rail
        let cx = Double(bx) + 0.5, cz = Double(bz) + 0.5
        if shape == 0 { x += (cx - x) * 0.3 }
        if shape == 1 { z += (cz - z) * 0.3 }
        // curves: redirect
        if shape >= 6 {
            x += (cx - x) * 0.2
            z += (cz - z) * 0.2
        }
        // slope height
        if shape >= 2 && shape <= 5 {
            let fx = x - Double(bx), fz = z - Double(bz)
            var h = 0.0
            if shape == 2 { h = fx }
            else if shape == 3 { h = 1 - fx }
            else if shape == 4 { h = 1 - fz }
            else if shape == 5 { h = fz }
            y = Double(by) + h + 0.0625 + 0.2
            vy = 0
        } else {
            y = Double(by) + 0.0625 + 0.2
            vy = 0
        }
        x += vx
        z += vz
        onGround = true
        if abs(vx) > 0.001 || abs(vz) > 0.001 {
            yaw = detAtan2(-vx, vz) + .pi / 2
        }
        // detector rail trigger handled by redstone system scanning carts
        // activator rail: eject / tnt ignite
        let below = world.getBlock(bx, by, bz)
        if (below >> 4) == Int(B.activator_rail) && (below & 8) != 0 {
            if variant == "tnt" && tntFuse < 0 {
                tntFuse = 80
                world.hooks.playSound("entity.tnt.primed", x, y, z, 1, 1)
            } else if !passengers.isEmpty {
                for p in passengers { p.dismount() }
            }
        }
    }
    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        if dead { return false }
        if variant == "tnt" && (source == "fire" || source == "explosion") {
            tntFuse = 10
            return true
        }
        let itemName = variant == "empty" ? "minecart" : "\(variant)_minecart"
        spawnItem(world, x, y, z, ItemStack(iid(itemName), 1))
        if variant == "chest" || variant == "hopper" {
            for s in chestItems { if let s { spawnItem(world, x, y, z, s) } }
        }
        remove()
        return true
    }
    public override func interact(_ player: Entity, _ stack: ItemStack?) -> Bool {
        if variant == "chest" || variant == "hopper" {
            openContainerScreenFn?(player, "minecart_chest", self)
            return true
        }
        if variant == "furnace" {
            let name = stack.map { itemDef($0.id).name }
            if name == "coal" || name == "charcoal" {
                fuel += 3600
                (player as? LivingEntity)?.consumeHeld(1)
                return true
            }
            return false
        }
        if variant == "empty" && passengers.isEmpty {
            player.mount(self)
            return true
        }
        return false
    }
    public override func save() -> [String: Any] {
        var d = super.save()
        d["variant"] = variant
        if let enc = try? JSONEncoder().encode(chestItems),
           let obj = try? JSONSerialization.jsonObject(with: enc) {
            d["chestItems"] = obj
        }
        d["fuel"] = fuel
        return d
    }
    public override func load(_ d: [String: Any]) {
        super.load(d)
        variant = (d["variant"] as? String) ?? "empty"
        if let raw = d["chestItems"],
           let bytes = try? JSONSerialization.data(withJSONObject: raw),
           let decoded = try? JSONDecoder().decode([ItemStack?].self, from: bytes) {
            chestItems = decoded
        } else {
            chestItems = Array(repeating: nil, count: 27)
        }
        fuel = inum(d["fuel"])
    }
}
