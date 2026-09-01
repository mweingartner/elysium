// ScriptEditorScreenTests.swift — native SwiftUI script editor (Stage A). design.md §16 row 3:
// "full in-game script editor (multi-line, syntax colouring, error line, save/run)", now served by
// a native window instead of the retired game-canvas `ScriptEditorScreen`. Model-level coverage:
// `LuaSyntaxColoring`'s tokenizer spans (pure, no UI dependency — unchanged from before), the
// Inspector data provider (`inspectorRows` — unchanged from before), and the editor's real
// controller, `ScriptEditorModel`, driven headlessly: no `Screen`, no `UIManager`, no `MTLDevice`,
// no `NSWindow` — the whole point of splitting a thin SwiftUI view over a testable model. The Core
// assertions the old screen-driven suite proved carry over unchanged in substance: multiline
// type+Save round-trips byte-exact via `scriptStore.get(...).source`; invalid syntax never
// attaches and reports the right error line; Run/ephemeral never persists its draft as a script;
// permitted live-world mutations remain durable by design; a LAN guest's Save
// sends a `scriptIntent` and never attaches locally.

import XCTest
@testable import Elysium
@testable import ElysiumCore

final class LuaSyntaxColoringTests: XCTestCase {
    private func kinds(_ line: String) -> [(LuaSyntaxSpanKind, String)] {
        let (spans, _) = LuaSyntaxColoring.colorLine(line, state: .normal)
        let chars = Array(line)
        return spans.map { ($0.kind, String(chars[$0.range])) }
    }

    func testKeywordsAreDistinguishedFromPlainIdentifiers() {
        let result = kinds("local function greet end")
        XCTAssertTrue(result.contains { $0.0 == .keyword && $0.1 == "local" })
        XCTAssertTrue(result.contains { $0.0 == .keyword && $0.1 == "function" })
        XCTAssertTrue(result.contains { $0.0 == .keyword && $0.1 == "end" })
        XCTAssertTrue(result.contains { $0.0 == .plain && $0.1 == "greet" })
    }

    func testStringsAndNumbersAndLineComments() {
        let result = kinds("local x = \"hi\" + 42 -- trailing comment")
        XCTAssertTrue(result.contains { $0.0 == .string && $0.1 == "\"hi\"" })
        XCTAssertTrue(result.contains { $0.0 == .number && $0.1 == "42" })
        XCTAssertTrue(result.contains { $0.0 == .comment && $0.1 == "-- trailing comment" })
    }

    func testEscapedQuoteDoesNotEndTheString() {
        let result = kinds("local s = \"a\\\"b\"")
        XCTAssertTrue(result.contains { $0.0 == .string && $0.1 == "\"a\\\"b\"" })
    }

    func testLongCommentSpansMultipleLines() {
        let (firstSpans, state1) = LuaSyntaxColoring.colorLine("--[[ start", state: .normal)
        XCTAssertEqual(firstSpans.first?.kind, .comment)
        XCTAssertEqual(state1, .inLongComment(level: 0))
        let (secondSpans, state2) = LuaSyntaxColoring.colorLine("still a comment", state: state1)
        XCTAssertEqual(secondSpans, [LuaSyntaxSpan(kind: .comment, range: 0..<15)])
        let (thirdSpans, state3) = LuaSyntaxColoring.colorLine("end here ]]", state: state2)
        XCTAssertTrue(thirdSpans.contains { $0.kind == .comment })
        XCTAssertEqual(state3, .normal, "the long comment must close and hand normal state to the next line")
    }

    func testLongStringWithEqualsLevelMatchesOnlySameLevel() {
        let (spans, state) = LuaSyntaxColoring.colorLine("local s = [=[ text ]] still-inside ]=]", state: .normal)
        XCTAssertEqual(state, .normal)
        // The inner "]]" (level 0) must not close a level-1 long bracket.
        XCTAssertTrue(spans.contains { $0.kind == .string })
    }

    func testColorLinesThreadsStateAcrossTheWholeSource() {
        let lines = ["--[[", "block comment", "still going", "]]", "local x = 1"]
        let allSpans = LuaSyntaxColoring.colorLines(lines)
        XCTAssertEqual(allSpans.count, 5)
        XCTAssertTrue(allSpans[1].allSatisfy { $0.kind == .comment })
        XCTAssertTrue(allSpans[2].allSatisfy { $0.kind == .comment })
        XCTAssertTrue(allSpans[4].contains { $0.kind == .keyword && $0.range == 0..<5 })
    }
}

