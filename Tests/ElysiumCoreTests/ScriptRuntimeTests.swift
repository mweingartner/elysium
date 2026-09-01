// ScriptRuntimeTests.swift — script-runtime (change 1c). Complements the
// elysmoke `scripting` suite (`Sources/elysmoke/ScriptingSuiteSmoke.swift`,
// which runs the four Appendix A scripts end-to-end against a bare
// `World`/`ObjectGraphHost` double and is the primary behavioral coverage —
// see its own header comment for why that discipline matches
// `EventBusSmoke.swift`'s). This file covers what a golden hash cannot show
// directly: real `GameCore` script-phase integration (`runEventBusPhase()`,
// `@testable`-visible, the same function `GameCore.tick()` itself calls —
// `debugStepSimulation` is gated behind `ELYSIUM_DEBUG_CONTROL` and not
// available in an ordinary test build),
// persistence codec round trips, the kill switch and trust gate as command-
// level refusals, and `/script` LAN-client gating. `FakeObjectGraphHost` is
// `ObjectGraphTests.swift`'s shared test double.

import Foundation
import ElysiumScript
import XCTest
@testable import ElysiumCore

@MainActor
final class ScriptRuntimeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
        if itemDefs.isEmpty { registerAllItems() }
    }

    private func makeRuntimeHarness(
        seed: Int, budgets: ScriptBudgets = .defaults
    ) throws -> (
        host: FakeObjectGraphHost, state: GameScriptingState, runtime: ScriptRuntime,
        scripts: ScriptStore, attributes: AttributeStore
    ) {
        let host = FakeObjectGraphHost()
        host.worldsByDim[.overworld] = World(dim: .overworld, seed: UInt32(seed))
        let state = GameScriptingState()
        let runtime = try ScriptRuntime(host: host, state: state, budgets: budgets, say: { _ in })
        state.scriptRuntime = runtime
        state.eventBus.delivery = { [weak runtime] event, targets in
            runtime?.deliver(event, targets)
        }
        state.eventBus.deliveryAdmission = { [weak runtime] event, targets in
            runtime?.admittedDeliveryCount(for: event, targets: targets) ?? 0
        }
        let graph = ObjectGraph(host: host)
        return (host, state, runtime, ScriptStore(graph: graph), AttributeStore(graph: graph))
    }

    func testEventEnvelopeFieldsCannotBeSpoofedByPayload() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-event-envelope")
        game.createWorld(name: "EventEnvelope", seedText: "29", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let value = runtime.eventValue(ScriptEvent(
            seq: 1,
            tick: 42,
            kind: .blockChanged,
            subject: .world,
            payload: [
                "kind": .string("spoofed"),
                "tick": .int(-1),
                "subject": .string("spoofed"),
                "source": .string("spoofed"),
            ],
            source: .player
        ))
        guard case .map(let event) = value else { return XCTFail("expected event map") }
        XCTAssertEqual(event["kind"], .string(EventKind.blockChanged.rawValue))
        XCTAssertEqual(event["tick"], .int(42))
        XCTAssertEqual(event["source"], .string("player"))
        XCTAssertEqual(event["subject"], .ref(ObjectRef.world.canonical))
    }

    func testEventPayloadRecursivelyMaterializesEngineAndLANObjectRefs() throws {
        let harness = try makeRuntimeHarness(seed: 91)
        let kind = try XCTUnwrap(EventKind.parse("test.refs"))
        _ = try harness.scripts.attach(
            .world, name: "ref_reader", source: """
            self:on("test.refs", function(ev)
              world.attrs.attacker_ref = ev.attacker.ref
              world.attrs.by_ref = ev.by.ref
              world.attrs.by_kind = ev.by.kind
              world.attrs.nested_lan_ref = ev.nested.actors[1].ref
              world.attrs.deep_target_ref = ev.nested.deeper.target.ref
            end)
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()

        let attacker = ObjectRef.entity(uid: 987_654)
        let by = ObjectRef.lanPlayer(peerID: "peer-by")
        let nestedLAN = ObjectRef.lanPlayer(peerID: "peer-nested")
        let deepTarget = ObjectRef.block(dim: .overworld, x: 12, y: 64, z: -3)
        harness.state.eventBus.raise(
            kind: kind, subject: .world,
            payload: [
                "attacker": .ref(attacker.canonical),
                "by": .ref(by.canonical),
                "nested": .map([
                    "actors": .list([.ref(nestedLAN.canonical)]),
                    "deeper": .map(["target": .ref(deepTarget.canonical)]),
                ]),
            ],
            source: .engine, tick: 1
        )
        _ = harness.state.eventBus.runDeliveryPhase(tick: 1)

        XCTAssertEqual(harness.attributes.get(.world, "attacker_ref"), .string(attacker.canonical))
        XCTAssertEqual(harness.attributes.get(.world, "by_ref"), .string(by.canonical))
        XCTAssertEqual(harness.attributes.get(.world, "by_kind"), .string(ObjectKind.player.rawValue))
        XCTAssertEqual(harness.attributes.get(.world, "nested_lan_ref"), .string(nestedLAN.canonical))
        XCTAssertEqual(harness.attributes.get(.world, "deep_target_ref"), .string(deepTarget.canonical))
        XCTAssertNil(harness.scripts.get(.world, "ref_reader")?.lastError)
    }

    func testAttrsNilRespectsReadonlyAndReportsTheMutationError() throws {
        let harness = try makeRuntimeHarness(seed: 911)
        _ = try harness.attributes.define(
            .world, "owner", .string("player"), readonly: true, by: .player
        ).get()
        _ = try harness.scripts.attach(
            .world, name: "cannot_remove", source: "world.attrs.owner = nil",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true

        harness.runtime.runLoads()

        XCTAssertEqual(harness.attributes.get(.world, "owner"), .string("player"))
        XCTAssertTrue(
            harness.scripts.get(.world, "cannot_remove")?.lastError?.contains("readonly") == true
        )
    }

    func testAttachDetachBudgetEnforcesPerScriptAndWorldCapsAndResetsPerTick() throws {
        let harness = try makeRuntimeHarness(seed: 912)
        for index in 0..<16 {
            let context = (owner: ObjectRef.entity(uid: index + 1), name: "manager")
            XCTAssertTrue(harness.runtime.incrementAttachDetach(context))
            XCTAssertTrue(harness.runtime.incrementAttachDetach(context))
            XCTAssertFalse(
                harness.runtime.incrementAttachDetach(context),
                "one script may perform at most two attach/detach operations per tick"
            )
        }
        XCTAssertFalse(
            harness.runtime.incrementAttachDetach((owner: .world, name: "thirty_third")),
            "the world must refuse operation 33 even when that script has unused local budget"
        )

        harness.runtime.resetPerTickCounters()
        XCTAssertFalse(
            harness.runtime.incrementAttachDetach((owner: .world, name: "same_tick_reentry")),
            "a second script phase in the same tick must not mint another world lifecycle budget"
        )

        harness.host.currentTick = 1
        XCTAssertTrue(harness.runtime.incrementAttachDetach((owner: .world, name: "next_tick")))
        harness.runtime.resetPerTickCounters()
        XCTAssertTrue(harness.runtime.incrementAttachDetach((owner: .world, name: "next_tick")))
        XCTAssertFalse(
            harness.runtime.incrementAttachDetach((owner: .world, name: "next_tick")),
            "same-tick phase re-entry must preserve the per-script count too"
        )
    }

    func testEventDeclarationMutationBudgetSurvivesPhaseReentryAndResetsNextTick() throws {
        let harness = try makeRuntimeHarness(seed: 915)
        let context = (owner: ObjectRef.world, name: "publisher")
        let limit = harness.runtime.customEventStore.caps.maxEventDeclarationsPerObject

        for _ in 0..<limit {
            XCTAssertTrue(harness.runtime.incrementEventDeclarations(context))
        }
        harness.runtime.resetPerTickCounters()
        XCTAssertFalse(
            harness.runtime.incrementEventDeclarations(context),
            "a second script phase in the same tick must not mint another declaration budget"
        )

        harness.host.currentTick = 1
        XCTAssertTrue(harness.runtime.incrementEventDeclarations(context))
        harness.runtime.resetPerTickCounters()
        for _ in 1..<limit {
            XCTAssertTrue(harness.runtime.incrementEventDeclarations(context))
        }
        XCTAssertFalse(
            harness.runtime.incrementEventDeclarations(context),
            "same-tick phase re-entry must preserve the declaration mutation count"
        )
    }

    func testDefinitionReconciliationIsDirtyDrivenWithoutPeriodicWorldCensus() throws {
        let harness = try makeRuntimeHarness(seed: 913)
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.definitionReconciliationCount, 0)

        harness.host.currentTick = 100
        harness.runtime.runLoads()
        XCTAssertEqual(
            harness.runtime.definitionReconciliationCount, 0,
            "advancing far beyond the retired 20-tick interval must not trigger a world census"
        )

        _ = try harness.scripts.attach(
            .world, name: "new_definition", source: "world.attrs.loaded = true",
            mode: .module, triggers: [], by: .player, tick: 100
        ).get()
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.definitionReconciliationCount, 1)
        XCTAssertEqual(harness.attributes.get(.world, "loaded"), .bool(true))

        harness.host.currentTick = 1_000
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.definitionReconciliationCount, 1)
        _ = try harness.scripts.detach(.world, "new_definition").get()
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.definitionReconciliationCount, 2)
        XCTAssertEqual(harness.runtime.summary.liveScripts, 0)
    }

    func testDefinitionLoadBacklogSurvivesLaterGenerationChanges() throws {
        var budgets = ScriptBudgets.defaults
        budgets.perTickInstructions = 200_000
        budgets.perTickBucket = 200_000
        let harness = try makeRuntimeHarness(seed: 914, budgets: budgets)
        let world = try XCTUnwrap(harness.host.worldsByDim[.overworld])

        // Nine objects x eight scripts exceeds maxScriptLoadsPerTick (64) while staying within
        // every per-object storage cap. Empty modules still become live and consume one scheduler
        // accounting quantum, making the expected split deterministic.
        var refs: [ObjectRef] = []
        for entityIndex in 0..<9 {
            let cow = Cow(world: world)
            cow.setPos(Double(entityIndex), 64, 0)
            world.addEntity(cow)
            let ref = ObjectRef.entity(uid: cow.id)
            refs.append(ref)
            for scriptIndex in 0..<maxScriptsPerObject {
                _ = try harness.scripts.attach(
                    ref, name: "s\(scriptIndex)", source: "", mode: .module, triggers: [],
                    by: .player, tick: 0
                ).get()
            }
        }
        harness.state.anyScriptsAttached = true

        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.summary.liveScripts, ScriptRuntime.maxScriptLoadsPerTick)
        XCTAssertEqual(harness.runtime.definitionReconciliationCount, refs.count)

        let editedRef = try XCTUnwrap(refs.min { utf8Less($0.canonical, $1.canonical) })
        _ = try harness.scripts.attach(
            editedRef, name: "s0", source: "world.attrs.backlog_edit_loaded = true",
            mode: .module, triggers: [], by: .player, tick: 1
        ).get()

        harness.host.currentTick = 1
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.summary.liveScripts, 9 * maxScriptsPerObject)
        XCTAssertEqual(harness.attributes.get(.world, "backlog_edit_loaded"), .bool(true))
        XCTAssertEqual(harness.runtime.definitionReconciliationCount, refs.count + 1)
    }

    func testHydratedDirtyRefQueueRetainsBoundedSuffixAndReconcilesRemovals() throws {
        var budgets = ScriptBudgets.defaults
        budgets.perTickInstructions = 200_000
        budgets.perTickBucket = 200_000
        let harness = try makeRuntimeHarness(seed: 916, budgets: budgets)
        let world = try XCTUnwrap(harness.host.worldsByDim[.overworld])
        var entitiesByRef: [ObjectRef: Entity] = [:]

        for index in 0...ScriptRuntime.maxDefinitionRefsPerTick {
            let cow = Cow(world: world)
            cow.setPos(Double(index), 64, 0)
            let ref = ObjectRef.entity(uid: cow.id)
            cow.objectRecord = ObjectRecord(
                entries: [
                    "persisted": .script(ScriptRecord(
                        name: "persisted", source: "", enabled: true, mode: .module,
                        author: .player, createdTick: 0
                    )),
                ],
                revision: 1
            )
            world.addEntity(cow)
            entitiesByRef[ref] = cow
            // This is the persistence-hydration notification that production World hooks issue.
            harness.host.scriptDefinitionsDidChange(for: ref, hasScripts: true)
        }

        let sortedRefs = entitiesByRef.keys.sorted { utf8Less($0.canonical, $1.canonical) }
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.summary.liveScripts, ScriptRuntime.maxDefinitionRefsPerTick)
        XCTAssertEqual(harness.runtime.definitionReconciliationCount, ScriptRuntime.maxDefinitionRefsPerTick)
        XCTAssertEqual(harness.host.scriptDefinitionChanges.pendingRefCount, 1)

        let firstLoaded = try XCTUnwrap(sortedRefs.first)
        let retainedSuffix = try XCTUnwrap(sortedRefs.last)
        entitiesByRef[firstLoaded]?.objectRecord = ObjectRecord()
        entitiesByRef[retainedSuffix]?.objectRecord = ObjectRecord()
        harness.host.scriptDefinitionsDidChange(for: firstLoaded, hasScripts: false)
        harness.host.scriptDefinitionsDidChange(for: retainedSuffix, hasScripts: false)

        harness.host.currentTick = 1
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.summary.liveScripts, ScriptRuntime.maxDefinitionRefsPerTick - 1)
        XCTAssertEqual(harness.runtime.definitionReconciliationCount, ScriptRuntime.maxDefinitionRefsPerTick + 2)
        XCTAssertEqual(harness.host.scriptDefinitionChanges.pendingRefCount, 0)
        XCTAssertEqual(
            harness.host.scriptDefinitionChanges.scriptedRefCount,
            ScriptRuntime.maxDefinitionRefsPerTick - 1
        )
    }

    func testDimensionTransitionRequeuesPersistedDefinitionBagsWithoutACensus() throws {
        let harness = try makeRuntimeHarness(seed: 919)
        harness.host.worldsByDim[.nether] = World(dim: .nether, seed: 919)
        let overworldRef = ObjectRef.dimension(.overworld)
        let netherRef = ObjectRef.dimension(.nether)
        let overworldScript = ScriptRecord(
            name: "overworld_script", source: "", enabled: true, mode: .module,
            author: .player, createdTick: 0
        )
        let netherScript = ScriptRecord(
            name: "nether_script", source: "world.attrs.nether_loaded = true", enabled: true,
            mode: .module, author: .player, createdTick: 0
        )
        harness.host.worldRecords[overworldRef.canonical] = ObjectRecord(
            entries: [overworldScript.name: .script(overworldScript)], revision: 1
        )
        harness.host.worldRecords[netherRef.canonical] = ObjectRecord(
            entries: [netherScript.name: .script(netherScript)], revision: 1
        )
        harness.host.scriptDefinitionsDidChange(for: overworldRef, hasScripts: true)
        harness.host.scriptDefinitionsDidChange(for: netherRef, hasScripts: true)

        harness.runtime.runLoads()
        XCTAssertNotNil(harness.runtime.instances[overworldRef.canonical + "#overworld_script"])
        XCTAssertNil(harness.runtime.instances[netherRef.canonical + "#nether_script"])

        harness.host.currentDimension = .nether
        harness.host.currentTick = 1
        harness.runtime.runLoads()

        XCTAssertNil(harness.runtime.instances[overworldRef.canonical + "#overworld_script"])
        XCTAssertNotNil(harness.runtime.instances[netherRef.canonical + "#nether_script"])
        XCTAssertEqual(harness.attributes.get(.world, "nether_loaded"), .bool(true))
    }

    func testAttributeAndScriptAPIsRefuseCrossNamespaceReplacementWithoutMutation() throws {
        let harness = try makeRuntimeHarness(seed: 917)
        _ = try harness.scripts.attach(
            .world, name: "shared", source: "", mode: .module, triggers: [],
            by: .player, tick: 0
        ).get()
        harness.runtime.runLoads()
        let scriptRevision = try XCTUnwrap(harness.attributes.record(.world)?.revision)
        let scriptGeneration = harness.host.scriptDefinitionGeneration
        XCTAssertEqual(harness.host.scriptDefinitionChanges.pendingRefCount, 0)

        guard case .failure(.nameIsScript) = harness.attributes.set(.world, "shared", .int(1)) else {
            return XCTFail("set must not replace a script entry")
        }
        guard case .failure(.nameIsScript) = harness.attributes.define(
            .world, "shared", .int(1), readonly: false
        ) else { return XCTFail("define must not replace a script entry") }
        guard case .failure(.nameIsScript) = harness.attributes.remove(.world, "shared") else {
            return XCTFail("attribute remove must direct the caller to detach the script")
        }
        XCTAssertEqual(harness.attributes.record(.world)?.revision, scriptRevision)
        XCTAssertEqual(harness.host.scriptDefinitionGeneration, scriptGeneration)
        XCTAssertEqual(harness.host.scriptDefinitionChanges.pendingRefCount, 0)
        XCTAssertNotNil(harness.scripts.get(.world, "shared"))

        _ = try harness.attributes.set(.world, "reserved", .string("attribute")).get()
        let attributeRevision = try XCTUnwrap(harness.attributes.record(.world)?.revision)
        let attributeGeneration = harness.host.scriptDefinitionGeneration
        guard case .failure(.nameIsAttribute) = harness.scripts.attach(
            .world, name: "reserved", source: "", mode: .module, triggers: [],
            by: .player, tick: 0
        ) else { return XCTFail("attach must not replace an attribute entry") }
        guard case .failure(.nameIsAttribute) = harness.scripts.detach(.world, "reserved") else {
            return XCTFail("script detach must direct the caller to remove the attribute")
        }
        XCTAssertEqual(harness.attributes.record(.world)?.revision, attributeRevision)
        XCTAssertEqual(harness.host.scriptDefinitionGeneration, attributeGeneration)
        XCTAssertEqual(harness.host.scriptDefinitionChanges.pendingRefCount, 0)
        XCTAssertEqual(harness.attributes.get(.world, "reserved"), .string("attribute"))
    }

    func testBlockTypeFilteredSubscriptionsReceiveRuntimeLifecycleEvents() throws {
        let harness = try makeRuntimeHarness(seed: 918)
        let world = try XCTUnwrap(harness.host.worldsByDim[.overworld])
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        _ = world.setBlock(1, 64, 1, Int(cell(B.stone)))
        let block = ObjectRef.block(dim: .overworld, x: 1, y: 64, z: 1)

        _ = try harness.scripts.attach(
            .world, name: "observer", source: """
            local stone = {kind = "block", type = "stone"}
            subscribe(stone, "load", function() world.attrs.saw_block_load = true end)
            subscribe(stone, "timer.fired", function() world.attrs.saw_block_timer = true end)
            subscribe(stone, "script.attached", function() world.attrs.saw_block_attach = true end)
            subscribe(stone, "script.faulted", function() world.attrs.saw_block_fault = true end)
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.runtime.runLoads()
        _ = harness.state.eventBus.runDeliveryPhase(tick: 0)

        _ = try harness.scripts.attach(
            block, name: "bad", source: "error(\"boom\")", mode: .module, triggers: [],
            by: .player, tick: 0
        ).get()
        _ = try harness.scripts.attach(
            block, name: "good", source: """
            register("wake", function() end)
            after(1, "wake")
            self:attach("child", "")
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()

        harness.runtime.runLoads()
        _ = harness.state.eventBus.runDeliveryPhase(tick: 0)
        harness.host.currentTick = 1
        harness.runtime.runLoads()
        harness.runtime.runResumptions()
        _ = harness.state.eventBus.runDeliveryPhase(tick: 1)

        XCTAssertEqual(harness.attributes.get(.world, "saw_block_load"), .bool(true))
        XCTAssertEqual(harness.attributes.get(.world, "saw_block_timer"), .bool(true))
        XCTAssertEqual(harness.attributes.get(.world, "saw_block_attach"), .bool(true))
        XCTAssertEqual(harness.attributes.get(.world, "saw_block_fault"), .bool(true))
    }

    func testHandlerChunkIsCachedAcrossChurnAndConcurrentSuspensions() throws {
        let harness = try makeRuntimeHarness(seed: 92)
        let cacheKind = try XCTUnwrap(EventKind.parse("test.cache"))
        let suspendKind = try XCTUnwrap(EventKind.parse("test.suspend"))
        _ = try harness.scripts.attach(
            .world, name: "cached_handler", source: """
            if ev.kind == "test.suspend" then
              wait(2)
              world.attrs.suspended_completions = (world.attrs.suspended_completions or 0) + 1
            end
            """, mode: .handler,
            triggers: [Trigger(event: cacheKind, attribute: nil, target: .object(.world))],
            by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()

        let key = ObjectRef.world.canonical + "#cached_handler"
        let cachedFunction = try XCTUnwrap(harness.runtime.instances[key]?.handlerFunction)
        let token = ScriptHandlerToken(.handlerChunk(ref: .world, name: "cached_handler"))
        let target = EventDeliveryTarget(kind: .scriptOwned(ScriptOwnedSubscription(
            id: 1, owner: .world, scriptName: "cached_handler", target: .object(.world),
            event: cacheKind, attribute: nil, token: token
        )))

        // Warm the coroutine pool and interned handles before taking the memory baseline.
        harness.runtime.deliver(
            ScriptEvent(
                seq: 1, tick: 0, kind: cacheKind, subject: .world,
                payload: [:], source: .engine
            ),
            [target]
        )
        harness.runtime.lua.collectFull()
        let baseline = harness.runtime.lua.memoryStatus.bytesInUse
        for i in 0..<5_000 {
            if harness.runtime.summary.instructionBudgetRemaining
                < ScriptRuntime.instructionAccountingQuantum {
                harness.host.currentTick += 1
                harness.runtime.resetPerTickCounters()
            }
            harness.runtime.deliver(
                ScriptEvent(
                    seq: UInt64(i + 2), tick: Int64(i + 1), kind: cacheKind,
                    subject: .world, payload: [:], source: .engine
                ),
                [target]
            )
        }
        harness.runtime.lua.collectFull()
        XCTAssertLessThanOrEqual(
            harness.runtime.lua.memoryStatus.bytesInUse, baseline + 64 * 1024,
            "repeated handler delivery must not retain one compiled registry ref per firing"
        )
        XCTAssertTrue(harness.runtime.instances[key]?.handlerFunction === cachedFunction)
        XCTAssertNil(harness.scripts.get(.world, "cached_handler")?.lastError)
        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 0)

        harness.host.currentTick += 1
        harness.runtime.resetPerTickCounters()
        let suspensionTick = harness.host.currentTick
        harness.runtime.deliver(
            ScriptEvent(
                seq: 6_000, tick: suspensionTick, kind: suspendKind, subject: .world,
                payload: [:], source: .engine
            ),
            [target]
        )
        harness.runtime.deliver(
            ScriptEvent(
                seq: 6_001, tick: suspensionTick, kind: suspendKind, subject: .world,
                payload: [:], source: .engine
            ),
            [target]
        )
        XCTAssertEqual(
            harness.runtime.summary.suspendedCoroutines, 2,
            "one cached function must seed independent, simultaneously suspended coroutines"
        )
        harness.host.currentTick = suspensionTick + 2
        harness.runtime.runResumptions()
        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 0)
        XCTAssertEqual(harness.attributes.get(.world, "suspended_completions"), .int(2))
        XCTAssertTrue(harness.runtime.instances[key]?.handlerFunction === cachedFunction)
    }

    func testGlobalInstructionBudgetBackpressuresExactEventRecipientSuffix() throws {
        var budgets = ScriptBudgets.defaults
        budgets.perTickInstructions = 2_000
        budgets.perTickBucket = 2_000
        let harness = try makeRuntimeHarness(seed: 93, budgets: budgets)
        let kind = try XCTUnwrap(EventKind.parse("test.budget"))
        for i in 0..<3 {
            _ = try harness.scripts.attach(
                .world, name: "budget_script_\(i)", source: "world.attrs.handler_\(i) = true",
                mode: .handler,
                triggers: [Trigger(event: kind, attribute: nil, target: .object(.world))],
                by: .player, tick: 0
            ).get()
        }
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        harness.state.eventBus.raise(kind: kind, subject: .world, source: .engine, tick: 0)

        let first = harness.state.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(first.delivered, 2)
        XCTAssertEqual(
            first.carriedOver, 3,
            "one recipient cursor plus the two attribute.changed events it produced remain queued"
        )
        XCTAssertEqual(harness.attributes.get(.world, "handler_0"), .bool(true))
        XCTAssertEqual(harness.attributes.get(.world, "handler_1"), .bool(true))
        XCTAssertNil(harness.attributes.get(.world, "handler_2"))
        XCTAssertEqual(harness.runtime.summary.instructionBudgetRemaining, 0)

        harness.host.currentTick = 1
        harness.runtime.resetPerTickCounters()
        let second = harness.state.eventBus.runDeliveryPhase(tick: 1)
        XCTAssertEqual(second.delivered, 1)
        XCTAssertEqual(second.carriedOver, 0)
        XCTAssertEqual(harness.attributes.get(.world, "handler_2"), .bool(true))
    }

    func testSubQuantumSliceOverrunBecomesDebtOnNextTick() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 1_500
        budgets.handlerTotalInstructions = 100_000
        budgets.perTickInstructions = 1_500
        budgets.perTickBucket = 1_500
        budgets.maxConsecutivePreemptions = 10
        let harness = try makeRuntimeHarness(seed: 94, budgets: budgets)
        let kind = try XCTUnwrap(EventKind.parse("test.spinner"))
        _ = try harness.scripts.attach(
            .world, name: "spinner", source: "local n = 0; while true do n = n + 1 end",
            mode: .handler,
            triggers: [Trigger(event: kind, attribute: nil, target: .object(.world))],
            by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        harness.state.eventBus.raise(kind: kind, subject: .world, source: .engine, tick: 0)
        _ = harness.state.eventBus.runDeliveryPhase(tick: 0)

        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 1)
        XCTAssertEqual(harness.runtime.summary.instructionsUsedThisTick, 2_000)
        XCTAssertEqual(harness.runtime.summary.instructionBudgetRemaining, 0)
        harness.host.currentTick = 1
        harness.runtime.resetPerTickCounters()
        XCTAssertEqual(
            harness.runtime.summary.instructionBudgetRemaining, 1_000,
            "the 500-instruction hook overrun must be repaid instead of erased"
        )
    }

    func testSixtyFifthSuspendedCoroutineFaultsWithoutGrowingScheduler() throws {
        var budgets = ScriptBudgets.defaults
        budgets.perTickInstructions = 100_000
        budgets.perTickBucket = 100_000
        let harness = try makeRuntimeHarness(seed: 95, budgets: budgets)
        let kind = try XCTUnwrap(EventKind.parse("test.waiter"))
        _ = try harness.scripts.attach(
            .world, name: "waiters", source: """
            self:on("test.waiter", function(ev)
              wait(1000)
            end)
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        for _ in 0..<65 {
            harness.state.eventBus.raise(kind: kind, subject: .world, source: .engine, tick: 0)
        }
        let report = harness.state.eventBus.runDeliveryPhase(tick: 0)

        XCTAssertEqual(report.delivered, 65)
        XCTAssertEqual(
            harness.runtime.summary.suspendedCoroutines,
            budgets.maxSuspendedCoroutinesPerScript
        )
        XCTAssertTrue(
            harness.scripts.get(.world, "waiters")?.lastError?.contains("script suspended coroutine limit") == true
        )
        XCTAssertTrue(harness.state.eventBus.recentEvents().contains { event in
            event.kind == .scriptOverBudget
                && event.payload["message"] == .string("script suspended coroutine limit exceeded")
        })
    }

    func testWorldSuspendedCoroutineCapRecoversAfterScriptUnload() throws {
        var budgets = ScriptBudgets.defaults
        budgets.perTickInstructions = 20_000
        budgets.perTickBucket = 20_000
        budgets.maxSuspendedCoroutinesPerScript = 8
        budgets.maxSuspendedCoroutinesPerWorld = 2
        let harness = try makeRuntimeHarness(seed: 951, budgets: budgets)
        let kind = try XCTUnwrap(EventKind.parse("test.world_waiter"))
        _ = try harness.scripts.attach(
            .world, name: "world_waiters", source: "self:on('test.world_waiter', function() wait(1000) end)",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        for _ in 0..<3 {
            harness.state.eventBus.raise(kind: kind, subject: .world, source: .engine, tick: 0)
        }
        _ = harness.state.eventBus.runDeliveryPhase(tick: 0)

        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 2)
        XCTAssertTrue(
            harness.scripts.get(.world, "world_waiters")?.lastError?.contains("world suspended coroutine limit") == true
        )

        _ = try harness.scripts.detach(.world, "world_waiters").get()
        harness.host.currentTick = 1
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 0)

        _ = try harness.scripts.attach(
            .world, name: "world_waiters", source: "self:on('test.world_waiter', function() wait(1000) end)",
            mode: .module, triggers: [], by: .player, tick: 1
        ).get()
        harness.runtime.runLoads()
        harness.state.eventBus.raise(kind: kind, subject: .world, source: .engine, tick: 1)
        _ = harness.state.eventBus.runDeliveryPhase(tick: 1)
        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 1)
    }

    func testAwaitedAIReplyRetainsRequestAndCoroutineUntilInstructionCreditReturns() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 1_000
        budgets.perTickInstructions = 1_000
        budgets.perTickBucket = 1_000
        let harness = try makeRuntimeHarness(seed: 952, budgets: budgets)
        _ = try harness.scripts.attach(
            .world, name: "await_reply", source: "local text, err = ai.await('hello'); world.attrs.ai_text = text; world.attrs.ai_error = err",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 1)
        XCTAssertEqual(harness.runtime.aiInFlightCount, 1)

        harness.runtime.runAIInbox()
        XCTAssertNil(harness.attributes.get(.world, "ai_text"))
        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 1)
        XCTAssertEqual(harness.runtime.aiInFlightCount, 1, "a deferred reply must retain its in-flight ownership")

        harness.host.currentTick = 1
        harness.runtime.resetPerTickCounters()
        harness.runtime.runAIInbox()
        XCTAssertNil(harness.attributes.get(.world, "ai_text"))
        XCTAssertEqual(harness.attributes.get(.world, "ai_error"), .string("timeout"))
        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 0)
        XCTAssertEqual(harness.runtime.aiInFlightCount, 0)
    }

    func testAwaitedAIReplyIsUTF8ByteBoundedBeforeLuaResume() throws {
        let harness = try makeRuntimeHarness(seed: 9_521)
        var requestID: UInt64?
        harness.runtime.outboxHandoff = { id, _ in requestID = id }
        _ = try harness.scripts.attach(
            .world, name: "bounded_await", source: """
            local text, err = ai.await("multibyte")
            world.attrs.await_reply_bytes = #text
            world.attrs.await_reply_tail = string.sub(text, -1)
            world.attrs.await_reply_error = err
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        harness.runtime.runAIInbox()
        let id = try XCTUnwrap(requestID)

        let oversized = String(repeating: "a", count: 4_095) + "😀tail"
        harness.runtime.submitAIReply(id: id, text: oversized, error: nil)
        harness.host.currentTick = 1
        harness.runtime.resetPerTickCounters()
        harness.runtime.runAIInbox()

        XCTAssertEqual(harness.attributes.get(.world, "await_reply_bytes"), .int(4_095))
        XCTAssertEqual(harness.attributes.get(.world, "await_reply_tail"), .string("a"))
        XCTAssertNil(harness.attributes.get(.world, "await_reply_error"))
        XCTAssertNil(harness.scripts.get(.world, "bounded_await")?.lastError)
        XCTAssertEqual(harness.runtime.aiInFlightCount, 0)
    }

    func testAskedAIReplyIsUTF8ByteBoundedBeforeEventDelivery() throws {
        let harness = try makeRuntimeHarness(seed: 9_522)
        var requestID: UInt64?
        harness.runtime.outboxHandoff = { id, _ in requestID = id }
        _ = try harness.scripts.attach(
            .world, name: "bounded_ask", source: """
            world:on("ai.replied", function(ev)
              world.attrs.ask_reply_bytes = #ev.text
              world.attrs.ask_reply_tail = string.sub(ev.text, -1)
            end)
            ai.ask("multibyte")
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        harness.runtime.runAIInbox()
        let id = try XCTUnwrap(requestID)

        let oversized = String(repeating: "a", count: 4_095) + "😀tail"
        harness.runtime.submitAIReply(id: id, text: oversized, error: nil)
        harness.host.currentTick = 1
        harness.runtime.resetPerTickCounters()
        harness.runtime.runAIInbox()
        _ = harness.state.eventBus.runDeliveryPhase(tick: 1)

        XCTAssertEqual(harness.attributes.get(.world, "ask_reply_bytes"), .int(4_095))
        XCTAssertEqual(harness.attributes.get(.world, "ask_reply_tail"), .string("a"))
        XCTAssertNil(harness.scripts.get(.world, "bounded_ask")?.lastError)
        XCTAssertEqual(harness.runtime.aiInFlightCount, 0)
        XCTAssertTrue(harness.state.eventBus.recentEvents().contains { event in
            event.kind == .aiReplied
                && event.payload["text"] == .string(String(repeating: "a", count: 4_095))
        })
    }

    func testSchedulerReservesOneQuantumForEveryDownstreamLane() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 1_000
        budgets.perTickInstructions = 5_000
        budgets.perTickBucket = 5_000
        let harness = try makeRuntimeHarness(seed: 953, budgets: budgets)
        var requestID: UInt64?
        harness.runtime.outboxHandoff = { id, _ in requestID = id }

        _ = try harness.scripts.attach(
            .world, name: "awaiter", source: "local text = ai.await('lane'); world.attrs.ai_lane = text",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        harness.runtime.runAIInbox()
        XCTAssertNotNil(requestID)

        harness.host.currentTick = 1
        _ = try harness.scripts.attach(
            .world, name: "waiter", source: "self:on('test.wait_lane', function() wait(1); world.attrs.wait_lane = true end)",
            mode: .module, triggers: [], by: .player, tick: 1
        ).get()
        harness.runtime.runLoads()
        let waitKind = try XCTUnwrap(EventKind.parse("test.wait_lane"))
        harness.state.eventBus.raise(kind: waitKind, subject: .world, source: .engine, tick: 1)
        _ = harness.state.eventBus.runDeliveryPhase(tick: 1)

        harness.host.currentTick = 2
        _ = try harness.scripts.attach(
            .world, name: "timer", source: "register('fire', function() world.attrs.timer_lane = true end); after(1, 'fire')",
            mode: .module, triggers: [], by: .player, tick: 2
        ).get()
        harness.runtime.runLoads()

        harness.host.currentTick = 3
        let eventKind = try XCTUnwrap(EventKind.parse("test.event_lane"))
        _ = try harness.scripts.attach(
            .world, name: "eventer", source: "world.attrs.event_lane = true", mode: .handler,
            triggers: [Trigger(event: eventKind, attribute: nil, target: .object(.world))],
            by: .player, tick: 3
        ).get()
        harness.runtime.runLoads()

        harness.host.currentTick = 4
        _ = try harness.scripts.attach(
            .world, name: "loader", source: "world.attrs.load_lane = true",
            mode: .module, triggers: [], by: .player, tick: 4
        ).get()
        harness.runtime.submitAIReply(id: try XCTUnwrap(requestID), text: "ok", error: nil)
        harness.state.eventBus.raise(kind: eventKind, subject: .world, source: .engine, tick: 4)

        harness.runtime.runLoads()
        harness.runtime.runAIInbox()
        harness.runtime.runResumptions()
        _ = harness.state.eventBus.runDeliveryPhase(tick: 4)

        XCTAssertEqual(harness.attributes.get(.world, "load_lane"), .bool(true))
        XCTAssertEqual(harness.attributes.get(.world, "ai_lane"), .string("ok"))
        XCTAssertEqual(harness.attributes.get(.world, "wait_lane"), .bool(true))
        XCTAssertEqual(harness.attributes.get(.world, "timer_lane"), .bool(true))
        XCTAssertEqual(harness.attributes.get(.world, "event_lane"), .bool(true))
        XCTAssertEqual(harness.runtime.summary.instructionsUsedThisTick, 5_000)
        XCTAssertEqual(harness.runtime.summary.instructionBudgetRemaining, 0)
    }

    func testInstructionBucketDoesNotRefillTwiceAndSaturatesAfterIdleTicks() throws {
        var budgets = ScriptBudgets.defaults
        budgets.perTickInstructions = 1_000
        budgets.perTickBucket = 2_500
        let harness = try makeRuntimeHarness(seed: 954, budgets: budgets)
        _ = try harness.scripts.attach(
            .world, name: "one_quantum", source: "world.attrs.ran = true",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.summary.instructionBudgetRemaining, 0)
        harness.runtime.resetPerTickCounters()
        harness.runtime.runAIInbox()
        XCTAssertEqual(harness.runtime.summary.instructionBudgetRemaining, 0)

        harness.host.currentTick = 100
        harness.runtime.resetPerTickCounters()
        XCTAssertEqual(harness.runtime.summary.instructionBudgetRemaining, 2_500)
    }

    func testConsecutivePreemptionLimitFaultsSpinnerDeterministically() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 1_000
        budgets.handlerTotalInstructions = 100_000
        budgets.perTickInstructions = 1_000
        budgets.perTickBucket = 1_000
        budgets.maxConsecutivePreemptions = 2
        let harness = try makeRuntimeHarness(seed: 96, budgets: budgets)
        let kind = try XCTUnwrap(EventKind.parse("test.spinlimit"))
        _ = try harness.scripts.attach(
            .world, name: "spinlimit", source: "while true do end", mode: .handler,
            triggers: [Trigger(event: kind, attribute: nil, target: .object(.world))],
            by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        harness.state.eventBus.raise(kind: kind, subject: .world, source: .engine, tick: 0)
        _ = harness.state.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 1)

        harness.host.currentTick = 1
        harness.runtime.resetPerTickCounters()
        harness.runtime.runResumptions()
        XCTAssertEqual(harness.runtime.summary.suspendedCoroutines, 0)
        XCTAssertTrue(
            harness.scripts.get(.world, "spinlimit")?.lastError?.contains("consecutive instruction-slice") == true
        )
    }

    func testHugeNumericTimerAndRNGArgumentsAreRejectedWithoutHostTrap() throws {
        let harness = try makeRuntimeHarness(seed: 97)
        _ = try harness.scripts.attach(
            .world, name: "numeric_bounds", source: """
            local timer_ok = pcall(function() after(1e300, "never") end)
            local rng_ok = pcall(function()
              rng(-9223372036854775808, 9223372036854775807)
            end)
            world.attrs.timer_huge_rejected = not timer_ok
            world.attrs.rng_huge_rejected = not rng_ok
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()
        XCTAssertEqual(harness.attributes.get(.world, "timer_huge_rejected"), .bool(true))
        XCTAssertEqual(harness.attributes.get(.world, "rng_huge_rejected"), .bool(true))
        XCTAssertNil(harness.scripts.get(.world, "numeric_bounds")?.lastError)
    }

    // MARK: - GameCore integration: a handler-mode script fires through a real tick()

    func testHandlerModeScriptFiresThroughRealGameCoreTick() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-tick")
        game.createWorld(name: "ScriptTick", seedText: "11", mode: GameMode.survival, difficulty: 2)
        let w = game.world
        let cx = floorDiv(ifloor(game.player.x), CHUNK_W), cz = floorDiv(ifloor(game.player.z), CHUNK_W)
        XCTAssertNotNil(w.getChunk(cx, cz), "the player's own chunk must already be loaded after createWorld")

        let lampX = ifloor(game.player.x) + 2
        let lampZ = ifloor(game.player.z)
        let lampY = ifloor(game.player.y)
        _ = w.setBlock(lampX, lampY, lampZ, Int(cell(bidOpt("sea_lantern")!, 0)))
        let lamp = ObjectRef.block(dim: game.dim, x: lampX, y: lampY, z: lampZ)

        let store = ScriptStore(graph: ObjectGraph(host: game))
        let source = """
        self:setBlock(ev.new < 10 and "glowstone" or "sea_lantern")
        """
        guard case .success = store.attach(
            lamp, name: "pulse", source: source, mode: .handler,
            triggers: [Trigger(event: .attributeChanged, attribute: "health", target: .object(.player))],
            by: .player, tick: 0
        ) else { return XCTFail("attach failed") }
        game.scripting.anyScriptsAttached = true

        game.runEventBusPhase() // load phase
        game.player.health = 5
        game.eventBus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("health"), "old": .number(20), "new": .number(5)],
            source: .player, tick: Int64(game.rpgSimulationTick)
        )
        game.runEventBusPhase() // delivery phase

        let cellAfter = Int(w.getBlock(lampX, lampY, lampZ))
        let idAfter = cellAfter >> 4
        let nameAfter = (idAfter >= 0 && idAfter < blockDefs.count) ? blockDefs[idAfter].name : "?"
        XCTAssertEqual(nameAfter, "glowstone")
        XCTAssertNil(store.get(lamp, "pulse")?.lastError)
    }

    func testModuleCanDeclareObserveAndEmitEventsOnAnotherObject() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-extensible-events")
        game.createWorld(name: "Extensible Events", seedText: "71", mode: GameMode.creative, difficulty: 2)
        let graph = ObjectGraph(host: game)
        let scripts = ScriptStore(graph: graph)
        let attributes = game.attributeStore
        let source = """
        player:declareEvent(
          "machine.ready",
          { count = "integer", note = "string?" },
          "A machine became ready"
        )
        player:onAttribute("mood", function(ev)
          world.attrs.last_mood = ev.new
        end)
        player:on("machine.ready", function(ev)
          world.attrs.ready_count = ev.count
          world.attrs.ready_subject = ev.subject.ref
        end)
        player:define("mood", "idle")
        player.attrs.mood = "active"
        player:set("favoriteColor", "blue")
        world.attrs.favorite_color_seen = player:get("favoriteColor")
        objects.get("self").attrs.alias_owner = self.ref
        player:emit("machine.ready", { count = 3 })
        """
        guard case .success = scripts.attach(
            .world, name: "controller", source: source, mode: .module,
            triggers: [], by: .player, tick: 0
        ) else { return XCTFail("attach failed") }
        game.scripting.anyScriptsAttached = true

        game.runEventBusPhase()

        let declaration = try XCTUnwrap(CustomEventStore(graph: graph).get(.player, "machine.ready"))
        XCTAssertEqual(declaration.summary, "A machine became ready")
        XCTAssertEqual(declaration.fields.map(\.typeToken), ["integer", "string?"])
        XCTAssertEqual(attributes.get(.world, "last_mood"), .string("active"))
        XCTAssertEqual(attributes.get(.player, "favorite_color"), .string("blue"))
        XCTAssertEqual(attributes.get(.world, "favorite_color_seen"), .string("blue"))
        XCTAssertEqual(attributes.get(.world, "alias_owner"), .string(ObjectRef.world.canonical))
        XCTAssertNil(attributes.get(.player, "alias_owner"))
        XCTAssertEqual(attributes.get(.world, "ready_count"), .int(3))
        XCTAssertEqual(attributes.get(.world, "ready_subject"), .string(ObjectRef.player.canonical))
        XCTAssertNil(scripts.get(.world, "controller")?.lastError)
        XCTAssertEqual(game.eventBus.scriptOwnedSubscriptionCount, 2)
    }

    func testCamelCaseLuaReusesLegacyCollapsedAttributeAndHandlerFilter() throws {
        let harness = try makeRuntimeHarness(seed: 971)
        _ = try harness.attributes.define(
            .world, "doorref", .string("legacy"), readonly: false, by: .player
        ).get()
        _ = try harness.scripts.attach(
            .world, name: "legacy_reader", source: """
            world:onAttribute("doorRef", function(ev)
              world.attrs.legacy_observed = ev.new
            end)
            world.attrs.legacy_before = world.attrs.doorRef
            world:set("doorRef", "updated")
            world:define("doorRef", "defined")
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true

        harness.runtime.runLoads()
        _ = harness.state.eventBus.runDeliveryPhase(tick: 0)

        XCTAssertEqual(harness.attributes.get(.world, "doorref"), .string("defined"))
        XCTAssertNil(harness.attributes.get(.world, "door_ref"))
        XCTAssertEqual(harness.attributes.get(.world, "legacy_before"), .string("legacy"))
        XCTAssertEqual(harness.attributes.get(.world, "legacy_observed"), .string("defined"))
        XCTAssertNil(harness.scripts.get(.world, "legacy_reader")?.lastError)
    }

    func testCamelCaseBuiltInsWinAcrossMethodDotWriteAndHandlerSurfaces() throws {
        let harness = try makeRuntimeHarness(seed: 972)
        let world = try XCTUnwrap(harness.host.worldsByDim[.overworld])
        let player = Player(world: world)
        world.addEntity(player)
        harness.host.localPlayer = player
        _ = try harness.scripts.attach(
            .world, name: "builtins", source: """
            player:onAttribute("maxHealth", function(ev)
              world.attrs.health_event_key = ev.key
            end)
            world.attrs.method_max = player:get("maxHealth")
            world.attrs.dot_max = player.maxHealth
            player:set("gameMode", "creative")
            world.attrs.method_mode = player:get("gameMode")
            player.onFire = true
            world.attrs.dot_fire = player.onFire
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true

        harness.runtime.runLoads()
        harness.state.eventBus.raise(
            kind: .attributeChanged, subject: .player,
            payload: ["key": .string("max_health"), "old": .number(19), "new": .number(20)],
            source: .engine, tick: 0
        )
        _ = harness.state.eventBus.runDeliveryPhase(tick: 0)

        XCTAssertEqual(harness.attributes.get(.world, "method_max"), .number(player.maxHealth))
        XCTAssertEqual(harness.attributes.get(.world, "dot_max"), .number(player.maxHealth))
        XCTAssertEqual(harness.attributes.get(.world, "method_mode"), .string("creative"))
        XCTAssertEqual(harness.attributes.get(.world, "dot_fire"), .bool(true))
        XCTAssertEqual(harness.attributes.get(.world, "health_event_key"), .string("max_health"))
        XCTAssertTrue(harness.attributes.list(.player).isEmpty, "built-ins must not fork custom keys")
        XCTAssertNil(harness.scripts.get(.world, "builtins")?.lastError)
    }

    func testCanonicalScriptSlotWinsOverLegacyCustomValueForCamelCaseAccess() throws {
        let harness = try makeRuntimeHarness(seed: 973)
        _ = try harness.attributes.define(
            .world, "doorref", .string("legacy"), readonly: false, by: .player
        ).get()
        _ = try harness.scripts.attach(
            .world, name: "door_ref", source: "", mode: .module,
            triggers: [], by: .player, tick: 0
        ).get()
        _ = try harness.scripts.attach(
            .world, name: "collision_reader", source: """
            world.attrs.canonical_was_nil = world.attrs.doorRef == nil
            world.attrs.doorRef = "must_fail"
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true

        harness.runtime.runLoads()

        XCTAssertEqual(harness.attributes.get(.world, "canonical_was_nil"), .bool(true))
        XCTAssertEqual(harness.attributes.get(.world, "doorref"), .string("legacy"))
        XCTAssertTrue(
            harness.scripts.get(.world, "collision_reader")?.lastError?.contains("detach it first") == true
        )
    }

    func testNestedHandlerAttachCanonicalizesAttributeFilterAndSurvivesCodecReload() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-nested-filter")
        game.createWorld(name: "Nested Filter", seedText: "72", mode: GameMode.creative, difficulty: 2)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        let managerSource = """
        world:attach(
          "watcher",
          "world.attrs.handler_seen = ev.new",
          {on = "attribute.changed", attr = "favoriteColor", target = player}
        )
        world:attach(
          "inventory_watcher",
          "world.attrs.inventory_event_seen = ev.key",
          {on = "attribute.changed", attr = "inventory[0]", target = player}
        )
        """
        _ = try scripts.attach(
            .world, name: "manager", source: managerSource, mode: .module,
            triggers: [], by: .player, tick: 0
        ).get()

        game.runEventBusPhase()
        game.runEventBusPhase()

        let watcher = try XCTUnwrap(scripts.get(.world, "watcher"))
        XCTAssertEqual(watcher.mode, .handler)
        XCTAssertEqual(watcher.triggers, [Trigger(
            event: .attributeChanged, attribute: "favorite_color", target: .object(.player)
        )])
        XCTAssertEqual(scripts.get(.world, "inventory_watcher")?.triggers, [Trigger(
            event: .attributeChanged, attribute: "inventory[0]", target: .object(.player)
        )])
        let encoded = ObjectRecordCodec.encode(game.worldObjectRecord(for: .world))
        let decoded = try XCTUnwrap(ObjectRecordCodec.decode(encoded, caps: .defaults))
        guard case .script(let decodedWatcher)? = decoded.entries["watcher"] else {
            return XCTFail("canonical handler record did not survive codec round-trip")
        }
        XCTAssertEqual(decodedWatcher.triggers, watcher.triggers)
        guard case .script(let decodedInventoryWatcher)? = decoded.entries["inventory_watcher"] else {
            return XCTFail("punctuated built-in handler record did not survive codec round-trip")
        }
        XCTAssertEqual(decodedInventoryWatcher.triggers.first?.attribute, "inventory[0]")

        var reloadedRecord = decoded
        reloadedRecord.entries.removeValue(forKey: "manager")
        let reloadedGame = PersistenceTestSupport.makeGame(owner: self, label: "script-nested-filter-reload")
        reloadedGame.createWorld(
            name: "Nested Filter Reload", seedText: "73", mode: GameMode.creative, difficulty: 2
        )
        reloadedGame.setWorldObjectRecord(reloadedRecord, for: .world)
        reloadedGame.scriptDefinitionsDidChange(for: .world, hasScripts: true)
        reloadedGame.runEventBusPhase()
        _ = try reloadedGame.attributeStore.set(
            .player, "favorite_color", .string("green"), by: .player
        ).get()
        reloadedGame.runEventBusPhase()
        XCTAssertEqual(
            reloadedGame.attributeStore.get(.world, "handler_seen"), .string("green"),
            "a decoded handler must load into a fresh runtime and receive its persisted filter"
        )
        XCTAssertNil(
            ScriptStore(graph: ObjectGraph(host: reloadedGame)).get(.world, "watcher")?.lastError
        )

        _ = try game.attributeStore.set(
            .player, "favorite_color", .string("blue"), by: .player
        ).get()
        game.runEventBusPhase()
        XCTAssertEqual(game.attributeStore.get(.world, "handler_seen"), .string("blue"))
        XCTAssertNil(scripts.get(.world, "watcher")?.lastError)

        let normalized = try scripts.attach(
            .world, name: "raw_normalized", source: "", mode: .handler,
            triggers: [Trigger(
                event: .attributeChanged, attribute: "favoriteColor", target: .object(.player)
            )], by: .player, tick: 0
        ).get()
        XCTAssertEqual(normalized.triggers.first?.attribute, "favorite_color")

        guard case .failure(.invalidTrigger(_)) = scripts.attach(
            .world, name: "wrong_event_filter", source: "", mode: .handler,
            triggers: [Trigger(
                event: .playerJoined, attribute: "favorite_color", target: .object(.player)
            )], by: .player, tick: 0
        ) else { return XCTFail("ScriptStore must reject an attribute filter on another event") }
    }

    func testLiveNestedAttachRejectsMalformedOptionsInsteadOfDefaulting() throws {
        let cases: [(options: String, expectedError: String)] = [
            ("42", "attach options must be a table"),
            ("{mode = \"handler\"}", "unknown attach option 'mode'"),
            ("{target = player}", "nonempty attach options require opts.on"),
            ("{on = 42}", "attach option 'on' must be an event name string"),
            ("{on = \"Player Joined\"}", "'Player Joined' is not a valid event name"),
            ("{on = \"test.ready\", target = \"player\"}", "attach option 'target' must be an object handle"),
            ("{on = \"attribute.changed\", attr = 42, target = player}", "attach option 'attr' must be an attribute name string"),
            ("{on = \"player.joined\", attr = \"health\", target = player}", "an attribute filter is valid only for attribute.changed"),
            ("{on = \"block.used\", target = player}", "the event does not apply to that target kind"),
            ("{on = \"unload\"}", "the event is reserved and has no producer"),
        ]

        for (index, testCase) in cases.enumerated() {
            let harness = try makeRuntimeHarness(seed: 1_100 + index)
            let managerName = "attach_manager_\(index)"
            let childName = "attach_child_\(index)"
            _ = try harness.scripts.attach(
                .world, name: managerName,
                source: "world:attach(\"\(childName)\", \"return true\", \(testCase.options))",
                mode: .module, triggers: [], by: .player, tick: 0
            ).get()
            harness.state.anyScriptsAttached = true

            harness.runtime.runLoads()

            XCTAssertNil(
                harness.scripts.get(.world, childName),
                "case \(index) must not silently attach a module"
            )
            let lastError = try XCTUnwrap(
                harness.scripts.get(.world, managerName)?.lastError,
                "case \(index) must fault the originating script"
            )
            XCTAssertTrue(
                lastError.contains(testCase.expectedError),
                "case \(index) expected '\(testCase.expectedError)' in '\(lastError)'"
            )
        }
    }

    func testLiveNestedAttachAcceptsEmptyModuleOptionsAndOpenCustomHandler() throws {
        let harness = try makeRuntimeHarness(seed: 1_120)
        _ = try harness.scripts.attach(
            .world, name: "attach_manager", source: """
            world:attach("empty_options_child", "return true", {})
            world:attach(
              "custom_event_child", "return true",
              {on = "test.ready", target = player}
            )
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true

        harness.runtime.runLoads()

        XCTAssertEqual(harness.scripts.get(.world, "empty_options_child")?.mode, .module)
        XCTAssertEqual(harness.scripts.get(.world, "empty_options_child")?.triggers, [])
        XCTAssertEqual(harness.scripts.get(.world, "custom_event_child")?.mode, .handler)
        XCTAssertEqual(harness.scripts.get(.world, "custom_event_child")?.triggers, [Trigger(
            event: try XCTUnwrap(EventKind.parse("test.ready")),
            attribute: nil,
            target: .object(.player)
        )])
        XCTAssertNil(harness.scripts.get(.world, "attach_manager")?.lastError)
    }

    func testScriptRecordCodecMigratesLegacyCamelCaseTriggerFilters() throws {
        let legacyCustom = ScriptRecord(
            name: "legacy_custom", source: "", enabled: true, mode: .handler,
            triggers: [Trigger(
                event: .attributeChanged, attribute: "doorref", target: .object(.world)
            )], author: .player, createdTick: 0
        )
        let legacyBuiltIn = ScriptRecord(
            name: "legacy_builtin", source: "", enabled: true, mode: .handler,
            triggers: [Trigger(
                event: .attributeChanged, attribute: "max_health", target: .object(.player)
            )], author: .player, createdTick: 0
        )
        let customText = ScriptRecordCodec.encode(legacyCustom)
            .replacingOccurrences(of: "doorref", with: "doorRef")
        let builtInText = ScriptRecordCodec.encode(legacyBuiltIn)
            .replacingOccurrences(of: "max_health", with: "maxHealth")
        let customBytes = Array(customText.utf8)
        let builtInBytes = Array(builtInText.utf8)
        let decodedCustom = try XCTUnwrap(ScriptRecordCodec.decode(
            customBytes, 0, customBytes.count, name: legacyCustom.name
        ))
        let decodedBuiltIn = try XCTUnwrap(ScriptRecordCodec.decode(
            builtInBytes, 0, builtInBytes.count, name: legacyBuiltIn.name
        ))
        XCTAssertEqual(decodedCustom.triggers.first?.attribute, "doorref")
        XCTAssertEqual(decodedBuiltIn.triggers.first?.attribute, "max_health")
    }

    func testEditingAndDetachingModuleAtomicallyReplaceRuntimeHandlersAndTimers() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-runtime-reconcile")
        game.createWorld(name: "Runtime Reconcile", seedText: "72", mode: GameMode.creative, difficulty: 2)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        let attributes = game.attributeStore
        let event = try XCTUnwrap(EventKind.parse("test.reload"))

        let firstSource = """
        register("later", function() end)
        every(1000, "later")
        player:on("test.reload", function(ev) world.attrs.observed_version = 1 end)
        world.attrs.loaded_version = 1
        """
        _ = try scripts.attach(
            .world, name: "controller", source: firstSource, mode: .module,
            triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()
        XCTAssertEqual(attributes.get(.world, "loaded_version"), .int(1))
        XCTAssertEqual(game.eventBus.scriptOwnedSubscriptionCount, 1)
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.durableTimers, 1)

        let secondSource = """
        register("later", function() end)
        every(1000, "later")
        player:on("test.reload", function(ev) world.attrs.observed_version = 2 end)
        world.attrs.loaded_version = 2
        """
        _ = try scripts.attach(
            .world, name: "controller", source: secondSource, mode: .module,
            triggers: [], by: .player, tick: 1
        ).get()
        game.runEventBusPhase()
        XCTAssertEqual(attributes.get(.world, "loaded_version"), .int(2))
        XCTAssertEqual(game.eventBus.scriptOwnedSubscriptionCount, 1, "the edited module must replace, not duplicate, its handler")
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.durableTimers, 1, "the edited module must replace its durable timer")

        game.eventBus.raise(kind: event, subject: .player, source: .player, tick: 2)
        game.runEventBusPhase()
        XCTAssertEqual(attributes.get(.world, "observed_version"), .int(2), "only the edited closure may receive the event")

        XCTAssertTrue(try scripts.detach(.world, "controller").get())
        game.eventBus.raise(kind: event, subject: .player, source: .player, tick: 3)
        game.runEventBusPhase()
        XCTAssertEqual(game.eventBus.scriptOwnedSubscriptionCount, 0)
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.liveScripts, 0)
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.durableTimers, 0)
        XCTAssertEqual(attributes.get(.world, "observed_version"), .int(2), "a detached module must not receive queued events")
    }

    func testFaultedModuleRollsBackPartialLifecycleAndWaitsForAnEdit() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-load-fault-reconcile")
        game.createWorld(name: "Fault Reconcile", seedText: "73", mode: GameMode.creative, difficulty: 2)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        let faultySource = """
        player:on("test.fault", function(ev) world.attrs.leaked = true end)
        every(1000, "missing_handler")
        error("load failed")
        """
        _ = try scripts.attach(
            .world, name: "faulty", source: faultySource, mode: .module,
            triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true

        game.runEventBusPhase()
        XCTAssertEqual(game.eventBus.scriptOwnedSubscriptionCount, 0)
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.durableTimers, 0)
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.liveScripts, 0)
        XCTAssertNotNil(scripts.get(.world, "faulty")?.lastError)
        let faultCount = game.eventBus.recentEvents().filter { $0.kind == .scriptFaulted }.count
        XCTAssertEqual(faultCount, 1)

        game.runEventBusPhase()
        XCTAssertEqual(
            game.eventBus.recentEvents().filter { $0.kind == .scriptFaulted }.count, faultCount,
            "an unchanged failed definition must not rerun and fault every tick"
        )

        _ = try scripts.attach(
            .world, name: "faulty", source: "world.attrs.recovered = true", mode: .module,
            triggers: [], by: .player, tick: 1
        ).get()
        game.runEventBusPhase()
        XCTAssertEqual(game.attributeStore.get(.world, "recovered"), .bool(true))
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.liveScripts, 1)
        XCTAssertNil(scripts.get(.world, "faulty")?.lastError)
    }

    func testLuaDetachRetiresOnlyTheNamedScriptAndBlocksItsQueuedHandler() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-lua-detach-exact")
        game.createWorld(name: "Exact Detach", seedText: "74", mode: GameMode.creative, difficulty: 2)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try scripts.attach(
            .world, name: "controller", source: """
            self:on("test.detach", function(ev)
              self:detach("victim")
              self:emit("test.victim")
            end)
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        _ = try scripts.attach(
            .world, name: "victim", source: """
            self:on("test.victim", function(ev)
              world.attrs.victim_ran = true
            end)
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()
        XCTAssertEqual(game.eventBus.scriptOwnedSubscriptionCount, 2)

        game.eventBus.raise(
            kind: try XCTUnwrap(EventKind.parse("test.detach")), subject: .world,
            source: .player, tick: 1
        )
        game.runEventBusPhase()
        XCTAssertNil(scripts.get(.world, "victim"))
        XCTAssertNotNil(scripts.get(.world, "controller"))
        XCTAssertNil(game.attributeStore.get(.world, "victim_ran"), "a queued stale closure must not run after its script is detached")

        game.runEventBusPhase()
        XCTAssertEqual(game.eventBus.scriptOwnedSubscriptionCount, 1, "only the detached script's subscription should be retired")
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.liveScripts, 1)
    }

    func testYieldingModuleDoesNotExposeHandlersBeforeLoadCompletes() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-loading-handler")
        game.createWorld(name: "Loading Handler", seedText: "75", mode: GameMode.creative, difficulty: 2)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try scripts.attach(
            .world, name: "loader", source: """
            self:on("test.early", function(ev) world.attrs.ran_early = true end)
            wait(1)
            world.attrs.load_finished = true
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.eventBus.raise(
            kind: try XCTUnwrap(EventKind.parse("test.early")), subject: .world,
            source: .player, tick: 0
        )

        game.runEventBusPhase()

        XCTAssertEqual(game.eventBus.scriptOwnedSubscriptionCount, 1)
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.liveScripts, 0)
        XCTAssertNil(game.attributeStore.get(.world, "ran_early"))
        XCTAssertNil(game.attributeStore.get(.world, "load_finished"))
    }

    func testUnloadIsSynchronousAndAllowsOnlyFinalCustomAttributeWrites() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-unload-capabilities")
        game.createWorld(name: "Unload Capabilities", seedText: "76", mode: GameMode.creative, difficulty: 2)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        let attributes = game.attributeStore
        let x = ifloor(game.player.x)
        let y = ifloor(game.player.y)
        let z = ifloor(game.player.z)
        let healthBefore = game.player.health
        let blockBefore = game.world.getBlock(x, y, z)
        let source = """
        self:declareEvent("test.unload", {})
        register("noop", function() end)
        register("unload", function()
          local function blocked(fn)
            local ok, err = pcall(fn)
            return (not ok) and string.find(tostring(err), "during unload", 1, true) ~= nil
          end
          world.attrs.unload_wait_blocked = blocked(function() wait(1) end)
          world.attrs.unload_ai_blocked = blocked(function() ai.await("hello") end)
          world.attrs.unload_timer_blocked = blocked(function() after(1, "noop") end)
          world.attrs.unload_attach_blocked = blocked(function() self:attach("child", "return true") end)
          world.attrs.unload_detach_blocked = blocked(function() self:detach("controller") end)
          world.attrs.unload_emit_blocked = blocked(function() self:emit("test.unload", {}) end)
          world.attrs.unload_on_blocked = blocked(function() self:on("test.unload", function() end) end)
          world.attrs.unload_declare_blocked = blocked(function() self:declareEvent("test.other", {}) end)
          world.attrs.unload_world_blocked = blocked(function()
            objects.block("overworld", \(x), \(y), \(z)):setBlock("stone")
          end)
          world.attrs.unload_builtin_blocked = blocked(function() player.health = 1 end)
          world.attrs.unload_register_blocked = blocked(function() register("late", function() end) end)
          world.attrs.unload_say_blocked = blocked(function() say("must not escape") end)
          world:define("unload_defined", 7)
          world.unload_direct = "done"
          world.attrs.unload_finished = true
        end)
        """
        _ = try scripts.attach(
            .world, name: "controller", source: source, mode: .module,
            triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()

        _ = try scripts.attach(
            .world, name: "controller", source: "world.attrs.replacement_loaded = true",
            mode: .module, triggers: [], by: .player, tick: 1
        ).get()
        game.runEventBusPhase()

        for name in [
            "unload_wait_blocked", "unload_ai_blocked", "unload_timer_blocked",
            "unload_attach_blocked", "unload_detach_blocked", "unload_emit_blocked",
            "unload_on_blocked", "unload_declare_blocked", "unload_world_blocked",
            "unload_builtin_blocked", "unload_register_blocked", "unload_say_blocked",
        ] {
            XCTAssertEqual(attributes.get(.world, name), .bool(true), name)
        }
        XCTAssertEqual(attributes.get(.world, "unload_defined"), .int(7))
        XCTAssertEqual(attributes.get(.world, "unload_direct"), .string("done"))
        XCTAssertEqual(attributes.get(.world, "unload_finished"), .bool(true))
        XCTAssertEqual(attributes.get(.world, "replacement_loaded"), .bool(true))
        XCTAssertNotNil(scripts.get(.world, "controller"), "the stale unload callback must not detach its replacement")
        XCTAssertNil(scripts.get(.world, "child"))
        XCTAssertEqual(game.player.health, healthBefore)
        XCTAssertEqual(game.world.getBlock(x, y, z), blockBefore)
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.liveScripts, 1)
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.suspendedCoroutines, 0)
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.durableTimers, 0)
        XCTAssertEqual(game.eventBus.scriptOwnedSubscriptionCount, 0)
    }

    func testLuaEventCascadeDepthIsPreservedThroughObjectHandlers() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-cascade-depth")
        game.createWorld(name: "Cascade Depth", seedText: "77", mode: GameMode.creative, difficulty: 2)
        var caps = EventBus.Caps.defaults
        caps.cascadeDepth = 2
        caps.maxEventsPerHandler = 32
        let bus = EventBus(caps: caps)
        game.scripting.eventBus = bus
        let runtime = try XCTUnwrap(game.scripting.scriptRuntime)
        bus.delivery = { [weak runtime] event, targets in runtime?.deliver(event, targets) }

        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try scripts.attach(
            .world, name: "cascade", source: """
            world:on("test.loop", function(ev)
              world.attrs.loop_count = (world.attrs.loop_count or 0) + 1
              world:emit("test.loop")
            end)
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()

        bus.raise(
            kind: try XCTUnwrap(EventKind.parse("test.loop")), subject: .world,
            source: .player, tick: Int64(game.rpgSimulationTick)
        )
        game.runEventBusPhase()

        XCTAssertEqual(game.attributeStore.get(.world, "loop_count"), .int(3))
        XCTAssertTrue(bus.recentEvents().contains { event in
            event.kind == .scriptOverBudget
                && event.payload["message"] == .string("cascade depth exceeded")
        })
    }

    func testYieldingHandlerKeepsItsCumulativeEmitBudget() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-yield-budget")
        game.createWorld(name: "Yield Budget", seedText: "78", mode: GameMode.creative, difficulty: 2)
        var caps = EventBus.Caps.defaults
        caps.maxEventsPerHandler = 2
        let bus = EventBus(caps: caps)
        game.scripting.eventBus = bus
        let runtime = try XCTUnwrap(game.scripting.scriptRuntime)
        bus.delivery = { [weak runtime] event, targets in runtime?.deliver(event, targets) }

        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try scripts.attach(
            .world, name: "budget", source: """
            world:on("test.budget", function(ev)
              local accepted = 0
              if world:emit("test.child") then accepted = accepted + 1 end
              if world:emit("test.child") then accepted = accepted + 1 end
              wait(1)
              if world:emit("test.child") then accepted = accepted + 1 end
              world.attrs.accepted_emits = accepted
            end)
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()

        bus.raise(
            kind: try XCTUnwrap(EventKind.parse("test.budget")), subject: .world,
            source: .player, tick: Int64(game.rpgSimulationTick)
        )
        game.runEventBusPhase()
        XCTAssertEqual(runtime.summary.suspendedCoroutines, 1)

        game.worldRec?.rpgSimulationTick += 1
        game.world.rpgSimulationTick += 1
        game.runEventBusPhase()

        XCTAssertEqual(game.attributeStore.get(.world, "accepted_emits"), .int(2))
        XCTAssertEqual(runtime.summary.suspendedCoroutines, 0)
        XCTAssertTrue(bus.recentEvents().contains { event in
            event.kind == .scriptOverBudget
                && event.payload["message"] == .string("handler event budget exceeded")
        })
    }

    func testModuleMayPublishTheFullCustomEventContractInOneLoad() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-event-contract-cap")
        game.createWorld(name: "Event Contract Cap", seedText: "79", mode: GameMode.creative, difficulty: 2)
        let graph = ObjectGraph(host: game)
        let scripts = ScriptStore(graph: graph)
        _ = try scripts.attach(
            .world, name: "publisher", source: """
            for i = 1, 16 do
              self:declareEvent("contract.e" .. i, {}, "Published event " .. i)
            end
            self.attrs.published_count = #self:events()
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true

        game.runEventBusPhase()

        XCTAssertEqual(CustomEventStore(graph: graph).list(.world).count, 16)
        XCTAssertEqual(game.attributeStore.get(.world, "published_count"), .int(16))
        XCTAssertNil(scripts.get(.world, "publisher")?.lastError)
    }

    func testDurableNamedTimerSurvivesRestartFiresFullEnvelopeAndKeepsIDMonotonic() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-durable-timer-restart")
        game.createWorld(name: "Durable Timer", seedText: "80", mode: GameMode.creative, difficulty: 2)
        let worldID = try XCTUnwrap(game.worldRec?.id)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        let source = """
        register("fire", function(ev)
          world.attrs.timer_kind = ev.kind
          world.attrs.timer_subject = ev.subject.ref
          world.attrs.timer_name = ev.name
          world.attrs.timer_source = ev.source
          world.attrs.timer_tick = ev.tick
        end)
        after(2, "fire")
        """
        _ = try scripts.attach(
            .world, name: "clock", source: source, mode: .module,
            triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()
        let firstID = try XCTUnwrap(game.scripting.scriptRuntime?.timers.first?.id)

        game.exitToTitle()
        game.loadWorld(worldID)
        game.worldRec?.rpgSimulationTick = 2
        game.world.rpgSimulationTick = 2
        game.runEventBusPhase()

        XCTAssertEqual(game.attributeStore.get(.world, "timer_kind"), .string("timer.fired"))
        XCTAssertEqual(game.attributeStore.get(.world, "timer_subject"), .string(ObjectRef.world.canonical))
        XCTAssertEqual(game.attributeStore.get(.world, "timer_name"), .string("fire"))
        XCTAssertEqual(game.attributeStore.get(.world, "timer_source"), .string("engine"))
        XCTAssertEqual(game.attributeStore.get(.world, "timer_tick"), .int(2))
        XCTAssertEqual(game.scripting.scriptRuntime?.summary.durableTimers, 0)

        let reloadedScripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try reloadedScripts.attach(
            .world, name: "clock", source: source + "\nworld.attrs.timer_reloaded = true",
            mode: .module, triggers: [], by: .player, tick: 2
        ).get()
        game.runEventBusPhase()
        let replacementID = try XCTUnwrap(game.scripting.scriptRuntime?.timers.first?.id)
        XCTAssertGreaterThan(replacementID, firstID)
    }

    func testPlayerLeftHandlerPersistsItsFinalAttributeBeforeShutdownSave() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-player-left-save")
        game.createWorld(name: "Player Left Save", seedText: "81", mode: GameMode.creative, difficulty: 2)
        let worldID = try XCTUnwrap(game.worldRec?.id)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try scripts.attach(
            .world, name: "farewell", source: """
            player:on("player.left", function(ev)
              world.attrs.last_departure_kind = ev.kind
              world.attrs.last_departure_subject = ev.subject.ref
            end)
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()

        game.exitToTitle()
        game.loadWorld(worldID)

        XCTAssertEqual(game.attributeStore.get(.world, "last_departure_kind"), .string("player.left"))
        XCTAssertEqual(game.attributeStore.get(.world, "last_departure_subject"), .string(ObjectRef.player.canonical))
    }

    func testInitialScriptRNGSeedIsStableAcrossProcesses() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-stable-rng-seed")
        game.createWorld(name: "Stable RNG", seedText: "82", mode: GameMode.creative, difficulty: 2)
        game.world.time = 12_345
        game.worldRec?.rpgSimulationTick = 17
        game.world.rpgSimulationTick = 17
        XCTAssertEqual(game.scriptingCommandContext().tick, 17)
        XCTAssertEqual(game.aiMutationContext(model: "test", requestID: 1).tick, 17)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try scripts.attach(
            .world, name: "stable", source: "world.attrs.first_rng = rng()",
            mode: .module, triggers: [], by: .player, tick: 17
        ).get()
        game.scripting.anyScriptsAttached = true

        var expectedStream = RandomX(mix32(hashString("world#stable")) ^ UInt32(17))
        let expected = Double(expectedStream.next()) / 4_294_967_296.0
        game.runEventBusPhase()

        XCTAssertEqual(game.attributeStore.get(.world, "first_rng"), .number(expected))
    }

    func testLuaCannotForgeBuiltInEngineEvent() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-built-in-emit-validation")
        game.createWorld(name: "Built-in Emit Validation", seedText: "83", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scripting.scriptRuntime)

        guard case .failure(let message) = runtime.runEphemeral(
            source: "player:emit(\"block.toolStrike\", {})", owner: .world
        ) else { return XCTFail("a built-in engine event must be refused") }
        XCTAssertTrue(message.contains("engine-produced"), message)
    }

    // MARK: - kill switch (doScripts gamerule)

    func testKillSwitchGameruleSuppressesThenReenables() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-killswitch")
        game.createWorld(name: "KillSwitch", seedText: "3", mode: GameMode.survival, difficulty: 2)
        let store = ScriptStore(graph: ObjectGraph(host: game))
        guard case .success = store.attach(
            .world, name: "flag", source: "world.attrs.ran = true", mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("attach failed") }
        game.scripting.anyScriptsAttached = true

        game.setGameRule("doScripts", 0)
        game.runEventBusPhase()
        XCTAssertNil(AttributeStore(graph: ObjectGraph(host: game)).get(.world, "ran"), "doScripts=0 must suppress every script")

        game.setGameRule("doScripts", 1)
        game.runEventBusPhase()
        XCTAssertEqual(AttributeStore(graph: ObjectGraph(host: game)).get(.world, "ran"), .bool(true), "doScripts=1 must re-enable")
    }

    func testKillSwitchConsumesEventsWithoutReplayingThemWhenReenabled() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-killswitch-events")
        game.createWorld(name: "KillSwitch Events", seedText: "31", mode: GameMode.survival, difficulty: 2)
        let kind = try XCTUnwrap(EventKind.parse("test.kill_switch_event"))
        let store = ScriptStore(graph: ObjectGraph(host: game))
        _ = try store.attach(
            .world, name: "listener", source: "world.attrs.forbidden_replay = true", mode: .handler,
            triggers: [Trigger(event: kind, attribute: nil, target: .object(.world))],
            by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()

        game.setGameRule("doScripts", 0)
        game.eventBus.raise(kind: kind, subject: .world, source: .engine, tick: 1)
        game.runEventBusPhase()
        XCTAssertEqual(game.eventBus.pendingCount, 0)
        XCTAssertNil(game.attributeStore.get(.world, "forbidden_replay"))

        game.setGameRule("doScripts", 1)
        game.runEventBusPhase()
        XCTAssertNil(game.attributeStore.get(.world, "forbidden_replay"))
    }

    func testMissingRuntimeConsumesEventsWithoutStaleReplay() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-missing-runtime-events")
        game.createWorld(name: "Missing Runtime Events", seedText: "32", mode: GameMode.survival, difficulty: 2)
        let kind = try XCTUnwrap(EventKind.parse("test.missing_runtime_event"))
        let store = ScriptStore(graph: ObjectGraph(host: game))
        _ = try store.attach(
            .world, name: "listener", source: "world.attrs.forbidden_runtime_replay = true", mode: .handler,
            triggers: [Trigger(event: kind, attribute: nil, target: .object(.world))],
            by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()
        game.scripting.scriptRuntime = nil

        game.eventBus.raise(kind: kind, subject: .world, source: .engine, tick: 1)
        game.runEventBusPhase()
        XCTAssertEqual(game.eventBus.pendingCount, 0)
        XCTAssertNil(game.attributeStore.get(.world, "forbidden_runtime_replay"))
    }

    // MARK: - trust gate (WorldRecord.scriptsEnabled)

    func testTrustGateRefusesUntrustedWorld() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-trust")
        game.createWorld(name: "Untrusted", seedText: "5", mode: GameMode.survival, difficulty: 2)
        // createWorld sets scriptsEnabled = true (Decision 11's own contract);
        // simulate an imported/migrated world by clearing it.
        guard var rec = game.worldRec else { return XCTFail("no world record") }
        XCTAssertTrue(rec.scriptsEnabled, "createWorld must persist scriptsEnabled true")
        rec.scriptsEnabled = false
        game.worldRec = rec

        let store = ScriptStore(graph: ObjectGraph(host: game))
        guard case .success = store.attach(
            .world, name: "flag", source: "world.attrs.ran = true", mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("attach failed") }
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()
        XCTAssertNil(AttributeStore(graph: ObjectGraph(host: game)).get(.world, "ran"), "an untrusted world must never run scripts")

        // `/script trust` flips it.
        let context = game.scriptingCommandContext()
        XCTAssertFalse(context.scriptsTrusted)
        let result = ScriptingCommands.run(command: "script", arguments: ["trust"], context: context)
        XCTAssertTrue(result.ok)
        XCTAssertTrue(game.worldRec?.scriptsEnabled ?? false)
        game.runEventBusPhase()
        XCTAssertEqual(AttributeStore(graph: ObjectGraph(host: game)).get(.world, "ran"), .bool(true), "trust must re-enable scripting")
    }

    func testExplicitEditorRunBypassesOnlyTrustWithoutLoadingAttachedScripts() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-editor-explicit-run")
        game.createWorld(name: "Editor Run", seedText: "53", mode: GameMode.creative, difficulty: 2)
        guard var record = game.worldRec else { return XCTFail("no world record") }
        record.scriptsEnabled = false
        game.worldRec = record

        let graph = ObjectGraph(host: game)
        let attributes = AttributeStore(graph: graph)
        let scripts = ScriptStore(graph: graph)
        guard case .success = scripts.attach(
            .world, name: "sibling", source: "world.attrs.sibling_loaded = true",
            mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("sibling attach failed") }
        game.scripting.anyScriptsAttached = true
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)

        guard case .failure(let ordinaryRefusal) = runtime.runEphemeral(
            source: "world.attrs.ordinary_run_seen = true", owner: .player
        ) else { return XCTFail("ordinary one-shot execution must remain trust-gated") }
        XCTAssertTrue(ordinaryRefusal.contains("not trusted"), ordinaryRefusal)
        XCTAssertNil(attributes.get(.world, "ordinary_run_seen"))

        guard case .success = runtime.runEphemeralForEditorExplicitRun(
            source: "world.attrs.editor_run_seen = true", owner: .player
        ) else { return XCTFail("an explicit editor Run should evaluate its visible draft") }
        XCTAssertEqual(attributes.get(.world, "editor_run_seen"), .bool(true))
        XCTAssertNil(attributes.get(.world, "sibling_loaded"), "editor Run must not load an attached sibling")
        XCTAssertEqual(runtime.summary.liveScripts, 0, "editor Run must not load any attached script")
        XCTAssertFalse(game.worldRec?.scriptsEnabled ?? true, "editor Run must not trust the world as a side effect")
    }

    func testExplicitEditorRunStillHonorsDoScriptsKillSwitchAndOpenWorld() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-editor-killswitch")
        game.createWorld(name: "Editor Kill Switch", seedText: "59", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let attributes = AttributeStore(graph: ObjectGraph(host: game))
        game.setGameRule("doScripts", 0)

        guard case .failure(let killSwitchRefusal) = runtime.runEphemeralForEditorExplicitRun(
            source: "world.attrs.editor_run_seen = true", owner: .player
        ) else { return XCTFail("editor Run must honor doScripts=0") }
        XCTAssertTrue(killSwitchRefusal.contains("doScripts"), killSwitchRefusal)
        XCTAssertNil(attributes.get(.world, "editor_run_seen"))

        let noWorldRuntime = try ScriptRuntime(
            host: FakeObjectGraphHost(), state: GameScriptingState(), say: { _ in }
        )
        guard case .failure(let noWorldRefusal) = noWorldRuntime.runEphemeralForEditorExplicitRun(
            source: "return true", owner: .world
        ) else { return XCTFail("editor Run must require an open world") }
        XCTAssertTrue(noWorldRefusal.contains("no world is loaded"), noWorldRefusal)
    }

    func testDryRunIgnoresTrustAndKillSwitchWithoutMutatingWorld() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-dry-run-gates")
        game.createWorld(name: "Dry Run Gates", seedText: "61", mode: GameMode.creative, difficulty: 2)
        guard var record = game.worldRec else { return XCTFail("no world record") }
        record.scriptsEnabled = false
        game.worldRec = record
        game.setGameRule("doScripts", 0)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let attributes = AttributeStore(graph: ObjectGraph(host: game))
        let scripts = ScriptStore(graph: ObjectGraph(host: game))

        XCTAssertEqual(
            runtime.dryRunOutcome(
                source: "world.attrs.dry_run_seen = true\nself:attach('dry_run_child', 'return true')",
                owner: .player, mode: .module
            ),
            .completed
        )
        XCTAssertNil(attributes.get(.world, "dry_run_seen"))
        XCTAssertNil(scripts.get(.player, "dry_run_child"))
        XCTAssertFalse(game.worldRec?.scriptsEnabled ?? true)
        XCTAssertEqual(game.world.gameRules["doScripts"], 0)
    }

    func testDryRunValidatesNestedAttachSourceAndCompleteOptionsWithoutMutation() throws {
        let harness = try makeRuntimeHarness(seed: 1_121)
        let cases: [(child: String, source: String, expectedError: String)] = [
            (
                "bad_nested_source",
                "world:attach(\"bad_nested_source\", \"if\")",
                "script source failed validation"
            ),
            (
                "bad_options_type",
                "world:attach(\"bad_options_type\", \"return true\", 42)",
                "attach options must be a table"
            ),
            (
                "unknown_option",
                "world:attach(\"unknown_option\", \"return true\", {mode = \"handler\"})",
                "unknown attach option 'mode'"
            ),
            (
                "bad_on",
                "world:attach(\"bad_on\", \"return true\", {on = \"Bad Event\"})",
                "'Bad Event' is not a valid event name"
            ),
            (
                "bad_attr",
                "world:attach(\"bad_attr\", \"return true\", {on = \"player.joined\", attr = \"health\", target = player})",
                "an attribute filter is valid only for attribute.changed"
            ),
            (
                "bad_target",
                "world:attach(\"bad_target\", \"return true\", {on = \"test.ready\", target = \"player\"})",
                "attach option 'target' must be an object handle"
            ),
        ]

        for testCase in cases {
            let outcome = harness.runtime.dryRunOutcome(
                source: testCase.source, owner: .world, mode: .module
            )
            guard case .failure(let message) = outcome else {
                XCTFail("expected dry-run failure for \(testCase.child), got \(outcome)")
                continue
            }
            XCTAssertTrue(
                message.contains(testCase.expectedError),
                "expected '\(testCase.expectedError)' in '\(message)'"
            )
            XCTAssertNil(harness.scripts.get(.world, testCase.child))
        }

        XCTAssertEqual(
            harness.runtime.dryRunOutcome(
                source: "world:attach(\"empty_options_child\", \"return true\", {})",
                owner: .world, mode: .module
            ),
            .completed
        )
        XCTAssertEqual(
            harness.runtime.dryRunOutcome(
                source: "world:attach(\"custom_event_child\", \"return true\", {on = \"test.ready\", target = player})",
                owner: .world, mode: .module
            ),
            .completed
        )
        XCTAssertNil(harness.scripts.get(.world, "empty_options_child"))
        XCTAssertNil(harness.scripts.get(.world, "custom_event_child"))
    }

    func testDryRunAndLiveValidateTopLevelHandlerOptionsAndEventBusShapeIdentically() throws {
        let cases: [(source: String, expectedError: String)] = [
            (
                "on(\"test.ready\", 42, function() end)",
                "on options must be a table"
            ),
            (
                "on(\"test.ready\", {bogus = true}, function() end)",
                "unknown on option 'bogus'"
            ),
            (
                "on(\"test.ready\", {target = \"player\"}, function() end)",
                "on option 'target' must be an object handle"
            ),
            (
                "on(\"test.ready\", {name = \"Bad Name\"}, function() end)",
                "on option 'name' must be a valid handler name"
            ),
            (
                "on(\"player.joined\", {target = world}, function() end)",
                "the event does not apply to that target kind"
            ),
            (
                "on(\"player.joined\", {target = player, attr = \"health\"}, function() end)",
                "an attribute filter is valid only for attribute.changed"
            ),
            (
                "on(\"unload\", function() end)",
                "the event is reserved and has no producer"
            ),
            (
                "subscribe(player, \"test.ready\", 42, function() end)",
                "subscribe options must be a table"
            ),
            (
                "subscribe(player, \"test.ready\", {target = world}, function() end)",
                "unknown subscribe option 'target'"
            ),
            (
                "subscribe(player, \"test.ready\", {attr = 42}, function() end)",
                "subscribe option 'attr' must be an attribute name string"
            ),
            (
                "subscribe({kind = \"block\"}, \"attribute.changed\", function() end)",
                "block.changed and attribute.changed require a block type filter"
            ),
            (
                "subscribe(player, \"block.used\", function() end)",
                "the event does not apply to that target kind"
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let harness = try makeRuntimeHarness(seed: 1_130 + index)
            let dryRun = harness.runtime.dryRunOutcome(
                source: testCase.source, owner: .world, mode: .module
            )
            guard case .failure(let dryRunError) = dryRun else {
                XCTFail("case \(index) expected dry-run failure, got \(dryRun)")
                continue
            }
            XCTAssertTrue(
                dryRunError.contains(testCase.expectedError),
                "case \(index) expected '\(testCase.expectedError)' in '\(dryRunError)'"
            )
            XCTAssertEqual(harness.state.eventBus.scriptOwnedSubscriptionCount, 0)

            let managerName = "handler_validation_\(index)"
            _ = try harness.scripts.attach(
                .world, name: managerName, source: testCase.source, mode: .module,
                triggers: [], by: .player, tick: 0
            ).get()
            harness.state.anyScriptsAttached = true
            harness.runtime.runLoads()

            let liveError = try XCTUnwrap(harness.scripts.get(.world, managerName)?.lastError)
            XCTAssertTrue(
                liveError.contains(testCase.expectedError),
                "case \(index) expected live '\(testCase.expectedError)' in '\(liveError)'"
            )
            XCTAssertEqual(harness.state.eventBus.scriptOwnedSubscriptionCount, 0)
        }

        let validHarness = try makeRuntimeHarness(seed: 1_150)
        XCTAssertEqual(
            validHarness.runtime.dryRunOutcome(
                source: """
                on("test.ready", {target = player, name = "ready"}, function() end)
                subscribe(player, "test.ready", {}, function() end)
                """, owner: .world, mode: .module
            ),
            .completed
        )
        XCTAssertEqual(validHarness.state.eventBus.scriptOwnedSubscriptionCount, 0)
    }

    func testDryRunAndLiveValidateHandleHandlerOptionsAndEventBusShapeIdentically() throws {
        let cases: [(source: String, expectedError: String)] = [
            (
                "world:on(\"test.ready\")",
                "on(event[, opts], fn)"
            ),
            (
                "world:on(\"test.ready\", {}, function() end, true)",
                "on(event[, opts], fn)"
            ),
            (
                "world:on(\"test.ready\", 42, function() end)",
                "h:on options must be a table"
            ),
            (
                "world:on(\"test.ready\", {atrr = \"state\"}, function() end)",
                "unknown h:on option 'atrr'"
            ),
            (
                "world:on(\"test.ready\", {target = player}, function() end)",
                "unknown h:on option 'target'"
            ),
            (
                "world:on(\"attribute.changed\", {attr = 42}, function() end)",
                "h:on option 'attr' must be an attribute name string"
            ),
            (
                "world:on(\"test.ready\", {name = \"Bad Name\"}, function() end)",
                "h:on option 'name' must be a valid handler name"
            ),
            (
                "world:on(\"player.joined\", function() end)",
                "the event does not apply to that target kind"
            ),
            (
                "player:on(\"player.joined\", {attr = \"health\"}, function() end)",
                "an attribute filter is valid only for attribute.changed"
            ),
            (
                "world:on(\"unload\", function() end)",
                "the event is reserved and has no producer"
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let harness = try makeRuntimeHarness(seed: 1_160 + index)
            let dryRun = harness.runtime.dryRunOutcome(
                source: testCase.source, owner: .world, mode: .module
            )
            guard case .failure(let dryRunError) = dryRun else {
                XCTFail("case \(index) expected dry-run failure, got \(dryRun)")
                continue
            }
            XCTAssertTrue(
                dryRunError.contains(testCase.expectedError),
                "case \(index) expected '\(testCase.expectedError)' in '\(dryRunError)'"
            )
            XCTAssertEqual(harness.state.eventBus.scriptOwnedSubscriptionCount, 0)

            let managerName = "handle_handler_validation_\(index)"
            _ = try harness.scripts.attach(
                .world, name: managerName, source: testCase.source, mode: .module,
                triggers: [], by: .player, tick: 0
            ).get()
            harness.state.anyScriptsAttached = true
            harness.runtime.runLoads()

            let liveError = try XCTUnwrap(harness.scripts.get(.world, managerName)?.lastError)
            XCTAssertTrue(
                liveError.contains(testCase.expectedError),
                "case \(index) expected live '\(testCase.expectedError)' in '\(liveError)'"
            )
            XCTAssertEqual(harness.state.eventBus.scriptOwnedSubscriptionCount, 0)
        }

        let validHarness = try makeRuntimeHarness(seed: 1_175)
        let validSource = """
        world:declareEvent("test.ready", {value = "integer"})
        world:on("test.ready", {name = "ready"}, function(ev)
          world.attrs.handle_value = ev.value
        end)
        world:on("test.open", {}, function()
          world.attrs.open_seen = true
        end)
        world:emit("test.ready", {value = 7})
        world:emit("test.open")
        """
        XCTAssertEqual(
            validHarness.runtime.dryRunOutcome(
                source: validSource, owner: .world, mode: .module
            ),
            .completed
        )
        XCTAssertEqual(validHarness.state.eventBus.scriptOwnedSubscriptionCount, 0)
        XCTAssertNil(validHarness.attributes.get(.world, "handle_value"))

        _ = try validHarness.scripts.attach(
            .world, name: "valid_handle_handlers", source: validSource, mode: .module,
            triggers: [], by: .player, tick: 0
        ).get()
        validHarness.state.anyScriptsAttached = true
        validHarness.runtime.runLoads()
        _ = validHarness.state.eventBus.runDeliveryPhase(tick: 0)

        XCTAssertNil(validHarness.scripts.get(.world, "valid_handle_handlers")?.lastError)
        XCTAssertEqual(validHarness.state.eventBus.scriptOwnedSubscriptionCount, 2)
        XCTAssertEqual(validHarness.attributes.get(.world, "handle_value"), .int(7))
        XCTAssertEqual(validHarness.attributes.get(.world, "open_seen"), .bool(true))
    }

    func testDryRunAndLiveRejectMalformedEmitArityAndTargetsIdentically() throws {
        let cases: [(source: String, expectedError: String)] = [
            (
                "emit()",
                "emit(name[, payload][, target])"
            ),
            (
                "emit(\"test.ready\", {}, world, true)",
                "emit(name[, payload][, target])"
            ),
            (
                "emit(\"test.ready\", {}, \"world\")",
                "emit target must be an object handle"
            ),
            (
                "emit(\"test.ready\", {}, {})",
                "emit target must be an object handle"
            ),
            (
                "world:emit()",
                "h:emit(name[, payload])"
            ),
            (
                "world:emit(\"test.ready\", {}, world)",
                "h:emit(name[, payload])"
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let harness = try makeRuntimeHarness(seed: 1_180 + index)
            let dryRun = harness.runtime.dryRunOutcome(
                source: testCase.source, owner: .world, mode: .module
            )
            guard case .failure(let dryRunError) = dryRun else {
                XCTFail("case \(index) expected dry-run failure, got \(dryRun)")
                continue
            }
            XCTAssertTrue(
                dryRunError.contains(testCase.expectedError),
                "case \(index) expected '\(testCase.expectedError)' in '\(dryRunError)'"
            )

            let managerName = "emit_validation_\(index)"
            _ = try harness.scripts.attach(
                .world, name: managerName, source: testCase.source, mode: .module,
                triggers: [], by: .player, tick: 0
            ).get()
            harness.state.anyScriptsAttached = true
            harness.runtime.runLoads()

            let liveError = try XCTUnwrap(harness.scripts.get(.world, managerName)?.lastError)
            XCTAssertTrue(
                liveError.contains(testCase.expectedError),
                "case \(index) expected live '\(testCase.expectedError)' in '\(liveError)'"
            )
        }

        let validHarness = try makeRuntimeHarness(seed: 1_190)
        let validSource = """
        world:declareEvent("test.ready", {value = "integer"})
        world:on("test.ready", function(ev)
          world.attrs.emitted_value = ev.value
        end)
        world:emit("test.ready", {value = 7})
        emit("test.ready", {value = 8}, world)
        """
        XCTAssertEqual(
            validHarness.runtime.dryRunOutcome(
                source: validSource, owner: .world, mode: .module
            ),
            .completed
        )
        XCTAssertEqual(validHarness.state.eventBus.scriptOwnedSubscriptionCount, 0)

        _ = try validHarness.scripts.attach(
            .world, name: "valid_emit_shapes", source: validSource, mode: .module,
            triggers: [], by: .player, tick: 0
        ).get()
        validHarness.state.anyScriptsAttached = true
        validHarness.runtime.runLoads()
        _ = validHarness.state.eventBus.runDeliveryPhase(tick: 0)

        XCTAssertNil(validHarness.scripts.get(.world, "valid_emit_shapes")?.lastError)
        XCTAssertEqual(validHarness.attributes.get(.world, "emitted_value"), .int(8))
    }

    func testDryRunAndLiveValidateObjectContractMethodArgumentsIdentically() throws {
        let cases: [(source: String, expectedError: String)] = [
            (
                "world:events(true)",
                "events() takes no arguments"
            ),
            (
                "world:declareEvent(\"test.ready\", {}, \"Ready\", true)",
                "declareEvent(name[, fields][, summary])"
            ),
            (
                "world:declareEvent(\"test.ready\", 42)",
                "declareEvent fields must be a table mapping names to type tokens"
            ),
            (
                "world:declareEvent(\"test.ready\", {}, true)",
                "declareEvent summary must be a string"
            ),
            (
                "world:undeclareEvent(\"test.ready\", true)",
                "undeclareEvent(name)"
            ),
            (
                "world:define(\"locked\", true, {}, true)",
                "define(name, value[, opts])"
            ),
            (
                "world:define(\"locked\", true, 42)",
                "define options must be a table"
            ),
            (
                "world:define(\"locked\", true, {readony = true})",
                "unknown define option 'readony'"
            ),
            (
                "world:define(\"locked\", true, {readonly = \"yes\"})",
                "define option 'readonly' must be a boolean"
            ),
            (
                "world:define(\"locked\", true, {force = 1})",
                "define option 'force' must be a boolean"
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let harness = try makeRuntimeHarness(seed: 1_200 + index)
            let dryRun = harness.runtime.dryRunOutcome(
                source: testCase.source, owner: .world, mode: .module
            )
            guard case .failure(let dryRunError) = dryRun else {
                XCTFail("case \(index) expected dry-run failure, got \(dryRun)")
                continue
            }
            XCTAssertTrue(
                dryRunError.contains(testCase.expectedError),
                "case \(index) expected '\(testCase.expectedError)' in '\(dryRunError)'"
            )
            XCTAssertNil(harness.attributes.get(.world, "locked"))

            let managerName = "object_contract_validation_\(index)"
            _ = try harness.scripts.attach(
                .world, name: managerName, source: testCase.source, mode: .module,
                triggers: [], by: .player, tick: 0
            ).get()
            harness.state.anyScriptsAttached = true
            harness.runtime.runLoads()

            let liveError = try XCTUnwrap(harness.scripts.get(.world, managerName)?.lastError)
            XCTAssertTrue(
                liveError.contains(testCase.expectedError),
                "case \(index) expected live '\(testCase.expectedError)' in '\(liveError)'"
            )
            XCTAssertNil(harness.attributes.get(.world, "locked"))
        }

        let validHarness = try makeRuntimeHarness(seed: 1_215)
        let validSource = """
        world:define("locked", 7, {readonly = true, force = false})
        world:declareEvent("test.ready", {value = "integer"}, "Ready event")
        local declarations = world:events()
        world:undeclareEvent("test.missing")
        """
        XCTAssertEqual(
            validHarness.runtime.dryRunOutcome(
                source: validSource, owner: .world, mode: .module
            ),
            .completed
        )
        XCTAssertNil(validHarness.attributes.get(.world, "locked"))

        _ = try validHarness.scripts.attach(
            .world, name: "valid_object_contracts", source: validSource, mode: .module,
            triggers: [], by: .player, tick: 0
        ).get()
        validHarness.state.anyScriptsAttached = true
        validHarness.runtime.runLoads()

        XCTAssertNil(validHarness.scripts.get(.world, "valid_object_contracts")?.lastError)
        guard case .value(let value, let readonly, _)? =
            validHarness.attributes.record(.world)?.entries["locked"] else {
            return XCTFail("expected the valid readonly attribute contract")
        }
        XCTAssertEqual(value, .int(7))
        XCTAssertTrue(readonly)
        XCTAssertNotNil(CustomEventStore(graph: ObjectGraph(host: validHarness.host)).get(
            .world, "test.ready"
        ))
    }

    func testDryRunAndLiveRejectExtraMutatingHandleArgumentsWithoutMutation() throws {
        let setHarness = try makeRuntimeHarness(seed: 1_220)
        let badSet = "world:set(\"arity_guard\", true, \"ignored\")"
        guard case .failure(let drySetError) = setHarness.runtime.dryRunOutcome(
            source: badSet, owner: .world, mode: .module
        ) else { return XCTFail("Check must reject extra h:set arguments") }
        XCTAssertTrue(drySetError.contains("set(name, value) requires a name and a value"))
        XCTAssertNil(setHarness.attributes.get(.world, "arity_guard"))
        guard case .failure(let liveSetError) = setHarness.runtime.runEphemeral(
            source: badSet, owner: .world
        ) else { return XCTFail("live execution must reject extra h:set arguments") }
        XCTAssertTrue(liveSetError.contains("set(name, value) requires a name and a value"))
        XCTAssertNil(setHarness.attributes.get(.world, "arity_guard"))

        let detachHarness = try makeRuntimeHarness(seed: 1_221)
        _ = try detachHarness.scripts.attach(
            .world, name: "child", source: "", mode: .module, triggers: [],
            by: .player, tick: 0
        ).get()
        let badDetach = "world:detach(\"child\", true)"
        guard case .failure(let dryDetachError) = detachHarness.runtime.dryRunOutcome(
            source: badDetach, owner: .world, mode: .module
        ) else { return XCTFail("Check must reject extra h:detach arguments") }
        XCTAssertTrue(dryDetachError.contains("detach(name)"))
        XCTAssertNotNil(detachHarness.scripts.get(.world, "child"))
        _ = try detachHarness.scripts.attach(
            .world, name: "bad_detacher", source: badDetach, mode: .module, triggers: [],
            by: .player, tick: 0
        ).get()
        detachHarness.state.anyScriptsAttached = true
        detachHarness.runtime.runLoads()
        XCTAssertTrue(
            detachHarness.scripts.get(.world, "bad_detacher")?.lastError?.contains("detach(name)")
                == true
        )
        XCTAssertNotNil(detachHarness.scripts.get(.world, "child"))

        let breakHarness = try makeRuntimeHarness(seed: 1_222)
        let world = try XCTUnwrap(breakHarness.host.worldsByDim[.overworld])
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        _ = world.setBlock(1, 64, 1, Int(cell(B.stone)))
        let originalCell = world.getBlock(1, 64, 1)
        let badBreak = "objects.block(\"overworld\", 1, 64, 1):breakBlock(true)"
        guard case .failure(let dryBreakError) = breakHarness.runtime.dryRunOutcome(
            source: badBreak, owner: .world, mode: .module
        ) else { return XCTFail("Check must reject extra breakBlock arguments") }
        XCTAssertTrue(dryBreakError.contains("breakBlock() takes no arguments"))
        XCTAssertEqual(world.getBlock(1, 64, 1), originalCell)
        _ = try breakHarness.scripts.attach(
            .world, name: "bad_breaker", source: badBreak, mode: .module, triggers: [],
            by: .player, tick: 0
        ).get()
        breakHarness.state.anyScriptsAttached = true
        breakHarness.runtime.runLoads()
        XCTAssertTrue(
            breakHarness.scripts.get(.world, "bad_breaker")?.lastError?.contains(
                "breakBlock() takes no arguments"
            ) == true
        )
        XCTAssertEqual(world.getBlock(1, 64, 1), originalCell)
    }

    func testAttributeMutationDryRunMatchesLiveValidationWithoutMutation() throws {
        let statelessCases: [(source: String, expectedError: String)] = [
            ("world:set(\"seed\", 1)", "'seed' is readonly"),
            ("world:set(\"difficulty\", 1)", "'difficulty' does not accept that value"),
            (
                "dim(\"overworld\"):set(\"dayTime\", 24000)",
                "'day_time' must be in 0...23999"
            ),
            (
                "world:define(\"difficulty\", \"hard\")",
                "'difficulty' is a built-in attribute"
            ),
            (
                "world.attrs.difficulty = \"hard\"",
                "'difficulty' is a built-in attribute"
            ),
            ("world:set(\"\", true)", "is not a valid attribute name"),
            ("world:define(\"\", true)", "is not a valid attribute name"),
            (
                "local k = string.rep('k', 257); world:set('payload', {[k] = 1})",
                "value rejected (map key exceeds 256 bytes)"
            ),
            (
                "objects.block(\"overworld\", 100, 64, 100):set(\"flag\", true)",
                "is not loaded"
            ),
        ]

        for (index, testCase) in statelessCases.enumerated() {
            let harness = try makeRuntimeHarness(seed: 1_230 + index)
            let beforeRecord = harness.attributes.record(.world)
            guard case .failure(let dryRunError) = harness.runtime.dryRunOutcome(
                source: testCase.source, owner: .world, mode: .module
            ) else {
                XCTFail("case \(index) expected Check failure")
                continue
            }
            XCTAssertTrue(
                dryRunError.contains(testCase.expectedError),
                "case \(index) expected '\(testCase.expectedError)' in '\(dryRunError)'"
            )
            XCTAssertEqual(harness.attributes.record(.world)?.revision, beforeRecord?.revision)

            guard case .failure(let liveError) = harness.runtime.runEphemeral(
                source: testCase.source, owner: .world
            ) else {
                XCTFail("case \(index) expected live failure")
                continue
            }
            XCTAssertTrue(
                liveError.contains(testCase.expectedError),
                "case \(index) expected live '\(testCase.expectedError)' in '\(liveError)'"
            )
            XCTAssertEqual(harness.attributes.record(.world)?.revision, beforeRecord?.revision)
        }

        let protectedCases: [(source: String, expectedError: String)] = [
            ("world:set(\"locked\", 2)", "'locked' is readonly"),
            ("world.attrs.locked = 2", "'locked' is readonly"),
            ("world.attrs.locked = nil", "'locked' is readonly"),
            ("world:define(\"locked\", 2)", "'locked' is readonly"),
            ("world:set(\"reserved\", true)", "'reserved' is an attached script"),
            ("world.attrs.reserved = true", "'reserved' is an attached script"),
            ("world:define(\"reserved\", true)", "'reserved' is an attached script"),
        ]
        for (index, testCase) in protectedCases.enumerated() {
            let harness = try makeRuntimeHarness(seed: 1_245 + index)
            _ = try harness.attributes.define(
                .world, "locked", .int(1), readonly: true, by: .player
            ).get()
            _ = try harness.scripts.attach(
                .world, name: "reserved", source: "", mode: .module, triggers: [],
                by: .player, tick: 0
            ).get()
            let beforeRevision = harness.attributes.record(.world)?.revision

            guard case .failure(let dryRunError) = harness.runtime.dryRunOutcome(
                source: testCase.source, owner: .world, mode: .module
            ) else {
                XCTFail("protected case \(index) expected Check failure")
                continue
            }
            XCTAssertTrue(dryRunError.contains(testCase.expectedError), dryRunError)
            XCTAssertEqual(harness.attributes.get(.world, "locked"), .int(1))
            XCTAssertNotNil(harness.scripts.get(.world, "reserved"))
            XCTAssertEqual(harness.attributes.record(.world)?.revision, beforeRevision)

            guard case .failure(let liveError) = harness.runtime.runEphemeral(
                source: testCase.source, owner: .world
            ) else {
                XCTFail("protected case \(index) expected live failure")
                continue
            }
            XCTAssertTrue(liveError.contains(testCase.expectedError), liveError)
            XCTAssertEqual(harness.attributes.get(.world, "locked"), .int(1))
            XCTAssertNotNil(harness.scripts.get(.world, "reserved"))
            XCTAssertEqual(harness.attributes.record(.world)?.revision, beforeRevision)
        }

        let capCases = [
            "world:set(\"overflow\", true)",
            "world.attrs.overflow = true",
            "world:define(\"overflow\", true)",
        ]
        for (index, source) in capCases.enumerated() {
            let harness = try makeRuntimeHarness(seed: 1_260 + index)
            for entry in 0..<harness.attributes.caps.maxEntriesPerObject {
                _ = try harness.attributes.define(
                    .world, "v\(entry)", .bool(true), readonly: false, by: .player
                ).get()
            }
            let beforeRevision = harness.attributes.record(.world)?.revision
            guard case .failure(let dryRunError) = harness.runtime.dryRunOutcome(
                source: source, owner: .world, mode: .module
            ) else { return XCTFail("cap case \(index) expected Check failure") }
            XCTAssertTrue(dryRunError.contains("too many attributes (limit 64)"), dryRunError)
            XCTAssertNil(harness.attributes.get(.world, "overflow"))
            XCTAssertEqual(harness.attributes.record(.world)?.revision, beforeRevision)

            guard case .failure(let liveError) = harness.runtime.runEphemeral(
                source: source, owner: .world
            ) else { return XCTFail("cap case \(index) expected live failure") }
            XCTAssertTrue(liveError.contains("too many attributes (limit 64)"), liveError)
            XCTAssertNil(harness.attributes.get(.world, "overflow"))
            XCTAssertEqual(harness.attributes.record(.world)?.revision, beforeRevision)
        }
    }

    func testSetBlockPreflightRejectsEveryInvalidShapeWithoutMutation() throws {
        let cases: [(call: String, expectedError: String)] = [
            ("setBlock(\"missing_block\")", "unknown block 'missing_block'"),
            ("setBlock(\"oak_stairs\", 42)", "setBlock options must be a table"),
            (
                "setBlock(\"oak_stairs\", {facing = \"east\", zz_bad = true})",
                "'zz_bad' is not a block attribute"
            ),
            (
                "setBlock(\"stone\", {facing = \"north\"})",
                "'facing' does not apply to this block"
            ),
            (
                "setBlock(\"oak_stairs\", {name = \"stone\"})",
                "'name' is readonly"
            ),
            (
                "setBlock(\"oak_stairs\", {facing = 7})",
                "'facing' does not accept that value"
            ),
            (
                "setBlock(\"snow\", {layers = 9})",
                "'layers' must be in 1...8"
            ),
        ]

        for (index, testCase) in cases.enumerated() {
            let harness = try makeRuntimeHarness(seed: 1_160 + index)
            let world = try XCTUnwrap(harness.host.worldsByDim[.overworld])
            let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
            chunk.status = .generated
            world.setChunk(chunk)
            _ = world.setBlock(1, 64, 1, Int(cell(B.stone)))
            let before = world.getBlock(1, 64, 1)
            let managerName = "setblock_invalid_\(index)"
            _ = try harness.scripts.attach(
                .world, name: managerName,
                source: "objects.block(\"overworld\", 1, 64, 1):\(testCase.call)",
                mode: .module, triggers: [], by: .player, tick: 0
            ).get()
            harness.state.anyScriptsAttached = true

            harness.runtime.runLoads()

            XCTAssertEqual(
                world.getBlock(1, 64, 1), before,
                "case \(index) must leave the original block byte-for-byte unchanged"
            )
            let error = try XCTUnwrap(harness.scripts.get(.world, managerName)?.lastError)
            XCTAssertTrue(
                error.contains(testCase.expectedError),
                "case \(index) expected '\(testCase.expectedError)' in '\(error)'"
            )
        }
    }

    func testSetBlockPreflightAppliesValidSortedOptionsAndDryRunNeverMutates() throws {
        let harness = try makeRuntimeHarness(seed: 1_170)
        let world = try XCTUnwrap(harness.host.worldsByDim[.overworld])
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        _ = world.setBlock(1, 64, 1, Int(cell(B.stone)))
        let stone = world.getBlock(1, 64, 1)
        let call = """
        objects.block("overworld", 1, 64, 1):setBlock(
          "oak_stairs", {half = "top", facing = "east", notify = false}
        )
        """

        XCTAssertEqual(
            harness.runtime.dryRunOutcome(source: call, owner: .world, mode: .module),
            .completed
        )
        XCTAssertEqual(world.getBlock(1, 64, 1), stone)
        guard case .failure(let dryRunError) = harness.runtime.dryRunOutcome(
            source: """
            objects.block("overworld", 1, 64, 1):setBlock(
              "oak_stairs", {facing = "east", zz_bad = true}
            )
            """, owner: .world, mode: .module
        ) else { return XCTFail("invalid option must fail Check") }
        XCTAssertTrue(dryRunError.contains("'zz_bad' is not a block attribute"), dryRunError)
        XCTAssertEqual(world.getBlock(1, 64, 1), stone)

        _ = try harness.scripts.attach(
            .world, name: "setblock_valid", source: call, mode: .module,
            triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()

        let finalCell = world.getBlock(1, 64, 1)
        XCTAssertEqual(finalCell >> 4, Int(try XCTUnwrap(bidOpt("oak_stairs"))))
        XCTAssertEqual(BlockStateCodec.decode(finalCell)["facing"], .string("east"))
        XCTAssertEqual(BlockStateCodec.decode(finalCell)["half"], .string("top"))
        XCTAssertNil(harness.scripts.get(.world, "setblock_valid")?.lastError)
    }

    func testSetBlockAtomicCommitPreservesScriptEventProvenance() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "setblock-provenance")
        game.createWorld(name: "SetBlock Provenance", seedText: "1171", mode: GameMode.creative, difficulty: 2)
        let y = game.world.info.minY + 1
        let chunk = Chunk(cx: 0, cz: 0, minY: game.world.info.minY, height: game.world.info.height)
        chunk.status = .generated
        game.world.setChunk(chunk)
        game.world.setBlock(0, y, 0, Int(cell(B.stone)))
        let ref = ObjectRef.block(dim: .overworld, x: 0, y: y, z: 0)
        guard case .success = game.eventBus.subscribe(
            subscriber: .world, scriptName: "observer", handler: "changed",
            target: .object(ref), event: .blockChanged, attribute: nil,
            createdBy: .player, tick: 0
        ) else { return XCTFail("block.changed subscription should be valid") }

        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try scripts.attach(
            .world, name: "atomic_builder",
            source: "objects.block(\"overworld\", 0, \(y), 0):setBlock(\"oak_stairs\", {facing = \"east\"})",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)

        runtime.runLoads()

        let event = try XCTUnwrap(game.eventBus.recentEvents().last {
            $0.kind == .blockChanged && $0.subject == ref
        })
        XCTAssertEqual(event.source, .script(owner: .world, name: "atomic_builder"))
        XCTAssertNil(scripts.get(.world, "atomic_builder")?.lastError)
    }

    func testGiveGrantsItemsToTheHostPlayerAndDryRunNeverMutates() throws {
        let harness = try makeRuntimeHarness(seed: 1_180)
        let world = try XCTUnwrap(harness.host.worldsByDim[.overworld])
        let player = Player(world: world)
        world.addEntity(player)
        harness.host.localPlayer = player
        let pickID = iid("iron_pickaxe")
        XCTAssertEqual(player.countItem(pickID), 0)

        // Editor "Check" validates the call but must never touch the inventory.
        XCTAssertEqual(
            harness.runtime.dryRunOutcome(
                source: "objects.get(\"player\"):give(\"iron_pickaxe\", 1)",
                owner: .world, mode: .module
            ),
            .completed
        )
        XCTAssertEqual(player.countItem(pickID), 0, "Check must not grant items")

        _ = try harness.scripts.attach(
            .world, name: "giver",
            source: "objects.get(\"player\"):give(\"iron_pickaxe\", 1)",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.state.anyScriptsAttached = true
        harness.runtime.runLoads()

        XCTAssertEqual(player.countItem(pickID), 1, "a live give must grant exactly one pickaxe")
        XCTAssertNil(harness.scripts.get(.world, "giver")?.lastError)
    }

    func testGivePreflightRejectsEveryInvalidShapeWithoutMutation() throws {
        // iron_pickaxe is a tool, so its stack limit is 1: any count outside 1...1 is refused.
        let cases: [(call: String, expectedError: String)] = [
            ("objects.get(\"player\"):give(\"missing_item\")", "unknown item 'missing_item'"),
            ("objects.get(\"player\"):give(\"iron_pickaxe\", 0)", "give count must be between 1 and 1 for 'iron_pickaxe'"),
            ("objects.get(\"player\"):give(\"iron_pickaxe\", 2)", "give count must be between 1 and 1 for 'iron_pickaxe'"),
            ("objects.block(\"overworld\", 1, 64, 1):give(\"iron_pickaxe\")", "give(item[, count]) is only valid on a player handle"),
        ]

        for (index, testCase) in cases.enumerated() {
            let harness = try makeRuntimeHarness(seed: 1_190 + index)
            let world = try XCTUnwrap(harness.host.worldsByDim[.overworld])
            let player = Player(world: world)
            world.addEntity(player)
            harness.host.localPlayer = player
            let pickID = iid("iron_pickaxe")
            let managerName = "give_invalid_\(index)"
            _ = try harness.scripts.attach(
                .world, name: managerName, source: testCase.call,
                mode: .module, triggers: [], by: .player, tick: 0
            ).get()
            harness.state.anyScriptsAttached = true

            harness.runtime.runLoads()

            XCTAssertEqual(player.countItem(pickID), 0, "case \(index) must not grant any item")
            let error = try XCTUnwrap(harness.scripts.get(.world, managerName)?.lastError)
            XCTAssertTrue(
                error.contains(testCase.expectedError),
                "case \(index) expected '\(testCase.expectedError)' in '\(error)'"
            )
        }
    }

    func testEditorOnlyRunEntryPointCannotSpreadOutsideItsRuntimeAndEditorCallSite() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let allowedOccurrenceCounts = [
            "Sources/ElysiumCore/Scripting/ScriptRuntime.swift": 1,
            "Sources/Elysium/ScriptEditorUI/ScriptEditorModel.swift": 1,
        ]
        let symbol = "runEphemeralForEditorExplicitRun"
        let manager = FileManager.default

        let sourcesRoot = repository.appendingPathComponent("Sources")
        let enumerator = try XCTUnwrap(manager.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ))
        let swiftFiles = (enumerator.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
        XCTAssertFalse(swiftFiles.isEmpty, "production Swift source scan must not be empty")

        var observedAllowedPaths = Set<String>()
        for file in swiftFiles {
            let relativePath = file.path.replacing(repository.path + "/", with: "")
            let source = try String(contentsOf: file, encoding: .utf8)
            let occurrenceCount = source.components(separatedBy: symbol).count - 1
            let expectedCount = allowedOccurrenceCounts[relativePath] ?? 0
            XCTAssertEqual(
                occurrenceCount, expectedCount,
                "editor-only execution entry point has an unexpected production reference in \(relativePath)"
            )
            if expectedCount > 0 { observedAllowedPaths.insert(relativePath) }
        }
        XCTAssertEqual(observedAllowedPaths, Set(allowedOccurrenceCounts.keys))
    }

    // MARK: - fault isolation at the GameCore level

    func testFaultingScriptNeverBlocksItsSiblingOrTheTick() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-fault")
        game.createWorld(name: "Fault", seedText: "9", mode: GameMode.survival, difficulty: 2)
        let store = ScriptStore(graph: ObjectGraph(host: game))
        _ = store.attach(.world, name: "bad", source: "error(\"boom\")", mode: .module, triggers: [], by: .player, tick: 0)
        _ = store.attach(.world, name: "good", source: "world.attrs.ran = true", mode: .module, triggers: [], by: .player, tick: 0)
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()
        XCTAssertNotNil(store.get(.world, "bad")?.lastError)
        XCTAssertEqual(AttributeStore(graph: ObjectGraph(host: game)).get(.world, "ran"), .bool(true))
    }

    // MARK: - /script command family: LAN-client gating

    func testScriptCommandRefusedOnLANClient() {
        XCTAssertNotNil(ScriptingCommands.lanClientRefusal(command: "script"))
        let host = FakeObjectGraphHost()
        host.isLANClient = true
        let graph = ObjectGraph(host: host)
        let store = AttributeStore(graph: graph)
        let target = ObjectTargetContext(currentDimension: .overworld, cursor: { nil })
        let context = ScriptingCommandContext(
            graph: graph, store: store, target: target, isLANClient: true, tick: 0, eventBus: EventBus(),
            scriptStore: ScriptStore(graph: graph), scriptRuntime: nil, scriptsTrusted: true, killSwitchOn: true,
            trustWorld: {}, setKillSwitch: { _ in }
        )
        let result = ScriptingCommands.run(command: "script", arguments: ["list"], context: context)
        XCTAssertFalse(result.ok)
    }

    // MARK: - /script list|show|attach|detach against a live object

    func testScriptListShowAttachDetachCommands() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-commands")
        game.createWorld(name: "Commands", seedText: "13", mode: GameMode.survival, difficulty: 2)
        let context = game.scriptingCommandContext()

        let attach = ScriptingCommands.run(
            command: "script", arguments: ["attach", "self", "greet", "module", "say(\"hi\")"], context: context
        )
        XCTAssertTrue(attach.ok, "\(attach.lines)")

        let list = ScriptingCommands.run(command: "script", arguments: ["list", "self"], context: context)
        XCTAssertTrue(list.ok)
        XCTAssertTrue(list.lines.contains { $0.contains("greet") })

        let show = ScriptingCommands.run(command: "script", arguments: ["show", "self", "greet"], context: context)
        XCTAssertTrue(show.ok)
        XCTAssertTrue(show.lines.contains { $0.contains("module") })

        let detach = ScriptingCommands.run(command: "script", arguments: ["detach", "self", "greet"], context: context)
        XCTAssertTrue(detach.ok)
        let listAfter = ScriptingCommands.run(command: "script", arguments: ["list", "self"], context: context)
        XCTAssertTrue(listAfter.ok)
        XCTAssertFalse(listAfter.lines.contains { $0.contains("greet") })
    }

    // MARK: - persistence codec round trips (the exact path a save/load cycle uses)

    func testScriptRecordRoundTripsThroughObjectRecordCodec() {
        let trigger = Trigger(event: .attributeChanged, attribute: "health", target: .object(.player))
        let builtInPunctuationTrigger = Trigger(
            event: .attributeChanged, attribute: "be.name",
            target: .object(.block(dim: .overworld, x: 1, y: 64, z: 1))
        )
        let record = ScriptRecord(
            name: "pulse", source: "self:setBlock(\"glowstone\")", enabled: true, mode: .handler,
            triggers: [trigger, builtInPunctuationTrigger], author: .player, createdTick: 42, apiVersion: 1,
            rngWords: [1, 2, 3, 4]
        )
        var objectRecord = ObjectRecord()
        objectRecord.entries["pulse"] = .script(record)
        objectRecord.revision = 7

        let text = ObjectRecordCodec.encode(objectRecord)
        guard let decoded = ObjectRecordCodec.decode(text, caps: .defaults) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(decoded.revision, 7)
        guard case .script(let decodedRecord)? = decoded.entries["pulse"] else {
            return XCTFail("expected a script entry")
        }
        XCTAssertEqual(decodedRecord.name, "pulse")
        XCTAssertEqual(decodedRecord.source, "self:setBlock(\"glowstone\")")
        XCTAssertTrue(decodedRecord.enabled)
        XCTAssertEqual(decodedRecord.mode, .handler)
        XCTAssertEqual(decodedRecord.triggers, [trigger, builtInPunctuationTrigger])
        XCTAssertEqual(decodedRecord.author, .player)
        XCTAssertEqual(decodedRecord.createdTick, 42)
        XCTAssertEqual(decodedRecord.rngWords, [1, 2, 3, 4])
        // Runtime-only fields never round-trip (§6.7).
        XCTAssertNil(decodedRecord.lastError)
    }

    func testScriptAndAttributeShareTheNamespaceWithoutCollision() {
        var record = ObjectRecord()
        record.entries["mood"] = .value(.string("curious"), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 0))
        let script = ScriptRecord(name: "brain", source: "", enabled: true, mode: .module, author: .player, createdTick: 0)
        record.entries["brain"] = .script(script)
        let text = ObjectRecordCodec.encode(record)
        guard let decoded = ObjectRecordCodec.decode(text, caps: .defaults) else { return XCTFail("decode failed") }
        guard case .value(.string("curious"), _, _)? = decoded.entries["mood"] else { return XCTFail("expected the value entry") }
        guard case .script? = decoded.entries["brain"] else { return XCTFail("expected the script entry") }
    }

    func testMalformedScriptEntryIsDroppedNotTheWholeRecord() {
        let text = """
        {"attrs":{"ok":{"by":"player","ro":false,"t":0,"v":"true"}},\
        "scripts":{"bad":{"src":"x"},"good":{"src":"","en":true,"mode":"module","by":"player","t":0,"api":1}},\
        "rev":1,"v":1}
        """
        guard let decoded = ObjectRecordCodec.decode(text, caps: .defaults) else { return XCTFail("whole document should not be refused") }
        XCTAssertNil(decoded.entries["bad"], "an entry missing required fields must be dropped")
        guard case .script? = decoded.entries["good"] else { return XCTFail("a well-formed sibling entry must survive") }
    }

    func testDurableTimerRegistryCodecRoundTrip() {
        let timers = [
            DurableTimer(id: 1, owner: .world, scriptName: "lumber", handlerName: "reset", wakeTick: 1200, intervalTicks: nil),
            DurableTimer(id: 2, owner: .block(dim: .overworld, x: 1, y: 64, z: 1), scriptName: "clock", handlerName: "tick", wakeTick: 20, intervalTicks: 20),
        ]
        let text = DurableTimerRegistryCodec.encode(timers)
        guard let decoded = DurableTimerRegistryCodec.decode(text) else { return XCTFail("decode failed") }
        XCTAssertEqual(Set(decoded.map(\.id)), Set(timers.map(\.id)))
        for timer in timers {
            guard let match = decoded.first(where: { $0.id == timer.id }) else { return XCTFail("missing timer \(timer.id)") }
            XCTAssertEqual(match.owner, timer.owner)
            XCTAssertEqual(match.scriptName, timer.scriptName)
            XCTAssertEqual(match.handlerName, timer.handlerName)
            XCTAssertEqual(match.wakeTick, timer.wakeTick)
            XCTAssertEqual(match.intervalTicks, timer.intervalTicks)
        }
    }

    func testDurableTimerRegistryRejectsCoercedFloatingPointNumbers() {
        let malformed = [
            "{\"timers\":[{\"id\":1e100,\"who\":\"world\",\"script\":\"s\",\"handler\":\"h\",\"wake\":1}],\"v\":1}",
            "{\"timers\":[{\"id\":1,\"who\":\"world\",\"script\":\"s\",\"handler\":\"h\",\"wake\":1.5}],\"v\":1}",
            "{\"timers\":[{\"id\":1,\"who\":\"world\",\"script\":\"s\",\"handler\":\"h\",\"wake\":1,\"every\":1e100}],\"v\":1}",
        ]
        for text in malformed {
            var diagnostics: [String] = []
            let decoded = DurableTimerRegistryCodec.decode(text) { diagnostics.append($0) }
            XCTAssertEqual(decoded, [])
            XCTAssertEqual(diagnostics.count, 1)
        }
    }

    func testDurableTimerAllocatorWrapsWithoutTrappingAfterMaximumRestoredID() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "timer-id-wrap")
        game.createWorld(name: "Timers", seedText: "1", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        runtime.restoreDurableTimers([
            DurableTimer(
                id: UInt64.max, owner: .world, scriptName: "s", handlerName: "h",
                wakeTick: 1, intervalTicks: nil
            ),
        ])
        XCTAssertEqual(runtime.allocateTimerID(), 1)
    }

    func testDurableTimerAllocatorWrapsInsideItsStrictCodecDomain() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "timer-id-codec-wrap")
        game.createWorld(name: "Timers", seedText: "1", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let maximum = UInt64(Int64.max)
        let text = DurableTimerRegistryCodec.encode([
            DurableTimer(
                id: maximum, owner: .world, scriptName: "s", handlerName: "h",
                wakeTick: 1, intervalTicks: nil
            ),
        ])
        let decoded = try XCTUnwrap(DurableTimerRegistryCodec.decode(text))
        runtime.restoreDurableTimers(decoded)
        XCTAssertEqual(runtime.allocateTimerID(), 1)
    }

    func testWorldRecordScriptTimersFieldRoundTripsAndOmitsWhenEmpty() throws {
        var rec = WorldRecord(id: "w1", name: "Timers", seed: 1, gameMode: 0, difficulty: 1)
        XCTAssertEqual(rec.scriptTimers, "")
        rec.scriptTimers = DurableTimerRegistryCodec.encode([
            DurableTimer(id: 1, owner: .world, scriptName: "a", handlerName: "b", wakeTick: 5, intervalTicks: nil),
        ])
        let encoder = JSONEncoder()
        let data = try encoder.encode(rec)
        let decoded = try JSONDecoder().decode(WorldRecord.self, from: data)
        XCTAssertEqual(decoded.scriptTimers, rec.scriptTimers)

        var empty = WorldRecord(id: "w2", name: "NoTimers", seed: 1, gameMode: 0, difficulty: 1)
        empty.scriptTimers = ""
        let emptyData = try encoder.encode(empty)
        let json = try XCTUnwrap(String(data: emptyData, encoding: .utf8))
        XCTAssertFalse(json.contains("scriptTimers"), "an empty scriptTimers must be omitted, exactly like scriptRegistry")
    }

    // MARK: - ScriptStore caps

    func testEphemeralRunCannotLeaveLifecycleOrAIWorkBehind() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "ephemeral-capabilities")
        game.createWorld(name: "Ephemeral", seedText: "41", mode: GameMode.creative, difficulty: 2)
        let context = game.scriptingCommandContext()
        let runtime = try XCTUnwrap(context.scriptRuntime)
        let blocked: [(String, String)] = [
            ("on(\"load\", function() end)", "on() is not available"),
            ("subscribe(self, \"load\", function() end)", "subscribe() is not available"),
            ("every(2, \"pulse\")", "timers are not available"),
            ("register(\"pulse\", function() end)", "register() is not available"),
            ("ai.ask(\"hello\")", "ai.ask() is not available"),
            ("self:attach(\"child\", \"say('hi')\")", "attach() is not available"),
        ]

        for (source, expected) in blocked {
            guard case .failure(let message) = runtime.runEphemeral(source: source, owner: .player) else {
                return XCTFail("ephemeral run unexpectedly accepted: \(source)")
            }
            XCTAssertTrue(message.contains(expected), "\(source): \(message)")
        }
        XCTAssertNil(context.scriptStore.get(.player, "child"))
        XCTAssertEqual(runtime.summary.suspendedCoroutines, 0)
        XCTAssertEqual(runtime.summary.durableTimers, 0)
    }

    func testEphemeralRunAndDryRunUseTheirThrowawayRNGStreams() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "transient-rng")
        game.createWorld(name: "Transient RNG", seedText: "43", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let source = "local value = rng()\nassert(value >= 0 and value < 1)"

        guard case .success = runtime.runEphemeral(source: source, owner: .player) else {
            return XCTFail("ephemeral rng should use its throwaway stream")
        }
        XCTAssertEqual(
            runtime.dryRunOutcome(source: source, owner: .player, mode: .module),
            .completed
        )
    }

    func testLuaEmitRejectsOversizedPayloadMapKeyBeforeEventBusRetention() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "emit-map-key-cap")
        game.createWorld(name: "Emit Map Key Cap", seedText: "45", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let custom = try XCTUnwrap(EventKind.parse("test.payload"))

        guard case .failure(let message) = runtime.runEphemeral(
            source: "local k = string.rep('k', 257); world:emit('test.payload', {[k] = 1})",
            owner: .player
        ) else {
            return XCTFail("Lua emit must reject a payload map key above the persistent value cap")
        }
        XCTAssertTrue(message.contains("event payload rejected"), message)
        XCTAssertTrue(message.contains("map key exceeds 256 bytes"), message)
        XCTAssertFalse(game.eventBus.recentEvents().contains { $0.kind == custom })
    }

    func testHandlerDryRunCompilesButDoesNotExecuteUnknownCustomEventPayloads() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "custom-event-dryrun")
        game.createWorld(name: "Custom Event Dry Run", seedText: "47", mode: GameMode.creative, difficulty: 2)
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let custom = try XCTUnwrap(EventKind.parse("quest.updated"))
        let source = """
        assert(ev.kind == "quest.updated")
        assert(ev.quest ~= nil, "a real custom payload may provide this field")
        """

        let outcome = runtime.dryRunOutcome(
            source: source, owner: .player, mode: .handler, handlerEvent: custom
        )
        guard case .compiledOnly(let reason) = outcome else {
            return XCTFail("unknown custom payload should compile without speculative execution: \(outcome)")
        }
        XCTAssertTrue(reason.contains("quest.updated"))
        XCTAssertTrue(reason.contains("payload schema"))
    }

    func testScriptStoreEnforcesEightScriptCap() {
        let host = FakeObjectGraphHost()
        let world = World(dim: .overworld, seed: 1)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        host.worldsByDim[.overworld] = world
        let store = ScriptStore(graph: ObjectGraph(host: host))
        for i in 0..<8 {
            let result = store.attach(.world, name: "s\(i)", source: "", mode: .module, triggers: [], by: .player, tick: 0)
            guard case .success = result else { return XCTFail("script \(i) should have attached: \(result)") }
        }
        let ninth = store.attach(.world, name: "s8", source: "", mode: .module, triggers: [], by: .player, tick: 0)
        guard case .failure(.tooManyScripts) = ninth else { return XCTFail("the 9th script must be refused") }
    }

    func testScriptStoreRefusesInvalidName() {
        let host = FakeObjectGraphHost()
        let world = World(dim: .overworld, seed: 1)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        host.worldsByDim[.overworld] = world
        let store = ScriptStore(graph: ObjectGraph(host: host))
        let result = store.attach(.world, name: "Bad Name!", source: "", mode: .module, triggers: [], by: .player, tick: 0)
        guard case .failure(.invalidName) = result else { return XCTFail("expected .invalidName, got \(result)") }
    }

    func testScriptStoreReattachPreservesDisabledStateUnlessExplicitlyChanged() throws {
        let host = FakeObjectGraphHost()
        let world = World(dim: .overworld, seed: 1)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        host.worldsByDim[.overworld] = world
        let store = ScriptStore(graph: ObjectGraph(host: host))
        _ = try store.attach(
            .world, name: "guard", source: "return 1", mode: .module, triggers: [],
            by: .player, tick: 1
        ).get()
        _ = try store.setEnabled(.world, "guard", false).get()

        let edited = try store.attach(
            .world, name: "guard", source: "return 2", mode: .module, triggers: [],
            by: .player, tick: 2
        ).get()
        XCTAssertFalse(edited.enabled, "editing source must not silently enable a disabled script")
        XCTAssertEqual(edited.createdTick, 1)

        let explicitlyEnabled = try store.attach(
            .world, name: "guard", source: "return 3", mode: .module, triggers: [],
            enabled: true, by: .player, tick: 3
        ).get()
        XCTAssertTrue(explicitlyEnabled.enabled)
    }

    // MARK: - `summary` (F3 line, scripting-ui-and-replication change 3)

    /// design.md §12's "F3 summary" reads `ScriptRuntime.summary` fresh every frame — this pins
    /// it as a pure function of session state (attach two live module scripts, a durable timer,
    /// and a suspended coroutine; the counts must match exactly, and reading it twice with no
    /// state change in between must produce byte-identical results).
    func testSummaryReflectsLiveScriptsTimersAndSuspendedCoroutinesDeterministically() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "script-summary")
        game.createWorld(name: "ScriptSummary", seedText: "5", mode: GameMode.survival, difficulty: 2)
        let store = ScriptStore(graph: ObjectGraph(host: game))

        guard case .success = store.attach(
            .world, name: "counter", source: "world.attrs.n = 1", mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("attach failed") }
        // A *named* timer (design.md §8.6: "after(n, 'handler'), every(n, 'handler') are
        // persisted in the registry... durable"), as opposed to a closure timer (live-only,
        // tracked as a suspended coroutine instead — this distinction is exactly what
        // `durableTimers` vs `suspendedCoroutines` must tell apart.
        guard case .success = store.attach(
            .dimension(.overworld), name: "waiter", source: "every(1000, 'tick')",
            mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("attach failed") }
        game.scripting.anyScriptsAttached = true
        game.runEventBusPhase()

        guard let runtime = game.scripting.scriptRuntime else { return XCTFail("no script runtime this session") }
        let first = runtime.summary
        XCTAssertEqual(first.liveScripts, 2)
        XCTAssertEqual(first.durableTimers, 1, "the named `every(...)` timer must be registered as durable")
        XCTAssertEqual(first.suspendedCoroutines, 0)

        let second = runtime.summary
        XCTAssertEqual(first, second, "reading the summary twice with no intervening state change must be byte-identical")

        let stats = ScriptingCommands.run(
            command: "script", arguments: ["stats"], context: game.scriptingCommandContext()
        )
        XCTAssertTrue(stats.ok)
        XCTAssertEqual(stats.lines.count, 3)
        XCTAssertTrue(stats.lines[0].contains("2 live"))
        XCTAssertTrue(stats.lines[1].contains("tokens available"))
        XCTAssertTrue(stats.lines[2].contains("events:"))
    }
}
