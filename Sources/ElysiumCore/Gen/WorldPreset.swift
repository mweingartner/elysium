import Foundation

public enum WorldPreset: String, CaseIterable, Equatable {
    case normal = "minecraft:normal"
    case flat = "minecraft:flat"
    case largeBiomes = "minecraft:large_biomes"
    case amplified = "minecraft:amplified"
    case moderateHillsResourceRich = "elysium:moderate_hills_resource_rich"
    case singleBiomeSurface = "minecraft:single_biome_surface"
    case debugAllBlockStates = "minecraft:debug_all_block_states"

    public static let normalCycle: [WorldPreset] = [
        .normal, .flat, .largeBiomes, .amplified, .moderateHillsResourceRich, .singleBiomeSurface,
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
        case .debugAllBlockStates: return "Debug Mode"
        }
    }
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

    public init(preset: WorldPreset = .normal, singleBiome: Biome = .plains,
                dungeonDensity: DungeonDensity = .normal) {
        self.preset = preset
        self.singleBiome = singleBiome
        self.dungeonDensity = dungeonDensity
    }

    public init(presetID: String?, singleBiomeID: String?, dungeonDensityLevel: Int? = nil) {
        preset = normalizedWorldPreset(presetID)
        singleBiome = normalizedSingleBiome(singleBiomeID)
        dungeonDensity = normalizedDungeonDensity(dungeonDensityLevel)
    }

    public static let normal = WorldGenerationSettings()

    /// Stable, complete identity for generation caches. Keep this explicit so a
    /// future setting cannot silently alias an older structure plan.
    public var cacheIdentity: String {
        "\(preset.rawValue)|\(biomeID(singleBiome))|dungeons:\(dungeonDensity.rawValue)"
    }
}
