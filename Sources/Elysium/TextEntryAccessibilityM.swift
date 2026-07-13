import AppKit
import ElysiumTextInput

@MainActor
final class TextEntryAccessibilityElement: NSAccessibilityElement {
    private(set) var descriptor: TextEntryAccessibilityDescriptor
    let screenIdentity: UInt64
    let presentationGeneration: UInt64
    weak var originScreen: Screen?
    private weak var bridge: TextEntryAccessibilityBridge?
    private(set) var retired = false

    var stableID: String { "text:\(descriptor.id)" }
    var identity: ElysiumTextAccessibilityIdentity {
        ElysiumTextAccessibilityIdentity(
            screenIdentity: screenIdentity,
            presentationGeneration: presentationGeneration,
            descriptorID: descriptor.id)
    }

    init(descriptor: TextEntryAccessibilityDescriptor, screen: Screen, frame: NSRect,
         parent: GameView, bridge: TextEntryAccessibilityBridge) {
        self.descriptor = descriptor
        screenIdentity = screen.textScreenIdentity
        presentationGeneration = screen.textPresentationGeneration
        originScreen = screen
        self.bridge = bridge
        super.init()
        apply(descriptor: descriptor, frame: frame, parent: parent)
    }

    func refresh(descriptor: TextEntryAccessibilityDescriptor, frame: NSRect, parent: GameView) {
        guard !retired else { return }
        self.descriptor = descriptor
        apply(descriptor: descriptor, frame: frame, parent: parent)
    }

    func retire() {
        guard !retired else { return }
        retired = true
        originScreen = nil
        bridge = nil
        setAccessibilityFocused(false)
        setAccessibilityEnabled(false)
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        setAccessibilityHelp(nil)
        setAccessibilityNumberOfCharacters(0)
        setAccessibilitySelectedTextRange(NSRange(location: NSNotFound, length: 0))
        setAccessibilityChildren(nil)
        setAccessibilityParent(nil)
        setAccessibilityElement(false)
    }

    private func apply(descriptor: TextEntryAccessibilityDescriptor, frame: NSRect,
                       parent: GameView) {
        switch descriptor.role {
        case .textField:
            setAccessibilityRole(.textField)
            setAccessibilitySubrole(nil)
        case .searchField:
            setAccessibilityRole(.textField)
            setAccessibilitySubrole(.searchField)
        case .staticText:
            setAccessibilityRole(.staticText)
            setAccessibilitySubrole(nil)
        case .button:
            setAccessibilityRole(.button)
            setAccessibilitySubrole(nil)
        case .checkbox:
            setAccessibilityRole(.checkBox)
            setAccessibilitySubrole(nil)
        case .listItem:
            setAccessibilityRole(.row)
            setAccessibilitySubrole(nil)
        }
        setAccessibilityElement(true)
        setAccessibilityParent(parent)
        setAccessibilityFrame(frame)
        setAccessibilityLabel(descriptor.label)
        setAccessibilityValue(descriptor.value)
        if let selected = descriptor.selected { setAccessibilitySelected(selected) }
        setAccessibilityHelp(descriptor.help.isEmpty ? nil : descriptor.help)
        setAccessibilityEnabled(descriptor.enabled)
        if let insertion = descriptor.insertionUTF16Offset,
           insertion >= 0, insertion <= descriptor.value.utf16.count {
            setAccessibilityNumberOfCharacters(descriptor.value.utf16.count)
            setAccessibilitySelectedTextRange(NSRange(location: insertion, length: 0))
        } else {
            setAccessibilityNumberOfCharacters(0)
            setAccessibilitySelectedTextRange(NSRange(location: NSNotFound, length: 0))
        }
    }

    override func isAccessibilityFocused() -> Bool {
        !retired && (bridge?.isFocused(self) ?? false)
    }

    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool {
        guard !retired else { return false }
        if attribute == .value || attribute == .selectedTextRange { return false }
        return attribute == .focused && descriptor.focusable
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard !retired, focused, descriptor.focusable else { return }
        _ = bridge?.focus(self)
    }

    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        !retired && descriptor.actionable && descriptor.enabled ? [.press] : []
    }

    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        guard action == .press else { return }
        _ = bridge?.press(self)
    }
}

