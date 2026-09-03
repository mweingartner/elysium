// ScriptSoundLibrary.swift — the app-owned boundary for script-playable audio.
//
// Lua receives names only. It can never provide a path: imported WAV files are copied into a
// bounded Application Support directory, catalogued by a validated stem, and reopened with
// no-follow descriptor reads before playback. macOS sounds are discovered from the same public
// system-sound directory NSSound searches plus the modern ToneLibrary locations used by Hype.

import AppKit
import AVFoundation
import Darwin
import ElysiumCore
import Foundation
import UniformTypeIdentifiers

struct ScriptSoundEntry: Equatable, Identifiable {
    enum Source: String, Equatable {
        case system
        case toneLibrary
        case imported

        var displayName: String {
            switch self {
            case .system: return "macOS System"
            case .toneLibrary: return "macOS Tone"
            case .imported: return "Imported WAV"
            }
        }
    }

    let id: String
    let name: String
    let source: Source
    let byteCount: Int
    let duration: TimeInterval?
    fileprivate let fileName: String
    fileprivate let systemURL: URL?
}

enum ScriptSoundLibraryError: Error, Equatable, LocalizedError {
    case storageUnavailable
    case sourceUnavailable
    case sourceIsNotRegular
    case sourceHasMultipleLinks
    case wavRequired
    case invalidWAV
    case invalidName
    case fileTooLarge(maximumBytes: Int)
    case durationTooLong(maximumSeconds: Int)
    case unsupportedChannels
    case catalogFull(maximumCount: Int)
    case storageFull(maximumBytes: Int)
    case nameConflictsWithSystem(String)
    case nameAlreadyImported(String)
    case importFailed
    case importedSoundNotFound
    case deleteFailed

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "The Elysium Sounds folder is unavailable."
        case .sourceUnavailable:
            return "The selected file could not be opened."
        case .sourceIsNotRegular:
            return "Choose a regular WAV file, not a folder, link, or special file."
        case .sourceHasMultipleLinks:
            return "Hard-linked WAV files are not accepted; make a standalone copy first."
        case .wavRequired:
            return "Only .wav files can be imported."
        case .invalidWAV:
            return "The selected file is not a valid playable WAV file."
        case .invalidName:
            return "The WAV filename must have a short, visible name without path separators."
        case .fileTooLarge(let maximumBytes):
            return "The WAV is too large (maximum \(maximumBytes / (1024 * 1024)) MB)."
        case .durationTooLong(let maximumSeconds):
            return "The WAV is too long (maximum \(maximumSeconds) seconds)."
        case .unsupportedChannels:
            return "The WAV must be mono or stereo."
        case .catalogFull(let maximumCount):
            return "The imported sound library is full (maximum \(maximumCount) files)."
        case .storageFull(let maximumBytes):
            return "Imported sounds would exceed the \(maximumBytes / (1024 * 1024)) MB library limit."
        case .nameConflictsWithSystem(let name):
            return "“\(name)” is already a macOS sound name. Rename the WAV before importing it."
        case .nameAlreadyImported(let name):
            return "“\(name)” is already imported. Delete it first or use a different filename."
        case .importFailed:
            return "The WAV could not be copied into Elysium."
        case .importedSoundNotFound:
            return "That imported sound is no longer available."
        case .deleteFailed:
            return "The imported sound could not be deleted."
        }
    }
}

enum ScriptSoundLibraryWorkEvent: Equatable {
    case managedRead
    case playbackPlayerConstruction
}

@MainActor
final class ScriptSoundLibrary: NSObject {
    static let maximumFileBytes = 16 * 1024 * 1024
    static let maximumDurationSeconds: Double = 120
    static let maximumImportedSounds = 256
    static let maximumAggregateBytes = 256 * 1024 * 1024
    static let maximumNameBytes = 128
    static let maximumConcurrentPlayers = 8
    /// Includes invalid and unexpected directory entries. Crossing this tamper boundary makes
    /// discovery fail closed instead of allocating or decoding an attacker-sized directory.
    static let maximumManagedDirectoryEntries = maximumImportedSounds * 2

