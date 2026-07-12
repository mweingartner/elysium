// Menus — title screen, world select/create, pause,
// settings (video/audio/controls/accessibility), advancements tree, credits.

import AppKit
import Foundation
import QuartzCore
import PebbleCore

// =============================================================================
final class TitleScreen: Screen {
    var splash = ""
    static let SPLASHES = [
        "Punch a tree!", "Watch out for creepers!", "Don't dig straight down!",
        "Diamonds run deep!", "Now with wardens!", "Sculk is listening!",
        "The dragon is waiting!", "Cherry blossoms!", "Archaeology!",
        "Goats will punt you!", "Trade with villagers!", "Ride a strider!",
        "X marks the buried treasure!", "Hero of the Village!", "Open to LAN!",
        "Do not stare at endermen!", "Beds explode in the Nether!", "Llamas spit back!",
        "Lava is not a swimming pool!", "Blame the goat!", "Bring a bucket!",
        "Mostly bug free!", "Creepers hate him!", "The chickens are watching!",
    ]
    override init() {
        super.init()
        closeOnEsc = false
    }
    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        if splash.isEmpty { splash = TitleScreen.SPLASHES[Int.random(in: 0..<TitleScreen.SPLASHES.count)] }
        let cx = (ui.width / 2).rounded(.down)
        // vanilla layout: stacked main buttons at h/4+48, then a half-width row
        var y = (ui.height / 4).rounded(.down) + 48
        buttons.append(Button(cx - 100, y, 200, 20, "Singleplayer", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(WorldSelectScreen(), game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Multiplayer", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(LANLobbyScreen(), game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Credits", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(CreditsScreen(), game)
        }))
        y += 36
        buttons.append(Button(cx - 100, y, 98, 20, "Options...", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(SettingsScreen(), game)
        }))
        buttons.append(Button(cx + 2, y, 98, 20, "Quit Game", {
            NSApp.terminate(nil)
        }))
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        let cv = ui.cv
        let now = CACurrentMediaTime() * 1000
        if !ui.titlePhoto {
            // no photo bundled: animated gradient sky + floating cubes fallback
            let t = CACurrentMediaTime() * 1000 / 30000
            let top = "hsl(\(215 + Foundation.sin(t) * 12), 55%, \(28 + Foundation.sin(t * 1.7) * 6)%)"
            let bottom = "hsl(\(230 + Foundation.cos(t) * 10), 45%, 12%)"
            cv.fillRect(0, 0, ui.width, ui.height, top: top, bottom: bottom)
            for i in 0..<24 {
                let fx = (Double(i) * 137.5 + now / Double(90 + i * 7)).truncatingRemainder(dividingBy: ui.width + 40) - 20
                let fy = 20 + Double((i * 53) % max(1, Int(ui.height) - 60))
                let size = Double(3 + (i % 4) * 2)
                cv.setFill("hsla(\(110 + i * 17 % 120), 35%, \(30 + i % 30)%, 0.25)")
                cv.fillRect(fx, fy, size, size)
            }
        }
        // wordmark: textured logo when bundled, block-shadowed text otherwise
        let logoY = (ui.height / 4).rounded(.down) - 26
        if !ui.titleLogo {
            cv.drawTextCentered("PEBBLE", ui.width / 2 + 2, logoY + 2, 4, "#1c1c1c", shadow: false)
            cv.drawTextCentered("PEBBLE", ui.width / 2, logoY, 4, "#e8e8e8", shadow: false)
        }
        // splash anchored to the logo's right edge
        cv.save()
        cv.translate(ui.width / 2 + 92, logoY + 26)
        cv.rotate(-0.25)
        let pulse = 1 + Foundation.sin(now / 250) * 0.06
        cv.scale(pulse, pulse)
        cv.drawTextCentered(splash, 0, 0, 1, "#ffff55")
        cv.restore()
        cv.drawText("Pebble \(PEBBLE_VERSION)", 2, ui.height - 10, 1, "#c8c8c8")
        cv.drawText("Textures: Faithful 32x (faithfulpack.net)", 2, ui.height - 20, 1, "#909090")
        let credit = "LAN multiplayer"
        cv.drawText(credit, ui.width - Double(textWidth(credit)) - 2, ui.height - 10, 1, "#c8c8c8")
        ui.drawButtons(self)
    }
}

// =============================================================================
final class WorldSelectScreen: Screen {
    private let lanHostRequest: LANHostLaunchRequest?
    var worlds: [WorldRecord] = []
    var selected = -1
    var loaded = false
    var playBtn: Button!
    var deleteBtn: Button!

