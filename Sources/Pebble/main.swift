// Pebble — native macOS app shell. Window + MTKView, NSEvent → key-code-style
// key codes, pointer capture, the frame loop, and the GameHost bridge wiring
// GameCore to the UI stack (title/menus/HUD/screens) and renderer.

import AppKit
import MetalKit
import PebbleCore

// ---------------------------------------------------------------------------
// NSEvent keyCode (kVK_*) → internal key-code strings (GameCore keybinds)
// ---------------------------------------------------------------------------
let KEYCODE_MAP: [UInt16: String] = [
    0: "KeyA", 1: "KeyS", 2: "KeyD", 3: "KeyF", 4: "KeyH", 5: "KeyG", 6: "KeyZ", 7: "KeyX",
    8: "KeyC", 9: "KeyV", 11: "KeyB", 12: "KeyQ", 13: "KeyW", 14: "KeyE", 15: "KeyR",
    16: "KeyY", 17: "KeyT", 18: "Digit1", 19: "Digit2", 20: "Digit3", 21: "Digit4",
    22: "Digit6", 23: "Digit5", 24: "Equal", 25: "Digit9", 26: "Digit7", 27: "Minus",
    28: "Digit8", 29: "Digit0", 30: "BracketRight", 31: "KeyO", 32: "KeyU", 33: "BracketLeft",
    34: "KeyI", 35: "KeyP", 36: "Enter", 37: "KeyL", 38: "KeyJ", 39: "Quote", 40: "KeyK",
    41: "Semicolon", 42: "Backslash", 43: "Comma", 44: "Slash", 45: "KeyN", 46: "KeyM",
    47: "Period", 48: "Tab", 49: "Space", 50: "Backquote", 51: "Backspace", 53: "Escape",
    96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10",
    111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "ArrowLeft", 124: "ArrowRight",
    125: "ArrowDown", 126: "ArrowUp", 117: "Delete",
    10: "IntlBackslash", // ISO § key
    82: "Numpad0", 83: "Numpad1", 84: "Numpad2", 85: "Numpad3", 86: "Numpad4",
    87: "Numpad5", 88: "Numpad6", 89: "Numpad7", 91: "Numpad8", 92: "Numpad9",
    65: "NumpadDecimal", 67: "NumpadMultiply", 69: "NumpadAdd", 75: "NumpadDivide",
    76: "NumpadEnter", 78: "NumpadSubtract", 81: "NumpadEqual",
]

