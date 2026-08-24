import Foundation
import ElysiumCore

private final class LANProbeLog {
    static let shared = LANProbeLog()

    private let path = ProcessInfo.processInfo.environment["ELYSIUM_LAN_PROBE_LOG"]
    private let queue = DispatchQueue(label: "com.briangao.elysium.lanprobe.log")

    func write(_ message: String) {
        let line = "LANPROBE \(message)"
        print(line)
        fflush(stdout)
        guard let path, !path.isEmpty else { return }
        queue.async {
            let url = URL(fileURLWithPath: path)
            let data = Data((line + "\n").utf8)
            FileManager.default.createFile(atPath: path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                _ = try? handle.write(contentsOf: data)
                _ = try? handle.close()
            }
        }
    }
}

func elysiumLANProbeLog(_ message: String) {
    LANProbeLog.shared.write(message)
}

final class LANLiveProbe {
    private enum Mode: String {
        case hostRig = "host-rig"
        case clientDoor = "client-door"
        case clientObserver = "client-observer"
        case clientResume = "client-resume"
    }

    private let mode: Mode
    private var frames = 0
    private var rigBuilt = false
    private var clientWorldFrame: Int?
    private var clientPositionedFrame: Int?
    private var clientUseSent = false
    private var clientUseSentFrame: Int?
    private var clientAttributeMirrorSeen = false
    private var clientUseAttempts = 0
    private var hostStarted = false
    private var completed = false
    private let timeoutFrames: Int
    private let hostJoinCode: String
    private let hostPort: UInt16
    private let expectedHostClients: Int

    init?(environment: [String: String]) {
        guard let rawMode = environment["ELYSIUM_LAN_PROBE"],
              let mode = Mode(rawValue: rawMode)
        else { return nil }
        self.mode = mode
        self.timeoutFrames = environment["ELYSIUM_LAN_PROBE_TIMEOUT_FRAMES"].flatMap(Int.init) ?? 2400
        self.hostJoinCode = environment["ELYSIUM_LAN_PROBE_JOIN_CODE"] ?? "TST42A"
        self.hostPort = environment["ELYSIUM_LAN_PROBE_PORT"].flatMap(UInt16.init) ?? LAN_MULTIPLAYER_DEFAULT_PORT
        self.expectedHostClients = max(1, min(
            LAN_MULTIPLAYER_MAX_CLIENTS,
            environment["ELYSIUM_LAN_PROBE_EXPECTED_CLIENTS"].flatMap(Int.init) ?? 1
        ))
        elysiumLANProbeLog("start mode=\(mode.rawValue)")
    }

    @MainActor
    func tick(app: AppDelegate) {
        guard !completed else { return }
        frames += 1
        if frames > timeoutFrames {
            fail(app: app, "timeout frame=\(frames)")
            return
        }
        switch mode {
        case .hostRig:
            tickHostRig(game: app.game)
        case .clientDoor:
            tickClientSharedState(game: app.game, sendsDoorIntent: true)
        case .clientObserver:
            tickClientSharedState(game: app.game, sendsDoorIntent: false)
        case .clientResume:
            tickClientResume(game: app.game)
        }
    }

    private func base(in game: GameCore) -> (x: Int, y: Int, z: Int) {
        (
            Int(game.world.spawnX.rounded(.down)),
            Int(game.world.spawnY.rounded(.down)),
            Int(game.world.spawnZ.rounded(.down))
        )
    }

    private func door(in game: GameCore) -> (x: Int, y: Int, z: Int) {
        let b = base(in: game)
        return (b.x + 2, b.y, b.z)
    }

    private func chest(in game: GameCore) -> (x: Int, y: Int, z: Int) {
        let b = base(in: game)
        return (b.x - 2, b.y, b.z + 1)
    }

    private func craftingTable(in game: GameCore) -> (x: Int, y: Int, z: Int) {
        let b = base(in: game)
        return (b.x - 1, b.y, b.z + 3)
    }

    private func isDoorOpen(_ cell: Int) -> Bool {
        (cell & 4) != 0
    }

