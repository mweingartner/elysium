import Foundation
import Metal
import simd
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// `UICanvas.record`/`replay` let the minimap re-emit an unchanged colour grid instead of drawing
/// thousands of cells again. A replay must put exactly the bytes a fresh draw would have put into
/// the vertex stream, and must refuse whenever the canvas state that shaped them has changed.
@MainActor
final class UICanvasRecordingTests: XCTestCase {
    private func canvas() throws -> UICanvas {
        UICanvas(device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    /// The canvas's private vertex stream (pos2 uv2 color4 per vertex), read by reflection so the
    /// test sees the exact bytes `flush` would upload.
    private func vertexBits(_ canvas: UICanvas) -> [UInt32] {
        let verts = Mirror(reflecting: canvas).children.first { $0.label == "verts" }?.value as? [Float]
        XCTAssertNotNil(verts, "UICanvas keeps its vertex stream in `verts`")
        return (verts ?? []).map(\.bitPattern)
    }

    /// (texture source, first vertex float) for each segment of the stream.
    private func segments(_ canvas: UICanvas) -> [(source: String, start: Int)] {
        guard let value = Mirror(reflecting: canvas).children.first(where: { $0.label == "segments" })?.value else {
            XCTFail("UICanvas keeps its texture segments in `segments`"); return []
        }
        return Mirror(reflecting: value).children.map { element in
            let fields = Mirror(reflecting: element.value).children
            let source = fields.first { $0.label == "source" }.map { String(describing: $0.value) } ?? "?"
            let start = fields.first { $0.label == "start" }?.value as? Int ?? -1
            return (source, start)
        }
    }

    private struct Cell { let x, y, w, h: Double; let color: SIMD4<Float> }

    private func drawCells(_ canvas: UICanvas, _ cells: [Cell]) {
        for cell in cells {
            canvas.fillStyle = cell.color
            canvas.fillRect(cell.x, cell.y, cell.w, cell.h)
        }
    }

    // MARK: - record / replay

    func testReplayEmitsTheBytesAFreshDrawEmitsUnderAnyCanvasState() throws {
        let cv = try canvas()
        var seed: UInt64 = 0xC0DE_CAFE
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        var transformed = 0
        for round in 0..<120 {
            let cells = (0..<(1 + Int(next() * 60))).map { _ in
                Cell(x: next() * 400, y: next() * 200, w: next() * 30, h: next() * 30,
                     color: SIMD4<Float>(Float(next()), Float(next()), Float(next()), Float(next())))
            }
            let tx = next() * 40 - 20, ty = next() * 40 - 20, scale = 0.5 + next() * 2, angle = next() - 0.5
            let alpha = Float(0.2 + next() * 0.8)
            let useTransform = round % 3 != 0
            func state() {
                cv.begin(480, 270)
                if useTransform { cv.translate(tx, ty); cv.scale(scale, scale); cv.rotate(angle) }
                cv.globalAlpha = alpha
                cv.setFill("#123456"); cv.fillRect(1, 1, 5, 5)   // something already in the stream
            }
            state()
            drawCells(cv, cells)
            let fresh = vertexBits(cv), freshFill = cv.fillStyle

            state()
            let recorded = try XCTUnwrap(cv.record { drawCells(cv, cells) }, "round \(round)")
            XCTAssertEqual(vertexBits(cv), fresh, "recording draws exactly what drawing draws")

            state()
            cv.fillStyle = SIMD4<Float>(0.9, 0.1, 0.9, 1)          // replay must restore the colour
            XCTAssertTrue(cv.replay(recorded))
            XCTAssertEqual(vertexBits(cv), fresh, "round \(round): the replay is byte-identical")
            XCTAssertEqual(cv.fillStyle, freshFill)
            if useTransform { transformed += 1 }
        }
        XCTAssertGreaterThan(transformed, 60)
    }

    func testReplayRefusesAChangedTransformOrAlphaAndEmitsNothing() throws {
        let cv = try canvas()
        let cells = [Cell(x: 10, y: 10, w: 4, h: 4, color: SIMD4(1, 0, 0, 1)),
                     Cell(x: 20, y: 10, w: 4, h: 4, color: SIMD4(0, 0, 1, 1))]
        cv.begin(480, 270)
        let recorded = try XCTUnwrap(cv.record { drawCells(cv, cells) })

        func refused(_ change: () -> Void, _ label: String) {
            cv.begin(480, 270)
            change()
            let before = vertexBits(cv)
            cv.fillStyle = SIMD4<Float>(0, 1, 0, 1)
            XCTAssertFalse(cv.replay(recorded), label)
            XCTAssertEqual(vertexBits(cv), before, "\(label): a refused replay emits nothing")
            XCTAssertEqual(cv.fillStyle, SIMD4<Float>(0, 1, 0, 1), "\(label): and leaves the fill colour alone")
        }
        refused({ cv.translate(0.5, 0) }, "translated")
        refused({ cv.scale(2, 2) }, "scaled")
        refused({ cv.rotate(0.001) }, "rotated")
        refused({ cv.globalAlpha = 0.5 }, "faded")
        refused({ cv.globalAlpha = .nan }, "NaN alpha")
        refused({ cv.translate(.nan, 0) }, "NaN transform")

        // An identity reached by save/translate/restore is the same state: the replay is accepted.
        cv.begin(480, 270)
        cv.save(); cv.translate(9, 9); cv.restore()
        XCTAssertTrue(cv.replay(recorded))
        XCTAssertEqual(vertexBits(cv).count, 2 * 6 * 8)
    }

    func testRecordingIsRefusedWhenThePassSwitchesTextureOrLeavesStateChanged() throws {
        let cv = try canvas()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4,
                                                                  mipmapped: false)
        cv.guiTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        cv.begin(480, 270)
        XCTAssertNil(cv.record { cv.fillRect(0, 0, 4, 4); cv.guiQuad(0, 0, 4, 4, 0, 0, 4, 4) },
                     "a pass that ends on another texture cannot be replayed as plain quads")
        cv.begin(480, 270)
        XCTAssertNil(cv.record { cv.guiQuad(0, 0, 4, 4, 0, 0, 4, 4); cv.fillRect(0, 0, 4, 4) },
                     "nor one that visited another texture and came back")
        cv.begin(480, 270)
        XCTAssertNil(cv.record { cv.translate(3, 0); cv.fillRect(0, 0, 4, 4) }, "transform left changed")
        cv.begin(480, 270)
        XCTAssertNil(cv.record { cv.globalAlpha = 0.4; cv.fillRect(0, 0, 4, 4) }, "alpha left changed")

        cv.begin(480, 270)
        XCTAssertNotNil(cv.record {
            cv.save(); cv.translate(3, 0); cv.fillRect(0, 0, 4, 4); cv.restore()
            cv.globalAlpha = 0.4; cv.fillRect(0, 0, 4, 4); cv.globalAlpha = 1
        }, "state changed and put back inside the pass is still replayable")
    }

    func testRecordAndReplayAfterAGUISegmentDrawWithTheAtlas() throws {
        let cv = try canvas()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4,
                                                                  mipmapped: false)
        cv.guiTexture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let cells = [Cell(x: 30, y: 30, w: 6, h: 6, color: SIMD4(0.2, 0.4, 0.6, 1))]

        cv.begin(480, 270)
        cv.guiQuad(0, 0, 4, 4, 0, 0, 4, 4)                       // the stream currently draws the GUI sheet
        let start = vertexBits(cv).count
        let recorded = try XCTUnwrap(cv.record { drawCells(cv, cells) })
        XCTAssertEqual(segments(cv).last?.source, "atlas")
        XCTAssertEqual(segments(cv).last?.start, start, "the recorded quads open their own atlas segment")
        let fresh = Array(vertexBits(cv)[start...])

        cv.begin(480, 270)
        cv.guiQuad(0, 0, 4, 4, 0, 0, 4, 4)
        XCTAssertTrue(cv.replay(recorded))
        XCTAssertEqual(segments(cv).map(\.source), ["gui", "atlas"])
        XCTAssertEqual(segments(cv).last?.start, start, "a replay after a GUI quad is drawn with the atlas")
        XCTAssertEqual(Array(vertexBits(cv)[start...]), fresh)
    }

