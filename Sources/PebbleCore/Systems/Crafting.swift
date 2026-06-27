// Crafting — grid matching (shaped with
// mirroring, shapeless, tags), enchanting table / anvil / grindstone math.

import Foundation

public struct CraftingRecipePlan {
    public let recipe: CraftRecipe
    public let output: ItemStack
    public let ingredients: [String?]
}

public let CRAFTING_TABLE_CONTAINER_RADIUS = 25

public func craftingIngredientMatches(_ ing: String, _ stack: ItemStack?) -> Bool {
    guard let stack else { return false }
    let name = itemDef(stack.id).name
    if ing.hasPrefix("#") { return tagMatches(String(ing.dropFirst()), name) }
    return ing == name
}

private func ingMatches(_ ing: String, _ stack: ItemStack?) -> Bool {
    craftingIngredientMatches(ing, stack)
}

public func craftingRecipeOutput(_ recipe: CraftRecipe) -> ItemStack {
    switch recipe {
    case .shaped(_, _, _, let out, let count),
         .shapeless(_, let out, let count):
        return ItemStack(iid(out), count)
    }
}

private func inventoryCounts(_ inventory: [ItemStack?]) -> [String: Int] {
    var counts: [String: Int] = [:]
    for stack in inventory {
        guard let stack, stack.count > 0 else { continue }
        counts[itemDef(stack.id).name, default: 0] += stack.count
    }
    return counts
}

private func reserveIngredient(_ ingredient: String, from counts: inout [String: Int]) -> String? {
    if ingredient.hasPrefix("#") {
        let tag = String(ingredient.dropFirst())
        for name in TAGS[tag] ?? [] where (counts[name] ?? 0) > 0 {
            counts[name, default: 0] -= 1
            return name
        }
        return nil
    }
    guard (counts[ingredient] ?? 0) > 0 else { return nil }
    counts[ingredient, default: 0] -= 1
    return ingredient
}

private func planRecipe(_ recipe: CraftRecipe, counts: [String: Int], gridWidth: Int, gridHeight: Int) -> CraftingRecipePlan? {
    var remaining = counts
    var ingredients = [String?](repeating: nil, count: gridWidth * gridHeight)

    switch recipe {
    case .shaped(let w, let h, let grid, _, _):
        if w > gridWidth || h > gridHeight { return nil }
        for y in 0..<h {
            for x in 0..<w {
                guard let ingredient = grid[y * w + x] else { continue }
                guard let concrete = reserveIngredient(ingredient, from: &remaining) else { return nil }
                ingredients[y * gridWidth + x] = concrete
            }
        }
    case .shapeless(let inputs, _, _):
        if inputs.count > gridWidth * gridHeight { return nil }
        for (i, ingredient) in inputs.enumerated() {
            guard let concrete = reserveIngredient(ingredient, from: &remaining) else { return nil }
            ingredients[i] = concrete
        }
    }

    return CraftingRecipePlan(recipe: recipe, output: craftingRecipeOutput(recipe), ingredients: ingredients)
}

private func representativeIngredient(_ ingredient: String) -> String? {
    if ingredient.hasPrefix("#") {
        for name in TAGS[String(ingredient.dropFirst())] ?? [] where itemExists(name) {
            return name
        }
        return nil
    }
    return itemExists(ingredient) ? ingredient : nil
}

private func planCreativeRecipe(_ recipe: CraftRecipe, gridWidth: Int, gridHeight: Int) -> CraftingRecipePlan? {
    var ingredients = [String?](repeating: nil, count: gridWidth * gridHeight)

    switch recipe {
    case .shaped(let w, let h, let grid, _, _):
        if w > gridWidth || h > gridHeight { return nil }
        for y in 0..<h {
            for x in 0..<w {
                guard let ingredient = grid[y * w + x] else { continue }
                guard let concrete = representativeIngredient(ingredient) else { return nil }
                ingredients[y * gridWidth + x] = concrete
            }
        }
    case .shapeless(let inputs, _, _):
        if inputs.count > gridWidth * gridHeight { return nil }
        for (i, ingredient) in inputs.enumerated() {
            guard let concrete = representativeIngredient(ingredient) else { return nil }
            ingredients[i] = concrete
        }
    }

    return CraftingRecipePlan(recipe: recipe, output: craftingRecipeOutput(recipe), ingredients: ingredients)
}

private func sortCraftingPlans(_ plans: inout [CraftingRecipePlan]) {
    plans.sort {
        let a = itemDef($0.output.id), b = itemDef($1.output.id)
        if a.displayName != b.displayName { return a.displayName < b.displayName }
        return a.name < b.name
    }
}

