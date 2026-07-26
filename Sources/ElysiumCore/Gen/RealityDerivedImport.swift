import Darwin
import Foundation

public let REALITY_EXCHANGE_FORMAT = "elysium-reality-exchange"
public let REALITY_EXCHANGE_VERSION = 3
public let REALITY_DERIVED_TRANSITION_BLOCKS = 64
public let REALITY_DERIVED_MAX_PHYSICAL_AREA_SQUARE_METRES: Double = 250_000_000
public let REALITY_DERIVED_MAX_PROJECTED_BLOCK_COLUMNS: Double = 250_000_000
public let REALITY_DERIVED_MAX_IMPORTED_CHUNKS = 1_000_000
public let REALITY_DERIVED_MAX_TOTAL_CHUNKS = 1_048_576

public struct RealityDerivedWorldSource: Codable, Equatable {
    public var generator: String
    public var minLatitude: Double
    public var maxLatitude: Double
    public var minLongitude: Double
    public var maxLongitude: Double
    public var projection: String
    public var scale: Double
    public var importedChunkCount: Int

    public init(generator: String, minLatitude: Double, maxLatitude: Double,
                minLongitude: Double, maxLongitude: Double, projection: String,
                scale: Double, importedChunkCount: Int) {
        self.generator = generator
        self.minLatitude = minLatitude
        self.maxLatitude = maxLatitude
        self.minLongitude = minLongitude
        self.maxLongitude = maxLongitude
        self.projection = projection
        self.scale = scale
        self.importedChunkCount = importedChunkCount
    }
}

public enum RealityDerivedImportError: Error, LocalizedError, Equatable {
    case invalidDirectory
    case missingManifest
    case invalidManifest
    case unsupportedFormat
    case limitExceeded(String)
    case invalidChunk(String)
    case unsupportedBlock(String)
    case cancelled
    case storageFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDirectory: return "The Reality Derived output directory is invalid."
        case .missingManifest: return "Arnis did not finish writing this map."
        case .invalidManifest: return "The Reality Derived manifest is malformed."
        case .unsupportedFormat: return "This Reality Derived map format is not supported."
        case .limitExceeded(let detail): return "The Reality Derived map exceeds the safe \(detail) limit."
        case .invalidChunk(let name): return "Reality Derived chunk \(name) is malformed."
        case .unsupportedBlock(let name): return "Reality Derived block \(name) is invalid."
        case .cancelled: return "Reality Derived map creation was cancelled."
        case .storageFailed: return "Elysium could not save the Reality Derived world."
        }
    }
}

public func makeRealityDerivedWorldIdentifier() -> String {
    "wr" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
}

private struct RealityExchangeBlock: Decodable {
    let id: UInt16
    let name: String
}

private struct RealityExchangeManifest: Decodable {
    let format: String
    let version: Int
    let complete: Bool
    let generator: String
    let chunkCount: Int
    let minChunkX: Int32
    let maxChunkX: Int32
    let minChunkZ: Int32
    let maxChunkZ: Int32
    let minGeoLat: Double
    let maxGeoLat: Double
    let minGeoLon: Double
    let maxGeoLon: Double
    let projection: String
    let scale: Double
    let spawnX: Int32
    let spawnY: Int32
    let spawnZ: Int32
    let streamBytes: UInt64
    let blocks: [RealityExchangeBlock]
}

private enum RealityExchangeLimits {
    static let manifestBytes = 1_048_576
    static let chunkBytes = 2_097_152
    static let palette = 512
    static let propertyBytes = 16_384
    static let totalPropertyBytes = 1_048_576
    static let projectionBytes = 2_048
    static let generatorBytes = 256
}

private func realityReadRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let fd = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
    guard fd >= 0 else { throw RealityDerivedImportError.invalidDirectory }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
          before.st_size >= 0, before.st_size <= maximumBytes else {
        throw RealityDerivedImportError.limitExceeded("file size")
    }
    var result = Data(count: Int(before.st_size))
    var offset = 0
    let resultCount = result.count
    try result.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        while offset < resultCount {
            let count = read(fd, base.advanced(by: offset), resultCount - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RealityDerivedImportError.invalidDirectory }
            offset += count
        }
    }
    var after = stat()
    guard fstat(fd, &after) == 0, before.st_dev == after.st_dev,
          before.st_ino == after.st_ino, before.st_size == after.st_size else {
        throw RealityDerivedImportError.invalidDirectory
    }
    return result
}