/// bundle resource lookup with a dev fallback: under `swift run` the
/// resourcePath is .build/<config> (no bundle assembly), so walk up to the
/// repo's packaging/ — otherwise dev builds silently lose the title photo,
/// wordmark and default pack
func bundleResourcePath(_ name: String) -> String? {
    if let rp = Bundle.main.resourcePath {
        let p = rp + "/" + name
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<6 {
        let cand = dir.appendingPathComponent("packaging/" + name).path
        if FileManager.default.fileExists(atPath: cand) { return cand }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}

// ---------------------------------------------------------------------------
// host bridge: GameCore ↔ UI stack / renderer / audio
// ---------------------------------------------------------------------------
final class HostBridge: GameHost {
    weak var app: AppDelegate?
    var ui: UIManager { app!.ui }
    var hud: HUD { app!.hud }
    var game: GameCore { app!.game }

    func hasScreen() -> Bool { app?.ui.hasScreen() ?? false }
    func screenPausesGame() -> Bool { app?.ui.current()?.pausesGame ?? false }

    func openScreen(_ kind: String, _ data: ScreenData?) {
        guard let app else { return }
        switch kind {
        case "crafting":
            if let data {
                ui.open(CraftingScreen((data.x, data.y, data.z)), game)
            } else {
                ui.open(CraftingScreen(), game)
            }
        case "inventory": ui.open(InventoryScreen(), game)
        case "creative": ui.open(CreativeScreen(), game)
        case "chest":
            if let be = data?.be {
                ui.open(ChestScreen(be, data?.title ?? "Chest", data?.other), game)
            }
        case "ender_chest":
            let p = game.player!
            ui.open(ChestScreen(items: { p.enderChest }, set: { p.enderChest[$0] = $1 },
                                count: p.enderChest.count, "Ender Chest"), game)
        case "furnace":
            if let be = data?.be { ui.open(FurnaceScreen(be), game) }
        case "brewing":
            if let be = data?.be { ui.open(BrewingScreen(be), game) }
        case "enchanting":
            ui.open(EnchantingScreen((data?.x ?? 0, data?.y ?? 0, data?.z ?? 0)), game)
        case "anvil":
            ui.open(AnvilScreen((data?.x ?? 0, data?.y ?? 0, data?.z ?? 0, data?.damage ?? 0)), game)
        case "grindstone": ui.open(GrindstoneScreen(), game)
        case "stonecutter": ui.open(StonecutterScreen(), game)
        case "smithing": ui.open(SmithingScreen(), game)
        case "templates": ui.open(TemplateBrowserScreen(), game)
        case "templatesPlace": ui.open(TemplateBrowserScreen(mode: .place), game)
        case "map":
            game.resetExpandedMapCenterToPlayer()
            ui.open(MapScreen(), game)
        case "beacon":
            if let be = data?.be { ui.open(BeaconScreen(be), game) }
        case "sign":
            ui.open(SignScreen(data?.be, (data?.x ?? 0, data?.y ?? 0, data?.z ?? 0)), game)
        case "toast":
            hud.showActionBar(data?.text ?? "")
        default:
            break
        }
        if ui.hasScreen() { app.gameView.releaseMouse() }
    }
    func openTrading(_ villager: Mob) {
        ui.open(TradingScreen(villager), game)
        app?.gameView.releaseMouse()
    }
    func openVehicleChest(_ kind: String, _ vehicle: Entity) {
        let title = kind == "boat_chest" ? "Chest Boat" : "Minecart with Chest"
        if let boat = vehicle as? Boat {
            ui.open(ChestScreen(vehicle: boat, title), game)
        } else if let cart = vehicle as? Minecart {
            ui.open(ChestScreen(vehicle: cart, title), game)
        }
        app?.gameView.releaseMouse()
    }
    func openChat(_ prefix: String) {
        let g = game
        ui.open(ChatScreen({ cmd in runCommand(g, cmd) }, prefix), g)
        app?.gameView.releaseMouse()
    }
    func openDeathScreen(_ message: String) {
        ui.open(DeathScreen(message), game)
    }
    func openPauseScreen() {
        ui.open(PauseScreen(), game)
        app?.gameView.releaseMouse()
    }
    func openTitleScreen() {
        ui.titlePhoto = app?.renderer.titleBgTex != nil; ui.titleLogo = app?.renderer.titleLogoTex != nil
        ui.open(TitleScreen(), game)
        app?.gameView.releaseMouse()
    }
    func closeAllScreens() { ui.closeAll(game) }
    func releasePointer() { app?.gameView.releaseMouse() }
    func capturePointer() { app?.gameView.captureMouse() }

    func showActionBar(_ text: String, _ time: Int) {
        hud.showActionBar(text)
        hud.actionBarTime = time
    }
    func pushChat(_ line: String) { Pebble_pushChat(line) }
    func pushToast(_ adv: AdvancementDef) { hud.pushToast(adv) }
    func setBossBars(_ bars: [BossBarInfo]) { hud.bossBars = bars }

    func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double, _ pitch: Double) {
        guard let app else { return }
        if name.hasPrefix("jukebox.play.") {
            app.audio.playDisc(name, x, y, z)
            return
        }
        app.audio.play(name, x, y, z, volume, pitch)
    }
    func playUI(_ name: String) { app?.audio.playUI(name) }
    func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {
        app?.audio.setEnvironment(underwater, caveFactor)
    }
    func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {
        app?.audio.setListener(x, y, z, yaw)
    }
    func tickMusic(_ mood: String, _ enabled: Bool) { app?.audio.tickMusic(mood, enabled) }
    func stopDisc() { app?.audio.stopDisc() }

    func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double, _ count: Int, _ spread: Double, _ cell: Int) {
        guard let app, app.game.hasWorld() else { return }
        app.renderer?.particles.spawn(app.game.world, type, x, y, z, count, spread, cell: cell)
    }
    func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double, _ groundY: Double) {
        guard let app, app.game.hasWorld() else { return }
        app.renderer?.particles.spawn(app.game.world, kind, x, y, z, 1, 0.1, groundY: groundY)
    }
    func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {
        app?.renderer?.uploadMesh(cx, sy, cz, minY, mesh)
    }
    func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {
        app?.renderer?.removeChunkMeshes(cx, cz, sections)
    }
    func clearAllSections() {
        app?.renderer?.clearAllSections()
    }
}

