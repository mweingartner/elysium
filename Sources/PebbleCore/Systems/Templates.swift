import Foundation

public let OBJECT_TEMPLATE_VERSION = 1
public let OBJECT_TEMPLATE_MAX_BLOCKS = 32_768
public let OBJECT_TEMPLATE_MAX_SPAN = 96
public let OBJECT_TEMPLATE_MAX_JSON_BYTES = 2_000_000
public let OBJECT_TEMPLATE_NAME_MAX = 48

public struct TemplateBlock: Codable, Equatable {
    public var dx: Int
    public var dy: Int
    public var dz: Int
    public var cell: UInt16

    public init(dx: Int, dy: Int, dz: Int, cell: UInt16) {
        self.dx = dx; self.dy = dy; self.dz = dz; self.cell = cell
    }
}

public struct ObjectTemplate: Codable {
    public var version: Int
    public var name: String
    public var anchorX: Int
    public var anchorY: Int
    public var anchorZ: Int
    public var sizeX: Int
    public var sizeY: Int
    public var sizeZ: Int
    public var blocks: [TemplateBlock]
    public var blockEntities: [BlockEntityData]

    public init(version: Int = OBJECT_TEMPLATE_VERSION, name: String,
                anchorX: Int, anchorY: Int, anchorZ: Int,
                sizeX: Int, sizeY: Int, sizeZ: Int,
                blocks: [TemplateBlock], blockEntities: [BlockEntityData] = []) {
        self.version = version
        self.name = name
        self.anchorX = anchorX; self.anchorY = anchorY; self.anchorZ = anchorZ
        self.sizeX = sizeX; self.sizeY = sizeY; self.sizeZ = sizeZ
        self.blocks = blocks
        self.blockEntities = blockEntities
    }
}

public struct TemplateCloneResult {
    public let template: ObjectTemplate
    public let minX: Int
    public let minY: Int
    public let minZ: Int
    public let maxX: Int
    public let maxY: Int
    public let maxZ: Int
}

public struct TemplatePlacementResult {
    public let originX: Int
    public let originY: Int
    public let originZ: Int
    public let blocksPlaced: Int
    public let blockEntitiesPlaced: Int
}

public struct ObjectTemplateSummary: Equatable {
    public let name: String
    public let sizeX: Int
    public let sizeY: Int
    public let sizeZ: Int
    public let blockCount: Int
    public let blockEntityCount: Int
    public let dominantBlockName: String
    public let dominantBlockDisplayName: String
}

public struct TemplateCloneOptions {
    public var maxBlocks: Int
    public var maxSpan: Int

    public init(maxBlocks: Int = OBJECT_TEMPLATE_MAX_BLOCKS, maxSpan: Int = OBJECT_TEMPLATE_MAX_SPAN) {
        self.maxBlocks = maxBlocks
        self.maxSpan = maxSpan
    }
}

public struct TemplatePlacementOptions {
    public var replaceExisting: Bool

    public init(replaceExisting: Bool = false) {
        self.replaceExisting = replaceExisting
    }
}

public enum TemplateError: Error, Equatable, CustomStringConvertible {
    case invalidName
    case missingTarget
    case targetNotCloneable
    case objectTooLarge(Int)
    case objectTooWide
    case templateEmpty
    case unsupportedVersion(Int)
    case corruptTemplate(String)
    case destinationUnavailable(Int, Int, Int)
    case destinationBlocked(Int, Int, Int)

    public var description: String {
        switch self {
        case .invalidName:
            return "Template names must be 1-\(OBJECT_TEMPLATE_NAME_MAX) characters and use letters, numbers, spaces, underscores, or hyphens."
        case .missingTarget:
            return "Point the cursor at a block first."
        case .targetNotCloneable:
            return "The targeted block looks like terrain or fluid, not a construction object."
        case .objectTooLarge(let count):
            return "Object is too large (\(count) blocks; limit \(OBJECT_TEMPLATE_MAX_BLOCKS))."
        case .objectTooWide:
            return "Object bounds are too wide; split it into smaller templates."
        case .templateEmpty:
            return "Template has no blocks."
        case .unsupportedVersion(let version):
            return "Unsupported template version \(version)."
        case .corruptTemplate(let why):
            return "Template is corrupt: \(why)."
        case .destinationUnavailable(let x, let y, let z):
            return "Destination is not loaded or out of bounds at \(x) \(y) \(z)."
        case .destinationBlocked(let x, let y, let z):
            return "Destination is blocked at \(x) \(y) \(z)."
        }
    }
}