    static let defaultSystemSoundDirectories = [
        URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true),
    ]

    static let defaultToneLibraryDirectories = [
        URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/AlertTones", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/Resources/AlertTones", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/PrivateFrameworks/ToneLibrary.framework/Resources/Ringtones", isDirectory: true),
    ]

    private static let playableSystemExtensions: Set<String> = [
        "aif", "aiff", "caf", "m4a", "m4r", "mp3", "wav",
    ]
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    let directoryURL: URL
    private let systemSoundDirectories: [URL]
    private let toneLibraryDirectories: [URL]
    private(set) var entries: [ScriptSoundEntry] = []
    private(set) var importedEntries: [ScriptSoundEntry] = []
    private(set) var systemEntries: [ScriptSoundEntry] = []
    private var entriesByKey: [String: ScriptSoundEntry] = [:]
    private var activePlayers: [ObjectIdentifier: AVAudioPlayer] = [:]
    private var activePlayerAdmissions: [ObjectIdentifier: UUID] = [:]
    private var playbackAdmissions: Set<UUID> = []
    private var knownMetadata: [String: ImportedSoundMetadata] = [:]
    private var regularStorageFileCount = 0
    private var regularStorageByteCount = 0
    private let workObserver: @MainActor (ScriptSoundLibraryWorkEvent) -> Void

    var names: [String] { entries.map(\.name) }

    func contains(name rawName: String) -> Bool {
        let requested = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !requested.isEmpty && entriesByKey[canonicalKey(requested)] != nil
    }

    init(
        directoryURL: URL = vcSupportDir().appendingPathComponent("Sounds", isDirectory: true),
        systemSoundDirectories: [URL]? = nil,
        toneLibraryDirectories: [URL]? = nil,
        workObserver: @escaping @MainActor (ScriptSoundLibraryWorkEvent) -> Void = { _ in }
    ) {
        self.directoryURL = directoryURL
        self.systemSoundDirectories = systemSoundDirectories ?? Self.defaultSystemSoundDirectories
        self.toneLibraryDirectories = toneLibraryDirectories ?? Self.defaultToneLibraryDirectories
        self.workObserver = workObserver
        super.init()
        _ = ensureStorageDirectory()
        rebuildCatalog()
    }

    func reload() {
        let prior = entries
        rebuildCatalog()
        if entries != prior {
            NotificationCenter.default.post(name: .elysiumScriptSoundCatalogDidChange, object: self)
        }
    }

    @discardableResult
    func importSound(from sourceURL: URL) throws -> ScriptSoundEntry {
        guard sourceURL.pathExtension.lowercased() == "wav" else {
            throw ScriptSoundLibraryError.wavRequired
        }
        let name = try validatedImportedName(
            sourceURL.deletingPathExtension().lastPathComponent
        )
        let bytes = try snapshotExternalWAV(sourceURL)
        _ = try validateWAV(bytes)

        rebuildCatalog()
        let key = canonicalKey(name)
        if systemEntries.contains(where: { canonicalKey($0.name) == key }) {
            throw ScriptSoundLibraryError.nameConflictsWithSystem(name)
        }
        if importedEntries.contains(where: { canonicalKey($0.name) == key }) {
            throw ScriptSoundLibraryError.nameAlreadyImported(name)
        }
        guard regularStorageFileCount < Self.maximumImportedSounds else {
            throw ScriptSoundLibraryError.catalogFull(maximumCount: Self.maximumImportedSounds)
        }
        guard bytes.count <= Self.maximumAggregateBytes - min(
            regularStorageByteCount, Self.maximumAggregateBytes
        ) else {
            throw ScriptSoundLibraryError.storageFull(maximumBytes: Self.maximumAggregateBytes)
        }

        let finalName = name + ".wav"
        try atomicInstall(bytes, fileName: finalName)
        rebuildCatalog()
        guard let result = importedEntries.first(where: { canonicalKey($0.name) == key }) else {
            throw ScriptSoundLibraryError.importFailed
        }
        NotificationCenter.default.post(name: .elysiumScriptSoundCatalogDidChange, object: self)
        return result
    }

    func deleteImportedSound(id: String) throws {
        rebuildCatalog()
        guard let entry = importedEntries.first(where: { $0.id == id }),
              safeManagedFileName(entry.fileName),
              let directoryFD = openStorageDirectory()
        else { throw ScriptSoundLibraryError.importedSoundNotFound }
        defer { _ = Darwin.close(directoryFD) }

        var status = stat()
        guard fstatat(directoryFD, entry.fileName, &status, AT_SYMLINK_NOFOLLOW) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1 else {
            throw ScriptSoundLibraryError.importedSoundNotFound
        }
        guard Darwin.unlinkat(directoryFD, entry.fileName, 0) == 0 else {
            throw ScriptSoundLibraryError.deleteFailed
        }
        guard syncDescriptor(directoryFD) else { throw ScriptSoundLibraryError.deleteFailed }
        knownMetadata.removeValue(forKey: entry.fileName)
        rebuildCatalog()
        NotificationCenter.default.post(name: .elysiumScriptSoundCatalogDidChange, object: self)
    }

    @discardableResult
    func play(name rawName: String, volume: Float, pan: Float) -> Bool {
        let requested = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requested.isEmpty,
              let entry = entriesByKey[canonicalKey(requested)] else { return false }
        prunePlayers()
        guard playbackAdmissions.count < Self.maximumConcurrentPlayers else { return false }
        let admission = UUID()
        playbackAdmissions.insert(admission)
        var keepsAdmission = false
        defer {
            if !keepsAdmission { releasePlaybackAdmissionAfterCurrentTurn(admission) }
        }

        let player: AVAudioPlayer
        do {
            if entry.source == .imported {
                guard let expectedIdentity = knownMetadata[entry.fileName]?.identity,
                      let data = readManagedWAV(
                        fileName: entry.fileName, expectedIdentity: expectedIdentity
                      ) else {
                    // A user may edit Application Support outside Elysium. Rebuild so a replaced
                    // file must cross the full structural/duration/channel validator before a
                    // later request can play it.
                    reload()
                    return false
                }
                workObserver(.playbackPlayerConstruction)
                player = try AVAudioPlayer(data: data)
            } else {
                guard let url = entry.systemURL else { return false }
                workObserver(.playbackPlayerConstruction)
                player = try AVAudioPlayer(contentsOf: url)
            }
        } catch {
            return false
        }
        player.volume = min(1, max(0, volume.isFinite ? volume : 0))
        player.pan = min(1, max(-1, pan.isFinite ? pan : 0))
        player.delegate = self
        guard player.prepareToPlay(), player.play() else { return false }
        let identity = ObjectIdentifier(player)
        activePlayers[identity] = player
        activePlayerAdmissions[identity] = admission
        keepsAdmission = true
        return true
    }

    func stopAll() {
        for player in activePlayers.values { player.stop() }
        activePlayers.removeAll(keepingCapacity: true)
        activePlayerAdmissions.removeAll(keepingCapacity: true)
        playbackAdmissions.removeAll(keepingCapacity: true)
    }

    private func rebuildCatalog() {
        let system = discoverSystemSounds()
        let reserved = Set(system.map { canonicalKey($0.name) })
        let imported = discoverImportedSounds(excluding: reserved)

        systemEntries = system
        importedEntries = imported
        // User imports lead the script-completion catalog so a bounded completion menu cannot
        // hide them behind the much larger ToneLibrary list. Each section is independently and
        // deterministically sorted by its discovery routine.
        entries = imported + system
        entriesByKey = Dictionary(
            entries.map { (canonicalKey($0.name), $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func discoverSystemSounds() -> [ScriptSoundEntry] {
        var chosen: [String: ScriptSoundEntry] = [:]
        for (source, directories) in [
            (ScriptSoundEntry.Source.system, systemSoundDirectories),
            (.toneLibrary, toneLibraryDirectories),
        ] {
            for directory in directories {
                for url in regularAudioURLs(in: directory) {
                    let name = systemDisplayName(for: url, source: source)
                    guard let validName = try? validatedCatalogName(name) else { continue }
                    let key = canonicalKey(validName)
                    guard chosen[key] == nil else { continue }
                    let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    chosen[key] = ScriptSoundEntry(
                        id: source.rawValue + ":" + key,
                        name: validName,
                        source: source,
                        byteCount: max(0, bytes),
                        duration: nil,
                        fileName: url.lastPathComponent,
                        systemURL: url
                    )
                }
            }
        }
        return chosen.values.sorted(by: entryLess)
    }

    private func regularAudioURLs(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard Self.playableSystemExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey,
                  ]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else { continue }
            result.append(url)
        }
        return result.sorted { utf8Less($0.path, $1.path) }
    }

    private func systemDisplayName(
        for url: URL, source: ScriptSoundEntry.Source
    ) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        guard source == .toneLibrary,
              let dash = stem.range(of: "-", options: .backwards) else { return stem }
        let suffix = String(stem[dash.upperBound...])
        let parent = url.deletingLastPathComponent().lastPathComponent
        if suffix == parent { stem = String(stem[..<dash.lowerBound]) }
        return stem
    }

    private func discoverImportedSounds(excluding reserved: Set<String>) -> [ScriptSoundEntry] {
        regularStorageFileCount = 0
        regularStorageByteCount = 0
        guard let directoryFD = openStorageDirectory() else {
            regularStorageFileCount = Int.max
            regularStorageByteCount = Int.max
            return []
        }
        defer { _ = Darwin.close(directoryFD) }
        guard let names = directoryNames(
            directoryFD, maximumEntries: Self.maximumManagedDirectoryEntries
        ) else {
            regularStorageFileCount = Int.max
            regularStorageByteCount = Int.max
            return []
        }

        // Preflight every regular entry before reading any of them. Invalid WAVs still consume
        // inspection budget: otherwise hundreds of maximum-sized malformed files could each be
        // copied into memory and handed to Core Audio during one startup scan.
        var regularFiles: [(name: String, status: stat)] = []
        for fileName in names {
            var status = stat()
            guard fstatat(directoryFD, fileName, &status, AT_SYMLINK_NOFOLLOW) == 0,
                  (status.st_mode & S_IFMT) == S_IFREG else { continue }
            let (nextCount, countOverflow) = regularStorageFileCount.addingReportingOverflow(1)
            regularStorageFileCount = countOverflow ? Int.max : nextCount
            guard status.st_size >= 0, status.st_size <= off_t(Int.max) else {
                regularStorageByteCount = Int.max
                knownMetadata.removeAll(keepingCapacity: true)
                return []
            }
            let byteCount = Int(status.st_size)
            guard byteCount <= Self.maximumAggregateBytes - regularStorageByteCount else {
                regularStorageByteCount = Int.max
                knownMetadata.removeAll(keepingCapacity: true)
                return []
            }
            regularStorageByteCount += byteCount
            regularFiles.append((fileName, status))
        }

        var chosen: [String: ScriptSoundEntry] = [:]
        var admittedByteCount = 0
        for (fileName, status) in regularFiles {

            guard status.st_nlink == 1,
                  status.st_size >= 12,
                  status.st_size <= off_t(Self.maximumFileBytes),
                  fileName.pathExtensionLowercased == "wav",
                  safeManagedFileName(fileName),
                  let name = try? validatedImportedName(
                    (fileName as NSString).deletingPathExtension
                  ) else { continue }
            let key = canonicalKey(name)
            guard !reserved.contains(key), chosen[key] == nil,
                  chosen.count < Self.maximumImportedSounds else { continue }
            let byteCount = Int(status.st_size)
            guard byteCount <= Self.maximumAggregateBytes - admittedByteCount else { continue }
            let identity = FileIdentity(status)
            let duration: TimeInterval
            if let cached = knownMetadata[fileName], cached.identity == identity {
                duration = cached.duration
            } else {
                guard let bytes = readManagedWAV(
                    directoryFD: directoryFD, fileName: fileName, identity: identity
                ), let validated = try? validateWAV(bytes) else { continue }
                duration = validated.duration
                knownMetadata[fileName] = ImportedSoundMetadata(
                    identity: identity, duration: duration
                )
            }
            chosen[key] = ScriptSoundEntry(
                id: ScriptSoundEntry.Source.imported.rawValue + ":" + key,
                name: name,
                source: .imported,
                byteCount: byteCount,
                duration: duration,
                fileName: fileName,
                systemURL: nil
            )
            admittedByteCount += byteCount
        }
        let retainedFiles = Set(chosen.values.map(\.fileName))
        knownMetadata = knownMetadata.filter { retainedFiles.contains($0.key) }
        return chosen.values.sorted(by: entryLess)
    }

    private func ensureStorageDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directoryURL, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return openStorageDirectory().map { Darwin.close($0) == 0 } ?? false
        } catch {
            return false
        }
    }

    private func openStorageDirectory() -> Int32? {
        let fd = Darwin.open(
            directoryURL.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard fd >= 0 else { return nil }
        var status = stat()
        guard fstat(fd, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
            _ = Darwin.close(fd)
            return nil
        }
        return fd
    }

    private func snapshotExternalWAV(_ url: URL) throws -> Data {
        let parentFD = Darwin.open(
            url.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard parentFD >= 0 else { throw ScriptSoundLibraryError.sourceUnavailable }
        defer { _ = Darwin.close(parentFD) }

        let fileName = url.lastPathComponent
        guard safeManagedFileName(fileName) else { throw ScriptSoundLibraryError.invalidName }
        var linkStatus = stat()
        guard fstatat(parentFD, fileName, &linkStatus, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw ScriptSoundLibraryError.sourceUnavailable
        }
        guard (linkStatus.st_mode & S_IFMT) == S_IFREG else {
            throw ScriptSoundLibraryError.sourceIsNotRegular
        }
        guard linkStatus.st_nlink == 1 else {
            throw ScriptSoundLibraryError.sourceHasMultipleLinks
        }
        guard linkStatus.st_size >= 12 else {
            throw ScriptSoundLibraryError.invalidWAV
        }
        guard linkStatus.st_size <= off_t(Self.maximumFileBytes) else {
            throw ScriptSoundLibraryError.fileTooLarge(maximumBytes: Self.maximumFileBytes)
        }

        let fd = Darwin.openat(
            parentFD, fileName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard fd >= 0 else { throw ScriptSoundLibraryError.sourceUnavailable }
        defer { _ = Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0,
              FileIdentity(opened) == FileIdentity(linkStatus) else {
            throw ScriptSoundLibraryError.sourceUnavailable
        }
        guard let bytes = readDescriptor(
            fd, identity: FileIdentity(opened), maximum: Self.maximumFileBytes
        ) else { throw ScriptSoundLibraryError.sourceUnavailable }
        return bytes
    }

    private func validateWAV(_ bytes: Data) throws -> (duration: TimeInterval, channels: Int) {
        guard isStructurallyValidWAV(bytes) else {
            throw ScriptSoundLibraryError.invalidWAV
        }
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: bytes, fileTypeHint: AVFileType.wav.rawValue)
        } catch {
            throw ScriptSoundLibraryError.invalidWAV
        }
        guard player.duration.isFinite, player.duration > 0 else {
            throw ScriptSoundLibraryError.invalidWAV
        }
        guard player.duration <= Self.maximumDurationSeconds else {
            throw ScriptSoundLibraryError.durationTooLong(
                maximumSeconds: Int(Self.maximumDurationSeconds)
            )
        }
        guard (1...2).contains(player.numberOfChannels) else {
            throw ScriptSoundLibraryError.unsupportedChannels
        }
        return (player.duration, player.numberOfChannels)
    }

    /// AVAudioPlayer is intentionally tolerant of truncated RIFF payloads, so decoding alone is
    /// not an import validator. Check the bounded container and every chunk before handing bytes
    /// to Core Audio.
    private func isStructurallyValidWAV(_ bytes: Data) -> Bool {
        guard bytes.count >= 12 else { return false }
        let signature = ascii(bytes, 0..<4)
        guard signature == "RIFF" || signature == "RIFX",
              ascii(bytes, 8..<12) == "WAVE" else { return false }
        let bigEndian = signature == "RIFX"
        guard let declaredSize = wavUInt32(bytes, at: 4, bigEndian: bigEndian),
              Int(declaredSize) == bytes.count - 8 else { return false }

        var offset = 12
        var sawFormat = false
        var sawAudioData = false
        while offset < bytes.count {
            guard offset <= bytes.count - 8,
                  let chunkSizeValue = wavUInt32(
                    bytes, at: offset + 4, bigEndian: bigEndian
                  ) else { return false }
            let chunkSize = Int(chunkSizeValue)
            let payloadStart = offset + 8
            guard chunkSize <= bytes.count - payloadStart else { return false }
            let payloadEnd = payloadStart + chunkSize
            switch ascii(bytes, offset..<(offset + 4)) {
            case "fmt ":
                guard chunkSize >= 16 else { return false }
                sawFormat = true
            case "data":
                guard chunkSize > 0 else { return false }
                sawAudioData = true
            default:
                break
            }
            let padding = chunkSize & 1
            guard padding <= bytes.count - payloadEnd else { return false }
            offset = payloadEnd + padding
        }
        return offset == bytes.count && sawFormat && sawAudioData
    }

    private func atomicInstall(_ bytes: Data, fileName: String) throws {
        guard safeManagedFileName(fileName),
              ensureStorageDirectory(),
              let directoryFD = openStorageDirectory() else {
            throw ScriptSoundLibraryError.storageUnavailable
        }
        defer { _ = Darwin.close(directoryFD) }
        let temporary = ".import-\(UUID().uuidString).tmp"
        let fd = Darwin.openat(
            directoryFD, temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0o600
        )
        guard fd >= 0 else { throw ScriptSoundLibraryError.importFailed }
        var fileOpen = true
        var renamed = false
        defer {
            if fileOpen { _ = Darwin.close(fd) }
            if !renamed { _ = Darwin.unlinkat(directoryFD, temporary, 0) }
        }
        guard writeAll(bytes, to: fd), syncDescriptor(fd) else {
            throw ScriptSoundLibraryError.importFailed
        }
        guard Darwin.close(fd) == 0 else {
            fileOpen = false
            throw ScriptSoundLibraryError.importFailed
        }
        fileOpen = false
        guard renameatx_np(
            directoryFD, temporary, directoryFD, fileName, UInt32(RENAME_EXCL)
        ) == 0 else {
            if errno == EEXIST { throw ScriptSoundLibraryError.nameAlreadyImported(fileName) }
            throw ScriptSoundLibraryError.importFailed
        }
        renamed = true
        guard syncDescriptor(directoryFD) else { throw ScriptSoundLibraryError.importFailed }
    }

    private func readManagedWAV(
        fileName: String, expectedIdentity: FileIdentity? = nil
    ) -> Data? {
        guard safeManagedFileName(fileName), let directoryFD = openStorageDirectory() else {
            return nil
        }
        defer { _ = Darwin.close(directoryFD) }
        var status = stat()
        guard fstatat(directoryFD, fileName, &status, AT_SYMLINK_NOFOLLOW) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_nlink == 1,
              status.st_size >= 12,
              status.st_size <= off_t(Self.maximumFileBytes) else { return nil }
        let identity = FileIdentity(status)
        if let expectedIdentity, identity != expectedIdentity { return nil }
        return readManagedWAV(directoryFD: directoryFD, fileName: fileName, identity: identity)
    }

    private func readManagedWAV(
        directoryFD: Int32, fileName: String, identity: FileIdentity
    ) -> Data? {
        workObserver(.managedRead)
        let fd = Darwin.openat(
            directoryFD, fileName, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard fd >= 0 else { return nil }
        defer { _ = Darwin.close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0, FileIdentity(status) == identity else { return nil }
        return readDescriptor(
            fd, identity: identity, maximum: Self.maximumFileBytes
        )
    }

    private func validatedImportedName(_ raw: String) throws -> String {
        try validatedCatalogName(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func validatedCatalogName(_ raw: String) throws -> String {
        let name = raw.precomposedStringWithCanonicalMapping
        guard !name.isEmpty,
              name != ".", name != "..",
              name.utf8.count <= Self.maximumNameBytes,
              !name.hasPrefix("."),
              !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              name.unicodeScalars.allSatisfy({ scalar in
                  !CharacterSet.controlCharacters.contains(scalar)
                      && !CharacterSet.newlines.contains(scalar)
                      && scalar.properties.generalCategory != .format
              }) else { throw ScriptSoundLibraryError.invalidName }
        return name
    }

    private func canonicalKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive], locale: Self.posixLocale
        )
    }

    private func entryLess(_ lhs: ScriptSoundEntry, _ rhs: ScriptSoundEntry) -> Bool {
        let lk = canonicalKey(lhs.name), rk = canonicalKey(rhs.name)
        if lk != rk { return utf8Less(lk, rk) }
        if lhs.source != rhs.source { return sourceRank(lhs.source) < sourceRank(rhs.source) }
        return utf8Less(lhs.name, rhs.name)
    }

    private func sourceRank(_ source: ScriptSoundEntry.Source) -> Int {
        switch source {
        case .system: return 0
        case .toneLibrary: return 1
        case .imported: return 2
        }
    }

    private func prunePlayers() {
        let finished = activePlayers.compactMap { $0.value.isPlaying ? nil : $0.key }
        for identity in finished { releasePlayer(identity) }
    }

    private func releasePlayer(_ identity: ObjectIdentifier) {
        activePlayers.removeValue(forKey: identity)
        if let admission = activePlayerAdmissions.removeValue(forKey: identity) {
            playbackAdmissions.remove(admission)
        }
    }

    private func releasePlaybackAdmissionAfterCurrentTurn(_ admission: UUID) {
        Task { @MainActor [weak self] in
            self?.playbackAdmissions.remove(admission)
        }
    }

}

extension ScriptSoundLibrary: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully flag: Bool
    ) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            self?.releasePlayer(identity)
        }
    }
}

