import Foundation

public enum WorldPreset: String, CaseIterable, Equatable {
    case normal = "minecraft:normal"
    case flat = "minecraft:flat"
    case largeBiomes = "minecraft:large_biomes"
    case amplified = "minecraft:amplified"
    case moderateHillsResourceRich = "elysium:moderate_hills_resource_rich"
    case singleBiomeSurface = "minecraft:single_biome_surface"
    case netherWorld = "elysium:nether_world"
    case debugAllBlockStates = "minecraft:debug_all_block_states"

    public static let normalCycle: [WorldPreset] = [
        .normal, .flat, .largeBiomes, .amplified, .moderateHillsResourceRich, .singleBiomeSurface,
        .netherWorld,
    ]

    public static let extendedCycle: [WorldPreset] = normalCycle + [.debugAllBlockStates]

    public var displayName: String {
        switch self {
        case .normal: return "Default"
        case .flat: return "Superflat"
        case .largeBiomes: return "Large Biomes"
        case .amplified: return "Amplified"
        case .moderateHillsResourceRich: return "Rich Resources"
        case .singleBiomeSurface: return "Single Biome"
        case .netherWorld: return "Nether World"
        case .debugAllBlockStates: return "Debug Mode"
        }
    }

    /// The dimension used for a player record that does not yet exist. Persisted player data
    /// always wins, so adding this case cannot move an established world between dimensions.
    public var startingDimension: Dim {
        self == .netherWorld ? .nether : .overworld
    }

    /// Whether an Overworld village plan can materialize for this preset.
    /// Superflat deliberately retains villages; a Nether World retains its
    /// world-level choice for the reachable Overworld. Only Debug has no
    /// meaningful village generator anywhere.
    public var supportsVillageDensity: Bool {
        switch self {
        case .debugAllBlockStates:
            return false
        default:
            return true
        }
    }

    /// Whether the selected starting world has a dungeon generator with a
    /// meaningful underground terrain envelope. Superflat has no such volume;
    /// Nether World retains the world-level choice for its reachable
    /// Overworld, whose ordinary generator does honor it.
    public var supportsDungeonDensity: Bool {
        switch self {
        case .flat, .debugAllBlockStates:
            return false
        default:
            return true
        }
    }

    /// Compatibility summary for callers that only need to know whether at
    /// least one procedural-density control is meaningful. New UI and
    /// persistence code must use the specific property above.
    public var supportsProceduralStructureDensities: Bool {
        supportsDungeonDensity || supportsVillageDensity
    }
}

/// Persist only choices that the selected preset can actually generate. This
/// is shared by settings construction, save decoding/encoding, direct API
/// callers, and the create screen so stale records cannot reintroduce an
/// unreachable option.
public func canonicalStructureDensities(for preset: WorldPreset,
                                        dungeon: DungeonDensity,
                                        village: VillageDensity) -> (dungeon: DungeonDensity,
                                                                       village: VillageDensity) {
    (preset.supportsDungeonDensity ? dungeon : .normal,
     preset.supportsVillageDensity ? village : .normal)
}

public func normalizedWorldPreset(_ raw: String?) -> WorldPreset {
    let rawKey = (raw ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "minecraft:", with: "")
        .replacingOccurrences(of: "elysium:", with: "")
        .replacingOccurrences(of: "-", with: "_")
    let key = rawKey
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .joined(separator: "_")
    switch key {
    case "", "default", "normal":
        return .normal
    case "flat", "superflat":
        return .flat
    case "largebiomes", "large_biomes", "large biomes":
        return .largeBiomes
    case "amplified":
        return .amplified
    case "moderate_hills_resource_rich", "moderate hills resource rich",
         "moderate_hills_rich", "moderate hills rich", "resource_rich",
         "resource rich", "noderate_hills_resource_rich", "noderate hills resource rich":
        return .moderateHillsResourceRich
    case "single_biome", "single_biome_surface", "single biome":
        return .singleBiomeSurface
    case "nether", "nether_world", "nether world":
        return .netherWorld
    case "debug", "debug_mode", "debug_all_block_states", "debug all block states":
        return .debugAllBlockStates
    default:
        return .normal
    }
}

public func biomeID(_ biome: Biome) -> String {
    let text = String(describing: biome)
    var out = ""
    for ch in text {
        if ch.isUppercase {
            if !out.isEmpty { out.append("_") }
            out.append(ch.lowercased())
        } else {
            out.append(ch)
        }
    }
    return out
}

public func normalizedSingleBiome(_ raw: String?) -> Biome {
    let key = (raw ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "minecraft:", with: "")
        .replacingOccurrences(of: "-", with: "_")
    if let biome = Biome.allCases.first(where: { biomeID($0) == key }) {
        return biome
    }
    return .plains
}

public func singleBiomeDisplayName(_ biome: Biome) -> String {
    biomeID(biome)
        .split(separator: "_")
        .map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

public struct WorldGenerationSettings: Equatable {
    public var preset: WorldPreset
    public var singleBiome: Biome
    public var dungeonDensity: DungeonDensity
    public var villageDensity: VillageDensity

    public init(preset: WorldPreset = .normal, singleBiome: Biome = .plains,
                dungeonDensity: DungeonDensity = .normal,
                villageDensity: VillageDensity = .normal) {
        self.preset = preset
        self.singleBiome = singleBiome
        let canonical = canonicalStructureDensities(for: preset, dungeon: dungeonDensity,
                                                     village: villageDensity)
        self.dungeonDensity = canonical.dungeon
        self.villageDensity = canonical.village
    }

    public init(presetID: String?, singleBiomeID: String?, dungeonDensityLevel: Int? = nil,
                villageDensityLevel: Int? = nil) {
        preset = normalizedWorldPreset(presetID)
        singleBiome = normalizedSingleBiome(singleBiomeID)
        let canonical = canonicalStructureDensities(
            for: preset,
            dungeon: normalizedDungeonDensity(dungeonDensityLevel),
            village: normalizedVillageDensity(villageDensityLevel)
        )
        dungeonDensity = canonical.dungeon
        villageDensity = canonical.village
    }

    public static let normal = WorldGenerationSettings()

    /// Stable, complete identity for generation caches. Keep this explicit so a
    /// future setting cannot silently alias an older structure plan.
    public var cacheIdentity: String {
        "\(preset.rawValue)|\(biomeID(singleBiome))|dungeons:\(dungeonDensity.rawValue)|villages:\(villageDensity.rawValue)"
    }
}
