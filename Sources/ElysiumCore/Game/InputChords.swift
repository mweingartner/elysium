import Foundation

public struct ElysiumKeyModifiers: OptionSet, Hashable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue & 0x0f }
    public static let command = ElysiumKeyModifiers(rawValue: 1 << 0)
    public static let control = ElysiumKeyModifiers(rawValue: 1 << 1)
    public static let option = ElysiumKeyModifiers(rawValue: 1 << 2)
    public static let shift = ElysiumKeyModifiers(rawValue: 1 << 3)
}

private let ELYSIUM_TERMINAL_KEY_ORDER: [String] = [
    "KeyA", "KeyS", "KeyD", "KeyF", "KeyH", "KeyG", "KeyZ", "KeyX", "KeyC", "KeyV", "KeyB",
    "KeyQ", "KeyW", "KeyE", "KeyR", "KeyY", "KeyT", "KeyO", "KeyU", "KeyI", "KeyP", "KeyL",
    "KeyJ", "KeyK", "KeyN", "KeyM", "Digit0", "Digit1", "Digit2", "Digit3", "Digit4", "Digit5",
    "Digit6", "Digit7", "Digit8", "Digit9", "Equal", "Minus", "BracketRight", "BracketLeft", "Quote",
    "Semicolon", "Backslash", "Comma", "Slash", "Period", "Tab", "Space", "Backquote", "Backspace",
    "Delete", "Escape", "Enter", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
    "F11", "F12", "ArrowLeft", "ArrowRight", "ArrowDown", "ArrowUp", "IntlBackslash", "Numpad0",
    "Numpad1", "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8",
    "Numpad9", "NumpadDecimal", "NumpadMultiply", "NumpadAdd", "NumpadDivide", "NumpadEnter",
    "NumpadSubtract", "NumpadEqual", "ShiftLeft", "ControlLeft",
]

public struct ElysiumTerminalKey: RawRepresentable, Hashable, Codable, Comparable {
    public let rawValue: String
    public init?(rawValue: String) {
        guard ELYSIUM_TERMINAL_KEY_ORDER.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }
    public static func < (lhs: ElysiumTerminalKey, rhs: ElysiumTerminalKey) -> Bool {
        let left = ELYSIUM_TERMINAL_KEY_ORDER.firstIndex(of: lhs.rawValue) ?? Int.max
        let right = ELYSIUM_TERMINAL_KEY_ORDER.firstIndex(of: rhs.rawValue) ?? Int.max
        return left < right
    }
}

public enum ElysiumKeyChordError: Error, Equatable {
    case empty, tooLong, emptySegment, unknownToken(String), modifierOnly, repeatedModifier(String)
    case nonCanonicalModifierOrder, multipleTerminalKeys, modifiedLegacyTerminal
}

public struct ElysiumKeyChord: Hashable, Codable, CustomStringConvertible {
    public let modifiers: ElysiumKeyModifiers
    public let terminal: ElysiumTerminalKey

    public init(modifiers: ElysiumKeyModifiers = [], terminal: ElysiumTerminalKey) throws {
        if terminal.rawValue == "ShiftLeft" || terminal.rawValue == "ControlLeft" {
            guard modifiers.isEmpty else { throw ElysiumKeyChordError.modifiedLegacyTerminal }
        }
        self.modifiers = modifiers
        self.terminal = terminal
    }

