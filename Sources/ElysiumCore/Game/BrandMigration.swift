// Brand migration — folds data written by the former "Pebble" brand into the
// current "Elysium" layout on first launch.
//
// The historical install stored everything under
// ~/Library/Application Support/Pebble/ with the world database named
// `pebble.db` (plus `-wal`/`-shm` sidecars). The rebrand moved that to
// ~/Library/Application Support/Elysium/elysium.db. This migration performs the
// rename once, in place, so existing player worlds and settings survive the
// rebrand without a re-import.
//
// The legacy names ("Pebble", "pebble.db") are hard-coded here on purpose:
// they name the *old* on-disk location and must never be rebranded away.

import Foundation

/// Moves data written by the former "Pebble" brand into the current "Elysium"
/// layout under `base` (an Application Support root).
///
/// Idempotent and non-destructive: a file or directory is moved only when its
/// destination does not already exist, so repeated calls are safe and current
/// ("Elysium") data is never clobbered. Failures are swallowed — the legacy
/// data is left untouched and the game simply starts fresh rather than crashing.
///
/// Exposed (with an explicit `base`) so tests can exercise it against a temp dir.
/// - Returns: `true` if anything was moved.
@discardableResult
public func migrateLegacyBrandData(base: URL) -> Bool {
    let fm = FileManager.default
    let legacyDir = base.appendingPathComponent("Pebble", isDirectory: true)
    let currentDir = base.appendingPathComponent("Elysium", isDirectory: true)
    var moved = false

    func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    // 1) Fold the whole legacy directory across, but only if the current-brand
    //    directory does not exist yet (a fresh rebrand). If both exist, the new
    //    install already owns its data and we leave the legacy folder alone.
    if isDirectory(legacyDir) && !fm.fileExists(atPath: currentDir.path) {
        do {
            try fm.moveItem(at: legacyDir, to: currentDir)
            moved = true
        } catch {
            // Leave the legacy folder intact; nothing is lost.
        }
    }

    // 2) Rename the SQLite database and its WAL/SHM sidecars inside the current
    //    directory. Order matters: the main `.db` moves before its sidecars so
    //    an in-flight WAL always travels with the database it belongs to.
    if isDirectory(currentDir) {
        let renames = [
            ("pebble.db", "elysium.db"),
            ("pebble.db-wal", "elysium.db-wal"),
            ("pebble.db-shm", "elysium.db-shm"),
        ]
        for (legacyName, currentName) in renames {
            let src = currentDir.appendingPathComponent(legacyName)
            let dst = currentDir.appendingPathComponent(currentName)
            if fm.fileExists(atPath: src.path) && !fm.fileExists(atPath: dst.path) {
                do {
                    try fm.moveItem(at: src, to: dst)
                    moved = true
                } catch {
                    // Leave the source under its old name; the game starts fresh
                    // rather than crashing (the un-renamed file is simply ignored).
                }
            }
        }
    }

    return moved
}

/// Process-wide, run-exactly-once entry point for the legacy-brand migration.
///
/// Swift's lazy `static let` gives us dispatch-once semantics, so the migration
/// runs a single time no matter which support-directory chokepoint touches it
/// first. Callers use `_ = LegacyBrandMigration.runOnce`.
public enum LegacyBrandMigration {
    public static let runOnce: Void = {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        migrateLegacyBrandData(base: base)
    }()
}
