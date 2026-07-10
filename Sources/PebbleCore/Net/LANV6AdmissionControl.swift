import Darwin
import Foundation

public let LAN_V6_MAX_OPEN_OR_CLOSING_SOCKETS = 16
public let LAN_V6_MAX_HANDSHAKE_SOCKETS = 8
public let LAN_V6_MAX_AUTHENTICATED_AUTHORITIES = 8
public let LAN_V6_MAX_PENDING_ONLY_IDENTITIES = 8
public let LAN_V6_MAX_SOURCE_BUCKETS = 256
public let LAN_V6_SOURCE_BUCKET_IDLE_NANOSECONDS: UInt64 = 600_000_000_000

public struct LANV6SocketID: Hashable, Comparable, Sendable {
    public let value: UInt64

    public init(_ value: UInt64) throws {
        guard value > 0 else { throw LANV6AdmissionError.invalidSocketID }
        self.value = value
    }

    public static func < (lhs: LANV6SocketID, rhs: LANV6SocketID) -> Bool {
        lhs.value < rhs.value
    }
}

public enum LANV6AdmissionError: Error, Equatable {
    case invalidSocketID
    case invalidRemoteAuthority
    case duplicateSocket
    case unknownSocket
    case socketNotHandshaking
    case socketNotClosing
    case totalSocketCapacity
    case handshakeCapacity
    case authenticatedCapacity
    case pendingOnlyCapacity
    case duplicatePendingIdentity
    case missingPendingOnlyReservation
    case unexpectedPendingOnlyReservation
    case invariantViolation
}

public enum LANV6AdmissionSocketState: Equatable {
    case handshaking
    case authenticated(LANV6Authority)
    /// Closing sockets continue to consume the total-socket reservation until
    /// their close completion callback arrives, but own no handshake or
    /// authenticated-authority reservation.
    case closing
}

public enum LANV6AdmissionPromotion: Equatable {
    case promoted
    case superseded(LANV6SocketID)
}

public enum LANV6AdmissionIdentityClass: Equatable {
    /// Resume or rotation of an already durable identity. It consumes no
    /// pending-only-new-identity reservation.
    case existing
    /// A join-new or legacy-consume identity whose pending-only reservation
    /// must already exist and is consumed by successful promotion.
    case pendingOnlyNew
}

/// Pure state behind the one global admission lock. Every public mutation is
/// all-or-nothing, and the derived counts make split check-then-increment paths
/// impossible.
public struct LANV6AdmissionLedger: Equatable {
    public private(set) var sockets: [LANV6SocketID: LANV6AdmissionSocketState] = [:]
    public private(set) var authenticatedSocketsByAuthority: [LANV6Authority: LANV6SocketID] = [:]
    public private(set) var pendingOnlyAuthorities: Set<LANV6Authority> = []

    init() {}

    public var totalSocketCount: Int { sockets.count }

    public var handshakeSocketCount: Int {
        sockets.values.reduce(into: 0) { count, state in
            if case .handshaking = state { count += 1 }
        }
    }

    public var authenticatedAuthorityCount: Int {
        authenticatedSocketsByAuthority.count
    }

    public var pendingOnlyIdentityCount: Int { pendingOnlyAuthorities.count }

    mutating func acceptSocket(_ socketID: LANV6SocketID) throws {
        guard sockets[socketID] == nil else { throw LANV6AdmissionError.duplicateSocket }
        guard totalSocketCount < LAN_V6_MAX_OPEN_OR_CLOSING_SOCKETS else {
            throw LANV6AdmissionError.totalSocketCapacity
        }
        guard handshakeSocketCount < LAN_V6_MAX_HANDSHAKE_SOCKETS else {
            throw LANV6AdmissionError.handshakeCapacity
        }
        sockets[socketID] = .handshaking
        try requireValidInvariants()
    }

    /// Reserves a persisted pending-only identity before its transaction
    /// commits. Callers release it on rollback/expiry, or promotion consumes it.
    mutating func reservePendingOnlyIdentity(_ authority: LANV6Authority) throws {
        guard authority != .hostLocal,
              authenticatedSocketsByAuthority[authority] == nil
        else { throw LANV6AdmissionError.invalidRemoteAuthority }
        guard !pendingOnlyAuthorities.contains(authority) else {
            throw LANV6AdmissionError.duplicatePendingIdentity
        }
        guard pendingOnlyIdentityCount < LAN_V6_MAX_PENDING_ONLY_IDENTITIES else {
            throw LANV6AdmissionError.pendingOnlyCapacity
        }
        pendingOnlyAuthorities.insert(authority)
        try requireValidInvariants()
    }

