import Foundation

/// One fully-bound mouse activation owned by a single committed semantic publication.
/// The capture remains cancellable until a matching release transfers it to the sole dispatcher.
public struct RPGScreenMouseActivation: Equatable {
    public let screenInstanceID: UInt64
    public let semanticRevision: UInt64
    public let elementID: RPGUIElementID
    public let capture: RPGSemanticActivationCapture

    public init?(screenInstanceID: UInt64, semanticRevision: UInt64,
                 elementID: RPGUIElementID, capture: RPGSemanticActivationCapture) {
        guard screenInstanceID > 0, semanticRevision > 0,
              capture.screenInstanceID == screenInstanceID,
              capture.semanticRevision == semanticRevision,
              capture.id == elementID else { return nil }
        self.screenInstanceID = screenInstanceID
        self.semanticRevision = semanticRevision
        self.elementID = elementID
        self.capture = capture
    }
}

public struct RPGClassDrag: Equatable {
    public let originX: Double
    public let originY: Double
    public var currentX: Double
    public var currentY: Double
    public let screenInstanceID: UInt64
    public let semanticRevision: UInt64
}

/// Presentation-only state for the RPG sheet. It deliberately contains no GameCore, persistence,
/// authority, or registry mutation capability; the app rebuilds the pure screen model from it.
public struct RPGScreenInteractionState: Equatable {
    public var creation: RPGCreationSession
    public var tab: RPGCharacterTab
    public var focusedID: RPGUIElementID?
    public var selection: RPGScreenSelection?
    public var scrollOffset: Double
    public var tutorial: RPGTutorialState
    /// Last focused scrolling descriptor in absolute screen coordinates after the committed
    /// offset. Retaining screen space (not the next model's content origin) makes contextual-band
    /// expansion/collapse anchor the same visible control across a semantic rebuild.
    public fileprivate(set) var focusedScreenFrame: RPGLogicalRect?
    public fileprivate(set) var focusOrder: [RPGUIElementID]
    public fileprivate(set) var pendingMouseActivation: RPGScreenMouseActivation?
    public fileprivate(set) var pendingClassDrag: RPGClassDrag?

    public init(creation: RPGCreationSession = rpgInitialCreationSession(),
                tab: RPGCharacterTab = .character,
                focusedID: RPGUIElementID? = nil,
                selection: RPGScreenSelection? = nil,
                scrollOffset: Double = 0,
                tutorial: RPGTutorialState = RPGTutorialState(),
                focusedScreenFrame: RPGLogicalRect? = nil,
                focusOrder: [RPGUIElementID] = [],
                pendingMouseActivation: RPGScreenMouseActivation? = nil) {
        self.creation = creation
        self.tab = tab
        self.focusedID = focusedID
        self.selection = selection
        self.scrollOffset = scrollOffset.isFinite ? max(0, scrollOffset) : 0
        self.tutorial = tutorial
        self.focusedScreenFrame = focusedScreenFrame
        self.focusOrder = focusOrder
        self.pendingMouseActivation = pendingMouseActivation
        self.pendingClassDrag = nil
    }
}

/// The immutable model publication against which one input event is reduced.
public struct RPGScreenInteractionContext: Equatable {
    public let model: RPGScreenModel
    public let screenInstanceID: UInt64
    public let semanticRevision: UInt64

    public init?(model: RPGScreenModel, screenInstanceID: UInt64, semanticRevision: UInt64) {
        guard screenInstanceID > 0, semanticRevision > 0 else { return nil }
        self.model = model
        self.screenInstanceID = screenInstanceID
        self.semanticRevision = semanticRevision
    }
}

public enum RPGScreenInteractionEvent: Equatable {
    case focusNext
    case focusPrevious
    case focusElement(RPGUIElementID)
    case moveFocus(RPGFocusDirection)
    case scrollRows(Int)
    case activateFocused
    /// Mouse-down is given the capture issued for this exact descriptor, or nil for a
    /// focusable-but-nonactionable descriptor. A prior held capture is always cancelled first.
    case mouseDown(elementID: RPGUIElementID, capture: RPGSemanticActivationCapture?)
    /// A nil ID represents release outside every fully visible semantic descriptor.
    case mouseUp(elementID: RPGUIElementID?)
    case cancelMouse
    case beginClassDrag(x: Double, y: Double)
    case updateClassDrag(x: Double, y: Double)
    case endClassDrag(x: Double, y: Double)
    case cancelClassDrag
    /// Screen cover, replacement, close, and app focus loss share this ownership-loss event.
    case inputOwnershipLost
    /// Apply a successfully dispatched semantic command. Tutorial completion is published only
    /// when the caller proves its persist-before-publish transaction succeeded.
    case applyCommand(RPGSemanticCommand, tutorialCompletionPublished: Bool)
}

