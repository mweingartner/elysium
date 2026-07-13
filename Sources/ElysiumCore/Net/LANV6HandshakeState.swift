import Foundation

public let LAN_V6_HANDSHAKE_PROGRESS_TIMEOUT_NANOSECONDS: UInt64 = 10_000_000_000

/// The admission variants are intentionally independent of their secret
/// material. State-machine callers may route on the already strictly decoded
/// variant, but may not retain a join code, token, or claim nonce here.
public enum LANV6HelloAdmissionKind: String, CaseIterable, Codable, Equatable, Hashable {
    case joinNew
    case resume
    case legacyClaim
    case legacyConsume
}

public enum LANV6HandshakeTransitionError: Error, Equatable {
    case invalidTransition
    case deadlineExpired
    case monotonicClockRegressed
}

private func lanV6Deadline(after now: UInt64) -> UInt64 {
    let (deadline, overflow) = now.addingReportingOverflow(
        LAN_V6_HANDSHAKE_PROGRESS_TIMEOUT_NANOSECONDS
    )
    return overflow ? UInt64.max : deadline
}

private func lanV6ValidateMonotonicTime(now: UInt64, previous: UInt64) throws {
    guard now >= previous else {
        throw LANV6HandshakeTransitionError.monotonicClockRegressed
    }
}

public enum LANV6HostHandshakeState: String, CaseIterable, Equatable, Hashable {
    case awaitingHello
    case awaitingClientReady
    case readyAwaitingOwnerBudget
    case authenticated
    case closing

    public var connectionPhase: LANV6ConnectionPhase {
        switch self {
        case .awaitingHello: return .awaitingHello
        case .awaitingClientReady: return .awaitingClientReady
        case .readyAwaitingOwnerBudget: return .readyAwaitingOwnerBudget
        case .authenticated: return .authenticated
        case .closing: return .closing
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .authenticated, .closing: return true
        default: return false
        }
    }
}

/// Events name completed side effects, not mere requests to perform them. For
/// example, `.admissionPersisted` may only be applied after the credential CAS
/// has committed. This keeps the pure machine from publishing a phase ahead of
/// durable authority state.
public enum LANV6HostHandshakeEvent: Equatable {
    case admissionPersisted(LANV6HelloAdmissionKind)
    case detachedLegacyClaimPersisted
    case clientReadyValidated
    case ownerBudgetReservedAdmissionSlotTransferredCredentialPromotedAndRequestZeroEnqueued
    case close
}

public enum LANV6HostHandshakeAction: Equatable {
    case sendServerAccept
    case closeAfterDetachedLegacyClaim
    case reserveOwnerBudgetTransferAdmissionSlotPromoteCredentialAndEnqueueRequestZero
    case beginAuthenticatedTraffic
    case none
    case close
}

/// A deterministic handshake state machine. Transport and persistence own all
/// effects; this value owns only legal transition order and the ten-second
/// monotonic progress deadline.
public struct LANV6HostHandshakeMachine: Equatable {
    public private(set) var state: LANV6HostHandshakeState
    public private(set) var progressDeadlineNanoseconds: UInt64
    public private(set) var lastObservedNanoseconds: UInt64

    public init(nowNanoseconds: UInt64) {
        state = .awaitingHello
        progressDeadlineNanoseconds = lanV6Deadline(after: nowNanoseconds)
        lastObservedNanoseconds = nowNanoseconds
    }

    public var connectionPhase: LANV6ConnectionPhase { state.connectionPhase }

    public func isExpired(at nowNanoseconds: UInt64) throws -> Bool {
        try lanV6ValidateMonotonicTime(
            now: nowNanoseconds, previous: lastObservedNanoseconds
        )
        guard !state.isTerminal else { return false }
        return nowNanoseconds >= progressDeadlineNanoseconds
    }

    @discardableResult
    public mutating func expireIfNeeded(at nowNanoseconds: UInt64) throws -> Bool {
        try lanV6ValidateMonotonicTime(now: nowNanoseconds, previous: lastObservedNanoseconds)
        lastObservedNanoseconds = nowNanoseconds
        guard !state.isTerminal, nowNanoseconds >= progressDeadlineNanoseconds else {
            return false
        }
        state = .closing
        return true
    }

    @discardableResult
    public mutating func apply(
        _ event: LANV6HostHandshakeEvent,
        at nowNanoseconds: UInt64
    ) throws -> LANV6HostHandshakeAction {
        try lanV6ValidateMonotonicTime(now: nowNanoseconds, previous: lastObservedNanoseconds)
        lastObservedNanoseconds = nowNanoseconds

        if !state.isTerminal, nowNanoseconds >= progressDeadlineNanoseconds {
            state = .closing
            throw LANV6HandshakeTransitionError.deadlineExpired
        }

        switch (state, event) {
        case (.awaitingHello, .admissionPersisted(let kind))
            where kind == .joinNew || kind == .resume || kind == .legacyConsume:
            state = .awaitingClientReady
            resetDeadline(after: nowNanoseconds)
            return .sendServerAccept

        case (.awaitingHello, .detachedLegacyClaimPersisted):
            state = .closing
            return .closeAfterDetachedLegacyClaim

        case (.awaitingClientReady, .clientReadyValidated):
            state = .readyAwaitingOwnerBudget
            resetDeadline(after: nowNanoseconds)
            return .reserveOwnerBudgetTransferAdmissionSlotPromoteCredentialAndEnqueueRequestZero

        case (.readyAwaitingOwnerBudget,
              .ownerBudgetReservedAdmissionSlotTransferredCredentialPromotedAndRequestZeroEnqueued):
            state = .authenticated
            return .beginAuthenticatedTraffic

        case (.awaitingHello, .close),
             (.awaitingClientReady, .close),
             (.readyAwaitingOwnerBudget, .close),
             (.authenticated, .close):
            state = .closing
            return .close

        case (.closing, .close):
            return .none

        default:
            throw LANV6HandshakeTransitionError.invalidTransition
        }
    }