    @discardableResult
    mutating func releasePendingOnlyIdentity(_ authority: LANV6Authority) throws -> Bool {
        let removed = pendingOnlyAuthorities.remove(authority) != nil
        try requireValidInvariants()
        return removed
    }

    /// Atomically transfers this socket's handshake reservation to an
    /// authority slot. When the same authority is already authenticated, the
    /// slot is transferred directly and the old socket becomes closing; no
    /// transient ninth authority exists.
    @discardableResult
    mutating func promote(
        socketID: LANV6SocketID,
        authority: LANV6Authority,
        identityClass: LANV6AdmissionIdentityClass
    ) throws -> LANV6AdmissionPromotion {
        guard authority != .hostLocal else {
            throw LANV6AdmissionError.invalidRemoteAuthority
        }
        guard sockets[socketID] != nil else { throw LANV6AdmissionError.unknownSocket }
        guard sockets[socketID] == .handshaking else {
            throw LANV6AdmissionError.socketNotHandshaking
        }
        switch identityClass {
        case .existing:
            guard !pendingOnlyAuthorities.contains(authority) else {
                throw LANV6AdmissionError.unexpectedPendingOnlyReservation
            }
        case .pendingOnlyNew:
            guard pendingOnlyAuthorities.contains(authority) else {
                throw LANV6AdmissionError.missingPendingOnlyReservation
            }
        }

        if let oldSocketID = authenticatedSocketsByAuthority[authority] {
            guard oldSocketID != socketID,
                  sockets[oldSocketID] == .authenticated(authority)
            else {
                throw LANV6AdmissionError.invariantViolation
            }
            sockets[oldSocketID] = .closing
            sockets[socketID] = .authenticated(authority)
            authenticatedSocketsByAuthority[authority] = socketID
            pendingOnlyAuthorities.remove(authority)
            try requireValidInvariants()
            return .superseded(oldSocketID)
        }

        guard authenticatedAuthorityCount < LAN_V6_MAX_AUTHENTICATED_AUTHORITIES else {
            throw LANV6AdmissionError.authenticatedCapacity
        }
        sockets[socketID] = .authenticated(authority)
        authenticatedSocketsByAuthority[authority] = socketID
        pendingOnlyAuthorities.remove(authority)
        try requireValidInvariants()
        return .promoted
    }

    /// Releases phase-specific capacity once and starts asynchronous close.
    /// Total-socket capacity remains reserved until `completeClose` succeeds.
    @discardableResult
    mutating func beginClosing(_ socketID: LANV6SocketID) throws -> Bool {
        guard let state = sockets[socketID] else { throw LANV6AdmissionError.unknownSocket }
        if case .closing = state { return false }
        if case .authenticated(let authority) = state {
            guard authenticatedSocketsByAuthority[authority] == socketID else {
                throw LANV6AdmissionError.invariantViolation
            }
            authenticatedSocketsByAuthority.removeValue(forKey: authority)
        }
        sockets[socketID] = .closing
        try requireValidInvariants()
        return true
    }

    /// The close-completion callback is the only operation that releases the
    /// total-socket reservation. A duplicate callback is rejected instead of
    /// decrementing a counter twice.
    mutating func completeClose(_ socketID: LANV6SocketID) throws {
        guard let state = sockets[socketID] else { throw LANV6AdmissionError.unknownSocket }
        guard state == .closing else { throw LANV6AdmissionError.socketNotClosing }
        sockets.removeValue(forKey: socketID)
        try requireValidInvariants()
    }

    func validateInvariants() -> Bool {
        guard totalSocketCount <= LAN_V6_MAX_OPEN_OR_CLOSING_SOCKETS,
              handshakeSocketCount <= LAN_V6_MAX_HANDSHAKE_SOCKETS,
              authenticatedAuthorityCount <= LAN_V6_MAX_AUTHENTICATED_AUTHORITIES,
              pendingOnlyIdentityCount <= LAN_V6_MAX_PENDING_ONLY_IDENTITIES
        else { return false }

        var socketAuthorities = [LANV6Authority: LANV6SocketID]()
        for (socketID, state) in sockets {
            if case .authenticated(let authority) = state {
                guard socketAuthorities.updateValue(socketID, forKey: authority) == nil else {
                    return false
                }
            }
        }
        return socketAuthorities == authenticatedSocketsByAuthority
    }

