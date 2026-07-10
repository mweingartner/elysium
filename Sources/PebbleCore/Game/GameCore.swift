// GameCore — the simulation orchestrator (the app target owns rendering
// and UI; everything sim-side lives here, ticking in frozen order). Chunk
// gen/meshing/saves run on GCD queues, persistence goes through SaveDB,
// and input + screens reach the app through the GameHost protocol.

import Foundation

// =============================================================================
// Constants (the frozen baseline)
// =============================================================================
public let TICK_MS = 1000.0 / 20.0
public let REACH_SURVIVAL = 4.5
public let REACH_CREATIVE = 5.0
public let ATTACK_REACH = 3.0

let SAVE_INTERVAL_TICKS = 1200          // 60 s autosave
let GEN_RADIUS_PAD = 1                  // generate one ring beyond render distance
let MAX_GEN_INFLIGHT = 24
let MAX_MESH_INFLIGHT = 26
let LIGHT_BUDGET_MS = 4.0               // seam-stitch time budget per frame
/// how long a LAN client waits for a requested chunk section before retrying the request
let LAN_CHUNK_REQUEST_EXPIRY_TICKS = 60
/// background full-column completion requests issued per LAN client tick (bounded)
let LAN_COLUMN_COMPLETION_REQUESTS_PER_TICK = 2
/// radius (in chunks) around the player scanned for incomplete columns to background-fill
let LAN_COLUMN_COMPLETION_RADIUS = 2

/// item-billboard projectiles (the app renders these as sprites)
public let SPRITE_TYPES: Set<String> = [
    "snowball", "egg", "ender_pearl", "xp_bottle", "thrown_potion", "firework",
    "eye_of_ender", "fishing_bobber", "wither_skull", "dragon_fireball", "fireball",
    "shulker_bullet", "llama_spit",
]
/// entities that tick regardless of sim distance (bosses roam the whole arena)
let ALWAYS_TICK: Set<String> = ["ender_dragon", "wither", "warden", "end_crystal", "eye_of_ender", "lightning"]

// =============================================================================
// Load-path profiler (PEBBLE_PROF=1) — aggregates per-stage wall time
// =============================================================================
public final class LoadProf {
    public static let shared = LoadProf()
    public let enabled = ProcessInfo.processInfo.environment["PEBBLE_PROF"] != nil
    private var lock = NSLock()
    private var buckets: [String: (count: Int, ms: Double)] = [:]
    private var lastPrint = CFAbsoluteTimeGetCurrent()

    @inline(__always)
    public func time<T>(_ name: String, _ body: () -> T) -> T {
        if !enabled { return body() }
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = body()
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        lock.lock()
        let b = buckets[name] ?? (0, 0)
        buckets[name] = (b.count + 1, b.ms + ms)
        lock.unlock()
        return r
    }
    public func tickPrint() {
        guard enabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastPrint < 2 { return }
        lastPrint = now
        lock.lock()
        let snap = buckets
        lock.unlock()
        let line = snap.sorted { $0.value.ms > $1.value.ms }
            .map { String(format: "%@ %.0fms/%d(%.1f)", $0.key, $0.value.ms, $0.value.count, $0.value.ms / Double(max(1, $0.value.count))) }
            .joined(separator: "  ")
        print("[prof] " + line)
        fflush(stdout)
    }
}

// =============================================================================
// Construction-pattern detection (golems, wither)
// =============================================================================
func tryBuildGolem(_ world: World, _ x: Int, _ y: Int, _ z: Int) {
    // snow golem: pumpkin on 2 snow blocks
    if world.getBlockId(x, y - 1, z) == Int(B.snow_block) && world.getBlockId(x, y - 2, z) == Int(B.snow_block) {
        world.setBlock(x, y, z, 0)
        world.setBlock(x, y - 1, z, 0)
        world.setBlock(x, y - 2, z, 0)
        spawnMob(world, "snow_golem", Double(x) + 0.5, Double(y - 2), Double(z) + 0.5, SpawnOpts(persistent: true))
        world.hooks.addParticles("block", Double(x) + 0.5, Double(y - 1) + 0.5, Double(z) + 0.5, 20, 0.6, Int(cell(B.snow_block)))
        return
    }
    // iron golem: T of iron blocks below pumpkin
    if world.getBlockId(x, y - 1, z) != Int(B.iron_block) || world.getBlockId(x, y - 2, z) != Int(B.iron_block) { return }
    for (ax, az) in [(1, 0), (0, 1)] {
        if world.getBlockId(x - ax, y - 1, z - az) == Int(B.iron_block) && world.getBlockId(x + ax, y - 1, z + az) == Int(B.iron_block) {
            world.setBlock(x, y, z, 0)
            world.setBlock(x, y - 1, z, 0)
            world.setBlock(x, y - 2, z, 0)
            world.setBlock(x - ax, y - 1, z - az, 0)
            world.setBlock(x + ax, y - 1, z + az, 0)
            // (baseline passes playerMade:true into the loose data bag; nothing reads it)
            spawnMob(world, "iron_golem", Double(x) + 0.5, Double(y - 2), Double(z) + 0.5, SpawnOpts(persistent: true))
            world.hooks.playSound("block.anvil.land", Double(x), Double(y), Double(z), 0.6, 1.2)
            return
        }
    }
}

func tryBuildWither(_ world: World, _ x: Int, _ y: Int, _ z: Int) {
    func isSoul(_ id: Int) -> Bool { id == Int(B.soul_sand) || id == Int(B.soul_soil) }
    func isSkull(_ bx: Int, _ by: Int, _ bz: Int) -> Bool { world.getBlockId(bx, by, bz) == Int(B.wither_skeleton_skull) }
    for (ax, az) in [(1, 0), (0, 1)] {
        // the skull just placed can be any of the three top positions
        for off in -1...1 {
            let cx = x - off * ax, cz = z - off * az
            if !isSkull(cx - ax, y, cz - az) || !isSkull(cx, y, cz) || !isSkull(cx + ax, y, cz + az) { continue }
            if !isSoul(world.getBlockId(cx, y - 1, cz)) || !isSoul(world.getBlockId(cx - ax, y - 1, cz - az)) ||
                !isSoul(world.getBlockId(cx + ax, y - 1, cz + az)) || !isSoul(world.getBlockId(cx, y - 2, cz)) { continue }
            // clear the structure
            for (dx, dy, dz) in [(-ax, 0, -az), (0, 0, 0), (ax, 0, az), (-ax, -1, -az), (0, -1, 0), (ax, -1, az), (0, -2, 0)] {
                world.setBlock(cx + dx, y + dy, cz + dz, 0)
            }
            let w = spawnMob(world, "wither", Double(cx) + 0.5, Double(y - 2), Double(cz) + 0.5, nil)
            if w != nil { world.hooks.playSound("entity.wither.spawn", Double(cx), Double(y), Double(cz), 8, 1) }
            return
        }
    }
}

// =============================================================================
// Host surface — the app implements this (screens, HUD, audio, renderer)
// =============================================================================
public struct BossBarInfo {
    public let name: String
    public let progress: Double
    public let color: String
    public init(name: String, progress: Double, color: String) {
        self.name = name
        self.progress = progress
        self.color = color
    }
}

public protocol GameHost: AnyObject {
    // screens
    func hasScreen() -> Bool
    func screenPausesGame() -> Bool
    func openScreen(_ kind: String, _ data: ScreenData?)
    func openTrading(_ villager: Mob)
    func openVehicleChest(_ kind: String, _ vehicle: Entity)
    func openChat(_ prefix: String)
    func openDeathScreen(_ message: String)
    func openPauseScreen()
    func openTitleScreen()
    func closeAllScreens()
    func releasePointer()
    func capturePointer()
    // HUD / chat
    func showActionBar(_ text: String, _ time: Int)
    func pushChat(_ line: String)
    func pushToast(_ adv: AdvancementDef)
    func setBossBars(_ bars: [BossBarInfo])
    // audio
    func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double, _ pitch: Double)
    func playUI(_ name: String)
    func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double)
    func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double)
    func tickMusic(_ mood: String, _ enabled: Bool)
    func stopDisc()
    // particles (count already scaled by the particles setting)
    func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double, _ count: Int, _ spread: Double, _ cell: Int)
    func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double, _ groundY: Double)
    // renderer
    func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput)
    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int)
    func clearAllSections()
}

/// interpolated camera for the renderer — reference implementation CameraState
public struct CamState {
    public var x = 0.0, y = 0.0, z = 0.0
    public var yaw = 0.0, pitch = 0.0
    public var fov = 70.0
    public var underwater = false
    public var underLava = false
    public var powderSnow = false
    public var portalWarp = 0.0
    public var nightVision = 0.0
    public var darkness = 0.0
    public var blindness = 0.0
    public init() {}
}

let CAMERA_WALK_BOB_SCALE = 0.5

func cameraBobOffset(phase: Double, amplitude: Double, yaw: Double) -> (x: Double, y: Double, z: Double) {
    let wave = detSin(phase * .pi)
    return (
        x: wave * amplitude * 0.3 * CAMERA_WALK_BOB_SCALE * detCos(yaw),
        y: abs(wave) * amplitude * 1.2 * CAMERA_WALK_BOB_SCALE,
        z: wave * amplitude * 0.3 * CAMERA_WALK_BOB_SCALE * detSin(yaw)
    )
}

// =============================================================================
// Streaming bookkeeping keys
// =============================================================================
struct SectionPos: Hashable {
    let cx: Int, sy: Int, cz: Int
}
struct DimSection: Hashable {
    let dim: Int
    let pos: SectionPos
}
struct DimChunk: Hashable {
    let dim: Int
    let key: Int64
}
final class MeshJobState {
    var dirtyAgain = false
}

// =============================================================================
// The Game
// =============================================================================
public final class GameCore {
    public weak var host: GameHost?
    public let db: SaveDB
    public var settings: Settings
    public var keybinds: [String: String]

    // world state
    public var worlds: [Dim: World] = [:]
    public var dim: Dim = .overworld
    public var player: Player!
    public var worldRec: WorldRecord?
    public var advancements = AdvancementTracker()
    public private(set) var inWorld = false
    public private(set) var isLANClientWorld = false
    /// A LAN host is authoritative for remote peers even while a local menu is
    /// open, so fixed-step simulation cannot inherit singleplayer menu pause.
    public var lanHostKeepsSimulationRunning = false
    private var lanClientResumeStorageKey: String?
    private var lanClientWorldSummary: LANWorldSummary?
    public private(set) var paused = false
    public var rpgSimulationTick: Int {
        max(0, min(RPG_MAX_COUNTER,
                   worldRec?.rpgSimulationTick ?? worlds[dim]?.rpgSimulationTick ?? 0))
    }
    public var mapSpanBlocks = MAP_DEFAULT_VIEW_BLOCKS
    public var mapMinimapSizeMode = MAP_DEFAULT_MINIMAP_SIZE_MODE
    public var expandedMapCenterX = 0.0
    public var expandedMapCenterZ = 0.0
    public var onWorldBlockChanged: ((World, Int, Int, Int, Int) -> Void)?
    public var onTemplatePlacementCommitted: ((World, TemplatePlacementUndoSnapshot) -> Void)?
    public var lanChunkRequestHandler: ((World, Int, Int) -> Bool)?
    /// full-column (radius 0, all sections) request — used by the background completion pass,
    /// which cannot express "whole column" through `lanChunkRequestHandler`'s visible-band request.
    public var lanFullColumnRequestHandler: ((World, Int, Int) -> Bool)?
    public var lanBlockIntentHandler: ((LANBlockIntent) -> Void)?
    /// client → host gameplay intents (all additive, LAN-client-only)
    public var lanAttackIntentHandler: ((LANAttackIntent) -> Void)?
    public var lanTossIntentHandler: ((LANTossIntent) -> Void)?
    public var lanRPGIntentHandler: ((LANRPGIntent) -> Void)?
    public var lanContainerEditHandler: ((LANContainerEditIntent) -> Void)?
    /// fires with the freshly-published snapshot and its new revision number
    public var lanInventoryPublishHandler: ((LANPlayerInventorySnapshot, Int) -> Void)?
    /// Host-side LAN hook: settles every guest's in-flight template PLACE/UNDO job before a
    /// graceful quit/save flush persists the world, exactly as `settleInFlightTemplatePlacementJobs`
    /// does for the local job. Set in `configureHostReplicationHooks`, cleared in
    /// `clearReplicationHooks` (LANTransport), and invoked from `saveAndFlush` alongside the local
    /// settle call so a host quitting mid-guest-placement never persists a half-placed object.
    public var lanSettleTemplateJobsHandler: (() -> Void)?
    /// Synchronous world-global RPG rule transition boundary. A LAN host uses
    /// this to terminate/publish/persist remote authorities before setGameRule
    /// returns; the Bool is the new enabled state.
    public var onRPGGameRuleTransition: ((Bool) -> Void)?
    public private(set) var rpgClockAdvancedThisTick = false

    // LAN client-authoritative inventory / container-edit / connection state
    private var lanLocalInventoryRevision = 0
    private var lanLastPublishedInventory: LANPlayerInventorySnapshot?
    public private(set) var lanApplyingReplication = false
    private var lanContainerEditSeq = 0
    private var lanLastAppliedGrantID = 0
    public private(set) var lanConnectionLost = false
    private var lanDeferredReplication = LANDeferredReplicationBuffer()
    /// position/type of the mirrored container screen currently open (if any) — used to detect
    /// orphaned screens after a replication batch replaces/removes the underlying block (A9)
    private var lanOpenContainerBE: (dim: Int, x: Int, y: Int, z: Int, type: String)?
    private var lanOpenContainerPositions: [LANBlockPosition] = []
    private var lanOpenContainerRevision = 0
    /// LAN-client-local monotonic tick counter (world.time is frozen for LAN clients since
    /// World.tick(simCenters:) never runs for them) — drives section-request expiry
    private var lanClientTickCounter = 0

    // streaming
    private var genInFlight = Set<DimChunk>()
    /// section-granular in-flight chunk requests: section → tick requested (expires after
    /// LAN_CHUNK_REQUEST_EXPIRY_TICKS so a lost/truncated host reply is retried)
    private var lanSectionRequestsInFlight: [DimSection: Int] = [:]
    /// per-column background-completion requests already issued this expiry window
    private var lanColumnCompletionRequestsInFlight: [DimChunk: Int] = [:]
    private var lanAppliedChunkSections = Set<DimSection>()
    /// keys of chunks that exist on disk — fresh chunks skip the read entirely
    private var savedChunkKeys = Set<String>()
    /// keys whose DB record holds full block data — an unload rewrite of these
    /// must emit a full record again or the blocks are lost (entity-only stubs
    /// REPLACE the row)
    private var savedFullKeys = Set<String>()
    /// chunks awaiting initial lighting, processed under a per-frame budget
    private var lightQueue: [Dim: Set<Int64>] = [:]
    private var dirtySections: [Dim: Set<SectionPos>] = [:]
    /// sections whose neighborhood isn't ready — parked so the per-frame dirty
    /// scan doesn't rescan the streaming frontier forever; retried once per second
    private var stalledSections: [Dim: Set<SectionPos>] = [:]
    private var meshJobs: [DimSection: MeshJobState] = [:]
    public private(set) var meshedThisSecond = 0
    public var lastChunkUpdates = 0
    /// unload records awaiting the once-per-second batched write
    private var pendingChunkSaves: [String: ChunkRecord] = [:]

    private let genQueue = DispatchQueue(label: "pebble.gen", qos: .userInitiated, attributes: .concurrent)
    private let meshQueue = DispatchQueue(label: "pebble.mesh", qos: .userInitiated, attributes: .concurrent)
    private let saveQueue = DispatchQueue(label: "pebble.save", qos: .utility)

    // input
    private var keys = Set<String>()
    private var leftDown = false
    private var rightDown = false
    private var useCooldown = 0
    private var breakCooldown = 0
    private var lastLightHealTick = -1
    private var lastSlot = 0
    public var heldNameTime = 0
    public var targetedBlock: (x: Int, y: Int, z: Int, cell: Int)?
    public var lastCursorHit: RaycastHit?
    public private(set) var templatePlacement: TemplatePlacementSession?
    public private(set) var lastTemplatePlacementUndo: TemplatePlacementUndoSnapshot?
    private var templatePlacementJob: ObjectTemplatePlacementJob?
    private var templatePlacementProgressTick = 0
    public var perspective = 0          // 0 first, 1 back, 2 front
    private var sprintHeld = false
    private var lastForwardPress = 0.0

    // loop
    private var accumulator = 0.0
    private var ticksSinceSave = 0

    // bookkeeping for vanilla feel — bob advances per TICK (frame-rate
    // independent) and camState interpolates; mutating it per frame made the
    // camera shake violently once the fps cap was lifted
    private var bobPhase = 0.0
    private var prevBobPhase = 0.0
    private var bobAmp = 0.0
    private var prevBobAmp = 0.0
    private var fovScale = 1.0
    private var prevFovScale = 1.0
    public private(set) var portalWarp = 0.0
    private var dragonSpawned = false
    private var brushTicks = 0
    private var deathScreenShown = false
    /// a portal/respawn chunk-load is in flight — player is held in place
    private var traveling = false
    /// player is frozen because the chunk under them hasn't streamed in yet
    private var heldForChunks = false
    public private(set) var musicMood = "menu"

    public init(db: SaveDB = SaveDB()) {
        self.db = db
        settings = loadSettings()
        keybinds = loadKeybinds()
        // registry boot, in frozen order
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllRecipes()
        registerAllLootTables()
        registerAllEntities()
        registerAllSystems()
        for d in [Dim.overworld, .nether, .end] {
            dirtySections[d] = []
            lightQueue[d] = []
        }
        onPlacedHandlers[Int(B.carved_pumpkin)] = { w, x, y, z, _ in tryBuildGolem(w, x, y, z) }
        onPlacedHandlers[Int(B.wither_skeleton_skull)] = { w, x, y, z, _ in tryBuildWither(w, x, y, z) }
        bindCrystalDestroyed { [weak self] crystal, attacker in
            let dragon = crystal.world.entities.first {
                ($0 as? Entity)?.type == "ender_dragon" && !$0.dead
            } as? EnderDragon
            if let dragon {
                _ = dragon.hurt(10, "explosion")
                dragon.pathAngle += 1.5
            }
            if attacker is Player { self?.advance("free_the_end_crystal") }
        }
        // screen-opening hooks fired from entity interactions
        bindOpenTrading { [weak self] player, villager in
            guard let self, player is Player else { return }
            self.host?.openTrading(villager)
            self.advanceLater("trade_villager")
        }
        openContainerScreenFn = { [weak self] player, kind, vehicle in
            guard let self, player is Player else { return }
            self.host?.openVehicleChest(kind, vehicle)
        }
    }

    // ===========================================================================
    // GameUI / MenuHost surface
    // ===========================================================================
    public var world: World { worlds[dim]! }

    /// resolves the loaded `World` for an arbitrary dimension (A2: LAN chunk requests must be
    /// served from the GUEST's dimension, not just the host's current one). Returns nil for an
    /// invalid raw dimension or a dimension that hasn't been loaded.
    public func worldFor(dimension: Int) -> World? {
        guard let d = Dim(rawValue: dimension) else { return nil }
        return worlds[d]
    }
    public func hasWorld() -> Bool { inWorld }

    public func playUISound(_ name: String) {
        host?.playUI(name)
    }

    public func advance(_ id: String) {
        if !inWorld { return }
        if advancements.grant(id) {
            playUISound("ui.toast.challenge_complete")
        }
    }
    /// queue an advancement next runloop turn (screens may open before tracker updates)
    private func advanceLater(_ id: String) {
        DispatchQueue.main.async { [weak self] in self?.advance(id) }
    }

