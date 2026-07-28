#if ELYSIUM_DEBUG_CONTROL
import Foundation
import ElysiumCore
import ElysiumDebugProtocol

@MainActor
struct DebugScreenSemantics {
    let ui: UIManager
    let game: GameCore

    func snapshot() -> [String: JSONValue] {
        guard let screen = ui.current() else {
            return ["open": .bool(false)]
        }
        let slots = semanticSlots(for: screen)
        return [
            "open": .bool(true),
            "kind": .string(kind(of: screen)),
            "instance": .string(instanceID(of: screen)),
            "readOnly": .bool(screen.readOnlySlots),
            "cursor": DebugStackProjection.value(ui.cursorStack),
            "state": semanticState(for: screen),
            "slots": .array(slots.keys.sorted().map { name in
                .object([
                    "id": .string(name),
                    "item": DebugStackProjection.value(slots[name]?.get() ?? nil),
                    "output": .bool(slots[name]?.output ?? false),
                ])
            }),
            "buttons": .array(semanticButtons(for: screen).map { id, button in
                .object([
                    "id": .string(id),
                    "label": .string(button.label),
                    "enabled": .bool(button.enabled),
                    "visible": .bool(button.visible),
                ])
            }),
            "actions": .array(semanticActions(for: screen).map { action in
                .object(["id": .string(action.id), "label": .string(action.label),
                         "enabled": .bool(action.enabled)])
            }),
            "fields": .array(screen.fields.map { field in
                .object([
                    "id": .string(field.id),
                    "value": .string(field.text),
                    "enabled": .bool(field.enabled),
                    "focused": .bool(field.focused),
                ])
            }),
        ]
    }

    func activateSlot(_ id: String, button: Int, shift: Bool,
                      expectedInstance: String?) throws {
        guard let screen = ui.current() else { throw DebugSemanticError.noScreen }
        try validate(screen, expectedInstance: expectedInstance)
        guard !screen.readOnlySlots else { throw DebugSemanticError.readOnly }
        guard button == 0 || button == 2 else { throw DebugSemanticError.invalidAction }
        guard let slot = semanticSlots(for: screen)[id] else { throw DebugSemanticError.unknownElement }
        ui.handleSlotClick(game, screen, slot, button, shift: shift)
    }

    /// Moves or swaps two ordinary slots through the production click path while ensuring an
    /// abandoned one-shot control connection cannot strand an item on the shared UI cursor.
    /// Output slots remain available through a one-request shift click because taking an output
    /// may commit crafting, XP, or trade side effects before a destination is known.
    func transferSlot(from sourceID: String, to destinationID: String,
                      expectedInstance: String?) throws {
        guard let screen = ui.current() else { throw DebugSemanticError.noScreen }
        try validate(screen, expectedInstance: expectedInstance)
        guard !screen.readOnlySlots else { throw DebugSemanticError.readOnly }
        guard ui.cursorStack == nil, sourceID != destinationID else {
            throw DebugSemanticError.invalidAction
        }
        let slots = semanticSlots(for: screen)
        guard let source = slots[sourceID], let destination = slots[destinationID] else {
            throw DebugSemanticError.unknownElement
        }
        guard !source.output, !destination.output, source.get() != nil else {
            throw DebugSemanticError.invalidAction
        }

        ui.handleSlotClick(game, screen, source, 0)
        guard ui.cursorStack != nil else { throw DebugSemanticError.invalidAction }
        ui.handleSlotClick(game, screen, destination, 0)
        if ui.cursorStack != nil {
            // A full destination swaps, a partial merge leaves a remainder, and a rejected
            // destination leaves the original stack. A final click puts that stack back in the
            // now-empty source slot in all three cases.
            ui.handleSlotClick(game, screen, source, 0)
        }
        guard ui.cursorStack == nil else { throw DebugSemanticError.invalidAction }
    }

    func activateButton(_ id: String, expectedInstance: String?) throws {
        guard let screen = ui.current() else { throw DebugSemanticError.noScreen }
        try validate(screen, expectedInstance: expectedInstance)
        guard let match = semanticButtons(for: screen).first(where: { $0.0 == id })?.1,
              match.visible, match.enabled else { throw DebugSemanticError.unknownElement }
        game.playUISound("ui.button.click")
        match.onClick()
    }

