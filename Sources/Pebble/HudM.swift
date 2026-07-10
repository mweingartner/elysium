// HUD — hotbar, hearts, hunger, armor, air, XP bar,
// crosshair, boss bars, effect icons, action bar, debug screen, subtitles,
// toasts. Same pixel layouts, drawn through UICanvas.

import Foundation
import QuartzCore
import PebbleCore

struct SubtitleInfo {
    var text: String
    var time: Int
}

final class HUD {
    var actionBarText = ""
    var actionBarTime = 0
    var toasts: [(def: AdvancementDef, time: Int)] = []
    var subtitles: [SubtitleInfo] = []
    var bossBars: [BossBarInfo] = []
    var debugVisible = false
    var debugInfo: [String: String] = [:]
    var hideGui = false
    // HUD timers are in 20Hz ticks but draw() runs per FRAME — convert real
    // time to whole tick steps or toasts/action bars expire 2-10× too fast
    // at high fps
    private var lastTimerTime = CACurrentMediaTime()
    private var timerAccum = 0.0
    private var tickSteps = 0
    private var rpgInsightCache = RPGHUDInsightCache()

    func showActionBar(_ text: String) {
        actionBarText = text
        actionBarTime = 60
    }
    func pushToast(_ def: AdvancementDef) {
        toasts.append((def, 0))
    }
    func pushSubtitle(_ text: String) {
        if let last = subtitles.last, last.text == text {
            subtitles[subtitles.count - 1].time = 0
            return
        }
        subtitles.append(SubtitleInfo(text: text, time: 0))
        if subtitles.count > 5 { subtitles.removeFirst() }
    }

    func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        if hideGui { return }
        let nowT = CACurrentMediaTime()
        timerAccum += min(0.25, nowT - lastTimerTime)
        lastTimerTime = nowT
        tickSteps = Int(timerAccum * 20)
        timerAccum -= Double(tickSteps) / 20
        let cv = ui.cv
        guard let player = game.player else { return }
        let W = ui.width, H = ui.height
        let cx = (W / 2).rounded(.down)
        let screenOpen = ui.hasScreen()
        let rpgDrawPlan = rpgHUDDrawPlan(player, screenOpen: screenOpen)
        let rpgInsightLines = rpgInsightCache.resolve(
            key: rpgHUDInsightCacheKey(player, screenOpen: screenOpen)
        ) { rpgHUDInsightLines(player) }
        let rpgHudLift = rpgDrawPlan.liftSurvivalHUD ? 24.0 : 0.0

        // vanilla pack HUD when the GUI sheets are loaded; procedural fallback
        let packHud = ui.hasSheet("icons") && ui.hasSheet("widgets")

        // crosshair (plain white; canvas used difference-blend)
        if !ui.hasScreen() {
            if packHud {
                ui.blitSheet("icons", 0, 0, 15, 15, ((W - 15) / 2).rounded(), ((H - 15) / 2).rounded())
            } else {
                cv.setFill("rgba(255,255,255,0.85)")
                cv.fillRect(cx - 5, H / 2 - 0.5, 10, 1)
                cv.fillRect(cx - 0.5, H / 2 - 5, 1, 10)
            }
            // attack indicator
            let str = player.attackStrength()
            if str < 1 {
                cv.setFill("rgba(255,255,255,0.4)")
                cv.fillRect(cx - 8, H / 2 + 8, 16, 2)
                cv.setFill("#ffffff")
                cv.fillRect(cx - 8, H / 2 + 8, (16 * str).rounded(), 2)
            }
        }
        if rpgDrawPlan.showInsights {
            let layout = rpgHUDInsightLayout(viewWidth: W, viewHeight: H)
            for (index, line) in rpgInsightLines.enumerated() {
                cv.drawText(fitHUD(line, maxWidth: layout.maximumWidth),
                            layout.x, layout.y + Double(index * 10),
                            1, "#b9ddff", shadow: true)
            }
        }

