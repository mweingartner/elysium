// Prehistoric starter shelter — deterministic, version-two spawn safety.
//
// The shelter is part of terrain generation rather than a runtime placement:
// a local host, a LAN client, and a resumed world therefore derive the same
// blocks, block entity, spawn position, and nearby wood from immutable world
// inputs. Version-one prehistoric saves never call this file's public entry
// points, preserving their established terrain contract.

import Foundation

public struct PrehistoricStarterShelterPosition: Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let z: Int

    public init(x: Int, y: Int, z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Complete deterministic placement data for the version-two prehistoric
/// starter shelter. The public coordinates make the spawn contract testable
/// without duplicating layout constants in lifecycle code or tests.
public struct PrehistoricStarterShelterSite: Equatable, Sendable {
    public let spawn: PrehistoricStarterShelterPosition
    /// Ancient Seas and any pathological seed use a raised dry platform. The
    /// ordinary land profiles normally select a dry, level natural pad.
    public let usesRaisedPlatform: Bool

    public init(spawn: PrehistoricStarterShelterPosition, usesRaisedPlatform: Bool) {
        self.spawn = spawn
        self.usesRaisedPlatform = usesRaisedPlatform
    }

    public var x: Int { spawn.x }
    public var y: Int { spawn.y }
    public var z: Int { spawn.z }

    public var bedFoot: PrehistoricStarterShelterPosition {
        .init(x: x + 1, y: y, z: z)
    }

    public var bedHead: PrehistoricStarterShelterPosition {
        .init(x: x + 1, y: y, z: z + 1)
    }

    public var craftingStation: PrehistoricStarterShelterPosition {
        .init(x: x - 1, y: y, z: z + 1)
    }

    public var chest: PrehistoricStarterShelterPosition {
        .init(x: x - 1, y: y, z: z)
    }

    /// Eight fixed oak trees mean every new prehistoric spawn has forty
    /// trunk logs before counting naturally generated forest nearby.
    public var woodGroveRoots: [PrehistoricStarterShelterPosition] {
        PrehistoricStarterShelterLayout.groveOffsets.map { offset in
            .init(x: x + offset.x, y: y, z: z + offset.z)
        }
    }

    /// Keep deterministic bootstrap mobs out of the house and immediate
    /// doorway clearing. Trees deliberately sit outside this safety zone.
    public func containsProtectedSpawnColumn(_ columnX: Int, _ columnZ: Int) -> Bool {
        abs(columnX - x) <= 5 && abs(columnZ - z) <= 5
    }

    /// The full roof/canopy extent, used to avoid doing any shelter work for
    /// a chunk that cannot receive a clipped write.
    public func intersectsGeneratedExtent(chunkX: Int, chunkZ: Int) -> Bool {
        let chunkX0 = chunkX * CHUNK_W
        let chunkZ0 = chunkZ * CHUNK_W
        let chunkX1 = chunkX0 + CHUNK_W - 1
        let chunkZ1 = chunkZ0 + CHUNK_W - 1
        return chunkX0 <= x + 12 && chunkX1 >= x - 12
            && chunkZ0 <= z + 12 && chunkZ1 >= z - 12
    }
}

private enum PrehistoricStarterShelterLayout {
    /// Kept in a fixed source order: it is part of the visible wood-grove
    /// layout, not a collection whose iteration may vary across processes.
    static let groveOffsets: [(x: Int, z: Int)] = [
        (-10, -8), (-10, 0), (-10, 8), (0, -10),
        (0, 10), (10, -8), (10, 0), (10, 8),
    ]
}

private struct PrehistoricStarterShelterCacheKey: Hashable {
    let seed: UInt32
    let generationSettingsIdentity: String
}

/// The cache only avoids repeating an expensive pure terrain survey. It is
/// bounded and locked; an eviction or a concurrent miss cannot change the
/// resulting site because each calculation reads the same immutable inputs.
private var prehistoricStarterShelterCache: [PrehistoricStarterShelterCacheKey: PrehistoricStarterShelterSite] = [:]
private var prehistoricStarterShelterCacheOrder: [PrehistoricStarterShelterCacheKey] = []
private let prehistoricStarterShelterCacheLock = NSLock()
private let prehistoricStarterShelterCacheLimit = 128

/// Returns the exact v2 prehistoric spawn/shelter placement, or `nil` for a
/// non-prehistoric or compatibility-v1 world.
public func prehistoricStarterShelterSite(seed: UInt32,
                                          settings: WorldGenerationSettings) -> PrehistoricStarterShelterSite? {
    guard settings.preset.supportsStarterShelter else { return nil }
    let key = PrehistoricStarterShelterCacheKey(seed: seed,
                                                generationSettingsIdentity: settings.cacheIdentity)
    if let cached = prehistoricStarterShelterCacheLock.withLock({
        prehistoricStarterShelterCache[key]
    }) {
        return cached
    }

    let computed = computePrehistoricStarterShelterSite(seed: seed, settings: settings)
    return prehistoricStarterShelterCacheLock.withLock {
        if let cached = prehistoricStarterShelterCache[key] { return cached }
        if prehistoricStarterShelterCache.count >= prehistoricStarterShelterCacheLimit,
           let evicted = prehistoricStarterShelterCacheOrder.first {
            prehistoricStarterShelterCacheOrder.removeFirst()
            prehistoricStarterShelterCache.removeValue(forKey: evicted)
        }
        prehistoricStarterShelterCache[key] = computed
        prehistoricStarterShelterCacheOrder.append(key)
        return computed
    }
}

private func computePrehistoricStarterShelterSite(seed: UInt32,
                                                   settings: WorldGenerationSettings) -> PrehistoricStarterShelterSite {
    let info = DIMS[Dim.overworld.rawValue]
    let seaLevel = info.seaLevel
    let maximumFloorY = info.minY + info.height - 6
    // A v2 shelter must fit with its entire grove inside even a Small map,
    // whose default playable extent is -500...499 around the origin. World
    // creation has not yet chosen a map-size-specific spawn API, so keep this
    // pure site selection safely within the smallest supported extent.
    let smallestMapHalfSide = WorldMapSize.small.sideBlocks / 2
    let smallestMapMinimum = -smallestMapHalfSide + 12
    let smallestMapMaximum = smallestMapHalfSide - 1 - 12
    let generator = overworldGen(seed, settings: settings)
    // This bounded exact oracle is separate from normal structure planning so
    // chunk-generation order cannot affect the chosen spawn site.
    let oracle = BaseTerrainOracle(seed: seed, settings: settings,
                                   maxCachedChunks: 192, maxQueries: 4_096)

    for index in 0..<40 {
        let approximateX = 8 + index * 40
        let approximateZ = 8 + ((index * 13) % 7 - 3) * 40
        // A chunk-centred hut keeps the complete building and its chest in a
        // predictable generated chunk, rather than straddling a chunk seam.
        let candidateX = floorDiv(approximateX, CHUNK_W) * CHUNK_W + CHUNK_W / 2
        let candidateZ = floorDiv(approximateZ, CHUNK_W) * CHUNK_W + CHUNK_W / 2
        guard candidateX >= smallestMapMinimum, candidateX <= smallestMapMaximum,
              candidateZ >= smallestMapMinimum, candidateZ <= smallestMapMaximum
        else { continue }
        let biome = generator.surfaceBiomeAt(Double(candidateX), Double(candidateZ))
        let estimate = generator.heightEstimate(Double(candidateX), Double(candidateZ))
        let biomeName = (BIOMES[Int(biome.rawValue)]?.name ?? "").lowercased()
        // Keep the same conservative inland preference as ordinary spawns;
        // exact terrain validation below is still authoritative.
        guard estimate > seaLevel + 2,
              !biomeName.contains("ocean"), !biomeName.contains("river"),
              !biomeName.contains("swamp"), !biomeName.contains("beach"),
              let feetY = exactStarterShelterPadY(oracle: oracle, x: candidateX, z: candidateZ),
              feetY <= maximumFloorY
        else { continue }
        return PrehistoricStarterShelterSite(
            spawn: .init(x: candidateX, y: max(seaLevel + 4, feetY), z: candidateZ),
            usesRaisedPlatform: false
        )
    }

    // Ancient Seas intentionally has no dependable dry inland surface. A
    // raised platform keeps that profile playable without making its oceanic
    // terrain pretend to be land. The same bounded fallback also makes an
    // extreme terrain seed safe instead of failing world creation.
    let fallbackX = CHUNK_W / 2
    let fallbackZ = CHUNK_W / 2
    let fallbackFeetY = oracle.exactSurface(fallbackX, fallbackZ)?.feetY ?? seaLevel + 4
    let floorY = min(max(seaLevel + 4, fallbackFeetY), maximumFloorY)
    return PrehistoricStarterShelterSite(
        spawn: .init(x: fallbackX, y: floorY, z: fallbackZ),
        usesRaisedPlatform: true
    )
}

/// A dry, low-variation seven-by-seven pad gives the hut a real ground
/// connection in land profiles. The raised-platform fallback handles the
/// deliberately water-heavy profile and any candidate that cannot meet this
/// physical validation.
private func exactStarterShelterPadY(oracle: BaseTerrainOracle, x: Int, z: Int) -> Int? {
    var low: Int?
    var high: Int?
    // Include the north porch/door approach, not only the sealed room. A
    // perfectly level interior is not useful if a terrain lip or tree fills
    // the first cell outside the paired door.
    for dz in -4...3 {
        for dx in -3...3 {
            guard let surface = oracle.exactSurface(x + dx, z + dz), surface.isDry else {
                return nil
            }
            low = min(low ?? surface.feetY, surface.feetY)
            high = max(high ?? surface.feetY, surface.feetY)
        }
    }
    guard let low, let high, high - low <= 2 else { return nil }
    return high
}

/// Final worldgen stamp for the deterministic shelter. Call this after
/// vegetation and snow so the physical safety envelope is never re-filled by
/// a feature pass. `ChunkSink` clips every write, allowing all chunks touched
/// by the roof and grove to replay this same fixed layout safely.
public func stampPrehistoricStarterShelter(seed: UInt32, settings: WorldGenerationSettings,
                                           sink: ChunkSink) {
    guard let site = prehistoricStarterShelterSite(seed: seed, settings: settings),
          site.intersectsGeneratedExtent(chunkX: sink.cx, chunkZ: sink.cz)
    else { return }

    let builder = Builder(sink, Rng(seed ^ 0x5350_A11E))
    let planks = Int(cell(B.oak_planks))
    let log = Int(cell(B.oak_log))
    let stone = Int(cell(B.cobblestone))
    let dirt = Int(cell(B.dirt))
    let glass = Int(cell(B.glass_pane))

    if site.usesRaisedPlatform {
        // Ancient Seas can legitimately have no dry island in the bounded
        // search region. Make its fallback a connected, supported deck rather
        // than isolated single-column piers: the player can leave the hut and
        // walk to every guaranteed tree without swimming or jumping gaps.
        for dz in -10...10 {
            for dx in -10...10 {
                let px = site.x + dx, pz = site.z + dz
                builder.foundation(px, site.y - 1, pz, stone, 96)
                builder.clear(px, site.y, pz, px, site.y + 2, pz)
                builder.set(px, site.y - 1, pz, planks)
            }
        }
    }

    // Seven-square closed shell, with a one-block floor and a full roof.
    // Clearing three body blocks first makes the fallback dry even when it
    // begins above water, and removes any pre-existing foliage on a land pad.
    for dz in -3...3 {
        for dx in -3...3 {
            let px = site.x + dx, pz = site.z + dz
            builder.foundation(px, site.y - 1, pz, stone, 96)
            builder.clear(px, site.y, pz, px, site.y + 3, pz)
            builder.set(px, site.y - 1, pz, planks)
        }
    }
    for h in 0..<3 {
        for dz in -3...3 {
            for dx in -3...3 where abs(dx) == 3 || abs(dz) == 3 {
                builder.set(site.x + dx, site.y + h, site.z + dz, planks)
            }
        }
    }
    for (dx, dz) in [(-3, -3), (3, -3), (-3, 3), (3, 3)] {
        for h in 0..<3 { builder.set(site.x + dx, site.y + h, site.z + dz, log) }
    }
    // A four-block overhang makes the roof visibly complete from outside.
    builder.fill(site.x - 4, site.y + 3, site.z - 4,
                 site.x + 4, site.y + 3, site.z + 4, planks)
    for (dx, dz) in [(0, -3), (-3, 0), (3, 0), (0, 3)] {
        builder.set(site.x + dx, site.y + 1, site.z + dz, glass)
    }

    // Front faces north (-Z). The paired upper door and paired bed head are
    // explicit multi-block cells, just like the established village houses.
    builder.set(site.x, site.y, site.z - 3, Int(cell(B.oak_door, 0)))
    builder.set(site.x, site.y + 1, site.z - 3, Int(cell(B.oak_door, 8)))
    // A three-wide clear porch guarantees a physically usable exit. It also
    // joins the raised-ocean deck when the fallback site is used.
    for dx in -1...1 {
        let px = site.x + dx, pz = site.z - 4
        builder.foundation(px, site.y - 1, pz, stone, 96)
        builder.clear(px, site.y, pz, px, site.y + 2, pz)
        builder.set(px, site.y - 1, pz, planks)
    }
    builder.foundation(site.x, site.y - 2, site.z - 4, stone, 96)
    builder.set(site.x, site.y - 1, site.z - 4, Int(cell(B.oak_stairs, FACE_OPP[0])))

    let bedFoot = site.bedFoot
    let bedHead = site.bedHead
    builder.set(bedFoot.x, bedFoot.y, bedFoot.z, Int(cell(B.red_bed, 1)))
    builder.set(bedHead.x, bedHead.y, bedHead.z, Int(cell(B.red_bed, 1 | 4)))
    let crafting = site.craftingStation
    builder.set(crafting.x, crafting.y, crafting.z, Int(cell(B.crafting_table)))
    let chest = site.chest
    builder.set(chest.x, chest.y, chest.z, Int(cell(B.chest, 0)))
    // Omit a coordinate-only `Builder.chest` seed: GameCore combines the
    // world seed with this position, so each world gets deterministic but
    // genuinely different small starter supplies.
    sink.addBlockEntity(BESpec(x: chest.x, y: chest.y, z: chest.z, kind: "chest_loot",
                               data: ["lootTable": .str("prehistoric_starter")]))
    builder.set(site.x - 1, site.y + 1, site.z - 1, Int(cell(B.torch)))
    builder.set(site.x + 1, site.y + 1, site.z - 1, Int(cell(B.torch)))

    // Eight short oak trees provide at least forty directly harvestable logs
    // and a clear visual signal that the hut has a renewable wood supply.
    for root in site.woodGroveRoots {
        stampPrehistoricStarterOak(root, builder: builder, support: stone, dirt: dirt)
    }
}

private func stampPrehistoricStarterOak(_ root: PrehistoricStarterShelterPosition,
                                        builder: Builder, support: Int, dirt: Int) {
    builder.foundation(root.x, root.y - 1, root.z, support, 96)
    builder.set(root.x, root.y - 1, root.z, dirt)
    builder.clear(root.x - 2, root.y, root.z - 2, root.x + 2, root.y + 6, root.z + 2)
    let log = Int(cell(B.oak_log))
    let leaves = Int(cell(B.oak_leaves, 4))
    for height in 0..<5 { builder.set(root.x, root.y + height, root.z, log) }
    for height in 3...4 {
        for dz in -2...2 {
            for dx in -2...2 where !(dx == 0 && dz == 0) {
                builder.set(root.x + dx, root.y + height, root.z + dz, leaves)
            }
        }
    }
    for dz in -1...1 {
        for dx in -1...1 {
            builder.set(root.x + dx, root.y + 5, root.z + dz, leaves)
        }
    }
}
