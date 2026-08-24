import Foundation
import XCTest
@testable import ElysiumDebugProtocol

final class DebugMessageTests: XCTestCase {
    func testJSONValueAndRequestRoundTrip() throws {
        let arguments: [String: JSONValue] = [
            "enabled": .bool(true),
            "count": .integer(12),
            "ratio": .number(0.25),
            "name": .string("debug"),
            "list": .array([.null, .integer(-4)]),
            "object": .object(["nested": .string("value")]),
        ]
        let request = try DebugRequest(
            operation: "world.create",
            arguments: arguments,
            expectedEpoch: 4,
            expectedRevision: 19,
            deadlineUptimeNanoseconds: 99_000
        )
        let decoded = try JSONDecoder().decode(
            DebugRequest.self,
            from: JSONEncoder().encode(request)
        )
        XCTAssertEqual(decoded, request)
        XCTAssertFalse(request.isExpired(atUptimeNanoseconds: 98_999))
        XCTAssertTrue(request.isExpired(atUptimeNanoseconds: 99_000))
    }

    func testRequestRejectsInvalidOperationAndDecodedVersion() throws {
        XCTAssertThrowsError(try DebugRequest(operation: "World Create")) {
            XCTAssertEqual($0 as? DebugProtocolError, .invalidMessage("operation"))
        }
        XCTAssertThrowsError(try DebugRequest(operation: "world.create", deadlineUptimeNanoseconds: 0)) {
            XCTAssertEqual($0 as? DebugProtocolError, .invalidMessage("deadline"))
        }

        let json: [String: Any] = [
            "protocolVersion": 99,
            "id": UUID().uuidString,
            "operation": "session.ping",
            "arguments": [:],
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            DebugRequest.self,
            from: JSONSerialization.data(withJSONObject: json)
        )) {
            XCTAssertEqual($0 as? DebugProtocolError, .unsupportedProtocolVersion(99))
        }
    }

    func testSuccessAndFailureResponsesAreExclusive() throws {
        let id = UUID()
        let success = DebugResponse(
            requestID: id,
            result: ["pong": .bool(true)],
            epoch: 3,
            revision: 8,
            eventSequence: 21
        )
        XCTAssertTrue(success.isSuccess)
        XCTAssertEqual(
            try JSONDecoder().decode(DebugResponse.self, from: JSONEncoder().encode(success)),
            success
        )

        let failure = DebugResponse(
            requestID: id,
            error: DebugError(
                code: .wrongRevision,
                message: "stale request",
                details: ["observed": .integer(9)]
            ),
            epoch: 3,
            revision: 9
        )
        XCTAssertFalse(failure.isSuccess)
        XCTAssertEqual(
            try JSONDecoder().decode(DebugResponse.self, from: JSONEncoder().encode(failure)),
            failure
        )

        let neither: [String: Any] = [
            "protocolVersion": 1,
            "requestID": id.uuidString,
        ]
        XCTAssertThrowsError(try decodeResponse(neither))
        let both: [String: Any] = [
            "protocolVersion": 1,
            "requestID": id.uuidString,
            "result": [:],
            "error": [
                "code": "internalFailure",
                "message": "failed",
                "retryable": false,
                "details": [:],
            ],
        ]
        XCTAssertThrowsError(try decodeResponse(both))
    }

    func testCapabilitiesAreCanonicalAndExtensible() throws {
        let extensionCapability = DebugCapabilityID(rawValue: "extension.inspect")
        let capabilities = try DebugCapabilities(
            capabilities: [.worldLifecycle, extensionCapability, .readSnapshots]
        )
        XCTAssertEqual(
            capabilities.capabilities.map(\.rawValue),
            ["extension.inspect", "state.snapshot", "world.lifecycle"]
        )
        XCTAssertTrue(capabilities.supports(.readSnapshots))
        XCTAssertFalse(capabilities.supports(.rpgControl))
        XCTAssertEqual(
            try JSONDecoder().decode(DebugCapabilities.self, from: JSONEncoder().encode(capabilities)),
            capabilities
        )
        XCTAssertThrowsError(try DebugCapabilities(
            capabilities: [.readSnapshots, .readSnapshots]
        ))
    }

    /// scripting-ui-and-replication (change 3), design.md §12: `DebugControlRuntime`
    /// (`Sources/Elysium/DebugControlRuntime.swift`, debug build only — outside this
    /// target's dependency graph, so its `script.*` op logic is exercised through
    /// `ScriptingCommandsTests`/`ScriptRuntimeTests`'s existing coverage of the same
    /// `ScriptingCommands.run` executor those ops call) advertises `.scriptControl`
    /// alongside every other family — this pins the identifier and its negotiation
    /// round-trip the same way `testCapabilitiesAreCanonicalAndExtensible` pins
    /// `.rpgControl`.
    func testScriptControlCapabilityRoundTrips() throws {
        XCTAssertEqual(DebugCapabilityID.scriptControl.rawValue, "script.control")
        let capabilities = try DebugCapabilities(capabilities: [.scriptControl, .worldLifecycle])
        XCTAssertTrue(capabilities.supports(.scriptControl))
        XCTAssertEqual(
            try JSONDecoder().decode(DebugCapabilities.self, from: JSONEncoder().encode(capabilities)),
            capabilities
        )
    }

    func testHandshakeMessagesShareABoundedSchema() throws {
        let sessionID = UUID()
        let client = try DebugClientHello(
            sessionID: sessionID,
            buildIdentifier: "elysium-debug-build-1"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(DebugClientHello.self, from: JSONEncoder().encode(client)),
            client
        )

        let capabilities = try DebugCapabilities(
            capabilities: [.readSnapshots, .subscribeEvents]
        )
        let server = try DebugServerHello(
            sessionID: sessionID,
            capabilities: capabilities
        )
        XCTAssertEqual(
            try JSONDecoder().decode(DebugServerHello.self, from: JSONEncoder().encode(server)),
            server
        )

        for invalid in ["", "contains\nnewline", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try DebugClientHello(
                sessionID: sessionID,
                buildIdentifier: invalid
            )) {
                XCTAssertEqual($0 as? DebugProtocolError, .invalidMessage("build identifier"))
            }
        }
        XCTAssertThrowsError(try DebugClientHello(
            protocolVersion: 2,
            sessionID: sessionID,
            buildIdentifier: "build"
        )) {
            XCTAssertEqual($0 as? DebugProtocolError, .unsupportedProtocolVersion(2))
        }
        XCTAssertThrowsError(try DebugServerHello(
            protocolVersion: 2,
            sessionID: sessionID,
            capabilities: capabilities
        )) {
            XCTAssertEqual($0 as? DebugProtocolError, .unsupportedProtocolVersion(2))
        }
    }

    func testSnapshotModelsRoundTrip() throws {
        let identity = DebugSnapshotIdentity(
            sessionID: UUID(),
            epoch: 2,
            revision: 30,
            eventSequence: 44,
            simulationTick: 900,
            dimensionID: "overworld",
            screenGeneration: 6,
            registryGeneration: 1
        )
        let snapshot = DebugSnapshot(
            identity: identity,
            sections: [
                "player": .object(["mode": .string("creative")]),
                "world": .object(["time": .integer(6_000)]),
            ],
            truncatedScopes: [.entities],
            nextCursor: "revision-30/page-2"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(DebugSnapshot.self, from: JSONEncoder().encode(snapshot)),
            snapshot
        )
        let query = try DebugSnapshotQuery(scopes: [.world, .player], maximumItemsPerScope: 256)
        XCTAssertEqual(query.scopes, [.player, .world])
    }

    func testEventRoundTrip() throws {
        let event = try DebugEvent(
            name: "world.block.changed",
            sequence: 12,
            epoch: 2,
            revision: 31,
            simulationTick: 901,
            payload: ["block": .string("elysium:chest")]
        )
        XCTAssertEqual(
            try JSONDecoder().decode(DebugEvent.self, from: JSONEncoder().encode(event)),
            event
        )
    }

    private func decodeResponse(_ object: [String: Any]) throws -> DebugResponse {
        try JSONDecoder().decode(
            DebugResponse.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }
}
