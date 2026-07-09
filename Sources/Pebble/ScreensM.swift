// Gameplay screens — inventory, crafting, furnace,
// chest, brewing, enchanting, anvil, grindstone, stonecutter, smithing,
// beacon, trading, creative, sign, death, chat. Same layouts and slot logic.

import Foundation
import QuartzCore
import PebbleCore

private enum CraftAmountStepperLayout {
    static let buttonW = 12.0
    static let buttonH = 8.0
    static let gap = 2.0
    static let outputGap = 3.0

    static func frames(outputX: Double, outputY: Double) -> (up: (x: Double, y: Double, w: Double, h: Double),
                                                            down: (x: Double, y: Double, w: Double, h: Double)) {
        let x = outputX + 18 + outputGap
        return (
            up: (x, outputY, buttonW, buttonH),
            down: (x, outputY + buttonH + gap, buttonW, buttonH)
        )
    }
}

// =============================================================================
// Base container screen with player inventory
// =============================================================================
class ContainerScreen: Screen {
    var panelX = 0.0
    var panelY = 0.0
    var panelW = 176.0
    var panelH = 166.0
    var title = ""
    var titleX = 8.0              // panel-local title position (vanilla titleLabelX/Y)
    var titleY = 6.0
    var showInvLabel = true       // vanilla hides "Inventory" on the survival inventory
    var sheet: String?            // pack GUI container texture key (nil = procedural panel)
    var playerSlots: [SlotDef] = []
    var containerSlots: [SlotDef] = []
    /// y of the player inventory slot grid, panel-local (vanilla: imageHeight−83/−84)
    var playerInvY: Double { panelH - 83 }
    /// true when this frame's panel came from the pack texture (slot bgs baked in)
    private(set) var textured = false
    /// LAN client container-edit capture (D-C, §7.10): the block entity this screen mirrors, if
    /// any (chest/furnace/brewing/crafting subclasses assign this in `init`). `onClose` fires a
    /// final capture; `draw` fires a ≤5 Hz debounced capture while the screen stays open so a
    /// guest's edit reaches the host without waiting for the screen to close.
    var lanEditBE: BlockEntityData?
    var lanEditBEs: [BlockEntityData] = []
    private var lanLastCaptureTime = 0.0
    private var lanLastCapturedFingerprint: [Int]?
    private let lanCaptureInterval = 0.2 // 5 Hz

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        panelX = ((ui.width - panelW) / 2).rounded(.down)
        panelY = ((ui.height - panelH) / 2).rounded(.down)
        playerSlots = playerInvSlots(game.player, panelX + 7, panelY + playerInvY)
        buildSlots(ui, game)
        slots = containerSlots + playerSlots
    }
    func buildSlots(_ ui: UIManager, _ game: GameCore) {}

    /// draw the panel from the pack sheet; subclasses override for multi-piece blits
    func drawSheetPanel(_ ui: UIManager) -> Bool {
        guard let sheet else { return false }
        return ui.blitSheet(sheet, 0, 0, panelW, panelH, panelX, panelY)
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.55)
        textured = drawSheetPanel(ui)
        if !textured { ui.drawPanel(panelX, panelY, panelW, panelH) }
        ui.cv.drawText(title, panelX + titleX, panelY + titleY, 1, "#3f3f3f", shadow: false)
        if showInvLabel {
            ui.cv.drawText("Inventory", panelX + 8, panelY + playerInvY - 10, 1, "#3f3f3f", shadow: false)
        }
        drawExtra(ui, game)
        ui.drawSlots(self, slotBg: !textured)
        ui.drawButtons(self)
        tickLANContainerEditFlush(game)
    }
    func drawExtra(_ ui: UIManager, _ game: GameCore) {}

    /// ≤5 Hz debounced capture while the screen is open: only sends when a cheap fingerprint
    /// (slot ids/counts) of the mirrored BE actually changed since the last capture, so idle
    /// screens produce no traffic.
    private func tickLANContainerEditFlush(_ game: GameCore) {
        let editBEs = lanEditBEs.isEmpty ? [lanEditBE].compactMap { $0 } : lanEditBEs
        guard game.isLANClientWorld, let be = editBEs.first else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - lanLastCaptureTime >= lanCaptureInterval else { return }
        let fingerprint = editBEs.flatMap { be -> [Int] in
            [be.x, be.y, be.z] + (be.items ?? []).flatMap { stack -> [Int] in
                guard let stack else { return [0, 0] }
                return [stack.id + 1, stack.count]
            }
        }
        guard fingerprint != lanLastCapturedFingerprint else { return }
        lanLastCaptureTime = now
        lanLastCapturedFingerprint = fingerprint
        game.captureLANContainerEdit(be, additional: Array(editBEs.dropFirst()))
    }

    /// Final container-edit capture on close (D-C): gated inside `GameCore.gameScreenWillClose`
    /// on `isLANClientWorld`, so this is a harmless no-op in singleplayer/hosting.
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let cursor = ui.cursorStack {
            _ = game.player?.give(cursor)
            ui.cursorStack = nil
        }
        let editBEs = lanEditBEs.isEmpty ? [lanEditBE].compactMap { $0 } : lanEditBEs
        if editBEs.isEmpty {
            game.gameScreenWillClose(be: lanEditBE)
        } else {
            game.gameScreenWillClose(blockEntities: editBEs)
        }
    }

    override func quickMove(_ game: GameCore, _ slot: SlotDef) {
        guard let s = slot.get() else { return }
        let fromContainer = containerSlots.contains { $0 === slot }
        let targets = fromContainer ? playerSlots : containerSlots.filter { !$0.output }
        if quickMoveInto(s, targets) {
            if s.count <= 0 { slot.set(nil) }
        }
        if s.count <= 0 { slot.set(nil) }
        slot.onChange?()
    }
}

// =============================================================================
// Inventory (survival) — 2×2 crafting + armor + offhand
// =============================================================================
private final class CraftingRecipePopup {
    private(set) var plans: [CraftingRecipePlan] = []
    var open = false
    private var typeahead = CraftingRecipeTypeahead(maxRows: 8, maxQueryLength: 48)
    private weak var button: Button?
    private let gridWidth: Int
    private let gridHeight: Int
    private let menuW = 136.0
    private let rowH = 18.0
    private let margin = 4.0
    private let buttonH = 18.0
    private let searchH = 12.0

    init(gridWidth: Int, gridHeight: Int) {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
    }

    func installButton(on screen: Screen, action: @escaping () -> Void) {
        let button = Button(margin, margin, menuW, buttonH, "Recipes", action)
        self.button = button
        screen.buttons.append(button)
    }

    func layout(_ ui: UIManager) {
        let w = min(menuW, max(96.0, ui.width - margin * 2))
        button?.x = margin
        button?.y = margin
        button?.w = w
        button?.h = buttonH
    }

    func refresh(_ game: GameCore, craftGrid: [ItemStack?], creative: Bool = false, resources: [ItemStack?]? = nil) {
        if creative {
            plans = creativeCraftingPlans(gridWidth: gridWidth, gridHeight: gridHeight)
        } else {
            let available = resources ?? (game.player.inventory + craftGrid)
            plans = craftingPlans(for: available, gridWidth: gridWidth, gridHeight: gridHeight)
        }
        button?.label = plans.isEmpty ? "No recipes" : "Recipes (\(plans.count))"
        typeahead.refresh(plans: plans)
    }

    func toggle() {
        if open {
            close()
        } else {
            open = true
            typeahead.open(plans: plans)
        }
    }

    func close() {
        open = false
        typeahead.close()
    }

    func selectedPlan(at mx: Double, _ my: Double) -> CraftingRecipePlan? {
        guard open, !plans.isEmpty else { return nil }
        let rows = min(typeahead.maxRows, plans.count)
        guard mx >= x && mx < x + w && my >= listY && my < listY + Double(rows) * rowH else { return nil }
        let idx = typeahead.scroll + Int((my - listY) / rowH)
        return idx >= 0 && idx < plans.count ? plans[idx] : nil
    }

    func closeIfOpenOutsideButton(_ mx: Double, _ my: Double) {
        if open, !(button?.contains(mx, my) ?? false) {
            close()
        }
    }

    func draw(_ ui: UIManager) {
        guard open else { return }
        let cv = ui.cv
        if plans.isEmpty {
            ui.drawPanel(x, y, w, 20)
            cv.drawText("No craftable items", x + 6, y + 6, 1, "#3f3f3f", shadow: false)
            return
        }
        let rows = min(typeahead.maxRows, plans.count)
        let headerH = typeahead.query.isEmpty ? 0 : searchH
        ui.drawPanel(x, y, w, headerH + Double(rows) * rowH + 2)
        if !typeahead.query.isEmpty {
            cv.setFill("#d0d0d0")
            cv.fillRect(x + 1, y + 1, w - 2, searchH)
            cv.drawText(searchLabel(), x + 5, y + 3, 1, "#303030", shadow: false)
        }
        for row in 0..<rows {
            let idx = typeahead.scroll + row
            let ry = listY + 1 + Double(row) * rowH
            let hover = ui.mouseX >= x && ui.mouseX < x + w && ui.mouseY >= ry && ui.mouseY < ry + rowH
            let selected = idx == typeahead.highlightedIndex
            cv.setFill(selected ? "#6f7dff" : hover ? "#8a8aff" : (row % 2 == 0 ? "#b8b8b8" : "#ababab"))
            cv.fillRect(x + 1, ry, w - 2, rowH)
            let stack = plans[idx].output
            cv.drawItemIcon(stack.id, stack.data, x + 3, ry + 1, 16, 16)
            cv.drawText(label(for: stack), x + 23, ry + 5, 1, (hover || selected) ? "#ffffff" : "#303030", shadow: false)
        }
        if plans.count > rows {
            cv.setFill("#555555")
            let trackH = Double(rows) * rowH
            cv.fillRect(x + w - 5, listY + 2, 3, trackH - 2)
            let maxScroll = max(1, plans.count - rows)
            let thumbH = max(8, (trackH - 4) * Double(rows) / Double(plans.count))
            let thumbY = listY + 3 + (trackH - thumbH - 4) * Double(typeahead.scroll) / Double(maxScroll)
            cv.setFill("#f0f0f0")
            cv.fillRect(x + w - 5, thumbY, 3, thumbH)
        }
    }

    func onWheel(_ dy: Double) -> Bool {
        guard open, plans.count > typeahead.maxRows else { return false }
        let delta = dy > 0 ? 1 : -1
        typeahead.scrollRows(delta, plans: plans)
        return true
    }

    func onKey(_ key: String) -> (handled: Bool, plan: CraftingRecipePlan?) {
        guard open else { return (false, nil) }
        switch key {
        case "Enter", "NumpadEnter":
            return (true, typeahead.selectedPlan(in: plans))
        case "Backspace", "Delete":
            typeahead.deleteBackward(plans: plans)
            return (true, nil)
        case "ArrowDown":
            typeahead.moveHighlight(1, plans: plans)
            return (true, nil)
        case "ArrowUp":
            typeahead.moveHighlight(-1, plans: plans)
            return (true, nil)
        default:
            return (false, nil)
        }
    }

    func onChar(_ text: String) -> Bool {
        guard open else { return false }
        return typeahead.append(text, plans: plans)
    }

    private var x: Double { button?.x ?? margin }
    private var y: Double { (button?.y ?? margin) + buttonH + 2 }
    private var w: Double { button?.w ?? menuW }
    private var listY: Double { y + (typeahead.query.isEmpty ? 0 : searchH) }

    private func label(for stack: ItemStack) -> String {
        let def = itemDef(stack.id)
        let suffix = stack.count > 1 ? " x\(stack.count)" : ""
        var text = def.displayName + suffix
        while textWidth(text) > Int(w - 28), text.count > 3 {
            text.removeLast()
        }
        return text
    }

    private func searchLabel() -> String {
        var body = typeahead.query
        var clipped = false
        while textWidth("> " + (clipped ? "..." : "") + body) > Int(w - 10), body.count > 1 {
            body.removeFirst()
            clipped = true
        }
        return "> " + (clipped ? "..." : "") + body
    }
}

final class InventoryScreen: ContainerScreen {
    var craftGrid: [ItemStack?] = [nil, nil, nil, nil]
    var craftResult: ItemStack?
    private let recipeMenu = CraftingRecipePopup(gridWidth: 2, gridHeight: 2)
    private var creativeCrafting = false
    private var selectedCreativePlan: CraftingRecipePlan?
    private var selectedSurvivalPlan: CraftingRecipePlan?
    private var selectedCraftRounds = 1
    private weak var creativeCheckbox: CheckBox?
    private weak var craftUpButton: Button?
    private weak var craftDownButton: Button?
    private weak var characterButton: Button?

