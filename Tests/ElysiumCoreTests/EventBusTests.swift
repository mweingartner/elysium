// EventBusTests.swift — event-bus (change 1b). Spec-level coverage of
// `EventBus` itself: the catalog's `EventKind` grammar, delivery-order
// determinism (§7.4), coalescing/caps/cascade (§7.6), subscription CRUD and
// caps (§7.3), persistence round-trips (`SubscriptionRegistryCodec`), and the
// zero-subscription fast path. Funnel-level ("does the real engine call site
// raise this") coverage lives in `EventBusFunnelTests.swift`.

import XCTest
@testable import ElysiumCore

final class EventBusTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
    }

    // MARK: - EventKind grammar

    func testEventKindParsesCatalogAndCustomNames() {
        XCTAssertEqual(EventKind.parse("attribute.changed"), .attributeChanged)
        XCTAssertEqual(EventKind.parse("block.broken"), .blockBroken)
        XCTAssertEqual(EventKind.parse("block.toolStrike"), .blockToolStrike)
        XCTAssertEqual(EventKind.parse("lumber.milestone")?.rawValue, "lumber.milestone")
        XCTAssertEqual(EventKind.parse("custom_thing")?.rawValue, "custom_thing")
    }

    func testEventKindRejectsMalformedNames() {
        XCTAssertNil(EventKind.parse(""))
        XCTAssertNil(EventKind.parse("Attribute.Changed")) // uppercase
        XCTAssertNil(EventKind.parse("a.b.c.d.e")) // > 4 segments
        XCTAssertNil(EventKind.parse("a..b")) // empty segment
        XCTAssertNil(EventKind.parse(String(repeating: "a", count: 65))) // > 64 bytes
        XCTAssertNil(EventKind.parse("1abc")) // segment must start with a letter
    }

    func testRequiresBlockTypeFilterIsExactlyAttributeChangedAndBlockChanged() {
        XCTAssertTrue(EventKind.attributeChanged.requiresBlockTypeFilter)
        XCTAssertTrue(EventKind.blockChanged.requiresBlockTypeFilter)
        XCTAssertFalse(EventKind.blockBroken.requiresBlockTypeFilter)
        XCTAssertFalse(EventKind.blockPlaced.requiresBlockTypeFilter)
        XCTAssertFalse(EventKind.blockUsed.requiresBlockTypeFilter)
    }

    // MARK: - delivery order (§7.4)

    func testDeliveryOrderIsAscendingSeqAcrossDifferentSubjects() {
        let bus = EventBus()
        var delivered: [EventKind] = []
        bus.delivery = { event, _ in delivered.append(event.kind) }
        bus.raise(kind: .entitySpawned, subject: .entity(uid: 1), source: .engine, tick: 0)
        bus.raise(kind: .entityRemoved, subject: .entity(uid: 2), source: .engine, tick: 0)
        bus.raise(kind: .playerJoined, subject: .player, source: .player, tick: 0)
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered, [.entitySpawned, .entityRemoved, .playerJoined])
    }

    func testTwoIndependentRunsProduceIdenticalDeliveryOrder() {
        func runOnce() -> [UInt64] {
            let bus = EventBus()
            var seqs: [UInt64] = []
            bus.delivery = { event, _ in seqs.append(event.seq) }
            for i in 0..<20 {
                bus.raise(kind: .entitySpawned, subject: .entity(uid: i), source: .engine, tick: 0)
            }
            bus.runDeliveryPhase(tick: 0)
            return seqs
        }
        XCTAssertEqual(runOnce(), runOnce())
        XCTAssertEqual(runOnce(), Array(0..<20).map(UInt64.init))
    }

    func testRecipientsAreOrderedByAscendingSubscriptionID() {
        let bus = EventBus()
        let target = SubscriptionTarget.object(.player)
        // Registered out of natural id order isn't possible via the public
        // API (ids are assigned at registration) — assert the *assigned*
        // order instead: three subscriptions on the same target/event/attr
        // triple differ only by handler name (a different natural key), and
        // delivery must return them in ascending id regardless of the order
        // `persistedSubs`/`scriptOwnedSubs` happen to store them internally
        // (persisted first, then script-owned, interleaved by shared id).
        let s1 = bus.subscribe(
            subscriber: .player, scriptName: "a", handler: "h1", target: target, event: .playerJoined,
            attribute: nil, createdBy: .player, tick: 0
        )
        let scriptOwned = bus.registerScriptOwned(
            owner: .player, scriptName: "b", target: target, event: .playerJoined, attribute: nil
        )
        let s2 = bus.subscribe(
            subscriber: .player, scriptName: "c", handler: "h2", target: target, event: .playerJoined,
            attribute: nil, createdBy: .player, tick: 0
        )
        guard case .success(let sub1) = s1, case .success(let sub2) = s2 else {
            return XCTFail("subscribe failed")
        }
        XCTAssertLessThan(sub1.id, scriptOwned.id)
        XCTAssertLessThan(scriptOwned.id, sub2.id)

        var recipientIDs: [UInt64] = []
        bus.delivery = { _, targets in recipientIDs = targets.map(\.id) }
        bus.raise(kind: .playerJoined, subject: .player, source: .player, tick: 0)
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(recipientIDs, recipientIDs.sorted())
        XCTAssertEqual(Set(recipientIDs), Set([sub1.id, scriptOwned.id, sub2.id]))
    }

    func testRecipientDeliveryBudgetSlicesOneEventWithoutReplayingHandlers() {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2, maxEventsPerHandler: 256,
            maxQueueSize: 32, maxRecentEvents: 32, maxSubscriptionsPerWorld: 8,
            maxSubscriptionsPerObject: 8
        )
        let bus = EventBus(caps: caps)
        for i in 0..<3 {
            _ = bus.registerScriptOwned(
                owner: .entity(uid: i + 1), scriptName: "s\(i)",
                target: .object(.player), event: .playerJoined, attribute: nil
            )
        }
        var recipientIDs: [UInt64] = []
        bus.delivery = { _, targets in recipientIDs += targets.map(\.id) }
        bus.raise(kind: .playerJoined, subject: .player, source: .player, tick: 0)

        let first = bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(first.delivered, 2)
        XCTAssertEqual(first.carriedOver, 1)
        XCTAssertEqual(bus.pendingCount, 1)
        XCTAssertEqual(recipientIDs.count, 2)

        let second = bus.runDeliveryPhase(tick: 1)
        XCTAssertEqual(second.delivered, 1)
        XCTAssertEqual(second.carriedOver, 0)
        XCTAssertEqual(recipientIDs, recipientIDs.sorted())
        XCTAssertEqual(Set(recipientIDs).count, 3, "a carried recipient suffix must not replay prior handlers")
    }

    func testRuntimeAdmissionZeroRetainsExactRecipientSuffixWithoutClaimingDelivery() {
        let bus = EventBus()
        for i in 0..<3 {
            _ = bus.registerScriptOwned(
                owner: .entity(uid: i + 1), scriptName: "s\(i)",
                target: .object(.player), event: .playerJoined, attribute: nil
            )
        }
        var admissionCalls = 0
        bus.deliveryAdmission = { _, proposed in
            admissionCalls += 1
            return admissionCalls == 1 ? min(1, proposed.count) : 0
        }
        var deliveredIDs: [UInt64] = []
        bus.delivery = { _, targets in deliveredIDs += targets.map(\.id) }
        bus.raise(kind: .playerJoined, subject: .player, source: .player, tick: 0)

        let first = bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(first.delivered, 1)
        XCTAssertEqual(first.carriedOver, 1)
        XCTAssertEqual(deliveredIDs.count, 1)

        bus.deliveryAdmission = { _, proposed in proposed.count }
        let second = bus.runDeliveryPhase(tick: 1)
        XCTAssertEqual(second.delivered, 2)
        XCTAssertEqual(second.carriedOver, 0)
        XCTAssertEqual(deliveredIDs, deliveredIDs.sorted())
        XCTAssertEqual(Set(deliveredIDs).count, 3)
    }

    func testNoRecipientEventsConsumeBoundedPhaseWorkWithoutInflatingDeliveredCount() {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2, maxEventsPerHandler: 256,
            maxQueueSize: 32, maxRecentEvents: 32, maxSubscriptionsPerWorld: 8,
            maxSubscriptionsPerObject: 8
        )
        let bus = EventBus(caps: caps)
        var observed: [UInt64] = []
        bus.delivery = { event, targets in
            XCTAssertTrue(targets.isEmpty)
            observed.append(event.seq)
        }
        for i in 0..<5 {
            bus.raise(kind: .entitySpawned, subject: .entity(uid: i), source: .engine, tick: 0)
        }

        let first = bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(first.delivered, 0)
        XCTAssertEqual(first.carriedOver, 3)
        XCTAssertEqual(observed, [0, 1])
        let second = bus.runDeliveryPhase(tick: 1)
        XCTAssertEqual(second.carriedOver, 1)
        XCTAssertEqual(observed, [0, 1, 2, 3])
        let third = bus.runDeliveryPhase(tick: 2)
        XCTAssertEqual(third.carriedOver, 0)
        XCTAssertEqual(observed, [0, 1, 2, 3, 4])
    }

    // MARK: - coalescing (§7.6)

    func testAttributeChangedCoalescesKeepingFirstOldLastNewLastSeq() {
        let bus = EventBus()
        let r1 = bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("mood"), "old": .string("a"), "new": .string("b")],
            source: .player, tick: 0
        )
        let r2 = bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("mood"), "old": .string("b"), "new": .string("c")],
            source: .player, tick: 0
        )
        guard case .enqueued(let firstSeq) = r1, case .coalesced(let mergedSeq) = r2 else {
            return XCTFail("expected enqueue then coalesce, got \(r1) / \(r2)")
        }
        XCTAssertNotEqual(firstSeq, mergedSeq) // §7.6: "the last seq"
        var payload: [String: AttrValue] = [:]
        bus.delivery = { event, _ in payload = event.payload }
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(payload["old"], .string("a")) // first old
        XCTAssertEqual(payload["new"], .string("c")) // last new
        XCTAssertEqual(bus.pendingCount, 0) // only one event was ever delivered
    }

    func testBlockChangedCoalescesPerPositionKeepingFirstOldMetaAndLastNewMeta() {
        let bus = EventBus()
        let subject = ObjectRef.block(dim: .overworld, x: 1, y: 2, z: 3)
        bus.raise(
            kind: .blockChanged, subject: subject,
            payload: ["oldName": .string("stone"), "newName": .string("dirt"), "oldMeta": .int(0), "newMeta": .int(0)],
            source: .engine, tick: 0
        )
        bus.raise(
            kind: .blockChanged, subject: subject,
            payload: ["oldName": .string("dirt"), "newName": .string("grass"), "oldMeta": .int(0), "newMeta": .int(1)],
            source: .engine, tick: 0
        )
        var payload: [String: AttrValue] = [:]
        var deliveredCount = 0
        bus.delivery = { event, _ in payload = event.payload; deliveredCount += 1 }
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(deliveredCount, 1)
        XCTAssertEqual(payload["oldName"], .string("stone")) // first old
        XCTAssertEqual(payload["newName"], .string("grass")) // last new
        XCTAssertEqual(payload["newMeta"], .int(1))
    }

    func testDifferentSubjectsDoNotCoalesceTogether() {
        let bus = EventBus()
        bus.raise(
            kind: .attributeChanged, subject: .entity(uid: 1),
            payload: ["key": .string("mood"), "old": .null, "new": .int(1)], source: .engine, tick: 0
        )
        bus.raise(
            kind: .attributeChanged, subject: .entity(uid: 2),
            payload: ["key": .string("mood"), "old": .null, "new": .int(2)], source: .engine, tick: 0
        )
        var count = 0
        bus.delivery = { _, _ in count += 1 }
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(count, 2)
    }

    func testRepeatedCoalescingKeepsBoundedSparseQueueStorageBehavior() {
        let bus = EventBus()
        for i in 0..<20_000 {
            bus.raise(
                kind: .attributeChanged, subject: .player,
                payload: ["key": .string("mood"), "old": .int(0), "new": .int(Int64(i))],
                source: .player, tick: 0
            )
        }
        XCTAssertEqual(bus.pendingCount, 1)
        var delivered: ScriptEvent?
        bus.delivery = { event, _ in delivered = event }
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered?.payload["old"], .int(0))
        XCTAssertEqual(delivered?.payload["new"], .int(19_999))
        XCTAssertEqual(bus.pendingCount, 0)
    }

    // MARK: - caps (§7.6)

    func testQueueFullDropsExcessAndRaisesExactlyOneOverBudgetPerTick() {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2_048, maxEventsPerHandler: 256, maxQueueSize: 4,
            maxRecentEvents: 128, maxSubscriptionsPerWorld: 512, maxSubscriptionsPerObject: 32
        )
        let bus = EventBus(caps: caps)
        // 4 distinct, non-coalescable events fill the queue; a 5th and 6th
        // must be dropped, and only one `script.overBudget` is queued for it.
        for i in 0..<4 {
            let outcome = bus.raise(kind: .entitySpawned, subject: .entity(uid: i), source: .engine, tick: 0)
            XCTAssertEqual(outcome, .enqueued(seq: UInt64(i)))
        }
        XCTAssertEqual(bus.raise(kind: .entitySpawned, subject: .entity(uid: 100), source: .engine, tick: 0), .droppedQueueFull)
        XCTAssertEqual(bus.raise(kind: .entitySpawned, subject: .entity(uid: 101), source: .engine, tick: 0), .droppedQueueFull)
        XCTAssertEqual(bus.pendingCount, caps.maxQueueSize, "the diagnostic must not bypass the queue cap")
        var kinds: [EventKind] = []
        bus.delivery = { event, _ in kinds.append(event.kind) }
        let report = bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(kinds.filter { $0 == .scriptOverBudget }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == .entitySpawned }.count, 4)
        XCTAssertEqual(report.droppedForQueueFull, 2)
    }

    func testPayloadSizerRejectsOversizedEventsAndMapKeysBeforeRetention() throws {
        var byteCaps = EventBus.Caps.defaults
        byteCaps.maxEventPayloadBytes = 64
        byteCaps.maxPendingPayloadBytes = 4_096
        byteCaps.maxRecentPayloadBytes = 4_096
        let oversizedBus = EventBus(caps: byteCaps)
        let custom = try XCTUnwrap(EventKind.parse("test.payload"))

        XCTAssertEqual(
            oversizedBus.raise(
                kind: custom, subject: .world,
                payload: ["blob": .string(String(repeating: "x", count: 100))],
                source: .script(owner: .world, name: "adversary"), tick: 0
            ),
            .droppedQueueFull
        )
        XCTAssertFalse(oversizedBus.recentEvents().contains { $0.kind == custom })
        XCTAssertEqual(oversizedBus.recentEvents().map(\.kind), [.scriptOverBudget])
        XCTAssertLessThanOrEqual(oversizedBus.pendingPayloadBytes, byteCaps.maxPendingPayloadBytes)

        var keyCaps = byteCaps
        keyCaps.maxEventPayloadBytes = 512
        let oversizedKeyBus = EventBus(caps: keyCaps)
        XCTAssertEqual(
            oversizedKeyBus.raise(
                kind: custom, subject: .world,
                payload: [String(repeating: "k", count: 257): .int(1)],
                source: .engine, tick: 0
            ),
            .droppedQueueFull
        )
        XCTAssertFalse(oversizedKeyBus.recentEvents().contains { $0.kind == custom })
        XCTAssertLessThanOrEqual(oversizedKeyBus.pendingPayloadBytes, keyCaps.maxPendingPayloadBytes)
    }

    func testAggregatePendingAndRecentPayloadByteCapsEvictAndDrainExactly() throws {
        var caps = EventBus.Caps.defaults
        caps.maxEventPayloadBytes = 512
        caps.maxPendingPayloadBytes = 900
        caps.maxRecentPayloadBytes = 300
        let bus = EventBus(caps: caps)
        let custom = try XCTUnwrap(EventKind.parse("test.payload"))
        let payload = ["blob": AttrValue.string(String(repeating: "x", count: 250))]

        XCTAssertTrue(bus.raise(
            kind: custom, subject: .entity(uid: 1), payload: payload,
            source: .engine, tick: 0
        ).wasEnqueued)
        let retainedAfterFirst = bus.pendingPayloadBytes
        XCTAssertEqual(retainedAfterFirst, AttrValueCodec.encode(.map(payload)).utf8.count)
        XCTAssertEqual(
            bus.raise(
                kind: custom, subject: .entity(uid: 2), payload: payload,
                source: .engine, tick: 0
            ),
            .droppedQueueFull
        )
        XCTAssertGreaterThanOrEqual(bus.pendingPayloadBytes, retainedAfterFirst)
        XCTAssertLessThanOrEqual(bus.pendingPayloadBytes, caps.maxPendingPayloadBytes)
        XCTAssertLessThanOrEqual(bus.recentPayloadBytes, caps.maxRecentPayloadBytes)
        XCTAssertFalse(bus.recentEvents().contains { $0.subject == .entity(uid: 1) },
                       "the byte ring must evict an entry even below its count cap")

        bus.delivery = { _, _ in }
        _ = bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(bus.pendingCount, 0)
        XCTAssertEqual(bus.pendingPayloadBytes, 0)
        XCTAssertLessThanOrEqual(bus.recentPayloadBytes, caps.maxRecentPayloadBytes)
    }

    func testFailedCoalescingByteReplacementKeepsOriginalAndAccounting() {
        var caps = EventBus.Caps.defaults
        caps.maxEventPayloadBytes = 512
        caps.maxPendingPayloadBytes = 900
        caps.maxRecentPayloadBytes = 4_096
        let bus = EventBus(caps: caps)
        XCTAssertTrue(bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("mood"), "old": .string("a"), "new": .string("b")],
            source: .player, tick: 0
        ).wasEnqueued)
        let originalBytes = bus.pendingPayloadBytes

        XCTAssertEqual(bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: [
                "key": .string("mood"), "old": .string("b"),
                "new": .string(String(repeating: "z", count: 370)),
            ],
            source: .player, tick: 0
        ), .droppedQueueFull)
        XCTAssertGreaterThanOrEqual(bus.pendingPayloadBytes, originalBytes)
        XCTAssertLessThanOrEqual(bus.pendingPayloadBytes, caps.maxPendingPayloadBytes)

        var delivered: [ScriptEvent] = []
        bus.delivery = { event, _ in delivered.append(event) }
        _ = bus.runDeliveryPhase(tick: 0)
        let original = delivered.first { $0.kind == .attributeChanged }
        XCTAssertEqual(original?.payload["old"], .string("a"))
        XCTAssertEqual(original?.payload["new"], .string("b"))
        XCTAssertEqual(bus.pendingPayloadBytes, 0)
    }

    func testStalledCursorAndDeferredDiagnosticRemainChargedExactlyOnce() {
        var caps = EventBus.Caps.defaults
        caps.maxQueueSize = 1
        caps.maxDeliveriesPerTick = 8
        caps.maxEventPayloadBytes = 512
        caps.maxPendingPayloadBytes = 900
        caps.maxRecentPayloadBytes = 4_096
        let bus = EventBus(caps: caps)
        _ = bus.registerScriptOwned(
            owner: .player, scriptName: "s", target: .object(.player),
            event: .playerJoined, attribute: nil
        )
        bus.deliveryAdmission = { _, _ in 0 }
        XCTAssertTrue(bus.raise(
            kind: .playerJoined, subject: .player, source: .engine, tick: 0
        ).wasEnqueued)
        let eventBytes = bus.pendingPayloadBytes
        _ = bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(bus.pendingPayloadBytes, eventBytes, "moving into a cursor must not release bytes")

        XCTAssertEqual(bus.raise(
            kind: .entitySpawned, subject: .entity(uid: 1), source: .engine, tick: 1
        ), .droppedQueueFull)
        let eventAndDeferredBytes = bus.pendingPayloadBytes
        XCTAssertGreaterThan(eventAndDeferredBytes, eventBytes)
        XCTAssertLessThanOrEqual(eventAndDeferredBytes, caps.maxPendingPayloadBytes)
        for tick in 2...20 {
            XCTAssertEqual(bus.raise(
                kind: .entitySpawned, subject: .entity(uid: tick),
                source: .engine, tick: Int64(tick)
            ), .droppedQueueFull)
            XCTAssertEqual(bus.pendingPayloadBytes, eventAndDeferredBytes,
                           "later diagnostics must not double-charge the one deferred slot")
        }

        bus.delivery = { _, _ in }
        bus.deliveryAdmission = { _, proposed in proposed.count }
        _ = bus.runDeliveryPhase(tick: 21)
        XCTAssertEqual(bus.pendingCount, 0)
        XCTAssertEqual(bus.pendingPayloadBytes, 0)
    }

    func testDeferredOverBudgetDiagnosticStaysBoundedBehindAStalledDeliveryCursor() {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 8, maxEventsPerHandler: 256,
            maxQueueSize: 1, maxRecentEvents: 128, maxSubscriptionsPerWorld: 8,
            maxSubscriptionsPerObject: 8
        )
        let bus = EventBus(caps: caps)
        _ = bus.registerScriptOwned(
            owner: .player, scriptName: "s", target: .object(.player),
            event: .playerJoined, attribute: nil
        )
        bus.deliveryAdmission = { _, _ in 0 }
        XCTAssertTrue(
            bus.raise(kind: .playerJoined, subject: .player, source: .engine, tick: 0).wasEnqueued
        )
        _ = bus.runDeliveryPhase(tick: 0)

        for tick in 1...32 {
            XCTAssertEqual(
                bus.raise(
                    kind: .entitySpawned, subject: .entity(uid: tick),
                    source: .engine, tick: Int64(tick)
                ),
                .droppedQueueFull
            )
            XCTAssertEqual(bus.pendingCount, caps.maxQueueSize)
        }

        var deliveredKinds: [EventKind] = []
        bus.delivery = { event, _ in deliveredKinds.append(event.kind) }
        bus.deliveryAdmission = { _, proposed in proposed.count }
        _ = bus.runDeliveryPhase(tick: 33)
        XCTAssertEqual(deliveredKinds.filter { $0 == .playerJoined }.count, 1)
        XCTAssertEqual(deliveredKinds.filter { $0 == .scriptOverBudget }.count, 1)
        XCTAssertEqual(bus.pendingCount, 0)
    }

    func testOverBudgetSignalResetsEachTick() {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2_048, maxEventsPerHandler: 256, maxQueueSize: 1,
            maxRecentEvents: 128, maxSubscriptionsPerWorld: 512, maxSubscriptionsPerObject: 32
        )
        let bus = EventBus(caps: caps)
        bus.delivery = { _, _ in }
        bus.raise(kind: .entitySpawned, subject: .entity(uid: 1), source: .engine, tick: 0)
        XCTAssertEqual(bus.raise(kind: .entitySpawned, subject: .entity(uid: 2), source: .engine, tick: 0), .droppedQueueFull)
        bus.runDeliveryPhase(tick: 0) // drains the queue and resets the signal
        bus.raise(kind: .entitySpawned, subject: .entity(uid: 3), source: .engine, tick: 1)
        XCTAssertEqual(bus.raise(kind: .entitySpawned, subject: .entity(uid: 4), source: .engine, tick: 1), .droppedQueueFull)
        var overBudgetCount = 0
        bus.delivery = { event, _ in if event.kind == .scriptOverBudget { overBudgetCount += 1 } }
        bus.runDeliveryPhase(tick: 1)
        XCTAssertEqual(overBudgetCount, 1, "a fresh tick gets its own over-budget signal")
    }

    func testHandlerEventBudgetTripsAtExactlyTwoHundredFiftySeven() {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2_048, maxEventsPerHandler: 3, maxQueueSize: 8_192,
            maxRecentEvents: 128, maxSubscriptionsPerWorld: 512, maxSubscriptionsPerObject: 32
        )
        let bus = EventBus(caps: caps)
        var outcomes: [EventBus.RaiseOutcome] = []
        bus.withHandlerContext {
            for i in 0..<5 {
                outcomes.append(bus.raise(kind: .entitySpawned, subject: .entity(uid: i), source: .engine, tick: 0))
            }
        }
        XCTAssertEqual(outcomes[0], .enqueued(seq: 0))
        XCTAssertEqual(outcomes[1], .enqueued(seq: 1))
        XCTAssertEqual(outcomes[2], .enqueued(seq: 2))
        XCTAssertEqual(outcomes[3], .droppedHandlerBudget)
        XCTAssertEqual(outcomes[4], .droppedHandlerBudget)
        // Outside the handler context the budget doesn't apply.
        XCTAssertEqual(bus.raise(kind: .entitySpawned, subject: .entity(uid: 99), source: .engine, tick: 0).wasEnqueued, true)
    }

    func testNestedHandlerContextsRestoreTheOuterCounter() {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2_048, maxEventsPerHandler: 1, maxQueueSize: 8_192,
            maxRecentEvents: 128, maxSubscriptionsPerWorld: 512, maxSubscriptionsPerObject: 32
        )
        let bus = EventBus(caps: caps)
        bus.withHandlerContext {
            _ = bus.raise(kind: .entitySpawned, subject: .entity(uid: 1), source: .engine, tick: 0) // outer 1/1
            bus.withHandlerContext {
                let inner = bus.raise(kind: .entitySpawned, subject: .entity(uid: 2), source: .engine, tick: 0)
                XCTAssertEqual(inner, .enqueued(seq: 1)) // inner context has its own fresh budget
            }
            let outerSecond = bus.raise(kind: .entitySpawned, subject: .entity(uid: 3), source: .engine, tick: 0)
            XCTAssertEqual(outerSecond, .droppedHandlerBudget) // outer budget (1) was already spent
        }
    }

    func testCascadeDepthCapsAtEight() {
        let bus = EventBus()
        var chain: [ScriptEvent] = [] // built by hand to simulate a would-be handler chain
        let root = ScriptEvent(seq: 0, tick: 0, kind: .entitySpawned, subject: .entity(uid: 0), payload: [:], source: .engine, cascadeDepth: 0)
        chain.append(root)
        var outcomes: [EventBus.RaiseOutcome] = []
        var current = root
        for i in 1...9 {
            let outcome = bus.raise(
                kind: .entitySpawned, subject: .entity(uid: i), source: .engine, tick: 0, causedBy: current
            )
            outcomes.append(outcome)
            if case .enqueued = outcome {
                // Re-derive the just-enqueued event's depth for the next
                // link — depth is `causedBy.cascadeDepth + 1`, matching what
                // `raise` itself just computed.
                current = ScriptEvent(
                    seq: 0, tick: 0, kind: .entitySpawned, subject: .entity(uid: i), payload: [:],
                    source: .engine, cascadeDepth: current.cascadeDepth + 1
                )
            }
        }
        // depths 1...8 succeed (root is depth 0), depth 9 is refused.
        for i in 0..<8 { XCTAssertTrue(outcomes[i].wasEnqueued, "depth \(i + 1) should be enqueued") }
        XCTAssertEqual(outcomes[8], .droppedCascadeDepth)
    }

    // MARK: - subscriptions (§7.3)

    func testSubscribeUpsertsOnNaturalKey() {
        let bus = EventBus()
        let target = SubscriptionTarget.object(.player)
        let r1 = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: target, event: .playerJoined,
            attribute: nil, createdBy: .player, tick: 0
        )
        let r2 = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: target, event: .playerJoined,
            attribute: nil, createdBy: .player, tick: 5
        )
        guard case .success(let sub1) = r1, case .success(let sub2) = r2 else { return XCTFail() }
        XCTAssertEqual(sub1.id, sub2.id)
        XCTAssertEqual(bus.listSubscriptions().count, 1)
    }

    func testSubscribeEnforcesPerObjectAndPerWorldCaps() {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2_048, maxEventsPerHandler: 256, maxQueueSize: 8_192,
            maxRecentEvents: 128, maxSubscriptionsPerWorld: 3, maxSubscriptionsPerObject: 2
        )
        let bus = EventBus(caps: caps)
        func sub(_ handler: String) -> Result<Subscription, EventBus.SubscribeError> {
            bus.subscribe(
                subscriber: .player, scriptName: "s", handler: handler, target: .object(.player),
                event: .playerJoined, attribute: nil, createdBy: .player, tick: 0
            )
        }
        XCTAssertTrue(sub("h1").isSuccessValue)
        XCTAssertTrue(sub("h2").isSuccessValue)
        guard case .failure(.tooManyForObject) = sub("h3") else { return XCTFail("expected tooManyForObject") }

        // A different subscriber can still register (per-object cap, not
        // global) up to the *world* cap.
        let r3 = bus.subscribe(
            subscriber: .entity(uid: 1), scriptName: "s", handler: "h1", target: .object(.player),
            event: .playerJoined, attribute: nil, createdBy: .player, tick: 0
        )
        XCTAssertTrue(r3.isSuccessValue)
        guard case .failure(.tooManyForWorld) = bus.subscribe(
            subscriber: .entity(uid: 2), scriptName: "s", handler: "h1", target: .object(.player),
            event: .playerJoined, attribute: nil, createdBy: .player, tick: 0
        ) else { return XCTFail("expected tooManyForWorld") }
    }

    func testSubscribeRefusesUnfilteredBlockKindOnAttributeChangedAndBlockChanged() {
        let bus = EventBus()
        for event in [EventKind.attributeChanged, .blockChanged] {
            let r = bus.subscribe(
                subscriber: .player, scriptName: "s", handler: "h", target: .kind(.block, typeFilter: nil),
                event: event, attribute: nil, createdBy: .player, tick: 0
            )
            guard case .failure(.targetRequiresTypeFilter) = r else { return XCTFail("expected targetRequiresTypeFilter for \(event)") }
        }
        // A causal block event doesn't require a filter.
        XCTAssertTrue(bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .kind(.block, typeFilter: nil),
            event: .blockBroken, attribute: nil, createdBy: .player, tick: 0
        ).isSuccessValue)
    }

    func testSubscribeRefusesAnyTargetOnAttributeChangedAndBlockChanged() {
        let bus = EventBus()
        for event in [EventKind.attributeChanged, .blockChanged] {
            let r = bus.subscribe(
                subscriber: .player, scriptName: "s", handler: "h", target: .any, event: event,
                attribute: nil, createdBy: .player, tick: 0
            )
            guard case .failure(.anyNotAllowedForThisEvent) = r else { return XCTFail("expected anyNotAllowedForThisEvent for \(event)") }
        }
        XCTAssertTrue(bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .any, event: .entitySpawned,
            attribute: nil, createdBy: .player, tick: 0
        ).isSuccessValue)
    }

    func testUnsubscribeRemovesByIDAndReportsAbsence() {
        let bus = EventBus()
        guard case .success(let sub) = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .object(.player), event: .playerJoined,
            attribute: nil, createdBy: .player, tick: 0
        ) else { return XCTFail() }
        XCTAssertTrue(bus.unsubscribe(id: sub.id))
        XCTAssertFalse(bus.unsubscribe(id: sub.id))
        XCTAssertFalse(bus.unsubscribe(id: 999_999))
        XCTAssertFalse(bus.hasEventInterest(.playerJoined, subject: .player))
    }

    // MARK: - matching (§7.3 target shapes)

    func testKindWildcardMatchesTypeFilterOnSubjectType() {
        let bus = EventBus()
        _ = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .kind(.entity, typeFilter: "zombie"),
            event: .entityDamaged, attribute: nil, createdBy: .player, tick: 0
        )
        var deliveredCount = 0
        bus.delivery = { _, targets in deliveredCount += targets.count }
        bus.raise(kind: .entityDamaged, subject: .entity(uid: 1), source: .engine, tick: 0, subjectType: "zombie")
        bus.raise(kind: .entityDamaged, subject: .entity(uid: 2), source: .engine, tick: 0, subjectType: "cow")
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(deliveredCount, 1)
    }

    func testAttributeFilterOnlyMatchesTheNamedAttribute() {
        let bus = EventBus()
        _ = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .object(.player), event: .attributeChanged,
            attribute: "mood", createdBy: .player, tick: 0
        )
        var deliveries: [String] = []
        bus.delivery = { event, targets in
            guard !targets.isEmpty, case .string(let key)? = event.payload["key"] else { return }
            deliveries.append(key)
        }
        bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("mood"), "old": .null, "new": .int(1)], source: .engine, tick: 0
        )
        bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("other"), "old": .null, "new": .int(1)], source: .engine, tick: 1
        )
        bus.runDeliveryPhase(tick: 1)
        XCTAssertEqual(deliveries, ["mood"])
    }

    func testCoalescedBlockAttributeTransitionMatchesOnlyOriginalAndFinalFamilies() throws {
        let bus = EventBus()
        var idsByType: [String: UInt64] = [:]
        for type in ["stone", "dirt", "grass_block"] {
            guard case .success(let subscription) = bus.subscribe(
                subscriber: .player, scriptName: type, handler: "changed",
                target: .kind(.block, typeFilter: type), event: .attributeChanged,
                attribute: "name", createdBy: .player, tick: 0
            ) else { return XCTFail("subscription failed for \(type)") }
            idsByType[type] = subscription.id
        }
        let subject = ObjectRef.block(dim: .overworld, x: 1, y: 2, z: 3)
        bus.raise(
            kind: .attributeChanged, subject: subject,
            payload: ["key": .string("name"), "old": .string("stone"), "new": .string("dirt")],
            source: .engine, tick: 0, subjectType: "dirt", priorSubjectType: "stone"
        )
        bus.raise(
            kind: .attributeChanged, subject: subject,
            payload: ["key": .string("name"), "old": .string("dirt"), "new": .string("grass_block")],
            source: .engine, tick: 0, subjectType: "grass_block", priorSubjectType: "dirt"
        )
        var deliveredIDs = Set<UInt64>()
        bus.delivery = { _, targets in deliveredIDs.formUnion(targets.map(\.id)) }
        bus.runDeliveryPhase(tick: 0)

        XCTAssertEqual(deliveredIDs, [idsByType["stone"]!, idsByType["grass_block"]!])
        XCTAssertFalse(deliveredIDs.contains(idsByType["dirt"]!))
    }

    func testUnfilteredAttributeChangedSubscriptionNeverMatchesSyntheticPosition() {
        let bus = EventBus()
        _ = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .kind(.player, typeFilter: nil),
            event: .attributeChanged, attribute: nil, createdBy: .player, tick: 0
        )
        var deliveredKeys: [String] = []
        bus.delivery = { event, targets in
            guard !targets.isEmpty, case .string(let key)? = event.payload["key"] else { return }
            deliveredKeys.append(key)
        }
        bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("pos"), "old": .null, "new": .list([.number(1), .number(2), .number(3)])],
            source: .engine, tick: 0, excludeFromRecent: true,
            isSyntheticPositionChange: true
        )
        bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("health"), "old": .null, "new": .number(20)], source: .engine, tick: 0
        )
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(deliveredKeys, ["health"])
    }

    // MARK: - script-owned subscriptions / sorted unload (§7.3, §7.5 step 6)

    func testDropScriptOwnedSubscriptionsRemovesOnlyThoseOwnedByGivenRefs() {
        let bus = EventBus()
        let a = bus.registerScriptOwned(owner: .entity(uid: 1), scriptName: "s", target: .object(.entity(uid: 1)), event: .entitySpawned, attribute: nil)
        let b = bus.registerScriptOwned(owner: .entity(uid: 2), scriptName: "s", target: .object(.entity(uid: 2)), event: .entitySpawned, attribute: nil)
        XCTAssertEqual(bus.scriptOwnedSubscriptionCount, 2)
        bus.dropScriptOwnedSubscriptions(ownedBy: [.entity(uid: 1)])
        XCTAssertEqual(bus.scriptOwnedSubscriptionCount, 1)
        XCTAssertFalse(bus.hasEventInterest(.entitySpawned, subject: .entity(uid: 1)))
        XCTAssertTrue(bus.hasEventInterest(.entitySpawned, subject: .entity(uid: 2)))
        bus.unregisterScriptOwned(id: b.id)
        XCTAssertEqual(bus.scriptOwnedSubscriptionCount, 0)
        _ = a // silence unused-variable warnings for the ids kept only for readability
    }

    func testDropScriptOwnedSubscriptionsForOneScriptPreservesSiblingScripts() {
        let bus = EventBus()
        _ = bus.registerScriptOwned(
            owner: .player, scriptName: "first", target: .object(.player),
            event: .playerJoined, attribute: nil
        )
        _ = bus.registerScriptOwned(
            owner: .player, scriptName: "second", target: .object(.player),
            event: .playerJoined, attribute: nil
        )

        bus.dropScriptOwnedSubscriptions(owner: .player, scriptName: "first")

        XCTAssertEqual(bus.scriptOwnedSubscriptionCount, 1)
        XCTAssertTrue(bus.hasEventInterest(.playerJoined, subject: .player))
        bus.dropScriptOwnedSubscriptions(owner: .player, scriptName: "second")
        XCTAssertEqual(bus.scriptOwnedSubscriptionCount, 0)
        XCTAssertFalse(bus.hasEventInterest(.playerJoined, subject: .player))
    }

    func testCheckedScriptOwnedRegistrationSharesPersistedWorldAndOwnerCaps() {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2_048, maxEventsPerHandler: 256,
            maxQueueSize: 8_192, maxRecentEvents: 128,
            maxSubscriptionsPerWorld: 3, maxSubscriptionsPerObject: 2
        )
        let bus = EventBus(caps: caps)
        XCTAssertTrue(bus.subscribe(
            subscriber: .player, scriptName: "persisted", handler: "h",
            target: .object(.player), event: .playerJoined, attribute: nil,
            createdBy: .player, tick: 0
        ).isSuccessValue)
        let runtimeRegistration = bus.registerScriptOwnedChecked(
            owner: .player, scriptName: "runtime", target: .object(.player),
            event: .playerJoined, attribute: nil
        )
        guard case .success(let runtimeSubscription) = runtimeRegistration else {
            return XCTFail("script-owned registration should fit the combined owner cap")
        }
        guard case .failure(.tooManyForObject) = bus.registerScriptOwnedChecked(
            owner: .player, scriptName: "overflow", target: .object(.player),
            event: .playerJoined, attribute: nil
        ) else { return XCTFail("persisted and runtime subscriptions must share the owner cap") }
        bus.unregisterScriptOwned(id: runtimeSubscription.id)
        XCTAssertTrue(bus.registerScriptOwnedChecked(
            owner: .player, scriptName: "replacement", target: .object(.player),
            event: .playerJoined, attribute: nil
        ).isSuccessValue, "removal must update the indexed owner count")

        XCTAssertTrue(bus.registerScriptOwnedChecked(
            owner: .entity(uid: 1), scriptName: "runtime", target: .any,
            event: .playerJoined, attribute: nil
        ).isSuccessValue)
        guard case .failure(.tooManyForWorld) = bus.subscribe(
            subscriber: .entity(uid: 2), scriptName: "persisted", handler: "h",
            target: .any, event: .playerJoined, attribute: nil,
            createdBy: .player, tick: 0
        ) else { return XCTFail("persisted and runtime subscriptions must share the world cap") }
        XCTAssertEqual(bus.listSubscriptions().count + bus.scriptOwnedSubscriptionCount, 3)
    }

    func testCheckedScriptOwnedRegistrationEnforcesBlockChangeTargetRules() {
        let bus = EventBus()
        guard case .failure(.anyNotAllowedForThisEvent) = bus.registerScriptOwnedChecked(
            owner: .player, scriptName: "s", target: .any,
            event: .blockChanged, attribute: nil
        ) else { return XCTFail("block.changed must reject any") }
        guard case .failure(.targetRequiresTypeFilter) = bus.registerScriptOwnedChecked(
            owner: .player, scriptName: "s", target: .kind(.block, typeFilter: nil),
            event: .blockChanged, attribute: nil
        ) else { return XCTFail("block.changed must require a block type filter") }
        XCTAssertEqual(bus.scriptOwnedSubscriptionCount, 0)
    }

    func testCentralSubscriptionValidationRejectsReservedInapplicableAndMeaninglessFilters() {
        let bus = EventBus()
        guard case .failure(.eventNotAvailable) = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .object(.world),
            event: .unload, attribute: nil, createdBy: .player, tick: 0
        ) else { return XCTFail("reserved events must not create dormant subscriptions") }
        guard case .failure(.eventNotApplicable) = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .object(.player),
            event: .blockToolStrike, attribute: nil, createdBy: .player, tick: 0
        ) else { return XCTFail("a block event must reject a player target") }
        guard case .failure(.attributeFilterNotAllowed) = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .object(.player),
            event: .playerJoined, attribute: "health", createdBy: .player, tick: 0
        ) else { return XCTFail("non-attribute events must reject ignored attribute filters") }
    }

    // MARK: - persistence round-trip

    func testPersistedSubscriptionsRoundTripThroughTheCodec() {
        let bus = EventBus()
        _ = bus.subscribe(
            subscriber: .player, scriptName: "guard", handler: "on_hit", target: .object(.entity(uid: 7)),
            event: .entityDamaged, attribute: nil, createdBy: .player, tick: 3
        )
        _ = bus.subscribe(
            subscriber: .entity(uid: 7), scriptName: "farm", handler: "on_grow",
            target: .kind(.block, typeFilter: "wheat"), event: .blockChanged, attribute: nil,
            createdBy: .ai(model: "test_model"), tick: 4
        )
        let text = bus.encodePersistedSubscriptions()
        let bus2 = EventBus()
        bus2.loadPersistedSubscriptions(from: text, storageCaps: .defaults)
        XCTAssertEqual(bus.listSubscriptions().map(\.id), bus2.listSubscriptions().map(\.id))
        XCTAssertEqual(bus.listSubscriptions().map(\.scriptName), bus2.listSubscriptions().map(\.scriptName))
        XCTAssertEqual(bus.listSubscriptions().map(\.event), bus2.listSubscriptions().map(\.event))
    }

    func testPersistedAttributeFiltersAdmitRegistryBuiltInsAndRejectUnknownSyntax() throws {
        let bus = EventBus()
        let blockFilter = try bus.subscribe(
            subscriber: .player, scriptName: "block_watch", handler: "changed",
            target: .object(.block(dim: .overworld, x: 1, y: 64, z: 1)),
            event: .attributeChanged, attribute: "be.name", createdBy: .player, tick: 1
        ).get()
        let playerFilter = try bus.subscribe(
            subscriber: .player, scriptName: "inventory_watch", handler: "changed",
            target: .object(.player), event: .attributeChanged, attribute: "inventory[0]",
            createdBy: .player, tick: 2
        ).get()
        let camelBuiltIn = try bus.subscribe(
            subscriber: .player, scriptName: "health_watch", handler: "changed",
            target: .object(.player), event: .attributeChanged, attribute: "maxHealth",
            createdBy: .player, tick: 3
        ).get()
        guard case .failure(.invalidAttributeFilter) = bus.subscribe(
            subscriber: .player, scriptName: "bad", handler: "changed",
            target: .object(.player), event: .attributeChanged, attribute: "not.valid[filter]",
            createdBy: .player, tick: 4
        ) else { return XCTFail("unknown punctuation must not cross the persisted filter boundary") }

        let reloaded = EventBus()
        reloaded.loadPersistedSubscriptions(
            from: bus.encodePersistedSubscriptions(), storageCaps: .defaults
        )
        XCTAssertEqual(
            reloaded.listSubscriptions().map(\.id),
            [blockFilter.id, playerFilter.id, camelBuiltIn.id]
        )
        XCTAssertEqual(
            reloaded.listSubscriptions().map(\.attribute),
            ["be.name", "inventory[0]", "max_health"]
        )
    }

    func testLegacyCamelCasePersistedFiltersMigrateWithoutAdmittingHostilePunctuation() {
        let text = """
        {"subs":[
          {"id":1,"who":"player","script":"health","handler":"changed","tgt":"obj:player","ev":"attribute.changed","attr":"maxHealth","by":"player","t":0},
          {"id":2,"who":"player","script":"door","handler":"changed","tgt":"obj:world","ev":"attribute.changed","attr":"doorRef","by":"player","t":0},
          {"id":3,"who":"player","script":"bad","handler":"changed","tgt":"obj:world","ev":"attribute.changed","attr":"not.valid[filter]","by":"player","t":0}
        ],"v":1}
        """
        var diagnostics: [String] = []
        let decoded = SubscriptionRegistryCodec.decode(
            text, caps: .defaults, diagnostic: { diagnostics.append($0) }
        )
        XCTAssertEqual(decoded?.map(\.attribute), ["max_health", "doorref"])
        XCTAssertEqual(diagnostics.count, 1)
        let encoded = SubscriptionRegistryCodec.encode(decoded ?? [])
        XCTAssertTrue(encoded.contains("\"attr\":\"max_health\""))
        XCTAssertTrue(encoded.contains("\"attr\":\"doorref\""))
        XCTAssertFalse(encoded.contains("doorRef"))
    }

    func testCanonicalCustomFilterMatchesLegacyCollapsedKeyInOneSubscriptionSlot() throws {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2_048, maxEventsPerHandler: 256,
            maxQueueSize: 8_192, maxRecentEvents: 128, maxSubscriptionsPerWorld: 1,
            maxSubscriptionsPerObject: 1
        )
        let bus = EventBus(caps: caps)
        let subscription = try bus.subscribe(
            subscriber: .world, scriptName: "watch", handler: "changed",
            target: .object(.world), event: .attributeChanged, attribute: "door_ref",
            createdBy: .player, tick: 0
        ).get()
        XCTAssertEqual(bus.listSubscriptions().count, 1)
        var delivered: [UInt64] = []
        bus.delivery = { _, targets in delivered.append(contentsOf: targets.map(\.id)) }

        bus.raise(
            kind: .attributeChanged, subject: .world,
            payload: ["key": .string("doorref"), "old": .null, "new": .string("legacy")],
            source: .player, tick: 1
        )
        _ = bus.runDeliveryPhase(tick: 1)

        XCTAssertEqual(delivered, [subscription.id])
    }

    func testCanonicalBuiltInFilterNeverFallsThroughToCollapsedCustomKey() throws {
        let bus = EventBus()
        _ = try bus.subscribe(
            subscriber: .world, scriptName: "watch", handler: "changed",
            target: .object(.player), event: .attributeChanged, attribute: "maxHealth",
            createdBy: .player, tick: 0
        ).get()
        var deliveredKeys: [String] = []
        bus.delivery = { event, targets in
            guard !targets.isEmpty, case .string(let key)? = event.payload["key"] else { return }
            deliveredKeys.append(key)
        }
        bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("maxhealth"), "old": .null, "new": .string("custom")],
            source: .player, tick: 1
        )
        bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("max_health"), "old": .number(19), "new": .number(20)],
            source: .engine, tick: 1
        )
        _ = bus.runDeliveryPhase(tick: 1)
        XCTAssertEqual(deliveredKeys, ["max_health"])
    }

    func testOrdinaryCustomPosDoesNotCoalesceWithOrInheritSyntheticPositionPolicy() throws {
        let bus = EventBus()
        let unfiltered = try bus.subscribe(
            subscriber: .world, scriptName: "all", handler: "changed",
            target: .object(.player), event: .attributeChanged, attribute: nil,
            createdBy: .player, tick: 0
        ).get()
        let explicit = try bus.subscribe(
            subscriber: .world, scriptName: "position", handler: "changed",
            target: .object(.player), event: .attributeChanged, attribute: "pos",
            createdBy: .player, tick: 0
        ).get()
        var delivered: [(synthetic: Bool, ids: [UInt64])] = []
        bus.delivery = { event, targets in
            delivered.append((event.isSyntheticPositionChange, targets.map(\.id)))
        }

        bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("pos"), "old": .null, "new": .string("custom")],
            source: .script(owner: .world, name: "writer"), tick: 1
        )
        bus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("pos"), "old": .null, "new": .list([.number(1), .number(2), .number(3)])],
            source: .engine, tick: 1, excludeFromRecent: true,
            isSyntheticPositionChange: true
        )

        XCTAssertEqual(bus.pendingCount, 2, "ordinary and synthetic pos changes are separate lanes")
        _ = bus.runDeliveryPhase(tick: 1)
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered[0].ids, [unfiltered.id, explicit.id])
        XCTAssertFalse(delivered[0].synthetic)
        XCTAssertEqual(delivered[1].ids, [explicit.id])
        XCTAssertTrue(delivered[1].synthetic)
        XCTAssertEqual(bus.recentEvents().count, 1)
        XCTAssertFalse(bus.recentEvents()[0].isSyntheticPositionChange)
    }

    func testLoadPersistedSubscriptionsDropsMalformedEntriesButKeepsGoodOnes() {
        let good = Subscription(
            id: 1, subscriber: .player, scriptName: "s", handler: "h", target: .object(.player),
            event: .playerJoined, attribute: nil, createdBy: .player, createdTick: 0
        )
        let text = """
        {"subs":[\
        {"id":1,"who":"player","script":"s","handler":"h","tgt":"obj:player","ev":"player.joined","by":"player","t":0},\
        {"id":2,"who":"not a ref","script":"s","handler":"h","tgt":"obj:player","ev":"player.joined","by":"player","t":0}\
        ],"v":1}
        """
        let bus = EventBus()
        var diagnostics: [String] = []
        bus.loadPersistedSubscriptions(from: text, storageCaps: .defaults) { diagnostics.append($0) }
        XCTAssertEqual(bus.listSubscriptions().map(\.id), [good.id])
        XCTAssertFalse(diagnostics.isEmpty)
    }

    func testPersistedSubscriptionRejectsCoercedFloatingPointIdentifiers() throws {
        let text = """
        {"subs":[
        {"id":1e100,"who":"player","script":"s","handler":"h","tgt":"obj:player","ev":"player.joined","by":"player","t":0},
        {"id":2,"who":"player","script":"s","handler":"h2","tgt":"obj:player","ev":"player.joined","by":"player","t":1.5}
        ],"v":1}
        """
        let bus = EventBus()
        var diagnostics: [String] = []
        bus.loadPersistedSubscriptions(from: text, storageCaps: .defaults) {
            diagnostics.append($0)
        }
        XCTAssertTrue(bus.listSubscriptions().isEmpty)
        XCTAssertEqual(diagnostics.count, 2)

        let next = try bus.subscribe(
            subscriber: .player, scriptName: "clean", handler: "h",
            target: .object(.player), event: .playerJoined, attribute: nil,
            createdBy: .player, tick: 0
        ).get()
        XCTAssertEqual(next.id, 1, "malformed saved numbers must not poison the live id allocator")
    }

    func testPersistedSubscriptionAllocatorWrapsInsideItsStrictCodecDomain() throws {
        let maximum = Int64.max
        let text = """
        {"subs":[
        {"id":\(maximum),"who":"player","script":"old","handler":"h","tgt":"obj:player","ev":"player.joined","by":"player","t":0}
        ],"v":1}
        """
        let bus = EventBus()
        bus.loadPersistedSubscriptions(from: text, storageCaps: .defaults)
        let next = try bus.subscribe(
            subscriber: .world, scriptName: "new", handler: "h",
            target: .object(.player), event: .playerJoined, attribute: nil,
            createdBy: .player, tick: 1
        ).get()
        XCTAssertEqual(next.id, 1)

        let reloaded = EventBus()
        reloaded.loadPersistedSubscriptions(
            from: bus.encodePersistedSubscriptions(), storageCaps: .defaults
        )
        XCTAssertEqual(reloaded.listSubscriptions().map(\.id), [1, UInt64(maximum)])
    }

    func testPersistedSubscriptionLoadReappliesRuntimeCapsTargetsAndNaturalKeys() throws {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 32, maxEventsPerHandler: 16,
            maxQueueSize: 32, maxRecentEvents: 32, maxSubscriptionsPerWorld: 3,
            maxSubscriptionsPerObject: 2
        )
        func sub(
            _ id: UInt64, _ subscriber: ObjectRef, _ handler: String,
            target: SubscriptionTarget = .object(.player), event: EventKind = .playerJoined,
            attribute: String? = nil
        ) -> Subscription {
            Subscription(
                id: id, subscriber: subscriber, scriptName: "s", handler: handler,
                target: target, event: event, attribute: attribute,
                createdBy: .player, createdTick: 0
            )
        }
        let duplicate = sub(2, .player, "h1")
        let text = SubscriptionRegistryCodec.encode([
            sub(1, .player, "h1"), duplicate, sub(3, .player, "h2"),
            sub(4, .player, "h3"), sub(5, .entity(uid: 1), "h1"),
            sub(6, .world, "h1"),
            sub(7, .world, "bad", target: .any, event: .attributeChanged),
        ])
        let bus = EventBus(caps: caps)
        var diagnostics: [String] = []
        bus.loadPersistedSubscriptions(from: text, storageCaps: .defaults) {
            diagnostics.append($0)
        }
        XCTAssertEqual(bus.listSubscriptions().map(\.id), [1, 3, 5])
        XCTAssertGreaterThanOrEqual(diagnostics.count, 4)
        XCTAssertTrue(bus.unsubscribe(id: 5))
        let next = try bus.subscribe(
            subscriber: .world, scriptName: "s", handler: "replacement",
            target: .object(.player), event: .playerJoined, attribute: nil,
            createdBy: .player, tick: 1
        ).get()
        XCTAssertEqual(next.id, 6, "dropped hostile ids must not create gaps in the live id space")
    }

    func testEncodeOmitsAttributeKeyWhenNil() {
        let bus = EventBus()
        _ = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .object(.player), event: .playerJoined,
            attribute: nil, createdBy: .player, tick: 0
        )
        let text = bus.encodePersistedSubscriptions()
        XCTAssertFalse(text.contains("\"attr\""))
    }

    // MARK: - recent events / zero-subscription fast path

    func testRecentEventsRingRespectsCapAndExcludesFlaggedEvents() {
        let caps = EventBus.Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2_048, maxEventsPerHandler: 256, maxQueueSize: 8_192,
            maxRecentEvents: 3, maxSubscriptionsPerWorld: 512, maxSubscriptionsPerObject: 32
        )
        let bus = EventBus(caps: caps)
        for i in 0..<5 {
            bus.raise(kind: .entitySpawned, subject: .entity(uid: i), source: .engine, tick: 0)
        }
        bus.raise(kind: .attributeChanged, subject: .player, payload: ["key": .string("pos")], source: .engine, tick: 0, excludeFromRecent: true)
        XCTAssertEqual(bus.recentEvents().count, 3)
        XCTAssertFalse(bus.recentEvents().contains { $0.kind == .attributeChanged })
    }

    func testHasAnySubscriptionAndAttributeChangedInterestQueries() {
        let bus = EventBus()
        XCTAssertFalse(bus.hasAnySubscription)
        XCTAssertFalse(bus.hasAttributeChangedInterest(in: .player))
        _ = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .object(.player), event: .attributeChanged,
            attribute: "mood", createdBy: .player, tick: 0
        )
        XCTAssertTrue(bus.hasAnySubscription)
        XCTAssertTrue(bus.hasAttributeChangedInterest(in: .player))
        XCTAssertFalse(bus.hasAttributeChangedInterest(in: .entity(uid: 1)))
    }

    func testAttributeInterestHonorsEntityTypeFilterBeforeDiffing() {
        let bus = EventBus()
        _ = bus.subscribe(
            subscriber: .player, scriptName: "watch", handler: "changed",
            target: .kind(.entity, typeFilter: "zombie"), event: .attributeChanged,
            attribute: "health", createdBy: .player, tick: 0
        )
        XCTAssertTrue(bus.hasAttributeChangedInterest(in: .entity(uid: 1), subjectType: "zombie"))
        XCTAssertFalse(bus.hasAttributeChangedInterest(in: .entity(uid: 2), subjectType: "cow"))
    }

    // MARK: - the pre-filtered block-changed funnel (§6.6 point 2)

    func testRecordBlockChangeIsANoOpWithoutARecordOrTypeFilterInterest() {
        let bus = EventBus()
        var delivered = 0
        bus.delivery = { _, _ in delivered += 1 }
        let stoneCell = Int(cell(bid("stone"))), dirtCell = Int(cell(bid("dirt")))
        bus.recordBlockChange(dim: .overworld, x: 0, y: 0, z: 0, oldCell: stoneCell, newCell: dirtCell, hasObjectRecord: false, tick: 0)
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(bus.pendingCount, 0)
    }

    func testRecordBlockChangeFiresWhenAnObjectRecordExists() {
        let bus = EventBus()
        var delivered = 0
        bus.delivery = { _, _ in delivered += 1 }
        let stoneCell = Int(cell(bid("stone"))), dirtCell = Int(cell(bid("dirt")))
        bus.recordBlockChange(dim: .overworld, x: 0, y: 0, z: 0, oldCell: stoneCell, newCell: dirtCell, hasObjectRecord: true, tick: 0)
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered, 1)
    }

    func testRecordBlockChangeFiresWhenATypeFilterSubscriptionMatches() {
        let bus = EventBus()
        _ = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .kind(.block, typeFilter: "dirt"),
            event: .blockChanged, attribute: nil, createdBy: .player, tick: 0
        )
        var delivered = 0
        bus.delivery = { _, _ in delivered += 1 }
        let stoneCell = Int(cell(bid("stone"))), dirtCell = Int(cell(bid("dirt")))
        bus.recordBlockChange(dim: .overworld, x: 0, y: 0, z: 0, oldCell: stoneCell, newCell: dirtCell, hasObjectRecord: false, tick: 0)
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered, 1)
    }

    func testRecordBlockChangeMatchesTheOldBlockTypeEndpoint() {
        let bus = EventBus()
        _ = bus.subscribe(
            subscriber: .player,
            scriptName: "old_stone",
            handler: "changed",
            target: .kind(.block, typeFilter: "stone"),
            event: .blockChanged,
            attribute: nil,
            createdBy: .player,
            tick: 0
        )
        var delivered = 0
        bus.delivery = { _, targets in delivered += targets.count }
        bus.recordBlockChange(
            dim: .overworld, x: 0, y: 0, z: 0,
            oldCell: Int(cell(bid("stone"))), newCell: Int(cell(bid("dirt"))),
            hasObjectRecord: false, tick: 0
        )
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered, 1, "stone -> dirt must notify both old- and new-family filters")
    }

    func testCoalescedBlockChangeMatchesOnlyOriginalAndFinalTypeEndpoints() throws {
        let bus = EventBus()
        var idsByType: [String: UInt64] = [:]
        for type in ["stone", "dirt", "grass_block"] {
            guard case .success(let subscription) = bus.subscribe(
                subscriber: .player,
                scriptName: type,
                handler: "changed",
                target: .kind(.block, typeFilter: type),
                event: .blockChanged,
                attribute: nil,
                createdBy: .player,
                tick: 0
            ) else { return XCTFail("subscription failed for \(type)") }
            idsByType[type] = subscription.id
        }
        var deliveredIDs = Set<UInt64>()
        bus.delivery = { _, targets in deliveredIDs.formUnion(targets.map(\.id)) }
        bus.recordBlockChange(
            dim: .overworld, x: 1, y: 2, z: 3,
            oldCell: Int(cell(bid("stone"))), newCell: Int(cell(bid("dirt"))),
            hasObjectRecord: false, tick: 0
        )
        bus.recordBlockChange(
            dim: .overworld, x: 1, y: 2, z: 3,
            oldCell: Int(cell(bid("dirt"))), newCell: Int(cell(bid("grass_block"))),
            hasObjectRecord: false, tick: 0
        )
        bus.runDeliveryPhase(tick: 0)

        XCTAssertEqual(deliveredIDs, [idsByType["stone"]!, idsByType["grass_block"]!])
        XCTAssertFalse(deliveredIDs.contains(idsByType["dirt"]!), "coalesced intermediate B is intentionally absent")
    }

    func testRecordBlockChangeFiresForAnExactObjectSubscriptionWithoutARecord() {
        let bus = EventBus()
        let subject = ObjectRef.block(dim: .overworld, x: 3, y: 4, z: 5)
        _ = bus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .object(subject),
            event: .blockChanged, attribute: nil, createdBy: .player, tick: 0
        )
        var captured: (ScriptEvent, [EventDeliveryTarget])?
        bus.delivery = { captured = ($0, $1) }
        bus.recordBlockChange(
            dim: .overworld, x: 3, y: 4, z: 5,
            oldCell: Int(cell(bid("stone"))), newCell: Int(cell(bid("dirt"))),
            hasObjectRecord: false, tick: 0
        )
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(captured?.0.kind, .blockChanged)
        XCTAssertEqual(captured?.0.subject, subject)
        XCTAssertEqual(captured?.1.count, 1)
    }

    func testScriptOwnedInterestIndexTracksRegistrationAndRemoval() {
        let bus = EventBus()
        let sub = bus.registerScriptOwned(
            owner: .player, scriptName: "s", target: .object(.player),
            event: .playerLeveled, attribute: nil
        )
        XCTAssertTrue(bus.hasEventInterest(.playerLeveled, subject: .player))
        bus.unregisterScriptOwned(id: sub.id)
        XCTAssertFalse(bus.hasEventInterest(.playerLeveled, subject: .player))
    }

    func testRecordBlockChangeIgnoresANoOpIDChange() {
        let bus = EventBus()
        var delivered = 0
        bus.delivery = { _, _ in delivered += 1 }
        let stoneCell = Int(cell(bid("stone")))
        bus.recordBlockChange(dim: .overworld, x: 0, y: 0, z: 0, oldCell: stoneCell, newCell: stoneCell, hasObjectRecord: true, tick: 0)
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered, 0)
    }

    func testRecordBlockChangePublishesMetadataOnlyChangesWithExactValues() {
        let bus = EventBus()
        let subject = ObjectRef.block(dim: .overworld, x: 2, y: 3, z: 4)
        _ = bus.subscribe(
            subscriber: .player, scriptName: "meta", handler: "changed",
            target: .object(subject), event: .blockChanged,
            attribute: nil, createdBy: .player, tick: 0
        )
        var captured: ScriptEvent?
        bus.delivery = { event, _ in captured = event }
        let id = Int(bid("stone"))
        bus.recordBlockChange(
            dim: .overworld, x: 2, y: 3, z: 4,
            oldCell: (id << 4) | 1, newCell: (id << 4) | 7,
            hasObjectRecord: false, source: .player, tick: 0
        )
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(captured?.payload["oldMeta"], .int(1))
        XCTAssertEqual(captured?.payload["newMeta"], .int(7))
        XCTAssertEqual(captured?.source, .player)
    }
}

private extension Result {
    var isSuccessValue: Bool {
        if case .success = self { return true }
        return false
    }
}
