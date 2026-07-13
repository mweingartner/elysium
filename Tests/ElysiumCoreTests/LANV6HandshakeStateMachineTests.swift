import XCTest
@testable import ElysiumCore

final class LANV6HandshakeStateMachineTests: XCTestCase {
    private let timeout = LAN_V6_HANDSHAKE_PROGRESS_TIMEOUT_NANOSECONDS

    func testHostTransitionMatrixCoversEveryStateAndEvent() throws {
        let events: [(String, LANV6HostHandshakeEvent)] = [
            ("joinNew", .admissionPersisted(.joinNew)),
            ("resume", .admissionPersisted(.resume)),
            ("legacyClaimAdmission", .admissionPersisted(.legacyClaim)),
            ("legacyConsume", .admissionPersisted(.legacyConsume)),
            ("detachedLegacyClaim", .detachedLegacyClaimPersisted),
            ("clientReady", .clientReadyValidated),
            ("ownerReady", .ownerBudgetReservedAdmissionSlotTransferredCredentialPromotedAndRequestZeroEnqueued),
            ("close", .close),
        ]

        for state in LANV6HostHandshakeState.allCases {
            for (eventName, event) in events {
                var machine = try hostMachine(in: state)
                let now = machine.lastObservedNanoseconds + 1
                let expected = expectedHostTransition(state: state, eventName: eventName)

                if let expected {
                    let action = try machine.apply(event, at: now)
                    XCTAssertEqual(action, expected.action, "\(state) + \(eventName)")
                    XCTAssertEqual(machine.state, expected.state, "\(state) + \(eventName)")
                } else {
                    XCTAssertThrowsError(try machine.apply(event, at: now),
                                         "\(state) + \(eventName) must be illegal") { error in
                        XCTAssertEqual(error as? LANV6HandshakeTransitionError,
                                       .invalidTransition)
                    }
                }
            }
        }
    }

    func testClientTransitionMatrixCoversEveryStateAndEvent() throws {
        let events: [(String, LANV6ClientHandshakeEvent)] = [
            ("transportConnected", .transportConnectedAndHelloSent),
            ("serverAccept", .serverAcceptCredentialPersisted),
            ("serverReject", .serverRejected),
            ("initialOwner", .initialOwnerBundleCheckpointed),
            ("close", .close),
        ]

        for state in LANV6ClientHandshakeState.allCases {
            for (eventName, event) in events {
                var machine = try clientMachine(in: state)
                let now = machine.lastObservedNanoseconds + 1
                let expected = expectedClientTransition(state: state, eventName: eventName)

                if let expected {
                    let action = try machine.apply(event, at: now)
                    XCTAssertEqual(action, expected.action, "\(state) + \(eventName)")
                    XCTAssertEqual(machine.state, expected.state, "\(state) + \(eventName)")
                } else {
                    XCTAssertThrowsError(try machine.apply(event, at: now),
                                         "\(state) + \(eventName) must be illegal") { error in
                        XCTAssertEqual(error as? LANV6HandshakeTransitionError,
                                       .invalidTransition)
                    }
                }
            }
        }
    }

    func testHostDeadlineIsOpenBeforeAndClosedAtExactTenSecondBoundary() throws {
        let start: UInt64 = 123
        var probe = LANV6HostHandshakeMachine(nowNanoseconds: start)
        XCTAssertEqual(probe.progressDeadlineNanoseconds, start + timeout)
        XCTAssertFalse(try probe.isExpired(at: start + timeout - 1))
        XCTAssertTrue(try probe.isExpired(at: start + timeout))
        XCTAssertFalse(try probe.expireIfNeeded(at: start + timeout - 1))
        XCTAssertEqual(probe.state, .awaitingHello)
        XCTAssertTrue(try probe.expireIfNeeded(at: start + timeout))
        XCTAssertEqual(probe.state, .closing)
        XCTAssertFalse(try probe.expireIfNeeded(at: start + timeout))

        var transition = LANV6HostHandshakeMachine(nowNanoseconds: start)
        XCTAssertNoThrow(try transition.apply(.admissionPersisted(.joinNew),
                                              at: start + timeout - 1))
        XCTAssertEqual(transition.progressDeadlineNanoseconds,
                       start + timeout - 1 + timeout)
        XCTAssertNoThrow(try transition.apply(.clientReadyValidated,
                                              at: start + timeout))

        var exact = LANV6HostHandshakeMachine(nowNanoseconds: start)
        XCTAssertThrowsError(try exact.apply(.admissionPersisted(.joinNew),
                                             at: start + timeout)) { error in
            XCTAssertEqual(error as? LANV6HandshakeTransitionError, .deadlineExpired)
        }
        XCTAssertEqual(exact.state, .closing)
    }

