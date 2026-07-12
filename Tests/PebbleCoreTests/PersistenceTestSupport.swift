import Foundation
import XCTest
@testable import PebbleCore

enum PersistenceTestSupport {
    static func makeDatabase(owner: XCTestCase,
                             label: String = "owner") throws -> SaveDB {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pebble-persistence-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let database = try SaveDB.open(databaseURL: directory.appendingPathComponent("pebble.db"),
                                       migrateLegacy: false)
        owner.addTeardownBlock {
            try? database.close()
            try? FileManager.default.removeItem(at: directory)
        }
        return database
    }

    static func makeGame(owner: XCTestCase, label: String = "game") -> GameCore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pebble-persistence-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let database = try SaveDB.open(
                databaseURL: directory.appendingPathComponent("pebble.db"), migrateLegacy: false)
            let game = GameCore(db: database)
            owner.addTeardownBlock {
                if game.hasWorld() { game.finalizeAndSave(synchronous: true) }
                try? database.close()
                try? FileManager.default.removeItem(at: directory)
            }
            return game
        } catch {
            XCTFail("unable to create unique Pebble test database")
            fatalError("unable to create unique Pebble test database")
        }
    }
}