    /// Activates non-slot workstation choices through the screen's real pointer/accessibility
    /// path. This covers enchanting options, stonecutter recipes, beacon powers/confirmation,
    /// villager offers, and any screen that publishes a text-accessibility action.
    func activateAction(_ id: String, expectedInstance: String?) throws {
        guard let screen = ui.current() else { throw DebugSemanticError.noScreen }
        try validate(screen, expectedInstance: expectedInstance)
        guard let action = semanticActions(for: screen).first(where: { $0.id == id }),
              action.enabled, action.activate() else { throw DebugSemanticError.unknownElement }
    }

    func setField(_ id: String, value: String, expectedInstance: String?) throws {
        guard let screen = ui.current() else { throw DebugSemanticError.noScreen }
        try validate(screen, expectedInstance: expectedInstance)
        guard value.utf8.count <= 4_096,
              let field = screen.fields.first(where: { $0.id == id }), field.enabled,
              field.replaceText(value, caret: value.count) else {
            throw DebugSemanticError.invalidAction
        }
        if let anvil = screen as? AnvilScreen { anvil.refresh() }
        if let creative = screen as? CreativeScreen { creative.refresh() }
    }

    func sendKey(_ key: String, expectedInstance: String?) throws {
        guard let screen = ui.current() else { throw DebugSemanticError.noScreen }
        try validate(screen, expectedInstance: expectedInstance)
        guard key.utf8.count <= 64 else { throw DebugSemanticError.invalidAction }
        guard screen.onKey(ui, game, key) else { throw DebugSemanticError.invalidAction }
    }

    func close(expectedInstance: String?) throws {
        guard let screen = ui.current() else { throw DebugSemanticError.noScreen }
        try validate(screen, expectedInstance: expectedInstance)
        ui.closeTop(game)
    }

    func instanceID(of screen: Screen) -> String {
        "\(kind(of: screen)):\(screen.textScreenIdentity):\(screen.textPresentationGeneration)"
    }

    private func validate(_ screen: Screen, expectedInstance: String?) throws {
        if let expectedInstance, expectedInstance != instanceID(of: screen) {
            throw DebugSemanticError.staleScreen
        }
    }

    private func kind(of screen: Screen) -> String {
        switch screen {
        case is InventoryScreen: return "inventory"
        case is CraftingScreen: return "crafting"
        case let furnace as FurnaceScreen:
            return furnace.title.lowercased().replacingOccurrences(of: " ", with: "_")
        case is ChestScreen: return "chest"
        case is BrewingScreen: return "brewing"
        case is EnchantingScreen: return "enchanting"
        case is AnvilScreen: return "anvil"
        case is GrindstoneScreen: return "grindstone"
        case is StonecutterScreen: return "stonecutter"
        case is SmithingScreen: return "smithing"
        case is BeaconScreen: return "beacon"
        case is TradingScreen: return "trading"
        case is CreativeScreen: return "creative"
        case is TemplateBrowserScreen: return "templates"
        case is RPGCharacterScreen: return "rpg"
        case is MapScreen: return "map"
        case is ChatScreen: return "chat"
        case is PauseScreen: return "pause"
        case is TitleScreen: return "title"
        default: return String(describing: type(of: screen))
        }
    }

