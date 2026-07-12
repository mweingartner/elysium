import Foundation

public enum RPGControllerContext: String, Codable { case inactive, sheet, world }

public enum RPGControllerControl: String, CaseIterable, Codable, Hashable {
    case dpadUp, dpadRight, dpadDown, dpadLeft
    case leftStickUp, leftStickRight, leftStickDown, leftStickLeft
    case rightStickUp, rightStickDown, rightStickClick
    case buttonA, buttonB, buttonX, buttonY
    case leftShoulder, rightShoulder, leftTrigger, options
}

public struct RPGControllerSample: Equatable {
    public let control: RPGControllerControl
    public let value: Double

    public init(control: RPGControllerControl, value: Double) {
        self.control = control
        self.value = value
    }
}

public struct RPGControllerInput: Equatable {
    public static let navigationEnter = 0.60
    public static let navigationExit = 0.35
    public static let triggerEnter = 0.65
    public static let triggerExit = 0.45
    public static let repeatDelayMilliseconds: UInt64 = 300
    public static let repeatIntervalMilliseconds: UInt64 = 90
    public static let maximumRepeatsPerUpdate = 8

    public private(set) var context: RPGControllerContext = .inactive
    private var values: [RPGControllerControl: Double] = [:]
    private var armed: Set<RPGControllerControl> = []
    private var rightStickDirection: RPGControllerControl?
    private var nextRepeatAt: UInt64?

    public init() {}

    public mutating func transition(to newContext: RPGControllerContext) {
        context = newContext
        armed = Set(values.compactMap { control, value in
            abs(value) <= Self.exitThreshold(for: control) ? control : nil
        })
        rightStickDirection = nil
        nextRepeatAt = nil
    }

    public mutating func resetForLifecycleBoundary() {
        context = .inactive
        values.removeAll(keepingCapacity: true)
        armed.removeAll(keepingCapacity: true)
        rightStickDirection = nil
        nextRepeatAt = nil
    }

    public mutating func update(control: RPGControllerControl, value rawValue: Double,
                                timestampMilliseconds now: UInt64) -> [RPGSemanticCommand] {
        guard rawValue.isFinite else { return [] }
        let value = min(1, max(0, abs(rawValue)))
        let wasPressed = (values[control] ?? 0) >= Self.enterThreshold(for: control)
        values[control] = value
        if value <= Self.exitThreshold(for: control) {
            armed.insert(control)
            if control == rightStickDirection {
                rightStickDirection = nil
                nextRepeatAt = nil
            }
            return []
        }
        guard context != .inactive else { return [] }
        if control == .rightStickUp || control == .rightStickDown {
            return updateScroll(control: control, pressed: value >= Self.navigationEnter,
                                wasPressed: wasPressed, now: now)
        }
        guard value >= Self.enterThreshold(for: control), !wasPressed, armed.contains(control) else { return [] }
        armed.remove(control)
        return commandForEdge(control).map { [$0] } ?? []
    }

    /// Reduces one physical framework callback. State for every sampled control is retained, while
    /// a callback can emit only one edge command or the bounded right-stick scroll catch-up batch.
    public mutating func updateCallback(_ samples: [RPGControllerSample],
                                        timestampMilliseconds now: UInt64)
        -> [RPGSemanticCommand] {
        var commands: [RPGSemanticCommand] = []
        for sample in samples {
            let emitted = update(control: sample.control, value: sample.value,
                                 timestampMilliseconds: now)
            guard !emitted.isEmpty else { continue }
            let scrolling = emitted.allSatisfy { command in
                if case .scrollRows = command { return true }
                return false
            }
            if commands.isEmpty, scrolling {
                commands = Array(emitted.prefix(Self.maximumRepeatsPerUpdate))
            } else if commands.isEmpty, let first = emitted.first {
                commands = [first]
            }
        }
        return commands
    }

    /// Advances only an already-held right-stick scroll repeat. Initial edges and every world
    /// mutation remain callback-driven; a frame tick cannot manufacture a new press.
    public mutating func updateHeldRepeat(timestampMilliseconds now: UInt64)
        -> [RPGSemanticCommand] {
        guard let control = rightStickDirection else { return [] }
        return updateScroll(control: control, pressed: true, wasPressed: true, now: now)
    }

    public static func callbackIsNeutral(_ samples: [RPGControllerSample]) -> Bool {
        samples.allSatisfy { sample in
            sample.value.isFinite && abs(sample.value) <= exitThreshold(for: sample.control)
        }
    }

    public static func callbackHasEnteredInput(_ samples: [RPGControllerSample]) -> Bool {
        samples.contains { sample in
            sample.value.isFinite && abs(sample.value) >= enterThreshold(for: sample.control)
        }
    }

    private mutating func updateScroll(control: RPGControllerControl, pressed: Bool,
                                       wasPressed: Bool, now: UInt64) -> [RPGSemanticCommand] {
        guard context == .sheet, pressed else { return [] }
        let rows = control == .rightStickUp ? -1 : 1
        if !wasPressed && armed.contains(control) {
            armed.remove(control)
            rightStickDirection = control
            nextRepeatAt = now.addingReportingOverflow(Self.repeatDelayMilliseconds).overflow
                ? UInt64.max : now + Self.repeatDelayMilliseconds
            return [.scrollRows(rows)]
        }
        guard rightStickDirection == control, var deadline = nextRepeatAt, now >= deadline else { return [] }
        var commands: [RPGSemanticCommand] = []
        while now >= deadline && commands.count < Self.maximumRepeatsPerUpdate {
            commands.append(.scrollRows(rows))
            let addition = deadline.addingReportingOverflow(Self.repeatIntervalMilliseconds)
            deadline = addition.overflow ? UInt64.max : addition.partialValue
        }
        nextRepeatAt = deadline
        return commands
    }

