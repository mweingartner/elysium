// GameCore+Scripting.swift — object-graph-attributes (change 1a). design.md
// Decisions 2/3/9. `GameCore`'s `ObjectGraphHost` conformance plus the small
// amount of session state the scripting subsystem needs
// (`GameScriptingState`) — kept out of `GameCore.swift` itself so that
// 5,500-line file's own diff stays at the one stored property Decision 2
// asks for.

import Foundation

func scriptEventSource(for author: Provenance.Author) -> EventSource {
    switch author {
    case .player: return .player
    case .ai(let model): return .ai(model: model)
    case .script(let owner, let name): return .script(owner: owner, name: name)
    case .lan(let peer): return .lan(peerID: peer)
    }
}

/// Session-scoped scripting state a `GameCore` owns for the lifetime of one
/// open world. Reset (by simply replacing its contents) on every
/// `enterWorld`; nothing here is itself persisted directly — it mirrors what
/// `WorldRecord.objects`/`Chunk.objectRecords`/`Entity.objectRecord` already
/// persist.
public final class GameScriptingState {
    /// World + three dimension bags, keyed by `ObjectRef.canonical`
    /// (`"world"`, `"dim:overworld"`, `"dim:nether"`, `"dim:end"`).
    var worldRecords: [String: ObjectRecord] = [:]
    /// Whether the entity-id reservation write has already failed once this
    /// session (design.md Condition 7: "failure logged once per session").
    var reservationFailureLogged = false
    /// event-bus (change 1b). Replaced (never mutated in place) at every
    /// `enterWorld` — a stale event/subscription in a `EventBus` instance
    /// must never outlive the world it belonged to, exactly like the entity
    /// id reservation hook (design.md Decision 3's own comment on that
    /// point) — `loadEventSubscriptions(from:)` is the single place that
    /// does the replacement.
    public var eventBus = EventBus()
    /// The diff phase's per-object baseline (§6.6 point 3: "the baseline
    /// taken at load emits nothing"), keyed by `ObjectRef.canonical`. Reset
    /// alongside `eventBus`.
    var diffBaselines: [String: [String: AttrValue]] = [:]
    /// Non-nil only while a command, Lua script, LAN guest, or AI tool is inside one authoritative
    /// built-in setter. World hooks read it synchronously so semantic/block events retain the true
    /// provenance instead of being mislabeled as generic engine/player work.
    var activeBuiltInMutationAuthor: Provenance.Author?
    /// script-runtime (change 1c). One `LuaState`-owning runtime per open
    /// world session (host-only — `nil` for a LAN-client world, or a world
    /// where `ScriptRuntime`'s own `LuaState` construction failed). Created
    /// in `enterWorld` after `hookWorld` runs for every dimension (§7.5
    /// step 6's own comment on `lua_State` lifetime), destroyed in
    /// `exitToTitle` after every script's `unload` runs.
    public var scriptRuntime: ScriptRuntime?
    /// Durable timer registry decoded before the Lua runtime exists and retained after runtime
    /// teardown long enough for the final save to serialize it. While a runtime is live, that
    /// runtime's `timers` array is authoritative.
    var durableTimers: [DurableTimer] = []
    /// Session summary/fast-path hint. Exact lifecycle work is carried by
    /// `scriptDefinitionChanges`; this flag is never used as a discovery substitute.
    public var anyScriptsAttached = false
    /// Advanced by every definition mutation, persistence hydration, and unload notification.
    var scriptDefinitionGeneration: UInt64 = 0
    /// Live scripted-ref index plus canonically ordered dirty work. A phase drains only a fixed
    /// prefix, so a large save hydration cannot turn into a periodic main-thread world census.
    var scriptDefinitionChanges = ScriptDefinitionChangeIndex()
    /// ai-object-graph (change 2), design.md §9.5. Replaced (never mutated
    /// in place) at every `enterWorld`, exactly like `eventBus` — a stale
    /// journal entry (or a subscription-undo id from a previous session)
    /// must never outlive the world it belonged to.
    public var aiJournal = AIJournal()

    public init() {}
}

extension GameCore: ObjectGraphHost {
    public var currentDimension: Dim { dim }

    public func world(for dim: Dim) -> World? { worlds[dim] }

    /// Bridges `GameCore.player` (`Player!`, historical) to the protocol's
    /// plain-`Optional` requirement — named `localPlayer` rather than
    /// `player` so it cannot collide with (or be mistaken for a re-typing
    /// of) that stored property.
    public var localPlayer: Player? { player }

    public var isLANClient: Bool { isLANClientWorld }

    /// The scripting/event contract exposes the dimension-independent deterministic simulation
    /// clock. World day time can jump or differ by dimension and must never drive waits, timers,
    /// provenance, or event ordering.
    public var currentTick: Int64 { Int64(rpgSimulationTick) }

