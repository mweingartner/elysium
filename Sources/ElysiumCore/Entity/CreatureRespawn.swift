// Bounded, host-owned dawn replenishment. Initial chunk populations and
// ordinary hostile spawning remain in their established generation paths.

import Foundation

/// Small diagnostics value for tests and native inspection, not persistent
/// authority. The saved dawn scheduler owns eligibility and replay prevention.
public struct CreatureRespawnReport: Equatable, Sendable {
    public internal(set) var candidateAttempts = 0
    public internal(set) var siteAdmissionChecks = 0
    public internal(set) var creaturesSpawned = 0
    public internal(set) var ambientSpawned = 0
    public internal(set) var waterSpawned = 0
    public var totalSpawned: Int { creaturesSpawned + ambientSpawned + waterSpawned }
}

/// Select a diet-specific roster. Dawn uses the live local population to aim
/// for two herbivores per predator; complete pods replace isolated births.
func prehistoricDawnLandEntries(profile: PrehistoricWorldProfile, sequence: Int) -> [SpawnEntry] {
    let wantsHerbivore = sequence != 2
    return prehistoricSpawnEntries(profile: profile, category: "creature").filter { entry in
        // Chickens refill with the herbivores, one bird per pick, so hunted flocks recover.
        if entry.mob == PREHISTORIC_CHICKEN_MOB { return wantsHerbivore }
        guard let definition = PrehistoricCreatureDefinition.named(entry.mob) else { return false }
        return wantsHerbivore ? definition.isLandHerdHerbivore : definition.isLandPredator
    }
}

/// Horizontal radius, in blocks, of a prehistoric world's dawn census. Only
/// living mobs this close to an eligible player occupy a refill vacancy. It
/// covers the 104-block maximum sampling distance plus the largest body, so a
/// crowded refill area still reads as full, while dinosaurs parked in the
/// outer loaded ring (which never tick beyond the 96-block simulation radius)
/// no longer hold every slot and starve the region around the player.
let PREHISTORIC_DAWN_CENSUS_RADIUS = 128.0

/// Whether `mob` counts against a dawn refill's category caps. Ordinary worlds
/// keep the historical whole-loaded-world census; prehistoric profiles count
/// only the population local to an eligible player. Pure distance arithmetic:
/// no RNG and no dependence on entity order.
func dawnCensusCounts(_ mob: Mob, prehistoric: Bool, players: [Entity]) -> Bool {
    guard prehistoric else { return true }
    return players.contains { dawnCensusIncludes(x: mob.x, z: mob.z, around: $0) }
}

/// Whether a position lies in one eligible player's prehistoric census neighbourhood.
func dawnCensusIncludes(x: Double, z: Double, around player: Entity) -> Bool {
    let dx = x - player.x, dz = z - player.z
    return dx * dx + dz * dz <= PREHISTORIC_DAWN_CENSUS_RADIUS * PREHISTORIC_DAWN_CENSUS_RADIUS
}