    public func applySettings() {
        settings = sanitizedSettings(settings)
        keybinds = sanitizedKeybinds(keybinds)
        saveSettings(settings)
        saveKeybinds(keybinds)
    }

    public func respawnPlayer() {
        if traveling { return }
        traveling = true
        defer { traveling = false }
        let p = player!
        deathScreenShown = false
        // respawn at bed / anchor / world spawn
        var dest: (Double, Double, Double)? = nil
        var destDim = Dim(rawValue: p.spawnDim) ?? .overworld
        if let sp = p.spawnPoint {
            let w = worlds[destDim]!
            ensureChunksLoaded(w, floorDiv(sp.0, 16), floorDiv(sp.2, 16), 1)
            let (sx, sy, sz) = sp
            let id = w.getBlockId(sx, sy, sz)
            let def = blockDefs[id]
            if SHAPE_OF[id] == Shape.bed.rawValue || def.name == "respawn_anchor" {
                if def.name == "respawn_anchor" {
                    let charge = w.getMeta(sx, sy, sz)
                    if charge > 0 {
                        w.setBlock(sx, sy, sz, Int(cell(UInt16(id), charge - 1)))
                        dest = (Double(sx) + 0.5, Double(sy + 1), Double(sz) + 0.5)
                    }
                } else {
                    dest = (Double(sx) + 0.5, Double(sy) + 0.6, Double(sz) + 0.5)
                }
            }
        }
        if dest == nil {
            destDim = .overworld
            let w = worlds[.overworld]!
            ensureChunksLoaded(w, floorDiv(Int(w.spawnX), 16), floorDiv(Int(w.spawnZ), 16), 1)
            dest = (w.spawnX + 0.5, Double(w.surfaceY(Int(w.spawnX), Int(w.spawnZ))), w.spawnZ + 0.5)
        }
        if destDim != dim { moveToDimension(destDim) }
        p.respawn()
        p.setPos(dest!.0, dest!.1, dest!.2)
        p.insidePortalKind = nil
        p.portalTicks = 0
    }

    public func exitToTitle() {
        if inWorld { finalizeAndSave(synchronous: true) }
        inWorld = false
        isLANClientWorld = false
        lanClientResumeStorageKey = nil
        lanClientWorldSummary = nil
        worldRec = nil
        dragonSpawned = false
        deathScreenShown = false
        worlds.removeAll()
        for d in dirtySections.keys { dirtySections[d]!.removeAll() }
        stalledSections.removeAll()
        for d in lightQueue.keys { lightQueue[d]!.removeAll() }
        meshJobs.removeAll()
        genInFlight.removeAll()
        savedChunkKeys.removeAll()
        savedFullKeys.removeAll()
        pendingChunkSaves.removeAll()
        clearEntityTimeouts()
        resetLANClientRoutingState()
        host?.clearAllSections()
        host?.setBossBars([])
        host?.stopDisc()
        host?.releasePointer()
        host?.closeAllScreens()
        host?.openTitleScreen()
    }

    /// resets all LAN client-routing bookkeeping — called on world entry/exit so a fresh session
    /// never inherits revision/grant/expiry state from a previous LAN world
    private func resetLANClientRoutingState() {
        lanLocalInventoryRevision = 0
        lanLastPublishedInventory = nil
        lanApplyingReplication = false
        lanContainerEditSeq = 0
        lanLastAppliedGrantID = 0
        lanConnectionLost = false
        lanDeferredReplication.removeAll()
        lanOpenContainerBE = nil
        lanOpenContainerPositions.removeAll()
        lanOpenContainerRevision = 0
        lanClientTickCounter = 0
        lanSectionRequestsInFlight.removeAll()
        lanColumnCompletionRequestsInFlight.removeAll()
    }

    // ---- MenuHost ----
    public func listWorlds() -> [WorldRecord] {
        db.listWorlds()
    }

    public func createWorld(name: String, seedText: String, mode: Int, difficulty: Int,
                            worldPreset: WorldPreset = .normal, singleBiome: Biome = .plains,
                            dungeonDensity: DungeonDensity = .normal) {
        lanClientResumeStorageKey = nil
        lanClientWorldSummary = nil
        let trimmed = seedText.trimmingCharacters(in: .whitespaces)
        var seed: Int32
        if trimmed.isEmpty {
            seed = Int32.random(in: 0..<0x7fffffff)
        } else if trimmed.range(of: "^-?\\d+$", options: .regularExpression) != nil {
            seed = wrapToInt32(Double(trimmed) ?? 0)
        } else {
            // (seed * 31 + ch.charCodeAt(0)) | 0 over code points
            seed = 0
            for unit in trimmed.utf16 {
                seed = seed &* 31 &+ Int32(unit)
            }
        }
        let ms = Int(Date().timeIntervalSince1970 * 1000)
        let id = "w" + String(ms, radix: 36) + String(Int.random(in: 0..<1_000_000), radix: 36)
        var rec = WorldRecord(id: id, name: name, seed: seed, gameMode: mode, difficulty: difficulty,
                              worldPreset: worldPreset, singleBiome: singleBiome,
                              dungeonDensity: dungeonDensity)
        rec.gameRules[RPG_CLASSES_GAME_RULE] = 1
        let spawn = defaultWorldSpawn(seed: seed, settings: rec.generationSettings)
        rec.spawnX = spawn.x
        rec.spawnY = spawn.y
        rec.spawnZ = spawn.z
        db.putWorld(rec)
        enterWorld(rec, nil, nil)
    }

    public func loadWorld(_ id: String) {
        lanClientResumeStorageKey = nil
        lanClientWorldSummary = nil
        guard let rec = db.getWorld(id) else { return }
        let playerData = db.getPlayer(id)
        let adv = db.getAdvancements(id)
        enterWorld(rec, playerData, adv)
    }

    public func enterLANClientWorld(_ summary: LANWorldSummary) {
        let seed = Int32(truncatingIfNeeded: summary.seed)
        let cleanID = sanitizedLANWorldIdentifier(summary.worldID)
        let resumeKey = lanClientResumeKey(for: summary)
        let resumeData = resumeKey.flatMap { db.getLANClientResume($0) }
        var rec = WorldRecord(
            id: "lan-" + (cleanID.isEmpty ? "world" : cleanID),
            name: "LAN: \(summary.worldName)",
            seed: seed,
            gameMode: summary.gameMode,
            difficulty: summary.difficulty
        )
        rec.gameRules[RPG_CLASSES_GAME_RULE] = summary.rpgClassesEnabled ? 1 : 0
        let spawn = defaultWorldSpawn(seed: seed, settings: rec.generationSettings)
        rec.spawnX = spawn.x
        rec.spawnY = spawn.y
        rec.spawnZ = spawn.z
        lanClientResumeStorageKey = resumeKey
        lanClientWorldSummary = summary
        enterWorld(rec, resumeData, nil, transientLANClient: true)
        if resumeData == nil, let d = Dim(rawValue: summary.dimension), d != dim {
            moveToDimension(d)
        }
    }

    public func deleteWorld(_ id: String) {
        db.deleteWorld(id)
    }

    // ===========================================================================
    // World lifecycle
    // ===========================================================================
    private func defaultWorldSpawn(seed: Int32, settings: WorldGenerationSettings = .normal) -> (x: Int, y: Int, z: Int) {
        if settings.preset == .flat {
            return (8, GEN_MIN_Y + 4, 8)
        }
        if settings.preset == .debugAllBlockStates {
            return (0, 71, 0)
        }
        let gen = overworldGen(UInt32(bitPattern: seed), settings: settings)
        var sx = 8, sz = 8
        for r in 0..<40 {
            let tx = 8 + r * 40, tz = 8 + ((r * 13) % 7 - 3) * 40
            let b = gen.surfaceBiomeAt(Double(tx), Double(tz))
            let h = gen.heightEstimate(Double(tx), Double(tz))
            let bname = (BIOMES[Int(b.rawValue)]?.name ?? "").lowercased()
            if h > DIMS[Dim.overworld.rawValue].seaLevel && !bname.contains("ocean") && !bname.contains("river") {
                sx = tx
                sz = tz
                break
            }
        }
        let maxSpawnY = DIMS[Dim.overworld.rawValue].minY + DIMS[Dim.overworld.rawValue].height
        return (sx, min(gen.heightEstimate(Double(sx), Double(sz)) + 1, maxSpawnY), sz)
    }

    private func enterWorld(_ rec: WorldRecord, _ playerData: [String: Any]?, _ adv: [String]?, transientLANClient: Bool = false) {
        worldRec = rec
        isLANClientWorld = transientLANClient
        lanSectionRequestsInFlight.removeAll()
        lanColumnCompletionRequestsInFlight.removeAll()
        lanAppliedChunkSections.removeAll()
        resetLANClientRoutingState()
        advancements = AdvancementTracker()
        if let adv { advancements.load(adv) }
        dragonSpawned = false
        worlds.removeAll()
        resetEntityIds(max(1, rec.nextEntityId))
        for d in [Dim.overworld, .nether, .end] {
            let w = World(dim: d, seed: UInt32(bitPattern: rec.seed), generationSettings: rec.generationSettings)
            if let ds = rec.dims["\(d.rawValue)"] {
                w.time = ds.time
                w.dayTime = ds.dayTime
                w.raining = ds.raining
                w.thundering = ds.thundering
                w.weatherTimer = ds.weatherTimer
                w.rainLevel = ds.raining ? 1 : 0
                w.thunderLevel = ds.thundering ? 1 : 0
            }
            w.rpgSimulationTick = rec.rpgSimulationTick
            w.difficulty = rec.difficulty
            for (k, v) in rec.gameRules { w.gameRules[k] = v }
            w.spawnX = Double(rec.spawnX)
            w.spawnY = Double(rec.spawnY)
            w.spawnZ = Double(rec.spawnZ)
            hookWorld(w)
            worlds[d] = w
        }
        savedChunkKeys = db.getChunkKeys(rec.id)
        dim = Dim(rawValue: (playerData?["dim"] as? NSNumber)?.intValue ?? 0) ?? .overworld
        let w = world
        player = Player(world: w)
        player.setGameMode(rec.gameMode)
        if let pd = playerData?["data"] as? [String: Any] {
            player.load(pd)
            // a corrupted save (NaN position from an old physics blowup) renders
            // nothing at all — snap back to world spawn instead
            if !player.x.isFinite || !player.y.isFinite || !player.z.isFinite {
                player.setPos(Double(rec.spawnX) + 0.5, Double(rec.spawnY + 1), Double(rec.spawnZ) + 0.5)
                player.vx = 0; player.vy = 0; player.vz = 0
            }
        } else {
            player.setPos(Double(rec.spawnX) + 0.5, Double(rec.spawnY + 1), Double(rec.spawnZ) + 0.5)
            // starter nothing — vanilla survival starts empty-handed
        }
        w.addEntity(player)

        // spawn area must exist before the first tick — saved copies are read so
        // edits near spawn aren't shadowed by fresh generation
        let pcx = floorDiv(ifloor(player.x), 16), pcz = floorDiv(ifloor(player.z), 16)
        ensureChunksLoaded(w, pcx, pcz, 1)
        if playerData == nil && !transientLANClient {
            let sy = w.surfaceY(rec.spawnX, rec.spawnZ)
            player.setPos(Double(rec.spawnX) + 0.5, Double(sy), Double(rec.spawnZ) + 0.5)
        }
        // if loading into the End with a living fight, re-arm the dragon hook
        for e in w.entities {
            if let d = e as? EnderDragon { armDragon(d) }
        }

        inWorld = true
        deathScreenShown = false
        templatePlacement = nil
        templatePlacementJob = nil
        templatePlacementProgressTick = 0
        lastTemplatePlacementUndo = nil
        ticksSinceSave = 0
        host?.closeAllScreens()
        host?.showActionBar("§e\(rec.name)§r — seed \(rec.seed)", 60)
        if player.rpgClassesEnabled(), !player.rpg.created {
            host?.openScreen("rpg", nil)
            host?.releasePointer()
        }
        // loaded in deep underground? say so loudly instead of looking like a render bug
        let bx = ifloor(player.x), bz = ifloor(player.z)
        if w.info.hasSky && Double(w.heightAt(bx, bz)) > player.eyeY() + 10 {
            host?.pushChat("§eYou are deep underground. Type §f/surface§e to climb out.")
            host?.showActionBar("§eDeep underground — press T, type §f/surface", 400)
        }
    }

    private func hookWorld(_ w: World) {
        var hooks = WorldHooks()
        hooks.onSectionDirty = { [weak self, weak w] cx, cz, sy in
            guard let self, let w else { return }
            self.dirtySections[w.dim]!.insert(SectionPos(cx: cx, sy: sy, cz: cz))
        }
        hooks.onBlockChanged = { [weak self, weak w] x, y, z, _, newCell, _ in
            guard let self, let w, !self.isLANClientWorld else { return }
            self.onWorldBlockChanged?(w, x, y, z, newCell)
        }
        hooks.playSound = { [weak self, weak w] name, x, y, z, volume, pitch in
            guard let self, let w, w === self.worlds[self.dim] else { return }
            self.host?.playSound(name, x, y, z, volume, pitch)
        }
        hooks.addParticles = { [weak self, weak w] type, x, y, z, count, spread, data in
            guard let self, let w, w === self.worlds[self.dim] else { return }
            let mult = [0.3, 0.65, 1.0][min(2, max(0, self.settings.particles))]
            let n = max(1, Int((Double(count) * mult).rounded()))
            self.host?.addParticles(type, x, y, z, n, spread, data)
        }
        hooks.onVibration = { [weak w] x, y, z, freq, src in
            guard let w else { return }
            handleVibration(w, x, y, z, freq)
            for e in w.getEntitiesNear(x, y, z, 24, filter: { ($0 as? Entity)?.type == "warden" }) {
                (e as? Warden)?.hearVibration(x, y, z, src as? Entity)
            }
        }
        hooks.requestChunk = { [weak self, weak w] cx, cz in
            guard let self, let w else { return }
            self.requestChunk(w, cx, cz)
        }
        w.hooks = hooks
    }

    public func saveAndFlush(synchronous: Bool = false) {
        guard inWorld else { return }
        if isLANClientWorld {
            // A10: once the connection is known lost, stop overwriting the last-good resume
            // snapshot with drifting offline state
            if !lanConnectionLost { saveLANClientResume() }
            return
        }
        // A graceful termination (Cmd-Q), Save & Quit from the pause menu, or the
        // interactive path (applicationDidResignActive -> PauseScreen -> Save & Quit)
        // can all land here mid-placement: the pause guard in tick() freezes ticking
        // BEFORE tickTemplatePlacementJob runs, so a job can be left in-flight while
        // the player is looking at an open menu. Finish it now so the chunks about to
        // be flushed hold the complete object, never a half-placed one. Surface the
        // stall to the player only when there's actually a job to settle — this path
        // can be user-visible (interactive), unlike the Cmd-Q shutdown case.
        if hasActiveTemplatePlacementJob() {
            host?.showActionBar("Finishing placement...", 200)
            host?.pushChat("§7Finishing placement before saving...")
            settleInFlightTemplatePlacementJobs()
        }
        // Host-side LAN forward-compatibility: a guest's tick-sliced template job is not driven
        // by this GameCore's own tick() at all (it lives in LANReplication's per-peer registry,
        // stepped from LANTransport.tickReplication), so it must be settled explicitly here too —
        // otherwise a graceful host quit could persist a guest's half-placed/half-undone object.
        lanSettleTemplateJobsHandler?()
        guard var rec = worldRec else { return }
        rec.lastPlayed = Date().timeIntervalSince1970 * 1000
        rec.gameMode = player.gameMode
        rec.nextEntityId = peekNextEntityId()
        for (d, w) in worlds {
            rec.dims["\(d.rawValue)"] = DimState(
                time: w.time, dayTime: w.dayTime,
                raining: w.raining, thundering: w.thundering, weatherTimer: w.weatherTimer)
        }
        rec.rpgSimulationTick = max(0, min(RPG_MAX_COUNTER,
                                           worlds.values.map(\.rpgSimulationTick).max() ?? rec.rpgSimulationTick))
        // rules/difficulty are world-global (kept in sync across dims by
        // setGameRule/setDifficulty) — read one deterministic source
        if let cur = worlds[dim] {
            rec.difficulty = cur.difficulty
            rec.gameRules = cur.gameRules
        }
        worldRec = rec
        db.putWorld(rec)
        db.putPlayer(rec.id, ["dim": dim.rawValue, "data": player.save()])
        db.putAdvancements(rec.id, advancements.save())
        // all modified chunks across all dims
        var records: [ChunkRecord] = []
        for (d, w) in worlds {
            for c in w.chunks.values where c.modified {
                records.append(chunkRecord(rec.id, d, w, c))
            }
        }
        // include any unload records still waiting in the batch buffer
        for r in pendingChunkSaves.values { records.append(r) }
        pendingChunkSaves.removeAll()
        for r in records { savedChunkKeys.insert(r.key) }
        if synchronous {
            saveQueue.sync { self.writeChunkBatch(records) }
        } else {
            saveQueue.async { [weak self] in self?.writeChunkBatch(records) }
        }
        for w in worlds.values {
            for c in w.chunks.values { c.modified = false }
        }
    }

    /// Idempotent terminal save. Ordinary autosaves and explicit player-state
    /// persistence remain non-finalizing and preserve live transient effects.
    public func finalizeAndSave(synchronous: Bool = true) {
        guard inWorld else { return }
        for w in worlds.values { w.finalizeRPGTransientState() }
        player?.clearRPGTerminalUpkeeps()
        saveAndFlush(synchronous: synchronous)
    }

    private func saveLANClientResume() {
        guard !lanConnectionLost,
              let key = lanClientResumeStorageKey,
              let summary = lanClientWorldSummary,
              let player
        else { return }
        db.putLANClientResume(key, [
            "worldID": summary.worldID,
            "worldName": summary.worldName,
            "seed": summary.seed,
            "dim": dim.rawValue,
            "updated": Date().timeIntervalSince1970 * 1000,
            "data": player.save(),
        ])
    }

    /// A10: the transport calls this once when the LAN connection is confirmed lost (socket
    /// drop, host reap, malformed-frame disconnect). Surfaces the loss to the player and stops
    /// any further resume writes so offline drift does not overwrite the last known-good
    /// resume snapshot.
    public func handleLANConnectionLost(reason: String) {
        guard isLANClientWorld, !lanConnectionLost else { return }
        lanConnectionLost = true
        let trimmed = reason.isEmpty ? "Connection to the host was lost." : reason
        host?.pushChat("§c" + trimmed)
        host?.showActionBar(trimmed, 100)
    }

    /// runs ON the save queue; on failure re-marks the chunks dirty (on main)
    /// so the next autosave retries instead of silently losing the edits
    private func writeChunkBatch(_ records: [ChunkRecord]) {
        if db.putChunks(records) { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            print("[saves] chunk batch failed — re-marking \(records.count) chunks dirty for retry")
            for r in records {
                guard let d = Dim(rawValue: r.dim), let w = self.worlds[d] else { continue }
                if let c = w.chunks[chunkKey(r.cx, r.cz)] {
                    c.modified = true
                } else {
                    // already unloaded — requeue the record itself
                    self.pendingChunkSaves[r.key] = r
                }
            }
        }
    }

    /// Difficulty is world-global: apply to every dimension so the value can't
    /// drift (and can't depend on which dim happens to save last).
    public func setDifficulty(_ d: Int) {
        for w in worlds.values { w.difficulty = d }
        worldRec?.difficulty = d
    }