    public var scriptsEnabled: Bool { worldRec?.scriptsEnabled ?? false }

    public var scriptDefinitionGeneration: UInt64 { scripting.scriptDefinitionGeneration }

    public func scriptDefinitionsDidChange(for ref: ObjectRef, hasScripts: Bool) {
        scripting.scriptDefinitionGeneration &+= 1
        scripting.scriptDefinitionChanges.record(ref, hasScripts: hasScripts)
        if hasScripts { scripting.anyScriptsAttached = true }
    }

    public func drainDirtyScriptDefinitionRefs(limit: Int) -> [ObjectRef] {
        scripting.scriptDefinitionChanges.drain(limit: limit)
    }

    public func worldObjectRecord(for ref: ObjectRef) -> ObjectRecord {
        scripting.worldRecords[ref.canonical] ?? ObjectRecord()
    }

    public func setWorldObjectRecord(_ record: ObjectRecord, for ref: ObjectRef) {
        if record.isEmpty {
            scripting.worldRecords.removeValue(forKey: ref.canonical)
        } else {
            scripting.worldRecords[ref.canonical] = record
        }
    }

    public func setScriptBuiltInAttribute(
        _ live: LiveObject, ref: ObjectRef, name: String, value: AttrValue,
        author: Provenance.Author
    ) -> BuiltInSetOutcome {
        let canonical = AttributeRegistry.resolve(kind: ref.kind, name: name)?.canonical ?? name
        let before: AttrValue? = if case .value(let value) = BuiltInAttributes.get(
            live, name: canonical, host: self
        ) { value } else { nil }
        let previousAuthor = scripting.activeBuiltInMutationAuthor
        scripting.activeBuiltInMutationAuthor = author
        defer { scripting.activeBuiltInMutationAuthor = previousAuthor }
        let outcome = BuiltInAttributes.set(live, name: canonical, value: value, host: self)
        guard case .ok(let after) = outcome, before != after else { return outcome }

        // Block setters use World.setBlock, whose synchronous hook compares every observed cell
        // field and emits with `activeBuiltInMutationAuthor`. Other object families have no common
        // mutation hook, so publish their exact before/after pair here.
        if case .block = live {
            return outcome
        }
        eventBus.raise(
            kind: .attributeChanged, subject: ref,
            payload: ["key": .string(canonical), "old": before ?? .null, "new": after],
            source: scriptEventSource(for: author), tick: currentTick,
            subjectType: scriptSubjectType(for: live)
        )
        var baseline = scripting.diffBaselines[ref.canonical] ?? [:]
        baseline[canonical] = after
        scripting.diffBaselines[ref.canonical] = baseline
        return outcome
    }

    public func commitPrevalidatedScriptBlockCell(
        _ world: World, x: Int, y: Int, z: Int, cell: Int,
        author: Provenance.Author
    ) {
        let previousAuthor = scripting.activeBuiltInMutationAuthor
        scripting.activeBuiltInMutationAuthor = author
        defer { scripting.activeBuiltInMutationAuthor = previousAuthor }
        world.setBlock(x, y, z, cell, SET_DEFAULT)
    }

    // `setDifficulty(_:)` and `setGameRule(_:_:)` are already implemented by
    // `GameCore` itself (Game/GameCore.swift) with the exact signatures this
    // protocol declares — no forwarding needed here.

    /// lan-client-parity (change 4): `nil` on a guest (`isLANClientWorld`) —
    /// a guest never resolves another peer's `player:lan:*` object, only the
    /// host does. On the host, looks up the live mirror in the *current*
    /// dimension's world only (a peer connected but elsewhere is `.dormant`,
    /// handled by `ObjectGraph.resolve` itself, not here).
    public func lanRemotePlayer(peerID: String) -> (entity: LANRemotePlayerEntity, world: World)? {
        guard !isLANClientWorld, let w = worlds[dim],
              let entity = lanRemotePlayerEntity(peerID: peerID, in: w)
        else { return nil }
        return (entity, w)
    }

    // MARK: - graph / store / command context

    /// event-bus (change 1b). One `EventBus` per open world session — see
    /// `GameScriptingState.eventBus`'s own comment for the replace-not-mutate
    /// lifecycle.
    public var eventBus: EventBus { scripting.eventBus }

    var attributeStore: AttributeStore {
        makeAttributeStore(graph: ObjectGraph(host: self))
    }

