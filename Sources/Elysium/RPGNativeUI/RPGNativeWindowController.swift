import AppKit
import SwiftUI
import ElysiumCore

/// Owns the single native character window for one in-game RPG screen.
///
/// The controller never retains gameplay state. `present` refreshes an observable model from the
/// latest committed semantic snapshot, while every action still returns through the screen's
/// receipt-bound activation boundary.
@MainActor
final class RPGNativeWindowController: NSObject, NSWindowDelegate {
    private weak var screen: RPGCharacterScreen?
    private weak var parentWindow: NSWindow?
    private var window: NSWindow?
    private var model: RPGNativeViewModel?
    private var isDismissing = false

    init(screen: RPGCharacterScreen) {
        self.screen = screen
        super.init()
    }

    @discardableResult
    func present(committed: RPGCommittedSemanticSnapshot,
                 runtime: RPGScreenRuntimeSnapshot,
                 creation: RPGCreationSession,
                 tab: RPGCharacterTab,
                 parent: NSWindow?) -> Bool {
        guard let screen, let parent else { return false }

        if let model, let window {
            model.refresh(committed: committed, runtime: runtime,
                          creation: creation, tab: tab)
            window.title = runtime.state.created ? "Character" : "Create Character"
            if !window.isVisible { window.makeKeyAndOrderFront(nil) }
            return true
        }

        let model = RPGNativeViewModel(screen: screen, committed: committed,
                                       runtime: runtime, creation: creation, tab: tab)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = runtime.state.created ? "Character" : "Create Character"
        // This is a content constraint, not a frame constraint: the title bar must not consume
        // part of the workspace's promised layout height. The width also leaves the outer
        // navigation sidebar and Loadout split view enough room to honor their inner minima.
        window.contentMinSize = NSSize(width: 980, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        window.contentView = NSHostingView(rootView: RPGNativeCharacterView(model: model))
        _ = window.setFrameAutosaveName("ElysiumRPGCharacterWindow")

        self.model = model
        self.window = window
        parentWindow = parent
        parent.addChildWindow(window, ordered: .above)
        if !window.setFrameUsingName("ElysiumRPGCharacterWindow") {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isDismissing else { return true }
        model?.requestClose()
        return false
    }

    func dismissFromScreen() {
        guard let window else { return }
        isDismissing = true
        if let parentWindow { parentWindow.removeChildWindow(window) }
        window.delegate = nil
        window.orderOut(nil)
        window.close()
        self.window = nil
        model = nil
        parentWindow = nil
        isDismissing = false
    }
}
