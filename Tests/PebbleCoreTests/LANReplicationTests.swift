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