    override init() {
        super.init()
        title = "Crafting"
        titleX = 97
        titleY = 8
        showInvLabel = false
        sheet = "inventory"
    }
    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let p = game.player!
        syncCreativeFromPlayer(game)
        let px = panelX, py = panelY
        for i in 0..<4 {
            let idx = i
            containerSlots.append(SlotDef(
                x: px + 7, y: py + 7 + Double(i) * 18,
                get: { p.armor[idx] },
                set: { p.armor[idx] = $0 },
                canPlace: { itemDef($0.id).armor?.slot == idx }))
        }
        containerSlots.append(SlotDef(
            x: px + 76, y: py + 61,
            get: { p.offHand },
            set: { p.offHand = $0 }))
        for i in 0..<4 {
            let idx = i
            containerSlots.append(SlotDef(
                x: px + 97 + Double(i % 2) * 18, y: py + 18 + Double(i / 2) * 18,
                get: { [weak self] in self?.craftGrid[idx] },
                set: { [weak self, weak game] s in
                    self?.selectedSurvivalPlan = nil
                    self?.selectedCraftRounds = 1
                    self?.craftGrid[idx] = s
                    self?.updateResult(game)
                },
                onChange: { [weak self, weak game] in
                    self?.selectedSurvivalPlan = nil
                    self?.selectedCraftRounds = 1
                    self?.updateResult(game)
                }))
        }
        containerSlots.append(SlotDef(
            x: px + 153, y: py + 27,
            get: { [weak self] in self?.craftResult },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                guard let self, let game else { return }
                self.takeCraftingOutput(game)
            },
            repeatsOutputQuickMove: { [weak self] in
                (self?.selectedCraftRounds ?? 1) <= 1
            }))
        installCraftAmountButtons(outputX: px + 153, outputY: py + 27, game)
        recipeMenu.installButton(on: self) { [weak self] in
            self?.recipeMenu.toggle()
        }
        let cb = CheckBox(148, 4, 82, 18, "Creative", isChecked: { [weak self] in
            self?.creativeCrafting ?? false
        }, { [weak self, weak game] in
            guard let self else { return }
            self.creativeCrafting = !self.creativeCrafting
            game?.player.setGameMode(self.creativeCrafting ? GameMode.creative : GameMode.survival)
            self.selectedCreativePlan = nil
            self.selectedSurvivalPlan = nil
            self.selectedCraftRounds = 1
            self.updateResult(game)
            if let game { self.recipeMenu.refresh(game, craftGrid: self.craftGrid, creative: self.creativeCrafting) }
        })
        creativeCheckbox = cb
        buttons.append(cb)
        if p.rpgClassesEnabled() {
            let character = Button(236, 4, 86, 18, "Character", { [weak ui, weak game] in
                guard let ui, let game else { return }
                ui.open(RPGCharacterScreen(), game)
            })
            characterButton = character
            buttons.append(character)
        }
    }
    private func installCraftAmountButtons(outputX: Double, outputY: Double, _ game: GameCore) {
        let frames = CraftAmountStepperLayout.frames(outputX: outputX, outputY: outputY)
        let up = CraftAmountButton(frames.up.x, frames.up.y, frames.up.w, frames.up.h, direction: .up) { [weak self, weak game] in
            guard let self, let game else { return }
            self.adjustCraftRounds(1, game)
        }
        let down = CraftAmountButton(frames.down.x, frames.down.y, frames.down.w, frames.down.h, direction: .down) { [weak self, weak game] in
            guard let self, let game else { return }
            self.adjustCraftRounds(-1, game)
        }
        craftUpButton = up
        craftDownButton = down
        buttons.append(up)
        buttons.append(down)
    }
    private func activeSurvivalPlan() -> CraftingRecipePlan? {
        selectedSurvivalPlan ?? currentCraftingPlan(from: craftGrid, gridWidth: 2, gridHeight: 2)
    }
    private func activeCraftingPlan() -> CraftingRecipePlan? {
        creativeCrafting ? selectedCreativePlan : activeSurvivalPlan()
    }
    private func availableCraftRounds(_ game: GameCore) -> Int {
        guard let plan = activeCraftingPlan() else { return 0 }
        if creativeCrafting {
            return max(1, maxCreativeCraftingRounds(plan, into: game.player.inventory))
        }
        return maxCraftingRounds(plan, from: game.player.inventory + craftGrid)
    }
    private func clampCraftRounds(_ game: GameCore) -> Int {
        let maxRounds = availableCraftRounds(game)
        guard maxRounds > 0 else {
            selectedCraftRounds = 1
            return 0
        }
        selectedCraftRounds = min(max(1, selectedCraftRounds), maxRounds)
        return maxRounds
    }
    private func updateCraftRoundButtons(_ game: GameCore) {
        let maxRounds = clampCraftRounds(game)
        let hasOutput = activeCraftingPlan() != nil && maxRounds > 0
        craftUpButton?.visible = hasOutput
        craftDownButton?.visible = hasOutput
        craftUpButton?.enabled = hasOutput && selectedCraftRounds < maxRounds
        craftDownButton?.enabled = hasOutput && selectedCraftRounds > 1
    }
    private func adjustCraftRounds(_ delta: Int, _ game: GameCore) {
        syncCreativeFromPlayer(game)
        let maxRounds = max(0, availableCraftRounds(game))
        guard maxRounds > 0 else {
            selectedCraftRounds = 1
            updateResult(game)
            return
        }
        selectedCraftRounds = min(max(1, selectedCraftRounds + delta), maxRounds)
        updateResult(game)
        updateCraftRoundButtons(game)
    }
    func updateResult(_ game: GameCore? = nil) {
        if let game, clampCraftRounds(game) == 0 {
            craftResult = nil
            return
        }
        guard let plan = activeCraftingPlan() else {
            craftResult = nil
            selectedCraftRounds = 1
            return
        }
        let out = plan.output.copy()
        out.count = max(1, selectedCraftRounds) * max(1, plan.output.count)
        craftResult = out
    }
    private func returnCraftGridToInventory(_ game: GameCore) -> Bool {
        var ok = true
        for i in craftGrid.indices {
            guard let stack = craftGrid[i] else { continue }
            if game.player.give(stack) || stack.count <= 0 {
                craftGrid[i] = nil
            } else {
                ok = false
            }
        }
        selectedSurvivalPlan = nil
        selectedCraftRounds = 1
        updateResult(game)
        return ok
    }
    private func syncCreativeFromPlayer(_ game: GameCore) {
        let actual = game.player.gameMode == GameMode.creative
        if creativeCrafting != actual {
            creativeCrafting = actual
            selectedCreativePlan = nil
            selectedSurvivalPlan = nil
            selectedCraftRounds = 1
            updateResult(game)
        }
    }
    private func selectRecipe(_ plan: CraftingRecipePlan, _ ui: UIManager, _ game: GameCore) {
        guard ui.cursorStack == nil else { return }
        if creativeCrafting {
            selectedCreativePlan = plan
            selectedSurvivalPlan = nil
            selectedCraftRounds = 1
            recipeMenu.close()
            updateResult(game)
            recipeMenu.refresh(game, craftGrid: craftGrid, creative: true)
            game.playUISound("ui.stonecutter.select_recipe")
            return
        }
        guard returnCraftGridToInventory(game) else { return }
        if populateCraftingGrid(plan, grid: &craftGrid, inventory: &game.player.inventory) {
            selectedSurvivalPlan = plan
            selectedCraftRounds = 1
            recipeMenu.close()
            updateResult(game)
            recipeMenu.refresh(game, craftGrid: craftGrid)
            game.playUISound("ui.stonecutter.select_recipe")
        }
    }
    private func takeCraftingOutput(_ game: GameCore) {
        if creativeCrafting {
            updateResult(game)
            game.advance("craft_any")
            return
        }
        guard let taken = craftResult else { return }
        let planForRefill = activeSurvivalPlan()
        let baseCount = max(1, planForRefill?.output.count ?? taken.count)
        let rounds = max(1, min(selectedCraftRounds, taken.count / baseCount))
        var consumed = 0
        while consumed < rounds {
            if matchCrafting(craftGrid, 2, 2)?.out.id != taken.id {
                guard let plan = planForRefill,
                      craftGrid.allSatisfy({ $0 == nil }),
                      populateCraftingGrid(plan, grid: &craftGrid, inventory: &game.player.inventory)
                else { break }
            }
            guard matchCrafting(craftGrid, 2, 2)?.out.id == taken.id else { break }
            _ = consumeCraftingGrid(&craftGrid)
            consumed += 1
        }
        updateResult(game)
        game.advance("craft_any")
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        syncCreativeFromPlayer(game)
        recipeMenu.layout(ui)
        if let cb = creativeCheckbox {
            cb.x = min(148, max(4, ui.width - cb.w - 4))
            cb.y = 4
        }
        if let characterButton {
            characterButton.visible = game.player.rpgClassesEnabled()
            characterButton.x = (creativeCheckbox?.x ?? 148) + (creativeCheckbox?.w ?? 82) + 6
            characterButton.y = 4
            if characterButton.x + characterButton.w > ui.width - 4 {
                characterButton.visible = false
            }
        }
        updateResult(game)
        updateCraftRoundButtons(game)
        recipeMenu.refresh(game, craftGrid: craftGrid, creative: creativeCrafting)
        super.draw(ui, game, partial)
        recipeMenu.draw(ui)
    }
    override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        let cv = ui.cv
        // vanilla inventory.png bakes the preview window, slot art and arrow in;
        // procedurally we draw the window frame + arrow ourselves
        if !textured {
            cv.drawText("▶", panelX + 138, panelY + 31, 1, "#3f3f3f", shadow: false)
            cv.setFill("#1c1c1c")
            cv.fillRect(panelX + 26, panelY + 8, 49, 70)
        }
        // simple front-facing player figure centered in the preview window
        let cx = panelX + 50, by = panelY + 10
        let sway = Foundation.sin(CACurrentMediaTime() * 1000 / 600) * 1.5
        let p = game.player!
        func px(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ c: String) {
            cv.setFill(c)
            cv.fillRect((cx + x + (y < 20 ? sway : 0)).rounded(), by + 6 + y, w, h)
        }
        px(-6, 0, 12, 12, "#b88a64")
        px(-4, 3, 3, 3, "#ffffff"); px(1, 3, 3, 3, "#ffffff")
        px(-3, 4, 2, 2, "#3a6ea8"); px(2, 4, 2, 2, "#3a6ea8")
        px(-6, 0, 12, 4, "#5a3c28")
        px(-6, 13, 12, 18, p.armor[1] != nil ? "#c8c8d0" : "#2ea3a3")
        px(-11, 13, 5, 16, "#b88a64")
        px(6, 13, 5, 16, "#b88a64")
        px(-6, 31, 5, 18, p.armor[2] != nil ? "#a8a8b0" : "#3a3a8c")
        px(1, 31, 5, 18, p.armor[2] != nil ? "#a8a8b0" : "#3a3a8c")
        px(-6, 49, 5, 4, p.armor[3] != nil ? "#909098" : "#6a6a6a")
        px(1, 49, 5, 4, p.armor[3] != nil ? "#909098" : "#6a6a6a")
        if p.armor[0] != nil { px(-6, 0, 12, 5, "#c8c8d0") }
    }
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        if let plan = recipeMenu.selectedPlan(at: mx, my) {
            selectRecipe(plan, ui, game)
            return true
        }
        if creativeCheckbox?.contains(mx, my) == true {
            return super.onMouseDown(ui, game, mx, my, btn)
        }
        recipeMenu.closeIfOpenOutsideButton(mx, my)
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        recipeMenu.onWheel(dy)
    }
    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        let result = recipeMenu.onKey(key)
        if result.handled {
            if let plan = result.plan { selectRecipe(plan, ui, game) }
            return true
        }
        return super.onKey(ui, game, key)
    }
    override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        if recipeMenu.onChar(ch) { return true }
        return super.onChar(ui, game, ch)
    }
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        _ = returnCraftGridToInventory(game)
    }
}

// =============================================================================
// Crafting table 3×3
// =============================================================================
final class CraftingScreen: ContainerScreen {
    private var localCraftGrid: [ItemStack?] = Array(repeating: nil, count: 9)
    private let tableBE: BlockEntityData?
    var craftGrid: [ItemStack?] {
        get {
            guard let tableBE else { return localCraftGrid }
            if tableBE.items?.count != 9 {
                tableBE.items = Array(repeating: nil, count: 9)
            }
            return tableBE.items ?? Array(repeating: nil, count: 9)
        }
        set {
            let normalized = normalizedCraftingGrid(newValue)
            if let tableBE {
                tableBE.items = normalized
            } else {
                localCraftGrid = normalized
            }
        }
    }
    var craftResult: ItemStack?
    private let recipeMenu = CraftingRecipePopup(gridWidth: 3, gridHeight: 3)
    private let tablePos: (x: Int, y: Int, z: Int)?
    private var creativeCrafting = false
    private var selectedCreativePlan: CraftingRecipePlan?
    private var selectedSurvivalPlan: CraftingRecipePlan?
    private var selectedCraftRounds = 1
    private weak var creativeCheckbox: CheckBox?
    private weak var craftUpButton: Button?
    private weak var craftDownButton: Button?
    private let readOnly: Bool

