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
    private var skillScroll = 0.0
    private var spellScroll = 0.0
    private var statusText = ""
    private var attrButtons: [(RPGAttributeID, Button, Button)] = []
    private var spendAttrButtons: [(RPGAttributeID, Button)] = []

    override init() {
        super.init()
        showHUD = true
        pausesGame = true
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        guard let player = game.player else { return }
        if player.rpg.created {
            buildSheetButtons(ui, game)
        } else {
            normalizeDraftSelection()
            buildCreationButtons(ui, game)
        }
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.45)
        guard let player = game.player else { return }
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
        let w = min(430.0, max(330.0, ui.width - 24))
        let h = min(236.0, max(210.0, ui.height - 20))
        return (((ui.width - w) / 2).rounded(.down), ((ui.height - h) / 2).rounded(.down), w, h)
    }

    private func buildCreationButtons(_ ui: UIManager, _ game: GameCore) {
        let f = panel(ui)
        let top = f.y + 34
        buttons.append(Button(f.x + f.w - 72, f.y + f.h - 28, 58, 20, "Create", { [weak self, weak ui, weak game] in
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
        }))
        buttons.append(Button(f.x + 14, f.y + f.h - 28, 58, 20, "Close", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        }))
        buttons.append(Button(f.x + 14, top, 22, 18, "<", { [weak self] in self?.movePath(-1) }))
        buttons.append(Button(f.x + f.w - 36, top, 22, 18, ">", { [weak self] in self?.movePath(1) }))
        buttons.append(Button(f.x + 194, top + 70, 22, 18, "<", { [weak self] in self?.moveStarterSkill(-1) }))
        buttons.append(Button(f.x + f.w - 36, top + 70, 22, 18, ">", { [weak self] in self?.moveStarterSkill(1) }))

        attrButtons.removeAll()
        for (i, attr) in RPGAttributeID.allCases.enumerated() {
            let y = f.y + 82 + Double(i) * 20
            let minus = Button(f.x + 72, y, 18, 16, "-", { [weak self] in self?.adjustDraft(attr, -1) })
            let plus = Button(f.x + 128, y, 18, 16, "+", { [weak self] in self?.adjustDraft(attr, 1) })
            attrButtons.append((attr, minus, plus))
            buttons.append(minus)
            buttons.append(plus)
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
        let remaining = RPGAttributes.creationBudget - draftAttributes.total
        ui.drawPanel(f.x, f.y, f.w, f.h)
        cv.drawText("Create Character", f.x + 12, f.y + 12, 1, "#3f3f3f", shadow: false)
        cv.drawRPGIcon(rpgAssetIDForPath(path.id), f.x + 42, f.y + 32, 24, 24)
        cv.drawTextCentered(path.displayName, f.x + f.w / 2, f.y + 38, 1, "#202020", shadow: false)
        drawWrapped(cv, path.summary, f.x + 182, f.y + 58, Int(f.w - 204), "#505050", maxLines: 2)
        cv.drawText("Attributes", f.x + 14, f.y + 66, 1, "#3f3f3f", shadow: false)
        cv.drawText("Pool \(remaining)", f.x + 104, f.y + 66, 1, remaining == 0 ? "#206020" : "#a04020", shadow: false)
        for (attr, minus, plus) in attrButtons {
            let value = draftAttributes.value(attr)
            minus.enabled = value > RPGAttributes.minimum
            plus.enabled = remaining > 0 && value < RPGAttributes.maximumAtCreation
            cv.drawText(attributeShortLabel(attr), f.x + 18, minus.y + 4, 1, "#303030", shadow: false)
            cv.drawText(String(value), f.x + 100, minus.y + 4, 1, "#202020", shadow: false)
        }
        cv.drawText("Starter", f.x + 194, f.y + 88, 1, "#3f3f3f", shadow: false)
        let starterSkill = path.starterSkillIDs.indices.contains(starterSkillIndex)
            ? path.starterSkillIDs[starterSkillIndex] : path.starterSkillIDs.first
        if let starterSkill, let def = rpgSkillDefinition(starterSkill) {
            cv.drawRPGIcon(rpgAssetIDForSkill(starterSkill), f.x + 222, f.y + 101, 18, 18)
            cv.drawText(def.displayName, f.x + 244, f.y + 104, 1, "#202020", shadow: false)
            drawWrapped(cv, def.summary, f.x + 194, f.y + 123, Int(f.w - 212), "#505050", maxLines: 2)
        }
        drawStarterSpells(ui, path: path, f: f)
        buttons.first { $0.label == "Create" }?.enabled = remaining == 0
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
        cv.drawText("Health \(Int(player.health.rounded())) / \(Int(player.maxHealth.rounded()))", left, y, 1, "#303030", shadow: false)
        cv.drawText("Skill Points \(rpgAvailableSkillPoints(state))", right, y, 1, "#303030", shadow: false)
        cv.drawText("Attribute Points \(rpgAvailableAttributePoints(state))", left, y + 14, 1, "#303030", shadow: false)
        cv.drawText("Prepared \(state.preparedSkillIDs.count) skills, \(state.preparedSpellIDs.count) spells", right, y + 14, 1, "#303030", shadow: false)
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
        cv.drawText("HP \(Int(derived.maxHealth))  Fatigue \(Int(derived.maxFatigue))  Regen \(String(format: "%.2f", derived.fatigueRegenPerTick * 20))/s",
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
            cv.drawText(rank > 0 ? "\(rank)/\(skill.maxRank)" : "-", row.x + 146, row.y + 4, 1, "#303030", shadow: false)
            cv.drawText(skillRowState(skill, state: player.rpg), row.x + row.w - 60, row.y + 4, 1, "#303030", shadow: false)
            cv.drawText(fit(skill.summary, maxWidth: Int(row.w - 220)), row.x + 190, row.y + 4, 1, "#606060", shadow: false)
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
            cv.drawText(prepared ? "Prepared" : known ? "Ready" : "Locked", row.x + row.w - 62, row.y + 4, 1, "#303030", shadow: false)
            cv.drawText(fit(spell.summary, maxWidth: Int(row.w - 220)), row.x + 190, row.y + 4, 1, "#606060", shadow: false)
        }
    }

    private func drawStarterSpells(_ ui: UIManager, path: RPGPathDefinition,
                                   f: (x: Double, y: Double, w: Double, h: Double)) {
        guard !path.starterSpellIDs.isEmpty else { return }
        let cv = ui.cv
        let x = f.x + 194
        let y = f.y + 154
        cv.drawText("Spells", x, y, 1, "#3f3f3f", shadow: false)
        for (i, spellID) in path.starterSpellIDs.enumerated() {
            guard let spell = rpgSpellDefinition(spellID) else { continue }
            let rowY = y + 14 + Double(i) * 18
            let selected = selectedStarterSpellIDs.contains(spellID)
            cv.setFill(selected ? "rgba(90,120,210,0.35)" : "rgba(0,0,0,0.12)")
            cv.fillRect(x, rowY, f.w - 212, 16)
            cv.drawRPGIcon(rpgAssetIDForSpell(spellID), x + 2, rowY, 16, 16)
            cv.drawText(fit(spell.displayName, maxWidth: Int(f.w - 244)), x + 22, rowY + 4, 1, "#303030", shadow: false)
        }
    }

    private func handleCreationClick(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) -> Bool {
        let f = panel(ui)
        let path = RPG_PATH_DEFINITIONS[pathIndex]
        guard !path.starterSpellIDs.isEmpty else { return false }
        let x = f.x + 194
        let y = f.y + 168
        for (i, spellID) in path.starterSpellIDs.enumerated() {
            let rowY = y + Double(i) * 18
            if mx >= x, mx < x + f.w - 212, my >= rowY, my < rowY + 16 {
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
            let known = (player.rpg.skillRanks[row.id] ?? 0) > 0
            if known {
                setStatus(game.requestRPGTogglePreparedSkill(row.id), game: game)
            } else {
                setStatus(game.requestRPGLearnSkill(row.id), game: game)
            }
            return true
        }
        return false
    }

    private func handleSpellClick(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) -> Bool {
        for row in spellRows(panel(ui)).visible where mx >= row.x && mx < row.x + row.w && my >= row.y && my < row.y + row.h {
            setStatus(game.requestRPGTogglePreparedSpell(row.id), game: game)
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
        if state.preparedSkillIDs.contains(skill.id) { return "Prepared" }
        if rank > 0 { return "Known" }
        var copy = state
        if rpgLearnSkill(skill.id, in: &copy) == nil { return "Learn" }
        return "Locked"
    }

    private func movePath(_ dir: Int) {
        pathIndex = (pathIndex + dir + RPG_PATH_DEFINITIONS.count) % RPG_PATH_DEFINITIONS.count
        starterSkillIndex = 0
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
        let lines = Array(wrapText(text, max(1, width)).prefix(maxLines))
        for (i, line) in lines.enumerated() {
            cv.drawText(line, x, y + Double(i) * 10, 1, color, shadow: false)
        }
    }

    private func fit(_ text: String, maxWidth: Int) -> String {
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
