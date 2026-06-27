import Foundation
import Network
import PebbleCore

enum LANTransportError: Error, CustomStringConvertible {
    case noWorld
    case invalidJoinCode
    case invalidDirectTarget
    case invalidPort
    case listenerUnavailable(String)
    case alreadyBusy

    var description: String {
        switch self {
        case .noWorld: return "Open a world before hosting a LAN game."
        case .invalidJoinCode: return "Join code must be 4-8 uppercase letters or digits."
        case .invalidDirectTarget: return "Direct Connect target must be <host> <port> <joinCode>."
        case .invalidPort: return "Port must be 1-65535."
        case .listenerUnavailable(let reason): return "LAN listener could not start: \(reason)"
        case .alreadyBusy: return "Stop the current LAN session before starting another."
        }
    }
}

struct LANDiscoveredHost {
    let endpoint: NWEndpoint
    let displayName: String
    let endpointDescription: String
}

private enum LANPeerMode {
    case hostPeer
    case clientServer
}

private final class LANWirePeer {
    let id = UUID()
    let connection: NWConnection
    var buffer = Data()
    var accepted = false
    var playerID = ""
    var playerName = "Player"
    var nextSequence: UInt32 = 1

    init(connection: NWConnection) {
        self.connection = connection
    }
}

final class LANMultiplayerManager {
    static let shared = LANMultiplayerManager()

