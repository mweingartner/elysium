import AppKit
import SwiftUI
import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class LuaCodeTextViewCompletionLifecycleTests: XCTestCase {
    func testSelectedAIExternalEditIsOneNativeUndoTransaction() throws {
        let original = "local old = 1\nsay(old)"
        let bindingState = LuaEditorBindingState()
        bindingState.text = original
        let replacedRange = (original as NSString).range(of: "local old = 1")
        bindingState.selection = replacedRange
        let representable = LuaCodeTextView(
            text: Binding(
                get: { bindingState.text },
                set: { bindingState.text = $0 }
            ),
            selectedRange: Binding(
                get: { bindingState.selection },
                set: { bindingState.selection = $0 }
            ),
            errorLine: nil,
            targetKind: .player,
            theme: .defaultDark
        )
        let coordinator = representable.makeCoordinator()
        let editorContainer = try XCTUnwrap(
            representable.makeEditorView(coordinator: coordinator) as? LuaEditorContainerView
        )
        let editor = try XCTUnwrap(coordinator.textView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = editorContainer
        defer {
            LuaCodeTextView.dismantleNSView(editorContainer, coordinator: coordinator)
            window.close()
        }

        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let replacement = "local generated = 2"
        let expected = (original as NSString).replacingCharacters(
            in: replacedRange,
            with: replacement
        )
        let edit = LuaEditorExternalEdit(
            id: 1,
            replacementRange: replacedRange,
            replacementText: replacement
        )

        XCTAssertTrue(coordinator.applyExternalEdit(edit, expectedText: expected, in: editor))
        XCTAssertEqual(editor.string, expected)
        XCTAssertEqual(bindingState.text, expected)
        let undoManager = try XCTUnwrap(editor.undoManager)
        XCTAssertTrue(undoManager.canUndo)

        undoManager.undo()
        XCTAssertEqual(editor.string, original)
        XCTAssertEqual(bindingState.text, original)
        XCTAssertFalse(
            undoManager.canUndo,
            "one Cmd-Z must revert the complete selected AI replacement"
        )
        XCTAssertTrue(undoManager.canRedo)
    }

    func testProductionCoordinatorDismissesAndTearsDownCompletionLifecycle() async throws {
        let application = NSApplication.shared
        let bindingState = LuaEditorBindingState()
        let representable = LuaCodeTextView(
            text: Binding(
                get: { bindingState.text },
                set: { bindingState.text = $0 }
            ),
            selectedRange: Binding(
                get: { bindingState.selection },
                set: { bindingState.selection = $0 }
            ),
            errorLine: nil,
            targetKind: .player,
            theme: .defaultDark
        )
        let coordinator = representable.makeCoordinator()
        let editorContainer = try XCTUnwrap(
            representable.makeEditorView(coordinator: coordinator) as? LuaEditorContainerView
        )
        let editor = try XCTUnwrap(coordinator.textView)

        let clickProbe = LuaEditorClickProbe()
        let outsideButton = NSButton(
            title: "Outside editor",
            target: clickProbe,
            action: #selector(LuaEditorClickProbe.clicked(_:))
        )
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 340))
        editorContainer.frame = NSRect(x: 0, y: 42, width: 620, height: 298)
        editorContainer.autoresizingMask = [.width, .height]
        outsideButton.frame = NSRect(x: 12, y: 8, width: 128, height: 26)
        outsideButton.autoresizingMask = [.maxXMargin, .maxYMargin]
        contentView.addSubview(editorContainer)
        contentView.addSubview(outsideButton)

        let editorWindow = NSWindow(
            contentRect: contentView.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        editorWindow.isReleasedWhenClosed = false
        editorWindow.contentView = contentView

        var didDismantle = false
        defer {
            if !didDismantle {
                LuaCodeTextView.dismantleNSView(editorContainer, coordinator: coordinator)
            }
            editorWindow.close()
        }

        editorWindow.makeKeyAndOrderFront(nil)
        editorContainer.layoutSubtreeIfNeeded()
        XCTAssertTrue(editorWindow.makeFirstResponder(editor))
        await nextMainActorTurn()
        await nextMainActorTurn()

        // Ordinary typing enters through LuaEditorTextView and the installed production
        // coordinator. A non-empty keyword prefix must create the real child panel and both of
        // its dismissal hooks without changing first-responder ownership.
        application.sendEvent(try keyEvent(code: 37, characters: "l"))
        await nextMainActorTurn()
        let completionPanel = try XCTUnwrap(currentCompletionPanel(of: editorWindow))
        XCTAssertEqual(editor.string, "l")
        XCTAssertEqual(bindingState.text, "l")
        XCTAssertTrue(completionPanel.isVisible)
        XCTAssertTrue(coordinator.hasActiveCompletionLifecycleHooks)
        XCTAssertTrue(editorWindow.firstResponder === editor)

        // The outside-click monitor must dismiss and still return the event for normal AppKit
        // delivery. This verifies both outcomes with an actual button action, not a direct call
        // to the coordinator's private dismissal routine.
        try click(outsideButton, in: editorWindow, application: application)
        await nextMainActorTurn()
        XCTAssertEqual(clickProbe.count, 1)
        XCTAssertFalse(completionPanel.isVisible)
        XCTAssertNil(completionPanel.parent)
        XCTAssertFalse(coordinator.hasActiveCompletionLifecycleHooks)

        // Typing remains normal after outside-click dismissal and reuses the same nonactivating
        // panel rather than accumulating windows, observers, or event monitors.
        XCTAssertTrue(editorWindow.makeFirstResponder(editor))
        application.sendEvent(try keyEvent(code: 31, characters: "o"))
        await nextMainActorTurn()
        XCTAssertEqual(editor.string, "lo")
        XCTAssertEqual(bindingState.text, "lo")
        XCTAssertTrue(currentCompletionPanel(of: editorWindow) === completionPanel)
        XCTAssertTrue(completionPanel.isVisible)
        XCTAssertTrue(coordinator.hasActiveCompletionLifecycleHooks)

        // Delivering the exact AppKit notification emitted when the parent loses key status
        // exercises the observer installed by this presentation without depending on whether the
        // xctest host process itself is currently the frontmost macOS application.
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: editorWindow
        )
        await nextMainActorTurn()
        await nextMainActorTurn()
        XCTAssertFalse(completionPanel.isVisible)
        XCTAssertNil(completionPanel.parent)
        XCTAssertFalse(coordinator.hasActiveCompletionLifecycleHooks)

        // A third presentation proves show/dismiss remains repeatable before the representable's
        // real dismantle witness is invoked.
        editorWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(editorWindow.makeFirstResponder(editor))
        application.sendEvent(try keyEvent(
            code: 49,
            characters: " ",
            modifiers: .control
        ))
        await nextMainActorTurn()
        XCTAssertTrue(currentCompletionPanel(of: editorWindow) === completionPanel)
        XCTAssertTrue(completionPanel.isVisible)
        XCTAssertTrue(coordinator.hasActiveCompletionLifecycleHooks)

        LuaCodeTextView.dismantleNSView(editorContainer, coordinator: coordinator)
        didDismantle = true
        XCTAssertFalse(completionPanel.isVisible)
        XCTAssertNil(completionPanel.parent)
        XCTAssertFalse(coordinator.hasActiveCompletionLifecycleHooks)
        XCTAssertNil(editor.delegate)
        XCTAssertNil(editor.onEditorKeyDown)
        XCTAssertNil(editor.onRequestAISuggestion)

        // Retain the native subtree deliberately: if dismantling left the coordinator delegate or
        // local monitor installed, either this keystroke would resurrect a panel or this click
        // would be intercepted. Both must behave like ordinary AppKit input after teardown.
        XCTAssertTrue(editorWindow.makeFirstResponder(editor))
        application.sendEvent(try keyEvent(code: 7, characters: "x"))
        try click(outsideButton, in: editorWindow, application: application)
        await nextMainActorTurn()
        XCTAssertEqual(editor.string, "lox")
        XCTAssertEqual(clickProbe.count, 2)
        XCTAssertNil(currentCompletionPanel(of: editorWindow))
        XCTAssertFalse(coordinator.hasActiveCompletionLifecycleHooks)
    }

    private func currentCompletionPanel(of window: NSWindow) -> LuaCompletionPanel? {
        window.childWindows?.compactMap { $0 as? LuaCompletionPanel }.first
    }

    private func keyEvent(
        code: UInt16,
        characters: String,
        modifiers: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
    }

    private func click(
        _ button: NSButton,
        in window: NSWindow,
        application: NSApplication
    ) throws {
        let location = NSPoint(x: button.frame.midX, y: button.frame.midY)
        let events: [(NSEvent.EventType, Int, Float)] = [
            (.leftMouseDown, 1, 1),
            (.leftMouseUp, 2, 0),
        ]
        for (type, eventNumber, pressure) in events {
            application.sendEvent(try XCTUnwrap(NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: 1,
                pressure: pressure
            )))
        }
    }

    private func nextMainActorTurn() async {
        await Task.yield()
    }
}

@MainActor
private final class LuaEditorBindingState {
    var text = ""
    var selection = NSRange(location: 0, length: 0)
}

@MainActor
private final class LuaEditorClickProbe: NSObject {
    private(set) var count = 0

    @objc func clicked(_ sender: Any?) {
        _ = sender
        count += 1
    }
}
