import Foundation
import GameController
import QuartzCore
import ElysiumCore

/// Physical controller support is scoped to RPG menus and actions plus the explicit
/// villager barter sheet. It does not route movement, camera, inventory, or
/// crafting input.
@MainActor
final class RPGControllerAdapter {
    private weak var app: AppDelegate?
    private var observers: [NSObjectProtocol] = []
    private var controllers: [ObjectIdentifier: GCController] = [:]
    private var input = RPGControllerInput()
    private var gate = RPGControllerGenerationGate()
    private var context: RPGControllerContext = .inactive
    private var focused = false
    private var started = false

    init(app: AppDelegate) {
        self.app = app
    }

    func start() {
        guard !started else { return }
        started = true
        focused = NSApp.isActive
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: .GCControllerDidConnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.connect(controller) }
        })
        observers.append(center.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.disconnect(controller) }
        })
        for controller in GCController.controllers() { connect(controller) }
        synchronizeContext()
    }

    func stop() {
        guard started else { return }
        removeEveryHandler()
        input.resetForLifecycleBoundary()
        gate.disconnectOrReplace()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        controllers.removeAll()
        started = false
    }

    func applicationDidResignActive() {
        guard focused else { return }
        focused = false
        lifecycleBoundary(advanceContext: true, reinstall: false, resetHelp: true)
    }

    func applicationDidBecomeActive() {
        guard !focused else { return }
        focused = true
        synchronizeContext(forceBoundary: true)
    }

    func synchronizeContext() {
        synchronizeContext(forceBoundary: false)
    }

    /// UI stack identity changed even when the coarse context remains `.sheet`; invalidate every
    /// callback and repeat edge rather than treating a replacement RPG screen as the same owner.
    func screenContextDidChange() {
        synchronizeContext(forceBoundary: true)
    }

    private func synchronizeContext(forceBoundary: Bool) {
        guard started else { return }
        let desired = desiredContext()
        guard forceBoundary || desired != context else {
            dispatch(input.updateHeldRepeat(
                timestampMilliseconds: Self.monotonicMilliseconds()))
            return
        }
        context = desired
        lifecycleBoundary(advanceContext: true, reinstall: focused, resetHelp: false)
    }

    private func desiredContext() -> RPGControllerContext {
        guard focused, let app, app.game.hasWorld() else { return .inactive }
        if app.ui.current() is RPGCharacterScreen || app.ui.current() is TradingScreen { return .sheet }
        return app.ui.hasScreen() ? .inactive : .world
    }

    private func connect(_ controller: GCController) {
        guard started, controller.extendedGamepad != nil else { return }
        let objectID = ObjectIdentifier(controller)
        guard controllers[objectID] == nil else { return }
        controllers[objectID] = controller
        // Retain the complete compatible inventory, then invalidate every closure and held/repeat
        // edge from the prior adapter generation. All controllers must sample neutral again.
        lifecycleBoundary(advanceContext: false, reinstall: focused, resetHelp: true)
    }

    private func disconnect(_ controller: GCController) {
        let objectID = ObjectIdentifier(controller)
        guard controllers[objectID] === controller else { return }
        // Handler removal and held-state clearing precede the checked adapter generation advance.
        removeEveryHandler()
        input.resetForLifecycleBoundary()
        gate.disconnectOrReplace()
        controllers.removeValue(forKey: objectID)
        app.map { $0.ui.setRPGControllerHelpPrimary(false, game: $0.game) }
        if focused { installEveryHandler() }
    }

    private func lifecycleBoundary(advanceContext: Bool, reinstall: Bool, resetHelp: Bool) {
        // The order is security-significant: old closures lose ownership before generation changes.
        removeEveryHandler()
        input.resetForLifecycleBoundary()
        if advanceContext { gate.contextBoundary() } else { gate.disconnectOrReplace() }
        if resetHelp, let app { app.ui.setRPGControllerHelpPrimary(false, game: app.game) }
        if reinstall { installEveryHandler() }
    }

    private func replaceActiveController(with controller: GCController,
                                         controllerID: String) {
        removeEveryHandler()
        input.resetForLifecycleBoundary()
        gate.disconnectOrReplace()
        gate.noteNeutral(controllerID: controllerID)
        _ = gate.claimAfterInput(controllerID: controllerID)
        app.map { $0.ui.setRPGControllerHelpPrimary(false, game: $0.game) }
        installEveryHandler()
        // The edge which caused replacement is intentionally not replayed under the new generation.
        seedReducerFromPhysical(controller)
    }

    private func installEveryHandler() {
        for controller in controllers.values { installHandler(on: controller) }
    }

    private func installHandler(on controller: GCController) {
        guard let gamepad = controller.extendedGamepad,
              let identity = callbackIdentity(for: controller) else { return }
        let objectID = ObjectIdentifier(controller)
        gamepad.valueChangedHandler = { [weak self, weak controller] _, _ in
            DispatchQueue.main.async {
                guard let self, let controller,
                      let currentGamepad = controller.extendedGamepad else { return }
                self.receive(Self.normalizedValues(currentGamepad),
                             controller: controller, objectID: objectID,
                             callbackIdentity: identity)
            }
        }
        let values = Self.normalizedValues(gamepad)
        if RPGControllerInput.callbackIsNeutral(values) {
            gate.noteNeutral(controllerID: identity.controllerID)
        }
    }

    private func removeEveryHandler() {
        for controller in controllers.values {
            controller.extendedGamepad?.valueChangedHandler = nil
        }
    }

    private func callbackIdentity(for controller: GCController) -> RPGControllerCallbackIdentity? {
        RPGControllerCallbackIdentity(
            controllerID: Self.controllerID(controller),
            adapterGeneration: gate.adapterGeneration,
            contextGeneration: gate.contextGeneration)
    }

    private func receive(_ values: [RPGControllerSample],
                         controller: GCController, objectID: ObjectIdentifier,
                         callbackIdentity: RPGControllerCallbackIdentity) {
        guard started, focused, context != .inactive,
              controllers[objectID] === controller,
              callbackIdentity.controllerID == Self.controllerID(controller),
              gate.acceptsCallback(callbackIdentity) else { return }

        if RPGControllerInput.callbackIsNeutral(values) {
            gate.noteNeutral(controllerID: callbackIdentity.controllerID)
        }

        if let active = gate.activeControllerID, active != callbackIdentity.controllerID {
            guard gate.isNeutralEligible(controllerID: callbackIdentity.controllerID),
                  RPGControllerInput.callbackHasEnteredInput(values) else { return }
            replaceActiveController(with: controller, controllerID: callbackIdentity.controllerID)
            return
        }

        if gate.activeControllerID == nil {
            guard RPGControllerInput.callbackHasEnteredInput(values),
                  gate.claimAfterInput(controllerID: callbackIdentity.controllerID) != nil else { return }
            armReducerFromNeutral()
        } else {
            guard let activeIdentity = gate.currentIdentity, gate.accepts(activeIdentity),
                  activeIdentity.controllerID == callbackIdentity.controllerID else { return }
        }

        let commands = input.updateCallback(
            values, timestampMilliseconds: Self.monotonicMilliseconds())
        dispatch(commands)
    }

    private func armReducerFromNeutral() {
        input.resetForLifecycleBoundary()
        for control in RPGControllerControl.allCases {
            _ = input.update(control: control, value: 0, timestampMilliseconds: 0)
        }
        input.transition(to: context)
    }

    private func seedReducerFromPhysical(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        input.resetForLifecycleBoundary()
        for sample in Self.normalizedValues(gamepad) {
            _ = input.update(control: sample.control, value: sample.value,
                             timestampMilliseconds: 0)
        }
        input.transition(to: context)
    }

    private func dispatch(_ commands: [RPGSemanticCommand]) {
        guard let app else { return }
        for command in commands {
            let accepted: Bool
            switch context {
            case .sheet:
                if let screen = app.ui.current() as? RPGCharacterScreen {
                    accepted = screen.handleRPGControllerCommand(command, ui: app.ui, game: app.game)
                } else if let screen = app.ui.current() as? TradingScreen {
                    accepted = screen.handleControllerCommand(command, ui: app.ui, game: app.game)
                } else {
                    accepted = false
                }
            case .world:
                let result = app.ui.dispatchRPGWorldSemanticCommand(
                    command, source: .controller, game: app.game)
                if case .dispatched = result { accepted = true } else { accepted = false }
            case .inactive:
                accepted = false
            }
            if accepted { app.ui.setRPGControllerHelpPrimary(true, game: app.game) }
        }
    }

    private static func controllerID(_ controller: GCController) -> String {
        String(describing: ObjectIdentifier(controller))
    }

    private static func monotonicMilliseconds() -> UInt64 {
        let value = CACurrentMediaTime() * 1_000
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(UInt64.max) ? UInt64.max : UInt64(value.rounded(.down))
    }

    private static func normalizedValues(
        _ gamepad: GCExtendedGamepad
    ) -> [RPGControllerSample] {
        func directions(x: Float, y: Float,
                        up: RPGControllerControl, right: RPGControllerControl,
                        down: RPGControllerControl, left: RPGControllerControl)
            -> [RPGControllerSample] {
            [RPGControllerSample(control: up, value: Double(max(0, y))),
             RPGControllerSample(control: right, value: Double(max(0, x))),
             RPGControllerSample(control: down, value: Double(max(0, -y))),
             RPGControllerSample(control: left, value: Double(max(0, -x)))]
        }
        var result: [RPGControllerSample] = [
            RPGControllerSample(control: .leftTrigger,
                                value: Double(gamepad.leftTrigger.value)),
        ]
        result += directions(x: gamepad.dpad.xAxis.value, y: gamepad.dpad.yAxis.value,
                             up: .dpadUp, right: .dpadRight,
                             down: .dpadDown, left: .dpadLeft)
        result += directions(x: gamepad.leftThumbstick.xAxis.value,
                             y: gamepad.leftThumbstick.yAxis.value,
                             up: .leftStickUp, right: .leftStickRight,
                             down: .leftStickDown, left: .leftStickLeft)
        result += [
            RPGControllerSample(control: .rightStickUp,
                value: Double(max(0, gamepad.rightThumbstick.yAxis.value))),
            RPGControllerSample(control: .rightStickDown,
                value: Double(max(0, -gamepad.rightThumbstick.yAxis.value))),
            RPGControllerSample(control: .rightStickClick,
                value: Double(gamepad.rightThumbstickButton?.value ?? 0)),
            RPGControllerSample(control: .buttonA, value: Double(gamepad.buttonA.value)),
            RPGControllerSample(control: .buttonB, value: Double(gamepad.buttonB.value)),
            RPGControllerSample(control: .buttonX, value: Double(gamepad.buttonX.value)),
            RPGControllerSample(control: .buttonY, value: Double(gamepad.buttonY.value)),
            RPGControllerSample(control: .leftShoulder,
                                value: Double(gamepad.leftShoulder.value)),
            RPGControllerSample(control: .rightShoulder,
                                value: Double(gamepad.rightShoulder.value)),
            RPGControllerSample(control: .options,
                value: Double(gamepad.buttonOptions?.value ?? gamepad.buttonMenu.value)),
        ]
        return result
    }
}