    public init(parsing raw: String) throws {
        guard !raw.isEmpty else { throw ElysiumKeyChordError.empty }
        guard raw.utf8.count <= 64 else { throw ElysiumKeyChordError.tooLong }
        let parts = raw.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty }) else { throw ElysiumKeyChordError.emptySegment }
        let orderedModifiers: [(String, ElysiumKeyModifiers)] = [
            ("Command", .command), ("Control", .control), ("Option", .option), ("Shift", .shift),
        ]
        var modifiers: ElysiumKeyModifiers = []
        var lastModifierIndex = -1
        var terminal: ElysiumTerminalKey?
        for part in parts {
            if let index = orderedModifiers.firstIndex(where: { $0.0 == part }) {
                guard terminal == nil else { throw ElysiumKeyChordError.nonCanonicalModifierOrder }
                guard index > lastModifierIndex else {
                    if modifiers.contains(orderedModifiers[index].1) { throw ElysiumKeyChordError.repeatedModifier(part) }
                    throw ElysiumKeyChordError.nonCanonicalModifierOrder
                }
                modifiers.insert(orderedModifiers[index].1)
                lastModifierIndex = index
            } else if let key = ElysiumTerminalKey(rawValue: part) {
                guard terminal == nil else { throw ElysiumKeyChordError.multipleTerminalKeys }
                terminal = key
            } else {
                throw ElysiumKeyChordError.unknownToken(part)
            }
        }
        guard let terminal else { throw ElysiumKeyChordError.modifierOnly }
        try self.init(modifiers: modifiers, terminal: terminal)
        guard description == raw else { throw ElysiumKeyChordError.nonCanonicalModifierOrder }
    }

    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("Command") }
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        parts.append(terminal.rawValue)
        return parts.joined(separator: "+")
    }
}

public enum ElysiumKeyEventOrigin: String, Codable { case physical, synthesizedLegacy }
public enum AppKeyEventSource: String, Codable { case performKeyEquivalent, keyDown, flagsChanged }

/// A collision-free callback identity. Keyboard and synthesized modifier deliveries intentionally
/// occupy different namespaces; neither observable event fields nor wall-clock time are identities.
public enum ElysiumInputDeliveryIdentity: Hashable {
    case keyboard(UInt64)
    case modifier(UInt64, ElysiumTerminalKey)
}

public struct AppKeyEventFingerprint: Hashable, Codable {
    public let eventNumber: Int64
    public let keyCode: UInt16
    public let timestampMicroseconds: UInt64
    public let windowNumber: Int32
    public let modifierBits: UInt8
    public let isRepeat: Bool
    public let origin: ElysiumKeyEventOrigin

    public init(eventNumber: Int64, keyCode: UInt16, timestampMicroseconds: UInt64,
                windowNumber: Int32, modifiers: ElysiumKeyModifiers, isRepeat: Bool,
                origin: ElysiumKeyEventOrigin) {
        self.eventNumber = eventNumber
        self.keyCode = keyCode
        self.timestampMicroseconds = timestampMicroseconds
        self.windowNumber = windowNumber
        self.modifierBits = modifiers.rawValue
        self.isRepeat = isRepeat
        self.origin = origin
    }
}

public struct ElysiumKeyEvent: Equatable {
    public let terminal: ElysiumTerminalKey
    public let modifiers: ElysiumKeyModifiers
    public let isRepeat: Bool
    public let origin: ElysiumKeyEventOrigin
    public let deliveryIdentity: ElysiumInputDeliveryIdentity

    /// Compatibility view used by existing diagnostics. Authorization and duplicate handling use
    /// `deliveryIdentity`, never this lossy projection.
    public var routingSerial: UInt64 {
        switch deliveryIdentity {
        case .keyboard(let serial), .modifier(let serial, _): return serial
        }
    }

    public init(terminal: ElysiumTerminalKey, modifiers: ElysiumKeyModifiers = [], isRepeat: Bool = false,
                origin: ElysiumKeyEventOrigin = .physical, routingSerial: UInt64) {
        self.terminal = terminal; self.modifiers = modifiers; self.isRepeat = isRepeat
        self.origin = origin; deliveryIdentity = .keyboard(routingSerial)
    }

