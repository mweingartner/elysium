#if ELYSIUM_DEBUG_CONTROL
import CryptoKit
import Darwin
import Foundation
import Network
import ElysiumDebugProtocol

/// Exact marker required in Debug.app and forbidden in the production executable/package.
let elysiumDebugControlBuildMarkerV1 = "elysium_debug_control_build_marker_v1"

enum DebugControlPaths {
    static func controlDirectory() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("Elysium Debug", isDirectory: true)
            .appendingPathComponent("Control", isDirectory: true)
    }

    static func manifestURL() throws -> URL {
        try controlDirectory().appendingPathComponent("session.json", isDirectory: false)
    }
}

/// One-controller, localhost-only authenticated TCP endpoint. The manifest token authenticates a
/// same-user controller; a fresh server challenge derives a new key for every connection so frame
/// sequences can safely restart without making an earlier transcript replayable.
final class DebugControlServer {
    private static let requestPayloadLimit = 64 * 1_024
    private static let receiveChunkLimit = 64 * 1_024
    private static let handshakeTimeout: TimeInterval = 3
    private static let idleTimeout: TimeInterval = 300
    private static let maximumRequestsPerSecond = 256
    // Requests are deliberately serialized per controller. In particular, a capture must be
    // taken before a later mutation can change the frame it is intended to prove.
    private static let maximumOutstandingRequests = 1

    let sessionID = UUID()
    let token = DebugSessionToken.random()
    let buildIdentifier: String
    let manifestURL: URL
    let artifactDirectory: URL
    let runtime: DebugControlRuntime

    private let queue = DispatchQueue(label: "elysium.debug-control.server", qos: .userInitiated)
    private let queueIdentityKey = DispatchSpecificKey<UInt8>()
    private let queueIdentityValue: UInt8 = 1
    private var listener: NWListener?
    private var activePeer: Peer?
    private var pendingPeer: Peer?
    private var publishedManifest: DebugSessionManifest?
    private var quitTerminationScheduled = false
    private var quitFallback: DispatchWorkItem?
    private var stopped = false

    @MainActor
    init(app: AppDelegate) throws {
        let process = try DebugManifestValidator.currentProcessIdentity()
        buildIdentifier = try DebugManifestValidator.executableSHA256(
            at: URL(fileURLWithPath: process.executablePath))
        let paths = try Self.prepareControlDirectory(sessionID: sessionID)
        manifestURL = paths.manifest
        artifactDirectory = paths.artifacts
        runtime = try DebugControlRuntime(app: app, sessionID: sessionID,
                                          artifactDirectory: artifactDirectory)
        queue.setSpecific(key: queueIdentityKey, value: queueIdentityValue)
    }

