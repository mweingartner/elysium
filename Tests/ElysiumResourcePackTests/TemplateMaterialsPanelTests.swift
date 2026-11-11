import Foundation
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// The cost of the selected template in the place-template browser (`TemplateMaterialsPanel`).
/// The panel draws from a quote it reads once for each selection, so its states can be checked
/// without a canvas: what it says, whether Place is allowed, what M and the page keys do, and
/// what VoiceOver is told.
final class TemplateMaterialsPanelTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    @MainActor
    private func makeGame(mode: Int = GameMode.survival) throws -> GameCore {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ElysiumTemplateMaterialsPanel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        roots.append(root)
        let game = GameCore(db: try SaveDB.open(databaseURL: root.appendingPathComponent("worlds.sqlite"),
                                                migrateLegacy: false),
                            localSettingsStore: LocalSettingsStore(directoryURL: root.appendingPathComponent("settings")))
        game.createWorld(name: "Panel", seedText: "panel", mode: mode, difficulty: 0)
        for index in game.player.inventory.indices { game.player.inventory[index] = nil }
        return game
    }

    private func object(_ name: String, _ blocks: [(String, Int)]) -> ObjectTemplate {
        var cells: [TemplateBlock] = []
        var dx = 0
        for (block, count) in blocks {
            for _ in 0..<count {
                cells.append(TemplateBlock(dx: dx % 16, dy: dx / 16, dz: 0, cell: cell(bid(block), 0)))
                dx += 1
            }
        }
        return ObjectTemplate(name: name, anchorX: 0, anchorY: 0, anchorZ: 0,
                              sizeX: 16, sizeY: max(1, (dx + 15) / 16), sizeZ: 1, blocks: cells)
    }

    private let frame = (x: 150.0, y: 30.0, w: 190.0, h: 150.0)

    @MainActor
    func testAnAffordableObjectSaysSoAndOffersTheList() throws {
        let game = try makeGame()
        game.player.inventory[0] = stack("oak_planks", 10)
        game.player.inventory[1] = stack("glass", 4)
        let panel = TemplateMaterialsPanel()
        panel.update(name: "House", template: object("House", [("oak_planks", 6), ("glass", 2)]), game: game)
        panel.layout(x: 10, y: 20)

        XCTAssertTrue(panel.canPlace)
        XCTAssertTrue(panel.toggle.visible)
        XCTAssertEqual(panel.toggle.label, "Materials")
        XCTAssertFalse(panel.showsList)
        let cost = try XCTUnwrap(panel.accessibilityDescriptors(frame: frame).first)
        XCTAssertEqual(cost.id, "templates.cost")
        XCTAssertEqual(cost.label, "Costs 8 materials. You have them all.")
        XCTAssertEqual(panel.accessibilityDescriptors(frame: frame).count, 1, "the list is not shown yet")
    }

    @MainActor
    func testMShowsTheListWithMissingMaterialsFirstAndMAgainHidesIt() throws {
        let game = try makeGame()
        game.player.inventory[0] = stack("oak_planks", 10)
        let panel = TemplateMaterialsPanel()
        panel.update(name: "House", template: object("House", [("oak_planks", 6), ("glass", 5), ("torch", 2)]), game: game)

        XCTAssertTrue(panel.onKey("KeyM"))
        XCTAssertTrue(panel.showsList)
        panel.layout(x: 10, y: 20)
        XCTAssertEqual(panel.toggle.label, "Preview")
        let descriptors = panel.accessibilityDescriptors(frame: frame)
        XCTAssertEqual(descriptors.map(\.id).prefix(2), ["templates.cost", "templates.materials"])
        XCTAssertEqual(descriptors[0].label, "Costs 13 materials. Still missing 5 Glass and 2 Torch.")
        let rows = descriptors.dropFirst(2)
        XCTAssertEqual(rows.map(\.label), ["Glass", "Torch", "Oak Planks"], "missing first, then the most needed")
        XCTAssertEqual(rows.map(\.value), ["Needs 5, you have 0, missing 5", "Needs 2, you have 0, missing 2",
                                           "Needs 6, you have 10"])
        XCTAssertTrue(rows.allSatisfy { $0.parentID == "templates.materials" && $0.role == .listItem })
        XCTAssertTrue(panel.canPlace, "missing materials do not disable Place: the player may fetch them")

        XCTAssertTrue(panel.onKey("KeyM"))
        XCTAssertFalse(panel.showsList)
        XCTAssertFalse(panel.onKey("PageDown"), "the page keys belong to the list")
    }

    @MainActor
    func testAnObjectSurvivalCannotPlaceDisablesPlaceAndNamesTheBlock() throws {
        let game = try makeGame()
        let panel = TemplateMaterialsPanel()
        panel.update(name: "Pond", template: object("Pond", [("oak_planks", 1), ("water", 1)]), game: game)
        panel.layout(x: 10, y: 20)
        XCTAssertFalse(panel.canPlace)
        XCTAssertFalse(panel.toggle.visible, "there is no list to show")
        XCTAssertFalse(panel.onKey("KeyM"))
        XCTAssertEqual(panel.accessibilityDescriptors(frame: frame).first?.label,
                       "Survival can't place Water. Switch to Creative to place this object.")
    }

    @MainActor
    func testCreativeIsFreeAndHasNoList() throws {
        let game = try makeGame(mode: GameMode.creative)
        let panel = TemplateMaterialsPanel()
        panel.update(name: "Pond", template: object("Pond", [("oak_planks", 1), ("water", 1)]), game: game)
        panel.layout(x: 10, y: 20)
        XCTAssertTrue(panel.canPlace)
        XCTAssertFalse(panel.toggle.visible)
        XCTAssertEqual(panel.accessibilityDescriptors(frame: frame).first?.label, "Free in Creative.")
    }

    @MainActor
    func testNoSelectionShowsNothingAndANewSelectionIsReadAgain() throws {
        let game = try makeGame()
        let panel = TemplateMaterialsPanel()
        panel.update(name: nil, template: nil, game: game)
        panel.layout(x: 10, y: 20)
        XCTAssertTrue(panel.canPlace)
        XCTAssertFalse(panel.toggle.visible)
        XCTAssertEqual(panel.accessibilityDescriptors(frame: frame).count, 0)

        panel.update(name: "A", template: object("A", [("oak_planks", 3)]), game: game)
        XCTAssertTrue(panel.onKey("KeyM"))
        XCTAssertEqual(panel.accessibilityDescriptors(frame: frame).first?.label,
                       "Costs 3 materials. Still missing 3 Oak Planks.")
        // The same selection is not read again while the browser is open ...
        game.player.inventory[0] = stack("oak_planks", 3)
        panel.update(name: "A", template: object("A", [("oak_planks", 3)]), game: game)
        XCTAssertEqual(panel.accessibilityDescriptors(frame: frame).first?.label,
                       "Costs 3 materials. Still missing 3 Oak Planks.")
        // ... a different one is, and a template that has not loaded clears the panel.
        panel.update(name: "B", template: object("B", [("oak_planks", 2)]), game: game)
        XCTAssertEqual(panel.accessibilityDescriptors(frame: frame).first?.label,
                       "Costs 2 materials. You have them all.")
        panel.update(name: "C", template: nil, game: game)
        XCTAssertFalse(panel.showsList)
        XCTAssertEqual(panel.accessibilityDescriptors(frame: frame).count, 0)
    }

    @MainActor
    func testThePageKeysScrollALongListAndStopAtItsEnds() throws {
        let game = try makeGame()
        let kinds = ["oak_planks", "glass", "torch", "stone", "dirt", "cobblestone", "bricks", "oak_log",
                     "sand", "gravel", "oak_slab", "oak_stairs", "ladder", "bookshelf"]
        let panel = TemplateMaterialsPanel()
        panel.update(name: "Many", template: object("Many", kinds.map { ($0, 1) }), game: game)
        XCTAssertTrue(panel.onKey("KeyM"))
        XCTAssertTrue(panel.onKey("PageUp"))
        XCTAssertTrue(panel.onKey("PageDown"))
        for _ in 0..<40 { XCTAssertTrue(panel.onKey("PageDown")) }
        let rows = panel.accessibilityDescriptors(frame: frame).dropFirst(2)
        XCTAssertEqual(rows.count, kinds.count, "every material is reachable for VoiceOver, scrolled or not")
        for row in rows {
            XCTAssertGreaterThanOrEqual(row.frame.y, frame.y)
            XCTAssertLessThanOrEqual(row.frame.y + row.frame.height, frame.y + frame.h + 1)
        }
    }
}