    public init(terminal: ElysiumTerminalKey, modifiers: ElysiumKeyModifiers = [],
                isRepeat: Bool = false, origin: ElysiumKeyEventOrigin,
                deliveryIdentity: ElysiumInputDeliveryIdentity) {
        self.terminal = terminal; self.modifiers = modifiers; self.isRepeat = isRepeat
        self.origin = origin; self.deliveryIdentity = deliveryIdentity
    }

    public var chord: ElysiumKeyChord? { try? ElysiumKeyChord(modifiers: modifiers, terminal: terminal) }
}

public enum ElysiumBindingContext: Int, Codable, Comparable {
    case movement = 0, hotbar = 1, rpgWorldAction = 2, appHUD = 3, rpgScreen = 4
    public static func < (lhs: ElysiumBindingContext, rhs: ElysiumBindingContext) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum ResolvedKeyCommand: Equatable {
    case semantic(RPGSemanticCommand)
    case binding(ElysiumGameBindingAction)
    case worldAction(String)
}

/// Canonical identities for the configurable bindings that still feed Elysium's held-key game
/// input. The AppKit adapter dispatches these identities rather than re-inferring behavior from a
/// terminal key, so modified chords and binding changes cannot change the action after resolution.
public enum ElysiumGameBindingAction: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case forward, back, left, right, jump, sneak, sprint
    case inventory, drop, chat, command, perspective, swapOffhand
}

public struct ElysiumConfiguredBindingPress: Equatable {
    public let action: ElysiumGameBindingAction
    public let terminal: ElysiumTerminalKey
    public let executedCode: String

    public init(action: ElysiumGameBindingAction, terminal: ElysiumTerminalKey,
                executedCode: String) {
        self.action = action
        self.terminal = terminal
        self.executedCode = executedCode
    }
}

/// Pure press/release pairing for configurable held-key input. A release carries the exact code
/// published on its press even if live bindings change while the physical key remains down.
public struct ElysiumConfiguredBindingPressLedger: Equatable {
    private var pressedByTerminal: [ElysiumTerminalKey: ElysiumConfiguredBindingPress] = [:]

    public init() {}

    public var pressed: [ElysiumConfiguredBindingPress] {
        pressedByTerminal.values.sorted { $0.terminal < $1.terminal }
    }

    public mutating func press(action: ElysiumGameBindingAction, event: ElysiumKeyEvent,
                               bindings: [String: String]) -> ElysiumConfiguredBindingPress? {
        guard !event.isRepeat, pressedByTerminal[event.terminal] == nil,
              let definition = KEYBIND_DEFINITIONS.first(where: {
                  $0.command == .binding(action)
              }),
              let configured = try? ElysiumKeyChord(
                  parsing: bindings[definition.actionID] ?? definition.defaultChord.description),
              !isProtectedAppChord(configured), configured.terminal == event.terminal,
              configured.modifiers == event.modifiers ||
                (definition.context == .movement && configured.modifiers.isEmpty)
        else { return nil }
        let press = ElysiumConfiguredBindingPress(
            action: action, terminal: event.terminal, executedCode: configured.description)
        pressedByTerminal[event.terminal] = press
        return press
    }

    public mutating func release(terminal: ElysiumTerminalKey) -> ElysiumConfiguredBindingPress? {
        pressedByTerminal.removeValue(forKey: terminal)
    }

    public mutating func removeAll() {
        pressedByTerminal.removeAll(keepingCapacity: true)
    }
}

public struct ElysiumKeybindDefinition: Equatable {
    public let actionID: String
    public let displayName: String
    public let defaultChord: ElysiumKeyChord
    public let context: ElysiumBindingContext
    public let command: ResolvedKeyCommand
}

private func chord(_ raw: String) -> ElysiumKeyChord { try! ElysiumKeyChord(parsing: raw) }

