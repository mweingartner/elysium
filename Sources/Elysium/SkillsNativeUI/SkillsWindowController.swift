import AppKit
import SwiftUI
import Atrium
import ElysiumCore

/// Owns the single native Skills window for one in-game `SkillTreeScreen`.
///
/// The controller holds presentation values only. Closing the window (Done, Esc, or the close
/// button) never dismisses it directly: it asks the owning screen, which closes through
/// `UIManager` so the screen stack, pause state and controller context stay authoritative.
@MainActor
final class SkillsWindowController: NSObject, NSWindowDelegate {
    /// The tree shown when Skills next opens, so it reopens where the player left it.
    private static var lastSelection: SkillTreeID = .mining
    private static let frameName = "ElysiumSkillsWindow"

    private let requestClose: () -> Void
    private weak var parentWindow: NSWindow?
    private var window: NSWindow?
    private var model: SkillsWindowModel?
    private var isDismissing = false

    init(requestClose: @escaping () -> Void) {
        self.requestClose = requestClose
        super.init()
    }

    @discardableResult
    func present(_ presentation: SkillsPresentation?, parent: NSWindow?) -> Bool {
        if let window {
            update(presentation)
            if !window.isVisible {
                // Ordering a child window out can detach it; reattach before showing it again.
                if window.parent == nil, let host = parent ?? parentWindow {
                    host.addChildWindow(window, ordered: .above)
                    parentWindow = host
                }
                window.makeKeyAndOrderFront(nil)
            }
            return true
        }
        guard let parent else { return false }

        let model = SkillsWindowModel(presentation: presentation, selection: Self.lastSelection) {
            [weak self] in self?.requestClose()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 648),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Skills"
        window.contentMinSize = Metrics.mainWindow
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.toolbarStyle = .unified
        window.contentView = NSHostingView(rootView: SkillsWindowView(model: model))
        _ = window.setFrameAutosaveName(Self.frameName)

        self.model = model
        self.window = window
        parentWindow = parent
        parent.addChildWindow(window, ordered: .above)
        if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Replaces the shown values; a no-op when nothing changed so SwiftUI does not re-render.
    func update(_ presentation: SkillsPresentation?) {
        guard let model, model.presentation != presentation else { return }
        model.presentation = presentation
    }

    /// Moves the sidebar selection one tree up (`-1`) or down (`+1`), for controller and
    /// arrow-key navigation routed through the game screen.
    func selectAdjacentTree(_ delta: Int) -> Bool {
        guard let model, let trees = model.presentation?.trees, !trees.isEmpty else { return false }
        let current = model.selection.flatMap { id in trees.firstIndex { $0.id == id } } ?? 0
        let next = min(max(0, current + delta), trees.count - 1)
        guard next != current else { return false }
        model.selection = trees[next].id
        return true
    }

    /// Hides the window while another screen sits above Skills, handing focus back to the game
    /// window. `present` shows it again when Skills is revealed.
    func stepAside() {
        guard let window else { return }
        window.orderOut(nil)
        parentWindow?.makeKeyAndOrderFront(nil)
    }

    func bringToFront() -> Bool {
        guard let window else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isDismissing else { return true }
        requestClose()
        return false
    }

    func dismissFromScreen() {
        guard let window else { return }
        isDismissing = true
        if let selection = model?.selection { Self.lastSelection = selection }
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
