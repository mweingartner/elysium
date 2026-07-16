import Foundation
import XCTest
@testable import ElysiumCore

final class CopperToolTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
        registerAllRecipes()
    }

    func testCopperToolsAreAppendedAndUseRequestedStats() throws {
        registerCoreIfNeeded()

        XCTAssertEqual(iid("copper_sword"), 1189)
        XCTAssertEqual(iid("copper_pickaxe"), 1190)
        XCTAssertEqual(iid("copper_axe"), 1191)
        XCTAssertEqual(iid("copper_shovel"), 1192)
        XCTAssertEqual(iid("copper_hoe"), 1193)

        let stonePick = try XCTUnwrap(itemDef(iid("stone_pickaxe")).tool)
        let ironPick = try XCTUnwrap(itemDef(iid("iron_pickaxe")).tool)
        let copperPick = try XCTUnwrap(itemDef(iid("copper_pickaxe")).tool)

        XCTAssertEqual(copperPick.tier, ironPick.tier)
        XCTAssertGreaterThan(copperPick.speed, stonePick.speed)
        XCTAssertLessThan(copperPick.speed, ironPick.speed)
        XCTAssertGreaterThan(copperPick.durability, stonePick.durability)
        XCTAssertLessThan(copperPick.durability, ironPick.durability)
        XCTAssertEqual(copperPick.durability, 190)

        let expectedTypes = [
            "copper_sword": "sword",
            "copper_pickaxe": "pickaxe",
            "copper_axe": "axe",
            "copper_shovel": "shovel",
            "copper_hoe": "hoe",
        ]
        for (name, type) in expectedTypes {
            let def = itemDef(iid(name))
            let tool = try XCTUnwrap(def.tool)
            XCTAssertEqual(tool.type, type)
            XCTAssertEqual(tool.tier, ironPick.tier)
            XCTAssertEqual(tool.durability, 190)
            XCTAssertGreaterThan(tool.enchantability, itemDef(iid("diamond_pickaxe")).tool?.enchantability ?? 0)
            XCTAssertLessThan(tool.enchantability, ironPick.enchantability)
            XCTAssertEqual(def.maxStack, 1)
        }
    }

    func testCopperPickaxeHarvestsIronTierBlocksButNotAncientDebris() {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 24680)
        let player = Player(world: world)
        player.mainHand = stack("copper_pickaxe")

        XCTAssertTrue(canHarvest(player, Int(cell(B.diamond_ore))))
        XCTAssertTrue(canHarvest(player, Int(cell(B.gold_ore))))
        XCTAssertTrue(canHarvest(player, Int(cell(B.redstone_ore))))
        XCTAssertFalse(canHarvest(player, Int(cell(B.ancient_debris))))

        player.mainHand = stack("stone_pickaxe")
        XCTAssertFalse(canHarvest(player, Int(cell(B.diamond_ore))))

        player.mainHand = stack("iron_pickaxe")
        XCTAssertTrue(canHarvest(player, Int(cell(B.diamond_ore))))
    }

    func testCopperPickaxeBreakSpeedSitsBetweenStoneAndIron() {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 13579)
        let player = Player(world: world)

        player.onGround = true
        player.mainHand = stack("stone_pickaxe")
        let stoneSpeed = breakSpeed(player, Int(cell(B.stone)))
        player.mainHand = stack("copper_pickaxe")
        let copperSpeed = breakSpeed(player, Int(cell(B.stone)))
        player.mainHand = stack("iron_pickaxe")
        let ironSpeed = breakSpeed(player, Int(cell(B.stone)))

        XCTAssertGreaterThan(copperSpeed, stoneSpeed)
        XCTAssertLessThan(copperSpeed, ironSpeed)
    }

    func testCopperToolRecipesUseStandardShapesWithCopperIngots() throws {
        registerCoreIfNeeded()

        func matchName(_ grid: [ItemStack?]) -> String? {
            matchCrafting(grid, 3, 3).map { itemDef($0.out.id).name }
        }
        let c = stack("copper_ingot")
        let s = stack("stick")

        XCTAssertEqual(matchName([nil, c, nil, nil, c, nil, nil, s, nil]), "copper_sword")
        XCTAssertEqual(matchName([c, c, c, nil, s, nil, nil, s, nil]), "copper_pickaxe")
        XCTAssertEqual(matchName([c, c, nil, c, s, nil, nil, s, nil]), "copper_axe")
        XCTAssertEqual(matchName([nil, c, nil, nil, s, nil, nil, s, nil]), "copper_shovel")
        XCTAssertEqual(matchName([c, c, nil, nil, s, nil, nil, s, nil]), "copper_hoe")

        let plans = craftingPlans(for: [stack("copper_ingot", 9), stack("stick", 10)], gridWidth: 3, gridHeight: 3)
        let outputs = Set(plans.map { itemDef($0.output.id).name })
        for name in ["copper_sword", "copper_pickaxe", "copper_axe", "copper_shovel", "copper_hoe"] {
            XCTAssertTrue(outputs.contains(name), "missing crafting plan for \(name)")
        }
    }

    func testCopperToolsRepairWithCopperIngots() throws {
        registerCoreIfNeeded()

        let damaged = ItemStack(iid("copper_pickaxe"), 1, damage: 95)
        let result = try XCTUnwrap(anvilCombine(damaged, stack("copper_ingot"), nil))

        XCTAssertEqual(itemDef(result.out.id).name, "copper_pickaxe")
        XCTAssertEqual(result.out.damage, 47)
        XCTAssertEqual(result.out.data.repairUnits, 1)
    }

    func testCopperToolIconsUseGeneratedCopperPalette() {
        registerCoreIfNeeded()

        withItemIconOverride(nil) {
            let names = ["copper_sword", "copper_pickaxe", "copper_axe", "copper_shovel", "copper_hoe"]
            let icons = names.map { itemIconPixels(iid($0)) }
            XCTAssertEqual(Set(icons.map(Data.init)).count, names.count)

            for pixels in icons {
                XCTAssertGreaterThan(nonTransparentPixelCount(pixels), 12)
                XCTAssertTrue(containsRGB(pixels, 0xf0b080) || containsRGB(pixels, 0xd0784f))
            }
            XCTAssertNotEqual(itemIconPixels(iid("copper_pickaxe")), itemIconPixels(iid("iron_pickaxe")))
            XCTAssertNotEqual(itemIconPixels(iid("copper_pickaxe")), itemIconPixels(iid("stone_pickaxe")))
        }
    }

    func testCopperToolIconsRecolorIronPackArtWhenCopperPackArtIsMissing() {
        registerCoreIfNeeded()
        let source = fakeIronToolIcon()
        let ironOverrides = Dictionary(uniqueKeysWithValues: ["sword", "pickaxe", "axe", "shovel", "hoe"].map {
            ("iron_\($0)", source)
        })

        withItemIconOverride({ ironOverrides[$0] }) {
            for name in ["copper_sword", "copper_pickaxe", "copper_axe", "copper_shovel", "copper_hoe"] {
                let copper = itemIconPixels(iid(name))
                XCTAssertEqual(alphaMask(copper), alphaMask(source), name)
                XCTAssertEqual(rgbAt(copper, 5, 5), 0x8a6a42, name)
                XCTAssertEqual(rgbAt(copper, 6, 6), 0x5a371c, name)
                XCTAssertTrue(isCopperTone(rgbAt(copper, 2, 2)), name)
                XCTAssertTrue(isCopperTone(rgbAt(copper, 3, 2)), name)
                XCTAssertTrue(isCopperTone(rgbAt(copper, 4, 2)), name)
                XCTAssertNotEqual(copper, source, name)
            }
        }
    }

    func testCopperToolPackArtOverridesRecolorFallback() {
        registerCoreIfNeeded()
        let source = fakeIronToolIcon()
        var providedCopper = [UInt8](repeating: 0, count: 16 * 16 * 4)
        setRGB(&providedCopper, 7, 7, 0x123456)

        withItemIconOverride({ name in
            if name == "copper_pickaxe" { return providedCopper }
            if name == "iron_pickaxe" { return source }
            return nil
        }) {
            XCTAssertEqual(itemIconPixels(iid("copper_pickaxe")), providedCopper)
        }
    }

    private func nonTransparentPixelCount(_ pixels: [UInt8]) -> Int {
        stride(from: 3, to: pixels.count, by: 4).filter { pixels[$0] != 0 }.count
    }

    private func containsRGB(_ pixels: [UInt8], _ rgb: Int) -> Bool {
        let r = UInt8((rgb >> 16) & 255)
        let g = UInt8((rgb >> 8) & 255)
        let b = UInt8(rgb & 255)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i] == r, pixels[i + 1] == g, pixels[i + 2] == b, pixels[i + 3] != 0 {
                return true
            }
        }
        return false
    }

    private func withItemIconOverride(_ override: ((String) -> [UInt8]?)?, _ body: () -> Void) {
        let atlas = buildAtlas()
        let overrides = Dictionary(uniqueKeysWithValues: itemDefs.compactMap { def in
            override?(def.name).map { (def.name, $0) }
        })
        _ = publishIconSourceSnapshot(IconSourceCandidate(atlas: atlas, itemOverrides: overrides)!)
        defer {
            _ = publishIconSourceSnapshot(IconSourceCandidate(atlas: atlas)!)
        }
        body()
    }

    private func fakeIronToolIcon() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: 16 * 16 * 4)
        setRGB(&pixels, 2, 2, 0xe8e8e8)
        setRGB(&pixels, 3, 2, 0xc8c8c8)
        setRGB(&pixels, 4, 2, 0x707070)
        setRGB(&pixels, 5, 5, 0x8a6a42)
        setRGB(&pixels, 6, 6, 0x5a371c)
        return pixels
    }

    private func setRGB(_ pixels: inout [UInt8], _ x: Int, _ y: Int, _ rgb: Int) {
        let i = (y * 16 + x) * 4
        pixels[i] = UInt8((rgb >> 16) & 255)
        pixels[i + 1] = UInt8((rgb >> 8) & 255)
        pixels[i + 2] = UInt8(rgb & 255)
        pixels[i + 3] = 255
    }

    private func rgbAt(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Int {
        let i = (y * 16 + x) * 4
        return (Int(pixels[i]) << 16) | (Int(pixels[i + 1]) << 8) | Int(pixels[i + 2])
    }

    private func alphaMask(_ pixels: [UInt8]) -> [UInt8] {
        stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] == 0 ? 0 : 1 }
    }

    private func isCopperTone(_ rgb: Int) -> Bool {
        let r = (rgb >> 16) & 255
        let g = (rgb >> 8) & 255
        let b = rgb & 255
        return r > g && g > b && r >= 110 && b <= 150
    }
}
