import Foundation
import ElysiumCore

/// Track-B character workspace. It renders one immutable committed Core model and routes every
/// actionable descriptor through UIManager's receipt-bound semantic activation boundary.
final class RPGCharacterScreen: Screen {
    private var interaction: RPGScreenInteractionState
    private var highContrast: Bool
    private var lastSemanticDispatchAccepted = false

    override init() {
        interaction = RPGScreenInteractionState()
        highContrast = false
        super.init()
        showHUD = true
        pausesGame = true
    }

    override var semanticSnapshot: RPGCommittedSemanticSnapshot? {
        rpgCommittedSemanticSnapshot
    }

    override var semanticRevision: UInt64 {
        rpgCommittedSemanticSnapshot?.semanticRevision ?? 0
    }

    override func focusSemanticElement(_ id: RPGUIElementID,
                                       _ ui: UIManager, _ game: GameCore) -> Bool {
        reduceInteraction(.focusElement(id), ui: ui, game: game)
    }

#if DEBUG
    init(tab: RPGCharacterTab, creation: RPGCreationSession = rpgInitialCreationSession(),
         focusedID: RPGUIElementID? = nil, scrollOffset: Double = 0) {
        interaction = RPGScreenInteractionState(
            creation: creation, tab: tab, focusedID: focusedID,
            scrollOffset: scrollOffset)
        highContrast = false
        super.init()
        showHUD = true
        pausesGame = true
    }
#endif

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        buttons.removeAll()
        sliders.removeAll()
        fields.removeAll()
        slots.removeAll()
        guard let runtime = MainActor.assumeIsolated({ game.rpgScreenRuntimeSnapshot() }) else {
            clearRPGPassiveSemanticSnapshot()
            ui.invalidateRPGAccessibilityCache()
            return
        }
        if runtime.state.created,
           interaction.tutorial.page == nil,
           interaction.tutorial.seenVersion < RPG_TUTORIAL_VERSION,
           runtime.tutorial.page != nil {
            interaction.tutorial = runtime.tutorial
        }
        func buildModel(scrollOffset: Double) -> RPGScreenModel {
            rpgBuildScreenModel(RPGScreenModelInput(
                state: runtime.state,
                quickSlots: runtime.quickSlots,
                localPreferenceScope: runtime.localPreferenceScope,
                localPreferenceRevision: runtime.localPreferenceRevision,
                localPreferenceWritable: runtime.localPreferenceWritable,
                localPreferenceStatus: runtime.localPreferenceStatus,
                worldEntryGeneration: runtime.worldEntryGeneration,
                authority: runtime.authority,
                rulesGeneration: runtime.rulesGeneration,
                inventoryRevision: runtime.inventoryRevision,
                equipmentFocusRevision: runtime.equipmentFocusRevision,
                equipmentSummary: runtime.equipmentSummary,
                focusSummary: runtime.focusSummary,
                configuredChords: runtime.configuredChords,
                inventoryCapacitySummary: runtime.inventoryCapacitySummary,
                inventoryCapacityAvailable: runtime.inventoryCapacityByPath[
                    interaction.creation.selectedPathID] == true,
                creation: interaction.creation,
                tutorial: interaction.tutorial,
                viewportWidth: ui.width,
                viewportHeight: ui.height,
                tab: interaction.tab,
                focusedID: interaction.focusedID,
                selection: interaction.selection,
                scrollOffset: scrollOffset,
                highContrast: runtime.highContrast,
                reduceMotion: runtime.reduceMotion))
        }
        let provisionalModel = buildModel(scrollOffset: interaction.scrollOffset)
        let needsAnchoredRebuild = rpgReconcileProvisionalScreenModel(
            &interaction, provisionalModel: provisionalModel)
        let model = needsAnchoredRebuild
            ? buildModel(scrollOffset: interaction.scrollOffset) : provisionalModel
        highContrast = runtime.highContrast
        _ = ui.commitRPGSemanticModel(model, runtime: runtime, to: self)
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.68)
        guard !rpgPassiveSemanticUnavailable,
              let snapshot = rpgCommittedSemanticSnapshot else {
            drawUnavailable(ui, "RPG screen unavailable")
            return
        }
        drawModel(snapshot.model, ui: ui, highContrast: highContrast)
    }

    override func inputOwnershipLost(_ ui: UIManager, _ game: GameCore) {
        _ = reduceInteraction(.inputOwnershipLost, ui: ui, game: game, rebuild: false)
    }

    override func onClose(_ ui: UIManager, _ game: GameCore) {
        _ = reduceInteraction(.inputOwnershipLost, ui: ui, game: game, rebuild: false)
    }

    // Mouse activation captures on button-down and dispatches only on a matching button-up.
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double,
                              _ my: Double, _ btn: Int) -> Bool {
        _ = reduceInteraction(.cancelMouse, ui: ui, game: game, rebuild: false)
        guard btn == 0,
              let model = rpgCommittedSemanticSnapshot?.model,
              let descriptor = rpgScreenDescriptor(atX: mx, y: my, in: model) else { return false }
        let capture = descriptor.isActionable ? MainActor.assumeIsolated {
            ui.captureRPGSemanticActivation(id: descriptor.id, on: self)
        } : nil
        let handled = reduceInteraction(
            .mouseDown(elementID: descriptor.id, capture: capture),
            ui: ui, game: game, rebuild: !descriptor.isActionable)
        return handled
    }
    override func onMouseUp(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        let releasedID: RPGUIElementID?
        if let model = rpgCommittedSemanticSnapshot?.model {
            releasedID = rpgScreenDescriptor(atX: mx, y: my, in: model)?.id
        } else {
            releasedID = nil
        }
        _ = reduceInteraction(.mouseUp(elementID: releasedID),
                              ui: ui, game: game, rebuild: false)
    }
    override func onMouseMove(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {}
    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        reduceInteraction(.scrollRows(dy >= 0 ? 1 : -1), ui: ui, game: game)
    }
    override func onKeyEvent(_ ui: UIManager, _ game: GameCore,
                             _ event: ElysiumKeyEvent) -> Bool {
        if event.terminal.rawValue == "Tab" {
            return reduceInteraction(event.modifiers.contains(.shift) ? .focusPrevious : .focusNext,
                                     ui: ui, game: game)
        }
        return onKey(ui, game, event.terminal.rawValue)
    }
    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        switch key {
        case "Tab": return reduceInteraction(.focusNext, ui: ui, game: game)
        case "ArrowUp": return reduceInteraction(.moveFocus(.up), ui: ui, game: game)
        case "ArrowDown": return reduceInteraction(.moveFocus(.down), ui: ui, game: game)
        case "ArrowLeft": return reduceInteraction(.moveFocus(.left), ui: ui, game: game)
        case "ArrowRight": return reduceInteraction(.moveFocus(.right), ui: ui, game: game)
        case "Enter", "Space":
            return reduceInteraction(.activateFocused, ui: ui, game: game, rebuild: false)
        case "PageUp": return reduceInteraction(.scrollRows(-1), ui: ui, game: game)
        case "PageDown": return reduceInteraction(.scrollRows(1), ui: ui, game: game)
        default: return false
        }
    }
    override func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool { false }

    /// Physical controller ingress reuses the same pure interaction reducer and semantic capture
    /// boundary as keyboard input. No controller callback owns an independent screen mutation path.
    func handleRPGControllerCommand(_ command: RPGSemanticCommand,
                                    ui: UIManager, game: GameCore) -> Bool {
        lastSemanticDispatchAccepted = false
        switch command {
        case .moveFocus(let direction):
            return reduceInteraction(.moveFocus(direction), ui: ui, game: game)
        case .activate:
            let handled = reduceInteraction(.activateFocused, ui: ui, game: game,
                                            rebuild: false, activationSource: .controller)
            return handled && lastSemanticDispatchAccepted
        case .back, .previousTab, .nextTab:
            return reduceInteraction(
                .applyCommand(command, tutorialCompletionPublished:
                    game.settings.rpgTutorialVersion == RPG_TUTORIAL_VERSION),
                ui: ui, game: game)
        case .scrollRows(let rows):
            return reduceInteraction(.scrollRows(rows), ui: ui, game: game)
        default:
            return false
        }
    }

    override func handleRPGPresentationCommand(_ command: RPGSemanticCommand,
                                               _ ui: UIManager, _ game: GameCore) -> Bool {
        reduceInteraction(.applyCommand(
            command, tutorialCompletionPublished:
                game.settings.rpgTutorialVersion == RPG_TUTORIAL_VERSION),
            ui: ui, game: game, rebuild: false)
    }

    @discardableResult
    private func reduceInteraction(_ event: RPGScreenInteractionEvent,
                                   ui: UIManager, game: GameCore,
                                   rebuild: Bool = true,
                                   activationSource: RPGSemanticActivationSource = .keyboard) -> Bool {
        guard let snapshot = rpgCommittedSemanticSnapshot,
              let context = RPGScreenInteractionContext(
                model: snapshot.model, screenInstanceID: snapshot.screenInstanceID,
                semanticRevision: snapshot.semanticRevision) else { return false }
        let transition = rpgReduceScreenInteraction(interaction, event: event, context: context)
        interaction = transition.state
        for effect in transition.effects {
            switch effect {
            case .activate(let id):
                guard let capture = MainActor.assumeIsolated({
                    ui.captureRPGSemanticActivation(id: id, on: self)
                }) else { continue }
                let result = MainActor.assumeIsolated {
                    ui.dispatchRPGSemanticActivation(
                        capture, source: activationSource, on: self, game: game)
                }
                if case .dispatched = result { lastSemanticDispatchAccepted = true }
            case .dispatchMouse(let capture):
                _ = MainActor.assumeIsolated {
                    ui.dispatchRPGSemanticActivation(
                        capture, source: .mouse, on: self, game: game)
                }
            case .cancelMouse(let capture):
                MainActor.assumeIsolated { ui.cancelRPGSemanticActivation(capture) }
            case .close:
                if ui.current() === self {
                    elysiumMainActorSync { ui.closeTop(game) }
                }
            }
        }
        if rebuild, ui.current() === self { initScreen(ui, game) }
        return transition.handled
    }

    private func drawUnavailable(_ ui: UIManager, _ message: String) {
        let width = min(420.0, max(260.0, ui.width - 24))
        let height = 92.0
        let x = ((ui.width - width) / 2).rounded(.down)
        let y = ((ui.height - height) / 2).rounded(.down)
        ui.drawPanel(x, y, width, height)
        ui.cv.drawTextCentered("RPG", x + width / 2, y + 18, 1.5, "#202020", shadow: false)
        ui.cv.drawTextCentered(clipped(message, characters: max(18, Int(width / 6.5))),
                               x + width / 2, y + 50, 1, "#7a2020", shadow: false)
    }

    private func drawModel(_ model: RPGScreenModel, ui: UIManager, highContrast: Bool) {
        guard model.panelFrame.width > 0, model.panelFrame.height > 0 else {
            drawUnavailable(ui, model.errorText ?? "Window is too small for the RPG screen")
            return
        }
        let panel = model.panelFrame
        ui.drawPanel(panel.x, panel.y, panel.width, panel.height)

        let ink = highContrast ? "#000000" : "#202020"
        let secondary = highContrast ? "#202020" : "#4a4a4a"
        ui.cv.drawText(model.headerText, model.layout.headerFrame.x + 4,
                       model.layout.headerFrame.y + 5, 1.5, ink, shadow: false)
        let authorityFrame = model.layout.authorityChipFrame
        drawAuthorityIcon(model.authority.proceduralIconID,
                          x: authorityFrame.x + 2, y: authorityFrame.y + 1,
                          ui: ui, highContrast: highContrast)
        ui.cv.drawText(model.authority.visibleTitle, authorityFrame.x + 24,
                       authorityFrame.y + 3, 1,
                       authorityColor(model.statusText, highContrast: highContrast),
                       shadow: false)
        if let statusDescriptor = model.descriptors.first(where: {
            $0.id.rawValue == "status:current"
        }) {
            if let status = model.status {
                drawStatusIcon(status.kind, x: statusDescriptor.frame.x + 4,
                               y: statusDescriptor.frame.y + 1,
                               ui: ui, highContrast: highContrast)
            }
            ui.cv.drawText("Status", statusDescriptor.frame.x + 26,
                           statusDescriptor.frame.y + 3, 0.8,
                           authorityColor(model.statusText,
                                          highContrast: highContrast), shadow: false)
        }
        if let detailFrame = model.layout.contextualDetailFrame {
            for (index, line) in model.contextualDetailLines.enumerated() {
                ui.cv.drawText(line, detailFrame.x + 4,
                               detailFrame.y + 2 + Double(index) * 12,
                               0.8, secondary, shadow: false)
            }
        }

        ui.cv.setFill(highContrast ? "#000000" : "#777777")
        ui.cv.fillRect(model.contentFrame.x, model.contentFrame.y - 2,
                       model.contentFrame.width, 1)

        for descriptor in model.visibleDescriptors {
            if descriptor.id.rawValue == "authority:phase" ||
                descriptor.id.rawValue == "status:current" ||
                descriptor.id.rawValue == "contextual-detail" { continue }
            drawDescriptor(descriptor, focusedID: model.focusedID, ui: ui,
                           highContrast: highContrast)
        }
        if model.focusedID?.rawValue == "authority:phase" {
            let frame = model.descriptors.first { $0.id.rawValue == "authority:phase" }?.frame
            if let frame {
                drawFocusRing(frame: frame, ui: ui, highContrast: highContrast)
            }
        }
        if model.focusedID?.rawValue == "status:current",
           let frame = model.descriptors.first(where: {
               $0.id.rawValue == "status:current"
           })?.frame {
            drawFocusRing(frame: frame, ui: ui, highContrast: highContrast)
        }

        let footer: String
        if ui.rpgControllerHelpPrimary {
            footer = "RPG controller: D-pad/A/B · Keyboard: Tab/Arrows/Enter/Escape"
        } else {
            footer = model.footerText.isEmpty ? "Ready" : model.footerText
        }
        ui.cv.drawText(footer, model.layout.footerHelpFrame.x + 4,
                       model.layout.footerHelpFrame.y + 3, 0.85,
                       secondary, shadow: false)
    }

    private func drawDescriptor(_ descriptor: RPGSemanticDescriptor,
                                focusedID: RPGUIElementID?, ui: UIManager,
                                highContrast: Bool) {
        guard let frame = descriptor.visibleFrame, frame.width > 0, frame.height > 0 else { return }
        guard rpgDescriptorVisualLinesFit(
            frame: descriptor.frame, iconAssetID: descriptor.iconAssetID,
            visualLines: descriptor.visualLines) else { return }
        let focused = descriptor.id == focusedID
        let selected = descriptor.selected || descriptor.prepared || descriptor.slotted
        let background: String
        if descriptor.locked || !descriptor.enabled {
            background = highContrast ? "#d0d0d0" : "#a6a6a6"
        } else if selected {
            background = highContrast ? "#ffffff" : "#d9e9c4"
        } else {
            background = highContrast ? "#ffffff" : "#d8d8d8"
        }
        ui.cv.setFill(background)
        ui.cv.fillRect(frame.x, frame.y, frame.width, frame.height)
        ui.cv.setStroke(highContrast ? "#000000" : "#777777")
        ui.cv.strokeRect(frame.x, frame.y, frame.width, frame.height, 1)
        if descriptor.adornment == .selectedCheckDoubleBorder {
            ui.cv.strokeRect(frame.x + 2, frame.y + 2,
                             max(1, frame.width - 4), max(1, frame.height - 4), 1)
            ui.cv.drawText("✓", frame.maxX - 14, frame.y + 3, 0.9,
                           highContrast ? "#000000" : "#275d20", shadow: false)
        } else if descriptor.adornment == .moveLeft {
            ui.cv.line(frame.x + 3, frame.y + frame.height / 2,
                       frame.x + 9, frame.y + frame.height / 2 - 4, 1)
            ui.cv.line(frame.x + 3, frame.y + frame.height / 2,
                       frame.x + 9, frame.y + frame.height / 2 + 4, 1)
        } else if descriptor.adornment == .moveRight {
            ui.cv.line(frame.maxX - 3, frame.y + frame.height / 2,
                       frame.maxX - 9, frame.y + frame.height / 2 - 4, 1)
            ui.cv.line(frame.maxX - 3, frame.y + frame.height / 2,
                       frame.maxX - 9, frame.y + frame.height / 2 + 4, 1)
        }

        let inset = 4.0
        let labelColor = descriptor.locked || !descriptor.enabled ? "#555555" : "#202020"
        var textX = frame.x + inset
        if let icon = descriptor.iconAssetID {
            ui.cv.drawRPGIcon(icon, frame.x + 4, frame.y + 4, 24, 24)
            textX += 28
        }
        for (index, line) in descriptor.visualLines.enumerated() {
            let lineY = frame.y + 4 + Double(index) * 9
            ui.cv.drawText(line, textX, lineY,
                           index == 0 ? 0.9 : 0.7,
                           index == 0 ? labelColor : (highContrast ? "#202020" : "#4f4f4f"),
                           shadow: false)
        }
        if focused {
            drawFocusRing(frame: frame, ui: ui, highContrast: highContrast)
        }
        if descriptor.locked, frame.width >= 70 {
            ui.cv.drawText("Locked", frame.maxX - 42, frame.y + 4, 0.7,
                           highContrast ? "#000000" : "#7a2020", shadow: false)
        } else if descriptor.prepared, frame.width >= 82 {
            ui.cv.drawText("Prepared", frame.maxX - 52, frame.y + 4, 0.7,
                           highContrast ? "#000000" : "#275d20", shadow: false)
        } else if descriptor.slotted, frame.width >= 72 {
            ui.cv.drawText("Slotted", frame.maxX - 44, frame.y + 4, 0.7,
                           highContrast ? "#000000" : "#275d20", shadow: false)
        } else if descriptor.selected, frame.width >= 80 {
            ui.cv.drawText("Selected", frame.maxX - 50, frame.y + 4, 0.7,
                           highContrast ? "#000000" : "#275d20", shadow: false)
        }
    }

    private func drawFocusRing(frame: RPGLogicalRect, ui: UIManager,
                               highContrast: Bool) {
        let token = rpgFocusRingToken(highContrast: highContrast)
        guard let geometry = rpgFocusRingGeometry(frame: frame, token: token) else { return }
        ui.cv.setStroke("#ffffff")
        ui.cv.strokeRect(geometry.lightOuterFrame.x, geometry.lightOuterFrame.y,
                         geometry.lightOuterFrame.width, geometry.lightOuterFrame.height,
                         token.lightOuterWidth)
        ui.cv.setStroke("#202020")
        ui.cv.strokeRect(geometry.darkSeparationFrame.x, geometry.darkSeparationFrame.y,
                         geometry.darkSeparationFrame.width, geometry.darkSeparationFrame.height,
                         token.darkSeparationWidth)
    }

    private func authorityColor(_ status: String,
                                highContrast: Bool) -> String {
        if highContrast { return "#000000" }
        if status == "Ready" { return "#275d20" }
        if status.localizedCaseInsensitiveContains("unavailable") ||
            status.localizedCaseInsensitiveContains("exhausted") { return "#7a2020" }
        return "#705810"
    }

    private func drawAuthorityIcon(_ identifier: String, x: Double, y: Double,
                                   ui: UIManager, highContrast: Bool) {
        let color = highContrast ? "#000000" : "#202020"
        let width = highContrast ? 2.0 : 1.0
        let cv = ui.cv
        cv.setStroke(color)
        cv.setFill(color)
        switch identifier {
        case "authority.ready":
            cv.line(x + 1, y + 8, x + 6, y + 13, width)
            cv.line(x + 6, y + 13, x + 16, y + 2, width)
        case "authority.awaitingHost":
            cv.strokeRect(x + 2, y + 1, 14, 16, width)
            cv.line(x + 3, y + 2, x + 15, y + 16, width)
            cv.line(x + 15, y + 2, x + 3, y + 16, width)
        case "authority.savingAccepted", "authority.savingRejected":
            cv.strokeRect(x + 1, y + 1, 16, 16, width)
            cv.strokeRect(x + 5, y + 2, 8, 5, width)
            if identifier == "authority.savingAccepted" {
                cv.line(x + 4, y + 11, x + 7, y + 14, width)
                cv.line(x + 7, y + 14, x + 14, y + 8, width)
            } else {
                cv.line(x + 4, y + 9, x + 14, y + 15, width)
                cv.line(x + 14, y + 9, x + 4, y + 15, width)
            }
        case "authority.reconnecting":
            cv.line(x + 3, y + 5, x + 13, y + 5, width)
            cv.line(x + 13, y + 5, x + 10, y + 2, width)
            cv.line(x + 15, y + 13, x + 5, y + 13, width)
            cv.line(x + 5, y + 13, x + 8, y + 16, width)
            cv.line(x + 3, y + 5, x + 3, y + 10, width)
            cv.line(x + 15, y + 8, x + 15, y + 13, width)
        case "authority.finalizing":
            cv.line(x + 2, y + 5, x + 5, y + 16, width)
            cv.line(x + 5, y + 16, x + 13, y + 16, width)
            cv.line(x + 13, y + 16, x + 16, y + 5, width)
            cv.line(x + 16, y + 5, x + 2, y + 5, width)
            cv.fillRect(x + 7, y + 9, 4, 4)
        case "authority.exhausted":
            let points = [(5.0, 1.0), (13, 1), (17, 5), (17, 13),
                          (13, 17), (5, 17), (1, 13), (1, 5), (5, 1)]
            for index in 0..<(points.count - 1) {
                cv.line(x + points[index].0, y + points[index].1,
                        x + points[index + 1].0, y + points[index + 1].1, width)
            }
        case "authority.unavailable":
            cv.strokeRect(x + 3, y + 8, 12, 9, width)
            cv.line(x + 6, y + 8, x + 6, y + 5, width)
            cv.line(x + 6, y + 5, x + 9, y + 2, width)
            cv.line(x + 9, y + 2, x + 12, y + 5, width)
            cv.line(x + 12, y + 5, x + 12, y + 8, width)
        default:
            cv.strokeRect(x + 2, y + 2, 14, 14, width)
        }
    }

    private func drawStatusIcon(_ kind: RPGStatusKind, x: Double, y: Double,
                                ui: UIManager, highContrast: Bool) {
        let cv = ui.cv
        let color = highContrast ? "#000000" : "#202020"
        let width = highContrast ? 2.0 : 1.0
        cv.setStroke(color)
        cv.setFill(color)
        switch kind {
        case .success:
            cv.line(x + 1, y + 7, x + 5, y + 12, width)
            cv.line(x + 5, y + 12, x + 15, y + 2, width)
        case .pending:
            cv.strokeRect(x + 2, y + 1, 12, 14, width)
            cv.line(x + 3, y + 2, x + 13, y + 14, width)
            cv.line(x + 13, y + 2, x + 3, y + 14, width)
        case .rejection:
            cv.line(x + 2, y + 2, x + 14, y + 14, width)
            cv.line(x + 14, y + 2, x + 2, y + 14, width)
        case .cooldown:
            cv.strokeRect(x + 1, y + 1, 14, 14, width)
            cv.line(x + 8, y + 8, x + 8, y + 3, width)
            cv.line(x + 8, y + 8, x + 13, y + 8, width)
        case .fatigue:
            cv.line(x + 2, y + 14, x + 8, y + 1, width)
            cv.line(x + 8, y + 1, x + 7, y + 8, width)
            cv.line(x + 7, y + 8, x + 14, y + 7, width)
        case .missingFocus:
            cv.strokeRect(x + 2, y + 2, 12, 12, width)
            cv.line(x + 8, y, x + 8, y + 16, width)
            cv.line(x, y + 8, x + 16, y + 8, width)
        case .missingEquipment:
            cv.strokeRect(x + 3, y + 1, 10, 14, width)
            cv.line(x + 3, y + 8, x + 13, y + 8, width)
        case .permissionDenied:
            cv.strokeRect(x + 2, y + 7, 12, 9, width)
            cv.line(x + 5, y + 7, x + 5, y + 4, width)
            cv.line(x + 5, y + 4, x + 8, y + 1, width)
            cv.line(x + 8, y + 1, x + 11, y + 4, width)
            cv.line(x + 11, y + 4, x + 11, y + 7, width)
        case .persistenceFailure:
            cv.strokeRect(x + 1, y + 1, 14, 14, width)
            cv.strokeRect(x + 4, y + 2, 8, 4, width)
            cv.line(x + 3, y + 13, x + 13, y + 8, width)
        case .authorityExhausted:
            cv.strokeRect(x + 1, y + 1, 14, 14, width)
            cv.line(x + 3, y + 8, x + 13, y + 8, width)
        }
    }

    private func clipped(_ text: String, characters: Int) -> String {
        let limit = max(1, characters)
        guard text.count > limit else { return text }
        guard limit > 1 else { return "…" }
        return String(text.prefix(limit - 1)) + "…"
    }
}
