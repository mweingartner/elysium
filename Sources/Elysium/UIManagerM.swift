// UI core — screen stack, cursor item, GUI scaling, MC-style
// panel/slot/button/slider/textfield drawing, and the slot interaction
// framework shared by every container screen. Draws through UICanvas.

import Foundation
import QuartzCore
import AppKit
import ElysiumCore
import ElysiumTextInput

/// Bridges legacy synchronous AppKit/UI callbacks into compiler-enforced
/// `@MainActor` lifecycle APIs. The runtime assertion is deliberately adjacent
/// to the only `assumeIsolated` used by the saved-world/LAN admission path.
@inline(__always)
func elysiumMainActorSync<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    MainActor.preconditionIsolated()
    return try MainActor.assumeIsolated(body)
}

final class SlotDef {
    var x: Double
    var y: Double
    let get: () -> ItemStack?
    let set: (ItemStack?) -> Void
    var canPlace: ((ItemStack) -> Bool)?
    var output = false
    var onTake: ((ItemStack) -> Void)?
    /// Optional pre-transfer transaction. The closure must return a stack no
    /// larger than and metadata-equal to the preview, or nil when nothing
    /// committed. Unlike `onTake`, it runs before cursor/inventory insertion.
    var commitOutputTake: ((ItemStack) -> ItemStack?)?
    var repeatsOutputQuickMove: () -> Bool
    var onChange: (() -> Void)?

    init(x: Double, y: Double, get: @escaping () -> ItemStack?, set: @escaping (ItemStack?) -> Void,
         canPlace: ((ItemStack) -> Bool)? = nil, output: Bool = false,
         onTake: ((ItemStack) -> Void)? = nil,
         commitOutputTake: ((ItemStack) -> ItemStack?)? = nil,
         repeatsOutputQuickMove: @escaping () -> Bool = { true },
         onChange: (() -> Void)? = nil) {
        self.x = x
        self.y = y
        self.get = get
        self.set = set
        self.canPlace = canPlace
        self.output = output
        self.onTake = onTake
        self.commitOutputTake = commitOutputTake
        self.repeatsOutputQuickMove = repeatsOutputQuickMove
        self.onChange = onChange
    }
}

class Button {
    var enabled = true
    var visible = true
    var x: Double, y: Double, w: Double, h: Double
    var label: String
    var onClick: () -> Void

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ label: String, _ onClick: @escaping () -> Void) {
        self.x = x; self.y = y; self.w = w; self.h = h
        self.label = label
        self.onClick = onClick
    }
    func contains(_ mx: Double, _ my: Double) -> Bool {
        visible && enabled && mx >= x && mx < x + w && my >= y && my < y + h
    }
}

enum CraftAmountDirection {
    case up
    case down
}

final class CraftAmountButton: Button {
    let direction: CraftAmountDirection

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
         direction: CraftAmountDirection, _ onClick: @escaping () -> Void) {
        self.direction = direction
        super.init(x, y, w, h, "", onClick)
    }
}

final class Slider: Button {
    let getLabel: () -> String
    let getValue: () -> Double
    let setValue: (Double) -> Void
    var dragging = false

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double,
         _ getLabel: @escaping () -> String, _ getValue: @escaping () -> Double, _ setValue: @escaping (Double) -> Void) {
        self.getLabel = getLabel
        self.getValue = getValue
        self.setValue = setValue
        super.init(x, y, w, h, "", {})
    }
}

final class CheckBox: Button {
    let isChecked: () -> Bool

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ label: String,
         isChecked: @escaping () -> Bool, _ onClick: @escaping () -> Void) {
        self.isChecked = isChecked
        super.init(x, y, w, h, label, onClick)
    }
}

final class TextField {
    let id: String
    let accessibilityLabel: String
    private var buffer: ElysiumBoundedTextBuffer
    var text: String {
        get { buffer.text }
        set { _ = replaceText(newValue, caret: newValue.count) }
    }
    var focused = false
    var enabled = true
    var caret = 0
    private(set) var visibleStart = 0
    var maxLength = 64
    var x: Double, y: Double, w: Double, h: Double
    var placeholder: String

    init(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ placeholder: String = "",
         id: String = "field", accessibilityLabel: String? = nil) {
        self.x = x; self.y = y; self.w = w; self.h = h
        self.placeholder = placeholder
        self.id = id
        self.accessibilityLabel = accessibilityLabel ?? (placeholder.isEmpty ? "Text" : placeholder)
        buffer = ElysiumBoundedTextBuffer("", limit: ElysiumTextLimit(
            maximumCharacters: 64, maximumUTF8Bytes: 4_096))
    }
    func contains(_ mx: Double, _ my: Double) -> Bool {
        enabled && mx >= x && mx < x + w && my >= y && my < y + h
    }
    private var limit: ElysiumTextLimit {
        ElysiumTextLimit(maximumCharacters: maxLength, maximumUTF8Bytes: 4_096)
    }

    @discardableResult
    func replaceText(_ value: String, caret requestedCaret: Int? = nil) -> Bool {
        var replacement = ElysiumBoundedTextBuffer("", limit: limit)
        guard replacement.replaceAtomically(value, limit: limit) else { return false }
        buffer = replacement
        caret = max(0, min(requestedCaret ?? value.count, value.count))
        visibleStart = min(visibleStart, caret)
        return true
    }

    @discardableResult
    func insert(_ proposal: String) -> Bool {
        guard enabled else { return false }
        guard case .accepted(let characterCount, _) = buffer.insertWholeProposalAtomically(
            proposal, atCharacterOffset: caret, limit: limit) else { return false }
        caret += characterCount
        return true
    }
    @discardableResult
    func insertPastePrefix(_ proposal: String) -> Bool {
        guard enabled else { return false }
        guard case .accepted(let characterCount, _) = buffer.insertValidPrefixAtomically(
            proposal, atCharacterOffset: caret, limit: limit) else { return false }
        caret += characterCount
        return true
    }
    func type(_ ch: String) { _ = insert(ch) }
    @discardableResult
    func deleteBackward() -> Bool { buffer.deleteBackward(atCharacterOffset: &caret) }
    func backspace() { _ = deleteBackward() }
    func moveCaret(by delta: Int) { caret = max(0, min(text.count, caret + delta)) }

    func focus(atX mouseX: Double, measure: (String) -> Int) {
        focused = true
        caret = elysiumCaretOffsetForClick(text: text, visibleStart: visibleStart,
                                          clickAdvance: mouseX - (x + 4), measure: measure)
    }

    func visiblePresentation(measure: (String) -> Int) -> (text: String, caretX: Double) {
        let capacity = max(0, Int(w - 9)) // 4px insets plus bitmap shadow/caret
        let presentation = elysiumTextPresentation(text: text, caret: caret,
                                                  visibleStart: visibleStart,
                                                  maximumWidth: capacity, measure: measure)
        visibleStart = presentation.visibleStart
        return (presentation.text, x + 4 + Double(presentation.caretAdvance))
    }
}

enum TextEntryAccessibilityRole: Equatable {
    case textField
    case searchField
    case staticText
    case button
    case checkbox
    case listItem
    case heading
    case list
}

struct TextEntryAccessibilityDescriptor {
    let id: String
    let role: TextEntryAccessibilityRole
    let label: String
    let value: String
    let help: String
    let frame: (x: Double, y: Double, width: Double, height: Double)
    let enabled: Bool
    let focused: Bool
    let insertionUTF16Offset: Int?
    let focusable: Bool
    let selected: Bool?
    let actionable: Bool
    let parentID: String?

    init(id: String, role: TextEntryAccessibilityRole, label: String, value: String,
         help: String, frame: (x: Double, y: Double, width: Double, height: Double),
         enabled: Bool, focused: Bool, insertionUTF16Offset: Int?, focusable: Bool,
         selected: Bool? = nil, actionable: Bool = false, parentID: String? = nil) {
        self.id = id; self.role = role; self.label = label; self.value = value
        self.help = help; self.frame = frame; self.enabled = enabled; self.focused = focused
        self.insertionUTF16Offset = insertionUTF16Offset; self.focusable = focusable
        self.selected = selected; self.actionable = actionable
        self.parentID = parentID
    }
}

/// Immutable AppKit pointer metadata captured at the event boundary. Screens
/// must not infer click cardinality from timing or reuse mutable global modifier
/// state for destructive or double-activation gestures.
struct ScreenPointerEvent: Equatable {
    let eventType: NSEvent.EventType
    let button: Int
    let appKitButtonNumber: Int
    let clickCount: Int
    let windowNumber: Int
    let eventNumber: Int
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool

    init(eventType: NSEvent.EventType, button: Int,
         appKitButtonNumber: Int, clickCount: Int,
         windowNumber: Int, eventNumber: Int,
         modifierFlags: NSEvent.ModifierFlags) {
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.eventType = eventType
        self.button = button
        self.appKitButtonNumber = appKitButtonNumber
        self.clickCount = clickCount
        self.windowNumber = windowNumber
        self.eventNumber = eventNumber
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        control = flags.contains(.control)
    }

    var isUnmodifiedPrimaryDoubleClick: Bool {
        eventType == .leftMouseDown && button == 0
            && appKitButtonNumber == 0 && clickCount == 2
            && !command && !shift && !option && !control
    }

    static func canonicalElysiumButton(appKitButtonNumber: Int) -> Int? {
        switch appKitButtonNumber {
        case 0: return 0
        case 1: return 2
        case 2: return 1
        default: return nil
        }
    }

    static func canonicalDownType(appKitButtonNumber: Int) -> NSEvent.EventType? {
        switch appKitButtonNumber {
        case 0: return .leftMouseDown
        case 1: return .rightMouseDown
        case 2: return .otherMouseDown
        default: return nil
        }
    }
}