    /// Shared by `attributeStore` and `scriptingCommandContext()` so every
    /// `AttributeStore` this `GameCore` ever hands out is wired to the same
    /// `attribute.changed` funnel (design.md §6.6 point 1) — a second,
    /// unwired construction here would silently produce a store whose custom-
    /// attribute writes never reach the event bus at all.
    func makeAttributeStore(graph: ObjectGraph) -> AttributeStore {
        AttributeStore(graph: graph, onChange: { [weak self] ref, name, old, new, _, author in
            guard let self else { return }
            // `key`/`old`/`new` are the `attribute.changed` payload shape
            // §7.2 fixes; `old`/`new` use `.null` for "absent" (define/
            // remove edges) rather than omitting the key, so a subscriber's
            // payload shape never depends on which edge fired.
            let source: EventSource
            switch author {
            case .player: source = .player
            case .ai(let model): source = .ai(model: model)
            case .script(let owner, let scriptName): source = .script(owner: owner, name: scriptName)
            case .lan(let peer): source = .lan(peerID: peer)
            }
            self.eventBus.raise(
                kind: .attributeChanged, subject: ref,
                payload: ["key": .string(name), "old": old ?? .null, "new": new ?? .null],
                source: source, tick: Int64(self.rpgSimulationTick),
                subjectType: {
                    guard case .live(let live) = graph.resolve(ref) else { return nil }
                    return scriptSubjectType(for: live)
                }()
            )
        })
    }

    /// The entity under the crosshair within reach if one is closer than the
    /// block hit, else the block under the crosshair, else `nil` ("nothing
    /// under the cursor") — spec `object-graph-refs` "Command target
    /// aliases". `crosshairEntity` already refuses an entity farther than the
    /// block hit, so a non-nil entity here is always the closer of the two.
    public func cursorObjectRef() -> ObjectRef? {
        guard let p = player else { return nil }
        let reach = p.gameMode == GameMode.creative ? REACH_CREATIVE : REACH_SURVIVAL
        if let entity = crosshairEntity(reach) {
            return scriptRef(for: entity)
        }
        if let hit = crosshairBlock() {
            return .block(dim: dim, x: hit.x, y: hit.y, z: hit.z)
        }
        return nil
    }

    /// Builds the context `ScriptingCommands.run` needs — a fresh `ObjectGraph`/
    /// `AttributeStore` pair over `self`, the target-alias context, LAN-client
    /// state and the current tick.
    ///
    /// lan-client-parity (change 4): `guestPeerID` builds the context a
    /// validated `scriptIntent` executes through — every executor stays
    /// identical (same `store`/`scriptStore`/`eventBus`/trust gate/kill
    /// switch as the host's own commands, per design.md §11 "same executors
    /// as the player"), but `author` becomes `.lan(peer:)`, `self` resolves
    /// to the guest's own `player:lan:<peerID>` (not the host's `.player`),
    /// and `looking`/`cursor` are disabled (`nil`) — the host has no
    /// structured notion of a *guest's* crosshair target, so a forwarded
    /// command must name an explicit ref or `self`/`world`/`dim`.
    public func scriptingCommandContext(guestPeerID: String? = nil) -> ScriptingCommandContext {
        let graph = ObjectGraph(host: self)
        let store = makeAttributeStore(graph: graph)
        let author: Provenance.Author = guestPeerID.map { .lan(peer: $0) } ?? .player
        let selfRef: ObjectRef = guestPeerID.map { .lanPlayer(peerID: $0) } ?? .player
        let cursorResolver: () -> ObjectRef? = guestPeerID == nil ? { [weak self] in self?.cursorObjectRef() } : { nil }
        let targetContext = ObjectTargetContext(currentDimension: dim, cursor: cursorResolver, selfRef: selfRef)
        return ScriptingCommandContext(
            graph: graph, store: store, target: targetContext, isLANClient: isLANClientWorld,
            tick: Int64(rpgSimulationTick), eventBus: eventBus,
            // script-runtime (change 1c): `/script`'s own executors.
            scriptStore: ScriptStore(graph: graph), scriptRuntime: scripting.scriptRuntime,
            scriptsTrusted: worldRec?.scriptsEnabled ?? false, killSwitchOn: (world.gameRules["doScripts"] ?? 1) != 0,
            trustWorld: { [weak self] in
                guard var rec = self?.worldRec else { return }
                rec.scriptsEnabled = true
                self?.worldRec = rec
                self?.db.putWorld(rec)
            },
            setKillSwitch: { [weak self] on in self?.setGameRule("doScripts", on ? 1 : 0) },
            markScriptAttached: { [weak self] in self?.scripting.anyScriptsAttached = true },
            aiJournal: scripting.aiJournal, author: author
        )
    }

    // MARK: - AI tool loop context builders (ai-object-graph, change 2)

