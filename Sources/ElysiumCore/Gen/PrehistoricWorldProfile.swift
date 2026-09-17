// Prehistoric Worlds — versioned, opt-in profile catalog.
//
// This file intentionally holds only stable identifiers and profile
// membership. It contains no presentation assets and does not mutate global
// biome spawn lists, which keeps ordinary worlds byte-for-byte on their
// existing terrain/spawn path.

import Foundation

public enum PrehistoricCreatureMedium: String, CaseIterable, Sendable {
    case land
    case air
    case aquatic
}

public enum PrehistoricWorldProfile: String, CaseIterable, Sendable {
    case lostWorld
    case jurassicGiants
    case cretaceousFrontiers
    case ancientSeas

    public static let contentVersion = 1

    public var preset: WorldPreset {
        switch self {
        case .lostWorld: return .prehistoricLostWorld
        case .jurassicGiants: return .prehistoricJurassicGiants
        case .cretaceousFrontiers: return .prehistoricCretaceousFrontiers
        case .ancientSeas: return .prehistoricAncientSeas
        }
    }

    /// Stable simulation/content identity included in diagnostics and LAN
    /// summaries. The preset raw value remains the persisted/cache identity.
    public var contentIdentity: String {
        "elysium.prehistoric.\(rawValue).v\(Self.contentVersion)"
    }

    public static func forPreset(_ preset: WorldPreset) -> PrehistoricWorldProfile? {
        switch preset {
        case .prehistoricLostWorld: return .lostWorld
        case .prehistoricJurassicGiants: return .jurassicGiants
        case .prehistoricCretaceousFrontiers: return .cretaceousFrontiers
        case .prehistoricAncientSeas: return .ancientSeas
        default: return nil
        }
    }

    /// The canonical registration/content order. Do not reorder: profile
    /// membership, validation, and deterministic weighted picks derive from it.
    public static let allCreatureIDs: [String] = [
        "prehistoric.compsognathus", "prehistoric.coelophysis", "prehistoric.velociraptor",
        "prehistoric.dilophosaurus", "prehistoric.deinonychus", "prehistoric.allosaurus",
        "prehistoric.ceratosaurus", "prehistoric.carnotaurus", "prehistoric.tyrannosaurus",
        "prehistoric.spinosaurus", "prehistoric.dryosaurus", "prehistoric.pachycephalosaurus",
        "prehistoric.gallimimus", "prehistoric.oviraptor", "prehistoric.parasaurolophus",
        "prehistoric.edmontosaurus", "prehistoric.iguanodon", "prehistoric.triceratops",
        "prehistoric.styracosaurus", "prehistoric.stegosaurus", "prehistoric.ankylosaurus",
        "prehistoric.diplodocus", "prehistoric.brachiosaurus", "prehistoric.therizinosaurus",
        "prehistoric.dimorphodon", "prehistoric.rhamphorhynchus", "prehistoric.pteranodon",
        "prehistoric.tapejara", "prehistoric.quetzalcoatlus", "prehistoric.microraptor",
        "prehistoric.ichthyosaurus", "prehistoric.plesiosaurus", "prehistoric.elasmosaurus",
        "prehistoric.liopleurodon", "prehistoric.mosasaurus", "prehistoric.deinosuchus",
    ]

    public static let landCreatureIDs: [String] = Array(allCreatureIDs.prefix(24))
    public static let airCreatureIDs: [String] = Array(allCreatureIDs[24..<30])
    public static let aquaticCreatureIDs: [String] = Array(allCreatureIDs.suffix(6))

    /// Curated world-play groups. They are authoring profiles rather than a
    /// claim that every listed taxon coexisted; Lost World is deliberately the
    /// mixed-era fantasy profile while the era labels offer focused encounters.
    public var creatureIDs: [String] {
        switch self {
        case .lostWorld:
            return Self.allCreatureIDs
        case .jurassicGiants:
            return [
                "prehistoric.compsognathus", "prehistoric.dilophosaurus", "prehistoric.allosaurus",
                "prehistoric.ceratosaurus", "prehistoric.dryosaurus", "prehistoric.stegosaurus",
                "prehistoric.diplodocus", "prehistoric.brachiosaurus", "prehistoric.dimorphodon",
                "prehistoric.rhamphorhynchus", "prehistoric.ichthyosaurus", "prehistoric.plesiosaurus",
                "prehistoric.liopleurodon",
            ]
        case .cretaceousFrontiers:
            return [
                "prehistoric.velociraptor", "prehistoric.deinonychus", "prehistoric.carnotaurus",
                "prehistoric.tyrannosaurus", "prehistoric.spinosaurus", "prehistoric.pachycephalosaurus",
                "prehistoric.gallimimus", "prehistoric.oviraptor", "prehistoric.parasaurolophus",
                "prehistoric.edmontosaurus", "prehistoric.iguanodon", "prehistoric.triceratops",
                "prehistoric.styracosaurus", "prehistoric.ankylosaurus", "prehistoric.therizinosaurus",
                "prehistoric.pteranodon", "prehistoric.tapejara", "prehistoric.quetzalcoatlus",
                "prehistoric.microraptor", "prehistoric.elasmosaurus", "prehistoric.mosasaurus",
                "prehistoric.deinosuchus",
            ]
        case .ancientSeas:
            return [
                "prehistoric.pteranodon", "prehistoric.quetzalcoatlus", "prehistoric.ichthyosaurus",
                "prehistoric.plesiosaurus", "prehistoric.elasmosaurus", "prehistoric.liopleurodon",
                "prehistoric.mosasaurus", "prehistoric.deinosuchus",
            ]
        }
    }

    public func creatureIDs(for medium: PrehistoricCreatureMedium) -> [String] {
        // Keep filtering in the canonical registration order. The catalog is
        // deliberately tiny, so an ordered array membership check is clearer
        // than introducing an unordered container on a simulation path.
        let permitted: [String]
        switch medium {
        case .land: permitted = Self.landCreatureIDs
        case .air: permitted = Self.airCreatureIDs
        case .aquatic: permitted = Self.aquaticCreatureIDs
        }
        return creatureIDs.filter { permitted.contains($0) }
    }
}

public extension WorldPreset {
    var prehistoricProfile: PrehistoricWorldProfile? {
        PrehistoricWorldProfile.forPreset(self)
    }

    var isPrehistoric: Bool { prehistoricProfile != nil }

    /// Exact roster/simulation revision that LAN peers must share.  Normal
    /// worlds deliberately carry no prehistoric content identity, preserving
    /// the legacy normal-world handshake and resume key shape.
    var prehistoricContentIdentity: String? {
        prehistoricProfile?.contentIdentity
    }
}