    init(_ tablePos: (x: Int, y: Int, z: Int)? = nil, tableBE: BlockEntityData? = nil, readOnly: Bool = false) {
        self.tablePos = tablePos
        self.tableBE = tableBE
        self.readOnly = readOnly
        super.init()
        readOnlySlots = readOnly
        title = "Crafting"
        titleX = 29
        sheet = "crafting_table"
        lanEditBE = tableBE
    }
    private func normalizedCraftingGrid(_ raw: [ItemStack?]) -> [ItemStack?] {
        var grid = Array(raw.prefix(9))
        if grid.count < 9 {
            grid.append(contentsOf: Array(repeating: nil, count: 9 - grid.count))
        }
        return grid
    }
    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        syncCreativeFromPlayer(game)
        let px = panelX, py = panelY
        for i in 0..<9 {
            let idx = i
            containerSlots.append(SlotDef(
                x: px + 29 + Double(i % 3) * 18, y: py + 16 + Double(i / 3) * 18,
                get: { [weak self] in self?.craftGrid[idx] },
                set: { [weak self, weak game] s in
                    self?.selectedSurvivalPlan = nil
                    self?.selectedCraftRounds = 1
                    self?.craftGrid[idx] = s
                    self?.updateResult(game)
                },
                onChange: { [weak self, weak game] in
                    self?.selectedSurvivalPlan = nil
                    self?.selectedCraftRounds = 1
                    self?.updateResult(game)
                }))
        }
        containerSlots.append(SlotDef(
            x: px + 123, y: py + 34,
            get: { [weak self] in self?.craftResult },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                guard let self, let game else { return }
                self.takeCraftingOutput(game)
            },
            repeatsOutputQuickMove: { [weak self] in
                (self?.selectedCraftRounds ?? 1) <= 1
            }))
        if !readOnly {
            installCraftAmountButtons(outputX: px + 123, outputY: py + 34, game)
            recipeMenu.installButton(on: self) { [weak self] in
                self?.recipeMenu.toggle()
            }
            let cb = CheckBox(148, 4, 82, 18, "Creative", isChecked: { [weak self] in
                self?.creativeCrafting ?? false
            }, { [weak self, weak game] in
                guard let self else { return }
                self.creativeCrafting = !self.creativeCrafting
                game?.player.setGameMode(self.creativeCrafting ? GameMode.creative : GameMode.survival)
                self.selectedCreativePlan = nil
                self.selectedSurvivalPlan = nil
                self.selectedCraftRounds = 1
                self.updateResult(game)
                if let game { self.recipeMenu.refresh(game, craftGrid: self.craftGrid, creative: self.creativeCrafting) }
            })
            creativeCheckbox = cb
            buttons.append(cb)
        }
    }
    private func installCraftAmountButtons(outputX: Double, outputY: Double, _ game: GameCore) {
        let frames = CraftAmountStepperLayout.frames(outputX: outputX, outputY: outputY)
        let up = CraftAmountButton(frames.up.x, frames.up.y, frames.up.w, frames.up.h, direction: .up) { [weak self, weak game] in
            guard let self, let game else { return }
            self.adjustCraftRounds(1, game)
        }
        let down = CraftAmountButton(frames.down.x, frames.down.y, frames.down.w, frames.down.h, direction: .down) { [weak self, weak game] in
            guard let self, let game else { return }
            self.adjustCraftRounds(-1, game)
        }
        craftUpButton = up
        craftDownButton = down
        buttons.append(up)
        buttons.append(down)
    }
    private func activeSurvivalPlan() -> CraftingRecipePlan? {
        selectedSurvivalPlan ?? currentCraftingPlan(from: craftGrid, gridWidth: 3, gridHeight: 3)
    }
    private func activeCraftingPlan() -> CraftingRecipePlan? {
        creativeCrafting ? selectedCreativePlan : activeSurvivalPlan()
    }
    private func availableCraftRounds(_ game: GameCore) -> Int {
        guard let plan = activeCraftingPlan() else { return 0 }
        if creativeCrafting {
            return max(1, maxCreativeCraftingRounds(plan, into: game.player.inventory))
        }
        return maxCraftingRounds(plan, from: availableRecipeResources(game))
    }
    private func clampCraftRounds(_ game: GameCore) -> Int {
        let maxRounds = availableCraftRounds(game)
        guard maxRounds > 0 else {
            selectedCraftRounds = 1
            return 0
        }
        selectedCraftRounds = min(max(1, selectedCraftRounds), maxRounds)
        return maxRounds
    }
    private func updateCraftRoundButtons(_ game: GameCore) {
        let maxRounds = clampCraftRounds(game)
        let hasOutput = activeCraftingPlan() != nil && maxRounds > 0
        craftUpButton?.visible = hasOutput
        craftDownButton?.visible = hasOutput
        craftUpButton?.enabled = hasOutput && selectedCraftRounds < maxRounds
        craftDownButton?.enabled = hasOutput && selectedCraftRounds > 1
    }
    private func adjustCraftRounds(_ delta: Int, _ game: GameCore) {
        syncCreativeFromPlayer(game)
        let maxRounds = max(0, availableCraftRounds(game))
        guard maxRounds > 0 else {
            selectedCraftRounds = 1
            updateResult(game)
            return
        }
        selectedCraftRounds = min(max(1, selectedCraftRounds + delta), maxRounds)
        updateResult(game)
        updateCraftRoundButtons(game)
    }
    func updateResult(_ game: GameCore? = nil) {
        if let game, clampCraftRounds(game) == 0 {
            craftResult = nil
            return
        }
        guard let plan = activeCraftingPlan() else {
            craftResult = nil
            selectedCraftRounds = 1
            return
        }
        let out = plan.output.copy()
        out.count = max(1, selectedCraftRounds) * max(1, plan.output.count)
        craftResult = out
    }
    private func returnCraftGridToInventory(_ game: GameCore) -> Bool {
        var ok = true
        for i in craftGrid.indices {
            guard let stack = craftGrid[i] else { continue }
            if game.player.give(stack) || stack.count <= 0 {
                craftGrid[i] = nil
            } else if let tablePos,
                      giveStackToNearbyCraftingContainers(stack, world: game.world,
                                                          tableX: tablePos.x, tableY: tablePos.y, tableZ: tablePos.z)
                        || stack.count <= 0 {
                craftGrid[i] = nil
            } else {
                ok = false
            }
        }
        selectedSurvivalPlan = nil
        selectedCraftRounds = 1
        updateResult(game)
        return ok
    }
    private func availableRecipeResources(_ game: GameCore) -> [ItemStack?] {
        guard let tablePos else { return game.player.inventory + craftGrid }
        return craftingTableResourceStacks(playerInventory: game.player.inventory,
                                           craftGrid: craftGrid,
                                           world: game.world,
                                           tableX: tablePos.x, tableY: tablePos.y, tableZ: tablePos.z)
    }
    private func syncCreativeFromPlayer(_ game: GameCore) {
        let actual = game.player.gameMode == GameMode.creative
        if creativeCrafting != actual {
            creativeCrafting = actual
            selectedCreativePlan = nil
            selectedSurvivalPlan = nil
            selectedCraftRounds = 1
            updateResult(game)
        }
    }
    private func selectRecipe(_ plan: CraftingRecipePlan, _ ui: UIManager, _ game: GameCore) {
        guard ui.cursorStack == nil else { return }
        if creativeCrafting {
            selectedCreativePlan = plan
            selectedSurvivalPlan = nil
            selectedCraftRounds = 1
            recipeMenu.close()
            updateResult(game)
            recipeMenu.refresh(game, craftGrid: craftGrid, creative: true)
            game.playUISound("ui.stonecutter.select_recipe")
            return
        }
        guard returnCraftGridToInventory(game) else { return }
        let populated: Bool
        if let tablePos {
            populated = populateCraftingGridFromNearbyContainers(plan, grid: &craftGrid,
                                                                 inventory: &game.player.inventory,
                                                                 world: game.world,
                                                                 tableX: tablePos.x, tableY: tablePos.y, tableZ: tablePos.z)
        } else {
            populated = populateCraftingGrid(plan, grid: &craftGrid, inventory: &game.player.inventory)
        }
        if populated {
            selectedSurvivalPlan = plan
            selectedCraftRounds = 1
            recipeMenu.close()
            updateResult(game)
            recipeMenu.refresh(game, craftGrid: craftGrid, resources: availableRecipeResources(game))
            game.playUISound("ui.stonecutter.select_recipe")
        }
    }
    private func refillSurvivalPlan(_ plan: CraftingRecipePlan?, _ game: GameCore) -> Bool {
        guard craftGrid.allSatisfy({ $0 == nil }), let plan else { return false }
        if let tablePos {
            return populateCraftingGridFromNearbyContainers(plan, grid: &craftGrid,
                                                            inventory: &game.player.inventory,
                                                            world: game.world,
                                                            tableX: tablePos.x, tableY: tablePos.y, tableZ: tablePos.z)
        }
        return populateCraftingGrid(plan, grid: &craftGrid, inventory: &game.player.inventory)
    }
    private func takeCraftingOutput(_ game: GameCore) {
        if creativeCrafting {
            updateResult(game)
            game.advance("craft_any")
            return
        }
        guard let taken = craftResult else { return }
        let planForRefill = activeSurvivalPlan()
        let baseCount = max(1, planForRefill?.output.count ?? taken.count)
        let rounds = max(1, min(selectedCraftRounds, taken.count / baseCount))
        var consumed = 0
        while consumed < rounds {
            if matchCrafting(craftGrid, 3, 3)?.out.id != taken.id {
                guard refillSurvivalPlan(planForRefill, game) else { break }
            }
            guard matchCrafting(craftGrid, 3, 3)?.out.id == taken.id else { break }
            _ = consumeCraftingGrid(&craftGrid)
            consumed += 1
        }
        updateResult(game)
        game.advance("craft_any")
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        syncCreativeFromPlayer(game)
        recipeMenu.layout(ui)
        if let cb = creativeCheckbox {
            cb.x = min(148, max(4, ui.width - cb.w - 4))
            cb.y = 4
        }
        updateResult(game)
        updateCraftRoundButtons(game)
        let resources = creativeCrafting ? nil : availableRecipeResources(game)
        recipeMenu.refresh(game, craftGrid: craftGrid, creative: creativeCrafting, resources: resources)
        super.draw(ui, game, partial)
        recipeMenu.draw(ui)
    }
    override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        if !textured {
            ui.cv.drawText("▶", panelX + 95, panelY + 38, 2, "#3f3f3f", shadow: false)
        }
    }
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        if readOnly {
            return super.onMouseDown(ui, game, mx, my, btn)
        }
        if let plan = recipeMenu.selectedPlan(at: mx, my) {
            selectRecipe(plan, ui, game)
            return true
        }
        if creativeCheckbox?.contains(mx, my) == true {
            return super.onMouseDown(ui, game, mx, my, btn)
        }
        recipeMenu.closeIfOpenOutsideButton(mx, my)
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        if readOnly { return false }
        return recipeMenu.onWheel(dy)
    }
    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        if readOnly { return super.onKey(ui, game, key) }
        let result = recipeMenu.onKey(key)
        if result.handled {
            if let plan = result.plan { selectRecipe(plan, ui, game) }
            return true
        }
        return super.onKey(ui, game, key)
    }
    override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        if readOnly { return super.onChar(ui, game, ch) }
        if recipeMenu.onChar(ch) { return true }
        return super.onChar(ui, game, ch)
    }
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        if tableBE == nil && !readOnly {
            _ = returnCraftGridToInventory(game)
        }
        super.onClose(ui, game)
    }
}

// =============================================================================
// Furnace / blast furnace / smoker
// =============================================================================
final class FurnaceScreen: ContainerScreen {
    private let be: BlockEntityData

    init(_ be: BlockEntityData, readOnly: Bool = false) {
        self.be = be
        super.init()
        readOnlySlots = readOnly
        title = be.kind == "blast" ? "Blast Furnace" : be.kind == "smoker" ? "Smoker" : "Furnace"
        sheet = "furnace"
        lanEditBE = be
    }
    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        let be = self.be
        containerSlots.append(SlotDef(
            x: px + 55, y: py + 16,
            get: { be.items![0] }, set: { be.items![0] = $0 }))
        containerSlots.append(SlotDef(
            x: px + 55, y: py + 52,
            get: { be.items![1] }, set: { be.items![1] = $0 },
            canPlace: { fuelTime($0) > 0 }))
        containerSlots.append(SlotDef(
            x: px + 115, y: py + 34,
            get: { be.items![2] },
            set: { _ in },
            output: true,
            onTake: { [weak game] _ in
                be.items![2] = nil
                let xp = Int(be.xpBank ?? 0)
                if xp > 0, let game {
                    spawnXP(game.world, game.player.x, game.player.y, game.player.z, xp)
                    be.xpBank = 0
                }
            }))
    }
    override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        let cv = ui.cv
        let px = panelX, py = panelY
        let burnTime = be.burnTime ?? 0
        let burnF = (be.burnTotal ?? 0) > 0 ? Double(burnTime) / Double(be.burnTotal!) : 0
        let prog = (be.cookTotal ?? 0) > 0 ? Double(be.cookTime ?? 0) / Double(be.cookTotal!) : 0
        if textured {
            // vanilla overlays from furnace.png: flame (176,0) fills bottom-up,
            // arrow (176,14) fills left-to-right
            if burnTime > 0 {
                let i = (burnF * 13).rounded()
                ui.blitSheet("furnace", 176, 12 - i, 14, i + 1, px + 56, py + 36 + 12 - i)
            }
            let j = (prog * 24).rounded()
            if j > 0 {
                ui.blitSheet("furnace", 176, 14, j + 1, 16, px + 79, py + 34)
            }
            return
        }
        if burnTime > 0 {
            let h = (burnF * 13).rounded(.up)
            cv.setFill("#ff9a2c")
            cv.fillRect(px + 57, py + 36 + (13 - h), 13, h)
        } else {
            cv.setFill("#3a3a3a")
            cv.fillRect(px + 57, py + 36, 13, 13)
        }
        cv.setFill("#5a5a5a")
        cv.fillRect(px + 79, py + 38, 24, 10)
        cv.setFill("#ffffff")
        cv.fillRect(px + 79, py + 38, (24 * prog).rounded(), 10)
    }
}

// =============================================================================
// Generic chest-style container
// =============================================================================
final class ChestScreen: ContainerScreen {
    private let getItems: () -> [ItemStack?]
    private let setItem: (Int, ItemStack?) -> Void
    private let count: Int
    private let other: BlockEntityData?

    /// items live in a BlockEntityData or a vehicle — accessors close over the owner
    init(_ be: BlockEntityData, _ title: String, _ other: BlockEntityData? = nil, readOnly: Bool = false) {
        count = be.items?.count ?? 27
        getItems = { be.items ?? [] }
        setItem = { be.items?[$0] = $1 }
        self.other = other
        super.init()
        readOnlySlots = readOnly
        self.title = title
        let total = count + (other?.items?.count ?? 0)
        panelH = 114 + Double((total + 8) / 9) * 18
        lanEditBE = be
        lanEditBEs = [be] + [other].compactMap { $0 }
    }
    init(vehicle: Boat, _ title: String) {
        count = vehicle.chestItems.count
        getItems = { vehicle.chestItems }
        setItem = { vehicle.chestItems[$0] = $1 }
        other = nil
        super.init()
        self.title = title
        panelH = 114 + Double((count + 8) / 9) * 18
    }
    init(vehicle: Minecart, _ title: String) {
        count = vehicle.chestItems.count
        getItems = { vehicle.chestItems }
        setItem = { vehicle.chestItems[$0] = $1 }
        other = nil
        super.init()
        self.title = title
        panelH = 114 + Double((count + 8) / 9) * 18
    }
    init(items: @escaping () -> [ItemStack?], set: @escaping (Int, ItemStack?) -> Void, count: Int, _ title: String) {
        self.count = count
        getItems = items
        setItem = set
        other = nil
        super.init()
        self.title = title
        panelH = 114 + Double((count + 8) / 9) * 18
    }

    /// vanilla generic_54 player grid sits at imageHeight−84 (one px above the 166-panel layouts)
    override var playerInvY: Double { panelH - 84 }

    /// generic_54.png is sliced vanilla-style: header+rows piece, then the
    /// player-inventory piece from y=126 — works for any 1–6 row container
    override func drawSheetPanel(_ ui: UIManager) -> Bool {
        let rows = (panelH - 114) / 18
        let total = containerSlots.count
        guard total % 9 == 0, rows >= 1, rows <= 6, ui.hasSheet("generic_54") else { return false }
        let topH = rows * 18 + 17
        ui.blitSheet("generic_54", 0, 0, 176, topH, panelX, panelY)
        ui.blitSheet("generic_54", 0, 126, 176, 96, panelX, panelY + topH)
        return true
    }

    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        var i = 0
        for idx in 0..<count {
            let g = getItems, s = setItem
            containerSlots.append(SlotDef(
                x: px + 7 + Double(i % 9) * 18,
                y: py + 17 + Double(i / 9) * 18,
                get: { g()[idx] },
                set: { s(idx, $0) }))
            i += 1
        }
        if let o = other, o.items != nil {
            for idx in 0..<(o.items!.count) {
                containerSlots.append(SlotDef(
                    x: px + 7 + Double(i % 9) * 18,
                    y: py + 17 + Double(i / 9) * 18,
                    get: { o.items![idx] },
                    set: { o.items![idx] = $0 }))
                i += 1
            }
        }
    }
}

// =============================================================================
// Brewing stand
// =============================================================================
final class BrewingScreen: ContainerScreen {
    private let be: BlockEntityData

