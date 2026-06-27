// UI core — screen stack, cursor item, GUI scaling, MC-style
// panel/slot/button/slider/textfield drawing, and the slot interaction
// framework shared by every container screen. Draws through UICanvas.

import Foundation
import QuartzCore
import PebbleCore

final class SlotDef {
    var x: Double
    var y: Double
    let get: () -> ItemStack?
    let set: (ItemStack?) -> Void
    var canPlace: ((ItemStack) -> Bool)?
    var output = false
    var onTake: ((ItemStack) -> Void)?
    var onChange: (() -> Void)?

    init(x: Double, y: Double, get: @escaping () -> ItemStack?, set: @escaping (ItemStack?) -> Void,
         canPlace: ((ItemStack) -> Bool)? = nil, output: Bool = false,
         onTake: ((ItemStack) -> Void)? = nil, onChange: (() -> Void)? = nil) {
        self.x = x
        self.y = y
        self.get = get
        self.set = set
        self.canPlace = canPlace
        self.output = output
        self.onTake = onTake
        self.onChange = onChange
    }
}

class Button {
    var enabled = true
    var visible = true
    var x: Double, y: Double, w: Double, h: Double
    var label: String
    var onClick: () -> Void

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ label: String, _ onClick: @escaping () -> Void) {
        self.x = x; self.y = y; self.w = w; self.h = h
        self.label = label
        self.onClick = onClick
    }
    func contains(_ mx: Double, _ my: Double) -> Bool {
        visible && enabled && mx >= x && mx < x + w && my >= y && my < y + h
    }
}

final class Slider: Button {
    let getLabel: () -> String
    let getValue: () -> Double
    let setValue: (Double) -> Void
    var dragging = false

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
         _ getLabel: @escaping () -> String, _ getValue: @escaping () -> Double, _ setValue: @escaping (Double) -> Void) {
        self.getLabel = getLabel
        self.getValue = getValue
        self.setValue = setValue
        super.init(x, y, w, h, "", {})
    }
}

final class CheckBox: Button {
    let isChecked: () -> Bool

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ label: String,
         isChecked: @escaping () -> Bool, _ onClick: @escaping () -> Void) {
        self.isChecked = isChecked
        super.init(x, y, w, h, label, onClick)
    }
}

final class TextField {
    var text = ""
    var focused = false
    var caret = 0
    var maxLength = 64
    var x: Double, y: Double, w: Double, h: Double
    var placeholder: String

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ placeholder: String = "") {
        self.x = x; self.y = y; self.w = w; self.h = h
        self.placeholder = placeholder
    }
    func contains(_ mx: Double, _ my: Double) -> Bool {
        mx >= x && mx < x + w && my >= y && my < y + h
    }
    func type(_ ch: String) {
        if text.count < maxLength {
            let i = text.index(text.startIndex, offsetBy: caret)
            text.insert(contentsOf: ch, at: i)
            caret += ch.count
        }
    }
    func backspace() {
        if caret > 0 {
            let i = text.index(text.startIndex, offsetBy: caret - 1)
            text.remove(at: i)
            caret -= 1
        }
    }
}

class Screen {
    var closeOnEsc = true
    var showHUD = false
    var pausesGame = false
    var buttons: [Button] = []
    var sliders: [Slider] = []
    var fields: [TextField] = []
    var slots: [SlotDef] = []

    func initScreen(_ ui: UIManager, _ game: GameCore) {}
    func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {}
    func onClose(_ ui: UIManager, _ game: GameCore) {}

    @discardableResult
    func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        for f in fields { f.focused = f.contains(mx, my) }
        for b in buttons where b.contains(mx, my) {
            game.playUISound("ui.button.click")
            b.onClick()
            return true
        }
        for s in sliders where s.contains(mx, my) {
            s.dragging = true
            s.setValue(max(0, min(1, (mx - s.x - 4) / (s.w - 8))))
            return true
        }
        if let slot = slotAt(mx, my) {
            ui.handleSlotClick(game, self, slot, btn, shift: ui.shiftDown)
            return true
        }
        return false
    }
    func onMouseUp(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        for s in sliders { s.dragging = false }
    }
    func onMouseMove(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        for s in sliders where s.dragging {
            s.setValue(max(0, min(1, (mx - s.x - 4) / (s.w - 8))))
        }
    }
    func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool { false }
    func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        for f in fields where f.focused {
            if key == "Backspace" { f.backspace(); return true }
            if key == "ArrowLeft" { f.caret = max(0, f.caret - 1); return true }
            if key == "ArrowRight" { f.caret = min(f.text.count, f.caret + 1); return true }
        }
        return false
    }
    func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        for f in fields where f.focused {
            f.type(ch)
            return true
        }
        return false
    }
    func slotAt(_ mx: Double, _ my: Double) -> SlotDef? {
        slots.first { mx >= $0.x && mx < $0.x + 18 && my >= $0.y && my < $0.y + 18 }
    }
    /// shift-click routing — override in container screens
    func quickMove(_ game: GameCore, _ slot: SlotDef) {}
}