    /// Game rules are world-global: apply to every dimension.
    public func setGameRule(_ rule: String, _ value: Double) {
        if rule == RPG_CLASSES_GAME_RULE {
            let wasEnabled = worlds[dim]?.rule(rule)
                ?? ((worldRec?.gameRules[rule] ?? 0) != 0)
            let enabled = value != 0
            if wasEnabled != enabled {
                onRPGGameRuleTransition?(enabled)
            }
        }
        if rule == RPG_CLASSES_GAME_RULE, value == 0 {
            player?.clearRPGTerminalUpkeeps()
            for w in worlds.values { w.finalizeRPGTransientState() }
        }
        for w in worlds.values { w.gameRules[rule] = value }
        worldRec?.gameRules[rule] = value
        if rule == RPG_CLASSES_GAME_RULE, value == 0 {
            player?.applyRPGDerivedStats()
        }
    }

    private func chunkRecord(_ worldId: String, _ d: Dim, _ w: World, _ c: Chunk) -> ChunkRecord {
        // persist entities standing in this chunk (skip player + transient)
        var ents: [[String: Any]] = []
        let temporaryEntityIDs = w.rpgTemporaryEntityIDsForPersistence()
        for e in w.entities {
            guard let ent = e as? Entity, !ent.isPlayer, !ent.dead else { continue }
            if temporaryEntityIDs.contains(ent.id) { continue }
            if floorDiv(ifloor(ent.x), 16) != c.cx || floorDiv(ifloor(ent.z), 16) != c.cz { continue }
            if (ent.type == "item" || ent.type == "xp_orb") && ent.age > 4000 { continue }
            ents.append(ent.save())
        }
        let key = db.chunkKey(worldId, d.rawValue, c.cx, c.cz)
        if !c.modified && !savedFullKeys.contains(key) {
            // entity-only record (~KBs): the blocks regenerate from seed
            return ChunkRecord(key: key, worldId: worldId, dim: d.rawValue, cx: c.cx, cz: c.cz, entities: ents)
        }
        // once a full record exists on disk, every rewrite must stay full —
        // the autosave clears `modified` but the blocks no longer regenerate
        savedFullKeys.insert(key)
        // deep-copy block entities — live BEs keep mutating while the save
        // queue serializes, and BlockEntityData is a reference type
        var besCopy: [BlockEntityData]? = nil
        let besLive = Array(c.blockEntities.values)
        if let data = try? JSONEncoder().encode(besLive) {
            besCopy = try? JSONDecoder().decode([BlockEntityData].self, from: data)
        }
        return ChunkRecord(
            key: key, worldId: worldId, dim: d.rawValue, cx: c.cx, cz: c.cz,
            blocks: w.rpgBlocksForPersistence(in: c), biomes: c.biomes,
            blockEntities: besCopy ?? besLive, entities: ents)
    }

    // ===========================================================================
    // Chunk streaming
    // ===========================================================================
    private func activeSimulationChunkCenters(in w: World, local p: Player) -> [(Int, Int)] {
        var centers: [(Int, Int)] = [(floorDiv(ifloor(p.x), 16), floorDiv(ifloor(p.z), 16))]
        if !isLANClientWorld {
            let remoteCenters = w.entities.compactMap { ref -> (Int, Int)? in
                guard let remote = ref as? LANRemotePlayerEntity, !remote.dead else { return nil }
                return (floorDiv(ifloor(remote.x), 16), floorDiv(ifloor(remote.z), 16))
            }.sorted { lhs, rhs in lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0 }
            centers.append(contentsOf: remoteCenters)
        }
        var out: [(Int, Int)] = []
        var seen = Set<Int64>()
        for center in centers {
            if seen.insert(chunkKey(center.0, center.1)).inserted {
                out.append(center)
            }
        }
        return out
    }

    private func activeSimulationEntities(in w: World, local p: Player) -> [Entity] {
        var entities: [Entity] = [p]
        if !isLANClientWorld {
            entities.append(contentsOf: w.entities.compactMap { $0 as? LANRemotePlayerEntity }.filter { !$0.dead })
        }
        return entities
    }

    private func lanClientRequiredSectionYs(in w: World) -> [Int] {
        let y = ifloor(player?.y ?? w.spawnY)
        let center = max(0, min(w.info.height / SECTION_H - 1, (y - w.info.minY) >> 4))
        let verticalRadius = LAN_MULTIPLAYER_DEFAULT_CHUNK_VERTICAL_RADIUS
        var out: [Int] = []
        for sy in max(0, center - verticalRadius)...min(w.info.height / SECTION_H - 1, center + verticalRadius) {
            out.append(sy)
        }
        return out
    }

    private func hasLANClientVisibleSections(_ w: World, _ cx: Int, _ cz: Int) -> Bool {
        guard w.getChunk(cx, cz) != nil else { return false }
        for sy in lanClientRequiredSectionYs(in: w) {
            let pos = DimSection(dim: w.dim.rawValue, pos: SectionPos(cx: cx, sy: sy, cz: cz))
            if !lanAppliedChunkSections.contains(pos) { return false }
        }
        return true
    }

    /// true iff every section this LAN client needs for (cx,cz) is both applied AND — for a
    /// chunk that already exists locally — not merely a stub the completion pass still owes
    /// sections to. Distinct from `hasLANClientVisibleSections`: this only looks at the
    /// required vertical band, so a chunk can be "visible" while still incomplete overall.
    private func lanClientMissingSectionYs(_ w: World, _ cx: Int, _ cz: Int, sectionYs: [Int]) -> [Int] {
        sectionYs.filter { sy in
            !lanAppliedChunkSections.contains(DimSection(dim: w.dim.rawValue, pos: SectionPos(cx: cx, sy: sy, cz: cz)))
        }
    }

    /// expires stale section requests (lost/truncated host replies) so they become
    /// re-requestable instead of silently starving forever
    private func expireLANSectionRequests() {
        guard !lanSectionRequestsInFlight.isEmpty else { return }
        let cutoff = lanClientTickCounter - LAN_CHUNK_REQUEST_EXPIRY_TICKS
        for (section, requestedAt) in lanSectionRequestsInFlight where requestedAt <= cutoff {
            lanSectionRequestsInFlight.removeValue(forKey: section)
        }
        for (chunk, requestedAt) in lanColumnCompletionRequestsInFlight where requestedAt <= cutoff {
            lanColumnCompletionRequestsInFlight.removeValue(forKey: chunk)
        }
    }

    private func requestChunk(_ w: World, _ cx: Int, _ cz: Int) {
        let key = chunkKey(cx, cz)
        let flight = DimChunk(dim: w.dim.rawValue, key: key)
        if isLANClientWorld {
            expireLANSectionRequests()
            let requestRadius = LAN_MULTIPLAYER_DEFAULT_CHUNK_REQUEST_RADIUS
            let requiredSectionYs = lanClientRequiredSectionYs(in: w)
            // exact-target short-circuit: if the chunk actually passed to requestChunk is
            // already fully visible, or every one of its own required sections is already
            // in-flight, skip re-deriving the wider neighborhood entirely. Without this, a
            // caller sweeping a 3×3 grid of chunks (e.g. ensureChunksLoaded's radius-1 ring)
            // would re-issue a fresh handler call for every one of those 9 chunks even though
            // the very first call already covered their shared neighborhood.
            let targetStillNeedsSections = lanClientMissingSectionYs(w, cx, cz, sectionYs: requiredSectionYs)
                .contains { sy in
                    lanSectionRequestsInFlight[DimSection(dim: w.dim.rawValue, pos: SectionPos(cx: cx, sy: sy, cz: cz))] == nil
                }
            guard targetStillNeedsSections else { return }
            let candidateCoords = orderedLANChunkRequestCoordinates(cx: cx, cz: cz, radius: requestRadius)
            var neededSections: [DimSection] = []
            var neededChunks = Set<DimChunk>()
            for coord in candidateCoords {
                for sy in lanClientMissingSectionYs(w, coord.cx, coord.cz, sectionYs: requiredSectionYs) {
                    let section = DimSection(dim: w.dim.rawValue, pos: SectionPos(cx: coord.cx, sy: sy, cz: coord.cz))
                    if lanSectionRequestsInFlight[section] == nil {
                        neededSections.append(section)
                        neededChunks.insert(DimChunk(dim: w.dim.rawValue, key: chunkKey(coord.cx, coord.cz)))
                    }
                }
            }
            if neededSections.isEmpty { return }
            // MAX_GEN_INFLIGHT bounds concurrent chunk-request messages (one handler call covers
            // every needed section for that chunk), not the raw section count — a single call
            // can legitimately cover a whole vertical band's worth of sections.
            let inFlightChunkCount = Set(lanSectionRequestsInFlight.keys.map { DimChunk(dim: $0.dim, key: chunkKey($0.pos.cx, $0.pos.cz)) }).count
            if inFlightChunkCount + neededChunks.count > MAX_GEN_INFLIGHT { return }
            if lanChunkRequestHandler?(w, cx, cz) == true {
                for section in neededSections {
                    lanSectionRequestsInFlight[section] = lanClientTickCounter
                }
            }
            return
        }
        if w.chunks[key] != nil || genInFlight.contains(flight) { return }
        if genInFlight.count >= MAX_GEN_INFLIGHT { return }
        guard let rec = worldRec else { return }
        genInFlight.insert(flight)
        let worldId = rec.id
        let d = w.dim
        let seed = w.seed
        let height = w.info.height
        let hasSky = w.info.hasSky
        let saved = savedChunkKeys.contains(db.chunkKey(worldId, d.rawValue, cx, cz))
        let db = self.db
        let minY = w.info.minY
        genQueue.async { [weak self] in
            var savedRec: ChunkRecord? = nil
            if saved { savedRec = db.getChunk(worldId, d.rawValue, cx, cz) }
            let c: Chunk
            var beSpecs: [BESpec]? = nil
            var entitySpecs: [EntitySpec]? = nil
            var loadedFull = false
            if let savedRec, Self.recordUsable(savedRec, height: height) {
                // saved chunk: relight the stored blocks
                loadedFull = true
                let light = LoadProf.shared.time("light") { computeLocalLight(blocks: savedRec.blocks!, height: height, hasSky: hasSky) }
                c = LoadProf.shared.time("mkchunk") { Self.makeChunk(cx, cz, minY, height, savedRec.blocks!, savedRec.biomes!, light.sky, light.blk) }
            } else {
                // fresh generation; a corrupt/entity-only record still re-attaches its entities
                let out = LoadProf.shared.time("gen") { generateChunk(d, seed, cx, cz, settings: w.generationSettings) }
                let light = LoadProf.shared.time("light") { computeLocalLight(blocks: out.blocks, height: height, hasSky: hasSky) }
                c = LoadProf.shared.time("mkchunk") { Self.makeChunk(cx, cz, minY, height, out.blocks, out.biomes, light.sky, light.blk) }
                beSpecs = out.blockEntities
                entitySpecs = savedRec != nil ? nil : out.entities
            }
            let savedFinal = savedRec
            DispatchQueue.main.async {
                guard let self else { return }
                self.genInFlight.remove(flight)
                guard self.inWorld, self.worlds[d] === w, w.chunks[key] == nil else { return }
                if loadedFull { self.savedFullKeys.insert(db.chunkKey(worldId, d.rawValue, cx, cz)) }
                self.adoptChunk(w, c, beSpecs, entitySpecs, savedFinal)
                self.enqueueLightAround(w, cx, cz)
            }
        }
    }

    @discardableResult
    public func ensureAuthoritativeLANChunkLoaded(dimension: Int, cx: Int, cz: Int) -> Bool {
        guard !isLANClientWorld,
              let dim = Dim(rawValue: dimension),
              let w = worlds[dim]
        else { return false }
        ensureChunksLoaded(w, cx, cz, 0)
        return w.getChunk(cx, cz) != nil
    }

    public func markLANChunkSectionsApplied(_ sections: [LANChunkSectionSnapshot]) {
        guard isLANClientWorld, !sections.isEmpty else { return }
        var dirtiedChunks: [DimChunk: (dim: Int, cx: Int, cz: Int)] = [:]
        for section in sections {
            let key = chunkKey(section.cx, section.cz)
            let dimSection = DimSection(dim: section.dimension, pos: SectionPos(cx: section.cx, sy: section.sectionY, cz: section.cz))
            lanAppliedChunkSections.insert(dimSection)
            lanSectionRequestsInFlight.removeValue(forKey: dimSection)
            dirtiedChunks[DimChunk(dim: section.dimension, key: key)] = (section.dimension, section.cx, section.cz)
        }
        // A3: replicated sections arrive with raw cells only — recompute local light for every
        // distinct chunk touched this batch (same as the singleplayer adoptChunk path), or guests
        // render wrong/black light until something else happens to relight the area.
        for (_, coord) in dirtiedChunks.sorted(by: { $0.key.dim == $1.key.dim ? $0.key.key < $1.key.key : $0.key.dim < $1.key.dim }) {
            guard let d = Dim(rawValue: coord.dim), let w = worlds[d] else { continue }
            enqueueLightAround(w, coord.cx, coord.cz)
        }
    }

    @discardableResult
    public func applyLANHostReplicationBatch(_ batch: LANReplicationBatch) -> LANReplicationApplyReport {
        guard (0...RPG_MAX_COUNTER).contains(batch.tick) else {
            return LANReplicationApplyReport()
        }
        guard isLANClientWorld else {
            return applyLANReplicationBatch(batch, to: world)
        }
        var deferred = Optional(lanDeferredReplication)
        let report = applyLANReplicationBatch(batch, to: world, deferred: &deferred)
        let acceptedTick = max(rpgSimulationTick, batch.tick)
        worldRec?.rpgSimulationTick = acceptedTick
        for loadedWorld in worlds.values { loadedWorld.rpgSimulationTick = acceptedTick }
        lanDeferredReplication = deferred ?? LANDeferredReplicationBuffer()
        markLANChunkSectionsApplied(batch.chunkSections)
        return report
    }

    /// bounded background pass: full-column completion requests for chunks near the player
    /// that already have their visible band but are still missing sections elsewhere in the
    /// column (e.g. deep caves below the loaded band). At most
    /// `LAN_COLUMN_COMPLETION_REQUESTS_PER_TICK` requests fire per tick, and each column is
    /// requested at most once per expiry window.
    private func tickLANClientColumnCompletion() {
        guard isLANClientWorld else { return }
        let w = world
        expireLANSectionRequests()
        let pcx = floorDiv(ifloor(player.x), 16)
        let pcz = floorDiv(ifloor(player.z), 16)
        var issued = 0
        outer: for dz in -LAN_COLUMN_COMPLETION_RADIUS...LAN_COLUMN_COMPLETION_RADIUS {
            for dx in -LAN_COLUMN_COMPLETION_RADIUS...LAN_COLUMN_COMPLETION_RADIUS {
                if issued >= LAN_COLUMN_COMPLETION_REQUESTS_PER_TICK { break outer }
                let cx = pcx + dx, cz = pcz + dz
                guard let chunk = w.getChunk(cx, cz) else { continue }
                let flight = DimChunk(dim: w.dim.rawValue, key: chunkKey(cx, cz))
                if lanColumnCompletionRequestsInFlight[flight] != nil { continue }
                let missing = (0..<chunk.sections).contains { sy in
                    !lanAppliedChunkSections.contains(DimSection(dim: w.dim.rawValue, pos: SectionPos(cx: cx, sy: sy, cz: cz)))
                }
                guard missing else { continue }
                let issuedRequest = lanFullColumnRequestHandler?(w, cx, cz) ?? lanChunkRequestHandler?(w, cx, cz)
                if issuedRequest == true {
                    lanColumnCompletionRequestsInFlight[flight] = lanClientTickCounter
                    issued += 1
                }
            }
        }
    }

    /// A saved record is only trustworthy if its arrays have the exact expected sizes
    private static func recordUsable(_ saved: ChunkRecord, height: Int) -> Bool {
        guard let blocks = saved.blocks, let biomes = saved.biomes else { return false }
        if blocks.count != 16 * 16 * height { return false }
        if biomes.count != 4 * 4 * ((height + 3) / 4) { return false }
        return true
    }

    /// heavy chunk assembly (heightmap + special scan) — safe off-main, the
    /// chunk isn't shared until adoptChunk
    private static func makeChunk(
        _ cx: Int, _ cz: Int, _ minY: Int, _ height: Int,
        _ blocks: [UInt16], _ biomes: [UInt8],
        _ skyLight: [UInt8]?, _ blockLight: [UInt8]?
    ) -> Chunk {
        let c = Chunk(cx: cx, cz: cz, minY: minY, height: height)
        c.blocks = blocks
        c.biomes = biomes
        if let skyLight { c.skyLight = skyLight }
        if let blockLight { c.blockLight = blockLight }
        c.buildHeightmap()
        c.scanSpecials()
        c.status = .generated
        return c
    }

    private func adoptChunk(
        _ w: World, _ c: Chunk,
        _ beSpecs: [BESpec]?, _ entitySpecs: [EntitySpec]?,
        _ saved: ChunkRecord?
    ) {
        let cx = c.cx, cz = c.cz
        _ = (cx, cz)
        w.setChunk(c)
        // block entities: a full saved record carries them verbatim; otherwise
        // worldgen specs resolve deterministically
        if let savedBEs = saved?.blockEntities {
            for be in savedBEs {
                c.setBlockEntity(posMod(be.x, 16), be.y, posMod(be.z, 16), be)
            }
            c.modified = true // remains a fully-saved chunk
        } else if let beSpecs {
            for spec in beSpecs { resolveBESpec(w, c, spec) }
            c.modified = false
        }
        w.adoptChunkBlockEntities(c)
        if isLANClientWorld { return }
        // entities: any saved record (full or entity-only) overrides worldgen spawns
        if let saved {
            for ed in saved.entities {
                if let e = loadEntity(w, ed) {
                    w.addEntity(e)
                    if let dragon = e as? EnderDragon { armDragon(dragon) }
                }
            }
        } else if let entitySpecs {
            for es in entitySpecs {
                let m = spawnMob(w, es.mob, es.x, es.y, es.z, spawnOptsFrom(es.data))
                m?.persistent = true
            }
        }
    }

    private func spawnOptsFrom(_ data: [String: BEValue]) -> SpawnOpts {
        var opts = SpawnOpts()
        if case .bool(let b)? = data["baby"] { opts.baby = b }
        if case .bool(let b)? = data["persistent"] { opts.persistent = b }
        if case .bool(let b)? = data["captain"] { opts.captain = b }
        if case .num(let n)? = data["size"] { opts.size = Int(n) }
        if case .num(let n)? = data["variant"] { opts.variant = Int(n) }
        return opts
    }