    func start(completion: @escaping (Result<DebugSessionManifest, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host("127.0.0.1"), port: .any)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        do {
                            guard let port = listener.port else {
                                throw DebugControlServerError.missingPort
                            }
                            let manifest = try self.makeAndPublishManifest(port: port.rawValue)
                            self.publishedManifest = manifest
                            DispatchQueue.main.async { completion(.success(manifest)) }
                        } catch {
                            self.stopOnQueue()
                            DispatchQueue.main.async { completion(.failure(error)) }
                        }
                    case .failed(let error):
                        self.stopOnQueue()
                        DispatchQueue.main.async { completion(.failure(error)) }
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
            } catch {
                self.stopOnQueue()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    @MainActor
    func stop() {
        queue.sync { [weak self] in self?.stopOnQueue(scheduleRuntimeShutdown: false) }
        // applicationWillTerminate must release a retained saved-world maintenance lease before
        // the AppDelegate continues into final save and database teardown.
        runtime.shutdown()
    }

    deinit {
        // AppDelegate owns the normal, synchronous stop path. This is a fail-safe for partial
        // startup and future ownership changes. Serialize with all Peer callbacks unless the last
        // server reference was itself released on the server queue.
        if DispatchQueue.getSpecific(key: queueIdentityKey) == queueIdentityValue {
            stopOnQueue()
        } else {
            queue.sync { stopOnQueue() }
        }
    }

    private func stopOnQueue(scheduleRuntimeShutdown: Bool = true) {
        guard !stopped else { return }
        stopped = true
        quitTerminationScheduled = false
        quitFallback?.cancel()
        quitFallback = nil
        activePeer?.cancelForServerShutdown()
        activePeer = nil
        pendingPeer?.cancelForServerShutdown()
        pendingPeer = nil
        listener?.cancel()
        listener = nil
        revokeManifestIfOwned()
        if scheduleRuntimeShutdown {
            let runtime = runtime
            DispatchQueue.main.async { runtime.shutdown() }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, pendingPeer == nil, Self.isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        let challenge = DebugSessionKeyDerivation.randomServerChallenge()
        do {
            let key = try DebugSessionKeyDerivation.deriveConnectionKey(
                token: token, serverChallenge: challenge, sessionID: sessionID,
                buildIdentifier: buildIdentifier)
            let peer = try Peer(connection: connection, challenge: challenge,
                                key: key, server: self)
            // A transport is not the controller until its authenticated hello has been
            // verified. Keeping every handshake pending also prevents an unauthenticated
            // disconnect from triggering controller cleanup in peerClosed(_:).
            pendingPeer = peer
            peer.start()
        } catch {
            connection.cancel()
        }
    }

    private func peerClosed(_ peer: Peer) {
        let controllerDisconnected = activePeer === peer
        if controllerDisconnected { activePeer = nil }
        if pendingPeer === peer { pendingPeer = nil }
        if controllerDisconnected {
            DispatchQueue.main.async { [weak self] in self?.runtime.controllerDidChange() }
        }
    }

    private func peerAuthenticated(_ peer: Peer) {
        guard pendingPeer === peer else { return }
        let previous = activePeer
        pendingPeer = nil
        activePeer = peer
        // Publish the replacement first. Closing the old connection afterwards makes its
        // peerClosed callback observational only and cannot clear the new controller state.
        previous?.close()
        DispatchQueue.main.async { [weak self] in self?.runtime.controllerDidChange() }
    }

    private func handleRequest(_ request: DebugRequest, from peer: Peer) {
        DispatchQueue.main.async { [weak self, weak peer] in
            guard let self, let peer else { return }
            let stillAuthorized = self.queue.sync { self.activePeer === peer }
            guard stillAuthorized else {
                self.queue.async { peer.finishRequest() }
                return
            }
            self.runtime.handle(request) { [weak self, weak peer] response in
                guard let self, let peer else { return }
                self.queue.async { [self, peer] in
                    peer.finishRequest()
                    guard self.activePeer === peer else { return }
                    let quitAfterDelivery = request.operation == "app.quit"
                        && response.error == nil
                    if quitAfterDelivery {
                        self.scheduleQuitFallback()
                        peer.send(response) { [weak self] delivered in
                            guard delivered else { return }
                            self?.requestQuitAfterResponseOnQueue()
                        }
                    } else {
                        peer.send(response)
                    }
                }
            }
        }
    }

    private func scheduleQuitFallback() {
        guard !quitTerminationScheduled else { return }
        quitTerminationScheduled = true
        let item = DispatchWorkItem { [weak self] in
            self?.requestQuitAfterResponseOnQueue()
        }
        quitFallback = item
        queue.asyncAfter(deadline: .now() + 2, execute: item)
    }

    private func requestQuitAfterResponseOnQueue() {
        guard quitTerminationScheduled else { return }
        quitTerminationScheduled = false
        quitFallback?.cancel()
        quitFallback = nil
        DispatchQueue.main.async { [weak self] in
            self?.runtime.terminateAfterResponseDelivery()
        }
    }

    private func makeAndPublishManifest(port: UInt16) throws -> DebugSessionManifest {
        let process = try DebugManifestValidator.currentProcessIdentity()
        let manifest = try DebugSessionManifest(
            sessionID: sessionID, process: process, port: port,
            executableSHA256: buildIdentifier, buildIdentifier: buildIdentifier,
            token: token)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(manifest)
        guard data.count <= DebugManifestValidator.maximumManifestBytes else {
            throw DebugControlServerError.manifestTooLarge
        }
        try Self.atomicOwnerOnlyWrite(data, to: manifestURL)
        return manifest
    }

    private func revokeManifestIfOwned() {
        guard let publishedManifest,
              let loaded = try? DebugManifestValidator.loadSecurely(
                from: manifestURL, verifyLiveProcess: false),
              loaded.sessionID == publishedManifest.sessionID,
              loaded.token == publishedManifest.token else { return }
        _ = unlink(manifestURL.path)
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        let value = String(describing: host).lowercased()
        return value == "127.0.0.1" || value == "::1" || value == "localhost"
    }

    private static func prepareControlDirectory(sessionID: UUID)
        throws -> (manifest: URL, artifacts: URL) {
        let directory = try DebugControlPaths.controlDirectory()
        try makeOwnerOnlyDirectory(directory)
        let manifest = directory.appendingPathComponent("session.json")
        if lstatMode(manifest.path) != nil {
            if let existing = try? DebugManifestValidator.loadSecurely(
                from: manifest, verifyLiveProcess: true) {
                throw DebugControlServerError.liveSession(existing.sessionID)
            }
            guard unlink(manifest.path) == 0 || errno == ENOENT else {
                throw DebugControlServerError.fileSystem("remove stale manifest")
            }
        }
        let artifacts = directory.appendingPathComponent(
            "Artifacts-\(sessionID.uuidString.lowercased())", isDirectory: true)
        try makeOwnerOnlyDirectory(artifacts)
        return (manifest, artifacts)
    }

    private static func makeOwnerOnlyDirectory(_ url: URL) throws {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            guard (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == geteuid() else {
                throw DebugControlServerError.fileSystem("unsafe control directory")
            }
        } else {
            guard errno == ENOENT else {
                throw DebugControlServerError.fileSystem("inspect control directory")
            }
            try FileManager.default.createDirectory(at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            guard lstat(url.path, &status) == 0,
                  (status.st_mode & S_IFMT) == S_IFDIR,
                  status.st_uid == geteuid() else {
                throw DebugControlServerError.fileSystem("create control directory")
            }
        }
        guard chmod(url.path, 0o700) == 0 else {
            throw DebugControlServerError.fileSystem("secure control directory")
        }
    }

    private static func atomicOwnerOnlyWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".session-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw DebugControlServerError.fileSystem("create manifest") }
        var succeeded = false
        defer {
            close(fd)
            if !succeeded { _ = unlink(temporary.path) }
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if count > 0 { written += count; continue }
                if count < 0 && errno == EINTR { continue }
                throw DebugControlServerError.fileSystem("write manifest")
            }
        }
        guard fsync(fd) == 0, fchmod(fd, 0o600) == 0 else {
            throw DebugControlServerError.fileSystem("sync manifest")
        }
        _ = unlink(url.path)
        guard rename(temporary.path, url.path) == 0 else {
            throw DebugControlServerError.fileSystem("publish manifest")
        }
        succeeded = true
    }

    private static func lstatMode(_ path: String) -> mode_t? {
        var status = stat()
        return lstat(path, &status) == 0 ? status.st_mode : nil
    }

    private final class Peer {
        private enum State { case awaitingHello, ready, closed }

        let connection: NWConnection
        private let challenge: Data
        private unowned let server: DebugControlServer
        private var decoder: DebugAuthenticatedFrameDecoder
        private var encoder: DebugAuthenticatedFrameEncoder
        private var state: State = .awaitingHello
        private var handshakeTimer: DispatchWorkItem?
        private var idleTimer: DispatchWorkItem?
        private var requestWindowStart = DispatchTime.now().uptimeNanoseconds
        private var requestsInWindow = 0
        private var outstandingRequests = 0

        init(connection: NWConnection, challenge: Data, key: Data,
             server: DebugControlServer) throws {
            self.connection = connection
            self.challenge = challenge
            self.server = server
            decoder = try DebugAuthenticatedFrameDecoder(
                sessionKey: key, direction: .clientToServer,
                limits: DebugFrameLimits(maximumPayloadBytes: requestPayloadLimit))
            encoder = try DebugAuthenticatedFrameEncoder(
                sessionKey: key, direction: .serverToClient)
        }

        func start() {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.connection.send(content: self.challenge,
                                         completion: .contentProcessed { [weak self] error in
                        guard let self else { return }
                        if error != nil { self.close(); return }
                        self.armHandshakeTimeout()
                        self.receive()
                    })
                case .failed, .cancelled:
                    self.close()
                default: break
                }
            }
            connection.start(queue: server.queue)
        }

