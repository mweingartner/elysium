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

    func testVisiblePanelDiscoversModelsAndPreloadsExactPersistedSelection() async throws {
        let restoreMode = setCompletionModeForTest(.manual)
        defer { restoreMode() }

        let selectedModel = "panel-saved-model:27b"
        let game = try makeGame(selectedModel: selectedModel)
        let model = ScriptEditorModel(target: .player, game: game)
        XCTAssertEqual(model.aiModelName, selectedModel)

        let discovered = expectation(description: "visible panel discovers local models")
        let preloaded = expectation(description: "visible panel preloads saved model")
        var discoveryCount = 0
        var preloadedModels: [String] = []
        let loader = ScriptEditorAIModelLoader(
            fetchModels: {
                discoveryCount += 1
                discovered.fulfill()
                return ["another-model:latest", selectedModel]
            },
            preloadModel: { name in
                preloadedModels.append(name)
                preloaded.fulfill()
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
        await fulfillment(of: [discovered, preloaded], timeout: 2)
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(discoveryCount, 1)
        XCTAssertEqual(preloadedModels, [selectedModel])
        XCTAssertEqual(model.aiModelName, selectedModel)
        XCTAssertEqual(game.settings.aiOllamaModel, selectedModel)
    }

    func testOffPanelDoesNotDiscoverOrPreloadModels() async throws {
        let restoreMode = setCompletionModeForTest(.off)
        defer { restoreMode() }

        let game = try makeGame(selectedModel: "local-model:latest")
        let model = ScriptEditorModel(target: .player, game: game)
        var discoveryCount = 0
        var preloadCount = 0
        let loader = ScriptEditorAIModelLoader(
            fetchModels: {
                discoveryCount += 1
                return []
            },
            preloadModel: { _ in
                preloadCount += 1
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
        XCTAssertEqual(preloadCount, 0)
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

    func testFailedPreloadCanRetryTheSameSelectedModel() async {
        let firstAttempt = expectation(description: "first preload fails")
        let retryAttempt = expectation(description: "same model retries")
        let selectedModel = "retry-model:latest"
        var attempts = 0
        let preloader = ScriptEditorAIModelPreloader { model in
            XCTAssertEqual(model, selectedModel)
            attempts += 1
            if attempts == 1 {
                firstAttempt.fulfill()
                throw RetryTestError.transientFailure
            }
            retryAttempt.fulfill()
        }

        preloader.preload(selectedModel)
        await fulfillment(of: [firstAttempt], timeout: 2)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertNil(preloader.satisfiedModel)

        preloader.preload(selectedModel)
        await fulfillment(of: [retryAttempt], timeout: 2)
        for _ in 0..<4 { await Task.yield() }
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(preloader.satisfiedModel, selectedModel)
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
}

private enum RetryTestError: Error {
    case transientFailure
}