    init(lanHostRequest: LANHostLaunchRequest? = nil) {
        self.lanHostRequest = lanHostRequest
        super.init()
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        worlds = game.listWorlds().sorted { $0.lastPlayed > $1.lastPlayed }
        loaded = true
        let cx = (ui.width / 2).rounded(.down)
        let by = ui.height - 50
        playBtn = Button(cx - 154, by, 100, 20, lanHostRequest == nil ? "Play Selected" : "Host Selected", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            if self.selected >= 0 {
                self.openWorld(self.worlds[self.selected], ui: ui, game: game)
            }
        })
        deleteBtn = Button(cx - 50, by, 100, 20, "Delete", { [weak self, weak game] in
            guard let self, let game else { return }
            if self.selected >= 0 {
                game.deleteWorld(self.worlds[self.selected].id)
                self.worlds = game.listWorlds().sorted { $0.lastPlayed > $1.lastPlayed }
                self.selected = -1
            }
        })
        buttons.append(playBtn)
        buttons.append(deleteBtn)
        buttons.append(Button(cx + 54, by, 100, 20, "Create New", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(WorldCreateScreen(lanHostRequest: self.lanHostRequest), game)
        }))
        buttons.append(Button(cx - 100, by + 24, 200, 20, "Back", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        }))
    }
    private var scroll = 0.0
    private var listTop: Double { 30 }
    private func listBottom(_ ui: UIManager) -> Double { ui.height - 78 }
    private func maxScroll(_ ui: UIManager) -> Double {
        max(0, Double(worlds.count) * 30 - (listBottom(ui) - listTop))
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDirtBg()
        ui.cv.drawTextCentered(lanHostRequest == nil ? "Select World" : "Select World to Host", ui.width / 2, 10, 1)
        playBtn.enabled = selected >= 0
        deleteBtn.enabled = selected >= 0
        let listX = (ui.width / 2).rounded(.down) - 130
        if !loaded {
            ui.cv.drawTextCentered("Loading...", ui.width / 2, 60, 1, "#a0a0a0")
        } else if worlds.isEmpty {
            ui.cv.drawTextCentered("No worlds yet — create one!", ui.width / 2, 60, 1, "#a0a0a0")
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        scroll = min(max(0, scroll), maxScroll(ui))
        let top = listTop, bottom = listBottom(ui)
        for (i, w) in worlds.enumerated() {
            let y = top + Double(i) * 30 - scroll
            if y + 28 <= top || y >= bottom { continue }   // clipped out of the viewport
            let hover = ui.mouseX >= listX && ui.mouseX < listX + 260 && ui.mouseY >= y && ui.mouseY < y + 28
            ui.cv.setFill(i == selected ? "rgba(255,255,255,0.25)" : hover ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.3)")
            ui.cv.fillRect(listX, y, 260, 28)
            ui.cv.drawText(w.name, listX + 4, y + 4, 1)
            let when = fmt.string(from: Date(timeIntervalSince1970: w.lastPlayed / 1000))
            ui.cv.drawText("§7\(when) • \(w.gameMode == GameMode.creative ? "Creative" : "Survival") • seed \(w.seed)", listX + 4, y + 15, 1)
        }
        // scrollbar
        if maxScroll(ui) > 0 {
            let trackH = bottom - top
            let thumbH = max(12, trackH * trackH / (Double(worlds.count) * 30))
            let thumbY = top + (trackH - thumbH) * (scroll / maxScroll(ui))
            ui.cv.setFill("rgba(0,0,0,0.4)")
            ui.cv.fillRect(listX + 264, top, 4, trackH)
            ui.cv.setFill("rgba(255,255,255,0.5)")
            ui.cv.fillRect(listX + 264, thumbY, 4, thumbH)
        }
        ui.drawButtons(self)
    }
    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        scroll = min(max(0, scroll + dy * 12), maxScroll(ui))
        return true
    }
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        // buttons take priority — invisible list rows must never eat their clicks
        if super.onMouseDown(ui, game, mx, my, btn) { return true }
        let listX = (ui.width / 2).rounded(.down) - 130
        let top = listTop, bottom = listBottom(ui)
        guard my >= top, my < bottom, mx >= listX, mx < listX + 260 else { return false }
        for i in 0..<worlds.count {
            let y = top + Double(i) * 30 - scroll
            if y + 28 <= top || y >= bottom { continue }
            if my >= y && my < y + 28 {
                if selected == i {
                    openWorld(worlds[i], ui: ui, game: game)
                }
                selected = i
                return true
            }
        }
        return false
    }

    private func openWorld(_ record: WorldRecord, ui: UIManager, game: GameCore) {
        game.loadWorld(record.id)
        startPendingLANHost(game)
        ui.open(LoadingScreen(), game)
    }

    private func startPendingLANHost(_ game: GameCore) {
        guard let lanHostRequest else { return }
        do {
            try LANMultiplayerManager.shared.startHost(
                game: game,
                requestedJoinCode: lanHostRequest.joinCode,
                requestedPort: lanHostRequest.port
            )
            for line in LANMultiplayerManager.shared.statusSummary() {
                pushChat("§7" + line)
            }
        } catch let error as LANTransportError {
            pushChat("§c" + error.description)
        } catch {
            pushChat("§cLAN host failed: \(error)")
        }
    }
}

// =============================================================================
final class WorldCreateScreen: Screen {
    private struct Layout {
        let uiHeight: Double
        let compact: Bool
        let buttonGap: Double
        let nameY: Double
        let seedY: Double
        let modeY: Double
        let difficultyY: Double
        let worldTypeY: Double
        let biomeY: Double

        init(uiHeight: Double) {
            self.uiHeight = uiHeight
            compact = uiHeight < 260
            buttonGap = compact ? 22.0 : 24.0
            nameY = compact ? 34 : 40
            seedY = compact ? 64 : 76
            modeY = compact ? 90 : 102
            difficultyY = modeY + buttonGap
            worldTypeY = difficultyY + buttonGap
            biomeY = worldTypeY + buttonGap
        }

        func dungeonY(showsBiome: Bool) -> Double {
            showsBiome ? biomeY + buttonGap : biomeY
        }

        func actionY(showsBiome: Bool) -> Double {
            let dungeonY = dungeonY(showsBiome: showsBiome)
            let preferredActionY = dungeonY + (compact ? 28 : 32)
            return max(dungeonY + 24, min(preferredActionY, uiHeight - 34))
        }

        func statusY(showsBiome: Bool) -> Double {
            min(actionY(showsBiome: showsBiome) + 30, uiHeight - 10)
        }
    }

    private let lanHostRequest: LANHostLaunchRequest?
    let nameField = TextField(0, 0, 200, 16, "New World",
                              id: "create.worldName", accessibilityLabel: "World Name")
    let seedField = TextField(0, 0, 200, 16, "Leave blank for random",
                              id: "create.seed", accessibilityLabel: "Seed")
    var mode = GameMode.survival
    var difficulty = 2
    var worldPreset = WorldPreset.normal
    var singleBiome = Biome.plains
    var dungeonDensity = DungeonDensity.normal
    var creating = false
    private var worldTypeBtn: Button!
    private var biomeBtn: Button!
    private var dungeonBtn: Button!
    private weak var createBtn: Button?
    private weak var cancelBtn: Button?
    private var lastUIHeight = 240.0

