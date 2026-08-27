import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class ScriptEditorAuthoringModelTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        if entityTypes().isEmpty { registerAllEntities() }
    }

    private func makeGame() throws -> GameCore {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "elysium-authoring-model-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(name: "Authoring Model Test", seedText: "31415", mode: GameMode.creative, difficulty: 2)
        return game
    }

    private func makeGuestGame() throws -> GameCore {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: "elysium-authoring-guest-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "authoring-host", worldName: "Authoring Host", seed: 42,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue,
            playerCount: 2
        ))
        LANMultiplayerManager.shared.attachGame(game)
        return game
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
        XCTAssertNil(model.aiInsertionPreflightFailure(
            "on(\"entity.damaged\", function(ev) say(ev.amount) end)"
        ))
    }

    func testAIAuthoringContractAndPaletteUseOnlyShippedShapes() throws {
        let moduleHelp = ScriptEditorAuthoringContract.modeHelp(.module)
        XCTAssertTrue(moduleHelp.contains("function(ev)"))
        XCTAssertTrue(moduleHelp.contains("receives exactly one ev"))
        XCTAssertTrue(moduleHelp.contains("target:onAttribute"))

        let handlerHelp = ScriptEditorAuthoringContract.modeHelp(.handler)
        XCTAssertTrue(handlerHelp.contains("supplies exactly one event value"))
        XCTAssertTrue(handlerHelp.contains("target:onAttribute"))

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
        XCTAssertTrue(guide.contains("only block-specific handle methods"))
        XCTAssertTrue(guide.contains("engine, player, ai, lan, or script:<owner-ref>"))
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