private func makeKeybindDefinitions() -> [ElysiumKeybindDefinition] {
    let bases: [(String, String, String, ElysiumBindingContext)] = [
        ("forward", "Forward", "KeyW", .movement), ("back", "Back", "KeyS", .movement),
        ("left", "Left", "KeyA", .movement), ("right", "Right", "KeyD", .movement),
        ("jump", "Jump", "Space", .movement), ("sneak", "Sneak", "ShiftLeft", .movement),
        ("sprint", "Sprint", "ControlLeft", .movement),
        ("inventory", "Inventory", "KeyE", .appHUD), ("drop", "Drop Item", "KeyQ", .appHUD),
        ("chat", "Chat", "KeyT", .appHUD), ("command", "Command", "Slash", .appHUD),
        ("perspective", "Perspective", "F5", .appHUD),
        ("swapOffhand", "Swap Offhand", "KeyF", .appHUD),
        ("rpgCharacter", "RPG Character", "KeyK", .rpgWorldAction),
        ("rpgCycleAction", "Cycle RPG Action", "KeyO", .rpgWorldAction),
        ("rpgUseAction", "Use RPG Action", "KeyL", .rpgWorldAction),
    ]
    var definitions = bases.map { value in
        let command = ElysiumGameBindingAction(rawValue: value.0).map {
            ResolvedKeyCommand.binding($0)
        } ?? .worldAction(value.0)
        return ElysiumKeybindDefinition(actionID: value.0, displayName: value.1,
                                       defaultChord: chord(value.2), context: value.3,
                                       command: command)
    }
    definitions[13] = ElysiumKeybindDefinition(actionID: "rpgCharacter", displayName: "RPG Character",
                                               defaultChord: chord("KeyK"),
                                               context: .rpgWorldAction, command: .semantic(.openCharacter))
    definitions[14] = ElysiumKeybindDefinition(actionID: "rpgCycleAction", displayName: "Cycle RPG Action",
                                               defaultChord: chord("KeyO"),
                                               context: .rpgWorldAction, command: .semantic(.cyclePreparedAction))
    definitions[15] = ElysiumKeybindDefinition(actionID: "rpgUseAction", displayName: "Use RPG Action",
                                               defaultChord: chord("KeyL"),
                                               context: .rpgWorldAction, command: .semantic(.useSelectedAction))
    for index in 1...9 {
        let defaultChord = chord("Shift+Digit\(index)")
        let command = ResolvedKeyCommand.semantic(.useQuickSlot(index - 1))
        definitions.append(ElysiumKeybindDefinition(actionID: "rpgQuickSlot\(index)",
            displayName: "RPG Quick Slot \(index)",
            defaultChord: defaultChord, context: .rpgWorldAction, command: command))
    }
    return definitions
}

public let KEYBIND_DEFINITIONS: [ElysiumKeybindDefinition] = makeKeybindDefinitions()

public struct ElysiumShippingMenuCommand: Equatable {
    public let commandID: String
    public let chord: ElysiumKeyChord
}

public let SHIPPING_MENU_COMMANDS: [ElysiumShippingMenuCommand] = [
    ElysiumShippingMenuCommand(commandID: "quit", chord: chord("Command+KeyQ")),
    ElysiumShippingMenuCommand(commandID: "copyObjectTemplate", chord: chord("Command+KeyC")),
    ElysiumShippingMenuCommand(commandID: "placeObjectTemplate", chord: chord("Command+KeyV")),
    ElysiumShippingMenuCommand(commandID: "minimize", chord: chord("Command+KeyM")),
]

public let PROTECTED_APP_CHORDS: Set<ElysiumKeyChord> =
    Set(SHIPPING_MENU_COMMANDS.map(\.chord) + [chord("Command+KeyZ")])

public func isProtectedAppChord(_ value: ElysiumKeyChord) -> Bool {
    value.terminal.rawValue == "F11" || PROTECTED_APP_CHORDS.contains(value)
}

public func rpgDefaultChordBindings() -> [String: String] {
    Dictionary(uniqueKeysWithValues: KEYBIND_DEFINITIONS.map { ($0.actionID, $0.defaultChord.description) })
}

