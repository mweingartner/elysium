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
        _ = manager.applyReplicationBatchForTesting(LANReplicationBatch(
            tick: 1, fullSnapshot: false,
            objectAttributes: [LANObjectAttributeSnapshot(
                ref: selfRef.canonical, revision: 1, attrsJSON: attributesJSON,
                scriptsJSON: LANObjectAttributeSnapshot.encodeScripts([
                    LANScriptMetadata(name: "greet", mode: "module", enabled: true),
                ])
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
    }
}
