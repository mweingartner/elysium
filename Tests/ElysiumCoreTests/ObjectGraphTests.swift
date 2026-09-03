// ObjectGraphTests.swift — object-graph-attributes (change 1a). Spec
// `object-graph-refs` "Liveness and resolution", "Deterministic nearby
// enumeration", plus Security (plan) note D4 (entity/block tie-break).

import XCTest
@testable import ElysiumCore

/// A minimal `ObjectGraphHost` test double — no `GameCore` required.
final class FakeObjectGraphHost: ObjectGraphHost {
    var currentDimension: Dim = .overworld
    var worldsByDim: [Dim: World] = [:]
    var localPlayer: Player?
    var isLANClient = false
    var currentTick: Int64 = 0
    var scriptsEnabled = true
    var worldRecords: [String: ObjectRecord] = [:]
    var gameRules: [String: Double] = [:]
    var difficultyWrites: [Int] = []
    var gameRuleWrites: [(String, Double)] = []
    var scriptDefinitionGeneration: UInt64 = 0
    var scriptDefinitionChanges = ScriptDefinitionChangeIndex()
    var availableScriptSounds: [String] = []
    var playedScriptSounds: [(name: String, volume: Double, owner: ObjectRef)] = []

    func world(for dim: Dim) -> World? { worldsByDim[dim] }

    func worldObjectRecord(for ref: ObjectRef) -> ObjectRecord { worldRecords[ref.canonical] ?? ObjectRecord() }
    func setWorldObjectRecord(_ record: ObjectRecord, for ref: ObjectRef) {
        if record.isEmpty { worldRecords.removeValue(forKey: ref.canonical) } else { worldRecords[ref.canonical] = record }
    }
    func setDifficulty(_ d: Int) { difficultyWrites.append(d) }
    func setGameRule(_ name: String, _ value: Double) { gameRuleWrites.append((name, value)) }
    func scriptDefinitionsDidChange(for ref: ObjectRef, hasScripts: Bool) {
        scriptDefinitionGeneration &+= 1
        scriptDefinitionChanges.record(ref, hasScripts: hasScripts)
    }
    func drainDirtyScriptDefinitionRefs(limit: Int) -> [ObjectRef] {
        scriptDefinitionChanges.drain(limit: limit)
    }
    func scriptSoundNames() -> [String] { availableScriptSounds }
    func playScriptSound(named name: String, volume: Double, owner: ObjectRef) -> Bool {
        guard availableScriptSounds.contains(name) else { return false }
        playedScriptSounds.append((name, volume, owner))
        return true
    }
}

