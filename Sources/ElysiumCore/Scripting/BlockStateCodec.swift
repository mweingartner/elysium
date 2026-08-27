// BlockStateCodec.swift — object-graph-attributes (change 1a). design.md
// Decision 8 / spec `block-state-codec`. A verified meta-bit codec (every
// field cites its engine source below), id-family descriptors (`lit`
// swaps), and the block-family table implementing the block identity rule
// (§17 #5). The Builder adds only fields whose bit layout is verified against
// the engine — an unverified shape (candle/turtle-egg counts, campfire item
// slots) stays absent rather than guessed.

import Foundation

public enum BlockStateCodec {
    // MARK: - decode (total: every cell, every applicable field)

    /// Every field of `cell`'s shape/id, as canonical `AttrValue`s. Total —
    /// never traps for any `id << 4 | meta`. `waterlogged`/`lit` read the id
    /// directly (id-family membership, not meta bits).
    public static func decode(_ cell: Int) -> [String: AttrValue] {
        let id = cell >> 4
        guard id >= 0, id < blockDefs.count else { return [:] }
        let meta = cell & 15
        let shape = blockDefs[id].shape
        let name = blockDefs[id].name
        var out: [String: AttrValue] = [:]
        out["meta"] = .int(Int64(meta))
        out["waterlogged"] = .bool(isWaterlogged(UInt16(cell)))
        if let f = decodeFacing(shape: shape, name: name, meta: meta) { out["facing"] = .string(f) }
        if let h = decodeHalf(shape: shape, meta: meta) { out["half"] = .string(h) }
        if let o = decodeOpen(shape: shape, meta: meta) { out["open"] = .bool(o) }
        if let h = decodeHinge(shape: shape, meta: meta) { out["hinge"] = .string(h) }
        if let p = decodePowered(shape: shape, meta: meta) { out["powered"] = .bool(p) }
        if let d = decodeDelay(id: id, meta: meta) { out["delay"] = .int(Int64(d)) }
        if let m = decodeMode(id: id, meta: meta) { out["mode"] = .string(m) }
        if let a = decodeAge(shape: shape, meta: meta) { out["age"] = .int(Int64(a)) }
        if let a = decodeAxis(name: name, meta: meta) { out["axis"] = .string(a) }
        if let l = decodeLayers(shape: shape, meta: meta) { out["layers"] = .int(Int64(l)) }
        if let c = decodeCount(name: name, meta: meta) { out["count"] = .int(Int64(c)) }
        if let l = decodeLit(name: name) { out["lit"] = .bool(l) }
        return out
    }

    /// Writes `field` on the in-memory `cell`, masking only that field's bits
    /// and preserving every other bit. `nil` for an inapplicable field, an
    /// out-of-range value, or a wrong value kind.
    public static func encode(_ cell: Int, field: String, value: AttrValue) -> UInt16? {
        let id = cell >> 4
        guard id >= 0, id < blockDefs.count else { return nil }
        let meta = cell & 15
        let shape = blockDefs[id].shape
        let name = blockDefs[id].name
        var newMeta: Int?
        switch field {
        case "meta":
            guard case .int(let v) = value, v >= 0, v <= 15 else { return nil }
            newMeta = Int(v)
        case "facing":
            guard case .string(let s) = value else { return nil }
            newMeta = encodeFacing(shape: shape, name: name, meta: meta, value: s)
        case "half":
            guard case .string(let s) = value else { return nil }
            newMeta = encodeHalf(shape: shape, meta: meta, value: s)
        case "open":
            guard case .bool(let b) = value else { return nil }
            newMeta = encodeOpen(shape: shape, meta: meta, value: b)
        case "hinge":
            guard case .string(let s) = value else { return nil }
            newMeta = encodeHinge(shape: shape, meta: meta, value: s)
        case "powered":
            guard case .bool(let b) = value else { return nil }
            newMeta = encodePowered(shape: shape, meta: meta, value: b)
        case "delay":
            guard case .int(let v) = value else { return nil }
            newMeta = encodeDelay(id: id, meta: meta, value: Int(v))
        case "mode":
            guard case .string(let s) = value else { return nil }
            newMeta = encodeMode(id: id, meta: meta, value: s)
        case "age":
            guard case .int(let v) = value else { return nil }
            newMeta = encodeAge(shape: shape, meta: meta, value: Int(v))
        case "axis":
            guard case .string(let s) = value else { return nil }
            newMeta = encodeAxis(name: name, meta: meta, value: s)
        case "layers":
            guard case .int(let v) = value else { return nil }
            newMeta = encodeLayers(shape: shape, meta: meta, value: Int(v))
        case "count":
            guard case .int(let v) = value else { return nil }
            newMeta = encodeCount(name: name, meta: meta, value: Int(v))
        default:
            return nil
        }
        guard let m = newMeta, m >= 0, m <= 15 else { return nil }
        return UInt16((id << 4) | m)
    }