private struct TemplatePos: Hashable, Comparable {
    let x: Int
    let y: Int
    let z: Int

    static func < (a: TemplatePos, b: TemplatePos) -> Bool {
        if a.y != b.y { return a.y < b.y }
        if a.z != b.z { return a.z < b.z }
        return a.x < b.x
    }
}

public func normalizedTemplateName(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= OBJECT_TEMPLATE_NAME_MAX else { return nil }
    var lastWasSpace = false
    var out = ""
    for scalar in trimmed.unicodeScalars {
        if scalar == " " {
            if !lastWasSpace { out.append(" ") }
            lastWasSpace = true
            continue
        }
        lastWasSpace = false
        let v = scalar.value
        let ok = (v >= 48 && v <= 57) || (v >= 65 && v <= 90) || (v >= 97 && v <= 122)
            || scalar == "_" || scalar == "-"
        guard ok else { return nil }
        out.unicodeScalars.append(UnicodeScalar(v >= 65 && v <= 90 ? v + 32 : v)!)
    }
    let normalized = out.trimmingCharacters(in: .whitespaces)
    return normalized.isEmpty ? nil : normalized
}

private func isTemplateTerrainOrFluid(_ id: Int) -> Bool {
    if id <= 0 || id >= blockDefs.count { return true }
    let def = blockDefs[id]
    if def.shape == .liquid || def.replaceable || def.hardness < 0 { return true }
    let name = def.name
    if name.hasSuffix("_ore") || name.hasPrefix("deepslate_") && name.hasSuffix("_ore") { return true }
    let terrain: Set<String> = [
        "air", "cave_air", "void_air", "water", "lava", "fire", "soul_fire",
        "grass_block", "dirt", "coarse_dirt", "rooted_dirt", "podzol", "mycelium",
        "sand", "red_sand", "gravel", "suspicious_sand", "suspicious_gravel",
        "clay", "mud", "farmland", "dirt_path", "snow", "powder_snow",
        "ice", "packed_ice", "blue_ice", "frosted_ice", "bedrock",
        "netherrack", "soul_sand", "soul_soil", "end_stone"
    ]
    return terrain.contains(name)
}

public func isTemplateCloneableBlock(_ cell: Int) -> Bool {
    let id = cell >> 4
    return !isTemplateTerrainOrFluid(id)
}

private func sanitizedTemplateStack(_ stack: ItemStack?) -> ItemStack? {
    guard let stack, stack.id >= 0, stack.id < itemDefs.count, stack.count > 0 else { return nil }
    let copy = stack.copy()
    copy.count = min(copy.count, itemDefs[copy.id].maxStack)
    if let contents = copy.data.contents {
        copy.data.contents = contents.map(sanitizedTemplateStack)
    }
    return copy
}

private func sanitizedTemplateBlockEntity(_ be: BlockEntityData) -> BlockEntityData? {
    guard let data = try? JSONEncoder().encode(be),
          let copy = try? JSONDecoder().decode(BlockEntityData.self, from: data) else { return nil }
    if let items = copy.items {
        copy.items = items.map(sanitizedTemplateStack)
    }
    copy.disc = sanitizedTemplateStack(copy.disc)
    copy.item = sanitizedTemplateStack(copy.item)
    return copy
}

private func templateBlockEntityCopy(_ be: BlockEntityData, minX: Int, minY: Int, minZ: Int) -> BlockEntityData? {
    guard let copy = sanitizedTemplateBlockEntity(be) else { return nil }
    copy.x -= minX
    copy.y -= minY
    copy.z -= minZ
    return copy
}