        // hotbar
        let hbX = cx - 91
        let hbY = packHud ? H - 22 : H - 23
        if packHud {
            ui.blitSheet("widgets", 0, 0, 182, 22, hbX, hbY)
            ui.blitSheet("widgets", 0, 22, 24, 23, hbX - 1 + Double(player.selectedSlot) * 20, hbY - 1)
            if let off = player.offHand {
                ui.blitSheet("widgets", 24, 22, 29, 24, hbX - 29 - 3, hbY - 1)
                ui.drawItemStack(off, hbX - 29, hbY + 2)
            }
            for i in 0..<9 {
                if let s = player.inventory[i] {
                    ui.drawItemStack(s, hbX + 2 + Double(i) * 20, hbY + 2)
                }
            }
        } else {
            cv.setFill("rgba(0,0,0,0.55)")
            cv.fillRect(hbX, hbY, 182, 22)
            cv.setStroke("rgba(255,255,255,0.35)")
            cv.strokeRect(hbX, hbY, 182, 22)
            for i in 0..<9 {
                let sx = hbX + 1 + Double(i) * 20
                if i == player.selectedSlot {
                    cv.setStroke("#ffffff")
                    cv.strokeRect(sx - 1, hbY - 1, 23, 24, 2)
                }
                if let s = player.inventory[i] {
                    ui.drawItemStack(s, sx + 1, hbY + 2)
                }
            }
        }
        // held item name
        let held = player.inventory[player.selectedSlot]
        if let held, actionBarTime <= 0, game.heldNameTime > 0 {
            let name = held.label ?? itemDef(held.id).displayName
            cv.globalAlpha = Float(min(1, Double(game.heldNameTime) / 20))
            cv.drawTextCentered(name, cx, hbY - 38 - rpgHudLift, 1)
            cv.globalAlpha = 1
        }
        if actionBarTime > 0 {
            actionBarTime = max(0, actionBarTime - tickSteps)
            cv.globalAlpha = Float(min(1, Double(actionBarTime) / 20))
            cv.drawTextCentered(actionBarText, cx, hbY - 38 - rpgHudLift, 1)
            cv.globalAlpha = 1
        }

        if !(ui.current() is MapScreen) {
            let mapRect = mapMinimapRect(screenWidth: W, screenHeight: H,
                                         hotbarCenterX: cx, hotbarHalfWidth: 91,
                                         hotbarTopY: hbY,
                                         sizeMode: game.mapMinimapSizeMode)
            let bounds = game.loadedMapBounds()
            let view = mapViewportCenteredOnPlayer(playerX: player.x, playerZ: player.z,
                                                   span: game.mapSpanBlocks,
                                                   bounds: bounds)
            drawMapOverlay(ui, game, rect: mapRect, viewport: view, expanded: false, bounds: bounds)
        }

