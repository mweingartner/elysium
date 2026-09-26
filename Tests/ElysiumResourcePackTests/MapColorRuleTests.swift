import XCTest
@testable import Elysium
@testable import ElysiumCore

/// The minimap resolves block-name colour rules once per registered block instead of once per
/// map cell per frame. These cases pin the precedence the former per-cell rules applied.
final class MapColorRuleTests: XCTestCase {
    override func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
    }

    private func rule(_ name: String) throws -> MapColorRule {
        let id = try XCTUnwrap(blockDefs.firstIndex { $0.name == name }, "missing block \(name)")
        return mapColorRules()[id]
    }

    func testTableCoversEveryRegisteredBlock() {
        XCTAssertEqual(mapColorRules().count, blockDefs.count)
    }

    func testBiomeTintedAndFluidRules() throws {
        XCTAssertEqual(try rule("water"), .water)
        XCTAssertEqual(try rule("lava"), .lava)
        XCTAssertEqual(try rule("grass_block"), .grass)
        XCTAssertEqual(try rule("short_grass"), .grass)
        XCTAssertEqual(try rule("oak_leaves"), .foliage)
    }

    func testDimensionMaterialsWinOverGenericSubstrings() throws {
        XCTAssertEqual(try rule("soul_sand"), .shaded(0x5b4b3b))
        XCTAssertEqual(try rule("netherrack"), .shaded(0x8a3030))
        XCTAssertEqual(try rule("end_stone"), .shaded(0xdbd88a))
        XCTAssertEqual(try rule("sandstone"), .shaded(0xd8c878))
        XCTAssertEqual(try rule("stone"), .shaded(0x858585))
        XCTAssertEqual(try rule("oak_planks"), .shaded(0x8a6236))
        XCTAssertEqual(try rule("dirt"), .shaded(0x7a5635))
    }

    func testDyedAndFallbackRules() throws {
        let red = try rule("red_wool")
        XCTAssertEqual(red, .shaded(Int(COLOR_RGB["red"] ?? 0xa0a0a0)))
        XCTAssertEqual(mapColorRule(id: 9_999, name: "mystery_lamp", solid: true, lightEmit: 12), .shaded(0xd0a65a))
        XCTAssertEqual(mapColorRule(id: 9_999, name: "mystery_block", solid: true, lightEmit: 0), .shaded(0x8a8a72))
        XCTAssertEqual(mapColorRule(id: 9_999, name: "mystery_plant", solid: false, lightEmit: 0), .shaded(0x66885a))
    }

    /// Verbatim transliteration of the per-cell chain removed from `mapColorForBlock` at
    /// 2459587 (`shadedMapColor(X, ...)` -> `.shaded(X)`), kept as an oracle for every id.
    private func legacyRule(id: Int) -> MapColorRule {
        let def = blockDefs[id]
        let name = def.name
        if id == Int(B.water) { return .water }
        if id == Int(B.lava) { return .lava }
        if name == "grass_block" || name == "short_grass" || name == "tall_grass" || name == "fern" || name == "large_fern" {
            return .grass
        }
        if name.contains("leaves") || name.contains("azalea") { return .foliage }
        if name == "soul_sand" || name == "soul_soil" { return .shaded(0x5b4b3b) }
        if name.contains("netherrack") || name.contains("crimson") { return .shaded(0x8a3030) }
        if name.contains("warped") { return .shaded(0x2f8f82) }
        if name.contains("basalt") || name.contains("blackstone") { return .shaded(0x3b3b42) }
        if name.contains("nether_brick") { return .shaded(0x4b1f28) }
        if name.contains("quartz") { return .shaded(0xd8d1c5) }
        if name.contains("end_stone") { return .shaded(0xdbd88a) }
        if name.contains("sand") || name.contains("sandstone") { return .shaded(0xd8c878) }
        if name.contains("snow") { return .shaded(0xf0f4f7) }
        if name.contains("ice") { return .shaded(0x9fd8f5) }
        if name.contains("dirt") || name.contains("mud") || name.contains("podzol") || name.contains("farmland") {
            return .shaded(0x7a5635)
        }
        if name.contains("stone") || name.contains("deepslate") || name.contains("ore") ||
            name.contains("andesite") || name.contains("diorite") || name.contains("granite") || name.contains("tuff") {
            return .shaded(0x858585)
        }
        if name.contains("planks") || name.contains("log") || name.contains("wood") || name.contains("stem") ||
            name.contains("hyphae") || name.contains("bamboo") {
            return .shaded(0x8a6236)
        }
        if name.contains("wool") || name.contains("concrete") || name.contains("terracotta") {
            for c in COLORS where name.hasPrefix(c + "_") {
                return .shaded(Int(COLOR_RGB[c] ?? 0xa0a0a0))
            }
        }
        if def.lightEmit > 0 { return .shaded(0xd0a65a) }
        return .shaded(def.solid ? 0x8a8a72 : 0x66885a)
    }

    func testEveryRegisteredBlockMatchesTheFormerPerCellRules() {
        let rules = mapColorRules()
        for id in 1..<blockDefs.count {
            XCTAssertEqual(rules[id], legacyRule(id: id), "block \(blockDefs[id].name)")
        }
    }
}
