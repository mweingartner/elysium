// Menus — title screen, world select/create, pause,
// settings (video/audio/controls/accessibility), advancements tree, credits.

import AppKit
import CryptoKit
import Foundation
import QuartzCore
import ElysiumCore

private func savedWorldCanvasName(_ raw: String, maximumAdvance: Int) -> String {
    let escaped = savedWorldDisplayName(raw)
    guard textWidth(escaped) > maximumAdvance else { return escaped }
    var result = ""
    for character in escaped {
        let candidate = result + String(character) + "…"
        if textWidth(candidate) > maximumAdvance { break }
        result.append(character)
    }
    return result + "…"
}

// =============================================================================
final class TitleScreen: Screen {
    var splash = ""
    static let SPLASHES = [
        "Punch a tree!", "Watch out for creepers!", "Don't dig straight down!",
        "Diamonds run deep!", "Now with wardens!", "Sculk is listening!",
        "The dragon is waiting!", "Cherry blossoms!", "Archaeology!",
        "Goats will punt you!", "Trade with villagers!", "Ride a strider!",
        "X marks the buried treasure!", "Hero of the Village!", "Open to LAN!",
        "Do not stare at endermen!", "Beds explode in the Nether!", "Llamas spit back!",
        "Lava is not a swimming pool!", "Blame the goat!", "Bring a bucket!",
        "Mostly bug free!", "Creepers hate him!", "The chickens are watching!",
    ]
    override init() {
        super.init()
        closeOnEsc = false
    }
    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        if splash.isEmpty { splash = TitleScreen.SPLASHES[Int.random(in: 0..<TitleScreen.SPLASHES.count)] }
        let cx = (ui.width / 2).rounded(.down)
        // vanilla layout: stacked main buttons at h/4+48, then a half-width row
        var y = (ui.height / 4).rounded(.down) + 48
        buttons.append(Button(cx - 100, y, 200, 20, "Singleplayer", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(WorldSelectScreen(), game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Multiplayer", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(LANLobbyScreen(), game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Credits", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(CreditsScreen(), game)
        }))
        y += 36
        buttons.append(Button(cx - 100, y, 98, 20, "Options...", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(SettingsScreen(), game)
        }))
        buttons.append(Button(cx + 2, y, 98, 20, "Quit Game", {
            NSApp.terminate(nil)
        }))
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        let cv = ui.cv
        let now = CACurrentMediaTime() * 1000
        if !ui.titlePhoto {
            // no photo bundled: animated gradient sky + floating cubes fallback
            let t = CACurrentMediaTime() * 1000 / 30000
            let top = "hsl(\(215 + Foundation.sin(t) * 12), 55%, \(28 + Foundation.sin(t * 1.7) * 6)%)"
            let bottom = "hsl(\(230 + Foundation.cos(t) * 10), 45%, 12%)"
            cv.fillRect(0, 0, ui.width, ui.height, top: top, bottom: bottom)
            for i in 0..<24 {
                let fx = (Double(i) * 137.5 + now / Double(90 + i * 7)).truncatingRemainder(dividingBy: ui.width + 40) - 20
                let fy = 20 + Double((i * 53) % max(1, Int(ui.height) - 60))
                let size = Double(3 + (i % 4) * 2)
                cv.setFill("hsla(\(110 + i * 17 % 120), 35%, \(30 + i % 30)%, 0.25)")
                cv.fillRect(fx, fy, size, size)
            }
        }
        // wordmark: textured logo when bundled, block-shadowed text otherwise
        let logoY = (ui.height / 4).rounded(.down) - 26
        if !ui.titleLogo {
            cv.drawTextCentered("ELYSIUM", ui.width / 2 + 2, logoY + 2, 4, "#1c1c1c", shadow: false)
            cv.drawTextCentered("ELYSIUM", ui.width / 2, logoY, 4, "#e8e8e8", shadow: false)
        }
        // splash anchored to the logo's right edge
        cv.save()
        cv.translate(ui.width / 2 + 92, logoY + 26)
        cv.rotate(-0.25)
        let pulse = 1 + Foundation.sin(now / 250) * 0.06
        cv.scale(pulse, pulse)
        cv.drawTextCentered(splash, 0, 0, 1, "#ffff55")
        cv.restore()
        cv.drawText("Elysium \(ELYSIUM_VERSION)", 2, ui.height - 10, 1, "#c8c8c8")
        cv.drawText("Textures: Faithful 32x (faithfulpack.net)", 2, ui.height - 20, 1, "#909090")
        let credit = "LAN multiplayer"
        cv.drawText(credit, ui.width - Double(textWidth(credit)) - 2, ui.height - 10, 1, "#c8c8c8")
        ui.drawButtons(self)
    }
}

// =============================================================================
final class WorldSelectScreen: Screen {
    private enum Phase {
        case loading
        case ready
        case loadFailure
        case prechecking
        case confirming(SavedWorldDeleteRequest, [String])
        case deleting(SavedWorldDeleteRequest, [String])
        case deleteFailure(SavedWorldDeleteRequest, [String])
        case stale
        case success(String)
        case terminal(SavedWorldDeleteRequest, [String], SavedWorldDeleteRecoveryAuthority?, Bool)
        case terminalReloading(SavedWorldDeleteRequest, [String], SavedWorldDeleteRecoveryAuthority?)
    }

    private let lanHostRequest: LANHostLaunchRequest?
    private let launchContextIdentity: UUID
    private var snapshot: CheckedSavedWorldSnapshot?
    private var selection = SavedWorldSelectionState()
    private var phase: Phase = .loading
    private var operationGeneration: UInt64 = 0
    private var accessibilityActionGeneration: UInt64 = 0
    private var openingPointerEvents = SavedWorldPointerEventConsumption()
    private var maintenanceToken: SavedWorldMaintenanceCoordinator.Token?
    private weak var maintenanceGame: GameCore?
    private weak var maintenanceUI: UIManager?
    private var activeDeleteOperation: SavedWorldDeleteOperation?
    private var deferredOutcome: SavedWorldDeleteOutcome?
    private var destructiveAdmissionAccepted = false
    private var scroll = 0.0
    private var statusAnnouncement: String?
    private var modalFocus = 0
    /// Toolbar, list, Play/Host, Delete, Create New, Back.
    private var keyboardFocus = 1
    private var modalNameScroll = 0
    private var lastWidth = 360.0
    private var lastHeight = 224.0
    private var playBtn: Button!
    private var deleteBtn: Button!
    private var createBtn: Button!
    private var selectAllBtn: Button!
    private var clearAllBtn: Button!
    private var backBtn: Button!

    init(lanHostRequest: LANHostLaunchRequest? = nil) {
        self.lanHostRequest = lanHostRequest
        launchContextIdentity = lanHostRequest?.identity ?? UUID()
        super.init()
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        maintenanceGame = game
        maintenanceUI = ui
        installControls(ui, game)
        reload(ui: ui, game: game)
    }

    override func relayoutScreen(_ ui: UIManager, _ game: GameCore) {
        installControls(ui, game)
    }