private struct RealityDataReader {
    let data: Data
    var offset = 0

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw RealityDerivedImportError.invalidManifest
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
    mutating func u8() throws -> UInt8 { try bytes(1)[0] }
    mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
}

private final class RealityStreamReader {
    private let fd: Int32
    private let initial: stat
    private var consumed: UInt64 = 0

    init(url: URL, expectedBytes: UInt64) throws {
        fd = url.path.withCString { open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW) }
        guard fd >= 0 else { throw RealityDerivedImportError.invalidDirectory }
        var value = stat()
        guard fstat(fd, &value) == 0, (value.st_mode & S_IFMT) == S_IFREG,
              value.st_size >= 0, UInt64(value.st_size) == expectedBytes else {
            close(fd)
            throw RealityDerivedImportError.invalidDirectory
        }
        initial = value
    }

    deinit { close(fd) }

    func readExactly(_ count: Int) throws -> Data {
        guard count >= 0, UInt64(count) <= UInt64.max - consumed,
              consumed + UInt64(count) <= UInt64(initial.st_size) else {
            throw RealityDerivedImportError.invalidManifest
        }
        var data = Data(count: count)
        var offset = 0
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < count {
                let amount = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw RealityDerivedImportError.invalidDirectory }
                offset += amount
            }
        }
        consumed += UInt64(count)
        return data
    }

    func u32() throws -> UInt32 {
        let b = try readExactly(4)
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }

    func verifyFinished() throws {
        guard consumed == UInt64(initial.st_size) else { throw RealityDerivedImportError.invalidManifest }
        var current = stat()
        guard fstat(fd, &current) == 0, current.st_dev == initial.st_dev,
              current.st_ino == initial.st_ino, current.st_size == initial.st_size else {
            throw RealityDerivedImportError.invalidDirectory
        }
    }
}

private func realityCanonicalBlockName(_ raw: String) throws -> String {
    let name = raw.hasPrefix("minecraft:") ? String(raw.dropFirst("minecraft:".count)) : raw
    guard !name.isEmpty, name.utf8.count <= 64,
          name.utf8.allSatisfy({ ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 95 }) else {
        throw RealityDerivedImportError.unsupportedBlock(raw)
    }
    return name
}

private func realityUnwrappedString(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let text = value as? String { return text }
    if let dictionary = value as? [String: Any] {
        for wrapper in ["String", "string", "value"] {
            if let text = dictionary[wrapper] as? String { return text }
        }
    }
    return nil
}

private func realityString(_ value: Any?, key: String) -> String? {
    guard let dictionary = value as? [String: Any] else { return nil }
    if let direct = realityUnwrappedString(dictionary[key]) { return direct }
    for nested in dictionary.values {
        if nested is [String: Any], let found = realityString(nested, key: key) { return found }
    }
    return nil
}

private func realityBool(_ value: Any?, key: String) -> Bool {
    guard let text = realityString(value, key: key)?.lowercased() else { return false }
    return text == "true" || text == "1"
}

private func realityFacing(_ properties: Any?) -> Int {
    switch realityString(properties, key: "facing")?.lowercased() {
    case "north": return 0
    case "south": return 1
    case "west": return 2
    case "east": return 3
    default: return 0
    }
}

private func realityMeta(blockID: UInt16, name: String, properties: Any?) -> UInt16 {
    let shape = Shape(rawValue: SHAPE_OF[Int(blockID)]) ?? .cube
    let facing = realityFacing(properties)
    switch shape {
    case .stairs: return UInt16(facing | (realityString(properties, key: "half") == "top" ? 4 : 0))
    case .slab: return realityString(properties, key: "type") == "top" ? 1 : 0
    case .door:
        if realityString(properties, key: "half") == "upper" {
            return UInt16(8 | (realityString(properties, key: "hinge") == "right" ? 1 : 0))
        }
        return UInt16(facing | (realityBool(properties, key: "open") ? 4 : 0))
    case .trapdoor:
        return UInt16(facing | (realityBool(properties, key: "open") ? 4 : 0)
            | (realityString(properties, key: "half") == "top" ? 8 : 0))
    case .fenceGate: return UInt16(facing | (realityBool(properties, key: "open") ? 4 : 0))
    case .ladder, .wallSign, .chest, .repeater, .comparator, .campfire: return UInt16(facing)
    case .rail: return (realityString(properties, key: "shape") ?? "").contains("east_west") ? 1 : 0
    default:
        if name.hasSuffix("_log") || name.hasSuffix("_wood") || name.hasSuffix("_stem")
            || name.contains("hyphae") || name.contains("basalt") || name == "bone_block"
            || name == "chain" || name.hasSuffix("_pillar") || name == "bamboo_block" {
            switch realityString(properties, key: "axis") {
            case "x": return 1
            case "z": return 2
            default: return 0
            }
        }
        return 0
    }
}