@MainActor
final class ScriptEditorModelTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        if entityTypes().isEmpty { registerAllEntities() }
    }

    private func makeTrustedGame() throws -> GameCore {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-script-editor-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(name: "Script Editor Test", seedText: "9001", mode: GameMode.creative, difficulty: 2)
        XCTAssertTrue(game.hasWorld())
        return game
    }

    private func makeLANClientGame() throws -> GameCore {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-script-editor-guest-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "guest-editor-host", worldName: "Guest Editor Host", seed: 4242,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2
        ))
        XCTAssertTrue(game.isLANClientWorld)
        LANMultiplayerManager.shared.attachGame(game)
        return game
    }

    // MARK: - host: type + Save round-trips byte-exact

    func testTypingMultilineModuleSourceAndSavingAttachesItByteExact() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertTrue(model.isNewScript)

        model.currentName = "greet"
        let source = "local n = 0\nfunction onLoad()\n  n = n + 1\nend"
        model.source = source

        let confirmed = model.save()

        let saved = try XCTUnwrap(game.scriptingCommandContext().scriptStore.get(.player, "greet"))
        XCTAssertEqual(saved.source, source, "the source must round-trip byte-exact through Save")
        XCTAssertEqual(saved.mode, .module)
        XCTAssertNil(model.errorLine)
        XCTAssertFalse(model.statusIsError)
        XCTAssertTrue(confirmed)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.isNewScript, "Save must clear the 'authoring something new' flag")
    }

    // MARK: - host: invalid syntax never attaches, reports the right error line

    func testInvalidSyntaxSetsTheErrorLineAndNeverAttaches() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.currentName = "broken"
        // Line 1 is a harmless comment so the fault must be reported on line 2, proving the
        // validator's line number — not just "some error happened" — reaches the model.
        model.source = "-- comment\nif true then"

        model.save()

        XCTAssertEqual(model.errorLine, 2, "the compile fault's own line number must surface, not line 1")
        XCTAssertNotNil(model.status)
        XCTAssertTrue(model.statusIsError)
        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "broken"),
                     "a script that fails validation must never be attached")
    }

    // MARK: - host: handler mode attaches a trigger for the chosen event

    func testHandlerModeAttachesATriggerForTheChosenEvent() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.currentName = "onload_handler"
        model.mode = .handler
        model.handlerEvent = "load"
        model.source = "say(\"loaded\")"

        model.save()

        let saved = try XCTUnwrap(game.scriptingCommandContext().scriptStore.get(.player, "onload_handler"))
        XCTAssertEqual(saved.mode, .handler)
        XCTAssertEqual(saved.triggers.first?.event, .load)
        XCTAssertFalse(model.statusIsError)
    }

    func testInvalidHandlerEventsAreRejectedConsistentlyBySaveAndCheck() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.currentName = "invalid_handler"
        model.mode = .handler
        model.source = "say(ev.kind)"

        model.handlerEvent = "unload"
        XCTAssertFalse(model.save())
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.status?.contains("not an EventBus handler") == true)
        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "invalid_handler"))

        model.handlerEvent = "block.used"
        model.check()
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.status?.contains("not raised for player") == true)
    }

    // MARK: - host: Run is ephemeral and never persists its draft as a script

    func testRunEphemeralNeverPersistsAScript() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.source = "say(\"hello from run\")"

        model.run()

        XCTAssertNil(model.errorLine)
        XCTAssertEqual(game.scriptingCommandContext().scriptStore.list(.player).count, 0,
                       "Run is ephemeral (§9.3) — it must never attach anything")
    }

    func testHandlerRunOnceIsRefusedBecauseNoRepresentativeEventWouldExist() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.mode = .handler
        model.handlerEvent = "entity.damaged"
        model.source = "self.attrs.accidentally_ran = ev.amount"

        model.run()

        XCTAssertTrue(model.statusIsError)
        XCTAssertEqual(model.status, ScriptEditorAuthoringContract.handlerRunOnceUnavailable)
        XCTAssertNil(game.scriptingCommandContext().store.get(.player, "accidentally_ran"))
    }

    func testRunExplainsNonYieldableBoundaryBeforeExecuting() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.source = "say(\"before\")\nwait(2)\nsay(\"after\")"

        model.run()

        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.status?.contains("Run is immediate") == true)
        XCTAssertTrue(model.status?.contains("Save the script") == true)
        XCTAssertEqual(model.errorLine, 2)
        XCTAssertEqual(model.selectedRange.location, ("say(\"before\")\n" as NSString).length)
    }

    func testRunDoesNotMistakeShadowedWaitOrAITableForEngineYieldCalls() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.source = """
        local wait = function() return 1 end
        local ai = { await = function() return 2 end }
        assert(wait() == 1)
        assert(ai.await() == 2)
        """

        model.run()

        XCTAssertFalse(model.statusIsError, model.status ?? "missing status")
        XCTAssertEqual(
            model.status,
            "ran 'player' script once (draft not saved or attached; live changes may persist)"
        )
    }

    func testCheckAcceptsAttachedYieldPointsWithoutSchedulingOrCallingAI() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.source = "while true do wait(2) end"
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let before = runtime.summary

        model.check()

        XCTAssertFalse(model.statusIsError, model.status ?? "missing status")
        XCTAssertTrue(model.status?.contains("valid wait() suspension") == true)
        XCTAssertTrue(model.status?.contains("code after that point was not executed") == true)
        XCTAssertEqual(runtime.summary, before, "dry-run yield points must leave no suspended work")

        model.source = "local reply, err = ai.await(\"explain\")\nif reply then say(reply) end"
        model.check()
        XCTAssertFalse(model.statusIsError, model.status ?? "missing status")
        XCTAssertTrue(model.status?.contains("valid ai.await() suspension") == true)
        XCTAssertEqual(runtime.summary, before, "dry-run ai.await must not enqueue or suspend real work")
    }

    func testHandlerCheckUsesSelectedEventKindAndRegistryPayloadWithoutPersisting() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.mode = .handler
        model.handlerEvent = "entity.damaged"
        model.source = """
        assert(ev.kind == "entity.damaged", "selected event kind was not supplied")
        assert(type(ev.amount) == "number" and ev.amount > 0, "documented amount payload is missing")
        assert(ev.attacker ~= nil and ev.attacker:exists(), "nullable attacker should have a safe typed representative")
        assert(ev.subject == self, "common subject should be the checked owner")
        assert(ev.source == "engine", "synthetic event provenance should be explicit")
        assert(type(ev.tick) == "number", "common tick should be present")
        """
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let before = runtime.summary

        model.check()

        XCTAssertFalse(model.statusIsError, model.status ?? "missing status")
        XCTAssertEqual(model.status, "Check passed — no issues found.")
        XCTAssertEqual(runtime.summary, before)
        XCTAssertTrue(game.scriptingCommandContext().scriptStore.list(.player).isEmpty,
                      "Check must not attach the handler it executes")
    }

    func testAvailabilityProjectionKeepsBannerCopyAndActionsExplicit() {
        let expected: [(ScriptEditorScriptingAvailability, ScriptEditorScriptingActivationAction?)] = [
            (.active, nil),
            (.trustRequired, .trustWorld),
            (.killSwitchOff, .turnOnKillSwitch),
            (.both, .trustWorldAndTurnOnKillSwitch),
            (.runtimeUnavailable(.lanGuest), nil),
            (.runtimeUnavailable(.worldSessionEnded), nil),
            (.runtimeUnavailable(.missingRuntime), nil),
        ]

        for (availability, action) in expected {
            XCTAssertFalse(availability.title.isEmpty)
            XCTAssertFalse(availability.detail.isEmpty)
            XCTAssertFalse(availability.systemImage.isEmpty)
            XCTAssertEqual(availability.activationAction, action)
        }
        XCTAssertFalse(ScriptEditorScriptingAvailability.active.attachedExecutionIsPaused)
        XCTAssertTrue(ScriptEditorScriptingAvailability.both.attachedExecutionIsPaused)
        XCTAssertTrue(ScriptEditorScriptingAvailability.trustRequired.detail.contains("Save, Check, and Run Once remain available"))
        XCTAssertFalse(ScriptEditorScriptingAvailability.killSwitchOff.title.contains("kill switch is off"))
        XCTAssertTrue(ScriptEditorScriptingAvailability.killSwitchOff.canCheck)
        XCTAssertFalse(ScriptEditorScriptingAvailability.killSwitchOff.canRunOnce)
        XCTAssertTrue(ScriptEditorScriptingAvailability.killSwitchOff.canSave)
        XCTAssertFalse(ScriptEditorScriptingAvailability.runtimeUnavailable(.missingRuntime).canCheck)
        XCTAssertFalse(ScriptEditorScriptingAvailability.runtimeUnavailable(.missingRuntime).canRunOnce)
        XCTAssertFalse(ScriptEditorScriptingAvailability.runtimeUnavailable(.missingRuntime).canSave)
        XCTAssertTrue(ScriptEditorScriptingActivationAction.trustWorld.confirmationDetail.contains("persisted"))
        XCTAssertTrue(
            ScriptEditorScriptingActivationAction.trustWorld.confirmationDetail
                .contains("cannot be reversed with Elysium's current controls")
        )
    }

    func testSaveAndCheckRemainAvailableWhileBothExecutionGatesAreOff() throws {
        let game = try makeTrustedGame()
        guard var record = game.worldRec else { return XCTFail("missing world record") }
        record.scriptsEnabled = false
        game.worldRec = record
        game.setGameRule("doScripts", 0)
        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertEqual(model.scriptingAvailability, .both)

        model.currentName = "paused_draft"
        model.source = "assert(self:exists())"
        XCTAssertTrue(model.save())
        XCTAssertNotNil(game.scriptingCommandContext().scriptStore.get(.player, "paused_draft"))
        XCTAssertFalse(model.statusIsError, model.status ?? "missing status")
        XCTAssertTrue(model.status?.contains("Attached execution is paused") == true)
        XCTAssertEqual(model.scriptingAvailability, .both, "Save must never change either execution gate")

        model.check()
        XCTAssertEqual(model.status, "Check passed — no issues found.")
        XCTAssertFalse(model.statusIsError)
        XCTAssertEqual(model.scriptingAvailability, .both, "Check must never change either execution gate")
    }

    func testKillSwitchOffDisablesRunOnceButLeavesCheckAndSaveAvailable() throws {
        let game = try makeTrustedGame()
        game.setGameRule("doScripts", 0)
        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertEqual(model.scriptingAvailability, .killSwitchOff)
        XCTAssertTrue(model.scriptingAvailability.canCheck)
        XCTAssertFalse(model.scriptingAvailability.canRunOnce)
        XCTAssertTrue(model.scriptingAvailability.canSave)

        model.source = "self.attrs.run_once_must_not_execute = true"
        model.run()
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.status?.contains("doScripts") == true)
        XCTAssertNil(
            AttributeStore(graph: ObjectGraph(host: game)).get(.player, "run_once_must_not_execute")
        )

        model.currentName = "paused_but_valid"
        XCTAssertTrue(model.save())
        XCTAssertNotNil(
            game.scriptingCommandContext().scriptStore.get(.player, "paused_but_valid")
        )
        model.check()
        XCTAssertEqual(model.status, "Check passed — no issues found.")
        XCTAssertFalse(model.statusIsError)
    }

    func testMissingRuntimeRejectsInvalidLuaWithoutSavingOrAttaching() throws {
        let game = try makeTrustedGame()
        game.scripting.scriptRuntime = nil
        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertEqual(model.scriptingAvailability, .runtimeUnavailable(.missingRuntime))

        model.currentName = "invalid_without_runtime"
        model.source = "-- invalid Lua must not pass through\nif true then"

        XCTAssertFalse(model.save())
        XCTAssertTrue(model.statusIsError)
        XCTAssertEqual(
            model.status,
            "No script runtime this session; Check and Save require validation."
        )
        XCTAssertNil(
            game.scriptingCommandContext().scriptStore.get(.player, "invalid_without_runtime")
        )
    }

    func testExplicitEditorRunWorksInAnUntrustedWorldWithoutTrustingIt() throws {
        let game = try makeTrustedGame()
        guard var record = game.worldRec else { return XCTFail("missing world record") }
        record.scriptsEnabled = false
        game.worldRec = record
        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertEqual(model.scriptingAvailability, .trustRequired)
        model.source = "self.attrs.editor_manual_run = true"

        model.run()

        let attributes = AttributeStore(graph: ObjectGraph(host: game))
        XCTAssertEqual(attributes.get(.player, "editor_manual_run"), .bool(true))
        XCTAssertFalse(model.statusIsError, model.status ?? "missing status")
        XCTAssertEqual(model.scriptingAvailability, .trustRequired)
        XCTAssertFalse(game.worldRec?.scriptsEnabled ?? true, "explicit Run must never trust the world")
    }

    func testRunOnceRefreshesEveryLiveEditorAfterSuccessAndFailure() throws {
        let game = try makeTrustedGame()
        let first = ScriptEditorModel(target: .player, game: game)
        let second = ScriptEditorModel(target: .world, game: game)
        first.source = "assert(self:exists())"
        XCTAssertEqual(second.scriptingAvailability, .active)

        guard var record = game.worldRec else { return XCTFail("missing world record") }
        record.scriptsEnabled = false
        game.worldRec = record
        first.run()

        XCTAssertFalse(first.statusIsError, first.status ?? "missing success status")
        XCTAssertEqual(first.scriptingAvailability, .trustRequired)
        XCTAssertEqual(second.scriptingAvailability, .trustRequired)

        game.setGameRule("doScripts", 0)
        first.run()

        XCTAssertTrue(first.statusIsError)
        XCTAssertTrue(first.status?.contains("doScripts") == true)
        XCTAssertEqual(first.scriptingAvailability, .both)
        XCTAssertEqual(second.scriptingAvailability, .both)
    }

    func testConfirmedActivationRefreshesEveryLiveEditorForTheWorld() throws {
        let game = try makeTrustedGame()
        guard var record = game.worldRec else { return XCTFail("missing world record") }
        record.scriptsEnabled = false
        game.worldRec = record
        game.setGameRule("doScripts", 0)
        let first = ScriptEditorModel(target: .player, game: game)
        let second = ScriptEditorModel(target: .world, game: game)
        XCTAssertEqual(first.scriptingAvailability.activationAction, .trustWorldAndTurnOnKillSwitch)
        XCTAssertEqual(second.scriptingAvailability, .both)

        first.enableAttachedScriptExecutionAfterConfirmation(
            confirming: .trustWorldAndTurnOnKillSwitch
        )

        XCTAssertTrue(game.worldRec?.scriptsEnabled ?? false)
        XCTAssertTrue(game.scriptingCommandContext().killSwitchOn)
        XCTAssertEqual(first.scriptingAvailability, .active)
        XCTAssertEqual(second.scriptingAvailability, .active)
        XCTAssertEqual(first.status, "Attached script execution is active.")
        XCTAssertFalse(first.statusIsError)
    }

    func testStaleActivationConfirmationCannotEnableANewlyChangedGate() throws {
        let game = try makeTrustedGame()
        guard var record = game.worldRec else { return XCTFail("missing world record") }
        record.scriptsEnabled = false
        game.worldRec = record
        let model = ScriptEditorModel(target: .player, game: game)
        let presentedAction = try XCTUnwrap(model.scriptingAvailability.activationAction)
        XCTAssertEqual(presentedAction, .trustWorld)

        game.setGameRule("doScripts", 0)
        model.enableAttachedScriptExecutionAfterConfirmation(confirming: presentedAction)

        XCTAssertFalse(game.worldRec?.scriptsEnabled ?? true, "stale confirmation must not trust the world")
        XCTAssertFalse(game.scriptingCommandContext().killSwitchOn, "stale confirmation must not turn scripts on")
        XCTAssertEqual(model.scriptingAvailability, .both)
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.status?.contains("changed while confirmation was open") == true)
    }

    func testAvailabilityRefreshObservesExternalGateChangesWithoutChangingThem() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertEqual(model.scriptingAvailability, .active)
        guard var record = game.worldRec else { return XCTFail("missing world record") }
        record.scriptsEnabled = false
        game.worldRec = record
        game.setGameRule("doScripts", 0)

        model.refreshScriptingAvailability()

        XCTAssertEqual(model.scriptingAvailability, .both)
        XCTAssertFalse(game.worldRec?.scriptsEnabled ?? true)
        XCTAssertFalse(game.scriptingCommandContext().killSwitchOn)
    }

    func testNewScriptCannotReplaceExistingNameWithoutExplicitConfirmation() throws {
        let game = try makeTrustedGame()
        let context = game.scriptingCommandContext()
        let model = ScriptEditorModel(target: .player, game: game)
        _ = try context.scriptStore.attach(
            .player, name: "existing", source: "say(\"old\")", mode: .module,
            triggers: [], by: .player, tick: context.tick
        ).get()
        model.currentName = "existing"
        model.source = "say(\"new\")"

        XCTAssertTrue(model.saveRequiresOverwriteConfirmation)
        let collision = try XCTUnwrap(model.saveCollision)
        XCTAssertFalse(model.save())
        XCTAssertEqual(context.scriptStore.get(.player, "existing")?.source, "say(\"old\")")
        XCTAssertTrue(model.status?.contains("Confirm replacement") == true)

        XCTAssertTrue(model.save(confirming: collision))
        XCTAssertEqual(context.scriptStore.get(.player, "existing")?.source, "say(\"new\")")
    }

    func testSameNameExternalEditRequiresExplicitReplacement() throws {
        let game = try makeTrustedGame()
        let context = game.scriptingCommandContext()
        _ = try context.scriptStore.attach(
            .player, name: "shared", source: "say(\"initial\")", mode: .module,
            triggers: [], by: .player, tick: context.tick
        ).get()
        let model = ScriptEditorModel(target: .player, game: game, existingName: "shared")
        _ = try context.scriptStore.attach(
            .player, name: "shared", source: "say(\"external\")", mode: .module,
            triggers: [], by: .player, tick: context.tick + 1
        ).get()
        model.source = "say(\"local\")"

        XCTAssertTrue(model.saveRequiresOverwriteConfirmation)
        let collision = try XCTUnwrap(model.saveCollision)
        XCTAssertFalse(model.save())
        XCTAssertEqual(context.scriptStore.get(.player, "shared")?.source, "say(\"external\")")

        XCTAssertTrue(model.save(confirming: collision))
        XCTAssertEqual(context.scriptStore.get(.player, "shared")?.source, "say(\"local\")")
    }

    func testSourceSavePreservesDisabledStateAndAllExistingTriggerMetadata() throws {
        let game = try makeTrustedGame()
        let context = game.scriptingCommandContext()
        let originalTriggers = [
            Trigger(event: .attributeChanged, attribute: "health", target: .object(.player)),
            Trigger(event: .playerAttacked, attribute: nil, target: .any),
        ]
        _ = try context.scriptStore.attach(
            .player, name: "guard", source: "say(\"initial\")", mode: .handler,
            triggers: originalTriggers, by: .player, tick: context.tick
        ).get()
        _ = try context.scriptStore.setEnabled(.player, "guard", false).get()
        let model = ScriptEditorModel(target: .player, game: game, existingName: "guard")
        model.source = "say(\"edited\")"

        XCTAssertTrue(model.save())
        let saved = try XCTUnwrap(context.scriptStore.get(.player, "guard"))
        XCTAssertFalse(saved.enabled, "source editing must never enable a disabled script")
        XCTAssertEqual(saved.triggers, originalTriggers, "filters, targets, and secondary triggers must round-trip")
    }

    func testExternallyDeletedLoadedScriptRequiresExplicitRecreateConfirmation() throws {
        let game = try makeTrustedGame()
        let context = game.scriptingCommandContext()
        _ = try context.scriptStore.attach(
            .player, name: "draft", source: "say(\"initial\")", mode: .module,
            triggers: [], enabled: false, by: .player, tick: context.tick
        ).get()
        let model = ScriptEditorModel(target: .player, game: game, existingName: "draft")
        _ = try context.scriptStore.detach(.player, "draft").get()
        model.source = "say(\"recreated\")"

        XCTAssertTrue(model.saveRequiresOverwriteConfirmation)
        let collision = try XCTUnwrap(model.saveCollision)
        XCTAssertFalse(model.save())
        XCTAssertNil(context.scriptStore.get(.player, "draft"))

        XCTAssertTrue(model.save(confirming: collision))
        let recreated = try XCTUnwrap(context.scriptStore.get(.player, "draft"))
        XCTAssertEqual(recreated.source, "say(\"recreated\")")
        XCTAssertFalse(recreated.enabled, "explicit recreation retains the loaded document's disabled state")
    }

    func testRenameCannotReplaceAnotherScriptWithoutExplicitConfirmation() throws {
        let game = try makeTrustedGame()
        let context = game.scriptingCommandContext()
        _ = try context.scriptStore.attach(
            .player, name: "alpha", source: "say(\"alpha\")", mode: .module,
            triggers: [], by: .player, tick: context.tick
        ).get()
        _ = try context.scriptStore.attach(
            .player, name: "beta", source: "say(\"beta\")", mode: .module,
            triggers: [], by: .player, tick: context.tick
        ).get()
        let model = ScriptEditorModel(target: .player, game: game, existingName: "alpha")
        model.currentName = "beta"
        model.source = "say(\"replacement\")"

        let collision = try XCTUnwrap(model.saveCollision)
        XCTAssertFalse(model.save())
        XCTAssertEqual(context.scriptStore.get(.player, "alpha")?.source, "say(\"alpha\")")
        XCTAssertEqual(context.scriptStore.get(.player, "beta")?.source, "say(\"beta\")")

        XCTAssertTrue(model.save(confirming: collision))
        XCTAssertEqual(context.scriptStore.get(.player, "alpha")?.source, "say(\"alpha\")")
        XCTAssertEqual(context.scriptStore.get(.player, "beta")?.source, "say(\"replacement\")")
    }

    func testCollisionConfirmationCannotOverwriteARecordThatChangesWhileModalIsOpen() throws {
        let game = try makeTrustedGame()
        let context = game.scriptingCommandContext()
        _ = try context.scriptStore.attach(
            .player, name: "shared", source: "say(\"initial\")", mode: .module,
            triggers: [], by: .player, tick: context.tick
        ).get()
        let model = ScriptEditorModel(target: .player, game: game, existingName: "shared")
        _ = try context.scriptStore.attach(
            .player, name: "shared", source: "say(\"collision-a\")", mode: .module,
            triggers: [], by: .player, tick: context.tick + 1
        ).get()
        model.source = "say(\"local\")"
        let collisionA = try XCTUnwrap(model.saveCollision)

        _ = try context.scriptStore.attach(
            .player, name: "shared", source: "say(\"collision-b\")", mode: .module,
            triggers: [], by: .player, tick: context.tick + 2
        ).get()

        XCTAssertFalse(model.save(confirming: collisionA))
        XCTAssertEqual(context.scriptStore.get(.player, "shared")?.source, "say(\"collision-b\")")
        XCTAssertTrue(model.status?.contains("changed again") == true)
        XCTAssertNotEqual(model.saveCollision, collisionA)
    }

    func testEndedWorldDraftCannotRunOrSaveIntoLaterWorldSession() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.currentName = "retained_draft"
        model.source = "say(\"old world\")"
        XCTAssertTrue(model.isDirty)

        game.exitToTitle()
        XCTAssertFalse(model.isWorldSessionActive)
        XCTAssertEqual(model.scriptingAvailability, .runtimeUnavailable(.worldSessionEnded))
        XCTAssertTrue(model.isDirty, "world exit must retain the unsaved source")

        game.createWorld(
            name: "Later World \(UUID().uuidString)", seedText: "91",
            mode: GameMode.creative, difficulty: 2
        )
        XCTAssertFalse(model.save())
        model.run()
        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "retained_draft"))
        XCTAssertTrue(model.status?.contains("world session") == true || model.status?.contains("World session") == true)
    }

    // MARK: - host: switching between scripts on the target reloads source/mode

    func testSwitchToLoadsAnExistingScriptsSourceAndMode() throws {
        let game = try makeTrustedGame()
        let context = game.scriptingCommandContext()
        guard case .success = context.scriptStore.attach(
            .player, name: "already_there", source: "return 1", mode: .module, triggers: [],
            by: .player, tick: 0
        ) else { return XCTFail("expected attach to succeed") }

        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertTrue(model.scripts.contains { $0.name == "already_there" })

        model.switchTo("already_there")
        XCTAssertEqual(model.source, "return 1")
        XCTAssertEqual(model.mode, .module)
        XCTAssertFalse(model.isNewScript)
    }

    func testSwitchingByteIdenticalDocumentsClearsAIStateAndScopesTheNextRequest() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: ScriptEditorAICompletionMode.defaultsKey)
        defaults.set(
            ScriptEditorAICompletionMode.manual.rawValue,
            forKey: ScriptEditorAICompletionMode.defaultsKey
        )
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: ScriptEditorAICompletionMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: ScriptEditorAICompletionMode.defaultsKey)
            }
        }

        let game = try makeTrustedGame()
        let context = game.scriptingCommandContext()
        let identicalSource = "local answer = 42"
        for name in ["first", "second"] {
            guard case .success = context.scriptStore.attach(
                .player, name: name, source: identicalSource, mode: .module, triggers: [],
                by: .player, tick: 0
            ) else {
                return XCTFail("expected \(name) to attach")
            }
        }
        let completer = RecordingScriptEditorAICompleter()
        let model = ScriptEditorModel(
            target: .player, game: game, existingName: "first", aiCompleter: completer
        )
        model.selectedRange = NSRange(location: (identicalSource as NSString).length, length: 0)
        model.requestAISuggestion()
        try await waitForEditorAIRequestCount(1, from: completer)
        try await waitForInlineAISuggestion(in: model)
        let firstRequests = await completer.recordedRequests()
        let firstRequest = try XCTUnwrap(firstRequests.first)
        let firstIdentity = model.documentIdentity
        XCTAssertEqual(firstRequest.identity.documentIdentity, firstIdentity)
        XCTAssertNotNil(model.inlineAISuggestion)

        model.switchTo("second")

        XCTAssertEqual(model.source, identicalSource)
        XCTAssertGreaterThan(model.documentIdentity, firstIdentity)
        XCTAssertNil(model.inlineAISuggestion)
        XCTAssertFalse(model.isRequestingAISuggestion)
        XCTAssertNil(model.aiSuggestionError)

        model.selectedRange = NSRange(location: (identicalSource as NSString).length, length: 0)
        model.requestAISuggestion()
        try await waitForEditorAIRequestCount(2, from: completer)
        let secondRequests = await completer.recordedRequests()
        let secondRequest = try XCTUnwrap(secondRequests.last)
        XCTAssertEqual(secondRequest.identity.documentIdentity, model.documentIdentity)
        XCTAssertNotEqual(secondRequest.identity.documentIdentity, firstRequest.identity.documentIdentity)
    }

    // MARK: - insertAtCursor inserts at the caret, not appended to the end

    func testInsertAtCursorInsertsAtTheSelectionNotTheEnd() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.source = "local x = 1\nlocal y = 2"
        // Place the caret right after "local x = 1\n" (position 12), not at the end.
        model.selectedRange = NSRange(location: 12, length: 0)

        model.insertAtCursor("-- inserted\n")

        XCTAssertEqual(model.source, "local x = 1\n-- inserted\nlocal y = 2",
                       "the palette must insert at the cursor, never append to the end")
        XCTAssertEqual(model.selectedRange.location, 12 + ("-- inserted\n" as NSString).length)
    }

    // MARK: - schema-backed palette conformance

    func testEveryPaletteSnippetValidatesInsideTheRuntimeWrapperForItsOwnerKind() throws {
        let game = try makeTrustedGame()
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)

        for kind in ObjectKind.allCases {
            let categories = ScriptPalette.categories(for: kind)
            let items = categories.flatMap(\.items)
            XCTAssertFalse(items.isEmpty, "expected snippets for \(kind.rawValue)")
            XCTAssertEqual(Set(items.map(\.id)).count, items.count, "snippet ids must remain stable and unique")
            for item in items {
                let wrapped = "local self, world, player, ev = ...\n" + item.code
                switch runtime.validateSourceForEditor(wrapped, chunkName: item.id).outcome {
                case .accepted:
                    break
                case .refused(let stage, let message, let hint, let line):
                    XCTFail("\(kind.rawValue)/\(item.id) refused at stage \(stage), line \(line): \(message) — \(hint)")
                }
            }
        }
    }

    func testPaletteUsesShippedSignaturesInsteadOfHistoricalInvalidExamples() {
        let source = ObjectKind.allCases
            .flatMap { ScriptPalette.categories(for: $0) }
            .flatMap(\.items)
            .map(\.code)
            .joined(separator: "\n")

        XCTAssertFalse(source.contains("function(self, world, player, ev)"))
        XCTAssertFalse(source.contains("emit(self,"))
        XCTAssertFalse(source.contains("self:attach(\"name\", \"module\""))
        XCTAssertFalse(source.contains("self:setBlock(x"))
        XCTAssertFalse(source.contains("self:breakBlock(x"))
        XCTAssertFalse(source.contains("objects.find(\"entity\")"))
        XCTAssertFalse(source.contains("objects.block(x"))
        XCTAssertFalse(source.contains("log("))
        XCTAssertTrue(source.contains("every(20, \"on_interval\")"))

        let playerObjectCode = ScriptPalette.categories(for: .player)
            .first(where: { $0.title == "Objects" })?.items.map(\.code) ?? []
        let blockObjectCode = ScriptPalette.categories(for: .block)
            .first(where: { $0.title == "Objects" })?.items.map(\.code) ?? []
        XCTAssertFalse(playerObjectCode.contains("self:setBlock(\"stone\")"))
        XCTAssertFalse(playerObjectCode.contains("self:breakBlock()"))
        XCTAssertFalse(playerObjectCode.contains("self:setFurnaceOutput(\"iron_ingot\")"))
        XCTAssertTrue(blockObjectCode.contains("self:setBlock(\"stone\")"))
        XCTAssertTrue(blockObjectCode.contains("self:breakBlock()"))
        XCTAssertTrue(blockObjectCode.contains("self:setFurnaceOutput(\"iron_ingot\")"))
        // give is the inverse of the block verbs: offered on player owners, withheld from blocks.
        XCTAssertTrue(playerObjectCode.contains("ev.by:give(\"iron_pickaxe\", 1)"))
        XCTAssertFalse(blockObjectCode.contains("ev.by:give(\"iron_pickaxe\", 1)"))
    }

    func testEditorAIModesKeepManualAndOffQuietAndDebounceOnIdle() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: ScriptEditorAICompletionMode.defaultsKey)
        defaults.set(ScriptEditorAICompletionMode.manual.rawValue,
                     forKey: ScriptEditorAICompletionMode.defaultsKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: ScriptEditorAICompletionMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: ScriptEditorAICompletionMode.defaultsKey)
            }
        }

        let game = try makeTrustedGame()
        let completer = RecordingScriptEditorAICompleter()
        let model = ScriptEditorModel(target: .player, game: game, aiCompleter: completer)

        model.source = "local manual = true"
        model.selectedRange = NSRange(location: (model.source as NSString).length, length: 0)
        try await ContinuousClock().sleep(for: .milliseconds(750))
        var requests = await completer.recordedRequests()
        XCTAssertTrue(requests.isEmpty, "Manual must never contact Ollama merely because source changed")

        model.requestAISuggestion()
        try await waitForEditorAIRequestCount(1, from: completer)
        requests = await completer.recordedRequests()
        XCTAssertEqual(requests.count, 1, "an explicit Manual request should contact the selected completer once")
        XCTAssertEqual(requests[0].identity.model, game.settings.aiOllamaModel)
        model.dismissAISuggestion()

        model.setAICompletionMode(.off)
        model.source = "local disabled = true"
        model.selectedRange = NSRange(location: (model.source as NSString).length, length: 0)
        model.requestAISuggestion()
        try await ContinuousClock().sleep(for: .milliseconds(750))
        requests = await completer.recordedRequests()
        XCTAssertEqual(requests.count, 1, "Off must block both idle and explicit editor requests")
        XCTAssertTrue(model.aiSuggestionError?.contains("Off") == true)

        model.setAICompletionMode(.onIdle)
        model.source = "local first = 1"
        model.selectedRange = NSRange(location: (model.source as NSString).length, length: 0)
        try await ContinuousClock().sleep(for: .milliseconds(200))
        model.source = "local final = 2"
        model.selectedRange = NSRange(location: (model.source as NSString).length, length: 0)
        try await waitForEditorAIRequestCount(2, from: completer, timeout: .seconds(2))

        requests = await completer.recordedRequests()
        XCTAssertEqual(requests.count, 2, "continued typing must cancel earlier idle work")
        let finalRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(
            finalRequest.prefix + finalRequest.selectedText + finalRequest.suffix,
            "local final = 2"
        )
    }

    func testHandlerAIPreflightRequiresEventAndAuthoringChangesStayOffline() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: ScriptEditorAICompletionMode.defaultsKey)
        defaults.set(
            ScriptEditorAICompletionMode.manual.rawValue,
            forKey: ScriptEditorAICompletionMode.defaultsKey
        )
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: ScriptEditorAICompletionMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: ScriptEditorAICompletionMode.defaultsKey)
            }
        }

        let game = try makeTrustedGame()
        let scriptingContext = game.scriptingCommandContext()
        guard case .success = scriptingContext.store.define(
            .world, "season_name", .string("summer"), readonly: true
        ) else {
            return XCTFail("expected nearby metadata fixture to succeed")
        }
        let eventStore = CustomEventStore(graph: scriptingContext.graph)
        guard case .success = eventStore.declare(
            .player,
            name: "player.quest_ready",
            fields: [CustomEventField(name: "quest", type: .string)]
        ) else {
            return XCTFail("expected custom event declaration to succeed")
        }
        let completer = RecordingScriptEditorAICompleter()
        let model = ScriptEditorModel(target: .player, game: game, aiCompleter: completer)
        model.source = "say(ev.amount)"
        model.selectedRange = NSRange(location: (model.source as NSString).length, length: 0)
        model.mode = .handler

        model.requestAISuggestion()
        try await ContinuousClock().sleep(for: .milliseconds(100))
        var requests = await completer.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(model.aiSuggestionError?.contains("No request was sent") == true)

        model.handlerEvent = "unload"
        model.requestAISuggestion()
        try await ContinuousClock().sleep(for: .milliseconds(100))
        requests = await completer.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(model.aiSuggestionError?.contains("not an EventBus handler") == true)

        model.handlerEvent = "block.used"
        model.requestAISuggestion()
        try await ContinuousClock().sleep(for: .milliseconds(100))
        requests = await completer.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(model.aiSuggestionError?.contains("not raised for player") == true)

        model.setAICompletionMode(.onIdle)
        model.handlerEvent = "entity.damaged"
        try await ContinuousClock().sleep(for: .milliseconds(750))
        requests = await completer.recordedRequests()
        XCTAssertTrue(
            requests.isEmpty,
            "changing the script mode/event must cancel stale idle work without starting another request"
        )
        model.mode = .module
        try await ContinuousClock().sleep(for: .milliseconds(750))
        requests = await completer.recordedRequests()
        XCTAssertTrue(requests.isEmpty)

        model.mode = .handler
        model.requestAISuggestion()
        try await waitForEditorAIRequestCount(1, from: completer)
        requests = await completer.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.authoringContext.targetReference, ObjectRef.player.canonical)
        XCTAssertEqual(request.authoringContext.targetKind, ObjectKind.player.rawValue)
        XCTAssertEqual(request.authoringContext.scriptMode, ScriptMode.handler.rawValue)
        XCTAssertEqual(request.authoringContext.selectedEvent, "entity.damaged")
        XCTAssertTrue(request.authoringContext.modeContract.contains("Use implicit ev directly"))
        XCTAssertTrue(request.authoringContext.compatibleEvents.contains {
            $0.name == "player.quest_ready" && $0.source == "declared_custom"
        })
        XCTAssertFalse(request.authoringContext.compatibleEvents.contains { $0.name == "block.used" })
        XCTAssertTrue(request.authoringContext.compatibleEvents.contains {
            $0.name == "entity.damaged" && !$0.summary.isEmpty
        })
        XCTAssertTrue(request.authoringContext.targetMembers.contains { $0.contains("method self:set") })
        XCTAssertFalse(request.authoringContext.targetMembers.contains { $0.contains("method h:") })
        XCTAssertFalse(request.authoringContext.targetMembers.contains { $0.contains("method block:") })
        let world = try XCTUnwrap(request.authorizedNearbyObjects.first {
            $0.reference == ObjectRef.world.canonical
        })
        let worldAttribute = try XCTUnwrap(world.customAttributes.first {
            $0.name == "season_name"
        })
        XCTAssertEqual(worldAttribute.type, "string")
        XCTAssertEqual(worldAttribute.mutability, "read_only")

        model.handlerEvent = "player.open_signal"
        model.requestAISuggestion()
        try await waitForEditorAIRequestCount(2, from: completer)
        requests = await completer.recordedRequests()
        let openRequest = try XCTUnwrap(requests.last)
        let openEvent = try XCTUnwrap(openRequest.authoringContext.compatibleEvents.first {
            $0.name == "player.open_signal"
        })
        XCTAssertEqual(openEvent.source, "open_custom_selected")
        XCTAssertEqual(openEvent.payloadContract, "open_custom_unknown_envelope_only")
        XCTAssertTrue(openEvent.payloadFields.isEmpty)

        let moduleCompleter = RecordingScriptEditorAICompleter()
        let moduleModel = ScriptEditorModel(target: .world, game: game, aiCompleter: moduleCompleter)
        moduleModel.source = "local observed_player = objects.get(\"player\")"
        moduleModel.selectedRange = NSRange(
            location: (moduleModel.source as NSString).length, length: 0
        )
        moduleModel.requestAISuggestion()
        try await waitForEditorAIRequestCount(1, from: moduleCompleter)
        let moduleRequests = await moduleCompleter.recordedRequests()
        let moduleRequest = try XCTUnwrap(moduleRequests.first)
        XCTAssertTrue(moduleRequest.authoringContext.compatibleEvents.contains {
            $0.name == "block.used" && $0.source == "built_in"
        }, "module authoring must retain cross-kind built-in payload contracts")
        let nearbyPlayer = try XCTUnwrap(moduleRequest.authorizedNearbyObjects.first {
            $0.reference == ObjectRef.player.canonical
        })
        XCTAssertTrue(nearbyPlayer.builtInEvents?.contains("player.attacked") == true)
        let nearbyDeclaration = try XCTUnwrap(nearbyPlayer.customEvents?.first {
            $0.name == "player.quest_ready"
        })
        XCTAssertEqual(nearbyDeclaration.payloadFields, ["quest:string"])
    }

    func testFurnaceAIContextUsesRealSelfReceiverAndSmeltContract() async throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: ScriptEditorAICompletionMode.defaultsKey)
        defaults.set(
            ScriptEditorAICompletionMode.manual.rawValue,
            forKey: ScriptEditorAICompletionMode.defaultsKey
        )
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: ScriptEditorAICompletionMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: ScriptEditorAICompletionMode.defaultsKey)
            }
        }

        let game = try makeTrustedGame()
        let x = Int(game.player.x.rounded(.down))
        let y = Int(game.player.y.rounded(.down))
        let z = Int(game.player.z.rounded(.down))
        guard game.world.getChunkAt(x, z) != nil else { return XCTFail("spawn chunk must be loaded") }
        _ = game.world.setBlock(x, y, z, Int(cell(B.furnace)))
        game.world.setBlockEntity(makeFurnaceBE(x, y, z, "furnace"))
        let target = ObjectRef.block(dim: game.dim, x: x, y: y, z: z)
        let completer = RecordingScriptEditorAICompleter()
        let model = ScriptEditorModel(target: target, game: game, aiCompleter: completer)
        model.source = "-- convert every output to iron"
        model.selectedRange = NSRange(location: (model.source as NSString).length, length: 0)

        model.requestAISuggestion()
        try await waitForEditorAIRequestCount(1, from: completer)
        let recordedRequests = await completer.recordedRequests()
        let request = try XCTUnwrap(recordedRequests.first)

        XCTAssertTrue(request.authoringContext.targetMembers.contains {
            $0 == "method self:setFurnaceOutput(item)"
        })
        XCTAssertTrue(request.authoringContext.targetMembers.contains {
            $0.hasPrefix("method self:setBlock(")
        })
        XCTAssertFalse(request.authoringContext.targetMembers.contains {
            $0.contains("method h:") || $0.contains("method block:") || $0.contains("method furnace:")
        })
        let event = try XCTUnwrap(request.authoringContext.compatibleEvents.first {
            $0.name == "furnace.smeltCompleted"
        })
        XCTAssertTrue(event.payloadFields.contains("recipeOutput:string"))
        XCTAssertTrue(event.payloadFields.contains("output:string"))
        XCTAssertTrue(event.summary.contains("completed one smelting operation"))
    }

    private func waitForEditorAIRequestCount(
        _ expected: Int,
        from completer: RecordingScriptEditorAICompleter,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await completer.recordedRequests().count >= expected { return }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for \(expected) editor AI request(s)")
    }

    private func waitForInlineAISuggestion(
        in model: ScriptEditorModel,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if model.inlineAISuggestion != nil { return }
            try await clock.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for an inline AI suggestion")
    }

    // MARK: - lan-client-parity: guest mode

    /// design.md §11 phase 4: Save on a guest never calls `ScriptStore.attach` directly (it would
    /// refuse with `.lanClient` immediately, same as every other direct guest write) — it sends a
    /// `scriptIntent` instead and reports doing so, rather than either silently failing or
    /// attaching locally.
    func testGuestSaveNeverAttachesLocallyAndReportsSendingToHost() throws {
        let game = try makeLANClientGame()
        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertEqual(model.scriptingAvailability, .runtimeUnavailable(.lanGuest))
        XCTAssertNil(model.scriptingAvailability.activationAction)
        model.currentName = "greet"
        model.source = "say(\"hi\")"

        chatLog.removeAll()
        let confirmed = model.save()

        XCTAssertTrue(model.status?.contains("sent") == true && model.status?.contains("host") == true,
                      "expected a 'sent ... to the host' status; got: \(model.status ?? "nil")")
        XCTAssertFalse(model.statusIsError)
        XCTAssertFalse(confirmed, "a queued guest intent is not a confirmed save")
        XCTAssertTrue(model.isDirty, "the only guest-side source copy must remain protected until confirmation")
        // Never attached anything through the guest's own (inert) executor.
        XCTAssertEqual(game.scriptingCommandContext().scriptStore.list(.player).count, 0)
    }

    /// Re-opening the editor on an existing script name never shows source — only the replicated
    /// name/mode, and a status note explaining why.
    func testGuestSwitchToPrefillsOnlyReplicatedMetadataNeverSource() throws {
        let game = try makeLANClientGame()
        let manager = LANMultiplayerManager.shared
        manager.attachGame(game)
        let ref = ObjectRef.player
        _ = manager.applyReplicationBatchForTesting(LANReplicationBatch(
            tick: 1, fullSnapshot: false,
            objectAttributes: [LANObjectAttributeSnapshot(
                ref: ref.canonical, revision: 1, attrsJSON: "{}",
                scriptsJSON: LANObjectAttributeSnapshot.encodeScripts([
                    LANScriptMetadata(name: "greet", mode: "handler", enabled: true),
                ])
            )]
        ))

        let model = ScriptEditorModel(target: .player, game: game, existingName: "greet")

        XCTAssertEqual(model.source, "", "source must never be prefilled for a guest")
        XCTAssertEqual(model.mode, .handler, "mode must come from replicated metadata")
        XCTAssertTrue(model.status?.contains("greet") == true, "expected a status note naming the script")
        XCTAssertFalse(model.statusIsError)
    }

    /// `detach` is a forwardable `/script` verb (design.md §11) — a guest's delete must send a
    /// `scriptIntent`, not attempt a local (inert) detach.
    func testGuestDeleteSendsDetachIntent() throws {
        let game = try makeLANClientGame()
        let model = ScriptEditorModel(target: .player, game: game)

        model.deleteScript("greet")

        XCTAssertTrue(model.status?.contains("sent") == true, "expected a 'sent detach...' status; got: \(model.status ?? "nil")")
        XCTAssertFalse(model.statusIsError)
    }
}