    private let queue = DispatchQueue(label: "com.briangao.pebble.lan")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var clientPeer: LANWirePeer?
    private var hostPeers: [UUID: LANWirePeer] = [:]
    private var hostWorldSummary: LANWorldSummary?
    private var joinCode = ""
    private var hostPort = LAN_MULTIPLAYER_DEFAULT_PORT
    private var hostedWorldName = ""
    private var localPeerID: String {
        let key = "PebbleLANPeerID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    private(set) var state: LANMultiplayerConnectionState = .idle
    private(set) var discoveredHosts: [LANDiscoveredHost] = []
    private(set) var statusLines: [String] = ["LAN multiplayer idle."]

    private init() {}

    func startHost(game: GameCore, requestedJoinCode: String?, requestedPort: UInt16?) throws {
        guard game.hasWorld() else { throw LANTransportError.noWorld }
        let code = requestedJoinCode.map(normalizedLANJoinCode) ?? generateLANJoinCode()
        guard isValidLANJoinCode(code) else { throw LANTransportError.invalidJoinCode }
        let port = requestedPort ?? LAN_MULTIPLAYER_DEFAULT_PORT
        guard let nwPort = NWEndpoint.Port(rawValue: port), nwPort.rawValue > 0 else {
            throw LANTransportError.invalidPort
        }

        stop()
        let rec = game.worldRec
        hostWorldSummary = LANWorldSummary(
            worldID: rec?.id ?? "unsaved",
            worldName: rec?.name ?? "Pebble World",
            seed: Int64(rec?.seed ?? Int32(bitPattern: game.world.seed)),
            gameMode: rec?.gameMode ?? game.player?.gameMode ?? GameMode.survival,
            difficulty: rec?.difficulty ?? game.world.difficulty,
            dimension: game.dim.rawValue,
            playerCount: 1
        )
        joinCode = code
        hostPort = port
        hostedWorldName = hostWorldSummary?.worldName ?? "Pebble World"

        do {
            let newListener = try NWListener(using: .tcp, on: nwPort)
            newListener.service = NWListener.Service(
                name: sanitizedLANWorldName(hostedWorldName),
                type: LAN_MULTIPLAYER_SERVICE_TYPE,
                domain: nil,
                txtRecord: nil
            )
            newListener.newConnectionHandler = { [weak self] connection in
                self?.acceptHostConnection(connection)
            }
            newListener.stateUpdateHandler = { [weak self, weak newListener] newState in
                self?.handleListenerState(newState, listener: newListener)
            }
            listener = newListener
            setState(.hosting)
            appendStatus("Opening LAN world \"\(hostedWorldName)\" on port \(port).")
            newListener.start(queue: queue)
        } catch {
            setState(.failed)
            throw LANTransportError.listenerUnavailable(error.localizedDescription)
        }
    }

    func startBrowsing() {
        browser?.cancel()
        discoveredHosts = []
        let descriptor = NWBrowser.Descriptor.bonjour(type: LAN_MULTIPLAYER_SERVICE_TYPE, domain: nil)
        let newBrowser = NWBrowser(for: descriptor, using: .tcp)
        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            let hosts = results.map { result in
                LANDiscoveredHost(
                    endpoint: result.endpoint,
                    displayName: LANMultiplayerManager.displayName(for: result.endpoint),
                    endpointDescription: String(describing: result.endpoint)
                )
            }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            DispatchQueue.main.async {
                self?.discoveredHosts = hosts
                if hosts.isEmpty {
                    self?.appendStatus("No Pebble LAN worlds discovered yet.")
                } else {
                    self?.appendStatus("Discovered \(hosts.count) Pebble LAN world\(hosts.count == 1 ? "" : "s").")
                }
            }
        }
        newBrowser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.setState(.browsing)
                    self?.appendStatus("Browsing for \(LAN_MULTIPLAYER_SERVICE_TYPE) worlds.")
                case .failed(let error):
                    self?.setState(.failed)
                    self?.appendStatus("LAN browser failed: \(error.localizedDescription)")
                case .cancelled:
                    if self?.listener == nil && self?.clientPeer == nil {
                        self?.setState(.idle)
                    }
                default:
                    break
                }
            }
        }
        browser = newBrowser
        setState(.browsing)
        appendStatus("Starting LAN discovery.")
        newBrowser.start(queue: queue)
    }

    func connectToDiscovered(_ host: LANDiscoveredHost, playerName: String, joinCode rawJoinCode: String) throws {
        let code = normalizedLANJoinCode(rawJoinCode)
        guard isValidLANJoinCode(code) else { throw LANTransportError.invalidJoinCode }
        stopClientOnly()
        let connection = NWConnection(to: host.endpoint, using: .tcp)
        connect(connection, playerName: playerName, joinCode: code, label: host.displayName)
    }

    func directConnect(host rawHost: String, port rawPort: String, joinCode rawJoinCode: String, playerName: String) throws {
        guard let target = LANDirectConnectTarget.parse(host: rawHost, port: rawPort) else {
            throw LANTransportError.invalidDirectTarget
        }
        let code = normalizedLANJoinCode(rawJoinCode)
        guard isValidLANJoinCode(code) else { throw LANTransportError.invalidJoinCode }
        stopClientOnly()
        guard let nwPort = NWEndpoint.Port(rawValue: target.port) else { throw LANTransportError.invalidPort }
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: nwPort, using: .tcp)
        connect(connection, playerName: playerName, joinCode: code, label: "\(target.host):\(target.port)")
    }

    func sendChat(_ rawText: String, sender rawSender: String? = nil) {
        let text = sanitizedLANChatText(rawText)
        guard !text.isEmpty else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let sender = sanitizedLANPlayerName(rawSender ?? NSFullUserName())
            if self.listener != nil {
                let message = LANMultiplayerMessage.chat(sender: sender, text: text)
                self.broadcastFromHost(message)
                self.postChat("§b<LAN \(sender)> §r\(text)")
            } else if let peer = self.clientPeer {
                self.send(.chat(sender: sender, text: text), to: peer)
            } else {
                self.appendStatus("No active LAN connection for chat.")
            }
        }
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            browser?.cancel()
            browser = nil
            clientPeer?.connection.cancel()
            clientPeer = nil
            for peer in hostPeers.values { peer.connection.cancel() }
            hostPeers.removeAll()
            hostWorldSummary = nil
            joinCode = ""
            hostPort = LAN_MULTIPLAYER_DEFAULT_PORT
            hostedWorldName = ""
        }
        setState(.idle)
        appendStatus("LAN multiplayer stopped.")
    }

    func statusSummary() -> [String] {
        var lines = statusLines.suffix(8).map { $0 }
        let acceptedCount = queue.sync {
            hostPeers.values.filter { $0.accepted }.count
        }
        switch state {
        case .hosting:
            lines.append("Hosting \"\(hostedWorldName)\" on port \(hostPort), join code \(joinCode).")
            lines.append("Connected clients: \(acceptedCount)/\(LAN_MULTIPLAYER_MAX_CLIENTS).")
        case .browsing:
            lines.append("Discovered hosts: \(discoveredHosts.count).")
        case .connected:
            lines.append("Connected to a LAN host.")
        default:
            lines.append("State: \(state.rawValue).")
        }
        return lines
    }

    private func connect(_ connection: NWConnection, playerName: String, joinCode code: String, label: String) {
        let peer = LANWirePeer(connection: connection)
        clientPeer = peer
        setState(.connecting)
        appendStatus("Connecting to \(label).")
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready:
                self.appendStatus("Connected transport to \(label); sending join request.")
                let hello = LANMultiplayerMessage.clientHello(
                    playerID: self.localPeerID,
                    playerName: sanitizedLANPlayerName(playerName),
                    joinCode: code,
                    pebbleVersion: PEBBLE_VERSION
                )
                self.send(hello, to: peer)
            case .failed(let error):
                self.setState(.failed)
                self.appendStatus("LAN connect failed: \(error.localizedDescription)")
            case .cancelled:
                if self.state != .hosting { self.setState(.idle) }
            default:
                break
            }
        }
        receiveLoop(peer, mode: .clientServer)
        connection.start(queue: queue)
    }

    private func acceptHostConnection(_ connection: NWConnection) {
        let peer = LANWirePeer(connection: connection)
        hostPeers[peer.id] = peer
        appendStatus("Incoming LAN connection from \(connection.endpoint).")
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .failed(let error):
                self.appendStatus("LAN client failed: \(error.localizedDescription)")
                self.hostPeers.removeValue(forKey: peer.id)
            case .cancelled:
                self.hostPeers.removeValue(forKey: peer.id)
            default:
                break
            }
        }
        receiveLoop(peer, mode: .hostPeer)
        connection.start(queue: queue)
    }

    private func handleListenerState(_ state: NWListener.State, listener: NWListener?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .ready:
                if let port = listener?.port?.rawValue { self.hostPort = port }
                self.setState(.hosting)
                self.appendStatus("LAN world ready on port \(self.hostPort). Join code: \(self.joinCode).")
            case .failed(let error):
                self.setState(.failed)
                self.appendStatus("LAN listener failed: \(error.localizedDescription)")
            case .cancelled:
                if self.clientPeer == nil { self.setState(.idle) }
            default:
                break
            }
        }
    }

    private func receiveLoop(_ peer: LANWirePeer, mode: LANPeerMode) {
        peer.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: LANMultiplayerFrameCodec.headerByteCount + LAN_MULTIPLAYER_MAX_FRAME_BYTES
        ) { [weak self, weak peer] data, _, isComplete, error in
            guard let self, let peer else { return }
            if let data, !data.isEmpty {
                peer.buffer.append(data)
                do {
                    let frames = try LANMultiplayerFrameCodec.decodeFrames(from: &peer.buffer)
                    for frame in frames {
                        self.handle(frame.message, from: peer, mode: mode)
                    }
                } catch {
                    self.appendStatus("Dropping malformed LAN peer: \(error)")
                    peer.connection.cancel()
                    self.hostPeers.removeValue(forKey: peer.id)
                    if self.clientPeer === peer { self.clientPeer = nil }
                    return
                }
            }
            if let error {
                self.appendStatus("LAN receive failed: \(error.localizedDescription)")
                peer.connection.cancel()
                return
            }
            if isComplete {
                peer.connection.cancel()
                return
            }
            self.receiveLoop(peer, mode: mode)
        }
    }

    private func handle(_ message: LANMultiplayerMessage, from peer: LANWirePeer, mode: LANPeerMode) {
        switch mode {
        case .hostPeer:
            handleHostMessage(message, from: peer)
        case .clientServer:
            handleClientMessage(message, from: peer)
        }
    }

    private func handleHostMessage(_ message: LANMultiplayerMessage, from peer: LANWirePeer) {
        switch message {
        case .clientHello(let playerID, let playerName, let rawJoinCode, _):
            let name = sanitizedLANPlayerName(playerName)
            guard normalizedLANJoinCode(rawJoinCode) == joinCode else {
                send(.serverReject(reason: "Join code rejected."), to: peer)
                peer.connection.cancel()
                appendStatus("Rejected LAN join from \(name): bad join code.")
                return
            }
            guard hostPeers.values.filter({ $0.accepted }).count < LAN_MULTIPLAYER_MAX_CLIENTS else {
                send(.serverReject(reason: "LAN world is full."), to: peer)
                peer.connection.cancel()
                appendStatus("Rejected LAN join from \(name): server full.")
                return
            }
            peer.accepted = true
            peer.playerID = String(playerID.prefix(128))
            peer.playerName = name
            let summary = makeWorldSummary(playerCount: hostPeers.values.filter { $0.accepted }.count)
            send(.serverAccept(peerID: peer.playerID, world: summary), to: peer)
            broadcastFromHost(.chat(sender: "Server", text: "\(name) joined the LAN world."), except: peer.id)
            postChat("§b[LAN] \(name) joined.")
        case .chat(let sender, let text):
            guard peer.accepted else { return }
            let cleanSender = sanitizedLANPlayerName(sender)
            let cleanText = sanitizedLANChatText(text)
            guard !cleanText.isEmpty else { return }
            let chat = LANMultiplayerMessage.chat(sender: cleanSender, text: cleanText)
            broadcastFromHost(chat, except: nil)
            postChat("§b<LAN \(cleanSender)> §r\(cleanText)")
        case .ping(let nonce):
            send(.pong(nonce: nonce), to: peer)
        case .disconnect(let reason):
            appendStatus("\(peer.playerName) disconnected: \(sanitizedLANChatText(reason))")
            peer.connection.cancel()
        default:
            guard peer.accepted else { return }
            appendStatus("LAN host received \(message.kind) intent from \(peer.playerName); queued for future authoritative gameplay replication.")
        }
    }

    private func handleClientMessage(_ message: LANMultiplayerMessage, from peer: LANWirePeer) {
        switch message {
        case .serverAccept(_, let world):
            setState(.connected)
            appendStatus("Joined LAN world \"\(world.worldName)\" with \(world.playerCount)/\(world.maxPlayers) players.")
            postChat("§b[LAN] Connected to \"\(world.worldName)\".")
        case .serverReject(let reason):
            setState(.rejected)
            appendStatus("LAN join rejected: \(sanitizedLANChatText(reason))")
            peer.connection.cancel()
        case .chat(let sender, let text):
            let cleanText = sanitizedLANChatText(text)
            guard !cleanText.isEmpty else { return }
            postChat("§b<LAN \(sanitizedLANPlayerName(sender))> §r\(cleanText)")
        case .ping(let nonce):
            send(.pong(nonce: nonce), to: peer)
        case .pong:
            break
        case .disconnect(let reason):
            appendStatus("LAN server disconnected: \(sanitizedLANChatText(reason))")
            peer.connection.cancel()
            setState(.idle)
        default:
            appendStatus("LAN client received \(message.kind); gameplay replication handling is pending.")
        }
    }

    private func send(_ message: LANMultiplayerMessage, to peer: LANWirePeer) {
        do {
            let frame = try LANMultiplayerFrameCodec.encode(message, sequence: peer.nextSequence)
            peer.nextSequence &+= 1
            peer.connection.send(content: frame, completion: .contentProcessed { [weak self, weak peer] error in
                if let error {
                    self?.appendStatus("LAN send failed: \(error.localizedDescription)")
                    peer?.connection.cancel()
                }
            })
        } catch {
            appendStatus("LAN encode failed: \(error)")
        }
    }

    private func broadcastFromHost(_ message: LANMultiplayerMessage, except excludedPeerID: UUID? = nil) {
        for peer in hostPeers.values where peer.accepted && peer.id != excludedPeerID {
            send(message, to: peer)
        }
    }

    private func makeWorldSummary(playerCount: Int) -> LANWorldSummary {
        if var summary = hostWorldSummary {
            summary.playerCount = max(1, min(summary.maxPlayers, playerCount + 1))
            return summary
        }
        return LANWorldSummary(
            worldID: "unsaved",
            worldName: hostedWorldName,
            seed: 0,
            gameMode: GameMode.survival,
            difficulty: 2,
            dimension: Dim.overworld.rawValue,
            playerCount: max(1, playerCount + 1)
        )
    }

    private func stopClientOnly() {
        clientPeer?.connection.cancel()
        clientPeer = nil
        if listener == nil { setState(.idle) }
    }

    private func setState(_ newState: LANMultiplayerConnectionState) {
        if Thread.isMainThread {
            state = newState
        } else {
            DispatchQueue.main.async { [weak self] in self?.state = newState }
        }
    }

    private func appendStatus(_ line: String) {
        let clean = sanitizedLANChatText(line)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusLines.append(clean)
            if self.statusLines.count > 48 {
                self.statusLines.removeFirst(self.statusLines.count - 48)
            }
        }
    }

    private func postChat(_ line: String) {
        DispatchQueue.main.async {
            pushChat(line)
        }
    }

    private static func displayName(for endpoint: NWEndpoint) -> String {
        let text = String(describing: endpoint)
        if case let .service(name: name, type: _, domain: _, interface: _) = endpoint {
            return name
        }
        return text
    }
}

