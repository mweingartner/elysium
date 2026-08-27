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
    @Published private(set) var externalEditorEdit: LuaEditorExternalEdit?
    @Published private(set) var documentIdentity: UInt64 = 0
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
    private var aiRequestGeneration: UInt64 = 0
    private var externalEditorEditSequence: UInt64 = 0
    private var isApplyingAISuggestion = false
    private var worldSessionObserver: AnyCancellable?

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
        refreshScriptingAvailability()
        reload()
        if let existingName {
            switchTo(existingName)
        } else {
            newScript()
        }
        refreshWorldObjects()
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

    private func applySharedAICompletionMode(_ newMode: ScriptEditorAICompletionMode) {
        guard newMode != aiCompletionMode else { return }
        aiCompletionMode = newMode
        cancelAIWork(clearSuggestion: true)
        aiSuggestionError = nil
        if newMode == .onIdle { scheduleIdleAISuggestionIfNeeded() }
    }

    private func applySharedAIModel(_ name: String) {
        guard name != aiModelName else { return }
        cancelAIWork(clearSuggestion: true)
        aiModelName = name
        aiSuggestionError = nil
        scheduleIdleAISuggestionIfNeeded()
    }

    private func synchronizeSharedAIConfiguration() {
        applySharedAICompletionMode(ScriptEditorAICompletionMode.persisted())
        applySharedAIModel(game.settings.aiOllamaModel)
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
    func requestEditorAIReply(instruction: String) async throws -> String {
        synchronizeSharedAIConfiguration()
        guard aiCompletionMode != .off else { throw ScriptEditorAIRequestError.disabled }
        if let authoringError = editorAIRequestPreflightError { throw authoringError }
        let response = try await performEditorAIRequest(instruction: instruction)
        return response.text
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
        instruction: String?
    ) async throws -> OllamaCodeCompletionResponse {
        guard isCurrentWorldSession else {
            disconnectFromWorldSession()
            throw OllamaCodeCompletionError.stale
        }
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
                            ? descriptor.kind.rawValue
                            : nil
                    }
                    : nil,
                customEvents: includeCrossObjectEvents
                    ? customEventCandidates(for: entry.ref, context: scriptingContext).map(aiEvent)
                    : nil
            )
        }
        let request = try OllamaCodeCompletionRequest(
            source: source,
            caretUTF16: selectedRange.location,
            selectionLengthUTF16: selectedRange.length,
            documentRevision: documentRevision,
            documentIdentity: documentIdentity,
            contextKey: contextKey,
            model: aiModelName,
            languageSchema: ScriptLanguageSchema.luaCATSDefinitions,
            authoringContext: currentAIAuthoringContext,
            diagnostics: editorDiagnostics.map(\.message),
            authorizedNearbyObjects: nearbyObjects,
            fillInMiddlePolicy: .disabled,
            instruction: instruction
        )
        // The owning structured task is cancelled on every document/caret/context change. The
        // response identity is checked again below on MainActor, which is the final publication
        // gate and avoids sharing this non-Sendable UI model with the service actor.
        let response = try await aiCompleter.completeEditorRequest(request)
        guard isCurrentWorldSession, response.isCurrent(
            documentRevision: documentRevision,
            documentIdentity: documentIdentity,
            source: source,
            caretUTF16: selectedRange.location,
            selectionLengthUTF16: selectedRange.length,
            contextKey: currentAIContextKey,
            model: aiModelName,
            instruction: instruction
        ) else {
            throw OllamaCodeCompletionError.stale
        }
        return response
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

    private var currentAIAuthoringContext: OllamaCodeCompletionAuthoringContext {
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
            }
            .map { "method \($0.signatures.first?.label ?? $0.name)" })
        members.append(contentsOf: applicableBuiltIns.map {
            "attribute \($0.name):\($0.type.displayName):\($0.mutability == .readOnly ? "read_only" : "writable")"
        })
        members.append(contentsOf: targetCustomAttributeCompletions.map {
            "custom_attribute \($0.name):\($0.typeName):\($0.isReadOnly ? "read_only" : "writable")"
        })
        let eventName = mode == .handler
            ? handlerEvent.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let eventCandidates = mode == .module
            ? ScriptEditorEventCatalog.broadlyAvailableCandidates(
                including: handlerEventCandidates
            )
            : handlerEventCandidates
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

    private func aiEvent(
        _ event: ScriptEditorEventCandidate
    ) -> OllamaCodeCompletionAuthoringEvent {
        OllamaCodeCompletionAuthoringEvent(
            name: event.name,
            source: event.source.rawValue,
            payloadFields: event.payload.map {
                $0.name + ":" + $0.type.displayName + ($0.isNullable ? "?" : "")
            }
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
        }) {
            return "AI proposal refused: \(violation.message)"
        }
        return nil
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
