import Foundation
import Metal
import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class WorldCreateVillageDensityUITests: XCTestCase {
    private struct Fixture {
        let game: GameCore
    }

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllEntities()
    }

    private func makeFixture() throws -> Fixture {
        // Keep both persistence destinations isolated: an actual Create click
        // enters GameCore and writes its new WorldRecord immediately.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("elysium-create-village-ui-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let settingsDirectory = root.appendingPathComponent("settings", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: false)
        let database = try SaveDB.open(databaseURL: root.appendingPathComponent("worlds.sqlite"),
                                       migrateLegacy: false)
        return Fixture(game: GameCore(db: database,
                                     localSettingsStore: LocalSettingsStore(directoryURL: settingsDirectory)))
    }

    private func makeUI(width: Double, height: Double) throws -> UIManager {
        let canvas = UICanvas(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let ui = UIManager(cv: canvas)
        ui.resize(width, height, 1)
        return ui
    }

    private func button(_ prefix: String, on screen: WorldCreateScreen) throws -> Button {
        try XCTUnwrap(screen.buttons.first { $0.label.hasPrefix(prefix) },
                      "expected one visible control beginning with \(prefix)")
    }

    private func tap(_ button: Button, screen: WorldCreateScreen, ui: UIManager, game: GameCore,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(screen.onMouseDown(ui, game, button.x + 1, button.y + 1, 0),
                      "pointer activation must reach \(button.label)", file: file, line: line)
    }

    /// Select by the actual screen state rather than assuming a fixed number
    /// of entries in the evolving world-type cycle. The bound makes a broken
    /// selector fail rather than looping forever.
    private func selectWorldPreset(_ target: WorldPreset, on screen: WorldCreateScreen,
                                   ui: UIManager, game: GameCore,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let worldType = try button("World Type:", on: screen)
        for _ in 0...WorldPreset.extendedCycle.count {
            if !screen.realityDerived, screen.worldPreset == target { return }
            tap(worldType, screen: screen, ui: ui, game: game, file: file, line: line)
        }
        if !screen.realityDerived, screen.worldPreset == target { return }
        XCTFail("World Type selector did not reach \(target.displayName)", file: file, line: line)
    }

    private func selectRealityDerived(on screen: WorldCreateScreen, ui: UIManager, game: GameCore,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let worldType = try button("World Type:", on: screen)
        for _ in 0...WorldPreset.extendedCycle.count {
            if screen.realityDerived { return }
            tap(worldType, screen: screen, ui: ui, game: game, file: file, line: line)
        }
        if screen.realityDerived { return }
        XCTFail("World Type selector did not reach Reality Derived", file: file, line: line)
    }

    private func selectDungeonDensity(_ target: DungeonDensity, on screen: WorldCreateScreen,
                                      ui: UIManager, game: GameCore,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let dungeon = try button("Dungeons:", on: screen)
        for _ in 0..<DungeonDensity.allCases.count {
            if screen.dungeonDensity == target { return }
            tap(dungeon, screen: screen, ui: ui, game: game, file: file, line: line)
        }
        if screen.dungeonDensity == target { return }
        XCTFail("Dungeon selector did not reach \(target.displayName)", file: file, line: line)
    }

    private func selectVillageDensity(_ target: VillageDensity, on screen: WorldCreateScreen,
                                      ui: UIManager, game: GameCore,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let village = try button("Villages:", on: screen)
        for _ in 0..<VillageDensity.allCases.count {
            if screen.villageDensity == target { return }
            tap(village, screen: screen, ui: ui, game: game, file: file, line: line)
        }
        if screen.villageDensity == target { return }
        XCTFail("Village selector did not reach \(target.displayName)", file: file, line: line)
    }

    func testVillageSelectorIsVisibleAndUsableAcrossCompactAndStandardLayouts() throws {
        let fixture = try makeFixture()
        let ui = try makeUI(width: 480, height: 240)
        let screen = WorldCreateScreen()
        ui.open(screen, fixture.game)

        var village = try button("Villages:", on: screen)
        var dungeon = try button("Dungeons:", on: screen)
        var create = try button("Create World", on: screen)
        XCTAssertTrue(village.visible)
        XCTAssertEqual(village.label, "Villages: Normal")
        XCTAssertEqual(village.y - dungeon.y, 20, accuracy: 0.001,
                       "compact selectors must not overlap")
        XCTAssertLessThanOrEqual(dungeon.y + dungeon.h, village.y,
                                 "Village must own its entire compact hit target")
        XCTAssertGreaterThanOrEqual(create.y, village.y + 22)
        XCTAssertLessThanOrEqual(create.y + create.h, ui.height,
                                 "compact Create must remain on-screen below Villages")

        // Exercise the real pointer route, not the closure directly. Starting
        // from Normal, the full requested five-choice cycle is observable.
        for expected in ["Villages: Many", "Villages: Max", "Villages: None",
                         "Villages: Few", "Villages: Normal"] {
            tap(village, screen: screen, ui: ui, game: fixture.game)
            XCTAssertEqual(village.label, expected)
        }
        XCTAssertEqual(screen.villageDensity, .normal)

        // Single Biome inserts its own row. Both procedural controls must move
        // together while staying above Create at the minimum supported height.
        try selectWorldPreset(.singleBiomeSurface, on: screen, ui: ui, game: fixture.game)
        var worldType = try button("World Type:", on: screen)
        XCTAssertEqual(worldType.label, "World Type: Single Biome")
        village = try button("Villages:", on: screen)
        dungeon = try button("Dungeons:", on: screen)
        create = try button("Create World", on: screen)
        XCTAssertTrue(village.visible)
        XCTAssertEqual(village.y - dungeon.y, 20, accuracy: 0.001)
        XCTAssertLessThanOrEqual(dungeon.y + dungeon.h, village.y)
        XCTAssertGreaterThanOrEqual(create.y, village.y + 22)
        XCTAssertLessThanOrEqual(create.y + create.h, ui.height)

        // Resize uses Screen.relayoutScreen, so it must retain the selector's
        // state and lay out the same control safely in the standard stack.
        ui.resize(480, 360, 1, relayout: fixture.game)
        worldType = try button("World Type:", on: screen)
        village = try button("Villages:", on: screen)
        dungeon = try button("Dungeons:", on: screen)
        create = try button("Create World", on: screen)
        XCTAssertTrue(village.visible)
        XCTAssertEqual(village.label, "Villages: Normal")
        XCTAssertEqual(village.y - dungeon.y, 24, accuracy: 0.001,
                       "standard selectors must use standard spacing")
        XCTAssertGreaterThanOrEqual(create.y, village.y + 22)
        XCTAssertLessThanOrEqual(create.y + create.h, ui.height)

        // Reality Derived worlds do not use procedural map generation; hiding
        // the selector here confirms it is not a stale hit target.
        try selectRealityDerived(on: screen, ui: ui, game: fixture.game)
        worldType = try button("World Type:", on: screen)
        XCTAssertEqual(worldType.label, "World Type: Reality Derived")
        XCTAssertFalse(try button("Villages:", on: screen).visible)
        XCTAssertFalse(try button("Dungeons:", on: screen).visible)
    }

    func testVillageSelectionFlowsThroughCreateWorldAndPersists() throws {
        let fixture = try makeFixture()
        let ui = try makeUI(width: 480, height: 240)
        let screen = WorldCreateScreen()
        ui.open(screen, fixture.game)

        let village = try button("Villages:", on: screen)
        tap(village, screen: screen, ui: ui, game: fixture.game) // Normal → Many
        tap(village, screen: screen, ui: ui, game: fixture.game) // Many → Max
        XCTAssertEqual(village.label, "Villages: Max")
        XCTAssertEqual(screen.villageDensity, .max)

        let create = try button("Create World", on: screen)
        tap(create, screen: screen, ui: ui, game: fixture.game)
        let record = try XCTUnwrap(fixture.game.worldRec)
        XCTAssertEqual(record.generationSettings.villageDensity, .max,
                       "Create World must forward the UI selection to GameCore")
        XCTAssertEqual(fixture.game.db.getWorld(record.id)?.generationSettings.villageDensity, .max,
                       "the created WorldRecord must persist the selected village density")
    }

    func testVillageSelectorIsKeyboardAndAccessibilityReachable() throws {
        let fixture = try makeFixture()
        let ui = try makeUI(width: 480, height: 240)
        let screen = WorldCreateScreen()
        ui.open(screen, fixture.game)

        let village = try button("Villages:", on: screen)
        let descriptor = try XCTUnwrap(screen.textAccessibilityDescriptors(ui, fixture.game)
            .first { $0.id == "create.villages" })
        XCTAssertEqual(descriptor.role, .button)
        XCTAssertEqual(descriptor.label, "Villages: Normal")
        XCTAssertEqual(descriptor.frame.x, village.x, accuracy: 0.001)
        XCTAssertEqual(descriptor.frame.y, village.y, accuracy: 0.001)
        XCTAssertTrue(descriptor.enabled)
        XCTAssertTrue(descriptor.focusable)
        XCTAssertTrue(descriptor.actionable)
        XCTAssertTrue(screen.focusTextAccessibilityElement("create.villages", ui, fixture.game))
        XCTAssertTrue(screen.performTextAccessibilityAction("create.villages", ui, fixture.game))
        XCTAssertEqual(screen.villageDensity, .many)
        XCTAssertEqual(screen.textAccessibilityDescriptors(ui, fixture.game)
            .first { $0.id == "create.villages" }?.label, "Villages: Many")

        let tab = ElysiumKeyEvent(
            terminal: try XCTUnwrap(ElysiumTerminalKey(rawValue: "Tab")),
            modifiers: [], isRepeat: false, routingSerial: 1)
        XCTAssertTrue(screen.onKeyEvent(ui, fixture.game, tab))
        XCTAssertEqual(screen.textAccessibilityDescriptors(ui, fixture.game)
            .first(where: { $0.focused })?.id, "create.confirm")
    }

    func testFlatHidesAndCanonicalizesOnlyTheUnsupportedDungeonSelector() throws {
        let fixture = try makeFixture()
        let ui = try makeUI(width: 480, height: 240)
        let screen = WorldCreateScreen()
        ui.open(screen, fixture.game)

        let dungeon = try button("Dungeons:", on: screen)
        let village = try button("Villages:", on: screen)
        tap(dungeon, screen: screen, ui: ui, game: fixture.game) // Normal → More
        tap(village, screen: screen, ui: ui, game: fixture.game) // Normal → Many
        let worldType = try button("World Type:", on: screen)
        tap(worldType, screen: screen, ui: ui, game: fixture.game) // Default → Superflat

        XCTAssertEqual(screen.worldPreset, .flat)
        XCTAssertEqual(screen.dungeonDensity, .normal)
        XCTAssertEqual(screen.villageDensity, .many)
        XCTAssertFalse(dungeon.visible)
        XCTAssertTrue(village.visible)
        XCTAssertNil(screen.textAccessibilityDescriptors(ui, fixture.game)
            .first { $0.id == "create.dungeons" })
        XCTAssertFalse(screen.performTextAccessibilityAction("create.dungeons", ui, fixture.game))
        XCTAssertEqual(screen.textAccessibilityDescriptors(ui, fixture.game)
            .first { $0.id == "create.villages" }?.label, "Villages: Many")
    }

    func testDebugModeHidesAndResetsProceduralDensitySelectors() throws {
        let fixture = try makeFixture()
        let ui = try makeUI(width: 480, height: 240)
        let screen = WorldCreateScreen()
        ui.open(screen, fixture.game)

        let dungeon = try button("Dungeons:", on: screen)
        let village = try button("Villages:", on: screen)
        tap(dungeon, screen: screen, ui: ui, game: fixture.game) // Normal → More
        tap(village, screen: screen, ui: ui, game: fixture.game) // Normal → Many
        XCTAssertEqual(screen.dungeonDensity, .more)
        XCTAssertEqual(screen.villageDensity, .many)

        // Debug Mode is an extended-only preset. Exercise the real selector
        // route so the test verifies both its transition and its hidden hit
        // targets rather than mutating the screen's fields directly.
        ui.optionDown = true
        try selectWorldPreset(.debugAllBlockStates, on: screen, ui: ui, game: fixture.game)
        let worldType = try button("World Type:", on: screen)
        XCTAssertEqual(worldType.label, "World Type: Debug Mode")
        XCTAssertEqual(screen.dungeonDensity, .normal)
        XCTAssertEqual(screen.villageDensity, .normal)
        XCTAssertFalse(dungeon.visible)
        XCTAssertFalse(village.visible)
        XCTAssertFalse(dungeon.contains(dungeon.x + 1, dungeon.y + 1),
                       "a hidden density selector must not retain a pointer hit target")
        XCTAssertFalse(village.contains(village.x + 1, village.y + 1),
                       "a hidden density selector must not retain a pointer hit target")
        XCTAssertNil(screen.textAccessibilityDescriptors(ui, fixture.game)
            .first { $0.id == "create.dungeons" },
                     "a hidden dungeon selector must retire its AX Press element")
        XCTAssertNil(screen.textAccessibilityDescriptors(ui, fixture.game)
            .first { $0.id == "create.villages" },
                     "a hidden village selector must retire its AX Press element")
        XCTAssertFalse(screen.performTextAccessibilityAction("create.dungeons", ui, fixture.game))
        XCTAssertFalse(screen.performTextAccessibilityAction("create.villages", ui, fixture.game))
    }

    func testEachPrehistoricProfileHidesAndCanonicalizesVillagesWhileKeepingDungeons() throws {
        let fixture = try makeFixture()
        let ui = try makeUI(width: 480, height: 240)
        let screen = WorldCreateScreen()
        ui.open(screen, fixture.game)

        let prehistoricPresets: [WorldPreset] = [
            .prehistoricLostWorldV3,
            .prehistoricJurassicGiantsV3,
            .prehistoricCretaceousFrontiersV3,
            .prehistoricAncientSeasV3,
        ]
        XCTAssertEqual(WorldPreset.normalCycle.filter { $0.isPrehistoric }, prehistoricPresets,
                       "adding a profile must extend this UI contract test")

        // Reaching Lost World from Default legitimately crosses Superflat,
        // which historically canonicalizes dungeons. Verify that transition
        // explicitly, then exercise the contiguous prehistoric segment: none
        // of those profiles may clear a supported dungeon selection.
        try selectDungeonDensity(.more, on: screen, ui: ui, game: fixture.game)
        try selectVillageDensity(.many, on: screen, ui: ui, game: fixture.game)
        try selectWorldPreset(.prehistoricLostWorldV3, on: screen, ui: ui, game: fixture.game)
        XCTAssertEqual(screen.dungeonDensity, .normal,
                       "the route through Superflat must preserve its historical dungeon canonicalization")
        XCTAssertEqual(screen.villageDensity, .normal,
                       "Lost World must clear an inapplicable village selection")

        try selectDungeonDensity(.more, on: screen, ui: ui, game: fixture.game)
        for preset in prehistoricPresets {
            try selectWorldPreset(preset, on: screen, ui: ui, game: fixture.game)

            let dungeon = try button("Dungeons:", on: screen)
            let village = try button("Villages:", on: screen)
            XCTAssertEqual(screen.worldPreset, preset)
            XCTAssertFalse(screen.realityDerived)
            XCTAssertEqual(screen.dungeonDensity, .more, "\(preset.displayName) must retain dungeons")
            XCTAssertEqual(screen.villageDensity, .normal,
                           "\(preset.displayName) must clear an inapplicable village selection")
            XCTAssertTrue(dungeon.visible, "\(preset.displayName) must keep the dungeon selector")
            XCTAssertFalse(village.visible, "\(preset.displayName) must hide the village selector")
            XCTAssertEqual(dungeon.label, "Dungeons: More")
            XCTAssertEqual(village.label, "Villages: Normal")
            XCTAssertNotNil(screen.textAccessibilityDescriptors(ui, fixture.game)
                .first { $0.id == "create.dungeons" })
            XCTAssertNil(screen.textAccessibilityDescriptors(ui, fixture.game)
                .first { $0.id == "create.villages" })
        }
    }

    func testPrehistoricCreateSelectionPersistsTheCurrentVolcanicRevision() throws {
        let fixture = try makeFixture()
        let ui = try makeUI(width: 480, height: 240)
        let screen = WorldCreateScreen()
        ui.open(screen, fixture.game)
        screen.seedField.text = "5366106"

        try selectWorldPreset(.prehistoricLostWorldV3, on: screen, ui: ui, game: fixture.game)
        XCTAssertEqual(try button("World Type:", on: screen).label, "World Type: Lost World")
        try selectDungeonDensity(.more, on: screen, ui: ui, game: fixture.game)
        tap(try button("Create World", on: screen), screen: screen, ui: ui, game: fixture.game)

        let record = try XCTUnwrap(fixture.game.worldRec)
        XCTAssertEqual(record.worldPreset, WorldPreset.prehistoricLostWorldV3.rawValue)
        XCTAssertEqual(record.generationSettings.preset.prehistoricProfile, .lostWorld)
        XCTAssertTrue(record.generationSettings.preset.prehistoricProfile?.supportsVolcanicTerrain == true)
        let saved = try XCTUnwrap(fixture.game.db.getWorld(record.id))
        XCTAssertEqual(saved.worldPreset, WorldPreset.prehistoricLostWorldV3.rawValue)
        XCTAssertEqual(saved.generationSettings.dungeonDensity, .more)
        XCTAssertEqual(saved.generationSettings.villageDensity, .normal)
    }
}
