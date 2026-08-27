// EventBus.swift — event-bus (change 1b). design.md §7. The engine behind
// §7.1-§7.6: raises typed events from the engine funnels, matches them
// against persisted + script-owned subscriptions, delivers them in
// deterministic order, and enforces the coalescing/cascade/queue caps. No
// Lua anywhere in this class — script execution is 1c; `delivery` is the
// seam 1c plugs a real handler dispatcher into (nil here means "no handler
// runtime yet", not "broken"). One `EventBus` per open world, owned by
// `GameScriptingState` (session-scoped, reset every `enterWorld`).

import Foundation

/// One recipient of a delivered event — either a persisted subscription or a
/// (1c) script-owned one. `EventBus` never invokes anything itself; it hands
/// the caller (`delivery`) the ordered list and gets out of the way.
public struct EventDeliveryTarget {
    public enum Kind {
        case persisted(Subscription)
        /// `ScriptOwnedSubscription` carries an `AnyObject?` token (the future
        /// Lua closure identity) — deliberately not `Sendable` (the package
        /// runs in Swift language mode 5; the game loop is single-threaded).
        case scriptOwned(ScriptOwnedSubscription)
    }
    public let kind: Kind

    public var id: UInt64 {
        switch kind {
        case .persisted(let s): return s.id
        case .scriptOwned(let s): return s.id
        }
    }
}

/// Allocation-bounded canonical payload sizing for EventBus retention. It mirrors
/// `AttrValueCodec.encode`'s byte grammar, but stops as soon as the caller's limit is crossed and
/// rejects hostile container shapes before sorting or walking them. Engine producers may use
/// strings larger than the persistent-attribute string cap (for example `ai.replied`), so the
/// event-level byte ceiling is authoritative while the persistent list/map/depth/node/key caps
/// still bound traversal work.
private enum EventPayloadSizer {
    static func measure(_ payload: [String: AttrValue], limit: Int) -> Int? {
        let shape = ScriptingStorageCaps.defaults
        guard limit >= 0, payload.count <= shape.value.mapKeys else { return nil }
        var counter = Counter(limit: limit, shape: shape, nodes: 1)
        guard counter.add(1) else { return nil } // {
        for (index, key) in payload.keys.sorted(by: utf8Less).enumerated() {
            guard boundedUTF8Count(key, limit: shape.maxMapKeyBytes) != nil else { return nil }
            if index > 0, !counter.add(1) { return nil } // ,
            guard counter.addEncodedString(key), counter.add(1), // :
                  let value = payload[key], counter.addValue(value, depth: 1)
            else { return nil }
        }
        guard counter.add(1) else { return nil } // }
        return counter.bytes
    }

    private struct Counter {
        let limit: Int
        let shape: ScriptingStorageCaps
        var bytes = 0
        var nodes: Int

        mutating func add(_ amount: Int) -> Bool {
            guard amount >= 0, bytes <= limit, amount <= limit - bytes else { return false }
            bytes += amount
            return true
        }

        mutating func chargeNode(depth: Int) -> Bool {
            guard depth <= shape.value.depth, nodes < shape.value.nodes else { return false }
            nodes += 1
            return true
        }

        mutating func addValue(_ value: AttrValue, depth: Int) -> Bool {
            guard chargeNode(depth: depth) else { return false }
            switch value {
            case .null:
                return add(4)
            case .bool(let value):
                return add(value ? 4 : 5)
            case .int(let value):
                return add(String(value).utf8.count)
            case .number(let value):
                guard value.isFinite else { return false }
                let normalized = value == 0 ? 0.0 : value
                return add(normalized.description.utf8.count)
            case .string(let value):
                return addEncodedString(value)
            case .list(let values):
                guard values.count <= shape.value.listElements, add(1) else { return false }
                for (index, value) in values.enumerated() {
                    if index > 0, !add(1) { return false }
                    if !addValue(value, depth: depth + 1) { return false }
                }
                return add(1)
            case .map(let values):
                guard values.count <= shape.value.mapKeys, add(1) else { return false }
                for (index, key) in values.keys.sorted(by: utf8Less).enumerated() {
                    guard boundedUTF8Count(key, limit: shape.maxMapKeyBytes) != nil else {
                        return false
                    }
                    if index > 0, !add(1) { return false }
                    guard addEncodedString(key), add(1),
                          let value = values[key], addValue(value, depth: depth + 1)
                    else { return false }
                }
                return add(1)
            case .ref(let value):
                return add(8) && addEncodedString(value) && add(1)
            }
        }

        mutating func addEncodedString(_ value: String) -> Bool {
            guard add(1) else { return false }
            for scalar in value.unicodeScalars {
                let amount: Int
                switch scalar {
                case "\"", "\\", "\u{08}", "\u{0C}", "\n", "\r", "\t":
                    amount = 2
                default:
                    if scalar.value < 0x20 {
                        amount = 6
                    } else if scalar.value <= 0x7F {
                        amount = 1
                    } else if scalar.value <= 0x7FF {
                        amount = 2
                    } else if scalar.value <= 0xFFFF {
                        amount = 3
                    } else {
                        amount = 4
                    }
                }
                guard add(amount) else { return false }
            }
            return add(1)
        }
    }

    private static func boundedUTF8Count(_ value: String, limit: Int) -> Int? {
        guard limit >= 0 else { return nil }
        var count = 0
        for _ in value.utf8 {
            guard count < limit else { return nil }
            count += 1
        }
        return count
    }
}

extension EventBus.RaiseOutcome {
    public var wasEnqueued: Bool {
        switch self {
        case .enqueued, .coalesced: return true
        default: return false
        }
    }
}

public final class EventBus {
    /// Precomputed attribute interest for one live subject. Subscription mutation rebuilds the
    /// bounded index; the simulation hot path combines at most four exact/kind keys, so observing
    /// one entity never scans the world's subscription list.
    public struct AttributeObservation: Equatable {
        public var observesAll = false
        public var names: Set<String> = []

        public var isEmpty: Bool { !observesAll && names.isEmpty }
        public func observes(_ name: String) -> Bool { observesAll || names.contains(name) }
        /// Position's synthetic `pos` event intentionally requires a named filter; an unfiltered
        /// `attribute.changed` subscription excludes that flagged event even though ordinary
        /// custom attributes (including a custom `pos`) remain observable.
        public func explicitlyObserves(_ name: String) -> Bool { names.contains(name) }

        mutating func formUnion(_ other: AttributeObservation) {
            observesAll = observesAll || other.observesAll
            names.formUnion(other.names)
        }
    }