// pushChat lives in ScreensM at module scope; alias avoids name shadowing here
func Pebble_pushChat(_ line: String) { pushChat(line) }

/// LoadingScreen reads mesh progress off the renderer through this
weak var gAppDelegate: AppDelegate?

// ---------------------------------------------------------------------------
// MTKView with keyboard/mouse capture + screen routing
// ---------------------------------------------------------------------------
final class GameView: MTKView {
    weak var appd: AppDelegate?
    private(set) var mouseCaptured = false

    override var acceptsFirstResponder: Bool { true }

    func captureMouse() {
        if mouseCaptured { return }
        mouseCaptured = true
        CGAssociateMouseAndMouseCursorPosition(0)
        NSCursor.hide()
    }
    func releaseMouse() {
        if !mouseCaptured { return }
        mouseCaptured = false
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
    }

    private func nowMs() -> Double { CACurrentMediaTime() * 1000 }
    private var ui: UIManager? { appd?.ui }
    private var game: GameCore? { appd?.game }

    private func uiPos(_ event: NSEvent) -> (Double, Double) {
        // AppKit origin is bottom-left in points; UI space is top-left in
        // drawable pixels / guiScale
        let p = convert(event.locationInWindow, from: nil)
        let bsf = Double(window?.backingScaleFactor ?? 1)
        let scale = ui?.scale ?? 1
        return (Double(p.x) * bsf / scale, (Double(bounds.height) - Double(p.y)) * bsf / scale)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleObjectTemplateShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let game, let ui = ui else { return }
        let code = KEYCODE_MAP[event.keyCode] ?? ""
        // fullscreen toggle works everywhere, including over open screens
        if code == "F11" {
            window?.toggleFullScreen(nil)
            return
        }
        if let screen = ui.current() {
            if event.isARepeat && code != "Backspace" && !code.hasPrefix("Arrow") &&
                code != "Comma" && code != "Period" { return }
            if code == "Escape" {
                if screen.closeOnEsc {
                    ui.closeTop(game)
                    recaptureIfClear()
                }
                return
            }
            if screen.onKey(ui, game, code) {
                recaptureIfClear()
                return
            }
            if let chars = event.characters, !chars.isEmpty, !event.modifierFlags.contains(.command),
               !event.modifierFlags.contains(.control),
               chars.allSatisfy({ !$0.isNewline && $0.asciiValue.map { $0 >= 32 } ?? true }) {
                if screen.onChar(ui, game, chars) { return }
            }
            // inventory key closes inventory-style screens (never text screens)
            if code == game.keybinds["inventory"], screen.closeOnEsc, !(screen is ChatScreen),
               !screen.fields.contains(where: { $0.focused }) {
                ui.closeTop(game)
                recaptureIfClear()
            }
            return
        }
        guard game.hasWorld() else { return }
        if code == "Comma" {
            game.zoomMap(false)
            return
        }
        if code == "Period" {
            game.zoomMap(true)
            return
        }
        if event.isARepeat { return }
        // HUD toggles stay app-side
        if code == "F3" {
            appd?.hud.debugVisible.toggle()
            return
        }
        if code == "F1" {
            appd?.hud.hideGui.toggle()
            return
        }
        if handleObjectTemplateShortcut(event) { return }
        if code == "KeyM" {
            game.openScreen("map", nil)
            return
        }
        game.keyDown(code, now: nowMs(),
                     ctrlOrCmd: event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control))
    }

    @discardableResult
    private func handleObjectTemplateShortcut(_ event: NSEvent) -> Bool {
        guard let game, let ui = ui else { return false }
        let code = KEYCODE_MAP[event.keyCode] ?? ""
        guard let action = objectTemplateShortcutAction(forKey: code,
                                                        commandDown: event.modifierFlags.contains(.command),
                                                        hasOpenScreen: ui.hasScreen(),
                                                        hasWorld: game.hasWorld(),
                                                        isRepeat: event.isARepeat) else { return false }
        return performObjectTemplateShortcut(action)
    }

    @discardableResult
    func performObjectTemplateShortcut(_ action: ObjectTemplateShortcutAction) -> Bool {
        guard let game, let ui = ui, game.hasWorld(), !ui.hasScreen() else { return false }
        switch action {
        case .copyObject:
            openTemplateCopyDialog(game, ui)
        case .placeObject:
            openTemplatePlacementBrowser(game, ui)
        }
        return true
    }

    private func openTemplateCopyDialog(_ game: GameCore, _ ui: UIManager) {
        guard let target = game.templateCopyTargetAtCrosshair() else {
            let message = "Point the center crosshair at an object to copy."
            appd?.hud.showActionBar(message)
            game.host?.pushChat("§c" + message)
            return
        }
        ui.open(TemplateNameScreen(target: target), game)
        releaseMouse()
    }

    private func openTemplatePlacementBrowser(_ game: GameCore, _ ui: UIManager) {
        ui.open(TemplateBrowserScreen(mode: .place), game)
        releaseMouse()
    }

    override func keyUp(with event: NSEvent) {
        guard let game, let code = KEYCODE_MAP[event.keyCode] else { return }
        game.keyUp(code)
    }
    override func flagsChanged(with event: NSEvent) {
        guard let game, let ui = ui else { return }
        let shift = event.modifierFlags.contains(.shift)
        let ctrl = event.modifierFlags.contains(.control)
        ui.shiftDown = shift
        if ui.hasScreen() {
            // releases must still reach the game — eating them left the
            // player permanently sneaking after shift+E, release, close
            if !shift { game.keyUp("ShiftLeft") }
            if !ctrl { game.keyUp("ControlLeft") }
            return
        }
        // sneak/sprint default binds are modifier keys — synthesize code events
        if shift { game.keyDown("ShiftLeft", now: nowMs()) } else { game.keyUp("ShiftLeft") }
        if ctrl { game.keyDown("ControlLeft", now: nowMs()) } else { game.keyUp("ControlLeft") }
    }

    private func recaptureIfClear() {
        if let ui = ui, !ui.hasScreen(), let game = game, game.hasWorld() {
            captureMouse()
        }
    }

    private func routeMouseDown(_ event: NSEvent, _ btn: Int) {
        guard let game, let ui = ui else { return }
        if let screen = ui.current() {
            let (mx, my) = uiPos(event)
            ui.mouseX = mx
            ui.mouseY = my
            _ = screen.onMouseDown(ui, game, mx, my, btn)
            recaptureIfClear()
            return
        }
        guard game.hasWorld() else { return }
        if !mouseCaptured {
            captureMouse()
            return
        }
        game.mouseDown(btn)
    }

    override func mouseDown(with event: NSEvent) { routeMouseDown(event, 0) }
    override func rightMouseDown(with event: NSEvent) { routeMouseDown(event, 2) }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { routeMouseDown(event, 1) }
    }
    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { game?.mouseUp(1) }
    }
    override func mouseUp(with event: NSEvent) {
        if let screen = ui?.current(), let game, let ui = ui {
            let (mx, my) = uiPos(event)
            screen.onMouseUp(ui, game, mx, my)
        }
        game?.mouseUp(0)
    }
    override func rightMouseUp(with event: NSEvent) { game?.mouseUp(2) }
    override func mouseDragged(with event: NSEvent) { handleMove(event) }
    override func rightMouseDragged(with event: NSEvent) { handleMove(event) }
    override func mouseMoved(with event: NSEvent) { handleMove(event) }
    private func handleMove(_ event: NSEvent) {
        guard let game, let ui = ui else { return }
        if ui.hasScreen() || !mouseCaptured {
            let (mx, my) = uiPos(event)
            let oldX = ui.mouseX, oldY = ui.mouseY
            _ = (oldX, oldY)
            ui.current()?.onMouseMove(ui, game, mx, my)
            ui.mouseX = mx
            ui.mouseY = my
            return
        }
        game.mouseDelta(Double(event.deltaX), Double(event.deltaY))
    }
    private var scrollAccum = 0.0
    override func scrollWheel(with event: NSEvent) {
        guard let game, let ui = ui else { return }
        var dy = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas {
            // trackpads deliver many sub-notch deltas — accumulate to a
            // notch instead of discarding them (slow two-finger scrolling
            // did nothing at all)
            scrollAccum += dy
            if abs(scrollAccum) < 8 { return }
            dy = scrollAccum
            scrollAccum = 0
        } else if abs(dy) < 0.5 {
            return
        }
        if let screen = ui.current() {
            _ = screen.onWheel(ui, game, dy > 0 ? -1 : 1)
            return
        }
        if game.hasWorld() {
            game.wheelHotbar(dy > 0 ? 1 : -1)
        }
    }
}