    private func semanticSlots(for screen: Screen) -> [String: SlotDef] {
        var result: [String: SlotDef] = [:]
        let containerNames: [String]
        switch screen {
        case is InventoryScreen:
            containerNames = ["armor.head", "armor.chest", "armor.legs", "armor.feet", "offhand",
                              "crafting.0", "crafting.1", "crafting.2", "crafting.3", "crafting.output"]
        case is CraftingScreen:
            containerNames = (0..<9).map { "crafting.\($0)" } + ["crafting.output"]
        case is FurnaceScreen:
            containerNames = ["furnace.input", "furnace.fuel", "furnace.output"]
        case is BrewingScreen:
            containerNames = ["brewing.bottle.0", "brewing.bottle.1", "brewing.bottle.2",
                              "brewing.ingredient", "brewing.fuel"]
        case is EnchantingScreen:
            containerNames = ["enchanting.item", "enchanting.lapis"]
        case is AnvilScreen:
            containerNames = ["anvil.left", "anvil.right", "anvil.output"]
        case is GrindstoneScreen:
            containerNames = ["grindstone.top", "grindstone.bottom", "grindstone.output"]
        case is StonecutterScreen:
            containerNames = ["stonecutter.input", "stonecutter.output"]
        case is SmithingScreen:
            containerNames = ["smithing.template", "smithing.base", "smithing.addition", "smithing.output"]
        case is BeaconScreen:
            containerNames = ["beacon.payment"]
        default:
            if let container = screen as? ContainerScreen {
                containerNames = container.containerSlots.indices.map { "container.\($0)" }
            } else {
                containerNames = screen.slots.indices.map { "slot.\($0)" }
            }
        }

        if let container = screen as? ContainerScreen {
            for (index, slot) in container.containerSlots.enumerated() {
                result[index < containerNames.count ? containerNames[index] : "container.\(index)"] = slot
            }
            let count = container.playerSlots.count
            for (index, slot) in container.playerSlots.enumerated() {
                let inventoryIndex: Int
                if count == 36 {
                    inventoryIndex = index < 27 ? index + 9 : index - 27
                } else if count == 9 {
                    inventoryIndex = index
                } else {
                    inventoryIndex = index
                }
                result["player.inventory.\(inventoryIndex)"] = slot
            }
        } else {
            for (index, slot) in screen.slots.enumerated() {
                result[index < containerNames.count ? containerNames[index] : "slot.\(index)"] = slot
            }
        }
        return result
    }

    private func semanticButtons(for screen: Screen) -> [(String, Button)] {
        screen.buttons.enumerated().map { index, button in
            let base: String
            if let step = button as? CraftAmountButton {
                switch step.direction {
                case .up: base = "crafting.amount.increase"
                case .down: base = "crafting.amount.decrease"
                }
            } else if button.label == "Trade" {
                base = "trading.trade"
            } else if button.label == "Recipes" || button.label.hasPrefix("Recipes (") {
                base = "crafting.recipes"
            } else if button.label == "Creative" {
                base = "mode.toggle_creative"
            } else if button.label == "Character" {
                base = "rpg.open"
            } else {
                let normalized = button.label.lowercased().map { ch -> Character in
                    ch.isLetter || ch.isNumber ? ch : "_"
                }
                base = "button." + String(normalized).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
            }
            return ("\(base).\(index)", button)
        }
    }

    private func semanticActions(for screen: Screen)
        -> [(id: String, label: String, enabled: Bool, activate: () -> Bool)] {
        var result: [(String, String, Bool, () -> Bool)] = []
        if let enchanting = screen as? EnchantingScreen {
            for index in enchanting.options.indices.prefix(3) {
                let option = enchanting.options[index]
                let enabled = enchanting.item != nil && game.player.xpLevel >= option.level
                    && (enchanting.lapis?.count ?? 0) >= option.lapis
                let id = "enchanting.option.\(index)"
                result.append((id, "Enchant option \(index + 1)", enabled, {
                    enchanting.onMouseDown(self.ui, self.game,
                        enchanting.panelX + 64,
                        enchanting.panelY + 18 + Double(index) * 19, 0)
                }))
            }
        }
        if let stonecutter = screen as? StonecutterScreen {
            for index in stonecutter.options.indices.prefix(12) {
                let option = stonecutter.options[index]
                let id = "stonecutter.recipe.\(index)"
                let point = stonecutter.debugControlRecipeActivationPoint(index)
                result.append((id, option.output, stonecutter.input != nil, {
                    stonecutter.onMouseDown(self.ui, self.game, point.x, point.y, 0)
                }))
            }
        }
        if let beacon = screen as? BeaconScreen {
            let powers = ["speed", "haste", "resistance", "jump_boost", "strength"]
            for (index, power) in powers.enumerated() {
                let point = beacon.debugControlPowerActivationPoint(index)
                result.append(("beacon.power.\(power)", power,
                               beacon.debugControlPowerEnabled(power), {
                    beacon.onMouseDown(self.ui, self.game, point.x, point.y, 0)
                }))
            }
            let point = beacon.debugControlConfirmActivationPoint
            result.append(("beacon.confirm", "Confirm", beacon.debugControlCanConfirm, {
                beacon.onMouseDown(self.ui, self.game, point.x, point.y, 0)
            }))
        }
        for descriptor in screen.textAccessibilityDescriptors(ui, game)
            where descriptor.actionable {
            let id = descriptor.id
            if result.contains(where: { $0.0 == id }) { continue }
            result.append((id, descriptor.label, descriptor.enabled, {
                screen.performTextAccessibilityAction(id, self.ui, self.game)
            }))
        }
        return result
    }

