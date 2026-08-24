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
        var kinds: [EventKind] = []
        bus.delivery = { event, _ in kinds.append(event.kind) }
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(kinds.filter { $0 == .scriptOverBudget }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == .entitySpawned }.count, 4)
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

    func testUnfilteredAttributeChangedSubscriptionNeverMatchesPosition() {
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
            source: .engine, tick: 0, excludeFromRecent: true
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
        let a = bus.registerScriptOwned(owner: .entity(uid: 1), scriptName: "s", target: .any, event: .entitySpawned, attribute: nil)
        let b = bus.registerScriptOwned(owner: .entity(uid: 2), scriptName: "s", target: .any, event: .entitySpawned, attribute: nil)
        XCTAssertEqual(bus.scriptOwnedSubscriptionCount, 2)
        bus.dropScriptOwnedSubscriptions(ownedBy: [.entity(uid: 1)])
        XCTAssertEqual(bus.scriptOwnedSubscriptionCount, 1)
        bus.unregisterScriptOwned(id: b.id)
        XCTAssertEqual(bus.scriptOwnedSubscriptionCount, 0)
        _ = a // silence unused-variable warnings for the ids kept only for readability
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

    // MARK: - the pre-filtered block-changed funnel (§6.6 point 2)

    func testRecordBlockChangeIsANoOpWithoutARecordOrTypeFilterInterest() {
        let bus = EventBus()
        var delivered = 0
        bus.delivery = { _, _ in delivered += 1 }
        let stoneID = Int(bid("stone")), dirtID = Int(bid("dirt"))
        bus.recordBlockChange(dim: .overworld, x: 0, y: 0, z: 0, oldId: stoneID, newId: dirtID, hasObjectRecord: false, tick: 0)
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(bus.pendingCount, 0)
    }

    func testRecordBlockChangeFiresWhenAnObjectRecordExists() {
        let bus = EventBus()
        var delivered = 0
        bus.delivery = { _, _ in delivered += 1 }
        let stoneID = Int(bid("stone")), dirtID = Int(bid("dirt"))
        bus.recordBlockChange(dim: .overworld, x: 0, y: 0, z: 0, oldId: stoneID, newId: dirtID, hasObjectRecord: true, tick: 0)
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
        let stoneID = Int(bid("stone")), dirtID = Int(bid("dirt"))
        bus.recordBlockChange(dim: .overworld, x: 0, y: 0, z: 0, oldId: stoneID, newId: dirtID, hasObjectRecord: false, tick: 0)
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered, 1)
    }

    func testRecordBlockChangeIgnoresANoOpIDChange() {
        let bus = EventBus()
        var delivered = 0
        bus.delivery = { _, _ in delivered += 1 }
        let stoneID = Int(bid("stone"))
        bus.recordBlockChange(dim: .overworld, x: 0, y: 0, z: 0, oldId: stoneID, newId: stoneID, hasObjectRecord: true, tick: 0)
        bus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered, 0)
    }
}

private extension Result {
    var isSuccessValue: Bool {
        if case .success = self { return true }
        return false
    }
}