private func realityResolvedBlock(_ name: String) -> (UInt16, String?) {
    if name == "air" || name == "cave_air" || name == "void_air" { return (B.air, nil) }
    if let exact = bidOpt(name) { return (exact, nil) }
    let aliases = ["grass": "short_grass", "grass_path": "dirt_path",
                   "brick_block": "bricks", "snow": "snow_block"]
    if let alias = aliases[name], let id = bidOpt(alias) { return (id, nil) }
    return (B.stone, name)
}

private func realityValidateManifest(_ manifest: RealityExchangeManifest) throws -> (width: Int, depth: Int, transition: Int) {
    guard manifest.format == REALITY_EXCHANGE_FORMAT,
          manifest.version == REALITY_EXCHANGE_VERSION else { throw RealityDerivedImportError.unsupportedFormat }
    guard manifest.complete, manifest.chunkCount > 0,
          manifest.chunkCount <= REALITY_DERIVED_MAX_IMPORTED_CHUNKS,
          manifest.blocks.count <= RealityExchangeLimits.palette,
          manifest.minChunkX <= manifest.maxChunkX, manifest.minChunkZ <= manifest.maxChunkZ,
          !manifest.generator.isEmpty, manifest.generator.utf8.count <= RealityExchangeLimits.generatorBytes,
          !manifest.projection.isEmpty, manifest.projection.utf8.count <= RealityExchangeLimits.projectionBytes,
          manifest.scale.isFinite, (0.5...3).contains(manifest.scale), manifest.streamBytes >= 12,
          manifest.minGeoLat.isFinite, manifest.maxGeoLat.isFinite,
          manifest.minGeoLon.isFinite, manifest.maxGeoLon.isFinite,
          manifest.minGeoLat >= -90, manifest.maxGeoLat <= 90,
          manifest.minGeoLon >= -180, manifest.maxGeoLon <= 180,
          manifest.minGeoLat < manifest.maxGeoLat, manifest.minGeoLon < manifest.maxGeoLon,
          manifest.spawnY >= Int32(GEN_MIN_Y + 1), manifest.spawnY < Int32(GEN_MIN_Y + WORLD_H - 1) else {
        throw RealityDerivedImportError.invalidManifest
    }
    let middleLatitude = (manifest.minGeoLat + manifest.maxGeoLat) * 0.5 * .pi / 180
    let physicalHeight = (manifest.maxGeoLat - manifest.minGeoLat) * 111_320
    let physicalWidth = (manifest.maxGeoLon - manifest.minGeoLon) * 111_320
        * max(0.01, cos(middleLatitude))
    guard physicalWidth * physicalHeight <= REALITY_DERIVED_MAX_PHYSICAL_AREA_SQUARE_METRES,
          manifest.streamBytes <= 12 + UInt64(manifest.chunkCount)
            * UInt64(4 + RealityExchangeLimits.chunkBytes) else {
        throw RealityDerivedImportError.limitExceeded("Arnis capacity")
    }
    let width64 = Int64(manifest.maxChunkX) - Int64(manifest.minChunkX) + 1
    let depth64 = Int64(manifest.maxChunkZ) - Int64(manifest.minChunkZ) + 1
    guard width64 > 0, depth64 > 0, width64 <= Int64(Int.max), depth64 <= Int64(Int.max),
          width64.multipliedReportingOverflow(by: depth64).overflow == false,
          width64 * depth64 == Int64(manifest.chunkCount) else { throw RealityDerivedImportError.invalidManifest }
    let width = Int(width64), depth = Int(depth64)
    let collar = (REALITY_DERIVED_TRANSITION_BLOCKS + 15) / 16
    let expanded = (width + collar * 2).multipliedReportingOverflow(by: depth + collar * 2)
    guard !expanded.overflow else { throw RealityDerivedImportError.limitExceeded("chunk count") }
    let transition = expanded.partialValue - manifest.chunkCount
    guard transition >= 0, manifest.chunkCount + transition <= REALITY_DERIVED_MAX_TOTAL_CHUNKS else {
        throw RealityDerivedImportError.limitExceeded("chunk count")
    }
    return (width, depth, transition)
}

