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
import Combine
import SwiftUI
import ElysiumCore

enum ScriptEditorUnsavedChangesDecision: Equatable {
    case save
    case cancel
    case discard
}

enum ScriptEditorOverwriteDecision: Equatable {
    case replace
    case cancel
}

/// Injectable modal boundary for destructive editor navigation. Production uses the same AppKit
/// alerts as before; tests supply deterministic decisions while exercising the controller's real
/// save, collision, close, and application-termination paths.
@MainActor
struct ScriptEditorConfirmationPresenter {
    let unsavedChangesDecision: (ScriptEditorModel, String) -> ScriptEditorUnsavedChangesDecision
    let overwriteDecision: (ScriptEditorSaveCollision, String) -> ScriptEditorOverwriteDecision

    static func appKit() -> ScriptEditorConfirmationPresenter {
        ScriptEditorConfirmationPresenter(
            unsavedChangesDecision: { model, action in
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Save changes before you \(action)?"
                if !model.isWorldSessionActive {
                    alert.informativeText = "This world session has ended. The draft cannot be saved back into another world; copy its source before discarding it."
                } else if model.isLANGuest, !model.isNewScript {
                    alert.informativeText = "The host does not reveal the existing source. Saving sends a complete replacement to the host."
                } else {
                    alert.informativeText = "Unsaved Lua source will be lost if you continue without saving."
                }
                alert.addButton(withTitle: "Save")
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Discard Changes")
                switch alert.runModal() {
                case .alertFirstButtonReturn: return .save
                case .alertThirdButtonReturn: return .discard
                default: return .cancel
                }
            },
            overwriteDecision: { collision, name in
                let alert = NSAlert()
                alert.alertStyle = .critical
                alert.messageText = "Replace existing script \"\(name)\"?"
                alert.informativeText = collision.description
                alert.addButton(withTitle: "Replace Script")
                alert.addButton(withTitle: "Cancel")
                return alert.runModal() == .alertFirstButtonReturn ? .replace : .cancel
            }
        )
    }
}

/// `@MainActor` because it constructs `ScriptEditorModel` (itself `@MainActor` — see that file's
/// own comment) and drives AppKit window lifecycle, all of which already only ever happens on the
/// main thread; callers outside a `@MainActor` context reach `open(...)` via `elysiumMainActorSync`.
@MainActor
final class ScriptEditorWindowController: NSObject, NSWindowDelegate {
    private weak var appDelegate: AppDelegate?
    private var windows: [String: NSWindow] = [:]
    private var models: [String: ScriptEditorModel] = [:]
    private var resizeObservers: [String: NSObjectProtocol] = [:]
    private var dirtyObservers: [String: AnyCancellable] = [:]
    private var worldSessionObserver: NSObjectProtocol?
    private let confirmations: ScriptEditorConfirmationPresenter

