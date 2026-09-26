// Prehistoric Worlds creature foundation.
//
// One deterministic data catalog drives every registered taxon. The three
// movement families intentionally share bounded state machines rather than
// creating 36 near-identical subclasses. All simulation randomness comes
// from each LivingEntity's seeded `rng`, never presentation/audio RNG.

import Foundation

public enum PrehistoricCreatureFamily: String, CaseIterable, Sendable {
    case smallTheropod
    case largeTheropod
    case ceratopsian
    case hadrosaur
    case armoredHerbivore
    case sauropod
    case unusualHerbivore
    case flyer
    case ichthyosaur
    case longNeckedSwimmer
    case marinePredator
    case shorePredator

    var isPredatory: Bool {
        switch self {
        case .smallTheropod, .largeTheropod, .ichthyosaur, .marinePredator, .shorePredator:
            return true
        default:
            return false
        }
    }

    var canCharge: Bool {
        self == .ceratopsian || self == .largeTheropod || self == .shorePredator
    }

    /// The land-only herbivore families that participate in the V2 herd
    /// ecology. Do not infer this from `!isPredatory`: that would accidentally
    /// classify flyers and non-predatory marine reptiles as herd prey.
    var isLandHerdHerbivore: Bool {
        switch self {
        case .ceratopsian, .hadrosaur, .armoredHerbivore, .sauropod, .unusualHerbivore:
            return true
        default:
            return false
        }
    }
}

/// Every source-authored cue a prehistoric creature can emit. The action
/// cases deliberately keep their existing raw values, but this separate enum
/// also covers combat, lifecycle, and continuous locomotion sounds without
/// expanding the save/LAN action schema.
public enum PrehistoricSoundCue: String, CaseIterable, Sendable {
    case ambient
    case hurt
    case death
    case attack
    case step
    case wingbeat
    case swim
    case idle
    case browse
    case alert
    case charge
    case recover
    case takeoff
    case flap
    case glide
    case landing
    case cruise
    case surface
    case dive
    case turn
    case eat
    case burst
    case stranded
}

/// Stable, source-owned acoustic parameters. They are presentation metadata,
/// never a simulation RNG input, and the roster index gives every species an
/// audibly distinct formant even when body size and movement family match.
public struct PrehistoricSoundProfile: Equatable, Hashable, Sendable {
    public let signature: Int
    public let formantFrequency: Int
    public let pulseCount: Int
    public let timbreIndex: Int
    public let cadenceOffset: Int
}

public enum PrehistoricAction: String, CaseIterable, Sendable {
    case idle
    case browse
    case alert
    case charge
    case recover
    case takeoff
    case flap
    case glide
    case landing
    case cruise
    case surface
    case dive
    case turn
    case eat
    case burst
    case stranded

    public var soundCue: PrehistoricSoundCue {
        // Action raw values are deliberately shared with their audio cue, so
        // a newly added controller state cannot silently become soundless.
        guard let cue = PrehistoricSoundCue(rawValue: rawValue) else {
            preconditionFailure("missing prehistoric sound cue for \(rawValue)")
        }
        return cue
    }
}