public func craftingPlans(for inventory: [ItemStack?], gridWidth: Int, gridHeight: Int) -> [CraftingRecipePlan] {
    guard gridWidth > 0, gridHeight > 0, gridWidth <= 8, gridHeight <= 8 else { return [] }
    let counts = inventoryCounts(inventory)
    var seen = Set<String>()
    var plans: [CraftingRecipePlan] = []
    for recipe in craftingRecipes {
        guard let plan = planRecipe(recipe, counts: counts, gridWidth: gridWidth, gridHeight: gridHeight) else { continue }
        let key = "\(itemDef(plan.output.id).name)#\(plan.output.count)"
        if seen.insert(key).inserted { plans.append(plan) }
    }
    sortCraftingPlans(&plans)
    return plans
}

public func creativeCraftingPlans(gridWidth: Int, gridHeight: Int) -> [CraftingRecipePlan] {
    guard gridWidth > 0, gridHeight > 0, gridWidth <= 8, gridHeight <= 8 else { return [] }
    var seen = Set<String>()
    var plans: [CraftingRecipePlan] = []
    for recipe in craftingRecipes {
        guard let plan = planCreativeRecipe(recipe, gridWidth: gridWidth, gridHeight: gridHeight) else { continue }
        let key = "\(itemDef(plan.output.id).name)#\(plan.output.count)"
        if seen.insert(key).inserted { plans.append(plan) }
    }
    sortCraftingPlans(&plans)
    return plans
}

public func normalizedCraftingPlanSearch(_ raw: String) -> String {
    var out = ""
    var lastWasSpace = true
    for scalar in raw.unicodeScalars {
        let v = scalar.value
        if v >= 65 && v <= 90 {
            out.unicodeScalars.append(UnicodeScalar(v + 32)!)
            lastWasSpace = false
        } else if (v >= 97 && v <= 122) || (v >= 48 && v <= 57) {
            out.unicodeScalars.append(scalar)
            lastWasSpace = false
        } else if !lastWasSpace {
            out.append(" ")
            lastWasSpace = true
        }
    }
    return out.trimmingCharacters(in: .whitespaces)
}

private func compactCraftingPlanSearch(_ raw: String) -> String {
    normalizedCraftingPlanSearch(raw).replacingOccurrences(of: " ", with: "")
}

private func craftingPlanSearchKeys(_ plan: CraftingRecipePlan) -> [String] {
    let def = itemDef(plan.output.id)
    return [def.displayName, def.name.replacingOccurrences(of: "_", with: " "), def.name]
}

public func craftingPlanMatchesSearch(_ plan: CraftingRecipePlan, query rawQuery: String) -> Bool {
    firstCraftingPlanIndex(matching: rawQuery, in: [plan]) != nil
}

public func firstCraftingPlanIndex(matching rawQuery: String, in plans: [CraftingRecipePlan]) -> Int? {
    let query = normalizedCraftingPlanSearch(rawQuery)
    guard !query.isEmpty else { return nil }
    let compactQuery = query.replacingOccurrences(of: " ", with: "")
    var containsFallback: Int?

    for (idx, plan) in plans.enumerated() {
        let keys = craftingPlanSearchKeys(plan)
        for key in keys {
            let normalized = normalizedCraftingPlanSearch(key)
            let compact = compactCraftingPlanSearch(key)
            if normalized.hasPrefix(query) || compact.hasPrefix(compactQuery) {
                return idx
            }
            if containsFallback == nil && (normalized.contains(query) || compact.contains(compactQuery)) {
                containsFallback = idx
            }
        }
    }
    return containsFallback
}

public struct CraftingRecipeTypeahead {
    public private(set) var query: String
    public private(set) var highlightedIndex: Int?
    public private(set) var scroll: Int
    public let maxRows: Int
    public let maxQueryLength: Int

    public init(maxRows: Int = 8, maxQueryLength: Int = 48) {
        self.maxRows = max(1, maxRows)
        self.maxQueryLength = max(1, maxQueryLength)
        query = ""
        highlightedIndex = nil
        scroll = 0
    }

    public mutating func open(plans: [CraftingRecipePlan]) {
        query = ""
        highlightedIndex = plans.isEmpty ? nil : 0
        ensureHighlightedVisible(planCount: plans.count)
    }

    public mutating func close() {
        query = ""
        highlightedIndex = nil
    }