extension Notification.Name {
    static let elysiumScriptSoundCatalogDidChange = Notification.Name(
        "ElysiumScriptSoundCatalogDidChange"
    )
}

private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let links: nlink_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ value: stat) {
        device = value.st_dev
        inode = value.st_ino
        mode = value.st_mode
        links = value.st_nlink
        size = value.st_size
        modifiedSeconds = value.st_mtimespec.tv_sec
        modifiedNanoseconds = value.st_mtimespec.tv_nsec
        changedSeconds = value.st_ctimespec.tv_sec
        changedNanoseconds = value.st_ctimespec.tv_nsec
    }
}

private struct ImportedSoundMetadata {
    let identity: FileIdentity
    let duration: TimeInterval
}

private extension String {
    var pathExtensionLowercased: String {
        (self as NSString).pathExtension.lowercased()
    }
}

private func utf8Less(_ lhs: String, _ rhs: String) -> Bool {
    Array(lhs.utf8).lexicographicallyPrecedes(Array(rhs.utf8))
}

private func safeManagedFileName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".."
        && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
        && name.utf8.count <= Int(NAME_MAX)
}

private func directoryNames(
    _ directoryFD: Int32, maximumEntries: Int
) -> [String]? {
    let fresh = Darwin.openat(
        directoryFD, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    )
    guard fresh >= 0, let directory = fdopendir(fresh) else {
        if fresh >= 0 { _ = Darwin.close(fresh) }
        return nil
    }
    defer { closedir(directory) }
    var names: [String] = []
    errno = 0
    while let entry = readdir(directory) {
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer -> String? in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                String(validatingUTF8: $0)
            }
        }
        guard let name else { return nil }
        if name == "." || name == ".." { continue }
        guard safeManagedFileName(name) else { return nil }
        guard names.count < maximumEntries else { return nil }
        names.append(name)
    }
    guard errno == 0 else { return nil }
    return names.sorted(by: utf8Less)
}