private actor RecordingScriptEditorAICompleter: ScriptEditorAICompleting {
    private var requests: [OllamaCodeCompletionRequest] = []

    func completeEditorRequest(
        _ request: OllamaCodeCompletionRequest
    ) async throws -> OllamaCodeCompletionResponse {
        requests.append(request)
        return OllamaCodeCompletionResponse(
            identity: request.identity,
            insertion: " -- suggested",
            strategy: .safePrompt,
            modelHints: nil
        )
    }

    func recordedRequests() -> [OllamaCodeCompletionRequest] { requests }
}

@MainActor
final class InspectorDataProviderTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if entityTypes().isEmpty { registerAllEntities() }
    }

    private func makeTrustedGame() throws -> GameCore {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-inspector-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(name: "Inspector Test", seedText: "77", mode: GameMode.creative, difficulty: 2)
        return game
    }

    func testHostRowsShowLiveAttributesScriptsAndSubscriptions() throws {
        let game = try makeTrustedGame()
        let context = game.scriptingCommandContext()
        XCTAssertEqual(context.store.set(.player, "mood", .string("focused")), .success(.string("focused")))
        guard case .success = context.scriptStore.attach(
            .player, name: "greet", source: "say(\"hi\")", mode: .module, triggers: [], by: .player, tick: 0
        ) else {
            return XCTFail("expected attach to succeed")
        }

        let rows = inspectorRows(target: .player, game: game)
        XCTAssertTrue(rows.contains { $0.contains("mood") && $0.contains("focused") })
        XCTAssertTrue(rows.contains { $0.contains("greet") && $0.contains("module") })
    }

    func testEmptyObjectReportsNoneForEachSection() throws {
        let game = try makeTrustedGame()
        let rows = inspectorRows(target: .player, game: game)
        XCTAssertEqual(rows.filter { $0.contains("(none)") }.count, 3,
                       "attributes, scripts, and subscriptions all report emptiness explicitly")
    }

    /// lan-client-parity (change 4): the guest Scripts section now surfaces replicated
    /// name/mode/enabled metadata (marked read-only) instead of the old "not available to
    /// guests" note — Subscriptions is unaffected (design.md §11 scopes guest parity to
    /// attrs/scripts, not subscriptions).
    func testGuestRowsShowReplicatedScriptMetadataButNotSubscriptions() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-inspector-guest-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "guest-inspector-host", worldName: "Guest Inspector Host", seed: 4242,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2
        ))

        let manager = LANMultiplayerManager.shared
        manager.attachGame(game)
        let ref = ObjectRef.player
        _ = manager.applyReplicationBatchForTesting(LANReplicationBatch(
            tick: 1, fullSnapshot: false,
            objectAttributes: [LANObjectAttributeSnapshot(
                ref: ref.canonical, revision: 1, attrsJSON: "{}",
                scriptsJSON: LANObjectAttributeSnapshot.encodeScripts([
                    LANScriptMetadata(name: "greet", mode: "module", enabled: true),
                ])
            )]
        ))

        let rows = inspectorRows(target: ref, game: game)
        XCTAssertTrue(rows.contains { $0.contains("greet") && $0.contains("module") && $0.contains("replicated, read-only") },
                      "got: \(rows)")
        XCTAssertTrue(rows.contains { $0.contains("not available to guests") },
                      "subscriptions must still say unavailable; got: \(rows)")
    }
}
