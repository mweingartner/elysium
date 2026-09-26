// AI companion creature spawning: prehistoric species names, named creature
// groups, and the bounded "populate my area" placement. Model output only names
// what to spawn. How many, which species of a group, and where are chosen by the
// engine with the world's deterministic RNG, then admitted cell by cell through
// the shared spawn-placement rule. Every count, radius and attempt is capped.

import Foundation

/// Largest horizontal radius around the player an area spawn may use.
public let AIAgentMaxAreaSpawnRadius = 32
/// Most groups or species one area request may name.
public let AIAgentAreaSpawnMaxItems = 4
/// Most creatures one named group or species contributes.
public let AIAgentAreaSpawnMaxPerItem = 8
/// Candidate sites tried per pack before it is reported as unplaced.
let AIAgentAreaSpawnSiteAttempts = 24
/// Boss-tier mobs are summoned only where the player deliberately aims (the
/// cursor), never scattered around the player by an area request.
let AIAgentAreaSpawnExcludedEntities: Set<String> = ["wither", "ender_dragon", "warden", "elder_guardian"]

// MARK: - prehistoric species names

/// Nicknames players use for roster species, keyed by normalized name. Plain
/// species names ("triceratops", "prehistoric.triceratops") and "-saur" short
/// forms ("stegosaur") resolve without an entry.
let aiAgentPrehistoricAliases: [String: String] = [
    "t_rex": "prehistoric.tyrannosaurus", "trex": "prehistoric.tyrannosaurus",
    "rex": "prehistoric.tyrannosaurus", "tyrannosaurus_rex": "prehistoric.tyrannosaurus",
    "raptor": "prehistoric.velociraptor", "velociraptors": "prehistoric.velociraptor",
    "brontosaurus": "prehistoric.diplodocus", "apatosaurus": "prehistoric.diplodocus",
    "bronto": "prehistoric.diplodocus",
    "pterodactyl": "prehistoric.pteranodon", "pterodactylus": "prehistoric.pteranodon",
    "trike": "prehistoric.triceratops", "stego": "prehistoric.stegosaurus",
    "anky": "prehistoric.ankylosaurus", "spino": "prehistoric.spinosaurus",
    "brachio": "prehistoric.brachiosaurus", "allo": "prehistoric.allosaurus",
    "dilo": "prehistoric.dilophosaurus", "compy": "prehistoric.compsognathus",
    "pachy": "prehistoric.pachycephalosaurus", "parasaur": "prehistoric.parasaurolophus",
    "carno": "prehistoric.carnotaurus", "styraco": "prehistoric.styracosaurus",
    "therizino": "prehistoric.therizinosaurus", "quetzal": "prehistoric.quetzalcoatlus",
    "mosa": "prehistoric.mosasaurus", "plesio": "prehistoric.plesiosaurus",
    "elasmo": "prehistoric.elasmosaurus",
]

/// The species part of a roster id ("tyrannosaurus" for "prehistoric.tyrannosaurus").
func aiAgentPrehistoricShortName(_ definition: PrehistoricCreatureDefinition) -> String {
    String(definition.id.dropFirst("prehistoric.".count))
}

/// Resolves one normalized candidate ("t_rex", "raptors", "prehistoric_triceratops",
/// "stegosaurs") to a roster species, or nil.
func resolveAIAgentPrehistoricSpecies(_ candidate: String) -> PrehistoricCreatureDefinition? {
    var name = candidate
    if name.hasPrefix("prehistoric_") { name.removeFirst("prehistoric_".count) }
    guard !name.isEmpty else { return nil }
    var forms = [name]
    if name.hasSuffix("es") { forms.append(String(name.dropLast(2))) }
    if name.hasSuffix("s") { forms.append(String(name.dropLast())) }
    forms += forms.filter { $0.hasSuffix("saur") }.map { $0 + "us" }
    for form in forms {
        if let id = aiAgentPrehistoricAliases[form], let definition = PrehistoricCreatureDefinition.named(id) {
            return definition
        }
        if let definition = PrehistoricCreatureDefinition.all.first(where: {
            aiAgentPrehistoricShortName($0) == form || normalizeAIAgentName($0.displayName) == form
        }) {
            return definition
        }
    }
    return nil
}

