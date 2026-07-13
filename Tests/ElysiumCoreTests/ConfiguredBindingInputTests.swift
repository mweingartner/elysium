import Foundation
import XCTest
@testable import ElysiumCore

@MainActor
final class ConfiguredBindingInputTests: XCTestCase {
    private var settingsRoots: [URL] = []

    override func tearDown() {
        for root in settingsRoots { try? FileManager.default.removeItem(at: root) }
        settingsRoots.removeAll()
        super.tearDown()
    }

    private func makeGame(_ label: String) throws -> GameCore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ElysiumConfiguredBinding-\(label)-\(UUID().uuidString)",
                                   isDirectory: true)
        settingsRoots.append(root)
        return GameCore(
            db: try PersistenceTestSupport.makeDatabase(owner: self, label: label),
            localSettingsStore: LocalSettingsStore(directoryURL: root))
    }

    private func publish(_ bindings: [String: String], to game: GameCore) {
        let publication = MainActor.assumeIsolated {
            game.persistAndPublishKeybindCandidate(
                bindings, expectedLiveRevision: game.keybindRevision)
        }
        guard case .success = publication else {
            return XCTFail("modified binding publication failed: \(publication)")
        }
    }

    func testCanonicalModifiedMovementPressAndPairedReleaseDriveGameCore() throws {
        let game = try makeGame("configured-binding")
        var bindings = game.keybinds
        bindings["forward"] = "Option+KeyW"
        publish(bindings, to: game)
        game.createWorld(name: "Configured Binding", seedText: "6217",
                         mode: GameMode.survival, difficulty: 2)

        // The typed boundary rejects a stale or fabricated configured-code token.
        game.keyDown(binding: .forward, configuredCode: "KeyW", now: 1_000)
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertEqual(game.player.moveForward, 0)

        game.keyDown(binding: .forward, configuredCode: "Option+KeyW", now: 2_000)
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertEqual(game.player.moveForward, 1)

        game.keyUp(binding: .forward, configuredCode: "Option+KeyW")
        _ = game.frame(dtMs: TICK_MS)
        XCTAssertEqual(game.player.moveForward, 0)
    }

    func testExplicitControlDropBindingRemainsSingleItemAction() throws {
        let game = try makeGame("configured-control-drop")
        var bindings = game.keybinds
        bindings["drop"] = "Control+KeyQ"
        publish(bindings, to: game)
        game.enterLANClientWorld(LANWorldSummary(
            worldID: "configured-drop-host", worldName: "Configured Drop Host", seed: 6218,
            gameMode: GameMode.survival, difficulty: 2, dimension: Dim.overworld.rawValue,
            playerCount: 2))
        game.player.selectedSlot = 0
        game.player.inventory[0] = ItemStack(iid("dirt"), 5)
        var captured: [LANTossIntent] = []
        game.lanTossIntentHandler = { captured.append($0) }

        game.keyDown(binding: .drop, configuredCode: "Control+KeyQ", now: 1_000)

        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?.count, 1)
        XCTAssertFalse(captured.first?.all ?? true)
        XCTAssertEqual(game.player.inventory[0]?.count, 4)
    }

    func testModifiedInventoryBindingExecutesCanonicalInventoryAction() throws {
        let game = try makeGame("configured-inventory")
        let host = ConfiguredBindingHost(); game.host = host
        var bindings = game.keybinds
        bindings["inventory"] = "Option+KeyE"
        publish(bindings, to: game)
        game.createWorld(name: "Configured Inventory", seedText: "6219",
                         mode: GameMode.survival, difficulty: 2)
        host.openedScreens.removeAll()

        game.keyDown(binding: .inventory, configuredCode: "KeyE", now: 1_000)
        XCTAssertTrue(host.openedScreens.isEmpty)
        game.keyDown(binding: .inventory, configuredCode: "Option+KeyE", now: 1_001)
        XCTAssertEqual(host.openedScreens, ["inventory"])
    }
}

private final class ConfiguredBindingHost: GameHost {
    var openedScreens: [String] = []
    func hasScreen() -> Bool { false }; func screenPausesGame() -> Bool { false }
    func openScreen(_ kind: String, _ data: ScreenData?) { openedScreens.append(kind) }
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
