// ScriptEditorModel.swift — native SwiftUI script editor (Stage A). The testable controller: every
// `ElysiumCore` scripting call the editor makes lives here, behind plain methods a headless test
// can call directly (`ScriptEditorModelTests`, `Tests/ElysiumResourcePackTests/
// ScriptEditorScreenTests.swift`) without constructing any SwiftUI view or `NSWindow`. Views only
// read `@Published` state and call these methods — the same "thin view over a testable model"
// split the architecture doc asks for.
//
// LAN-guest aware, mirroring the retired `ScriptEditorScreen`'s exact save/run contract (design.md
// §11 phase 4): on a LAN client, Save/Run/Delete never touch `ScriptStore`/`ScriptRuntime`
// directly (those refuse with `.lanClient` anyway) — they send a `scriptIntent` and report having
// done so; the script list and an existing script's metadata come from the replicated mirror
// (`LANMultiplayerManager.mirroredScripts(for:)`), never from a live read.

import Foundation
import ElysiumCore

/// `GameCore` declares several of the members this model calls (notably
/// `persistAndPublishSettingsCandidate`) as explicitly `@MainActor` — this model is itself
/// `@MainActor` so those calls type-check directly, matching the hard rule that every
/// `GameCore`/scripting/AI touch point in this window runs on the main thread. Callers outside a
/// `@MainActor` context (an AppKit target-action method, a free function like `runCommand`) reach
/// this the same way every other AppKit-callback boundary in the app does: `elysiumMainActorSync`.
@MainActor
final class ScriptEditorModel: ObservableObject {
    let target: ObjectRef
    let game: GameCore

    @Published var scripts: [ScriptRecord] = []
    @Published var currentName: String = ""
    @Published var source: String = ""
    @Published var selectedRange: NSRange = NSRange(location: 0, length: 0)
    @Published var mode: ScriptMode = .module
    @Published var handlerEvent: String = ""
    @Published var errorLine: Int? = nil
    @Published var status: String? = nil
    @Published var statusIsError: Bool = false
    @Published var isNewScript: Bool = true

    var isLANGuest: Bool { game.isLANClientWorld }

    var targetDisplayName: String {
        game.scriptingCommandContext().graph.displayName(of: target)
    }

    var sourceByteCount: Int { source.utf8.count }

    var aiModelName: String { game.settings.aiOllamaModel }

    /// Persists a new default AI model choice through the same public settings-publish path the
    /// Options screen itself uses (`GameCore.persistAndPublishSettingsCandidate`) — a choice made
    /// from the script editor's model picker sticks exactly like an Options-screen change would.
    @discardableResult
    func setAIModel(_ name: String) -> Bool {
        var candidate = game.settings
        candidate.aiOllamaModel = name
        switch game.persistAndPublishSettingsCandidate(candidate, expectedLiveRevision: game.settingsRevision) {
        case .success: return true
        case .failure: return false
        }
    }

    init(target: ObjectRef, game: GameCore, existingName: String? = nil) {
        self.target = target
        self.game = game
        reload()
        if let existingName {
            switchTo(existingName)
        } else {
            newScript()
        }
    }

    // MARK: - list / switch / new

    /// Refreshes `scripts` from either the live `ScriptStore` (host) or the replicated metadata
    /// mirror (guest — name/mode/enabled only, source always empty).
    func reload() {
        if game.isLANClientWorld {
            let mirrored = LANMultiplayerManager.shared.mirroredScripts(for: target) ?? []
            scripts = mirrored.map { meta in
                ScriptRecord(
                    name: meta.name, source: "", enabled: meta.enabled,
                    mode: ScriptMode(rawValue: meta.mode) ?? .module, triggers: [],
                    author: .player, createdTick: 0
                )
            }
        } else {
            scripts = game.scriptingCommandContext().scriptStore.list(target)
        }
    }

