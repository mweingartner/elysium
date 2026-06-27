import XCTest
@testable import PebbleCore

final class LANReplicationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
    }

    func testChangeLogCoalescesByPositionAndDrainsInInsertionOrder() {
        let log = LANReplicationChangeLog()
        log.record(LANBlockChange(dimension: 0, x: 1, y: 64, z: 1, cell: Int(B.dirt) << 4))
        log.record(LANBlockChange(dimension: 0, x: 2, y: 64, z: 1, cell: Int(B.stone) << 4))
        log.record(LANBlockChange(dimension: 0, x: 1, y: 64, z: 1, cell: Int(B.cobblestone) << 4))

        XCTAssertEqual(log.count, 2)
        let first = log.drain(maxCount: 1)
        XCTAssertEqual(first, [LANBlockChange(dimension: 0, x: 1, y: 64, z: 1, cell: Int(B.cobblestone) << 4)])

        let rest = log.drain()
        XCTAssertEqual(rest, [LANBlockChange(dimension: 0, x: 2, y: 64, z: 1, cell: Int(B.stone) << 4)])
        XCTAssertEqual(log.count, 0)
    }

    func testHostSessionAppliesValidatedBreakAndPlaceBlockIntents() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 2.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.creative
        ))
        _ = world.setBlock(2, 64, 1, Int(B.dirt) << 4)

        let breakResult = session.applyBlockIntent(
            LANBlockIntent(action: .breakBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0),
            from: "peer-a",
            to: world
        )
        XCTAssertEqual(breakResult, .applied([
            LANBlockChange(dimension: 0, x: 2, y: 64, z: 1, cell: 0),
        ]))
        XCTAssertEqual(world.getBlock(2, 64, 1), 0)

        let stone = Int(B.stone) << 4
        let placeResult = session.applyBlockIntent(
            LANBlockIntent(action: .placeBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0, cell: stone),
            from: "peer-a",
            to: world
        )
        XCTAssertEqual(placeResult, .applied([
            LANBlockChange(dimension: 0, x: 2, y: 65, z: 1, cell: stone),
        ]))
        XCTAssertEqual(world.getBlock(2, 65, 1), stone)
    }

    func testHostSessionRejectsOutOfReachOrInvalidPlacementCells() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 100,
            y: 64,
            z: 100,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival
        ))
        _ = world.setBlock(2, 64, 1, Int(B.dirt) << 4)

        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .breakBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .rejected("target out of reach")
        )

        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 2.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.creative
        ))
        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .placeBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0, cell: Int(UInt16.max)),
                from: "peer-a",
                to: world
            ),
            .rejected("invalid placement cell")
        )
    }

    func testHostSessionClampsUnauthorizedCreativeDimensionAndPreservesReconnectRecord() {
        let session = LANMultiplayerHostSession()

        XCTAssertEqual(session.acceptPeer(playerID: "peer-a", displayName: "Alex", tick: 3), .joined)
        let sanitized = session.updatePlayerState(
            LANPlayerState(
                playerID: "peer-a",
                displayName: "Spoofed",
                x: 8,
                y: 66,
                z: 9,
                yaw: 0.4,
                pitch: 0.1,
                health: 20,
                hunger: 19,
                selectedHotbarSlot: 2,
                gameMode: GameMode.creative,
                dimension: Dim.nether.rawValue
            ),
            currentDimension: Dim.overworld.rawValue,
            tick: 4
        )

        XCTAssertEqual(sanitized?.displayName, "Alex")
        XCTAssertEqual(sanitized?.gameMode, GameMode.survival)
        XCTAssertEqual(sanitized?.dimension, Dim.overworld.rawValue)

        session.recordInventorySnapshot(
            LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 2, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: 1, count: 32),
            ]),
            from: "peer-a"
        )
        session.disconnectPeer(playerID: "peer-a", tick: 10)

        var record = session.peerRecord(playerID: "peer-a")
        XCTAssertEqual(record?.lifecycle, .disconnected)
        XCTAssertEqual(record?.inventory?.slots.first?.count, 32)
        XCTAssertEqual(record?.disconnectedTick, 10)

        XCTAssertEqual(session.acceptPeer(playerID: "peer-a", displayName: "Alex Again", tick: 12), .reconnected)
        record = session.peerRecord(playerID: "peer-a")
        XCTAssertEqual(record?.lifecycle, .connected)
        XCTAssertEqual(record?.inventory?.slots.first?.count, 32)
        XCTAssertEqual(record?.playerState?.x, 8)
    }

    func testHostSessionPermissionGatesBuildContainerCraftingTemplateAndDeadPlayers() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 2.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival
        ))
        session.setPermissions(LANPeerPermissions(canBuild: false, canUseContainers: false, canCraft: false, canUseTemplates: false), for: "peer-a")
        _ = world.setBlock(2, 64, 1, Int(B.dirt) << 4)

        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .breakBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .rejected("permission denied: build")
        )
        XCTAssertEqual(
            session.authorizeContainerIntent(LANContainerIntent(action: .open, containerID: "chest@2,64,1", slot: -1, button: 0, shift: false), from: "peer-a"),
            .rejected("permission denied: container")
        )
        XCTAssertEqual(session.authorizeCraftingIntent(from: "peer-a"), .rejected("permission denied: crafting"))

        let result = session.applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: "Tiny", x: 1, y: 64, z: 1, rotation: 0),
            from: "peer-a",
            world: world,
            loadTemplate: { _ in nil },
            saveTemplate: { _ in false }
        )
        XCTAssertEqual(result, .rejected("permission denied: template"))

        session.setPermissions(LANPeerPermissions(), for: "peer-a")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 2.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 0,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival,
            dead: true
        ))
        XCTAssertEqual(
            session.applyBlockIntent(
                LANBlockIntent(action: .breakBlock, x: 2, y: 64, z: 1, face: 1, selectedHotbarSlot: 0),
                from: "peer-a",
                to: world
            ),
            .rejected("player is dead")
        )
    }

    func testHostSessionTemplatePermissionFlowPlacesAndUndoesValidatedTemplate() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 1.5,
            y: 64,
            z: 1.5,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.creative
        ))
        let dirt = UInt16(Int(B.dirt) << 4)
        _ = world.setBlock(1, 63, 1, Int(dirt))
        let template = ObjectTemplate(
            name: "Tiny",
            anchorX: 0,
            anchorY: 0,
            anchorZ: 0,
            sizeX: 1,
            sizeY: 1,
            sizeZ: 1,
            blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: dirt)]
        )
        var saved = ["Tiny": template]

        let placed = session.applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: "Tiny", x: 1, y: 64, z: 1, rotation: 0),
            from: "peer-a",
            world: world,
            loadTemplate: { saved[$0] },
            saveTemplate: { saved[$0.name] = $0; return true }
        )

        XCTAssertEqual(placed, .placed(name: "Tiny", blocks: 1, blockEntities: 0, cleared: 0, filled: 0))
        XCTAssertEqual(world.getBlock(1, 64, 1), Int(dirt))
        XCTAssertEqual(session.pendingBlockChanges(), [
            LANBlockChange(dimension: Dim.overworld.rawValue, x: 1, y: 64, z: 1, cell: Int(dirt)),
        ])

        let undone = session.applyTemplateIntent(
            LANTemplateIntent(action: .undoPlacement, templateName: "Tiny", x: 1, y: 64, z: 1, rotation: 0),
            from: "peer-a",
            world: world,
            loadTemplate: { saved[$0] },
            saveTemplate: { saved[$0.name] = $0; return true }
        )

        XCTAssertEqual(undone, .undone(name: "Tiny", restored: 1))
        XCTAssertEqual(world.getBlock(1, 64, 1), 0)
    }

    func testHostSessionTemplateIntentRejectsOutOfReachTargets() {
        let world = makeLoadedWorld()
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 100,
            y: 64,
            z: 100,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival
        ))

        let result = session.applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: "Tiny", x: 1, y: 64, z: 1, rotation: 0),
            from: "peer-a",
            world: world,
            loadTemplate: { _ in nil },
            saveTemplate: { _ in false }
        )

        XCTAssertEqual(result, .rejected("target out of reach"))
    }

    func testRemotePlayerEntitiesSpawnUpdateAndRemoveFromWorldSnapshots() {
        let world = makeLoadedWorld()
        let initial = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 1,
            y: 65,
            z: 2,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 18,
            selectedHotbarSlot: 3,
            gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        )

        var report = applyLANRemotePlayers([initial], to: world, localPlayerID: "local")
        XCTAssertEqual(report, LANRemotePlayerApplyReport(spawned: 1, updated: 0, removed: 0))
        var remote = world.entities.compactMap { $0 as? LANRemotePlayerEntity }.first
        XCTAssertEqual(remote?.multiplayerPlayerID, "peer-a")
        XCTAssertEqual(remote?.x, 1)

        let moved = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 4,
            y: 66,
            z: 5,
            yaw: 0.5,
            pitch: 0,
            health: 19,
            hunger: 17,
            selectedHotbarSlot: 3,
            gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        )
        report = applyLANRemotePlayers([moved], to: world, localPlayerID: "local")
        XCTAssertEqual(report.spawned, 0)
        XCTAssertEqual(report.updated, 1)
        remote = world.entities.compactMap { $0 as? LANRemotePlayerEntity }.first
        XCTAssertEqual(remote?.x, 4)
        XCTAssertEqual(remote?.health, 19)

        let nether = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 4,
            y: 66,
            z: 5,
            yaw: 0.5,
            pitch: 0,
            health: 19,
            hunger: 17,
            selectedHotbarSlot: 3,
            gameMode: GameMode.survival,
            dimension: Dim.nether.rawValue
        )
        report = applyLANRemotePlayers([nether], to: world, localPlayerID: "local")
        XCTAssertEqual(report.removed, 1)
        XCTAssertTrue(world.entities.compactMap { $0 as? LANRemotePlayerEntity }.isEmpty)
    }

    func testChunkSectionSnapshotAppliesToTargetWorld() throws {
        let source = makeLoadedWorld()
        let target = World(dim: .overworld, seed: 99)
        var dirtiedSections: [LANChunkSectionPosition] = []
        target.hooks.onSectionDirty = { cx, cz, sy in
            dirtiedSections.append(LANChunkSectionPosition(dimension: target.dim.rawValue, cx: cx, cz: cz, sectionY: sy))
        }
        let sectionY = (64 - source.info.minY) >> 4
        let dirt = Int(B.dirt) << 4
        let stone = Int(B.stone) << 4
        _ = source.setBlock(4, 64, 4, dirt)
        _ = source.setBlock(5, 65, 4, stone)

        let snapshot = try XCTUnwrap(makeLANChunkSectionSnapshot(
            from: try XCTUnwrap(source.getChunk(0, 0)),
            dimension: source.dim.rawValue,
            sectionY: sectionY
        ))

        XCTAssertTrue(applyLANChunkSectionSnapshot(snapshot, to: target))
        XCTAssertEqual(target.getBlock(4, 64, 4), dirt)
        XCTAssertEqual(target.getBlock(5, 65, 4), stone)
        XCTAssertEqual(dirtiedSections, [
            LANChunkSectionPosition(dimension: target.dim.rawValue, cx: 0, cz: 0, sectionY: sectionY),
        ])
    }

    func testClientSessionAppliesBatchAndDropsMalformedSectionsAndCells() {
        let client = LANMultiplayerClientSession()
        let validCell = Int(B.dirt) << 4
        let invalidCell = Int(UInt16.max)
        let player = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 1,
            y: 65,
            z: 2,
            yaw: 0,
            pitch: 0,
            health: 20,
            hunger: 18,
            selectedHotbarSlot: 3,
            gameMode: GameMode.survival
        )
        let validSection = LANChunkSectionSnapshot(
            dimension: 0,
            cx: 0,
            cz: 0,
            sectionY: 8,
            minY: 64,
            cells: Array(repeating: UInt16(validCell), count: LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
        )
        let malformedSection = LANChunkSectionSnapshot(
            dimension: 0,
            cx: 0,
            cz: 0,
            sectionY: 8,
            minY: 64,
            cells: [UInt16(validCell)]
        )
        let batch = LANReplicationBatch(
            tick: 12,
            fullSnapshot: true,
            world: LANWorldSummary(
                worldID: "w",
                worldName: "World",
                seed: 1,
                gameMode: GameMode.survival,
                difficulty: 2,
                dimension: 0,
                playerCount: 2
            ),
            players: [player],
            blockChanges: [
                LANBlockChange(dimension: 0, x: 1, y: 64, z: 1, cell: validCell),
                LANBlockChange(dimension: 0, x: 2, y: 64, z: 1, cell: invalidCell),
            ],
            chunkSections: [validSection, malformedSection],
            entities: [LANEntitySnapshot(entityID: 7, type: "zombie", x: 1, y: 64, z: 1, yaw: 0, pitch: 0, health: 20, dead: false)],
            inventories: [LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 3, slots: [
                LANInventorySlotSnapshot(slot: 0, itemID: 1, count: 64),
            ])]
        )

        let report = client.apply(batch)

        XCTAssertEqual(report.appliedBlockChanges, 1)
        XCTAssertEqual(report.ignoredInvalidCells, 1)
        XCTAssertEqual(report.appliedChunkSections, 1)
        XCTAssertEqual(report.ignoredInvalidSections, 1)
        XCTAssertEqual(client.latestTick, 12)
        XCTAssertEqual(client.players["peer-a"], player)
        XCTAssertEqual(client.blockCells[LANBlockPosition(dimension: 0, x: 1, y: 64, z: 1)], validCell)
        XCTAssertNil(client.blockCells[LANBlockPosition(dimension: 0, x: 2, y: 64, z: 1)])
        XCTAssertEqual(client.entities[7]?.type, "zombie")
        XCTAssertEqual(client.inventories["peer-a"]?.slots.first?.count, 64)
    }

    func testReplicationBatchCapsLargePayloadCollections() {
        let changes = (0..<(LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES + 10)).map {
            LANBlockChange(dimension: 0, x: $0, y: 64, z: 0, cell: 0)
        }
        let entities = (0..<(LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES + 10)).map {
            LANEntitySnapshot(entityID: $0, type: "zombie", x: 0, y: 64, z: 0, yaw: 0, pitch: 0, health: 20, dead: false)
        }

        let batch = LANReplicationBatch(
            tick: 1,
            fullSnapshot: false,
            blockChanges: changes,
            entities: entities
        )

        XCTAssertEqual(batch.blockChanges.count, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_CHANGES)
        XCTAssertEqual(batch.entities.count, LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES)
        XCTAssertTrue(batch.isWithinReplicationCaps)
    }

    func testMaximumChunkSectionBatchFitsFrameCap() throws {
        let section = LANChunkSectionSnapshot(
            dimension: 0,
            cx: 0,
            cz: 0,
            sectionY: 0,
            minY: -64,
            cells: Array(repeating: UInt16.max, count: LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
        )
        let batch = LANReplicationBatch(
            tick: 1,
            fullSnapshot: true,
            chunkSections: Array(repeating: section, count: LAN_MULTIPLAYER_MAX_REPLICATION_CHUNK_SECTIONS)
        )

        let encoded = try LANMultiplayerFrameCodec.encode(.replicationBatch(batch))

        XCTAssertLessThanOrEqual(encoded.count, LANMultiplayerFrameCodec.headerByteCount + LAN_MULTIPLAYER_MAX_FRAME_BYTES)
    }

    private func makeLoadedWorld() -> World {
        let world = World(dim: .overworld, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }
}
