// BuiltInAttributes.swift — object-graph-attributes (change 1a). design.md
// Decision 7 / spec `attribute-registry` "typed switches implement". Reads
// are lenient (`nil`/`.notApplicable` never raises); writes go only through
// the funnels Decision 7 names (`World.setBlock` via `BlockStateCodec`,
// `setPos`, `heal`/`hurt`, `setGameMode`, `setDifficulty`, `setGameRule`,
// plain fields) and every ranged integer refuses out-of-range before the
// field is touched (Security (plan) C22).

import Foundation

public enum BuiltInGetOutcome {
    case value(AttrValue)
    case unknownName
    case notApplicable
}

public enum BuiltInSetOutcome {
    case ok(AttrValue)
    case unknownName(didYouMean: [String])
    case notApplicable
    case readOnly
    case wrongValueKind
    /// The range as shown to the user, e.g. `"0...100000"`.
    case outOfRange(String)
}

private let difficultyNames = ["peaceful", "easy", "normal", "hard"]

public enum BuiltInAttributes {
    // MARK: - entry points

    public static func get(_ live: LiveObject, name: String, host: ObjectGraphHost) -> BuiltInGetOutcome {
        let kind = kindOf(live)
        guard let descriptor = AttributeRegistry.resolve(kind: kind, name: name) else { return .unknownName }
        guard AttributeRegistry.applies(descriptor, in: applicabilityContext(for: live)) else { return .notApplicable }
        switch live {
        case .block(_, let chunk, let cellIndex, let x, let y, let z):
            return getBlock(chunk: chunk, cellIndex: cellIndex, x: x, y: y, z: z, name: name)
        case .entity(let entity, _):
            return getEntityCommon(entity, name: name) ?? .unknownName
        case .player(let player, let world):
            return getPlayer(player, world: world, name: name) ?? getEntityCommon(player, name: name) ?? .unknownName
        case .dimension(let world):
            return getDimension(world, name: name) ?? .unknownName
        case .world:
            return getWorld(host: host, name: name) ?? .unknownName
        }
    }

    public static func set(_ live: LiveObject, name: String, value: AttrValue, host: ObjectGraphHost) -> BuiltInSetOutcome {
        let kind = kindOf(live)
        guard let descriptor = AttributeRegistry.resolve(kind: kind, name: name) else {
            return .unknownName(didYouMean: AttributeRegistry.didYouMean(kind: kind, name: name))
        }
        guard AttributeRegistry.applies(descriptor, in: applicabilityContext(for: live)) else { return .notApplicable }
        guard descriptor.mutability == .getSet else { return .readOnly }
        switch live {
        case .block(let world, _, _, let x, let y, let z):
            guard BlockStateCodec.write(world, x, y, z, field: name, value: value) else { return .wrongValueKind }
            let cell = world.getBlock(x, y, z)
            return .ok(BlockStateCodec.decode(cell)[name] ?? .null)
        case .entity(let entity, _):
            return setEntityCommon(entity, name: name, value: value) ?? .notApplicable
        case .player(let player, let world):
            return setPlayer(player, world: world, name: name, value: value)
                ?? setEntityCommon(player, name: name, value: value) ?? .notApplicable
        case .dimension(let world):
            return setDimension(world, name: name, value: value) ?? .notApplicable
        case .world:
            return setWorld(host: host, name: name, value: value) ?? .notApplicable
        }
    }

    // MARK: - kind / applicability

    static func kindOf(_ live: LiveObject) -> ObjectKind {
        switch live {
        case .world: return .world
        case .dimension: return .dim
        case .block: return .block
        case .entity: return .entity
        case .player: return .player
        }
    }

