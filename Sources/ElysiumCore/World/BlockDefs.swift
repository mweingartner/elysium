// The block registry — Every block in the game.
// Cells are UInt16: (id << 4) | meta. Tile registration order is deterministic
// so the atlas painter and mesher agree on layer indices.

import Foundation

// MARK: - enums

public enum Shape: UInt8 {
    case cube = 0, cross, slab, stairs, fence, fenceGate, wall, pane, door, trapdoor
    case torch, lever, button, pressurePlate, liquid, layer, farmland, path, crop
    case carpet, rail, chest, ladder, sign, wallSign, hangingSign, cake, bed, anvil, hopper
    case cauldron, brewingStand, enchantTable, lantern, chain, flowerPot, endPortalFrame
    case dragonEgg, conduit, grindstone, stonecutter, bamboo, candle, seaPickle, turtleEgg
    case dripstone, amethystCluster, snifferEgg, decoratedPot, campfire, scaffolding
    case tripwire, tripwireHook, redstoneWire, repeater, comparator, piston, pistonHead
    case daylightSensor, chorus, chorusFlower, cocoa, vine, lilyPad, glowLichen
    case sporeBlossom, hangingRoots, bigDripleaf, smallDripleafShape, propagule, frogspawn
    case web, fire, portalShape, endPortalShape, bell, composter, pointedAttach, tallCross
    case bars, head, lectern, rootsShape, netherWart, sweetBerry, caveVinesShape, beacon
    case structureVoid, bambooSapling, pitcherCropShape, muddyMangroveRoots, sculkVein, cactusShape, air
}

public enum ToolType: String {
    case pickaxe, axe, shovel, hoe, sword, shears, none
}

public enum PistonBehavior: UInt8 { case normal = 0, destroy, block, blockEntity }

// MARK: - drops

public struct Drop {
    public let item: String
    public let countMin: Int
    public let countMax: Int
    public let chance: Double

    public init(_ item: String, _ count: Int = 1, chance: Double = 1) {
        self.item = item
        countMin = count
        countMax = count
        self.chance = chance
    }
    public init(_ item: String, _ min: Int, _ max: Int, chance: Double = 1) {
        self.item = item
        countMin = min
        countMax = max
        self.chance = chance
    }
}

public struct DropCtx {
    public let fortune: Int
    public let silkTouch: Bool
    public let toolType: ToolType
    public let toolTier: Int
    public let shears: Bool
    public let random: () -> Double

    public init(fortune: Int = 0, silkTouch: Bool = false, toolType: ToolType = .none,
                toolTier: Int = 0, shears: Bool = false, random: @escaping () -> Double) {
        self.fortune = fortune
        self.silkTouch = silkTouch
        self.toolType = toolType
        self.toolTier = toolTier
        self.shears = shears
        self.random = random
    }
}

/// mirrors the baseline drops union: undefined (self) / null / 'item' / [list] / fn
public enum DropSpec {
    case selfDrop
    case none
    case item(String)
    case list([Drop])
    case fn((Int, DropCtx) -> [Drop])
}

/// mirrors the baseline tex union: undefined (name) / 'tile' / Int32Array
public enum TexSpec {
    case own
    case named(String)
    case faces([Int32])
}

// MARK: - tile registry

private var tileNames: [String] = []
private var tileMap: [String: Int] = [:]

@discardableResult
public func tileId(_ name: String) -> Int {
    if let t = tileMap[name] { return t }
    let t = tileNames.count
    tileNames.append(name)
    tileMap[name] = t
    return t
}
public func allTileNames() -> [String] { tileNames }
public func tileCount() -> Int { tileNames.count }
public func tileName(_ idx: Int) -> String { idx >= 0 && idx < tileNames.count ? tileNames[idx] : "missing" }

public func tex(_ all: String) -> TexSpec {
    let t = Int32(tileId(all))
    return .faces([t, t, t, t, t, t])
}
public func texTB(_ top: String, _ bottom: String, _ side: String) -> TexSpec {
    let s = Int32(tileId(side))
    return .faces([Int32(tileId(bottom)), Int32(tileId(top)), s, s, s, s])
}
public func texCol(_ end: String, _ side: String) -> TexSpec {
    let e = Int32(tileId(end)), s = Int32(tileId(side))
    return .faces([e, e, s, s, s, s])
}
public func tex6(_ d: String, _ u: String, _ n: String, _ s: String, _ w: String, _ e: String) -> TexSpec {
    .faces([Int32(tileId(d)), Int32(tileId(u)), Int32(tileId(n)), Int32(tileId(s)), Int32(tileId(w)), Int32(tileId(e))])
}

// MARK: - block definition

public final class BlockDef {
    public let id: Int
    public let name: String
    public let displayName: String
    public let shape: Shape
    public let tex: [Int32]
    public let texFn: ((Int, Int) -> Int)?
    public let opaque: Bool
    public let solid: Bool
    public let fullCube: Bool
    public let replaceable: Bool
    public let lightEmit: Int
    public let lightOpacity: Int
    public let hardness: Double
    public let resistance: Double
    public let tool: ToolType
    public let tier: Int
    public let requiresTool: Bool
    public let sound: String
    public let tint: Int
    public let flammable: Int
    public let burnOdds: Int
    public let piston: PistonBehavior
    public let gravity: Bool
    public let climbable: Bool
    public let randomTicks: Bool
    public let transparentRender: Bool
    public let translucent: Bool
    public let emissiveRender: Bool
    public let cullSame: Bool
    public let drops: ((Int, DropCtx) -> [Drop])?
    public let ao: Bool