    private mutating func resetDeadline(after nowNanoseconds: UInt64) {
        progressDeadlineNanoseconds = lanV6Deadline(after: nowNanoseconds)
    }
}

public enum LANV6ClientHandshakeState: String, CaseIterable, Equatable, Hashable {
    case connecting
    case awaitingServerAccept
    case awaitingInitialOwner
    case connected
    case rejected

    public var connectionPhase: LANV6ConnectionPhase {
        switch self {
        case .connecting: return .connecting
        case .awaitingServerAccept: return .awaitingServerAccept
        case .awaitingInitialOwner: return .awaitingInitialOwner
        case .connected: return .connected
        case .rejected: return .rejected
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .connected, .rejected: return true
        default: return false
        }
    }
}

public enum LANV6ClientHandshakeEvent: Equatable {
    case transportConnectedAndHelloSent
    case serverAcceptCredentialPersisted
    case serverRejected
    case initialOwnerBundleCheckpointed
    case close
}

public enum LANV6ClientHandshakeAction: Equatable {
    case awaitServerDecision
    /// The machine has already entered `.awaitingInitialOwner`, whose named
    /// frame policy admits `clientReady`; the transport sends it only after
    /// observing this action.
    case sendClientReadyAndAwaitInitialOwner
    case beginConnectedTraffic
    case rejected
    case none
}

public struct LANV6ClientHandshakeMachine: Equatable {
    public private(set) var state: LANV6ClientHandshakeState
    public private(set) var progressDeadlineNanoseconds: UInt64
    public private(set) var lastObservedNanoseconds: UInt64

    public init(nowNanoseconds: UInt64) {
        state = .connecting
        progressDeadlineNanoseconds = lanV6Deadline(after: nowNanoseconds)
        lastObservedNanoseconds = nowNanoseconds
    }

    public var connectionPhase: LANV6ConnectionPhase { state.connectionPhase }

    public func isExpired(at nowNanoseconds: UInt64) throws -> Bool {
        try lanV6ValidateMonotonicTime(
            now: nowNanoseconds, previous: lastObservedNanoseconds
        )
        guard !state.isTerminal else { return false }
        return nowNanoseconds >= progressDeadlineNanoseconds
    }

    @discardableResult
    public mutating func expireIfNeeded(at nowNanoseconds: UInt64) throws -> Bool {
        try lanV6ValidateMonotonicTime(now: nowNanoseconds, previous: lastObservedNanoseconds)
        lastObservedNanoseconds = nowNanoseconds
        guard !state.isTerminal, nowNanoseconds >= progressDeadlineNanoseconds else {
            return false
        }
        state = .rejected
        return true
    }

    @discardableResult
    public mutating func apply(
        _ event: LANV6ClientHandshakeEvent,
        at nowNanoseconds: UInt64
    ) throws -> LANV6ClientHandshakeAction {
        try lanV6ValidateMonotonicTime(now: nowNanoseconds, previous: lastObservedNanoseconds)
        lastObservedNanoseconds = nowNanoseconds

        if !state.isTerminal, nowNanoseconds >= progressDeadlineNanoseconds {
            state = .rejected
            throw LANV6HandshakeTransitionError.deadlineExpired
        }

        switch (state, event) {
        case (.connecting, .transportConnectedAndHelloSent):
            state = .awaitingServerAccept
            resetDeadline(after: nowNanoseconds)
            return .awaitServerDecision

        case (.awaitingServerAccept, .serverAcceptCredentialPersisted):
            state = .awaitingInitialOwner
            resetDeadline(after: nowNanoseconds)
            return .sendClientReadyAndAwaitInitialOwner

        case (.awaitingServerAccept, .serverRejected):
            state = .rejected
            return .rejected

        case (.awaitingInitialOwner, .serverRejected):
            state = .rejected
            return .rejected

        case (.awaitingInitialOwner, .initialOwnerBundleCheckpointed):
            state = .connected
            return .beginConnectedTraffic

        case (.connecting, .close),
             (.awaitingServerAccept, .close),
             (.awaitingInitialOwner, .close),
             (.connected, .close):
            state = .rejected
            return .rejected

        case (.rejected, .close):
            return .none

        default:
            throw LANV6HandshakeTransitionError.invalidTransition
        }
    }

    private mutating func resetDeadline(after nowNanoseconds: UInt64) {
        progressDeadlineNanoseconds = lanV6Deadline(after: nowNanoseconds)
    }
}