final class ObjectGraphTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
    }

    private func makeLoadedWorld(_ dim: Dim = .overworld) -> World {
        let world = World(dim: dim, seed: 7)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }

    func testWorldPublishesScriptDefinitionHydrationAndUnloadForEntitiesAndChunks() {
        let world = World(dim: .overworld, seed: 7)
        let scriptRecord = ObjectRecord(
            entries: [
                "persisted": .script(ScriptRecord(
                    name: "persisted", source: "", enabled: true, mode: .module,
                    author: .player, createdTick: 0
                )),
            ],
            revision: 1
        )
        var hydrated: [ObjectRef] = []
        var unloaded: [ObjectRef] = []
        world.hooks.onScriptObjectHydrated = { ref, record in
            XCTAssertTrue(record.hasScriptDefinitions)
            hydrated.append(ref)
        }
        world.hooks.onScriptObjectUnloaded = { unloaded.append($0) }

        let cow = Cow(world: world)
        cow.objectRecord = scriptRecord
        let entityRef = ObjectRef.entity(uid: cow.id)
        world.addEntity(cow)

        let chunk = Chunk(cx: 2, cz: -1, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        let cellIndex = chunk.index(3, 64, 4)
        chunk.objectRecords[cellIndex] = scriptRecord
        let blockRef = ObjectRef.block(dim: .overworld, x: 35, y: 64, z: -12)
        world.setChunk(chunk)

        XCTAssertEqual(hydrated, [entityRef, blockRef])

        world.removeEntity(cow)
        world.removeChunk(chunk.cx, chunk.cz)
        XCTAssertEqual(unloaded, [entityRef, blockRef])
    }

    // MARK: - liveness

    func testWorldAndCurrentDimensionAreLiveWhileOpen() {
        let host = FakeObjectGraphHost()
        let world = makeLoadedWorld()
        host.worldsByDim[.overworld] = world
        let graph = ObjectGraph(host: host)
        guard case .live(.world) = graph.resolve(.world) else { return XCTFail("expected .live(.world)") }
        guard case .live(.dimension) = graph.resolve(.dimension(.overworld)) else {
            return XCTFail("expected .live(.dimension)")
        }
    }

    func testWorldIsUnknownWhenNoneOpen() {
        let host = FakeObjectGraphHost()
        let graph = ObjectGraph(host: host)
        guard case .unknown = graph.resolve(.world) else { return XCTFail("expected .unknown") }
    }

    func testDormantDimension() {
        let host = FakeObjectGraphHost()
        host.worldsByDim[.overworld] = makeLoadedWorld(.overworld)
        host.worldsByDim[.nether] = makeLoadedWorld(.nether)
        let graph = ObjectGraph(host: host)
        guard case .dormant = graph.resolve(.dimension(.nether)) else { return XCTFail("expected .dormant") }
        guard case .dormant = graph.resolve(.block(dim: .nether, x: 1, y: 2, z: 3)) else {
            return XCTFail("expected .dormant for a block in a dormant dimension")
        }
    }

    func testUnloadedChunkAndDeadEntity() {
        let host = FakeObjectGraphHost()
        let world = makeLoadedWorld()
        host.worldsByDim[.overworld] = world
        let graph = ObjectGraph(host: host)
        guard case .notLoaded = graph.resolve(.block(dim: .overworld, x: 100_000, y: 64, z: 100_000)) else {
            return XCTFail("expected .notLoaded")
        }
        guard case .unknown = graph.resolve(.entity(uid: 999_999)) else { return XCTFail("expected .unknown") }
    }

    func testDeadLivingEntityIsUnknown() {
        let host = FakeObjectGraphHost()
        let world = makeLoadedWorld()
        host.worldsByDim[.overworld] = world
        let cow = Cow(world: world)
        world.addEntity(cow)
        cow.remove()
        let graph = ObjectGraph(host: host)
        guard case .unknown = graph.resolve(.entity(uid: cow.id)) else { return XCTFail("expected .unknown") }
    }

    func testPlayerRefResolvesTheLocalPlayer() {
        let host = FakeObjectGraphHost()
        let world = makeLoadedWorld()
        host.worldsByDim[.overworld] = world
        let player = Player(world: world)
        world.addEntity(player)
        host.localPlayer = player
        let graph = ObjectGraph(host: host)
        guard case .live(.player(let p, _)) = graph.resolve(.player) else { return XCTFail("expected .live(.player)") }
        XCTAssertTrue(p === player)
    }

    /// Security (code) SC-1 / Test DEF-2 — `specs/object-graph-refs/spec.md`'s "Player
    /// objects in the entity index" scenario and design.md Decision 2:
    /// `entity:<uid of the local player>` SHALL resolve to the canonical `player` object
    /// (never a bare `.entity`, since the player's id is re-minted every `enterWorld` and
    /// never adopted — a stored `entity:<playerUid>` ref would dangle next session); a real
    /// non-player entity resolves `.entity` exactly as before; a `LANRemotePlayerEntity`
    /// (the host-side mirror of a guest's own player, added to `world.entityById` the same
    /// way the local player is) resolves `.unsupported`, not as a plain writable entity.
    func testEntityRefResolvesTheLocalPlayerAsPlayerAndFlagsLANRemotePlayers() {
        let host = FakeObjectGraphHost()
        let world = makeLoadedWorld()
        host.worldsByDim[.overworld] = world
        let player = Player(world: world)
        world.addEntity(player)
        host.localPlayer = player
        let cow = Cow(world: world)
        world.addEntity(cow)
        let remote = LANRemotePlayerEntity(world: world, state: LANPlayerState(
            playerID: "peer-a", displayName: "Guest", x: 0, y: 64, z: 0, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        ))
        world.addEntity(remote)
        let graph = ObjectGraph(host: host)

        // The local player's own uid resolves through entity:<uid> to `player`, not `.entity`.
        guard case .live(.player(let resolvedPlayer, _)) = graph.resolve(.entity(uid: player.id)) else {
            return XCTFail("expected the local player's entity:<uid> to resolve to the player object")
        }
        XCTAssertTrue(resolvedPlayer === player)

        // A real, non-player entity still resolves .entity exactly as before.
        guard case .live(.entity(let e2, _)) = graph.resolve(.entity(uid: cow.id)) else {
            return XCTFail("expected another entity to resolve via entity:<uid>")
        }
        XCTAssertTrue(e2 === cow)

        // A LANRemotePlayerEntity's uid resolves .unsupported, not as a plain entity.
        guard case .unsupported = graph.resolve(.entity(uid: remote.id)) else {
            return XCTFail("expected a LANRemotePlayerEntity to resolve .unsupported")
        }
        XCTAssertEqual(scriptRef(for: player), .player)
        XCTAssertEqual(scriptRef(for: cow), .entity(uid: cow.id))
        XCTAssertEqual(
            scriptRef(for: remote),
            .lanPlayer(peerID: remote.multiplayerPlayerID),
            "engine events and script discovery must never expose a LAN player as entity:<uid>"
        )
    }

    /// The same scenario's `objectsNear` half: the local player, when in range, is listed
    /// as `player` (canonical ref `player`), never `entity:<n>`, and a `LANRemotePlayerEntity`
    /// appears exactly once under its canonical `player:lan:<peerID>` ref.
    func testObjectsNearUsesCanonicalLocalAndLANPlayerRefs() {
        let host = FakeObjectGraphHost()
        let world = makeLoadedWorld()
        host.worldsByDim[.overworld] = world
        let player = Player(world: world)
        player.setPos(1, 64, 0)
        world.addEntity(player)
        host.localPlayer = player
        let cow = Cow(world: world)
        cow.setPos(2, 64, 0)
        world.addEntity(cow)
        let remote = LANRemotePlayerEntity(world: world, state: LANPlayerState(
            playerID: "peer-a", displayName: "Guest", x: 3, y: 64, z: 0, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue
        ))
        remote.setPos(3, 64, 0)
        world.addEntity(remote)
        let graph = ObjectGraph(host: host)

        let entries = graph.objectsNear(x: 0, y: 64, z: 0, radius: 16, limit: 32)
        XCTAssertTrue(entries.contains { $0.ref == .player }, "the local player must be listed as .player")
        XCTAssertFalse(entries.contains { $0.ref == .entity(uid: player.id) }, "the local player must never be listed as .entity")
        XCTAssertFalse(entries.contains { $0.ref == .entity(uid: remote.id) }, "a LANRemotePlayerEntity must never appear")
        XCTAssertEqual(
            entries.filter { $0.ref == .lanPlayer(peerID: "peer-a") }.count,
            1,
            "a host must expose one stable LAN player traversal key"
        )
        XCTAssertTrue(entries.contains { $0.ref == .entity(uid: cow.id) }, "an ordinary entity is unaffected")
    }

    func testUnsupportedLANPlayerRef() {
        let host = FakeObjectGraphHost()
        let graph = ObjectGraph(host: host)
        guard case .unsupported = graph.resolve(.lanPlayer(peerID: "guest1")) else { return XCTFail("expected .unsupported") }
    }

    // MARK: - deterministic nearby enumeration

    func testObjectsNearOrderIsStableAcrossTwoFreshGraphs() {
        func build() -> ObjectGraph {
            // Simulates "two separate processes" (spec) — each starts the
            // entity id sequence fresh, exactly like a real process would.
            resetEntityIds(1)
            let host = FakeObjectGraphHost()
            let world = makeLoadedWorld()
            host.worldsByDim[.overworld] = world
            for (uid, x) in [(5, 1.0), (2, 1.0), (9, 1.0)] {
                let cow = Cow(world: world)
                _ = uid
                cow.setPos(x, 64, 0)
                world.addEntity(cow)
            }
            let chunk = world.getChunk(0, 0)!
            chunk.objectRecords[chunk.index(3, 64, 0)] = ObjectRecord(
                entries: ["mood": .value(.string("happy"), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 0))]
            )
            return ObjectGraph(host: host)
        }
        let a = build().objectsNear(x: 0, y: 64, z: 0, radius: 16, limit: 32)
        let b = build().objectsNear(x: 0, y: 64, z: 0, radius: 16, limit: 32)
        XCTAssertEqual(a.map(\.ref.canonical), b.map(\.ref.canonical))
        XCTAssertFalse(a.isEmpty)
    }

    func testEntityAndBlockAtEqualDistanceEntityFirst() {
        // Security (plan) note D4: at an exact tie, entities sort before blocks.
        func build() -> ObjectGraph {
            let host = FakeObjectGraphHost()
            let world = makeLoadedWorld()
            host.worldsByDim[.overworld] = world
            let chunk = world.getChunk(0, 0)!
            let cellIndex = chunk.index(2, 64, 2)
            chunk.objectRecords[cellIndex] = ObjectRecord(
                entries: ["mood": .value(.string("happy"), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 0))]
            )
            let cow = Cow(world: world)
            cow.setPos(2.5, 64.5, 2.5) // block center — exact distance tie with the block above
            world.addEntity(cow)
            return ObjectGraph(host: host)
        }
        for _ in 0..<2 {
            let entries = build().objectsNear(x: 2.5, y: 64.5, z: 2.5, radius: 8, limit: 8)
            XCTAssertGreaterThanOrEqual(entries.count, 2)
            XCTAssertEqual(entries.first?.ref.kind, .entity, "entity should sort before the block at an exact tie")
        }
    }

    func testRadiusAndLimitAreClamped() {
        let host = FakeObjectGraphHost()
        let world = makeLoadedWorld()
        host.worldsByDim[.overworld] = world
        for i in 0..<80 {
            let cow = Cow(world: world)
            cow.setPos(Double(i % 8), 64, 0)
            world.addEntity(cow)
        }
        let graph = ObjectGraph(host: host)
        let entries = graph.objectsNear(x: 0, y: 64, z: 0, radius: 1000, limit: 1000)
        XCTAssertLessThanOrEqual(entries.count, 64)
    }

    func testDisplayNameForBlockAndEntity() {
        let host = FakeObjectGraphHost()
        let world = makeLoadedWorld()
        host.worldsByDim[.overworld] = world
        _ = world.setBlock(1, 64, 1, Int(cell(B.stone)))
        let graph = ObjectGraph(host: host)
        XCTAssertEqual(graph.displayName(of: .block(dim: .overworld, x: 1, y: 64, z: 1)), blockDefs[Int(B.stone)].displayName)
        XCTAssertEqual(graph.displayName(of: .world), "World")
        XCTAssertEqual(graph.displayName(of: .dimension(.nether)), "Nether")
    }
}
