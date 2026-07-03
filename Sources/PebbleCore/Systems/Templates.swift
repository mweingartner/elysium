import Foundation

public let OBJECT_TEMPLATE_VERSION = 1
public let OBJECT_TEMPLATE_MAX_BLOCKS = 32_768
public let OBJECT_TEMPLATE_MAX_SPAN = 96
public let OBJECT_TEMPLATE_MAX_JSON_BYTES = 2_000_000
public let OBJECT_TEMPLATE_NAME_MAX = 48
public let OBJECT_TEMPLATE_PREVIEW_MAX_BLOCKS = 4_096
public let OBJECT_TEMPLATE_PREVIEW_MAX_BOXES = OBJECT_TEMPLATE_PREVIEW_MAX_BLOCKS
public let OBJECT_TEMPLATE_MAX_SUPPORT_FILL_DEPTH = 32
public let OBJECT_TEMPLATE_PREVIEW_LINE_VERTICES_PER_BOX = 24

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
    public let blocksCleared: Int
    public let supportBlocksFilled: Int
}

public struct TemplatePlacementUndoCell {
    public let x: Int
    public let y: Int
    public let z: Int
    public let cell: Int
    public let blockEntity: BlockEntityData?
}

public struct TemplatePlacementUndoSnapshot {
    public let templateName: String
    public let cells: [TemplatePlacementUndoCell]
}

public struct TemplatePlacementTarget: Equatable {
    public let originX: Int
    public let originY: Int
    public let originZ: Int
    public let targetX: Int
    public let targetY: Int
    public let targetZ: Int
    public let distance: Double

    public init(originX: Int, originY: Int, originZ: Int,
                targetX: Int, targetY: Int, targetZ: Int, distance: Double) {
        self.originX = originX; self.originY = originY; self.originZ = originZ
        self.targetX = targetX; self.targetY = targetY; self.targetZ = targetZ
        self.distance = distance
    }
}

public struct ObjectTemplatePreviewBox: Equatable {
    public let cell: UInt16
    public let x0: Double
    public let y0: Double
    public let z0: Double
    public let x1: Double
    public let y1: Double
    public let z1: Double

    public init(cell: UInt16, x0: Double, y0: Double, z0: Double,
                x1: Double, y1: Double, z1: Double) {
        self.cell = cell
        self.x0 = x0; self.y0 = y0; self.z0 = z0
        self.x1 = x1; self.y1 = y1; self.z1 = z1
    }
}

public struct TemplatePlacementSession {
    public let name: String
    public let baseTemplate: ObjectTemplate
    public private(set) var rotatedTemplate: ObjectTemplate
    public private(set) var rotationSteps: Int

    public init(template: ObjectTemplate, rotationSteps: Int = 0) throws {
        self.baseTemplate = try validateTemplate(template)
        self.name = self.baseTemplate.name
        self.rotationSteps = normalizedTemplateRotation(rotationSteps)
        self.rotatedTemplate = try rotatedObjectTemplate(self.baseTemplate, rotationSteps: self.rotationSteps)
    }

    public mutating func rotate(by delta: Int) throws {
        rotationSteps = normalizedTemplateRotation(rotationSteps + delta)
        rotatedTemplate = try rotatedObjectTemplate(baseTemplate, rotationSteps: rotationSteps)
    }

    public var rotationDegrees: Int { rotationSteps * 90 }
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

public enum TemplateBlockSelector: Equatable {
    case exact(UInt16)
    case woodFamily
}

public struct ObjectTemplateReplacementResult {
    public let template: ObjectTemplate
    public let replacedBlocks: Int
    public let fromDescription: String
    public let toBlockName: String
}

public struct ObjectTemplateBlockPaletteEntry: Equatable {
    public let blockName: String
    public let blockDisplayName: String
    public let count: Int
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
    public var prepareTerrain: Bool