    public mutating func refresh(plans: [CraftingRecipePlan]) {
        guard !plans.isEmpty else {
            highlightedIndex = nil
            scroll = 0
            return
        }
        scroll = min(scroll, max(0, plans.count - maxRows))
        if let idx = highlightedIndex, idx >= plans.count {
            highlightedIndex = plans.count - 1
        } else if highlightedIndex == nil {
            highlightedIndex = query.isEmpty ? min(scroll, plans.count - 1) : firstCraftingPlanIndex(matching: query, in: plans)
        }
    }

    @discardableResult
    public mutating func append(_ text: String, plans: [CraftingRecipePlan]) -> Bool {
        var accepted = ""
        for scalar in text.unicodeScalars where scalar.value >= 32 && scalar.value != 127 {
            accepted.unicodeScalars.append(scalar)
        }
        guard !accepted.isEmpty else { return false }

        query.append(accepted)
        if query.count > maxQueryLength {
            query = String(query.suffix(maxQueryLength))
        }
        updateHighlight(plans: plans)
        return true
    }

    @discardableResult
    public mutating func deleteBackward(plans: [CraftingRecipePlan]) -> Bool {
        guard !query.isEmpty else {
            updateHighlight(plans: plans)
            return false
        }
        query.removeLast()
        updateHighlight(plans: plans)
        return true
    }

    public mutating func moveHighlight(_ delta: Int, plans: [CraftingRecipePlan]) {
        guard !plans.isEmpty else {
            highlightedIndex = nil
            scroll = 0
            return
        }
        let current = highlightedIndex ?? scroll
        highlightedIndex = max(0, min(plans.count - 1, current + delta))
        ensureHighlightedVisible(planCount: plans.count)
    }

    public mutating func scrollRows(_ delta: Int, plans: [CraftingRecipePlan]) {
        guard plans.count > maxRows else {
            scroll = 0
            if let idx = highlightedIndex, idx >= plans.count {
                highlightedIndex = plans.isEmpty ? nil : plans.count - 1
            }
            return
        }
        scroll = max(0, min(plans.count - maxRows, scroll + delta))
        let rows = min(maxRows, plans.count)
        if let idx = highlightedIndex {
            if idx < scroll {
                highlightedIndex = scroll
            } else if idx >= scroll + rows {
                highlightedIndex = scroll + rows - 1
            }
        } else {
            highlightedIndex = scroll
        }
    }

    public func selectedPlan(in plans: [CraftingRecipePlan]) -> CraftingRecipePlan? {
        guard let idx = highlightedIndex, idx >= 0 && idx < plans.count else { return nil }
        return plans[idx]
    }

    private mutating func updateHighlight(plans: [CraftingRecipePlan]) {
        guard !plans.isEmpty else {
            highlightedIndex = nil
            scroll = 0
            return
        }
        if query.isEmpty {
            highlightedIndex = min(highlightedIndex ?? 0, plans.count - 1)
        } else {
            highlightedIndex = firstCraftingPlanIndex(matching: query, in: plans)
        }
        ensureHighlightedVisible(planCount: plans.count)
    }

    private mutating func ensureHighlightedVisible(planCount: Int) {
        guard let idx = highlightedIndex, planCount > 0 else {
            scroll = min(scroll, max(0, planCount - maxRows))
            return
        }
        let rows = min(maxRows, planCount)
        if idx < scroll {
            scroll = idx
        } else if idx >= scroll + rows {
            scroll = idx - rows + 1
        }
        scroll = max(0, min(max(0, planCount - maxRows), scroll))
    }
}

public func populateCraftingGrid(_ plan: CraftingRecipePlan, grid: inout [ItemStack?], inventory: inout [ItemStack?]) -> Bool {
    guard grid.count == plan.ingredients.count else { return false }
    guard grid.allSatisfy({ $0 == nil }) else { return false }

    var counts = inventoryCounts(inventory)
    for name in plan.ingredients.compactMap({ $0 }) {
        guard (counts[name] ?? 0) > 0 else { return false }
        counts[name, default: 0] -= 1
    }

    for (gridIndex, name) in plan.ingredients.enumerated() {
        guard let name else { continue }
        for invIndex in inventory.indices {
            guard let stack = inventory[invIndex], stack.count > 0, itemDef(stack.id).name == name else { continue }
            let one = stack.copy()
            one.count = 1
            grid[gridIndex] = one
            stack.count -= 1
            if stack.count <= 0 { inventory[invIndex] = nil }
            break
        }
    }
    return true
}

private enum CraftingResourceOwner {
    case blockEntity(BlockEntityData, Int)
    case boat(Boat, Int)
    case minecart(Minecart, Int)

