import Foundation

/// Controls the deterministic settlement lattice used for newly generated
/// overworld chunks. Values are persisted as stable integers; missing or
/// malformed values deliberately resolve to `.normal` so existing worlds keep
/// a predictable, compatible generation profile.
public enum VillageDensity: Int, CaseIterable, Equatable {
    case none = 1
    case few = 2
    case normal = 3
    case many = 4
    case max = 5

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .few: return "Few"
        case .normal: return "Normal"
        case .many: return "Many"
        case .max: return "Max"
        }
    }

    /// All active levels share one safe, 20-chunk base lattice. Lower density
    /// levels take nested deterministic subsets of it instead of switching to
    /// unrelated lattices. Thus every grounded town admitted at Few remains a
    /// candidate at Normal, Many, and Max; raising the option cannot make a
    /// real-world town count go down merely because the grid phase changed.
    /// A settlement's widest ref reaches eight chunks from its origin, so the
    /// 18-chunk separation leaves a deterministic margin even after its
    /// terrain-aware centre shifts up to three chunks in either direction.
    var structurePlacement: StructurePlacement? {
        switch self {
        case .none:
            return nil
        case .few, .normal, .many, .max:
            return StructurePlacement(spacing: 20, separation: 18)
        }
    }

    /// Equivalent acceptance rates recreate the intended average candidate
    /// distances: roughly 64 chunks for Few, 34 for Normal, 26 for Many, and
    /// 20 for Max. The values are deliberately nested prefixes of one hash.
    private var acceptanceThreshold: Int {
        switch self {
        case .none: return 0
        case .few: return 6_554       // ~= (20 / 64)^2
        case .normal: return 22_938   // ~= (20 / 34)^2
        case .many: return 38_816     // ~= (20 / 26)^2
        case .max: return 65_536
        }
    }

    /// Larger settings feel alive through more settlements, while every
    /// accepted settlement maintains the same complete, inhabited form. This
    /// stability is what makes the cross-level selection truly monotonic.
    var buildingCountPerArm: ClosedRange<Int> {
        2...4
    }

    var armCount: ClosedRange<Int> {
        3...4
    }

    func includesCandidate(seed: UInt32, originX: Int, originZ: Int) -> Bool {
        guard acceptanceThreshold > 0 else { return false }
        if acceptanceThreshold >= 65_536 { return true }
        let rank = Int(hash2(seed, originX, originZ, 0x71_11_A6E)) & 0xFFFF
        return rank < acceptanceThreshold
    }
}

public func normalizedVillageDensity(_ raw: Int?) -> VillageDensity {
    guard let raw, let density = VillageDensity(rawValue: raw) else { return .normal }
    return density
}

public func normalizedVillageDensity(_ raw: String?) -> VillageDensity {
    let key = (raw ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
    switch key {
    case "1", "none", "off", "no_villages", "no villages":
        return .none
    case "2", "few", "low", "sparse":
        return .few
    case "", "3", "default", "normal":
        return .normal
    case "4", "many", "high", "lots":
        return .many
    case "5", "max", "maximum", "very_many", "very many", "abundant":
        return .max
    default:
        return .normal
    }
}