    /// worldgen block-entity specs → live block entities
    private func resolveBESpec(_ w: World, _ c: Chunk, _ spec: BESpec) {
        let x = spec.x, y = spec.y, z = spec.z
        let lx = posMod(x, 16), lz = posMod(z, 16)
        func put(_ be: BlockEntityData) { c.setBlockEntity(lx, y, lz, be) }
        func str(_ k: String) -> String? {
            if case .str(let s)? = spec.data[k] { return s }
            return nil
        }
        func num(_ k: String) -> Double? {
            if case .num(let n)? = spec.data[k] { return n }
            return nil
        }
        func bool(_ k: String) -> Bool? {
            if case .bool(let b)? = spec.data[k] { return b }
            return nil
        }
        var rng = RandomX(hash3(w.seed ^ 0xBE5, x, y, z))
        switch spec.kind {
        case "chest_loot":
            let be = makeContainerBE(x, y, z, 27)
            let table = str("lootTable") ?? ""
            let seed = Int(num("seed") ?? Double(Int(hash3(w.seed ^ 0xBE5, x, y, z))))
            be.lootTable = table.isEmpty ? nil : table
            be.lootSeed = seed
            let generatedKey = "generated:\(w.dim.rawValue):\(x):\(y):\(z)"
            be.rpgGeneratedContainerKey = rpgIsBoundedID(generatedKey) && be.lootTable != nil
                ? generatedKey : nil
            put(be)
        case "elytra_chest":
            let be = makeContainerBE(x, y, z, 27)
            be.items![13] = ItemStack(iid("elytra"), 1)
            let extra = rollLoot("end_city_treasure", &rng, luck: 0)
            for s in extra.prefix(4) {
                let slot = rng.nextInt(27)
                if be.items![slot] == nil { be.items![slot] = s }
            }
            put(be)
        case "dispenser_arrows":
            let be = makeContainerBE(x, y, z, 9)
            be.items![4] = ItemStack(iid("arrow"), 2 + rng.nextInt(7))
            put(be)
        case "spawner":
            put(makeSpawnerBE(x, y, z, str("mob") ?? "zombie"))
        case "brushable":
            put(makeBrushableBE(x, y, z, str("lootTable") ?? "trail_ruins_common", Int(hash3(w.seed, x, y, z))))
        case "beehive":
            let be = BlockEntityData(type: "beehive", x: x, y: y, z: z)
            be.bees = Int(num("bees") ?? 3)
            be.honey = 0
            put(be)
        case "pot_plant":
            let be = BlockEntityData(type: "lectern", x: x, y: y, z: z)
            be.plant = str("plant") ?? "poppy"
            put(be)
        case "pot_sherds":
            let pool: [String?] = ["archer", "prize", "arms_up", "skull", "heart", "heartbreak", "howl", "sheaf", nil, nil]
            let be = BlockEntityData(type: "pot", x: x, y: y, z: z)
            be.sherds = (0..<4).map { _ in pool[rng.nextInt(pool.count)] }
            put(be)
        case "shrieker":
            let be = BlockEntityData(type: "shrieker", x: x, y: y, z: z)
            be.canSummon = bool("canSummon") ?? true
            be.shrieking = 0
            put(be)
        default:
            break
        }
    }

    /// queue every chunk around (cx,cz) whose 3×3 neighborhood is now generated
    private func enqueueLightAround(_ w: World, _ cx: Int, _ cz: Int) {
        for dz in -1...1 {
            for dx in -1...1 {
                guard let c = w.getChunk(cx + dx, cz + dz), c.status == .generated else { continue }
                if !w.neighborsReady(c.cx, c.cz) { continue }
                lightQueue[w.dim]!.insert(chunkKey(c.cx, c.cz))
            }
        }
    }

    /// finish lighting a chunk: cheap seam exchange (local light came from the gen queue)
    private func lightChunk(_ w: World, _ c: Chunk) {
        w.light.stitchChunk(c)
        var dirty = dirtySections[w.dim]!
        for s in 0..<c.sections { dirty.insert(SectionPos(cx: c.cx, sy: s, cz: c.cz)) }
        for (nx, nz) in [(c.cx - 1, c.cz), (c.cx + 1, c.cz), (c.cx, c.cz - 1), (c.cx, c.cz + 1)] {
            if let n = w.getChunk(nx, nz), n.status == .lit {
                for s in 0..<n.sections { dirty.insert(SectionPos(cx: nx, sy: s, cz: nz)) }
            }
        }
        dirtySections[w.dim] = dirty
        activateFluids(w, c)
    }

    /// schedule flow ticks for fluid cells that should be moving — the fluid sim
    /// is purely event-driven, so worldgen springs/lakes (and saves made mid-flow)
    /// otherwise sit frozen forever until some neighbor changes
    private func activateFluids(_ w: World, _ c: Chunk) {
        let waterId = B.water, lavaId = B.lava
        let minY = c.minY
        // pure scan first; world lookups outside the unsafe buffer access
        var fluidCells: [(Int, Int, Int, UInt16)] = []
        c.blocks.withUnsafeBufferPointer { bp in
            for i in 0..<bp.count {
                let cellv = bp[i]
                let id = cellv >> 4
                if id == waterId || id == lavaId {
                    fluidCells.append((i & 15, (i >> 8) + minY, (i >> 4) & 15, cellv))
                }
            }
        }
        // ocean/lake chunks hold thousands of stable sources — waking them all
        // floods the tick queue and the drop-seek BFS melts the frame rate.
        // Big water bodies are self-stable; only wake modest fluid populations.
        let wakeSources = fluidCells.count <= 400
        var woken = 0
        let baseX = c.cx * 16, baseZ = c.cz * 16
        for (lx, wy, lz, cellv) in fluidCells {
            if woken >= 128 { break }
            let wx = baseX + lx, wz = baseZ + lz
            let id = Int(cellv >> 4)
            if (cellv & 15) != 0 {
                w.scheduleTick(wx, wy, wz, id, id == Int(waterId) ? 5 : 30)
                woken += 1
                continue
            }
            guard wakeSources else { continue }
            // source: only wake it if it can actually act
            let below = w.getBlock(wx, wy - 1, wz) >> 4
            if below == 0 || (below != id && REPLACEABLE[below] == 1) {
                w.scheduleTick(wx, wy, wz, id, id == Int(waterId) ? 5 : 30)
                woken += 1
                continue
            }
            for d in 0..<4 {
                let n = w.getBlock(wx + [0, 0, -1, 1][d], wy, wz + [-1, 1, 0, 0][d]) >> 4
                if n == 0 {
                    w.scheduleTick(wx, wy, wz, id, id == Int(waterId) ? 5 : 30)
                    woken += 1
                    break
                }
            }
        }
    }

    /// Budgeted initial lighting: nearest chunks first, stop when the frame's budget is spent
    private func processLightQueue() {
        guard inWorld else { return }
        let w = world
        var q = lightQueue[dim]!
        if !q.isEmpty {
            let pcx = floorDiv(ifloor(player.x), 16)
            let pcz = floorDiv(ifloor(player.z), 16)
            var ready: [(key: Int64, c: Chunk, d: Int)] = []
            for key in q {
                guard let c = w.chunks[key], c.status == .generated else {
                    q.remove(key) // gone or already lit — done with it
                    continue
                }
                if !w.neighborsReady(c.cx, c.cz) { continue } // keep queued, never drop
                ready.append((key, c, (c.cx - pcx) * (c.cx - pcx) + (c.cz - pcz) * (c.cz - pcz)))
            }
            ready.sort { $0.d < $1.d }
            let t0 = CFAbsoluteTimeGetCurrent()
            for r in ready {
                q.remove(r.key)
                lightChunk(w, r.c)
                if (CFAbsoluteTimeGetCurrent() - t0) * 1000 > LIGHT_BUDGET_MS { break }
            }
        }
        // self-heal: any chunk that slipped through the queue gets re-queued
        // (this runs per frame — gate to once per qualifying tick)
        if w.time % 20 == 0 && lastLightHealTick != w.time {
            lastLightHealTick = w.time
            for c in w.chunks.values {
                if c.status == .generated && w.neighborsReady(c.cx, c.cz) {
                    q.insert(chunkKey(c.cx, c.cz))
                }
            }
            // retry sections parked on an unfinished neighborhood
            if let stalled = stalledSections[dim], !stalled.isEmpty {
                dirtySections[dim]!.formUnion(stalled)
                stalledSections[dim] = []
            }
        }
        lightQueue[dim] = q
    }

    /// Guarantee an area exists before placing the player in it (synchronous)
    private func ensureChunksLoaded(_ w: World, _ ccx: Int, _ ccz: Int, _ radius: Int) {
        if isLANClientWorld {
            let radius = max(0, radius)
            for r in 0...radius {
                for dz in -r...r {
                    for dx in -r...r {
                        if max(abs(dx), abs(dz)) != r { continue }
                        requestChunk(w, ccx + dx, ccz + dz)
                    }
                }
            }
            return
        }
        let worldId = worldRec?.id
        for dz in -radius...radius {
            for dx in -radius...radius {
                let cx = ccx + dx, cz = ccz + dz
                if w.chunks[chunkKey(cx, cz)] != nil { continue }
                var saved: ChunkRecord? = nil
                if let worldId, savedChunkKeys.contains(db.chunkKey(worldId, w.dim.rawValue, cx, cz)) {
                    saved = db.getChunk(worldId, w.dim.rawValue, cx, cz)
                    if let s = saved, Self.recordUsable(s, height: w.info.height) {
                        let light = computeLocalLight(blocks: s.blocks!, height: w.info.height, hasSky: w.info.hasSky)
                        adoptChunk(w, Self.makeChunk(cx, cz, w.info.minY, w.info.height, s.blocks!, s.biomes!, light.sky, light.blk),
                                   nil, nil, s)
                        continue
                    }
                }
                let out = generateChunk(w.dim, w.seed, cx, cz, settings: w.generationSettings)
                let light = computeLocalLight(blocks: out.blocks, height: w.info.height, hasSky: w.info.hasSky)
                adoptChunk(w, Self.makeChunk(cx, cz, w.info.minY, w.info.height, out.blocks, out.biomes, light.sky, light.blk),
                           out.blockEntities, saved != nil ? nil : out.entities, saved)
            }
        }
        // teleport targets need light immediately — stitch the area now
        for dz in (-radius - 1)...(radius + 1) {
            for dx in (-radius - 1)...(radius + 1) {
                if let c = w.getChunk(ccx + dx, ccz + dz), c.status == .generated, w.neighborsReady(c.cx, c.cz) {
                    lightChunk(w, c)
                }
            }
        }
    }

    private func streamChunks() {
        let w = world
        let pcx = floorDiv(ifloor(player.x), 16)
        let pcz = floorDiv(ifloor(player.z), 16)
        w.simCenterX = pcx
        w.simCenterZ = pcz
        let centers = activeSimulationChunkCenters(in: w, local: player)
        let R = settings.renderDistance + GEN_RADIUS_PAD
        // request missing chunks ring by ring (closest first)
        outer: for center in centers {
            for r in 0...R {
                for dz in -r...r {
                    for dx in -r...r {
                        if max(abs(dx), abs(dz)) != r { continue }
                        if genInFlight.count >= MAX_GEN_INFLIGHT { break outer }
                        let cx = center.0 + dx, cz = center.1 + dz
                        // LAN clients must keep requesting a chunk that exists locally but is
                        // still missing sections in the visible band — the singleplayer branch
                        // below only checks presence since it always generates the full column
                        let needsRequest = isLANClientWorld
                            ? !hasLANClientVisibleSections(w, cx, cz)
                            : w.chunks[chunkKey(cx, cz)] == nil
                        if needsRequest { requestChunk(w, cx, cz) }
                    }
                }
            }
        }
        // unload far chunks (tight radius — chunk arrays are ~400KB each)
        let dropR = R + 2
        for c in Array(w.chunks.values) {
            let nearActiveCenter = centers.contains { abs(c.cx - $0.0) <= dropR && abs(c.cz - $0.1) <= dropR }
            if !nearActiveCenter {
                unloadChunk(w, c)
            }
        }
        // inactive dimensions don't stream — drop everything they hold
        if w.time % 100 == 0 {
            for (d, other) in worlds {
                if d == dim { continue }
                for c in Array(other.chunks.values) { unloadChunk(other, c) }
            }
        }
    }

    private func unloadChunk(_ w: World, _ c: Chunk) {
        // Temporary blocks/entities are session state and must be restored or
        // removed before the chunk record is captured.
        w.cancelRPGTemporaryEffects(inChunkX: c.cx, z: c.cz)
        // persist if edited, if live entities stand in it, or if a stale record exists
        var hasEntities = false
        for e in w.entities {
            guard let ent = e as? Entity, !ent.isPlayer, !ent.dead else { continue }
            if floorDiv(ifloor(ent.x), 16) == c.cx && floorDiv(ifloor(ent.z), 16) == c.cz {
                hasEntities = true
                break
            }
        }
        // A8: LAN client mirror chunks are never persisted (the host owns world save
        // authority) — queuing them here would grow pendingChunkSaves unboundedly since
        // saveAndFlush never drains it for LAN client worlds.
        if !isLANClientWorld, let rec = worldRec {
            let dbKey = db.chunkKey(rec.id, w.dim.rawValue, c.cx, c.cz)
            if c.modified || hasEntities || savedChunkKeys.contains(dbKey) {
                let record = chunkRecord(rec.id, w.dim, w, c)
                savedChunkKeys.insert(record.key)
                pendingChunkSaves[record.key] = record
            }
        }
        // entities standing in the chunk were captured in the record; drop the live ones
        for e in Array(w.entities) {
            guard let ent = e as? Entity, !ent.isPlayer, !ent.dead else { continue }
            if floorDiv(ifloor(ent.x), 16) == c.cx && floorDiv(ifloor(ent.z), 16) == c.cz {
                w.removeEntity(e)
            }
        }
        w.releaseChunkBlockEntities(c)
        w.removeChunk(c.cx, c.cz)
        if w.dim == dim { host?.removeChunkMeshes(c.cx, c.cz, c.sections) }
        lightQueue[w.dim]!.remove(chunkKey(c.cx, c.cz))
        lanColumnCompletionRequestsInFlight.removeValue(forKey: DimChunk(dim: w.dim.rawValue, key: chunkKey(c.cx, c.cz)))
        for s in 0..<c.sections {
            dirtySections[w.dim]!.remove(SectionPos(cx: c.cx, sy: s, cz: c.cz))
            let dimSection = DimSection(dim: w.dim.rawValue, pos: SectionPos(cx: c.cx, sy: s, cz: c.cz))
            lanAppliedChunkSections.remove(dimSection)
            lanSectionRequestsInFlight.removeValue(forKey: dimSection)
        }
    }

    // ---- meshing --------------------------------------------------------------
    private func streamMeshes() {
        guard inWorld else { return }
        let w = world
        var dirty = dirtySections[dim]!
        if dirty.isEmpty { return }
        // skip the scan entirely while the queue is already full
        if meshJobs.count >= MAX_MESH_INFLIGHT { return }
        let pcx = floorDiv(ifloor(player.x), 16)
        let pcz = floorDiv(ifloor(player.z), 16)
        // sort a bounded batch by distance
        var candidates: [(pos: SectionPos, d: Int)] = []
        for pos in dirty {
            guard let c = w.getChunk(pos.cx, pos.cz), c.status == .lit, w.neighborsReady(pos.cx, pos.cz) else { continue }
            // neighbors must be lit too or the seam light is garbage
            var ok = true
            for (nx, nz) in [(pos.cx - 1, pos.cz), (pos.cx + 1, pos.cz), (pos.cx, pos.cz - 1), (pos.cx, pos.cz + 1)] {
                guard let n = w.getChunk(nx, nz), n.status == .lit else { ok = false; break }
            }
            // diagonals only need to exist — the snapshot reads their cells
            if ok && (w.getChunk(pos.cx - 1, pos.cz - 1) == nil || w.getChunk(pos.cx + 1, pos.cz - 1) == nil ||
                w.getChunk(pos.cx - 1, pos.cz + 1) == nil || w.getChunk(pos.cx + 1, pos.cz + 1) == nil) { ok = false }
            if !ok {
                // park it: retried when the surrounding area completes
                stalledSections[dim, default: []].insert(pos)
                dirty.remove(pos)
                continue
            }
            candidates.append((pos, (pos.cx - pcx) * (pos.cx - pcx) + (pos.cz - pcz) * (pos.cz - pcz)))
        }
        candidates.sort { $0.d < $1.d }
        for cand in candidates {
            if meshJobs.count >= MAX_MESH_INFLIGHT { break }
            let jobKey = DimSection(dim: dim.rawValue, pos: cand.pos)
            if let existing = meshJobs[jobKey] {
                existing.dirtyAgain = true
                dirty.remove(cand.pos)
                continue
            }
            dirty.remove(cand.pos)
            dirtySections[dim] = dirty
            dispatchMesh(w, cand.pos, jobKey)
            dirty = dirtySections[dim]!
        }
        dirtySections[dim] = dirty
    }

    /// flip mesh mode at runtime and rebuild every visible section
    public func setMeshMode(simple: Bool) {
        settings.simpleMesh = simple
        settings = sanitizedSettings(settings)
        saveSettings(settings)
        remeshAll()
    }

    private func remeshAll() {
        host?.clearAllSections()
        meshJobs.removeAll()
        guard inWorld else { return }
        let w = world
        for c in w.chunks.values where c.status == .lit {
            for s in 0..<c.sections {
                dirtySections[dim]!.insert(SectionPos(cx: c.cx, sy: s, cz: c.cz))
            }
        }
    }

    private func dispatchMesh(_ w: World, _ pos: SectionPos, _ jobKey: DimSection) {
        let snapOpt = LoadProf.shared.time("snapshot") { buildSnapshot(w, pos.cx, pos.sy, pos.cz) }
        guard var snap = snapOpt else {
            // a diagonal neighbor is missing (streaming frontier / unload churn) —
            // the dirty key was already consumed, so REQUEUE or this section's
            // remesh is lost forever (stale black mesh / permanent hole)
            dirtySections[w.dim]!.insert(pos)
            return
        }
        snap.noMerge = settings.simpleMesh
        let state = MeshJobState()
        meshJobs[jobKey] = state
        let d = w.dim
        let minY = w.info.minY
        meshQueue.async { [weak self] in
            let mesh = LoadProf.shared.time("mesh") { buildSectionMesh(snap) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.meshJobs.removeValue(forKey: jobKey)
                guard self.inWorld, self.worlds[d] === w else { return }
                if d == self.dim {
                    self.host?.uploadMesh(pos.cx, pos.sy, pos.cz, minY, mesh)
                    self.meshedThisSecond += 1
                }
                if state.dirtyAgain { self.dirtySections[d]!.insert(pos) }
            }
        }
    }

    /// reset the once-per-second chunk-update counter (the app's fps timer calls this)
    public func harvestMeshCounter() -> Int {
        let n = meshedThisSecond
        meshedThisSecond = 0
        lastChunkUpdates = n
        return n
    }

    /// padded 18×18×18 snapshot for the mesher
    private func buildSnapshot(_ w: World, _ cx: Int, _ sy: Int, _ cz: Int) -> MeshInput? {
        let P = 18
        var blocks = [UInt16](repeating: 0, count: P * P * P)
        var skyLight = [UInt8](repeating: 0, count: P * P * P)
        var blockLight = [UInt8](repeating: 0, count: P * P * P)
        var biomes = [UInt8](repeating: 0, count: P * P)
        let minY = w.info.minY
        let baseY = minY + sy * 16
        let baseX = cx * 16, baseZ = cz * 16
        for dz in -1...16 {
            for dx in -1...16 {
                let wx = baseX + dx, wz = baseZ + dz
                guard let c = w.getChunkAt(wx, wz) else { return nil }
                let lx = posMod(wx, 16), lz = posMod(wz, 16)
                let col = (dz + 1) * P + (dx + 1)
                biomes[col] = UInt8(c.biomeAt(lx, min(minY + w.info.height - 1, max(minY, baseY + 8)), lz))
                for dy in -1...16 {
                    let wy = baseY + dy
                    let idx = ((dy + 1) * P + (dz + 1)) * P + (dx + 1)
                    if wy < minY || wy >= minY + w.info.height {
                        skyLight[idx] = wy >= minY + w.info.height ? 15 : 0
                    } else {
                        blocks[idx] = c.get(lx, wy, lz)
                        skyLight[idx] = UInt8(c.getSky(lx, wy, lz))
                        blockLight[idx] = UInt8(c.getBlockLight(lx, wy, lz))
                    }
                }
            }
        }
        return MeshInput(blocks: blocks, skyLight: skyLight, blockLight: blockLight, biomes: biomes)
    }

    /// drop every GPU mesh and re-mesh all lit chunks in the current dimension —
    /// used when the atlas/tint semantics change under us (resource pack swap)
    public func remeshAllLoaded() {
        guard hasWorld() else { return }
        host?.clearAllSections()
        meshJobs.removeAll()
        stalledSections.removeAll()
        for c in world.chunks.values where c.status == .lit {
            for s in 0..<c.sections {
                dirtySections[dim]!.insert(SectionPos(cx: c.cx, sy: s, cz: c.cz))
            }
        }
    }

