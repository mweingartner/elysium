#if ELYSIUM_DEBUG_CONTROL
import AppKit
import CryptoKit
import Foundation
import QuartzCore
import ElysiumCore
import ElysiumDebugProtocol

/// Main-actor-only adapter from authenticated protocol operations to the same game/UI entry
/// points used by a player. Raw world setup operations are intentionally bounded and unavailable
/// in LAN-client worlds; semantic interaction operations reuse production validation paths.
@MainActor
final class DebugControlRuntime {
    static let maximumCachedRequests = 512
    static let maximumCachedResponseBytes = 8 * 1_024 * 1_024
    static let maximumEvents = 4_096
    static let maximumRegionBlocks = 4_096
    static let maximumCoordinateDistance = 256
    static let maximumTemplateBlocks = 8_192
    static let maximumTemplatePreparationCells = 65_536

    let sessionID: UUID
    let capabilities: DebugCapabilities

    private unowned let app: AppDelegate
    private let artifactDirectory: URL
    private var epoch: UInt64 = 1
    private var revision: UInt64 = 1
    private var eventSequence: UInt64 = 0
    private var events: [DebugEvent] = []
    private var cachedResponses: [UUID: (fingerprint: Data, response: DebugResponse, bytes: Int)] = [:]
    private var cachedOrder: [UUID] = []
    private var cachedResponseBytes = 0
    private var inFlightRequests: [UUID: Data] = [:]
    private var capturePaths: [UUID: URL] = [:]
    private var captureTimeouts: [UUID: DispatchWorkItem] = [:]
    private var templateUndo: DebugTemplateUndo?
    private var pendingWorldDeleteRecovery: DebugWorldDeleteRecovery?
    private var observedWorldIdentity = RuntimeWorldIdentity.title
    private var controllerGeneration: UInt64 = 0
    private var permanentlyShutdown = false

    init(app: AppDelegate, sessionID: UUID, artifactDirectory: URL) throws {
        self.app = app
        self.sessionID = sessionID
        self.artifactDirectory = artifactDirectory
        capabilities = try DebugCapabilities(capabilities: [
            .readSnapshots, .replayEvents, .captureFrames, .worldLifecycle,
            .simulationControl, .playerControl, .environmentMutation, .entityControl,
            .interactionControl, .screenControl, .templateControl, .rpgControl,
            .lanControl, .scriptControl,
        ], maximumRequestPayloadBytes: 64 * 1_024,
           maximumSnapshotPayloadBytes: DebugFrameLimits.absoluteMaximumPayloadBytes,
           maximumEventReplayCount: Self.maximumEvents)
        observedWorldIdentity = currentWorldIdentity()
    }

    func disconnect() {
        cancelPendingCaptures()
        app.game?.clearInput()
        guard let cursor = app.ui?.cursorStack else { return }
        defer { app.ui?.cursorStack = nil }
        guard app.game?.hasWorld() == true, let player = app.game?.player else { return }
        if !player.give(cursor), cursor.count > 0 {
            player.dropStack(cursor)
        }
    }

    /// Permanently relinquishes resources owned by this control session. Ordinary controller
    /// disconnects deliberately retain a terminal world-delete recovery so a replacement
    /// authenticated controller can obtain its durable receipt. Once the server itself stops,
    /// however, no controller can resume that recovery; retaining its maintenance lease would
    /// unnecessarily block the in-app saved-world UI for the rest of the process lifetime.
    func shutdown() {
        guard !permanentlyShutdown else { return }
        permanentlyShutdown = true
        disconnect()
        guard let pending = pendingWorldDeleteRecovery else { return }
        pendingWorldDeleteRecovery = nil
        app.game.releaseSavedWorldMaintenance(pending.token)
    }

    func controllerDidChange() {
        if controllerGeneration < UInt64.max { controllerGeneration += 1 }
        disconnect()
    }

