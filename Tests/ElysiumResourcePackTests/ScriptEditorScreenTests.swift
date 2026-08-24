// ScriptEditorScreenTests.swift — scripting-ui-and-replication (change 3). design.md §16 row 3:
// "full in-game script editor (multi-line, syntax colouring, error line, save/run)". Model-
// level coverage: `LuaSyntaxColoring`'s tokenizer spans (pure, no UI dependency), the Inspector
// data provider (`inspectorRows`), and — the "editor proof" the Builder brief asks for — the
// real `ScriptEditorScreen` driven headlessly through its actual `Screen` surface
// (`insertText`/`onKey`/button `onClick()`) exactly the way
// `ResourcePackHardeningTests.testShowMinimapPreferenceIsKeyboardAndAccessibilityReachable`
// already proved out for another screen: a real `MTLDevice`/`UICanvas`/`UIManager`, `ui.open`,
// then synthetic input — no live window, no AppKit event loop.

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
final class ScriptEditorScreenTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        if entityTypes().isEmpty { registerAllEntities() }
    }

    private func makeTrustedGameAndUI() throws -> (GameCore, UIManager) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ui = UIManager(cv: UICanvas(device: device))
        ui.resize(480, 270, 1)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-script-editor-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(name: "Script Editor Test", seedText: "9001", mode: GameMode.creative, difficulty: 2)
        XCTAssertTrue(game.hasWorld())
        return (game, ui)
    }

    /// Types `text` character by character through the screen's real `insertText`, and turns
    /// every `\n` into a real `onKey(ui, game, "Enter")` — the exact two entry points a live
    /// keystroke stream reaches (`AppInputRouterM.swift`'s dispatch to `screen.insertText`, and
    /// `onKeyEvent` -> `onKey` for named keys).
    private func type(_ text: String, into screen: ScriptEditorScreen, _ ui: UIManager, _ game: GameCore) {
        for ch in text {
            if ch == "\n" {
                _ = screen.onKey(ui, game, "Enter")
            } else {
                _ = screen.insertText(ui, game, String(ch))
            }
        }
    }

    private func click(_ label: String, on screen: Screen) throws {
        let button = try XCTUnwrap(screen.buttons.first { $0.label == label }, "no '\(label)' button")
        XCTAssertTrue(button.enabled, "'\(label)' button must be enabled")
        button.onClick()
    }

    func testTypingMultilineModuleSourceAndSavingAttachesItByteExact() throws {
        let (game, ui) = try makeTrustedGameAndUI()
        let screen = ScriptEditorScreen(target: .player, existingName: nil)
        ui.open(screen, game)

        let nameField = try XCTUnwrap(screen.fields.first { $0.id == "script.name" })
        nameField.text = "greet"

        XCTAssertTrue(screen.textFocused, "the source body owns keyboard input as soon as the screen opens")
        let source = "local n = 0\nfunction onLoad()\n  n = n + 1\nend"
        type(source, into: screen, ui, game)
        XCTAssertEqual(screen.lines, ["local n = 0", "function onLoad()", "  n = n + 1", "end"],
                        "typed Enter must split into new array entries, never an embedded \\n")

        try click("Save", on: screen)

        let saved = try XCTUnwrap(game.scriptingCommandContext().scriptStore.get(.player, "greet"))
        XCTAssertEqual(saved.source, source, "the reconstructed (lines joined by \\n) source must round-trip byte-exact")
        XCTAssertEqual(saved.mode, .module)
        XCTAssertNil(screen.errorLine)
    }

    func testBackspaceAtColumnZeroJoinsWithThePreviousLine() throws {
        let (game, ui) = try makeTrustedGameAndUI()
        let screen = ScriptEditorScreen(target: .player, existingName: nil)
        ui.open(screen, game)
        type("ab\ncd", into: screen, ui, game)
        XCTAssertEqual(screen.lines, ["ab", "cd"])
        XCTAssertEqual(screen.caretLine, 1)
        XCTAssertEqual(screen.caretCol, 2)

        screen.caretCol = 0
        _ = screen.onKey(ui, game, "Backspace")
        XCTAssertEqual(screen.lines, ["abcd"], "joining must concatenate, not drop, the second line's text")
        XCTAssertEqual(screen.caretLine, 0)
        XCTAssertEqual(screen.caretCol, 2, "caret lands exactly at the old join point")
    }

    func testInvalidSyntaxSetsTheErrorLineAndNeverAttaches() throws {
        let (game, ui) = try makeTrustedGameAndUI()
        let screen = ScriptEditorScreen(target: .player, existingName: nil)
        ui.open(screen, game)
        let nameField = try XCTUnwrap(screen.fields.first { $0.id == "script.name" })
        nameField.text = "broken"

        // Line 1 is a harmless comment so the fault must be reported on line 2, proving the
        // validator's line number — not just "some error happened" — reaches the editor.
        type("-- comment\nif true then", into: screen, ui, game)
        try click("Save", on: screen)

        XCTAssertEqual(screen.errorLine, 2, "the compile fault's own line number must surface, not line 1")
        XCTAssertNotNil(screen.statusMessage)
        XCTAssertTrue(screen.statusIsError)
        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "broken"),
                     "a script that fails validation must never be attached")
    }

    func testHandlerModeAttachesATriggerForTheChosenEvent() throws {
        let (game, ui) = try makeTrustedGameAndUI()
        let screen = ScriptEditorScreen(target: .player, existingName: nil)
        ui.open(screen, game)
        let nameField = try XCTUnwrap(screen.fields.first { $0.id == "script.name" })
        nameField.text = "onload_handler"
        let eventField = try XCTUnwrap(screen.fields.first { $0.id == "script.event" })

        try click("module", on: screen) // the mode toggle button starts labeled "module"; clicking flips it to "handler"
        XCTAssertTrue(screen.handlerMode)
        eventField.text = "load"
        type("log('loaded')", into: screen, ui, game)
        try click("Save", on: screen)

        let saved = try XCTUnwrap(game.scriptingCommandContext().scriptStore.get(.player, "onload_handler"))
        XCTAssertEqual(saved.mode, .handler)
        XCTAssertEqual(saved.triggers.first?.event, .load)
    }

    func testRunEphemeralNeverPersistsAScript() throws {
        let (game, ui) = try makeTrustedGameAndUI()
        let screen = ScriptEditorScreen(target: .player, existingName: nil)
        ui.open(screen, game)
        type("log('hello from run')", into: screen, ui, game)
        try click("Run", on: screen)

        XCTAssertNil(screen.errorLine)
        XCTAssertEqual(game.scriptingCommandContext().scriptStore.list(.player).count, 0,
                       "Run is ephemeral (§9.3) — it must never attach anything")
    }

    // MARK: - lan-client-parity (change 4): guest mode

    private func makeLANClientGameAndUI() throws -> (GameCore, UIManager) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ui = UIManager(cv: UICanvas(device: device))
        ui.resize(480, 270, 1)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-script-editor-guest-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "guest-editor-host", worldName: "Guest Editor Host", seed: 4242,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue, playerCount: 2
        ))
        XCTAssertTrue(game.isLANClientWorld)
        return (game, ui)
    }

    /// design.md §11 phase 4: Save on a guest never calls `ScriptStore.attach` directly (it
    /// would refuse with `.lanClient` immediately, same as every other direct guest write) — it
    /// sends a `scriptIntent` instead and reports doing so, rather than either silently failing
    /// or attaching locally.
    func testGuestSaveNeverAttachesLocallyAndReportsSendingToHost() throws {
        let (game, ui) = try makeLANClientGameAndUI()
        let screen = ScriptEditorScreen(target: .player, existingName: nil)
        ui.open(screen, game)
        let nameField = try XCTUnwrap(screen.fields.first { $0.id == "script.name" })
        nameField.text = "greet"
        type("log('hi')", into: screen, ui, game)

        chatLog.removeAll()
        try click("Save", on: screen)

        XCTAssertTrue(chatLog.contains { $0.text.contains("sent") && $0.text.contains("host") },
                      "expected a 'sent ... to the host' chat line; got: \(chatLog.map(\.text))")
        // Never attached anything through the guest's own (inert) executor — resolving `.player`
        // built-ins doesn't need a live world at all here, so this is a meaningful assertion, not
        // a vacuous one: the guest's local `scriptingCommandContext()` executor was never called.
        XCTAssertEqual(game.scriptingCommandContext().scriptStore.list(.player).count, 0)
    }

    /// Re-opening the editor on an existing script name never shows source — only the
    /// replicated name/mode, and a note explaining why.
    func testGuestEditorPrefillsOnlyReplicatedMetadataNeverSource() throws {
        let (game, ui) = try makeLANClientGameAndUI()
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

        let screen = ScriptEditorScreen(target: .player, existingName: "greet")
        ui.open(screen, game)

        XCTAssertEqual(screen.lines, [""], "source must never be prefilled for a guest")
        XCTAssertTrue(screen.handlerMode, "mode must come from replicated metadata")
        XCTAssertTrue(screen.statusMessage?.contains("greet") == true, "expected a status note naming the script")
        XCTAssertFalse(screen.statusIsError)
    }
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
            .player, name: "greet", source: "log('hi')", mode: .module, triggers: [], by: .player, tick: 0
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
