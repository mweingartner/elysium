import CryptoKit
import Foundation
import XCTest

final class RPGPixelFontSourceTests: XCTestCase {
    private typealias GlyphEntry = (key: Character, columns: [Int])

    private let frozenGlyphs: [(Character, [Int], Int)] = [
        ("·", [0x18], 2),
        ("✓", [0x20, 0x40, 0x20, 0x10, 0x08, 0x04], 7),
        ("←", [0x08, 0x1c, 0x2a, 0x08, 0x08, 0x08, 0x08], 8),
        ("→", [0x08, 0x08, 0x08, 0x08, 0x2a, 0x1c, 0x08], 8),
        ("’", [0x01, 0x03, 0x06, 0x04], 5),
        ("…", [0x40, 0x00, 0x40, 0x00, 0x40], 6),
        ("—", [0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08], 8),
    ]

    private let appendedLines = [
        "    \"·\": [0x18],",
        "    \"✓\": [0x20, 0x40, 0x20, 0x10, 0x08, 0x04],",
        "    \"←\": [0x08, 0x1c, 0x2a, 0x08, 0x08, 0x08, 0x08],",
        "    \"→\": [0x08, 0x08, 0x08, 0x08, 0x2a, 0x1c, 0x08],",
        "    \"’\": [0x01, 0x03, 0x06, 0x04],",
        "    \"…\": [0x40, 0x00, 0x40, 0x00, 0x40],",
        "    \"—\": [0x08, 0x08, 0x08, 0x08, 0x08, 0x08, 0x08],",
    ]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func glyphDeclaration(in canvas: String) throws -> String {
        let start = try XCTUnwrap(canvas.range(of: "let GLYPHS: [Character: [Int]] = ["))
        let end = try XCTUnwrap(canvas.range(
            of: "\n]\n\n/// per-character advances", range: start.upperBound..<canvas.endIndex))
        return String(canvas[start.lowerBound..<end.lowerBound]) + "\n]\n"
    }

    private func parseGlyphs(_ declaration: String) throws -> [GlyphEntry] {
        let expression = try NSRegularExpression(
            pattern: #"\"((?:\\.|[^\"\\])+)\"\s*:\s*\[([^\]]*)\]"#)
        let range = NSRange(declaration.startIndex..<declaration.endIndex, in: declaration)
        return try expression.matches(in: declaration, range: range).map { match in
            let rawKeyRange = try XCTUnwrap(Range(match.range(at: 1), in: declaration))
            let rawColumnsRange = try XCTUnwrap(Range(match.range(at: 2), in: declaration))
            let encodedKey = "\"" + declaration[rawKeyRange] + "\""
            let decodedKey = try XCTUnwrap(
                try JSONSerialization.jsonObject(
                    with: Data(encodedKey.utf8), options: .fragmentsAllowed) as? String)
            let characters = Array(decodedKey)
            XCTAssertEqual(characters.count, 1, "glyph key must be one Character: \(decodedKey)")
            let key = try XCTUnwrap(characters.first)
            let columns = try declaration[rawColumnsRange].split(separator: ",").map { token in
                let value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if value.hasPrefix("0x") {
                    return try XCTUnwrap(Int(value.dropFirst(2), radix: 16))
                }
                return try XCTUnwrap(Int(value))
            }
            return (key, columns)
        }
    }

    private func raster(_ columns: [Int]) -> [String] {
        (0..<8).map { row in
            String(columns.map { column in column & (1 << row) == 0 ? "." : "#" })
        }
    }

    private func sha256(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func occurrenceCount(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    func testFrozenGlyphTableAndReviewedBaselineAreExact() throws {
        let declaration = try glyphDeclaration(in: source("Sources/Elysium/UICanvas.swift"))
        let entries = try parseGlyphs(declaration)
        XCTAssertEqual(entries.count, 108)
        XCTAssertEqual(Set(entries.map(\.key)).count, 108)

        let glyphs = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.columns) })
        let requiredKeys = Set(frozenGlyphs.map(\.0))
        XCTAssertEqual(requiredKeys.count, 7)
        for (key, expectedColumns, expectedAdvance) in frozenGlyphs {
            XCTAssertEqual(entries.filter { $0.key == key }.count, 1, "duplicate glyph \(key)")
            let actual = try XCTUnwrap(glyphs[key])
            XCTAssertEqual(actual, expectedColumns, "columns drifted for \(key)")
            XCTAssertEqual(actual.count + 1, expectedAdvance, "advance drifted for \(key)")
            XCTAssertFalse(actual.isEmpty)
            XCTAssertTrue(actual.contains(where: { $0 != 0 }))
            XCTAssertTrue(actual.allSatisfy { $0 >= 0 && ($0 & ~0x7f) == 0 },
                          "glyph \(key) escaped rows 0...6")
            for (otherKey, otherColumns) in glyphs where otherKey != key {
                XCTAssertNotEqual(actual, otherColumns, "glyph \(key) aliases \(otherKey)")
            }
        }
        XCTAssertEqual(glyphs["?"], [0x02, 0x01, 0x51, 0x09, 0x06])

        var reviewedBaseline = declaration
        for line in appendedLines {
            XCTAssertEqual(occurrenceCount(line + "\n", in: reviewedBaseline), 1)
            reviewedBaseline = reviewedBaseline.replacingOccurrences(of: line + "\n", with: "")
        }
        XCTAssertEqual(sha256(reviewedBaseline),
                       "9c8db10f4946068dfcb52ceeb0df4a6cc16a849dbadaf9a30a9d677eafe35860")
    }