    /// Layout-only control reconstruction. This must not touch phase,
    /// operation generation, selection/focus, modal state, maintenance lease,
    /// operation ownership, or storage.
    private func installControls(_ ui: UIManager, _ game: GameCore) {
        buttons.removeAll(keepingCapacity: true)
        sliders.removeAll(keepingCapacity: true)
        fields.removeAll(keepingCapacity: true)
        slots.removeAll(keepingCapacity: true)
        selectAllBtn = Button(0, 0, 150, 20, "Select All", {
            [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            self.commitSelectionMutation(ui: ui, game: game) { $0.selectAll() }
        })
        clearAllBtn = Button(0, 0, 150, 20, "Clear All", {
            [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            self.commitSelectionMutation(ui: ui, game: game) { $0.clearAll() }
        })
        playBtn = Button(0, 0, 100, 20,
                         lanHostRequest == nil ? "Play Selected" : "Host Selected",
                         { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            self.openFocusedWorld(ui: ui, game: game)
        })
        deleteBtn = Button(0, 0, 100, 20, "Delete", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            self.beginDeletePrecheck(ui: ui, game: game)
        })
        createBtn = Button(0, 0, 100, 20, "Create New", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game, self.isReady else { return }
            ui.open(WorldCreateScreen(lanHostRequest: self.lanHostRequest), game)
        })
        backBtn = Button(0, 0, 200, 20, "Back", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game, self.isReady else { return }
            ui.closeTop(game)
        })
        buttons.append(selectAllBtn)
        buttons.append(clearAllBtn)
        buttons.append(playBtn)
        buttons.append(deleteBtn)
        buttons.append(createBtn)
        buttons.append(backBtn)
        applyLayout(SavedWorldSelectionLayout(width: ui.width, height: ui.height))
    }

    /// The sole user-selection commit boundary. A rejected or idempotent
    /// mutation leaves the retained tree untouched; every accepted state
    /// change synchronously retires and republishes it exactly once.
    @discardableResult
    private func commitSelectionMutation(
        ui: UIManager, game: GameCore,
        prepareAccessibility: () -> Void = {},
        _ mutation: (inout SavedWorldSelectionState) -> Void
    ) -> Bool {
        guard isReady else { return false }
        let previous = selection
        mutation(&selection)
        guard selection != previous else { return false }
        prepareAccessibility()
        ui.renewTextAccessibilityPresentation(screen: self, game: game)
        return true
    }

    private var isReady: Bool {
        switch phase { case .ready, .stale, .success: return true; default: return false }
    }

    @discardableResult
    private func advanceOperationGeneration() -> UInt64? {
        let next = operationGeneration.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue != 0 else { return nil }
        operationGeneration = next.partialValue
        return operationGeneration
    }

    private func publishPhase(_ nextPhase: Phase, ui: UIManager, game: GameCore) {
        phase = nextPhase
        let next = accessibilityActionGeneration.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue != 0 else {
            phase = .loadFailure
            setControlsEnabled(false)
            ui.renewTextAccessibilityPresentation(screen: self, game: game)
            return
        }
        accessibilityActionGeneration = next.partialValue
        ui.renewTextAccessibilityPresentation(screen: self, game: game)
    }

    private func destructiveAccessibilityID(
        _ kind: String, request: SavedWorldDeleteRequest? = nil
    ) -> String {
        var identity = Data()
        if let request { identity = savedWorldDeleteRequestIdentity(request) }
        let token = maintenanceToken?.value ?? 0
        return savedWorldDestructiveAccessibilityID(
            kind: kind, screenIdentity: textScreenIdentity,
            actionGeneration: accessibilityActionGeneration,
            leaseToken: token, requestIdentity: identity) ?? "worlds.action.invalid"
    }

    private func applyLayout(_ layout: SavedWorldSelectionLayout) {
        selectAllBtn.x = layout.toolbar.x + 208
        selectAllBtn.y = layout.toolbar.y
        selectAllBtn.w = 100
        clearAllBtn.x = layout.toolbar.x + 208
        clearAllBtn.y = layout.toolbar.y
        clearAllBtn.w = 100
        for (button, frame) in zip([playBtn!, deleteBtn!, createBtn!], layout.primaryButtons) {
            button.x = frame.x; button.y = frame.y; button.w = frame.width; button.h = frame.height
        }
        backBtn.x = layout.backButton.x; backBtn.y = layout.backButton.y
        backBtn.w = layout.backButton.width; backBtn.h = layout.backButton.height
    }

    private func requestForOutcomePhase(
        _ expectedPhase: SavedWorldOutcomeReductionPhase
    ) -> SavedWorldDeleteRequest? {
        switch (expectedPhase, phase) {
        case (.deleting, .deleting(let request, _)),
             (.terminal, .terminal(let request, _, _, _)),
             (.terminalReloading, .terminalReloading(let request, _, _)):
            return request
        case (.prechecking, .prechecking):
            return nil
        case (.confirming, .confirming(let request, _)):
            return request
        default:
            return nil
        }
    }

    private func outcomeBinding(
        phase expectedPhase: SavedWorldOutcomeReductionPhase,
        request: SavedWorldDeleteRequest,
        generation: UInt64,
        token: SavedWorldMaintenanceCoordinator.Token
    ) -> SavedWorldOutcomeReductionBinding {
        SavedWorldOutcomeReductionBinding(
            screenIdentity: textScreenIdentity,
            operationGeneration: generation,
            phase: expectedPhase,
            leaseToken: token.value,
            requestIdentity: savedWorldDeleteRequestIdentity(request),
            launchContextIdentity: launchContextIdentity)
    }

    @MainActor
    private func preserveUnclaimedOutcome(
        _ outcome: SavedWorldDeleteOutcome,
        request: SavedWorldDeleteRequest, names: [String],
        token: SavedWorldMaintenanceCoordinator.Token,
        operation: SavedWorldDeleteOperation,
        ui: UIManager, game: GameCore
    ) {
        guard ui.current() === self,
              maintenanceToken == token,
              activeDeleteOperation === operation,
              game.revalidateSavedWorldMaintenance(token) else { return }
        deferredOutcome = outcome
        let authority: SavedWorldDeleteRecoveryAuthority?
        if case .terminalRecovery(let value) = outcome { authority = value }
        else { authority = nil }
        publishPhase(.terminal(request, names, authority, true), ui: ui, game: game)
        setControlsEnabled(false)
    }

    /// The sole main-actor claim boundary. Every live UI identity is checked
    /// before GameCore can consume the operation's pending classification.
    @MainActor
    private func claimOutcomeIfCurrent(
        _ outcome: SavedWorldDeleteOutcome,
        expected: SavedWorldOutcomeReductionBinding,
        expectedPhase: SavedWorldOutcomeReductionPhase,
        request: SavedWorldDeleteRequest, names: [String],
        token: SavedWorldMaintenanceCoordinator.Token,
        operation: SavedWorldDeleteOperation,
        ui: UIManager, game: GameCore
    ) -> Bool {
        let currentRequest = requestForOutcomePhase(expectedPhase)
        let current = currentRequest.map {
            outcomeBinding(
                phase: expectedPhase, request: $0,
                generation: operationGeneration, token: token)
        }
        guard ui.current() === self,
              maintenanceToken == token,
              activeDeleteOperation === operation,
              let currentRequest, let current,
              savedWorldOutcomeReductionMatches(expected: expected, current: current),
              savedWorldConstantTimeEqual32(
                savedWorldDeleteRequestIdentity(currentRequest),
                savedWorldDeleteRequestIdentity(request)),
              currentRequest.expectations == request.expectations,
              game.revalidateSavedWorldMaintenance(token),
              game.finishSavedWorldDeleteOperation(
                operation, outcome: outcome,
                screenIdentity: expected.screenIdentity,
                launchContextIdentity: expected.launchContextIdentity) else {
            preserveUnclaimedOutcome(
                outcome, request: request, names: names,
                token: token, operation: operation, ui: ui, game: game)
            return false
        }
        return true
    }

    private func maxScroll(_ layout: SavedWorldSelectionLayout) -> Double {
        max(0, Double(snapshot?.rows.count ?? 0) * 30 - layout.list.height)
    }

    private func reload(ui: UIManager, game: GameCore, success: String? = nil) {
        guard let generation = advanceOperationGeneration() else {
            phase = .loadFailure; setControlsEnabled(false); releaseMaintenanceLease(); return
        }
        publishPhase(.loading, ui: ui, game: game)
        setControlsEnabled(false)
        let leaseAtStart = maintenanceToken
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            let result = Result { try game.checkedWorldSnapshot() }
            DispatchQueue.main.async { [weak self, weak ui, weak game] in
                guard let game else { return }
                guard let self, let ui, ui.current() === self,
                      self.operationGeneration == generation else {
                    if success != nil, let leaseAtStart {
                        elysiumMainActorSync {
                            game.releaseSavedWorldMaintenance(leaseAtStart)
                        }
                    }
                    return
                }
                switch result {
                case .success(let checked):
                    self.snapshot = checked
                    self.selection.refresh(orderedIDs: checked.orderedIDs)
                    self.scroll = min(self.scroll, self.maxScroll(
                        SavedWorldSelectionLayout(width: ui.width, height: ui.height)))
                    self.publishPhase(success.map(Phase.success) ?? .ready, ui: ui, game: game)
                    self.statusAnnouncement = success
                    self.releaseMaintenanceLease()
                    self.setControlsEnabled(true)
                case .failure:
                    self.snapshot = nil
                    self.selection.refresh(orderedIDs: [])
                    self.publishPhase(.loadFailure, ui: ui, game: game)
                    self.releaseMaintenanceLease()
                    self.setControlsEnabled(false)
                }
            }
        }
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        lastWidth = ui.width
        lastHeight = ui.height
        ui.drawDirtBg()
        ui.cv.drawTextCentered(lanHostRequest == nil ? "Select World" : "Select World to Host", ui.width / 2, 10, 1)
        let layout = SavedWorldSelectionLayout(width: ui.width, height: ui.height)
        applyLayout(layout)
        let selectedCount = selection.selectedIDs.count
        let rowCount = snapshot?.rows.count ?? 0
        let allSelected = rowCount > 0 && selectedCount == rowCount
        playBtn.enabled = isReady && selectedCount == 1
        deleteBtn.enabled = isReady && selectedCount > 0
        selectAllBtn.enabled = isReady && !(snapshot?.rows.isEmpty ?? true)
        clearAllBtn.enabled = isReady && selectedCount > 0
        selectAllBtn.visible = !allSelected
        clearAllBtn.visible = allSelected
        createBtn.enabled = isReady
        backBtn.enabled = isReady
        switch phase {
        case .loading:
            ui.cv.drawTextCentered("Loading saved worlds…", ui.width / 2, 68, 1, "#a0a0a0")
        case .loadFailure:
            ui.cv.drawTextCentered("Worlds couldn’t be loaded.", ui.width / 2, 68, 1, "#ff5555")
            drawLoadFailureActions(ui, game)
        default:
            break
        }
        if isReady, snapshot?.rows.isEmpty == true {
            ui.cv.drawTextCentered("No worlds yet — create one!", ui.width / 2, 68, 1, "#a0a0a0")
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        scroll = min(max(0, scroll), maxScroll(layout))
        let listX = layout.list.x, top = layout.list.y, bottom = top + layout.list.height
        let selectionStatus = allSelected ? "All \(selectedCount) selected" : "\(selectedCount) selected"
        ui.cv.drawText(selectionStatus, layout.toolbar.x,
                       layout.toolbar.y + 6, 1, "#c8c8c8")
        for (i, row) in (snapshot?.rows ?? []).enumerated() {
            let y = top + Double(i) * 30 - scroll
            if y + 28 <= top || y >= bottom { continue }
            let w = row.record
            let hover = ui.mouseX >= listX && ui.mouseX < listX + layout.list.width &&
                ui.mouseY >= y && ui.mouseY < y + 28
            let selected = selection.selectedIDs.contains(row.storedID)
            ui.cv.setFill(selected ? "rgba(255,255,255,0.25)" :
                hover ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.3)")
            ui.cv.fillRect(listX, y, layout.list.width, 28)
            if selection.focusedID == row.storedID {
                ui.cv.setFill("#ffff55")
                ui.cv.fillRect(listX + 1, y + 1, layout.list.width - 2, 1)
                ui.cv.fillRect(listX + 1, y + 26, layout.list.width - 2, 1)
                ui.cv.fillRect(listX + 1, y + 1, 1, 26)
                ui.cv.fillRect(listX + layout.list.width - 2, y + 1, 1, 26)
            }
            ui.cv.setFill("#c6c6c6"); ui.cv.fillRect(listX + 9, y + 9, 10, 10)
            ui.cv.setFill("#373737"); ui.cv.fillRect(listX + 9, y + 9, 10, 1)
            if selected { ui.cv.drawText("x", listX + 11, y + 10, 1, "#202020", shadow: false) }
            ui.cv.drawText(savedWorldCanvasName(
                w.name, maximumAdvance: Int(layout.list.width - 34)), listX + 28, y + 4, 1)
            let when = fmt.string(from: Date(timeIntervalSince1970: w.lastPlayed / 1000))
            ui.cv.drawText("§7\(when) • \(w.gameMode == GameMode.creative ? "Creative" : "Survival") • seed \(w.seed)", listX + 28, y + 15, 1)
        }
        if maxScroll(layout) > 0 {
            let trackH = layout.list.height
            let thumbH = max(12, trackH * trackH / Double((snapshot?.rows.count ?? 1) * 30))
            let thumbY = top + (trackH - thumbH) * (scroll / maxScroll(layout))
            ui.cv.setFill("rgba(0,0,0,0.4)")
            ui.cv.fillRect(listX + layout.list.width + 2, top, 4, trackH)
            ui.cv.setFill("rgba(255,255,255,0.5)")
            ui.cv.fillRect(listX + layout.list.width + 2, thumbY, 4, thumbH)
        }
        ui.drawButtons(self)
        drawStatusAndModal(ui, game, layout: layout)
    }

    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        switch phase {
        case .confirming(_, let names), .deleteFailure(_, let names):
            let delta = dy > 0 ? 1 : dy < 0 ? -1 : 0
            modalNameScroll = max(0, min(max(0, names.count - 5), modalNameScroll + delta))
            return true
        default:
            break
        }
        guard isReady else { return true }
        let layout = SavedWorldSelectionLayout(width: ui.width, height: ui.height)
        scroll = min(max(0, scroll + dy * 12), maxScroll(layout))
        return true
    }

    override func onPointerDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double,
                                _ event: ScreenPointerEvent) -> Bool {
        guard elysiumMainActorSync({
            ui.validatesCurrentActiveKeyPointerEvent(event)
        }) else { return true }
        guard openingPointerEvents.consume(
            screenIdentity: textScreenIdentity,
            windowNumber: event.windowNumber,
            eventNumber: event.eventNumber) else { return true }
        if handleModalPointer(ui, game, mx: mx, my: my, event: event) { return true }
        guard isReady else { return true }
        if super.onPointerDown(ui, game, mx, my, event) { return true }
        guard event.button == 0 else { return false }
        let layout = SavedWorldSelectionLayout(width: ui.width, height: ui.height)
        let listX = layout.list.x, top = layout.list.y, bottom = top + layout.list.height
        guard my >= top, my < bottom, mx >= listX, mx < listX + layout.list.width else { return false }
        for (i, row) in (snapshot?.rows ?? []).enumerated() {
            let y = top + Double(i) * 30 - scroll
            if y + 28 <= top || y >= bottom { continue }
            if my >= y && my < y + 28 {
                let checkboxHit = mx >= listX + 4 && mx < listX + 24
                    && my >= y + 4 && my < y + 24
                let gesture: SavedWorldSelectionGesture
                if checkboxHit { gesture = .toggle }
                else if event.command && event.shift { gesture = .extendRange }
                else if event.shift { gesture = .range }
                else if event.command { gesture = .toggle }
                else { gesture = .plain }
                let opensSoleFocusedSelection = !checkboxHit
                    && event.isUnmodifiedPrimaryDoubleClick
                    && selection.selectedIDs == [row.storedID]
                    && selection.focusedID == row.storedID
                keyboardFocus = 1
                commitSelectionMutation(ui: ui, game: game) {
                    $0.select(id: row.storedID, gesture: gesture)
                }
                if opensSoleFocusedSelection {
                    openWorld(row.record, ui: ui, game: game)
                }
                return true
            }
        }
        return false
    }

    override func onKeyEvent(_ ui: UIManager, _ game: GameCore, _ event: ElysiumKeyEvent) -> Bool {
        let key = event.terminal.rawValue
        if key == "Delete" || key == "Backspace" {
            return true
        }
        if handleModalKey(ui, game, event: event) { return true }
        guard isReady else { return true }
        if key == "Tab" {
            let delta = event.modifiers.contains(.shift) ? -1 : 1
            keyboardFocus = (keyboardFocus + delta + 6) % 6
            return true
        }
        if key == "KeyA", event.modifiers == [.command], keyboardFocus == 1 {
            commitSelectionMutation(ui: ui, game: game) { $0.selectAll() }
            return true
        }
        if (key == "ArrowUp" || key == "ArrowDown"), keyboardFocus == 1 {
            commitSelectionMutation(
                ui: ui, game: game,
                prepareAccessibility: { ensureFocusedRowVisible(ui) }
            ) {
                $0.moveFocus(delta: key == "ArrowUp" ? -1 : 1,
                             extendRange: event.modifiers.contains(.shift),
                             focusOnly: event.modifiers.contains(.command))
            }
            return true
        }
        if key == "Space", keyboardFocus == 1 {
            commitSelectionMutation(ui: ui, game: game) { $0.toggleFocused() }
            return true
        }
        if key == "Enter" || key == "Space" {
            switch keyboardFocus {
            case 0:
                if snapshot?.rows.isEmpty == false {
                    let allSelected = selection.selectedIDs.count == snapshot?.rows.count
                    commitSelectionMutation(ui: ui, game: game) {
                        if allSelected { $0.clearAll() } else { $0.selectAll() }
                    }
                }
            case 1, 2: openFocusedWorld(ui: ui, game: game)
            case 3: beginDeletePrecheck(ui: ui, game: game)
            case 4: ui.open(WorldCreateScreen(lanHostRequest: lanHostRequest), game)
            case 5: ui.closeTop(game)
            default: break
            }
            return true
        }
        return super.onKeyEvent(ui, game, event)
    }

    override func onClose(_ ui: UIManager, _ game: GameCore) {
        _ = advanceOperationGeneration()
        if !destructiveAdmissionAccepted { releaseMaintenanceLease() }
    }

    private func setControlsEnabled(_ enabled: Bool) {
        for button in buttons { button.enabled = enabled }
    }

    private func beginDeletePrecheck(ui: UIManager, game: GameCore) {
        guard isReady, !selection.selectedIDs.isEmpty, maintenanceToken == nil,
              let current = snapshot,
              let token = elysiumMainActorSync({
                  game.acquireSavedWorldMaintenance()
              }) else { return }
        let original: SavedWorldDeleteRequest
        do { original = try current.deleteRequest(selectedIDs: selection.selectedIDs) }
        catch {
            elysiumMainActorSync { game.releaseSavedWorldMaintenance(token) }
            return
        }
        maintenanceToken = token
        publishPhase(.prechecking, ui: ui, game: game)
        setControlsEnabled(false)
        guard let generation = advanceOperationGeneration() else {
            elysiumMainActorSync { game.releaseSavedWorldMaintenance(token) }
            maintenanceToken = nil
            phase = .loadFailure; return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            let result = Result { try game.checkedWorldSnapshot() }
            DispatchQueue.main.async { [weak self, weak ui, weak game] in
                guard let game else { return }
                guard let self, let ui, ui.current() === self,
                      self.operationGeneration == generation,
                      elysiumMainActorSync({
                          game.revalidateSavedWorldMaintenance(token)
                      }) else {
                    elysiumMainActorSync { game.releaseSavedWorldMaintenance(token) }
                    return
                }
                guard case .success(let fresh) = result else {
                    self.publishPhase(.deleteFailure(original, self.selectedNames()),
                                      ui: ui, game: game)
                    return
                }
                let freshRequest = try? fresh.deleteRequest(
                    selectedIDs: self.selection.selectedIDs)
                let freshIdentity = freshRequest.map(savedWorldDeleteRequestIdentity)
                let originalIdentity = savedWorldDeleteRequestIdentity(original)
                guard savedWorldConstantTimeEqual32(
                        fresh.collectionDigest, original.expectedCollectionDigest),
                      let freshRequest, let freshIdentity,
                      savedWorldConstantTimeEqual32(freshIdentity, originalIdentity),
                      freshRequest.expectations == original.expectations else {
                    self.snapshot = fresh
                    self.selection.refresh(orderedIDs: fresh.orderedIDs)
                    self.publishPhase(.stale, ui: ui, game: game)
                    self.statusAnnouncement = "World list changed. Review your selection and try again."
                    self.releaseMaintenanceLease()
                    self.setControlsEnabled(true)
                    return
                }
                self.snapshot = fresh
                self.modalFocus = 0
                self.publishPhase(.confirming(original, self.selectedNames()),
                                  ui: ui, game: game)
            }
        }
    }

    private func executeDelete(_ request: SavedWorldDeleteRequest, names: [String],
                               ui: UIManager, game: GameCore) {
        guard let token = maintenanceToken,
              elysiumMainActorSync({ game.revalidateSavedWorldMaintenance(token) }),
              let operation = elysiumMainActorSync({
                  game.admitSavedWorldDelete(
                    token, request: request,
                    screenIdentity: textScreenIdentity,
                    launchContextIdentity: launchContextIdentity)
              }) else { return }
        guard elysiumMainActorSync({
            ui.retainSavedWorldMaintenanceOperation(
                operation, game: game, token: token)
        }) else {
            elysiumMainActorSync { game.releaseSavedWorldMaintenance(token) }
            maintenanceToken = nil
            return
        }
        activeDeleteOperation = operation
        destructiveAdmissionAccepted = true
        publishPhase(.deleting(request, names), ui: ui, game: game)
        guard let generation = advanceOperationGeneration() else {
            releaseMaintenanceLease()
            phase = .loadFailure; return
        }
        let expected = outcomeBinding(
            phase: .deleting, request: request,
            generation: generation, token: token)
        DispatchQueue.global(qos: .userInitiated).async {
            [operation, game, weak self, weak ui] in
            let outcome = operation.execute()
            DispatchQueue.main.async { [operation, game, weak self, weak ui] in
                guard let self, let ui,
                      self.claimOutcomeIfCurrent(
                        outcome, expected: expected, expectedPhase: .deleting,
                        request: request, names: names, token: token,
                        operation: operation, ui: ui, game: game) else { return }
                switch outcome {
                case .direct, .recovered:
                    let count = request.expectations.count
                    self.reload(ui: ui, game: game,
                                success: count == 1 ? "Deleted 1 world." : "Deleted \(count) worlds.")
                case .provenPrecommitFailure:
                    self.modalFocus = 0
                    self.publishPhase(.deleteFailure(request, names), ui: ui, game: game)
                case .stale:
                    self.publishPhase(.stale, ui: ui, game: game)
                    self.statusAnnouncement = "World list changed. Review your selection and try again."
                    self.releaseMaintenanceLease()
                    self.setControlsEnabled(true)
                case .terminalRecovery(let authority):
                    self.publishPhase(.terminal(request, names, authority, false),
                                      ui: ui, game: game)
                case .terminalIntegrity:
                    // This result is emitted only before the checked storage
                    // transaction starts; no recovery authority exists and a
                    // terminal Reload action could never classify it.
                    self.modalFocus = 0
                    self.publishPhase(.deleteFailure(request, names), ui: ui, game: game)
                    self.releaseMaintenanceLease()
                    self.setControlsEnabled(true)
                }
            }
        }
    }

    private func selectedNames() -> [String] {
        (snapshot?.rows ?? []).filter { selection.selectedIDs.contains($0.storedID) }
            .map { savedWorldDisplayName($0.record.name) }
    }

    private func openFocusedWorld(ui: UIManager, game: GameCore) {
        guard isReady, selection.selectedIDs.count == 1,
              let id = selection.focusedID, selection.selectedIDs.contains(id),
              let row = snapshot?.rows.first(where: { $0.storedID == id }) else { return }
        openWorld(row.record, ui: ui, game: game)
    }

    private func ensureFocusedRowVisible(_ ui: UIManager) {
        guard let id = selection.focusedID,
              let index = snapshot?.rows.firstIndex(where: { $0.storedID == id }) else { return }
        let layout = SavedWorldSelectionLayout(width: ui.width, height: ui.height)
        let rowTop = Double(index) * 30, rowBottom = rowTop + 30
        if rowTop < scroll { scroll = rowTop }
        else if rowBottom > scroll + layout.list.height { scroll = rowBottom - layout.list.height }
    }

    private func releaseMaintenanceLease() {
        guard let token = maintenanceToken, let game = maintenanceGame else { return }
        if let operation = activeDeleteOperation {
            elysiumMainActorSync {
                maintenanceUI?.releaseSavedWorldMaintenanceOperation(operation)
            }
            activeDeleteOperation = nil
        }
        elysiumMainActorSync { game.releaseSavedWorldMaintenance(token) }
        maintenanceToken = nil
        destructiveAdmissionAccepted = false
    }

    private func modalFrames(_ ui: UIManager) -> (left: Button, right: Button, single: Button) {
        let layout = SavedWorldDeleteModalLayout(width: ui.width, height: ui.height)
        return (
            Button(layout.leftButton.x, layout.leftButton.y,
                   layout.leftButton.width, layout.leftButton.height, "", {}),
            Button(layout.rightButton.x, layout.rightButton.y,
                   layout.rightButton.width, layout.rightButton.height, "", {}),
            Button(layout.singleButton.x, layout.singleButton.y,
                   layout.singleButton.width, layout.singleButton.height, "", {}))
    }

    private func drawLoadFailureActions(_ ui: UIManager, _ game: GameCore) {
        let cx = (ui.width / 2).rounded(.down)
        let retry = Button(cx - 102, 88, 100, 20, "Try Again", {})
        let back = Button(cx + 2, 88, 100, 20, "Back", {})
        ui.drawButton(retry, retry.contains(ui.mouseX, ui.mouseY))
        ui.drawButton(back, back.contains(ui.mouseX, ui.mouseY))
    }

    private func drawStatusAndModal(_ ui: UIManager, _ game: GameCore,
                                    layout: SavedWorldSelectionLayout) {
        let status: String?
        switch phase {
        case .prechecking: status = "Checking selected worlds…"
        case .deleting(let request, _):
            status = request.expectations.count == 1 ? "Deleting 1 world…" :
                "Deleting \(request.expectations.count) worlds…"
        case .success(let message): status = message
        case .stale: status = "World list changed. Review your selection and try again."
        case .terminalReloading: status = "Reloading saved worlds…"
        default: status = nil
        }
        if let status { ui.cv.drawTextCentered(status, ui.width / 2, layout.statusY, 1, "#ffff55") }

        let title: String
        let body: String
        let names: [String]
        var leftLabel: String?
        var rightLabel: String?
        var singleLabel: String?
        switch phase {
        case .confirming(let request, let selectedNames):
            let count = request.expectations.count
            title = count == 1 ? "Delete 1 World?" : "Delete \(count) Worlds?"
            body = count == 1
                ? "This permanently deletes this world and its saved data from this Mac. This cannot be undone."
                : "This permanently deletes the selected worlds and their saved data from this Mac. This cannot be undone."
            names = selectedNames
            leftLabel = "Cancel"
            rightLabel = count == 1 ? "Delete World" : "Delete \(count) Worlds"
        case .deleting(let request, let selectedNames):
            let count = request.expectations.count
            title = count == 1 ? "Delete 1 World?" : "Delete \(count) Worlds?"
            body = count == 1 ? "Deleting 1 world…" : "Deleting \(count) worlds…"
            names = selectedNames
        case .deleteFailure(_, let selectedNames):
            title = "Delete Saved Worlds"
            body = "Worlds weren’t deleted. Try Again or Cancel."
            names = selectedNames
            leftLabel = "Cancel"
            rightLabel = "Try Again"
        case .terminal(_, _, _, let unresolved):
            title = "Saved Worlds Need Reloading"
            body = unresolved
                ? "Elysium still couldn’t verify whether the selected worlds were deleted. Reload saved worlds before continuing."
                : "Elysium couldn’t verify whether the selected worlds were deleted. Reload saved worlds before continuing."
            names = []
            singleLabel = "Reload Saved Worlds"
        case .terminalReloading:
            title = "Saved Worlds Need Reloading"
            body = "Reloading saved worlds…"
            names = []
        default:
            return
        }
        let modal = SavedWorldDeleteModalLayout(width: ui.width, height: ui.height)
        let cx = modal.panel.x + floor(modal.panel.width / 2)
        ui.cv.setFill("rgba(0,0,0,0.78)")
        ui.cv.fillRect(modal.panel.x, modal.panel.y, modal.panel.width, modal.panel.height)
        ui.cv.setFill("#a0a0a0")
        ui.cv.fillRect(modal.panel.x, modal.panel.y, modal.panel.width, 1)
        ui.cv.drawTextCentered(title, cx, modal.title.y, 1, "#ffffff")
        var bodyLines: [String] = []
        var current = ""
        for word in body.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : current + " " + word
            if Double(textWidth(candidate)) * 0.65 <= modal.warning.width || current.isEmpty {
                current = candidate
            } else {
                bodyLines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty { bodyLines.append(current) }
        for (index, line) in bodyLines.prefix(names.isEmpty ? 5 : 2).enumerated() {
            ui.cv.drawTextCentered(line, cx, modal.warning.y + Double(index * 8),
                                   0.65, "#e0e0e0")
        }
        if !names.isEmpty {
            let start = min(modalNameScroll, max(0, names.count - 5))
            for (offset, name) in names.dropFirst(start).prefix(5).enumerated() {
                ui.cv.drawText(savedWorldCanvasName(
                    name, maximumAdvance: Int(modal.names.width)),
                    modal.names.x, modal.names.y + Double(offset * 12), 1, "#c8c8c8")
            }
            if names.count > 5 {
                ui.cv.drawText("\(start + 1)–\(min(names.count, start + 5)) of \(names.count)",
                               modal.status.x, modal.status.y, 1, "#a0a0a0")
            }
        }
        let frames = modalFrames(ui)
        if let leftLabel, let rightLabel {
            frames.left.label = leftLabel; frames.right.label = rightLabel
            ui.drawButton(frames.left, frames.left.contains(ui.mouseX, ui.mouseY) || modalFocus == 0)
            ui.drawButton(frames.right, frames.right.contains(ui.mouseX, ui.mouseY) || modalFocus == 1)
        } else if let singleLabel {
            frames.single.label = singleLabel
            ui.drawButton(frames.single, frames.single.contains(ui.mouseX, ui.mouseY))
        }
    }

    private func handleModalPointer(_ ui: UIManager, _ game: GameCore, mx: Double, my: Double,
                                    event: ScreenPointerEvent) -> Bool {
        guard event.button == 0 else {
            switch phase {
            case .confirming, .deleting, .deleteFailure, .terminal, .terminalReloading,
                 .loadFailure, .prechecking: return true
            default: return false
            }
        }
        if case .loadFailure = phase {
            let cx = (ui.width / 2).rounded(.down)
            if Button(cx - 102, 88, 100, 20, "", {}).contains(mx, my) {
                reload(ui: ui, game: game); return true
            }
            if Button(cx + 2, 88, 100, 20, "", {}).contains(mx, my) {
                ui.closeTop(game); return true
            }
            return true
        }
        let frames = modalFrames(ui)
        switch phase {
        case .confirming(let request, let names):
            if frames.left.contains(mx, my) {
                keyboardFocus = 3
                releaseMaintenanceLease(); publishPhase(.ready, ui: ui, game: game)
                setControlsEnabled(true)
            }
            else if frames.right.contains(mx, my) { executeDelete(request, names: names, ui: ui, game: game) }
            return true
        case .deleteFailure(_, _):
            if frames.left.contains(mx, my) {
                keyboardFocus = 3
                releaseMaintenanceLease(); publishPhase(.ready, ui: ui, game: game)
                setControlsEnabled(true)
            }
            else if frames.right.contains(mx, my) { retryDeletePrecheck(ui: ui, game: game) }
            return true
        case .terminal(let request, let names, let pre, _):
            if frames.single.contains(mx, my) {
                elysiumMainActorSync {
                    terminalReload(request, names: names, pre: pre, ui: ui, game: game)
                }
            }
            return true
        case .deleting, .terminalReloading, .prechecking:
            return true
        default:
            return false
        }
    }

    private func handleModalKey(_ ui: UIManager, _ game: GameCore,
                                event: ElysiumKeyEvent) -> Bool {
        let key = event.terminal.rawValue
        switch phase {
        case .loadFailure:
            if key == "Enter" || key == "Space" { reload(ui: ui, game: game) }
            else if key == "Escape" { ui.closeTop(game) }
            return true
        case .confirming(let request, let names):
            if key == "Tab" || key == "ArrowLeft" || key == "ArrowRight" {
                modalFocus = modalFocus == 0 ? 1 : 0
            } else if key == "Escape" || ((key == "Enter" || key == "Space") && modalFocus == 0) {
                keyboardFocus = 3
                releaseMaintenanceLease(); publishPhase(.ready, ui: ui, game: game)
                setControlsEnabled(true)
            } else if (key == "Enter" || key == "Space") && modalFocus == 1 {
                executeDelete(request, names: names, ui: ui, game: game)
            }
            return true
        case .deleteFailure:
            if key == "Tab" || key == "ArrowLeft" || key == "ArrowRight" {
                modalFocus = modalFocus == 0 ? 1 : 0
            } else if key == "Escape" || ((key == "Enter" || key == "Space") && modalFocus == 0) {
                keyboardFocus = 3
                releaseMaintenanceLease(); publishPhase(.ready, ui: ui, game: game)
                setControlsEnabled(true)
            } else if (key == "Enter" || key == "Space") && modalFocus == 1 {
                retryDeletePrecheck(ui: ui, game: game)
            }
            return true
        case .terminal(let request, let names, let pre, _):
            if key == "Enter" || key == "Space" {
                elysiumMainActorSync {
                    terminalReload(request, names: names, pre: pre, ui: ui, game: game)
                }
            }
            return true
        case .deleting, .terminalReloading, .prechecking:
            return true
        default:
            return false
        }
    }

    private func retryDeletePrecheck(ui: UIManager, game: GameCore) {
        releaseMaintenanceLease()
        publishPhase(.ready, ui: ui, game: game)
        setControlsEnabled(true)
        beginDeletePrecheck(ui: ui, game: game)
    }

    private func terminalReload(_ request: SavedWorldDeleteRequest, names: [String],
                                pre: SavedWorldDeleteRecoveryAuthority?,
                                ui: UIManager, game: GameCore) {
        guard let token = maintenanceToken,
              let operation = activeDeleteOperation,
              elysiumMainActorSync({ game.revalidateSavedWorldMaintenance(token) }) else {
            return
        }
        var recoveryAuthority = pre
        if let deferredOutcome {
            let deferredExpected = outcomeBinding(
                phase: .terminal, request: request,
                generation: operationGeneration, token: token)
            guard elysiumMainActorSync({
                claimOutcomeIfCurrent(
                    deferredOutcome, expected: deferredExpected,
                    expectedPhase: .terminal, request: request, names: names,
                    token: token, operation: operation, ui: ui, game: game)
            }) else { return }
            self.deferredOutcome = nil
            switch deferredOutcome {
            case .direct, .recovered:
                let count = request.expectations.count
                reload(ui: ui, game: game,
                       success: count == 1 ? "Deleted 1 world." : "Deleted \(count) worlds.")
                return
            case .provenPrecommitFailure:
                modalFocus = 0
                publishPhase(.deleteFailure(request, names), ui: ui, game: game)
                return
            case .stale:
                publishPhase(.stale, ui: ui, game: game)
                statusAnnouncement = "World list changed. Review your selection and try again."
                releaseMaintenanceLease()
                setControlsEnabled(true)
                return
            case .terminalRecovery(let authority):
                recoveryAuthority = authority
            case .terminalIntegrity:
                modalFocus = 0
                publishPhase(.deleteFailure(request, names), ui: ui, game: game)
                releaseMaintenanceLease()
                setControlsEnabled(true)
                return
            }
        }
        let fallbackRecoveryAuthority = recoveryAuthority
        publishPhase(
            .terminalReloading(request, names, fallbackRecoveryAuthority),
            ui: ui, game: game)
        guard let generation = advanceOperationGeneration() else {
            phase = .terminal(request, names, recoveryAuthority, true); return
        }
        let expected = outcomeBinding(
            phase: .terminalReloading, request: request,
            generation: generation, token: token)
        DispatchQueue.global(qos: .userInitiated).async {
            [operation, game, weak self, weak ui] in
            let outcome = operation.recover()
            DispatchQueue.main.async { [operation, game, weak self, weak ui] in
                guard let self, let ui,
                      self.claimOutcomeIfCurrent(
                        outcome, expected: expected,
                        expectedPhase: .terminalReloading,
                        request: request, names: names, token: token,
                        operation: operation, ui: ui, game: game) else { return }
                switch outcome {
                case .direct, .recovered:
                    let count = request.expectations.count
                    self.reload(ui: ui, game: game,
                                success: count == 1 ? "Deleted 1 world." :
                                    "Deleted \(count) worlds.")
                case .provenPrecommitFailure:
                    self.modalFocus = 0
                    self.publishPhase(.deleteFailure(request, names), ui: ui, game: game)
                case .terminalRecovery(let nextAuthority):
                    self.publishPhase(.terminal(request, names, nextAuthority, true),
                                      ui: ui, game: game)
                case .terminalIntegrity, .stale:
                    self.publishPhase(
                        .terminal(request, names, fallbackRecoveryAuthority, true),
                        ui: ui, game: game)
                }
            }
        }
    }

    override func textAccessibilityDescriptors(_ ui: UIManager, _ game: GameCore)
        -> [TextEntryAccessibilityDescriptor] {
        let layout = SavedWorldSelectionLayout(width: lastWidth, height: lastHeight)
        func descriptor(_ id: String, _ role: TextEntryAccessibilityRole, _ label: String,
                        _ value: String = "", _ frame: SavedWorldSelectionLayout.Rect,
                        enabled: Bool = true, focused: Bool = false,
                        selected: Bool? = nil, actionable: Bool = false,
                        help: String = "") -> TextEntryAccessibilityDescriptor {
            TextEntryAccessibilityDescriptor(
                id: id, role: role, label: label, value: value, help: help,
                frame: (frame.x, frame.y, frame.width, frame.height), enabled: enabled,
                focused: focused, insertionUTF16Offset: nil, focusable: actionable,
                selected: selected, actionable: actionable)
        }
        let modal = SavedWorldDeleteModalLayout(width: lastWidth, height: lastHeight)
        let panel = modal.panel
        let frames = modalFrames(ui)
        let left = SavedWorldSelectionLayout.Rect(
            x: frames.left.x, y: frames.left.y, width: frames.left.w, height: frames.left.h)
        let right = SavedWorldSelectionLayout.Rect(
            x: frames.right.x, y: frames.right.y, width: frames.right.w, height: frames.right.h)
        let single = SavedWorldSelectionLayout.Rect(
            x: frames.single.x, y: frames.single.y, width: frames.single.w, height: frames.single.h)
        switch phase {
        case .loading:
            return [descriptor("worlds.status.loading", .staticText, "Loading saved worlds…", "", panel)]
        case .loadFailure:
            return [
                descriptor("worlds.status.loadFailure", .staticText,
                           "Worlds couldn’t be loaded.", "", panel),
                descriptor(destructiveAccessibilityID("loadRetry"), .button, "Try Again", "", left,
                           actionable: true),
                descriptor("worlds.load.back", .button, "Back", "", right,
                           actionable: true),
            ]
        case .confirming(let request, let names), .deleteFailure(let request, let names):
            let isFailure: Bool
            if case .deleteFailure = phase { isFailure = true } else { isFailure = false }
            var result = [descriptor(
                "worlds.modal.summary", .staticText,
                isFailure ? "Worlds weren’t deleted. Try Again or Cancel." :
                    (request.expectations.count == 1
                        ? "Delete 1 World? This permanently deletes this world and its saved data from this Mac. This cannot be undone."
                        : "Delete \(request.expectations.count) Worlds? This permanently deletes the selected worlds and their saved data from this Mac. This cannot be undone."),
                "", panel)]
            let start = min(modalNameScroll, max(0, names.count - 5))
            for (offset, name) in names.dropFirst(start).prefix(5).enumerated() {
                result.append(descriptor(
                    "worlds.modal.name.\(start + offset)", .listItem,
                    savedWorldDisplayName(name), savedWorldDisplayName(name),
                    SavedWorldSelectionLayout.Rect(
                        x: modal.names.x,
                        y: modal.names.y + Double(offset * 12),
                        width: modal.names.width, height: 10)))
            }
            result.append(descriptor(
                destructiveAccessibilityID("cancel", request: request), .button, "Cancel", "", left,
                focused: modalFocus == 0, actionable: true))
            result.append(descriptor(
                destructiveAccessibilityID(isFailure ? "retry" : "delete", request: request), .button,
                isFailure ? "Try Again" :
                    (request.expectations.count == 1 ? "Delete World" :
                     "Delete \(request.expectations.count) Worlds"), "", right,
                focused: modalFocus == 1, actionable: true))
            return result
        case .deleting(let request, _):
            let copy = request.expectations.count == 1 ? "Deleting 1 world…" :
                "Deleting \(request.expectations.count) worlds…"
            return [descriptor("worlds.status.deleting", .staticText, copy, "", panel)]
        case .prechecking:
            return [descriptor("worlds.status.precheck", .staticText,
                               "Checking selected worlds…", "", panel)]
        case .terminal(let request, _, _, let unresolved):
            let copy = unresolved
                ? "Elysium still couldn’t verify whether the selected worlds were deleted. Reload saved worlds before continuing."
                : "Elysium couldn’t verify whether the selected worlds were deleted. Reload saved worlds before continuing."
            return [
                descriptor("worlds.terminal.body", .staticText,
                           "Saved Worlds Need Reloading. \(copy)", "", panel),
                descriptor(destructiveAccessibilityID("terminalReload", request: request),
                           .button, "Reload Saved Worlds", "",
                           single, focused: true, actionable: true),
            ]
        case .terminalReloading:
            return [descriptor("worlds.status.terminalReload", .staticText,
                               "Reloading saved worlds…", "", panel)]
        case .ready, .stale, .success:
            break
        }

        let accessibility = SavedWorldSelectionAccessibilitySnapshot(selection: selection)
        var result: [TextEntryAccessibilityDescriptor] = [descriptor(
            accessibility.bulkActionID, .button,
            accessibility.bulkActionLabel, "",
            SavedWorldSelectionLayout.Rect(
                x: layout.toolbar.x + 208, y: layout.toolbar.y,
                width: 100, height: 20),
            enabled: accessibility.bulkActionEnabled, actionable: true)]
        let rows = snapshot?.rows ?? []
        for (index, row) in rows.enumerated() {
            let y = layout.list.y + Double(index) * 30 - scroll
            guard y + 28 > layout.list.y, y < layout.list.y + layout.list.height else { continue }
            let checked = accessibility.rowSelected(row.storedID)
            result.append(descriptor(
                worldAccessibilityID(row.storedID), .checkbox,
                savedWorldDisplayName(row.record.name),
                accessibility.rowValue(row.storedID),
                SavedWorldSelectionLayout.Rect(
                    x: layout.list.x, y: y, width: layout.list.width, height: 28),
                focused: selection.focusedID == row.storedID, selected: checked,
                actionable: true,
                help: "Toggle selection for this saved world."))
        }
        result.append(descriptor(
            "worlds.play", .button, playBtn.label, "", layout.primaryButtons[0],
            enabled: accessibility.playEnabled, actionable: true))
        result.append(descriptor(
            destructiveAccessibilityID("beginDelete"), .button, "Delete", "",
            layout.primaryButtons[1],
            enabled: accessibility.deleteEnabled, actionable: true))
        result.append(descriptor(
            "worlds.create", .button, "Create New", "", layout.primaryButtons[2],
            actionable: true))
        result.append(descriptor(
            "worlds.back", .button, "Back", "", layout.backButton, actionable: true))
        if let statusAnnouncement {
            result.append(descriptor(
                "worlds.status", .staticText, statusAnnouncement, "",
                SavedWorldSelectionLayout.Rect(
                    x: layout.list.x, y: layout.statusY,
                    width: layout.list.width, height: 10)))
        }
        return result
    }

    override func consumeTextAccessibilityStatusAnnouncement() -> String? {
        defer { statusAnnouncement = nil }
        return statusAnnouncement
    }

    override func focusTextAccessibilityElement(_ id: String, _ ui: UIManager,
                                                 _ game: GameCore) -> Bool {
        switch phase {
        case .confirming(let request, _), .deleteFailure(let request, _):
            if id == destructiveAccessibilityID("cancel", request: request) {
                modalFocus = 0; return true
            }
            let kind: String
            if case .deleteFailure = phase { kind = "retry" } else { kind = "delete" }
            if id == destructiveAccessibilityID(kind, request: request) {
                modalFocus = 1; return true
            }
        case .terminal(let request, _, _, _):
            if id == destructiveAccessibilityID("terminalReload", request: request) { return true }
        default: break
        }
        guard isReady,
              let row = snapshot?.rows.first(where: { worldAccessibilityID($0.storedID) == id }) else {
            return false
        }
        commitSelectionMutation(
            ui: ui, game: game,
            prepareAccessibility: { ensureFocusedRowVisible(ui) }
        ) { _ = $0.focus(id: row.storedID) }
        return true
    }

    override func performTextAccessibilityAction(_ id: String, _ ui: UIManager,
                                                  _ game: GameCore) -> Bool {
        if case .loadFailure = phase,
           id == destructiveAccessibilityID("loadRetry") {
            reload(ui: ui, game: game); return true
        }
        if isReady, id == destructiveAccessibilityID("beginDelete") {
            beginDeletePrecheck(ui: ui, game: game); return true
        }
        if case .confirming(let request, let names) = phase {
            if id == destructiveAccessibilityID("cancel", request: request) {
                keyboardFocus = 3
                releaseMaintenanceLease(); publishPhase(.ready, ui: ui, game: game)
                setControlsEnabled(true); return true
            }
            if id == destructiveAccessibilityID("delete", request: request) {
                executeDelete(request, names: names, ui: ui, game: game); return true
            }
        }
        if case .deleteFailure(let request, _) = phase {
            if id == destructiveAccessibilityID("cancel", request: request) {
                keyboardFocus = 3
                releaseMaintenanceLease(); publishPhase(.ready, ui: ui, game: game)
                setControlsEnabled(true); return true
            }
            if id == destructiveAccessibilityID("retry", request: request) {
                retryDeletePrecheck(ui: ui, game: game); return true
            }
        }
        if case .terminal(let request, let names, let pre, _) = phase,
           id == destructiveAccessibilityID("terminalReload", request: request) {
            elysiumMainActorSync {
                terminalReload(request, names: names, pre: pre, ui: ui, game: game)
            }
            return true
        }
        switch id {
        case "worlds.load.back", "worlds.back": ui.closeTop(game); return true
        case "worlds.selectAll", "worlds.clearAll":
            let accessibility = SavedWorldSelectionAccessibilitySnapshot(selection: selection)
            guard isReady, id == accessibility.bulkActionID else { return false }
            commitSelectionMutation(ui: ui, game: game) {
                if id == "worlds.selectAll" { $0.selectAll() } else { $0.clearAll() }
            }
            return true
        case "worlds.play": openFocusedWorld(ui: ui, game: game); return true
        case "worlds.create": ui.open(WorldCreateScreen(lanHostRequest: lanHostRequest), game); return true
        default:
            guard isReady,
                  let row = snapshot?.rows.first(where: {
                      worldAccessibilityID($0.storedID) == id
                  }) else { return false }
            commitSelectionMutation(ui: ui, game: game) {
                $0.select(id: row.storedID, gesture: .toggle)
            }
            return true
        }
    }

    private func worldAccessibilityID(_ storedID: String) -> String {
        let digest = SHA256.hash(data: Data(storedID.utf8))
        return "worlds.row." + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func openWorld(_ record: WorldRecord, ui: UIManager, game: GameCore) {
        elysiumMainActorSync { game.loadWorld(record.id) }
        startPendingLANHost(game)
        ui.open(LoadingScreen(), game)
    }

    private func startPendingLANHost(_ game: GameCore) {
        guard let lanHostRequest else { return }
        do {
            try elysiumMainActorSync {
                try LANMultiplayerManager.shared.startHost(
                    game: game,
                    requestedJoinCode: lanHostRequest.joinCode,
                    requestedPort: lanHostRequest.port
                )
            }
            for line in LANMultiplayerManager.shared.statusSummary() {
                pushChat("§7" + line)
            }
        } catch let error as LANTransportError {
            pushChat("§c" + error.description)
        } catch {
            pushChat("§cLAN host failed: \(error)")
        }
    }
}

// =============================================================================
final class WorldCreateScreen: Screen {
    private struct Layout {
        let uiHeight: Double
        let compact: Bool
        let buttonGap: Double
        let nameY: Double
        let seedY: Double
        let modeY: Double
        let difficultyY: Double
        let worldTypeY: Double
        let biomeY: Double

        init(uiHeight: Double) {
            self.uiHeight = uiHeight
            compact = uiHeight < 260
            buttonGap = compact ? 22.0 : 24.0
            nameY = compact ? 34 : 40
            seedY = compact ? 64 : 76
            modeY = compact ? 90 : 102
            difficultyY = modeY + buttonGap
            worldTypeY = difficultyY + buttonGap
            biomeY = worldTypeY + buttonGap
        }

        func dungeonY(showsBiome: Bool) -> Double {
            showsBiome ? biomeY + buttonGap : biomeY
        }

        func actionY(showsBiome: Bool) -> Double {
            let dungeonY = dungeonY(showsBiome: showsBiome)
            let preferredActionY = dungeonY + (compact ? 28 : 32)
            return max(dungeonY + 24, min(preferredActionY, uiHeight - 34))
        }

        func statusY(showsBiome: Bool) -> Double {
            min(actionY(showsBiome: showsBiome) + 30, uiHeight - 10)
        }
    }

    private let lanHostRequest: LANHostLaunchRequest?
    let nameField = TextField(0, 0, 200, 16, "New World",
                              id: "create.worldName", accessibilityLabel: "World Name")
    let seedField = TextField(0, 0, 200, 16, "Leave blank for random",
                              id: "create.seed", accessibilityLabel: "Seed")
    var mode = GameMode.survival
    var difficulty = 2
    var worldPreset = WorldPreset.normal
    var singleBiome = Biome.plains
    var dungeonDensity = DungeonDensity.normal
    var creating = false
    private var worldTypeBtn: Button!
    private var biomeBtn: Button!
    private var dungeonBtn: Button!
    private weak var createBtn: Button?
    private weak var cancelBtn: Button?
    private var lastUIHeight = 240.0

    init(lanHostRequest: LANHostLaunchRequest? = nil) {
        self.lanHostRequest = lanHostRequest
        super.init()
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        let cx = (ui.width / 2).rounded(.down)
        lastUIHeight = ui.height
        let layout = Layout(uiHeight: ui.height)
        nameField.x = cx - 100
        nameField.y = layout.nameY
        seedField.x = cx - 100
        seedField.y = layout.seedY
        fields.append(nameField)
        fields.append(seedField)
        let modeBtn = Button(cx - 100, layout.modeY, 200, 20, "Game Mode: Survival", {})
        modeBtn.onClick = { [weak self, weak modeBtn] in
            guard let self, let modeBtn else { return }
            self.mode = self.mode == GameMode.survival ? GameMode.creative : GameMode.survival
            modeBtn.label = "Game Mode: \(self.mode == GameMode.creative ? "Creative" : "Survival")"
        }
        let diffBtn = Button(cx - 100, layout.difficultyY, 200, 20, "Difficulty: Normal", {})
        diffBtn.onClick = { [weak self, weak diffBtn] in
            guard let self, let diffBtn else { return }
            self.difficulty = (self.difficulty + 1) % 4
            diffBtn.label = "Difficulty: \(DIFFICULTY_NAMES[self.difficulty])"
        }
        buttons.append(modeBtn)
        buttons.append(diffBtn)
        worldTypeBtn = Button(cx - 100, layout.worldTypeY, 200, 20, "", {})
        worldTypeBtn.onClick = { [weak self, weak ui] in
            guard let self, let ui else { return }
            let cycle = ui.optionDown ? WorldPreset.extendedCycle : WorldPreset.normalCycle
            let current = cycle.firstIndex(of: self.worldPreset) ?? -1
            self.worldPreset = cycle[(current + 1) % cycle.count]
            self.updateWorldTypeLabels()
        }
        biomeBtn = Button(cx - 100, layout.biomeY, 200, 20, "", {})
        biomeBtn.onClick = { [weak self] in
            guard let self else { return }
            let cases = Biome.allCases
            let current = cases.firstIndex(of: self.singleBiome) ?? 0
            self.singleBiome = cases[(current + 1) % cases.count]
            self.updateWorldTypeLabels()
        }
        buttons.append(worldTypeBtn)
        buttons.append(biomeBtn)
        dungeonBtn = Button(cx - 100, layout.dungeonY(showsBiome: false), 200, 20, "", {})
        dungeonBtn.onClick = { [weak self] in
            guard let self else { return }
            let cases = DungeonDensity.allCases
            let current = cases.firstIndex(of: self.dungeonDensity) ?? 1
            self.dungeonDensity = cases[(current + 1) % cases.count]
            self.updateWorldTypeLabels()
        }
        buttons.append(dungeonBtn)
        let create = Button(cx - 100, layout.actionY(showsBiome: false), 98, 20, lanHostRequest == nil ? "Create World" : "Create & Host", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game, !self.creating else { return }
            self.creating = true
            elysiumMainActorSync {
                game.createWorld(
                    name: self.nameField.text.isEmpty ? "New World" : self.nameField.text,
                    seedText: self.seedField.text, mode: self.mode,
                    difficulty: self.difficulty, worldPreset: self.worldPreset,
                    singleBiome: self.singleBiome,
                    dungeonDensity: self.dungeonDensity)
            }
            self.startPendingLANHost(game)
            ui.open(LoadingScreen(), game)
        })
        let cancel = Button(cx + 2, layout.actionY(showsBiome: false), 98, 20, "Cancel", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        })
        createBtn = create
        cancelBtn = cancel
        buttons.append(create)
        buttons.append(cancel)
        updateWorldTypeLabels()
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        lastUIHeight = ui.height
        let layout = Layout(uiHeight: ui.height)
        let showsBiome = worldPreset == .singleBiomeSurface
        ui.drawDirtBg()
        ui.cv.drawTextCentered(lanHostRequest == nil ? "Create New World" : "Create World to Host", ui.width / 2, 10, 1)
        ui.cv.drawText("World Name", nameField.x, nameField.y - 10, 1, "#a0a0a0")
        ui.cv.drawText("Seed", seedField.x, seedField.y - 10, 1, "#a0a0a0")
        if creating {
            ui.cv.drawTextCentered("Generating world...", ui.width / 2, layout.statusY(showsBiome: showsBiome), 1, "#ffff55")
        }
        ui.drawButtons(self)
    }

    private func updateWorldTypeLabels() {
        worldTypeBtn?.label = "World Type: \(worldPreset.displayName)"
        biomeBtn?.label = "Biome: \(singleBiomeDisplayName(singleBiome))"
        let showsBiome = worldPreset == .singleBiomeSurface
        biomeBtn?.visible = showsBiome
        let layout = Layout(uiHeight: lastUIHeight)
        biomeBtn?.y = layout.biomeY
        dungeonBtn?.y = layout.dungeonY(showsBiome: showsBiome)
        createBtn?.y = layout.actionY(showsBiome: showsBiome)
        cancelBtn?.y = layout.actionY(showsBiome: showsBiome)
        dungeonBtn?.label = "Dungeons: \(dungeonDensity.displayName)"
    }

    private func startPendingLANHost(_ game: GameCore) {
        guard let lanHostRequest else { return }
        do {
            try elysiumMainActorSync {
                try LANMultiplayerManager.shared.startHost(
                    game: game,
                    requestedJoinCode: lanHostRequest.joinCode,
                    requestedPort: lanHostRequest.port
                )
            }
            for line in LANMultiplayerManager.shared.statusSummary() {
                pushChat("§7" + line)
            }
        } catch let error as LANTransportError {
            pushChat("§c" + error.description)
        } catch {
            pushChat("§cLAN host failed: \(error)")
        }
    }
}