/// A validated, single-use streaming import description. It retains only manifest/palette data;
/// chunk payloads are decoded and committed one at a time by `SaveDB`.
public final class RealityDerivedImportPlan {
    public let worldID: String
    public let source: RealityDerivedWorldSource
    public let spawnX: Int
    public let spawnY: Int
    public let spawnZ: Int
    public let importedChunkCount: Int
    public let transitionChunkCount: Int
    public var totalChunkCount: Int { importedChunkCount + transitionChunkCount }
    public var importedWidthBlocks: Int { width * 16 }
    public var importedDepthBlocks: Int { depth * 16 }
    public let mapCenterX: Int
    public let mapCenterZ: Int

    fileprivate let directory: URL
    fileprivate let manifest: RealityExchangeManifest
    fileprivate let palette: [UInt16: (value: UInt16, name: String)]
    fileprivate let width: Int
    fileprivate let depth: Int
    private let lock = NSLock()
    private var consumed = false

    fileprivate init(directory: URL, worldID: String, manifest: RealityExchangeManifest,
                     palette: [UInt16: (value: UInt16, name: String)],
                     width: Int, depth: Int, transition: Int) {
        self.directory = directory
        self.worldID = worldID
        self.manifest = manifest
        self.palette = palette
        self.width = width
        self.depth = depth
        importedChunkCount = manifest.chunkCount
        transitionChunkCount = transition
        spawnX = Int(manifest.spawnX)
        spawnY = Int(manifest.spawnY)
        spawnZ = Int(manifest.spawnZ)
        mapCenterX = (Int(manifest.minChunkX) * 16 + (Int(manifest.maxChunkX) + 1) * 16 - 1) / 2
        mapCenterZ = (Int(manifest.minChunkZ) * 16 + (Int(manifest.maxChunkZ) + 1) * 16 - 1) / 2
        source = RealityDerivedWorldSource(
            generator: manifest.generator, minLatitude: manifest.minGeoLat,
            maxLatitude: manifest.maxGeoLat, minLongitude: manifest.minGeoLon,
            maxLongitude: manifest.maxGeoLon, projection: manifest.projection,
            scale: manifest.scale, importedChunkCount: manifest.chunkCount)
    }

    fileprivate func claim() throws {
        lock.lock(); defer { lock.unlock() }
        guard !consumed else { throw RealityDerivedImportError.invalidManifest }
        consumed = true
    }
}

public func makeRealityDerivedImportPlan(at directory: URL, worldID: String) throws -> RealityDerivedImportPlan {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
          isDirectory.boolValue,
          (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
        throw RealityDerivedImportError.invalidDirectory
    }
    let manifestURL = directory.appendingPathComponent("manifest.json")
    guard FileManager.default.fileExists(atPath: manifestURL.path) else {
        throw RealityDerivedImportError.missingManifest
    }
    let data = try realityReadRegularFile(manifestURL, maximumBytes: RealityExchangeLimits.manifestBytes)
    let manifest: RealityExchangeManifest
    do { manifest = try JSONDecoder().decode(RealityExchangeManifest.self, from: data) }
    catch { throw RealityDerivedImportError.invalidManifest }
    let dimensions = try realityValidateManifest(manifest)
    var palette: [UInt16: (value: UInt16, name: String)] = [:]
    for block in manifest.blocks {
        let name = try realityCanonicalBlockName(block.name)
        guard palette[block.id] == nil else { throw RealityDerivedImportError.invalidManifest }
        palette[block.id] = (realityResolvedBlock(name).0, name)
    }
    // Open once during preflight to reject links/size mismatches before a database transaction.
    let stream = try RealityStreamReader(
        url: directory.appendingPathComponent("chunks.elxstream"), expectedBytes: manifest.streamBytes)
    guard try stream.readExactly(8) == Data("ELEXSTR3".utf8),
          try stream.u32() == UInt32(manifest.chunkCount) else {
        throw RealityDerivedImportError.invalidManifest
    }
    return RealityDerivedImportPlan(
        directory: directory, worldID: worldID, manifest: manifest, palette: palette,
        width: dimensions.width, depth: dimensions.depth, transition: dimensions.transition)
}