final class UIManager {
    let cv: UICanvas
    var packUI: PackUI?          // pack GUI sheets (nil = procedural UI)
    var titlePhoto = false       // renderer has a title-bg photo loaded
    var titleLogo = false        // renderer draws the wordmark texture
    var scale = 3.0
    var width = 0.0    // GUI units
    var height = 0.0
    var mouseX = 0.0
    var mouseY = 0.0
    var shiftDown = false
    var cursorStack: ItemStack?
    private var stack: [Screen] = []
    var tooltipLines: [String]?

    init(cv: UICanvas) {
        self.cv = cv
    }

    func resize(_ pw: Double, _ ph: Double, _ guiScaleSetting: Int, relayout game: GameCore? = nil) {
        let auto = max(1.0, min((pw / 380).rounded(.down), (ph / 240).rounded(.down)))
        let newScale = guiScaleSetting == 0 ? auto : min(Double(guiScaleSetting), auto)
        let newWidth = (pw / newScale).rounded(.up)
        let newHeight = (ph / newScale).rounded(.up)
        let changed = newScale != scale || newWidth != width || newHeight != height
        scale = newScale
        width = newWidth
        height = newHeight
        // screens lay widgets out in initScreen against the size at open time —
        // re-run layout for every open screen, carrying typed field state over
        guard changed, let game else { return }
        for s in stack {
            let saved = s.fields.map { ($0.text, $0.caret, $0.focused) }
            s.buttons.removeAll()
            s.sliders.removeAll()
            s.fields.removeAll()
            s.slots.removeAll()
            s.initScreen(self, game)
            for (i, t) in saved.enumerated() where i < s.fields.count {
                s.fields[i].text = t.0
                s.fields[i].caret = min(t.1, t.0.count)
                s.fields[i].focused = t.2
            }
        }
    }

    func open(_ s: Screen, _ game: GameCore) {
        // release held movement/mouse state — keys held when a screen opens
        // never get their keyUp (the screen eats it) and stick otherwise
        if stack.isEmpty { game.clearInput() }
        stack.append(s)
        s.initScreen(self, game)
    }
    func replace(_ s: Screen, _ game: GameCore) {
        closeTop(game)
        open(s, game)
    }
    func closeTop(_ game: GameCore) {
        if let top = stack.popLast() {
            top.onClose(self, game)
        }
        if stack.isEmpty, let c = cursorStack {
            // drop the cursor stack back into player inventory
            _ = game.player?.give(c)
            cursorStack = nil
        }
    }
    func closeAll(_ game: GameCore) {
        while !stack.isEmpty { closeTop(game) }
    }
    func current() -> Screen? { stack.last }
    func hasScreen() -> Bool { !stack.isEmpty }

    // ---- frame ----------------------------------------------------------------
    func beginFrame() {
        // canvas in GUI units; the flush uniform needs the pixel framebuffer size
        cv.begin(width * scale, height * scale)
        cv.scale(scale, scale)
        tooltipLines = nil
    }
    func endFrame() {
        if let c = cursorStack {
            drawItemStack(c, mouseX - 8, mouseY - 8)
        }
        if let lines = tooltipLines, !lines.isEmpty {
            drawTooltipBox(lines, mouseX + 6, mouseY - 6)
        }
    }

    // ---- pack GUI sheets ----------------------------------------------------------
    func hasSheet(_ s: String) -> Bool { packUI?.sheets.contains(s) ?? false }

