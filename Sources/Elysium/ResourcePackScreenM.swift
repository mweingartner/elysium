import AppKit
import ElysiumCore
import Foundation

final class ResourcePackCPUWorker {
    static let shared = ResourcePackCPUWorker()

    typealias Preparation = (ResourcePackStackSourceSnapshot,
                             ResourcePackCancellationToken) -> PreparedResourcePackTransaction?

    private let queue: DispatchQueue
    private let preparation: Preparation
    private let lock = NSLock()
    private var leasedTransactionID: UInt64?
    private var leasedCancellation: ResourcePackCancellationToken?

    init(queueLabel: String = "com.elysium.resource-pack.prepare",
         preparation: @escaping Preparation = prepareResourcePackTransaction) {
        queue = DispatchQueue(label: queueLabel, qos: .userInitiated)
        self.preparation = preparation
    }

    var isLeased: Bool {
        lock.lock(); defer { lock.unlock() }
        return leasedTransactionID != nil
    }

    func submit(transactionID: UInt64, snapshot: ResourcePackStackSourceSnapshot,
                completion: @escaping (UInt64, PreparedResourcePackTransaction?, Bool) -> Void) -> Bool {
        lock.lock()
        guard leasedTransactionID == nil else { lock.unlock(); return false }
        let cancellation = ResourcePackCancellationToken()
        leasedTransactionID = transactionID
        leasedCancellation = cancellation
        lock.unlock()

        queue.async { [weak self] in
            let prepared = self?.preparation(snapshot, cancellation)
            guard let self else { return }
            self.lock.lock()
            let cancelled = cancellation.isCancelled
            if self.leasedTransactionID == transactionID {
                self.leasedTransactionID = nil
                self.leasedCancellation = nil
            }
            self.lock.unlock()
            DispatchQueue.main.async {
                completion(transactionID, cancelled ? nil : prepared, cancelled)
            }
        }
        return true
    }

    /// Cancellation invalidates publication immediately and cooperatively stops budgeted work;
    /// the single-worker lease remains occupied until that work has actually drained.
    func cancel(transactionID: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if leasedTransactionID == transactionID { leasedCancellation?.cancel() }
    }
}

/// Video-options child screen for the closed, locally bundled visual-style catalog.
final class ResourcePackScreen: Screen {
    private struct BaselinePresentation {
        let canvas: String
        let value: String
        let help: String
    }

    private struct StatusPresentation {
        let canvas: String
        let recovery: String?
        let value: String
        let help: String
    }

    private struct Transaction {
        let id: UInt64
        let requested: RequestedChange
        let displayName: String
        let candidateBaseStyle: BundledResourcePackBaseStyleID
        let candidateIDs: [BundledResourcePackAddOnID]
        let priorSettings: Settings
        let expectedRevision: UInt64
        let deadlineUptimeNanoseconds: UInt64
    }

    private enum RequestedChange: Equatable {
        case baseStyle(BundledResourcePackBaseStyleID)
        case addOn(BundledResourcePackAddOnID)

        var rawValue: String {
            switch self {
            case .baseStyle(let style): return style.rawValue
            case .addOn(let addOn): return addOn.rawValue
            }
        }

        var focusID: ResourcePackScreenFocusID {
            switch self {
            case .baseStyle(let style): return .baseStyle(style)
            case .addOn(let addOn): return .addOn(addOn)
            }
        }
    }

    private var status = "Select a visual style; Faithful add-ons remain opt-in."
    private var applyState: ResourcePackApplyState = .idle
    private var transaction: Transaction?
    private var nextTransactionID: UInt64 = 0
    private var focusedID: ResourcePackScreenFocusID = .baseStyle(.faithful64x)
    private var controlsByFocusID: [ResourcePackScreenFocusID: Button] = [:]
    private var pendingAnnouncement: String?

    private func baselinePresentation() -> BaselinePresentation {
        switch RESOURCE_PACK_PRESENTATION.generation {
        case .faithful64x:
            return BaselinePresentation(
                canvas: "Visual style: Faithful 64x",
                value: "Faithful 64x active",
                help: "Faithful 64x is the active visual baseline.")
        case .kubikosCubicWorld:
            return BaselinePresentation(
                canvas: "Visual style: KUBIKOS Cubic World",
                value: "KUBIKOS Cubic World active",
                help: "KUBIKOS Cubic World replaces the complete bundled visual baseline.")
        case .proceduralFallback:
            return BaselinePresentation(
                canvas: "Visual style unavailable; built-in fallback active",
                value: "Unavailable; built-in fallback active",
                help: "The selected visual baseline could not be loaded; built-in textures are active.")
        }
    }