// ---------------------------------------------------------------------------
// app delegate: window, game, renderer, UI, frame loop
// ---------------------------------------------------------------------------
final class AppDelegate: NSObject, NSApplicationDelegate, MTKViewDelegate, NSWindowDelegate {
    var window: NSWindow!
    var gameView: GameView!
    var renderer: WorldRenderer!
    let host = HostBridge()
    var game: GameCore!
    var ui: UIManager!
    let hud = HUD()
    let audio = AudioEngineM()
    private var lastFrame = CACurrentMediaTime()
    private var startTime = CACurrentMediaTime()
    private var fpsCounter = 0
    private var fpsTimer = 0.0
    private var fps = 0
    private var uncappedMode = false
    private var uncapTimer: Timer?
    var bot: PhysicsBot?
    var booth: PhotoBooth?
    // test hook: PEBBLE_CMD="/tp 0 120 0;/time set 1000" runs once the world is up
    private var pendingCmds = ProcessInfo.processInfo.environment["PEBBLE_CMD"]
    private var pendingCmdDelay = 0
    // test hook: PEBBLE_SHOT="/tmp/x.png@300" captures the frame N frames after load
    private var shotQuitFrames = 0
    private var pendingShot: (path: String, frames: Int)? = {
        guard let v = ProcessInfo.processInfo.environment["PEBBLE_SHOT"] else { return nil }
        let parts = v.components(separatedBy: "@")
        return (parts[0], parts.count > 1 ? Int(parts[1]) ?? 240 : 240)
    }()
    // test hook: PEBBLE_OPEN_SCREEN=templates|templatesPlace|creative opens an allowlisted UI screen before PEBBLE_SHOT.
    private var pendingOpenScreen = ProcessInfo.processInfo.environment["PEBBLE_OPEN_SCREEN"]
    private var pendingOpenScreenDelay = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        gAppDelegate = self
        let t0 = CFAbsoluteTimeGetCurrent()
        game = GameCore()
        game.host = host
        host.app = self
        print(String(format: "registries: %.0fms (%d blocks, %d items, %d biomes)",
                     (CFAbsoluteTimeGetCurrent() - t0) * 1000, blockDefs.count, itemDefs.count, BIOMES.count))

        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
        let t1 = CFAbsoluteTimeGetCurrent()
        renderer = WorldRenderer(device: device)
        ui = UIManager(cv: UICanvas(device: device))
        print(String(format: "renderer: %.0fms (atlas + pipelines)", (CFAbsoluteTimeGetCurrent() - t1) * 1000))

