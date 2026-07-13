import Dispatch
import Foundation
import XCTest
@testable import ElysiumCore

final class LANV6HelloRateLimiterTests: XCTestCase {
    func testGlobalBucketRefillsContinuouslyAtExactFourPerSecondBoundary() throws {
        var limiter = LANV6HelloRateLimiter(nowNanoseconds: 0)
        for value in 0..<32 {
            XCTAssertTrue(limiter.consume(source: try source(value), nowNanoseconds: 0).allowed)
        }

        let deniedAtEmpty = limiter.consume(source: try source(100), nowNanoseconds: 0)
        XCTAssertEqual(deniedAtEmpty.denial, .global)
        let deniedOneNanosecondEarly = limiter.consume(
            source: try source(101), nowNanoseconds: 249_999_999
        )
        XCTAssertEqual(deniedOneNanosecondEarly.denial, .global)
        let admittedAtBoundary = limiter.consume(
            source: try source(102), nowNanoseconds: 250_000_000
        )
        XCTAssertTrue(admittedAtBoundary.allowed)
    }

    func testSourceBucketRefillsAtExactFiveSecondBoundaryAndCapsAtFour() throws {
        var limiter = LANV6HelloRateLimiter(nowNanoseconds: 0)
        let peer = try source(1)
        for _ in 0..<4 {
            XCTAssertTrue(limiter.consume(source: peer, nowNanoseconds: 0).allowed)
        }
        XCTAssertEqual(limiter.consume(source: peer, nowNanoseconds: 0).denial, .source)
        XCTAssertEqual(limiter.consume(source: peer,
                                       nowNanoseconds: 4_999_999_999).denial, .source)
        XCTAssertTrue(limiter.consume(source: peer,
                                      nowNanoseconds: 5_000_000_000).allowed)

        let longIdle = UInt64(100_000_000_000)
        for _ in 0..<4 {
            XCTAssertTrue(limiter.consume(source: peer, nowNanoseconds: longIdle).allowed)
        }
        XCTAssertEqual(limiter.consume(source: peer, nowNanoseconds: longIdle).denial, .source,
                       "idle refill must never exceed the four-token source capacity")
    }

    func testSourceDenialStillConsumesGlobalToken() throws {
        var limiter = LANV6HelloRateLimiter(nowNanoseconds: 0)
        let noisy = try source(0)
        for _ in 0..<4 {
            XCTAssertTrue(limiter.consume(source: noisy, nowNanoseconds: 0).allowed)
        }
        XCTAssertEqual(limiter.consume(source: noisy, nowNanoseconds: 0).denial, .source)

        for value in 1...27 {
            XCTAssertTrue(limiter.consume(source: try source(value),
                                          nowNanoseconds: 0).allowed)
        }
        XCTAssertEqual(limiter.consume(source: try source(28),
                                       nowNanoseconds: 0).denial, .global,
                       "the source-denied fifth hello must have consumed global token 5")
    }

    func testGlobalDenialStillConsumesSourceToken() throws {
        var limiter = LANV6HelloRateLimiter(nowNanoseconds: 0)
        for value in 0..<32 {
            XCTAssertTrue(limiter.consume(source: try source(value), nowNanoseconds: 0).allowed)
        }

        let target = try source(100)
        for _ in 0..<4 {
            XCTAssertEqual(limiter.consume(source: target, nowNanoseconds: 0).denial, .global)
        }
        XCTAssertEqual(limiter.consume(source: target,
                                       nowNanoseconds: 250_000_000).denial, .source,
                       "four globally denied hellos must still empty the source bucket")
    }