public enum RPGScreenInteractionEffect: Equatable {
    /// Keyboard/controller/accessibility asks the app's sole boundary for a fresh capture.
    case activate(RPGUIElementID)
    /// Mouse-up transfers the original mouse-down capture to the sole dispatcher exactly once.
    case dispatchMouse(RPGSemanticActivationCapture)
    /// The app must cancel this issued-but-undispatched receipt at its sole boundary.
    case cancelMouse(RPGSemanticActivationCapture)
    case close
}

public struct RPGScreenInteractionTransition: Equatable {
    public let state: RPGScreenInteractionState
    public let effects: [RPGScreenInteractionEffect]
    public let handled: Bool
    public let creationError: RPGCreationSessionError?

    public init(state: RPGScreenInteractionState,
                effects: [RPGScreenInteractionEffect] = [],
                handled: Bool,
                creationError: RPGCreationSessionError? = nil) {
        self.state = state
        self.effects = effects
        self.handled = handled
        self.creationError = creationError
    }
}

public let RPG_SCREEN_SCROLL_STRIDE = 28.0
public let RPG_CLASS_SWIPE_THRESHOLD = 32.0

private func validClassDragPoint(x: Double, y: Double, model: RPGScreenModel) -> Bool {
    guard x.isFinite, y.isFinite, model.panelFrame.isFinite else { return false }
    return x >= model.panelFrame.x && x <= model.panelFrame.maxX &&
        y >= model.panelFrame.y && y <= model.panelFrame.maxY
}

/// Returns only fully visible semantic elements and uses reverse draw order for overlap safety.
public func rpgScreenDescriptor(atX x: Double, y: Double,
                                in model: RPGScreenModel) -> RPGSemanticDescriptor? {
    guard x.isFinite, y.isFinite else { return nil }
    return model.visibleDescriptors.reversed().first { value in
        guard let frame = value.visibleFrame, frame.isFinite,
              frame.width > 0, frame.height > 0 else { return false }
        return x >= frame.x && x < frame.maxX && y >= frame.y && y < frame.maxY
    }
}

private func rpgInteractionFocusOrder(_ model: RPGScreenModel) -> [RPGUIElementID] {
    model.descriptors.filter(\.isFocusable).map(\.id)
}

/// Checked one-clamp nearest-edge reveal shared by production focus and installed harness setup.
/// It never mutates focus, publishes semantics, or dispatches input.
public func rpgRevealScrollOffset(descriptor: RPGSemanticDescriptor,
                                  in model: RPGScreenModel,
                                  currentOffset: Double) -> Double? {
    let viewport = model.contentFrame
    guard viewport.isFinite, viewport.width > 0, viewport.height > 0,
          viewport.maxX.isFinite, viewport.maxY.isFinite,
          model.panelFrame.isFinite, model.panelFrame.width > 0,
          model.panelFrame.height > 0, model.panelFrame.maxX.isFinite,
          model.panelFrame.maxY.isFinite,
          model.contentHeight.isFinite, model.contentHeight >= 0,
          model.viewportHeight.isFinite, model.viewportHeight > 0,
          currentOffset.isFinite, descriptor.frame.isFinite,
          descriptor.frame.width > 0, descriptor.frame.height > 0,
          descriptor.frame.maxX.isFinite, descriptor.frame.maxY.isFinite else { return nil }
    let clamped = rpgClampedScrollOffset(
        contentHeight: model.contentHeight, viewportHeight: model.viewportHeight,
        requested: currentOffset)
    guard clamped.isFinite else { return nil }
    if descriptor.layoutRegion == .fixed {
        guard descriptor.visibleFrame == descriptor.frame,
              model.panelFrame.contains(descriptor.frame) else { return nil }
        return clamped
    }
    guard descriptor.layoutRegion == .scrollingContent,
          descriptor.frame.height <= viewport.height else { return nil }
    let unscrolledY = descriptor.frame.y + model.scrollOffset
    guard unscrolledY.isFinite else { return nil }
    var requested = clamped
    let projectedY = unscrolledY - requested
    guard projectedY.isFinite else { return nil }
    if projectedY < viewport.y {
        let delta = projectedY - viewport.y
        guard delta.isFinite, (requested + delta).isFinite else { return nil }
        requested += delta
    } else {
        let projectedMaxY = projectedY + descriptor.frame.height
        guard projectedMaxY.isFinite else { return nil }
        if projectedMaxY > viewport.maxY {
            let delta = projectedMaxY - viewport.maxY
            guard delta.isFinite, (requested + delta).isFinite else { return nil }
            requested += delta
        }
    }
    let result = rpgClampedScrollOffset(
        contentHeight: model.contentHeight, viewportHeight: model.viewportHeight,
        requested: requested)
    guard result.isFinite else { return nil }
    let finalFrame = RPGLogicalRect(
        x: descriptor.frame.x,
        y: unscrolledY - result,
        width: descriptor.frame.width, height: descriptor.frame.height)
    guard finalFrame.isFinite, viewport.contains(finalFrame) else { return nil }
    return result
}

