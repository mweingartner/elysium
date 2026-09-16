import XCTest
@testable import ElysiumCore

final class WitchHutWorldgenTests: XCTestCase {
    private let seed: UInt32 = 0x57_17_C0DE
    private let fixtureChunk = (x: 13, z: 17)

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    func testRegularSwampHutPublishesItsWitchAndBlackCat() throws {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface, singleBiome: .swamp)

        let output = generateChunk(.overworld, seed, fixtureChunk.x, fixtureChunk.z, settings: settings)

        let ref = try XCTUnwrap(output.structRefs.first { $0.id == "witch_hut" },
                                "the emitted swamp chunk must publish its witch-hut reference")
        let witch = try XCTUnwrap(output.entities.first { $0.mob == "witch" },
                                  "a generated swamp hut must publish its resident witch")
        let cat = try XCTUnwrap(output.entities.first { $0.mob == "cat" },
                                "a generated swamp hut must publish its resident cat")
        XCTAssertEqual(witch.data["persistent"], .bool(true))
        XCTAssertEqual(cat.data["persistent"], .bool(true))
        XCTAssertEqual(cat.data["variant"], .num(Double(CatVariant.allBlack.rawValue)))
        XCTAssertTrue((Double(ref.x0)...Double(ref.x1)).contains(witch.x))
        XCTAssertTrue((Double(ref.z0)...Double(ref.z1)).contains(witch.z))
        XCTAssertTrue(output.blockEntities.contains {
            $0.kind == "pot_plant" && $0.data["plant"] == .str("red_mushroom")
        }, "the emitted hut must retain its canonical furnishing")
    }

    @MainActor
    func testGeneratedHutBlackCatSurvivesGameCoreChunkAdoption() throws {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface, singleBiome: .swamp)
        let output = generateChunk(.overworld, seed, fixtureChunk.x, fixtureChunk.z, settings: settings)
        let expected = try XCTUnwrap(output.entities.first { $0.mob == "cat" },
                                     "fixture must contain the witch hut's black cat")

        let game = PersistenceTestSupport.makeGame(owner: self, label: "witch-hut-cat-adoption")
        game.createWorld(name: "Witch Hut Adoption", seedText: String(Int32(bitPattern: seed)),
                         mode: GameMode.survival, difficulty: 2,
                         worldPreset: .singleBiomeSurface, singleBiome: .swamp)
        XCTAssertTrue(game.ensureAuthoritativeLANChunkLoaded(
            dimension: Dim.overworld.rawValue, cx: fixtureChunk.x, cz: fixtureChunk.z))

        let cat = try XCTUnwrap(game.world.entities.compactMap { $0 as? Cat }.first {
            $0.persistent && abs($0.x - expected.x) < 0.0001 && abs($0.z - expected.z) < 0.0001
        }, "worldgen adoption must retain the hut cat rather than only its output metadata")
        XCTAssertEqual(cat.data.variant, CatVariant.allBlack.rawValue)
        XCTAssertTrue(cat.persistent)
    }

    func testMangroveSwampDoesNotEmitWitchHut() throws {
        let settings = WorldGenerationSettings(preset: .singleBiomeSurface, singleBiome: .mangroveSwamp)

        let output = generateChunk(.overworld, seed, fixtureChunk.x, fixtureChunk.z, settings: settings)

        XCTAssertFalse(output.structRefs.contains { $0.id == "witch_hut" })
        XCTAssertFalse(output.entities.contains { $0.mob == "witch" })
    }
}
