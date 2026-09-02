import AppKit
import SwiftUI
import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class ScriptEditorAIPanelTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        if entityTypes().isEmpty { registerAllEntities() }
    }

    func testVisiblePanelDiscoversModelsWithoutOwningEditorWarmup() async throws {
        let restoreMode = setCompletionModeForTest(.manual)
        defer { restoreMode() }

        let selectedModel = "panel-saved-model:27b"
        let game = try makeGame(selectedModel: selectedModel)
        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertEqual(model.aiModelName, selectedModel)

        let discovered = expectation(description: "visible panel discovers local models")
        var discoveryCount = 0
        let loader = ScriptEditorAIModelLoader(
            fetchModels: {
                discoveryCount += 1
                discovered.fulfill()
                return ["another-model:latest", selectedModel]
            }
        )

        let hosting = NSHostingView(rootView: ScriptEditorAIPanel(
            model: model,
            modelLoader: loader
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        await fulfillment(of: [discovered], timeout: 2)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(discoveryCount, 1)
        XCTAssertEqual(model.aiModelName, selectedModel)
        XCTAssertEqual(game.settings.aiOllamaModel, selectedModel)
    }

    func testOffPanelDoesNotDiscoverOrPreloadModels() async throws {
        let restoreMode = setCompletionModeForTest(.off)
        defer { restoreMode() }

        let game = try makeGame(selectedModel: "local-model:latest")
        let model = ScriptEditorModel(target: .player, game: game)
        var discoveryCount = 0
        let loader = ScriptEditorAIModelLoader(
            fetchModels: {
                discoveryCount += 1
                return []
            }
        )
        let hosting = NSHostingView(rootView: ScriptEditorAIPanel(
            model: model,
            modelLoader: loader
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(discoveryCount, 0)
    }

    func testPreloadRequestContainsOnlyExactModelAndEmptyWarmupFields() throws {
        let request = try OllamaAgentService.editorModelPreloadRequest(
            baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:11434")),
            requestedModel: "qwen3.8:27b-mlx"
        )

        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11434/api/generate")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, OllamaAgentService.editorModelPreloadTimeout)
        let bodyData = try XCTUnwrap(request.httpBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        )
        XCTAssertEqual(Set(body.keys), ["model", "prompt", "keep_alive", "stream"])
        XCTAssertEqual(body["model"] as? String, "qwen3.8:27b-mlx")
        XCTAssertEqual(body["prompt"] as? String, "")
        XCTAssertEqual(
            body["keep_alive"] as? String,
            OllamaAgentService.editorModelPreloadKeepAlive
        )
        XCTAssertEqual(body["stream"] as? Bool, false)
    }

    func testEditorLifecycleWarmsWithPanelClosedAndRetriesFailedExactModel() async throws {
        let restoreMode = setCompletionModeForTest(.manual)
        defer { restoreMode() }

        let selectedModel = "retry-model:latest"
        let completer = FlakyPreparationCompleter()
        let game = try makeGame(selectedModel: selectedModel)
        let model = ScriptEditorModel(
            target: .player,
            game: game,
            aiCompleter: completer
        )

        // No ScriptEditorAIPanel is constructed: opening the editor model lifecycle is enough.
        model.beginAIReadiness()
        try await waitUntil { if case .failed = model.aiReadinessState { true } else { false } }
        var preparedModels = await completer.preparedModels()
        XCTAssertEqual(preparedModels, [selectedModel])

        model.retryAIReadiness()
        try await waitUntil { model.aiReadinessState == .ready(selectedModel) }
        preparedModels = await completer.preparedModels()
        XCTAssertEqual(preparedModels, [selectedModel, selectedModel])
        model.endAIReadiness()
        try await waitUntil { await completer.releaseCount() == 1 }
    }

    func testOffEditorLifecycleMakesNoPreparationRequest() async throws {
        let restoreMode = setCompletionModeForTest(.off)
        defer { restoreMode() }

        let completer = FlakyPreparationCompleter(failFirst: false)
        let game = try makeGame(selectedModel: "local-model:latest")
        let model = ScriptEditorModel(
            target: .player,
            game: game,
            aiCompleter: completer
        )
        model.beginAIReadiness()
        for _ in 0..<8 { await Task.yield() }

        XCTAssertEqual(model.aiReadinessState, .off)
        let preparedModels = await completer.preparedModels()
        XCTAssertTrue(preparedModels.isEmpty)
    }

    func testClosingEditorBeforePreparationStartsRetiresOwnerWithoutWarmup() async throws {
        let restoreMode = setCompletionModeForTest(.manual)
        defer { restoreMode() }

        let completer = FlakyPreparationCompleter(failFirst: false)
        let game = try makeGame(selectedModel: "local-model:latest")
        let model = ScriptEditorModel(
            target: .player,
            game: game,
            aiCompleter: completer
        )

        // Both lifecycle calls happen in the same MainActor turn, before the preparation task can
        // start. Closing must retire and release that owner without doing a late cold warmup.
        model.beginAIReadiness()
        model.endAIReadiness()
        try await waitUntil { await completer.releaseAttemptCount() == 1 }

        XCTAssertEqual(model.aiReadinessState, .idle)
        let preparedModels = await completer.preparedModels()
        let activeOwnerCount = await completer.activeOwnerCount()
        XCTAssertTrue(preparedModels.isEmpty)
        XCTAssertEqual(activeOwnerCount, 0)
    }

    private func makeGame(selectedModel: String) throws -> GameCore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("elysium-script-ai-panel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let databaseURL = root.appendingPathComponent("worlds.sqlite")
        let settingsURL = root.appendingPathComponent("settings", isDirectory: true)
        let game = GameCore(
            db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false),
            localSettingsStore: LocalSettingsStore(directoryURL: settingsURL)
        )
        var settings = game.settings
        settings.aiOllamaModel = selectedModel
        switch game.persistAndPublishSettingsCandidate(
            settings,
            expectedLiveRevision: game.settingsRevision
        ) {
        case .success:
            break
        case .failure(let error):
            throw error
        }
        game.createWorld(
            name: "Script AI Panel Test",
            seedText: "8315",
            mode: GameMode.creative,
            difficulty: 2
        )
        return game
    }

    private func setCompletionModeForTest(
        _ mode: ScriptEditorAICompletionMode
    ) -> @MainActor () -> Void {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: ScriptEditorAICompletionMode.defaultsKey)
        defaults.set(mode.rawValue, forKey: ScriptEditorAICompletionMode.defaultsKey)
        return {
            if let previous {
                defaults.set(previous, forKey: ScriptEditorAICompletionMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: ScriptEditorAICompletionMode.defaultsKey)
            }
        }
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try await clock.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for Script AI lifecycle state")
    }
}

private enum RetryTestError: Error {
    case transientFailure
}

private actor FlakyPreparationCompleter: ScriptEditorAICompleting {
    private let failFirst: Bool
    private var models: [String] = []
    private var releases = 0
    private var releaseAttempts = 0
    private var activeOwners: Set<UUID> = []

    init(failFirst: Bool = true) {
        self.failFirst = failFirst
    }

    func prepareEditorModel(_ model: String, owner: UUID) async throws {
        try Task.checkCancellation()
        models.append(model)
        if failFirst, models.count == 1 {
            throw RetryTestError.transientFailure
        }
        activeOwners.insert(owner)
    }

    func releaseEditorModel(owner: UUID) async {
        releaseAttempts += 1
        if activeOwners.remove(owner) != nil {
            releases += 1
        }
    }

    func completeEditorRequest(
        _ request: OllamaCodeCompletionRequest
    ) async throws -> OllamaCodeCompletionResponse {
        OllamaCodeCompletionResponse(
            identity: request.identity,
            insertion: "say('ready')",
            strategy: .safePrompt,
            modelHints: nil
        )
    }

    func preparedModels() -> [String] { models }
    func releaseCount() -> Int { releases }
    func releaseAttemptCount() -> Int { releaseAttempts }
    func activeOwnerCount() -> Int { activeOwners.count }
}