    public struct Caps: Sendable, Equatable {
        /// §7.6: "the phase keeps draining up to cascade depth 8".
        public var cascadeDepth: Int
        /// §7.6: "2,048 deliveries per tick".
        public var maxDeliveriesPerTick: Int
        /// §7.6: "one handler may enqueue ≤ 256 events" — enforced while
        /// `withHandlerContext` is active (1c wraps one handler invocation
        /// per call).
        public var maxEventsPerHandler: Int
        /// §7.6: "the queue holds ≤ 8,192".
        public var maxQueueSize: Int
        /// Not in the design's numbered caps — a bound for `/events recent`'s
        /// backing ring so the debug feed itself can never grow unbounded.
        public var maxRecentEvents: Int
        /// Maximum canonical payload bytes retained by one event. This is checked without first
        /// materializing an encoded copy of the payload.
        public var maxEventPayloadBytes: Int
        /// Aggregate canonical payload bytes retained by the pending queue, an in-progress
        /// delivery cursor, and the one deferred over-budget diagnostic.
        public var maxPendingPayloadBytes: Int
        /// Aggregate canonical payload bytes retained by `/events recent`.
        public var maxRecentPayloadBytes: Int
        /// §7.3: "≤ 512 per world".
        public var maxSubscriptionsPerWorld: Int
        /// §7.3: "≤ 32 per object".
        public var maxSubscriptionsPerObject: Int

        public init(
            cascadeDepth: Int, maxDeliveriesPerTick: Int, maxEventsPerHandler: Int,
            maxQueueSize: Int, maxRecentEvents: Int, maxSubscriptionsPerWorld: Int,
            maxSubscriptionsPerObject: Int,
            maxEventPayloadBytes: Int = 16_384,
            maxPendingPayloadBytes: Int = 4_194_304,
            maxRecentPayloadBytes: Int = 524_288
        ) {
            self.cascadeDepth = cascadeDepth
            self.maxDeliveriesPerTick = maxDeliveriesPerTick
            self.maxEventsPerHandler = maxEventsPerHandler
            self.maxQueueSize = maxQueueSize
            self.maxRecentEvents = maxRecentEvents
            self.maxEventPayloadBytes = maxEventPayloadBytes
            self.maxPendingPayloadBytes = maxPendingPayloadBytes
            self.maxRecentPayloadBytes = maxRecentPayloadBytes
            self.maxSubscriptionsPerWorld = maxSubscriptionsPerWorld
            self.maxSubscriptionsPerObject = maxSubscriptionsPerObject
        }

        public static let defaults = Caps(
            cascadeDepth: 8, maxDeliveriesPerTick: 2_048, maxEventsPerHandler: 256,
            maxQueueSize: 8_192, maxRecentEvents: 128, maxSubscriptionsPerWorld: 512,
            maxSubscriptionsPerObject: 32
        )
    }

    public enum RaiseOutcome: Equatable {
        case enqueued(seq: UInt64)
        case coalesced(intoSeq: UInt64)
        case droppedCascadeDepth
        case droppedQueueFull
        case droppedHandlerBudget
    }

    public enum SubscribeError: Error, Equatable {
        case tooManyForWorld
        case tooManyForObject
        /// A `.kind(.block, nil)` target on `block.changed`/`attribute.changed`
        /// (§7.3: a type filter is required), or an `.any` target on
        /// `block.changed`/`attribute.changed` (§7.3: "`.any` for causal
        /// events only").
        case targetRequiresTypeFilter
        case anyNotAllowedForThisEvent
        case attributeFilterNotAllowed
        case invalidAttributeFilter
        case eventNotApplicable
        case eventNotAvailable
    }

    public struct PhaseReport: Equatable {
        public var delivered = 0
        public var carriedOver = 0
        public var droppedForCascadeDepth = 0
        public var droppedForQueueFull = 0
        public var droppedForHandlerBudget = 0
    }

    public let caps: Caps

    private var nextSeq: UInt64 = 0
    /// Always append-only / prefix-removed (including on coalesce, which
    /// removes the stale entry and re-appends) — always sorted by `seq`
    /// without needing an explicit sort.
    /// Sparse FIFO storage plus an index for coalescable keys. Tombstoning a superseded event and
    /// advancing `pendingHead` avoids `Array.removeFirst`/middle removal, which made a legal
    /// 8,192-event burst quadratic. Periodic compaction is amortized and deterministic.
    /// The byte count is the canonical encoded payload size. Keeping it beside the event makes
    /// every ownership transfer explicit and avoids recomputing or losing accounting when a
    /// pending entry moves into a delivery cursor or deferred diagnostic slot.
    private struct BufferedEvent {
        var event: ScriptEvent
        var payloadBytes: Int
    }
    private var pending: [BufferedEvent?] = []
    private var pendingHead = 0
    private var pendingEventCount = 0
    private var pendingCoalescingIndex: [String: Int] = [:]
    private var pendingPayloadByteCount = 0
    /// A recipient list can span ticks when the per-tick delivery budget is smaller than the
    /// number of matching subscriptions. The snapshot preserves ascending subscription order and
    /// prevents already-run recipients from being invoked again on the next tick.
    private struct DeliveryCursor {
        var buffered: BufferedEvent
        var recipients: [EventDeliveryTarget]
        var nextRecipient: Int

        var event: ScriptEvent { buffered.event }
    }
    private var deliveryCursor: DeliveryCursor?
    private var recent: [BufferedEvent] = []
    private var recentPayloadByteCount = 0

    private var persistedSubs: [Subscription] = []
    private var scriptOwnedSubs: [ScriptOwnedSubscription] = []
    /// Subscription mutation is rare and capped; event delivery and observable-diff checks are
    /// hot. Appends update these indexes directly; removals and persistence loads rebuild them so
    /// those paths never scan subscriptions for unrelated event kinds. `subscriptionInterest`
    /// also makes exact-object admission checks (notably `block.changed`) constant-time.
    private var persistedSubsByEvent: [EventKind: [Subscription]] = [:]
    private var scriptOwnedSubsByEvent: [EventKind: [ScriptOwnedSubscription]] = [:]
    private struct InterestKey: Hashable {
        let event: EventKind
        let target: SubscriptionTarget
    }
    private var subscriptionInterest: Set<InterestKey> = []
    private var attributeInterestByTarget: [SubscriptionTarget: AttributeObservation] = [:]
    private var subscriptionCountByOwner: [ObjectRef: Int] = [:]
    /// One shared id space across persisted and script-owned subscriptions
    /// (design.md §7.4: "persisted and script-owned subscriptions in
    /// ascending id" — a single, unambiguous ascending order).
    private var nextSubscriptionID: UInt64 = 1

    private var handlerContextActive = false
    private var handlerEventCount = 0
    private var activeHandlerCause: ScriptEvent?
    private var overBudgetSignalTick: Int64?
    /// A full queue cannot admit its own over-budget diagnostic without violating the queue cap.
    /// Keep at most one diagnostic out of band and admit it before later work as soon as a slot
    /// opens. Additional full-queue ticks remain visible in the bounded recent-event ring but do
    /// not grow another hidden queue.
    private var deferredOverBudgetEvent: BufferedEvent?
    private var droppedCascadeSinceLastPhase = 0
    private var droppedQueueSinceLastPhase = 0
    private var droppedHandlerSinceLastPhase = 0