let DIFFICULTY_NAMES = ["Peaceful", "Easy", "Normal", "Hard"]

// =============================================================================
/// shown right after world entry while nearby chunks mesh — sim keeps running
/// (the player is frozen by heldForChunks until the ground exists)
final class LoadingScreen: Screen {
    private var openedAt = CACurrentMediaTime()
    static let target = 30

    override init() {
        super.init()
        closeOnEsc = false
    }
    /// sections meshed within 2 chunks of the player
    private func progress(_ game: GameCore) -> (Int, Int, Bool) {
        guard let renderer = gAppDelegate?.renderer, game.hasWorld(), let p = game.player else {
            return (0, Self.target, false)
        }
        let pcx = Int(p.x.rounded(.down)) >> 4, pcz = Int(p.z.rounded(.down)) >> 4
        var n = 0
        for key in renderer.sections.keys where abs(key.cx - pcx) <= 2 && abs(key.cz - pcz) <= 2 {
            n += 1
        }
        return (n, Self.target, n >= Self.target)
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        let (done, target, ready) = progress(game)
        let elapsed = CACurrentMediaTime() - openedAt
        if (ready && elapsed > 0.4) || elapsed > 8 {
            ui.closeTop(game)
            return
        }
        ui.drawDirtBg()
        ui.cv.drawTextCentered("Loading world…", ui.width / 2, ui.height / 2 - 24, 1)
        let w = 200.0
        let x = (ui.width - w) / 2, y = ui.height / 2
        let f = target > 0 ? min(1, Double(done) / Double(target)) : 0
        ui.cv.setFill("#1c1c1c")
        ui.cv.fillRect(x, y, w, 6)
        ui.cv.setFill("#80ff20")
        ui.cv.fillRect(x, y, (w * f).rounded(), 6)
        ui.cv.drawTextCentered("§7Building terrain (\(done)/\(target))", ui.width / 2, y + 14, 1)
    }
}

