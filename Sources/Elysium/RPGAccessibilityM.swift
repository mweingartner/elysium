import AppKit
import ElysiumCore
import ElysiumTextInput
import ElysiumAppSupport

/// One cached AppKit element. Its activation origin, descriptor, viewport, and layout generation
/// are immutable; invalidating the current bridge cache never rewrites a retained old reference.
@MainActor
final class ElysiumAccessibilityElement: NSAccessibilityElement {
    private(set) var cached: RPGAccessibilityElementSnapshot
    let screenInstanceID: UInt64
    private(set) var semanticRevision: UInt64
    /// Weak to avoid retaining an obsolete screen graph. Press still issues a fresh cached-origin
    /// receipt first; UIManager explicitly consumes it if this screen has deallocated.
    weak var originScreen: Screen?
    private weak var bridge: RPGAccessibilityBridge?
    private(set) var retired = false
    var stableID: String { "rpg:\(cached.descriptor.id.rawValue)" }

    init(cached: RPGAccessibilityElementSnapshot,
         tree: RPGAccessibilityTreeSnapshot,
         frame: NSRect,
         parent: GameView,
         screen: Screen,
         bridge: RPGAccessibilityBridge) {
        self.cached = cached
        screenInstanceID = tree.screenInstanceID
        semanticRevision = tree.semanticRevision
        originScreen = screen
        self.bridge = bridge
        super.init()
        setAccessibilityRole(Self.appKitRole(cached.descriptor))
        setAccessibilityFrame(frame)
        setAccessibilityLabel(cached.descriptor.label)
        setAccessibilityParent(parent)
        setAccessibilityValue(cached.accessibilityValue)
        setAccessibilityHelp(cached.accessibilityHelp.isEmpty ? nil : cached.accessibilityHelp)
        setAccessibilityEnabled(cached.descriptor.enabled && !cached.descriptor.locked)
        setAccessibilitySelected(cached.descriptor.selected)
    }

    func refreshScalars(cached: RPGAccessibilityElementSnapshot,
                        tree: RPGAccessibilityTreeSnapshot,
                        frame: NSRect) {
        guard !retired, tree.screenInstanceID == screenInstanceID else { return }
        self.cached = cached
        semanticRevision = tree.semanticRevision
        setAccessibilityFrame(frame)
        setAccessibilityLabel(cached.descriptor.label)
        setAccessibilityValue(cached.accessibilityValue)
        setAccessibilityHelp(cached.accessibilityHelp.isEmpty ? nil : cached.accessibilityHelp)
        setAccessibilityEnabled(cached.descriptor.enabled && !cached.descriptor.locked)
        setAccessibilitySelected(cached.descriptor.selected)
    }

    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        !retired && cached.hasPressAction ? [.press] : []
    }

    override func accessibilityPerformPress() -> Bool {
        guard !retired, cached.hasPressAction else { return false }
        return bridge?.press(self) ?? false
    }

    override func isAccessibilityFocused() -> Bool {
        !retired && (bridge?.isFocused(self) ?? false)
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        guard !retired, focused else { return }
        _ = bridge?.focus(self)
    }

    func retire() {
        guard !retired else { return }
        retired = true
        originScreen = nil
        bridge = nil
        setAccessibilityEnabled(false)
        setAccessibilitySelected(false)
        setAccessibilityLabel(nil)
        setAccessibilityValue(nil)
        setAccessibilityHelp(nil)
        setAccessibilityChildren(nil)
        setAccessibilityParent(nil)
        setAccessibilityElement(false)
    }

    private static func appKitRole(_ descriptor: RPGSemanticDescriptor) -> NSAccessibility.Role {
        if descriptor.id.rawValue == "accessibility:tab-group" { return .tabGroup }
        switch descriptor.role {
        case .button: return .button
        case .staticText: return .staticText
        case .tab: return .radioButton
        case .group: return .group
        case .row: return .row
        case .scrollArea: return .scrollArea
        }
    }
}

/// Main-thread bridge from one explicitly committed Core semantic tree to AppKit accessibility.
@MainActor
final class RPGAccessibilityBridge {
    private weak var view: GameView?
    private var tree: RPGAccessibilityTreeSnapshot?
    private var currentElements: [ElysiumAccessibilityElement] = []
    private var rootElements: [ElysiumAccessibilityElement] = []
    private let retainedStore = ElysiumRetainedTreeStore<ElysiumAccessibilityElement>()

    init(view: GameView) {
        self.view = view
    }

    var children: [Any] { rootElements }
    var stableIDs: [String] { currentElements.map(\.stableID) }