    /// The 1c seam: called once per delivered event during
    /// `runDeliveryPhase`, in `(event.seq, recipient.id)` order. `nil` (this
    /// change's default) means "record and drain, but nothing is listening
    /// yet" — the zero-scripts-runtime state, not an error.
    public var delivery: ((ScriptEvent, [EventDeliveryTarget]) -> Void)?
    /// Optional backpressure seam evaluated before recipients are advanced. A runtime with no
    /// remaining global instruction tokens returns zero, leaving the exact recipient cursor for
    /// the next tick. Returning a prefix count preserves strict subscription order and guarantees
    /// that EventBus never reports or discards a handler it did not actually admit.
    public var deliveryAdmission: ((ScriptEvent, [EventDeliveryTarget]) -> Int)?

    public init(caps: Caps = .defaults) {
        self.caps = caps
    }

    /// Ordinary producers leave a small byte slot for the bus's sole deferred diagnostic. Without
    /// this reservation, hitting the aggregate cap could make the cap violation itself invisible
    /// to subscribers until unrelated payloads drained.
    private var ordinaryPendingPayloadLimit: Int {
        let aggregate = max(0, caps.maxPendingPayloadBytes)
        let diagnosticReserve = min(aggregate, min(max(0, caps.maxEventPayloadBytes), 512))
        return aggregate - diagnosticReserve
    }

    private func pendingPayloadFits(adding: Int, removing: Int = 0, limit: Int) -> Bool {
        guard adding >= 0, removing >= 0, removing <= pendingPayloadByteCount else { return false }
        let retained = pendingPayloadByteCount - removing
        let boundedLimit = max(0, limit)
        guard retained <= boundedLimit else { return false }
        return adding <= boundedLimit - retained
    }

    private func releasePendingPayload(_ bytes: Int) {
        precondition(bytes >= 0 && bytes <= pendingPayloadByteCount, "EventBus payload accounting underflow")
        pendingPayloadByteCount -= bytes
    }

    // MARK: - raise (funnels, commands, and — via `causedBy` — 1c cascades)

    /// Raises one event. `causedBy` is the event currently being delivered,
    /// if any (1c wraps a handler's raises so cascades are attributed
    /// correctly); every funnel/command/AI-tool raise in this change passes
    /// `nil` (top-level, depth 0). `subjectType` is the subject's family name
    /// at raise time (a block's registry name, an entity's `type`) — required
    /// for a `.kind(_, typeFilter)` subscription to ever match; omit for
    /// world/dimension/player subjects, which have no type concept.
    /// `excludeFromRecent` is set only for the quantized-position diff
    /// (§6.6: "position is excluded from... `recent_events`").
    @discardableResult
    public func raise(
        kind: EventKind, subject: ObjectRef, payload: [String: AttrValue] = [:],
        source: EventSource, tick: Int64, causedBy: ScriptEvent? = nil,
        subjectType: String? = nil, priorSubjectType: String? = nil,
        excludeFromRecent: Bool = false, isSyntheticPositionChange: Bool = false
    ) -> RaiseOutcome {
        admitDeferredOverBudgetIfPossible()
        let effectiveCause = causedBy ?? activeHandlerCause
        let depth = (effectiveCause?.cascadeDepth ?? -1) + 1
        guard depth <= caps.cascadeDepth else {
            droppedCascadeSinceLastPhase += 1
            signalOverBudget(reason: "cascade depth exceeded", tick: tick)
            return .droppedCascadeDepth
        }
        if handlerContextActive {
            handlerEventCount += 1
            guard handlerEventCount <= caps.maxEventsPerHandler else {
                droppedHandlerSinceLastPhase += 1
                signalOverBudget(reason: "handler event budget exceeded", tick: tick)
                return .droppedHandlerBudget
            }
        }

        guard let incomingPayloadBytes = EventPayloadSizer.measure(
            payload, limit: max(0, caps.maxEventPayloadBytes)
        ) else {
            droppedQueueSinceLastPhase += 1
            signalOverBudget(
                reason: "event payload exceeds the \(max(0, caps.maxEventPayloadBytes))-byte limit",
                tick: tick
            )
            return .droppedQueueFull
        }

        if kind.isCoalescable, let key = coalescingKey(
            kind: kind, subject: subject, payload: payload,
            isSyntheticPositionChange: isSyntheticPositionChange
        ) {
            if let existing = pendingEvent(coalescingKey: key) {
                let mergedPayload = mergeCoalescedPayload(
                    kind: kind, old: existing.event.payload, new: payload
                )
                guard let mergedPayloadBytes = EventPayloadSizer.measure(
                    mergedPayload, limit: max(0, caps.maxEventPayloadBytes)
                ) else {
                    droppedQueueSinceLastPhase += 1
                    signalOverBudget(
                        reason: "coalesced event payload exceeds the \(max(0, caps.maxEventPayloadBytes))-byte limit",
                        tick: tick
                    )
                    return .droppedQueueFull
                }
                guard pendingPayloadFits(
                    adding: mergedPayloadBytes, removing: existing.payloadBytes,
                    limit: ordinaryPendingPayloadLimit
                ) else {
                    droppedQueueSinceLastPhase += 1
                    signalOverBudget(reason: "event payload queue is full", tick: tick)
                    return .droppedQueueFull
                }
                let seq = nextSeq
                nextSeq += 1
                let merged = ScriptEvent(
                    seq: seq, tick: tick, kind: kind, subject: subject,
                    payload: mergedPayload,
                    source: source, cascadeDepth: depth,
                    subjectType: subjectType ?? existing.event.subjectType,
                    priorSubjectType: existing.event.priorSubjectType ?? existing.event.subjectType
                        ?? priorSubjectType,
                    isSyntheticPositionChange: isSyntheticPositionChange
                )
                guard removePendingEvent(coalescingKey: key) != nil else { return .droppedQueueFull }
                let buffered = BufferedEvent(event: merged, payloadBytes: mergedPayloadBytes)
                appendPending(buffered)
                appendRecent(buffered, excludeFromRecent: excludeFromRecent)
                return .coalesced(intoSeq: seq)
            }
        }

        let queuedEventCount = pendingEventCount + (deliveryCursor == nil ? 0 : 1)
        guard queuedEventCount < caps.maxQueueSize else {
            droppedQueueSinceLastPhase += 1
            signalOverBudget(reason: "event queue full", tick: tick)
            return .droppedQueueFull
        }
        guard pendingPayloadFits(
            adding: incomingPayloadBytes, limit: ordinaryPendingPayloadLimit
        ) else {
            droppedQueueSinceLastPhase += 1
            signalOverBudget(reason: "event payload queue is full", tick: tick)
            return .droppedQueueFull
        }
        let seq = nextSeq
        nextSeq += 1
        let event = ScriptEvent(
            seq: seq, tick: tick, kind: kind, subject: subject, payload: payload,
            source: source, cascadeDepth: depth, subjectType: subjectType,
            priorSubjectType: priorSubjectType,
            isSyntheticPositionChange: isSyntheticPositionChange
        )
        let buffered = BufferedEvent(event: event, payloadBytes: incomingPayloadBytes)
        appendPending(buffered)
        appendRecent(buffered, excludeFromRecent: excludeFromRecent)
        return .enqueued(seq: seq)
    }

