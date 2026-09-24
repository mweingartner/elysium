import Foundation
import XCTest
@testable import ElysiumCore

final class CreatureRespawnSettingsTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        roots.removeAll()
    }

    private func store(json: String? = nil) throws -> LocalSettingsStore {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("ElysiumCreatureRespawnSettings-\(UUID().uuidString)",
                                   isDirectory: true)
        roots.append(root)
        if let json {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: root.appendingPathComponent("settings.json"))
        }
        return LocalSettingsStore(directoryURL: root)
    }

    func testFrequencyHasClosedCycleBasedChoicesAndWraps() {
        XCTAssertEqual(CreatureRespawnFrequency.allCases.map(\.dayCount), [1, 2, 7])
        XCTAssertEqual(CreatureRespawnFrequency.allCases.map(\.displayName),
                       ["Daily", "Alternate Days", "Weekly"])
        XCTAssertEqual(CreatureRespawnFrequency.daily.next, .alternateDays)
        XCTAssertEqual(CreatureRespawnFrequency.alternateDays.next, .weekly)
        XCTAssertEqual(CreatureRespawnFrequency.weekly.next, .daily)
        XCTAssertEqual(Settings().creatureRespawnFrequency, .daily)
    }

    func testFrequencyRoundTripsEveryChoiceWithoutChangingOtherPreferences() throws {
        for frequency in CreatureRespawnFrequency.allCases {
            let store = try store()
            var candidate = Settings()
            candidate.creatureRespawnFrequency = frequency
            candidate.fov = 91
            candidate.showMinimap = false
            try store.persistSettings(candidate).get()
            let loaded = try store.loadSettings().get()
            XCTAssertEqual(loaded.creatureRespawnFrequency, frequency)
            XCTAssertEqual(loaded.fov, 91)
            XCTAssertFalse(loaded.showMinimap)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with:
                Data(contentsOf: store.directoryURL.appendingPathComponent("settings.json")))
                as? [String: Any])
            XCTAssertEqual(object["creatureRespawnFrequency"] as? Int, frequency.dayCount)
            XCTAssertTrue(store.lastDiagnostics.isEmpty)
        }
    }

    func testMissingFrequencyPreservesLegacySettingsAndDefaultsDaily() throws {
        let store = try store(json: #"{"fov":91,"showMinimap":false}"#)
        let loaded = try store.loadSettings().get()
        XCTAssertEqual(loaded.creatureRespawnFrequency, .daily)
        XCTAssertEqual(loaded.fov, 91)
        XCTAssertFalse(loaded.showMinimap)
        XCTAssertTrue(store.lastDiagnostics.isEmpty)
    }

    func testMalformedAndUnsupportedFrequencyOnlyDefaultThatField() throws {
        for raw in ["0", "3", "-1", "999", "1.5", "true", "null", "{}", "[]", #""weekly""#] {
            let store = try store(json:
                "{\"creatureRespawnFrequency\":\(raw),\"fov\":91,\"showMinimap\":false}")
            let loaded = try store.loadSettings().get()
            XCTAssertEqual(loaded.creatureRespawnFrequency, .daily, raw)
            XCTAssertEqual(loaded.fov, 91, raw)
            XCTAssertFalse(loaded.showMinimap, raw)
            XCTAssertEqual(store.lastDiagnostics, [LocalSettingsDiagnostic(
                field: "creatureRespawnFrequency", reason: "invalid value")], raw)
        }
    }
}