// =============================================================================
final class PauseScreen: Screen {
    override init() {
        super.init()
        pausesGame = true
    }
    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        let cx = (ui.width / 2).rounded(.down)
        var y = (ui.height / 2).rounded(.down) - 50
        buttons.append(Button(cx - 100, y, 200, 20, "Back to Game", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Advancements", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(AdvancementsScreen(), game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Options...", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(SettingsScreen(), game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Open to LAN", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(LANLobbyScreen(), game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Save & Quit to Title", { [weak game] in
            guard let game else { return }
            game.exitToTitle()
        }))
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.5)
        ui.cv.drawTextCentered("Game Menu", ui.width / 2, (ui.height / 2).rounded(.down) - 70, 1)
        ui.drawButtons(self)
    }
}

// =============================================================================
final class SettingsScreen: Screen {
    var tab = "video"
    var bindingKey: String?
    private var controlsScrollOffset = 0.0
    private var controlsLayout: ElysiumControlsLayout?
    private var pendingKeybindConflict: ElysiumControlsPendingConflict?
    private var pendingKeybindExpectedRevision: UInt64?
    private var controlsStatus = ""
    var aiModelField: TextField?
    var aiModelChoices: [String] = []
    var aiStatus = ""
    var hasActiveControlsCapture: Bool { bindingKey != nil }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        rebuild(ui, game)
    }

    @discardableResult
    private func persistSettingsMutation(
        _ game: GameCore, _ mutation: (inout Settings) -> Void
    ) -> Bool {
        var candidate = game.settings
        mutation(&candidate)
        return persistSettingsCandidate(
            game, candidate: candidate, expectedRevision: game.settingsRevision)
    }

    @discardableResult
    private func persistSettingsCandidate(
        _ game: GameCore, candidate: Settings, expectedRevision: UInt64
    ) -> Bool {
        return MainActor.assumeIsolated {
            if case .success = game.persistAndPublishSettingsCandidate(
                candidate, expectedLiveRevision: expectedRevision) { return true }
            return false
        }
    }

    @discardableResult
    private func persistControlsCandidate(
        _ game: GameCore, candidate: [String: String], expectedRevision: UInt64,
        successMessage: String
    ) -> Bool {
        let result = MainActor.assumeIsolated {
            game.persistAndPublishKeybindCandidate(
                candidate, expectedLiveRevision: expectedRevision)
        }
        switch result {
        case .success:
            controlsStatus = successMessage
            return true
        case .failure(let error):
            controlsStatus = "Could not save binding: \(error.description)"
            return false
        }
    }

    func rebuild(_ ui: UIManager, _ game: GameCore) {
        buttons = []
        sliders = []
        fields = []
        aiModelField = nil
        controlsLayout = nil
        let cx = (ui.width / 2).rounded(.down)
        // tabs
        let tabs = ["video", "audio", "controls", "accessibility", "ai"]
        let tabW = 64.0
        let tabStart = cx - (Double(tabs.count) * tabW) / 2
        for (i, t) in tabs.enumerated() {
            let label = t == "accessibility" ? "Access" : t.prefix(1).uppercased() + String(t.dropFirst())
            let b = Button(tabStart + Double(i) * tabW, 20, tabW - 2, 16, label, { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                guard self.saveAIModelIfNeeded(game) else { return }
                self.tab = t
                self.bindingKey = nil
                self.pendingKeybindConflict = nil
                self.pendingKeybindExpectedRevision = nil
                self.controlsStatus = ""
                self.rebuild(ui, game)
            })
            buttons.append(b)
        }
        var y = 46.0
        let W = 150.0, GAP = 158.0
        func toggle(_ label: String, _ get: @escaping (Settings) -> Bool,
                    _ set: @escaping (inout Settings, Bool) -> Void, _ col: Int) {
            let b = Button(cx - 160 + Double(col) * GAP, y, W, 18,
                           "\(label): \(get(game.settings) ? "ON" : "OFF")", {})
            b.onClick = { [weak self, weak b, weak game] in
                guard let self, let b, let game else { return }
                let next = !get(game.settings)
                guard self.persistSettingsMutation(game, { set(&$0, next) }) else { return }
                b.label = "\(label): \(get(game.settings) ? "ON" : "OFF")"
            }
            buttons.append(b)
        }
        if tab == "video" {
            sliders.append(Slider(cx - 160, y, W, 18,
                { [weak game] in "Render Distance: \(game?.settings.renderDistance ?? 8)" },
                { [weak game] in Double((game?.settings.renderDistance ?? 8) - 4) / 12 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) {
                        $0.renderDistance = 4 + Int((v * 12).rounded())
                    }
                }))
            sliders.append(Slider(cx - 2, y, W, 18,
                { [weak game] in "FOV: \(game?.settings.fov ?? 70)" },
                { [weak game] in Double((game?.settings.fov ?? 70) - 60) / 50 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) {
                        $0.fov = 60 + Int((v * 50).rounded())
                    }
                }))
            y += 22
            sliders.append(Slider(cx - 160, y, W, 18,
                { [weak game] in "Brightness: \(Int(((game?.settings.gamma ?? 0.5) * 100).rounded()))%" },
                { [weak game] in game?.settings.gamma ?? 0.5 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) { $0.gamma = v }
                }))
            sliders.append(Slider(cx - 2, y, W, 18,
                { [weak game] in
                    let g = game?.settings.guiScale ?? 0
                    return "GUI Scale: \(g == 0 ? "Auto" : String(g))"
                },
                { [weak game] in Double(game?.settings.guiScale ?? 0) / 4 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    let persisted = self.persistSettingsMutation(game) {
                        $0.guiScale = Int((v * 4).rounded())
                    }
                    // Re-layout only after the durable candidate publishes.
                    if persisted, let a = gAppDelegate {
                        a.ui.resize(Double(a.gameView.drawableSize.width),
                                    Double(a.gameView.drawableSize.height),
                                    a.game.settings.guiScale, relayout: a.game)
                    }
                }))
            y += 22
            toggle("Fancy Graphics", { $0.fancyGraphics }, { $0.fancyGraphics = $1 }, 0)
            toggle("Smooth Lighting", { $0.smoothLighting }, { $0.smoothLighting = $1 }, 1)
            y += 22
            toggle("Bloom", { $0.bloom }, { $0.bloom = $1 }, 0)
            toggle("Soft Shadows", { $0.shadows }, { $0.shadows = $1 }, 1)
            y += 22
            toggle("Clouds", { $0.clouds }, { $0.clouds = $1 }, 0)
            toggle("View Bobbing", { $0.viewBobbing }, { $0.viewBobbing = $1 }, 1)
            y += 22
            let fullscreen = Button(cx - 160, y, W, 18,
                "Fullscreen: \((gAppDelegate?.window?.styleMask.contains(.fullScreen) ?? false) ? "ON" : "OFF")", {
                    gAppDelegate?.window?.toggleFullScreen(nil)
                })
            buttons.append(fullscreen)
            y += 22
            sliders.append(Slider(cx - 160, y, W, 18,
                { [weak game] in "Particles: \(["Minimal", "Decreased", "All"][min(2, game?.settings.particles ?? 2)])" },
                { [weak game] in Double(game?.settings.particles ?? 2) / 2 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) {
                        $0.particles = Int((v * 2).rounded())
                    }
                }))
            sliders.append(Slider(cx - 2, y, W, 18,
                { [weak game] in
                    let f = game?.settings.maxFps ?? 250
                    return "Max FPS: \(f >= 250 ? "Unlimited" : String(f))"
                },
                { [weak game] in Double((game?.settings.maxFps ?? 250) - 30) / 220 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) {
                        $0.maxFps = 30 + Int((v * 220).rounded())
                    }
                }))
            y += 22
            let shaderB = Button(cx - 160, y, W, 18, "", {})
            func shaderLabel() -> String {
                "Shaders: \(game.settings.shader == "ultra" ? "§6ULTRA§r" : "OFF")"
            }
            shaderB.label = shaderLabel()
            shaderB.onClick = { [weak self, weak shaderB, weak game] in
                guard let self, let shaderB, let game else { return }
                guard self.persistSettingsMutation(game, {
                    $0.shader = game.settings.shader == "ultra" ? nil : "ultra"
                }) else { return }
                shaderB.label = shaderLabel()
            }
            buttons.append(shaderB)
        } else if tab == "audio" {
            let cats: [(String, String)] = [
                ("master", "Master Volume"), ("music", "Music"), ("blocks", "Blocks"),
                ("hostile", "Hostile Creatures"), ("friendly", "Friendly Creatures"),
                ("players", "Players"), ("ambient", "Ambient"), ("records", "Jukebox"),
                ("ui", "UI"),
            ]
            for (i, cat) in cats.enumerated() {
                let col = i % 2
                let key = cat.0, label = cat.1
                sliders.append(Slider(cx - 160 + Double(col) * GAP, y, W, 18,
                    { [weak game] in "\(label): \(Int(((game?.settings.volumes[key] ?? 1) * 100).rounded()))%" },
                    { [weak game] in game?.settings.volumes[key] ?? 1 },
                    { [weak self, weak game] v in
                        guard let self, let game else { return }
                        _ = self.persistSettingsMutation(game) { $0.volumes[key] = v }
                    }))
                if col == 1 { y += 22 }
            }
        } else if tab == "controls" {
            sliders.append(Slider(cx - 160, y, W, 18,
                { [weak game] in "Sensitivity: \(Int(((game?.settings.sensitivity ?? 0.5) * 200).rounded()))%" },
                { [weak game] in game?.settings.sensitivity ?? 0.5 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) { $0.sensitivity = v }
                }))
            toggle("Invert Y", { $0.invertY }, { $0.invertY = $1 }, 1)
            y += 26
            let contentBottom = max(y, ui.height - (pendingKeybindConflict == nil ? 52 : 72))
            let layout = ElysiumControlsLayout(
                viewportWidth: ui.width, contentTop: y, contentBottom: contentBottom,
                requestedScrollOffset: controlsScrollOffset, bindings: game.keybinds)
            controlsLayout = layout
            controlsScrollOffset = layout.clampedScrollOffset
            for row in layout.visibleRows {
                let captureWidth = 48.0
                let resetWidth = 36.0
                let resetX = row.x + row.width - resetWidth
                let captureX = resetX - captureWidth - 2
                let capture = Button(captureX, row.y + 1, captureWidth, 18,
                                     bindingKey == row.actionID ? "Listening" : "Capture", {})
                capture.onClick = { [weak self, weak ui, weak game] in
                    guard let self, let ui, let game else { return }
                    self.bindingKey = row.actionID
                    self.pendingKeybindConflict = nil
                    self.pendingKeybindExpectedRevision = nil
                    self.controlsStatus = "Press a chord; Escape cancels."
                    self.rebuild(ui, game)
                }
                buttons.append(capture)

                let reset = Button(resetX, row.y + 1, resetWidth, 18, "Reset", {})
                reset.onClick = { [weak self, weak ui, weak game] in
                    guard let self, let ui, let game,
                          let definition = KEYBIND_DEFINITIONS.first(where: {
                              $0.actionID == row.actionID
                          }) else { return }
                    self.bindingKey = nil
                    self.pendingKeybindConflict = nil
                    self.pendingKeybindExpectedRevision = nil
                    self.applyControlsChord(definition.defaultChord, actionID: row.actionID,
                                            ui: ui, game: game)
                }
                buttons.append(reset)
            }
            if let pending = pendingKeybindConflict,
               let expectedRevision = pendingKeybindExpectedRevision {
                let useAnyway = Button(cx - 50, ui.height - 52, 100, 16, "Use Anyway", {})
                useAnyway.onClick = { [weak self, weak ui, weak game] in
                    guard let self, let ui, let game else { return }
                    if self.persistControlsCandidate(
                        game, candidate: pending.candidateBindings,
                        expectedRevision: expectedRevision,
                        successMessage: "Saved \(pending.chord.description) for \(pending.actionID)."
                    ) {
                        self.pendingKeybindConflict = nil
                        self.pendingKeybindExpectedRevision = nil
                    }
                    self.rebuild(ui, game)
                }
                buttons.append(useAnyway)
            }
        } else if tab == "accessibility" {
            toggle("Subtitles", { $0.subtitles }, { $0.subtitles = $1 }, 0)
            toggle("Auto-Jump", { $0.autoJump }, { $0.autoJump = $1 }, 1)
            y += 22
            toggle("Reduce Motion", { $0.reduceMotion }, { $0.reduceMotion = $1 }, 0)
            toggle("Reduced Flashes", { $0.reducedFlashes }, { $0.reducedFlashes = $1 }, 1)
            y += 22
            toggle("High Contrast UI", { $0.highContrast }, { $0.highContrast = $1 }, 0)
            sliders.append(Slider(cx - 2, y, W, 18,
                { [weak game] in "Darkness Pulsing: \(Int(((game?.settings.darknessPulse ?? 1) * 100).rounded()))%" },
                { [weak game] in game?.settings.darknessPulse ?? 1 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) { $0.darknessPulse = v }
                }))
        } else if tab == "ai" {
            let modelField = TextField(cx - 160, y + 14, W * 2 + 8, 18, "ollama model",
                                       id: "settings.ollamaModel",
                                       accessibilityLabel: "Ollama Model")
            modelField.maxLength = 128
            modelField.text = game.settings.aiOllamaModel
            modelField.caret = modelField.text.count
            fields.append(modelField)
            aiModelField = modelField

            buttons.append(Button(cx - 160, y + 38, W, 18, "Save Model", { [weak self, weak game] in
                guard let self, let game else { return }
                guard self.saveAIModelIfNeeded(game) else { return }
                self.aiStatus = game.settings.aiOllamaModel.isEmpty ? "Model cleared" : "Saved \(game.settings.aiOllamaModel)"
            }))
            buttons.append(Button(cx - 2, y + 38, W, 18, "Refresh Models", { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                guard self.saveAIModelIfNeeded(game) else { return }
                let refreshCandidate = game.settings
                let refreshExpectedRevision = game.settingsRevision
                self.aiStatus = "Refreshing..."
                elysiumOllamaAgent.fetchModels { [weak self, weak ui, weak game] result in
                    guard let self, let ui, let game else { return }
                    switch result {
                    case .success(let names):
                        var candidate = refreshCandidate
                        if candidate.aiOllamaModel.isEmpty, let first = names.first {
                            candidate.aiOllamaModel = first
                        }
                        guard self.persistSettingsCandidate(
                            game, candidate: candidate,
                            expectedRevision: refreshExpectedRevision) else { return }
                        self.aiModelChoices = names
                        self.aiStatus = names.isEmpty ? "No local models found" : "Loaded \(names.count) local models"
                    case .failure(let error):
                        self.aiStatus = "Ollama unavailable: \(error.localizedDescription)"
                    }
                    self.rebuild(ui, game)
                }
            }))
            let next = Button(cx - 160, y + 60, W, 18, "Next Model", { [weak self, weak game] in
                guard let self, let game, !self.aiModelChoices.isEmpty else { return }
                let current = sanitizedOllamaModelName(self.aiModelField?.text ?? game.settings.aiOllamaModel)
                let idx = self.aiModelChoices.firstIndex(of: current) ?? -1
                let next = self.aiModelChoices[(idx + 1) % self.aiModelChoices.count]
                guard self.persistSettingsMutation(game, { $0.aiOllamaModel = next }) else { return }
                self.aiModelField?.text = next
                self.aiModelField?.caret = next.count
                self.aiStatus = "Selected \(next)"
            })
            next.enabled = !aiModelChoices.isEmpty
            buttons.append(next)
            buttons.append(Button(cx - 2, y + 60, W, 18, "Clear Model", { [weak self, weak game] in
                guard let self, let game else { return }
                guard self.persistSettingsMutation(game, { $0.aiOllamaModel = "" }) else { return }
                self.aiModelField?.text = ""
                self.aiModelField?.caret = 0
                self.aiStatus = "Model cleared"
            }))
        }
        buttons.append(Button(cx - 100, ui.height - 30, 200, 20, "Done", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            guard self.saveAIModelIfNeeded(game) else { return }
            ui.closeTop(game)
        }))
    }

    /// Shared capture seam for the AppKit router: validation is pure and the live label remains
    /// sourced from `game.keybinds` until the detached candidate has durably published.
    func applyControlsChord(_ chord: ElysiumKeyChord, actionID: String,
                            ui: UIManager, game: GameCore) {
        let expectedRevision = game.keybindRevision
        bindingKey = nil
        pendingKeybindConflict = nil
        pendingKeybindExpectedRevision = nil
        switch prepareControlsKeybindCandidate(
            bindings: game.keybinds, actionID: actionID, chord: chord) {
        case .reserved:
            controlsStatus = "Reserved by Elysium"
        case .invalidAction, .invalidBindings:
            controlsStatus = "Binding was not changed."
        case .conflict(let pending):
            pendingKeybindConflict = pending
            pendingKeybindExpectedRevision = expectedRevision
            controlsStatus = "Conflict: \(pending.conflictingActionIDs.joined(separator: ", ")). "
                + "Winner: \(pending.winnerActionID)."
        case .ready(let committedActionID, let canonicalChord, let candidate):
            _ = persistControlsCandidate(
                game, candidate: candidate, expectedRevision: expectedRevision,
                successMessage: "Saved \(canonicalChord.description) for \(committedActionID).")
        }
        rebuild(ui, game)
    }

    @discardableResult
    func cancelControlsCapture(_ ui: UIManager, _ game: GameCore) -> Bool {
        guard bindingKey != nil || pendingKeybindConflict != nil else { return false }
        bindingKey = nil
        pendingKeybindConflict = nil
        pendingKeybindExpectedRevision = nil
        controlsStatus = "Capture cancelled."
        rebuild(ui, game)
        return true
    }

    @discardableResult
    func handleControlsKeyEvent(_ event: ElysiumKeyEvent,
                                ui: UIManager, game: GameCore) -> Bool {
        guard let binding = bindingKey else { return false }
        if event.terminal.rawValue == "Escape" { return cancelControlsCapture(ui, game) }
        guard !event.isRepeat, let chord = event.chord else {
            controlsStatus = "That key cannot be bound."
            rebuild(ui, game)
            return true
        }
        applyControlsChord(chord, actionID: binding, ui: ui, game: game)
        return true
    }

    @discardableResult
    func saveAIModelIfNeeded(_ game: GameCore) -> Bool {
        guard tab == "ai", let field = aiModelField else { return true }
        var model = sanitizedOllamaModelName(field.text)
        if !model.isEmpty && !isAllowedLocalOllamaModelName(model) {
            model = ""
            aiStatus = "Cloud models are not allowed"
        }
        guard persistSettingsMutation(game, { $0.aiOllamaModel = model }) else { return false }
        field.text = model
        field.caret = min(field.caret, field.text.count)
        return true
    }
    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        if tab == "ai", key == "Enter" {
            guard saveAIModelIfNeeded(game) else { return true }
            aiStatus = game.settings.aiOllamaModel.isEmpty ? "Model cleared" : "Saved \(game.settings.aiOllamaModel)"
            return true
        }
        return super.onKey(ui, game, key)
    }
    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        guard tab == "controls", let layout = controlsLayout else {
            return super.onWheel(ui, game, dy)
        }
        let finiteDelta = dy.isFinite ? dy : 0
        controlsScrollOffset = min(max(0,
            layout.clampedScrollOffset + finiteDelta * ElysiumControlsLayout.rowStride),
            layout.maximumScrollOffset)
        rebuild(ui, game)
        return true
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        if game.hasWorld() {
            ui.drawDarkBg(0.65)
        } else {
            ui.drawDirtBg()
        }
        ui.cv.drawTextCentered("Options", ui.width / 2, 6, 1)
        if tab == "controls", let layout = controlsLayout {
            for row in layout.visibleRows {
                let definition = KEYBIND_DEFINITIONS[row.definitionIndex]
                let hovered = ui.mouseX >= row.x && ui.mouseX < row.x + row.width
                    && ui.mouseY >= row.y && ui.mouseY < row.y + row.height
                ui.cv.setFill(hovered ? "rgba(255,255,255,0.16)" : "rgba(0,0,0,0.24)")
                ui.cv.fillRect(row.x, row.y, row.width, row.height)
                let textWidthAvailable = max(24, row.width - 92)
                ui.cv.drawText(controlsClipped(definition.displayName,
                                               maximumPixels: textWidthAvailable),
                               row.x + 3, row.y + 2, 0.75, "#ffffff", shadow: false)
                let bindingText = bindingKey == row.actionID
                    ? "[press chord]" : row.chordText + (row.conflictText == nil ? "" : " • Conflict")
                ui.cv.drawText(controlsClipped(bindingText, maximumPixels: textWidthAvailable,
                                               scale: 0.75),
                               row.x + 3, row.y + 11, 0.75,
                               row.conflictText == nil ? "#b8b8b8" : "#ffb060", shadow: false)
                if hovered {
                    var lines = [definition.displayName, "Binding: \(row.chordText)"]
                    if let conflict = row.conflictText { lines.append(conflict) }
                    ui.tooltipLines = lines
                }
            }
            let contentTop = 72.0
            let contentBottom = max(contentTop,
                ui.height - (pendingKeybindConflict == nil ? 52 : 72))
            if layout.maximumScrollOffset > 0, contentBottom > contentTop {
                let trackHeight = contentBottom - contentTop
                let contentHeight = trackHeight + layout.maximumScrollOffset
                let thumbHeight = max(10, trackHeight * trackHeight / contentHeight)
                let thumbY = contentTop + (trackHeight - thumbHeight)
                    * layout.clampedScrollOffset / layout.maximumScrollOffset
                ui.cv.setFill("rgba(0,0,0,0.45)")
                ui.cv.fillRect(ui.width - 5, contentTop, 3, trackHeight)
                ui.cv.setFill("rgba(255,255,255,0.60)")
                ui.cv.fillRect(ui.width - 5, thumbY, 3, thumbHeight)
            }
            if !controlsStatus.isEmpty {
                let statusY = contentBottom + 2
                ui.cv.drawText(controlsClipped(controlsStatus,
                                               maximumPixels: max(20, ui.width - 28), scale: 0.75),
                               14, statusY, 0.75,
                               pendingKeybindConflict == nil ? "#d0d0d0" : "#ffb060",
                               shadow: false)
                if ui.mouseY >= statusY - 2 && ui.mouseY < statusY + 10 {
                    ui.tooltipLines = [controlsStatus]
                }
            }
        } else if tab == "ai" {
            let cx = (ui.width / 2).rounded(.down)
            ui.cv.drawText("Ollama Model", cx - 160, 46, 1)
            if !aiStatus.isEmpty {
                ui.cv.drawText(aiStatus, cx - 160, 132, 1, "#a0a0a0")
            }
        }
        ui.drawButtons(self)
    }

    private func controlsClipped(_ text: String, maximumPixels: Double,
                                 scale: Double = 0.75) -> String {
        guard maximumPixels > 0, Double(textWidth(text)) * scale > maximumPixels else { return text }
        var result = text
        while !result.isEmpty && Double(textWidth(result + "…")) * scale > maximumPixels {
            result.removeLast()
        }
        return result + "…"
    }
}