public struct PrehistoricCreatureDefinition: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let medium: PrehistoricCreatureMedium
    public let family: PrehistoricCreatureFamily
    /// A design scale for player-facing metadata/model sizing, not a claim of
    /// an exact fossil reconstruction.
    public let authoringLengthMetres: Double
    public let collisionWidth: Double
    public let collisionHeight: Double
    public let health: Double
    public let speed: Double
    public let attackDamage: Double
    public let spawnWeight: Double
    public let minPack: Int
    public let maxPack: Int

    public var isPredatory: Bool { family.isPredatory }
    public var canCharge: Bool { family.canCharge }
    public var isLandPredator: Bool { medium == .land && isPredatory }
    public var isLandHerdHerbivore: Bool {
        medium == .land && family.isLandHerdHerbivore
    }

    /// The V2 herd-combat values are derived from immutable family metadata,
    /// rather than mutable entity data. That keeps defense selection stable
    /// across a save/load and does not add a new LAN payload field.
    public var herdDefenseDamage: Double {
        guard isLandHerdHerbivore else { return attackDamage }
        switch family {
        case .ceratopsian:
            return max(5, min(14, authoringLengthMetres * 1.15))
        case .armoredHerbivore:
            return max(4, min(12, authoringLengthMetres * 0.95))
        case .sauropod:
            return max(6, min(15, authoringLengthMetres * 0.60))
        case .unusualHerbivore:
            return max(5, min(12, authoringLengthMetres * 0.75))
        case .hadrosaur:
            return max(3, min(8, authoringLengthMetres * 0.55))
        default:
            return attackDamage
        }
    }

    /// Multiplier applied only to incoming land-predator damage in a V2
    /// profile. Player, environmental, projectile, and ordinary V1 damage
    /// deliberately retain their existing values.
    public var herdPredatorDamageMultiplier: Double {
        guard isLandHerdHerbivore else { return 1 }
        switch family {
        case .armoredHerbivore: return 0.55
        case .ceratopsian: return 0.65
        case .sauropod: return 0.70
        case .unusualHerbivore: return 0.75
        case .hadrosaur: return 0.85
        default: return 1
        }
    }

    public var herdKnockbackResistance: Double {
        guard isLandHerdHerbivore else { return 0 }
        switch family {
        case .armoredHerbivore: return 0.65
        case .ceratopsian: return 0.55
        case .sauropod: return 0.50
        case .unusualHerbivore: return 0.35
        case .hadrosaur: return 0.15
        default: return 0
        }
    }

    /// A distinct, immutable signature for source-synthesized creature audio.
    /// The canonical roster ordering is frozen with `PrehistoricWorldProfile`;
    /// it is therefore safe to use as authored presentation metadata.
    public var soundProfile: PrehistoricSoundProfile {
        let signature = (Self.all.firstIndex { $0.id == id } ?? 0) + 1
        return PrehistoricSoundProfile(
            signature: signature,
            formantFrequency: 430 + signature * 37,
            pulseCount: 2 + signature % 3,
            timbreIndex: signature % 4,
            cadenceOffset: signature % 7
        )
    }

    public func soundName(for cue: PrehistoricSoundCue) -> String {
        "entity.\(id).\(cue.rawValue)"
    }

    public var soundNames: [String] {
        PrehistoricSoundCue.allCases.map { soundName(for: $0) }
    }

    /// A unique source-synthesis motif for every species/cue pair. Audio uses
    /// this only to differentiate presentation; it is not saved or simulated.
    public func soundSignature(for cue: PrehistoricSoundCue) -> Int {
        let cueIndex = PrehistoricSoundCue.allCases.firstIndex(of: cue) ?? 0
        return soundProfile.signature * PrehistoricSoundCue.allCases.count + cueIndex
    }

    /// Ordinary XP-orb value for a player-attributed kill. It reflects the
    /// configured combat threat (durability, active attack, and behaviour),
    /// rather than visual body length. `xpReward` also feeds the existing
    /// catalyst-bloom value by design, keeping both systems consistent.
    public var combatXPReward: Int {
        combatXPReward(ecosystemCombat: false)
    }

    /// V2 profiles make land herbivores active, resistant defenders. Their
    /// player-kill reward includes those real combat traits, while the legacy
    /// value remains frozen for V1 saves.
    public func combatXPReward(ecosystemCombat: Bool) -> Int {
        let healthTier = max(1, Int((max(0, health) / 10).rounded(.up)))
        let herdDefender = ecosystemCombat && isLandHerdHerbivore
        let activeThreat = isPredatory || canCharge || herdDefender
        let effectiveDamage = herdDefender ? herdDefenseDamage : attackDamage
        let damageTier = activeThreat
            ? max(1, Int((max(0, effectiveDamage) / 3).rounded(.up)))
            : 0
        let behaviourTier = (isPredatory ? 3 : 0) + (canCharge ? 2 : 0)
            + (herdDefender ? 2 : 0)
        let resistanceTier = herdDefender
            ? max(1, Int(((1 - herdPredatorDamageMultiplier) * 4).rounded(.up)))
            : 0
        return min(24, max(2, healthTier + damageTier + behaviourTier + resistanceTier))
    }

    /// Conservative voxel envelope used for spawn admission and body-aware
    /// path nodes. It intentionally exceeds the collision AABB for long
    /// necks/tails and open wings: physics cannot pass through a block, but a
    /// narrow AABB alone would let the visible creature repeatedly clip it.
    public var bodyClearanceRadius: Int {
        switch medium {
        case .land:
            switch family {
            case .sauropod:
                return min(6, max(2, Int((authoringLengthMetres * 0.25).rounded(.up))))
            case .largeTheropod, .ceratopsian, .armoredHerbivore, .unusualHerbivore:
                return min(4, max(1, Int((authoringLengthMetres * 0.18).rounded(.up))))
            default:
                return max(0, Int((collisionWidth / 2).rounded(.up)))
            }
        case .air:
            return flightOpenClearanceRadius
        case .aquatic:
            return min(4, max(1, Int((authoringLengthMetres * 0.20).rounded(.up))))
        }
    }

    public var bodyClearanceHeight: Int {
        switch medium {
        case .land where family == .sauropod:
            return min(7, max(2, Int((authoringLengthMetres * 0.20).rounded(.up))))
        case .land:
            return max(1, Int(collisionHeight.rounded(.up)))
        case .air:
            return max(2, Int(collisionHeight.rounded(.up)) + 1)
        case .aquatic:
            return max(1, Int(collisionHeight.rounded(.up)))
        }
    }

    /// Feet must be supported under the physical collision body, not under a
    /// tail/neck/wing visual envelope. The larger envelope still has to be
    /// empty above the site; decoupling it from support prevents a sauropod
    /// from requiring an implausible 13×13 perfectly level lawn.
    public var groundSupportRadius: Int {
        min(bodyClearanceRadius, max(0, Int((collisionWidth / 2).rounded(.up))))
    }

    /// Open-wing route clearance stays separate from the folded landing body
    /// footprint. The cap bounds every corridor probe while still rejecting a
    /// visibly implausible canopy/narrow-gap route for giant flyers.
    public var flightOpenClearanceRadius: Int {
        guard medium == .air else { return 0 }
        return min(6, max(1, Int((authoringLengthMetres * 0.50).rounded(.up))))
    }

    public var flightFoldedClearanceRadius: Int {
        guard medium == .air else { return bodyClearanceRadius }
        return max(1, Int((collisionWidth / 2).rounded(.up)))
    }

    private static func definition(
        _ shortName: String,
        _ displayName: String,
        _ medium: PrehistoricCreatureMedium,
        _ family: PrehistoricCreatureFamily,
        _ metres: Double,
        weight: Double = 8,
        pack: ClosedRange<Int> = 1...3
    ) -> PrehistoricCreatureDefinition {
        let widthFactor: Double
        let heightFactor: Double
        switch medium {
        case .land:
            widthFactor = 0.22; heightFactor = 0.25
        case .air:
            widthFactor = 0.17; heightFactor = 0.16
        case .aquatic:
            widthFactor = 0.18; heightFactor = 0.18
        }
        let width = max(0.35, min(3.6, metres * widthFactor))
        let height = max(0.35, min(4.4, metres * heightFactor))
        let predator = family.isPredatory
        let health = max(6, min(120, metres * (predator ? 5.2 : 4.4)))
        let speed = max(0.055, min(0.19, 0.075 + (predator ? 0.035 : 0.012)))
        let attack = predator || family.canCharge ? max(2, min(24, metres * 1.15)) : 1
        return PrehistoricCreatureDefinition(
            id: "prehistoric.\(shortName)", displayName: displayName, medium: medium,
            family: family, authoringLengthMetres: metres, collisionWidth: width,
            collisionHeight: height, health: health, speed: speed, attackDamage: attack,
            spawnWeight: weight, minPack: pack.lowerBound, maxPack: pack.upperBound
        )
    }

    /// Frozen in the same canonical order as `PrehistoricWorldProfile`.
    public static let all: [PrehistoricCreatureDefinition] = [
        definition("compsognathus", "Compsognathus", .land, .smallTheropod, 1, weight: 14, pack: 3...6),
        definition("coelophysis", "Coelophysis", .land, .smallTheropod, 3, weight: 10, pack: 2...5),
        definition("velociraptor", "Velociraptor", .land, .smallTheropod, 2, weight: 10, pack: 2...4),
        definition("dilophosaurus", "Dilophosaurus", .land, .smallTheropod, 6, weight: 6, pack: 1...3),
        definition("deinonychus", "Deinonychus", .land, .smallTheropod, 3.5, weight: 8, pack: 2...4),
        definition("allosaurus", "Allosaurus", .land, .largeTheropod, 9, weight: 3, pack: 1...2),
        definition("ceratosaurus", "Ceratosaurus", .land, .largeTheropod, 6, weight: 4, pack: 1...2),
        definition("carnotaurus", "Carnotaurus", .land, .largeTheropod, 7.5, weight: 3, pack: 1...2),
        definition("tyrannosaurus", "Tyrannosaurus", .land, .largeTheropod, 12, weight: 2, pack: 1...1),
        definition("spinosaurus", "Spinosaurus", .land, .largeTheropod, 14, weight: 1, pack: 1...1),
        definition("dryosaurus", "Dryosaurus", .land, .hadrosaur, 3, weight: 10, pack: 2...5),
        definition("pachycephalosaurus", "Pachycephalosaurus", .land, .armoredHerbivore, 4.5, weight: 7, pack: 2...4),
        definition("gallimimus", "Gallimimus", .land, .hadrosaur, 6, weight: 8, pack: 2...5),
        definition("oviraptor", "Oviraptor", .land, .smallTheropod, 2, weight: 9, pack: 2...4),
        definition("parasaurolophus", "Parasaurolophus", .land, .hadrosaur, 9, weight: 4, pack: 2...4),
        definition("edmontosaurus", "Edmontosaurus", .land, .hadrosaur, 10, weight: 3, pack: 2...3),
        definition("iguanodon", "Iguanodon", .land, .hadrosaur, 9, weight: 4, pack: 2...3),
        definition("triceratops", "Triceratops", .land, .ceratopsian, 8, weight: 4, pack: 2...3),
        definition("styracosaurus", "Styracosaurus", .land, .ceratopsian, 5.5, weight: 5, pack: 2...3),
        definition("stegosaurus", "Stegosaurus", .land, .armoredHerbivore, 8, weight: 4, pack: 1...3),
        definition("ankylosaurus", "Ankylosaurus", .land, .armoredHerbivore, 7, weight: 4, pack: 1...3),
        definition("diplodocus", "Diplodocus", .land, .sauropod, 24, weight: 1, pack: 1...2),
        definition("brachiosaurus", "Brachiosaurus", .land, .sauropod, 21, weight: 1, pack: 1...2),
        definition("therizinosaurus", "Therizinosaurus", .land, .unusualHerbivore, 9, weight: 3, pack: 1...2),
        definition("dimorphodon", "Dimorphodon", .air, .flyer, 1.4, weight: 12, pack: 2...4),
        definition("rhamphorhynchus", "Rhamphorhynchus", .air, .flyer, 1.8, weight: 10, pack: 2...4),
        definition("pteranodon", "Pteranodon", .air, .flyer, 6, weight: 5, pack: 1...2),
        definition("tapejara", "Tapejara", .air, .flyer, 4, weight: 7, pack: 1...3),
        definition("quetzalcoatlus", "Quetzalcoatlus", .air, .flyer, 10, weight: 2, pack: 1...1),
        definition("microraptor", "Microraptor", .air, .flyer, 0.8, weight: 12, pack: 2...5),
        definition("ichthyosaurus", "Ichthyosaurus", .aquatic, .ichthyosaur, 2, weight: 10, pack: 2...4),
        definition("plesiosaurus", "Plesiosaurus", .aquatic, .longNeckedSwimmer, 3.5, weight: 6, pack: 1...3),
        definition("elasmosaurus", "Elasmosaurus", .aquatic, .longNeckedSwimmer, 10, weight: 2, pack: 1...2),
        definition("liopleurodon", "Liopleurodon", .aquatic, .marinePredator, 6, weight: 3, pack: 1...2),
        definition("mosasaurus", "Mosasaurus", .aquatic, .marinePredator, 14, weight: 1, pack: 1...1),
        definition("deinosuchus", "Deinosuchus", .aquatic, .shorePredator, 10, weight: 2, pack: 1...1),
    ]

    public static func named(_ id: String) -> PrehistoricCreatureDefinition? {
        // The static ordered table is small (36) and preserves the project's
        // no-unordered-state discipline; lookup cost is irrelevant to a tick.
        all.first { $0.id == id }
    }

    public static var allIDs: [String] { all.map(\.id) }
}

public func prehistoricSpawnEntries(
    profile: PrehistoricWorldProfile,
    category: String
) -> [SpawnEntry] {
    let medium: PrehistoricCreatureMedium?
    switch category {
    case "creature": medium = .land
    case "ambient": medium = .air
    case "water": medium = .aquatic
    default: medium = nil
    }
    guard let medium else { return [] }
    let permitted = profile.creatureIDs(for: medium)
    let roster: [SpawnEntry] = PrehistoricCreatureDefinition.all.compactMap { definition in
        guard definition.medium == medium, permitted.contains(definition.id) else { return nil }
        return (mob: definition.id, weight: definition.spawnWeight,
                minPack: definition.minPack, maxPack: definition.maxPack)
    }
    // Wild fish are a deliberately narrow ecosystem resource, not a return to
    // modern domestic fauna. They give the roster's fish-focused swimmers and
    // marine predators a real, bounded prey source in profiles that otherwise
    // replace the ordinary water table with prehistoric creatures.
    if medium == .aquatic, !roster.isEmpty {
        return roster + [
            ("cod", 4, 2, 4),
            ("salmon", 3, 1, 3),
            ("tropical_fish", 2, 2, 4),
        ]
    }
    return roster
}

/// Bounded semantic/action fields exposed on saves and LAN snapshots.
public func normalizedPrehistoricAction(_ raw: String?) -> PrehistoricAction {
    guard let raw, let action = PrehistoricAction(rawValue: raw) else { return .idle }
    return action
}

/// Derives the private controller stream from immutable world/entity inputs.
/// Keeping this outside the class lets construction select the same stream
/// before it enters the ordinary `LivingEntity` initializer chain.
private func prehistoricControllerSeed(
    world: World,
    definition: PrehistoricCreatureDefinition,
    x: Double,
    y: Double,
    z: Double,
    instanceSalt: UInt32 = 0
) -> UInt32 {
    hash3(
        world.seed ^ hashString(definition.id),
        ifloor(x * 16), ifloor(y * 16), ifloor(z * 16),
        0x5052_4548 ^ instanceSalt
    )
}

/// One bounded node in an aquatic creature's locally validated route.  Parent
/// indices preserve deterministic breadth-first discovery without relying on
/// unordered collection iteration.
private struct PrehistoricWaterRouteNode {
    let x: Int
    let y: Int
    let z: Int
    let parent: Int
}

/// The limits on V2+ land predation. Without them every land predator, down
/// to a 1 m Compsognathus, hunted any herd herbivore every few seconds, and a
/// predator returned to hunting moments after each kill, so a region's
/// dinosaurs bled away between dawn refills. The policy reads only immutable
/// definition data and the predator's own age: it adds no RNG draw, no save
/// field and no LAN payload, and it applies in place to existing V2/V3 saves.
enum PrehistoricPredationPolicy {
    /// A land predator hunts herd prey no longer than this multiple of its
    /// own authoring length (mirroring the aquatic "smaller prey" rule).
    static let maximumPreyLengthRatio = 1.5
    /// Ticks of the predator's own simulation during which it starts no new
    /// hunt after a genuine kill (five in-game minutes).
    static let satiationTicks = 6_000

