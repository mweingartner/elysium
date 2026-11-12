import Foundation
import Metal
import XCTest
@testable import Elysium

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

    func testImagesOfTheWrongSizeAreRefusedRatherThanStaged() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let stager = AtlasAnimationStager(device: device)
        stager.request(.init(slice: 0, current: solid(1, 2, 3, size: 4), blend: nil))
        stager.pump(tileSize: 8)                        // atlas tiles are 8 px, this frame is 4 px
        stager.waitUntilIdle()
        XCTAssertTrue(stager.takeFinished().isEmpty)
    }
}