        if player.gameMode != GameMode.creative {
            // 9×9 icon blit from icons.png (vanilla offsets), pack path only
            func icon9(_ sx: Double, _ sy: Double, _ dx: Double, _ dy: Double) {
                ui.blitSheet("icons", sx, sy, 9, 9, dx, dy)
            }
            // hearts
            let healthY = (packHud ? H - 39 : hbY - 10) - rpgHudLift
            let hearts = Int((player.maxHealth / 2).rounded(.up))
            let hp = player.health
            let shake = player.hurtTime > 0 ? (Foundation.sin(CACurrentMediaTime() * 50) * 1).rounded() : 0
            let kind = player.hasEffect("wither") ? "wither"
                : player.hasEffect("poison") ? "poison"
                : player.freezeTicks > 100 ? "frozen" : "normal"
            // icons.png heart column x by kind (full, half)
            let heartX: [String: (Double, Double)] = [
                "normal": (52, 61), "poison": (88, 97), "wither": (124, 133),
                "absorb": (160, 169), "frozen": (178, 187),
            ]
            for i in 0..<hearts {
                let hx = hbX + Double(i) * 8
                let hy = healthY + (player.hurtTime > 0 && i % 2 == 0 ? shake : 0)
                let v = hp - Double(i * 2)
                if packHud {
                    icon9(16, 0, hx, hy)
                    let (full, half) = heartX[kind]!
                    if v >= 2 { icon9(full, 0, hx, hy) }
                    else if v >= 1 { icon9(half, 0, hx, hy) }
                } else {
                    drawHeart(cv, hx, hy, "bg", false)
                    if v >= 2 { drawHeart(cv, hx, hy, kind, false) }
                    else if v >= 1 { drawHeart(cv, hx, hy, kind, true) }
                }
            }
            // absorption hearts
            if player.absorption > 0 {
                for i in 0..<Int((player.absorption / 2).rounded(.up)) {
                    if packHud { icon9(160, 0, hbX + Double(i % 10) * 8, healthY - 10) }
                    else { drawHeart(cv, hbX + Double(i % 10) * 8, healthY - 10, "absorb", false) }
                }
            }
            // hunger (right-aligned)
            for i in 0..<10 {
                let hx = hbX + 182 - 9 - Double(i) * 8
                let v = player.hunger - i * 2
                let rotten = player.hasEffect("hunger")
                if packHud {
                    icon9(16, 27, hx, healthY)
                    if v >= 2 { icon9(rotten ? 88 : 52, 27, hx, healthY) }
                    else if v >= 1 { icon9(rotten ? 97 : 61, 27, hx, healthY) }
                } else {
                    drawFood(cv, hx, healthY, "bg")
                    if v >= 2 { drawFood(cv, hx, healthY, rotten ? "rotten" : "normal") }
                    else if v >= 1 { drawFood(cv, hx, healthY, "half") }
                }
            }
            // armor
            let armorVal = player.armorValue()
            if armorVal > 0 {
                for i in 0..<10 {
                    let ax = hbX + Double(i) * 8
                    let v = armorVal - Double(i * 2)
                    if packHud {
                        if v >= 2 { icon9(34, 9, ax, healthY - 10) }
                        else if v >= 1 { icon9(25, 9, ax, healthY - 10) }
                        else { icon9(16, 9, ax, healthY - 10) }
                    } else {
                        if v >= 2 { drawArmorIcon(cv, ax, healthY - 10, "full") }
                        else if v >= 1 { drawArmorIcon(cv, ax, healthY - 10, "half") }
                        else { drawArmorIcon(cv, ax, healthY - 10, "empty") }
                    }
                }
            }
            // air bubbles (right-aligned, above hunger)
            if player.airSupply < 300 {
                let bubbles = Int((Double(player.airSupply) / 30).rounded(.up))
                for i in 0..<10 where i < bubbles {
                    if packHud { icon9(16, 18, hbX + 182 - 9 - Double(i) * 8, healthY - 10) }
                    else { drawBubble(cv, hbX + 182 - 9 - Double(i) * 8, healthY - 10) }
                }
            }
            // XP bar
            if packHud {
                let xpY = H - 29 - rpgHudLift
                ui.blitSheet("icons", 0, 64, 182, 5, hbX, xpY)
                let fill = (Double(182) * player.xpProgress).rounded()
                if fill > 0 { ui.blitSheet("icons", 0, 69, fill, 5, hbX, xpY) }
                if player.xpLevel > 0 {
                    cv.drawTextCentered(String(player.xpLevel), cx, xpY - 6, 1, "#80ff20")
                }
            } else {
                let xpY = hbY - 4 - rpgHudLift
                cv.setFill("#1c1c1c")
                cv.fillRect(hbX, xpY, 182, 3)
                cv.setFill("#80ff20")
                cv.fillRect(hbX, xpY, (182 * player.xpProgress).rounded(), 3)
                if player.xpLevel > 0 {
                    cv.drawTextCentered(String(player.xpLevel), cx, xpY - 10, 1, "#80ff20")
                }
            }
            // vehicle health (riding)
            if let v = player.vehicle as? LivingEntity {
                cv.drawTextCentered("♥ \(Int(v.health.rounded(.up))) / \(Int(v.maxHealth))", cx, healthY - 20, 1, "#ff5555")
            }
        }
        if rpgDrawPlan.showQuickSlots {
            let rpgState = repairRPGCharacterState(player.rpg)
            let derived = rpgDerivedStats(rpgState)
            let f = max(0, min(1, rpgState.fatigue / max(1, derived.maxFatigue)))
            let fx = hbX + 186
            let fy = hbY
            cv.setFill("#1c1c1c")
            cv.fillRect(fx, fy, 5, 22)
            cv.setFill("#55aaff")
            cv.fillRect(fx + 1, fy + 21 - (20 * f).rounded(), 3, (20 * f).rounded())
            drawRPGQuickSlots(ui, rpg: rpgState, hotbarX: hbX, hotbarY: hbY)
        }