struct RealityDerivedChunkBlob {
    let cx: Int
    let cz: Int
    let data: Data
}

final class RealityDerivedChunkStream {
    private let plan: RealityDerivedImportPlan
    private let reader: RealityStreamReader
    private let seed: UInt32
    private let settings: WorldGenerationSettings
    private let progress: (Int, Int) -> Void
    private let cancelled: () -> Bool
    private var importedIndex = 0
    private var emitted = 0
    private var transitionCX: Int
    private var transitionCZ: Int
    private var finished = false
    private var west: [Int16]
    private var east: [Int16]
    private var north: [Int16]
    private var south: [Int16]

    init(plan: RealityDerivedImportPlan, seed: UInt32, settings: WorldGenerationSettings,
         progress: @escaping (Int, Int) -> Void, cancelled: @escaping () -> Bool) throws {
        try plan.claim()
        self.plan = plan
        self.seed = seed
        self.settings = settings
        self.progress = progress
        self.cancelled = cancelled
        reader = try RealityStreamReader(
            url: plan.directory.appendingPathComponent("chunks.elxstream"),
            expectedBytes: plan.manifest.streamBytes)
        guard try reader.readExactly(8) == Data("ELEXSTR3".utf8),
              try reader.u32() == UInt32(plan.importedChunkCount) else {
            throw RealityDerivedImportError.invalidManifest
        }
        let collar = (REALITY_DERIVED_TRANSITION_BLOCKS + 15) / 16
        transitionCX = Int(plan.manifest.minChunkX) - collar
        transitionCZ = Int(plan.manifest.minChunkZ) - collar
        west = [Int16](repeating: .min, count: plan.depth * 16)
        east = [Int16](repeating: .min, count: plan.depth * 16)
        north = [Int16](repeating: .min, count: plan.width * 16)
        south = [Int16](repeating: .min, count: plan.width * 16)
    }

    func next() throws -> RealityDerivedChunkBlob? {
        guard !finished else { return nil }
        if cancelled() { throw RealityDerivedImportError.cancelled }
        let blob: RealityDerivedChunkBlob?
        if importedIndex < plan.importedChunkCount {
            blob = try nextImported()
        } else {
            blob = try nextTransition()
        }
        if let blob {
            emitted += 1
            if emitted == 1 || emitted == plan.totalChunkCount || emitted % 64 == 0 {
                progress(emitted, plan.totalChunkCount)
            }
            return blob
        }
        guard emitted == plan.totalChunkCount else { throw RealityDerivedImportError.invalidManifest }
        try reader.verifyFinished()
        finished = true
        return nil
    }