    /// Wraps one handler invocation (1c) so §7.6's per-handler event budget
    /// applies only to raises caused by that specific invocation. Re-entrant:
    /// a nested call restores the outer counter on exit.
    public func withHandlerContext<T>(
        causedBy: ScriptEvent? = nil, _ body: () throws -> T
    ) rethrows -> T {
        var eventCount = 0
        return try withHandlerContext(causedBy: causedBy, eventCount: &eventCount, body)
    }

    /// Resumes an already-yielded logical handler without resetting its event budget. The caller
    /// stores the updated count alongside the coroutine before the next suspension.
    public func withHandlerContext<T>(
        causedBy: ScriptEvent? = nil, eventCount: inout Int, _ body: () throws -> T
    ) rethrows -> T {
        let previousActive = handlerContextActive
        let previousCount = handlerEventCount
        let previousCause = activeHandlerCause
        handlerContextActive = true
        handlerEventCount = eventCount
        if let causedBy { activeHandlerCause = causedBy }
        defer {
            eventCount = handlerEventCount
            handlerContextActive = previousActive
            handlerEventCount = previousCount
            activeHandlerCause = previousCause
        }
        return try body()
    }

    private func coalescingKey(
        kind: EventKind, subject: ObjectRef, payload: [String: AttrValue],
        isSyntheticPositionChange: Bool
    ) -> String? {
        switch kind {
        case .attributeChanged:
            guard case .string(let key)? = payload["key"] else { return nil }
            let lane = isSyntheticPositionChange ? "position" : "ordinary"
            return "attr:\(subject.canonical):\(key):\(lane)"
        case .blockChanged:
            return "block:\(subject.canonical)"
        default:
            return nil
        }
    }

    /// §7.6: "keeps the first `old`, the last `new` and the last `seq`" —
    /// generalized over both payload shapes (`attribute.changed`'s
    /// `old`/`new`; `block.changed`'s `oldName`/`newName` +
    /// `oldMeta`/`newMeta`). `new` (the incoming payload) already has every
    /// "last" field; only the "first" fields need restoring from `old`.
    private func mergeCoalescedPayload(
        kind: EventKind, old: [String: AttrValue], new: [String: AttrValue]
    ) -> [String: AttrValue] {
        var merged = new
        let firstFields = kind == .attributeChanged ? ["old"] : ["oldName", "oldMeta"]
        for field in firstFields where old[field] != nil {
            merged[field] = old[field]
        }
        return merged
    }

    public func signalOverBudget(reason: String, tick: Int64) {
        guard overBudgetSignalTick != tick else { return }
        overBudgetSignalTick = tick
        admitDeferredOverBudgetIfPossible()
        let seq = nextSeq
        let message = truncateUTF8(ScriptingDisplayText.line(reason), toByteCount: 128)
        let event = ScriptEvent(
            seq: seq, tick: tick, kind: .scriptOverBudget, subject: .world,
            payload: ["message": .string(message)], source: .engine, cascadeDepth: 0
        )
        guard let payloadBytes = EventPayloadSizer.measure(
            event.payload, limit: max(0, caps.maxEventPayloadBytes)
        ) else { return }
        nextSeq += 1
        let buffered = BufferedEvent(event: event, payloadBytes: payloadBytes)
        appendRecent(buffered, excludeFromRecent: false)
        let queuedEventCount = pendingEventCount + (deliveryCursor == nil ? 0 : 1)
        if queuedEventCount < caps.maxQueueSize,
           pendingPayloadFits(adding: payloadBytes, limit: max(0, caps.maxPendingPayloadBytes)) {
            appendPending(buffered)
        } else if deferredOverBudgetEvent == nil,
                  pendingPayloadFits(adding: payloadBytes, limit: max(0, caps.maxPendingPayloadBytes)) {
            deferredOverBudgetEvent = buffered
            pendingPayloadByteCount += payloadBytes
        }
    }

    private func admitDeferredOverBudgetIfPossible() {
        guard let buffered = deferredOverBudgetEvent else { return }
        let queuedEventCount = pendingEventCount + (deliveryCursor == nil ? 0 : 1)
        guard queuedEventCount < caps.maxQueueSize else { return }
        deferredOverBudgetEvent = nil
        appendPending(buffered, alreadyAccounted: true)
    }

    private func appendRecent(_ buffered: BufferedEvent, excludeFromRecent: Bool) {
        guard !excludeFromRecent else { return }
        recent.append(buffered)
        recentPayloadByteCount += buffered.payloadBytes
        let eventLimit = max(0, caps.maxRecentEvents)
        let byteLimit = max(0, caps.maxRecentPayloadBytes)
        while !recent.isEmpty,
              recent.count > eventLimit || recentPayloadByteCount > byteLimit {
            let evicted = recent.removeFirst()
            recentPayloadByteCount -= evicted.payloadBytes
        }
    }

    /// `/events recent` (§12). Most-recent last (append order); `limit` (if
    /// given) keeps the most-recent `limit` entries.
    public func recentEvents(limit: Int? = nil) -> [ScriptEvent] {
        let events = recent.map(\.event)
        guard let limit else { return events }
        let boundedLimit = max(0, limit)
        guard boundedLimit < events.count else { return events }
        return Array(events.suffix(boundedLimit))
    }

    /// The current pending (undelivered) queue depth — test/diagnostic use.
    public var pendingCount: Int { pendingEventCount + (deliveryCursor == nil ? 0 : 1) }

    /// Canonical payload bytes retained by pending entries, the current delivery cursor, and the
    /// optional deferred over-budget diagnostic. Exposed for diagnostics and invariant tests.
    public var pendingPayloadBytes: Int { pendingPayloadByteCount }

    /// Canonical payload bytes retained by the bounded recent-event feed.
    public var recentPayloadBytes: Int { recentPayloadByteCount }

    // MARK: - persisted subscriptions (`/on`, `/unsubscribe`, phase 2 AI tool)

