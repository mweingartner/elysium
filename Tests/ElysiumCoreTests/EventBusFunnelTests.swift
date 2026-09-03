// EventBusFunnelTests.swift — event-bus integration. These tests drive representative actual
// production producers (`World.setBlock`, `Interact.placeBlock`, `LivingEntity.hurt`, observable
// diffs, LAN proxy hydration, `GameCore` input paths, …), never a substitute test-only funnel.
// EventBusTests covers ordering/coalescing/caps/persistence; registry/schema tests exhaustively
// cover the complete standard-event catalog while this file proves its distinct wiring patterns.

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
        var captured: (EventKind, ObjectRef, [String: AttrValue])?
        world.hooks.raiseScriptEvent = { kind, subject, payload, _, _ in
            if kind == .blockBroken { captured = (kind, subject, payload) }
        }
        finishBreaking(InteractCtx(world: world, player: player), 0, 63, 0)
        XCTAssertEqual(captured?.0, .blockBroken)
        XCTAssertEqual(captured?.1, .block(dim: .overworld, x: 0, y: 63, z: 0))
        XCTAssertEqual(captured?.2["blockName"], .string("stone"))
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
        XCTAssertTrue(eventFunnelResultSucceeded(
            game.attributeStore.define(ref, "guard", .bool(true), readonly: true)
        ))
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

    func testScriptBuiltInBlockMutationRaisesAttributeChangedWithAuthorAndMetadata() {
        let game = makeGameInWorld(label: "block-attribute-change")
        _ = putChunk(in: game.world, cx: 0, cz: 0)
        let y = game.world.info.minY + 1
        let ref = ObjectRef.block(dim: game.world.dim, x: 0, y: y, z: 0)
        _ = game.eventBus.subscribe(
            subscriber: .player, scriptName: "meta_watch", handler: "changed",
            target: .object(ref), event: .attributeChanged, attribute: "meta",
            createdBy: .player, tick: 0
        )
        guard case .live(let live) = ObjectGraph(host: game).resolve(ref) else {
            return XCTFail("fixture block is not live")
        }
        var captured: ScriptEvent?
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty, event.kind == .attributeChanged { captured = event }
        }

        guard case .ok = game.setScriptBuiltInAttribute(
            live, ref: ref, name: "meta", value: .int(3), author: .script(owner: .player, name: "builder")
        ) else { return XCTFail("metadata write failed") }
        game.eventBus.runDeliveryPhase(tick: 0)

        XCTAssertEqual(captured?.payload["key"], .string("meta"))
        XCTAssertEqual(captured?.payload["old"], .int(0))
        XCTAssertEqual(captured?.payload["new"], .int(3))
        XCTAssertEqual(captured?.source, .script(owner: .player, name: "builder"))
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

    func testBlockNeighborChangedFiresForACellWithARecord() {
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

    func testBlockNeighborChangedFiresForAnInterestedPlainCell() {
        let (world, chunk) = makeWorld()
        chunk.set(1, 63, 0, cell(B.stone))
        let subject = ObjectRef.block(dim: .overworld, x: 0, y: 63, z: 0)
        XCTAssertNil(chunk.objectRecords[chunk.index(0, 63, 0)])
        world.hooks.hasScriptEventInterest = { kind, candidate, type in
            kind == .blockNeighborChanged && candidate == subject && type == "stone"
        }
        var captured: ObjectRef?
        world.hooks.raiseScriptEvent = { kind, eventSubject, _, _, _ in
            if kind == .blockNeighborChanged { captured = eventSubject }
        }
        world.notifyBlock(0, 63, 0, 1, 63, 0)
        XCTAssertEqual(captured, subject)
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

    func testLANPlayerUsesCanonicalLifecycleAndObservableBuiltInEvents() {
        let game = makeGameInWorld(label: "lan-player-events")
        let ref = ObjectRef.lanPlayer(peerID: "peer-a")
        for event in [EventKind.entitySpawned, .entityRemoved] {
            _ = game.eventBus.subscribe(
                subscriber: .player, scriptName: event.rawValue.replacingOccurrences(of: ".", with: "_"),
                handler: "handle", target: .object(ref), event: event,
                attribute: nil, createdBy: .player, tick: 0
            )
        }
        _ = game.eventBus.subscribe(
            subscriber: .player, scriptName: "health", handler: "changed",
            target: .object(ref), event: .attributeChanged, attribute: "health",
            createdBy: .player, tick: 0
        )
        var delivered: [ScriptEvent] = []
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty { delivered.append(event) }
        }
        var state = LANPlayerState(
            playerID: "peer-a", displayName: "Alex", x: 2, y: 65, z: 2,
            yaw: 0, pitch: 0, health: 20, hunger: 20, selectedHotbarSlot: 0,
            gameMode: GameMode.survival, dimension: Dim.overworld.rawValue
        )

        _ = applyLANRemotePlayers([state], to: game.world, localPlayerID: nil)
        game.runEventBusPhase()
        XCTAssertTrue(delivered.contains { $0.kind == .entitySpawned && $0.subject == ref })
        delivered.removeAll()

        state.health = 14
        _ = applyLANRemotePlayers([state], to: game.world, localPlayerID: nil)
        game.runEventBusPhase()
        let healthEvent = delivered.first { $0.kind == .attributeChanged }
        XCTAssertEqual(healthEvent?.subject, ref)
        XCTAssertEqual(healthEvent?.payload["key"], .string("health"))
        XCTAssertEqual(healthEvent?.payload["old"], .number(20))
        XCTAssertEqual(healthEvent?.payload["new"], .number(14))
        delivered.removeAll()

        XCTAssertTrue(removeLANRemotePlayer("peer-a", from: game.world))
        game.eventBus.runDeliveryPhase(tick: game.currentTick)
        XCTAssertTrue(delivered.contains { $0.kind == .entityRemoved && $0.subject == ref })
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
        var payloads: [EventKind: [String: AttrValue]] = [:]
        world.hooks.raiseScriptEvent = { kind, subject, payload, _, _ in
            guard subject == .entity(uid: zombie.id) else { return }
            kinds.append(kind)
            payloads[kind] = payload
            if case .number(let a)? = payload["amount"] { amounts.append(a) }
        }
        XCTAssertTrue(zombie.hurt(5, "test_cause"))
        XCTAssertTrue(kinds.contains(.entityDamaged))
        XCTAssertEqual(amounts.first, 5)
        XCTAssertEqual(payloads[.entityDamaged]?["cause"], .string("test_cause"))
        XCTAssertNil(payloads[.entityDamaged]?["source"], "payload must not overwrite ev.source provenance")

        zombie.heal(3)
        XCTAssertTrue(kinds.contains(.entityHealed))

        zombie.die("test_death")
        XCTAssertTrue(kinds.contains(.entityDied))
        XCTAssertEqual(payloads[.entityDied]?["cause"], .string("test_death"))
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
        world.hooks.raiseScriptEvent = { kind, subject, payload, _, subjectType in
            if kind == .playerAttacked {
                captured = (kind, subject)
                XCTAssertEqual(payload["target"], .ref(ObjectRef.entity(uid: zombie.id).canonical))
                XCTAssertNil(subjectType, "the event subject is the player, not the attacked entity family")
            }
        }
        playerAttack(player, zombie)
        XCTAssertEqual(captured?.0, .playerAttacked)
        XCTAssertEqual(captured?.1, .player)
    }

    func testPlayerAttackedKindFilterCannotMatchTheTargetsEntityType() {
        let game = makeGameInWorld(label: "player-attacked-subject-type")
        let zombie = Zombie(world: game.world)
        zombie.setPos(game.player.x + 1, game.player.y, game.player.z)
        game.world.addEntity(zombie)
        guard case .success = game.eventBus.subscribe(
            subscriber: .player,
            scriptName: "wrong_family",
            handler: "attacked",
            target: .kind(.player, typeFilter: "zombie"),
            event: .playerAttacked,
            attribute: nil,
            createdBy: .player,
            tick: 0
        ) else { return XCTFail("player attacked subscription failed") }
        var deliveries = 0
        game.eventBus.delivery = { event, targets in
            if event.kind == .playerAttacked { deliveries += targets.count }
        }

        playerAttack(game.player, zombie)
        game.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(deliveries, 0)
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

    @discardableResult
    private func prepareMiningWall(in game: GameCore, block: UInt16 = B.stone) -> Chunk {
        let world = game.world
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        for z in 0..<CHUNK_W {
            for x in 0..<CHUNK_W {
                chunk.set(x, 64, z, cell(B.dirt))
            }
        }
        for y in 66...67 {
            for x in 0..<CHUNK_W {
                chunk.set(x, y, 10, cell(block))
            }
        }
        chunk.status = .generated
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        game.player.setPos(8.5, 65, 8.5)
        game.player.yaw = 0
        game.player.pitch = 0
        game.player.vx = 0
        game.player.vy = 0
        game.player.vz = 0
        return chunk
    }

    private func stepOneTick(_ game: GameCore) {
        _ = game.frame(dtMs: TICK_MS)
    }

    func testBlockToolStrikeFiresOnceAtMiningStartOnlyWithATool() {
        let game = makeGameInWorld(label: "tool-strike")
        _ = prepareMiningWall(in: game)
        game.player.mainHand = ItemStack(iid("wooden_pickaxe"), 1)

        game.mouseDown(0)
        stepOneTick(game)
        for _ in 0..<3 { stepOneTick(game) }

        let strikes = game.eventBus.recentEvents().filter { $0.kind == .blockToolStrike }
        XCTAssertEqual(strikes.count, 1, "held mining and presentation hit repeats must not re-fire")
        XCTAssertEqual(strikes.first?.subject, .block(dim: .overworld, x: 8, y: 66, z: 10))
        XCTAssertEqual(strikes.first?.payload["by"], .ref(ObjectRef.player.canonical))
        XCTAssertEqual(strikes.first?.payload["item"], .string("wooden_pickaxe"))
        XCTAssertEqual(strikes.first?.payload["blockName"], .string("stone"))
        XCTAssertEqual(strikes.first?.payload["face"], .string("north"))
        XCTAssertEqual(strikes.first?.payload["toolType"], .string("pickaxe"))
        XCTAssertEqual(strikes.first?.payload["tier"], .int(0))
        XCTAssertEqual(strikes.first?.payload["instant"], .bool(false))

        game.mouseUp(0)
        stepOneTick(game)
        game.player.mainHand = nil
        game.mouseDown(0)
        stepOneTick(game)
        XCTAssertEqual(
            game.eventBus.recentEvents().filter { $0.kind == .blockToolStrike }.count, 1,
            "empty-hand mining is not a tool strike"
        )
    }

    func testBlockToolStrikeFiresOnceWhenTheToolHitsAnUnbreakableBlock() {
        let game = makeGameInWorld(label: "tool-strike-unbreakable")
        _ = prepareMiningWall(in: game, block: B.bedrock)
        game.player.mainHand = ItemStack(iid("wooden_pickaxe"), 1)

        game.mouseDown(0)
        for _ in 0..<4 { stepOneTick(game) }

        let strikes = game.eventBus.recentEvents().filter { $0.kind == .blockToolStrike }
        XCTAssertEqual(strikes.count, 1)
        XCTAssertEqual(strikes.first?.payload["blockName"], .string("bedrock"))
        XCTAssertEqual(game.world.getBlock(8, 66, 10), Int(cell(B.bedrock)))
    }

    func testBlockToolStrikeMarksCreativeFirstStrikeAsInstant() {
        let game = makeGameInWorld(label: "tool-strike-creative")
        _ = prepareMiningWall(in: game)
        game.player.setGameMode(GameMode.creative)
        game.player.mainHand = ItemStack(iid("diamond_pickaxe"), 1)
        game.mouseDown(0)
        stepOneTick(game)
        let strike = game.eventBus.recentEvents().last { $0.kind == .blockToolStrike }
        XCTAssertEqual(strike?.payload["instant"], .bool(true))
    }

    func testBlockUsedSnapshotsHeldItemBeforeInteractionMutatesIt() {
        let game = makeGameInWorld(label: "block-use-snapshot")
        let chunk = prepareMiningWall(in: game, block: B.cauldron)
        chunk.set(8, 66, 10, cell(B.cauldron))
        game.player.mainHand = ItemStack(iid("water_bucket"), 1)
        game.mouseDown(2)
        let events = game.eventBus.recentEvents().filter { $0.kind == .blockUsed }
        let event = events.last
        XCTAssertEqual(events.count, 1, "one interactive use pulse must publish exactly once")
        XCTAssertEqual(game.player.mainHand.map { itemDef($0.id).name }, "bucket")
        XCTAssertEqual(event?.payload["item"], .string("water_bucket"))
        XCTAssertEqual(event?.subjectType, "cauldron")
    }

    func testInertBlockSecondaryUseRunsItsAttachedHandlerAndRepeatsOncePerPulse() throws {
        let game = makeGameInWorld(label: "inert-block-use")
        _ = prepareMiningWall(in: game)
        let block = ObjectRef.block(dim: .overworld, x: 8, y: 66, z: 10)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try scripts.attach(
            block,
            name: "use_counter",
            source: "self.attrs.use_count = (self.attrs.use_count or 0) + 1",
            mode: .handler,
            triggers: [Trigger(event: .blockUsed, attribute: nil, target: .object(block))],
            by: .player,
            tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()

        game.mouseDown(2)
        game.runEventBusPhase()

        XCTAssertEqual(game.attributeStore.get(block, "use_count"), .int(1))
        XCTAssertEqual(
            game.eventBus.recentEvents().filter { $0.kind == .blockUsed }.count,
            1,
            "an inert target still gets exactly one event for the initial pulse"
        )

        for _ in 0..<4 { stepOneTick(game) }
        XCTAssertEqual(game.attributeStore.get(block, "use_count"), .int(1))
        stepOneTick(game)
        game.runEventBusPhase()
        XCTAssertEqual(game.attributeStore.get(block, "use_count"), .int(2))
        XCTAssertEqual(
            game.eventBus.recentEvents().filter { $0.kind == .blockUsed }.count,
            2,
            "the held-use repeat publishes once, not once per simulation tick"
        )
        game.mouseUp(2)
    }

    func testForemostInertEntityWinsSecondaryUseAndRunsOnlyItsAttachedHandler() throws {
        let game = makeGameInWorld(label: "inert-entity-use")
        _ = prepareMiningWall(in: game)
        let block = ObjectRef.block(dim: .overworld, x: 8, y: 66, z: 10)
        let entity = Entity(world: game.world)
        entity.setPos(8.5, 65.3, 9.5)
        game.world.addEntity(entity)
        let entityRef = ObjectRef.entity(uid: entity.id)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try scripts.attach(
            block,
            name: "block_counter",
            source: "self.attrs.use_count = (self.attrs.use_count or 0) + 1",
            mode: .handler,
            triggers: [Trigger(event: .blockUsed, attribute: nil, target: .object(block))],
            by: .player,
            tick: 0
        ).get()
        _ = try scripts.attach(
            entityRef,
            name: "entity_counter",
            source: "self.attrs.use_count = (self.attrs.use_count or 0) + 1",
            mode: .handler,
            triggers: [Trigger(event: .entityInteracted, attribute: nil, target: .object(entityRef))],
            by: .player,
            tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()

        game.mouseDown(2)
        game.runEventBusPhase()

        XCTAssertEqual(game.attributeStore.get(entityRef, "use_count"), .int(1))
        XCTAssertNil(game.attributeStore.get(block, "use_count"))
        let interactions = game.eventBus.recentEvents().filter {
            $0.kind == .entityInteracted || $0.kind == .blockUsed
        }
        XCTAssertEqual(interactions.count, 1)
        XCTAssertEqual(interactions.first?.kind, .entityInteracted)
        XCTAssertEqual(interactions.first?.subject, entityRef)
        game.mouseUp(2)
    }

    func testBroaderScriptTargetDoesNotStealExistingNativeEntityInteraction() {
        let game = makeGameInWorld(label: "semantic-use-preserves-native")
        _ = prepareMiningWall(in: game)
        let inert = Entity(world: game.world)
        inert.setPos(8.5, 65.3, 9.1)
        game.world.addEntity(inert)
        let cow = Cow(world: game.world)
        cow.setPos(8.5, 65.3, 9.6)
        game.world.addEntity(cow)
        game.player.mainHand = ItemStack(iid("bucket"), 1)

        game.mouseDown(2)

        XCTAssertEqual(
            game.player.mainHand.map { itemDef($0.id).name }, "milk_bucket",
            "the pre-existing native entity filter must still reach the cow behind an inert entity"
        )
        let event = game.eventBus.recentEvents().last { $0.kind == .entityInteracted }
        XCTAssertEqual(
            event?.subject, .entity(uid: inert.id),
            "the broader scripted target remains the foremost physical object"
        )
        game.mouseUp(2)
    }

    func testSecondaryUseMissAndDeadPlayerDoNotPublishInteractionEvents() {
        let game = makeGameInWorld(label: "use-guards")
        _ = prepareMiningWall(in: game)
        game.player.pitch = -.pi / 2
        game.mouseDown(2)
        game.mouseUp(2)
        XCTAssertFalse(game.eventBus.recentEvents().contains {
            $0.kind == .entityInteracted || $0.kind == .blockUsed
        })

        game.player.pitch = 0
        game.player.dead = true
        game.mouseDown(2)
        game.mouseUp(2)
        XCTAssertFalse(game.eventBus.recentEvents().contains {
            $0.kind == .entityInteracted || $0.kind == .blockUsed
        })
    }

    func testPlayerSleptFiresOnlyFromTheSuccessfulBedUsePath() {
        let (world, chunk) = makeWorld()
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        let bedCell = Int(cell(B.red_bed))
        chunk.set(0, 63, 0, UInt16(bedCell))
        let hit = RaycastHit(
            x: 0, y: 63, z: 0, face: Dir.up, cell: bedCell, t: 1,
            px: 0.5, py: 64, pz: 0.5
        )
        var events: [(EventKind, ObjectRef, EventSource)] = []
        world.hooks.raiseScriptEvent = { kind, subject, _, source, _ in
            events.append((kind, subject, source))
        }

        world.dayTime = 1_000
        XCTAssertTrue(useBlock(InteractCtx(world: world, player: player), hit))
        XCTAssertFalse(events.contains { $0.0 == .playerSlept })

        world.dayTime = 18_000
        XCTAssertTrue(useBlock(InteractCtx(world: world, player: player), hit))
        XCTAssertEqual(player.sleepTicks, 1)
        let slept = events.filter { $0.0 == .playerSlept }
        XCTAssertEqual(slept.count, 1)
        XCTAssertEqual(slept.first?.1, .player)
        XCTAssertEqual(slept.first?.2, .player)
    }

    func testEntityInteractedSnapshotsHeldItemBeforeInteractionMutatesIt() {
        let game = makeGameInWorld(label: "entity-use-snapshot")
        _ = prepareMiningWall(in: game)
        let cow = Cow(world: game.world)
        // A cow is only 1.4 blocks tall; lift it slightly so the level camera ray at eye height
        // crosses its hitbox before reaching the wall.
        cow.setPos(8.5, 65.3, 9.5)
        game.world.addEntity(cow)
        game.player.mainHand = ItemStack(iid("bucket"), 1)
        game.mouseDown(2)
        let event = game.eventBus.recentEvents().last { $0.kind == .entityInteracted }
        XCTAssertEqual(game.player.mainHand.map { itemDef($0.id).name }, "milk_bucket")
        XCTAssertEqual(event?.subject, .entity(uid: cow.id))
        XCTAssertEqual(event?.payload["item"], .string("bucket"))
        XCTAssertEqual(event?.subjectType, "cow")
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
        _ = game.eventBus.recentEvents() // drain nothing — just confirm the bus is alive
        var captured = false
        game.eventBus.delivery = { event, _ in if event.kind == .playerLeft { captured = true } }
        game.exitToTitle()
        XCTAssertTrue(game.eventBus.recentEvents().map(\.kind).contains(.playerLeft))
        XCTAssertTrue(captured, "player.left must be delivered before the script runtime is torn down")
    }

    func testPlayerRespawnedFiresFromRespawnPlayer() {
        let game = makeGameInWorld(label: "respawn")
        game.player.hurt(1_000, "test")
        XCTAssertGreaterThan(game.player.deathTime, 0)
        game.respawnPlayer()
        XCTAssertTrue(game.eventBus.recentEvents().map(\.kind).contains(.playerRespawned))
    }

    func testPlayerDimensionChangedFiresFromCrossDimensionRespawn() throws {
        let game = makeGameInWorld(label: "dimension-changed")
        let nether = try XCTUnwrap(game.worlds[.nether])
        let chunk = putChunk(in: nether, cx: 0, cz: 0)
        chunk.status = .generated
        let x = 0, y = nether.info.minY + 1, z = 0
        chunk.set(x, y, z, cell(B.respawn_anchor, 1))
        game.player.spawnDim = Dim.nether.rawValue
        game.player.spawnPoint = (x, y, z)

        game.respawnPlayer()

        let event = try XCTUnwrap(
            game.eventBus.recentEvents().last { $0.kind == .playerDimensionChanged }
        )
        XCTAssertEqual(event.subject, .player)
        XCTAssertEqual(event.payload["old"], .string("overworld"))
        XCTAssertEqual(event.payload["new"], .string("nether"))
        XCTAssertEqual(event.source, .player)
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
        XCTAssertTrue(eventFunnelResultSucceeded(
            game.attributeStore.set(.player, "mood", .string("curious"))
        ))
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
        XCTAssertTrue(eventFunnelResultSucceeded(
            game.attributeStore.define(ref, "tag", .bool(true), readonly: true)
        ))
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

    func testCustomBlockAttributeChangedDeliversThroughAnActualBlockTypeFilter() {
        let game = makeGameInWorld(label: "attr-type-block")
        let world = game.world
        _ = putChunk(in: world, cx: 0, cz: 0)
        let ref = ObjectRef.block(
            dim: world.dim, x: 0, y: world.info.minY + 1, z: 0
        )
        guard case .success = game.eventBus.subscribe(
            subscriber: .player,
            scriptName: "block_filter",
            handler: "changed",
            target: .kind(.block, typeFilter: "stone"),
            event: .attributeChanged,
            attribute: "mood",
            createdBy: .player,
            tick: 0
        ) else { return XCTFail("block type-filter subscription failed") }
        var delivered: [ScriptEvent] = []
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty { delivered.append(event) }
        }

        XCTAssertTrue(eventFunnelResultSucceeded(
            game.attributeStore.set(ref, "mood", .string("watchful"))
        ))
        game.eventBus.runDeliveryPhase(tick: 0)

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.subject, ref)
        XCTAssertEqual(delivered.first?.subjectType, "stone")
    }

    func testBlockBuiltInReplacementNotifiesOldAndNewFamilyAttributeObservers() throws {
        let game = makeGameInWorld(label: "attr-type-replacement")
        let world = game.world
        _ = putChunk(in: world, cx: 0, cz: 0)
        let ref = ObjectRef.block(dim: world.dim, x: 0, y: world.info.minY + 1, z: 0)
        var idsByType: [String: UInt64] = [:]
        for type in ["stone", "dirt"] {
            guard case .success(let subscription) = game.eventBus.subscribe(
                subscriber: .player, scriptName: type, handler: "changed",
                target: .kind(.block, typeFilter: type), event: .attributeChanged,
                attribute: "name", createdBy: .player, tick: 0
            ) else { return XCTFail("subscription failed for \(type)") }
            idsByType[type] = subscription.id
        }
        var deliveredIDs = Set<UInt64>()
        game.eventBus.delivery = { event, targets in
            if event.kind == .attributeChanged { deliveredIDs.formUnion(targets.map(\.id)) }
        }

        world.setBlock(0, world.info.minY + 1, 0, Int(cell(B.dirt)))
        game.eventBus.runDeliveryPhase(tick: game.currentTick)

        XCTAssertEqual(deliveredIDs, Set(idsByType.values))
        XCTAssertEqual(
            game.eventBus.recentEvents().last { $0.kind == .attributeChanged }?.subject,
            ref
        )
    }

    func testBlockEntityAttributeObservationPublishesCreateRemoveAndRecreateTransitions() {
        let game = makeGameInWorld(label: "block-entity-attribute-transitions")
        let world = game.world
        let chunk = putChunk(in: world, cx: 0, cz: 0)
        let x = 0, y = world.info.minY + 1, z = 0
        chunk.set(x, y, z, cell(B.chest))
        let ref = ObjectRef.block(dim: world.dim, x: x, y: y, z: z)
        _ = game.eventBus.subscribe(
            subscriber: .player, scriptName: "be_watch", handler: "changed",
            target: .object(ref), event: .attributeChanged, attribute: "be.name",
            createdBy: .player, tick: 0
        )
        game.runEventBusPhase() // missing block entity establishes a null baseline
        var transitions: [(AttrValue?, AttrValue?)] = []
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty, event.kind == .attributeChanged,
               event.payload["key"] == .string("be.name") {
                transitions.append((event.payload["old"], event.payload["new"]))
            }
        }

        let first = makeContainerBE(x, y, z, 27)
        first.name = "First"
        world.setBlockEntity(first)
        game.runEventBusPhase()
        world.removeBlockEntity(x, y, z)
        game.runEventBusPhase()
        let second = makeContainerBE(x, y, z, 27)
        second.name = "Second"
        world.setBlockEntity(second)
        game.runEventBusPhase()

        XCTAssertEqual(transitions.count, 3)
        XCTAssertEqual(transitions[0].0, .null)
        XCTAssertEqual(transitions[0].1, .string("First"))
        XCTAssertEqual(transitions[1].0, .string("First"))
        XCTAssertEqual(transitions[1].1, .null)
        XCTAssertEqual(transitions[2].0, .null)
        XCTAssertEqual(transitions[2].1, .string("Second"))
    }

    func testEntityTypeFilterDeliversObservableHealthAndPositionChanges() {
        let game = makeGameInWorld(label: "attr-type-entity")
        let cow = Cow(world: game.world)
        cow.setPos(2, 65, 2)
        game.world.addEntity(cow)
        let ref = ObjectRef.entity(uid: cow.id)
        for attribute in ["health", "pos"] {
            guard case .success = game.eventBus.subscribe(
                subscriber: .player,
                scriptName: "cow_\(attribute)",
                handler: "changed",
                target: .kind(.entity, typeFilter: "cow"),
                event: .attributeChanged,
                attribute: attribute,
                createdBy: .player,
                tick: 0
            ) else { return XCTFail("cow \(attribute) subscription failed") }
        }
        game.runEventBusPhase() // establish both observable baselines
        var delivered: [ScriptEvent] = []
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty, event.kind == .attributeChanged { delivered.append(event) }
        }

        cow.health -= 1
        cow.setPos(2.2, 65, 2)
        game.runEventBusPhase()

        XCTAssertEqual(
            Set(delivered.compactMap { event -> String? in
                guard case .string(let key)? = event.payload["key"] else { return nil }
                return key
            }),
            ["health", "pos"]
        )
        XCTAssertTrue(delivered.allSatisfy { $0.subject == ref && $0.subjectType == "cow" })
    }

    func testPlayerLeveledSubscriptionWorksWithoutAttributeChangedInterest() {
        let game = makeGameInWorld(label: "leveled-only")
        _ = game.eventBus.subscribe(
            subscriber: .player, scriptName: "s", handler: "h", target: .object(.player),
            event: .playerLeveled, attribute: nil, createdBy: .player, tick: 0
        )
        game.runEventBusPhase() // establish the xp_level baseline
        var delivered: [ScriptEvent] = []
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty { delivered.append(event) }
        }
        game.player.xpLevel += 1
        game.runEventBusPhase()
        XCTAssertEqual(delivered.map(\.kind), [.playerLeveled])
        XCTAssertEqual(delivered.first?.payload["old"], .int(0))
        XCTAssertEqual(delivered.first?.payload["new"], .int(1))
    }

    func testDimensionDayPhaseAndWeatherEventsComeFromTheObservableDiffPhase() {
        let game = makeGameInWorld(label: "dimension-semantic-events")
        let ref = ObjectRef.dimension(game.dim)
        for event in [EventKind.dimDayPhaseChanged, .dimWeatherChanged] {
            _ = game.eventBus.subscribe(
                subscriber: .player, scriptName: event.rawValue.replacingOccurrences(of: ".", with: "_"),
                handler: "changed", target: .object(ref), event: event,
                attribute: nil, createdBy: .player, tick: 0
            )
        }
        game.world.dayTime = 1_000
        game.world.raining = false
        game.runEventBusPhase()
        var delivered: [ScriptEvent] = []
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty { delivered.append(event) }
        }

        game.world.dayTime = 12_500
        game.world.raining = true
        game.runEventBusPhase()

        let day = delivered.first { $0.kind == .dimDayPhaseChanged }
        XCTAssertEqual(day?.payload["old"], .string("day"))
        XCTAssertEqual(day?.payload["new"], .string("sunset"))
        let weather = delivered.first { $0.kind == .dimWeatherChanged }
        XCTAssertEqual(weather?.payload["key"], .string("raining"))
        XCTAssertEqual(weather?.payload["old"], .bool(false))
        XCTAssertEqual(weather?.payload["new"], .bool(true))
    }

    func testPlayerPickedUpFiresFromTheActualMagnetPickupPath() {
        let game = makeGameInWorld(label: "player-picked-up")
        _ = prepareMiningWall(in: game)
        game.player.inventory = Array(repeating: nil, count: game.player.inventory.count)
        game.player.age = 1 // the next real player tick reaches the magnet's even-tick cadence
        let item = spawnItem(
            game.world, game.player.x, game.player.y + 0.5, game.player.z,
            ItemStack(iid("stone"), 3), 0, 0, 0
        )
        item.pickupDelay = 0
        item.noGravity = true
        _ = game.eventBus.subscribe(
            subscriber: .player, scriptName: "pickup_watch", handler: "picked_up",
            target: .object(.player), event: .playerPickedUp,
            attribute: nil, createdBy: .player, tick: 0
        )
        var captured: ScriptEvent?
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty, event.kind == .playerPickedUp { captured = event }
        }

        stepOneTick(game)

        XCTAssertEqual(captured?.subject, .player)
        XCTAssertEqual(captured?.payload["item"], .string("stone"))
        XCTAssertEqual(captured?.payload["count"], .int(3))
        XCTAssertEqual(captured?.source, .player)
    }

    func testPlayerDroppedFiresFromConfiguredDropBinding() {
        let game = makeGameInWorld(label: "player-dropped")
        game.player.selectedSlot = 0
        game.player.inventory[0] = ItemStack(iid("stone"), 3)
        _ = game.eventBus.subscribe(
            subscriber: .player, scriptName: "drop_watch", handler: "dropped",
            target: .object(.player), event: .playerDropped,
            attribute: nil, createdBy: .player, tick: 0
        )
        var captured: ScriptEvent?
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty, event.kind == .playerDropped { captured = event }
        }

        game.keyDown("KeyQ", now: 1_000)
        game.eventBus.runDeliveryPhase(tick: game.currentTick)

        XCTAssertEqual(captured?.subject, .player)
        XCTAssertEqual(captured?.payload["item"], .string("stone"))
        XCTAssertEqual(captured?.payload["count"], .int(1))
    }

    // MARK: - commands (/on, /unsubscribe, /events)

    func testOnCommandRegistersASubscriptionAndEventsRecentShowsIt() {
        let game = makeGameInWorld(label: "oncommand")
        let context = game.scriptingCommandContext()
        let defineResult = ScriptingCommands.run(
            command: "events", arguments: ["define", "self", "rest.slept"], context: context
        )
        XCTAssertTrue(defineResult.ok, defineResult.lines.joined())
        let onResult = ScriptingCommands.run(command: "on", arguments: ["self", "rest.slept", "farm.on_sleep"], context: context)
        XCTAssertTrue(onResult.ok, onResult.lines.joined())
        XCTAssertEqual(game.eventBus.listSubscriptions().count, 1)

        let emitResult = ScriptingCommands.run(command: "events", arguments: ["emit", "self", "rest.slept"], context: context)
        XCTAssertTrue(emitResult.ok, emitResult.lines.joined())
        let recentResult = ScriptingCommands.run(command: "events", arguments: ["recent"], context: context)
        XCTAssertTrue(recentResult.lines.contains { $0.contains("rest.slept") })

        guard let subID = game.eventBus.listSubscriptions().first?.id else { return XCTFail() }
        let unsubResult = ScriptingCommands.run(command: "unsubscribe", arguments: ["\(subID)"], context: context)
        XCTAssertTrue(unsubResult.ok, unsubResult.lines.joined())
        XCTAssertEqual(game.eventBus.listSubscriptions().count, 0)
    }

    func testEventsRecentRejectsNegativeLimitWithoutTrapping() {
        let game = makeGameInWorld(label: "events-negative-limit")
        let result = ScriptingCommands.run(
            command: "events", arguments: ["recent", "-1"],
            context: game.scriptingCommandContext()
        )
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.lines.joined().contains("nonnegative"))
        XCTAssertTrue(game.eventBus.recentEvents(limit: -1).isEmpty)
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

private func eventFunnelResultSucceeded<Success, Failure>(
    _ result: Result<Success, Failure>
) -> Bool where Failure: Error {
    if case .success = result { return true }
    return false
}
