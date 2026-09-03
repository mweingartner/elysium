// ObjectGraph.swift — object-graph-attributes (change 1a). design.md Decision 2 /
// spec `object-graph-refs`. Resolves `ObjectRef`s to live game objects without
// owning any state itself — a small value type over the `ObjectGraphHost`
// protocol `GameCore` implements (`GameCore+Scripting.swift`) and tests fake.
// Resolution is side-effect-free and never loads a chunk.

import Foundation

/// What `ObjectGraph` needs from the running game to resolve refs and enumerate
/// nearby objects. Implemented by `GameCore` (`Scripting/GameCore+Scripting.swift`)
/// and by test fakes.
public protocol ObjectGraphHost: AnyObject {
    /// The dimension the local player is currently in. Only `world`/`dim:<this>`
    /// and blocks/entities within it are ever live.
    var currentDimension: Dim { get }
    /// The `World` for `dim`, if a world is open (all three dimensions' worlds
    /// exist together whenever one does — only `currentDimension` counts as live).
    func world(for dim: Dim) -> World?
    /// The local player, if any. Named `localPlayer` (not `player`) because
    /// `GameCore`'s own `player: Player!` stored property already occupies
    /// that name with a different (IUO) type.
    var localPlayer: Player? { get }
    /// The persisted record for a `.world` or `.dimension` ref (Decision 9's
    /// world + three-dimension bags) — never called with any other ref kind.
    func worldObjectRecord(for ref: ObjectRef) -> ObjectRecord
    func setWorldObjectRecord(_ record: ObjectRecord, for ref: ObjectRef)
    /// Whether this is a transient LAN client (guest) world.
    var isLANClient: Bool { get }
    /// The current tick, for provenance (`Provenance.createdTick`). Named
    /// `currentTick` (not `tick`) because `GameCore` already has a private
    /// `tick()` simulation method with that name.
    var currentTick: Int64 { get }
    /// `WorldRecord.scriptsEnabled` — the persisted half of the 1c trust gate,
    /// surfaced read-only as the `world.scripts_enabled` built-in.
    var scriptsEnabled: Bool { get }
    /// `world.difficulty` (getSet, Decision 7) — world-global, so it must go
    /// through `GameCore.setDifficulty` (keeps every dimension and the world
    /// record in sync) rather than a direct `World` field write.
    func setDifficulty(_ d: Int)
    /// `world.gamerule.<name>` (getSet, existing rules only, Decision 7) —
    /// same reasoning: `GameCore.setGameRule` is world-global.
    func setGameRule(_ name: String, _ value: Double)
    /// Authoritative built-in mutation seam. GameCore records event provenance and updates its
    /// observable baseline around the same engine setter; lightweight test hosts may use the
    /// default implementation when they do not own an EventBus.
    func setScriptBuiltInAttribute(
        _ live: LiveObject, ref: ObjectRef, name: String, value: AttrValue,
        author: Provenance.Author
    ) -> BuiltInSetOutcome
    /// Commits one cell from an already-complete, non-fallible `block:setBlock` plan. GameCore
    /// scopes the synchronous world hooks to `author`; the default keeps lightweight hosts simple.
    func commitPrevalidatedScriptBlockCell(
        _ world: World, x: Int, y: Int, z: Int, cell: Int,
        author: Provenance.Author
    )
    /// Monotonic session-local definition generation. Every mutation/hydration/unload notification
    /// advances it, while the bounded dirty-ref queue carries the exact work that generation names.
    var scriptDefinitionGeneration: UInt64 { get }
    func scriptDefinitionsDidChange(for ref: ObjectRef, hasScripts: Bool)
    /// Removes at most `limit` canonically ordered dirty refs. Implementations retain every suffix
    /// entry for a later phase; the runtime never needs to census the live world.
    func drainDirtyScriptDefinitionRefs(limit: Int) -> [ObjectRef]
    /// Canonical, currently playable names exposed to sandboxed scripts. The app owns discovery
    /// and imported-file storage; Core receives names only and never grants Lua filesystem access.
    func scriptSoundNames() -> [String]
    /// Plays one already-resolved catalog sound for `owner`. Implementations choose the spatial
    /// origin from the live object and return false when playback could not start.
    func playScriptSound(named name: String, volume: Double, owner: ObjectRef) -> Bool
    /// lan-client-parity (change 4): the live `LANRemotePlayerEntity` for a
    /// connected guest, if the host currently mirrors one *in the current
    /// dimension* — `nil` when the peer isn't connected, or is connected but
    /// currently in a different dimension (matches every other kind's
    /// "objects in inactive dimensions are dormant" rule: no ghost entity is
    /// ever materialized outside the host's current dimension, so there is
    /// nothing live to resolve there either). `GameCore`'s own default
    /// implementation is `nil` when `isLANClient` (a guest never resolves
    /// another guest's `player:lan:*` object — only the host does).
    func lanRemotePlayer(peerID: String) -> (entity: LANRemotePlayerEntity, world: World)?
}