/// Retained, generation-bound Accessibility publication for canvas editors. AX getters never mint
/// objects; mutation and replacement occur only at UIManager's synchronous commit boundary.
@MainActor
final class TextEntryAccessibilityBridge {
    private weak var view: GameView?
    private var elements: [TextEntryAccessibilityElement] = []

    init(view: GameView) { self.view = view }

    var children: [Any] { elements }
    var stableIDs: [String] { elements.map(\.stableID) }

    /// Returns true only when root membership/object identity changed and AppKit must republish.
    func commit(screen: Screen, descriptors: [TextEntryAccessibilityDescriptor]) -> Bool {
        guard let view, descriptors.count <= 64,
              screen.textPresentationGeneration != 0,
              Set(descriptors.map(\.id)).count == descriptors.count else {
            return invalidate()
        }
        let projected: [(TextEntryAccessibilityDescriptor, NSRect)] = descriptors.compactMap {
            let frame = screenFrame($0.frame, view: view)
            return frame.width > 0 && frame.height > 0 ? ($0, frame) : nil
        }
        guard projected.count == descriptors.count,
              projected.allSatisfy({ descriptorIsBounded($0.0) }) else {
            return invalidate()
        }

        let sameStructure = elements.count == projected.count && zip(elements, projected).allSatisfy {
            element, candidate in
            element.screenIdentity == screen.textScreenIdentity &&
                element.presentationGeneration == screen.textPresentationGeneration &&
                element.descriptor.id == candidate.0.id &&
                element.descriptor.role == candidate.0.role &&
                element.descriptor.focusable == candidate.0.focusable && !element.retired
        }
        if sameStructure {
            for (element, candidate) in zip(elements, projected) {
                element.refresh(descriptor: candidate.0, frame: candidate.1, parent: view)
            }
            return false
        }

        let replacements = projected.map {
            TextEntryAccessibilityElement(descriptor: $0.0, screen: screen, frame: $0.1,
                                          parent: view, bridge: self)
        }
        elements.forEach { $0.retire() }
        elements = replacements
        return true
    }

    @discardableResult
    func invalidate() -> Bool {
        guard !elements.isEmpty else { return false }
        elements.forEach { $0.retire() }
        elements.removeAll(keepingCapacity: false)
        return true
    }

    func element(id: String) -> TextEntryAccessibilityElement? {
        let matches = elements.filter { !$0.retired && $0.descriptor.id == id }
        return matches.count == 1 ? matches[0] : nil
    }

    func isFocused(_ element: TextEntryAccessibilityElement) -> Bool {
        guard NSApp.isActive, view?.window?.isKeyWindow == true,
              !element.retired, elements.contains(where: { $0 === element }),
              let app = view?.appd, let screen = element.originScreen,
              app.ui.current() === screen,
              elysiumTextAccessibilityIdentityIsCurrent(
                origin: element.identity,
                current: ElysiumTextAccessibilityIdentity(
                    screenIdentity: screen.textScreenIdentity,
                    presentationGeneration: screen.textPresentationGeneration,
                    descriptorID: element.descriptor.id)) else { return false }
        return screen.textAccessibilityDescriptors(app.ui, app.game).contains {
            $0.id == element.descriptor.id && $0.focused
        }
    }