@discardableResult
private func rpgRevealInteractionFocus(_ state: inout RPGScreenInteractionState,
                                       model: RPGScreenModel) -> Bool {
    guard let id = state.focusedID,
          let value = model.descriptors.first(where: { $0.id == id }),
          let revealedOffset = rpgRevealScrollOffset(
              descriptor: value, in: model, currentOffset: state.scrollOffset) else {
        return false
    }
    state.scrollOffset = revealedOffset
    if value.layoutRegion == .fixed {
        state.focusedScreenFrame = nil
        return true
    }
    let unscrolled = RPGLogicalRect(
        x: value.frame.x, y: value.frame.y + model.scrollOffset,
        width: value.frame.width, height: value.frame.height)
    state.focusedScreenFrame = RPGLogicalRect(
        x: unscrolled.x, y: unscrolled.y - state.scrollOffset,
        width: unscrolled.width, height: unscrolled.height)
    return true
}

private func rpgSelectInteractionDescriptor(_ descriptor: RPGSemanticDescriptor,
                                            state: inout RPGScreenInteractionState) {
    state.focusedID = descriptor.id
    if let selection = descriptor.focusSelection { state.selection = selection }
}

/// Reconciles a provisional production rebuild before its sole semantic commit. Contextual fixed
/// bands may move the scrolling viewport between publications; anchoring must therefore happen
/// before observers can see the rebuilt model, not on the next input event.
@discardableResult
public func rpgReconcileProvisionalScreenModel(
    _ state: inout RPGScreenInteractionState,
    provisionalModel model: RPGScreenModel
) -> Bool {
    let provisionalOffset = model.scrollOffset
    state.scrollOffset = provisionalOffset
    guard let previousFocusedFrame = state.focusedScreenFrame,
          let id = state.focusedID,
          let descriptor = model.descriptors.first(where: {
              $0.id == id && $0.layoutRegion == .scrollingContent
          }) else {
        return false
    }
    let nextUnscrolled = RPGLogicalRect(
        x: descriptor.frame.x, y: descriptor.frame.y + provisionalOffset,
        width: descriptor.frame.width, height: descriptor.frame.height)
    state.scrollOffset = rpgAnchoredScrollOffset(
        previousFocusedFrame: previousFocusedFrame,
        newUnscrolledFocusedFrame: nextUnscrolled,
        currentOffset: provisionalOffset,
        contentHeight: model.contentHeight,
        viewportHeight: model.viewportHeight,
        viewportOriginY: model.contentFrame.y)
    state.focusedScreenFrame = RPGLogicalRect(
        x: nextUnscrolled.x, y: nextUnscrolled.y - state.scrollOffset,
        width: nextUnscrolled.width, height: nextUnscrolled.height)
    return state.scrollOffset != provisionalOffset
}

private func rpgCyclicTab(_ current: RPGCharacterTab, delta: Int) -> RPGCharacterTab {
    let tabs = RPGCharacterTab.allCases
    guard let index = tabs.firstIndex(of: current), !tabs.isEmpty else { return .character }
    let normalized = ((index + delta) % tabs.count + tabs.count) % tabs.count
    return tabs[normalized]
}