    /// The read-only bundle `AIObjectGraphQueryTools` needs — mirrors
    /// `scriptingCommandContext()`'s own "fresh `ObjectGraph`/`AttributeStore`
    /// pair over `self`" construction.
    public func aiQueryContext() -> AIQueryContext {
        let graph = ObjectGraph(host: self)
        let targetContext = ObjectTargetContext(currentDimension: dim, cursor: { [weak self] in self?.cursorObjectRef() })
        return AIQueryContext(
            graph: graph, store: makeAttributeStore(graph: graph), scriptStore: ScriptStore(graph: graph),
            eventBus: eventBus, target: targetContext, scriptRuntime: scripting.scriptRuntime
        )
    }

    /// The mutable bundle `AIObjectGraphMutationTools` needs — `requestID`
    /// must come from `scripting.aiJournal.beginRequest()`, called once per
    /// `/ai` tool-loop invocation before any of its tool calls run (so every
    /// mutation that invocation makes shares one undo group, §9.1/§9.5).
    public func aiMutationContext(model: String, requestID: UInt64) -> AIMutationContext {
        let graph = ObjectGraph(host: self)
        let targetContext = ObjectTargetContext(currentDimension: dim, cursor: { [weak self] in self?.cursorObjectRef() })
        return AIMutationContext(
            graph: graph, store: makeAttributeStore(graph: graph), scriptStore: ScriptStore(graph: graph),
            eventBus: eventBus, scriptRuntime: scripting.scriptRuntime, target: targetContext,
            tick: Int64(rpgSimulationTick), model: model, isLANClient: isLANClientWorld, journal: scripting.aiJournal,
            requestID: requestID
        )
    }

    // MARK: - uid hi/lo reservation (design.md Decision 3 / Condition 7,
    // amended by Security (plan) C20)

    /// The reservation hook `installEntityIdReservation` fires (via
    /// `Entity.init`/`bumpEntityIdCounter(past:)`) whenever the live counter
    /// is about to hand out an id at or past the durable mark. Writes the
    /// world record with `nextEntityId = needed + 4096` (overflow-safe,
    /// saturating at `WorldRecord.maxReservableEntityId`), verifies by
    /// reading it back, and raises the mark only once that verification
    /// succeeds. A failed write is logged once per session (never again) and
    /// the mark is raised anyway so the hook does not keep retrying a write
    /// that is already known to fail on every subsequent mint.
    func reserveEntityIds(upTo needed: Int) {
        guard var rec = worldRec, !isLANClientWorld else { return }
        let (bumped, overflowed) = needed.addingReportingOverflow(4096)
        let newLimit = overflowed ? WorldRecord.maxReservableEntityId : min(bumped, WorldRecord.maxReservableEntityId)
        rec.nextEntityId = max(newLimit, rec.nextEntityId)
        db.putWorld(rec)
        if let readBack = db.getWorld(rec.id), readBack.nextEntityId >= newLimit {
            worldRec = rec
        } else if !scripting.reservationFailureLogged {
            scripting.reservationFailureLogged = true
            print("[scripting] entity id reservation write failed for world \(rec.id); "
                + "continuing without further reservation this session")
        }
        raiseEntityIdReservationLimit(to: newLimit)
    }

    // MARK: - world/dimension object records (design.md Decision 9)

    /// Populates `scripting.worldRecords` from a freshly loaded `WorldRecord`
    /// (`enterWorld`). A corrupt entry is dropped with a diagnostic; the
    /// world still loads.
    func loadWorldObjectRecords(from rec: WorldRecord) {
        scripting.worldRecords.removeAll()
        scripting.scriptDefinitionGeneration = 0
        scripting.scriptDefinitionChanges.reset()
        scripting.anyScriptsAttached = false
        for key in rec.objects.keys.sorted(by: utf8Less) {
            guard let text = rec.objects[key] else { continue }
            guard let record = ObjectRecordCodec.decode(text, caps: .defaults) else {
                print("[scripting] dropped corrupt world/dimension object record for '\(key)'")
                continue
            }
            scripting.worldRecords[key] = record
            if record.hasScriptDefinitions, let ref = ObjectRef.parse(key) {
                scriptDefinitionsDidChange(for: ref, hasScripts: true)
            }
        }
    }

    /// Encodes `scripting.worldRecords` into `rec.objects` (`saveAndFlushResult`,
    /// before `db.putWorld`) — non-empty bags only.
    func storeWorldObjectRecords(into rec: inout WorldRecord) {
        var out: [String: String] = [:]
        for (key, record) in scripting.worldRecords where !record.isEmpty {
            out[key] = ObjectRecordCodec.encode(record)
        }
        rec.objects = out
    }

    // MARK: - event subscriptions (design.md §7.3, `WorldRecord.scriptRegistry`)

