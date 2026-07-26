import Darwin
import AppKit
import CryptoKit
import Foundation
import Metal
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class ResourcePackHardeningTests: XCTestCase {
    private final class SortInteractionHost: GameHost {
        var uiSounds = 0
        func hasScreen() -> Bool { false }; func screenPausesGame() -> Bool { false }
        func openScreen(_ kind: String, _ data: ScreenData?) {}; func openTrading(_ villager: Mob) {}
        func openVehicleChest(_ kind: String, _ vehicle: Entity) {}; func openChat(_ prefix: String) {}
        func openDeathScreen(_ message: String) {}; func openPauseScreen() {}; func openTitleScreen() {}
        func closeAllScreens() {}; func releasePointer() {}; func capturePointer() {}
        func showActionBar(_ text: String, _ time: Int) {}; func pushChat(_ line: String) {}
        func pushToast(_ adv: AdvancementDef) {}; func setBossBars(_ bars: [BossBarInfo]) {}
        func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double, _ volume: Double, _ pitch: Double) {}
        func playUI(_ name: String) { uiSounds += 1 }
        func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
        func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {}
        func tickMusic(_ mood: String, _ enabled: Bool) {}; func stopDisc() {}
        func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double, _ count: Int, _ spread: Double, _ cell: Int) {}
        func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double, _ groundY: Double) {}
        func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {}
        func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {}; func clearAllSections() {}
    }
    private func asymmetricPNG() throws -> Data {
        // Literal PNG scanlines, independent of Core Graphics: authored top is
        // red/green and authored bottom is blue/yellow (PNG filter byte 0).
        try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR42mP4z8DwHwyBNBAw/AcAR8oI+FuapL4AAAAASUVORK5CYII="))
    }

    @MainActor
    func testShowMinimapPreferenceIsKeyboardAndAccessibilityReachable() throws {
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ui = UIManager(cv: UICanvas(device: device))
        ui.resize(480, 270, 1)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-minimap-settings-\(UUID().uuidString).sqlite")
        let settingsDirectory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("elysium-minimap-settings-\(UUID().uuidString)",
                                   isDirectory: true)
        let game = GameCore(
            db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false),
            localSettingsStore: LocalSettingsStore(directoryURL: settingsDirectory))
        defer {
            try? FileManager.default.removeItem(at: databaseURL)
            try? FileManager.default.removeItem(at: settingsDirectory)
        }
        let screen = SettingsScreen()
        ui.open(screen, game)

        let descriptor = try XCTUnwrap(screen.textAccessibilityDescriptors(ui, game)
            .first { $0.id == "video.show-minimap" })
        XCTAssertEqual(descriptor.label, "Show Minimap: ON")
        XCTAssertTrue(descriptor.enabled)
        XCTAssertTrue(descriptor.actionable)

        XCTAssertTrue(screen.focusTextAccessibilityElement("video.fullscreen", ui, game))
        let tab = ElysiumKeyEvent(
            terminal: try XCTUnwrap(ElysiumTerminalKey(rawValue: "Tab")),
            modifiers: [], isRepeat: false, routingSerial: 1)
        XCTAssertTrue(screen.onKeyEvent(ui, game, tab))
        XCTAssertEqual(screen.textAccessibilityDescriptors(ui, game)
            .first(where: { $0.focused })?.id, "video.show-minimap")

        XCTAssertTrue(screen.performTextAccessibilityAction("video.show-minimap", ui, game))
        XCTAssertFalse(game.settings.showMinimap)
        XCTAssertEqual(screen.textAccessibilityDescriptors(ui, game)
            .first(where: { $0.id == "video.show-minimap" })?.label, "Show Minimap: OFF")
    }

    func testDecodePNGNormalizesVisualTopRowOnce() throws {
        let limits = ResourcePackPreparationLimits(
            archiveBytes: 512 << 20, fileBytes: 64 << 20, entries: 100_000,
            pathBytes: 1_024, aggregatePathBytes: 16 << 20,
            advertisedBytes: 512 << 20, inflatedBytes: 512 << 20,
            decodedRGBABytes: 16, metadataBytes: 64 << 10,
            framesPerTexture: 256, framesPerGeneration: 4_096,
            minimumFrameDuration: 1, maximumFrameDuration: 1_200)
        let exactBudget = ResourcePackPreparationBudget(limits: limits)
        let image = decodePNG(try asymmetricPNG(), budget: exactBudget)
        XCTAssertEqual(image?.width, 2)
        XCTAssertEqual(image?.height, 2)
        XCTAssertEqual(image?.pixels, [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 0, 255,
        ], "row zero must be authored red/green top; row one blue/yellow bottom")
        XCTAssertEqual(exactBudget.decodedRGBABytes, 16)

        var shortLimits = limits
        shortLimits.decodedRGBABytes = 15
        XCTAssertNil(decodePNG(try asymmetricPNG(),
                               budget: ResourcePackPreparationBudget(limits: shortLimits)))
        let token = ResourcePackCancellationToken()
        token.cancel()
        XCTAssertNil(decodePNG(try asymmetricPNG(),
                               budget: ResourcePackPreparationBudget(cancellation: token)))

        let alphaPNG = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNwaDjQAAAEhQIBHAk9JgAAAABJRU5ErkJggg=="))
        let alpha = try XCTUnwrap(decodePNG(alphaPNG))
        XCTAssertEqual(alpha.pixels[0], 63, accuracy: 1)
        XCTAssertEqual(alpha.pixels[1], 127, accuracy: 1)
        XCTAssertEqual(alpha.pixels[2], 191, accuracy: 1)
        XCTAssertEqual(alpha.pixels[3], 128)
    }

    func testFaithfulDoubleChestCropKeepsAuthoredSeamColumn() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let archive = repository.appendingPathComponent(
            "packaging/Faithful 64x - December 2025 Release.zip")
        let pack = try XCTUnwrap(ResourcePack(url: archive))
        let image = try XCTUnwrap(cropSemanticChestTile(
            [pack], budget: ResourcePackPreparationBudget()))

        XCTAssertEqual(image.width, 60,
                       "double-chest fronts are fifteen base texels at Faithful's 4x scale")
        XCTAssertEqual(image.height, 180,
                       "single, left, and right semantic pieces must remain equal bands")
    }

    func testPackUIRasterScalePreservesNativeDetailWithBoundedLogicalMapping() throws {
        XCTAssertEqual(PackUI.preferredRasterScale([
            (width: 256, height: 256, logicalSize: 256),
        ]), 1)
        XCTAssertEqual(PackUI.preferredRasterScale([
            (width: 512, height: 512, logicalSize: 256),
            (width: 384, height: 384, logicalSize: 128),
        ]), 3)
        XCTAssertEqual(PackUI.preferredRasterScale([
            (width: 1024, height: 1024, logicalSize: 256),
            (width: 512, height: 512, logicalSize: 128),
        ]), 4, "Faithful 64x GUI and ASCII sources must retain their native 4x raster")
        XCTAssertEqual(PackUI.preferredRasterScale([
            (width: 2048, height: 2048, logicalSize: 256),
        ]), 4, "higher source scales must clamp to the bounded 4x composite")
        XCTAssertEqual(PackUI.preferredRasterScale([
            (width: 1024, height: 512, logicalSize: 256),
            (width: 513, height: 513, logicalSize: 128),
        ]), 1, "non-square and non-integral sources cannot define the composite scale")

        let dimensions = try XCTUnwrap(PackUI.compositeDimensions(rasterScale: 4))
        XCTAssertEqual(dimensions.width, 4096)
        XCTAssertEqual(dimensions.height, 5120)
        XCTAssertEqual(dimensions.width * dimensions.height * 4, 80 << 20)
        XCTAssertNil(PackUI.compositeDimensions(rasterScale: 0))
        XCTAssertNil(PackUI.compositeDimensions(rasterScale: 5))

        XCTAssertEqual(PackUI.CELLS["ascii"]?.0, 512)
        XCTAssertEqual(PackUI.CELLS["ascii"]?.1, 0)
        XCTAssertEqual(PackUI.CELLS["horse"]?.0, 768)
        XCTAssertEqual(PackUI.CELLS["horse"]?.1, 1024)

        let logicalGlyph = UICanvas.guiUVRect(512 + 15 * 8, 15 * 8, 8, 8)
        XCTAssertEqual(logicalGlyph.x, Float((1024.0 + 15 * 16) / 2048.0), accuracy: 0.000_001)
        XCTAssertEqual(logicalGlyph.y, Float((15.0 * 16) / 2560.0), accuracy: 0.000_001)
        XCTAssertEqual(logicalGlyph.z, Float((1024.0 + 16 * 16) / 2048.0), accuracy: 0.000_001)
        XCTAssertEqual(logicalGlyph.w, Float((16.0 * 16) / 2560.0), accuracy: 0.000_001)
    }

    func testRainbowAndHeldOverlayPlansClampAndStayDeterministic() throws {
        XCTAssertEqual(xpRainbowSegments(progress: -1, width: 182), [])
        XCTAssertEqual(xpRainbowSegments(progress: .nan, width: 182), [])
        let full = xpRainbowSegments(progress: 2, width: 182)
        XCTAssertEqual(full.map(\.color),
                       ["#ff4040", "#ff9b32", "#ffe84d", "#6eea58",
                        "#43d6c5", "#3978ff", "#9b70f5"])
        XCTAssertEqual(full.reduce(0) { $0 + $1.width }, 182)
        for boundary in 1...7 {
            let segments = xpRainbowSegments(progress: Double(boundary) / 7, width: 182)
            XCTAssertEqual(segments.count, boundary)
            XCTAssertEqual(segments.reduce(0) { $0 + $1.width },
                           (Double(boundary) * 182 / 7).rounded(), accuracy: 0.001)
        }

        XCTAssertNil(heldOverlayPlan(viewWidth: 159, viewHeight: 120,
                                     guiVisible: true, firstPerson: true, screenOpen: false,
                                     attack: 1, usingItem: false, useTicks: 0))
        XCTAssertNil(heldOverlayPlan(viewWidth: 160, viewHeight: 119,
                                     guiVisible: true, firstPerson: true, screenOpen: false,
                                     attack: 1, usingItem: false, useTicks: 0))
        for dimension in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertNil(heldOverlayPlan(viewWidth: dimension, viewHeight: 180,
                                         guiVisible: true, firstPerson: true, screenOpen: false,
                                         attack: 1, usingItem: false, useTicks: 0))
            XCTAssertNil(heldOverlayPlan(viewWidth: 320, viewHeight: dimension,
                                         guiVisible: true, firstPerson: true, screenOpen: false,
                                         attack: 1, usingItem: false, useTicks: 0))
        }
        XCTAssertNil(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                     guiVisible: false,
                                     firstPerson: true, screenOpen: false,
                                     attack: 1, usingItem: true, useTicks: 30))
        XCTAssertNil(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                     guiVisible: true,
                                     firstPerson: false, screenOpen: false,
                                     attack: 1, usingItem: true, useTicks: 30))
        XCTAssertNil(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                     guiVisible: true,
                                     firstPerson: true, screenOpen: true,
                                     attack: 1, usingItem: true, useTicks: 30))
        let idle = try XCTUnwrap(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                   guiVisible: true,
                                   firstPerson: true, screenOpen: false,
                                   attack: 1, usingItem: false, useTicks: 0))
        let midAttack = try XCTUnwrap(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                                        guiVisible: true, firstPerson: true, screenOpen: false,
                                                        attack: 0.5, usingItem: false, useTicks: 0))
        let returned = try XCTUnwrap(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                                      guiVisible: true, firstPerson: true, screenOpen: false,
                                                      attack: 0, usingItem: false, useTicks: 0))
        let use = try XCTUnwrap(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                  guiVisible: true,
                                  firstPerson: true, screenOpen: false,
                                  attack: 1, usingItem: true, useTicks: 6))
        XCTAssertEqual(idle, heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                              guiVisible: true,
                                              firstPerson: true, screenOpen: false,
                                              attack: 1, usingItem: false, useTicks: 0))
        XCTAssertEqual(idle.armX, returned.armX, accuracy: 0.0001)
        XCTAssertEqual(idle.armY, returned.armY, accuracy: 0.0001)
        XCTAssertEqual(idle.rotation, returned.rotation, accuracy: 0.0001)
        XCTAssertEqual(idle.armBaseX, 320, accuracy: 0.0001)
        XCTAssertEqual(idle.armBaseY, 180, accuracy: 0.0001)
        XCTAssertEqual(idle.iconSize, 48, accuracy: 0.0001)
        XCTAssertEqual(idle.armX - idle.iconX, idle.iconSize * 0.25, accuracy: 0.0001)
        XCTAssertEqual(idle.armY - idle.iconY, idle.iconSize * 0.83, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(hypot(midAttack.armX - idle.armX, midAttack.armY - idle.armY), 24)
        XCTAssertGreaterThanOrEqual(abs(midAttack.rotation - idle.rotation), 0.55)
        XCTAssertGreaterThanOrEqual(hypot(use.armX - midAttack.armX, use.armY - midAttack.armY), 12)
        XCTAssertGreaterThanOrEqual(abs(use.rotation - midAttack.rotation), 0.35)
        XCTAssertGreaterThanOrEqual(hypot(use.armX - idle.armX, use.armY - idle.armY), 12)
        XCTAssertGreaterThanOrEqual(abs(use.rotation - idle.rotation), 0.25)
        for (width, height) in [(160.0, 120.0), (320.0, 180.0), (480.0, 270.0)] {
            for sample in [(1.0, false, 0), (0.5, false, 0), (0.0, false, 0), (1.0, true, 6)] {
                let candidate = try XCTUnwrap(heldOverlayPlan(
                    viewWidth: width, viewHeight: height, guiVisible: true, firstPerson: true,
                    screenOpen: false, attack: sample.0, usingItem: sample.1, useTicks: sample.2),
                    "missing plan for \(width)x\(height) sample \(sample)")
                XCTAssertGreaterThanOrEqual(candidate.minX, 0)
                XCTAssertGreaterThanOrEqual(candidate.minY, 0)
                XCTAssertLessThanOrEqual(candidate.maxX, width)
                XCTAssertLessThanOrEqual(candidate.maxY, height)
                XCTAssertFalse(candidate.maxX > width / 2 - 24 && candidate.minX < width / 2 + 24 &&
                               candidate.maxY > height / 2 - 24 && candidate.minY < height / 2 + 24)
                XCTAssertEqual(candidate.armBaseY, height, accuracy: 0.001)
                XCTAssertGreaterThanOrEqual(candidate.iconSize, 34)
            }
        }
        XCTAssertNotNil(heldOverlayPlan(viewWidth: 160, viewHeight: 120,
                                        guiVisible: true, firstPerson: true, screenOpen: false,
                                        attack: .nan, usingItem: false, useTicks: 0,
                                        hasHeldItem: false))
        let minimap = mapMinimapRect(screenWidth: 776, screenHeight: 475,
                                     hotbarCenterX: 388, hotbarHalfWidth: 91,
                                     hotbarTopY: 453)
        let unobscured = try XCTUnwrap(heldOverlayPlan(
            viewWidth: 776, viewHeight: 475, guiVisible: true, firstPerson: true,
            screenOpen: false, attack: 1, usingItem: false, useTicks: 0,
            rightObstruction: minimap))
        XCTAssertTrue(unobscured.maxX <= minimap.x || unobscured.minX >= minimap.x + minimap.size ||
                      unobscured.maxY <= minimap.y || unobscured.minY >= minimap.y + minimap.size)
        XCTAssertEqual(unobscured.armBaseX, minimap.x - 4, accuracy: 0.001)
        XCTAssertEqual(unobscured.armBaseY, 475, accuracy: 0.001)
    }

    func testContainerSortLayoutAndCommitGuards() throws {
        let normal = containerSortPlacement(viewWidth: 480, viewHeight: 270, panelWidth: 176, panelHeight: 166)
        let normalButton = try XCTUnwrap(normal.button)
        let normalHint = try XCTUnwrap(normal.hint)
        XCTAssertEqual(normalButton.w, 68); XCTAssertEqual(normalButton.h, 20)
        XCTAssertEqual(normalHint.w, 32); XCTAssertEqual(normalHint.h, 20)
        XCTAssertTrue(normalButton.inside(480, 270, margin: 4))
        XCTAssertTrue(normalHint.inside(480, 270, margin: 4))
        XCTAssertFalse(normalButton.intersects(ContainerSortRect(x: normal.panelX, y: normal.panelY, w: 176, h: 166)))
        XCTAssertFalse(normalHint.intersects(ContainerSortRect(x: normal.panelX, y: normal.panelY, w: 176, h: 166)))
        let narrow = containerSortPlacement(viewWidth: 380, viewHeight: 240, panelWidth: 176, panelHeight: 222)
        XCTAssertNotNil(narrow.button); XCTAssertNil(narrow.hint)
        let rail = containerSortPlacement(viewWidth: 256, viewHeight: 270, panelWidth: 176, panelHeight: 166)
        XCTAssertEqual(rail.panelX, 76); XCTAssertEqual(rail.button?.x, 4); XCTAssertNil(rail.hint)
        let top = containerSortPlacement(viewWidth: 255, viewHeight: 194, panelWidth: 176, panelHeight: 166)
        XCTAssertEqual(top.panelY, 28); XCTAssertEqual(top.button?.y, 4)
        let unsupported = containerSortPlacement(viewWidth: 255, viewHeight: 193, panelWidth: 176, panelHeight: 166)
        XCTAssertFalse(unsupported.supported); XCTAssertNil(unsupported.button); XCTAssertNil(unsupported.hint)

        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        let stone = try XCTUnwrap(iidOpt("stone"))
        var exact36 = Array(repeating: ItemStack?(nil), count: 36)
        exact36[0] = ItemStack(stone, 1)
        XCTAssertTrue(commitPlayerInventorySort(&exact36))
        var invalidPlayer = exact36
        invalidPlayer[0] = ItemStack(-1, 1)
        let invalidReference = invalidPlayer[0]
        XCTAssertFalse(commitPlayerInventorySort(&invalidPlayer))
        XCTAssertTrue(invalidPlayer[0] === invalidReference)
        var wrongCount = Array(repeating: ItemStack?(nil), count: 35)
        XCTAssertFalse(commitPlayerInventorySort(&wrongCount))

        var gets = 0, writes = 0
        let invalid: [ItemStack?] = [ItemStack(-1, 1)]
        XCTAssertFalse(commitContainerSort(readOnly: false, isLANClientWorld: true, slotCount: 1,
                                           snapshot: { gets += 1; return invalid }, set: { _, _ in writes += 1 }))
        XCTAssertEqual(gets, 0); XCTAssertEqual(writes, 0)
        XCTAssertFalse(commitContainerSort(readOnly: true, isLANClientWorld: false, slotCount: 1,
                                           snapshot: { gets += 1; return invalid }, set: { _, _ in writes += 1 }))
        XCTAssertEqual(gets, 0); XCTAssertEqual(writes, 0)
        XCTAssertFalse(commitContainerSort(readOnly: false, isLANClientWorld: false, slotCount: 1,
                                           snapshot: { gets += 1; return invalid }, set: { _, _ in writes += 1 }))
        XCTAssertEqual(gets, 1); XCTAssertEqual(writes, 0)

        let apple = try XCTUnwrap(iidOpt("apple"))
        var local: [ItemStack?] = [ItemStack(stone, 1), ItemStack(apple, 2), nil]
        var localWrites = 0
        XCTAssertTrue(commitContainerSort(readOnly: false, isLANClientWorld: false, slotCount: 3,
                                          snapshot: { local }, set: { index, stack in
                                              localWrites += 1; local[index] = stack
                                          }))
        XCTAssertEqual(localWrites, 3)
        XCTAssertEqual(local[0]?.id, apple)
        XCTAssertEqual(local[1]?.id, stone)
        XCTAssertNil(local[2])
        localWrites = 0
        XCTAssertFalse(commitContainerSort(readOnly: false, isLANClientWorld: false, slotCount: 2,
                                           snapshot: { local }, set: { _, _ in localWrites += 1 }))
        XCTAssertEqual(localWrites, 0)
    }

    func testSortPointerBoundaryAndPairedContainerCommit() throws {
        let frame = ContainerSortRect(x: 10, y: 20, w: 68, h: 20)
        func pointer(_ type: NSEvent.EventType, _ button: Int, _ appKitButton: Int) -> ScreenPointerEvent {
            ScreenPointerEvent(eventType: type, button: button, appKitButtonNumber: appKitButton,
                               clickCount: 1, windowNumber: 1, eventNumber: 1, modifierFlags: [])
        }
        XCTAssertEqual(containerSortPointerRoute(frame: frame, x: 12, y: 22,
                                                 event: pointer(.leftMouseDown, 0, 0)), .delegatePrimary)
        XCTAssertEqual(containerSortPointerRoute(frame: frame, x: 12, y: 22,
                                                 event: pointer(.rightMouseDown, 2, 1)), .consume)
        XCTAssertEqual(containerSortPointerRoute(frame: frame, x: 12, y: 22,
                                                 event: pointer(.otherMouseDown, 1, 2)), .consume)
        XCTAssertEqual(containerSortPointerRoute(frame: frame, x: 9, y: 22,
                                                 event: pointer(.leftMouseDown, 0, 0)), .miss)

        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        let stone = try XCTUnwrap(iidOpt("stone"))
        let apple = try XCTUnwrap(iidOpt("apple"))
        var firstHalf: [ItemStack?] = [ItemStack(stone, 1), nil]
        var secondHalf: [ItemStack?] = [ItemStack(apple, 2), nil]
        let playerRows: [ItemStack?] = [ItemStack(stone, 9)]
        var writes = 0
        XCTAssertTrue(commitContainerSort(readOnly: false, isLANClientWorld: false, slotCount: 4,
                                          snapshot: { firstHalf + secondHalf }, set: { index, stack in
                                              writes += 1
                                              if index < 2 { firstHalf[index] = stack } else { secondHalf[index - 2] = stack }
                                          }))
        XCTAssertEqual(writes, 4)
        XCTAssertEqual(firstHalf[0]?.id, apple, "paired halves sort as one logical region")
        XCTAssertEqual(firstHalf[1]?.id, stone)
        XCTAssertNil(secondHalf[0]); XCTAssertNil(secondHalf[1])
        XCTAssertEqual(playerRows[0]?.count, 9, "displayed player rows are excluded")

        secondHalf = [ItemStack(-1, 1), nil]
        writes = 0
        XCTAssertFalse(commitContainerSort(readOnly: false, isLANClientWorld: false, slotCount: 4,
                                           snapshot: { firstHalf + secondHalf }, set: { _, _ in writes += 1 }))
        XCTAssertEqual(writes, 0, "an invalid stack in the paired second half rejects before writes")
    }

    func testInventoryScreenSortRoutesPointerKeyAndAccessibility() throws {
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ui = UIManager(cv: UICanvas(device: device))
        ui.resize(480, 270, 1)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-sort-ui-\(UUID().uuidString).sqlite")
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        let world = World(dim: .overworld, seed: 91)
        game.player = Player(world: world)
        let apple = try XCTUnwrap(iidOpt("apple")), stone = try XCTUnwrap(iidOpt("stone"))
        game.player.inventory[0] = ItemStack(stone, 1)
        game.player.inventory[1] = ItemStack(apple, 1)
        game.player.selectedSlot = 5
        game.player.xp = 37; game.player.xpLevel = 4; game.player.xpProgress = 0.25
        game.player.armor[0] = ItemStack(stone, 7)
        game.player.offHand = ItemStack(stone, 8)
        let host = SortInteractionHost(); game.host = host
        let screen = InventoryScreen(); screen.craftGrid[0] = ItemStack(stone, 6); screen.craftResult = ItemStack(apple, 4)
        ui.cursorStack = ItemStack(stone, 3)
        ui.open(screen, game)
        let descriptor = try XCTUnwrap(screen.textAccessibilityDescriptors(ui, game).first { $0.id == "inventory.sort" })
        func pointer(_ type: NSEvent.EventType, _ button: Int, _ appKitButton: Int) -> ScreenPointerEvent {
            ScreenPointerEvent(eventType: type, button: button, appKitButtonNumber: appKitButton,
                               clickCount: 1, windowNumber: 1, eventNumber: 17, modifierFlags: [])
        }
        XCTAssertTrue(screen.onPointerDown(ui, game, descriptor.frame.x + 1, descriptor.frame.y + 1,
                                           pointer(.leftMouseDown, 0, 0)))
        XCTAssertEqual(game.player.inventory[0]?.id, apple); XCTAssertEqual(host.uiSounds, 1)
        XCTAssertEqual(game.player.armor[0]?.count, 7); XCTAssertEqual(game.player.offHand?.count, 8)
        XCTAssertEqual(screen.craftGrid[0]?.count, 6); XCTAssertEqual(screen.craftResult?.count, 4)
        XCTAssertEqual(ui.cursorStack?.count, 3); XCTAssertEqual(game.player.selectedSlot, 5)
        XCTAssertEqual(game.player.xp, 37); XCTAssertEqual(game.player.xpLevel, 4); XCTAssertEqual(game.player.xpProgress, 0.25)
        let sorted = game.player.inventory
        XCTAssertTrue(screen.onPointerDown(ui, game, descriptor.frame.x + 1, descriptor.frame.y + 1,
                                           pointer(.rightMouseDown, 2, 1)))
        XCTAssertTrue(screen.onPointerDown(ui, game, descriptor.frame.x + 1, descriptor.frame.y + 1,
                                           pointer(.otherMouseDown, 1, 2)))
        XCTAssertEqual(game.player.inventory.map { $0?.id }, sorted.map { $0?.id }); XCTAssertEqual(host.uiSounds, 1)
        game.player.inventory.swapAt(0, 1)
        let commandS = ElysiumKeyEvent(terminal: try XCTUnwrap(ElysiumTerminalKey(rawValue: "KeyS")),
                                       modifiers: [.command], isRepeat: false, routingSerial: 1)
        XCTAssertTrue(screen.onKeyEvent(ui, game, commandS)); XCTAssertEqual(game.player.inventory[0]?.id, apple)
        XCTAssertEqual(host.uiSounds, 1)
        game.player.inventory.swapAt(0, 1)
        XCTAssertFalse(screen.onKeyEvent(ui, game, ElysiumKeyEvent(terminal: try XCTUnwrap(ElysiumTerminalKey(rawValue: "KeyS")), modifiers: [.command, .shift], isRepeat: false, routingSerial: 2)))
        XCTAssertFalse(screen.onKeyEvent(ui, game, ElysiumKeyEvent(terminal: try XCTUnwrap(ElysiumTerminalKey(rawValue: "KeyS")), modifiers: [.command], isRepeat: true, routingSerial: 3)))
        XCTAssertEqual(game.player.inventory[0]?.id, stone)
        let textOwner = TextField(0, 0, 20, 10)
        textOwner.focused = true; screen.fields.append(textOwner)
        XCTAssertFalse(screen.onKeyEvent(ui, game, commandS))
        XCTAssertEqual(game.player.inventory[0]?.id, stone, "text ownership keeps Command-S out of sorting")
        screen.fields.removeAll()
        XCTAssertTrue(screen.focusTextAccessibilityElement("inventory.sort", ui, game))
        XCTAssertTrue(screen.performTextAccessibilityAction("inventory.sort", ui, game))
        XCTAssertEqual(game.player.inventory[0]?.id, apple); XCTAssertEqual(host.uiSounds, 1)
        screen.readOnlySlots = true
        game.player.inventory.swapAt(0, 1)
        XCTAssertTrue(screen.onPointerDown(ui, game, descriptor.frame.x + 1, descriptor.frame.y + 1,
                                           pointer(.leftMouseDown, 0, 0)))
        XCTAssertFalse(screen.focusTextAccessibilityElement("inventory.sort", ui, game))
        XCTAssertFalse(screen.performTextAccessibilityAction("inventory.sort", ui, game))
        XCTAssertEqual(game.player.inventory[0]?.id, stone); XCTAssertEqual(host.uiSounds, 1)
    }

    @MainActor
    func testLANClientChestScreenSortRoutesAreSilentNoOps() throws {
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ui = UIManager(cv: UICanvas(device: device)); ui.resize(480, 270, 1)
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-lan-chest-sort-\(UUID().uuidString).sqlite")
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        defer { try? FileManager.default.removeItem(at: databaseURL) }
        game.enterLANClientWorld(LANWorldSummary(worldID: "sort-host", worldName: "Sort Host", seed: 97,
                                                  gameMode: GameMode.survival, difficulty: 2,
                                                  dimension: Dim.overworld.rawValue, playerCount: 2))
        let host = SortInteractionHost(); game.host = host
        var captures = 0; game.lanContainerEditHandler = { _ in captures += 1 }
        let stone = try XCTUnwrap(iidOpt("stone")), apple = try XCTUnwrap(iidOpt("apple"))
        let chest = makeContainerBE(2, 64, 2, 27)
        let stoneStack = ItemStack(stone, 1), appleStack = ItemStack(apple, 2)
        chest.items?[0] = stoneStack; chest.items?[1] = appleStack
        let screen = ChestScreen(chest, "Chest"); ui.open(screen, game)
        let descriptor = try XCTUnwrap(screen.textAccessibilityDescriptors(ui, game).first { $0.id == "chest.sort" })
        XCTAssertFalse(descriptor.enabled); XCTAssertFalse(descriptor.actionable)
        XCTAssertTrue(descriptor.help.contains("Sorting is available to the host"))
        func pointer(_ type: NSEvent.EventType, _ button: Int, _ appKitButton: Int) -> ScreenPointerEvent {
            ScreenPointerEvent(eventType: type, button: button, appKitButtonNumber: appKitButton,
                               clickCount: 1, windowNumber: 1, eventNumber: 22, modifierFlags: [])
        }
        for event in [pointer(.leftMouseDown, 0, 0), pointer(.rightMouseDown, 2, 1), pointer(.otherMouseDown, 1, 2)] {
            XCTAssertTrue(screen.onPointerDown(ui, game, descriptor.frame.x + 1, descriptor.frame.y + 1, event))
        }
        let keyS = try XCTUnwrap(ElysiumTerminalKey(rawValue: "KeyS"))
        XCTAssertTrue(screen.onKeyEvent(ui, game, ElysiumKeyEvent(terminal: keyS, modifiers: [.command], isRepeat: false, routingSerial: 21)))
        XCTAssertFalse(screen.onKeyEvent(ui, game, ElysiumKeyEvent(terminal: keyS, modifiers: [.command, .shift], isRepeat: false, routingSerial: 22)))
        XCTAssertFalse(screen.onKeyEvent(ui, game, ElysiumKeyEvent(terminal: keyS, modifiers: [.command], isRepeat: true, routingSerial: 23)))
        XCTAssertFalse(screen.focusTextAccessibilityElement("chest.sort", ui, game))
        XCTAssertFalse(screen.performTextAccessibilityAction("chest.sort", ui, game))
        XCTAssertTrue(chest.items?[0] === stoneStack); XCTAssertTrue(chest.items?[1] === appleStack)
        XCTAssertEqual(host.uiSounds, 0); XCTAssertEqual(captures, 0)
    }

    func testTemplateDeleteRequestCapturesNormalizedNameAndClaimsOnce() throws {
        var request = try XCTUnwrap(TemplateDeleteConfirmationRequest(rawName: "  Mixed  Name  "))
        XCTAssertEqual(request.displayName, "  Mixed  Name  ")
        XCTAssertEqual(request.storageKey, "mixed name")
        XCTAssertFalse(request.claimed)
        XCTAssertEqual(request.claim(), "mixed name")
        XCTAssertTrue(request.claimed)
        XCTAssertNil(request.claim(), "one confirmation cannot execute twice")
        XCTAssertNil(TemplateDeleteConfirmationRequest(rawName: "../not-a-template"))
    }
    /// Test-only AppKit interaction host. It deliberately reuses the two closed production IDs
    /// with a synthetic shared conflict group, so no conflicting descriptor or fault selector is
    /// introduced into Elysium.app. Settings/live tokens are spies for forbidden side effects.
    private struct SyntheticConflictHost {
        let interaction = ResourcePackScreenInteraction(catalog: [
            .init(id: .oreBorders64x, displayName: "Synthetic Ore", conflictGroup: "fixture"),
            .init(id: .staticLanterns, displayName: "Synthetic Lantern", conflictGroup: "fixture"),
        ])
        var selected: [BundledResourcePackAddOnID] = [.oreBorders64x]
        var settingsToken = 41
        var liveGenerationToken = 73
        var focused = BundledResourcePackAddOnID.staticLanterns
        var status: String?

        mutating func activateFocused() {
            switch interaction.evaluateToggle(selected: selected, requested: focused) {
            case .conflict(let requested, let active):
                status = "Cannot enable \(requested) while \(active) is active."
            case .ready(let candidate):
                selected = candidate
                settingsToken += 1
                liveGenerationToken += 1
            case .invalid:
                status = "Resource pack choice was not changed."
            }
        }

        mutating func consumeStatusAnnouncement() -> String? {
            defer { status = nil }
            return status
        }
    }

    private struct FixtureEntry {
        var name: String
        var bytes: Data
        var localName: String? = nil
        var flags: UInt16 = 0
        var method: UInt16 = 0
        var crcOverride: UInt32? = nil
        var externalAttributes: UInt32 = UInt32(S_IFREG | 0o600) << 16
        var centralExtra = Data()
        var localExtra = Data()
    }

    private func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8))
    }

    private func append32(_ value: UInt32, to data: inout Data) {
        append16(UInt16(value & 0xffff), to: &data)
        append16(UInt16(value >> 16), to: &data)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320) }
        }
        return crc ^ 0xffff_ffff
    }

    private func zip(_ rows: [FixtureEntry], disk: UInt16 = 0) -> Data {
        var body = Data()
        var centralRows: [(FixtureEntry, UInt32, UInt32)] = []
        for row in rows {
            let offset = UInt32(body.count)
            let payloadCRC = row.crcOverride ?? crc32(row.bytes)
            let localName = Data((row.localName ?? row.name).utf8)
            append32(0x04034b50, to: &body)
            append16(20, to: &body); append16(row.flags, to: &body)
            append16(row.method, to: &body); append16(0, to: &body); append16(0, to: &body)
            append32(payloadCRC, to: &body)
            append32(UInt32(row.bytes.count), to: &body); append32(UInt32(row.bytes.count), to: &body)
            append16(UInt16(localName.count), to: &body); append16(UInt16(row.localExtra.count), to: &body)
            body.append(localName); body.append(row.localExtra); body.append(row.bytes)
            centralRows.append((row, offset, payloadCRC))
        }
        let centralStart = UInt32(body.count)
        var central = Data()
        for (row, offset, payloadCRC) in centralRows {
            let name = Data(row.name.utf8)
            append32(0x02014b50, to: &central)
            append16(UInt16((3 << 8) | 20), to: &central); append16(20, to: &central)
            append16(row.flags, to: &central); append16(row.method, to: &central)
            append16(0, to: &central); append16(0, to: &central); append32(payloadCRC, to: &central)
            append32(UInt32(row.bytes.count), to: &central); append32(UInt32(row.bytes.count), to: &central)
            append16(UInt16(name.count), to: &central); append16(UInt16(row.centralExtra.count), to: &central)
            append16(0, to: &central); append16(0, to: &central); append16(0, to: &central)
            append32(row.externalAttributes, to: &central); append32(offset, to: &central)
            central.append(name); central.append(row.centralExtra)
        }
        body.append(central)
        append32(0x06054b50, to: &body)
        append16(disk, to: &body); append16(disk, to: &body)
        append16(UInt16(rows.count), to: &body); append16(UInt16(rows.count), to: &body)
        append32(UInt32(central.count), to: &body); append32(centralStart, to: &body)
        append16(0, to: &body)
        return body
    }

    private func limits(path: Int = 1_024, aggregatePath: Int = 16 << 20,
                        advertised: Int = 512 << 20, inflated: Int = 512 << 20,
                        entries: Int = 100_000) -> ResourcePackPreparationLimits {
        var value = ResourcePackPreparationLimits.production
        value.pathBytes = path
        value.aggregatePathBytes = aggregatePath
        value.advertisedBytes = advertised
        value.inflatedBytes = inflated
        value.entries = entries
        return value
    }

    func testExactAndPlusOnePathAndByteBudgets() {
        let exactPath = zip([FixtureEntry(name: "12345678", bytes: Data([1, 2, 3, 4]))])
        XCTAssertNotNil(MiniZip(data: exactPath,
            budget: ResourcePackPreparationBudget(limits: limits(path: 8, aggregatePath: 8,
                                                                   advertised: 4, inflated: 4))))
        XCTAssertNil(MiniZip(data: exactPath,
            budget: ResourcePackPreparationBudget(limits: limits(path: 7, aggregatePath: 8,
                                                                   advertised: 4, inflated: 4))))
        XCTAssertNil(MiniZip(data: exactPath,
            budget: ResourcePackPreparationBudget(limits: limits(path: 8, aggregatePath: 7,
                                                                   advertised: 4, inflated: 4))))
        XCTAssertNil(MiniZip(data: exactPath,
            budget: ResourcePackPreparationBudget(limits: limits(path: 8, aggregatePath: 8,
                                                                   advertised: 3, inflated: 4))))
        XCTAssertNil(MiniZip(data: exactPath,
            budget: ResourcePackPreparationBudget(limits: limits(path: 8, aggregatePath: 8,
                                                                   advertised: 4, inflated: 3))))
    }

    func testCompleteStackAggregateAndDecodedMetadataAnimationBoundaries() {
        let first = zip([FixtureEntry(name: "aaaa", bytes: Data([1, 2, 3, 4]))])
        let second = zip([FixtureEntry(name: "bbbb", bytes: Data([5, 6, 7, 8]))])
        let exact = ResourcePackPreparationBudget(
            limits: limits(path: 4, aggregatePath: 8, advertised: 8, inflated: 8, entries: 2))
        XCTAssertNotNil(MiniZip(data: first, budget: exact))
        XCTAssertNotNil(MiniZip(data: second, budget: exact))
        XCTAssertEqual(exact.pathBytes, 8)
        XCTAssertEqual(exact.advertisedBytes, 8)
        XCTAssertEqual(exact.inflatedBytes, 8)

        let plusOne = ResourcePackPreparationBudget(
            limits: limits(path: 4, aggregatePath: 7, advertised: 8, inflated: 8, entries: 2))
        XCTAssertNotNil(MiniZip(data: first, budget: plusOne))
        XCTAssertNil(MiniZip(data: second, budget: plusOne))

        var tiny = ResourcePackPreparationLimits.production
        tiny.decodedRGBABytes = 16
        tiny.metadataBytes = 4
        tiny.framesPerTexture = 2
        tiny.framesPerGeneration = 2
        tiny.minimumFrameDuration = 1
        tiny.maximumFrameDuration = 3
        let work = ResourcePackPreparationBudget(limits: tiny)
        XCTAssertTrue(work.chargeDecodedRGBA(width: 2, height: 2))
        XCTAssertTrue(work.chargeMetadata(4))
        XCTAssertTrue(work.chargeAnimationFrames(2))
        XCTAssertTrue(work.validDuration(1))
        XCTAssertTrue(work.validDuration(3))
        XCTAssertFalse(work.chargeDecodedRGBA(width: 1, height: 1))

        let durationUnder = ResourcePackPreparationBudget(limits: tiny)
        XCTAssertFalse(durationUnder.validDuration(0))
        let durationOver = ResourcePackPreparationBudget(limits: tiny)
        XCTAssertFalse(durationOver.validDuration(4))
        let framesOver = ResourcePackPreparationBudget(limits: tiny)
        XCTAssertFalse(framesOver.chargeAnimationFrames(3))
        let metadataOver = ResourcePackPreparationBudget(limits: tiny)
        XCTAssertFalse(metadataOver.chargeMetadata(5))
    }

    func testAmbiguousAndUnsupportedArchivesFailClosed() {
        XCTAssertNil(MiniZip(data: zip([
            FixtureEntry(name: "A.png", bytes: Data([1])),
            FixtureEntry(name: "a.PNG", bytes: Data([2]))
        ])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "../a", bytes: Data())])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a\\b", bytes: Data())])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data([1]),
                                                    localName: "b")])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data([1]),
                                                    flags: 1)])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data([1]),
                                                    method: 99)])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data([1]),
                                                    crcOverride: 0)])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data(),
                                                    externalAttributes: UInt32(S_IFLNK | 0o777) << 16)])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data(),
                                                    centralExtra: Data([1, 0, 0, 0]))])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data())], disk: 1)))
    }

    func testCancellationRejectsPreparationBeforeAllocation() {
        let token = ResourcePackCancellationToken()
        token.cancel()
        let budget = ResourcePackPreparationBudget(cancellation: token)
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data([1]))]),
                             budget: budget))
        XCTAssertFalse(budget.shouldContinue)
    }

    func testFolderSnapshotRejectsSymlinkHardlinkAndAcceptsExactRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-pack-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = root.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try Data(#"{"pack":{"pack_format":75,"description":"fixture"}}"#.utf8)
            .write(to: valid.appendingPathComponent("pack.mcmeta"))
        XCTAssertNotNil(ResourcePack(url: valid))

        let symlinked = root.appendingPathComponent("symlinked", isDirectory: true)
        try FileManager.default.copyItem(at: valid, to: symlinked)
        try FileManager.default.createSymbolicLink(
            at: symlinked.appendingPathComponent("escape.png"),
            withDestinationURL: valid.appendingPathComponent("pack.mcmeta"))
        XCTAssertNil(ResourcePack(url: symlinked))

        let hardlinked = root.appendingPathComponent("hardlinked", isDirectory: true)
        try FileManager.default.createDirectory(at: hardlinked, withIntermediateDirectories: true)
        XCTAssertEqual(link(valid.appendingPathComponent("pack.mcmeta").path,
                            hardlinked.appendingPathComponent("pack.mcmeta").path), 0)
        XCTAssertNil(ResourcePack(url: hardlinked))
    }

    func testReviewedArchivesMatchHashesAndParseAsOneBoundedStack() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let budget = ResourcePackPreparationBudget()
        var parsed: [ResourcePack] = []
        for asset in BUNDLED_RESOURCE_PACK_ASSETS {
            let bytes = try Data(contentsOf: repository.appendingPathComponent("packaging")
                .appendingPathComponent(asset.fileName))
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, asset.sha256, asset.fileName)
            let pack = try XCTUnwrap(ResourcePack(data: bytes, fileName: asset.fileName,
                                                  budget: budget), asset.fileName)
            for path in asset.requiredPaths { XCTAssertNotNil(pack.file(path), "\(asset.fileName): \(path)") }
            parsed.append(pack)
        }
        XCTAssertEqual(parsed.count, 3)
        XCTAssertNotNil(buildPackAtlas(packs: parsed, budget: budget))
        XCTAssertTrue(budget.isValid)
        XCTAssertLessThanOrEqual(budget.pathBytes, budget.limits.aggregatePathBytes)
        XCTAssertLessThanOrEqual(budget.inflatedBytes, budget.limits.inflatedBytes)
    }

    func testShippedCatalogDefaultsOffAndSupportsIndependentAndCombinedSelection() {
        let interaction = ResourcePackScreenInteraction()
        var selected: [BundledResourcePackAddOnID] = []
        let shippedGroups = BUNDLED_RESOURCE_PACK_ADD_ONS.compactMap(\.conflictGroup)
        XCTAssertEqual(shippedGroups.count, Set(shippedGroups).count,
                       "the shipped catalog must contain no active conflict pair")
        XCTAssertEqual(selected, [], "the optional catalog must begin OFF")

        guard case .ready(let oreOnly) = interaction.evaluateToggle(
            selected: selected, requested: .oreBorders64x) else {
            return XCTFail("Ore Borders must toggle independently")
        }
        selected = oreOnly
        XCTAssertEqual(selected, [.oreBorders64x])

        guard case .ready(let both) = interaction.evaluateToggle(
            selected: selected, requested: .staticLanterns) else {
            return XCTFail("the two shipped add-ons must be independently compatible")
        }
        selected = both
        XCTAssertEqual(selected, [.oreBorders64x, .staticLanterns])

        guard case .ready(let lanternOnly) = interaction.evaluateToggle(
            selected: selected, requested: .oreBorders64x) else {
            return XCTFail("Ore Borders must toggle back OFF without changing Static Lanterns")
        }
        XCTAssertEqual(lanternOnly, [.staticLanterns])
    }

    @MainActor
    func testPresentationNoticeIsFallbackOnlySerialAwareAndOneShot() {
        let original = RESOURCE_PACK_PRESENTATION
        defer { RESOURCE_PACK_PRESENTATION = original }
        let approved = "Faithful 64x is unavailable; built-in fallback active."

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 0, pendingNotice: approved)
        XCTAssertNil(consumeResourcePackPresentationNotice())

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .faithful64x(activeAddOns: []), noticeSerial: 41_000,
            pendingNotice: approved)
        XCTAssertNil(consumeResourcePackPresentationNotice())

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 41_000, pendingNotice: approved)
        XCTAssertEqual(consumeResourcePackPresentationNotice(), approved)
        XCTAssertNil(consumeResourcePackPresentationNotice(), "one serial announces once")

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .faithful64x(activeAddOns: [.oreBorders64x]),
            noticeSerial: 41_000)
        XCTAssertNil(consumeResourcePackPresentationNotice())

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 41_001, pendingNotice: "later fallback")
        XCTAssertNil(consumeResourcePackPresentationNotice())
        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 41_001, pendingNotice: approved)
        XCTAssertEqual(consumeResourcePackPresentationNotice(), approved,
                       "a rejected message must not consume the serial")
        XCTAssertNil(consumeResourcePackPresentationNotice())

        for serial in [UInt64.max, 1, 2] {
            RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
                generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
                noticeSerial: serial, pendingNotice: approved)
            XCTAssertEqual(consumeResourcePackPresentationNotice(), approved)
            XCTAssertNil(consumeResourcePackPresentationNotice())
        }

        for (serial, notice) in [(UInt64(3), ""), (4, "   "), (5, "unexpected fallback")] {
            RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
                generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
                noticeSerial: serial, pendingNotice: notice)
            XCTAssertNil(consumeResourcePackPresentationNotice())
        }

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Other pack"),
            noticeSerial: 6, pendingNotice: approved)
        XCTAssertNil(consumeResourcePackPresentationNotice())

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 7, pendingNotice: nil)
        XCTAssertNil(consumeResourcePackPresentationNotice())
    }

    func testPresentationPublicationTransitionsPreserveAdvanceAndClearExactly() {
        let pending = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: UInt64.max,
            pendingNotice: "Faithful 64x is unavailable; built-in fallback active.")

        let active = resourcePackPresentationAfterActivePublication(
            pending, activeAddOns: [.staticLanterns])
        XCTAssertEqual(active, ResourcePackPresentationSnapshot(
            generation: .faithful64x(activeAddOns: [.staticLanterns]),
            noticeSerial: UInt64.max))
        XCTAssertNil(active.pendingNotice, "active publication clears the transient notice")

        let wrapped = resourcePackPresentationAfterFallbackPublication(pending)
        XCTAssertEqual(wrapped, ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 1,
            pendingNotice: "Faithful 64x is unavailable; built-in fallback active."))
        let advanced = resourcePackPresentationAfterFallbackPublication(wrapped)
        XCTAssertEqual(advanced.noticeSerial, 2)
        XCTAssertEqual(advanced.pendingNotice,
                       "Faithful 64x is unavailable; built-in fallback active.")
    }

    func testSyntheticConflictFixtureNamesBothAndHasNoSettingsOrLiveSideEffects() {
        var host = SyntheticConflictHost()
        let beforeSelection = host.selected
        let beforeSettings = host.settingsToken
        let beforeLive = host.liveGenerationToken
        let beforeFocus = host.focused

        host.activateFocused()

        XCTAssertEqual(host.selected, beforeSelection)
        XCTAssertEqual(host.settingsToken, beforeSettings)
        XCTAssertEqual(host.liveGenerationToken, beforeLive)
        XCTAssertEqual(host.focused, beforeFocus)
        XCTAssertEqual(host.consumeStatusAnnouncement(),
                       "Cannot enable Synthetic Lantern while Synthetic Ore is active.")
        XCTAssertNil(host.consumeStatusAnnouncement(), "conflict status announces exactly once")
        XCTAssertEqual(BUNDLED_RESOURCE_PACK_ADD_ONS.map(\.conflictGroup),
                       ["ore-appearance", "sea-lantern-animation"],
                       "the signed catalog must not contain the synthetic conflict group")
    }

    func testCancelledWorkerRetainsLeaseUntilDrainAndRejectsReplacement() {
        let started = DispatchSemaphore(value: 0)
        let drain = DispatchSemaphore(value: 0)
        let worker = ResourcePackCPUWorker(
            queueLabel: "com.elysium.tests.resource-pack-worker.\(UUID().uuidString)"
        ) { _, cancellation in
            started.signal()
            _ = drain.wait(timeout: .now() + 5)
            XCTAssertTrue(cancellation.isCancelled)
            return nil
        }
        let snapshot = ResourcePackStackSourceSnapshot(
            enabledNames: [], sources: [], bundledAddOns: [])
        let completed = expectation(description: "cancelled worker drains")
        var completion: (UInt64, PreparedResourcePackTransaction?, Bool)?

        XCTAssertTrue(worker.submit(transactionID: 1, snapshot: snapshot) { id, prepared, cancelled in
            completion = (id, prepared, cancelled)
            completed.fulfill()
        })
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        worker.cancel(transactionID: 1)
        XCTAssertTrue(worker.isLeased, "cancellation must not free a still-running worker lease")
        XCTAssertFalse(worker.submit(transactionID: 2, snapshot: snapshot) { _, _, _ in
            XCTFail("a replacement transaction must not be queued while the old worker drains")
        })

        drain.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(completion?.0, 1)
        XCTAssertNil(completion?.1)
        XCTAssertEqual(completion?.2, true)
        XCTAssertFalse(worker.isLeased)
    }
}