extension ObjectGraphHost {
    /// Default: no LAN peers. Test fakes and `elysmoke`'s script host never
    /// mirror a LAN peer, so they get this for free instead of each having
    /// to implement a method they'd only ever return `nil` from.
    public func lanRemotePlayer(peerID: String) -> (entity: LANRemotePlayerEntity, world: World)? { nil }

    public func setScriptBuiltInAttribute(
        _ live: LiveObject, ref _: ObjectRef, name: String, value: AttrValue,
        author _: Provenance.Author
    ) -> BuiltInSetOutcome {
        BuiltInAttributes.set(live, name: name, value: value, host: self)
    }

    public func commitPrevalidatedScriptBlockCell(
        _ world: World, x: Int, y: Int, z: Int, cell: Int,
        author _: Provenance.Author
    ) {
        world.setBlock(x, y, z, cell, SET_DEFAULT)
    }

    public var scriptDefinitionGeneration: UInt64 { 0 }
    public func scriptDefinitionsDidChange(for _: ObjectRef, hasScripts _: Bool) {}
    public func drainDirtyScriptDefinitionRefs(limit _: Int) -> [ObjectRef] { [] }
    public func scriptSoundNames() -> [String] { [] }
    public func playScriptSound(named _: String, volume _: Double, owner _: ObjectRef) -> Bool { false }
}

/// A deterministic deduplicating min-heap used for bounded script-definition work. Canonical UTF-8
/// order makes continuation independent of Dictionary/Set hashing and insertion order.
struct DeterministicStringWorkQueue {
    private var heap: [String] = []
    private var members = Set<String>()

    var count: Int { heap.count }
    var isEmpty: Bool { heap.isEmpty }

    mutating func removeAll(keepingCapacity: Bool = false) {
        heap.removeAll(keepingCapacity: keepingCapacity)
        members.removeAll(keepingCapacity: keepingCapacity)
    }

    mutating func insert(_ value: String) {
        guard members.insert(value).inserted else { return }
        heap.append(value)
        var child = heap.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard utf8Less(heap[child], heap[parent]) else { break }
            heap.swapAt(child, parent)
            child = parent
        }
    }

    mutating func popFirst() -> String? {
        guard !heap.isEmpty else { return nil }
        let first = heap[0]
        members.remove(first)
        if heap.count == 1 {
            heap.removeLast()
            return first
        }
        heap[0] = heap.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < heap.count else { break }
            let right = left + 1
            var child = left
            if right < heap.count, utf8Less(heap[right], heap[left]) { child = right }
            guard utf8Less(heap[child], heap[parent]) else { break }
            heap.swapAt(parent, child)
            parent = child
        }
        return first
    }
}

/// Host-owned live-definition index plus its bounded deterministic dirty queue. `hasScripts`
/// updates the index eagerly; the runtime still re-reads the live record when it drains a ref, so a
/// rapid remove/recreate sequence collapses safely to the latest authoritative definition.
public struct ScriptDefinitionChangeIndex {
    private var scriptedRefs = Set<String>()
    private var dirtyRefs = DeterministicStringWorkQueue()

    public init() {}

    public var scriptedRefCount: Int { scriptedRefs.count }
    public var pendingRefCount: Int { dirtyRefs.count }

    public mutating func reset() {
        scriptedRefs.removeAll(keepingCapacity: false)
        dirtyRefs.removeAll(keepingCapacity: false)
    }

    public mutating func record(_ ref: ObjectRef, hasScripts: Bool) {
        let canonical = ref.canonical
        if hasScripts { scriptedRefs.insert(canonical) }
        else { scriptedRefs.remove(canonical) }
        dirtyRefs.insert(canonical)
    }