    func commit(screen: Screen, tree newTree: RPGAccessibilityTreeSnapshot) {
        guard let view else { return }
        let previous = tree
        guard newTree.elements.count <= 384,
              Set(newTree.elements.map { $0.descriptor.id }).count == newTree.elements.count else {
            invalidate()
            return
        }
        let projected = newTree.elements.map { cached in
            (cached, screenFrame(for: cached.descriptor.frame, view: view))
        }
        guard projected.allSatisfy({ candidate in
            let frame = candidate.1
            return [frame.origin.x, frame.origin.y, frame.width, frame.height]
                .map(Double.init).allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
        }) else {
            invalidate()
            return
        }

        let newKey = structuralKey(newTree)
        let mutation = retainedStore.update(key: newKey) {
            projected.map { candidate in
                ElysiumAccessibilityElement(
                    cached: candidate.0, tree: newTree, frame: candidate.1,
                    parent: view, screen: screen, bridge: self)
            }
        }
        switch mutation {
        case .scalarRefresh(let retained):
            guard retained.count == projected.count,
                  retained.allSatisfy({ !$0.retired }) else {
                invalidate()
                return
            }
            tree = newTree
            currentElements = retained
            for (element, candidate) in zip(retained, projected) {
                element.refreshScalars(cached: candidate.0, tree: newTree, frame: candidate.1)
            }
            postNotifications(previous: previous, current: newTree, view: view)
            return
        case .structuralReplacement(let old, let replacements):
            old.forEach { $0.retire() }
            tree = newTree
            currentElements = replacements
            rootElements = replacements
            nestChildren(parentID: "accessibility:tab-group", roles: [.tab])
            // The Skills tab is the only surface where "accessibility:skills-root" is present,
            // and its nine skill cards are the only .row descriptors on that tab.
            nestChildren(parentID: "accessibility:skills-root", roles: [.row])
            guard view.publishAccessibilityChildren() else { return }
            postNotifications(previous: previous, current: newTree, view: view)
        }
    }

