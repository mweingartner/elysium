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

extension EventBus.RaiseOutcome {
    public var wasEnqueued: Bool {
        switch self {
        case .enqueued, .coalesced: return true
        default: return false
        }
    }
}

public final class EventBus {
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
        /// §7.3: "≤ 512 per world".
        public var maxSubscriptionsPerWorld: Int
        /// §7.3: "≤ 32 per object".
        public var maxSubscriptionsPerObject: Int

        public init(
            cascadeDepth: Int, maxDeliveriesPerTick: Int, maxEventsPerHandler: Int,
            maxQueueSize: Int, maxRecentEvents: Int, maxSubscriptionsPerWorld: Int,
            maxSubscriptionsPerObject: Int
        ) {
            self.cascadeDepth = cascadeDepth
            self.maxDeliveriesPerTick = maxDeliveriesPerTick
            self.maxEventsPerHandler = maxEventsPerHandler
            self.maxQueueSize = maxQueueSize
            self.maxRecentEvents = maxRecentEvents
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
    private var pending: [ScriptEvent] = []
    private var recent: [ScriptEvent] = []

    private var persistedSubs: [Subscription] = []
    private var scriptOwnedSubs: [ScriptOwnedSubscription] = []
    /// One shared id space across persisted and script-owned subscriptions
    /// (design.md §7.4: "persisted and script-owned subscriptions in
    /// ascending id" — a single, unambiguous ascending order).
    private var nextSubscriptionID: UInt64 = 1

    private var handlerContextActive = false
    private var handlerEventCount = 0
    private var overBudgetSignaledThisTick = false

    /// The 1c seam: called once per delivered event during
    /// `runDeliveryPhase`, in `(event.seq, recipient.id)` order. `nil` (this
    /// change's default) means "record and drain, but nothing is listening
    /// yet" — the zero-scripts-runtime state, not an error.
    public var delivery: ((ScriptEvent, [EventDeliveryTarget]) -> Void)?

    public init(caps: Caps = .defaults) {
        self.caps = caps
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
        subjectType: String? = nil, excludeFromRecent: Bool = false
    ) -> RaiseOutcome {
        let depth = (causedBy?.cascadeDepth ?? -1) + 1
        guard depth <= caps.cascadeDepth else {
            raiseOverBudgetOnce(reason: "cascade depth exceeded", tick: tick)
            return .droppedCascadeDepth
        }
        if handlerContextActive {
            handlerEventCount += 1
            guard handlerEventCount <= caps.maxEventsPerHandler else {
                raiseOverBudgetOnce(reason: "handler event budget exceeded", tick: tick)
                return .droppedHandlerBudget
            }
        }

        if kind.isCoalescable, let key = coalescingKey(kind: kind, subject: subject, payload: payload) {
            if let idx = pending.firstIndex(where: {
                $0.kind == kind && coalescingKey(kind: $0.kind, subject: $0.subject, payload: $0.payload) == key
            }) {
                let existing = pending.remove(at: idx)
                let seq = nextSeq
                nextSeq += 1
                let merged = ScriptEvent(
                    seq: seq, tick: tick, kind: kind, subject: subject,
                    payload: mergeCoalescedPayload(kind: kind, old: existing.payload, new: payload),
                    source: source, cascadeDepth: depth, subjectType: subjectType ?? existing.subjectType
                )
                pending.append(merged)
                appendRecent(merged, excludeFromRecent: excludeFromRecent)
                return .coalesced(intoSeq: seq)
            }
        }

        guard pending.count < caps.maxQueueSize else {
            raiseOverBudgetOnce(reason: "event queue full", tick: tick)
            return .droppedQueueFull
        }
        let seq = nextSeq
        nextSeq += 1
        let event = ScriptEvent(
            seq: seq, tick: tick, kind: kind, subject: subject, payload: payload,
            source: source, cascadeDepth: depth, subjectType: subjectType
        )
        pending.append(event)
        appendRecent(event, excludeFromRecent: excludeFromRecent)
        return .enqueued(seq: seq)
    }

    /// Wraps one handler invocation (1c) so §7.6's per-handler event budget
    /// applies only to raises caused by that specific invocation. Re-entrant:
    /// a nested call restores the outer counter on exit.
    public func withHandlerContext<T>(_ body: () -> T) -> T {
        let previousActive = handlerContextActive
        let previousCount = handlerEventCount
        handlerContextActive = true
        handlerEventCount = 0
        defer {
            handlerContextActive = previousActive
            handlerEventCount = previousCount
        }
        return body()
    }

    private func coalescingKey(kind: EventKind, subject: ObjectRef, payload: [String: AttrValue]) -> String? {
        switch kind {
        case .attributeChanged:
            guard case .string(let key)? = payload["key"] else { return nil }
            return "attr:\(subject.canonical):\(key)"
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

    private func raiseOverBudgetOnce(reason: String, tick: Int64) {
        guard !overBudgetSignaledThisTick else { return }
        overBudgetSignaledThisTick = true
        // Bypasses the queue-size check deliberately — the one diagnostic
        // that must always get through even when the queue is already full
        // (§7.6: "excess is dropped deterministically with one
        // `script.overBudget`").
        let seq = nextSeq
        nextSeq += 1
        let event = ScriptEvent(
            seq: seq, tick: tick, kind: .scriptOverBudget, subject: .world,
            payload: ["message": .string(reason)], source: .engine, cascadeDepth: 0
        )
        pending.append(event)
        appendRecent(event, excludeFromRecent: false)
    }

    private func appendRecent(_ event: ScriptEvent, excludeFromRecent: Bool) {
        guard !excludeFromRecent else { return }
        recent.append(event)
        if recent.count > caps.maxRecentEvents {
            recent.removeFirst(recent.count - caps.maxRecentEvents)
        }
    }

    /// `/events recent` (§12). Most-recent last (append order); `limit` (if
    /// given) keeps the most-recent `limit` entries.
    public func recentEvents(limit: Int? = nil) -> [ScriptEvent] {
        guard let limit, limit < recent.count else { return recent }
        return Array(recent.suffix(limit))
    }

    /// The current pending (undelivered) queue depth — test/diagnostic use.
    public var pendingCount: Int { pending.count }

    // MARK: - persisted subscriptions (`/on`, `/unsubscribe`, phase 2 AI tool)

    @discardableResult
    public func subscribe(
        subscriber: ObjectRef, scriptName: String, handler: String, target: SubscriptionTarget,
        event: EventKind, attribute: String?, createdBy: Provenance.Author, tick: Int64
    ) -> Result<Subscription, SubscribeError> {
        if case .kind(.block, let filter) = target, filter == nil, event.requiresBlockTypeFilter {
            return .failure(.targetRequiresTypeFilter)
        }
        if target == .any, event.requiresBlockTypeFilter {
            // requiresBlockTypeFilter is exactly {attribute.changed,
            // blockChanged} — §7.3's ".any for causal events only".
            return .failure(.anyNotAllowedForThisEvent)
        }
        let key = Subscription.NaturalKey(
            subscriber: subscriber, scriptName: scriptName, handler: handler,
            target: target, event: event, attribute: attribute
        )
        if let existing = persistedSubs.first(where: { $0.naturalKey == key }) {
            return .success(existing) // upsert of an identical key is a no-op (§7.3: idempotent)
        }
        let perObjectCount = persistedSubs.lazy.filter { $0.subscriber == subscriber }.count
        guard perObjectCount < caps.maxSubscriptionsPerObject else { return .failure(.tooManyForObject) }
        guard persistedSubs.count < caps.maxSubscriptionsPerWorld else { return .failure(.tooManyForWorld) }
        let sub = Subscription(
            id: nextSubscriptionID, subscriber: subscriber, scriptName: scriptName, handler: handler,
            target: target, event: event, attribute: attribute, createdBy: createdBy, createdTick: tick
        )
        nextSubscriptionID += 1
        persistedSubs.append(sub)
        return .success(sub)
    }

    @discardableResult
    public func unsubscribe(id: UInt64) -> Bool {
        guard let idx = persistedSubs.firstIndex(where: { $0.id == id }) else { return false }
        persistedSubs.remove(at: idx)
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
            nextSubscriptionID = 1
            return
        }
        persistedSubs = subs
        let maxExisting = max(subs.map(\.id).max() ?? 0, scriptOwnedSubs.map(\.id).max() ?? 0)
        nextSubscriptionID = max(nextSubscriptionID, maxExisting + 1)
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

    @discardableResult
    public func registerScriptOwned(
        owner: ObjectRef, scriptName: String, target: SubscriptionTarget, event: EventKind,
        attribute: String?, token: AnyObject? = nil
    ) -> ScriptOwnedSubscription {
        let sub = ScriptOwnedSubscription(
            id: nextSubscriptionID, owner: owner, scriptName: scriptName, target: target,
            event: event, attribute: attribute, token: token
        )
        nextSubscriptionID += 1
        scriptOwnedSubs.append(sub)
        return sub
    }

    public func unregisterScriptOwned(id: UInt64) {
        scriptOwnedSubs.removeAll { $0.id == id }
    }

    /// §7.3 "dropped at unload" / §7.5 step 6: bulk-drops every script-owned
    /// subscription rooted at any of `refs`. This function is a pure filter —
    /// the caller owns computing (and sorting) `refs`; dropping in any order
    /// produces the same resulting set, so no sort happens here.
    public func dropScriptOwnedSubscriptions(ownedBy refs: [ObjectRef]) {
        guard !refs.isEmpty, !scriptOwnedSubs.isEmpty else { return }
        let refSet = Set(refs)
        scriptOwnedSubs.removeAll { refSet.contains($0.owner) }
    }

    public var scriptOwnedSubscriptionCount: Int { scriptOwnedSubs.count }

    // MARK: - the pre-filtered block-changed funnel (§6.6 point 2)

    /// Called from `GameCore.hookWorld`'s extended `onBlockChanged` for every
    /// non-silent block write. Decodes/raises only when the change is
    /// actually observable — the cell already carries an `ObjectRecord`, or a
    /// `.kind(.block, typeFilter)` subscription to `block.changed` matches
    /// the old or new block's family name — otherwise this is an O(1)
    /// no-op (the zero-scripts fast path §15 asks for).
    public func recordBlockChange(
        dim: Dim, x: Int, y: Int, z: Int, oldId: Int, newId: Int, hasObjectRecord: Bool, tick: Int64
    ) {
        guard oldId != newId else { return }
        guard oldId >= 0, oldId < blockDefs.count, newId >= 0, newId < blockDefs.count else { return }
        let oldName = blockDefs[oldId].name
        let newName = blockDefs[newId].name
        guard hasObjectRecord || blockChangeHasTypeFilterInterest(oldName: oldName, newName: newName) else { return }
        raise(
            kind: .blockChanged, subject: .block(dim: dim, x: x, y: y, z: z),
            payload: [
                "oldName": .string(oldName), "newName": .string(newName),
                "oldMeta": .int(Int64(oldId & 15)), "newMeta": .int(Int64(newId & 15)),
            ],
            source: .engine, tick: tick, subjectType: newName
        )
    }

    private func blockChangeHasTypeFilterInterest(oldName: String, newName: String) -> Bool {
        for sub in persistedSubs where sub.event == .blockChanged {
            if case .kind(.block, let filter?) = sub.target, filter == oldName || filter == newName { return true }
        }
        for sub in scriptOwnedSubs where sub.event == .blockChanged {
            if case .kind(.block, let filter?) = sub.target, filter == oldName || filter == newName { return true }
        }
        return false
    }

    // MARK: - subscription-interest queries (phase-diff zero-cost gate)

    public var hasAnySubscription: Bool { !persistedSubs.isEmpty || !scriptOwnedSubs.isEmpty }

    /// Whether *any* subscription could possibly match an `attribute.changed`
    /// on `ref` — a conservative (type-filter-blind) pre-check the phase diff
    /// uses to skip diffing an unobserved object entirely (§6.6: "only
    /// observed objects pay"). Correctness of the actual delivery still comes
    /// from `matches` at delivery time.
    public func hasAttributeChangedInterest(in ref: ObjectRef) -> Bool {
        for sub in persistedSubs where sub.event == .attributeChanged {
            if interestMatches(sub.target, ref) { return true }
        }
        for sub in scriptOwnedSubs where sub.event == .attributeChanged {
            if interestMatches(sub.target, ref) { return true }
        }
        return false
    }

    private func interestMatches(_ target: SubscriptionTarget, _ ref: ObjectRef) -> Bool {
        switch target {
        case .object(let r): return r == ref
        case .kind(let k, _): return k == ref.kind
        case .any: return false // .any is never valid for attribute.changed (subscribe() refuses it)
        }
    }

    // MARK: - delivery (§7.4/§7.5 step 5, §7.6)

    /// Drains `pending` in `seq` order, up to `caps.maxDeliveriesPerTick`
    /// total deliveries this call, computing each event's ordered recipient
    /// list and invoking `delivery`. Runs in an inner loop so a cascade
    /// (`delivery` calling back into `raise(..., causedBy:)`, which only 1c's
    /// dispatcher will ever do) is drained within the *same* tick, up to the
    /// same per-tick delivery budget — the depth-8 cap is enforced per event
    /// at `raise` time, independent of this loop. Undelivered leftovers carry
    /// into the next tick (§7.6: "Leftovers carry into the next tick") —
    /// never dropped by this function itself.
    @discardableResult
    public func runDeliveryPhase(tick: Int64) -> PhaseReport {
        overBudgetSignaledThisTick = false
        var report = PhaseReport()
        guard !pending.isEmpty else { return report }
        var totalDelivered = 0
        while totalDelivered < caps.maxDeliveriesPerTick, !pending.isEmpty {
            let batchSize = min(pending.count, caps.maxDeliveriesPerTick - totalDelivered)
            for i in 0..<batchSize {
                let event = pending[i]
                delivery?(event, recipients(for: event))
            }
            pending.removeFirst(batchSize)
            totalDelivered += batchSize
        }
        report.delivered = totalDelivered
        report.carriedOver = pending.count
        return report
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
        for sub in persistedSubs where sub.event == event.kind
            && matches(sub.target, attribute: sub.attribute, subject: event.subject,
                       attributeKey: attributeKey, subjectType: event.subjectType, kind: event.kind) {
            targets.append(EventDeliveryTarget(kind: .persisted(sub)))
        }
        for sub in scriptOwnedSubs where sub.event == event.kind
            && matches(sub.target, attribute: sub.attribute, subject: event.subject,
                       attributeKey: attributeKey, subjectType: event.subjectType, kind: event.kind) {
            targets.append(EventDeliveryTarget(kind: .scriptOwned(sub)))
        }
        targets.sort { $0.id < $1.id }
        return targets
    }

    private func matches(
        _ target: SubscriptionTarget, attribute: String?, subject: ObjectRef,
        attributeKey: String?, subjectType: String?, kind: EventKind
    ) -> Bool {
        if kind == .attributeChanged {
            if let attribute {
                guard attribute == attributeKey else { return false }
            } else if attributeKey == "pos" {
                // §6.6: position is excluded from attribute-less subscriptions.
                return false
            }
        }
        switch target {
        case .object(let ref): return ref == subject
        case .kind(let k, let filter):
            guard k == subject.kind else { return false }
            guard let filter else { return true }
            return subjectType == filter
        case .any: return true
        }
    }
}