    // ===========================================================================
    // Dimension travel
    // ===========================================================================
    private func moveToDimension(_ dest: Dim) {
        let from = world
        from.cancelRPGTemporaryEffects(ownerID: player.effectiveRPGAuthorityID)
        _ = from.removeRPGWardenMitigationLayers(
            ownerAuthorityID: player.effectiveRPGAuthorityID
        )
        player.clearRPGTerminalUpkeeps()
        from.removeEntity(player)
        dim = dest
        let w = world
        player.world = w
        w.addEntity(player)
        host?.clearAllSections()
        meshJobs.removeAll()
        // re-mesh everything already loaded in the destination
        for c in w.chunks.values where c.status == .lit {
            for s in 0..<c.sections {
                dirtySections[dest]!.insert(SectionPos(cx: c.cx, sy: s, cz: c.cz))
            }
        }
    }

    private func travelNetherPortal() {
        if traveling { return }
        traveling = true
        defer { traveling = false }
        let p = player!
        let fromDim = dim
        let destDim: Dim = fromDim == .nether ? .overworld : .nether
        let scale = DIMS[fromDim.rawValue].coordScale / DIMS[destDim.rawValue].coordScale
        let tx = p.x * scale, tz = p.z * scale
        let destW = worlds[destDim]!
        ensureChunksLoaded(destW, floorDiv(ifloor(tx), 16), floorDiv(ifloor(tz), 16), 1)
        let (px, py, pz) = findOrCreatePortal(
            destW, tx,
            clampD(p.y, Double(destW.info.minY + 4), Double(destW.info.minY + destW.info.height - 8)), tz)
        moveToDimension(destDim)
        p.setPos(px, py, pz)
        p.vx = 0; p.vy = 0; p.vz = 0
        p.portalCooldown = 200
        p.portalTicks = 0
        p.insidePortalKind = nil
        host?.playSound("block.portal.travel", px, py, pz, 1, 1)
        advance("nether_root")
    }

    private func travelEndPortal() {
        if traveling { return }
        traveling = true
        defer { traveling = false }
        let p = player!
        if dim != .end {
            let end = worlds[.end]!
            ensureChunksLoaded(end, floorDiv(100, 16), 0, 1)
            let (px, py, pz) = buildEndSpawnPlatform(end)
            moveToDimension(.end)
            p.setPos(px, py, pz)
            p.vx = 0; p.vy = 0; p.vz = 0
            p.portalCooldown = 200
            p.insidePortalKind = nil
            advance("enter_end")
            // first visit: the fight begins
            if !(worldRec?.dragonKilled ?? false) && !dragonSpawned {
                ensureChunksLoaded(end, 0, 0, 2)
                let dragon = spawnMob(end, "ender_dragon", 0.5, 90, 0.5, nil) as? EnderDragon
                if let dragon { armDragon(dragon) }
                dragonSpawned = true
            }
        } else {
            // leaving the End: drop at world spawn (credits-free return)
            let ow = worlds[.overworld]!
            ensureChunksLoaded(ow, floorDiv(Int(ow.spawnX), 16), floorDiv(Int(ow.spawnZ), 16), 1)
            moveToDimension(.overworld)
            p.setPos(ow.spawnX + 0.5, Double(ow.surfaceY(Int(ow.spawnX), Int(ow.spawnZ))), ow.spawnZ + 0.5)
            p.vx = 0; p.vy = 0; p.vz = 0
            p.portalCooldown = 200
            p.insidePortalKind = nil
        }
    }

    private func armDragon(_ dragon: EnderDragon) {
        dragonSpawned = true
        dragon.onDeath = { [weak self] _ in
            guard let self, let end = self.worlds[.end] else { return }
            activateEndPortal(end)
            let n = self.worldRec?.gatewaysSpawned ?? 0
            self.worldRec?.gatewaysSpawned = n + 1
            spawnEndGateway(end, n)
            self.worldRec?.dragonKilled = true
            self.advance("kill_dragon")
            self.host?.pushChat("§dThe Ender Dragon has been defeated!")
        }
    }

    private func tickPortals() {
        let p = player!
        if p.portalCooldown > 0 {
            p.insidePortalKind = nil
            return
        }
        let bb = p.bb()
        var inNether = false, inEnd = false
        var inGateway: BlockEntityData? = nil
        let x0 = ifloor(bb.x0), x1 = ifloor(bb.x1)
        let y0 = ifloor(bb.y0), y1 = ifloor(bb.y1)
        let z0 = ifloor(bb.z0), z1 = ifloor(bb.z1)
        let w = world
        for y in y0...y1 {
            for z in z0...z1 {
                for x in x0...x1 {
                    let id = w.getBlockId(x, y, z)
                    if id == Int(B.nether_portal) { inNether = true }
                    else if id == Int(B.end_portal) { inEnd = true }
                    else if id == Int(B.end_gateway) {
                        if let be = w.getBlockEntity(x, y, z), be.type == "end_gateway" { inGateway = be }
                    }
                }
            }
        }
        if let be = inGateway {
            if traveling { return }
            traveling = true
            defer { traveling = false }
            p.portalCooldown = 200
            let exitX = be.exitX ?? 0, exitZ = be.exitZ ?? 0
            ensureChunksLoaded(w, floorDiv(exitX, 16), floorDiv(exitZ, 16), 1)
            let sy = w.surfaceY(exitX, exitZ)
            p.setPos(Double(exitX) + 0.5,
                     (be.exactTeleport ?? false) ? Double(be.exitY ?? 0) : Double(max(sy, 50)),
                     Double(exitZ) + 0.5)
            p.vx = 0; p.vy = 0; p.vz = 0
            host?.playSound("block.portal.travel", p.x, p.y, p.z, 1, 1)
            advance("enter_gateway")
            return
        }
        if inEnd {
            travelEndPortal()
            return
        }
        if inNether {
            p.insidePortalKind = "nether"
            p.portalTicks += 1
            let wait = p.gameMode == GameMode.creative ? 1 : 80
            if p.portalTicks >= wait { travelNetherPortal() }
        } else {
            p.insidePortalKind = nil
        }
    }

    @discardableResult
    private func tickTemplatePlacementJob() -> Bool {
        guard let job = templatePlacementJob else { return false }
        templatePlacementProgressTick += 1
        _ = job.step(maxOperations: 12_000)
        if job.isDone {
            finishTemplatePlacementJob(job)
        } else if templatePlacementProgressTick % 10 == 1 {
            let progress = job.progress
            host?.showActionBar("Placing \"\(progress.templateName)\" \(progress.percent)% - \(progress.phase)", 25)
        }
        return true
    }

    /// Single completion path for a `.done` placement job, shared by the per-tick
    /// path (`tickTemplatePlacementJob`) and the graceful-termination settle path
    /// (`settleInFlightTemplatePlacementJobs`). Publishes the undo snapshot, fires
    /// `onTemplatePlacementCommitted` (LAN dirty-section marking hooks this event),
    /// resets placement-mode input state, and reports the result exactly once no
    /// matter which caller drove the job to completion.
    private func finishTemplatePlacementJob(_ job: ObjectTemplatePlacementJob) {
        guard let result = job.result else { return }
        let progress = job.progress
        let undo = job.undoSnapshot
        lastTemplatePlacementUndo = undo
        templatePlacementJob = nil
        templatePlacementProgressTick = 0
        leftDown = false
        rightDown = false
        player?.breakingProgress = -1
        targetedBlock = nil
        lastCursorHit = nil
        onTemplatePlacementCommitted?(world, undo)
        var details = "\(result.blocksPlaced) blocks, \(result.blockEntitiesPlaced) block entities"
        if result.blocksCleared > 0 || result.supportBlocksFilled > 0 {
            details += ", cleared \(result.blocksCleared), filled \(result.supportBlocksFilled)"
        }
        host?.pushChat("§7Placed object \"\(progress.templateName)\" - \(details)")
        host?.showActionBar("Placed \"\(progress.templateName)\"", 60)
    }

    /// True when an in-flight placement job (currently the single local job; LAN
    /// per-peer jobs will extend this to OR in the per-peer collection) still has
    /// unpersisted work. Used by callers that need to know before deciding whether
    /// to surface a "finishing up" message ahead of a settle.
    public func hasActiveTemplatePlacementJob() -> Bool {
        templatePlacementJob != nil
    }

    /// Drives every in-flight placement job to completion synchronously, publishing
    /// its undo snapshot exactly as the per-tick path does, so a graceful termination
    /// (Cmd-Q, Save & Quit, or any other final flush) never persists a half-placed
    /// object. Intended for the `saveAndFlush` final-flush path only — never call this
    /// from `tick()`/autosave, since autosave must remain a structural no-op mid-job.
    ///
    /// LAN forward-compatibility: this is the single drain point host-side per-peer
    /// placement jobs will extend. When that lands, peers MUST be drained in sorted
    /// peer-ID order so the resulting world mutation order (and therefore any derived
    /// dirty-section replication) stays deterministic across runs; `finishTemplatePlacementJob`
    /// will be reused per peer, adapted to the per-peer LAN undo store.
    ///
    /// Bounded by the job's own operation caps plus a hard iteration ceiling; if that
    /// ceiling is somehow hit (the phase machine fails to converge), the job is abandoned
    /// so the flush is never blocked — this is a fail-toward-saving backstop, not an
    /// expected outcome, and it is surfaced to the player and the log rather than
    /// silently swallowed.
    ///
    /// - Returns: the number of jobs settled (0 or 1 today; LAN will return N).
    @discardableResult
    public func settleInFlightTemplatePlacementJobs() -> Int {
        guard let job = templatePlacementJob else { return 0 }
        let maxOperations = 12_000
        let totalOperations = job.progress.totalOperations
        let ceiling = (totalOperations + maxOperations - 1) / maxOperations + 2
        var iterations = 0
        while !job.isDone {
            guard iterations < ceiling else {
                templatePlacementJob = nil
                templatePlacementProgressTick = 0
                let warning = "Could not finish placing \"\(job.progress.templateName)\" before saving; the partial object was left in place."
                host?.pushChat("§c" + warning)
                print("[templates] settleInFlightTemplatePlacementJobs: abandoned after \(iterations) iterations — \(warning)")
                return 0
            }
            _ = job.step(maxOperations: maxOperations)
            iterations += 1
        }
        finishTemplatePlacementJob(job)
        return 1
    }

    // ===========================================================================
    // Tick
    // ===========================================================================
    private func tick() {
        rpgClockAdvancedThisTick = false
        if !inWorld { return }
        let w = world
        let p = player!
        paused = (host?.screenPausesGame() ?? false) && !lanHostKeepsSimulationRunning
        if paused { return }

        if !isLANClientWorld {
            let current = rpgSimulationTick
            let next = rpgSaturatedAdd(current, 1)
            if next > current {
                rpgClockAdvancedThisTick = true
                worldRec?.rpgSimulationTick = next
                for loadedWorld in worlds.values { loadedWorld.rpgSimulationTick = next }
                // Clock-driven state and expiry must not freeze behind later
                // early-return gates. Iterate dimensions in stable registration
                // order for deterministic guarded cleanup.
                p.tickRPGContinuousState()
                for dimension in [Dim.overworld, .nether, .end] {
                    worlds[dimension]?.tickRPGTemporaryEffects()
                }
            }
        }

        if isLANClientWorld { lanClientTickCounter += 1 }
        streamChunks()
        if tickTemplatePlacementJob() { return }
        if isLANClientWorld {
            _ = removeLANClientNonAuthoritativeEntities(from: w, localPlayer: p)
        }

        // ---- player intent ----
        let playerDead = p.dead || p.deathTime > 0
        let blocked = (host?.hasScreen() ?? false) || playerDead || p.sleepTicks > 0
        if !blocked {
            func k(_ b: String) -> Bool { keys.contains(keybinds[b] ?? "") }
            p.moveForward = (k("forward") ? 1 : 0) + (k("back") ? -1 : 0)
            // applyInput's strafe basis points +strafe to the LEFT of the view
            // direction (golden baselines shipped the same quirk) — flip here so D=right
            p.moveStrafe = (k("right") ? -1 : 0) + (k("left") ? 1 : 0)
            // vanilla: eating / drawing a bow slows movement to 20%
            if p.usingItem {
                p.moveForward *= 0.2
                p.moveStrafe *= 0.2
            }
            p.jumping = k("jump")
            p.sneaking = k("sneak") && !p.flying
            let wantSprint = (k("sprint") || sprintHeld) && p.moveForward > 0 && p.hunger > 6 && !p.sneaking
            if wantSprint && !p.sprinting && p.moveForward > 0 { p.sprinting = true }
            if !wantSprint || p.moveForward <= 0 || p.horizontalCollision { p.sprinting = false }
            sprintHeld = p.sprinting
            p.syncFlightEquipmentState()
            // elytra start: jump while airborne
            if k("jump") && !p.onGround && !p.elytraFlying && p.vy < 0 && !p.flying {
                if p.startElytra() {
                    host?.playSound("item.armor.equip_elytra", p.x, p.y, p.z, 1, 1)
                }
            }
        } else {
            p.moveForward = 0
            p.moveStrafe = 0
            p.jumping = false
            p.sprinting = false
        }

        // ---- player physics & state ----
        if !p.x.isFinite || !p.y.isFinite || !p.z.isFinite {
            // physics blowup — recover instead of rendering nothing forever
            p.setPos(w.spawnX + 0.5, max(p.prevY.isFinite ? p.prevY : w.spawnY, w.spawnY), w.spawnZ + 0.5)
            p.vx = 0; p.vy = 0; p.vz = 0
        }
        let feetReady = w.isChunkReady(floorDiv(ifloor(p.x), 16), floorDiv(ifloor(p.z), 16))
        if !playerDead && (!feetReady || traveling) {
            // the world doesn't exist under the player yet — hold them in place
            p.prevX = p.x; p.prevY = p.y; p.prevZ = p.z
            p.vx = 0; p.vy = 0; p.vz = 0
            p.fallDistance = 0
            heldForChunks = true
        } else if !playerDead {
            if heldForChunks {
                heldForChunks = false
                // if the hold began mid-fall through unloaded terrain, the player may
                // now be inside solid blocks or under the world — surface them
                let bx = ifloor(p.x), bz = ifloor(p.z)
                let inSolid = blockDefs[w.getBlockId(bx, ifloor(p.y), bz)].solid ||
                    blockDefs[w.getBlockId(bx, ifloor(p.y + 1), bz)].solid
                if p.y < Double(w.info.minY + 1) || inSolid {
                    p.setPos(p.x, Double(w.surfaceY(bx, bz)), p.z)
                }
            }
            p.tickFromGameCore(
                authoritativeRPG: !isLANClientWorld && rpgClockAdvancedThisTick
            )
            if let v = p.vehicle {
                p.setPos(v.x, v.y + v.height * 0.6, v.z)
                p.fallDistance = 0
                p.vx = 0; p.vy = 0; p.vz = 0
            } else if p.flying {
                p.travelCreativeFlight(ascend: keys.contains(keybinds["jump"] ?? ""),
                                       descend: keys.contains(keybinds["sneak"] ?? ""))
            } else if p.elytraFlying {
                p.move(p.vx, p.vy, p.vz)
            } else if p.sleepTicks <= 0 {
                p.travel()
            }
            if p.sprinting { p.addExhaustion(0.0) }
        } else {
            p.tickDeath()
            if !deathScreenShown {
                deathScreenShown = true
                host?.closeAllScreens()
                host?.openDeathScreen(deathCauseText(p.data.deathCause, p.data.deathAttacker))
                host?.releasePointer()
            }
        }

        if isLANClientWorld {
            _ = removeLANClientNonAuthoritativeEntities(from: w, localPlayer: p)
            for e in Array(w.entities) where e.dead && e !== p {
                w.removeEntity(e)
            }
            tickViewBob()
            tickAmbience()
            tickBossBars()
            tickLANClientMining()
            tickLANClientMirroredUse()
            tickLANClientEating()
            tickHotbarAndCooldowns(p)
            publishLANInventoryIfChanged()
            tickLANClientColumnCompletion()
            return
        }

        // ---- world & entities ----
        let activeChunkCenters = activeSimulationChunkCenters(in: w, local: p)
        let activeEntities = activeSimulationEntities(in: w, local: p)
        // RPG effects were already advanced for every loaded dimension above.
        w.tick(simCenters: activeChunkCenters, advanceRPGEffects: false)
        let simR = Double(w.simDistance * 16) * Double(w.simDistance * 16)
        for e in Array(w.entities) {
            if e === p || e.dead { continue }
            guard let ent = e as? Entity else { continue }
            if ent.lanReplicatedMirror { continue }
            let inRange = activeEntities.contains { active in
                let dx = ent.x - active.x
                let dz = ent.z - active.z
                return dx * dx + dz * dz <= simR
            }
            if !inRange && !ALWAYS_TICK.contains(ent.type) { continue }
            ent.tick()
            // sculk catalyst blooms on death
            if let liv = ent as? LivingEntity, liv.catalystBloomPending {
                liv.catalystBloomPending = false
                tryCatalystBloom(w, ent.x, ent.y, ent.z, liv.xpReward)
            }
        }
        for e in Array(w.entities) where e.dead {
            w.removeEntity(e)
        }

        // ---- per-tick systems ----
        tickEntityTriggers(w)
        tickFangs(w)
        // (updateDaylightDetectors is a no-op — detectors self-schedule ticks)
        naturalSpawnTick(w, [p], &w.rng)
        raidManager.tick(w)
        if w.time % 1200 == 0 && dim == .overworld { tryPatrolSpawn(w, [p], &w.rng) }
        raidManager.tryStartRaid(w, p)
        tickWeatherEffects()
        tickPortals()
        tickUsing()
        tickMining()
        tickViewBob()
        tickAmbience()
        tickAdvancementScan()
        tickBossBars()

        // toasts
        while !advancements.pendingToasts.isEmpty {
            host?.pushToast(advancements.pendingToasts.removeFirst())
        }

        // sleeping skips to morning
        if p.sleepTicks > 100 {
            p.sleepTicks = 0
            w.dayTime = 0
            if w.raining && w.rng.chance(0.6) {
                w.raining = false
                w.thundering = false
                w.weatherTimer = 12000
            }
            advance("sleep_in_bed")
        }

        tickHotbarAndCooldowns(p)

        // portal overlay warp factor
        let targetWarp = p.insidePortalKind == "nether" ? min(1, Double(p.portalTicks) / 60) : 0
        portalWarp += (targetWarp - portalWarp) * 0.1

        // batched unload writes — one transaction per second at most
        if !pendingChunkSaves.isEmpty && w.time % 20 == 0 {
            let batch = Array(pendingChunkSaves.values)
            pendingChunkSaves.removeAll()
            saveQueue.async { [weak self] in self?.writeChunkBatch(batch) }
        }

        // autosave
        ticksSinceSave += 1
        if ticksSinceSave >= SAVE_INTERVAL_TICKS {
            ticksSinceSave = 0
            saveAndFlush()
        }
    }

    private func tickHotbarAndCooldowns(_ p: Player) {
        if p.selectedSlot != lastSlot {
            lastSlot = p.selectedSlot
            heldNameTime = 60
        } else if heldNameTime > 0 {
            heldNameTime -= 1
        }
        if useCooldown > 0 { useCooldown -= 1 }
        if breakCooldown > 0 { breakCooldown -= 1 }
    }

    private func tryCatalystBloom(_ w: World, _ x: Double, _ y: Double, _ z: Double, _ xp: Int) {
        let bx = ifloor(x), by = ifloor(y), bz = ifloor(z)
        for dy in -4...4 {
            for dz in -4...4 {
                for dx in -4...4 {
                    if w.getBlockId(bx + dx, by + dy, bz + dz) == Int(B.sculk_catalyst) {
                        sculkBloom(w, bx + dx, by + dy, bz + dz, xp)
                        advance("avoid_warden")
                        return
                    }
                }
            }
        }
    }

