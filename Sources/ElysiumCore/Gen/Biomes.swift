// Every biome: climate selection, surface rules, colors, features, spawns.
// Enum order and climate thresholds are pinned by the frozen golden baselines.

import Foundation

public enum Biome: Int, CaseIterable {
    case ocean = 0, deepOcean, frozenOcean, deepFrozenOcean, coldOcean, deepColdOcean
    case lukewarmOcean, deepLukewarmOcean, warmOcean
    case river, frozenRiver, beach, snowyBeach, stonyShore
    case plains, sunflowerPlains, snowyPlains, iceSpikes, desert
    case swamp, mangroveSwamp
    case forest, flowerForest, birchForest, oldGrowthBirchForest, darkForest
    case taiga, oldGrowthPineTaiga, oldGrowthSpruceTaiga, snowyTaiga
    case savanna, savannaPlateau, windsweptSavanna
    case windsweptHills, windsweptGravellyHills, windsweptForest
    case jungle, sparseJungle, bambooJungle
    case badlands, erodedBadlands, woodedBadlands
    case meadow, cherryGrove, grove, snowySlopes, jaggedPeaks, frozenPeaks, stonyPeaks
    case mushroomFields
    case dripstoneCaves, lushCaves, deepDark
    case netherWastes, crimsonForest, warpedForest, soulSandValley, basaltDeltas
    case theEnd, endHighlands, endMidlands, smallEndIslands, endBarrens
}

public typealias SpawnEntry = (mob: String, weight: Double, minPack: Int, maxPack: Int)

public final class BiomeDef {
    public let id: Biome
    public let name: String
    public let displayName: String
    public let temperature: Double
    public let downfall: Double
    public let grassColor: UInt32
    public let foliageColor: UInt32
    public let waterColor: UInt32
    public let fogTint: UInt32
    public let top: UInt16
    public let under: UInt16
    public let underwaterTop: UInt16
    public let features: [String]
    public let monsters: [SpawnEntry]
    public let creatures: [SpawnEntry]
    public let waterCreatures: [SpawnEntry]
    public let ambient: [SpawnEntry]
    public let mood: String

    init(id: Biome, name: String, temperature: Double, downfall: Double,
         grassColor: UInt32, foliageColor: UInt32, waterColor: UInt32, fogTint: UInt32,
         top: UInt16, under: UInt16, underwaterTop: UInt16,
         features: [String], monsters: [SpawnEntry], creatures: [SpawnEntry],
         waterCreatures: [SpawnEntry], ambient: [SpawnEntry], mood: String) {
        self.id = id; self.name = name
        displayName = name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        self.temperature = temperature; self.downfall = downfall
        self.grassColor = grassColor; self.foliageColor = foliageColor
        self.waterColor = waterColor; self.fogTint = fogTint
        self.top = top; self.under = under; self.underwaterTop = underwaterTop
        self.features = features; self.monsters = monsters; self.creatures = creatures
        self.waterCreatures = waterCreatures; self.ambient = ambient; self.mood = mood
    }
}

public var BIOMES: [BiomeDef?] = []

private var biomesRegistered = false