    func testFrozenEightRowRastersBaselineAndScaleBounds() throws {
        let expected: [Character: [String]] = [
            "·": [".", ".", ".", "#", "#", ".", ".", "."],
            "✓": ["......", "......", ".....#", "....#.", "...#..", "#.#...", ".#....", "......"],
            "←": [".......", "..#....", ".#.....", "#######", ".#.....", "..#....", ".......", "......."],
            "→": [".......", "....#..", ".....#.", "#######", ".....#.", "....#..", ".......", "......."],
            "’": ["##..", ".##.", "..##", "....", "....", "....", "....", "...."],
            "…": [".....", ".....", ".....", ".....", ".....", ".....", "#.#.#", "....."],
            "—": [".......", ".......", ".......", "#######", ".......", ".......", ".......", "......."],
        ]
        let shippedRPGScales = [0.7, 0.8, 0.85, 0.9, 1.0, 1.5]
        for (key, columns, advance) in frozenGlyphs {
            XCTAssertEqual(raster(columns), expected[key])
            XCTAssertTrue(raster(columns)[7].allSatisfy { $0 == "." })
            for scale in shippedRPGScales {
                for (column, bits) in columns.enumerated() where bits != 0 {
                    XCTAssertLessThanOrEqual(Double(column + 1) * scale,
                                             Double(advance - 1) * scale)
                }
                let occupiedRows = (0..<8).filter { row in
                    columns.contains { $0 & (1 << row) != 0 }
                }
                XCTAssertLessThanOrEqual(Double((occupiedRows.max() ?? 0) + 1) * scale,
                                         7 * scale)
            }
        }
        XCTAssertEqual(expected["·"]?[5], ".", "middle dot must not use period baseline")
        XCTAssertEqual(expected["’"]?[0], "##..", "right quote must remain in cap region")
        XCTAssertEqual(expected["…"]?[6], "#.#.#", "ellipsis must be one baseline glyph")
        XCTAssertEqual(expected["—"]?[3], "#######", "em dash must retain centered long stroke")
    }