    func get() -> ItemStack? {
        switch self {
        case .blockEntity(let be, let slot):
            guard let items = be.items, slot >= 0, slot < items.count else { return nil }
            return items[slot]
        case .boat(let boat, let slot):
            return slot >= 0 && slot < boat.chestItems.count ? boat.chestItems[slot] : nil
        case .minecart(let cart, let slot):
            return slot >= 0 && slot < cart.chestItems.count ? cart.chestItems[slot] : nil
        }
    }

    func set(_ stack: ItemStack?) {
        switch self {
        case .blockEntity(let be, let slot):
            guard var items = be.items, slot >= 0, slot < items.count else { return }
            items[slot] = stack
            be.items = items
        case .boat(let boat, let slot):
            guard slot >= 0 && slot < boat.chestItems.count else { return }
            boat.chestItems[slot] = stack
        case .minecart(let cart, let slot):
            guard slot >= 0 && slot < cart.chestItems.count else { return }
            cart.chestItems[slot] = stack
        }
    }

    func markDirty(in world: World) {
        switch self {
        case .blockEntity(let be, _):
            world.setBlockEntity(be)
        case .boat, .minecart:
            break
        }
    }
}

private struct CraftingResourceSlot {
    let owner: CraftingResourceOwner
    let distanceKey: Int
    let x: Int
    let y: Int
    let z: Int
    let slot: Int
}

private func isCraftingTableResourceContainer(_ be: BlockEntityData) -> Bool {
    guard let items = be.items, !items.isEmpty else { return false }
    return be.type == "container" || be.type == "hopper" || be.type == "furnace" || be.type == "brewing"
}

private func craftingDistanceSquared(_ ax: Int, _ ay: Int, _ az: Int, _ bx: Int, _ by: Int, _ bz: Int) -> Int {
    let dx = ax - bx, dy = ay - by, dz = az - bz
    return dx * dx + dy * dy + dz * dz
}

public func nearbyCraftingTableContainers(in world: World, tableX: Int, tableY: Int, tableZ: Int,
                                          radius: Int = CRAFTING_TABLE_CONTAINER_RADIUS) -> [BlockEntityData] {
    let r2 = radius * radius
    var out: [BlockEntityData] = []
    let chunks = world.chunks.values.sorted {
        if $0.cx != $1.cx { return $0.cx < $1.cx }
        return $0.cz < $1.cz
    }
    for chunk in chunks {
        for be in chunk.blockEntities.values where isCraftingTableResourceContainer(be) {
            if craftingDistanceSquared(tableX, tableY, tableZ, be.x, be.y, be.z) <= r2 {
                out.append(be)
            }
        }
    }
    out.sort {
        let ad = craftingDistanceSquared(tableX, tableY, tableZ, $0.x, $0.y, $0.z)
        let bd = craftingDistanceSquared(tableX, tableY, tableZ, $1.x, $1.y, $1.z)
        if ad != bd { return ad < bd }
        if $0.y != $1.y { return $0.y < $1.y }
        if $0.z != $1.z { return $0.z < $1.z }
        if $0.x != $1.x { return $0.x < $1.x }
        return $0.type < $1.type
    }
    return out
}

private func nearbyCraftingResourceSlots(in world: World, tableX: Int, tableY: Int, tableZ: Int,
                                         radius: Int) -> [CraftingResourceSlot] {
    let r2 = radius * radius
    var slots: [CraftingResourceSlot] = []

    for be in nearbyCraftingTableContainers(in: world, tableX: tableX, tableY: tableY, tableZ: tableZ, radius: radius) {
        let d2 = craftingDistanceSquared(tableX, tableY, tableZ, be.x, be.y, be.z)
        for i in 0..<(be.items?.count ?? 0) {
            slots.append(CraftingResourceSlot(owner: .blockEntity(be, i), distanceKey: d2 * 1000,
                                              x: be.x, y: be.y, z: be.z, slot: i))
        }
    }

    let tableCX = Double(tableX) + 0.5
    let tableCY = Double(tableY) + 0.5
    let tableCZ = Double(tableZ) + 0.5
    for entity in world.entities.sorted(by: { $0.id < $1.id }) where !entity.dead {
        if let boat = entity as? Boat, boat.hasChest {
            let dx = boat.x - tableCX, dy = boat.y - tableCY, dz = boat.z - tableCZ
            let d2 = dx * dx + dy * dy + dz * dz
            guard d2 <= Double(r2) else { continue }
            let key = Int((d2 * 1000).rounded(.down))
            let ex = ifloor(boat.x), ey = ifloor(boat.y), ez = ifloor(boat.z)
            for i in 0..<boat.chestItems.count {
                slots.append(CraftingResourceSlot(owner: .boat(boat, i), distanceKey: key,
                                                  x: ex, y: ey, z: ez, slot: i))
            }
        } else if let cart = entity as? Minecart, cart.variant == "chest" || cart.variant == "hopper" {
            let dx = cart.x - tableCX, dy = cart.y - tableCY, dz = cart.z - tableCZ
            let d2 = dx * dx + dy * dy + dz * dz
            guard d2 <= Double(r2) else { continue }
            let key = Int((d2 * 1000).rounded(.down))
            let ex = ifloor(cart.x), ey = ifloor(cart.y), ez = ifloor(cart.z)
            for i in 0..<cart.chestItems.count {
                slots.append(CraftingResourceSlot(owner: .minecart(cart, i), distanceKey: key,
                                                  x: ex, y: ey, z: ez, slot: i))
            }
        }
    }

    slots.sort {
        if $0.distanceKey != $1.distanceKey { return $0.distanceKey < $1.distanceKey }
        if $0.y != $1.y { return $0.y < $1.y }
        if $0.z != $1.z { return $0.z < $1.z }
        if $0.x != $1.x { return $0.x < $1.x }
        return $0.slot < $1.slot
    }
    return slots
}

