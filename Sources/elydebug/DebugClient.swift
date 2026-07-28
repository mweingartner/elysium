import ElysiumDebugProtocol
import Foundation
import Network

final class ElysiumDebugClient {
    private static let receiveChunkBytes = 64 * 1024
    private static let maximumQueuedFrames = 4_096
    private static let maximumIgnoredEvents = 4_096
    private static let maximumHelloPayloadBytes = 64 * 1024

    private struct WaitDeadline {
        let uptimeNanoseconds: UInt64

        init(timeoutSeconds: Double) throws {
            let delta = UInt64(timeoutSeconds * 1_000_000_000)
            let (value, overflow) = DispatchTime.now().uptimeNanoseconds.addingReportingOverflow(delta)
            guard !overflow, value > 0 else {
                throw ElysiumDebugCLIError.transport("timeout is out of range")
            }
            uptimeNanoseconds = value
        }

        init?(uptimeNanoseconds: UInt64?) {
            guard let uptimeNanoseconds, uptimeNanoseconds > 0 else { return nil }
            self.uptimeNanoseconds = uptimeNanoseconds
        }

        func wait(on semaphore: DispatchSemaphore, phase: String) throws {
            let result = semaphore.wait(timeout: DispatchTime(uptimeNanoseconds: uptimeNanoseconds))
            guard result == .success else {
                throw ElysiumDebugCLIError.transport("\(phase) timed out")
            }
        }
    }

    private struct ReceiveResult {
        let data: Data
        let isComplete: Bool
    }

    private let manifest: DebugSessionManifest
    private let timeoutSeconds: Double
    private let queue = DispatchQueue(label: "dev.elysium.elydebug.connection")
    private let connection: NWConnection

    private var encoder: DebugAuthenticatedFrameEncoder?
    private var decoder: DebugAuthenticatedFrameDecoder?
    private var queuedFrames: [DebugDecodedFrame] = []
    private var capabilities: DebugCapabilities?
    private var didAuthenticate = false

