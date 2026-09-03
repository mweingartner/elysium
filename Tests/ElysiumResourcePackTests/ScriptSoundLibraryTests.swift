import Darwin
import Foundation
import Metal
import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class ScriptSoundLibraryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let imported: URL
        let system: URL
        let tones: URL
    }

    private func makeFixture() throws -> Fixture {
        // Keep the entire fixture below the canonical `/private/tmp` root. The production
        // library deliberately rejects symlinked path components, while Foundation's
        // temporaryDirectory is normally reached through the `/var` symlink on macOS.
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("elysium-script-sounds-\(UUID().uuidString)",
                                    isDirectory: true)
        let fixture = Fixture(
            root: root,
            imported: root.appendingPathComponent("Imported", isDirectory: true),
            system: root.appendingPathComponent("System", isDirectory: true),
            tones: root.appendingPathComponent("Tones", isDirectory: true)
        )
        for directory in [fixture.root, fixture.imported, fixture.system, fixture.tones] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        }
        return fixture
    }

    private func removeFixture(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private func library(_ fixture: Fixture) -> ScriptSoundLibrary {
        ScriptSoundLibrary(
            directoryURL: fixture.imported,
            systemSoundDirectories: [fixture.system],
            toneLibraryDirectories: [fixture.tones]
        )
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private func pcmWAV(
        frames: Int = 80,
        sampleRate: UInt32 = 8_000,
        channels: UInt16 = 1,
        bitsPerSample: UInt16 = 16
    ) -> Data {
        precondition(frames >= 0)
        precondition(bitsPerSample == 8 || bitsPerSample == 16)
        let bytesPerSample = Int(bitsPerSample / 8)
        let payloadByteCount = frames * Int(channels) * bytesPerSample
        precondition(payloadByteCount <= Int(UInt32.max) - 36)

        let blockAlign = channels * (bitsPerSample / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        var data = Data("RIFF".utf8)
        appendLittleEndian(UInt32(36 + payloadByteCount), to: &data)
        data.append(contentsOf: Data("WAVE".utf8))
        data.append(contentsOf: Data("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)
        appendLittleEndian(UInt16(1), to: &data) // Linear PCM.
        appendLittleEndian(channels, to: &data)
        appendLittleEndian(sampleRate, to: &data)
        appendLittleEndian(byteRate, to: &data)
        appendLittleEndian(blockAlign, to: &data)
        appendLittleEndian(bitsPerSample, to: &data)
        data.append(contentsOf: Data("data".utf8))
        appendLittleEndian(UInt32(payloadByteCount), to: &data)
        data.append(Data(repeating: bitsPerSample == 8 ? 0x80 : 0, count: payloadByteCount))
        return data
    }

    @discardableResult
    private func writeWAV(
        named name: String,
        in directory: URL,
        frames: Int = 80,
        bitsPerSample: UInt16 = 16
    ) throws -> URL {
        let url = directory.appendingPathComponent(name, isDirectory: false)
        try pcmWAV(frames: frames, bitsPerSample: bitsPerSample)
            .write(to: url, options: .withoutOverwriting)
        return url
    }

    func testSystemAndToneCatalogEnumerationIsDeterministicAndCaseInsensitive() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }

        // The system catalog uses AIFF filenames on macOS. The fixture contains PCM WAVE bytes
        // under that extension so it remains tiny while still being decodable by Core Audio.
        try pcmWAV().write(
            to: fixture.system.appendingPathComponent("Zulu.aiff"),
            options: .withoutOverwriting
        )
        try pcmWAV().write(
            to: fixture.system.appendingPathComponent("alpha.AIFF"),
            options: .withoutOverwriting
        )
        try writeWAV(named: "Sonar.wav", in: fixture.tones)
        try Data("not audio".utf8).write(
            to: fixture.system.appendingPathComponent("Ignored.txt"),
            options: .withoutOverwriting
        )

        let first = library(fixture)
        let second = library(fixture)
        XCTAssertEqual(first.entries.map(\.id), second.entries.map(\.id))
        XCTAssertEqual(first.entries.map(\.name), second.entries.map(\.name))

        let alpha = try XCTUnwrap(first.entries.first { $0.name == "alpha" })
        let sonar = try XCTUnwrap(first.entries.first { $0.name == "Sonar" })
        let zulu = try XCTUnwrap(first.entries.first { $0.name == "Zulu" })
        XCTAssertEqual(alpha.source, .system)
        XCTAssertEqual(sonar.source, .toneLibrary)
        XCTAssertEqual(zulu.source, .system)
        XCTAssertGreaterThan(alpha.byteCount, 0)
        XCTAssertFalse(first.names.contains("Ignored"))

        let fixtureNames = first.names.filter { ["alpha", "Sonar", "Zulu"].contains($0) }
        XCTAssertEqual(fixtureNames, ["alpha", "Sonar", "Zulu"],
                       "catalog names must have one stable, case-insensitive sort order")
        XCTAssertTrue(first.play(name: "ALPHA", volume: 0, pan: 0))
        XCTAssertTrue(first.play(name: "sOnAr", volume: 0, pan: 0))
        XCTAssertFalse(first.play(name: "definitely-not-an-installed-sound", volume: 0, pan: 0))
    }

    func testPCMImportPersistsMetadataAndCanBeDeletedByOpaqueID() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        let source = try writeWAV(named: "Door Chime.wav", in: fixture.root)

        let initial = library(fixture)
        let imported = try initial.importSound(from: source)
        XCTAssertEqual(imported.name, "Door Chime")
        XCTAssertEqual(imported.source, .imported)
        XCTAssertEqual(imported.byteCount, pcmWAV().count)
        XCTAssertEqual(try XCTUnwrap(imported.duration), 0.01, accuracy: 0.002)
        XCTAssertEqual(initial.importedEntries.map(\.id), [imported.id])
        XCTAssertTrue(initial.names.contains("Door Chime"))
        XCTAssertTrue(initial.play(name: "dOoR cHiMe", volume: 0, pan: 0))
        initial.reload()
        XCTAssertEqual(initial.importedEntries.map(\.id), [imported.id])

        let reloaded = library(fixture)
        let persisted = try XCTUnwrap(reloaded.importedEntries.first)
        XCTAssertEqual(persisted.id, imported.id, "IDs exposed to scripts must survive relaunch")
        XCTAssertEqual(persisted.name, imported.name)
        XCTAssertEqual(persisted.byteCount, imported.byteCount)
        XCTAssertEqual(
            try XCTUnwrap(persisted.duration), try XCTUnwrap(imported.duration),
            accuracy: 0.000_1
        )

        try reloaded.deleteImportedSound(id: persisted.id)
        XCTAssertTrue(reloaded.importedEntries.isEmpty)
        XCTAssertFalse(reloaded.names.contains("Door Chime"))
        XCTAssertFalse(reloaded.play(name: "Door Chime", volume: 0, pan: 0))

        let afterRelaunch = library(fixture)
        XCTAssertTrue(afterRelaunch.importedEntries.isEmpty)
    }

    func testImportRejectsSpoofedMalformedAndWrongExtensionInputs() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        let sounds = library(fixture)

        let spoofed = fixture.root.appendingPathComponent("Spoofed.wav")
        try Data("this is not a RIFF/WAVE file".utf8)
            .write(to: spoofed, options: .withoutOverwriting)
        XCTAssertThrowsError(try sounds.importSound(from: spoofed))

        let tiny = fixture.root.appendingPathComponent("Tiny.wav")
        try Data("RIFF".utf8).write(to: tiny, options: .withoutOverwriting)
        XCTAssertThrowsError(try sounds.importSound(from: tiny)) { error in
            XCTAssertEqual(error as? ScriptSoundLibraryError, .invalidWAV)
        }

        var truncated = pcmWAV()
        truncated.removeLast(10)
        let truncatedURL = fixture.root.appendingPathComponent("Truncated.wav")
        try truncated.write(to: truncatedURL, options: .withoutOverwriting)
        XCTAssertThrowsError(try sounds.importSound(from: truncatedURL))

        let wrongExtension = fixture.root.appendingPathComponent("Disguised.mp3")
        try pcmWAV().write(to: wrongExtension, options: .withoutOverwriting)
        XCTAssertThrowsError(try sounds.importSound(from: wrongExtension))

        let bidiName = fixture.root.appendingPathComponent("Spoof\u{202E}wav.wav")
        try pcmWAV().write(to: bidiName, options: .withoutOverwriting)
        XCTAssertThrowsError(try sounds.importSound(from: bidiName)) { error in
            XCTAssertEqual(error as? ScriptSoundLibraryError, .invalidName)
        }
        XCTAssertTrue(sounds.importedEntries.isEmpty)
    }

    func testImportRejectsOversizedAndOverDurationWAVs() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        let sounds = library(fixture)

        let oversized = try writeWAV(named: "Oversized.wav", in: fixture.root)
        let oversizedHandle = try FileHandle(forWritingTo: oversized)
        try oversizedHandle.truncate(
            atOffset: UInt64(ScriptSoundLibrary.maximumFileBytes) + 1
        )
        try oversizedHandle.close()
        XCTAssertThrowsError(try sounds.importSound(from: oversized))

        let overDurationFrames = Int(
            (ScriptSoundLibrary.maximumDurationSeconds * 8_000).rounded(.down)
        ) + 8
        let overDurationBytes = 44 + overDurationFrames
        guard overDurationBytes <= ScriptSoundLibrary.maximumFileBytes else {
            throw XCTSkip("duration boundary cannot be isolated from the configured file cap")
        }
        let tooLong = fixture.root.appendingPathComponent("Too Long.wav")
        try pcmWAV(frames: overDurationFrames, bitsPerSample: 8)
            .write(to: tooLong, options: .withoutOverwriting)
        XCTAssertThrowsError(try sounds.importSound(from: tooLong))
        XCTAssertTrue(sounds.importedEntries.isEmpty)
    }

    func testImportRejectsSymlinksAndMultiplyLinkedFiles() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        let sounds = library(fixture)
        let target = try writeWAV(named: "Link Target.wav", in: fixture.root)

        let symbolic = fixture.root.appendingPathComponent("Symbolic.wav")
        try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: target)
        XCTAssertThrowsError(try sounds.importSound(from: symbolic))

        let hard = fixture.root.appendingPathComponent("Hard.wav")
        XCTAssertEqual(link(target.path, hard.path), 0)
        XCTAssertThrowsError(try sounds.importSound(from: hard))
        XCTAssertTrue(sounds.importedEntries.isEmpty)
    }

    func testCaseFoldDuplicatesAndBuiltInShadowingAreRejected() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        try pcmWAV().write(
            to: fixture.system.appendingPathComponent("Glass.aiff"),
            options: .withoutOverwriting
        )
        let sounds = library(fixture)

        let bell = try writeWAV(named: "Bell.wav", in: fixture.root)
        _ = try sounds.importSound(from: bell)
        let duplicateDirectory = fixture.root.appendingPathComponent("Duplicate", isDirectory: true)
        try FileManager.default.createDirectory(
            at: duplicateDirectory, withIntermediateDirectories: false
        )
        let duplicate = try writeWAV(named: "bELL.WAV", in: duplicateDirectory)
        XCTAssertThrowsError(try sounds.importSound(from: duplicate))

        let shadowsBuiltIn = try writeWAV(named: "gLaSs.wav", in: fixture.root)
        XCTAssertThrowsError(try sounds.importSound(from: shadowsBuiltIn))
        XCTAssertEqual(sounds.importedEntries.map(\.name), ["Bell"])
        XCTAssertEqual(Array(sounds.names.prefix(2)), ["Bell", "Glass"],
                       "imports must precede the deterministic macOS section for completion")
    }

    func testImportedSoundCountRemainsBounded() throws {
        let limit = ScriptSoundLibrary.maximumImportedSounds
        XCTAssertGreaterThan(ScriptSoundLibrary.maximumFileBytes, 44)
        XCTAssertGreaterThan(ScriptSoundLibrary.maximumDurationSeconds, 0)
        XCTAssertGreaterThanOrEqual(
            ScriptSoundLibrary.maximumAggregateBytes,
            ScriptSoundLibrary.maximumFileBytes
        )
        guard limit > 0, limit <= 512 else {
            throw XCTSkip("configured import count is unsuitable for a focused unit boundary test")
        }
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        let sounds = library(fixture)

        for index in 0..<limit {
            let source = try writeWAV(
                named: String(format: "Bounded-%04d.wav", index),
                in: fixture.root
            )
            _ = try sounds.importSound(from: source)
        }
        XCTAssertEqual(sounds.importedEntries.count, limit)

        let excess = try writeWAV(named: "Excess.wav", in: fixture.root, frames: 1)
        XCTAssertThrowsError(try sounds.importSound(from: excess))
        XCTAssertEqual(sounds.importedEntries.count, limit)
    }

    func testTamperedManagedDirectoryCannotExpandThePlayableCatalogPastItsCap() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        for index in 0..<(ScriptSoundLibrary.maximumImportedSounds + 4) {
            _ = try writeWAV(
                named: String(format: "Tampered-%04d.wav", index),
                in: fixture.imported
            )
        }

        let sounds = library(fixture)

        XCTAssertEqual(
            sounds.importedEntries.count, ScriptSoundLibrary.maximumImportedSounds
        )
        XCTAssertEqual(sounds.entries.count, ScriptSoundLibrary.maximumImportedSounds)
        let extra = try writeWAV(named: "Refused.wav", in: fixture.root)
        XCTAssertThrowsError(try sounds.importSound(from: extra)) { error in
            XCTAssertEqual(
                error as? ScriptSoundLibraryError,
                .catalogFull(maximumCount: ScriptSoundLibrary.maximumImportedSounds)
            )
        }
    }

    func testManagedFileReplacementMustRevalidateBeforePlayback() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        let source = try writeWAV(named: "Replace Me.wav", in: fixture.root)
        let sounds = library(fixture)
        _ = try sounds.importSound(from: source)
        let managed = fixture.imported.appendingPathComponent("Replace Me.wav")
        try FileManager.default.removeItem(at: managed)
        try Data("not a wav".utf8).write(to: managed, options: .withoutOverwriting)

        XCTAssertFalse(sounds.play(name: "Replace Me", volume: 0, pan: 0))
        XCTAssertFalse(sounds.contains(name: "Replace Me"))

        try FileManager.default.removeItem(at: managed)
        try pcmWAV().write(to: managed, options: .withoutOverwriting)
        sounds.reload()
        XCTAssertTrue(sounds.contains(name: "Replace Me"))
        XCTAssertTrue(sounds.play(name: "Replace Me", volume: 0, pan: 0))
    }

    func testPlaybackSaturationRejectsBeforeAdditionalManagedReadsOrConstruction() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        var work: [ScriptSoundLibraryWorkEvent] = []
        let sounds = ScriptSoundLibrary(
            directoryURL: fixture.imported,
            systemSoundDirectories: [fixture.system],
            toneLibraryDirectories: [fixture.tones],
            workObserver: { work.append($0) }
        )
        let source = try writeWAV(
            named: "Long Bell.wav", in: fixture.root, frames: 8_000 * 10
        )
        _ = try sounds.importSound(from: source)
        work.removeAll(keepingCapacity: true)

        let attemptCount = ScriptSoundLibrary.maximumConcurrentPlayers + 8
        let results = (0..<attemptCount).map { _ in
            sounds.play(name: "Long Bell", volume: 0, pan: 0)
        }

        XCTAssertEqual(
            work.filter { $0 == .managedRead }.count,
            ScriptSoundLibrary.maximumConcurrentPlayers
        )
        XCTAssertEqual(
            work.filter { $0 == .playbackPlayerConstruction }.count,
            ScriptSoundLibrary.maximumConcurrentPlayers
        )
        XCTAssertTrue(
            results.dropFirst(ScriptSoundLibrary.maximumConcurrentPlayers).allSatisfy { !$0 },
            "saturated requests must reject before file I/O or AVAudioPlayer construction"
        )
        sounds.stopAll()
    }

    func testDiscoveryPreflightsAggregateRegularBytesBeforeAnyManagedRead() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        let fileCount = ScriptSoundLibrary.maximumAggregateBytes
            / ScriptSoundLibrary.maximumFileBytes + 1
        XCTAssertLessThan(fileCount, ScriptSoundLibrary.maximumManagedDirectoryEntries)
        for index in 0..<fileCount {
            let url = fixture.imported.appendingPathComponent(
                String(format: "Invalid-%03d.wav", index)
            )
            XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(ScriptSoundLibrary.maximumFileBytes))
            try handle.close()
        }
        var work: [ScriptSoundLibraryWorkEvent] = []

        let sounds = ScriptSoundLibrary(
            directoryURL: fixture.imported,
            systemSoundDirectories: [fixture.system],
            toneLibraryDirectories: [fixture.tones],
            workObserver: { work.append($0) }
        )

        XCTAssertTrue(sounds.importedEntries.isEmpty)
        XCTAssertFalse(work.contains(.managedRead),
                       "an over-budget directory must fail closed before reading WAV bodies")
        let source = try writeWAV(named: "Still Full.wav", in: fixture.root)
        XCTAssertThrowsError(try sounds.importSound(from: source)) { error in
            XCTAssertEqual(
                error as? ScriptSoundLibraryError,
                .storageFull(maximumBytes: ScriptSoundLibrary.maximumAggregateBytes)
            )
        }
        XCTAssertFalse(work.contains(.managedRead))
    }

    func testAggregateStorageLimitCountsUnexpectedRegularFilesConservatively() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        let filler = fixture.imported.appendingPathComponent("unmanaged.bin")
        FileManager.default.createFile(atPath: filler.path, contents: nil)
        let handle = try FileHandle(forWritingTo: filler)
        try handle.truncate(atOffset: UInt64(ScriptSoundLibrary.maximumAggregateBytes))
        try handle.close()

        let sounds = library(fixture)
        let source = try writeWAV(named: "No Room.wav", in: fixture.root)
        XCTAssertThrowsError(try sounds.importSound(from: source)) { error in
            XCTAssertEqual(
                error as? ScriptSoundLibraryError,
                .storageFull(maximumBytes: ScriptSoundLibrary.maximumAggregateBytes)
            )
        }
        XCTAssertTrue(sounds.importedEntries.isEmpty)
    }

    func testAudioOptionsExposeScriptSoundLibraryToKeyboardAndAccessibility() throws {
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ui = UIManager(cv: UICanvas(device: device))
        ui.resize(480, 270, 1)
        let databaseURL = fixtureDatabaseURL()
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let screen = SettingsScreen()
        screen.tab = "audio"
        ui.open(screen, game)

        let descriptor = try XCTUnwrap(
            screen.textAccessibilityDescriptors(ui, game)
                .first { $0.id == "audio.script-sounds" }
        )
        XCTAssertEqual(descriptor.label, "Script Sounds…")
        XCTAssertTrue(descriptor.enabled)
        XCTAssertTrue(descriptor.focusable)
        XCTAssertTrue(descriptor.actionable)
        XCTAssertTrue(
            screen.focusTextAccessibilityElement("audio.script-sounds", ui, game)
        )
    }

    func testSoundLibraryWheelCanReachRowsBeyondTheFirstPage() throws {
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        let fixture = try makeFixture()
        defer { removeFixture(fixture) }
        for index in 0..<12 {
            _ = try writeWAV(
                named: String(format: "Sound %02d.wav", index), in: fixture.imported
            )
        }
        let sounds = library(fixture)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ui = UIManager(cv: UICanvas(device: device))
        ui.resize(480, 270, 1)
        let databaseURL = fixtureDatabaseURL()
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let screen = SoundLibraryScreen(library: sounds)
        ui.open(screen, game)

        let visibleLabels = {
            screen.textAccessibilityDescriptors(ui, game)
                .filter { $0.id.hasPrefix("sound-library.row.") }
                .map(\.label)
        }
        XCTAssertEqual(visibleLabels().first, "Sound 00")

        XCTAssertTrue(screen.onWheel(ui, game, -1))

        XCTAssertEqual(visibleLabels().first, "Sound 01")
        XCTAssertTrue(visibleLabels().contains("Sound 07"))
    }

    private func fixtureDatabaseURL() -> URL {
        URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("elysium-script-sounds-\(UUID().uuidString).sqlite")
    }
}
