import Foundation

public enum DungeonDensity: Int, CaseIterable, Equatable {
    case none = 1
    case normal = 2
    case more = 3
    case plentiful = 4
    case many = 5

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .normal: return "Normal"
        case .more: return "More"
        case .plentiful: return "Plentiful"
        case .many: return "Many"
        }
    }

    public var dungeonPasses: Int {
        switch self {
        case .none:
            return 0
        case .normal, .more, .plentiful, .many:
            return 1 << (rawValue - DungeonDensity.normal.rawValue)
        }
    }
}

public func normalizedDungeonDensity(_ raw: Int?) -> DungeonDensity {
    guard let raw, let density = DungeonDensity(rawValue: raw) else { return .normal }
    return density
}

public func normalizedDungeonDensity(_ raw: String?) -> DungeonDensity {
    let key = (raw ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: "-", with: "_")
    switch key {
    case "1", "none", "off", "no_dungeons", "no dungeons":
        return .none
    case "", "2", "default", "normal":
        return .normal
    case "3", "more":
        return .more
    case "4", "plentiful", "high", "lots":
        return .plentiful
    case "5", "many", "very_many", "very many", "abundant":
        return .many
    default:
        return .normal
    }
}
