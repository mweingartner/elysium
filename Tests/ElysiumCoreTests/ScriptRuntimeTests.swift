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
import XCTest
@testable import ElysiumCore

@MainActor
final class ScriptRuntimeTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
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
        let record = ScriptRecord(
            name: "pulse", source: "self:setBlock(\"glowstone\")", enabled: true, mode: .handler,
            triggers: [trigger], author: .player, createdTick: 42, apiVersion: 1,
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
        XCTAssertEqual(decodedRecord.triggers, [trigger])
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
    }
}
