import Foundation

/// The stored request stays distinct from the effective device-supported mode.
/// Reuses the established shader preference without migrating saved worlds.
enum GraphicsMode: CaseIterable, Equatable {
    case standard, ultra, rayTraced

    init(shader: String?) {
        switch shader {
        case "ultra": self = .ultra
        case "raytraced": self = .rayTraced
        default: self = .standard
        }
    }

    var shader: String? {
        switch self {
        case .standard: return nil
        case .ultra: return "ultra"
        case .rayTraced: return "raytraced"
        }
    }

    func next(rayTracingSupported: Bool) -> GraphicsMode {
        switch self {
        case .standard: return .ultra
        case .ultra: return rayTracingSupported ? .rayTraced : .standard
        case .rayTraced: return .standard
        }
    }

    func effective(rayTracingSupported: Bool) -> GraphicsMode {
        self == .rayTraced && !rayTracingSupported ? .ultra : self
    }

    func buttonLabel(rayTracingSupported: Bool) -> String {
        switch self {
        case .standard: return "Shaders: OFF"
        case .ultra: return "Shaders: §6ULTRA§r"
        case .rayTraced:
            return rayTracingSupported ? "Shaders: §bRAY TRACED§r" : "Shaders: §cRT UNAVAILABLE§r"
        }
    }
}