public func registerAllBiomes() {
    if biomesRegistered { return }
    biomesRegistered = true
    precondition(!blockDefs.isEmpty, "blocks must register first")

    BIOMES = [BiomeDef?](repeating: nil, count: Biome.allCases.count)

    let DEF_MONSTERS: [SpawnEntry] = [
        ("zombie", 95, 4, 4), ("skeleton", 100, 4, 4), ("creeper", 100, 4, 4),
        ("spider", 100, 4, 4), ("enderman", 10, 1, 4), ("witch", 5, 1, 1),
    ]
    let DEF_CREATURES: [SpawnEntry] = [
        ("sheep", 12, 4, 4), ("pig", 10, 4, 4), ("chicken", 10, 4, 4), ("cow", 8, 4, 4),
    ]
    let OCEAN_WATER: [SpawnEntry] = [("squid", 4, 1, 4), ("cod", 10, 3, 6), ("dolphin", 2, 1, 2)]
    let BAT_AMBIENT: [SpawnEntry] = [("bat", 10, 8, 8)]

    func biome(_ id: Biome, _ name: String, temperature: Double, downfall: Double,
               grassColor: UInt32 = 0x91bd59, foliageColor: UInt32 = 0x77ab2f,
               waterColor: UInt32 = 0x3f76e4, fogTint: UInt32 = 0xffffff,
               top: UInt16? = nil, under: UInt16? = nil, underwaterTop: UInt16? = nil,
               features: [String] = [],
               monsters: [SpawnEntry]? = nil, creatures: [SpawnEntry]? = nil,
               waterCreatures: [SpawnEntry] = [], ambient: [SpawnEntry]? = nil,
               mood: String = "overworld") {
        BIOMES[id.rawValue] = BiomeDef(
            id: id, name: name, temperature: temperature, downfall: downfall,
            grassColor: grassColor, foliageColor: foliageColor, waterColor: waterColor, fogTint: fogTint,
            top: top ?? cell(B.grass_block), under: under ?? cell(B.dirt), underwaterTop: underwaterTop ?? cell(B.dirt),
            features: features, monsters: monsters ?? DEF_MONSTERS, creatures: creatures ?? DEF_CREATURES,
            waterCreatures: waterCreatures, ambient: ambient ?? BAT_AMBIENT, mood: mood)
    }

    let GRASS_PATCH = "patch:short_grass:24"
    func TREES(_ kind: String, _ count: Int, _ extra: Double = 0.1) -> String { "trees:\(kind):\(count):\(extra)" }

    // oceans
    let oceanFeat = ["patch_water:seagrass:32", "kelp:6"]
    let gravel = cell(B.gravel), sand = cell(B.sand)
    biome(.ocean, "ocean", temperature: 0.5, downfall: 0.5, top: sand, under: sand, underwaterTop: sand, features: oceanFeat, waterCreatures: OCEAN_WATER, mood: "water")
    biome(.deepOcean, "deep_ocean", temperature: 0.5, downfall: 0.5, top: gravel, under: gravel, underwaterTop: gravel, features: oceanFeat, waterCreatures: OCEAN_WATER, mood: "water")
    biome(.frozenOcean, "frozen_ocean", temperature: 0.0, downfall: 0.5, waterColor: 0x3938c9, top: gravel, under: gravel, underwaterTop: gravel, features: ["iceberg:1"], creatures: [("polar_bear", 1, 1, 2)], waterCreatures: [("squid", 4, 1, 4), ("salmon", 15, 1, 5)], mood: "water")
    biome(.deepFrozenOcean, "deep_frozen_ocean", temperature: 0.0, downfall: 0.5, waterColor: 0x3938c9, top: gravel, under: gravel, underwaterTop: gravel, features: ["iceberg:2"], creatures: [("polar_bear", 1, 1, 2)], waterCreatures: [("squid", 4, 1, 4), ("salmon", 15, 1, 5)], mood: "water")
    biome(.coldOcean, "cold_ocean", temperature: 0.3, downfall: 0.5, waterColor: 0x3d57d6, top: gravel, under: gravel, underwaterTop: gravel, features: ["patch_water:seagrass:32", "kelp:10"], waterCreatures: [("squid", 4, 1, 4), ("cod", 15, 3, 6), ("salmon", 15, 1, 5)], mood: "water")
    biome(.deepColdOcean, "deep_cold_ocean", temperature: 0.3, downfall: 0.5, waterColor: 0x3d57d6, top: gravel, under: gravel, underwaterTop: gravel, features: ["patch_water:seagrass:32", "kelp:10"], waterCreatures: [("squid", 4, 1, 4), ("cod", 15, 3, 6), ("salmon", 15, 1, 5)], mood: "water")
    biome(.lukewarmOcean, "lukewarm_ocean", temperature: 0.6, downfall: 0.5, waterColor: 0x45adf2, top: sand, under: sand, underwaterTop: sand, features: ["patch_water:seagrass:48", "kelp:2", "sea_pickle:1"], waterCreatures: [("squid", 4, 1, 4), ("cod", 8, 3, 6), ("tropical_fish", 12, 4, 8), ("dolphin", 2, 1, 2), ("pufferfish", 5, 1, 3)], mood: "water")
    biome(.deepLukewarmOcean, "deep_lukewarm_ocean", temperature: 0.6, downfall: 0.5, waterColor: 0x45adf2, top: sand, under: sand, underwaterTop: sand, features: oceanFeat, waterCreatures: [("squid", 4, 1, 4), ("cod", 8, 3, 6), ("tropical_fish", 12, 4, 8), ("dolphin", 2, 1, 2)], mood: "water")
    biome(.warmOcean, "warm_ocean", temperature: 0.7, downfall: 0.5, waterColor: 0x43d5ee, top: sand, under: sand, underwaterTop: sand, features: ["coral_reef:8", "patch_water:seagrass:48", "sea_pickle:3"], waterCreatures: [("squid", 4, 1, 4), ("tropical_fish", 25, 4, 8), ("dolphin", 2, 1, 2), ("pufferfish", 15, 1, 3)], mood: "water")

    // rivers / shores
    biome(.river, "river", temperature: 0.5, downfall: 0.5, top: sand, under: sand, underwaterTop: sand, features: ["patch_water:seagrass:20", "sugar_cane:8", "clay_disk:1"], waterCreatures: [("squid", 2, 1, 4), ("salmon", 5, 1, 5)], mood: "water")
    biome(.frozenRiver, "frozen_river", temperature: 0.0, downfall: 0.5, top: sand, under: sand, underwaterTop: sand, features: ["sugar_cane:4"], waterCreatures: [("salmon", 5, 1, 5)])
    biome(.beach, "beach", temperature: 0.8, downfall: 0.4, top: sand, under: sand, underwaterTop: sand, features: ["sugar_cane:6"], creatures: [("turtle", 5, 2, 5)], mood: "water")
    biome(.snowyBeach, "snowy_beach", temperature: 0.05, downfall: 0.3, top: sand, under: sand, underwaterTop: sand)
    biome(.stonyShore, "stony_shore", temperature: 0.2, downfall: 0.3, top: gravel, under: cell(B.stone), underwaterTop: gravel)

    // temperate
    biome(.plains, "plains", temperature: 0.8, downfall: 0.4,
          features: [TREES("oak_sparse", 0, 0.05), "flowers:plains:8", GRASS_PATCH, "pumpkin:32", "bee_nest:oak:40"],
          creatures: DEF_CREATURES + [("horse", 5, 2, 6), ("donkey", 1, 1, 3)])
    biome(.sunflowerPlains, "sunflower_plains", temperature: 0.8, downfall: 0.4,
          features: ["patch:sunflower:20", TREES("oak_sparse", 0, 0.05), "flowers:plains:8", GRASS_PATCH],
          creatures: DEF_CREATURES + [("horse", 5, 2, 6)])
    biome(.snowyPlains, "snowy_plains", temperature: 0.0, downfall: 0.5, grassColor: 0x80b497, foliageColor: 0x60a17b,
          features: [TREES("spruce", 0, 0.08)],
          monsters: DEF_MONSTERS.filter { $0.mob != "skeleton" } + [("skeleton", 20, 4, 4), ("stray", 80, 4, 4)],
          creatures: [("rabbit", 10, 2, 3), ("polar_bear", 1, 1, 2)])
    biome(.iceSpikes, "ice_spikes", temperature: 0.0, downfall: 0.5, grassColor: 0x80b497, top: cell(B.snow_block), under: cell(B.dirt),
          features: ["ice_spike:3"],
          monsters: DEF_MONSTERS.filter { $0.mob != "skeleton" } + [("stray", 80, 4, 4)],
          creatures: [("rabbit", 10, 2, 3), ("polar_bear", 1, 1, 2)])
    biome(.desert, "desert", temperature: 2.0, downfall: 0, grassColor: 0xbfb755, foliageColor: 0xaea42a,
          top: sand, under: cell(B.sandstone), underwaterTop: sand,
          features: ["cactus:4", "patch:dead_bush:4", "sugar_cane:4", "desert_well:1"],
          monsters: DEF_MONSTERS.filter { $0.mob != "zombie" } + [("zombie", 19, 4, 4), ("husk", 80, 4, 4)],
          creatures: [("rabbit", 4, 2, 3), ("camel", 1, 1, 1)])
    biome(.swamp, "swamp", temperature: 0.8, downfall: 0.9, grassColor: 0x6a7039, foliageColor: 0x6a7039, waterColor: 0x617b64,
          features: [TREES("swamp_oak", 2), "patch:blue_orchid:4", GRASS_PATCH, "lily_pad:4", "patch_water:seagrass:24", "sugar_cane:10", "clay_disk:1", "patch:brown_mushroom:8", "patch:red_mushroom:8"],
          monsters: DEF_MONSTERS + [("slime", 100, 1, 1)],
          creatures: DEF_CREATURES + [("frog", 10, 2, 5)], mood: "dark")
    biome(.mangroveSwamp, "mangrove_swamp", temperature: 0.8, downfall: 0.9, grassColor: 0x6a7039, foliageColor: 0x8db127, waterColor: 0x3a7a6a,
          top: cell(B.mud), under: cell(B.mud), underwaterTop: cell(B.mud),
          features: [TREES("mangrove", 8), "lily_pad:2", "patch_water:seagrass:24"],
          monsters: DEF_MONSTERS + [("slime", 100, 1, 1)],
          creatures: [("frog", 10, 2, 5)], mood: "dark")
    biome(.forest, "forest", temperature: 0.7, downfall: 0.8,
          features: [TREES("oak_birch", 10), "flowers:forest:4", GRASS_PATCH, "patch:brown_mushroom:16", "bee_nest:oak:80"],
          creatures: DEF_CREATURES + [("wolf", 5, 4, 4)])
    biome(.flowerForest, "flower_forest", temperature: 0.7, downfall: 0.8,
          features: [TREES("oak_birch", 4), "flowers:flower_forest:40", GRASS_PATCH, "bee_nest:oak:20"],
          creatures: [("rabbit", 8, 2, 3)])
    biome(.birchForest, "birch_forest", temperature: 0.6, downfall: 0.6, grassColor: 0x88bb67, foliageColor: 0x6ba941,
          features: [TREES("birch", 10), "flowers:forest:4", GRASS_PATCH, "bee_nest:birch:80"])
    biome(.oldGrowthBirchForest, "old_growth_birch_forest", temperature: 0.6, downfall: 0.6, grassColor: 0x88bb67, foliageColor: 0x6ba941,
          features: [TREES("tall_birch", 10), "flowers:forest:4", GRASS_PATCH])
    biome(.darkForest, "dark_forest", temperature: 0.7, downfall: 0.8, grassColor: 0x507a32, foliageColor: 0x59ae30,
          features: [TREES("dark_oak", 16), "huge_mushroom:2", "patch:brown_mushroom:16", "flowers:forest:4", GRASS_PATCH], mood: "dark")
    biome(.taiga, "taiga", temperature: 0.25, downfall: 0.8, grassColor: 0x86b783, foliageColor: 0x68a464,
          features: [TREES("spruce", 10), GRASS_PATCH, "patch:fern:16", "berry_bush:4", "patch:large_fern:8"],
          creatures: DEF_CREATURES + [("wolf", 8, 4, 4), ("fox", 8, 2, 4), ("rabbit", 4, 2, 3)])
    biome(.oldGrowthPineTaiga, "old_growth_pine_taiga", temperature: 0.3, downfall: 0.8, grassColor: 0x86b87f, foliageColor: 0x68a55f, top: cell(B.podzol),
          features: [TREES("mega_pine", 8), GRASS_PATCH, "patch:fern:16", "patch:brown_mushroom:12", "patch:red_mushroom:12", "mossy_boulder:2"],
          creatures: DEF_CREATURES + [("wolf", 8, 4, 4), ("fox", 8, 2, 4)])
    biome(.oldGrowthSpruceTaiga, "old_growth_spruce_taiga", temperature: 0.25, downfall: 0.8, grassColor: 0x86b783, foliageColor: 0x68a464, top: cell(B.podzol),
          features: [TREES("mega_spruce", 8), GRASS_PATCH, "patch:fern:16", "mossy_boulder:2"],
          creatures: DEF_CREATURES + [("wolf", 8, 4, 4), ("fox", 8, 2, 4)])
    biome(.snowyTaiga, "snowy_taiga", temperature: -0.5, downfall: 0.4, grassColor: 0x80b497, foliageColor: 0x60a17b,
          features: [TREES("spruce", 7), "patch:fern:8", "berry_bush:1"],
          monsters: DEF_MONSTERS.filter { $0.mob != "skeleton" } + [("skeleton", 20, 4, 4), ("stray", 80, 4, 4)],
          creatures: [("wolf", 8, 4, 4), ("fox", 8, 2, 4), ("rabbit", 4, 2, 3)])
    biome(.savanna, "savanna", temperature: 1.2, downfall: 0, grassColor: 0xbfb755, foliageColor: 0xaea42a,
          features: [TREES("acacia", 1), "patch:short_grass:60", "patch:tall_grass:10"],
          creatures: DEF_CREATURES + [("horse", 1, 2, 6), ("donkey", 1, 1, 1), ("llama", 8, 4, 4)])
    biome(.savannaPlateau, "savanna_plateau", temperature: 1.0, downfall: 0, grassColor: 0xbfb755, foliageColor: 0xaea42a,
          features: [TREES("acacia", 1), "patch:short_grass:40"],
          creatures: DEF_CREATURES + [("horse", 1, 2, 6), ("llama", 8, 4, 4)])
    biome(.windsweptSavanna, "windswept_savanna", temperature: 1.1, downfall: 0, grassColor: 0xbfb755, foliageColor: 0xaea42a,
          features: [TREES("acacia", 1), "patch:short_grass:40"])
    biome(.windsweptHills, "windswept_hills", temperature: 0.2, downfall: 0.3,
          features: [TREES("spruce", 0, 0.05), GRASS_PATCH, "emerald_ore:1"],
          creatures: DEF_CREATURES + [("llama", 5, 4, 6)])
    biome(.windsweptGravellyHills, "windswept_gravelly_hills", temperature: 0.2, downfall: 0.3, top: gravel, under: gravel,
          features: [TREES("spruce", 0, 0.05), "emerald_ore:1"])
    biome(.windsweptForest, "windswept_forest", temperature: 0.2, downfall: 0.3, top: cell(B.coarse_dirt),
          features: [TREES("oak_spruce", 3), GRASS_PATCH, "emerald_ore:1"])
    biome(.jungle, "jungle", temperature: 0.95, downfall: 0.9, grassColor: 0x59c93c, foliageColor: 0x30bb0b,
          features: [TREES("jungle", 14), "patch:short_grass:50", "patch:fern:20", "melon:32", "vines:40", "flowers:jungle:6", "cocoa:8"],
          creatures: DEF_CREATURES + [("parrot", 40, 1, 2), ("panda", 1, 1, 2), ("ocelot", 2, 1, 3), ("chicken", 10, 4, 4)])
    biome(.sparseJungle, "sparse_jungle", temperature: 0.95, downfall: 0.8, grassColor: 0x64c73f, foliageColor: 0x3eb80f,
          features: [TREES("jungle_sparse", 2), "patch:short_grass:40", "melon:64", "vines:20"],
          creatures: DEF_CREATURES + [("parrot", 40, 1, 2), ("ocelot", 2, 1, 3)])
    biome(.bambooJungle, "bamboo_jungle", temperature: 0.95, downfall: 0.9, grassColor: 0x59c93c, foliageColor: 0x30bb0b, top: cell(B.podzol),
          features: ["bamboo:160", TREES("jungle_sparse", 2), "patch:short_grass:30", "melon:64"],
          creatures: DEF_CREATURES + [("parrot", 40, 1, 2), ("panda", 80, 1, 2), ("ocelot", 2, 1, 3)])
    let bTop = cell(B.red_sand), bUnder = cell(B.terracotta)
    biome(.badlands, "badlands", temperature: 2.0, downfall: 0, grassColor: 0x90814d, foliageColor: 0x9e814d, top: bTop, under: bUnder, underwaterTop: bTop,
          features: ["patch:dead_bush:6", "cactus:2", "badlands_gold:1"], creatures: [])
    biome(.erodedBadlands, "eroded_badlands", temperature: 2.0, downfall: 0, grassColor: 0x90814d, foliageColor: 0x9e814d, top: bTop, under: bUnder, underwaterTop: bTop,
          features: ["hoodoo:6", "patch:dead_bush:6", "cactus:2", "badlands_gold:1"], creatures: [])
    biome(.woodedBadlands, "wooded_badlands", temperature: 2.0, downfall: 0, grassColor: 0x90814d, foliageColor: 0x9e814d, top: cell(B.coarse_dirt), under: bUnder, underwaterTop: bTop,
          features: [TREES("oak_small", 3), "patch:dead_bush:6", "badlands_gold:1"], creatures: [])

    // mountain
    biome(.meadow, "meadow", temperature: 0.5, downfall: 0.8, grassColor: 0x83bb6d, foliageColor: 0x63a948,
          features: ["flowers:meadow:30", "patch:tall_grass:20", TREES("oak_bee", 0, 0.02)],
          creatures: [("sheep", 12, 2, 4), ("donkey", 1, 1, 2), ("rabbit", 2, 2, 6)])
    biome(.cherryGrove, "cherry_grove", temperature: 0.5, downfall: 0.8, grassColor: 0xb6db61, foliageColor: 0xb6db61, waterColor: 0x5db7ef,
          features: [TREES("cherry", 4), "patch:pink_petals:30", "flowers:cherry:6", "bee_nest:cherry:40"],
          creatures: [("sheep", 12, 2, 4), ("rabbit", 2, 2, 6), ("pig", 10, 4, 4)])
    biome(.grove, "grove", temperature: -0.2, downfall: 0.8, top: cell(B.snow_block), under: cell(B.dirt),
          features: [TREES("spruce", 10)],
          creatures: [("wolf", 8, 4, 4), ("rabbit", 4, 2, 3), ("fox", 8, 2, 4)])
    biome(.snowySlopes, "snowy_slopes", temperature: -0.3, downfall: 0.9, top: cell(B.snow_block), under: cell(B.snow_block),
          features: ["powder_snow:2"],
          creatures: [("rabbit", 4, 2, 3), ("goat", 5, 1, 3)])
    biome(.jaggedPeaks, "jagged_peaks", temperature: -0.7, downfall: 0.9, top: cell(B.snow_block), under: cell(B.stone),
          creatures: [("goat", 5, 1, 3)])
    biome(.frozenPeaks, "frozen_peaks", temperature: -0.7, downfall: 0.9, top: cell(B.snow_block), under: cell(B.packed_ice),
          features: ["ice_patch:2"],
          creatures: [("goat", 5, 1, 3)])
    biome(.stonyPeaks, "stony_peaks", temperature: 1.0, downfall: 0.3, top: cell(B.stone), under: cell(B.stone), creatures: [])
    biome(.mushroomFields, "mushroom_fields", temperature: 0.9, downfall: 1, grassColor: 0x55c93f, foliageColor: 0x2bbb0f,
          top: cell(B.mycelium), under: cell(B.dirt),
          features: ["huge_mushroom:3", "patch:red_mushroom:8", "patch:brown_mushroom:8"],
          monsters: [], creatures: [("mooshroom", 8, 4, 8)])

    // cave biomes
    biome(.dripstoneCaves, "dripstone_caves", temperature: 0.8, downfall: 0.4,
          features: ["dripstone_cluster:25", "pointed_dripstone:100", "dripstone_pool:8"], mood: "dark")
    biome(.lushCaves, "lush_caves", temperature: 0.5, downfall: 0.5, grassColor: 0x91bd59,
          features: ["moss_patch:40", "lush_vegetation:60", "glow_berries:30", "spore_blossom:8", "azalea_tree:2", "big_dripleaf:10", "small_dripleaf:8", "clay_pool:6"],
          waterCreatures: [("axolotl", 10, 1, 4), ("glow_squid", 10, 2, 4), ("tropical_fish", 25, 8, 8)], mood: "lush")
    biome(.deepDark, "deep_dark", temperature: 0.8, downfall: 0.4,
          features: ["sculk_patch:60", "sculk_vein:40", "sculk_shrieker:4", "sculk_sensor:8"],
          monsters: [], creatures: [], ambient: [], mood: "dark")

    // nether
    let rack = cell(B.netherrack)
    biome(.netherWastes, "nether_wastes", temperature: 2, downfall: 0, fogTint: 0x330808,
          top: rack, under: rack, underwaterTop: rack,
          features: ["glowstone_cluster:10", "lava_spring:8", "fire_patch:3", "magma_blob:4", "brown_mushroom_nether:2", "red_mushroom_nether:2"],
          monsters: [("ghast", 50, 4, 4), ("zombified_piglin", 100, 4, 4), ("magma_cube", 2, 4, 4), ("enderman", 1, 4, 4), ("piglin", 15, 4, 4)],
          creatures: [("strider", 60, 1, 2)], ambient: [], mood: "nether")
    biome(.crimsonForest, "crimson_forest", temperature: 2, downfall: 0, fogTint: 0x330303,
          top: cell(B.crimson_nylium), under: rack, underwaterTop: rack,
          features: ["huge_fungus:crimson:8", "nether_vegetation:crimson:40", "weeping_vines:30", "glowstone_cluster:8", "lava_spring:4"],
          monsters: [("zombified_piglin", 1, 2, 4), ("hoglin", 9, 3, 4), ("piglin", 5, 3, 4)],
          creatures: [("strider", 60, 1, 2)], ambient: [], mood: "nether")
    biome(.warpedForest, "warped_forest", temperature: 2, downfall: 0, fogTint: 0x0a1b1b,
          top: cell(B.warped_nylium), under: rack, underwaterTop: rack,
          features: ["huge_fungus:warped:8", "nether_vegetation:warped:40", "twisting_vines:20", "glowstone_cluster:8"],
          monsters: [("enderman", 1, 4, 4)],
          creatures: [("strider", 60, 1, 2)], ambient: [], mood: "nether")
    biome(.soulSandValley, "soul_sand_valley", temperature: 2, downfall: 0, fogTint: 0x1b4745,
          top: cell(B.soul_sand), under: cell(B.soul_soil), underwaterTop: cell(B.soul_sand),
          features: ["basalt_pillar:4", "fire_patch_soul:6", "glowstone_cluster:6", "bone_spire:2"],
          monsters: [("skeleton", 20, 5, 5), ("ghast", 50, 4, 4), ("enderman", 1, 4, 4)],
          creatures: [("strider", 60, 1, 2)], ambient: [], mood: "nether")
    biome(.basaltDeltas, "basalt_deltas", temperature: 2, downfall: 0, fogTint: 0x685f70,
          top: cell(B.basalt), under: cell(B.blackstone), underwaterTop: cell(B.basalt),
          features: ["delta:12", "basalt_column:8", "magma_blob:8", "lava_spring:8", "glowstone_cluster:4"],
          monsters: [("ghast", 40, 1, 1), ("magma_cube", 100, 2, 5)],
          creatures: [("strider", 60, 1, 2)], ambient: [], mood: "nether")

    // end
    let endStone = cell(B.end_stone)
    func endBiome(_ id: Biome, _ name: String, features: [String] = []) {
        biome(id, name, temperature: 0.5, downfall: 0.5, fogTint: 0xa080a0,
              top: endStone, under: endStone, underwaterTop: endStone,
              features: features, monsters: [("enderman", 10, 4, 4)], creatures: [], ambient: [], mood: "end")
    }
    endBiome(.theEnd, "the_end")
    endBiome(.endHighlands, "end_highlands", features: ["chorus:6"])
    endBiome(.endMidlands, "end_midlands")
    endBiome(.smallEndIslands, "small_end_islands")
    endBiome(.endBarrens, "end_barrens")
}