    private func statusPresentation(_ game: GameCore) -> StatusPresentation {
        let recovery = game.settingsRecoveryRequired
            ? "Settings recovery required — Restart Elysium" : nil
        return StatusPresentation(
            canvas: status, recovery: recovery,
            value: [status, recovery].compactMap { $0 }.joined(separator: " — "),
            help: recovery == nil
                ? "Current resource pack operation status."
                : "Restart Elysium before changing settings again.")
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        if game.settingsRecoveryRequired,
           let raw = game.settingsRecoveryRequestedResourcePackID {
            if let style = BundledResourcePackBaseStyleID(rawValue: raw) {
                focusedID = .baseStyle(style)
            } else if let requested = BundledResourcePackAddOnID(rawValue: raw) {
                focusedID = .addOn(requested)
            }
            status = "Could not confirm the saved resource pack choice; restart Elysium before changing it again."
        }
        rebuild(ui, game)
        pendingAnnouncement = game.consumeSettingsRecoveryAnnouncement()
    }

    override func onClose(_ ui: UIManager, _ game: GameCore) {
        if case .awaitingPresentedFrame(let id) = applyState {
            ui.cancelAfterNextPresentedFrame()
            transaction = nil
            applyState = .idle
            ResourcePackCPUWorker.shared.cancel(transactionID: id)
        } else if case .preparing(let id) = applyState {
            transaction = nil
            applyState = .idle
            ResourcePackCPUWorker.shared.cancel(transactionID: id)
        }
    }