/// A readable name for a spawnable entity id in chat.
func aiAgentCreatureDisplayName(_ entityID: String) -> String {
    PrehistoricCreatureDefinition.named(entityID)?.displayName ?? entityID.replacingOccurrences(of: "_", with: " ")
}

// MARK: - creature groups

/// A named group of prehistoric creatures the companion can populate an area with.
public enum AIAgentCreatureGroup: String, CaseIterable, Sendable {
    case predators
    case herbivores
    case dinosaurs
    case flyers
    case marineReptiles = "marine_reptiles"

    private static let aliases: [String: AIAgentCreatureGroup] = [
        "predator": .predators, "predators": .predators, "carnivore": .predators, "carnivores": .predators,
        "meat_eater": .predators, "meat_eaters": .predators, "hunter": .predators, "hunters": .predators,
        "theropod": .predators, "theropods": .predators,
        "predatory_dinosaurs": .predators, "predator_dinosaurs": .predators, "carnivorous_dinosaurs": .predators,
        "meat_eating_dinosaurs": .predators,
        "herbivore": .herbivores, "herbivores": .herbivores, "plant_eater": .herbivores, "plant_eaters": .herbivores,
        "grazer": .herbivores, "grazers": .herbivores, "herd": .herbivores, "herds": .herbivores,
        "prey": .herbivores, "herbivorous_dinosaurs": .herbivores, "herbivore_dinosaurs": .herbivores,
        "plant_eating_dinosaurs": .herbivores,
        "dinosaur": .dinosaurs, "dinosaurs": .dinosaurs, "dino": .dinosaurs, "dinos": .dinosaurs,
        "prehistoric_creatures": .dinosaurs, "prehistoric_animals": .dinosaurs,
        "pterosaur": .flyers, "pterosaurs": .flyers, "flyer": .flyers, "flyers": .flyers,
        "flying_reptiles": .flyers, "flying_dinosaurs": .flyers,
        "marine_reptile": .marineReptiles, "marine_reptiles": .marineReptiles, "sea_monster": .marineReptiles,
        "sea_monsters": .marineReptiles, "sea_reptiles": .marineReptiles, "aquatic_dinosaurs": .marineReptiles,
        "sea_dinosaurs": .marineReptiles, "water_dinosaurs": .marineReptiles,
    ]

    /// The group a normalized phrase names ("predators", "plant_eaters"), or nil.
    public static func named(_ phrase: String) -> AIAgentCreatureGroup? {
        let name = normalizeAIAgentName(phrase)
        return aliases[name]
    }

    public var displayName: String {
        switch self {
        case .predators: return "predators"
        case .herbivores: return "herbivores"
        case .dinosaurs: return "dinosaurs"
        case .flyers: return "pterosaurs"
        case .marineReptiles: return "marine reptiles"
        }
    }

    /// How many the engine picks when a request does not give a number.
    var randomCount: ClosedRange<Int> {
        switch self {
        case .predators: return 1...3
        case .herbivores: return 3...6
        case .dinosaurs: return 3...6
        case .flyers: return 2...4
        case .marineReptiles: return 1...3
        }
    }

    func contains(_ definition: PrehistoricCreatureDefinition) -> Bool {
        switch self {
        case .predators: return definition.isLandPredator
        case .herbivores: return definition.isLandHerdHerbivore
        case .dinosaurs: return definition.isLandPredator || definition.isLandHerdHerbivore
        case .flyers: return definition.medium == .air
        case .marineReptiles: return definition.medium == .aquatic
        }
    }

    /// Species this group spawns in `world`, in roster order: the world's own
    /// prehistoric roster when it has members of the group, else the whole roster.
    func pool(for world: World) -> [PrehistoricCreatureDefinition] {
        let all = PrehistoricCreatureDefinition.all.filter(contains)
        guard let profile = world.generationSettings.preset.prehistoricProfile else { return all }
        let local = all.filter { profile.creatureIDs.contains($0.id) }
        return local.isEmpty ? all : local
    }
}

// MARK: - request parsing

/// One named thing to spawn and, when the request gave one, how many.
public struct AIAgentSpawnRequest: Equatable, Sendable {
    public enum Subject: Equatable, Sendable {
        case group(AIAgentCreatureGroup)
        case entity(String)
    }
    public let subject: Subject
    public let count: Int?
}

