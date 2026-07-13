// Entity factory registry + natural spawning rules — Registration order mirrors baseline (it feeds entityTypes()).

import Foundation

public typealias EntityFactory = (World) -> Entity

private var FACTORIES: [(String, EntityFactory)] = []
private var FACTORY_BY_NAME: [String: EntityFactory] = [:]
private func reg(_ name: String, _ f: @escaping EntityFactory) {
    FACTORIES.append((name, f))
    FACTORY_BY_NAME[name] = f
}

private var entitiesRegistered = false

public func registerAllEntities() {
    if entitiesRegistered { return }
    entitiesRegistered = true
    registerEntityHelpers()

    reg("cow") { Cow(world: $0) }; reg("mooshroom") { Mooshroom(world: $0) }
    reg("pig") { Pig(world: $0) }; reg("sheep") { Sheep(world: $0) }
    reg("chicken") { Chicken(world: $0) }; reg("rabbit") { Rabbit(world: $0) }
    reg("wolf") { Wolf(world: $0) }; reg("cat") { Cat(world: $0) }; reg("ocelot") { Ocelot(world: $0) }
    reg("fox") { Fox(world: $0) }; reg("parrot") { Parrot(world: $0) }; reg("bee") { Bee(world: $0) }
    reg("axolotl") { Axolotl(world: $0) }; reg("frog") { Frog(world: $0) }; reg("tadpole") { Tadpole(world: $0) }
    reg("goat") { Goat(world: $0) }; reg("turtle") { Turtle(world: $0) }; reg("dolphin") { Dolphin(world: $0) }
    reg("squid") { Squid(world: $0) }; reg("glow_squid") { GlowSquid(world: $0) }; reg("bat") { Bat(world: $0) }
    reg("polar_bear") { PolarBear(world: $0) }; reg("panda") { Panda(world: $0) }; reg("strider") { Strider(world: $0) }
    reg("camel") { Camel(world: $0) }; reg("sniffer") { Sniffer(world: $0) }; reg("allay") { Allay(world: $0) }
    reg("cod") { Cod(world: $0) }; reg("salmon") { Salmon(world: $0) }
    reg("tropical_fish") { TropicalFish(world: $0) }; reg("pufferfish") { Pufferfish(world: $0) }
    reg("villager") { Villager(world: $0) }; reg("wandering_trader") { WanderingTrader(world: $0) }
    reg("iron_golem") { IronGolem(world: $0) }; reg("snow_golem") { SnowGolem(world: $0) }
    reg("horse") { Horse(world: $0) }; reg("donkey") { Donkey(world: $0) }; reg("mule") { Mule(world: $0) }
    reg("skeleton_horse") { SkeletonHorse(world: $0) }; reg("llama") { Llama(world: $0) }
    reg("zombie") { Zombie(world: $0) }; reg("husk") { Husk(world: $0) }; reg("drowned") { Drowned(world: $0) }
    reg("zombie_villager") { ZombieVillagerMob(world: $0) }
    reg("skeleton") { Skeleton(world: $0) }; reg("stray") { Stray(world: $0) }
    reg("creeper") { Creeper(world: $0) }
    reg("spider") { Spider(world: $0) }; reg("cave_spider") { CaveSpider(world: $0) }
    reg("slime") { Slime(world: $0) }; reg("witch") { Witch(world: $0) }
    reg("enderman") { Enderman(world: $0) }
    reg("silverfish") { Silverfish(world: $0) }; reg("endermite") { Endermite(world: $0) }
    reg("phantom") { Phantom(world: $0) }
    reg("guardian") { Guardian(world: $0) }; reg("elder_guardian") { ElderGuardian(world: $0) }
    reg("shulker") { Shulker(world: $0) }
    reg("pillager") { Pillager(world: $0) }; reg("vindicator") { Vindicator(world: $0) }
    reg("evoker") { Evoker(world: $0) }; reg("vex") { Vex(world: $0) }; reg("ravager") { Ravager(world: $0) }
    reg("blaze") { Blaze(world: $0) }; reg("ghast") { Ghast(world: $0) }; reg("magma_cube") { MagmaCube(world: $0) }
    reg("zombified_piglin") { ZombifiedPiglin(world: $0) }
    reg("piglin") { Piglin(world: $0) }; reg("piglin_brute") { PiglinBrute(world: $0) }
    reg("hoglin") { Hoglin(world: $0) }; reg("zoglin") { Zoglin(world: $0) }
    reg("wither_skeleton") { WitherSkeletonMob(world: $0) }
    reg("warden") { Warden(world: $0) }
    reg("ender_dragon") { EnderDragon(world: $0) }
    reg("wither") { WitherBoss(world: $0) }
    reg("item") { ItemEntity(world: $0) }; reg("xp_orb") { XPOrb(world: $0) }
    reg("falling_block") { FallingBlockEntity(world: $0) }; reg("tnt") { TNTEntity(world: $0) }
    reg("lightning") { LightningBolt(world: $0) }; reg("end_crystal") { EndCrystal(world: $0) }
    reg("effect_cloud") { AreaEffectCloud(world: $0) }; reg("eye_of_ender") { EyeOfEnderEntity(world: $0) }
    reg("arrow") { ArrowEntity(world: $0) }; reg("snowball") { ThrownSnowball(world: $0) }
    reg("egg") { ThrownEgg(world: $0) }; reg("ender_pearl") { ThrownPearl(world: $0) }
    reg("xp_bottle") { ThrownXPBottle(world: $0) }; reg("thrown_potion") { ThrownPotion(world: $0) }
    reg("fireball") { Fireball(world: $0) }; reg("wither_skull") { WitherSkull(world: $0) }
    reg("dragon_fireball") { DragonFireball(world: $0) }; reg("shulker_bullet") { ShulkerBullet(world: $0) }
    reg("trident") { TridentEntity(world: $0) }; reg("firework") { FireworkEntity(world: $0) }
    reg("fishing_bobber") { FishingBobber(world: $0) }; reg("llama_spit") { LlamaSpit(world: $0) }
    reg("boat") { Boat(world: $0) }; reg("minecart") { Minecart(world: $0) }
    reg("player") { Player(world: $0) }

    bindSpawnMob(spawnMob)
}

