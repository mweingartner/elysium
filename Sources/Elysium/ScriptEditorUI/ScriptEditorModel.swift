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
import Combine
import ElysiumCore

/// An optimistic-concurrency token for one destructive Save decision. UI code captures this exact
/// value before presenting a modal confirmation; Save succeeds only if a synchronous re-read still
/// produces the same collision. The token deliberately carries no user-editable Boolean bypass.
struct ScriptEditorSaveCollision: Equatable {
    enum Snapshot: Equatable {
        case host(ScriptRecord?)
        case guest(mode: String?, enabled: Bool?)
    }

    let name: String
    let description: String
    let snapshot: Snapshot
}

enum ScriptEditorRuntimeUnavailableReason: Equatable {
    case lanGuest
    case worldSessionEnded
    case missingRuntime
}

enum ScriptEditorScriptingActivationAction: Equatable {
    case trustWorld
    case turnOnKillSwitch
    case trustWorldAndTurnOnKillSwitch

    var buttonTitle: String {
        switch self {
        case .trustWorld: "Trust World"
        case .turnOnKillSwitch: "Turn On Scripts"
        case .trustWorldAndTurnOnKillSwitch: "Trust & Turn On"
        }
    }

    var confirmationDetail: String {
        switch self {
        case .trustWorld, .trustWorldAndTurnOnKillSwitch:
            "Trusting this world is persisted and cannot be reversed with Elysium's current controls. Every attached script in this world may run as soon as simulation resumes, including load and event handlers. Continue only if you trust all attached scripts."
        case .turnOnKillSwitch:
            "Every attached script in this world may run as soon as simulation resumes, including load and event handlers. This does not change the world's persisted trust setting."
        }
    }
}

enum ScriptEditorAIReadinessState: Equatable {
    case off
    case needsModel
    case idle
    case preparing(String)
    case ready(String)
    case failed(model: String, message: String)

    var statusText: String {
        switch self {
        case .off: "Editor AI is Off"
        case .needsModel: "Choose a local Ollama model"
        case .idle: "Script AI is idle"
        case .preparing(let model): "Preparing \(model)…"
        case .ready(let model): "\(model) is ready"
        case .failed(let model, _): "\(model) is not ready"
        }
    }

    var accessibilityText: String {
        switch self {
        case .failed(_, let message): "\(statusText). \(message)"
        default: statusText
        }
    }
}

struct ScriptEditorAIInsertionReceipt: Equatable {
    let mode: ScriptMode
    let eventName: String?
    let replacedRange: NSRange
    let insertedUTF16Length: Int
    let omittedTrailingText: Bool

    var destinationDescription: String {
        if mode == .handler {
            let event = eventName.flatMap { $0.isEmpty ? nil : $0 } ?? "selected event"
            return "Handler · \(event)"
        }
        return "Module"
    }
}

/// The user, not model output, authorizes whether a panel request may edit source. This removes
/// the ambiguity between a valid Lua-looking answer and a requested code change.
enum ScriptEditorAIRequestIntent: String, CaseIterable, Identifiable, Sendable {
    case writeCode = "Write Code"
    case ask = "Ask"

    var id: Self { self }

    var completionIntent: OllamaCodeCompletionInstructionIntent {
        switch self {
        case .writeCode: .codeChange
        case .ask: .question
        }
    }
}

enum ScriptEditorAIApplyOutcome: Equatable {
    case inserted(ScriptEditorAIInsertionReceipt)
    case answerOnly
    case refused(String)
}

struct ScriptEditorAIReply: Equatable {
    let text: String
    let applyOutcome: ScriptEditorAIApplyOutcome
}

/// Durable editor-facing projection of the two execution gates. This state is intentionally
/// independent of the transient `status` line: Save/Check/Run results must never hide why attached
/// scripts are paused or imply that opening the editor changed a world-wide security control.
enum ScriptEditorScriptingAvailability: Equatable {
    case active
    case trustRequired
    case killSwitchOff
    case both
    case runtimeUnavailable(ScriptEditorRuntimeUnavailableReason)

    var title: String {
        switch self {
        case .active: "Attached scripts are active"
        case .trustRequired: "Attached scripts are paused — trust required"
        case .killSwitchOff: "Attached scripts are paused — scripts are turned off"
        case .both: "Attached scripts are paused — trust and activation required"
        case .runtimeUnavailable(.lanGuest): "Scripts run on the LAN host"
        case .runtimeUnavailable(.worldSessionEnded): "World session ended"
        case .runtimeUnavailable(.missingRuntime): "Script runtime unavailable"
        }
    }

    var detail: String {
        switch self {
        case .active:
            "Saved scripts can run when their events or lifecycle phases occur."
        case .trustRequired:
            "Save, Check, and Run Once remain available, but attached execution is paused until you explicitly trust this world."
        case .killSwitchOff:
            "Saving and Check remain available, but attached execution is paused by the doScripts kill switch."
        case .both:
            "Saving and Check remain available, but attached execution is paused until you trust the world and turn scripts on."
        case .runtimeUnavailable(.lanGuest):
            "Save and Run requests go to the host. Check requires a local host runtime."
        case .runtimeUnavailable(.worldSessionEnded):
            "This draft remains available to copy, but world-backed actions are no longer available."
        case .runtimeUnavailable(.missingRuntime):
            "This draft remains available to copy, but Check, Save, and Run Once are unavailable because this session cannot validate or execute scripts."
        }
    }

    var systemImage: String {
        switch self {
        case .active: "checkmark.shield.fill"
        case .trustRequired, .killSwitchOff, .both: "pause.circle.fill"
        case .runtimeUnavailable(.lanGuest): "network"
        case .runtimeUnavailable(.worldSessionEnded): "clock.badge.xmark"
        case .runtimeUnavailable(.missingRuntime): "exclamationmark.triangle.fill"
        }
    }

    var activationAction: ScriptEditorScriptingActivationAction? {
        switch self {
        case .active, .runtimeUnavailable: nil
        case .trustRequired: .trustWorld
        case .killSwitchOff: .turnOnKillSwitch
        case .both: .trustWorldAndTurnOnKillSwitch
        }
    }

    var attachedExecutionIsPaused: Bool {
        self != .active
    }

    var canCheck: Bool {
        switch self {
        case .active, .trustRequired, .killSwitchOff, .both: true
        case .runtimeUnavailable: false
        }
    }

    var canRunOnce: Bool {
        switch self {
        case .active, .trustRequired, .runtimeUnavailable(.lanGuest): true
        case .killSwitchOff, .both,
             .runtimeUnavailable(.worldSessionEnded), .runtimeUnavailable(.missingRuntime): false
        }
    }

    var canSave: Bool {
        switch self {
        case .active, .trustRequired, .killSwitchOff, .both,
             .runtimeUnavailable(.lanGuest): true
        case .runtimeUnavailable(.worldSessionEnded), .runtimeUnavailable(.missingRuntime): false
        }
    }
}

/// `GameCore` declares several of the members this model calls (notably
/// `persistAndPublishSettingsCandidate`) as explicitly `@MainActor` — this model is itself
/// `@MainActor` so those calls type-check directly, matching the hard rule that every
/// `GameCore`/scripting/AI touch point in this window runs on the main thread. Callers outside a
/// `@MainActor` context (an AppKit target-action method, a free function like `runCommand`) reach
/// this the same way every other AppKit-callback boundary in the app does: `elysiumMainActorSync`.
@MainActor
final class ScriptEditorModel: ObservableObject {
    private static let liveModels = NSHashTable<ScriptEditorModel>.weakObjects()

    let target: ObjectRef
    let game: GameCore
    private let aiCompleter: any ScriptEditorAICompleting
    private var aiReadinessOwner = UUID()
    private let openedWorldSessionGeneration: UInt64
    private let openedWorldRecordID: String?
    private let openedAsLANGuest: Bool
    private var cachedTargetDisplayName: String

    @Published var scripts: [ScriptRecord] = []
    @Published var currentName: String = ""
    @Published var source: String = "" {
        didSet {
            guard source != oldValue else { return }
            documentRevision &+= 1
            sourceOrCaretDidChange()
        }
    }
    @Published var selectedRange: NSRange = NSRange(location: 0, length: 0) {
        didSet {
            guard selectedRange != oldValue else { return }
            sourceOrCaretDidChange()
        }
    }
    @Published var mode: ScriptMode = .module {
        didSet {
            guard mode != oldValue else { return }
            authoringContextDidChange()
        }
    }
    @Published var handlerEvent: String = "" {
        didSet {
            guard handlerEvent != oldValue else { return }
            authoringContextDidChange()
        }
    }
    @Published var errorLine: Int? = nil
    @Published var status: String? = nil
    @Published var statusIsError: Bool = false
    @Published var isNewScript: Bool = true
    @Published private(set) var worldObjects: [WorldObjectPaletteEntry] = []
    @Published private(set) var targetApplicableBuiltInAttributes: Set<String>?
    @Published private(set) var targetCustomAttributes: [String] = []
    @Published private(set) var targetCustomAttributeCompletions: [LuaCustomAttributeCompletion] = []
    @Published private(set) var handlerEventCandidates: [ScriptEditorEventCandidate] = []
    @Published private(set) var editorDiagnostics: [LuaDiagnostic] = []
    @Published private(set) var signatureHelp: LuaSignatureHelp?
    @Published private(set) var inlineAISuggestion: String?
    @Published private(set) var isRequestingAISuggestion = false
    @Published private(set) var aiSuggestionError: String?
    @Published private(set) var aiCompletionMode: ScriptEditorAICompletionMode
    @Published private(set) var aiModelName: String
    @Published private(set) var aiReadinessState: ScriptEditorAIReadinessState = .idle
    @Published private(set) var externalEditorEdit: LuaEditorExternalEdit?
    @Published private(set) var documentIdentity: UInt64 = 0
    /// Invalidates the computed language environment when Options imports or deletes a sound
    /// while this native editor window remains open.
    @Published private(set) var soundCatalogRevision: UInt64 = 0
    @Published private(set) var isWorldSessionActive: Bool
    @Published private(set) var scriptingAvailability: ScriptEditorScriptingAvailability =
        .runtimeUnavailable(.worldSessionEnded)

    private var cleanName = ""
    private var cleanSource = ""
    private var cleanMode: ScriptMode = .module
    private var cleanHandlerEvent = ""
    private var cleanTriggers: [Trigger] = []
    private var cleanEnabled = true
    private var documentRevision: UInt64 = 0
    private var authoringContextRevision: UInt64 = 0
    private var aiSuggestionTask: Task<Void, Never>?
    private var aiIdleTask: Task<Void, Never>?
    private var aiPreparationTask: Task<Void, Never>?
    private var aiRequestGeneration: UInt64 = 0
    private var aiPreparationGeneration: UInt64 = 0
    private var aiReadinessLifecycleActive = false
    private var externalEditorEditSequence: UInt64 = 0
    private var isApplyingAISuggestion = false
    private var worldSessionObserver: AnyCancellable?
    private var soundCatalogObserver: AnyCancellable?

    var isLANGuest: Bool { openedAsLANGuest }

    var targetDisplayName: String { cachedTargetDisplayName }

    var sourceByteCount: Int { source.utf8.count }

    var worldObjectPinScope: String {
        openedWorldRecordID ?? (openedAsLANGuest ? "lan-session" : "local-session")
    }

    var isDirty: Bool {
        currentName != cleanName || source != cleanSource || mode != cleanMode ||
            handlerEvent != cleanHandlerEvent
    }

    /// True when Save would replace a different existing record rather than update the document
    /// originally loaded in this window. UI and close flows must obtain explicit confirmation.
    var saveRequiresOverwriteConfirmation: Bool {
        saveCollision != nil
    }

    var saveCollisionDescription: String? {
        saveCollision?.description
    }

    var saveCollision: ScriptEditorSaveCollision? {
        let name = currentName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return authoritativeSaveCollision(for: name)
    }

    var handlerEventValidationError: String? {
        guard mode == .handler else { return nil }
        return ScriptEditorAuthoringContract.handlerEventValidationError(
            eventName: handlerEvent,
            targetKind: target.kind
        )
    }

    /// Persists a new default AI model choice through the same public settings-publish path the
    /// Options screen itself uses (`GameCore.persistAndPublishSettingsCandidate`) — a choice made
    /// from the script editor's model picker sticks exactly like an Options-screen change would.
    @discardableResult
    func setAIModel(_ name: String) -> Bool {
        cancelAIWork(clearSuggestion: true)
        var candidate = game.settings
        candidate.aiOllamaModel = name
        switch game.persistAndPublishSettingsCandidate(candidate, expectedLiveRevision: game.settingsRevision) {
        case .success:
            for editor in Self.liveModels.allObjects where editor.game === game {
                editor.applySharedAIModel(game.settings.aiOllamaModel)
            }
            return true
        case .failure:
            return false
        }
    }

