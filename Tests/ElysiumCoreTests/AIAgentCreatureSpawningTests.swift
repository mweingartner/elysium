import XCTest
@testable import ElysiumCore

/// The AI companion's dinosaur names, creature groups and "populate my area" spawns.
final class AIAgentCreatureSpawningTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
        registerAllSystems()
    }

    /// A flat grass plain of `radius` chunks around the origin, optionally with a
    /// lake covering columns where `lake` is true, and a player at the centre.
    private func makePlain(_ preset: WorldPreset = .prehistoricLostWorldV3, radius: Int = 4, seed: UInt32 = 0xA1D0,
                           lake: (Int, Int) -> Bool = { _, _ in false }) -> (World, Player) {
        let world = World(dim: .overworld, seed: seed, generationSettings: .init(preset: preset))
        for cz in -radius..<radius {
            for cx in -radius..<radius {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                for z in 0..<CHUNK_W {
                    for x in 0..<CHUNK_W {
                        let wx = cx * CHUNK_W + x, wz = cz * CHUNK_W + z
                        chunk.set(x, 56, z, cell(B.stone))
                        if lake(wx, wz) {
                            chunk.set(x, 57, z, cell(B.sand))
                            for y in 58...63 { chunk.set(x, y, z, cell(B.water)) }
                        } else {
                            for y in 57..<63 { chunk.set(x, y, z, cell(B.dirt)) }
                            chunk.set(x, 63, z, cell(B.grass_block))
                        }
                    }
                }
                chunk.buildHeightmap()
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        let player = Player(world: world)
        player.setPos(0.5, 64, 0.5)
        world.addEntity(player)
        return (world, player)
    }

    private func creatures(_ world: World) -> [PrehistoricCreature] {
        world.entities.compactMap { $0 as? PrehistoricCreature }
    }

    // MARK: - names

    func testEveryRosterSpeciesResolvesByIdSpeciesAndDisplayName() {
        for definition in PrehistoricCreatureDefinition.all {
            let short = String(definition.id.dropFirst("prehistoric.".count))
            XCTAssertEqual(resolveAIAgentEntityName(definition.id), definition.id)
            XCTAssertEqual(resolveAIAgentEntityName(short), definition.id)
            XCTAssertEqual(resolveAIAgentEntityName(definition.displayName), definition.id)
            XCTAssertEqual(resolveAIAgentEntityName("prehistoric \(short)"), definition.id)
        }
    }

    func testNicknamesPluralsAndSaurFormsResolve() {
        let expected: [(String, String)] = [
            ("T. rex", "prehistoric.tyrannosaurus"), ("t-rex", "prehistoric.tyrannosaurus"),
            ("trex", "prehistoric.tyrannosaurus"), ("Tyrannosaurus rex", "prehistoric.tyrannosaurus"),
            ("raptor", "prehistoric.velociraptor"), ("raptors", "prehistoric.velociraptor"),
            ("brontosaurus", "prehistoric.diplodocus"), ("pterodactyl", "prehistoric.pteranodon"),
            ("stegosaurs", "prehistoric.stegosaurus"), ("mosasaur", "prehistoric.mosasaurus"),
            ("triceratops", "prehistoric.triceratops"), ("iguanodons", "prehistoric.iguanodon"),
            ("a spinosaurus", "prehistoric.spinosaurus"),
        ]
        for (name, id) in expected {
            XCTAssertEqual(resolveAIAgentEntityName(name), id, name)
        }
        // Ordinary names still win and unknown names still fail.
        XCTAssertEqual(resolveAIAgentEntityName("zombie"), "zombie")
        XCTAssertEqual(resolveAIAgentEntityName("cows"), "cow")
        XCTAssertNil(resolveAIAgentEntityName("dragonosaurus"))
    }

    func testGroupsCoverTheirRosterRoles() {
        let (world, _) = makePlain(.normal)
        XCTAssertTrue(AIAgentCreatureGroup.predators.pool(for: world).allSatisfy(\.isLandPredator))
        XCTAssertTrue(AIAgentCreatureGroup.herbivores.pool(for: world).allSatisfy(\.isLandHerdHerbivore))
        XCTAssertEqual(AIAgentCreatureGroup.predators.pool(for: world).count, 11)
        XCTAssertEqual(AIAgentCreatureGroup.herbivores.pool(for: world).count, 13)
        XCTAssertEqual(AIAgentCreatureGroup.flyers.pool(for: world).count, 6)
        XCTAssertEqual(AIAgentCreatureGroup.marineReptiles.pool(for: world).count, 6)
        XCTAssertEqual(AIAgentCreatureGroup.named("plant eaters"), .herbivores)
        XCTAssertEqual(AIAgentCreatureGroup.named("Carnivores"), .predators)
        XCTAssertEqual(AIAgentCreatureGroup.named("dinos"), .dinosaurs)
        XCTAssertNil(AIAgentCreatureGroup.named("cows"))
    }

    // MARK: - parsing

    func testSpawnListParsesGroupsSpeciesAndCounts() throws {
        XCTAssertEqual(try parseAIAgentSpawnList("some predators and herbivores"), [
            .init(subject: .group(.predators), count: nil), .init(subject: .group(.herbivores), count: nil),
        ])
        XCTAssertEqual(try parseAIAgentSpawnList("2 raptors, a t-rex"), [
            .init(subject: .entity("prehistoric.velociraptor"), count: 2),
            .init(subject: .entity("prehistoric.tyrannosaurus"), count: 1),
        ])
        XCTAssertEqual(try parseAIAgentSpawnList("3 triceratops 2 stegosaurus"), [
            .init(subject: .entity("prehistoric.triceratops"), count: 3),
            .init(subject: .entity("prehistoric.stegosaurus"), count: 2),
        ])
        XCTAssertEqual(try parseAIAgentSpawnList("a few pterosaurs"), [.init(subject: .group(.flyers), count: nil)])
        XCTAssertEqual(try parseAIAgentSpawnList("a herd"), [.init(subject: .group(.herbivores), count: nil)])
        XCTAssertEqual(try parseAIAgentSpawnList("a couple of cows"), [.init(subject: .entity("cow"), count: 2)])
        XCTAssertThrowsError(try parseAIAgentSpawnList("some unicorns")) { error in
            XCTAssertEqual(error as? AIAgentError, .unknownEntity("unicorns"))
        }
        XCTAssertThrowsError(try parseAIAgentSpawnList("cows, pigs, sheep, goats, chickens")) { error in
            XCTAssertEqual(error as? AIAgentError, .tooManySpawnGroups(5))
        }
        XCTAssertThrowsError(try parseAIAgentSpawnList("  ")) { error in
            XCTAssertEqual(error as? AIAgentError, .missingEntity)
        }
    }

    func testDirectRequestsRouteToAreaAndCursorSpawns() throws {
        let area = try XCTUnwrap(inferDirectAIAgentAction(from: "spawn some predators and herbivores in my area"))
        XCTAssertEqual(area.action, "spawn_group")
        XCTAssertEqual(area.target, "area")
        XCTAssertEqual(area.entity, "some predators and herbivores")

        XCTAssertEqual(inferDirectAIAgentAction(from: "summon 3 raptors around me")?.action, "spawn_group")
        XCTAssertEqual(inferDirectAIAgentAction(from: "Spawn dinosaurs nearby")?.action, "spawn_group")
        // Prehistoric creatures go to the area even without a place phrase.
        XCTAssertEqual(inferDirectAIAgentAction(from: "spawn a t-rex")?.action, "spawn_group")

        let cursor = try XCTUnwrap(inferDirectAIAgentAction(from: "spawn a T. rex at the cursor"))
        XCTAssertEqual(cursor.action, "spawn_entity")
        XCTAssertEqual(cursor.entity, "prehistoric.tyrannosaurus")
        XCTAssertEqual(inferDirectAIAgentAction(from: "spawn a dinosaur at the cursor")?.entity, "dinosaurs")

        // Ordinary mobs keep needing a place phrase, and give requests are not captured.
        XCTAssertNil(inferDirectAIAgentAction(from: "spawn cows")?.target)
        XCTAssertEqual(inferDirectAIAgentAction(from: "spawn some cows around me")?.action, "spawn_group")
        XCTAssertNotEqual(inferDirectAIAgentAction(from: "add 10 torches to my inventory")?.action, "spawn_group")
        XCTAssertNotEqual(inferDirectAIAgentAction(from: "give me a raptor spawn egg")?.action, "spawn_group")
    }

    func testModelActionsParseForTheNewSkill() throws {
        let action = try parseAIAgentAction(from: #"{"action":"spawn_group","target":"area","entity":"predators, herbivores"}"#)
        XCTAssertEqual(action.action, "spawn_group")
        XCTAssertTrue(allAIAgentSkills.contains { $0.name == "spawn_group" })
        let (world, player) = makePlain()
        let prompt = buildAIAgentPrompt(userRequest: "spawn predators near me", world: world, player: player, cursor: nil)
        XCTAssertTrue(prompt.contains(#""spawn_group""#))
        XCTAssertTrue(prompt.contains("tyrannosaurus"))
    }

    // MARK: - area spawns

    func testAreaSpawnPlacesRandomPredatorsAndHerbivoresAroundThePlayer() throws {
        let (world, player) = makePlain()
        let result = try executeAIAgentAction(
            try XCTUnwrap(inferDirectAIAgentAction(from: "spawn some predators and herbivores in my area")),
            world: world, player: player, cursor: nil)
        XCTAssertTrue(result.changedWorld)
        XCTAssertTrue(result.message.contains("predators"), result.message)
        XCTAssertTrue(result.message.contains("herbivores"), result.message)

        let spawned = creatures(world)
        let predators = spawned.filter { $0.definition.isLandPredator }
        let herbivores = spawned.filter { $0.definition.isLandHerdHerbivore }
        XCTAssertTrue((1...3).contains(predators.count), "\(predators.count) predators")
        XCTAssertTrue((3...6).contains(herbivores.count), "\(herbivores.count) herbivores")
        let profileIDs = try XCTUnwrap(world.generationSettings.preset.prehistoricProfile).creatureIDs
        for creature in spawned {
            let dx = creature.x - player.x, dz = creature.z - player.z
            let distance = (dx * dx + dz * dz).squareRoot()
            XCTAssertLessThanOrEqual(distance, Double(AIAgentMaxAreaSpawnRadius) + 8, creature.type)
            XCTAssertGreaterThanOrEqual(distance, 4, "\(creature.type) spawned on top of the player")
            XCTAssertTrue(creature.persistent)
            XCTAssertTrue(profileIDs.contains(creature.type), "\(creature.type) is outside this map's roster")
            XCTAssertTrue(spawnPlacementIsValid(world, creature.type, ifloor(creature.x), ifloor(creature.y), ifloor(creature.z)))
        }
    }

    func testAreaSpawnIsDeterministicForTheSameWorldState() throws {
        func run() throws -> [String] {
            let (world, player) = makePlain(seed: 0xBEEF)
            _ = try executeAIAgentAreaSpawn("dinosaurs", count: nil, radius: nil, world: world, player: player)
            return creatures(world).map { "\($0.type)@\($0.x),\($0.z)" }
        }
        XCTAssertEqual(try run(), try run())
    }

    func testExplicitCountsAreHonouredAndTheTotalIsCapped() throws {
        let (world, player) = makePlain()
        _ = try executeAIAgentAreaSpawn("2 raptors, 3 triceratops", count: nil, radius: nil, world: world, player: player)
        XCTAssertEqual(creatures(world).filter { $0.type == "prehistoric.velociraptor" }.count, 2)
        XCTAssertEqual(creatures(world).filter { $0.type == "prehistoric.triceratops" }.count, 3)

        let (big, bigPlayer) = makePlain()
        _ = try executeAIAgentAreaSpawn("99 raptors, 99 triceratops, 99 stegosaurus", count: nil, radius: nil,
                                        world: big, player: bigPlayer)
        XCTAssertLessThanOrEqual(creatures(big).count, AIAgentMaxSpawnCount)
        XCTAssertLessThanOrEqual(creatures(big).filter { $0.type == "prehistoric.velociraptor" }.count,
                                 AIAgentAreaSpawnMaxPerItem)
    }

    func testLandCreaturesAvoidWaterAndMarineReptilesNeedIt() throws {
        // Half the plain is a lake: land dinosaurs stand only on dry ground.
        let (world, player) = makePlain { x, _ in x >= 4 }
        _ = try executeAIAgentAreaSpawn("herbivores", count: 6, radius: nil, world: world, player: player)
        for creature in creatures(world) {
            XCTAssertLessThan(creature.x, 4, "\(creature.type) spawned in the lake")
        }
        // An all-land plain has no water for marine reptiles.
        let (dry, dryPlayer) = makePlain()
        XCTAssertThrowsError(try executeAIAgentAreaSpawn("marine reptiles", count: nil, radius: nil,
                                                         world: dry, player: dryPlayer)) { error in
            XCTAssertEqual(error as? AIAgentError, .areaSpawnFailed("marine reptiles"))
        }
        XCTAssertTrue(creatures(dry).isEmpty)
    }

    func testAreaSpawnWorksInOrdinaryWorldsAndForOrdinaryMobs() throws {
        let (world, player) = makePlain(.normal)
        _ = try executeAIAgentAreaSpawn("a t-rex and some cows", count: nil, radius: nil, world: world, player: player)
        XCTAssertEqual(creatures(world).filter { $0.type == "prehistoric.tyrannosaurus" }.count, 1)
        let cows = world.entities.compactMap { $0 as? Entity }.filter { $0.type == "cow" }
        XCTAssertTrue((2...4).contains(cows.count), "\(cows.count) cows")
    }

    func testSpawnEntityWithAreaTargetUsesTheAreaSpawn() throws {
        let (world, player) = makePlain()
        let result = try executeAIAgentAction(
            AIAgentAction(action: "spawn_entity", count: 2, target: "area", entity: "velociraptor"),
            world: world, player: player, cursor: nil)
        XCTAssertTrue(result.changedWorld)
        XCTAssertEqual(creatures(world).filter { $0.type == "prehistoric.velociraptor" }.count, 2)
        XCTAssertThrowsError(try executeAIAgentAction(
            AIAgentAction(action: "spawn_group", target: "cursor", entity: "predators"),
            world: world, player: player, cursor: nil)) { error in
            XCTAssertEqual(error as? AIAgentError, .invalidTarget("cursor"))
        }
    }

    // MARK: - cursor spawns

    func testCursorSummonOfALargeDinosaurFindsRoomNearTheCursor() throws {
        let (world, player) = makePlain()
        // A stone pillar right at the cursor leaves no room for a Brachiosaurus body there.
        for y in 64...70 { _ = world.setBlock(5, y, 5, Int(cell(B.stone))) }
        let hit = RaycastHit(x: 6, y: 63, z: 5, face: Dir.up, cell: Int(cell(B.grass_block)),
                             t: 1, px: 6.5, py: 64, pz: 5.5)
        let result = try executeAIAgentAction(
            try XCTUnwrap(inferDirectAIAgentAction(from: "summon a brachiosaurus at the cursor")),
            world: world, player: player, cursor: hit)
        XCTAssertTrue(result.message.contains("Brachiosaurus"), result.message)
        let brachio = try XCTUnwrap(creatures(world).first { $0.type == "prehistoric.brachiosaurus" })
        XCTAssertTrue(spawnPlacementIsValid(world, brachio.type, ifloor(brachio.x), ifloor(brachio.y), ifloor(brachio.z)))
        let dx = brachio.x - 6.5, dz = brachio.z - 5.5
        XCTAssertLessThanOrEqual((dx * dx + dz * dz).squareRoot(), 15, "placed near the cursor, not across the map")
    }

    func testCursorSummonOfSeveralDinosaursSpreadsThem() throws {
        let (world, player) = makePlain()
        let hit = RaycastHit(x: 8, y: 63, z: 8, face: Dir.up, cell: Int(cell(B.grass_block)),
                             t: 1, px: 8.5, py: 64, pz: 8.5)
        _ = try executeAIAgentAction(AIAgentAction(action: "spawn_entity", count: 3, target: "cursor", entity: "trike"),
                                     world: world, player: player, cursor: hit)
        let trikes = creatures(world).filter { $0.type == "prehistoric.triceratops" }
        XCTAssertEqual(trikes.count, 3)
        XCTAssertEqual(Set(trikes.map { "\($0.x),\($0.z)" }).count, 3, "each summoned body gets its own cell")
    }

    func testSpawnEntityWithADinosaurGroupAtTheCursorSpawnsARosterSpecies() throws {
        let (world, player) = makePlain()
        let hit = RaycastHit(x: 8, y: 63, z: 8, face: Dir.up, cell: Int(cell(B.grass_block)),
                             t: 1, px: 8.5, py: 64, pz: 8.5)
        let action = try XCTUnwrap(inferDirectAIAgentAction(from: "spawn a dinosaur at the cursor"))
        XCTAssertEqual(action.action, "spawn_entity")
        XCTAssertEqual(action.target, "cursor")
        let result = try executeAIAgentAction(action, world: world, player: player, cursor: hit)
        XCTAssertTrue(result.changedWorld)
        let spawned = creatures(world)
        XCTAssertEqual(spawned.count, 1)
        let creature = try XCTUnwrap(spawned.first)
        XCTAssertTrue(creature.definition.isLandPredator || creature.definition.isLandHerdHerbivore,
                      "\(creature.type) is not a member of the dinosaurs group")
        XCTAssertTrue(spawnPlacementIsValid(world, creature.type, ifloor(creature.x), ifloor(creature.y), ifloor(creature.z)))
    }

    // MARK: - area spawn bounds

    func testAreaSpawnNeverPlacesCreaturesWithinFourBlocksOfThePlayerAtMinimumRadius() throws {
        let (world, player) = makePlain()
        // The smallest allowed radius produces the tightest packed offsets,
        // the scenario most likely to place a body close to the player.
        _ = try executeAIAgentAreaSpawn("dinosaurs", count: 8, radius: 12, world: world, player: player)
        let spawned = creatures(world)
        XCTAssertFalse(spawned.isEmpty)
        for creature in spawned {
            let dx = creature.x - player.x, dz = creature.z - player.z
            let distance = (dx * dx + dz * dz).squareRoot()
            XCTAssertGreaterThanOrEqual(distance, 4, "\(creature.type) landed \(distance) blocks from the player")
        }
    }

    func testAreaSpawnNeverPlacesOutsideTheLoadedAreaNearAnUnloadedEdge() throws {
        // A small loaded island: with the maximum request radius, most
        // candidate sites fall off the loaded edge.
        let (world, player) = makePlain(radius: 1)
        do {
            _ = try executeAIAgentAreaSpawn("herbivores", count: 6, radius: AIAgentMaxAreaSpawnRadius,
                                            world: world, player: player)
        } catch let error as AIAgentError {
            XCTAssertEqual(error, .areaSpawnFailed("herbivores"))
        }
        for creature in creatures(world) {
            XCTAssertTrue(world.isLoadedAt(ifloor(creature.x), ifloor(creature.z)),
                         "\(creature.type) spawned outside the loaded area")
        }
    }

    func testAreaSpawnNeverExceedsSixteenTotalOrEightPerItem() throws {
        let (world, player) = makePlain()
        // Two unambiguous, non-overlapping items with absurd explicit counts:
        // every predator comes from the first item, every herbivore from the second.
        _ = try executeAIAgentAreaSpawn("999999999 predators, 999999999 herbivores",
                                        count: nil, radius: nil, world: world, player: player)
        let spawned = creatures(world)
        let predators = spawned.filter { $0.definition.isLandPredator }
        let herbivores = spawned.filter { $0.definition.isLandHerdHerbivore }
        XCTAssertLessThanOrEqual(predators.count, AIAgentAreaSpawnMaxPerItem, "predator item exceeded its per-item cap")
        XCTAssertLessThanOrEqual(herbivores.count, AIAgentAreaSpawnMaxPerItem, "herbivore item exceeded its per-item cap")
        XCTAssertLessThanOrEqual(spawned.count, AIAgentMaxSpawnCount, "total spawns exceeded the request-wide cap")
        XCTAssertGreaterThan(predators.count, 0)
        XCTAssertGreaterThan(herbivores.count, 0)
    }

    func testOrdinaryWorldRequestingMarineReptilesOnLandProducesACleanError() throws {
        let (world, player) = makePlain(.normal)
        XCTAssertThrowsError(try executeAIAgentAreaSpawn("marine reptiles", count: nil, radius: nil,
                                                         world: world, player: player)) { error in
            XCTAssertEqual(error as? AIAgentError, .areaSpawnFailed("marine reptiles"))
        }
        XCTAssertTrue(creatures(world).isEmpty)
    }

    // MARK: - robustness / fuzz

    func testHugeNumericSpawnCountsAreRejectedOrClampedWithoutCrashing() throws {
        // An Int64-overflowing digit string never parses as a number: it is
        // folded into the name text and rejected as an unresolvable species.
        XCTAssertThrowsError(try parseAIAgentSpawnList("999999999999999999999999999999 raptors")) { error in
            XCTAssertEqual(error as? AIAgentError, .unknownEntity("999999999999999999999999999999 raptors"))
        }

        // A huge but in-range count parses cleanly...
        let requests = try parseAIAgentSpawnList("9999999999 raptors")
        XCTAssertEqual(requests, [.init(subject: .entity("prehistoric.velociraptor"), count: 9_999_999_999)])

        // ...and is clamped, not crashed, once executed.
        let (world, player) = makePlain()
        _ = try executeAIAgentAreaSpawn("9999999999 raptors", count: nil, radius: nil, world: world, player: player)
        let raptors = creatures(world).filter { $0.type == "prehistoric.velociraptor" }
        XCTAssertGreaterThan(raptors.count, 0)
        XCTAssertLessThanOrEqual(raptors.count, AIAgentAreaSpawnMaxPerItem)

        // The Int64 boundary itself does not overflow arithmetic either.
        let (edgeWorld, edgePlayer) = makePlain()
        _ = try executeAIAgentAreaSpawn("9223372036854775807 triceratops", count: nil, radius: nil,
                                        world: edgeWorld, player: edgePlayer)
        XCTAssertLessThanOrEqual(creatures(edgeWorld).count, AIAgentAreaSpawnMaxPerItem)

        // A model-supplied JSON count that overflows Int64 fails to decode cleanly.
        XCTAssertThrowsError(try parseAIAgentAction(
            from: #"{"action":"spawn_group","target":"area","entity":"raptors","count":99999999999999999999999999999}"#
        )) { error in
            XCTAssertEqual(error as? AIAgentError, .malformedJSON)
        }
    }

    /// A deterministic seeded fuzz over random mixes of numbers, quantity words,
    /// separators, group names, species names, nicknames and junk. The parser
    /// must never crash, must resolve every accepted item to a real spawnable id
    /// or group, must never report a negative count, and must never accept more
    /// than the item cap.
    func testParseAIAgentSpawnListFuzzNeverCrashesAndInvariantsHold() {
        let vocabulary: [String] = [
            "0", "1", "2", "3", "4", "5", "8", "12", "99",
            "999999999999999999999999999999", "9999999999999999999999999999999999999999",
            "a", "an", "the", "of", "some", "few", "several", "many", "random", "number",
            "couple", "pair", "dozen", "handful", "extra", "various", "more", "amount",
            ",", ";", "&", "+", "/", "and", "plus", "with", "also", "then",
            "predators", "herbivores", "dinosaurs", "pterosaurs", "marine", "reptiles",
            "marine_reptiles", "carnivores", "plant", "eaters", "herd", "pack", "flock",
            "pod", "school",
            "raptor", "raptors", "t-rex", "t.rex", "trex", "triceratops", "trike",
            "stegosaurus", "brontosaurus", "mosasaurus", "pteranodon", "compsognathus",
            "spinosaurus", "prehistoric.tyrannosaurus", "iguanodons",
            "cow", "cows", "pig", "zombie", "sheep", "unicorns",
            "asdkjhaskjd", "!!!", "kind", "type", "🦖", "   ",
        ]
        var rng = RandomX(0xF00D_5EED)
        func randomPhrase(maxWords: Int) -> String {
            let n = rng.nextInt(maxWords + 1)
            var words: [String] = []
            for _ in 0..<n { words.append(vocabulary[rng.nextInt(vocabulary.count)]) }
            return words.joined(separator: " ")
        }
        var successes = 0, failures = 0
        for _ in 0..<3_000 {
            let phrase = randomPhrase(maxWords: rng.nextBoolean() ? 6 : 24)
            do {
                let requests = try parseAIAgentSpawnList(phrase)
                successes += 1
                XCTAssertLessThanOrEqual(requests.count, AIAgentAreaSpawnMaxItems, phrase)
                XCTAssertFalse(requests.isEmpty, phrase)
                for request in requests {
                    if let count = request.count {
                        XCTAssertGreaterThanOrEqual(count, 0, "\(phrase) -> negative count \(count)")
                    }
                    if case .entity(let id) = request.subject {
                        XCTAssertEqual(resolveAIAgentEntityName(id), id, "\(phrase) -> non-spawnable id \(id)")
                    }
                }
            } catch is AIAgentError {
                failures += 1
            } catch {
                XCTFail("unexpected non-AIAgentError for \(phrase): \(error)")
            }
        }
        // The fuzz mix should exercise both the happy and the error path;
        // if either count is zero the vocabulary/generator stopped being representative.
        XCTAssertGreaterThan(successes, 0)
        XCTAssertGreaterThan(failures, 0)
    }
}