private func validateTemplate(_ template: ObjectTemplate) throws -> ObjectTemplate {
    guard template.version == OBJECT_TEMPLATE_VERSION else { throw TemplateError.unsupportedVersion(template.version) }
    guard normalizedTemplateName(template.name) != nil else { throw TemplateError.invalidName }
    guard !template.blocks.isEmpty else { throw TemplateError.templateEmpty }
    guard template.blocks.count <= OBJECT_TEMPLATE_MAX_BLOCKS else {
        throw TemplateError.objectTooLarge(template.blocks.count)
    }
    guard template.sizeX > 0, template.sizeY > 0, template.sizeZ > 0,
          template.sizeX <= OBJECT_TEMPLATE_MAX_SPAN,
          template.sizeY <= OBJECT_TEMPLATE_MAX_SPAN,
          template.sizeZ <= OBJECT_TEMPLATE_MAX_SPAN else {
        throw TemplateError.objectTooWide
    }

    var seen = Set<TemplatePos>()
    var blocks: [TemplateBlock] = []
    for block in template.blocks {
        guard block.dx >= 0, block.dy >= 0, block.dz >= 0,
              block.dx < template.sizeX, block.dy < template.sizeY, block.dz < template.sizeZ else {
            throw TemplateError.corruptTemplate("block outside template bounds")
        }
        let id = Int(block.cell >> 4)
        guard id > 0, id < blockDefs.count else {
            throw TemplateError.corruptTemplate("invalid block id \(id)")
        }
        let pos = TemplatePos(x: block.dx, y: block.dy, z: block.dz)
        guard seen.insert(pos).inserted else {
            throw TemplateError.corruptTemplate("duplicate block at \(block.dx),\(block.dy),\(block.dz)")
        }
        blocks.append(block)
    }
    blocks.sort { TemplatePos(x: $0.dx, y: $0.dy, z: $0.dz) < TemplatePos(x: $1.dx, y: $1.dy, z: $1.dz) }

    var blockEntities: [BlockEntityData] = []
    for be in template.blockEntities {
        guard be.x >= 0, be.y >= 0, be.z >= 0,
              be.x < template.sizeX, be.y < template.sizeY, be.z < template.sizeZ else {
            throw TemplateError.corruptTemplate("block entity outside template bounds")
        }
        guard seen.contains(TemplatePos(x: be.x, y: be.y, z: be.z)) else {
            throw TemplateError.corruptTemplate("block entity without a cloned block")
        }
        if let copy = sanitizedTemplateBlockEntity(be) { blockEntities.append(copy) }
    }
    blockEntities.sort {
        TemplatePos(x: $0.x, y: $0.y, z: $0.z) < TemplatePos(x: $1.x, y: $1.y, z: $1.z)
    }

    var out = template
    out.blocks = blocks
    out.blockEntities = blockEntities
    return out
}

public func encodeObjectTemplate(_ template: ObjectTemplate) throws -> Data {
    let validated = try validateTemplate(template)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(validated)
    guard data.count <= OBJECT_TEMPLATE_MAX_JSON_BYTES else {
        throw TemplateError.corruptTemplate("template JSON exceeds \(OBJECT_TEMPLATE_MAX_JSON_BYTES) bytes")
    }
    return data
}

public func decodeObjectTemplate(_ data: Data) throws -> ObjectTemplate {
    guard data.count <= OBJECT_TEMPLATE_MAX_JSON_BYTES else {
        throw TemplateError.corruptTemplate("template JSON exceeds \(OBJECT_TEMPLATE_MAX_JSON_BYTES) bytes")
    }
    return try validateTemplate(JSONDecoder().decode(ObjectTemplate.self, from: data))
}

public func summarizeObjectTemplate(_ rawTemplate: ObjectTemplate) throws -> ObjectTemplateSummary {
    let data = try encodeObjectTemplate(rawTemplate)
    let template = try decodeObjectTemplate(data)
    var counts: [Int: Int] = [:]
    for block in template.blocks {
        counts[Int(block.cell >> 4), default: 0] += 1
    }
    let dominant = counts.sorted {
        if $0.value != $1.value { return $0.value > $1.value }
        return blockDefs[$0.key].name < blockDefs[$1.key].name
    }.first?.key ?? 0
    let def = dominant > 0 && dominant < blockDefs.count ? blockDefs[dominant] : blockDefs[0]
    return ObjectTemplateSummary(
        name: template.name,
        sizeX: template.sizeX,
        sizeY: template.sizeY,
        sizeZ: template.sizeZ,
        blockCount: template.blocks.count,
        blockEntityCount: template.blockEntities.count,
        dominantBlockName: def.name,
        dominantBlockDisplayName: def.displayName)
}