private func readDescriptor(
    _ fd: Int32, identity: FileIdentity, maximum: Int
) -> Data? {
    guard identity.size >= 0, identity.size <= off_t(maximum) else { return nil }
    var result = Data()
    result.reserveCapacity(Int(identity.size))
    var offset: off_t = 0
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while offset < identity.size {
        let requested = min(buffer.count, Int(identity.size - offset))
        let count = buffer.withUnsafeMutableBytes {
            Darwin.pread(fd, $0.baseAddress, requested, offset)
        }
        if count > 0 {
            result.append(buffer, count: count)
            offset += off_t(count)
        } else if count < 0, errno == EINTR {
            continue
        } else {
            return nil
        }
    }
    var after = stat()
    guard fstat(fd, &after) == 0,
          FileIdentity(after) == identity,
          result.count == Int(identity.size) else { return nil }
    return result
}

private func writeAll(_ data: Data, to fd: Int32) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard let base = raw.baseAddress else { return data.isEmpty }
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
            if count > 0 { offset += count }
            else if count < 0, errno == EINTR { continue }
            else { return false }
        }
        return true
    }
}

private func syncDescriptor(_ fd: Int32) -> Bool {
    while Darwin.fsync(fd) != 0 {
        if errno != EINTR { return false }
    }
    return true
}

