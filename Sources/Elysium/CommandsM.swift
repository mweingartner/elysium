// Chat commands — (/debug and /rendertest were
// legacy diagnostics and stay behind.)

import Foundation
import ElysiumCore

func runCommand(_ game: GameCore, _ raw: String) {
    if !raw.hasPrefix("/") {
        pushChat("<You> \(raw)")
        return
    }
    let parts = splitCommandLineArguments(String(raw.dropFirst()).trimmingCharacters(in: .whitespaces))
    let cmd = parts.first?.lowercased() ?? ""
    let args = Array(parts.dropFirst())
    if cmd == "lan" || cmd == "multiplayer" {
        elysiumMainActorSync { runLANCommand(game, args) }
        return
    }
    guard let p = game.player else { return }
    let world = game.world
    func fail(_ msg: String) { pushChat("§c" + msg) }
    func ok(_ msg: String) { pushChat("§7" + msg) }
    func parseCoord(_ s: String, _ base: Double) -> Double {
        if s.hasPrefix("~") {
            return base + (s.count > 1 ? Double(s.dropFirst()) ?? 0 : 0)
        }
        return Double(s) ?? 0
    }
    func arg(_ i: Int) -> String? { i < args.count ? args[i] : nil }
    func cursorHit() -> RaycastHit? {
        game.crosshairBlock() ?? game.lastCursorHit
    }
    func targetBlock() -> (x: Int, y: Int, z: Int)? {
        if let hit = cursorHit() { return (hit.x, hit.y, hit.z) }
        if let t = game.targetedBlock { return (t.x, t.y, t.z) }
        return nil
    }

    switch cmd {
    case "help":
        ok("Commands: ai, lan, clone, place, listTemplates, templates, give, tp, time, weather, gamemode, seed, kill, summon, effect, enchant, xp, setblock, fill, locate, difficulty, gamerule, clear, spawnpoint, heal")
    case "ai", "agent":
        let prompt = args.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return fail("Usage: /ai <request>") }
        elysiumOllamaAgent.run(prompt: prompt, game: game)
    case "clone":
        guard let name = cloneTemplateNameFromCommandArgs(args) else {
            return fail("Usage: /clone the target with new name \"name\"")
        }
        guard let target = targetBlock() else { return fail(TemplateError.missingTarget.description) }
        do {
            let result = try cloneObjectTemplate(named: name, from: world, targetX: target.x, targetY: target.y, targetZ: target.z)
            guard try game.db.putTemplate(result.template) else {
                return fail("Template store write failed.")
            }
            ok("Cloned object \"\(result.template.name)\" — \(result.template.blocks.count) blocks, \(result.template.blockEntities.count) block entities, \(result.template.sizeX)x\(result.template.sizeY)x\(result.template.sizeZ)")
        } catch let error as TemplateError {
            fail(error.description)
        } catch {
            fail("Clone failed: \(error)")
        }
    case "place":
        guard let name = placeTemplateNameFromCommandArgs(args) else {
            return fail("Usage: /place \"name\"")
        }
        do {
            guard let template = try game.db.getTemplate(named: name) else {
                return fail("Unknown template: \(name)")
            }
            try game.beginTemplatePlacement(template)
            ok("Placing object \"\(template.name)\" - scroll to rotate, left click to place")
        } catch let error as TemplateError {
            fail(error.description)
        } catch {
            fail("Place failed: \(error)")
        }
    case "listtemplates", "templates":
        let names = game.db.listTemplates()
        ok(names.isEmpty ? "No templates saved." : "Opening \(names.count) saved template\(names.count == 1 ? "" : "s").")
        game.openScreen("templates", nil)
    case "give":
        guard let itemName = arg(0) else { return fail("Usage: /give <item> [count]") }
        let count = arg(1).flatMap(Int.init) ?? 1
        guard let id = iidOpt(itemName) else { return fail("Unknown item: \(itemName)") }
        var remaining = count
        while remaining > 0 {
            let give = min(remaining, itemDef(id).maxStack)
            if !p.give(ItemStack(id, give)) { break }
            remaining -= give
        }
        ok("Gave \(count - remaining) \(itemName)")
    case "tp", "teleport":
        guard args.count >= 3 else { return fail("Usage: /tp <x> <y|top> <z> [yaw pitch]") }
        let x = parseCoord(args[0], p.x)
        let z = parseCoord(args[2], p.z)
        let y = args[1] == "top" ? Double(world.surfaceY(Int(x.rounded(.down)), Int(z.rounded(.down))) + 1)
                                 : parseCoord(args[1], p.y)
        p.setPos(x, y, z)
        p.vx = 0; p.vy = 0; p.vz = 0
        if args.count >= 5, let yaw = Double(args[3]), let pitch = Double(args[4]) {
            p.yaw = yaw * .pi / 180
            p.pitch = max(-89.9, min(89.9, pitch)) * .pi / 180
        }
        ok(String(format: "Teleported to %.1f %.1f %.1f", x, y, z))
    case "time":
        if arg(0) == "set" {
            let presets: [String: Int] = ["day": 1000, "noon": 6000, "sunset": 12000, "night": 13000, "midnight": 18000, "sunrise": 23000]
            guard let v = presets[arg(1) ?? ""] ?? arg(1).flatMap(Int.init) else {
                return fail("Usage: /time set <day|noon|night|midnight|ticks>")
            }
            world.dayTime = ((v % 24000) + 24000) % 24000
            ok("Set time to \(world.dayTime)")
        } else if arg(0) == "add" {
            world.dayTime = (world.dayTime + (arg(1).flatMap(Int.init) ?? 0)) % 24000
            ok("Time is now \(world.dayTime)")
        } else {
            ok("Time: \(world.dayTime) (day \(world.time / 24000))")
        }
    case "weather":
        switch arg(0) {
        case "clear":
            world.raining = false
            world.thundering = false
            world.weatherTimer = 12000
        case "rain":
            world.raining = true
            world.thundering = false
            world.weatherTimer = 12000
        case "thunder":
            world.raining = true
            world.thundering = true
            world.weatherTimer = 12000
        default:
            return fail("Usage: /weather <clear|rain|thunder>")
        }
        ok("Weather set to \(arg(0)!)")
    case "gamemode", "gm":
        switch arg(0) {
        case "creative", "1", "c": p.setGameMode(GameMode.creative)
        case "survival", "0", "s": p.setGameMode(GameMode.survival)
        default: return fail("Usage: /gamemode <survival|creative>")
        }
        p.flying = p.flying && p.gameMode == GameMode.creative
        ok("Game mode set to \(p.gameMode == GameMode.creative ? "Creative" : "Survival")")
    case "seed":
        ok("Seed: \(world.seed)")
    case "kill":
        if arg(0) == "@e" {
            var n = 0
            for e in Array(world.entities) {
                guard let ent = e as? Entity, !ent.isPlayer else { continue }
                ent.remove()
                n += 1
            }
            ok("Removed \(n) entities")
        } else {
            _ = p.hurt(10000, "void")
            ok("Ouch")
        }
    case "summon":
        guard let mob = arg(0) else { return fail("Usage: /summon <mob> [x y z]") }
        let mobs = spawnableMobs()
        if !mobs.contains(mob) {
            return fail("Unknown mob: \(mob). Try: \(mobs.prefix(8).joined(separator: ", "))…")
        }
        let x = arg(1).map { parseCoord($0, p.x) } ?? p.x
        let y = arg(2).map { parseCoord($0, p.y) } ?? p.y
        let z = arg(3).map { parseCoord($0, p.z) } ?? p.z
        if spawnMob(world, mob, x, y, z, nil) != nil {
            ok("Summoned \(mob)")
        }
    case "effect":
        if arg(0) == "clear" {
            p.clearEffects()
            ok("Cleared effects")
            return
        }
        let give = arg(0) == "give" ? Array(args.dropFirst()) : args
        guard let effId = give.first, EFFECT_BY_ID[effId] != nil else {
            return fail("Unknown effect: \(give.first ?? "?")")
        }
        let dur = give.count > 1 ? Int(give[1]) ?? 30 : 30
        let amp = give.count > 2 ? Int(give[2]) ?? 0 : 0
        p.addEffect(effId, dur * 20, amp)
        ok("Applied \(effId) \(amp + 1) for \(dur)s")
    case "enchant":
        guard let enchId = arg(0), let e = ENCH_BY_ID[enchId] else {
            return fail("Unknown enchantment: \(arg(0) ?? "?")")
        }
        let lvl = arg(1).flatMap(Int.init) ?? 1
        guard let held = p.mainHand else { return fail("Hold an item first") }
        held.ench = held.ench.filter { $0.id != enchId } + [EnchInstance(enchId, min(lvl, 255))]
        ok("Enchanted with \(e.displayName) \(lvl)")
    case "xp", "experience":
        let amount = arg(0).flatMap { Int($0.replacingOccurrences(of: "L", with: "")) } ?? 1
        if arg(1) == "levels" || (arg(0) ?? "").hasSuffix("L") {
            p.xpLevel += amount
            ok("Added \(amount) levels")
        } else {
            p.addXP(amount)
            ok("Added \(amount) XP")
        }
    case "setblock":
        guard args.count >= 4 else { return fail("Usage: /setblock <x> <y> <z> <block> [meta]") }
        let x = Int(parseCoord(args[0], p.x).rounded(.down))
        let y = Int(parseCoord(args[1], p.y).rounded(.down))
        let z = Int(parseCoord(args[2], p.z).rounded(.down))
        let blockName = args[3]
        let id: UInt16? = blockName == "air" ? 0 : bidOpt(blockName)
        guard let id else { return fail("Unknown block: \(blockName)") }
        let meta = arg(4).flatMap(Int.init) ?? 0
        world.setBlock(x, y, z, id == 0 ? 0 : Int(cell(id, meta)))
        ok("Set block at \(x) \(y) \(z)")
    case "fill":
        guard args.count >= 7 else { return fail("Usage: /fill <x0> <y0> <z0> <x1> <y1> <z1> <block>") }
        let x0 = Int(parseCoord(args[0], p.x).rounded(.down)), y0 = Int(parseCoord(args[1], p.y).rounded(.down)), z0 = Int(parseCoord(args[2], p.z).rounded(.down))
        let x1 = Int(parseCoord(args[3], p.x).rounded(.down)), y1 = Int(parseCoord(args[4], p.y).rounded(.down)), z1 = Int(parseCoord(args[5], p.z).rounded(.down))
        let blockName = args[6]
        let id: UInt16? = blockName == "air" ? 0 : bidOpt(blockName)
        guard let id else { return fail("Unknown block: \(blockName)") }
        let vol = (abs(x1 - x0) + 1) * (abs(y1 - y0) + 1) * (abs(z1 - z0) + 1)
        if vol > 32768 { return fail("Too many blocks (\(vol) > 32768)") }
        var n = 0
        for y in min(y0, y1)...max(y0, y1) {
            for z in min(z0, z1)...max(z0, z1) {
                for x in min(x0, x1)...max(x0, x1) {
                    world.setBlock(x, y, z, id == 0 ? 0 : Int(cell(id, 0)))
                    n += 1
                }
            }
        }
        ok("Filled \(n) blocks")
    case "locate":
        guard let target = arg(0) else { return fail("Usage: /locate <structure>") }
        if target == "stronghold" {
            var best: (Int, Int)?
            var bestD = Double.infinity
            for (cx, cz) in strongholdPositions(world.seed) {
                let dx = Double(cx * 16) - p.x, dz = Double(cz * 16) - p.z
                let d = dx * dx + dz * dz
                if d < bestD {
                    bestD = d
                    best = (cx * 16, cz * 16)
                }
            }
            if let best {
                ok("Nearest stronghold: \(best.0), ~, \(best.1) (\(Int(bestD.squareRoot().rounded())) blocks)")
            }
            return
        }
        guard let def = STRUCTURES.first(where: { $0.id == target }) else {
            return fail("Unknown structure. Try: \(STRUCTURES.map { $0.id }.joined(separator: ", "))")
        }
        let pcx = Int((p.x / 16).rounded(.down)), pcz = Int((p.z / 16).rounded(.down))
        let ctx = GenCtx(
            seed: world.seed,
            heightAt: { x, z in world.surfaceY(x, z) },
            biomeAt: { x, z in world.biomeAt(x, world.surfaceY(x, z), z) },
            dim: world.dim.rawValue)
        for r in 0..<12 {
            for rz in -r...r {
                for rx in -r...r {
                    if max(abs(rx), abs(rz)) != r { continue }
                    let rcx = Int((Double(pcx) / Double(def.spacing)).rounded(.down)) + rx
                    let rcz = Int((Double(pcz) / Double(def.spacing)).rounded(.down)) + rz
                    let (ocx, ocz) = structureOriginFor(def, world.seed, rcx, rcz)
                    if getPlan(def, ctx, ocx, ocz) != nil {
                        ok("Nearest \(target): \(ocx * 16 + 8), ~, \(ocz * 16 + 8)")
                        return
                    }
                }
            }
        }
        fail("Could not find \(target) nearby")
    case "difficulty":
        guard let d = ["peaceful", "easy", "normal", "hard"].firstIndex(of: arg(0) ?? "") else {
            return fail("Usage: /difficulty <peaceful|easy|normal|hard>")
        }
        game.setDifficulty(d)
        ok("Difficulty set to \(DIFFICULTY_NAMES[d])")
    case "gamerule":
        guard let rule = arg(0) else {
            ok(world.gameRules.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))
            return
        }
        guard world.gameRules[rule] != nil else { return fail("Unknown gamerule: \(rule)") }
        if let v = arg(1) {
            game.setGameRule(rule, v == "true" ? 1 : v == "false" ? 0 : Double(v) ?? 0)
        }
        ok("\(rule) = \(world.gameRules[rule]!)")
    case "clear":
        for i in 0..<p.inventory.count { p.inventory[i] = nil }
        for i in 0..<p.armor.count { p.armor[i] = nil }
        p.offHand = nil
        ok("Inventory cleared")
    case "spawnpoint":
        p.spawnPoint = (Int(p.x.rounded(.down)), Int(p.y.rounded(.down)), Int(p.z.rounded(.down)))
        p.spawnDim = world.dim.rawValue
        ok("Spawn point set")
    case "heal":
        p.health = p.maxHealth
        p.hunger = 20
        p.saturation = 20
        ok("Healed")
    case "meshmode":
        let mode = arg(0)
        guard mode == "simple" || mode == "greedy" else { return fail("Usage: /meshmode <simple|greedy>") }
        game.setMeshMode(simple: mode == "simple")
        ok("Mesh mode: \(mode!) — rebuilding world…")
    case "surface", "top":
        let sx = Int(p.x.rounded(.down)), sz = Int(p.z.rounded(.down))
        let sy = world.surfaceY(sx, sz)
        p.setPos(p.x, Double(sy), p.z)
        p.vx = 0; p.vy = 0; p.vz = 0
        p.fallDistance = 0
        ok("Brought you to the surface (y=\(sy))")
    default:
        fail("Unknown command: /\(cmd). Try /help")
    }
}