class Screen {
    var closeOnEsc = true
    var showHUD = false
    var pausesGame = false
    var buttons: [Button] = []
    var sliders: [Slider] = []
    var fields: [TextField] = []
    var slots: [SlotDef] = []
    var readOnlySlots = false
    fileprivate(set) var textScreenIdentity: UInt64 = 0
    fileprivate(set) var textPresentationGeneration: UInt64 = 0
    fileprivate(set) var rpgPassiveSemanticSnapshot: RPGPassiveSemanticSnapshot?
    fileprivate(set) var rpgCommittedSemanticSnapshot: RPGCommittedSemanticSnapshot?
    fileprivate(set) var rpgPassiveSemanticUnavailable = false
    fileprivate var rpgPassiveScreenInstanceID: UInt64?
    fileprivate var rpgPassiveSemanticRevision: UInt64?

    /// Default-empty accessibility semantics. Only a screen with one atomically committed RPG
    /// model may publish a tree or accept semantic focus.
    var semanticSnapshot: RPGCommittedSemanticSnapshot? { nil }
    var semanticRevision: UInt64 { 0 }
    func focusSemanticElement(_ id: RPGUIElementID,
                              _ ui: UIManager, _ game: GameCore) -> Bool { false }

    /// Mutation-free inspection seam shared by rendering and later accessibility publication.
    func rpgPassiveDescriptor(id: RPGUIElementID) -> RPGSemanticDescriptor? {
        (rpgCommittedSemanticSnapshot?.model ?? rpgPassiveSemanticSnapshot?.model)?
            .descriptors.first { $0.id == id }
    }

    func clearRPGPassiveSemanticSnapshot() {
        rpgPassiveSemanticSnapshot = nil
        rpgCommittedSemanticSnapshot = nil
        rpgPassiveSemanticUnavailable = true
    }

    /// Handles presentation-only commands after the shared activation boundary dispatches them.
    func handleRPGPresentationCommand(_ command: RPGSemanticCommand,
                                      _ ui: UIManager, _ game: GameCore) -> Bool { false }

    func initScreen(_ ui: UIManager, _ game: GameCore) {}
    /// Rebuilds resize-dependent controls. Screens whose initialization has
    /// loading or mutation side effects must override this with layout-only
    /// work; the default preserves the legacy behavior for inert screens.
    func relayoutScreen(_ ui: UIManager, _ game: GameCore) {
        buttons.removeAll()
        sliders.removeAll()
        fields.removeAll()
        slots.removeAll()
        initScreen(ui, game)
    }
    func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {}
    func onClose(_ ui: UIManager, _ game: GameCore) {}
    func inputOwnershipLost(_ ui: UIManager, _ game: GameCore) {}

    func ownsTextInput(_ ui: UIManager, _ game: GameCore) -> Bool {
        fields.filter(\.focused).count == 1
    }

    @discardableResult
    func insertText(_ ui: UIManager, _ game: GameCore, _ proposal: String) -> Bool {
        guard let field = fields.first(where: { $0.focused }),
              fields.filter(\.focused).count == 1 else { return false }
        return field.insert(proposal)
    }

    @discardableResult
    func pasteText(_ ui: UIManager, _ game: GameCore, _ proposal: String) -> Bool {
        guard let field = fields.first(where: { $0.focused }),
              fields.filter(\.focused).count == 1 else { return false }
        return field.insertPastePrefix(proposal)
    }

    func textOwnerDescriptorID(_ ui: UIManager, _ game: GameCore) -> String? {
        let focused = fields.filter(\.focused)
        return focused.count == 1 ? focused[0].id : nil
    }

    /// A visible descriptor requested by an ordinary activation. Unlike the
    /// current owner ID, this may name an editor before it acquires focus.
    func textActivationDescriptorID(_ ui: UIManager, _ game: GameCore) -> String? {
        textOwnerDescriptorID(ui, game)
    }

    func activateImplicitTextDescriptor(_ id: String) -> Bool { false }

    @discardableResult
    func focusTextDescriptor(authorization: UIManager.TextFocusAuthorization,
                             ui: UIManager, clickX: Double? = nil) -> Bool {
        guard let id = ui.claimTextFocusAuthorization(authorization, for: self) else { return false }
        let matches = fields.filter { $0.id == id }
        if matches.isEmpty { return activateImplicitTextDescriptor(id) }
        guard matches.count == 1, let target = matches.first else { return false }
        for field in fields { field.focused = field === target }
        if let clickX { target.focus(atX: clickX, measure: textWidth) }
        return true
    }

    func placeReadyTextCaret(descriptorID: String, clickX: Double) -> Bool {
        let matches = fields.filter { $0.id == descriptorID && $0.focused }
        guard matches.count == 1, fields.filter(\.focused).count == 1,
              let target = matches.first else { return false }
        target.focus(atX: clickX, measure: textWidth)
        return true
    }

    func clearTextFocus() {
        for field in fields { field.focused = false }
    }

    func textAccessibilityDescriptors(_ ui: UIManager, _ game: GameCore)
        -> [TextEntryAccessibilityDescriptor] {
        fields.map { field in
            let insertion = elysiumUTF16InsertionOffset(in: field.text, characterOffset: field.caret)
            return TextEntryAccessibilityDescriptor(
                id: field.id,
                role: field.id.lowercased().contains("search") ? .searchField : .textField,
                label: field.accessibilityLabel,
                value: field.text,
                help: field.placeholder.isEmpty
                    ? "Editable text. Use Left, Right, and Backspace."
                    : "\(field.placeholder). Editable text. Use Left, Right, and Backspace.",
                frame: (field.x, field.y, field.w, field.h), enabled: field.enabled,
                focused: field.focused && field.enabled, insertionUTF16Offset: insertion,
                focusable: field.enabled)
        }
    }

    func consumeTextAccessibilityStatusAnnouncement() -> String? { nil }

    func performTextAccessibilityAction(_ id: String, _ ui: UIManager,
                                        _ game: GameCore) -> Bool { false }
    func focusTextAccessibilityElement(_ id: String, _ ui: UIManager,
                                       _ game: GameCore) -> Bool { false }

    /// Reverts a custom, implicit text owner when the readiness transaction
    /// cannot establish the real AppKit first responder. Ordinary `TextField`
    /// owners already roll back by clearing logical focus.
    func cancelImplicitTextOwnerActivation() -> Bool { false }

    @discardableResult
    func onPointerDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double,
                       _ event: ScreenPointerEvent) -> Bool {
        onMouseDown(ui, game, mx, my, event.button)
    }

    @discardableResult
    func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        if btn == 0, let hit = fields.first(where: { $0.contains(mx, my) }) {
            _ = ui.establishOrdinaryTextReadiness(
                screen: self, game: game, descriptorID: hit.id,
                cause: .primaryClick, clickX: mx)
            return true
        }
        let ownerBefore = textOwnerDescriptorID(ui, game)
        if btn == 0 { ui.clearTextReadiness(screen: self, clearLogicalFocus: true) }
        for b in buttons where b.contains(mx, my) {
            game.playUISound("ui.button.click")
            b.onClick()
            ui.reconcileOrdinaryTextOwnerChange(on: self, game: game, previousID: ownerBefore)
            return true
        }
        for s in sliders where s.contains(mx, my) {
            s.dragging = true
            s.setValue(max(0, min(1, (mx - s.x - 4) / (s.w - 8))))
            return true
        }
        if let slot = slotAt(mx, my) {
            if readOnlySlots { return true }
            ui.handleSlotClick(game, self, slot, btn, shift: ui.shiftDown)
            return true
        }
        return false
    }
    func onMouseUp(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        for s in sliders { s.dragging = false }
    }
    func onMouseMove(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        for s in sliders where s.dragging {
            s.setValue(max(0, min(1, (mx - s.x - 4) / (s.w - 8))))
        }
    }
    func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool { false }
    func onKeyEvent(_ ui: UIManager, _ game: GameCore, _ event: ElysiumKeyEvent) -> Bool {
        onKey(ui, game, event.terminal.rawValue)
    }
    func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        for f in fields where f.focused {
            if key == "Backspace" { f.backspace(); return true }
            if key == "ArrowLeft" { f.moveCaret(by: -1); return true }
            if key == "ArrowRight" { f.moveCaret(by: 1); return true }
            if key == "Tab" { return true }
        }
        return false
    }
    func onChar(_ ui: UIManager, _ game: GameCore, _ ch: String) -> Bool {
        insertText(ui, game, ch)
    }
    func slotAt(_ mx: Double, _ my: Double) -> SlotDef? {
        slots.first { mx >= $0.x && mx < $0.x + 18 && my >= $0.y && my < $0.y + 18 }
    }
    /// shift-click routing — override in container screens
    func quickMove(_ game: GameCore, _ slot: SlotDef) {}
}

final class UIManager {
    typealias OrdinaryTextReadinessCause = ElysiumTextActivationCause

    final class TextFocusAuthorization {
        fileprivate let token: ElysiumTextOwnerToken
        fileprivate var consumed = false
        private init(token: ElysiumTextOwnerToken) { self.token = token }