public enum ElysiumKeybindValidationError: Error, Equatable {
    case unknownAction(String)
    case invalidChord(String)
    case protectedChord(String)
}

public func rpgSanitizedChordBindings(_ raw: [String: String]) -> [String: String] {
    var output: [String: String] = [:]
    output.reserveCapacity(KEYBIND_DEFINITIONS.count)
    for definition in KEYBIND_DEFINITIONS {
        let candidate = raw[definition.actionID] ?? definition.defaultChord.description
        if let parsed = try? ElysiumKeyChord(parsing: candidate), !isProtectedAppChord(parsed) {
            output[definition.actionID] = parsed.description
        } else {
            output[definition.actionID] = definition.defaultChord.description
        }
    }
    return output
}

public func rpgValidateChordBindingsForPersistence(_ raw: [String: String])
    -> Result<[String: String], ElysiumKeybindValidationError> {
    for key in raw.keys where !KEYBIND_DEFINITIONS.contains(where: { $0.actionID == key }) {
        return .failure(.unknownAction(key))
    }
    var output = rpgDefaultChordBindings()
    for definition in KEYBIND_DEFINITIONS {
        guard let candidate = raw[definition.actionID] else { continue }
        guard let parsed = try? ElysiumKeyChord(parsing: candidate) else {
            return .failure(.invalidChord(definition.actionID))
        }
        guard !isProtectedAppChord(parsed) else {
            return .failure(.protectedChord(definition.actionID))
        }
        output[definition.actionID] = parsed.description
    }
    return .success(output)
}

public struct ElysiumKeybindConflict: Equatable {
    public let chord: ElysiumKeyChord
    public let actionIDs: [String]
    public let winnerActionID: String
}

public struct ElysiumControlsPendingConflict: Equatable {
    public let actionID: String
    public let chord: ElysiumKeyChord
    public let conflictingActionIDs: [String]
    public let winnerActionID: String
    public let candidateBindings: [String: String]

    public init(actionID: String, chord: ElysiumKeyChord, conflictingActionIDs: [String],
                winnerActionID: String, candidateBindings: [String: String]) {
        self.actionID = actionID
        self.chord = chord
        self.conflictingActionIDs = conflictingActionIDs
        self.winnerActionID = winnerActionID
        self.candidateBindings = candidateBindings
    }
}

public enum ElysiumControlsCandidateDecision: Equatable {
    case ready(actionID: String, chord: ElysiumKeyChord, candidateBindings: [String: String])
    case conflict(ElysiumControlsPendingConflict)
    case reserved
    case invalidAction
    case invalidBindings
}

/// Builds a detached, exact candidate for the Controls screen. Nothing in this function publishes
/// live bindings: callers must persist the returned dictionary before using it as display state.
public func prepareControlsKeybindCandidate(
    bindings: [String: String], actionID: String, chord: ElysiumKeyChord
) -> ElysiumControlsCandidateDecision {
    guard KEYBIND_DEFINITIONS.contains(where: { $0.actionID == actionID }) else {
        return .invalidAction
    }
    guard !isProtectedAppChord(chord) else { return .reserved }
    let expectedActions = Set(KEYBIND_DEFINITIONS.map(\.actionID))
    guard bindings.count == KEYBIND_DEFINITIONS.count,
          Set(bindings.keys) == expectedActions else { return .invalidBindings }
    var candidate = bindings
    candidate[actionID] = chord.description
    guard case .success(let canonical) = rpgValidateChordBindingsForPersistence(candidate) else {
        return .invalidBindings
    }
    if let conflict = keybindConflicts(bindings: canonical).first(where: { $0.chord == chord }) {
        return .conflict(ElysiumControlsPendingConflict(
            actionID: actionID, chord: chord, conflictingActionIDs: conflict.actionIDs,
            winnerActionID: conflict.winnerActionID, candidateBindings: canonical))
    }
    return .ready(actionID: actionID, chord: chord, candidateBindings: canonical)
}

