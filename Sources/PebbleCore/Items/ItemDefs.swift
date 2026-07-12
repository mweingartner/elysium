// Item registry — Block items auto-generate from
// the block registry; registration order mirrors baseline for id parity.

import Foundation

/// Display names required by pure RPG creation review before the global item registry boots.
/// `registerItem` consumes this same table, so pre-bootstrap review and the live registry cannot
/// silently drift. Keep this closed: unknown IDs must not acquire a prettified RPG Review fallback.
public let RPG_STARTER_KIT_ITEM_REGISTRATION_DISPLAY_NAMES: [String: String] = [
    "stone_sword": "Stone Sword",
    "shield": "Shield",
    "bread": "Bread",
    "bow": "Bow",
    "arrow": "Arrow",
    "stone_pickaxe": "Stone Pickaxe",
    "torch": "Torch",
    "apprentice_focus": "Apprentice Focus",
    "potion": "Potion",
    "redstone": "Redstone",
]

public func rpgStarterKitItemRegistrationDisplayName(_ name: String) -> String? {
    RPG_STARTER_KIT_ITEM_REGISTRATION_DISPLAY_NAMES[name]
}

public struct FoodDef {
    public let hunger: Int
    public let saturation: Double
    public let alwaysEat: Bool
    public let meat: Bool
    public let fast: Bool
    public let effects: [(effect: String, duration: Int, amplifier: Int, chance: Double)]

    public init(hunger: Int, saturation: Double, alwaysEat: Bool = false, meat: Bool = false, fast: Bool = false,
                effects: [(effect: String, duration: Int, amplifier: Int, chance: Double)] = []) {
        self.hunger = hunger
        self.saturation = saturation
        self.alwaysEat = alwaysEat
        self.meat = meat
        self.fast = fast
        self.effects = effects
    }
}

public struct ToolDef {
    public let type: String   // pickaxe/axe/shovel/hoe/sword/shears/flint_and_steel/fishing_rod/bow/crossbow/trident/brush
    public let tier: Int
    public let speed: Double
    public let attackDamage: Double
    public let attackSpeed: Double
    public let durability: Int
    public let enchantability: Int

    public init(_ type: String, tier: Int, speed: Double, attackDamage: Double, attackSpeed: Double, durability: Int, enchantability: Int) {
        self.type = type; self.tier = tier; self.speed = speed
        self.attackDamage = attackDamage; self.attackSpeed = attackSpeed
        self.durability = durability; self.enchantability = enchantability
    }
}

public struct ArmorDef {
    public let slot: Int       // 0 head 1 chest 2 legs 3 feet
    public let defense: Int
    public let toughness: Double
    public let knockbackRes: Double
    public let durability: Int
    public let enchantability: Int
    public let material: String

    public init(slot: Int, defense: Int, toughness: Double, knockbackRes: Double, durability: Int, enchantability: Int, material: String) {
        self.slot = slot; self.defense = defense; self.toughness = toughness
        self.knockbackRes = knockbackRes; self.durability = durability
        self.enchantability = enchantability; self.material = material
    }
}

public final class ItemDef {
    public let id: Int
    public let name: String
    public let displayName: String
    public var maxStack: Int
    public let block: UInt16?
    public let food: FoodDef?
    public let tool: ToolDef?
    public let armor: ArmorDef?
    public let category: String
    public let icon: String
    public let burnTime: Int
    public let rarity: Int
    public let compostChance: Double

    init(id: Int, name: String, displayName: String, maxStack: Int, block: UInt16?, food: FoodDef?,
         tool: ToolDef?, armor: ArmorDef?, category: String, icon: String, burnTime: Int, rarity: Int, compostChance: Double) {
        self.id = id; self.name = name; self.displayName = displayName; self.maxStack = maxStack
        self.block = block; self.food = food; self.tool = tool; self.armor = armor
        self.category = category; self.icon = icon; self.burnTime = burnTime
        self.rarity = rarity; self.compostChance = compostChance
    }
}

/// enchantment instance on a stack
public struct EnchInstance: Equatable, Codable {
    public var id: String
    public var lvl: Int
    public init(_ id: String, _ lvl: Int) { self.id = id; self.lvl = lvl }
}

/// armor trim payload — mirrors baseline `data.trim = { pattern, material }`
public struct TrimData: Equatable, Codable {
    public var pattern: String
    public var material: String
    public init(pattern: String, material: String) {
        self.pattern = pattern
        self.material = material
    }
}