public func craftingTableResourceStacks(playerInventory: [ItemStack?], craftGrid: [ItemStack?],
                                        world: World, tableX: Int, tableY: Int, tableZ: Int,
                                        radius: Int = CRAFTING_TABLE_CONTAINER_RADIUS) -> [ItemStack?] {
    var stacks = (playerInventory + craftGrid).map(copyStack)
    for slot in nearbyCraftingResourceSlots(in: world, tableX: tableX, tableY: tableY, tableZ: tableZ, radius: radius) {
        guard let stack = slot.owner.get(), stack.count > 0 else { continue }
        stacks.append(stack.copy())
    }
    return stacks
}

private func addStackCounts(_ stacks: [ItemStack?], to counts: inout [String: Int]) {
    for stack in stacks {
        guard let stack, stack.count > 0 else { continue }
        counts[itemDef(stack.id).name, default: 0] += stack.count
    }
}

private func addNearbySlotCounts(_ slots: [CraftingResourceSlot], to counts: inout [String: Int]) {
    for slot in slots {
        guard let stack = slot.owner.get(), stack.count > 0 else { continue }
        counts[itemDef(stack.id).name, default: 0] += stack.count
    }
}

private func hasConcreteIngredients(_ ingredients: [String?], in countsIn: [String: Int]) -> Bool {
    var counts = countsIn
    for name in ingredients.compactMap({ $0 }) {
        guard (counts[name] ?? 0) > 0 else { return false }
        counts[name, default: 0] -= 1
    }
    return true
}

private func withdrawOneConcreteIngredient(_ name: String, inventory: inout [ItemStack?],
                                           slots: [CraftingResourceSlot], world: World) -> ItemStack? {
    for i in inventory.indices {
        guard let stack = inventory[i], stack.count > 0, itemDef(stack.id).name == name else { continue }
        let one = stack.copy()
        one.count = 1
        stack.count -= 1
        if stack.count <= 0 { inventory[i] = nil }
        return one
    }
    for slot in slots {
        guard let stack = slot.owner.get(), stack.count > 0, itemDef(stack.id).name == name else { continue }
        let one = stack.copy()
        one.count = 1
        stack.count -= 1
        if stack.count <= 0 { slot.owner.set(nil) }
        slot.owner.markDirty(in: world)
        return one
    }
    return nil
}

public func populateCraftingGridFromNearbyContainers(_ plan: CraftingRecipePlan, grid: inout [ItemStack?],
                                                     inventory: inout [ItemStack?], world: World,
                                                     tableX: Int, tableY: Int, tableZ: Int,
                                                     radius: Int = CRAFTING_TABLE_CONTAINER_RADIUS) -> Bool {
    guard grid.count == plan.ingredients.count else { return false }
    guard grid.allSatisfy({ $0 == nil }) else { return false }

    let slots = nearbyCraftingResourceSlots(in: world, tableX: tableX, tableY: tableY, tableZ: tableZ, radius: radius)
    var counts = inventoryCounts(inventory)
    addNearbySlotCounts(slots, to: &counts)
    guard hasConcreteIngredients(plan.ingredients, in: counts) else { return false }

    let originalGrid = grid.map(copyStack)
    let originalInventory = inventory.map(copyStack)
    let originalSlots = slots.map { ($0.owner, copyStack($0.owner.get())) }
    func rollback() {
        grid = originalGrid.map(copyStack)
        inventory = originalInventory.map(copyStack)
        for (owner, stack) in originalSlots {
            owner.set(copyStack(stack))
            owner.markDirty(in: world)
        }
    }

    for (gridIndex, name) in plan.ingredients.enumerated() {
        guard let name else { continue }
        guard let one = withdrawOneConcreteIngredient(name, inventory: &inventory, slots: slots, world: world) else {
            rollback()
            return false
        }
        grid[gridIndex] = one
    }
    return true
}

