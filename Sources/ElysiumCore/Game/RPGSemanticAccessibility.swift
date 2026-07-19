import Foundation

public struct RPGAccessibilityViewport: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init?(x: Double = 0, y: Double = 0, width: Double, height: Double) {
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite,
              width > 0, height > 0 else { return nil }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

/// Checked publication generation. Transient viewport/tree failure returns nil without advancing or
/// latching; only true UInt64 exhaustion permanently closes later publication.
public struct RPGAccessibilityPublicationClock: Equatable {
    public private(set) var generation: UInt64
    public private(set) var exhausted: Bool

    public init(generation: UInt64 = 0, exhausted: Bool = false) {
        self.generation = generation
        self.exhausted = exhausted
    }

    public mutating func publish<Value>(_ build: (UInt64) -> Value?) -> Value? {
        guard !exhausted else { return nil }
        let addition = generation.addingReportingOverflow(1)
        guard !addition.overflow, addition.partialValue != 0 else {
            exhausted = true
            return nil
        }
        guard let value = build(addition.partialValue) else { return nil }
        generation = addition.partialValue
        return value
    }
}

/// Pure checked GUI-top-left to view-point projection. AppKit performs the final view/window/screen
/// conversion only after every arithmetic intermediate has passed these finite bounded checks.
public func rpgAccessibilityViewFrame(
    logical: RPGLogicalRect,
    uiScale: Double,
    backingScale: Double,
    viewWidth: Double,
    viewHeight: Double
) -> RPGLogicalRect? {
    let inputs = [logical.x, logical.y, logical.width, logical.height,
                  uiScale, backingScale, viewWidth, viewHeight]
    guard inputs.allSatisfy(\.isFinite), logical.width > 0, logical.height > 0,
          uiScale > 0, uiScale <= 64, backingScale > 0, backingScale <= 8,
          viewWidth > 0, viewHeight > 0,
          viewWidth <= 1_000_000, viewHeight <= 1_000_000,
          abs(logical.x) <= 1_000_000, abs(logical.y) <= 1_000_000,
          logical.width <= 1_000_000, logical.height <= 1_000_000 else { return nil }
    let logicalBottom = logical.y + logical.height
    let scaledX = logical.x * uiScale
    let scaledBottom = logicalBottom * uiScale
    let scaledWidth = logical.width * uiScale
    let scaledHeight = logical.height * uiScale
    guard [logicalBottom, scaledX, scaledBottom, scaledWidth, scaledHeight]
        .allSatisfy(\.isFinite) else { return nil }
    let x = scaledX / backingScale
    let width = scaledWidth / backingScale
    let height = scaledHeight / backingScale
    let top = scaledBottom / backingScale
    let y = viewHeight - top
    let maximumExtent = max(viewWidth, viewHeight) * 256
    guard [x, y, width, height, top, maximumExtent].allSatisfy(\.isFinite),
          width > 0, height > 0,
          width <= maximumExtent, height <= maximumExtent,
          abs(x) <= maximumExtent, abs(y) <= maximumExtent else { return nil }
    return RPGLogicalRect(x: x, y: y, width: width, height: height)
}

public struct RPGAccessibilityElementSnapshot: Equatable {
    public let descriptor: RPGSemanticDescriptor
    public let activationOrigin: RPGSemanticActivationOrigin?
    public let layoutGeneration: UInt64
    public let viewport: RPGAccessibilityViewport
    public let accessibilityValue: String
    public let accessibilityHelp: String
    public var hasPressAction: Bool { activationOrigin != nil && descriptor.isActionable }

