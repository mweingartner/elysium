import AppKit
import XCTest
@testable import Elysium

@MainActor
final class LuaCompletionPanelTests: XCTestCase {
    func testDocumentationPaneHasReadableContentAndGeometry() throws {
        let controller = CompletionViewController()
        controller.suggestions = [LuaCompletionItem(
            label: "player",
            insertionText: "player",
            kind: .variable,
            detail: "ElysiumObject",
            documentation: "The local player's handle.",
            source: .elysium,
            isReadOnly: true,
            sortPriority: 0
        )]
        controller.view.layoutSubtreeIfNeeded()

        let documentationView = try XCTUnwrap(
            allSubviews(of: controller.view).compactMap { $0 as? NSTextView }.first
        )
        XCTAssertFalse(documentationView.isEditable)
        XCTAssertFalse(documentationView.isSelectable)
        XCTAssertGreaterThan(documentationView.frame.width, 0)
        XCTAssertGreaterThan(documentationView.frame.height, 0)
        XCTAssertEqual(
            documentationView.string,
            "player\nElysiumObject • read only\n\nThe local player's handle."
        )
        XCTAssertNotNil(documentationView.textStorage?.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ))
    }

    func testVisibleCompletionPanelNeverTakesEditorKeyRouting() async throws {
        let application = NSApplication.shared
        let editor = LuaEditorTextView(
            frame: NSRect(x: 0, y: 0, width: 480, height: 180)
        )
        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.string = ""

        var handledSpecialKeys: [UInt16] = []
        editor.onEditorKeyDown = { event in
            guard [UInt16(125), 126, 36, 53].contains(event.keyCode) else { return false }
            handledSpecialKeys.append(event.keyCode)
            return true
        }

        let editorWindow = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 480, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        editorWindow.isReleasedWhenClosed = false
        editorWindow.contentView = editor
        editorWindow.makeKeyAndOrderFront(nil)
        XCTAssertTrue(editorWindow.makeFirstResponder(editor))

        let panel = LuaCompletionPanel(contentViewController: CompletionViewController())
        panel.setContentSize(NSSize(width: 320, height: 140))
        panel.present(
            relativeTo: NSRect(x: 12, y: 12, width: 2, height: 16),
            of: editor
        )

        defer {
            if editorWindow.childWindows?.contains(where: { $0 === panel }) == true {
                editorWindow.removeChildWindow(panel)
            }
            editor.onEditorKeyDown = nil
            panel.close()
            editorWindow.close()
            XCTAssertFalse(panel.isVisible)
            XCTAssertFalse(panel.isKeyWindow)
            XCTAssertFalse(editorWindow.isVisible)
            XCTAssertFalse(editorWindow.isKeyWindow)
        }

        // Flush already-enqueued AppKit presentation and focus work without a timed wait.
        await nextMainQueueTurn()
        await nextMainQueueTurn()

        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertFalse(application.keyWindow === panel)
        XCTAssertTrue(editorWindow.firstResponder === editor)

        // A zero window number makes NSApplication select the keyboard target. Pinning these
        // events to the editor window (or calling editor.keyDown directly) would mask the focus
        // regression this test protects against.
        application.sendEvent(try keyEvent(code: 0, characters: "s"))
        await nextMainQueueTurn()
        application.sendEvent(try keyEvent(code: 14, characters: "e"))
        XCTAssertEqual(editor.string, "se")
        XCTAssertTrue(panel.isVisible)
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(editorWindow.firstResponder === editor)

        for (code, characters) in [
            (UInt16(125), ""),
            (UInt16(126), ""),
            (UInt16(36), "\r"),
            (UInt16(53), "\u{1b}"),
        ] {
            application.sendEvent(try keyEvent(code: code, characters: characters))
        }
        XCTAssertEqual(handledSpecialKeys, [125, 126, 36, 53])
        XCTAssertEqual(editor.string, "se", "Handled commands must not leak into source")
        XCTAssertFalse(panel.isKeyWindow)
        XCTAssertTrue(editorWindow.firstResponder === editor)

        panel.dismiss()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.parent)
        XCTAssertTrue(editorWindow.firstResponder === editor)

        // Reusing the same flyout must not accumulate child-window state or disturb typing after
        // teardown; production keeps one panel per editor coordinator for exactly this lifecycle.
        panel.present(
            relativeTo: NSRect(x: 18, y: 12, width: 2, height: 16),
            of: editor
        )
        XCTAssertTrue(panel.isVisible)
        XCTAssertTrue(panel.parent === editorWindow)
        panel.dismiss()
        XCTAssertFalse(panel.isVisible)
        XCTAssertNil(panel.parent)
        application.sendEvent(try keyEvent(code: 7, characters: "x"))
        XCTAssertEqual(editor.string, "sex")
        XCTAssertTrue(editorWindow.firstResponder === editor)
    }

    private func keyEvent(code: UInt16, characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: code
        ))
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews(of:))
    }
}
