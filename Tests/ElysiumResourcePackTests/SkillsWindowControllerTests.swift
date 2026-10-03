import AppKit
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// Window-free logic of the native Skills window: the model's selection fallback and the
/// controller's guards before a window exists, plus one present/navigate/close lifecycle.
@MainActor
final class SkillsWindowControllerTests: XCTestCase {
    private func presentation(trees ids: [SkillTreeID]? = nil) -> SkillsPresentation {
        let full = makeSkillsPresentation(
            state: SkillTreeState(),
            context: SkillsPresentationContext(quickSlot: { _ in nil }, recipeOutputItemIDs: [],
                                               itemName: { "Item \($0)" }, isLANGuest: false))
        guard let ids else { return full }
        return SkillsPresentation(trees: full.trees.filter { ids.contains($0.id) },
                                  fastBar: full.fastBar, isLANGuest: false)
    }

    // MARK: - SkillsWindowModel.selectedTree

    func testSelectedTreeFollowsSelection() {
        let model = SkillsWindowModel(presentation: presentation(), selection: .ranged) {}
        XCTAssertEqual(model.selectedTree?.id, .ranged)
        model.selection = .crafting
        XCTAssertEqual(model.selectedTree?.id, .crafting)
    }

    func testSelectedTreeFallsBackToFirstWhenSelectionIsNil() {
        let model = SkillsWindowModel(presentation: presentation(), selection: .melee) {}
        model.selection = nil
        XCTAssertEqual(model.selectedTree?.id, .mining)
    }

    func testSelectedTreeFallsBackToFirstWhenSelectionIsMissing() {
        let model = SkillsWindowModel(presentation: presentation(trees: [.ranged, .crafting]),
                                      selection: .mining) {}
        XCTAssertEqual(model.selectedTree?.id, .ranged)
    }

    func testSelectedTreeIsNilWithoutPresentationOrTrees() {
        let model = SkillsWindowModel(presentation: nil, selection: .melee) {}
        XCTAssertNil(model.selectedTree)
        model.presentation = presentation(trees: [])
        XCTAssertNil(model.selectedTree)
        model.presentation = presentation()
        XCTAssertEqual(model.selectedTree?.id, .melee, "selection survives the world finishing loading")
    }

    func testModelRequestCloseInvokesClosure() {
        var closes = 0
        let model = SkillsWindowModel(presentation: nil, selection: .mining) { closes += 1 }
        model.requestClose()
        XCTAssertEqual(closes, 1)
    }

    // MARK: - SkillsWindowController before a window exists

    func testControllerWithoutParentDoesNotPresent() {
        var closes = 0
        let controller = SkillsWindowController { closes += 1 }
        XCTAssertFalse(controller.present(presentation(), parent: nil))
        XCTAssertFalse(controller.bringToFront())
        XCTAssertFalse(controller.selectAdjacentTree(1))
        XCTAssertFalse(controller.selectAdjacentTree(-1))
        controller.update(presentation())
        controller.dismissFromScreen()
        XCTAssertEqual(closes, 0, "no window, no close request")
    }

    func testWindowCloseButtonRoutesThroughOwningScreen() {
        var closes = 0
        let controller = SkillsWindowController { closes += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        XCTAssertFalse(controller.windowShouldClose(window), "the screen, not AppKit, closes Skills")
        XCTAssertEqual(closes, 1)
    }

    // MARK: - One lifecycle with a real (offscreen-capable) parent window

    func testPresentNavigateCloseAndReopenRemembersSelection() throws {
        var closes = 0
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        defer { parent.close() }

        let controller = SkillsWindowController { closes += 1 }
        XCTAssertTrue(controller.present(presentation(), parent: parent))
        XCTAssertEqual(parent.childWindows?.count, 1)
        let skillsWindow = try XCTUnwrap(parent.childWindows?.first)
        XCTAssertEqual(skillsWindow.title, "Skills")

        // Walk to the top regardless of the remembered selection, then down to the bottom.
        for _ in 0..<SkillTreeID.allCases.count { _ = controller.selectAdjacentTree(-1) }
        XCTAssertFalse(controller.selectAdjacentTree(-1), "already at the first tree")
        XCTAssertTrue(controller.selectAdjacentTree(1))
        XCTAssertTrue(controller.selectAdjacentTree(1))
        XCTAssertTrue(controller.selectAdjacentTree(1))
        XCTAssertFalse(controller.selectAdjacentTree(1), "already at the last tree")
        XCTAssertFalse(controller.selectAdjacentTree(0))

        // A second present while open only updates; it never adds another window.
        XCTAssertTrue(controller.present(presentation(), parent: parent))
        XCTAssertEqual(parent.childWindows?.count, 1)

        // Unavailable progress keeps the window but disables navigation.
        controller.update(nil)
        XCTAssertFalse(controller.selectAdjacentTree(-1))
        controller.update(presentation())

        XCTAssertFalse(controller.windowShouldClose(skillsWindow))
        XCTAssertEqual(closes, 1)

        controller.dismissFromScreen()
        XCTAssertEqual(parent.childWindows?.count ?? 0, 0)
        XCTAssertFalse(controller.bringToFront())
        XCTAssertFalse(skillsWindow.isVisible)

        // Reopening restores the last tree (crafting, the bottom), so another step down fails.
        XCTAssertTrue(controller.present(presentation(), parent: parent))
        XCTAssertFalse(controller.selectAdjacentTree(1))
        XCTAssertTrue(controller.selectAdjacentTree(-1))
        // Leave the shared static selection at the default for any later test.
        for _ in 0..<SkillTreeID.allCases.count { _ = controller.selectAdjacentTree(-1) }
        controller.dismissFromScreen()
        XCTAssertEqual(closes, 1, "programmatic dismissal never asks the screen to close again")
    }
}
