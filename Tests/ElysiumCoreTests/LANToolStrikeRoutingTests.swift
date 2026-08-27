import XCTest
@testable import ElysiumCore

@MainActor
final class LANToolStrikeRoutingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
    }

    private func makeFixture(
        label: String
    ) -> (game: GameCore, session: LANMultiplayerHostSession, ghosts: LANHostGhostRegistry, cell: Int) {
        let game = PersistenceTestSupport.makeGame(owner: self, label: label)
        game.createWorld(name: "LAN Tool Strike", seedText: "7", mode: GameMode.survival, difficulty: 2)
        let world = game.world
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        let blockCell = Int(cell(B.stone))
        chunk.set(2, 64, 1, UInt16(blockCell))
        chunk.status = .generated
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)

        let session = LANMultiplayerHostSession()
        _ = session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        _ = session.updatePlayerState(LANPlayerState(
            playerID: "peer-a", displayName: "Alex",
            x: 2.5, y: 64, z: 1.5, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0,
            gameMode: GameMode.survival, dimension: Dim.overworld.rawValue
        ))
        let inventory = LANPlayerInventorySnapshot(
            playerID: "peer-a", selectedHotbarSlot: 0,
            slots: [LANInventorySlotSnapshot(slot: 0, itemID: iid("wooden_pickaxe"), count: 1)]
        )
        XCTAssertTrue(session.applyInventoryUpdate(
            LANInventoryUpdate(playerID: "peer-a", revision: 1, snapshot: inventory),
            from: "peer-a"
        ))
        return (game, session, LANHostGhostRegistry(), blockCell)
    }

    private func intent(
        cell: Int, sequence: UInt32, gesture: UInt32? = 1, x: Int = 2, z: Int = 1
    ) -> LANBlockIntent {
        LANBlockIntent(
            action: .toolStrike, x: x, y: 64, z: z, face: Dir.north,
            selectedHotbarSlot: 0, cell: cell, toolStrikeSequence: sequence,
            toolStrikeGesture: gesture
        )
    }

    func testHostRouteRaisesTheLocalPayloadShapeFromAuthoritativeStateOnce() {
        let fixture = makeFixture(label: "lan-tool-strike-route")
        let strike = intent(cell: fixture.cell, sequence: 1)

        XCTAssertEqual(routeLANHostToolStrikeIntent(
            strike, from: "peer-a", game: fixture.game,
            session: fixture.session, ghostRegistry: fixture.ghosts
        ), .raised)

        let events = fixture.game.eventBus.recentEvents().filter { $0.kind == .blockToolStrike }
        XCTAssertEqual(events.count, 1)
        let event = events.first
        XCTAssertEqual(event?.subject, .block(dim: .overworld, x: 2, y: 64, z: 1))
        XCTAssertEqual(event?.subjectType, "stone")
        XCTAssertEqual(event?.source, .lan(peerID: "peer-a"))
        XCTAssertEqual(event?.payload, [
            "by": .ref(ObjectRef.lanPlayer(peerID: "peer-a").canonical),
            "item": .string("wooden_pickaxe"),
            "blockName": .string("stone"),
            "face": .string("north"),
            "toolType": .string("pickaxe"),
            "tier": .int(0),
            "instant": .bool(false),
        ])

        XCTAssertEqual(routeLANHostToolStrikeIntent(
            strike, from: "peer-a", game: fixture.game,
            session: fixture.session, ghostRegistry: fixture.ghosts
        ), .ignored("duplicate tool strike"))
        XCTAssertEqual(
            fixture.game.eventBus.recentEvents().filter { $0.kind == .blockToolStrike }.count, 1
        )
    }

    func testHostAcceptsAnAuthenticatedToolStrikeOnAnUnbreakableBlock() {
        let fixture = makeFixture(label: "lan-tool-strike-unbreakable")
        let bedrock = Int(cell(B.bedrock))
        _ = fixture.game.world.setBlock(2, 64, 1, bedrock)

        XCTAssertEqual(routeLANHostToolStrikeIntent(
            intent(cell: bedrock, sequence: 1), from: "peer-a", game: fixture.game,
            session: fixture.session, ghostRegistry: fixture.ghosts
        ), .raised)
        let event = fixture.game.eventBus.recentEvents().last { $0.kind == .blockToolStrike }
        XCTAssertEqual(event?.payload["blockName"], .string("bedrock"))
        XCTAssertEqual(fixture.game.world.getBlock(2, 64, 1), bedrock)
    }

    func testHostValidationConsumesSemanticFailuresAllowsGapsAndResetsOnReconnect() {
        let fixture = makeFixture(label: "lan-tool-strike-validation")

        XCTAssertEqual(
            fixture.session.authorizeToolStrikeIntent(
                intent(cell: Int(cell(B.dirt)), sequence: 1), from: "peer-a", in: fixture.game.world
            ),
            .rejected("stale target block")
        )
        XCTAssertEqual(
            fixture.session.authorizeToolStrikeIntent(
                intent(cell: fixture.cell, sequence: 1), from: "peer-a", in: fixture.game.world
            ),
            .ignored("duplicate tool strike"),
            "a semantic rejection consumes its sequence and cannot be replayed after state changes"
        )

        let gap = intent(cell: fixture.cell, sequence: 4)
        XCTAssertEqual(
            fixture.session.authorizeToolStrikeIntent(gap, from: "peer-a", in: fixture.game.world),
            .accepted(LANAuthorizedToolStrike(blockCell: fixture.cell, itemID: iid("wooden_pickaxe")))
        )
        XCTAssertEqual(
            fixture.session.authorizeToolStrikeIntent(gap, from: "peer-a", in: fixture.game.world),
            .ignored("duplicate tool strike")
        )

        fixture.session.disconnectPeer(playerID: "peer-a", tick: 10)
        XCTAssertEqual(
            fixture.session.acceptPeer(playerID: "peer-a", displayName: "Alex", tick: 11),
            .reconnected
        )
        XCTAssertEqual(
            fixture.session.authorizeToolStrikeIntent(
                intent(cell: fixture.cell, sequence: 9), from: "peer-a", in: fixture.game.world
            ),
            .accepted(LANAuthorizedToolStrike(blockCell: fixture.cell, itemID: iid("wooden_pickaxe"))),
            "a continuing client counter is valid in the new connection epoch"
        )

        let dirtInventory = LANPlayerInventorySnapshot(
            playerID: "peer-a", selectedHotbarSlot: 0,
            slots: [LANInventorySlotSnapshot(slot: 0, itemID: iid("dirt"), count: 1)]
        )
        XCTAssertTrue(fixture.session.applyInventoryUpdate(
            LANInventoryUpdate(playerID: "peer-a", revision: 2, snapshot: dirtInventory),
            from: "peer-a"
        ))
        XCTAssertEqual(
            fixture.session.authorizeToolStrikeIntent(
                intent(cell: fixture.cell, sequence: 10), from: "peer-a", in: fixture.game.world
            ),
            .rejected("selected item is not a usable tool")
        )
    }

    func testHostDeduplicatesPerGestureButAllowsAwayBackAndReleaseRestrike() {
        let fixture = makeFixture(label: "lan-tool-strike-target-transition")
        _ = fixture.game.world.setBlock(3, 64, 1, fixture.cell)

        XCTAssertEqual(routeLANHostToolStrikeIntent(
            intent(cell: fixture.cell, sequence: 1),
            from: "peer-a", game: fixture.game,
            session: fixture.session, ghostRegistry: fixture.ghosts
        ), .raised)
        XCTAssertEqual(routeLANHostToolStrikeIntent(
            intent(cell: fixture.cell, sequence: 2),
            from: "peer-a", game: fixture.game,
            session: fixture.session, ghostRegistry: fixture.ghosts
        ), .ignored("duplicate tool strike target"))
        XCTAssertEqual(routeLANHostToolStrikeIntent(
            intent(cell: fixture.cell, sequence: 3, x: 3),
            from: "peer-a", game: fixture.game,
            session: fixture.session, ghostRegistry: fixture.ghosts
        ), .raised)
        XCTAssertEqual(routeLANHostToolStrikeIntent(
            intent(cell: fixture.cell, sequence: 4),
            from: "peer-a", game: fixture.game,
            session: fixture.session, ghostRegistry: fixture.ghosts
        ), .raised)
        XCTAssertEqual(routeLANHostToolStrikeIntent(
            intent(cell: fixture.cell, sequence: 5, gesture: 2),
            from: "peer-a", game: fixture.game,
            session: fixture.session, ghostRegistry: fixture.ghosts
        ), .raised, "a release/new-press gesture may strike the same block again")
        XCTAssertEqual(routeLANHostToolStrikeIntent(
            intent(cell: fixture.cell, sequence: 6, gesture: 1, x: 3),
            from: "peer-a", game: fixture.game,
            session: fixture.session, ghostRegistry: fixture.ghosts
        ), .ignored("stale tool strike gesture"))

        XCTAssertEqual(
            fixture.game.eventBus.recentEvents()
                .filter { $0.kind == .blockToolStrike }
                .map(\.subject),
            [
                .block(dim: .overworld, x: 2, y: 64, z: 1),
                .block(dim: .overworld, x: 3, y: 64, z: 1),
                .block(dim: .overworld, x: 2, y: 64, z: 1),
                .block(dim: .overworld, x: 2, y: 64, z: 1),
            ]
        )
    }
}