    private func requireValidInvariants() throws {
        guard validateInvariants() else { throw LANV6AdmissionError.invariantViolation }
    }
}

/// Lock-owning facade used by transport code. The pure ledger remains directly
/// testable, while this facade ensures each compound capacity transition is one
/// critical section.
public final class LANV6AdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ledger = LANV6AdmissionLedger()

    public init() {}

    public func snapshot() -> LANV6AdmissionLedger {
        lock.lock()
        defer { lock.unlock() }
        return ledger
    }

    public func acceptSocket(_ socketID: LANV6SocketID) throws {
        try transact { try $0.acceptSocket(socketID) }
    }

    public func reservePendingOnlyIdentity(_ authority: LANV6Authority) throws {
        try transact { try $0.reservePendingOnlyIdentity(authority) }
    }

    @discardableResult
    public func releasePendingOnlyIdentity(_ authority: LANV6Authority) throws -> Bool {
        try transact { try $0.releasePendingOnlyIdentity(authority) }
    }

    /// Module-internal foundation only. Production transport must use the
    /// Phase-2 promotion coordinator, which keeps this candidate transition
    /// unpublished while holding admission -> authority -> SaveDB order and
    /// commits it only after bundle/send/checkpoint reservation and credential
    /// CAS succeed. Exposing this directly would make CAS rollback impossible.
    @discardableResult
    func promote(
        socketID: LANV6SocketID,
        authority: LANV6Authority,
        identityClass: LANV6AdmissionIdentityClass
    ) throws -> LANV6AdmissionPromotion {
        try transact {
            try $0.promote(
                socketID: socketID,
                authority: authority,
                identityClass: identityClass
            )
        }
    }

    @discardableResult
    public func beginClosing(_ socketID: LANV6SocketID) throws -> Bool {
        try transact { try $0.beginClosing(socketID) }
    }

    public func completeClose(_ socketID: LANV6SocketID) throws {
        try transact { try $0.completeClose(socketID) }
    }

    private func transact<T>(
        _ operation: (inout LANV6AdmissionLedger) throws -> T
    ) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        var candidate = ledger
        let result = try operation(&candidate)
        guard candidate.validateInvariants() else {
            throw LANV6AdmissionError.invariantViolation
        }
        ledger = candidate
        return result
    }
}

public enum LANV6SourceAddressError: Error, Equatable {
    case invalidIPv4
    case invalidIPv6
    case invalidText
}

/// A bounded, canonical rate-limit key. IPv4 retains all 32 bits; IPv6 retains
/// its first 64 bits and deliberately discards the interface identifier.
public struct LANV6NormalizedSource: Hashable, Comparable, Sendable {
    public enum Family: UInt8, Sendable {
        case ipv4 = 4
        case ipv6Prefix64 = 6
    }

    public let family: Family
    private let keyBytes: [UInt8]

    public init(ipv4Bytes: [UInt8]) throws {
        guard ipv4Bytes.count == 4 else { throw LANV6SourceAddressError.invalidIPv4 }
        family = .ipv4
        keyBytes = ipv4Bytes
    }

    public init(ipv6Bytes: [UInt8]) throws {
        guard ipv6Bytes.count == 16 else { throw LANV6SourceAddressError.invalidIPv6 }
        let mappedIPv4Prefix = ipv6Bytes.prefix(10).allSatisfy { $0 == 0 } &&
            ipv6Bytes[10] == 0xff && ipv6Bytes[11] == 0xff
        if mappedIPv4Prefix {
            family = .ipv4
            keyBytes = Array(ipv6Bytes.suffix(4))
            return
        }
        family = .ipv6Prefix64
        keyBytes = Array(ipv6Bytes.prefix(8))
    }

    public init(ipAddress: String) throws {
        guard !ipAddress.isEmpty,
              ipAddress.utf8.count <= Int(INET6_ADDRSTRLEN),
              !ipAddress.contains("%"),
              !ipAddress.contains("[") && !ipAddress.contains("]")
        else { throw LANV6SourceAddressError.invalidText }

        var ipv4 = in_addr()
        if inet_pton(AF_INET, ipAddress, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
            try self.init(ipv4Bytes: bytes)
            return
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, ipAddress, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            try self.init(ipv6Bytes: bytes)
            return
        }
        throw LANV6SourceAddressError.invalidText
    }