    private func postNotifications(previous: RPGAccessibilityTreeSnapshot?,
                                   current newTree: RPGAccessibilityTreeSnapshot,
                                   view: GameView) {
        let intents = rpgAccessibilityNotificationIntents(previous: previous, current: newTree)
        for intent in intents {
            switch intent {
            case .focusedElementChanged:
                guard NSApp.isActive, view.window?.isKeyWindow == true else { continue }
                let focused = currentElements.first {
                    $0.cached.descriptor.id == newTree.focusedID
                } ?? view
                NSAccessibility.post(element: focused,
                                     notification: .focusedUIElementChanged)
            case .valueChanged:
                NSAccessibility.post(element: view, notification: .valueChanged)
            case .layoutChanged:
                NSAccessibility.post(element: view, notification: .layoutChanged)
            }
        }
        if let announcement = rpgAccessibilityAuthorityAnnouncement(
            previous: previous, current: newTree) {
            NSAccessibility.post(
                element: view, notification: .announcementRequested,
                userInfo: [
                    .announcement: announcement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
        // D4: announce the creation step title ("Path · Step 1 of 4", ...) on each step transition.
        if let stepAnnouncement = rpgAccessibilityCreationStepAnnouncement(
            previous: previous, current: newTree) {
            NSAccessibility.post(
                element: view, notification: .announcementRequested,
                userInfo: [
                    .announcement: stepAnnouncement,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ])
        }
    }

    private func structuralKey(_ value: RPGAccessibilityTreeSnapshot)
        -> ElysiumRetainedStructureKey {
        ElysiumRetainedStructureKey(
            screenIdentity: value.screenInstanceID,
            generation: value.layoutGeneration,
            orderedDescriptors: value.elements.map { element in
                let descriptor = element.descriptor
                let parentID: String?
                switch descriptor.role {
                case .tab: parentID = "accessibility:tab-group"
                case .row where descriptor.rankPips != nil: parentID = "accessibility:skills-root"
                default: parentID = descriptor.groupID?.rawValue
                }
                return ElysiumRetainedDescriptorKey(
                    id: descriptor.id.rawValue, role: String(describing: descriptor.role),
                    parentID: parentID, actionable: element.hasPressAction,
                    focusable: descriptor.isFocusable)
            })
    }

    func invalidate(publish: Bool = true) {
        guard tree != nil || !currentElements.isEmpty else { return }
        retainedStore.invalidate().forEach { $0.retire() }
        tree = nil
        currentElements = []
        rootElements = []
        if let view, publish {
            view.publishAccessibilityChildren()
            NSAccessibility.post(element: view, notification: .layoutChanged)
        }
    }

    func isFocused(_ element: ElysiumAccessibilityElement) -> Bool {
        NSApp.isActive && view?.window?.isKeyWindow == true &&
            !element.retired && currentElements.contains(where: { $0 === element }) &&
            tree?.focusedID == element.cached.descriptor.id &&
            tree?.screenInstanceID == element.screenInstanceID &&
            tree?.semanticRevision == element.semanticRevision
    }

    private func nestChildren(parentID: String, roles: [RPGSemanticRole]) {
        guard let parent = currentElements.first(where: {
            $0.cached.descriptor.id.rawValue == parentID
        }) else { return }
        let nested = currentElements.filter { roles.contains($0.cached.descriptor.role) }
        guard !nested.isEmpty else { return }
        parent.setAccessibilityChildren(nested)
        for child in nested { child.setAccessibilityParent(parent) }
        let nestedIDs = Set(nested.map { ObjectIdentifier($0) })
        rootElements.removeAll { nestedIDs.contains(ObjectIdentifier($0)) }
    }

    @discardableResult
    func focus(_ element: ElysiumAccessibilityElement) -> Bool {
        guard NSApp.isActive, view?.window?.isKeyWindow == true,
              !element.retired, currentElements.contains(where: { $0 === element }),
              element.cached.descriptor.isFocusable,
              let screen = element.originScreen,
              let app = view?.appd else { return false }
        return app.ui.focusRPGAccessibilityElement(
            screenInstanceID: element.screenInstanceID,
            semanticRevision: element.semanticRevision,
            id: element.cached.descriptor.id,
            on: screen, game: app.game)
    }

    func retainedFocusedElement() -> ElysiumAccessibilityElement? {
        let focused = currentElements.filter { isFocused($0) }
        return focused.count == 1 ? focused[0] : nil
    }

    @discardableResult
    func press(_ element: ElysiumAccessibilityElement) -> Bool {
        guard !element.retired, currentElements.contains(where: { $0 === element }),
              let origin = element.cached.activationOrigin,
              let app = view?.appd,
              let capture = app.ui.captureRPGAccessibilityActivation(origin: origin) else {
            return false
        }
        // A direct Press on an offscreen cached element reveals first. That commit makes this
        // capture stale; dispatch consumes it and requires VoiceOver to fetch and press the new one.
        if element.cached.descriptor.visibleFrame == nil {
            if let screen = element.originScreen {
                _ = app.ui.focusRPGAccessibilityElement(
                    screenInstanceID: element.screenInstanceID,
                    semanticRevision: element.semanticRevision,
                    id: element.cached.descriptor.id,
                    on: screen, game: app.game)
            }
        }
        let result = app.ui.dispatchRPGAccessibilityActivation(
            capture, on: element.originScreen, game: app.game)
        if case .dispatched = result { return true }
        return false
    }

    private func screenFrame(for logical: RPGLogicalRect, view: GameView) -> NSRect {
        guard logical.isFinite, logical.width > 0, logical.height > 0,
              let window = view.window else { return .zero }
        let uiScale = view.ui?.scale ?? 1
        let backingScale = Double(window.backingScaleFactor)
        guard let projected = rpgAccessibilityViewFrame(
            logical: logical, uiScale: uiScale, backingScale: backingScale,
            viewWidth: Double(view.bounds.width), viewHeight: Double(view.bounds.height)) else {
            return .zero
        }
        let windowRect = view.convert(NSRect(
            x: projected.x, y: projected.y,
            width: projected.width, height: projected.height), to: nil)
        let windowValues = [Double(windowRect.origin.x), Double(windowRect.origin.y),
                            Double(windowRect.width), Double(windowRect.height)]
        guard windowValues.allSatisfy(\.isFinite), windowRect.width > 0, windowRect.height > 0,
              windowRect.width <= 1_000_000, windowRect.height <= 1_000_000 else { return .zero }
        let screenOrigin = window.convertPoint(toScreen: windowRect.origin)
        let finalValues = [Double(screenOrigin.x), Double(screenOrigin.y),
                           Double(windowRect.width), Double(windowRect.height)]
        guard finalValues.allSatisfy(\.isFinite),
              abs(screenOrigin.x) <= 10_000_000, abs(screenOrigin.y) <= 10_000_000 else {
            return .zero
        }
        return NSRect(origin: screenOrigin, size: windowRect.size)
    }
}