private let aiAgentSpawnSeparatorWords: Set<String> = ["and", "plus", "with", "also", "then"]
/// Quantity words that mean "the engine picks how many".
private let aiAgentVagueQuantityWords: Set<String> = [
    "some", "few", "several", "bunch", "lots", "lot", "many", "random", "number", "amount",
    "group", "herd", "pack", "flock", "school", "pod", "handful", "more", "extra", "various",
]
/// Filler words that never name a creature.
private let aiAgentSpawnFillerWords: Set<String> = ["a", "an", "the", "of", "any", "kind", "kinds", "type", "types"]
private let aiAgentExactQuantityWords: [String: Int] = ["couple": 2, "pair": 2, "dozen": 12]

/// Splits a request such as "some predators and herbivores" or "2 raptors, a t-rex"
/// into named groups or species with optional counts. Every name must resolve.
public func parseAIAgentSpawnList(_ raw: String) throws -> [AIAgentSpawnRequest] {
    var separated = raw
    for mark in [",", ";", "&", "+", "/"] { separated = separated.replacingOccurrences(of: mark, with: " and ") }
    let tokens = normalizeAIAgentRequestText(separated).split(separator: " ").map(String.init)
    var segments: [[String]] = [[]]
    func hasName(_ segment: [String]) -> Bool {
        segment.contains { word in
            !aiAgentVagueQuantityWords.contains(word) && !aiAgentSpawnFillerWords.contains(word)
                && aiAgentExactQuantityWords[word] == nil && spelledAIAgentNumber(word) == nil && Int(word) == nil
        }
    }
    for token in tokens {
        if aiAgentSpawnSeparatorWords.contains(token) {
            if !(segments.last ?? []).isEmpty { segments.append([]) }
            continue
        }
        let isQuantity = Int(token) != nil || (spelledAIAgentNumber(token) != nil && token != "a" && token != "an")
        if isQuantity, hasName(segments[segments.count - 1]) { segments.append([]) }
        segments[segments.count - 1].append(token)
    }
    segments = segments.filter { !$0.isEmpty }
    guard !segments.isEmpty else { throw AIAgentError.missingEntity }
    guard segments.count <= AIAgentAreaSpawnMaxItems else {
        throw AIAgentError.tooManySpawnGroups(segments.count)
    }
    return try segments.map { segment in
        var count: Int?
        var vague = false
        var sawArticle = false
        var nameWords: [String] = []
        for word in segment {
            if let number = Int(word) { count = number; continue }
            if let exact = aiAgentExactQuantityWords[word] { count = exact; continue }
            if word == "a" || word == "an" { sawArticle = true; continue }
            if let spelled = spelledAIAgentNumber(word) { count = spelled; continue }
            if aiAgentVagueQuantityWords.contains(word) { vague = true; continue }
            if aiAgentSpawnFillerWords.contains(word) { continue }
            nameWords.append(word)
        }
        if count == nil, sawArticle, !vague { count = 1 }
        if vague, count == 1 { count = nil }
        let phrase = nameWords.joined(separator: " ")
        if phrase.isEmpty {
            // A bare collective noun ("spawn a herd") names its group.
            let collectives: [(String, AIAgentCreatureGroup)] = [
                ("herd", .herbivores), ("pack", .predators), ("flock", .flyers), ("pod", .marineReptiles),
                ("school", .marineReptiles),
            ]
            if let group = collectives.first(where: { segment.contains($0.0) })?.1 {
                return AIAgentSpawnRequest(subject: .group(group), count: count)
            }
            throw AIAgentError.missingEntity
        }
        if let group = AIAgentCreatureGroup.named(phrase) {
            return AIAgentSpawnRequest(subject: .group(group), count: count)
        }
        guard let entity = resolveAIAgentEntityName(phrase) else { throw AIAgentError.unknownEntity(phrase) }
        guard !AIAgentAreaSpawnExcludedEntities.contains(entity) else { throw AIAgentError.areaSpawnNotAllowed(entity) }
        return AIAgentSpawnRequest(subject: .entity(entity), count: count)
    }
}

// MARK: - area placement

/// One placed pack for reporting.
private struct AIAgentSpawnTally {
    var label: String
    var group: AIAgentCreatureGroup?
    var bySpecies: [(name: String, count: Int)] = []
    var placed = 0
    var planned = 0

    mutating func record(_ entityID: String) {
        placed += 1
        let name = aiAgentCreatureDisplayName(entityID)
        if let index = bySpecies.firstIndex(where: { $0.name == name }) {
            bySpecies[index].count += 1
        } else {
            bySpecies.append((name, 1))
        }
    }