    init(_ be: BlockEntityData, readOnly: Bool = false) {
        self.be = be
        super.init()
        readOnlySlots = readOnly
        title = "Brewing Stand"
        sheet = "brewing_stand"
        lanEditBE = be
    }
    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        let be = self.be
        let bottlePositions: [(Double, Double)] = [(55, 50), (79, 57), (103, 50)]
        for i in 0..<3 {
            let idx = i
            containerSlots.append(SlotDef(
                x: px + bottlePositions[i].0, y: py + bottlePositions[i].1,
                get: { be.items![idx] }, set: { be.items![idx] = $0 },
                canPlace: { ["potion", "splash_potion", "lingering_potion", "glass_bottle"].contains(itemDef($0.id).name) }))
        }
        containerSlots.append(SlotDef(
            x: px + 78, y: py + 16,
            get: { be.items![3] }, set: { be.items![3] = $0 },
            canPlace: { isBrewIngredient(itemDef($0.id).name) }))
        containerSlots.append(SlotDef(
            x: px + 16, y: py + 16,
            get: { be.items![4] }, set: { be.items![4] = $0 },
            canPlace: { itemDef($0.id).name == "blaze_powder" }))
    }
    override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        let cv = ui.cv
        let px = panelX, py = panelY
        let fuelW = (18 * Double(be.fuel ?? 0) / 20).rounded()
        let brewing = (be.brewTime ?? 0) > 0
        let f = brewing ? Double(be.brewTime!) / 400 : 0
        if textured {
            // vanilla overlays from brewing_stand.png: fuel flame strip, brew
            // arrow filling downward, bubbles cycling while active
            if fuelW > 0 { ui.blitSheet("brewing_stand", 176, 29, fuelW, 4, px + 60, py + 44) }
            if brewing {
                let j = (28 * f).rounded()
                if j > 0 { ui.blitSheet("brewing_stand", 176, 0, 9, j, px + 97, py + 16) }
                let lengths: [Double] = [29, 24, 20, 16, 11, 6, 0]
                let k = lengths[Int(CACurrentMediaTime() * 10) % 7]
                if k > 0 { ui.blitSheet("brewing_stand", 185, 29 - k, 12, k, px + 63, py + 14 + 29 - k) }
            }
            return
        }
        cv.setFill("#3a3a3a")
        cv.fillRect(px + 36, py + 18, 18, 4)
        cv.setFill("#e89a3c")
        cv.fillRect(px + 36, py + 18, fuelW, 4)
        if brewing {
            cv.setFill("#e8e8e8")
            cv.fillRect(px + 98, py + 18, 2, (26 * f).rounded())
        }
        cv.drawText("◡", px + 76, py + 36, 1, "#3f3f3f", shadow: false)
    }
}

// =============================================================================
// Enchanting table
// =============================================================================
final class EnchantingScreen: ContainerScreen {
    var item: ItemStack?
    var lapis: ItemStack?
    var options: [EnchantOption] = []
    var seed = Int.random(in: 0..<1_000_000_000)
    var bookshelves = 0
    private let pos: (x: Int, y: Int, z: Int)

    init(_ pos: (x: Int, y: Int, z: Int)) {
        self.pos = pos
        super.init()
        title = "Enchant"
        sheet = "enchanting_table"
    }
    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        super.initScreen(ui, game)
        var n = 0
        for dz in -2...2 {
            for dx in -2...2 {
                if abs(dx) < 2 && abs(dz) < 2 { continue }
                for dy in [0, 1] {
                    if (game.world.getBlock(pos.x + dx, pos.y + dy, pos.z + dz) >> 4) == Int(B.bookshelf) { n += 1 }
                }
            }
        }
        bookshelves = min(15, n)
    }
    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        containerSlots.append(SlotDef(
            x: px + 14, y: py + 46,
            get: { [weak self] in self?.item },
            set: { [weak self] s in
                self?.item = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 34, y: py + 46,
            get: { [weak self] in self?.lapis },
            set: { [weak self] s in
                self?.lapis = s
                self?.refresh()
            },
            canPlace: { itemDef($0.id).name == "lapis_lazuli" },
            onChange: { [weak self] in self?.refresh() }))
    }
    func refresh() {
        options = enchantingOptions(item, bookshelves, seed)
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        super.draw(ui, game, partial)
        let cv = ui.cv
        let px = panelX, py = panelY
        let lapisCount = lapis?.count ?? 0
        for i in 0..<3 {
            let opt = i < options.count ? options[i] : nil
            let bx = px + 60, by = py + 14 + Double(i) * 19, bw = 108.0, bh = 18.0
            let affordable = opt != nil && game.player.xpLevel >= opt!.level && lapisCount >= opt!.lapis
            let hover = ui.mouseX >= bx && ui.mouseX < bx + bw && ui.mouseY >= by && ui.mouseY < by + bh
            cv.setFill(opt == nil ? "#3a3a3a" : affordable ? (hover ? "#5a4a8a" : "#4a3a6a") : "#3a3a3a")
            cv.fillRect(bx, by, bw, bh)
            if let opt {
                cv.drawText(String(opt.level), bx + bw - 12, by + 9, 1, affordable ? "#80ff20" : "#407f10")
                if let e = opt.preview {
                    let label = e.id.replacingOccurrences(of: "_", with: " ") + " " + ["I", "II", "III", "IV", "V"][min(4, e.lvl - 1)] + "…"
                    cv.drawText(label, bx + 4, by + 5, 1, affordable ? "#d8c8f8" : "#707070")
                }
                cv.drawText(String(repeating: "•", count: opt.lapis), bx + 4, by + 12, 1, "#3c5ac8")
            }
        }
        cv.drawText("Bookshelves: \(bookshelves)", px + 60, py + 73, 1, "#3f3f3f", shadow: false)
    }
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        let px = panelX, py = panelY
        for i in 0..<3 {
            let bx = px + 60, by = py + 14 + Double(i) * 19
            if mx >= bx && mx < bx + 108 && my >= by && my < by + 18 {
                if i < options.count, let item = self.item {
                    let opt = options[i]
                    if game.player.xpLevel >= opt.level && (lapis?.count ?? 0) >= opt.lapis {
                        self.item = applyEnchanting(item, opt)
                        lapis!.count -= opt.lapis
                        if lapis!.count <= 0 { lapis = nil }
                        game.player.takeLevels(opt.lapis)
                        seed = Int.random(in: 0..<1_000_000_000)
                        refresh()
                        game.playUISound("block.enchantment_table.use")
                        game.advance("enchant_item")
                    }
                }
                return true
            }
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let item { _ = game.player.give(item) }
        if let lapis { _ = game.player.give(lapis) }
    }
}

// =============================================================================
// Anvil
// =============================================================================
final class AnvilScreen: ContainerScreen {
    var left: ItemStack?
    var right: ItemStack?
    var result: ItemStack?
    var cost = 0
    let nameField = TextField(0, 0, 96, 14)
    private var pos: (x: Int, y: Int, z: Int, damage: Int)

    init(_ pos: (x: Int, y: Int, z: Int, damage: Int)) {
        self.pos = pos
        super.init()
        title = "Repair & Name"
        sheet = "anvil"
    }
    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        super.initScreen(ui, game)
        nameField.x = panelX + 60
        nameField.y = panelY + 22
        fields.append(nameField)
    }
    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        containerSlots.append(SlotDef(
            x: px + 26, y: py + 46,
            get: { [weak self] in self?.left },
            set: { [weak self] s in
                self?.left = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 75, y: py + 46,
            get: { [weak self] in self?.right },
            set: { [weak self] s in
                self?.right = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 133, y: py + 46,
            get: { [weak self] in self?.result },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game, weak ui] _ in
                guard let self, let game, let ui else { return }
                game.player.takeLevels(self.cost)
                self.left = nil
                if let right = self.right {
                    let units = self.result?.data.repairUnits
                    if let units, right.count > units {
                        right.count -= units
                    } else {
                        self.right = nil
                    }
                }
                self.result?.data.repairUnits = nil
                self.result = nil
                self.cost = 0
                // anvil degrade
                if Double.random(in: 0..<1) < 0.12 {
                    let (x, y, z, damage) = self.pos
                    let c = game.world.getBlock(x, y, z)
                    if damage >= 2 {
                        game.world.setBlock(x, y, z, 0)
                        game.world.hooks.playSound("block.anvil.destroy", Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
                        ui.closeTop(game)
                    } else {
                        game.world.setBlock(x, y, z, Int(cell(damage == 0 ? B.chipped_anvil : B.damaged_anvil, c & 15)))
                        self.pos.damage += 1
                    }
                }
                game.world.hooks.playSound("block.anvil.use", Double(self.pos.x) + 0.5, Double(self.pos.y) + 0.5, Double(self.pos.z) + 0.5, 1, 1)
            }))
    }
    func refresh() {
        let r = anvilCombine(left, right, nameField.text.isEmpty ? nil : nameField.text)
        result = r?.out
        cost = r?.cost ?? 0
    }
    override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        let r = super.onChar(ui, game, ch)
        if r { refresh() }
        return r
    }
    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        let r = super.onKey(ui, game, key)
        if r { refresh() }
        return r
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        super.draw(ui, game, partial)
        if cost > 0 {
            let ok = game.player.xpLevel >= cost && cost < 40
            ui.cv.drawText(cost >= 40 ? "Too Expensive!" : "Enchantment Cost: \(cost)",
                           panelX + 8, panelY + 71, 1, ok ? "#80ff20" : "#ff5050")
        }
        if !textured {
            ui.cv.drawText("+", panelX + 56, panelY + 50, 1, "#3f3f3f", shadow: false)
        }
    }
    override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        if textured {
            // vanilla text-field art strip below the GUI in anvil.png
            ui.blitSheet("anvil", 0, 166, 110, 16, panelX + 59, panelY + 20)
        }
    }
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let left { _ = game.player.give(left) }
        if let right { _ = game.player.give(right) }
    }
}

// =============================================================================
// Grindstone
// =============================================================================
final class GrindstoneScreen: ContainerScreen {
    var top: ItemStack?
    var bottom: ItemStack?
    var result: ItemStack?
    var xp = 0

    override init() {
        super.init()
        title = "Repair & Disenchant"
        sheet = "grindstone"
    }
    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        containerSlots.append(SlotDef(
            x: px + 48, y: py + 18,
            get: { [weak self] in self?.top },
            set: { [weak self] s in
                self?.top = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 48, y: py + 39,
            get: { [weak self] in self?.bottom },
            set: { [weak self] s in
                self?.bottom = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 128, y: py + 33,
            get: { [weak self] in self?.result },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                guard let self, let game else { return }
                self.top = nil
                self.bottom = nil
                self.result = nil
                if self.xp > 0 {
                    spawnXP(game.world, game.player.x, game.player.y, game.player.z, self.xp)
                }
                self.xp = 0
                game.playUISound("block.grindstone.use")
            }))
    }
    func refresh() {
        let r = grindstoneResult(top, bottom)
        result = r?.out
        xp = r?.xp ?? 0
    }
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let top { _ = game.player.give(top) }
        if let bottom { _ = game.player.give(bottom) }
    }
}

// =============================================================================
// Stonecutter
// =============================================================================
final class StonecutterScreen: ContainerScreen {
    var input: ItemStack?
    var selected = -1
    var options: [(output: String, count: Int)] = []

    override init() {
        super.init()
        title = "Stonecutter"
        sheet = "stonecutter"
    }
    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        containerSlots.append(SlotDef(
            x: px + 19, y: py + 32,
            get: { [weak self] in self?.input },
            set: { [weak self] s in
                self?.input = s
                self?.refresh()
            },
            onChange: { [weak self] in self?.refresh() }))
        containerSlots.append(SlotDef(
            x: px + 142, y: py + 32,
            get: { [weak self] in
                guard let self, self.selected >= 0, self.input != nil, self.selected < self.options.count else { return nil }
                let o = self.options[self.selected]
                return ItemStack(iid(o.output), o.count)
            },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                guard let self else { return }
                if let input = self.input {
                    let sel = self.selected
                    input.count -= 1
                    if input.count <= 0 { self.input = nil }
                    self.refresh()
                    // keep the recipe selected while input remains (refresh
                    // clears it), so repeated/shift takes keep cutting
                    if self.input != nil && sel >= 0 && sel < self.options.count {
                        self.selected = sel
                    }
                }
                game?.playUISound("ui.stonecutter.take_result")
            }))
    }
    func refresh() {
        options = []
        selected = -1
        guard let input else { return }
        let name = itemDef(input.id).name
        for r in stonecuttingRecipes where r.input == name {
            options.append((r.output, r.count))
        }
    }
    private var gridX: Double { panelX + (textured ? 52 : 48) }
    private var gridY: Double { panelY + (textured ? 15 : 14) }
    private var cellW: Double { textured ? 16 : 18 }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        super.draw(ui, game, partial)
        let cv = ui.cv
        for i in 0..<min(12, options.count) {
            let ox = gridX + Double(i % 4) * cellW, oy = gridY + Double(i / 4) * 18
            if textured {
                if i == selected {
                    cv.setFill("rgba(138,138,255,0.55)")
                    cv.fillRect(ox, oy, cellW, 18)
                }
            } else {
                cv.setFill(i == selected ? "#8a8aff" : "#5a5a5a")
                cv.fillRect(ox, oy, cellW, 18)
            }
            cv.drawItemIcon(iid(options[i].output), nil, ox + (cellW - 16) / 2, oy + 1, 16, 16)
        }
    }
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        let px = gridX, py = gridY
        if mx >= px && mx < px + cellW * 4 && my >= py && my < py + 54 {
            let i = Int((mx - px) / cellW) + Int((my - py) / 18) * 4
            if i >= 0 && i < options.count {
                selected = i
                game.playUISound("ui.stonecutter.select_recipe")
                return true
            }
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let input { _ = game.player.give(input) }
    }
}

// =============================================================================
// Smithing table
// =============================================================================
final class SmithingScreen: ContainerScreen {
    var template: ItemStack?
    var base: ItemStack?
    var addition: ItemStack?
    var result: ItemStack?

