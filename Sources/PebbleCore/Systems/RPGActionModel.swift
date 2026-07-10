import Foundation

public enum RPGSpellEffectID: String, CaseIterable, Hashable {
    case ignite
    case frostRay = "frost_ray"
    case shock
    case stormAura = "storm_aura"
    case blur
    case decoy
    case shadowStep = "shadow_step"
    case mirrorImage = "mirror_image"
    case mageLight = "mage_light"
    case ward
    case summonServant = "summon_servant"
    case stoneWard = "stone_ward"
    case mendWounds = "mend_wounds"
    case restore
    case purify
    case aegis
    case sanctuary
}

public enum RPGExecutableEffectID: Hashable {
    case skill(RPGSkillEffectID)
    case spell(RPGSpellEffectID)

    public var rawValue: String {
        switch self {
        case .skill(let id): return id.rawValue
        case .spell(let id): return id.rawValue
        }
    }
}

public enum RPGActionPermissionClass: Equatable {
    case none
    case build
    case container
    case buildOnlyForBlockTarget
}

public enum RPGEquipmentRequirement: Equatable {
    case none
    case apprenticeFocus
    case heldMeleeWeapon
    case heldBowAndArrow
    case heldPickaxe
    case heldTool
}

public enum RPGMaterialRequirement: Equatable {
    case none
    case consumeItem(String, Int)
    case matchingRepairMaterial
    case ownedChargeRefund
}

public enum RPGTargetClass: Equatable {
    case selfTarget
    case hostileRay(Double)
    case nonPlayerAllyRay(Double)
    case hostileArea(Double, maximum: Int)
    case nonPlayerAllyArea(Double, maximum: Int)
    case solidBlockRay(Double)
    case adjacentReplaceableBlock(Double)
    case containerRay(Double)
    case redstoneDeviceRay(Double)
    case darkTeleportRay(Double)
    case placedPoint(Double)
    case ownedCharge(Double)
    case damagedGear
}

public struct RPGActionMetadata: Equatable {
    public let id: RPGExecutableEffectID
    public let permission: RPGActionPermissionClass
    public let equipment: RPGEquipmentRequirement
    public let material: RPGMaterialRequirement
    public let target: RPGTargetClass

    public init(id: RPGExecutableEffectID,
                permission: RPGActionPermissionClass,
                equipment: RPGEquipmentRequirement,
                material: RPGMaterialRequirement,
                target: RPGTargetClass) {
        self.id = id
        self.permission = permission
        self.equipment = equipment
        self.material = material
        self.target = target
    }
}

public struct RPGActionAuthorization: Equatable {
    public let ownerAuthorityID: String
    public let worldOwnerEntityID: Int?
    public let canBuild: Bool
    public let canUseContainers: Bool

    public init(ownerAuthorityID: String,
                worldOwnerEntityID: Int? = nil,
                canBuild: Bool,
                canUseContainers: Bool) {
        self.ownerAuthorityID = ownerAuthorityID
        self.worldOwnerEntityID = worldOwnerEntityID
        self.canBuild = canBuild
        self.canUseContainers = canUseContainers
    }

    public static func local(for player: Player) -> RPGActionAuthorization {
        RPGActionAuthorization(ownerAuthorityID: player.effectiveRPGAuthorityID,
                               worldOwnerEntityID: player.id,
                               canBuild: true,
                               canUseContainers: true)
    }
}

private func activeMetadata(_ id: RPGSkillEffectID,
                            _ permission: RPGActionPermissionClass = .none,
                            _ equipment: RPGEquipmentRequirement = .none,
                            _ material: RPGMaterialRequirement = .none,
                            _ target: RPGTargetClass) -> RPGActionMetadata {
    RPGActionMetadata(id: .skill(id), permission: permission, equipment: equipment,
                      material: material, target: target)
}

private func activeMetadata(_ id: RPGSkillEffectID, target: RPGTargetClass) -> RPGActionMetadata {
    activeMetadata(id, .none, .none, .none, target)
}

private func activeMetadata(_ id: RPGSkillEffectID,
                            _ permission: RPGActionPermissionClass,
                            target: RPGTargetClass) -> RPGActionMetadata {
    activeMetadata(id, permission, .none, .none, target)
}