    private func tickWeatherEffects() {
        let w = world
        if dim != .overworld { return }
        let p = player!
        // lightning strikes
        if w.thundering && w.rng.chance(0.00004 * w.thunderLevel * 16) {
            let x = ifloor(p.x + (w.rng.nextFloat() - 0.5) * 160)
            let z = ifloor(p.z + (w.rng.nextFloat() - 0.5) * 160)
            if w.isLoadedAt(x, z) {
                let y = w.surfaceY(x, z)
                if w.canSeeSky(x, y, z) {
                    spawnLightningFn?(w, Double(x) + 0.5, Double(y), Double(z) + 0.5)
                }
            }
        }
        // snow/ice accumulation + fire spread damp: sample random loaded columns
        if w.rainLevel > 0.5 {
            for _ in 0..<4 {
                let x = ifloor(p.x + (w.rng.nextFloat() - 0.5) * 128)
                let z = ifloor(p.z + (w.rng.nextFloat() - 0.5) * 128)
                if w.isLoadedAt(x, z) { weatherRandomTick(w, x, z) }
            }
        }
        // precipitation particles near the camera (cosmetic randomness stays native)
        if w.rainLevel > 0.2 && settings.particles > 0 {
            let n = Int((6 * w.rainLevel).rounded())
            for _ in 0..<n {
                let x = p.x + (Double.random(in: 0..<1) - 0.5) * 18
                let z = p.z + (Double.random(in: 0..<1) - 0.5) * 18
                let bx = ifloor(x), bz = ifloor(z)
                if !w.isLoadedAt(bx, bz) { continue }
                let top = Double(w.heightAt(bx, bz) + 1)
                if top > p.y + 14 || top < p.y - 20 { continue }
                let biome = w.biomeAt(bx, ifloor(p.y), bz)
                if snowsAt(biome, Int(top)) {
                    host?.spawnPrecipitation("snow", x, p.y + 8 + Double.random(in: 0..<4), z, 0)
                } else if (BIOMES[biome]?.downfall ?? 1) > 0.05 {
                    host?.spawnPrecipitation("rain", x, top + 4 + Double.random(in: 0..<8), z, top)
                }
            }
        }
    }

    /// per-tick walk-bob state, vanilla-style smoothed amplitude
    private func tickViewBob() {
        let p = player!
        prevBobPhase = bobPhase
        prevBobAmp = bobAmp
        let speed = min(0.4, detHyp(p.x - p.prevX, p.z - p.prevZ))
        bobAmp += (speed - bobAmp) * 0.4
        if p.onGround && p.vehicle == nil {
            bobPhase += bobAmp * 1.4
        }
        // smoothed FOV kick (vanilla eases toward the speed-scaled FOV)
        prevFovScale = fovScale
        let target = p.elytraFlying ? 1.12 : (p.sprinting ? 1.15 : (p.usingItem && itemUseSlows() ? 0.9 : 1.0))
        fovScale += (target - fovScale) * 0.5
    }

    /// bows/spyglass zoom-slow while charging
    private func itemUseSlows() -> Bool {
        guard let held = player?.mainHand else { return false }
        let n = itemDef(held.id).name
        return n == "bow" || n == "spyglass" || n == "crossbow" || n == "trident"
    }

    // ---- held item use / eating / brushing ----
    private func tickUsing() {
        let p = player!
        if p.dead || p.deathTime > 0 || (host?.hasScreen() ?? false) {
            if p.usingItem { p.cancelUsingItem() }
            return
        }
        let ctx = interactCtx()
        if p.usingItem {
            guard let held = p.usingMainHandStack() else {
                p.cancelUsingItem()
                return
            }
            if !rightDown {
                releaseUsingItem(ctx)
            } else {
                p.useItemTicks += 1
                let def = itemDef(held.id)
                if def.food != nil || def.name == "potion" || def.name == "milk_bucket" {
                    if p.useItemTicks % 4 == 0 {
                        host?.playSound("entity.generic.eat", p.x, p.y, p.z, 0.4, 0.9 + Double.random(in: 0..<0.3))
                    }
                    if p.useItemTicks >= heldUseDurationTicks(def) { finishUsingItem(ctx) }
                }
            }
        } else if rightDown && useCooldown <= 0 {
            // held use repeats (block placement etc.) every 4 ticks
            doUse()
            useCooldown = 4
        }
        // brushing suspicious blocks
        let held = p.mainHand
        if rightDown, let held, itemDef(held.id).name == "brush", !p.usingItem {
            let hit = crosshairBlock()
            if let hit, (hit.cell >> 4) == Int(B.suspicious_sand) || (hit.cell >> 4) == Int(B.suspicious_gravel) {
                brushTicks += 1
                let w = world
                if brushTicks % 5 == 0 {
                    host?.playSound("item.brush.brushing", Double(hit.x), Double(hit.y), Double(hit.z), 0.8, 1)
                    w.hooks.addParticles("block", hit.px, hit.py, hit.pz, 4, 0.15, hit.cell)
                }
                if brushTicks >= 10 {
                    brushTicks = 0
                    var be = w.getBlockEntity(hit.x, hit.y, hit.z)
                    if be == nil || be!.type != "brushable" {
                        be = makeBrushableBE(hit.x, hit.y, hit.z, "trail_ruins_common", Int(hash3(w.seed, hit.x, hit.y, hit.z)))
                        w.setBlockEntity(be!)
                    }
                    let brushable = be!
                    brushable.dusted = (brushable.dusted ?? 0) + 1
                    if (brushable.dusted ?? 0) >= 4 {
                        if brushable.item == nil {
                            var rng = RandomX(UInt32(truncatingIfNeeded: brushable.lootSeed ?? 0))
                            let loot = rollLoot(brushable.lootTable ?? "trail_ruins_common", &rng, luck: 0)
                            brushable.item = loot.first ?? ItemStack(iid("stick"), 1)
                        }
                        let isGravel = (hit.cell >> 4) == Int(B.suspicious_gravel)
                        world.setBlock(hit.x, hit.y, hit.z, Int(cell(isGravel ? B.gravel : B.sand)))
                        spawnItem(world, Double(hit.x) + 0.5, Double(hit.y) + 0.6, Double(hit.z) + 0.5, brushable.item!)
                        if itemDef(brushable.item!.id).name.hasSuffix("_pottery_sherd") { advance("brush_sherd") }
                        if itemDef(brushable.item!.id).name == "sniffer_egg" { advance("sniffer_egg") }
                        host?.playSound("block.suspicious_sand.break", Double(hit.x), Double(hit.y), Double(hit.z), 1, 1)
                    }
                }
            } else {
                brushTicks = 0
            }
        } else if !rightDown {
            brushTicks = 0
        }
    }

    // ---- mining ----
    private func tickMining() {
        let p = player!
        if !leftDown || p.dead || p.deathTime > 0 || (host?.hasScreen() ?? false) {
            p.breakingProgress = -1
            return
        }
        let hitOpt = crosshairBlock()
        targetedBlock = hitOpt.map { ($0.x, $0.y, $0.z, $0.cell) }
        guard let hit = hitOpt else {
            p.breakingProgress = -1
            return
        }
        let w = world
        let def = blockDefs[hit.cell >> 4]
        if def.hardness < 0 && p.gameMode != GameMode.creative {
            p.breakingProgress = -1
            return
        }
        if p.gameMode == GameMode.creative {
            if breakCooldown <= 0 {
                finishBreaking(interactCtx(), hit.x, hit.y, hit.z)
                breakCooldown = 5
            }
            return
        }
        if breakCooldown > 0 {
            p.breakingProgress = -1
            return
        }
        if p.breakingProgress < 0 || p.breakingX != hit.x || p.breakingY != hit.y || p.breakingZ != hit.z {
            p.breakingX = hit.x; p.breakingY = hit.y; p.breakingZ = hit.z
            p.breakingProgress = 0
        }
        p.breakingProgress += breakSpeed(p, hit.cell)
        p.attackAnim = 1
        if w.time % 4 == 0 {
            host?.playSound("block.\(def.sound).hit", Double(hit.x) + 0.5, Double(hit.y) + 0.5, Double(hit.z) + 0.5, 0.25, 0.6)
            w.hooks.addParticles("block", hit.px, hit.py, hit.pz, 1, 0.12, hit.cell)
        }
        if p.breakingProgress >= 1 {
            finishBreaking(interactCtx(), hit.x, hit.y, hit.z)
            trackBreakAdvancements(hit.cell >> 4)
            p.breakingProgress = -1
            breakCooldown = 3
            p.addExhaustion(0.005)
        }
    }

    private func trackBreakAdvancements(_ id: Int) {
        let name = blockDefs[id].name
        if name.hasSuffix("_log") || name.hasSuffix("_stem") { advance("mine_log") }
        if id == Int(B.stone) || id == Int(B.deepslate) { advance("mine_stone") }
        if id == Int(B.diamond_ore) || id == Int(B.deepslate_diamond_ore) { advance("mine_diamond") }
        if id == Int(B.ancient_debris) { advance("obtain_ancient_debris") }
    }

    /// LAN-client mining: mirrors tickMining's exact progress math (same breakSpeed inputs,
    /// same cracks state) but never mutates the mirror world — on completion it emits a
    /// `.breakBlock` intent for the host to apply through the real finishBreaking path.
    private func tickLANClientMining() {
        let p = player!
        if !leftDown || p.dead || p.deathTime > 0 || (host?.hasScreen() ?? false) {
            p.breakingProgress = -1
            return
        }
        let hitOpt = crosshairBlock()
        targetedBlock = hitOpt.map { ($0.x, $0.y, $0.z, $0.cell) }
        guard let hit = hitOpt else {
            p.breakingProgress = -1
            return
        }
        let w = world
        let def = blockDefs[hit.cell >> 4]
        if def.hardness < 0 && p.gameMode != GameMode.creative {
            p.breakingProgress = -1
            return
        }
        if p.gameMode == GameMode.creative {
            if breakCooldown <= 0 {
                emitLANBreakBlockIntent(hit)
                breakCooldown = 5
            }
            return
        }
        if breakCooldown > 0 {
            p.breakingProgress = -1
            return
        }
        if p.breakingProgress < 0 || p.breakingX != hit.x || p.breakingY != hit.y || p.breakingZ != hit.z {
            p.breakingX = hit.x; p.breakingY = hit.y; p.breakingZ = hit.z
            p.breakingProgress = 0
        }
        p.breakingProgress += breakSpeed(p, hit.cell)
        p.attackAnim = 1
        if lanClientTickCounter % 4 == 0 {
            host?.playSound("block.\(def.sound).hit", Double(hit.x) + 0.5, Double(hit.y) + 0.5, Double(hit.z) + 0.5, 0.25, 0.6)
            w.hooks.addParticles("block", hit.px, hit.py, hit.pz, 1, 0.12, hit.cell)
        }
        if p.breakingProgress >= 1 {
            emitLANBreakBlockIntent(hit)
            p.breakingProgress = -1
            breakCooldown = 3
        }
    }

    private func emitLANBreakBlockIntent(_ hit: RaycastHit) {
        guard let handler = lanBlockIntentHandler else { return }
        handler(LANBlockIntent(
            action: .breakBlock,
            x: hit.x,
            y: hit.y,
            z: hit.z,
            face: hit.face,
            selectedHotbarSlot: player?.selectedSlot ?? 0,
            cell: hit.cell
        ))
    }

    private func tickLANClientMirroredUse() {
        let p = player!
        if p.dead || p.deathTime > 0 || (host?.hasScreen() ?? false) { return }
        guard rightDown && useCooldown <= 0 else { return }
        _ = performLANClientUse()
    }

    /// LAN-client eating/drinking continuation: mirrors tickUsing's food/potion completion
    /// path (client-authoritative inventory — the item is consumed locally, no world mutation
    /// involved) but never falls through to doUse's held-item-repeat branch, which would place
    /// blocks or spawn projectiles directly into the non-authoritative mirror world.
    private func tickLANClientEating() {
        let p = player!
        if p.dead || p.deathTime > 0 || (host?.hasScreen() ?? false) {
            if p.usingItem { p.cancelUsingItem() }
            return
        }
        guard p.usingItem else { return }
        let ctx = interactCtx()
        guard let held = p.usingMainHandStack() else {
            p.cancelUsingItem()
            return
        }
        if !rightDown {
            p.cancelUsingItem()
            return
        }
        p.useItemTicks += 1
        let def = itemDef(held.id)
        guard def.food != nil || def.name == "potion" || def.name == "milk_bucket" else {
            // not a food/potion use — LAN clients don't locally resolve other held-use kinds
            // (bows/tridents/crossbows spawn projectiles into the shared world and are host-only)
            p.cancelUsingItem()
            return
        }
        if p.useItemTicks % 4 == 0 {
            host?.playSound("entity.generic.eat", p.x, p.y, p.z, 0.4, 0.9 + Double.random(in: 0..<0.3))
        }
        if p.useItemTicks >= heldUseDurationTicks(def) { finishUsingItem(ctx) }
    }

    @discardableResult
    private func performLANClientUse() -> Bool {
        let p = player!
        guard let hit = crosshairBlock() else { return false }
        if openLANClientMirroredBlockScreen(hit) {
            p.attackAnim = 0.6
            useCooldown = 4
            return true
        }
        if sendLANClientOpenableBlockUse(hit) {
            p.attackAnim = 0.6
            useCooldown = 4
            return true
        }
        if !p.sneaking, let held = p.mainHand {
            let def = itemDef(held.id)
            if def.block != nil, emitLANPlaceBlockIntent(hit, held: held) {
                p.attackAnim = 0.6
                useCooldown = 4
                return true
            }
            if def.food != nil || def.name == "potion" || def.name == "milk_bucket" {
                // client-authoritative held-item use: begins the local eat/drink continuation
                // (tickLANClientEating finishes it); never touches the mirror world
                if useItem(interactCtx(), hit) {
                    p.attackAnim = 0.6
                    useCooldown = 4
                    return true
                }
            }
        }
        return false
    }

    /// computes the placement target + orientation exactly as local placement would, and emits
    /// a `.placeBlock` intent for the host to apply — the LAN client mirror world is never
    /// mutated locally (the host is the sole write authority on the shared world).
    private func emitLANPlaceBlockIntent(_ hit: RaycastHit, held: ItemStack) -> Bool {
        guard let handler = lanBlockIntentHandler,
              let blockRaw = itemDef(held.id).block
        else { return false }
        let blockId = Int(blockRaw)
        let targetCell = world.getBlock(hit.x, hit.y, hit.z)
        var px = hit.x, py = hit.y, pz = hit.z
        if REPLACEABLE[targetCell >> 4] == 0 {
            px += DIR_X[hit.face]
            py += DIR_Y[hit.face]
            pz += DIR_Z[hit.face]
        }
        let cur = world.getBlock(px, py, pz)
        if cur != 0 && REPLACEABLE[cur >> 4] == 0 { return false }
        let meta = lanClientPlacementMeta(hit, blockId: blockId, px: px, py: py, pz: pz)
        guard meta >= 0 else { return false }
        handler(LANBlockIntent(
            action: .placeBlock,
            x: hit.x,
            y: hit.y,
            z: hit.z,
            face: hit.face,
            selectedHotbarSlot: player?.selectedSlot ?? 0,
            cell: Int(cell(UInt16(blockId), meta))
        ))
        return true
    }

    /// Conservative, read-only orientation-meta computation for LAN client placement previews.
    /// This intentionally mirrors only the common cases (full cubes, stairs, slabs, axis blocks,
    /// torches) rather than the complete shape-orientation table in Interact.swift's
    /// placementMeta — that function is `Systems/*`, which this workstream is not permitted to
    /// modify (even to widen visibility), so exotic orientation-aware shapes (doors, rails,
    /// signs, crops, redstone components, ...) fall back to placing with meta 0 client-side.
    /// The host is the sole write authority regardless: an incorrect preview here only affects
    /// what the client predicts, never the shared world (documented deviation — see Builder report).
    private func lanClientPlacementMeta(_ hit: RaycastHit, blockId: Int, px: Int, py: Int, pz: Int) -> Int {
        guard let p = player else { return 0 }
        let shape = Shape(rawValue: SHAPE_OF[blockId]) ?? .cube
        let name = blockDefs[blockId].name
        let facing = [0, 0, 0, 1, 2, 3][yawToDir(p.yaw * 180 / .pi)]      // direction player faces
        let facingOpp = [1, 0, 3, 2][facing]                              // toward player
        let hitFY = hit.py - Double(hit.y)
        switch shape {
        case .stairs:
            let top = (hit.face == 0 || (hit.face != 1 && hitFY > 0.5)) ? 4 : 0
            return facing | top
        case .slab:
            let top = (hit.face == 0 || (hit.face != 1 && hitFY > 0.5)) ? 1 : 0
            return top
        case .torch:
            if blockId == Int(B.lightning_rod) || blockId == Int(B.end_rod) { return hit.face }
            if hit.face >= 2 {
                let support = world.getBlock(px - DIR_X[hit.face], py, pz - DIR_Z[hit.face]) >> 4
                if blockDefs[support].fullCube { return hit.face ^ 1 }
            }
            let below = world.getBlock(px, py - 1, pz) >> 4
            return blockDefs[below].fullCube ? 0 : -1
        case .chest:
            return facingOpp
        case .repeater, .comparator:
            return facing
        default:
            let isAxis = name.hasSuffix("_log") || name.hasSuffix("_stem") || name.hasSuffix("_wood")
                || name.contains("hyphae") || name.contains("basalt") || name == "bone_block"
                || name == "chain" || name == "quartz_pillar" || name == "purpur_pillar" || name == "bamboo_block"
            if isAxis {
                return hit.face < 2 ? 0 : (hit.face < 4 ? 2 : 1)
            }
            if blockId == Int(B.furnace) || blockId == Int(B.blast_furnace) || blockId == Int(B.smoker) {
                return facingOpp
            }
            // full cubes and every other unhandled shape: meta 0 (see doc comment above)
            return 0
        }
    }