private func ascii(_ data: Data, _ range: Range<Int>) -> String {
    guard range.lowerBound >= 0, range.upperBound <= data.count else { return "" }
    return String(bytes: data[range], encoding: .ascii) ?? ""
}

private func wavUInt32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32? {
    guard offset >= 0, offset <= data.count - MemoryLayout<UInt32>.size else { return nil }
    let b0 = UInt32(data[offset])
    let b1 = UInt32(data[offset + 1])
    let b2 = UInt32(data[offset + 2])
    let b3 = UInt32(data[offset + 3])
    if bigEndian { return b0 << 24 | b1 << 16 | b2 << 8 | b3 }
    return b0 | b1 << 8 | b2 << 16 | b3 << 24
}

// MARK: - Options > Audio management screen

private enum SoundLibraryFocus: Hashable {
    case row(String)
    case importSound
    case preview
    case delete
    case done
}

final class SoundLibraryScreen: Screen {
    private let libraryOverride: ScriptSoundLibrary?
    private var focused: SoundLibraryFocus = .importSound
    private var selectedID: String?
    private var scrollOffset = 0
    private var visibleEntries: [ScriptSoundEntry] = []
    private var controls: [SoundLibraryFocus: Button] = [:]
    private var status = "Import WAV files to use their filename in sound(…)."
    private var pendingAnnouncement: String?

