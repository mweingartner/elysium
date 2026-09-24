import Foundation
import Metal
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class CreatureRespawnOptionsTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    @MainActor
    private func fixture(width: Double = 480) throws
        -> (SettingsScreen, UIManager, GameCore, LocalSettingsStore) {
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ElysiumCreatureRespawnOptions-\(UUID().uuidString)",
                                   isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let store = LocalSettingsStore(directoryURL: root.appendingPathComponent("settings"))
        let game = GameCore(db: try SaveDB.open(
            databaseURL: root.appendingPathComponent("worlds.sqlite"), migrateLegacy: false),
            localSettingsStore: store)
        let ui = UIManager(cv: UICanvas(device: try XCTUnwrap(MTLCreateSystemDefaultDevice())))
        ui.resize(width, 240, 1)
        let screen = SettingsScreen()
        ui.open(screen, game)
        XCTAssertTrue(screen.performTextAccessibilityAction("settings.tab.world", ui, game))
        return (screen, ui, game, store)
    }

    @MainActor
    func testWorldPreferenceCyclesDurablyWithKeyboardAndAccessibility() throws {
        let (screen, ui, game, store) = try fixture()
        XCTAssertEqual(screen.tab, "world")
        let initialRevision = game.settingsRevision
        let id = "world.creature-respawn-frequency"
        XCTAssertTrue(screen.focusTextAccessibilityElement("settings.tab.ai", ui, game))
        let tab = ElysiumKeyEvent(terminal: try XCTUnwrap(ElysiumTerminalKey(rawValue: "Tab")),
                                 modifiers: [], isRepeat: false, routingSerial: 1)
        XCTAssertTrue(screen.onKeyEvent(ui, game, tab))
        XCTAssertEqual(screen.textAccessibilityDescriptors(ui, game)
            .first(where: { $0.focused })?.id, id)
        let enter = ElysiumKeyEvent(terminal: try XCTUnwrap(ElysiumTerminalKey(rawValue: "Enter")),
                                   modifiers: [], isRepeat: false, routingSerial: 2)
        XCTAssertTrue(screen.onKeyEvent(ui, game, enter))
        XCTAssertEqual(game.settings.creatureRespawnFrequency, .alternateDays)
        XCTAssertEqual(try store.loadSettings().get().creatureRespawnFrequency, .alternateDays)
        XCTAssertEqual(game.settingsRevision, initialRevision + 1)
        XCTAssertTrue(screen.performTextAccessibilityAction(id, ui, game))
        XCTAssertEqual(game.settings.creatureRespawnFrequency, .weekly)
        XCTAssertEqual(try store.loadSettings().get().creatureRespawnFrequency, .weekly)
        XCTAssertEqual(screen.textAccessibilityDescriptors(ui, game)
            .first(where: { $0.id == id })?.label, "Creature Respawn: Weekly")
        XCTAssertTrue(screen.performTextAccessibilityAction(id, ui, game))
        XCTAssertEqual(game.settings.creatureRespawnFrequency, .daily)
        XCTAssertEqual(game.settingsRevision, initialRevision + 3)
    }

    @MainActor
    func testWorldPreferenceExplainsDawnCycleRatioAndHostAuthority() throws {
        let (screen, ui, game, _) = try fixture()
        let help = try XCTUnwrap(screen.textAccessibilityDescriptors(ui, game)
            .first { $0.id == "world.creature-respawn-help" })
        XCTAssertTrue(help.value.contains("at dawn every 1, 2 or 7"))
        XCTAssertTrue(help.value.contains("in-game day/night cycles"))
        XCTAssertTrue(help.value.contains("2 herbivores per carnivore"))
        XCTAssertTrue(help.value.contains("LAN guests follow the host's frequency"))
        XCTAssertFalse(help.actionable)
    }

    @MainActor
    func testOptionsTabsAndWorldControlRemainInsideNarrowViewport() throws {
        for width in [280.0, 320, 380, 480] {
            let (screen, ui, game, _) = try fixture(width: width)
            let controls = screen.textAccessibilityDescriptors(ui, game)
                .filter { $0.id.hasPrefix("settings.tab.") || $0.id == "world.creature-respawn-frequency" }
            XCTAssertEqual(controls.count, 7)
            for control in controls {
                XCTAssertGreaterThanOrEqual(control.frame.x, 0, control.id)
                XCTAssertLessThanOrEqual(control.frame.x + control.frame.width, width, control.id)
                XCTAssertGreaterThan(control.frame.width, 0, control.id)
                XCTAssertLessThanOrEqual(Double(textWidth(control.label)), control.frame.width - 4,
                                         "\(control.id) at \(width)")
            }
        }
    }

    @MainActor
    func testFailedPersistenceDoesNotChangeFrequencyRevisionOrLabel() throws {
        let (screen, ui, game, store) = try fixture()
        try store.persistSettings(game.settings).get()
        let beforeRevision = game.settingsRevision
        store.faultInjector = { stage in
            stage == .fileSync ? InjectedLocalSettingsFailure(stage: stage) : nil
        }
        XCTAssertTrue(screen.performTextAccessibilityAction("world.creature-respawn-frequency", ui, game))
        XCTAssertEqual(game.settings.creatureRespawnFrequency, .daily)
        XCTAssertEqual(game.settingsRevision, beforeRevision)
        XCTAssertEqual(try store.loadSettings().get().creatureRespawnFrequency, .daily)
        XCTAssertEqual(screen.textAccessibilityDescriptors(ui, game)
            .first(where: { $0.id == "world.creature-respawn-frequency" })?.label,
                       "Creature Respawn: Daily")
    }

    @MainActor
    func testRecoveryDisablesMutationIncludingPreviouslyCapturedButton() throws {
        let (screen, ui, game, store) = try fixture()
        let captured = try XCTUnwrap(screen.buttons.first { $0.label.hasPrefix("Creature Respawn:") })
        store.faultInjector = { stage in
            stage == .directorySync ? InjectedLocalSettingsFailure(stage: stage) : nil
        }
        var third = game.settings
        third.fov = 99
        let thirdDocument = try store.canonicalSettingsDocument(third).get()
        store.commitAwareCanonicalRereadOverride = { .success(thirdDocument) }
        var candidate = game.settings
        candidate.creatureRespawnFrequency = .weekly
        _ = game.persistAndPublishSettingsCandidateCommitAware(
            candidate, expectedLiveRevision: game.settingsRevision)
        XCTAssertTrue(game.settingsRecoveryRequired)
        let revision = game.settingsRevision
        captured.onClick()
        XCTAssertEqual(game.settings.creatureRespawnFrequency, .daily)
        XCTAssertEqual(game.settingsRevision, revision)
        screen.rebuild(ui, game)
        let descriptor = try XCTUnwrap(screen.textAccessibilityDescriptors(ui, game)
            .first { $0.id == "world.creature-respawn-frequency" })
        XCTAssertFalse(descriptor.enabled)
        XCTAssertFalse(descriptor.actionable)
        XCTAssertFalse(screen.performTextAccessibilityAction(descriptor.id, ui, game))
        XCTAssertTrue(screen.performTextAccessibilityAction("settings.tab.video", ui, game))
    }
}
