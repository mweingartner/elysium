// SkillTreeScreen — a compact, canvas-based workspace for the four usage-based
// advancement trees.  It deliberately takes its state and action hooks as
// closures: the screen is presentation-only and never reaches through to a
// player/save/LAN authority on its own.

import Foundation
import ElysiumCore

/// Presents the four usage-based advancement trees without reviving any of the
/// retired character-path UI.  The embedding screen supplies the current
/// authoritative state and the guarded action request.  Keeping those seams
/// explicit makes it safe to use for a LAN client as well as a local player.
final class SkillTreeScreen: Screen {
    typealias StateProvider = (GameCore) -> SkillTreeState?
    typealias ActionDispatcher = (GameCore, SkillTreeActionID) -> Bool
    /// One-based fast-bar slot number, or `nil` while an unlocked action has
    /// not been assigned.  The screen displays this state but does not mutate
    /// a fast-bar preference directly.
    typealias QuickSlotProvider = (GameCore, SkillTreeActionID) -> Int?

    private struct Layout {
        let panelX: Double
        let panelY: Double
        let panelW: Double
        let panelH: Double
        let viewportY: Double
        let viewportH: Double
        let footerY: Double
        let contentX: Double
        let contentW: Double
        let columnCount: Int
        let cardW: Double
        let cardH: Double
        let treeSectionH: Double
        let actionsY: Double
        let actionColumns: Int
        let actionW: Double
        let actionH: Double
        let contentH: Double
    }

    private enum TreeCard: CaseIterable {
        case mining
        case melee
        case ranged
        case crafting

        var title: String {
            switch self {
            case .mining: return "Mining"
            case .melee: return "Melee combat"
            case .ranged: return "Ranged combat"
            case .crafting: return "Crafting"
            }
        }

        var primaryTitle: String {
            switch self {
            case .mining: return "Mining speed"
            case .melee: return "Sword damage"
            case .ranged: return "Bow damage"
            case .crafting: return "Crafting speed"
            }
        }

        var advancedTitle: String {
            switch self {
            case .mining: return "Ore yield"
            case .melee: return "Combat techniques"
            case .ranged: return "Bow techniques"
            case .crafting: return "Quality and repair"
            }
        }

        var description: String {
            switch self {
            case .mining: return "Harvest resource blocks to earn XP."
            case .melee: return "Land sword hits on animals and enemies."
            case .ranged: return "Land bow hits on animals and enemies."
            case .crafting: return "Complete recipes; each output item caps at 100 XP crafts."
            }
        }

        var accent: String {
            switch self {
            case .mining: return "#d9ad4c"
            case .melee: return "#d96b62"
            case .ranged: return "#78b868"
            case .crafting: return "#8e95d8"
            }
        }

        func branch(in state: SkillTreeState) -> SkillTreeBranchState {
            switch self {
            case .mining: return skillTreeValidatedBranchState(state.mining)
            case .melee: return skillTreeValidatedBranchState(state.melee)
            case .ranged: return skillTreeValidatedBranchState(state.ranged)
            case .crafting: return skillTreeValidatedBranchState(state.crafting.progress)
            }
        }
    }

    private let stateProvider: StateProvider
    private let actionDispatcher: ActionDispatcher
    private let quickSlotProvider: QuickSlotProvider
    private var scrollOffset = 0.0
    private var maximumScrollOffset = 0.0
    private var actionButtons: [SkillTreeActionID: Button] = [:]
    private var doneButton: Button?
    private var statusText: String?

