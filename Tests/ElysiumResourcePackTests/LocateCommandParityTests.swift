import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class LocateCommandParityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
        registerAllStructures()
    }

    override func setUp() {
        super.setUp()
        chatLog.removeAll()
        resetStructurePlanCacheForTesting()
    }

    override func tearDown() {
        chatLog.removeAll()
        resetStructurePlanCacheForTesting()
        super.tearDown()
    }

    private func makeCreatedWorld(preset: WorldPreset = .singleBiomeSurface) throws -> GameCore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("elysium-locate-parity-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let game = GameCore(db: try SaveDB.open(
            databaseURL: root.appendingPathComponent("worlds.sqlite"),
            migrateLegacy: false
        ))
        game.createWorld(name: "Locate Parity", seedText: "1", mode: GameMode.creative,
                         difficulty: 2, worldPreset: preset, singleBiome: .plains,
                         dungeonDensity: .normal, villageDensity: .max)
        return game
    }

    private func reportedOrigin(_ line: String, target: String) throws -> (Int, Int) {
        let prefix = "§7Nearest \(target): "
        guard line.hasPrefix(prefix) else {
            throw NSError(domain: "LocateCommandParityTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "/locate did not report a \(target) location: \(line)"])
        }
        let parts = line.dropFirst(prefix.count).split(separator: ",", maxSplits: 2,
                                                        omittingEmptySubsequences: false)
        guard parts.count == 3,
              let x = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let z = Int(parts[2].trimmingCharacters(in: .whitespaces)) else {
            throw NSError(domain: "LocateCommandParityTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey:
                            "/locate returned malformed coordinates: \(line)"])
        }
        XCTAssertEqual((x - 8) % 16, 0)
        XCTAssertEqual((z - 8) % 16, 0)
        return ((x - 8) / 16, (z - 8) / 16)
    }

    private func firstLocateCandidate(_ definition: StructureDef,
                                      context: GenCtx,
                                      collisionDefinitions: [StructureDef],
                                      playerChunkX: Int = 0,
                                      playerChunkZ: Int = 0) -> (Int, Int)? {
        guard let placement = definition.placement(context) else { return nil }
        for radius in 0..<12 {
            for regionZOffset in -radius...radius {
                for regionXOffset in -radius...radius {
                    if max(abs(regionXOffset), abs(regionZOffset)) != radius { continue }
                    let regionX = Int((Double(playerChunkX) / Double(placement.spacing)).rounded(.down))
                        + regionXOffset
                    let regionZ = Int((Double(playerChunkZ) / Double(placement.spacing)).rounded(.down))
                        + regionZOffset
                    let origin = structureOriginFor(definition, placement: placement,
                                                    seed: context.seed,
                                                    regionX: regionX, regionZ: regionZ)
                    if let plan = getPlan(definition, context, origin.0, origin.1),
                       surfaceStructurePlanWins(definition, plan, context, origin.0, origin.1,
                                                collisionDefinitions: collisionDefinitions) {
                        return origin
                    }
                }
            }
        }
        return nil
    }

    /// The seed's first legacy candidate is `(4, -21)`: its estimate-only
    /// plan was formerly reported by the app command, but exact terrain
    /// rejects it. The real command must instead select the same later
    /// candidate that world generation emits. This reaches `CommandsM` rather
    /// than merely checking the Core planner in isolation.
    func testLocateReportsAnActuallyEmittedExactTerrainWinningOutpost() throws {
        let game = try makeCreatedWorld()
        let player = try XCTUnwrap(game.player)
        player.setPos(0.5, 120, 0.5)
        let world = game.world
        let settings = world.generationSettings
        XCTAssertEqual(settings.preset, .singleBiomeSurface)
        XCTAssertEqual(settings.villageDensity, .max)
        let active = structureDefinitionsForGeneration(dim: .overworld, settings: settings)
        let definition = try XCTUnwrap(active.first { $0.id == "pillager_outpost" })
        let generator = overworldGen(world.seed, settings: settings)
        let legacyContext = GenCtx(
            seed: world.seed,
            heightAt: { x, z in generator.refinedHeightEstimate(Double(x), Double(z)) },
            biomeAt: { x, z in generator.surfaceBiomeAt(Double(x), Double(z)).rawValue },
            dim: Dim.overworld.rawValue,
            villageDensity: settings.villageDensity,
            generationSettingsIdentity: settings.cacheIdentity
        )
        let legacyOrigin = try XCTUnwrap(firstLocateCandidate(
            definition, context: legacyContext, collisionDefinitions: active
        ))
        XCTAssertEqual(legacyOrigin.0, 4)
        XCTAssertEqual(legacyOrigin.1, -21)

        resetStructurePlanCacheForTesting()
        runCommand(game, "/locate pillager_outpost")
        let line = try XCTUnwrap(chatLog.last?.text)
        let commandOrigin = try reportedOrigin(line, target: "pillager_outpost")

        let exactContext = try XCTUnwrap(structurePlanningContext(
            seed: world.seed, dim: .overworld, settings: settings
        ))
        XCTAssertEqual(exactContext.baseTerrainOracleVersion, baseTerrainOracleVersion)
        XCTAssertNotNil(exactContext.terrainOracle)
        let expectedOrigin = try XCTUnwrap(firstLocateCandidate(
            definition, context: exactContext, collisionDefinitions: active
        ))
        XCTAssertTrue(legacyOrigin.0 != expectedOrigin.0 || legacyOrigin.1 != expectedOrigin.1,
                      "the reviewed seed must distinguish no-oracle lookup from actual terrain")
        XCTAssertEqual(commandOrigin.0, expectedOrigin.0)
        XCTAssertEqual(commandOrigin.1, expectedOrigin.1)

        let plan = try XCTUnwrap(getPlan(definition, exactContext, commandOrigin.0, commandOrigin.1))
        XCTAssertTrue(surfaceStructurePlanWins(definition, plan, exactContext,
                                               commandOrigin.0, commandOrigin.1,
                                               collisionDefinitions: active))
        let reference = try XCTUnwrap(plan.ref)
        let output = generateChunk(.overworld, world.seed,
                                   floorDiv(reference.x0, 16), floorDiv(reference.z0, 16),
                                   settings: settings)
        XCTAssertTrue(output.structRefs.contains {
            $0.id == definition.id
                && $0.x0 == reference.x0 && $0.y0 == reference.y0 && $0.z0 == reference.z0
                && $0.x1 == reference.x1 && $0.y1 == reference.y1 && $0.z1 == reference.z1
        }, "the reported winning plan must be emitted by real Overworld generation")
    }

    func testLocateRefusesStructuresInCreatedDebugModeWorld() throws {
        let game = try makeCreatedWorld(preset: .debugAllBlockStates)
        let player = try XCTUnwrap(game.player)
        player.setPos(0.5, 120, 0.5)
        XCTAssertEqual(game.world.generationSettings.preset, .debugAllBlockStates)
        XCTAssertTrue(structureDefinitionsForGeneration(dim: .overworld,
                                                         settings: game.world.generationSettings).isEmpty)
        XCTAssertNil(structurePlanningContext(seed: game.world.seed, dim: .overworld,
                                              settings: game.world.generationSettings))

        runCommand(game, "/locate pillager_outpost")
        XCTAssertEqual(chatLog.map(\.text), ["§cpillager_outpost generation is disabled for this world"])
    }
}