    /// Replaces `scripting.eventBus` with a fresh instance and loads its
    /// persisted subscriptions from `rec.scriptRegistry` (`enterWorld`) — a
    /// stale `EventBus` (queued events, subscriptions) must never outlive the
    /// world it belonged to.
    func loadEventSubscriptions(from rec: WorldRecord) {
        scripting.eventBus = EventBus()
        scripting.diffBaselines.removeAll()
        if !rec.scriptRegistry.isEmpty {
            scripting.eventBus.loadPersistedSubscriptions(from: rec.scriptRegistry, storageCaps: .defaults) { message in
                print("[scripting] \(message)")
            }
        }
        // ai-object-graph (change 2), design.md §9.5: the journal rides the
        // same load point as everything else scripting persists — a fresh
        // `AIJournal()` per session (§9.5's own ring semantics don't survive
        // a stale prior session any more than subscriptions do).
        scripting.aiJournal = AIJournal()
        if !rec.aiJournal.isEmpty {
            scripting.aiJournal.loadPersisted(from: rec.aiJournal) { message in
                print("[scripting] \(message)")
            }
        }
        // Decode before `createScriptRuntimeForSession`: enterWorld intentionally constructs Lua
        // only after every World has been hooked. The session snapshot bridges that ordering.
        scripting.durableTimers = []
        if !rec.scriptTimers.isEmpty {
            if let timers = DurableTimerRegistryCodec.decode(rec.scriptTimers, diagnostic: { message in
                print("[scripting] \(message)")
            }) {
                scripting.durableTimers = timers
            } else {
                print("[scripting] dropped corrupt durable timer registry")
            }
        }
    }

    /// Encodes `scripting.eventBus`'s persisted subscriptions into
    /// `rec.scriptRegistry` (`saveAndFlushResult`, before `db.putWorld`) —
    /// empty when there are none, exactly like `objects`.
    func storeEventSubscriptions(into rec: inout WorldRecord) {
        rec.scriptRegistry = scripting.eventBus.hasPersistedSubscriptions
            ? scripting.eventBus.encodePersistedSubscriptions() : ""
        let timers = scripting.scriptRuntime?.timers ?? scripting.durableTimers
        rec.scriptTimers = timers.isEmpty ? "" : DurableTimerRegistryCodec.encode(timers)
        rec.aiJournal = scripting.aiJournal.encodePersisted()
    }

    // MARK: - script runtime session lifecycle (design.md §7.5's "the
    // lua_State... created in enterWorld after hookWorld... never created
    // for LAN-client worlds")

    /// Called from `enterWorld` right after `hookWorld` has run for every
    /// dimension. Construction failure (design.md Decision 9/`LuaRuntimeError`
    /// — locale not pinned, sandbox construction failed, ...) is logged once
    /// and leaves `scripting.scriptRuntime` `nil`: the kill switch/trust gate
    /// already make "no runtime" behaviorally identical to "scripts off", so
    /// the world still loads and plays normally, just without scripting.
    func createScriptRuntimeForSession() {
        guard !isLANClientWorld else { return }
        // World/dimension records were indexed before the worlds existed. Entity and block records
        // arrive later, through these host-only lifecycle hooks, so no periodic world census is
        // needed. `World` calls the hydration hook only for records that actually contain scripts.
        for w in worlds.values {
            w.hooks.onScriptObjectHydrated = { [weak self] ref, record in
                guard record.hasScriptDefinitions else { return }
                self?.scriptDefinitionsDidChange(for: ref, hasScripts: true)
            }
            w.hooks.onScriptObjectUnloaded = { [weak self] ref in
                self?.scriptDefinitionsDidChange(for: ref, hasScripts: false)
            }
        }
        do {
            scripting.scriptRuntime = try ScriptRuntime(
                host: self, state: scripting,
                say: { [weak self] line in self?.host?.pushChat(line) }
            )
            scripting.scriptRuntime?.restoreDurableTimers(scripting.durableTimers)
        } catch {
            print("[scripting] script runtime construction failed (\(error)); scripting disabled this session")
            scripting.scriptRuntime = nil
        }
        scripting.eventBus.delivery = { [weak self] event, targets in
            self?.scripting.scriptRuntime?.deliver(event, targets)
        }
        scripting.eventBus.deliveryAdmission = { [weak self] event, targets in
            guard let runtime = self?.scripting.scriptRuntime else { return targets.count }
            return runtime.admittedDeliveryCount(for: event, targets: targets)
        }
    }