    @MainActor
    private func tickHostRig(game: GameCore) {
        guard game.hasWorld() else { return }
        if !rigBuilt {
            game.player.setGameMode(GameMode.creative)
            game.world.dayTime = 1000
            game.world.raining = false
            game.world.thundering = false
            game.setDifficulty(0)
            buildRig(game)
            rigBuilt = true
        }
        if !hostStarted {
            do {
                try LANMultiplayerManager.shared.startHost(
                    game: game,
                    requestedJoinCode: hostJoinCode,
                    requestedPort: hostPort
                )
                hostStarted = true
                elysiumLANProbeLog("host_started port=\(hostPort)")
            } catch {
                fail(app: nil, "host_start_failed error=\(error)")
                return
            }
        }
        let d = door(in: game)
        let cell = game.world.getBlock(d.x, d.y, d.z)
        let acceptedPeers = LANMultiplayerManager.shared.acceptedHostPeerCountForProbe()
        if (cell >> 4) == Int(B.oak_door), isDoorOpen(cell),
           acceptedPeers == expectedHostClients {
            pass("host remote-use peers=\(acceptedPeers) door=\(d.x),\(d.y),\(d.z) cell=\(cell) frame=\(frames)")
        }
    }

    private func buildRig(_ game: GameCore) {
        let b = base(in: game)
        let world = game.world
        for y in b.y...(b.y + 3) {
            for z in (b.z - 5)...(b.z + 5) {
                for x in (b.x - 5)...(b.x + 5) {
                    _ = world.setBlock(x, y, z, 0)
                }
            }
        }
        for z in (b.z - 5)...(b.z + 5) {
            for x in (b.x - 5)...(b.x + 5) {
                _ = world.setBlock(x, b.y - 1, z, Int(cell(B.stone)))
            }
        }

        let d = door(in: game)
        _ = world.setBlock(d.x, d.y - 1, d.z, Int(cell(B.stone)))
        _ = world.setBlock(d.x, d.y, d.z, Int(cell(B.oak_door, 0)))
        _ = world.setBlock(d.x, d.y + 1, d.z, Int(cell(B.oak_door, 8)))

        let c = chest(in: game)
        _ = world.setBlock(c.x, c.y - 1, c.z, Int(cell(B.stone)))
        _ = world.setBlock(c.x, c.y, c.z, Int(cell(B.chest, 0)))
        let chestBE = makeContainerBE(c.x, c.y, c.z, 27)
        chestBE.items?[0] = ItemStack(iid("stick"), 7)
        world.setBlockEntity(chestBE)

        let t = craftingTable(in: game)
        _ = world.setBlock(t.x, t.y - 1, t.z, Int(cell(B.stone)))
        _ = world.setBlock(t.x, t.y, t.z, Int(cell(B.crafting_table, 0)))
        let tableBE = makeCraftingTableBE(t.x, t.y, t.z)
        tableBE.items?[0] = ItemStack(iid("oak_planks"), 1)
        world.setBlockEntity(tableBE)

        // scripting-ui-and-replication (change 3), design.md §11: reuses this already-reviewed
        // single-machine host+client lab for the object-attribute replication probe rather than
        // adding a second scenario/harness — one custom attribute on `.world` (no coordinates
        // needed, so it needs no companion "where is it" logic on the client side) attached
        // through the exact same `ScriptStore`/`ScriptingCommandContext` the editor and `/script`
        // use. `client-observer`/`client-door` check for it via `LANMultiplayerManager
        // .mirroredAttributes(for:)` — the same read path the Inspector screen uses — in
        // `tickClientSharedState` below.
        let context = game.scriptingCommandContext()
        if case .success = context.scriptStore.attach(
            .world, name: "probe_attr", source: "world.attrs.probe = \"replicated\"",
            mode: .module, triggers: [], by: .player, tick: context.tick
        ) {
            game.scripting.anyScriptsAttached = true
            elysiumLANProbeLog("host_rig_attribute_attached ref=world name=probe")
        } else {
            elysiumLANProbeLog("host_rig_attribute_attach_failed")
        }

        elysiumLANProbeLog(
            "host_rig_ready base=\(b.x),\(b.y),\(b.z) door=\(d.x),\(d.y),\(d.z) chest=\(c.x),\(c.y),\(c.z) crafting=\(t.x),\(t.y),\(t.z)"
        )
    }

