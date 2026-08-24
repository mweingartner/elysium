// EventBusFunnelTests.swift — event-bus (change 1b). "Every v1 event fires
// from its real funnel": each test below drives the actual production call
// site named in design.md §7.2's catalog table (`World.setBlock`,
// `Interact.placeBlock`, `LivingEntity.hurt`, `GameCore.respawnPlayer`, …) —
// never `EventBus.raise` directly — and asserts the right typed event comes
// out the other end. `EventBusTests.swift` covers the engine itself
// (ordering, coalescing, caps, persistence); this file covers wiring.

import XCTest
@testable import ElysiumCore

@MainActor
final class EventBusFunnelTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    // MARK: - bare-`World` funnels (no `GameCore` needed — `world.hooks`
    // wiring is asserted directly, exactly like `hookWorld` wires it for real)

    private func makeWorld() -> (World, Chunk) {
        let world = World(dim: .overworld, seed: 7)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.set(0, 63, 0, cell(B.stone))
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        return (world, chunk)
    }

    func testBlockPlacedFiresFromInteractPlaceBlock() {
        let (world, _) = makeWorld()
        let player = Player(world: world)
        player.setGameMode(GameMode.creative)
        player.setPos(4.5, 64, 4.5)
        player.inventory[0] = stack("dirt", 1)
        player.selectedSlot = 0
        var captured: (EventKind, ObjectRef)?
        world.hooks.raiseScriptEvent = { kind, subject, _, _, _ in captured = (kind, subject) }
        let hit = RaycastHit(x: 0, y: 63, z: 0, face: Dir.up, cell: Int(cell(B.stone)), t: 1, px: 0.5, py: 64, pz: 0.5)
        XCTAssertTrue(placeBlock(InteractCtx(world: world, player: player), hit, Int(B.dirt), player.mainHand!))
        XCTAssertEqual(captured?.0, .blockPlaced)
        XCTAssertEqual(captured?.1, .block(dim: .overworld, x: 0, y: 64, z: 0))
    }

    func testBlockBrokenFiresFromInteractFinishBreaking() {
        let (world, _) = makeWorld()
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        var captured: (EventKind, ObjectRef)?
        world.hooks.raiseScriptEvent = { kind, subject, _, _, _ in
            if kind == .blockBroken { captured = (kind, subject) }
        }
        finishBreaking(InteractCtx(world: world, player: player), 0, 63, 0)
        XCTAssertEqual(captured?.0, .blockBroken)
        XCTAssertEqual(captured?.1, .block(dim: .overworld, x: 0, y: 63, z: 0))
    }

    // `block.changed`'s funnel is the pre-filtered `EventBus.recordBlockChange`,
    // called from `GameCore.hookWorld`'s `onBlockChanged` closure directly —
    // *not* through the generic `world.hooks.raiseScriptEvent` seam every
    // other `World`-level funnel above uses. A bare `World` (no `GameCore`)
    // never wires that closure at all, so this pair needs a real `GameCore`.
    func testBlockChangedFiresFromWorldSetBlockWhenARecordExists() throws {
        let game = makeGameInWorld(label: "blockchanged-yes")
        let chunk = putChunk(in: game.world, cx: 0, cz: 0)
        let ref = ObjectRef.block(dim: game.world.dim, x: 0, y: game.world.info.minY + 1, z: 0)
        XCTAssertTrue(game.attributeStore.define(ref, "guard", .bool(true), readonly: true).isSuccessValue)
        var deliveredKinds: [EventKind] = []
        game.eventBus.delivery = { event, _ in deliveredKinds.append(event.kind) }
        game.world.setBlock(0, game.world.info.minY + 1, 0, Int(cell(B.dirt)))
        game.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertTrue(deliveredKinds.contains(.blockChanged))
        _ = chunk
    }

    func testBlockChangedIsANoOpWhenNoRecordOrSubscriptionExists() {
        let game = makeGameInWorld(label: "blockchanged-no")
        _ = putChunk(in: game.world, cx: 0, cz: 0)
        game.eventBus.runDeliveryPhase(tick: 0) // drain `player.joined` from `createWorld` first
        var deliveredBlockChanged = false
        game.eventBus.delivery = { event, _ in if event.kind == .blockChanged { deliveredBlockChanged = true } }
        game.world.setBlock(0, game.world.info.minY + 1, 0, Int(cell(B.dirt)))
        game.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertFalse(deliveredBlockChanged, "the zero-scripts fast path must never even decode block state")
    }

    /// Builds and installs a real (non-worldgen) chunk at `(cx, cz)` — a
    /// freshly `createWorld`-ed `GameCore` in a test has no chunks resident
    /// yet (worldgen is asynchronous and nothing here drives a tick loop).
    @discardableResult
    private func putChunk(in world: World, cx: Int, cz: Int) -> Chunk {
        let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
        chunk.set(0, world.info.minY + 1, 0, cell(B.stone))
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        return chunk
    }

    func testBlockNeighborChangedFiresOnlyForACellWithARecord() {
        let (world, chunk) = makeWorld()
        chunk.set(1, 63, 0, cell(B.stone))
        let cellIndex = chunk.index(0, 63, 0)
        chunk.objectRecords[cellIndex] = ObjectRecord(
            entries: ["g": .value(.bool(true), readonly: true, provenance: Provenance(createdBy: .player, createdTick: 0))]
        )
        var captured: (EventKind, ObjectRef)?
        world.hooks.raiseScriptEvent = { kind, subject, _, _, _ in
            if kind == .blockNeighborChanged { captured = (kind, subject) }
        }
        world.notifyBlock(0, 63, 0, 1, 63, 0)
        XCTAssertEqual(captured?.0, .blockNeighborChanged)
        XCTAssertEqual(captured?.1, .block(dim: .overworld, x: 0, y: 63, z: 0))
    }

    func testEntitySpawnedAndRemovedFireFromWorldAddRemoveEntity() {
        let (world, _) = makeWorld()
        let cow = Cow(world: world)
        cow.setPos(2, 64, 2)
        var kinds: [EventKind] = []
        world.hooks.raiseScriptEvent = { kind, subject, _, _, _ in
            guard subject == .entity(uid: cow.id) else { return }
            kinds.append(kind)
        }
        world.addEntity(cow)
        world.removeEntity(cow)
        XCTAssertEqual(kinds, [.entitySpawned, .entityRemoved])
    }

    func testEntitySpawnedIsSkippedForTheLocalPlayerRefAndUsesPlayerRef() {
        let (world, _) = makeWorld()
        let player = Player(world: world)
        player.setPos(1, 64, 1)
        var captured: ObjectRef?
        world.hooks.raiseScriptEvent = { kind, subject, _, _, _ in
            if kind == .entitySpawned { captured = subject }
        }
        world.addEntity(player)
        XCTAssertEqual(captured, .player, "the local player must never be reported as entity(uid:)")
    }

    func testEntityDamagedDiedHealedFireFromLivingEntityHurtDieHeal() {
        let (world, _) = makeWorld()
        let zombie = Zombie(world: world)
        zombie.setPos(0.5, 64, 0.5)
        world.addEntity(zombie)
        var kinds: [EventKind] = []
        var amounts: [Double] = []
        world.hooks.raiseScriptEvent = { kind, subject, payload, _, _ in
            guard subject == .entity(uid: zombie.id) else { return }
            kinds.append(kind)
            if case .number(let a)? = payload["amount"] { amounts.append(a) }
        }
        XCTAssertTrue(zombie.hurt(5, "player"))
        XCTAssertTrue(kinds.contains(.entityDamaged))
        XCTAssertEqual(amounts.first, 5)

        zombie.heal(3)
        XCTAssertTrue(kinds.contains(.entityHealed))

        zombie.die("player")
        XCTAssertTrue(kinds.contains(.entityDied))
    }

    func testEntityTargetChangedFiresOnlyOnActualChange() {
        let (world, _) = makeWorld()
        let zombie = Zombie(world: world)
        let cow = Cow(world: world)
        zombie.setPos(0, 64, 0)
        cow.setPos(1, 64, 1)
        world.addEntity(zombie)
        world.addEntity(cow)
        var fireCount = 0
        world.hooks.raiseScriptEvent = { kind, subject, _, _, _ in
            if kind == .entityTargetChanged, subject == .entity(uid: zombie.id) { fireCount += 1 }
        }
        zombie.setTarget(cow)
        zombie.setTarget(cow) // reasserting the same target must not re-fire
        XCTAssertEqual(fireCount, 1)
        zombie.setTarget(nil)
        XCTAssertEqual(fireCount, 2)
    }

    func testPlayerAttackedFiresFromCombatPlayerAttack() {
        let (world, _) = makeWorld()
        let player = Player(world: world)
        player.setPos(0, 64, 0)
        let zombie = Zombie(world: world)
        zombie.setPos(1, 64, 0)
        world.addEntity(player)
        world.addEntity(zombie)
        var captured: (EventKind, ObjectRef)?
        world.hooks.raiseScriptEvent = { kind, subject, payload, _, _ in
            if kind == .playerAttacked {
                captured = (kind, subject)
                XCTAssertEqual(payload["target"], .ref(ObjectRef.entity(uid: zombie.id).canonical))
            }
        }
        playerAttack(player, zombie)
        XCTAssertEqual(captured?.0, .playerAttacked)
        XCTAssertEqual(captured?.1, .player)
    }

    func testExplosionFiresFromExplode() {
        let (world, _) = makeWorld()
        var captured: (EventKind, ObjectRef)?
        world.hooks.raiseScriptEvent = { kind, subject, _, _, _ in
            if kind == .explosion { captured = (kind, subject) }
        }
        explode(world, 0.5, 64.5, 0.5, 2, false, nil)
        XCTAssertEqual(captured?.0, .explosion)
        XCTAssertEqual(captured?.1, .dimension(.overworld))
    }

    // MARK: - `GameCore`-level funnels (direct `eventBus.raise` call sites)

    private func makeGameInWorld(label: String) -> GameCore {
        let game = PersistenceTestSupport.makeGame(owner: self, label: label)
        game.createWorld(name: "Funnel \(label)", seedText: "9", mode: GameMode.survival, difficulty: 2)
        return game
    }

    func testPlayerJoinedFiresFromEnterWorld() {
        var kinds: [EventKind] = []
        let game = PersistenceTestSupport.makeGame(owner: self, label: "joined")
        // `eventBus` is replaced at `enterWorld`/`createWorld` — this test
        // observes recent events *after* the world is up, which is exactly
        // what `/events recent` would show a player immediately afterward.
        game.createWorld(name: "Joined", seedText: "1", mode: GameMode.survival, difficulty: 2)
        kinds = game.eventBus.recentEvents().map(\.kind)
        XCTAssertTrue(kinds.contains(.playerJoined))
    }

    func testPlayerLeftFiresFromExitToTitle() {
        let game = makeGameInWorld(label: "left")
        game.eventBus.recentEvents() // drain nothing — just confirm the bus is alive
        var captured = false
        game.eventBus.delivery = { event, _ in if event.kind == .playerLeft { captured = true } }
        game.exitToTitle()
        // `exitToTitle` never runs another tick phase, so the raised event
        // never reaches `delivery` — assert it was queued instead (still the
        // same `EventBus` instance; `finalizeAndSave`/teardown don't reset it
        // themselves, only the *next* `enterWorld` does).
        XCTAssertTrue(game.eventBus.recentEvents().map(\.kind).contains(.playerLeft))
        _ = captured
    }

    func testPlayerRespawnedFiresFromRespawnPlayer() {
        let game = makeGameInWorld(label: "respawn")
        game.player.hurt(1_000, "test")
        XCTAssertGreaterThan(game.player.deathTime, 0)
        game.respawnPlayer()
        XCTAssertTrue(game.eventBus.recentEvents().map(\.kind).contains(.playerRespawned))
    }

    func testPlayerAdvancementFiresFromAdvance() {
        let game = makeGameInWorld(label: "advancement")
        game.advance("nether_root")
        let events = game.eventBus.recentEvents()
        XCTAssertTrue(events.contains { $0.kind == .playerAdvancement && $0.payload["id"] == .string("nether_root") })
    }

    func testWorldDifficultyChangedFiresOnlyOnActualChange() {
        let game = makeGameInWorld(label: "difficulty")
        game.setDifficulty(game.world.difficulty) // no-op: must not fire
        XCTAssertFalse(game.eventBus.recentEvents().contains { $0.kind == .worldDifficultyChanged })
        game.setDifficulty(game.world.difficulty == 3 ? 0 : 3)
        XCTAssertTrue(game.eventBus.recentEvents().contains { $0.kind == .worldDifficultyChanged })
    }

    func testWorldGameruleChangedFiresOnlyOnActualChange() {
        let game = makeGameInWorld(label: "gamerule")
        // A never-set rule defaults to 0 (`worldRec?.gameRules[rule] ?? 0`) —
        // set it to a genuinely different value first, then repeat that same
        // value to prove the second call doesn't re-fire.
        game.setGameRule("mobGriefing", 1)
        game.setGameRule("mobGriefing", 1)
        let fires = game.eventBus.recentEvents().filter { $0.kind == .worldGameruleChanged }
        XCTAssertEqual(fires.count, 1)
        XCTAssertEqual(fires.first?.payload["key"], .string("mobGriefing"))
    }

    func testAttributeChangedFiresFromAttributeStoreThroughGameCore() {
        let game = makeGameInWorld(label: "attrchange")
        var captured: [String: AttrValue]?
        game.eventBus.delivery = { event, _ in if event.kind == .attributeChanged { captured = event.payload } }
        XCTAssertTrue(game.attributeStore.set(.player, "mood", .string("curious")).isSuccessValue)
        game.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(captured?["key"], .string("mood"))
        XCTAssertEqual(captured?["new"], .string("curious"))
    }

    // MARK: - deferred object-record drop (§6.7)

    func testBlockReplacedIsDeliveredBeforeTheRecordIsDroppedThenDropsAfter() {
        let game = makeGameInWorld(label: "replaced")
        let w = game.world
        putChunk(in: w, cx: 0, cz: 0)
        let x = 0, y = w.info.minY + 1, z = 0
        let ref = ObjectRef.block(dim: w.dim, x: x, y: y, z: z)
        XCTAssertTrue(game.attributeStore.define(ref, "tag", .bool(true), readonly: true).isSuccessValue)
        XCTAssertNotNil(game.attributeStore.record(ref))

        var sawBlockChangedWithRecordStillReadable = false
        game.eventBus.delivery = { event, _ in
            guard event.kind == .blockChanged else { return }
            sawBlockChangedWithRecordStillReadable = game.attributeStore.record(ref) != nil
        }
        w.setBlock(x, y, z, Int(cell(B.dirt))) // a real id change, not same-family
        game.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertTrue(sawBlockChangedWithRecordStillReadable, "the record must survive until after delivery")
        w.drainPendingObjectRecordDrops()
        // `AttributeStore.record` never returns `nil` for a *live* object —
        // an absent entry reads back as a fresh empty `ObjectRecord()` — so
        // "dropped" means empty, not nil.
        XCTAssertEqual(game.attributeStore.record(ref)?.isEmpty, true, "the record must be dropped once delivery has run")
    }

    // MARK: - persistence through the 1a record machinery (design.md §7.3,
    // `WorldRecord.scriptRegistry`)

    func testPersistedSubscriptionSurvivesSaveAndReload() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "sub-reload")
        game.createWorld(name: "Sub Reload", seedText: "1", mode: GameMode.survival, difficulty: 2)
        guard case .success(let sub) = game.eventBus.subscribe(
            subscriber: .player, scriptName: "guard", handler: "on_hit", target: .object(.player),
            event: .playerRespawned, attribute: nil, createdBy: .player, tick: 0
        ) else { return XCTFail("subscribe failed") }
        XCTAssertTrue(game.saveAndFlushChecked())
        let worldID = game.worldRec!.id
        game.exitToTitle()
        game.loadWorld(worldID)
        let reloaded = game.eventBus.listSubscriptions()
        XCTAssertEqual(reloaded.map(\.id), [sub.id])
        XCTAssertEqual(reloaded.first?.scriptName, "guard")
        XCTAssertEqual(reloaded.first?.event, .playerRespawned)
    }

    func testWorldWithNoSubscriptionsOmitsScriptRegistryEntirely() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "sub-empty")
        game.createWorld(name: "Sub Empty", seedText: "1", mode: GameMode.survival, difficulty: 2)
        XCTAssertTrue(game.saveAndFlushChecked())
        let stored = game.db.getWorld(game.worldRec!.id)
        XCTAssertEqual(stored?.scriptRegistry, "")
    }

    // MARK: - phase diff (§6.6 point 3 / §7.5 step 2)

    func testAttributeChangedFiresFromTheObservableBuiltInDiffOnHealthChange() {
        let game = makeGameInWorld(label: "diff")
        // A subscription must exist for the diff to bother computing anything
        // (§6.6: "only observed objects pay").
        _ = game.eventBus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .object(.player), event: .attributeChanged,
            attribute: "health", createdBy: .player, tick: 0
        )
        game.runEventBusPhase() // baseline tick — must emit nothing yet
        var deliveries: [(String, AttrValue)] = []
        game.eventBus.delivery = { event, targets in
            guard event.kind == .attributeChanged, !targets.isEmpty,
                  case .string(let key)? = event.payload["key"], let newValue = event.payload["new"]
            else { return }
            deliveries.append((key, newValue))
        }
        game.player.health = max(1, game.player.health - 1)
        game.runEventBusPhase()
        XCTAssertTrue(deliveries.contains { $0.0 == "health" })
    }

    // MARK: - commands (/on, /unsubscribe, /events)

    func testOnCommandRegistersASubscriptionAndEventsRecentShowsIt() {
        let game = makeGameInWorld(label: "oncommand")
        let context = game.scriptingCommandContext()
        let onResult = ScriptingCommands.run(command: "on", arguments: ["self", "player.slept", "farm.on_sleep"], context: context)
        XCTAssertTrue(onResult.ok, onResult.lines.joined())
        XCTAssertEqual(game.eventBus.listSubscriptions().count, 1)

        let emitResult = ScriptingCommands.run(command: "events", arguments: ["emit", "self", "player.slept"], context: context)
        XCTAssertTrue(emitResult.ok, emitResult.lines.joined())
        let recentResult = ScriptingCommands.run(command: "events", arguments: ["recent"], context: context)
        XCTAssertTrue(recentResult.lines.contains { $0.contains("player.slept") })

        guard let subID = game.eventBus.listSubscriptions().first?.id else { return XCTFail() }
        let unsubResult = ScriptingCommands.run(command: "unsubscribe", arguments: ["\(subID)"], context: context)
        XCTAssertTrue(unsubResult.ok, unsubResult.lines.joined())
        XCTAssertEqual(game.eventBus.listSubscriptions().count, 0)
    }

    func testOnCommandRefusesAmbiguousOrInvalidGrammar() {
        let game = makeGameInWorld(label: "onbad")
        let context = game.scriptingCommandContext()
        let badEvent = ScriptingCommands.run(command: "on", arguments: ["self", "not a real kind!", "s.h"], context: context)
        XCTAssertFalse(badEvent.ok)
        let badHandler = ScriptingCommands.run(command: "on", arguments: ["self", "player.slept", "nodothere"], context: context)
        XCTAssertFalse(badHandler.ok)
    }
}

private extension Result {
    var isSuccessValue: Bool {
        if case .success = self { return true }
        return false
    }
}