    init(
        owner: AppDelegate,
        confirmations: ScriptEditorConfirmationPresenter? = nil
    ) {
        self.appDelegate = owner
        self.confirmations = confirmations ?? .appKit()
        super.init()
        worldSessionObserver = NotificationCenter.default.addObserver(
            forName: .elysiumWorldSessionWillEnd, object: owner.game, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let owner = self.appDelegate else { return }
                owner.game.scriptEditorWindowOpen = false
                for (key, model) in self.models where model.game === owner.game {
                    self.windows[key]?.title = "Disconnected Draft — \(model.targetDisplayName)"
                }
            }
        }
    }

    deinit {
        if let worldSessionObserver { NotificationCenter.default.removeObserver(worldSessionObserver) }
    }

    private func key(for target: ObjectRef, game: GameCore) -> String {
        "\(game.worldSessionGeneration)|\(target.canonical)"
    }

    /// Opens (or focuses an existing) editor window for `target`. `existingName`, when given,
    /// selects that script immediately (Inspector's "Edit Script", `/script edit <target> <name>`);
    /// `nil` opens on a fresh, unnamed script (Cmd-E with no existing script chosen).
    func open(target: ObjectRef, existingName: String?, game: GameCore) {
        let key = key(for: target, game: game)
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            if let existingName, let model = models[key] {
                guard !model.isDirty || resolveUnsavedChanges(for: model, action: "switch scripts") else { return }
                model.switchTo(existingName)
            }
            return
        }

        let model = ScriptEditorModel(target: target, game: game, existingName: existingName)
        model.beginAIReadiness()

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
        // NOTE: do NOT force `hosting.wantsLayer = true`, and keep LuaEditorContainerView
        // non-layer-backed as well. Layer-backing either mixed SwiftUI/TextKit boundary breaks
        // compositing: glyphs or sibling AppKit toolbar controls can remain live but draw behind
        // SwiftUI's graphics surface.
        let hosting = NSHostingView(rootView: ScriptEditorView(model: model))
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)

        windows[key] = window
        models[key] = model
        dirtyObservers[key] = model.objectWillChange.sink { [weak window, weak model] _ in
            DispatchQueue.main.async {
                window?.isDocumentEdited = model?.isDirty ?? false
            }
        }

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
        models[key]?.cancelAIWork(clearSuggestion: true)
        models[key]?.endAIReadiness()
        windows.removeValue(forKey: key)
        models.removeValue(forKey: key)
        dirtyObservers.removeValue(forKey: key)
        if let observer = resizeObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
        guard let appDelegate else { return }
        appDelegate.game.scriptEditorWindowOpen = models.values.contains {
            $0.game === appDelegate.game && $0.isWorldSessionActive
        }
        // Recapture the pointer only if the game is actually the thing on screen — a normal UI
        // screen (inventory, chat, …) opened while the editor was up owns capture-on-close itself
        // (every existing screen-close call site already does `game.host?.capturePointer()`), so
        // recapturing here too would fight it.
        if windows.isEmpty, appDelegate.game.hasWorld(), appDelegate.ui?.hasScreen() != true {
            appDelegate.gameView.captureMouse()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let key = windows.first(where: { $0.value === sender })?.key,
              let model = models[key]
        else { return true }
        return shouldCloseEditor(model)
    }

    /// Testable decision kernel used by the window delegate. Keeping the dirty check here proves a
    /// clean document never asks for confirmation while every dirty close uses the save boundary.
    func shouldCloseEditor(_ model: ScriptEditorModel) -> Bool {
        guard model.isDirty else { return true }
        return resolveUnsavedChanges(for: model, action: "close the editor")
    }

    /// Cmd-Q and last-window termination must honor the same per-document Save/Discard/Cancel
    /// boundary as an ordinary editor-window close.
    func shouldTerminateApplication() -> Bool {
        let editors = models.keys.sorted().compactMap { key -> (window: NSWindow?, model: ScriptEditorModel)? in
            guard let model = models[key] else { return nil }
            return (windows[key], model)
        }
        return shouldTerminateApplication(editors: editors)
    }

    /// Ordered editor input keeps application-termination behavior directly testable without
    /// opening modal windows. Production supplies its stable target-key order above.
    func shouldTerminateApplication(
        editors: [(window: NSWindow?, model: ScriptEditorModel)]
    ) -> Bool {
        for editor in editors where editor.model.isDirty {
            editor.window?.makeKeyAndOrderFront(nil)
            let model = editor.model
            guard resolveUnsavedChanges(for: model, action: "quit Elysium") else { return false }
        }
        return true
    }

    @discardableResult
    func requestAISuggestionInKeyWindow() -> Bool {
        guard let window = NSApp.keyWindow,
              let key = windows.first(where: { $0.value === window })?.key,
              let model = models[key], model.isWorldSessionActive else { return false }
        model.requestAISuggestion()
        return true
    }

    private func resolveUnsavedChanges(for model: ScriptEditorModel, action: String) -> Bool {
        switch confirmations.unsavedChangesDecision(model, action) {
        case .save:
            return saveAfterConfirmingCollision(model)
        case .discard:
            return true
        case .cancel:
            return false
        }
    }

    private func saveAfterConfirmingCollision(_ model: ScriptEditorModel) -> Bool {
        guard let collision = model.saveCollision else { return model.save() }
        let name = model.currentName.trimmingCharacters(in: .whitespaces)
        guard confirmations.overwriteDecision(collision, name) == .replace else { return false }
        return model.save(confirming: collision)
    }
}