    func testClientDeadlineIsOpenBeforeAndClosedAtExactTenSecondBoundary() throws {
        let start: UInt64 = 321
        var probe = LANV6ClientHandshakeMachine(nowNanoseconds: start)
        XCTAssertEqual(probe.progressDeadlineNanoseconds, start + timeout)
        XCTAssertFalse(try probe.isExpired(at: start + timeout - 1))
        XCTAssertTrue(try probe.isExpired(at: start + timeout))
        XCTAssertFalse(try probe.expireIfNeeded(at: start + timeout - 1))
        XCTAssertTrue(try probe.expireIfNeeded(at: start + timeout))
        XCTAssertEqual(probe.state, .rejected)

        var transition = LANV6ClientHandshakeMachine(nowNanoseconds: start)
        XCTAssertNoThrow(try transition.apply(.transportConnectedAndHelloSent,
                                              at: start + timeout - 1))
        XCTAssertEqual(transition.progressDeadlineNanoseconds,
                       start + timeout - 1 + timeout)
        XCTAssertNoThrow(try transition.apply(.serverAcceptCredentialPersisted,
                                              at: start + timeout))

        var exact = LANV6ClientHandshakeMachine(nowNanoseconds: start)
        XCTAssertThrowsError(try exact.apply(.transportConnectedAndHelloSent,
                                             at: start + timeout)) { error in
            XCTAssertEqual(error as? LANV6HandshakeTransitionError, .deadlineExpired)
        }
        XCTAssertEqual(exact.state, .rejected)
    }

    func testClockRegressionFailsWithoutMutatingEitherMachine() throws {
        var host = LANV6HostHandshakeMachine(nowNanoseconds: 100)
        let hostBefore = host
        XCTAssertThrowsError(try host.expireIfNeeded(at: 99)) { error in
            XCTAssertEqual(error as? LANV6HandshakeTransitionError,
                           .monotonicClockRegressed)
        }
        XCTAssertEqual(host, hostBefore)
        XCTAssertThrowsError(try host.isExpired(at: 99)) { error in
            XCTAssertEqual(error as? LANV6HandshakeTransitionError,
                           .monotonicClockRegressed)
        }
        XCTAssertEqual(host, hostBefore)
        XCTAssertThrowsError(try host.apply(.admissionPersisted(.joinNew), at: 99)) { error in
            XCTAssertEqual(error as? LANV6HandshakeTransitionError,
                           .monotonicClockRegressed)
        }
        XCTAssertEqual(host, hostBefore)

        var client = LANV6ClientHandshakeMachine(nowNanoseconds: 100)
        let clientBefore = client
        XCTAssertThrowsError(try client.expireIfNeeded(at: 99)) { error in
            XCTAssertEqual(error as? LANV6HandshakeTransitionError,
                           .monotonicClockRegressed)
        }
        XCTAssertEqual(client, clientBefore)
        XCTAssertThrowsError(try client.isExpired(at: 99)) { error in
            XCTAssertEqual(error as? LANV6HandshakeTransitionError,
                           .monotonicClockRegressed)
        }
        XCTAssertEqual(client, clientBefore)
        XCTAssertThrowsError(try client.apply(.transportConnectedAndHelloSent, at: 99)) { error in
            XCTAssertEqual(error as? LANV6HandshakeTransitionError,
                           .monotonicClockRegressed)
        }
        XCTAssertEqual(client, clientBefore)
    }