// =============================================================================
// =============================================================================
final class AdvancementsScreen: Screen {
    var scrollX = 0.0
    var scrollY = 0.0
    var dragging = false
    var positions: [String: (Double, Double)] = [:]

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        // layout: BFS depth → column, siblings → rows
        var children: [String: [AdvancementDef]] = [:]
        for a in ADVANCEMENTS {
            children[a.parent ?? "<root>", default: []].append(a)
        }
        var nextRow = 0.0
        func place(_ id: String, _ depth: Double) -> Double {
            let kids = children[id] ?? []
            if kids.isEmpty {
                let row = nextRow
                nextRow += 1
                positions[id] = (depth, row)
                return row
            }
            let rows = kids.map { place($0.id, depth + 1) }
            let row = (rows.min()! + rows.max()!) / 2
            positions[id] = (depth, row)
            return row
        }
        _ = place("root", 0)
        buttons.append(Button(8, ui.height - 28, 80, 20, "Done", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        }))
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.7)
        let cv = ui.cv
        cv.drawTextCentered("Advancements (\(game.advancements.earnedOrder.count)/\(ADVANCEMENTS.count))", ui.width / 2, 6, 1)
        let ox = 30 + scrollX, oy = 30 + scrollY
        // connection lines
        cv.setStroke("#707070")
        for a in ADVANCEMENTS {
            guard let parent = a.parent, let p = positions[a.id], let pp = positions[parent] else { continue }
            cv.line(ox + pp.0 * 70 + 24, oy + pp.1 * 30 + 12, ox + p.0 * 70 - 2, oy + p.1 * 30 + 12)
        }
        var hovered: AdvancementDef?
        for a in ADVANCEMENTS {
            guard let p = positions[a.id] else { continue }
            let x = ox + p.0 * 70, y = oy + p.1 * 30
            if x < -30 || x > ui.width + 10 || y < -30 || y > ui.height + 10 { continue }
            let earned = game.advancements.has(a.id)
            cv.setFill(earned ? (a.frame == "challenge" ? "#9a4ae8" : "#e8a83c") : "#3a3a3a")
            cv.fillRect(x, y, 24, 24)  // (challenge diamonds render as squares natively)
            cv.setStroke(earned ? "#ffffff" : "#1a1a1a")
            cv.strokeRect(x, y, 24, 24)
            if let iconId = iidOpt(a.icon) {
                cv.globalAlpha = earned ? 1 : 0.4
                cv.drawItemIcon(iconId, nil, x + 4, y + 4, 16, 16)
                cv.globalAlpha = 1
            }
            if ui.mouseX >= x && ui.mouseX < x + 24 && ui.mouseY >= y && ui.mouseY < y + 24 { hovered = a }
        }
        if let hovered {
            ui.tooltipLines = [
                (game.advancements.has(hovered.id) ? "§a" : "§f") + hovered.title,
                "§7" + hovered.description,
            ]
        }
        ui.drawButtons(self)
        cv.drawText("Drag to pan", ui.width - 70, ui.height - 12, 1, "#808080")
    }
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        if super.onMouseDown(ui, game, mx, my, btn) { return true }
        dragging = true
        return true
    }
    override func onMouseUp(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        super.onMouseUp(ui, game, mx, my)
        dragging = false
    }
    override func onMouseMove(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        super.onMouseMove(ui, game, mx, my)
        if dragging {
            scrollX += mx - ui.mouseX
            scrollY += my - ui.mouseY
        }
    }
    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        scrollY -= (dy > 0 ? 1 : dy < 0 ? -1 : 0) * 20
        return true
    }
}

