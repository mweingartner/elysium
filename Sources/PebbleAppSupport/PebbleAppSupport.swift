import Foundation

public enum PebbleLaunchRevealKind: Equatable, Sendable {
    case fullscreen
    case windowedFallback
}

public struct PebbleLaunchRevealToken<WindowIdentity: Equatable> {
    public let windowIdentity: WindowIdentity
    public let generation: UInt64
    public let kind: PebbleLaunchRevealKind
}

public struct PebbleLaunchRevealPredicates: Equatable, Sendable {
    public let opaque: Bool
    public let visible: Bool
    public let ordinaryLevel: Bool
    public let mouseAccepting: Bool
    public let finitePositiveGeometry: Bool
    public let onScreen: Bool
    public let fullscreenEntered: Bool
    public let fullscreenStyle: Bool
    public let keyWindow: Bool

    public init(opaque: Bool, visible: Bool, ordinaryLevel: Bool, mouseAccepting: Bool,
                finitePositiveGeometry: Bool, onScreen: Bool, fullscreenEntered: Bool,
                fullscreenStyle: Bool, keyWindow: Bool) {
        self.opaque = opaque
        self.visible = visible
        self.ordinaryLevel = ordinaryLevel
        self.mouseAccepting = mouseAccepting
        self.finitePositiveGeometry = finitePositiveGeometry
        self.onScreen = onScreen
        self.fullscreenEntered = fullscreenEntered
        self.fullscreenStyle = fullscreenStyle
        self.keyWindow = keyWindow
    }
}

public enum PebbleLaunchActivationDecision: Equatable, Sendable {
    case noRequest
    case request
}

/// Pure fail-closed kernel for the AppKit reveal coordinator. The first consume closes the state
/// regardless of validity, so stale, repeated and re-entrant reveal paths can never request later.
public struct PebbleLaunchActivationState<WindowIdentity: Equatable> {
    private let windowIdentity: WindowIdentity
    private let generation: UInt64
    public private(set) var isClosed = false

    public init(windowIdentity: WindowIdentity, generation: UInt64) {
        self.windowIdentity = windowIdentity
        self.generation = generation
    }

    public func token(kind: PebbleLaunchRevealKind, windowIdentity: WindowIdentity,
                      generation: UInt64) -> PebbleLaunchRevealToken<WindowIdentity> {
        PebbleLaunchRevealToken(
            windowIdentity: windowIdentity, generation: generation, kind: kind)
    }

    public mutating func consume(
        _ token: PebbleLaunchRevealToken<WindowIdentity>,
        predicates: PebbleLaunchRevealPredicates,
        applicationActive: Bool
    ) -> PebbleLaunchActivationDecision {
        guard !isClosed else { return .noRequest }
        isClosed = true
        guard token.windowIdentity == windowIdentity, token.generation == generation,
              predicates.opaque, predicates.visible, predicates.ordinaryLevel,
              predicates.mouseAccepting, predicates.finitePositiveGeometry,
              predicates.onScreen, applicationActive || !predicates.keyWindow else {
            return .noRequest
        }
        switch token.kind {
        case .fullscreen:
            guard predicates.fullscreenEntered, predicates.fullscreenStyle else {
                return .noRequest
            }
        case .windowedFallback:
            guard !predicates.fullscreenEntered, !predicates.fullscreenStyle else {
                return .noRequest
            }
        }
        return applicationActive ? .noRequest : .request
    }
}

public enum PebbleAppInputEntrySource: Equatable, Sendable {
    case performKeyEquivalent, keyDown, flagsChanged
}
public enum PebbleExhaustedInputDisposition: Equatable, Sendable { case consume, passThrough }
public func pebbleExhaustedInputDisposition(
    source: PebbleAppInputEntrySource, protectedEquivalent: Bool
) -> PebbleExhaustedInputDisposition {
    switch source {
    case .keyDown: return .consume
    case .performKeyEquivalent: return protectedEquivalent ? .consume : .passThrough
    case .flagsChanged: return .passThrough
    }
}

/// Stateful seam shared by each AppKit keyboard entry point. Exhaustion is latched until the
/// explicit input-session reset; modifier changes may update one bounded mask but may not dispatch.
public final class PebbleAppInputExhaustionLatch: @unchecked Sendable {
    private let lock = NSLock()
    public private(set) var isExhausted = false
    public private(set) var lastModifierMask: UInt64 = 0

    public init() {}

    public func exhaust() { lock.withLock { isExhausted = true } }

    public func resetInputSession() {
        lock.withLock {
            isExhausted = false
            lastModifierMask = 0
        }
    }

    public func disposition(
        source: PebbleAppInputEntrySource, protectedEquivalent: Bool
    ) -> PebbleExhaustedInputDisposition? {
        lock.withLock {
            guard isExhausted else { return nil }
            return pebbleExhaustedInputDisposition(
                source: source, protectedEquivalent: protectedEquivalent)
        }
    }

    /// Returns whether the caller may synthesize modifier edges for this entry.
    public func recordFlagsChanged(mask: UInt64) -> Bool {
        lock.withLock {
            lastModifierMask = mask
            return !isExhausted
        }
    }

    public func mayDispatchRelease() -> Bool { lock.withLock { !isExhausted } }
}

public enum PebbleRetainedTreeMutation<Node: AnyObject> {
    case scalarRefresh([Node])
    case structuralReplacement(old: [Node], current: [Node])
}

/// Reference-preserving decision seam used by the RPG Accessibility bridge. Equal keys can only
/// return the existing objects for scalar refresh; structural changes alone allocate replacements.
public final class PebbleRetainedTreeStore<Node: AnyObject> {
    private var key: PebbleRetainedStructureKey?
    private var nodes: [Node] = []

    public init() {}

    public func update(
        key newKey: PebbleRetainedStructureKey, makeNodes: () -> [Node]
    ) -> PebbleRetainedTreeMutation<Node> {
        if key == newKey {
            return .scalarRefresh(nodes)
        }
        let previous = nodes
        let replacement = makeNodes()
        key = newKey
        nodes = replacement
        return .structuralReplacement(old: previous, current: replacement)
    }

    public func invalidate() -> [Node] {
        defer { key = nil; nodes = [] }
        return nodes
    }
}
public struct PebbleRetainedStructureKey: Equatable, Sendable {
    public let screenIdentity: UInt64
    public let generation: UInt64
    public let orderedDescriptors: [PebbleRetainedDescriptorKey]
    public init(screenIdentity: UInt64, generation: UInt64,
                orderedDescriptors: [PebbleRetainedDescriptorKey]) {
        self.screenIdentity = screenIdentity; self.generation = generation
        self.orderedDescriptors = orderedDescriptors
    }
}
public struct PebbleRetainedDescriptorKey: Equatable, Sendable {
    public let id: String; public let role: String; public let parentID: String?
    public let actionable: Bool; public let focusable: Bool
    public init(id: String, role: String, parentID: String?, actionable: Bool, focusable: Bool) {
        self.id = id; self.role = role; self.parentID = parentID
        self.actionable = actionable; self.focusable = focusable
    }
}