    init(lanHostRequest: LANHostLaunchRequest? = nil) {
        self.lanHostRequest = lanHostRequest
        super.init()
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        let cx = (ui.width / 2).rounded(.down)
        lastUIHeight = ui.height
        let layout = Layout(uiHeight: ui.height)
        nameField.x = cx - 100
        nameField.y = layout.nameY
        seedField.x = cx - 100
        seedField.y = layout.seedY
        fields.append(nameField)
        fields.append(seedField)
        let modeBtn = Button(cx - 100, layout.modeY, 200, 20, "Game Mode: Survival", {})
        modeBtn.onClick = { [weak self, weak modeBtn] in
            guard let self, let modeBtn else { return }
            self.mode = self.mode == GameMode.survival ? GameMode.creative : GameMode.survival
            modeBtn.label = "Game Mode: \(self.mode == GameMode.creative ? "Creative" : "Survival")"
        }
        let diffBtn = Button(cx - 100, layout.difficultyY, 200, 20, "Difficulty: Normal", {})
        diffBtn.onClick = { [weak self, weak diffBtn] in
            guard let self, let diffBtn else { return }
            self.difficulty = (self.difficulty + 1) % 4
            diffBtn.label = "Difficulty: \(DIFFICULTY_NAMES[self.difficulty])"
        }
        buttons.append(modeBtn)
        buttons.append(diffBtn)
        worldTypeBtn = Button(cx - 100, layout.worldTypeY, 200, 20, "", {})
        worldTypeBtn.onClick = { [weak self, weak ui] in
            guard let self, let ui else { return }
            let cycle = ui.optionDown ? WorldPreset.extendedCycle : WorldPreset.normalCycle
            let current = cycle.firstIndex(of: self.worldPreset) ?? -1
            self.worldPreset = cycle[(current + 1) % cycle.count]
            self.updateWorldTypeLabels()
        }
        biomeBtn = Button(cx - 100, layout.biomeY, 200, 20, "", {})
        biomeBtn.onClick = { [weak self] in
            guard let self else { return }
            let cases = Biome.allCases
            let current = cases.firstIndex(of: self.singleBiome) ?? 0
            self.singleBiome = cases[(current + 1) % cases.count]
            self.updateWorldTypeLabels()
        }
        buttons.append(worldTypeBtn)
        buttons.append(biomeBtn)
        dungeonBtn = Button(cx - 100, layout.dungeonY(showsBiome: false), 200, 20, "", {})
        dungeonBtn.onClick = { [weak self] in
            guard let self else { return }
            let cases = DungeonDensity.allCases
            let current = cases.firstIndex(of: self.dungeonDensity) ?? 1
            self.dungeonDensity = cases[(current + 1) % cases.count]
            self.updateWorldTypeLabels()
        }
        buttons.append(dungeonBtn)
        let create = Button(cx - 100, layout.actionY(showsBiome: false), 98, 20, lanHostRequest == nil ? "Create World" : "Create & Host", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game, !self.creating else { return }
            self.creating = true
            game.createWorld(name: self.nameField.text.isEmpty ? "New World" : self.nameField.text,
                             seedText: self.seedField.text, mode: self.mode, difficulty: self.difficulty,
                             worldPreset: self.worldPreset, singleBiome: self.singleBiome,
                             dungeonDensity: self.dungeonDensity)
            self.startPendingLANHost(game)
            ui.open(LoadingScreen(), game)
        })
        let cancel = Button(cx + 2, layout.actionY(showsBiome: false), 98, 20, "Cancel", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        })
        createBtn = create
        cancelBtn = cancel
        buttons.append(create)
        buttons.append(cancel)
        updateWorldTypeLabels()
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        lastUIHeight = ui.height
        let layout = Layout(uiHeight: ui.height)
        let showsBiome = worldPreset == .singleBiomeSurface
        ui.drawDirtBg()
        ui.cv.drawTextCentered(lanHostRequest == nil ? "Create New World" : "Create World to Host", ui.width / 2, 10, 1)
        ui.cv.drawText("World Name", nameField.x, nameField.y - 10, 1, "#a0a0a0")
        ui.cv.drawText("Seed", seedField.x, seedField.y - 10, 1, "#a0a0a0")
        if creating {
            ui.cv.drawTextCentered("Generating world...", ui.width / 2, layout.statusY(showsBiome: showsBiome), 1, "#ffff55")
        }
        ui.drawButtons(self)
    }

    private func updateWorldTypeLabels() {
        worldTypeBtn?.label = "World Type: \(worldPreset.displayName)"
        biomeBtn?.label = "Biome: \(singleBiomeDisplayName(singleBiome))"
        let showsBiome = worldPreset == .singleBiomeSurface
        biomeBtn?.visible = showsBiome
        let layout = Layout(uiHeight: lastUIHeight)
        biomeBtn?.y = layout.biomeY
        dungeonBtn?.y = layout.dungeonY(showsBiome: showsBiome)
        createBtn?.y = layout.actionY(showsBiome: showsBiome)
        cancelBtn?.y = layout.actionY(showsBiome: showsBiome)
        dungeonBtn?.label = "Dungeons: \(dungeonDensity.displayName)"
    }

    private func startPendingLANHost(_ game: GameCore) {
        guard let lanHostRequest else { return }
        do {
            try LANMultiplayerManager.shared.startHost(
                game: game,
                requestedJoinCode: lanHostRequest.joinCode,
                requestedPort: lanHostRequest.port
            )
            for line in LANMultiplayerManager.shared.statusSummary() {
                pushChat("§7" + line)
            }
        } catch let error as LANTransportError {
            pushChat("§c" + error.description)
        } catch {
            pushChat("§cLAN host failed: \(error)")
        }
    }
}

let DIFFICULTY_NAMES = ["Peaceful", "Easy", "Normal", "Hard"]

// =============================================================================
/// shown right after world entry while nearby chunks mesh — sim keeps running
/// (the player is frozen by heldForChunks until the ground exists)
final class LoadingScreen: Screen {
    private var openedAt = CACurrentMediaTime()
    static let target = 30

