// Advancements — definition tree, trigger
// API, persistence-ready state. earned keeps insertion order (deterministic Set).

import Foundation

public struct AdvancementDef {
    public let id: String
    public let title: String
    public let description: String
    public let icon: String            // item name for the icon
    public let parent: String?
    public let frame: String           // task | goal | challenge
}

public let ADVANCEMENTS: [AdvancementDef] = {
    var A: [AdvancementDef] = []
    func adv(_ id: String, _ title: String, _ description: String, _ icon: String, _ parent: String?, _ frame: String = "task") {
        A.append(AdvancementDef(id: id, title: title, description: description, icon: icon, parent: parent, frame: frame))
    }

    // story (main progression)
    adv("root", "Elysium", "The heart and story of the game", "grass_block", nil)
    adv("mine_log", "Getting Wood", "Punch a tree until a block of wood pops out", "oak_log", "root")
    adv("crafting_table", "Benchmarking", "Craft a crafting table", "crafting_table", "mine_log")
    adv("wooden_pickaxe", "Time to Mine!", "Use planks and sticks to make a pickaxe", "wooden_pickaxe", "crafting_table")
    adv("mine_stone", "Stone Age", "Mine stone with your new pickaxe", "cobblestone", "wooden_pickaxe")
    adv("stone_pickaxe", "Getting an Upgrade", "Construct a better pickaxe", "stone_pickaxe", "mine_stone")
    adv("iron_ingot", "Acquire Hardware", "Smelt an iron ingot", "iron_ingot", "stone_pickaxe")
    adv("iron_tools", "Isn't It Iron Pick", "Upgrade your pickaxe", "iron_pickaxe", "iron_ingot")
    adv("iron_armor", "Suit Up", "Protect yourself with a piece of iron armor", "iron_chestplate", "iron_ingot")
    adv("mine_diamond", "Diamonds!", "Acquire diamonds", "diamond", "iron_tools")
    adv("diamond_armor", "Cover Me with Diamonds", "Diamond armor saves lives", "diamond_chestplate", "mine_diamond")
    adv("enchant_item", "Enchanter", "Enchant an item at an enchanting table", "enchanting_table", "mine_diamond")
    adv("ignite_portal", "We Need to Go Deeper", "Build, light and enter a Nether portal", "flint_and_steel", "mine_diamond")
    adv("return_portal", "Return to Sender", "Destroy a Ghast with a fireball", "fire_charge", "ignite_portal", "challenge")
    adv("obtain_blaze_rod", "Into Fire", "Relieve a Blaze of its rod", "blaze_rod", "ignite_portal")
    adv("brew_potion", "Local Brewery", "Brew a potion", "brewing_stand", "obtain_blaze_rod")
    adv("ender_eye", "Eye for an Eye", "Obtain an Eye of Ender", "ender_eye", "obtain_blaze_rod")
    adv("follow_ender_eye", "Eye Spy", "Throw an Eye of Ender", "ender_eye", "obtain_blaze_rod")
    adv("enter_end", "The End?", "Enter the End portal", "end_stone", "ender_eye")
    adv("kill_dragon", "Free the End", "Good luck", "dragon_head", "enter_end", "goal")
    adv("dragon_egg", "The Next Generation", "Hold the Dragon Egg", "dragon_egg", "kill_dragon")
    adv("enter_gateway", "Remote Getaway", "Escape the island", "ender_pearl", "kill_dragon")
    adv("elytra", "Sky's the Limit", "Find an Elytra", "elytra", "enter_gateway")
    adv("dragon_breath", "You Need a Mint", "Collect Dragon's Breath in a glass bottle", "dragon_breath", "kill_dragon", "goal")

    // nether branch
    adv("nether_root", "Nether", "Bring summer clothes", "netherrack", "ignite_portal")
    adv("find_fortress", "A Terrible Fortress", "Break your way into a Nether Fortress", "nether_bricks", "nether_root")
    adv("obtain_ancient_debris", "Hidden in the Depths", "Obtain Ancient Debris", "ancient_debris", "nether_root")
    adv("netherite_armor", "Cover Me in Debris", "Get a full suit of Netherite armor", "netherite_chestplate", "obtain_ancient_debris", "challenge")
    adv("find_bastion", "Those Were the Days", "Enter a Bastion Remnant", "gilded_blackstone", "nether_root")
    adv("distract_piglin", "Oh Shiny", "Distract Piglins with gold", "gold_ingot", "find_bastion")
    adv("kill_wither", "Withering Heights", "Summon and defeat the Wither", "nether_star", "find_fortress", "challenge")
    adv("beacon", "Bring Home the Beacon", "Construct and place a beacon", "beacon", "kill_wither")

    // adventure branch
    adv("adventure_root", "Adventure", "Adventure, exploration and combat", "compass", "root")
    adv("kill_mob", "Monster Hunter", "Kill any hostile monster", "iron_sword", "adventure_root")
    adv("shoot_arrow", "Take Aim", "Shoot something with an arrow", "bow", "kill_mob")
    adv("sleep_in_bed", "Sweet Dreams", "Sleep in a bed to change your respawn point", "red_bed", "adventure_root")
    adv("trade_villager", "What a Deal!", "Successfully trade with a Villager", "emerald", "adventure_root")
    adv("totem", "Postmortal", "Use a Totem of Undying to cheat death", "totem_of_undying", "kill_mob", "goal")
    adv("sniper_duel", "Sniper Duel", "Kill a Skeleton from at least 50 meters away", "arrow", "shoot_arrow", "challenge")
    adv("hero_village", "Hero of the Village", "Successfully defend a village from a raid", "iron_axe", "kill_mob", "challenge")
    adv("brush_sherd", "Respecting the Remnants", "Brush a suspicious block to obtain a pottery sherd", "brush", "adventure_root")
    adv("avoid_warden", "It Spreads", "Kill a mob near a Sculk Catalyst", "sculk_catalyst", "kill_mob")
    adv("lightning_rod", "Surge Protector", "Protect a villager from a lightning strike", "lightning_rod", "adventure_root")

    // husbandry
    adv("husbandry_root", "Husbandry", "The world is full of friends and food", "wheat", "root")
    adv("husbandry_eat", "A First Bite", "Eat anything", "apple", "husbandry_root")
    adv("breed_animals", "The Parrots and the Bats", "Breed two animals together", "wheat", "husbandry_root")
    adv("tame_animal", "Best Friends Forever", "Tame an animal", "bone", "husbandry_root")
    adv("plant_seed", "A Seedy Place", "Plant a seed and watch it grow", "wheat_seeds", "husbandry_root")
    adv("fish", "Fishy Business", "Catch a fish", "fishing_rod", "husbandry_root")
    adv("tactical_fishing", "Tactical Fishing", "Catch a fish... without a fishing rod!", "pufferfish_bucket", "fish")
    adv("sniffer_egg", "Smells Interesting", "Obtain a Sniffer Egg", "sniffer_egg", "husbandry_root")
    adv("plant_torchflower", "Planting the Past", "Plant any Sniffer seed", "torchflower_seeds", "sniffer_egg")
    adv("full_beehive", "Total Beelocation", "Move a bee nest with silk touch", "bee_nest", "husbandry_root")
    adv("axolotl_bucket", "The Cutest Predator", "Catch an axolotl in a bucket", "axolotl_bucket", "husbandry_root")
    adv("wax_copper", "Wax On", "Apply honeycomb to a copper block", "honeycomb", "husbandry_root")

    return A
}()

public let ADV_BY_ID: [String: AdvancementDef] = Dictionary(uniqueKeysWithValues: ADVANCEMENTS.map { ($0.id, $0) })

public final class AdvancementTracker {
    /// insertion-ordered (deterministic Set semantics)
    public private(set) var earnedOrder: [String] = []
    private var earnedSet = Set<String>()
    public var pendingToasts: [AdvancementDef] = []

    public init() {}

    @discardableResult
    public func grant(_ id: String) -> Bool {
        if earnedSet.contains(id) { return false }
        guard let def = ADV_BY_ID[id] else { return false }
        addEarned(id)
        // auto-grant parents (silently)
        var p = def.parent
        while let cur = p {
            addEarned(cur)
            p = ADV_BY_ID[cur]?.parent
        }
        pendingToasts.append(def)
        return true
    }
    private func addEarned(_ id: String) {
        if earnedSet.insert(id).inserted {
            earnedOrder.append(id)
        }
    }
    public func has(_ id: String) -> Bool { earnedSet.contains(id) }
    public func save() -> [String] { earnedOrder }
    public func load(_ ids: [String]) {
        earnedOrder = []
        earnedSet = []
        for id in ids { addEarned(id) }
    }
}