    /// The caller should provide its guarded game-core operation, for example:
    ///
    ///     SkillTreeScreen(
    ///         stateProvider: { $0.skillTreeStateSnapshot() },
    ///         actionDispatcher: { $0.requestSkillTreeAction($1) },
    ///         quickSlotProvider: { $0.skillTreeQuickSlot(for: $1) }
    ///     )
    ///
    /// The closure boundary intentionally keeps this canvas screen from being
    /// a second gameplay authority.
    init(stateProvider: @escaping StateProvider,
         actionDispatcher: @escaping ActionDispatcher,
         quickSlotProvider: @escaping QuickSlotProvider = { _, _ in nil }) {
        self.stateProvider = stateProvider
        self.actionDispatcher = actionDispatcher
        self.quickSlotProvider = quickSlotProvider
        super.init()
        showHUD = true
        pausesGame = true
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        buttons.removeAll()
        sliders.removeAll()
        fields.removeAll()
        slots.removeAll()
        actionButtons.removeAll(keepingCapacity: true)

        let layout = makeLayout(ui)
        maximumScrollOffset = max(0, layout.contentH - layout.viewportH)
        scrollOffset = min(max(0, scrollOffset), maximumScrollOffset)

        if let state = stateProvider(game) {
            for (index, descriptor) in SKILL_TREE_ACTION_DESCRIPTORS.enumerated() {
                let frame = actionFrame(for: index, in: layout)
                let id = descriptor.id
                let button = Button(frame.x, frame.y - scrollOffset, frame.w, frame.h, "") {
                    [weak self, weak game] in
                    guard let self, let game else { return }
                    guard let current = self.stateProvider(game),
                          skillTreeActionIsUnlocked(id, in: current) else {
                        self.statusText = descriptor.displayName + " is still locked."
                        return
                    }
                    self.statusText = self.actionDispatcher(game, id)
                        ? descriptor.displayName + " is ready."
                        : descriptor.displayName + " could not be used now."
                }
                button.enabled = skillTreeActionIsUnlocked(id, in: state)
                button.visible = frame.y - scrollOffset >= layout.viewportY
                    && frame.y - scrollOffset + frame.h <= layout.footerY
                actionButtons[id] = button
                buttons.append(button)
            }
        }

        let done = Button(layout.panelX + layout.panelW / 2 - 50, layout.footerY + 4,
                          100, 18, "Done") { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        }
        doneButton = done
        buttons.append(done)
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        let layout = makeLayout(ui)
        maximumScrollOffset = max(0, layout.contentH - layout.viewportH)
        scrollOffset = min(max(0, scrollOffset), maximumScrollOffset)

        ui.drawDarkBg(0.70)
        ui.drawPanel(layout.panelX, layout.panelY, layout.panelW, layout.panelH)
        guard let state = stateProvider(game) else {
            drawUnavailable(in: layout, ui: ui)
            drawHeaderAndFooter(in: layout, ui: ui)
            if let doneButton {
                doneButton.x = layout.panelX + layout.panelW / 2 - doneButton.w / 2
                doneButton.y = layout.footerY + 4
                ui.drawButton(doneButton, doneButton.contains(ui.mouseX, ui.mouseY))
            }
            return
        }

        // Content deliberately draws before the fixed header and footer.  The two
        // opaque rails then mask any scrolled content outside the viewport while
        // retaining the simple immediate-mode canvas contract.
        for (index, tree) in TreeCard.allCases.enumerated() {
            drawTreeCard(tree, state: state, frame: treeFrame(for: index, in: layout),
                         ui: ui)
        }
        drawActions(state: state, game: game, in: layout, ui: ui)
        drawHeaderAndFooter(in: layout, ui: ui)

        if let doneButton {
            doneButton.x = layout.panelX + layout.panelW / 2 - doneButton.w / 2
            doneButton.y = layout.footerY + 4
            ui.drawButton(doneButton, doneButton.contains(ui.mouseX, ui.mouseY))
        }
    }

    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        guard maximumScrollOffset > 0 else { return false }
        let previous = scrollOffset
        // A notch is intentionally modest: a tree card can be read without
        // losing its title or its five-rank rows on ordinary trackpads.
        scrollOffset = min(maximumScrollOffset, max(0, scrollOffset - dy * 26))
        guard scrollOffset != previous else { return false }
        initScreen(ui, game)
        return true
    }

    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        let delta: Double
        switch key {
        case "ArrowUp": delta = -42
        case "ArrowDown": delta = 42
        case "PageUp": delta = -max(84, makeLayout(ui).viewportH - 34)
        case "PageDown": delta = max(84, makeLayout(ui).viewportH - 34)
        case "Home":
            scrollOffset = 0
            initScreen(ui, game)
            return true
        case "End":
            scrollOffset = maximumScrollOffset
            initScreen(ui, game)
            return true
        default: return false
        }
        let previous = scrollOffset
        scrollOffset = min(maximumScrollOffset, max(0, scrollOffset + delta))
        guard scrollOffset != previous else { return false }
        initScreen(ui, game)
        return true
    }

    private func makeLayout(_ ui: UIManager) -> Layout {
        let margin = 10.0
        let panelW = min(760, max(260, ui.width - margin * 2))
        let panelH = max(198, ui.height - margin * 2)
        let panelX = ((ui.width - panelW) / 2).rounded(.down)
        let panelY = ((ui.height - panelH) / 2).rounded(.down)
        let viewportY = panelY + 31
        let footerY = panelY + panelH - 28
        let viewportH = max(64, footerY - viewportY)
        let contentX = panelX + 10
        let contentW = panelW - 20
        let columnCount = contentW >= 560 ? 2 : 1
        let cardGap = 8.0
        let cardW = (contentW - Double(columnCount - 1) * cardGap) / Double(columnCount)
        let cardH = columnCount == 2 ? 150.0 : 146.0
        let treeRows = (TreeCard.allCases.count + columnCount - 1) / columnCount
        let treeSectionH = Double(treeRows) * cardH + Double(max(0, treeRows - 1)) * cardGap
        let actionsY = treeSectionH + 20
        let actionColumns = contentW >= 560 ? 2 : 1
        let actionW = (contentW - Double(actionColumns - 1) * cardGap) / Double(actionColumns)
        let actionH = 46.0
        let actionRows = (SKILL_TREE_ACTION_DESCRIPTORS.count + actionColumns - 1) / actionColumns
        let contentH = actionsY + 14 + Double(actionRows) * actionH
            + Double(max(0, actionRows - 1)) * 6 + 8
        return Layout(panelX: panelX, panelY: panelY, panelW: panelW, panelH: panelH,
                      viewportY: viewportY, viewportH: viewportH, footerY: footerY,
                      contentX: contentX, contentW: contentW, columnCount: columnCount,
                      cardW: cardW, cardH: cardH, treeSectionH: treeSectionH,
                      actionsY: actionsY, actionColumns: actionColumns, actionW: actionW,
                      actionH: actionH, contentH: contentH)
    }

    private func treeFrame(for index: Int, in layout: Layout) -> (x: Double, y: Double, w: Double, h: Double) {
        let gap = 8.0
        let column = index % layout.columnCount
        let row = index / layout.columnCount
        return (layout.contentX + Double(column) * (layout.cardW + gap),
                layout.viewportY + Double(row) * (layout.cardH + gap) - scrollOffset,
                layout.cardW, layout.cardH)
    }

    private func actionFrame(for index: Int, in layout: Layout) -> (x: Double, y: Double, w: Double, h: Double) {
        let gap = 8.0
        let rowGap = 6.0
        let column = index % layout.actionColumns
        let row = index / layout.actionColumns
        return (layout.contentX + Double(column) * (layout.actionW + gap),
                layout.viewportY + layout.actionsY + 14
                    + Double(row) * (layout.actionH + rowGap),
                layout.actionW, layout.actionH)
    }

    private func drawHeaderAndFooter(in layout: Layout, ui: UIManager) {
        let cv = ui.cv
        cv.setFill("#c6c6c6")
        cv.fillRect(layout.panelX + 2, layout.panelY + 1, layout.panelW - 4,
                    layout.viewportY - layout.panelY - 1)
        cv.setFill("#555555")
        cv.fillRect(layout.panelX + 2, layout.viewportY - 1, layout.panelW - 4, 1)
        cv.setFill("#c6c6c6")
        cv.fillRect(layout.panelX + 2, layout.footerY, layout.panelW - 4,
                    layout.panelY + layout.panelH - layout.footerY - 1)
        cv.setFill("#ffffff")
        cv.fillRect(layout.panelX + 2, layout.footerY, layout.panelW - 4, 1)

        cv.drawText("Skill trees", layout.panelX + 10, layout.panelY + 9, 1.15,
                    "#202020", shadow: false)
        let hint = maximumScrollOffset > 0 ? "Scroll for more" : "Use skills to advance"
        cv.drawText(hint, layout.panelX + layout.panelW - 10 - Double(textWidth(hint)),
                    layout.panelY + 11, 0.75, "#4d4d4d", shadow: false)
        if let statusText {
            let fitted = fit(statusText, maxWidth: Int(layout.panelW - 132))
            cv.drawText(fitted, layout.panelX + 10, layout.footerY + 10, 0.72,
                        "#303030", shadow: false)
        }
    }

    private func drawUnavailable(in layout: Layout, ui: UIManager) {
        let cv = ui.cv
        let x = layout.contentX
        let y = layout.viewportY + 18
        cv.setFill("#a8a8a8")
        cv.fillRect(x, y, layout.contentW, 52)
        cv.setStroke("#555555")
        cv.strokeRect(x, y, layout.contentW, 52)
        cv.drawText("Skill progression is not available in this world.", x + 8, y + 13,
                    0.9, "#202020", shadow: false)
        cv.drawText("The world must finish loading before its usage state can be shown.",
                    x + 8, y + 27, 0.72, "#4d4d4d", shadow: false)
    }

    private func drawTreeCard(_ tree: TreeCard, state: SkillTreeState,
                              frame: (x: Double, y: Double, w: Double, h: Double),
                              ui: UIManager) {
        let cv = ui.cv
        cv.setFill("#a9a9a9")
        cv.fillRect(frame.x, frame.y, frame.w, frame.h)
        cv.setStroke(tree.accent)
        cv.strokeRect(frame.x, frame.y, frame.w, frame.h, 1)

        drawTreeGlyph(tree, x: frame.x + 8, y: frame.y + 7, ui: ui)
        cv.drawText(tree.title, frame.x + 30, frame.y + 8, 0.95, "#202020", shadow: false)
        cv.drawText(fit(tree.description, maxWidth: Int(frame.w - 16)), frame.x + 8,
                    frame.y + 23, 0.68, "#3e3e3e", shadow: false)

        let branch = tree.branch(in: state)
        let primaryY = frame.y + 39
        drawRankTrack(title: tree.primaryTitle, branch: branch, isAdvanced: false,
                      accent: tree.accent, y: primaryY, frame: frame, ui: ui)
        let advancedY = frame.y + 83
        drawRankTrack(title: tree.advancedTitle, branch: branch,
                      isAdvanced: true, unlocked: branch.primaryRank == SKILL_TREE_PRIMARY_RANK_CAP,
                      accent: tree.accent, y: advancedY, frame: frame, ui: ui)

        if tree == .crafting {
            let completed = state.crafting.recipeMasteryCounts.reduce(0) { $0 + Int($1) }
            let mastered = state.crafting.recipeMasteryCounts.filter {
                Int($0) >= SKILL_TREE_RECIPE_MASTERY_CAP
            }.count
            let detail = "Item mastery: " + String(mastered)
                + " mastered, " + String(completed) + " completed"
            cv.drawText(fit(detail, maxWidth: Int(frame.w - 16)), frame.x + 8, frame.y + frame.h - 14,
                        0.65, "#363636", shadow: false)
        } else if branch.primaryRank == SKILL_TREE_PRIMARY_RANK_CAP {
            let detail = branch.advancedRank == SKILL_TREE_ADVANCED_RANK_CAP
                ? "Advanced tree mastered" : "Advanced tree unlocked"
            cv.drawText(detail, frame.x + 8, frame.y + frame.h - 14, 0.68,
                        branch.advancedRank == SKILL_TREE_ADVANCED_RANK_CAP ? "#285b2b" : tree.accent,
                        shadow: false)
        } else {
            let remaining = SKILL_TREE_PRIMARY_RANK_CAP - branch.primaryRank
            let suffix = remaining == 1 ? "" : "s"
            cv.drawText(String(remaining) + " base rank" + suffix + " until advanced unlock",
                        frame.x + 8, frame.y + frame.h - 14, 0.65, "#4d4d4d", shadow: false)
        }
    }

    private func drawRankTrack(title: String, branch: SkillTreeBranchState, isAdvanced: Bool,
                               unlocked: Bool = true, accent: String, y: Double,
                               frame: (x: Double, y: Double, w: Double, h: Double),
                               ui: UIManager) {
        let cv = ui.cv
        let rank = isAdvanced ? branch.advancedRank : branch.primaryRank
        let clampedRank = max(0, min(SKILL_TREE_PRIMARY_RANK_CAP, rank))
        let status = unlocked ? "\(clampedRank)/5" : "Locked"
        let titleWidth = min(frame.w - 64, Double(textWidth(title)))
        cv.drawText(fit(title, maxWidth: Int(titleWidth)), frame.x + 8, y, 0.72,
                    unlocked ? "#202020" : "#555555", shadow: false)
        cv.drawText(status, frame.x + frame.w - 8 - Double(textWidth(status)), y, 0.72,
                    unlocked ? accent : "#666666", shadow: false)

        let nodeSize = 14.0
        let nodeGap = 6.0
        let startX = frame.x + 8
        let nodeY = y + 11
        let trackW = nodeSize * 5 + nodeGap * 4
        cv.setFill(unlocked ? "#707070" : "#777777")
        cv.fillRect(startX + nodeSize / 2, nodeY + nodeSize / 2 - 1,
                    trackW - nodeSize, 2)
        for index in 0..<SKILL_TREE_PRIMARY_RANK_CAP {
            let x = startX + Double(index) * (nodeSize + nodeGap)
            let filled = unlocked && index < clampedRank
            cv.setFill(filled ? accent : (unlocked ? "#626262" : "#808080"))
            cv.fillRect(x, nodeY, nodeSize, nodeSize)
            cv.setStroke(filled ? "#ffffff" : "#404040")
            cv.strokeRect(x, nodeY, nodeSize, nodeSize)
            let numeral = String(index + 1)
            cv.drawText(numeral, x + (nodeSize - Double(textWidth(numeral))) / 2,
                        nodeY + 3, 0.65, filled ? "#202020" : "#d0d0d0", shadow: false)
        }

        let currentXP: Int
        let targetXP: Int
        let label: String
        if !unlocked {
            currentXP = 0
            targetXP = 1
            label = "Complete the base tree to unlock"
        } else if isAdvanced {
            currentXP = max(0, branch.xp - skillTreePrimaryXPRequired(
                forRank: SKILL_TREE_PRIMARY_RANK_CAP))
            targetXP = clampedRank == SKILL_TREE_ADVANCED_RANK_CAP
                ? skillTreeAdvancedXPRequired(forRank: SKILL_TREE_ADVANCED_RANK_CAP)
                : skillTreeAdvancedXPRequired(forRank: clampedRank + 1)
            label = clampedRank == SKILL_TREE_ADVANCED_RANK_CAP
                ? "Mastered " + String(currentXP) + "/" + String(targetXP) + " XP"
                : "XP " + String(currentXP) + "/" + String(targetXP)
        } else {
            currentXP = min(branch.xp, skillTreePrimaryXPRequired(
                forRank: SKILL_TREE_PRIMARY_RANK_CAP))
            targetXP = clampedRank == SKILL_TREE_PRIMARY_RANK_CAP
                ? skillTreePrimaryXPRequired(forRank: SKILL_TREE_PRIMARY_RANK_CAP)
                : skillTreePrimaryXPRequired(forRank: clampedRank + 1)
            label = clampedRank == SKILL_TREE_PRIMARY_RANK_CAP
                ? "Mastered " + String(currentXP) + "/" + String(targetXP) + " XP"
                : "XP " + String(currentXP) + "/" + String(targetXP)
        }
        let barX = startX + trackW + 9
        let barW = max(32, frame.x + frame.w - 8 - barX)
        let barY = nodeY + 4
        let fraction = max(0, min(1, Double(currentXP) / Double(max(1, targetXP))))
        cv.setFill(unlocked ? "#4f4f4f" : "#777777")
        cv.fillRect(barX, barY, barW, 4)
        cv.setFill(unlocked ? accent : "#8a8a8a")
        cv.fillRect(barX, barY, (barW * fraction).rounded(.down), 4)
        cv.drawText(fit(label, maxWidth: Int(frame.w - 16)), frame.x + 8, nodeY + 19,
                    0.62, unlocked ? "#3e3e3e" : "#5f5f5f", shadow: false)
    }

    private func drawActions(state: SkillTreeState, game: GameCore,
                             in layout: Layout, ui: UIManager) {
        let cv = ui.cv
        let titleY = layout.viewportY + layout.actionsY - scrollOffset
        cv.drawText("Advanced actions", layout.contentX, titleY, 0.92, "#202020", shadow: false)
        let subtitle = "Unlock advanced techniques in order; their icons mirror the action fast bar."
        cv.drawText(fit(subtitle, maxWidth: Int(layout.contentW - 116)),
                    layout.contentX + 110, titleY + 1, 0.62, "#4d4d4d", shadow: false)

        for (index, descriptor) in SKILL_TREE_ACTION_DESCRIPTORS.enumerated() {
            let rawFrame = actionFrame(for: index, in: layout)
            let frame: (x: Double, y: Double, w: Double, h: Double) = (
                x: rawFrame.x, y: rawFrame.y - scrollOffset, w: rawFrame.w, h: rawFrame.h)
            let unlocked = skillTreeActionIsUnlocked(descriptor.id, in: state)
            actionButtons[descriptor.id]?.x = frame.x
            actionButtons[descriptor.id]?.y = frame.y
            actionButtons[descriptor.id]?.w = frame.w
            actionButtons[descriptor.id]?.h = frame.h
            let visible = frame.y >= layout.viewportY && frame.y + frame.h <= layout.footerY
            actionButtons[descriptor.id]?.visible = visible
            actionButtons[descriptor.id]?.enabled = unlocked && visible

            cv.setFill(unlocked ? "#9da79d" : "#858585")
            cv.fillRect(frame.x, frame.y, frame.w, frame.h)
            cv.setStroke(unlocked ? "#3d7442" : "#5b5b5b")
            cv.strokeRect(frame.x, frame.y, frame.w, frame.h)
            drawActionIcon(descriptor.id, assetID: descriptor.iconAssetID,
                           x: frame.x + 7, y: frame.y + 11, ui: ui)
            cv.drawText(descriptor.displayName, frame.x + 31, frame.y + 7, 0.82,
                        unlocked ? "#202020" : "#525252", shadow: false)

            if unlocked {
                let slot = quickSlotProvider(game, descriptor.id).flatMap {
                    (1...RPG_ACTION_QUICK_SLOT_COUNT).contains($0) ? $0 : nil
                }
                let status = slot.map { "Fast bar: \($0)" } ?? "Fast bar: not assigned"
                cv.drawText(status, frame.x + 31, frame.y + 21, 0.65, "#285b2b", shadow: false)
                cv.drawText("Click to use", frame.x + 31, frame.y + 32, 0.62, "#3b3b3b", shadow: false)
            } else {
                let requirement = "Unlocks at technique \(descriptor.advancedRankRequired)/5"
                cv.drawText(requirement, frame.x + 31, frame.y + 21, 0.65, "#5e3d34", shadow: false)
                cv.drawText(actionEquipmentText(descriptor), frame.x + 31, frame.y + 32,
                            0.62, "#4d4d4d", shadow: false)
            }
        }
    }

    private func drawTreeGlyph(_ tree: TreeCard, x: Double, y: Double, ui: UIManager) {
        let cv = ui.cv
        cv.setStroke(tree.accent)
        // The mining, melee, and ranged marks are stroked; the crafting mark
        // is filled.  Set both drawing colors so the plus glyph does not
        // inherit an unrelated fill from the card drawn immediately before it.
        cv.setFill(tree.accent)
        switch tree {
        case .mining:
            cv.line(x + 2, y + 13, x + 14, y + 1, 2)
            cv.line(x + 4, y + 1, x + 14, y + 5, 2)
        case .melee:
            cv.line(x + 4, y + 13, x + 13, y + 2, 2)
            cv.line(x + 2, y + 11, x + 8, y + 15, 2)
        case .ranged:
            cv.line(x + 2, y + 8, x + 14, y + 8, 2)
            cv.line(x + 10, y + 4, x + 14, y + 8, 2)
            cv.line(x + 10, y + 12, x + 14, y + 8, 2)
        case .crafting:
            cv.fillRect(x + 7, y + 1, 4, 11)
            cv.fillRect(x + 3, y + 10, 12, 4)
        }
    }

    private func drawActionIcon(_ id: SkillTreeActionID, assetID: String,
                                x: Double, y: Double, ui: UIManager) {
        let cv = ui.cv
        if rpgIconPixels(assetID: assetID) != nil {
            cv.drawRPGIcon(assetID, x, y, 22, 22)
            return
        }
        cv.setStroke("#202020")
        switch id {
        case .stunEnemy, .pinningShot:
            cv.line(x + 11, y, x + 6, y + 10, 2)
            cv.line(x + 6, y + 10, x + 12, y + 10, 2)
            cv.line(x + 12, y + 10, x + 7, y + 21, 2)
        case .spartanKick, .powerShot:
            cv.line(x + 3, y + 5, x + 11, y + 11, 3)
            cv.line(x + 11, y + 11, x + 20, y + 11, 3)
            cv.line(x + 16, y + 7, x + 20, y + 11, 2)
            cv.line(x + 16, y + 15, x + 20, y + 11, 2)
        case .roundHouse, .volley:
            cv.line(x + 5, y + 6, x + 16, y + 6, 2)
            cv.line(x + 16, y + 6, x + 19, y + 12, 2)
            cv.line(x + 19, y + 12, x + 13, y + 18, 2)
            cv.line(x + 13, y + 18, x + 5, y + 16, 2)
            cv.line(x + 5, y + 16, x + 2, y + 10, 2)
        case .disarmEnemy, .disarmingShot:
            cv.line(x + 4, y + 18, x + 17, y + 5, 2)
            cv.line(x + 7, y + 5, x + 16, y + 14, 2)
            cv.line(x + 4, y + 4, x + 18, y + 18, 2)
        case .battleCry, .eagleEye:
            cv.line(x + 4, y + 8, x + 8, y + 8, 3)
            cv.line(x + 8, y + 8, x + 12, y + 4, 2)
            cv.line(x + 8, y + 12, x + 12, y + 16, 2)
            cv.line(x + 14, y + 5, x + 19, y + 2, 2)
            cv.line(x + 14, y + 11, x + 20, y + 11, 2)
            cv.line(x + 14, y + 17, x + 19, y + 20, 2)
        case .fieldRepair:
            cv.line(x + 4, y + 5, x + 18, y + 19, 3)
            cv.line(x + 16, y + 3, x + 20, y + 7, 2)
            cv.line(x + 3, y + 16, x + 7, y + 20, 2)
        }
    }

    private func actionEquipmentText(_ descriptor: SkillTreeActionDescriptor) -> String {
        switch descriptor.equipment {
        case .sword: return "Sword required"
        case .bow: return "Bow and arrow required"
        case .none: return "Damaged gear and matching material required"
        }
    }

    private func fit(_ value: String, maxWidth: Int) -> String {
        guard maxWidth > 0 else { return "" }
        var result = value
        while textWidth(result) > maxWidth && result.count > 3 {
            result.removeLast()
        }
        if result.count < value.count {
            while textWidth(result + "...") > maxWidth && result.count > 1 {
                result.removeLast()
            }
            return result + "..."
        }
        return result
    }
}

/// One construction path for every in-game Skills entry point.  The screen
/// remains presentation-only; the closures call the GameCore authority seam
/// so local and LAN action requests cannot mutate state from the canvas.
func makeSkillTreeScreen() -> SkillTreeScreen {
    SkillTreeScreen(
        stateProvider: { $0.skillTreeStateSnapshot() },
        actionDispatcher: { $0.requestSkillTreeAction($1) },
        quickSlotProvider: { $0.skillTreeQuickSlot(for: $1) }
    )
}