public func createEntity(_ type: String, _ world: World) -> Entity? {
    FACTORY_BY_NAME[type].map { $0(world) }
}
public func entityTypes() -> [String] { FACTORIES.map { $0.0 } }

@discardableResult
public func spawnMob(_ world: World, _ type: String, _ x: Double, _ y: Double, _ z: Double, _ data: SpawnOpts? = nil) -> Entity? {
    guard let e = createEntity(type, world) else { return nil }
    e.setPos(x, y, z)
    if let data {
        if data.baby, let mob = e as? Mob {
            mob.baby = true
            mob.growUpAge = 24000
        }
        if let size = data.size, size != 0, let slime = e as? Slime { slime.setSize(size) }
        if data.persistent { e.persistent = true }
        if data.captain {
            (e as? Pillager)?.isCaptain = true
            (e as? Vindicator)?.isCaptain = true
        }
        if let v = data.variant, v != 0 { e.data.variant = v }
        // mirror the spawn option-bag fields onto entity data
        if data.captain { e.data.captain = true }
        if data.baby { e.data.baby = true }
        if data.persistent { e.data.persistent = true }
        if let s = data.size { e.data.size = s }
    }
    world.addEntity(e)
    return e
}

public func loadEntity(_ world: World, _ d: [String: Any]) -> Entity? {
    guard let type = d["type"] as? String, let e = createEntity(type, world) else { return nil }
    e.load(d)
    return e
}

// =============================================================================
// Natural spawning
// =============================================================================
public func naturalSpawnTick(_ world: World, _ players: [Player], _ rng: inout RandomX) {
    if !world.rule("doMobSpawning") || players.isEmpty { return }
    // count by category
    var counts: [String: Int] = [:]
    for e in world.entities {
        if let mob = e as? Mob {
            counts[mob.category] = (counts[mob.category] ?? 0) + 1
        }
    }
    let attempts: [(String, Int, Bool)] = [
        ("monster", 70, true),          // every tick
        ("creature", 10, world.time % 400 == 0),
        ("ambient", 15, world.time % 400 == 0),
        ("water", 5, world.time % 400 == 0),
    ]
    for (cat, cap, doIt) in attempts {
        if !doIt { continue }
        if cat == "monster" && world.difficulty == 0 { continue }
        if (counts[cat] ?? 0) >= cap { continue }
        // pick a random player and position
        let p = players[rng.nextInt(players.count)]
        let dist = 24 + rng.nextFloat() * 80
        let ang = rng.nextFloat() * .pi * 2
        let x = ifloor(p.x + detCos(ang) * dist)
        let z = ifloor(p.z + detSin(ang) * dist)
        if !world.isLoadedAt(x, z) { continue }
        var y: Int
        if cat == "monster" && rng.nextFloat() < 0.6 {
            // try caves: random y below surface
            y = world.info.minY + 1 + rng.nextInt(max(1, world.surfaceY(x, z) - world.info.minY))
        } else {
            y = world.surfaceY(x, z)
        }
        let biome = world.biomeAt(x, y, z)
        guard let bdef = BIOMES[Int(biome)] else { continue }
        let list = cat == "monster" ? bdef.monsters : cat == "creature" ? bdef.creatures : cat == "water" ? bdef.waterCreatures : bdef.ambient
        if list.isEmpty { continue }
        let entry = rng.pickWeighted(list) { $0.weight }
        let mobType = entry.mob, minPack = entry.minPack, maxPack = entry.maxPack

        // spawn conditions
        if !canSpawnAt(world, mobType, cat, x, y, z, &rng) { continue }
        // pack spawn
        let pack = minPack + rng.nextInt(Swift.max(1, maxPack - minPack + 1))
        var spawned = 0
        for _ in 0..<pack {
            let px = x + rng.nextInt(9) - 4
            let pz = z + rng.nextInt(9) - 4
            var py = cat == "water" ? y : world.surfaceY(px, pz)
            if cat == "monster" { py = y }
            if !canSpawnAt(world, mobType, cat, px, py, pz, &rng) { continue }
            // don't spawn too close to players
            var tooClose = false
            for pl in players {
                let dx = pl.x - Double(px), dy = pl.y - Double(py), dz = pl.z - Double(pz)
                if dx * dx + dy * dy + dz * dz < 24 * 24 { tooClose = true; break }
            }
            if tooClose { continue }
            let mob = spawnMob(world, mobType, Double(px) + 0.5, Double(py), Double(pz) + 0.5, SpawnOpts())
            if mob != nil { spawned += 1 }
            if (counts[cat] ?? 0) + spawned >= cap { break }
        }
    }
}