    init(manifest: DebugSessionManifest, timeoutSeconds: Double) throws {
        guard let port = NWEndpoint.Port(rawValue: manifest.port), port.rawValue > 0 else {
            throw ElysiumDebugCLIError.manifest("manifest contains an invalid debug port")
        }
        self.manifest = manifest
        self.timeoutSeconds = timeoutSeconds
        // Host is deliberately not configurable: the debug control plane is loopback-only.
        self.connection = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: port, using: .tcp)
    }

    func connectAndAuthenticate() throws -> DebugCapabilities {
        guard !didAuthenticate else {
            guard let capabilities else {
                throw ElysiumDebugCLIError.protocolFailure("authenticated session has no capabilities")
            }
            return capabilities
        }

        let deadline = try WaitDeadline(timeoutSeconds: timeoutSeconds)
        try startConnection(deadline: deadline)
        let challenge = try receiveExactly(
            DebugSessionKeyDerivation.challengeByteCount,
            deadline: deadline,
            phase: "server challenge"
        )
        let sessionKey = try DebugSessionKeyDerivation.deriveConnectionKey(
            token: manifest.token,
            serverChallenge: challenge,
            sessionID: manifest.sessionID,
            buildIdentifier: manifest.buildIdentifier
        )
        encoder = try DebugAuthenticatedFrameEncoder(
            sessionKey: sessionKey,
            direction: .clientToServer
        )
        decoder = try DebugAuthenticatedFrameDecoder(
            sessionKey: sessionKey,
            direction: .serverToClient
        )

        let hello = try DebugClientHello(
            sessionID: manifest.sessionID,
            buildIdentifier: manifest.buildIdentifier
        )
        try sendFrame(kind: .clientHello, payload: try encodeJSON(hello), deadline: deadline)

        let frame = try readFrame(deadline: deadline)
        guard frame.kind == .serverHello else {
            throw ElysiumDebugCLIError.protocolFailure("expected authenticated serverHello frame")
        }
        guard frame.payload.count <= Self.maximumHelloPayloadBytes else {
            throw ElysiumDebugCLIError.protocolFailure("serverHello exceeds 64 KiB")
        }
        try requireExactObjectKeys(
            in: frame.payload,
            expected: ["protocolVersion", "sessionID", "capabilities"],
            label: "serverHello"
        )
        let serverHello: DebugServerHello
        do {
            serverHello = try JSONDecoder().decode(DebugServerHello.self, from: frame.payload)
        } catch {
            throw ElysiumDebugCLIError.protocolFailure("invalid serverHello payload")
        }
        guard serverHello.protocolVersion == ElysiumDebugProtocolVersion.current else {
            throw ElysiumDebugCLIError.protocolFailure("serverHello protocol version mismatch")
        }
        guard serverHello.sessionID == manifest.sessionID else {
            throw ElysiumDebugCLIError.protocolFailure("serverHello session identity mismatch")
        }

        capabilities = serverHello.capabilities
        didAuthenticate = true
        return serverHello.capabilities
    }

    func send(request: DebugRequest) throws -> DebugResponse {
        guard didAuthenticate, let capabilities else {
            throw ElysiumDebugCLIError.protocolFailure("debug connection is not authenticated")
        }
        guard !request.isExpired(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) else {
            throw ElysiumDebugCLIError.protocolFailure("request deadline already expired")
        }

        let payload = try encodeJSON(request)
        guard payload.count <= capabilities.maximumRequestPayloadBytes else {
            throw ElysiumDebugCLIError.protocolFailure(
                "request exceeds negotiated maximum payload of \(capabilities.maximumRequestPayloadBytes) bytes"
            )
        }
        let localDeadline = try WaitDeadline(timeoutSeconds: timeoutSeconds)
        guard let deadline = WaitDeadline(
            uptimeNanoseconds: min(
                request.deadlineUptimeNanoseconds ?? localDeadline.uptimeNanoseconds,
                localDeadline.uptimeNanoseconds
            )
        ) else {
            throw ElysiumDebugCLIError.protocolFailure("request deadline is invalid")
        }
        try sendFrame(kind: .request, payload: payload, deadline: deadline)

        var ignoredEvents = 0
        let eventLimit = min(Self.maximumIgnoredEvents, capabilities.maximumEventReplayCount)
        while true {
            let frame = try readFrame(deadline: deadline)
            switch frame.kind {
            case .response:
                let response: DebugResponse
                do {
                    response = try JSONDecoder().decode(DebugResponse.self, from: frame.payload)
                } catch {
                    throw ElysiumDebugCLIError.protocolFailure("invalid response payload")
                }
                guard response.requestID == request.id else {
                    throw ElysiumDebugCLIError.protocolFailure("response request identity mismatch")
                }
                return response
            case .event:
                do {
                    _ = try JSONDecoder().decode(DebugEvent.self, from: frame.payload)
                } catch {
                    throw ElysiumDebugCLIError.protocolFailure("invalid event payload")
                }
                ignoredEvents += 1
                guard ignoredEvents <= eventLimit else {
                    throw ElysiumDebugCLIError.protocolFailure("too many events before response")
                }
            case .close:
                throw ElysiumDebugCLIError.protocolFailure("server closed the debug session")
            case .clientHello, .serverHello, .request:
                throw ElysiumDebugCLIError.protocolFailure("unexpected frame while awaiting response")
            }
        }
    }

    func close() {
        connection.cancel()
    }

    private func startConnection(deadline: WaitDeadline) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>?
        var completed = false
        connection.stateUpdateHandler = { state in
            guard !completed else { return }
            switch state {
            case .ready:
                completed = true
                result = .success(())
                semaphore.signal()
            case .failed(let error):
                completed = true
                result = .failure(error)
                semaphore.signal()
            case .cancelled:
                completed = true
                result = .failure(ElysiumDebugCLIError.transport("connection was cancelled"))
                semaphore.signal()
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
        do {
            try deadline.wait(on: semaphore, phase: "connection")
        } catch {
            connection.cancel()
            throw error
        }
        switch result {
        case .success?:
            return
        case .failure(let error)?:
            throw ElysiumDebugCLIError.transport(Self.safeNetworkDescription(error))
        case nil:
            throw ElysiumDebugCLIError.transport("connection ended without a result")
        }
    }

    private func receiveExactly(
        _ expectedBytes: Int,
        deadline: WaitDeadline,
        phase: String
    ) throws -> Data {
        var result = Data()
        result.reserveCapacity(expectedBytes)
        while result.count < expectedBytes {
            let remaining = expectedBytes - result.count
            let received = try receive(
                minimumIncompleteLength: remaining,
                maximumLength: remaining,
                deadline: deadline,
                phase: phase
            )
            guard !received.data.isEmpty else {
                throw ElysiumDebugCLIError.transport("connection closed during \(phase)")
            }
            result.append(received.data)
            if received.isComplete {
                throw ElysiumDebugCLIError.transport("connection closed during \(phase)")
            }
        }
        guard result.count == expectedBytes else {
            throw ElysiumDebugCLIError.protocolFailure("invalid \(phase) length")
        }
        return result
    }

    private func sendFrame(
        kind: DebugFrameKind,
        payload: Data,
        deadline: WaitDeadline
    ) throws {
        guard var currentEncoder = encoder else {
            throw ElysiumDebugCLIError.protocolFailure("frame encoder is unavailable")
        }
        let frame: Data
        do {
            frame = try currentEncoder.encode(kind: kind, payload: payload)
        } catch {
            throw ElysiumDebugCLIError.protocolFailure(Self.safeProtocolDescription(error))
        }
        encoder = currentEncoder

        let semaphore = DispatchSemaphore(value: 0)
        var sendError: NWError?
        connection.send(content: frame, completion: .contentProcessed { error in
            sendError = error
            semaphore.signal()
        })
        try deadline.wait(on: semaphore, phase: "send")
        if let sendError {
            throw ElysiumDebugCLIError.transport(Self.safeNetworkDescription(sendError))
        }
    }

    private func readFrame(deadline: WaitDeadline) throws -> DebugDecodedFrame {
        if !queuedFrames.isEmpty {
            return queuedFrames.removeFirst()
        }
        while true {
            let received = try receive(
                minimumIncompleteLength: 1,
                maximumLength: Self.receiveChunkBytes,
                deadline: deadline,
                phase: "receive"
            )
            guard var currentDecoder = decoder else {
                throw ElysiumDebugCLIError.protocolFailure("frame decoder is unavailable")
            }
            let frames: [DebugDecodedFrame]
            do {
                frames = try currentDecoder.append(received.data)
                if received.isComplete {
                    try currentDecoder.finish()
                }
            } catch {
                throw ElysiumDebugCLIError.protocolFailure(Self.safeProtocolDescription(error))
            }
            decoder = currentDecoder
            guard queuedFrames.count + frames.count <= Self.maximumQueuedFrames else {
                throw ElysiumDebugCLIError.protocolFailure("too many queued frames")
            }
            queuedFrames.append(contentsOf: frames)
            if !queuedFrames.isEmpty {
                return queuedFrames.removeFirst()
            }
            if received.isComplete {
                throw ElysiumDebugCLIError.transport("server closed the connection")
            }
            if received.data.isEmpty {
                throw ElysiumDebugCLIError.transport("server returned no data")
            }
        }
    }

    private func receive(
        minimumIncompleteLength: Int,
        maximumLength: Int,
        deadline: WaitDeadline,
        phase: String
    ) throws -> ReceiveResult {
        let semaphore = DispatchSemaphore(value: 0)
        var data = Data()
        var isComplete = false
        var receiveError: NWError?
        connection.receive(
            minimumIncompleteLength: minimumIncompleteLength,
            maximumLength: maximumLength
        ) { content, _, complete, error in
            if let content { data = content }
            isComplete = complete
            receiveError = error
            semaphore.signal()
        }
        try deadline.wait(on: semaphore, phase: phase)
        if let receiveError {
            throw ElysiumDebugCLIError.transport(Self.safeNetworkDescription(receiveError))
        }
        guard data.count <= maximumLength else {
            throw ElysiumDebugCLIError.protocolFailure("network receive exceeded its bound")
        }
        return ReceiveResult(data: data, isComplete: isComplete)
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw ElysiumDebugCLIError.protocolFailure("could not encode protocol JSON")
        }
    }

    private func requireExactObjectKeys(
        in data: Data,
        expected: Set<String>,
        label: String
    ) throws {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw ElysiumDebugCLIError.protocolFailure("invalid \(label) JSON")
        }
        guard let dictionary = object as? [String: Any], Set(dictionary.keys) == expected else {
            throw ElysiumDebugCLIError.protocolFailure("invalid \(label) object shape")
        }
    }

    private static func safeNetworkDescription(_ error: Error) -> String {
        String(error.localizedDescription.prefix(512))
    }

    private static func safeProtocolDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription, !description.isEmpty {
            return String(description.prefix(512))
        }
        return String(String(describing: error).prefix(512))
    }
}