    func testIPv4UsesExactAddressAndIPv6UsesExactPrefix64() throws {
        XCTAssertEqual(try LANV6NormalizedSource(ipAddress: "192.0.2.1"),
                       try LANV6NormalizedSource(ipv4Bytes: [192, 0, 2, 1]))
        XCTAssertNotEqual(try LANV6NormalizedSource(ipAddress: "192.0.2.1"),
                          try LANV6NormalizedSource(ipAddress: "192.0.2.2"))

        let first = try LANV6NormalizedSource(ipAddress: "2001:db8:abcd:1234::1")
        let samePrefix = try LANV6NormalizedSource(
            ipAddress: "2001:0db8:abcd:1234:ffff:eeee:dddd:cccc"
        )
        let nextPrefix = try LANV6NormalizedSource(ipAddress: "2001:db8:abcd:1235::1")
        XCTAssertEqual(first, samePrefix)
        XCTAssertNotEqual(first, nextPrefix)
        XCTAssertEqual(first.family, .ipv6Prefix64)
        XCTAssertEqual(try LANV6NormalizedSource(ipAddress: "192.0.2.1").family, .ipv4)
        let mapped = try LANV6NormalizedSource(ipAddress: "::ffff:192.0.2.1")
        let exact = try LANV6NormalizedSource(ipAddress: "192.0.2.1")
        XCTAssertEqual(mapped, exact)
        XCTAssertEqual(mapped.family, .ipv4)

        var sharedLimiter = LANV6HelloRateLimiter(nowNanoseconds: 0)
        for peer in [mapped, exact, mapped, exact] {
            XCTAssertTrue(sharedLimiter.consume(source: peer, nowNanoseconds: 0).allowed)
        }
        XCTAssertEqual(sharedLimiter.consume(source: mapped,
                                             nowNanoseconds: 0).denial, .source,
                       "mapped and exact IPv4 must share one four-token bucket")

        for invalid in ["", "[2001:db8::1]", "fe80::1%en0", "999.0.0.1", "host.local"] {
            XCTAssertThrowsError(try LANV6NormalizedSource(ipAddress: invalid), invalid)
        }
        XCTAssertThrowsError(try LANV6NormalizedSource(ipv4Bytes: [1, 2, 3]))
        XCTAssertThrowsError(try LANV6NormalizedSource(ipv6Bytes: [UInt8](repeating: 0,
                                                                          count: 15)))
    }

    func testSourceTableOverflowIsSharedAndExactIdleBoundaryEvictsStableLRU() throws {
        var limiter = LANV6HelloRateLimiter(nowNanoseconds: 0)
        for value in 0..<LAN_V6_MAX_SOURCE_BUCKETS {
            let now = UInt64(value) * 250_000_000
            let decision = limiter.consume(source: try source(value), nowNanoseconds: now)
            XCTAssertTrue(decision.allowed, "source \(value)")
            XCTAssertFalse(decision.usedOverflowBucket, "source \(value)")
        }
        XCTAssertEqual(limiter.trackedSourceCount, 256)

        let tableFillTime = UInt64(255) * 250_000_000
        for value in 256..<260 {
            let decision = limiter.consume(source: try source(value),
                                           nowNanoseconds: tableFillTime)
            XCTAssertTrue(decision.allowed)
            XCTAssertTrue(decision.usedOverflowBucket)
        }
        let fifthOverflow = limiter.consume(source: try source(260),
                                            nowNanoseconds: tableFillTime)
        XCTAssertTrue(fifthOverflow.usedOverflowBucket)
        XCTAssertEqual(fifthOverflow.denial, .source,
                       "all untracked sources must share one four-token overflow bucket")
        XCTAssertEqual(limiter.trackedSourceCount, 256)

        let oneNanosecondEarly = LAN_V6_SOURCE_BUCKET_IDLE_NANOSECONDS - 1
        let early = limiter.consume(source: try source(300),
                                    nowNanoseconds: oneNanosecondEarly)
        XCTAssertTrue(early.usedOverflowBucket,
                      "the oldest entry is not idle until the exact ten-minute boundary")
        XCTAssertEqual(limiter.trackedSourceCount, 256)

        let exactBoundary = LAN_V6_SOURCE_BUCKET_IDLE_NANOSECONDS
        let replacement = limiter.consume(source: try source(301),
                                          nowNanoseconds: exactBoundary)
        XCTAssertFalse(replacement.usedOverflowBucket)
        XCTAssertEqual(limiter.trackedSourceCount, 256)

        let evictedOldest = limiter.consume(source: try source(0),
                                            nowNanoseconds: exactBoundary)
        XCTAssertTrue(evictedOldest.usedOverflowBucket,
                      "stable LRU must evict source zero, the only exactly-idle entry")
    }