    override init() {
        super.init()
        title = "Upgrade Gear"
        titleX = 44
        sheet = "smithing"
    }
    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX, py = panelY
        func mk(_ x: Double, _ getF: @escaping () -> ItemStack?, _ setF: @escaping (ItemStack?) -> Void) -> SlotDef {
            SlotDef(
                x: px + x, y: py + 47,
                get: getF,
                set: { [weak self] s in
                    setF(s)
                    self?.refresh()
                },
                onChange: { [weak self] in self?.refresh() })
        }
        containerSlots.append(mk(7, { [weak self] in self?.template }, { [weak self] in self?.template = $0 }))
        containerSlots.append(mk(25, { [weak self] in self?.base }, { [weak self] in self?.base = $0 }))
        containerSlots.append(mk(43, { [weak self] in self?.addition }, { [weak self] in self?.addition = $0 }))
        containerSlots.append(SlotDef(
            x: px + 97, y: py + 47,
            get: { [weak self] in self?.result },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                guard let self else { return }
                self.consumeOne(&self.template)
                self.consumeOne(&self.base)
                self.consumeOne(&self.addition)
                self.result = nil
                self.refresh()
                game?.playUISound("block.smithing_table.use")
            }))
    }
    private func consumeOne(_ s: inout ItemStack?) {
        if let stack = s {
            stack.count -= 1
            if stack.count <= 0 { s = nil }
        }
    }
    func refresh() {
        result = matchSmithing(template, base, addition)
    }
    override func drawExtra(_ ui: UIManager, _ game: GameCore) {
        if !textured {
            ui.cv.drawText("▶", panelX + 74, panelY + 48, 1, "#3f3f3f", shadow: false)
        }
    }
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        for s in [template, base, addition] {
            if let s { _ = game.player.give(s) }
        }
        template = nil
        base = nil
        addition = nil
    }
}

// =============================================================================
// Beacon
// =============================================================================
final class BeaconScreen: Screen {
    var payment: ItemStack?
    var pendingPrimary: String?
    var panelX = 0.0
    var panelY = 0.0
    private let be: BlockEntityData

    init(_ be: BlockEntityData) {
        self.be = be
        super.init()
    }
    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        panelX = ((ui.width - 200) / 2).rounded(.down)
        panelY = ((ui.height - 120) / 2).rounded(.down)
        slots.append(SlotDef(
            x: panelX + 160, y: panelY + 90,
            get: { [weak self] in self?.payment },
            set: { [weak self] in self?.payment = $0 },
            canPlace: { ["iron_ingot", "gold_ingot", "diamond", "emerald", "netherite_ingot"].contains(itemDef($0.id).name) }))
        pendingPrimary = be.primary
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.55)
        ui.drawPanel(panelX, panelY, 200, 120)
        let cv = ui.cv
        cv.drawText("Beacon (Pyramid level \(be.levels ?? 0))", panelX + 8, panelY + 6, 1, "#3f3f3f", shadow: false)
        let powers: [(String, String, Int)] = [
            ("speed", "Speed", 1), ("haste", "Haste", 1),
            ("resistance", "Resistance", 2), ("jump_boost", "Jump Boost", 2),
            ("strength", "Strength", 3),
        ]
        for (i, p) in powers.enumerated() {
            let bx = panelX + 10 + Double(i % 2) * 92
            let by = panelY + 20 + Double(i / 2) * 22
            let unlocked = (be.levels ?? 0) >= p.2
            let sel = pendingPrimary == p.0
            cv.setFill(!unlocked ? "#3a3a3a" : sel ? "#6a8aff" : "#5a5a5a")
            cv.fillRect(bx, by, 88, 18)
            cv.drawText(p.1, bx + 5, by + 5, 1, unlocked ? "#ffffff" : "#808080")
        }
        cv.drawText("Pay:", panelX + 132, panelY + 95, 1, "#3f3f3f", shadow: false)
        ui.drawSlots(self)
        let can = pendingPrimary != nil && payment != nil && (be.levels ?? 0) > 0
        cv.setFill(can ? "#4a8a4a" : "#3a3a3a")
        cv.fillRect(panelX + 10, panelY + 92, 60, 16)
        cv.drawTextCentered("Confirm", panelX + 40, panelY + 96, 1, can ? "#ffffff" : "#808080")
    }
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        let powers = ["speed", "haste", "resistance", "jump_boost", "strength"]
        let minLvls = [1, 1, 2, 2, 3]
        for i in 0..<powers.count {
            let bx = panelX + 10 + Double(i % 2) * 92
            let by = panelY + 20 + Double(i / 2) * 22
            if mx >= bx && mx < bx + 88 && my >= by && my < by + 18 && (be.levels ?? 0) >= minLvls[i] {
                pendingPrimary = powers[i]
                return true
            }
        }
        if mx >= panelX + 10 && mx < panelX + 70 && my >= panelY + 92 && my < panelY + 108 {
            if let primary = pendingPrimary, let pay = payment, (be.levels ?? 0) > 0 {
                be.primary = primary
                be.secondary = (be.levels ?? 0) >= 4 ? primary : nil
                pay.count -= 1
                if pay.count <= 0 { payment = nil }
                game.playUISound("block.beacon.power_select")
                ui.closeTop(game)
            }
            return true
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let payment { _ = game.player.give(payment) }
    }
}

// =============================================================================
// Villager trading
// =============================================================================
final class TradingScreen: ContainerScreen {
    var selected = 0
    var buyA: ItemStack?
    var buyB: ItemStack?
    private let villager: Mob

    init(_ villager: Mob) {
        self.villager = villager
        super.init()
        panelW = 250
        title = "Trading"
    }
    var offers: [TradeOffer] {
        (villager as? Villager)?.offers ?? (villager as? WanderingTrader)?.offers ?? []
    }
    override func buildSlots(_ ui: UIManager, _ game: GameCore) {
        let px = panelX + 80, py = panelY
        containerSlots.append(SlotDef(
            x: px + 24, y: py + 40,
            get: { [weak self] in self?.buyA },
            set: { [weak self] in self?.buyA = $0 }))
        containerSlots.append(SlotDef(
            x: px + 48, y: py + 40,
            get: { [weak self] in self?.buyB },
            set: { [weak self] in self?.buyB = $0 }))
        containerSlots.append(SlotDef(
            x: px + 100, y: py + 40,
            get: { [weak self] in self?.tradeResult() },
            set: { _ in },
            output: true,
            onTake: { [weak self, weak game] _ in
                if let game { self?.executeTrade(game) }
            }))
        playerSlots = playerInvSlots(game.player, panelX + 80, panelY + panelH - 83)
        slots = containerSlots + playerSlots
    }
    func tradeResult() -> ItemStack? {
        guard selected < offers.count else { return nil }
        let o = offers[selected]
        if o.uses >= o.maxUses { return nil }
        if !matches(buyA, o.buyA) { return nil }
        if let b = o.buyB, !matches(buyB, b) { return nil }
        return copyStack(o.sell)
    }
    private func matches(_ have: ItemStack?, _ want: ItemStack) -> Bool {
        guard let have else { return false }
        return have.id == want.id && have.count >= want.count
    }
    private func executeTrade(_ game: GameCore) {
        guard selected < offers.count else { return }
        let o = offers[selected]
        buyA!.count -= o.buyA.count
        if buyA!.count <= 0 { buyA = nil }
        if let b = o.buyB, let mine = buyB {
            mine.count -= b.count
            if mine.count <= 0 { buyB = nil }
        }
        if let v = villager as? Villager {
            v.offers[selected].uses += 1
            v.addTradeXP(o.xp)
        } else if let w = villager as? WanderingTrader {
            w.offers[selected].uses += 1
        }
        game.playUISound("entity.villager.yes")
        game.advance("trade_villager")
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.55)
        ui.drawPanel(panelX, panelY, panelW, panelH)
        let cv = ui.cv
        let prof = (villager as? Villager)?.profession ?? "wandering trader"
        let lvl = (villager as? Villager).map { String($0.tradeLevel) } ?? "-"
        cv.drawText("\(prof.prefix(1).uppercased())\(prof.dropFirst()) (lvl \(lvl))", panelX + 8, panelY + 6, 1, "#3f3f3f", shadow: false)
        for (i, o) in offers.enumerated() where i < 7 {
            let oy = panelY + 18 + Double(i) * 20
            let hover = ui.mouseX >= panelX + 5 && ui.mouseX < panelX + 75 && ui.mouseY >= oy && ui.mouseY < oy + 20
            cv.setFill(i == selected ? "#6a8aff" : hover ? "#7a7a7a" : "#5a5a5a")
            cv.fillRect(panelX + 5, oy, 72, 20)
            cv.drawItemIcon(o.buyA.id, nil, panelX + 7, oy + 2, 16, 16)
            cv.drawText(String(o.buyA.count), panelX + 18, oy + 10, 1)
            cv.drawText("→", panelX + 32, oy + 6, 1, "#e8e8e8")
            cv.drawItemIcon(o.sell.id, o.sell.data, panelX + 46, oy + 2, 16, 16)
            if o.sell.count > 1 { cv.drawText(String(o.sell.count), panelX + 58, oy + 10, 1) }
            if o.uses >= o.maxUses {
                cv.setFill("rgba(180,0,0,0.4)")
                cv.fillRect(panelX + 5, oy, 72, 20)
            }
        }
        cv.drawText("Trade", panelX + 104, panelY + 28, 1, "#3f3f3f", shadow: false)
        ui.drawSlots(self)
    }
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        for i in 0..<min(offers.count, 7) {
            let oy = panelY + 18 + Double(i) * 20
            if mx >= panelX + 5 && mx < panelX + 77 && my >= oy && my < oy + 20 {
                selected = i
                return true
            }
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        if let buyA { _ = game.player.give(buyA) }
        if let buyB { _ = game.player.give(buyB) }
    }
}

// =============================================================================
// Creative inventory
// =============================================================================
private let CREATIVE_TABS: [(String, String)] = [
    ("building", "Building"), ("colored", "Colored"), ("natural", "Natural"),
    ("functional", "Function"), ("redstone", "Redstone"), ("tools", "Tools"),
    ("combat", "Combat"), ("food", "Food"), ("ingredients", "Ingred."), ("spawn_eggs", "Eggs"),
]
private let CREATIVE_TAB_COLUMNS = 5
private let CREATIVE_TAB_H = 16.0
private let CREATIVE_PANEL_W = 280.0
private let CREATIVE_PANEL_H = 188.0
private let CREATIVE_GRID_COLUMNS = 9
private let CREATIVE_GRID_ROWS = 6
private let CREATIVE_SLOT_SIZE = 18.0

final class CreativeScreen: ContainerScreen {
    var tab = 0
    var scroll = 0
    let search = TextField(0, 0, 162, 14, "Search")
    var filtered: [Int] = []
    private weak var creativeCheckbox: CheckBox?
    private weak var characterButton: Button?

    override init() {
        super.init()
        panelW = CREATIVE_PANEL_W
        panelH = CREATIVE_PANEL_H
        title = ""
    }
    private var gridClusterW: Double {
        Double(CREATIVE_GRID_COLUMNS) * CREATIVE_SLOT_SIZE + 18
    }
    private var gridX: Double {
        panelX + ((panelW - gridClusterW) / 2).rounded(.down)
    }
    private var gridY: Double { panelY + 40 }
    private var scrollX: Double {
        gridX + Double(CREATIVE_GRID_COLUMNS) * CREATIVE_SLOT_SIZE + 8
    }
    private var hotbarY: Double { panelY + 160 }
    private var tabW: Double { panelW / Double(CREATIVE_TAB_COLUMNS) }
    private func tabRect(_ i: Int) -> (x: Double, y: Double, w: Double, h: Double) {
        let x = panelX + Double(i % CREATIVE_TAB_COLUMNS) * tabW
        let y = i < CREATIVE_TAB_COLUMNS ? panelY - CREATIVE_TAB_H : panelY + panelH
        return (x, y, tabW, CREATIVE_TAB_H)
    }
    private func maxScroll() -> Int {
        max(0, (filtered.count + CREATIVE_GRID_COLUMNS - 1) / CREATIVE_GRID_COLUMNS - CREATIVE_GRID_ROWS)
    }
    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        panelX = ((ui.width - panelW) / 2).rounded(.down)
        panelY = ((ui.height - panelH) / 2).rounded(.down)
        panelY = max(CREATIVE_TAB_H + 4, min(panelY, ui.height - panelH - CREATIVE_TAB_H - 4))
        search.x = gridX
        search.y = panelY + 20
        search.w = Double(CREATIVE_GRID_COLUMNS) * CREATIVE_SLOT_SIZE
        search.h = 14
        fields.append(search)
        let cb = CheckBox(panelX + panelW - 90, panelY + 4, 82, 18, "Creative", isChecked: { [weak game] in
            game?.player.gameMode == GameMode.creative
        }, { [weak ui, weak game] in
            guard let ui, let game else { return }
            game.player.setGameMode(GameMode.survival)
            ui.replace(InventoryScreen(), game)
        })
        creativeCheckbox = cb
        buttons.append(cb)
        if game.player.rpgClassesEnabled() {
            let character = Button(panelX + panelW - 176, panelY + 4, 82, 18, "Character", { [weak ui, weak game] in
                guard let ui, let game else { return }
                ui.open(RPGCharacterScreen(), game)
            })
            characterButton = character
            buttons.append(character)
        }
        playerSlots = []
        let p = game.player!
        for col in 0..<9 {
            let idx = col
            playerSlots.append(SlotDef(
                x: gridX + Double(col) * CREATIVE_SLOT_SIZE, y: hotbarY,
                get: { p.inventory[idx] },
                set: { p.inventory[idx] = $0 }))
        }
        refresh()
        slots = playerSlots
    }
    func refresh() {
        let cat = CREATIVE_TABS[tab].0
        let q = search.text.lowercased()
        filtered = []
        for i in 0..<itemDefs.count {
            let d = itemDefs[i]
            if !q.isEmpty {
                if d.name.contains(q) || d.displayName.lowercased().contains(q) { filtered.append(i) }
            } else if d.category == cat {
                filtered.append(i)
            }
        }
        scroll = min(scroll, maxScroll())
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.55)
        let cv = ui.cv
        if let cb = creativeCheckbox {
            cb.x = min(panelX + panelW - cb.w - 8, max(4, ui.width - cb.w - 4))
            cb.y = panelY + 4
        }
        if let characterButton {
            characterButton.visible = game.player.rpgClassesEnabled()
            characterButton.x = (creativeCheckbox?.x ?? (panelX + panelW - 90)) - characterButton.w - 6
            characterButton.y = panelY + 4
            if characterButton.x < panelX + 96 {
                characterButton.visible = false
            }
        }
        for i in 0..<CREATIVE_TABS.count {
            let (tx, ty, tw, th) = tabRect(i)
            cv.setFill(i == tab ? "#c6c6c6" : "#8a8a8a")
            cv.fillRect(tx, ty, tw - 1, th)
            cv.drawTextCentered(CREATIVE_TABS[i].1, tx + tw / 2, ty + 4, 1,
                                i == tab ? "#3f3f3f" : "#e8e8e8", shadow: false)
        }
        ui.drawPanel(panelX, panelY, panelW, panelH)
        cv.drawText(characterButton?.visible == true ? "Creative" : "Creative Inventory",
                    panelX + 10, panelY + 6, 1, "#3f3f3f", shadow: false)
        for row in 0..<CREATIVE_GRID_ROWS {
            for col in 0..<CREATIVE_GRID_COLUMNS {
                let gx = gridX + Double(col) * CREATIVE_SLOT_SIZE
                let gy = gridY + Double(row) * CREATIVE_SLOT_SIZE
                ui.drawSlotBg(gx, gy)
                let idx = (scroll + row) * CREATIVE_GRID_COLUMNS + col
                if idx < filtered.count {
                    let stack = ItemStack(filtered[idx], 1)
                    ui.drawItemStack(stack, gx, gy)
                    if ui.mouseX >= gx && ui.mouseX < gx + 18 && ui.mouseY >= gy && ui.mouseY < gy + 18 {
                        cv.setFill("rgba(255,255,255,0.45)")
                        cv.fillRect(gx + 1, gy + 1, 16, 16)
                        ui.tooltipLines = ui.itemTooltip(stack)
                    }
                }
            }
        }
        let maxScroll = maxScroll()
        cv.setFill("#1c1c1c")
        cv.fillRect(scrollX, gridY, 10, Double(CREATIVE_GRID_ROWS) * CREATIVE_SLOT_SIZE)
        let sf = maxScroll == 0 ? 0.0 : Double(scroll) / Double(maxScroll)
        cv.setFill("#c8c8c8")
        cv.fillRect(scrollX, gridY + (sf * 93).rounded(), 10, 15)
        ui.drawSlots(self)
        ui.drawButtons(self)
    }
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        for i in 0..<CREATIVE_TABS.count {
            let (tx, ty, tw, th) = tabRect(i)
            if mx >= tx && mx < tx + tw && my >= ty && my < ty + th {
                tab = i
                search.text = ""
                search.caret = 0
                refresh()
                return true
            }
        }
        if mx >= gridX && mx < gridX + Double(CREATIVE_GRID_COLUMNS) * CREATIVE_SLOT_SIZE &&
           my >= gridY && my < gridY + Double(CREATIVE_GRID_ROWS) * CREATIVE_SLOT_SIZE {
            let col = Int((mx - gridX) / CREATIVE_SLOT_SIZE)
            let row = Int((my - gridY) / CREATIVE_SLOT_SIZE)
            let idx = (scroll + row) * CREATIVE_GRID_COLUMNS + col
            if ui.cursorStack != nil {
                ui.cursorStack = nil // destroy
            } else if idx < filtered.count {
                let id = filtered[idx]
                ui.cursorStack = ItemStack(id, btn == 2 ? 1 : maxStackOf(ItemStack(id, 1)))
            }
            return true
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }
    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        let maxScroll = maxScroll()
        scroll = max(0, min(maxScroll, scroll + (dy > 0 ? 1 : -1)))
        return true
    }
    override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        let r = super.onChar(ui, game, ch)
        if r { refresh() }
        return r
    }
    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        let r = super.onKey(ui, game, key)
        if r { refresh() }
        return r
    }
}