/// stack `data` payload (potion id, armor trim, sherds, anvil work, …)
public struct StackData: Equatable, Codable {
    public var potion: String?
    public var trim: TrimData?
    public var sherds: [String]?
    public var charged: Bool?
    public var priorWork: Int?
    public var repairUnits: Int?
    /// shulker-box carried inventory
    public var contents: [ItemStack?]?
    /// lodestone compass target [x, y, z, dim]
    public var lodestone: [Int]?
    /// firework flight duration
    public var flight: Int?

    public init() {}
    public var isEmpty: Bool {
        potion == nil && trim == nil && sherds == nil && charged == nil
            && priorWork == nil && repairUnits == nil && contents == nil
            && lodestone == nil && flight == nil
    }
}

/// Reference type on purpose: the golden baselines passes stacks around as shared
/// mutable objects (give() mutates the caller's stack, mending repairs items
/// in place, containers move the same object between slots). All stored
/// fields are value types, so copy() is a deep copy (baseline copyStack).
public final class ItemStack: Equatable, Codable {
    public var id: Int
    public var count: Int
    public var damage: Int
    public var ench: [EnchInstance]
    public var label: String?
    public var data: StackData

    public init(_ id: Int, _ count: Int = 1, damage: Int = 0, ench: [EnchInstance] = [], label: String? = nil, data: StackData = StackData()) {
        self.id = id
        self.count = count
        self.damage = damage
        self.ench = ench
        self.label = label
        self.data = data
    }

    public func copy() -> ItemStack {
        ItemStack(id, count, damage: damage, ench: ench, label: label, data: data)
    }

    public static func == (a: ItemStack, b: ItemStack) -> Bool {
        a.id == b.id && a.count == b.count && a.damage == b.damage
            && a.ench == b.ench && a.label == b.label && a.data == b.data
    }
}

public func copyStack(_ s: ItemStack?) -> ItemStack? { s?.copy() }

public var itemDefs: [ItemDef] = []
private var itemByName: [String: Int] = [:]
public var blockToItem = [Int32](repeating: -1, count: 4096)

@discardableResult
public func registerItem(
    _ name: String,
    display: String? = nil,
    maxStack: Int? = nil,
    block: UInt16? = nil,
    food: FoodDef? = nil,
    tool: ToolDef? = nil,
    armor: ArmorDef? = nil,
    category: String = "none",
    icon: String? = nil,
    burnTime: Int = 0,
    rarity: Int = 0,
    compostChance: Double = 0
) -> Int {
    precondition(itemByName[name] == nil, "duplicate item: \(name)")
    let id = itemDefs.count
    let def = ItemDef(
        id: id, name: name,
        displayName: rpgStarterKitItemRegistrationDisplayName(name) ?? display ?? prettify(name),
        maxStack: maxStack ?? ((tool != nil || armor != nil) ? 1 : 64),
        block: block, food: food, tool: tool, armor: armor,
        category: category,
        icon: icon ?? (block != nil ? "block" : name),
        burnTime: burnTime, rarity: rarity, compostChance: compostChance
    )
    itemDefs.append(def)
    itemByName[name] = id
    if let b = block, blockToItem[Int(b)] == -1 { blockToItem[Int(b)] = Int32(id) }
    return id
}

public func iid(_ name: String) -> Int {
    guard let id = itemByName[name] else { fatalError("unknown item: \(name)") }
    return id
}
public func iidOpt(_ name: String) -> Int? { itemByName[name] }
public func itemExists(_ name: String) -> Bool { itemByName[name] != nil }
public func itemDef(_ id: Int) -> ItemDef { itemDefs[id] }
public func itemName(_ id: Int) -> String { id < itemDefs.count ? itemDefs[id].name : "air" }
public func stack(_ name: String, _ count: Int = 1) -> ItemStack { ItemStack(iid(name), count) }

// MARK: - stack helpers

public func stacksEqual(_ a: ItemStack?, _ b: ItemStack?) -> Bool {
    guard let a, let b else { return a == nil && b == nil }
    return a.id == b.id && a.damage == b.damage && a.ench == b.ench
        && a.data == b.data && (a.label ?? "") == (b.label ?? "")
}
public func canMerge(_ a: ItemStack?, _ b: ItemStack?) -> Bool {
    guard let a, let b else { return false }
    if itemDefs[a.id].maxStack <= 1 { return false }
    return stacksEqual(a, b)
}
public func maxStackOf(_ s: ItemStack) -> Int { itemDefs[s.id].maxStack }
public func maxDamageOf(_ s: ItemStack) -> Int {
    let d = itemDefs[s.id]
    return d.tool?.durability ?? d.armor?.durability ?? 0
}
public func enchLevel(_ s: ItemStack?, _ ench: String) -> Int {
    guard let s else { return 0 }
    for e in s.ench where e.id == ench { return e.lvl }
    return 0
}
