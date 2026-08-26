// LuaEditorTextView.swift — the native text surface's command bridge. Keeping command routing in
// the first responder lets both keyboard events and ordinary AppKit menu items invoke the same
// editor actions without coupling the window controller to SwiftUI state.

import AppKit

final class LuaEditorTextView: NSTextView {
    var onEditorKeyDown: ((NSEvent) -> Bool)?
    var onRequestAISuggestion: (() -> Void)?
    private var requestedInitialFocus = false

    override func keyDown(with event: NSEvent) {
        if onEditorKeyDown?(event) == true { return }
        super.keyDown(with: event)
    }

    @objc func requestAISuggestion(_ sender: Any?) {
        _ = sender
        onRequestAISuggestion?()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(requestAISuggestion(_:)) {
            return onRequestAISuggestion != nil
        }
        return super.validateUserInterfaceItem(item)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !requestedInitialFocus else { return }
        requestedInitialFocus = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
