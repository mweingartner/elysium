import Foundation
import XCTest
@testable import PebbleCore

final class GameCoreLocalSettingsIntegrationTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
        super.tearDown()
    }

    private func makeStore(_ label: String) -> LocalSettingsStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("PebbleGameCoreSettings-\(label)-\(UUID().uuidString)",
                                   isDirectory: true)
        roots.append(root)
        return LocalSettingsStore(directoryURL: root)
    }

    private func makeGame(_ label: String, store: LocalSettingsStore) throws -> GameCore {
        GameCore(db: try PersistenceTestSupport.makeDatabase(
            owner: self, label: "game-core-settings-\(label)"), localSettingsStore: store)
    }

    private func onMain<T>(_ body: @MainActor () -> T) -> T {
        MainActor.assumeIsolated(body)
    }

    private func settingsBytes(_ value: Settings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func keybindBytes(_ value: [String: String]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private struct LiveSnapshot: Equatable {
        let settings: Data
        let keybinds: Data
        let settingsRevision: UInt64
        let keybindRevision: UInt64
        let semanticRevision: UInt64
        let dirtyCount: UInt64
        let notificationIntentCount: UInt64
    }

    private func snapshot(_ game: GameCore) throws -> LiveSnapshot {
        LiveSnapshot(
            settings: try settingsBytes(game.settings),
            keybinds: try keybindBytes(game.keybinds),
            settingsRevision: game.settingsRevision,
            keybindRevision: game.keybindRevision,
            semanticRevision: game._testLocalSettingsSemanticRevision,
            dirtyCount: game._testLocalSettingsDirtyCount,
            notificationIntentCount: game._testLocalSettingsNotificationIntentCount)
    }

    func testMissingDocumentsLoadCanonicalTwentyFiveDefaultsAndCheckedRevisions() throws {
        let game = try makeGame("defaults", store: makeStore("defaults"))
        XCTAssertEqual(game.settings.rpgTutorialVersion, 0)
        XCTAssertEqual(game.settingsRevision, 1)
        XCTAssertEqual(game.keybindRevision, 1)
        XCTAssertEqual(KEYBIND_DEFINITIONS.count, 25)
        XCTAssertEqual(DEFAULT_KEYBINDS.count, 25)
        XCTAssertEqual(game.keybinds, rpgDefaultChordBindings())
        XCTAssertFalse(game.localSettingsPersistenceFailed)
        XCTAssertEqual(game.localSettingsPersistenceFailureCount, 0)
    }

    func testAllThreeCandidateAPIsPersistBeforeAtomicPublishAndSettingsPreserveTutorial() throws {
        let store = makeStore("success")
        let game = try makeGame("success", store: store)
        var publications: [(String, UInt64)] = []
        game._testLocalSettingsDidPublish = { publications.append(($0, $1)) }

        XCTAssertEqual(onMain {
            game.persistAndPublishTutorialVersionCandidate(
                RPG_TUTORIAL_VERSION, expectedLiveRevision: 1)
        }, .success(2))
        var settingsCandidate = game.settings
        settingsCandidate.fov = 99
        settingsCandidate.rpgTutorialVersion = 0
        XCTAssertEqual(onMain {
            game.persistAndPublishSettingsCandidate(settingsCandidate, expectedLiveRevision: 2)
        }, .success(3))
        XCTAssertEqual(game.settings.fov, 99)
        XCTAssertEqual(game.settings.rpgTutorialVersion, RPG_TUTORIAL_VERSION,
                       "general settings publication must not own tutorial state")

        var keybindCandidate = game.keybinds
        keybindCandidate["forward"] = "KeyZ"
        XCTAssertEqual(onMain {
            game.persistAndPublishKeybindCandidate(keybindCandidate, expectedLiveRevision: 1)
        }, .success(2))
        XCTAssertEqual(game.keybinds["forward"], "KeyZ")
        XCTAssertEqual(publications.map(\.0), ["tutorial", "settings", "keybinds"])
        XCTAssertEqual(game._testLocalSettingsSemanticRevision, 4)
        XCTAssertEqual(game._testLocalSettingsDirtyCount, 3)
        XCTAssertEqual(game._testLocalSettingsNotificationIntentCount, 0)

        guard case .success(let persistedSettings) = store.loadSettings(),
              case .success(let persistedKeybinds) = store.loadKeybinds() else {
            return XCTFail("published candidates must be durable")
        }
        XCTAssertEqual(persistedSettings.fov, 99)
        XCTAssertEqual(persistedSettings.rpgTutorialVersion, RPG_TUTORIAL_VERSION)
        XCTAssertEqual(persistedKeybinds["forward"], "KeyZ")
    }

    func testStaleAndExhaustedRevisionsRejectBeforeIOWithNoSideEffects() throws {
        let store = makeStore("revision")
        let game = try makeGame("revision", store: store)
        var candidate = game.settings
        candidate.fov = 101
        let beforeStale = try snapshot(game)
        XCTAssertEqual(onMain {
            game.persistAndPublishSettingsCandidate(candidate, expectedLiveRevision: 2)
        }, .failure(.staleLiveRevision(expected: 2, actual: 1)))
        XCTAssertEqual(try snapshot(game), beforeStale)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: store.directoryURL.appendingPathComponent("settings.json").path))

        game._testSetSettingsRevision(.max)
        let beforeSettingsExhaustion = try snapshot(game)
        XCTAssertEqual(onMain {
            game.persistAndPublishTutorialVersionCandidate(
                RPG_TUTORIAL_VERSION, expectedLiveRevision: .max)
        }, .failure(.revisionExhausted))
        XCTAssertEqual(try snapshot(game), beforeSettingsExhaustion)

        game._testSetKeybindRevision(.max)
        let beforeKeybindExhaustion = try snapshot(game)
        XCTAssertEqual(onMain {
            game.persistAndPublishKeybindCandidate(game.keybinds, expectedLiveRevision: .max)
        }, .failure(.revisionExhausted))
        XCTAssertEqual(try snapshot(game), beforeKeybindExhaustion)

        game._testSetSettingsRevision(0)
        let beforeZeroRevision = try snapshot(game)
        XCTAssertEqual(onMain {
            game.persistAndPublishSettingsCandidate(candidate, expectedLiveRevision: 0)
        }, .failure(.revisionExhausted))
        XCTAssertEqual(try snapshot(game), beforeZeroRevision)
    }

    func testValidationAndEncodeFailuresPreserveByteIdenticalLiveState() throws {
        print("GameCore local settings encode-validation cases=5")
        let store = makeStore("validation")
        let game = try makeGame("validation", store: store)

        var missing = game.keybinds
        missing.removeValue(forKey: "forward")
        var before = try snapshot(game)
        guard case .failure(.invalidKeybinds(_)) = onMain({
            game.persistAndPublishKeybindCandidate(missing, expectedLiveRevision: 1)
        }) else { return XCTFail("missing keybind must fail validation") }
        XCTAssertEqual(try snapshot(game), before)

        before = try snapshot(game)
        guard case .failure(.invalidSettings(_)) = onMain({
            game.persistAndPublishTutorialVersionCandidate(
                RPG_TUTORIAL_VERSION + 1, expectedLiveRevision: game.settingsRevision)
        }) else { return XCTFail("future tutorial version must fail validation") }
        XCTAssertEqual(try snapshot(game), before)

        store.encodeFaultInjector = { $0 == .settings ? TestEncodeFailure() : nil }
        var settingsCandidate = game.settings
        settingsCandidate.fov = 88
        before = try snapshot(game)
        guard case .failure(.encodeFailed(.settings, _)) = onMain({
            game.persistAndPublishSettingsCandidate(
                settingsCandidate, expectedLiveRevision: game.settingsRevision)
        }) else { return XCTFail("injected settings encode failure must surface") }
        XCTAssertEqual(try snapshot(game), before)

        store.encodeFaultInjector = { $0 == .keybinds ? TestEncodeFailure() : nil }
        var keybindCandidate = game.keybinds
        keybindCandidate["forward"] = "KeyZ"
        before = try snapshot(game)
        guard case .failure(.encodeFailed(.keybinds, _)) = onMain({
            game.persistAndPublishKeybindCandidate(
                keybindCandidate, expectedLiveRevision: game.keybindRevision)
        }) else { return XCTFail("injected keybind encode failure must surface") }
        XCTAssertEqual(try snapshot(game), before)

        store.encodeFaultInjector = { $0 == .settings ? TestEncodeFailure() : nil }
        before = try snapshot(game)
        guard case .failure(.encodeFailed(.settings, _)) = onMain({
            game.persistAndPublishTutorialVersionCandidate(
                RPG_TUTORIAL_VERSION, expectedLiveRevision: game.settingsRevision)
        }) else { return XCTFail("injected tutorial-document encode failure must surface") }
        XCTAssertEqual(try snapshot(game), before)
    }

    func testEveryWriteStageForEveryPublicationAPILeavesLiveStateUntouched() throws {
        enum Operation: CaseIterable { case settings, keybinds, tutorial }

        print("GameCore local settings API-write-stage cases=15")
        for operation in Operation.allCases {
            for stage in LocalSettingsWriteStage.allCases {
                let label = "\(operation)-\(stage.rawValue)"
                let store = makeStore(label)
                let game = try makeGame(label, store: store)
                var failures: [LocalSettingsStoreError] = []
                var publications = 0
                game._testLocalSettingsPersistenceFailure = { failures.append($0) }
                game._testLocalSettingsDidPublish = { _, _ in publications += 1 }
                store.faultInjector = { $0 == stage ? InjectedLocalSettingsFailure(stage: $0) : nil }
                let before = try snapshot(game)
                let failureCount = game.localSettingsPersistenceFailureCount

                let result: Result<UInt64, LocalSettingsStoreError> = onMain {
                    switch operation {
                    case .settings:
                        var candidate = game.settings
                        candidate.fov = 94
                        return game.persistAndPublishSettingsCandidate(
                            candidate, expectedLiveRevision: game.settingsRevision)
                    case .keybinds:
                        var candidate = game.keybinds
                        candidate["forward"] = "KeyZ"
                        return game.persistAndPublishKeybindCandidate(
                            candidate, expectedLiveRevision: game.keybindRevision)
                    case .tutorial:
                        return game.persistAndPublishTutorialVersionCandidate(
                            RPG_TUTORIAL_VERSION, expectedLiveRevision: game.settingsRevision)
                    }
                }
                guard case let .failure(.writeFailed(_, reportedStage, _)) = result else {
                    return XCTFail("\(label) must return its write-stage failure")
                }
                XCTAssertEqual(reportedStage, stage, label)
                XCTAssertEqual(try snapshot(game), before, label)
                XCTAssertEqual(game.localSettingsPersistenceFailureCount, failureCount + 1, label)
                XCTAssertTrue(game.localSettingsPersistenceFailed, label)
                XCTAssertEqual(failures.count, 1, label)
                XCTAssertEqual(publications, 0, label)

                // Rename precedes directory sync. A directory-sync failure may leave the complete
                // new document durable, but it still must not publish into this live GameCore.
                if stage == .directorySync {
                    switch operation {
                    case .settings, .tutorial:
                        guard case .success = store.loadSettings() else {
                            return XCTFail("\(label) must leave a complete settings document")
                        }
                    case .keybinds:
                        guard case .success = store.loadKeybinds() else {
                            return XCTFail("\(label) must leave a complete keybind document")
                        }
                    }
                }
            }
        }
    }

    func testDelayedCapturedSettingsCandidateCannotOverwriteInterveningPublication() throws {
        let store = makeStore("delayed-capture")
        let game = try makeGame("delayed-capture", store: store)
        var delayedCandidate = game.settings
        delayedCandidate.aiOllamaModel = "first-model:latest"
        let delayedExpectedRevision = game.settingsRevision

        var intervening = game.settings
        intervening.aiOllamaModel = "user-choice:latest"
        XCTAssertEqual(onMain {
            game.persistAndPublishSettingsCandidate(
                intervening, expectedLiveRevision: game.settingsRevision)
        }, .success(2))
        let beforeDelayedCompletion = try snapshot(game)
        let durableBefore = try Data(contentsOf:
            store.directoryURL.appendingPathComponent("settings.json"))

        XCTAssertEqual(onMain {
            game.persistAndPublishSettingsCandidate(
                delayedCandidate, expectedLiveRevision: delayedExpectedRevision)
        }, .failure(.staleLiveRevision(expected: 1, actual: 2)))
        XCTAssertEqual(try snapshot(game), beforeDelayedCompletion)
        XCTAssertEqual(game.settings.aiOllamaModel, "user-choice:latest")
        XCTAssertEqual(try Data(contentsOf:
            store.directoryURL.appendingPathComponent("settings.json")), durableBefore)
        let restarted = try makeGame("delayed-capture-restart", store: store)
        XCTAssertEqual(restarted.settings.aiOllamaModel, "user-choice:latest")
    }

    func testRestartedGameCorrelatesOldOrNewCompleteDocumentAcrossRealCuts() throws {
        enum Operation: CaseIterable { case settings, keybinds, tutorial }
        enum Cut: CaseIterable, Equatable { case partialWrite, completeWriteThenError, directorySync }

        print("GameCore local settings restarted correlation cases=9")
        for operation in Operation.allCases {
            for cut in Cut.allCases {
                let label = "restart-\(operation)-\(cut)"
                let store = makeStore(label)
                let game = try makeGame(label, store: store)

                switch operation {
                case .settings:
                    var baseline = game.settings; baseline.fov = 71
                    guard case .success = onMain({ game.persistAndPublishSettingsCandidate(
                        baseline, expectedLiveRevision: game.settingsRevision) }) else {
                        return XCTFail("\(label) baseline settings failed")
                    }
                case .keybinds:
                    var baseline = game.keybinds; baseline["forward"] = "KeyX"
                    guard case .success = onMain({ game.persistAndPublishKeybindCandidate(
                        baseline, expectedLiveRevision: game.keybindRevision) }) else {
                        return XCTFail("\(label) baseline keybinds failed")
                    }
                case .tutorial:
                    guard case .success = onMain({ game.persistAndPublishTutorialVersionCandidate(
                        0, expectedLiveRevision: game.settingsRevision) }) else {
                        return XCTFail("\(label) baseline tutorial failed")
                    }
                }

                switch cut {
                case .partialWrite: store.systemWriteCut = .partialWrite
                case .completeWriteThenError: store.systemWriteCut = .completeWriteThenError
                case .directorySync:
                    store.faultInjector = {
                        $0 == .directorySync ? InjectedLocalSettingsFailure(stage: $0) : nil
                    }
                }
                let before = try snapshot(game)
                let result: Result<UInt64, LocalSettingsStoreError> = onMain {
                    switch operation {
                    case .settings:
                        var candidate = game.settings; candidate.fov = 109
                        return game.persistAndPublishSettingsCandidate(
                            candidate, expectedLiveRevision: game.settingsRevision)
                    case .keybinds:
                        var candidate = game.keybinds; candidate["forward"] = "KeyI"
                        return game.persistAndPublishKeybindCandidate(
                            candidate, expectedLiveRevision: game.keybindRevision)
                    case .tutorial:
                        return game.persistAndPublishTutorialVersionCandidate(
                            RPG_TUTORIAL_VERSION, expectedLiveRevision: game.settingsRevision)
                    }
                }
                guard case .failure = result else { return XCTFail("\(label) must fail") }
                XCTAssertEqual(try snapshot(game), before, label)
                store.systemWriteCut = nil
                store.faultInjector = nil

                let restarted = try makeGame("\(label)-restarted", store: store)
                let newDocumentExpected = cut == .directorySync
                switch operation {
                case .settings:
                    XCTAssertEqual(restarted.settings.fov, newDocumentExpected ? 109 : 71, label)
                case .keybinds:
                    XCTAssertEqual(restarted.keybinds["forward"],
                                   newDocumentExpected ? "KeyI" : "KeyX", label)
                case .tutorial:
                    XCTAssertEqual(restarted.settings.rpgTutorialVersion,
                                   newDocumentExpected ? RPG_TUTORIAL_VERSION : 0, label)
                }
            }
        }
    }
}

private struct TestEncodeFailure: Error {}