    static func landPredator(
        _ predator: PrehistoricCreatureDefinition, mayHunt prey: PrehistoricCreatureDefinition
    ) -> Bool {
        predator.isLandPredator && prey.isLandHerdHerbivore
            && prey.authoringLengthMetres <= predator.authoringLengthMetres * maximumPreyLengthRatio
    }
}

/// A bounded, deterministic land-prey acquisition goal used only by V2
/// prehistoric profiles. It owns no saved path: normal target/navigation
/// state is intentionally transient and re-acquires from the authoritative
/// loaded herd after a resume. `PrehistoricPredationPolicy` bounds which prey
/// qualifies and pauses acquisition while the predator is satiated.
private final class PrehistoricHuntTargetGoal: Goal {
    private static let acquisitionInterval = 80
    private let range: Double

    init(_ mob: PrehistoricCreature, _ priority: Int, range: Double) {
        self.range = range
        super.init(mob, priority)
        flags = GoalFlag.target
    }

    override func canUse() -> Bool {
        guard let predator = mob as? PrehistoricCreature,
              predator.usesPredatorHerdCombat,
              predator.definition.isLandPredator,
              !predator.isSatiatedAfterKill
        else { return false }

        // Goal selectors try new targets only every other entity tick. Keep
        // phases even so every persisted-ID phase is reachable, and never
        // consume controller/global RNG merely to decide when to hunt.
        let phase = (abs(predator.id) % (Self.acquisitionInterval / 2)) * 2
        guard predator.age % Self.acquisitionInterval == phase,
              let prey = predator.nearestLandHerdPrey(range: range)
        else { return false }
        predator.setTarget(prey)
        predator.setAction(.alert, ticks: 20)
        return true
    }

    override func canContinue() -> Bool {
        guard let predator = mob as? PrehistoricCreature,
              let prey = predator.target as? PrehistoricCreature,
              !prey.dead, prey.deathTime <= 0,
              prey.definition.isLandHerdHerbivore,
              predator.distanceToSq(prey) <= (range * 1.5) * (range * 1.5)
        else {
            mob.setTarget(nil)
            return false
        }
        return true
    }
}

/// Lets a mixed land herd rally only against a prehistoric land predator that
/// just injured it. The scan is deliberately local and ID tie-broken so herd
/// members do not form a world-wide target graph or inherit insertion-order
/// behavior from the spatial query.
private final class PrehistoricHerdDefenseTargetGoal: Goal {
    private let range: Double

    init(_ mob: PrehistoricCreature, _ priority: Int, range: Double = 18) {
        self.range = range
        super.init(mob, priority)
        flags = GoalFlag.target
    }

    override func canUse() -> Bool {
        guard let defender = mob as? PrehistoricCreature,
              defender.usesPredatorHerdCombat,
              defender.definition.isLandHerdHerbivore,
              let threat = defender.nearestHerdThreat(range: range)
        else { return false }
        defender.setTarget(threat)
        defender.setAction(.alert, ticks: 24)
        return true
    }

    override func canContinue() -> Bool {
        guard let defender = mob as? PrehistoricCreature,
              let threat = defender.target as? PrehistoricCreature,
              !threat.dead, threat.deathTime <= 0,
              threat.definition.isLandPredator,
              defender.distanceToSq(threat) <= (range * 1.5) * (range * 1.5)
        else {
            mob.setTarget(nil)
            return false
        }
        return true
    }
}

public final class PrehistoricCreature: Animal {
    /// Extra underwater ticks reserved between a cached route being reached
    /// and a revalidated ascent beginning. It covers the mandatory tick after
    /// a surface-to-dive transition without pretending that air is free.
    private static let breathingRouteReactionMargin = 8

    public let definition: PrehistoricCreatureDefinition
    private var movementTarget: (x: Double, y: Double, z: Double)?
    /// Non-persisted steering waypoints. Save/load deliberately recomputes
    /// them from authoritative terrain rather than retaining a route that may
    /// have been edited while its chunk was absent.
    private var swimRoute: [(x: Double, y: Double, z: Double)] = []
    /// A verified reserve for a connected route to open air. The route itself
    /// is deliberately not persisted (or trusted after terrain changes), but
    /// recording its conservative air cost lets a deep swimmer begin ascent
    /// before its ordinary reserve falls below what the route requires.
    private var breathingRouteAirBudget: Int?
    /// Keeps route probes bounded when a basin has no viable open-water path.
    /// A fresh creature/load has no value and probes once immediately; later
    /// probes are throttled below.
    private var lastBreathingRouteProbeAge: Int?
    /// The predator's own `age` until which it starts no new hunt after a
    /// kill (`PrehistoricPredationPolicy.satiationTicks`). Deliberately
    /// session-only: a resumed predator is simply hungry again, so no save or
    /// LAN field is needed.
    private var satiatedUntilAge: Int?

    public override var type: String { definition.id }
    public override func ambientSound() -> String? { definition.soundName(for: .ambient) }
    public override func hurtSound() -> String { definition.soundName(for: .hurt) }
    public override func deathSound() -> String { definition.soundName(for: .death) }
    public override func attackSound() -> String { definition.soundName(for: .attack) }
    public override var avoidsWaterWhileMoving: Bool {
        definition.medium == .land && super.avoidsWaterWhileMoving
    }
    public override var requiresBodyAwarePathing: Bool {
        definition.medium == .land && definition.bodyClearanceRadius > 1
    }
    public override func hasPathClearance(atX x: Int, y: Int, z: Int) -> Bool {
        prehistoricHasClearance(world, definition: definition, x: x, y: y, z: z, requireGround: true)
    }

    /// The versioned profile, rather than an entity save field, selects the
    /// ecosystem rules. A V1 entity therefore remains V1 when a saved world is
    /// resumed, while V2 reacquires transient targets from its loaded world.
    fileprivate var usesPredatorHerdCombat: Bool {
        world.generationSettings.preset.supportsPredatorHerdCombat
    }

    /// True while a land predator is still digesting its last kill.
    var isSatiatedAfterKill: Bool {
        guard let satiatedUntilAge else { return false }
        return age < satiatedUntilAge
    }

    public init(world: World, definition: PrehistoricCreatureDefinition) {
        self.definition = definition
        // This bypasses LivingEntity's historical gameRng-based constructor
        // path. Spawn/load order for an opt-in creature can therefore never
        // perturb unrelated global gameplay randomness.
        super.init(world: world, deterministicRNGSeed: prehistoricControllerSeed(
            world: world, definition: definition, x: 0, y: 0, z: 0
        ))
        width = definition.collisionWidth
        height = definition.collisionHeight
        maxHealth = definition.health
        health = definition.health
        speed = definition.speed
        let ecosystemCombat = usesPredatorHerdCombat
        attackDamage = ecosystemCombat && definition.isLandHerdHerbivore
            ? definition.herdDefenseDamage
            : definition.attackDamage
        if ecosystemCombat && definition.isLandHerdHerbivore {
            kbResist = definition.herdKnockbackResistance
        }
        xpReward = definition.combatXPReward(ecosystemCombat: ecosystemCombat)
        data.prehistoricAction = PrehistoricAction.idle.rawValue
        data.prehistoricActionTicks = 0
        seedControllerRNGForCurrentPosition()

        switch definition.medium {
        case .land:
            category = "creature"
            nav.avoidWater = true
            addBasicGoals(definition.speed / 0.09, definition.speed / 0.07)
            if definition.isPredatory || (definition.canCharge && !ecosystemCombat) {
                targetGoals.add(HurtByTargetGoal(self, 1, true))
                goals.add(MeleeAttackGoal(self, 2, definition.canCharge ? 1.35 : 1.15))
            }
            if ecosystemCombat && definition.isLandHerdHerbivore {
                targetGoals.add(PrehistoricHerdDefenseTargetGoal(self, 1))
                // This beats the ordinary priority-1 panic response only while
                // a nearby herd member has a live prehistoric-predator threat.
                goals.add(MeleeAttackGoal(self, 0, 1.18))
            }
            if definition.isPredatory {
                if ecosystemCombat {
                    let huntRange = definition.family == .largeTheropod ? 22.0 : 16.0
                    targetGoals.add(PrehistoricHuntTargetGoal(self, 2, range: huntRange))
                }
                // Predators replace the opt-in profile's ordinary hostile
                // table. This remains a normal host-side target goal—not a
                // renderer/action cue—and excludes creative/invisible players
                // through the goal's existing shared filter path.
                targetGoals.add(NearestTargetGoal(self, 3, { target in
                    target.isPlayer && !target.dead
                }, definition.family == .largeTheropod ? 20 : 14))
            }
        case .air:
            category = "ambient"
            nav.avoidWater = false
            noGravity = true
            stepHeight = 0
        case .aquatic:
            category = "water"
            nav.avoidWater = false
            noGravity = true
            // Aquatic roster members are air-breathing reptiles, not fish.
            // `baseLivingTick` therefore owns the ordinary underwater air
            // countdown; the controller below plans an actual open-water
            // surface before the reserve becomes unsafe.
            breathesWater = false
            breathesWaterOnly = false
            data.prehistoricAirSupply = airSupply
            stepHeight = 0
        }
    }

