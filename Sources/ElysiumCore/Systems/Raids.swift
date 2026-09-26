// Raids — triggered by Bad Omen near a village,
// waves of pillagers/vindicators/witches/ravagers/evokers, Hero of the
// Village on victory. Plus wandering pillager patrols.

import Foundation

public final class Raid {
    // weak: raidManager is process-global and outlives world switches — an
    // unowned ref trapped on the first touch after loading another save
    public weak var world: World?
    public var cx: Int, cy: Int, cz: Int
    public var wave = 0
    public var totalWaves: Int
    public var raiders: [Int] = []      // entity ids
    public var active = true
    public var victory = false
    public var defeat = false
    public var cooldown = 60
    public var totalHealth = 0.0
    public var maxHealth = 1.0
    /// Times the current wave was re-rolled because no member found a dry
    /// placement (a wave angle that landed in a lake). Bounded so an island
    /// village cannot hold a raid open forever.
    var wavePlacementRerolls = 0
    /// Raiders actually placed over the whole raid. A raid whose every wave found only open
    /// water ends without victory: nobody fought it, so it grants no Hero of the Village.
    var raidersSpawned = 0

    init(world: World, cx: Int, cy: Int, cz: Int, totalWaves: Int) {
        self.world = world
        self.cx = cx; self.cy = cy; self.cz = cz
        self.totalWaves = totalWaves
    }
}

private let WAVES: [Int: [(String, Int)]] = [
    1: [("pillager", 4), ("vindicator", 1)],
    2: [("pillager", 5), ("vindicator", 2)],
    3: [("pillager", 4), ("vindicator", 2), ("witch", 1), ("ravager", 1)],
    4: [("pillager", 5), ("vindicator", 3), ("witch", 2)],
    5: [("pillager", 5), ("vindicator", 4), ("witch", 2), ("evoker", 1), ("ravager", 1)],
    6: [("pillager", 6), ("vindicator", 4), ("witch", 2), ("evoker", 1)],
    7: [("pillager", 7), ("vindicator", 5), ("witch", 3), ("evoker", 2), ("ravager", 2)],
]

public final class RaidManager {
    public var raids: [Raid] = []
    private var rng = RandomX(0x4A1D)

    public init() {}

    /// call when a player with Bad Omen enters a village area
    public func tryStartRaid(_ world: World, _ player: Player) {
        // Prehistoric profiles own their hostile-event domain. Keep this
        // defensive boundary inside the manager as well as GameCore's
        // scheduler, because imported state and direct callers can bypass
        // that outer tick gate.
        guard !world.generationSettings.preset.isPrehistoric else { return }
        if !player.hasEffect("bad_omen") { return }
        // is there a village nearby? (bell or villagers)
        let villagers = world.getEntitiesNear(player.x, player.y, player.z, 48, filter: { ($0 as? Entity)?.type == "villager" })
        if villagers.count < 1 { return }
        // existing raid at this village?
        for r in raids {
            let dx = Double(r.cx) - player.x, dz = Double(r.cz) - player.z
            if r.world === world && r.active && !r.victory && !r.defeat && dx * dx + dz * dz < 96 * 96 { return }
        }
        let omenLvl = player.effectLevel("bad_omen")
        player.removeEffect("bad_omen")
        let totalWaves = (world.difficulty == 1 ? 3 : world.difficulty == 2 ? 5 : 7) + (omenLvl > 1 ? 1 : 0)
        let raid = Raid(world: world, cx: ifloor(player.x), cy: ifloor(player.y), cz: ifloor(player.z), totalWaves: totalWaves)
        raids.append(raid)
        world.hooks.playSound("event.raid.horn", player.x, player.y + 8, player.z, 6, 1)
    }