// =============================================================================
final class CreditsScreen: Screen {
    var scroll = 0.0
    private var lastT = CACurrentMediaTime()
    let lines = [
        "§eELYSIUM",
        "",
        "§7A complete block-survival game",
        "§7built from scratch in Swift + Metal.",
        "",
        "§fEvery sound synthesized in real time.",
        "§fEvery chunk carved from noise.",
        "",
        "§8— —",
        "",
        "§dTwo voices, somewhere outside the world:",
        "",
        "§3it reached the end of its journey.",
        "§9and yet the world it shaped keeps turning.",
        "§3it built, and broke, and built again.",
        "§9that is the whole of the game, and the whole of the player.",
        "§3does it know the stars were painted for it?",
        "§9it knows. it placed a torch against the dark anyway.",
        "§3let it rest now.",
        "§9let it wake. there is always another world.",
        "",
        "",
        "§eThank you for playing.",
        "",
        "§7Inspired by the classic block game.",
        "§7Elysium is an original fan re-creation.",
        "§7Not affiliated with Mojang or Microsoft.",
        "§7No Mojang code or asset files included.",
        "",
        "§fAll textures: Faithful 32x,",
        "§funmodified, by the Faithful Team.",
        "§efaithfulpack.net",
    ]
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.cv.setFill("#000000")
        ui.cv.fillRect(0, 0, ui.width, ui.height)
        // time-based: a per-frame increment scrolled 2-10× too fast uncapped
        let nowT = CACurrentMediaTime()
        scroll += min(0.25, nowT - lastT) * 15
        lastT = nowT
        var y = ui.height - scroll
        for line in lines {
            if y > -10 && y < ui.height + 10 {
                ui.cv.drawTextCentered(line, ui.width / 2, y, 1)
            }
            y += 14
        }
        if y < -20 {
            ui.closeTop(game)
        }
        ui.cv.drawTextCentered("§8Press Esc to skip", ui.width / 2, ui.height - 12, 1)
    }
}
