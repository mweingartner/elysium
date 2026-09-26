// Entity factory registry + natural spawning rules — Registration order mirrors baseline (it feeds entityTypes()).

import CoreFoundation
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
    // Append-only registration: roster order is the stable profile catalog
    // order and every existing entity type keeps its historical ordinal.
    for definition in PrehistoricCreatureDefinition.all {
        reg(definition.id) { PrehistoricCreature(world: $0, definition: definition) }
    }

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
        if let prehistoricSeedSalt = data.prehistoricSeedSalt {
            e.data.prehistoricSeedSalt = prehistoricSeedSalt
        }
    }
    if let prehistoric = e as? PrehistoricCreature {
        // Apply the opt-in seed salt after all spawn options have been copied.
        // A direct/manual spawn falls back to the unique live entity id.
        prehistoric.seedControllerRNGForCurrentPosition()
    }
    world.addEntity(e)
    return e
}

/// The inclusive range a persisted entity `"id"` must fall in to be adopted
/// (object-graph-attributes change 1a, design.md Decision 3, amended by
/// Security (plan) C26): the same durable bound as
/// `WorldRecord.nextEntityId`'s own decode-time clamp, so an id at the very
/// edge of the reservable range can never itself become unreservable.
let entityIdAdoptionRange: ClosedRange<Int> = 1...(Int.max - 1_000_000)

/// `true` only when `v` is a JSON *integer* token (never a float/bool/string)
/// bridged through `JSONSerialization`, in `entityIdAdoptionRange` — a
/// non-integer, out-of-range, or absent `"id"` makes the row "legacy"
/// (Security (plan) C26: "adopts 'id' only as an integer-typed JSON number").
private func integerEntityId(_ v: Any?) -> Int? {
    guard let number = v as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          !CFNumberIsFloatType(number)
    else { return nil }
    let value = number.int64Value
    guard Double(value) == number.doubleValue else { return nil } // precision-loss guard
    guard value >= 1, value <= Int64(entityIdAdoptionRange.upperBound) else { return nil }
    return Int(value)
}

public func loadEntity(_ world: World, _ d: [String: Any]) -> Entity? {
    guard let type = d["type"] as? String, let e = createEntity(type, world) else { return nil }
    e.load(d)
    let mintedId = e.id
    if let persistedId = integerEntityId(d["id"]) {
        if world.entityById[persistedId] != nil {
            // Live collision (corrupt/hand-edited record): keep the freshly
            // minted id and log a diagnostic — never double-assign one.
            print("[scripting] entity id \(persistedId) is already live; keeping minted id \(mintedId)")
        } else {
            e.adoptPersistedId(persistedId)
            e.reclaimEntityId(mintedId)
            e.bumpEntityIdCounter(past: persistedId)
        }
    }
    // Legacy rows (no "id") keep their adoption-order id; the record carries
    // "id" after the chunk's next save.
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
        // Sky-world wildlife replenishes only through the saved dawn
        // scheduler. Dimensions without a sunrise retain their historical
        // cadence; in particular Nether striders must not stop spawning.
        ("creature", 18, !world.info.hasSky && world.time % 100 == 0),
        ("ambient", 15, !world.info.hasSky && world.time % 400 == 0),
        ("water", 5, !world.info.hasSky && world.time % 400 == 0),
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
        let list: [SpawnEntry]
        if let profile = world.generationSettings.preset.prehistoricProfile {
            // A prehistoric profile owns its entire natural-population domain:
            // no modern passive animals and no ordinary fantasy/night-monster
            // table. Predatory roster members provide its host-owned danger.
            // The ordinary branch below stays byte-for-byte isolated for every
            // non-prehistoric save.
            list = cat == "monster" ? [] : prehistoricSpawnEntries(profile: profile, category: cat)
        } else {
            list = cat == "monster" ? bdef.monsters
                : cat == "creature" ? bdef.creatures
                : cat == "water" ? bdef.waterCreatures
                : bdef.ambient
        }
        if list.isEmpty { continue }
        let entry = rng.pickWeighted(list) { $0.weight }
        let mobType = entry.mob, minPack = entry.minPack, maxPack = entry.maxPack

        // spawn conditions
        if !canSpawnAt(world, mobType, cat, x, y, z, &rng) { continue }
        // pack spawn
        let pack = minPack + rng.nextInt(Swift.max(1, maxPack - minPack + 1))
        var spawned = 0
        for packOrdinal in 0..<pack {
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
            let controllerSalt: UInt32?
            if PrehistoricCreatureDefinition.named(mobType) != nil {
                controllerSalt = hash3(
                    world.seed ^ hashString(mobType), x, y, z,
                    UInt32(truncatingIfNeeded: world.time) ^ UInt32(packOrdinal + 1)
                )
            } else {
                controllerSalt = nil
            }
            let mob = spawnMob(world, mobType, Double(px) + 0.5, Double(py), Double(pz) + 0.5,
                               SpawnOpts(prehistoricSeedSalt: controllerSalt))
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
        guard atId == Int(B.water) else { return false }
        if let definition = PrehistoricCreatureDefinition.named(mobType) {
            return prehistoricAquaticNaturalSpawnHasOpenWaterAdmission(
                world, definition: definition, x: x, y: y, z: z
            )
        }
        return true
    }
    // land mobs never spawn inside fluids (water is "replaceable" and slipped
    // through — zombies and chickens were spawning in the ocean). Water-filled
    // flora counts as water too: underwater tall seagrass on a sand seabed is
    // replaceable and was admitting land animals and monsters into the sea.
    if atId == Int(B.water) || atId == Int(B.lava) { return false }
    let headId = world.getBlock(x, y + 1, z) >> 4
    if headId == Int(B.water) { return false }
    if spawnPlacementCellIsWater(world, x, y, z) || spawnPlacementCellIsWater(world, x, y + 1, z) { return false }
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
        let permittedGround = below == Int(B.grass_block) || below == Int(B.sand)
            || below == Int(B.snow_block) || below == Int(B.mycelium)
            || below == Int(B.podzol) || !world.info.hasSky
        guard permittedGround else { return false }
        if let definition = PrehistoricCreatureDefinition.named(mobType) {
            return prehistoricHasClearance(world, definition: definition, x: x, y: y, z: z, requireGround: true)
        }
        return true
    }
    if let definition = PrehistoricCreatureDefinition.named(mobType) {
        // Flyers enter from a clear, grounded launch site; the profile's air
        // controller owns takeoff after spawning rather than phasing in sky.
        return prehistoricHasClearance(world, definition: definition, x: x, y: y, z: z, requireGround: true)
    }
    return true
}