    @discardableResult
    public func subscribe(
        subscriber: ObjectRef, scriptName: String, handler: String, target: SubscriptionTarget,
        event: EventKind, attribute: String?, createdBy: Provenance.Author, tick: Int64
    ) -> Result<Subscription, SubscribeError> {
        let canonicalAttribute: String?
        if let attribute {
            guard let canonical = canonicalEventBusAttributeFilter(
                attribute, target: target
            ) else { return .failure(.invalidAttributeFilter) }
            canonicalAttribute = canonical
        } else {
            canonicalAttribute = nil
        }
        if let targetError = validateSubscriptionTarget(
            target, event: event, attribute: canonicalAttribute
        ) { return .failure(targetError) }
        let key = Subscription.NaturalKey(
            subscriber: subscriber, scriptName: scriptName, handler: handler,
            target: target, event: event, attribute: canonicalAttribute
        )
        if let existing = persistedSubs.first(where: { $0.naturalKey == key }) {
            return .success(existing) // upsert of an identical key is a no-op (§7.3: idempotent)
        }
        let perObjectCount = subscriptionCountByOwner[subscriber, default: 0]
        guard perObjectCount < caps.maxSubscriptionsPerObject else { return .failure(.tooManyForObject) }
        guard persistedSubs.count + scriptOwnedSubs.count < caps.maxSubscriptionsPerWorld else {
            return .failure(.tooManyForWorld)
        }
        let sub = Subscription(
            id: allocateSubscriptionID(), subscriber: subscriber, scriptName: scriptName, handler: handler,
            target: target, event: event, attribute: canonicalAttribute, createdBy: createdBy, createdTick: tick
        )
        persistedSubs.append(sub)
        indexPersistedSubscription(sub)
        return .success(sub)
    }

    @discardableResult
    public func unsubscribe(id: UInt64) -> Bool {
        guard let idx = persistedSubs.firstIndex(where: { $0.id == id }) else { return false }
        persistedSubs.remove(at: idx)
        rebuildSubscriptionIndexes()
        return true
    }

    /// Ownership-scoped deletion for an untrusted caller such as a LAN guest. A missing id and an
    /// id belonging to another subscriber are intentionally indistinguishable to the caller.
    @discardableResult
    public func unsubscribe(id: UInt64, ownedBy subscriber: ObjectRef) -> Bool {
        guard let idx = persistedSubs.firstIndex(where: {
            $0.id == id && $0.subscriber == subscriber
        }) else { return false }
        persistedSubs.remove(at: idx)
        rebuildSubscriptionIndexes()
        return true
    }

    /// Sorted by id (§7.4's own delivery order — also a stable, deterministic
    /// listing order for `/events subscriptions`-style output).
    public func listSubscriptions(for ref: ObjectRef? = nil) -> [Subscription] {
        let filtered = ref.map { r in persistedSubs.filter { $0.subscriber == r } } ?? persistedSubs
        return filtered.sorted { $0.id < $1.id }
    }

    public func subscription(id: UInt64) -> Subscription? {
        persistedSubs.first { $0.id == id }
    }

    // MARK: - persistence (WorldRecord.scriptRegistry)

    /// Replaces the in-memory persisted-subscription set from a decoded
    /// world record (`enterWorld`). A malformed registry (whole-document
    /// refusal) is treated as "no subscriptions", exactly like
    /// `ObjectRecordCodec`'s own contract — the world still loads.
    public func loadPersistedSubscriptions(
        from text: String, storageCaps: ScriptingStorageCaps, diagnostic: (String) -> Void = { _ in }
    ) {
        guard let subs = SubscriptionRegistryCodec.decode(text, caps: storageCaps, diagnostic: diagnostic) else {
            diagnostic("dropped corrupt subscription registry")
            persistedSubs = []
            rebuildSubscriptionIndexes()
            nextSubscriptionID = 1
            return
        }
        // A save is untrusted input. Re-apply every runtime admission invariant instead of
        // assuming the codec's structural validation implies a safe subscription registry.
        // Lowest ids win deterministically when a crafted document contains duplicate natural
        // keys or exceeds a cap.
        var admitted: [Subscription] = []
        var seenNaturalKeys = Set<Subscription.NaturalKey>()
        var countByOwner: [ObjectRef: Int] = [:]
        for sub in scriptOwnedSubs {
            countByOwner[sub.owner, default: 0] += 1
        }
        for sub in subs.sorted(by: { $0.id < $1.id }) {
            guard validateSubscriptionTarget(
                sub.target, event: sub.event, attribute: sub.attribute
            ) == nil else {
                diagnostic("dropped persisted subscription with a forbidden target")
                continue
            }
            guard seenNaturalKeys.insert(sub.naturalKey).inserted else {
                diagnostic("dropped duplicate persisted subscription")
                continue
            }
            guard admitted.count + scriptOwnedSubs.count < caps.maxSubscriptionsPerWorld else {
                diagnostic("dropped persisted subscription beyond the world limit")
                continue
            }
            guard countByOwner[sub.subscriber, default: 0] < caps.maxSubscriptionsPerObject else {
                diagnostic("dropped persisted subscription beyond the object limit")
                continue
            }
            admitted.append(sub)
            countByOwner[sub.subscriber, default: 0] += 1
        }
        persistedSubs = admitted
        rebuildSubscriptionIndexes()
        let maxExisting = max(admitted.map(\.id).max() ?? 0, scriptOwnedSubs.map(\.id).max() ?? 0)
        nextSubscriptionID = identifierSuccessor(maxExisting)
    }

    /// World shutdown cannot leave a lifecycle event behind an arbitrary gameplay backlog. The
    /// caller may discard that already-doomed backlog immediately before raising `player.left`;
    /// the recent-event ring remains intact for diagnostics.
    func discardPendingForShutdownLifecycleEvent() {
        pending.removeAll(keepingCapacity: false)
        pendingHead = 0
        pendingEventCount = 0
        pendingCoalescingIndex.removeAll(keepingCapacity: false)
        deliveryCursor = nil
        deferredOverBudgetEvent = nil
        pendingPayloadByteCount = 0
    }

    /// Encodes the persisted-subscription set for `WorldRecord.scriptRegistry`
    /// (empty when there are none — the caller omits the key entirely, like
    /// `objects`).
    public func encodePersistedSubscriptions() -> String {
        SubscriptionRegistryCodec.encode(persistedSubs)
    }

    public var hasPersistedSubscriptions: Bool { !persistedSubs.isEmpty }

    // MARK: - script-owned subscriptions (1c populates `token`; this change
    // only owns the shape and the load/unload bookkeeping)

    /// Checked registration used by the Lua runtime. Persisted and script-owned subscriptions
    /// share the same world and owning-object limits: otherwise a script could grow both storage
    /// and the delivery indexes without bound by repeatedly calling `on`/`subscribe`.
    @discardableResult
    public func registerScriptOwnedChecked(
        owner: ObjectRef, scriptName: String, target: SubscriptionTarget, event: EventKind,
        attribute: String?, token: AnyObject? = nil
    ) -> Result<ScriptOwnedSubscription, SubscribeError> {
        let canonicalAttribute: String?
        if let attribute {
            guard let canonical = canonicalEventBusAttributeFilter(
                attribute, target: target
            ) else { return .failure(.invalidAttributeFilter) }
            canonicalAttribute = canonical
        } else {
            canonicalAttribute = nil
        }
        if let targetError = validateSubscriptionTarget(
            target, event: event, attribute: canonicalAttribute
        ) { return .failure(targetError) }
        let perObjectCount = subscriptionCountByOwner[owner, default: 0]
        guard perObjectCount < caps.maxSubscriptionsPerObject else { return .failure(.tooManyForObject) }
        guard persistedSubs.count + scriptOwnedSubs.count < caps.maxSubscriptionsPerWorld else {
            return .failure(.tooManyForWorld)
        }
        let sub = ScriptOwnedSubscription(
            id: allocateSubscriptionID(), owner: owner, scriptName: scriptName, target: target,
            event: event, attribute: canonicalAttribute, token: token
        )
        scriptOwnedSubs.append(sub)
        indexScriptOwnedSubscription(sub)
        return .success(sub)
    }

