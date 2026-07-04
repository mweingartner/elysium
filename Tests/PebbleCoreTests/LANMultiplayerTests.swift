import Foundation
import XCTest
@testable import PebbleCore

final class LANMultiplayerTests: XCTestCase {
    func testFrameCodecRoundTripsAllHandshakeAndGameplayMessageKinds() throws {
        let world = LANWorldSummary(
            worldID: "world-1",
            worldName: "LAN World",
            seed: 12345,
            gameMode: GameMode.survival,
            difficulty: 2,
            dimension: Dim.overworld.rawValue,
            playerCount: 2
        )
        let player = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 1.25,
            y: 65,
            z: -9.5,
            yaw: 0.3,
            pitch: -0.1,
            health: 19,
            hunger: 18,
            selectedHotbarSlot: 4,
            gameMode: GameMode.creative,
            dimension: Dim.nether.rawValue
        )
        let event = LANGameplayEvent(playerID: "peer-a", kind: .peerReconnected, message: "Alex reconnected", tick: 8)
        let messages: [LANMultiplayerMessage] = [
            .clientHello(playerID: "peer-a", playerName: "Alex", joinCode: "ABCD42", pebbleVersion: PEBBLE_VERSION),
            .serverAccept(peerID: "peer-a", world: world),
            .serverReject(reason: "bad join code"),
            .chat(sender: "Alex", text: "hello"),
            .playerState(player),
            .worldSummary(world),
            .ping(nonce: 42),
            .pong(nonce: 42),
            .disconnect(reason: "bye"),
            .inputIntent(
                playerID: "peer-a",
                intent: LANInputIntent(
                    forward: 1.5,
                    strafe: -1.5,
                    jump: true,
                    sneak: false,
                    sprint: true,
                    flyingUp: false,
                    flyingDown: false,
                    yaw: 0.4,
                    pitch: 2,
                    selectedHotbarSlot: 99
                )
            ),
            .blockIntent(playerID: "peer-a", intent: LANBlockIntent(action: .placeBlock, x: 1, y: 2, z: 3, face: 9, selectedHotbarSlot: -5)),
            .containerIntent(playerID: "peer-a", intent: LANContainerIntent(action: .clickSlot, containerID: "chest", slot: 5, button: 1, shift: true)),
            .templateIntent(playerID: "peer-a", intent: LANTemplateIntent(action: .placeTemplate, templateName: "A House!", x: 9, y: 64, z: -4, rotation: -1)),
            .replicationBatch(LANReplicationBatch(
                tick: 7,
                fullSnapshot: false,
                players: [player],
                blockChanges: [
                    LANBlockChange(dimension: Dim.overworld.rawValue, x: 1, y: 65, z: 1, cell: 0),
                ],
                blockEntities: [
                    LANBlockEntitySnapshot(
                        dimension: Dim.overworld.rawValue,
                        x: 2,
                        y: 65,
                        z: 2,
                        type: "container",
                        slotCount: 27,
                        slots: [LANBlockEntitySlotSnapshot(slot: 0, itemID: 1, count: 1)]
                    ),
                ]
            )),
            .chunkRequest(playerID: "peer-a", request: LANChunkRequest(dimension: Dim.overworld.rawValue, cx: 0, cz: 0, radius: 9)),
            .replicationAck(playerID: "peer-a", ack: LANReplicationAck(tick: 7, receivedSequence: 42)),
            .gameplayEvent(event),
            .attackIntent(playerID: "peer-a", intent: LANAttackIntent(targetEntityID: 12, selectedHotbarSlot: 3, sprinting: true)),
            .tossIntent(playerID: "peer-a", intent: LANTossIntent(slot: 4, count: 12, all: false)),
            .containerEditIntent(
                playerID: "peer-a",
                intent: LANContainerEditIntent(
                    blockEntity: LANBlockEntitySnapshot(
                        dimension: Dim.overworld.rawValue,
                        x: 3,
                        y: 65,
                        z: 3,
                        type: "container",
                        slotCount: 27,
                        slots: [LANBlockEntitySlotSnapshot(slot: 0, itemID: 2, count: 5)]
                    ),
                    inventory: LANPlayerInventorySnapshot(
                        playerID: "peer-a",
                        selectedHotbarSlot: 0,
                        slots: [LANInventorySlotSnapshot(slot: 0, itemID: 1, count: 1)]
                    ),
                    revision: 3,
                    editSeq: 9
                )
            ),
            .inventoryUpdate(LANInventoryUpdate(
                playerID: "peer-a",
                revision: 5,
                snapshot: LANPlayerInventorySnapshot(
                    playerID: "peer-a",
                    selectedHotbarSlot: 1,
                    slots: [LANInventorySlotSnapshot(slot: 1, itemID: 3, count: 10)]
                )
            )),
            .inventoryGrant(LANInventoryGrant(
                playerID: "peer-a",
                grantID: 2,
                items: [LANInventorySlotSnapshot(slot: 0, itemID: 4, count: 2)],
                xp: 10,
                clearAll: false
            )),
            .restoreState(LANRestoreState(
                playerState: player,
                inventory: LANPlayerInventorySnapshot(
                    playerID: "peer-a",
                    selectedHotbarSlot: 0,
                    slots: [LANInventorySlotSnapshot(slot: 0, itemID: 5, count: 1)]
                ),
                revision: 4,
                grantID: 1
            )),
            .damageEvent(LANDamageEvent(
                playerID: "peer-a",
                amount: 5.5,
                source: "zombie",
                knockbackX: 0.5,
                knockbackZ: -0.5,
                attackerType: "zombie"
            )),
            .keepalive,
        ]

