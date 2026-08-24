// GameCore+Scripting.swift — object-graph-attributes (change 1a). design.md
// Decisions 2/3/9. `GameCore`'s `ObjectGraphHost` conformance plus the small
// amount of session state the scripting subsystem needs
// (`GameScriptingState`) — kept out of `GameCore.swift` itself so that
// 5,500-line file's own diff stays at the one stored property Decision 2
// asks for.

import Foundation

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
    var eventBus = EventBus()
    /// The diff phase's per-object baseline (§6.6 point 3: "the baseline
    /// taken at load emits nothing"), keyed by `ObjectRef.canonical`. Reset
    /// alongside `eventBus`.
    var diffBaselines: [String: [String: AttrValue]] = [:]

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

    public var currentTick: Int64 { Int64(world.time) }

    public var scriptsEnabled: Bool { worldRec?.scriptsEnabled ?? false }

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

    // `setDifficulty(_:)` and `setGameRule(_:_:)` are already implemented by
    // `GameCore` itself (Game/GameCore.swift) with the exact signatures this
    // protocol declares — no forwarding needed here.

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
            }
            self.eventBus.raise(
                kind: .attributeChanged, subject: ref,
                payload: ["key": .string(name), "old": old ?? .null, "new": new ?? .null],
                source: source, tick: Int64(self.rpgSimulationTick)
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
            return .entity(uid: entity.id)
        }
        if let hit = crosshairBlock() {
            return .block(dim: dim, x: hit.x, y: hit.y, z: hit.z)
        }
        return nil
    }

    /// Builds the context `ScriptingCommands.run` needs — a fresh `ObjectGraph`/
    /// `AttributeStore` pair over `self`, the target-alias context, LAN-client
    /// state and the current tick.
    public func scriptingCommandContext() -> ScriptingCommandContext {
        let graph = ObjectGraph(host: self)
        let store = makeAttributeStore(graph: graph)
        let targetContext = ObjectTargetContext(currentDimension: dim, cursor: { [weak self] in self?.cursorObjectRef() })
        return ScriptingCommandContext(
            graph: graph, store: store, target: targetContext, isLANClient: isLANClientWorld,
            tick: Int64(world.time), eventBus: eventBus
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
        for (key, text) in rec.objects {
            guard let record = ObjectRecordCodec.decode(text, caps: .defaults) else {
                print("[scripting] dropped corrupt world/dimension object record for '\(key)'")
                continue
            }
            scripting.worldRecords[key] = record
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
        guard !rec.scriptRegistry.isEmpty else { return }
        scripting.eventBus.loadPersistedSubscriptions(from: rec.scriptRegistry, storageCaps: .defaults) { message in
            print("[scripting] \(message)")
        }
    }

    /// Encodes `scripting.eventBus`'s persisted subscriptions into
    /// `rec.scriptRegistry` (`saveAndFlushResult`, before `db.putWorld`) —
    /// empty when there are none, exactly like `objects`.
    func storeEventSubscriptions(into rec: inout WorldRecord) {
        rec.scriptRegistry = scripting.eventBus.hasPersistedSubscriptions
            ? scripting.eventBus.encodePersistedSubscriptions() : ""
    }

    // MARK: - event bus tick phase (design.md §7.5)

    /// Placed in `GameCore.tick()` after the dead-entity sweep and before
    /// `tickEntityTriggers` (§7.5), host-only (the caller already returns
    /// before reaching this point on a LAN client, same as the sweep it
    /// follows). This change implements the steps that don't need a script
    /// runtime: the observable-built-in diff (§7.5 step 2, narrowed to §6.6
    /// point 3's named fields), `EventBus.runDeliveryPhase` (§7.5 step 5),
    /// and the deferred object-record drop (§6.7) right after it. Loads/AI-
    /// inbox/resumptions/host-effects are 1c/phase 2 — there is nothing for
    /// them to do yet (no script records exist), so this function goes
    /// straight from the diff to delivery.
    func runEventBusPhase() {
        // Defense in depth (like `ScriptingCommands.run`'s own re-check):
        // `GameCore.tick()` already never reaches this call for a LAN client
        // (the whole branch returns earlier), but a test harness calling this
        // function directly should get the same host-only guarantee.
        guard !isLANClientWorld else { return }
        let w = world
        let tick = Int64(rpgSimulationTick)
        if eventBus.hasAnySubscription {
            runObservableBuiltInDiff(w, tick: tick)
        }
        eventBus.runDeliveryPhase(tick: tick)
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
            diffFields(worldDiffFieldsFor(ref), live: live, ref: ref, tick: tick)
        }
        for e in w.entities {
            guard let ent = e as? Entity, !ent.dead, !ent.lanReplicatedMirror, !(ent is LANRemotePlayerEntity) else { continue }
            let ref = scriptRef(for: ent)
            guard eventBus.hasAttributeChangedInterest(in: ref) else { continue }
            guard case .live(let live) = attributeStoreGraph.resolve(ref) else { continue }
            var fields = Self.entityDiffFields
            if ent is Player { fields += Self.playerOnlyDiffFields }
            diffFields(fields, live: live, ref: ref, tick: tick)
            diffPosition(live: live, ref: ref, entity: ent, tick: tick)
        }
    }

    private var attributeStoreGraph: ObjectGraph { ObjectGraph(host: self) }

    private static let entityDiffFields = ["health", "max_health", "on_fire", "dead", "target", "sitting", "baby", "tamed"]
    private static let playerOnlyDiffFields = ["hunger", "xp_level", "game_mode", "dimension", "held_item"]

    private func worldDiffFieldsFor(_ ref: ObjectRef) -> [String] {
        switch ref {
        case .world: return ["difficulty"]
        case .dimension: return ["day_phase", "raining", "thundering"]
        default: return []
        }
    }

    private func diffFields(_ fields: [String], live: LiveObject, ref: ObjectRef, tick: Int64) {
        guard !fields.isEmpty else { return }
        var baseline = scripting.diffBaselines[ref.canonical] ?? [:]
        let hadBaseline = scripting.diffBaselines[ref.canonical] != nil
        for name in fields {
            guard case .value(let current) = BuiltInAttributes.get(live, name: name, host: self) else { continue }
            let previous = baseline[name]
            baseline[name] = current
            guard hadBaseline, previous != current else { continue }
            eventBus.raise(
                kind: .attributeChanged, subject: ref,
                payload: ["key": .string(name), "old": previous ?? .null, "new": current],
                source: .engine, tick: tick
            )
            if name == "day_phase" {
                eventBus.raise(
                    kind: .dimDayPhaseChanged, subject: ref,
                    payload: ["old": previous ?? .null, "new": current], source: .engine, tick: tick
                )
            } else if name == "raining" || name == "thundering" {
                eventBus.raise(
                    kind: .dimWeatherChanged, subject: ref,
                    payload: ["key": .string(name), "old": previous ?? .null, "new": current],
                    source: .engine, tick: tick
                )
            } else if name == "xp_level", case (.int(let oldLevel)?, .int(let newLevel)) = (previous, current),
                      newLevel > oldLevel {
                // event-bus (change 1b): `player.leveled` (design.md §7.2,
                // "addXP"). `Player.swift`'s `addXP` is untouched by this
                // change — derived from the diff instead of a direct funnel
                // (§6.6 already computes `xp_level`'s old/new every phase for
                // `attribute.changed`; a second, semantically-named event on
                // an actual increase costs nothing extra to compute).
                eventBus.raise(
                    kind: .playerLeveled, subject: ref,
                    payload: ["old": previous ?? .null, "new": current], source: .engine, tick: tick
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
            source: .engine, tick: tick, excludeFromRecent: true
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
        eventBus.dropScriptOwnedSubscriptions(ownedBy: refs)
        // A block-id-change drop queued earlier this tick for a cell in this
        // chunk (§6.7) must be applied now, before `chunkRecord()` snapshots
        // `objectRecords` for persistence — otherwise a record already fully
        // delivered (`block.replaced`) could still get saved.
        for drop in w.pendingObjectRecordDrops where drop.chunk === chunk {
            if let current = chunk.objectRecords[drop.cellIndex], current.revision == drop.expectedRevision {
                chunk.objectRecords.removeValue(forKey: drop.cellIndex)
            }
        }
        w.pendingObjectRecordDrops.removeAll { $0.chunk === chunk }
        for ref in refs {
            scripting.diffBaselines.removeValue(forKey: ref.canonical)
            scripting.diffBaselines.removeValue(forKey: ref.canonical + "#pos")
        }
    }
}