private func spellMetadata(_ id: RPGSpellEffectID,
                           _ permission: RPGActionPermissionClass = .none,
                           _ target: RPGTargetClass) -> RPGActionMetadata {
    RPGActionMetadata(id: .spell(id), permission: permission, equipment: .apprenticeFocus,
                      material: .none, target: target)
}

private func spellMetadata(_ id: RPGSpellEffectID, target: RPGTargetClass) -> RPGActionMetadata {
    spellMetadata(id, .none, target)
}

public let RPG_ACTIVE_ACTION_METADATA: [RPGActionMetadata] = [
    activeMetadata(.interpose, target: .nonPlayerAllyArea(5, maximum: 3)),
    activeMetadata(.anchorLine, target: .nonPlayerAllyRay(6)),
    activeMetadata(.heavyCut, .none, .heldMeleeWeapon, .none, .hostileRay(4.5)),
    activeMetadata(.chargeBreak, target: .hostileRay(5)),
    activeMetadata(.fortifyBlock, .build, target: .solidBlockRay(5)),
    activeMetadata(.cripplingShot, .none, .heldBowAndArrow, .consumeItem("arrow", 1), .hostileRay(18)),
    activeMetadata(.farSight, target: .hostileArea(32, maximum: 8)),
    activeMetadata(.fastBore, .none, .heldPickaxe, .none, .selfTarget),
    activeMetadata(.trapProbe, target: .solidBlockRay(10)),
    activeMetadata(.deadfall, .build, .none, .consumeItem("gravel", 1), .adjacentReplaceableBlock(6)),
    activeMetadata(.lockTouch, .container, target: .containerRay(5)),
    activeMetadata(.fortuneRead, .container, target: .containerRay(5)),
    activeMetadata(.secondBreath, target: .selfTarget),
    activeMetadata(.safeHaven, target: .selfTarget),
    activeMetadata(.remoteTrigger, .build, target: .redstoneDeviceRay(10)),
    activeMetadata(.fieldMod, .none, .heldTool, .none, .selfTarget),
    activeMetadata(.quickRepair, .none, .none, .matchingRepairMaterial, .damagedGear),
    activeMetadata(.chargePack, .build, .none, .consumeItem("tnt", 1), .adjacentReplaceableBlock(6)),
    activeMetadata(.safeFuse, .build, .none, .ownedChargeRefund, .ownedCharge(8)),
]

public let RPG_SPELL_ACTION_METADATA: [RPGActionMetadata] = [
    spellMetadata(.ignite, .buildOnlyForBlockTarget, .hostileRay(12)),
    spellMetadata(.frostRay, target: .hostileRay(14)),
    spellMetadata(.shock, target: .hostileRay(16)),
    spellMetadata(.stormAura, target: .selfTarget),
    spellMetadata(.blur, target: .selfTarget),
    spellMetadata(.decoy, target: .placedPoint(8)),
    spellMetadata(.shadowStep, target: .darkTeleportRay(13)),
    spellMetadata(.mirrorImage, target: .selfTarget),
    spellMetadata(.mageLight, .build, .adjacentReplaceableBlock(12)),
    spellMetadata(.ward, .build, .solidBlockRay(6)),
    spellMetadata(.summonServant, target: .placedPoint(4)),
    spellMetadata(.stoneWard, .build, .solidBlockRay(8)),
    spellMetadata(.mendWounds, target: .nonPlayerAllyRay(2)),
    spellMetadata(.restore, target: .nonPlayerAllyRay(2)),
    spellMetadata(.purify, target: .nonPlayerAllyRay(2)),
    spellMetadata(.aegis, target: .nonPlayerAllyRay(2)),
    spellMetadata(.sanctuary, target: .hostileArea(10, maximum: 32)),
]

private let RPG_ACTION_METADATA_BY_ID: [RPGExecutableEffectID: RPGActionMetadata] =
    Dictionary(uniqueKeysWithValues: (RPG_ACTIVE_ACTION_METADATA + RPG_SPELL_ACTION_METADATA).map { ($0.id, $0) })

public func rpgActionMetadata(kind: RPGPreparedActionKind, id: String) -> RPGActionMetadata? {
    switch kind {
    case .skill:
        guard let typed = RPGSkillEffectID(rawValue: id) else { return nil }
        return RPG_ACTION_METADATA_BY_ID[.skill(typed)]
    case .spell:
        guard let typed = RPGSpellEffectID(rawValue: id) else { return nil }
        return RPG_ACTION_METADATA_BY_ID[.spell(typed)]
    }
}