    /// Convenience for bounded engine tests and setup code that register a known-small number of
    /// subscriptions. Runtime/user-controlled paths must use `registerScriptOwnedChecked` and
    /// surface the refusal rather than trapping.
    @discardableResult
    public func registerScriptOwned(
        owner: ObjectRef, scriptName: String, target: SubscriptionTarget, event: EventKind,
        attribute: String?, token: AnyObject? = nil
    ) -> ScriptOwnedSubscription {
        switch registerScriptOwnedChecked(
            owner: owner, scriptName: scriptName, target: target, event: event,
            attribute: attribute, token: token
        ) {
        case .success(let sub): return sub
        case .failure(let error):
            preconditionFailure("bounded script-owned subscription setup failed: \(error)")
        }
    }

    public func unregisterScriptOwned(id: UInt64) {
        scriptOwnedSubs.removeAll { $0.id == id }
        rebuildSubscriptionIndexes()
    }

    /// §7.3 "dropped at unload" / §7.5 step 6: bulk-drops every script-owned
    /// subscription rooted at any of `refs`. This function is a pure filter —
    /// the caller owns computing (and sorting) `refs`; dropping in any order
    /// produces the same resulting set, so no sort happens here.
    public func dropScriptOwnedSubscriptions(ownedBy refs: [ObjectRef]) {
        guard !refs.isEmpty, !scriptOwnedSubs.isEmpty else { return }
        let refSet = Set(refs)
        scriptOwnedSubs.removeAll { refSet.contains($0.owner) }
        rebuildSubscriptionIndexes()
    }

    /// Drops only the transient subscriptions installed by one attached script. Script edits,
    /// disables, detaches, and failed module loads use this narrower form so another script on the
    /// same object keeps its independently registered handlers.
    public func dropScriptOwnedSubscriptions(owner: ObjectRef, scriptName: String) {
        guard !scriptOwnedSubs.isEmpty else { return }
        let previousCount = scriptOwnedSubs.count
        scriptOwnedSubs.removeAll { $0.owner == owner && $0.scriptName == scriptName }
        if scriptOwnedSubs.count != previousCount { rebuildSubscriptionIndexes() }
    }

    public var scriptOwnedSubscriptionCount: Int { scriptOwnedSubs.count }

    // MARK: - the pre-filtered block-changed funnel (§6.6 point 2)

    /// Called from `GameCore.hookWorld`'s extended `onBlockChanged` for every
    /// non-silent block write. Decodes/raises only when the change is
    /// actually observable — the cell already carries an `ObjectRecord`, or a
    /// exact-object subscription names this cell, or a block-kind subscription
    /// matches the old or new block's family name — otherwise this is an O(1)
    /// no-op (the zero-scripts fast path §15 asks for).
    public func recordBlockChange(
        dim: Dim, x: Int, y: Int, z: Int, oldCell: Int, newCell: Int,
        hasObjectRecord: Bool, source: EventSource = .engine, tick: Int64
    ) {
        guard oldCell != newCell else { return }
        let oldId = oldCell >> 4
        let newId = newCell >> 4
        guard oldId >= 0, oldId < blockDefs.count, newId >= 0, newId < blockDefs.count else { return }
        let oldName = blockDefs[oldId].name
        let newName = blockDefs[newId].name
        let subject = ObjectRef.block(dim: dim, x: x, y: y, z: z)
        guard hasObjectRecord || blockChangeHasInterest(subject: subject, oldName: oldName, newName: newName) else { return }
        raise(
            kind: .blockChanged, subject: subject,
            payload: [
                "oldName": .string(oldName), "newName": .string(newName),
                "oldMeta": .int(Int64(oldCell & 15)), "newMeta": .int(Int64(newCell & 15)),
            ],
            source: source, tick: tick, subjectType: newName
        )
    }

    private func blockChangeHasInterest(subject: ObjectRef, oldName: String, newName: String) -> Bool {
        let event = EventKind.blockChanged
        return subscriptionInterest.contains(InterestKey(event: event, target: .object(subject)))
            || subscriptionInterest.contains(InterestKey(event: event, target: .any))
            || subscriptionInterest.contains(InterestKey(event: event, target: .kind(.block, typeFilter: nil)))
            || subscriptionInterest.contains(InterestKey(event: event, target: .kind(.block, typeFilter: oldName)))
            || subscriptionInterest.contains(InterestKey(event: event, target: .kind(.block, typeFilter: newName)))
    }

    // MARK: - subscription-interest queries (phase-diff zero-cost gate)

    public var hasAnySubscription: Bool { !persistedSubs.isEmpty || !scriptOwnedSubs.isEmpty }

    /// Whether *any* subscription could possibly match an `attribute.changed`
    /// on `ref` — a conservative (type-filter-blind) pre-check the phase diff
    /// uses to skip diffing an unobserved object entirely (§6.6: "only
    /// observed objects pay"). Correctness of the actual delivery still comes
    /// from `matches` at delivery time.
    public func hasAttributeChangedInterest(
        in ref: ObjectRef, subjectType: String? = nil
    ) -> Bool {
        !attributeObservation(in: ref, subjectType: subjectType).isEmpty
    }

    /// Exact named/all-fields interest merged with applicable kind filters in O(1) index lookups.
    public func attributeObservation(
        in ref: ObjectRef, subjectType: String? = nil
    ) -> AttributeObservation {
        var result = attributeInterestByTarget[.object(ref)] ?? AttributeObservation()
        result.formUnion(attributeInterestByTarget[.kind(ref.kind, typeFilter: nil)] ?? AttributeObservation())
        result.formUnion(attributeInterestByTarget[.any] ?? AttributeObservation())
        if let subjectType {
            result.formUnion(
                attributeInterestByTarget[.kind(ref.kind, typeFilter: subjectType)] ?? AttributeObservation()
            )
        }
        return result
    }

    /// Exact block refs are the only blocks the phase diff polls for dynamic light/block-entity
    /// fields. Cell-state mutations for exact and kind-filtered blocks use the World.setBlock hook.
    public func exactAttributeObservedObjects(of kind: ObjectKind) -> [ObjectRef] {
        attributeInterestByTarget.keys.compactMap { target -> ObjectRef? in
            guard case .object(let ref) = target, ref.kind == kind else { return nil }
            return ref
        }.sorted { utf8Less($0.canonical, $1.canonical) }
    }

