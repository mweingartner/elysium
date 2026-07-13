import XCTest
@testable import ElysiumCore

/// Covers the one-time rebrand migration that folds a former "Pebble" install's
/// data into the current "Elysium" layout.
final class BrandMigrationTests: XCTestCase {
    private var base: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory
            .appendingPathComponent("elysium-brandmigration-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func legacyDir() -> URL { base.appendingPathComponent("Pebble", isDirectory: true) }
    private func currentDir() -> URL { base.appendingPathComponent("Elysium", isDirectory: true) }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.data(using: .utf8)!.write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(data: try Data(contentsOf: url), encoding: .utf8)!
    }

    func testFoldsLegacyDirectoryAndRenamesDatabase() throws {
        try write("world-bytes", to: legacyDir().appendingPathComponent("pebble.db"))
        try write("wal-bytes", to: legacyDir().appendingPathComponent("pebble.db-wal"))
        try write("shm-bytes", to: legacyDir().appendingPathComponent("pebble.db-shm"))
        try write("{\"fov\":70}", to: legacyDir().appendingPathComponent("settings.json"))

        let moved = migrateLegacyBrandData(base: base)
        XCTAssertTrue(moved)

        // Legacy directory is gone; current directory holds the renamed DB set.
        XCTAssertFalse(fm.fileExists(atPath: legacyDir().path))
        XCTAssertEqual(try read(currentDir().appendingPathComponent("elysium.db")), "world-bytes")
        XCTAssertEqual(try read(currentDir().appendingPathComponent("elysium.db-wal")), "wal-bytes")
        XCTAssertEqual(try read(currentDir().appendingPathComponent("elysium.db-shm")), "shm-bytes")
        // Non-database files ride along untouched.
        XCTAssertEqual(try read(currentDir().appendingPathComponent("settings.json")), "{\"fov\":70}")
        XCTAssertFalse(fm.fileExists(atPath: currentDir().appendingPathComponent("pebble.db").path))
    }

    func testIsIdempotent() throws {
        try write("world-bytes", to: legacyDir().appendingPathComponent("pebble.db"))
        XCTAssertTrue(migrateLegacyBrandData(base: base))
        // Second pass has nothing to move.
        XCTAssertFalse(migrateLegacyBrandData(base: base))
        XCTAssertEqual(try read(currentDir().appendingPathComponent("elysium.db")), "world-bytes")
    }

    func testDoesNotClobberExistingCurrentData() throws {
        // Both brands present: the current install already owns its data.
        try write("legacy", to: legacyDir().appendingPathComponent("pebble.db"))
        try write("current", to: currentDir().appendingPathComponent("elysium.db"))

        XCTAssertFalse(migrateLegacyBrandData(base: base))

        // Current data is preserved; legacy folder is left intact, not merged.
        XCTAssertEqual(try read(currentDir().appendingPathComponent("elysium.db")), "current")
        XCTAssertTrue(fm.fileExists(atPath: legacyDir().appendingPathComponent("pebble.db").path))
    }

    func testNoLegacyDataIsANoOp() throws {
        XCTAssertFalse(migrateLegacyBrandData(base: base))
        XCTAssertFalse(fm.fileExists(atPath: currentDir().path))
    }

    func testRenamesDatabaseEvenWhenCurrentDirAlreadyExists() throws {
        // A partially-migrated state: dir already renamed, DB file not yet.
        try write("world-bytes", to: currentDir().appendingPathComponent("pebble.db"))

        XCTAssertTrue(migrateLegacyBrandData(base: base))
        XCTAssertEqual(try read(currentDir().appendingPathComponent("elysium.db")), "world-bytes")
    }
}