        let rect = NSRect(x: 0, y: 0, width: 1440, height: 810)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Pebble"
        window.center()
        gameView = GameView(frame: rect, device: device)
        gameView.appd = self
        gameView.delegate = self
        gameView.colorPixelFormat = .bgra8Unorm
        gameView.depthStencilPixelFormat = .invalid
        gameView.preferredFramesPerSecond = 120
        // capture hooks blit from the drawable, which framebufferOnly forbids
        let env = ProcessInfo.processInfo.environment
        if env["PEBBLE_SHOT"] != nil || env["PEBBLE_PHOTOBOOTH"] != nil {
            gameView.framebufferOnly = false
        }
        window.contentView = gameView
        window.acceptsMouseMovedEvents = true
        window.delegate = self
        // invisible until the fullscreen transition lands — the user never sees
        // the windowed popup or the zoom animation, just a fade-in (the reveal
        // happens in windowDidEnterFullScreen, or after the retry loop gives up)
        window.alphaValue = 0
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(gameView)
        NSApp.activate(ignoringOtherApps: true)
        // launch straight into fullscreen (F11 toggles back). AppKit silently
        // drops toggleFullScreen during the launch transaction, so retry until
        // the window actually transitions.
        window.collectionBehavior.insert(.fullScreenPrimary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.enterFullscreenAtLaunch()
        }

