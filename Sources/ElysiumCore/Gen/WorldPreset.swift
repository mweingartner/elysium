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
    /// Versioned, opt-in prehistoric ecosystem profiles. The version is part
    /// of the persisted preset id and generation cache identity, so a later
    /// content revision cannot silently reinterpret a saved world.
    case prehistoricLostWorld = "elysium:prehistoric_lost_world_v1"
    case prehistoricJurassicGiants = "elysium:prehistoric_jurassic_giants_v1"
    case prehistoricCretaceousFrontiers = "elysium:prehistoric_cretaceous_frontiers_v1"
    case prehistoricAncientSeas = "elysium:prehistoric_ancient_seas_v1"

    public static let normalCycle: [WorldPreset] = [
        .normal, .flat, .largeBiomes, .amplified, .moderateHillsResourceRich, .singleBiomeSurface,
        .netherWorld, .prehistoricLostWorld, .prehistoricJurassicGiants,
        .prehistoricCretaceousFrontiers, .prehistoricAncientSeas,
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
        case .prehistoricLostWorld: return "Lost World"
        case .prehistoricJurassicGiants: return "Jurassic Giants"
        case .prehistoricCretaceousFrontiers: return "Cretaceous Frontiers"
        case .prehistoricAncientSeas: return "Ancient Seas"
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
        case .debugAllBlockStates, .prehistoricLostWorld, .prehistoricJurassicGiants,
             .prehistoricCretaceousFrontiers, .prehistoricAncientSeas:
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

/// A persisted/wire prehistoric identifier is versioned content, rather than
/// a cosmetic alias.  Do not silently turn an identifier from a newer build
/// into a normal world: callers at a decoding boundary must reject it until
/// this build knows how to interpret that profile.
public enum WorldPresetValidationError: Error, Equatable, Sendable {
    case unsupportedPrehistoricPreset
}

/// Future prehistoric profile identifiers sometimes arrive with a foreign
/// namespace (for example after an export/import hop).  Treat the profile
/// marker—not only Elysium's namespace—as authoritative at a persistence or
/// network boundary so such a world cannot be laundered into normal.
private func hasUnsupportedPrehistoricProfileMarker(_ raw: String?) -> Bool {
    let tokens = (raw ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    guard !tokens.isEmpty else { return false }

    // Tokenizing every non-alphanumeric separator catches copied/imported
    // forms such as `other:prehistoric.lost_world_v2` and nested namespace
    // forms without broadening the normal fallback for unrelated IDs.
    // A copied future identifier can collapse camel-case into one token once
    // it is lowercased (for example `prehistoricLostWorldV2`).  The explicit
    // marker remains authoritative in that form too; otherwise the normal
    // fallback would silently reinterpret its generation domain.
    if tokens.contains(where: { $0.hasPrefix("prehistoric") }) { return true }

    // Preserve the same fail-closed boundary if an importer inserts a
    // punctuation boundary *inside* the marker (`pre.historic...`).  Looking
    // at each suffix, rather than only the complete raw value, avoids an
    // unrelated foreign namespace masking the profile marker.
    for index in tokens.indices {
        let compactSuffix = tokens[index...].map(String.init).joined()
        if compactSuffix.hasPrefix("prehistoric") { return true }
    }

    // Elysium's historic short aliases (for example `lost_world`) remain
    // accepted above. A versioned unknown sibling under the Elysium namespace
    // is still prehistoric content and must not become a normal save.
    let compactProfileBases = [
        "lostworld", "jurassicgiants", "cretaceousfrontiers", "ancientseas",
    ]
    for index in tokens.indices where tokens[index] == "elysium" {
        // Join remaining lexical units so the official namespace catches both
        // `lost_world_v2` and a camel-cased/squashed `lostWorldV2` sibling.
        let suffix = tokens[tokens.index(after: index)...].map(String.init).joined()
        if compactProfileBases.contains(where: { suffix.hasPrefix($0) }) {
            return true
        }
    }
    return false
}

private func normalizedWorldPresetKey(_ raw: String?) -> String {
    let rawKey = (raw ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "minecraft:", with: "")
        .replacingOccurrences(of: "elysium:", with: "")
        .replacingOccurrences(of: "-", with: "_")
    return rawKey
        .replacingOccurrences(of: "_", with: " ")
        .split(separator: " ")
        .joined(separator: "_")
}

public func normalizedWorldPreset(_ raw: String?) -> WorldPreset {
    let key = normalizedWorldPresetKey(raw)
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
    case "lost_world", "lost world", "prehistoric_lost_world", "prehistoric_lost_world_v1":
        return .prehistoricLostWorld
    case "jurassic_giants", "jurassic giants", "prehistoric_jurassic_giants",
         "prehistoric_jurassic_giants_v1":
        return .prehistoricJurassicGiants
    case "cretaceous_frontiers", "cretaceous frontiers", "prehistoric_cretaceous_frontiers",
         "prehistoric_cretaceous_frontiers_v1":
        return .prehistoricCretaceousFrontiers
    case "ancient_seas", "ancient seas", "prehistoric_ancient_seas",
         "prehistoric_ancient_seas_v1":
        return .prehistoricAncientSeas
    default:
        return .normal
    }
}

/// Strict counterpart to `normalizedWorldPreset(_:)` for persisted and LAN
/// payloads.  Legacy, non-prehistoric unknown values retain the historical
/// normal-world fallback; a future `prehistoric*` identifier instead fails
/// closed so its terrain and roster cannot be reinterpreted as normal.
public func validatedWorldPreset(_ raw: String?) throws -> WorldPreset {
    let preset = normalizedWorldPreset(raw)
    guard preset == .normal, hasUnsupportedPrehistoricProfileMarker(raw) else {
        return preset
    }
    throw WorldPresetValidationError.unsupportedPrehistoricPreset
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