    public func tick(_ world: World) {
        // See tryStartRaid: a direct manager call must neither mutate an
        // imported raid nor emit modern raiders in a prehistoric world.
        guard !world.generationSettings.preset.isPrehistoric else { return }
        raids.removeAll { $0.world == nil }
        for raid in raids {
            if raid.world !== world || !raid.active { continue }
            // count living raiders + health
            var alive = 0
            var hp = 0.0
            for id in raid.raiders {
                if let e = world.entityById[id] as? LivingEntity, !e.dead { alive += 1; hp += e.health }
            }
            raid.totalHealth = hp
            if raid.cooldown > 0 {
                raid.cooldown -= 1
                continue
            }
            if alive == 0 {
                if raid.wave >= raid.totalWaves {
                    raid.active = false
                    // A raid that never reached the village (every wave over open water)
                    // simply ends; victory and its reward need raiders to have been fought.
                    guard raid.raidersSpawned > 0 else { continue }
                    // VICTORY
                    raid.victory = true
                    world.hooks.playSound("ui.toast.challenge_complete", Double(raid.cx), Double(raid.cy), Double(raid.cz), 4, 1)
                    for p in world.getEntitiesNear(Double(raid.cx), Double(raid.cy), Double(raid.cz), 64, filter: { ($0 as? Entity)?.isPlayer ?? false }) {
                        (p as? LivingEntity)?.addEffect("hero_of_the_village", 48000, 0)
                    }
                    continue
                }
                // next wave
                raid.wave += 1
                raid.raiders = []
                let comp = WAVES[min(7, raid.wave)] ?? WAVES[7]!
                let ang = rng.nextFloat() * .pi * 2
                let sx = Double(raid.cx) + detCos(ang) * 40
                let sz = Double(raid.cz) + detSin(ang) * 40
                var captainSet = false
                var maxHp = 0.0
                for (mob, count) in comp {
                    for _ in 0..<count {
                        let px = sx + rng.nextFloat() * 6 - 3
                        let pz = sz + rng.nextFloat() * 6 - 3
                        // a member whose sampled column is in water moves to the
                        // nearest dry column, or is skipped; never spawned in water
                        guard let placement = raidSpawnPlacement(
                            world, mob, x: px, z: pz, preferredY: world.surfaceY(ifloor(px), ifloor(pz)))
                        else { continue }
                        let e = spawnMob(world, mob, placement.x, Double(placement.y), placement.z,
                                         SpawnOpts(persistent: true, captain: !captainSet && mob == "pillager"))
                        if let e {
                            raid.raiders.append(e.id)
                            raid.raidersSpawned += 1
                            maxHp += (e as? LivingEntity)?.maxHealth ?? 20
                            if mob == "pillager" { captainSet = true }
                            // raiders hunt the village
                            (e as? Mob)?.nav.moveTo(Double(raid.cx), Double(raid.cy), Double(raid.cz), 1.1)
                        }
                    }
                }
                if raid.raiders.isEmpty && raid.wavePlacementRerolls < RAID_WAVE_PLACEMENT_REROLLS {
                    // The whole wave sampled open water. Re-roll its angle on a
                    // later cycle instead of handing the village a free wave.
                    raid.wave -= 1
                    raid.wavePlacementRerolls += 1
                    raid.cooldown = 20
                    continue
                }
                raid.wavePlacementRerolls = 0
                raid.maxHealth = maxHp
                raid.cooldown = 40
                world.hooks.playSound("event.raid.horn", Double(raid.cx), Double(raid.cy + 8), Double(raid.cz), 6, 1)
            } else {
                raid.cooldown = 20
                // defeat check: all villagers dead
                if world.time % 100 == 0 {
                    let villagers = world.getEntitiesNear(Double(raid.cx), Double(raid.cy), Double(raid.cz), 64, filter: { ($0 as? Entity)?.type == "villager" })
                    if villagers.isEmpty {
                        raid.active = false
                        raid.defeat = true
                    }
                }
            }
        }
        // prune finished
        if world.time % 200 == 0 {
            raids = raids.filter { $0.active || (world.time % 1200 != 0) }
        }
    }