    init(library: ScriptSoundLibrary? = nil) {
        libraryOverride = library
        super.init()
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        rebuild(ui, game)
    }

    override func relayoutScreen(_ ui: UIManager, _ game: GameCore) {
        rebuild(ui, game)
    }

    private func withLibrary<T>(
        _ body: @MainActor (ScriptSoundLibrary) throws -> T
    ) rethrows -> T? {
        try elysiumMainActorSync {
            guard let library = libraryOverride ?? gAppDelegate?.scriptSoundLibrary else {
                return nil
            }
            return try body(library)
        }
    }

    private func rebuild(_ ui: UIManager, _ game: GameCore) {
        buttons = []
        controls = [:]
        let imported = withLibrary { $0.importedEntries } ?? []
        if selectedID == nil || !imported.contains(where: { $0.id == selectedID }) {
            selectedID = imported.first?.id
        }
        let rowCount = max(1, min(8, Int((ui.height - 112) / 21)))
        scrollOffset = min(max(0, scrollOffset), max(0, imported.count - rowCount))
        if let selectedID,
           let selectedIndex = imported.firstIndex(where: { $0.id == selectedID }) {
            if selectedIndex < scrollOffset { scrollOffset = selectedIndex }
            if selectedIndex >= scrollOffset + rowCount {
                scrollOffset = max(0, selectedIndex - rowCount + 1)
            }
        }
        visibleEntries = Array(imported.dropFirst(scrollOffset).prefix(rowCount))

        let cx = (ui.width / 2).rounded(.down)
        var y = 58.0
        for entry in visibleEntries {
            let selected = entry.id == selectedID
            let size = max(1, entry.byteCount / 1024)
            let button = Button(
                cx - 170, y, 340, 18,
                "\(selected ? "▶ " : "")\(entry.name)  ·  \(size) KB", {}
            )
            let focus = SoundLibraryFocus.row(entry.id)
            button.onClick = { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                self.selectedID = entry.id
                self.focused = focus
                self.rebuild(ui, game)
                ui.renewTextAccessibilityPresentation(screen: self, game: game)
            }
            buttons.append(button)
            controls[focus] = button
            y += 21
        }

        let controlY = ui.height - 53
        let specs: [(SoundLibraryFocus, String, Double, () -> Void)] = [
            (.importSound, "Import WAV…", cx - 170, { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                self.beginImport(ui, game)
            }),
            (.preview, "Preview", cx - 58, { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                self.previewSelected(ui, game)
            }),
            (.delete, "Delete", cx + 26, { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                self.confirmDelete(ui, game)
            }),
        ]
        for (focus, label, x, action) in specs {
            let width = focus == .importSound ? 108.0 : 80.0
            let button = Button(x, controlY, width, 18, label, action)
            if focus == .preview || focus == .delete { button.enabled = selectedID != nil }
            buttons.append(button)
            controls[focus] = button
        }
        let done = Button(cx - 100, ui.height - 29, 200, 18, "Done", {
            [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        })
        buttons.append(done)
        controls[.done] = done
        if controls[focused] == nil || controls[focused]?.enabled != true {
            focused = .importSound
        }
    }

    private func publish(
        _ message: String, ui: UIManager, game: GameCore, announce: Bool = true
    ) {
        status = message
        if announce { pendingAnnouncement = message }
        rebuild(ui, game)
        ui.renewTextAccessibilityPresentation(screen: self, game: game)
    }

    private func beginImport(_ ui: UIManager, _ game: GameCore) {
        let panel = NSOpenPanel()
        panel.title = "Import WAV Sound"
        panel.prompt = "Import"
        panel.message = "Elysium copies one validated WAV into its managed Sounds folder."
        panel.allowedContentTypes = [.wav]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        status = "Choose a WAV file to import."
        pendingAnnouncement = status
        ui.renewTextAccessibilityPresentation(screen: self, game: game)
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak ui, weak game] response in
            guard let self, let ui, let game, ui.current() === self else { return }
            guard response == .OK, let url = panel.url else {
                self.publish("Import cancelled.", ui: ui, game: game)
                return
            }
            do {
                guard let entry = try self.withLibrary({ try $0.importSound(from: url) }) else {
                    throw ScriptSoundLibraryError.storageUnavailable
                }
                self.selectedID = entry.id
                self.focused = .row(entry.id)
                self.publish("Imported “\(entry.name)”.", ui: ui, game: game)
            } catch {
                self.publish(
                    (error as? LocalizedError)?.errorDescription
                        ?? "The WAV could not be imported.",
                    ui: ui, game: game
                )
            }
        }
        if let window = gAppDelegate?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func previewSelected(_ ui: UIManager, _ game: GameCore) {
        guard let selectedID,
              let entry = (withLibrary { library in
                  library.importedEntries.first { $0.id == selectedID }
              } ?? nil) else {
            publish("Select an imported sound first.", ui: ui, game: game)
            return
        }
        let played = elysiumMainActorSync { [libraryOverride] () -> Bool in
            guard let library = libraryOverride ?? gAppDelegate?.scriptSoundLibrary else {
                return false
            }
            guard let app = gAppDelegate else {
                return library.play(name: entry.name, volume: 1, pan: 0)
            }
            guard let mix = app.audio.scriptSampleMix(
                app.audio.listenerX, app.audio.listenerY, app.audio.listenerZ, 1
            ) else { return false }
            return library.play(name: entry.name, volume: mix.volume, pan: mix.pan)
        }
        publish(
            played ? "Playing “\(entry.name)”." : "Could not play “\(entry.name)”.",
            ui: ui, game: game
        )
    }