// =============================================================================
// Spawn placement
// =============================================================================

/// Where a spawned body belongs with respect to water. Only aquatic creatures
/// may be put into water; everything that lives on land is kept out of it.
public enum SpawnPlacementMedium: Equatable, Sendable {
    /// Must be placed in water: fish, squid, dolphins, guardians, axolotls,
    /// tadpoles and the prehistoric aquatic roster.
    case water
    /// Must keep its whole body out of water, lava and water-filled flora.
    case land
    /// At home in or out of water (drowned, turtles, frogs): only lava and
    /// solid obstruction are refused.
    case amphibious
    /// Not a creature at all (boats, minecarts, end crystals): no fluid rule.
    case object
}

/// Ordinary (non-prehistoric) mobs that live in water. Membership lookups only.
let ORDINARY_AQUATIC_MOBS: Set<String> = [
    "squid", "glow_squid", "cod", "salmon", "tropical_fish", "pufferfish",
    "dolphin", "axolotl", "guardian", "elder_guardian", "tadpole",
]
/// Ordinary mobs equally at home in water and on land.
let AMPHIBIOUS_MOBS: Set<String> = ["drowned", "turtle", "frog"]
/// Spawnable entity types that are objects rather than creatures.
let NON_CREATURE_SPAWN_TYPES: Set<String> = ["boat", "minecart", "end_crystal"]

public func spawnPlacementMedium(forMob mobType: String) -> SpawnPlacementMedium {
    if let definition = PrehistoricCreatureDefinition.named(mobType) {
        return definition.medium == .aquatic ? .water : .land
    }
    if ORDINARY_AQUATIC_MOBS.contains(mobType) { return .water }
    if AMPHIBIOUS_MOBS.contains(mobType) { return .amphibious }
    if NON_CREATURE_SPAWN_TYPES.contains(mobType) { return .object }
    return .land
}

/// Water or water-filled flora (seagrass, kelp, coral, sea pickles).
func spawnPlacementCellIsWater(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    let cell = world.getBlock(x, y, z)
    guard cell >= 0, cell <= Int(UInt16.max) else { return false }
    return isWaterlogged(UInt16(cell))
}

/// Water, water-filled flora, or lava.
func spawnPlacementCellIsFluid(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    spawnPlacementCellIsWater(world, x, y, z) || world.getBlock(x, y, z) >> 4 == Int(B.lava)
}

/// True when a two-cell ordinary body standing at (x, y, z) has its feet or
/// head in water, water-filled flora or lava. This is the fluid part of
/// `spawnPlacementIsValid` alone, for callers such as generated structure
/// occupants whose authored cell may legitimately hold a non-replaceable block.
func spawnBodyTouchesFluid(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    spawnPlacementCellIsFluid(world, x, y, z) || spawnPlacementCellIsFluid(world, x, y + 1, z)
}

/// The one shared, RNG-free placement rule for direct spawn paths (raid waves,
/// patrols, the AI companion's summon). Aquatic creatures go only into water;
/// land creatures keep their body out of water, lava and water-filled flora
/// and may not stand directly on water; prehistoric creatures additionally
/// need their whole-body clearance (`prehistoricHasClearance`, grounded for
/// land and air). Unlike `canSpawnAt` it has no biome, light or ground-type
/// rule and never draws randomness, so routing a caller through it cannot
/// perturb any RNG stream.
public func spawnPlacementIsValid(_ world: World, _ mobType: String, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    guard y > world.info.minY, y + 1 < world.info.minY + world.info.height,
          world.isLoadedAt(x, z) else { return false }
    if let definition = PrehistoricCreatureDefinition.named(mobType) {
        return prehistoricHasClearance(world, definition: definition, x: x, y: y, z: z,
                                       requireGround: definition.medium != .aquatic)
    }
    // Body cells must not be solid. A non-solid plant (a flower, tall grass)
    // is a fine place to stand; callers wanting a stricter open-cell rule
    // (the AI companion requires a replaceable foot cell) check it themselves.
    func open(_ id: Int) -> Bool { id == 0 || (id > 0 && id < blockDefs.count && !blockDefs[id].solid) }
    let feet = world.getBlock(x, y, z) >> 4
    let head = world.getBlock(x, y + 1, z) >> 4
    switch spawnPlacementMedium(forMob: mobType) {
    case .water:
        return spawnPlacementCellIsWater(world, x, y, z)
    case .land:
        if spawnBodyTouchesFluid(world, x, y, z) { return false }
        // standing directly on water would drop the body straight into it
        if spawnPlacementCellIsWater(world, x, y - 1, z) { return false }
        return open(feet) && open(head)
    case .amphibious, .object:
        if feet == Int(B.lava) || head == Int(B.lava) { return false }
        return open(feet) && open(head)
    }
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