    func handle(_ request: DebugRequest, completion: @escaping (DebugResponse) -> Void) {
        MainActor.preconditionIsolated()
        synchronizeExternalWorldIdentity()
        let fingerprint = requestFingerprint(request)
        if let cached = cachedResponses[request.id] {
            if cached.fingerprint == fingerprint {
                completion(cached.response)
            } else {
                completion(failure(request, .invalidArguments,
                                   "A request id cannot be reused with different content"))
            }
            return
        }
        if let pendingFingerprint = inFlightRequests[request.id] {
            if pendingFingerprint == fingerprint {
                completion(failure(request, .busy, "Request is still in progress", retryable: true))
            } else {
                completion(failure(request, .invalidArguments,
                                   "A request id cannot be reused with different content"))
            }
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard !request.isExpired(atUptimeNanoseconds: now) else {
            complete(request, fingerprint: fingerprint,
                     response: failure(request, .deadlineExceeded, "Request deadline elapsed"),
                     completion: completion)
            return
        }
        if let expected = request.expectedEpoch, expected != epoch {
            complete(request, fingerprint: fingerprint,
                     response: failure(request, .wrongEpoch, "World epoch changed"),
                     completion: completion)
            return
        }
        if let expected = request.expectedRevision, expected != revision {
            complete(request, fingerprint: fingerprint,
                     response: failure(request, .wrongRevision, "State revision changed"),
                     completion: completion)
            return
        }

        do {
            if request.operation == "render.capture" {
                inFlightRequests[request.id] = fingerprint
                do {
                    try beginCapture(request, fingerprint: fingerprint, completion: completion)
                } catch {
                    inFlightRequests.removeValue(forKey: request.id)
                    throw error
                }
                return
            }
            let result = try execute(request)
            let response = DebugResponse(requestID: request.id, result: result,
                                         epoch: epoch, revision: revision,
                                         eventSequence: eventSequence)
            complete(request, fingerprint: fingerprint, response: response,
                     completion: completion)
        } catch let error as RuntimeError {
            complete(request, fingerprint: fingerprint,
                     response: failure(request, error.code, error.message,
                                       retryable: error.retryable),
                     completion: completion)
        } catch let error as DebugSemanticError {
            let mapped: (DebugErrorCode, String)
            switch error {
            case .noScreen: mapped = (.wrongState, "No screen is open")
            case .staleScreen: mapped = (.staleScreen, "Screen instance changed")
            case .readOnly: mapped = (.notAuthoritative, "Screen is read-only")
            case .unknownElement: mapped = (.invalidArguments, "Unknown semantic element")
            case .invalidAction: mapped = (.wrongState, "Screen rejected the action")
            }
            complete(request, fingerprint: fingerprint,
                     response: failure(request, mapped.0, mapped.1), completion: completion)
        } catch let error as AIAgentError {
            let mapped = runtimeError(for: error)
            complete(request, fingerprint: fingerprint,
                     response: failure(request, mapped.code, mapped.message,
                                       retryable: mapped.retryable), completion: completion)
        } catch let error as TemplateError {
            let mapped = runtimeError(for: error)
            complete(request, fingerprint: fingerprint,
                     response: failure(request, mapped.code, mapped.message,
                                       retryable: mapped.retryable), completion: completion)
        } catch {
            complete(request, fingerprint: fingerprint,
                     response: failure(request, .internalFailure,
                                       String(describing: error)), completion: completion)
        }
    }

    private func execute(_ request: DebugRequest) throws -> [String: JSONValue] {
        let a = request.arguments
        switch request.operation {
        case "session.capabilities":
            return ["capabilities": try jsonValue(capabilities)]
        case "session.status":
            return [
                "sessionID": .string(sessionID.uuidString.lowercased()),
                "epoch": .integer(safeInt64(epoch)),
                "revision": .integer(safeInt64(revision)),
                "eventSequence": .integer(safeInt64(eventSequence)),
                "worldLoaded": .bool(app.game.hasWorld()),
                "profile": .string("isolated-debug"),
            ]
        case "lan.status":
            return ["lan": .object(lanStatusValue())]
        case "lan.host":
            try requireWorld(authoritative: true)
            let joinCode = try boundedString(a, "joinCode", maximumBytes: 32)
            let requestedPort = try optionalInt(a, "port")
            if let requestedPort, !(1...65_535).contains(requestedPort) {
                throw RuntimeError(.invalidArguments, "port must be 1...65535")
            }
            LANMultiplayerManager.shared.attachGame(app.game)
            do {
                try LANMultiplayerManager.shared.startHost(
                    game: app.game,
                    requestedJoinCode: joinCode,
                    requestedPort: requestedPort.map(UInt16.init)
                )
            } catch {
                throw RuntimeError(.wrongState, "LAN host start failed: \(error)")
            }
            mutate("lan.host.started", payload: [
                "port": .integer(Int64(requestedPort ?? Int(LAN_MULTIPLAYER_DEFAULT_PORT))),
            ])
            return ["lan": .object(lanStatusValue())]
        case "lan.direct_connect":
            guard !app.game.hasWorld() else {
                throw RuntimeError(.wrongState, "Exit the active world before joining a LAN host")
            }
            let host = try boundedString(a, "host", maximumBytes: 253)
            let port = try int(a, "port")
            guard (1...65_535).contains(port) else {
                throw RuntimeError(.invalidArguments, "port must be 1...65535")
            }
            let joinCode = try boundedString(a, "joinCode", maximumBytes: 32)
            let playerName = try boundedString(a, "playerName", maximumBytes: 128)
            LANMultiplayerManager.shared.attachGame(app.game)
            do {
                try LANMultiplayerManager.shared.directConnect(
                    host: host,
                    port: String(port),
                    joinCode: joinCode,
                    playerName: playerName,
                    game: app.game
                )
            } catch {
                throw RuntimeError(.wrongState, "LAN direct connect failed: \(error)")
            }
            mutate("lan.connect.started")
            return ["lan": .object(lanStatusValue())]
        case "lan.stop":
            LANMultiplayerManager.shared.stop()
            mutate("lan.stopped")
            return ["lan": .object(lanStatusValue())]
        case "registry.items":
            return ["items": .array(itemDefs.enumerated().map { index, item in
                .object(["id": .integer(Int64(index)), "name": .string(item.name),
                         "displayName": .string(item.displayName),
                         "maxStack": .integer(Int64(item.maxStack))])
            })]
        case "registry.blocks":
            return ["blocks": .array(blockDefs.enumerated().map { index, block in
                .object(["id": .integer(Int64(index)), "name": .string(block.name),
                         "displayName": .string(block.displayName)])
            })]
        case "registry.entities":
            return ["entities": .array(entityTypes().sorted().map(JSONValue.string))]
        case "registry.world_presets":
            return ["worldPresets": .array(WorldPreset.allCases.map {
                .object(["id": .string($0.rawValue), "displayName": .string($0.displayName)])
            })]
        case "registry.biomes":
            return ["biomes": .array(BIOMES.compactMap { biome -> JSONValue? in
                guard let biome else { return nil }
                return .object(["id": .string(biome.name),
                                "numericID": .integer(Int64(biome.id.rawValue)),
                                "displayName": .string(biome.displayName)])
            })]
        case "registry.dungeon_densities":
            return ["dungeonDensities": .array(DungeonDensity.allCases.map {
                .object(["id": .integer(Int64($0.rawValue)),
                         "displayName": .string($0.displayName)])
            })]
        case "registry.rpg":
            return try rpgRegistry()
        case "state.snapshot":
            return ["snapshot": try jsonValue(makeSnapshot(arguments: a))]
        case "events.replay":
            let after = try optionalUInt64(a, "after") ?? 0
            let limit = min(Self.maximumEvents, max(1, try optionalInt(a, "limit") ?? 256))
            let replay = events.filter { $0.sequence > after }.prefix(limit)
            return ["events": .array(try replay.map(jsonValue))]
        case "world.list":
            let worlds = app.game.listWorlds()
            let offset = try optionalInt(a, "offset") ?? 0
            let limit = min(256, max(1, try optionalInt(a, "limit") ?? 128))
            guard offset >= 0, offset <= worlds.count else {
                throw RuntimeError(.invalidArguments, "offset is outside the saved-world list")
            }
            let end = min(worlds.count, offset + limit)
            let page = worlds[offset..<end]
            return ["worlds": .array(page.map(worldRecordValue)),
                    "offset": .integer(Int64(offset)),
                    "count": .integer(Int64(page.count)),
                    "total": .integer(Int64(worlds.count)),
                    "nextOffset": end < worlds.count ? .integer(Int64(end)) : .null]
        case "world.create":
            try requireNoLANClient()
            let name = try boundedString(a, "name", maximumBytes: 128)
            let seed = try optionalString(a, "seed", maximumBytes: 256) ?? ""
            let mode = try optionalInt(a, "mode") ?? GameMode.survival
            guard mode == GameMode.survival || mode == GameMode.creative else {
                throw RuntimeError(.invalidArguments, "mode must be 0 or 1")
            }
            let difficulty = try optionalInt(a, "difficulty") ?? 2
            guard (0...3).contains(difficulty) else {
                throw RuntimeError(.invalidArguments, "difficulty must be 0...3")
            }
            let presetRaw = try optionalString(a, "preset", maximumBytes: 128)
                ?? WorldPreset.normal.rawValue
            guard let preset = WorldPreset.allCases.first(where: {
                $0.rawValue == presetRaw || String(describing: $0) == presetRaw
            }) else { throw RuntimeError(.invalidArguments, "Unknown world preset") }
            let biomeRaw = try optionalString(a, "biome", maximumBytes: 128) ?? "plains"
            guard let biome = BIOMES.compactMap({ $0 }).first(where: { $0.name == biomeRaw })?.id
                else { throw RuntimeError(.invalidArguments, "Unknown biome") }
            let densityRaw = try optionalInt(a, "dungeonDensity") ?? DungeonDensity.normal.rawValue
            guard let density = DungeonDensity(rawValue: densityRaw) else {
                throw RuntimeError(.invalidArguments, "Unknown dungeon density")
            }
            let rpg = try optionalBool(a, "rpgClassesEnabled") ?? true
            // Validate the complete request before crossing the current-world boundary. A typo in
            // a preset or biome must not eject the developer from the world being inspected.
            if app.game.hasWorld() {
                try settleScreensBeforeWorldBoundary()
                app.game.exitToTitle()
            }
            app.game.createWorld(name: name, seedText: seed, mode: mode,
                                 difficulty: difficulty, worldPreset: preset,
                                 singleBiome: biome, dungeonDensity: density,
                                 rpgClassesEnabled: rpg)
            guard app.game.hasWorld(), let rec = app.game.worldRec else {
                throw RuntimeError(.persistenceFailed, "World creation did not enter a world")
            }
            app.ui.closeAll(app.game)
            app.gameView.captureMouse()
            guard app.game.db.getWorld(rec.id) != nil else {
                worldBoundaryEvent("world.create_unpersisted", payload: ["id": .string(rec.id)])
                throw RuntimeError(.persistenceFailed,
                                   "World creation entered memory but did not persist its record")
            }
            worldBoundaryEvent("world.created", payload: ["id": .string(rec.id)])
            return ["world": worldRecordValue(rec)]
        case "world.load":
            try requireNoLANClient()
            let id = try boundedString(a, "id", maximumBytes: 128)
            guard app.game.listWorlds().contains(where: { $0.id == id }) else {
                throw RuntimeError(.invalidArguments, "World was not found")
            }
            if app.game.hasWorld() {
                try settleScreensBeforeWorldBoundary()
                app.game.exitToTitle()
            }
            app.game.loadWorld(id)
            guard app.game.hasWorld(), app.game.worldRec?.id == id else {
                throw RuntimeError(.invalidArguments, "World was not found or could not load")
            }
            app.ui.closeAll(app.game)
            app.gameView.captureMouse()
            worldBoundaryEvent("world.loaded", payload: ["id": .string(id)])
            return ["world": worldRecordValue(app.game.worldRec!)]
        case "world.save":
            try requireWorld(authoritative: true)
            try settleScreensBeforeWorldBoundary()
            mutate("world.saved")
            return ["saved": .bool(true), "allComponentsVerified": .bool(true)]
        case "world.exit":
            try requireWorld(authoritative: false)
            let id = app.game.worldRec?.id ?? ""
            try settleScreensBeforeWorldBoundary()
            app.game.exitToTitle()
            worldBoundaryEvent("world.exited", payload: ["id": .string(id)])
            return ["exited": .bool(true)]
        case "world.delete":
            guard !app.game.hasWorld() else {
                throw RuntimeError(.wrongState, "Exit the active world before deleting")
            }
            let id = try boundedString(a, "id", maximumBytes: 128)
            try deleteWorldChecked(id)
            worldBoundaryEvent("world.deleted", payload: ["id": .string(id)])
            return ["deleted": .bool(true), "id": .string(id)]
        case "simulation.pause":
            try requireWorld(authoritative: true)
            app.game.setDebugManualClock(true)
            mutate("simulation.paused")
            return ["paused": .bool(true)]
        case "simulation.resume":
            try requireWorld(authoritative: true)
            app.game.setDebugManualClock(false)
            mutate("simulation.resumed")
            return ["paused": .bool(false)]
        case "simulation.step":
            try requireWorld(authoritative: true)
            let ticks = try int(a, "ticks")
            guard (1...20).contains(ticks) else {
                throw RuntimeError(.boundedLimit, "One step request is limited to 1...20 ticks")
            }
            let advanced = app.game.debugStepSimulation(ticks)
            guard advanced == ticks else { throw RuntimeError(.wrongState, "Simulation did not advance") }
            mutate("simulation.stepped", payload: ["ticks": .integer(Int64(advanced))])
            return ["ticks": .integer(Int64(advanced)),
                    "simulationTick": .integer(Int64(app.game.world.time))]
        case "player.teleport":
            try requireWorld(authoritative: true)
            let x = try finiteDouble(a, "x"), y = try finiteDouble(a, "y"), z = try finiteDouble(a, "z")
            guard abs(x) <= 30_000_000, abs(z) <= 30_000_000,
                  y >= Double(app.game.world.info.minY),
                  y < Double(app.game.world.info.minY + app.game.world.info.height) else {
                throw RuntimeError(.invalidArguments, "Teleport destination is outside world bounds")
            }
            app.game.player.setPos(x, y, z)
            app.game.player.vx = 0; app.game.player.vy = 0; app.game.player.vz = 0
            app.game.player.fallDistance = 0
            mutate("player.teleported")
            return playerPositionValue()
        case "player.look":
            try requireWorld(authoritative: false)
            let yaw = try finiteDouble(a, "yaw")
            let pitch = try finiteDouble(a, "pitch")
            guard abs(pitch) <= .pi / 2 else {
                throw RuntimeError(.invalidArguments, "pitch must be within -pi/2...pi/2")
            }
            app.game.player.yaw = normalizedYaw(yaw)
            app.game.player.pitch = pitch
            mutate("player.looked")
            return playerPositionValue()
        case "player.flying":
            try requireWorld(authoritative: true)
            let enabled = try bool(a, "enabled")
            guard !enabled || app.game.player.gameMode == GameMode.creative else {
                throw RuntimeError(.wrongState, "Creative mode is required for flight")
            }
            app.game.player.flying = enabled
            mutate("player.flight_changed")
            return ["flying": .bool(enabled)]
        case "inventory.select":
            try requireWorld(authoritative: true)
            let slot = try int(a, "slot")
            guard (0...8).contains(slot) else {
                throw RuntimeError(.invalidArguments, "Hotbar slot must be 0...8")
            }
            app.game.player.selectedSlot = slot
            mutate("inventory.selected")
            return ["slot": .integer(Int64(slot))]

        // scripting-ui-and-replication (change 3), design.md §12: `script.*` routes
        // straight through `ScriptingCommands.run(command: "script", ...)` — the same
        // pure, validator/trust/kill-switch-gated executors `/script` uses (never a
        // second implementation) — so every existing `/script` invariant (LAN-client
        // refusal, the 8-scripts-per-object cap, the validator, the trust gate)
        // applies unchanged. `ScriptingCommands.run` reconstructs multi-line `source`
        // by `.joined(separator: " ")`-ing everything after the fixed-position
        // arguments, so the source is always passed as exactly one trailing array
        // element (never word-split) to keep embedded newlines byte-exact.
        case "script.list":
            try requireWorld(authoritative: true)
            let target = (try optionalString(a, "target", maximumBytes: 128)) ?? "looking"
            return scriptCommandResponse(["list", target])
        case "script.show":
            try requireWorld(authoritative: true)
            let target = (try optionalString(a, "target", maximumBytes: 128)) ?? "looking"
            let name = try boundedString(a, "name", maximumBytes: 32)
            return scriptCommandResponse(["show", target, name])
        case "script.attach":
            try requireWorld(authoritative: true)
            let target = (try optionalString(a, "target", maximumBytes: 128)) ?? "looking"
            let name = try boundedString(a, "name", maximumBytes: 32)
            let source = try boundedString(a, "source", maximumBytes: 16_384)
            let mode = (try optionalString(a, "mode", maximumBytes: 16)) ?? "module"
            guard mode == "module" || mode == "handler" else {
                throw RuntimeError(.invalidArguments, "mode must be 'module' or 'handler'")
            }
            var arguments = ["attach", target, name, mode]
            if mode == "handler" {
                arguments.append(try boundedString(a, "event", maximumBytes: 64))
            }
            arguments.append(source)
            let response = scriptCommandResponse(arguments)
            if case .bool(true)? = response["ok"] {
                mutate("script.attached", payload: ["target": .string(target), "name": .string(name)])
            }
            return response
        case "script.run":
            try requireWorld(authoritative: true)
            let target = (try optionalString(a, "target", maximumBytes: 128)) ?? "looking"
            let source = try boundedString(a, "source", maximumBytes: 16_384)
            return scriptCommandResponse(["run", target, source])
        case "script.journal":
            try requireWorld(authoritative: true)
            var arguments = ["journal"]
            if let limit = try optionalInt(a, "limit") {
                guard (1...256).contains(limit) else {
                    throw RuntimeError(.invalidArguments, "limit must be 1...256")
                }
                arguments.append(String(limit))
            }
            return scriptCommandResponse(arguments)
        case "interaction.action":
            try requireWorld(authoritative: true)
            let action = try decodeAIAgentAction(a)
            let result = try executeAIAgentAction(
                action, world: app.game.world, player: app.game.player,
                cursor: try debugCursor(arguments: a),
                openScreen: { [weak game = app.game] kind, data in game?.openScreen(kind, data) },
                advance: { [weak game = app.game] id in game?.advance(id) },
                persistPlayerState: { [weak game = app.game] in game?.saveAndFlush(synchronous: true) },
                setDifficulty: { [weak game = app.game] in game?.setDifficulty($0) },
                setGameRule: { [weak game = app.game] in game?.setGameRule($0, $1) })
            mutate("interaction.action", payload: ["action": .string(action.action)])
            return ["message": .string(result.message), "changedWorld": .bool(result.changedWorld)]
        case "interaction.bed_click":
            try requireWorld(authoritative: true)
            guard a["cursor"] != nil, let hit = try debugCursor(arguments: a) else {
                throw RuntimeError(.invalidArguments, "A cursor object is required")
            }
            guard app.game.debugBedPlacementClick(at: hit) else {
                throw RuntimeError(.wrongState,
                                   "Bed click requires a held bed and no open screen")
            }
            mutate("interaction.bed_click", payload: [
                "x": .integer(Int64(hit.x)), "y": .integer(Int64(hit.y)),
                "z": .integer(Int64(hit.z)), "face": .integer(Int64(hit.face)),
            ])
            return ["accepted": .bool(true)]
        case "world.set_block":
            try requireWorld(authoritative: true)
            let (x, y, z) = try boundedCoordinate(a)
            let raw = try boundedString(a, "block", maximumBytes: 128)
            let blockID: UInt16
            if raw == "air" || raw == "minecraft:air" { blockID = 0 }
            else if let resolved = resolveAIAgentBlockID(raw) { blockID = resolved }
            else { throw RuntimeError(.invalidArguments, "Unknown block") }
            let newValue = blockID == 0 ? 0 : Int(cell(blockID))
            let old = setDebugBlock(x: x, y: y, z: z, value: newValue)
            mutate("world.block_set")
            return ["changed": .bool(old != newValue),
                    "x": .integer(Int64(x)), "y": .integer(Int64(y)), "z": .integer(Int64(z))]
        case "world.fill":
            try requireWorld(authoritative: true)
            let minX = try int(a, "minX"), minY = try int(a, "minY"), minZ = try int(a, "minZ")
            let maxX = try int(a, "maxX"), maxY = try int(a, "maxY"), maxZ = try int(a, "maxZ")
            guard minX <= maxX, minY <= maxY, minZ <= maxZ else {
                throw RuntimeError(.invalidArguments, "Fill bounds are inverted")
            }
            let count = try checkedVolume(minX: minX, minY: minY, minZ: minZ,
                                          maxX: maxX, maxY: maxY, maxZ: maxZ)
            guard count <= Self.maximumRegionBlocks else {
                throw RuntimeError(.boundedLimit, "Fill is limited to \(Self.maximumRegionBlocks) blocks")
            }
            let raw = try boundedString(a, "block", maximumBytes: 128)
            let blockID: UInt16
            if raw == "air" || raw == "minecraft:air" { blockID = 0 }
            else if let resolved = resolveAIAgentBlockID(raw) { blockID = resolved }
            else { throw RuntimeError(.invalidArguments, "Unknown block") }
            for x in minX...maxX { for y in minY...maxY { for z in minZ...maxZ {
                try validateCoordinate(x, y, z)
            } } }
            let value = blockID == 0 ? 0 : Int(cell(blockID))
            var changed = 0
            for x in minX...maxX { for y in minY...maxY { for z in minZ...maxZ {
                if setDebugBlock(x: x, y: y, z: z, value: value) != value { changed += 1 }
            } } }
            mutate("world.filled", payload: ["blocks": .integer(Int64(changed))])
            return ["visited": .integer(Int64(count)), "changed": .integer(Int64(changed))]
        case "entity.spawn":
            try requireWorld(authoritative: true)
            let name = try boundedString(a, "type", maximumBytes: 128)
            guard let type = resolveAIAgentEntityName(name) else {
                throw RuntimeError(.invalidArguments, "Unknown entity type")
            }
            let (x, y, z) = try boundedCoordinate(a)
            let count = min(AIAgentMaxSpawnCount, max(1, try optionalInt(a, "count") ?? 1))
            var ids: [JSONValue] = []
            for _ in 0..<count {
                guard let entity = spawnMob(app.game.world, type, Double(x) + 0.5,
                                            Double(y), Double(z) + 0.5,
                                            SpawnOpts(persistent: true)) else { continue }
                ids.append(.integer(Int64(entity.id)))
            }
            guard !ids.isEmpty else { throw RuntimeError(.wrongState, "Entity spawn failed") }
            mutate("entity.spawned", payload: ["type": .string(type)])
            return ["ids": .array(ids)]
        case "input.key_down":
            try requireWorld(authoritative: false)
            let key = try boundedString(a, "key", maximumBytes: 64)
            app.game.keyDown(key, now: CACurrentMediaTime() * 1_000,
                             ctrlOrCmd: try optionalBool(a, "command") ?? false)
            return ["accepted": .bool(true)]
        case "input.key_up":
            try requireWorld(authoritative: false)
            let key = try boundedString(a, "key", maximumBytes: 64)
            app.game.keyUp(key)
            return ["accepted": .bool(true)]
        case "input.mouse_delta":
            try requireWorld(authoritative: false)
            let dx = try finiteDouble(a, "dx"), dy = try finiteDouble(a, "dy")
            guard abs(dx) <= 10_000, abs(dy) <= 10_000 else {
                throw RuntimeError(.boundedLimit, "Mouse delta is limited to +/-10000")
            }
            app.game.mouseDelta(dx, dy)
            app.game.player.yaw = normalizedYaw(app.game.player.yaw)
            return ["accepted": .bool(true)]
        case "input.mouse_down":
            try requireWorld(authoritative: false)
            let button = try int(a, "button")
            guard button == 0 || button == 2 else {
                throw RuntimeError(.invalidArguments, "button must be 0 or 2")
            }
            app.game.mouseDown(button)
            return ["accepted": .bool(true)]
        case "input.mouse_up":
            try requireWorld(authoritative: false)
            let button = try int(a, "button")
            guard button == 0 || button == 2 else {
                throw RuntimeError(.invalidArguments, "button must be 0 or 2")
            }
            app.game.mouseUp(button)
            return ["accepted": .bool(true)]
        case "input.wheel":
            try requireWorld(authoritative: false)
            let direction = try int(a, "direction")
            guard direction == -1 || direction == 1 else {
                throw RuntimeError(.invalidArguments, "direction must be -1 or 1")
            }
            app.game.wheelHotbar(direction)
            return ["accepted": .bool(true)]
        case "input.clear":
            app.game.clearInput()
            return ["cleared": .bool(true)]
        case "screen.snapshot":
            return ["screen": .object(DebugScreenSemantics(ui: app.ui, game: app.game).snapshot())]
        case "screen.slot":
            try requireNoLANClient()
            let semantics = DebugScreenSemantics(ui: app.ui, game: app.game)
            try semantics.activateSlot(try boundedString(a, "id", maximumBytes: 128),
                                       button: try optionalInt(a, "button") ?? 0,
                                       shift: try optionalBool(a, "shift") ?? false,
                                       expectedInstance: try boundedString(a, "instance", maximumBytes: 256))
            mutate("screen.slot")
            return ["screen": .object(semantics.snapshot())]
        case "screen.transfer":
            try requireNoLANClient()
            let semantics = DebugScreenSemantics(ui: app.ui, game: app.game)
            try semantics.transferSlot(
                from: try boundedString(a, "from", maximumBytes: 128),
                to: try boundedString(a, "to", maximumBytes: 128),
                expectedInstance: try boundedString(a, "instance", maximumBytes: 256))
            mutate("screen.transfer")
            return ["screen": .object(semantics.snapshot())]
        case "screen.button":
            try requireNoLANClient()
            let semantics = DebugScreenSemantics(ui: app.ui, game: app.game)
            try semantics.activateButton(try boundedString(a, "id", maximumBytes: 128),
                                         expectedInstance: try boundedString(a, "instance", maximumBytes: 256))
            mutate("screen.button")
            return ["screen": .object(semantics.snapshot())]
        case "screen.action":
            try requireNoLANClient()
            let semantics = DebugScreenSemantics(ui: app.ui, game: app.game)
            try semantics.activateAction(try boundedString(a, "id", maximumBytes: 256),
                                         expectedInstance: try boundedString(
                                            a, "instance", maximumBytes: 256))
            mutate("screen.action")
            return ["screen": .object(semantics.snapshot())]
        case "screen.field":
            try requireNoLANClient()
            let semantics = DebugScreenSemantics(ui: app.ui, game: app.game)
            try semantics.setField(try boundedString(a, "id", maximumBytes: 128),
                                   value: try boundedString(a, "value", maximumBytes: 4_096),
                                   expectedInstance: try boundedString(a, "instance", maximumBytes: 256))
            mutate("screen.field")
            return ["screen": .object(semantics.snapshot())]
        case "screen.key":
            try requireNoLANClient()
            let semantics = DebugScreenSemantics(ui: app.ui, game: app.game)
            try semantics.sendKey(try boundedString(a, "key", maximumBytes: 64),
                                  expectedInstance: try boundedString(a, "instance", maximumBytes: 256))
            mutate("screen.key")
            return ["screen": .object(semantics.snapshot())]
        case "screen.close":
            let semantics = DebugScreenSemantics(ui: app.ui, game: app.game)
            try semantics.close(expectedInstance: try boundedString(a, "instance", maximumBytes: 256))
            mutate("screen.closed")
            return ["screen": .object(semantics.snapshot())]
        case "screen.open":
            try requireWorld(authoritative: true)
            let kind = try boundedString(a, "kind", maximumBytes: 64)
            guard ["inventory", "creative", "templates", "templatesPlace", "map", "rpg"].contains(kind) else {
                throw RuntimeError(.invalidArguments, "Use interaction.action/use_block for workstation screens")
            }
            app.game.openScreen(kind, nil)
            mutate("screen.opened", payload: ["kind": .string(kind)])
            return ["screen": .object(DebugScreenSemantics(ui: app.ui, game: app.game).snapshot())]
        case "template.list":
            let summaries = app.game.db.listTemplateSummaries()
            let offset = try optionalInt(a, "offset") ?? 0
            let limit = min(256, max(1, try optionalInt(a, "limit") ?? 128))
            guard offset >= 0, offset <= summaries.count else {
                throw RuntimeError(.invalidArguments, "offset is outside the template list")
            }
            let pageCount = min(limit, summaries.count - offset)
            let end = offset + pageCount
            return ["templates": .array(summaries[offset..<end].map { summary in
                .object(["name": .string(summary.name),
                         "size": .array([.integer(Int64(summary.sizeX)),
                                         .integer(Int64(summary.sizeY)),
                                         .integer(Int64(summary.sizeZ))]),
                         "blocks": .integer(Int64(summary.blockCount)),
                         "blockEntities": .integer(Int64(summary.blockEntityCount)),
                         "dominantBlock": .string(summary.dominantBlockName)])
            }), "offset": .integer(Int64(offset)), "count": .integer(Int64(pageCount)),
                "total": .integer(Int64(summaries.count)),
                "nextOffset": end < summaries.count ? .integer(Int64(end)) : .null]
        case "template.copy":
            try requireWorld(authoritative: true)
            let name = try boundedString(a, "name", maximumBytes: OBJECT_TEMPLATE_NAME_MAX)
            let (x, y, z) = try boundedCoordinate(a)
            let result = try cloneObjectTemplate(named: name, from: app.game.world,
                                                 targetX: x, targetY: y, targetZ: z,
                                                 options: TemplateCloneOptions(
                                                    maxBlocks: Self.maximumTemplateBlocks,
                                                    maxSpan: OBJECT_TEMPLATE_MAX_SPAN))
            guard try app.game.db.putTemplate(result.template) else {
                throw RuntimeError(.persistenceFailed, "Template could not be stored")
            }
            mutate("template.copied", payload: ["name": .string(result.template.name)])
            return ["name": .string(result.template.name),
                    "blocks": .integer(Int64(result.template.blocks.count)),
                    "bounds": .array([.integer(Int64(result.minX)), .integer(Int64(result.minY)),
                                      .integer(Int64(result.minZ)), .integer(Int64(result.maxX)),
                                      .integer(Int64(result.maxY)), .integer(Int64(result.maxZ))])]
        case "template.generate":
            let name = try boundedString(a, "name", maximumBytes: OBJECT_TEMPLATE_NAME_MAX)
            let kind = try boundedString(a, "kind", maximumBytes: 64)
            let template = try generatedObjectTemplate(named: name, kind: kind,
                                                       requestedLength: try optionalInt(a, "length"),
                                                       style: try optionalString(a, "style", maximumBytes: 512) ?? "")
            guard template.blocks.count <= Self.maximumTemplateBlocks else {
                throw RuntimeError(.boundedLimit, "Generated template is too large for control-port placement")
            }
            guard try app.game.db.putTemplate(template) else {
                throw RuntimeError(.persistenceFailed, "Template could not be stored")
            }
            mutate("template.generated", payload: ["name": .string(template.name)])
            return ["name": .string(template.name), "blocks": .integer(Int64(template.blocks.count))]
        case "template.place":
            try requireWorld(authoritative: true)
            let name = try boundedString(a, "name", maximumBytes: OBJECT_TEMPLATE_NAME_MAX)
            guard let template = try app.game.db.getTemplate(named: name) else {
                throw RuntimeError(.invalidArguments, "Unknown template")
            }
            guard template.blocks.count <= Self.maximumTemplateBlocks else {
                throw RuntimeError(.boundedLimit, "Template is too large for one control request")
            }
            let (x, y, z) = try boundedCoordinate(a)
            let rotation = try optionalInt(a, "rotation") ?? 0
            let options = TemplatePlacementOptions(
                replaceExisting: try optionalBool(a, "replaceExisting") ?? false,
                prepareTerrain: try optionalBool(a, "prepareTerrain") ?? false)
            if options.prepareTerrain {
                let footprint = template.sizeX.multipliedReportingOverflow(by: template.sizeZ)
                let volume = footprint.partialValue.multipliedReportingOverflow(by: template.sizeY)
                let support = footprint.partialValue.multipliedReportingOverflow(
                    by: OBJECT_TEMPLATE_MAX_SUPPORT_FILL_DEPTH + 1)
                let work = volume.partialValue.addingReportingOverflow(support.partialValue)
                guard !footprint.overflow, !volume.overflow, !support.overflow, !work.overflow,
                      work.partialValue <= Self.maximumTemplatePreparationCells else {
                    throw RuntimeError(
                        .boundedLimit,
                        "Terrain preparation is limited to \(Self.maximumTemplatePreparationCells) scanned cells")
                }
            }
            guard let worldID = app.game.worldRec?.id else {
                throw RuntimeError(.wrongState, "The active world has no persistent identity")
            }
            let undo = try objectTemplatePlacementUndoSnapshot(for: template,
                in: app.game.world, targetX: x, targetY: y, targetZ: z,
                rotationSteps: rotation, options: options)
            let result = try placeObjectTemplate(template, in: app.game.world,
                targetX: x, targetY: y, targetZ: z, rotationSteps: rotation, options: options)
            templateUndo = DebugTemplateUndo(worldID: worldID, snapshot: undo)
            mutate("template.placed", payload: ["name": .string(name)])
            return ["blocksPlaced": .integer(Int64(result.blocksPlaced)),
                    "blockEntitiesPlaced": .integer(Int64(result.blockEntitiesPlaced)),
                    "origin": .array([.integer(Int64(result.originX)),
                                      .integer(Int64(result.originY)),
                                      .integer(Int64(result.originZ))])]
        case "template.undo":
            try requireWorld(authoritative: true)
            guard let undo = templateUndo,
                  undo.worldID == app.game.worldRec?.id,
                  undo.snapshot.dimension == app.game.dim.rawValue else {
                throw RuntimeError(.wrongState, "No compatible debug template placement to undo")
            }
            guard templateUndoSnapshotFullyLoaded(undo.snapshot, in: app.game.world) else {
                throw RuntimeError(.unloaded, "Template undo region is not loaded", retryable: true)
            }
            let restored = restoreObjectTemplatePlacementUndo(undo.snapshot, in: app.game.world)
            templateUndo = nil
            mutate("template.undone")
            return ["restored": .integer(Int64(restored))]
        case "template.delete":
            let name = try boundedString(a, "name", maximumBytes: OBJECT_TEMPLATE_NAME_MAX)
            let deleted = try app.game.db.deleteTemplate(named: name)
            if deleted { mutate("template.deleted", payload: ["name": .string(name)]) }
            return ["deleted": .bool(deleted)]
        case "rpg.create":
            try requireWorld(authoritative: true)
            let path = try boundedString(a, "path", maximumBytes: 128)
            let branch = try boundedString(a, "branch", maximumBytes: 128)
            let skills = try optionalStringArray(a, "startingSkills", maximumCount: 3,
                                                 maximumBytes: 128) ?? []
            let message = app.game.requestRPGCreateCharacter(RPGCreationDraft(
                pathID: path, branchID: branch, startingSkillIDs: skills))
            mutate("rpg.created", payload: ["path": .string(path), "branch": .string(branch)])
            return ["message": .string(message), "rpg": try jsonValue(app.game.player.rpg)]
        case "rpg.learn":
            try requireWorld(authoritative: true)
            let id = try boundedString(a, "skill", maximumBytes: 128)
            let message = app.game.requestRPGLearnSkill(id)
            mutate("rpg.learned", payload: ["skill": .string(id)])
            return ["message": .string(message), "rpg": try jsonValue(app.game.player.rpg)]
        case "rpg.prepare_skill":
            try requireWorld(authoritative: true)
            let id = try boundedString(a, "skill", maximumBytes: 128)
            let message = app.game.requestRPGTogglePreparedSkill(id)
            mutate("rpg.prepared_skill", payload: ["skill": .string(id)])
            return ["message": .string(message), "rpg": try jsonValue(app.game.player.rpg)]
        case "rpg.prepare_spell":
            try requireWorld(authoritative: true)
            let id = try boundedString(a, "spell", maximumBytes: 128)
            let message = app.game.requestRPGTogglePreparedSpell(id)
            mutate("rpg.prepared_spell", payload: ["spell": .string(id)])
            return ["message": .string(message), "rpg": try jsonValue(app.game.player.rpg)]
        case "rpg.select_skill":
            try requireWorld(authoritative: true)
            let id = try boundedString(a, "skill", maximumBytes: 128)
            let message = app.game.requestRPGSelectPreparedSkill(id)
            mutate("rpg.selected_skill", payload: ["skill": .string(id)])
            return ["message": .string(message)]
        case "rpg.select_spell":
            try requireWorld(authoritative: true)
            let id = try boundedString(a, "spell", maximumBytes: 128)
            let message = app.game.requestRPGSelectPreparedSpell(id)
            mutate("rpg.selected_spell", payload: ["spell": .string(id)])
            return ["message": .string(message)]
        case "rpg.use_selected":
            try requireWorld(authoritative: true)
            let message = app.game.requestRPGUseSelectedAction()
            mutate("rpg.used_selected")
            return ["message": .string(message)]
        case "rpg.use_quick_slot":
            try requireWorld(authoritative: true)
            let slot = try int(a, "slot")
            let message = app.game.requestRPGUseActionQuickSlot(slot)
            mutate("rpg.used_quick_slot", payload: ["slot": .integer(Int64(slot))])
            return ["message": .string(message)]
        case "app.quit":
            if app.game.hasWorld() {
                try settleScreensBeforeWorldBoundary()
            } else {
                app.game.clearInput()
            }
            mutate("app.quit_requested")
            return ["quitting": .bool(true)]
        default:
            throw RuntimeError(.unknownOperation, "Unknown operation: \(request.operation)")
        }
    }

    private func beginCapture(_ request: DebugRequest, fingerprint: Data,
                              completion: @escaping (DebugResponse) -> Void) throws {
        guard app.renderer != nil else { throw RuntimeError(.unloaded, "Renderer is unavailable") }
        guard app.window?.isVisible == true, app.window?.isMiniaturized == false else {
            throw RuntimeError(.wrongState, "Capture requires a visible, non-minimized window")
        }
        let includeUI = try optionalBool(request.arguments, "includeUI") ?? true
        guard includeUI || app.game.hasWorld() else {
            throw RuntimeError(.noWorld, "A world-only capture requires a loaded world")
        }
        let enqueueEpoch = epoch
        let enqueueWorldIdentity = currentWorldIdentity()
        let enqueueControllerGeneration = controllerGeneration
        let artifactID = UUID().uuidString.lowercased()
        let url = artifactDirectory.appendingPathComponent("capture-\(artifactID).png")
        guard url.deletingLastPathComponent().standardizedFileURL == artifactDirectory.standardizedFileURL,
              !FileManager.default.fileExists(atPath: url.path) else {
            throw RuntimeError(.internalFailure, "Could not reserve capture artifact")
        }
        let queued = app.renderer.requestCapture(path: url.path, includeUI: includeUI) {
            [weak self] result in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.inFlightRequests.removeValue(forKey: request.id) != nil else {
                    try? FileManager.default.removeItem(at: url)
                    return
                }
                self.capturePaths.removeValue(forKey: request.id)
                self.captureTimeouts.removeValue(forKey: request.id)?.cancel()
                let response: DebugResponse
                self.synchronizeExternalWorldIdentity()
                if request.isExpired(atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds) {
                    try? FileManager.default.removeItem(at: url)
                    response = self.failure(request, .deadlineExceeded,
                                            "Capture completed after its deadline")
                } else if self.epoch != enqueueEpoch
                            || self.currentWorldIdentity() != enqueueWorldIdentity
                            || self.controllerGeneration != enqueueControllerGeneration {
                    try? FileManager.default.removeItem(at: url)
                    response = self.failure(request, .wrongEpoch,
                                            "Capture authority or world changed before completion")
                } else if result.succeeded,
                   let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                   data.count <= 64 * 1_024 * 1_024 {
                    let hash = Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
                    self.mutate("render.captured", payload: ["artifactID": .string(artifactID)])
                    response = DebugResponse(requestID: request.id, result: [
                        "artifactID": .string(artifactID), "path": .string(url.path),
                        "sha256": .string(hash), "bytes": .integer(Int64(data.count)),
                        "width": .integer(Int64(result.width)),
                        "height": .integer(Int64(result.height)),
                        "includeUI": .bool(includeUI),
                    ], epoch: self.epoch, revision: self.revision,
                       eventSequence: self.eventSequence)
                } else {
                    try? FileManager.default.removeItem(at: url)
                    response = self.failure(request, .internalFailure, "Frame capture failed")
                }
                self.complete(request, fingerprint: fingerprint, response: response,
                              completion: completion)
            }
        }
        guard queued else { throw RuntimeError(.busy, "Capture queue is full", retryable: true) }
        capturePaths[request.id] = url
        let now = DispatchTime.now().uptimeNanoseconds
        let hardDeadline = now.addingReportingOverflow(15_000_000_000)
        let timeoutAt = min(request.deadlineUptimeNanoseconds ?? UInt64.max,
                            hardDeadline.overflow ? UInt64.max : hardDeadline.partialValue)
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.inFlightRequests.removeValue(forKey: request.id) != nil else { return }
            self.captureTimeouts.removeValue(forKey: request.id)
            self.capturePaths.removeValue(forKey: request.id)
            _ = self.app.renderer.cancelCapture(path: url.path)
            try? FileManager.default.removeItem(at: url)
            let deadlineElapsed = request.isExpired(
                atUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds)
            let response = self.failure(
                request, deadlineElapsed ? .deadlineExceeded : .timeout,
                deadlineElapsed ? "Capture deadline elapsed" : "Frame capture timed out",
                retryable: !deadlineElapsed)
            self.complete(request, fingerprint: fingerprint, response: response,
                          completion: completion)
        }
        captureTimeouts[request.id] = timeout
        let delay = timeoutAt > now ? timeoutAt - now : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(min(delay, UInt64(Int.max)))),
                                      execute: timeout)
        app.scheduleDebugCaptureDraw()
    }

    private func makeSnapshot(arguments: [String: JSONValue]) throws -> DebugSnapshot {
        let requested = try optionalStringArray(arguments, "scopes", maximumCount: 32,
                                                maximumBytes: 64)
        let scopes = requested?.map(DebugSnapshotScope.init(rawValue:)) ?? [
            .app, .world, .player, .target, .inventory, .rpg, .screen, .entities,
            .renderer, .network,
        ]
        let limit = min(1_024, max(1, try optionalInt(arguments, "limit") ?? 256))
        var sections: [String: JSONValue] = [:]
        var truncated: [DebugSnapshotScope] = []
        for scope in scopes {
            switch scope {
            case .app:
                sections[scope.rawValue] = .object([
                    "version": .string(ELYSIUM_VERSION),
                    "debugControl": .bool(true),
                    "profile": .string("isolated-debug"),
                    "manualClock": .bool(app.game.isDebugManualClockEnabled),
                ])
            case .world:
                sections[scope.rawValue] = app.game.hasWorld() ? .object([
                    "record": app.game.worldRec.map(worldRecordValue) ?? .null,
                    "dimension": .integer(Int64(app.game.dim.rawValue)),
                    "time": .integer(Int64(app.game.world.time)),
                    "dayTime": .integer(Int64(app.game.world.dayTime)),
                    "raining": .bool(app.game.world.raining),
                    "thundering": .bool(app.game.world.thundering),
                    "loadedChunks": .integer(Int64(app.game.world.chunks.count)),
                ]) : .null
            case .player:
                sections[scope.rawValue] = app.game.hasWorld() ? .object(playerValue()) : .null
            case .target:
                if app.game.hasWorld(), let hit = app.game.crosshairBlock() {
                    sections[scope.rawValue] = .object([
                        "x": .integer(Int64(hit.x)), "y": .integer(Int64(hit.y)),
                        "z": .integer(Int64(hit.z)), "face": .integer(Int64(hit.face)),
                        "cell": .integer(Int64(hit.cell)),
                        "block": .string(blockName(hit.cell >> 4)),
                    ])
                } else { sections[scope.rawValue] = .null }
            case .inventory:
                sections[scope.rawValue] = app.game.hasWorld()
                    ? .array(app.game.player.inventory.enumerated().map { index, stack in
                        .object(["slot": .integer(Int64(index)), "stack": stackValue(stack)])
                    }) : .array([])
            case .rpg:
                sections[scope.rawValue] = app.game.hasWorld()
                    ? try jsonValue(app.game.player.rpg) : .null
            case .screen:
                sections[scope.rawValue] = .object(
                    DebugScreenSemantics(ui: app.ui, game: app.game).snapshot())
            case .entities:
                guard app.game.hasWorld() else { sections[scope.rawValue] = .array([]); continue }
                let all = app.game.world.entities.compactMap { $0 as? Entity }
                let selected = all.prefix(limit)
                if all.count > selected.count { truncated.append(scope) }
                sections[scope.rawValue] = .array(selected.map { entity in
                    .object(["id": .integer(Int64(entity.id)), "type": .string(entity.type),
                             "x": .number(entity.x), "y": .number(entity.y),
                             "z": .number(entity.z), "dead": .bool(entity.dead)])
                })
            case .region:
                guard app.game.hasWorld() else { sections[scope.rawValue] = .array([]); continue }
                let radius = min(8, max(0, try optionalInt(arguments, "radius") ?? 2))
                let cx = try optionalInt(arguments, "x") ?? Int(app.game.player.x.rounded(.down))
                let cy = try optionalInt(arguments, "y") ?? Int(app.game.player.y.rounded(.down))
                let cz = try optionalInt(arguments, "z") ?? Int(app.game.player.z.rounded(.down))
                let minX = cx.subtractingReportingOverflow(radius)
                let maxX = cx.addingReportingOverflow(radius)
                let minY = cy.subtractingReportingOverflow(radius)
                let maxY = cy.addingReportingOverflow(radius)
                let minZ = cz.subtractingReportingOverflow(radius)
                let maxZ = cz.addingReportingOverflow(radius)
                guard !minX.overflow, !maxX.overflow, !minY.overflow, !maxY.overflow,
                      !minZ.overflow, !maxZ.overflow,
                      (-30_000_000...30_000_000).contains(cx),
                      (-30_000_000...30_000_000).contains(cz),
                      cy >= app.game.world.info.minY,
                      cy < app.game.world.info.minY + app.game.world.info.height else {
                    throw RuntimeError(.invalidArguments, "Region center is outside world bounds")
                }
                var blocks: [JSONValue] = []
                outer: for y in minY.partialValue...maxY.partialValue {
                    for z in minZ.partialValue...maxZ.partialValue {
                        for x in minX.partialValue...maxX.partialValue {
                            guard blocks.count < limit else { truncated.append(scope); break outer }
                            let cellValue = app.game.world.getBlock(x, y, z)
                            let id = cellValue >> 4
                            if id != 0 {
                                blocks.append(.object(["x": .integer(Int64(x)),
                                    "y": .integer(Int64(y)), "z": .integer(Int64(z)),
                                    "cell": .integer(Int64(cellValue)),
                                    "meta": .integer(Int64(cellValue & 15)),
                                    "id": .integer(Int64(id)), "name": .string(blockName(id)),
                                    "blockEntity": app.game.world.getBlockEntity(x, y, z)
                                        .map { JSONValue.string($0.type) } ?? .null]))
                            }
                        }
                    }
                }
                sections[scope.rawValue] = .array(blocks)
            case .renderer:
                let culling = app.renderer.cullingStats
                sections[scope.rawValue] = .object([
                    "drawableWidth": .integer(Int64(app.gameView.drawableSize.width)),
                    "drawableHeight": .integer(Int64(app.gameView.drawableSize.height)),
                    "atlasResolution": .integer(Int64(app.renderer.atlasRes)),
                    "drawCalls": .integer(Int64(app.renderer.drawCalls)),
                    "totalSections": .integer(Int64(culling.totalSections)),
                    "emptySections": .integer(Int64(culling.emptySections)),
                    "distanceCulledSections": .integer(Int64(culling.distanceCulledSections)),
                    "frustumCulledSections": .integer(Int64(culling.frustumCulledSections)),
                    "visibleSections": .integer(Int64(culling.visibleSections)),
                    "shadowCandidates": .integer(Int64(culling.shadowCandidates)),
                    "shadowRangeCulledSections": .integer(Int64(culling.shadowRangeCulledSections)),
                    "shadowFrustumCulledSections": .integer(Int64(culling.shadowFrustumCulledSections)),
                    "shadowVisibleSections": .integer(Int64(culling.shadowVisibleSections)),
                ])
            case .network:
                sections[scope.rawValue] = .object(lanStatusValue())
            default:
                sections[scope.rawValue] = .null
            }
        }
        let identity = DebugSnapshotIdentity(
            sessionID: sessionID, epoch: epoch, revision: revision,
            eventSequence: eventSequence,
            simulationTick: app.game.hasWorld() ? UInt64(max(0, app.game.world.time)) : nil,
            dimensionID: app.game.hasWorld() ? String(app.game.dim.rawValue) : nil,
            screenGeneration: app.ui.current().map { UInt64($0.textPresentationGeneration) },
            registryGeneration: 1)
        return DebugSnapshot(identity: identity, sections: sections,
                             truncatedScopes: truncated)
    }

    private func lanStatusValue() -> [String: JSONValue] {
        let status = LANMultiplayerManager.shared.debugControlStatus()
        return [
            "state": .string(status.state.rawValue),
            "role": .string(status.role),
            "wireProtocolVersion": .integer(Int64(LAN_MULTIPLAYER_PROTOCOL_VERSION)),
            "transportSecurity": .string("trusted-lan-plaintext"),
            "acceptedClientCount": .integer(Int64(status.acceptedClientCount)),
            "maximumClientCount": .integer(Int64(LAN_MULTIPLAYER_MAX_CLIENTS)),
            "discoveredHostCount": .integer(Int64(status.discoveredHostCount)),
            "listeningPort": status.listeningPort.map { .integer(Int64($0)) } ?? .null,
            "lanClient": .bool(app.game.isLANClientWorld),
            "lanConnectionLost": .bool(app.game.lanConnectionLost),
        ]
    }

    private func rpgRegistry() throws -> [String: JSONValue] {
        [
            "paths": .array(RPG_PATH_DEFINITIONS.map { path in
                .object(["id": .string(path.id), "displayName": .string(path.displayName),
                         "branches": .array(path.branchIDs.map(JSONValue.string)),
                         "starterSkills": .array(path.starterSkillIDs.map(JSONValue.string))])
            }),
            "branches": .array(RPG_BRANCH_DEFINITIONS.map { branch in
                .object(["id": .string(branch.id), "path": .string(branch.pathID),
                         "displayName": .string(branch.displayName),
                         "skills": .array(branch.skillIDs.map(JSONValue.string))])
            }),
            "skills": .array(RPG_SKILL_DEFINITIONS.map { skill in
                .object(["id": .string(skill.id), "path": .string(skill.pathID),
                         "branch": .string(skill.branchID),
                         "displayName": .string(skill.displayName)])
            }),
            "spells": .array(RPG_SPELL_DEFINITIONS.map { spell in
                .object(["id": .string(spell.id), "displayName": .string(spell.displayName)])
            }),
        ]
    }

    private func decodeAIAgentAction(_ arguments: [String: JSONValue]) throws -> AIAgentAction {
        guard let actionValue = arguments["action"] else {
            throw RuntimeError(.invalidArguments, "Missing action object")
        }
        let data = try JSONEncoder().encode(actionValue)
        do { return try JSONDecoder().decode(AIAgentAction.self, from: data) }
        catch { throw RuntimeError(.invalidArguments, "Invalid action object") }
    }

    private func runtimeError(for error: TemplateError) -> RuntimeError {
        switch error {
        case .objectTooLarge, .objectTooWide, .tooManyBlockEntities:
            return RuntimeError(.boundedLimit, error.description)
        case .destinationUnavailable:
            return RuntimeError(.unloaded, error.description, retryable: true)
        case .destinationBlocked, .foundationTooDeep:
            return RuntimeError(.placementRejected, error.description)
        case .invalidName, .missingTarget, .targetNotCloneable, .templateEmpty,
             .unsupportedVersion, .corruptTemplate:
            return RuntimeError(.invalidArguments, error.description)
        }
    }

    private func runtimeError(for error: AIAgentError) -> RuntimeError {
        switch error {
        case .responseTooLarge, .holeFillTooLarge, .regionFillTooLarge:
            return RuntimeError(.boundedLimit, error.description)
        case .unloadedTarget:
            return RuntimeError(.unloaded, error.description, retryable: true)
        case .placementFailed, .inventoryFull, .entitySpawnFailed,
             .blockBreakFailed, .blockUseFailed:
            return RuntimeError(.placementRejected, error.description)
        case .templateWriteFailed:
            return RuntimeError(.persistenceFailed, error.description)
        default:
            return RuntimeError(.invalidArguments, error.description)
        }
    }

    private func debugCursor(arguments: [String: JSONValue]) throws -> RaycastHit? {
        if let rawCursor = arguments["cursor"] {
            guard case .object(let cursor) = rawCursor else {
                throw RuntimeError(.invalidArguments, "cursor must be an object")
            }
            let x = try int(cursor, "x"), y = try int(cursor, "y")
            let z = try int(cursor, "z"), face = try int(cursor, "face")
            guard app.game.hasWorld(), (0...5).contains(face) else {
                throw RuntimeError(.invalidArguments, "cursor face must be 0...5")
            }
            try validateCoordinate(x, y, z)
            return RaycastHit(x: x, y: y, z: z, face: face,
                              cell: app.game.world.getBlock(x, y, z), t: 0,
                              px: Double(x) + 0.5, py: Double(y) + 0.5,
                              pz: Double(z) + 0.5)
        }
        return app.game.hasWorld() ? app.game.crosshairBlock() : nil
    }

    private func boundedCoordinate(_ arguments: [String: JSONValue]) throws -> (Int, Int, Int) {
        let x = try int(arguments, "x"), y = try int(arguments, "y"), z = try int(arguments, "z")
        try validateCoordinate(x, y, z)
        return (x, y, z)
    }

    private func validateCoordinate(_ x: Int, _ y: Int, _ z: Int) throws {
        let world = app.game.world
        guard y >= world.info.minY, y < world.info.minY + world.info.height else {
            throw RuntimeError(.invalidArguments, "Coordinate is outside world height")
        }
        let px = Int(app.game.player.x.rounded(.down)), pz = Int(app.game.player.z.rounded(.down))
        let dx = x.subtractingReportingOverflow(px)
        let dz = z.subtractingReportingOverflow(pz)
        guard !dx.overflow, !dz.overflow,
              (-Self.maximumCoordinateDistance...Self.maximumCoordinateDistance).contains(dx.partialValue),
              (-Self.maximumCoordinateDistance...Self.maximumCoordinateDistance).contains(dz.partialValue) else {
            throw RuntimeError(.boundedLimit, "Target is outside the debug setup radius")
        }
        guard world.isLoadedAt(x, z) else {
            throw RuntimeError(.unloaded, "Target chunk is not loaded", retryable: true)
        }
    }

    private func checkedVolume(minX: Int, minY: Int, minZ: Int,
                               maxX: Int, maxY: Int, maxZ: Int) throws -> Int {
        let dx = maxX.subtractingReportingOverflow(minX)
        let dy = maxY.subtractingReportingOverflow(minY)
        let dz = maxZ.subtractingReportingOverflow(minZ)
        guard !dx.overflow, !dy.overflow, !dz.overflow else {
            throw RuntimeError(.boundedLimit, "Fill volume overflow")
        }
        let x = dx.partialValue.addingReportingOverflow(1)
        let y = dy.partialValue.addingReportingOverflow(1)
        let z = dz.partialValue.addingReportingOverflow(1)
        guard !x.overflow, !y.overflow, !z.overflow else {
            throw RuntimeError(.boundedLimit, "Fill volume overflow")
        }
        let xy = x.partialValue.multipliedReportingOverflow(by: y.partialValue)
        let xyz = xy.partialValue.multipliedReportingOverflow(by: z.partialValue)
        guard !xy.overflow, !xyz.overflow, xyz.partialValue >= 0 else {
            throw RuntimeError(.boundedLimit, "Fill volume overflow")
        }
        return xyz.partialValue
    }

    private func requireWorld(authoritative: Bool) throws {
        guard app.game.hasWorld(), app.game.player != nil else {
            throw RuntimeError(.noWorld, "No world is loaded")
        }
        if authoritative { try requireNoLANClient() }
    }

    private func requireNoLANClient() throws {
        guard !app.game.isLANClientWorld else {
            throw RuntimeError(.forbiddenInLANClient,
                               "The LAN host owns authoritative mutation")
        }
    }

    /// Uses the same immutable, receipt-bearing transaction as the saved-world screen. A
    /// terminal recovery remains owned by this runtime with the maintenance lease held; a fresh
    /// request for the same id resumes recovery instead of inferring success from a failed read.
    private func deleteWorldChecked(_ id: String) throws {
        if let pending = pendingWorldDeleteRecovery {
            guard pending.id == id else {
                throw RuntimeError(
                    .busy,
                    "A prior world deletion requires recovery before another world can be deleted",
                    retryable: true)
            }
            let state: DebugWorldDeleteCompletion
            do {
                state = try finishWorldDelete(pending, outcome: pending.operation.recover())
            } catch {
                pendingWorldDeleteRecovery = nil
                app.game.releaseSavedWorldMaintenance(pending.token)
                throw error
            }
            switch state {
            case .deleted:
                pendingWorldDeleteRecovery = nil
                app.game.releaseSavedWorldMaintenance(pending.token)
                return
            case .needsRecovery:
                throw RuntimeError(
                    .persistenceFailed,
                    "World deletion is committed but its durable receipt still requires recovery; retry with a new request id",
                    retryable: true)
            }
        }

        let snapshot: CheckedSavedWorldSnapshot
        do {
            snapshot = try app.game.checkedWorldSnapshot()
        } catch {
            throw RuntimeError(.persistenceFailed,
                               "Saved-world authority could not be read safely", retryable: true)
        }
        guard snapshot.rows.contains(where: { $0.storedID == id }) else {
            throw RuntimeError(.invalidArguments, "Unknown world id")
        }
        let request: SavedWorldDeleteRequest
        do {
            request = try snapshot.deleteRequest(selectedIDs: [id])
        } catch {
            throw RuntimeError(.persistenceFailed,
                               "Saved-world deletion request could not be bound to storage")
        }
        guard let token = app.game.acquireSavedWorldMaintenance() else {
            throw RuntimeError(.busy, "Saved-world maintenance is already active", retryable: true)
        }
        var releaseToken = true
        defer {
            if releaseToken { app.game.releaseSavedWorldMaintenance(token) }
        }
        let screenIdentity = token.value
        let launchContextIdentity = UUID()
        guard let operation = app.game.admitSavedWorldDelete(
            token, request: request, screenIdentity: screenIdentity,
            launchContextIdentity: launchContextIdentity) else {
            throw RuntimeError(.wrongState, "Saved-world deletion admission became stale",
                               retryable: true)
        }
        let context = DebugWorldDeleteRecovery(
            id: id, token: token, operation: operation,
            screenIdentity: screenIdentity, launchContextIdentity: launchContextIdentity)
        switch try finishWorldDelete(context, outcome: operation.execute()) {
        case .deleted:
            return
        case .needsRecovery:
            pendingWorldDeleteRecovery = context
            releaseToken = false
            throw RuntimeError(
                .persistenceFailed,
                "World deletion is committed but its durable receipt requires recovery; retry with a new request id",
                retryable: true)
        }
    }

    private func finishWorldDelete(
        _ context: DebugWorldDeleteRecovery, outcome: SavedWorldDeleteOutcome
    ) throws -> DebugWorldDeleteCompletion {
        guard app.game.finishSavedWorldDeleteOperation(
            context.operation, outcome: outcome,
            screenIdentity: context.screenIdentity,
            launchContextIdentity: context.launchContextIdentity) else {
            throw RuntimeError(.persistenceFailed,
                               "Saved-world deletion receipt failed contextual validation")
        }
        switch outcome {
        case .direct(let receipt), .recovered(let receipt):
            guard receipt.deletedWorldCount == 1 else {
                throw RuntimeError(.persistenceFailed,
                                   "Saved-world deletion receipt had an invalid delete count")
            }
            return .deleted
        case .terminalRecovery:
            return .needsRecovery
        case .provenPrecommitFailure:
            throw RuntimeError(.persistenceFailed,
                               "World deletion failed before commit", retryable: true)
        case .stale:
            throw RuntimeError(.wrongState,
                               "Saved-world authority changed before deletion", retryable: true)
        case .terminalIntegrity:
            throw RuntimeError(.persistenceFailed,
                               "World deletion could not establish a trustworthy receipt")
        }
    }

    private func settleScreensBeforeWorldBoundary() throws {
        // Cursor and screen-local items still belong to the current player. Settle both while
        // that player/world is valid, then verify maintenance did not refuse the close.
        disconnect()
        app.ui.closeAll(app.game)
        disconnect()
        guard !app.ui.hasScreen() else {
            throw RuntimeError(.busy, "A screen could not close during saved-world maintenance",
                               retryable: true)
        }
        if !app.game.isLANClientWorld, !app.game.saveAndFlushChecked() {
            throw RuntimeError(.persistenceFailed,
                               "World, player, advancement, or chunk persistence failed")
        }
    }

    @discardableResult
    private func setDebugBlock(x: Int, y: Int, z: Int, value: Int) -> Int {
        let world = app.game.world
        let old = world.getBlock(x, y, z)
        let oldID = old >> 4
        let newID = value >> 4
        if oldID != newID {
            // World.setBlock deliberately preserves same-shape solid block entities for ordinary
            // transitions. A raw debug replacement has no such semantic continuity.
            world.removeBlockEntity(x, y, z)
        }
        _ = world.setBlock(x, y, z, value)
        if oldID != newID, newID != 0, world.getBlock(x, y, z) == value,
           let blockEntity = defaultDebugBlockEntity(blockID: newID, x: x, y: y, z: z) {
            world.setBlockEntity(blockEntity)
        }
        return old
    }

    private func defaultDebugBlockEntity(blockID: Int, x: Int, y: Int,
                                         z: Int) -> BlockEntityData? {
        guard blockID > 0, blockID < blockDefs.count else { return nil }
        let name = blockDefs[blockID].name
        switch name {
        case "chest", "trapped_chest", "barrel":
            return makeContainerBE(x, y, z, 27)
        case "furnace", "furnace_lit":
            return makeFurnaceBE(x, y, z, "furnace")
        case "blast_furnace", "blast_furnace_lit":
            return makeFurnaceBE(x, y, z, "blast")
        case "smoker", "smoker_lit":
            return makeFurnaceBE(x, y, z, "smoker")
        case "brewing_stand":
            return makeBrewingBE(x, y, z)
        case "hopper":
            return makeHopperBE(x, y, z)
        case "dispenser", "dropper":
            return makeContainerBE(x, y, z, 9)
        case "crafting_table":
            return makeCraftingTableBE(x, y, z)
        case "beacon":
            let entity = BlockEntityData(type: "beacon", x: x, y: y, z: z)
            entity.levels = 0
            return entity
        case "conduit":
            let entity = BlockEntityData(type: "conduit", x: x, y: y, z: z)
            entity.active = false
            return entity
        case "decorated_pot":
            let entity = BlockEntityData(type: "pot", x: x, y: y, z: z)
            entity.sherds = [nil, nil, nil, nil]
            return entity
        default:
            if name.hasSuffix("shulker_box") {
                return makeContainerBE(x, y, z, 27)
            }
            switch blockDefs[blockID].shape {
            case .sign, .wallSign, .hangingSign:
                return makeSignBE(x, y, z)
            default:
                return nil
            }
        }
    }

    private func playerPositionValue() -> [String: JSONValue] {
        let p = app.game.player!
        return ["x": .number(p.x), "y": .number(p.y), "z": .number(p.z),
                "yaw": .number(p.yaw), "pitch": .number(p.pitch)]
    }

    private func normalizedYaw(_ value: Double) -> Double {
        let turn = Double.pi * 2
        var result = value.truncatingRemainder(dividingBy: turn)
        if result >= Double.pi { result -= turn }
        if result < -Double.pi { result += turn }
        return result
    }

    private func playerValue() -> [String: JSONValue] {
        let p = app.game.player!
        return playerPositionValue().merging([
            "health": .number(p.health), "maxHealth": .number(p.maxHealth),
            "hunger": .integer(Int64(p.hunger)), "saturation": .number(p.saturation),
            "mode": .integer(Int64(p.gameMode)), "flying": .bool(p.flying),
            "selectedSlot": .integer(Int64(p.selectedSlot)),
            "xp": .integer(Int64(p.xp)), "xpLevel": .integer(Int64(p.xpLevel)),
            "xpProgress": .number(p.xpProgress),
            "absorption": .number(p.absorption),
            "effects": .array(p.effects.prefix(64).map { effect in
                .object(["id": .string(effect.id),
                         "duration": .integer(Int64(effect.duration)),
                         "amplifier": .integer(Int64(effect.amplifier)),
                         "ambient": effect.ambient.map(JSONValue.bool) ?? .null,
                         "showParticles": effect.showParticles.map(JSONValue.bool) ?? .null])
            }),
        ], uniquingKeysWith: { _, new in new })
    }

    private func stackValue(_ stack: ItemStack?) -> JSONValue {
        DebugStackProjection.value(stack)
    }

    private func worldRecordValue(_ record: WorldRecord) -> JSONValue {
        .object(["id": .string(record.id), "name": .string(record.name),
                 "seed": .integer(Int64(record.seed)),
                 "mode": .integer(Int64(record.gameMode)),
                 "difficulty": .integer(Int64(record.difficulty)),
                 "preset": .string(record.worldPreset),
                 "biome": .string(record.singleBiome),
                 "dungeonDensity": .integer(Int64(record.dungeonDensity)),
                 "lastPlayed": .number(record.lastPlayed)])
    }

    private func mutate(_ name: String, payload: [String: JSONValue] = [:]) {
        if revision < UInt64.max { revision += 1 }
        emit(name, payload: payload)
    }

    /// `script.*` ops share this one call site into `ScriptingCommands.run` — the
    /// design.md §12 Core-side executors — so every `script.*` op returns the exact
    /// same shape (`ok`, `lines`) and can never drift from what `/script` itself
    /// would have done for the same arguments.
    private func scriptCommandResponse(_ arguments: [String]) -> [String: JSONValue] {
        let result = ScriptingCommands.run(
            command: "script", arguments: arguments, context: app.game.scriptingCommandContext()
        )
        return ["ok": .bool(result.ok), "lines": .array(result.lines.map(JSONValue.string))]
    }

    private func currentWorldIdentity() -> RuntimeWorldIdentity {
        guard app.game.hasWorld() else { return .title }
        return RuntimeWorldIdentity(worldObject: ObjectIdentifier(app.game.world),
                                    recordID: app.game.worldRec?.id,
                                    dimension: app.game.dim.rawValue)
    }

    private func cancelPendingCaptures() {
        for url in capturePaths.values {
            _ = app.renderer?.cancelCapture(path: url.path)
        }
    }

    private func synchronizeExternalWorldIdentity() {
        let current = currentWorldIdentity()
        guard current != observedWorldIdentity else { return }
        let previous = observedWorldIdentity
        observedWorldIdentity = current
        if epoch < UInt64.max { epoch += 1 }
        if revision < UInt64.max { revision += 1 }
        templateUndo = nil
        cancelPendingCaptures()
        emit("world.external_transition", payload: [
            "previousWorldID": previous.recordID.map(JSONValue.string) ?? .null,
            "worldID": current.recordID.map(JSONValue.string) ?? .null,
            "previousDimension": previous.dimension.map { .integer(Int64($0)) } ?? .null,
            "dimension": current.dimension.map { .integer(Int64($0)) } ?? .null,
        ])
    }

    private func worldBoundaryEvent(_ name: String, payload: [String: JSONValue]) {
        observedWorldIdentity = currentWorldIdentity()
        if epoch < UInt64.max { epoch += 1 }
        if revision < UInt64.max { revision += 1 }
        templateUndo = nil
        cancelPendingCaptures()
        emit(name, payload: payload)
    }

    private func emit(_ name: String, payload: [String: JSONValue]) {
        guard eventSequence < UInt64.max else { return }
        eventSequence += 1
        guard let event = try? DebugEvent(name: name, sequence: eventSequence,
                                          epoch: epoch, revision: revision,
                                          simulationTick: app.game.hasWorld()
                                            ? UInt64(max(0, app.game.world.time)) : nil,
                                          payload: payload) else { return }
        events.append(event)
        if events.count > Self.maximumEvents {
            events.removeFirst(events.count - Self.maximumEvents)
        }
    }

    private func complete(_ request: DebugRequest, fingerprint: Data,
                          response: DebugResponse,
                          completion: @escaping (DebugResponse) -> Void) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var finalResponse = response
        var encoded = try? encoder.encode(finalResponse)
        if encoded.map({ $0.count > DebugFrameLimits.absoluteMaximumPayloadBytes }) ?? true {
            finalResponse = failure(
                request, .boundedLimit,
                "Response exceeds the negotiated payload limit; request a smaller page or snapshot")
            encoded = try? encoder.encode(finalResponse)
        }
        let responseBytes = encoded?.count ?? 1_024
        if let existing = cachedResponses[request.id] {
            cachedResponseBytes = max(0, cachedResponseBytes - existing.bytes)
            cachedOrder.removeAll { $0 == request.id }
        }
        cachedResponses[request.id] = (fingerprint, finalResponse, responseBytes)
        cachedOrder.append(request.id)
        cachedResponseBytes += responseBytes
        while cachedOrder.count > Self.maximumCachedRequests
                || cachedResponseBytes > Self.maximumCachedResponseBytes,
              let expired = cachedOrder.first {
            cachedOrder.removeFirst()
            if let removed = cachedResponses.removeValue(forKey: expired) {
                cachedResponseBytes = max(0, cachedResponseBytes - removed.bytes)
            }
        }
        completion(finalResponse)
    }

    private func failure(_ request: DebugRequest, _ code: DebugErrorCode,
                         _ message: String, retryable: Bool = false) -> DebugResponse {
        DebugResponse(requestID: request.id,
                      error: DebugError(code: code, message: message,
                                        retryable: retryable),
                      epoch: epoch, revision: revision,
                      eventSequence: eventSequence)
    }

    private func requestFingerprint(_ request: DebugRequest) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(request)) ?? Data()
        return Data(SHA256.hash(data: data))
    }

    private func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    private func safeInt64(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }

    func terminateAfterResponseDelivery() {
        NSApp.terminate(nil)
    }
}