    // MARK: - The minimap

    private func mapWorld(seed: UInt64) -> World {
        let world = World(dim: .overworld, seed: 1)
        let tops = ["stone", "grass_block", "water", "sand", "oak_leaves", "snow_block", "lava", "dirt"]
            .compactMap(bidOpt)
        XCTAssertGreaterThanOrEqual(tops.count, 6)
        func mix(_ value: Int) -> Int {
            var h = UInt64(bitPattern: Int64(value)) &+ seed &* 0x9E37_79B9_7F4A_7C15
            h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9; h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((h ^ (h >> 31)) % 1_000_003)
        }
        for cz in -2...1 {
            for cx in -2...1 {
                let chunk = Chunk(cx: cx, cz: cz, minY: world.info.minY, height: world.info.height)
                chunk.status = .lit
                chunk.biomes = Array(repeating: UInt8(Biome.plains.rawValue), count: chunk.biomes.count)
                for z in 0..<16 { for x in 0..<16 {
                    // Two-by-two patches, so runs of equal colour merge into longer quads.
                    let patch = mix(((cx * 16 + x) >> 1) &* 7_919 &+ ((cz * 16 + z) >> 1))
                    let block = tops[patch % tops.count], height = 60 + (patch / 7) % 12
                    chunk.set(x, height, z, cell(block)); chunk.heightmap[z * 16 + x] = Int16(height)
                } }
                world.setChunk(chunk)
            }
        }
        return world
    }