    override init() {
        super.init()
        closeOnEsc = false
    }
    /// sections meshed within 2 chunks of the player
    private func progress(_ game: GameCore) -> (Int, Int, Bool) {
        guard let renderer = gAppDelegate?.renderer, game.hasWorld(), let p = game.player else {
            return (0, Self.target, false)
        }
        let pcx = Int(p.x.rounded(.down)) >> 4, pcz = Int(p.z.rounded(.down)) >> 4
        var n = 0
        for key in renderer.sections.keys where abs(key.cx - pcx) <= 2 && abs(key.cz - pcz) <= 2 {
            n += 1
        }
        return (n, Self.target, n >= Self.target)
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        let (done, target, ready) = progress(game)
        let elapsed = CACurrentMediaTime() - openedAt
        if (ready && elapsed > 0.4) || elapsed > 8 {
            ui.closeTop(game)
            return
        }
        ui.drawDirtBg()
        ui.cv.drawTextCentered("Loading world…", ui.width / 2, ui.height / 2 - 24, 1)
        let w = 200.0
        let x = (ui.width - w) / 2, y = ui.height / 2
        let f = target > 0 ? min(1, Double(done) / Double(target)) : 0
        ui.cv.setFill("#1c1c1c")
        ui.cv.fillRect(x, y, w, 6)
        ui.cv.setFill("#80ff20")
        ui.cv.fillRect(x, y, (w * f).rounded(), 6)
        ui.cv.drawTextCentered("§7Building terrain (\(done)/\(target))", ui.width / 2, y + 14, 1)
    }
}

// =============================================================================
final class PauseScreen: Screen {
    override init() {
        super.init()
        pausesGame = true
    }
    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        let cx = (ui.width / 2).rounded(.down)
        var y = (ui.height / 2).rounded(.down) - 50
        buttons.append(Button(cx - 100, y, 200, 20, "Back to Game", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Advancements", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(AdvancementsScreen(), game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Options...", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(SettingsScreen(), game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Open to LAN", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.open(LANLobbyScreen(), game)
        }))
        y += 24
        buttons.append(Button(cx - 100, y, 200, 20, "Save & Quit to Title", { [weak game] in
            guard let game else { return }
            game.exitToTitle()
        }))
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.5)
        ui.cv.drawTextCentered("Game Menu", ui.width / 2, (ui.height / 2).rounded(.down) - 70, 1)
        ui.drawButtons(self)
    }
}

