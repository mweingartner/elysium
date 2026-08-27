import ElysiumScript
import XCTest
@testable import ElysiumCore

@MainActor
final class FurnaceScriptTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        if smeltingRecipes.isEmpty { registerAllRecipes() }
        registerBlockEntityHandlers()
    }

    private func makeHarness() throws -> (
        host: FakeObjectGraphHost,
        state: GameScriptingState,
        runtime: ScriptRuntime,
        scripts: ScriptStore,
        attributes: AttributeStore,
        world: World,
        chunk: Chunk,
        furnace: BlockEntityData,
        ref: ObjectRef
    ) {
        let host = FakeObjectGraphHost()
        let world = World(dim: .overworld, seed: 91)
        let chunk = Chunk(
            cx: 0, cz: 0, minY: world.info.minY, height: world.info.height
        )
        chunk.status = .generated
        world.setChunk(chunk)
        _ = world.setBlock(2, 64, 3, Int(cell(B.furnace_lit)))
        let furnace = makeFurnaceBE(2, 64, 3, "furnace")
        world.setBlockEntity(furnace)
        host.worldsByDim[.overworld] = world

        let state = GameScriptingState()
        let runtime = try ScriptRuntime(host: host, state: state, say: { _ in })
        state.scriptRuntime = runtime
        state.eventBus.delivery = { [weak runtime] event, targets in
            runtime?.deliver(event, targets)
        }
        state.eventBus.deliveryAdmission = { [weak runtime] event, targets in
            runtime?.admittedDeliveryCount(for: event, targets: targets) ?? 0
        }
        world.hooks.scriptedFurnaceOutput = { [weak runtime] subject in
            runtime?.effectiveFurnaceOutput(for: subject)
        }
        world.hooks.raiseScriptEvent = { kind, subject, payload, source, subjectType in
            state.eventBus.raise(
                kind: kind, subject: subject, payload: payload, source: source,
                tick: host.currentTick, subjectType: subjectType
            )
        }
        let graph = ObjectGraph(host: host)
        return (
            host, state, runtime, ScriptStore(graph: graph), AttributeStore(graph: graph),
            world, chunk, furnace, .block(dim: .overworld, x: 2, y: 64, z: 3)
        )
    }

    func testAttachedOverrideConvertsExistingAndFutureOutputAndRaisesTypedEvent() throws {
        let harness = try makeHarness()
        harness.furnace.items = [
            ItemStack(iid("raw_copper"), 2), nil, ItemStack(iid("copper_ingot"), 47),
        ]
        harness.furnace.burnTime = 10
        harness.furnace.burnTotal = 1_600
        harness.furnace.cookTime = 199
        harness.furnace.cookTotal = 200
        harness.furnace.xpBank = 3
        let recipe = try XCTUnwrap(smeltResultFor(harness.furnace.items?[0] ?? nil, "furnace"))

        _ = try harness.scripts.attach(
            harness.ref, name: "iron_output", source: """
            self:setFurnaceOutput("iron_ingot")
            self:on("furnace.smeltCompleted", function(ev)
              self.attrs.last_input = ev.input
              self.attrs.last_recipe_output = ev.recipeOutput
              self.attrs.last_output = ev.output
              self.attrs.last_count = ev.count
              self.attrs.last_xp = ev.xp
              self.attrs.last_furnace_kind = ev.furnaceKind
            end)
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.effectiveFurnaceOutput(for: harness.ref), "iron_ingot")

        harness.chunk.modified = false
        try XCTUnwrap(beTickHandlers["furnace"])(harness.world, harness.furnace)

        XCTAssertEqual(harness.furnace.items?[0]?.count, 1)
        XCTAssertEqual(harness.furnace.items?[2]?.id, iid("iron_ingot"))
        XCTAssertEqual(harness.furnace.items?[2]?.count, 48)
        XCTAssertEqual(try XCTUnwrap(harness.furnace.xpBank), 3 + recipe.xp, accuracy: 0.000_001)
        XCTAssertTrue(harness.chunk.modified, "conversion/completion must be save-eligible itself")

        let report = harness.state.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(report.delivered, 1)
        XCTAssertEqual(harness.attributes.get(harness.ref, "last_input"), .string("raw_copper"))
        XCTAssertEqual(harness.attributes.get(harness.ref, "last_recipe_output"), .string("copper_ingot"))
        XCTAssertEqual(harness.attributes.get(harness.ref, "last_output"), .string("iron_ingot"))
        XCTAssertEqual(harness.attributes.get(harness.ref, "last_count"), .int(1))
        XCTAssertEqual(harness.attributes.get(harness.ref, "last_xp"), .number(recipe.xp))
        XCTAssertEqual(harness.attributes.get(harness.ref, "last_furnace_kind"), .string("furnace"))

        let event = try XCTUnwrap(harness.state.eventBus.recentEvents().last {
            $0.kind == .furnaceSmeltCompleted
        })
        XCTAssertEqual(event.subject, harness.ref)
        XCTAssertEqual(event.source, .engine)
        XCTAssertEqual(event.payload["recipeOutput"], .string("copper_ingot"))
        XCTAssertEqual(event.payload["output"], .string("iron_ingot"))
        XCTAssertEqual(event.payload["xp"], .number(recipe.xp))
        XCTAssertEqual(event.payload["furnaceKind"], .string("furnace"))
    }

    func testOverrideHonorsGatesAndIsRemovedOnDetachAndFault() throws {
        let harness = try makeHarness()
        harness.furnace.items = [
            ItemStack(iid("raw_copper"), 1), nil, ItemStack(iid("copper_ingot"), 1),
        ]

        XCTAssertEqual(
            harness.runtime.dryRunOutcome(
                source: "self:setFurnaceOutput('iron_ingot')",
                owner: harness.ref, mode: .module
            ),
            .completed
        )
        XCTAssertNil(harness.runtime.effectiveFurnaceOutput(for: harness.ref))
        guard case .failure(let runOnceError) = harness.runtime.runEphemeralForEditorExplicitRun(
            source: "self:setFurnaceOutput('iron_ingot')", owner: harness.ref
        ) else { return XCTFail("Run Once must refuse lifecycle output control") }
        XCTAssertTrue(runOnceError.contains("requires an attached script"))

        _ = try harness.scripts.attach(
            harness.ref, name: "controller", source: "self:setFurnaceOutput('iron_ingot')",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.effectiveFurnaceOutput(for: harness.ref), "iron_ingot")

        harness.world.gameRules["doScripts"] = 0
        XCTAssertNil(harness.runtime.effectiveFurnaceOutput(for: harness.ref))
        harness.world.gameRules["doScripts"] = 1
        XCTAssertEqual(harness.runtime.effectiveFurnaceOutput(for: harness.ref), "iron_ingot")
        harness.host.scriptsEnabled = false
        XCTAssertNil(harness.runtime.effectiveFurnaceOutput(for: harness.ref))
        harness.host.scriptsEnabled = true

        _ = try harness.scripts.detach(harness.ref, "controller").get()
        harness.runtime.runLoads()
        XCTAssertNil(harness.runtime.effectiveFurnaceOutput(for: harness.ref))

        _ = try harness.scripts.attach(
            harness.ref, name: "faulting",
            source: "self:setFurnaceOutput('iron_ingot'); error('after registration')",
            mode: .module, triggers: [], by: .player, tick: 1
        ).get()
        harness.host.currentTick = 1
        harness.runtime.resetPerTickCounters()
        harness.runtime.runLoads()
        XCTAssertNil(harness.runtime.effectiveFurnaceOutput(for: harness.ref))
        XCTAssertTrue(harness.scripts.get(harness.ref, "faulting")?.lastError?.contains("after registration") == true)
    }

    func testLiveCallbackFaultRevokesOverrideWithoutWaitingForUnload() throws {
        let harness = try makeHarness()
        _ = try harness.scripts.attach(
            harness.ref, name: "callback_fault",
            source: """
            self:setFurnaceOutput("iron_ingot")
            self:on("machine.trip", function(ev)
              error("callback fault")
            end)
            """,
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        harness.runtime.runLoads()
        XCTAssertEqual(harness.runtime.effectiveFurnaceOutput(for: harness.ref), "iron_ingot")

        harness.state.eventBus.raise(
            kind: try XCTUnwrap(EventKind.parse("machine.trip")),
            subject: harness.ref, source: .engine, tick: 1,
            subjectType: "furnace_lit"
        )
        XCTAssertEqual(harness.state.eventBus.runDeliveryPhase(tick: 1).delivered, 1)

        XCTAssertNil(harness.runtime.effectiveFurnaceOutput(for: harness.ref))
        XCTAssertTrue(
            harness.scripts.get(harness.ref, "callback_fault")?.lastError?.contains("callback fault") == true
        )
    }

    func testYieldedControllerCannotBeSilentlyReplacedBySiblingScript() throws {
        let harness = try makeHarness()
        _ = try harness.scripts.attach(
            harness.ref, name: "a_controller",
            source: "self:setFurnaceOutput('iron_ingot'); wait(1)",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        _ = try harness.scripts.attach(
            harness.ref, name: "b_controller",
            source: "self:setFurnaceOutput('gold_ingot')",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()

        harness.runtime.runLoads()
        XCTAssertNil(harness.runtime.effectiveFurnaceOutput(for: harness.ref))
        XCTAssertTrue(
            harness.scripts.get(harness.ref, "b_controller")?.lastError?.contains("already controlled") == true
        )

        harness.host.currentTick = 1
        harness.runtime.resetPerTickCounters()
        harness.runtime.runResumptions()
        XCTAssertEqual(harness.runtime.effectiveFurnaceOutput(for: harness.ref), "iron_ingot")
    }

    func testOverrideValidationRejectsUnknownItemStackOverflowAndOrphanBlockEntity() throws {
        let harness = try makeHarness()
        XCTAssertTrue(harness.runtime.dryRun(
            source: "self:setFurnaceOutput('not_registered')", owner: harness.ref, mode: .module
        )?.contains("unknown item") == true)

        harness.furnace.items = [nil, nil, ItemStack(iid("copper_ingot"), 2)]
        XCTAssertTrue(harness.runtime.dryRun(
            source: "self:setFurnaceOutput('iron_pickaxe')", owner: harness.ref, mode: .module
        )?.contains("stack limit") == true)

        _ = harness.world.setBlock(2, 64, 3, Int(cell(B.stone)))
        harness.world.setBlockEntity(harness.furnace)
        XCTAssertTrue(harness.runtime.dryRun(
            source: "self:setFurnaceOutput('iron_ingot')", owner: harness.ref, mode: .module
        )?.contains("requires a loaded furnace") == true)
    }
}