    /// Stable nearest-prey selection for a land predator. The explicit ID
    /// tiebreak preserves deterministic behavior even if a world later changes
    /// its entity insertion order. Only prey the predation policy admits for
    /// this predator's size qualifies.
    fileprivate func nearestLandHerdPrey(range: Double) -> PrehistoricCreature? {
        let candidates = world.getEntitiesNear(x, y, z, range) { entity in
            guard let other = entity as? PrehistoricCreature else { return false }
            return other !== self && !other.dead && other.deathTime <= 0
                && PrehistoricPredationPolicy.landPredator(self.definition, mayHunt: other.definition)
        }
        var best: PrehistoricCreature?
        var bestDistance = Double.infinity
        for candidate in candidates {
            guard let other = candidate as? PrehistoricCreature, canSee(other) else { continue }
            let distance = distanceToSq(other)
            if distance < bestDistance
                || (distance == bestDistance && other.id < (best?.id ?? Int.max)) {
                best = other
                bestDistance = distance
            }
        }
        return best
    }

    /// Finds a just-injured mixed-herd member and its prehistoric predator.
    /// The lexicographic `(ally distance, ally id, predator distance, predator
    /// id)` selection avoids treating `getEntitiesNear` insertion order as a
    /// simulation decision.
    fileprivate func nearestHerdThreat(range: Double) -> PrehistoricCreature? {
        var herdMembers: [PrehistoricCreature] = [self]
        herdMembers += world.getEntitiesNear(x, y, z, range) { entity in
            guard let other = entity as? PrehistoricCreature else { return false }
            return other !== self && !other.dead && other.deathTime <= 0
                && other.definition.isLandHerdHerbivore
        }.compactMap { $0 as? PrehistoricCreature }

        var bestThreat: PrehistoricCreature?
        var bestAllyDistance = Double.infinity
        var bestAllyID = Int.max
        var bestThreatDistance = Double.infinity
        var bestThreatID = Int.max
        for herdMember in herdMembers {
            guard herdMember.hurtTime > 0,
                  let threat = herdMember.lastAttacker as? PrehistoricCreature,
                  !threat.dead, threat.deathTime <= 0,
                  threat.definition.isLandPredator
            else { continue }
            let allyDistance = distanceToSq(herdMember)
            let threatDistance = distanceToSq(threat)
            let betterAlly = allyDistance < bestAllyDistance
                || (allyDistance == bestAllyDistance && herdMember.id < bestAllyID)
            let sameAlly = allyDistance == bestAllyDistance && herdMember.id == bestAllyID
            let betterThreat = sameAlly && (threatDistance < bestThreatDistance
                || (threatDistance == bestThreatDistance && threat.id < bestThreatID))
            if betterAlly || betterThreat {
                bestThreat = threat
                bestAllyDistance = allyDistance
                bestAllyID = herdMember.id
                bestThreatDistance = threatDistance
                bestThreatID = threat.id
            }
        }
        return bestThreat
    }

    public override func load(_ d: [String: Any]) {
        super.load(d)
        data.prehistoricAction = normalizedPrehistoricAction(data.prehistoricAction).rawValue
        data.prehistoricActionTicks = max(0, min(1_200, data.prehistoricActionTicks ?? 0))
        ambientSoundTimer = max(0, min(300, data.prehistoricAmbientSoundTimer ?? 0))
        data.prehistoricAmbientSoundTimer = ambientSoundTimer
        if let a = data.prehistoricRngA, let b = data.prehistoricRngB,
           let c = data.prehistoricRngC, let d = data.prehistoricRngD {
            rng = RandomX(stateWords: (a, b, c, d))
        } else {
            seedControllerRNGForCurrentPosition()
        }
        if definition.medium == .aquatic {
            airSupply = max(0, min(300, data.prehistoricAirSupply ?? 300))
            data.prehistoricAirSupply = airSupply
        } else {
            data.prehistoricAirSupply = nil
        }
    }

    public override func save() -> [String: Any] {
        // A save may run between simulation ticks, so retain its current
        // controller/audio timing instead of relying solely on tick's defer.
        persistControllerRNGState()
        return super.save()
    }

    public var action: PrehistoricAction {
        normalizedPrehistoricAction(data.prehistoricAction)
    }

    private func playSound(_ cue: PrehistoricSoundCue, volume: Double = 1, pitch: Double = 1) {
        world.hooks.playSound(definition.soundName(for: cue), x, y, z, volume, pitch)
    }

    /// Controller-internal transition seam. It remains module-internal so the
    /// action-to-cue contract can be exercised directly without widening the
    /// public save/LAN surface.
    func setAction(_ action: PrehistoricAction, ticks: Int = 0, emitsSound: Bool = true) {
        let previous = self.action
        data.prehistoricAction = action.rawValue
        data.prehistoricActionTicks = max(0, min(1_200, ticks))
        data.grazing = action == .browse
        // Action timers are refreshed frequently by the controllers. Audio is
        // emitted only for a semantic transition, never every AI tick.
        if emitsSound, previous != action {
            playSound(action.soundCue, volume: 0.84,
                      pitch: 0.90 + Double(definition.soundProfile.timbreIndex) * 0.035)
        }
    }

    /// Module-internal for the deterministic controller/cue contract test.
    func consumeActionTick() {
        let remaining = max(0, min(1_200, data.prehistoricActionTicks ?? 0))
        if remaining > 0 {
            data.prehistoricActionTicks = remaining - 1
            // A timed state may immediately choose a new action in the same
            // controller tick. Expiry is a bookkeeping handoff, not an idle
            // performance, so do not stack an idle cue before the real cue.
            if remaining == 1 { setAction(.idle, emitsSound: false) }
        }
    }

    public override func tick() {
        defer { persistControllerRNGState() }
        switch definition.medium {
        case .land:
            super.tick()
            if dead || deathTime > 0 { return }
            tickGroundAction()
            tickLocomotionSound()
        case .air:
            tickFlight()
        case .aquatic:
            tickSwim()
        }
    }

    /// Called by the central spawn path after authoritative coordinates have
    /// been assigned. The seed is independent of process-global `gameRng`, so
    /// loading unrelated entities first cannot alter this creature's decisions.
    func seedControllerRNGForCurrentPosition() {
        rng = RandomX(prehistoricControllerSeed(
            world: world, definition: definition, x: x, y: y, z: z,
            instanceSalt: data.prehistoricSeedSalt ?? UInt32(truncatingIfNeeded: id)
        ))
        persistControllerRNGState()
    }

    private func persistControllerRNGState() {
        let state = rng.stateWords
        data.prehistoricRngA = state.0
        data.prehistoricRngB = state.1
        data.prehistoricRngC = state.2
        data.prehistoricRngD = state.3
        data.prehistoricAmbientSoundTimer = max(0, min(300, ambientSoundTimer))
    }

    private func tickGroundAction() {
        consumeActionTick()
        if let target, !target.dead, definition.canCharge {
            let distance = distanceTo(target)
            if distance < 12, action != .recover {
                setAction(.charge, ticks: min(30, max(8, Int(distance * 3))))
                moveForward = 1.25
                lookAt(target.x, target.centerY(), target.z, 0.42, 0.15)
            }
        } else if action == .idle, age % 160 == 0, rng.nextFloat() < 0.38 {
            setAction(definition.isPredatory ? .alert : .browse, ticks: 30 + rng.nextInt(45))
        }
    }

    public override func doMeleeAttack(_ target: LivingEntity) {
        let huntedHerdHerbivore = usesPredatorHerdCombat
            && definition.isLandPredator
            && (target as? PrehistoricCreature)?.definition.isLandHerdHerbivore == true
        let wasCharging = action == .charge
        if wasCharging {
            attackAnim = 1
            target.hurt(max(1, attackDamage * 1.5), "prehistoric_charge", self)
            playSound(.attack, volume: 0.95, pitch: 0.75)
            setAction(.recover, ticks: 24)
        } else {
            super.doMeleeAttack(target)
        }
        if huntedHerdHerbivore && (target.health <= 0 || target.deathTime > 0) {
            // Feeding is a bounded presentation/action state after a genuine
            // prey kill, followed by a session-only satiation window. It
            // deliberately does not introduce hunger/carcass persistence
            // beyond the existing authoritative death/drop path.
            setAction(.eat, ticks: 48)
            setTarget(nil)
            satiatedUntilAge = age + PrehistoricPredationPolicy.satiationTicks
        }
    }

    @discardableResult
    public override func hurt(_ amount: Double, _ source: String, _ attacker: Entity? = nil) -> Bool {
        let predatorAttack = usesPredatorHerdCombat
            && definition.isLandHerdHerbivore
            && (attacker as? PrehistoricCreature).map {
                $0.world === world && $0.definition.isLandPredator
            } == true
        let mitigatedAmount = predatorAttack ? amount * definition.herdPredatorDamageMultiplier : amount
        return super.hurt(mitigatedAmount, source, attacker)
    }