// =============================================================================
// Sign editing
// =============================================================================
final class SignScreen: Screen {
    var lines = ["", "", "", ""]
    var lineIdx = 0
    private let be: BlockEntityData?
    private let pos: (x: Int, y: Int, z: Int)

    init(_ be: BlockEntityData?, _ pos: (x: Int, y: Int, z: Int)) {
        self.be = be
        self.pos = pos
        super.init()
        if let l = be?.lines { lines = l }
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.5)
        let w = 140.0, h = 80.0
        let px = ((ui.width - w) / 2).rounded(.down), py = ((ui.height - h) / 2).rounded(.down)
        let cv = ui.cv
        cv.setFill("#9a7444")
        cv.fillRect(px, py, w, h)
        cv.setFill("#85643a")
        cv.fillRect(px + 2, py + 2, w - 4, h - 4)
        for i in 0..<4 {
            let blink = i == lineIdx && Int(CACurrentMediaTime() * 1000 / 400) % 2 == 0 ? "_" : ""
            cv.drawTextCentered(lines[i] + blink, px + w / 2, py + 12 + Double(i) * 15, 1, "#1c1208", shadow: false)
        }
        cv.drawTextCentered("Press Enter / Esc to finish", px + w / 2, py + h + 8, 1)
    }
    override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        if textWidth(lines[lineIdx] + ch) < 90 {
            lines[lineIdx] += ch
        }
        return true
    }
    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        if key == "Backspace" {
            if !lines[lineIdx].isEmpty { lines[lineIdx].removeLast() }
            return true
        }
        if key == "Enter" || key == "ArrowDown" {
            lineIdx = (lineIdx + 1) % 4
            if key == "Enter" && lineIdx == 0 { ui.closeTop(game) }
            return true
        }
        if key == "ArrowUp" {
            lineIdx = (lineIdx + 3) % 4
            return true
        }
        return false
    }
    override func onClose(_ ui: UIManager, _ game: GameCore) {
        var sign = be
        if sign == nil {
            sign = makeSignBE(pos.x, pos.y, pos.z)
            game.world.setBlockEntity(sign!)
        }
        sign!.lines = lines
    }
}

// =============================================================================
// Death screen
// =============================================================================
final class DeathScreen: Screen {
    private let causeText: String

    init(_ causeText: String) {
        self.causeText = causeText
        super.init()
        closeOnEsc = false
    }
    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        let cx = (ui.width / 2).rounded(.down)
        buttons.append(Button(cx - 100, (ui.height / 2).rounded(.down), 200, 20, "Respawn", { [weak ui, weak game] in
            guard let ui, let game else { return }
            game.respawnPlayer()
            ui.closeAll(game)
        }))
        buttons.append(Button(cx - 100, (ui.height / 2).rounded(.down) + 24, 200, 20, "Title Screen", { [weak game] in
            game?.exitToTitle()
        }))
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.cv.setFill("rgba(120,0,0,0.45)")
        ui.cv.fillRect(0, 0, ui.width, ui.height)
        ui.cv.drawTextCentered("You Died!", ui.width / 2, ui.height / 2 - 50, 3)
        ui.cv.drawTextCentered(causeText, ui.width / 2, ui.height / 2 - 24, 1)
        ui.cv.drawTextCentered("Score: §e\(game.player.xpLevel * 7)", ui.width / 2, ui.height / 2 - 12, 1)
        ui.drawButtons(self)
    }
}

// =============================================================================
// Saved construction templates
// =============================================================================
final class TemplateNameScreen: Screen {
    private let target: (x: Int, y: Int, z: Int)
    private weak var nameField: TextField?
    private var errorMessage: String?

    init(target: (x: Int, y: Int, z: Int)) {
        self.target = target
        super.init()
        pausesGame = true
    }

    private func frame(_ ui: UIManager) -> (x: Double, y: Double, w: Double, h: Double) {
        let w = max(230, min(320, ui.width - 28))
        let h = 118.0
        return (((ui.width - w) / 2).rounded(.down), ((ui.height - h) / 2).rounded(.down), w, h)
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        let f = frame(ui)
        let field = TextField(f.x + 16, f.y + 48, f.w - 32, 20, "template name")
        field.maxLength = OBJECT_TEMPLATE_NAME_MAX
        field.focused = true
        nameField = field
        fields.append(field)
        buttons.append(Button(f.x + f.w - 140, f.y + f.h - 30, 60, 20, "Save", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            self.save(ui, game)
        }))
        buttons.append(Button(f.x + f.w - 74, f.y + f.h - 30, 60, 20, "Cancel", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
            game.host?.capturePointer()
        }))
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        let f = frame(ui)
        ui.drawDarkBg(0.58)
        ui.drawPanel(f.x, f.y, f.w, f.h)
        ui.cv.drawText("Copy Object", f.x + 16, f.y + 12, 1, "#3f3f3f", shadow: false)
        ui.cv.drawText("Target: \(target.x) \(target.y) \(target.z)", f.x + 16, f.y + 28, 1, "#606060", shadow: false)
        if let errorMessage {
            ui.cv.drawText(fitDialogText(errorMessage, maxWidth: Int(f.w - 32)), f.x + 16, f.y + 74, 1, "#a02020", shadow: false)
        } else {
            ui.cv.drawText("Name", f.x + 16, f.y + 38, 1, "#606060", shadow: false)
        }
        ui.drawButtons(self)
    }

    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        switch key {
        case "Enter", "NumpadEnter":
            save(ui, game)
            return true
        default:
            if super.onKey(ui, game, key) {
                errorMessage = nil
                return true
            }
            return false
        }
    }

    override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        if super.onChar(ui, game, ch) {
            errorMessage = nil
            return true
        }
        return false
    }

    private func save(_ ui: UIManager, _ game: GameCore) {
        let rawName = nameField?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawName.isEmpty else {
            errorMessage = "Enter a template name."
            return
        }
        do {
            let result = try cloneObjectTemplate(named: rawName, from: game.world,
                                                 targetX: target.x, targetY: target.y, targetZ: target.z)
            guard try game.db.putTemplate(result.template) else {
                errorMessage = "Template store write failed."
                return
            }
            let details = "\(result.template.blocks.count) blocks, \(result.template.blockEntities.count) block entities, \(result.template.sizeX)x\(result.template.sizeY)x\(result.template.sizeZ)"
            game.host?.pushChat("§7Copied object \"\(result.template.name)\" - \(details)")
            game.host?.showActionBar("Copied \"\(result.template.name)\"", 80)
            ui.closeTop(game)
            game.host?.capturePointer()
        } catch let error as TemplateError {
            errorMessage = error.description
        } catch {
            errorMessage = "Copy failed: \(error)"
        }
    }

    private func fitDialogText(_ text: String, maxWidth: Int) -> String {
        var out = text
        while textWidth(out) > maxWidth, out.count > 3 {
            out.removeLast()
        }
        return out.count < text.count && out.count > 3 ? out + "." : out
    }
}

private struct TemplateBrowserEntry {
    let name: String
    var template: ObjectTemplate?
    var summary: ObjectTemplateSummary?
    var previewBoxes: [ObjectTemplatePreviewBox]?
    var error: String?
}

private struct TemplatePreviewFace {
    let points: [(Double, Double)]
    let depth: Double
    let color: String
}

private let TEMPLATE_PREVIEW_MAX_BLOCKS = 4096

enum TemplateBrowserMode {
    case browse
    case place
}

final class TemplateBrowserScreen: Screen {
    private let mode: TemplateBrowserMode
    private var entries: [TemplateBrowserEntry] = []
    private var selectedIndex = 0
    private var scroll = 0
    private var yaw = 0.7
    private var pitch = 0.45
    private var draggingPreview = false
    private var lastDragX = 0.0
    private var lastDragY = 0.0
    private var lastVisibleRows = 1
    private weak var deleteButton: Button?
    private weak var placeButton: Button?
    private weak var leftButton: Button?
    private weak var rightButton: Button?
    private weak var closeButton: Button?

    override convenience init() {
        self.init(mode: .browse)
    }

