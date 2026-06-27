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
            gameMode: GameMode.creative
        )
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
            .replicationBatch(LANReplicationBatch(tick: 7, fullSnapshot: false, players: [player], blockChanges: [
                LANBlockChange(dimension: Dim.overworld.rawValue, x: 1, y: 65, z: 1, cell: 0),
            ])),
            .chunkRequest(playerID: "peer-a", request: LANChunkRequest(dimension: Dim.overworld.rawValue, cx: 0, cz: 0, radius: 9)),
            .replicationAck(playerID: "peer-a", ack: LANReplicationAck(tick: 7, receivedSequence: 42)),
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

        var oversized = Data([0x50, 0x42, 0x4c, 0x4e, 0, 1, 0, 7, 0, 0, 0, 1])
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
    }

    func testBlockIntentDecodesMissingPlacementCellAsZeroForCompatibility() throws {
        let data = """
        {"action":"placeBlock","x":1,"y":2,"z":3,"face":1,"selectedHotbarSlot":0}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(LANBlockIntent.self, from: data)

        XCTAssertEqual(decoded, LANBlockIntent(action: .placeBlock, x: 1, y: 2, z: 3, face: 1, selectedHotbarSlot: 0))
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
}
