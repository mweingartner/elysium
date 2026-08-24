// LANScriptIntentHostTests.swift — lan-client-parity (change 4). design.md §11 phase 4: the
// host-side half of guest scripting parity — everything reachable without a live socket
// connection (the app-layer transport glue, `LANTransport.applyHostScriptIntent`, is a thin
// wrapper over exactly these pieces; see `Tests/ElysiumResourcePackTests/
// LANGuestCommandGateTests.swift` for the client-side routing-decision half and the app-target
// `lan_players`/`/script trust <peer>` coverage).
//
// Covers: the `canScript`/`canUseAI` permission grant/revoke round trip, the
// `ScriptingCommands.lanForwardableCommand` allowlist, `LANScriptIntent`'s hostile-bytes codec
// discipline, the message-kind protocol additions (rate limit / RPG-clock-catch-up / inbound
// admission), `player:lan:<peerID>` live resolution + provenance, replicated script metadata,
// and the `lan_players` world-delete hook.

import XCTest
@testable import ElysiumCore

@MainActor
final class LANScriptIntentHostTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
    }

    // MARK: - canScript / canUseAI grant round trip (LANMultiplayerHostSession)

    func testCanScriptDefaultsOffAndSetCanScriptFlipsAuthorization() {
        let session = LANMultiplayerHostSession()
        _ = session.acceptPeer(playerID: "guest1", displayName: "Guest One")

        guard case .rejected = session.authorize(.script, from: "guest1") else {
            return XCTFail("canScript must default false")
        }

        XCTAssertTrue(session.setCanScript(true, for: "guest1"))
        guard case .accepted = session.authorize(.script, from: "guest1") else {
            return XCTFail("setCanScript(true) must grant .script")
        }

        XCTAssertTrue(session.setCanScript(false, for: "guest1"))
        guard case .rejected = session.authorize(.script, from: "guest1") else {
            return XCTFail("setCanScript(false) must revoke .script")
        }
    }

    func testCanUseAIDefaultsOffAndSetCanUseAIFlipsAuthorizationIndependentlyOfCanScript() {
        let session = LANMultiplayerHostSession()
        _ = session.acceptPeer(playerID: "guest1", displayName: "Guest One")

        guard case .rejected = session.authorize(.ai, from: "guest1") else {
            return XCTFail("canUseAI must default false")
        }
        XCTAssertTrue(session.setCanUseAI(true, for: "guest1"))
        guard case .accepted = session.authorize(.ai, from: "guest1") else {
            return XCTFail("setCanUseAI(true) must grant .ai")
        }
        // Independent of canScript — granting AI must not also grant scripting.
        guard case .rejected = session.authorize(.script, from: "guest1") else {
            return XCTFail("canUseAI and canScript must be independent grants")
        }
    }

    func testSetCanScriptOnUnknownPeerFailsWithoutTrapping() {
        let session = LANMultiplayerHostSession()
        XCTAssertFalse(session.setCanScript(true, for: "nobody"))
        XCTAssertFalse(session.setCanUseAI(true, for: "nobody"))
    }

    func testPermissionsRoundTripThroughLANPeerRecordSnapshot() {
        let session = LANMultiplayerHostSession()
        _ = session.acceptPeer(playerID: "guest1", displayName: "Guest One")
        XCTAssertTrue(session.setCanScript(true, for: "guest1"))
        let record = session.peerRecord(playerID: "guest1")
        XCTAssertEqual(record?.permissions.canScript, true)

        // seedPeerRecord (reconnect path) must carry the grant through.
        let freshSession = LANMultiplayerHostSession()
        guard let seedRecord = record else { return XCTFail("expected a record") }
        freshSession.seedPeerRecord(seedRecord)
        XCTAssertEqual(freshSession.permissions(for: "guest1")?.canScript, true)
    }

    // MARK: - lanForwardableCommand allowlist (shared by both sides of the wire)

    func testLanForwardableCommandAllowsExactlyTheScriptIntentFamily() {
        let allowed: [(String, [String])] = [
            ("attr", ["set", "self", "n", "1"]),
            ("attr", ["define", "self", "n", "1"]),
            ("attr", ["remove", "self", "n"]),
            ("script", ["attach", "self", "n", "module", "x=1"]),
            ("script", ["detach", "self", "n"]),
            ("script", ["run", "self", "x=1"]),
            ("on", ["self", "player.joined", "s.h"]),
            ("unsubscribe", ["1"]),
            ("events", ["emit", "self", "custom.thing"]),
        ]
        for (command, arguments) in allowed {
            XCTAssertTrue(
                ScriptingCommands.lanForwardableCommand(command, arguments),
                "'\(command) \(arguments.joined(separator: " "))' should be forwardable"
            )
        }

        let refused: [(String, [String])] = [
            ("attr", ["list", "self"]),
            ("attr", ["get", "self", "n"]),
            ("attr", []),
            ("inspect", []),
            ("objects", ["near"]),
            ("events", ["recent"]),
            ("events", []),
            ("script", ["list"]),
            ("script", ["show", "self", "n"]),
            ("script", ["journal"]),
            ("script", ["undo-ai"]),
            ("script", ["trust"]),
            ("script", ["off"]),
            ("script", ["on"]),
            ("script", []),
            ("ai", ["hello"]),
            ("nonsense", ["set"]),
        ]
        for (command, arguments) in refused {
            XCTAssertFalse(
                ScriptingCommands.lanForwardableCommand(command, arguments),
                "'\(command) \(arguments.joined(separator: " "))' should NOT be forwardable"
            )
        }
    }

    // MARK: - LANScriptIntent hostile-bytes codec discipline

    func testLANScriptIntentCapsArgumentCountAndBytes() {
        let manyArgs = Array(repeating: "x", count: 50)
        let intent = LANScriptIntent.command("attr", manyArgs)
        XCTAssertLessThanOrEqual(intent.arguments.count, LAN_MULTIPLAYER_MAX_SCRIPT_INTENT_ARGUMENTS)

        let hugeArg = String(repeating: "a", count: 100_000)
        let intent2 = LANScriptIntent.command("script", ["attach", "self", "n", "module", hugeArg])
        for arg in intent2.arguments {
            XCTAssertLessThanOrEqual(arg.utf8.count, LAN_MULTIPLAYER_MAX_SCRIPT_INTENT_ARGUMENT_BYTES)
        }
    }

    func testLANScriptIntentPreservesNewlinesInArgumentsButStripsHostileControlBytes() {
        let source = "local x = 1\nlocal y = 2\t-- ok"
        let intent = LANScriptIntent.command("script", ["run", "self", source])
        XCTAssertEqual(intent.arguments.last, source, "newlines/tabs are legitimate in script source")

        let hostile = "line1\u{0001}\u{0007}line2"
        let intent2 = LANScriptIntent.command("attr", ["set", "self", "n", hostile])
        XCTAssertFalse(intent2.arguments.last?.contains("\u{0001}") ?? true)
    }

    func testLANScriptIntentPromptCapped() {
        let hugePrompt = String(repeating: "p", count: 100_000)
        let intent = LANScriptIntent.aiPrompt(hugePrompt)
        XCTAssertLessThanOrEqual(intent.prompt.utf8.count, LAN_MULTIPLAYER_MAX_SCRIPT_INTENT_PROMPT_BYTES)
    }

    func testLANScriptIntentCommandTokenCapped() {
        let intent = LANScriptIntent.command(String(repeating: "z", count: 200), [])
        XCTAssertLessThanOrEqual(intent.command.utf8.count, 16)
    }

    func testLANScriptIntentRoundTripsThroughJSON() throws {
        let intent = LANScriptIntent.command("attr", ["set", "self", "mood", "happy"])
        let message = LANMultiplayerMessage.scriptIntent(playerID: "guest1", intent: intent)
        let (kind, payload) = try LANMultiplayerFrameCodec.encodePayload(message)
        XCTAssertEqual(kind, .scriptIntent)
        let frame = LANMultiplayerFrameCodec.frame(kind: kind, payload: payload, sequence: 1)
        let decoded = try LANMultiplayerFrameCodec.decode(frame)
        guard case .scriptIntent(let playerID, let decodedIntent) = decoded.message else {
            return XCTFail("expected .scriptIntent")
        }
        XCTAssertEqual(playerID, "guest1")
        XCTAssertEqual(decodedIntent, intent)
    }

    // MARK: - message-kind protocol wiring

    func testScriptIntentIsBlockedByRPGClockCatchUpLikeEveryOtherMutatingGuestIntent() {
        XCTAssertTrue(LANMultiplayerMessageKind.scriptIntent.isHostMutationBlockedByRPGClockCatchUp)
    }

    func testScriptIntentInboundAdmissionIsHostOnlyFromAnAuthenticatedClient() {
        XCTAssertTrue(lanMultiplayerAllowsInbound(.scriptIntent, localRole: .host, phase: .authenticated))
        XCTAssertFalse(lanMultiplayerAllowsInbound(.scriptIntent, localRole: .client, phase: .authenticated))
        XCTAssertFalse(lanMultiplayerAllowsInbound(.scriptIntent, localRole: .host, phase: .awaitingHandshake))
    }

    func testScriptIntentHasItsOwnRateLimitCategory() {
        XCTAssertEqual(lanMultiplayerHostRateLimitCategory(for: .scriptIntent), .scriptIntent)
    }

    func testScriptIntentKindIsMirroredIntoTheV6Manifest() {
        XCTAssertEqual(LANV6MessageKind.scriptIntent.rawValue, LANMultiplayerMessageKind.scriptIntent.rawValue)
    }

    // MARK: - player:lan:<peerID> live resolution + guest-forwarded execution

    /// Places a `LANRemotePlayerEntity` for `peerID` directly into the game's current-dimension
    /// world — exactly what `applyLANRemotePlayers` does on the real host, without needing a
    /// live socket to drive it.
    private func addConnectedGuest(peerID: String, to game: GameCore) {
        let world = game.worlds[game.dim]!
        let state = LANPlayerState(
            playerID: peerID, displayName: "Guest", x: 5, y: 65, z: 5,
            yaw: 0, pitch: 0, health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival
        )
        let remote = LANRemotePlayerEntity(world: world, state: state)
        world.addEntity(remote)
    }

    func testLanPlayerRefIsDormantWhenPeerNotConnected() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lanplayer-dormant")
        game.createWorld(name: "W", seedText: "1", mode: GameMode.survival, difficulty: 2)
        let graph = ObjectGraph(host: game)
        switch graph.resolve(.lanPlayer(peerID: "ghost")) {
        case .dormant: break
        default: XCTFail("an unconnected peer should resolve .dormant")
        }
    }

    func testLanPlayerRefIsLiveOnHostForAConnectedPeerAndUnsupportedOnAGuest() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lanplayer-live")
        game.createWorld(name: "W", seedText: "1", mode: GameMode.survival, difficulty: 2)
        addConnectedGuest(peerID: "guest1", to: game)

        let graph = ObjectGraph(host: game)
        guard case .live(.entity(let entity, _)) = graph.resolve(.lanPlayer(peerID: "guest1")) else {
            return XCTFail("a connected peer's player:lan ref must resolve .live(.entity)")
        }
        XCTAssertTrue(entity is LANRemotePlayerEntity)
        XCTAssertEqual(graph.displayName(of: .lanPlayer(peerID: "guest1")), "Guest")
    }

    func testGuestForwardedAttrSetWritesThroughTheSameExecutorWithLanProvenance() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lanplayer-attr")
        game.createWorld(name: "W", seedText: "1", mode: GameMode.survival, difficulty: 2)
        addConnectedGuest(peerID: "guest1", to: game)

        // Exactly what LANTransport.applyHostScriptIntent does for a `.command` intent once
        // `canScript` is granted: build the guest-forwarded context and run the exact command
        // grammar the wire intent carried.
        let context = game.scriptingCommandContext(guestPeerID: "guest1")
        let result = ScriptingCommands.run(command: "attr", arguments: ["set", "self", "mood", "happy"], context: context)
        XCTAssertTrue(result.ok, "expected success, got: \(result.lines)")

        // "self" resolved to the guest's own player:lan ref, not the host's `.player`.
        let value = context.store.get(.lanPlayer(peerID: "guest1"), "mood")
        XCTAssertEqual(value, .string("happy"))

        // Provenance recorded .lan(peer:), not .player.
        let record = context.store.record(.lanPlayer(peerID: "guest1"))
        guard case .value(_, _, let provenance)? = record?.entries["mood"] else {
            return XCTFail("expected a value entry")
        }
        guard case .lan(let peer) = provenance.createdBy else {
            return XCTFail("expected .lan(peer:) provenance, got \(provenance.createdBy)")
        }
        XCTAssertEqual(peer, "guest1")

        // The host's own `.player` object is untouched.
        XCTAssertNil(context.store.get(.player, "mood"))
    }

    func testGuestForwardedScriptAttachRoutesThroughScriptStoreWithLanProvenance() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lanplayer-script")
        game.createWorld(name: "W", seedText: "1", mode: GameMode.survival, difficulty: 2)
        addConnectedGuest(peerID: "guest1", to: game)

        let context = game.scriptingCommandContext(guestPeerID: "guest1")
        let result = ScriptingCommands.run(
            command: "script", arguments: ["attach", "self", "greet", "module", "log(\"hi\")"], context: context
        )
        XCTAssertTrue(result.ok, "expected success, got: \(result.lines)")
        let script = context.scriptStore.get(.lanPlayer(peerID: "guest1"), "greet")
        XCTAssertNotNil(script)
        guard case .lan(let peer) = script?.author else {
            return XCTFail("expected .lan(peer:) author, got \(String(describing: script?.author))")
        }
        XCTAssertEqual(peer, "guest1")
    }

    func testGuestContextSelfDoesNotResolveToTheHostsOwnPlayer() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lanplayer-self")
        game.createWorld(name: "W", seedText: "1", mode: GameMode.survival, difficulty: 2)
        addConnectedGuest(peerID: "guest1", to: game)

        let guestContext = game.scriptingCommandContext(guestPeerID: "guest1")
        XCTAssertEqual(guestContext.target.resolve(alias: "self"), .lanPlayer(peerID: "guest1"))
        XCTAssertEqual(guestContext.target.resolve(alias: "player"), .player)
        // A guest-forwarded context has no cursor/looking target — the host has no structured
        // notion of a guest's crosshair.
        XCTAssertNil(guestContext.target.resolve(alias: "looking"))

        let hostContext = game.scriptingCommandContext()
        XCTAssertEqual(hostContext.target.resolve(alias: "self"), .player)
    }

    // MARK: - replicated script metadata (LANObjectAttributeSnapshot.scriptsJSON)

    func testScriptMetadataRoundTripsAndNeverCarriesSource() {
        let metadata = [
            LANScriptMetadata(name: "greet", mode: "module", enabled: true),
            LANScriptMetadata(name: "guard", mode: "handler", enabled: false),
        ]
        let json = LANObjectAttributeSnapshot.encodeScripts(metadata)
        XCTAssertFalse(json.contains("source"))
        let snapshot = LANObjectAttributeSnapshot(ref: "player:lan:guest1", revision: 1, attrsJSON: "{}", scriptsJSON: json)
        let decoded = snapshot.scripts()
        XCTAssertEqual(decoded, metadata)
    }

    func testScriptMetadataDecodeFailsClosedOnMalformedJSON() {
        let snapshot = LANObjectAttributeSnapshot(
            ref: "player:lan:guest1", revision: 1, attrsJSON: "{}", scriptsJSON: "not json at all {["
        )
        XCTAssertEqual(snapshot.scripts(), [])
    }

    func testScriptsJSONIsClampedAtConstructionWhenOversized() {
        let huge = String(repeating: "x", count: LAN_MULTIPLAYER_MAX_OBJECT_SCRIPTS_JSON_BYTES + 1)
        let snapshot = LANObjectAttributeSnapshot(ref: "player:lan:guest1", revision: 1, attrsJSON: "{}", scriptsJSON: huge)
        XCTAssertEqual(snapshot.scriptsJSON, "[]")
    }

    func testMakeLANObjectAttributeSnapshotsIncludesConnectedGuestsAndScriptMetadata() {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lanplayer-snapshot")
        game.createWorld(name: "W", seedText: "1", mode: GameMode.survival, difficulty: 2)
        addConnectedGuest(peerID: "guest1", to: game)

        let context = game.scriptingCommandContext(guestPeerID: "guest1")
        _ = ScriptingCommands.run(command: "attr", arguments: ["set", "self", "mood", "happy"], context: context)
        _ = ScriptingCommands.run(
            command: "script", arguments: ["attach", "self", "greet", "module", "log(\"hi\")"], context: context
        )

        let hostStore = game.scriptingCommandContext().store
        let hostScriptStore = game.scriptingCommandContext().scriptStore
        let snapshots = makeLANObjectAttributeSnapshots(host: game, store: hostStore, scriptStore: hostScriptStore)
        guard let guestSnapshot = snapshots.first(where: { $0.ref == "player:lan:guest1" }) else {
            return XCTFail("expected a snapshot for the connected guest's own object; got refs: \(snapshots.map(\.ref))")
        }
        let scripts = guestSnapshot.scripts()
        XCTAssertEqual(scripts.first?.name, "greet")
        XCTAssertEqual(scripts.first?.mode, "module")
        guard case .success(.map(let attrs)) = AttrValueCodec.decode(guestSnapshot.attrsJSON, caps: .defaults) else {
            return XCTFail("expected a decodable attrs map")
        }
        XCTAssertEqual(attrs["mood"], .string("happy"))
    }

    // MARK: - world-delete hook (lan_players)

    func testDeleteWorldSweepsLanPlayersRows() throws {
        let game = PersistenceTestSupport.makeGame(owner: self, label: "lanplayer-delete")
        game.createWorld(name: "DeleteMe", seedText: "1", mode: GameMode.survival, difficulty: 2)
        guard let worldID = game.worldRec?.id else { return XCTFail("expected a saved world id") }
        game.db.putLANPlayer(world: worldID, playerID: "guest1", ["displayName": "Guest"])
        game.db.putLANPlayer(world: worldID, playerID: "guest2", ["displayName": "Guest Two"])
        XCTAssertEqual(game.db.listLANPlayers(world: worldID).count, 2)

        game.exitToTitle()
        game.deleteWorld(worldID)

        XCTAssertTrue(game.db.listLANPlayers(world: worldID).isEmpty, "lan_players rows must not survive a deleted world")
    }
}
