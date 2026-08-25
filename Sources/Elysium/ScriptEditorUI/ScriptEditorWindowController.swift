// ScriptEditorWindowController.swift — native SwiftUI script editor (Stage A). The NSWindow host,
// owned lazily by `AppDelegate` (`RealityDerivedCoordinator`'s ownership precedent,
// `RealityDerivedM.swift`) and patterned after Hype's `openScriptEditorWindow`
// (`PropertyInspector.swift:5559`): a detached `NSWindow` + `NSHostingView`, `isReleasedWhenClosed
// = false`, dedup by target so a second open for the same object brings the existing window
// forward instead of stacking duplicates, and window-size restore via `UserDefaults`.
//
// Unlike Hype's game-less editor, opening this window sits over a running Metal game view — so it
// also owns the two side effects that come with "a native window took over interaction while the
// game view still exists underneath": releasing pointer capture (`gameView.releaseMouse()`, the
// process-global mouse-capture precedent every other screen-open in `main.swift` already follows)
// and setting `GameCore.scriptEditorWindowOpen` so `screenPausesGame()` pauses simulation while
// any editor window is open, clearing it (and recapturing the pointer, if nothing else is
// showing) only once every editor window for this session has closed.

import AppKit
import SwiftUI
import ElysiumCore

/// `@MainActor` because it constructs `ScriptEditorModel` (itself `@MainActor` — see that file's
/// own comment) and drives AppKit window lifecycle, all of which already only ever happens on the
/// main thread; callers outside a `@MainActor` context reach `open(...)` via `elysiumMainActorSync`.
@MainActor
final class ScriptEditorWindowController: NSObject, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?
    private var windows: [String: NSWindow] = [:]
    private var models: [String: ScriptEditorModel] = [:]
    private var resizeObservers: [String: NSObjectProtocol] = [:]

    init(owner: AppDelegate) {
        self.appDelegate = owner
    }

    /// Opens (or focuses an existing) editor window for `target`. `existingName`, when given,
    /// selects that script immediately (Inspector's "Edit Script", `/script edit <target> <name>`);
    /// `nil` opens on a fresh, unnamed script (Cmd-E with no existing script chosen).
    func open(target: ObjectRef, existingName: String?, game: GameCore) {
        let key = target.canonical
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            if let existingName, let model = models[key] {
                model.switchTo(existingName)
            }
            return
        }

        let model = ScriptEditorModel(target: target, game: game, existingName: existingName)

        // Default sized so all three columns (script list + palette | editor | AI chat) and the
        // full editor toolbar (name, mode picker, Check/Run/Save, AI toggle) render without the
        // trailing controls compressing — min width holds the same floor.
        let savedWidth = UserDefaults.standard.double(forKey: "elysiumScriptEditorWindowWidth")
        let savedHeight = UserDefaults.standard.double(forKey: "elysiumScriptEditorWindowHeight")
        let width = savedWidth >= 900 ? savedWidth : 1180
        let height = savedHeight >= 520 ? savedHeight : 740

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.minSize = NSSize(width: 900, height: 520)
        window.title = "\(model.targetDisplayName) — Script Editor"
        window.isReleasedWhenClosed = false
        window.delegate = self
        // NOTE: do NOT force `hosting.wantsLayer = true`. Layer-backing the whole NSHostingView
        // makes the embedded AppKit NSTextView (LuaCodeTextView) implicitly layer-backed too, which
        // breaks TextKit glyph compositing — the code accepted input but drew no visible text. The
        // toolbar-overlap that layer-backing was meant to cure is instead fixed by the code view's
        // scroll view using `translatesAutoresizingMaskIntoConstraints = false` (see LuaCodeTextView).
        let hosting = NSHostingView(rootView: ScriptEditorView(model: model))
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)

        windows[key] = window
        models[key] = model

        appDelegate?.gameView.releaseMouse()
        game.scriptEditorWindowOpen = true

        resizeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                UserDefaults.standard.set(window.frame.width, forKey: "elysiumScriptEditorWindowWidth")
                UserDefaults.standard.set(window.frame.height, forKey: "elysiumScriptEditorWindowHeight")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let key = windows.first(where: { $0.value === window })?.key
        else { return }
        windows.removeValue(forKey: key)
        models.removeValue(forKey: key)
        if let observer = resizeObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
        guard windows.isEmpty, let appDelegate else { return }
        appDelegate.game.scriptEditorWindowOpen = false
        // Recapture the pointer only if the game is actually the thing on screen — a normal UI
        // screen (inventory, chat, …) opened while the editor was up owns capture-on-close itself
        // (every existing screen-close call site already does `game.host?.capturePointer()`), so
        // recapturing here too would fight it.
        if appDelegate.game.hasWorld(), appDelegate.ui?.hasScreen() != true {
            appDelegate.gameView.captureMouse()
        }
    }
}