    /// `lit` is an id swap, not a meta field — returns the new full cell
    /// (same meta) or `nil` if `name` is not a `lit`-family id.
    public static func encodeLitSwap(_ cell: Int, on: Bool) -> UInt16? {
        let id = cell >> 4
        guard id >= 0, id < blockDefs.count else { return nil }
        let meta = cell & 15
        guard let newId = litSwapTarget(name: blockDefs[id].name, on: on) else { return nil }
        return UInt16((Int(newId) << 4) | meta)
    }

    // MARK: - facing (design.md Decision 8: facing-4 `meta & 3`
    // `["north","south","west","east"]`; facing-6 `meta & 7` as `Dir`
    // `["down","up","north","south","west","east"]`)

    private static let facing4Shapes: Set<Shape> = [
        .stairs, .door, .fenceGate, .bed, .repeater, .comparator, .campfire, .chest,
    ]
    private static let facing4Names: Set<String> = [
        "furnace", "furnace_lit", "blast_furnace", "blast_furnace_lit", "smoker", "smoker_lit",
        "carved_pumpkin", "jack_o_lantern", "loom", "chiseled_bookshelf",
    ]
    private static let facing6Shapes: Set<Shape> = [.piston, .pistonHead, .lever, .button]
    private static let facing6Names: Set<String> = ["observer", "dispenser", "dropper", "barrel", "hopper"]
    private static let facing4Values = ["north", "south", "west", "east"]

    private static func decodeFacing(shape: Shape, name: String, meta: Int) -> String? {
        if facing4Shapes.contains(shape) || facing4Names.contains(name) {
            return facing4Values[meta & 3]
        }
        if facing6Shapes.contains(shape) || facing6Names.contains(name) {
            let d = meta & 7
            return d < DIR_NAMES.count ? DIR_NAMES[d] : DIR_NAMES[0]
        }
        return nil
    }

    private static func encodeFacing(shape: Shape, name: String, meta: Int, value: String) -> Int? {
        if facing4Shapes.contains(shape) || facing4Names.contains(name) {
            guard let idx = facing4Values.firstIndex(of: value) else { return nil }
            return (meta & ~3) | idx
        }
        if facing6Shapes.contains(shape) || facing6Names.contains(name) {
            guard let idx = DIR_NAMES.firstIndex(of: value) else { return nil }
            return (meta & ~7) | idx
        }
        return nil
    }

    // MARK: - half (Interact.swift `placementMeta`: stairs bit 4, slab bit 1,
    // trapdoor bit 8; `useBlock`'s door toggle `(meta & 8) != 0 ? y - 1 : y`
    // confirms door bit 8 = half)

    private static func decodeHalf(shape: Shape, meta: Int) -> String? {
        switch shape {
        case .stairs: return (meta & 4) != 0 ? "top" : "bottom"
        case .slab: return (meta & 1) != 0 ? "top" : "bottom"
        case .trapdoor: return (meta & 8) != 0 ? "top" : "bottom"
        case .door: return (meta & 8) != 0 ? "upper" : "lower"
        default: return nil
        }
    }

    private static func encodeHalf(shape: Shape, meta: Int, value: String) -> Int? {
        switch shape {
        case .stairs:
            guard value == "top" || value == "bottom" else { return nil }
            return value == "top" ? (meta | 4) : (meta & ~4)
        case .slab:
            guard value == "top" || value == "bottom" else { return nil }
            return value == "top" ? (meta | 1) : (meta & ~1)
        case .trapdoor:
            guard value == "top" || value == "bottom" else { return nil }
            return value == "top" ? (meta | 8) : (meta & ~8)
        case .door:
            guard value == "upper" || value == "lower" else { return nil }
            return value == "upper" ? (meta | 8) : (meta & ~8)
        default:
            return nil
        }
    }

    /// Whether `y` (with cell `cell`) is the *lower* half of a two-tall door
    /// — used by callers with world access to redirect a door's `open`
    /// (always the lower half's bit) and `hinge` (always the upper half's
    /// bit) writes/reads to the correct cell (spec "Door writes touch the
    /// right half").
    public static func isDoorUpperHalf(_ cell: Int) -> Bool {
        (cell & 15 & 8) != 0
    }

    // MARK: - open (Interact.swift `useBlock`: door/trapdoor/fence-gate all
    // toggle `meta ^ 4`)

    private static let openShapes: Set<Shape> = [.door, .trapdoor, .fenceGate]

    private static func decodeOpen(shape: Shape, meta: Int) -> Bool? {
        guard openShapes.contains(shape) else { return nil }
        return (meta & 4) != 0
    }

    private static func encodeOpen(shape: Shape, meta: Int, value: Bool) -> Int? {
        guard openShapes.contains(shape) else { return nil }
        return value ? (meta | 4) : (meta & ~4)
    }