    public init?(descriptor: RPGSemanticDescriptor,
                 activationOrigin: RPGSemanticActivationOrigin?,
                 layoutGeneration: UInt64, viewport: RPGAccessibilityViewport) {
        guard layoutGeneration > 0,
              (descriptor.isActionable == (activationOrigin != nil)) else { return nil }
        self.descriptor = descriptor
        self.activationOrigin = activationOrigin
        self.layoutGeneration = layoutGeneration
        self.viewport = viewport
        if descriptor.id.rawValue == "authority:phase" ||
            descriptor.id.rawValue == "status:current" {
            accessibilityValue = descriptor.value
        } else {
            var values: [String] = []
            if !descriptor.value.isEmpty { values.append(descriptor.value) }
            if let pips = descriptor.rankPips { values.append("Rank \(pips.filled) of \(pips.total)") }
            if descriptor.selected { values.append("Selected") }
            if descriptor.prepared { values.append("Prepared") }
            if descriptor.slotted { values.append("Slotted") }
            values.append(descriptor.locked ? "Locked" : descriptor.enabled ? "Enabled" : "Disabled")
            accessibilityValue = values.joined(separator: ", ")
        }
        accessibilityHelp = descriptor.help
    }
}

public struct RPGAccessibilityTreeSnapshot: Equatable {
    public let screenInstanceID: UInt64
    public let semanticRevision: UInt64
    public let layoutGeneration: UInt64
    public let viewport: RPGAccessibilityViewport
    public let elements: [RPGAccessibilityElementSnapshot]
    public let focusedID: RPGUIElementID?
    public let highContrast: Bool
    public let reduceMotion: Bool

    public init?(committed: RPGCommittedSemanticSnapshot,
                 layoutGeneration: UInt64,
                 viewport: RPGAccessibilityViewport) {
        guard layoutGeneration > 0 else { return nil }
        var values: [RPGAccessibilityElementSnapshot] = []
        if committed.model.descriptors.contains(where: { $0.role == .tab }),
           let tabGroupID = RPGUIElementID(rawValue: "accessibility:tab-group") {
            let tabGroup = RPGSemanticDescriptor(
                id: tabGroupID, role: .group, label: "Character sections",
                value: "Five character tabs", enabled: true, isFocusable: false,
                frame: committed.model.panelFrame,
                visibleFrame: committed.model.panelFrame)
            guard let element = RPGAccessibilityElementSnapshot(
                descriptor: tabGroup, activationOrigin: nil,
                layoutGeneration: layoutGeneration, viewport: viewport) else { return nil }
            values.append(element)
        }
        let skillCardCount = committed.model.descriptors.filter { $0.rankPips != nil && $0.role == .row }.count
        if skillCardCount == 9, let projection = committed.model.projection,
           let rootID = RPGUIElementID(rawValue: "accessibility:skills-root") {
            let root = RPGSemanticDescriptor(
                id: rootID, role: .scrollArea,
                label: "\(projection.pathID.capitalized) Skills",
                value: "3 sub-classes, 9 skills, 5 ranks each",
                help: "Current character path skill ranks.", enabled: true,
                isFocusable: false, frame: committed.model.contentFrame,
                visibleFrame: committed.model.contentFrame)
            guard let element = RPGAccessibilityElementSnapshot(
                descriptor: root, activationOrigin: nil,
                layoutGeneration: layoutGeneration, viewport: viewport) else { return nil }
            values.append(element)
        }
        for descriptor in committed.model.descriptors {
            let origin: RPGSemanticActivationOrigin?
            if descriptor.isActionable,
               let input = committed.semanticInputs[descriptor.id] {
                origin = RPGSemanticActivationOrigin(
                    screenInstanceID: committed.screenInstanceID,
                    semanticRevision: committed.semanticRevision,
                    descriptor: descriptor, input: input)
            } else {
                origin = nil
            }
            guard let element = RPGAccessibilityElementSnapshot(
                descriptor: descriptor, activationOrigin: origin,
                layoutGeneration: layoutGeneration, viewport: viewport) else { return nil }
            values.append(element)
        }
        self.screenInstanceID = committed.screenInstanceID
        self.semanticRevision = committed.semanticRevision
        self.layoutGeneration = layoutGeneration
        self.viewport = viewport
        self.elements = values
        self.focusedID = committed.model.focusedID
        self.highContrast = committed.highContrast
        self.reduceMotion = committed.reduceMotion
    }

