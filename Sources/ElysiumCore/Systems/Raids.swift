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
        if !player.hasEffect("bad_omen") { return }
        // is there a village nearby? (bell or villagers)
        let villagers = world.getEntitiesNear(player.x, player.y, player.z, 48, filter: { ($0 as? Entity)?.type == "villager" })
        if villagers.count < 1 { return }
        // existing raid at this village?
        for r in raids {
            let dx = Double(r.cx) - player.x, dz = Double(r.cz) - player.z
            if r.world === world && !r.victory && !r.defeat && dx * dx + dz * dz < 96 * 96 { return }
        }
        let omenLvl = player.effectLevel("bad_omen")
        player.removeEffect("bad_omen")
        let totalWaves = (world.difficulty == 1 ? 3 : world.difficulty == 2 ? 5 : 7) + (omenLvl > 1 ? 1 : 0)
        let raid = Raid(world: world, cx: ifloor(player.x), cy: ifloor(player.y), cz: ifloor(player.z), totalWaves: totalWaves)
        raids.append(raid)
        world.hooks.playSound("event.raid.horn", player.x, player.y + 8, player.z, 6, 1)
    }

    public func tick(_ world: World) {
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
                    // VICTORY
                    raid.active = false
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
                        let py = world.surfaceY(ifloor(px), ifloor(pz))
                        let e = spawnMob(world, mob, px, Double(py), pz, SpawnOpts(persistent: true, captain: !captainSet && mob == "pillager"))
                        if let e {
                            raid.raiders.append(e.id)
                            maxHp += (e as? LivingEntity)?.maxHealth ?? 20
                            if mob == "pillager" { captainSet = true }
                            // raiders hunt the village
                            (e as? Mob)?.nav.moveTo(Double(raid.cx), Double(raid.cy), Double(raid.cz), 1.1)
                        }
                    }
                }
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
    while i < 2 + rng.nextInt(3) {
        _ = spawnMob(world, "pillager", x + rng.nextFloat() * 4 - 2, Double(y), z + rng.nextFloat() * 4 - 2, SpawnOpts(persistent: false, captain: i == 0))
        i += 1
    }
}
