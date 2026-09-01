// AIObjectGraphToolsTests.swift — ai-object-graph (change 2). design.md §9:
// query/mutation tool contracts, the §9.4 validation+dry-run gate, §9.5
// journal/undo round trips, the §9.1 bounded tool loop (fake-Ollama
// transport: native calls, text repair, malformed-args retry/give-up, the
// mutation cap, the turn limit, transport failure), and the §9.6 async
// broker seam on `ScriptRuntime` (in-flight budget, `ai.await` resumption
// across ticks, fallback to the 1c synchronous stub when no broker is
// attached). LAN-guest refusal at the real `CommandsM` call site is proven
// by `Tests/ElysiumResourcePackTests/LANGuestCommandGateTests.swift`.

import XCTest
@testable import ElysiumCore

@MainActor
final class AIObjectGraphToolsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    private func makeGameWithWorld(_ label: String) -> GameCore {
        let game = PersistenceTestSupport.makeGame(owner: self, label: label)
        game.createWorld(name: label, seedText: "7", mode: GameMode.survival, difficulty: 2)
        return game
    }

    private func args(_ object: [String: Any]) -> AIToolArguments { AIToolArguments(object: object) }

    // MARK: - query tools

    func testListObjectsFindsScriptedBlockNearPlayer() throws {
        let game = makeGameWithWorld("ai-list-objects")
        let x = ifloor(game.player.x) + 1, y = ifloor(game.player.y), z = ifloor(game.player.z)
        _ = game.world.setBlock(x, y, z, Int(cell(B.chest)))
        let ref = ObjectRef.block(dim: game.dim, x: x, y: y, z: z)
        _ = game.attributeStore.set(ref, "mood", .string("curious"), by: .player)

        let outcome = AIObjectGraphQueryTools.run("list_objects", args: args(["radius": 8]), context: game.aiQueryContext())
        XCTAssertFalse(outcome.refused)
        XCTAssertTrue(outcome.data?.contains(ref.canonical) == true)
    }

    func testGetObjectReportsAttrsAndScripts() throws {
        let game = makeGameWithWorld("ai-get-object")
        let ref = ObjectRef.player
        _ = game.attributeStore.set(ref, "mood", .string("happy"), by: .player)
        let outcome = AIObjectGraphQueryTools.run("get_object", args: args(["ref": "player"]), context: game.aiQueryContext())
        XCTAssertFalse(outcome.refused)
        XCTAssertTrue(outcome.data?.contains("\"mood\"") == true)
    }

    func testDescribeAttributesFiltersByKind() throws {
        let game = makeGameWithWorld("ai-describe-attrs")
        let outcome = AIObjectGraphQueryTools.run("describe_attributes", args: args(["kind": "player"]), context: game.aiQueryContext())
        XCTAssertFalse(outcome.refused)
        XCTAssertTrue(outcome.data?.contains("health") == true)
    }

    func testDescribeAttributesRejectsUnknownKind() throws {
        let game = makeGameWithWorld("ai-describe-attrs-bad")
        let outcome = AIObjectGraphQueryTools.run("describe_attributes", args: args(["kind": "spaceship"]), context: game.aiQueryContext())
        XCTAssertTrue(outcome.refused)
        XCTAssertEqual(outcome.stage, "args")
    }

    func testDescribeEventsIsDerivedFromTheEventDescriptorRegistry() throws {
        let game = makeGameWithWorld("ai-describe-events")
        let outcome = AIObjectGraphQueryTools.run(
            "describe_events", args: args(["kind": "script."]), context: game.aiQueryContext()
        )

        XCTAssertFalse(outcome.refused)
        XCTAssertTrue(outcome.data?.contains("script.attached") == true)
        for name in EventDescriptorRegistry.names where name.hasPrefix("script.") {
            XCTAssertTrue(outcome.data?.contains(name) == true, "missing registry event \(name)")
        }
    }

    func testDescribeEventsOmitsReservedEventsWithAndWithoutObjectRef() throws {
        let game = makeGameWithWorld("ai-describe-produced-events")

        let blockEvents = AIObjectGraphQueryTools.run(
            "describe_events", args: args(["kind": "block."]), context: game.aiQueryContext()
        )
        XCTAssertFalse(blockEvents.refused)
        XCTAssertTrue(blockEvents.data?.contains("\"name\":\"block.used\"") == true)
        XCTAssertFalse(blockEvents.data?.contains("\"name\":\"block.replaced\"") == true)
        XCTAssertFalse(blockEvents.data?.contains("\"name\":\"block.scheduledTick\"") == true)

        let playerLoad = AIObjectGraphQueryTools.run(
            "describe_events", args: args(["ref": "player", "kind": "load"]),
            context: game.aiQueryContext()
        )
        XCTAssertFalse(playerLoad.refused)
        XCTAssertTrue(playerLoad.data?.contains("\"name\":\"load\"") == true)

        let playerUnload = AIObjectGraphQueryTools.run(
            "describe_events", args: args(["ref": "player", "kind": "unload"]),
            context: game.aiQueryContext()
        )
        XCTAssertFalse(playerUnload.refused)
        XCTAssertEqual(playerUnload.data, "{\"events\":[]}")
    }

    func testAIAuthoringGuideNamesExactObjectEventAPIsAndEveryAvailableEvent() {
        let guide = ScriptAIAuthoringGuide.text
        for fragment in [
            "self:onAttribute(attribute, fn)", "self:declareEvent(name, fields[, summary])",
            "self:events()", "self:undeclareEvent(name)", "self:emit(name[, payload])",
            "self:setFurnaceOutput(\"iron_ingot\")", "furnace.smeltCompleted", "block.toolStrike",
            "player:give(item[, count])", "ev.by:give(\"iron_pickaxe\", 1)",
            "A declaration defines schema and discovery only", "unload is not an EventBus event",
            "register(\"unload\", fn)", "It receives no ev",
        ] {
            XCTAssertTrue(guide.contains(fragment), "AI guide is missing \(fragment)")
        }
        XCTAssertFalse(guide.contains("h:"))
        XCTAssertFalse(guide.contains("target:on"))
        XCTAssertFalse(guide.contains("- unload ["), "unload finalization must not be listed as an event")
        for descriptor in EventDescriptorRegistry.available {
            XCTAssertTrue(
                guide.contains("- \(descriptor.kind.rawValue) ["),
                "AI guide is missing available event \(descriptor.kind.rawValue)"
            )
        }
    }

    func testCheckScriptReportsCompileErrorWithRealRuntime() throws {
        let game = makeGameWithWorld("ai-check-script")
        let outcome = AIObjectGraphQueryTools.run("check_script", args: args(["source": "this is not lua("]), context: game.aiQueryContext())
        XCTAssertFalse(outcome.refused, "check_script always succeeds as a tool call; the failure is in its payload")
        XCTAssertTrue(outcome.data?.contains("\"accepted\":false") == true)
    }

    func testCheckScriptFallsBackWithoutARuntime() throws {
        let host = FakeObjectGraphHost()
        let graph = ObjectGraph(host: host)
        let target = ObjectTargetContext(currentDimension: .overworld, cursor: { nil })
        let context = AIQueryContext(
            graph: graph, store: AttributeStore(graph: graph), scriptStore: ScriptStore(graph: graph),
            eventBus: EventBus(), target: target, scriptRuntime: nil
        )
        let outcome = AIObjectGraphQueryTools.run("check_script", args: args(["source": "return 1"]), context: context)
        XCTAssertFalse(outcome.refused)
        XCTAssertTrue(outcome.data?.contains("note") == true)
    }

    func testRecentEventsRespectsLimit() throws {
        let game = makeGameWithWorld("ai-recent-events")
        for _ in 0..<5 {
            _ = game.eventBus.raise(kind: EventKind.parse("lumber.milestone")!, subject: .player, source: .player, tick: 0)
        }
        let outcome = AIObjectGraphQueryTools.run("recent_events", args: args(["limit": 2]), context: game.aiQueryContext())
        XCTAssertFalse(outcome.refused)
        XCTAssertEqual(outcome.data?.components(separatedBy: "\"seq\"").count, 3, "2 events -> 3 pieces when split on the field name")
    }

    // MARK: - mutation tools + journal

    func testSetAttributeCreatesJournalsAndUndoes() throws {
        let game = makeGameWithWorld("ai-set-attr")
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let outcome = AIObjectGraphMutationTools.run(
            "set_attribute", args: args(["ref": "player", "key": "mood", "value": "curious"]), context: ctx
        )
        XCTAssertFalse(outcome.refused)
        XCTAssertEqual(game.attributeStore.get(.player, "mood"), .string("curious"))
        XCTAssertEqual(game.scripting.aiJournal.list().count, 1)
        XCTAssertEqual(game.scripting.aiJournal.list().first?.tool, "set_attribute")

        let undoLines = game.scripting.aiJournal.undo(groups: 1, context: AIUndoContext(
            graph: game.aiQueryContext().graph, store: game.aiQueryContext().store, scriptStore: game.aiQueryContext().scriptStore,
            eventBus: game.eventBus, tick: 0
        ))
        XCTAssertTrue(undoLines.contains { $0.contains("removed") })
        XCTAssertNil(game.attributeStore.get(.player, "mood"))
        XCTAssertTrue(game.scripting.aiJournal.isEmpty)
    }

    func testAIUsesCanonicalCamelCaseAttributesAndReusesLegacyCollapsedKeys() throws {
        let game = makeGameWithWorld("ai-camel-attr-compat")
        _ = try game.attributeStore.define(
            .player, "doorref", .string("legacy"), readonly: false, by: .player
        ).get()
        let requestID = game.scripting.aiJournal.beginRequest()
        let context = game.aiMutationContext(model: "test-model", requestID: requestID)

        let fresh = AIObjectGraphMutationTools.run(
            "set_attribute",
            args: args(["ref": "player", "key": "favoriteColor", "value": "blue"]),
            context: context
        )
        let legacy = AIObjectGraphMutationTools.run(
            "set_attribute",
            args: args(["ref": "player", "key": "doorRef", "value": "updated"]),
            context: context
        )

        XCTAssertFalse(fresh.refused)
        XCTAssertFalse(legacy.refused)
        XCTAssertEqual(game.attributeStore.get(.player, "favorite_color"), .string("blue"))
        XCTAssertNil(game.attributeStore.get(.player, "favoritecolor"))
        XCTAssertEqual(game.attributeStore.get(.player, "doorref"), .string("updated"))
        XCTAssertNil(game.attributeStore.get(.player, "door_ref"))
    }

    func testAICanonicalizesCamelCaseSubscriptionAndHandlerTriggerFilters() throws {
        let game = makeGameWithWorld("ai-camel-filter-compat")
        let store = ScriptStore(graph: game.aiQueryContext().graph)
        _ = try store.attach(
            .player, name: "brain", source: "register('changed', function(ev) end)",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        let requestID = game.scripting.aiJournal.beginRequest()
        let context = game.aiMutationContext(model: "test-model", requestID: requestID)

        let subscription = AIObjectGraphMutationTools.run(
            "subscribe", args: args([
                "subscriber": "player", "target": "player", "event": "attribute.changed",
                "attr": "favoriteColor", "handler": "brain.changed",
            ]), context: context
        )
        let handler = AIObjectGraphMutationTools.run(
            "attach_script", args: args([
                "ref": "world", "name": "watcher", "source": "world.attrs.seen = ev.new",
                "mode": "handler",
                "triggers": "[{\"event\":\"attribute.changed\",\"attr\":\"favoriteColor\",\"target\":\"player\"}]",
            ]), context: context
        )

        XCTAssertFalse(subscription.refused, subscription.message ?? "")
        XCTAssertFalse(handler.refused, handler.message ?? "")
        XCTAssertEqual(game.eventBus.listSubscriptions().first?.attribute, "favorite_color")
        XCTAssertEqual(store.get(.world, "watcher")?.triggers.first?.attribute, "favorite_color")
    }

    func testSetBuiltInAttributePublishesAIProvenanceAndUndoRestoresThroughHostSetter() throws {
        let game = makeGameWithWorld("ai-set-built-in")
        let before = game.player.health
        _ = game.eventBus.subscribe(
            subscriber: .player, scriptName: "health_watch", handler: "changed",
            target: .object(.player), event: .attributeChanged, attribute: "health",
            createdBy: .player, tick: 0
        )
        var delivered: [ScriptEvent] = []
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty { delivered.append(event) }
        }
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)

        let outcome = AIObjectGraphMutationTools.run(
            "set_attribute", args: args(["ref": "player", "key": "health", "value": 7]),
            context: ctx
        )
        XCTAssertFalse(outcome.refused)
        XCTAssertEqual(game.player.health, 7)
        XCTAssertEqual(game.scripting.aiJournal.list().count, 1)
        game.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered.last?.source, .ai(model: "test-model"))
        XCTAssertEqual(delivered.last?.payload["old"], .number(before))
        XCTAssertEqual(delivered.last?.payload["new"], .number(7))

        let persisted = game.scripting.aiJournal.encodePersisted()
        let reloaded = AIJournal()
        reloaded.loadPersisted(from: persisted)
        let undoLines = reloaded.undo(groups: 1, context: undoContext(game))
        XCTAssertTrue(undoLines.contains { $0.contains("restored") })
        XCTAssertEqual(game.player.health, before)
        game.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered.last?.source, .player)
        XCTAssertEqual(delivered.last?.payload["old"], .number(7))
        XCTAssertEqual(delivered.last?.payload["new"], .number(before))
    }

    func testAIJournalRejectsCoercedFloatingPointIdentifiersWithoutPoisoningAllocator() {
        let text = """
        {"entries":[{"id":1e100,"req":1,"tool":"set_attribute","ref":"player",\
        "name":"mood","t":0,"model":"test","after":"hash","undo":{"k":"none"}}],"src":{},"v":1}
        """
        let journal = AIJournal()
        var diagnostics: [String] = []
        journal.loadPersisted(from: text) { diagnostics.append($0) }
        XCTAssertTrue(journal.isEmpty)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertEqual(journal.beginRequest(), 1)
    }

    func testAIJournalAllocatorsWrapInsideTheirStrictCodecDomain() {
        let maximum = Int64.max
        let text = """
        {"entries":[{"id":\(maximum),"req":\(maximum),"tool":"set_attribute","ref":"player",\
        "name":"mood","t":0,"model":"test","after":"hash","undo":{"k":"none"}}],"src":{},"v":1}
        """
        let journal = AIJournal()
        journal.loadPersisted(from: text)
        let requestID = journal.beginRequest()
        XCTAssertEqual(requestID, 1)
        XCTAssertEqual(
            journal.record(
                requestID: requestID, tool: "set_attribute", ref: .player, name: "mood",
                tick: 1, model: "test", afterHash: "hash2", undo: .none
            ),
            1
        )

        let reloaded = AIJournal()
        reloaded.loadPersisted(from: journal.encodePersisted())
        XCTAssertEqual(reloaded.entries.map(\.id), [UInt64(maximum), 1])
        XCTAssertEqual(reloaded.entries.map(\.requestID), [UInt64(maximum), 1])
    }

    func testAIJournalRestoreReappliesRingAndSourceSideListCaps() throws {
        let entries = (1...70).map { id in
            "{\"id\":\(id),\"req\":\(id),\"tool\":\"set_attribute\",\"ref\":\"player\","
                + "\"name\":\"mood\",\"t\":\(id),\"model\":\"test\",\"after\":\"hash\","
                + "\"undo\":{\"k\":\"none\"}}"
        }.joined(separator: ",")
        let sources = (65...70).map { id in
            "\"\(id)\":\"source-\(id)\""
        }.joined(separator: ",")
        let persisted = "{\"entries\":[\(entries)],\"src\":{\(sources)},\"v\":1}"
        var diagnostics: [String] = []
        let journal = AIJournal()

        journal.loadPersisted(from: persisted) { diagnostics.append($0) }

        XCTAssertEqual(journal.entries.count, AIJournal.maxEntries)
        XCTAssertEqual(journal.entries.first?.id, 7, "restore keeps the newest valid ring suffix")
        XCTAssertEqual(journal.entries.last?.id, 70)
        XCTAssertEqual(journal.previousScriptSources.count, AIJournal.maxSourceSideListEntries)
        XCTAssertEqual(Set(journal.previousScriptSources.keys), Set([67, 68, 69, 70]))
        XCTAssertLessThanOrEqual(
            journal.previousScriptSources.values.reduce(0) { $0 + $1.utf8.count },
            AIJournal.maxSourceSideListBytes
        )
        XCTAssertLessThanOrEqual(journal.encodePersisted().utf8.count, AIJournal.maxTotalBytes)
        XCTAssertTrue(diagnostics.contains("trimmed over-cap AI journal persistence"))
        XCTAssertEqual(journal.beginRequest(), 71)
    }

    func testDefineAttributeReadonlyRequiresForce() throws {
        let game = makeGameWithWorld("ai-define-attr")
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        _ = AIObjectGraphMutationTools.run(
            "define_attribute", args: args(["ref": "player", "key": "maxspeed", "value": 4, "readonly": true]), context: ctx
        )
        let refused = AIObjectGraphMutationTools.run(
            "define_attribute", args: args(["ref": "player", "key": "maxspeed", "value": 5]), context: ctx
        )
        XCTAssertTrue(refused.refused)
        let forced = AIObjectGraphMutationTools.run(
            "define_attribute", args: args(["ref": "player", "key": "maxspeed", "value": 5, "force": true]), context: ctx
        )
        XCTAssertFalse(forced.refused)
        XCTAssertEqual(game.attributeStore.get(.player, "maxspeed"), .int(5))
    }

    func testRemoveAttributeJournalsAndUndoRestores() throws {
        let game = makeGameWithWorld("ai-remove-attr")
        _ = game.attributeStore.set(.player, "note", .string("hi"), by: .player)
        _ = game.eventBus.subscribe(
            subscriber: .player, scriptName: "note_watch", handler: "changed",
            target: .object(.player), event: .attributeChanged, attribute: "note",
            createdBy: .player, tick: 0
        )
        var delivered: ScriptEvent?
        game.eventBus.delivery = { event, targets in
            if !targets.isEmpty { delivered = event }
        }
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let outcome = AIObjectGraphMutationTools.run("remove_attribute", args: args(["ref": "player", "key": "note"]), context: ctx)
        XCTAssertFalse(outcome.refused)
        XCTAssertNil(game.attributeStore.get(.player, "note"))
        game.eventBus.runDeliveryPhase(tick: 0)
        XCTAssertEqual(delivered?.source, .ai(model: "test-model"))
        let undoLines = game.scripting.aiJournal.undo(groups: 1, context: undoContext(game))
        XCTAssertTrue(undoLines.contains { $0.contains("restored") })
        XCTAssertEqual(game.attributeStore.get(.player, "note"), .string("hi"))
    }

    func testAttachScriptRejectsInvalidEventLiteralAtStage5() throws {
        let game = makeGameWithWorld("ai-attach-stage5")
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        // "Attribute.Changed" is grammar-invalid (uppercase letters) — a
        // realistic LLM capitalization mistake, and distinct from a mere
        // semantic typo like "attribute.change" (still grammar-valid, since
        // custom event names share the exact same grammar as catalog ones —
        // §7.2's own "bare names, namespaced by convention" — so stage 5
        // cannot and does not claim to catch that case; only a genuinely
        // malformed literal).
        let source = "on(\"Attribute.Changed\", function(ev) end)"
        let outcome = AIObjectGraphMutationTools.run(
            "attach_script", args: args(["ref": "player", "name": "bad", "source": source]), context: ctx
        )
        XCTAssertTrue(outcome.refused)
        XCTAssertEqual(outcome.stage, "validate")
        XCTAssertNil(game.scripting.aiJournal.list().first)
    }

    func testAttachScriptDryRunWarnsButStillAttaches() throws {
        let game = makeGameWithWorld("ai-attach-dryrun-warn")
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let source = "local missing = objects.get(\"entity:99999999\")\nmissing:get(\"health\")"
        let outcome = AIObjectGraphMutationTools.run(
            "attach_script", args: args(["ref": "player", "name": "flaky", "source": source]), context: ctx
        )
        XCTAssertFalse(outcome.refused)
        XCTAssertFalse(outcome.warnings.isEmpty, "a dry-run runtime failure must surface as a warning, not a refusal")
        XCTAssertNotNil(ScriptStore(graph: game.aiQueryContext().graph).get(.player, "flaky"))
    }

    func testAttachScriptThenUndoDetachesBrandNewScript() throws {
        let game = makeGameWithWorld("ai-attach-undo-new")
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let outcome = AIObjectGraphMutationTools.run(
            "attach_script", args: args(["ref": "player", "name": "greet", "source": "self.attrs.greeted = true"]), context: ctx
        )
        XCTAssertFalse(outcome.refused)
        XCTAssertNotNil(ScriptStore(graph: game.aiQueryContext().graph).get(.player, "greet"))

        let undoLines = game.scripting.aiJournal.undo(groups: 1, context: undoContext(game))
        XCTAssertTrue(undoLines.contains { $0.contains("detached") })
        XCTAssertNil(ScriptStore(graph: game.aiQueryContext().graph).get(.player, "greet"))
    }

    func testAttachScriptReplaceThenUndoRestoresPreviousUnlessEditedSince() throws {
        let game = makeGameWithWorld("ai-attach-undo-replace")
        let store = ScriptStore(graph: game.aiQueryContext().graph)
        guard case .success = store.attach(
            .player, name: "mood", source: "self.attrs.mood = 'calm'", mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("seed attach failed") }

        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let outcome = AIObjectGraphMutationTools.run(
            "attach_script", args: args(["ref": "player", "name": "mood", "source": "self.attrs.mood = 'excited'"]), context: ctx
        )
        XCTAssertFalse(outcome.refused)

        // A CAS mismatch (the player edited it since) must refuse, not clobber.
        _ = store.attach(.player, name: "mood", source: "self.attrs.mood = 'player edit'", mode: .module, triggers: [], by: .player, tick: 1)
        let refusedUndo = game.scripting.aiJournal.undo(groups: 1, context: undoContext(game))
        XCTAssertTrue(refusedUndo.contains { $0.contains("edited since") })
        XCTAssertEqual(store.get(.player, "mood")?.source, "self.attrs.mood = 'player edit'")
    }

    func testDetachScriptThenUndoReattaches() throws {
        let game = makeGameWithWorld("ai-detach-undo")
        let store = ScriptStore(graph: game.aiQueryContext().graph)
        guard case .success = store.attach(
            .player, name: "keepme", source: "self.attrs.k = 1", mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("seed attach failed") }

        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let outcome = AIObjectGraphMutationTools.run("detach_script", args: args(["ref": "player", "name": "keepme"]), context: ctx)
        XCTAssertFalse(outcome.refused)
        XCTAssertNil(store.get(.player, "keepme"))

        let undoLines = game.scripting.aiJournal.undo(groups: 1, context: undoContext(game))
        XCTAssertTrue(undoLines.contains { $0.contains("restored") })
        XCTAssertNotNil(store.get(.player, "keepme"))
    }

    func testEnableScriptThenUndoReverts() throws {
        let game = makeGameWithWorld("ai-enable-undo")
        let store = ScriptStore(graph: game.aiQueryContext().graph)
        guard case .success = store.attach(
            .player, name: "toggle", source: "self.attrs.t = 1", mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("seed attach failed") }

        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let outcome = AIObjectGraphMutationTools.run(
            "enable_script", args: args(["ref": "player", "name": "toggle", "enabled": false]), context: ctx
        )
        XCTAssertFalse(outcome.refused)
        XCTAssertEqual(store.get(.player, "toggle")?.enabled, false)

        let undoLines = game.scripting.aiJournal.undo(groups: 1, context: undoContext(game))
        XCTAssertTrue(undoLines.contains { $0.contains("re-enabled") })
        XCTAssertEqual(store.get(.player, "toggle")?.enabled, true)
    }

    func testSubscribeThenUndoUnsubscribes() throws {
        let game = makeGameWithWorld("ai-subscribe-undo")
        let store = ScriptStore(graph: game.aiQueryContext().graph)
        guard case .success = store.attach(
            .player, name: "brain", source: "register('onhurt', function(ev) end)", mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("seed attach failed") }

        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let outcome = AIObjectGraphMutationTools.run(
            "subscribe", args: args([
                "subscriber": "player", "target": "player", "event": "attribute.changed", "attr": "health", "handler": "brain.onhurt",
            ]), context: ctx
        )
        XCTAssertFalse(outcome.refused)
        XCTAssertEqual(game.eventBus.listSubscriptions(for: .player).count, 1)

        let undoLines = game.scripting.aiJournal.undo(groups: 1, context: undoContext(game))
        XCTAssertTrue(undoLines.contains { $0.contains("removed") })
        XCTAssertEqual(game.eventBus.listSubscriptions(for: .player).count, 0)
    }

    func testEmitEventSucceedsAndJournalsAsNonUndoable() throws {
        let game = makeGameWithWorld("ai-emit")
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let outcome = AIObjectGraphMutationTools.run(
            "emit_event", args: args(["ref": "player", "name": "lumber.milestone"]), context: ctx
        )
        XCTAssertFalse(outcome.refused)
        let undoLines = game.scripting.aiJournal.undo(groups: 1, context: undoContext(game))
        XCTAssertTrue(undoLines.contains { $0.contains("nothing to revert") })
    }

    func testAIEventDeclarationIsDiscoverableAndValidatesEmits() throws {
        let game = makeGameWithWorld("ai-custom-event")
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)

        let declare = AIObjectGraphMutationTools.run(
            "emit_event",
            args: args([
                "ref": "player", "name": "machine.ready", "action": "declare",
                "fields": "{\"count\":\"integer\",\"note\":\"string?\"}",
                "summary": "A machine became ready",
            ]),
            context: ctx
        )
        XCTAssertFalse(declare.refused, declare.message ?? "")

        let described = AIObjectGraphQueryTools.run(
            "describe_events", args: args(["ref": "player", "kind": "machine."]),
            context: game.aiQueryContext()
        )
        XCTAssertFalse(described.refused, described.message ?? "")
        XCTAssertTrue(described.data?.contains("\"name\":\"machine.ready\"") == true)
        XCTAssertTrue(described.data?.contains("\"source\":\"custom\"") == true)
        XCTAssertTrue(described.data?.contains("\"type\":\"integer\"") == true)

        let invalid = AIObjectGraphMutationTools.run(
            "emit_event",
            args: args(["ref": "player", "name": "machine.ready", "payload": "{\"count\":\"three\"}"]),
            context: ctx
        )
        XCTAssertTrue(invalid.refused)
        XCTAssertEqual(invalid.stage, "validate")

        let valid = AIObjectGraphMutationTools.run(
            "emit_event",
            args: args(["ref": "player", "name": "machine.ready", "payload": "{\"count\":3}"]),
            context: ctx
        )
        XCTAssertFalse(valid.refused, valid.message ?? "")
        XCTAssertEqual(game.eventBus.recentEvents().last?.payload["count"], .int(3))
    }

    func testRunScriptEphemeralExecutesOnceAndIsNotPersisted() throws {
        let game = makeGameWithWorld("ai-run-script")
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let outcome = AIObjectGraphMutationTools.run("run_script", args: args(["source": "self.attrs.ran = true"]), context: ctx)
        XCTAssertFalse(outcome.refused)
        XCTAssertEqual(game.attributeStore.get(.player, "ran"), .bool(true))
        XCTAssertNil(ScriptStore(graph: game.aiQueryContext().graph).get(.player, "run"), "run_script must never persist a script record")
    }

    func testMutationToolsRefuseOnLANClient() throws {
        let host = FakeObjectGraphHost()
        host.isLANClient = true
        let graph = ObjectGraph(host: host)
        let target = ObjectTargetContext(currentDimension: .overworld, cursor: { nil })
        let ctx = AIMutationContext(
            graph: graph, store: AttributeStore(graph: graph), scriptStore: ScriptStore(graph: graph), eventBus: EventBus(),
            scriptRuntime: nil, target: target, tick: 0, model: "m", isLANClient: true, journal: AIJournal(), requestID: 1
        )
        let outcome = AIObjectGraphMutationTools.run("set_attribute", args: args(["ref": "player", "key": "x", "value": "1"]), context: ctx)
        XCTAssertTrue(outcome.refused)
    }

    // MARK: - AIToolLoop (fake transport)

    private func makeLoopContexts(_ game: GameCore) -> (AIQueryContext, AIMutationContext) {
        let requestID = game.scripting.aiJournal.beginRequest()
        return (game.aiQueryContext(), game.aiMutationContext(model: "test-model", requestID: requestID))
    }

    func testLoopDispatchesNativeToolCallThenReturnsFinalAnswer() throws {
        let game = makeGameWithWorld("ai-loop-basic")
        let (q, m) = makeLoopContexts(game)
        var turnIndex = 0
        let transport: AIChatTransport = { messages, _, completion in
            turnIndex += 1
            if turnIndex == 1 {
                completion(AIChatTurn(content: nil, toolCalls: [AIToolCallRequest(name: "set_attribute", argumentsJSON: "{\"ref\":\"player\",\"key\":\"mood\",\"value\":\"curious\"}")]))
            } else {
                XCTAssertTrue(messages.contains { $0.role == .tool })
                completion(AIChatTurn(content: "Done — set your mood to curious.", toolCalls: []))
            }
        }
        let loop = AIToolLoop(queryContext: q, mutationContext: m, transport: transport)
        let expectation = expectation(description: "loop completes")
        loop.run(systemPrompt: "sys", userPrompt: "make me curious") { result in
            XCTAssertTrue(result.completedNormally)
            XCTAssertEqual(result.mutationsApplied, 1)
            XCTAssertTrue(result.finalMessage.contains("curious"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertEqual(game.attributeStore.get(.player, "mood"), .string("curious"))
    }

    func testLoopRepairsFencedJSONToolCall() throws {
        let game = makeGameWithWorld("ai-loop-repair")
        let (q, m) = makeLoopContexts(game)
        var turnIndex = 0
        let transport: AIChatTransport = { _, _, completion in
            turnIndex += 1
            if turnIndex == 1 {
                let fenced = "I'll do that:\n```json\n{\"name\":\"list_objects\",\"arguments\":{\"radius\":4}}\n```"
                completion(AIChatTurn(content: fenced, toolCalls: []))
            } else {
                completion(AIChatTurn(content: "ok", toolCalls: []))
            }
        }
        let loop = AIToolLoop(queryContext: q, mutationContext: m, transport: transport)
        let expectation = expectation(description: "loop completes")
        loop.run(systemPrompt: "sys", userPrompt: "what's near me?") { result in
            XCTAssertTrue(result.transcript.contains { $0.role == .tool })
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testLoopMalformedArgsRetriesThenGivesUpEnvelope() throws {
        let game = makeGameWithWorld("ai-loop-malformed")
        let (q, m) = makeLoopContexts(game)
        let transport: AIChatTransport = { _, _, completion in
            completion(AIChatTurn(content: nil, toolCalls: [AIToolCallRequest(name: "set_attribute", argumentsJSON: "not json")]))
        }
        let loop = AIToolLoop(queryContext: q, mutationContext: m, transport: transport)
        let expectation = expectation(description: "loop completes")
        loop.run(systemPrompt: "sys", userPrompt: "do it") { result in
            XCTAssertFalse(result.completedNormally, "the loop must give up at the turn limit, never crash or hang")
            let toolMessages = result.transcript.filter { $0.role == .tool }
            XCTAssertTrue(toolMessages.contains { $0.content.contains("\"refused\":true") })
            XCTAssertTrue(toolMessages.contains { $0.content.contains("too many failed attempts") })
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testLoopEnforcesFourMutationsPerRequestCap() throws {
        let game = makeGameWithWorld("ai-loop-cap")
        let (q, m) = makeLoopContexts(game)
        var turnIndex = 0
        let transport: AIChatTransport = { _, _, completion in
            turnIndex += 1
            if turnIndex <= 5 {
                let json = "{\"ref\":\"player\",\"key\":\"k\(turnIndex)\",\"value\":\"\(turnIndex)\"}"
                completion(AIChatTurn(content: nil, toolCalls: [AIToolCallRequest(name: "set_attribute", argumentsJSON: json)]))
            } else {
                completion(AIChatTurn(content: "finished", toolCalls: []))
            }
        }
        let loop = AIToolLoop(queryContext: q, mutationContext: m, transport: transport)
        let expectation = expectation(description: "loop completes")
        loop.run(systemPrompt: "sys", userPrompt: "set five attributes") { result in
            XCTAssertEqual(result.mutationsApplied, 4, "the fifth mutation call must be refused by the request-level cap")
            let toolMessages = result.transcript.filter { $0.role == .tool }
            XCTAssertTrue(toolMessages.contains { $0.content.contains("mutation limit reached") })
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
        XCTAssertNil(game.attributeStore.get(.player, "k5"))
    }

    func testLoopGivesUpAtTurnLimitWithoutHanging() throws {
        let game = makeGameWithWorld("ai-loop-turnlimit")
        let (q, m) = makeLoopContexts(game)
        let transport: AIChatTransport = { _, _, completion in
            completion(AIChatTurn(content: nil, toolCalls: [AIToolCallRequest(name: "list_objects", argumentsJSON: "{}")]))
        }
        let loop = AIToolLoop(queryContext: q, mutationContext: m, transport: transport)
        let expectation = expectation(description: "loop completes")
        loop.run(systemPrompt: "sys", userPrompt: "keep looking forever") { result in
            XCTAssertFalse(result.completedNormally)
            XCTAssertEqual(result.finalMessage, "reached the turn limit without a final answer")
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testLoopReportsTransportFailureAsUnavailable() throws {
        let game = makeGameWithWorld("ai-loop-fallback")
        let (q, m) = makeLoopContexts(game)
        let transport: AIChatTransport = { _, _, completion in completion(nil) }
        let loop = AIToolLoop(queryContext: q, mutationContext: m, transport: transport)
        let expectation = expectation(description: "loop completes")
        loop.run(systemPrompt: "sys", userPrompt: "hello") { result in
            XCTAssertFalse(result.completedNormally)
            XCTAssertTrue(result.finalMessage.contains("unavailable"))
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)
    }

    func testIsScriptingRequestHeuristic() {
        XCTAssertTrue(AIToolLoop.isScriptingRequest("attach a script to the chest"))
        XCTAssertTrue(AIToolLoop.isScriptingRequest("subscribe to attribute changes"))
        XCTAssertFalse(AIToolLoop.isScriptingRequest("give me 5 diamonds"))
    }

    // MARK: - tool-call repair

    func testRepairParsesDirectJSON() {
        let call = AIToolCallRepair.repair("{\"name\":\"emit_event\",\"arguments\":{\"ref\":\"player\",\"name\":\"lumber.milestone\"}}")
        XCTAssertEqual(call?.name, "emit_event")
    }

    func testRepairFindsBracesInsideSentence() {
        let call = AIToolCallRepair.repair("Sure, calling it now: {\"name\":\"recent_events\",\"arguments\":{\"limit\":5}} — one moment")
        XCTAssertEqual(call?.name, "recent_events")
    }

    func testRepairReturnsNilForPlainText() {
        XCTAssertNil(AIToolCallRepair.repair("I don't need a tool for that."))
    }

    // MARK: - ScriptRuntime async broker seam (design.md §9.6)

    func testAiAwaitResumesAcrossTicksViaAsyncBroker() throws {
        let game = makeGameWithWorld("ai-await-broker")
        guard let runtime = game.scripting.scriptRuntime else { return XCTFail("no script runtime") }
        let store = ScriptStore(graph: game.aiQueryContext().graph)
        guard case .success = store.attach(
            .player, name: "asker", source: "local text, err = ai.await('hi')\nself.attrs.reply = text or ('err:' .. tostring(err))",
            mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("seed attach failed") }
        game.scripting.anyScriptsAttached = true

        var handoffCalls: [(UInt64, String)] = []
        runtime.outboxHandoff = { id, prompt in handoffCalls.append((id, prompt)) }

        game.runEventBusPhase() // load — the script yields on ai.await, request handed to the broker
        XCTAssertEqual(handoffCalls.count, 1)
        XCTAssertNil(game.attributeStore.get(.player, "reply"), "must not resume before the reply is delivered")

        game.runEventBusPhase() // a phase with no reply yet: still suspended
        XCTAssertNil(game.attributeStore.get(.player, "reply"))

        runtime.submitAIReply(id: handoffCalls[0].0, text: "hello back", error: nil)
        game.runEventBusPhase() // the phase that drains the now-queued reply
        XCTAssertEqual(game.attributeStore.get(.player, "reply"), .string("hello back"))
    }

    func testAiAskPublishesThePositiveAIRepliedEventEnvelope() throws {
        let game = makeGameWithWorld("ai-ask-event")
        let runtime = try XCTUnwrap(game.scripting.scriptRuntime)
        let store = ScriptStore(graph: game.aiQueryContext().graph)
        _ = try store.attach(
            .world, name: "asker", source: "world.attrs.request_id = ai.ask('hello')",
            mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        var request: (UInt64, String)?
        runtime.outboxHandoff = { request = ($0, $1) }

        game.runEventBusPhase()
        let sent = try XCTUnwrap(request)
        XCTAssertEqual(sent.1, "hello")
        runtime.submitAIReply(id: sent.0, text: "world", error: nil)
        game.runEventBusPhase()

        let event = try XCTUnwrap(game.eventBus.recentEvents().last { $0.kind == .aiReplied })
        XCTAssertEqual(event.subject, .world)
        XCTAssertEqual(event.payload["requestId"], .int(Int64(sent.0)))
        XCTAssertEqual(event.payload["text"], .string("world"))
        XCTAssertEqual(event.payload["error"], .null)
        XCTAssertEqual(event.source, .engine)
    }

    func testAiInFlightBudgetRefusesThirdConcurrentRequest() throws {
        let game = makeGameWithWorld("ai-inflight-budget")
        guard let runtime = game.scripting.scriptRuntime else { return XCTFail("no script runtime") }
        let store = ScriptStore(graph: game.aiQueryContext().graph)
        let source = """
        local a = ai.ask('one')
        local b = ai.ask('two')
        local c = ai.ask('three')
        self.attrs.third = c
        """
        guard case .success = store.attach(.player, name: "flooder", source: source, mode: .module, triggers: [], by: .player, tick: 0)
        else { return XCTFail("seed attach failed") }
        game.scripting.anyScriptsAttached = true

        var handoffCount = 0
        runtime.outboxHandoff = { _, _ in handoffCount += 1 }
        game.runEventBusPhase()
        XCTAssertEqual(handoffCount, ScriptRuntime.aiMaxInFlightPerWorld, "the pump must never see more than the in-flight cap")
        XCTAssertEqual(game.attributeStore.get(.player, "third"), .int(0), "the third ai.ask over budget returns id 0, never enqueued")
    }

    func testSortedAIRepliesCannotResumeAWaiterDetachedByAnEarlierReply() throws {
        let game = makeGameWithWorld("ai-await-stale-batch")
        let runtime = try XCTUnwrap(game.scripting.scriptRuntime)
        let scripts = ScriptStore(graph: game.aiQueryContext().graph)
        _ = try scripts.attach(
            .world, name: "a_controller", source: """
            local text = ai.await('first')
            self:detach('b_waiter')
            self.attrs.first_reply = text
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        _ = try scripts.attach(
            .world, name: "b_waiter", source: """
            local text = ai.await('second')
            self.attrs.stale_reply_ran = text
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        var requests: [(UInt64, String)] = []
        runtime.outboxHandoff = { requests.append(($0, $1)) }
        game.runEventBusPhase()
        XCTAssertEqual(requests.map(\.1), ["first", "second"])

        runtime.submitAIReply(id: requests[0].0, text: "one", error: nil)
        runtime.submitAIReply(id: requests[1].0, text: "two", error: nil)
        game.runEventBusPhase()

        XCTAssertNil(scripts.get(.world, "b_waiter"))
        XCTAssertEqual(game.attributeStore.get(.world, "first_reply"), .string("one"))
        XCTAssertNil(game.attributeStore.get(.world, "stale_reply_ran"))
        XCTAssertEqual(runtime.aiInFlightCount, 0)
        XCTAssertFalse(game.eventBus.recentEvents().contains { $0.kind == .aiReplied })
    }

    func testDetachedAwaitCancelsBudgetAndDropsLateBrokerReply() throws {
        let game = makeGameWithWorld("ai-await-cancel")
        let runtime = try XCTUnwrap(game.scripting.scriptRuntime)
        let scripts = ScriptStore(graph: game.aiQueryContext().graph)
        _ = try scripts.attach(
            .world, name: "waiter", source: """
            local text = ai.await('late')
            self.attrs.late_reply_ran = text
            """, mode: .module, triggers: [], by: .player, tick: 0
        ).get()
        game.scripting.anyScriptsAttached = true
        var requestID: UInt64?
        var canceledRequestIDs: [UInt64] = []
        runtime.outboxHandoff = { requestID = $0; _ = $1 }
        runtime.aiCancellationHandoff = { canceledRequestIDs.append($0) }
        game.runEventBusPhase()
        XCTAssertEqual(runtime.aiInFlightCount, 1)

        XCTAssertTrue(try scripts.detach(.world, "waiter").get())
        game.runEventBusPhase()
        XCTAssertEqual(runtime.aiInFlightCount, 0)
        XCTAssertEqual(canceledRequestIDs, [try XCTUnwrap(requestID)])
        let recentReplies = game.eventBus.recentEvents().filter { $0.kind == .aiReplied }.count

        runtime.submitAIReply(id: try XCTUnwrap(requestID), text: "too late", error: nil)
        game.runEventBusPhase()
        XCTAssertNil(game.attributeStore.get(.world, "late_reply_ran"))
        XCTAssertEqual(
            game.eventBus.recentEvents().filter { $0.kind == .aiReplied }.count,
            recentReplies
        )
    }

    func testAIEmitCannotForgeBuiltInEngineEvents() {
        let game = makeGameWithWorld("ai-built-in-emit-validation")
        let ctx = game.aiMutationContext(
            model: "test-model", requestID: game.scripting.aiJournal.beginRequest()
        )
        let wrongSubject = AIObjectGraphMutationTools.run(
            "emit_event", args: args([
                "ref": "player", "name": "block.toolStrike", "payload": "{}",
            ]), context: ctx
        )
        XCTAssertTrue(wrongSubject.refused)
        XCTAssertTrue(wrongSubject.message?.contains("engine-produced") == true)

        let missingPayload = AIObjectGraphMutationTools.run(
            "emit_event", args: args([
                "ref": "player", "name": "player.pickedUp", "payload": "{}",
            ]), context: ctx
        )
        XCTAssertTrue(missingPayload.refused)
        XCTAssertTrue(missingPayload.message?.contains("engine-produced") == true)
    }

    func testBrokerFallbackUsesSynchronousStubWhenNoHandoffAttached() throws {
        // Non-regression: 1c's own synchronous `aiResponder` stub seam must
        // keep working exactly as shipped when no production broker is
        // attached (`outboxHandoff == nil`) — every 1c test relies on this.
        let host = FakeObjectGraphHost()
        let world = World(dim: .overworld, seed: 3)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        host.worldsByDim[.overworld] = world
        let player = Player(world: world)
        player.setPos(0, 64, 0)
        world.addEntity(player)
        host.localPlayer = player
        let state = GameScriptingState()
        let runtime = try ScriptRuntime(host: host, state: state, say: { _ in }, aiResponder: { _ in "stub reply" })
        state.scriptRuntime = runtime
        state.eventBus.delivery = { event, targets in runtime.deliver(event, targets) }
        let store = ScriptStore(graph: ObjectGraph(host: host))
        guard case .success = store.attach(
            .player, name: "asker", source: "local text = ai.await('hi')\nself.attrs.reply = text",
            mode: .module, triggers: [], by: .player, tick: 0
        ) else { return XCTFail("seed attach failed") }
        state.anyScriptsAttached = true

        runtime.runLoads()
        XCTAssertNil(runtime.outboxHandoff)
        runtime.runAIInbox()
        runtime.runResumptions()
        XCTAssertEqual(AttributeStore(graph: ObjectGraph(host: host)).get(.player, "reply"), .string("stub reply"))
    }

    // MARK: - /script journal, /script undo-ai commands

    func testScriptJournalAndUndoAiCommands() throws {
        let game = makeGameWithWorld("ai-script-journal-cmd")
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        _ = AIObjectGraphMutationTools.run("set_attribute", args: args(["ref": "player", "key": "note", "value": "\"hi\""]), context: ctx)

        let journalResult = ScriptingCommands.run(command: "script", arguments: ["journal"], context: game.scriptingCommandContext())
        XCTAssertTrue(journalResult.ok)
        XCTAssertTrue(journalResult.lines.contains { $0.contains("set_attribute") })

        let undoResult = ScriptingCommands.run(command: "script", arguments: ["undo-ai"], context: game.scriptingCommandContext())
        XCTAssertTrue(undoResult.ok)
        XCTAssertNil(game.attributeStore.get(.player, "note"))
    }

    // MARK: - helpers

    private func undoContext(_ game: GameCore) -> AIUndoContext {
        let q = game.aiQueryContext()
        return AIUndoContext(graph: q.graph, store: q.store, scriptStore: q.scriptStore, eventBus: game.eventBus, tick: 0)
    }
}
