import AppKit
import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class NativeScriptEditorToolbarTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        if entityTypes().isEmpty { registerAllEntities() }
    }

    func testNativeToolbarKeepsEveryPrimaryControlVisibleAndNonLayerBacked() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: ScriptEditorAICompletionMode.defaultsKey)
        defaults.set(ScriptEditorAICompletionMode.manual.rawValue,
                     forKey: ScriptEditorAICompletionMode.defaultsKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: ScriptEditorAICompletionMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: ScriptEditorAICompletionMode.defaultsKey)
            }
        }

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-native-toolbar-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(
            name: "Native Toolbar Test",
            seedText: "4242",
            mode: GameMode.creative,
            difficulty: 2
        )
        let model = ScriptEditorModel(target: .player, game: game)
        let toolbar = NativeScriptEditorToolbarView(theme: .defaultDark)
        toolbar.frame = NSRect(x: 0, y: 0, width: 879, height: 82)
        toolbar.update(model: model, theme: .defaultDark, aiPanelOpen: false)
        toolbar.layoutSubtreeIfNeeded()

        XCTAssertFalse(toolbar.wantsLayer)
        XCTAssertNil(toolbar.layer)

        let simulatedSwiftUIHost = NSView(frame: toolbar.frame)
        simulatedSwiftUIHost.wantsLayer = true
        simulatedSwiftUIHost.addSubview(toolbar)
        toolbar.promotePlatformHostAboveSiblingSurfaces()
        XCTAssertEqual(simulatedSwiftUIHost.layer?.zPosition, 1)

        for identifier in [
            "scriptEditor.scriptName",
            "scriptEditor.targetStatus",
            "scriptEditor.mode",
            "scriptEditor.aiMode",
            "scriptEditor.requestAI",
            "scriptEditor.check",
            "scriptEditor.run",
            "scriptEditor.save",
            "scriptEditor.toggleAIPanel",
        ] {
            let control = try XCTUnwrap(
                allSubviews(of: toolbar).first { $0.accessibilityIdentifier() == identifier },
                "missing native toolbar control \(identifier)"
            )
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor, "\(identifier) must be visible")
            XCTAssertGreaterThan(control.frame.width, 0, "\(identifier) needs visible width")
            XCTAssertGreaterThan(control.frame.height, 0, "\(identifier) needs visible height")
        }

        model.mode = .handler
        toolbar.update(model: model, theme: .defaultDark, aiPanelOpen: true)
        toolbar.layoutSubtreeIfNeeded()
        let eventField = try XCTUnwrap(
            allSubviews(of: toolbar).first {
                $0.accessibilityIdentifier() == "scriptEditor.handlerEvent"
            }
        )
        let eventMenu = try XCTUnwrap(
            allSubviews(of: toolbar).first {
                $0.accessibilityIdentifier() == "scriptEditor.handlerEventMenu"
            }
        )
        XCTAssertFalse(eventField.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(eventMenu.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(eventField.frame.width, 0)
        XCTAssertGreaterThan(eventMenu.frame.width, 0)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}