private struct RuntimeWorldIdentity: Equatable {
    static let title = RuntimeWorldIdentity(worldObject: nil, recordID: nil, dimension: nil)

    let worldObject: ObjectIdentifier?
    let recordID: String?
    let dimension: Int?
}

private struct DebugTemplateUndo {
    let worldID: String
    let snapshot: TemplatePlacementUndoSnapshot
}

private struct DebugWorldDeleteRecovery {
    let id: String
    let token: SavedWorldMaintenanceCoordinator.Token
    let operation: SavedWorldDeleteOperation
    let screenIdentity: UInt64
    let launchContextIdentity: UUID
}

private enum DebugWorldDeleteCompletion {
    case deleted
    case needsRecovery
}

private struct RuntimeError: Error {
    let code: DebugErrorCode
    let message: String
    let retryable: Bool

    init(_ code: DebugErrorCode, _ message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

private func int(_ values: [String: JSONValue], _ key: String) throws -> Int {
    guard let value = try optionalInt(values, key) else {
        throw RuntimeError(.invalidArguments, "Missing integer argument: \(key)")
    }
    return value
}

private func optionalInt(_ values: [String: JSONValue], _ key: String) throws -> Int? {
    guard let value = values[key] else { return nil }
    switch value {
    case .integer(let number):
        guard let exact = Int(exactly: number) else {
            throw RuntimeError(.invalidArguments, "Integer is out of range: \(key)")
        }
        return exact
    default: throw RuntimeError(.invalidArguments, "Expected integer: \(key)")
    }
}

private func optionalUInt64(_ values: [String: JSONValue], _ key: String) throws -> UInt64? {
    guard let value = try optionalInt(values, key) else { return nil }
    guard value >= 0 else { throw RuntimeError(.invalidArguments, "Expected unsigned integer: \(key)") }
    return UInt64(value)
}

private func finiteDouble(_ values: [String: JSONValue], _ key: String) throws -> Double {
    guard let value = values[key] else {
        throw RuntimeError(.invalidArguments, "Missing number argument: \(key)")
    }
    let number: Double
    switch value {
    case .integer(let v): number = Double(v)
    case .number(let v): number = v
    default: throw RuntimeError(.invalidArguments, "Expected number: \(key)")
    }
    guard number.isFinite else { throw RuntimeError(.invalidArguments, "Number must be finite: \(key)") }
    return number
}

private func bool(_ values: [String: JSONValue], _ key: String) throws -> Bool {
    guard let value = try optionalBool(values, key) else {
        throw RuntimeError(.invalidArguments, "Missing boolean argument: \(key)")
    }
    return value
}

private func optionalBool(_ values: [String: JSONValue], _ key: String) throws -> Bool? {
    guard let value = values[key] else { return nil }
    guard case .bool(let bool) = value else {
        throw RuntimeError(.invalidArguments, "Expected boolean: \(key)")
    }
    return bool
}

private func boundedString(_ values: [String: JSONValue], _ key: String,
                           maximumBytes: Int) throws -> String {
    guard let value = try optionalString(values, key, maximumBytes: maximumBytes) else {
        throw RuntimeError(.invalidArguments, "Missing string argument: \(key)")
    }
    return value
}

private func optionalString(_ values: [String: JSONValue], _ key: String,
                            maximumBytes: Int) throws -> String? {
    guard let value = values[key] else { return nil }
    guard case .string(let string) = value, string.utf8.count <= maximumBytes else {
        throw RuntimeError(.invalidArguments, "Invalid or oversized string: \(key)")
    }
    return string
}

private func optionalStringArray(_ values: [String: JSONValue], _ key: String,
                                 maximumCount: Int, maximumBytes: Int) throws -> [String]? {
    guard let value = values[key] else { return nil }
    guard case .array(let array) = value, array.count <= maximumCount else {
        throw RuntimeError(.invalidArguments, "Invalid or oversized array: \(key)")
    }
    return try array.map { element in
        guard case .string(let string) = element, string.utf8.count <= maximumBytes else {
            throw RuntimeError(.invalidArguments, "Invalid string in array: \(key)")
        }
        return string
    }
}
#endif
