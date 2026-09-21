import Foundation
import XCTest
@testable import Elysium
@testable import ElysiumCore

/// Java resource packs store sign boards in entity-sheet unwraps, not in
/// `block/`. Exercise the real Faithful archive so the renderer cannot
/// silently fall back to planks when one of those entity paths changes.
final class SignResourcePackMappingTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func opaquePixels(in slice: [UInt8], resolution: Int, rows: Range<Int>) -> Int {
        rows.reduce(0) { total, y in
            total + (0..<resolution).reduce(0) { count, x in
                count + (slice[(y * resolution + x) * 4 + 3] == 0 ? 0 : 1)
            }
        }
    }

    private func crop(_ image: RGBAImage, x: Int, y: Int, width: Int, height: Int) -> RGBAImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for row in 0..<height {
            let source = ((y + row) * image.width + x) * 4
            let destination = row * width * 4
            pixels.replaceSubrange(destination..<(destination + width * 4),
                                   with: image.pixels[source..<(source + width * 4)])
        }
        return RGBAImage(width: width, height: height, pixels: pixels)
    }

    private func expectedBoard(_ pack: ResourcePack, wood: String, hanging: Bool) throws -> RGBAImage {
        let path = hanging ? "entity/signs/hanging/\(wood)" : "entity/signs/\(wood)"
        let image = try XCTUnwrap(decodePNG(try XCTUnwrap(pack.file("\(pack.texRoot)\(path).png"))))
        XCTAssertEqual(image.width % 64, 0, "\(path) must preserve Java's 64-wide logical sheet")
        XCTAssertEqual(image.height % 32, 0, "\(path) must preserve Java's 32-high logical sheet")
        let scale = image.width / 64
        XCTAssertEqual(image.height / 32, scale, "\(path) must have uniform logical scale")
        let rects = hanging ? [(2, 14, 14, 10), (18, 14, 14, 10)] : [(2, 2, 24, 12), (28, 2, 24, 12)]
        let pieces = rects.map { crop(image, x: $0.0 * scale, y: $0.1 * scale,
                                       width: $0.2 * scale, height: $0.3 * scale) }
        var pixels = [UInt8]()
        for piece in pieces { pixels += piece.pixels }
        return RGBAImage(width: pieces[0].width,
                         height: pieces.reduce(0) { $0 + $1.height }, pixels: pixels)
    }

    func testFaithfulEntitySheetsPopulateBothSemanticSignBoardBands() throws {
        let archive = repositoryRoot().appendingPathComponent(
            "packaging/Faithful 64x - December 2025 Release.zip")
        let pack = try XCTUnwrap(ResourcePack(url: archive))
        let atlas = try XCTUnwrap(buildPackAtlas(packs: [pack]))
        let upperRows = 0..<(atlas.res / 2)
        let lowerRows = (atlas.res / 2)..<atlas.res

        for wood in WOODS {
            for tile in ["\(wood)_sign_board", "\(wood)_hanging_sign_board"] {
                let index = tileId(tile)
                XCTAssertEqual(atlas.textureGate[index], 1,
                               "\(tile) must load from Faithful's entity/signs unwrap")
                let slice = atlas.slices[index]
                XCTAssertGreaterThan(opaquePixels(in: slice, resolution: atlas.res, rows: upperRows), 0,
                                     "\(tile) front band must contain authored art")
                XCTAssertGreaterThan(opaquePixels(in: slice, resolution: atlas.res, rows: lowerRows), 0,
                                     "\(tile) back band must contain authored art")
                let expected = try expectedBoard(pack, wood: wood, hanging: tile.contains("_hanging_"))
                XCTAssertEqual(slice, scaleTo(expected, atlas.res),
                               "\(tile) must preserve both ordered entity-sheet faces")
            }
        }
    }

    func testNonIntegralSignBoardDownscalesKeepFullWidthAndBothBands() {
        // A normal sign stacks two 24×12 board faces.  At Faithful's 4× source
        // scale that is a 96×96 semantic tile; common 16× and 64× atlas sizes
        // are both a 1.5× downscale.  Each source coordinate is distinct so a
        // truncated integer box (which previously dropped the rightmost third)
        // cannot accidentally pass this test.
        for (sourceResolution, atlasResolution) in [(24, 16), (96, 64)] {
            var pixels = [UInt8](repeating: 0, count: sourceResolution * sourceResolution * 4)
            for y in 0..<sourceResolution {
                for x in 0..<sourceResolution {
                    let i = (y * sourceResolution + x) * 4
                    pixels[i] = y < sourceResolution / 2 ? 0x31 : 0xc7
                    pixels[i + 1] = UInt8(x * 255 / (sourceResolution - 1))
                    pixels[i + 2] = UInt8(y * 255 / (sourceResolution - 1))
                    pixels[i + 3] = 255
                }
            }
            let board = RGBAImage(width: sourceResolution, height: sourceResolution, pixels: pixels)
            let scaled = scaleTo(board, atlasResolution)
            XCTAssertEqual(scaled, scaleNearestFullExtent(board, to: atlasResolution),
                           "\(sourceResolution)px sign board → \(atlasResolution)px atlas must sample the complete source")
            let firstDestination = 0
            let lastDestination = (atlasResolution * atlasResolution - 1) * 4
            let lastSource = (sourceResolution * sourceResolution - 1) * 4
            XCTAssertEqual(Array(scaled[firstDestination..<(firstDestination + 4)]),
                           Array(board.pixels[0..<4]),
                           "\(sourceResolution)px sign board must retain its first authored texel")
            XCTAssertEqual(Array(scaled[lastDestination..<(lastDestination + 4)]),
                           Array(board.pixels[lastSource..<(lastSource + 4)]),
                           "\(sourceResolution)px sign board must retain its final authored texel")
        }
    }
}