        fileprivate static func mint(_ token: ElysiumTextOwnerToken) -> TextFocusAuthorization {
            TextFocusAuthorization(token: token)
        }
    }
    let cv: UICanvas
    var packUI: PackUI?          // pack GUI sheets (nil = procedural UI)
    var titlePhoto = false       // renderer has a title-bg photo loaded
    var titleLogo = false        // renderer has a hero-embedded or fallback wordmark
    var scale = 3.0
    var width = 0.0    // GUI units
    var height = 0.0
    var mouseX = 0.0
    var mouseY = 0.0
    var shiftDown = false
    var optionDown = false
    var cursorStack: ItemStack?
    private var stack: [Screen] = []
    private var textPresentationClock = ElysiumTextPresentationClock()
    private var nextTextScreenIdentity: UInt64 = 0
    private var textIdentityExhausted = false
    private var textFocusTransaction = ElysiumTextFocusTransactionAdapter()
    private weak var activeTextAuthorization: TextFocusAuthorization?
    private var savedWorldMaintenanceOperationOwner: AnyObject?
    private var afterNextPresentedFrameCallback: (() -> Void)?
    weak var textInputView: GameView?
    /// The sole RPG activation-receipt owner shared by mouse, keyboard, and the RPG controller.
    /// Accessibility joins this same boundary in its separately gated build step.
    private var rpgSemanticActivationBoundary: RPGSemanticActivationBoundary?
    /// The sole owner of passive screen identities. Checked exhaustion is fail-closed and latched.
    private var rpgPassiveSemanticClock = RPGPassiveSemanticClock()
    private var rpgAccessibilityPublicationClock = RPGAccessibilityPublicationClock()
    var rpgAccessibilityDidCommit: ((Screen, RPGAccessibilityTreeSnapshot) -> Void)?
    var rpgAccessibilityDidInvalidate: (() -> Void)?
    var textAccessibilityDidCommit: ((Screen, [TextEntryAccessibilityDescriptor]) -> Void)?
    var textAccessibilityDidInvalidate: (() -> Void)?
    var accessibilityDidInvalidateAll: (() -> Void)?
    private var nextWorldSemanticRevision: UInt64 = 0
    private var lastWorldScreenInstanceID: UInt64 = RPGPassiveSemanticClock.maximumScreenInstanceID
    private var worldSemanticRevisionExhausted = false
    private var worldScreenInstanceIDExhausted = false
    private(set) var rpgControllerHelpPrimary = false
    var rpgControllerContextDidChange: (() -> Void)?
    var tooltipLines: [String]?

    init(cv: UICanvas) {
        self.cv = cv
    }

    /// Registers one continuation for the first GPU-completed frame scheduled
    /// after this call. The caller publishes visible state before registering.
    func afterNextPresentedFrame(_ callback: @escaping () -> Void) -> Bool {
        guard afterNextPresentedFrameCallback == nil else { return false }
        afterNextPresentedFrameCallback = callback
        return true
    }

    func cancelAfterNextPresentedFrame() {
        afterNextPresentedFrameCallback = nil
    }

    func takeAfterNextPresentedFrameCallback() -> (() -> Void)? {
        defer { afterNextPresentedFrameCallback = nil }
        return afterNextPresentedFrameCallback
    }

    @MainActor
    func validatesCurrentActiveKeyPointerEvent(_ event: ScreenPointerEvent) -> Bool {
        guard NSApp.isActive,
              let view = textInputView,
              let window = view.window,
              window.isKeyWindow,
              event.windowNumber == window.windowNumber,
              let current = NSApp.currentEvent,
              current.type == event.eventType,
              current.windowNumber == event.windowNumber,
              current.eventNumber == event.eventNumber,
              current.buttonNumber == event.appKitButtonNumber,
              current.clickCount == event.clickCount,
              ScreenPointerEvent.canonicalDownType(
                appKitButtonNumber: current.buttonNumber) == current.type,
              ScreenPointerEvent.canonicalElysiumButton(
                appKitButtonNumber: current.buttonNumber) == event.button else { return false }
        let flags = current.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return flags.contains(.command) == event.command
            && flags.contains(.shift) == event.shift
            && flags.contains(.option) == event.option
            && flags.contains(.control) == event.control
    }

    private func allocateTextScreenIdentity() -> UInt64? {
        guard !textIdentityExhausted else { return nil }
        let next = nextTextScreenIdentity.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue != 0 else {
            textIdentityExhausted = true
            return nil
        }
        nextTextScreenIdentity = next.partialValue
        return next.partialValue
    }

    @discardableResult
    private func advanceTextPresentation(for screen: Screen) -> Bool {
        textFocusTransaction.cancel()
        guard let generation = textPresentationClock.next() else {
            screen.textPresentationGeneration = 0
            screen.clearTextFocus()
            return false
        }
        screen.textPresentationGeneration = generation
        return true
    }

    fileprivate func claimTextFocusAuthorization(_ authorization: TextFocusAuthorization,
                                                 for screen: Screen) -> String? {
        guard activeTextAuthorization === authorization, !authorization.consumed,
              current() === screen,
              authorization.token.screenIdentity == screen.textScreenIdentity,
              authorization.token.presentationGeneration == screen.textPresentationGeneration else {
            return nil
        }
        authorization.consumed = true
        return authorization.token.descriptorID
    }

    func clearTextReadiness(screen: Screen? = nil, clearLogicalFocus: Bool) {
        textFocusTransaction.cancel()
        activeTextAuthorization = nil
        if clearLogicalFocus { (screen ?? current())?.clearTextFocus() }
    }

    private func ownerToken(screen: Screen, descriptorID: String) -> ElysiumTextOwnerToken {
        ElysiumTextOwnerToken(screenIdentity: screen.textScreenIdentity,
                             presentationGeneration: screen.textPresentationGeneration,
                             descriptorID: descriptorID)
    }

    private func descriptorIsEligible(_ descriptorID: String, screen: Screen,
                                      game: GameCore) -> Bool {
        let matches = screen.textAccessibilityDescriptors(self, game).filter {
            $0.id == descriptorID && $0.enabled && $0.focusable &&
                [$0.frame.x, $0.frame.y, $0.frame.width, $0.frame.height].allSatisfy(\.isFinite) &&
                $0.frame.x >= 0 && $0.frame.y >= 0 && $0.frame.width > 0 && $0.frame.height > 0
        }
        return matches.count == 1
    }

    private func postvalidateTextOwner(_ token: ElysiumTextOwnerToken, screen: Screen,
                                       game: GameCore, expectedValue: String) -> Bool {
        guard current() === screen, token.screenIdentity == screen.textScreenIdentity,
              token.presentationGeneration == screen.textPresentationGeneration,
              descriptorIsEligible(token.descriptorID, screen: screen, game: game),
              screen.ownsTextInput(self, game),
              screen.textOwnerDescriptorID(self, game) == token.descriptorID,
              textInputView?.window?.firstResponder === textInputView else { return false }
        let values = screen.textAccessibilityDescriptors(self, game).filter { $0.id == token.descriptorID }
        return values.count == 1 && values[0].value == expectedValue
    }

    @discardableResult
    func establishOrdinaryTextReadiness(
        screen: Screen, game: GameCore, descriptorID: String,
        cause: OrdinaryTextReadinessCause, clickX: Double? = nil
    ) -> Bool {
        return establishTextReadiness(screen: screen, game: game, descriptorID: descriptorID,
                                      clickX: clickX,
                                      publishLayout: cause.publishesLayoutChange)
    }

    @discardableResult
    func establishAccessibilityTextReadiness(screen: Screen, game: GameCore,
                                             descriptorID: String) -> Bool {
        establishTextReadiness(screen: screen, game: game, descriptorID: descriptorID,
                               clickX: nil, publishLayout: false)
    }

    private func establishTextReadiness(screen: Screen, game: GameCore, descriptorID: String,
                                        clickX: Double?, publishLayout shouldPublishLayout: Bool) -> Bool {
        guard current() === screen, screen.textPresentationGeneration != 0,
              descriptorIsEligible(descriptorID, screen: screen, game: game),
              let view = textInputView else { return false }
        let token = ownerToken(screen: screen, descriptorID: descriptorID)
        guard let expectedValue = screen.textAccessibilityDescriptors(self, game)
            .first(where: { $0.id == descriptorID })?.value else { return false }
        let alreadyReady = screen.ownsTextInput(self, game) &&
            screen.textOwnerDescriptorID(self, game) == descriptorID &&
            view.window?.firstResponder === view
        let focusChanged = !alreadyReady
        var succeeded = false
        defer {
            activeTextAuthorization = nil
            if !succeeded {
                if current() === screen && screen.textPresentationGeneration == token.presentationGeneration {
                    screen.clearTextFocus()
                }
            }
        }
        let result = textFocusTransaction.perform(
            token: token,
            ownerAndResponderAlreadyReady: alreadyReady,
            mutateOwner: {
                let authorization = TextFocusAuthorization.mint(token)
                self.activeTextAuthorization = authorization
                return screen.focusTextDescriptor(authorization: authorization, ui: self,
                                                  clickX: clickX)
            },
            establishResponder: { view.window?.makeFirstResponder(view) == true },
            preNotificationPostvalidate: {
                self.postvalidateTextOwner(token, screen: screen, game: game,
                                           expectedValue: expectedValue)
            },
            publishLayout: {
                self.commitTextAccessibility(screen: screen, game: game)
                if shouldPublishLayout {
                    NSAccessibility.post(element: view, notification: .layoutChanged)
                }
            },
            publishFocus: {
                if focusChanged, NSApp.isActive, view.window?.isKeyWindow == true {
                    NSAccessibility.post(
                        element: view.textAccessibilityElement(id: descriptorID) ?? view,
                        notification: .focusedUIElementChanged)
                }
            },
            takeStatusAnnouncement: {
                screen.consumeTextAccessibilityStatusAnnouncement()
            },
            publishStatusAnnouncement: { announcement in
                NSAccessibility.post(
                    element: view, notification: .announcementRequested,
                    userInfo: [.announcement: announcement,
                               .priority: NSAccessibilityPriorityLevel.high.rawValue])
            },
            postNotificationPostvalidate: {
                self.postvalidateTextOwner(token, screen: screen, game: game,
                                           expectedValue: expectedValue)
            })
        switch result {
        case .committed:
            succeeded = true
            return true
        case .idempotentReady:
            succeeded = true
            if let clickX {
                return screen.placeReadyTextCaret(descriptorID: descriptorID, clickX: clickX)
            }
            return true
        case .coalesced, .rejected:
            succeeded = true
            return false
        case .failed:
            return false
        }
    }