    // MARK: - hinge (design.md Decision 8: door, upper half, bit 1 — read
    // only from the block itself, not natively toggled by any engine path in
    // this codebase today)

    private static func decodeHinge(shape: Shape, meta: Int) -> String? {
        guard shape == .door else { return nil }
        return (meta & 1) != 0 ? "right" : "left"
    }

    private static func encodeHinge(shape: Shape, meta: Int, value: String) -> Int? {
        guard shape == .door, value == "left" || value == "right" else { return nil }
        return value == "right" ? (meta | 1) : (meta & ~1)
    }

    // MARK: - powered (Interact.swift `useBlock`: lever `meta ^ 8`, button
    // `meta | 8`)

    private static let poweredShapes: Set<Shape> = [.lever, .button]

    private static func decodePowered(shape: Shape, meta: Int) -> Bool? {
        guard poweredShapes.contains(shape) else { return nil }
        return (meta & 8) != 0
    }

    private static func encodePowered(shape: Shape, meta: Int, value: Bool) -> Int? {
        guard poweredShapes.contains(shape) else { return nil }
        return value ? (meta | 8) : (meta & ~8)
    }

    // MARK: - delay (Interact.swift `useBlock`: repeater
    // `((meta >> 2) & 3) + 1`, facing in bits 0-1)

    private static func decodeDelay(id: Int, meta: Int) -> Int? {
        guard id == Int(B.repeater) || id == Int(B.repeater_on) else { return nil }
        return ((meta >> 2) & 3) + 1
    }

    private static func encodeDelay(id: Int, meta: Int, value: Int) -> Int? {
        guard id == Int(B.repeater) || id == Int(B.repeater_on), value >= 1, value <= 4 else { return nil }
        return (meta & 3) | ((value - 1) << 2)
    }

    // MARK: - mode (Interact.swift `useBlock`: comparator `meta ^ 4`)

    private static func decodeMode(id: Int, meta: Int) -> String? {
        guard id == Int(B.comparator) || id == Int(B.comparator_on) else { return nil }
        return (meta & 4) != 0 ? "subtract" : "compare"
    }

    private static func encodeMode(id: Int, meta: Int, value: String) -> Int? {
        guard id == Int(B.comparator) || id == Int(B.comparator_on) else { return nil }
        guard value == "compare" || value == "subtract" else { return nil }
        return value == "subtract" ? (meta | 4) : (meta & ~4)
    }

    // MARK: - age (design.md Decision 8: `.crop`/`.netherWart`, `meta & 7`)

    private static func decodeAge(shape: Shape, meta: Int) -> Int? {
        guard shape == .crop || shape == .netherWart else { return nil }
        return meta & 7
    }

    private static func encodeAge(shape: Shape, meta: Int, value: Int) -> Int? {
        guard shape == .crop || shape == .netherWart, value >= 0, value <= 7 else { return nil }
        return (meta & ~7) | value
    }

    // MARK: - axis (Interact.swift `placementMeta` default case: log/stem/
    // wood/hyphae/basalt/bone_block/chain/quartz_pillar/purpur_pillar/
    // bamboo_block, `0=y 1=x 2=z`)

    private static let axisValues = ["y", "x", "z"]

    static func isAxisBlockName(_ name: String) -> Bool {
        name.hasSuffix("_log") || name.hasSuffix("_stem") || name.hasSuffix("_wood")
            || name.contains("hyphae") || name.contains("basalt") || name == "bone_block"
            || name == "chain" || name == "quartz_pillar" || name == "purpur_pillar" || name == "bamboo_block"
    }

    private static func decodeAxis(name: String, meta: Int) -> String? {
        guard isAxisBlockName(name) else { return nil }
        let idx = meta & 3
        return idx < axisValues.count ? axisValues[idx] : "y"
    }

    private static func encodeAxis(name: String, meta: Int, value: String) -> Int? {
        guard isAxisBlockName(name), let idx = axisValues.firstIndex(of: value) else { return nil }
        return (meta & ~3) | idx
    }

    // MARK: - layers (design.md Decision 8: snow layer shape, `(meta & 7) + 1`)

    private static func decodeLayers(shape: Shape, meta: Int) -> Int? {
        guard shape == .layer else { return nil }
        return (meta & 7) + 1
    }

    private static func encodeLayers(shape: Shape, meta: Int, value: Int) -> Int? {
        guard shape == .layer, value >= 1, value <= 8 else { return nil }
        return (meta & ~7) | (value - 1)
    }

    // MARK: - count (verified only for sea pickle: `BlockRegistry3.swift:382`,
    // `BlockRegistry.swift:377`, `(meta & 3) + 1`)

    private static func decodeCount(name: String, meta: Int) -> Int? {
        guard name == "sea_pickle" else { return nil }
        return (meta & 3) + 1
    }