    private func tickClientSharedState(game: GameCore, sendsDoorIntent: Bool) {
        guard game.hasWorld(), game.isLANClientWorld, let player = game.player else { return }
        if clientWorldFrame == nil {
            clientWorldFrame = frames
            elysiumLANProbeLog("client_world_ready frame=\(frames)")
        }
        if game.host?.hasScreen() == true {
            game.host?.closeAllScreens()
            game.host?.capturePointer()
            elysiumLANProbeLog("client_closed_screen_for_probe frame=\(frames)")
            return
        }

        if !clientAttributeMirrorSeen,
           LANMultiplayerManager.shared.mirroredAttributes(for: .world)?["probe"] == .string("replicated") {
            clientAttributeMirrorSeen = true
            elysiumLANProbeLog("client_object_attribute_mirrored ref=world name=probe value=replicated frame=\(frames)")
        }

        let d = door(in: game)
        let lower = game.world.getBlock(d.x, d.y, d.z)
        let upper = game.world.getBlock(d.x, d.y + 1, d.z)
        let c = chest(in: game)
        let chestBE = game.world.getBlockEntity(c.x, c.y, c.z)
        let hasChestItem = chestBE?.items?.first??.id == iid("stick") && chestBE?.items?.first??.count == 7
        if hasChestItem {
            elysiumLANProbeLog("client_chest_item stick=7 chest=\(c.x),\(c.y),\(c.z)")
        }

        guard (lower >> 4) == Int(B.oak_door), (upper >> 4) == Int(B.oak_door) else {
            if frames % 120 == 0 {
                elysiumLANProbeLog("client_waiting_for_door lower=\(lower) upper=\(upper)")
            }
            return
        }

        if isDoorOpen(lower), hasChestItem {
            game.saveAndFlush(synchronous: true)
            let latencyFrames = clientUseSentFrame.map { frames - $0 } ?? -1
            let result = sendsDoorIntent ? "shared-state" : "observed-state"
            pass("client \(result) door_open=true chest_item=stick:7 latencyFrames=\(latencyFrames)")
            return
        }

        guard sendsDoorIntent else { return }

        if clientPositionedFrame == nil {
            position(player, toUseDoorAt: d)
            clientPositionedFrame = frames
            elysiumLANProbeLog("client_positioned_for_door frame=\(frames)")
            return
        }

        if let positioned = clientPositionedFrame,
           frames - positioned >= 90,
           (clientUseSentFrame == nil || frames - (clientUseSentFrame ?? 0) >= 60) {
            position(player, toUseDoorAt: d)
            if let hit = game.crosshairBlock() {
                elysiumLANProbeLog("client_crosshair target=\(hit.x),\(hit.y),\(hit.z) cell=\(hit.cell)")
            } else {
                elysiumLANProbeLog("client_crosshair target=none")
            }
            elysiumLANProbeLog("client_block_intent_handler \(game.lanBlockIntentHandler == nil ? "missing" : "ready")")
            clientUseAttempts += 1
            game.mouseDown(2)
            game.mouseUp(2)
            if !clientUseSent {
                clientUseSent = true
            }
            clientUseSentFrame = frames
            elysiumLANProbeLog("client_use_sent attempt=\(clientUseAttempts) door=\(d.x),\(d.y),\(d.z)")
        }
    }

    private func tickClientResume(game: GameCore) {
        guard game.hasWorld(), game.isLANClientWorld, let player = game.player else { return }
        if clientWorldFrame == nil {
            clientWorldFrame = frames
            elysiumLANProbeLog("client_resume_world_ready frame=\(frames)")
        }
        let d = door(in: game)
        let expectedX = Double(d.x) + 0.5
        let expectedY = Double(d.y)
        let expectedZ = Double(d.z) - 3.0
        let dx = abs(player.x - expectedX)
        let dy = abs(player.y - expectedY)
        let dz = abs(player.z - expectedZ)
        if dx <= 0.25, dy <= 0.25, dz <= 0.25 {
            pass(String(format: "client resume-position x=%.2f y=%.2f z=%.2f", player.x, player.y, player.z))
        } else if let ready = clientWorldFrame, frames - ready > 180 {
            fail(
                app: nil,
                String(format: "resume-position-mismatch expected=%.2f,%.2f,%.2f actual=%.2f,%.2f,%.2f",
                       expectedX, expectedY, expectedZ, player.x, player.y, player.z)
            )
        }
    }

    private func position(_ player: Player, toUseDoorAt door: (x: Int, y: Int, z: Int)) {
        let px = Double(door.x) + 0.5
        let py = Double(door.y)
        let pz = Double(door.z) - 3.0
        player.setPos(px, py, pz)
        player.vx = 0
        player.vy = 0
        player.vz = 0
        let eyeY = player.eyeY()
        let tx = Double(door.x) + 0.5
        let ty = Double(door.y) + 1.0
        let tz = Double(door.z) + 0.5
        let dx = tx - px
        let dy = ty - eyeY
        let dz = tz - pz
        let horizontal = max(0.0001, (dx * dx + dz * dz).squareRoot())
        player.yaw = atan2(-dx, dz)
        player.pitch = atan2(-dy, horizontal)
    }

    private func pass(_ message: String) {
        completed = true
        elysiumLANProbeLog("PASS \(message)")
    }

    private func fail(app: AppDelegate?, _ message: String) {
        completed = true
        let state = LANMultiplayerManager.shared.statusSummary().joined(separator: " | ")
        elysiumLANProbeLog("FAIL \(message) state=\(state)")
    }
}