// =============================================================================
final class SettingsScreen: Screen {
    var tab = "video"
    var bindingKey: String?
    private var controlsScrollOffset = 0.0
    private var controlsLayout: PebbleControlsLayout?
    private var pendingKeybindConflict: PebbleControlsPendingConflict?
    private var pendingKeybindExpectedRevision: UInt64?
    private var controlsStatus = ""
    var aiModelField: TextField?
    var aiModelChoices: [String] = []
    var aiStatus = ""
    var hasActiveControlsCapture: Bool { bindingKey != nil }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        rebuild(ui, game)
    }

    @discardableResult
    private func persistSettingsMutation(
        _ game: GameCore, _ mutation: (inout Settings) -> Void
    ) -> Bool {
        var candidate = game.settings
        mutation(&candidate)
        return persistSettingsCandidate(
            game, candidate: candidate, expectedRevision: game.settingsRevision)
    }

    @discardableResult
    private func persistSettingsCandidate(
        _ game: GameCore, candidate: Settings, expectedRevision: UInt64
    ) -> Bool {
        return MainActor.assumeIsolated {
            if case .success = game.persistAndPublishSettingsCandidate(
                candidate, expectedLiveRevision: expectedRevision) { return true }
            return false
        }
    }

    @discardableResult
    private func persistControlsCandidate(
        _ game: GameCore, candidate: [String: String], expectedRevision: UInt64,
        successMessage: String
    ) -> Bool {
        let result = MainActor.assumeIsolated {
            game.persistAndPublishKeybindCandidate(
                candidate, expectedLiveRevision: expectedRevision)
        }
        switch result {
        case .success:
            controlsStatus = successMessage
            return true
        case .failure(let error):
            controlsStatus = "Could not save binding: \(error.description)"
            return false
        }
    }

    func rebuild(_ ui: UIManager, _ game: GameCore) {
        buttons = []
        sliders = []
        fields = []
        aiModelField = nil
        controlsLayout = nil
        let cx = (ui.width / 2).rounded(.down)
        // tabs
        let tabs = ["video", "audio", "controls", "accessibility", "ai"]
        let tabW = 64.0
        let tabStart = cx - (Double(tabs.count) * tabW) / 2
        for (i, t) in tabs.enumerated() {
            let label = t == "accessibility" ? "Access" : t.prefix(1).uppercased() + String(t.dropFirst())
            let b = Button(tabStart + Double(i) * tabW, 20, tabW - 2, 16, label, { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                guard self.saveAIModelIfNeeded(game) else { return }
                self.tab = t
                self.bindingKey = nil
                self.pendingKeybindConflict = nil
                self.pendingKeybindExpectedRevision = nil
                self.controlsStatus = ""
                self.rebuild(ui, game)
            })
            buttons.append(b)
        }
        var y = 46.0
        let W = 150.0, GAP = 158.0
        func toggle(_ label: String, _ get: @escaping (Settings) -> Bool,
                    _ set: @escaping (inout Settings, Bool) -> Void, _ col: Int) {
            let b = Button(cx - 160 + Double(col) * GAP, y, W, 18,
                           "\(label): \(get(game.settings) ? "ON" : "OFF")", {})
            b.onClick = { [weak self, weak b, weak game] in
                guard let self, let b, let game else { return }
                let next = !get(game.settings)
                guard self.persistSettingsMutation(game, { set(&$0, next) }) else { return }
                b.label = "\(label): \(get(game.settings) ? "ON" : "OFF")"
            }
            buttons.append(b)
        }
        if tab == "video" {
            sliders.append(Slider(cx - 160, y, W, 18,
                { [weak game] in "Render Distance: \(game?.settings.renderDistance ?? 8)" },
                { [weak game] in Double((game?.settings.renderDistance ?? 8) - 4) / 12 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) {
                        $0.renderDistance = 4 + Int((v * 12).rounded())
                    }
                }))
            sliders.append(Slider(cx - 2, y, W, 18,
                { [weak game] in "FOV: \(game?.settings.fov ?? 70)" },
                { [weak game] in Double((game?.settings.fov ?? 70) - 60) / 50 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) {
                        $0.fov = 60 + Int((v * 50).rounded())
                    }
                }))
            y += 22
            sliders.append(Slider(cx - 160, y, W, 18,
                { [weak game] in "Brightness: \(Int(((game?.settings.gamma ?? 0.5) * 100).rounded()))%" },
                { [weak game] in game?.settings.gamma ?? 0.5 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) { $0.gamma = v }
                }))
            sliders.append(Slider(cx - 2, y, W, 18,
                { [weak game] in
                    let g = game?.settings.guiScale ?? 0
                    return "GUI Scale: \(g == 0 ? "Auto" : String(g))"
                },
                { [weak game] in Double(game?.settings.guiScale ?? 0) / 4 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    let persisted = self.persistSettingsMutation(game) {
                        $0.guiScale = Int((v * 4).rounded())
                    }
                    // Re-layout only after the durable candidate publishes.
                    if persisted, let a = gAppDelegate {
                        a.ui.resize(Double(a.gameView.drawableSize.width),
                                    Double(a.gameView.drawableSize.height),
                                    a.game.settings.guiScale, relayout: a.game)
                    }
                }))
            y += 22
            toggle("Fancy Graphics", { $0.fancyGraphics }, { $0.fancyGraphics = $1 }, 0)
            toggle("Smooth Lighting", { $0.smoothLighting }, { $0.smoothLighting = $1 }, 1)
            y += 22
            toggle("Bloom", { $0.bloom }, { $0.bloom = $1 }, 0)
            toggle("Soft Shadows", { $0.shadows }, { $0.shadows = $1 }, 1)
            y += 22
            toggle("Clouds", { $0.clouds }, { $0.clouds = $1 }, 0)
            toggle("View Bobbing", { $0.viewBobbing }, { $0.viewBobbing = $1 }, 1)
            y += 22
            let fullscreen = Button(cx - 160, y, W, 18,
                "Fullscreen: \((gAppDelegate?.window?.styleMask.contains(.fullScreen) ?? false) ? "ON" : "OFF")", {
                    gAppDelegate?.window?.toggleFullScreen(nil)
                })
            buttons.append(fullscreen)
            y += 22
            sliders.append(Slider(cx - 160, y, W, 18,
                { [weak game] in "Particles: \(["Minimal", "Decreased", "All"][min(2, game?.settings.particles ?? 2)])" },
                { [weak game] in Double(game?.settings.particles ?? 2) / 2 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) {
                        $0.particles = Int((v * 2).rounded())
                    }
                }))
            sliders.append(Slider(cx - 2, y, W, 18,
                { [weak game] in
                    let f = game?.settings.maxFps ?? 250
                    return "Max FPS: \(f >= 250 ? "Unlimited" : String(f))"
                },
                { [weak game] in Double((game?.settings.maxFps ?? 250) - 30) / 220 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) {
                        $0.maxFps = 30 + Int((v * 220).rounded())
                    }
                }))
            y += 22
            let shaderB = Button(cx - 160, y, W, 18, "", {})
            func shaderLabel() -> String {
                "Shaders: \(game.settings.shader == "ultra" ? "§6ULTRA§r" : "OFF")"
            }
            shaderB.label = shaderLabel()
            shaderB.onClick = { [weak self, weak shaderB, weak game] in
                guard let self, let shaderB, let game else { return }
                guard self.persistSettingsMutation(game, {
                    $0.shader = game.settings.shader == "ultra" ? nil : "ultra"
                }) else { return }
                shaderB.label = shaderLabel()
            }
            buttons.append(shaderB)
        } else if tab == "audio" {
            let cats: [(String, String)] = [
                ("master", "Master Volume"), ("music", "Music"), ("blocks", "Blocks"),
                ("hostile", "Hostile Creatures"), ("friendly", "Friendly Creatures"),
                ("players", "Players"), ("ambient", "Ambient"), ("records", "Jukebox"),
                ("ui", "UI"),
            ]
            for (i, cat) in cats.enumerated() {
                let col = i % 2
                let key = cat.0, label = cat.1
                sliders.append(Slider(cx - 160 + Double(col) * GAP, y, W, 18,
                    { [weak game] in "\(label): \(Int(((game?.settings.volumes[key] ?? 1) * 100).rounded()))%" },
                    { [weak game] in game?.settings.volumes[key] ?? 1 },
                    { [weak self, weak game] v in
                        guard let self, let game else { return }
                        _ = self.persistSettingsMutation(game) { $0.volumes[key] = v }
                    }))
                if col == 1 { y += 22 }
            }
        } else if tab == "controls" {
            sliders.append(Slider(cx - 160, y, W, 18,
                { [weak game] in "Sensitivity: \(Int(((game?.settings.sensitivity ?? 0.5) * 200).rounded()))%" },
                { [weak game] in game?.settings.sensitivity ?? 0.5 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) { $0.sensitivity = v }
                }))
            toggle("Invert Y", { $0.invertY }, { $0.invertY = $1 }, 1)
            y += 26
            let contentBottom = max(y, ui.height - (pendingKeybindConflict == nil ? 52 : 72))
            let layout = PebbleControlsLayout(
                viewportWidth: ui.width, contentTop: y, contentBottom: contentBottom,
                requestedScrollOffset: controlsScrollOffset, bindings: game.keybinds)
            controlsLayout = layout
            controlsScrollOffset = layout.clampedScrollOffset
            for row in layout.visibleRows {
                let captureWidth = 48.0
                let resetWidth = 36.0
                let resetX = row.x + row.width - resetWidth
                let captureX = resetX - captureWidth - 2
                let capture = Button(captureX, row.y + 1, captureWidth, 18,
                                     bindingKey == row.actionID ? "Listening" : "Capture", {})
                capture.onClick = { [weak self, weak ui, weak game] in
                    guard let self, let ui, let game else { return }
                    self.bindingKey = row.actionID
                    self.pendingKeybindConflict = nil
                    self.pendingKeybindExpectedRevision = nil
                    self.controlsStatus = "Press a chord; Escape cancels."
                    self.rebuild(ui, game)
                }
                buttons.append(capture)

                let reset = Button(resetX, row.y + 1, resetWidth, 18, "Reset", {})
                reset.onClick = { [weak self, weak ui, weak game] in
                    guard let self, let ui, let game,
                          let definition = KEYBIND_DEFINITIONS.first(where: {
                              $0.actionID == row.actionID
                          }) else { return }
                    self.bindingKey = nil
                    self.pendingKeybindConflict = nil
                    self.pendingKeybindExpectedRevision = nil
                    self.applyControlsChord(definition.defaultChord, actionID: row.actionID,
                                            ui: ui, game: game)
                }
                buttons.append(reset)
            }
            if let pending = pendingKeybindConflict,
               let expectedRevision = pendingKeybindExpectedRevision {
                let useAnyway = Button(cx - 50, ui.height - 52, 100, 16, "Use Anyway", {})
                useAnyway.onClick = { [weak self, weak ui, weak game] in
                    guard let self, let ui, let game else { return }
                    if self.persistControlsCandidate(
                        game, candidate: pending.candidateBindings,
                        expectedRevision: expectedRevision,
                        successMessage: "Saved \(pending.chord.description) for \(pending.actionID)."
                    ) {
                        self.pendingKeybindConflict = nil
                        self.pendingKeybindExpectedRevision = nil
                    }
                    self.rebuild(ui, game)
                }
                buttons.append(useAnyway)
            }
        } else if tab == "accessibility" {
            toggle("Subtitles", { $0.subtitles }, { $0.subtitles = $1 }, 0)
            toggle("Auto-Jump", { $0.autoJump }, { $0.autoJump = $1 }, 1)
            y += 22
            toggle("Reduce Motion", { $0.reduceMotion }, { $0.reduceMotion = $1 }, 0)
            toggle("Reduced Flashes", { $0.reducedFlashes }, { $0.reducedFlashes = $1 }, 1)
            y += 22
            toggle("High Contrast UI", { $0.highContrast }, { $0.highContrast = $1 }, 0)
            sliders.append(Slider(cx - 2, y, W, 18,
                { [weak game] in "Darkness Pulsing: \(Int(((game?.settings.darknessPulse ?? 1) * 100).rounded()))%" },
                { [weak game] in game?.settings.darknessPulse ?? 1 },
                { [weak self, weak game] v in
                    guard let self, let game else { return }
                    _ = self.persistSettingsMutation(game) { $0.darknessPulse = v }
                }))
        } else if tab == "ai" {
            let modelField = TextField(cx - 160, y + 14, W * 2 + 8, 18, "ollama model",
                                       id: "settings.ollamaModel",
                                       accessibilityLabel: "Ollama Model")
            modelField.maxLength = 128
            modelField.text = game.settings.aiOllamaModel
            modelField.caret = modelField.text.count
            fields.append(modelField)
            aiModelField = modelField

            buttons.append(Button(cx - 160, y + 38, W, 18, "Save Model", { [weak self, weak game] in
                guard let self, let game else { return }
                guard self.saveAIModelIfNeeded(game) else { return }
                self.aiStatus = game.settings.aiOllamaModel.isEmpty ? "Model cleared" : "Saved \(game.settings.aiOllamaModel)"
            }))
            buttons.append(Button(cx - 2, y + 38, W, 18, "Refresh Models", { [weak self, weak ui, weak game] in
                guard let self, let ui, let game else { return }
                guard self.saveAIModelIfNeeded(game) else { return }
                let refreshCandidate = game.settings
                let refreshExpectedRevision = game.settingsRevision
                self.aiStatus = "Refreshing..."
                pebbleOllamaAgent.fetchModels { [weak self, weak ui, weak game] result in
                    guard let self, let ui, let game else { return }
                    switch result {
                    case .success(let names):
                        var candidate = refreshCandidate
                        if candidate.aiOllamaModel.isEmpty, let first = names.first {
                            candidate.aiOllamaModel = first
                        }
                        guard self.persistSettingsCandidate(
                            game, candidate: candidate,
                            expectedRevision: refreshExpectedRevision) else { return }
                        self.aiModelChoices = names
                        self.aiStatus = names.isEmpty ? "No local models found" : "Loaded \(names.count) local models"
                    case .failure(let error):
                        self.aiStatus = "Ollama unavailable: \(error.localizedDescription)"
                    }
                    self.rebuild(ui, game)
                }
            }))
            let next = Button(cx - 160, y + 60, W, 18, "Next Model", { [weak self, weak game] in
                guard let self, let game, !self.aiModelChoices.isEmpty else { return }
                let current = sanitizedOllamaModelName(self.aiModelField?.text ?? game.settings.aiOllamaModel)
                let idx = self.aiModelChoices.firstIndex(of: current) ?? -1
                let next = self.aiModelChoices[(idx + 1) % self.aiModelChoices.count]
                guard self.persistSettingsMutation(game, { $0.aiOllamaModel = next }) else { return }
                self.aiModelField?.text = next
                self.aiModelField?.caret = next.count
                self.aiStatus = "Selected \(next)"
            })
            next.enabled = !aiModelChoices.isEmpty
            buttons.append(next)
            buttons.append(Button(cx - 2, y + 60, W, 18, "Clear Model", { [weak self, weak game] in
                guard let self, let game else { return }
                guard self.persistSettingsMutation(game, { $0.aiOllamaModel = "" }) else { return }
                self.aiModelField?.text = ""
                self.aiModelField?.caret = 0
                self.aiStatus = "Model cleared"
            }))
        }
        buttons.append(Button(cx - 100, ui.height - 30, 200, 20, "Done", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game else { return }
            guard self.saveAIModelIfNeeded(game) else { return }
            ui.closeTop(game)
        }))
    }

    /// Shared capture seam for the AppKit router: validation is pure and the live label remains
    /// sourced from `game.keybinds` until the detached candidate has durably published.
    func applyControlsChord(_ chord: PebbleKeyChord, actionID: String,
                            ui: UIManager, game: GameCore) {
        let expectedRevision = game.keybindRevision
        bindingKey = nil
        pendingKeybindConflict = nil
        pendingKeybindExpectedRevision = nil
        switch prepareControlsKeybindCandidate(
            bindings: game.keybinds, actionID: actionID, chord: chord) {
        case .reserved:
            controlsStatus = "Reserved by Pebble"
        case .invalidAction, .invalidBindings:
            controlsStatus = "Binding was not changed."
        case .conflict(let pending):
            pendingKeybindConflict = pending
            pendingKeybindExpectedRevision = expectedRevision
            controlsStatus = "Conflict: \(pending.conflictingActionIDs.joined(separator: ", ")). "
                + "Winner: \(pending.winnerActionID)."
        case .ready(let committedActionID, let canonicalChord, let candidate):
            _ = persistControlsCandidate(
                game, candidate: candidate, expectedRevision: expectedRevision,
                successMessage: "Saved \(canonicalChord.description) for \(committedActionID).")
        }
        rebuild(ui, game)
    }

    @discardableResult
    func cancelControlsCapture(_ ui: UIManager, _ game: GameCore) -> Bool {
        guard bindingKey != nil || pendingKeybindConflict != nil else { return false }
        bindingKey = nil
        pendingKeybindConflict = nil
        pendingKeybindExpectedRevision = nil
        controlsStatus = "Capture cancelled."
        rebuild(ui, game)
        return true
    }

    @discardableResult
    func handleControlsKeyEvent(_ event: PebbleKeyEvent,
                                ui: UIManager, game: GameCore) -> Bool {
        guard let binding = bindingKey else { return false }
        if event.terminal.rawValue == "Escape" { return cancelControlsCapture(ui, game) }
        guard !event.isRepeat, let chord = event.chord else {
            controlsStatus = "That key cannot be bound."
            rebuild(ui, game)
            return true
        }
        applyControlsChord(chord, actionID: binding, ui: ui, game: game)
        return true
    }

    @discardableResult
    func saveAIModelIfNeeded(_ game: GameCore) -> Bool {
        guard tab == "ai", let field = aiModelField else { return true }
        var model = sanitizedOllamaModelName(field.text)
        if !model.isEmpty && !isAllowedLocalOllamaModelName(model) {
            model = ""
            aiStatus = "Cloud models are not allowed"
        }
        guard persistSettingsMutation(game, { $0.aiOllamaModel = model }) else { return false }
        field.text = model
        field.caret = min(field.caret, field.text.count)
        return true
    }
    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        if tab == "ai", key == "Enter" {
            guard saveAIModelIfNeeded(game) else { return true }
            aiStatus = game.settings.aiOllamaModel.isEmpty ? "Model cleared" : "Saved \(game.settings.aiOllamaModel)"
            return true
        }
        return super.onKey(ui, game, key)
    }
    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        guard tab == "controls", let layout = controlsLayout else {
            return super.onWheel(ui, game, dy)
        }
        let finiteDelta = dy.isFinite ? dy : 0
        controlsScrollOffset = min(max(0,
            layout.clampedScrollOffset + finiteDelta * PebbleControlsLayout.rowStride),
            layout.maximumScrollOffset)
        rebuild(ui, game)
        return true
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        if game.hasWorld() {
            ui.drawDarkBg(0.65)
        } else {
            ui.drawDirtBg()
        }
        ui.cv.drawTextCentered("Options", ui.width / 2, 6, 1)
        if tab == "controls", let layout = controlsLayout {
            for row in layout.visibleRows {
                let definition = KEYBIND_DEFINITIONS[row.definitionIndex]
                let hovered = ui.mouseX >= row.x && ui.mouseX < row.x + row.width
                    && ui.mouseY >= row.y && ui.mouseY < row.y + row.height
                ui.cv.setFill(hovered ? "rgba(255,255,255,0.16)" : "rgba(0,0,0,0.24)")
                ui.cv.fillRect(row.x, row.y, row.width, row.height)
                let textWidthAvailable = max(24, row.width - 92)
                ui.cv.drawText(controlsClipped(definition.displayName,
                                               maximumPixels: textWidthAvailable),
                               row.x + 3, row.y + 2, 0.75, "#ffffff", shadow: false)
                let bindingText = bindingKey == row.actionID
                    ? "[press chord]" : row.chordText + (row.conflictText == nil ? "" : " • Conflict")
                ui.cv.drawText(controlsClipped(bindingText, maximumPixels: textWidthAvailable,
                                               scale: 0.75),
                               row.x + 3, row.y + 11, 0.75,
                               row.conflictText == nil ? "#b8b8b8" : "#ffb060", shadow: false)
                if hovered {
                    var lines = [definition.displayName, "Binding: \(row.chordText)"]
                    if let conflict = row.conflictText { lines.append(conflict) }
                    ui.tooltipLines = lines
                }
            }
            let contentTop = 72.0
            let contentBottom = max(contentTop,
                ui.height - (pendingKeybindConflict == nil ? 52 : 72))
            if layout.maximumScrollOffset > 0, contentBottom > contentTop {
                let trackHeight = contentBottom - contentTop
                let contentHeight = trackHeight + layout.maximumScrollOffset
                let thumbHeight = max(10, trackHeight * trackHeight / contentHeight)
                let thumbY = contentTop + (trackHeight - thumbHeight)
                    * layout.clampedScrollOffset / layout.maximumScrollOffset
                ui.cv.setFill("rgba(0,0,0,0.45)")
                ui.cv.fillRect(ui.width - 5, contentTop, 3, trackHeight)
                ui.cv.setFill("rgba(255,255,255,0.60)")
                ui.cv.fillRect(ui.width - 5, thumbY, 3, thumbHeight)
            }
            if !controlsStatus.isEmpty {
                let statusY = contentBottom + 2
                ui.cv.drawText(controlsClipped(controlsStatus,
                                               maximumPixels: max(20, ui.width - 28), scale: 0.75),
                               14, statusY, 0.75,
                               pendingKeybindConflict == nil ? "#d0d0d0" : "#ffb060",
                               shadow: false)
                if ui.mouseY >= statusY - 2 && ui.mouseY < statusY + 10 {
                    ui.tooltipLines = [controlsStatus]
                }
            }
        } else if tab == "ai" {
            let cx = (ui.width / 2).rounded(.down)
            ui.cv.drawText("Ollama Model", cx - 160, 46, 1)
            if !aiStatus.isEmpty {
                ui.cv.drawText(aiStatus, cx - 160, 132, 1, "#a0a0a0")
            }
        }
        ui.drawButtons(self)
    }

    private func controlsClipped(_ text: String, maximumPixels: Double,
                                 scale: Double = 0.75) -> String {
        guard maximumPixels > 0, Double(textWidth(text)) * scale > maximumPixels else { return text }
        var result = text
        while !result.isEmpty && Double(textWidth(result + "…")) * scale > maximumPixels {
            result.removeLast()
        }
        return result + "…"
    }
}