    func reconcileOrdinaryTextOwnerChange(on screen: Screen, game: GameCore,
                                          previousID: String?) {
        guard current() === screen else { return }
        let currentID = screen.textActivationDescriptorID(self, game)
        if let currentID, currentID != previousID {
            let established = establishOrdinaryTextReadiness(
                screen: screen, game: game, descriptorID: currentID,
                cause: .implicitOwnerOpen)
            if !established {
                _ = screen.cancelImplicitTextOwnerActivation()
                clearTextReadiness(screen: screen, clearLogicalFocus: true)
            }
        } else if currentID == nil {
            clearTextReadiness(screen: screen, clearLogicalFocus: false)
        }
    }

    func textIngressIsReady(for screen: Screen, game: GameCore) -> Bool {
        guard current() === screen, !textFocusTransaction.ingressBlocked,
              screen.ownsTextInput(self, game),
              let descriptorID = screen.textOwnerDescriptorID(self, game),
              textInputView?.window?.firstResponder === textInputView else { return false }
        return textFocusTransaction.isReady(ownerToken(screen: screen, descriptorID: descriptorID))
    }

    func textIngressMustBeConsumed(for screen: Screen, game: GameCore) -> Bool {
        textFocusTransaction.ingressBlocked ||
            (screen.textActivationDescriptorID(self, game) != nil &&
             !textIngressIsReady(for: screen, game: game))
    }

    func reactivateTextReadiness(game: GameCore) {
        guard let screen = current(),
              let id = screen.textActivationDescriptorID(self, game) else { return }
        _ = establishOrdinaryTextReadiness(screen: screen, game: game, descriptorID: id,
                                           cause: .applicationReactivation)
    }