    public mutating func drain(limit: Int) -> [ObjectRef] {
        guard limit > 0 else { return [] }
        var result: [ObjectRef] = []
        result.reserveCapacity(min(limit, dirtyRefs.count))
        while result.count < limit, let canonical = dirtyRefs.popFirst() {
            if let ref = ObjectRef.parse(canonical) { result.append(ref) }
        }
        return result
    }
}

/// The outcome of resolving an `ObjectRef`.
public enum ObjectResolution {
    /// The ref names a live object right now.
    case live(LiveObject)
    /// The ref names a real dimension/block that exists but is not the current
    /// dimension (spec: "dormant" — distinct from "unknown").
    case dormant
    /// The ref names a block in the current dimension whose chunk is not loaded.
    case notLoaded
    /// The ref names nothing that currently exists (dead/never-existed entity,
    /// no world open, out-of-range block already rejected at parse time).
    case unknown
    /// The ref's kind is recognized but not resolvable in this change
    /// (`player:lan:*` — phase 3/4).
    case unsupported
}

/// A live object's owner(s), carried by reference so a caller (`AttributeStore`,
/// `ScriptingCommands`) can read or mutate its `ObjectRecord`/fields directly
/// without re-resolving.
public enum LiveObject {
    case world
    case dimension(World)
    case block(world: World, chunk: Chunk, cellIndex: Int, x: Int, y: Int, z: Int)
    case entity(Entity, World)
    case player(Player, World)
}

/// Canonical family name used by subscription `type=` filters and event `subjectType` metadata.
/// Keep this beside `LiveObject` so custom-attribute, observable-built-in, position, command, AI,
/// and Lua funnels can share the exact same block/entity/player/dimension spelling.
public func scriptSubjectType(for live: LiveObject) -> String {
    switch live {
    case .world:
        return "world"
    case .dimension(let world):
        return dimCanonicalName(world.dim)
    case .block(_, let chunk, _, let x, let y, let z):
        let cell = Int(chunk.get(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)))
        let id = cell >> 4
        return id >= 0 && id < blockDefs.count ? blockDefs[id].name : "block"
    case .entity(let entity, _):
        return entity.type
    case .player:
        return "player"
    }
}

/// One entry in a deterministic nearby-objects listing (`objectsNear`).
public struct NearbyObjectEntry {
    public let ref: ObjectRef
    public let liveObject: LiveObject
    public let distanceSq: Double
}

/// Resolves `ObjectRef`s against a `ObjectGraphHost` and enumerates nearby
/// objects deterministically. Carries no state of its own.
public struct ObjectGraph {
    public let host: ObjectGraphHost

    public init(host: ObjectGraphHost) {
        self.host = host
    }

    private var isWorldOpen: Bool {
        host.world(for: host.currentDimension) != nil
    }

