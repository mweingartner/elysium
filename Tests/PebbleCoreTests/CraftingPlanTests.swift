import XCTest
@testable import PebbleCore

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

    private func makeWorld() -> World {
        registerCoreIfNeeded()
        let world = World(dim: .overworld, seed: 13579)
        let info = dimInfo(.overworld)
        for cz in -1...2 {
            for cx in -1...2 {
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

    func testCraftingTablePlansUseNearbyContainerResources() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 8)
        world.setBlockEntity(chest)

        let resources = craftingTableResourceStacks(playerInventory: [], craftGrid: [], world: world,
                                                    tableX: 1, tableY: 64, tableZ: 1)
        let outputs = craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).map { itemDef($0.output.id).name }

        XCTAssertTrue(outputs.contains("chest"))
    }

    func testCraftingTableRecipeSelectionConsumesNearbyContainerResources() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 8)
        world.setBlockEntity(chest)
        var inventory = [ItemStack?](repeating: nil, count: 36)
        var grid = [ItemStack?](repeating: nil, count: 9)
        let resources = craftingTableResourceStacks(playerInventory: inventory, craftGrid: grid, world: world,
                                                    tableX: 1, tableY: 64, tableZ: 1)
        let p = try XCTUnwrap(craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "chest"
        })

        XCTAssertTrue(populateCraftingGridFromNearbyContainers(p, grid: &grid, inventory: &inventory,
                                                               world: world, tableX: 1, tableY: 64, tableZ: 1))

        XCTAssertNil(chest.items?[0])
        XCTAssertEqual(grid.compactMap { $0 }.count, 8)
        XCTAssertEqual(matchCrafting(grid, 3, 3)?.out.id, iid("chest"))
    }

    func testCraftingTableConsumesPlayerInventoryBeforeNearbyContainers() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 3)
        world.setBlockEntity(chest)
        var inventory = [ItemStack?](repeating: nil, count: 36)
        inventory[0] = stack("oak_planks", 1)
        var grid = [ItemStack?](repeating: nil, count: 9)
        let resources = craftingTableResourceStacks(playerInventory: inventory, craftGrid: grid, world: world,
                                                    tableX: 1, tableY: 64, tableZ: 1)
        let p = try XCTUnwrap(craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "crafting_table"
        })

        XCTAssertTrue(populateCraftingGridFromNearbyContainers(p, grid: &grid, inventory: &inventory,
                                                               world: world, tableX: 1, tableY: 64, tableZ: 1))

        XCTAssertNil(inventory[0])
        XCTAssertNil(chest.items?[0])
        XCTAssertEqual(grid.compactMap { $0 }.count, 4)
        XCTAssertEqual(matchCrafting(grid, 3, 3)?.out.id, iid("crafting_table"))
    }

    func testCraftingTableIgnoresContainersOutsideRadius() {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        world.setBlock(30, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(30, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 8)
        world.setBlockEntity(chest)

        let resources = craftingTableResourceStacks(playerInventory: [], craftGrid: [], world: world,
                                                    tableX: 1, tableY: 64, tableZ: 1)
        let outputs = craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).map { itemDef($0.output.id).name }

        XCTAssertFalse(outputs.contains("chest"))
        XCTAssertEqual(chest.items?[0]?.count, 8)
    }

    func testCraftingTableUsesNearbyChestVehicles() throws {
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
        let resources = craftingTableResourceStacks(playerInventory: inventory, craftGrid: grid, world: world,
                                                    tableX: 1, tableY: 64, tableZ: 1)
        let p = try XCTUnwrap(craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "crafting_table"
        })

        XCTAssertTrue(populateCraftingGridFromNearbyContainers(p, grid: &grid, inventory: &inventory,
                                                               world: world, tableX: 1, tableY: 64, tableZ: 1))

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
        let scrolled = typeahead.scroll
        let highlighted = typeahead.highlightedIndex

        typeahead.refresh(plans: plans)
        XCTAssertEqual(typeahead.scroll, scrolled)
        XCTAssertEqual(typeahead.highlightedIndex, highlighted)
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
        XCTAssertEqual(typeahead.selectedPlan(in: plans).map { itemDef($0.output.id).name }, "oak_door")

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

    func testCraftingTableRoundLimitIncludesNearbyContainerResources() throws {
        let world = makeWorld()
        world.setBlock(1, 64, 1, Int(cell(B.crafting_table)))
        world.setBlock(4, 64, 1, Int(cell(B.chest)))
        let chest = makeContainerBE(4, 64, 1, 27)
        chest.items?[0] = stack("oak_planks", 12)
        world.setBlockEntity(chest)
        let resources = craftingTableResourceStacks(playerInventory: [], craftGrid: [], world: world,
                                                    tableX: 1, tableY: 64, tableZ: 1)
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
