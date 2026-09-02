import SwiftUI
import ElysiumCore

enum RPGNativeDesign {
    static let contentPadding = 20.0
    static let sectionSpacing = 18.0
    static let cardSpacing = 12.0
    static let cardRadius = 10.0
    static let sidebarWidth = 210.0

    static func pathSymbol(_ pathID: String) -> String {
        switch pathID {
        case "warden": return "shield.lefthalf.filled"
        case "ranger": return "scope"
        case "delver": return "hammer.fill"
        case "arcanist": return "sparkles"
        case "mender": return "cross.case.fill"
        case "tinker": return "gearshape.2.fill"
        default: return "person.crop.circle"
        }
    }

    static func tabSymbol(_ tab: RPGCharacterTab) -> String {
        switch tab {
        case .character: return "person.text.rectangle"
        case .skills: return "point.3.connected.trianglepath.dotted"
        case .actives: return "bolt.circle"
        case .spells: return "wand.and.stars"
        case .progression: return "chart.line.uptrend.xyaxis"
        }
    }

    static func tabTitle(_ tab: RPGCharacterTab) -> String {
        switch tab {
        case .character: return "Overview"
        case .skills: return "Skills"
        case .actives: return "Actions"
        case .spells: return "Spells"
        case .progression: return "Progression"
        }
    }

    static func creationSymbol(_ step: RPGCreationStep) -> String {
        switch step {
        case .path: return "person.3.sequence"
        case .branch: return "arrow.triangle.branch"
        case .skills: return "checklist"
        case .review: return "checkmark.seal"
        }
    }

    static func creationTitle(_ step: RPGCreationStep) -> String {
        switch step {
        case .path: return "Choose a Path"
        case .branch: return "Choose a Sub-class"
        case .skills: return "Starting Skills"
        case .review: return "Review Character"
        }
    }
}

enum RPGNativeCharacterSection: String, CaseIterable, Identifiable {
    case overview
    case skills
    case loadout
    case progress

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .skills: return "Skills"
        case .loadout: return "Loadout"
        case .progress: return "Progress"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "person.text.rectangle"
        case .skills: return "point.3.connected.trianglepath.dotted"
        case .loadout: return "bolt.badge.clock"
        case .progress: return "chart.line.uptrend.xyaxis"
        }
    }
}

enum RPGNativeLoadoutSection: String, CaseIterable, Identifiable {
    case actions
    case spells

    var id: Self { self }
    var title: String { rawValue.capitalized }
}