public struct ElysiumControlsRow: Equatable {
    public let definitionIndex: Int
    public let actionID: String
    public let chordText: String
    public let conflictText: String?
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
}

public struct ElysiumControlsLayout: Equatable {
    public static let rowStride = 22.0
    public let columnCount: Int
    public let clampedScrollOffset: Double
    public let maximumScrollOffset: Double
    public let visibleRows: [ElysiumControlsRow]

    public init(viewportWidth: Double, contentTop: Double, contentBottom: Double,
                requestedScrollOffset: Double, bindings: [String: String]) {
        let safeWidth = viewportWidth.isFinite ? max(1, viewportWidth) : 1
        let safeTop = contentTop.isFinite ? contentTop : 0
        let safeBottom = contentBottom.isFinite ? max(safeTop, contentBottom) : safeTop
        columnCount = safeWidth < 520 ? 1 : 2
        let logicalLineCount = Int(ceil(Double(KEYBIND_DEFINITIONS.count) / Double(columnCount)))
        let viewportHeight = max(0, safeBottom - safeTop)
        maximumScrollOffset = max(0, Double(logicalLineCount) * Self.rowStride - viewportHeight)
        let finiteOffset = requestedScrollOffset.isFinite ? requestedScrollOffset : 0
        clampedScrollOffset = min(max(0, finiteOffset), maximumScrollOffset)

        let horizontalMargin = safeWidth < 380 ? 8.0 : 14.0
        let columnGap = columnCount == 1 ? 0.0 : 8.0
        let columnWidth = max(1, (safeWidth - horizontalMargin * 2 - columnGap) / Double(columnCount))
        let conflicts = keybindConflicts(bindings: bindings)
        var rows: [ElysiumControlsRow] = []
        rows.reserveCapacity(KEYBIND_DEFINITIONS.count)
        for (index, definition) in KEYBIND_DEFINITIONS.enumerated() {
            let column = index % columnCount
            let line = index / columnCount
            let y = safeTop + Double(line) * Self.rowStride - clampedScrollOffset
            // Only publish fully visible rows: the executable has no per-widget clipping region,
            // so partial rows must not overlap sensitivity/status controls or receive hidden hits.
            guard y >= safeTop, y + 20 <= safeBottom else { continue }
            let raw = bindings[definition.actionID] ?? definition.defaultChord.description
            let canonical = (try? ElysiumKeyChord(parsing: raw))?.description
                ?? definition.defaultChord.description
            let conflict = conflicts.first { $0.chord.description == canonical }
            let conflictText = conflict.map {
                "Conflict: \($0.actionIDs.joined(separator: ", ")); winner \($0.winnerActionID)"
            }
            rows.append(ElysiumControlsRow(
                definitionIndex: index, actionID: definition.actionID, chordText: canonical,
                conflictText: conflictText,
                x: horizontalMargin + Double(column) * (columnWidth + columnGap), y: y,
                width: columnWidth, height: 20))
        }
        visibleRows = rows
    }
}

public func keybindConflicts(bindings: [String: String]) -> [ElysiumKeybindConflict] {
    var parsed: [(Int, ElysiumKeybindDefinition, ElysiumKeyChord)] = []
    for (index, definition) in KEYBIND_DEFINITIONS.enumerated() {
        let raw = bindings[definition.actionID] ?? definition.defaultChord.description
        guard let value = try? ElysiumKeyChord(parsing: raw) else { continue }
        parsed.append((index, definition, value))
    }
    var result: [ElysiumKeybindConflict] = []
    for chordValue in Set(parsed.map { $0.2 }).sorted(by: { $0.description < $1.description }) {
        let matching = parsed.filter { $0.2 == chordValue }.sorted {
            if $0.1.context != $1.1.context { return $0.1.context > $1.1.context }
            return $0.0 < $1.0
        }
        guard matching.count > 1 else { continue }
        result.append(ElysiumKeybindConflict(chord: chordValue, actionIDs: matching.map { $0.1.actionID },
                                            winnerActionID: matching[0].1.actionID))
    }
    return result
}

