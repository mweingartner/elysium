import AppKit
import QuartzCore
import ElysiumCore
import ElysiumTextInput
import ElysiumAppSupport

/// The sole `NSEvent` adapter for keyboard ingress. AppKit's two down-event callbacks share one
/// pure router and fingerprint ledger, so a physical event can dispatch at most once.
@MainActor
final class AppInputRouter {
    private unowned let view: GameView
    private var router = RPGPureInputRouter()
    private var configuredBindingPresses = ElysiumConfiguredBindingPressLedger()
    private var modifierSynthesizer = ElysiumModifierEdgeSynthesizer()
    private var nextPhysicalRoutingSerial: UInt64 = 0
    private var routingSerialExhausted = false
    private let exhaustionLatch = ElysiumAppInputExhaustionLatch()
    private var handledEquivalents: [HandledEquivalent] = []

    private struct HandledEquivalent {
        let event: NSEvent
        let keyCode: UInt16
        let timestamp: TimeInterval
        let windowNumber: Int
        let modifierFlags: NSEvent.ModifierFlags
        let isRepeat: Bool
        let insertedAt: TimeInterval
    }

    init(view: GameView) {
        self.view = view
    }

    func route(event: NSEvent, source: AppKeyEventSource) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        expireHandledEquivalents(now: now)
        let isProtectedEquivalent = source == .performKeyEquivalent && (
            (view.ui?.current() as? SettingsScreen)?.hasActiveControlsCapture == true ||
                KEYCODE_MAP[event.keyCode] == "F11")
        if let exhausted = exhaustionLatch.disposition(
            source: source == .keyDown ? .keyDown : .performKeyEquivalent,
            protectedEquivalent: isProtectedEquivalent) {
            return exhausted == .consume
        }
        if source == .performKeyEquivalent {
            guard isProtectedEquivalent else { return false }
        } else if source == .keyDown, consumeHandledEquivalent(event, now: now) {
            return true
        }
        guard let routed = makePhysicalEvent(event) else {
            if routingSerialExhausted { return source == .keyDown }
            return source == .keyDown ? routeUnmappedScreenText(event) : false
        }
        let handled = route(routed.event, fingerprint: routed.fingerprint,
                            nowMilliseconds: routed.nowMilliseconds, appKitEvent: event)
        if handled, source == .performKeyEquivalent {
            rememberHandledEquivalent(event, now: now)
        }
        return handled
    }

    private func safeFieldsMatch(_ marker: HandledEquivalent, _ event: NSEvent) -> Bool {
        marker.keyCode == event.keyCode && marker.timestamp == event.timestamp &&
            marker.windowNumber == event.windowNumber &&
            marker.modifierFlags == event.modifierFlags.intersection(.deviceIndependentFlagsMask) &&
            marker.isRepeat == event.isARepeat
    }

    private func consumeHandledEquivalent(_ event: NSEvent, now: TimeInterval) -> Bool {
        guard let index = handledEquivalents.firstIndex(where: {
            $0.event === event && safeFieldsMatch($0, event)
        }) else { return false }
        handledEquivalents.remove(at: index)
        return true
    }

    private func rememberHandledEquivalent(_ event: NSEvent, now: TimeInterval) {
        handledEquivalents.append(HandledEquivalent(
            event: event, keyCode: event.keyCode, timestamp: event.timestamp,
            windowNumber: event.windowNumber,
            modifierFlags: event.modifierFlags.intersection(.deviceIndependentFlagsMask),
            isRepeat: event.isARepeat, insertedAt: now))
        if handledEquivalents.count > 16 {
            handledEquivalents.removeFirst(handledEquivalents.count - 16)
        }
    }

    private func expireHandledEquivalents(now: TimeInterval) {
        handledEquivalents.removeAll { now >= $0.insertedAt && now - $0.insertedAt >= 0.250 }
    }

    private func routeUnmappedScreenText(_ event: NSEvent) -> Bool {
        guard let game = view.game, let ui = view.ui, let screen = ui.current() else { return false }
        let result = ElysiumTextEventIngressAdapter.route(
            proposal: event.characters,
            commandOrControl: event.modifierFlags.contains(.command) ||
                event.modifierFlags.contains(.control),
            ingressBlocked: { ui.textIngressMustBeConsumed(for: screen, game: game) },
            dispatch: { screen.insertText(ui, game, $0) })
        if result == .dispatched(accepted: true) {
            ui.notifyTextAccessibilityValueChanged(on: screen, game: game)
        }
        return true
    }

    func flagsChanged(with event: NSEvent) {
        guard let game = view.game, let ui = view.ui else { return }
        let modifiers = Self.modifiers(from: event.modifierFlags)
        ui.optionDown = modifiers.contains(.option)
        ui.shiftDown = modifiers.contains(.shift)

        // Exhaustion still records the current bounded modifier mask so UI state does not stick,
        // but it cannot release gameplay bindings or synthesize/dispatch an edge.
        guard exhaustionLatch.recordFlagsChanged(
            mask: UInt64(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)) else {
            return
        }

        if !modifiers.contains(.shift),
           let terminal = ElysiumTerminalKey(rawValue: "ShiftLeft") {
            release(terminal: terminal, fallbackCode: "ShiftLeft", game: game)
        }
        if !modifiers.contains(.control),
           let terminal = ElysiumTerminalKey(rawValue: "ControlLeft") {
            release(terminal: terminal, fallbackCode: "ControlLeft", game: game)
        }

        let edges = modifierSynthesizer.update(modifiers)
        guard !ui.hasScreen() else { return }
        for edge in edges {
            let syntheticCode: UInt16 = edge.terminal.rawValue == "ShiftLeft" ? 56 : 59
            let fingerprint = AppKeyEventFingerprint(
                eventNumber: 0, keyCode: syntheticCode,
                timestampMicroseconds: Self.timestampMicroseconds(event.timestamp),
                windowNumber: Int32(clamping: event.windowNumber), modifiers: edge.modifiers,
                isRepeat: false, origin: .synthesizedLegacy)
            _ = route(edge, fingerprint: fingerprint,
                      nowMilliseconds: Self.monotonicMilliseconds(event.timestamp), appKitEvent: nil)
        }
    }

    func release(event: NSEvent) {
        guard exhaustionLatch.mayDispatchRelease(),
              let game = view.game, let code = KEYCODE_MAP[event.keyCode],
              let terminal = ElysiumTerminalKey(rawValue: code) else { return }
        release(terminal: terminal, fallbackCode: code, game: game)
    }

    private func release(terminal: ElysiumTerminalKey, fallbackCode: String, game: GameCore) {
        if let press = configuredBindingPresses.release(terminal: terminal) {
            game.keyUp(binding: press.action, configuredCode: press.executedCode)
        } else {
            game.keyUp(fallbackCode)
        }
    }

    func resetPressedBindings() {
        // This MainActor method is the input-session boundary. Retire every identity from the old
        // session before either serial zero or the exhaustion latch can be reused.
        router = RPGPureInputRouter()
        handledEquivalents.removeAll(keepingCapacity: false)
        nextPhysicalRoutingSerial = 0
        routingSerialExhausted = false
        exhaustionLatch.resetInputSession()
        configuredBindingPresses.removeAll()
        modifierSynthesizer = ElysiumModifierEdgeSynthesizer()
    }

    private func makePhysicalEvent(_ event: NSEvent)
        -> (event: ElysiumKeyEvent, fingerprint: AppKeyEventFingerprint, nowMilliseconds: UInt64)? {
        guard !routingSerialExhausted,
              let terminalName = KEYCODE_MAP[event.keyCode],
              let terminal = ElysiumTerminalKey(rawValue: terminalName) else { return nil }
        let addition = nextPhysicalRoutingSerial.addingReportingOverflow(1)
        guard !addition.overflow, addition.partialValue != 0 else {
            routingSerialExhausted = true
            exhaustionLatch.exhaust()
            handledEquivalents.removeAll(keepingCapacity: false)
            return nil
        }
        nextPhysicalRoutingSerial = addition.partialValue
        let modifiers = Self.modifiers(from: event.modifierFlags)
        let keyEvent = ElysiumKeyEvent(terminal: terminal, modifiers: modifiers,
                                      isRepeat: event.isARepeat, origin: .physical,
                                      routingSerial: addition.partialValue)
        let fingerprint = AppKeyEventFingerprint(
            eventNumber: 0, keyCode: event.keyCode,
            timestampMicroseconds: Self.timestampMicroseconds(event.timestamp),
            windowNumber: Int32(clamping: event.windowNumber), modifiers: modifiers,
            isRepeat: event.isARepeat, origin: .physical)
        return (keyEvent, fingerprint, Self.monotonicMilliseconds(event.timestamp))
    }

    private func route(_ event: ElysiumKeyEvent, fingerprint: AppKeyEventFingerprint,
                       nowMilliseconds: UInt64, appKitEvent: NSEvent?) -> Bool {
        guard let game = view.game, let ui = view.ui else { return false }
        let screenPresent = ui.hasScreen()
        // Binding capture owns the next structured event before global/menu/protected routing.
        // This prevents F11 or a shipping menu chord from escaping while it is being rejected.
        if let settings = ui.current() as? SettingsScreen,
           settings.hasActiveControlsCapture {
            _ = settings.handleControlsKeyEvent(event, ui: ui, game: game)
            router.rememberConsumed(event)
            return true
        }
        let appShortcut = eligibleObjectTemplateCommand(event, game: game, ui: ui)
        let independent = independentCommand(event, hasWorld: game.hasWorld())
        let contexts: Set<ElysiumBindingContext> = game.hasWorld()
            ? [.appHUD, .rpgWorldAction, .hotbar, .movement] : []
        let disposition = router.route(
            event: event, fingerprint: fingerprint, nowMilliseconds: nowMilliseconds,
            eligibleAppShortcutCommand: appShortcut, screenPresent: screenPresent,
            independentCommand: independent, allowedContexts: contexts, bindings: game.keybinds)

        switch disposition {
        case .globalFullscreen:
            view.window?.toggleFullScreen(nil)
            return true
        case .resolved(let command):
            dispatch(command, event: event, game: game, ui: ui)
            return true
        case .consumedRepeat, .consumedDuplicate:
            return true
        case .routeToScreen:
            return routeToScreen(event, appKitEvent: appKitEvent, fingerprint: fingerprint,
                                 nowMilliseconds: nowMilliseconds, game: game, ui: ui)
        case .unhandledForMainMenu, .unhandledProtected, .unhandled:
            return false
        }
    }

    private func routeToScreen(_ event: ElysiumKeyEvent, appKitEvent: NSEvent?,
                               fingerprint: AppKeyEventFingerprint, nowMilliseconds: UInt64,
                               game: GameCore, ui: UIManager) -> Bool {
        guard let screen = ui.current() else { return false }
        if ui.textIngressMustBeConsumed(for: screen, game: game) {
            router.rememberConsumed(event)
            return true
        }
        let code = event.terminal.rawValue
        if let settings = screen as? SettingsScreen,
           settings.handleControlsKeyEvent(event, ui: ui, game: game) {
            router.rememberConsumed(event)
            return true
        }
        if screen.onKeyEvent(ui, game, event) {
            router.rememberConsumed(event)
            ui.notifyTextAccessibilityValueChanged(on: screen, game: game)
            view.recaptureIfClear()
            return true
        }
        let typed = ElysiumTextEventIngressAdapter.route(
            proposal: appKitEvent?.characters,
            commandOrControl: event.modifiers.contains(.command) ||
                event.modifiers.contains(.control),
            ingressBlocked: { ui.textIngressMustBeConsumed(for: screen, game: game) },
            dispatch: { screen.insertText(ui, game, $0) })
        if typed == .dispatched(accepted: true) {
            router.rememberConsumed(event)
            ui.notifyTextAccessibilityValueChanged(on: screen, game: game)
            return true
        }
        if !event.isRepeat, code == "Escape", screen.closeOnEsc {
            ui.closeTop(game)
            view.recaptureIfClear()
            router.rememberConsumed(event)
            return true
        }
        if !event.isRepeat,
           resolveKeyCommand(event: event, allowedContexts: [.appHUD], bindings: game.keybinds)
                == .binding(.inventory),
           screen.closeOnEsc, !(screen is ChatScreen),
           !screen.fields.contains(where: { $0.focused }) {
            ui.closeTop(game)
            view.recaptureIfClear()
            router.rememberConsumed(event)
            return true
        }
        // An open screen is exclusive even when it declines a key: world movement, hotbar, RPG,
        // and AppKit responder actions never fall through behind it.
        router.rememberConsumed(event)
        return true
    }

    private func eligibleObjectTemplateCommand(_ event: ElysiumKeyEvent, game: GameCore,
                                                ui: UIManager) -> ResolvedKeyCommand? {
        guard let action = objectTemplateShortcutAction(
            forKey: event.terminal.rawValue, commandDown: event.modifiers.contains(.command),
            hasOpenScreen: ui.hasScreen(), hasWorld: game.hasWorld(), isRepeat: event.isRepeat)
        else { return nil }
        switch action {
        case .copyObject: return .worldAction("copyObjectTemplate")
        case .placeObject: return .worldAction("placeObjectTemplate")
        case .undoObjectPlacement: return .worldAction("undoObjectPlacement")
        }
    }

    private func independentCommand(_ event: ElysiumKeyEvent, hasWorld: Bool) -> ResolvedKeyCommand? {
        guard hasWorld else { return nil }
        if let dropAll = resolveLegacyControlDropAll(event: event,
                                                     bindings: view.game?.keybinds ?? [:]) {
            return dropAll
        }
        guard event.modifiers.isEmpty else { return nil }
        switch event.terminal.rawValue {
        case "Escape": return .worldAction("pause")
        case "Comma": return .worldAction("mapZoomOut")
        case "Period": return .worldAction("mapZoomIn")
        case "F1": return .worldAction("toggleHUD")
        case "F3": return .worldAction("toggleDebugHUD")
        case "Minus", "NumpadSubtract": return .worldAction("minimapSmaller")
        case "Equal", "NumpadEqual": return .worldAction("minimapLarger")
        case "KeyM": return .worldAction("openMap")
        default:
            if event.terminal.rawValue.hasPrefix("Digit"),
               let value = Int(event.terminal.rawValue.dropFirst(5)), (1...9).contains(value) {
                return .worldAction("hotbar:\(value - 1)")
            }
            return nil
        }
    }

    private func dispatch(_ command: ResolvedKeyCommand, event: ElysiumKeyEvent,
                          game: GameCore, ui: UIManager) {
        switch command {
        case .binding(let action):
            guard let press = configuredBindingPresses.press(
                action: action, event: event, bindings: game.keybinds)
            else { return }
            game.keyDown(binding: press.action, configuredCode: press.executedCode,
                         now: view.nowMs())
        case .worldAction(let action):
            switch action {
            case "copyObjectTemplate": _ = view.performObjectTemplateShortcut(.copyObject)
            case "placeObjectTemplate": _ = view.performObjectTemplateShortcut(.placeObject)
            case "undoObjectPlacement": _ = view.performObjectTemplateShortcut(.undoObjectPlacement)
            case "pause":
                game.keyDown("Escape", now: view.nowMs())
            case "mapZoomOut": game.zoomMap(false)
            case "mapZoomIn": game.zoomMap(true)
            case "toggleHUD": view.appd?.hud.hideGui.toggle()
            case "toggleDebugHUD": view.appd?.hud.debugVisible.toggle()
            case "minimapSmaller": game.cycleMinimapSize(larger: false)
            case "minimapLarger": game.cycleMinimapSize(larger: true)
            case "openMap": game.openScreen("map", nil)
            case "dropAll":
                game.keyDown(event.terminal.rawValue, now: view.nowMs(), ctrlOrCmd: true)
            default:
                if action.hasPrefix("hotbar:"), let slot = Int(action.dropFirst(7)),
                   (0..<9).contains(slot) {
                    game.player?.selectedSlot = slot
                } else {
                    game.keyDown(event.terminal.rawValue, now: view.nowMs(),
                                 ctrlOrCmd: event.modifiers.contains(.command) ||
                                     event.modifiers.contains(.control))
                }
            }
        case .semantic(let semantic):
            dispatchWorldSemantic(semantic, game: game, ui: ui)
        }
    }

    private func dispatchWorldSemantic(_ command: RPGSemanticCommand, game: GameCore, ui: UIManager) {
        _ = ui.dispatchRPGWorldSemanticCommand(command, source: .keyboard, game: game)
    }

    private static func modifiers(from flags: NSEvent.ModifierFlags) -> ElysiumKeyModifiers {
        var value: ElysiumKeyModifiers = []
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { value.insert(.command) }
        if flags.contains(.control) { value.insert(.control) }
        if flags.contains(.option) { value.insert(.option) }
        if flags.contains(.shift) { value.insert(.shift) }
        return value
    }

    private static func timestampMicroseconds(_ timestamp: TimeInterval) -> UInt64 {
        guard timestamp.isFinite, timestamp > 0 else { return 0 }
        let scaled = (timestamp * 1_000_000).rounded()
        return scaled >= Double(UInt64.max) ? UInt64.max : UInt64(scaled)
    }

    private static func monotonicMilliseconds(_ timestamp: TimeInterval) -> UInt64 {
        guard timestamp.isFinite, timestamp > 0 else {
            return UInt64(max(0, CACurrentMediaTime() * 1_000))
        }
        let scaled = (timestamp * 1_000).rounded(.down)
        return scaled >= Double(UInt64.max) ? UInt64.max : UInt64(scaled)
    }
}