    public static func < (lhs: LANV6NormalizedSource, rhs: LANV6NormalizedSource) -> Bool {
        if lhs.family.rawValue != rhs.family.rawValue {
            return lhs.family.rawValue < rhs.family.rawValue
        }
        return lhs.keyBytes.lexicographicallyPrecedes(rhs.keyBytes)
    }
}

private struct LANV6ExactTokenBucket: Equatable {
    let capacity: UInt64
    let nanosecondsPerToken: UInt64
    var availableCredit: UInt64
    var lastRefillNanoseconds: UInt64

    init(capacity: UInt64, nanosecondsPerToken: UInt64, nowNanoseconds: UInt64) {
        self.capacity = capacity
        self.nanosecondsPerToken = nanosecondsPerToken
        availableCredit = capacity * nanosecondsPerToken
        lastRefillNanoseconds = nowNanoseconds
    }

    mutating func consume(at nowNanoseconds: UInt64) -> Bool {
        precondition(nowNanoseconds >= lastRefillNanoseconds)
        let elapsed = nowNanoseconds - lastRefillNanoseconds
        lastRefillNanoseconds = nowNanoseconds
        let capacityCredit = capacity * nanosecondsPerToken
        if availableCredit < capacityCredit {
            let headroom = capacityCredit - availableCredit
            availableCredit += min(elapsed, headroom)
        }
        guard availableCredit >= nanosecondsPerToken else { return false }
        availableCredit -= nanosecondsPerToken
        return true
    }
}

public enum LANV6HelloRateLimitDenial: Equatable {
    case global
    case source
    case globalAndSource
    case monotonicClockRegressed
}

public struct LANV6HelloRateLimitDecision: Equatable {
    public let allowed: Bool
    public let denial: LANV6HelloRateLimitDenial?
    public let usedOverflowBucket: Bool

    private init(allowed: Bool, denial: LANV6HelloRateLimitDenial?, usedOverflowBucket: Bool) {
        self.allowed = allowed
        self.denial = denial
        self.usedOverflowBucket = usedOverflowBucket
    }

    fileprivate static func allowed(usedOverflowBucket: Bool) -> LANV6HelloRateLimitDecision {
        LANV6HelloRateLimitDecision(
            allowed: true, denial: nil, usedOverflowBucket: usedOverflowBucket
        )
    }

    fileprivate static func denied(
        _ denial: LANV6HelloRateLimitDenial,
        usedOverflowBucket: Bool
    ) -> LANV6HelloRateLimitDecision {
        LANV6HelloRateLimitDecision(
            allowed: false, denial: denial, usedOverflowBucket: usedOverflowBucket
        )
    }
}

private struct LANV6SourceBucketEntry: Equatable {
    var bucket: LANV6ExactTokenBucket
    var lastSeenNanoseconds: UInt64
    var accessOrdinal: UInt64
}

/// Exact monotonic token buckets for every fully framed hello. Both the global
/// and selected source bucket independently consume an available token even if
/// the other bucket denies the attempt.
public struct LANV6HelloRateLimiter: Equatable {
    private var globalBucket: LANV6ExactTokenBucket
    private var sourceBuckets: [LANV6NormalizedSource: LANV6SourceBucketEntry] = [:]
    private var overflowBucket: LANV6ExactTokenBucket
    private var lastObservedNanoseconds: UInt64
    private var nextAccessOrdinal: UInt64 = 1

    init(nowNanoseconds: UInt64) {
        globalBucket = LANV6ExactTokenBucket(
            capacity: 32, nanosecondsPerToken: 250_000_000,
            nowNanoseconds: nowNanoseconds
        )
        overflowBucket = LANV6ExactTokenBucket(
            capacity: 4, nanosecondsPerToken: 5_000_000_000,
            nowNanoseconds: nowNanoseconds
        )
        lastObservedNanoseconds = nowNanoseconds
    }

    public var trackedSourceCount: Int { sourceBuckets.count }