/// Pure deterministic RPG screen reducer. All gameplay/persistence effects remain explicit outputs
/// or travel through the existing semantic dispatcher; no reducer branch mutates live game state.
public func rpgReduceScreenInteraction(_ current: RPGScreenInteractionState,
                                       event: RPGScreenInteractionEvent,
                                       context: RPGScreenInteractionContext)
    -> RPGScreenInteractionTransition {
    var state = current
    var effects: [RPGScreenInteractionEffect] = []

    // A semantic rebuild cannot retain ownership of a mouse capture from an older publication.
    if let pending = state.pendingMouseActivation,
       pending.screenInstanceID != context.screenInstanceID ||
       pending.semanticRevision != context.semanticRevision {
        effects.append(.cancelMouse(pending.capture))
        state.pendingMouseActivation = nil
    }
    if let pending = state.pendingClassDrag,
       pending.screenInstanceID != context.screenInstanceID ||
       pending.semanticRevision != context.semanticRevision {
        state.pendingClassDrag = nil
    }

    let newOrder = rpgInteractionFocusOrder(context.model)
    if state.focusedID != nil {
        state.focusedID = rpgRetainedFocusID(
            previousID: state.focusedID, previousOrder: state.focusOrder,
            newDescriptors: context.model.descriptors)
    }
    state.focusOrder = newOrder
    state.scrollOffset = rpgClampedScrollOffset(
        contentHeight: context.model.contentHeight,
        viewportHeight: context.model.viewportHeight,
        requested: state.scrollOffset)
    if let id = state.focusedID,
       let descriptor = context.model.descriptors.first(where: {
           $0.id == id && $0.layoutRegion == .scrollingContent
       }) {
        let nextUnscrolled = RPGLogicalRect(
            x: descriptor.frame.x,
            y: descriptor.frame.y + context.model.scrollOffset,
            width: descriptor.frame.width, height: descriptor.frame.height)
        state.scrollOffset = rpgAnchoredScrollOffset(
            previousFocusedFrame: state.focusedScreenFrame,
            newUnscrolledFocusedFrame: nextUnscrolled,
            currentOffset: state.scrollOffset,
            contentHeight: context.model.contentHeight,
            viewportHeight: context.model.viewportHeight,
            viewportOriginY: context.model.contentFrame.y)
        state.focusedScreenFrame = RPGLogicalRect(
            x: nextUnscrolled.x, y: nextUnscrolled.y - state.scrollOffset,
            width: nextUnscrolled.width, height: nextUnscrolled.height)
    } else {
        state.focusedScreenFrame = nil
    }

    switch event {
    case .beginClassDrag(let x, let y):
        guard state.creation.step == .path,
              validClassDragPoint(x: x, y: y, model: context.model),
              let card = context.model.descriptors.first(where: {
                  $0.id.rawValue == "creation:path:card"
              }), x >= card.frame.x, x < card.frame.maxX,
              y >= card.frame.y, y < card.frame.maxY,
              !context.model.descriptors.contains(where: { descriptor in
                  descriptor.role == .button && descriptor.frame.width > 0 &&
                  x >= descriptor.frame.x && x < descriptor.frame.maxX &&
                  y >= descriptor.frame.y && y < descriptor.frame.maxY
              }) else {
            state.pendingClassDrag = nil
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        state.pendingClassDrag = RPGClassDrag(originX: x, originY: y, currentX: x, currentY: y,
            screenInstanceID: context.screenInstanceID, semanticRevision: context.semanticRevision)
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .updateClassDrag(let x, let y):
        guard var drag = state.pendingClassDrag else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        guard validClassDragPoint(x: x, y: y, model: context.model) else {
            state.pendingClassDrag = nil
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
        }
        drag.currentX = x
        drag.currentY = y
        state.pendingClassDrag = drag
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .endClassDrag(let x, let y):
        guard let drag = state.pendingClassDrag else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        state.pendingClassDrag = nil
        guard validClassDragPoint(x: x, y: y, model: context.model) else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
        }
        let dx = x - drag.originX
        let dy = y - drag.originY
        guard dx.isFinite, dy.isFinite, abs(dx) >= RPG_CLASS_SWIPE_THRESHOLD,
              abs(dx) > abs(dy) else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
        }
        switch rpgReduceCreationSession(state.creation, command: .cyclePath(dx < 0 ? 1 : -1)) {
        case .success(let creation): state.creation = creation
        case .failure(let error):
            return RPGScreenInteractionTransition(state: state, effects: effects,
                                                  handled: true, creationError: error)
        }
        state.scrollOffset = 0
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .cancelClassDrag:
        let handled = state.pendingClassDrag != nil
        state.pendingClassDrag = nil
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: handled)

    case .focusElement(let id):
        guard let descriptor = context.model.descriptors.first(where: {
            $0.id == id && $0.isFocusable
        }) else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        var revealed = state
        rpgSelectInteractionDescriptor(descriptor, state: &revealed)
        guard rpgRevealInteractionFocus(&revealed, model: context.model) else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        state = revealed
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .focusNext, .focusPrevious:
        let forward = event == .focusNext
        var revealed = state
        revealed.focusedID = rpgNextFocusableID(
            in: context.model.descriptors, current: state.focusedID, forward: forward)
        if let id = revealed.focusedID,
           let descriptor = context.model.descriptors.first(where: { $0.id == id }) {
            rpgSelectInteractionDescriptor(descriptor, state: &revealed)
        }
        guard rpgRevealInteractionFocus(&revealed, model: context.model) else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        state = revealed
        return RPGScreenInteractionTransition(
            state: state, effects: effects, handled: state.focusedID != nil)

    case .moveFocus(let direction):
        guard let id = rpgSpatialFocusableID(
                in: context.model.descriptors, current: state.focusedID, direction: direction),
              let descriptor = context.model.descriptors.first(where: { $0.id == id }) else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        var revealed = state
        rpgSelectInteractionDescriptor(descriptor, state: &revealed)
        guard rpgRevealInteractionFocus(&revealed, model: context.model) else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        state = revealed
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .scrollRows(let rows):
        guard rows != 0, context.model.contentHeight > context.model.viewportHeight else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        let delta = Double(rows) * RPG_SCREEN_SCROLL_STRIDE
        let sum = state.scrollOffset + delta
        let requested = sum.isFinite ? sum
            : (delta > 0 ? Double.greatestFiniteMagnitude : 0)
        state.scrollOffset = rpgClampedScrollOffset(
            contentHeight: context.model.contentHeight,
            viewportHeight: context.model.viewportHeight,
            requested: requested)
        // Explicit scroll establishes a new user-selected screen position. The subsequent
        // provisional rebuild will seed a fresh anchor at that position instead of snapping back
        // to a pre-scroll frame on this or the next event.
        state.focusedScreenFrame = nil
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .activateFocused:
        guard let id = state.focusedID,
              let descriptor = context.model.descriptors.first(where: { $0.id == id }),
              descriptor.isFocusable else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        rpgSelectInteractionDescriptor(descriptor, state: &state)
        guard descriptor.isActionable else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
        }
        effects.append(.activate(id))
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .mouseDown(let id, let capture):
        if let pending = state.pendingMouseActivation {
            effects.append(.cancelMouse(pending.capture))
            state.pendingMouseActivation = nil
        }
        guard let descriptor = context.model.visibleDescriptors.first(where: {
                $0.id == id && $0.visibleFrame != nil && $0.isFocusable
              }) else {
            if let capture { effects.append(.cancelMouse(capture)) }
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        rpgSelectInteractionDescriptor(descriptor, state: &state)
        guard descriptor.isActionable else {
            if let capture { effects.append(.cancelMouse(capture)) }
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
        }
        guard let capture,
              let ownership = RPGScreenMouseActivation(
                screenInstanceID: context.screenInstanceID,
                semanticRevision: context.semanticRevision,
                elementID: id, capture: capture) else {
            if let capture { effects.append(.cancelMouse(capture)) }
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
        }
        state.pendingMouseActivation = ownership
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .mouseUp(let releasedID):
        guard let pending = state.pendingMouseActivation else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        state.pendingMouseActivation = nil
        let descriptor = context.model.visibleDescriptors.first {
            $0.id == pending.elementID && $0.visibleFrame != nil
        }
        if pending.screenInstanceID == context.screenInstanceID,
           pending.semanticRevision == context.semanticRevision,
           releasedID == pending.elementID,
           descriptor?.isFocusable == true, descriptor?.isActionable == true {
            effects.append(.dispatchMouse(pending.capture))
        } else {
            effects.append(.cancelMouse(pending.capture))
        }
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .cancelMouse, .inputOwnershipLost:
        if let pending = state.pendingMouseActivation {
            effects.append(.cancelMouse(pending.capture))
            state.pendingMouseActivation = nil
        }
        if state.pendingClassDrag != nil { state.pendingClassDrag = nil }
        return RPGScreenInteractionTransition(state: state, effects: effects,
                                              handled: !effects.isEmpty)

    case .applyCommand(let command, let tutorialCompletionPublished):
        return rpgApplyScreenPresentationCommand(
            state, command: command,
            tutorialCompletionPublished: tutorialCompletionPublished,
            carriedEffects: effects)
    }
}