    func testDeadlineArithmeticSaturatesWithoutWrapping() throws {
        let start = UInt64.max - timeout / 2
        var host = LANV6HostHandshakeMachine(nowNanoseconds: start)
        var client = LANV6ClientHandshakeMachine(nowNanoseconds: start)
        XCTAssertEqual(host.progressDeadlineNanoseconds, UInt64.max)
        XCTAssertEqual(client.progressDeadlineNanoseconds, UInt64.max)
        XCTAssertFalse(try host.isExpired(at: UInt64.max - 1))
        XCTAssertFalse(try client.isExpired(at: UInt64.max - 1))
        XCTAssertNoThrow(try host.apply(.admissionPersisted(.resume), at: UInt64.max - 1))
        XCTAssertNoThrow(try client.apply(.transportConnectedAndHelloSent, at: UInt64.max - 1))
        XCTAssertEqual(host.progressDeadlineNanoseconds, UInt64.max)
        XCTAssertEqual(client.progressDeadlineNanoseconds, UInt64.max)
        XCTAssertThrowsError(try host.apply(.clientReadyValidated, at: UInt64.max)) {
            XCTAssertEqual($0 as? LANV6HandshakeTransitionError, .deadlineExpired)
        }
        XCTAssertThrowsError(try client.apply(.serverAcceptCredentialPersisted,
                                              at: UInt64.max)) {
            XCTAssertEqual($0 as? LANV6HandshakeTransitionError, .deadlineExpired)
        }
    }

    func testSuccessfulTransitionsResetDeadlineAndTerminalStatesDoNotExpire() throws {
        var host = LANV6HostHandshakeMachine(nowNanoseconds: 0)
        _ = try host.apply(.admissionPersisted(.legacyConsume), at: 10)
        XCTAssertEqual(host.progressDeadlineNanoseconds, 10 + timeout)
        _ = try host.apply(.clientReadyValidated, at: 20)
        XCTAssertEqual(host.progressDeadlineNanoseconds, 20 + timeout)
        _ = try host.apply(.ownerBudgetReservedAdmissionSlotTransferredCredentialPromotedAndRequestZeroEnqueued,
                           at: 30)
        XCTAssertEqual(host.state, .authenticated)
        XCTAssertFalse(try host.isExpired(at: UInt64.max))
        XCTAssertFalse(try host.expireIfNeeded(at: UInt64.max))

        var client = LANV6ClientHandshakeMachine(nowNanoseconds: 0)
        _ = try client.apply(.transportConnectedAndHelloSent, at: 10)
        XCTAssertEqual(client.progressDeadlineNanoseconds, 10 + timeout)
        _ = try client.apply(.serverAcceptCredentialPersisted, at: 20)
        XCTAssertEqual(client.progressDeadlineNanoseconds, 20 + timeout)
        _ = try client.apply(.initialOwnerBundleCheckpointed, at: 30)
        XCTAssertEqual(client.state, .connected)
        XCTAssertFalse(try client.isExpired(at: UInt64.max))
        XCTAssertFalse(try client.expireIfNeeded(at: UInt64.max))
    }

    func testClientReadyPolicyOpensOnlyAfterCredentialPersistenceTransition() throws {
        var client = LANV6ClientHandshakeMachine(nowNanoseconds: 0)
        _ = try client.apply(.transportConnectedAndHelloSent, at: 1)
        XCTAssertEqual(client.connectionPhase, .awaitingServerAccept)
        XCTAssertFalse(LANV6FrameAdmissionPolicy.handshakeV6(
            localRole: .client, phase: client.connectionPhase
        ).admits(localRole: .client, phase: client.connectionPhase,
                 flow: .outbound, kind: .clientReady))

        let action = try client.apply(.serverAcceptCredentialPersisted, at: 2)
        XCTAssertEqual(action, .sendClientReadyAndAwaitInitialOwner)
        XCTAssertEqual(client.connectionPhase, .awaitingInitialOwner)
        XCTAssertTrue(LANV6FrameAdmissionPolicy.handshakeV6(
            localRole: .client, phase: client.connectionPhase
        ).admits(localRole: .client, phase: client.connectionPhase,
                 flow: .outbound, kind: .clientReady))
    }

