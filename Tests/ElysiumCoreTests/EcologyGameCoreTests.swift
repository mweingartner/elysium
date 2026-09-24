import Foundation
import XCTest
@testable import ElysiumCore

@MainActor
final class EcologyGameCoreTests: XCTestCase {
    // GameCore retains its production host weakly; keep the fixture host alive
    // so advancement toasts drain through the real tick path after sleeping.
    private let testHost = EcologyGameCoreTestHost()

    private func makeGame(_ label: String, frequency: CreatureRespawnFrequency) throws -> GameCore {
        let settingsRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ElysiumEcologyGameCore-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: settingsRoot) }
        let store = LocalSettingsStore(directoryURL: settingsRoot)
        var settings = Settings()
        settings.renderDistance = 4
        settings.creatureRespawnFrequency = frequency
        try store.persistSettings(settings).get()
        let game = GameCore(
            db: try PersistenceTestSupport.makeDatabase(owner: self, label: "ecology-\(label)"),
            localSettingsStore: store)
        game.host = testHost
        // The flat fixture avoids expensive terrain/structure generation. No population is
        // needed to exercise the real tick's eligibility/consumption and persistence funnels.
        game.createWorld(name: "Ecology \(label)", seedText: "24000",
                         mode: GameMode.creative, difficulty: 0, worldPreset: .flat,
                         dungeonDensity: .none, villageDensity: .none, mapSize: .small)
        game.setGameRule("doMobSpawning", 0)
        game.world.randomTickSpeed = 0
        return game
    }

    func testRainySleepAcrossNaturalDawnWakesWithoutCountingAnotherDay() throws {
        let game = try makeGame("late-sleep", frequency: .alternateDays)
        defer { game.exitToTitle() }
        let world = game.world
        XCTAssertTrue(world.isChunkReady(0, 0))
        world.dayTime = DAY_LENGTH - 50
        world.ecologyCalendar = EcologyCalendar()
        world.raining = true
        world.thundering = true
        world.rainLevel = 1
        world.thunderLevel = 1
        world.weatherTimer = DAY_LENGTH
        let bed = Int(cell(B.red_bed))
        world.setBlock(8, -60, 8, bed)
        game.player.setPos(8.5, -59, 8.5)
        let hit = RaycastHit(x: 8, y: -60, z: 8, face: Dir.up, cell: bed, t: 1,
                            px: 8.5, py: -59, pz: 8.5)
        XCTAssertTrue(useBlock(InteractCtx(world: world, player: game.player), hit))
        XCTAssertEqual(game.player.sleepTicks, 1,
                       "rainy daylight must reach the real successful bed-use path")

        for _ in 0..<50 { _ = game.frame(dtMs: TICK_MS) }

        XCTAssertEqual(game.player.sleepTicks, 0, "natural dawn must end the pending sleep")
        XCTAssertEqual(world.dayTime, 0)
        XCTAssertEqual(world.ecologyTick, 50)
        XCTAssertEqual(world.ecologyCalendar.completedDawns, 1)
        XCTAssertEqual(world.ecologyCalendar.lastRespawnDawn, 0,
                       "alternate-day replenishment is not due after one dawn")
        for _ in 0..<60 { _ = game.frame(dtMs: TICK_MS) }
        XCTAssertEqual(world.dayTime, 60)
        XCTAssertEqual(world.ecologyTick, 110)
        XCTAssertEqual(world.ecologyCalendar.completedDawns, 1)
        XCTAssertEqual(world.ecologyCalendar.lastRespawnDawn, 0,
                       "the original sleep timeout must not manufacture a second dawn")
    }

    func testActualWorldSaveReloadPreservesCalendarRatioAndConsumedDawn() throws {
        let game = try makeGame("reload", frequency: .weekly)
        defer { if game.hasWorld() { game.exitToTitle() } }
        let worldID = try XCTUnwrap(game.worldRec?.id)
        let overworld = game.world
        for _ in 0..<6 {
            overworld.ecologyCalendar.advance(ticks: DAY_LENGTH, dawn: true)
            XCTAssertFalse(overworld.ecologyCalendar.consumeRespawnDawn(frequency: .weekly))
        }
        overworld.dayTime = DAY_LENGTH - 1
        overworld.creatureRespawnSequence = 2
        let nether = try XCTUnwrap(game.worlds[.nether])
        nether.ecologyCalendar = EcologyCalendar(elapsedTicks: 12345, completedDawns: 4,
                                                 lastRespawnDawn: 2)
        nether.creatureRespawnSequence = 1
        let before = overworld.ecologyCalendar
        let netherBefore = nether.ecologyCalendar

        game.exitToTitle()
        let stored = try XCTUnwrap(game.db.getWorld(worldID))
        XCTAssertEqual(stored.dims[String(Dim.overworld.rawValue)]?.ecologyCalendar, before)
        XCTAssertEqual(stored.dims[String(Dim.overworld.rawValue)]?.creatureRespawnSequence, 2)
        XCTAssertEqual(stored.dims[String(Dim.nether.rawValue)]?.ecologyCalendar, netherBefore)
        XCTAssertEqual(stored.dims[String(Dim.nether.rawValue)]?.creatureRespawnSequence, 1)
        game.loadWorld(worldID)

        XCTAssertEqual(game.world.ecologyCalendar, before)
        XCTAssertEqual(game.world.creatureRespawnSequence, 2)
        XCTAssertEqual(game.worlds[.nether]?.ecologyCalendar, netherBefore)
        XCTAssertEqual(game.worlds[.nether]?.creatureRespawnSequence, 1)
        game.world.randomTickSpeed = 0
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertEqual(game.world.dayTime, 0)
        XCTAssertEqual(game.world.ecologyCalendar.completedDawns, 7)
        XCTAssertEqual(game.world.ecologyCalendar.lastRespawnDawn, 7,
                       "the seventh dawn must consume eligibility even with spawning disabled")
        XCTAssertEqual(game.world.creatureRespawnSequence, 2,
                       "an unsuccessful wave must not spend the next successful birth's ratio slot")
        let consumed = game.world.ecologyCalendar

        game.exitToTitle()
        game.loadWorld(worldID)
        XCTAssertEqual(game.world.ecologyCalendar, consumed)
        XCTAssertEqual(game.world.creatureRespawnSequence, 2)
        XCTAssertFalse(game.world.ecologyCalendar.consumeRespawnDawn(frequency: .weekly),
                       "loading a dawn save must not replay the already-consumed wave")
        game.world.randomTickSpeed = 0
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertEqual(game.world.ecologyCalendar.completedDawns, 7)
        XCTAssertEqual(game.world.ecologyCalendar.lastRespawnDawn, 7)
    }
}

private final class EcologyGameCoreTestHost: GameHost {
    func hasScreen() -> Bool { false }; func screenPausesGame() -> Bool { false }
    func openScreen(_ kind: String, _ data: ScreenData?) {}
    func openTrading(_ villager: Mob) {}; func openVehicleChest(_ kind: String, _ vehicle: Entity) {}
    func openChat(_ prefix: String) {}; func openDeathScreen(_ message: String) {}
    func openPauseScreen() {}; func openTitleScreen() {}; func closeAllScreens() {}
    func releasePointer() {}; func capturePointer() {}; func showActionBar(_ text: String, _ time: Int) {}
    func pushChat(_ line: String) {}; func pushToast(_ adv: AdvancementDef) {}
    func setBossBars(_ bars: [BossBarInfo]) {}
    func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double,
                   _ volume: Double, _ pitch: Double) {}
    func playUI(_ name: String) {}; func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
    func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {}
    func tickMusic(_ mood: String, _ enabled: Bool) {}; func stopDisc() {}
    func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double,
                      _ count: Int, _ spread: Double, _ cell: Int) {}
    func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double,
                            _ groundY: Double) {}
    func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {}
    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {}; func clearAllSections() {}
}