    /// Called from `exitToTitle`, before `finalizeAndSave` captures the
    /// world/chunk/entity records — runs every live script's `unload`
    /// synchronously (§8.2), then drops the `LuaState`.
    func teardownScriptRuntimeForSession() {
        scripting.scriptRuntime?.unloadAllForShutdown()
        scripting.scriptRuntime?.persistRNGState()
        scripting.durableTimers = scripting.scriptRuntime?.timers ?? scripting.durableTimers
        scripting.scriptRuntime = nil
        scripting.eventBus.delivery = nil
        scripting.eventBus.deliveryAdmission = nil
    }

    // MARK: - script phase (design.md §7.5)

    /// Placed in `GameCore.tick()` after the dead-entity sweep and before
    /// `tickEntityTriggers` (§7.5), host-only (the caller already returns
    /// before reaching this point on a LAN client, same as the sweep it
    /// follows). Implements the full §7.5 step order: loads (1) -> diff (2)
    /// -> AI inbox (3) -> resumptions incl. durable timers (4) -> deliveries
    /// (5, `EventBus.runDeliveryPhase`, dispatching into `ScriptRuntime
    /// .deliver` via the `delivery` seam) -> the deferred object-record drop
    /// (part of §6.7/step 6) -> RNG-state persistence (this change's own
    /// bookkeeping, not a numbered §7.5 step). Kept named `runEventBusPhase`
    /// for source-compat with 1b's own doc comments/tests that already call
    /// it by this name; it is the same function 1b shipped, extended in
    /// place rather than renamed.
    func runEventBusPhase() {
        // Defense in depth (like `ScriptingCommands.run`'s own re-check):
        // `GameCore.tick()` already never reaches this call for a LAN client
        // (the whole branch returns earlier), but a test harness calling this
        // function directly should get the same host-only guarantee.
        guard !isLANClientWorld else { return }
        let w = world
        let tick = Int64(rpgSimulationTick)
        if let runtime = scripting.scriptRuntime, scriptsEffectivelyEnabled(host: self) {
            runtime.resetPerTickCounters()
            runtime.runLoads()
            if eventBus.hasAnySubscription {
                runObservableBuiltInDiff(w, tick: tick)
            }
            runtime.runAIInbox()
            runtime.runResumptions()
            eventBus.runDeliveryPhase(tick: tick)
            runtime.persistRNGState()
        } else {
            if eventBus.hasAnySubscription {
                runObservableBuiltInDiff(w, tick: tick)
            }
            eventBus.runDeliveryPhase(tick: tick)
        }
        w.drainPendingObjectRecordDrops()
    }

    /// event-bus (change 1b), design.md §6.6 point 3 / §7.5 step 2. Diffs the
    /// named observable built-ins for the world, its three dimensions, and
    /// every live entity/player that at least one subscription could match
    /// (`EventBus.hasAttributeChangedInterest`) — "only observed objects
    /// pay." The first observation of any given ref records a baseline and
    /// emits nothing (§6.6: "the baseline taken at load emits nothing").
    private func runObservableBuiltInDiff(_ w: World, tick: Int64) {
        let worldDimRefs: [ObjectRef] = [.world, .dimension(.overworld), .dimension(.nether), .dimension(.end)]
        for ref in worldDimRefs {
            guard case .live(let live) = attributeStoreGraph.resolve(ref) else { continue }
            let observation = eventBus.attributeObservation(
                in: ref, subjectType: scriptSubjectType(for: live)
            )
            var fields = Set(observableFields(for: observation, live: live))
            if case .dimension = ref {
                if eventBus.hasEventInterest(.dimDayPhaseChanged, subject: ref) { fields.insert("day_phase") }
                if eventBus.hasEventInterest(.dimWeatherChanged, subject: ref) {
                    fields.formUnion(["raining", "thundering"])
                }
            }
            diffFields(
                fields.sorted(by: utf8Less), live: live, ref: ref, tick: tick,
                observation: observation
            )
        }
        for e in w.entities {
            guard let ent = e as? Entity, !ent.dead, !ent.lanReplicatedMirror else { continue }
            let ref: ObjectRef = if let remote = ent as? LANRemotePlayerEntity {
                .lanPlayer(peerID: remote.multiplayerPlayerID)
            } else {
                scriptRef(for: ent)
            }
            let observation = eventBus.attributeObservation(in: ref, subjectType: ent.type)
            let observesLevel = ent is Player && eventBus.hasEventInterest(.playerLeveled, subject: ref)
            guard !observation.isEmpty || observesLevel else { continue }
            guard case .live(let live) = attributeStoreGraph.resolve(ref) else { continue }
            var fields = Set(observableFields(for: observation, live: live))
            if observesLevel { fields.insert("xp_level") }
            diffFields(
                fields.sorted(by: utf8Less), live: live, ref: ref, tick: tick,
                observation: observation
            )
            if observation.explicitlyObserves("pos") {
                diffPosition(live: live, ref: ref, entity: ent, tick: tick)
            }
        }

        // Exact block observers also see dynamic light and block-entity fields that do not pass
        // through World.setBlock. Kind-filtered block cell state remains hook-driven, avoiding an
        // unbounded scan of every loaded voxel.
        for ref in eventBus.exactAttributeObservedObjects(of: .block) {
            guard case .live(let live) = attributeStoreGraph.resolve(ref) else { continue }
            let observation = eventBus.attributeObservation(
                in: ref, subjectType: scriptSubjectType(for: live)
            )
            diffFields(
                observableFields(for: observation, live: live), live: live, ref: ref, tick: tick,
                observation: observation
            )
        }
    }