    private func hostMachine(
        in target: LANV6HostHandshakeState
    ) throws -> LANV6HostHandshakeMachine {
        var machine = LANV6HostHandshakeMachine(nowNanoseconds: 0)
        switch target {
        case .awaitingHello:
            break
        case .awaitingClientReady:
            _ = try machine.apply(.admissionPersisted(.joinNew), at: 1)
        case .readyAwaitingOwnerBudget:
            _ = try machine.apply(.admissionPersisted(.joinNew), at: 1)
            _ = try machine.apply(.clientReadyValidated, at: 2)
        case .authenticated:
            _ = try machine.apply(.admissionPersisted(.joinNew), at: 1)
            _ = try machine.apply(.clientReadyValidated, at: 2)
            _ = try machine.apply(
                .ownerBudgetReservedAdmissionSlotTransferredCredentialPromotedAndRequestZeroEnqueued, at: 3
            )
        case .closing:
            _ = try machine.apply(.close, at: 1)
        }
        return machine
    }

    private func clientMachine(
        in target: LANV6ClientHandshakeState
    ) throws -> LANV6ClientHandshakeMachine {
        var machine = LANV6ClientHandshakeMachine(nowNanoseconds: 0)
        switch target {
        case .connecting:
            break
        case .awaitingServerAccept:
            _ = try machine.apply(.transportConnectedAndHelloSent, at: 1)
        case .awaitingInitialOwner:
            _ = try machine.apply(.transportConnectedAndHelloSent, at: 1)
            _ = try machine.apply(.serverAcceptCredentialPersisted, at: 2)
        case .connected:
            _ = try machine.apply(.transportConnectedAndHelloSent, at: 1)
            _ = try machine.apply(.serverAcceptCredentialPersisted, at: 2)
            _ = try machine.apply(.initialOwnerBundleCheckpointed, at: 3)
        case .rejected:
            _ = try machine.apply(.close, at: 1)
        }
        return machine
    }

    private func expectedHostTransition(
        state: LANV6HostHandshakeState,
        eventName: String
    ) -> (state: LANV6HostHandshakeState, action: LANV6HostHandshakeAction)? {
        switch (state, eventName) {
        case (.awaitingHello, "joinNew"),
             (.awaitingHello, "resume"),
             (.awaitingHello, "legacyConsume"):
            return (.awaitingClientReady, .sendServerAccept)
        case (.awaitingHello, "detachedLegacyClaim"):
            return (.closing, .closeAfterDetachedLegacyClaim)
        case (.awaitingClientReady, "clientReady"):
            return (.readyAwaitingOwnerBudget,
                    .reserveOwnerBudgetTransferAdmissionSlotPromoteCredentialAndEnqueueRequestZero)
        case (.readyAwaitingOwnerBudget, "ownerReady"):
            return (.authenticated, .beginAuthenticatedTraffic)
        case (.awaitingHello, "close"),
             (.awaitingClientReady, "close"),
             (.readyAwaitingOwnerBudget, "close"),
             (.authenticated, "close"):
            return (.closing, .close)
        case (.closing, "close"):
            return (.closing, .none)
        default:
            return nil
        }
    }

    private func expectedClientTransition(
        state: LANV6ClientHandshakeState,
        eventName: String
    ) -> (state: LANV6ClientHandshakeState, action: LANV6ClientHandshakeAction)? {
        switch (state, eventName) {
        case (.connecting, "transportConnected"):
            return (.awaitingServerAccept, .awaitServerDecision)
        case (.awaitingServerAccept, "serverAccept"):
            return (.awaitingInitialOwner, .sendClientReadyAndAwaitInitialOwner)
        case (.awaitingServerAccept, "serverReject"):
            return (.rejected, .rejected)
        case (.awaitingInitialOwner, "serverReject"):
            return (.rejected, .rejected)
        case (.awaitingInitialOwner, "initialOwner"):
            return (.connected, .beginConnectedTraffic)
        case (.connecting, "close"),
             (.awaitingServerAccept, "close"),
             (.awaitingInitialOwner, "close"),
             (.connected, "close"):
            return (.rejected, .rejected)
        case (.rejected, "close"):
            return (.rejected, .none)
        default:
            return nil
        }
    }
}