    var summary: String {
        guard let group else { return "\(placed) \(label)" }
        let species = bySpecies.map { $0.count > 1 ? "\($0.count) \($0.name)" : $0.name }.joined(separator: ", ")
        return "\(placed) \(group.displayName) (\(species))"
    }
}

/// The feet cell to put `entity` at in column (x, z), or nil when the column has none.
private func aiAgentAreaSpawnY(_ world: World, _ entity: String, _ x: Int, _ z: Int) -> Int? {
    let lowest = world.info.minY + 1, highest = world.info.minY + world.info.height - 2
    switch spawnPlacementMedium(forMob: entity) {
    case .water:
        // Start at the seabed and rise through the water column until the body fits.
        let floor = world.surfaceY(x, z)
        for y in floor..<(floor + 8) where y >= lowest && y <= highest {
            if spawnPlacementIsValid(world, entity, x, y, z) { return y }
        }
        return nil
    case .land, .amphibious, .object:
        guard let y = world.dryGroundY(x, z), y >= lowest, y <= highest,
              spawnPlacementIsValid(world, entity, x, y, z) else { return nil }
        return y
    }
}

/// Spawns one creature at a cell already admitted by `spawnPlacementIsValid`.
private func aiAgentSpawnAt(_ world: World, _ entity: String, _ x: Int, _ y: Int, _ z: Int, serial: Int) -> Entity? {
    let salt: UInt32? = PrehistoricCreatureDefinition.named(entity).map { _ in
        hash3(world.seed ^ hashString(entity), x, y, z,
              UInt32(truncatingIfNeeded: world.time) ^ UInt32(truncatingIfNeeded: serial))
    }
    return spawnMob(world, entity, Double(x) + 0.5, Double(y), Double(z) + 0.5,
                    SpawnOpts(persistent: true, prehistoricSeedSalt: salt))
}

/// Offsets for a pack around its anchor, nearest first, in a fixed order.
private let aiAgentPackOffsets: [(Int, Int)] = [
    (0, 0), (3, 0), (0, 3), (-3, 0), (0, -3), (3, 3), (-3, 3), (3, -3), (-3, -3),
    (6, 0), (0, 6), (-6, 0), (0, -6), (6, 3), (-6, 3), (6, -3), (-6, -3),
]