public func resolveKeyCommand(event: ElysiumKeyEvent,
                              allowedContexts: Set<ElysiumBindingContext>,
                              bindings: [String: String]) -> ResolvedKeyCommand? {
    guard !event.isRepeat else { return nil }
    guard let eventChord = event.chord else { return nil }
    guard !isProtectedAppChord(eventChord) else { return nil }
    var candidates: [(exact: Bool, index: Int, definition: ElysiumKeybindDefinition)] = []
    for (index, definition) in KEYBIND_DEFINITIONS.enumerated() where allowedContexts.contains(definition.context) {
        let raw = bindings[definition.actionID] ?? definition.defaultChord.description
        guard let binding = try? ElysiumKeyChord(parsing: raw), !isProtectedAppChord(binding),
              binding.terminal == event.terminal else { continue }
        if binding.modifiers == event.modifiers {
            candidates.append((true, index, definition))
        } else if definition.context == .movement && binding.modifiers.isEmpty {
            candidates.append((false, index, definition))
        }
    }
    candidates.sort {
        if $0.exact != $1.exact { return $0.exact && !$1.exact }
        if $0.definition.context != $1.definition.context { return $0.definition.context > $1.definition.context }
        return $0.index < $1.index
    }
    return candidates.first?.definition.command
}

/// Narrow compatibility fallback for the historical Control+Drop "drop all" gesture. It applies
/// only when Drop remains a canonical unmodified app-HUD binding; no other modifier-added binding
/// is relaxed and protected app chords remain excluded.
public func resolveLegacyControlDropAll(event: ElysiumKeyEvent,
                                        bindings: [String: String]) -> ResolvedKeyCommand? {
    guard !event.isRepeat, event.modifiers == .control,
          let eventChord = event.chord, !isProtectedAppChord(eventChord),
          let definition = KEYBIND_DEFINITIONS.first(where: { $0.actionID == "drop" }),
          let configured = try? ElysiumKeyChord(
            parsing: bindings[definition.actionID] ?? definition.defaultChord.description),
          configured.modifiers.isEmpty, configured.terminal == event.terminal else { return nil }
    return .worldAction("dropAll")
}

public struct RPGPureInputRouter: Equatable {
    private(set) public var consumedIdentities: [ElysiumInputDeliveryIdentity] = []
    public init() {}

    public var consumedSerials: [UInt64] { consumedIdentities.map {
        switch $0 { case .keyboard(let value), .modifier(let value, _): value }
    } }

    public mutating func resolve(event: ElysiumKeyEvent, allowedContexts: Set<ElysiumBindingContext>,
                                 bindings: [String: String]) -> ResolvedKeyCommand? {
        guard !consumedIdentities.contains(event.deliveryIdentity),
              let command = resolveKeyCommand(event: event, allowedContexts: allowedContexts,
                                              bindings: bindings) else { return nil }
        remember(event.deliveryIdentity)
        return command
    }