    init(mode: TemplateBrowserMode) {
        self.mode = mode
        super.init()
        pausesGame = true
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        refreshEntries(game)
        let delete = Button(0, 0, 90, 20, "Delete", { [weak self, weak game] in
            guard let self, let game else { return }
            self.deleteSelected(game)
        })
        let place = Button(0, 0, 60, 20, "Place", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            self.placeSelected(ui, game)
        })
        let left = Button(0, 0, 24, 20, "<", { [weak self] in
            self?.yaw -= 0.18
        })
        let right = Button(0, 0, 24, 20, ">", { [weak self] in
            self?.yaw += 0.18
        })
        let close = Button(0, 0, 56, 20, "Close", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        })
        deleteButton = delete
        placeButton = place
        leftButton = left
        rightButton = right
        closeButton = close
        if mode == .place {
            buttons.append(contentsOf: [delete, place, left, right, close])
        } else {
            buttons.append(contentsOf: [delete, left, right, close])
        }
    }

    private func refreshEntries(_ game: GameCore) {
        let previousName = selectedEntry?.name
        let summaries = Dictionary(uniqueKeysWithValues: game.db.listTemplateSummaries().map { ($0.name, $0) })
        entries = game.db.listTemplates().map { name in
            TemplateBrowserEntry(name: name, template: nil, summary: summaries[name], previewBoxes: nil,
                                 error: summaries[name] == nil ? "Unable to summarize template" : nil)
        }
        if entries.isEmpty {
            selectedIndex = 0
        } else if let previousName, let idx = entries.firstIndex(where: { $0.name == previousName }) {
            selectedIndex = idx
        } else {
            selectedIndex = min(selectedIndex, entries.count - 1)
        }
        scroll = min(scroll, maxScroll(lastVisibleRows))
    }

    private func frame(_ ui: UIManager) -> (x: Double, y: Double, w: Double, h: Double) {
        let w = max(300, min(560, ui.width - 24))
        let h = max(210, min(310, ui.height - 24))
        return (((ui.width - w) / 2).rounded(.down), ((ui.height - h) / 2).rounded(.down), w, h)
    }

    private func listRect(_ ui: UIManager) -> (x: Double, y: Double, w: Double, h: Double) {
        let f = frame(ui)
        let w = min(190.0, max(132.0, f.w * 0.36))
        return (f.x + 10, f.y + 30, w, f.h - 66)
    }

    private func previewRect(_ ui: UIManager) -> (x: Double, y: Double, w: Double, h: Double) {
        let f = frame(ui)
        let l = listRect(ui)
        return (l.x + l.w + 10, f.y + 30, f.x + f.w - (l.x + l.w + 20), f.h - 66)
    }

    private func layoutButtons(_ ui: UIManager) {
        let f = frame(ui)
        let l = listRect(ui)
        let p = previewRect(ui)
        let deleteW = mode == .place ? min(64, max(52, (l.w - 4) / 2)) : min(90, l.w)
        deleteButton?.x = l.x
        deleteButton?.y = f.y + f.h - 28
        deleteButton?.w = deleteW
        deleteButton?.enabled = selectedEntry != nil
        placeButton?.x = l.x + deleteW + 4
        placeButton?.y = f.y + f.h - 28
        placeButton?.w = max(52, l.w - deleteW - 4)
        placeButton?.enabled = selectedEntry?.summary != nil
        closeButton?.x = f.x + f.w - 66
        closeButton?.y = f.y + 6
        leftButton?.x = p.x + 4
        leftButton?.y = f.y + f.h - 28
        rightButton?.x = p.x + 32
        rightButton?.y = f.y + f.h - 28
        let hasPreview = selectedEntry?.summary != nil
        leftButton?.enabled = hasPreview
        rightButton?.enabled = hasPreview
    }

    private var selectedEntry: TemplateBrowserEntry? {
        entries.indices.contains(selectedIndex) ? entries[selectedIndex] : nil
    }

    private func ensureSelectedTemplateLoaded(_ game: GameCore) {
        guard entries.indices.contains(selectedIndex),
              entries[selectedIndex].template == nil,
              entries[selectedIndex].summary != nil else { return }
        do {
            guard let template = try game.db.getTemplate(named: entries[selectedIndex].name) else {
                entries[selectedIndex].error = "Missing template data"
                entries[selectedIndex].summary = nil
                return
            }
            entries[selectedIndex].template = template
            entries[selectedIndex].previewBoxes = try objectTemplatePreviewBoxes(for: template, maxBoxes: TEMPLATE_PREVIEW_MAX_BLOCKS)
            if entries[selectedIndex].summary == nil {
                entries[selectedIndex].summary = try summarizeObjectTemplate(template)
            }
            entries[selectedIndex].error = nil
        } catch {
            entries[selectedIndex].template = nil
            entries[selectedIndex].previewBoxes = nil
            entries[selectedIndex].summary = nil
            entries[selectedIndex].error = String(describing: error)
        }
    }

    private func maxScroll(_ visibleRows: Int) -> Int {
        max(0, entries.count - max(1, visibleRows))
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ensureSelectedTemplateLoaded(game)
        layoutButtons(ui)
        let f = frame(ui)
        let l = listRect(ui)
        let p = previewRect(ui)
        let cv = ui.cv
        ui.drawDarkBg(0.6)
        ui.drawPanel(f.x, f.y, f.w, f.h)
        cv.drawText(mode == .place ? "Place Template" : "Saved Templates", f.x + 10, f.y + 10, 1, "#3f3f3f", shadow: false)
        drawTemplateList(ui, rect: l)
        drawTemplateDetails(ui, rect: p)
        ui.drawButtons(self)
    }

    private func drawTemplateList(_ ui: UIManager, rect: (x: Double, y: Double, w: Double, h: Double)) {
        let cv = ui.cv
        cv.setFill("#8b8b8b")
        cv.fillRect(rect.x, rect.y, rect.w, rect.h)
        cv.setFill("#1c1c1c")
        cv.fillRect(rect.x, rect.y, rect.w, 1)
        cv.fillRect(rect.x, rect.y, 1, rect.h)
        let rowH = 22.0
        let visibleRows = max(1, Int((rect.h - 2) / rowH))
        lastVisibleRows = visibleRows
        scroll = max(0, min(scroll, maxScroll(visibleRows)))
        if entries.isEmpty {
            cv.drawText("No saved templates", rect.x + 6, rect.y + 8, 1, "#303030", shadow: false)
            return
        }
        for row in 0..<visibleRows {
            let idx = scroll + row
            guard idx < entries.count else { break }
            let y = rect.y + 1 + Double(row) * rowH
            let selected = idx == selectedIndex
            let hover = ui.mouseX >= rect.x && ui.mouseX < rect.x + rect.w && ui.mouseY >= y && ui.mouseY < y + rowH
            cv.setFill(selected ? "#6f7dff" : hover ? "#9a9ac0" : (row % 2 == 0 ? "#b8b8b8" : "#ababab"))
            cv.fillRect(rect.x + 1, y, rect.w - 2, rowH)
            let entry = entries[idx]
            let name = fitTemplateText(entry.name, maxWidth: Int(rect.w - 10))
            cv.drawText(name, rect.x + 5, y + 4, 1, selected ? "#ffffff" : "#202020", shadow: false)
            if let summary = entry.summary {
                cv.drawText("\(summary.blockCount)b  \(summary.sizeX)x\(summary.sizeY)x\(summary.sizeZ)",
                            rect.x + 5, y + 13, 1, selected ? "#e8e8ff" : "#404040", shadow: false)
            } else {
                cv.drawText("Corrupt", rect.x + 5, y + 13, 1, selected ? "#ffd0d0" : "#802020", shadow: false)
            }
        }
        if entries.count > visibleRows {
            let trackH = rect.h - 4
            let thumbH = max(10, trackH * Double(visibleRows) / Double(entries.count))
            let denom = max(1, entries.count - visibleRows)
            let thumbY = rect.y + 2 + (trackH - thumbH) * Double(scroll) / Double(denom)
            cv.setFill("#555555")
            cv.fillRect(rect.x + rect.w - 5, rect.y + 2, 3, trackH)
            cv.setFill("#f0f0f0")
            cv.fillRect(rect.x + rect.w - 5, thumbY, 3, thumbH)
        }
    }

    private func drawTemplateDetails(_ ui: UIManager, rect: (x: Double, y: Double, w: Double, h: Double)) {
        let cv = ui.cv
        cv.setFill("#2b3038")
        cv.fillRect(rect.x, rect.y, rect.w, rect.h)
        cv.setStroke("#101218")
        cv.strokeRect(rect.x, rect.y, rect.w, rect.h)
        guard let entry = selectedEntry else {
            cv.drawTextCentered("No template selected", rect.x + rect.w / 2, rect.y + rect.h / 2 - 4, 1)
            return
        }
        if let summary = entry.summary {
            cv.drawText(fitTemplateText(summary.name, maxWidth: Int(rect.w - 12)), rect.x + 6, rect.y + 6, 1)
            cv.drawText("\(summary.blockCount) blocks  \(summary.blockEntityCount) data blocks  \(summary.sizeX)x\(summary.sizeY)x\(summary.sizeZ)",
                        rect.x + 6, rect.y + 16, 1, "#c8c8c8", shadow: false)
            cv.drawText(fitTemplateText(summary.dominantBlockDisplayName, maxWidth: Int(rect.w - 12)),
                        rect.x + 6, rect.y + 26, 1, "#a8c8ff", shadow: false)
        } else {
            cv.drawText(fitTemplateText(entry.name, maxWidth: Int(rect.w - 12)), rect.x + 6, rect.y + 6, 1)
            cv.drawText("Corrupt template", rect.x + 6, rect.y + 16, 1, "#ff8080", shadow: false)
            cv.drawText(fitTemplateText(entry.error ?? "Unable to load", maxWidth: Int(rect.w - 12)),
                        rect.x + 6, rect.y + 26, 1, "#ffb0b0", shadow: false)
        }
        let modelRect = (x: rect.x + 6, y: rect.y + 40, w: rect.w - 12, h: rect.h - 48)
        cv.setFill("#15191f")
        cv.fillRect(modelRect.x, modelRect.y, modelRect.w, modelRect.h)
        cv.setStroke("#3f4654")
        cv.strokeRect(modelRect.x, modelRect.y, modelRect.w, modelRect.h)
        if let template = entry.template, let boxes = entry.previewBoxes {
            drawTemplatePreview(ui, template, boxes: boxes, rect: modelRect)
        } else {
            cv.drawTextCentered("No preview", modelRect.x + modelRect.w / 2, modelRect.y + modelRect.h / 2 - 4, 1, "#a8a8a8", shadow: false)
        }
    }

    private func selectEntry(_ index: Int) {
        guard entries.indices.contains(index) else { return }
        if index != selectedIndex {
            selectedIndex = index
            yaw = 0.7
            pitch = 0.45
        }
    }

    private func deleteSelected(_ game: GameCore) {
        guard let entry = selectedEntry else {
            game.host?.showActionBar("Select a saved template to delete", 60)
            return
        }
        do {
            guard try game.db.deleteTemplate(named: entry.name) else {
                game.host?.showActionBar("Template was already gone", 60)
                refreshEntries(game)
                return
            }
            game.host?.pushChat("§7Deleted object \"\(entry.name)\"")
            game.host?.showActionBar("Deleted \"\(entry.name)\"", 60)
            let nextIndex = min(selectedIndex, max(0, entries.count - 2))
            selectedIndex = nextIndex
            refreshEntries(game)
            yaw = 0.7
            pitch = 0.45
        } catch let error as TemplateError {
            game.host?.pushChat("§c" + error.description)
            game.host?.showActionBar(error.description, 70)
        } catch {
            game.host?.pushChat("§cDelete failed: \(error)")
            game.host?.showActionBar("Delete failed", 70)
        }
    }

    private func placeSelected(_ ui: UIManager, _ game: GameCore) {
        ensureSelectedTemplateLoaded(game)
        guard let entry = selectedEntry else {
            game.host?.showActionBar("Select a saved template to place", 60)
            return
        }
        guard let template = entry.template else {
            game.host?.showActionBar("Cannot place corrupt template", 70)
            return
        }
        do {
            try game.beginTemplatePlacement(template)
            game.host?.pushChat("§7Placing object \"\(template.name)\" - scroll to rotate, left click to place")
        } catch let error as TemplateError {
            game.host?.pushChat("§c" + error.description)
            game.host?.showActionBar(error.description, 70)
        } catch {
            game.host?.pushChat("§cPlace failed: \(error)")
            game.host?.showActionBar("Place failed", 70)
        }
    }

    private func fitTemplateText(_ text: String, maxWidth: Int) -> String {
        var out = text
        while textWidth(out) > maxWidth, out.count > 3 {
            out.removeLast()
        }
        return out.count < text.count && out.count > 3 ? out + "." : out
    }

    private func drawTemplatePreview(_ ui: UIManager, _ template: ObjectTemplate,
                                     boxes: [ObjectTemplatePreviewBox],
                                     rect: (x: Double, y: Double, w: Double, h: Double)) {
        let cv = ui.cv
        let sx = max(1.0, Double(template.sizeX))
        let sy = max(1.0, Double(template.sizeY))
        let sz = max(1.0, Double(template.sizeZ))
        let scale = max(2.0, min(18.0, min(rect.w / max(1.0, sx + sz + 2), rect.h / max(1.0, sy + (sx + sz) * 0.45 + 2))))
        let cx = rect.x + rect.w / 2
        let cy = rect.y + rect.h / 2 + sy * scale * 0.18
        let cYaw = Foundation.cos(yaw), sYaw = Foundation.sin(yaw)
        let cPitch = Foundation.cos(pitch), sPitch = Foundation.sin(pitch)
        let centerX = sx / 2, centerY = sy / 2, centerZ = sz / 2

        func project(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let mx = x - centerX, my = y - centerY, mz = z - centerZ
            let rx = mx * cYaw - mz * sYaw
            let rz = mx * sYaw + mz * cYaw
            let ry = my * cPitch - rz * sPitch
            let depth = my * sPitch + rz * cPitch
            return (cx + rx * scale, cy - ry * scale, depth)
        }

        let faces = makePreviewFaces(boxes: boxes, project: project)
        for face in faces.sorted(by: { $0.depth < $1.depth }) {
            guard face.points.count == 4 else { continue }
            cv.setFill(face.color)
            cv.fillQuad(face.points[0].0, face.points[0].1,
                        face.points[1].0, face.points[1].1,
                        face.points[2].0, face.points[2].1,
                        face.points[3].0, face.points[3].1)
        }
        drawPreviewBounds(cv, template, project: project)
        if boxes.count >= TEMPLATE_PREVIEW_MAX_BLOCKS && template.blocks.count > boxes.count {
            cv.drawText("\(boxes.count) preview boxes", rect.x + 4, rect.y + rect.h - 12, 1, "#a8a8a8", shadow: false)
        }
    }

    private func makePreviewFaces(boxes: [ObjectTemplatePreviewBox],
                                  project: (Double, Double, Double) -> (Double, Double, Double)) -> [TemplatePreviewFace] {
        let faceDefs: [(Double, (ObjectTemplatePreviewBox) -> [(Double, Double, Double)])] = [
            (1.18, { b in [(b.x0, b.y1, b.z0), (b.x1, b.y1, b.z0), (b.x1, b.y1, b.z1), (b.x0, b.y1, b.z1)] }),
            (0.54, { b in [(b.x0, b.y0, b.z0), (b.x0, b.y0, b.z1), (b.x1, b.y0, b.z1), (b.x1, b.y0, b.z0)] }),
            (0.92, { b in [(b.x0, b.y0, b.z1), (b.x0, b.y1, b.z1), (b.x1, b.y1, b.z1), (b.x1, b.y0, b.z1)] }),
            (0.76, { b in [(b.x0, b.y0, b.z0), (b.x1, b.y0, b.z0), (b.x1, b.y1, b.z0), (b.x0, b.y1, b.z0)] }),
            (0.98, { b in [(b.x1, b.y0, b.z0), (b.x1, b.y0, b.z1), (b.x1, b.y1, b.z1), (b.x1, b.y1, b.z0)] }),
            (0.72, { b in [(b.x0, b.y0, b.z0), (b.x0, b.y1, b.z0), (b.x0, b.y1, b.z1), (b.x0, b.y0, b.z1)] }),
        ]
        var faces: [TemplatePreviewFace] = []
        faces.reserveCapacity(boxes.count * 6)
        for box in boxes {
            let id = Int(box.cell >> 4)
            guard id > 0, id < blockDefs.count else { continue }
            let base = templateBlockHSL(blockDefs[id].name)
            for face in faceDefs {
                let projected = face.1(box).map { project($0.0, $0.1, $0.2) }
                let depth = projected.reduce(0.0) { $0 + $1.2 } / Double(projected.count)
                let color = templateHSLString(base.0, base.1, max(18, min(78, base.2 * face.0)))
                faces.append(TemplatePreviewFace(points: projected.map { ($0.0, $0.1) }, depth: depth, color: color))
            }
        }
        return faces
    }

    private func drawPreviewBounds(_ cv: UICanvas, _ template: ObjectTemplate,
                                   project: (Double, Double, Double) -> (Double, Double, Double)) {
        let sx = Double(template.sizeX), sy = Double(template.sizeY), sz = Double(template.sizeZ)
        let corners = [
            project(0, 0, 0), project(sx, 0, 0), project(sx, sy, 0), project(0, sy, 0),
            project(0, 0, sz), project(sx, 0, sz), project(sx, sy, sz), project(0, sy, sz)
        ]
        let edges = [(0, 1), (1, 2), (2, 3), (3, 0), (4, 5), (5, 6), (6, 7), (7, 4), (0, 4), (1, 5), (2, 6), (3, 7)]
        cv.setStroke("rgba(255,255,255,0.22)")
        for edge in edges {
            cv.line(corners[edge.0].0, corners[edge.0].1, corners[edge.1].0, corners[edge.1].1, 0.75)
        }
    }

    private func templateBlockHSL(_ name: String) -> (Double, Double, Double) {
        if name.contains("leaves") || name.contains("moss") { return (118, 38, 34) }
        if name.contains("grass") { return (98, 42, 38) }
        if name.contains("dirt") || name.contains("mud") { return (28, 42, 33) }
        if name.contains("sand") || name.contains("birch") || name.contains("bamboo") { return (45, 44, 58) }
        if name.contains("oak") || name.contains("spruce") || name.contains("jungle") || name.contains("mangrove") || name.contains("cherry") { return (31, 42, 45) }
        if name.contains("stone") || name.contains("deepslate") || name.contains("andesite") || name.contains("diorite") || name.contains("granite") { return (0, 0, 46) }
        if name.contains("copper") { return (25, 58, 48) }
        if name.contains("iron") { return (210, 8, 66) }
        if name.contains("gold") { return (48, 72, 54) }
        if name.contains("diamond") || name.contains("prismarine") { return (178, 46, 48) }
        if name.contains("redstone") || name.contains("brick") { return (6, 58, 42) }
        if name.contains("glass") { return (195, 34, 62) }
        var h = 0
        for scalar in name.unicodeScalars {
            h = (h &* 31 &+ Int(scalar.value)) & 0x7fffffff
        }
        return (Double(h % 360), 34, 45)
    }

    private func templateHSLString(_ h: Double, _ s: Double, _ l: Double) -> String {
        "hsl(\(Int(h)), \(Int(s)), \(Int(l)))"
    }

    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        layoutButtons(ui)
        if super.onMouseDown(ui, game, mx, my, btn) { return true }
        let l = listRect(ui)
        let rowH = 22.0
        if mx >= l.x && mx < l.x + l.w && my >= l.y && my < l.y + l.h {
            let idx = scroll + Int((my - l.y - 1) / rowH)
            if entries.indices.contains(idx) {
                selectEntry(idx)
                return true
            }
        }
        let p = previewRect(ui)
        if selectedEntry?.template != nil, mx >= p.x && mx < p.x + p.w && my >= p.y && my < p.y + p.h {
            draggingPreview = true
            lastDragX = mx
            lastDragY = my
            return true
        }
        return false
    }

    override func onMouseMove(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        guard draggingPreview else { return }
        yaw += (mx - lastDragX) * 0.012
        pitch = max(-0.95, min(0.95, pitch + (my - lastDragY) * 0.008))
        lastDragX = mx
        lastDragY = my
    }

    override func onMouseUp(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        draggingPreview = false
    }

    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        let maxS = maxScroll(lastVisibleRows)
        guard maxS > 0 else { return false }
        scroll = max(0, min(maxS, scroll + (dy > 0 ? 1 : -1)))
        return true
    }

    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        switch key {
        case "Enter", "NumpadEnter":
            if mode == .place {
                placeSelected(ui, game)
            }
            return true
        case "ArrowUp":
            if !entries.isEmpty {
                selectEntry(max(0, selectedIndex - 1))
                scroll = min(scroll, selectedIndex)
            }
            return true
        case "ArrowDown":
            if !entries.isEmpty {
                selectEntry(min(entries.count - 1, selectedIndex + 1))
                if selectedIndex >= scroll + lastVisibleRows { scroll = selectedIndex - lastVisibleRows + 1 }
            }
            return true
        case "ArrowLeft":
            yaw -= 0.18
            return true
        case "ArrowRight":
            yaw += 0.18
            return true
        default:
            return false
        }
    }
}