struct RPGPlayerItemsSnapshot: Equatable {
    var inventory: [ItemStack?]
    var armor: [ItemStack?]
    var offHand: ItemStack?
    var selectedSlot: Int

    static func capture(_ player: Player) -> RPGPlayerItemsSnapshot {
        RPGPlayerItemsSnapshot(inventory: player.inventory.map(copyStack),
                               armor: player.armor.map(copyStack),
                               offHand: copyStack(player.offHand),
                               selectedSlot: player.selectedSlot)
    }

    func deepCopy() -> RPGPlayerItemsSnapshot {
        RPGPlayerItemsSnapshot(inventory: inventory.map(copyStack),
                               armor: armor.map(copyStack),
                               offHand: copyStack(offHand),
                               selectedSlot: selectedSlot)
    }

    func apply(to player: Player) {
        player.inventory = inventory.map(copyStack)
        player.armor = armor.map(copyStack)
        player.offHand = copyStack(offHand)
        player.selectedSlot = max(0, min(8, selectedSlot))
    }
}

enum RPGEntityTarget: Equatable {
    case owner
    case entity(Int)
}

struct RPGEntityGuard: Equatable {
    var id: Int
    var type: String
    var isPlayer: Bool
    var gameMode: Int
    var dead: Bool
    var deathTime: Int
    var x: Double, y: Double, z: Double
    var vx: Double, vy: Double, vz: Double
    var yaw: Double, pitch: Double
    var health: Double
    var maxHealth: Double
    var absorption: Double
    var invulnTicks: Int
    var fireTicks: Int
    var freezeTicks: Int
    var effects: [ActiveEffect]
    var mainHand: ItemStack?
    var offHand: ItemStack?
    var armor: [ItemStack?]
    var wardenMitigationOwnerID: Int?
    var wardenMitigationSequence: Int
    var wardenMitigationRemaining: Double
    var wardenMitigationAbsorbed: Double
    var wardenMitigationLayers: [RPGWardenMitigationLayerSnapshot]
    var menderInjuryGeneration: Int
    var menderInjuryNonce: Int
    var menderInjuryExpiryTick: Int
    var menderInjuryRemaining: Double
    var arcanistFireOwnerID: Int?
    var arcanistFireExpiryTick: Int

    static func capture(_ entity: LivingEntity) -> RPGEntityGuard {
        RPGEntityGuard(id: entity.id, type: entity.type, isPlayer: entity.isPlayer,
                       gameMode: entity.gameMode,
                       dead: entity.dead, deathTime: entity.deathTime,
                       x: entity.x, y: entity.y, z: entity.z,
                       vx: entity.vx, vy: entity.vy, vz: entity.vz,
                       yaw: entity.yaw, pitch: entity.pitch,
                       health: entity.health, maxHealth: entity.maxHealth,
                       absorption: entity.absorption, invulnTicks: entity.invulnTicks,
                       fireTicks: entity.fireTicks, freezeTicks: entity.freezeTicks,
                       effects: entity.effects,
                       mainHand: copyStack(entity.mainHand), offHand: copyStack(entity.offHand),
                       armor: entity.armor.map(copyStack),
                       wardenMitigationOwnerID: entity.rpgWardenMitigationOwner?.id,
                       wardenMitigationSequence: entity.rpgWardenMitigationSequence,
                       wardenMitigationRemaining: entity.rpgWardenMitigationRemaining,
                       wardenMitigationAbsorbed: entity.rpgWardenMitigationAbsorbed,
                       wardenMitigationLayers: entity.rpgWardenMitigationLayerSnapshots,
                       menderInjuryGeneration: entity.rpgMenderInjuryGeneration,
                       menderInjuryNonce: entity.rpgMenderInjuryNonce,
                       menderInjuryExpiryTick: entity.rpgMenderInjuryExpiryTick,
                       menderInjuryRemaining: entity.rpgMenderInjuryRemaining,
                       arcanistFireOwnerID: entity.rpgArcanistFireOwner?.id,
                       arcanistFireExpiryTick: entity.rpgArcanistFireExpiryTick)
    }