    func testDrawMeasurePackFormattingAndGraphemeContracts() throws {
        let entries = try parseGlyphs(try glyphDeclaration(in: source("Sources/Elysium/UICanvas.swift")))
        let glyphs = Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.columns) })
        let fallback = try XCTUnwrap(glyphs["?"])

        func isPackASCII(_ character: Character) -> Bool {
            character.unicodeScalars.count == 1
                && (character.unicodeScalars.first?.value ?? 0) >= 32
                && (character.unicodeScalars.first?.value ?? 0) < 127
        }
        func width(_ text: String, packWidths: [Int]?) -> Int {
            var total = 0
            var skip = false
            for character in text {
                if skip { skip = false; continue }
                if character == "§" { skip = true; continue }
                if let packWidths, isPackASCII(character),
                   let value = character.unicodeScalars.first?.value {
                    total += packWidths[Int(value)]
                } else {
                    total += (glyphs[character] ?? fallback).count + 1
                }
            }
            return total
        }

        let requiredText = String(frozenGlyphs.map(\.0))
        let activePack = (0..<127).map { 20 + $0 }
        XCTAssertEqual(width(requiredText, packWidths: nil),
                       frozenGlyphs.reduce(0) { $0 + $1.2 })
        XCTAssertEqual(width(requiredText, packWidths: activePack),
                       width(requiredText, packWidths: nil),
                       "required non-ASCII glyphs must bypass an active ASCII pack")
        XCTAssertEqual(width("§x", packWidths: nil), 0)
        XCTAssertEqual(width("§x", packWidths: activePack), 0)
        XCTAssertTrue(isPackASCII(" "))
        XCTAssertTrue(isPackASCII("~"))
        XCTAssertFalse(isPackASCII(Character("\u{1f}")))
        XCTAssertFalse(isPackASCII(Character("\u{7f}")))
        XCTAssertTrue(frozenGlyphs.allSatisfy { !isPackASCII($0.0) })

        let unsupported: Character = "Ω"
        XCTAssertNil(glyphs[unsupported])
        XCTAssertEqual((glyphs[unsupported] ?? fallback).count + 1, fallback.count + 1)
        let variation = Character("✓\u{fe0f}")
        XCTAssertEqual(variation.unicodeScalars.count, 2)
        XCTAssertEqual(Array(String(variation)).count, 1)
        XCTAssertNil(glyphs[variation])
        XCTAssertEqual(width(String(variation), packWidths: nil), fallback.count + 1,
                       "multi-scalar grapheme must fall back exactly once")

        let mixed = "A·✓←→’…—Z"
        let expectedActive = activePack[Int(Character("A").asciiValue!)]
            + frozenGlyphs.reduce(0) { $0 + $1.2 }
            + activePack[Int(Character("Z").asciiValue!)]
        XCTAssertEqual(width(mixed, packWidths: activePack), expectedActive)
    }

    func testProductionSourceKeepsOneCharacterFallbackAndSharedAdvanceRouting() throws {
        let canvas = try source("Sources/Elysium/UICanvas.swift")
        let renderer = try source("Sources/Elysium/RPGScreensM.swift")
        let drawStart = try XCTUnwrap(canvas.range(of: "    func drawText(_ text: String"))
        let drawEnd = try XCTUnwrap(canvas.range(
            of: "    func drawTextCentered", range: drawStart.upperBound..<canvas.endIndex))
        let draw = String(canvas[drawStart.lowerBound..<drawEnd.lowerBound])
        let glyphStart = try XCTUnwrap(canvas.range(of: "func glyphWidth(_ ch: Character)"))
        let widthEnd = try XCTUnwrap(canvas.range(
            of: "func wrapText", range: glyphStart.upperBound..<canvas.endIndex))
        let widths = String(canvas[glyphStart.lowerBound..<widthEnd.lowerBound])

        XCTAssertTrue(draw.contains("let ch = text[i]"))
        XCTAssertTrue(draw.contains("let g = GLYPHS[ch] ?? GLYPHS[\"?\"]!"))
        XCTAssertTrue(draw.contains("cx += Double(g.count + 1) * s"))
        XCTAssertTrue(draw.contains("if let pf = guiTexture != nil ? packFontWidths : nil"))
        XCTAssertTrue(widths.contains("(GLYPHS[ch] ?? GLYPHS[\"?\"]!).count + 1"))
        XCTAssertTrue(widths.contains("width += Double(glyphWidth(ch))"))
        XCTAssertTrue(widths.contains("if ch == \"§\""))
        XCTAssertTrue(widths.contains("if let pf = packFontWidths"))
        XCTAssertTrue(widths.contains("var cursor = UIStreamingTextWidthCursor()"))
        XCTAssertTrue(widths.contains("let step = makeTextWidthStep()"))
        XCTAssertEqual(occurrenceCount("code >= 32, code < 127", in: canvas), 2)
        XCTAssertEqual(occurrenceCount("GLYPHS[ch] ?? GLYPHS[\"?\"]!", in: canvas), 2)
        XCTAssertFalse(canvas.contains("precomposedStringWithCanonicalMapping"))
        XCTAssertFalse(canvas.contains("decomposedStringWithCanonicalMapping"))

        for scalar in frozenGlyphs.map(\.0) {
            XCTAssertFalse(canvas.contains("replacingOccurrences(of: \"\(scalar)\""))
            XCTAssertFalse(renderer.contains("replacingOccurrences(of: \"\(scalar)\""))
        }
        XCTAssertTrue(renderer.contains("drawText(\"✓\""))
        XCTAssertTrue(renderer.contains("D-pad/A/B · Keyboard"))
        XCTAssertTrue(renderer.contains("return \"…\""))
    }

    func testApprovedRPGSourcesRetainAllSevenBareScalars() throws {
        let model = try source("Sources/ElysiumCore/Game/RPGScreenModel.swift")
        let renderer = try source("Sources/Elysium/RPGScreensM.swift")
        let harness = try source("Sources/ElysiumCore/Game/RPGUIHarness.swift")
        XCTAssertTrue(model.contains("[\"← Move Left\"]"))
        XCTAssertTrue(model.contains("[\"Move Right →\"]"))
        XCTAssertTrue(model.contains("host’s character state"))
        XCTAssertTrue(model.contains("·"))
        XCTAssertTrue(renderer.contains("drawText(\"✓\""))
        XCTAssertTrue(renderer.contains("return \"…\""))
        XCTAssertTrue(harness.contains(" + \" — \" + "))
        for scalar in frozenGlyphs.map(\.0) {
            XCTAssertEqual(String(scalar).unicodeScalars.count, 1)
        }
    }

    func testClassCarouselNeverRoutesUnsupportedChevronTextThroughPixelFont() throws {
        let model = try source("Sources/ElysiumCore/Game/RPGScreenModel.swift")
        let renderer = try source("Sources/Elysium/RPGScreensM.swift")
        XCTAssertFalse(model.contains("visualLines: [\"‹\"]"))
        XCTAssertFalse(model.contains("visualLines: [\"›\"]"))
        XCTAssertTrue(model.contains("adornment: .carouselPrevious"))
        XCTAssertTrue(model.contains("adornment: .carouselNext"))
        XCTAssertTrue(renderer.contains("descriptor.adornment == .carouselPrevious"))
        XCTAssertTrue(renderer.contains("descriptor.adornment == .carouselNext"))
    }
}