// =============================================================================
// Map
// =============================================================================
final class MapScreen: Screen {
    private var dragging = false

    override init() {
        super.init()
        closeOnEsc = true
        pausesGame = false
        showHUD = false
    }

    private func mapRect(_ ui: UIManager) -> MapOverlayRect {
        mapExpandedRect(screenWidth: ui.width, screenHeight: ui.height)
    }

    private func clampedFocus(_ ui: UIManager, _ rect: MapOverlayRect) -> (Double, Double) {
        (min(max(ui.mouseX, rect.x), rect.x + rect.size),
         min(max(ui.mouseY, rect.y), rect.y + rect.size))
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        let r = mapRect(ui)
        ui.mouseX = r.midX
        ui.mouseY = r.midY
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.46)
        let bounds = game.loadedMapBounds()
        let viewport = clampedMapViewport(MapViewport(centerX: game.expandedMapCenterX,
                                                      centerZ: game.expandedMapCenterZ,
                                                      spanBlocks: game.mapSpanBlocks),
                                          bounds: bounds)
        drawMapOverlay(ui, game, rect: mapRect(ui), viewport: viewport, expanded: true, bounds: bounds)
    }

    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        let r = mapRect(ui)
        if btn == 0, mx >= r.x, mx < r.x + r.size, my >= r.y, my < r.y + r.size {
            dragging = true
        }
        return true
    }

    override func onMouseMove(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        guard dragging else { return }
        let r = mapRect(ui)
        let bounds = game.loadedMapBounds()
        let current = clampedMapViewport(MapViewport(centerX: game.expandedMapCenterX,
                                                     centerZ: game.expandedMapCenterZ,
                                                     spanBlocks: game.mapSpanBlocks),
                                         bounds: bounds)
        let next = mapPannedViewport(current,
                                     screenDX: mx - ui.mouseX,
                                     screenDY: my - ui.mouseY,
                                     rect: r,
                                     bounds: bounds)
        game.setExpandedMapViewport(next)
    }

    override func onMouseUp(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        dragging = false
    }

    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        let r = mapRect(ui)
        if key == "KeyM" {
            ui.closeTop(game)
            return true
        }
        if key == "Comma" || key == "Period" {
            let focus = clampedFocus(ui, r)
            let bounds = game.loadedMapBounds()
            let current = clampedMapViewport(MapViewport(centerX: game.expandedMapCenterX,
                                                         centerZ: game.expandedMapCenterZ,
                                                         spanBlocks: game.mapSpanBlocks),
                                             bounds: bounds)
            let next = mapZoomedViewport(current,
                                         zoomIn: key == "Period",
                                         focusScreenX: focus.0,
                                         focusScreenY: focus.1,
                                         rect: r,
                                         bounds: bounds)
            game.setExpandedMapViewport(next)
            return true
        }
        let pan = game.expandedMapViewport().spanBlocks * 0.08
        switch key {
        case "ArrowLeft":
            game.setExpandedMapViewport(MapViewport(centerX: game.expandedMapCenterX - pan,
                                                    centerZ: game.expandedMapCenterZ,
                                                    spanBlocks: game.mapSpanBlocks))
            return true
        case "ArrowRight":
            game.setExpandedMapViewport(MapViewport(centerX: game.expandedMapCenterX + pan,
                                                    centerZ: game.expandedMapCenterZ,
                                                    spanBlocks: game.mapSpanBlocks))
            return true
        case "ArrowUp":
            game.setExpandedMapViewport(MapViewport(centerX: game.expandedMapCenterX,
                                                    centerZ: game.expandedMapCenterZ - pan,
                                                    spanBlocks: game.mapSpanBlocks))
            return true
        case "ArrowDown":
            game.setExpandedMapViewport(MapViewport(centerX: game.expandedMapCenterX,
                                                    centerZ: game.expandedMapCenterZ + pan,
                                                    spanBlocks: game.mapSpanBlocks))
            return true
        default:
            return false
        }
    }

    override func onClose(_ ui: UIManager, _ game: GameCore) {
        dragging = false
    }
}

// =============================================================================
// Chat / command screen + chat log
// =============================================================================
struct ChatMessage {
    var text: String
    var time: Double
}
var chatLog: [ChatMessage] = []
func pushChat(_ text: String) {
    chatLog.append(ChatMessage(text: text, time: CACurrentMediaTime() * 1000))
    if chatLog.count > 100 { chatLog.removeFirst() }
}

private let chatLineHeight = 10.0

private func openChatTextWidth(_ ui: UIManager) -> Int {
    max(24, Int(ui.width - 8))
}

private func overlayChatTextWidth(_ ui: UIManager) -> Int {
    max(24, Int(min(ui.width - 8, max(160, ui.width * 0.65))))
}

private func wrappedChatLines(_ maxWidth: Int) -> [String] {
    chatLog.flatMap { wrapText($0.text, maxWidth) }
}

private func drawChatLine(_ cv: UICanvas, _ line: String, _ x: Double, _ y: Double, _ maxWidth: Int) {
    cv.setFill("rgba(0,0,0,0.5)")
    cv.fillRect(x - 2, y - 1, min(Double(maxWidth) + 4, Double(textWidth(line)) + 4), chatLineHeight)
    cv.drawText(line, x, y, 1)
}

final class ChatScreen: Screen {
    var input = ""
    var historyIdx = -1
    static var history: [String] = []
    private let runCommandFn: (String) -> Void
    private var scrollLines = 0
    private var completionBaseInput: String?
    private var completionLastInput: String?
    private var completionMatches: [String] = []
    private var completionIndex: Int?

    init(_ runCommand: @escaping (String) -> Void, _ prefill: String = "") {
        runCommandFn = runCommand
        input = prefill
        super.init()
    }
    private func resetCompletion() {
        completionBaseInput = nil
        completionLastInput = nil
        completionMatches.removeAll()
        completionIndex = nil
    }
    private func inputLines(_ ui: UIManager, blink: String = "") -> [String] {
        let lines = wrapText(input + blink, openChatTextWidth(ui))
        return lines.isEmpty ? [blink] : Array(lines.suffix(4))
    }
    private func visibleOutputLineCount(_ ui: UIManager) -> Int {
        let inputHeight = Double(inputLines(ui, blink: "_").count) * chatLineHeight + 4
        return max(0, Int((ui.height - inputHeight - 18) / chatLineHeight))
    }
    private func maxScroll(_ ui: UIManager) -> Int {
        max(0, wrappedChatLines(openChatTextWidth(ui)).count - visibleOutputLineCount(ui))
    }
    private func clampScroll(_ ui: UIManager) {
        scrollLines = max(0, min(scrollLines, maxScroll(ui)))
    }
    private func completeInput() -> Bool {
        let base: String
        let cycle: Int?
        if let completionBaseInput, input == completionLastInput, !completionMatches.isEmpty {
            let next = ((completionIndex ?? -1) + 1) % completionMatches.count
            base = completionBaseInput
            cycle = next
        } else {
            base = input
            cycle = nil
        }
        guard let result = completeCommandLineItem(input: base, cycleIndex: cycle) else {
            resetCompletion()
            return true
        }
        completionBaseInput = base
        completionLastInput = result.completedInput
        completionMatches = result.matches
        completionIndex = result.selectedIndex
        input = result.completedInput
        return true
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        let cv = ui.cv
        let width = openChatTextWidth(ui)
        let blink = Int(CACurrentMediaTime() * 1000 / 400) % 2 == 0 ? "_" : ""
        let inputWrapped = inputLines(ui, blink: blink)
        let inputHeight = Double(inputWrapped.count) * chatLineHeight + 4
        let outputBottom = ui.height - inputHeight - 8
        let visibleCount = max(0, Int((outputBottom - 4) / chatLineHeight))
        let lines = wrappedChatLines(width)
        let maxScroll = max(0, lines.count - visibleCount)
        scrollLines = max(0, min(scrollLines, maxScroll))
        if visibleCount > 0 && !lines.isEmpty {
            let end = max(0, lines.count - scrollLines)
            let start = max(0, end - visibleCount)
            let visible = Array(lines[start..<end])
            let topY = outputBottom - Double(visible.count) * chatLineHeight
            for (i, line) in visible.enumerated() {
                drawChatLine(cv, line, 4, topY + Double(i) * chatLineHeight + 1, width)
            }
            if maxScroll > 0 {
                let thumbH = max(10.0, (outputBottom - 4) * Double(visibleCount) / Double(lines.count))
                let trackH = max(thumbH, outputBottom - 4)
                let thumbY = 2 + (trackH - thumbH) * (1 - Double(scrollLines) / Double(maxScroll))
                cv.setFill("rgba(255,255,255,0.35)")
                cv.fillRect(ui.width - 4, thumbY, 2, thumbH)
            }
        }
        cv.setFill("rgba(0,0,0,0.6)")
        cv.fillRect(2, ui.height - inputHeight - 2, ui.width - 4, inputHeight)
        for (i, line) in inputWrapped.enumerated() {
            cv.drawText(line, 4, ui.height - inputHeight + 1 + Double(i) * chatLineHeight, 1)
        }
    }
    override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        input += ch
        resetCompletion()
        return true
    }
    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        if key == "Backspace" {
            if !input.isEmpty { input.removeLast() }
            resetCompletion()
            return true
        }
        if key == "Tab" { return completeInput() }
        if key == "Enter" {
            if !input.trimmingCharacters(in: .whitespaces).isEmpty {
                let submitted = input
                ChatScreen.history.append(submitted)
                resetCompletion()
                ui.closeTop(game)
                runCommandFn(submitted)
                return true
            }
            resetCompletion()
            ui.closeTop(game)
            return true
        }
        if key == "ArrowUp" {
            if !ChatScreen.history.isEmpty {
                historyIdx = historyIdx < 0 ? ChatScreen.history.count - 1 : max(0, historyIdx - 1)
                input = ChatScreen.history[historyIdx]
                resetCompletion()
            }
            return true
        }
        if key == "ArrowDown" {
            if historyIdx >= 0 {
                historyIdx = min(ChatScreen.history.count - 1, historyIdx + 1)
                input = ChatScreen.history[historyIdx]
                resetCompletion()
            }
            return true
        }
        return false
    }
    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        let step = 3
        if dy < 0 {
            scrollLines += step
        } else {
            scrollLines -= step
        }
        clampScroll(ui)
        return true
    }
}

/// draws recent chat while playing (no screen open)
func drawChatOverlay(_ ui: UIManager) {
    let now = CACurrentMediaTime() * 1000
    let cv = ui.cv
    var shown = 0
    var i = chatLog.count - 1
    let width = overlayChatTextWidth(ui)
    while i >= 0 && shown < 8 {
        let msg = chatLog[i]
        let age = now - msg.time
        if age > 8000 { break }
        let alpha = age > 6000 ? 1 - (age - 6000) / 2000 : 1
        let lines = wrapText(msg.text, width)
        for line in lines.reversed() {
            if shown >= 8 { break }
            let y = ui.height - 44 - Double(shown) * chatLineHeight
            cv.globalAlpha = Float(alpha)
            cv.setFill("rgba(0,0,0,0.45)")
            cv.fillRect(2, y, min(Double(width) + 4, Double(textWidth(line)) + 4), chatLineHeight)
            cv.drawText(line, 4, y + 1, 1)
            cv.globalAlpha = 1
            shown += 1
        }
        i -= 1
    }
}
