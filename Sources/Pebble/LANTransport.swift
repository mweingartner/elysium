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

private enum LANReplicationSendPriority {
    case interactive
    case background
}

private let LAN_MAX_SYNC_CHUNK_GENERATIONS_PER_REQUEST = 4

private struct LANHostReplicationContent {
    var includeWorldSummary = false
    var includeWorldState = false
    var includeEntities = false
    var entitySnapshotsComplete = false
    var includeInventories = false
    var includeDirtyBlockEntities = false
    var includeDirtyChunkSections = false
    var includeBlockEntityFill = false
    var blockEntityFillCap = 0
    var entityRadius = 160.0

    static let foregroundDelta = LANHostReplicationContent(includeDirtyBlockEntities: true, includeDirtyChunkSections: true)

    static let initialSnapshot = LANHostReplicationContent(
        includeWorldSummary: true,
        includeWorldState: true,
        includeEntities: true,
        entitySnapshotsComplete: true,
        includeInventories: true,
        includeDirtyBlockEntities: true,
        includeDirtyChunkSections: true,
        includeBlockEntityFill: true,
        blockEntityFillCap: 16
    )

    static func background(_ selection: LANHostReplicationBackgroundSelection) -> LANHostReplicationContent {
        LANHostReplicationContent(
            includeWorldSummary: selection.includeWorldSummary,
            includeWorldState: selection.includeWorldState,
            includeEntities: selection.includeEntitySnapshots,
            entitySnapshotsComplete: selection.entitySnapshotsComplete,
            includeInventories: selection.includeInventories,
            includeDirtyBlockEntities: false,
            includeDirtyChunkSections: false,
            includeBlockEntityFill: selection.includeBlockEntityFill,
            blockEntityFillCap: 8
        )
    }
}

/// Fixed-size token bucket for per-peer rate limiting (§7.6/A12). Pure value type — no timers,
/// no Network.framework dependency — so it is trivially testable logic even though it lives in
/// this Network-framework-bound file (the plan's designated home for it).
struct LANTokenBucket {
    let capacity: Double
    let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: Double

    init(capacity: Double, refillPerSecond: Double, now: Double = Date.timeIntervalSinceReferenceDate) {
        self.capacity = max(1, capacity)
        self.refillPerSecond = max(0.001, refillPerSecond)
        self.tokens = self.capacity
        self.lastRefill = now
    }

    /// Attempts to spend one token at `now`, refilling first. Returns false (no mutation beyond
    /// the refill) when the bucket is empty — callers should drop the message on `false`.
    mutating func tryConsume(now: Double = Date.timeIntervalSinceReferenceDate) -> Bool {
        let elapsed = max(0, now - lastRefill)
        lastRefill = now
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}

/// Per-peer rate limits (§7.6): one bucket per gameplay message category. `blockIntent`,
/// `attackIntent`, and `tossIntent` share a single combined bucket per the plan.
private struct LANPeerRateLimiter {
    var chat: LANTokenBucket
    var chunkRequest: LANTokenBucket
    var gameplayIntent: LANTokenBucket
    var inventoryUpdate: LANTokenBucket
    var containerEditIntent: LANTokenBucket

    init(now: Double = Date.timeIntervalSinceReferenceDate) {
        chat = LANTokenBucket(capacity: 8, refillPerSecond: 8.0 / 10.0, now: now)
        chunkRequest = LANTokenBucket(capacity: 30, refillPerSecond: 30, now: now)
        gameplayIntent = LANTokenBucket(capacity: 60, refillPerSecond: 60, now: now)
        inventoryUpdate = LANTokenBucket(capacity: 25, refillPerSecond: 25, now: now)
        containerEditIntent = LANTokenBucket(capacity: 20, refillPerSecond: 20, now: now)
    }
}

/// Splits a chunk-section-heavy replication batch into pieces of decreasing section count so an
/// oversized frame (§10) can be retried instead of silently dropped. Halves the section count
/// each attempt down to a 1-section floor; pure function of the section list for testability.
func lanHalvedChunkSectionBatches(_ sections: [LANChunkSectionSnapshot]) -> [[LANChunkSectionSnapshot]] {
    guard !sections.isEmpty else { return [] }
    var batches: [[LANChunkSectionSnapshot]] = []
    var remaining = sections
    var chunkSize = max(1, sections.count / 2)
    while !remaining.isEmpty {
        let take = min(chunkSize, remaining.count)
        batches.append(Array(remaining.prefix(take)))
        remaining.removeFirst(take)
        chunkSize = max(1, chunkSize / 2 == 0 ? 1 : min(chunkSize, take))
    }
    return batches
}

private final class LANWirePeer {
    let id = UUID()
    let connection: NWConnection
    var buffer = Data()
    var accepted = false
    var playerID = ""
    var playerName = "Player"
    var nextSequence: UInt32 = 1
    /// set on the socket being replaced by a newer accepted connection for the same playerID
    /// (A5 reconnect-supersede) so its cancel/disconnect handler skips lifecycle cleanup —
    /// the NEW socket already ran (or will run) that cleanup exactly once.
    var superseded = false
    /// true once this peer's disconnect lifecycle cleanup has run — Network.framework can
    /// surface more than one terminal signal for the same connection (e.g. a receive error
    /// followed by the state handler's `.cancelled`), and this guards against double-teardown
    /// (double `markHostPeerDisconnected`/`handleLANConnectionLost`, double persistence write).
    var tornDown = false
    /// wall-clock time of the last frame received from this peer on ANY message kind — drives
    /// the 15s silence timeout (§7.6).
    var lastReceiveTime = Date.timeIntervalSinceReferenceDate
    /// wall-clock time this connection was accepted into the host's peer table but not yet
    /// authenticated via ClientHello — drives the 10s handshake timeout (A7/§7.6).
    var acceptedConnectionTime = Date.timeIntervalSinceReferenceDate
    /// wall-clock time the outbound ping nonce was last sent (host->peer and client->host).
    var lastPingSentTime: Double?
    var pendingPingNonce: UInt64?
    var rateLimiter = LANPeerRateLimiter()
    private var throttledCategoriesLoggedThisWindow = Set<String>()
    var lastThrottleLogTime = 0.0
    /// count of sends handed to `connection.send` that have not yet completed (§7.7 backpressure).
    var inFlightSendCount = 0
    var inFlightSendBytes = 0

    init(connection: NWConnection) {
        self.connection = connection
    }