    /// blit a base-px region of a pack GUI sheet (sheet content is stored at 2×);
    /// returns false when the sheet isn't loaded so callers can fall back
    @discardableResult
    func blitSheet(_ sheet: String, _ sx: Double, _ sy: Double, _ sw: Double, _ sh: Double,
                   _ dx: Double, _ dy: Double, _ dw: Double? = nil, _ dh: Double? = nil,
                   tint: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)) -> Bool {
        guard let p = packUI, p.sheets.contains(sheet), let cell = PackUI.CELLS[sheet] else { return false }
        cv.guiQuad(Double(cell.0) + sx * 2, Double(cell.1) + sy * 2, sw * 2, sh * 2,
                   dx, dy, dw ?? sw, dh ?? sh, tint)
        return true
    }

    // ---- drawing helpers --------------------------------------------------------
    func drawPanel(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        cv.setFill("#c6c6c6")
        cv.fillRect(x + 1, y + 1, w - 2, h - 2)
        cv.setFill("#ffffff")
        cv.fillRect(x + 1, y, w - 2, 1)
        cv.fillRect(x, y + 1, 1, h - 2)
        cv.setFill("#555555")
        cv.fillRect(x + 1, y + h - 1, w - 2, 1)
        cv.fillRect(x + w - 1, y + 1, 1, h - 2)
        cv.setFill("#000000")
        cv.fillRect(x + 2, y - 1, w - 4, 1)
        cv.fillRect(x + 2, y + h, w - 4, 1)
        cv.fillRect(x - 1, y + 2, 1, h - 4)
        cv.fillRect(x + w, y + 2, 1, h - 4)
    }
    func drawSlotBg(_ x: Double, _ y: Double) {
        cv.setFill("#8b8b8b")
        cv.fillRect(x, y, 18, 18)
        cv.setFill("#373737")
        cv.fillRect(x, y, 17, 1)
        cv.fillRect(x, y, 1, 17)
        cv.setFill("#ffffff")
        cv.fillRect(x + 1, y + 17, 17, 1)
        cv.fillRect(x + 17, y + 1, 1, 17)
    }
    func drawItemStack(_ s: ItemStack, _ x: Double, _ y: Double) {
        cv.drawItemIcon(s.id, s.data, x + 1, y + 1, 16, 16)
        // enchant glint
        if !s.ench.isEmpty || itemDef(s.id).name == "enchanted_golden_apple" {
            cv.setFill("rgba(160,80,255,0.22)")
            cv.fillRect(x + 1, y + 1, 16, 16)
        }
        // durability bar
        let maxD = itemDef(s.id).tool?.durability ?? itemDef(s.id).armor?.durability ?? 0
        if maxD > 0 && s.damage > 0 {
            let f = 1 - Double(s.damage) / Double(maxD)
            cv.setFill("#000000")
            cv.fillRect(x + 2, y + 15, 14, 2)
            cv.setFill(f > 0.5 ? "#40c040" : f > 0.25 ? "#e8d83c" : "#e84040")
            cv.fillRect(x + 2, y + 15, max(1, (14 * f).rounded()), 1)
        }
        if s.count > 1 {
            cv.drawText(String(s.count), x + 18 - Double(textWidth(String(s.count))) - 1, y + 10, 1)
        }
    }
    func drawSlot(_ s: SlotDef, _ hover: Bool, slotBg: Bool = true) {
        if slotBg { drawSlotBg(s.x, s.y) }
        let stack = s.get()
        if let stack { drawItemStack(stack, s.x, s.y) }
        if hover {
            cv.setFill("rgba(255,255,255,0.45)")
            cv.fillRect(s.x + 1, s.y + 1, 16, 16)
            if let stack { tooltipLines = itemTooltip(stack) }
        }
    }
    func drawSlots(_ screen: Screen, slotBg: Bool = true) {
        for s in screen.slots {
            let hover = mouseX >= s.x && mouseX < s.x + 18 && mouseY >= s.y && mouseY < s.y + 18
            drawSlot(s, hover, slotBg: slotBg)
        }
    }
    func drawButton(_ b: Button, _ hover: Bool) {
        if !b.visible { return }
        if let cb = b as? CheckBox {
            let box = 10.0
            let by = b.y + ((b.h - box) / 2).rounded(.down)
            cv.setFill(hover ? "#d8d8d8" : "#c6c6c6")
            cv.fillRect(b.x, by, box, box)
            cv.setFill("#373737")
            cv.fillRect(b.x, by, box, 1)
            cv.fillRect(b.x, by, 1, box)
            cv.setFill("#ffffff")
            cv.fillRect(b.x + 1, by + box - 1, box - 1, 1)
            cv.fillRect(b.x + box - 1, by + 1, 1, box - 1)
            if cb.isChecked() {
                cv.drawText("x", b.x + 2, by + 1, 1, "#202020", shadow: false)
            }
            cv.drawText(cb.label, b.x + box + 4, b.y + ((b.h - 8) / 2).rounded(.down), 1,
                        hover ? "#ffffff" : "#e0e0e0")
            return
        }
        // vanilla widgets.png strips: 46 disabled / 66 normal / 86 hover, 200×20,
        // blitted as left+right halves so any width keeps both end caps
        if b.w <= 200, hasSheet("widgets") {
            let sy = b.enabled ? (hover ? 86.0 : 66.0) : 46.0
            let half = (b.w / 2).rounded(.down)
            blitSheet("widgets", 0, sy, half, 20, b.x, b.y, half, b.h)
            blitSheet("widgets", 200 - (b.w - half), sy, b.w - half, 20, b.x + half, b.y, b.w - half, b.h)
            cv.drawTextCentered(b.label, b.x + b.w / 2, b.y + (b.h - 8) / 2, 1, b.enabled ? "#ffffff" : "#a0a0a0")
            return
        }
        cv.setFill(b.enabled ? (hover ? "#7a8cbf" : "#6f6f6f") : "#3f3f3f")
        cv.fillRect(b.x, b.y, b.w, b.h)
        cv.setFill(b.enabled ? (hover ? "#aab8e0" : "#a0a0a0") : "#555555")
        cv.fillRect(b.x, b.y, b.w, 1)
        cv.fillRect(b.x, b.y, 1, b.h)
        cv.setFill("#2a2a2a")
        cv.fillRect(b.x, b.y + b.h - 1, b.w, 1)
        cv.fillRect(b.x + b.w - 1, b.y, 1, b.h)
        cv.drawTextCentered(b.label, b.x + b.w / 2, b.y + (b.h - 8) / 2, 1, b.enabled ? "#ffffff" : "#a0a0a0")
    }
    func drawButtons(_ screen: Screen) {
        for b in screen.buttons where !(b is Slider) {
            drawButton(b, b.contains(mouseX, mouseY))
        }
        for s in screen.sliders {
            if s.w <= 200, hasSheet("widgets") {
                // vanilla slider: disabled-strip track + 8px handle
                let half = (s.w / 2).rounded(.down)
                blitSheet("widgets", 0, 46, half, 20, s.x, s.y, half, s.h)
                blitSheet("widgets", 200 - (s.w - half), 46, s.w - half, 20, s.x + half, s.y, s.w - half, s.h)
                let v = s.getValue()
                let hx = (s.x + v * (s.w - 8)).rounded()
                let hover = s.contains(mouseX, mouseY) || s.dragging
                blitSheet("widgets", 0, hover ? 86 : 66, 4, 20, hx, s.y, 4, s.h)
                blitSheet("widgets", 196, hover ? 86 : 66, 4, 20, hx + 4, s.y, 4, s.h)
                cv.drawTextCentered(s.getLabel(), s.x + s.w / 2, s.y + (s.h - 8) / 2, 1)
                continue
            }
            cv.setFill("#3f3f3f")
            cv.fillRect(s.x, s.y, s.w, s.h)
            cv.setFill("#1c1c1c")
            cv.fillRect(s.x, s.y, s.w, 1)
            let v = s.getValue()
            let hx = s.x + 2 + v * (s.w - 10)
            cv.setFill("#8a8a8a")
            cv.fillRect(hx, s.y + 1, 6, s.h - 2)
            cv.setFill("#c8c8c8")
            cv.fillRect(hx, s.y + 1, 6, 2)
            cv.drawTextCentered(s.getLabel(), s.x + s.w / 2, s.y + (s.h - 8) / 2, 1)
        }
        for f in screen.fields {
            cv.setFill("#000000")
            cv.fillRect(f.x, f.y, f.w, f.h)
            cv.setStroke(f.focused ? "#ffffff" : "#a0a0a0")
            cv.strokeRect(f.x, f.y, f.w, f.h)
            cv.drawText(f.text, f.x + 4, f.y + (f.h - 8) / 2, 1, f.text.isEmpty ? "#707070" : "#ffffff")
            if f.text.isEmpty && !f.placeholder.isEmpty {
                cv.drawText(f.placeholder, f.x + 4, f.y + (f.h - 8) / 2, 1, "#5a5a5a")
            }
            if f.focused && Int(CACurrentMediaTime() * 1000 / 400) % 2 == 0 {
                let cx = f.x + 4 + Double(textWidth(String(f.text.prefix(f.caret))))
                cv.setFill("#ffffff")
                cv.fillRect(cx, f.y + 3, 1, f.h - 6)
            }
        }
    }
    func drawDarkBg(_ alpha: Double = 0.6) {
        cv.setFill("rgba(8,8,12,\(alpha))")
        cv.fillRect(0, 0, width, height)
    }
    func drawDirtBg() {
        if hasSheet("bg") {
            // vanilla options background: 16px texture tiled every 32 GUI px, ×0.25 tint
            let tint = SIMD4<Float>(0.25, 0.25, 0.25, 1)
            var y = 0.0
            while y < height {
                var x = 0.0
                while x < width {
                    blitSheet("bg", 0, 0, 16, 16, x, y, 32, 32, tint: tint)
                    x += 32
                }
                y += 32
            }
            return
        }
        cv.setFill("#3a2a1e")
        cv.fillRect(0, 0, width, height)
        var y = 0.0
        while y < height {
            var x = 0.0
            while x < width {
                let xi = Int(x), yi = Int(y)
                let h = ((xi * 31 + yi * 17) ^ (xi >> 3)) & 255
                cv.setFill(h < 60 ? "#33241a" : h < 120 ? "#403021" : h < 200 ? "#382a1d" : "#443325")
                cv.fillRect(x, y, 4, 4)
                x += 4
            }
            y += 4
        }
        cv.setFill("rgba(0,0,0,0.45)")
        cv.fillRect(0, 0, width, height)
    }
    func drawTooltipBox(_ lines: [String], _ xIn: Double, _ yIn: Double) {
        var w = 0.0
        for l in lines { w = max(w, Double(textWidth(l))) }
        let h = Double(lines.count) * 10 + 6
        let x = min(xIn, width - w - 10)
        let y = max(4, min(yIn, height - h - 4))
        cv.setFill("rgba(16,0,16,0.94)")
        cv.fillRect(x, y, w + 8, h)
        cv.setStroke("rgba(80,0,255,0.45)")
        cv.strokeRect(x, y, w + 8, h)
        for (i, line) in lines.enumerated() {
            cv.drawText(line, x + 4, y + 4 + Double(i) * 10, 1)
        }
    }
    func itemTooltip(_ s: ItemStack) -> [String] {
        let def = itemDef(s.id)
        var lines: [String] = []
        let rarityColor = ["§f", "§e", "§b", "§d"][min(3, max(0, def.rarity))]
        lines.append(rarityColor + (s.label ?? def.displayName))
        if def.name == "potion" || def.name == "splash_potion" || def.name == "lingering_potion" || def.name == "tipped_arrow" {
            let pot = potionDef(s.data.potion ?? "water")
            for e in pot.effects {
                let ed = effectDef(e.effect)
                let mins = e.duration / 1200
                let secs = (e.duration % 1200) / 20
                var line = (ed.beneficial ? "§9" : "§c") + ed.displayName
                if e.amplifier > 0 { line += " " + ["I", "II", "III", "IV", "V"][min(4, e.amplifier)] }
                if e.duration > 1 { line += " (\(mins):\(String(format: "%02d", secs)))" }
                lines.append(line)
            }
            if pot.effects.isEmpty { lines.append("§7No Effects") }
        }
        for e in s.ench {
            let ed = enchDef(e.id)
            lines.append("§7" + ed.displayName + (ed.maxLevel > 1 ? " " + ["I", "II", "III", "IV", "V"][min(4, e.lvl - 1)] : ""))
        }
        if let trim = s.data.trim {
            lines.append("§7Trim: " + trim.pattern + " (" + trim.material.replacingOccurrences(of: "_", with: " ") + ")")
        }
        if let food = def.food {
            lines.append("§2+\(food.hunger) hunger")
        }
        let maxD = def.tool?.durability ?? def.armor?.durability ?? 0
        if maxD > 0 { lines.append("§7Durability: \(maxD - s.damage) / \(maxD)") }
        return lines
    }

    // ---- slot interaction ---------------------------------------------------------
    /// shift-click on an output slot: every take must run onTake (it consumes
    /// the crafting grid / grants furnace XP / counts trade uses), and a take
    /// is all-or-nothing — never insert a partial result with inputs unspent
    private func quickMoveOutput(_ screen: Screen, _ slot: SlotDef) {
        let targets = (screen as? ContainerScreen)?.playerSlots ?? []
        if targets.isEmpty { return }
        var rounds = 0
        while let s = slot.get(), s.count > 0, rounds < 64 {
            guard canFullyInsert(s, targets) else { break }
            let taken = copyStack(s)!
            _ = quickMoveInto(taken, targets)
            slot.onTake?(s)
            rounds += 1
            // defensive: a slot whose onTake doesn't refresh its source would
            // hand out the same stack forever
            if let again = slot.get(), again === s { break }
        }
    }

    func handleSlotClick(_ game: GameCore, _ screen: Screen, _ slot: SlotDef, _ btn: Int, shift: Bool = false) {
        let inSlot = slot.get()
        let cursor = cursorStack
        if shift {
            if inSlot != nil {
                if slot.output {
                    quickMoveOutput(screen, slot)
                } else {
                    screen.quickMove(game, slot)
                }
                slot.onChange?()
            }
            return
        }
        if slot.output {
            // take only (all)
            if let inSlot, cursor == nil || (canMerge(cursor!, inSlot) && cursor!.count + inSlot.count <= maxStackOf(cursor!)) {
                if let cursor {
                    cursor.count += inSlot.count
                } else {
                    cursorStack = copyStack(inSlot)
                }
                slot.onTake?(inSlot)
                slot.onChange?()
            }
            return
        }
        if btn == 0 {
            if let cursor, let inSlot, canMerge(cursor, inSlot) {
                let space = maxStackOf(inSlot) - inSlot.count
                let move = min(space, cursor.count)
                inSlot.count += move
                cursor.count -= move
                if cursor.count <= 0 { cursorStack = nil }
            } else if let cursor {
                if slot.canPlace?(cursor) ?? true {
                    slot.set(cursor)
                    cursorStack = inSlot
                }
            } else if let inSlot {
                cursorStack = inSlot
                slot.set(nil)
            }
        } else if btn == 2 {
            // right click
            if let cursor {
                if inSlot == nil && (slot.canPlace?(cursor) ?? true) {
                    let one = copyStack(cursor)!
                    one.count = 1
                    slot.set(one)
                    cursor.count -= 1
                    if cursor.count <= 0 { cursorStack = nil }
                } else if let inSlot, canMerge(cursor, inSlot), inSlot.count < maxStackOf(inSlot) {
                    inSlot.count += 1
                    cursor.count -= 1
                    if cursor.count <= 0 { cursorStack = nil }
                }
            } else if let inSlot {
                let half = (inSlot.count + 1) / 2
                let taken = copyStack(inSlot)!
                taken.count = half
                cursorStack = taken
                inSlot.count -= half
                if inSlot.count <= 0 { slot.set(nil) }
            }
        }
        slot.onChange?()
    }
}

