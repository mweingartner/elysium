import Foundation

/// Reorders a slot snapshot without changing a stack or consulting mutable UI state.
/// Invalid item IDs fail closed with `nil`, so a caller never mistakes rejection for a valid
/// unchanged snapshot and can prove that no owning-slot writes took place.
public func sortedInventoryStacks(_ stacks: [ItemStack?]) -> [ItemStack?]? {
    // Validate every occupied entry before the first registry lookup.  In particular, do not
    // use `itemDef` here: malformed decoded stacks must not be able to trap an inventory UI.
    guard stacks.allSatisfy({ stack in
        guard let stack else { return true }
        return stack.id >= 0 && stack.id < itemDefs.count
    }) else {
        return nil
    }

    struct Decorated {
        let stack: ItemStack
        let display: String
        let category: String
        let canonical: String
        let id: Int
        let index: Int
    }

    let occupied: [Decorated] = stacks.enumerated().compactMap { index, stack in
        guard let stack else { return nil }
        let definition = itemDefs[stack.id]
        return Decorated(stack: stack,
                         display: inventorySortASCIIFold(definition.displayName),
                         category: inventorySortASCIIFold(definition.category),
                         canonical: inventorySortASCIIFold(definition.name),
                         id: definition.id,
                         index: index)
    }
    let ordered = occupied.sorted { left, right in
        if left.display != right.display { return left.display < right.display }
        if left.category != right.category { return left.category < right.category }
        if left.canonical != right.canonical { return left.canonical < right.canonical }
        if left.id != right.id { return left.id < right.id }
        return left.index < right.index
    }
    return ordered.map(\.stack) + Array(repeating: nil, count: stacks.count - ordered.count)
}

/// Locale-independent ASCII-only folding for deterministic persisted/UI ordering.
/// It is intentionally internal so the pure policy is directly testable without exposing a
/// second production sorting API.
func inventorySortASCIIFold(_ value: String) -> String {
    String(value.unicodeScalars.map { scalar in
        guard scalar.value >= 65 && scalar.value <= 90 else { return Character(String(scalar)) }
        return Character(UnicodeScalar(scalar.value + 32)!)
    })
}