// =============================================================================
// =============================================================================
final class AdvancementsScreen: Screen {
    var scrollX = 0.0
    var scrollY = 0.0
    var dragging = false
    var positions: [String: (Double, Double)] = [:]

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        // layout: BFS depth → column, siblings → rows
        var children: [String: [AdvancementDef]] = [:]
        for a in ADVANCEMENTS {
            children[a.parent ?? "<root>", default: []].append(a)
        }
        var nextRow = 0.0
        func place(_ id: String, _ depth: Double) -> Double {
            let kids = children[id] ?? []
            if kids.isEmpty {
                let row = nextRow
                nextRow += 1
                positions[id] = (depth, row)
                return row
            }
            let rows = kids.map { place($0.id, depth + 1) }
            let row = (rows.min()! + rows.max()!) / 2
            positions[id] = (depth, row)
            return row
        }
        _ = place("root", 0)
        buttons.append(Button(8, ui.height - 28, 80, 20, "Done", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
        }))
    }
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.drawDarkBg(0.7)
        let cv = ui.cv
        cv.drawTextCentered("Advancements (\(game.advancements.earnedOrder.count)/\(ADVANCEMENTS.count))", ui.width / 2, 6, 1)
        let ox = 30 + scrollX, oy = 30 + scrollY
        // connection lines
        cv.setStroke("#707070")
        for a in ADVANCEMENTS {
            guard let parent = a.parent, let p = positions[a.id], let pp = positions[parent] else { continue }
            cv.line(ox + pp.0 * 70 + 24, oy + pp.1 * 30 + 12, ox + p.0 * 70 - 2, oy + p.1 * 30 + 12)
        }
        var hovered: AdvancementDef?
        for a in ADVANCEMENTS {
            guard let p = positions[a.id] else { continue }
            let x = ox + p.0 * 70, y = oy + p.1 * 30
            if x < -30 || x > ui.width + 10 || y < -30 || y > ui.height + 10 { continue }
            let earned = game.advancements.has(a.id)
            cv.setFill(earned ? (a.frame == "challenge" ? "#9a4ae8" : "#e8a83c") : "#3a3a3a")
            cv.fillRect(x, y, 24, 24)  // (challenge diamonds render as squares natively)
            cv.setStroke(earned ? "#ffffff" : "#1a1a1a")
            cv.strokeRect(x, y, 24, 24)
            if let iconId = iidOpt(a.icon) {
                cv.globalAlpha = earned ? 1 : 0.4
                cv.drawItemIcon(iconId, nil, x + 4, y + 4, 16, 16)
                cv.globalAlpha = 1
            }
            if ui.mouseX >= x && ui.mouseX < x + 24 && ui.mouseY >= y && ui.mouseY < y + 24 { hovered = a }
        }
        if let hovered {
            ui.tooltipLines = [
                (game.advancements.has(hovered.id) ? "§a" : "§f") + hovered.title,
                "§7" + hovered.description,
            ]
        }
        ui.drawButtons(self)
        cv.drawText("Drag to pan", ui.width - 70, ui.height - 12, 1, "#808080")
    }
    override func onMouseDown(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double, _ btn: Int) -> Bool {
        if super.onMouseDown(ui, game, mx, my, btn) { return true }
        dragging = true
        return true
    }
    override func onMouseUp(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        super.onMouseUp(ui, game, mx, my)
        dragging = false
    }
    override func onMouseMove(_ ui: UIManager, _ game: GameCore, _ mx: Double, _ my: Double) {
        super.onMouseMove(ui, game, mx, my)
        if dragging {
            scrollX += mx - ui.mouseX
            scrollY += my - ui.mouseY
        }
    }
    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        scrollY -= (dy > 0 ? 1 : dy < 0 ? -1 : 0) * 20
        return true
    }
}