    private static func applicabilityContext(for live: LiveObject) -> AttributeApplicabilityContext {
        switch live {
        case .world: return .world
        case .dimension: return .dimension
        case .block(_, let chunk, _, let x, let y, let z):
            let cell = Int(chunk.get(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)))
            let id = cell >> 4
            let shape = (id >= 0 && id < blockDefs.count) ? blockDefs[id].shape : .air
            let name = (id >= 0 && id < blockDefs.count) ? blockDefs[id].name : ""
            let beType = chunk.getBlockEntity(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W))?.type
            return .block(shape: shape, name: name, blockEntityType: beType)
        case .entity(let entity, _):
            return .entity(type: entity.type, isPlayer: false, isLiving: entity is LivingEntity, isMob: entity is Mob)
        case .player(let player, _):
            return .entity(type: player.type, isPlayer: true, isLiving: true, isMob: false)
        }
    }

    // MARK: - numeric coercion (lenient: `.int` or an integral `.number` both
    // satisfy an int field; `.int`/`.number` both satisfy a number field)

    private static func numericValue(_ v: AttrValue) -> Double? {
        switch v {
        case .int(let i): return Double(i)
        case .number(let d): return d.isFinite ? d : nil
        default: return nil
        }
    }

    private static func integerValue(_ v: AttrValue) -> Int? {
        switch v {
        case .int(let i): return Int(exactly: i)
        case .number(let d): return (d.isFinite && d == d.rounded()) ? Int(exactly: d) : nil
        default: return nil
        }
    }

    // MARK: - block

    private static func getBlock(chunk: Chunk, cellIndex: Int, x: Int, y: Int, z: Int, name: String) -> BuiltInGetOutcome {
        let cell = Int(chunk.get(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)))
        let id = cell >> 4
        guard id >= 0, id < blockDefs.count else { return .notApplicable }
        let def = blockDefs[id]
        switch name {
        case "name": return .value(.string(def.name))
        case "shape": return .value(.string(String(describing: def.shape)))
        case "hardness": return .value(.number(def.hardness))
        case "light": return .value(.int(Int64(lightEmitOf(UInt16(cell)))))
        case "sky_light": return .value(.int(Int64(chunk.getSky(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)))))
        case "be.type": return blockEntityField(chunk, x, y, z) { .string($0.type) }
        case "be.name": return blockEntityField(chunk, x, y, z) { be in be.name.map { .string($0) } ?? .null }
        case "be.lines": return blockEntityField(chunk, x, y, z) { be in .list((be.lines ?? []).map { .string($0) }) }
        case "be.burn_time": return blockEntityField(chunk, x, y, z) { be in .int(Int64(be.burnTime ?? 0)) }
        case "be.cook_time": return blockEntityField(chunk, x, y, z) { be in .int(Int64(be.cookTime ?? 0)) }
        case "be.mob": return blockEntityField(chunk, x, y, z) { be in be.mob.map { .string($0) } ?? .null }
        default:
            if name.hasPrefix("be.items["), name.hasSuffix("]") {
                let idxText = name.dropFirst("be.items[".count).dropLast()
                guard let idx = Int(idxText) else { return .notApplicable }
                return blockEntityField(chunk, x, y, z) { be in
                    guard let items = be.items, idx >= 0, idx < items.count else { return .null }
                    return itemValue(items[idx])
                }
            }
            if let v = BlockStateCodec.decode(cell)[name] { return .value(v) }
            return .notApplicable
        }
    }

    private static func blockEntityField(_ chunk: Chunk, _ x: Int, _ y: Int, _ z: Int, _ f: (BlockEntityData) -> AttrValue) -> BuiltInGetOutcome {
        guard let be = chunk.getBlockEntity(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W)) else { return .value(.null) }
        return .value(f(be))
    }

    // MARK: - entity (shared by kind .entity and .player)

    private static func getEntityCommon(_ entity: Entity, name: String) -> BuiltInGetOutcome? {
        switch name {
        case "type": return .value(.string(entity.type))
        case "x": return .value(.number(entity.x))
        case "y": return .value(.number(entity.y))
        case "z": return .value(.number(entity.z))
        case "yaw": return .value(.number(entity.yaw))
        case "pitch": return .value(.number(entity.pitch))
        case "vx": return .value(.number(entity.vx))
        case "vy": return .value(.number(entity.vy))
        case "vz": return .value(.number(entity.vz))
        case "on_ground": return .value(.bool(entity.onGround))
        case "in_water": return .value(.bool(entity.inWater))
        case "on_fire": return .value(.bool(entity.fireTicks > 0))
        case "age": return .value(.int(Int64(entity.age)))
        case "dead": return .value(.bool(entity.dead))
        case "persistent": return .value(.bool(entity.persistent))
        case "variant": return .value(entity.data.variant.map { .int(Int64($0)) } ?? .null)
        case "color": return .value(entity.data.color.map { .int(Int64($0)) } ?? .null)
        case "item": return (entity as? ItemEntity).map { .value(itemValue($0.stack)) }
        case "xp": return (entity as? XPOrb).map { .value(.int(Int64($0.amount))) }
        default: break
        }
        if let living = entity as? LivingEntity {
            switch name {
            case "health": return .value(.number(living.health))
            case "max_health": return .value(.number(living.maxHealth))
            case "absorption": return .value(.number(living.absorption))
            case "effects": return .value(effectsValue(living.effects))
            case "armor": return .value(.list(living.armor.map(itemValue)))
            case "main_hand": return .value(itemValue(living.mainHand))
            case "off_hand": return .value(itemValue(living.offHand))
            default: break
            }
        }
        if let mob = entity as? Mob {
            switch name {
            case "target": return .value(mob.target.map { .ref(ObjectRef.entity(uid: $0.id).canonical) } ?? .null)
            case "baby": return .value(.bool(mob.baby))
            case "sitting": return .value(.bool(mob.sitting))
            case "tamed": return .value(.bool(mob.ownerId != nil))
            case "owner": return .value(mob.ownerId.map { .ref(ObjectRef.entity(uid: $0).canonical) } ?? .null)
            default: break
            }
        }
        return nil
    }

    private static func setEntityCommon(_ entity: Entity, name: String, value: AttrValue) -> BuiltInSetOutcome? {
        switch name {
        case "x":
            guard let v = numericValue(value) else { return .wrongValueKind }
            entity.setPos(v, entity.y, entity.z)
            return .ok(.number(entity.x))
        case "y":
            guard let v = numericValue(value) else { return .wrongValueKind }
            entity.setPos(entity.x, v, entity.z)
            return .ok(.number(entity.y))
        case "z":
            guard let v = numericValue(value) else { return .wrongValueKind }
            entity.setPos(entity.x, entity.y, v)
            return .ok(.number(entity.z))
        case "yaw":
            guard let v = numericValue(value) else { return .wrongValueKind }
            entity.yaw = v
            return .ok(.number(entity.yaw))
        case "pitch":
            guard let v = numericValue(value) else { return .wrongValueKind }
            entity.pitch = v
            return .ok(.number(entity.pitch))
        case "vx":
            guard let v = numericValue(value) else { return .wrongValueKind }
            entity.vx = v
            return .ok(.number(entity.vx))
        case "vy":
            guard let v = numericValue(value) else { return .wrongValueKind }
            entity.vy = v
            return .ok(.number(entity.vy))
        case "vz":
            guard let v = numericValue(value) else { return .wrongValueKind }
            entity.vz = v
            return .ok(.number(entity.vz))
        case "on_fire":
            guard case .bool(let b) = value else { return .wrongValueKind }
            entity.fireTicks = b ? max(entity.fireTicks, 300) : 0
            return .ok(.bool(entity.fireTicks > 0))
        case "persistent":
            guard case .bool(let b) = value else { return .wrongValueKind }
            entity.persistent = b
            return .ok(.bool(entity.persistent))
        default:
            break
        }
        if let living = entity as? LivingEntity, name == "health" {
            guard let target = numericValue(value) else { return .wrongValueKind }
            let before = living.health
            if target > before {
                living.heal(target - before)
            } else if target < before {
                _ = living.hurt(before - target, "attr")
            }
            return .ok(.number(living.health))
        }
        if let mob = entity as? Mob {
            switch name {
            case "baby":
                guard case .bool(let b) = value else { return .wrongValueKind }
                mob.baby = b
                return .ok(.bool(mob.baby))
            case "sitting":
                guard case .bool(let b) = value else { return .wrongValueKind }
                mob.sitting = b
                return .ok(.bool(mob.sitting))
            default: break
            }
        }
        return nil
    }

    // MARK: - player (getSet fields beyond the shared entity set)

    private static func getPlayer(_ player: Player, world: World, name: String) -> BuiltInGetOutcome? {
        switch name {
        case "hunger": return .value(.int(Int64(player.hunger)))
        case "saturation": return .value(.number(player.saturation))
        case "xp_level": return .value(.int(Int64(player.xpLevel)))
        case "xp_progress": return .value(.number(player.xpProgress))
        case "game_mode": return .value(.string(player.gameMode == GameMode.creative ? "creative" : "survival"))
        case "dimension": return .value(.string(dimCanonicalName(world.dim)))
        case "held_slot": return .value(.int(Int64(player.selectedSlot)))
        case "held_item": return .value(itemValue(player.mainHandStack))
        case "sneaking": return .value(.bool(player.sneaking))
        case "sprinting": return .value(.bool(player.sprinting))
        case "flying": return .value(.bool(player.flying))
        case "sleeping": return .value(.bool(player.bedPos != nil))
        case "spawn_point":
            guard let sp = player.spawnPoint else { return .value(.null) }
            return .value(.map([
                "x": .int(Int64(sp.0)), "y": .int(Int64(sp.1)), "z": .int(Int64(sp.2)),
                "dim": .string(Dim(rawValue: player.spawnDim).map(dimCanonicalName) ?? "overworld"),
            ]))
        case "rpg.path": return .value(player.rpg.created ? .string(player.rpg.pathID) : .null)
        case "rpg.level": return .value(.int(Int64(player.rpg.level)))
        case "rpg.fatigue": return .value(.number(player.rpg.fatigue))
        default:
            if name.hasPrefix("inventory["), name.hasSuffix("]") {
                let idxText = name.dropFirst("inventory[".count).dropLast()
                guard let idx = Int(idxText), idx >= 0, idx < player.inventory.count else { return .notApplicable }
                return .value(itemValue(player.inventory[idx]))
            }
            if name.hasPrefix("stats.") {
                let statName = String(name.dropFirst("stats.".count))
                return .value(player.stats[statName].map { .int(Int64($0)) } ?? .null)
            }
            return nil
        }
    }

    private static func setPlayer(_ player: Player, world: World, name: String, value: AttrValue) -> BuiltInSetOutcome? {
        switch name {
        case "hunger":
            guard let v = integerValue(value) else { return .wrongValueKind }
            guard (0...20).contains(v) else { return .outOfRange("0...20") }
            player.hunger = v
            return .ok(.int(Int64(player.hunger)))
        case "saturation":
            guard let v = numericValue(value) else { return .wrongValueKind }
            player.saturation = v
            return .ok(.number(player.saturation))
        case "xp_level":
            // Security (plan) C22: refuse out-of-range before Player.xpLevel is
            // ever assigned — `xpForLevel`/`addXP` overflow far above 100_000.
            guard let v = integerValue(value) else { return .wrongValueKind }
            guard (0...100_000).contains(v) else { return .outOfRange("0...100000") }
            player.xpLevel = v
            return .ok(.int(Int64(player.xpLevel)))
        case "game_mode":
            guard case .string(let s) = value else { return .wrongValueKind }
            switch s {
            case "survival": player.setGameMode(GameMode.survival)
            case "creative": player.setGameMode(GameMode.creative)
            default: return .wrongValueKind
            }
            return .ok(.string(s))
        case "held_slot":
            guard let v = integerValue(value) else { return .wrongValueKind }
            guard (0...8).contains(v) else { return .outOfRange("0...8") }
            player.selectedSlot = v
            return .ok(.int(Int64(player.selectedSlot)))
        default:
            return nil
        }
    }

    // MARK: - dimension

    private static func getDimension(_ world: World, name: String) -> BuiltInGetOutcome? {
        switch name {
        case "time": return .value(.int(Int64(world.time)))
        case "day_time": return .value(.int(Int64(world.dayTime)))
        case "day_phase": return .value(.string(dayPhase(world.dayTime)))
        case "raining": return .value(.bool(world.raining))
        case "thundering": return .value(.bool(world.thundering))
        case "rain_level": return .value(.number(world.rainLevel))
        default: return nil
        }
    }

    private static func setDimension(_ world: World, name: String, value: AttrValue) -> BuiltInSetOutcome? {
        switch name {
        case "day_time":
            guard let v = integerValue(value) else { return .wrongValueKind }
            guard (0...23_999).contains(v) else { return .outOfRange("0...23999") }
            world.dayTime = v
            return .ok(.int(Int64(world.dayTime)))
        case "raining":
            guard case .bool(let b) = value else { return .wrongValueKind }
            world.raining = b
            return .ok(.bool(world.raining))
        case "thundering":
            guard case .bool(let b) = value else { return .wrongValueKind }
            world.thundering = b
            return .ok(.bool(world.thundering))
        default:
            return nil
        }
    }

    private static func dayPhase(_ t: Int) -> String {
        switch t {
        case 0..<12_000: return "day"
        case 12_000..<13_000: return "sunset"
        case 13_000..<23_000: return "night"
        default: return "sunrise"
        }
    }

    // MARK: - world

    private static func getWorld(host: ObjectGraphHost, name: String) -> BuiltInGetOutcome? {
        switch name {
        case "difficulty":
            guard let w = host.world(for: host.currentDimension) else { return .notApplicable }
            let idx = w.difficulty
            return .value(.string((0..<difficultyNames.count).contains(idx) ? difficultyNames[idx] : "peaceful"))
        case "seed":
            guard let w = host.world(for: host.currentDimension) else { return .notApplicable }
            return .value(.int(Int64(w.seed)))
        case "tick":
            guard let w = host.world(for: host.currentDimension) else { return .notApplicable }
            return .value(.int(Int64(w.rpgSimulationTick)))
        case "scripts_enabled":
            return .value(.bool(host.scriptsEnabled))
        default:
            if name.hasPrefix("gamerule.") {
                let ruleName = String(name.dropFirst("gamerule.".count))
                guard let w = host.world(for: host.currentDimension), let v = w.gameRules[ruleName] else {
                    return .notApplicable
                }
                return .value(.number(v))
            }
            return nil
        }
    }

    private static func setWorld(host: ObjectGraphHost, name: String, value: AttrValue) -> BuiltInSetOutcome? {
        switch name {
        case "difficulty":
            guard case .string(let s) = value, let idx = difficultyNames.firstIndex(of: s) else { return .wrongValueKind }
            host.setDifficulty(idx)
            return .ok(.string(s))
        default:
            if name.hasPrefix("gamerule.") {
                let ruleName = String(name.dropFirst("gamerule.".count))
                guard let w = host.world(for: host.currentDimension), w.gameRules[ruleName] != nil else {
                    return .notApplicable
                }
                guard let v = numericValue(value) else { return .wrongValueKind }
                host.setGameRule(ruleName, v)
                return .ok(.number(v))
            }
            return nil
        }
    }

    // MARK: - shared value builders

    private static func itemValue(_ stack: ItemStack?) -> AttrValue {
        guard let stack else { return .null }
        return .map([
            "item": .string(itemDef(stack.id).name), "count": .int(Int64(stack.count)),
            "damage": .int(Int64(stack.damage)),
        ])
    }

    private static func effectsValue(_ effects: [ActiveEffect]) -> AttrValue {
        .list(effects.map {
            .map(["id": .string($0.id), "duration": .int(Int64($0.duration)), "amplifier": .int(Int64($0.amplifier))])
        })
    }
}
