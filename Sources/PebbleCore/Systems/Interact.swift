// Interactions — block placement with
// orientation, right-click block uses, item uses (buckets, food, throwables,
// tools-on-blocks), eating, block breaking with drops & XP.

import Foundation

var interactRng = RandomX(0x17AC7)

/// payload passed to the UI layer's openScreen
public struct ScreenData {
    public var be: BlockEntityData?
    public var other: BlockEntityData?
    public var title: String?
    public var block: Int?
    public var x = 0, y = 0, z = 0
    public var damage = 0
    public var text: String?
    public var readOnly = false
    public init() {}
}

public struct InteractCtx {
    public let world: World
    public let player: Player
    public let openScreen: (String, ScreenData?) -> Void
    public let advance: (String) -> Void
    public let persistPlayerState: () -> Void

    public init(world: World, player: Player,
                openScreen: @escaping (String, ScreenData?) -> Void = { _, _ in },
                advance: @escaping (String) -> Void = { _ in },
                persistPlayerState: @escaping () -> Void = {}) {
        self.world = world
        self.player = player
        self.openScreen = openScreen
        self.advance = advance
        self.persistPlayerState = persistPlayerState
    }
}

private func dirFacingMeta(_ player: Player) -> Int {
    // horizontal facing meta (0=N 1=S 2=W 3=E) — direction the PLAYER faces
    let d = yawToDir(player.yaw * 180 / .pi)
    return [0, 0, 0, 1, 2, 3][d]
}
private func dirFacingMetaOpp(_ player: Player) -> Int {
    [1, 0, 3, 2][dirFacingMeta(player)]
}

private func shapeOf(_ id: Int) -> Shape {
    Shape(rawValue: SHAPE_OF[id]) ?? .cube
}