    private func nextImported() throws -> RealityDerivedChunkBlob {
        let length = Int(try reader.u32())
        guard length > 0, length <= RealityExchangeLimits.chunkBytes else {
            throw RealityDerivedImportError.limitExceeded("chunk payload")
        }
        var payload = RealityDataReader(data: try reader.readExactly(length))
        let expectedCX = Int(plan.manifest.minChunkX) + importedIndex / plan.depth
        let expectedCZ = Int(plan.manifest.minChunkZ) + importedIndex % plan.depth
        let cx = Int(try payload.i32()), cz = Int(try payload.i32())
        guard cx == expectedCX, cz == expectedCZ else {
            throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)")
        }
        let sectionCount = Int(try payload.u16())
        guard sectionCount <= 24 else { throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)") }
        var sections: [CompactChunkSectionV2] = []
        var priorSection: Int8?
        for _ in 0..<sectionCount {
            let sectionY = try payload.i8()
            guard sectionY >= -4, sectionY <= 19, priorSection.map({ $0 < sectionY }) ?? true else {
                throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)")
            }
            priorSection = sectionY
            let runCount = Int(try payload.u16())
            guard (1...4096).contains(runCount) else {
                throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)")
            }
            var runs: [CompactChunkRunV2] = []
            var flat = 0
            for _ in 0..<runCount {
                let length = Int(try payload.u16())
                let sourceID = try payload.u16()
                guard length > 0, flat <= 4096 - length, let mapped = plan.palette[sourceID] else {
                    throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)")
                }
                let value = mapped.value << 4
                if let last = runs.last, last.value == value,
                   Int(last.length) <= Int(UInt16.max) - length {
                    runs[runs.count - 1].length += UInt16(length)
                } else {
                    runs.append(CompactChunkRunV2(length: UInt16(length), value: value))
                }
                flat += length
            }
            guard flat == 4096 else { throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)") }
            let propertyCount = Int(try payload.u16())
            guard propertyCount <= 4096 else { throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)") }
            if propertyCount > 0 {
                var expanded: [UInt16] = []
                expanded.reserveCapacity(4096)
                for run in runs { expanded.append(contentsOf: repeatElement(run.value, count: Int(run.length))) }
                var seen = Set<Int>()
                var totalPropertyBytes = 0
                for _ in 0..<propertyCount {
                    let index = Int(try payload.u16())
                    let jsonLength = Int(try payload.u32())
                    guard index < 4096, seen.insert(index).inserted, jsonLength > 0,
                          jsonLength <= RealityExchangeLimits.propertyBytes,
                          totalPropertyBytes <= RealityExchangeLimits.totalPropertyBytes - jsonLength else {
                        throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)")
                    }
                    totalPropertyBytes += jsonLength
                    let json = try payload.bytes(jsonLength)
                    guard let value = try? JSONSerialization.jsonObject(with: json),
                          JSONSerialization.isValidJSONObject(value) else {
                        throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)")
                    }
                    let blockID = expanded[index] >> 4
                    expanded[index] = (blockID << 4) | realityMeta(
                        blockID: blockID, name: blockName(Int(blockID)), properties: value)
                }
                runs.removeAll(keepingCapacity: true)
                var current = expanded[0], count = 1
                for value in expanded.dropFirst() {
                    if value == current { count += 1 }
                    else {
                        runs.append(CompactChunkRunV2(length: UInt16(count), value: current))
                        current = value; count = 1
                    }
                }
                runs.append(CompactChunkRunV2(length: UInt16(count), value: current))
            }
            if runs.count != 1 || runs[0].value != 0 {
                sections.append(CompactChunkSectionV2(y: sectionY, runs: runs))
            }
        }
        var heights: [Int16] = []
        heights.reserveCapacity(256)
        for _ in 0..<256 {
            let height = try payload.i16()
            guard height >= Int16(GEN_MIN_Y), height < Int16(GEN_MIN_Y + WORLD_H) else {
                throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)")
            }
            heights.append(height)
        }
        guard payload.offset == payload.data.count else {
            throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)")
        }
        captureBoundaryHeights(cx: cx, cz: cz, heights: heights)
        let biomes = [UInt8](repeating: UInt8(Biome.plains.rawValue),
                             count: 4 * 4 * ((WORLD_H + 3) / 4))
        guard let data = encodeCompactVCK2(dimension: Dim.overworld.rawValue,
                                           sections: sections, biomes: biomes) else {
            throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)")
        }
        importedIndex += 1
        return RealityDerivedChunkBlob(cx: cx, cz: cz, data: data)
    }

    private func captureBoundaryHeights(cx: Int, cz: Int, heights: [Int16]) {
        let minCX = Int(plan.manifest.minChunkX), maxCX = Int(plan.manifest.maxChunkX)
        let minCZ = Int(plan.manifest.minChunkZ), maxCZ = Int(plan.manifest.maxChunkZ)
        if cx == minCX || cx == maxCX {
            let offset = (cz - minCZ) * 16
            for z in 0..<16 {
                if cx == minCX { west[offset + z] = heights[z * 16] }
                if cx == maxCX { east[offset + z] = heights[z * 16 + 15] }
            }
        }
        if cz == minCZ || cz == maxCZ {
            let offset = (cx - minCX) * 16
            for x in 0..<16 {
                if cz == minCZ { north[offset + x] = heights[x] }
                if cz == maxCZ { south[offset + x] = heights[15 * 16 + x] }
            }
        }
    }

    private func nextTransition() throws -> RealityDerivedChunkBlob? {
        let collar = (REALITY_DERIVED_TRANSITION_BLOCKS + 15) / 16
        let minCX = Int(plan.manifest.minChunkX), maxCX = Int(plan.manifest.maxChunkX)
        let minCZ = Int(plan.manifest.minChunkZ), maxCZ = Int(plan.manifest.maxChunkZ)
        let finalCX = maxCX + collar, finalCZ = maxCZ + collar
        while transitionCX <= finalCX {
            let cx = transitionCX, cz = transitionCZ
            transitionCZ += 1
            if transitionCZ > finalCZ { transitionCZ = minCZ - collar; transitionCX += 1 }
            if cx >= minCX, cx <= maxCX, cz >= minCZ, cz <= maxCZ { continue }
            return try makeTransition(cx: cx, cz: cz)
        }
        return nil
    }

    private func edgeHeight(worldX: Int, worldZ: Int) throws -> Int {
        let minX = Int(plan.manifest.minChunkX) * 16
        let maxX = (Int(plan.manifest.maxChunkX) + 1) * 16 - 1
        let minZ = Int(plan.manifest.minChunkZ) * 16
        let maxZ = (Int(plan.manifest.maxChunkZ) + 1) * 16 - 1
        let x = min(max(worldX, minX), maxX), z = min(max(worldZ, minZ), maxZ)
        let value: Int16
        if worldZ < minZ { value = north[x - minX] }
        else if worldZ > maxZ { value = south[x - minX] }
        else if worldX < minX { value = west[z - minZ] }
        else { value = east[z - minZ] }
        guard value != .min else { throw RealityDerivedImportError.invalidManifest }
        return Int(value)
    }

    private func makeTransition(cx: Int, cz: Int) throws -> RealityDerivedChunkBlob {
        let importedMinX = Int(plan.manifest.minChunkX) * 16
        let importedMaxX = (Int(plan.manifest.maxChunkX) + 1) * 16 - 1
        let importedMinZ = Int(plan.manifest.minChunkZ) * 16
        let importedMaxZ = (Int(plan.manifest.maxChunkZ) + 1) * 16 - 1
        let base = buildBaseTerrainChunk(seed: seed, cx: cx, cz: cz, settings: settings)
        var shifted = [UInt16](repeating: 0, count: base.blocks.count)
        for localZ in 0..<16 {
            for localX in 0..<16 {
                let worldX = cx * 16 + localX, worldZ = cz * 16 + localZ
                let dx = worldX < importedMinX ? importedMinX - worldX
                    : (worldX > importedMaxX ? worldX - importedMaxX : 0)
                let dz = worldZ < importedMinZ ? importedMinZ - worldZ
                    : (worldZ > importedMaxZ ? worldZ - importedMaxZ : 0)
                let distance = max(dx, dz)
                guard distance >= 1, distance <= REALITY_DERIVED_TRANSITION_BLOCKS,
                      let normalTop = base.topSolidY(worldX: worldX, worldZ: worldZ) else {
                    throw RealityDerivedImportError.invalidManifest
                }
                let linear = Double(distance) / Double(REALITY_DERIVED_TRANSITION_BLOCKS)
                let blend = linear * linear * (3 - 2 * linear)
                let importedTop = try edgeHeight(worldX: worldX, worldZ: worldZ)
                let targetTop = Int((Double(importedTop) * (1 - blend) + Double(normalTop) * blend).rounded())
                let delta = targetTop - normalTop
                for y in GEN_MIN_Y..<(GEN_MIN_Y + WORLD_H) {
                    let sourceY = y - delta
                    let target = ((y - GEN_MIN_Y) * 16 + localZ) * 16 + localX
                    if sourceY >= GEN_MIN_Y, sourceY < GEN_MIN_Y + WORLD_H {
                        shifted[target] = base.blocks[((sourceY - GEN_MIN_Y) * 16 + localZ) * 16 + localX]
                    } else if sourceY < GEN_MIN_Y { shifted[target] = B.stone << 4 }
                }
            }
        }
        let record = ChunkRecord(
            key: "\(plan.worldID):0:\(cx),\(cz)", worldId: plan.worldID,
            dim: Dim.overworld.rawValue, cx: cx, cz: cz, blocks: shifted, biomes: base.biomes)
        guard let data = encodeCompactVCK2(record) else {
            throw RealityDerivedImportError.invalidChunk("\(cx),\(cz)")
        }
        return RealityDerivedChunkBlob(cx: cx, cz: cz, data: data)
    }
}
