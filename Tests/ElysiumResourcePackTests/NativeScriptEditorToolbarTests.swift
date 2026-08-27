import AppKit
import SwiftUI
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
        var capturedActivation: ScriptEditorScriptingActivationAction?
        let bridge = NativeScriptEditorToolbar(
            model: model,
            theme: .defaultDark,
            aiPanelOpen: false,
            onSave: {},
            onToggleAI: {},
            onRequestScriptingActivation: { capturedActivation = $0 }
        )
        let coordinator = bridge.makeCoordinator()
        let toolbar = NativeScriptEditorToolbarView(theme: .defaultDark)
        toolbar.connect(to: coordinator)
        defer { toolbar.disconnect() }
        coordinator.toolbarView = toolbar
        toolbar.frame = NSRect(x: 0, y: 0, width: 879, height: 140)
        toolbar.update(model: model, theme: .defaultDark, aiPanelOpen: false)
        toolbar.layoutSubtreeIfNeeded()

        XCTAssertFalse(toolbar.wantsLayer)
        XCTAssertNil(toolbar.layer)
        XCTAssertGreaterThan(toolbar.intrinsicContentSize.height, 110)

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
            "scriptEditor.scriptingAvailability",
        ] {
            let control = try XCTUnwrap(
                allSubviews(of: toolbar).first { $0.accessibilityIdentifier() == identifier },
                "missing native toolbar control \(identifier)"
            )
            XCTAssertFalse(control.isHiddenOrHasHiddenAncestor, "\(identifier) must be visible")
            XCTAssertGreaterThan(control.frame.width, 0, "\(identifier) needs visible width")
            XCTAssertGreaterThan(control.frame.height, 0, "\(identifier) needs visible height")
        }
        let runOnceButton = try XCTUnwrap(
            allSubviews(of: toolbar).first {
                $0.accessibilityIdentifier() == "scriptEditor.run"
            } as? NSButton
        )
        XCTAssertEqual(runOnceButton.title, "Run Once")
        XCTAssertEqual(
            runOnceButton.toolTip,
            "Execute the visible draft against the live world once; live changes may persist, but the draft is not saved or attached, world trust is unchanged, and attached scripts are not loaded"
        )
        XCTAssertEqual(runOnceButton.accessibilityHelp(), runOnceButton.toolTip)

        let activeBanner = try XCTUnwrap(
            allSubviews(of: toolbar).first {
                $0.accessibilityIdentifier() == "scriptEditor.scriptingAvailability"
            }
        )
        XCTAssertFalse(activeBanner.wantsLayer)
        XCTAssertEqual(
            activeBanner.accessibilityLabel(),
            "Script execution status: \(model.scriptingAvailability.title). \(model.scriptingAvailability.detail)"
        )
        XCTAssertEqual(activeBanner.accessibilityHelp(), model.scriptingAvailability.detail)

        let activationButton = try XCTUnwrap(
            allSubviews(of: toolbar).first {
                $0.accessibilityIdentifier() == "scriptEditor.scriptingActivation"
            } as? NSButton
        )
        XCTAssertTrue(activationButton.isHidden)

        guard var record = game.worldRec else { return XCTFail("missing world record") }
        record.scriptsEnabled = false
        game.worldRec = record
        model.refreshScriptingAvailability()
        toolbar.update(model: model, theme: .defaultDark, aiPanelOpen: false)
        toolbar.layoutSubtreeIfNeeded()

        XCTAssertEqual(model.scriptingAvailability, .trustRequired)
        XCTAssertEqual(toolbar.presentedScriptingActivationAction, .trustWorld)
        XCTAssertEqual(
            activeBanner.accessibilityLabel(),
            "Script execution status: Attached scripts are paused — trust required. Save, Check, and Run Once remain available, but attached execution is paused until you explicitly trust this world."
        )
        XCTAssertFalse(activationButton.isHidden)
        XCTAssertTrue(activationButton.isEnabled)
        XCTAssertFalse(activationButton.isHiddenOrHasHiddenAncestor)
        XCTAssertGreaterThan(activationButton.frame.width, 0)
        XCTAssertGreaterThan(activationButton.frame.height, 0)
        XCTAssertEqual(activationButton.title, "Trust World")
        XCTAssertEqual(activationButton.accessibilityLabel(), "Trust World")
        XCTAssertEqual(
            activationButton.accessibilityHelp(),
            "Shows a warning before changing world-wide script execution settings"
        )
        XCTAssertTrue(
            (activeBanner.accessibilityChildren() ?? []).contains {
                ($0 as? NSButton) === activationButton
            }
        )

        activationButton.performClick(nil)

        XCTAssertEqual(capturedActivation, .trustWorld)
        XCTAssertFalse(game.worldRec?.scriptsEnabled ?? true, "the native button only opens confirmation")

        model.mode = .handler
        toolbar.update(model: model, theme: .defaultDark, aiPanelOpen: true)
        let handlerRunButton = try XCTUnwrap(
            allSubviews(of: toolbar).first {
                $0.accessibilityIdentifier() == "scriptEditor.run"
            } as? NSButton
        )
        XCTAssertFalse(handlerRunButton.isEnabled)
        XCTAssertEqual(
            handlerRunButton.accessibilityHelp(),
            ScriptEditorAuthoringContract.handlerRunOnceUnavailable
        )
        let invalidHandlerAIButton = try XCTUnwrap(
            allSubviews(of: toolbar).first {
                $0.accessibilityIdentifier() == "scriptEditor.requestAI"
            } as? NSButton
        )
        XCTAssertFalse(invalidHandlerAIButton.isEnabled)
        XCTAssertTrue(invalidHandlerAIButton.accessibilityHelp()?.contains("Choose or enter") == true)
        let narrowVisibleIdentifiers = [
            "scriptEditor.scriptName",
            "scriptEditor.mode",
            "scriptEditor.handlerEvent",
            "scriptEditor.handlerEventMenu",
            "scriptEditor.aiMode",
            "scriptEditor.requestAI",
            "scriptEditor.check",
            "scriptEditor.run",
            "scriptEditor.save",
            "scriptEditor.toggleAIPanel",
            "scriptEditor.scriptingAvailability",
            "scriptEditor.scriptingActivation",
        ]
        for width: CGFloat in [380, 485] {
            let proposedSize = toolbar.representableSize(proposedWidth: width)
            XCTAssertEqual(proposedSize.width, width)
            XCTAssertEqual(proposedSize.height, toolbar.intrinsicContentSize.height)
            toolbar.frame = NSRect(
                x: 0,
                y: 0,
                width: proposedSize.width,
                height: proposedSize.height
            )
            toolbar.layoutSubtreeIfNeeded()

            for identifier in narrowVisibleIdentifiers {
                let control = try XCTUnwrap(
                    allSubviews(of: toolbar).first {
                        $0.accessibilityIdentifier() == identifier
                    },
                    "missing narrow-toolbar control \(identifier)"
                )
                XCTAssertFalse(control.isHiddenOrHasHiddenAncestor, "\(identifier) hidden at \(width)")
                let controlRect = control.convert(control.bounds, to: toolbar)
                XCTAssertGreaterThanOrEqual(controlRect.minX, -0.5, "\(identifier) starts outside \(width)")
                XCTAssertLessThanOrEqual(
                    controlRect.maxX,
                    toolbar.bounds.maxX + 0.5,
                    "\(identifier) ends outside \(width): \(controlRect)"
                )
                XCTAssertGreaterThan(controlRect.width, 0, "\(identifier) has no width at \(width)")
                XCTAssertGreaterThan(controlRect.height, 0, "\(identifier) has no height at \(width)")
            }

            let detailField = try XCTUnwrap(
                allSubviews(of: toolbar).first {
                    ($0 as? NSTextField)?.stringValue == model.scriptingAvailability.detail
                } as? NSTextField
            )
            let detailRect = detailField.convert(detailField.bounds, to: toolbar)
            XCTAssertLessThan(
                detailField.frame.width,
                detailField.intrinsicContentSize.width,
                "availability detail should compress at \(width), not widen the toolbar"
            )
            XCTAssertLessThanOrEqual(detailRect.maxX, toolbar.bounds.maxX + 0.5)
        }
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

    func testSwiftUIBridgeConstrainsNativeToolbarToTheActualPaneWidth() throws {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: ScriptEditorAICompletionMode.defaultsKey)
        defaults.set(
            ScriptEditorAICompletionMode.manual.rawValue,
            forKey: ScriptEditorAICompletionMode.defaultsKey
        )
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: ScriptEditorAICompletionMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: ScriptEditorAICompletionMode.defaultsKey)
            }
        }

        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-hosted-toolbar-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(
            name: "Hosted Toolbar Test",
            seedText: "8181",
            mode: GameMode.creative,
            difficulty: 2
        )
        guard var record = game.worldRec else { return XCTFail("missing world record") }
        record.scriptsEnabled = false
        game.worldRec = record
        let model = ScriptEditorModel(target: .player, game: game)
        model.mode = .handler

        let identifiers = [
            "scriptEditor.scriptName",
            "scriptEditor.mode",
            "scriptEditor.handlerEvent",
            "scriptEditor.handlerEventMenu",
            "scriptEditor.aiMode",
            "scriptEditor.requestAI",
            "scriptEditor.check",
            "scriptEditor.run",
            "scriptEditor.save",
            "scriptEditor.toggleAIPanel",
            "scriptEditor.scriptingAvailability",
            "scriptEditor.scriptingActivation",
        ]

        for paneWidth: CGFloat in [380, 485] {
            let root = NativeScriptEditorToolbar(
                model: model,
                theme: .defaultDark,
                aiPanelOpen: true,
                onSave: {},
                onToggleAI: {},
                onRequestScriptingActivation: { _ in }
            )
            .frame(maxWidth: .infinity)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(x: 0, y: 0, width: paneWidth, height: 160)
            hosting.layoutSubtreeIfNeeded()

            let toolbar = try XCTUnwrap(
                allSubviews(of: hosting).first { $0 is NativeScriptEditorToolbarView }
                    as? NativeScriptEditorToolbarView,
                "SwiftUI did not materialize the native toolbar at width \(paneWidth)"
            )
            let toolbarRect = toolbar.convert(toolbar.bounds, to: hosting)
            XCTAssertEqual(toolbarRect.minX, 0, accuracy: 0.5)
            XCTAssertEqual(toolbarRect.width, paneWidth, accuracy: 0.5)
            XCTAssertLessThanOrEqual(toolbarRect.maxX, hosting.bounds.maxX + 0.5)

            for identifier in identifiers {
                let control = try XCTUnwrap(
                    allSubviews(of: toolbar).first {
                        $0.accessibilityIdentifier() == identifier
                    },
                    "missing hosted control \(identifier) at width \(paneWidth)"
                )
                XCTAssertFalse(
                    control.isHiddenOrHasHiddenAncestor,
                    "hosted control \(identifier) hidden at width \(paneWidth)"
                )
                let controlRect = control.convert(control.bounds, to: hosting)
                XCTAssertGreaterThanOrEqual(
                    controlRect.minX,
                    toolbarRect.minX - 0.5,
                    "hosted control \(identifier) starts outside its toolbar at \(paneWidth)"
                )
                XCTAssertLessThanOrEqual(
                    controlRect.maxX,
                    toolbarRect.maxX + 0.5,
                    "hosted control \(identifier) ends outside its toolbar at \(paneWidth)"
                )
            }
        }
    }

    func testToolbarActionEnablementTracksKillSwitchAndMissingRuntime() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-toolbar-actions-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(
            name: "Toolbar Action State Test",
            seedText: "9191",
            mode: GameMode.creative,
            difficulty: 2
        )
        let model = ScriptEditorModel(target: .player, game: game)
        let toolbar = NativeScriptEditorToolbarView(theme: .defaultDark)
        toolbar.update(model: model, theme: .defaultDark, aiPanelOpen: false)

        func button(_ identifier: String) throws -> NSButton {
            try XCTUnwrap(
                allSubviews(of: toolbar).first {
                    $0.accessibilityIdentifier() == identifier
                } as? NSButton,
                "missing toolbar button \(identifier)"
            )
        }

        let checkButton = try button("scriptEditor.check")
        let runOnceButton = try button("scriptEditor.run")
        let saveButton = try button("scriptEditor.save")

        game.setGameRule("doScripts", 0)
        model.refreshScriptingAvailability()
        toolbar.update(model: model, theme: .defaultDark, aiPanelOpen: false)

        XCTAssertEqual(model.scriptingAvailability, .killSwitchOff)
        XCTAssertTrue(checkButton.isEnabled)
        XCTAssertFalse(runOnceButton.isEnabled)
        XCTAssertTrue(saveButton.isEnabled)

        game.scripting.scriptRuntime = nil
        model.refreshScriptingAvailability()
        toolbar.update(model: model, theme: .defaultDark, aiPanelOpen: false)

        XCTAssertEqual(model.scriptingAvailability, .runtimeUnavailable(.missingRuntime))
        XCTAssertFalse(checkButton.isEnabled)
        XCTAssertFalse(runOnceButton.isEnabled)
        XCTAssertFalse(saveButton.isEnabled)
    }

    func testHandlerEventPickerIsTargetFilteredDeclaredAndAccessible() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-toolbar-events-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(
            name: "Toolbar Event Picker Test",
            seedText: "6161",
            mode: GameMode.creative,
            difficulty: 2
        )
        let context = game.scriptingCommandContext()
        guard case .success = CustomEventStore(graph: context.graph).declare(
            .player,
            name: "player.quest_ready",
            fields: [
                CustomEventField(name: "quest", type: .string),
                CustomEventField(name: "reward", type: .integer, isNullable: true),
            ],
            summary: "A quest reward is ready."
        ) else {
            return XCTFail("expected custom event declaration to succeed")
        }

        let model = ScriptEditorModel(target: .player, game: game)
        model.mode = .handler
        let bridge = NativeScriptEditorToolbar(
            model: model,
            theme: .defaultDark,
            aiPanelOpen: false,
            onSave: {},
            onToggleAI: {},
            onRequestScriptingActivation: { _ in }
        )
        let coordinator = bridge.makeCoordinator()
        let toolbar = NativeScriptEditorToolbarView(theme: .defaultDark)
        toolbar.connect(to: coordinator)
        defer { toolbar.disconnect() }
        coordinator.toolbarView = toolbar
        toolbar.update(model: model, theme: .defaultDark, aiPanelOpen: false)

        let modeControl = try XCTUnwrap(
            allSubviews(of: toolbar).first {
                $0.accessibilityIdentifier() == "scriptEditor.mode"
            } as? NSSegmentedControl
        )
        XCTAssertEqual(modeControl.accessibilityValue() as? String, "Handler")
        XCTAssertTrue(modeControl.accessibilityHelp()?.contains("implicit ev") == true)

        let eventField = try XCTUnwrap(
            allSubviews(of: toolbar).first {
                $0.accessibilityIdentifier() == "scriptEditor.handlerEvent"
            } as? NSTextField
        )
        XCTAssertTrue(eventField.accessibilityHelp()?.contains("Required for Handler mode") == true)

        let eventMenu = try XCTUnwrap(
            allSubviews(of: toolbar).first {
                $0.accessibilityIdentifier() == "scriptEditor.handlerEventMenu"
            } as? NSPopUpButton
        )
        XCTAssertEqual(eventMenu.accessibilityLabel(), "Choose a handler event for Player")
        XCTAssertTrue(eventMenu.accessibilityHelp()?.contains("only events compatible") == true)
        let titles = eventMenu.itemTitles
        XCTAssertTrue(titles.contains("Compatible Built-in Events"))
        XCTAssertTrue(titles.contains("entity.damaged"))
        XCTAssertFalse(titles.contains("block.used"))
        XCTAssertTrue(titles.contains("Declared on player"))

        let customItem = try XCTUnwrap(eventMenu.itemArray.first {
            $0.title == "player.quest_ready"
        })
        XCTAssertTrue(customItem.toolTip?.contains("quest: string") == true)
        XCTAssertTrue(customItem.toolTip?.contains("reward: integer?") == true)
        XCTAssertEqual(customItem.representedObject as? String, "player.quest_ready")

        coordinator.eventSelected(customItem)
        toolbar.update(model: model, theme: .defaultDark, aiPanelOpen: false)
        XCTAssertEqual(model.handlerEvent, "player.quest_ready")
        XCTAssertEqual(eventField.stringValue, "player.quest_ready")
        XCTAssertTrue(eventField.accessibilityHelp()?.contains("Declared custom event") == true)
        XCTAssertTrue(eventField.accessibilityHelp()?.contains("A quest reward is ready") == true)
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}