    init(id: Int, name: String, displayName: String, shape: Shape, tex: [Int32], texFn: ((Int, Int) -> Int)?,
         opaque: Bool, solid: Bool, fullCube: Bool, replaceable: Bool, lightEmit: Int, lightOpacity: Int,
         hardness: Double, resistance: Double, tool: ToolType, tier: Int, requiresTool: Bool,
         sound: String, tint: Int, flammable: Int, burnOdds: Int, piston: PistonBehavior,
         gravity: Bool, climbable: Bool, randomTicks: Bool, transparentRender: Bool,
         translucent: Bool, emissiveRender: Bool, cullSame: Bool, drops: ((Int, DropCtx) -> [Drop])?, ao: Bool) {
        self.id = id; self.name = name; self.displayName = displayName; self.shape = shape
        self.tex = tex; self.texFn = texFn; self.opaque = opaque; self.solid = solid
        self.fullCube = fullCube; self.replaceable = replaceable; self.lightEmit = lightEmit
        self.lightOpacity = lightOpacity; self.hardness = hardness; self.resistance = resistance
        self.tool = tool; self.tier = tier; self.requiresTool = requiresTool; self.sound = sound
        self.tint = tint; self.flammable = flammable; self.burnOdds = burnOdds; self.piston = piston
        self.gravity = gravity; self.climbable = climbable; self.randomTicks = randomTicks
        self.transparentRender = transparentRender; self.translucent = translucent
        self.emissiveRender = emissiveRender; self.cullSame = cullSame; self.drops = drops; self.ao = ao
    }
}

public var blockDefs: [BlockDef] = []
private var byName: [String: Int] = [:]

func prettify(_ name: String) -> String {
    name.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
}

@discardableResult
public func registerBlock(
    _ name: String,
    shape: Shape = .cube,
    tex texSpec: TexSpec = .own,
    texFn: ((Int, Int) -> Int)? = nil,
    display: String? = nil,
    opaque: Bool = true,
    solid: Bool = true,
    fullCube: Bool? = nil,
    replaceable: Bool = false,
    light: Int = 0,
    lightOpacity: Int? = nil,
    hardness: Double = 1,
    resistance: Double? = nil,
    tool: ToolType = .none,
    tier: Int = 0,
    requiresTool: Bool = false,
    sound: String = "stone",
    tint: Int = 0,
    flammable: Int = 0,
    burnOdds: Int = 0,
    piston: PistonBehavior = .normal,
    gravity: Bool = false,
    climbable: Bool = false,
    randomTicks: Bool = false,
    transparentRender: Bool? = nil,
    translucent: Bool = false,
    emissiveRender: Bool? = nil,
    cullSame: Bool = false,
    drops: DropSpec = .selfDrop,
    ao: Bool = true
) -> UInt16 {
    let id = blockDefs.count
    precondition(id < 4096, "block id space exhausted")
    precondition(byName[name] == nil, "duplicate block: \(name)")
    let texArr: [Int32]
    switch texSpec {
    case .own:
        let t = Int32(tileId(name))
        texArr = [t, t, t, t, t, t]
    case .named(let n):
        let t = Int32(tileId(n))
        texArr = [t, t, t, t, t, t]
    case .faces(let arr):
        texArr = arr
    }
    let dropsFn: ((Int, DropCtx) -> [Drop])?
    switch drops {
    case .selfDrop: dropsFn = nil
    case .none: dropsFn = { _, _ in [] }
    case .item(let it): dropsFn = { _, _ in [Drop(it)] }
    case .list(let arr): dropsFn = { _, _ in arr }
    case .fn(let f): dropsFn = f
    }
    let def = BlockDef(
        id: id, name: name,
        displayName: display ?? prettify(name),
        shape: shape,
        tex: texArr,
        texFn: texFn,
        opaque: opaque,
        solid: solid,
        fullCube: fullCube ?? (shape == .cube),
        replaceable: replaceable,
        lightEmit: light,
        lightOpacity: lightOpacity ?? (opaque ? 15 : 0),
        hardness: hardness,
        resistance: resistance ?? hardness,
        tool: tool, tier: tier, requiresTool: requiresTool,
        sound: sound, tint: tint, flammable: flammable, burnOdds: burnOdds,
        piston: piston, gravity: gravity, climbable: climbable, randomTicks: randomTicks,
        transparentRender: transparentRender ?? !opaque,
        translucent: translucent,
        emissiveRender: emissiveRender ?? (light >= 10),
        cullSame: cullSame,
        drops: dropsFn,
        ao: ao
    )
    blockDefs.append(def)
    byName[name] = id
    return UInt16(id)
}

public func bid(_ name: String) -> UInt16 {
    guard let id = byName[name] else { fatalError("unknown block: \(name)") }
    return UInt16(id)
}
public func bidOpt(_ name: String) -> UInt16? { byName[name].map(UInt16.init) }
public func blockName(_ id: Int) -> String { id < blockDefs.count ? blockDefs[id].name : "air" }
public func blockExists(_ name: String) -> Bool { byName[name] != nil }

/// block id lookup: `B.stone` is a stored field resolved once at registration
/// (BlockIDsCache.swift) — a direct load on every hot path. Interpolated names
/// (`B["\(w)_slab"]`) and unlisted members fall back to the byName dictionary.
public var B = ResolvedBlockIDs()