    init(
        target: ObjectRef,
        game: GameCore,
        existingName: String? = nil,
        aiCompleter: any ScriptEditorAICompleting = elysiumOllamaCodeCompletion
    ) {
        self.target = target
        self.game = game
        self.aiCompleter = aiCompleter
        self.openedWorldSessionGeneration = game.worldSessionGeneration
        self.openedWorldRecordID = game.worldRec?.id
        self.openedAsLANGuest = game.isLANClientWorld
        self.cachedTargetDisplayName = target.canonical
        self.isWorldSessionActive = game.hasWorld()
        self.aiCompletionMode = ScriptEditorAICompletionMode.persisted()
        self.aiModelName = game.settings.aiOllamaModel
        Self.liveModels.add(self)
        if isCurrentWorldSession {
            cachedTargetDisplayName = displayName(for: target, graph: game.scriptingCommandContext().graph)
        }
        worldSessionObserver = NotificationCenter.default
            .publisher(for: .elysiumWorldSessionWillEnd, object: game)
            .sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.disconnectFromWorldSession()
            }
        }
        soundCatalogObserver = NotificationCenter.default
            .publisher(for: .elysiumScriptSoundCatalogDidChange)
            .sink { [weak self] _ in
            MainActor.assumeIsolated {
                self?.soundCatalogRevision &+= 1
            }
        }
        refreshScriptingAvailability()
        reload()
        if let existingName {
            switchTo(existingName)
        } else {
            newScript()
        }
        refreshWorldObjects()
    }

    deinit {
        aiPreparationTask?.cancel()
        let completer = aiCompleter
        let owner = aiReadinessOwner
        Task {
            await completer.releaseEditorModel(owner: owner)
        }
    }

    private var isCurrentWorldSession: Bool {
        isWorldSessionActive && game.hasWorld()
            && game.worldSessionGeneration == openedWorldSessionGeneration
            && game.worldRec?.id == openedWorldRecordID
    }

    @discardableResult
    private func requireCurrentWorldSession(for action: String) -> Bool {
        guard isCurrentWorldSession else {
            disconnectFromWorldSession()
            status = "This draft belongs to a world session that has ended. Copy its source into a new editor before you \(action)."
            statusIsError = true
            return false
        }
        return true
    }

    private func disconnectFromWorldSession() {
        guard isWorldSessionActive else { return }
        isWorldSessionActive = false
        scriptingAvailability = .runtimeUnavailable(.worldSessionEnded)
        authoringContextRevision &+= 1
        cancelAIWork(clearSuggestion: true)
        updateAIReadiness()
        worldObjects = []
        targetApplicableBuiltInAttributes = nil
        targetCustomAttributes = []
        targetCustomAttributeCompletions = []
        handlerEventCandidates = ScriptEditorEventCatalog.candidates(targetKind: target.kind)
        status = "World session ended. This draft is retained read-only from the game; copy it into a new editor to continue."
        statusIsError = true
    }

    /// Re-reads the world-wide execution controls without changing either one. The view invokes
    /// this whenever its window becomes key so chat/command changes made elsewhere are reflected.
    func refreshScriptingAvailability() {
        guard isCurrentWorldSession else {
            scriptingAvailability = .runtimeUnavailable(.worldSessionEnded)
            return
        }
        guard !openedAsLANGuest else {
            scriptingAvailability = .runtimeUnavailable(.lanGuest)
            return
        }
        let context = game.scriptingCommandContext()
        guard context.scriptRuntime != nil else {
            scriptingAvailability = .runtimeUnavailable(.missingRuntime)
            return
        }
        switch (context.scriptsTrusted, context.killSwitchOn) {
        case (true, true): scriptingAvailability = .active
        case (false, true): scriptingAvailability = .trustRequired
        case (true, false): scriptingAvailability = .killSwitchOff
        case (false, false): scriptingAvailability = .both
        }
    }

    /// Applies the action the UI has already explained and confirmed. Opening, editing, Save,
    /// Check, and Run never call this method. Re-read immediately so a stale confirmation cannot
    /// turn on a gate that is no longer represented by the persistent banner.
    func enableAttachedScriptExecutionAfterConfirmation(
        confirming expectedAction: ScriptEditorScriptingActivationAction
    ) {
        guard requireCurrentWorldSession(for: "change script execution settings") else { return }
        refreshScriptingAvailability()
        guard scriptingAvailability.activationAction == expectedAction else {
            Self.refreshScriptingAvailability(in: game)
            status = "Script execution settings changed while confirmation was open. Review the current status and confirm again."
            statusIsError = true
            return
        }
        let context = game.scriptingCommandContext()
        switch expectedAction {
        case .trustWorld:
            context.trustWorld()
        case .turnOnKillSwitch:
            context.setKillSwitch(true)
        case .trustWorldAndTurnOnKillSwitch:
            context.trustWorld()
            context.setKillSwitch(true)
        }

        Self.refreshScriptingAvailability(in: game)
        if case .active = scriptingAvailability {
            status = "Attached script execution is active."
            statusIsError = false
        } else {
            status = "The script execution settings could not be enabled."
            statusIsError = true
        }
    }

    private static func refreshScriptingAvailability(in game: GameCore) {
        for editor in liveModels.allObjects where editor.game === game {
            editor.refreshScriptingAvailability()
        }
    }

    // MARK: - deterministic analysis and optional editor AI

    var languageEnvironment: LuaLanguageEnvironment {
        LuaLanguageEnvironment(
            targetKind: target.kind,
            targetCanonicalRef: target.canonical,
            targetApplicableBuiltInAttributes: targetApplicableBuiltInAttributes,
            targetCustomAttributes: targetCustomAttributeCompletions,
            objectReferences: worldObjects.map { entry in
                LuaObjectReferenceCompletion(
                    canonicalRef: entry.ref.canonical,
                    displayName: entry.displayName,
                    kind: entry.ref.kind,
                    isLive: entry.isLive,
                    customAttributes: entry.attributeCompletions
                )
            },
            soundNames: game.scriptSoundNames(),
            scriptMode: mode,
            handlerEvent: mode == .handler ? handlerEvent : nil,
            eventCandidates: handlerEventCandidates,
            isYieldable: true
        )
    }

    func updateLanguageAnalysis(_ diagnostics: [LuaDiagnostic], signature: LuaSignatureHelp?) {
        editorDiagnostics = diagnostics
        signatureHelp = signature
    }

    /// The AppKit text view has already inserted this proposal through the normal undo manager.
    /// Clear only proposal state here so the binding update cannot insert the same text twice.
    func didAcceptAISuggestionInTextView(_ accepted: String) {
        guard inlineAISuggestion == accepted else {
            cancelAIWork(clearSuggestion: true)
            return
        }
        cancelAIWork(clearSuggestion: true)
    }

    func applyQuickFix(_ fix: LuaQuickFix) {
        selectedRange = fix.replacementRange
        insertAtCursor(fix.replacementText)
    }

    func setAICompletionMode(_ newMode: ScriptEditorAICompletionMode) {
        UserDefaults.standard.set(newMode.rawValue, forKey: ScriptEditorAICompletionMode.defaultsKey)
        for editor in Self.liveModels.allObjects {
            editor.applySharedAICompletionMode(newMode)
        }
    }

    func refreshAIConfiguration() {
        synchronizeSharedAIConfiguration()
    }

    /// Called by the native window controller as soon as an editor opens. This deliberately does
    /// not depend on the optional Script AI panel being visible: Manual and On Idle both prepare
    /// the exact configured local model before the first prompt can race its cold load.
    func beginAIReadiness() {
        guard !aiReadinessLifecycleActive else { return }
        aiReadinessLifecycleActive = true
        updateAIReadiness()
    }

    /// Releases this editor's interest. A process-shared preparation stays alive while another
    /// editor still owns the same exact model.
    func endAIReadiness() {
        guard aiReadinessLifecycleActive else { return }
        aiReadinessLifecycleActive = false
        aiPreparationGeneration &+= 1
        aiPreparationTask?.cancel()
        aiPreparationTask = nil
        aiReadinessState = aiCompletionMode == .off ? .off : .idle
        releaseCurrentAIReadinessOwner()
    }

    func retryAIReadiness() {
        guard aiCompletionMode != .off, isWorldSessionActive else { return }
        aiPreparationGeneration &+= 1
        aiPreparationTask?.cancel()
        aiPreparationTask = nil
        updateAIReadiness(force: true)
    }

    private func applySharedAICompletionMode(_ newMode: ScriptEditorAICompletionMode) {
        guard newMode != aiCompletionMode else { return }
        aiCompletionMode = newMode
        cancelAIWork(clearSuggestion: true)
        aiSuggestionError = nil
        updateAIReadiness()
        if newMode == .onIdle { scheduleIdleAISuggestionIfNeeded() }
    }

    private func applySharedAIModel(_ name: String) {
        guard name != aiModelName else { return }
        cancelAIWork(clearSuggestion: true)
        aiModelName = name
        aiSuggestionError = nil
        updateAIReadiness()
        scheduleIdleAISuggestionIfNeeded()
    }

    private func synchronizeSharedAIConfiguration() {
        applySharedAICompletionMode(ScriptEditorAICompletionMode.persisted())
        applySharedAIModel(game.settings.aiOllamaModel)
    }

    private func updateAIReadiness(force: Bool = false) {
        aiPreparationGeneration &+= 1
        let generation = aiPreparationGeneration
        aiPreparationTask?.cancel()
        aiPreparationTask = nil

        guard aiReadinessLifecycleActive, isWorldSessionActive else {
            aiReadinessState = aiCompletionMode == .off ? .off : .idle
            releaseCurrentAIReadinessOwner()
            return
        }
        guard aiCompletionMode != .off else {
            aiReadinessState = .off
            releaseCurrentAIReadinessOwner()
            return
        }
        let model = aiModelName
        guard !model.isEmpty, isAllowedLocalOllamaModelName(model) else {
            aiReadinessState = .needsModel
            releaseCurrentAIReadinessOwner()
            return
        }

        if !force, aiReadinessState == .ready(model) { return }
        aiReadinessState = .preparing(model)
        let completer = aiCompleter
        let owner = aiReadinessOwner
        aiPreparationTask = Task { @MainActor [weak self] in
            do {
                try await completer.prepareEditorModel(model, owner: owner)
                guard let self, !Task.isCancelled,
                      self.aiPreparationGeneration == generation,
                      self.aiReadinessLifecycleActive,
                      self.aiCompletionMode != .off,
                      self.isWorldSessionActive,
                      self.aiModelName == model else { return }
                self.aiReadinessState = .ready(model)
                self.aiPreparationTask = nil
            } catch let error as OllamaCodeCompletionError where error == .cancelled {
                return
            } catch {
                guard let self, !Task.isCancelled,
                      self.aiPreparationGeneration == generation,
                      self.aiModelName == model else { return }
                self.aiReadinessState = .failed(
                    model: model,
                    message: error.localizedDescription
                )
                self.aiPreparationTask = nil
            }
        }
    }

    /// Retire the token before scheduling its release. A delayed actor hop for an old lifecycle
    /// state can then never remove this editor's newly prepared model ownership.
    private func releaseCurrentAIReadinessOwner() {
        let completer = aiCompleter
        let retiredOwner = aiReadinessOwner
        aiReadinessOwner = UUID()
        Task {
            await completer.releaseEditorModel(owner: retiredOwner)
        }
    }

    /// Requests one optional Ollama proposal. Manual mode never reaches this method unless the
    /// user invokes the toolbar/menu/hot-key action; Off refuses even an explicit shortcut.
    func requestAISuggestion() {
        synchronizeSharedAIConfiguration()
        guard aiCompletionMode != .off else {
            aiSuggestionError = "Editor AI is Off. Choose Manual or On Idle to request a suggestion."
            return
        }
        guard selectedRange.length == 0 else {
            aiSuggestionError = "Collapse the selection to a caret before requesting inline completion. Use Script AI for a selected rewrite."
            return
        }
        if let authoringError = editorAIRequestPreflightError {
            aiSuggestionError = authoringError.localizedDescription
            return
        }
        cancelAIWork(clearSuggestion: true)
        let requestGeneration = aiRequestGeneration
        aiSuggestionError = nil
        isRequestingAISuggestion = true

        aiSuggestionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await self.performEditorAIRequest(instruction: nil)
                guard !Task.isCancelled, self.aiRequestGeneration == requestGeneration else { return }
                if let refusal = self.aiInsertionPreflightFailure(response.insertion) {
                    self.aiSuggestionError = refusal
                    self.isRequestingAISuggestion = false
                    return
                }
                self.inlineAISuggestion = response.insertion
                self.isRequestingAISuggestion = false
            } catch let error as OllamaCodeCompletionError {
                guard self.aiRequestGeneration == requestGeneration else { return }
                guard error != .cancelled, error != .stale else {
                    self.isRequestingAISuggestion = false
                    return
                }
                self.aiSuggestionError = error.localizedDescription
                self.isRequestingAISuggestion = false
            } catch {
                guard !Task.isCancelled, self.aiRequestGeneration == requestGeneration else { return }
                self.aiSuggestionError = error.localizedDescription
                self.isRequestingAISuggestion = false
            }
        }
    }

    /// The right-hand Script AI panel uses the same proposal-only service with an instruction.
    /// It remains separate from `/ai`: no tool definitions or mutation context are reachable.
    func requestEditorAIReply(
        instruction: String,
        intent: ScriptEditorAIRequestIntent
    ) async throws -> ScriptEditorAIReply {
        synchronizeSharedAIConfiguration()
        guard aiCompletionMode != .off else { throw ScriptEditorAIRequestError.disabled }
        if let selectionError = editorAISelectionPreflightError {
            throw selectionError
        }
        if intent == .writeCode, let authoringError = editorAIRequestPreflightError {
            throw authoringError
        }
        let response = try await performEditorAIRequest(
            instruction: instruction,
            instructionIntent: intent.completionIntent
        )
        try Task.checkCancellation()
        return ScriptEditorAIReply(
            text: response.text,
            applyOutcome: intent == .writeCode ? applyEditorAIReply(response.text) : .answerOnly
        )
    }

    func acceptAISuggestion() {
        guard let suggestion = inlineAISuggestion else { return }
        isApplyingAISuggestion = true
        inlineAISuggestion = nil
        insertAtCursor(suggestion)
        isApplyingAISuggestion = false
    }

    func acceptNextAIWord() {
        acceptAIFragment(Self.nextWordFragment)
    }

    func acceptNextAILine() {
        acceptAIFragment(Self.nextLineFragment)
    }

    func dismissAISuggestion() {
        cancelAIWork(clearSuggestion: true)
        aiSuggestionError = nil
    }

    func cancelAIWork(clearSuggestion: Bool = true) {
        aiRequestGeneration &+= 1
        aiSuggestionTask?.cancel()
        aiSuggestionTask = nil
        aiIdleTask?.cancel()
        aiIdleTask = nil
        isRequestingAISuggestion = false
        if clearSuggestion { inlineAISuggestion = nil }
    }

    private func sourceOrCaretDidChange() {
        guard !isApplyingAISuggestion else { return }
        cancelAIWork(clearSuggestion: true)
        aiSuggestionError = nil
        scheduleIdleAISuggestionIfNeeded()
    }

    private func authoringContextDidChange() {
        authoringContextRevision &+= 1
        cancelAIWork(clearSuggestion: true)
        aiSuggestionError = nil
    }

    private func scheduleIdleAISuggestionIfNeeded() {
        guard aiCompletionMode == .onIdle, !source.isEmpty, selectedRange.length == 0 else { return }
        aiIdleTask = Task { @MainActor [weak self] in
            do {
                try await ContinuousClock().sleep(for: .milliseconds(650))
                guard let self, !Task.isCancelled, self.aiCompletionMode == .onIdle else { return }
                self.requestAISuggestion()
            } catch {
                // Cancellation is the normal path for continued typing or caret movement.
            }
        }
    }

    private func performEditorAIRequest(
        instruction: String?,
        instructionIntent: OllamaCodeCompletionInstructionIntent? = nil
    ) async throws -> OllamaCodeCompletionResponse {
        guard isCurrentWorldSession else {
            disconnectFromWorldSession()
            throw OllamaCodeCompletionError.stale
        }
        let requestedModel = aiModelName
        let requestGeneration = aiRequestGeneration
        // Capture the exact document, selection, mode, event, model, and authorized context before
        // a cold-model await. The editor remains editable while Ollama prepares; that must make
        // this request stale rather than silently retargeting the eventual reply.
        let request = try makeEditorAIRequest(
            model: requestedModel,
            instruction: instruction,
            instructionIntent: instructionIntent ?? .codeChange
        )
        if aiReadinessState != .ready(requestedModel) {
            aiReadinessState = .preparing(requestedModel)
        }
        do {
            try await aiCompleter.prepareEditorModel(
                requestedModel,
                owner: aiReadinessOwner
            )
            try Task.checkCancellation()
            guard isCurrentWorldSession,
                  aiRequestGeneration == requestGeneration,
                  aiCompletionMode != .off,
                  aiModelName == requestedModel else {
                throw OllamaCodeCompletionError.stale
            }
            aiReadinessState = .ready(requestedModel)
        } catch let error as OllamaCodeCompletionError {
            if error != .cancelled, error != .stale,
               aiModelName == requestedModel, aiCompletionMode != .off {
                aiReadinessState = .failed(
                    model: requestedModel,
                    message: error.localizedDescription
                )
            }
            throw error
        } catch is CancellationError {
            throw OllamaCodeCompletionError.cancelled
        } catch {
            if aiModelName == requestedModel, aiCompletionMode != .off {
                aiReadinessState = .failed(
                    model: requestedModel,
                    message: error.localizedDescription
                )
            }
            throw error
        }
        guard isCurrentAIRequest(request, requestGeneration: requestGeneration) else {
            throw OllamaCodeCompletionError.stale
        }
        let response: OllamaCodeCompletionResponse
        do {
            response = try await aiCompleter.completeEditorRequest(request)
        } catch let error as OllamaCodeCompletionError {
            if (error == .transport || error == .modelPreparationFailed),
               isCurrentAIRequest(request, requestGeneration: requestGeneration) {
                aiReadinessState = .failed(
                    model: requestedModel,
                    message: error.localizedDescription
                )
            }
            throw error
        } catch is CancellationError {
            throw OllamaCodeCompletionError.cancelled
        } catch {
            throw error
        }
        guard response.identity == request.identity,
              isCurrentAIRequest(request, requestGeneration: requestGeneration) else {
            throw OllamaCodeCompletionError.stale
        }
        return response
    }

    private func makeEditorAIRequest(
        model requestedModel: String,
        instruction: String?,
        instructionIntent: OllamaCodeCompletionInstructionIntent
    ) throws -> OllamaCodeCompletionRequest {
        let contextKey = currentAIContextKey
        let scriptingContext = game.scriptingCommandContext()
        let includeCrossObjectEvents = mode == .module
        let nearbyObjects = worldObjects.filter(\.isLive).map { entry in
            let attributes = customAttributes(for: entry.ref, context: scriptingContext)
            return OllamaCodeCompletionNearbyObject(
                reference: entry.ref.canonical,
                kind: entry.kindLabel,
                displayName: entry.displayName,
                distance: entry.distance,
                capabilities: entry.capabilities,
                customAttributes: attributes.map {
                    OllamaCodeCompletionNearbyAttribute(
                        name: $0.name,
                        type: Self.luaTypeName(for: $0.value),
                        mutability: $0.readonly.map { $0 ? "read_only" : "writable" }
                            ?? "host_authoritative_unknown"
                    )
                },
                builtInEvents: includeCrossObjectEvents
                    ? EventDescriptorRegistry.available.compactMap { descriptor in
                        descriptor.subjectKinds.contains(entry.ref.kind)
                            && aiBuiltInEventIsApplicable(
                                descriptor.kind, to: entry.ref, graph: scriptingContext.graph
                            )
                            ? descriptor.kind.rawValue
                            : nil
                    }
                    : nil,
                customEvents: includeCrossObjectEvents
                    ? customEventCandidates(for: entry.ref, context: scriptingContext).map(aiEvent)
                    : nil
            )
        }
        return try OllamaCodeCompletionRequest(
            source: source,
            caretUTF16: selectedRange.location,
            selectionLengthUTF16: selectedRange.length,
            documentRevision: documentRevision,
            documentIdentity: documentIdentity,
            contextKey: contextKey,
            model: requestedModel,
            languageSchema: ScriptLanguageSchema.luaCATSDefinitions,
            authoringContext: currentAIAuthoringContext,
            diagnostics: editorDiagnostics.map(\.message),
            authorizedNearbyObjects: nearbyObjects,
            fillInMiddlePolicy: .disabled,
            instruction: instruction,
            instructionIntent: instructionIntent
        )
    }

    private func isCurrentAIRequest(
        _ request: OllamaCodeCompletionRequest,
        requestGeneration: UInt64
    ) -> Bool {
        isCurrentWorldSession
            && aiRequestGeneration == requestGeneration
            && aiCompletionMode != .off
            && request.identity.matches(
            documentRevision: documentRevision,
            documentIdentity: documentIdentity,
            source: source,
            caretUTF16: selectedRange.location,
            selectionLengthUTF16: selectedRange.length,
            contextKey: currentAIContextKey,
            model: aiModelName,
            instruction: request.instruction
        )
    }

    private var currentAIContextKey: OllamaCodeCompletionContextKey {
        OllamaCodeCompletionContextKey(
            revision: authoringContextRevision,
            targetReference: target.canonical,
            scriptMode: mode.rawValue,
            eventName: mode == .handler ? handlerEvent : nil
        )
    }

    private var editorAIRequestPreflightError: ScriptEditorAIRequestError? {
        guard mode == .handler else { return nil }
        let eventName = handlerEvent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !eventName.isEmpty else { return .handlerEventRequired }
        if let error = ScriptEditorAuthoringContract.handlerEventValidationError(
            eventName: eventName,
            targetKind: target.kind
        ) {
            return .invalidHandlerEvent(error)
        }
        return nil
    }

    /// Write Code replaces the complete captured selection, so the model must receive that same
    /// complete selection. Ask follows the same rule: a partial excerpt would make an apparently
    /// authoritative answer misleading. Refuse before warmup or any source-bearing request.
    private var editorAISelectionPreflightError: ScriptEditorAIRequestError? {
        let sourceText = source as NSString
        guard selectedRange.location >= 0,
              selectedRange.location + selectedRange.length <= sourceText.length else {
            return nil
        }
        let selectedText = sourceText.substring(with: selectedRange)
        let maximum = OllamaCodeCompletionLimits.default.selectionCharacters
        guard selectedText.count > maximum else { return nil }
        return .selectionTooLarge(maximumCharacters: maximum)
    }

    private var currentAIAuthoringContext: OllamaCodeCompletionAuthoringContext {
        let graph = game.scriptingCommandContext().graph
        let supportsFurnaceOutput = isLoadedFurnaceFamilyBlock(target, graph: graph)
        let applicableBuiltIns = ScriptLanguageSchema.attributes(for: target.kind).filter { attribute in
            guard let targetApplicableBuiltInAttributes else { return true }
            return targetApplicableBuiltInAttributes.contains(attribute.name)
        }
        var members = ScriptLanguageSchema.handleProperties
            .filter { $0.receiverKinds.isEmpty || $0.receiverKinds.contains(target.kind) }
            .map { "property \($0.name):\($0.valueType.displayName)" }
        members.append(contentsOf: ScriptLanguageSchema.handleMethods
            .filter {
                ($0.receiverKinds.isEmpty || $0.receiverKinds.contains(target.kind))
                    && $0.availability.isCompletable
                    && ($0.name != "setFurnaceOutput" || supportsFurnaceOutput)
            }
            .map { symbol in
                let label = symbol.signatures.first?.label ?? symbol.name
                guard let receiverEnd = label.firstIndex(of: ":") else {
                    return "method \(label)"
                }
                return "method self\(label[receiverEnd...])"
            })
        members.append(contentsOf: applicableBuiltIns.map {
            "attribute \($0.name):\($0.type.displayName):\($0.mutability == .readOnly ? "read_only" : "writable")"
        })
        members.append(contentsOf: targetCustomAttributeCompletions.map {
            "custom_attribute \($0.name):\($0.typeName):\($0.isReadOnly ? "read_only" : "writable")"
        })
        let eventName = mode == .handler
            ? handlerEvent.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let broadlyCompatibleEventCandidates = mode == .module
            ? ScriptEditorEventCatalog.broadlyAvailableCandidates(
                including: handlerEventCandidates
            )
            : handlerEventCandidates
        let eventCandidates = broadlyCompatibleEventCandidates.filter { candidate in
            mode == .module
                || candidate.name != EventKind.furnaceSmeltCompleted.rawValue
                || supportsFurnaceOutput
        }
        var compatibleEvents = eventCandidates.map(aiEvent)
        if mode == .handler,
           let eventName, !eventName.isEmpty,
           handlerEventValidationError == nil,
           !eventCandidates.contains(where: { $0.name == eventName }) {
            compatibleEvents.insert(
                OllamaCodeCompletionAuthoringEvent(
                    name: eventName,
                    source: "open_custom_selected",
                    payloadFields: [],
                    summary: "Valid undeclared custom event on the current target; only the common envelope is known.",
                    payloadContract: "open_custom_unknown_envelope_only"
                ),
                at: 0
            )
        }
        return OllamaCodeCompletionAuthoringContext(
            targetReference: target.canonical,
            targetKind: target.kind.rawValue,
            scriptMode: mode.rawValue,
            modeContract: ScriptEditorAuthoringContract.modeHelp(mode),
            selectedEvent: eventName?.isEmpty == false ? eventName : nil,
            compatibleEvents: compatibleEvents,
            targetMembers: members
        )
    }

    /// Event descriptors are kind-wide, but furnace completion and output control require the
    /// stricter runtime applicability predicate. Keep the editor AI's positive facts aligned with
    /// the actual loaded block entity instead of advertising a never-working ordinary-block API.
    private func aiBuiltInEventIsApplicable(
        _ event: EventKind,
        to ref: ObjectRef,
        graph: ObjectGraph
    ) -> Bool {
        event != .furnaceSmeltCompleted || isLoadedFurnaceFamilyBlock(ref, graph: graph)
    }

    private func isLoadedFurnaceFamilyBlock(_ ref: ObjectRef, graph: ObjectGraph) -> Bool {
        guard case .live(.block(let world, _, _, let x, let y, let z)) = graph.resolve(ref),
              let blockEntity = world.getBlockEntity(x, y, z),
              blockEntity.type == "furnace",
              ["furnace", "blast", "smoker"].contains(blockEntity.kind ?? "furnace"),
              [
                  Int(B.furnace), Int(B.furnace_lit), Int(B.blast_furnace),
                  Int(B.blast_furnace_lit), Int(B.smoker), Int(B.smoker_lit),
              ].contains(world.getBlockId(x, y, z)) else { return false }
        return true
    }

    private func aiEvent(
        _ event: ScriptEditorEventCandidate
    ) -> OllamaCodeCompletionAuthoringEvent {
        OllamaCodeCompletionAuthoringEvent(
            name: event.name,
            source: event.source.rawValue,
            payloadFields: event.payload.map {
                $0.name + ":" + $0.type.displayName + ($0.isNullable ? "?" : "")
            },
            summary: event.summary
        )
    }

    func aiInsertionPreflightFailure(_ insertion: String) -> String? {
        guard !insertion.isEmpty, ScriptingDisplayText.isValidScriptSource(insertion) else {
            return "AI proposal refused: Ollama returned text that cannot be inserted safely."
        }
        let current = source as NSString
        guard selectedRange.location >= 0,
              selectedRange.location + selectedRange.length <= current.length else {
            return "AI proposal refused: the editor selection changed before insertion."
        }
        let merged = current.replacingCharacters(in: selectedRange, with: insertion)
        guard merged.utf8.count <= 16_384, ScriptingDisplayText.isValidScriptSource(merged) else {
            return "AI proposal refused: the resulting script would exceed the source limit or contain invalid text."
        }
        let diagnostics = LuaLanguageService.analyze(
            source: merged,
            environment: languageEnvironment
        ).diagnostics
        if let violation = diagnostics.first(where: {
            $0.id.hasPrefix("handler-subscription-wrapper:")
                || $0.id.hasPrefix("module-top-level-ev:")
                || ($0.id.hasPrefix("unavailable:") && $0.message.contains("'h'"))
        }) {
            return "AI proposal refused: \(violation.message)"
        }
        return nil
    }

    /// Whether inserting `insertion` at the current selection yields Lua that PARSES.
    ///
    /// This is used ONLY by the chat-salvage path (``insertableProposal``) to strip trailing prose;
    /// it is deliberately kept out of ``aiInsertionPreflightFailure`` so the shared inline
    /// ghost-text completion path still offers a valid in-progress completion that only parses once
    /// the surrounding edit is finished. It is a pure syntax check (``ScriptRuntime/validateSource``),
    /// never a dry run, so a shape-valid body passes even when its object is unloaded. When no
    /// runtime is available (e.g. a guest session) the check cannot run and is treated as passing.
    private func mergedProposalParses(_ insertion: String) -> Bool {
        guard let runtime = game.scriptingCommandContext().scriptRuntime else { return true }
        let current = source as NSString
        guard selectedRange.location >= 0,
              selectedRange.location + selectedRange.length <= current.length else { return false }
        let merged = current.replacingCharacters(in: selectedRange, with: insertion)
        if case .refused = runtime.validateSource(merged, chunkName: "ai-proposal") { return false }
        return true
    }

    /// Extracts the insertable Lua from a raw Script-AI chat reply.
    ///
    /// The panel asks the model for code only, but it occasionally appends an explanatory sentence
    /// after the code (\"Note: ...\"). Inserted verbatim, that trailing prose is a syntax error — the
    /// exact failure a Birch Button script hit. This unwraps a Markdown fence when present, then
    /// drops only a clearly labeled explanatory suffix until the remaining prefix is non-empty, passes
    /// ``aiInsertionPreflightFailure`` (safe text, size, mode-contract diagnostics), and parses as
    /// Lua once merged (``mergedProposalParses``), so a code-plus-prose reply still yields its code.
    /// A suffix that still looks like Lua is never discarded to make an unsafe partial proposal
    /// insertable. Returns nil when no complete safe prefix is available.
    func insertableProposal(from rawReply: String) -> String? {
        let fenceParts = Self.proposalFenceParts(rawReply)
        let exterior = fenceParts.exterior.trimmingCharacters(in: .whitespacesAndNewlines)
        guard exterior.isEmpty || Self.isClearlyExplanatoryText(exterior) else { return nil }
        var lines = fenceParts.code
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var removedLines: [String] = []
        while !lines.isEmpty {
            let candidate = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let removedSuffix = removedLines.joined(separator: "\n")
            if !candidate.isEmpty,
               (removedLines.isEmpty || Self.isClearlyExplanatoryText(removedSuffix)),
               aiInsertionPreflightFailure(candidate) == nil,
               mergedProposalParses(candidate) {
                return candidate
            }
            removedLines.insert(lines.removeLast(), at: 0)
        }
        return nil
    }

    private static func isClearlyExplanatoryText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = ["Note:", "Explanation:"]
        let body: String
        if let label = labels.first(where: { trimmed.hasPrefix($0) }) {
            body = String(trimmed.dropFirst(label.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            body = trimmed
            guard body.first?.isUppercase == true,
                  body.contains(where: { $0.isWhitespace }),
                  body.last.map({ ".!?:".contains($0) }) == true else { return false }
        }
        return !body.isEmpty && !appearsToContainLua(body)
    }

    /// Applies an instruction-driven Script AI reply as one editor transaction. Inline and On
    /// Idle proposals deliberately do not use this path; they remain ghost text requiring an
    /// explicit accept action. The current mode/event and captured selection are app authority —
    /// model text can never switch destinations, Save, Run, or enable script execution.
    func applyEditorAIReply(_ rawReply: String) -> ScriptEditorAIApplyOutcome {
        guard let insertion = insertableProposal(from: rawReply) else {
            if Self.appearsToContainLua(rawReply) {
                return .refused(
                    "AI proposal was left in the transcript because it did not contain valid, insertable Lua."
                )
            }
            return .answerOnly
        }
        if let refusal = automaticAIInsertionFailure(insertion) {
            return .refused(refusal)
        }

        let replacedRange = selectedRange
        let fenceParts = Self.proposalFenceParts(rawReply)
        let normalizedReply = fenceParts.code
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let omittedTrailingText = normalizedReply != insertion
            || !fenceParts.exterior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let destinationMode = mode
        let destinationEvent = destinationMode == .handler
            ? handlerEvent.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        insertAtCursor(insertion)
        let receipt = ScriptEditorAIInsertionReceipt(
            mode: destinationMode,
            eventName: destinationEvent,
            replacedRange: replacedRange,
            insertedUTF16Length: (insertion as NSString).length,
            omittedTrailingText: omittedTrailingText
        )
        status = "AI inserted validated Lua into \(receipt.destinationDescription). Review it, then use Check before Save."
        statusIsError = false
        return .inserted(receipt)
    }

    private func automaticAIInsertionFailure(_ insertion: String) -> String? {
        if let refusal = aiInsertionPreflightFailure(insertion) { return refusal }
        guard !isLANGuest,
              let runtime = game.scriptingCommandContext().scriptRuntime else {
            return "AI proposal was left in the transcript because automatic insertion requires the local authoritative Lua validator."
        }

        let current = source as NSString
        guard selectedRange.location >= 0,
              selectedRange.location + selectedRange.length <= current.length else {
            return "AI proposal was left in the transcript because the editor selection changed."
        }
        let merged = current.replacingCharacters(in: selectedRange, with: insertion)
        switch runtime.validateSourceForEditor(
            merged,
            chunkName: currentName.isEmpty ? "ai-proposal" : currentName
        ).outcome {
        case .accepted:
            break
        case .refused(_, let message, let hint, _):
            let detail = hint.isEmpty ? message : "\(message) — \(hint)"
            return "AI proposal was left in the transcript: \(detail)"
        }

        let diagnostics = LuaLanguageService.analyze(
            source: merged,
            environment: languageEnvironment
        ).diagnostics
        if let blocking = diagnostics.first(where: { diagnostic in
            diagnostic.severity == .error
                || diagnostic.id.hasPrefix("unknown-member:")
                || diagnostic.id.hasPrefix("target-event:")
                || diagnostic.id.hasPrefix("reserved-event:")
        }) {
            return "AI proposal was left in the transcript: \(blocking.message)"
        }
        // Run both comparisons. Whole-document counts catch a rewrite that removes a declaration
        // needed by the unchanged suffix. Prefix-only counts prevent the inverse trick where a
        // selected rewrite "pays for" a newly introduced unresolved call by deleting an old one.
        // In both cases, unchanged pre-existing dynamic calls remain neutral.
        let unchangedPrefix = current.substring(to: selectedRange.location)
        let proposalContext = unchangedPrefix + insertion
        let prefixUnsupportedCall = Self.firstAdditionalUnsupportedAutomaticAICall(
            baseline: unchangedPrefix,
            candidate: proposalContext
        )
        let wholeDocumentUnsupportedCall = Self.firstAdditionalUnsupportedAutomaticAICall(
            baseline: source,
            candidate: merged
        )
        if let unsupportedCall = prefixUnsupportedCall ?? wholeDocumentUnsupportedCall {
            return "AI proposal was left in the transcript: '\(unsupportedCall)' cannot be proven to be a shipped function or a statically known call target."
        }
        let prefixUnresolvedRead = Self.firstAdditionalUnresolvedAutomaticAIGlobalRead(
            baseline: unchangedPrefix,
            candidate: proposalContext,
            allowsImplicitEvent: mode == .handler
        )
        let wholeDocumentUnresolvedRead = Self.firstAdditionalUnresolvedAutomaticAIGlobalRead(
            baseline: source,
            candidate: merged,
            allowsImplicitEvent: mode == .handler
        )
        if let unresolvedRead = prefixUnresolvedRead ?? wholeDocumentUnresolvedRead {
            return "AI proposal was left in the transcript: '\(unresolvedRead)' is an unresolved global read."
        }
        let existingEnvironmentReferences = Self.automaticAIEnvironmentReferenceCount(
            in: unchangedPrefix
        )
        if Self.automaticAIEnvironmentReferenceCount(in: proposalContext) > existingEnvironmentReferences {
            return "AI proposal was left in the transcript: automatic insertion cannot introduce dynamic _ENV access."
        }

        let selectedEvent = mode == .handler
            ? EventKind.parse(handlerEvent.trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        switch runtime.dryRunOutcome(
            source: merged,
            owner: target,
            mode: mode,
            handlerEvent: selectedEvent,
            handlerSubject: mode == .handler ? target : nil,
            handlerSubjectIsExact: true
        ) {
        case .completed, .suspended, .compiledOnly:
            return nil
        case .failure(let message):
            return "AI proposal was left in the transcript: mutation-free Check found \(message)"
        }
    }

    private static func appearsToContainLua(_ text: String) -> Bool {
        let tokens = LuaSourceScanner.tokens(in: text)
        if tokens.contains(where: { $0.kind == .keyword }) { return true }
        if text.contains("```") || text.contains("--") { return true }

        func nextSignificantIndex(after index: Int) -> Int? {
            var cursor = index + 1
            while cursor < tokens.count {
                if tokens[cursor].kind != .newline { return cursor }
                cursor += 1
            }
            return nil
        }

        for index in tokens.indices {
            guard let next = nextSignificantIndex(after: index) else { continue }
            if tokens[index].kind == .identifier {
                if ["(", ":", "=", "[", "{"].contains(tokens[next].text)
                    || tokens[next].kind == .string {
                    return true
                }
                if tokens[next].text == ".",
                   let member = nextSignificantIndex(after: next),
                   tokens[member].kind == .identifier {
                    return true
                }
            }
            if [")", "]", "}", "end"].contains(tokens[index].text),
               ["(", "{"].contains(tokens[next].text) || tokens[next].kind == .string {
                return true
            }
        }
        return false
    }

    /// Automatic insertion is intentionally stricter than ordinary authoring. A mutation-free
    /// dry run stops at the first legal wait/await, so an invented global call after that boundary
    /// would otherwise escape runtime validation. Permit the shipped Lua/Elysium globals and
    /// simple top-level helper functions declared before use; more dynamic call graphs remain in
    /// the transcript for deliberate review and manual insertion.
    private static func firstAdditionalUnsupportedAutomaticAICall(
        baseline: String,
        candidate: String
    ) -> String? {
        let baselineCalls = unsupportedAutomaticAIBareCalls(in: baseline)
        let candidateCalls = unsupportedAutomaticAIBareCalls(in: candidate)
        let baselineCounts = Dictionary(
            baselineCalls.map { ($0, 1) },
            uniquingKeysWith: +
        )
        let candidateCounts = Dictionary(
            candidateCalls.map { ($0, 1) },
            uniquingKeysWith: +
        )
        return candidateCalls.first(where: {
            candidateCounts[$0, default: 0] > baselineCounts[$0, default: 0]
        })
    }

    private static func unsupportedAutomaticAIBareCalls(in source: String) -> [String] {
        enum Block: Equatable {
            case function
            case branch
            case scoped
            case repeatLoop
        }

        let tokens = LuaSourceScanner.tokens(in: source)
        let allowedGlobals = Set(
            (ScriptLanguageSchema.luaBaseGlobals + ScriptLanguageSchema.engineGlobals)
                .filter { $0.kind == .globalFunction }
                .map(\.name)
        )
        let allowedReceiverRoots = Set(
            (ScriptLanguageSchema.implicitLocals + ScriptLanguageSchema.modules).map(\.name)
        )
        let protectedBuiltInNames = allowedGlobals.union(allowedReceiverRoots)
        var topLevelHelpers: Set<String> = []
        var safeTopLevelReceivers: Set<String> = []
        var shadowedBuiltInNames: Set<String> = []
        var blocks: [Block] = []
        var unsupported: [String] = []
        var expressionDelimiterDepth = 0

        func previousSignificantIndex(before index: Int) -> Int? {
            guard index > 0 else { return nil }
            var cursor = index - 1
            while cursor >= 0 {
                if tokens[cursor].kind != .newline { return cursor }
                cursor -= 1
            }
            return nil
        }

        func nextSignificantIndex(after index: Int) -> Int? {
            var cursor = index + 1
            while cursor < tokens.count {
                if tokens[cursor].kind != .newline { return cursor }
                cursor += 1
            }
            return nil
        }

        func isCallArgumentStart(_ index: Int) -> Bool {
            tokens[index].text == "(" || tokens[index].text == "{" ||
                tokens[index].kind == .string
        }

        func identifierIsCalled(at index: Int) -> Bool {
            if let next = nextSignificantIndex(after: index), isCallArgumentStart(next) {
                return true
            }
            guard var left = previousSignificantIndex(before: index),
                  var right = nextSignificantIndex(after: index),
                  tokens[left].text == "(", tokens[right].text == ")" else {
                return false
            }
            while true {
                guard let afterRight = nextSignificantIndex(after: right) else { return false }
                if isCallArgumentStart(afterRight) { return true }
                guard tokens[afterRight].text == ")",
                      let beforeLeft = previousSignificantIndex(before: left),
                      tokens[beforeLeft].text == "(" else {
                    return false
                }
                left = beforeLeft
                right = afterRight
            }
        }

        func rootReceiver(before operatorIndex: Int) -> String? {
            guard var root = previousSignificantIndex(before: operatorIndex),
                  tokens[root].kind == .identifier else { return nil }
            while let join = previousSignificantIndex(before: root),
                  tokens[join].text == "." || tokens[join].text == ":",
                  let earlier = previousSignificantIndex(before: join),
                  tokens[earlier].kind == .identifier {
                root = earlier
            }
            return tokens[root].text
        }

        func expressionIndices(startingAt start: Int) -> [Int] {
            var result: [Int] = []
            var delimiterDepth = 0
            var cursor = start
            while cursor < tokens.count {
                let token = tokens[cursor]
                if delimiterDepth == 0,
                   token.kind == .newline || token.text == ";" {
                    break
                }
                result.append(cursor)
                if ["(", "[", "{"].contains(token.text) {
                    delimiterDepth += 1
                } else if [")", "]", "}"].contains(token.text) {
                    delimiterDepth = max(0, delimiterDepth - 1)
                }
                cursor += 1
            }
            return result
        }

        func isExactCall(_ expression: [Int], head: [String]) -> Bool {
            guard expression.count >= head.count + 2 else { return false }
            for (offset, expected) in head.enumerated()
                where tokens[expression[offset]].text != expected {
                return false
            }
            guard tokens[expression[head.count]].text == "(" else { return false }
            var parenthesisDepth = 0
            for offset in head.count..<expression.count {
                switch tokens[expression[offset]].text {
                case "(":
                    parenthesisDepth += 1
                case ")":
                    parenthesisDepth -= 1
                    if parenthesisDepth == 0 {
                        return offset == expression.count - 1
                    }
                    if parenthesisDepth < 0 { return false }
                default:
                    break
                }
            }
            return false
        }

        func expressionContinuesAfterLineBreak(_ expression: [Int]) -> Bool {
            guard let last = expression.last, last + 1 < tokens.count,
                  tokens[last + 1].kind == .newline,
                  let next = nextSignificantIndex(after: last) else { return false }
            let continuationTokens: Set<String> = [
                "and", "or", "+", "-", "*", "/", "//", "%", "^", "..",
                "==", "~=", "<", ">", "<=", ">=", ".", ":", "[", "(", "{",
            ]
            return continuationTokens.contains(tokens[next].text)
                || tokens[next].kind == .string
        }

        func identifierIsAssignmentTarget(at index: Int) -> Bool {
            // A syntactic identifier inside a table/index/call expression is not a variable
            // binding even when followed by `=` (for example `{ gate = value }`).
            guard expressionDelimiterDepth == 0,
                  let next = nextSignificantIndex(after: index) else { return false }
            if tokens[next].text == "=" { return true }
            guard tokens[next].text == "," else { return false }

            // Handle the first element of a multiple assignment (`gate, other = ...`). Stop at a
            // real statement boundary; malformed or more complex syntax is refused elsewhere.
            var cursor = next + 1
            var delimiterDepth = 0
            while cursor < tokens.count {
                let token = tokens[cursor]
                if delimiterDepth == 0, token.text == ";" {
                    return false
                }
                if ["(", "[", "{"].contains(token.text) {
                    delimiterDepth += 1
                } else if [")", "]", "}"].contains(token.text) {
                    delimiterDepth = max(0, delimiterDepth - 1)
                } else if delimiterDepth == 0, token.text == "=" {
                    return true
                } else if delimiterDepth == 0,
                          ["then", "do", "end", "until"].contains(token.text) {
                    return false
                }
                cursor += 1
            }
            return false
        }

        func functionParameterNames(after functionIndex: Int) -> [String] {
            var cursor = functionIndex + 1
            while cursor < tokens.count, tokens[cursor].text != "(" {
                cursor += 1
            }
            guard cursor < tokens.count, tokens[cursor].text == "(" else { return [] }
            var names: [String] = []
            var depth = 1
            cursor += 1
            while cursor < tokens.count, depth > 0 {
                switch tokens[cursor].text {
                case "(":
                    depth += 1
                case ")":
                    depth -= 1
                default:
                    if depth == 1, tokens[cursor].kind == .identifier {
                        names.append(tokens[cursor].text)
                    }
                }
                cursor += 1
            }
            return names
        }

        func localNames(after localIndex: Int) -> [String] {
            guard let first = nextSignificantIndex(after: localIndex),
                  tokens[first].text != "function" else { return [] }
            var names: [String] = []
            var cursor = first
            while cursor < tokens.count {
                guard tokens[cursor].kind == .identifier else { break }
                names.append(tokens[cursor].text)
                guard let separator = nextSignificantIndex(after: cursor),
                      tokens[separator].text == ",",
                      let nextName = nextSignificantIndex(after: separator) else { break }
                cursor = nextName
            }
            return names
        }

        func loopNames(after forIndex: Int) -> [String] {
            var names: [String] = []
            guard let first = nextSignificantIndex(after: forIndex) else { return names }
            var cursor = first
            while cursor < tokens.count {
                guard tokens[cursor].kind == .identifier else { break }
                names.append(tokens[cursor].text)
                guard let separator = nextSignificantIndex(after: cursor),
                      tokens[separator].text == ",",
                      let nextName = nextSignificantIndex(after: separator) else { break }
                cursor = nextName
            }
            return names
        }

        func callArgumentGroups(openingAt openIndex: Int) -> [[Int]] {
            enum ArgumentBlock: Equatable {
                case function
                case branch
                case scoped
                case repeatLoop
            }

            var groups: [[Int]] = [[]]
            var delimiters = ["("]
            var argumentBlocks: [ArgumentBlock] = []
            var cursor = openIndex + 1
            while cursor < tokens.count {
                let token = tokens[cursor]
                if token.text == "elseif", argumentBlocks.last == .branch {
                    argumentBlocks.removeLast()
                }
                if token.text == ")", delimiters.count == 1, argumentBlocks.isEmpty {
                    return groups
                }
                if token.text == ",", delimiters.count == 1, argumentBlocks.isEmpty {
                    groups.append([])
                    cursor += 1
                    continue
                }
                if token.kind != .newline { groups[groups.count - 1].append(cursor) }

                switch token.text {
                case "(", "[", "{":
                    delimiters.append(token.text)
                case ")", "]", "}":
                    if delimiters.count > 1 { delimiters.removeLast() }
                case "function":
                    argumentBlocks.append(.function)
                case "then":
                    argumentBlocks.append(.branch)
                case "do":
                    argumentBlocks.append(.scoped)
                case "repeat":
                    argumentBlocks.append(.repeatLoop)
                case "end":
                    if !argumentBlocks.isEmpty { argumentBlocks.removeLast() }
                case "until":
                    if argumentBlocks.last == .repeatLoop { argumentBlocks.removeLast() }
                default:
                    break
                }
                cursor += 1
            }
            return groups
        }

        func isStaticallyKnownFunction(_ group: [Int]) -> Bool {
            guard let first = group.first else { return false }
            if tokens[first].text == "function" { return true }
            guard group.count == 1, tokens[first].kind == .identifier else { return false }
            let name = tokens[first].text
            return topLevelHelpers.contains(name)
                || (allowedGlobals.contains(name) && !shadowedBuiltInNames.contains(name))
        }

        enum CallableArgumentPolicy {
            case function
            case functionOrHandlerName
            case functionStringOrTable
        }

        func callableArgumentIsKnown(_ group: [Int], policy: CallableArgumentPolicy) -> Bool {
            if isStaticallyKnownFunction(group) { return true }
            guard let first = group.first else { return false }
            switch policy {
            case .function:
                return false
            case .functionOrHandlerName:
                return group.count == 1 && tokens[first].kind == .string
            case .functionStringOrTable:
                return (group.count == 1 && tokens[first].kind == .string)
                    || (tokens[first].text == "{" && group.last.map { tokens[$0].text } == "}")
            }
        }

        func unprovenCallableArgument(
            callName: String,
            receiverRoot: String?,
            groups: [[Int]]
        ) -> String? {
            var requirements: [(Int, CallableArgumentPolicy)] = []
            if receiverRoot == nil {
                switch callName {
                case "after", "every":
                    requirements = [(1, .functionOrHandlerName)]
                case "on", "subscribe":
                    if !groups.isEmpty { requirements = [(groups.count - 1, .function)] }
                case "register":
                    requirements = [(1, .function)]
                case "pcall":
                    requirements = [(0, .function)]
                case "xpcall":
                    requirements = [(0, .function), (1, .function)]
                default:
                    break
                }
            } else {
                switch (receiverRoot, callName) {
                case (_, "on"):
                    if !groups.isEmpty { requirements = [(groups.count - 1, .function)] }
                case (_, "onAttribute"):
                    requirements = [(1, .function)]
                case ("table", "sort") where groups.count >= 2:
                    requirements = [(1, .function)]
                case ("string", "gsub") where groups.count >= 3:
                    requirements = [(2, .functionStringOrTable)]
                default:
                    break
                }
            }

            for (position, policy) in requirements {
                guard position < groups.count,
                      callableArgumentIsKnown(groups[position], policy: policy) else {
                    return "unproven callable argument for \(callName)"
                }
            }
            return nil
        }

        func genericForIteratorIsKnown(after inIndex: Int) -> Bool {
            guard let first = nextSignificantIndex(after: inIndex) else { return false }
            var expression: [Int] = []
            var delimiters: [String] = []
            var cursor = first
            while cursor < tokens.count {
                let token = tokens[cursor]
                if delimiters.isEmpty, token.text == "," || token.text == "do" { break }
                if token.kind != .newline { expression.append(cursor) }
                switch token.text {
                case "(", "[", "{":
                    delimiters.append(token.text)
                case ")", "]", "}":
                    if !delimiters.isEmpty { delimiters.removeLast() }
                default:
                    break
                }
                cursor += 1
            }
            guard !expression.isEmpty else { return false }
            var headOffset = 0
            guard tokens[expression[headOffset]].kind == .identifier else {
                return isStaticallyKnownFunction(expression)
            }
            headOffset += 1
            while headOffset + 1 < expression.count,
                  [".", ":"].contains(tokens[expression[headOffset]].text),
                  tokens[expression[headOffset + 1]].kind == .identifier {
                headOffset += 2
            }
            if headOffset < expression.count,
               tokens[expression[headOffset]].text == "(" {
                var parenthesisDepth = 0
                var closesAtEnd = false
                for offset in headOffset..<expression.count {
                    switch tokens[expression[offset]].text {
                    case "(":
                        parenthesisDepth += 1
                    case ")":
                        parenthesisDepth -= 1
                        if parenthesisDepth == 0 {
                            closesAtEnd = offset == expression.count - 1
                            break
                        }
                    default:
                        break
                    }
                    if closesAtEnd { break }
                }
                guard closesAtEnd else { return false }
                // The ordinary call/member gate validates the explicit factory invocation.
                return true
            }
            return isStaticallyKnownFunction(expression)
        }

        for index in tokens.indices {
            let token = tokens[index]

            if token.text == "elseif", blocks.last == .branch {
                blocks.removeLast()
            }

            if token.text == "function" {
                let parameterNames = functionParameterNames(after: index)
                for name in parameterNames {
                    safeTopLevelReceivers.remove(name)
                    topLevelHelpers.remove(name)
                    if protectedBuiltInNames.contains(name) {
                        shadowedBuiltInNames.insert(name)
                    }
                }
                if blocks.isEmpty, let nameIndex = nextSignificantIndex(after: index),
                   tokens[nameIndex].kind == .identifier,
                   let openIndex = nextSignificantIndex(after: nameIndex),
                   tokens[openIndex].text == "(" {
                    let name = tokens[nameIndex].text
                    if protectedBuiltInNames.contains(name) {
                        shadowedBuiltInNames.insert(name)
                    }
                    safeTopLevelReceivers.remove(name)
                    topLevelHelpers.remove(name)
                    if !parameterNames.contains(name) {
                        topLevelHelpers.insert(name)
                    }
                } else if blocks.isEmpty,
                          let equalsIndex = previousSignificantIndex(before: index),
                          tokens[equalsIndex].text == "=",
                          let nameIndex = previousSignificantIndex(before: equalsIndex),
                          tokens[nameIndex].kind == .identifier,
                          let localIndex = previousSignificantIndex(before: nameIndex),
                          tokens[localIndex].text == "local" {
                    let name = tokens[nameIndex].text
                    if protectedBuiltInNames.contains(name) {
                        shadowedBuiltInNames.insert(name)
                    }
                    safeTopLevelReceivers.remove(name)
                    topLevelHelpers.remove(name)
                    if !parameterNames.contains(name) {
                        topLevelHelpers.insert(name)
                    }
                } else if let nameIndex = nextSignificantIndex(after: index),
                          tokens[nameIndex].kind == .identifier {
                    let name = tokens[nameIndex].text
                    safeTopLevelReceivers.remove(name)
                    topLevelHelpers.remove(name)
                    if protectedBuiltInNames.contains(name) {
                        shadowedBuiltInNames.insert(name)
                    }
                }
                blocks.append(.function)
                continue
            }

            if token.text == "local" {
                for name in localNames(after: index) {
                    safeTopLevelReceivers.remove(name)
                    topLevelHelpers.remove(name)
                    if protectedBuiltInNames.contains(name) {
                        shadowedBuiltInNames.insert(name)
                    }
                }
            } else if token.text == "for" {
                for name in loopNames(after: index) {
                    safeTopLevelReceivers.remove(name)
                    topLevelHelpers.remove(name)
                    if protectedBuiltInNames.contains(name) {
                        shadowedBuiltInNames.insert(name)
                    }
                }
            }

            if token.text == "local", blocks.isEmpty,
               let nameIndex = nextSignificantIndex(after: index),
               tokens[nameIndex].kind == .identifier {
                let name = tokens[nameIndex].text
                safeTopLevelReceivers.remove(name)
                topLevelHelpers.remove(name)
                if let equalsIndex = nextSignificantIndex(after: nameIndex),
                   tokens[equalsIndex].text == "=",
                   let valueIndex = nextSignificantIndex(after: equalsIndex) {
                    let expression = expressionIndices(startingAt: valueIndex)
                    let expressionIsComplete = !expressionContinuesAfterLineBreak(expression)
                    let isImplicitHandle = expressionIsComplete && expression.count == 1
                        && ["self", "world", "player", "ev"]
                            .contains(tokens[expression[0]].text)
                        && !shadowedBuiltInNames.contains(tokens[expression[0]].text)
                    let isDimensionHandle = expressionIsComplete
                        && !shadowedBuiltInNames.contains("dim")
                        && isExactCall(expression, head: ["dim"])
                    let isObjectLookup = expressionIsComplete && isExactCall(
                        expression,
                        head: ["objects", ".", "get"]
                    ) && !shadowedBuiltInNames.contains("objects")
                    if !protectedBuiltInNames.contains(name),
                       isImplicitHandle || isDimensionHandle || isObjectLookup {
                        safeTopLevelReceivers.insert(name)
                    }
                }
            }

            if token.kind == .identifier,
               identifierIsAssignmentTarget(at: index) {
                let previous = previousSignificantIndex(before: index)
                    .map { tokens[$0].text }
                if previous != "local", previous != "function" {
                    safeTopLevelReceivers.remove(token.text)
                    topLevelHelpers.remove(token.text)
                    if protectedBuiltInNames.contains(token.text) {
                        shadowedBuiltInNames.insert(token.text)
                    }
                }
            }

            if isCallArgumentStart(index),
               let calleeEnd = previousSignificantIndex(before: index),
               ["]", "}", ")", "end"].contains(tokens[calleeEnd].text) {
                unsupported.append("computed call target")
            }

            if token.text == "in", !genericForIteratorIsKnown(after: index) {
                unsupported.append("unproven generic-for iterator")
            }

            if token.kind == .identifier, identifierIsCalled(at: index) {
                let previousIndex = previousSignificantIndex(before: index)
                let previous = previousIndex.map { tokens[$0].text }
                let isDeclaration = previous == "function"
                let isMember = previous == "." || previous == ":"
                let receiverRoot = isMember && previousIndex != nil
                    ? rootReceiver(before: previousIndex!)
                    : nil
                if let openIndex = nextSignificantIndex(after: index),
                   tokens[openIndex].text == "(",
                   let callableFailure = unprovenCallableArgument(
                    callName: token.text,
                    receiverRoot: receiverRoot,
                    groups: callArgumentGroups(openingAt: openIndex)
                   ) {
                    unsupported.append(callableFailure)
                }
                if isMember, let previousIndex {
                    guard let root = rootReceiver(before: previousIndex),
                          (allowedReceiverRoots.contains(root)
                            && !shadowedBuiltInNames.contains(root))
                            || safeTopLevelReceivers.contains(root) else {
                        unsupported.append(rootReceiver(before: previousIndex) ?? "computed member call")
                        continue
                    }
                } else if !isDeclaration,
                          (!allowedGlobals.contains(token.text)
                            || shadowedBuiltInNames.contains(token.text)),
                          !topLevelHelpers.contains(token.text) {
                    unsupported.append(token.text)
                }
            }

            switch token.text {
            case "then":
                blocks.append(.branch)
            case "do":
                blocks.append(.scoped)
            case "repeat":
                blocks.append(.repeatLoop)
            case "end":
                if !blocks.isEmpty { blocks.removeLast() }
            case "until":
                if blocks.last == .repeatLoop { blocks.removeLast() }
            default:
                break
            }
            if ["(", "[", "{"].contains(token.text) {
                expressionDelimiterDepth += 1
            } else if [")", "]", "}"].contains(token.text) {
                expressionDelimiterDepth = max(0, expressionDelimiterDepth - 1)
            }
        }
        return unsupported
    }

    private static func firstAdditionalUnresolvedAutomaticAIGlobalRead(
        baseline: String,
        candidate: String,
        allowsImplicitEvent: Bool
    ) -> String? {
        let baselineReads = unresolvedAutomaticAIGlobalReads(
            in: baseline,
            allowsImplicitEvent: allowsImplicitEvent
        )
        let candidateReads = unresolvedAutomaticAIGlobalReads(
            in: candidate,
            allowsImplicitEvent: allowsImplicitEvent
        )
        let baselineCounts = Dictionary(
            baselineReads.map { ($0, 1) },
            uniquingKeysWith: +
        )
        let candidateCounts = Dictionary(
            candidateReads.map { ($0, 1) },
            uniquingKeysWith: +
        )
        return candidateReads.first(where: {
            candidateCounts[$0, default: 0] > baselineCounts[$0, default: 0]
        })
    }

    /// Conservative lexical existence check for automatic AI edits. The normal editor remains
    /// error tolerant and permits arbitrary user globals; auto-insertion has a narrower contract:
    /// an identifier read must resolve to a shipped name or a declaration visible in its Lua
    /// lexical block. Member names, table keys, labels, and declaration sites are not reads.
    private static func unresolvedAutomaticAIGlobalReads(
        in source: String,
        allowsImplicitEvent: Bool
    ) -> [String] {
        enum ScopeKind {
            case chunk
            case function
            case branch
            case scoped
            case repeatLoop
        }
        struct Scope {
            let kind: ScopeKind
            var names: Set<String>
        }
        struct Delimiter {
            let text: String
            let scopeDepth: Int
        }
        struct PendingLocalActivation {
            let scopeIndex: Int
            let names: Set<String>
        }

        let tokens = LuaSourceScanner.tokens(in: source)
        var shippedNames = Set(
            ScriptLanguageSchema.allSymbols
                .filter { $0.parent == nil }
                .map(\.name)
        ).union(["self", "world", "player"])
        if allowsImplicitEvent {
            shippedNames.insert("ev")
        } else {
            shippedNames.remove("ev")
        }
        var scopes = [Scope(kind: .chunk, names: [])]
        var delimiters: [Delimiter] = []
        var declarationIndices: Set<Int> = []
        var forNamesByDoIndex: [Int: [String]] = [:]
        var localActivationsByIndex: [Int: [PendingLocalActivation]] = [:]
        var unresolved: [String] = []

        func previousSignificantIndex(before index: Int) -> Int? {
            guard index > 0 else { return nil }
            var cursor = index - 1
            while cursor >= 0 {
                if tokens[cursor].kind != .newline { return cursor }
                cursor -= 1
            }
            return nil
        }

        func nextSignificantIndex(after index: Int) -> Int? {
            var cursor = index + 1
            while cursor < tokens.count {
                if tokens[cursor].kind != .newline { return cursor }
                cursor += 1
            }
            return nil
        }

        func nameList(startingAt first: Int) -> [Int] {
            var result: [Int] = []
            var cursor = first
            while cursor < tokens.count, tokens[cursor].kind == .identifier {
                result.append(cursor)
                guard let comma = nextSignificantIndex(after: cursor),
                      tokens[comma].text == ",",
                      let nextName = nextSignificantIndex(after: comma) else { break }
                cursor = nextName
            }
            return result
        }

        func localDeclaration(startingAt first: Int) -> (names: [Int], separator: Int?) {
            var names: [Int] = []
            var cursor = first
            while cursor < tokens.count, tokens[cursor].kind == .identifier {
                names.append(cursor)
                guard var separator = nextSignificantIndex(after: cursor) else {
                    return (names, nil)
                }
                if tokens[separator].text == "<",
                   let attributeName = nextSignificantIndex(after: separator),
                   tokens[attributeName].kind == .identifier,
                   let close = nextSignificantIndex(after: attributeName),
                   tokens[close].text == ">" {
                    declarationIndices.insert(attributeName)
                    guard let afterAttribute = nextSignificantIndex(after: close) else {
                        return (names, nil)
                    }
                    separator = afterAttribute
                }
                guard tokens[separator].text == ",",
                      let nextName = nextSignificantIndex(after: separator) else {
                    return (names, separator)
                }
                cursor = nextName
            }
            return (names, cursor < tokens.count ? cursor : nil)
        }

        /// Lua evaluates a normal local declaration's initializer in the surrounding scope and
        /// activates the new names only after that statement. Find a conservative lexical boundary
        /// so `local x = x` never lets the new `x` authorize its own initializer. Newlines inside
        /// delimiters, anonymous functions, or a continued expression remain part of the initializer.
        func localInitializerActivationIndex(after equalsIndex: Int) -> Int {
            enum InitializerBlock: Equatable {
                case function
                case branch
                case scoped
                case repeatLoop
            }

            let infixOrContinuationTokens: Set<String> = [
                "=", ",", "and", "or", "not", "#", "+", "-", "*", "/", "//", "%", "^", "..",
                "==", "~=", "<", ">", "<=", ">=", "&", "|", "~", "<<", ">>",
                ".", ":", "[", "(", "{",
            ]
            var delimiterStack: [String] = []
            var blocks: [InitializerBlock] = []
            var cursor = equalsIndex + 1

            while cursor < tokens.count {
                let token = tokens[cursor]
                if token.text == ";", delimiterStack.isEmpty, blocks.isEmpty {
                    return cursor + 1
                }
                if token.kind == .newline, delimiterStack.isEmpty, blocks.isEmpty {
                    let previous = previousSignificantIndex(before: cursor)
                        .map { tokens[$0] }
                    let next = nextSignificantIndex(after: cursor)
                        .map { tokens[$0] }
                    let previousContinues = previous.map {
                        infixOrContinuationTokens.contains($0.text)
                    } ?? true
                    let nextContinues = next.map {
                        infixOrContinuationTokens.contains($0.text) || $0.kind == .string
                    } ?? false
                    if !previousContinues, !nextContinues {
                        return cursor + 1
                    }
                }

                switch token.text {
                case "(", "[", "{":
                    delimiterStack.append(token.text)
                case ")", "]", "}":
                    if !delimiterStack.isEmpty { delimiterStack.removeLast() }
                case "function":
                    blocks.append(.function)
                case "elseif":
                    if blocks.last == .branch { blocks.removeLast() }
                case "else":
                    if blocks.last == .branch { blocks.removeLast() }
                    blocks.append(.branch)
                case "then":
                    blocks.append(.branch)
                case "do":
                    blocks.append(.scoped)
                case "repeat":
                    blocks.append(.repeatLoop)
                case "end":
                    if !blocks.isEmpty { blocks.removeLast() }
                case "until":
                    if blocks.last == .repeatLoop { blocks.removeLast() }
                default:
                    break
                }
                cursor += 1
            }
            return tokens.count
        }

        func parameterIndices(after functionIndex: Int) -> [Int] {
            var open = functionIndex + 1
            while open < tokens.count, tokens[open].text != "(" { open += 1 }
            guard open < tokens.count else { return [] }
            var result: [Int] = []
            var depth = 1
            var cursor = open + 1
            while cursor < tokens.count, depth > 0 {
                switch tokens[cursor].text {
                case "(": depth += 1
                case ")": depth -= 1
                default:
                    if depth == 1, tokens[cursor].kind == .identifier {
                        result.append(cursor)
                    }
                }
                cursor += 1
            }
            return result
        }

        func firstDoIndex(after forIndex: Int) -> Int? {
            var delimiterDepth = 0
            var cursor = forIndex + 1
            while cursor < tokens.count {
                let token = tokens[cursor]
                if token.text == "do", delimiterDepth == 0 { return cursor }
                if ["(", "[", "{"].contains(token.text) {
                    delimiterDepth += 1
                } else if [")", "]", "}"].contains(token.text) {
                    delimiterDepth = max(0, delimiterDepth - 1)
                }
                cursor += 1
            }
            return nil
        }

        func isVisible(_ name: String) -> Bool {
            shippedNames.contains(name) || scopes.reversed().contains { $0.names.contains(name) }
        }

        func addNames(_ indices: [Int], toScopeAt scopeIndex: Int) {
            for declarationIndex in indices {
                declarationIndices.insert(declarationIndex)
                scopes[scopeIndex].names.insert(tokens[declarationIndex].text)
            }
        }

        for index in tokens.indices {
            let token = tokens[index]

            for activation in localActivationsByIndex[index] ?? []
                where activation.scopeIndex < scopes.count {
                scopes[activation.scopeIndex].names.formUnion(activation.names)
            }

            switch token.text {
            case "elseif":
                if scopes.last?.kind == .branch { scopes.removeLast() }
            case "else":
                if scopes.last?.kind == .branch { scopes.removeLast() }
                scopes.append(Scope(kind: .branch, names: []))
            case "end":
                if scopes.count > 1 { scopes.removeLast() }
            case "until":
                // Popping before the condition is deliberately conservative: a repeat-local read
                // in `until` may remain transcript-only, but no name can leak beyond its block.
                if scopes.last?.kind == .repeatLoop { scopes.removeLast() }
            default:
                break
            }

            if token.text == "local", let first = nextSignificantIndex(after: index) {
                if tokens[first].text == "function",
                   let nameIndex = nextSignificantIndex(after: first),
                   tokens[nameIndex].kind == .identifier {
                    addNames([nameIndex], toScopeAt: scopes.count - 1)
                } else if tokens[first].kind == .identifier {
                    let declaration = localDeclaration(startingAt: first)
                    declarationIndices.formUnion(declaration.names)
                    let activationIndex: Int
                    if let separator = declaration.separator,
                       tokens[separator].text == "=" {
                        activationIndex = localInitializerActivationIndex(after: separator)
                    } else {
                        activationIndex = declaration.separator ?? tokens.count
                    }
                    localActivationsByIndex[activationIndex, default: []].append(
                        PendingLocalActivation(
                            scopeIndex: scopes.count - 1,
                            names: Set(declaration.names.map { tokens[$0].text })
                        )
                    )
                }
            }

            if token.text == "for", let first = nextSignificantIndex(after: index),
               tokens[first].kind == .identifier {
                let names = nameList(startingAt: first)
                declarationIndices.formUnion(names)
                if let doIndex = firstDoIndex(after: index) {
                    forNamesByDoIndex[doIndex] = names.map { tokens[$0].text }
                }
            }

            if token.text == "function" {
                let first = nextSignificantIndex(after: index)
                if let first, tokens[first].kind == .identifier,
                   let afterName = nextSignificantIndex(after: first),
                   tokens[afterName].text == "(" {
                    declarationIndices.insert(first)
                    scopes[scopes.count - 1].names.insert(tokens[first].text)
                }
                let parameters = parameterIndices(after: index)
                declarationIndices.formUnion(parameters)
                scopes.append(Scope(
                    kind: .function,
                    names: Set(parameters.map { tokens[$0].text })
                ))
            }

            if token.kind == .identifier, !declarationIndices.contains(index) {
                let previous = previousSignificantIndex(before: index)
                    .map { tokens[$0].text }
                let next = nextSignificantIndex(after: index)
                    .map { tokens[$0].text }
                let isMemberName = previous == "." || previous == ":"
                let isLabel = previous == "goto" || previous == "::" || next == "::"
                let isLocalAttribute = previous == "<" && next == ">"
                let isTableKey = next == "="
                    && delimiters.last?.text == "{"
                    && delimiters.last?.scopeDepth == scopes.count
                if !isMemberName, !isLabel, !isLocalAttribute, !isTableKey,
                   !isVisible(token.text) {
                    unresolved.append(token.text)
                }
            }

            switch token.text {
            case "then":
                scopes.append(Scope(kind: .branch, names: []))
            case "do":
                scopes.append(Scope(
                    kind: .scoped,
                    names: Set(forNamesByDoIndex[index] ?? [])
                ))
            case "repeat":
                scopes.append(Scope(kind: .repeatLoop, names: []))
            default:
                break
            }

            if ["(", "[", "{"].contains(token.text) {
                delimiters.append(Delimiter(text: token.text, scopeDepth: scopes.count))
            } else if [")", "]", "}"].contains(token.text), !delimiters.isEmpty {
                delimiters.removeLast()
            }
        }
        return unresolved
    }

    private static func automaticAIEnvironmentReferenceCount(in source: String) -> Int {
        LuaSourceScanner.tokens(in: source).count {
            $0.kind == .identifier && $0.text == "_ENV"
        }
    }

    private static func proposalFenceParts(_ raw: String) -> (code: String, exterior: String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard let opening = normalized.range(of: "```") else { return (normalized, "") }
        let afterOpening = normalized[opening.upperBound...]
        guard let lineEnd = afterOpening.firstIndex(of: "\n") else { return (normalized, "") }
        let possibleLanguage = afterOpening[..<lineEnd]
        let codeStart = possibleLanguage.allSatisfy { $0.isLetter || $0 == "_" }
            ? afterOpening.index(after: lineEnd)
            : opening.upperBound
        let remainder = normalized[codeStart...]
        guard let closing = remainder.range(of: "```") else { return (normalized, "") }
        var code = String(remainder[..<closing.lowerBound])
        if code.hasSuffix("\n") { code.removeLast() }
        let leading = String(normalized[..<opening.lowerBound])
        let trailing = String(normalized[closing.upperBound...])
        return (code, [leading, trailing].joined(separator: "\n"))
    }

    /// Returns the contents of the first complete Markdown code fence in `raw`, or `raw` unchanged
    /// when no complete fence is present. Automatic insertion separately validates all text outside
    /// the fence as clearly explanatory and non-Lua before using this code.
    static func unwrapProposalFence(_ raw: String) -> String {
        proposalFenceParts(raw).code
    }

    private func acceptAIFragment(_ split: (String) -> (accepted: String, remainder: String)) {
        guard let suggestion = inlineAISuggestion else { return }
        let parts = split(suggestion)
        guard !parts.accepted.isEmpty else { return }
        isApplyingAISuggestion = true
        inlineAISuggestion = parts.remainder.isEmpty ? nil : parts.remainder
        insertAtCursor(parts.accepted)
        isApplyingAISuggestion = false
    }

    private static func nextLineFragment(_ text: String) -> (accepted: String, remainder: String) {
        guard let newline = text.firstIndex(of: "\n") else { return (text, "") }
        let end = text.index(after: newline)
        return (String(text[..<end]), String(text[end...]))
    }

    private static func nextWordFragment(_ text: String) -> (accepted: String, remainder: String) {
        guard !text.isEmpty else { return ("", "") }
        var end = text.startIndex
        while end < text.endIndex, text[end].isWhitespace { end = text.index(after: end) }
        guard end < text.endIndex else { return (text, "") }
        let first = text[end]
        let isIdentifier = first.isLetter || first.isNumber || first == "_"
        end = text.index(after: end)
        if isIdentifier {
            while end < text.endIndex {
                let character = text[end]
                guard character.isLetter || character.isNumber || character == "_" else { break }
                end = text.index(after: end)
            }
        }
        return (String(text[..<end]), String(text[end...]))
    }

    // MARK: - list / switch / new

    private func beginDocumentTransition() {
        documentIdentity &+= 1
        cancelAIWork(clearSuggestion: true)
        aiSuggestionError = nil
    }

    /// Refreshes `scripts` from either the live `ScriptStore` (host) or the replicated metadata
    /// mirror (guest — name/mode/enabled only, source always empty).
    func reload() {
        guard isCurrentWorldSession else {
            scripts = []
            return
        }
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
        guard requireCurrentWorldSession(for: "switch scripts") else { return }
        if game.isLANClientWorld {
            guard let meta = LANMultiplayerManager.shared.mirroredScripts(for: target)?.first(where: { $0.name == name }) else {
                status = "No replicated data for \"\(name)\" yet."
                statusIsError = true
                return
            }
            beginDocumentTransition()
            currentName = name
            source = ""
            selectedRange = NSRange(location: 0, length: 0)
            mode = ScriptMode(rawValue: meta.mode) ?? .module
            handlerEvent = ""
            errorLine = nil
            isNewScript = false
            status = "editing \"\(name)\" — source isn't visible to guests; Save replaces it"
            statusIsError = false
            markCurrentDocumentClean(savedTriggers: [], savedEnabled: meta.enabled)
            return
        }
        guard let record = game.scriptingCommandContext().scriptStore.get(target, name) else {
            status = "No script '\(name)' on \(target.canonical)"
            statusIsError = true
            return
        }
        beginDocumentTransition()
        currentName = name
        source = record.source
        selectedRange = NSRange(location: 0, length: 0)
        mode = record.mode
        handlerEvent = record.triggers.first?.event.rawValue ?? ""
        errorLine = nil
        isNewScript = false
        status = nil
        statusIsError = false
        markCurrentDocumentClean(savedTriggers: record.triggers, savedEnabled: record.enabled)
    }

    /// Clears the editor back to "authoring a fresh, unnamed script" — the palette/AI-panel still
    /// insert into `source` as usual; Save is what actually creates the record.
    func newScript() {
        guard requireCurrentWorldSession(for: "start another script") else { return }
        beginDocumentTransition()
        currentName = ""
        source = ""
        selectedRange = NSRange(location: 0, length: 0)
        mode = .module
        handlerEvent = ""
        errorLine = nil
        isNewScript = true
        status = nil
        statusIsError = false
        markCurrentDocumentClean(savedTriggers: [], savedEnabled: true)
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
        let candidate = ns.replacingCharacters(in: range, with: text)
        guard candidate.utf8.count <= 16_384,
              ScriptingDisplayText.isValidScriptSource(candidate) else {
            status = "Insertion would exceed the 16384-byte source limit or contains unsafe text."
            statusIsError = true
            return
        }
        externalEditorEditSequence &+= 1
        externalEditorEdit = LuaEditorExternalEdit(
            id: externalEditorEditSequence,
            replacementRange: range,
            replacementText: text
        )
        source = candidate
        let insertedLength = (text as NSString).length
        selectedRange = NSRange(location: range.location + insertedLength, length: 0)
        status = nil
        errorLine = nil
    }

    /// Inserts a stable canonical lookup rather than a display name, so a later object with the
    /// same name can never silently become the script's target.
    func insertObjectReference(_ entry: WorldObjectPaletteEntry) {
        guard canInsertWorldObject(entry) else { return }
        insertAtCursor("objects.get(\"\(entry.ref.canonical)\")")
    }

    /// Inserts a useful local binding and leaves the caret after it. Names are deliberately
    /// conservative Lua identifiers; identity still comes exclusively from the canonical ref.
    func insertObjectBinding(_ entry: WorldObjectPaletteEntry) {
        guard canInsertWorldObject(entry) else { return }
        let identifier = uniqueLuaIdentifier(for: entry)
        insertAtCursor("local \(identifier) = objects.get(\"\(entry.ref.canonical)\")")
    }

    /// Refreshes an immutable, deterministically ordered authoring snapshot. Nearby blocks are
    /// intentionally limited to objects with records by ObjectGraph; ordinary terrain is not
    /// scanned merely because an editor is open.
    func refreshWorldObjects() {
        guard isCurrentWorldSession else {
            disconnectFromWorldSession()
            worldObjects = []
            targetApplicableBuiltInAttributes = nil
            targetCustomAttributes = []
            targetCustomAttributeCompletions = []
            handlerEventCandidates = ScriptEditorEventCatalog.candidates(targetKind: target.kind)
            authoringContextDidChange()
            return
        }
        let context = game.scriptingCommandContext()
        let graph = context.graph
        if game.isLANClientWorld {
            handlerEventCandidates = ScriptEditorEventCatalog.candidates(
                targetKind: target.kind,
                mirroredDeclarations: LANMultiplayerManager.shared.mirroredEvents(for: target) ?? []
            )
        } else {
            handlerEventCandidates = ScriptEditorEventCatalog.candidates(target: target, graph: graph)
        }
        let cursor = game.cursorObjectRef()
        var candidates: [(ref: ObjectRef, distance: Double?)] = []
        var seen = Set<String>()

        func append(_ ref: ObjectRef, distance: Double? = nil) {
            guard seen.insert(ref.canonical).inserted else { return }
            candidates.append((ref, distance))
        }

        append(target)
        if let cursor { append(cursor) }
        append(.player)
        append(.dimension(game.dim))
        append(.world)

        if let player = game.player {
            let nearby = graph.objectsNear(
                x: player.x, y: player.y, z: player.z,
                radius: 16, limit: 32
            )
            for entry in nearby {
                append(entry.ref, distance: entry.distanceSq.squareRoot())
            }
        }

        worldObjects = candidates.map { candidate in
            let customAttributes = customAttributeCompletions(
                for: candidate.ref, context: context
            )
            let isLive = isWorldObjectAvailable(candidate.ref, graph: graph)
            return WorldObjectPaletteEntry(
                ref: candidate.ref,
                displayName: displayName(for: candidate.ref, graph: graph),
                distance: candidate.distance,
                isLive: isLive,
                isTarget: candidate.ref == target,
                isCursorTarget: candidate.ref == cursor,
                attributeNames: customAttributes.map(\.name),
                scriptNames: scriptNames(for: candidate.ref, context: context),
                capabilities: authoringCapabilities(for: candidate.ref, isLive: isLive),
                attributeCompletions: customAttributes
            )
        }
        targetApplicableBuiltInAttributes = applicableBuiltInAttributeNames(for: target, graph: graph)
        targetCustomAttributeCompletions = customAttributeCompletions(
            for: target, context: context
        )
        targetCustomAttributes = targetCustomAttributeCompletions.map(\.name)
        authoringContextDidChange()
    }

    private func customAttributeCompletions(
        for ref: ObjectRef, context: ScriptingCommandContext
    ) -> [LuaCustomAttributeCompletion] {
        customAttributes(for: ref, context: context).map {
            LuaCustomAttributeCompletion(
                name: $0.name,
                typeName: Self.luaTypeName(for: $0.value),
                // Protocol 5 does not mirror mutability. Treat unknown guest attributes as
                // read-only in authoring UI; the host remains the final authority.
                isReadOnly: $0.readonly ?? true,
                summary: game.isLANClientWorld
                    ? "Replicated custom attribute on \(ref.canonical); mutability is unknown and the host remains authoritative."
                    : "Live custom attribute on \(ref.canonical)."
            )
        }
    }

    private func canInsertWorldObject(_ entry: WorldObjectPaletteEntry) -> Bool {
        guard requireCurrentWorldSession(for: "insert an object reference") else { return false }
        let graph = game.scriptingCommandContext().graph
        guard entry.isLive, isWorldObjectAvailable(entry.ref, graph: graph) else {
            status = "\(entry.ref.canonical) is no longer available. Refresh World Objects."
            statusIsError = true
            return false
        }
        return true
    }

    private func isWorldObjectAvailable(_ ref: ObjectRef, graph: ObjectGraph) -> Bool {
        if game.isLANClientWorld {
            let manager = LANMultiplayerManager.shared
            let guestSelf = ObjectRef.lanPlayer(peerID: manager.localGuestPeerID)
            if ref == guestSelf || ref == .player || ref == .world || ref == .dimension(game.dim) {
                return true
            }
            if manager.mirroredAttributes(for: ref) != nil || manager.mirroredScripts(for: ref) != nil {
                return true
            }
        }
        if case .live = graph.resolve(ref) { return true }
        return false
    }

    private func customAttributes(
        for ref: ObjectRef, context: ScriptingCommandContext
    ) -> [(name: String, value: AttrValue, readonly: Bool?)] {
        if game.isLANClientWorld {
            let mirrored = LANMultiplayerManager.shared.mirroredAttributes(for: ref) ?? [:]
            // Protocol 5 mirrors values but not the readonly bit. Preserve that uncertainty;
            // presentation is conservative and the host remains authoritative for writes.
            return mirrored.keys.sorted().compactMap { name in
                mirrored[name].map { (name: name, value: $0, readonly: nil) }
            }
        }
        return context.store.list(ref).map { (name: $0.name, value: $0.value, readonly: Optional($0.readonly)) }
    }

    private func customEventCandidates(
        for ref: ObjectRef, context: ScriptingCommandContext
    ) -> [ScriptEditorEventCandidate] {
        let candidates: [ScriptEditorEventCandidate]
        if game.isLANClientWorld {
            candidates = ScriptEditorEventCatalog.candidates(
                targetKind: ref.kind,
                mirroredDeclarations: LANMultiplayerManager.shared.mirroredEvents(for: ref) ?? []
            )
        } else {
            candidates = ScriptEditorEventCatalog.candidates(target: ref, graph: context.graph)
        }
        return candidates.filter { $0.source == .declaredCustom }
    }

    private func applicableBuiltInAttributeNames(
        for ref: ObjectRef, graph: ObjectGraph
    ) -> Set<String>? {
        guard !game.isLANClientWorld, case .live(let live) = graph.resolve(ref) else { return nil }
        return Set(AttributeRegistry.descriptors(for: ref.kind).compactMap { descriptor in
            if case .value = BuiltInAttributes.get(live, name: descriptor.canonical, host: graph.host) {
                return descriptor.canonical
            }
            return nil
        })
    }

    private func scriptNames(for ref: ObjectRef, context: ScriptingCommandContext) -> [String] {
        if game.isLANClientWorld {
            return (LANMultiplayerManager.shared.mirroredScripts(for: ref) ?? []).map(\.name)
        }
        return context.scriptStore.list(ref).map(\.name)
    }

    private func displayName(for ref: ObjectRef, graph: ObjectGraph) -> String {
        guard game.isLANClientWorld else { return graph.displayName(of: ref) }
        let guestSelf = ObjectRef.lanPlayer(peerID: LANMultiplayerManager.shared.localGuestPeerID)
        if ref == guestSelf { return "You (LAN guest)" }
        if ref == .player { return "Host player" }
        return graph.displayName(of: ref)
    }

    private func authoringCapabilities(for ref: ObjectRef, isLive: Bool) -> [String] {
        guard isLive else { return ["stale canonical reference"] }
        var values = ["canonical reference"]
        if game.isLANClientWorld {
            values.append(contentsOf: ["replicated metadata", "host validates script actions"])
        } else {
            values.append(contentsOf: ["inspect metadata", "script handle API"])
        }
        if ref.kind == .block { values.append("block handle API") }
        return values
    }

    private func uniqueLuaIdentifier(for entry: WorldObjectPaletteEntry) -> String {
        let lowerBytes = Array(entry.displayName.lowercased().utf8)
        var output: [UInt8] = []
        var lastWasUnderscore = false
        for byte in lowerBytes {
            let isLetter = byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")
            let isNumber = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            if isLetter || isNumber {
                output.append(byte)
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                output.append(UInt8(ascii: "_"))
                lastWasUnderscore = true
            }
        }
        while output.first == UInt8(ascii: "_") { output.removeFirst() }
        while output.last == UInt8(ascii: "_") { output.removeLast() }
        var candidate = String(decoding: output, as: UTF8.self)
        if candidate.isEmpty { candidate = "\(entry.kindLabel)_object" }
        if candidate.utf8.first.map({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) == true {
            candidate = "\(entry.kindLabel)_\(candidate)"
        }
        let reserved = Set(
            ScriptLanguageSchema.keywords
                + ScriptLanguageSchema.allSymbols.filter { $0.parent == nil }.map(\.name)
                + ["self", "world", "player", "ev"]
        )
        if reserved.contains(candidate) { candidate += "_object" }

        let symbols = LuaLanguageService.analyze(source: source, environment: languageEnvironment).symbols
        let used = Set(symbols.map(\.name))
        guard used.contains(candidate) else { return candidate }
        var suffix = 2
        while used.contains("\(candidate)_\(suffix)") { suffix += 1 }
        return "\(candidate)_\(suffix)"
    }

    private static func luaTypeName(for value: AttrValue) -> String {
        switch value {
        case .null: "nil"
        case .bool: "boolean"
        case .int: "integer"
        case .number: "number"
        case .string: "string"
        case .list: "table"
        case .map: "table"
        case .ref: "ElysiumObject"
        }
    }

    func markCurrentDocumentClean(savedTriggers: [Trigger]? = nil, savedEnabled: Bool? = nil) {
        cleanName = currentName
        cleanSource = source
        cleanMode = mode
        cleanHandlerEvent = handlerEvent
        if let savedTriggers { cleanTriggers = savedTriggers }
        if let savedEnabled { cleanEnabled = savedEnabled }
    }

    // MARK: - validate / save / run / check / delete

    /// The same validator `/script attach`/`/script run` use
    /// (`ScriptRuntime.validateSourceForEditor`) — the editor never accepts something the runtime
    /// would then refuse. Sets `errorLine`/`status` and returns `false` on refusal. A LAN client
    /// forwards Save to the host and therefore has no local validation result. A local session
    /// with no runtime fails closed so invalid Lua can never be persisted as validated source.
    @discardableResult
    func validate() -> Bool {
        guard requireCurrentWorldSession(for: "check or save it") else { return false }
        guard !game.isLANClientWorld else {
            errorLine = nil
            return true
        }
        let context = game.scriptingCommandContext()
        guard let runtime = context.scriptRuntime else {
            errorLine = nil
            status = "No script runtime this session; Check and Save require validation."
            statusIsError = true
            return false
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
    @discardableResult
    func save(confirming expectedCollision: ScriptEditorSaveCollision? = nil) -> Bool {
        guard requireCurrentWorldSession(for: "save it") else { return false }
        refreshScriptingAvailability()
        guard let name = validatedName() else { return false }
        let currentCollision = authoritativeSaveCollision(for: name)
        if let expectedCollision {
            guard currentCollision == expectedCollision else {
                status = "The saved script changed again while confirmation was open. Review the current state and confirm again."
                statusIsError = true
                return false
            }
        } else if let currentCollision {
            status = "\(currentCollision.description) Confirm replacement before saving."
            statusIsError = true
            return false
        }
        guard !source.isEmpty else {
            status = "Source is empty."
            statusIsError = true
            return false
        }
        var eventText: String?
        var parsedEvent: EventKind?
        if mode == .handler {
            let text = handlerEvent.trimmingCharacters(in: .whitespacesAndNewlines)
            if let error = ScriptEditorAuthoringContract.handlerEventValidationError(
                eventName: text,
                targetKind: target.kind
            ) {
                status = error
                statusIsError = true
                return false
            }
            guard let event = EventKind.parse(text) else { return false }
            eventText = text
            parsedEvent = event
        }
        if game.isLANClientWorld {
            var args = ["attach", target.canonical, name, mode == .handler ? "handler" : "module"]
            if let eventText { args.append(eventText) }
            args.append(source)
            LANMultiplayerManager.shared.sendScriptIntent(.command("script", args))
            currentName = name
            status = "sent \"\(name)\" to the host; keep this draft until the host confirms it in chat"
            statusIsError = false
            // A queued guest intent is not a successful save. Without a document-specific host
            // acknowledgement, marking this clean would let close/switch discard the only source
            // copy if the host later refuses it. Callers use `true` only for confirmed persistence.
            return false
        }
        let context = game.scriptingCommandContext()
        guard validate() else { return false }
        let triggers: [Trigger]
        if mode == .module {
            triggers = []
        } else if !isNewScript, !cleanTriggers.isEmpty, let parsedEvent {
            // The current UI edits the first event name only. Preserve every existing trigger's
            // filter/target plus all additional triggers so a source-only save is lossless.
            var retained = cleanTriggers
            let first = retained[0]
            retained[0] = Trigger(
                event: parsedEvent,
                attribute: parsedEvent == .attributeChanged ? first.attribute : nil,
                target: first.target
            )
            triggers = retained
        } else {
            triggers = parsedEvent.map {
                [Trigger(event: $0, attribute: nil, target: .object(target))]
            } ?? []
        }
        let recreatingLoadedDocument = !isNewScript && name == cleanName
            && context.scriptStore.get(target, name) == nil
        switch context.scriptStore.attach(
            target, name: name, source: source, mode: mode, triggers: triggers,
            enabled: recreatingLoadedDocument ? cleanEnabled : nil,
            by: .player, tick: context.tick
        ) {
        case .success(let savedRecord):
            currentName = name
            game.scripting.anyScriptsAttached = true
            if scriptingAvailability.attachedExecutionIsPaused {
                status = "Saved \"\(name)\" to \(target.canonical). Attached execution is paused: \(scriptingAvailability.detail)"
            } else {
                status = "Saved and attached \"\(name)\" to \(target.canonical)"
            }
            statusIsError = false
            isNewScript = false
            markCurrentDocumentClean(savedTriggers: savedRecord.triggers, savedEnabled: savedRecord.enabled)
            reload()
            refreshWorldObjects()
            return true
        case .failure(let err):
            status = scriptStoreErrorText(err)
            statusIsError = true
            return false
        }
    }

    /// Run Once (ephemeral — §9.3) never saves or attaches the draft. Permitted script calls may
    /// still mutate the live world, and those mutations can be included in a later world save. A
    /// host's explicit editor action can exercise the visible draft in an untrusted world without
    /// trusting it or starting attached scripts. The doScripts emergency pause remains
    /// authoritative. A LAN guest sends a `scriptIntent` and never runs Lua locally.
    func run() {
        guard requireCurrentWorldSession(for: "run it") else { return }
        defer { Self.refreshScriptingAvailability(in: game) }
        refreshScriptingAvailability()
        guard !source.isEmpty else {
            status = "Source is empty."
            statusIsError = true
            return
        }
        guard mode == .module else {
            status = ScriptEditorAuthoringContract.handlerRunOnceUnavailable
            statusIsError = true
            return
        }
        var runEnvironment = languageEnvironment
        runEnvironment.isYieldable = false
        if let yieldDiagnostic = LuaLanguageService.analyze(
            source: source, environment: runEnvironment
        ).diagnostics.first(where: {
            $0.id.hasPrefix("wait-mode:") || $0.id.hasPrefix("await-mode:")
        }) {
            errorLine = Self.lineNumber(in: source, atUTF16: yieldDiagnostic.range.location)
            selectedRange = yieldDiagnostic.range
            status = "Run is immediate and cannot suspend at wait() or ai.await(). Save the script and let the attached runtime execute it instead."
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
        switch runtime.runEphemeralForEditorExplicitRun(source: source, owner: target) {
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
        guard requireCurrentWorldSession(for: "check it") else { return }
        refreshScriptingAvailability()
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
        var selectedEvent: EventKind?
        if mode == .handler {
            let text = handlerEvent.trimmingCharacters(in: .whitespacesAndNewlines)
            if let error = ScriptEditorAuthoringContract.handlerEventValidationError(
                eventName: text,
                targetKind: target.kind
            ) {
                status = error
                statusIsError = true
                return
            }
            guard let event = EventKind.parse(text) else { return }
            selectedEvent = event
        }
        guard validate() else { return }
        switch runtime.dryRunOutcome(
            source: source, owner: target, mode: mode, handlerEvent: selectedEvent
        ) {
        case .failure(let message):
            status = message
            statusIsError = true
        case .suspended(let boundary):
            status = "Check reached a valid \(boundary) suspension. The prefix passed; code after that point was not executed."
            statusIsError = false
        case .compiledOnly(let reason):
            status = "Check compiled successfully, but did not execute: \(reason)."
            statusIsError = false
        case .completed:
            status = "Check passed — no issues found."
            statusIsError = false
        }
    }

    /// Deletes (detaches) a script from the target — `detach` is one of the three forwardable
    /// `/script` verbs (design.md §11), so this works for a guest too.
    func deleteScript(_ name: String) {
        guard requireCurrentWorldSession(for: "delete a script") else { return }
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
            refreshWorldObjects()
        case .failure(let err):
            status = scriptStoreErrorText(err)
            statusIsError = true
        }
    }

    /// Re-read the current store/mirror at the synchronous save boundary. Cached sidebar rows are
    /// only presentation and must never authorize replacement. Same-name external edits are also
    /// detected against the clean snapshot loaded by this window.
    private func authoritativeSaveCollision(for name: String) -> ScriptEditorSaveCollision? {
        guard isCurrentWorldSession else { return nil }
        if game.isLANClientWorld {
            let existing = LANMultiplayerManager.shared.mirroredScripts(for: target)?.first {
                $0.name == name
            }
            guard let existing else {
                if !isNewScript, name == cleanName {
                    return ScriptEditorSaveCollision(
                        name: name,
                        description: "The host script \"\(name)\" was deleted after this editor loaded it.",
                        snapshot: .guest(mode: nil, enabled: nil)
                    )
                }
                return nil
            }
            guard name == cleanName else {
                return ScriptEditorSaveCollision(
                    name: name,
                    description: "A different host script named \"\(name)\" already exists.",
                    snapshot: .guest(mode: existing.mode, enabled: existing.enabled)
                )
            }
            guard existing.mode != cleanMode.rawValue || existing.enabled != cleanEnabled else {
                return nil
            }
            return ScriptEditorSaveCollision(
                name: name,
                description: "The host script \"\(name)\" changed after this editor loaded it.",
                snapshot: .guest(mode: existing.mode, enabled: existing.enabled)
            )
        }
        guard let existing = game.scriptingCommandContext().scriptStore.get(target, name) else {
            if !isNewScript, name == cleanName {
                return ScriptEditorSaveCollision(
                    name: name,
                    description: "The saved script \"\(name)\" was deleted after this editor loaded it.",
                    snapshot: .host(nil)
                )
            }
            return nil
        }
        guard name == cleanName else {
            return ScriptEditorSaveCollision(
                name: name,
                description: "A different script named \"\(name)\" already exists.",
                snapshot: .host(existing)
            )
        }
        guard existing.source != cleanSource || existing.mode != cleanMode
                || existing.triggers != cleanTriggers || existing.enabled != cleanEnabled else { return nil }
        return ScriptEditorSaveCollision(
            name: name,
            description: "The saved script \"\(name)\" changed after this editor loaded it.",
            snapshot: .host(existing)
        )
    }

    private static func lineNumber(in source: String, atUTF16 location: Int) -> Int {
        let text = source as NSString
        let end = min(max(0, location), text.length)
        var line = 1
        guard end > 0 else { return line }
        for index in 0..<end where text.character(at: index) == 10 { line += 1 }
        return line
    }
}