/// Populates the area around `player` with the named groups or species. Counts not
/// given are random within each group's range; species, sites and pack sizes come
/// from `world.rng`. Each creature is admitted by `spawnPlacementIsValid`.
public func executeAIAgentAreaSpawn(_ rawEntity: String, count requestedCount: Int?, radius requestedRadius: Int?,
                                    world: World, player: Player) throws -> AIAgentExecutionResult {
    let requests = try parseAIAgentSpawnList(rawEntity)
    let radius = Double(min(AIAgentMaxAreaSpawnRadius, max(12, requestedRadius ?? 28)))
    var remaining = AIAgentMaxSpawnCount
    var serial = 0
    var tallies: [AIAgentSpawnTally] = []

    for request in requests where remaining > 0 {
        let explicit = requests.count == 1 ? (request.count ?? requestedCount) : request.count
        var planned: Int
        var pool: [PrehistoricCreatureDefinition] = []
        var tally: AIAgentSpawnTally
        switch request.subject {
        case .group(let group):
            pool = group.pool(for: world)
            guard !pool.isEmpty else { throw AIAgentError.unknownEntity(group.rawValue) }
            planned = explicit ?? world.rng.nextIntBetween(group.randomCount.lowerBound, group.randomCount.upperBound)
            tally = AIAgentSpawnTally(label: group.displayName, group: group)
        case .entity(let entity):
            if let definition = PrehistoricCreatureDefinition.named(entity) {
                let low = max(1, min(4, definition.minPack)), high = max(low, min(4, definition.maxPack))
                planned = explicit ?? world.rng.nextIntBetween(low, high)
            } else {
                planned = explicit ?? world.rng.nextIntBetween(2, 4)
            }
            tally = AIAgentSpawnTally(label: aiAgentCreatureDisplayName(entity), group: nil)
        }
        planned = min(remaining, min(AIAgentAreaSpawnMaxPerItem, max(1, planned)))
        remaining -= planned
        tally.planned = planned

        var left = planned
        while left > 0 {
            // Choose this pack's species and size.
            let entity: String
            var packSize = left
            switch request.subject {
            case .group(let group):
                var candidates = pool
                if group == .dinosaurs {
                    // Herds outnumber hunters two to one, like the dawn refill.
                    let wantHerbivore = world.rng.nextInt(3) < 2
                    let side = pool.filter { wantHerbivore ? $0.isLandHerdHerbivore : $0.isLandPredator }
                    if !side.isEmpty { candidates = side }
                }
                let species = world.rng.pickWeighted(candidates) { $0.spawnWeight }
                entity = species.id
                let low = max(1, species.minPack), high = max(low, species.maxPack)
                packSize = min(left, world.rng.nextIntBetween(low, high))
            case .entity(let id):
                entity = id
            }
            let predator = PrehistoricCreatureDefinition.named(entity)?.isPredatory == true
            // Keep predators a little farther out than grazers.
            let minDistance = min(radius - 4, predator ? 14.0 : 8.0)
            var anchor: (x: Int, z: Int)?
            for _ in 0..<AIAgentAreaSpawnSiteAttempts {
                let distance = minDistance + world.rng.nextFloat() * (radius - minDistance)
                let angle = world.rng.nextFloat() * .pi * 2
                let x = ifloor(player.x + detCos(angle) * distance)
                let z = ifloor(player.z + detSin(angle) * distance)
                guard world.isLoadedAt(x, z), aiAgentAreaSpawnY(world, entity, x, z) != nil else { continue }
                anchor = (x, z)
                break
            }
            if let anchor {
                var placedInPack = 0
                for (dx, dz) in aiAgentPackOffsets where placedInPack < packSize {
                    let x = anchor.x + dx, z = anchor.z + dz
                    let ddx = Double(x) + 0.5 - player.x, ddz = Double(z) + 0.5 - player.z
                    guard ddx * ddx + ddz * ddz >= minDistance * minDistance * 0.5,
                          world.isLoadedAt(x, z), let y = aiAgentAreaSpawnY(world, entity, x, z) else { continue }
                    serial += 1
                    if aiAgentSpawnAt(world, entity, x, y, z, serial: serial) != nil {
                        tally.record(entity)
                        placedInPack += 1
                    }
                }
            }
            left -= packSize
        }
        tallies.append(tally)
    }

    let placed = tallies.reduce(0) { $0 + $1.placed }
    guard placed > 0 else {
        throw AIAgentError.areaSpawnFailed(tallies.map(\.label).joined(separator: ", "))
    }
    let planned = tallies.reduce(0) { $0 + $1.planned }
    var message = "Spawned " + tallies.filter { $0.placed > 0 }.map(\.summary).joined(separator: " and ") + " around you."
    if planned > placed {
        message += " \(planned - placed) found no safe spot nearby."
    }
    return AIAgentExecutionResult(message: message, changedWorld: true)
}

// MARK: - cursor placement for large creatures

/// Cells for `count` creatures at or near the cursor. Ordinary mobs keep the
/// exact cursor cell; a prehistoric creature whose body does not fit there uses
/// the nearest admitted cells within its body clearance plus four blocks (at most
/// ten), one creature per cell.
func aiAgentCursorSpawnCells(_ entity: String, count: Int, target: (x: Int, y: Int, z: Int),
                             world: World, admits: (Int, Int, Int) -> Bool) -> [(x: Int, y: Int, z: Int)] {
    guard let definition = PrehistoricCreatureDefinition.named(entity) else {
        return admits(target.x, target.y, target.z) ? Array(repeating: target, count: count) : []
    }
    let reach = min(10, 4 + definition.bodyClearanceRadius)
    var cells: [(x: Int, y: Int, z: Int)] = []
    for radius in 0...reach where cells.count < count {
        for dz in -radius...radius {
            for dx in -radius...radius where max(abs(dx), abs(dz)) == radius && cells.count < count {
                let x = target.x + dx, z = target.z + dz
                guard world.isLoadedAt(x, z) else { continue }
                var ys = [target.y]
                if let ground = world.dryGroundY(x, z), ground != target.y { ys.append(ground) }
                for y in ys where y > world.info.minY && y + 1 < world.info.minY + world.info.height {
                    if admits(x, y, z) { cells.append((x, y, z)); break }
                }
            }
        }
    }
    return cells
}