func canSpawnAt(_ world: World, _ mobType: String, _ cat: String, _ x: Int, _ y: Int, _ z: Int, _ rng: inout RandomX) -> Bool {
    if y <= world.info.minY || y >= world.info.minY + world.info.height - 1 { return false }
    let at = world.getBlock(x, y, z)
    let atId = at >> 4
    let below = world.getBlock(x, y - 1, z) >> 4
    if cat == "water" {
        return atId == Int(B.water)
    }
    // land mobs never spawn inside fluids (water is "replaceable" and slipped
    // through — zombies and chickens were spawning in the ocean)
    if atId == Int(B.water) || atId == Int(B.lava) { return false }
    let headId = world.getBlock(x, y + 1, z) >> 4
    if headId == Int(B.water) { return false }
    if atId != 0 && !blockDefs[atId].replaceable { return false }
    let head = world.getBlock(x, y + 1, z) >> 4
    if head != 0 && blockDefs[head].solid { return false }
    if below == 0 || !blockDefs[below].solid { return false }
    if cat == "monster" {
        // vanilla 1.20 isDarkEnoughToSpawn: block light must be 0, then two
        // probabilistic gates — raw skylight vs rand(32), then skyDarken-adjusted
        // light vs rand(8). The old "≤7" rule let every midday shadow spawn mobs.
        let blockLight = world.getBlockLight(x, y, z)
        if blockLight > 0 { return false }
        if mobType == "blaze" || mobType == "magma_cube" || mobType == "ghast" || mobType == "zombified_piglin" || mobType == "piglin" || mobType == "hoglin" || mobType == "strider" {
            return true // nether mobs ignore light
        }
        if world.info.hasSky {
            let rawSky = world.getSkyLight(x, y, z)
            if rawSky > rng.nextInt(32) { return false }
            let effective = Int(world.lightAt(x, y, z))
            if effective > rng.nextInt(8) { return false }
        }
        if below == Int(B.bedrock) { return false }
        // slimes: swamps at night or slime chunks below y=40
        if mobType == "slime" {
            let biome = world.biomeAt(x, y, z)
            if biome == Biome.swamp.rawValue || biome == Biome.mangroveSwamp.rawValue { return y < 70 }
            // slime chunk
            let cx = Int((Double(x) / 16).rounded(.down)), cz = Int((Double(z) / 16).rounded(.down))
            let h = (imul32(cx, 0x1f1f1f1f) ^ imul32(cz, 0x5f356495) ^ world.seed)
            return (h % 10) == 0 && y < 40
        }
        return true
    }
    if cat == "creature" {
        // animals need grass-ish + light
        if world.lightAt(x, y, z) < 9 && world.info.hasSky { return false }
        return below == Int(B.grass_block) || below == Int(B.sand) || below == Int(B.snow_block) || below == Int(B.mycelium) || below == Int(B.podzol) || !world.info.hasSky
    }
    return true
}

@inline(__always)
private func imul32(_ a: Int, _ b: UInt32) -> UInt32 {
    UInt32(bitPattern: Int32(truncatingIfNeeded: a)) &* b
}

/// helper for commands /summon listing
public func spawnableMobs() -> [String] {
    let excluded: Set<String> = ["item", "xp_orb", "falling_block", "tnt", "lightning", "effect_cloud", "eye_of_ender", "arrow", "snowball", "egg", "ender_pearl", "xp_bottle", "thrown_potion", "fireball", "wither_skull", "dragon_fireball", "shulker_bullet", "trident", "firework", "fishing_bobber", "llama_spit", "player"]
    return entityTypes().filter { !excluded.contains($0) }
}
