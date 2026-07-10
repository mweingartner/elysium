import Foundation
import PebbleCore

final class RPGCharacterScreen: Screen {
    private enum Tab: Int, CaseIterable {
        case overview
        case skills
        case spells
        case progression

        var label: String {
            switch self {
            case .overview: return "Overview"
            case .skills: return "Skills"
            case .spells: return "Spells"
            case .progression: return "Progress"
            }
        }
    }

    private var tab: Tab = .overview
    private var pathIndex = 0
    private var draftAttributes = RPGAttributes.defaultCreation
    private var starterSkillIndex = 0
    private var selectedStarterSpellIDs = Set<String>()
    private var selectedQuickSlotIndex = 0
    private var creationSpellScroll = 0.0
    private var appliedDebugCreationSelection = false
    private var skillScroll = 0.0
    private var spellScroll = 0.0
    private var statusText = ""
    private var buttonsBuiltForCreatedState: Bool?
    private var attrButtons: [(RPGAttributeID, Button, Button)] = []
    private var spendAttrButtons: [(RPGAttributeID, Button)] = []
    private weak var createButton: Button?
    private weak var closeButton: Button?
    private weak var prevPathButton: Button?
    private weak var nextPathButton: Button?
    private weak var prevStarterButton: Button?
    private weak var nextStarterButton: Button?
    private weak var nextActionButton: Button?
    private weak var useActionButton: Button?

    private struct CreationLayout {
        let footerY: Double
        let pathButtonY: Double
        let pathIconX: Double
        let pathIconY: Double
        let pathTitleY: Double
        let pathSummaryX: Double
        let pathSummaryY: Double
        let pathSummaryW: Int
        let pathSummaryLines: Int
        let attrHeaderY: Double
        let attrRowStartY: Double
        let attrMinusX: Double
        let attrValueX: Double
        let attrPlusX: Double
        let starterLabelY: Double
        let starterButtonY: Double
        let starterIconX: Double
        let starterIconY: Double
        let starterNameX: Double
        let starterNameW: Int
        let starterSummaryX: Double
        let starterSummaryY: Double
        let starterSummaryW: Int
        let starterSummaryLines: Int
        let spellsTitleY: Double
        let spellsListTop: Double
        let spellsListBottom: Double
        let spellsX: Double
        let spellsW: Double
        let spellRowH: Double
        let spellRowStride: Double
    }