    private func confirmDelete(_ ui: UIManager, _ game: GameCore) {
        guard let selectedID,
              let entry = (withLibrary { library in
                  library.importedEntries.first { $0.id == selectedID }
              } ?? nil) else {
            publish("Select an imported sound first.", ui: ui, game: game)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete “\(entry.name)”?"
        alert.informativeText = "This removes the managed WAV from Elysium. Scripts using its name will no longer play it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak ui, weak game] response in
            guard let self, let ui, let game, ui.current() === self else { return }
            guard response == .alertFirstButtonReturn else {
                self.publish("Delete cancelled.", ui: ui, game: game)
                return
            }
            do {
                guard try self.withLibrary({
                    try $0.deleteImportedSound(id: entry.id)
                    return true
                }) == true else { throw ScriptSoundLibraryError.storageUnavailable }
                self.selectedID = nil
                self.focused = .importSound
                self.publish("Deleted “\(entry.name)”.", ui: ui, game: game)
            } catch {
                self.publish(
                    (error as? LocalizedError)?.errorDescription
                        ?? "The imported sound could not be deleted.",
                    ui: ui, game: game
                )
            }
        }
        if let window = gAppDelegate?.window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    private func focusGraph() -> [SoundLibraryFocus] {
        visibleEntries.map { .row($0.id) }
            + [.importSound, .preview, .delete, .done].filter {
                controls[$0]?.enabled == true
            }
    }

    private func scroll(
        by delta: Int, ui: UIManager, game: GameCore
    ) {
        let imported = withLibrary { $0.importedEntries } ?? []
        let rowCount = max(1, min(8, Int((ui.height - 112) / 21)))
        let nextOffset = min(
            max(0, scrollOffset + delta), max(0, imported.count - rowCount)
        )
        guard nextOffset != scrollOffset else { return }
        scrollOffset = nextOffset
        if imported.indices.contains(nextOffset) {
            selectedID = imported[nextOffset].id
            focused = .row(imported[nextOffset].id)
        }
        rebuild(ui, game)
        ui.renewTextAccessibilityPresentation(screen: self, game: game)
    }

    override func onKeyEvent(
        _ ui: UIManager, _ game: GameCore, _ event: ElysiumKeyEvent
    ) -> Bool {
        if event.isRepeat { return true }
        let key = event.terminal.rawValue
        if key == "Escape" { ui.closeTop(game); return true }
        let graph = focusGraph()
        guard !graph.isEmpty else { return true }
        if key == "Tab" || key == "ArrowDown" || key == "ArrowUp" {
            let backwards = key == "ArrowUp" || (key == "Tab" && event.modifiers.contains(.shift))
            let index = graph.firstIndex(of: focused) ?? 0
            focused = graph[(index + (backwards ? graph.count - 1 : 1)) % graph.count]
            if case .row(let id) = focused { selectedID = id }
            rebuild(ui, game)
            ui.renewTextAccessibilityPresentation(screen: self, game: game)
            return true
        }
        if ["Enter", "NumpadEnter", "Space"].contains(key),
           let button = controls[focused], button.enabled {
            button.onClick()
            return true
        }
        if key == "PageDown" || key == "PageUp" {
            scroll(
                by: key == "PageDown" ? max(1, visibleEntries.count) : -max(1, visibleEntries.count),
                ui: ui, game: game
            )
            return true
        }
        return true
    }

    override func onWheel(
        _ ui: UIManager, _ game: GameCore, _ dy: Double
    ) -> Bool {
        scroll(by: dy > 0 ? -1 : 1, ui: ui, game: game)
        return true
    }

    override func onMouseDown(
        _ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int
    ) -> Bool {
        if btn == 0 {
            for (id, button) in controls where button.contains(mx, my) {
                focused = id
                if case .row(let entryID) = id { selectedID = entryID }
                break
            }
        }
        return super.onMouseDown(ui, game, mx, my, btn)
    }

    override func textAccessibilityDescriptors(
        _ ui: UIManager, _ game: GameCore
    ) -> [TextEntryAccessibilityDescriptor] {
        guard ui.current() === self else { return [] }
        let libraryInfo = withLibrary { library in
            (library.importedEntries.count, library.systemEntries.count)
        } ?? (0, 0)
        var result = [
            TextEntryAccessibilityDescriptor(
                id: "sound-library.summary", role: .staticText,
                label: "Script sound library",
                value: "\(libraryInfo.0) imported; \(libraryInfo.1) macOS sounds available",
                help: "Imported WAV files and discovered macOS sounds are available to sound by name.",
                frame: (2, 28, max(1, ui.width - 4), 12), enabled: true,
                focused: false, insertionUTF16Offset: nil, focusable: false,
                actionable: false
            ),
            TextEntryAccessibilityDescriptor(
                id: "sound-library.status", role: .staticText,
                label: "Sound library status", value: status,
                help: "Current sound import or playback status.",
                frame: (2, 42, max(1, ui.width - 4), 12), enabled: true,
                focused: false, insertionUTF16Offset: nil, focusable: false,
                actionable: false
            ),
        ]
        for entry in visibleEntries {
            let focus = SoundLibraryFocus.row(entry.id)
            guard let button = controls[focus] else { continue }
            result.append(TextEntryAccessibilityDescriptor(
                id: "sound-library.row.\(entry.id)", role: .listItem,
                label: entry.name,
                value: entry.id == selectedID ? "Selected" : "",
                help: "Imported WAV, \(max(1, entry.byteCount / 1024)) kilobytes.",
                frame: (button.x, button.y, button.w, button.h), enabled: true,
                focused: focused == focus, insertionUTF16Offset: nil,
                focusable: true, selected: entry.id == selectedID, actionable: true
            ))
        }
        for (focus, stableID, help) in [
            (SoundLibraryFocus.importSound, "sound-library.import", "Choose and import one WAV file."),
            (.preview, "sound-library.preview", "Play the selected imported sound."),
            (.delete, "sound-library.delete", "Delete the selected managed WAV after confirmation."),
            (.done, "sound-library.done", "Return to Audio options."),
        ] {
            guard let button = controls[focus] else { continue }
            result.append(TextEntryAccessibilityDescriptor(
                id: stableID, role: .button, label: button.label, value: "", help: help,
                frame: (button.x, button.y, button.w, button.h), enabled: button.enabled,
                focused: focused == focus, insertionUTF16Offset: nil,
                focusable: button.enabled, actionable: button.enabled
            ))
        }
        return result
    }

    override func focusTextAccessibilityElement(
        _ id: String, _ ui: UIManager, _ game: GameCore
    ) -> Bool {
        let target: SoundLibraryFocus?
        switch id {
        case "sound-library.import": target = .importSound
        case "sound-library.preview": target = .preview
        case "sound-library.delete": target = .delete
        case "sound-library.done": target = .done
        default:
            if id.hasPrefix("sound-library.row.") {
                let entryID = String(id.dropFirst("sound-library.row.".count))
                target = .row(entryID)
            } else {
                target = nil
            }
        }
        guard let target, controls[target]?.enabled == true else { return false }
        focused = target
        if case .row(let entryID) = target { selectedID = entryID }
        return true
    }

    override func performTextAccessibilityAction(
        _ id: String, _ ui: UIManager, _ game: GameCore
    ) -> Bool {
        guard focusTextAccessibilityElement(id, ui, game),
              let button = controls[focused], button.enabled else { return false }
        button.onClick()
        return true
    }

    override func consumeTextAccessibilityStatusAnnouncement() -> String? {
        defer { pendingAnnouncement = nil }
        return pendingAnnouncement
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        game.hasWorld() ? ui.drawDarkBg(0.7) : ui.drawDirtBg()
        ui.cv.drawTextCentered("Script Sounds", ui.width / 2, 12, 1.25)
        let counts = withLibrary { ($0.importedEntries.count, $0.systemEntries.count) } ?? (0, 0)
        ui.cv.drawTextCentered(
            "\(counts.0) imported WAV\(counts.0 == 1 ? "" : "s") · \(counts.1) macOS sounds available",
            ui.width / 2, 31, 0.8, "#dddddd"
        )
        ui.cv.drawTextCentered(status, ui.width / 2, 43, 0.75,
                               status.hasPrefix("Could not") ? "#ffaaaa" : "#dddddd")
        if visibleEntries.isEmpty {
            ui.cv.drawTextCentered("No imported WAV files", ui.width / 2, 78, 1, "#a0a0a0")
        }
        ui.drawButtons(self)
        if let button = controls[focused] {
            let light = game.settings.highContrast ? "#ffff00" : "#ffffff"
            ui.cv.setStroke("#000000")
            ui.cv.strokeRect(button.x + 1, button.y + 1, button.w - 2, button.h - 2)
            ui.cv.setStroke(light)
            ui.cv.strokeRect(button.x, button.y, button.w, button.h)
        }
    }
}