/// Refill vacancies at one eligible dawn, with no debt carried into daytime.
/// Ordinary maps have at most 128 site candidates and 38 births; dinosaur maps
/// have 256 candidates, 48/30/10 local category caps, and a shared 1024-check
/// land placement budget (including complete herbivore pods). The caller
/// persists the consumed dawn and `creatureRespawnSequence`; this function
/// never derives a schedule from real time or renderer frame rate.
///
/// Players are Entities so authoritative LAN player proxies can participate
/// without creating fake Player instances. Callers retain authority over which
/// peers are active; this boundary additionally rejects dead/non-player/mirror
/// world inputs. Ancient Seas has no land-dinosaur table, so its genuine
/// air/water roster remains eligible without inventing herbivorous sea reptiles.
@discardableResult
public func replenishCreaturesAtDawn(
    _ world: World, _ players: [Entity], _ rng: inout RandomX
) -> CreatureRespawnReport {
    var report = CreatureRespawnReport()
    guard world.info.hasSky, !world.isTransientLANClient,
          world.rule("doMobSpawning"), (0..<1_000).contains(world.dayTime) else { return report }
    let eligiblePlayers = players.filter {
        $0.world === world && $0.isPlayer && !$0.dead
            && (($0 as? LivingEntity)?.health ?? 0) > 0
            && $0.x.isFinite && $0.y.isFinite && $0.z.isFinite
            && abs($0.x) < 30_000_000 && abs($0.z) < 30_000_000
    }
    guard !eligiblePlayers.isEmpty else { return report }

    let profile = world.generationSettings.preset.prehistoricProfile
    // Ordinary worlds keep one whole-loaded-world count per category. Prehistoric worlds keep
    // one count per eligible player's neighbourhood, so a saturated region around one LAN
    // player cannot use up the vacancies of another player's separate region.
    var counts: [String: Int] = [:]
    var localCounts: [[String: Int]] = Array(repeating: [:], count: eligiblePlayers.count)
    var herbivores = Array(repeating: 0, count: eligiblePlayers.count)
    var predators = Array(repeating: 0, count: eligiblePlayers.count)
    for entity in world.entities {
        guard let mob = entity as? Mob, !mob.dead, mob.health > 0 else { continue }
        guard profile != nil else { counts[mob.category, default: 0] += 1; continue }
        for (index, player) in eligiblePlayers.enumerated() where dawnCensusIncludes(x: mob.x, z: mob.z, around: player) {
            localCounts[index][mob.category, default: 0] += 1
            if let dinosaur = mob as? PrehistoricCreature {
                if dinosaur.definition.isLandHerdHerbivore { herbivores[index] += 1 }
                if dinosaur.definition.isLandPredator { predators[index] += 1 }
            }
        }
    }
    func saturated(_ category: String, cap: Int) -> Bool {
        profile == nil ? counts[category, default: 0] >= cap
            : localCounts.allSatisfy { $0[category, default: 0] >= cap }
    }
    let categories: [(name: String, cap: Int, budget: Int)] = profile == nil
        ? [("creature", 18, 64), ("ambient", 15, 32), ("water", 5, 32)]
        : [("creature", 48, 128), ("ambient", 30, 64), ("water", 10, 64)]
    var landChecks = 0
    for category in categories {
        // An empty fixed profile table needs no positions, clearance probes,
        // or RNG draws. The ordinary biome table is selected at each site.
        if let profile, prehistoricSpawnEntries(profile: profile, category: category.name).isEmpty {
            continue
        }
        for _ in 0..<category.budget {
            if saturated(category.name, cap: category.cap) { break }
            report.candidateAttempts += 1
            let playerIndex = rng.nextInt(eligiblePlayers.count)
            let player = eligiblePlayers[playerIndex]
            if profile != nil, localCounts[playerIndex][category.name, default: 0] >= category.cap { continue }
            let distance = 24 + rng.nextFloat() * 80
            let angle = rng.nextFloat() * .pi * 2
            let x = ifloor(player.x + detCos(angle) * distance)
            let z = ifloor(player.z + detSin(angle) * distance)
            guard world.isLoadedAt(x, z), dawnSpawnInsidePlayableBoundary(world, x: x, z: z) else { continue }
            let y: Int
            if category.name == "water" {
                y = world.surfaceY(x, z)
            } else {
                guard let ground = world.dryGroundY(x, z) else { continue }
                y = ground
            }
            // Checking every active player also keeps a host-centred wave
            // from appearing directly on top of a nearby LAN guest.
            guard !eligiblePlayers.contains(where: {
                let dx = $0.x - (Double(x) + 0.5), dy = $0.y - Double(y), dz = $0.z - (Double(z) + 0.5)
                return dx * dx + dy * dy + dz * dz < 24 * 24
            }) else { continue }
            let entries: [SpawnEntry]
            if let profile {
                entries = category.name == "creature"
                    ? prehistoricDawnLandEntries(profile: profile, sequence:
                        herbivores[playerIndex] < 2 * max(1, predators[playerIndex])
                        && category.cap - localCounts[playerIndex][category.name, default: 0] >= 8 ? 0 : 2)
                    : prehistoricSpawnEntries(profile: profile, category: category.name)
            } else {
                let biomeID = world.biomeAt(x, y, z)
                guard BIOMES.indices.contains(biomeID), let biome = BIOMES[biomeID] else { continue }
                entries = category.name == "creature" ? biome.creatures
                    : category.name == "water" ? biome.waterCreatures : biome.ambient
            }
            guard !entries.isEmpty else { continue }
            let entry = rng.pickWeighted(entries) { $0.weight }
            let definition = PrehistoricCreatureDefinition.named(entry.mob)
            let isPod = profile != nil && definition?.isLandHerdHerbivore == true
            let remaining = profile == nil ? 1 : category.cap - localCounts[playerIndex][category.name, default: 0]
            let target = isPod ? min(remaining, 8 + rng.nextInt(3)) : 1
            var sites: [(x: Int, y: Int, z: Int)] = []
            for attempt in 0..<(isPod ? 96 : 1) {
                if sites.count == target { break }
                if profile != nil && category.name == "creature" {
                    if landChecks >= 1024 { break }
                    landChecks += 1
                }
                let px = isPod && attempt > 0 ? x + rng.nextInt(25) - 12 : x
                let pz = isPod && attempt > 0 ? z + rng.nextInt(25) - 12 : z
                guard world.isLoadedAt(px, pz), dawnSpawnInsidePlayableBoundary(world, x: px, z: pz) else { continue }
                let py: Int
                if isPod {
                    guard let ground = world.dryGroundY(px, pz) else { continue }
                    py = ground
                } else { py = y }
                guard !eligiblePlayers.contains(where: {
                    let dx = $0.x - (Double(px)+0.5), dy = $0.y - Double(py), dz = $0.z - (Double(pz)+0.5)
                    return dx*dx + dy*dy + dz*dz < 24*24
                }) else { continue }
                // Keep every pod inside its owner's census and reserve slots in
                // every overlapping player's region, not just the sampled one.
                if profile != nil {
                    guard dawnCensusIncludes(x: Double(px)+0.5, z: Double(pz)+0.5, around: player) else { continue }
                    let full = eligiblePlayers.enumerated().contains { index, other in
                        guard dawnCensusIncludes(x: Double(px)+0.5, z: Double(pz)+0.5, around: other) else { return false }
                        let reserved = sites.filter { dawnCensusIncludes(x: Double($0.x)+0.5, z: Double($0.z)+0.5, around: other) }.count
                        return localCounts[index][category.name, default: 0] + reserved >= category.cap
                    }
                    if full { continue }
                }
                if isPod {
                    let spacing = max(2, (definition?.collisionWidth ?? 1) + 0.5)
                    if sites.contains(where: { abs(Double($0.x-px)) < spacing && abs(Double($0.z-pz)) < spacing }) { continue }
                }
                report.siteAdmissionChecks += 1
                guard canSpawnAt(world, entry.mob, category.name, px, py, pz, &rng) else { continue }
                sites.append((px, py, pz))
            }
            if isPod && sites.count < 8 { continue }
            for (ordinal, site) in sites.enumerated() {
                let salt: UInt32? = definition.map { _ in
                    hash3(world.seed ^ hashString(entry.mob), site.x, site.y, site.z,
                          UInt32(truncatingIfNeeded: world.time) ^ UInt32(report.candidateAttempts * 16 + ordinal))
                }
                guard spawnMob(world, entry.mob, Double(site.x) + 0.5, Double(site.y), Double(site.z) + 0.5,
                               SpawnOpts(prehistoricSeedSalt: salt)) != nil else { continue }
                if profile == nil {
                    counts[category.name, default: 0] += 1
                } else {
                    for (index, other) in eligiblePlayers.enumerated()
                        where dawnCensusIncludes(x: Double(site.x) + 0.5, z: Double(site.z) + 0.5, around: other) {
                        localCounts[index][category.name, default: 0] += 1
                        if definition?.isLandHerdHerbivore == true { herbivores[index] += 1 }
                        if definition?.isLandPredator == true { predators[index] += 1 }
                    }
                }
                switch category.name {
                case "creature":
                    report.creaturesSpawned += 1
                    if profile != nil {
                        world.creatureRespawnSequence = (max(0, min(2, world.creatureRespawnSequence)) + 1) % 3
                    }
                case "ambient": report.ambientSpawned += 1
                default: report.waterSpawned += 1
                }
            }
        }
    }
    return report
}

private func dawnSpawnInsidePlayableBoundary(_ world: World, x: Int, z: Int) -> Bool {
    if let bound = world.playableMinX, x < bound { return false }
    if let bound = world.playableMaxX, x > bound { return false }
    if let bound = world.playableMinZ, z < bound { return false }
    if let bound = world.playableMaxZ, z > bound { return false }
    return true
}