    /// Internal deterministic seam for origin/cache invalidation tests. Production publication uses
    /// only the committed-model initializer above.
    init?(screenInstanceID: UInt64, semanticRevision: UInt64,
          layoutGeneration: UInt64, viewport: RPGAccessibilityViewport,
          elements: [RPGAccessibilityElementSnapshot], focusedID: RPGUIElementID?,
          highContrast: Bool, reduceMotion: Bool) {
        guard screenInstanceID > 0, semanticRevision > 0, layoutGeneration > 0,
              elements.allSatisfy({ $0.layoutGeneration == layoutGeneration &&
                  $0.viewport == viewport }) else { return nil }
        self.screenInstanceID = screenInstanceID
        self.semanticRevision = semanticRevision
        self.layoutGeneration = layoutGeneration
        self.viewport = viewport
        self.elements = elements
        self.focusedID = focusedID
        self.highContrast = highContrast
        self.reduceMotion = reduceMotion
    }
}

public enum RPGAccessibilityNotificationIntent: String, CaseIterable, Equatable {
    case focusedElementChanged
    case valueChanged
    case layoutChanged
}

/// Returns the one bounded VoiceOver announcement required by an initial publication or an exact
/// authority value/help transition. Byte-identical rebuilds deliberately return nil.
public func rpgAccessibilityAuthorityAnnouncement(
    previous: RPGAccessibilityTreeSnapshot?,
    current: RPGAccessibilityTreeSnapshot
) -> String? {
    func authority(_ tree: RPGAccessibilityTreeSnapshot) -> RPGAccessibilityElementSnapshot? {
        tree.elements.first { $0.descriptor.id.rawValue == "authority:phase" }
    }
    guard let currentAuthority = authority(current) else { return nil }
    if let previous, let old = authority(previous),
       old.descriptor.value == currentAuthority.descriptor.value,
       old.accessibilityHelp == currentAuthority.accessibilityHelp { return nil }
    let separator = currentAuthority.accessibilityHelp.isEmpty ? "" : ". "
    return rpgSanitizeStatusText(
        currentAuthority.descriptor.value + separator + currentAuthority.accessibilityHelp,
        byteLimit: 512)
}

/// The creation step-indicator title ("Path · Step 1 of 4", etc.) to announce when the creation
/// flow advances or steps back, or when the creation sheet first appears (D4). Returns nil when the
/// step is unchanged, so a focus/scroll rebuild does not re-announce the same step.
public func rpgAccessibilityCreationStepAnnouncement(
    previous: RPGAccessibilityTreeSnapshot?,
    current: RPGAccessibilityTreeSnapshot
) -> String? {
    func step(_ tree: RPGAccessibilityTreeSnapshot) -> RPGAccessibilityElementSnapshot? {
        tree.elements.first { $0.descriptor.id.rawValue.hasPrefix("creation-step:") }
    }
    guard let currentStep = step(current), !currentStep.descriptor.value.isEmpty else { return nil }
    if let previous, let old = step(previous),
       old.descriptor.value == currentStep.descriptor.value { return nil }
    return rpgSanitizeStatusText(currentStep.descriptor.value, byteLimit: 512)
}

public func rpgAccessibilityNotificationIntents(
    previous: RPGAccessibilityTreeSnapshot?,
    current: RPGAccessibilityTreeSnapshot
) -> [RPGAccessibilityNotificationIntent] {
    guard let previous else { return [.layoutChanged] }
    if previous == current { return [] }
    var intents: [RPGAccessibilityNotificationIntent] = []
    if previous.focusedID != current.focusedID { intents.append(.focusedElementChanged) }
    let oldValues = previous.elements.map {
        ($0.descriptor.id, $0.accessibilityValue, $0.accessibilityHelp)
    }
    let newValues = current.elements.map {
        ($0.descriptor.id, $0.accessibilityValue, $0.accessibilityHelp)
    }
    if oldValues.elementsEqual(newValues, by: { lhs, rhs in
        lhs.0 == rhs.0 && lhs.1 == rhs.1 && lhs.2 == rhs.2
    }) == false { intents.append(.valueChanged) }
    let oldLayout = previous.elements.map {
        ($0.descriptor, $0.activationOrigin)
    }
    let newLayout = current.elements.map {
        ($0.descriptor, $0.activationOrigin)
    }
    let sameLayout = oldLayout.elementsEqual(newLayout, by: { lhs, rhs in
        lhs.0 == rhs.0 && lhs.1 == rhs.1
    }) && previous.screenInstanceID == current.screenInstanceID &&
        previous.semanticRevision == current.semanticRevision &&
        previous.layoutGeneration == current.layoutGeneration &&
        previous.viewport == current.viewport &&
        previous.highContrast == current.highContrast &&
        previous.reduceMotion == current.reduceMotion
    if !sameLayout { intents.append(.layoutChanged) }
    return intents
}
