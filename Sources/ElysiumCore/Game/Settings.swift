// Settings — JSON files under ~/Library/Application Support/Elysium/.
// Field names, defaults, and render-distance clamps are frozen; keybinds
// keep internal key-code strings so the app's NSEvent translation layer
// and saved configs stay engine-compatible.

import Foundation

public struct Settings: Codable {
    // video
    public var renderDistance = 8
    public var fov = 70
    public var fancyGraphics = true
    public var smoothLighting = true
    public var bloom = true
    public var shadows = true
    public var clouds = true
    public var particles = 2        // 0 minimal 1 decreased 2 all
    public var gamma = 0.5          // 0..1
    public var viewBobbing = true
    public var guiScale = 0         // 0 auto
    public var maxFps = 120         // 250 = unlimited/vsync-off; opt-in, not the default
    public var entityDistance = 64.0
    // audio
    public var volumes: [String: Double] = [
        "master": 0.8, "music": 0.5, "blocks": 1, "hostile": 1, "friendly": 1,
        "players": 1, "ambient": 1, "records": 1, "ui": 1,
    ]
    // controls
    public var sensitivity = 0.5    // 0..1
    public var invertY = false
    // accessibility
    public var subtitles = false
    public var autoJump = false
    public var reduceMotion = false
    public var reducedFlashes = false
    public var highContrast = false
    public var darknessPulse = 1.0
    /// per-block quads instead of greedy-merged spans (GPU driver workaround)
    public var simpleMesh = false
    /// enabled resource pack file names, index 0 = highest priority.
    /// optional so settings.json files written before this field still decode
    public var resourcePacks: [String]? = nil
    /// nil = off, "ultra" = built-in ultra preset, anything else = shader pack file name
    public var shader: String? = nil
    /// Local Ollama model name used by the in-game /ai command. Empty = unset.
    public var aiOllamaModel = ""
    /// Version of the local RPG tutorial that the player finished or skipped.
    /// Nil means the tutorial has not been acknowledged.
    public var rpgTutorialVersion: Int? = nil

    public init() {}
}

/// Compatibility spelling retained for older callers. There is exactly one canonical default
/// source: the stable 25-entry definition table in `InputChords.swift`.
public var DEFAULT_KEYBINDS: [String: String] { rpgDefaultChordBindings() }

public func defaultSettings() -> Settings { Settings() }

private func clampInt(_ v: Int, _ lo: Int, _ hi: Int) -> Int {
    min(hi, max(lo, v))
}

private func clampUnit(_ v: Double, fallback: Double) -> Double {
    v.isFinite ? min(1, max(0, v)) : fallback
}

public func sanitizedOllamaModelName(_ raw: String) -> String {
    let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:")
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return String(trimmed.prefix(128).filter { allowed.contains($0) })
}

public func isAllowedLocalOllamaModelName(_ raw: String) -> Bool {
    let model = sanitizedOllamaModelName(raw).lowercased()
    return !model.isEmpty && !model.hasSuffix(":cloud")
}

func sanitizedSettings(_ input: Settings) -> Settings {
    var s = input
    s.renderDistance = clampInt(s.renderDistance, 4, 16)
    s.fov = clampInt(s.fov, 60, 110)
    s.particles = clampInt(s.particles, 0, 2)
    s.gamma = clampUnit(s.gamma, fallback: Settings().gamma)
    s.guiScale = clampInt(s.guiScale, 0, 4)
    s.maxFps = clampInt(s.maxFps, 30, 250)
    s.entityDistance = s.entityDistance.isFinite ? min(256, max(16, s.entityDistance)) : Settings().entityDistance
    s.sensitivity = clampUnit(s.sensitivity, fallback: Settings().sensitivity)
    s.darknessPulse = clampUnit(s.darknessPulse, fallback: Settings().darknessPulse)

    let defaults = Settings().volumes
    var volumes: [String: Double] = [:]
    for (k, def) in defaults {
        volumes[k] = clampUnit(s.volumes[k] ?? def, fallback: def)
    }
    s.volumes = volumes

    if let packs = s.resourcePacks {
        s.resourcePacks = Array(packs.filter {
            !$0.isEmpty && $0.count <= 255 && !$0.contains("/") && !$0.contains("\\")
        }.prefix(64))
    }
    s.aiOllamaModel = sanitizedOllamaModelName(s.aiOllamaModel)
    let tutorialVersion = s.rpgTutorialVersion ?? 0
    s.rpgTutorialVersion = (0...RPG_TUTORIAL_VERSION).contains(tutorialVersion)
        ? tutorialVersion : 0
    return s
}

func sanitizedKeybinds(_ input: [String: String]) -> [String: String] {
    rpgSanitizedChordBindings(input)
}

/// ~/Library/Application Support/Elysium — created on first touch
public func vcSupportDir() -> URL {
    _ = LegacyBrandMigration.runOnce // fold any former "Pebble" data across before first use
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Elysium", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