    public func activeRaidNear(_ world: World, _ x: Double, _ z: Double) -> Raid? {
        for r in raids {
            let dx = Double(r.cx) - x, dz = Double(r.cz) - z
            if r.world === world && r.active && dx * dx + dz * dz < 96 * 96 { return r }
        }
        return nil
    }
}

public let raidManager = RaidManager()

/// patrols: occasionally spawn pillager patrols in the world
public func tryPatrolSpawn(_ world: World, _ players: [Player], _ rng: inout RandomX) {
    // The scheduler guards this too, but direct callers/imported simulation
    // must not consume patrol RNG or emit modern raiders in a profile that
    // owns its hostile-event domain.
    guard !world.generationSettings.preset.isPrehistoric else { return }
    if world.time % 12000 != 0 || world.difficulty == 0 || players.isEmpty { return }
    if rng.nextFloat() > 0.2 { return }
    let p = players[rng.nextInt(players.count)]
    let ang = rng.nextFloat() * .pi * 2
    let x = p.x + detCos(ang) * (32 + rng.nextFloat() * 32)
    let z = p.z + detSin(ang) * (32 + rng.nextFloat() * 32)
    let y = world.surfaceY(ifloor(x), ifloor(z))
    if world.lightAt(ifloor(x), y, ifloor(z)) > 7 && !world.isDay() { return }
    // baseline: rng-in-loop-condition — rerolls every iteration check
    var i = 0
    var captainSet = false
    while i < 2 + rng.nextInt(3) {
        // same draw order as before (x offset, then z offset) whether or not
        // the member finds a dry placement
        let px = x + rng.nextFloat() * 4 - 2
        let pz = z + rng.nextFloat() * 4 - 2
        if let placement = raidSpawnPlacement(world, "pillager", x: px, z: pz, preferredY: y),
           spawnMob(world, "pillager", placement.x, Double(placement.y), placement.z,
                    SpawnOpts(persistent: false, captain: !captainSet)) != nil {
            captainSet = true
        }
        i += 1
    }
}

/// Largest square-ring radius searched around a raid or patrol member's
/// sampled column when that column is not a valid placement.
let RAID_PLACEMENT_SEARCH_RADIUS = 4
/// Times a wave whose every member sampled open water is re-rolled at a new
/// angle before the raid simply moves on.
let RAID_WAVE_PLACEMENT_REROLLS = 3

/// Where a raid or patrol member actually spawns. Its sampled position is kept
/// when `spawnPlacementIsValid` admits it (so dry-land raids are unchanged);
/// otherwise the sampled column's own surface, then the nearest valid surface
/// column in a fixed square-ring order out to `RAID_PLACEMENT_SEARCH_RADIUS`.
/// Deterministic and RNG-free. Nil when every candidate is water: skip the member.
func raidSpawnPlacement(
    _ world: World, _ mob: String, x: Double, z: Double, preferredY: Int
) -> (x: Double, y: Int, z: Double)? {
    let bx = ifloor(x), bz = ifloor(z)
    if spawnPlacementIsValid(world, mob, bx, preferredY, bz) { return (x, preferredY, z) }
    let columnY = world.surfaceY(bx, bz)
    if columnY != preferredY, spawnPlacementIsValid(world, mob, bx, columnY, bz) { return (x, columnY, z) }
    for r in 1...RAID_PLACEMENT_SEARCH_RADIUS {
        for dz in -r...r {
            for dx in -r...r where max(abs(dx), abs(dz)) == r {
                let cx = bx + dx, cz = bz + dz
                let cy = world.surfaceY(cx, cz)
                if spawnPlacementIsValid(world, mob, cx, cy, cz) {
                    return (Double(cx) + 0.5, cy, Double(cz) + 0.5)
                }
            }
        }
    }
    return nil
}