    func testClockRegressionHasNoAccountingSideEffectsAndRestartStartsFull() throws {
        let peer = try source(1)
        let unknown = try source(2)
        var limiter = LANV6HelloRateLimiter(nowNanoseconds: 100)
        for _ in 0..<3 {
            XCTAssertTrue(limiter.consume(source: peer, nowNanoseconds: 100).allowed)
        }
        let trackedBefore = limiter.trackedSourceCount
        let regressed = limiter.consume(source: unknown, nowNanoseconds: 99)
        XCTAssertFalse(regressed.allowed)
        XCTAssertEqual(regressed.denial, .monotonicClockRegressed)
        XCTAssertFalse(regressed.usedOverflowBucket)
        XCTAssertEqual(limiter.trackedSourceCount, trackedBefore)
        XCTAssertTrue(limiter.consume(source: peer, nowNanoseconds: 100).allowed)
        XCTAssertEqual(limiter.consume(source: peer, nowNanoseconds: 100).denial, .source)

        var restarted = LANV6HelloRateLimiter(nowNanoseconds: 100)
        for _ in 0..<4 {
            XCTAssertTrue(restarted.consume(source: peer, nowNanoseconds: 100).allowed)
        }
        XCTAssertEqual(restarted.consume(source: peer, nowNanoseconds: 100).denial, .source)
    }

    func testUInt64MaximumClockRefillDoesNotOverflow() throws {
        let start = UInt64.max - 10_000_000_000
        var limiter = LANV6HelloRateLimiter(nowNanoseconds: start)
        let peer = try source(1)
        for _ in 0..<4 {
            XCTAssertTrue(limiter.consume(source: peer, nowNanoseconds: start).allowed)
        }
        XCTAssertTrue(limiter.consume(source: peer, nowNanoseconds: UInt64.max).allowed)
    }

    func testGateOwnsClockSamplingAndConcurrentReverseSchedulingNeverRegresses() throws {
        let clock = StrictlyIncreasingClock(start: 1_000, step: 250_000_000)
        let gate = LANV6HelloRateLimitGate(clock: clock)
        let peers = try (0..<64).reversed().map(source)
        let decisions = RateLockedResults<LANV6HelloRateLimitDecision>()

        DispatchQueue.concurrentPerform(iterations: peers.count) { offset in
            decisions.append(gate.consume(source: peers[offset]))
        }

        let captured = decisions.snapshot()
        XCTAssertEqual(captured.count, peers.count)
        XCTAssertFalse(captured.contains { $0.denial == .monotonicClockRegressed })
        XCTAssertEqual(clock.sampleCount, peers.count + 1,
                       "the gate samples once at init and once per locked consume")
        XCTAssertEqual(gate.snapshot().trackedSourceCount, peers.count)
    }

    func testSeededTwentyThousandStepsMatchIndependentReferenceModel() throws {
        let sources = try (0..<320).map(source)
        var implementation = LANV6HelloRateLimiter(nowNanoseconds: 0)
        var reference = ReferenceRateLimiter(now: 0)
        var rng = RateLCG(seed: 0x51a7_0f1e_2d3c_4b5a)
        var now: UInt64 = 0
        let exactDeltas: [UInt64] = [
            0, 1, 249_999_999, 250_000_000,
            4_999_999_999, 5_000_000_000,
            599_999_999_999, 600_000_000_000,
        ]

        for iteration in 0..<20_000 {
            let sourceID = Int(rng.next() % UInt64(sources.count))
            let delta: UInt64
            if iteration.isMultiple(of: 97) {
                delta = exactDeltas[(iteration / 97) % exactDeltas.count]
            } else {
                delta = rng.next() % 1_000_000_000
            }
            now += delta

            let actual = implementation.consume(source: sources[sourceID],
                                                nowNanoseconds: now)
            let expected = reference.consume(sourceID: sourceID, now: now)
            XCTAssertEqual(actual.allowed, expected.allowed, "iteration \(iteration)")
            XCTAssertEqual(actual.denial, expected.denial, "iteration \(iteration)")
            XCTAssertEqual(actual.usedOverflowBucket, expected.usedOverflow,
                           "iteration \(iteration)")
            XCTAssertEqual(implementation.trackedSourceCount, reference.sources.count,
                           "iteration \(iteration)")
        }
    }

    private func source(_ value: Int) throws -> LANV6NormalizedSource {
        precondition((0...0x00ff_ffff).contains(value))
        return try LANV6NormalizedSource(ipv4Bytes: [
            10,
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ])
    }
}