    /// Bounded, stable workstation telemetry. Values are read from the same block-entity fields
    /// the production screens render, so automation can wait on actual progress without reaching
    /// around the screen lifecycle or depending on pixels.
    private func semanticState(for screen: Screen) -> JSONValue {
        if let furnace = screen as? FurnaceScreen {
            let burnTime = furnace.debugControlBurnTime
            let burnTotal = furnace.debugControlBurnTotal
            let cookTime = furnace.debugControlCookTime
            let cookTotal = furnace.debugControlCookTotal
            return .object([
                "kind": .string(furnace.debugControlKind),
                "burning": .bool(burnTime > 0),
                "burnTime": .integer(Int64(burnTime)),
                "burnTotal": .integer(Int64(burnTotal)),
                "burnProgress": progressValue(current: burnTime, total: burnTotal),
                "cookTime": .integer(Int64(cookTime)),
                "cookTotal": .integer(Int64(cookTotal)),
                "cookProgress": progressValue(current: cookTime, total: cookTotal),
                "remainingCookTicks": .integer(Int64(max(0, cookTotal - cookTime))),
                "xpBank": finiteNumber(furnace.debugControlXPBank),
            ])
        }
        if let brewing = screen as? BrewingScreen {
            let brewTime = brewing.debugControlBrewTime
            let brewTotal = brewing.debugControlBrewTotal
            return .object([
                "brewing": .bool(brewTime > 0),
                "brewTime": .integer(Int64(brewTime)),
                "brewTotal": .integer(Int64(brewTotal)),
                "brewProgress": progressValue(current: brewTime, total: brewTotal),
                "remainingBrewTicks": .integer(Int64(max(0, brewTotal - brewTime))),
                "fuel": .integer(Int64(brewing.debugControlFuel)),
            ])
        }
        if let beacon = screen as? BeaconScreen {
            return .object([
                "levels": .integer(Int64(beacon.debugControlLevels)),
                "pendingPrimary": beacon.pendingPrimary.map(JSONValue.string) ?? .null,
                "canConfirm": .bool(beacon.debugControlCanConfirm),
            ])
        }
        if let stonecutter = screen as? StonecutterScreen {
            return .object([
                "selectedRecipe": .integer(Int64(stonecutter.selected)),
                "recipeCount": .integer(Int64(min(stonecutter.options.count, 12))),
                "recipesTruncated": .bool(stonecutter.options.count > 12),
            ])
        }
        return .null
    }

    private func progressValue(current: Int, total: Int) -> JSONValue {
        guard total > 0 else { return .number(0) }
        return .number(min(1, max(0, Double(current) / Double(total))))
    }

    private func finiteNumber(_ value: Double) -> JSONValue {
        value.isFinite ? .number(value) : .null
    }
}