        // boss bars
        var bbY = 6.0
        for bar in bossBars {
            cv.drawTextCentered(bar.name, cx, bbY, 1)
            cv.setFill("#1c1c1c")
            cv.fillRect(cx - 91, bbY + 10, 182, 5)
            cv.setFill(bar.color)
            cv.fillRect(cx - 91, bbY + 10, (182 * max(0, min(1, bar.progress))).rounded(), 5)
            bbY += 22
        }

        // status effect icons (top right)
        var efX = W - 26
        for e in player.effects {
            let def = effectDef(e.id)
            cv.setFill(def.beneficial ? "rgba(30,30,80,0.7)" : "rgba(80,30,30,0.7)")
            cv.fillRect(efX, 4, 22, 22)
            cv.setFill("#" + String(format: "%06x", def.color))
            cv.fillRect(efX + 4, 8, 14, 10)
            let secs = e.duration / 20
            let t = e.duration < 0 ? "∞" : "\(secs / 60):\(String(format: "%02d", secs % 60))"
            cv.drawTextCentered(t, efX + 11, 19, 1, "#ffffff", shadow: false)
            if e.amplifier > 0 { cv.drawText(String(e.amplifier + 1), efX + 2, 5, 1) }
            efX -= 24
        }

        // subtitles (accessibility)
        if game.settings.subtitles && !subtitles.isEmpty {
            var sy = H - 60
            var i = subtitles.count - 1
            while i >= 0 {
                subtitles[i].time += tickSteps
                if subtitles[i].time > 60 {
                    subtitles.remove(at: i)
                    i -= 1
                    continue
                }
                let sub = subtitles[i]
                let w = Double(textWidth(sub.text)) + 6
                cv.setFill("rgba(0,0,0,0.7)")
                cv.fillRect(W - w - 6, sy, w, 11)
                cv.drawText(sub.text, W - w - 3, sy + 2, 1)
                sy -= 12
                i -= 1
            }
        }

        // toasts
        var ti = toasts.count - 1
        while ti >= 0 {
            toasts[ti].time += tickSteps
            if toasts[ti].time > 120 {
                toasts.remove(at: ti)
                ti -= 1
                continue
            }
            let t = toasts[ti]
            let slide = t.time < 10 ? Double(10 - t.time) * 16 : t.time > 110 ? Double(t.time - 110) * 16 : 0
            let tx = W - 160 + slide
            let ty = 8 + Double(ti) * 36
            ui.drawPanel(tx, ty, 152, 32)
            cv.drawText(t.def.frame == "challenge" ? "§dChallenge Complete!" : "§eAdvancement Made!", tx + 28, ty + 6, 1)
            cv.drawText(t.def.title, tx + 28, ty + 17, 1)
            if let iconId = iidOpt(t.def.icon) {
                cv.drawItemIcon(iconId, nil, tx + 7, ty + 8, 16, 16)
            }
            ti -= 1
        }