    private func tickFlight() {
        baseLivingTick()
        if dead || deathTime > 0 { return }
        consumeActionTick()
        let wet = touchesWater(atX: x, y: y, z: z, below: 0.1)
        let surface = Double(world.surfaceY(ifloor(x), ifloor(z)))

        // An idle flyer with a timed action is resting on a previously
        // validated footprint. It does not keep steering or drift into an
        // unloaded chunk during that rest interval.
        if action == .idle, movementTarget == nil,
           (data.prehistoricActionTicks ?? 0) > 0,
           flyerLandingTarget(atX: ifloor(x), z: ifloor(z)) != nil {
            vx = 0; vy = 0; vz = 0
            onGround = true
            data.airborne = false
            tickManualLimbAnimation()
            tickManualAmbient()
            return
        }

        if let target = movementTarget,
           !flightRouteIsClear(to: target, landing: action == .landing) {
            movementTarget = nil
        }

        if action == .landing {
            if movementTarget == nil {
                if let landing = findLandingTarget(radius: 12) {
                    movementTarget = landing
                } else {
                    setAction(.glide, ticks: 40)
                    movementTarget = makeFlightTarget()
                }
            }
        } else if wet || y < surface + 0.8 {
            setAction(.takeoff, ticks: 36)
            movementTarget = makeFlightTarget()
        } else if movementTarget == nil || horizontalCollision {
            if age % 240 == 0, let landing = findLandingTarget(radius: 12) {
                setAction(.landing, ticks: 160)
                movementTarget = landing
            } else {
                if action == .idle { setAction(.takeoff, ticks: 36) }
                movementTarget = makeFlightTarget()
            }
        } else if age % 240 == 0, let landing = findLandingTarget(radius: 12) {
            setAction(.landing, ticks: 160)
            movementTarget = landing
        }

        guard let target = movementTarget else {
            // A loaded-world fallback prefers a real landing; when no valid
            // local footprint exists, stop rather than asking streaming to
            // create terrain or flying through an unknown chunk.
            if let landing = findLandingTarget(radius: 12) {
                setAction(.landing, ticks: 160)
                movementTarget = landing
            } else {
                vx = 0; vy = 0; vz = 0
                setAction(.idle, ticks: 20)
                data.airborne = false
                return
            }
            guard let landing = movementTarget else { return }
            tickFlightToward(landing, wet: wet, surface: surface)
            return
        }
        tickFlightToward(target, wet: wet, surface: surface)
    }

    private func tickFlightToward(_ target: (x: Double, y: Double, z: Double), wet: Bool, surface: Double) {
        let dx = target.x - x, dy = target.y - y, dz = target.z - z
        let distance = max(0.001, (dx * dx + dy * dy + dz * dz).squareRoot())
        let landing = action == .landing
        let accelerating = action == .takeoff || action == .flap || wet || y < surface + 2
        let impulse = landing ? 0.024 : (accelerating ? 0.031 : 0.014)
        vx += dx / distance * impulse
        vy += dy / distance * impulse
        vz += dz / distance * impulse
        let maxSpeed = landing ? 0.16 : (accelerating ? 0.31 : 0.22)
        let horizontal = (vx * vx + vz * vz).squareRoot()
        if horizontal > maxSpeed {
            vx *= maxSpeed / horizontal
            vz *= maxSpeed / horizontal
        }
        vy = clampD(vy, landing ? -0.20 : -0.18, landing ? 0.12 : 0.22)
        move(vx, vy, vz)
        vx *= 0.91; vy *= 0.91; vz *= 0.91
        if vx * vx + vz * vz > 0.0004 {
            yaw += clampD(wrapAngle(detAtan2(-vx, vz) - yaw), -0.38, 0.38)
        }
        let horizontalDistance = (dx * dx + dz * dz).squareRoot()
        if landing,
           flyerLandingTarget(atX: ifloor(target.x), z: ifloor(target.z)) != nil,
           horizontalDistance < 0.55,
           abs(y - target.y) < 0.35 {
            // The target passed the exact body/approach validation and the
            // route was collision-swept, so this small final settle cannot
            // phase through a constructed wall or unknown terrain.
            setPos(target.x, target.y, target.z)
            vx = 0; vy = 0; vz = 0
            onGround = true
            movementTarget = nil
            setAction(.idle, ticks: 90)
            data.airborne = false
        } else if landing, !flightRouteIsClear(to: target, landing: true) {
            movementTarget = findLandingTarget(radius: 12) ?? makeFlightTarget()
            if movementTarget == nil { setAction(.idle, ticks: 20) }
        } else if wet || y < surface + 0.8 {
            setAction(.takeoff, ticks: 24)
            movementTarget = makeFlightTarget()
        } else if !landing && (distance < 2 || horizontalCollision) {
            setAction(.glide, ticks: 50 + rng.nextInt(40))
            movementTarget = makeFlightTarget()
        } else if action == .idle {
            setAction(accelerating ? .flap : .glide, ticks: 40)
        }
        // Landing remains airborne until the validated settle above clears it;
        // otherwise the renderer folds wings while the entity is still moving
        // through the approach volume.
        data.airborne = action != .idle
        tickManualLimbAnimation()
        tickLocomotionSound()
        tickManualAmbient()
    }

    private func makeFlightTarget() -> (x: Double, y: Double, z: Double)? {
        let ceiling = Double(world.info.minY + world.info.height - 4)
        for _ in 0..<8 {
            let heading = rng.nextFloat() * .pi * 2
            let distance = 4 + rng.nextFloat() * 12
            let px = x + detSin(heading) * distance
            let pz = z + detCos(heading) * distance
            let surface = Double(world.surfaceY(ifloor(px), ifloor(pz)))
            let py = min(ceiling, max(surface + 4, y + (rng.nextFloat() - 0.35) * 7))
            guard flightSpaceIsClear(px, py, pz), flightRouteIsClear(to: (px, py, pz), landing: false) else { continue }
            return (px, py, pz)
        }
        // A vertical local lift is a bounded fallback for a one-chunk world
        // fixture. It remains inside the currently loaded column and the
        // periodic landing branch still returns the flyer to a valid perch.
        let localSurface = Double(world.surfaceY(ifloor(x), ifloor(z)))
        let local = (x, min(ceiling, max(localSurface + 4, y + 4)), z)
        return flightSpaceIsClear(local.0, local.1, local.2) ? local : nil
    }

    private func findLandingTarget(radius: Int) -> (x: Double, y: Double, z: Double)? {
        let originX = ifloor(x), originZ = ifloor(z)
        let directions = [(0, 0), (1, 0), (0, 1), (-1, 0), (0, -1), (1, 1), (-1, 1), (-1, -1), (1, -1)]
        for distance in stride(from: 0, through: max(0, min(16, radius)), by: 4) {
            for (dx, dz) in directions {
                let tx = originX + dx * distance, tz = originZ + dz * distance
                if let landing = flyerLandingTarget(atX: tx, z: tz),
                   flightRouteIsClear(to: landing, landing: true) {
                    return landing
                }
            }
        }
        return nil
    }

    private func flyerLandingTarget(atX x: Int, z: Int) -> (x: Double, y: Double, z: Double)? {
        guard world.isLoadedAt(x, z) else { return nil }
        let y = world.surfaceY(x, z)
        guard y > world.info.minY,
              hasFlyerLandingClearance(atX: x, y: y, z: z)
        else { return nil }
        return (Double(x) + 0.5, Double(y), Double(z) + 0.5)
    }

    private func hasFlyerLandingClearance(atX x: Int, y: Int, z: Int) -> Bool {
        let foldedRadius = definition.flightFoldedClearanceRadius
        let openRadius = definition.flightOpenClearanceRadius
        let vertical = definition.bodyClearanceHeight
        for zz in (z - openRadius)...(z + openRadius) {
            for xx in (x - openRadius)...(x + openRadius) {
                guard world.isLoadedAt(xx, zz) else { return false }
                if abs(xx - x) <= foldedRadius && abs(zz - z) <= foldedRadius {
                    let ground = world.getBlock(xx, y - 1, zz) >> 4
                    guard ground > 0, ground < blockDefs.count, blockDefs[ground].solid else { return false }
                }
                for yy in y..<(y + vertical + 3) {
                    let cell = world.getBlock(xx, yy, zz)
                    let block = cell >> 4
                    if block == Int(B.water) || block == Int(B.lava)
                        || (block != 0 && (block >= blockDefs.count || !blockDefs[block].replaceable)) {
                        return false
                    }
                }
            }
        }
        return true
    }

    private func flightRouteIsClear(to target: (x: Double, y: Double, z: Double), landing: Bool) -> Bool {
        let dx = target.x - x, dy = target.y - y, dz = target.z - z
        let distance = (dx * dx + dy * dy + dz * dz).squareRoot()
        let steps = max(1, min(24, Int((distance / 1.5).rounded(.up))))
        for step in 1...steps {
            let fraction = Double(step) / Double(steps)
            let px = x + dx * fraction, py = y + dy * fraction, pz = z + dz * fraction
            if landing && step == steps {
                guard flyerLandingTarget(atX: ifloor(px), z: ifloor(pz)) != nil else { return false }
            } else if !flightSpaceIsClear(px, py, pz) {
                return false
            }
        }
        return true
    }

    private func flightSpaceIsClear(_ px: Double, _ py: Double, _ pz: Double) -> Bool {
        let radius = definition.flightOpenClearanceRadius
        let lower = ifloor(py)
        let upper = max(lower, ifloor(py + Double(definition.bodyClearanceHeight) - 0.000_001))
        for zz in (ifloor(pz) - radius)...(ifloor(pz) + radius) {
            for xx in (ifloor(px) - radius)...(ifloor(px) + radius) {
                guard world.isLoadedAt(xx, zz) else { return false }
                for yy in lower...upper {
                    let cell = world.getBlock(xx, yy, zz)
                    let block = cell >> 4
                    if block == Int(B.water) || block == Int(B.lava)
                        || (block != 0 && (block >= blockDefs.count || !blockDefs[block].replaceable)) {
                        return false
                    }
                }
            }
        }
        return true
    }