    private func commandForEdge(_ control: RPGControllerControl) -> RPGSemanticCommand? {
        switch context {
        case .inactive:
            return nil
        case .sheet:
            switch control {
            case .dpadUp, .leftStickUp: return .moveFocus(.up)
            case .dpadRight, .leftStickRight: return .moveFocus(.right)
            case .dpadDown, .leftStickDown: return .moveFocus(.down)
            case .dpadLeft, .leftStickLeft: return .moveFocus(.left)
            case .buttonA: return .activate
            case .buttonB: return .back
            case .leftShoulder: return .previousTab
            case .rightShoulder: return .nextTab
            default: return nil
            }
        case .world:
            if triggerHeld {
                switch control {
                case .dpadUp: return .useQuickSlot(0)
                case .dpadRight: return .useQuickSlot(1)
                case .dpadDown: return .useQuickSlot(2)
                case .dpadLeft: return .useQuickSlot(3)
                case .buttonY: return .useQuickSlot(4)
                case .buttonB: return .useQuickSlot(5)
                case .buttonA: return .useQuickSlot(6)
                case .buttonX: return .useQuickSlot(7)
                case .rightStickClick: return .useQuickSlot(8)
                default: break
                }
            }
            switch control {
            case .options: return .openCharacter
            case .leftShoulder: return .cyclePreparedAction
            case .rightShoulder: return .useSelectedAction
            default: return nil
            }
        }
    }

    private var triggerHeld: Bool {
        (values[.leftTrigger] ?? 0) > Self.triggerExit && !armed.contains(.leftTrigger)
    }

    private static func enterThreshold(for control: RPGControllerControl) -> Double {
        switch control {
        case .leftTrigger: return triggerEnter
        case .dpadUp, .dpadRight, .dpadDown, .dpadLeft,
             .leftStickUp, .leftStickRight, .leftStickDown, .leftStickLeft,
             .rightStickUp, .rightStickDown: return navigationEnter
        default: return 0.60
        }
    }

    private static func exitThreshold(for control: RPGControllerControl) -> Double {
        control == .leftTrigger ? triggerExit : navigationExit
    }
}

public struct RPGControllerCallbackIdentity: Equatable, Hashable {
    public let controllerID: String
    public let adapterGeneration: UInt64
    public let contextGeneration: UInt64

    public init?(controllerID: String, adapterGeneration: UInt64, contextGeneration: UInt64) {
        guard !controllerID.isEmpty, controllerID.utf8.count <= 128,
              adapterGeneration > 0, contextGeneration > 0 else { return nil }
        self.controllerID = controllerID
        self.adapterGeneration = adapterGeneration
        self.contextGeneration = contextGeneration
    }
}

public struct RPGControllerGenerationGate: Equatable {
    public private(set) var activeControllerID: String?
    public private(set) var adapterGeneration: UInt64
    public private(set) var contextGeneration: UInt64
    public private(set) var generationExhausted = false
    private var neutralControllers: Set<String> = []

    public init(adapterGeneration: UInt64 = 1, contextGeneration: UInt64 = 1) {
        self.adapterGeneration = max(1, adapterGeneration)
        self.contextGeneration = max(1, contextGeneration)
    }

    public mutating func noteNeutral(controllerID: String) {
        guard !generationExhausted, !controllerID.isEmpty, controllerID.utf8.count <= 128 else { return }
        neutralControllers.insert(controllerID)
    }

    public mutating func claimAfterInput(controllerID: String) -> RPGControllerCallbackIdentity? {
        guard !generationExhausted, neutralControllers.remove(controllerID) != nil else { return nil }
        activeControllerID = controllerID
        return currentIdentity
    }

    public var currentIdentity: RPGControllerCallbackIdentity? {
        guard !generationExhausted, let activeControllerID else { return nil }
        return RPGControllerCallbackIdentity(controllerID: activeControllerID,
            adapterGeneration: adapterGeneration, contextGeneration: contextGeneration)
    }

    public func accepts(_ identity: RPGControllerCallbackIdentity) -> Bool {
        identity == currentIdentity
    }

    /// Callback delivery validates its captured adapter/context generations before arbitration.
    /// Stable object identity remains the platform adapter's responsibility.
    public func acceptsCallback(_ identity: RPGControllerCallbackIdentity) -> Bool {
        !generationExhausted && identity.adapterGeneration == adapterGeneration &&
            identity.contextGeneration == contextGeneration
    }

    public func isNeutralEligible(controllerID: String) -> Bool {
        !generationExhausted && neutralControllers.contains(controllerID)
    }

    public mutating func disconnectOrReplace() {
        activeControllerID = nil
        neutralControllers.removeAll(keepingCapacity: true)
        guard !generationExhausted else { return }
        guard adapterGeneration < UInt64.max else {
            generationExhausted = true
            return
        }
        adapterGeneration += 1
    }

    public mutating func contextBoundary() {
        activeControllerID = nil
        neutralControllers.removeAll(keepingCapacity: true)
        guard !generationExhausted else { return }
        guard contextGeneration < UInt64.max else {
            generationExhausted = true
            return
        }
        contextGeneration += 1
    }
}