    /// Whether a semantic producer for `event` can reach at least one subscription on `subject`.
    /// This is an exact target check (including a type filter when supplied), used to avoid
    /// piggybacking semantic events such as `player.leveled` on unrelated attribute interest.
    public func hasEventInterest(_ event: EventKind, subject: ObjectRef, subjectType: String? = nil) -> Bool {
        if subscriptionInterest.contains(InterestKey(event: event, target: .object(subject)))
            || subscriptionInterest.contains(InterestKey(event: event, target: .kind(subject.kind, typeFilter: nil)))
            || subscriptionInterest.contains(InterestKey(event: event, target: .any)) {
            return true
        }
        guard let subjectType else { return false }
        return subscriptionInterest.contains(
            InterestKey(event: event, target: .kind(subject.kind, typeFilter: subjectType))
        )
    }

    // MARK: - delivery (§7.4/§7.5 step 5, §7.6)

    /// Drains `pending` in `seq` and recipient-id order, up to
    /// `caps.maxDeliveriesPerTick` actual recipient invocations. An event with no recipients is
    /// still surfaced once to the diagnostic seam and drained without consuming a handler slot.
    /// If one event crosses the limit, `deliveryCursor` retains only its not-yet-run recipient
    /// suffix; no handler is replayed on the next tick. The event is removed from `pending` before
    /// callbacks run, so a handler raising the same coalescable event cannot mutate the batch being
    /// iterated. Cascades append normally and are drained in the same tick while budget remains.
    @discardableResult
    public func runDeliveryPhase(tick: Int64) -> PhaseReport {
        var report = PhaseReport()
        report.droppedForCascadeDepth = droppedCascadeSinceLastPhase
        report.droppedForQueueFull = droppedQueueSinceLastPhase
        report.droppedForHandlerBudget = droppedHandlerSinceLastPhase
        droppedCascadeSinceLastPhase = 0
        droppedQueueSinceLastPhase = 0
        droppedHandlerSinceLastPhase = 0
        admitDeferredOverBudgetIfPossible()
        guard deliveryCursor != nil || pendingEventCount > 0 else { return report }
        var totalDelivered = 0
        var workUnits = 0
        while workUnits < caps.maxDeliveriesPerTick {
            if deliveryCursor == nil {
                guard let buffered = popFirstPending() else { break }
                let targets = recipients(for: buffered.event)
                if targets.isEmpty {
                    delivery?(buffered.event, [])
                    workUnits += 1
                    releasePendingPayload(buffered.payloadBytes)
                    admitDeferredOverBudgetIfPossible()
                    continue
                }
                deliveryCursor = DeliveryCursor(
                    buffered: buffered, recipients: targets, nextRecipient: 0
                )
            }
            guard var cursor = deliveryCursor else { continue }
            let available = caps.maxDeliveriesPerTick - workUnits
            let end = min(cursor.recipients.count, cursor.nextRecipient + available)
            let proposed = Array(cursor.recipients[cursor.nextRecipient..<end])
            let admitted = min(
                proposed.count,
                max(0, deliveryAdmission?(cursor.event, proposed) ?? proposed.count)
            )
            guard admitted > 0 else { break }
            let slice = Array(proposed.prefix(admitted))
            delivery?(cursor.event, slice)
            totalDelivered += slice.count
            workUnits += slice.count
            cursor.nextRecipient += slice.count
            if cursor.nextRecipient == cursor.recipients.count {
                deliveryCursor = nil
                releasePendingPayload(cursor.buffered.payloadBytes)
                admitDeferredOverBudgetIfPossible()
            } else {
                deliveryCursor = cursor
            }
        }
        report.delivered = totalDelivered
        report.carriedOver = pendingEventCount + (deliveryCursor == nil ? 0 : 1)
        return report
    }

    private func appendPending(_ buffered: BufferedEvent, alreadyAccounted: Bool = false) {
        let index = pending.count
        pending.append(buffered)
        pendingEventCount += 1
        if !alreadyAccounted { pendingPayloadByteCount += buffered.payloadBytes }
        let event = buffered.event
        if event.kind.isCoalescable,
           let key = coalescingKey(
               kind: event.kind, subject: event.subject, payload: event.payload,
               isSyntheticPositionChange: event.isSyntheticPositionChange
           ) {
            pendingCoalescingIndex[key] = index
        }
        compactPendingStorageIfNeeded()
    }

    /// The combined subscription cap bounds this search to at most 513 probes. Wrapping skips
    /// zero and occupied ids instead of relying on trapping `UInt64` increment semantics.
    private func allocateSubscriptionID() -> UInt64 {
        let occupied = Set(persistedSubs.map(\.id) + scriptOwnedSubs.map(\.id))
        var candidate = nextSubscriptionID == 0 ? 1 : nextSubscriptionID
        while occupied.contains(candidate) {
            candidate = identifierSuccessor(candidate)
        }
        nextSubscriptionID = identifierSuccessor(candidate)
        return candidate
    }

    private func identifierSuccessor(_ id: UInt64) -> UInt64 {
        scriptingRegistryIdentifierSuccessor(id)
    }

    private func pendingEvent(coalescingKey key: String) -> BufferedEvent? {
        guard let index = pendingCoalescingIndex[key],
              index >= pendingHead, index < pending.count else { return nil }
        return pending[index]
    }

    private func removePendingEvent(coalescingKey key: String) -> BufferedEvent? {
        guard let index = pendingCoalescingIndex.removeValue(forKey: key),
              index >= pendingHead, index < pending.count,
              let buffered = pending[index] else { return nil }
        pending[index] = nil
        pendingEventCount -= 1
        releasePendingPayload(buffered.payloadBytes)
        return buffered
    }

    /// Transfers (rather than releases) payload ownership from the sparse queue into the caller,
    /// which immediately either delivers it or stores it in `deliveryCursor`.
    private func popFirstPending() -> BufferedEvent? {
        while pendingHead < pending.count {
            let index = pendingHead
            pendingHead += 1
            guard let buffered = pending[index] else { continue }
            pending[index] = nil
            pendingEventCount -= 1
            let event = buffered.event
            if let key = coalescingKey(
                kind: event.kind, subject: event.subject, payload: event.payload,
                isSyntheticPositionChange: event.isSyntheticPositionChange
            ), pendingCoalescingIndex[key] == index {
                pendingCoalescingIndex.removeValue(forKey: key)
            }
            compactPendingStorageIfNeeded()
            return buffered
        }
        compactPendingStorageIfNeeded(force: true)
        return nil
    }