    public init(replaceExisting: Bool = false, prepareTerrain: Bool = false) {
        self.replaceExisting = replaceExisting
        self.prepareTerrain = prepareTerrain
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
    case foundationTooDeep(Int, Int, Int)

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
        case .foundationTooDeep(let x, let y, let z):
            return "Foundation gap is too deep at \(x) \(y) \(z); move the object closer to terrain."
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

private let templateCloneNeighborDeltas: [(Int, Int, Int)] = [
    (1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1),
    (1, 1, 0), (-1, 1, 0), (1, -1, 0), (-1, -1, 0),
    (1, 0, 1), (-1, 0, 1), (1, 0, -1), (-1, 0, -1),
    (0, 1, 1), (0, -1, 1), (0, 1, -1), (0, -1, -1),
]

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

private func stripContainedItemsFromTemplateClone(_ copy: BlockEntityData) {
    guard let items = copy.items else { return }
    copy.items = Array<ItemStack?>(repeating: nil, count: items.count)
    copy.lootTable = nil
    copy.lootSeed = nil
    copy.viewers = nil
    switch copy.type {
    case "hopper":
        copy.cooldown = 0
    case "furnace":
        copy.burnTime = 0
        copy.burnTotal = 0
        copy.cookTime = 0
        copy.cookTotal = copy.cookTotal ?? 200
        copy.xpBank = 0
    case "brewing":
        copy.brewTime = 0
        copy.fuel = 0
    case "shelf":
        copy.lastSlot = -1
    case "campfire":
        copy.times = Array(repeating: 0, count: max(4, items.count))
    default:
        break
    }
}

private func templateCloneCellWithoutContainedItemState(_ cellValue: UInt16, blockEntity be: BlockEntityData?) -> UInt16 {
    guard be?.items != nil else { return cellValue }
    let id = Int(cellValue >> 4)
    let meta = Int(cellValue & 15)
    switch id {
    case Int(B.furnace_lit):
        return cell(B.furnace, meta)
    case Int(B.blast_furnace_lit):
        return cell(B.blast_furnace, meta)
    case Int(B.smoker_lit):
        return cell(B.smoker, meta)
    case Int(B.chiseled_bookshelf):
        return cell(B.chiseled_bookshelf, meta & ~4)
    default:
        return cellValue
    }
}

private func templateCloneBlockEntityCopy(_ be: BlockEntityData, minX: Int, minY: Int, minZ: Int) -> BlockEntityData? {
    guard let copy = sanitizedTemplateBlockEntity(be) else { return nil }
    stripContainedItemsFromTemplateClone(copy)
    copy.x -= minX
    copy.y -= minY
    copy.z -= minZ
    return copy
}

public func normalizedTemplateRotation(_ steps: Int) -> Int {
    ((steps % 4) + 4) % 4
}

private func rotatedTemplateSize(_ template: ObjectTemplate, rotationSteps: Int) -> (x: Int, y: Int, z: Int) {
    switch normalizedTemplateRotation(rotationSteps) {
    case 1, 3:
        return (template.sizeZ, template.sizeY, template.sizeX)
    default:
        return (template.sizeX, template.sizeY, template.sizeZ)
    }
}

private func rotatedTemplateCoordinate(x: Int, y: Int, z: Int,
                                       sizeX: Int, sizeZ: Int,
                                       rotationSteps: Int) -> (x: Int, y: Int, z: Int) {
    switch normalizedTemplateRotation(rotationSteps) {
    case 1:
        return (sizeZ - 1 - z, y, x)
    case 2:
        return (sizeX - 1 - x, y, sizeZ - 1 - z)
    case 3:
        return (z, y, sizeX - 1 - x)
    default:
        return (x, y, z)
    }
}

public func rotatedObjectTemplate(_ rawTemplate: ObjectTemplate, rotationSteps: Int) throws -> ObjectTemplate {
    let rotation = normalizedTemplateRotation(rotationSteps)
    let template = try validateTemplate(rawTemplate)
    guard rotation != 0 else { return template }
    let size = rotatedTemplateSize(template, rotationSteps: rotation)
    let anchor = rotatedTemplateCoordinate(x: template.anchorX, y: template.anchorY, z: template.anchorZ,
                                           sizeX: template.sizeX, sizeZ: template.sizeZ,
                                           rotationSteps: rotation)
    let blocks = template.blocks.map { block in
        let p = rotatedTemplateCoordinate(x: block.dx, y: block.dy, z: block.dz,
                                          sizeX: template.sizeX, sizeZ: template.sizeZ,
                                          rotationSteps: rotation)
        return TemplateBlock(dx: p.x, dy: p.y, dz: p.z, cell: block.cell)
    }
    var blockEntities: [BlockEntityData] = []
    for be in template.blockEntities {
        guard let copy = sanitizedTemplateBlockEntity(be) else { continue }
        let p = rotatedTemplateCoordinate(x: copy.x, y: copy.y, z: copy.z,
                                          sizeX: template.sizeX, sizeZ: template.sizeZ,
                                          rotationSteps: rotation)
        copy.x = p.x; copy.y = p.y; copy.z = p.z
        blockEntities.append(copy)
    }
    return try validateTemplate(ObjectTemplate(
        version: template.version,
        name: template.name,
        anchorX: anchor.x, anchorY: anchor.y, anchorZ: anchor.z,
        sizeX: size.x, sizeY: size.y, sizeZ: size.z,
        blocks: blocks,
        blockEntities: blockEntities))
}

public func templatePlacementPreviewDistance(for rawTemplate: ObjectTemplate) throws -> Double {
    let template = try validateTemplate(rawTemplate)
    let sx = Double(template.sizeX)
    let sy = Double(template.sizeY)
    let sz = Double(template.sizeZ)
    let radius = (sx * sx + sy * sy + sz * sz).squareRoot() * 0.5
    return max(6.0, radius * 2.2 + 2.0)
}

public func objectTemplatePlacementTarget(for rawTemplate: ObjectTemplate,
                                          eyeX: Double, eyeY: Double, eyeZ: Double,
                                          yaw: Double, pitch: Double) throws -> TemplatePlacementTarget {
    let template = try validateTemplate(rawTemplate)
    let distance = try templatePlacementPreviewDistance(for: template)
    let dx = -detSin(yaw) * detCos(pitch)
    let dy = -detSin(pitch)
    let dz = detCos(yaw) * detCos(pitch)
    let centerX = eyeX + dx * distance
    let centerY = eyeY + dy * distance
    let centerZ = eyeZ + dz * distance
    let originX = Int((centerX - Double(template.sizeX) * 0.5).rounded(.down))
    let originY = Int((centerY - Double(template.sizeY) * 0.5).rounded(.down))
    let originZ = Int((centerZ - Double(template.sizeZ) * 0.5).rounded(.down))
    return TemplatePlacementTarget(
        originX: originX, originY: originY, originZ: originZ,
        targetX: originX + template.anchorX,
        targetY: originY + template.anchorY,
        targetZ: originZ + template.anchorZ,
        distance: distance)
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

public func objectTemplatePreviewLineVertexCount(boxCount: Int, includeBounds: Bool = false) -> Int {
    max(0, boxCount) * OBJECT_TEMPLATE_PREVIEW_LINE_VERTICES_PER_BOX
        + (includeBounds ? OBJECT_TEMPLATE_PREVIEW_LINE_VERTICES_PER_BOX : 0)
}

public func objectTemplatePreviewLineByteCount(boxCount: Int, includeBounds: Bool = false) -> Int {
    objectTemplatePreviewLineVertexCount(boxCount: boxCount, includeBounds: includeBounds)
        * 3 * MemoryLayout<Float>.stride
}

public func objectTemplatePreviewBoxes(for rawTemplate: ObjectTemplate,
                                       maxBoxes rawMaxBoxes: Int = OBJECT_TEMPLATE_PREVIEW_MAX_BOXES) throws -> [ObjectTemplatePreviewBox] {
    let template = try validateTemplate(rawTemplate)
    let maxBoxes = max(0, min(rawMaxBoxes, OBJECT_TEMPLATE_PREVIEW_MAX_BOXES))
    guard maxBoxes > 0 else { return [] }

    var occupied = Set<TemplatePos>()
    occupied.reserveCapacity(template.blocks.count)
    var cells: [TemplatePos: UInt16] = [:]
    cells.reserveCapacity(template.blocks.count)
    for block in template.blocks {
        let pos = TemplatePos(x: block.dx, y: block.dy, z: block.dz)
        occupied.insert(pos)
        cells[pos] = block.cell
    }

    let neighbors = [
        TemplatePos(x: 1, y: 0, z: 0), TemplatePos(x: -1, y: 0, z: 0),
        TemplatePos(x: 0, y: 1, z: 0), TemplatePos(x: 0, y: -1, z: 0),
        TemplatePos(x: 0, y: 0, z: 1), TemplatePos(x: 0, y: 0, z: -1),
    ]
    let surfaceOnly = template.blocks.count > maxBoxes
    var out: [ObjectTemplatePreviewBox] = []
    out.reserveCapacity(min(maxBoxes, template.blocks.count))
    var scratch: [AABB] = []

    for block in template.blocks {
        let pos = TemplatePos(x: block.dx, y: block.dy, z: block.dz)
        if surfaceOnly {
            let isSurface = neighbors.contains { delta in
                !occupied.contains(TemplatePos(x: pos.x + delta.x, y: pos.y + delta.y, z: pos.z + delta.z))
            }
            if !isSurface { continue }
        }

        scratch.removeAll(keepingCapacity: true)
        shapeBoxes(Int(block.cell), { dx, dy, dz in
            Int(cells[TemplatePos(x: pos.x + dx, y: pos.y + dy, z: pos.z + dz)] ?? 0)
        }, &scratch, false)
        if scratch.isEmpty {
            scratch.append(aabb(0, 0, 0, 1, 1, 1))
        }

        for box in scratch {
            out.append(ObjectTemplatePreviewBox(
                cell: block.cell,
                x0: Double(block.dx) + box.x0,
                y0: Double(block.dy) + box.y0,
                z0: Double(block.dz) + box.z0,
                x1: Double(block.dx) + box.x1,
                y1: Double(block.dy) + box.y1,
                z1: Double(block.dz) + box.z1))
            if out.count >= maxBoxes { return out }
        }
    }

    if out.isEmpty, let block = template.blocks.first {
        out.append(ObjectTemplatePreviewBox(
            cell: block.cell,
            x0: Double(block.dx), y0: Double(block.dy), z0: Double(block.dz),
            x1: Double(block.dx + 1), y1: Double(block.dy + 1), z1: Double(block.dz + 1)))
    }
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

public func objectTemplateBlockPalette(_ rawTemplate: ObjectTemplate,
                                       limit rawLimit: Int = 16) throws -> [ObjectTemplateBlockPaletteEntry] {
    let template = try validateTemplate(rawTemplate)
    let limit = max(0, rawLimit)
    var counts: [Int: Int] = [:]
    for block in template.blocks {
        counts[Int(block.cell >> 4), default: 0] += 1
    }
    let entries = counts.sorted {
        if $0.value != $1.value { return $0.value > $1.value }
        return blockDefs[$0.key].name < blockDefs[$1.key].name
    }.map { id, count in
        ObjectTemplateBlockPaletteEntry(
            blockName: blockDefs[id].name,
            blockDisplayName: blockDefs[id].displayName,
            count: count)
    }
    return Array(entries.prefix(limit))
}

public func isObjectTemplateWoodFamilyBlock(_ blockId: Int) -> Bool {
    guard blockId > 0, blockId < blockDefs.count else { return false }
    let name = blockDefs[blockId].name
    let woodSuffixes: Set<String> = [
        "planks", "log", "wood", "stem", "hyphae",
        "stairs", "slab", "fence", "fence_gate", "door", "trapdoor",
        "button", "pressure_plate", "sign", "wall_sign", "hanging_sign",
    ]
    if name == "bamboo_block" || name == "stripped_bamboo_block" ||
        name == "bamboo_mosaic" || name == "bamboo_mosaic_stairs" ||
        name == "bamboo_mosaic_slab" {
        return true
    }
    for wood in WOODS {
        let prefix = "\(wood)_"
        if name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count))
            if woodSuffixes.contains(suffix) { return true }
        }
        let strippedPrefix = "stripped_\(wood)_"
        if name.hasPrefix(strippedPrefix) {
            let suffix = String(name.dropFirst(strippedPrefix.count))
            if suffix == "log" || suffix == "wood" || suffix == "stem" || suffix == "hyphae" {
                return true
            }
        }
    }
    return false
}

private func templateSelectorMatches(_ selector: TemplateBlockSelector, blockId: Int) -> Bool {
    switch selector {
    case .exact(let exact):
        return blockId == Int(exact)
    case .woodFamily:
        return isObjectTemplateWoodFamilyBlock(blockId)
    }
}

private func templateSelectorDescription(_ selector: TemplateBlockSelector) -> String {
    switch selector {
    case .exact(let exact):
        let id = Int(exact)
        return id >= 0 && id < blockDefs.count ? blockDefs[id].displayName : "unknown block"
    case .woodFamily:
        return "wood-family blocks"
    }
}

public func replacingObjectTemplateBlocks(_ rawTemplate: ObjectTemplate,
                                          matching selector: TemplateBlockSelector,
                                          with replacementBlock: UInt16) throws -> ObjectTemplateReplacementResult {
    let template = try validateTemplate(rawTemplate)
    let replacementId = Int(replacementBlock)
    guard replacementId > 0, replacementId < blockDefs.count else {
        throw TemplateError.corruptTemplate("invalid replacement block id \(replacementId)")
    }

    var replaced = 0
    var replacedPositions = Set<TemplatePos>()
    let blocks = template.blocks.map { block -> TemplateBlock in
        let blockId = Int(block.cell >> 4)
        guard templateSelectorMatches(selector, blockId: blockId) else { return block }
        replaced += 1
        replacedPositions.insert(TemplatePos(x: block.dx, y: block.dy, z: block.dz))
        return TemplateBlock(dx: block.dx, dy: block.dy, dz: block.dz, cell: cell(replacementBlock))
    }
    let blockEntities = template.blockEntities.filter { be in
        !replacedPositions.contains(TemplatePos(x: be.x, y: be.y, z: be.z))
    }
    let updated = try validateTemplate(ObjectTemplate(
        version: template.version,
        name: template.name,
        anchorX: template.anchorX, anchorY: template.anchorY, anchorZ: template.anchorZ,
        sizeX: template.sizeX, sizeY: template.sizeY, sizeZ: template.sizeZ,
        blocks: blocks,
        blockEntities: blockEntities))
    return ObjectTemplateReplacementResult(
        template: updated,
        replacedBlocks: replaced,
        fromDescription: templateSelectorDescription(selector),
        toBlockName: blockDefs[replacementId].displayName)
}

private func normalizedGeneratedTemplateKind(_ raw: String) -> String {
    raw.lowercased()
        .replacingOccurrences(of: "-", with: "_")
        .replacingOccurrences(of: " ", with: "_")
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
}

private func generatedTemplateBlock(_ names: [String], fallback: UInt16) -> UInt16 {
    for name in names {
        if let id = bidOpt(name) { return id }
    }
    return fallback
}

private func generatedTemplateLength(_ requested: Int?, defaultValue: Int = 50) -> Int {
    min(OBJECT_TEMPLATE_MAX_SPAN, max(16, requested ?? defaultValue))
}

private func generatedTemplateOddWidth(for length: Int) -> Int {
    var width = min(21, max(9, length / 4))
    if width % 2 == 0 { width += 1 }
    return width
}

private func generatePirateShipTemplate(named rawName: String, requestedLength: Int?,
                                        style: String) throws -> ObjectTemplate {
    guard let name = normalizedTemplateName(rawName) else { throw TemplateError.invalidName }
    let length = generatedTemplateLength(requestedLength)
    let width = generatedTemplateOddWidth(for: length)
    let centerZ = width / 2
    let height = min(OBJECT_TEMPLATE_MAX_SPAN, max(14, length / 3 + 3))
    let hull = generatedTemplateBlock(["dark_oak_planks", "spruce_planks", "oak_planks"], fallback: B.oak_planks)
    let deck = generatedTemplateBlock(["spruce_planks", "dark_oak_planks", "oak_planks"], fallback: B.oak_planks)
    let rail = generatedTemplateBlock(["dark_oak_fence", "spruce_fence", "oak_fence"], fallback: hull)
    let mast = generatedTemplateBlock(["stripped_dark_oak_log", "dark_oak_log", "spruce_log"], fallback: hull)
    let accent = generatedTemplateBlock(["polished_blackstone_bricks", "blackstone", "deepslate_tiles"], fallback: hull)
    let sail = generatedTemplateBlock(
        style.lowercased().contains("red") ? ["red_wool", "black_wool"] : ["black_wool", "gray_wool", "dark_oak_planks"],
        fallback: hull)
    let lantern = generatedTemplateBlock(["soul_lantern", "lantern", "torch"], fallback: rail)

    var cells: [TemplatePos: UInt16] = [:]
    func put(_ x: Int, _ y: Int, _ z: Int, _ block: UInt16) {
        guard x >= 0, x < length, y >= 0, y < height, z >= 0, z < width else { return }
        cells[TemplatePos(x: x, y: y, z: z)] = cell(block)
    }
    func halfWidth(at x: Int) -> Int {
        let taper = min(x, length - 1 - x)
        let full = width / 2
        let ramp = max(1, length / 8)
        return max(1, min(full, 1 + taper * max(1, full - 1) / ramp))
    }

    for x in 0..<length {
        let hw = halfWidth(at: x)
        for z in (centerZ - hw)...(centerZ + hw) {
            let edge = abs(z - centerZ) == hw
            if edge {
                put(x, 1, z, hull)
                put(x, 2, z, rail)
            } else {
                put(x, 0, z, hull)
                if x > 1 && x < length - 2 {
                    put(x, 1, z, deck)
                }
            }
        }
        put(x, 0, centerZ, accent)
        if x < 3 || x >= length - 3 {
            for y in 2...min(height - 1, 4 + (3 - min(x, length - 1 - x))) {
                put(x, y, centerZ, hull)
            }
        }
    }

    let cabinStart = max(3, length - max(10, length / 5) - 2)
    let cabinEnd = max(cabinStart, length - 4)
    let cabinHalf = max(2, width / 4)
    for x in cabinStart...cabinEnd {
        for z in (centerZ - cabinHalf)...(centerZ + cabinHalf) {
            let wall = x == cabinStart || x == cabinEnd || z == centerZ - cabinHalf || z == centerZ + cabinHalf
            if wall {
                put(x, 3, z, hull)
                put(x, 4, z, hull)
            }
            put(x, 5, z, accent)
        }
    }

    let mastXs = [length / 3, (length * 2) / 3].filter { $0 > 4 && $0 < length - 5 }
    let mastTop = max(8, height - 2)
    for mastX in mastXs {
        for y in 2...mastTop {
            put(mastX, y, centerZ, mast)
        }
        let sailHalfZ = max(2, min(width / 2 - 1, 4))
        let sailMinY = max(4, mastTop - 8)
        let sailMaxY = max(sailMinY, mastTop - 2)
        for y in sailMinY...sailMaxY {
            let verticalInset = min(y - sailMinY, sailMaxY - y) / 2
            let half = max(1, sailHalfZ - verticalInset)
            for z in (centerZ - half)...(centerZ + half) {
                if z != centerZ || y % 2 == 0 {
                    put(mastX + 1, y, z, sail)
                }
            }
        }
        put(mastX, mastTop + 1, centerZ, lantern)
    }

    let bowspritEnd = min(length - 1, 4)
    for x in 0...bowspritEnd {
        put(x, 3 + x / 2, centerZ, mast)
    }

    let sorted = cells.keys.sorted()
    let blocks = sorted.map { pos in
        TemplateBlock(dx: pos.x, dy: pos.y, dz: pos.z, cell: cells[pos]!)
    }
    return try validateTemplate(ObjectTemplate(
        name: name,
        anchorX: length / 2,
        anchorY: 0,
        anchorZ: centerZ,
        sizeX: length,
        sizeY: height,
        sizeZ: width,
        blocks: blocks))
}

public func generatedObjectTemplate(named rawName: String, kind rawKind: String,
                                    requestedLength: Int? = nil,
                                    style: String = "") throws -> ObjectTemplate {
    let kind = normalizedGeneratedTemplateKind(rawKind)
    if kind.contains("pirate_ship") || (kind.contains("pirate") && kind.contains("ship")) ||
        kind == "ship" || kind == "boat" {
        return try generatePirateShipTemplate(named: rawName, requestedLength: requestedLength, style: style)
    }
    throw TemplateError.corruptTemplate("unsupported generated object kind \(rawKind)")
}

public func cloneObjectTemplate(named rawName: String, from world: World,
                                targetX: Int, targetY: Int, targetZ: Int,
                                options: TemplateCloneOptions = TemplateCloneOptions()) throws -> TemplateCloneResult {
    guard let name = normalizedTemplateName(rawName) else { throw TemplateError.invalidName }
    let seedCell = world.getBlock(targetX, targetY, targetZ)
    guard seedCell != 0 else { throw TemplateError.missingTarget }
    guard isTemplateCloneableBlock(seedCell) else { throw TemplateError.targetNotCloneable }

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
        for d in templateCloneNeighborDeltas {
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
        TemplateBlock(
            dx: $0.x - minX,
            dy: $0.y - minY,
            dz: $0.z - minZ,
            cell: templateCloneCellWithoutContainedItemState(cells[$0]!,
                                                             blockEntity: world.getBlockEntity($0.x, $0.y, $0.z)))
    }
    var bes: [BlockEntityData] = []
    for pos in sorted {
        if let be = world.getBlockEntity(pos.x, pos.y, pos.z),
           let copy = templateCloneBlockEntityCopy(be, minX: minX, minY: minY, minZ: minZ) {
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

private struct TemplatePlacementPreparation {
    let blocksCleared: Int
    let supportBlocksFilled: Int
}

private func validateTemplateMutableDestination(_ world: World, _ x: Int, _ y: Int, _ z: Int) throws {
    guard world.isLoadedAt(x, z), y >= world.info.minY, y < world.info.minY + world.info.height else {
        throw TemplateError.destinationUnavailable(x, y, z)
    }
    let id = world.getBlock(x, y, z) >> 4
    guard id >= 0, id < blockDefs.count else {
        throw TemplateError.destinationBlocked(x, y, z)
    }
    if id > 0 && id < blockDefs.count && blockDefs[id].hardness < 0 {
        throw TemplateError.destinationBlocked(x, y, z)
    }
}

private func isTemplateFoundationMaterial(_ cell: Int) -> Bool {
    let id = cell >> 4
    guard id > 0, id < blockDefs.count else { return false }
    let def = blockDefs[id]
    return def.solid && def.fullCube && !def.replaceable && def.hardness >= 0
}

private func normalizedFoundationCell(_ cellValue: Int) -> Int {
    let id = cellValue >> 4
    guard id > 0, id < blockDefs.count else { return Int(cell(B.dirt)) }
    return Int(cell(UInt16(id)))
}

private func adjacentFoundationCell(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> Int? {
    let deltas = [(-1, 0, 0), (1, 0, 0), (0, 0, -1), (0, 0, 1), (0, -1, 0), (0, 1, 0)]
    for d in deltas {
        let cellValue = world.getBlock(x + d.0, y + d.1, z + d.2)
        if isTemplateFoundationMaterial(cellValue) {
            return normalizedFoundationCell(cellValue)
        }
    }
    return nil
}

private func prepareObjectTemplatePlacement(_ template: ObjectTemplate, in world: World,
                                            originX: Int, originY: Int, originZ: Int) throws -> TemplatePlacementPreparation {
    var clearance: [TemplatePos] = []
    clearance.reserveCapacity(template.sizeX * template.sizeY * template.sizeZ)
    var support = Set<TemplatePos>()
    let minY = world.info.minY

    for dx in 0..<template.sizeX {
        for dz in 0..<template.sizeZ {
            let x = originX + dx
            let z = originZ + dz
            for dy in 0..<template.sizeY {
                let y = originY + dy
                try validateTemplateMutableDestination(world, x, y, z)
                clearance.append(TemplatePos(x: x, y: y, z: z))
            }

            let foundationY = originY - 1
            guard foundationY >= minY else {
                throw TemplateError.destinationUnavailable(x, foundationY, z)
            }
            let minSearchY = max(minY, foundationY - OBJECT_TEMPLATE_MAX_SUPPORT_FILL_DEPTH)
            var baseY: Int?
            var y = foundationY
            while y >= minSearchY {
                try validateTemplateMutableDestination(world, x, y, z)
                if isTemplateFoundationMaterial(world.getBlock(x, y, z)) {
                    baseY = y
                    break
                }
                y -= 1
            }
            guard let baseY else {
                throw TemplateError.foundationTooDeep(x, foundationY, z)
            }
            if baseY < foundationY {
                for fillY in (baseY + 1)...foundationY {
                    try validateTemplateMutableDestination(world, x, fillY, z)
                    support.insert(TemplatePos(x: x, y: fillY, z: z))
                }
            }
        }
    }

    var cleared = 0
    var touched = Set<TemplatePos>()
    for p in clearance.sorted() {
        if world.getBlock(p.x, p.y, p.z) != 0 {
            world.setBlock(p.x, p.y, p.z, 0, SET_NO_NEIGHBORS)
            cleared += 1
            touched.insert(p)
        }
    }

    var filled = 0
    for p in support.sorted() {
        let fillCell = adjacentFoundationCell(world, p.x, p.y, p.z) ?? Int(cell(B.dirt))
        if world.getBlock(p.x, p.y, p.z) != fillCell {
            world.setBlock(p.x, p.y, p.z, fillCell, SET_NO_NEIGHBORS)
            filled += 1
            touched.insert(p)
        }
    }

    for p in touched.sorted() {
        world.updateNeighbors(p.x, p.y, p.z)
        world.notifyBlock(p.x, p.y, p.z, p.x, p.y, p.z)
    }
    return TemplatePlacementPreparation(blocksCleared: cleared, supportBlocksFilled: filled)
}

private func objectTemplatePlacementMutationPositions(_ template: ObjectTemplate, in world: World,
                                                      originX: Int, originY: Int, originZ: Int,
                                                      options: TemplatePlacementOptions) throws -> [TemplatePos] {
    var positions = Set<TemplatePos>()
    positions.reserveCapacity(template.blocks.count)
    for block in template.blocks {
        let x = originX + block.dx
        let y = originY + block.dy
        let z = originZ + block.dz
        guard world.isLoadedAt(x, z), y >= world.info.minY, y < world.info.minY + world.info.height else {
            throw TemplateError.destinationUnavailable(x, y, z)
        }
        if !options.replaceExisting && !options.prepareTerrain && !isDestinationReplaceable(world, x, y, z) {
            throw TemplateError.destinationBlocked(x, y, z)
        }
        positions.insert(TemplatePos(x: x, y: y, z: z))
    }
    guard options.prepareTerrain else { return positions.sorted() }

    let minY = world.info.minY
    for dx in 0..<template.sizeX {
        for dz in 0..<template.sizeZ {
            let x = originX + dx
            let z = originZ + dz
            for dy in 0..<template.sizeY {
                let y = originY + dy
                try validateTemplateMutableDestination(world, x, y, z)
                if world.getBlock(x, y, z) != 0 || world.getBlockEntity(x, y, z) != nil {
                    positions.insert(TemplatePos(x: x, y: y, z: z))
                }
            }

            let foundationY = originY - 1
            guard foundationY >= minY else {
                throw TemplateError.destinationUnavailable(x, foundationY, z)
            }
            let minSearchY = max(minY, foundationY - OBJECT_TEMPLATE_MAX_SUPPORT_FILL_DEPTH)
            var baseY: Int?
            var y = foundationY
            while y >= minSearchY {
                try validateTemplateMutableDestination(world, x, y, z)
                if isTemplateFoundationMaterial(world.getBlock(x, y, z)) {
                    baseY = y
                    break
                }
                y -= 1
            }
            guard let baseY else {
                throw TemplateError.foundationTooDeep(x, foundationY, z)
            }
            if baseY < foundationY {
                for fillY in (baseY + 1)...foundationY {
                    try validateTemplateMutableDestination(world, x, fillY, z)
                    positions.insert(TemplatePos(x: x, y: fillY, z: z))
                }
            }
        }
    }
    return positions.sorted()
}

public func objectTemplatePlacementUndoSnapshot(for rawTemplate: ObjectTemplate, in world: World,
                                                targetX: Int, targetY: Int, targetZ: Int,
                                                rotationSteps: Int = 0,
                                                options: TemplatePlacementOptions = TemplatePlacementOptions()) throws -> TemplatePlacementUndoSnapshot {
    let template = try rotatedObjectTemplate(rawTemplate, rotationSteps: rotationSteps)
    let originX = targetX - template.anchorX
    let originY = targetY - template.anchorY
    let originZ = targetZ - template.anchorZ
    let positions = try objectTemplatePlacementMutationPositions(template, in: world,
                                                                 originX: originX, originY: originY, originZ: originZ,
                                                                 options: options)
    let cells = positions.map { pos -> TemplatePlacementUndoCell in
        let cellValue = world.getBlock(pos.x, pos.y, pos.z)
        let id = cellValue >> 4
        let blockEntity = id > 0 && id < blockDefs.count
            ? world.getBlockEntity(pos.x, pos.y, pos.z).flatMap(sanitizedTemplateBlockEntity)
            : nil
        return TemplatePlacementUndoCell(x: pos.x, y: pos.y, z: pos.z, cell: cellValue, blockEntity: blockEntity)
    }
    return TemplatePlacementUndoSnapshot(templateName: template.name, cells: cells)
}

@discardableResult
public func restoreObjectTemplatePlacementUndo(_ snapshot: TemplatePlacementUndoSnapshot, in world: World) -> Int {
    var restored = 0
    var touched: [TemplatePos] = []
    touched.reserveCapacity(snapshot.cells.count)
    for cell in snapshot.cells {
        _ = world.setBlock(cell.x, cell.y, cell.z, cell.cell, SET_NO_NEIGHBORS)
        if let blockEntity = cell.blockEntity,
           let copy = sanitizedTemplateBlockEntity(blockEntity) {
            copy.x = cell.x
            copy.y = cell.y
            copy.z = cell.z
            world.setBlockEntity(copy)
        } else {
            world.removeBlockEntity(cell.x, cell.y, cell.z)
        }
        touched.append(TemplatePos(x: cell.x, y: cell.y, z: cell.z))
        restored += 1
    }
    for p in touched.sorted() {
        world.updateNeighbors(p.x, p.y, p.z)
        world.notifyBlock(p.x, p.y, p.z, p.x, p.y, p.z)
    }
    return restored
}

public func placeObjectTemplate(_ rawTemplate: ObjectTemplate, in world: World,
                                targetX: Int, targetY: Int, targetZ: Int,
                                rotationSteps: Int = 0,
                                options: TemplatePlacementOptions = TemplatePlacementOptions()) throws -> TemplatePlacementResult {
    let template = try rotatedObjectTemplate(rawTemplate, rotationSteps: rotationSteps)
    let originX = targetX - template.anchorX
    let originY = targetY - template.anchorY
    let originZ = targetZ - template.anchorZ
    let preparation: TemplatePlacementPreparation
    if options.prepareTerrain {
        preparation = try prepareObjectTemplatePlacement(template, in: world,
                                                         originX: originX, originY: originY, originZ: originZ)
    } else {
        preparation = TemplatePlacementPreparation(blocksCleared: 0, supportBlocksFilled: 0)
    }

    for block in template.blocks {
        let x = originX + block.dx
        let y = originY + block.dy
        let z = originZ + block.dz
        guard world.isLoadedAt(x, z), y >= world.info.minY, y < world.info.minY + world.info.height else {
            throw TemplateError.destinationUnavailable(x, y, z)
        }
        if !options.replaceExisting && !options.prepareTerrain && !isDestinationReplaceable(world, x, y, z) {
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
                                   blocksPlaced: template.blocks.count, blockEntitiesPlaced: placedBEs,
                                   blocksCleared: preparation.blocksCleared,
                                   supportBlocksFilled: preparation.supportBlocksFilled)
}