// =============================================================================
final class CreditsScreen: Screen {
    var scroll = 0.0
    private var lastT = CACurrentMediaTime()
    let lines = [
        "§ePEBBLE",
        "",
        "§7A complete block-survival game",
        "§7built from scratch in Swift + Metal.",
        "",
        "§fEvery sound synthesized in real time.",
        "§fEvery chunk carved from noise.",
        "",
        "§8— —",
        "",
        "§dTwo voices, somewhere outside the world:",
        "",
        "§3it reached the end of its journey.",
        "§9and yet the world it shaped keeps turning.",
        "§3it built, and broke, and built again.",
        "§9that is the whole of the game, and the whole of the player.",
        "§3does it know the stars were painted for it?",
        "§9it knows. it placed a torch against the dark anyway.",
        "§3let it rest now.",
        "§9let it wake. there is always another world.",
        "",
        "",
        "§eThank you for playing.",
        "",
        "§7Inspired by the classic block game.",
        "§7Pebble is an original fan re-creation.",
        "§7Not affiliated with Mojang or Microsoft.",
        "§7No Mojang code or asset files included.",
        "",
        "§fAll textures: Faithful 32x,",
        "§funmodified, by the Faithful Team.",
        "§efaithfulpack.net",
    ]
    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        ui.cv.setFill("#000000")
        ui.cv.fillRect(0, 0, ui.width, ui.height)
        // time-based: a per-frame increment scrolled 2-10× too fast uncapped
        let nowT = CACurrentMediaTime()
        scroll += min(0.25, nowT - lastT) * 15
        lastT = nowT
        var y = ui.height - scroll
        for line in lines {
            if y > -10 && y < ui.height + 10 {
                ui.cv.drawTextCentered(line, ui.width / 2, y, 1)
            }
            y += 14
        }
        if y < -20 {
            ui.closeTop(game)
        }
        ui.cv.drawTextCentered("§8Press Esc to skip", ui.width / 2, ui.height - 12, 1)
    }
}