    public mutating func route(event: ElysiumKeyEvent, fingerprint: AppKeyEventFingerprint,
                               nowMilliseconds: UInt64,
                               eligibleAppShortcutCommand: ResolvedKeyCommand? = nil,
                               screenCommand: ResolvedKeyCommand? = nil,
                               screenPresent: Bool = false,
                               independentCommand: ResolvedKeyCommand? = nil,
                               allowedContexts: Set<ElysiumBindingContext>, bindings: [String: String])
        -> RPGPureInputRouteDisposition {
        _ = fingerprint
        _ = nowMilliseconds
        if consumedIdentities.contains(event.deliveryIdentity) {
            return .consumedDuplicate
        }
        let chord = event.chord
        if event.terminal.rawValue == "F11" {
            remember(event.deliveryIdentity)
            return event.isRepeat ? .consumedRepeat : .globalFullscreen
        }
        if !event.isRepeat, let chord,
           ["Command+KeyC", "Command+KeyV", "Command+KeyZ"].contains(chord.description),
           let eligibleAppShortcutCommand {
            remember(event.deliveryIdentity)
            return .resolved(eligibleAppShortcutCommand)
        }
        if let chord, SHIPPING_MENU_COMMANDS.contains(where: { $0.chord == chord }) {
            return .unhandledForMainMenu
        }
        if let chord, isProtectedAppChord(chord) { return .unhandledProtected }
        if let screenCommand, !event.isRepeat {
            remember(event.deliveryIdentity)
            return .resolved(screenCommand)
        }
        if screenPresent { return .routeToScreen }
        if let command = resolveKeyCommand(event: event, allowedContexts: allowedContexts,
                                           bindings: bindings) {
            remember(event.deliveryIdentity)
            return .resolved(command)
        }
        if !event.isRepeat, let independentCommand {
            remember(event.deliveryIdentity)
            return .resolved(independentCommand)
        }
        // A held key in-world emits a stream of OS key-repeat events. Movement, hotbar, and
        // world actions all act on the press/release edge, so a repeat carries no new intent.
        // Swallow it here rather than returning `.unhandled` — otherwise the AppKit responder
        // chain surfaces each repeat as an unhandled-key system beep for as long as the key is held.
        if event.isRepeat {
            remember(event.deliveryIdentity)
            return .consumedRepeat
        }
        return .unhandled
    }

    /// Records a screen/lifecycle action only after the AppKit adapter reports that it actually
    /// handled the event. Unhandled `performKeyEquivalent` events intentionally remain absent so
    /// the matching `keyDown` delivery may still route them.
    public mutating func rememberConsumed(_ event: ElysiumKeyEvent) {
        remember(event.deliveryIdentity)
    }

    private mutating func remember(_ identity: ElysiumInputDeliveryIdentity) {
        guard !consumedIdentities.contains(identity) else { return }
        consumedIdentities.append(identity)
        if consumedIdentities.count > 16 {
            consumedIdentities.removeFirst(consumedIdentities.count - 16)
        }
    }
}

public enum RPGPureInputRouteDisposition: Equatable {
    case globalFullscreen
    case resolved(ResolvedKeyCommand)
    case consumedRepeat
    case consumedDuplicate
    case unhandledForMainMenu
    case unhandledProtected
    case routeToScreen
    case unhandled
}

public struct ElysiumModifierEdgeSynthesizer: Equatable {
    private var previousModifiers: ElysiumKeyModifiers = []
    private var serial: UInt64 = 0
    private(set) public var exhausted = false

    public init() {}

    init(startingSerial: UInt64) { serial = startingSerial }

    public mutating func update(_ modifiers: ElysiumKeyModifiers) -> [ElysiumKeyEvent] {
        defer { previousModifiers = modifiers }
        guard !exhausted else { return [] }
        var events: [ElysiumKeyEvent] = []
        for (modifier, terminalName) in [(ElysiumKeyModifiers.shift, "ShiftLeft"),
                                         (ElysiumKeyModifiers.control, "ControlLeft")] {
            guard modifiers.contains(modifier), !previousModifiers.contains(modifier),
                  let terminal = ElysiumTerminalKey(rawValue: terminalName) else { continue }
            let next = serial.addingReportingOverflow(1)
            guard !next.overflow, next.partialValue != 0 else {
                exhausted = true
                return []
            }
            serial = next.partialValue
            events.append(ElysiumKeyEvent(
                terminal: terminal, origin: .synthesizedLegacy,
                deliveryIdentity: .modifier(serial, terminal)))
        }
        return events
    }
}