    @discardableResult
    func focus(_ element: TextEntryAccessibilityElement) -> Bool {
        guard NSApp.isActive, view?.window?.isKeyWindow == true,
              !element.retired, elements.contains(where: { $0 === element }),
              let view, let app = view.appd, let screen = element.originScreen,
              app.ui.current() === screen,
              elysiumTextAccessibilityIdentityIsCurrent(
                origin: element.identity,
                current: ElysiumTextAccessibilityIdentity(
                    screenIdentity: screen.textScreenIdentity,
                    presentationGeneration: screen.textPresentationGeneration,
                    descriptorID: element.descriptor.id)) else { return false }
        let matches = screen.textAccessibilityDescriptors(app.ui, app.game).filter {
            $0.id == element.descriptor.id && $0.enabled && $0.focusable
        }
        guard matches.count == 1 else { return false }
        if element.descriptor.role != .textField && element.descriptor.role != .searchField {
            return screen.focusTextAccessibilityElement(
                element.descriptor.id, app.ui, app.game)
        }
        return app.ui.establishAccessibilityTextReadiness(
            screen: screen, game: app.game, descriptorID: element.descriptor.id)
    }

    func retainedFocusedElement() -> TextEntryAccessibilityElement? {
        let focused = elements.filter { isFocused($0) }
        return focused.count == 1 ? focused[0] : nil
    }

    @discardableResult
    func press(_ element: TextEntryAccessibilityElement) -> Bool {
        guard NSApp.isActive, view?.window?.isKeyWindow == true,
              !element.retired, elements.contains(where: { $0 === element }),
              let view, let app = view.appd, let screen = element.originScreen,
              app.ui.current() === screen,
              elysiumTextAccessibilityIdentityIsCurrent(
                origin: element.identity,
                current: ElysiumTextAccessibilityIdentity(
                    screenIdentity: screen.textScreenIdentity,
                    presentationGeneration: screen.textPresentationGeneration,
                    descriptorID: element.descriptor.id)) else { return false }
        let matches = screen.textAccessibilityDescriptors(app.ui, app.game).filter {
            $0.id == element.descriptor.id && $0.enabled && $0.actionable
        }
        guard matches.count == 1 else { return false }
        return screen.performTextAccessibilityAction(element.descriptor.id, app.ui, app.game)
    }

    private func descriptorIsBounded(_ descriptor: TextEntryAccessibilityDescriptor) -> Bool {
        !descriptor.id.isEmpty && descriptor.id.utf8.count <= 256 &&
            descriptor.label.utf8.count <= 4_096 && descriptor.value.utf8.count <= 16_384 &&
            descriptor.help.utf8.count <= 4_096
    }

    private func screenFrame(
        _ logical: (x: Double, y: Double, width: Double, height: Double), view: GameView
    ) -> NSRect {
        guard [logical.x, logical.y, logical.width, logical.height].allSatisfy(\.isFinite),
              logical.x >= 0, logical.y >= 0, logical.width > 0, logical.height > 0,
              let window = view.window else { return .zero }
        let scale = view.ui?.scale ?? 1
        let pointRect = NSRect(x: logical.x * scale / Double(window.backingScaleFactor),
                               y: Double(view.bounds.height) -
                                  (logical.y + logical.height) * scale /
                                  Double(window.backingScaleFactor),
                               width: logical.width * scale / Double(window.backingScaleFactor),
                               height: logical.height * scale / Double(window.backingScaleFactor))
        guard [pointRect.origin.x, pointRect.origin.y, pointRect.width, pointRect.height]
            .map(Double.init).allSatisfy(\.isFinite) else { return .zero }
        let windowRect = view.convert(pointRect, to: nil)
        let origin = window.convertPoint(toScreen: windowRect.origin)
        guard [origin.x, origin.y, windowRect.width, windowRect.height]
            .map(Double.init).allSatisfy(\.isFinite) else { return .zero }
        let converted = NSRect(origin: origin, size: windowRect.size)
        guard let owningScreen = window.screen,
              let clamped = elysiumClampTextRect(
                ElysiumTextRect(x: converted.origin.x, y: converted.origin.y,
                               width: converted.width, height: converted.height),
                to: ElysiumTextRect(x: owningScreen.frame.origin.x,
                                   y: owningScreen.frame.origin.y,
                                   width: owningScreen.frame.width,
                                   height: owningScreen.frame.height)) else { return .zero }
        return NSRect(x: clamped.x, y: clamped.y, width: clamped.width, height: clamped.height)
    }
}