    /// Resolves `ref` to a live object, dormant/not-loaded/unknown classification,
    /// or unsupported. Side-effect-free: never loads a chunk, never creates
    /// anything.
    public func resolve(_ ref: ObjectRef) -> ObjectResolution {
        switch ref {
        case .world:
            return isWorldOpen ? .live(.world) : .unknown

        case .dimension(let d):
            guard isWorldOpen else { return .unknown }
            guard d == host.currentDimension else { return .dormant }
            guard let w = host.world(for: d) else { return .unknown }
            return .live(.dimension(w))

        case .block(let d, let x, let y, let z):
            guard isWorldOpen else { return .unknown }
            guard d == host.currentDimension else { return .dormant }
            guard let w = host.world(for: d) else { return .unknown }
            let info = dimInfo(d)
            guard y >= info.minY, y < info.minY + info.height else { return .unknown }
            let cx = floorDiv(x, CHUNK_W), cz = floorDiv(z, CHUNK_W)
            guard let chunk = w.getChunk(cx, cz) else { return .notLoaded }
            let lx = posMod(x, CHUNK_W), lz = posMod(z, CHUNK_W)
            let cellIndex = chunk.index(lx, y, lz)
            return .live(.block(world: w, chunk: chunk, cellIndex: cellIndex, x: x, y: y, z: z))

        case .entity(let uid):
            guard isWorldOpen, let w = host.world(for: host.currentDimension) else { return .unknown }
            guard let ref2 = w.entityById[uid], let entity = ref2 as? Entity, !entity.dead else { return .unknown }
            // Security (code) SC-1 / Test DEF-2 fix (design.md Decision 2, spec
            // `object-graph-refs` "Player objects in the entity index"): `World.entityById`
            // also holds the local `Player` and, on a host, every `LANRemotePlayerEntity` —
            // neither is a plain entity. The local player's id is re-minted every
            // `enterWorld` and never adopted (Decision 3), so a stored `entity:<playerUid>`
            // ref would dangle across sessions; redirect to the canonical `player` object
            // instead. A `LANRemotePlayerEntity` is a host-side mirror of a guest's own
            // player (the `player:lan:*` object of a later phase) whose plain-field
            // built-ins are not the `Player` built-ins, so it resolves `.unsupported` here.
            if entity === host.localPlayer { return resolve(.player) }
            if entity is LANRemotePlayerEntity { return .unsupported }
            return .live(.entity(entity, w))

        case .player:
            guard isWorldOpen, let p = host.localPlayer, let w = host.world(for: host.currentDimension) else { return .unknown }
            return .live(.player(p, w))

        case .lanPlayer(let peerID):
            // lan-client-parity (change 4): live only on the host, for a
            // currently-connected peer whose `LANRemotePlayerEntity` mirror
            // exists in the *current* dimension (see `lanRemotePlayer`'s doc
            // comment on why a different-dimension peer is `.dormant`, not
            // `.unknown` — the ref names a real, known peer; the object is
            // just not loaded here right now, exactly like an unloaded
            // block/entity). A guest never resolves this (its own
            // `ObjectGraphHost.isLANClient` is true) — guests read their own
            // `player:lan:*` object only through the replicated mirror.
            guard isWorldOpen, !host.isLANClient else { return .unsupported }
            if let (entity, w) = host.lanRemotePlayer(peerID: peerID) {
                return .live(.entity(entity, w))
            }
            return .dormant
        }
    }

    public func kind(of ref: ObjectRef) -> ObjectKind { ref.kind }