        for (index, message) in messages.enumerated() {
            let encoded = try LANMultiplayerFrameCodec.encode(message, sequence: UInt32(index + 1))
            let decoded = try LANMultiplayerFrameCodec.decode(encoded)
            XCTAssertEqual(decoded.sequence, UInt32(index + 1))
            XCTAssertEqual(decoded.kind, message.kind)
            XCTAssertEqual(decoded.message, message)
        }
    }

    func testStreamingDecoderLeavesPartialFrameBuffered() throws {
        let first = try LANMultiplayerFrameCodec.encode(.ping(nonce: 1), sequence: 10)
        let second = try LANMultiplayerFrameCodec.encode(.pong(nonce: 1), sequence: 11)
        let cut = second.count / 2
        var buffer = Data()
        buffer.append(first)
        buffer.append(second.prefix(cut))

        let frames = try LANMultiplayerFrameCodec.decodeFrames(from: &buffer)

        XCTAssertEqual(frames, [LANMultiplayerFrame(sequence: 10, message: .ping(nonce: 1))])
        XCTAssertEqual(buffer, second.prefix(cut))

        buffer.append(second.dropFirst(cut))
        let rest = try LANMultiplayerFrameCodec.decodeFrames(from: &buffer)
        XCTAssertEqual(rest, [LANMultiplayerFrame(sequence: 11, message: .pong(nonce: 1))])
        XCTAssertTrue(buffer.isEmpty)
    }

    func testCodecRejectsBadMagicUnsupportedVersionUnknownTypeAndOversizedFrame() throws {
        let good = try LANMultiplayerFrameCodec.encode(.ping(nonce: 7))

        var badMagic = good
        badMagic[0] = 0
        XCTAssertThrowsError(try LANMultiplayerFrameCodec.decode(badMagic)) { error in
            XCTAssertEqual(error as? LANMultiplayerCodecError, .invalidMagic)
        }

        var badVersion = good
        badVersion[4] = 0
        badVersion[5] = 99
        XCTAssertThrowsError(try LANMultiplayerFrameCodec.decode(badVersion)) { error in
            XCTAssertEqual(error as? LANMultiplayerCodecError, .unsupportedVersion(99))
        }

        var badType = good
        badType[6] = 0xff
        badType[7] = 0xff
        XCTAssertThrowsError(try LANMultiplayerFrameCodec.decode(badType)) { error in
            XCTAssertEqual(error as? LANMultiplayerCodecError, .unknownMessageType(65_535))
        }

        var oversized = Data([0x50, 0x42, 0x4c, 0x4e, 0, 2, 0, 7, 0, 0, 0, 1])
        oversized.append(contentsOf: [0x00, 0x10, 0x00, 0x01])
        XCTAssertThrowsError(try LANMultiplayerFrameCodec.decode(oversized)) { error in
            XCTAssertEqual(error as? LANMultiplayerCodecError, .oversizedFrame(LAN_MULTIPLAYER_MAX_FRAME_BYTES + 1))
        }
    }

    func testValidationSanitizesUntrustedLANInputs() {
        XCTAssertEqual(sanitizedLANPlayerName("  Alex\nAdmin  "), "AlexAdmin")
        XCTAssertEqual(sanitizedLANPlayerName(""), "Player")
        XCTAssertEqual(normalizedLANJoinCode(" ab-cd 42! "), "ABCD42")
        XCTAssertTrue(isValidLANJoinCode("ABCD42"))
        XCTAssertFalse(isValidLANJoinCode("ABC"))
        XCTAssertFalse(isValidLANJoinCode("AB-CD"))
        XCTAssertEqual(sanitizedLANChatText("hello\nworld"), "helloworld")
        XCTAssertEqual(sanitizedLANTemplateName("A House!"), "A House")

        XCTAssertEqual(LANDirectConnectTarget.parse(host: "192.168.1.20", port: "41337"),
                       LANDirectConnectTarget(host: "192.168.1.20", port: LAN_MULTIPLAYER_DEFAULT_PORT))
        XCTAssertNil(LANDirectConnectTarget.parse(host: "bad host", port: "41337"))
        XCTAssertNil(LANDirectConnectTarget.parse(host: "localhost", port: "0"))

        XCTAssertEqual(
            LANAutoJoinSpec.parse("192.168.1.20 41337 abcd42 Neo Probe"),
            LANAutoJoinSpec(
                target: LANDirectConnectTarget(host: "192.168.1.20", port: LAN_MULTIPLAYER_DEFAULT_PORT),
                joinCode: "ABCD42",
                playerName: "Neo Probe"
            )
        )
        XCTAssertNil(LANAutoJoinSpec.parse("192.168.1.20 41337 bad"))
        XCTAssertNil(LANAutoJoinSpec.parse("bad host 41337 ABCD42 Neo"))
    }

    func testBlockIntentDecodesMissingPlacementCellAsZeroForCompatibility() throws {
        let data = """
        {"action":"placeBlock","x":1,"y":2,"z":3,"face":1,"selectedHotbarSlot":0}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LANBlockIntent.self, from: data)

        XCTAssertEqual(decoded, LANBlockIntent(action: .placeBlock, x: 1, y: 2, z: 3, face: 1, selectedHotbarSlot: 0))
    }

    func testPlayerStateDecodesLegacyPayloadWithDefaultDimensionAndAliveLifecycle() throws {
        let data = """
        {"playerID":"peer-a","displayName":"Alex","x":1,"y":65,"z":2,"yaw":0,"pitch":0,"health":20,"hunger":18,"selectedHotbarSlot":3,"gameMode":0}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LANPlayerState.self, from: data)

        XCTAssertEqual(decoded.dimension, Dim.overworld.rawValue)
        XCTAssertFalse(decoded.dead)
    }

    func testInfoPlistDeclaresLocalNetworkPrivacyAndBonjourService() throws {
        let plistURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("packaging/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try XCTUnwrap(plist as? [String: Any])

        let privacy = try XCTUnwrap(dict["NSLocalNetworkUsageDescription"] as? String)
        XCTAssertFalse(privacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let services = try XCTUnwrap(dict["NSBonjourServices"] as? [String])
        XCTAssertTrue(services.contains(LAN_MULTIPLAYER_SERVICE_TYPE))
    }

    func testLANClientWorldEntryUsesSummaryAndSkipsSingleplayerPersistence() {
        let game = GameCore()
        let before = Set(game.listWorlds().map(\.id))
        let summary = LANWorldSummary(
            worldID: "host world !",
            worldName: "Host LAN",
            seed: -123_456,
            gameMode: GameMode.creative,
            difficulty: 3,
            dimension: Dim.overworld.rawValue,
            playerCount: 2
        )

        game.enterLANClientWorld(summary)

        XCTAssertTrue(game.hasWorld())
        XCTAssertTrue(game.isLANClientWorld)
        XCTAssertGreaterThan(game.player.y, Double(game.world.info.minY + 32))
        XCTAssertEqual(game.worldRec?.id, "lan-hostworld")
        XCTAssertEqual(game.worldRec?.name, "LAN: Host LAN")
        XCTAssertEqual(game.worldRec?.seed, Int32(-123_456))
        XCTAssertEqual(game.worldRec?.gameMode, GameMode.creative)
        XCTAssertEqual(game.worldRec?.difficulty, 3)

        game.saveAndFlush(synchronous: true)
        XCTAssertEqual(Set(game.listWorlds().map(\.id)), before)

        game.exitToTitle()
        XCTAssertFalse(game.hasWorld())
        XCTAssertFalse(game.isLANClientWorld)
        XCTAssertEqual(Set(game.listWorlds().map(\.id)), before)
    }

    func testLANClientResumeLocationPersistsPerHostedWorldWithoutSavingHostWorld() throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pebble-lan-resume-\(UUID().uuidString).db")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
        }
        let db = SaveDB(databaseURL: dbURL, migrateLegacy: false)
        let summary = LANWorldSummary(
            worldID: "host world !",
            worldName: "Host LAN",
            seed: -123_456,
            gameMode: GameMode.survival,
            difficulty: 2,
            dimension: Dim.overworld.rawValue,
            playerCount: 2
        )

        let first = GameCore(db: db)
        let before = Set(first.listWorlds().map(\.id))
        first.enterLANClientWorld(summary)
        first.player.setPos(123.25, 91.5, -45.75)
        first.player.yaw = 1.25
        first.player.pitch = -0.35
        first.saveAndFlush(synchronous: true)
        first.exitToTitle()

        XCTAssertEqual(Set(first.listWorlds().map(\.id)), before)

        let second = GameCore(db: db)
        second.enterLANClientWorld(summary)

        XCTAssertTrue(second.isLANClientWorld)
        XCTAssertEqual(second.player.x, 123.25, accuracy: 0.001)
        XCTAssertEqual(second.player.y, 91.5, accuracy: 0.001)
        XCTAssertEqual(second.player.z, -45.75, accuracy: 0.001)
        XCTAssertEqual(second.player.yaw, 1.25, accuracy: 0.001)
        XCTAssertEqual(second.player.pitch, -0.35, accuracy: 0.001)
        XCTAssertEqual(Set(second.listWorlds().map(\.id)), before)
    }

    func testLANClientWorldRequestsHostChunksInsteadOfGeneratingLocalChunks() {
        let game = GameCore()
        var requested: [(Int, Int, Int)] = []
        game.lanChunkRequestHandler = { world, cx, cz in
            requested.append((world.dim.rawValue, cx, cz))
            return true
        }
        let summary = LANWorldSummary(
            worldID: "host world !",
            worldName: "Host LAN",
            seed: -123_456,
            gameMode: GameMode.survival,
            difficulty: 2,
            dimension: Dim.overworld.rawValue,
            playerCount: 2
        )

        game.enterLANClientWorld(summary)

        XCTAssertTrue(game.isLANClientWorld)
        XCTAssertFalse(requested.isEmpty)
        XCTAssertEqual(requested.count, 1)
        XCTAssertEqual(requested.first?.1, floorDiv(ifloor(game.player.x), CHUNK_W))
        XCTAssertEqual(requested.first?.2, floorDiv(ifloor(game.player.z), CHUNK_W))
        XCTAssertTrue(requested.allSatisfy { $0.0 == Dim.overworld.rawValue })
        XCTAssertTrue(game.world.chunks.isEmpty)
    }

    // MARK: - RLE chunk-section cells

    /// Ensures `blockDefs` (and therefore `isValidLANReplicatedCell`) is populated before any test
    /// asserts on `isValidRLE`, independent of test execution order.
    private static let blockRegistryBootstrap: Void = { _ = GameCore() }()

    private func seededCells(_ seed: UInt32, valueBound: Int = 4096) -> [UInt16] {
        var rng = RandomX(seed)
        var out: [UInt16] = []
        out.reserveCapacity(LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
        for _ in 0..<LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT {
            out.append(UInt16(rng.nextInt(valueBound)))
        }
        return out
    }

    /// Seeded cells whose block id portion (`cell >> 4`) is always a registered block, so
    /// `isValidLANReplicatedCell` accepts every cell regardless of registry size.
    private func seededValidReplicatedCells(_ seed: UInt32) -> [UInt16] {
        _ = Self.blockRegistryBootstrap
        var rng = RandomX(seed)
        var out: [UInt16] = []
        out.reserveCapacity(LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
        let idBound = max(1, blockDefs.count)
        for _ in 0..<LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT {
            let id = rng.nextInt(idBound)
            let meta = rng.nextInt(16)
            out.append(UInt16(id << 4 | meta))
        }
        return out
    }

    func testRLERoundTripsAllAirAllOneValueAndAlternatingWorstCase() {
        let allAir = [UInt16](repeating: 0, count: LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
        let allAirEncoded = lanEncodeChunkSectionRLE(allAir)
        XCTAssertEqual(lanDecodeChunkSectionRLE(allAirEncoded), allAir)
        XCTAssertLessThanOrEqual(allAirEncoded.count, LAN_MULTIPLAYER_MAX_CELLS_DATA_BYTES)

        let allOne = [UInt16](repeating: 42, count: LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
        let allOneEncoded = lanEncodeChunkSectionRLE(allOne)
        XCTAssertEqual(lanDecodeChunkSectionRLE(allOneEncoded), allOne)
        XCTAssertLessThanOrEqual(allOneEncoded.count, LAN_MULTIPLAYER_MAX_CELLS_DATA_BYTES)

        var alternating: [UInt16] = []
        alternating.reserveCapacity(LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT)
        for i in 0..<LAN_MULTIPLAYER_CHUNK_SECTION_CELL_COUNT {
            alternating.append(i % 2 == 0 ? 1 : 2)
        }
        let alternatingEncoded = lanEncodeChunkSectionRLE(alternating)
        XCTAssertEqual(lanDecodeChunkSectionRLE(alternatingEncoded), alternating)
        XCTAssertLessThanOrEqual(alternatingEncoded.count, LAN_MULTIPLAYER_MAX_CELLS_DATA_BYTES)
    }

    func testRLERoundTripsTwoHundredSeededRandomCellArraysWithinCap() {
        for seed in 0..<200 {
            let cells = seededCells(UInt32(seed) &+ 0x1000)
            let encoded = lanEncodeChunkSectionRLE(cells)
            XCTAssertLessThanOrEqual(encoded.count, LAN_MULTIPLAYER_MAX_CELLS_DATA_BYTES, "seed \(seed)")
            XCTAssertEqual(lanDecodeChunkSectionRLE(encoded), cells, "seed \(seed) failed round trip")
        }
    }

    func testRLEDecodeNeverTrapsAndReturnsNilForMalformedBuffers() {
        // Truncated (not a multiple of 4).
        XCTAssertNil(lanDecodeChunkSectionRLE(Data([0x00, 0x01, 0x00])))
        // Odd length.
        XCTAssertNil(lanDecodeChunkSectionRLE(Data([0x00])))
        // Empty.
        XCTAssertNil(lanDecodeChunkSectionRLE(Data()))
        // Zero-count run.
        XCTAssertNil(lanDecodeChunkSectionRLE(Data([0x00, 0x00, 0x00, 0x01])))
        // Over-cap byte count (one byte over the max, still a multiple of 4).
        let overCap = Data(repeating: 0xff, count: LAN_MULTIPLAYER_MAX_CELLS_DATA_BYTES + 4)
        XCTAssertNil(lanDecodeChunkSectionRLE(overCap))
        // Well-formed runs whose total != 4096 (single run claiming only half the section).
        var shortTotal = Data()
        shortTotal.append(contentsOf: [0x08, 0x00, 0x00, 0x01]) // count 2048, cell 1
        XCTAssertNil(lanDecodeChunkSectionRLE(shortTotal))

        // 200 seeded arbitrary random Data blobs (valid-length but adversarial content) must never trap.
        for seed in 0..<200 {
            var rng = RandomX(UInt32(seed) &+ 0x9000)
            let byteCount = (rng.nextInt(300)) * 4
            var bytes = [UInt8]()
            bytes.reserveCapacity(byteCount)
            for _ in 0..<byteCount {
                bytes.append(UInt8(rng.nextInt(256)))
            }
            _ = lanDecodeChunkSectionRLE(Data(bytes)) // must not trap regardless of result
        }

        // Odd-length arbitrary fuzz bytes must also never trap and must return nil.
        for seed in 0..<50 {
            var rng = RandomX(UInt32(seed) &+ 0xA000)
            let byteCount = rng.nextInt(300) * 4 + 1
            var bytes = [UInt8]()
            bytes.reserveCapacity(byteCount)
            for _ in 0..<byteCount {
                bytes.append(UInt8(rng.nextInt(256)))
            }
            XCTAssertNil(lanDecodeChunkSectionRLE(Data(bytes)))
        }
    }

    func testChunkSectionSnapshotCellsRoundTripsThroughInitAndIsValidRLE() {
        let cells = seededValidReplicatedCells(0x2222)
        let snapshot = LANChunkSectionSnapshot(dimension: Dim.overworld.rawValue, cx: 1, cz: -2, sectionY: 3, minY: 48, cells: cells)

        XCTAssertEqual(snapshot.cells, cells)
        XCTAssertTrue(snapshot.hasExpectedCellCount)
        XCTAssertTrue(snapshot.isValidRLE)

        let malformed = LANChunkSectionSnapshot(dimension: Dim.overworld.rawValue, cx: 0, cz: 0, sectionY: 0, minY: 0, cells: [])
        XCTAssertFalse(malformed.isValidRLE)
        XCTAssertEqual(malformed.cells, [])
    }

    func testChunkSectionSnapshotFrameRoundTripPreservesCellsThroughJSONBase64() throws {
        let cells = seededValidReplicatedCells(0x3333)
        let snapshot = LANChunkSectionSnapshot(dimension: Dim.overworld.rawValue, cx: 4, cz: 5, sectionY: 1, minY: 16, cells: cells)
        let batch = LANReplicationBatch(tick: 1, fullSnapshot: true, chunkSections: [snapshot])
        let message = LANMultiplayerMessage.replicationBatch(batch)

        let framed = try LANMultiplayerFrameCodec.encode(message, sequence: 1)
        let decoded = try LANMultiplayerFrameCodec.decode(framed)

        guard case .replicationBatch(let decodedBatch) = decoded.message else {
            return XCTFail("expected replicationBatch")
        }
        XCTAssertEqual(decodedBatch.chunkSections.first?.cells, cells)
        XCTAssertTrue(decodedBatch.isWithinReplicationCaps)
    }

    func testIsWithinReplicationCapsRejectsInvalidRLEChunkSection() {
        let malformed = LANChunkSectionSnapshot(dimension: Dim.overworld.rawValue, cx: 0, cz: 0, sectionY: 0, minY: 0, cells: [1, 2, 3])
        let batch = LANReplicationBatch(tick: 1, fullSnapshot: true, chunkSections: [malformed])
        XCTAssertFalse(batch.isWithinReplicationCaps)
    }

    // MARK: - Encode-once codec equivalence

    func testEncodePayloadThenFrameProducesByteIdenticalOutputToEncode() throws {
        let messages: [LANMultiplayerMessage] = [
            .ping(nonce: 99),
            .chat(sender: "Alex", text: "hi there"),
            .attackIntent(playerID: "peer-a", intent: LANAttackIntent(targetEntityID: 3, selectedHotbarSlot: 1, sprinting: false)),
            .damageEvent(LANDamageEvent(playerID: "peer-a", amount: 3, source: "fall", knockbackX: 0, knockbackZ: 0)),
            .keepalive,
        ]
        for (index, message) in messages.enumerated() {
            for sequence: UInt32 in [0, 1, 999, UInt32(index)] {
                let viaEncode = try LANMultiplayerFrameCodec.encode(message, sequence: sequence)
                let (kind, payload) = try LANMultiplayerFrameCodec.encodePayload(message)
                let viaFrame = LANMultiplayerFrameCodec.frame(kind: kind, payload: payload, sequence: sequence)
                XCTAssertEqual(viaEncode, viaFrame)
            }
        }
    }

    // MARK: - v1 frame rejection

    func testV1FrameIsRejectedAsUnsupportedVersion() throws {
        var frame = try LANMultiplayerFrameCodec.encode(.ping(nonce: 1), sequence: 1)
        // Byte offset 5 is the low byte of the big-endian UInt16 protocol version.
        frame[5] = 1
        XCTAssertThrowsError(try LANMultiplayerFrameCodec.decode(frame)) { error in
            XCTAssertEqual(error as? LANMultiplayerCodecError, .unsupportedVersion(1))
        }
    }

    // MARK: - Bounds tests for new payload structs

    func testAttackIntentClampsHotbarSlotAndTargetID() {
        let intent = LANAttackIntent(targetEntityID: -5, selectedHotbarSlot: 99, sprinting: true)
        XCTAssertEqual(intent.targetEntityID, 0)
        XCTAssertEqual(intent.selectedHotbarSlot, 8)
    }

    func testTossIntentClampsSlotAndCount() {
        let intent = LANTossIntent(slot: 999, count: 0, all: true)
        XCTAssertEqual(intent.slot, 35)
        XCTAssertEqual(intent.count, 1)

        let overCount = LANTossIntent(slot: 0, count: 9999, all: false)
        XCTAssertEqual(overCount.count, LAN_MULTIPLAYER_MAX_REPLICATED_ITEM_COUNT)
    }

    func testContainerEditIntentClampsRevisionAndEditSeq() {
        let intent = LANContainerEditIntent(
            blockEntity: LANBlockEntitySnapshot(
                dimension: Dim.overworld.rawValue,
                x: 0, y: 0, z: 0,
                type: "container",
                slotCount: 1,
                slots: []
            ),
            inventory: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: []),
            revision: -4,
            editSeq: -1
        )
        XCTAssertEqual(intent.revision, 0)
        XCTAssertEqual(intent.editSeq, 0)
    }

    func testInventoryUpdateClampsNegativeRevision() {
        let update = LANInventoryUpdate(
            playerID: "peer-a",
            revision: -10,
            snapshot: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: [])
        )
        XCTAssertEqual(update.revision, 0)
    }

    func testInventoryGrantRejectsOverCapItemsAndClampsFields() {
        let overCapItems = (0..<200).map { LANInventorySlotSnapshot(slot: $0 % 36, itemID: 1, count: 1) }
        let grant = LANInventoryGrant(playerID: "peer-a", grantID: -3, items: overCapItems, xp: -5, clearAll: true)

        XCTAssertEqual(grant.items.count, LAN_MULTIPLAYER_MAX_GRANT_ITEMS)
        XCTAssertEqual(grant.grantID, 0)
        XCTAssertEqual(grant.xp, 0)
        XCTAssertTrue(grant.clearAll)
    }

    func testDamageEventClampsAmountToCapAndSanitizesSource() {
        let overCap = LANDamageEvent(
            playerID: "peer-a",
            amount: 999_999,
            source: "zombie\nattack",
            knockbackX: 999,
            knockbackZ: -999
        )
        XCTAssertEqual(overCap.amount, LAN_MULTIPLAYER_MAX_DAMAGE_AMOUNT)
        XCTAssertEqual(overCap.source, "zombieattack")
        XCTAssertEqual(overCap.knockbackX, 64)
        XCTAssertEqual(overCap.knockbackZ, -64)

        let nonFinite = LANDamageEvent(playerID: "peer-a", amount: .infinity, source: "x", knockbackX: .nan, knockbackZ: .nan)
        XCTAssertEqual(nonFinite.amount, 0)
        XCTAssertEqual(nonFinite.knockbackX, 0)
        XCTAssertEqual(nonFinite.knockbackZ, 0)

        let negative = LANDamageEvent(playerID: "peer-a", amount: -5, source: "x", knockbackX: 0, knockbackZ: 0)
        XCTAssertEqual(negative.amount, 0)
    }

    func testRestoreStateClampsRevisionAndGrantID() {
        let restore = LANRestoreState(
            playerState: LANPlayerState(
                playerID: "peer-a",
                displayName: "Alex",
                x: 0, y: 64, z: 0,
                yaw: 0, pitch: 0,
                health: 20, hunger: 20,
                selectedHotbarSlot: 0,
                gameMode: GameMode.survival
            ),
            inventory: LANPlayerInventorySnapshot(playerID: "peer-a", selectedHotbarSlot: 0, slots: []),
            revision: -1,
            grantID: -1
        )
        XCTAssertEqual(restore.revision, 0)
        XCTAssertEqual(restore.grantID, 0)
    }

    func testPlayerStateInventoryRevisionDefaultsToZeroAndDecodesTolerantly() throws {
        let state = LANPlayerState(
            playerID: "peer-a",
            displayName: "Alex",
            x: 0, y: 64, z: 0,
            yaw: 0, pitch: 0,
            health: 20, hunger: 20,
            selectedHotbarSlot: 0,
            gameMode: GameMode.survival
        )
        XCTAssertEqual(state.inventoryRevision, 0)

        let legacyJSON = """
        {"playerID":"peer-a","displayName":"Alex","x":1,"y":65,"z":2,"yaw":0,"pitch":0,"health":20,"hunger":18,"selectedHotbarSlot":3,"gameMode":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LANPlayerState.self, from: legacyJSON)
        XCTAssertEqual(decoded.inventoryRevision, 0)
    }

    func testEntitySnapshotSanitizesVelocityAndDecodesNewFieldsTolerantly() throws {
        let snapshot = LANEntitySnapshot(
            entityID: 1,
            type: "zombie",
            x: 0, y: 64, z: 0,
            yaw: 0, pitch: 0,
            health: 20,
            dead: false,
            vx: .infinity,
            vy: 999,
            vz: -999,
            onGround: true,
            fire: true,
            dimension: Dim.nether.rawValue
        )
        XCTAssertEqual(snapshot.vx, 0)
        XCTAssertEqual(snapshot.vy, 64)
        XCTAssertEqual(snapshot.vz, -64)
        XCTAssertTrue(snapshot.onGround)
        XCTAssertTrue(snapshot.fire)
        XCTAssertEqual(snapshot.dimension, Dim.nether.rawValue)

        let legacyJSON = """
        {"entityID":2,"type":"cow","x":0,"y":64,"z":0,"yaw":0,"pitch":0,"dead":false}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LANEntitySnapshot.self, from: legacyJSON)
        XCTAssertEqual(decoded.vx, 0)
        XCTAssertEqual(decoded.vy, 0)
        XCTAssertEqual(decoded.vz, 0)
        XCTAssertFalse(decoded.onGround)
        XCTAssertFalse(decoded.fire)
        XCTAssertEqual(decoded.dimension, Dim.overworld.rawValue)

        let invalidDimensionJSON = """
        {"entityID":3,"type":"cow","x":0,"y":64,"z":0,"yaw":0,"pitch":0,"dead":false,"dimension":999}
        """.data(using: .utf8)!
        let decodedInvalidDim = try JSONDecoder().decode(LANEntitySnapshot.self, from: invalidDimensionJSON)
        XCTAssertEqual(decodedInvalidDim.dimension, Dim.overworld.rawValue)
    }
}