private struct ReferenceRateDecision {
    let allowed: Bool
    let denial: LANV6HelloRateLimitDenial?
    let usedOverflow: Bool
}

private struct ReferenceBucket {
    let capacity: UInt64
    let interval: UInt64
    var credit: UInt64
    var last: UInt64

    init(capacity: UInt64, interval: UInt64, now: UInt64) {
        self.capacity = capacity
        self.interval = interval
        credit = capacity * interval
        last = now
    }

    mutating func consume(now: UInt64) -> Bool {
        let elapsed = now - last
        last = now
        let maximum = capacity * interval
        credit += min(elapsed, maximum - credit)
        guard credit >= interval else { return false }
        credit -= interval
        return true
    }
}

private struct ReferenceSourceEntry {
    var bucket: ReferenceBucket
    var lastSeen: UInt64
    var accessOrdinal: UInt64
}

private struct ReferenceRateLimiter {
    var global: ReferenceBucket
    var overflow: ReferenceBucket
    var sources: [Int: ReferenceSourceEntry] = [:]
    var lastObserved: UInt64
    var nextOrdinal: UInt64 = 1

    init(now: UInt64) {
        global = ReferenceBucket(capacity: 32, interval: 250_000_000, now: now)
        overflow = ReferenceBucket(capacity: 4, interval: 5_000_000_000, now: now)
        lastObserved = now
    }

    mutating func consume(sourceID: Int, now: UInt64) -> ReferenceRateDecision {
        guard now >= lastObserved else {
            return ReferenceRateDecision(allowed: false,
                                         denial: .monotonicClockRegressed,
                                         usedOverflow: false)
        }
        lastObserved = now
        let globalAllowed = global.consume(now: now)
        let concrete = selectSource(sourceID, now: now)
        let sourceAllowed: Bool
        if concrete {
            var entry = sources[sourceID]!
            entry.lastSeen = now
            entry.accessOrdinal = takeOrdinal()
            sourceAllowed = entry.bucket.consume(now: now)
            sources[sourceID] = entry
        } else {
            sourceAllowed = overflow.consume(now: now)
        }

        let denial: LANV6HelloRateLimitDenial?
        switch (globalAllowed, sourceAllowed) {
        case (true, true): denial = nil
        case (false, true): denial = .global
        case (true, false): denial = .source
        case (false, false): denial = .globalAndSource
        }
        return ReferenceRateDecision(allowed: globalAllowed && sourceAllowed,
                                     denial: denial, usedOverflow: !concrete)
    }

    private mutating func selectSource(_ sourceID: Int, now: UInt64) -> Bool {
        if sources[sourceID] != nil { return true }
        if sources.count >= LAN_V6_MAX_SOURCE_BUCKETS {
            let idle = sources.filter { _, entry in
                now >= entry.lastSeen &&
                    now - entry.lastSeen >= LAN_V6_SOURCE_BUCKET_IDLE_NANOSECONDS
            }
            guard let victim = idle.min(by: { lhs, rhs in
                if lhs.value.lastSeen != rhs.value.lastSeen {
                    return lhs.value.lastSeen < rhs.value.lastSeen
                }
                if lhs.value.accessOrdinal != rhs.value.accessOrdinal {
                    return lhs.value.accessOrdinal < rhs.value.accessOrdinal
                }
                return lhs.key < rhs.key
            }) else { return false }
            sources.removeValue(forKey: victim.key)
        }
        sources[sourceID] = ReferenceSourceEntry(
            bucket: ReferenceBucket(capacity: 4, interval: 5_000_000_000, now: now),
            lastSeen: now,
            accessOrdinal: takeOrdinal()
        )
        return true
    }

    private mutating func takeOrdinal() -> UInt64 {
        let ordinal = nextOrdinal
        nextOrdinal += 1
        return ordinal
    }
}

private struct RateLCG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
        return state
    }
}

private final class StrictlyIncreasingClock: LANV6MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private let step: UInt64
    private var nextValue: UInt64
    private var samples = 0

    init(start: UInt64, step: UInt64) {
        nextValue = start
        self.step = step
    }

    func nowNanoseconds() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let value = nextValue
        nextValue += step
        samples += 1
        return value
    }

    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}

private final class RateLockedResults<Value>: @unchecked Sendable {
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