// MARK: - climate → biome

public struct Climate {
    public var t: Double
    public var h: Double
    public var c: Double
    public var e: Double
    public var w: Double
    public var pv: Double
    public var rare: Double

    public init(t: Double, h: Double, c: Double, e: Double, w: Double, pv: Double, rare: Double) {
        self.t = t; self.h = h; self.c = c; self.e = e; self.w = w; self.pv = pv; self.rare = rare
    }
}

@inline(__always)
public func peaksValleys(_ w: Double) -> Double {
    -(abs(abs(w * 3) - 2) - 1)
}

public func selectBiome(_ cl: Climate) -> Biome {
    let t = cl.t, h = cl.h, c = cl.c, e = cl.e, pv = cl.pv, rare = cl.rare

    if c < -0.74 && rare > 0.93 { return .mushroomFields }

    if c < -0.19 {
        let deep = c < -0.45
        if t < -0.45 { return deep ? .deepFrozenOcean : .frozenOcean }
        if t < -0.15 { return deep ? .deepColdOcean : .coldOcean }
        if t < 0.4 { return deep ? .deepOcean : .ocean }
        if t < 0.7 || deep { return deep ? .deepLukewarmOcean : .lukewarmOcean }
        return .warmOcean
    }

    if pv < -0.78 && e > -0.4 { return t < -0.45 ? .frozenRiver : .river }

    if c < -0.11 && pv < 0.2 && e > -0.2 {
        if t < -0.45 { return .snowyBeach }
        if e < 0.1 && t < 0.2 { return .stonyShore }
        return .beach
    }

    if e < -0.375 && pv > 0.3 {
        if pv > 0.7 {
            if t < -0.2 { return rare > 0.5 ? .frozenPeaks : .jaggedPeaks }
            if t > 0.55 { return .stonyPeaks }
            return rare > 0.5 ? .frozenPeaks : .jaggedPeaks
        }
        if t < -0.1 { return h > 0.1 ? .grove : .snowySlopes }
        if h < -0.25 && t > 0.1 && rare > 0.55 { return .cherryGrove }
        return .meadow
    }

    if t > 0.55 && h < -0.35 && e < 0.05 {
        if h < -0.6 { return rare > 0.6 ? .erodedBadlands : .badlands }
        return .woodedBadlands
    }

    if e < -0.22 && pv > 0.05 && t < 0.3 && t > -0.45 {
        if rare > 0.85 { return .windsweptSavanna }
        if h < -0.3 { return .windsweptGravellyHills }
        if h > 0.3 { return .windsweptForest }
        return .windsweptHills
    }

    if e > 0.55 && h > 0.1 && c < 0.35 {
        if t > 0.35 { return .mangroveSwamp }
        if t > -0.1 { return .swamp }
    }

    if t < -0.45 {
        if h > 0.3 { return .snowyTaiga }
        return rare > 0.92 ? .iceSpikes : .snowyPlains
    }
    if t < -0.15 {
        if h > 0.3 { return rare > 0.8 ? (rare > 0.9 ? .oldGrowthSpruceTaiga : .oldGrowthPineTaiga) : .taiga }
        if h > -0.1 { return .taiga }
        return .plains
    }
    if t < 0.2 {
        if h < -0.35 { return rare > 0.9 ? .sunflowerPlains : .plains }
        if h < -0.1 { return rare > 0.88 ? .flowerForest : .plains }
        if h < 0.1 { return .forest }
        if h < 0.3 { return rare > 0.85 ? .oldGrowthBirchForest : .birchForest }
        return .darkForest
    }
    if t < 0.55 {
        if h < -0.35 { return .plains }
        if h < -0.1 { return rare > 0.88 ? .flowerForest : .forest }
        if h < 0.3 { return .forest }
        return rare > 0.6 ? .bambooJungle : .sparseJungle
    }
    if h < -0.35 { return .desert }
    if h < -0.1 { return e < -0.1 ? .savannaPlateau : .savanna }
    if h < 0.25 { return .sparseJungle }
    return rare > 0.7 ? .bambooJungle : .jungle
}

public func biomeDef(_ b: Int) -> BiomeDef {
    if b >= 0, b < BIOMES.count, let def = BIOMES[b] { return def }
    return BIOMES[Biome.plains.rawValue]!
}

public func temperatureAt(_ b: Int, _ y: Int) -> Double {
    let base = biomeDef(b).temperature
    // vanilla altitude lapse is 0.00125/block above y80 — the stray ×8 put
    // snow lines at y85-90 and froze biomes that should never see snow
    if y > 80 { return base - Double(y - 80) * 0.00125 }
    return base
}
public func snowsAt(_ b: Int, _ y: Int) -> Bool { temperatureAt(b, y) < 0.15 }
public func isOceanBiome(_ b: Int) -> Bool { b <= Biome.warmOcean.rawValue }
public func isCaveBiome(_ b: Int) -> Bool {
    b == Biome.dripstoneCaves.rawValue || b == Biome.lushCaves.rawValue || b == Biome.deepDark.rawValue
}