    /// Logs at most once per throttle category per 5s window, per peer, so a flood of
    /// over-limit messages produces one status line instead of one per drop.
    func shouldLogThrottle(_ category: String, now: Double) -> Bool {
        if now - lastThrottleLogTime > 5 {
            throttledCategoriesLoggedThisWindow.removeAll()
            lastThrottleLogTime = now
        }
        return throttledCategoriesLoggedThisWindow.insert(category).inserted
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
    private weak var activeGame: GameCore?
    private var hostReplicationSession = LANMultiplayerHostSession()
    private var clientReplicationSession = LANMultiplayerClientSession()
    private var hostGhostRegistry = LANHostGhostRegistry()
    private var lastHostReplicationPublish = 0.0
    private var lastHostEntityPublish = 0.0
    private var lastHostCompleteEntityPublish = 0.0
    private var lastHostBlockEntityFillPublish = 0.0
    private var lastHostWorldStatePublish = 0.0
    private var lastHostInventoryPublish = 0.0
    private var lastHostWorldSummaryPublish = 0.0
    private var lastClientPlayerStatePublish = 0.0
    private var lastHostPeerPersist = 0.0
    private let hostReplicationInterval = 0.05
    private let hostBackgroundCadence = LANHostReplicationCadence()
    private let clientPlayerStateInterval = 0.05
    private let hostPeerPersistInterval = 60.0
    private let hostPingInterval = 5.0
    private let hostPeerSilenceTimeout = 15.0
    private let hostHandshakeTimeout = 10.0
    private let clientPingInterval = 5.0
    private let clientSilenceTimeout = 15.0
    private let clientConnectHandshakeTimeout = 15.0
    private let clientWaitingAbortTimeout = 10.0
    private let backpressureDeltaSkipDepth = 4
    private let backpressureDeltaSkipBytes = LAN_MULTIPLAYER_MAX_FRAME_BYTES
    private var clientConnectDeadline: Double?
    private var clientWaitingSince: Double?
    /// every playerID this host session has accepted since `startHost` — used to persist peer
    /// records on disconnect/stop even after the live `LANWirePeer` socket is gone.
    private var knownHostPeerIDs = Set<String>()
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

    func attachGame(_ game: GameCore) {
        activeGame = game
    }

    private func configureHostReplicationHooks(for game: GameCore) {
        game.onWorldBlockChanged = { [weak self] world, x, y, z, cell in
            guard let self else { return }
            _ = self.hostReplicationSession.recordBlockChange(dimension: world.dim.rawValue, x: x, y: y, z: z, cell: cell)
        }
        game.onTemplatePlacementCommitted = { [weak self] world, undo in
            self?.hostReplicationSession.recordDirtyChunkSections(from: undo, in: world)
        }
        game.lanChunkRequestHandler = nil
        game.lanBlockIntentHandler = nil
    }

    private func configureClientReplicationHooks(for game: GameCore) {
        game.onWorldBlockChanged = nil
        game.onTemplatePlacementCommitted = nil
        game.lanChunkRequestHandler = { [weak self] world, cx, cz in
            guard let self else { return false }
            let centerY = self.activeGame?.player.map { Int($0.y.rounded(.down)) }
            let request = LANChunkRequest(
                dimension: world.dim.rawValue,
                cx: cx,
                cz: cz,
                radius: LAN_MULTIPLAYER_DEFAULT_CHUNK_REQUEST_RADIUS,
                centerY: centerY,
                verticalRadius: LAN_MULTIPLAYER_DEFAULT_CHUNK_VERTICAL_RADIUS
            )
            self.queue.async { [weak self] in
                guard let self, let peer = self.clientPeer else { return }
                self.send(.chunkRequest(playerID: self.localPeerID, request: request), to: peer)
            }
            return true
        }
        game.lanFullColumnRequestHandler = { [weak self] world, cx, cz in
            guard let self else { return false }
            let request = LANChunkRequest(dimension: world.dim.rawValue, cx: cx, cz: cz, radius: 0, centerY: nil, verticalRadius: 0)
            self.queue.async { [weak self] in
                guard let self, let peer = self.clientPeer else { return }
                self.send(.chunkRequest(playerID: self.localPeerID, request: request), to: peer)
            }
            return true
        }
        game.lanBlockIntentHandler = { [weak self] intent in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, let peer = self.clientPeer else { return }
                self.send(.blockIntent(playerID: self.localPeerID, intent: intent), to: peer)
            }
        }
        game.lanAttackIntentHandler = { [weak self] intent in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, let peer = self.clientPeer else { return }
                self.send(.attackIntent(playerID: self.localPeerID, intent: intent), to: peer)
            }
        }
        game.lanTossIntentHandler = { [weak self] intent in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, let peer = self.clientPeer else { return }
                self.send(.tossIntent(playerID: self.localPeerID, intent: intent), to: peer)
            }
        }
        game.lanContainerEditHandler = { [weak self] intent in
            guard let self else { return }
            self.queue.async { [weak self] in
                guard let self, let peer = self.clientPeer else { return }
                self.send(.containerEditIntent(playerID: self.localPeerID, intent: intent), to: peer)
            }
        }
        game.lanInventoryPublishHandler = { [weak self] snapshot, revision in
            guard let self else { return }
            let update = LANInventoryUpdate(playerID: self.localPeerID, revision: revision, snapshot: snapshot)
            self.queue.async { [weak self] in
                guard let self, let peer = self.clientPeer else { return }
                self.send(.inventoryUpdate(update), to: peer)
            }
        }
    }

    private func clearReplicationHooks(for game: GameCore?) {
        game?.onWorldBlockChanged = nil
        game?.onTemplatePlacementCommitted = nil
        game?.lanChunkRequestHandler = nil
        game?.lanFullColumnRequestHandler = nil
        game?.lanBlockIntentHandler = nil
        game?.lanAttackIntentHandler = nil
        game?.lanTossIntentHandler = nil
        game?.lanContainerEditHandler = nil
        game?.lanInventoryPublishHandler = nil
    }

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
        activeGame = game
        hostReplicationSession = LANMultiplayerHostSession()
        clientReplicationSession = LANMultiplayerClientSession()
        hostGhostRegistry = LANHostGhostRegistry()
        knownHostPeerIDs.removeAll()
        lastHostReplicationPublish = 0
        lastHostEntityPublish = 0
        lastHostCompleteEntityPublish = 0
        lastHostBlockEntityFillPublish = 0
        lastHostWorldStatePublish = 0
        lastHostInventoryPublish = 0
        lastHostWorldSummaryPublish = 0
        lastClientPlayerStatePublish = 0
        lastHostPeerPersist = 0
        configureHostReplicationHooks(for: game)
        // §7.3: seed persisted per-guest records (position/inventory/permissions) so a peer that
        // reconnects to a freshly (re)started host still resumes where it left off.
        if let worldID = rec?.id {
            for row in game.db.listLANPlayers(world: worldID) {
                if let record = lanPeerRecordSnapshot(fromStoredJSON: row.data, playerID: row.playerID) {
                    hostReplicationSession.seedPeerRecord(record)
                }
            }
        }

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
        // §7.5: flush every tracked peer record to SQLite before tearing the session down, so a
        // host restart (or the app quitting) doesn't lose guest position/inventory progress.
        persistAllHostPeerRecords()
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
        clearReplicationHooks(for: activeGame)
        activeGame?.handleLANConnectionLost(reason: "")
        activeGame = nil
        hostReplicationSession = LANMultiplayerHostSession()
        clientReplicationSession = LANMultiplayerClientSession()
        hostGhostRegistry = LANHostGhostRegistry()
        knownHostPeerIDs.removeAll()
        lastHostReplicationPublish = 0
        lastHostEntityPublish = 0
        lastHostCompleteEntityPublish = 0
        lastHostBlockEntityFillPublish = 0
        lastHostWorldStatePublish = 0
        lastHostInventoryPublish = 0
        lastHostWorldSummaryPublish = 0
        lastClientPlayerStatePublish = 0
        lastHostPeerPersist = 0
        clientConnectDeadline = nil
        clientWaitingSince = nil
        setState(.idle)
        appendStatus("LAN multiplayer stopped.")
    }

    /// Writes every host peer this session has ever accepted (`knownHostPeerIDs`) to `lan_players`
    /// on the host's world id. No-ops when not hosting or the world was never saved (no stable id
    /// to key rows on). `LANMultiplayerHostSession` doesn't expose full peer enumeration (kept
    /// private by design), so the transport tracks accepted playerIDs itself and re-reads each
    /// current record via the existing public `peerRecord(playerID:)` accessor.
    private func persistAllHostPeerRecords() {
        guard let game = activeGame, listener != nil, let worldID = game.worldRec?.id else { return }
        for playerID in knownHostPeerIDs {
            guard let record = hostReplicationSession.peerRecord(playerID: playerID) else { continue }
            game.db.putLANPlayer(world: worldID, playerID: record.playerID, lanPeerRecordJSON(record))
        }
    }

    func tickReplication(game: GameCore) {
        precondition(Thread.isMainThread)
        attachGame(game)
        guard game.hasWorld(), let player = game.player else { return }
        let now = Date.timeIntervalSinceReferenceDate
        let transportState = queue.sync { (isHosting: listener != nil, hasClientPeer: clientPeer != nil, hasAcceptedPeer: hostPeers.values.contains { $0.accepted }) }
        if transportState.isHosting {
            configureHostReplicationHooks(for: game)
            queue.async { [weak self] in self?.tickHostRobustness() }
            // per-tick addressed events (damage/grants/death) flow independent of the replication
            // publish cadence below so a hit or a pickup never waits on the next full-batch tick.
            drainHostPerPeerEvents(game: game)
            if now - lastHostPeerPersist >= hostPeerPersistInterval {
                lastHostPeerPersist = now
                persistAllHostPeerRecords()
            }
            let hasAcceptedPeer = transportState.hasAcceptedPeer
            guard hasAcceptedPeer, now - lastHostReplicationPublish >= hostReplicationInterval else { return }
            lastHostReplicationPublish = now

            var foregroundDirtyBlockEntities: [LANBlockPosition] = []
            if let foreground = makeHostReplicationBatch(
                game: game,
                player: player,
                fullSnapshot: false,
                content: .foregroundDelta,
                drainedDirtyBlockEntities: &foregroundDirtyBlockEntities
            ) {
                let drained = foreground.blockChanges
                queue.async { [weak self] in
                    self?.broadcastHostReplicationBatch(
                        foreground,
                        drainedBlockChanges: drained,
                        drainedDirtyBlockEntities: foregroundDirtyBlockEntities,
                        priority: .interactive
                    )
                }
            }

            let background = hostBackgroundCadence.backgroundSelection(
                now: now,
                lastEntitySnapshot: lastHostEntityPublish,
                lastCompleteEntitySnapshot: lastHostCompleteEntityPublish,
                lastBlockEntityFill: lastHostBlockEntityFillPublish,
                lastWorldStateSnapshot: lastHostWorldStatePublish,
                lastInventorySnapshot: lastHostInventoryPublish,
                lastWorldSummary: lastHostWorldSummaryPublish
            )
            guard background.hasContent else { return }
            if background.includeEntitySnapshots {
                lastHostEntityPublish = now
            }
            if background.entitySnapshotsComplete {
                lastHostCompleteEntityPublish = now
            }
            if background.includeBlockEntityFill {
                lastHostBlockEntityFillPublish = now
            }
            if background.includeWorldState {
                lastHostWorldStatePublish = now
            }
            if background.includeInventories {
                lastHostInventoryPublish = now
            }
            if background.includeWorldSummary {
                lastHostWorldSummaryPublish = now
            }
            var backgroundDirtyBlockEntities: [LANBlockPosition] = []
            guard let batch = makeHostReplicationBatch(
                game: game,
                player: player,
                fullSnapshot: false,
                content: .background(background),
                drainedDirtyBlockEntities: &backgroundDirtyBlockEntities
            ) else { return }
            queue.async { [weak self] in
                self?.broadcastHostReplicationBatch(
                    batch,
                    drainedBlockChanges: [],
                    drainedDirtyBlockEntities: backgroundDirtyBlockEntities,
                    priority: .background
                )
            }
        } else if transportState.hasClientPeer, state == .connected {
            configureClientReplicationHooks(for: game)
            queue.async { [weak self] in self?.tickClientRobustness() }
            guard now - lastClientPlayerStatePublish >= clientPlayerStateInterval else { return }
            lastClientPlayerStatePublish = now
            let state = makeLANPlayerState(player, playerID: localPeerID, displayName: NSFullUserName(), dimension: game.dim.rawValue)
            queue.async { [weak self] in
                guard let self, let peer = self.clientPeer else { return }
                self.send(.playerState(state), to: peer)
            }
        } else if transportState.hasClientPeer {
            // still connecting/handshaking — enforce the overall connect+handshake timeout (A7)
            // even before the client transitions to `.connected`.
            queue.async { [weak self] in self?.tickClientConnectTimeout() }
            clearReplicationHooks(for: game)
        } else {
            clearReplicationHooks(for: game)
        }
    }

    /// Drains per-peer addressed events that must reach guests promptly regardless of the batch
    /// publish cadence: proxy-recorded melee/attack damage, host-originated inventory grants
    /// (pickups/corrections/death-clears), and the alive->dead edge (spawns authoritative death
    /// drops once per epoch, D-L).
    private func drainHostPerPeerEvents(game: GameCore) {
        guard game.hasWorld() else { return }
        let world = game.world
        for entity in world.entities {
            guard let proxy = entity as? LANRemotePlayerEntity else { continue }
            let events = proxy.drainPendingDamage()
            guard !events.isEmpty else { continue }
            let playerID = proxy.multiplayerPlayerID
            queue.async { [weak self] in
                guard let self, let peer = self.hostPeers.values.first(where: { $0.accepted && $0.playerID == playerID }) else { return }
                for event in events { self.send(.damageEvent(event), to: peer) }
            }
        }
        for playerID in knownHostPeerIDs {
            if let drop = hostReplicationSession.consumeDeathDrops(for: playerID) {
                if !world.rule("keepInventory") {
                    spawnPlayerDeathDrops(inventory: drop.inventory, at: drop.x, drop.y, drop.z, in: world)
                    _ = hostReplicationSession.enqueueGrant(items: [], xp: 0, clearAll: true, to: playerID)
                }
            }
            let grants = hostReplicationSession.drainGrants(for: playerID)
            guard !grants.isEmpty else { continue }
            queue.async { [weak self] in
                guard let self, let peer = self.hostPeers.values.first(where: { $0.accepted && $0.playerID == playerID }) else { return }
                for grant in grants { self.send(.inventoryGrant(grant), to: peer) }
            }
        }
    }

    // ===========================================================================
    // §7.6 robustness: keepalive pings, silence reaping, handshake timeouts
    // ===========================================================================

    /// Runs on the transport queue: pings every accepted host peer at `hostPingInterval`, reaps
    /// peers silent for longer than `hostPeerSilenceTimeout` (any received frame — not just pongs
    /// — resets the silence clock, so active gameplay traffic alone keeps a peer alive), and reaps
    /// unaccepted connections that never completed the handshake within `hostHandshakeTimeout`.
    private func tickHostRobustness() {
        let now = Date.timeIntervalSinceReferenceDate
        for peer in hostPeers.values {
            if !peer.accepted {
                if now - peer.acceptedConnectionTime > hostHandshakeTimeout {
                    appendStatus("LAN handshake timed out for \(peer.connection.endpoint).")
                    peer.connection.cancel()
                }
                continue
            }
            if now - peer.lastReceiveTime > hostPeerSilenceTimeout {
                appendStatus("\(peer.playerName) timed out (no traffic for \(Int(hostPeerSilenceTimeout))s).")
                markHostPeerDisconnected(peer)
                peer.connection.cancel()
                hostPeers.removeValue(forKey: peer.id)
                continue
            }
            if peer.lastPingSentTime == nil || now - (peer.lastPingSentTime ?? 0) >= hostPingInterval {
                let nonce = UInt64.random(in: .min ... .max)
                peer.lastPingSentTime = now
                peer.pendingPingNonce = nonce
                send(.ping(nonce: nonce), to: peer)
            }
        }
    }

    /// Runs on the transport queue: pings the host at `clientPingInterval` and disconnects (routing
    /// through `game.handleLANConnectionLost`) if the host has gone silent for
    /// `clientSilenceTimeout` — mirrors the host's own reap policy from the client's perspective.
    private func tickClientRobustness() {
        guard let peer = clientPeer else { return }
        let now = Date.timeIntervalSinceReferenceDate
        if now - peer.lastReceiveTime > clientSilenceTimeout {
            appendStatus("LAN host connection timed out.")
            disconnectClientDueToLoss(reason: "Connection to the LAN host timed out.")
            return
        }
        if peer.lastPingSentTime == nil || now - (peer.lastPingSentTime ?? 0) >= clientPingInterval {
            let nonce = UInt64.random(in: .min ... .max)
            peer.lastPingSentTime = now
            peer.pendingPingNonce = nonce
            send(.ping(nonce: nonce), to: peer)
        }
    }

    /// A7: enforces the overall 15s connect+handshake timeout while a client connection is still
    /// in the `.connecting`/`.waiting` states (i.e. before `serverAccept` moves it to `.connected`).
    private func tickClientConnectTimeout() {
        guard let peer = clientPeer, state != .connected else { return }
        guard let deadline = clientConnectDeadline else { return }
        let now = Date.timeIntervalSinceReferenceDate
        guard now >= deadline else { return }
        appendStatus("LAN connect timed out.")
        peer.connection.cancel()
        clientPeer = nil
        clientConnectDeadline = nil
        clientWaitingSince = nil
        setState(.failed)
    }

    /// Client-side connection-loss teardown (§7.6/A6): cancels the socket, routes through the
    /// GameCore lifecycle hook (returns to title with a message, per D-I/M2) if a game world is
    /// active, and returns the transport to idle so the player can retry.
    private func disconnectClientDueToLoss(reason: String) {
        clientPeer?.connection.cancel()
        clientPeer = nil
        clientConnectDeadline = nil
        clientWaitingSince = nil
        clearReplicationHooks(for: activeGame)
        DispatchQueue.main.async { [weak self] in
            self?.activeGame?.handleLANConnectionLost(reason: reason)
        }
        setState(.idle)
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
        clientReplicationSession = LANMultiplayerClientSession()
        let now = Date.timeIntervalSinceReferenceDate
        clientConnectDeadline = now + clientConnectHandshakeTimeout
        clientWaitingSince = nil
        setState(.connecting)
        appendStatus("Connecting to \(label).")
        connection.stateUpdateHandler = { [weak self, weak peer] connState in
            guard let self, let peer else { return }
            switch connState {
            case .ready:
                self.clientWaitingSince = nil
                self.appendStatus("Connected transport to \(label); sending join request.")
                let hello = LANMultiplayerMessage.clientHello(
                    playerID: self.localPeerID,
                    playerName: sanitizedLANPlayerName(playerName),
                    joinCode: code,
                    pebbleVersion: PEBBLE_VERSION
                )
                self.send(hello, to: peer)
            case .waiting(let error):
                // A7: the connection can sit in `.waiting` indefinitely (e.g. host unreachable) —
                // surface status immediately and start a short abort timer distinct from the
                // overall connect+handshake deadline so a slow-but-progressing attempt isn't
                // killed prematurely while a truly stuck one still gets aborted.
                let now = Date.timeIntervalSinceReferenceDate
                if self.clientWaitingSince == nil {
                    self.clientWaitingSince = now
                    self.appendStatus("LAN connect waiting: \(error.localizedDescription)")
                } else if now - (self.clientWaitingSince ?? now) > self.clientWaitingAbortTimeout {
                    self.appendStatus("LAN connect aborted after \(Int(self.clientWaitingAbortTimeout))s waiting.")
                    connection.cancel()
                    self.clientPeer = nil
                    self.clientConnectDeadline = nil
                    self.clientWaitingSince = nil
                    self.setState(.failed)
                }
            case .failed(let error):
                self.clientConnectDeadline = nil
                self.clientWaitingSince = nil
                self.setState(.failed)
                self.appendStatus("LAN connect failed: \(error.localizedDescription)")
            case .cancelled:
                self.clientConnectDeadline = nil
                self.clientWaitingSince = nil
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
                self.finishHostPeerTeardown(peer)
            case .cancelled:
                self.finishHostPeerTeardown(peer)
            default:
                break
            }
        }
        receiveLoop(peer, mode: .hostPeer)
        connection.start(queue: queue)
    }

    /// Common host-side socket teardown for every disconnect path (state-handler failed/cancelled,
    /// malformed frame, receive error, silence reap). A5: a peer marked `superseded` (replaced by a
    /// newer accepted connection for the same playerID) skips `markHostPeerDisconnected` — the new
    /// socket already owns that playerID's lifecycle, so the stale socket's teardown must not mark
    /// a live, reconnected player as disconnected.
    private func finishHostPeerTeardown(_ peer: LANWirePeer) {
        guard !peer.tornDown else { return }
        peer.tornDown = true
        if !peer.superseded {
            markHostPeerDisconnected(peer)
        }
        hostPeers.removeValue(forKey: peer.id)
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
                // any successfully-received bytes reset the silence clock (§7.6) — gameplay
                // traffic alone is enough to keep a peer alive without needing a pong specifically.
                peer.lastReceiveTime = Date.timeIntervalSinceReferenceDate
                peer.buffer.append(data)
                do {
                    let frames = try LANMultiplayerFrameCodec.decodeFrames(from: &peer.buffer)
                    for frame in frames {
                        self.handle(frame, from: peer, mode: mode)
                    }
                } catch {
                    // A6: a malformed frame runs the SAME lifecycle cleanup as any other
                    // disconnect path (host: markHostPeerDisconnected via finishHostPeerTeardown;
                    // client: handleLANConnectionLost) rather than silently vanishing the peer.
                    self.appendStatus("Dropping malformed LAN peer: \(error)")
                    peer.connection.cancel()
                    switch mode {
                    case .hostPeer:
                        self.finishHostPeerTeardown(peer)
                    case .clientServer:
                        if self.clientPeer === peer {
                            self.disconnectClientDueToLoss(reason: "The LAN connection sent malformed data.")
                        }
                    }
                    return
                }
            }
            if let error {
                self.appendStatus("LAN receive failed: \(error.localizedDescription)")
                peer.connection.cancel()
                switch mode {
                case .hostPeer:
                    self.finishHostPeerTeardown(peer)
                case .clientServer:
                    if self.clientPeer === peer {
                        self.disconnectClientDueToLoss(reason: "The LAN connection was interrupted.")
                    }
                }
                return
            }
            if isComplete {
                peer.connection.cancel()
                switch mode {
                case .hostPeer:
                    self.finishHostPeerTeardown(peer)
                case .clientServer:
                    if self.clientPeer === peer {
                        self.disconnectClientDueToLoss(reason: "The LAN host closed the connection.")
                    }
                }
                return
            }
            self.receiveLoop(peer, mode: mode)
        }
    }

    private func handle(_ frame: LANMultiplayerFrame, from peer: LANWirePeer, mode: LANPeerMode) {
        switch mode {
        case .hostPeer:
            guard !isHostRateLimited(frame.message, from: peer) else { return }
            handleHostMessage(frame.message, from: peer)
        case .clientServer:
            if case .pong = frame.message { peer.pendingPingNonce = nil }
            handleClientMessage(frame.message, receivedSequence: frame.sequence, from: peer)
        }
    }

    /// §7.6/A12 rate limiting: every guest→host message category the host trusts a peer to send
    /// repeatedly is bucketed. `clientHello`/`serverAccept`/etc. (handshake/one-shot kinds) are not
    /// bucketed. Over-limit messages are dropped with a throttled (not per-drop) status line.
    private func isHostRateLimited(_ message: LANMultiplayerMessage, from peer: LANWirePeer) -> Bool {
        let now = Date.timeIntervalSinceReferenceDate
        let category: String
        let allowed: Bool
        switch message {
        case .chat:
            category = "chat"
            allowed = peer.rateLimiter.chat.tryConsume(now: now)
        case .chunkRequest:
            category = "chunkRequest"
            allowed = peer.rateLimiter.chunkRequest.tryConsume(now: now)
        case .blockIntent, .attackIntent, .tossIntent:
            category = "gameplayIntent"
            allowed = peer.rateLimiter.gameplayIntent.tryConsume(now: now)
        case .inventoryUpdate:
            category = "inventoryUpdate"
            allowed = peer.rateLimiter.inventoryUpdate.tryConsume(now: now)
        case .containerEditIntent:
            category = "containerEditIntent"
            allowed = peer.rateLimiter.containerEditIntent.tryConsume(now: now)
        case .pong:
            peer.pendingPingNonce = nil
            return false
        default:
            return false
        }
        guard !allowed else { return false }
        if peer.shouldLogThrottle(category, now: now) {
            appendStatus("Throttling \(category) from \(peer.playerName.isEmpty ? "a peer" : peer.playerName): rate limit exceeded.")
        }
        return true
    }

    private func handleHostMessage(_ message: LANMultiplayerMessage, from peer: LANWirePeer) {
        switch message {
        case .clientHello(let playerID, let playerName, let rawJoinCode, let pebbleVersion):
            let name = sanitizedLANPlayerName(playerName)
            guard normalizedLANJoinCode(rawJoinCode) == joinCode else {
                send(.serverReject(reason: "Join code rejected."), to: peer)
                peer.connection.cancel()
                appendStatus("Rejected LAN join from \(name): bad join code.")
                return
            }
            // A11: same-protocol app-version skew still gets a clean, explicit rejection (the
            // frame codec's protocol-version gate only covers wire-format compatibility).
            guard pebbleVersion == PEBBLE_VERSION else {
                send(.serverReject(reason: "Pebble version mismatch: host is \(PEBBLE_VERSION)."), to: peer)
                peer.connection.cancel()
                appendStatus("Rejected LAN join from \(name): version mismatch (\(pebbleVersion)).")
                return
            }
            guard hostPeers.values.filter({ $0.accepted }).count < LAN_MULTIPLAYER_MAX_CLIENTS else {
                send(.serverReject(reason: "LAN world is full."), to: peer)
                peer.connection.cancel()
                appendStatus("Rejected LAN join from \(name): server full.")
                return
            }
            let cleanPlayerID = String(playerID.prefix(128))
            // A5: a reconnecting playerID may still have a live (stale) accepted socket from a
            // connection the host hasn't noticed dropped yet — supersede it BEFORE registering the
            // new one so its eventual teardown does not mark the just-reconnected player as
            // disconnected.
            for existing in hostPeers.values where existing.id != peer.id && existing.accepted && existing.playerID == cleanPlayerID {
                existing.superseded = true
                existing.connection.cancel()
                hostPeers.removeValue(forKey: existing.id)
            }
            peer.accepted = true
            peer.playerID = cleanPlayerID
            peer.playerName = name
            peer.lastReceiveTime = Date.timeIntervalSinceReferenceDate
            knownHostPeerIDs.insert(cleanPlayerID)
            let summary = makeWorldSummary(playerCount: hostPeers.values.filter { $0.accepted }.count)
            send(.serverAccept(peerID: peer.playerID, world: summary), to: peer)
            DispatchQueue.main.async { [weak self, weak peer] in
                guard let self, let peer else { return }
                let tick = self.activeGame?.world.time ?? 0
                let disposition = self.hostReplicationSession.acceptPeer(playerID: peer.playerID, displayName: peer.playerName, tick: tick)
                // §7.3: a restore-eligible peer (known lan_players record or a still-tracked live
                // session) gets its authoritative state BEFORE the first replication snapshot so
                // the client adopts position/inventory/revision/grant baselines in the right order.
                if let restore = self.hostReplicationSession.peerRestoreState(playerID: peer.playerID) {
                    self.queue.async { [weak self] in
                        guard let self, let peer = self.hostPeers[peer.id], peer.accepted else { return }
                        self.send(.restoreState(restore), to: peer)
                    }
                }
                self.sendInitialReplicationSnapshot(to: peer.id)
                let eventKind: LANGameplayEventKind = disposition == .reconnected ? .peerReconnected : .peerJoined
                let event = LANGameplayEvent(
                    playerID: peer.playerID,
                    kind: eventKind,
                    message: "\(peer.playerName) \(disposition == .reconnected ? "reconnected" : "joined") the LAN world.",
                    tick: tick
                )
                self.queue.async { [weak self] in
                    self?.broadcastFromHost(.gameplayEvent(event), except: peer.id)
                }
            }
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
        case .playerState(let state):
            guard peer.accepted else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                var currentDimension: Int?
                var tick = 0
                var keepInventory = false
                if let game = self.activeGame, game.hasWorld() {
                    currentDimension = game.world.dim.rawValue
                    tick = game.world.time
                    keepInventory = game.world.rule("keepInventory")
                }
                let sanitized = self.hostReplicationSession.updatePlayerState(
                    state,
                    currentDimension: currentDimension,
                    tick: tick,
                    keepInventory: keepInventory
                )
                if let game = self.activeGame, game.hasWorld() {
                    _ = applyLANRemotePlayers(
                        self.hostReplicationSession.peerPlayerStates(),
                        to: game.world,
                        localPlayerID: self.localPeerID,
                        inventorySnapshots: self.hostReplicationSession.peerInventorySnapshotsByPlayerID()
                    )
                }
                guard let sanitized else { return }
                self.queue.async { [weak self] in
                    self?.broadcastFromHost(.playerState(sanitized), except: peer.id)
                }
            }
        case .blockIntent(_, let intent):
            guard peer.accepted else { return }
            applyHostBlockIntent(intent, from: peer.playerID, peerName: peer.playerName)
        case .containerIntent(_, let intent):
            guard peer.accepted else { return }
            applyHostContainerIntent(intent, from: peer.playerID, peerID: peer.id, peerName: peer.playerName)
        case .templateIntent(_, let intent):
            guard peer.accepted else { return }
            applyHostTemplateIntent(intent, from: peer.playerID, peerID: peer.id, peerName: peer.playerName)
        case .attackIntent(_, let intent):
            guard peer.accepted else { return }
            applyHostAttackIntent(intent, from: peer.playerID, peerName: peer.playerName)
        case .tossIntent(_, let intent):
            guard peer.accepted else { return }
            applyHostTossIntent(intent, from: peer.playerID, peerName: peer.playerName)
        case .containerEditIntent(_, let intent):
            guard peer.accepted else { return }
            applyHostContainerEditIntent(intent, from: peer.playerID, peerName: peer.playerName)
        case .inventoryUpdate(let update):
            guard peer.accepted, update.playerID == peer.playerID else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                _ = self.hostReplicationSession.applyInventoryUpdate(update, from: peer.playerID)
            }
        case .replicationAck(_, let ack):
            guard peer.accepted else { return }
            DispatchQueue.main.async { [weak self] in
                self?.hostReplicationSession.recordAck(ack, from: peer.playerID)
            }
        case .chunkRequest(_, let request):
            guard peer.accepted else { return }
            sendChunkSnapshot(to: peer.id, request: request)
        default:
            guard peer.accepted else { return }
            appendStatus("LAN host received \(message.kind) from \(peer.playerName); no authoritative handler was needed.")
        }
    }

    private func handleClientMessage(_ message: LANMultiplayerMessage, receivedSequence: UInt32, from peer: LANWirePeer) {
        switch message {
        case .serverAccept(_, let world):
            clientConnectDeadline = nil
            clientWaitingSince = nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setState(.connected)
                if let game = self.activeGame, !game.hasWorld() {
                    self.configureClientReplicationHooks(for: game)
                    game.enterLANClientWorld(world)
                    game.host?.capturePointer()
                    self.appendStatus("Entered LAN client world \"\(world.worldName)\".")
                } else if self.activeGame == nil {
                    self.appendStatus("LAN join accepted, but no active game was attached for world entry.")
                }
                self.appendStatus("Joined LAN world \"\(world.worldName)\" with \(world.playerCount)/\(world.maxPlayers) players.")
                self.postChat("§b[LAN] Connected to \"\(world.worldName)\".")
            }
        case .serverReject(let reason):
            clientConnectDeadline = nil
            clientWaitingSince = nil
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
            disconnectClientDueToLoss(reason: sanitizedLANChatText(reason))
        case .playerState(let state):
            DispatchQueue.main.async { [weak self] in
                let batch = LANReplicationBatch(tick: 0, fullSnapshot: false, players: [state])
                _ = self?.clientReplicationSession.apply(batch)
                if let self, let game = self.activeGame, game.hasWorld() {
                    _ = applyLANRemotePlayers([state], to: game.world, localPlayerID: self.localPeerID, removeMissing: false)
                }
            }
        case .replicationBatch(let batch):
            handleClientReplicationBatch(batch, receivedSequence: receivedSequence, from: peer)
        case .gameplayEvent(let event):
            handleGameplayEvent(event)
        case .restoreState(let restore):
            clientReplicationSession.applyRestore(restore)
            DispatchQueue.main.async { [weak self] in
                self?.activeGame?.applyLANRestore(restore)
            }
        case .inventoryGrant(let grant):
            guard grant.playerID == localPeerID else { return }
            guard clientReplicationSession.markGrantApplied(grant.grantID) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.activeGame?.applyLANGrant(grant)
            }
        case .damageEvent(let event):
            guard event.playerID == localPeerID else { return }
            DispatchQueue.main.async { [weak self] in
                self?.activeGame?.applyLANDamage(event)
            }
        default:
            appendStatus("LAN client received \(message.kind); no client-side handler was needed.")
        }
    }

    /// Message categories the §7.7 backpressure policy is allowed to skip when a peer's in-flight
    /// send depth exceeds `backpressureDeltaSkipDepth`. Only non-authoritative, superseded-by-the-
    /// next-batch delta traffic qualifies — every other kind (full snapshots, initial snapshot,
    /// chunk replies, restore, grants, damage, gameplay events, chat) is never skipped.
    private func isSkippableDeltaBatch(_ message: LANMultiplayerMessage) -> Bool {
        if case .replicationBatch(let batch) = message, !batch.fullSnapshot {
            return batch.blockChanges.isEmpty && batch.chunkSections.isEmpty && batch.blockEntities.isEmpty
        }
        return false
    }

    private func shouldSkipSkippableDelta(_ message: LANMultiplayerMessage, for peer: LANWirePeer) -> Bool {
        guard isSkippableDeltaBatch(message) else { return false }
        return peer.inFlightSendCount > backpressureDeltaSkipDepth ||
            peer.inFlightSendBytes > backpressureDeltaSkipBytes
    }

    /// Encodes `message`'s JSON payload exactly once (§7.1) and frames+sends it to `peer`, honoring
    /// backpressure (§7.7): a peer with more than `backpressureDeltaSkipDepth` sends already in
    /// flight has its non-authoritative delta batches skipped rather than queued further behind.
    private func send(_ message: LANMultiplayerMessage, to peer: LANWirePeer) {
        if shouldSkipSkippableDelta(message, for: peer) { return }
        do {
            let (kind, payload) = try LANMultiplayerFrameCodec.encodePayload(message)
            sendFramedPayload(kind: kind, payload: payload, to: peer)
        } catch {
            appendStatus("LAN encode failed: \(error)")
        }
    }

    /// Wraps an already-encoded payload with `peer`'s next sequence number and hands it to the
    /// connection, tracking in-flight depth for backpressure accounting.
    private func sendFramedPayload(kind: LANMultiplayerMessageKind, payload: Data, to peer: LANWirePeer) {
        let frame = LANMultiplayerFrameCodec.frame(kind: kind, payload: payload, sequence: peer.nextSequence)
        peer.nextSequence &+= 1
        peer.inFlightSendCount += 1
        peer.inFlightSendBytes += frame.count
        peer.connection.send(content: frame, completion: .contentProcessed { [weak self, weak peer] error in
            peer?.inFlightSendCount = max(0, (peer?.inFlightSendCount ?? 1) - 1)
            peer?.inFlightSendBytes = max(0, (peer?.inFlightSendBytes ?? frame.count) - frame.count)
            if let error {
                self?.appendStatus("LAN send failed: \(error.localizedDescription)")
                peer?.connection.cancel()
            }
        })
    }

    /// Broadcasts a host-originated replication batch honoring amendment A4 (never lose drained
    /// deltas) and §10 (never silently drop an oversized full/chunk-reply frame). `drainedBlockChanges`
    /// are the change-log entries already consumed to build `batch` (empty for full snapshots,
    /// which read the log via `peek` and never drain it) — on ANY encode failure they are requeued
    /// via `session.requeueBlockChanges` so the next tick's batch picks them back up.
    ///
    /// For a full-snapshot/chunk-reply batch whose payload is oversized, the batch is retried
    /// without its chunk sections (players/entities/BEs first), then the sections are re-sent in
    /// follow-up batches whose section count is halved each attempt (down to 1/frame) — the
    /// sections are never dropped, only deferred to more, smaller frames.
    private func broadcastHostReplicationBatch(
        _ batch: LANReplicationBatch,
        drainedBlockChanges: [LANBlockChange],
        drainedDirtyBlockEntities: [LANBlockPosition] = [],
        to peerID: UUID? = nil,
        priority: LANReplicationSendPriority = .interactive
    ) {
        do {
            let (kind, payload) = try LANMultiplayerFrameCodec.encodePayload(.replicationBatch(batch))
            let sent = dispatchEncodedReplicationPayload(
                kind: kind,
                payload: payload,
                to: peerID,
                skipWhenBackpressured: priority == .background && isSkippableDeltaBatch(.replicationBatch(batch))
            )
            if sent == 0, !drainedBlockChanges.isEmpty {
                hostReplicationSession.requeueBlockChanges(drainedBlockChanges)
            }
            if sent == 0, !drainedDirtyBlockEntities.isEmpty {
                hostReplicationSession.requeueDirtyBlockEntities(drainedDirtyBlockEntities)
            }
        } catch LANMultiplayerCodecError.oversizedFrame where !batch.chunkSections.isEmpty {
            if !drainedBlockChanges.isEmpty {
                hostReplicationSession.requeueBlockChanges(drainedBlockChanges)
            }
            var withoutSections = batch
            withoutSections.chunkSections = []
            do {
                let (kind, payload) = try LANMultiplayerFrameCodec.encodePayload(.replicationBatch(withoutSections))
                let sent = dispatchEncodedReplicationPayload(
                    kind: kind,
                    payload: payload,
                    to: peerID,
                    skipWhenBackpressured: priority == .background && isSkippableDeltaBatch(.replicationBatch(withoutSections))
                )
                if sent == 0, !drainedDirtyBlockEntities.isEmpty {
                    hostReplicationSession.requeueDirtyBlockEntities(drainedDirtyBlockEntities)
                }
            } catch {
                if !drainedDirtyBlockEntities.isEmpty {
                    hostReplicationSession.requeueDirtyBlockEntities(drainedDirtyBlockEntities)
                }
                appendStatus("LAN encode failed even without chunk sections: \(error)")
            }
            for sectionBatch in lanHalvedChunkSectionBatches(batch.chunkSections) {
                sendSplitChunkSectionBatch(sectionBatch, tick: batch.tick, to: peerID, priority: priority)
            }
        } catch {
            if !drainedBlockChanges.isEmpty {
                hostReplicationSession.requeueBlockChanges(drainedBlockChanges)
            }
            if !drainedDirtyBlockEntities.isEmpty {
                hostReplicationSession.requeueDirtyBlockEntities(drainedDirtyBlockEntities)
            }
            appendStatus("LAN encode failed: \(error)")
        }
    }

    /// Sends one halved slice of chunk sections as its own minimal replication batch, recursively
    /// halving further if that slice is STILL oversized (pathological RLE worst case) down to the
    /// single-section floor `lanHalvedChunkSectionBatches` already provides; a single section that
    /// still can't fit is logged and dropped (documented last resort — a section over 1 MiB after
    /// RLE would mean cap-violating input, which `isValidRLE` should already have rejected upstream).
    private func sendSplitChunkSectionBatch(
        _ sections: [LANChunkSectionSnapshot],
        tick: Int,
        to peerID: UUID?,
        priority: LANReplicationSendPriority
    ) {
        let batch = LANReplicationBatch(tick: tick, fullSnapshot: true, chunkSections: sections)
        do {
            let (kind, payload) = try LANMultiplayerFrameCodec.encodePayload(.replicationBatch(batch))
            _ = dispatchEncodedReplicationPayload(
                kind: kind,
                payload: payload,
                to: peerID,
                skipWhenBackpressured: priority == .background && isSkippableDeltaBatch(.replicationBatch(batch))
            )
        } catch LANMultiplayerCodecError.oversizedFrame where sections.count > 1 {
            for smaller in lanHalvedChunkSectionBatches(sections) {
                sendSplitChunkSectionBatch(smaller, tick: tick, to: peerID, priority: priority)
            }
        } catch {
            appendStatus("LAN split chunk section batch still oversized/failed: \(error)")
        }
    }

    @discardableResult
    private func dispatchEncodedReplicationPayload(
        kind: LANMultiplayerMessageKind,
        payload: Data,
        to peerID: UUID?,
        skipWhenBackpressured: Bool
    ) -> Int {
        var sent = 0
        if let peerID {
            guard let peer = hostPeers[peerID], peer.accepted else { return 0 }
            if skipWhenBackpressured && peer.inFlightSendCount > backpressureDeltaSkipDepth { return sent }
            if skipWhenBackpressured && peer.inFlightSendBytes > backpressureDeltaSkipBytes { return sent }
            sendFramedPayload(kind: kind, payload: payload, to: peer)
            sent += 1
        } else {
            for peer in hostPeers.values where peer.accepted {
                if skipWhenBackpressured && peer.inFlightSendCount > backpressureDeltaSkipDepth { continue }
                if skipWhenBackpressured && peer.inFlightSendBytes > backpressureDeltaSkipBytes { continue }
                sendFramedPayload(kind: kind, payload: payload, to: peer)
                sent += 1
            }
        }
        return sent
    }

    /// Fans `message` out to every accepted host peer (except `excludedPeerID`) with a single JSON
    /// encode (§7.1) shared across all recipients — only the 16-byte header is rebuilt per peer.
    private func broadcastFromHost(_ message: LANMultiplayerMessage, except excludedPeerID: UUID? = nil) {
        let recipients = hostPeers.values.filter { $0.accepted && $0.id != excludedPeerID }
        guard !recipients.isEmpty else { return }
        let eligibleRecipients = recipients.filter { !shouldSkipSkippableDelta(message, for: $0) }
        guard !eligibleRecipients.isEmpty else { return }
        do {
            let (kind, payload) = try LANMultiplayerFrameCodec.encodePayload(message)
            for peer in eligibleRecipients {
                sendFramedPayload(kind: kind, payload: payload, to: peer)
            }
        } catch {
            appendStatus("LAN encode failed: \(error)")
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

    private func makeHostReplicationBatch(
        game: GameCore,
        player: Player,
        fullSnapshot: Bool,
        chunkSectionsOverride: [LANChunkSectionSnapshot]? = nil,
        content: LANHostReplicationContent,
        drainedDirtyBlockEntities: inout [LANBlockPosition]
    ) -> LANReplicationBatch? {
        guard game.hasWorld() else { return nil }
        let acceptedCount = queue.sync { hostPeers.values.filter { $0.accepted }.count }
        // D-A: proxy inventory is now fed FROM the peer record (client-published) for other
        // peers' held-item display only — it is never scraped back INTO the peer record. The
        // former `makeLANRemotePlayerInventorySnapshots(in:) -> recordInventorySnapshot` loop
        // that lived here caused the rubber-band bug (C6) and has been removed.
        _ = applyLANRemotePlayers(
            hostReplicationSession.peerPlayerStates(),
            to: game.world,
            localPlayerID: localPeerID,
            inventorySnapshots: hostReplicationSession.peerInventorySnapshotsByPlayerID()
        )
        let localState = makeLANPlayerState(player, playerID: localPeerID, displayName: NSFullUserName(), dimension: game.dim.rawValue)
        let peerStates = hostReplicationSession.peerPlayerStates()
        // D-G: dirty block entities (container edits, ghost break spills, active furnaces/hoppers)
        // are replicated FIRST, ahead of the normal distance-prioritized fill, so a guest's edit
        // or a spilling container is never starved out by a busy world.
        let dirtyPositions = content.includeDirtyBlockEntities ? hostReplicationSession.drainDirtyBlockEntities() : []
        drainedDirtyBlockEntities.append(contentsOf: dirtyPositions)
        var dirtyBlockEntities: [LANBlockEntitySnapshot] = []
        dirtyBlockEntities.reserveCapacity(dirtyPositions.count)
        for position in dirtyPositions where position.dimension == game.world.dim.rawValue {
            guard let be = game.world.getBlockEntity(position.x, position.y, position.z),
                  let snapshot = makeLANBlockEntitySnapshot(be, dimension: position.dimension)
            else { continue }
            dirtyBlockEntities.append(snapshot)
        }
        var chunks = chunkSectionsOverride ?? []
        if chunkSectionsOverride == nil, content.includeDirtyChunkSections {
            chunks.append(contentsOf: hostReplicationSession.drainDirtyChunkSectionSnapshots(in: game.world))
        }
        let entityFocus = ([localState] + peerStates)
            .filter { $0.dimension == game.world.dim.rawValue }
            .map { (x: $0.x, z: $0.z) }
        let entities = content.includeEntities
            ? makeLANEntitySnapshots(in: game.world, around: entityFocus, radius: content.entityRadius)
            : []
        let inventories = content.includeInventories ? [makeLANInventorySnapshot(player, playerID: localPeerID)] : []
        let blockEntityFocus = ([localState] + peerStates)
            .filter { $0.dimension == game.world.dim.rawValue }
            .map { (x: $0.x, z: $0.z) }
        var dirtyPositionSet = Set<LANBlockPosition>()
        for be in dirtyBlockEntities {
            dirtyPositionSet.insert(LANBlockPosition(dimension: be.dimension, x: be.x, y: be.y, z: be.z))
        }
        let dirtyLimit = LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES
        var blockEntities = Array(dirtyBlockEntities.prefix(dirtyLimit))
        if content.includeBlockEntityFill {
            let fillCap = max(0, min(content.blockEntityFillCap, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES))
            if blockEntities.count < fillCap {
                let remainingCap = fillCap - blockEntities.count
                let fillBlockEntities = makeLANBlockEntitySnapshots(
                    in: game.world,
                    prioritizedAround: blockEntityFocus,
                    maxCount: remainingCap + dirtyPositionSet.count
                ).filter { !dirtyPositionSet.contains(LANBlockPosition(dimension: $0.dimension, x: $0.x, y: $0.y, z: $0.z)) }
                blockEntities.append(contentsOf: fillBlockEntities.prefix(remainingCap))
            }
        }
        let summary = content.includeWorldSummary ? makeWorldSummary(playerCount: acceptedCount) : nil
        let worldState = content.includeWorldState ? makeLANWorldStateSnapshot(in: game.world) : nil
        return hostReplicationSession.makeBatch(
            tick: game.world.time,
            fullSnapshot: fullSnapshot,
            worldSummary: summary,
            worldState: worldState,
            localPlayer: localState,
            chunkSections: chunks,
            entitySnapshots: entities,
            entitySnapshotsComplete: content.entitySnapshotsComplete && entities.count < LAN_MULTIPLAYER_MAX_REPLICATION_ENTITIES,
            inventorySnapshots: inventories,
            blockEntitySnapshots: blockEntities,
            includePeerInventories: content.includeInventories
        )
    }

    private func sendInitialReplicationSnapshot(to peerID: UUID) {
        guard Thread.isMainThread,
              let game = activeGame,
              game.hasWorld(),
              let player = game.player
        else { return }
        let peerPlayerID = queue.sync { hostPeers[peerID]?.playerID }
        let restoreState = peerPlayerID.flatMap { hostReplicationSession.peerRecord(playerID: $0)?.playerState }
        let centerDimension = game.world.dim.rawValue
        let restoredInCurrentDimension = restoreState?.dimension == centerDimension
        let centerX = restoredInCurrentDimension ? (restoreState?.x ?? game.world.spawnX) : game.world.spawnX
        let centerY = restoredInCurrentDimension ? (restoreState?.y ?? game.world.spawnY) : game.world.spawnY
        let centerZ = restoredInCurrentDimension ? (restoreState?.z ?? game.world.spawnZ) : game.world.spawnZ
        let spawnRequest = LANChunkRequest(
            dimension: centerDimension,
            cx: floorDiv(Int(centerX.rounded(.down)), CHUNK_W),
            cz: floorDiv(Int(centerZ.rounded(.down)), CHUNK_W),
            radius: LAN_MULTIPLAYER_DEFAULT_CHUNK_REQUEST_RADIUS,
            centerY: Int(centerY.rounded(.down)),
            verticalRadius: LAN_MULTIPLAYER_DEFAULT_CHUNK_VERTICAL_RADIUS
        )
        for coord in orderedLANChunkRequestCoordinates(cx: spawnRequest.cx, cz: spawnRequest.cz, radius: spawnRequest.radius) {
            _ = game.ensureAuthoritativeLANChunkLoaded(dimension: spawnRequest.dimension, cx: coord.cx, cz: coord.cz)
        }
        let spawnChunks = makeLANChunkSectionSnapshots(for: spawnRequest, in: game.world)
        var dirtyBlockEntities: [LANBlockPosition] = []
        guard let batch = makeHostReplicationBatch(
            game: game,
            player: player,
            fullSnapshot: true,
            chunkSectionsOverride: spawnChunks,
            content: .initialSnapshot,
            drainedDirtyBlockEntities: &dirtyBlockEntities
        ) else { return }
        queue.async { [weak self] in
            guard let self, let peer = self.hostPeers[peerID], peer.accepted else { return }
            self.broadcastHostReplicationBatch(
                batch,
                drainedBlockChanges: [],
                drainedDirtyBlockEntities: dirtyBlockEntities,
                to: peer.id
            )
        }
    }

    private func applyHostBlockIntent(_ intent: LANBlockIntent, from playerID: String, peerName: String) {
        switch intent.action {
        case .breakBlock:
            applyHostBreakBlockIntent(intent, from: playerID, peerName: peerName)
        case .placeBlock:
            applyHostPlaceBlockIntent(intent, from: playerID, peerName: peerName)
        case .useBlock:
            DispatchQueue.main.async { [weak self] in
                guard let self, let game = self.activeGame, game.hasWorld() else { return }
                let result = self.hostReplicationSession.applyBlockIntent(intent, from: playerID, to: game.world)
                self.reportBlockIntentResult(result, playerID: playerID, peerName: peerName, tick: game.world.time)
            }
        }
    }

    /// §7.2: `.breakBlock` routes through `LANHostGhostRegistry.applyBreak` (NOT bare
    /// `applyBlockIntent`) so the real singleplayer `finishBreaking` routine spawns drops/XP and
    /// consumes tool durability. `applyBreak` itself only checks the target isn't already air — the
    /// reach/authorize preconditions `applyBlockIntent` would have enforced are done explicitly
    /// here first (mirroring its exact validation order) so a break can't bypass them.
    private func applyHostBreakBlockIntent(_ intent: LANBlockIntent, from playerID: String, peerName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let game = self.activeGame, game.hasWorld() else { return }
            let world = game.world
            switch self.hostReplicationSession.authorize(.build, from: playerID) {
            case .rejected(let reason):
                self.reportBlockIntentRejected(reason, playerID: playerID, peerName: peerName, tick: world.time)
                return
            case .accepted:
                break
            }
            guard let record = self.hostReplicationSession.peerRecord(playerID: playerID), let playerState = record.playerState else {
                self.reportBlockIntentRejected("player state unavailable", playerID: playerID, peerName: peerName, tick: world.time)
                return
            }
            guard playerState.dimension == world.dim.rawValue else {
                self.reportBlockIntentRejected("target dimension unavailable", playerID: playerID, peerName: peerName, tick: world.time)
                return
            }
            guard isWithinLANReach(playerState, x: intent.x, y: intent.y, z: intent.z) else {
                self.reportBlockIntentRejected("target out of reach", playerID: playerID, peerName: peerName, tick: world.time)
                return
            }
            let beforeInventory = record.inventory
            let outcome = self.hostGhostRegistry.applyBreak(for: playerID, x: intent.x, y: intent.y, z: intent.z, world: world, session: self.hostReplicationSession)
            guard outcome.broke else {
                if let reason = outcome.reason {
                    self.appendStatus("LAN break intent from \(peerName) ignored: \(reason).")
                }
                return
            }
            self.hostReplicationSession.recordInventorySnapshot(outcome.inventory, from: playerID)
            self.sendInventoryDeltaGrantIfNeeded(before: beforeInventory, after: outcome.inventory, playerID: playerID)
            // the block change itself was already captured via `onWorldBlockChanged` ->
            // `recordBlockChange` (world.setBlock fires that hook during finishBreaking) — drain
            // and broadcast it promptly rather than waiting for the next periodic tick.
            let changes = self.hostReplicationSession.drainBlockChanges()
            guard !changes.isEmpty else { return }
            let batch = LANReplicationBatch(tick: world.time, fullSnapshot: false, blockChanges: changes)
            self.queue.async { [weak self] in
                self?.broadcastHostReplicationBatch(batch, drainedBlockChanges: changes)
            }
        }
    }

    /// `.placeBlock` keeps the existing `session.applyBlockIntent` world-mutation path (reach/
    /// authorization/replacement checks already implemented there) via `LANHostGhostRegistry.applyPlace`,
    /// which wraps it and additionally decrements one matching item from the peer's stored
    /// inventory (ghost/peer inventory decrement, §7.2).
    private func applyHostPlaceBlockIntent(_ intent: LANBlockIntent, from playerID: String, peerName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let game = self.activeGame, game.hasWorld() else { return }
            let world = game.world
            guard let record = self.hostReplicationSession.peerRecord(playerID: playerID) else { return }
            let beforeInventory = record.inventory
            let outcome = self.hostGhostRegistry.applyPlace(for: playerID, intent: intent, world: world, session: self.hostReplicationSession)
            guard outcome.placed else {
                if let reason = outcome.reason {
                    self.appendStatus("LAN place intent from \(peerName) ignored/rejected: \(reason).")
                }
                return
            }
            self.hostReplicationSession.recordInventorySnapshot(outcome.inventory, from: playerID)
            self.sendInventoryDeltaGrantIfNeeded(before: beforeInventory, after: outcome.inventory, playerID: playerID)
            let changes = self.hostReplicationSession.drainBlockChanges()
            guard !changes.isEmpty else { return }
            let batch = LANReplicationBatch(tick: world.time, fullSnapshot: false, blockChanges: changes)
            self.queue.async { [weak self] in
                self?.broadcastHostReplicationBatch(batch, drainedBlockChanges: changes)
            }
        }
    }

    private func reportBlockIntentResult(_ result: LANBlockIntentResult, playerID: String, peerName: String, tick: Int) {
        switch result {
        case .applied(let changes):
            let batch = LANReplicationBatch(tick: tick, fullSnapshot: false, blockChanges: changes)
            self.queue.async { [weak self] in
                self?.broadcastHostReplicationBatch(batch, drainedBlockChanges: changes)
            }
        case .ignored(let reason):
            appendStatus("LAN block intent from \(peerName) ignored: \(reason).")
        case .rejected(let reason):
            reportBlockIntentRejected(reason, playerID: playerID, peerName: peerName, tick: tick)
        }
    }

    private func reportBlockIntentRejected(_ reason: String, playerID: String, peerName: String, tick: Int) {
        appendStatus("LAN block intent from \(peerName) rejected: \(reason).")
        let event = LANGameplayEvent(playerID: playerID, kind: .permissionDenied, message: reason, tick: tick)
        queue.async { [weak self] in self?.sendGameplayEvent(event, to: nil) }
    }

    /// §7.2: `.attackIntent` → `ghostRegistry.applyAttack` (real `playerAttack` routine — durability/
    /// crit/sweeping/etc all flow through the exact singleplayer path); a durability delta on the
    /// ghost's inventory (post-attack) is relayed as an additive correction grant.
    private func applyHostAttackIntent(_ intent: LANAttackIntent, from playerID: String, peerName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let game = self.activeGame, game.hasWorld() else { return }
            guard let record = self.hostReplicationSession.peerRecord(playerID: playerID) else { return }
            let beforeInventory = record.inventory
            let outcome = self.hostGhostRegistry.applyAttack(for: playerID, targetEntityID: intent.targetEntityID, world: game.world, session: self.hostReplicationSession)
            guard outcome.attacked else {
                if let reason = outcome.reason {
                    self.appendStatus("LAN attack intent from \(peerName) rejected: \(reason).")
                }
                return
            }
            self.hostReplicationSession.recordInventorySnapshot(outcome.inventory, from: playerID)
            self.sendInventoryDeltaGrantIfNeeded(before: beforeInventory, after: outcome.inventory, playerID: playerID)
        }
    }

    /// §7.2: `.tossIntent` → `ghostRegistry.applyToss` (removes items from the stored peer
    /// inventory and authoritatively spawns them into the shared world); any mismatch between the
    /// client's optimistic local decrement and the host's authoritative result is corrected via
    /// the same additive grant mechanism.
    private func applyHostTossIntent(_ intent: LANTossIntent, from playerID: String, peerName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let game = self.activeGame, game.hasWorld() else { return }
            guard let record = self.hostReplicationSession.peerRecord(playerID: playerID) else { return }
            let beforeInventory = record.inventory
            let outcome = self.hostGhostRegistry.applyToss(for: playerID, intent: intent, world: game.world, session: self.hostReplicationSession)
            guard outcome.tossed else {
                if let reason = outcome.reason {
                    self.appendStatus("LAN toss intent from \(peerName) rejected: \(reason).")
                }
                return
            }
            self.hostReplicationSession.recordInventorySnapshot(outcome.inventory, from: playerID)
            self.sendInventoryDeltaGrantIfNeeded(before: beforeInventory, after: outcome.inventory, playerID: playerID)
        }
    }

    /// §7.2: `.containerEditIntent` → `session.applyContainerEditIntent`; on success the resulting
    /// BE snapshot is immediately re-broadcast to ALL peers in its own small batch (D-C: closes the
    /// concurrent-edit window to ~1 RTT) rather than waiting for the next periodic replication tick.
    private func applyHostContainerEditIntent(_ intent: LANContainerEditIntent, from playerID: String, peerName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let game = self.activeGame, game.hasWorld() else { return }
            let result = self.hostReplicationSession.applyContainerEditIntent(intent, from: playerID, to: game.world)
            switch result {
            case .applied(let blockEntities):
                let batch = LANReplicationBatch(tick: game.world.time, fullSnapshot: false, blockEntities: blockEntities)
                self.queue.async { [weak self] in
                    self?.broadcastFromHost(.replicationBatch(batch))
                }
            case .rejected(let reason):
                self.appendStatus("LAN container edit from \(peerName) rejected: \(reason).")
                let event = LANGameplayEvent(playerID: playerID, kind: .permissionDenied, message: reason, tick: game.world.time)
                self.queue.async { [weak self] in self?.sendGameplayEvent(event, to: nil) }
            }
        }
    }

    /// Diffs a ghost-driven outcome's resulting inventory against the peer's inventory as it stood
    /// immediately before the intent, and — if anything changed (durability consumed, items
    /// removed by a break/attack/toss/place) — enqueues an additive correction grant so the guest's
    /// client-authoritative inventory converges with the host's authoritative result. Grants are
    /// Sends a ghost-driven inventory correction as ABSOLUTE per-slot deltas: only the slots the
    /// intent actually changed are replaced (`slots`) or emptied (`clearedSlots`) on the client,
    /// preserving the guest's inventory arrangement and any concurrent client-side edits to other
    /// slots. Slot-set semantics are idempotent, so a replayed grant converges to the same state.
    private func sendInventoryDeltaGrantIfNeeded(before: LANPlayerInventorySnapshot?, after: LANPlayerInventorySnapshot, playerID: String) {
        guard before != after else { return }
        var beforeBySlot: [Int: LANInventorySlotSnapshot] = [:]
        for slot in before?.slots ?? [] { beforeBySlot[slot.slot] = slot }
        var changedSlots: [LANInventorySlotSnapshot] = []
        var seenSlots = Set<Int>()
        for slot in after.slots {
            seenSlots.insert(slot.slot)
            if beforeBySlot[slot.slot] != slot {
                changedSlots.append(slot)
            }
        }
        let clearedSlots = beforeBySlot.keys.filter { !seenSlots.contains($0) }.sorted()
        guard !changedSlots.isEmpty || !clearedSlots.isEmpty else { return }
        guard let grant = hostReplicationSession.enqueueGrant(
            items: [],
            xp: 0,
            clearAll: false,
            to: playerID,
            slots: changedSlots,
            clearedSlots: clearedSlots
        ) else { return }
        queue.async { [weak self] in
            guard let self, let peer = self.hostPeers.values.first(where: { $0.accepted && $0.playerID == playerID }) else { return }
            self.send(.inventoryGrant(grant), to: peer)
        }
    }

    private func applyHostContainerIntent(_ intent: LANContainerIntent, from playerID: String, peerID: UUID, peerName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let game = self.activeGame, game.hasWorld() else { return }
            let result = self.hostReplicationSession.authorizeContainerIntent(intent, from: playerID)
            switch result {
            case .accepted(let action):
                let event = LANGameplayEvent(playerID: playerID, kind: .intentAccepted, message: "container \(action)", tick: game.world.time)
                self.queue.async { [weak self] in self?.sendGameplayEvent(event, to: peerID) }
            case .rejected(let reason):
                self.appendStatus("LAN container intent from \(peerName) rejected: \(reason).")
                let event = LANGameplayEvent(playerID: playerID, kind: .permissionDenied, message: reason, tick: game.world.time)
                self.queue.async { [weak self] in self?.sendGameplayEvent(event, to: peerID) }
            }
        }
    }

    private func applyHostTemplateIntent(_ intent: LANTemplateIntent, from playerID: String, peerID: UUID, peerName: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let game = self.activeGame, game.hasWorld() else { return }
            let result = self.hostReplicationSession.applyTemplateIntent(
                intent,
                from: playerID,
                world: game.world,
                loadTemplate: { try game.db.getTemplate(named: $0) },
                saveTemplate: { try game.db.putTemplate($0) }
            )
            switch result {
            case .copied(let name, let blocks):
                let event = LANGameplayEvent(playerID: playerID, kind: .intentAccepted, message: "copied \(name) (\(blocks) blocks)", tick: game.world.time)
                self.queue.async { [weak self] in self?.sendGameplayEvent(event, to: peerID) }
            case .placed(let name, let blocks, let blockEntities, let cleared, let filled):
                let event = LANGameplayEvent(
                    playerID: playerID,
                    kind: .intentAccepted,
                    message: "placed \(name) (\(blocks) blocks, \(blockEntities) block entities, cleared \(cleared), filled \(filled))",
                    tick: game.world.time
                )
                let placedChanges = self.hostReplicationSession.drainBlockChanges()
                let placedSections = self.hostReplicationSession.drainDirtyChunkSectionSnapshots(in: game.world)
                let batch = LANReplicationBatch(tick: game.world.time, fullSnapshot: false,
                                                blockChanges: placedChanges,
                                                chunkSections: placedSections)
                self.queue.async { [weak self] in
                    self?.broadcastHostReplicationBatch(batch, drainedBlockChanges: placedChanges)
                    self?.sendGameplayEvent(event, to: peerID)
                }
            case .undone(let name, let restored):
                let event = LANGameplayEvent(playerID: playerID, kind: .intentAccepted, message: "undid \(name) (\(restored) cells)", tick: game.world.time)
                let undoneChanges = self.hostReplicationSession.drainBlockChanges()
                let undoneSections = self.hostReplicationSession.drainDirtyChunkSectionSnapshots(in: game.world)
                let batch = LANReplicationBatch(tick: game.world.time, fullSnapshot: false,
                                                blockChanges: undoneChanges,
                                                chunkSections: undoneSections)
                self.queue.async { [weak self] in
                    self?.broadcastHostReplicationBatch(batch, drainedBlockChanges: undoneChanges)
                    self?.sendGameplayEvent(event, to: peerID)
                }
            case .rejected(let reason):
                self.appendStatus("LAN template intent from \(peerName) rejected: \(reason).")
                let event = LANGameplayEvent(playerID: playerID, kind: .permissionDenied, message: reason, tick: game.world.time)
                self.queue.async { [weak self] in self?.sendGameplayEvent(event, to: peerID) }
            }
        }
    }

    /// A2: serves chunk requests for the GUEST's dimension, not just the host's current one —
    /// resolves `request.dimension` to its own `World` via `game.worldFor(dimension:)` and builds
    /// every section/BE/world-state field from THAT world, so a guest who travels to a different
    /// dimension than the host is currently in still gets correct chunk data (previously guests
    /// resumed in a different dimension saw void — fleet-critical).
    private func sendChunkSnapshot(to peerID: UUID, request: LANChunkRequest) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let game = self.activeGame,
                  game.hasWorld(),
                  let requestWorld = game.worldFor(dimension: request.dimension)
            else { return }
            var syncGenerations = 0
            for coord in orderedLANChunkRequestCoordinates(cx: request.cx, cz: request.cz, radius: request.radius) {
                let missing = requestWorld.getChunk(coord.cx, coord.cz) == nil
                if missing, syncGenerations >= LAN_MAX_SYNC_CHUNK_GENERATIONS_PER_REQUEST { continue }
                if missing { syncGenerations += 1 }
                _ = game.ensureAuthoritativeLANChunkLoaded(dimension: request.dimension, cx: coord.cx, cz: coord.cz)
            }
            if syncGenerations >= LAN_MAX_SYNC_CHUNK_GENERATIONS_PER_REQUEST {
                self.appendStatus("LAN chunk request forced \(syncGenerations) synchronous generations (dimension \(request.dimension)).")
            }
            let snapshots = makeLANChunkSectionSnapshots(for: request, in: requestWorld)
            let blockEntities = makeLANBlockEntitySnapshots(for: request, in: requestWorld, maxCount: 16)
            let batch = LANReplicationBatch(
                tick: requestWorld.time,
                fullSnapshot: true,
                world: self.makeWorldSummary(playerCount: self.queue.sync { self.hostPeers.values.filter { $0.accepted }.count }),
                worldState: makeLANWorldStateSnapshot(in: requestWorld),
                chunkSections: snapshots,
                blockEntities: blockEntities
            )
            self.queue.async { [weak self] in
                self?.broadcastHostReplicationBatch(batch, drainedBlockChanges: [], to: peerID)
            }
        }
    }

    private func handleClientReplicationBatch(_ batch: LANReplicationBatch, receivedSequence: UInt32, from peer: LANWirePeer) {
        let ack = LANReplicationAck(tick: batch.tick, receivedSequence: receivedSequence)
        send(.replicationAck(playerID: localPeerID, ack: ack), to: peer)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let mirrorReport = self.clientReplicationSession.apply(batch)
            var worldReport: LANReplicationApplyReport?
            if let game = self.activeGame, game.hasWorld() {
                // D-A: normal batches never overwrite the client-owned local inventory anymore —
                // only `applyLANRestore` (join/reconnect) and `applyLANGrant` (additive host
                // corrections) may touch it. The former per-batch
                // `applyLANInventorySnapshot(localInventory, to: player)` call has been removed.
                game.beginLANReplicationApply()
                worldReport = game.applyLANHostReplicationBatch(batch)
                _ = applyLANRemotePlayers(batch.players, to: game.world, localPlayerID: self.localPeerID)
                game.endLANReplicationApply()
            }
            if batch.fullSnapshot {
                self.appendStatus("Applied LAN snapshot tick \(batch.tick): \(mirrorReport.appliedChunkSections) sections, \(mirrorReport.appliedBlockChanges) block deltas, \(mirrorReport.appliedBlockEntities) block entities, \(mirrorReport.appliedEntitySnapshots) entities.")
            } else if let worldReport,
                      worldReport.appliedBlockChanges > 0 ||
                      worldReport.appliedBlockEntities > 0 ||
                      worldReport.ignoredInvalidBlockEntities > 0 ||
                      worldReport.removedEntitySnapshots > 0 ||
                      worldReport.ignoredInvalidEntities > 0 {
                let rejected = worldReport.ignoredInvalidEntities + worldReport.ignoredInvalidBlockEntities
                self.appendStatus("Applied \(worldReport.appliedBlockChanges) LAN block delta\(worldReport.appliedBlockChanges == 1 ? "" : "s"), \(worldReport.appliedBlockEntities) block entit\(worldReport.appliedBlockEntities == 1 ? "y" : "ies"), \(worldReport.removedEntitySnapshots) entity removal\(worldReport.removedEntitySnapshots == 1 ? "" : "s"), \(rejected) rejected replicated update\(rejected == 1 ? "" : "s").")
            }
        }
    }

    private func stopClientOnly() {
        clearReplicationHooks(for: activeGame)
        clientPeer?.connection.cancel()
        clientPeer = nil
        if listener == nil { setState(.idle) }
    }

    private func markHostPeerDisconnected(_ peer: LANWirePeer) {
        guard peer.accepted, !peer.playerID.isEmpty else { return }
        let playerID = peer.playerID
        let name = peer.playerName
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let tick = self.activeGame?.world.time ?? 0
            self.hostReplicationSession.disconnectPeer(playerID: playerID, tick: tick)
            if let game = self.activeGame, game.hasWorld() {
                _ = removeLANRemotePlayer(playerID, from: game.world)
            }
            // §7.5: persist the peer's record on disconnect (main-thread read of the session
            // record, write on the same save-queue pattern GameCore's own persistence uses) so a
            // guest who drops mid-session doesn't lose position/inventory progress even before the
            // periodic/stop() persistence passes run.
            if let game = self.activeGame, let worldID = game.worldRec?.id,
               let record = self.hostReplicationSession.peerRecord(playerID: playerID) {
                game.db.putLANPlayer(world: worldID, playerID: playerID, lanPeerRecordJSON(record))
            }
            let event = LANGameplayEvent(playerID: playerID, kind: .peerDisconnected, message: "\(name) disconnected.", tick: tick)
            self.queue.async { [weak self] in
                self?.broadcastFromHost(.gameplayEvent(event))
            }
        }
    }

    private func sendGameplayEvent(_ event: LANGameplayEvent, to peerID: UUID?) {
        if let peerID {
            guard let peer = hostPeers[peerID], peer.accepted else { return }
            send(.gameplayEvent(event), to: peer)
        } else {
            broadcastFromHost(.gameplayEvent(event))
        }
    }

    private func handleGameplayEvent(_ event: LANGameplayEvent) {
        appendStatus(event.message)
        switch event.kind {
        case .peerDisconnected, .death:
            DispatchQueue.main.async { [weak self] in
                guard let self, let game = self.activeGame, game.hasWorld() else { return }
                _ = removeLANRemotePlayer(event.playerID, from: game.world)
            }
        default:
            break
        }
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
        if ProcessInfo.processInfo.environment["PEBBLE_LAN_PROBE_LOG"] != nil {
            pebbleLANProbeLog("status \(clean)")
        }
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

// =============================================================================
// §5/§7.3 persistence: LANPeerRecordSnapshot <-> lan_players JSON bridging.
//
// SaveDB's LAN player rows store a `[String: Any]` blob (JSONSerialization, matching every other
// SaveDB table) with the schema `{ state, inventory, revision, permissions, displayName, updated }`.
// `LANPeerRecordSnapshot`'s sub-fields (`LANPlayerState`, `LANPlayerInventorySnapshot`,
// `LANPeerPermissions`) are all `Codable`, so each is bridged individually through `JSONEncoder`/
// `JSONDecoder` and re-nested into the `[String: Any]` shape SaveDB expects. Fails closed: any
// decode error anywhere in the chain returns nil rather than a partially-populated record.
// =============================================================================

private func lanJSONObject<T: Encodable>(_ value: T) -> [String: Any]? {
    guard let data = try? JSONEncoder().encode(value),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object
}

private func lanDecode<T: Decodable>(_ type: T.Type, from object: Any?) -> T? {
    guard let object,
          let data = try? JSONSerialization.data(withJSONObject: object)
    else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

/// Serializes a host peer record into the `[String: Any]` JSON blob `SaveDB.putLANPlayer` stores.
func lanPeerRecordJSON(_ record: LANPeerRecordSnapshot) -> [String: Any] {
    var out: [String: Any] = [
        "displayName": record.displayName,
        "revision": record.inventoryRevision,
        "updated": Date().timeIntervalSince1970 * 1000,
    ]
    if let state = record.playerState, let stateJSON = lanJSONObject(state) {
        out["state"] = stateJSON
    }
    if let inventory = record.inventory, let inventoryJSON = lanJSONObject(inventory) {
        out["inventory"] = inventoryJSON
    }
    if let permissionsJSON = lanJSONObject(record.permissions) {
        out["permissions"] = permissionsJSON
    }
    return out
}

/// Reconstructs a `LANPeerRecordSnapshot` from a stored `lan_players` JSON blob (as read back by
/// `SaveDB.getLANPlayer`/`listLANPlayers`), for `seedPeerRecord`-ing a host session on startup.
/// Returns nil (fail closed) if the row is missing required sub-objects or any of them fail to
/// decode — a corrupt row is skipped rather than crashing or seeding partial state.
func lanPeerRecordSnapshot(fromStoredJSON data: [String: Any], playerID: String) -> LANPeerRecordSnapshot? {
    guard let state = lanDecode(LANPlayerState.self, from: data["state"]) else { return nil }
    let inventory = lanDecode(LANPlayerInventorySnapshot.self, from: data["inventory"])
    let permissions = lanDecode(LANPeerPermissions.self, from: data["permissions"]) ?? LANPeerPermissions()
    let displayName = (data["displayName"] as? String) ?? "Player"
    let revision = (data["revision"] as? Int) ?? Int((data["revision"] as? NSNumber)?.intValue ?? 0)
    return LANPeerRecordSnapshot(
        playerID: playerID,
        displayName: displayName,
        lifecycle: .disconnected,
        permissions: permissions,
        playerState: state,
        inventory: inventory,
        inventoryRevision: max(0, revision),
        lastAckTick: 0,
        lastSeenTick: 0,
        disconnectedTick: nil
    )
}

func runLANCommand(_ game: GameCore, _ args: [String]) {
    let manager = LANMultiplayerManager.shared
    manager.attachGame(game)
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