public func cloneObjectTemplate(named rawName: String, from world: World,
                                targetX: Int, targetY: Int, targetZ: Int,
                                options: TemplateCloneOptions = TemplateCloneOptions()) throws -> TemplateCloneResult {
    guard let name = normalizedTemplateName(rawName) else { throw TemplateError.invalidName }
    let seedCell = world.getBlock(targetX, targetY, targetZ)
    guard seedCell != 0 else { throw TemplateError.missingTarget }
    guard isTemplateCloneableBlock(seedCell) else { throw TemplateError.targetNotCloneable }

    let neighborDeltas = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
    var seen = Set<TemplatePos>()
    var queue = [TemplatePos(x: targetX, y: targetY, z: targetZ)]
    var cursor = 0
    var cells: [TemplatePos: UInt16] = [queue[0]: UInt16(seedCell)]
    seen.insert(queue[0])
    var minX = targetX, maxX = targetX
    var minY = targetY, maxY = targetY
    var minZ = targetZ, maxZ = targetZ

    while cursor < queue.count {
        let p = queue[cursor]
        cursor += 1
        if cells.count > options.maxBlocks { throw TemplateError.objectTooLarge(cells.count) }
        if maxX - minX + 1 > options.maxSpan || maxY - minY + 1 > options.maxSpan || maxZ - minZ + 1 > options.maxSpan {
            throw TemplateError.objectTooWide
        }
        for d in neighborDeltas {
            let np = TemplatePos(x: p.x + d.0, y: p.y + d.1, z: p.z + d.2)
            if seen.contains(np) { continue }
            seen.insert(np)
            let cell = world.getBlock(np.x, np.y, np.z)
            guard isTemplateCloneableBlock(cell) else { continue }
            minX = min(minX, np.x); maxX = max(maxX, np.x)
            minY = min(minY, np.y); maxY = max(maxY, np.y)
            minZ = min(minZ, np.z); maxZ = max(maxZ, np.z)
            cells[np] = UInt16(cell)
            queue.append(np)
        }
    }

    guard !cells.isEmpty else { throw TemplateError.templateEmpty }
    let sorted = cells.keys.sorted()
    let blocks = sorted.map {
        TemplateBlock(dx: $0.x - minX, dy: $0.y - minY, dz: $0.z - minZ, cell: cells[$0]!)
    }
    var bes: [BlockEntityData] = []
    for pos in sorted {
        if let be = world.getBlockEntity(pos.x, pos.y, pos.z),
           let copy = templateBlockEntityCopy(be, minX: minX, minY: minY, minZ: minZ) {
            bes.append(copy)
        }
    }
    let template = ObjectTemplate(
        name: name,
        anchorX: targetX - minX, anchorY: targetY - minY, anchorZ: targetZ - minZ,
        sizeX: maxX - minX + 1, sizeY: maxY - minY + 1, sizeZ: maxZ - minZ + 1,
        blocks: blocks, blockEntities: bes)
    return TemplateCloneResult(template: try validateTemplate(template),
                               minX: minX, minY: minY, minZ: minZ,
                               maxX: maxX, maxY: maxY, maxZ: maxZ)
}

private func isDestinationReplaceable(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Bool {
    guard world.isLoadedAt(x, z), y >= world.info.minY, y < world.info.minY + world.info.height else { return false }
    let cell = world.getBlock(x, y, z)
    if cell == 0 { return true }
    let id = cell >> 4
    return id > 0 && id < blockDefs.count && blockDefs[id].replaceable
}

public func placeObjectTemplate(_ rawTemplate: ObjectTemplate, in world: World,
                                targetX: Int, targetY: Int, targetZ: Int,
                                options: TemplatePlacementOptions = TemplatePlacementOptions()) throws -> TemplatePlacementResult {
    let template = try validateTemplate(rawTemplate)
    let originX = targetX - template.anchorX
    let originY = targetY - template.anchorY
    let originZ = targetZ - template.anchorZ

    for block in template.blocks {
        let x = originX + block.dx
        let y = originY + block.dy
        let z = originZ + block.dz
        guard world.isLoadedAt(x, z), y >= world.info.minY, y < world.info.minY + world.info.height else {
            throw TemplateError.destinationUnavailable(x, y, z)
        }
        if !options.replaceExisting && !isDestinationReplaceable(world, x, y, z) {
            throw TemplateError.destinationBlocked(x, y, z)
        }
    }

    let positions = template.blocks.map { TemplatePos(x: originX + $0.dx, y: originY + $0.dy, z: originZ + $0.dz) }
    for block in template.blocks {
        _ = world.setBlock(originX + block.dx, originY + block.dy, originZ + block.dz,
                           Int(block.cell), SET_NO_NEIGHBORS)
    }
    var placedBEs = 0
    for be in template.blockEntities {
        guard let copy = sanitizedTemplateBlockEntity(be) else { continue }
        copy.x = originX + be.x
        copy.y = originY + be.y
        copy.z = originZ + be.z
        world.setBlockEntity(copy)
        placedBEs += 1
    }
    for p in positions.sorted() {
        world.updateNeighbors(p.x, p.y, p.z)
        world.notifyBlock(p.x, p.y, p.z, p.x, p.y, p.z)
    }
    return TemplatePlacementResult(originX: originX, originY: originY, originZ: originZ,
                                   blocksPlaced: template.blocks.count, blockEntitiesPlaced: placedBEs)
}