    /// Loads an existing script into the editor. On a guest this only ever loads *metadata*
    /// (name/mode/enabled) — never source — and leaves a status note explaining why, exactly like
    /// the retired `ScriptEditorScreen.initScreen`'s guest branch.
    func switchTo(_ name: String) {
        if game.isLANClientWorld {
            guard let meta = LANMultiplayerManager.shared.mirroredScripts(for: target)?.first(where: { $0.name == name }) else {
                status = "No replicated data for \"\(name)\" yet."
                statusIsError = true
                return
            }
            currentName = name
            source = ""
            selectedRange = NSRange(location: 0, length: 0)
            mode = ScriptMode(rawValue: meta.mode) ?? .module
            handlerEvent = ""
            errorLine = nil
            isNewScript = false
            status = "editing \"\(name)\" — source isn't visible to guests; Save replaces it"
            statusIsError = false
            return
        }
        guard let record = game.scriptingCommandContext().scriptStore.get(target, name) else {
            status = "No script '\(name)' on \(target.canonical)"
            statusIsError = true
            return
        }
        currentName = name
        source = record.source
        selectedRange = NSRange(location: 0, length: 0)
        mode = record.mode
        handlerEvent = record.triggers.first?.event.rawValue ?? ""
        errorLine = nil
        isNewScript = false
        status = nil
        statusIsError = false
    }

    /// Clears the editor back to "authoring a fresh, unnamed script" — the palette/AI-panel still
    /// insert into `source` as usual; Save is what actually creates the record.
    func newScript() {
        currentName = ""
        source = ""
        selectedRange = NSRange(location: 0, length: 0)
        mode = .module
        handlerEvent = ""
        errorLine = nil
        isNewScript = true
        status = nil
        statusIsError = false
    }

    // MARK: - insert at cursor (palette clicks, AI "Insert into editor")

    /// Inserts `text` at the current selection (replacing it if non-empty) rather than appending
    /// to the end — the command palette's whole reason for existing over a static snippet list.
    func insertAtCursor(_ text: String) {
        guard !text.isEmpty else { return }
        let ns = source as NSString
        let range: NSRange
        if selectedRange.location >= 0, selectedRange.location <= ns.length,
           selectedRange.location + selectedRange.length <= ns.length {
            range = selectedRange
        } else {
            range = NSRange(location: ns.length, length: 0)
        }
        source = ns.replacingCharacters(in: range, with: text)
        let insertedLength = (text as NSString).length
        selectedRange = NSRange(location: range.location + insertedLength, length: 0)
        status = nil
        errorLine = nil
    }

    // MARK: - validate / save / run / check / delete

    /// The same validator `/script attach`/`/script run` use
    /// (`ScriptRuntime.validateSourceForEditor`) — the editor never accepts something the runtime
    /// would then refuse. Sets `errorLine`/`status` and returns `false` on refusal. A LAN client
    /// (no local `ScriptRuntime`) or a test context with no session runtime is treated as
    /// "nothing to validate against yet" and passes through — the same fallback the retired
    /// screen used.
    @discardableResult
    func validate() -> Bool {
        guard !game.isLANClientWorld else {
            errorLine = nil
            return true
        }
        let context = game.scriptingCommandContext()
        guard let runtime = context.scriptRuntime else {
            errorLine = nil
            return true
        }
        let chunkName = currentName.isEmpty ? "script" : currentName
        switch runtime.validateSourceForEditor(source, chunkName: chunkName).outcome {
        case .accepted:
            errorLine = nil
            return true
        case .refused(let stage, let message, let hint, let line):
            errorLine = line > 0 ? line : nil
            status = "stage \(stage) line \(line > 0 ? String(line) : "-"): \(message) — \(hint)"
            statusIsError = true
            return false
        }
    }