        // debug overlay
        if debugVisible {
            drawDebug(ui, game)
        }
    }

    private func drawHeart(_ cv: UICanvas, _ x: Double, _ y: Double, _ kind: String, _ half: Bool) {
        let colors: [String: (String, String)] = [
            "bg": ("#3f1414", "#1f0a0a"),
            "normal": ("#ff2020", "#a80000"),
            "poison": ("#94a061", "#586038"),
            "wither": ("#3a3a3a", "#1c1c1c"),
            "frozen": ("#60c8e8", "#3088a8"),
            "absorb": ("#e8c83c", "#a8862c"),
        ]
        let (main, dark) = colors[kind] ?? colors["normal"]!
        let rows = [".##.##.", "#######", "#######", ".#####.", "..###..", "...#..."]
        for (ry, row) in rows.enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                if half && rx >= 4 { continue }
                cv.setFill(ry < 3 ? main : dark)
                cv.fillRect(x + Double(rx), y + Double(ry), 1, 1)
            }
        }
        // shine pixel sits at rx=1, inside the half-heart clip — always drawn
        if kind != "bg" {
            cv.setFill("#ffffff")
            cv.fillRect(x + 1, y + 1, 1, 1)
        }
    }
    private func drawFood(_ cv: UICanvas, _ x: Double, _ y: Double, _ kind: String) {
        let main = kind == "bg" ? "#2a1c10" : kind == "rotten" ? "#7a8a4a" : "#c87830"
        let dark = kind == "bg" ? "#180f08" : kind == "rotten" ? "#586038" : "#8a4a1c"
        let rows = ["..###..", ".#####.", ".#####.", ".#####.", "..###..", "...#..."]
        for (ry, row) in rows.enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                if kind == "half" && rx >= 4 { continue }
                cv.setFill(ry > 2 ? dark : main)
                cv.fillRect(x + Double(rx), y + Double(ry), 1, 1)
            }
        }
    }
    private func drawArmorIcon(_ cv: UICanvas, _ x: Double, _ y: Double, _ kind: String) {
        let main = kind == "empty" ? "#3a3a3a" : "#c8c8c8"
        let rows = ["##.##", "#####", "#####", ".###."]
        for (ry, row) in rows.enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                cv.setFill(kind == "half" && rx >= 3 ? "#3a3a3a" : main)
                cv.fillRect(x + Double(rx) + 1, y + Double(ry) + 1, 1, 1)
            }
        }
    }
    private func drawBubble(_ cv: UICanvas, _ x: Double, _ y: Double) {
        let rows = [".###.", "#...#", "#...#", ".###."]
        for (ry, row) in rows.enumerated() {
            for (rx, ch) in row.enumerated() where ch == "#" {
                cv.setFill("#6ab8e8")
                cv.fillRect(x + Double(rx) + 1, y + Double(ry) + 1, 1, 1)
            }
        }
    }

    private func drawRPGQuickSlots(_ ui: UIManager, rpg: RPGCharacterState, hotbarX: Double, hotbarY: Double) {
        let cv = ui.cv
        let slots = rpgActionQuickSlotActions(rpg)
        let y = hotbarY - 25
        cv.setFill("rgba(12,12,12,0.68)")
        cv.fillRect(hotbarX, y, 182, 22)
        cv.setStroke("rgba(255,255,255,0.25)")
        cv.strokeRect(hotbarX, y, 182, 22)
        let selected = rpg.selectedPreparedActionID
        var selectedSlot: (index: Int, action: RPGPreparedAction)?
        for i in 0..<RPG_ACTION_QUICK_SLOT_COUNT {
            let sx = hotbarX + 1 + Double(i) * 20
            let action = i < slots.count ? slots[i] : nil
            let isSelected = action?.token == selected
            if let action, isSelected { selectedSlot = (i, action) }
            if let action {
                let fill = isSelected ? "rgba(80,140,230,0.45)" : action.available ? "rgba(70,130,90,0.24)" : "rgba(150,92,48,0.28)"
                cv.setFill(fill)
                cv.fillRect(sx, y + 1, 20, 20)
                cv.drawRPGIcon(action.iconAssetID, sx + 2, y + 2, 16, 16)
                cv.setFill("rgba(0,0,0,0.55)")
                cv.fillRect(sx + 1, y + 12, 9, 8)
                cv.drawText(String(i + 1), sx + 2, y + 13, 1, "#ffffff", shadow: false)
                if action.cooldownRemainingTicks > 0 {
                    cv.setFill("rgba(0,0,0,0.64)")
                    cv.fillRect(sx + 10, y + 12, 10, 8)
                    cv.drawText(fitHUD(action.statusText, maxWidth: 10), sx + 11, y + 13, 1, "#ffc878", shadow: false)
                } else if !action.available {
                    cv.setStroke("#ffb070")
                    cv.strokeRect(sx + 1, y + 1, 18, 18)
                }
            } else {
                cv.setFill("rgba(0,0,0,0.26)")
                cv.fillRect(sx, y + 1, 20, 20)
                cv.drawTextCentered(String(i + 1), sx + 10, y + 8, 1, "#909090", shadow: false)
            }
            if isSelected {
                cv.setStroke("#ffffff")
                cv.strokeRect(sx - 1, y, 22, 22, 2)
            }
        }
        if let selectedSlot {
            let x = hotbarX + 196
            let w = min(128.0, max(0, ui.width - x - 6))
            if w >= 92 {
                cv.setFill("rgba(12,12,12,0.68)")
                cv.fillRect(x, y, w, 22)
                cv.setStroke("rgba(255,255,255,0.25)")
                cv.strokeRect(x, y, w, 22)
                let text = "Slot \(selectedSlot.index + 1) \(selectedSlot.action.displayName)"
                let status = "Fat \(Int(selectedSlot.action.fatigueCost.rounded(.up))) \(selectedSlot.action.statusText)"
                cv.drawText(fitHUD(text, maxWidth: Int(w - 6)), x + 3, y + 3, 1, "#ffffff", shadow: false)
                cv.drawText(fitHUD(status, maxWidth: Int(w - 6)), x + 3, y + 13, 1,
                            selectedSlot.action.available ? "#b8ffb8" : "#ffc878", shadow: false)
            }
        }
    }

    private func fitHUD(_ text: String, maxWidth: Int) -> String {
        guard maxWidth > 0 else { return "" }
        var out = text
        while textWidth(out) > maxWidth && out.count > 3 {
            out.removeLast()
        }
        if out.count < text.count {
            while textWidth(out + "...") > maxWidth && out.count > 1 { out.removeLast() }
            return out + "..."
        }
        return out
    }

    private func drawDebug(_ ui: UIManager, _ game: GameCore) {
        let cv = ui.cv
        guard let p = game.player else { return }
        let world = game.world
        let bx = Int(p.x.rounded(.down)), by = Int(p.y.rounded(.down)), bz = Int(p.z.rounded(.down))
        let biome = BIOMES[world.biomeAt(bx, by, bz)]
        var lines = [
            "Pebble \(PEBBLE_VERSION) (\(debugInfo["fps"] ?? "?") fps, \(debugInfo["chunkUpdates"] ?? "0") chunk updates)",
            "XYZ: \(String(format: "%.3f", p.x)) / \(String(format: "%.4f", p.y)) / \(String(format: "%.3f", p.z))",
            "Block: \(bx) \(by) \(bz)  Chunk: \(bx >> 4) \(bz >> 4)",
            "Facing: \(facingName(p.yaw)) (\(String(format: "%.1f", (p.yaw * 180 / .pi).truncatingRemainder(dividingBy: 360))) / \(String(format: "%.1f", p.pitch * 180 / .pi)))",
            "Biome: \(biome?.name ?? "?")",
            "Light: \(Int(world.lightAt(bx, by, bz))) (\(world.getSkyLight(bx, by, bz)) sky, \(world.getBlockLight(bx, by, bz)) block)",
            "Time: \(world.dayTime) (day \(world.time / 24000))  Weather: \(world.raining ? (world.thundering ? "thunder" : "rain") : "clear")",
            "E: \(world.entities.count)  Sections: \(debugInfo["sections"] ?? "?")  Draw: \(debugInfo["drawCalls"] ?? "?")",
            "Mem: \(debugInfo["mem"] ?? "?")  Seed: \(world.seed)",
        ]
        if let t = game.targetedBlock {
            let def = blockDefs[t.cell >> 4]
            lines.append("Looking at: \(t.x) \(t.y) \(t.z) = \(def.name)#\(t.cell & 15)")
        }
        cv.setFill("rgba(16,16,16,0.4)")
        for (i, line) in lines.enumerated() {
            cv.fillRect(2, 2 + Double(i) * 10, Double(textWidth(line)) + 2, 10)
        }
        for (i, line) in lines.enumerated() {
            cv.drawText(line, 3, 3 + Double(i) * 10, 1, "#e8e8e8", shadow: false)
        }
    }
}

private func facingName(_ yaw: Double) -> String {
    let deg = ((yaw * 180 / .pi).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    if deg >= 315 || deg < 45 { return "south (+Z)" }
    if deg < 135 { return "west (-X)" }
    if deg < 225 { return "north (-Z)" }
    return "east (+X)"
}