    /// A human-readable display name for `ref` — the block registry's display
    /// name, the entity type prettified, "Player", "World", or the dimension
    /// name — regardless of liveness (used by `/inspect`/`/objects` after
    /// resolving, but pure with respect to the ref's shape).
    public func displayName(of ref: ObjectRef) -> String {
        switch ref {
        case .world:
            return "World"
        case .dimension(let d):
            return prettify(dimCanonicalName(d))
        case .block(_, let x, let y, let z):
            if case .live(.block(_, let chunk, _, _, _, _)) = resolve(ref) {
                let id = Int(chunk.get(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W))) >> 4
                if id >= 0 && id < blockDefs.count { return blockDefs[id].displayName }
            }
            return "Block"
        case .entity(let uid):
            if case .live(.entity(let entity, _)) = resolve(ref) { return prettify(entity.type) }
            _ = uid
            return "Entity"
        case .player:
            return "Player"
        case .lanPlayer:
            if case .live(.entity(let entity, _)) = resolve(ref), let remote = entity as? LANRemotePlayerEntity {
                return remote.displayName
            }
            return "LAN Player"
        }
    }

    /// Entities (non-dead, in the current world, excluding LAN mirror entities on
    /// a LAN client) and blocks owning a non-empty `ObjectRecord`, within
    /// `radius` (clamped to ≤ 48) of `(x,y,z)`, sorted by squared distance
    /// ascending — entities before blocks at an exact tie, then by uid (entities)
    /// or canonical ref (blocks) — truncated to `limit` (clamped to ≤ 64). Never
    /// loads a chunk; never iterates a `Dictionary`/`Set` in an order that
    /// affects the result.
    public func objectsNear(
        x: Double, y: Double, z: Double, radius: Double, limit: Int, kinds: Set<ObjectKind>? = nil
    ) -> [NearbyObjectEntry] {
        guard let w = host.world(for: host.currentDimension) else { return [] }
        let r = min(max(0, radius), 48)
        let lim = min(max(0, limit), 64)
        let r2 = r * r
        var entries: [NearbyObjectEntry] = []

        if kinds == nil || kinds!.contains(.entity) {
            for e in w.entities {
                guard let ent = e as? Entity, !ent.dead else { continue }
                if host.isLANClient && ent.lanReplicatedMirror { continue }
                // Security (code) SC-1 / Test DEF-2 fix: a `LANRemotePlayerEntity` is not a
                // plain entity (see `resolve`'s matching comment) and never appears under an
                // `entity:<uid>` ref — lan-client-parity (change 4) lists it separately below,
                // under its own `player:lan:<peerID>` ref, kind `.player` not `.entity`.
                if ent is LANRemotePlayerEntity { continue }
                let dx = ent.x - x, dy = ent.y - y, dz = ent.z - z
                let d2 = dx * dx + dy * dy + dz * dz
                guard d2 <= r2 else { continue }
                if ent === host.localPlayer, let p = ent as? Player {
                    entries.append(NearbyObjectEntry(ref: .player, liveObject: .player(p, w), distanceSq: d2))
                } else {
                    entries.append(NearbyObjectEntry(ref: .entity(uid: ent.id), liveObject: .entity(ent, w), distanceSq: d2))
                }
            }
        }

        // lan-client-parity (change 4): connected guests are discoverable as
        // `player:lan:<peerID>` objects — host-only (a guest never enumerates
        // another peer, matching its own object graph never resolving one
        // either) and only kind `.player` (their canonical ref kind, §5.1),
        // never `.entity` (SC-1's guard above stays exactly as strict as it
        // was — this is a second, deliberate listing under a different ref).
        if !host.isLANClient, kinds == nil || kinds!.contains(.player) {
            for e in w.entities {
                guard let remote = e as? LANRemotePlayerEntity, !remote.dead else { continue }
                let dx = remote.x - x, dy = remote.y - y, dz = remote.z - z
                let d2 = dx * dx + dy * dy + dz * dz
                guard d2 <= r2 else { continue }
                entries.append(NearbyObjectEntry(
                    ref: .lanPlayer(peerID: remote.multiplayerPlayerID),
                    liveObject: .entity(remote, w), distanceSq: d2
                ))
            }
        }

        if kinds == nil || kinds!.contains(.block) {
            let minCx = floorDiv(Int((x - r).rounded(.down)), CHUNK_W)
            let maxCx = floorDiv(Int((x + r).rounded(.up)), CHUNK_W)
            let minCz = floorDiv(Int((z - r).rounded(.down)), CHUNK_W)
            let maxCz = floorDiv(Int((z + r).rounded(.up)), CHUNK_W)
            var chunkKeys: [(Int, Int)] = []
            if minCx <= maxCx && minCz <= maxCz {
                for cx in minCx...maxCx {
                    for cz in minCz...maxCz { chunkKeys.append((cx, cz)) }
                }
            }
            chunkKeys.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            for (cx, cz) in chunkKeys {
                guard let chunk = w.getChunk(cx, cz), !chunk.objectRecords.isEmpty else { continue }
                for cellIndex in chunk.objectRecords.keys.sorted() {
                    guard let record = chunk.objectRecords[cellIndex], !record.isEmpty else { continue }
                    let (wx, wy, wz) = chunk.idxToWorld(cellIndex)
                    let dx = Double(wx) + 0.5 - x, dy = Double(wy) + 0.5 - y, dz = Double(wz) + 0.5 - z
                    let d2 = dx * dx + dy * dy + dz * dz
                    guard d2 <= r2 else { continue }
                    let ref = ObjectRef.block(dim: host.currentDimension, x: wx, y: wy, z: wz)
                    let live = LiveObject.block(world: w, chunk: chunk, cellIndex: cellIndex, x: wx, y: wy, z: wz)
                    entries.append(NearbyObjectEntry(ref: ref, liveObject: live, distanceSq: d2))
                }
            }
        }

        entries.sort { a, b in
            if a.distanceSq != b.distanceSq { return a.distanceSq < b.distanceSq }
            let aIsEntity = a.ref.kind == .entity
            let bIsEntity = b.ref.kind == .entity
            if aIsEntity != bIsEntity { return aIsEntity }
            if aIsEntity, case .entity(let auid) = a.ref, case .entity(let buid) = b.ref {
                return auid < buid
            }
            return a.ref.canonical < b.ref.canonical
        }
        return Array(entries.prefix(lim))
    }
}