    private func tickSwim() {
        baseLivingTick()
        if dead || deathTime > 0 { return }
        consumeActionTick()
        if !inWater {
            swimRoute.removeAll(keepingCapacity: true)
            breathingRouteAirBudget = nil
            lastBreathingRouteProbeAge = nil
            setAction(.stranded, ticks: 40)
            movementTarget = nearestWaterTarget(radius: 8)
        } else if action == .surface && !underwater {
            // The eye has reached open air and the standard air reserve has
            // begun recovering. Keep a creature at its validated breathing
            // waypoint until it owns enough *ordinary* air for the cached
            // ascent plus a one-tick reaction margin. A deep swimmer must not
            // dive at a shallow 124-air threshold then discover a 64-block
            // route only after its reserve is already insufficient.
            let routeReserve = breathingRouteAirBudget ?? 0
            let diveReserve = min(300, max(
                285, routeReserve + Self.breathingRouteReactionMargin
            ))
            if airSupply >= diveReserve {
                swimRoute.removeAll(keepingCapacity: true)
                setAction(.dive, ticks: 50)
                movementTarget = makeSwimTarget(preferDepth: true)
                // The retained reserve admitted this dive, but it describes
                // the old deep route. Clear it so the first submerged tick
                // measures the actual new depth instead of forcing an
                // artificial immediate re-surface from stale state.
                breathingRouteAirBudget = nil
                lastBreathingRouteProbeAge = nil
            } else {
                // Waiting must be a genuine surface hold, not a lower reserve
                // threshold that lets the swimmer drift away from safe air.
                if let breathingWaypoint = swimRoute.last {
                    movementTarget = breathingWaypoint
                }
                vx = 0; vy = 0; vz = 0
                if let target = movementTarget {
                    data.swimTarget = [target.x, target.y, target.z]
                }
                data.prehistoricAirSupply = max(0, min(300, airSupply))
                tickManualLimbAnimation()
                tickManualAmbient()
                return
            }
        } else {
            let urgentAir = airSupply <= 120
            let cachedBudgetReached = breathingRouteAirBudget.map {
                airSupply <= min(300, $0 + Self.breathingRouteReactionMargin)
            } ?? false
            let routeRefreshDue: Bool
            if action == .surface {
                routeRefreshDue = movementTarget == nil || age % 40 == 0
            } else {
                // Probe once at construction/load while the reserve is full,
                // then only at a fixed cadence or when a recorded reserve is
                // reached. This preserves a physical start condition for a
                // deep ascent without doing a BFS on every swimming tick.
                let probeInterval = underwater ? 8 : 40
                routeRefreshDue = lastBreathingRouteProbeAge == nil
                    || urgentAir
                    || cachedBudgetReached
                    || age % probeInterval == 0
            }
            if routeRefreshDue {
                // A deep column must begin its ascent while it still has the
                // physical air budget to finish it.  The route is bounded and
                // validated, so measuring its actual length is both safer and
                // less guessy than a fixed low-air threshold.
                lastBreathingRouteProbeAge = age
                if let route = routeToBreathingSurface(radius: 8),
                   let airBudget = airBudgetForBreathingRoute(route) {
                    breathingRouteAirBudget = airBudget
                    let shouldSurface = action == .surface
                        || urgentAir
                        || cachedBudgetReached
                        || airSupply <= airBudget
                    if shouldSurface {
                        // Never start a route from less air than its measured
                        // conservative requirement. A stale/changed route can
                        // therefore fail closed to ordinary stranded behavior
                        // instead of pretending an impossible ascent is safe.
                        if airSupply < airBudget {
                            breathingRouteAirBudget = nil
                            setAction(.stranded, ticks: 40)
                            swimRoute.removeAll(keepingCapacity: true)
                            movementTarget = nearestWaterTarget(radius: 8)
                        } else {
                            swimRoute = route
                            movementTarget = swimRoute.first
                            if action != .surface {
                                setAction(.surface, ticks: min(1_200, max(160, airBudget + 64)))
                            }
                        }
                    }
                } else {
                    breathingRouteAirBudget = nil
                    if urgentAir || action == .surface || cachedBudgetReached {
                        // A sealed/drained basin, or a route that cannot be
                        // completed before the ordinary air reserve runs out,
                        // has no legal breathing point. Never teleport through
                        // terrain or grant aquatic creatures gills here.
                        setAction(.stranded, ticks: 40)
                        swimRoute.removeAll(keepingCapacity: true)
                        movementTarget = nearestWaterTarget(radius: 8)
                    }
                }
            } else if let prey = nearestAquaticPrey(), action != .eat, action != .dive {
                swimRoute.removeAll(keepingCapacity: true)
                let reach = width / 2 + prey.width / 2 + 0.65
                if distanceToSq(prey) <= reach * reach && abs(prey.y - y) < max(1.5, height) {
                    prey.hurt(max(1, attackDamage), "prehistoric_bite", self)
                    setAction(.eat, ticks: 36)
                    movementTarget = nil
                    playSound(.attack, volume: 0.82, pitch: 0.84)
                } else {
                    movementTarget = (prey.x, prey.y, prey.z)
                    setAction(.burst, ticks: 28)
                }
            } else if movementTarget == nil || age % 70 == 0 || !targetIsWater() {
                swimRoute.removeAll(keepingCapacity: true)
                movementTarget = makeSwimTarget(preferDepth: action == .dive)
                if action == .idle { setAction(.turn, ticks: 12) }
            }
        }
        guard let target = movementTarget else {
            data.prehistoricAirSupply = max(0, min(300, airSupply))
            return
        }
        let dx = target.x - x, dy = target.y - y, dz = target.z - z
        let distance = max(0.001, (dx * dx + dy * dy + dz * dz).squareRoot())
        let bursting = action == .burst
        let surfacing = action == .surface && target.y > y
        let impulse = bursting ? 0.034 : 0.019
        vx += dx / distance * impulse
        vy += dy / distance * (surfacing ? 0.060 : impulse)
        vz += dz / distance * impulse
        let maxSpeed = bursting ? 0.28 : 0.17
        let horizontal = (vx * vx + vz * vz).squareRoot()
        if horizontal > maxSpeed {
            vx *= maxSpeed / horizontal
            vz *= maxSpeed / horizontal
        }
        vy = clampD(vy, -0.14, surfacing ? 0.38 : 0.14)
        // The legal breathing waypoint deliberately keeps the body's lower
        // voxel in water while its eye reaches air. Do not let the faster
        // emergency lift overshoot that waypoint: an overshoot would mark
        // the animal dry and turn a valid breath into a stranded fallback.
        if surfacing, vy > 0, y + vy > target.y {
            vy = target.y - y
        }
        move(vx, vy, vz)
        vx *= 0.87; vy *= 0.87; vz *= 0.87
        if vx * vx + vz * vz > 0.0004 {
            yaw += clampD(wrapAngle(detAtan2(-vx, vz) - yaw), -0.28, 0.28)
        }
        if action == .surface {
            advanceSwimRoute()
        } else if distance < 1.2 || !targetIsWater() {
            movementTarget = makeSwimTarget(preferDepth: action == .dive)
        }
        if action == .idle {
            if definition.isPredatory && age % 130 == 0 && rng.nextFloat() < 0.35 {
                setAction(.burst, ticks: 28)
            } else { setAction(.cruise, ticks: 50) }
        }
        data.swimTarget = [target.x, target.y, target.z]
        data.prehistoricAirSupply = max(0, min(300, airSupply))
        tickManualLimbAnimation()
        tickLocomotionSound()
        tickManualAmbient()
    }

    private func makeSwimTarget(preferDepth: Bool = false) -> (x: Double, y: Double, z: Double)? {
        for _ in 0..<10 {
            let tx = ifloor(x) + rng.nextInt(15) - 7
            let ty = ifloor(y) + rng.nextInt(7) - 3
            let tz = ifloor(z) + rng.nextInt(15) - 7
            let targetY = Double(ty) + 0.5
            guard isWater(tx, ty, tz),
                  hasAquaticClearance(atX: tx, y: targetY, z: tz, allowsBreathingAir: false)
            else { continue }
            if preferDepth, let top = waterSurfaceY(tx, ty, tz), ty >= top - 1 { continue }
            return (Double(tx) + 0.5, targetY, Double(tz) + 0.5)
        }
        return nearestWaterTarget(radius: 6)
    }

    private func targetIsWater() -> Bool {
        guard let target = movementTarget else { return false }
        return isWater(ifloor(target.x), ifloor(target.y), ifloor(target.z))
    }