private func rpgApplyScreenPresentationCommand(
    _ current: RPGScreenInteractionState,
    command: RPGSemanticCommand,
    tutorialCompletionPublished: Bool,
    carriedEffects: [RPGScreenInteractionEffect]
) -> RPGScreenInteractionTransition {
    var state = current
    var effects = carriedEffects

    func creation(_ command: RPGCreationSessionCommand)
        -> RPGScreenInteractionTransition {
        switch rpgReduceCreationSession(state.creation, command: command) {
        case .success(let next):
            state.creation = next
            state.scrollOffset = 0
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
        case .failure(let error):
            return RPGScreenInteractionTransition(
                state: state, effects: effects, handled: true, creationError: error)
        }
    }

    switch command {
    case .create:
        // The app re-seeds this from the post-dispatch runtime only when creation committed.
        state.tutorial = RPGTutorialState()
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
    case .choosePath(let id): return creation(.selectPath(id))
    case .previousClass: return creation(.cyclePath(-1))
    case .nextClass: return creation(.cyclePath(1))
    case .chooseBranch(let id): return creation(.selectBranch(id))
    case .adjustAttribute(let attribute, let delta):
        return creation(.adjustAttribute(attribute, delta))
    case .resetAttributes: return creation(.resetToPreset)
    case .creationNext: return creation(.next)
    case .creationBack:
        if state.creation.step == .path {
            effects.append(.close)
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
        }
        return creation(.back)

    case .selectTab(let tab):
        state.tab = tab
        state.focusedID = .tab(tab)
        state.scrollOffset = 0
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
    case .previousTab, .nextTab:
        state.tab = rpgCyclicTab(state.tab, delta: command == .previousTab ? -1 : 1)
        state.focusedID = .tab(state.tab)
        state.scrollOffset = 0
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
    case .selectElement(let id):
        state.focusedID = id
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .tutorialBack:
        guard state.tutorial.seenVersion < RPG_TUTORIAL_VERSION,
              state.tutorial.page != nil else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        state.tutorial = rpgTutorialAfter(.tutorialBack, state: state.tutorial)
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
    case .tutorialNext:
        guard state.tutorial.seenVersion < RPG_TUTORIAL_VERSION,
              let page = state.tutorial.page, page < RPG_TUTORIAL_PAGES.count else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        state.tutorial = rpgTutorialAfter(.tutorialNext, state: state.tutorial)
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
    case .tutorialFinish:
        guard tutorialCompletionPublished,
              state.tutorial.seenVersion < RPG_TUTORIAL_VERSION,
              state.tutorial.page == RPG_TUTORIAL_PAGES.count else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        state.tutorial = rpgTutorialAfter(.tutorialFinish, state: state.tutorial)
        effects.append(.close)
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)
    case .tutorialSkip:
        guard tutorialCompletionPublished,
              state.tutorial.seenVersion < RPG_TUTORIAL_VERSION,
              state.tutorial.page != nil else {
            return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
        }
        state.tutorial = rpgTutorialAfter(.tutorialSkip, state: state.tutorial)
        effects.append(.close)
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    case .back:
        effects.append(.close)
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: true)

    // These are dispatcher/GameCore operations or raw input vocabulary. They do not own local
    // presentation state and are intentionally ignored by this presentation reducer.
    default:
        return RPGScreenInteractionTransition(state: state, effects: effects, handled: false)
    }
}