        func send(_ response: DebugResponse, completion: ((Bool) -> Void)? = nil) {
            guard state == .ready else {
                if state != .closed { close() }
                completion?(false)
                return
            }
            do {
                let encoderJSON = JSONEncoder()
                encoderJSON.outputFormatting = [.sortedKeys]
                let payload = try encoderJSON.encode(response)
                let frame = try encoder.encode(kind: .response, payload: payload)
                connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                    let delivered = error == nil
                    if !delivered { self?.close() }
                    completion?(delivered)
                })
                armIdleTimeout()
            } catch {
                close()
                completion?(false)
            }
        }

        /// Owner teardown cannot call close(): that method reports back through the unowned
        /// server reference, which is unsafe from DebugControlServer.deinit.
        func cancelForServerShutdown() {
            guard state != .closed else { return }
            state = .closed
            handshakeTimer?.cancel()
            idleTimer?.cancel()
            connection.stateUpdateHandler = nil
            connection.cancel()
        }

        func close() {
            guard state != .closed else { return }
            state = .closed
            handshakeTimer?.cancel()
            idleTimer?.cancel()
            connection.cancel()
            server.peerClosed(self)
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1,
                               maximumLength: receiveChunkLimit) { [weak self] data, _, complete, error in
                guard let self, self.state != .closed else { return }
                if let data, !data.isEmpty {
                    if self.state == .awaitingHello && Self.looksLikeHTTP(data) {
                        self.close(); return
                    }
                    do {
                        let frames = try self.decoder.append(data)
                        for frame in frames { try self.receive(frame) }
                    } catch {
                        self.close(); return
                    }
                }
                if complete || error != nil { self.close(); return }
                self.receive()
            }
        }

        private func receive(_ frame: DebugDecodedFrame) throws {
            switch state {
            case .awaitingHello:
                guard frame.kind == .clientHello else {
                    throw DebugControlServerError.invalidHandshake
                }
                try DebugJSONPreflight.validate(frame.payload)
                let hello = try JSONDecoder().decode(DebugClientHello.self, from: frame.payload)
                guard hello.sessionID == server.sessionID,
                      hello.buildIdentifier == server.buildIdentifier else {
                    throw DebugControlServerError.invalidHandshake
                }
                let response = try DebugServerHello(sessionID: server.sessionID,
                                                    capabilities: server.runtime.capabilities)
                let json = JSONEncoder()
                json.outputFormatting = [.sortedKeys]
                let payload = try json.encode(response)
                let encoded = try encoder.encode(kind: .serverHello, payload: payload)
                connection.send(content: encoded, completion: .contentProcessed { [weak self] error in
                    if error != nil { self?.close() }
                })
                state = .ready
                server.peerAuthenticated(self)
                handshakeTimer?.cancel()
                armIdleTimeout()
            case .ready:
                guard frame.kind == .request, allowRequestNow(), beginRequest() else {
                    throw DebugControlServerError.rateLimited
                }
                try DebugJSONPreflight.validate(frame.payload)
                let request = try JSONDecoder().decode(DebugRequest.self, from: frame.payload)
                armIdleTimeout()
                server.handleRequest(request, from: self)
            case .closed:
                throw DebugControlServerError.invalidHandshake
            }
        }

        private func allowRequestNow() -> Bool {
            let now = DispatchTime.now().uptimeNanoseconds
            if now - requestWindowStart >= 1_000_000_000 {
                requestWindowStart = now
                requestsInWindow = 0
            }
            requestsInWindow += 1
            return requestsInWindow <= maximumRequestsPerSecond
        }

        private func beginRequest() -> Bool {
            guard outstandingRequests < maximumOutstandingRequests else { return false }
            outstandingRequests += 1
            return true
        }

        func finishRequest() {
            if outstandingRequests > 0 { outstandingRequests -= 1 }
        }

        private func armHandshakeTimeout() {
            handshakeTimer?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard self?.state == .awaitingHello else { return }
                self?.close()
            }
            handshakeTimer = item
            server.queue.asyncAfter(deadline: .now() + handshakeTimeout, execute: item)
        }

        private func armIdleTimeout() {
            idleTimer?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.close() }
            idleTimer = item
            server.queue.asyncAfter(deadline: .now() + idleTimeout, execute: item)
        }

        private static func looksLikeHTTP(_ data: Data) -> Bool {
            let prefix = String(decoding: data.prefix(8), as: UTF8.self).uppercased()
            return ["GET ", "POST ", "PUT ", "HEAD ", "OPTIONS ", "CONNECT ", "DELETE "]
                .contains { prefix.hasPrefix($0) }
        }
    }
}

private enum DebugControlServerError: Error, CustomStringConvertible {
    case missingPort
    case manifestTooLarge
    case liveSession(UUID)
    case invalidHandshake
    case rateLimited
    case fileSystem(String)

    var description: String {
        switch self {
        case .missingPort: return "Debug listener did not publish a port"
        case .manifestTooLarge: return "Debug manifest exceeded its size limit"
        case .liveSession(let id): return "Another debug session is live: \(id)"
        case .invalidHandshake: return "Invalid debug-control handshake"
        case .rateLimited: return "Debug-control request rate exceeded"
        case .fileSystem(let action): return "Debug-control filesystem failure: \(action)"
        }
    }
}
#endif