    private func compactPendingStorageIfNeeded(force: Bool = false) {
        if pendingEventCount == 0 {
            pending.removeAll(keepingCapacity: true)
            pendingHead = 0
            pendingCoalescingIndex.removeAll(keepingCapacity: true)
            return
        }
        let retainedSlots = pending.count - pendingHead
        let excessivelySparse = retainedSlots > caps.maxQueueSize
            && retainedSlots > max(1_024, pendingEventCount * 2)
        guard force || pendingHead >= 1_024 && pendingHead * 2 >= pending.count
                || excessivelySparse else { return }
        let events = pending[pendingHead...].compactMap { $0 }
        pending = events.map(Optional.some)
        pendingHead = 0
        pendingCoalescingIndex.removeAll(keepingCapacity: true)
        for (index, buffered) in events.enumerated() where buffered.event.kind.isCoalescable {
            let event = buffered.event
            if let key = coalescingKey(
                kind: event.kind, subject: event.subject, payload: event.payload,
                isSyntheticPositionChange: event.isSyntheticPositionChange
            ) {
                pendingCoalescingIndex[key] = index
            }
        }
    }

    /// §7.4: "(1) the subject's own scripts in `(createdTick, name)` order,
    /// (2) persisted and script-owned subscriptions in ascending id." Step
    /// (1) is always empty in this change (script records are 1c) — the
    /// ordering contract is already correct for 1c to plug scripts into
    /// without touching this function.
    private func recipients(for event: ScriptEvent) -> [EventDeliveryTarget] {
        let attributeKey: String?
        if event.kind == .attributeChanged, case .string(let key)? = event.payload["key"] {
            attributeKey = key
        } else {
            attributeKey = nil
        }
        var targets: [EventDeliveryTarget] = []
        for sub in persistedSubsByEvent[event.kind, default: []]
            where matches(sub.target, attribute: sub.attribute, subject: event.subject,
                       attributeKey: attributeKey, subjectType: event.subjectType,
                       priorSubjectType: event.priorSubjectType,
                       kind: event.kind, payload: event.payload,
                       isSyntheticPositionChange: event.isSyntheticPositionChange) {
            targets.append(EventDeliveryTarget(kind: .persisted(sub)))
        }
        for sub in scriptOwnedSubsByEvent[event.kind, default: []]
            where matches(sub.target, attribute: sub.attribute, subject: event.subject,
                       attributeKey: attributeKey, subjectType: event.subjectType,
                       priorSubjectType: event.priorSubjectType,
                       kind: event.kind, payload: event.payload,
                       isSyntheticPositionChange: event.isSyntheticPositionChange) {
            targets.append(EventDeliveryTarget(kind: .scriptOwned(sub)))
        }
        targets.sort { $0.id < $1.id }
        return targets
    }

    private func rebuildSubscriptionIndexes() {
        persistedSubsByEvent = Dictionary(grouping: persistedSubs, by: \.event)
        scriptOwnedSubsByEvent = Dictionary(grouping: scriptOwnedSubs, by: \.event)
        subscriptionInterest.removeAll(keepingCapacity: true)
        attributeInterestByTarget.removeAll(keepingCapacity: true)
        subscriptionCountByOwner.removeAll(keepingCapacity: true)
        for sub in persistedSubs {
            subscriptionCountByOwner[sub.subscriber, default: 0] += 1
            indexInterest(event: sub.event, target: sub.target, attribute: sub.attribute)
        }
        for sub in scriptOwnedSubs {
            subscriptionCountByOwner[sub.owner, default: 0] += 1
            indexInterest(event: sub.event, target: sub.target, attribute: sub.attribute)
        }
    }

    private func indexPersistedSubscription(_ sub: Subscription) {
        persistedSubsByEvent[sub.event, default: []].append(sub)
        subscriptionCountByOwner[sub.subscriber, default: 0] += 1
        indexInterest(event: sub.event, target: sub.target, attribute: sub.attribute)
    }

    private func indexScriptOwnedSubscription(_ sub: ScriptOwnedSubscription) {
        scriptOwnedSubsByEvent[sub.event, default: []].append(sub)
        subscriptionCountByOwner[sub.owner, default: 0] += 1
        indexInterest(event: sub.event, target: sub.target, attribute: sub.attribute)
    }

    private func indexInterest(event: EventKind, target: SubscriptionTarget, attribute: String?) {
        subscriptionInterest.insert(InterestKey(event: event, target: target))
        guard event == .attributeChanged else { return }
        var observation = attributeInterestByTarget[target] ?? AttributeObservation()
        if let attribute { observation.names.insert(attribute) }
        else { observation.observesAll = true }
        attributeInterestByTarget[target] = observation
    }

    static func validateSubscriptionShape(
        _ target: SubscriptionTarget, event: EventKind, attribute: String?
    ) -> SubscribeError? {
        if attribute != nil, event != .attributeChanged { return .attributeFilterNotAllowed }
        if let attribute,
           canonicalEventBusAttributeFilter(attribute, target: target) == nil {
            return .invalidAttributeFilter
        }
        if let descriptor = EventDescriptorRegistry.descriptor(for: event) {
            guard descriptor.availability.isCompletable else { return .eventNotAvailable }
            switch target {
            case .object(let ref) where !descriptor.subjectKinds.contains(ref.kind):
                return .eventNotApplicable
            case .kind(let kind, _) where !descriptor.subjectKinds.contains(kind):
                return .eventNotApplicable
            default:
                break
            }
        }
        if case .kind(.block, let filter) = target, filter == nil, event.requiresBlockTypeFilter {
            return .targetRequiresTypeFilter
        }
        if target == .any, event.requiresBlockTypeFilter {
            // requiresBlockTypeFilter is exactly {attribute.changed,
            // blockChanged} — §7.3's ".any for causal events only".
            return .anyNotAllowedForThisEvent
        }
        return nil
    }

    private func validateSubscriptionTarget(
        _ target: SubscriptionTarget, event: EventKind, attribute: String?
    ) -> SubscribeError? {
        Self.validateSubscriptionShape(target, event: event, attribute: attribute)
    }

    private func matches(
        _ target: SubscriptionTarget, attribute: String?, subject: ObjectRef,
        attributeKey: String?, subjectType: String?, priorSubjectType: String?, kind: EventKind,
        payload: [String: AttrValue], isSyntheticPositionChange: Bool
    ) -> Bool {
        if kind == .attributeChanged {
            if let attribute {
                guard let attributeKey,
                      attributeFilterMatches(attribute, eventKey: attributeKey, target: target)
                else { return false }
            } else if isSyntheticPositionChange {
                // §6.6: flagged synthetic position is excluded from attribute-less subscriptions.
                return false
            }
        }
        switch target {
        case .object(let ref): return ref == subject
        case .kind(let k, let filter):
            guard k == subject.kind else { return false }
            guard let filter else { return true }
            if kind == .blockChanged {
                let oldName: String? = if case .string(let value)? = payload["oldName"] {
                    value
                } else {
                    nil
                }
                let newName: String? = if case .string(let value)? = payload["newName"] {
                    value
                } else {
                    nil
                }
                // A coalesced A -> B -> C change intentionally exposes only endpoints: the
                // original family and final family match; transient B is collapsed with its event.
                return filter == oldName || filter == newName
            }
            if kind == .attributeChanged, subject.kind == .block {
                return filter == priorSubjectType || filter == subjectType
            }
            return subjectType == filter
        case .any: return true
        }
    }
}