func runLANCommand(_ game: GameCore, _ args: [String]) {
    let manager = LANMultiplayerManager.shared
    func ok(_ message: String) { pushChat("§7" + message) }
    func fail(_ message: String) { pushChat("§c" + message) }
    func playerName(from index: Int) -> String {
        let explicit = args.count > index ? args[index...].joined(separator: " ") : ""
        return sanitizedLANPlayerName(explicit.isEmpty ? NSFullUserName() : explicit)
    }

    let subcommand = args.first?.lowercased() ?? "status"
    do {
        switch subcommand {
        case "help":
            ok("LAN: /lan host [joinCode] [port], /lan browse, /lan hosts, /lan join <host> <port> <joinCode> [name], /lan join <index> <joinCode> [name], /lan say <text>, /lan status, /lan stop")
        case "host", "open":
            let rawCode = args.count >= 2 ? args[1] : nil
            let requestedCode = rawCode.map(normalizedLANJoinCode)
            let portArg = args.dropFirst(2).first(where: { UInt16($0) != nil })
            let port = portArg.flatMap(UInt16.init)
            try manager.startHost(game: game, requestedJoinCode: requestedCode, requestedPort: port)
            for line in manager.statusSummary() { ok(line) }
        case "browse", "discover":
            manager.startBrowsing()
            ok("Browsing for Pebble LAN worlds.")
        case "hosts", "list":
            let hosts = manager.discoveredHosts
            if hosts.isEmpty {
                ok("No Pebble LAN worlds discovered. Run /lan browse first.")
            } else {
                for (i, host) in hosts.enumerated() {
                    ok("[\(i)] \(host.displayName) - \(host.endpointDescription)")
                }
            }
        case "join":
            guard args.count >= 3 else {
                return fail("Usage: /lan join <host> <port> <joinCode> [name] or /lan join <index> <joinCode> [name]")
            }
            if let index = Int(args[1]), index >= 0, index < manager.discoveredHosts.count {
                try manager.connectToDiscovered(manager.discoveredHosts[index], playerName: playerName(from: 3), joinCode: args[2])
                ok("Joining discovered LAN world \(manager.discoveredHosts[index].displayName).")
            } else {
                guard args.count >= 4 else {
                    return fail("Usage: /lan join <host> <port> <joinCode> [name]")
                }
                try manager.directConnect(host: args[1], port: args[2], joinCode: args[3], playerName: playerName(from: 4))
                ok("Connecting to \(args[1]):\(args[2]).")
            }
        case "direct", "connect":
            guard args.count >= 4 else {
                return fail("Usage: /lan direct <host> <port> <joinCode> [name]")
            }
            try manager.directConnect(host: args[1], port: args[2], joinCode: args[3], playerName: playerName(from: 4))
            ok("Connecting to \(args[1]):\(args[2]).")
        case "say", "chat":
            let text = args.dropFirst().joined(separator: " ")
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return fail("Usage: /lan say <message>")
            }
            manager.sendChat(text, sender: playerName(from: args.count))
        case "status":
            for line in manager.statusSummary() { ok(line) }
        case "stop", "close":
            manager.stop()
            ok("LAN multiplayer stopped.")
        default:
            fail("Unknown LAN command. Try /lan help")
        }
    } catch let error as LANTransportError {
        fail(error.description)
    } catch {
        fail("LAN command failed: \(error)")
    }
}
