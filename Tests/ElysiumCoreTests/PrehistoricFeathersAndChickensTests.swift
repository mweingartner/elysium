import XCTest
@testable import ElysiumCore

/// Dinosaurs shed feathers like birds, and dinosaur maps keep chickens so arrows can be fletched.
final class PrehistoricFeathersAndChickensTests: XCTestCase {
    override class func setUp() {
        registerAllBlocks(); registerAllItems(); registerAllBiomes(); registerAllEntities(); registerAllSystems()
    }

    private let prehistoricPresets = WorldPreset.allCases.filter { $0.isPrehistoric }

    private func groundWorld(_ preset: WorldPreset) -> World {
        let world = World(dim: .overworld, seed: 4242, generationSettings: .init(preset: preset))
        for cz in -1...1 { for cx in -1...1 {
            let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
            chunk.status = .lit
            for z in 0..<16 { for x in 0..<16 { chunk.set(x, 62, z, cell(B.stone)); chunk.set(x, 63, z, cell(B.grass_block)) } }
            chunk.buildHeightmap(); world.setChunk(chunk); world.light.initChunkLight(chunk)
        } }
        return world
    }

    func testDinosaursShedFeathersButOtherPrehistoricReptilesKeepTheirLoot() {
        let world = groundWorld(.prehistoricLostWorldV4)
        for definition in PrehistoricCreatureDefinition.all {
            let creature = PrehistoricCreature(world: world, definition: definition)
            let feather = creature.drops().first { $0.item == "feather" }
            if definition.family.isDinosaur {
                XCTAssertEqual(feather?.min, 0, definition.id)
                XCTAssertEqual(feather?.max, 2, definition.id)
                XCTAssertEqual(feather?.lootingBonus, 1, definition.id)
                XCTAssertTrue(creature.drops().contains { $0.item == "bone" }, "\(definition.id) keeps its bones")
            } else if definition.medium == .air {
                XCTAssertNotNil(feather, "pterosaurs keep their existing feather drop: \(definition.id)")
            } else {
                XCTAssertNil(feather, "marine reptiles and the crocodilian are not dinosaurs: \(definition.id)")
            }
        }
        let dinosaurs = PrehistoricCreatureDefinition.all.filter { $0.family.isDinosaur }
        XCTAssertGreaterThan(dinosaurs.count, PrehistoricCreatureDefinition.all.count / 2, "most of the roster")
    }

    func testKillingADinosaurDropsZeroToTwoFeathersPlusLooting() throws {
        let world = groundWorld(.prehistoricLostWorldV4)
        let raptor = try XCTUnwrap(PrehistoricCreatureDefinition.named("prehistoric.velociraptor"))
        var feathers: [Int] = []
        let previous = spawnItemFn
        defer { spawnItemFn = previous }
        var dropped = 0
        spawnItemFn = { _, _, _, _, stack, _, _, _ in if itemName(stack.id) == "feather" { dropped += stack.count } }
        for looting in [0, 3] {
            for _ in 0..<400 {
                dropped = 0
                PrehistoricCreature(world: world, definition: raptor).dropLoot(looting, true)
                feathers.append(dropped)
            }
            let seen = Set(feathers)
            XCTAssertTrue(seen.contains(0) && seen.contains(2), "looting \(looting): \(seen.sorted())")
            XCTAssertLessThanOrEqual(feathers.max() ?? 0, 2 + looting)
            if looting > 0 { XCTAssertGreaterThan(feathers.max() ?? 0, 2, "looting adds feathers") }
            feathers.removeAll()
        }
    }

    func testEveryLandProfileSpawnsChickensAsAboutAnEighthOfItsLandTable() {
        for preset in prehistoricPresets {
            guard let profile = preset.prehistoricProfile else { continue }
            let land = prehistoricSpawnEntries(profile: profile, category: "creature")
            let chickens = land.filter { $0.mob == "chicken" }
            if land.allSatisfy({ $0.mob == "chicken" }) {
                XCTAssertTrue(land.isEmpty, "a profile without land dinosaurs gets no chickens: \(preset)")
                continue
            }
            XCTAssertEqual(chickens.count, 1, "\(preset)")
            let total = land.reduce(0) { $0 + $1.weight }
            XCTAssertEqual(chickens[0].weight / total, 1.0 / 8, accuracy: 0.03, "\(preset)")
            XCTAssertEqual(chickens[0].minPack, 2); XCTAssertEqual(chickens[0].maxPack, 4)
            XCTAssertFalse(prehistoricSpawnEntries(profile: profile, category: "ambient").contains { $0.mob == "chicken" })
            XCTAssertTrue(prehistoricProfileSpawnsMob(profile, "chicken"))
            XCTAssertFalse(prehistoricProfileSpawnsMob(profile, "cow"))
            XCTAssertFalse(prehistoricProfileSpawnsMob(profile, "villager"))
        }
        XCTAssertTrue(prehistoricPresets.contains { preset in
            preset.prehistoricProfile.map { prehistoricSpawnEntries(profile: $0, category: "creature").isEmpty } ?? false
        }, "Ancient Seas still has no land table")
    }

    func testDawnRefillReplacesChickensWithTheHerbivoresNotThePredators() throws {
        let profile = try XCTUnwrap(WorldPreset.prehistoricLostWorldV4.prehistoricProfile)
        XCTAssertTrue(prehistoricDawnLandEntries(profile: profile, sequence: 0).contains { $0.mob == "chicken" })
        XCTAssertFalse(prehistoricDawnLandEntries(profile: profile, sequence: 2).contains { $0.mob == "chicken" })
    }

    func testGeneratedChickensMaterializeWhileOtherOrdinaryOccupantsStayOut() {
        let world = groundWorld(.prehistoricLostWorldV4)
        func spec(_ mob: String) -> EntitySpec { EntitySpec(mob: mob, x: 4.5, y: 64, z: 4.5, data: [:]) }
        XCTAssertTrue(GameCore.shouldMaterializeGeneratedEntity(spec("chicken"), in: world))
        for occupant in ["villager", "cow", "sheep", "zombie"] {
            XCTAssertFalse(GameCore.shouldMaterializeGeneratedEntity(spec(occupant), in: world), occupant)
        }
        // Ancient Seas has no land table, so a generated chicken is still a foreign occupant there.
        let seas = groundWorld(.prehistoricAncientSeasV4)
        XCTAssertFalse(GameCore.shouldMaterializeGeneratedEntity(spec("chicken"), in: seas))
    }

    func testGeneratedDinosaurMapsContainChickenFlocks() {
        let settings = WorldGenerationSettings(preset: .prehistoricLostWorldV4)
        var chickens = 0
        for cz in -3...3 { for cx in -3...3 {
            chickens += generateChunk(.overworld, 7_301, cx, cz, settings: settings).entities.filter { $0.mob == "chicken" }.count
        } }
        XCTAssertGreaterThan(chickens, 0, "a 7x7-chunk dinosaur map (fixed seed) starts with chicken flocks")
    }
}
