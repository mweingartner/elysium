import Foundation
import XCTest
@testable import ElysiumCore

final class CraftingPlanTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
        registerAllRecipes()
    }

    private func plan(named name: String, from inventory: [ItemStack?]) throws -> CraftingRecipePlan {
        registerCoreIfNeeded()
        return try XCTUnwrap(craftingPlans(for: inventory, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == name
        })
    }

    private func makeWorld(chunkRange: ClosedRange<Int> = -1...2) -> World {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 13579)
        let info = dimInfo(.overworld)
        for cz in chunkRange {
            for cx in chunkRange {
                let chunk = Chunk(cx: cx, cz: cz, minY: info.minY, height: info.height)
                chunk.status = .lit
                world.setChunk(chunk)
                world.light.initChunkLight(chunk)
            }
        }
        return world
    }

    func testCraftingPlansUseInventoryTagsAndPopulateShapedGrid() throws {
        registerCoreIfNeeded()
        var inventory: [ItemStack?] = [stack("oak_planks", 4)]
        var grid = [ItemStack?](repeating: nil, count: 9)
        let p = try plan(named: "crafting_table", from: inventory)

        XCTAssertTrue(populateCraftingGrid(p, grid: &grid, inventory: &inventory))
        XCTAssertNil(inventory[0])
        XCTAssertEqual(grid.compactMap { $0 }.count, 4)
        XCTAssertEqual(grid[0].map { itemDef($0.id).name }, "oak_planks")
        XCTAssertEqual(grid[1].map { itemDef($0.id).name }, "oak_planks")
        XCTAssertEqual(grid[3].map { itemDef($0.id).name }, "oak_planks")
        XCTAssertEqual(grid[4].map { itemDef($0.id).name }, "oak_planks")
        XCTAssertEqual(matchCrafting(grid, 3, 3)?.out.id, iid("crafting_table"))
    }

    func testShapelessPlanPopulatesAndConsumesInventory() throws {
        registerCoreIfNeeded()
        var inventory: [ItemStack?] = [stack("chest"), stack("tripwire_hook")]
        var grid = [ItemStack?](repeating: nil, count: 9)
        let p = try plan(named: "trapped_chest", from: inventory)

        XCTAssertTrue(populateCraftingGrid(p, grid: &grid, inventory: &inventory))
        XCTAssertNil(inventory[0])
        XCTAssertNil(inventory[1])
        XCTAssertEqual(grid[0].map { itemDef($0.id).name }, "chest")
        XCTAssertEqual(grid[1].map { itemDef($0.id).name }, "tripwire_hook")
        XCTAssertEqual(matchCrafting(grid, 3, 3)?.out.id, iid("trapped_chest"))
    }

    func testPlansDedupeDuplicateOutputRecipes() {
        registerCoreIfNeeded()
        let inventory: [ItemStack?] = [stack("cobblestone"), stack("vine"), stack("moss_block")]
        let outputs = craftingPlans(for: inventory, gridWidth: 3, gridHeight: 3).map { itemDef($0.output.id).name }

        XCTAssertEqual(outputs.filter { $0 == "mossy_cobblestone" }.count, 1)
    }

    func testPersonalCraftingPlansExcludeThreeByThreeOnlyRecipes() {
        registerCoreIfNeeded()
        let inventory: [ItemStack?] = [stack("oak_planks", 8)]
        let personalOutputs = craftingPlans(for: inventory, gridWidth: 2, gridHeight: 2).map { itemDef($0.output.id).name }
        let workbenchOutputs = craftingPlans(for: inventory, gridWidth: 3, gridHeight: 3).map { itemDef($0.output.id).name }

        XCTAssertTrue(personalOutputs.contains("crafting_table"))
        XCTAssertFalse(personalOutputs.contains("chest"))
        XCTAssertTrue(workbenchOutputs.contains("chest"))
    }

    func testFlyingWandRecipeUsesEmeraldDiamondTShape() throws {
        registerCoreIfNeeded()
        let recipe = try XCTUnwrap(craftingRecipes.first { recipe in
            if case .shaped(_, _, _, let out, _) = recipe { return out == FLYING_WAND_ITEM_NAME }
            return false
        })

        guard case .shaped(let w, let h, let grid, let out, let count) = recipe else {
            return XCTFail("flying wand recipe should be shaped")
        }
        XCTAssertEqual(w, 3)
        XCTAssertEqual(h, 3)
        XCTAssertEqual(out, FLYING_WAND_ITEM_NAME)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(grid, [
            "emerald", "diamond", "emerald",
            nil, "diamond", nil,
            nil, "diamond", nil,
        ])

        var craftingGrid = [ItemStack?](repeating: nil, count: 9)
        craftingGrid[0] = stack("emerald")
        craftingGrid[1] = stack("diamond")
        craftingGrid[2] = stack("emerald")
        craftingGrid[4] = stack("diamond")
        craftingGrid[7] = stack("diamond")

        XCTAssertEqual(matchCrafting(craftingGrid, 3, 3)?.out.id, iid(FLYING_WAND_ITEM_NAME))
    }

    func testPersonalCraftingPlanPopulatesTwoByTwoGrid() throws {
        registerCoreIfNeeded()
        var inventory: [ItemStack?] = [stack("oak_planks", 2)]
        var grid = [ItemStack?](repeating: nil, count: 4)
        let p = try XCTUnwrap(craftingPlans(for: inventory, gridWidth: 2, gridHeight: 2).first {
            itemDef($0.output.id).name == "stick"
        })

        XCTAssertTrue(populateCraftingGrid(p, grid: &grid, inventory: &inventory))
        XCTAssertNil(inventory[0])
        XCTAssertEqual(grid[0].map { itemDef($0.id).name }, "oak_planks")
        XCTAssertEqual(grid[2].map { itemDef($0.id).name }, "oak_planks")
        XCTAssertEqual(matchCrafting(grid, 2, 2)?.out.id, iid("stick"))
    }

    func testPopulateRejectsOccupiedGridWithoutMutatingInventory() throws {
        registerCoreIfNeeded()
        var inventory: [ItemStack?] = [stack("oak_planks", 2)]
        var grid = [ItemStack?](repeating: nil, count: 9)
        grid[0] = stack("dirt")
        let p = try plan(named: "stick", from: inventory)

        XCTAssertFalse(populateCraftingGrid(p, grid: &grid, inventory: &inventory))
        XCTAssertEqual(inventory[0]?.count, 2)
        XCTAssertEqual(grid[0].map { itemDef($0.id).name }, "dirt")
        XCTAssertNil(grid[1])
    }

    func testPlansCanUseReturnedBenchContentsForRecipeSwitching() throws {
        registerCoreIfNeeded()
        var inventory = [ItemStack?](repeating: nil, count: 9)
        let occupiedBench: [ItemStack?] = [stack("oak_planks", 2)]
        let p = try XCTUnwrap(craftingPlans(for: inventory + occupiedBench, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "stick"
        })

        inventory[0] = occupiedBench[0]
        var grid = [ItemStack?](repeating: nil, count: 9)
        XCTAssertTrue(populateCraftingGrid(p, grid: &grid, inventory: &inventory))
        XCTAssertNil(inventory[0])
        XCTAssertEqual(grid[0].map { itemDef($0.id).name }, "oak_planks")
        XCTAssertEqual(grid[3].map { itemDef($0.id).name }, "oak_planks")
        XCTAssertEqual(matchCrafting(grid, 3, 3)?.out.id, iid("stick"))
    }

    func testCraftingPoolPlansUseNearbyContainerResources() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 8)
        world.setBlockEntity(chest)

        let resources = craftingResourceStacks(playerInventory: [], craftGrid: [], world: world,
                                               centerX: 1, centerY: 64, centerZ: 1, radius: CRAFTING_CONTAINER_RADIUS)
        let outputs = craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).map { itemDef($0.output.id).name }

        XCTAssertTrue(outputs.contains("chest"))
    }

    func testCraftingPoolRecipeSelectionConsumesNearbyContainerResources() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 8)
        world.setBlockEntity(chest)
        var inventory = [ItemStack?](repeating: nil, count: 36)
        var grid = [ItemStack?](repeating: nil, count: 9)
        let resources = craftingResourceStacks(playerInventory: inventory, craftGrid: grid, world: world,
                                               centerX: 1, centerY: 64, centerZ: 1, radius: CRAFTING_CONTAINER_RADIUS)
        let p = try XCTUnwrap(craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "chest"
        })

        XCTAssertTrue(populateCraftingGridFromNearbyContainers(p, grid: &grid, inventory: &inventory, world: world,
                                                               centerX: 1, centerY: 64, centerZ: 1,
                                                               radius: CRAFTING_CONTAINER_RADIUS))

        XCTAssertNil(chest.items?[0])
        XCTAssertEqual(grid.compactMap { $0 }.count, 8)
        XCTAssertEqual(matchCrafting(grid, 3, 3)?.out.id, iid("chest"))
    }

    func testCraftingPoolConsumesPlayerInventoryBeforeNearbyContainers() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 3)
        world.setBlockEntity(chest)
        var inventory = [ItemStack?](repeating: nil, count: 36)
        inventory[0] = stack("oak_planks", 1)
        var grid = [ItemStack?](repeating: nil, count: 9)
        let resources = craftingResourceStacks(playerInventory: inventory, craftGrid: grid, world: world,
                                               centerX: 1, centerY: 64, centerZ: 1, radius: CRAFTING_CONTAINER_RADIUS)
        let p = try XCTUnwrap(craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "crafting_table"
        })

        XCTAssertTrue(populateCraftingGridFromNearbyContainers(p, grid: &grid, inventory: &inventory, world: world,
                                                               centerX: 1, centerY: 64, centerZ: 1,
                                                               radius: CRAFTING_CONTAINER_RADIUS))

        XCTAssertNil(inventory[0])
        XCTAssertNil(chest.items?[0])
        XCTAssertEqual(grid.compactMap { $0 }.count, 4)
        XCTAssertEqual(matchCrafting(grid, 3, 3)?.out.id, iid("crafting_table"))
    }

    func testCraftingPoolIncludesContainerAtExactRadiusAndExcludesOneBeyond() {
        let world = makeWorld(chunkRange: -1...4)
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        world.setBlock(51, 64, 1, Int(cell(B.chest)))
        let included = makeContainerBE(51, 64, 1, 27)
        included.items?[0] = stack("oak_planks", 8)
        world.setBlockEntity(included)
        world.setBlock(52, 64, 1, Int(cell(B.chest)))
        let excluded = makeContainerBE(52, 64, 1, 27)
        excluded.items?[0] = stack("oak_planks", 8)
        world.setBlockEntity(excluded)

        let resources = craftingResourceStacks(playerInventory: [], craftGrid: [], world: world,
                                               centerX: 1, centerY: 64, centerZ: 1, radius: CRAFTING_CONTAINER_RADIUS)
        let totalPlanks = resources.compactMap { $0 }
            .filter { itemDef($0.id).name == "oak_planks" }
            .reduce(0) { $0 + $1.count }

        XCTAssertEqual(totalPlanks, 8, "only the exact-distance-50 container should contribute")
        XCTAssertEqual(excluded.items?[0]?.count, 8, "the distance-51 container must be untouched")
    }

    func testCraftingPoolUsesNearbyChestVehicles() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        let boat = Boat(world: world)
        boat.hasChest = true
        boat.x = 3.5
        boat.y = 64
        boat.z = 1.5
        boat.chestItems[0] = stack("oak_planks", 4)
        world.addEntity(boat)
        var inventory = [ItemStack?](repeating: nil, count: 36)
        var grid = [ItemStack?](repeating: nil, count: 9)
        let resources = craftingResourceStacks(playerInventory: inventory, craftGrid: grid, world: world,
                                               centerX: 1, centerY: 64, centerZ: 1, radius: CRAFTING_CONTAINER_RADIUS)
        let p = try XCTUnwrap(craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "crafting_table"
        })

        XCTAssertTrue(populateCraftingGridFromNearbyContainers(p, grid: &grid, inventory: &inventory, world: world,
                                                               centerX: 1, centerY: 64, centerZ: 1,
                                                               radius: CRAFTING_CONTAINER_RADIUS))

        XCTAssertNil(boat.chestItems[0])
        XCTAssertEqual(matchCrafting(grid, 3, 3)?.out.id, iid("crafting_table"))
    }

    func testCraftingPlanSearchMatchesDisplayNamesAndItemIds() throws {
        registerCoreIfNeeded()
        let plans = craftingPlans(for: [stack("oak_planks", 8)], gridWidth: 3, gridHeight: 3)

        let displayMatch = try XCTUnwrap(firstCraftingPlanIndex(matching: "craft", in: plans))
        XCTAssertEqual(itemDef(plans[displayMatch].output.id).name, "crafting_table")

        let containsMatch = try XCTUnwrap(firstCraftingPlanIndex(matching: "table", in: plans))
        XCTAssertEqual(itemDef(plans[containsMatch].output.id).name, "crafting_table")

        let idMatch = try XCTUnwrap(firstCraftingPlanIndex(matching: "crafting_table", in: plans))
        XCTAssertEqual(itemDef(plans[idMatch].output.id).name, "crafting_table")
    }

    func testCraftingPlanSearchPrefersPrefixBeforeContainsFallback() throws {
        registerCoreIfNeeded()
        let plans = creativeCraftingPlans(gridWidth: 3, gridHeight: 3)

        let stone = try XCTUnwrap(firstCraftingPlanIndex(matching: "stone", in: plans))
        XCTAssertTrue(itemDef(plans[stone].output.id).displayName.lowercased().hasPrefix("stone"))

        let ingot = try XCTUnwrap(firstCraftingPlanIndex(matching: "ingot", in: plans))
        XCTAssertTrue(itemDef(plans[ingot].output.id).displayName.lowercased().contains("ingot"))
    }

    func testFilteredCraftingPlansContainsEveryMatchOnceInCanonicalOrder() {
        registerCoreIfNeeded()
        let plans = creativeCraftingPlans(gridWidth: 3, gridHeight: 3)
        let filtered = filteredCraftingPlans(plans, query: "door")

        XCTAssertFalse(filtered.isEmpty)
        XCTAssertTrue(filtered.allSatisfy { craftingPlanMatchesSearch($0, query: "door") })
        XCTAssertEqual(filtered.map(\.recipeIndex), plans.filter {
            craftingPlanMatchesSearch($0, query: "door")
        }.map(\.recipeIndex))
        XCTAssertEqual(Set(filtered.map(\.recipeIndex)).count, filtered.count)
        XCTAssertEqual(filteredCraftingPlans(plans, query: "" ).map(\.recipeIndex), plans.map(\.recipeIndex))
    }

    func testCraftingPlanSearchNormalizesCaseWhitespaceAndPunctuation() {
        XCTAssertEqual(normalizedCraftingPlanSearch("  Crafting_Table!! "), "crafting table")
        XCTAssertEqual(normalizedCraftingPlanSearch("OAK   DOOR"), "oak door")
        XCTAssertNil(firstCraftingPlanIndex(matching: "", in: []))
    }

    func testCraftingRecipeTypeaheadCorrectsMistypeAndSelectsHighlightedPlan() throws {
        registerCoreIfNeeded()
        let plans = craftingPlans(for: [stack("oak_planks", 8)], gridWidth: 3, gridHeight: 3)
        var typeahead = CraftingRecipeTypeahead(maxRows: 4, maxQueryLength: 16)

        typeahead.open(plans: plans)
        XCTAssertEqual(typeahead.query, "")
        XCTAssertEqual(typeahead.highlightedIndex, 0)

        XCTAssertTrue(typeahead.append("craftx", plans: plans))
        XCTAssertEqual(typeahead.query, "craftx")
        XCTAssertNil(typeahead.selectedPlan(in: plans))

        XCTAssertTrue(typeahead.deleteBackward(plans: plans))
        let selected = try XCTUnwrap(typeahead.selectedPlan(in: plans))
        XCTAssertEqual(typeahead.query, "craft")
        XCTAssertEqual(itemDef(selected.output.id).name, "crafting_table")
    }

    func testCraftingRecipeTypeaheadKeyboardNavigationKeepsHighlightVisible() {
        registerCoreIfNeeded()
        let plans = creativeCraftingPlans(gridWidth: 3, gridHeight: 3)
        XCTAssertGreaterThan(plans.count, 4)
        var typeahead = CraftingRecipeTypeahead(maxRows: 2, maxQueryLength: 16)

        typeahead.open(plans: plans)
        typeahead.moveHighlight(3, plans: plans)
        XCTAssertEqual(typeahead.highlightedIndex, 3)
        XCTAssertEqual(typeahead.scroll, 2)

        typeahead.moveHighlight(-2, plans: plans)
        XCTAssertEqual(typeahead.highlightedIndex, 1)
        XCTAssertEqual(typeahead.scroll, 1)
    }

    func testCraftingRecipeTypeaheadRefreshPreservesManualScroll() {
        registerCoreIfNeeded()
        let plans = creativeCraftingPlans(gridWidth: 3, gridHeight: 3)
        XCTAssertGreaterThan(plans.count, 8)
        var typeahead = CraftingRecipeTypeahead(maxRows: 4, maxQueryLength: 16)

        typeahead.open(plans: plans)
        typeahead.scrollRows(3, plans: plans)
        XCTAssertEqual(typeahead.scroll, 3)
        XCTAssertEqual(typeahead.highlightedIndex, 3)

        typeahead.refresh(plans: plans)
        XCTAssertEqual(typeahead.scroll, 3)
        XCTAssertEqual(typeahead.highlightedIndex, 3)
    }

    func testCraftingRecipeTypeaheadRefreshPreservesScrolledSearchSelection() throws {
        registerCoreIfNeeded()
        let plans = creativeCraftingPlans(gridWidth: 3, gridHeight: 3)
        var typeahead = CraftingRecipeTypeahead(maxRows: 3, maxQueryLength: 16)

        typeahead.open(plans: plans)
        XCTAssertTrue(typeahead.append("door", plans: plans))
        _ = try XCTUnwrap(typeahead.highlightedIndex)
        let searchScroll = typeahead.scroll

        typeahead.scrollRows(4, plans: plans)
        XCTAssertGreaterThan(typeahead.scroll, searchScroll)
        XCTAssertGreaterThan(typeahead.scroll, 0)

        typeahead.refresh(plans: plans)
        XCTAssertEqual(typeahead.scroll, 0)
        XCTAssertEqual(typeahead.highlightedIndex, 0)
        XCTAssertTrue(typeahead.matchingPlans(in: plans).allSatisfy {
            craftingPlanMatchesSearch($0, query: "door")
        })
    }

    func testCraftingRecipeTypeaheadFiltersCorrectionNavigationAndSelection() throws {
        registerCoreIfNeeded()
        let plans = creativeCraftingPlans(gridWidth: 3, gridHeight: 3)
        var typeahead = CraftingRecipeTypeahead(maxRows: 2, maxQueryLength: 16)

        typeahead.open(plans: plans)
        XCTAssertTrue(typeahead.append("door", plans: plans))
        let matches = typeahead.matchingPlans(in: plans)
        XCTAssertGreaterThan(matches.count, 2)
        XCTAssertEqual(typeahead.highlightedIndex, 0)
        XCTAssertEqual(typeahead.selectedPlan(in: plans)?.recipeIndex, matches[0].recipeIndex)

        typeahead.moveHighlight(2, plans: plans)
        XCTAssertEqual(typeahead.highlightedIndex, 2)
        XCTAssertEqual(typeahead.scroll, 1)
        XCTAssertEqual(typeahead.selectedPlan(in: plans)?.recipeIndex, matches[2].recipeIndex)

        XCTAssertTrue(typeahead.append("zzz", plans: plans))
        XCTAssertTrue(typeahead.matchingPlans(in: plans).isEmpty)
        XCTAssertNil(typeahead.highlightedIndex)
        XCTAssertNil(typeahead.selectedPlan(in: plans))
        typeahead.moveHighlight(1, plans: plans)
        typeahead.scrollRows(1, plans: plans)
        XCTAssertNil(typeahead.selectedPlan(in: plans))

        XCTAssertTrue(typeahead.deleteBackward(plans: plans))
        XCTAssertTrue(typeahead.deleteBackward(plans: plans))
        XCTAssertTrue(typeahead.deleteBackward(plans: plans))
        XCTAssertEqual(typeahead.query, "door")
        XCTAssertEqual(typeahead.highlightedIndex, 0)
        XCTAssertEqual(typeahead.scroll, 0)
        XCTAssertEqual(typeahead.selectedPlan(in: plans)?.recipeIndex, matches[0].recipeIndex)
    }

    func testCraftingRecipeTypeaheadDeletionRestoresFullListAndRefreshUsesCurrentMatches() {
        registerCoreIfNeeded()
        let plans = creativeCraftingPlans(gridWidth: 3, gridHeight: 3)
        var typeahead = CraftingRecipeTypeahead(maxRows: 3, maxQueryLength: 16)

        typeahead.open(plans: plans)
        XCTAssertTrue(typeahead.append("door", plans: plans))
        let matches = typeahead.matchingPlans(in: plans)
        XCTAssertFalse(matches.isEmpty)
        typeahead.refresh(plans: Array(plans.reversed()))
        XCTAssertEqual(typeahead.highlightedIndex, 0)
        XCTAssertEqual(typeahead.scroll, 0)
        XCTAssertEqual(typeahead.selectedPlan(in: Array(plans.reversed()))?.recipeIndex,
                       Array(matches.reversed()).first?.recipeIndex)

        for _ in 0..<4 { XCTAssertTrue(typeahead.deleteBackward(plans: plans)) }
        XCTAssertEqual(typeahead.query, "")
        XCTAssertEqual(typeahead.matchingPlans(in: plans).map(\.recipeIndex), plans.map(\.recipeIndex))
        XCTAssertEqual(typeahead.highlightedIndex, 0)
        XCTAssertEqual(typeahead.scroll, 0)
    }

    func testCraftingRecipeTypeaheadIgnoresControlTextAndLimitsQuery() {
        registerCoreIfNeeded()
        let plans = creativeCraftingPlans(gridWidth: 3, gridHeight: 3)
        var typeahead = CraftingRecipeTypeahead(maxRows: 8, maxQueryLength: 16)

        typeahead.open(plans: plans)
        XCTAssertFalse(typeahead.append("\u{7f}\n", plans: plans))
        XCTAssertEqual(typeahead.query, "")

        XCTAssertTrue(typeahead.append("oak door", plans: plans))
        XCTAssertEqual(typeahead.query, "oak door")
        let topMatch = typeahead.selectedPlan(in: plans).map { itemDef($0.output.id).name }
        XCTAssertEqual(topMatch, typeahead.matchingPlans(in: plans).first.map { itemDef($0.output.id).name })
        XCTAssertTrue(topMatch?.contains("oak_door") ?? false)

        var limited = CraftingRecipeTypeahead(maxRows: 8, maxQueryLength: 4)
        limited.open(plans: plans)
        XCTAssertTrue(limited.append("oak door", plans: plans))
        XCTAssertEqual(limited.query, "door")
        XCTAssertTrue(limited.selectedPlan(in: plans).map { itemDef($0.output.id).name.contains("door") } ?? false)
    }

    func testCraftingPlansRejectInvalidGridSizes() {
        registerCoreIfNeeded()
        XCTAssertTrue(craftingPlans(for: [stack("oak_planks", 4)], gridWidth: 0, gridHeight: 3).isEmpty)
        XCTAssertTrue(craftingPlans(for: [stack("oak_planks", 4)], gridWidth: 3, gridHeight: 0).isEmpty)
        XCTAssertTrue(craftingPlans(for: [stack("oak_planks", 4)], gridWidth: 9, gridHeight: 9).isEmpty)
        XCTAssertTrue(creativeCraftingPlans(gridWidth: 0, gridHeight: 3).isEmpty)
        XCTAssertTrue(creativeCraftingPlans(gridWidth: 3, gridHeight: 0).isEmpty)
        XCTAssertTrue(creativeCraftingPlans(gridWidth: 9, gridHeight: 9).isEmpty)
    }

    func testCreativeCraftingPlansIgnoreInventoryAndExposeAllFittingOutputs() {
        registerCoreIfNeeded()

        let survival = craftingPlans(for: [], gridWidth: 3, gridHeight: 3)
        let creative = creativeCraftingPlans(gridWidth: 3, gridHeight: 3)
        let creativeKeys = Set(creative.map(outputKey))
        let expectedKeys = Set(craftingRecipes.compactMap { recipe -> String? in
            recipeFits(recipe, gridWidth: 3, gridHeight: 3) ? outputKey(craftingRecipeOutput(recipe)) : nil
        })

        XCTAssertTrue(survival.isEmpty)
        XCTAssertEqual(creativeKeys, expectedKeys)
        XCTAssertTrue(creativeKeys.contains("chest#1"))
    }

    func testCreativeCraftingTablePlansExposeEveryFittingRecipeEntry() {
        registerCoreIfNeeded()

        let plans = creativeCraftingPlans(gridWidth: 3, gridHeight: 3)
        let expectedCount = craftingRecipes.filter {
            recipeFits($0, gridWidth: 3, gridHeight: 3)
        }.count
        let uniqueOutputs = Set(plans.map(outputKey))

        XCTAssertEqual(plans.count, expectedCount)
        XCTAssertGreaterThan(plans.count, uniqueOutputs.count)
        XCTAssertTrue(plans.contains { itemDef($0.output.id).name == "chest" })
        XCTAssertTrue(plans.contains { itemDef($0.output.id).name == "copper_pickaxe" })
    }

    func testCreativePersonalCraftingPlansExposeEveryFittingTwoByTwoRecipeEntry() {
        registerCoreIfNeeded()

        let plans = creativeCraftingPlans(gridWidth: 2, gridHeight: 2)
        let expectedCount = craftingRecipes.filter {
            recipeFits($0, gridWidth: 2, gridHeight: 2)
        }.count
        let outputs = Set(plans.map { itemDef($0.output.id).name })

        XCTAssertEqual(plans.count, expectedCount)
        XCTAssertTrue(outputs.contains("crafting_table"))
        XCTAssertTrue(outputs.contains("stick"))
        XCTAssertFalse(outputs.contains("chest"))
        XCTAssertLessThan(plans.count, creativeCraftingPlans(gridWidth: 3, gridHeight: 3).count)
    }

    func testCreativeCraftingPlansStillRespectPersonalGridSize() {
        registerCoreIfNeeded()

        let personalOutputs = Set(creativeCraftingPlans(gridWidth: 2, gridHeight: 2).map { itemDef($0.output.id).name })
        let workbenchOutputs = Set(creativeCraftingPlans(gridWidth: 3, gridHeight: 3).map { itemDef($0.output.id).name })

        XCTAssertTrue(personalOutputs.contains("crafting_table"))
        XCTAssertFalse(personalOutputs.contains("chest"))
        XCTAssertTrue(workbenchOutputs.contains("chest"))
    }

    func testCreativeCraftingPlansChooseRepresentativeIngredientsForTags() throws {
        registerCoreIfNeeded()

        let plan = try XCTUnwrap(creativeCraftingPlans(gridWidth: 2, gridHeight: 2).first {
            itemDef($0.output.id).name == "crafting_table"
        })

        XCTAssertEqual(plan.ingredients.compactMap { $0 }.count, 4)
        for ingredient in plan.ingredients.compactMap({ $0 }) {
            XCTAssertTrue(itemExists(ingredient), "creative plan used unknown representative item \(ingredient)")
            XCTAssertTrue(tagMatches("planks", ingredient))
        }
    }

    func testCraftingRoundLimitUsesConcreteInventoryResources() throws {
        registerCoreIfNeeded()
        let plan = try XCTUnwrap(craftingPlans(for: [stack("oak_planks", 9)], gridWidth: 2, gridHeight: 2).first {
            itemDef($0.output.id).name == "crafting_table"
        })

        XCTAssertEqual(maxCraftingRounds(plan, from: [stack("oak_planks", 9)]), 2)
        XCTAssertEqual(maxCraftingRounds(plan, from: [stack("oak_planks", 3)]), 0)
    }

    func testCurrentCraftingPlanSupportsManualStackedGridRoundCounts() throws {
        registerCoreIfNeeded()
        var grid = [ItemStack?](repeating: nil, count: 4)
        grid[0] = stack("oak_planks", 3)
        grid[2] = stack("oak_planks", 3)

        let plan = try XCTUnwrap(currentCraftingPlan(from: grid, gridWidth: 2, gridHeight: 2))

        XCTAssertEqual(itemDef(plan.output.id).name, "stick")
        XCTAssertEqual(plan.output.count, 4)
        XCTAssertEqual(maxCraftingRounds(plan, from: grid), 3)

        _ = consumeCraftingGrid(&grid)
        _ = consumeCraftingGrid(&grid)
        _ = consumeCraftingGrid(&grid)
        XCTAssertTrue(grid.allSatisfy { $0 == nil })

        var inventory: [ItemStack?] = [stack("oak_planks", 2)]
        XCTAssertTrue(populateCraftingGrid(plan, grid: &grid, inventory: &inventory))
        XCTAssertEqual(matchCrafting(grid, 2, 2)?.out.id, iid("stick"))
        XCTAssertNil(inventory[0])
    }

    func testCraftingPoolRoundLimitIncludesNearbyContainerResources() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 12)
        world.setBlockEntity(chest)
        let resources = craftingResourceStacks(playerInventory: [], craftGrid: [], world: world,
                                               centerX: 1, centerY: 64, centerZ: 1, radius: CRAFTING_CONTAINER_RADIUS)
        let plan = try XCTUnwrap(craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "crafting_table"
        })

        XCTAssertEqual(maxCraftingRounds(plan, from: resources), 3)
    }

    func testProductionCraftCommitTransfersAndAwardsOnlyBackedPersonalRounds() throws {
        registerCoreIfNeeded()
        let world = makeWorld()
        let player = Player(world: world)
        player.rpg = try rpgCreateCharacter(RPGCreationDraft(
            pathID: "mender",
            attributes: try XCTUnwrap(rpgCreationPreset(pathID: "mender")),
            starterSkillID: "herbal_lore"
        )).get()
        var resources: [ItemStack?] = [
            stack("brown_mushroom", 3), stack("red_mushroom", 3), stack("bowl", 3),
        ]
        var grid = [ItemStack?](repeating: nil, count: 4)
        let recipe = try XCTUnwrap(craftingPlans(
            for: resources, gridWidth: 2, gridHeight: 2
        ).first { itemDef($0.output.id).name == "mushroom_stew" })
        XCTAssertTrue(populateCraftingGrid(recipe, grid: &grid, inventory: &resources))
        let preview = recipe.output.copy()
        preview.count = recipe.output.count * 3
        var successfulRefills = 0

        let commit = try XCTUnwrap(commitCraftingOutputRounds(
            player: player, grid: &grid, gridWidth: 2, gridHeight: 2,
            plan: recipe, displayedOutput: preview, requestedRounds: 3
        ) { nextGrid in
            guard successfulRefills < 1 else { return false }
            successfulRefills += 1
            return populateCraftingGrid(recipe, grid: &nextGrid, inventory: &resources)
        })

        XCTAssertEqual(commit.completedRounds, 2)
        XCTAssertEqual(commit.output.id, recipe.output.id)
        XCTAssertEqual(commit.output.count, recipe.output.count * 2,
                       "a failed final refill cannot mint the third previewed output")
        XCTAssertEqual(commit.progression.awardedXP, 12)
        XCTAssertEqual(player.rpg.xp, 12,
                       "progression must observe the same two committed rounds as output transfer")
        XCTAssertTrue(grid.allSatisfy { $0 == nil })
        XCTAssertEqual(resources.compactMap { $0?.count }, [1, 1, 1])
    }

    func testProductionCraftCommitTransfersAndAwardsOnlyBackedTableRounds() throws {
        registerCoreIfNeeded()
        let world = makeWorld()
        let player = Player(world: world)
        player.rpg = try rpgCreateCharacter(RPGCreationDraft(
            pathID: "tinker",
            attributes: try XCTUnwrap(rpgCreationPreset(pathID: "tinker")),
            starterSkillID: "circuit_sense"
        )).get()
        var resources: [ItemStack?] = [
            stack("redstone_torch", 8), stack("redstone", 4), stack("stone", 12),
        ]
        var grid = [ItemStack?](repeating: nil, count: 9)
        let recipe = try XCTUnwrap(craftingPlans(
            for: resources, gridWidth: 3, gridHeight: 3
        ).first { itemDef($0.output.id).name == "repeater" })
        XCTAssertTrue(populateCraftingGrid(recipe, grid: &grid, inventory: &resources))
        let preview = recipe.output.copy()
        preview.count = recipe.output.count * 4
        var successfulRefills = 0

        let commit = try XCTUnwrap(commitCraftingOutputRounds(
            player: player, grid: &grid, gridWidth: 3, gridHeight: 3,
            plan: recipe, displayedOutput: preview, requestedRounds: 4
        ) { nextGrid in
            guard successfulRefills < 2 else { return false }
            successfulRefills += 1
            return populateCraftingGrid(recipe, grid: &nextGrid, inventory: &resources)
        })

        XCTAssertEqual(commit.completedRounds, 3)
        XCTAssertEqual(commit.output.count, recipe.output.count * 3)
        XCTAssertEqual(commit.progression.awardedXP, 22,
                       "one first-recipe event plus three backed engineering rounds")
        XCTAssertEqual(player.rpg.xp, 22)
        XCTAssertTrue(grid.allSatisfy { $0 == nil })
        XCTAssertEqual(resources.compactMap { $0?.count }, [2, 1, 3])
    }

    func testCreativeCraftingRoundLimitFillsInventoryCapacity() throws {
        registerCoreIfNeeded()
        let plan = try XCTUnwrap(creativeCraftingPlans(gridWidth: 2, gridHeight: 2).first {
            itemDef($0.output.id).name == "stick"
        })
        var inventory = [ItemStack?](repeating: nil, count: 36)

        XCTAssertEqual(maxCreativeCraftingRounds(plan, into: inventory), 36 * 64 / plan.output.count)

        inventory[0] = stack("stick", 60)
        inventory[1] = stack("cobblestone", 64)
        XCTAssertEqual(inventoryInsertionCapacity(for: plan.output, into: inventory), 4 + 34 * 64)
    }

    func testRegisteredCraftingRecipesResolveKnownItemsAndTags() {
        registerCoreIfNeeded()

        for recipe in craftingRecipes {
            switch recipe {
            case .shaped(_, _, let grid, let out, _):
                XCTAssertTrue(itemExists(out), "unknown recipe output \(out)")
                for ingredient in grid.compactMap({ $0 }) {
                    assertKnownIngredient(ingredient)
                }
            case .shapeless(let inputs, let out, _):
                XCTAssertTrue(itemExists(out), "unknown recipe output \(out)")
                for ingredient in inputs {
                    assertKnownIngredient(ingredient)
                }
            }
        }
    }

    // MARK: - Player-centered pooling (radius 50, LAN gate, bounded scan, deposit filter)

    private func itemCounts(_ groups: [[ItemStack?]]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for group in groups {
            for stack in group {
                guard let stack, stack.count > 0 else { continue }
                counts[itemDef(stack.id).name, default: 0] += stack.count
            }
        }
        return counts
    }

    func testCraftingPoolConservesTotalItemsAcrossSuccessfulPopulate() throws {
        let world = makeWorld()
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("chest", 1)
        world.setBlockEntity(chest)
        var inventory: [ItemStack?] = [stack("oak_planks", 1)]
        var grid = [ItemStack?](repeating: nil, count: 4)
        let plan = CraftingRecipePlan(recipeIndex: 0, recipe: craftingRecipes[0],
                                      output: ItemStack(iid("stick"), 1),
                                      ingredients: ["oak_planks", "chest", nil, nil])
        let before = itemCounts([inventory, grid, chest.items ?? []])

        XCTAssertTrue(populateCraftingGridFromNearbyContainers(plan, grid: &grid, inventory: &inventory, world: world,
                                                               centerX: 1, centerY: 64, centerZ: 1,
                                                               radius: CRAFTING_CONTAINER_RADIUS))

        let after = itemCounts([inventory, grid, chest.items ?? []])
        XCTAssertEqual(before, after, "the multiset of items across inventory/grid/containers must be unchanged")
        XCTAssertEqual(after["oak_planks"], 1)
        XCTAssertEqual(after["chest"], 1)
    }

    func testCraftingPoolRollsBackAtomicallyOnFailedPopulateIncludingVehicleOwner() throws {
        let world = makeWorld()
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("chest", 1)
        world.setBlockEntity(chest)
        let boat = Boat(world: world)
        boat.hasChest = true
        boat.x = 2.5
        boat.y = 64
        boat.z = 1.5
        boat.chestItems[0] = stack("tripwire_hook", 1)
        world.addEntity(boat)
        var inventory: [ItemStack?] = [stack("oak_planks", 1)]
        var grid = [ItemStack?](repeating: nil, count: 4)
        // "diamond" is unavailable anywhere, so withdrawal only fails after the first three
        // ingredients (inventory, chest, boat) have already been decremented — proving the
        // rollback restores every touched owner, including a vehicle.
        let plan = CraftingRecipePlan(recipeIndex: 0, recipe: craftingRecipes[0],
                                      output: ItemStack(iid("stick"), 1),
                                      ingredients: ["oak_planks", "chest", "tripwire_hook", "diamond"])
        let inventorySnapshot = itemCounts([inventory])
        let gridSnapshot = itemCounts([grid])
        let chestSnapshot = itemCounts([chest.items ?? []])
        let boatSnapshot = itemCounts([boat.chestItems])

        XCTAssertFalse(populateCraftingGridFromNearbyContainers(plan, grid: &grid, inventory: &inventory, world: world,
                                                                centerX: 1, centerY: 64, centerZ: 1,
                                                                radius: CRAFTING_CONTAINER_RADIUS))

        XCTAssertEqual(itemCounts([inventory]), inventorySnapshot)
        XCTAssertEqual(itemCounts([grid]), gridSnapshot)
        XCTAssertEqual(itemCounts([chest.items ?? []]), chestSnapshot)
        XCTAssertEqual(itemCounts([boat.chestItems]), boatSnapshot)
        XCTAssertTrue(grid.allSatisfy { $0 == nil })
    }

    func testGiveStackToNearbyCraftingContainersSkipsFurnaceAndBrewingDeposits() {
        let world = makeWorld()
        world.setBlock(2, 64, 1, Int(cell(B.furnace)))
        let furnace = makeFurnaceBE(2, 64, 1, "furnace")
        world.setBlockEntity(furnace)
        world.setBlock(3, 64, 1, Int(cell(B.brewing_stand)))
        let brewing = makeBrewingBE(3, 64, 1)
        world.setBlockEntity(brewing)
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        world.setBlockEntity(chest)
        let returned = stack("oak_planks", 4)

        XCTAssertTrue(giveStackToNearbyCraftingContainers(returned, world: world,
                                                           centerX: 1, centerY: 64, centerZ: 1,
                                                           radius: CRAFTING_CONTAINER_RADIUS))

        XCTAssertTrue((furnace.items ?? []).allSatisfy { $0 == nil },
                      "furnace input/fuel/output must never receive a crafting-grid return deposit")
        XCTAssertTrue((brewing.items ?? []).allSatisfy { $0 == nil },
                      "brewing input must never receive a crafting-grid return deposit")
        XCTAssertEqual(chest.items?[0]?.count, 4, "general storage remains a valid deposit target")
    }

    func testCraftingPoolWithdrawsFromFurnaceOutputSlot() throws {
        let world = makeWorld()
        world.setBlock(2, 64, 1, Int(cell(B.furnace)))
        let furnace = makeFurnaceBE(2, 64, 1, "furnace")
        furnace.items?[2] = stack("iron_ingot", 3)
        world.setBlockEntity(furnace)

        let resources = craftingResourceStacks(playerInventory: [], craftGrid: [], world: world,
                                               centerX: 1, centerY: 64, centerZ: 1, radius: CRAFTING_CONTAINER_RADIUS)
        XCTAssertEqual(resources.compactMap { $0 }.filter { itemDef($0.id).name == "iron_ingot" }
            .reduce(0) { $0 + $1.count }, 3)

        var inventory: [ItemStack?] = []
        var grid = [ItemStack?](repeating: nil, count: 4)
        let plan = CraftingRecipePlan(recipeIndex: 0, recipe: craftingRecipes[0],
                                      output: ItemStack(iid("stick"), 1),
                                      ingredients: ["iron_ingot", nil, nil, nil])

        XCTAssertTrue(populateCraftingGridFromNearbyContainers(plan, grid: &grid, inventory: &inventory, world: world,
                                                               centerX: 1, centerY: 64, centerZ: 1,
                                                               radius: CRAFTING_CONTAINER_RADIUS))

        XCTAssertEqual(furnace.items?[2]?.count, 2)
        XCTAssertEqual(grid[0].map { itemDef($0.id).name }, "iron_ingot")
    }

    func testCraftingPoolTwoByTwoParityWithThreeByThreeForSharedNearbyContainers() throws {
        let world = makeWorld()
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 4)
        world.setBlockEntity(chest)
        let grid2x2 = [ItemStack?](repeating: nil, count: 4)
        let grid3x3 = [ItemStack?](repeating: nil, count: 9)

        let resources2x2 = craftingResourceStacks(playerInventory: [], craftGrid: grid2x2, world: world,
                                                  centerX: 1, centerY: 64, centerZ: 1, radius: CRAFTING_CONTAINER_RADIUS)
        let resources3x3 = craftingResourceStacks(playerInventory: [], craftGrid: grid3x3, world: world,
                                                  centerX: 1, centerY: 64, centerZ: 1, radius: CRAFTING_CONTAINER_RADIUS)
        let plan2x2 = try XCTUnwrap(craftingPlans(for: resources2x2, gridWidth: 2, gridHeight: 2).first {
            itemDef($0.output.id).name == "stick"
        })
        let plan3x3 = try XCTUnwrap(craftingPlans(for: resources3x3, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "stick"
        })

        let rounds2x2 = maxCraftingRounds(plan2x2, from: resources2x2)
        let rounds3x3 = maxCraftingRounds(plan3x3, from: resources3x3)
        XCTAssertGreaterThan(rounds2x2, 0)
        XCTAssertEqual(rounds2x2, rounds3x3,
                       "the personal 2x2 window must see the same pooled availability as the 3x3 table")
    }

    func testCraftingPoolBoundedScanIncludesContainerInFarChunkWithinInclusiveAABB() {
        let world = makeWorld(chunkRange: -4...4)
        world.setBlock(48, 64, 0, Int(cell(B.chest)))
        let chest = makeContainerBE(48, 64, 0, 27)
        chest.items?[0] = stack("oak_planks", 4)
        world.setBlockEntity(chest)

        // Chunk (3,0) spans x:[48,63] z:[0,15]; its own center is well beyond radius 50 from the
        // origin, but the container sits at exactly its nearest corner (distance 48 <= 50).
        let chunkCenterDistance = ((48.0 + 7.5) * (48.0 + 7.5) + 7.5 * 7.5).squareRoot()
        XCTAssertGreaterThan(chunkCenterDistance, 50)

        let found = nearbyCraftingContainers(in: world, centerX: 0, centerY: 64, centerZ: 0,
                                             radius: CRAFTING_CONTAINER_RADIUS)
        XCTAssertTrue(found.contains { $0.x == 48 && $0.y == 64 && $0.z == 0 },
                      "inclusive chunk-AABB math must include a boundary chunk by its corner, not its center")
    }

    func testCraftingContainerPoolCenterIsNilOnLANClientAndPlayerBlockPositionOtherwise() {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 1)
        let player = Player(world: world)
        player.x = 12.4
        player.y = 64.0
        player.z = -3.9

        XCTAssertNil(craftingContainerPoolCenter(for: player, isLANClientWorld: true),
                     "LAN clients must never pool — this is a correctness gate against honest-client duping")

        let center = try? XCTUnwrap(craftingContainerPoolCenter(for: player, isLANClientWorld: false))
        XCTAssertEqual(center?.x, 12)
        XCTAssertEqual(center?.y, 64)
        XCTAssertEqual(center?.z, -4)
    }

    func testCraftingPoolUnresolvedLootContributesZeroResources() {
        let world = makeWorld()
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.lootTable = "dungeon"
        world.setBlockEntity(chest)

        let resources = craftingResourceStacks(playerInventory: [], craftGrid: [], world: world,
                                               centerX: 1, centerY: 64, centerZ: 1, radius: CRAFTING_CONTAINER_RADIUS)

        XCTAssertTrue(resources.allSatisfy { $0 == nil },
                      "a container with unresolved (lazy) loot and no rolled items yet must contribute nothing")
    }

    // MARK: - Security regression: close-time no-loss/no-dupe (reference-implementation mirror)
    //
    // `InventoryScreen`/`CraftingScreen` (Sources/Elysium/ScreensM.swift) live in the `Elysium`
    // executable target, which links AppKit/Metal/QuartzCore. Package.swift has no test target
    // that depends on `Elysium`, so a real screen-close XCTest is not reachable from
    // ElysiumCoreTests today (verified: only ElysiumTextInputTests/ElysiumAppSupportTests exist
    // besides this target, neither depends on Elysium). `RPGUIHarnessTests`/`ControlsScreenTests`
    // test screens that live in `ElysiumCore` itself — `InventoryScreen`/`CraftingScreen` are not
    // in that category.
    //
    // These tests instead pin the exact fallback algorithm both `onClose` overrides run —
    // `player.give()` -> `giveStackToNearbyCraftingContainers()` -> `player.dropStack()` — built
    // from the identical public ElysiumCore primitives ScreensM.swift calls in the identical
    // order, and assert the no-loss/no-dupe invariant the fix exists to guarantee. If the real
    // onClose call sequence in ScreensM.swift ever drifts from this mirror, update both together.
    @discardableResult
    private func mirrorScreenOnCloseLeftovers(grid: inout [ItemStack?], player: Player, world: World,
                                              center: (x: Int, y: Int, z: Int)?, radius: Int) -> [ItemStack] {
        var ok = true
        for i in grid.indices {
            guard let stack = grid[i] else { continue }
            if player.give(stack) || stack.count <= 0 {
                grid[i] = nil
            } else if let center,
                      giveStackToNearbyCraftingContainers(stack, world: world,
                                                          centerX: center.x, centerY: center.y, centerZ: center.z,
                                                          radius: radius)
                        || stack.count <= 0 {
                grid[i] = nil
            } else {
                ok = false
            }
        }
        guard !ok else { return [] }
        var dropped: [ItemStack] = []
        for i in grid.indices {
            guard let stack = grid[i] else { continue }
            dropped.append(stack)
            grid[i] = nil
        }
        return dropped
    }

    /// Captures every `player.dropStack` call for the duration of `body`, restoring the prior
    /// global spawner hook afterward regardless of how `body` exits.
    private func capturingWorldDrops(_ body: () -> Void) -> [ItemStack] {
        var dropped: [ItemStack] = []
        let restore = spawnItemFn
        bindSpawners({ _, _, _, _, s, _, _, _ in dropped.append(s) }, spawnXPFn)
        defer { bindSpawners(restore, spawnXPFn) }
        body()
        return dropped
    }

    func testInventoryScreenCloseMirrorDropsLeftoverGridToWorldWithNoLossOrDupeWhenInventoryIsFull() {
        let world = makeWorld()
        let player = Player(world: world)
        player.x = 0; player.y = 64; player.z = 0
        for i in player.inventory.indices { player.inventory[i] = stack("cobblestone", 64) }
        var grid = [ItemStack?](repeating: nil, count: 4)
        grid[0] = stack("oak_planks", 3)
        grid[2] = stack("stick", 1)
        let before = itemCounts([player.inventory, grid])

        // InventoryScreen has no block entity of its own to persist leftovers in, and no nearby
        // container exists here, so onClose's only remaining path is a world drop.
        let dropped = capturingWorldDrops {
            let leftovers = mirrorScreenOnCloseLeftovers(
                grid: &grid, player: player, world: world,
                center: craftingContainerPoolCenter(for: player, isLANClientWorld: false),
                radius: CRAFTING_CONTAINER_RADIUS)
            for stack in leftovers { player.dropStack(stack) }
        }

        XCTAssertTrue(grid.allSatisfy { $0 == nil }, "onClose must never leave the grid non-empty")
        XCTAssertEqual(dropped.count, 2, "no duplication: exactly the two leftover grid stacks are dropped, once each")
        let after = itemCounts([player.inventory, grid, dropped.map { Optional($0) }])
        XCTAssertEqual(before, after, "no item may be lost or duplicated across inventory/grid/world-drop")
    }

    func testCraftingScreenTableBENilCloseMirrorDropsToWorldWhenInventoryAndNearbyContainersAreFull() {
        let world = makeWorld()
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 1)
        chest.items?[0] = stack("dirt", 64) // one slot, already at max stack: no merge room, no empty slot
        world.setBlockEntity(chest)
        let player = Player(world: world)
        player.x = 1; player.y = 64; player.z = 1
        for i in player.inventory.indices { player.inventory[i] = stack("cobblestone", 64) }
        var grid = [ItemStack?](repeating: nil, count: 9)
        grid[0] = stack("iron_ingot", 5)
        let before = itemCounts([player.inventory, grid, chest.items ?? []])

        // Mirrors CraftingScreen.onClose's `tableBE == nil` path: the ad-hoc 3x3 grid has no
        // persisted block entity, so once the inventory and every pooled container are
        // exhausted the remainder must be dropped rather than silently lost.
        let dropped = capturingWorldDrops {
            let leftovers = mirrorScreenOnCloseLeftovers(
                grid: &grid, player: player, world: world,
                center: craftingContainerPoolCenter(for: player, isLANClientWorld: false),
                radius: CRAFTING_CONTAINER_RADIUS)
            for stack in leftovers { player.dropStack(stack) }
        }

        XCTAssertTrue(grid.allSatisfy { $0 == nil })
        XCTAssertEqual(dropped.map { itemDef($0.id).name }, ["iron_ingot"])
        let after = itemCounts([player.inventory, grid, chest.items ?? [], dropped.map { Optional($0) }])
        XCTAssertEqual(before, after, "no item may be lost or duplicated when both inventory and pooled containers are full")
    }

    func testCraftingScreenTableBENilCloseMirrorPrefersNearbyContainerOverWorldDropWhenRoomExists() {
        let world = makeWorld()
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        world.setBlockEntity(chest)
        let player = Player(world: world)
        player.x = 1; player.y = 64; player.z = 1
        for i in player.inventory.indices { player.inventory[i] = stack("cobblestone", 64) }
        var grid = [ItemStack?](repeating: nil, count: 9)
        grid[4] = stack("redstone", 7)
        let before = itemCounts([player.inventory, grid, chest.items ?? []])

        let dropped = capturingWorldDrops {
            let leftovers = mirrorScreenOnCloseLeftovers(
                grid: &grid, player: player, world: world,
                center: craftingContainerPoolCenter(for: player, isLANClientWorld: false),
                radius: CRAFTING_CONTAINER_RADIUS)
            for stack in leftovers { player.dropStack(stack) }
        }

        XCTAssertTrue(dropped.isEmpty, "a nearby container with room must absorb the leftover before anything is dropped")
        XCTAssertEqual(chest.items?[0]?.count, 7)
        let after = itemCounts([player.inventory, grid, chest.items ?? [], dropped.map { Optional($0) }])
        XCTAssertEqual(before, after)
    }

    // MARK: - Property / fuzz / metamorphic (seeded, reproducible)

    private func randomItemName(_ rng: inout RandomX, from pool: [String]) -> String {
        pool[rng.nextInt(pool.count)]
    }

    /// Conservation on success, bit-identical rollback on failure — across many seeded random
    /// worlds/inventories/plans. Reproduce a failure by pinning the printed seed.
    func testCraftingPoolConservesOrRollsBackBitIdenticallyAcrossSeededRandomWorlds() {
        let itemPool = ["oak_planks", "cobblestone", "iron_ingot", "stick", "torch", "redstone", "chest"]
        for seed: UInt32 in 1...12 {
            var rng = RandomX(seed)
            let world = makeWorld(chunkRange: -3...3)
            var containers: [BlockEntityData] = []
            var usedPositions = Set<Int>()
            let containerCount = rng.nextIntBetween(0, 4)
            for _ in 0..<containerCount {
                var x = 0, z = 0
                repeat {
                    x = rng.nextIntBetween(-45, 45)
                    z = rng.nextIntBetween(-45, 45)
                } while !usedPositions.insert(x * 1000 + z).inserted
                world.setBlock(x, 64, z, Int(cell(B.chest)))
                let be = makeContainerBE(x, 64, z, 27)
                let slotCount = rng.nextIntBetween(0, 6)
                for _ in 0..<slotCount {
                    let slot = rng.nextInt(27)
                    if be.items?[slot] == nil {
                        be.items?[slot] = stack(randomItemName(&rng, from: itemPool), rng.nextIntBetween(1, 12))
                    }
                }
                world.setBlockEntity(be)
                containers.append(be)
            }
            var inventory = [ItemStack?](repeating: nil, count: 36)
            let invCount = rng.nextIntBetween(0, 8)
            for _ in 0..<invCount {
                let slot = rng.nextInt(36)
                if inventory[slot] == nil {
                    inventory[slot] = stack(randomItemName(&rng, from: itemPool), rng.nextIntBetween(1, 12))
                }
            }
            var grid = [ItemStack?](repeating: nil, count: 9)
            var ingredients = [String?](repeating: nil, count: 9)
            let ingredientCount = rng.nextIntBetween(1, 4)
            for i in 0..<ingredientCount {
                ingredients[i] = randomItemName(&rng, from: itemPool)
            }
            let plan = CraftingRecipePlan(recipeIndex: 0, recipe: craftingRecipes[0],
                                          output: ItemStack(iid("stick"), 1), ingredients: ingredients)

            func fingerprint(_ stacks: [ItemStack?]) -> [String] {
                stacks.map { $0.map { "\($0.id):\($0.count):\($0.damage)" } ?? "-" }
            }
            let beforeInventory = fingerprint(inventory)
            let beforeGrid = fingerprint(grid)
            let beforeContainerFingerprints = containers.map { fingerprint($0.items ?? []) }
            let beforeTotals = itemCounts([inventory, grid] + containers.map { $0.items ?? [] })

            let success = populateCraftingGridFromNearbyContainers(
                plan, grid: &grid, inventory: &inventory, world: world,
                centerX: 0, centerY: 64, centerZ: 0, radius: CRAFTING_CONTAINER_RADIUS)

            if success {
                let afterTotals = itemCounts([inventory, grid] + containers.map { $0.items ?? [] })
                XCTAssertEqual(beforeTotals, afterTotals,
                               "seed \(seed): item multiset must be conserved across a successful populate")
            } else {
                XCTAssertEqual(fingerprint(inventory), beforeInventory,
                               "seed \(seed): a failed populate must roll back the inventory bit-for-bit")
                XCTAssertEqual(fingerprint(grid), beforeGrid,
                               "seed \(seed): a failed populate must roll back the grid bit-for-bit")
                for (container, snapshot) in zip(containers, beforeContainerFingerprints) {
                    XCTAssertEqual(fingerprint(container.items ?? []), snapshot,
                                   "seed \(seed): a failed populate must roll back container (\(container.x),\(container.y),\(container.z)) bit-for-bit")
                }
            }
        }
    }

    private struct FuzzContainerSpec {
        let x: Int, y: Int, z: Int
        let items: [(slot: Int, name: String, count: Int)]
    }
    private struct FuzzBoatSpec {
        let x: Double, y: Double, z: Double
        let items: [(slot: Int, name: String, count: Int)]
    }

    /// Builds an identical set of chunks/containers/boats, but visiting them in whatever
    /// (seeded-shuffled) order the caller provides, so callers can prove pooling output is
    /// independent of insertion order.
    private func makeShuffledPooledWorld(chunkOrder: [(Int, Int)],
                                         containers: [FuzzContainerSpec], containerOrder: [Int],
                                         boats: [FuzzBoatSpec], boatOrder: [Int]) -> (World, [BlockEntityData], [Boat]) {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 24680)
        let info = dimInfo(.overworld)
        for (cx, cz) in chunkOrder {
            let chunk = Chunk(cx: cx, cz: cz, minY: info.minY, height: info.height)
            chunk.status = .lit
            world.setChunk(chunk)
            world.light.initChunkLight(chunk)
        }
        var beByIndex = [BlockEntityData?](repeating: nil, count: containers.count)
        for idx in containerOrder {
            let spec = containers[idx]
            world.setBlock(spec.x, spec.y, spec.z, Int(cell(B.chest)))
            let be = makeContainerBE(spec.x, spec.y, spec.z, 27)
            for item in spec.items { be.items?[item.slot] = stack(item.name, item.count) }
            world.setBlockEntity(be)
            beByIndex[idx] = be
        }
        var boatByIndex = [Boat?](repeating: nil, count: boats.count)
        for idx in boatOrder {
            let spec = boats[idx]
            let boat = Boat(world: world)
            boat.hasChest = true
            boat.x = spec.x; boat.y = spec.y; boat.z = spec.z
            for item in spec.items { boat.chestItems[item.slot] = stack(item.name, item.count) }
            world.addEntity(boat)
            boatByIndex[idx] = boat
        }
        return (world, beByIndex.compactMap { $0 }, boatByIndex.compactMap { $0 })
    }

    /// Metamorphic/determinism: the same chunks/containers/boats inserted in two different
    /// (seeded-shuffled) orders must yield an identical pooled-resource listing and must
    /// withdraw the identical units from the identical owners.
    func testCraftingPoolResourceOrderAndWithdrawalAreInvariantToInsertionOrder() {
        let containerSpecs = [
            FuzzContainerSpec(x: 5, y: 64, z: 5, items: [(slot: 0, name: "oak_planks", count: 5)]),
            FuzzContainerSpec(x: -10, y: 64, z: 3, items: [(slot: 2, name: "cobblestone", count: 8)]),
            FuzzContainerSpec(x: 20, y: 64, z: -20, items: [(slot: 1, name: "iron_ingot", count: 3)]),
            FuzzContainerSpec(x: 0, y: 64, z: 40, items: [(slot: 0, name: "stick", count: 2)]),
        ]
        let boatSpecs = [
            FuzzBoatSpec(x: 3.5, y: 64.0, z: 1.5, items: [(slot: 0, name: "torch", count: 6)]),
        ]
        let chunkCoords: [(Int, Int)] = (-3...3).flatMap { cx in (-3...3).map { cz in (cx, cz) } }

        for seed: UInt32 in [101, 202, 303] {
            var rngA = RandomX(seed)
            var chunkOrderA = chunkCoords; rngA.shuffle(&chunkOrderA)
            var containerOrderA = Array(containerSpecs.indices); rngA.shuffle(&containerOrderA)
            var boatOrderA = Array(boatSpecs.indices); rngA.shuffle(&boatOrderA)

            var rngB = RandomX(seed &+ 777)
            var chunkOrderB = chunkCoords; rngB.shuffle(&chunkOrderB)
            var containerOrderB = Array(containerSpecs.indices); rngB.shuffle(&containerOrderB)
            var boatOrderB = Array(boatSpecs.indices); rngB.shuffle(&boatOrderB)

            let (worldA, containersA, _) = makeShuffledPooledWorld(
                chunkOrder: chunkOrderA, containers: containerSpecs, containerOrder: containerOrderA,
                boats: boatSpecs, boatOrder: boatOrderA)
            let (worldB, containersB, _) = makeShuffledPooledWorld(
                chunkOrder: chunkOrderB, containers: containerSpecs, containerOrder: containerOrderB,
                boats: boatSpecs, boatOrder: boatOrderB)

            let resourcesA = craftingResourceStacks(playerInventory: [], craftGrid: [], world: worldA,
                                                     centerX: 0, centerY: 64, centerZ: 0, radius: CRAFTING_CONTAINER_RADIUS)
            let resourcesB = craftingResourceStacks(playerInventory: [], craftGrid: [], world: worldB,
                                                     centerX: 0, centerY: 64, centerZ: 0, radius: CRAFTING_CONTAINER_RADIUS)
            let describe: ([ItemStack?]) -> [String] = { $0.map { $0.map { "\(itemDef($0.id).name):\($0.count)" } ?? "-" } }
            XCTAssertEqual(describe(resourcesA), describe(resourcesB),
                           "seed \(seed): pooled resource listing (and order) must not depend on insertion order")

            var gridA = [ItemStack?](repeating: nil, count: 4)
            var gridB = [ItemStack?](repeating: nil, count: 4)
            var invA: [ItemStack?] = []
            var invB: [ItemStack?] = []
            let plan = CraftingRecipePlan(recipeIndex: 0, recipe: craftingRecipes[0], output: ItemStack(iid("stick"), 1),
                                          ingredients: ["oak_planks", "cobblestone", "torch", nil])

            let okA = populateCraftingGridFromNearbyContainers(plan, grid: &gridA, inventory: &invA, world: worldA,
                                                                centerX: 0, centerY: 64, centerZ: 0, radius: CRAFTING_CONTAINER_RADIUS)
            let okB = populateCraftingGridFromNearbyContainers(plan, grid: &gridB, inventory: &invB, world: worldB,
                                                                centerX: 0, centerY: 64, centerZ: 0, radius: CRAFTING_CONTAINER_RADIUS)
            XCTAssertTrue(okA)
            XCTAssertEqual(okA, okB, "seed \(seed): withdrawal success must be independent of insertion order")

            for (containerA, containerB) in zip(containersA, containersB) {
                XCTAssertEqual((containerA.items ?? []).map { $0?.count }, (containerB.items ?? []).map { $0?.count },
                               "seed \(seed): withdrawal must remove the same units from the same container regardless of insertion order")
            }
        }
    }

    /// Reference brute-force scan (every loaded chunk, no chunk-AABB bound) mirroring the
    /// production filter/sort exactly, to prove the bounded scan is a pure optimization.
    private func bruteForceNearbyCraftingContainers(in world: World, centerX: Int, centerY: Int, centerZ: Int,
                                                     radius: Int) -> [BlockEntityData] {
        guard radius >= 0 else { return [] }
        let r2 = radius * radius
        var out: [BlockEntityData] = []
        for chunk in world.chunks.values {
            for be in chunk.blockEntities.values {
                guard let items = be.items, !items.isEmpty else { continue }
                guard be.type == "container" || be.type == "hopper" || be.type == "furnace" || be.type == "brewing" else { continue }
                let dx = centerX - be.x, dy = centerY - be.y, dz = centerZ - be.z
                if dx * dx + dy * dy + dz * dz <= r2 { out.append(be) }
            }
        }
        func d2(_ be: BlockEntityData) -> Int {
            let dx = centerX - be.x, dy = centerY - be.y, dz = centerZ - be.z
            return dx * dx + dy * dy + dz * dz
        }
        out.sort {
            let ad = d2($0), bd = d2($1)
            if ad != bd { return ad < bd }
            if $0.y != $1.y { return $0.y < $1.y }
            if $0.z != $1.z { return $0.z < $1.z }
            if $0.x != $1.x { return $0.x < $1.x }
            return $0.type < $1.type
        }
        return out
    }

    /// Bounded-scan equivalence: the chunk-range scan must return exactly the brute-force
    /// all-chunks result (set AND order), across seeded random worlds and centers chosen to
    /// straddle chunk borders and negative coordinates.
    func testCraftingPoolBoundedScanMatchesBruteForceAcrossSeededWorldsAndBorderCenters() {
        let types = ["container", "furnace", "brewing", "hopper"]
        let centers: [(Int, Int, Int)] = [
            (0, 64, 0), (16, 64, 16), (15, 64, 15), (-16, 64, -16), (-1, 64, -1),
            (48, 64, -33), (-48, 64, 33), (0, 64, 15), (0, 64, 16), (-63, 64, 63),
        ]
        for seed: UInt32 in [7, 42, 99] {
            var rng = RandomX(seed)
            let world = makeWorld(chunkRange: -4...4)
            var used = Set<Int>()
            let count = rng.nextIntBetween(10, 30)
            for _ in 0..<count {
                var x = 0, z = 0
                repeat {
                    x = rng.nextIntBetween(-63, 63)
                    z = rng.nextIntBetween(-63, 63)
                } while !used.insert(x * 10_000 + z).inserted
                let type = types[rng.nextInt(types.count)]
                let be: BlockEntityData
                switch type {
                case "furnace": be = makeFurnaceBE(x, 64, z, "furnace")
                case "brewing": be = makeBrewingBE(x, 64, z)
                case "hopper": be = makeHopperBE(x, 64, z)
                default: be = makeContainerBE(x, 64, z, 27)
                }
                if rng.chance(0.7), let slotCount = be.items?.count, slotCount > 0 {
                    be.items?[rng.nextInt(slotCount)] = stack("oak_planks", rng.nextIntBetween(1, 8))
                }
                world.setBlockEntity(be)
            }

            for center in centers {
                let scanned = nearbyCraftingContainers(in: world, centerX: center.0, centerY: center.1, centerZ: center.2,
                                                        radius: CRAFTING_CONTAINER_RADIUS)
                let brute = bruteForceNearbyCraftingContainers(in: world, centerX: center.0, centerY: center.1, centerZ: center.2,
                                                                radius: CRAFTING_CONTAINER_RADIUS)
                let describe: ([BlockEntityData]) -> [String] = { $0.map { "\($0.x),\($0.y),\($0.z),\($0.type)" } }
                XCTAssertEqual(describe(scanned), describe(brute),
                               "seed \(seed) center \(center): bounded chunk-range scan must match a brute-force all-chunks scan, set and order")
            }
        }
    }

    // MARK: - Boundary: radius 0/negative, empty world, unloaded center

    func testNearbyCraftingContainersRadiusZeroIncludesOnlyExactCenterMatch() {
        let world = makeWorld()
        world.setBlock(0, 64, 0, Int(cell(B.chest)))
        let atCenter = makeContainerBE(0, 64, 0, 27)
        atCenter.items?[0] = stack("oak_planks", 1)
        world.setBlockEntity(atCenter)
        world.setBlock(1, 64, 0, Int(cell(B.chest)))
        let oneAway = makeContainerBE(1, 64, 0, 27)
        oneAway.items?[0] = stack("oak_planks", 1)
        world.setBlockEntity(oneAway)

        let found = nearbyCraftingContainers(in: world, centerX: 0, centerY: 64, centerZ: 0, radius: 0)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.x, 0)
    }

    func testNearbyCraftingContainersRejectsNegativeRadiusRatherThanCrashing() {
        let world = makeWorld()
        world.setBlock(0, 64, 0, Int(cell(B.chest)))
        let chest = makeContainerBE(0, 64, 0, 27)
        chest.items?[0] = stack("oak_planks", 1)
        world.setBlockEntity(chest)

        XCTAssertTrue(nearbyCraftingContainers(in: world, centerX: 0, centerY: 64, centerZ: 0, radius: -1).isEmpty)
    }

    func testNearbyCraftingContainersOnEmptyWorldReturnsEmpty() {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 1) // no chunks loaded at all

        XCTAssertTrue(nearbyCraftingContainers(in: world, centerX: 0, centerY: 64, centerZ: 0,
                                               radius: CRAFTING_CONTAINER_RADIUS).isEmpty)
    }

    func testNearbyCraftingContainersAtUnloadedCenterReturnsEmptyWithoutCrashing() {
        let world = makeWorld() // loads chunkRange -1...2 only
        world.setBlock(1, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(1, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 1)
        world.setBlockEntity(chest)

        let found = nearbyCraftingContainers(in: world, centerX: 5000, centerY: 64, centerZ: 5000,
                                             radius: CRAFTING_CONTAINER_RADIUS)

        XCTAssertTrue(found.isEmpty, "a center whose surrounding chunks are all unloaded must not crash and must contribute nothing")
    }

    // MARK: - Non-functional: bounded-scan performance (Design D2 + Security medium)

    /// Dense radius-50 container farm at simDistance-6 scale (`World.simDistance` defaults to
    /// 6). Reports median of several runs and asserts comfortable frame-budget headroom, since
    /// `pooledRecipeResources` now runs at most once per `draw()`.
    func testCraftingPoolBoundedScanStaysWellWithinFrameBudgetOnDenseContainerFarm() {
        let world = makeWorld(chunkRange: -6...6)
        var rng = RandomX(555)
        var placed = 0
        var x = -50
        while x <= 50 {
            var z = -50
            while z <= 50 {
                if x * x + z * z <= 50 * 50 {
                    world.setBlock(x, 64, z, Int(cell(B.chest)))
                    let be = makeContainerBE(x, 64, z, 27)
                    for slot in 0..<27 where rng.chance(0.5) {
                        be.items?[slot] = stack("oak_planks", rng.nextIntBetween(1, 64))
                    }
                    world.setBlockEntity(be)
                    placed += 1
                }
                z += 2
            }
            x += 2
        }
        XCTAssertGreaterThan(placed, 500, "sanity: the farm must actually be dense")

        var samples: [Double] = []
        for _ in 0..<7 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = craftingResourceStacks(playerInventory: [ItemStack?](repeating: nil, count: 36),
                                       craftGrid: [ItemStack?](repeating: nil, count: 9),
                                       world: world, centerX: 0, centerY: 64, centerZ: 0, radius: CRAFTING_CONTAINER_RADIUS)
            samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        print("[perf][DEBUG build] crafting pool scan, dense \(placed)-container farm, radius 50: "
              + "median \(String(format: "%.4f", median))ms over \(samples.count) runs — "
              + "samples(ms): \(samples.map { String(format: "%.4f", $0) })")

        // `swift test` always builds this target in DEBUG here — several sibling *Tests.swift
        // files call debug-only `_test*` production hooks that don't exist under `-c release`,
        // so an optimized XCTest run isn't reachable. A standalone `-c release` probe against
        // this exact scenario (same `craftingResourceStacks` call, same 1961-container farm,
        // `swift run -c release`, median of 9 runs) measured **2.80ms** — the DEBUG number below
        // is a pessimistic stand-in, not the shipped number; the real (release) headroom against
        // the 16ms/frame budget is ~5.8x better than this assertion's threshold suggests. This
        // still guards against an accidental algorithmic regression (e.g. losing the chunk-AABB
        // bound and reverting to an all-chunks scan) even though its absolute number is debug-only.
        XCTAssertLessThan(median, 60.0,
                          "pooled resource scan regressed far beyond its DEBUG-build baseline (~16ms); "
                          + "see release-mode headroom note above")
    }

    private func assertKnownIngredient(_ ingredient: String, file: StaticString = #filePath, line: UInt = #line) {
        if ingredient.hasPrefix("#") {
            let tag = String(ingredient.dropFirst())
            let values = TAGS[tag] ?? []
            XCTAssertFalse(values.isEmpty, "unknown or empty tag \(ingredient)", file: file, line: line)
            for name in values {
                XCTAssertTrue(itemExists(name), "tag \(ingredient) references unknown item \(name)", file: file, line: line)
            }
        } else {
            XCTAssertTrue(itemExists(ingredient), "unknown ingredient \(ingredient)", file: file, line: line)
        }
    }

    private func outputKey(_ plan: CraftingRecipePlan) -> String {
        outputKey(plan.output)
    }

    private func outputKey(_ stack: ItemStack) -> String {
        "\(itemDef(stack.id).name)#\(stack.count)"
    }

    private func recipeFits(_ recipe: CraftRecipe, gridWidth: Int, gridHeight: Int) -> Bool {
        switch recipe {
        case .shaped(let w, let h, _, _, _):
            return w <= gridWidth && h <= gridHeight
        case .shapeless(let inputs, _, _):
            return inputs.count <= gridWidth * gridHeight
        }
    }
}