        audio.initEngine()
        audio.applyVolumes(game.settings.volumes)
        audio.onSubtitle = { [weak self] text in
            guard let self, self.game.settings.subtitles else { return }
            self.hud.pushSubtitle(text)
        }

        ui.resize(Double(gameView.drawableSize.width), Double(gameView.drawableSize.height), game.settings.guiScale)

        // settings.resourcePacks holds USER packs only — the default pack
        // (Faithful base layer) is self-healing and force-applied inside
        // applyResourcePacks, so this always runs, even with no user packs.
        // older settings that listed the default explicitly migrate cleanly
        // (withDefaultPack dedupes it to the base slot).
        applyResourcePacks(game.settings.resourcePacks ?? [], game: game, renderer: renderer, ui: ui)

        ui.titlePhoto = renderer.titleBgTex != nil ; ui.titleLogo = renderer.titleLogoTex != nil
        ui.open(TitleScreen(), game)
        // test hook: jump straight to the world list (UI testing)
        if ProcessInfo.processInfo.environment["PEBBLE_WORLDS"] != nil {
            ui.open(WorldSelectScreen(), game)
        }

        // test hook: skip the menus and jump straight into the latest world.
        // PEBBLE_NEWWORLD=<seed> creates a fresh world instead (worldgen testing)
        if ProcessInfo.processInfo.environment["PEBBLE_AUTOLOAD"] != nil {
            if let seedText = ProcessInfo.processInfo.environment["PEBBLE_NEWWORLD"] {
                game.createWorld(name: "WGTest-\(seedText)", seedText: seedText,
                                 mode: GameMode.survival, difficulty: 2)
            } else if let rec = game.listWorlds().sorted(by: { $0.lastPlayed > $1.lastPlayed }).first {
                game.loadWorld(rec.id)
            } else {
                game.createWorld(name: "New World", seedText: "", mode: GameMode.survival, difficulty: 2)
            }
            ui.open(LoadingScreen(), game)
            gameView.captureMouse()
            if ProcessInfo.processInfo.environment["PEBBLE_BOT"] != nil {
                bot = PhysicsBot(game: game)
            }
            if ProcessInfo.processInfo.environment["PEBBLE_PHOTOBOOTH"] != nil {
                booth = PhotoBooth(game: game, renderer: renderer)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if game.hasWorld() { game.saveAndFlush(synchronous: true) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Edit→Paste (Cmd-V): route pasteboard text into the focused screen field
    /// — the UI fields are canvas-drawn, so the standard NSText paste path
    /// never reaches them
    @objc func pasteText(_ sender: Any?) {
        guard let game, let ui, let screen = ui.current(),
              screen.fields.contains(where: { $0.focused }),
              let s = NSPasteboard.general.string(forType: .string) else { return }
        for ch in s where !ch.isNewline && (ch.asciiValue.map { $0 >= 32 } ?? true) {
            _ = screen.onChar(ui, game, String(ch))
        }
    }

    @objc func copyObjectTemplate(_ sender: Any?) {
        _ = gameView.performObjectTemplateShortcut(.copyObject)
    }

    @objc func pasteOrPlaceTemplate(_ sender: Any?) {
        if gameView.performObjectTemplateShortcut(.placeObject) { return }
        pasteText(sender)
    }

    /// AppKit refuses toggleFullScreen while the app is still activating
    /// (windowDidFailToEnterFullScreen fires and the window reverts), so the
    /// launch toggle re-checks until the transition actually completes.
    func windowDidEnterFullScreen(_ notification: Notification) {
        fsEntered = true
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.3
            window?.animator().alphaValue = 1
        }
    }
    private var fsEntered = false
    private var fsChecks = 0
    private func enterFullscreenAtLaunch() {
        guard let w = window, !fsEntered else { return }
        if fsChecks >= 5 {
            w.alphaValue = 1   // fullscreen never engaged: show windowed, don't stay invisible
            return
        }
        fsChecks += 1
        if !w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.enterFullscreenAtLaunch()
        }
    }

    /// Cmd-Tab away: release every held key (keyUps go to the other app),
    /// give the system its cursor back (capture sets GLOBAL state that froze
    /// the cursor system-wide), and auto-pause like vanilla.
    func applicationDidResignActive(_ notification: Notification) {
        game?.clearInput()
        gameView?.releaseMouse()
        if let game, let ui, game.hasWorld(), !ui.hasScreen() {
            ui.open(PauseScreen(), game)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.resize(Int(size.width), Int(size.height))
        ui.resize(Double(size.width), Double(size.height), game.settings.guiScale, relayout: game)
    }

    /// maxFps >= 250 = unlimited: MTKView's display link can't exceed the panel
    /// refresh, so drive draw() from a runloop timer with vsync off instead
    private func applyFpsMode() {
        let unlimited = game.settings.maxFps >= 250
        if unlimited != uncappedMode {
            uncappedMode = unlimited
            (gameView.layer as? CAMetalLayer)?.displaySyncEnabled = !unlimited
            gameView.isPaused = unlimited
            gameView.enableSetNeedsDisplay = false
            uncapTimer?.invalidate()
            uncapTimer = nil
            if unlimited {
                let t = Timer(timeInterval: 0.0001, repeats: true) { [weak self] _ in
                    self?.gameView.draw()
                }
                RunLoop.main.add(t, forMode: .common)
                uncapTimer = t
            }
        }
        if !unlimited {
            gameView.preferredFramesPerSecond = max(30, game.settings.maxFps)
        }
    }

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = (now - lastFrame) * 1000
        lastFrame = now
        let timeSec = (now - startTime).truncatingRemainder(dividingBy: 1800)

        fpsTimer += dt
        fpsCounter += 1
        if fpsTimer >= 1000 {
            fps = fpsCounter
            fpsCounter = 0
            fpsTimer -= 1000
            let n = game.harvestMeshCounter()
            hud.debugInfo["fps"] = String(fps)
            hud.debugInfo["chunkUpdates"] = String(n)
            hud.debugInfo["sections"] = String(renderer.sections.count)
            hud.debugInfo["drawCalls"] = String(renderer.drawCalls)
            hud.debugInfo["mem"] = "n/a"
            audio.applyVolumes(game.settings.volumes)
            applyFpsMode()
            if game.hasWorld(), let p = game.player {
                window.title = String(format: "Pebble — %d fps · %d sections · (%.0f, %.0f, %.0f)",
                                      fps, renderer.sections.count, p.x, p.y, p.z)
            } else {
                window.title = "Pebble"
            }
        }

        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = renderer.queue.makeCommandBuffer() else { return }

        if renderer.fbWidth == 0 {
            renderer.resize(Int(view.drawableSize.width), Int(view.drawableSize.height))
            ui.resize(Double(view.drawableSize.width), Double(view.drawableSize.height), game.settings.guiScale, relayout: game)
        }

        renderer.tickTileAnimations(dtMs: dt)   // resource-pack .mcmeta frames
        renderer.flushAtlasUploads(cmd)         // staged slice blits, GPU-ordered

        if let cmds = pendingCmds, game.hasWorld(), let p = game.player {
            pendingCmdDelay += 1
            if pendingCmdDelay > 90 {
                if p.dead { game.respawnPlayer() }
                for c in cmds.components(separatedBy: ";") where !c.isEmpty {
                    runCommand(game, c.trimmingCharacters(in: .whitespaces))
                }
                pendingCmds = nil
            }
        }
        if let screen = pendingOpenScreen, game.hasWorld(), pendingCmds == nil {
            pendingOpenScreenDelay += 1
            if pendingOpenScreenDelay > 90 {
                switch screen.lowercased() {
                case "creative":
                    game.openScreen("creative", nil)
                case "templates":
                    game.openScreen("templates", nil)
                case "templatesplace", "templates-place":
                    game.openScreen("templatesPlace", nil)
                case "map":
                    game.openScreen("map", nil)
                default:
                    print("[shot] ignored unknown PEBBLE_OPEN_SCREEN=\(screen)")
                    fflush(stdout)
                }
                pendingOpenScreen = nil
            }
        }
        if let shot = pendingShot, game.hasWorld(), pendingCmds == nil, pendingOpenScreen == nil {
            hud.hideGui = true
            pendingShot = (shot.path, shot.frames - 1)
            if shot.frames <= 0 {
                renderer.requestCapture(path: shot.path)
                pendingShot = nil
                hud.hideGui = false
                print("[shot] captured \(shot.path)")
                fflush(stdout)
                // scripted-shot runs quit on their own — leave a beat for the
                // async blit + PNG write to land before terminating
                shotQuitFrames = 120
            }
        }
        if shotQuitFrames > 0 {
            shotQuitFrames -= 1
            if shotQuitFrames == 0 { NSApp.terminate(nil) }
        }

        let enc: MTLRenderCommandEncoder
        if game.hasWorld() {
            let partial = game.frame(dtMs: dt)
            bot?.tick()
            booth?.tickBooth()
            renderer.particles.tick(game.world)
            let cam = game.camState(partial, timeSec: timeSec)
            enc = renderer.render(cmd: cmd, rpd: rpd, game: game, cam: cam, partial: partial, timeSec: timeSec)
        } else {
            enc = renderer.renderTitle(cmd: cmd, rpd: rpd)
        }

        // ---- UI pass ----
        ui.beginFrame()
        let screen = ui.current()
        if game.hasWorld() && (screen == nil || screen!.showHUD || !screen!.pausesGame) {
            hud.draw(ui, game, 0)
            if !(screen is ChatScreen) { drawChatOverlay(ui) }
        }
        screen?.draw(ui, game, 0)
        ui.endFrame()
        ui.cv.flush(enc, pipeline: renderer.uiPipeline)

        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)

// minimal main menu: Cmd-Q quits; Cmd-C/Cmd-V route object templates in
// world mode, while Cmd-V remains Paste for focused UI fields
let mainMenu = NSMenu()
let appItem = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "About Pebble",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(withTitle: "Quit Pebble",
                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
mainMenu.addItem(appItem)
let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Copy Object",
                 action: #selector(AppDelegate.copyObjectTemplate(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste",
                 action: #selector(AppDelegate.pasteOrPlaceTemplate(_:)), keyEquivalent: "v")
editItem.submenu = editMenu
mainMenu.addItem(editItem)
let winItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
let winMenu = NSMenu(title: "Window")
winMenu.addItem(withTitle: "Minimize",
                action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
winItem.submenu = winMenu
mainMenu.addItem(winItem)
app.mainMenu = mainMenu
app.windowsMenu = winMenu

app.run()
