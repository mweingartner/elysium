// GameCore+Scripting.swift — object-graph-attributes (change 1a). design.md
// Decisions 2/3/9. `GameCore`'s `ObjectGraphHost` conformance plus the small
// amount of session state the scripting subsystem needs
// (`GameScriptingState`) — kept out of `GameCore.swift` itself so that
// 5,500-line file's own diff stays at the one stored property Decision 2
// asks for.

import Foundation

/// Session-scoped scripting state a `GameCore` owns for the lifetime of one
/// open world. Reset (by simply replacing its contents) on every
/// `enterWorld`; nothing here is itself persisted directly — it mirrors what
/// `WorldRecord.objects`/`Chunk.objectRecords`/`Entity.objectRecord` already
/// persist.
public final class GameScriptingState {
    /// World + three dimension bags, keyed by `ObjectRef.canonical`
    /// (`"world"`, `"dim:overworld"`, `"dim:nether"`, `"dim:end"`).
    var worldRecords: [String: ObjectRecord] = [:]
    /// Whether the entity-id reservation write has already failed once this
    /// session (design.md Condition 7: "failure logged once per session").
    var reservationFailureLogged = false

    public init() {}
}

extension GameCore: ObjectGraphHost {
    public var currentDimension: Dim { dim }

    public func world(for dim: Dim) -> World? { worlds[dim] }

    /// Bridges `GameCore.player` (`Player!`, historical) to the protocol's
    /// plain-`Optional` requirement — named `localPlayer` rather than
    /// `player` so it cannot collide with (or be mistaken for a re-typing
    /// of) that stored property.
    public var localPlayer: Player? { player }

    public var isLANClient: Bool { isLANClientWorld }

    public var currentTick: Int64 { Int64(world.time) }

    public var scriptsEnabled: Bool { worldRec?.scriptsEnabled ?? false }

    public func worldObjectRecord(for ref: ObjectRef) -> ObjectRecord {
        scripting.worldRecords[ref.canonical] ?? ObjectRecord()
    }

    public func setWorldObjectRecord(_ record: ObjectRecord, for ref: ObjectRef) {
        if record.isEmpty {
            scripting.worldRecords.removeValue(forKey: ref.canonical)
        } else {
            scripting.worldRecords[ref.canonical] = record
        }
    }

    // `setDifficulty(_:)` and `setGameRule(_:_:)` are already implemented by
    // `GameCore` itself (Game/GameCore.swift) with the exact signatures this
    // protocol declares — no forwarding needed here.

    // MARK: - graph / store / command context

    var attributeStore: AttributeStore {
        AttributeStore(graph: ObjectGraph(host: self))
    }

    /// The entity under the crosshair within reach if one is closer than the
    /// block hit, else the block under the crosshair, else `nil` ("nothing
    /// under the cursor") — spec `object-graph-refs` "Command target
    /// aliases". `crosshairEntity` already refuses an entity farther than the
    /// block hit, so a non-nil entity here is always the closer of the two.
    public func cursorObjectRef() -> ObjectRef? {
        guard let p = player else { return nil }
        let reach = p.gameMode == GameMode.creative ? REACH_CREATIVE : REACH_SURVIVAL
        if let entity = crosshairEntity(reach) {
            return .entity(uid: entity.id)
        }
        if let hit = crosshairBlock() {
            return .block(dim: dim, x: hit.x, y: hit.y, z: hit.z)
        }
        return nil
    }

    /// Builds the context `ScriptingCommands.run` needs — a fresh `ObjectGraph`/
    /// `AttributeStore` pair over `self`, the target-alias context, LAN-client
    /// state and the current tick.
    public func scriptingCommandContext() -> ScriptingCommandContext {
        let graph = ObjectGraph(host: self)
        let store = AttributeStore(graph: graph)
        let targetContext = ObjectTargetContext(currentDimension: dim, cursor: { [weak self] in self?.cursorObjectRef() })
        return ScriptingCommandContext(
            graph: graph, store: store, target: targetContext, isLANClient: isLANClientWorld, tick: Int64(world.time)
        )
    }

    // MARK: - uid hi/lo reservation (design.md Decision 3 / Condition 7,
    // amended by Security (plan) C20)

    /// The reservation hook `installEntityIdReservation` fires (via
    /// `Entity.init`/`bumpEntityIdCounter(past:)`) whenever the live counter
    /// is about to hand out an id at or past the durable mark. Writes the
    /// world record with `nextEntityId = needed + 4096` (overflow-safe,
    /// saturating at `WorldRecord.maxReservableEntityId`), verifies by
    /// reading it back, and raises the mark only once that verification
    /// succeeds. A failed write is logged once per session (never again) and
    /// the mark is raised anyway so the hook does not keep retrying a write
    /// that is already known to fail on every subsequent mint.
    func reserveEntityIds(upTo needed: Int) {
        guard var rec = worldRec, !isLANClientWorld else { return }
        let (bumped, overflowed) = needed.addingReportingOverflow(4096)
        let newLimit = overflowed ? WorldRecord.maxReservableEntityId : min(bumped, WorldRecord.maxReservableEntityId)
        rec.nextEntityId = max(newLimit, rec.nextEntityId)
        db.putWorld(rec)
        if let readBack = db.getWorld(rec.id), readBack.nextEntityId >= newLimit {
            worldRec = rec
        } else if !scripting.reservationFailureLogged {
            scripting.reservationFailureLogged = true
            print("[scripting] entity id reservation write failed for world \(rec.id); "
                + "continuing without further reservation this session")
        }
        raiseEntityIdReservationLimit(to: newLimit)
    }

    // MARK: - world/dimension object records (design.md Decision 9)

    /// Populates `scripting.worldRecords` from a freshly loaded `WorldRecord`
    /// (`enterWorld`). A corrupt entry is dropped with a diagnostic; the
    /// world still loads.
    func loadWorldObjectRecords(from rec: WorldRecord) {
        scripting.worldRecords.removeAll()
        for (key, text) in rec.objects {
            guard let record = ObjectRecordCodec.decode(text, caps: .defaults) else {
                print("[scripting] dropped corrupt world/dimension object record for '\(key)'")
                continue
            }
            scripting.worldRecords[key] = record
        }
    }

    /// Encodes `scripting.worldRecords` into `rec.objects` (`saveAndFlushResult`,
    /// before `db.putWorld`) — non-empty bags only.
    func storeWorldObjectRecords(into rec: inout WorldRecord) {
        var out: [String: String] = [:]
        for (key, record) in scripting.worldRecords where !record.isEmpty {
            out[key] = ObjectRecordCodec.encode(record)
        }
        rec.objects = out
    }
}