    private var attributeStoreGraph: ObjectGraph { ObjectGraph(host: self) }

    private func observableFields(
        for observation: EventBus.AttributeObservation, live: LiveObject
    ) -> [String] {
        var names = observation.names
        if observation.observesAll {
            names.formUnion(BuiltInAttributes.applicableObservableNames(for: live))
        }
        return names.sorted(by: utf8Less)
    }

    /// Synchronous World.setBlock funnel for block base attributes. It compares only fields that
    /// at least one exact/type-filtered subscription can receive, so the ordinary no-script path
    /// remains four bounded index lookups and no descriptor/value construction.
    func recordObservableBlockAttributeChanges(
        world: World, x: Int, y: Int, z: Int, oldCell: Int, newCell: Int,
        source: EventSource
    ) {
        guard oldCell != newCell else { return }
        let ref = ObjectRef.block(dim: world.dim, x: x, y: y, z: z)
        let oldType = blockTypeName(for: oldCell)
        let newType = blockTypeName(for: newCell)
        var observation = eventBus.attributeObservation(in: ref, subjectType: newType)
        if oldType != newType {
            observation.formUnion(eventBus.attributeObservation(in: ref, subjectType: oldType))
        }
        guard !observation.isEmpty else { return }

        let oldValues = Self.blockCellAttributeValues(oldCell)
        let newValues = Self.blockCellAttributeValues(newCell)
        var names = observation.names
        if observation.observesAll {
            names.formUnion(oldValues.keys)
            names.formUnion(newValues.keys)
        }
        var baseline = scripting.diffBaselines[ref.canonical] ?? [:]
        for name in names.sorted(by: utf8Less) {
            let old = oldValues[name]
            let new = newValues[name]
            guard old != new else { continue }
            eventBus.raise(
                kind: .attributeChanged, subject: ref,
                payload: ["key": .string(name), "old": old ?? .null, "new": new ?? .null],
                source: source, tick: currentTick, subjectType: newType,
                priorSubjectType: oldType
            )
            baseline[name] = new ?? .null
        }
        scripting.diffBaselines[ref.canonical] = baseline
    }

    private static func blockCellAttributeValues(_ cell: Int) -> [String: AttrValue] {
        let id = cell >> 4
        guard id >= 0, id < blockDefs.count else { return [:] }
        let definition = blockDefs[id]
        var values = BlockStateCodec.decode(cell)
        values["name"] = .string(definition.name)
        values["shape"] = .string(String(describing: definition.shape))
        values["hardness"] = .number(definition.hardness)
        values["light"] = .int(Int64(lightEmitOf(UInt16(cell))))
        return values
    }

    private func blockTypeName(for cell: Int) -> String {
        let id = cell >> 4
        return id >= 0 && id < blockDefs.count ? blockDefs[id].name : "block"
    }

    private func diffFields(
        _ fields: [String], live: LiveObject, ref: ObjectRef, tick: Int64,
        observation: EventBus.AttributeObservation
    ) {
        guard !fields.isEmpty else { return }
        var baseline = scripting.diffBaselines[ref.canonical] ?? [:]
        for name in fields {
            guard case .value(let current) = BuiltInAttributes.get(live, name: name, host: self) else { continue }
            let previous = baseline[name]
            baseline[name] = current
            guard let previous, previous != current else { continue }
            if observation.observes(name) {
                eventBus.raise(
                    kind: .attributeChanged, subject: ref,
                    payload: ["key": .string(name), "old": previous, "new": current],
                    source: .engine, tick: tick, subjectType: scriptSubjectType(for: live)
                )
            }
            if name == "day_phase" {
                eventBus.raise(
                    kind: .dimDayPhaseChanged, subject: ref,
                    payload: ["old": previous, "new": current], source: .engine, tick: tick
                )
            } else if name == "raining" || name == "thundering" {
                eventBus.raise(
                    kind: .dimWeatherChanged, subject: ref,
                    payload: ["key": .string(name), "old": previous, "new": current],
                    source: .engine, tick: tick
                )
            } else if name == "xp_level", case (.int(let oldLevel), .int(let newLevel)) = (previous, current),
                      newLevel > oldLevel {
                // event-bus (change 1b): `player.leveled` (design.md §7.2,
                // "addXP"). `Player.swift`'s `addXP` is untouched by this
                // change — derived from the diff instead of a direct funnel
                // (§6.6 already computes `xp_level`'s old/new every phase for
                // `attribute.changed`; a second, semantically-named event on
                // an actual increase costs nothing extra to compute).
                eventBus.raise(
                    kind: .playerLeveled, subject: ref,
                    payload: ["old": previous, "new": current], source: .engine, tick: tick
                )
            }
        }
        scripting.diffBaselines[ref.canonical] = baseline
    }