// =============================================================================
// BLOCK USE (right-click on block)
// =============================================================================
public func useBlock(_ ctx: InteractCtx, _ hit: RaycastHit) -> Bool {
    let world = ctx.world, player = ctx.player
    let x = hit.x, y = hit.y, z = hit.z
    let c = world.getBlock(x, y, z)
    let id = c >> 4
    let meta = c & 15
    let def = blockDefs[id]
    let shape = shapeOf(id)
    let name = def.name

    // doors / trapdoors / gates
    if shape == .door && id != Int(B.iron_door) {
        let lowerY = (meta & 8) != 0 ? y - 1 : y
        let lower = world.getBlock(x, lowerY, z)
        world.setBlock(x, lowerY, z, Int(cell(UInt16(id), (lower & 15) ^ 4)))
        world.hooks.playSound((lower & 4) != 0 ? "block.wooden_door.close" : "block.wooden_door.open", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
        world.emitVibration(Double(x), Double(y), Double(z), 11, player)
        return true
    }
    if shape == .trapdoor && id != Int(B.iron_trapdoor) {
        world.setBlock(x, y, z, Int(cell(UInt16(id), meta ^ 4)))
        world.hooks.playSound((meta & 4) != 0 ? "block.wooden_trapdoor.close" : "block.wooden_trapdoor.open", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
        return true
    }
    if shape == .fenceGate {
        var m = meta ^ 4
        if (m & 4) != 0 {
            // open away from player
            let f = dirFacingMeta(player)
            m = (m & 12) | f
            if (meta & 3) == ((f + 2) % 4) { m = (m & 12) | f }
        }
        world.setBlock(x, y, z, Int(cell(UInt16(id), m)))
        world.hooks.playSound((meta & 4) != 0 ? "block.fence_gate.close" : "block.fence_gate.open", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
        return true
    }
    // lever / button
    if id == Int(B.lever) {
        world.setBlock(x, y, z, Int(cell(B.lever, meta ^ 8)))
        world.hooks.playSound("block.lever.click", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.5, (meta & 8) != 0 ? 0.6 : 0.7)
        let attach = meta & 7
        world.updateNeighbors(x + DIR_X[attach], y + DIR_Y[attach], z + DIR_Z[attach])
        world.emitVibration(Double(x), Double(y), Double(z), 10, player)
        return true
    }
    if shape == .button {
        if (meta & 8) == 0 {
            world.setBlock(x, y, z, Int(cell(UInt16(id), meta | 8)))
            world.hooks.playSound("block.stone_button.click_on", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.5, 0.9)
            let attach = meta & 7
            world.updateNeighbors(x + DIR_X[attach], y + DIR_Y[attach], z + DIR_Z[attach])
            world.scheduleTick(x, y, z, id, def.sound == "wood" ? 30 : 20)
        }
        return true
    }
    // repeater / comparator adjust
    if id == Int(B.repeater) || id == Int(B.repeater_on) {
        let delay = ((meta >> 2) & 3) + 1
        let next = delay % 4
        world.setBlock(x, y, z, Int(cell(UInt16(id), (meta & 3) | (next << 2))), 4)
        world.hooks.playSound("block.lever.click", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.3, 1)
        return true
    }
    if id == Int(B.comparator) || id == Int(B.comparator_on) {
        world.setBlock(x, y, z, Int(cell(UInt16(id), meta ^ 4)), 4)
        world.scheduleTick(x, y, z, id, 2)
        world.hooks.playSound("block.comparator.click", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.3, (meta & 4) != 0 ? 0.55 : 0.5)
        return true
    }
    if id == Int(B.note_block) {
        var be = world.getBlockEntity(x, y, z)
        if be == nil || be!.type != "note" {
            be = BlockEntityData(type: "note", x: x, y: y, z: z)
            be!.note = 0
            world.setBlockEntity(be!)
        }
        be!.note = ((be!.note ?? 0) + 1) % 25
        playNoteBlock(world, x, y, z)
        return true
    }
    if id == Int(B.daylight_detector) || id == Int(B.daylight_detector_inverted) {
        let other = id == Int(B.daylight_detector) ? B.daylight_detector_inverted : B.daylight_detector
        world.setBlock(x, y, z, Int(cell(other, 0)))
        world.scheduleTick(x, y, z, Int(other), 2)
        return true
    }
    // containers & screens
    if id == Int(B.crafting_table) {
        var be = world.getBlockEntity(x, y, z)
        if be == nil || be!.type != "crafting" {
            be = makeCraftingTableBE(x, y, z)
            world.setBlockEntity(be!)
        }
        var data = ScreenData()
        data.be = be
        data.x = x
        data.y = y
        data.z = z
        ctx.openScreen("crafting", data)
        return true
    }
    if id == Int(B.chest) || id == Int(B.trapped_chest) {
        // blocked by solid above?
        if blockDefs[world.getBlock(x, y + 1, z) >> 4].opaque { return true }
        var be = world.getBlockEntity(x, y, z)
        if be == nil { be = makeContainerBE(x, y, z, 27); world.setBlockEntity(be!) }
        resolveLoot(world, be!)
        // double chest
        var other: BlockEntityData? = nil
        for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            if (world.getBlock(x + dx, y, z + dz) >> 4) == id {
                var obe = world.getBlockEntity(x + dx, y, z + dz)
                if obe == nil { obe = makeContainerBE(x + dx, y, z + dz, 27); world.setBlockEntity(obe!) }
                resolveLoot(world, obe!)
                other = obe
                break
            }
        }
        var data = ScreenData()
        data.be = be
        data.other = other
        data.title = other != nil ? "Large Chest" : "Chest"
        data.block = id
        ctx.openScreen("chest", data)
        world.hooks.playSound("block.chest.open", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.6, 1)
        return true
    }
    if id == Int(B.barrel) {
        var be = world.getBlockEntity(x, y, z)
        if be == nil { be = makeContainerBE(x, y, z, 27); world.setBlockEntity(be!) }
        resolveLoot(world, be!)
        var data = ScreenData()
        data.be = be
        data.title = "Barrel"
        data.block = id
        ctx.openScreen("chest", data)
        world.hooks.playSound("block.barrel.open", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.6, 1)
        return true
    }
    if id == Int(B.ender_chest) {
        ctx.openScreen("ender_chest", nil)
        world.hooks.playSound("block.ender_chest.open", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.6, 1)
        return true
    }
    if name.hasSuffix("shulker_box") || id == Int(B.shulker_box) {
        var be = world.getBlockEntity(x, y, z)
        if be == nil { be = makeContainerBE(x, y, z, 27); world.setBlockEntity(be!) }
        var data = ScreenData()
        data.be = be
        data.title = "Shulker Box"
        data.block = id
        ctx.openScreen("chest", data)
        world.hooks.playSound("block.shulker_box.open", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.6, 1)
        return true
    }
    if id == Int(B.furnace) || id == Int(B.furnace_lit) || id == Int(B.blast_furnace) || id == Int(B.blast_furnace_lit) || id == Int(B.smoker) || id == Int(B.smoker_lit) {
        var be = world.getBlockEntity(x, y, z)
        if be == nil || be!.type != "furnace" {
            let kind = (id == Int(B.blast_furnace) || id == Int(B.blast_furnace_lit)) ? "blast" : (id == Int(B.smoker) || id == Int(B.smoker_lit)) ? "smoker" : "furnace"
            be = makeFurnaceBE(x, y, z, kind)
            world.setBlockEntity(be!)
        }
        var data = ScreenData()
        data.be = be
        ctx.openScreen("furnace", data)
        return true
    }
    if id == Int(B.brewing_stand) {
        var be = world.getBlockEntity(x, y, z)
        if be == nil || be!.type != "brewing" { be = makeBrewingBE(x, y, z); world.setBlockEntity(be!) }
        var data = ScreenData()
        data.be = be
        ctx.openScreen("brewing", data)
        return true
    }
    if id == Int(B.enchanting_table) {
        var data = ScreenData()
        data.x = x; data.y = y; data.z = z
        ctx.openScreen("enchanting", data)
        return true
    }
    if id == Int(B.anvil) || id == Int(B.chipped_anvil) || id == Int(B.damaged_anvil) {
        var data = ScreenData()
        data.x = x; data.y = y; data.z = z
        data.damage = id == Int(B.anvil) ? 0 : id == Int(B.chipped_anvil) ? 1 : 2
        ctx.openScreen("anvil", data)
        return true
    }
    if id == Int(B.grindstone) { ctx.openScreen("grindstone", nil); return true }
    if id == Int(B.stonecutter) { ctx.openScreen("stonecutter", nil); return true }
    if id == Int(B.smithing_table) { ctx.openScreen("smithing", nil); return true }
    if id == Int(B.loom) || id == Int(B.cartography_table) || id == Int(B.fletching_table) {
        return true // villager job sites; no player UI
    }
    if id == Int(B.beacon) {
        var be = world.getBlockEntity(x, y, z)
        if be == nil || be!.type != "beacon" {
            be = BlockEntityData(type: "beacon", x: x, y: y, z: z)
            be!.levels = 0
            world.setBlockEntity(be!)
        }
        var data = ScreenData()
        data.be = be
        ctx.openScreen("beacon", data)
        return true
    }
    if id == Int(B.hopper) {
        var be = world.getBlockEntity(x, y, z)
        if be == nil || be!.type != "hopper" { be = makeHopperBE(x, y, z); world.setBlockEntity(be!) }
        var data = ScreenData()
        data.be = be
        data.title = "Hopper"
        data.block = id
        ctx.openScreen("chest", data)
        return true
    }
    if id == Int(B.dispenser) || id == Int(B.dropper) {
        var be = world.getBlockEntity(x, y, z)
        if be == nil || be!.type != "container" { be = makeContainerBE(x, y, z, 9); world.setBlockEntity(be!) }
        var data = ScreenData()
        data.be = be
        data.title = id == Int(B.dispenser) ? "Dispenser" : "Dropper"
        data.block = id
        ctx.openScreen("chest", data)
        return true
    }
    // beds
    if shape == .bed {
        return useBed(ctx, x, y, z, c)
    }
    if id == Int(B.respawn_anchor) {
        let charges = meta & 7
        let held = player.mainHand
        if let held, itemDef(held.id).name == "glowstone", charges < 4 {
            player.consumeHeld(1)
            world.setBlock(x, y, z, Int(cell(B.respawn_anchor, charges + 1)))
            world.hooks.playSound("block.respawn_anchor.charge", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            return true
        }
        if charges > 0 {
            if world.dim == .nether {
                player.spawnPoint = (x, y + 1, z)
                player.spawnDim = 1
                ctx.persistPlayerState()
                world.hooks.playSound("block.respawn_anchor.set_spawn", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            } else {
                // BOOM
                world.setBlock(x, y, z, 0)
                explodeFn?(world, Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 5, true, nil)
            }
            return true
        }
        return false
    }
    if id == Int(B.bell) {
        world.hooks.playSound("block.bell.use", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 2, 1)
        world.emitVibration(Double(x), Double(y), Double(z), 15, player)
        return true
    }
    if id == Int(B.cake) {
        if player.hunger < 20 {
            player.feed(2, 0.4)
            let bites = meta & 7
            if bites >= 6 { world.setBlock(x, y, z, 0) }
            else { world.setBlock(x, y, z, Int(cell(B.cake, bites + 1))) }
            world.hooks.playSound("entity.generic.eat", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 0.8, 1)
            return true
        }
        return false
    }
    if id == Int(B.jukebox) {
        let be = world.getBlockEntity(x, y, z)
        if let disc = be?.disc {
            spawnItem(world, Double(x) + 0.5, Double(y) + 1.1, Double(z) + 0.5, disc)
            be?.disc = nil
            world.hooks.playSound("jukebox.stop", Double(x) + 0.5, Double(y), Double(z) + 0.5, 1, 1)
            return true
        }
        if let held = player.mainHand, itemDef(held.id).name.hasPrefix("music_disc") {
            var jbe = be
            if jbe == nil {
                jbe = BlockEntityData(type: "jukebox", x: x, y: y, z: z)
                world.setBlockEntity(jbe!)
            }
            let one = held.copy()
            one.count = 1
            jbe!.disc = one
            jbe!.startedTick = world.time
            player.consumeHeld(1)
            world.hooks.playSound("jukebox.play." + itemDef(held.id).name, Double(x) + 0.5, Double(y), Double(z) + 0.5, 4, 1)
            return true
        }
        return false
    }
    if id == Int(B.chiseled_bookshelf) {
        var be = world.getBlockEntity(x, y, z)
        if be == nil || be!.type != "shelf" {
            be = BlockEntityData(type: "shelf", x: x, y: y, z: z)
            be!.items = Array(repeating: nil, count: 6)
            be!.lastSlot = -1
            world.setBlockEntity(be!)
        }
        let held = player.mainHand
        let heldName = held.map { itemDef($0.id).name }
        if let held, heldName == "book" || heldName == "enchanted_book" || heldName == "writable_book" {
            var items = be!.items ?? Array(repeating: nil, count: 6)
            for i in 0..<6 where items[i] == nil {
                let one = held.copy()
                one.count = 1
                items[i] = one
                be!.items = items
                player.consumeHeld(1)
                be!.lastSlot = i
                world.hooks.playSound("block.chiseled_bookshelf.insert", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
                updateShelfVisual(world, x, y, z, be!)
                return true
            }
        } else {
            var items = be!.items ?? Array(repeating: nil, count: 6)
            var i = 5
            while i >= 0 {
                if let s = items[i] {
                    if player.give(s) {
                        items[i] = nil
                        be!.items = items
                        world.hooks.playSound("block.chiseled_bookshelf.pickup", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
                        updateShelfVisual(world, x, y, z, be!)
                    }
                    return true
                }
                i -= 1
            }
        }
        return false
    }
    if id == Int(B.composter) {
        let held = player.mainHand
        let level = meta
        if level >= 8 {
            // collect bone meal
            world.setBlock(x, y, z, Int(cell(B.composter, 0)))
            spawnItem(world, Double(x) + 0.5, Double(y) + 1, Double(z) + 0.5, ItemStack(iid("bone_meal"), 1))
            world.hooks.playSound("block.composter.empty", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            return true
        }
        if let held {
            let chance = itemDef(held.id).compostChance
            if chance != 0 && level < 7 {
                player.consumeHeld(1)
                if gameRng.nextFloat() < chance {
                    world.setBlock(x, y, z, Int(cell(B.composter, min(8, level + 1 == 7 ? 8 : level + 1))))
                    world.hooks.playSound("block.composter.fill_success", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
                } else {
                    world.hooks.playSound("block.composter.fill", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
                }
                return true
            }
        }
        return false
    }
    if id == Int(B.cauldron) {
        return useCauldron(ctx, x, y, z, c)
    }
    if id == Int(B.campfire) || id == Int(B.soul_campfire) {
        if let held = player.mainHand, itemDef(held.id).food != nil, (meta & 4) != 0 {
            var be = world.getBlockEntity(x, y, z)
            if be == nil || be!.type != "campfire" {
                be = BlockEntityData(type: "campfire", x: x, y: y, z: z)
                be!.items = Array(repeating: nil, count: 4)
                be!.times = [0, 0, 0, 0]
                world.setBlockEntity(be!)
            }
            var items = be!.items ?? Array(repeating: nil, count: 4)
            var times = be!.times ?? [0, 0, 0, 0]
            for i in 0..<4 where items[i] == nil {
                let one = held.copy()
                one.count = 1
                items[i] = one
                times[i] = 0
                be!.items = items
                be!.times = times
                player.consumeHeld(1)
                world.hooks.playSound("block.campfire.crackle", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
                return true
            }
        }
        return false
    }
    if id == Int(B.beehive) || id == Int(B.bee_nest) {
        let be = world.getBlockEntity(x, y, z)
        let honey = be?.honey ?? 0
        let heldName = player.mainHand.map { itemDef($0.id).name }
        if honey >= 5 {
            if heldName == "shears" {
                for _ in 0..<3 { spawnItem(world, Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, ItemStack(iid("honeycomb"), 1)) }
                be?.honey = 0
                player.damageHeld(1)
                world.hooks.playSound("block.beehive.shear", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
                return true
            }
            if heldName == "glass_bottle" {
                player.replaceHeld(ItemStack(iid("honey_bottle"), 1))
                be?.honey = 0
                world.hooks.playSound("item.bottle.fill", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
                return true
            }
        }
        return false
    }
    if id == Int(B.flower_pot) {
        let be = world.getBlockEntity(x, y, z)
        let held = player.mainHand
        if let plant = be?.plant {
            if let itemId = iidOpt(plant), player.give(ItemStack(itemId, 1)) {
                be?.plant = nil
            }
            return true
        }
        if let held {
            let heldName = itemDef(held.id).name
            let pottableWords = ["sapling", "fern", "dandelion", "poppy", "orchid", "allium", "bluet", "tulip", "daisy", "cornflower", "lily_of", "wither_rose", "mushroom", "cactus", "bamboo", "azalea", "fungus", "roots", "dead_bush", "torchflower"]
            if pottableWords.contains(where: { heldName.contains($0) }) {
                var pbe = be
                if pbe == nil {
                    pbe = BlockEntityData(type: "lectern", x: x, y: y, z: z)
                    world.setBlockEntity(pbe!)
                }
                pbe!.plant = heldName
                player.consumeHeld(1)
                world.hooks.playSound("block.flower_pot.place_plant", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
                return true
            }
        }
        return false
    }
    if shape == .sign || shape == .wallSign || shape == .hangingSign {
        var data = ScreenData()
        data.x = x; data.y = y; data.z = z
        data.be = world.getBlockEntity(x, y, z)
        ctx.openScreen("sign", data)
        return true
    }
    if id == Int(B.suspicious_sand) || id == Int(B.suspicious_gravel) {
        return false // brushing handled by brush item hold
    }
    if id == Int(B.end_portal_frame) {
        if let held = player.mainHand, itemDef(held.id).name == "ender_eye", (meta & 4) == 0 {
            world.setBlock(x, y, z, Int(cell(B.end_portal_frame, meta | 4)))
            player.consumeHeld(1)
            world.hooks.playSound("block.end_portal_frame.fill", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            checkEndPortalComplete(world, x, y, z)
            ctx.advance("eye_for_an_eye")
            return true
        }
        return false
    }
    if id == Int(B.tnt) {
        if let held = player.mainHand {
            let hn = itemDef(held.id).name
            if hn == "flint_and_steel" || hn == "fire_charge" {
                igniteTNT(world, x, y, z)
                if hn == "flint_and_steel" { player.damageHeld(1) }
                else { player.consumeHeld(1) }
                return true
            }
        }
        return false
    }
    if id == Int(B.lectern) || id == Int(B.decorated_pot) {
        return false
    }
    if id == Int(B.lodestone) {
        if let held = player.mainHand, itemDef(held.id).name == "compass" {
            var data = StackData()
            data.lodestone = [x, y, z, world.dim.rawValue]
            held.data = data
            world.hooks.playSound("item.lodestone_compass.lock", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            return true
        }
        return false
    }
    return false
}

private func updateShelfVisual(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ be: BlockEntityData) {
    let c = world.getBlock(x, y, z)
    let any = (be.items ?? []).contains { $0 != nil }
    let newMeta = (c & 3) | (any ? 4 : 0)
    if (c & 15) != newMeta {
        world.setBlock(x, y, z, Int(cell(B.chiseled_bookshelf, newMeta)), 4)
        world.setBlockEntity(be)
    }
}

func resolveLoot(_ world: World, _ be: BlockEntityData) {
    if let lootTable = be.lootTable {
        var lootRng = RandomX(UInt32(truncatingIfNeeded: be.lootSeed ?? 1))
        let loot = rollLoot(lootTable, &lootRng)
        var items = be.items ?? []
        var slots = Array(0..<items.count)
        var r = RandomX(UInt32(truncatingIfNeeded: (be.lootSeed ?? 1) ^ 0x55))
        r.shuffle(&slots)
        for i in 0..<min(loot.count, slots.count) {
            items[slots[i]] = loot[i]
        }
        be.items = items
        be.lootTable = nil
    }
}

private func useBed(_ ctx: InteractCtx, _ x: Int, _ y: Int, _ z: Int, _ c: Int) -> Bool {
    let world = ctx.world, player = ctx.player
    if world.dim != .overworld {
        // bed explodes!
        world.setBlock(x, y, z, 0)
        explodeFn?(world, Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 5, true, nil)
        return true
    }
    // set spawn
    player.spawnPoint = (x, y, z)
    player.spawnDim = 0
    ctx.persistPlayerState()
    // sleep if night
    if world.isDay() && world.rainLevel < 0.9 {
        var data = ScreenData()
        data.text = "You can only sleep at night"
        ctx.openScreen("toast", data)
        return true
    }
    // monsters nearby?
    let monsters = world.getEntitiesNear(Double(x), Double(y), Double(z), 8) { e in
        (e as? Mob)?.category == "monster" && !e.dead
    }
    if !monsters.isEmpty {
        var data = ScreenData()
        data.text = "You may not rest now; there are monsters nearby"
        ctx.openScreen("toast", data)
        return true
    }
    player.sleepTicks = 1
    player.bedPos = (x, y, z)
    player.setPos(Double(x) + 0.5, Double(y) + 0.6, Double(z) + 0.5)
    return true
}

private func useCauldron(_ ctx: InteractCtx, _ x: Int, _ y: Int, _ z: Int, _ c: Int) -> Bool {
    let world = ctx.world, player = ctx.player
    guard let held = player.mainHand else { return false }
    let name = itemDef(held.id).name
    let level = c & 3
    let kind = (c >> 2) & 3
    if name == "water_bucket" {
        world.setBlock(x, y, z, Int(cell(B.cauldron, 3 | (0 << 2))))
        player.replaceHeld(ItemStack(iid("bucket"), 1))
        world.hooks.playSound("item.bucket.empty", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
        return true
    }
    if name == "lava_bucket" {
        world.setBlock(x, y, z, Int(cell(B.cauldron, 3 | (1 << 2))))
        player.replaceHeld(ItemStack(iid("bucket"), 1))
        return true
    }
    if name == "powder_snow_bucket" {
        world.setBlock(x, y, z, Int(cell(B.cauldron, 3 | (2 << 2))))
        player.replaceHeld(ItemStack(iid("bucket"), 1))
        return true
    }
    if name == "bucket" && level == 3 {
        let out = kind == 0 ? "water_bucket" : kind == 1 ? "lava_bucket" : "powder_snow_bucket"
        world.setBlock(x, y, z, Int(cell(B.cauldron, 0)))
        player.replaceHeld(ItemStack(iid(out), 1))
        world.hooks.playSound("item.bucket.fill", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
        return true
    }
    if name == "glass_bottle" && kind == 0 && level > 0 {
        world.setBlock(x, y, z, Int(cell(B.cauldron, (level - 1) | (0 << 2))))
        var data = StackData()
        data.potion = "water"
        player.replaceHeld(ItemStack(iid("potion"), 1, data: data))
        world.hooks.playSound("item.bottle.fill", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
        return true
    }
    if name == "potion" && held.data.potion == "water" && level < 3 && kind == 0 {
        world.setBlock(x, y, z, Int(cell(B.cauldron, level + 1)))
        player.replaceHeld(ItemStack(iid("glass_bottle"), 1))
        return true
    }
    // wash dyed items
    if kind == 0 && level > 0 {
        if name.hasSuffix("_shulker_box") {
            player.replaceHeld(ItemStack(iid("shulker_box"), 1))
            world.setBlock(x, y, z, Int(cell(B.cauldron, level - 1)))
            return true
        }
    }
    return false
}

private func checkEndPortalComplete(_ world: World, _ x: Int, _ y: Int, _ z: Int) {
    // scan candidate centers near the frame
    for cz in (z - 4)...(z + 4) {
        for cx in (x - 4)...(x + 4) {
            // a complete portal: frames at ring positions around 3×3 air
            var complete = true
            outer: for i in -1...1 {
                for (fx, fz) in [(i, -2), (i, 2), (-2, i), (2, i)] {
                    let fc = world.getBlock(cx + fx, y, cz + fz)
                    if (fc >> 4) != Int(B.end_portal_frame) || (fc & 4) == 0 { complete = false; break outer }
                }
            }
            if complete {
                for dz in -1...1 {
                    for dx in -1...1 {
                        world.setBlock(cx + dx, y, cz + dz, Int(cell(B.end_portal)))
                    }
                }
                world.hooks.playSound("block.end_portal.spawn", Double(cx) + 0.5, Double(y), Double(cz) + 0.5, 3, 1)
                return
            }
        }
    }
}

// =============================================================================
// ITEM USE
// =============================================================================
func heldUseDurationTicks(_ def: ItemDef) -> Int {
    def.food?.fast == true ? 17 : 32
}

private func canUseFood(_ player: Player, _ food: FoodDef, allowCreativeFullUse: Bool) -> Bool {
    player.health < player.maxHealth || player.hunger < 20 || food.alwaysEat ||
        (allowCreativeFullUse && player.gameMode == GameMode.creative)
}

public func useItem(_ ctx: InteractCtx, _ hit: RaycastHit?) -> Bool {
    let world = ctx.world, player = ctx.player
    guard let held = player.mainHand else { return false }
    let def = itemDef(held.id)
    let name = def.name

    // stick-steering boost while riding (vanilla: 140–980 ticks)
    if name == "carrot_on_a_stick", let pig = player.vehicle as? Pig {
        pig.boostTime = 140 + Int(world.rng.nextFloat() * 840)
        return true
    }
    if name == "warped_fungus_on_a_stick", let strider = player.vehicle as? Strider {
        strider.boostTime = 140 + Int(world.rng.nextFloat() * 840)
        return true
    }

    // food → start eating
    if let food = def.food {
        if canUseFood(player, food, allowCreativeFullUse: true) {
            player.beginUsingMainHand()
            return true
        }
        return false
    }
    if name == "potion" {
        player.beginUsingMainHand()
        return true
    }
    if name == "bow" || name == "trident" || name == "crossbow" || name == "shield" || name == "spyglass" || name == "goat_horn" {
        player.beginUsingMainHand()
        if name == "goat_horn" {
            world.hooks.playSound("item.goat_horn.sound", player.x, player.y, player.z, 8, 1)
            world.emitVibration(Double(ifloor(player.x)), Double(ifloor(player.y)), Double(ifloor(player.z)), 15, player)
        }
        return true
    }
    // throwables
    if name == "snowball" || name == "egg" || name == "ender_pearl" || name == "experience_bottle" || name == "splash_potion" || name == "lingering_potion" {
        let proj: Projectile
        if name == "snowball" { proj = ThrownSnowball(world: world) }
        else if name == "egg" { proj = ThrownEgg(world: world) }
        else if name == "ender_pearl" { proj = ThrownPearl(world: world) }
        else if name == "experience_bottle" { proj = ThrownXPBottle(world: world) }
        else {
            let p = ThrownPotion(world: world)
            p.potionId = held.data.potion ?? "water"
            p.lingering = name == "lingering_potion"
            proj = p
        }
        proj.shootFrom(player, player.pitch, player.yaw, 1.5, 1)
        proj.gravity = name == "splash_potion" || name == "lingering_potion" ? 0.05 : 0.03
        world.addEntity(proj)
        world.hooks.playSound("entity.snowball.throw", player.x, player.y, player.z, 0.5, 0.5)
        player.consumeHeld(1)
        return true
    }
    if name == "fishing_rod" {
        if let bobberId = player.fishingBobberId {
            if let bobber = world.entityById[bobberId] as? FishingBobber, !bobber.dead {
                bobber.retrieve()
                player.damageHeld(1)
                player.fishingBobberId = nil
                return true
            }
            player.fishingBobberId = nil
        }
        let bobber = FishingBobber(world: world)
        bobber.ownerPlayer = player
        bobber.setPos(player.x, player.eyeY() - 0.1, player.z)
        let lookX = -detSin(player.yaw) * detCos(player.pitch)
        let lookY = -detSin(player.pitch)
        let lookZ = detCos(player.yaw) * detCos(player.pitch)
        bobber.vx = lookX * 0.8
        bobber.vy = lookY * 0.8 + 0.1
        bobber.vz = lookZ * 0.8
        world.addEntity(bobber)
        player.fishingBobberId = bobber.id
        world.hooks.playSound("entity.fishing_bobber.throw", player.x, player.y, player.z, 0.5, 0.6)
        return true
    }
    if name == "firework_rocket" {
        let fw = FireworkEntity(world: world)
        if player.elytraFlying {
            fw.attachedTo = player
            fw.setPos(player.x, player.y, player.z)
        } else if let hit {
            fw.setPos(hit.px, hit.py, hit.pz)
            fw.vy = 0.4
        } else { return false }
        fw.flightDuration = held.data.flight ?? 1
        world.addEntity(fw)
        world.hooks.playSound("entity.firework_rocket.launch", player.x, player.y, player.z, 1, 1)
        player.consumeHeld(1)
        return true
    }
    if name == "ender_eye" {
        // locate stronghold
        let positions = strongholdPositions(world.seed)
        var best: (Double, Double)? = nil
        var bestD = Double.infinity
        for (scx, scz) in positions {
            let dx = Double(scx * 16) - player.x, dz = Double(scz * 16) - player.z
            let d = dx * dx + dz * dz
            if d < bestD { bestD = d; best = (Double(scx * 16 + 8), Double(scz * 16 + 8)) }
        }
        if let best {
            let eye = EyeOfEnderEntity(world: world)
            eye.setPos(player.x, player.eyeY(), player.z)
            eye.targetX = best.0
            eye.targetZ = best.1
            world.addEntity(eye)
            world.hooks.playSound("entity.ender_eye.launch", player.x, player.y, player.z, 1, 1)
            player.consumeHeld(1)
            ctx.advance("follow_ender_eye")
            return true
        }
        return false
    }
    // armor equip
    if let armor = def.armor {
        let slot = armor.slot
        let cur = player.armor[slot]
        let one = held.copy()
        one.count = 1
        player.armor[slot] = one
        player.consumeHeld(1)
        if let cur { player.give(cur) }
        world.hooks.playSound("item.armor.equip_generic", player.x, player.y, player.z, 1, 1)
        return true
    }

    // ---- block-targeted item uses ----
    guard let hit else { return false }
    let x = hit.x, y = hit.y, z = hit.z, face = hit.face
    let tx = x + DIR_X[face], ty = y + DIR_Y[face], tz = z + DIR_Z[face]
    let targetCell = world.getBlock(x, y, z)
    let targetId = targetCell >> 4

    if name == "water_bucket" || name == "lava_bucket" || name == "powder_snow_bucket" ||
        name == "cod_bucket" || name == "salmon_bucket" || name == "pufferfish_bucket" ||
        name == "tropical_fish_bucket" || name == "axolotl_bucket" || name == "tadpole_bucket" {
        let isReplaceable = REPLACEABLE[targetId] == 1
        let px = isReplaceable ? x : tx
        let py = isReplaceable ? y : ty
        let pz = isReplaceable ? z : tz
        let cur = world.getBlock(px, py, pz)
        if cur != 0 && REPLACEABLE[cur >> 4] == 0 && blockDefs[cur >> 4].solid { return false }
        if name == "lava_bucket" { world.setBlock(px, py, pz, Int(cell(B.lava, 0))) }
        else if name == "powder_snow_bucket" { world.setBlock(px, py, pz, Int(cell(B.powder_snow))) }
        else { world.setBlock(px, py, pz, Int(cell(B.water, 0))) }
        if name != "water_bucket" && name != "lava_bucket" && name != "powder_snow_bucket" {
            let mob = name.replacingOccurrences(of: "_bucket", with: "")
            _ = spawnMob(world, mob, Double(px) + 0.5, Double(py) + 0.3, Double(pz) + 0.5, SpawnOpts())
        }
        player.replaceHeld(ItemStack(iid("bucket"), 1))
        world.hooks.playSound(name == "lava_bucket" ? "item.bucket.empty_lava" : "item.bucket.empty", Double(px) + 0.5, Double(py) + 0.5, Double(pz) + 0.5, 1, 1)
        return true
    }
    if name == "bucket" {
        // pick up fluid (raycast through fluids)
        let fhit = world.raycast(player.x, player.eyeY(), player.z,
                                 -detSin(player.yaw) * detCos(player.pitch), -detSin(player.pitch), detCos(player.yaw) * detCos(player.pitch), 5, fluid: true)
        if let fhit {
            let fc = world.getBlock(fhit.x, fhit.y, fhit.z)
            let fid = fc >> 4
            if (fid == Int(B.water) || fid == Int(B.lava)) && (fc & 15) == 0 {
                world.setBlock(fhit.x, fhit.y, fhit.z, 0)
                player.replaceHeld(ItemStack(iid(fid == Int(B.water) ? "water_bucket" : "lava_bucket"), 1))
                world.hooks.playSound(fid == Int(B.water) ? "item.bucket.fill" : "item.bucket.fill_lava", Double(fhit.x), Double(fhit.y), Double(fhit.z), 1, 1)
                return true
            }
            if fid == Int(B.powder_snow) {
                world.setBlock(fhit.x, fhit.y, fhit.z, 0)
                player.replaceHeld(ItemStack(iid("powder_snow_bucket"), 1))
                return true
            }
        }
        return false
    }
    if name == "flint_and_steel" || name == "fire_charge" {
        // portal ignition first
        if tryIgnitePortal(world, tx, ty, tz) || tryIgnitePortal(world, x, y + 1, z) {
            if name == "flint_and_steel" { player.damageHeld(1) } else { player.consumeHeld(1) }
            world.hooks.playSound("item.flintandsteel.use", Double(tx) + 0.5, Double(ty) + 0.5, Double(tz) + 0.5, 1, 1)
            ctx.advance("ignite_portal")
            return true
        }
        if targetId == Int(B.campfire) || targetId == Int(B.soul_campfire) {
            if (targetCell & 4) == 0 {
                world.setBlock(x, y, z, Int(cell(UInt16(targetId), (targetCell & 15) | 4)))
                if name == "flint_and_steel" { player.damageHeld(1) } else { player.consumeHeld(1) }
                return true
            }
        }
        if world.getBlock(tx, ty, tz) == 0 {
            world.setBlock(tx, ty, tz, Int(cell(B.fire)))
            if name == "flint_and_steel" { player.damageHeld(1) } else { player.consumeHeld(1) }
            world.hooks.playSound("item.flintandsteel.use", Double(tx) + 0.5, Double(ty) + 0.5, Double(tz) + 0.5, 1, 1)
            return true
        }
        return false
    }
    if name == "bone_meal" {
        if applyBonemeal(world, x, y, z) {
            player.consumeHeld(1)
            return true
        }
        return false
    }
    if def.tool?.type == "hoe" {
        if (targetId == Int(B.grass_block) || targetId == Int(B.dirt) || targetId == Int(B.dirt_path)) && world.getBlock(x, y + 1, z) == 0 {
            world.setBlock(x, y, z, Int(cell(B.farmland, 0)))
            world.hooks.playSound("item.hoe.till", Double(x) + 0.5, Double(y) + 1, Double(z) + 0.5, 1, 1)
            player.damageHeld(1)
            return true
        }
        if targetId == Int(B.rooted_dirt) {
            world.setBlock(x, y, z, Int(cell(B.dirt)))
            spawnItem(world, Double(x) + 0.5, Double(y) + 1, Double(z) + 0.5, ItemStack(iid("hanging_roots"), 1))
            player.damageHeld(1)
            return true
        }
        return false
    }
    if def.tool?.type == "shovel" {
        if targetId == Int(B.grass_block) && world.getBlock(x, y + 1, z) == 0 {
            world.setBlock(x, y, z, Int(cell(B.dirt_path)))
            world.hooks.playSound("item.shovel.flatten", Double(x) + 0.5, Double(y) + 1, Double(z) + 0.5, 1, 1)
            player.damageHeld(1)
            return true
        }
        if (targetId == Int(B.campfire) || targetId == Int(B.soul_campfire)) && (targetCell & 4) != 0 {
            world.setBlock(x, y, z, Int(cell(UInt16(targetId), targetCell & 11)))
            world.hooks.playSound("block.fire.extinguish", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            player.damageHeld(1)
            return true
        }
        return false
    }
    if def.tool?.type == "axe" {
        let stripped = strippedVersion(targetId)
        if stripped >= 0 {
            world.setBlock(x, y, z, Int(cell(UInt16(stripped), targetCell & 15)))
            world.hooks.playSound("item.axe.strip", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            player.damageHeld(1)
            return true
        }
        let scraped = scrapedCopper(targetId)
        if scraped >= 0 {
            world.setBlock(x, y, z, Int(cell(UInt16(scraped), targetCell & 15)))
            world.hooks.playSound("item.axe.scrape", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            player.damageHeld(1)
            return true
        }
        return false
    }
    if name == "shears" {
        if targetId == Int(B.pumpkin) {
            world.setBlock(x, y, z, Int(cell(B.carved_pumpkin, dirFacingMetaOpp(player))))
            spawnItem(world, Double(x) + 0.5, Double(y) + 1, Double(z) + 0.5, ItemStack(iid("pumpkin_seeds"), 4))
            player.damageHeld(1)
            world.hooks.playSound("block.pumpkin.carve", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
            return true
        }
        return false
    }
    if name == "honeycomb" {
        let waxed = waxedCopper(targetId)
        if waxed >= 0 {
            world.setBlock(x, y, z, Int(cell(UInt16(waxed), targetCell & 15)))
            world.hooks.addParticles("wax", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 8, 0.5, 0)
            player.consumeHeld(1)
            return true
        }
        return false
    }
    if name.hasSuffix("_boat") || name.hasSuffix("_raft") || name.contains("chest_boat") || name.contains("chest_raft") {
        let boat = Boat(world: world)
        boat.wood = name.split(separator: "_")[0] == "bamboo" ? "bamboo"
            : name.replacingOccurrences(of: "_chest_boat", with: "")
                .replacingOccurrences(of: "_boat", with: "")
                .replacingOccurrences(of: "_chest_raft", with: "")
                .replacingOccurrences(of: "_raft", with: "")
        boat.hasChest = name.contains("chest")
        boat.setPos(hit.px, hit.py + 0.2, hit.pz)
        boat.yaw = player.yaw
        world.addEntity(boat)
        player.consumeHeld(1)
        return true
    }
    if name == "minecart" || name.hasSuffix("_minecart") {
        if shapeOf(targetId) == .rail {
            let cart = Minecart(world: world)
            cart.variant = name == "minecart" ? "empty" : name.replacingOccurrences(of: "_minecart", with: "")
            cart.setPos(Double(x) + 0.5, Double(y) + 0.3, Double(z) + 0.5)
            world.addEntity(cart)
            player.consumeHeld(1)
            return true
        }
        return false
    }
    if name.hasSuffix("_spawn_egg") {
        let mob = String(name.dropLast(10))
        _ = spawnMob(world, mob, Double(tx) + 0.5, Double(ty), Double(tz) + 0.5, SpawnOpts())
        if player.gameMode != GameMode.creative { player.consumeHeld(1) }
        return true
    }
    if name == "brush" { return false } // handled as hold-to-brush in Game
    if name == "lead" || name == "name_tag" { return false } // entity interactions

    // ---- block placement ----
    if let block = def.block {
        return placeBlock(ctx, hit, Int(block), held)
    }
    return false
}

private func strippedVersion(_ id: Int) -> Int {
    let name = blockDefs[id].name
    let logWoods = ["oak", "spruce", "birch", "jungle", "acacia", "dark_oak", "mangrove", "cherry"]
    let isLog = logWoods.contains { name == "\($0)_log" || name == "\($0)_wood" }
    let isStem = name == "crimson_stem" || name == "crimson_hyphae" || name == "warped_stem" || name == "warped_hyphae"
    if isLog || isStem || name == "bamboo_block" {
        let strippedName = "stripped_" + name
        return bidOpt(strippedName).map(Int.init) ?? -1
    }
    return -1
}
private func scrapedCopper(_ id: Int) -> Int {
    let name = blockDefs[id].name
    if name.hasPrefix("waxed_") {
        let unwaxed = String(name.dropFirst(6))
        return bidOpt(unwaxed).map(Int.init) ?? -1
    }
    for (from, to) in [("exposed_", ""), ("weathered_", "exposed_"), ("oxidized_", "weathered_")] {
        if name.hasPrefix(from) && name.contains("copper") {
            let next = to + name.dropFirst(from.count)
            return bidOpt(next).map(Int.init) ?? -1
        }
    }
    return -1
}
private func waxedCopper(_ id: Int) -> Int {
    let name = blockDefs[id].name
    if name.contains("copper") && !name.hasPrefix("waxed_") && !name.contains("ore") && !name.contains("raw") {
        let waxed = "waxed_" + name
        return bidOpt(waxed).map(Int.init) ?? -1
    }
    return -1
}

// =============================================================================
// PLACEMENT
// =============================================================================
public func placeBlock(_ ctx: InteractCtx, _ hit: RaycastHit, _ blockId: Int, _ held: ItemStack) -> Bool {
    let world = ctx.world, player = ctx.player
    let targetCell = world.getBlock(hit.x, hit.y, hit.z)
    var px = hit.x, py = hit.y, pz = hit.z
    if REPLACEABLE[targetCell >> 4] == 0 {
        px += DIR_X[hit.face]
        py += DIR_Y[hit.face]
        pz += DIR_Z[hit.face]
    }
    let cur = world.getBlock(px, py, pz)
    if cur != 0 && REPLACEABLE[cur >> 4] == 0 {
        // slab merging
        if shapeOf(blockId) == .slab && (cur >> 4) == blockId && (cur & 3) != 2 {
            world.setBlock(px, py, pz, Int(cell(UInt16(blockId), 2)))
            placeEffects(world, blockId, px, py, pz)
            player.consumeHeld(1)
            return true
        }
        return false
    }
    // entity collision check
    let def = blockDefs[blockId]
    if def.solid {
        let box = AABB(Double(px) + 0.05, Double(py) + 0.05, Double(pz) + 0.05, Double(px) + 0.95, Double(py) + 0.95, Double(pz) + 0.95)
        let blocked = world.getEntitiesInBox(box, except: nil, filter: { $0 is LivingEntity })
        if !blocked.isEmpty { return false }
    }
    let meta = placementMeta(world, player, hit, blockId, px, py, pz)
    if meta == -1 { return false }
    // snow layer stacking
    if blockId == Int(B.snow) && (cur >> 4) == Int(B.snow) {
        let layers = cur & 7
        if layers < 7 {
            world.setBlock(px, py, pz, Int(cell(B.snow, layers + 1)))
            placeEffects(world, blockId, px, py, pz)
            player.consumeHeld(1)
            return true
        }
        return false
    }
    // candles & pickles & petals stack
    if (cur >> 4) == blockId && (shapeOf(blockId) == .candle || shapeOf(blockId) == .seaPickle || blockId == Int(bid("pink_petals")) || shapeOf(blockId) == .turtleEgg) {
        let count = cur & 3
        if count < 3 {
            world.setBlock(px, py, pz, Int(cell(UInt16(blockId), (cur & 12) | (count + 1))))
            placeEffects(world, blockId, px, py, pz)
            player.consumeHeld(1)
            return true
        }
        return false
    }

    world.setBlock(px, py, pz, Int(cell(UInt16(blockId), meta)))
    // multi-block: doors & beds & tall plants
    let shape = shapeOf(blockId)
    if shape == .door {
        let above = world.getBlock(px, py + 1, pz)
        if above != 0 && REPLACEABLE[above >> 4] == 0 {
            world.setBlock(px, py, pz, 0)
            return false
        }
        // hinge: pick side with more support
        let hinge = interactRng.nextBoolean() ? 1 : 0
        world.setBlock(px, py + 1, pz, Int(cell(UInt16(blockId), 8 | hinge)))
    } else if shape == .bed {
        let f = meta & 3
        let hx = px + [0, 0, -1, 1][f], hz = pz + [-1, 1, 0, 0][f]
        let headCur = world.getBlock(hx, py, hz)
        if headCur != 0 && REPLACEABLE[headCur >> 4] == 0 {
            world.setBlock(px, py, pz, 0)
            return false
        }
        world.setBlock(hx, py, hz, Int(cell(UInt16(blockId), f | 4)))
    } else if shape == .tallCross || blockId == Int(B.pitcher_plant) {
        if world.getBlock(px, py + 1, pz) == 0 {
            world.setBlock(px, py + 1, pz, Int(cell(UInt16(blockId), meta | 1)))
        }
    }
    // block entities on placement
    attachPlacementBE(world, blockId, px, py, pz, held)
    if let handler = onPlacedHandlers[blockId] {
        handler(world, px, py, pz, Int(cell(UInt16(blockId), meta)))
    }
    placeEffects(world, blockId, px, py, pz)
    player.consumeHeld(1)
    player.stats["blocksPlaced"] = (player.stats["blocksPlaced"] ?? 0) + 1
    world.emitVibration(Double(px), Double(py), Double(pz), 13, player)
    return true
}

private func placeEffects(_ world: World, _ blockId: Int, _ x: Int, _ y: Int, _ z: Int) {
    world.hooks.playSound("block." + blockDefs[blockId].sound + ".place", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 0.8)
}

private func attachPlacementBE(_ world: World, _ blockId: Int, _ x: Int, _ y: Int, _ z: Int, _ held: ItemStack) {
    if blockId == Int(B.chest) || blockId == Int(B.trapped_chest) || blockId == Int(B.barrel) {
        world.setBlockEntity(makeContainerBE(x, y, z, 27))
    } else if blockId == Int(B.furnace) || blockId == Int(B.blast_furnace) || blockId == Int(B.smoker) {
        world.setBlockEntity(makeFurnaceBE(x, y, z, blockId == Int(B.blast_furnace) ? "blast" : blockId == Int(B.smoker) ? "smoker" : "furnace"))
    } else if blockId == Int(B.brewing_stand) {
        world.setBlockEntity(makeBrewingBE(x, y, z))
    } else if blockId == Int(B.hopper) {
        world.setBlockEntity(makeHopperBE(x, y, z))
    } else if blockId == Int(B.dispenser) || blockId == Int(B.dropper) {
        world.setBlockEntity(makeContainerBE(x, y, z, 9))
    } else if blockDefs[blockId].name.hasSuffix("shulker_box") || blockId == Int(B.shulker_box) {
        let be = makeContainerBE(x, y, z, 27)
        if let contents = held.data.contents { be.items = contents }
        world.setBlockEntity(be)
    } else if shapeOf(blockId) == .sign || shapeOf(blockId) == .wallSign || shapeOf(blockId) == .hangingSign {
        world.setBlockEntity(makeSignBE(x, y, z))
    } else if blockId == Int(B.beacon) {
        let be = BlockEntityData(type: "beacon", x: x, y: y, z: z)
        be.levels = 0
        world.setBlockEntity(be)
    } else if blockId == Int(B.conduit) {
        let be = BlockEntityData(type: "conduit", x: x, y: y, z: z)
        be.active = false
        world.setBlockEntity(be)
    } else if blockId == Int(B.decorated_pot) {
        let be = BlockEntityData(type: "pot", x: x, y: y, z: z)
        be.sherds = held.data.sherds.map { $0.map { Optional($0) } } ?? [nil, nil, nil, nil]
        world.setBlockEntity(be)
    }
}

/// compute placement meta for orientation-aware shapes; -1 = can't place
private func placementMeta(_ world: World, _ player: Player, _ hit: RaycastHit, _ blockId: Int, _ px: Int, _ py: Int, _ pz: Int) -> Int {
    let shape = shapeOf(blockId)
    let name = blockDefs[blockId].name
    let facing = dirFacingMeta(player)       // direction player faces
    let facingOpp = dirFacingMetaOpp(player) // toward player
    let hitFY = hit.py - Double(hit.y)

    switch shape {
    case .stairs:
        let top = (hit.face == 0 || (hit.face != 1 && hitFY > 0.5)) ? 4 : 0
        return facing | top
    case .slab:
        let top = (hit.face == 0 || (hit.face != 1 && hitFY > 0.5)) ? 1 : 0
        return top
    case .door, .fenceGate, .bed:
        return facing
    case .trapdoor:
        let top = (hit.face == 0 || (hit.face != 1 && hitFY > 0.5)) ? 8 : 0
        return facingOpp | top
    case .torch:
        if blockId == Int(B.lightning_rod) || blockId == Int(B.end_rod) { return hit.face }
        if hit.face >= 2 {
            // wall torch: meta = dir TOWARD support block = opposite of face
            let support = world.getBlock(px - DIR_X[hit.face], py, pz - DIR_Z[hit.face]) >> 4
            if blockDefs[support].fullCube { return hit.face ^ 1 }
        }
        let below = world.getBlock(px, py - 1, pz)
        if !blockDefs[below >> 4].fullCube && !sturdyTopOk(below) { return -1 }
        return 0
    case .lever, .button:
        return hit.face ^ 1 // attach toward support
    case .ladder, .wallSign:
        if hit.face < 2 { return -1 }
        return [0, 1, 2, 3][hit.face - 2]
    case .sign:
        let deg = (player.yaw * 180 / .pi + 180).truncatingRemainder(dividingBy: 360)
        return Int((deg / 22.5).rounded(.down)) & 15
    case .chest:
        return facingOpp
    case .repeater, .comparator:
        return facing
    case .rail:
        // orient along player facing; curves/connections simplified to straight
        return (facing == 2 || facing == 3) ? 1 : 0
    case .crop:
        let below = world.getBlock(px, py - 1, pz) >> 4
        if blockId == Int(B.nether_wart) { return below == Int(B.soul_sand) ? 0 : -1 }
        return below == Int(B.farmland) ? 0 : -1
    case .cross, .tallCross:
        let below = world.getBlock(px, py - 1, pz) >> 4
        let belowName = blockDefs[below].name
        let plantWords = ["sapling", "grass", "fern", "flower", "bush", "tulip", "daisy", "orchid", "allium", "bluet", "dandelion", "poppy", "cornflower", "lily", "rose", "peony", "lilac", "sunflower", "torchflower", "pitcher"]
        if plantWords.contains(where: { name.contains($0) }) {
            let soilWords = ["grass_block", "dirt", "podzol", "farmland", "coarse", "rooted", "moss", "mud"]
            return soilWords.contains(where: { belowName.contains($0) }) ? 0 : -1
        }
        let netherWords = ["fungus", "roots", "sprouts"]
        if netherWords.contains(where: { name.contains($0) }) {
            let netherSoil = ["nylium", "netherrack", "soul", "grass_block", "dirt", "moss"]
            return netherSoil.contains(where: { belowName.contains($0) }) ? 0 : -1
        }
        if name == "sugar_cane" {
            // vanilla: on another cane, or on dirt/sand family with water (or
            // frosted ice) horizontally adjacent to the SUPPORT block.
            // (the "special check below" this pointed at never existed — cane
            // was unplaceable everywhere)
            if below == Int(B.sugar_cane) { return 0 }
            let dirtSand = ["grass_block", "dirt", "coarse_dirt", "podzol", "mycelium",
                            "rooted_dirt", "moss_block", "mud", "sand", "red_sand",
                            "suspicious_sand", "gravel"]
            guard dirtSand.contains(belowName) else { return -1 }
            for (dx, dz) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let n = world.getBlock(px + dx, py - 1, pz + dz) >> 4
                if n == Int(B.water) || n == Int(B.frosted_ice) { return 0 }
            }
            return -1
        }
        if name == "dead_bush" {
            let dryWords = ["sand", "terracotta", "dirt"]
            return dryWords.contains(where: { belowName.contains($0) }) ? 0 : -1
        }
        return blockDefs[below].fullCube ? 0 : -1
    case .carpet, .pressurePlate, .lilyPad:
        let below = world.getBlock(px, py - 1, pz)
        if shape == .lilyPad { return (below >> 4) == Int(B.water) ? 0 : -1 }
        return blockDefs[below >> 4].fullCube || sturdyTopOk(below) ? 0 : -1
    case .hopper:
        return hit.face == 1 ? 0 : hit.face == 0 ? 0 : hit.face ^ 1
    case .lantern:
        return hit.face == 0 ? 1 : 0
    case .campfire:
        return facing
    case .anvil:
        return (facing == 0 || facing == 1) ? 2 : 0
    case .piston:
        // facing away from player incl vertical
        if player.pitch < -0.9 { return Dir.down }
        if player.pitch > 0.9 { return Dir.up }
        return [Dir.north, Dir.south, Dir.west, Dir.east][facingOpp]
    case .vine:
        if hit.face < 2 { return -1 }
        return 1 << (hit.face - 2)
    case .glowLichen, .sculkVein:
        return hit.face ^ 1
    case .cocoa:
        if hit.face < 2 { return -1 }
        let support = world.getBlock(px - DIR_X[hit.face], py, pz - DIR_Z[hit.face]) >> 4
        let supportName = blockDefs[support].name
        if !supportName.contains("jungle_log") && !supportName.contains("jungle_wood") { return -1 }
        return (hit.face - 2) ^ 1
    case .amethystCluster:
        return hit.face ^ 1
    default:
        // axis blocks (logs, basalt, chain, bone)
        let isAxis = name.hasSuffix("_log") || name.hasSuffix("_stem") || name.hasSuffix("_wood")
            || name.contains("hyphae") || name.contains("basalt") || name == "bone_block"
            || name == "chain" || name == "quartz_pillar" || name == "purpur_pillar" || name == "bamboo_block"
        if isAxis {
            return hit.face < 2 ? 0 : (hit.face < 4 ? 2 : 1)
        }
        if blockId == Int(B.observer) {
            if player.pitch < -0.9 { return Dir.up }
            if player.pitch > 0.9 { return Dir.down }
            return [Dir.north, Dir.south, Dir.west, Dir.east][facing]
        }
        if blockId == Int(B.dispenser) || blockId == Int(B.dropper) {
            if player.pitch < -0.9 { return Dir.down }
            if player.pitch > 0.9 { return Dir.up }
            return [Dir.north, Dir.south, Dir.west, Dir.east][facingOpp]
        }
        if blockId == Int(B.barrel) {
            if player.pitch < -0.9 { return Dir.up }
            if player.pitch > 0.9 { return Dir.down }
            return [Dir.north, Dir.south, Dir.west, Dir.east][facingOpp]
        }
        if blockId == Int(B.furnace) || blockId == Int(B.blast_furnace) || blockId == Int(B.smoker) ||
            blockId == Int(B.carved_pumpkin) || blockId == Int(B.jack_o_lantern) || blockId == Int(B.chiseled_bookshelf) || blockId == Int(B.loom) {
            return facingOpp
        }
        return 0
    }
}
private func sturdyTopOk(_ c: Int) -> Bool {
    let id = c >> 4
    let s = shapeOf(id)
    if s == .slab { return (c & 3) != 0 }
    if s == .stairs { return (c & 4) != 0 }
    return blockDefs[id].fullCube
}

// =============================================================================
// EATING / DRINKING completion
// =============================================================================
public func finishUsingItem(_ ctx: InteractCtx) {
    let world = ctx.world, player = ctx.player
    guard let held = player.usingMainHandStack() else {
        player.cancelUsingItem()
        return
    }
    let def = itemDef(held.id)
    if let food = def.food {
        player.heal(Double(food.hunger))
        player.feed(food.hunger, food.saturation)
        for e in food.effects {
            if e.chance == 0 || gameRng.nextFloat() < e.chance {
                player.addEffect(e.effect, e.duration, e.amplifier)
            }
        }
        if def.name == "milk_bucket" {
            player.clearEffects()
            player.replaceUsingMainHand(ItemStack(iid("bucket"), 1))
        } else if def.name == "chorus_fruit" {
            // random teleport
            for _ in 0..<16 {
                let tx = player.x + (gameRng.nextFloat() - 0.5) * 16
                let tz = player.z + (gameRng.nextFloat() - 0.5) * 16
                let ty = world.surfaceY(ifloor(tx), ifloor(tz))
                if ty > world.info.minY {
                    player.setPos(tx, Double(ty), tz)
                    world.hooks.playSound("item.chorus_fruit.teleport", tx, Double(ty), tz, 1, 1)
                    break
                }
            }
            player.consumeUsingMainHand(1)
        } else if def.name.contains("stew") || def.name.contains("soup") {
            player.replaceUsingMainHand(ItemStack(iid("bowl"), 1))
        } else {
            player.consumeUsingMainHand(1)
        }
        world.hooks.playSound("entity.player.burp", player.x, player.y, player.z, 0.5, 1)
        ctx.advance("husbandry_eat")
    } else if def.name == "potion" {
        let pot = potionDef(held.data.potion ?? "water")
        for e in pot.effects { player.addEffect(e.effect, e.duration, e.amplifier) }
        player.replaceUsingMainHand(ItemStack(iid("glass_bottle"), 1))
        world.hooks.playSound("entity.generic.drink", player.x, player.y, player.z, 0.5, 1)
    }
    player.cancelUsingItem()
}

public func releaseUsingItem(_ ctx: InteractCtx) {
    let player = ctx.player
    if !player.usingItem { return }
    guard let held = player.usingMainHandStack() else {
        player.cancelUsingItem()
        return
    }
    let name = itemDef(held.id).name
    if name == "bow" { shootBow(player, player.useItemTicks) }
    else if name == "trident" { throwTridentPlayer(player, player.useItemTicks) }
    else if name == "crossbow" {
        if player.useItemTicks >= 25 - enchLevel(held, "quick_charge") * 5 {
            shootBow(player, 20) // full power
            ctx.world.hooks.playSound("item.crossbow.shoot", player.x, player.y, player.z, 1, 1)
        }
    }
    player.cancelUsingItem()
}

@discardableResult
public func consumeSelectedFoodNow(_ ctx: InteractCtx) -> Bool {
    let player = ctx.player
    guard let held = player.mainHand else { return false }
    let def = itemDef(held.id)
    guard let food = def.food,
          canUseFood(player, food, allowCreativeFullUse: false)
    else { return false }
    player.beginUsingMainHand()
    finishUsingItem(ctx)
    return true
}

// =============================================================================
// BREAKING
// =============================================================================
public func finishBreaking(_ ctx: InteractCtx, _ x: Int, _ y: Int, _ z: Int) {
    let world = ctx.world, player = ctx.player
    let c = world.getBlock(x, y, z)
    let id = c >> 4
    if id == 0 { return }
    let def = blockDefs[id]
    world.hooks.playSound("block." + def.sound + ".break", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 0.9)
    world.hooks.addParticles("block", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 18, 0.4, c)
    world.emitVibration(Double(x), Double(y), Double(z), 12, player)

    // container contents spill
    if let be = world.getBlockEntity(x, y, z) {
        let isShulker = def.name.hasSuffix("shulker_box") || id == Int(B.shulker_box)
        if !isShulker && (be.type == "container" || be.type == "hopper" || be.type == "furnace" || be.type == "brewing" || be.type == "shelf" || be.type == "campfire" || be.type == "crafting") {
            if let items = be.items {
                for s in items { if let s { spawnItem(world, Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, s) } }
            }
            if be.type == "furnace" {
                let xp = Int((be.xpBank ?? 0).rounded(.down))
                if xp > 0 { spawnXP(world, Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, xp) }
            }
        }
        if be.type == "jukebox", let disc = be.disc {
            spawnItem(world, Double(x) + 0.5, Double(y) + 1, Double(z) + 0.5, disc)
        }
        if isShulker && world.rule("doTileDrops") {
            // shulker keeps contents
            let itemId = blockToItem[id]
            if itemId >= 0 {
                let stack = ItemStack(Int(itemId), 1)
                if let items = be.items, items.contains(where: { $0 != nil }) {
                    stack.data.contents = items
                }
                spawnItem(world, Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, stack)
            }
            world.setBlock(x, y, z, 0)
            player.stats["blocksMined"] = (player.stats["blocksMined"] ?? 0) + 1
            return
        }
    }

    // door/bed upper-half cleanup
    let shape = shapeOf(id)
    if shape == .door {
        let upper = (c & 8) != 0
        world.setBlock(x, upper ? y - 1 : y + 1, z, 0)
    } else if shape == .bed {
        let f = c & 3
        let head = (c & 4) != 0
        let ox = x + (head ? -1 : 1) * [0, 0, -1, 1][f]
        let oz = z + (head ? -1 : 1) * [-1, 1, 0, 0][f]
        if shapeOf(world.getBlock(ox, y, oz) >> 4) == .bed { world.setBlock(ox, y, oz, 0) }
    } else if shape == .tallCross {
        let upper = (c & 1) != 0
        let oy = upper ? y - 1 : y + 1
        if (world.getBlock(x, oy, z) >> 4) == id { world.setBlock(x, oy, z, 0, 2 | 4) }
    }

    // infested → spawn silverfish
    if def.name.hasPrefix("infested") {
        world.setBlock(x, y, z, 0)
        _ = spawnMob(world, "silverfish", Double(x) + 0.5, Double(y), Double(z) + 0.5, SpawnOpts())
        return
    }
    // ice melts to water if supported
    if id == Int(B.ice) && player.gameMode != GameMode.creative {
        let held = player.mainHand
        if held == nil || enchLevel(held!, "silk_touch") == 0 {
            let below = world.getBlock(x, y - 1, z) >> 4
            world.setBlock(x, y, z, below != 0 && blockDefs[below].solid ? Int(cell(B.water, 0)) : 0)
            return
        }
    }

    world.setBlock(x, y, z, 0)
    player.stats["blocksMined"] = (player.stats["blocksMined"] ?? 0) + 1

    if player.gameMode == GameMode.creative { return }
    if !world.rule("doTileDrops") { return }
    if !canHarvest(player, c) { return }

    let held = player.mainHand
    let fortune = held.map { enchLevel($0, "fortune") } ?? 0
    let silk = held.map { enchLevel($0, "silk_touch") > 0 } ?? false
    let toolDef = held.map { itemDef($0.id).tool } ?? nil

    // silk touch: drop the block itself
    if silk {
        let itemId = blockToItem[id]
        if itemId >= 0 {
            spawnItem(world, Double(x) + 0.5, Double(y) + 0.3, Double(z) + 0.5, ItemStack(Int(itemId), 1))
            damageToolForBreak(player, c)
            return
        }
    }
    let ctx2 = DropCtx(fortune: fortune, silkTouch: silk,
                       toolType: ToolType(rawValue: toolDef?.type ?? "none") ?? .none,
                       toolTier: toolDef?.tier ?? 0,
                       shears: toolDef?.type == "shears",
                       random: { gameRng.nextFloat() })
    let drops: [Drop]
    if let dropsFn = def.drops {
        drops = dropsFn(c & 15, ctx2)
    } else {
        drops = defaultDrop(id)
    }
    for d in drops {
        guard let itemId = iidOpt(d.item) else { continue }
        var count = 1
        if d.countMin == d.countMax { count = d.countMin }
        else { count = d.countMin + gameRng.nextInt(max(0, d.countMax - d.countMin) + 1) }
        if d.chance != 1 && gameRng.nextFloat() > d.chance { continue }
        if count > 0 { spawnItem(world, Double(x) + 0.5, Double(y) + 0.3, Double(z) + 0.5, ItemStack(itemId, count)) }
    }
    // ore XP
    let xpMap: [Int: (Int, Int)] = [
        Int(B.coal_ore): (0, 2), Int(B.deepslate_coal_ore): (0, 2),
        Int(B.diamond_ore): (3, 7), Int(B.deepslate_diamond_ore): (3, 7),
        Int(B.emerald_ore): (3, 7), Int(B.deepslate_emerald_ore): (3, 7),
        Int(B.lapis_ore): (2, 5), Int(B.deepslate_lapis_ore): (2, 5),
        Int(B.redstone_ore): (1, 5), Int(B.deepslate_redstone_ore): (1, 5),
        Int(B.nether_quartz_ore): (2, 5), Int(B.nether_gold_ore): (0, 1),
        Int(B.spawner): (15, 43), Int(B.sculk): (1, 1), Int(B.sculk_sensor): (5, 5), Int(B.sculk_catalyst): (5, 5), Int(B.sculk_shrieker): (5, 5),
    ]
    if !silk, let (lo, hi) = xpMap[id] {
        spawnXP(world, Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, lo + gameRng.nextInt(hi - lo + 1))
    }
    damageToolForBreak(player, c)
    player.addExhaustion(0.005)
}
private func damageToolForBreak(_ player: Player, _ c: Int) {
    guard let held = player.mainHand else { return }
    let toolDef = itemDef(held.id).tool
    if toolDef != nil && blockDefs[c >> 4].hardness > 0 {
        player.damageHeld(toolDef!.type == "sword" ? 2 : 1)
    }
}
private func defaultDrop(_ id: Int) -> [Drop] {
    let name = blockDefs[id].name
    return itemExists(name) ? [Drop(name)] : []
}

// =============================================================================
// Bonemeal
// =============================================================================
@discardableResult
public func applyBonemeal(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    let c = world.getBlock(x, y, z)
    let id = c >> 4
    world.hooks.addParticles("glow", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 12, 0.5, 0)

    if id == Int(B.wheat) || id == Int(B.carrots) || id == Int(B.potatoes) {
        let stage = min(7, (c & 7) + 2 + gameRng.nextInt(3))
        world.setBlock(x, y, z, Int(cell(UInt16(id), stage)))
        return true
    }
    if id == Int(B.beetroots) || id == Int(B.sweet_berry_bush) {
        let stage = min(3, (c & 3) + 1)
        world.setBlock(x, y, z, Int(cell(UInt16(id), stage)))
        return true
    }
    if blockDefs[id].name.contains("sapling") || id == Int(B.mangrove_propagule) || id == Int(B.crimson_fungus) || id == Int(B.warped_fungus) {
        if gameRng.nextFloat() < 0.45 { growTreeAt(world, x, y, z, id) }
        return true
    }
    if id == Int(B.grass_block) {
        // sprout vegetation around
        for _ in 0..<24 {
            let tx = x + gameRng.nextInt(7) - 3
            let tz = z + gameRng.nextInt(7) - 3
            let ty = world.surfaceY(tx, tz)
            if (world.getBlock(tx, ty - 1, tz) >> 4) == Int(B.grass_block) && world.getBlock(tx, ty, tz) == 0 {
                let r = gameRng.nextFloat()
                world.setBlock(tx, ty, tz, r < 0.8 ? Int(cell(B.short_grass)) : r < 0.9 ? Int(cell(B.dandelion)) : Int(cell(B.poppy)))
            }
        }
        return true
    }
    if id == Int(B.melon_stem) || id == Int(B.pumpkin_stem) {
        let stage = min(7, (c & 7) + 2 + gameRng.nextInt(3))
        world.setBlock(x, y, z, Int(cell(UInt16(id), stage)))
        return true
    }
    if id == Int(B.bamboo) || id == Int(B.bamboo_sapling) || id == Int(B.kelp) || id == Int(B.sugar_cane) || id == Int(B.cactus) {
        // trigger a few growth ticks
        if let h = randomTickHandlers[id] {
            h(world, x, y, z, c)
            h(world, x, y, z, world.getBlock(x, y, z))
        }
        return true
    }
    if id == Int(B.short_grass) {
        world.setBlock(x, y, z, Int(cell(B.tall_grass, 0)))
        if world.getBlock(x, y + 1, z) == 0 { world.setBlock(x, y + 1, z, Int(cell(B.tall_grass, 1))) }
        return true
    }
    if id == Int(B.moss_block) {
        for _ in 0..<12 {
            let tx = x + gameRng.nextInt(5) - 2
            let tz = z + gameRng.nextInt(5) - 2
            let tc = world.getBlock(tx, y, tz) >> 4
            if tc == Int(B.stone) || tc == Int(B.dirt) || tc == Int(B.grass_block) || tc == Int(B.deepslate) {
                world.setBlock(tx, y, tz, Int(cell(B.moss_block)))
                if world.getBlock(tx, y + 1, tz) == 0 && gameRng.nextFloat() < 0.5 {
                    world.setBlock(tx, y + 1, tz, gameRng.nextFloat() < 0.7 ? Int(cell(B.moss_carpet)) : Int(cell(B.azalea)))
                }
            }
        }
        return true
    }
    if id == Int(B.torchflower_crop) || id == Int(B.pitcher_crop) {
        if let h = randomTickHandlers[id] { h(world, x, y, z, c) }
        return true
    }
    if id == Int(B.cocoa) {
        let age = (c >> 2) & 3
        if age < 2 {
            world.setBlock(x, y, z, Int(cell(B.cocoa, (c & 3) | ((age + 1) << 2))))
            return true
        }
    }
    return false
}

// =============================================================================
// Registration umbrella for the whole systems layer
// =============================================================================
private var systemsRegistered = false

public func registerAllSystems() {
    if systemsRegistered { return }
    systemsRegistered = true
    registerExplosionHandler()
    registerCombatBindings()
    registerBlockEntityHandlers()
    registerFarmingHandlers()
    registerSupportPops()
    registerRedstoneHandlers()
    registerFluidHandlers()   // was only wired in pebsmoke — in-app water/lava never flowed
    bindBonemeal(applyBonemeal)
}