/// standard player inventory slots (27 main + 9 hotbar) at panel-local coords
func playerInvSlots(_ player: Player, _ px: Double, _ py: Double) -> [SlotDef] {
    var out: [SlotDef] = []
    for row in 0..<3 {
        for col in 0..<9 {
            let idx = 9 + row * 9 + col
            out.append(SlotDef(
                x: px + Double(col) * 18, y: py + Double(row) * 18,
                get: { player.inventory[idx] },
                set: { player.inventory[idx] = $0 }))
        }
    }
    for col in 0..<9 {
        let idx = col
        out.append(SlotDef(
            x: px + Double(col) * 18, y: py + 58,
            get: { player.inventory[idx] },
            set: { player.inventory[idx] = $0 }))
    }
    return out
}

/// shift-move a stack into a list of slots (merge then empty)
@discardableResult
/// true if `stack` fits entirely into `targets` (merge space + empty slots) —
/// checked before quickMoveInto when a partial insert must not happen
func canFullyInsert(_ stack: ItemStack, _ targets: [SlotDef]) -> Bool {
    var remaining = stack.count
    for t in targets {
        if let ts = t.get(), canMerge(ts, stack) {
            remaining -= maxStackOf(ts) - ts.count
            if remaining <= 0 { return true }
        }
    }
    for t in targets where t.get() == nil && (t.canPlace?(stack) ?? true) {
        remaining -= maxStackOf(stack)
        if remaining <= 0 { return true }
    }
    return remaining <= 0
}

func quickMoveInto(_ stack: ItemStack, _ targets: [SlotDef]) -> Bool {
    for t in targets {
        if let ts = t.get(), canMerge(ts, stack) {
            let space = maxStackOf(ts) - ts.count
            let move = min(space, stack.count)
            ts.count += move
            stack.count -= move
            if stack.count <= 0 { return true }
        }
    }
    for t in targets {
        if t.get() == nil && (t.canPlace?(stack) ?? true) {
            t.set(copyStack(stack))
            stack.count = 0
            return true
        }
    }
    return stack.count <= 0
}