    func notifyTextAccessibilityValueChanged(on screen: Screen, game: GameCore) {
        guard current() === screen, textIngressIsReady(for: screen, game: game),
              let view = textInputView else { return }
        commitTextAccessibility(screen: screen, game: game)
        let descriptorID = screen.textOwnerDescriptorID(self, game)
        NSAccessibility.post(element: descriptorID.flatMap(view.textAccessibilityElement(id:)) ?? view,
                             notification: .valueChanged)
        if let announcement = screen.consumeTextAccessibilityStatusAnnouncement() {
            NSAccessibility.post(
                element: view, notification: .announcementRequested,
                userInfo: [.announcement: announcement,
                           .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func postTextAccessibilityLayoutIfPresent(screen: Screen, game: GameCore) {
        guard current() === screen, let view = textInputView,
              !screen.textAccessibilityDescriptors(self, game).isEmpty else { return }
        commitTextAccessibility(screen: screen, game: game)
        NSAccessibility.post(element: view, notification: .layoutChanged)
        let focused = screen.textAccessibilityDescriptors(self, game).filter {
            $0.focused && $0.enabled && $0.focusable
        }
        if focused.count == 1 {
            _ = publishOrdinaryAccessibilityFocus(
                screen: screen, game: game, descriptorID: focused[0].id)
        }
        if let announcement = screen.consumeTextAccessibilityStatusAnnouncement() {
            NSAccessibility.post(
                element: view, notification: .announcementRequested,
                userInfo: [.announcement: announcement,
                           .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    private func commitTextAccessibility(screen: Screen, game: GameCore) {
        guard current() === screen, screen.textPresentationGeneration != 0 else {
            textAccessibilityDidInvalidate?()
            return
        }
        textAccessibilityDidCommit?(screen, screen.textAccessibilityDescriptors(self, game))
    }

    @discardableResult
    func publishOrdinaryAccessibilityFocus(
        screen: Screen, game: GameCore, descriptorID: String
    ) -> Bool {
        elysiumMainActorSync {
            guard current() === screen, screen.textPresentationGeneration != 0,
                  let view = textInputView, NSApp.isActive,
                  view.window?.isKeyWindow == true, view.window?.firstResponder === view else {
                return false
            }
            let generation = screen.textPresentationGeneration
            let matches = screen.textAccessibilityDescriptors(self, game).filter {
                $0.id == descriptorID && $0.enabled && $0.focusable && $0.focused
            }
            guard matches.count == 1 else { return false }
            commitTextAccessibility(screen: screen, game: game)
            guard current() === screen, screen.textPresentationGeneration == generation,
                  let element = view.textAccessibilityElement(id: descriptorID),
                  !element.retired, element.originScreen === screen,
                  element.presentationGeneration == generation,
                  element.isAccessibilityFocused() else { return false }
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
            let post = screen.textAccessibilityDescriptors(self, game).filter {
                $0.id == descriptorID && $0.enabled && $0.focusable && $0.focused
            }
            return current() === screen && screen.textPresentationGeneration == generation &&
                post.count == 1 && !element.retired && element.isAccessibilityFocused()
        }
    }

    /// Retires every previously published canvas AX child before a screen
    /// publishes a new action generation. Destructive screens call this at
    /// every request/lease/state transition so stale Press objects cannot be
    /// rebound to a newer operation.
    func renewTextAccessibilityPresentation(screen: Screen, game: GameCore) {
        guard current() === screen, advanceTextPresentation(for: screen) else {
            textAccessibilityDidInvalidate?()
            return
        }
        commitTextAccessibility(screen: screen, game: game)
        if let view = textInputView {
            NSAccessibility.post(element: view, notification: .layoutChanged)
        }
    }

    @discardableResult
    func commitPassiveRPGSemanticModel(_ model: RPGScreenModel,
                                       to screen: Screen) -> RPGPassiveSemanticSnapshot? {
        guard model.descriptors.allSatisfy({ $0.actionCommand == nil }),
              model.visibleDescriptors.allSatisfy({ $0.actionCommand == nil }) else {
            screen.rpgPassiveSemanticSnapshot = nil
            screen.rpgPassiveSemanticUnavailable = true
            if current() === screen { invalidateRPGAccessibilityCache() }
            return nil
        }
        let instanceID: UInt64
        if let existing = screen.rpgPassiveScreenInstanceID {
            instanceID = existing
        } else if let allocated = rpgPassiveSemanticClock.allocateScreenInstanceID() {
            instanceID = allocated
            screen.rpgPassiveScreenInstanceID = allocated
        } else {
            screen.rpgPassiveSemanticSnapshot = nil
            screen.rpgPassiveSemanticUnavailable = true
            if current() === screen { invalidateRPGAccessibilityCache() }
            return nil
        }
        guard let revision = rpgPassiveSemanticClock.nextSemanticRevision(
                after: screen.rpgPassiveSemanticRevision),
              let snapshot = RPGPassiveSemanticSnapshot(
                screenInstanceID: instanceID, semanticRevision: revision, model: model) else {
            screen.rpgPassiveSemanticSnapshot = nil
            screen.rpgPassiveSemanticUnavailable = true
            if current() === screen { invalidateRPGAccessibilityCache() }
            return nil
        }
        screen.rpgPassiveSemanticRevision = revision
        screen.rpgPassiveSemanticSnapshot = snapshot
        screen.rpgPassiveSemanticUnavailable = false
        if current() === screen { invalidateRPGAccessibilityCache() }
        return snapshot
    }

    @discardableResult
    func commitRPGSemanticModel(_ model: RPGScreenModel, runtime: RPGScreenRuntimeSnapshot,
                                to screen: Screen) -> RPGCommittedSemanticSnapshot? {
        let instanceID: UInt64
        if let existing = screen.rpgPassiveScreenInstanceID {
            instanceID = existing
        } else if let allocated = rpgPassiveSemanticClock.allocateScreenInstanceID() {
            instanceID = allocated
            screen.rpgPassiveScreenInstanceID = allocated
        } else {
            screen.rpgCommittedSemanticSnapshot = nil
            screen.rpgPassiveSemanticUnavailable = true
            if current() === screen { invalidateRPGAccessibilityCache() }
            return nil
        }
        guard let revision = rpgPassiveSemanticClock.nextSemanticRevision(
                after: screen.rpgPassiveSemanticRevision),
              let snapshot = RPGCommittedSemanticSnapshot(
                screenInstanceID: instanceID, semanticRevision: revision,
                model: model, runtime: runtime) else {
            screen.rpgCommittedSemanticSnapshot = nil
            screen.rpgPassiveSemanticUnavailable = true
            if current() === screen { invalidateRPGAccessibilityCache() }
            return nil
        }
        screen.rpgPassiveSemanticRevision = revision
        screen.rpgCommittedSemanticSnapshot = snapshot
        screen.rpgPassiveSemanticSnapshot = nil
        screen.rpgPassiveSemanticUnavailable = false
        if current() === screen { publishRPGAccessibilityCommit(snapshot, screen: screen) }
        return snapshot
    }

    private func publishRPGAccessibilityCommit(_ snapshot: RPGCommittedSemanticSnapshot,
                                               screen: Screen) {
        guard current() === screen else {
            invalidateRPGAccessibilityCache()
            return
        }
        guard let tree: RPGAccessibilityTreeSnapshot = rpgAccessibilityPublicationClock.publish({
            generation in
            guard let viewport = RPGAccessibilityViewport(width: width, height: height) else {
                return nil
            }
            return RPGAccessibilityTreeSnapshot(
                committed: snapshot, layoutGeneration: generation, viewport: viewport)
        }) else {
            invalidateRPGAccessibilityCache()
            return
        }
        rpgAccessibilityDidCommit?(screen, tree)
    }

    func invalidateRPGAccessibilityCache() {
        rpgAccessibilityDidInvalidate?()
    }

#if DEBUG
    /// Representative/exhaustion seam; production input cannot modify snapshot identity state.
    func debugSetRPGPassiveSemanticClock(_ clock: RPGPassiveSemanticClock) {
        rpgPassiveSemanticClock = clock
    }
#endif

    func resize(_ pw: Double, _ ph: Double, _ guiScaleSetting: Int, relayout game: GameCore? = nil) {
        let auto = max(1.0, min((pw / 380).rounded(.down), (ph / 240).rounded(.down)))
        let newScale = guiScaleSetting == 0 ? auto : min(Double(guiScaleSetting), auto)
        let newWidth = (pw / newScale).rounded(.up)
        let newHeight = (ph / newScale).rounded(.up)
        let changed = newScale != scale || newWidth != width || newHeight != height
        scale = newScale
        width = newWidth
        height = newHeight
        // Rebuild resize-dependent controls through the screen's relayout
        // boundary, carrying typed field state over. Stateful screens override
        // this boundary so resize never re-enters load/mutation initialization.
        guard changed, let game else { return }
        let currentOwnerID = current()?.textActivationDescriptorID(self, game)
        for s in stack {
            struct SavedField {
                let text: String
                let caret: Int
                let focused: Bool
            }
            var savedByID: [String: SavedField] = [:]
            let oldGroups = Dictionary(grouping: s.fields, by: \.id)
            for (id, values) in oldGroups where values.count == 1 {
                let field = values[0]
                savedByID[id] = SavedField(text: field.text, caret: field.caret,
                                            focused: field.focused)
            }
            s.relayoutScreen(self, game)
            let newGroups = Dictionary(grouping: s.fields, by: \.id)
            var restoredFocus = false
            for (id, values) in newGroups where values.count == 1 {
                guard oldGroups[id]?.count == 1, let saved = savedByID[id] else { continue }
                let field = values[0]
                _ = field.replaceText(saved.text, caret: saved.caret)
                field.focused = saved.focused && !restoredFocus
                restoredFocus = restoredFocus || field.focused
            }
            for (_, values) in newGroups where values.count > 1 {
                values.forEach { $0.focused = false }
            }
            _ = advanceTextPresentation(for: s)
        }
        if let screen = current(), let currentOwnerID {
            _ = establishOrdinaryTextReadiness(screen: screen, game: game,
                                               descriptorID: currentOwnerID,
                                               cause: .resizeRenewal)
        } else if let screen = current() {
            postTextAccessibilityLayoutIfPresent(screen: screen, game: game)
        }
        if !(current() is RPGCharacterScreen) { invalidateRPGAccessibilityCache() }
    }

    @MainActor
    func retainSavedWorldMaintenanceOperation(
        _ owner: AnyObject, game: GameCore,
        token: SavedWorldMaintenanceCoordinator.Token
    ) -> Bool {
        guard savedWorldMaintenanceOperationOwner == nil,
              game.revalidateSavedWorldMaintenance(token) else { return false }
        savedWorldMaintenanceOperationOwner = owner
        return true
    }

    @MainActor
    func releaseSavedWorldMaintenanceOperation(_ owner: AnyObject) {
        guard savedWorldMaintenanceOperationOwner === owner else { return }
        savedWorldMaintenanceOperationOwner = nil
    }

    func open(_ s: Screen, _ game: GameCore) {
        elysiumMainActorSync { openIsolated(s, game) }
    }

    @MainActor
    private func openIsolated(_ s: Screen, _ game: GameCore) {
        guard game.savedWorldMaintenanceAllowsTransitions() else { return }
        // release held movement/mouse state — keys held when a screen opens
        // never get their keyUp (the screen eats it) and stick otherwise
        if stack.isEmpty { game.clearInput() }
        stack.last?.inputOwnershipLost(self, game)
        guard let identity = allocateTextScreenIdentity() else { return }
        s.textScreenIdentity = identity
        stack.append(s)
        s.initScreen(self, game)
        _ = advanceTextPresentation(for: s)
        commitTextAccessibility(screen: s, game: game)
        if let id = s.textActivationDescriptorID(self, game) {
            let cause: OrdinaryTextReadinessCause = s.fields.isEmpty ? .implicitOwnerOpen : .initialOpen
            let established = establishOrdinaryTextReadiness(
                screen: s, game: game, descriptorID: id, cause: cause)
            if !established, s.fields.isEmpty {
                closeTopIsolated(game)
                return
            }
        } else {
            postTextAccessibilityLayoutIfPresent(screen: s, game: game)
        }
        if s.semanticSnapshot == nil { invalidateRPGAccessibilityCache() }
        rpgControllerContextDidChange?()
    }
    func replace(_ s: Screen, _ game: GameCore) {
        elysiumMainActorSync { replaceIsolated(s, game) }
    }

    @MainActor
    private func replaceIsolated(_ s: Screen, _ game: GameCore) {
        guard game.savedWorldMaintenanceAllowsTransitions() else { return }
        closeTopIsolated(game)
        openIsolated(s, game)
    }
    func closeTop(_ game: GameCore) {
        elysiumMainActorSync { closeTopIsolated(game) }
    }

    @MainActor
    private func closeTopIsolated(_ game: GameCore) {
        guard game.savedWorldMaintenanceAllowsTransitions() else { return }
        clearTextReadiness(screen: stack.last, clearLogicalFocus: false)
        accessibilityDidInvalidateAll?()
        if let view = textInputView {
            NSAccessibility.post(element: view, notification: .layoutChanged)
        }
        stack.last?.inputOwnershipLost(self, game)
        if let top = stack.popLast() {
            top.textPresentationGeneration = 0
            top.onClose(self, game)
        }
        if stack.isEmpty, let c = cursorStack {
            // drop the cursor stack back into player inventory
            _ = game.player?.give(c)
            cursorStack = nil
        }
        if let revealed = stack.last as? RPGCharacterScreen {
            revealed.initScreen(self, game)
        }
        if let revealed = stack.last {
            _ = advanceTextPresentation(for: revealed)
            commitTextAccessibility(screen: revealed, game: game)
            if let id = revealed.textActivationDescriptorID(self, game) {
                _ = establishOrdinaryTextReadiness(screen: revealed, game: game,
                                                   descriptorID: id, cause: .screenReveal)
            }
        }
        rpgControllerContextDidChange?()
    }
    func closeAll(_ game: GameCore) {
        elysiumMainActorSync { closeAllIsolated(game) }
    }

    @MainActor
    private func closeAllIsolated(_ game: GameCore) {
        while !stack.isEmpty { closeTopIsolated(game) }
    }
    func current() -> Screen? { stack.last }
    func hasScreen() -> Bool { !stack.isEmpty }

    struct TextOwnerCapture {
        weak var screen: Screen?
        let token: ElysiumTextOwnerToken
    }

    func captureTextOwner(game: GameCore) -> TextOwnerCapture? {
        guard let screen = current(), screen.textPresentationGeneration != 0,
              textIngressIsReady(for: screen, game: game),
              screen.ownsTextInput(self, game),
              let descriptorID = screen.textOwnerDescriptorID(self, game) else { return nil }
        return TextOwnerCapture(screen: screen, token: ElysiumTextOwnerToken(
            screenIdentity: screen.textScreenIdentity,
            presentationGeneration: screen.textPresentationGeneration,
            descriptorID: descriptorID))
    }

    func revalidateTextOwner(_ capture: TextOwnerCapture, game: GameCore) -> Screen? {
        guard let screen = capture.screen, current() === screen,
              screen.textScreenIdentity == capture.token.screenIdentity,
              screen.textPresentationGeneration == capture.token.presentationGeneration,
              textFocusTransaction.isReady(capture.token),
              textInputView?.window?.firstResponder === textInputView,
              screen.ownsTextInput(self, game),
              screen.textOwnerDescriptorID(self, game) == capture.token.descriptorID else { return nil }
        return screen
    }

    func refreshCurrentRPGScreen(_ refresh: RPGLocalPreferenceUIRefresh, game: GameCore) {
        guard let screen = current() as? RPGCharacterScreen,
              let snapshot = screen.rpgCommittedSemanticSnapshot,
              snapshot.worldEntryGeneration == refresh.worldEntryGeneration,
              refresh.localPreferenceRevision >= snapshot.localPreferenceRevision else { return }
        screen.initScreen(self, game)
    }

    func setRPGControllerHelpPrimary(_ primary: Bool, game: GameCore) {
        guard rpgControllerHelpPrimary != primary else { return }
        rpgControllerHelpPrimary = primary
        (current() as? RPGCharacterScreen)?.initScreen(self, game)
    }

    @MainActor
    func captureRPGAccessibilityActivation(
        origin: RPGSemanticActivationOrigin
    ) -> RPGSemanticActivationCapture? {
        let boundary: RPGSemanticActivationBoundary
        if let existing = rpgSemanticActivationBoundary { boundary = existing }
        else {
            let created = RPGSemanticActivationBoundary()
            rpgSemanticActivationBoundary = created
            boundary = created
        }
        return boundary.capture(origin: origin)
    }

    @MainActor
    func dispatchRPGAccessibilityActivation(
        _ capture: RPGSemanticActivationCapture,
        on originScreen: Screen?,
        game: GameCore
    ) -> RPGSemanticActivationResult {
        guard let originScreen else {
            cancelRPGSemanticActivation(capture)
            return .unavailable
        }
        return dispatchRPGSemanticActivation(
            capture, source: .accessibility, on: originScreen, game: game)
    }

    @MainActor
    func focusRPGAccessibilityElement(screenInstanceID: UInt64,
                                      semanticRevision: UInt64,
                                      id: RPGUIElementID,
                                      on screen: Screen,
                                      game: GameCore) -> Bool {
        guard current() === screen,
              let snapshot = screen.semanticSnapshot,
              snapshot.screenInstanceID == screenInstanceID,
              snapshot.semanticRevision == semanticRevision,
              snapshot.model.descriptors.contains(where: {
                $0.id == id && $0.isFocusable
              }) else { return false }
        return screen.focusSemanticElement(id, self, game)
    }

    /// Sole guarded synthetic boundary for RPG world commands, shared by keyboard and controller.
    @MainActor
    @discardableResult
    func dispatchRPGWorldSemanticCommand(_ command: RPGSemanticCommand,
                                         source: RPGSemanticActivationSource,
                                         game: GameCore) -> RPGSemanticActivationResult {
        guard game.hasWorld(), !hasScreen() else { return .unavailable }
        if command == .openCharacter, game.player?.rpgClassesEnabled() != true { return .unavailable }
        guard !worldSemanticRevisionExhausted, !worldScreenInstanceIDExhausted else {
            return .unavailable
        }
        let instanceAddition = lastWorldScreenInstanceID.addingReportingOverflow(1)
        guard !instanceAddition.overflow, instanceAddition.partialValue != 0 else {
            worldScreenInstanceIDExhausted = true
            return .unavailable
        }
        lastWorldScreenInstanceID = instanceAddition.partialValue
        let revisionAddition = nextWorldSemanticRevision.addingReportingOverflow(1)
        guard !revisionAddition.overflow, revisionAddition.partialValue != 0 else {
            worldSemanticRevisionExhausted = true
            return .unavailable
        }
        nextWorldSemanticRevision = revisionAddition.partialValue
        guard let id = RPGUIElementID(rawValue: "world-input:\(revisionAddition.partialValue)") else {
            return .unavailable
        }
        let descriptor = RPGSemanticDescriptor(
            id: id, role: .button, label: "RPG world action", enabled: true,
            isFocusable: true, frame: RPGLogicalRect(x: 0, y: 0, width: 1, height: 1),
            visibleFrame: RPGLogicalRect(x: 0, y: 0, width: 1, height: 1),
            actionCommand: command)
        guard let capture = captureSyntheticRPGSemanticActivation(
            descriptor, screenInstanceID: instanceAddition.partialValue,
            semanticRevision: revisionAddition.partialValue, game: game) else {
            return .unavailable
        }
        let result = dispatchSyntheticRPGSemanticActivation(
            capture, source: source, screenInstanceID: instanceAddition.partialValue,
            semanticRevision: revisionAddition.partialValue, descriptor: descriptor, game: game)
        if case .dispatched = result, command == .openCharacter {
            game.openScreen("rpg", nil)
        }
        return result
    }

    @MainActor
    func captureSyntheticRPGSemanticActivation(
        _ descriptor: RPGSemanticDescriptor,
        screenInstanceID: UInt64,
        semanticRevision: UInt64,
        game: GameCore
    ) -> RPGSemanticActivationCapture? {
        let boundary: RPGSemanticActivationBoundary
        if let existing = rpgSemanticActivationBoundary {
            boundary = existing
        } else {
            let created = RPGSemanticActivationBoundary()
            rpgSemanticActivationBoundary = created
            boundary = created
        }
        return game.captureSyntheticRPGSemanticActivation(
            using: boundary,
            screenInstanceID: screenInstanceID,
            semanticRevision: semanticRevision,
            descriptor: descriptor
        )
    }

    @MainActor
    func dispatchSyntheticRPGSemanticActivation(
        _ capture: RPGSemanticActivationCapture,
        source: RPGSemanticActivationSource,
        screenInstanceID: UInt64,
        semanticRevision: UInt64,
        descriptor: RPGSemanticDescriptor?,
        game: GameCore
    ) -> RPGSemanticActivationResult {
        let boundary: RPGSemanticActivationBoundary
        if let existing = rpgSemanticActivationBoundary {
            boundary = existing
        } else {
            let created = RPGSemanticActivationBoundary()
            rpgSemanticActivationBoundary = created
            boundary = created
        }
        let protocol5TransportRejected = descriptor?.actionCommand.flatMap {
            LANMultiplayerManager.shared.rejectProtocol5RPGSemanticOperation($0, in: game)
        } == .unavailable
        return game.dispatchSyntheticRPGSemanticActivation(
            capture, source: source, using: boundary,
            screenInstanceID: screenInstanceID, semanticRevision: semanticRevision,
            descriptor: descriptor,
            protocol5TransportRejected: protocol5TransportRejected
        )
    }

    /// Sole production capture path. The command and semantic input come from the same committed
    /// immutable publication; no mutable GameCore value is consulted until dispatch revalidation.
    @MainActor
    func captureRPGSemanticActivation(id: RPGUIElementID,
                                      on screen: Screen) -> RPGSemanticActivationCapture? {
        guard current() === screen,
              let snapshot = screen.rpgCommittedSemanticSnapshot,
              let descriptor = snapshot.model.descriptors.first(where: { $0.id == id }),
              let input = snapshot.semanticInputs[id] else { return nil }
        let boundary: RPGSemanticActivationBoundary
        if let existing = rpgSemanticActivationBoundary { boundary = existing }
        else {
            let created = RPGSemanticActivationBoundary()
            rpgSemanticActivationBoundary = created
            boundary = created
        }
        return boundary.capture(screenInstanceID: snapshot.screenInstanceID,
                                semanticRevision: snapshot.semanticRevision,
                                descriptor: descriptor, input: input)
    }

    @MainActor
    func cancelRPGSemanticActivation(_ capture: RPGSemanticActivationCapture) {
        _ = rpgSemanticActivationBoundary?.cancel(capture)
    }

    /// Sole production dispatch path for every modality. The boundary consumes before current-state
    /// revalidation. A stale genuine activation rebuilds once and is never replayed automatically.
    @MainActor
    func dispatchRPGSemanticActivation(_ capture: RPGSemanticActivationCapture,
                                       source: RPGSemanticActivationSource,
                                       on screen: Screen, game: GameCore) -> RPGSemanticActivationResult {
        let boundary: RPGSemanticActivationBoundary
        if let existing = rpgSemanticActivationBoundary { boundary = existing }
        else {
            let created = RPGSemanticActivationBoundary()
            rpgSemanticActivationBoundary = created
            boundary = created
        }
        guard current() === screen else {
            _ = boundary.cancel(capture)
            return .unavailable
        }
        let snapshot = screen.rpgCommittedSemanticSnapshot
        let descriptor = snapshot?.model.descriptors.first { $0.id == capture.id }
        let command = descriptor?.actionCommand
        let protocol5TransportRejected = command.flatMap {
            LANMultiplayerManager.shared.rejectProtocol5RPGSemanticOperation($0, in: game)
        } == .unavailable
        let result = game.dispatchSyntheticRPGSemanticActivation(
            capture, source: source, using: boundary,
            screenInstanceID: snapshot?.screenInstanceID ?? 0,
            semanticRevision: snapshot?.semanticRevision ?? 0,
            descriptor: descriptor,
            protocol5TransportRejected: protocol5TransportRejected)
        switch result {
        case .dispatched:
            if let command { _ = screen.handleRPGPresentationCommand(command, self, game) }
            if current() === screen { screen.initScreen(self, game) }
        case .staleRequiresFreshActivation:
            if current() === screen { screen.initScreen(self, game) }
        default:
            break
        }
        return result
    }

    // ---- frame ----------------------------------------------------------------
    func beginFrame() {
        // canvas in GUI units; the flush uniform needs the pixel framebuffer size
        cv.begin(width * scale, height * scale)
        cv.scale(scale, scale)
        tooltipLines = nil
    }
    func endFrame() {
        if let c = cursorStack {
            drawItemStack(c, mouseX - 8, mouseY - 8)
        }
        if let lines = tooltipLines, !lines.isEmpty {
            drawTooltipBox(lines, mouseX + 6, mouseY - 6)
        }
    }

    // ---- pack GUI sheets ----------------------------------------------------------
    func hasSheet(_ s: String) -> Bool { packUI?.sheets.contains(s) ?? false }

    /// Blit a base-px region of a pack GUI sheet. Composite coordinates are
    /// logical, so callers are independent of the prepared pack's raster scale.
    /// Returns false when the sheet isn't loaded so callers can fall back.
    @discardableResult
    func blitSheet(_ sheet: String, _ sx: Double, _ sy: Double, _ sw: Double, _ sh: Double,
                   _ dx: Double, _ dy: Double, _ dw: Double? = nil, _ dh: Double? = nil,
                   tint: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1)) -> Bool {
        guard let p = packUI, p.sheets.contains(sheet), let cell = PackUI.CELLS[sheet] else { return false }
        cv.guiQuad(Double(cell.0) + sx, Double(cell.1) + sy, sw, sh,
                   dx, dy, dw ?? sw, dh ?? sh, tint)
        return true
    }

    // ---- drawing helpers --------------------------------------------------------
    func drawPanel(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
        cv.setFill("#c6c6c6")
        cv.fillRect(x + 1, y + 1, w - 2, h - 2)
        cv.setFill("#ffffff")
        cv.fillRect(x + 1, y, w - 2, 1)
        cv.fillRect(x, y + 1, 1, h - 2)
        cv.setFill("#555555")
        cv.fillRect(x + 1, y + h - 1, w - 2, 1)
        cv.fillRect(x + w - 1, y + 1, 1, h - 2)
        cv.setFill("#000000")
        cv.fillRect(x + 2, y - 1, w - 4, 1)
        cv.fillRect(x + 2, y + h, w - 4, 1)
        cv.fillRect(x - 1, y + 2, 1, h - 4)
        cv.fillRect(x + w, y + 2, 1, h - 4)
    }
    func drawSlotBg(_ x: Double, _ y: Double) {
        cv.setFill("#8b8b8b")
        cv.fillRect(x, y, 18, 18)
        cv.setFill("#373737")
        cv.fillRect(x, y, 17, 1)
        cv.fillRect(x, y, 1, 17)
        cv.setFill("#ffffff")
        cv.fillRect(x + 1, y + 17, 17, 1)
        cv.fillRect(x + 17, y + 1, 1, 17)
    }
    func drawItemStack(_ s: ItemStack, _ x: Double, _ y: Double) {
        cv.drawItemIcon(s.id, s.data, x + 1, y + 1, 16, 16)
        // enchant glint
        if !s.ench.isEmpty || itemDef(s.id).name == "enchanted_golden_apple" {
            cv.setFill("rgba(160,80,255,0.22)")
            cv.fillRect(x + 1, y + 1, 16, 16)
        }
        // durability bar
        let maxD = itemDef(s.id).tool?.durability ?? itemDef(s.id).armor?.durability ?? 0
        if maxD > 0 && s.damage > 0 {
            let f = 1 - Double(s.damage) / Double(maxD)
            cv.setFill("#000000")
            cv.fillRect(x + 2, y + 15, 14, 2)
            cv.setFill(f > 0.5 ? "#40c040" : f > 0.25 ? "#e8d83c" : "#e84040")
            cv.fillRect(x + 2, y + 15, max(1, (14 * f).rounded()), 1)
        }
        if s.count > 1 {
            cv.drawText(String(s.count), x + 18 - Double(textWidth(String(s.count))) - 1, y + 10, 1)
        }
    }
    func drawSlot(_ s: SlotDef, _ hover: Bool, slotBg: Bool = true) {
        if slotBg { drawSlotBg(s.x, s.y) }
        let stack = s.get()
        if let stack { drawItemStack(stack, s.x, s.y) }
        if hover {
            cv.setFill("rgba(255,255,255,0.45)")
            cv.fillRect(s.x + 1, s.y + 1, 16, 16)
            if let stack { tooltipLines = itemTooltip(stack) }
        }
    }
    func drawSlots(_ screen: Screen, slotBg: Bool = true) {
        for s in screen.slots {
            let hover = mouseX >= s.x && mouseX < s.x + 18 && mouseY >= s.y && mouseY < s.y + 18
            drawSlot(s, hover, slotBg: slotBg)
        }
    }
    func drawButton(_ b: Button, _ hover: Bool) {
        if !b.visible { return }
        if let craftButton = b as? CraftAmountButton {
            drawCraftAmountButton(craftButton, hover)
            return
        }
        if let cb = b as? CheckBox {
            let box = 10.0
            let by = b.y + ((b.h - box) / 2).rounded(.down)
            cv.setFill(hover ? "#d8d8d8" : "#c6c6c6")
            cv.fillRect(b.x, by, box, box)
            cv.setFill("#373737")
            cv.fillRect(b.x, by, box, 1)
            cv.fillRect(b.x, by, 1, box)
            cv.setFill("#ffffff")
            cv.fillRect(b.x + 1, by + box - 1, box - 1, 1)
            cv.fillRect(b.x + box - 1, by + 1, 1, box - 1)
            if cb.isChecked() {
                cv.drawText("x", b.x + 2, by + 1, 1, "#202020", shadow: false)
            }
            cv.drawText(cb.label, b.x + box + 4, b.y + ((b.h - 8) / 2).rounded(.down), 1,
                        hover ? "#ffffff" : "#e0e0e0")
            return
        }
        // vanilla widgets.png strips: 46 disabled / 66 normal / 86 hover, 200×20,
        // blitted as left+right halves so any width keeps both end caps
        if b.w <= 200, hasSheet("widgets") {
            let sy = b.enabled ? (hover ? 86.0 : 66.0) : 46.0
            let half = (b.w / 2).rounded(.down)
            blitSheet("widgets", 0, sy, half, 20, b.x, b.y, half, b.h)
            blitSheet("widgets", 200 - (b.w - half), sy, b.w - half, 20, b.x + half, b.y, b.w - half, b.h)
            cv.drawTextCentered(b.label, b.x + b.w / 2, b.y + (b.h - 8) / 2, 1, b.enabled ? "#ffffff" : "#a0a0a0")
            return
        }
        cv.setFill(b.enabled ? (hover ? "#7a8cbf" : "#6f6f6f") : "#3f3f3f")
        cv.fillRect(b.x, b.y, b.w, b.h)
        cv.setFill(b.enabled ? (hover ? "#aab8e0" : "#a0a0a0") : "#555555")
        cv.fillRect(b.x, b.y, b.w, 1)
        cv.fillRect(b.x, b.y, 1, b.h)
        cv.setFill("#2a2a2a")
        cv.fillRect(b.x, b.y + b.h - 1, b.w, 1)
        cv.fillRect(b.x + b.w - 1, b.y, 1, b.h)
        cv.drawTextCentered(b.label, b.x + b.w / 2, b.y + (b.h - 8) / 2, 1, b.enabled ? "#ffffff" : "#a0a0a0")
    }
    private func drawCraftAmountButton(_ b: CraftAmountButton, _ hover: Bool) {
        let face = b.enabled ? (hover ? "#b8b8b8" : "#9a9a9a") : "#5c5c5c"
        cv.setFill(face)
        cv.fillRect(b.x, b.y, b.w, b.h)
        cv.setFill(b.enabled ? "#f2f2f2" : "#7a7a7a")
        cv.fillRect(b.x, b.y, b.w, 1)
        cv.fillRect(b.x, b.y, 1, b.h)
        cv.setFill("#1f1f1f")
        cv.fillRect(b.x, b.y + b.h - 1, b.w, 1)
        cv.fillRect(b.x + b.w - 1, b.y, 1, b.h)

        let arrow = b.enabled ? "#ffffff" : "#9a9a9a"
        let shadow = b.enabled ? "#505050" : "#3a3a3a"
        drawCraftAmountChevron(b, color: shadow, offsetX: 1, offsetY: 1)
        drawCraftAmountChevron(b, color: arrow, offsetX: 0, offsetY: 0)
    }
    private func drawCraftAmountChevron(_ b: CraftAmountButton, color: String, offsetX: Double, offsetY: Double) {
        cv.setFill(color)
        let cx = (b.x + b.w / 2).rounded(.down) + offsetX
        let top = b.y + 2 + offsetY
        for row in 0..<4 {
            let r = Double(row)
            switch b.direction {
            case .up:
                cv.fillRect(cx - 1 - r, top + r, 2, 1)
                cv.fillRect(cx + r, top + r, 2, 1)
            case .down:
                cv.fillRect(cx - 4 + r, top + r, 2, 1)
                cv.fillRect(cx + 3 - r, top + r, 2, 1)
            }
        }
    }
    func drawButtons(_ screen: Screen) {
        for b in screen.buttons where !(b is Slider) {
            drawButton(b, b.contains(mouseX, mouseY))
        }
        for s in screen.sliders {
            if s.w <= 200, hasSheet("widgets") {
                // vanilla slider: disabled-strip track + 8px handle
                let half = (s.w / 2).rounded(.down)
                blitSheet("widgets", 0, 46, half, 20, s.x, s.y, half, s.h)
                blitSheet("widgets", 200 - (s.w - half), 46, s.w - half, 20, s.x + half, s.y, s.w - half, s.h)
                let v = s.getValue()
                let hx = (s.x + v * (s.w - 8)).rounded()
                let hover = s.contains(mouseX, mouseY) || s.dragging
                blitSheet("widgets", 0, hover ? 86 : 66, 4, 20, hx, s.y, 4, s.h)
                blitSheet("widgets", 196, hover ? 86 : 66, 4, 20, hx + 4, s.y, 4, s.h)
                cv.drawTextCentered(s.getLabel(), s.x + s.w / 2, s.y + (s.h - 8) / 2, 1)
                continue
            }
            cv.setFill("#3f3f3f")
            cv.fillRect(s.x, s.y, s.w, s.h)
            cv.setFill("#1c1c1c")
            cv.fillRect(s.x, s.y, s.w, 1)
            let v = s.getValue()
            let hx = s.x + 2 + v * (s.w - 10)
            cv.setFill("#8a8a8a")
            cv.fillRect(hx, s.y + 1, 6, s.h - 2)
            cv.setFill("#c8c8c8")
            cv.fillRect(hx, s.y + 1, 6, 2)
            cv.drawTextCentered(s.getLabel(), s.x + s.w / 2, s.y + (s.h - 8) / 2, 1)
        }
        for f in screen.fields {
            cv.setFill("#000000")
            cv.fillRect(f.x, f.y, f.w, f.h)
            cv.setStroke(f.focused ? "#ffffff" : "#a0a0a0")
            cv.strokeRect(f.x, f.y, f.w, f.h)
            let presentation = f.visiblePresentation(measure: textWidth)
            if f.text.isEmpty && !f.placeholder.isEmpty {
                var boundedPlaceholder = ""
                for character in f.placeholder {
                    let candidate = boundedPlaceholder + String(character)
                    if textWidth(candidate) > Int(f.w - 9) { break }
                    boundedPlaceholder = candidate
                }
                cv.drawText(boundedPlaceholder, f.x + 4, f.y + (f.h - 8) / 2, 1,
                            "#5a5a5a", shadow: false)
            } else {
                cv.drawText(presentation.text, f.x + 4, f.y + (f.h - 8) / 2, 1,
                            "#ffffff", shadow: false)
            }
            if f.focused && Int(CACurrentMediaTime() * 1000 / 400) % 2 == 0 {
                let cx = min(f.x + f.w - 4, presentation.caretX)
                cv.setFill("#ffffff")
                cv.fillRect(cx, f.y + 3, 1, f.h - 6)
            }
        }
    }
    func drawDarkBg(_ alpha: Double = 0.6) {
        cv.setFill("rgba(8,8,12,\(alpha))")
        cv.fillRect(0, 0, width, height)
    }
    func drawDirtBg() {
        if hasSheet("bg") {
            // vanilla options background: 16px texture tiled every 32 GUI px, ×0.25 tint
            let tint = SIMD4<Float>(0.25, 0.25, 0.25, 1)
            var y = 0.0
            while y < height {
                var x = 0.0
                while x < width {
                    blitSheet("bg", 0, 0, 16, 16, x, y, 32, 32, tint: tint)
                    x += 32
                }
                y += 32
            }
            return
        }
        cv.setFill("#3a2a1e")
        cv.fillRect(0, 0, width, height)
        var y = 0.0
        while y < height {
            var x = 0.0
            while x < width {
                let xi = Int(x), yi = Int(y)
                let h = ((xi * 31 + yi * 17) ^ (xi >> 3)) & 255
                cv.setFill(h < 60 ? "#33241a" : h < 120 ? "#403021" : h < 200 ? "#382a1d" : "#443325")
                cv.fillRect(x, y, 4, 4)
                x += 4
            }
            y += 4
        }
        cv.setFill("rgba(0,0,0,0.45)")
        cv.fillRect(0, 0, width, height)
    }
    func drawTooltipBox(_ lines: [String], _ xIn: Double, _ yIn: Double) {
        var w = 0.0
        for l in lines { w = max(w, Double(textWidth(l))) }
        let h = Double(lines.count) * 10 + 6
        let x = min(xIn, width - w - 10)
        let y = max(4, min(yIn, height - h - 4))
        cv.setFill("rgba(16,0,16,0.94)")
        cv.fillRect(x, y, w + 8, h)
        cv.setStroke("rgba(80,0,255,0.45)")
        cv.strokeRect(x, y, w + 8, h)
        for (i, line) in lines.enumerated() {
            cv.drawText(line, x + 4, y + 4 + Double(i) * 10, 1)
        }
    }
    func itemTooltip(_ s: ItemStack) -> [String] {
        let def = itemDef(s.id)
        var lines: [String] = []
        let rarityColor = ["§f", "§e", "§b", "§d"][min(3, max(0, def.rarity))]
        lines.append(rarityColor + (s.label ?? def.displayName))
        if def.name == "potion" || def.name == "splash_potion" || def.name == "lingering_potion" || def.name == "tipped_arrow" {
            let pot = potionDef(s.data.potion ?? "water")
            for e in pot.effects {
                let ed = effectDef(e.effect)
                let mins = e.duration / 1200
                let secs = (e.duration % 1200) / 20
                var line = (ed.beneficial ? "§9" : "§c") + ed.displayName
                if e.amplifier > 0 { line += " " + ["I", "II", "III", "IV", "V"][min(4, e.amplifier)] }
                if e.duration > 1 { line += " (\(mins):\(String(format: "%02d", secs)))" }
                lines.append(line)
            }
            if pot.effects.isEmpty { lines.append("§7No Effects") }
        }
        for e in s.ench {
            let ed = enchDef(e.id)
            lines.append("§7" + ed.displayName + (ed.maxLevel > 1 ? " " + ["I", "II", "III", "IV", "V"][min(4, e.lvl - 1)] : ""))
        }
        if let trim = s.data.trim {
            lines.append("§7Trim: " + trim.pattern + " (" + trim.material.replacingOccurrences(of: "_", with: " ") + ")")
        }
        if let food = def.food {
            lines.append("§2+\(food.hunger) hunger")
        }
        let maxD = def.tool?.durability ?? def.armor?.durability ?? 0
        if maxD > 0 { lines.append("§7Durability: \(maxD - s.damage) / \(maxD)") }
        return lines
    }

    // ---- slot interaction ---------------------------------------------------------
    /// shift-click on an output slot: every take must run onTake (it consumes
    /// the crafting grid / grants furnace XP / counts trade uses), and a take
    /// is all-or-nothing — never insert a partial result with inputs unspent
    private func quickMoveOutput(_ screen: Screen, _ slot: SlotDef) {
        let targets = (screen as? ContainerScreen)?.playerSlots ?? []
        if targets.isEmpty { return }
        let repeatOutput = slot.repeatsOutputQuickMove()
        var rounds = 0
        while let s = slot.get(), s.count > 0, rounds < 64 {
            guard canFullyInsert(s, targets) else { break }
            let taken: ItemStack
            if let commit = slot.commitOutputTake {
                guard let committed = commit(s), committed.count > 0,
                      committed.count <= s.count, stacksEqual(committed, s) else { break }
                taken = committed
            } else {
                taken = copyStack(s)!
            }
            _ = quickMoveInto(taken, targets)
            if slot.commitOutputTake == nil { slot.onTake?(s) }
            rounds += 1
            if !repeatOutput { break }
            // defensive: a slot whose onTake doesn't refresh its source would
            // hand out the same stack forever
            if let again = slot.get(), again === s { break }
        }
    }

    func handleSlotClick(_ game: GameCore, _ screen: Screen, _ slot: SlotDef, _ btn: Int, shift: Bool = false) {
        let inSlot = slot.get()
        let cursor = cursorStack
        if shift {
            if inSlot != nil {
                if slot.output {
                    quickMoveOutput(screen, slot)
                } else {
                    screen.quickMove(game, slot)
                }
                slot.onChange?()
            }
            return
        }
        if slot.output {
            if let commit = slot.commitOutputTake {
                guard let preview = inSlot else { return }
                let mustUseInventory = preview.count > maxStackOf(preview)
                if mustUseInventory {
                    guard let container = screen as? ContainerScreen,
                          canFullyInsert(preview, container.playerSlots) else { return }
                    guard let committed = commit(preview), committed.count > 0,
                          committed.count <= preview.count,
                          stacksEqual(committed, preview) else { return }
                    let taken = copyStack(committed)!
                    _ = quickMoveInto(taken, container.playerSlots)
                } else {
                    guard cursor == nil || (canMerge(cursor!, preview)
                        && cursor!.count + preview.count <= maxStackOf(cursor!)) else { return }
                    guard let committed = commit(preview), committed.count > 0,
                          committed.count <= preview.count,
                          stacksEqual(committed, preview) else { return }
                    if let cursor {
                        cursor.count += committed.count
                    } else {
                        cursorStack = copyStack(committed)
                    }
                }
                slot.onChange?()
                return
            }
            // take only (all)
            if let inSlot,
               cursor == nil,
               inSlot.count > maxStackOf(inSlot),
               let container = screen as? ContainerScreen {
                guard canFullyInsert(inSlot, container.playerSlots) else { return }
                let taken = copyStack(inSlot)!
                _ = quickMoveInto(taken, container.playerSlots)
                slot.onTake?(inSlot)
                slot.onChange?()
            } else if let inSlot, cursor == nil || (canMerge(cursor!, inSlot) && cursor!.count + inSlot.count <= maxStackOf(cursor!)) {
                if let cursor {
                    cursor.count += inSlot.count
                } else {
                    cursorStack = copyStack(inSlot)
                }
                slot.onTake?(inSlot)
                slot.onChange?()
            }
            return
        }
        if btn == 0 {
            if let cursor, let inSlot, canMerge(cursor, inSlot) {
                let space = maxStackOf(inSlot) - inSlot.count
                let move = min(space, cursor.count)
                inSlot.count += move
                cursor.count -= move
                if cursor.count <= 0 { cursorStack = nil }
            } else if let cursor {
                if slot.canPlace?(cursor) ?? true {
                    slot.set(cursor)
                    cursorStack = inSlot
                }
            } else if let inSlot {
                cursorStack = inSlot
                slot.set(nil)
            }
        } else if btn == 2 {
            // right click
            if let cursor {
                if inSlot == nil && (slot.canPlace?(cursor) ?? true) {
                    let one = copyStack(cursor)!
                    one.count = 1
                    slot.set(one)
                    cursor.count -= 1
                    if cursor.count <= 0 { cursorStack = nil }
                } else if let inSlot, canMerge(cursor, inSlot), inSlot.count < maxStackOf(inSlot) {
                    inSlot.count += 1
                    cursor.count -= 1
                    if cursor.count <= 0 { cursorStack = nil }
                }
            } else if let inSlot {
                let half = (inSlot.count + 1) / 2
                let taken = copyStack(inSlot)!
                taken.count = half
                cursorStack = taken
                inSlot.count -= half
                if inSlot.count <= 0 { slot.set(nil) }
            }
        }
        slot.onChange?()
    }
}

/// standard player inventory slots (27 main + 9 hotbar) at panel-local coords
func playerInvSlots(_ player: Player, _ px: Double, _ py: Double) -> [SlotDef] {
    var out: [SlotDef] = []
    for row in 0..<3 {
        for col in 0..<9 {
            let idx = 9 + row * 9 + col
            out.append(SlotDef(
                x: px + Double(col) * 18, y: py + Double(row) * 18,
                get: { player.inventory[idx] },
                set: { player.inventory[idx] = $0 }))
        }
    }
    for col in 0..<9 {
        let idx = col
        out.append(SlotDef(
            x: px + Double(col) * 18, y: py + 58,
            get: { player.inventory[idx] },
            set: { player.inventory[idx] = $0 }))
    }
    return out
}

/// shift-move a stack into a list of slots (merge then empty)
@discardableResult
/// true if `stack` fits entirely into `targets` (merge space + empty slots) —
/// checked before quickMoveInto when a partial insert must not happen
func canFullyInsert(_ stack: ItemStack, _ targets: [SlotDef]) -> Bool {
    var remaining = stack.count
    for t in targets {
        if let ts = t.get(), canMerge(ts, stack) {
            remaining -= maxStackOf(ts) - ts.count
            if remaining <= 0 { return true }
        }
    }
    for t in targets where t.get() == nil && (t.canPlace?(stack) ?? true) {
        remaining -= maxStackOf(stack)
        if remaining <= 0 { return true }
    }
    return remaining <= 0
}

func quickMoveInto(_ stack: ItemStack, _ targets: [SlotDef]) -> Bool {
    for t in targets {
        if let ts = t.get(), canMerge(ts, stack) {
            let space = maxStackOf(ts) - ts.count
            let move = min(space, stack.count)
            ts.count += move
            stack.count -= move
            if stack.count <= 0 { return true }
        }
    }
    for t in targets {
        if t.get() == nil && (t.canPlace?(stack) ?? true) {
            let moved = copyStack(stack)!
            moved.count = min(maxStackOf(moved), stack.count)
            t.set(moved)
            stack.count -= moved.count
            if stack.count <= 0 { return true }
        }
    }
    return stack.count <= 0
}