    func testMinimapReplayIsByteIdenticalToAFreshDrawAcrossTheRefreshAndRefusals() throws {
        registerAllBlocks(); registerAllItems(); registerAllBiomes()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ui = UIManager(cv: UICanvas(device: device))
        ui.resize(480, 270, 1)
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("elysium-minimap-replay-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try SaveDB.open(databaseURL: root.appendingPathComponent("worlds.sqlite"), migrateLegacy: false)
        defer { try? database.close(); try? FileManager.default.removeItem(at: root) }
        let game = GameCore(db: database,
                            localSettingsStore: LocalSettingsStore(directoryURL: root.appendingPathComponent("settings")))
        let a = mapWorld(seed: 11), b = mapWorld(seed: 29)
        game.player = Player(world: a)
        game.player.setPos(3.5, 70, -4.5); game.player.yaw = 0.7
        let rect = MapOverlayRect(x: 360, y: 8, size: 100)
        let viewport = MapViewport(centerX: 0, centerZ: 0, spanBlocks: 60)

        func draw(_ world: World, transform: (() -> Void)? = nil) -> [UInt32] {
            game.worlds[.overworld] = world
            ui.cv.begin(480, 270)
            transform?()
            drawMapOverlay(ui, game, rect: rect, viewport: viewport, expanded: false, bounds: nil)
            return vertexBits(ui.cv)
        }
        // Drawing the other world first means the next draw of `a` misses both caches: fresh.
        _ = draw(b)
        let freshA = draw(a)
        XCTAssertGreaterThan(freshA.count, 8 * 6 * 8, "the grid really drew cells")
        // The next frames hit the colour-grid cache and replay the recorded quads.
        for frame in 1..<9 {
            XCTAssertEqual(draw(a), freshA, "frame \(frame): replayed grid differs from the fresh draw")
        }
        let freshB = draw(b)
        XCTAssertNotEqual(freshB, freshA, "the two worlds have different maps")
        XCTAssertEqual(draw(a), freshA, "a fresh draw is deterministic")

        // A still view across several periodic refreshes (new grid generation, new recording).
        for frame in 0..<25 { XCTAssertEqual(draw(a), freshA, "still frame \(frame)") }

        // Under a translated canvas the replay is refused and the quads are drawn and recorded
        // again; the result equals a fresh translated draw, and its own replays match it.
        let shift = { ui.cv.translate(7, -3) }
        _ = draw(b, transform: shift)
        let freshShifted = draw(a, transform: shift)
        XCTAssertNotEqual(freshShifted, freshA)
        _ = draw(a)                                          // records under identity
        XCTAssertEqual(draw(a, transform: shift), freshShifted, "refused replay falls back to drawing")
        XCTAssertEqual(draw(a, transform: shift), freshShifted, "and that recording replays")
        XCTAssertEqual(draw(a), freshA, "back at identity the stale shifted recording is refused")

        // A block edit reaches the map within the refresh, and then matches a fresh draw.
        let chunk = try XCTUnwrap(a.getChunkAt(0, 0))
        for z in 0..<16 { for x in 0..<16 { chunk.set(x, 80, z, cell(bid("gold_block"))); chunk.heightmap[z * 16 + x] = 80 } }
        var edited: [UInt32] = []
        for _ in 0..<12 { edited = draw(a) }
        XCTAssertNotEqual(edited, freshA, "the periodic refresh picks up the edit")
        _ = draw(b)
        XCTAssertEqual(draw(a), edited, "the refreshed, replayed grid equals a fresh draw of the edited world")
    }
}
