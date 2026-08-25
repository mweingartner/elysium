// ScriptEditorScreenTests.swift — native SwiftUI script editor (Stage A). design.md §16 row 3:
// "full in-game script editor (multi-line, syntax colouring, error line, save/run)", now served by
// a native window instead of the retired game-canvas `ScriptEditorScreen`. Model-level coverage:
// `LuaSyntaxColoring`'s tokenizer spans (pure, no UI dependency — unchanged from before), the
// Inspector data provider (`inspectorRows` — unchanged from before), and the editor's real
// controller, `ScriptEditorModel`, driven headlessly: no `Screen`, no `UIManager`, no `MTLDevice`,
// no `NSWindow` — the whole point of splitting a thin SwiftUI view over a testable model. The Core
// assertions the old screen-driven suite proved carry over unchanged in substance: multiline
// type+Save round-trips byte-exact via `scriptStore.get(...).source`; invalid syntax never
// attaches and reports the right error line; Run/ephemeral never persists; a LAN guest's Save
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

        model.save()

        let saved = try XCTUnwrap(game.scriptingCommandContext().scriptStore.get(.player, "greet"))
        XCTAssertEqual(saved.source, source, "the source must round-trip byte-exact through Save")
        XCTAssertEqual(saved.mode, .module)
        XCTAssertNil(model.errorLine)
        XCTAssertFalse(model.statusIsError)
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
        model.source = "log('loaded')"

        model.save()

        let saved = try XCTUnwrap(game.scriptingCommandContext().scriptStore.get(.player, "onload_handler"))
        XCTAssertEqual(saved.mode, .handler)
        XCTAssertEqual(saved.triggers.first?.event, .load)
        XCTAssertFalse(model.statusIsError)
    }

    // MARK: - host: Run is ephemeral, never persists

    func testRunEphemeralNeverPersistsAScript() throws {
        let game = try makeTrustedGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.source = "log('hello from run')"

        model.run()

        XCTAssertNil(model.errorLine)
        XCTAssertEqual(game.scriptingCommandContext().scriptStore.list(.player).count, 0,
                       "Run is ephemeral (§9.3) — it must never attach anything")
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

    // MARK: - lan-client-parity: guest mode

    /// design.md §11 phase 4: Save on a guest never calls `ScriptStore.attach` directly (it would
    /// refuse with `.lanClient` immediately, same as every other direct guest write) — it sends a
    /// `scriptIntent` instead and reports doing so, rather than either silently failing or
    /// attaching locally.
    func testGuestSaveNeverAttachesLocallyAndReportsSendingToHost() throws {
        let game = try makeLANClientGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.currentName = "greet"
        model.source = "log('hi')"

        chatLog.removeAll()
        model.save()

        XCTAssertTrue(model.status?.contains("sent") == true && model.status?.contains("host") == true,
                      "expected a 'sent ... to the host' status; got: \(model.status ?? "nil")")
        XCTAssertFalse(model.statusIsError)
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
