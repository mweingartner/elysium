import Foundation
import Metal
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// Animated atlas tiles are now built off the main thread. The pixels must be the ones the
/// renderer used to build inline, and a slow build must never queue up or outlive its atlas.
final class AtlasAnimationStagerTests: XCTestCase {
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255, size: Int = 4) -> [UInt8] {
        Array(repeating: [r, g, b, a], count: size * size).flatMap { $0 }
    }

    private func levelZero(_ staged: AtlasAnimationStager.Staged, size: Int) -> [UInt8] {
        let level = staged.levels[0]
        let bytes = UnsafeRawBufferPointer(start: staged.buffer.contents(), count: staged.buffer.length)
        return (0..<size).flatMap { row in
            Array(bytes[(level.offset + row * level.rowBytes)..<(level.offset + row * level.rowBytes + size * 4)])
        }
    }

    func testBlendIsTheTruncatingInterpolationTheRendererAlwaysUsed() {
        var seed: UInt64 = 0x1234_5678
        func next() -> UInt8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return UInt8(truncatingIfNeeded: seed >> 33)
        }
        for _ in 0..<50 {
            let current = (0..<256).map { _ in next() }, target = (0..<256).map { _ in next() }
            let steps = 1 + Int(next() % 40)
            for tick in 0..<steps {
                let fraction = Double(tick) / Double(steps)
                // The loop `WorldRenderer.advanceAnimationTick` ran on the main thread.
                var expected = [UInt8](repeating: 0, count: current.count)
                for i in 0..<current.count {
                    expected[i] = UInt8(Double(current[i]) + (Double(target[i]) - Double(current[i])) * fraction)
                }
                let request = AtlasAnimationStager.Request(slice: 0, current: current, blend: (target, fraction))
                XCTAssertEqual(AtlasAnimationStager.pixels(for: request), expected)
            }
        }
        let plain = AtlasAnimationStager.Request(slice: 0, current: [1, 2, 3, 4], blend: nil)
        XCTAssertEqual(AtlasAnimationStager.pixels(for: plain), [1, 2, 3, 4])
        let mismatched = AtlasAnimationStager.Request(slice: 0, current: [1, 2, 3, 4], blend: ([9, 9], 0.5))
        XCTAssertEqual(AtlasAnimationStager.pixels(for: mismatched), [1, 2, 3, 4],
                       "a frame of another size is never read past its end")
    }

    func testLayoutPadsRowsAndKeepsEveryLevelsPixels() throws {
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        for i in pixels.indices { pixels[i] = UInt8(truncatingIfNeeded: i &* 7 &+ 3) }
        let chain = try XCTUnwrap(WorldAtlasMipChain.make(pixels: pixels, size: 8))
        let (bytes, levels) = AtlasAnimationStager.layout(chain)
        XCTAssertEqual(levels.map(\.size), [8, 4, 2, 1])
        XCTAssertEqual(levels.map(\.level), [0, 1, 2, 3])
        var offset = 0
        for (level, image) in zip(levels, chain) {
            XCTAssertEqual(level.rowBytes, 256, "rows are padded to the blit alignment")
            XCTAssertEqual(level.offset, offset)
            for row in 0..<image.size {
                let start = level.offset + row * level.rowBytes
                XCTAssertEqual(Array(bytes[start..<(start + image.size * 4)]),
                               Array(image.pixels[(row * image.size * 4)..<((row + 1) * image.size * 4)]))
            }
            offset += level.rowBytes * image.size
        }
        XCTAssertEqual(bytes.count, offset)
    }

    func testNewestRequestPerTileWinsAndLaterRequestsFollowInOrder() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stager = AtlasAnimationStager(device: device)
        XCTAssertTrue(stager.takeFinished().isEmpty)
        stager.pump(tileSize: 4)                       // nothing asked for: nothing starts
        stager.waitUntilIdle()
        XCTAssertTrue(stager.takeFinished().isEmpty)

        stager.request(.init(slice: 3, current: solid(10, 0, 0), blend: nil))
        stager.request(.init(slice: 3, current: solid(20, 0, 0), blend: nil))    // replaces the first
        stager.request(.init(slice: 1, current: solid(0, 30, 0), blend: (solid(0, 50, 0), 0.5)))
        stager.pump(tileSize: 4)
        // Asked for while the first batch may still be building: held for the next batch.
        stager.request(.init(slice: 3, current: solid(40, 0, 0), blend: nil))
        stager.pump(tileSize: 4)
        stager.waitUntilIdle()
        var built = stager.takeFinished()
        XCTAssertTrue(stager.takeFinished().isEmpty, "finished images are handed over once")
        // Whether the late request joined a second batch at once or waits for this pump depends
        // on timing; the images and their order do not.
        stager.pump(tileSize: 4)
        stager.waitUntilIdle()
        built += stager.takeFinished()
        XCTAssertEqual(built.map(\.slice), [1, 3, 3], "one image per tile per batch, in slice order")
        XCTAssertEqual(levelZero(built[0], size: 4), solid(0, 40, 0))
        XCTAssertEqual(levelZero(built[1], size: 4), solid(20, 0, 0), "the replaced request was never built")
        XCTAssertEqual(levelZero(built[2], size: 4), solid(40, 0, 0))
        XCTAssertEqual(built[0].levels.map(\.size), [4, 2, 1])
    }

    func testEveryRequestIsEventuallyBuiltEvenWhenAskedDuringABuild() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stager = AtlasAnimationStager(device: device)
        var latest: [Int: UInt8] = [:]
        var shown: [Int: UInt8] = [:]
        for tick in 0..<200 {
            let slice = tick % 5, value = UInt8(tick % 250) + 1
            stager.request(.init(slice: slice, current: solid(value, 0, 0), blend: nil))
            latest[slice] = value
            stager.pump(tileSize: 4)
            for staged in stager.takeFinished() { shown[staged.slice] = levelZero(staged, size: 4)[0] }
        }
        for _ in 0..<3 {
            stager.waitUntilIdle()
            for staged in stager.takeFinished() { shown[staged.slice] = levelZero(staged, size: 4)[0] }
            stager.pump(tileSize: 4)
        }
        XCTAssertEqual(shown, latest, "each tile ends on the last image asked for it")
    }

    func testResetDropsWhatWasAskedAndBuiltForThePreviousAtlas() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stager = AtlasAnimationStager(device: device)
        for round in 0..<50 {
            stager.request(.init(slice: 0, current: solid(UInt8(round), 0, 0, size: 16), blend: nil))
            stager.pump(tileSize: 16)
            stager.request(.init(slice: 1, current: solid(0, UInt8(round), 0, size: 16), blend: nil))
            stager.reset()                              // a new atlas is installed mid-build
            stager.waitUntilIdle()
            XCTAssertTrue(stager.takeFinished().isEmpty, "round \(round): nothing from the old atlas survives")
            stager.pump(tileSize: 16)
            stager.waitUntilIdle()
            XCTAssertTrue(stager.takeFinished().isEmpty, "round \(round): nor does an unbuilt request")
        }
        stager.request(.init(slice: 2, current: solid(0, 0, 9), blend: nil))
        stager.pump(tileSize: 4)
        stager.waitUntilIdle()
        XCTAssertEqual(stager.takeFinished().map(\.slice), [2], "the stager keeps working for the new atlas")
    }

    // MARK: - Through the real renderer (independent review)

    private func pack(res: Int, slices: [[UInt8]], animations: [TileAnimation]) -> PackAtlasResult {
        PackAtlasResult(res: res, slices: slices,
            icon16: BuiltAtlas(count: 0, pixels: [], missing: []), animations: animations,
            itemIcons: [:], heldItemIcons: [:], tintGate: slices.map { _ in 1 }, textureGate: slices.map { _ in 1 },
            fluidAnimated: false, appliedTiles: slices.count, appliedItems: 0)
    }

    /// Blits whatever the renderer has staged and returns every mip level of `slice`.
    private func flushAndRead(_ renderer: WorldRenderer, _ texture: MTLTexture, slice: Int) throws -> [[UInt8]] {
        let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
        renderer.flushAtlasUploads(command)
        if texture.storageMode == .managed {
            let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
            blit.synchronize(resource: texture); blit.endEncoding()
        }
        command.commit(); command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "")
        return (0..<texture.mipmapLevelCount).map { level in
            let size = max(1, texture.width >> level)
            var bytes = [UInt8](repeating: 0, count: size * size * 4)
            bytes.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: size * 4, bytesPerImage: size * size * 4,
                                 from: MTLRegionMake2D(0, 0, size, size), mipmapLevel: level, slice: slice)
            }
            return bytes
        }
    }

    /// The per-channel truncating blend `advanceAnimationTick` computed inline before the stager.
    private func inlineBlend(_ current: [UInt8], _ next: [UInt8], _ fraction: Double) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: current.count)
        for i in 0..<current.count { out[i] = UInt8(Double(current[i]) + (Double(next[i]) - Double(current[i])) * fraction) }
        return out
    }

    @MainActor
    func testInterpolatedAnimationReachesEveryMipAsTheInlineBlendDidAndTheNewestTickWins() throws {
        registerAllBlocks()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = WorldRenderer(device: device)
        var red = solid(250, 10, 0, size: 4), blue = solid(0, 20, 240, 200, size: 4)
        red[5] = 99; blue[22] = 7                                      // not every pixel the same
        let animation = TileAnimation(slice: 1, frames: [red, blue], order: [(0, 4), (1, 4)], interpolate: true)
        let staged = try XCTUnwrap(renderer.stagePackAtlas(pack(res: 4, slices: [solid(1, 2, 3), red],
                                                                 animations: [animation])))
        renderer.installStagedWorldAtlas(staged)

        renderer.tickTileAnimations(dtMs: 50)                          // tick 1 of 4 into red: blend 0.25
        renderer.waitForStagedTileAnimations()
        let quarter = try XCTUnwrap(WorldAtlasMipChain.make(pixels: inlineBlend(red, blue, 0.25), size: 4))
        XCTAssertEqual(try flushAndRead(renderer, staged.texture, slice: 1), quarter.map(\.pixels))

        // Three ticks in one frame (blend 0.5, 0.75, then blue at 0): only the newest is uploaded.
        renderer.tickTileAnimations(dtMs: 150)
        renderer.waitForStagedTileAnimations()
        let newest = try XCTUnwrap(WorldAtlasMipChain.make(pixels: inlineBlend(blue, red, 0), size: 4))
        XCTAssertEqual(try flushAndRead(renderer, staged.texture, slice: 1), newest.map(\.pixels))
        let untouched = try XCTUnwrap(WorldAtlasMipChain.make(pixels: solid(1, 2, 3), size: 4))
        XCTAssertEqual(try flushAndRead(renderer, staged.texture, slice: 0), untouched.map(\.pixels),
                       "the other slice is never written")
    }

    /// An atlas installed while its predecessor's animated tiles are being built (a resource-pack
    /// switch, of the same or another tile size) must never receive those tiles.
    @MainActor
    func testAnAtlasInstalledWhileABatchBuildsNeverReceivesThePreviousAtlasTiles() throws {
        registerAllBlocks()
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = WorldRenderer(device: device)
        for (round, newRes) in [8, 4, 8, 16, 4, 8].enumerated() {
            let red = solid(255, 0, 0, size: 8), blue = solid(0, 0, 255, size: 8)
            let animation = TileAnimation(slice: 0, frames: [red, blue], order: [(0, 1), (1, 100)], interpolate: false)
            let old = try XCTUnwrap(renderer.stagePackAtlas(pack(res: 8, slices: [red, red], animations: [animation])))
            renderer.installStagedWorldAtlas(old)
            renderer.tickTileAnimations(dtMs: 50)                      // asks for blue and starts building it
            let green = solid(0, 255, 0, size: newRes)
            let replacement = try XCTUnwrap(renderer.stagePackAtlas(pack(res: newRes, slices: [green, green], animations: [])))
            renderer.installStagedWorldAtlas(replacement)              // before or after the build finished
            renderer.waitForStagedTileAnimations()
            let expected = try XCTUnwrap(WorldAtlasMipChain.make(pixels: green, size: newRes)).map(\.pixels)
            XCTAssertEqual(try flushAndRead(renderer, replacement.texture, slice: 0), expected,
                           "round \(round): a \(newRes)px atlas kept its own tile")
        }
        // Control: the same renderer still animates the atlas that is installed.
        let red = solid(255, 0, 0, size: 8), blue = solid(0, 0, 255, size: 8)
        let animation = TileAnimation(slice: 0, frames: [red, blue], order: [(0, 1), (1, 100)], interpolate: false)
        let current = try XCTUnwrap(renderer.stagePackAtlas(pack(res: 8, slices: [red, red], animations: [animation])))
        renderer.installStagedWorldAtlas(current)
        renderer.tickTileAnimations(dtMs: 50)
        renderer.waitForStagedTileAnimations()
        XCTAssertEqual(try flushAndRead(renderer, current.texture, slice: 0),
                       try XCTUnwrap(WorldAtlasMipChain.make(pixels: blue, size: 8)).map(\.pixels))
    }

    func testImagesOfTheWrongSizeAreRefusedRatherThanStaged() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stager = AtlasAnimationStager(device: device)
        stager.request(.init(slice: 0, current: solid(1, 2, 3, size: 4), blend: nil))
        stager.pump(tileSize: 8)                        // atlas tiles are 8 px, this frame is 4 px
        stager.waitUntilIdle()
        XCTAssertTrue(stager.takeFinished().isEmpty)
    }
}