    private func nearestWaterTarget(radius: Int) -> (x: Double, y: Double, z: Double)? {
        let cx = ifloor(x), cy = ifloor(y), cz = ifloor(z)
        for distance in 0...max(0, min(12, radius)) {
            for dz in -distance...distance {
                for dx in -distance...distance where abs(dx) == distance || abs(dz) == distance {
                    for dy in -2...2 {
                        let tx = cx + dx, ty = cy + dy, tz = cz + dz
                        let targetY = Double(ty) + 0.5
                        if isWater(tx, ty, tz),
                           hasAquaticClearance(atX: tx, y: targetY, z: tz, allowsBreathingAir: false) {
                            return (Double(tx) + 0.5, targetY, Double(tz) + 0.5)
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Finds a body-safe route through *connected* loaded water to a genuine
    /// open-air surface. A nearby puddle or a surface beyond a solid wall is
    /// therefore not considered a breath target. Exploration order and cap
    /// are fixed, so this cannot introduce path-order RNG or unbounded work.
    private func routeToBreathingSurface(radius: Int) -> [(x: Double, y: Double, z: Double)]? {
        let start = (x: ifloor(x), y: ifloor(y), z: ifloor(z))
        let horizontalLimit = max(0, min(12, radius))
        let verticalLimit = min(64, max(8, world.info.height - 2))
        guard world.isLoadedAt(start.x, start.z),
              hasAquaticClearance(atX: start.x, y: Double(start.y) + 0.5,
                                  z: start.z, allowsBreathingAir: !underwater)
        else { return nil }

        // Fast path for a deep, open column. It proves every intermediate
        // body volume rather than treating the top as teleport-reachable, and
        // keeps a vertical ocean from spending the lateral BFS budget first.
        if let direct = directVerticalBreathingRoute(from: start, limit: verticalLimit) {
            return direct
        }

        var nodes = [PrehistoricWaterRouteNode(x: start.x, y: start.y, z: start.z, parent: -1)]
        var cursor = 0
        // Up first ensures a deep, vertical ocean column reaches a nearby
        // surface before consuming the bounded lateral search budget.
        let steps = [(0, 1, 0), (1, 0, 0), (0, 0, 1), (-1, 0, 0), (0, 0, -1), (0, -1, 0)]
        while cursor < nodes.count, nodes.count <= 256 {
            let node = nodes[cursor]
            if let surface = breathingSurfaceTarget(atX: node.x, aroundY: node.y, z: node.z),
               abs((Double(node.y) + 0.5) - surface.y) <= 1.1 {
                return routeThroughWaterNodes(nodes, endingAt: cursor, surface: surface)
            }
            cursor += 1
            guard nodes.count < 256 else { continue }
            for (dx, dy, dz) in steps {
                let nx = node.x + dx, ny = node.y + dy, nz = node.z + dz
                guard abs(nx - start.x) <= horizontalLimit,
                      abs(nz - start.z) <= horizontalLimit,
                      abs(ny - start.y) <= verticalLimit,
                      ny >= world.info.minY,
                      ny < world.info.minY + world.info.height,
                      world.isLoadedAt(nx, nz),
                      isWater(nx, ny, nz),
                      !nodes.contains(where: { $0.x == nx && $0.y == ny && $0.z == nz })
                else { continue }

                // A terminal breathing pose is deliberately not a water-only
                // node: its lower body remains in water while its head reaches
                // air. Check it before applying the intermediate-node rule so
                // a connected lateral tunnel can legitimately exit at an open
                // surface rather than being rejected for having breathable air.
                if let surface = breathingSurfaceTarget(atX: nx, aroundY: ny, z: nz),
                   abs((Double(ny) + 0.5) - surface.y) <= 1.1 {
                    return routeThroughWaterNodes(nodes, endingAt: cursor - 1, surface: surface)
                }

                guard hasAquaticClearance(atX: nx, y: Double(ny) + 0.5,
                                           z: nz, allowsBreathingAir: false)
                else { continue }
                nodes.append(PrehistoricWaterRouteNode(x: nx, y: ny, z: nz, parent: cursor - 1))
                if nodes.count >= 256 { break }
            }
        }
        return nil
    }

    /// Reconstructs a deterministic water-node prefix and appends its distinct
    /// air-breathing endpoint. The terminal pose is intentionally not stored
    /// as a water node because its valid envelope includes breathable air.
    private func routeThroughWaterNodes(
        _ nodes: [PrehistoricWaterRouteNode],
        endingAt endIndex: Int,
        surface: (x: Double, y: Double, z: Double)
    ) -> [(x: Double, y: Double, z: Double)] {
        var reversed: [(x: Double, y: Double, z: Double)] = []
        var index = endIndex
        while nodes[index].parent >= 0 {
            let point = nodes[index]
            reversed.append((Double(point.x) + 0.5, Double(point.y) + 0.5,
                             Double(point.z) + 0.5))
            index = nodes[index].parent
        }
        reversed.reverse()
        if reversed.last.map({
            abs($0.x - surface.x) < 0.001 && abs($0.y - surface.y) < 0.001 && abs($0.z - surface.z) < 0.001
        }) != true {
            reversed.append(surface)
        }
        return reversed
    }

    /// Conservative air requirement for a route traversed with the bounded
    /// surfacing lift below.  The reserve is still ordinary `LivingEntity`
    /// air: this only decides when to start moving, never replenishes it in
    /// water.  Routes beyond one full reserve are intentionally rejected.
    private func airBudgetForBreathingRoute(
        _ route: [(x: Double, y: Double, z: Double)]
    ) -> Int? {
        var previous = (x: x, y: y, z: z)
        var distance = 0.0
        for waypoint in route {
            let dx = waypoint.x - previous.x
            let dy = waypoint.y - previous.y
            let dz = waypoint.z - previous.z
            distance += (dx * dx + dy * dy + dz * dz).squareRoot()
            previous = waypoint
        }
        // The measured 0.25 blocks/tick is deliberately below the surface
        // controller's bounded steady ascent, leaving a 32-tick margin for
        // acceleration, waypoint turns, and the final exposed breath.
        let required = Int((distance / 0.25).rounded(.up)) + 32
        return required <= 300 ? required : nil
    }

    private func directVerticalBreathingRoute(
        from start: (x: Int, y: Int, z: Int),
        limit: Int
    ) -> [(x: Double, y: Double, z: Double)]? {
        guard let surface = breathingSurfaceTarget(atX: start.x, aroundY: start.y, z: start.z) else {
            return nil
        }
        let finalY = ifloor(surface.y)
        guard finalY >= start.y, finalY - start.y <= limit else { return nil }
        var route: [(x: Double, y: Double, z: Double)] = []
        if finalY > start.y {
            for yy in (start.y + 1)...finalY {
                let allowsAir = yy == finalY
                guard hasAquaticClearance(atX: start.x, y: Double(yy) + 0.5,
                                          z: start.z, allowsBreathingAir: allowsAir)
                else { return nil }
                route.append((Double(start.x) + 0.5, Double(yy) + 0.5,
                              Double(start.z) + 0.5))
            }
        }
        if route.last.map({
            abs($0.x - surface.x) < 0.001 && abs($0.y - surface.y) < 0.001 && abs($0.z - surface.z) < 0.001
        }) != true {
            route.append(surface)
        }
        return route
    }

    private func advanceSwimRoute() {
        guard !swimRoute.isEmpty else { return }
        while swimRoute.count > 1 {
            let waypoint = swimRoute[0]
            let dx = waypoint.x - x, dy = waypoint.y - y, dz = waypoint.z - z
            if dx * dx + dy * dy + dz * dz >= 0.75 * 0.75 { break }
            swimRoute.removeFirst()
        }
        movementTarget = swimRoute.first
    }

    private func breathingSurfaceTarget(atX x: Int, aroundY y: Int, z: Int) -> (x: Double, y: Double, z: Double)? {
        guard let top = waterSurfaceY(x, y, z) else { return nil }
        let airY = top + 1
        guard isBreathableAir(x, airY, z) else { return nil }
        let bodyY = Double(airY) - height * 0.85 + 0.02
        guard hasAquaticClearance(atX: x, y: bodyY, z: z, allowsBreathingAir: true) else { return nil }
        return (Double(x) + 0.5, bodyY, Double(z) + 0.5)
    }

    private func waterSurfaceY(_ x: Int, _ y: Int, _ z: Int) -> Int? {
        // A column is at most the fixed world height (384), so this contiguous
        // vertical scan is bounded. Horizontal connectivity is established by
        // `routeToBreathingSurface`, not assumed from this column alone.
        let lower = max(world.info.minY + 1, min(world.info.minY + world.info.height - 2, y))
        guard isWater(x, lower, z) else { return nil }
        var top = lower
        let upper = world.info.minY + world.info.height - 2
        if lower < upper {
            for yy in (lower + 1)...upper {
                if isWater(x, yy, z) { top = yy }
                else { break }
            }
        }
        return top
    }

    private func isWater(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        guard world.isLoadedAt(x, z) else { return false }
        let cell = world.getBlock(x, y, z)
        return (cell >> 4) == Int(B.water) || (cell >= 0 && isWaterlogged(UInt16(cell)))
    }

    private func isBreathableAir(_ x: Int, _ y: Int, _ z: Int) -> Bool {
        let cell = world.getBlock(x, y, z)
        let block = cell >> 4
        guard block >= 0, block < blockDefs.count, !isWater(x, y, z) else { return false }
        return block == 0 || blockDefs[block].replaceable
    }

    private func hasAquaticClearance(atX x: Int, y: Double, z: Int, allowsBreathingAir: Bool) -> Bool {
        let radius = definition.bodyClearanceRadius
        let lower = ifloor(y)
        let upper = max(lower, ifloor(y + Double(definition.bodyClearanceHeight) - 0.000_001))
        var hasWater = false
        for zz in (z - radius)...(z + radius) {
            for xx in (x - radius)...(x + radius) {
                guard world.isLoadedAt(xx, zz) else { return false }
                guard isWater(xx, lower, zz) else { return false }
                for yy in lower...upper {
                    if isWater(xx, yy, zz) {
                        hasWater = true
                    } else if !allowsBreathingAir || !isBreathableAir(xx, yy, zz) {
                        return false
                    }
                }
            }
        }
        return hasWater
    }

    private func nearestAquaticPrey() -> LivingEntity? {
        guard definition.isPredatory else { return nil }
        let candidates = world.getEntitiesNear(x, y, z, 14) { entity in
            guard let living = entity as? LivingEntity, !living.dead else { return false }
            if living.type == "cod" || living.type == "salmon" || living.type == "tropical_fish" { return true }
            guard let other = PrehistoricCreatureDefinition.named(living.type),
                  other.medium == .aquatic,
                  other.id != self.definition.id
            else { return false }
            return other.authoringLengthMetres < self.definition.authoringLengthMetres * 0.70
        }
        var best: LivingEntity?
        var bestDistance = Double.infinity
        for candidate in candidates {
            guard let living = candidate as? LivingEntity else { continue }
            let distance = distanceToSq(living)
            if distance < bestDistance || (distance == bestDistance && living.id < (best?.id ?? Int.max)) {
                best = living
                bestDistance = distance
            }
        }
        return best
    }

    private func tickManualLimbAnimation() {
        let dx = x - prevX, dz = z - prevZ
        let moved = min(1, (dx * dx + dz * dz).squareRoot() * 4)
        limbAmp += (moved - limbAmp) * 0.4
        limbSwing += limbAmp * 1.2
    }

    private func tickManualAmbient() {
        ambientSoundTimer -= 1
        if ambientSoundTimer <= 0 {
            ambientSoundTimer = 90 + rng.nextInt(180)
            playSound(.ambient, volume: 1, pitch: 0.92 + rng.nextFloat() * 0.12)
        }
    }

    /// Movement sounds are cosmetic and derive their cadence from already
    /// simulated position/age. They must not advance the controller RNG.
    private func tickLocomotionSound() {
        let dx = x - prevX
        let dy = y - prevY
        let dz = z - prevZ

        let cue: PrehistoricSoundCue
        let cadence: Int
        switch definition.medium {
        case .land:
            guard onGround else { return }
            guard dx * dx + dz * dz > 0.0016 else { return }
            cue = .step
            cadence = 9 + definition.soundProfile.cadenceOffset
        case .air:
            guard action == .takeoff || action == .flap else { return }
            guard dx * dx + dy * dy + dz * dz > 0.0016 else { return }
            cue = .wingbeat
            cadence = 7 + definition.soundProfile.cadenceOffset
        case .aquatic:
            guard inWater else { return }
            guard dx * dx + dy * dy + dz * dz > 0.0016 else { return }
            cue = .swim
            cadence = 8 + definition.soundProfile.cadenceOffset
        }

        let phase = (abs(id) + definition.soundProfile.cadenceOffset) % cadence
        guard age % cadence == phase else { return }
        let volume = min(1.05, max(0.42, definition.collisionWidth / 1.6))
        playSound(cue, volume: volume,
                  pitch: 0.88 + Double(definition.soundProfile.timbreIndex) * 0.04)
    }

    public override func drops() -> [DropEntry] {
        switch definition.medium {
        case .land:
            return [DropEntry("bone", min: 1, max: definition.isPredatory ? 3 : 2)]
        case .air:
            return [DropEntry("feather", min: 1, max: 2)]
        case .aquatic:
            return [DropEntry("bone", min: 0, max: 2), DropEntry("cod", min: 0, max: 1)]
        }
    }
}

/// Conservative spawn/path clearance for a large native creature. It checks
/// every occupied body column and is bounded by the roster's capped collision
/// dimensions; it never changes ordinary mob behavior.
public func prehistoricHasClearance(
    _ world: World,
    definition: PrehistoricCreatureDefinition,
    x: Int,
    y: Int,
    z: Int,
    requireGround: Bool
) -> Bool {
    let radius = definition.bodyClearanceRadius
    let supportRadius = definition.groundSupportRadius
    let vertical = definition.bodyClearanceHeight
    for zz in (z - radius)...(z + radius) {
        for xx in (x - radius)...(x + radius) {
            guard world.isLoadedAt(xx, zz) else { return false }
            if requireGround,
               abs(xx - x) <= supportRadius,
               abs(zz - z) <= supportRadius {
                let below = world.getBlock(xx, y - 1, zz) >> 4
                guard below > 0, below < blockDefs.count, blockDefs[below].solid else { return false }
            }
            for yy in y..<(y + vertical) {
                let cell = world.getBlock(xx, yy, zz)
                let block = cell >> 4
                if definition.medium == .aquatic {
                    if block != Int(B.water) && !(cell >= 0 && isWaterlogged(UInt16(cell))) { return false }
                } else if block == Int(B.water) || block == Int(B.lava)
                    || block < 0 || (block != 0 && (block >= blockDefs.count || !blockDefs[block].replaceable)) {
                    return false
                } else if cell >= 0, cell <= Int(UInt16.max), isWaterlogged(UInt16(cell)) {
                    // Seagrass is replaceable but still water: a land or air
                    // body never stands in water-filled flora.
                    return false
                }
            }
        }
    }
    return true
}

/// Admission check for an air-breathing prehistoric swimmer spawned by the
/// natural-population loop. Whole-body clearance alone would accept a sealed
/// trough or a one-body puddle; this additionally requires a bounded,
/// connected body-safe water region that reaches a genuine breathable surface
/// and extends horizontally beyond the creature's immediate footprint.
///
/// The fixed node cap and ordered neighbor walk preserve deterministic,
/// bounded work. This is intentionally only for the prehistoric aquatic
/// roster: ordinary fish retain their historical water-spawn behavior.
public func prehistoricAquaticNaturalSpawnHasOpenWaterAdmission(
    _ world: World,
    definition: PrehistoricCreatureDefinition,
    x: Int,
    y: Int,
    z: Int
) -> Bool {
    guard definition.medium == .aquatic,
          prehistoricHasClearance(world, definition: definition, x: x, y: y, z: z,
                                  requireGround: false),
          world.isLoadedAt(x, z)
    else { return false }

    let horizontalLimit = 12
    let verticalLimit = min(64, max(8, world.info.height - 2))
    let requiredHorizontalReach = min(
        horizontalLimit, max(4, definition.bodyClearanceRadius + 3)
    )
    var nodes = [PrehistoricOpenWaterAdmissionNode(x: x, y: y, z: z)]
    var cursor = 0
    var foundBreathingSurface = false
    // Up first makes deep water cheap to admit while the later cardinal walk
    // still proves this is an open body of water rather than a vertical pipe.
    let steps = [(0, 1, 0), (1, 0, 0), (0, 0, 1), (-1, 0, 0), (0, 0, -1), (0, -1, 0)]

    while cursor < nodes.count, nodes.count <= 256 {
        let node = nodes[cursor]
        cursor += 1
        if prehistoricAquaticBreathingSurfaceIsClear(
            world, definition: definition, x: node.x, y: node.y, z: node.z
        ) {
            foundBreathingSurface = true
        }
        let horizontalReach = max(abs(node.x - x), abs(node.z - z))
        if foundBreathingSurface, horizontalReach >= requiredHorizontalReach {
            return true
        }

        guard nodes.count < 256 else { continue }
        for (dx, dy, dz) in steps {
            let nx = node.x + dx, ny = node.y + dy, nz = node.z + dz
            guard abs(nx - x) <= horizontalLimit,
                  abs(nz - z) <= horizontalLimit,
                  abs(ny - y) <= verticalLimit,
                  ny >= world.info.minY,
                  ny < world.info.minY + world.info.height,
                  prehistoricWaterCell(world, x: nx, y: ny, z: nz),
                  !nodes.contains(where: { $0.x == nx && $0.y == ny && $0.z == nz })
            else { continue }

            // Just as the controller does, admit a body-in-water/head-in-air
            // endpoint before testing the water-only envelope required of
            // intermediate BFS nodes. That keeps natural spawning and runtime
            // route validation on the same physical definition of open water.
            if prehistoricAquaticBreathingSurfaceIsClear(
                world, definition: definition, x: nx, y: ny, z: nz
            ) {
                let horizontalReach = max(abs(nx - x), abs(nz - z))
                if horizontalReach >= requiredHorizontalReach { return true }
                foundBreathingSurface = true
            }

            guard prehistoricAquaticEnvelopeIsClear(
                      world, definition: definition, x: nx, y: Double(ny) + 0.5, z: nz,
                      allowsBreathingAir: false
                  )
            else { continue }
            nodes.append(PrehistoricOpenWaterAdmissionNode(x: nx, y: ny, z: nz))
            if nodes.count >= 256 { break }
        }
    }
    return false
}

private struct PrehistoricOpenWaterAdmissionNode {
    let x: Int
    let y: Int
    let z: Int
}

private func prehistoricWaterCell(_ world: World, x: Int, y: Int, z: Int) -> Bool {
    guard y >= world.info.minY,
          y < world.info.minY + world.info.height,
          world.isLoadedAt(x, z)
    else { return false }
    let cell = world.getBlock(x, y, z)
    return (cell >> 4) == Int(B.water) || (cell >= 0 && isWaterlogged(UInt16(cell)))
}

private func prehistoricBreathableAirCell(_ world: World, x: Int, y: Int, z: Int) -> Bool {
    guard y >= world.info.minY,
          y < world.info.minY + world.info.height,
          world.isLoadedAt(x, z),
          !prehistoricWaterCell(world, x: x, y: y, z: z)
    else { return false }
    let block = world.getBlock(x, y, z) >> 4
    return block == 0 || (block >= 0 && block < blockDefs.count && blockDefs[block].replaceable)
}

private func prehistoricAquaticEnvelopeIsClear(
    _ world: World,
    definition: PrehistoricCreatureDefinition,
    x: Int,
    y: Double,
    z: Int,
    allowsBreathingAir: Bool
) -> Bool {
    let lower = ifloor(y)
    let upper = max(lower, ifloor(y + Double(definition.bodyClearanceHeight) - 0.000_001))
    var hasWater = false
    for zz in (z - definition.bodyClearanceRadius)...(z + definition.bodyClearanceRadius) {
        for xx in (x - definition.bodyClearanceRadius)...(x + definition.bodyClearanceRadius) {
            guard prehistoricWaterCell(world, x: xx, y: lower, z: zz) else { return false }
            for yy in lower...upper {
                if prehistoricWaterCell(world, x: xx, y: yy, z: zz) {
                    hasWater = true
                } else if !allowsBreathingAir || !prehistoricBreathableAirCell(world, x: xx, y: yy, z: zz) {
                    return false
                }
            }
        }
    }
    return hasWater
}

private func prehistoricAquaticBreathingSurfaceIsClear(
    _ world: World,
    definition: PrehistoricCreatureDefinition,
    x: Int,
    y: Int,
    z: Int
) -> Bool {
    guard prehistoricWaterCell(world, x: x, y: y, z: z) else { return false }
    let upper = world.info.minY + world.info.height - 2
    var top = y
    if top < upper {
        for candidate in (top + 1)...upper {
            if prehistoricWaterCell(world, x: x, y: candidate, z: z) {
                top = candidate
            } else {
                break
            }
        }
    }
    let airY = top + 1
    guard prehistoricBreathableAirCell(world, x: x, y: airY, z: z) else { return false }
    let bodyY = Double(airY) - definition.collisionHeight * 0.85 + 0.02
    return prehistoricAquaticEnvelopeIsClear(
        world, definition: definition, x: x, y: bodyY, z: z, allowsBreathingAir: true
    )
}