/// Shared bounded projection used by both semantic screens and whole-game debug snapshots.
/// This deliberately summarizes carried inventories instead of recursively projecting stacks.
enum DebugStackProjection {
    static func value(_ stack: ItemStack?) -> JSONValue {
        guard let stack else { return .null }
        let name = stack.id >= 0 && stack.id < itemDefs.count ? itemDef(stack.id).name : "invalid"
        return .object([
            "id": .integer(Int64(stack.id)),
            "name": .string(name),
            "count": .integer(Int64(stack.count)),
            "damage": .integer(Int64(stack.damage)),
            "label": stack.label.map { .string(boundedString($0, utf8Limit: 4_096)) } ?? .null,
            "labelTruncated": .bool((stack.label?.utf8.count ?? 0) > 4_096),
            "enchantments": .array(stack.ench.prefix(32).map { enchantment in
                .object([
                    "id": .string(boundedString(enchantment.id, utf8Limit: 256)),
                    "idTruncated": .bool(enchantment.id.utf8.count > 256),
                    "level": .integer(Int64(enchantment.lvl)),
                ])
            }),
            "enchantmentsTruncated": .bool(stack.ench.count > 32),
            "data": stackDataValue(stack.data),
        ])
    }

    /// Stack payloads can be persisted or supplied by debug setup operations, so every variable
    /// collection is bounded and carried-container contents are summarized without recursion.
    private static func stackDataValue(_ data: StackData) -> JSONValue {
        let sherds = data.sherds.map { values in
            JSONValue.array(values.prefix(16).map {
                .string(boundedString($0, utf8Limit: 256))
            })
        } ?? .null
        let lodestone = data.lodestone.map { values in
            JSONValue.array(values.prefix(4).map { .integer(Int64($0)) })
        } ?? .null
        return .object([
            "potion": data.potion.map {
                .string(boundedString($0, utf8Limit: 256))
            } ?? .null,
            "potionTruncated": .bool((data.potion?.utf8.count ?? 0) > 256),
            "trim": data.trim.map { trim in
                .object([
                    "pattern": .string(boundedString(trim.pattern, utf8Limit: 256)),
                    "patternTruncated": .bool(trim.pattern.utf8.count > 256),
                    "material": .string(boundedString(trim.material, utf8Limit: 256)),
                    "materialTruncated": .bool(trim.material.utf8.count > 256),
                ])
            } ?? .null,
            "sherds": sherds,
            "sherdsTruncated": .bool((data.sherds?.count ?? 0) > 16),
            "sherdValuesTruncated": .bool(data.sherds?.prefix(16).contains {
                $0.utf8.count > 256
            } ?? false),
            "charged": data.charged.map(JSONValue.bool) ?? .null,
            "priorWork": data.priorWork.map { .integer(Int64($0)) } ?? .null,
            "repairUnits": data.repairUnits.map { .integer(Int64($0)) } ?? .null,
            "contents": carriedContentsSummary(data.contents),
            "lodestone": lodestone,
            "lodestoneTruncated": .bool((data.lodestone?.count ?? 0) > 4),
            "flight": data.flight.map { .integer(Int64($0)) } ?? .null,
        ])
    }

    private static func carriedContentsSummary(_ contents: [ItemStack?]?) -> JSONValue {
        guard let contents else { return .null }
        let inspectedCount = min(contents.count, 54)
        var nonEmpty: [JSONValue] = []
        nonEmpty.reserveCapacity(inspectedCount)
        for index in 0..<inspectedCount {
            guard let stack = contents[index] else { continue }
            let name = stack.id >= 0 && stack.id < itemDefs.count
                ? itemDef(stack.id).name : "invalid"
            nonEmpty.append(.object([
                "slot": .integer(Int64(index)),
                "id": .integer(Int64(stack.id)),
                "name": .string(name),
                "count": .integer(Int64(stack.count)),
                "damage": .integer(Int64(stack.damage)),
            ]))
        }
        return .object([
            "slotCount": .integer(Int64(contents.count)),
            "inspectedSlots": .integer(Int64(inspectedCount)),
            "nonEmpty": .array(nonEmpty),
            "truncated": .bool(contents.count > inspectedCount),
        ])
    }

    private static func boundedString(_ value: String, utf8Limit: Int) -> String {
        guard value.utf8.count > utf8Limit else { return value }
        return String(decoding: value.utf8.prefix(utf8Limit), as: UTF8.self)
    }
}

enum DebugSemanticError: Error {
    case noScreen
    case staleScreen
    case readOnly
    case unknownElement
    case invalidAction
}
#endif