    private func rebuild(_ ui: UIManager, _ game: GameCore) {
        buttons = []
        controlsByFocusID = [:]
        let baseStyle = sanitizedBundledResourcePackBaseStyleID(game.settings.bundledResourcePackBaseStyle)
        let selected = Set(sanitizedBundledResourcePackAddOnIDs(
            game.settings.bundledResourcePackAddOns, for: baseStyle))
        let cx = (ui.width / 2).rounded(.down)
        var y = 78.0
        let idle: Bool
        if case .idle = applyState { idle = true } else { idle = false }
        for descriptor in BUNDLED_RESOURCE_PACK_BASE_STYLES {
            let isSelected = descriptor.id == baseStyle
            let focusID = ResourcePackScreenFocusID.baseStyle(descriptor.id)
            let button = Button(cx - 150, y, 300, 22,
                                "\(descriptor.displayName): \(isSelected ? "Selected" : "Select")", {})
            button.enabled = idle && !game.settingsRecoveryRequired && !isSelected
            button.onClick = { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                self.focusedID = focusID
                self.beginSelectBaseStyle(descriptor.id, ui: ui, game: game)
            }
            buttons.append(button)
            controlsByFocusID[focusID] = button
            y += 32
        }
        y += 4
        for descriptor in BUNDLED_RESOURCE_PACK_ADD_ONS {
            let isOn = selected.contains(descriptor.id)
            let value = baseStyle != .faithful64x
                ? "Requires Faithful 64x"
                : game.settingsRecoveryRequired
                ? "Current session: \(isOn ? "ON" : "OFF"); saved choice unknown"
                : (isOn ? "ON" : "OFF")
            let focusID = ResourcePackScreenFocusID.addOn(descriptor.id)
            let button = Button(cx - 150, y, 300, 22, "\(descriptor.displayName): \(value)", {})
            button.enabled = idle && !game.settingsRecoveryRequired && baseStyle == .faithful64x
            button.onClick = { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                self.focusedID = focusID
                self.beginToggle(descriptor.id, ui: ui, game: game)
            }
            buttons.append(button)
            controlsByFocusID[focusID] = button
            y += 32
        }
        if game.settingsRecoveryRequired && !game.settingsRecoveryTransientAcknowledged {
            let acknowledge = Button(cx - 75, y, 150, 18, "Acknowledge", { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                game.acknowledgeSettingsRecoveryNotice()
                self.pendingAnnouncement = nil
                if self.focusedID == .acknowledge { self.focusedID = .done }
                self.rebuild(ui, game)
                ui.renewTextAccessibilityPresentation(screen: self, game: game)
            })
            buttons.append(acknowledge)
            controlsByFocusID[.acknowledge] = acknowledge
        }
        let done = Button(cx - 100, ui.height - 30, 200, 20,
                          idle ? "Done" : "Applying…", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        })
        done.enabled = idle
        buttons.append(done)
        controlsByFocusID[.done] = done
    }

    private func publishState(_ ui: UIManager, _ game: GameCore, announcement: String? = nil) {
        if let announcement { pendingAnnouncement = announcement }
        rebuild(ui, game)
        ui.renewTextAccessibilityPresentation(screen: self, game: game)
    }

    private func allocateTransactionID() -> UInt64? {
        let next = nextTransactionID.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue != 0 else { return nil }
        nextTransactionID = next.partialValue
        return next.partialValue
    }

    private func deadlineExpired(_ transaction: Transaction) -> Bool {
        DispatchTime.now().uptimeNanoseconds >= transaction.deadlineUptimeNanoseconds
    }

    private func beginSelectBaseStyle(_ style: BundledResourcePackBaseStyleID,
                                      ui: UIManager, game: GameCore) {
        let current = sanitizedBundledResourcePackBaseStyleID(game.settings.bundledResourcePackBaseStyle)
        guard current != style,
              let descriptor = BUNDLED_RESOURCE_PACK_BASE_STYLES.first(where: { $0.id == style }) else { return }
        let retained = sanitizedBundledResourcePackAddOnIDs(
            game.settings.bundledResourcePackAddOns, for: style)
        beginTransaction(requested: .baseStyle(style), displayName: descriptor.displayName,
                         candidateBaseStyle: style, candidateIDs: retained, ui: ui, game: game)
    }

    private func beginToggle(_ id: BundledResourcePackAddOnID, ui: UIManager, game: GameCore) {
        let baseStyle = sanitizedBundledResourcePackBaseStyleID(game.settings.bundledResourcePackBaseStyle)
        guard baseStyle == .faithful64x else {
            status = "Faithful add-ons require the Faithful 64x visual style."
            publishState(ui, game, announcement: status)
            return
        }
        guard let descriptor = BUNDLED_RESOURCE_PACK_ADD_ONS.first(where: { $0.id == id }) else { return }
        let priorIDs = sanitizedBundledResourcePackAddOnIDs(game.settings.bundledResourcePackAddOns,
                                                             for: baseStyle)
        switch evaluateBundledResourcePackToggle(selected: priorIDs.map(\.rawValue), requested: id.rawValue) {
        case .invalid:
            status = "Resource pack choice was not changed."
            publishState(ui, game, announcement: status)
        case .conflict(let requested, let active):
            status = "Cannot enable \(requested) while \(active) is active."
            publishState(ui, game, announcement: status)
        case .ready(let candidateIDs):
            beginTransaction(requested: .addOn(id), displayName: descriptor.displayName,
                             candidateBaseStyle: baseStyle, candidateIDs: candidateIDs, ui: ui, game: game)
        }
    }

    private func beginTransaction(requested: RequestedChange, displayName: String,
                                  candidateBaseStyle: BundledResourcePackBaseStyleID,
                                  candidateIDs: [BundledResourcePackAddOnID],
                                  ui: UIManager, game: GameCore) {
        guard !game.settingsRecoveryRequired else { return }
        guard case .idle = applyState else { return }
        guard !ResourcePackCPUWorker.shared.isLeased else {
            status = "Previous resource pack work is still finishing; try again shortly."
            publishState(ui, game, announcement: status)
            return
        }
        let deadline = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(15_000_000_000)
        guard let transactionID = allocateTransactionID(), !deadline.overflow else {
            status = "Could not apply \(displayName): transaction limit reached."
            publishState(ui, game, announcement: status)
            return
        }
        let value = Transaction(
            id: transactionID, requested: requested, displayName: displayName,
            candidateBaseStyle: candidateBaseStyle, candidateIDs: candidateIDs,
            priorSettings: game.settings, expectedRevision: game.settingsRevision,
            deadlineUptimeNanoseconds: deadline.partialValue)
        transaction = value
        focusedID = requested.focusID
        applyState = .awaitingPresentedFrame(transactionID: transactionID)
        status = "Applying \(displayName)…"
        publishState(ui, game, announcement: status)
        guard ui.afterNextPresentedFrame({ [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            self.startPreparation(transactionID: transactionID, ui: ui, game: game)
        }) else {
            transaction = nil
            applyState = .idle
            status = "Could not apply \(displayName): presentation unavailable."
            publishState(ui, game, announcement: status)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline.partialValue)) {
            [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            self.timeout(transactionID: transactionID, ui: ui, game: game)
        }
    }

    private func startPreparation(transactionID: UInt64, ui: UIManager, game: GameCore) {
        guard ui.current() === self,
              let transaction, transaction.id == transactionID,
              case .awaitingPresentedFrame(let stateID) = applyState,
              stateID == transactionID else { return }
        applyState = .preparing(transactionID: transactionID)
        publishState(ui, game)
        if deadlineExpired(transaction) {
            timeout(transactionID: transactionID, ui: ui, game: game)
            return
        }
        guard let snapshot = snapshotResourcePackStack(
            transaction.priorSettings.resourcePacks ?? [],
            bundledBaseStyle: transaction.candidateBaseStyle,
            bundledAddOns: transaction.candidateIDs) else {
            self.transaction = nil
            applyState = .idle
            focusedID = transaction.requested.focusID
            status = "Could not apply \(transaction.displayName): source snapshot failed."
            publishState(ui, game, announcement: status)
            return
        }
        if deadlineExpired(transaction) {
            timeout(transactionID: transactionID, ui: ui, game: game)
            return
        }
        let admitted = ResourcePackCPUWorker.shared.submit(
            transactionID: transactionID, snapshot: snapshot
        ) { [weak self, weak ui, weak game] completedID, prepared, cancelled in
            guard let self, let ui, let game else { return }
            self.preparationCompleted(transactionID: completedID, prepared: prepared,
                                      cancelled: cancelled, ui: ui, game: game)
        }
        guard admitted else {
            self.transaction = nil
            applyState = .idle
            status = "Previous resource pack work is still finishing; try again shortly."
            publishState(ui, game, announcement: status)
            return
        }
    }

    private func timeout(transactionID: UInt64, ui: UIManager, game: GameCore) {
        guard let transaction, transaction.id == transactionID else { return }
        switch applyState {
        case .awaitingPresentedFrame(let stateID) where stateID == transactionID:
            ui.cancelAfterNextPresentedFrame()
        case .preparing(let stateID) where stateID == transactionID:
            ResourcePackCPUWorker.shared.cancel(transactionID: transactionID)
        default:
            return
        }
        self.transaction = nil
        applyState = .idle
        focusedID = transaction.requested.focusID
        status = "Could not apply \(transaction.displayName): timed out"
        publishState(ui, game, announcement: status)
    }

    private func preparationCompleted(transactionID: UInt64,
                                      prepared: PreparedResourcePackTransaction?, cancelled: Bool,
                                      ui: UIManager, game: GameCore) {
        guard !cancelled, ui.current() === self,
              let transaction, transaction.id == transactionID,
              case .preparing(let stateID) = applyState,
              stateID == transactionID else { return }
        guard let prepared else {
            self.transaction = nil
            applyState = .idle
            status = "Could not apply \(transaction.displayName): pack validation failed."
            publishState(ui, game, announcement: status)
            return
        }
        finishPrepared(transaction, prepared: prepared, ui: ui, game: game)
    }

    /// Fallible staging precedes persistence. Once persistence commits, publication consumes the
    /// staged generation without a failure branch or a second filesystem/parse/decode pass.
    private func finishPrepared(_ transaction: Transaction,
                                prepared: PreparedResourcePackTransaction,
                                ui: UIManager, game: GameCore) {
        MainActor.preconditionIsolated()
        defer {
            self.transaction = nil
            applyState = .idle
            focusedID = transaction.requested.focusID
            publishState(ui, game, announcement: status)
        }
        guard game.settingsRevision == transaction.expectedRevision else {
            status = "Resource pack choices changed; try again."
            return
        }
        if deadlineExpired(transaction) {
            timeout(transactionID: transaction.id, ui: ui, game: game)
            return
        }
        guard let renderer = gAppDelegate?.renderer else {
            status = "Could not apply \(transaction.displayName): renderer unavailable."
            return
        }
        guard let staged = prepared.stage(renderer: renderer, game: game) else {
            status = "Could not apply \(transaction.displayName): staging failed."
            return
        }
        if deadlineExpired(transaction) {
            timeout(transactionID: transaction.id, ui: ui, game: game)
            return
        }
        var candidate = transaction.priorSettings
        candidate.bundledResourcePackBaseStyle = transaction.candidateBaseStyle.rawValue
        candidate.bundledResourcePackAddOns = transaction.candidateIDs.map(\.rawValue)
        let persistence = MainActor.assumeIsolated {
            game.persistAndPublishSettingsCandidateCommitAware(
                candidate, expectedLiveRevision: transaction.expectedRevision,
                recoveryRequestedResourcePackID: transaction.requested.rawValue)
        }
        let durabilityWarning: Bool
        switch persistence {
        case .committed:
            durabilityWarning = false
        case .committedWithDurabilityWarning:
            durabilityWarning = true
        case .retainedPrior:
            status = "Could not save resource pack choice."
            return
        case .recoveryRequired:
            status = "Could not confirm the saved resource pack choice; restart Elysium before changing it again."
            pendingAnnouncement = game.consumeSettingsRecoveryAnnouncement()
            return
        }
        staged.publish(game: game, renderer: renderer, ui: ui)
        status = durabilityWarning
            ? "Applied \(transaction.displayName); disk durability was not confirmed."
            : "Applied \(transaction.displayName)."
    }

    private func ordinaryFocusGraph(_ game: GameCore) -> [ResourcePackScreenFocusID] {
        let base: [ResourcePackScreenFocusID] = BUNDLED_RESOURCE_PACK_BASE_STYLES.map {
            ResourcePackScreenFocusID.baseStyle($0.id)
        }
        let style = sanitizedBundledResourcePackBaseStyleID(game.settings.bundledResourcePackBaseStyle)
        let addOns: [ResourcePackScreenFocusID] = bundledResourcePackAddOnsAllowed(for: style)
            ? BUNDLED_RESOURCE_PACK_ADD_ONS.map { ResourcePackScreenFocusID.addOn($0.id) } : []
        return base + addOns + [.done]
    }

    private func recoveryNavigationGraph(_ game: GameCore) -> [ResourcePackScreenFocusID] {
        (game.settingsRecoveryTransientAcknowledged ? [] : [.acknowledge]) + [.done]
    }

    private func isSelectionControl(_ id: ResourcePackScreenFocusID) -> Bool {
        switch id {
        case .baseStyle, .addOn: return true
        case .acknowledge, .done: return false
        }
    }

    override func onKeyEvent(_ ui: UIManager, _ game: GameCore,
                             _ event: ElysiumKeyEvent) -> Bool {
        if event.isRepeat { return true }
        let key = event.terminal.rawValue
        switch applyState {
        case .awaitingPresentedFrame(let id):
            if key == "Escape" {
                ui.cancelAfterNextPresentedFrame()
                transaction = nil
                applyState = .idle
                ResourcePackCPUWorker.shared.cancel(transactionID: id)
                status = "Apply cancelled."
                publishState(ui, game, announcement: status)
            }
            return true
        case .preparing:
            return true
        case .idle:
            break
        }

        if game.settingsRecoveryRequired,
           isSelectionControl(focusedID),
           ["Enter", "NumpadEnter", "Space"].contains(key) { return true }

        let graph = game.settingsRecoveryRequired
            ? recoveryNavigationGraph(game) : ordinaryFocusGraph(game)
        if key == "Tab" {
            if game.settingsRecoveryRequired,
               isSelectionControl(focusedID) {
                focusedID = event.modifiers.contains(.shift) ? .done : (graph.first ?? .done)
            } else {
                let index = graph.firstIndex(of: focusedID) ?? 0
                focusedID = graph[(index + (event.modifiers.contains(.shift) ? graph.count - 1 : 1)) % graph.count]
            }
            publishState(ui, game)
            return true
        }
        if key == "ArrowUp" || key == "ArrowDown" {
            guard !game.settingsRecoveryRequired else { return true }
            let index = graph.firstIndex(of: focusedID) ?? 0
            focusedID = graph[(index + (key == "ArrowUp" ? graph.count - 1 : 1)) % graph.count]
            publishState(ui, game)
            return true
        }
        if ["Enter", "NumpadEnter", "Space"].contains(key) {
            activateFocused(ui, game)
            return true
        }
        if key == "Escape" {
            ui.closeTop(game)
            return true
        }
        return true
    }

    private func activateFocused(_ ui: UIManager, _ game: GameCore) {
        switch focusedID {
        case .baseStyle(let style): beginSelectBaseStyle(style, ui: ui, game: game)
        case .addOn(let id): beginToggle(id, ui: ui, game: game)
        case .acknowledge:
            game.acknowledgeSettingsRecoveryNotice()
            pendingAnnouncement = nil
            focusedID = .done
            publishState(ui, game)
        case .done: ui.closeTop(game)
        }
    }

    override func onMouseDown(_ ui: UIManager, _ game: GameCore,
                              _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        if btn == 0 {
            for (id, button) in controlsByFocusID
                where mx >= button.x && mx < button.x + button.w &&
                      my >= button.y && my < button.y + button.h {
                focusedID = id
                if !button.enabled { return true }
            }
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }

    override func textAccessibilityDescriptors(_ ui: UIManager, _ game: GameCore)
        -> [TextEntryAccessibilityDescriptor] {
        guard ui.current() === self else { return [] }
        let baseStyle = sanitizedBundledResourcePackBaseStyleID(game.settings.bundledResourcePackBaseStyle)
        let selected = Set(sanitizedBundledResourcePackAddOnIDs(
            game.settings.bundledResourcePackAddOns, for: baseStyle))
        let baseline = baselinePresentation()
        let currentStatus = statusPresentation(game)
        let staticWidth = max(1, ui.width - 4)
        var result: [TextEntryAccessibilityDescriptor] = [
            TextEntryAccessibilityDescriptor(
                id: "resource-pack.baseline", role: .staticText,
                label: "Visual style baseline", value: baseline.value, help: baseline.help,
                frame: (2, 42, staticWidth, 12), enabled: true, focused: false,
                insertionUTF16Offset: nil, focusable: false, actionable: false),
            TextEntryAccessibilityDescriptor(
                id: "resource-pack.status", role: .staticText,
                label: "Resource pack status", value: currentStatus.value,
                help: currentStatus.help,
                frame: (2, 56, staticWidth, currentStatus.recovery == nil ? 10 : 22),
                enabled: true, focused: false, insertionUTF16Offset: nil,
                focusable: false, actionable: false),
        ]
        for descriptor in BUNDLED_RESOURCE_PACK_BASE_STYLES {
            let id = ResourcePackScreenFocusID.baseStyle(descriptor.id)
            guard let button = controlsByFocusID[id] else { continue }
            let isSelected = descriptor.id == baseStyle
            let value = game.settingsRecoveryRequired
                ? "Current session: \(isSelected ? "selected" : "not selected"); saved choice unknown"
                : (isSelected ? "Selected" : "Not selected")
            let help = game.settingsRecoveryRequired
                ? "Restart Elysium before changing settings."
                : "\(descriptor.detail) Select this visual style."
            result.append(TextEntryAccessibilityDescriptor(
                id: "resource-pack.style.\(descriptor.id.rawValue)", role: .checkbox,
                label: descriptor.displayName, value: value, help: help,
                frame: (button.x, button.y, button.w, button.h), enabled: !game.settingsRecoveryRequired,
                focused: focusedID == id, insertionUTF16Offset: nil,
                focusable: !game.settingsRecoveryRequired, selected: isSelected,
                actionable: button.enabled))
        }
        for descriptor in BUNDLED_RESOURCE_PACK_ADD_ONS {
            let id = ResourcePackScreenFocusID.addOn(descriptor.id)
            guard let button = controlsByFocusID[id] else { continue }
            let isOn = selected.contains(descriptor.id)
            let value = game.settingsRecoveryRequired
                ? "Current session: \(isOn ? "ON" : "OFF"); saved choice unknown"
                : baseStyle != .faithful64x
                ? "Requires Faithful 64x"
                : (isOn ? "ON" : "OFF")
            let help = game.settingsRecoveryRequired
                ? "Restart Elysium before changing settings"
                : baseStyle != .faithful64x
                ? "This Faithful 64x add-on cannot be used with KUBIKOS Cubic World."
                : "Toggle \(descriptor.displayName)."
            result.append(TextEntryAccessibilityDescriptor(
                id: "resource-pack.\(descriptor.id.rawValue)", role: .checkbox,
                label: descriptor.displayName, value: value, help: help,
                frame: (button.x, button.y, button.w, button.h), enabled: button.enabled,
                focused: focusedID == id, insertionUTF16Offset: nil, focusable: button.enabled,
                selected: isOn, actionable: button.enabled))
        }
        for id in [ResourcePackScreenFocusID.acknowledge, .done] {
            guard let button = controlsByFocusID[id] else { continue }
            let stableID = id == .acknowledge ? "resource-pack.acknowledge" : "resource-pack.done"
            result.append(TextEntryAccessibilityDescriptor(
                id: stableID, role: .button, label: button.label, value: "",
                help: id == .acknowledge
                    ? "Dismiss the transient announcement; restart guidance remains."
                    : "Return to Video options.",
                frame: (button.x, button.y, button.w, button.h), enabled: button.enabled,
                focused: focusedID == id, insertionUTF16Offset: nil, focusable: button.enabled,
                actionable: button.enabled))
        }
        return result
    }

    override func focusTextAccessibilityElement(_ id: String, _ ui: UIManager,
                                                 _ game: GameCore) -> Bool {
        let focus: ResourcePackScreenFocusID?
        if id == "resource-pack.done" { focus = .done }
        else if id == "resource-pack.acknowledge" { focus = .acknowledge }
        else if let descriptor = BUNDLED_RESOURCE_PACK_BASE_STYLES.first(where: {
            id == "resource-pack.style.\($0.id.rawValue)"
        }) { focus = .baseStyle(descriptor.id) }
        else if let descriptor = BUNDLED_RESOURCE_PACK_ADD_ONS.first(where: {
            id == "resource-pack.\($0.id.rawValue)"
        }) { focus = .addOn(descriptor.id) }
        else { focus = nil }
        guard let focus, controlsByFocusID[focus] != nil else { return false }
        focusedID = focus
        return true
    }

    override func performTextAccessibilityAction(_ id: String, _ ui: UIManager,
                                                  _ game: GameCore) -> Bool {
        guard let descriptor = textAccessibilityDescriptors(ui, game).first(where: {
            $0.id == id && $0.enabled && $0.actionable
        }) else { return false }
        _ = descriptor
        guard focusTextAccessibilityElement(id, ui, game) else { return false }
        activateFocused(ui, game)
        return true
    }

    override func consumeTextAccessibilityStatusAnnouncement() -> String? {
        defer { pendingAnnouncement = nil }
        return pendingAnnouncement
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        game.hasWorld() ? ui.drawDarkBg(0.7) : ui.drawDirtBg()
        ui.cv.drawTextCentered("Resource Packs", ui.width / 2, 16, 1.25)
        let baseline = baselinePresentation()
        let currentStatus = statusPresentation(game)
        ui.cv.drawTextCentered(baseline.canvas, ui.width / 2, 46, 0.9, "#f4e7a2")
        ui.cv.drawTextCentered(currentStatus.canvas, ui.width / 2, 58, 0.75,
                               currentStatus.canvas.hasPrefix("Could not")
                                   ? "#ffaaaa" : "#dddddd")
        if let recovery = currentStatus.recovery {
            ui.cv.drawTextCentered(recovery, ui.width / 2, 68, 0.75, "#ffaaaa")
        }
        ui.drawButtons(self)
        if let button = controlsByFocusID[focusedID] {
            let light = game.settings.highContrast ? "#ffff00" : "#ffffff"
            ui.cv.setStroke("#000000")
            ui.cv.strokeRect(button.x + 1, button.y + 1, button.w - 2, button.h - 2)
            ui.cv.setStroke(light)
            ui.cv.strokeRect(button.x + 2, button.y + 2, button.w - 4, button.h - 4)
        }
    }
}