    private func validatedName() -> String? {
        let name = currentName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            status = "Enter a script name."
            statusIsError = true
            return nil
        }
        return name
    }

    /// Save (attach). LAN-guest aware: on a client this never calls `ScriptStore.attach` — it
    /// sends a `scriptIntent` (design.md §11 phase 4) and reports doing so; the host's accept/
    /// refuse arrives later as a chat receipt, exactly like every other optimistic guest intent.
    func save() {
        guard let name = validatedName() else { return }
        guard !source.isEmpty else {
            status = "Source is empty."
            statusIsError = true
            return
        }
        var eventText: String?
        var parsedEvent: EventKind?
        if mode == .handler {
            let text = handlerEvent.trimmingCharacters(in: .whitespaces)
            guard let event = EventKind.parse(text) else {
                status = "'\(text)' is not a valid event name."
                statusIsError = true
                return
            }
            eventText = text
            parsedEvent = event
        }
        if game.isLANClientWorld {
            var args = ["attach", target.canonical, name, mode == .handler ? "handler" : "module"]
            if let eventText { args.append(eventText) }
            args.append(source)
            LANMultiplayerManager.shared.sendScriptIntent(.command("script", args))
            status = "sent \"\(name)\" to the host..."
            statusIsError = false
            return
        }
        let context = game.scriptingCommandContext()
        guard validate() else { return }
        let triggers: [Trigger] = parsedEvent.map { [Trigger(event: $0, attribute: nil, target: .object(target))] } ?? []
        switch context.scriptStore.attach(
            target, name: name, source: source, mode: mode, triggers: triggers, by: .player, tick: context.tick
        ) {
        case .success:
            game.scripting.anyScriptsAttached = true
            status = "Attached \"\(name)\" to \(target.canonical)"
            statusIsError = false
            isNewScript = false
            reload()
        case .failure(let err):
            status = scriptStoreErrorText(err)
            statusIsError = true
        }
    }

    /// Run (ephemeral — §9.3). Never persists anything, on host or guest. LAN-guest aware: sends a
    /// `scriptIntent` and never calls `runEphemeral` locally (a guest has no `ScriptRuntime` to
    /// call it against in the first place).
    func run() {
        guard !source.isEmpty else {
            status = "Source is empty."
            statusIsError = true
            return
        }
        if game.isLANClientWorld {
            LANMultiplayerManager.shared.sendScriptIntent(.command("script", ["run", target.canonical, source]))
            status = "sent to the host..."
            statusIsError = false
            return
        }
        let context = game.scriptingCommandContext()
        guard let runtime = context.scriptRuntime else {
            status = "No script runtime this session."
            statusIsError = true
            return
        }
        guard validate() else { return }
        switch runtime.runEphemeral(source: source, owner: target) {
        case .success(let message):
            status = message
            statusIsError = false
        case .failure(let message):
            status = message
            statusIsError = true
        }
    }

    /// Check (dry-run — design.md §9.4 stage 6): compiles and runs once against a read-only
    /// facade, never persists, never emits, never reaches the AI outbox. Not available to a LAN
    /// guest (no local `ScriptRuntime`, and `dryRun` has no `scriptIntent` verb — `attach`/
    /// `detach`/`run` are the only forwardable `/script` subcommands, `ScriptingCommands
    /// .lanForwardableCommand`).
    func check() {
        guard !source.isEmpty else {
            status = "Source is empty."
            statusIsError = true
            return
        }
        guard !game.isLANClientWorld else {
            status = "Check is not available for guests yet — use Run or Save."
            statusIsError = true
            return
        }
        let context = game.scriptingCommandContext()
        guard let runtime = context.scriptRuntime else {
            status = "No script runtime this session."
            statusIsError = true
            return
        }
        guard validate() else { return }
        if let message = runtime.dryRun(source: source, owner: target, mode: mode) {
            status = message
            statusIsError = true
        } else {
            status = "Check passed — no issues found."
            statusIsError = false
        }
    }

    /// Deletes (detaches) a script from the target — `detach` is one of the three forwardable
    /// `/script` verbs (design.md §11), so this works for a guest too.
    func deleteScript(_ name: String) {
        if game.isLANClientWorld {
            LANMultiplayerManager.shared.sendScriptIntent(.command("script", ["detach", target.canonical, name]))
            status = "sent detach \"\(name)\" to the host..."
            statusIsError = false
            return
        }
        let context = game.scriptingCommandContext()
        switch context.scriptStore.detach(target, name) {
        case .success(let existed):
            guard existed else {
                status = "No script '\(name)'"
                statusIsError = true
                return
            }
            status = "Detached \"\(name)\""
            statusIsError = false
            if currentName == name { newScript() }
            reload()
        case .failure(let err):
            status = scriptStoreErrorText(err)
            statusIsError = true
        }
    }
}