    @discardableResult
    mutating func consume(
        source: LANV6NormalizedSource,
        nowNanoseconds: UInt64
    ) -> LANV6HelloRateLimitDecision {
        guard nowNanoseconds >= lastObservedNanoseconds else {
            return .denied(.monotonicClockRegressed, usedOverflowBucket: false)
        }
        lastObservedNanoseconds = nowNanoseconds

        let globalAllowed = globalBucket.consume(at: nowNanoseconds)
        let usesOverflow = sourceEntryKey(for: source, nowNanoseconds: nowNanoseconds) == nil
        let sourceAllowed: Bool
        if usesOverflow {
            sourceAllowed = overflowBucket.consume(at: nowNanoseconds)
        } else {
            var entry = sourceBuckets[source]!
            entry.lastSeenNanoseconds = nowNanoseconds
            entry.accessOrdinal = takeAccessOrdinal()
            sourceAllowed = entry.bucket.consume(at: nowNanoseconds)
            sourceBuckets[source] = entry
        }

        switch (globalAllowed, sourceAllowed) {
        case (true, true): return .allowed(usedOverflowBucket: usesOverflow)
        case (false, true): return .denied(.global, usedOverflowBucket: usesOverflow)
        case (true, false): return .denied(.source, usedOverflowBucket: usesOverflow)
        case (false, false): return .denied(.globalAndSource, usedOverflowBucket: usesOverflow)
        }
    }

    /// Returns the concrete source key, creating/evicting one as needed. `nil`
    /// selects the shared overflow bucket when all 256 entries are non-idle.
    private mutating func sourceEntryKey(
        for source: LANV6NormalizedSource,
        nowNanoseconds: UInt64
    ) -> LANV6NormalizedSource? {
        if sourceBuckets[source] != nil { return source }

        if sourceBuckets.count >= LAN_V6_MAX_SOURCE_BUCKETS {
            let idleCandidates = sourceBuckets.filter { _, entry in
                nowNanoseconds >= entry.lastSeenNanoseconds &&
                    nowNanoseconds - entry.lastSeenNanoseconds >=
                        LAN_V6_SOURCE_BUCKET_IDLE_NANOSECONDS
            }
            if let eviction = idleCandidates.min(by: { lhs, rhs in
                if lhs.value.lastSeenNanoseconds != rhs.value.lastSeenNanoseconds {
                    return lhs.value.lastSeenNanoseconds < rhs.value.lastSeenNanoseconds
                }
                if lhs.value.accessOrdinal != rhs.value.accessOrdinal {
                    return lhs.value.accessOrdinal < rhs.value.accessOrdinal
                }
                return lhs.key < rhs.key
            }) {
                sourceBuckets.removeValue(forKey: eviction.key)
            } else {
                return nil
            }
        }

        sourceBuckets[source] = LANV6SourceBucketEntry(
            bucket: LANV6ExactTokenBucket(
                capacity: 4, nanosecondsPerToken: 5_000_000_000,
                nowNanoseconds: nowNanoseconds
            ),
            lastSeenNanoseconds: nowNanoseconds,
            accessOrdinal: takeAccessOrdinal()
        )
        return source
    }

    private mutating func takeAccessOrdinal() -> UInt64 {
        if nextAccessOrdinal == UInt64.max { rebaseAccessOrdinals() }
        let result = nextAccessOrdinal
        nextAccessOrdinal += 1
        return result
    }

    private mutating func rebaseAccessOrdinals() {
        let ordered = sourceBuckets.sorted { lhs, rhs in
            if lhs.value.lastSeenNanoseconds != rhs.value.lastSeenNanoseconds {
                return lhs.value.lastSeenNanoseconds < rhs.value.lastSeenNanoseconds
            }
            if lhs.value.accessOrdinal != rhs.value.accessOrdinal {
                return lhs.value.accessOrdinal < rhs.value.accessOrdinal
            }
            return lhs.key < rhs.key
        }
        for (offset, pair) in ordered.enumerated() {
            var entry = pair.value
            entry.accessOrdinal = UInt64(offset + 1)
            sourceBuckets[pair.key] = entry
        }
        nextAccessOrdinal = UInt64(ordered.count + 1)
    }
}

public final class LANV6HelloRateLimitGate: @unchecked Sendable {
    private let lock = NSLock()
    private let clock: any LANV6MonotonicClock
    private var limiter: LANV6HelloRateLimiter

    public init(clock: any LANV6MonotonicClock = LANV6SystemMonotonicClock()) {
        self.clock = clock
        limiter = LANV6HelloRateLimiter(nowNanoseconds: clock.nowNanoseconds())
    }

    public func consume(source: LANV6NormalizedSource) -> LANV6HelloRateLimitDecision {
        lock.lock()
        defer { lock.unlock() }
        let nowNanoseconds = clock.nowNanoseconds()
        return limiter.consume(source: source, nowNanoseconds: nowNanoseconds)
    }

    public func snapshot() -> LANV6HelloRateLimiter {
        lock.lock()
        defer { lock.unlock() }
        return limiter
    }
}