    /// Position (§6.6: "quantized to 1/10 block... excluded from attribute-
    /// less subscriptions and from `recent_events`") — diffed separately from
    /// `diffFields` because both its matching rule and its `recentEvents`
    /// visibility are special-cased, not because the underlying mechanism
    /// differs.
    private func diffPosition(live: LiveObject, ref: ObjectRef, entity: Entity, tick: Int64) {
        let quantized = AttrValue.list([
            .number((entity.x * 10).rounded() / 10),
            .number((entity.y * 10).rounded() / 10),
            .number((entity.z * 10).rounded() / 10),
        ])
        let key = ref.canonical + "#pos"
        let hadBaseline = scripting.diffBaselines[key] != nil
        let previous = scripting.diffBaselines[key]?["pos"]
        scripting.diffBaselines[key] = ["pos": quantized]
        guard hadBaseline, previous != quantized else { return }
        eventBus.raise(
            kind: .attributeChanged, subject: ref,
            payload: ["key": .string("pos"), "old": previous ?? .null, "new": quantized],
            source: .engine, tick: tick, subjectType: scriptSubjectType(for: live),
            excludeFromRecent: true, isSyntheticPositionChange: true
        )
    }

    // MARK: - sorted unload (design.md §7.3 "dropped at unload" / §7.5 step 6)

    /// Bulk-drops script-owned (in-memory) subscriptions rooted at any block
    /// in `chunk` or any of `entityRefs`, and finalizes any pending object-
    /// record drop for a cell in this chunk — called from `unloadChunk`
    /// right before the chunk record is captured for persistence, so a
    /// "replaced" record already delivered this tick never gets saved.
    /// `refs` is built by the caller in the sorted order design.md §7.5 step
    /// 6 specifies (chunk key, then dims by raw value); this function itself
    /// never reads dictionary order.
    func handleScriptedChunkUnload(_ w: World, _ chunk: Chunk, entityRefs: [ObjectRef]) {
        var refs = entityRefs
        if !chunk.objectRecords.isEmpty {
            for cellIndex in chunk.objectRecords.keys.sorted() {
                let (wx, wy, wz) = chunk.idxToWorld(cellIndex)
                refs.append(.block(dim: w.dim, x: wx, y: wy, z: wz))
            }
        }
        // script-runtime (change 1c), §7.5 step 6: run `unload` for every
        // live script rooted at one of `refs` (against an attrs-only facade
        // — `ScriptRuntime.unloadScripts` never opens a world write path)
        // and drop its compiled environment, *before* the script-owned
        // subscriptions those instances registered are bulk-dropped below —
        // matches §8.2's own ordering ("unload handlers run... then
        // handlers, timers, suspended threads and the handle are dropped").
        scripting.scriptRuntime?.unloadScripts(for: refs)
        eventBus.dropScriptOwnedSubscriptions(ownedBy: refs)
        // A block-id-change drop queued earlier this tick for a cell in this
        // chunk (§6.7) must be applied now, before `chunkRecord()` snapshots
        // `objectRecords` for persistence — otherwise a record already fully
        // delivered (`block.replaced`) could still get saved.
        for drop in w.pendingObjectRecordDrops where drop.chunk === chunk {
            if let current = chunk.objectRecords[drop.cellIndex], current.revision == drop.expectedRevision {
                chunk.objectRecords.removeValue(forKey: drop.cellIndex)
                if current.hasScriptDefinitions {
                    let (x, y, z) = chunk.idxToWorld(drop.cellIndex)
                    w.hooks.onScriptObjectUnloaded(.block(dim: w.dim, x: x, y: y, z: z))
                }
            }
        }
        w.pendingObjectRecordDrops.removeAll { $0.chunk === chunk }
        for ref in refs {
            scripting.diffBaselines.removeValue(forKey: ref.canonical)
            scripting.diffBaselines.removeValue(forKey: ref.canonical + "#pos")
        }
    }
}
