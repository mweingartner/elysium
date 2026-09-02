import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class ScriptEditorAuthoringModelTests: XCTestCase {
    private struct TestGameFixture {
        let game: GameCore
        let settingsDirectory: URL
    }

    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        if entityTypes().isEmpty { registerAllEntities() }
    }

    private func makeIsolatedGame(prefix: String) throws -> TestGameFixture {
        // LocalSettingsStore intentionally refuses symlinked path components. Foundation's
        // temporaryDirectory is `/var/...` on macOS, where `/var` is a symlink, so use the same
        // canonical test root as the store's filesystem-boundary suite.
        let rootDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: rootDirectory) }
        let databaseURL = rootDirectory.appendingPathComponent("worlds.sqlite")
        let settingsDirectory = rootDirectory.appendingPathComponent("settings", isDirectory: true)
        try FileManager.default.createDirectory(
            at: settingsDirectory,
            withIntermediateDirectories: false
        )
        let game = GameCore(
            db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false),
            localSettingsStore: LocalSettingsStore(directoryURL: settingsDirectory)
        )
        return TestGameFixture(
            game: game,
            settingsDirectory: settingsDirectory
        )
    }

    private func makeGameFixture() throws -> TestGameFixture {
        let fixture = try makeIsolatedGame(prefix: "elysium-authoring-model")
        let game = fixture.game
        game.createWorld(name: "Authoring Model Test", seedText: "31415", mode: GameMode.creative, difficulty: 2)
        return fixture
    }

    private func makeGame() throws -> GameCore {
        try makeGameFixture().game
    }

    private func makeGuestGame() throws -> GameCore {
        let fixture = try makeIsolatedGame(prefix: "elysium-authoring-guest")
        let game = fixture.game
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "authoring-host", worldName: "Authoring Host", seed: 42,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue,
            playerCount: 2
        ))
        LANMultiplayerManager.shared.attachGame(game)
        return game
    }

    private func useManualEditorAI() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ScriptEditorAICompletionMode.defaultsKey)
        addTeardownBlock {
            if let previous {
                defaults.set(previous, forKey: ScriptEditorAICompletionMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: ScriptEditorAICompletionMode.defaultsKey)
            }
        }
        defaults.set(
            ScriptEditorAICompletionMode.manual.rawValue,
            forKey: ScriptEditorAICompletionMode.defaultsKey
        )
    }

    @discardableResult
    private func setTestAIModel(_ name: String, in game: GameCore) -> Bool {
        var settings = game.settings
        settings.aiOllamaModel = name
        switch game.persistAndPublishSettingsCandidate(
            settings,
            expectedLiveRevision: game.settingsRevision
        ) {
        case .success:
            return true
        case .failure(let error):
            XCTFail("failed to persist isolated test model: \(error)")
            return false
        }
    }

    func testAIModelPersistenceUsesIsolatedSettingsStore() throws {
        let fixture = try makeGameFixture()
        let expectedModel = "isolated-coder:latest"
        guard setTestAIModel(expectedModel, in: fixture.game) else {
            return XCTFail("expected isolated test model setting to persist")
        }

        let isolatedSettingsURL = fixture.settingsDirectory
            .appendingPathComponent("settings.json", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: isolatedSettingsURL.path))
        XCTAssertEqual(
            try LocalSettingsStore(directoryURL: fixture.settingsDirectory)
                .loadSettings().get().aiOllamaModel,
            expectedModel
        )
    }

    private func waitUntil(
        attempts: Int = 300,
        condition: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if await condition() { return true }
            try? await ContinuousClock().sleep(for: .milliseconds(10))
        }
        return false
    }

    func testDirtyStateTracksSourceMetadataAndSuccessfulSave() throws {
        let game = try makeGame()
        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertFalse(model.isDirty)

        model.currentName = "greet"
        model.source = "say(\"hello\")"
        XCTAssertTrue(model.isDirty)

        XCTAssertTrue(model.save())
        XCTAssertFalse(model.isDirty)

        model.mode = .handler
        XCTAssertTrue(model.isDirty)
    }

    func testWorldObjectSnapshotIsUniqueAndContainsStableAnchors() throws {
        let game = try makeGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.refreshWorldObjects()

        let refs = model.worldObjects.map(\.id)
        XCTAssertEqual(refs.count, Set(refs).count)
        XCTAssertTrue(refs.contains(ObjectRef.player.canonical))
        XCTAssertTrue(refs.contains(ObjectRef.world.canonical))
        XCTAssertTrue(refs.contains(ObjectRef.dimension(game.dim).canonical))
        XCTAssertTrue(model.worldObjects.first(where: { $0.ref == .player })?.isTarget == true)
    }

    func testSnapshotPublishesLiveCustomAttributesAndInsertionUsesCanonicalRef() throws {
        let game = try makeGame()
        let context = game.scriptingCommandContext()
        XCTAssertEqual(context.store.set(.player, "mood", .string("focused")), .success(.string("focused")))
        let model = ScriptEditorModel(target: .player, game: game)

        XCTAssertEqual(model.targetCustomAttributes, ["mood"])
        let player = try XCTUnwrap(model.worldObjects.first(where: { $0.ref == .player }))
        model.insertObjectBinding(player)
        XCTAssertEqual(model.source, "local player_object = objects.get(\"player\")")
    }

    func testCustomAttributeCompletionCarriesLiveTypeAndReadonlyState() throws {
        let game = try makeGame()
        let context = game.scriptingCommandContext()
        guard case .success = context.store.define(
            .player, "mood", .string("focused"), readonly: true
        ) else {
            return XCTFail("expected readonly custom attribute definition to succeed")
        }

        let model = ScriptEditorModel(target: .player, game: game)
        let attribute = try XCTUnwrap(model.targetCustomAttributeCompletions.first(where: { $0.name == "mood" }))
        XCTAssertEqual(attribute.typeName, "string")
        XCTAssertTrue(attribute.isReadOnly)
    }

    func testNearbyObjectCompletionPreservesTypedReadonlyAttributeMetadata() throws {
        let game = try makeGame()
        let context = game.scriptingCommandContext()
        guard case .success = context.store.define(
            .world, "season_name", .string("summer"), readonly: true
        ) else {
            return XCTFail("expected readonly nearby-object attribute definition to succeed")
        }

        let model = ScriptEditorModel(target: .player, game: game)
        let world = try XCTUnwrap(model.languageEnvironment.objectReferences.first {
            $0.canonicalRef == ObjectRef.world.canonical
        })
        let attribute = try XCTUnwrap(world.customAttributes.first {
            $0.name == "season_name"
        })

        XCTAssertEqual(attribute.typeName, "string")
        XCTAssertTrue(attribute.isReadOnly)
        XCTAssertTrue(attribute.summary.contains(ObjectRef.world.canonical))
    }

    func testHandlerValidationRejectsReservedOrIncompatibleBuiltInsButKeepsCustomNamespaceOpen() throws {
        let game = try makeGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.mode = .handler

        model.handlerEvent = "unload"
        XCTAssertTrue(model.handlerEventValidationError?.contains("not an EventBus handler") == true)

        model.handlerEvent = "block.used"
        XCTAssertTrue(model.handlerEventValidationError?.contains("not raised for player") == true)

        model.handlerEvent = "player.quest_ready"
        XCTAssertNil(model.handlerEventValidationError)
    }

    func testChangingHandlerAwayFromAttributeChangedClearsItsAttributeFilter() throws {
        let game = try makeGame()
        let store = game.scriptingCommandContext().scriptStore
        _ = try store.attach(
            .player, name: "watch", source: "world.attrs.joined = true", mode: .handler,
            triggers: [Trigger(
                event: .attributeChanged, attribute: "favorite_color", target: .object(.player)
            )], by: .player, tick: 0
        ).get()
        let model = ScriptEditorModel(target: .player, game: game, existingName: "watch")

        model.handlerEvent = "player.joined"
        XCTAssertTrue(model.save())

        let saved = try XCTUnwrap(store.get(.player, "watch"))
        XCTAssertEqual(saved.triggers.first?.event, .playerJoined)
        XCTAssertNil(saved.triggers.first?.attribute)
    }

    func testEventCatalogFiltersBuiltInsAndPublishesTargetDeclarations() throws {
        let game = try makeGame()
        let context = game.scriptingCommandContext()
        let eventStore = CustomEventStore(graph: context.graph)
        guard case .success = eventStore.declare(
            .player,
            name: "player.quest_ready",
            fields: [
                CustomEventField(name: "quest", type: .string),
                CustomEventField(name: "reward", type: .integer, isNullable: true),
            ],
            summary: "A quest reward is ready."
        ) else {
            return XCTFail("expected custom event declaration to succeed")
        }

        let model = ScriptEditorModel(target: .player, game: game)
        let names = model.handlerEventCandidates.map(\.name)
        XCTAssertTrue(names.contains("entity.damaged"))
        XCTAssertFalse(names.contains("block.used"))
        let custom = try XCTUnwrap(model.handlerEventCandidates.first {
            $0.name == "player.quest_ready"
        })
        XCTAssertEqual(custom.source, .declaredCustom)
        XCTAssertEqual(custom.payload.map(\.name), ["quest", "reward"])
        XCTAssertEqual(custom.payload.last?.isNullable, true)
        XCTAssertNotNil(custom.provenance)
    }

    func testAIInsertionPreflightRejectsModeContractViolations() throws {
        let game = try makeGame()
        let model = ScriptEditorModel(target: .player, game: game)

        model.mode = .handler
        model.handlerEvent = "entity.damaged"
        XCTAssertTrue(model.aiInsertionPreflightFailure(
            "subscribe(self, \"entity.damaged\", function(ev) say(ev.amount) end)"
        )?.contains("already the selected event body") == true)
        XCTAssertNil(model.aiInsertionPreflightFailure("say(ev.amount)"))

        model.mode = .module
        XCTAssertTrue(model.aiInsertionPreflightFailure("say(ev.amount)")?.contains("no top-level ev") == true)
        XCTAssertTrue(
            model.aiInsertionPreflightFailure("h:setFurnaceOutput(\"iron_ingot\")")?.contains("'h'") == true
        )
        XCTAssertNil(model.aiInsertionPreflightFailure("local h = self\nh:exists()"))
        XCTAssertNil(model.aiInsertionPreflightFailure(
            "on(\"entity.damaged\", function(ev) say(ev.amount) end)"
        ))
    }

    func testInsertableProposalStripsTrailingProseAndRefusesUnparseableReplies() throws {
        let game = try makeGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.mode = .module

        // A clean module script is inserted verbatim.
        let clean = "on(\"block.used\", function(ev)\n  ev.by:give(\"iron_pickaxe\", 1)\nend)"
        XCTAssertEqual(model.insertableProposal(from: clean), clean)

        // The model sometimes appends an explanation after the code despite the code-only prompt.
        // That trailing prose is a syntax error once inserted, so it must be stripped, not kept —
        // this is the exact Birch Button failure that motivated the salvage.
        let withProse = clean + "\n\nNote: the exact attribute name may vary between versions."
        XCTAssertEqual(model.insertableProposal(from: withProse), clean)

        // Invalid or mode-incompatible Lua is not prose. Salvage must not drop it and insert a
        // valid-looking prefix, because doing so would silently change the requested behavior.
        XCTAssertNil(model.insertableProposal(from: "wait(1)\nsay(ev.kind)"))

        // A fenced reply is unwrapped and any prose after the closing fence discarded.
        let fenced = "```lua\n" + clean + "\n```\nThat should grant the pickaxe."
        XCTAssertEqual(model.insertableProposal(from: fenced), clean)
        XCTAssertNil(model.insertableProposal(from: "```lua\nwait(1)\n```\nsay(ev.kind)"))

        for labeledLua in [
            "wait(1)\nNote: launchRocket \"now\"",
            "wait(1)\nExplanation: launchRocket {}",
        ] {
            guard case .refused = model.applyEditorAIReply(labeledLua) else {
                return XCTFail("labeled Lua call sugar must remain whole and be refused")
            }
            XCTAssertTrue(model.source.isEmpty)
            XCTAssertNil(model.insertableProposal(from: labeledLua + " trailing"))
        }
        XCTAssertNil(model.insertableProposal(from: "wait(1)\nNote: self[\"bad\"]()"))

        // A reply that is entirely prose yields nothing insertable: the salvage's own parse check
        // rejects every trailing-trimmed prefix, so insertableProposal returns nil.
        XCTAssertNil(model.insertableProposal(from: "I have added the handler for you."))

        // Regression guard: the parse check lives ONLY in the salvage path, never in the shared
        // aiInsertionPreflightFailure that the inline ghost-text completion also calls. So an
        // in-progress completion that is valid Lua only once the surrounding edit is finished (here
        // a mid-assignment "local total =") must still pass preflight rather than be rejected as a
        // parse error.
        XCTAssertNil(model.aiInsertionPreflightFailure("local total ="))
    }

    func testPanelRequestAutomaticallyInsertsValidatedModuleLuaAtCapturedCaret() async throws {
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

        let game = try makeGame()
        var settings = game.settings
        settings.aiOllamaModel = "test-coder:latest"
        guard case .success = game.persistAndPublishSettingsCandidate(
            settings,
            expectedLiveRevision: game.settingsRevision
        ) else {
            return XCTFail("expected test model setting to persist")
        }
        let generated = "on(\"entity.damaged\", function(ev)\n  say(\"hurt\")\nend)"
        let completer = StaticEditorReplyCompleter(
            reply: generated + "\n\nThis callback reports damage."
        )
        let model = ScriptEditorModel(
            target: .player,
            game: game,
            aiCompleter: completer
        )
        model.source = "local enabled = true\n"
        let insertionLocation = (model.source as NSString).length
        model.selectedRange = NSRange(location: insertionLocation, length: 0)

        let reply = try await model.requestEditorAIReply(
            instruction: "Add a callback that reports damage.",
            intent: .writeCode
        )

        XCTAssertEqual(
            model.source,
            "local enabled = true\n" + generated
        )
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.externalEditorEdit?.replacementRange, NSRange(
            location: insertionLocation,
            length: 0
        ))
        XCTAssertEqual(model.externalEditorEdit?.replacementText, generated)
        guard case .inserted(let receipt) = reply.applyOutcome else {
            return XCTFail("expected validated module insertion, got \(reply.applyOutcome)")
        }
        XCTAssertEqual(receipt.mode, .module)
        XCTAssertNil(receipt.eventName)
        XCTAssertTrue(receipt.omittedTrailingText)
        let completedRequestCount = await completer.completedRequestCount()
        XCTAssertEqual(completedRequestCount, 1)
    }

    func testAskIntentNeverEditsLuaLookingAnswerAndDoesNotRequireHandlerEvent() async throws {
        useManualEditorAI()
        let game = try makeGame()
        XCTAssertTrue(setTestAIModel("test-coder:latest", in: game))
        let completer = StaticEditorReplyCompleter(reply: "return")
        let model = ScriptEditorModel(target: .player, game: game, aiCompleter: completer)
        model.source = "local preserved = true"
        model.selectedRange = NSRange(location: (model.source as NSString).length, length: 0)
        model.mode = .handler
        model.handlerEvent = ""

        let reply = try await model.requestEditorAIReply(
            instruction: "What does return do?",
            intent: .ask
        )

        XCTAssertEqual(reply.text, "return")
        XCTAssertEqual(reply.applyOutcome, .answerOnly)
        XCTAssertEqual(model.source, "local preserved = true")
        XCTAssertNil(model.externalEditorEdit)
        let recordedIntent = await completer.lastInstructionIntent()
        XCTAssertEqual(recordedIntent, .question)
    }

    func testColdWaitCapturesSelectionBeforePreparationAndRefusesRetargeting() async throws {
        useManualEditorAI()
        let game = try makeGame()
        XCTAssertTrue(setTestAIModel("test-coder:latest", in: game))
        let completer = BlockingPreparationEditorReplyCompleter(reply: "say(\"ready\")")
        let model = ScriptEditorModel(target: .player, game: game, aiCompleter: completer)
        model.source = "local preserved = true\n"
        model.selectedRange = NSRange(location: (model.source as NSString).length, length: 0)
        let originalSource = model.source

        let task = Task {
            try await model.requestEditorAIReply(
                instruction: "Add a ready message.",
                intent: .writeCode
            )
        }
        let preparationStarted = await waitUntil {
            await completer.preparationHasStarted()
        }
        XCTAssertTrue(preparationStarted)
        model.selectedRange = NSRange(location: 0, length: 0)
        await completer.finishPreparation()

        do {
            _ = try await task.value
            XCTFail("a cold request must become stale when its captured selection changes")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .stale)
        }
        XCTAssertEqual(model.source, originalSource)
        XCTAssertNil(model.externalEditorEdit)
        let completedRequestCount = await completer.completedRequestCount()
        XCTAssertEqual(completedRequestCount, 0)
    }

    func testRepliesBecomeStaleAfterModelSwitchAndAfterEditorAIIsTurnedOff() async throws {
        useManualEditorAI()
        let game = try makeGame()
        XCTAssertTrue(setTestAIModel("test-coder-a:latest", in: game))

        let modelSwitchCompleter = BlockingCompletionEditorReplyCompleter(reply: "say(\"old\")")
        let model = ScriptEditorModel(
            target: .player,
            game: game,
            aiCompleter: modelSwitchCompleter
        )
        let modelSwitchTask = Task {
            try await model.requestEditorAIReply(
                instruction: "Add a message.",
                intent: .writeCode
            )
        }
        let firstStarted = await waitUntil {
            await modelSwitchCompleter.completionHasStarted()
        }
        XCTAssertTrue(firstStarted)
        XCTAssertTrue(model.setAIModel("test-coder-b:latest"))
        await modelSwitchCompleter.finishCompletion()
        do {
            _ = try await modelSwitchTask.value
            XCTFail("an old-model reply must not edit the current document")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .stale)
        }
        XCTAssertTrue(model.source.isEmpty)

        let offCompleter = BlockingCompletionEditorReplyCompleter(reply: "say(\"late\")")
        let offModel = ScriptEditorModel(target: .player, game: game, aiCompleter: offCompleter)
        let offTask = Task {
            try await offModel.requestEditorAIReply(
                instruction: "Add another message.",
                intent: .writeCode
            )
        }
        let secondStarted = await waitUntil {
            await offCompleter.completionHasStarted()
        }
        XCTAssertTrue(secondStarted)
        offModel.setAICompletionMode(.off)
        await offCompleter.finishCompletion()
        do {
            _ = try await offTask.value
            XCTFail("turning Editor AI Off must invalidate an in-flight panel reply")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .stale)
        }
        XCTAssertTrue(offModel.source.isEmpty)
    }

    func testClosingEditorInvalidatesAViewOwnedPanelRequestBeforeItCanEdit() async throws {
        useManualEditorAI()
        let game = try makeGame()
        XCTAssertTrue(setTestAIModel("test-coder:latest", in: game))
        let completer = BlockingCompletionEditorReplyCompleter(reply: "say(\"late\")")
        let model = ScriptEditorModel(target: .player, game: game, aiCompleter: completer)
        model.beginAIReadiness()
        let request = Task {
            try await model.requestEditorAIReply(
                instruction: "Add a message.",
                intent: .writeCode
            )
        }
        let completionStarted = await waitUntil {
            await completer.completionHasStarted()
        }
        XCTAssertTrue(completionStarted)

        // This is the model-boundary sequence used by ScriptEditorWindowController on close. The
        // panel task is view-owned, so stale generation—not SwiftUI disappearance timing—must be
        // the final authority preventing a late hidden-draft edit.
        model.cancelAIWork(clearSuggestion: true)
        model.endAIReadiness()
        await completer.finishCompletion()

        do {
            _ = try await request.value
            XCTFail("closing the editor must invalidate a late panel reply")
        } catch {
            XCTAssertEqual(error as? OllamaCodeCompletionError, .stale)
        }
        XCTAssertTrue(model.source.isEmpty)
        XCTAssertNil(model.externalEditorEdit)
    }

    func testAutomaticHandlerInsertionUsesImplicitEventBodyAndRefusesWrongDestinationOrAPI() throws {
        let game = try makeGame()
        let model = ScriptEditorModel(target: .player, game: game)
        model.mode = .handler
        model.handlerEvent = "entity.damaged"
        model.selectedRange = NSRange(location: 0, length: 0)

        let valid = "assert(ev.amount > 0)"
        let validOutcome = model.applyEditorAIReply(valid)
        guard case .inserted(let receipt) = validOutcome else {
            return XCTFail("expected handler body to auto-insert, got \(validOutcome)")
        }
        XCTAssertEqual(model.source, valid)
        XCTAssertEqual(receipt.mode, .handler)
        XCTAssertEqual(receipt.eventName, "entity.damaged")
        XCTAssertTrue(model.status?.contains("Handler · entity.damaged") == true)
        XCTAssertTrue(
            game.scriptingCommandContext().scriptStore.list(.player).isEmpty,
            "automatic insertion must not Save or attach generated source"
        )

        model.newScript()
        model.mode = .handler
        model.handlerEvent = "entity.damaged"
        let wrapper = "on(\"entity.damaged\", function(ev) say(ev.amount) end)"
        guard case .refused = model.applyEditorAIReply(wrapper) else {
            return XCTFail("handler wrapper must be refused rather than inserted")
        }
        XCTAssertTrue(model.source.isEmpty)

        guard case .refused(let inventedAPI) = model.applyEditorAIReply(
            "self:launchRocket()"
        ) else {
            return XCTFail("invented API must be refused rather than inserted")
        }
        XCTAssertTrue(inventedAPI.contains("not available"))
        XCTAssertTrue(model.source.isEmpty)

        model.newScript()
        model.mode = .module
        model.source = "local function f(launchRocket) end\nwait(1)\n"
        model.selectedRange = NSRange(location: (model.source as NSString).length, length: 0)
        let beforeInventedGlobal = model.source
        guard case .refused(let inventedGlobal) = model.applyEditorAIReply("launchRocket()") else {
            return XCTFail("an invented global after a dry-run suspension must be refused")
        }
        XCTAssertTrue(inventedGlobal.contains("cannot be proven to be a shipped function"))
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply("(launchRocket)()") else {
            return XCTFail("a parenthesized invented call after suspension must be refused")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply("_ENV[\"launchRocket\"]()") else {
            return XCTFail("a dynamic environment call after suspension must be refused")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local actions = { launchRocket }\nactions[1]()"
        ) else {
            return XCTFail("an indexed call graph after suspension must be refused")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply("thing:launchRocket()") else {
            return XCTFail("an unknown member-call receiver after suspension must be refused")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local gate = dim\nwait(1)\ngate:launchRocket()"
        ) else {
            return XCTFail("a bare handle factory must not authorize an alias after suspension")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local gate = objects.get(\"player\")\ngate = thing\nwait(1)\ngate:launchRocket()"
        ) else {
            return XCTFail("reassignment must revoke a statically known handle alias")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local function helper() end\nhelper = launchRocket\nwait(1)\nhelper()"
        ) else {
            return XCTFail("reassignment must revoke a statically known helper")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local self = {}\nwait(1)\nself:get(\"health\")"
        ) else {
            return XCTFail("a shadowed implicit receiver must not retain shipped authority")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local math = {}\nwait(1)\nmath.random()"
        ) else {
            return XCTFail("a shadowed module must not retain shipped authority")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local say = {}\nwait(1)\nsay(\"hello\")"
        ) else {
            return XCTFail("a shadowed shipped global must not retain callable authority")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local function invoke(say)\n  wait(1)\n  say(\"hello\")\nend\ninvoke(nil)"
        ) else {
            return XCTFail("a function parameter must shadow a shipped global")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local function inspect(self)\n  wait(1)\n  self:get(\"health\")\nend\ninspect({})"
        ) else {
            return XCTFail("a function parameter must shadow an implicit receiver")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local function invoke\n(say)\n  wait(1)\n  say(\"hello\")\nend\ninvoke(nil)"
        ) else {
            return XCTFail("a multiline function parameter must shadow a shipped global")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "for\nsay in values() do\n  wait(1)\n  say(\"hello\")\nend"
        ) else {
            return XCTFail("a multiline generic-for variable must shadow a shipped global")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local gate = self\nand nil\nwait(1)\ngate:get(\"health\")"
        ) else {
            return XCTFail("a continued initializer must not be mistaken for an exact handle")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local gate = objects.get(\"player\")\ngate,\nother = nil, nil\nwait(1)\ngate:get(\"health\")"
        ) else {
            return XCTFail("a multiline multiple assignment must revoke a handle alias")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local gate = objects.get(\"player\")\nlocal function f(gate)\n  wait(1)\n  gate:get(\"health\")\nend\nf({})"
        ) else {
            return XCTFail("a nested parameter must revoke a same-named handle alias")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local function helper(helper)\n  wait(1)\n  helper()\nend\nhelper(nil)"
        ) else {
            return XCTFail("a helper parameter must revoke the same-named helper proof")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "wait(1)\nfor value in launchRocket do\n  say(value)\nend"
        ) else {
            return XCTFail("a generic-for iterator must be a statically known callable")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "wait(1)\nfor value in pairs({}) and launchRocket do\n  say(value)\nend"
        ) else {
            return XCTFail("a generic-for iterator must be one complete proven call expression")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        for unresolvedCallback in [
            "wait(1)\nafter(1, launchRocket)",
            "wait(1)\non(\"custom.test\", launchRocket)",
            "wait(1)\nsubscribe(self, \"custom.test\", launchRocket)",
            "wait(1)\nregister(\"later\", launchRocket)",
            "wait(1)\npcall(launchRocket)",
            "wait(1)\nxpcall(launchRocket, launchRocket)",
        ] {
            guard case .refused = model.applyEditorAIReply(unresolvedCallback) else {
                return XCTFail("higher-order calls must prove callable arguments: \(unresolvedCallback)")
            }
            XCTAssertEqual(model.source, beforeInventedGlobal)
        }
        guard case .refused = model.applyEditorAIReply(
            "on(\"entity.damaged\", function(ev) say(launchRocket.name) end)"
        ) else {
            return XCTFail("an invented global value inside a deferred callback must be refused")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "wait(1)\nsay(launchRocket.name)"
        ) else {
            return XCTFail("an invented global value after suspension must be refused")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        let topLevelEventOutcome = model.applyEditorAIReply("wait(1)\nsay(ev.kind)")
        guard case .refused = topLevelEventOutcome else {
            return XCTFail(
                "top-level ev must not be authorized in Module mode, got \(topLevelEventOutcome)"
            )
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local launchRocket = launchRocket; wait(1); say(launchRocket.name)"
        ) else {
            return XCTFail("a local must not authorize an unresolved read in its own initializer")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local launchRocket =\n  launchRocket\nwait(1)\nsay(launchRocket.name)"
        ) else {
            return XCTFail("a multiline initializer must resolve before its local becomes visible")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local launchRocket = not\n  launchRocket\nwait(1)\nsay(launchRocket.name)"
        ) else {
            return XCTFail("a multiline unary initializer must resolve before its local is visible")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)
        guard case .refused = model.applyEditorAIReply(
            "local launchRocket = #\n  launchRocket\nwait(1)\nsay(launchRocket)"
        ) else {
            return XCTFail("the length operator must not end a multiline local initializer")
        }
        XCTAssertEqual(model.source, beforeInventedGlobal)

        guard case .inserted = model.applyEditorAIReply(
            "local gate = objects.get(\"player\")\ngate:get(\"health\")"
        ) else {
            return XCTFail("a statically known object-handle binding should remain insertable")
        }
        XCTAssertTrue(model.source.contains("gate:get(\"health\")"))

        model.newScript()
        model.source = "local function f(callback)\n  callback()\nend\nwait(1)"
        model.selectedRange = NSRange(location: 0, length: (model.source as NSString).length)
        let beforeUnsafeRewrite = model.source
        guard case .refused = model.applyEditorAIReply("wait(1)\ncallback()") else {
            return XCTFail("a rewrite cannot trade an existing dynamic call for a new unresolved call")
        }
        XCTAssertEqual(model.source, beforeUnsafeRewrite)

        model.newScript()
        let helperDeclaration = "local function helper() end\n"
        model.source = helperDeclaration + "wait(1)\nhelper()"
        model.selectedRange = NSRange(
            location: 0,
            length: (helperDeclaration as NSString).length
        )
        let beforeSuffixInvalidation = model.source
        guard case .refused = model.applyEditorAIReply("local removed = true\n") else {
            return XCTFail("a rewrite cannot remove a helper required by the unchanged suffix")
        }
        XCTAssertEqual(model.source, beforeSuffixInvalidation)

        model.newScript()
        model.source = "local function invoke(callback)\n  callback()\nend\n"
        model.selectedRange = NSRange(location: (model.source as NSString).length, length: 0)
        guard case .inserted = model.applyEditorAIReply("say(\"safe\")") else {
            return XCTFail("an unrelated existing dynamic call must not block a safe new edit")
        }
        XCTAssertTrue(model.source.hasSuffix("say(\"safe\")"))

        model.newScript()
        guard case .inserted = model.applyEditorAIReply(
            "local rocket = { name = \"safe\" }\nwait(1)\nsay(rocket.name)"
        ) else {
            return XCTFail("a declared local must remain available after its initializer")
        }
        XCTAssertTrue(model.source.contains("say(rocket.name)"))

        let beforeAnswer = model.source
        XCTAssertEqual(
            model.applyEditorAIReply("This handler explains what damage means."),
            .answerOnly
        )
        XCTAssertEqual(model.source, beforeAnswer)
    }

    func testAIAuthoringContractAndPaletteUseOnlyShippedShapes() throws {
        let moduleHelp = ScriptEditorAuthoringContract.modeHelp(.module)
        XCTAssertTrue(moduleHelp.contains("function(ev)"))
        XCTAssertTrue(moduleHelp.contains("receives exactly one ev"))
        XCTAssertTrue(moduleHelp.contains("self:onAttribute"))
        XCTAssertFalse(moduleHelp.contains("target:onAttribute"))

        let handlerHelp = ScriptEditorAuthoringContract.modeHelp(.handler)
        XCTAssertTrue(handlerHelp.contains("supplies exactly one event value"))
        XCTAssertTrue(handlerHelp.contains("self:onAttribute"))
        XCTAssertFalse(handlerHelp.contains("target:onAttribute"))

        let setSnippet = try XCTUnwrap(ScriptLanguageSchema.snippets.first {
            $0.id == "object.set"
        })
        XCTAssertEqual(setSnippet.code, "self:set(\"custom_state\", \"active\")")
        let defineSnippet = try XCTUnwrap(ScriptLanguageSchema.snippets.first {
            $0.id == "object.define"
        })
        XCTAssertEqual(defineSnippet.code, "self:define(\"custom_state\", \"active\")")
        let attach = try XCTUnwrap(ScriptLanguageSchema.handleMethods.first {
            $0.name == "attach"
        })
        XCTAssertTrue(attach.summary.contains("There is no opts.mode option"))

        let guide = ScriptAIAuthoringGuide.text
        XCTAssertTrue(guide.contains("attributes and attached scripts share one name namespace"))
        XCTAssertTrue(guide.contains("There is no mode option"))
        XCTAssertTrue(guide.contains("Block-specific handle methods"))
        XCTAssertTrue(guide.contains("engine, player, ai, lan, or script:<owner-ref>"))
        XCTAssertTrue(guide.contains("self:setFurnaceOutput(\"iron_ingot\")"))
        XCTAssertTrue(guide.contains("player:give(item[, count])"))
        XCTAssertTrue(guide.contains("A declaration defines schema and discovery only"))
        XCTAssertFalse(guide.contains("h:"))
        XCTAssertFalse(guide.contains("target:on"))
        XCTAssertFalse(guide.contains("{mode="))
    }

    func testBindingSanitizesLuaKeywordsAndUnicodeToASafeIdentifier() throws {
        let game = try makeGame()
        let model = ScriptEditorModel(target: .player, game: game)
        let keywordNamedObject = WorldObjectPaletteEntry(
            ref: .world, displayName: "End", distance: nil, isLive: true,
            isTarget: false, isCursorTarget: false, attributeNames: [], scriptNames: [],
            capabilities: ["canonical reference"]
        )
        model.insertObjectBinding(keywordNamedObject)
        XCTAssertEqual(model.source, "local end_object = objects.get(\"world\")")

        model.newScript()
        let unicode = WorldObjectPaletteEntry(
            ref: .world, displayName: "\u{00C9}\u{00E9} Portal", distance: nil, isLive: true,
            isTarget: false, isCursorTarget: false, attributeNames: [], scriptNames: [],
            capabilities: ["canonical reference"]
        )
        model.insertObjectBinding(unicode)
        XCTAssertEqual(model.source, "local portal = objects.get(\"world\")")
    }

    func testStaleWorldObjectCannotBeInsertedThroughTheModel() throws {
        let game = try makeGame()
        let model = ScriptEditorModel(target: .player, game: game)
        let stale = WorldObjectPaletteEntry(
            ref: .entity(uid: 9_999_999), displayName: "Gone", distance: nil, isLive: false,
            isTarget: false, isCursorTarget: false, attributeNames: [], scriptNames: [],
            capabilities: ["stale canonical reference"]
        )

        model.insertObjectReference(stale)

        XCTAssertTrue(model.source.isEmpty)
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.status?.contains("no longer available") == true)
    }

    func testGuestSnapshotUsesReplicatedMetadataAndDistinguishesSelfFromHostPlayer() throws {
        let game = try makeGuestGame()
        let manager = LANMultiplayerManager.shared
        let selfRef = ObjectRef.lanPlayer(peerID: manager.localGuestPeerID)
        let attributesJSON = AttrValueCodec.encode(.map(["mood": .string("focused")]))
        let mirroredEvent = CustomEventDeclaration(
            kind: try XCTUnwrap(EventKind.parse("guest.action_ready")),
            fields: [CustomEventField(name: "action", type: .string)],
            summary: "The host says an action is ready.",
            provenance: Provenance(createdBy: .player, createdTick: 1)
        )
        _ = manager.applyReplicationBatchForTesting(LANReplicationBatch(
            tick: 1, fullSnapshot: false,
            objectAttributes: [LANObjectAttributeSnapshot(
                ref: selfRef.canonical, revision: 1, attrsJSON: attributesJSON,
                scriptsJSON: LANObjectAttributeSnapshot.encodeScripts([
                    LANScriptMetadata(name: "greet", mode: "module", enabled: true),
                ]),
                eventsJSON: LANObjectAttributeSnapshot.encodeEvents([mirroredEvent])
            )]
        ))

        let model = ScriptEditorModel(target: selfRef, game: game)
        let selfEntry = try XCTUnwrap(model.worldObjects.first(where: { $0.ref == selfRef }))
        let hostEntry = try XCTUnwrap(model.worldObjects.first(where: { $0.ref == .player }))

        XCTAssertTrue(selfEntry.isLive)
        XCTAssertEqual(selfEntry.displayName, "You (LAN guest)")
        XCTAssertEqual(selfEntry.attributeNames, ["mood"])
        XCTAssertEqual(selfEntry.scriptNames, ["greet"])
        XCTAssertEqual(hostEntry.displayName, "Host player")
        XCTAssertEqual(model.targetCustomAttributes, ["mood"])
        let event = try XCTUnwrap(model.handlerEventCandidates.first {
            $0.name == "guest.action_ready"
        })
        XCTAssertEqual(event.source, .declaredCustom)
        XCTAssertEqual(event.payload.map(\.name), ["action"])
        XCTAssertNil(event.provenance, "LAN authoring metadata must not expose host provenance")
    }
}

private actor StaticEditorReplyCompleter: ScriptEditorAICompleting {
    private let reply: String
    private var requestCount = 0
    private var recordedInstructionIntent: OllamaCodeCompletionInstructionIntent?

    init(reply: String) {
        self.reply = reply
    }

    func completeEditorRequest(
        _ request: OllamaCodeCompletionRequest
    ) async throws -> OllamaCodeCompletionResponse {
        requestCount += 1
        recordedInstructionIntent = request.instructionIntent
        return OllamaCodeCompletionResponse(
            identity: request.identity,
            insertion: reply,
            strategy: .safePrompt,
            modelHints: nil
        )
    }

    func completedRequestCount() -> Int { requestCount }
    func lastInstructionIntent() -> OllamaCodeCompletionInstructionIntent? {
        recordedInstructionIntent
    }
}

private actor BlockingPreparationEditorReplyCompleter: ScriptEditorAICompleting {
    private let reply: String
    private var preparationStarted = false
    private var preparationContinuation: CheckedContinuation<Void, Never>?
    private var requestCount = 0

    init(reply: String) {
        self.reply = reply
    }

    func prepareEditorModel(_ model: String, owner: UUID) async throws {
        _ = model
        _ = owner
        preparationStarted = true
        await withCheckedContinuation { continuation in
            preparationContinuation = continuation
        }
    }

    func completeEditorRequest(
        _ request: OllamaCodeCompletionRequest
    ) async throws -> OllamaCodeCompletionResponse {
        requestCount += 1
        return OllamaCodeCompletionResponse(
            identity: request.identity,
            insertion: reply,
            strategy: .safePrompt,
            modelHints: nil
        )
    }

    func preparationHasStarted() -> Bool { preparationStarted }

    func finishPreparation() {
        preparationContinuation?.resume()
        preparationContinuation = nil
    }

    func completedRequestCount() -> Int { requestCount }
}

private actor BlockingCompletionEditorReplyCompleter: ScriptEditorAICompleting {
    private let reply: String
    private var completionStarted = false
    private var completionContinuation: CheckedContinuation<Void, Never>?

    init(reply: String) {
        self.reply = reply
    }

    func completeEditorRequest(
        _ request: OllamaCodeCompletionRequest
    ) async throws -> OllamaCodeCompletionResponse {
        completionStarted = true
        await withCheckedContinuation { continuation in
            completionContinuation = continuation
        }
        return OllamaCodeCompletionResponse(
            identity: request.identity,
            insertion: reply,
            strategy: .safePrompt,
            modelHints: nil
        )
    }

    func completionHasStarted() -> Bool { completionStarted }

    func finishCompletion() {
        completionContinuation?.resume()
        completionContinuation = nil
    }
}