@discardableResult
public func giveStackToNearbyCraftingContainers(_ stackIn: ItemStack?, world: World,
                                                tableX: Int, tableY: Int, tableZ: Int,
                                                radius: Int = CRAFTING_TABLE_CONTAINER_RADIUS) -> Bool {
    guard let stack = stackIn else { return false }
    let slots = nearbyCraftingResourceSlots(in: world, tableX: tableX, tableY: tableY, tableZ: tableZ, radius: radius)

    for slot in slots where stack.count > 0 {
        guard let existing = slot.owner.get(), canMerge(existing, stack), existing.count < maxStackOf(existing) else { continue }
        let take = min(maxStackOf(existing) - existing.count, stack.count)
        existing.count += take
        stack.count -= take
        slot.owner.markDirty(in: world)
    }
    for slot in slots where stack.count > 0 {
        guard slot.owner.get() == nil else { continue }
        let moved = stack.copy()
        moved.count = min(maxStackOf(stack), stack.count)
        slot.owner.set(moved)
        stack.count -= moved.count
        slot.owner.markDirty(in: world)
    }
    return stack.count <= 0
}

/// match a w×h grid of stacks against all recipes; returns output or nil
public func matchCrafting(_ grid: [ItemStack?], _ gw: Int, _ gh: Int) -> (out: ItemStack, recipe: CraftRecipe)? {
    // trim grid to bounding box
    var minX = gw, minY = gh, maxX = -1, maxY = -1
    for y in 0..<gh {
        for x in 0..<gw {
            if grid[y * gw + x] != nil {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    if maxX < 0 { return nil }
    let bw = maxX - minX + 1, bh = maxY - minY + 1

    for r in craftingRecipes {
        switch r {
        case .shapeless(let inputs, let out, let count):
            var ok = true
            var used = [Bool](repeating: false, count: gw * gh)
            for ing in inputs {
                var found = false
                for i in 0..<grid.count {
                    if used[i] || grid[i] == nil { continue }
                    if ingMatches(ing, grid[i]) { used[i] = true; found = true; break }
                }
                if !found { ok = false; break }
            }
            if ok {
                // no extra items
                var extra = false
                for i in 0..<grid.count where grid[i] != nil && !used[i] { extra = true }
                if !extra { return (ItemStack(iid(out), count), r) }
            }
        case .shaped(let rw, let rh, let rgrid, let out, let count):
            if rw != bw || rh != bh { continue }
            for mirror in [false, true] {
                var ok = true
                for y in 0..<bh where ok {
                    for x in 0..<bw where ok {
                        let rx = mirror ? bw - 1 - x : x
                        let ing = rgrid[y * rw + rx]
                        let stack = grid[(minY + y) * gw + (minX + x)]
                        if ing == nil { if stack != nil { ok = false } }
                        else if !ingMatches(ing!, stack) { ok = false }
                    }
                }
                if ok { return (ItemStack(iid(out), count), r) }
            }
        }
    }
    return nil
}

/// consume one of each ingredient; returns container items (buckets/bottles)
public func consumeCraftingGrid(_ grid: inout [ItemStack?]) -> [ItemStack] {
    var returns: [ItemStack] = []
    for i in 0..<grid.count {
        guard let s = grid[i] else { continue }
        let name = itemDef(s.id).name
        if name == "milk_bucket" || name == "water_bucket" || name == "lava_bucket" {
            returns.append(ItemStack(iid("bucket"), 1))
        }
        if name == "honey_bottle" { returns.append(ItemStack(iid("glass_bottle"), 1)) }
        s.count -= 1
        if s.count <= 0 { grid[i] = nil }
    }
    return returns
}

/// smithing: template + base + addition
public func matchSmithing(_ template: ItemStack?, _ base: ItemStack?, _ addition: ItemStack?) -> ItemStack? {
    guard let template, let base, let addition else { return nil }
    let tName = itemDef(template.id).name
    let bName = itemDef(base.id).name
    let aName = itemDef(addition.id).name
    for r in smithingRecipes {
        if r.template != tName { continue }
        if r.output == "trim" {
            // any armor + trim material
            if itemDef(base.id).armor == nil { continue }
            if !TRIM_MATERIALS.contains(aName) { continue }
            let out = base.copy()
            out.data.trim = TrimData(pattern: tName.replacingOccurrences(of: "_armor_trim", with: ""), material: aName)
            return out
        }
        if r.base == bName && r.addition == aName {
            let out = base.copy()
            out.id = iid(r.output)
            return out
        }
    }
    return nil
}

// ---------------------------------------------------------------------------
// Enchanting table
// ---------------------------------------------------------------------------
public struct EnchantOption {
    public var level: Int          // XP level cost requirement
    public var lapis: Int          // 1-3
    public var preview: EnchInstance?
    public var enchants: [EnchInstance]
}

public func enchantingOptions(_ item: ItemStack?, _ bookshelves: Int, _ seed: Int) -> [EnchantOption] {
    var out: [EnchantOption] = []
    guard let item else { return out }
    let def = itemDef(item.id)
    let isBook = def.name == "book"
    if !isBook && !ENCHANTMENTS.contains(where: { appliesTo($0, def) }) { return out }
    if !item.ench.isEmpty { return out } // already enchanted
    var rng = RandomX(UInt32(truncatingIfNeeded: seed))
    let b = min(15, bookshelves)
    let base = rng.nextInt(8) + 1 + (b >> 1) + rng.nextInt(b + 1)
    let levels = [
        Int(max(Double(base) / 3, 1)),
        Int(Double(base) * 2 / 3 + 1),
        max(base, b * 2),
    ]
    for slot in 0..<3 {
        let level = levels[slot]
        var slotRng = RandomX(UInt32(truncatingIfNeeded: seed + slot * 947))
        let enchants = selectEnchants(item, level, &slotRng)
        out.append(EnchantOption(level: level, lapis: slot + 1, preview: enchants.first, enchants: enchants))
    }
    return out
}

private func selectEnchants(_ item: ItemStack, _ level: Int, _ rng: inout RandomX) -> [EnchInstance] {
    let def = itemDef(item.id)
    let isBook = def.name == "book"
    let enchValue = enchantability(def)
    var modLevel = level + 1 + rng.nextInt((enchValue >> 2) + 1) + rng.nextInt((enchValue >> 2) + 1)
    let bonus = 1 + (rng.nextFloat() + rng.nextFloat() - 1) * 0.15
    modLevel = max(1, Int(detRound(Double(modLevel) * bonus)))
    var picked: [EnchInstance] = []
    var candidates: [(e: EnchantmentDef, lvl: Int)] = []
    for e in ENCHANTMENTS {
        if e.treasure || e.curse { continue }
        if !isBook && !appliesTo(e, def) { continue }
        var l = e.maxLevel
        while l >= 1 {
            if modLevel >= e.minPower(l) && modLevel <= e.maxPower(l) {
                candidates.append((e, l))
                break
            }
            l -= 1
        }
    }
    if candidates.isEmpty { return picked }
    let first = rng.pickWeighted(candidates) { Double($0.e.weight) }
    picked.append(EnchInstance(first.e.id, first.lvl))
    var lvl2 = modLevel
    while rng.nextFloat() < Double(lvl2 + 1) / 50 {
        lvl2 = Int((Double(lvl2) / 2).rounded(.down))
        let remaining = candidates.filter { c in
            picked.allSatisfy { p in compatible(c.e, enchDef(p.id)) } && !picked.contains { $0.id == c.e.id }
        }
        if remaining.isEmpty { break }
        let next = rng.pickWeighted(remaining) { Double($0.e.weight) }
        picked.append(EnchInstance(next.e.id, next.lvl))
    }
    return picked
}

public func applyEnchanting(_ item: ItemStack, _ option: EnchantOption) -> ItemStack {
    let def = itemDef(item.id)
    if def.name == "book" {
        return ItemStack(iid("enchanted_book"), 1, ench: option.enchants)
    }
    let result = item.copy()
    result.ench = option.enchants
    return result
}

// ---------------------------------------------------------------------------
// Anvil
// ---------------------------------------------------------------------------
public struct AnvilResult {
    public var out: ItemStack
    public var cost: Int
}

private let REPAIR_MATS: [String: String] = [
    "leather": "leather", "chainmail": "iron_ingot", "iron": "iron_ingot", "golden": "gold_ingot",
    "diamond": "diamond", "netherite": "netherite_ingot", "turtle": "scute", "elytra": "phantom_membrane",
    "wooden": "oak_planks", "stone": "cobblestone",
]

public func anvilCombine(_ left: ItemStack?, _ right: ItemStack?, _ rename: String?) -> AnvilResult? {
    guard let left else { return nil }
    let out = left.copy()
    var cost = 0.0
    let prior = (left.data.priorWork ?? 0) + (right?.data.priorWork ?? 0)
    cost += pow(2, Double(left.data.priorWork ?? 0)) - 1
    if let right { cost += pow(2, Double(right.data.priorWork ?? 0)) - 1 }

    if let right {
        let ldef = itemDef(left.id), rdef = itemDef(right.id)
        let rName = rdef.name
        let material: String? = ldef.tool != nil
            ? REPAIR_MATS[String(ldef.name.split(separator: "_")[0])]
            : ldef.armor != nil ? REPAIR_MATS[ldef.armor!.material] : nil
        if rName == "enchanted_book" && !right.ench.isEmpty {
            // book apply
            var newEnch = out.ench
            var applied = false
            for be in right.ench {
                let e = enchDef(be.id)
                if itemDef(left.id).name != "enchanted_book" && !appliesTo(e, ldef) { continue }
                let conflict = newEnch.contains { $0.id != be.id && !compatible(e, enchDef($0.id)) }
                if conflict { cost += 1; continue }
                if let idx = newEnch.firstIndex(where: { $0.id == be.id }) {
                    newEnch[idx].lvl = newEnch[idx].lvl == be.lvl ? min(e.maxLevel, newEnch[idx].lvl + 1) : max(newEnch[idx].lvl, be.lvl)
                } else {
                    newEnch.append(be)
                }
                cost += Double(be.lvl) * (e.weight >= 10 ? 1 : e.weight >= 5 ? 2 : e.weight >= 2 ? 4 : 8) / 2
                applied = true
            }
            if !applied { return nil }
            out.ench = newEnch
        } else if let material, rName == material {
            // unit repair: each mat repairs 25%
            let maxD = ldef.tool?.durability ?? ldef.armor?.durability ?? 0
            if maxD == 0 || left.damage == 0 { return nil }
            let quarter = Int((Double(maxD) / 4).rounded(.up))
            let units = min(right.count, Int((Double(left.damage) / (Double(maxD) / 4)).rounded(.up)))
            out.damage = max(0, left.damage - units * quarter)
            cost += Double(units)
            out.data.repairUnits = units
        } else if right.id == left.id {
            // combine same items
            let maxD = ldef.tool?.durability ?? ldef.armor?.durability ?? 0
            if maxD != 0 {
                let totalLife = (maxD - left.damage) + (maxD - right.damage) + Int((Double(maxD) * 0.12).rounded(.down))
                out.damage = max(0, maxD - totalLife)
                cost += 2
            }
            // merge enchants
            if !right.ench.isEmpty {
                var newEnch = out.ench
                for be in right.ench {
                    let e = enchDef(be.id)
                    let conflict = newEnch.contains { $0.id != be.id && !compatible(e, enchDef($0.id)) }
                    if conflict { cost += 1; continue }
                    if let idx = newEnch.firstIndex(where: { $0.id == be.id }) {
                        newEnch[idx].lvl = newEnch[idx].lvl == be.lvl ? min(e.maxLevel, newEnch[idx].lvl + 1) : max(newEnch[idx].lvl, be.lvl)
                    } else { newEnch.append(be) }
                    cost += Double(be.lvl)
                }
                out.ench = newEnch
            }
        } else {
            return nil
        }
    }
    if let rename, rename != (left.label ?? "") {
        out.label = rename.isEmpty ? nil : rename
        cost += 1
    }
    if cost <= 0 { return nil }
    out.data.priorWork = prior + 1
    return AnvilResult(out: out, cost: min(39, Int(cost.rounded(.up))))
}

/// grindstone: strip enchants, repair by combining, return XP value
public func grindstoneResult(_ a: ItemStack?, _ b: ItemStack?) -> (out: ItemStack, xp: Int)? {
    guard let item = a ?? b else { return nil }
    if let a, let b, a.id != b.id { return nil }
    let def = itemDef(item.id)
    let out = item.copy()
    var xp = 0
    if !out.ench.isEmpty {
        for e in out.ench {
            if !enchDef(e.id).curse { xp += enchDef(e.id).minPower(e.lvl) }
        }
        out.ench = out.ench.filter { enchDef($0.id).curse }
    }
    if let a, let b {
        let maxD = def.tool?.durability ?? def.armor?.durability ?? 0
        if maxD != 0 {
            let totalLife = (maxD - a.damage) + (maxD - b.damage) + Int((Double(maxD) * 0.05).rounded(.down))
            out.damage = max(0, maxD - totalLife)
        }
    }
    if def.name == "enchanted_book" && out.ench.isEmpty {
        out.id = iid("book")
    }
    out.data = StackData()
    return (out, min(50, Int((Double(xp) / 2).rounded(.up))))
}