    private static func encodeCount(name: String, meta: Int, value: Int) -> Int? {
        guard name == "sea_pickle", value >= 1, value <= 4 else { return nil }
        return (meta & ~3) | (value - 1)
    }

    // MARK: - lit (id-family swap, `Systems/BlockEntities.swift`'s furnace/
    // blast-furnace/smoker lit map, `Systems/Redstone.swift`'s
    // `redstone_lamp`/`redstone_lamp_on`)

    private static let litOnByOff: [String: String] = [
        "furnace": "furnace_lit", "blast_furnace": "blast_furnace_lit", "smoker": "smoker_lit",
        "redstone_lamp": "redstone_lamp_on",
    ]
    private static let litOffByOn: [String: String] = [
        "furnace_lit": "furnace", "blast_furnace_lit": "blast_furnace", "smoker_lit": "smoker",
        "redstone_lamp_on": "redstone_lamp",
    ]

    private static func decodeLit(name: String) -> Bool? {
        if litOffByOn[name] != nil { return true }
        if litOnByOff[name] != nil { return false }
        return nil
    }

    private static func litSwapTarget(name: String, on: Bool) -> UInt16? {
        let targetName: String?
        if on {
            targetName = litOnByOff[name] ?? (litOffByOn[name] != nil ? name : nil)
        } else {
            targetName = litOffByOn[name] ?? (litOnByOff[name] != nil ? name : nil)
        }
        guard let targetName else { return nil }
        return bidOpt(targetName)
    }

    // MARK: - id families and the block identity rule (spec "Block families
    // and the block identity rule", design.md Decision 8)

    /// The soil family (meta-only farmland aside — these ids themselves are
    /// otherwise a genuine id change, e.g. tilling `dirt` into `farmland`,
    /// that this game deliberately treats as "same family" so a scripted
    /// attribute survives ordinary terraforming) and every registered wood's
    /// sapling/log pair.
    private static let blockFamilies: [Set<String>] = {
        var families: [Set<String>] = [
            ["dirt", "grass_block", "coarse_dirt", "podzol", "mycelium", "rooted_dirt", "farmland", "dirt_path"],
        ]
        for wood in WOODS {
            families.append(["\(wood)_sapling", "\(wood)_log"])
        }
        return families
    }()

    /// `true` when `oldId == newId`, both ids are one `lit` pair, or both are
    /// in one block-family row. `World.setBlock` uses this to decide whether
    /// a block's `ObjectRecord` survives an id change.
    public static func sameFamily(_ oldId: Int, _ newId: Int) -> Bool {
        if oldId == newId { return true }
        guard oldId >= 0, oldId < blockDefs.count, newId >= 0, newId < blockDefs.count else { return false }
        let oldName = blockDefs[oldId].name
        let newName = blockDefs[newId].name
        if litOnByOff[oldName] == newName || litOnByOff[newName] == oldName { return true }
        for family in blockFamilies where family.contains(oldName) && family.contains(newName) {
            return true
        }
        return false
    }

    /// Writes `field` on the live cell at `(x,y,z)` through
    /// `World.setBlock(..., SET_DEFAULT)` so light/remesh/neighbours/the LAN
    /// change log all fire, redirecting `open`/`hinge` on a door to the half
    /// the engine actually stores them on (spec "Door writes touch the right
    /// half"). Returns `false` for an inapplicable field, an out-of-range
    /// value, or a wrong value kind — the world is left unchanged either way.
    static func preflightWrite(
        _ world: World, _ x: Int, _ y: Int, _ z: Int, field: String, value: AttrValue
    ) -> (targetY: Int, cell: UInt16)? {
        var targetY = y
        let originalCell = world.getBlock(x, y, z)
        let originalID = originalCell >> 4
        guard originalID >= 0, originalID < blockDefs.count else { return nil }
        if blockDefs[originalID].shape == .door {
            let isUpper = isDoorUpperHalf(originalCell)
            if field == "open", isUpper { targetY = y - 1 }
            if field == "hinge", !isUpper { targetY = y + 1 }
        }
        let targetCell = world.getBlock(x, targetY, z)
        if field == "lit" {
            guard case .bool(let on) = value,
                  let encoded = encodeLitSwap(targetCell, on: on) else { return nil }
            return (targetY, encoded)
        }
        guard let encoded = encode(targetCell, field: field, value: value) else { return nil }
        return (targetY, encoded)
    }

    @discardableResult
    public static func write(_ world: World, _ x: Int, _ y: Int, _ z: Int, field: String, value: AttrValue) -> Bool {
        guard let plan = preflightWrite(world, x, y, z, field: field, value: value) else {
            return false
        }
        world.setBlock(x, plan.targetY, z, Int(plan.cell), SET_DEFAULT)
        return true
    }
}