    func matches(_ entity: LivingEntity) -> Bool {
        self == RPGEntityGuard.capture(entity)
    }
}

struct RPGBlockGuard: Equatable {
    var position: RPGBlockPosition
    var cell: Int
}

struct RPGContainerGuard: Equatable {
    var position: RPGBlockPosition
    var type: String
    var items: [ItemStack?]
    var lootTable: String?
    var lootSeed: Int?
    var generatedContainerKey: String?

    static func capture(_ be: BlockEntityData, at position: RPGBlockPosition) -> RPGContainerGuard {
        RPGContainerGuard(position: position, type: be.type, items: (be.items ?? []).map(copyStack),
                          lootTable: be.lootTable, lootSeed: be.lootSeed,
                          generatedContainerKey: be.rpgGeneratedContainerKey)
    }

    func matches(_ be: BlockEntityData) -> Bool {
        type == be.type && items == (be.items ?? []) && lootTable == be.lootTable
            && lootSeed == be.lootSeed && generatedContainerKey == be.rpgGeneratedContainerKey
    }
}

struct RPGBlockMutation: Equatable {
    var position: RPGBlockPosition
    var expectedCell: Int
    var newCell: Int
}

struct RPGTeleportMutation: Equatable {
    var expectedX: Double, expectedY: Double, expectedZ: Double
    var destinationX: Double, destinationY: Double, destinationZ: Double
}

struct RPGSpawnAllayMutation: Equatable {
    var x: Double, y: Double, z: Double
    var ownerEntityID: Int?
    var temporaryDraft: RPGTemporaryEffectDraft
}

enum RPGMutationOperation: Equatable {
    case heal(RPGEntityTarget, Double)
    case damage(RPGEntityTarget, Double, source: String)
    case addEffect(RPGEntityTarget, id: String, ticks: Int, amplifier: Int)
    case removeEffects(RPGEntityTarget, ids: [String])
    case setMinimumAbsorption(RPGEntityTarget, Double)
    case grantWardenAbsorption(RPGEntityTarget, Double, ownerSequence: Int)
    case clearMenderInjury(RPGEntityTarget, expectedNonce: Int)
    case setArcanistFire(RPGEntityTarget, Int)
    case setFreezeTicks(RPGEntityTarget, Int)
    case addVelocity(RPGEntityTarget, Double, Double, Double)
    case teleportOwner(RPGTeleportMutation)
    case damageHeld(Int)
    case setBlock(RPGBlockMutation)
    case scheduleBlockTick(RPGBlockPosition, id: Int, delay: Int)
    case resolveContainerLoot(RPGBlockPosition)
    case triggerDevice(RPGBlockPosition, expectedCell: Int)
    case registerTemporary(RPGTemporaryEffectDraft)
    case removeTemporary(RPGTemporaryEffectKey, restoreGuardedBlock: Bool)
    case spawnAllay(RPGSpawnAllayMutation)
}

enum RPGActionResultTemplate: Equatable {
    case fixed(String, targetEntityID: Int? = nil, blockPosition: RPGBlockPosition? = nil)
    case containerOccupancy(RPGBlockPosition, maximumSlots: Int)
    case fortuneRead(RPGBlockPosition, precision: Int)
}

struct RPGActionFeedback: Equatable {
    var particle: String
    var x: Double, y: Double, z: Double
    var count: Int
    var spread: Double
    var data: Int
}

public struct RPGPreparedMutation {
    let identity: RPGExecutableEffectID
    let metadata: RPGActionMetadata
    let authorization: RPGActionAuthorization
    let worldIdentity: ObjectIdentifier
    let dimension: Int
    let simulationTick: Int
    let ownerEntityID: Int
    let ownerGuard: RPGEntityGuard
    let expectedRPG: RPGCharacterState
    let nextRPG: RPGCharacterState
    let expectedItems: RPGPlayerItemsSnapshot
    let nextItems: RPGPlayerItemsSnapshot?
    let entityGuards: [RPGEntityGuard]
    let blockGuards: [RPGBlockGuard]
    let containerGuards: [RPGContainerGuard]
    let operations: [RPGMutationOperation]
    let feedback: [RPGActionFeedback]
    let resultTemplate: RPGActionResultTemplate
}
