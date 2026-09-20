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
    /// Explicit compatibility profiles for worlds created before the predator
    /// and herd-defense simulation revision. Their roster stays identical to
    /// v2; the revision only changes the opted-in simulation contract.
    case lostWorldV1
    case jurassicGiantsV1
    case cretaceousFrontiersV1
    case ancientSeasV1
    /// Current creation profiles. Keep these unqualified source names so new
    /// callers naturally use the current content revision.
    case lostWorld
    case jurassicGiants
    case cretaceousFrontiers
    case ancientSeas

    public static let currentContentVersion = 2

    /// The persisted content revision that controls simulation compatibility.
    public var contentVersion: Int {
        switch self {
        case .lostWorldV1, .jurassicGiantsV1, .cretaceousFrontiersV1, .ancientSeasV1:
            return 1
        case .lostWorld, .jurassicGiants, .cretaceousFrontiers, .ancientSeas:
            return Self.currentContentVersion
        }
    }

    /// Stable profile name shared by the compatible revisions. Do not derive
    /// this from the enum raw value: the raw value distinguishes v1 from v2.
    public var profileID: String {
        switch self {
        case .lostWorldV1, .lostWorld: return "lostWorld"
        case .jurassicGiantsV1, .jurassicGiants: return "jurassicGiants"
        case .cretaceousFrontiersV1, .cretaceousFrontiers: return "cretaceousFrontiers"
        case .ancientSeasV1, .ancientSeas: return "ancientSeas"
        }
    }

    /// Version-two worlds opt into the predator/prey and herd-defense rules.
    /// Keeping this in the profile layer makes v1 save behavior explicit and
    /// provides one reusable gate for later v2-only world features.
    public var supportsPredatorHerdCombat: Bool {
        contentVersion == Self.currentContentVersion
    }

    /// Version-two worlds also own the bounded starter-shelter contract.
    /// It stays false for v1 so an existing saved world never gains generated
    /// spawn structures from a later build.
    public var supportsStarterShelter: Bool {
        contentVersion == Self.currentContentVersion
    }

    public var isAncientSeas: Bool {
        switch self {
        case .ancientSeasV1, .ancientSeas: return true
        default: return false
        }
    }

    public var preset: WorldPreset {
        switch self {
        case .lostWorldV1: return .prehistoricLostWorld
        case .jurassicGiantsV1: return .prehistoricJurassicGiants
        case .cretaceousFrontiersV1: return .prehistoricCretaceousFrontiers
        case .ancientSeasV1: return .prehistoricAncientSeas
        case .lostWorld: return .prehistoricLostWorldV2
        case .jurassicGiants: return .prehistoricJurassicGiantsV2
        case .cretaceousFrontiers: return .prehistoricCretaceousFrontiersV2
        case .ancientSeas: return .prehistoricAncientSeasV2
        }
    }

    /// Stable simulation/content identity included in diagnostics and LAN
    /// summaries. The preset raw value remains the persisted/cache identity.
    public var contentIdentity: String {
        "elysium.prehistoric.\(profileID).v\(contentVersion)"
    }

    public static func forPreset(_ preset: WorldPreset) -> PrehistoricWorldProfile? {
        switch preset {
        case .prehistoricLostWorld: return .lostWorldV1
        case .prehistoricJurassicGiants: return .jurassicGiantsV1
        case .prehistoricCretaceousFrontiers: return .cretaceousFrontiersV1
        case .prehistoricAncientSeas: return .ancientSeasV1
        case .prehistoricLostWorldV2: return .lostWorld
        case .prehistoricJurassicGiantsV2: return .jurassicGiants
        case .prehistoricCretaceousFrontiersV2: return .cretaceousFrontiers
        case .prehistoricAncientSeasV2: return .ancientSeas
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
        case .lostWorldV1, .lostWorld:
            return Self.allCreatureIDs
        case .jurassicGiantsV1, .jurassicGiants:
            return [
                "prehistoric.compsognathus", "prehistoric.dilophosaurus", "prehistoric.allosaurus",
                "prehistoric.ceratosaurus", "prehistoric.dryosaurus", "prehistoric.stegosaurus",
                "prehistoric.diplodocus", "prehistoric.brachiosaurus", "prehistoric.dimorphodon",
                "prehistoric.rhamphorhynchus", "prehistoric.ichthyosaurus", "prehistoric.plesiosaurus",
                "prehistoric.liopleurodon",
            ]
        case .cretaceousFrontiersV1, .cretaceousFrontiers:
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
        case .ancientSeasV1, .ancientSeas:
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

    /// Gates the v2 predator/prey and herd-defense simulation without
    /// reinterpreting a persisted v1 world.
    var supportsPredatorHerdCombat: Bool {
        prehistoricProfile?.supportsPredatorHerdCombat ?? false
    }

    /// Gates the v2 dinosaur-world starter shelter without changing v1 saves.
    var supportsStarterShelter: Bool {
        prehistoricProfile?.supportsStarterShelter ?? false
    }

    /// Exact roster/simulation revision that LAN peers must share.  Normal
    /// worlds deliberately carry no prehistoric content identity, preserving
    /// the legacy normal-world handshake and resume key shape.
    var prehistoricContentIdentity: String? {
        prehistoricProfile?.contentIdentity
    }
}
