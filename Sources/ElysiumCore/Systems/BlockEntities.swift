// Block entity tickers — furnaces, brewing
// stands, hoppers, campfires, spawners, beacons, conduits. Registered into
// the world handler maps.

import Foundation

// ---------------------------------------------------------------------------
// Furnace family
// ---------------------------------------------------------------------------
public func smeltResultFor(_ input: ItemStack?, _ kind: String) -> (output: String, xp: Double)? {
    guard let input else { return nil }
    let name = itemDef(input.id).name
    for r in smeltingRecipes {
        if r.input != name { continue }
        if kind == "furnace" { return (r.output, r.xp) }
        if kind == "blast" && (r.kind == "blast" || r.kind == "any") { return (r.output, r.xp) }
        if kind == "smoker" && r.kind == "smoke" { return (r.output, r.xp) }
    }
    return nil
}
public func fuelTime(_ s: ItemStack?) -> Int {
    guard let s else { return 0 }
    return itemDef(s.id).burnTime
}

private func containerAt(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> BlockEntityData? {
    guard let be = world.getBlockEntity(x, y, z) else { return nil }
    if be.type == "container" || be.type == "hopper" || be.type == "furnace" || be.type == "brewing" {
        return be.items != nil ? be : nil
    }
    return nil
}

private func insertInto(_ be: BlockEntityData, _ stack: ItemStack, _ slotFilter: ((Int) -> Bool)? = nil) -> Bool {
    guard var items = be.items else { return false }
    defer { be.items = items }
    for i in 0..<items.count {
        if let f = slotFilter, !f(i) { continue }
        if let s = items[i], canMerge(s, stack), s.count < maxStackOf(s) {
            s.count += 1
            stack.count -= 1
            return true
        }
    }
    for i in 0..<items.count {
        if let f = slotFilter, !f(i) { continue }
        if items[i] == nil {
            let one = stack.copy()
            one.count = 1
            items[i] = one
            stack.count -= 1
            return true
        }
    }
    return false
}

private var blockEntitiesRegistered = false

public func registerBlockEntityHandlers() {
    if blockEntitiesRegistered { return }
    blockEntitiesRegistered = true

    beTickHandlers["furnace"] = { world, be in
        let kind = be.kind ?? "furnace"
        let speed = kind == "furnace" ? 1 : 2
        var items = be.items ?? [nil, nil, nil]
        defer { be.items = items }
        let wasBurning = (be.burnTime ?? 0) > 0
        if (be.burnTime ?? 0) > 0 { be.burnTime = (be.burnTime ?? 0) - speed }
        let result = smeltResultFor(items[0], kind)
        let out = items[2]
        let canOutput = result != nil && (out == nil || (itemDef(out!.id).name == result!.output && out!.count < maxStackOf(out!)))

        if (be.burnTime ?? 0) <= 0 && canOutput {
            let fuel = fuelTime(items[1])
            if fuel > 0 {
                be.burnTime = fuel
                be.burnTotal = fuel
                let f = items[1]!
                if itemDef(f.id).name == "lava_bucket" {
                    items[1] = ItemStack(iid("bucket"), 1)
                } else {
                    f.count -= 1
                    if f.count <= 0 { items[1] = nil }
                }
            }
        }
        if (be.burnTime ?? 0) > 0 && canOutput {
            be.cookTime = (be.cookTime ?? 0) + speed
            if (be.cookTime ?? 0) >= (be.cookTotal ?? 200) {
                be.cookTime = 0
                let input = items[0]!
                input.count -= 1
                if input.count <= 0 { items[0] = nil }
                if let out { out.count += 1 }
                else { items[2] = ItemStack(iid(result!.output), 1) }
                be.xpBank = (be.xpBank ?? 0) + result!.xp
            }
        } else {
            be.cookTime = max(0, (be.cookTime ?? 0) - 2)
        }
        // lit state
        let isBurning = (be.burnTime ?? 0) > 0
        if isBurning != wasBurning {
            let c = world.getBlock(be.x, be.y, be.z)
            let bid = c >> 4
            let meta = c & 15
            let litMap: [Int: UInt16] = [
                Int(B.furnace): B.furnace_lit, Int(B.furnace_lit): B.furnace_lit,
                Int(B.blast_furnace): B.blast_furnace_lit, Int(B.blast_furnace_lit): B.blast_furnace_lit,
                Int(B.smoker): B.smoker_lit, Int(B.smoker_lit): B.smoker_lit,
            ]
            let unlitMap: [Int: UInt16] = [
                Int(B.furnace_lit): B.furnace, Int(B.furnace): B.furnace,
                Int(B.blast_furnace_lit): B.blast_furnace, Int(B.blast_furnace): B.blast_furnace,
                Int(B.smoker_lit): B.smoker, Int(B.smoker): B.smoker,
            ]
            let newId = isBurning ? litMap[bid] : unlitMap[bid]
            if let newId, Int(newId) != bid {
                be.items = items
                world.setBlock(be.x, be.y, be.z, Int(cell(newId, meta)))
                // setBlock with different id removes BEs of changed blocks — re-attach
                world.setBlockEntity(be)
                items = be.items ?? items
            }
        }
        if isBurning && world.time % 24 == 0 {
            world.hooks.addParticles("flame", Double(be.x) + 0.5, Double(be.y) + 0.3, Double(be.z) + 0.5, 1, 0.3, 0)
            world.hooks.playSound("block.furnace.fire_crackle", Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 0.3, 1)
        }
    }

    beTickHandlers["brewing"] = { world, be in
        var items = be.items ?? [nil, nil, nil, nil, nil]
        defer { be.items = items }
        // refuel
        if (be.fuel ?? 0) <= 0, let f = items[4] {
            if itemDef(f.id).name == "blaze_powder" {
                be.fuel = 20
                f.count -= 1
                if f.count <= 0 { items[4] = nil }
            }
        }
        guard let ing = items[3] else { be.brewTime = 0; return }
        let ingName = itemDef(ing.id).name
        // check any bottle can brew
        var anyBrewable = false
        for i in 0..<3 {
            guard let bottle = items[i] else { continue }
            let bName = itemDef(bottle.id).name
            if bName != "potion" && bName != "splash_potion" && bName != "lingering_potion" { continue }
            let potionId = bottle.data.potion ?? "water"
            if ingName == "gunpowder" && bName == "potion" { anyBrewable = true; break }
            if ingName == "dragon_breath" && bName == "splash_potion" { anyBrewable = true; break }
            if findBrew(potionId, ingName) != nil { anyBrewable = true; break }
        }
        if !anyBrewable || (be.fuel ?? 0) <= 0 { be.brewTime = 0; return }
        if (be.brewTime ?? 0) == 0 { be.fuel = (be.fuel ?? 0) - 1 }
        be.brewTime = (be.brewTime ?? 0) + 1
        if (be.brewTime ?? 0) >= 400 {
            be.brewTime = 0
            for i in 0..<3 {
                guard let bottle = items[i] else { continue }
                let bName = itemDef(bottle.id).name
                let potionId = bottle.data.potion ?? "water"
                if ingName == "gunpowder" && bName == "potion" {
                    var data = StackData()
                    data.potion = potionId
                    items[i] = ItemStack(iid("splash_potion"), 1, data: data)
                } else if ingName == "dragon_breath" && bName == "splash_potion" {
                    var data = StackData()
                    data.potion = potionId
                    items[i] = ItemStack(iid("lingering_potion"), 1, data: data)
                } else {
                    if let result = findBrew(potionId, ingName) {
                        var data = StackData()
                        data.potion = result
                        bottle.data = data
                    }
                }
            }
            ing.count -= 1
            if ing.count <= 0 { items[3] = nil }
            world.hooks.playSound("block.brewing_stand.brew", Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 1, 1)
        }
    }

    beTickHandlers["hopper"] = { world, be in
        if (be.cooldown ?? 0) > 0 { be.cooldown = (be.cooldown ?? 0) - 1; return }
        let c = world.getBlock(be.x, be.y, be.z)
        if (c >> 4) != Int(B.hopper) { return }
        if (c & 8) != 0 { return } // locked by redstone
        let facing = c & 7
        var acted = false

        // push: into the container we face
        let fx = be.x + [0, 0, 0, 0, -1, 1][facing == 0 ? 0 : facing]
        let fy = be.y + (facing == 0 ? -1 : 0)
        let fz = be.z + [0, 0, -1, 1, 0, 0][facing == 0 ? 0 : facing]
        if let target = containerAt(world, fx, fy, fz) {
            var beItems = be.items ?? []
            for i in 0..<beItems.count {
                guard let s = beItems[i] else { continue }
                var filter: ((Int) -> Bool)? = nil
                if target.type == "furnace" {
                    let isFuel = fuelTime(s) > 0
                    filter = facing == 0 ? { idx in idx == 0 } : { idx in idx == 1 && isFuel }
                } else if target.type == "brewing" {
                    let name = itemDef(s.id).name
                    filter = { idx in
                        (idx == 4 && name == "blaze_powder") || (idx == 3 && name != "potion") || (idx < 3 && (name == "potion" || name == "splash_potion" || name == "glass_bottle"))
                    }
                }
                if insertInto(target, s, filter) {
                    if s.count <= 0 { beItems[i] = nil }
                    be.items = beItems
                    acted = true
                    break
                }
            }
        }

        // pull: from container above, or sucked item entities
        if let above = containerAt(world, be.x, be.y + 1, be.z) {
            var aboveItems = above.items ?? []
            for i in 0..<aboveItems.count {
                if above.type == "furnace" && i != 2 { continue } // only output slot
                guard let s = aboveItems[i] else { continue }
                let one = s.copy()
                one.count = 1
                if insertInto(be, one) {
                    s.count -= 1
                    if s.count <= 0 { aboveItems[i] = nil }
                    above.items = aboveItems
                    acted = true
                    break
                }
            }
        } else {
            // vacuum item entities above
            for e in world.getEntitiesNear(Double(be.x) + 0.5, Double(be.y) + 1, Double(be.z) + 0.5, 1) {
                guard let item = e as? ItemEntity, !item.dead else { continue }
                let before = item.stack.count
                while item.stack.count > 0 {
                    let one = item.stack.copy()
                    one.count = 1
                    if !insertInto(be, one) { break }
                    item.stack.count -= 1
                }
                if item.stack.count <= 0 { item.remove() }
                if item.stack.count != before { acted = true; break }
            }
        }
        if acted { be.cooldown = 8 }
    }

    beTickHandlers["campfire"] = { world, be in
        let c = world.getBlock(be.x, be.y, be.z)
        let lit = (c & 4) != 0
        var items = be.items ?? [nil, nil, nil, nil]
        var times = be.times ?? [0, 0, 0, 0]
        // saved BEs can carry short arrays — pad before the indexed writes
        while items.count < 4 { items.append(nil) }
        while times.count < 4 { times.append(0) }
        defer { be.items = items; be.times = times }
        for i in 0..<4 {
            guard let s = items[i] else { continue }
            if !lit { continue }
            times[i] += 1
            if times[i] >= 600 {
                if let result = smeltResultFor(s, "smoker") {
                    spawnItem(world, Double(be.x) + 0.5, Double(be.y) + 1, Double(be.z) + 0.5, ItemStack(iid(result.output), 1))
                }
                items[i] = nil
                times[i] = 0
            }
        }
        if lit && world.time % 40 == 0 {
            world.hooks.addParticles("campfire_smoke", Double(be.x) + 0.5, Double(be.y) + 0.8, Double(be.z) + 0.5, 1, 0.2, 0)
        }
    }

    beTickHandlers["spawner"] = { world, be in
        // require player within 16
        let near = !world.getEntitiesNear(Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 16, filter: { ($0 as? Entity)?.isPlayer ?? false }).isEmpty
        if !near { return }
        if world.difficulty == 0 { return }
        if world.time % 10 == 0 {
            world.hooks.addParticles("flame", Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 1, 0.4, 0)
            world.hooks.addParticles("smoke", Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 1, 0.4, 0)
        }
        be.delay = (be.delay ?? 0) - 1
        if (be.delay ?? 0) > 0 { return }
        be.delay = 200 + gameRng.nextInt(600)
        let mob = be.mob ?? "zombie"
        // count nearby same-type
        let count = world.getEntitiesNear(Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 9, filter: { ($0 as? Entity)?.type == mob }).count
        if count >= 6 { return }
        let n = 1 + gameRng.nextInt(4)
        for _ in 0..<n {
            let px = Double(be.x) + 0.5 + (gameRng.nextFloat() - 0.5) * 7
            let pz = Double(be.z) + 0.5 + (gameRng.nextFloat() - 0.5) * 7
            let py = be.y + gameRng.nextInt(3) - 1
            let at = world.getBlock(ifloor(px), py, ifloor(pz))
            if at != 0 { continue }
            _ = spawnMob(world, mob, px, Double(py), pz, SpawnOpts())
            world.hooks.addParticles("flame", px, Double(py) + 0.5, pz, 8, 0.4, 0)
        }
        world.hooks.playSound("block.spawner.spawn", Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 1, 1)
    }

    beTickHandlers["beacon"] = { world, be in
        if world.time % 80 != 0 { return }
        // pyramid check
        var levels = 0
        let valid: Set<Int> = [Int(B.iron_block), Int(B.gold_block), Int(B.diamond_block), Int(B.emerald_block), Int(B.netherite_block)]
        for layer in 1...4 {
            var complete = true
            for dz in -layer...layer where complete {
                for dx in -layer...layer where complete {
                    if !valid.contains(world.getBlock(be.x + dx, be.y - layer, be.z + dz) >> 4) { complete = false }
                }
            }
            if complete { levels = layer }
            else { break }
        }
        be.levels = levels
        // sky access (glass passes the beam)
        var skyOK = true
        var y = be.y + 1
        while y < world.info.minY + world.info.height {
            let bid = world.getBlock(be.x, y, be.z) >> 4
            if bid == 0 { y += 1; continue }
            if !blockDefs[bid].name.contains("glass") { skyOK = false; break }
            y += 1
        }
        guard levels > 0, skyOK, let primary = be.primary else { return }
        let range = Double(10 + levels * 10)
        for e in world.getEntitiesNear(Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, range, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
            guard let p = e as? LivingEntity else { continue }
            p.addEffect(primary, 260, levels >= 4 && be.secondary == primary ? 1 : 0, ambient: true)
            if levels >= 4 && be.secondary == "regeneration" { p.addEffect("regeneration", 260, 0, ambient: true) }
        }
    }

    beTickHandlers["conduit"] = { world, be in
        if world.time % 80 != 0 { return }
        // count prismarine frame blocks in 5×5×5 shell
        var frame = 0
        let valid: Set<Int> = [Int(B.prismarine), Int(B.prismarine_bricks), Int(B.dark_prismarine), Int(B.sea_lantern)]
        for dy in -2...2 {
            for dz in -2...2 {
                for dx in -2...2 {
                    if abs(dx) != 2 && abs(dy) != 2 && abs(dz) != 2 { continue }
                    if valid.contains(world.getBlock(be.x + dx, be.y + dy, be.z + dz) >> 4) { frame += 1 }
                }
            }
        }
        be.active = frame >= 16
        if be.active == true {
            let range = Double((frame / 7) * 16)
            for e in world.getEntitiesNear(Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, range, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
                guard let p = e as? LivingEntity else { continue }
                if p.inWater || world.rainLevel > 0.5 { p.addEffect("conduit_power", 260, 0, ambient: true) }
            }
            world.hooks.playSound("block.conduit.ambient", Double(be.x) + 0.5, Double(be.y) + 0.5, Double(be.z) + 0.5, 0.5, 1)
        }
    }
}