    override init() {
        super.init()
        showHUD = true
        pausesGame = true
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        guard let player = game.player else { return }
        rebuildButtons(ui, game, created: player.rpg.created)
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.45)
        guard let player = game.player else { return }
        if buttonsBuiltForCreatedState != player.rpg.created {
            rebuildButtons(ui, game, created: player.rpg.created)
        }
        if player.rpg.created {
            drawSheet(ui, game)
        } else {
            drawCreation(ui, game)
        }
        ui.drawButtons(self)
    }

    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        if super.onMouseDown(ui, game, mx, my, btn) { return true }
        guard let player = game.player else { return false }
        if !player.rpg.created {
            return handleCreationClick(ui, game, mx, my)
        }
        if handleQuickSlotClick(ui, game, mx, my, btn) { return true }
        switch tab {
        case .skills:
            return handleSkillClick(ui, game, mx, my)
        case .spells:
            return handleSpellClick(ui, game, mx, my)
        default:
            return false
        }
    }

    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        if game.player?.rpg.created != true {
            let f = panel(ui)
            let path = RPG_PATH_DEFINITIONS[pathIndex]
            let layout = creationLayout(f, path: path)
            let total = Double(path.starterSpellIDs.count) * layout.spellRowStride
            let available = max(0, layout.spellsListBottom - layout.spellsListTop)
            let maxScroll = max(0, total - available)
            guard maxScroll > 0 else { return false }
            creationSpellScroll = max(0, min(maxScroll, creationSpellScroll + (dy >= 0 ? layout.spellRowStride : -layout.spellRowStride)))
            return true
        }
        switch tab {
        case .skills:
            skillScroll = max(0, skillScroll + dy * 12)
            return true
        case .spells:
            spellScroll = max(0, spellScroll + dy * 12)
            return true
        default:
            return false
        }
    }

    private func panel(_ ui: UIManager) -> (x: Double, y: Double, w: Double, h: Double) {
        let w = min(452.0, max(350.0, ui.width - 18))
        let h = min(268.0, max(224.0, ui.height - 14))
        return (((ui.width - w) / 2).rounded(.down), ((ui.height - h) / 2).rounded(.down), w, h)
    }

    private func buildCreationButtons(_ ui: UIManager, _ game: GameCore) {
        let f = panel(ui)
        applyDebugCreationSelectionIfNeeded()
        let path = RPG_PATH_DEFINITIONS[pathIndex]
        let layout = creationLayout(f, path: path)
        let create = Button(f.x + f.w - 72, layout.footerY, 58, 20, "Create", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            self.normalizeDraftSelection()
            let path = RPG_PATH_DEFINITIONS[self.pathIndex]
            let spells = path.starterSpellIDs.filter { self.selectedStarterSpellIDs.contains($0) }
            let skill = path.starterSkillIDs.indices.contains(self.starterSkillIndex)
                ? path.starterSkillIDs[self.starterSkillIndex] : path.starterSkillIDs.first
            let message = game.requestRPGCreateCharacter(RPGCreationDraft(
                pathID: path.id,
                attributes: self.draftAttributes,
                starterSkillID: skill,
                starterSpellIDs: spells
            ))
            self.setStatus(message, game: game)
            if game.player?.rpg.created == true {
                ui.replace(RPGCharacterScreen(), game)
            }
        })
        let close = Button(f.x + 14, layout.footerY, 58, 20, "Close", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        })
        let prevPath = Button(f.x + 14, layout.pathButtonY, 22, 18, "<", { [weak self] in self?.movePath(-1) })
        let nextPath = Button(f.x + f.w - 36, layout.pathButtonY, 22, 18, ">", { [weak self] in self?.movePath(1) })
        let prevStarter = Button(layout.starterSummaryX, layout.starterButtonY, 22, 18, "<", { [weak self] in self?.moveStarterSkill(-1) })
        let nextStarter = Button(f.x + f.w - 36, layout.starterButtonY, 22, 18, ">", { [weak self] in self?.moveStarterSkill(1) })
        createButton = create
        closeButton = close
        prevPathButton = prevPath
        nextPathButton = nextPath
        prevStarterButton = prevStarter
        nextStarterButton = nextStarter
        buttons.append(contentsOf: [create, close, prevPath, nextPath, prevStarter, nextStarter])

        attrButtons.removeAll()
        for (i, attr) in RPGAttributeID.allCases.enumerated() {
            let y = layout.attrRowStartY + Double(i) * 20
            let minus = Button(layout.attrMinusX, y, 18, 16, "-", { [weak self] in self?.adjustDraft(attr, -1) })
            let plus = Button(layout.attrPlusX, y, 18, 16, "+", { [weak self] in self?.adjustDraft(attr, 1) })
            attrButtons.append((attr, minus, plus))
            buttons.append(minus)
            buttons.append(plus)
        }
    }

    private func rebuildButtons(_ ui: UIManager, _ game: GameCore, created: Bool) {
        buttons.removeAll()
        sliders.removeAll()
        fields.removeAll()
        slots.removeAll()
        attrButtons.removeAll()
        spendAttrButtons.removeAll()
        createButton = nil
        closeButton = nil
        prevPathButton = nil
        nextPathButton = nil
        prevStarterButton = nil
        nextStarterButton = nil
        nextActionButton = nil
        useActionButton = nil
        buttonsBuiltForCreatedState = created
        if created {
            buildSheetButtons(ui, game)
        } else {
            normalizeDraftSelection()
            buildCreationButtons(ui, game)
        }
    }

    private func buildSheetButtons(_ ui: UIManager, _ game: GameCore) {
        let f = panel(ui)
        let tabW = min(82.0, (f.w - 34) / Double(Tab.allCases.count))
        for (i, t) in Tab.allCases.enumerated() {
            buttons.append(Button(f.x + 12 + Double(i) * tabW, f.y + 30, tabW - 2, 18, t.label, { [weak self] in
                self?.tab = t
            }))
        }
        buttons.append(Button(f.x + f.w - 72, f.y + f.h - 28, 58, 20, "Close", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        }))
        let next = Button(f.x + f.w - 132, f.y + f.h - 28, 54, 20, "Clear", { [weak self, weak game] in
            guard let self, let game else { return }
            self.setStatus(game.requestRPGClearActionQuickSlot(self.selectedQuickSlotIndex), game: game)
        })
        let use = Button(f.x + f.w - 200, f.y + f.h - 28, 62, 20, "Use Slot", { [weak self, weak game] in
            guard let self, let game else { return }
            self.setStatus(game.requestRPGUseActionQuickSlot(self.selectedQuickSlotIndex), game: game)
        })
        nextActionButton = next
        useActionButton = use
        buttons.append(next)
        buttons.append(use)
        spendAttrButtons.removeAll()
        for (i, attr) in RPGAttributeID.allCases.enumerated() {
            let y = f.y + 84 + Double(i) * 22
            let b = Button(f.x + 158, y, 22, 16, "+", { [weak self, weak game] in
                guard let self, let game else { return }
                self.setStatus(game.requestRPGSpendAttributePoint(attr), game: game)
            })
            spendAttrButtons.append((attr, b))
            buttons.append(b)
        }
    }

    private func drawCreation(_ ui: UIManager, _ game: GameCore) {
        let f = panel(ui)
        let cv = ui.cv
        let path = RPG_PATH_DEFINITIONS[pathIndex]
        let layout = creationLayout(f, path: path)
        updateCreationButtonLayout(layout, f: f, path: path)
        let remaining = RPGAttributes.creationBudget - draftAttributes.total
        ui.drawPanel(f.x, f.y, f.w, f.h)
        cv.drawText("Create Character", f.x + 12, f.y + 12, 1, "#3f3f3f", shadow: false)
        cv.drawRPGIcon(rpgAssetIDForPath(path.id), layout.pathIconX, layout.pathIconY, 24, 24)
        cv.drawTextCentered(path.displayName, f.x + f.w / 2, layout.pathTitleY, 1, "#202020", shadow: false)
        drawWrapped(cv, path.summary, layout.pathSummaryX, layout.pathSummaryY, layout.pathSummaryW, "#505050",
                    maxLines: layout.pathSummaryLines)
        cv.drawText("Attributes", f.x + 14, layout.attrHeaderY, 1, "#3f3f3f", shadow: false)
        cv.drawText("Pool \(remaining)", f.x + 104, layout.attrHeaderY, 1, remaining == 0 ? "#206020" : "#a04020", shadow: false)
        for (attr, minus, plus) in attrButtons {
            let value = draftAttributes.value(attr)
            minus.enabled = value > RPGAttributes.minimum
            plus.enabled = remaining > 0 && value < RPGAttributes.maximumAtCreation
            minus.y = layout.attrRowStartY + Double(RPGAttributeID.allCases.firstIndex(of: attr) ?? 0) * 20
            plus.y = minus.y
            minus.x = layout.attrMinusX
            plus.x = layout.attrPlusX
            cv.drawText(attributeShortLabel(attr), f.x + 18, minus.y + 4, 1, "#303030", shadow: false)
            cv.drawText(String(value), layout.attrValueX, minus.y + 4, 1, "#202020", shadow: false)
        }
        cv.drawText("Starter", layout.starterSummaryX, layout.starterLabelY, 1, "#3f3f3f", shadow: false)
        let starterSkill = path.starterSkillIDs.indices.contains(starterSkillIndex)
            ? path.starterSkillIDs[starterSkillIndex] : path.starterSkillIDs.first
        if let starterSkill, let def = rpgSkillDefinition(starterSkill) {
            cv.drawRPGIcon(rpgAssetIDForSkill(starterSkill), layout.starterIconX, layout.starterIconY, 18, 18)
            cv.drawText(fit(def.displayName, maxWidth: layout.starterNameW), layout.starterNameX, layout.starterIconY + 3, 1, "#202020", shadow: false)
            drawWrapped(cv, def.summary, layout.starterSummaryX, layout.starterSummaryY, layout.starterSummaryW, "#505050",
                        maxLines: layout.starterSummaryLines)
        }
        drawStarterSpells(ui, path: path, f: f, layout: layout)
        createButton?.enabled = remaining == 0
        if !statusText.isEmpty {
            cv.drawText(fit(statusText, maxWidth: Int(f.w - 96)), f.x + 78, f.y + f.h - 22, 1, "#a03030", shadow: false)
        }
    }

    private func drawSheet(_ ui: UIManager, _ game: GameCore) {
        guard let player = game.player else { return }
        player.rpg = repairRPGCharacterState(player.rpg)
        let f = panel(ui)
        let cv = ui.cv
        ui.drawPanel(f.x, f.y, f.w, f.h)
        cv.drawText("Character", f.x + 12, f.y + 12, 1, "#3f3f3f", shadow: false)
        updateSheetActionButtons(f: f, player: player)
        drawQuickSlotStrip(ui, player: player, f: f)
        for b in buttons where Tab.allCases.map(\.label).contains(b.label) {
            b.enabled = b.label != tab.label
        }
        for (_, b) in spendAttrButtons {
            b.visible = tab == .progression
            b.enabled = rpgAvailableAttributePoints(player.rpg) > 0
        }
        switch tab {
        case .overview:
            drawOverview(ui, player: player, f: f)
        case .skills:
            drawSkills(ui, player: player, f: f)
        case .spells:
            drawSpells(ui, player: player, f: f)
        case .progression:
            drawProgression(ui, player: player, f: f)
        }
        if !statusText.isEmpty {
            cv.drawText(fit(statusText, maxWidth: Int(f.w - 96)), f.x + 78, f.y + f.h - 22, 1, "#303030", shadow: false)
        }
    }

    private func drawOverview(_ ui: UIManager, player: Player, f: (x: Double, y: Double, w: Double, h: Double)) {
        let cv = ui.cv
        let state = player.rpg
        let path = rpgPathDefinition(state.pathID)
        let derived = rpgDerivedStats(state)
        let top = f.y + 58
        if let path {
            cv.drawRPGIcon(rpgAssetIDForPath(path.id), f.x + 18, top, 32, 32)
            cv.drawText(path.displayName, f.x + 58, top + 4, 1, "#202020", shadow: false)
            cv.drawText("Level \(state.level)", f.x + 58, top + 16, 1, "#505050", shadow: false)
            drawWrapped(cv, path.summary, f.x + 160, top + 2, Int(f.w - 176), "#505050", maxLines: 3)
        }
        drawBar(cv, x: f.x + 18, y: top + 50, w: f.w - 36, label: "XP",
                value: Double(state.xp - rpgXPRequiredForLevel(state.level)),
                maxValue: Double(max(1, rpgXPRequiredForLevel(min(RPG_LEVEL_CAP, state.level + 1)) - rpgXPRequiredForLevel(state.level))),
                fill: "#55aa55")
        drawBar(cv, x: f.x + 18, y: top + 68, w: f.w - 36, label: "Fatigue",
                value: state.fatigue, maxValue: derived.maxFatigue, fill: "#55aaff")
        let left = f.x + 20
        let right = f.x + f.w / 2 + 8
        let y = top + 94
        let colW = Int((f.w - 48) / 2)
        cv.drawText(fit("Health \(Int(player.health.rounded())) / \(Int(player.maxHealth.rounded()))", maxWidth: colW),
                    left, y, 1, "#303030", shadow: false)
        cv.drawText(fit("Skill Points \(rpgAvailableSkillPoints(state))", maxWidth: colW),
                    right, y, 1, "#303030", shadow: false)
        cv.drawText(fit("Attribute Points \(rpgAvailableAttributePoints(state))", maxWidth: colW),
                    left, y + 14, 1, "#303030", shadow: false)
        cv.drawText(fit("Prepared \(state.preparedSkillIDs.count) skills, \(state.preparedSpellIDs.count) spells", maxWidth: colW),
                    right, y + 14, 1, "#303030", shadow: false)
    }

    private func drawProgression(_ ui: UIManager, player: Player, f: (x: Double, y: Double, w: Double, h: Double)) {
        let cv = ui.cv
        let state = player.rpg
        cv.drawText("Attribute Points \(rpgAvailableAttributePoints(state))", f.x + 18, f.y + 60, 1, "#3f3f3f", shadow: false)
        for (attr, button) in spendAttrButtons {
            let value = state.attributes.value(attr)
            button.visible = tab == .progression
            button.enabled = rpgAvailableAttributePoints(state) > 0 && value < RPGAttributes.maximumWithProgression
            cv.drawText(attributeLabel(attr), f.x + 20, button.y + 4, 1, "#303030", shadow: false)
            cv.drawText(String(value), f.x + 122, button.y + 4, 1, "#202020", shadow: false)
        }
        let derived = rpgDerivedStats(state)
        let y = f.y + 196
        cv.drawText(fit("HP \(Int(derived.maxHealth))  Fatigue \(Int(derived.maxFatigue))  Regen \(String(format: "%.2f", derived.fatigueRegenPerTick * 20))/s",
                        maxWidth: Int(f.w - 40)),
                    f.x + 20, min(y, f.y + f.h - 44), 1, "#505050", shadow: false)
    }

    private func drawSkills(_ ui: UIManager, player: Player, f: (x: Double, y: Double, w: Double, h: Double)) {
        let cv = ui.cv
        let rows = skillRows(f, pathID: player.rpg.pathID)
        cv.drawText("Skill Points \(rpgAvailableSkillPoints(player.rpg))", f.x + 18, f.y + 56, 1, "#3f3f3f", shadow: false)
        for row in rows.visible {
            guard let skill = rpgSkillDefinition(row.id) else { continue }
            let known = (player.rpg.skillRanks[skill.id] ?? 0) > 0
            let prepared = player.rpg.preparedSkillIDs.contains(skill.id)
            cv.setFill(prepared ? "rgba(80,140,210,0.35)" : known ? "rgba(70,150,70,0.25)" : "rgba(0,0,0,0.18)")
            cv.fillRect(row.x, row.y, row.w, row.h)
            cv.drawRPGIcon(rpgAssetIDForSkill(skill.id), row.x + 3, row.y + 3, 16, 16)
            cv.drawText(fit(skill.displayName, maxWidth: 118), row.x + 24, row.y + 4, 1, known ? "#202020" : "#505050", shadow: false)
            let rank = player.rpg.skillRanks[skill.id] ?? 0
            cv.drawText(rank > 0 ? "\(rank)/3" : "-", row.x + 146, row.y + 4, 1, "#303030", shadow: false)
            let stateX = row.x + row.w - 62
            cv.drawText(skillRowState(skill, state: player.rpg), stateX, row.y + 4, 1, "#303030", shadow: false)
            cv.drawText(fit(skill.summary, maxWidth: Int(max(0, stateX - (row.x + 190) - 8))),
                        row.x + 190, row.y + 4, 1, "#606060", shadow: false)
        }
    }

    private func drawSpells(_ ui: UIManager, player: Player, f: (x: Double, y: Double, w: Double, h: Double)) {
        let cv = ui.cv
        let rows = spellRows(f)
        cv.drawText("Prepared \(player.rpg.preparedSpellIDs.count) / \(RPG_MAX_PREPARED_SPELLS)", f.x + 18, f.y + 56, 1, "#3f3f3f", shadow: false)
        for row in rows.visible {
            guard let spell = rpgSpellDefinition(row.id) else { continue }
            let known = player.rpg.knownSpellIDs.contains(spell.id)
            let prepared = player.rpg.preparedSpellIDs.contains(spell.id)
            cv.setFill(prepared ? "rgba(110,100,210,0.35)" : known ? "rgba(70,150,150,0.25)" : "rgba(0,0,0,0.12)")
            cv.fillRect(row.x, row.y, row.w, row.h)
            cv.drawRPGIcon(rpgAssetIDForSpell(spell.id), row.x + 3, row.y + 3, 16, 16)
            cv.drawText(fit(spell.displayName, maxWidth: 116), row.x + 24, row.y + 4, 1, known ? "#202020" : "#707070", shadow: false)
            cv.drawText("C\(spell.circle) F\(Int(spell.fatigueCost))", row.x + 146, row.y + 4, 1, "#303030", shadow: false)
            let stateX = row.x + row.w - 62
            cv.drawText(spellRowState(spell, state: player.rpg), stateX, row.y + 4, 1, "#303030", shadow: false)
            cv.drawText(fit(spell.summary, maxWidth: Int(max(0, stateX - (row.x + 190) - 8))),
                        row.x + 190, row.y + 4, 1, "#606060", shadow: false)
        }
    }

    private func drawStarterSpells(_ ui: UIManager, path: RPGPathDefinition,
                                   f: (x: Double, y: Double, w: Double, h: Double),
                                   layout: CreationLayout) {
        guard !path.starterSpellIDs.isEmpty else { return }
        let cv = ui.cv
        let x = layout.spellsX
        cv.drawText("Spells", x, layout.spellsTitleY, 1, "#3f3f3f", shadow: false)
        let total = Double(path.starterSpellIDs.count) * layout.spellRowStride
        let available = max(0, layout.spellsListBottom - layout.spellsListTop)
        creationSpellScroll = min(max(0, creationSpellScroll), max(0, total - available))
        for (i, spellID) in path.starterSpellIDs.enumerated() {
            guard let spell = rpgSpellDefinition(spellID) else { continue }
            let rowY = layout.spellsListTop + Double(i) * layout.spellRowStride - creationSpellScroll
            guard rowY >= layout.spellsListTop, rowY + layout.spellRowH <= layout.spellsListBottom else { continue }
            let selected = selectedStarterSpellIDs.contains(spellID)
            cv.setFill(selected ? "rgba(90,120,210,0.35)" : "rgba(0,0,0,0.12)")
            cv.fillRect(x, rowY, layout.spellsW, layout.spellRowH)
            cv.drawRPGIcon(rpgAssetIDForSpell(spellID), x + 2, rowY, 16, 16)
            cv.drawText(fit(spell.displayName, maxWidth: Int(layout.spellsW - 24)), x + 22, rowY + 4, 1, "#303030", shadow: false)
        }
        if total > available, available > 0 {
            drawScrollBar(cv, x: x + layout.spellsW - 4, y: layout.spellsListTop, h: available,
                          contentH: total, offset: creationSpellScroll)
        }
    }

    private func handleCreationClick(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) -> Bool {
        let f = panel(ui)
        let path = RPG_PATH_DEFINITIONS[pathIndex]
        let layout = creationLayout(f, path: path)
        guard !path.starterSpellIDs.isEmpty else { return false }
        for (i, spellID) in path.starterSpellIDs.enumerated() {
            let rowY = layout.spellsListTop + Double(i) * layout.spellRowStride - creationSpellScroll
            guard rowY >= layout.spellsListTop, rowY + layout.spellRowH <= layout.spellsListBottom else { continue }
            if mx >= layout.spellsX, mx < layout.spellsX + layout.spellsW, my >= rowY, my < rowY + layout.spellRowH {
                if selectedStarterSpellIDs.contains(spellID) {
                    selectedStarterSpellIDs.remove(spellID)
                } else {
                    selectedStarterSpellIDs.insert(spellID)
                }
                return true
            }
        }
        return false
    }

    private func handleSkillClick(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) -> Bool {
        guard let player = game.player else { return false }
        for row in skillRows(panel(ui), pathID: player.rpg.pathID).visible where mx >= row.x && mx < row.x + row.w && my >= row.y && my < row.y + row.h {
            guard let skill = rpgSkillDefinition(row.id) else { return false }
            let known = (player.rpg.skillRanks[row.id] ?? 0) > 0
            if known {
                if skill.kind == .active, player.rpg.preparedSkillIDs.contains(row.id) {
                    setStatus(game.requestRPGAssignPreparedActionToQuickSlot(kind: .skill, id: row.id, slot: selectedQuickSlotIndex), game: game)
                } else {
                    setStatus(game.requestRPGTogglePreparedSkill(row.id), game: game)
                }
            } else {
                setStatus(game.requestRPGLearnSkill(row.id), game: game)
            }
            return true
        }
        return false
    }

    private func handleSpellClick(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) -> Bool {
        guard let player = game.player else { return false }
        for row in spellRows(panel(ui)).visible where mx >= row.x && mx < row.x + row.w && my >= row.y && my < row.y + row.h {
            if player.rpg.preparedSpellIDs.contains(row.id) {
                setStatus(game.requestRPGAssignPreparedActionToQuickSlot(kind: .spell, id: row.id, slot: selectedQuickSlotIndex), game: game)
            } else {
                setStatus(game.requestRPGTogglePreparedSpell(row.id), game: game)
            }
            return true
        }
        return false
    }

    private func skillRows(_ f: (x: Double, y: Double, w: Double, h: Double), pathID: String)
        -> (visible: [(id: String, x: Double, y: Double, w: Double, h: Double)], totalHeight: Double) {
        let skillIDs = RPG_BRANCH_DEFINITIONS.filter { $0.pathID == pathID }.flatMap(\.skillIDs)
        return visibleRows(ids: skillIDs, f: f, scroll: skillScroll)
    }

    private func spellRows(_ f: (x: Double, y: Double, w: Double, h: Double))
        -> (visible: [(id: String, x: Double, y: Double, w: Double, h: Double)], totalHeight: Double) {
        visibleRows(ids: RPG_SPELL_DEFINITIONS.map(\.id), f: f, scroll: spellScroll)
    }

    private func visibleRows(ids: [String], f: (x: Double, y: Double, w: Double, h: Double), scroll: Double)
        -> (visible: [(id: String, x: Double, y: Double, w: Double, h: Double)], totalHeight: Double) {
        let x = f.x + 18
        let top = f.y + 72
        let bottom = f.y + f.h - 34
        let rowH = 24.0
        var out: [(String, Double, Double, Double, Double)] = []
        for (i, id) in ids.enumerated() {
            let y = top + Double(i) * rowH - scroll
            if y + rowH <= top || y >= bottom { continue }
            out.append((id, x, y, f.w - 36, rowH - 2))
        }
        return (out, Double(ids.count) * rowH)
    }

    private func skillRowState(_ skill: RPGSkillDefinition, state: RPGCharacterState) -> String {
        let rank = state.skillRanks[skill.id] ?? 0
        if rank > 0, skill.kind == .passive { return "Passive" }
        if let slot = rpgActionQuickSlotIndex(for: rpgPreparedActionToken(kind: .skill, id: skill.id), in: state) {
            return "Slot \(slot + 1)"
        }
        if state.preparedSkillIDs.contains(skill.id), skill.kind == .active { return "Prepared" }
        if rank > 0 { return "Known" }
        var copy = state
        if rpgLearnSkill(skill.id, in: &copy) == nil { return "Learn" }
        return "Locked"
    }

    private func spellRowState(_ spell: RPGSpellDefinition, state: RPGCharacterState) -> String {
        if let slot = rpgActionQuickSlotIndex(for: rpgPreparedActionToken(kind: .spell, id: spell.id), in: state) {
            return "Slot \(slot + 1)"
        }
        if state.preparedSpellIDs.contains(spell.id) { return "Prepared" }
        if state.knownSpellIDs.contains(spell.id) { return "Ready" }
        return "Locked"
    }

    private func updateSheetActionButtons(f: (x: Double, y: Double, w: Double, h: Double), player: Player) {
        selectedQuickSlotIndex = max(0, min(RPG_ACTION_QUICK_SLOT_COUNT - 1, selectedQuickSlotIndex))
        nextActionButton?.x = f.x + f.w - 132
        nextActionButton?.y = f.y + f.h - 28
        useActionButton?.x = f.x + f.w - 200
        useActionButton?.y = f.y + f.h - 28
        let slots = rpgActionQuickSlotActions(player.rpg)
        let action = selectedQuickSlotIndex < slots.count ? slots[selectedQuickSlotIndex] : nil
        nextActionButton?.visible = true
        useActionButton?.visible = true
        nextActionButton?.enabled = action != nil
        useActionButton?.enabled = action?.available == true
    }

    private func handleQuickSlotClick(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        let f = panel(ui)
        let x = (f.x + (f.w - 182) / 2).rounded(.down)
        let y = f.y + 7
        guard mx >= x, mx < x + 182, my >= y, my < y + 22 else { return false }
        let slot = Int((mx - x) / 20)
        guard slot >= 0 && slot < RPG_ACTION_QUICK_SLOT_COUNT else { return false }
        selectedQuickSlotIndex = slot
        if btn == 1 || btn == 2 {
            setStatus(game.requestRPGClearActionQuickSlot(slot), game: game)
        }
        return true
    }

    private func drawQuickSlotStrip(_ ui: UIManager, player: Player,
                                    f: (x: Double, y: Double, w: Double, h: Double)) {
        let cv = ui.cv
        let x = (f.x + (f.w - 182) / 2).rounded(.down)
        let y = f.y + 7
        let slots = rpgActionQuickSlotActions(player.rpg)
        cv.setFill("rgba(0,0,0,0.12)")
        cv.fillRect(x, y, 182, 22)
        for i in 0..<RPG_ACTION_QUICK_SLOT_COUNT {
            let sx = x + 1 + Double(i) * 20
            let action = i < slots.count ? slots[i] : nil
            let selected = i == selectedQuickSlotIndex
            cv.setFill(selected ? "rgba(80,140,230,0.38)" : "rgba(255,255,255,0.16)")
            cv.fillRect(sx, y + 1, 20, 20)
            if let action {
                cv.drawRPGIcon(action.iconAssetID, sx + 2, y + 2, 16, 16)
            } else {
                cv.drawTextCentered(String(i + 1), sx + 10, y + 8, 1, "#707070", shadow: false)
            }
            cv.setStroke(selected ? "#ffffff" : "rgba(0,0,0,0.25)")
            cv.strokeRect(sx, y + 1, 20, 20)
        }
        let action = selectedQuickSlotIndex < slots.count ? slots[selectedQuickSlotIndex] : nil
        let labelX = x + 190
        let labelW = Int(max(0, f.x + f.w - labelX - 12))
        guard labelW >= 44 else { return }
        if let action {
            cv.drawText(fit("Slot \(selectedQuickSlotIndex + 1): \(action.displayName)", maxWidth: labelW),
                        labelX, y + 2, 1, "#303030", shadow: false)
            cv.drawText(fit("Fat \(Int(action.fatigueCost.rounded(.up))) \(action.statusText)", maxWidth: labelW),
                        labelX, y + 12, 1, action.available ? "#206020" : "#904020", shadow: false)
        } else {
            cv.drawText("Empty", labelX, y + 7, 1, "#606060", shadow: false)
        }
    }

    private func movePath(_ dir: Int) {
        pathIndex = (pathIndex + dir + RPG_PATH_DEFINITIONS.count) % RPG_PATH_DEFINITIONS.count
        starterSkillIndex = 0
        creationSpellScroll = 0
        selectedStarterSpellIDs.removeAll()
        normalizeDraftSelection()
    }

    private func moveStarterSkill(_ dir: Int) {
        let path = RPG_PATH_DEFINITIONS[pathIndex]
        guard !path.starterSkillIDs.isEmpty else { return }
        starterSkillIndex = (starterSkillIndex + dir + path.starterSkillIDs.count) % path.starterSkillIDs.count
    }

    private func adjustDraft(_ attr: RPGAttributeID, _ delta: Int) {
        var value = draftAttributes.value(attr)
        if delta > 0 {
            guard draftAttributes.total < RPGAttributes.creationBudget, value < RPGAttributes.maximumAtCreation else { return }
            value += 1
        } else {
            guard value > RPGAttributes.minimum else { return }
            value -= 1
        }
        draftAttributes.set(attr, value)
    }

    private func normalizeDraftSelection() {
        pathIndex = max(0, min(pathIndex, RPG_PATH_DEFINITIONS.count - 1))
        let path = RPG_PATH_DEFINITIONS[pathIndex]
        if starterSkillIndex < 0 || starterSkillIndex >= path.starterSkillIDs.count {
            starterSkillIndex = 0
        }
        selectedStarterSpellIDs = selectedStarterSpellIDs.filter { path.starterSpellIDs.contains($0) }
        if selectedStarterSpellIDs.isEmpty, let first = path.starterSpellIDs.first {
            selectedStarterSpellIDs.insert(first)
        }
        if path.starterSpellIDs.isEmpty { selectedStarterSpellIDs.removeAll() }
    }

    private func applyDebugCreationSelectionIfNeeded() {
        guard !appliedDebugCreationSelection else { return }
        appliedDebugCreationSelection = true
        let env = ProcessInfo.processInfo.environment
        if let requested = env["PEBBLE_RPG_PATH"]?.lowercased(),
           let index = RPG_PATH_DEFINITIONS.firstIndex(where: { $0.id.lowercased() == requested || $0.displayName.lowercased() == requested }) {
            pathIndex = index
            starterSkillIndex = 0
            selectedStarterSpellIDs.removeAll()
        }
        if let requested = env["PEBBLE_RPG_STARTER"]?.lowercased() {
            let path = RPG_PATH_DEFINITIONS[pathIndex]
            if let index = path.starterSkillIDs.firstIndex(where: { id in
                id.lowercased() == requested || (rpgSkillDefinition(id)?.displayName.lowercased() == requested)
            }) {
                starterSkillIndex = index
            }
        }
        normalizeDraftSelection()
    }

    private func creationLayout(_ f: (x: Double, y: Double, w: Double, h: Double), path: RPGPathDefinition) -> CreationLayout {
        let footerY = f.y + f.h - 25
        let rightX = f.x + max(174, min(202, f.w * 0.45))
        let rightW = max(126, f.x + f.w - rightX - 18)
        let pathSummaryY = f.y + 54
        let pathSummaryW = Int(rightW)
        let pathSummaryLines = path.starterSpellIDs.isEmpty ? 3 : 2
        let pathLines = min(pathSummaryLines, wrapText(path.summary, max(1, pathSummaryW)).count)
        let starterLabelY = max(f.y + 80, pathSummaryY + Double(pathLines) * 10 + 6)
        let starterButtonY = starterLabelY + 16
        let starterSummaryY = starterButtonY + 22
        let starterSummaryW = Int(rightW)
        let starterSummaryLines = path.starterSpellIDs.isEmpty ? 2 : max(1, min(2, Int((footerY - starterSummaryY - 44) / 10)))
        let spellsTitleY = starterSummaryY + Double(starterSummaryLines) * 10 + 8
        let spellsListTop = spellsTitleY + 13
        let spellsListBottom = footerY - 4
        return CreationLayout(
            footerY: footerY,
            pathButtonY: f.y + 34,
            pathIconX: f.x + 42,
            pathIconY: f.y + 32,
            pathTitleY: f.y + 38,
            pathSummaryX: rightX,
            pathSummaryY: pathSummaryY,
            pathSummaryW: pathSummaryW,
            pathSummaryLines: pathSummaryLines,
            attrHeaderY: f.y + 66,
            attrRowStartY: f.y + 82,
            attrMinusX: f.x + 72,
            attrValueX: f.x + 100,
            attrPlusX: f.x + 128,
            starterLabelY: starterLabelY,
            starterButtonY: starterButtonY,
            starterIconX: rightX + 28,
            starterIconY: starterButtonY + 1,
            starterNameX: rightX + 52,
            starterNameW: Int(max(1, f.x + f.w - 38 - (rightX + 52))),
            starterSummaryX: rightX,
            starterSummaryY: starterSummaryY,
            starterSummaryW: starterSummaryW,
            starterSummaryLines: starterSummaryLines,
            spellsTitleY: spellsTitleY,
            spellsListTop: spellsListTop,
            spellsListBottom: spellsListBottom,
            spellsX: rightX,
            spellsW: rightW,
            spellRowH: 16,
            spellRowStride: 18
        )
    }

    private func updateCreationButtonLayout(_ layout: CreationLayout, f: (x: Double, y: Double, w: Double, h: Double),
                                            path: RPGPathDefinition) {
        closeButton?.x = f.x + 14
        closeButton?.y = layout.footerY
        createButton?.x = f.x + f.w - 72
        createButton?.y = layout.footerY
        prevPathButton?.x = f.x + 14
        prevPathButton?.y = layout.pathButtonY
        nextPathButton?.x = f.x + f.w - 36
        nextPathButton?.y = layout.pathButtonY
        prevStarterButton?.x = layout.starterSummaryX
        prevStarterButton?.y = layout.starterButtonY
        nextStarterButton?.x = f.x + f.w - 36
        nextStarterButton?.y = layout.starterButtonY
        prevStarterButton?.visible = path.starterSkillIDs.count > 1
        nextStarterButton?.visible = path.starterSkillIDs.count > 1
    }

    private func setStatus(_ text: String, game: GameCore) {
        statusText = text
        game.host?.showActionBar(text, 70)
    }

    private func drawBar(_ cv: UICanvas, x: Double, y: Double, w: Double, label: String,
                         value: Double, maxValue: Double, fill: String) {
        cv.drawText(label, x, y, 1, "#303030", shadow: false)
        cv.setFill("#202020")
        cv.fillRect(x + 64, y + 1, w - 64, 6)
        cv.setFill(fill)
        cv.fillRect(x + 64, y + 1, (w - 64) * max(0, min(1, value / max(1, maxValue))), 6)
    }

    private func drawWrapped(_ cv: UICanvas, _ text: String, _ x: Double, _ y: Double,
                             _ width: Int, _ color: String, maxLines: Int) {
        guard width > 0, maxLines > 0 else { return }
        let wrapped = wrapText(text, max(1, width))
        var lines = Array(wrapped.prefix(maxLines))
        if wrapped.count > maxLines, !lines.isEmpty {
            var last = lines[lines.count - 1]
            while textWidth(last + "...") > width && last.count > 1 {
                last.removeLast()
            }
            lines[lines.count - 1] = last + "..."
        }
        for (i, line) in lines.enumerated() {
            cv.drawText(line, x, y + Double(i) * 10, 1, color, shadow: false)
        }
    }

    private func fit(_ text: String, maxWidth: Int) -> String {
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

    private func drawScrollBar(_ cv: UICanvas, x: Double, y: Double, h: Double, contentH: Double, offset: Double) {
        guard contentH > h, h >= 12 else { return }
        cv.setFill("rgba(0,0,0,0.25)")
        cv.fillRect(x, y, 3, h)
        let thumbH = max(8, h * h / contentH)
        let range = max(1, contentH - h)
        let thumbY = y + (h - thumbH) * max(0, min(1, offset / range))
        cv.setFill("rgba(255,255,255,0.55)")
        cv.fillRect(x, thumbY, 3, thumbH)
    }

    private func attributeShortLabel(_ attr: RPGAttributeID) -> String {
        switch attr {
        case .strength: return "ST"
        case .dexterity: return "DX"
        case .intelligence: return "IQ"
        case .endurance: return "EN"
        case .luck: return "LK"
        }
    }

    private func attributeLabel(_ attr: RPGAttributeID) -> String {
        switch attr {
        case .strength: return "Strength"
        case .dexterity: return "Dexterity"
        case .intelligence: return "Intelligence"
        case .endurance: return "Endurance"
        case .luck: return "Luck"
        }
    }
}