    private func openLANClientMirroredBlockScreen(_ hit: RaycastHit) -> Bool {
        let x = hit.x, y = hit.y, z = hit.z
        let id = hit.cell >> 4
        guard id > 0 && id < blockDefs.count else { return false }
        let name = blockDefs[id].name
        var data = ScreenData()
        data.x = x
        data.y = y
        data.z = z
        data.block = id
        // D-C: LAN client container/crafting/furnace/brewing screens are now interactive —
        // edits are captured and sent to the host as whole-BE LANContainerEditIntents (the
        // host validates and applies them; last-writer-wins). Each successful branch below
        // records the open BE's identity (lanOpenContainerBE) so a later replication batch
        // that removes/replaces the block can close the screen (A9).
        data.readOnly = false
        // records which BE this mirrored screen refers to (A9 orphan-close check), then opens it
        func open(_ kind: String, _ screenData: ScreenData) {
            if let be = screenData.be {
                lanOpenContainerBE = (dim: self.dim.rawValue, x: be.x, y: be.y, z: be.z, type: be.type)
            }
            let editSnapshots = [screenData.be, screenData.other]
                .compactMap { $0 }
                .compactMap { makeLANBlockEntitySnapshot($0, dimension: self.dim.rawValue) }
            lanOpenContainerPositions = editSnapshots.map {
                LANBlockPosition(dimension: $0.dimension, x: $0.x, y: $0.y, z: $0.z)
            }
            lanOpenContainerRevision = lanBlockEntityRevision(editSnapshots)
            openScreen(kind, screenData)
        }

        if id == Int(B.crafting_table) {
            guard let be = world.getBlockEntity(x, y, z), be.type == "crafting" else { return false }
            data.be = be
            open("crafting", data)
            return true
        }
        if id == Int(B.chest) || id == Int(B.trapped_chest) {
            if blockDefs[world.getBlock(x, y + 1, z) >> 4].opaque { return true }
            guard let be = world.getBlockEntity(x, y, z) else { return false }
            var other: BlockEntityData? = nil
            for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] where (world.getBlock(x + dx, y, z + dz) >> 4) == id {
                other = world.getBlockEntity(x + dx, y, z + dz)
                break
            }
            data.be = be
            data.other = other
            data.title = other != nil ? "Large Chest" : "Chest"
            open("chest", data)
            return true
        }
        if id == Int(B.barrel) {
            guard let be = world.getBlockEntity(x, y, z) else { return false }
            data.be = be
            data.title = "Barrel"
            open("chest", data)
            return true
        }
        if name.hasSuffix("shulker_box") || id == Int(B.shulker_box) {
            guard let be = world.getBlockEntity(x, y, z) else { return false }
            data.be = be
            data.title = "Shulker Box"
            open("chest", data)
            return true
        }
        if id == Int(B.hopper) {
            guard let be = world.getBlockEntity(x, y, z), be.type == "hopper" else { return false }
            data.be = be
            data.title = "Hopper"
            open("chest", data)
            return true
        }
        if id == Int(B.dispenser) || id == Int(B.dropper) {
            guard let be = world.getBlockEntity(x, y, z) else { return false }
            data.be = be
            data.title = id == Int(B.dispenser) ? "Dispenser" : "Dropper"
            open("chest", data)
            return true
        }
        if id == Int(B.furnace) || id == Int(B.furnace_lit) || id == Int(B.blast_furnace) || id == Int(B.blast_furnace_lit) || id == Int(B.smoker) || id == Int(B.smoker_lit) {
            guard let be = world.getBlockEntity(x, y, z), be.type == "furnace" else { return false }
            data.be = be
            open("furnace", data)
            return true
        }
        if id == Int(B.brewing_stand) {
            guard let be = world.getBlockEntity(x, y, z), be.type == "brewing" else { return false }
            data.be = be
            open("brewing", data)
            return true
        }
        return false
    }

    private func sendLANClientOpenableBlockUse(_ hit: RaycastHit) -> Bool {
        guard let handler = lanBlockIntentHandler else { return false }
        let id = hit.cell >> 4
        guard isLANClientOpenableBlockUseID(id) else { return false }
        handler(LANBlockIntent(
            action: .useBlock,
            x: hit.x,
            y: hit.y,
            z: hit.z,
            face: hit.face,
            selectedHotbarSlot: player?.selectedSlot ?? 0,
            cell: hit.cell
        ))
        return true
    }

    private func isLANClientOpenableBlockUseID(_ id: Int) -> Bool {
        guard id > 0, id < blockDefs.count else { return false }
        let shape = Shape(rawValue: SHAPE_OF[id]) ?? .cube
        if shape == .door { return id != Int(B.iron_door) }
        if shape == .trapdoor { return id != Int(B.iron_trapdoor) }
        return shape == .fenceGate
    }

    // ===========================================================================
    // LAN client: container-edit capture, replication-apply guard, restore/grant/damage
    // ===========================================================================

    /// wraps the transport's per-batch replication apply — captureLANContainerEdit no-ops while
    /// set, preventing an echoed host-authored BE snapshot from being re-captured as a new edit
    /// (anti-loop, D-C §4).
    public func beginLANReplicationApply() {
        lanApplyingReplication = true
    }

    /// A9: after a batch is applied, close any open mirrored container/furnace/brewing/crafting
    /// screen whose block entity is now gone or no longer compatible with what the screen
    /// expects (broken/replaced by the host or another peer).
    public func endLANReplicationApply() {
        lanApplyingReplication = false
        guard isLANClientWorld, let open = lanOpenContainerBE, open.dim == dim.rawValue else { return }
        let be = world.getBlockEntity(open.x, open.y, open.z)
        if be == nil || be?.type != open.type {
            lanOpenContainerBE = nil
            lanOpenContainerPositions.removeAll()
            lanOpenContainerRevision = 0
            host?.closeAllScreens()
            host?.showActionBar("§cThat container is no longer available", 60)
        } else {
            let snapshots = lanOpenContainerPositions.compactMap { position -> LANBlockEntitySnapshot? in
                guard position.dimension == dim.rawValue,
                      let be = world.getBlockEntity(position.x, position.y, position.z)
                else { return nil }
                return makeLANBlockEntitySnapshot(be, dimension: position.dimension)
            }
            if !snapshots.isEmpty {
                lanOpenContainerRevision = lanBlockEntityRevision(snapshots)
            }
        }
    }

    /// captures a whole-BE snapshot of an edited mirrored container and sends it to the host
    /// (D-C). Guarded against the anti-loop flag and against firing outside LAN client worlds.
    public func captureLANContainerEdit(_ be: BlockEntityData, additional: [BlockEntityData] = []) {
        guard isLANClientWorld, !lanApplyingReplication,
              let handler = lanContainerEditHandler,
              let p = player
        else { return }
        let snapshots = ([be] + additional)
            .compactMap { makeLANBlockEntitySnapshot($0, dimension: dim.rawValue) }
        guard let snapshot = snapshots.first else { return }
        lanContainerEditSeq += 1
        lanLocalInventoryRevision += 1
        let inventory = makeLANInventorySnapshot(p, playerID: "")
        lanLastPublishedInventory = inventory
        handler(LANContainerEditIntent(
            blockEntity: snapshot,
            additionalBlockEntities: Array(snapshots.dropFirst()),
            inventory: inventory,
            revision: lanLocalInventoryRevision,
            editSeq: lanContainerEditSeq,
            blockEntityRevision: lanOpenContainerRevision
        ))
        lanOpenContainerRevision = lanBlockEntityRevision(snapshots)
    }

    /// public entry point for the app to call from a mirrored screen's close/dismiss handler
    /// (and any debounced ≤5 Hz flush while the screen stays open) — forwards to
    /// captureLANContainerEdit when there is an edit to send.
    public func gameScreenWillClose(be: BlockEntityData?) {
        guard let be else { return }
        captureLANContainerEdit(be)
        if lanOpenContainerBE?.x == be.x && lanOpenContainerBE?.y == be.y && lanOpenContainerBE?.z == be.z {
            lanOpenContainerBE = nil
            lanOpenContainerPositions.removeAll()
            lanOpenContainerRevision = 0
        }
    }

    public func gameScreenWillClose(blockEntities: [BlockEntityData]) {
        guard let be = blockEntities.first else { return }
        captureLANContainerEdit(be, additional: Array(blockEntities.dropFirst()))
        if lanOpenContainerBE?.x == be.x && lanOpenContainerBE?.y == be.y && lanOpenContainerBE?.z == be.z {
            lanOpenContainerBE = nil
            lanOpenContainerPositions.removeAll()
            lanOpenContainerRevision = 0
        }
    }

    /// applies the host's authoritative reconnect/join state: position, health/hunger,
    /// inventory + xp, and the revision/grant baselines the client resumes publishing from.
    public func applyLANRestore(_ restore: LANRestoreState) {
        guard isLANClientWorld, let p = player else { return }
        let state = restore.playerState
        if let destDim = Dim(rawValue: state.dimension), destDim != dim {
            moveToDimension(destDim)
        }
        p.setPos(state.x, state.y, state.z)
        p.yaw = state.yaw
        p.pitch = state.pitch
        p.health = state.health
        p.hunger = state.hunger
        p.selectedSlot = state.selectedHotbarSlot
        p.setGameMode(state.gameMode)
        _ = applyLANInventorySnapshot(restore.inventory, to: p)
        lanLastPublishedInventory = makeLANInventorySnapshot(p, playerID: "")
        lanLocalInventoryRevision = restore.revision
        lanLastAppliedGrantID = restore.grantID
    }

    /// merges a host-originated inventory grant (pickups via the host ghost, death clear,
    /// per-slot corrections). Monotone grantID: duplicates/regressions are ignored so replays
    /// over an unreliable connection never double-apply. Apply order: clearAll, then absolute
    /// per-slot empties/sets (arrangement-preserving corrections), then additive item merges.
    public func applyLANGrant(_ grant: LANInventoryGrant) {
        guard isLANClientWorld, let p = player, grant.grantID > lanLastAppliedGrantID else { return }
        lanLastAppliedGrantID = grant.grantID
        if grant.clearAll {
            for i in 0..<p.inventory.count { p.inventory[i] = nil }
        }
        for slot in grant.clearedSlots where slot >= 0 && slot < p.inventory.count {
            p.inventory[slot] = nil
        }
        for slot in grant.slots {
            guard slot.slot >= 0, slot.slot < p.inventory.count,
                  slot.itemID >= 0, slot.itemID < itemDefs.count,
                  slot.count > 0, slot.damage >= 0
            else { continue }
            let count = min(slot.count, maxStackOf(ItemStack(slot.itemID, 1)))
            p.inventory[slot.slot] = ItemStack(slot.itemID, count, damage: slot.damage, label: slot.label)
        }
        for slot in grant.items {
            guard slot.itemID >= 0, slot.itemID < itemDefs.count, slot.count > 0 else { continue }
            _ = p.give(ItemStack(slot.itemID, slot.count, damage: slot.damage, label: slot.label))
        }
        if grant.xp > 0 { p.xp += grant.xp }
        lanLocalInventoryRevision += 1
        lanLastPublishedInventory = makeLANInventorySnapshot(p, playerID: "")
    }

    /// applies a host-relayed damage event against the local player (the host validated the
    /// hit against the mirror proxy; the client is authoritative for its own health/knockback
    /// response). Knockback direction/magnitude mirrors the vanilla LivingEntity.hurt formula.
    public func applyLANDamage(_ event: LANDamageEvent) {
        guard isLANClientWorld, let p = player else { return }
        _ = p.hurt(event.amount, event.source, nil)
        var d = (event.knockbackX * event.knockbackX + event.knockbackZ * event.knockbackZ).squareRoot()
        if d == 0 { d = 1 }
        let kb = 0.4 * (1 - p.kbResist)
        p.vx += event.knockbackX / d * kb
        p.vz += event.knockbackZ / d * kb
        p.vy = min(p.vy + 0.36 * (1 - p.kbResist), 0.4)
    }

    /// periodic inventory / situation scan for item- & place-based advancements
    private func tickAdvancementScan() {
        let w = world
        let p = player!
        if w.time % 40 != 0 { return }
        func has(_ n: String) -> Bool {
            guard let id = iidOpt(n) else { return false }
            if p.inventory.contains(where: { $0?.id == id }) || p.offHand?.id == id { return true }
            return p.armor.contains { $0?.id == id }
        }
        if has("crafting_table") { advance("crafting_table") }
        if has("wooden_pickaxe") { advance("wooden_pickaxe") }
        if has("stone_pickaxe") { advance("stone_pickaxe") }
        if has("iron_ingot") { advance("iron_ingot") }
        if has("iron_pickaxe") { advance("iron_tools") }
        if has("iron_chestplate") || has("iron_helmet") || has("iron_leggings") || has("iron_boots") { advance("iron_armor") }
        if has("diamond") { advance("mine_diamond") }
        if has("diamond_chestplate") && has("diamond_helmet") && has("diamond_leggings") && has("diamond_boots") { advance("diamond_armor") }
        if has("blaze_rod") { advance("obtain_blaze_rod") }
        if has("ender_eye") { advance("ender_eye") }
        if has("dragon_egg") { advance("dragon_egg") }
        if has("elytra") { advance("elytra") }
        if has("ancient_debris") { advance("obtain_ancient_debris") }
        if has("netherite_helmet") && has("netherite_chestplate") && has("netherite_leggings") && has("netherite_boots") { advance("netherite_armor") }
        if has("nether_star") { advance("kill_wither") }
        if has("dragon_breath") { advance("dragon_breath") }
        if has("sniffer_egg") { advance("sniffer_egg") }
        if has("emerald") { advance("adventure_root") }
        if has("wheat_seeds") || has("wheat") { advance("husbandry_root") }
        // location-based
        if dim == .nether {
            let below = w.getBlockId(ifloor(p.x), ifloor(p.y) - 1, ifloor(p.z))
            if below == Int(B.nether_bricks) { advance("find_fortress") }
            if below == Int(B.polished_blackstone_bricks) || below == Int(B.gilded_blackstone) { advance("find_bastion") }
        }
    }

    private func tickBossBars() {
        let w = world
        var bars: [BossBarInfo] = []
        for e in w.entities {
            guard let ent = e as? Entity else { continue }
            if let d = ent as? EnderDragon {
                bars.append(BossBarInfo(name: "Ender Dragon", progress: d.health / d.maxHealth, color: "#e864e8"))
            } else if let d = ent as? WitherBoss {
                bars.append(BossBarInfo(name: "Wither", progress: d.health / d.maxHealth, color: "#7a7ab8"))
            }
        }
        for r in raidManager.raids {
            if r.world === w && r.active {
                bars.append(BossBarInfo(
                    name: "Raid",
                    progress: r.maxHealth > 0 ? min(1, r.totalHealth / max(1, r.maxHealth)) : 1,
                    color: "#e84040"))
            }
        }
        host?.setBossBars(bars)
    }

    private func tickAmbience() {
        let w = world
        let p = player!
        // audio environment
        let eyeBlock = w.getBlock(ifloor(p.x), ifloor(p.eyeY()), ifloor(p.z))
        let underwater = isWaterlogged(UInt16(eyeBlock))
        let sky = w.getSkyLight(ifloor(p.x), ifloor(p.y), ifloor(p.z))
        let caveFactor = dim == .overworld
            ? clampD(Double(8 - sky) / 8, 0, 1) * (p.y < 50 ? 1 : 0.4)
            : 0.3
        host?.setAudioEnvironment(underwater, caveFactor)
        host?.setAudioListener(p.x, p.eyeY(), p.z, p.yaw)
        // music mood
        var mood = "overworld"
        if dim == .nether { mood = "nether" }
        else if dim == .end { mood = "end" }
        else {
            let biome = w.biomeAt(ifloor(p.x), ifloor(p.y), ifloor(p.z))
            if biome == Int(Biome.deepDark.rawValue) { mood = "dark" }
            else if biome == Int(Biome.lushCaves.rawValue) { mood = "lush" }
            else if underwater { mood = "water" }
        }
        musicMood = mood
        host?.tickMusic(mood, (settings.volumes["music"] ?? 0) > 0.01)
    }

    // ===========================================================================
    // Interaction wiring
    // ===========================================================================
    private func interactCtx() -> InteractCtx {
        InteractCtx(
            world: world,
            player: player,
            openScreen: { [weak self] kind, data in self?.openScreen(kind, data) },
            advance: { [weak self] id in self?.advance(id) },
            persistPlayerState: { [weak self] in self?.saveAndFlush(synchronous: true) })
    }

    public func openScreen(_ kind: String, _ data: ScreenData?) {
        if kind == "toast" {
            host?.showActionBar(data?.text ?? "", 60)
            return
        }
        host?.openScreen(kind, data)
    }

    /// raycast a player crosshair against blocks
    static func crosshairBlock(in world: World, player p: Player) -> RaycastHit? {
        let reach = p.gameMode == GameMode.creative ? REACH_CREATIVE : REACH_SURVIVAL
        let dx = -detSin(p.yaw) * detCos(p.pitch)
        let dy = -detSin(p.pitch)
        let dz = detCos(p.yaw) * detCos(p.pitch)
        return world.raycast(p.x, p.eyeY(), p.z, dx, dy, dz, reach)
    }

    /// raycast the crosshair against blocks
    public func crosshairBlock() -> RaycastHit? {
        guard let p = player else { return nil }
        return Self.crosshairBlock(in: world, player: p)
    }

    public func templateCopyTargetAtCrosshair() -> (x: Int, y: Int, z: Int)? {
        guard let hit = crosshairBlock() else {
            targetedBlock = nil
            lastCursorHit = nil
            return nil
        }
        targetedBlock = (hit.x, hit.y, hit.z, hit.cell)
        lastCursorHit = hit
        return (hit.x, hit.y, hit.z)
    }

    /// nearest entity under the crosshair within attack reach
    private func crosshairEntity(_ maxDist: Double) -> Entity? {
        let p = player!
        let dx = -detSin(p.yaw) * detCos(p.pitch)
        let dy = -detSin(p.pitch)
        let dz = detCos(p.yaw) * detCos(p.pitch)
        let ox = p.x, oy = p.eyeY(), oz = p.z
        var best: Entity? = nil
        var bestT = maxDist
        let blockHit = world.raycast(ox, oy, oz, dx, dy, dz, maxDist)
        let blockT = blockHit?.t ?? maxDist
        for e in world.getEntitiesNear(ox, oy, oz, maxDist + 2) {
            if e === p || e.dead { continue }
            guard let ent = e as? Entity else { continue }
            if !(ent is LivingEntity) && !["boat", "minecart", "item_frame", "end_crystal"].contains(ent.type) { continue }
            let bb = ent.bb()
            if let t = rayBoxT(ox, oy, oz, dx, dy, dz,
                               bb.x0 - 0.1, bb.y0 - 0.1, bb.z0 - 0.1,
                               bb.x1 + 0.1, bb.y1 + 0.1, bb.z1 + 0.1),
               t < bestT && t < blockT {
                best = ent
                bestT = t
            }
        }
        return best
    }

    private func doAttack() {
        let p = player!
        if p.dead || p.deathTime > 0 || (host?.hasScreen() ?? false) { return }
        let target = crosshairEntity(ATTACK_REACH)
        p.attackAnim = 1
        if let target {
            if target is LivingEntity || target.type == "end_crystal" {
                playerAttack(p, target)
                advance("kill_mob_attempt")
            } else if target.type == "boat" || target.type == "minecart" {
                _ = target.hurt(2, "player", p)
            }
            return
        }
        host?.playSound("entity.player.attack.sweep", p.x, p.y, p.z, 0.3, 1.2)
    }

    /// LAN-client left-click dispatcher (replaces doAttack for LAN clients — C3 fix): raycasts
    /// for an attackable mirror mob within attack reach first; a hurtable, non-player mirror
    /// entity emits a LANAttackIntent targeting the HOST's real entity id (the mirror's
    /// lanReplicationSourceID) and plays the local swing purely cosmetically. Otherwise begins
    /// client-side mining (tickLANClientMining picks it up next tick). Never calls doAttack —
    /// that would run playerAttack against the ghost-less local player, hurting the mirror
    /// entity directly instead of routing through the host's authoritative combat.
    private func performLANClientAttackOrMine() {
        let p = player!
        if p.dead || p.deathTime > 0 || (host?.hasScreen() ?? false) { return }
        if let target = crosshairEntity(ATTACK_REACH),
           target is LivingEntity,
           !target.isPlayer,
           let hostEntityID = target.lanReplicationSourceID,
           let handler = lanAttackIntentHandler {
            p.attackAnim = 1
            handler(LANAttackIntent(
                targetEntityID: hostEntityID,
                selectedHotbarSlot: p.selectedSlot,
                sprinting: p.sprinting
            ))
            return
        }
    }

    /// LAN-client toss (Q / drop key): emits a LANTossIntent and optimistically decrements the
    /// local slot (client-authoritative inventory) but never spawns a local ItemEntity — the
    /// host is the sole authority on the shared world and spawns the dropped item there,
    /// replicating it back as a mirror entity like any other item drop.
    private func performLANClientToss(all: Bool) {
        guard let p = player, let handler = lanTossIntentHandler, let stack = p.mainHand else { return }
        let count = all ? stack.count : 1
        guard count > 0 else { return }
        handler(LANTossIntent(slot: p.selectedSlot, count: count, all: all))
        stack.count -= count
        if stack.count <= 0 { p.mainHand = nil }
    }

    /// per-tick diff of the local player's inventory/selected-slot/xp against the last published
    /// snapshot; on change, bumps the client-owned revision counter and publishes. Client-owned
    /// inventory authority (D-A): the host never overwrites this except via LANRestoreState
    /// (reconnect) or LANInventoryGrant (additive correction).
    private func publishLANInventoryIfChanged() {
        guard let p = player, let handler = lanInventoryPublishHandler else { return }
        if p.dead || p.deathTime > 0 { return }   // D-race: don't overwrite the host's pre-death snapshot
        let snapshot = makeLANInventorySnapshot(p, playerID: "")
        if snapshot == lanLastPublishedInventory { return }
        lanLastPublishedInventory = snapshot
        lanLocalInventoryRevision += 1
        handler(snapshot, lanLocalInventoryRevision)
    }

    private func doUse() {
        let p = player!
        if p.dead || p.deathTime > 0 || (host?.hasScreen() ?? false) { return }
        let ctx = interactCtx()
        // entities first
        let target = crosshairEntity(REACH_SURVIVAL - 1)
        if let target, !p.sneaking {
            if target.interact(p, p.mainHand) {
                p.attackAnim = 0.6
                return
            }
        }
        let hit = crosshairBlock()
        if let hit, !p.sneaking || p.mainHand == nil {
            if useBlock(ctx, hit) {
                p.attackAnim = 0.6
                return
            }
        }
        if useItem(ctx, hit) {
            p.attackAnim = 0.6
        }
    }

    private func pickBlock() {
        let p = player!
        guard let hit = crosshairBlock() else { return }
        let raw = blockToItem[hit.cell >> 4]
        if raw < 0 { return }
        let itemId = Int(raw)
        // already in hotbar?
        for i in 0..<9 {
            if p.inventory[i]?.id == itemId {
                p.selectedSlot = i
                return
            }
        }
        if p.gameMode == GameMode.creative {
            p.inventory[p.selectedSlot] = ItemStack(itemId, 1)
        } else {
            for i in 9..<36 {
                if p.inventory[i]?.id == itemId {
                    let tmp = p.inventory[p.selectedSlot]
                    p.inventory[p.selectedSlot] = p.inventory[i]
                    p.inventory[i] = tmp
                    return
                }
            }
        }
    }

    // ===========================================================================
    // Object-template placement preview
    // ===========================================================================
    public func beginTemplatePlacement(_ template: ObjectTemplate) throws {
        let session = try TemplatePlacementSession(template: template)
        templatePlacement = session
        leftDown = false
        rightDown = false
        player?.breakingProgress = -1
        targetedBlock = nil
        lastCursorHit = nil
        host?.closeAllScreens()
        host?.capturePointer()
        host?.showActionBar("Placing \"\(session.name)\" - scroll to rotate, left click to place, Esc to cancel", 120)
    }

    @discardableResult
    public func rotateTemplatePlacement(by delta: Int) -> Bool {
        guard var session = templatePlacement else { return false }
        do {
            try session.rotate(by: delta)
            templatePlacement = session
            host?.showActionBar("Placement rotation: \(session.rotationDegrees) degrees", 45)
        } catch {
            host?.showActionBar("Placement rotation failed", 45)
        }
        return true
    }

    public func cancelTemplatePlacement(showMessage: Bool = true) {
        guard templatePlacement != nil else { return }
        templatePlacement = nil
        leftDown = false
        rightDown = false
        player?.breakingProgress = -1
        targetedBlock = nil
        lastCursorHit = nil
        if showMessage {
            host?.showActionBar("Template placement canceled", 50)
        }
    }

    public func templatePlacementTarget() -> TemplatePlacementTarget? {
        guard let session = templatePlacement, let p = player else { return nil }
        return objectTemplatePlacementTargetForValidatedTemplate(
            session.rotatedTemplate,
            eyeX: p.x, eyeY: p.eyeY(), eyeZ: p.z,
            yaw: p.yaw, pitch: p.pitch)
    }

    @discardableResult
    public func commitTemplatePlacement() throws -> TemplatePlacementResult? {
        guard templatePlacementJob == nil else { return nil }
        guard let session = templatePlacement else { return nil }
        guard let target = templatePlacementTarget() else { throw TemplateError.missingTarget }
        let job = try ObjectTemplatePlacementJob(rawTemplate: session.rotatedTemplate, in: world,
                                                 targetX: target.targetX,
                                                 targetY: target.targetY,
                                                 targetZ: target.targetZ,
                                                 options: TemplatePlacementOptions(prepareTerrain: true))
        templatePlacementJob = job
        templatePlacementProgressTick = 0
        templatePlacement = nil
        leftDown = false
        rightDown = false
        player?.breakingProgress = -1
        targetedBlock = nil
        lastCursorHit = nil
        let progress = job.progress
        host?.showActionBar("Placing \"\(progress.templateName)\" 0% - \(progress.phase)", 60)
        return nil
    }

    @discardableResult
    public func undoLastTemplatePlacement() -> Bool {
        guard templatePlacementJob == nil else {
            host?.showActionBar("Template placement is still running", 55)
            return false
        }
        guard let undo = lastTemplatePlacementUndo else {
            host?.showActionBar("No object placement to undo", 55)
            return false
        }
        guard undo.dimension == dim.rawValue else {
            host?.showActionBar("Cannot undo — object was placed in another dimension", 60)
            return false
        }
        guard templateUndoSnapshotFullyLoaded(undo, in: world) else {
            host?.showActionBar("Move closer to the object to undo it", 60)
            return false
        }
        if templatePlacement != nil {
            cancelTemplatePlacement(showMessage: false)
        }
        let restored = restoreObjectTemplatePlacementUndo(undo, in: world)
        lastTemplatePlacementUndo = nil
        leftDown = false
        rightDown = false
        player?.breakingProgress = -1
        targetedBlock = nil
        lastCursorHit = nil
        host?.pushChat("§7Undid object placement \"\(undo.templateName)\" - restored \(restored) cells")
        host?.showActionBar("Undid \"\(undo.templateName)\"", 60)
        return true
    }

    // ===========================================================================
    // Input — the app forwards events here when no screen is open
    // ===========================================================================
    public func mouseDown(_ button: Int) {
        guard inWorld, !(host?.hasScreen() ?? false) else { return }
        if let job = templatePlacementJob {
            let progress = job.progress
            host?.showActionBar("Placing \"\(progress.templateName)\" \(progress.percent)% - \(progress.phase)", 25)
            return
        }
        if templatePlacement != nil {
            if button == 0 {
                do {
                    _ = try commitTemplatePlacement()
                } catch let error as TemplateError {
                    host?.pushChat("§c" + error.description)
                    host?.showActionBar(error.description, 70)
                } catch {
                    host?.pushChat("§cPlace failed: \(error)")
                    host?.showActionBar("Place failed", 70)
                }
            } else if button == 2 {
                cancelTemplatePlacement()
            }
            return
        }
        if button == 0 {
            if consumeSelectedFoodNow(interactCtx()) {
                leftDown = false
                player?.breakingProgress = -1
                return
            }
            leftDown = true
            if isLANClientWorld {
                performLANClientAttackOrMine()
            } else {
                doAttack()
            }
        } else if button == 1 {
            pickBlock()
        } else if button == 2 {
            rightDown = true
            if isLANClientWorld {
                _ = performLANClientUse()
            } else {
                doUse()
                useCooldown = 4
            }
        }
    }

    public func mouseUp(_ button: Int) {
        if button == 0 { leftDown = false }
        if button == 2 {
            rightDown = false
            if player?.usingItem == true { releaseUsingItem(interactCtx()) }
        }
    }

    public func mouseDelta(_ dx: Double, _ dy: Double) {
        guard inWorld, !(host?.hasScreen() ?? false), let p = player else { return }
        let sens = 0.0008 + settings.sensitivity * 0.004
        p.yaw += dx * sens
        p.pitch += dy * sens * (settings.invertY ? -1 : 1)
        p.pitch = clampD(p.pitch, -Double.pi / 2 + 0.001, Double.pi / 2 - 0.001)
    }

    public func wheelHotbar(_ dir: Int) {
        guard inWorld, let p = player else { return }
        if rotateTemplatePlacement(by: dir) { return }
        p.selectedSlot = posMod(p.selectedSlot + dir, 9)
    }

    /// world-mode keydown (app already routed screen input elsewhere).
    /// `now` is a monotonic millisecond clock for double-tap detection.
    public func keyDown(_ code: String, now: Double, ctrlOrCmd: Bool = false) {
        guard inWorld else { return }
        keys.insert(code)
        let p = player!
        if code == "Escape" {
            if let job = templatePlacementJob {
                let progress = job.progress
                host?.showActionBar("Placing \"\(progress.templateName)\" \(progress.percent)% - \(progress.phase)", 45)
                return
            }
            if templatePlacement != nil {
                cancelTemplatePlacement()
                return
            }
            host?.openPauseScreen()
            host?.releasePointer()
        } else if code == keybinds["perspective"] {
            perspective = (perspective + 1) % 3
        } else if code == keybinds["inventory"] {
            if p.gameMode == GameMode.creative {
                host?.openScreen("creative", nil)
            } else {
                host?.openScreen("inventory", nil)
            }
        } else if code == keybinds["chat"] {
            host?.openChat("")
        } else if code == keybinds["command"] {
            host?.openChat("/")
        } else if code == "KeyK" {
            host?.openScreen("rpg", nil)
            host?.releasePointer()
        } else if code == "KeyO" {
            let message = requestRPGCyclePreparedAction()
            host?.showActionBar(message, 45)
        } else if code == "KeyL" {
            let message = requestRPGUseSelectedAction()
            host?.showActionBar(message, 70)
        } else if code == keybinds["drop"] {
            if isLANClientWorld {
                performLANClientToss(all: ctrlOrCmd)
            } else {
                p.dropSelected(ctrlOrCmd)
            }
        } else if code == keybinds["swapOffhand"] {
            let tmp = p.offHand
            p.offHand = p.mainHand
            p.mainHand = tmp
        } else {
            // hotbar digits
            if code.hasPrefix("Digit"), code.count == 6, let n = Int(code.suffix(1)), n >= 1, n <= 9 {
                if keys.contains("ShiftLeft") {
                    let message = requestRPGUseActionQuickSlot(n - 1)
                    host?.showActionBar(message, 70)
                    return
                }
                p.selectedSlot = n - 1
            }
            // double-space enables creative flight
            if code == keybinds["jump"] {
                _ = p.creativeJumpPressed(now: now)
            }
            if code == keybinds["sprint"] { sprintHeld = true }
        }
        // double-tap forward → sprint
        if code == keybinds["forward"] {
            if now - lastForwardPress < 250 { sprintHeld = true }
            lastForwardPress = now
        }
    }

    public func keyUp(_ code: String) {
        keys.remove(code)
        if code == keybinds["sprint"] { sprintHeld = player?.sprinting ?? false }
    }

    public func loadedMapBounds() -> MapBlockBounds? {
        mapBoundsForLoadedChunks(world.chunks.values.map { (cx: $0.cx, cz: $0.cz) })
    }

    public func zoomMap(_ zoomIn: Bool) {
        mapSpanBlocks = mapZoomedSpan(current: mapSpanBlocks, zoomIn: zoomIn, bounds: loadedMapBounds())
    }

    public func cycleMinimapSize(larger: Bool) {
        mapMinimapSizeMode = cycledMapMinimapSizeMode(mapMinimapSizeMode, larger: larger)
    }

    public func resetExpandedMapCenterToPlayer() {
        guard let player else { return }
        let view = mapViewportCenteredOnPlayer(playerX: player.x, playerZ: player.z,
                                              span: mapSpanBlocks, bounds: loadedMapBounds())
        expandedMapCenterX = view.centerX
        expandedMapCenterZ = view.centerZ
        mapSpanBlocks = view.spanBlocks
    }

    public func expandedMapViewport() -> MapViewport {
        clampedMapViewport(MapViewport(centerX: expandedMapCenterX, centerZ: expandedMapCenterZ,
                                       spanBlocks: mapSpanBlocks),
                           bounds: loadedMapBounds())
    }

    public func setExpandedMapViewport(_ viewport: MapViewport) {
        let clamped = clampedMapViewport(viewport, bounds: loadedMapBounds())
        expandedMapCenterX = clamped.centerX
        expandedMapCenterZ = clamped.centerZ
        mapSpanBlocks = clamped.spanBlocks
    }

    /// window blur / screen opened — release all held input
    public func clearInput() {
        keys.removeAll()
        leftDown = false
        rightDown = false
    }

    // ===========================================================================
    // Frame pump — the app's render loop calls this once per frame
    // ===========================================================================
    /// Runs fixed-step sim ticks, then the budgeted light/mesh streamers.
    /// Returns the interpolation partial for rendering.
    public func frame(dtMs: Double) -> Double {
        guard inWorld else { return 0 }
        accumulator += min(dtMs, 250)
        var steps = 0
        while accumulator >= TICK_MS && steps < 10 {
            LoadProf.shared.time("tick") { tick() }
            accumulator -= TICK_MS
            steps += 1
        }
        if steps >= 10 { accumulator = 0 }
        LoadProf.shared.time("lightQ") { processLightQueue() }
        LoadProf.shared.time("streamMesh") { streamMeshes() }
        LoadProf.shared.tickPrint()
        return paused ? 1 : clampD(accumulator / TICK_MS, 0, 1)
    }

    /// interpolated camera (view bobbing, third person, effect overlays)
    public func camState(_ partial: Double, timeSec: Double) -> CamState {
        let p = player!
        let w = world
        let ix = p.prevX + (p.x - p.prevX) * partial
        let iy = p.prevY + (p.y - p.prevY) * partial
        let iz = p.prevZ + (p.z - p.prevZ) * partial
        var eyeY = iy + (p.sneaking ? 1.27 : PLAYER_EYE)
        var cx = ix, cz = iz
        // view bobbing — phase/amp advance in tickViewBob (20Hz), interpolate here
        if settings.viewBobbing && p.vehicle == nil {
            let bp = prevBobPhase + (bobPhase - prevBobPhase) * partial
            let ba = prevBobAmp + (bobAmp - prevBobAmp) * partial
            let bob = cameraBobOffset(phase: bp, amplitude: ba, yaw: p.yaw)
            eyeY += bob.y
            cx += bob.x
            cz += bob.z
        }
        var yaw = p.yaw, pitch = p.pitch
        if perspective == 2 {
            yaw += .pi
            pitch = -pitch
        }
        // third person: pull camera back along the view ray, clipped by blocks
        if perspective > 0 {
            let back = 4.0
            let dx = detSin(yaw) * detCos(pitch)
            let dy = detSin(pitch)
            let dz = -detCos(yaw) * detCos(pitch)
            let hit = w.raycast(cx, eyeY, cz, dx, dy, dz, back)
            let dist = hit.map { max(0.2, $0.t - 0.25) } ?? back
            cx += dx * dist
            eyeY += dy * dist
            cz += dz * dist
        }
        let eyeBlock = w.getBlock(ifloor(cx), ifloor(eyeY), ifloor(cz))
        let eyeId = eyeBlock >> 4
        var cam = CamState()
        cam.x = cx; cam.y = eyeY; cam.z = cz
        cam.yaw = yaw; cam.pitch = pitch
        cam.fov = Double(settings.fov) * (prevFovScale + (fovScale - prevFovScale) * partial)
        cam.underwater = isWaterlogged(UInt16(eyeBlock))
        cam.underLava = eyeId == Int(B.lava)
        cam.powderSnow = eyeId == Int(B.powder_snow)
        cam.portalWarp = portalWarp
        cam.nightVision = p.hasEffect("night_vision") ? 1 : 0
        cam.darkness = p.hasEffect("darkness") ? (0.6 + 0.4 * detSin(timeSec * 2)) * settings.darknessPulse : 0
        cam.blindness = p.hasEffect("blindness") ? 1 : 0
        return cam
    }
}

