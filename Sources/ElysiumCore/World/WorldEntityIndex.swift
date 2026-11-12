// Typed views of a world's entity list, for code that runs many times a tick.
//
// `World.entities` holds every entity as an `EntityRef`. Spawners, mob goals, projectiles,
// beacons and the crowd-push loop only care about players or living entities, and each used to
// walk and cast the whole list per call: with a thousand animals loaded, that walk was most of a
// simulation tick. The index keeps the two typed lists and rebuilds them only after `entities`
// itself changes, so every reader gets the same members in the same order as the walk did.
import Foundation

/// Membership caches for `World.entities`. Liveness, position and eligibility are never cached;
/// readers test them on each use, exactly as they did when walking the full list.
struct WorldEntityIndex {
    private var revision: UInt64 = 0
    private var players: (revision: UInt64, members: [Entity])?
    private var living: (revision: UInt64, members: [LivingEntity])?

    /// Called from `World.entities.didSet`: any gain, loss or reorder makes both lists stale.
    mutating func membershipChanged() { revision &+= 1 }

    mutating func players(in entities: [EntityRef]) -> [Entity] {
        if let players, players.revision == revision { return players.members }
        var members: [Entity] = []
        for ref in entities {
            if let entity = ref as? Entity, entity.isPlayer { members.append(entity) }
        }
        players = (revision, members)
        return members
    }

    mutating func living(in entities: [EntityRef]) -> [LivingEntity] {
        if let living, living.revision == revision { return living.members }
        var members: [LivingEntity] = []
        for ref in entities {
            if let entity = ref as? LivingEntity { members.append(entity) }
        }
        living = (revision, members)
        return members
    }
}

extension World {
    /// The members of `entities` that are players (`Entity.isPlayer`), in `entities` order.
    /// Dead players are included; callers decide what liveness means to them.
    public var playerEntities: [Entity] { entityIndex.players(in: entities) }

    /// The members of `entities` that are `LivingEntity`, in `entities` order.
    public var livingEntities: [LivingEntity] { entityIndex.living(in: entities) }

    /// The live players within `radius` of the point, in `entities` order: exactly what
    /// `getEntitiesNear` returns when filtered to `Entity.isPlayer`, found without visiting
    /// anything that is not a player.
    public func getPlayersNear(_ x: Double, _ y: Double, _ z: Double, _ radius: Double) -> [EntityRef] {
        World.liveMembers(of: playerEntities, within: radius, x, y, z, filter: nil)
    }

    /// The one statement of what "near" means for `getEntitiesNear` and `getPlayersNear`: not
    /// dead, and no farther than `radius` from the point, measured to the entity's position.
    /// Candidates keep their order; `filter` is asked only about those in range.
    static func liveMembers(of candidates: [EntityRef], within radius: Double,
                            _ x: Double, _ y: Double, _ z: Double,
                            filter: ((EntityRef) -> Bool)?) -> [EntityRef] {
        let r2 = radius * radius
        var out: [EntityRef] = []
        for e in candidates {
            if e.dead { continue }
            let dx = e.x - x, dy = e.y - y, dz = e.z - z
            if dx * dx + dy * dy + dz * dz <= r2 && (filter?(e) ?? true) { out.append(e) }
        }
        return out
    }
}
