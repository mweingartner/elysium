import Dispatch
import Foundation
import XCTest
@testable import ElysiumCore

final class LANV6AdmissionCapacityTests: XCTestCase {
    func testHandshakeAuthenticatedAndTotalSocketCapsAreIndependentAndExact() throws {
        var handshakeOnly = LANV6AdmissionLedger()
        for value in 1...LAN_V6_MAX_HANDSHAKE_SOCKETS {
            try handshakeOnly.acceptSocket(try socket(value))
        }
        XCTAssertEqual(handshakeOnly.handshakeSocketCount, 8)
        let handshakeBefore = handshakeOnly
        XCTAssertThrowsError(try handshakeOnly.acceptSocket(try socket(9))) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .handshakeCapacity)
        }
        XCTAssertEqual(handshakeOnly, handshakeBefore)

        var mixed = LANV6AdmissionLedger()
        for value in 1...LAN_V6_MAX_AUTHENTICATED_AUTHORITIES {
            let socketID = try socket(value)
            try mixed.acceptSocket(socketID)
            XCTAssertEqual(try mixed.promote(socketID: socketID,
                                             authority: try authority(value),
                                             identityClass: .existing), .promoted)
        }
        XCTAssertEqual(mixed.authenticatedAuthorityCount, 8)
        XCTAssertEqual(mixed.handshakeSocketCount, 0)

        let blockedPromotion = try socket(9)
        try mixed.acceptSocket(blockedPromotion)
        let beforePromotion = mixed
        XCTAssertThrowsError(try mixed.promote(socketID: blockedPromotion,
                                               authority: try authority(9),
                                               identityClass: .existing)) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .authenticatedCapacity)
        }
        XCTAssertEqual(mixed, beforePromotion)

        for value in 10...16 {
            try mixed.acceptSocket(try socket(value))
        }
        XCTAssertEqual(mixed.totalSocketCount, 16)
        XCTAssertEqual(mixed.handshakeSocketCount, 8)
        XCTAssertEqual(mixed.authenticatedAuthorityCount, 8)
        let fullBefore = mixed
        XCTAssertThrowsError(try mixed.acceptSocket(try socket(17))) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .totalSocketCapacity)
        }
        XCTAssertEqual(mixed, fullBefore)
        XCTAssertTrue(mixed.validateInvariants())
    }

    func testPendingOnlyCapDuplicateAndAuthorityDomainAreExact() throws {
        var ledger = LANV6AdmissionLedger()
        for value in 1...LAN_V6_MAX_PENDING_ONLY_IDENTITIES {
            try ledger.reservePendingOnlyIdentity(try authority(value))
        }
        XCTAssertEqual(ledger.pendingOnlyIdentityCount, 8)

        let fullBefore = ledger
        XCTAssertThrowsError(try ledger.reservePendingOnlyIdentity(try authority(9))) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .pendingOnlyCapacity)
        }
        XCTAssertEqual(ledger, fullBefore)
        XCTAssertThrowsError(try ledger.reservePendingOnlyIdentity(try authority(1))) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .duplicatePendingIdentity)
        }
        XCTAssertEqual(ledger, fullBefore)
        XCTAssertThrowsError(try ledger.reservePendingOnlyIdentity(.hostLocal)) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .invalidRemoteAuthority)
        }
        XCTAssertEqual(ledger, fullBefore)

        XCTAssertTrue(try ledger.releasePendingOnlyIdentity(try authority(1)))
        XCTAssertFalse(try ledger.releasePendingOnlyIdentity(try authority(1)))
        XCTAssertEqual(ledger.pendingOnlyIdentityCount, 7)
        try ledger.reservePendingOnlyIdentity(try authority(9))
        XCTAssertEqual(ledger.pendingOnlyIdentityCount, 8)
        XCTAssertTrue(ledger.validateInvariants())
    }

    func testPromotionConsumesMatchingPendingAndSameAuthoritySupersessionReusesSlot() throws {
        var ledger = LANV6AdmissionLedger()
        for value in 1...8 {
            let socketID = try socket(value)
            try ledger.acceptSocket(socketID)
            try ledger.reservePendingOnlyIdentity(try authority(value))
            XCTAssertEqual(try ledger.promote(socketID: socketID,
                                              authority: try authority(value),
                                              identityClass: .pendingOnlyNew), .promoted)
        }
        XCTAssertEqual(ledger.authenticatedAuthorityCount, 8)
        XCTAssertEqual(ledger.pendingOnlyIdentityCount, 0)

        let replacement = try socket(9)
        let replacedAuthority = try authority(1)
        try ledger.acceptSocket(replacement)
        let promotion = try ledger.promote(socketID: replacement,
                                           authority: replacedAuthority,
                                           identityClass: .existing)
        XCTAssertEqual(promotion, .superseded(try socket(1)))
        XCTAssertEqual(ledger.authenticatedAuthorityCount, 8)
        XCTAssertEqual(ledger.handshakeSocketCount, 0)
        XCTAssertEqual(ledger.totalSocketCount, 9)
        XCTAssertEqual(ledger.sockets[try socket(1)], .closing)
        XCTAssertEqual(ledger.sockets[replacement], .authenticated(replacedAuthority))
        XCTAssertEqual(ledger.authenticatedSocketsByAuthority[replacedAuthority], replacement)
        XCTAssertTrue(ledger.validateInvariants())

        XCTAssertFalse(try ledger.beginClosing(try socket(1)),
                       "supersession already began the old socket close exactly once")
        try ledger.completeClose(try socket(1))
        XCTAssertEqual(ledger.totalSocketCount, 8)
        XCTAssertThrowsError(try ledger.completeClose(try socket(1))) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .unknownSocket)
        }
        XCTAssertEqual(ledger.totalSocketCount, 8)
    }

    func testPromotionIdentityClassCannotBypassPendingOnlyReservation() throws {
        var ledger = LANV6AdmissionLedger()
        let socketID = try socket(1)
        let peer = try authority(1)
        try ledger.acceptSocket(socketID)

        let missingBefore = ledger
        XCTAssertThrowsError(try ledger.promote(
            socketID: socketID, authority: peer, identityClass: .pendingOnlyNew
        )) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .missingPendingOnlyReservation)
        }
        XCTAssertEqual(ledger, missingBefore)

        try ledger.reservePendingOnlyIdentity(peer)
        let unexpectedBefore = ledger
        XCTAssertThrowsError(try ledger.promote(
            socketID: socketID, authority: peer, identityClass: .existing
        )) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .unexpectedPendingOnlyReservation)
        }
        XCTAssertEqual(ledger, unexpectedBefore)

        XCTAssertEqual(try ledger.promote(
            socketID: socketID, authority: peer, identityClass: .pendingOnlyNew
        ), .promoted)
        XCTAssertEqual(ledger.pendingOnlyIdentityCount, 0)
        XCTAssertEqual(ledger.authenticatedAuthorityCount, 1)
        XCTAssertTrue(ledger.validateInvariants())
    }

    func testCloseLifecycleReleasesPhaseCapacityOnceAndTotalOnlyOnCompletion() throws {
        var ledger = LANV6AdmissionLedger()
        let socketID = try socket(1)
        try ledger.acceptSocket(socketID)
        XCTAssertThrowsError(try ledger.completeClose(socketID)) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .socketNotClosing)
        }
        XCTAssertEqual(ledger.totalSocketCount, 1)
        XCTAssertEqual(ledger.handshakeSocketCount, 1)

        XCTAssertTrue(try ledger.beginClosing(socketID))
        XCTAssertEqual(ledger.totalSocketCount, 1)
        XCTAssertEqual(ledger.handshakeSocketCount, 0)
        XCTAssertFalse(try ledger.beginClosing(socketID))
        try ledger.completeClose(socketID)
        XCTAssertEqual(ledger.totalSocketCount, 0)
        XCTAssertThrowsError(try ledger.beginClosing(socketID)) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .unknownSocket)
        }
        XCTAssertThrowsError(try ledger.completeClose(socketID)) { error in
            XCTAssertEqual(error as? LANV6AdmissionError, .unknownSocket)
        }
        XCTAssertTrue(ledger.validateInvariants())
    }

    func testConcurrentAcceptRaceNeverCreatesNinthHandshake() throws {
        let gate = LANV6AdmissionGate()
        let sockets = try (1...64).map(socket)
        let results = LockedResults<Result<LANV6SocketID, LANV6AdmissionError>>()

        DispatchQueue.concurrentPerform(iterations: sockets.count) { offset in
            let socketID = sockets[offset]
            do {
                try gate.acceptSocket(socketID)
                results.append(.success(socketID))
            } catch let error as LANV6AdmissionError {
                results.append(.failure(error))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        let captured = results.snapshot()
        XCTAssertEqual(captured.filter { if case .success = $0 { true } else { false } }.count, 8)
        XCTAssertEqual(captured.filter {
            if case .failure(.handshakeCapacity) = $0 { true } else { false }
        }.count, 56)
        let snapshot = gate.snapshot()
        XCTAssertEqual(snapshot.totalSocketCount, 8)
        XCTAssertEqual(snapshot.handshakeSocketCount, 8)
        XCTAssertTrue(snapshot.validateInvariants())
    }

    func testConcurrentSameAuthorityPromotionsAtomicallyTransferOneSlot() throws {
        let gate = LANV6AdmissionGate()
        let sockets = try (1...8).map(socket)
        for socketID in sockets { try gate.acceptSocket(socketID) }
        let sharedAuthority = try authority(1)
        let results = LockedResults<Result<LANV6AdmissionPromotion, LANV6AdmissionError>>()

        DispatchQueue.concurrentPerform(iterations: sockets.count) { offset in
            do {
                results.append(.success(try gate.promote(socketID: sockets[offset],
                                                        authority: sharedAuthority,
                                                        identityClass: .existing)))
            } catch let error as LANV6AdmissionError {
                results.append(.failure(error))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
        }

        let captured = results.snapshot()
        XCTAssertEqual(captured.count, 8)
        XCTAssertEqual(captured.filter { if case .success(.promoted) = $0 { true } else { false } }
            .count, 1)
        XCTAssertEqual(captured.filter {
            if case .success(.superseded) = $0 { true } else { false }
        }.count, 7)
        XCTAssertEqual(captured.filter { if case .failure = $0 { true } else { false } }.count, 0)

        let snapshot = gate.snapshot()
        XCTAssertEqual(snapshot.totalSocketCount, 8)
        XCTAssertEqual(snapshot.handshakeSocketCount, 0)
        XCTAssertEqual(snapshot.authenticatedAuthorityCount, 1)
        XCTAssertEqual(snapshot.sockets.values.filter {
            if case .closing = $0 { true } else { false }
        }.count, 7)
        XCTAssertTrue(snapshot.validateInvariants())
    }

    func testSeededTenThousandOperationLedgerPropertiesAndFailureAtomicity() throws {
        var ledger = LANV6AdmissionLedger()
        var rng = LCG(seed: 0x7a11_cafe_f00d_beef)

        for iteration in 0..<10_000 {
            let before = ledger
            let socketID = try socket(Int(rng.next() % 24) + 1)
            let authority = try authority(Int(rng.next() % 12) + 1)
            do {
                switch rng.next() % 6 {
                case 0: try ledger.acceptSocket(socketID)
                case 1: try ledger.reservePendingOnlyIdentity(authority)
                case 2: _ = try ledger.releasePendingOnlyIdentity(authority)
                case 3:
                    _ = try ledger.promote(
                        socketID: socketID,
                        authority: authority,
                        identityClass: rng.next().isMultiple(of: 2) ? .existing : .pendingOnlyNew
                    )
                case 4: _ = try ledger.beginClosing(socketID)
                default: try ledger.completeClose(socketID)
                }
            } catch is LANV6AdmissionError {
                XCTAssertEqual(ledger, before, "failed operation mutated ledger at \(iteration)")
            }
            XCTAssertTrue(ledger.validateInvariants(), "iteration \(iteration)")
            XCTAssertLessThanOrEqual(ledger.totalSocketCount, 16)
            XCTAssertLessThanOrEqual(ledger.handshakeSocketCount, 8)
            XCTAssertLessThanOrEqual(ledger.authenticatedAuthorityCount, 8)
            XCTAssertLessThanOrEqual(ledger.pendingOnlyIdentityCount, 8)
        }
    }

    private func socket(_ value: Int) throws -> LANV6SocketID {
        try LANV6SocketID(UInt64(value))
    }

    private func authority(_ value: Int) throws -> LANV6Authority {
        try LANV6Authority("lan:\(value)")
    }
}

private final class LockedResults<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Value] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private struct LCG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