// ---- death messages -------------------------------------------------------------
/// "wither_skeleton" → "Wither Skeleton"
public func prettyEntityName(_ type: String) -> String {
    type.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

/// vanilla 1.20 death-message grammar, with attacker names and the
/// "whilst trying to escape" variants for environmental deaths
public func deathCauseText(_ source: String?, _ attacker: String? = nil) -> String {
    if let a = attacker {
        switch source {
        case "mob", "player": return "was slain by \(a)"
        case "arrow": return "was shot by \(a)"
        case "explosion": return "was blown up by \(a)"
        case "magic": return "was killed by \(a) using magic"
        case "sonic": return "was sonically charged by \(a)"
        case "wither": return "withered away whilst fighting \(a)"
        case "fall": return "hit the ground too hard whilst trying to escape \(a)"
        case "fall_high": return "fell from a high place whilst trying to escape \(a)"
        case "lava": return "tried to swim in lava to escape \(a)"
        case "fire": return "was burned to a crisp whilst fighting \(a)"
        case "drown": return "drowned whilst trying to escape \(a)"
        case "freeze": return "was frozen to death by \(a)"
        case "cactus": return "walked into a cactus whilst trying to escape \(a)"
        default: break
        }
    }
    switch source {
    case "void": return "fell out of the world"
    case "fall": return "hit the ground too hard"
    case "fall_high": return "fell from a high place"
    case "lava": return "tried to swim in lava"
    case "fire": return "went up in flames"
    case "fire_tick": return "burned to death"
    case "drown": return "drowned"
    case "starve": return "starved to death"
    case "explosion": return "blew up"
    case "magic": return "was killed by magic"
    case "arrow": return "was shot"
    case "wither": return "withered away"
    case "freeze": return "froze to death"
    case "lightning": return "was struck by lightning"
    case "sonic": return "was sonically charged"
    case "fly_into_wall": return "experienced kinetic energy"
    case "cactus": return "was pricked to death"
    case "sweet_berry": return "was poked to death by a sweet berry bush"
    case "anvil": return "was squashed by a falling anvil"
    case "falling_block": return "was squashed by a falling block"
    case "stalagmite": return "was impaled on a stalagmite"
    case "suffocate": return "suffocated in a wall"
    case "mob", "player": return "was slain"
    default: return "died"
    }
}

// ---- small math helpers -------------------------------------------------------
func wrapAngle(_ a: Double) -> Double {
    var a = a
    while a > .pi { a -= .pi * 2 }
    while a < -.pi { a += .pi * 2 }
    return a
}

func rayBoxT(_ ox: Double, _ oy: Double, _ oz: Double,
             _ dx: Double, _ dy: Double, _ dz: Double,
             _ x0: Double, _ y0: Double, _ z0: Double,
             _ x1: Double, _ y1: Double, _ z1: Double) -> Double? {
    var tmin = 0.0, tmax = Double.infinity
    let axes: [(Double, Double, Double, Double)] = [(ox, dx, x0, x1), (oy, dy, y0, y1), (oz, dz, z0, z1)]
    for (o, d, lo, hi) in axes {
        if abs(d) < 1e-9 {
            if o < lo || o > hi { return nil }
        } else {
            var t1 = (lo - o) / d, t2 = (hi - o) / d
            if t1 > t2 { swap(&t1, &t2) }
            tmin = max(tmin, t1)
            tmax = min(tmax, t2)
            if tmin > tmax { return nil }
        }
    }
    return tmin
}

/// deterministic ToInt32 (the `| 0` coercion) for seed-text parity with the golden baselines
func wrapToInt32(_ d: Double) -> Int32 {
    if !d.isFinite { return 0 }
    let m = d.truncatingRemainder(dividingBy: 4294967296)
    let u = UInt32(truncatingIfNeeded: Int64(m))
    return Int32(bitPattern: u)
}
