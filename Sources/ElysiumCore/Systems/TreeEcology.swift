// Natural-tree provenance and bounded, host-owned forest renewal. Provenance is
// deliberately separate from block metadata: an oak beam is not a living tree.
import Foundation

public struct NaturalTreeOrigin: Hashable, Codable, Comparable, Sendable {
    public var x: Int
    public var y: Int
    public var z: Int
    public init(x: Int, y: Int, z: Int) { self.x = x; self.y = y; self.z = z }
    public static func < (a: Self, b: Self) -> Bool {
        if a.x != b.x { return a.x < b.x }
        if a.z != b.z { return a.z < b.z }
        return a.y < b.y
    }
}

public struct NaturalTreeCell: Codable, Equatable, Sendable {
    public var origin: NaturalTreeOrigin
    public var expected: UInt16
    public var decayStartTick: Int?
    public init(origin: NaturalTreeOrigin, expected: UInt16, decayStartTick: Int? = nil) {
        self.origin = origin; self.expected = expected; self.decayStartTick = decayStartTick
    }
}

public enum NaturalTreePersistence {
    private struct Entry: Codable { let index: Int; let record: NaturalTreeCell }
    public static func encode(_ records: [Int: NaturalTreeCell]) -> String? {
        guard !records.isEmpty else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let entries = records.keys.sorted().compactMap { index in
            records[index].map { Entry(index: index, record: $0) }
        }
        guard let bytes = try? encoder.encode(entries), bytes.count <= 16_777_216 else { return nil }
        return String(data: bytes, encoding: .utf8)
    }
    public static func decode(_ text: String, height: Int) -> [Int: NaturalTreeCell] {
        guard text.utf8.count <= 16_777_216, height > 0, height <= 4096,
              let bytes = text.data(using: .utf8),
              let entries = try? JSONDecoder().decode([Entry].self, from: bytes),
              entries.count <= CHUNK_W * CHUNK_W * height else { return [:] }
        var result: [Int: NaturalTreeCell] = [:]
        for entry in entries {
            let r = entry.record
            guard entry.index >= 0, entry.index < CHUNK_W * CHUNK_W * height,
                  (-30_000_000...30_000_000).contains(r.origin.x),
                  (-30_000_000...30_000_000).contains(r.origin.z),
                  r.origin.y >= -4096, r.origin.y <= 4096,
                  TreeEcologyRuntime.isTreeCell(r.expected),
                  r.decayStartTick.map({ $0 >= 0 && $0 <= Int.max - DAY_LENGTH }) ?? true,
                  result[entry.index] == nil else { return [:] }
            result[entry.index] = r
        }
        return result
    }
}

/// A transparent wrapper around an existing generation sink. It consumes no
/// random numbers and does not change generated block cells or clipping rules.
final class NaturalTreeSink: ChunkSink {
    let base: ChunkSink
    let origin: NaturalTreeOrigin
    init(_ base: ChunkSink, x: Int, y: Int, z: Int) {
        self.base = base; origin = NaturalTreeOrigin(x: x, y: y, z: z)
    }
    var cx: Int { base.cx }; var cz: Int { base.cz }
    var minY: Int { base.minY }; var maxY: Int { base.maxY }
    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        if TreeEcologyRuntime.isTreeCell(c) {
            base.setNaturalTreeCell(x, y, z, c, origin: origin)
        } else { base.set(x, y, z, c) }
    }
    func get(_ x: Int, _ y: Int, _ z: Int) -> Int { base.get(x, y, z) }
    func topY(_ x: Int, _ z: Int) -> Int { base.topY(x, z) }
    func hasBlockEntity(_ x: Int, _ y: Int, _ z: Int) -> Bool { base.hasBlockEntity(x, y, z) }
    func addBlockEntity(_ spec: BESpec) { base.addBlockEntity(spec) }
    func addEntity(_ spec: EntitySpec) { base.addEntity(spec) }
}

public final class TreeEcologyRuntime {
    private var pending = Set<NaturalTreeOrigin>()
    private var active = Set<NaturalTreeOrigin>()
    private var internalMutation = false
    private var lastTick = -1
    private var activeCursor = 0
    private var pendingCursor = 0
    private var positionsByOrigin: [NaturalTreeOrigin: Set<CellPosition>] = [:]
    private var originsByChunk: [Int64: Set<NaturalTreeOrigin>] = [:]
    private var protectedOversizedOrigins = Set<NaturalTreeOrigin>()
    private static let inspectionBudget = 8
    private static let mutationBudget = 256
    private static let maxCellsPerTree = 8192

    public init() {}
    public func unload(chunk: Chunk) {
        let key = chunkKey(chunk.cx, chunk.cz)
        let origins = originsByChunk.removeValue(forKey: key) ?? []
        pending.subtract(origins)
        active.subtract(origins)
        protectedOversizedOrigins.subtract(origins)
        for origin in origins {
            positionsByOrigin[origin] = positionsByOrigin[origin]?.filter {
                floorDiv($0.x, 16) != chunk.cx || floorDiv($0.z, 16) != chunk.cz
            }
            if positionsByOrigin[origin]?.isEmpty == true { positionsByOrigin.removeValue(forKey: origin) }
        }
    }
    private static func name(_ cell: UInt16) -> String {
        let id = Int(cell >> 4)
        return id > 0 && id < blockDefs.count ? blockDefs[id].name : ""
    }
    static func isWood(_ cell: UInt16) -> Bool {
        let n = name(cell)
        return (!n.hasPrefix("stripped_") && n.hasSuffix("_log"))
            || n == "mangrove_roots" || n == "muddy_mangrove_roots"
    }
    static func isLeaf(_ cell: UInt16) -> Bool { name(cell).hasSuffix("_leaves") }
    public static func isTreeCell(_ cell: UInt16) -> Bool { isWood(cell) || isLeaf(cell) }

    public func adopt(chunk: Chunk, in world: World) {
        guard !world.isTransientLANClient else { return }
        unload(chunk: chunk)
        let key = chunkKey(chunk.cx, chunk.cz)
        for index in chunk.naturalTreeCells.keys.sorted() {
            guard let record = chunk.naturalTreeCells[index] else { continue }
            guard index >= 0, index < chunk.blocks.count else {
                chunk.naturalTreeCells.removeValue(forKey: index); continue
            }
            let p = chunk.idxToWorld(index)
            guard record.expected == chunk.blocks[index],
                  (p.0 - 16...p.0 + 16).contains(record.origin.x),
                  (p.2 - 16...p.2 + 16).contains(record.origin.z),
                  p.1 >= record.origin.y - 8, p.1 <= record.origin.y + 64 else {
                chunk.naturalTreeCells.removeValue(forKey: index)
                continue
            }
            originsByChunk[key, default: []].insert(record.origin)
            if !protectedOversizedOrigins.contains(record.origin) {
                positionsByOrigin[record.origin, default: []].insert(CellPosition(x: p.0, y: p.1, z: p.2))
                if positionsByOrigin[record.origin]!.count > Self.maxCellsPerTree {
                    protectOversized(record.origin)
                    continue
                }
            }
            guard !protectedOversizedOrigins.contains(record.origin) else { continue }
            pending.insert(record.origin)
            if record.decayStartTick != nil { active.insert(record.origin) }
        }
        // A loaded root chunk may now contain only the cut stump's empty
        // location. Re-enqueue neighboring recorded crowns, not only its own
        // records, so they resume when their last missing dependency arrives.
        for cz in (chunk.cz - 2)...(chunk.cz + 2) { for cx in (chunk.cx - 2)...(chunk.cx + 2) {
            for origin in originsByChunk[chunkKey(cx, cz)] ?? [] where !protectedOversizedOrigins.contains(origin) {
                pending.insert(origin)
            }
        } }
    }

    private func protectOversized(_ origin: NaturalTreeOrigin) {
        positionsByOrigin.removeValue(forKey: origin)
        pending.remove(origin); active.remove(origin)
        protectedOversizedOrigins.insert(origin)
    }

    public func blockChanged(in world: World, x: Int, y: Int, z: Int, old: Int, new: Int) {
        guard !world.isTransientLANClient, old != new,
              let chunk = world.getChunkAt(x, z), chunk.inYRange(y) else { return }
        let index = chunk.index(posMod(x, 16), y, posMod(z, 16))
        if let record = chunk.naturalTreeCells.removeValue(forKey: index) {
            positionsByOrigin[record.origin]?.remove(CellPosition(x: x, y: y, z: z))
            if positionsByOrigin[record.origin]?.isEmpty == true {
                positionsByOrigin.removeValue(forKey: record.origin)
                originsByChunk[chunkKey(chunk.cx, chunk.cz)]?.remove(record.origin)
            }
            if !internalMutation, !protectedOversizedOrigins.contains(record.origin) { pending.insert(record.origin) }
        }
        guard !internalMutation else { return }
        // A soil/support edit can disconnect a tree without editing its wood.
        for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
            let nx = x + dx, ny = y + dy, nz = z + dz
            guard let c = world.getChunkAt(nx, nz), c.inYRange(ny),
                  let r = c.naturalTreeCells[c.index(posMod(nx, 16), ny, posMod(nz, 16))],
                  Self.isWood(r.expected) else { continue }
            if !protectedOversizedOrigins.contains(r.origin) { pending.insert(r.origin) }
        } } }
        // A repaired trunk can contain several player-placed logs. Soil or a
        // lower repair-log change must invalidate the natural crown above it,
        // even though no natural cell is directly adjacent to the edit.
        for aboveY in stride(from: y + 1, through: min(y + 65, world.info.minY + world.info.height - 1), by: 1) {
            let above = world.getBlock(x, aboveY, z)
            guard Self.isWood(UInt16(above)), let c = world.getChunkAt(x, z), c.inYRange(aboveY) else { break }
            if let r = c.naturalTreeCells[c.index(posMod(x, 16), aboveY, posMod(z, 16))] {
                if !protectedOversizedOrigins.contains(r.origin) { pending.insert(r.origin) }
                break
            }
        }
    }

    /// Called by the world clock and directly by bounded deterministic tests.
    /// Loading and support mutations enqueue inspections; healthy forests do
    /// not require an all-loaded-block scan every frame.
    public func tick(in world: World) {
        guard !world.isTransientLANClient, world.ecologyTick != lastTick else { return }
        lastTick = world.ecologyTick
        let ordered = pending.sorted()
        let due: [NaturalTreeOrigin]
        if ordered.isEmpty { due = [] }
        else {
            pendingCursor %= ordered.count
            due = (0..<min(Self.inspectionBudget, ordered.count)).map {
                ordered[(pendingCursor + $0) % ordered.count]
            }
            pendingCursor += due.count
        }
        for origin in due {
            pending.remove(origin)
            if protectedOversizedOrigins.contains(origin) { continue }
            guard world.getChunkAt(origin.x, origin.z) != nil else {
                active.remove(origin); continue
            }
            if !inspect(origin, in: world) { pending.insert(origin) }
        }
        guard !active.isEmpty else { return }
        let origins = active.sorted()
        activeCursor %= origins.count
        var budget = Self.mutationBudget
        for offset in 0..<min(Self.inspectionBudget, origins.count) {
            let origin = origins[(activeCursor + offset) % origins.count]
            decay(origin, in: world, budget: &budget)
            if budget == 0 { break }
        }
        activeCursor += min(Self.inspectionBudget, origins.count)
    }

    private struct CellPosition: Hashable, Comparable {
        let x: Int; let y: Int; let z: Int
        static func < (a: Self, b: Self) -> Bool {
            if a.y != b.y { return a.y < b.y }
            if a.z != b.z { return a.z < b.z }
            return a.x < b.x
        }
    }
    private struct OwnedCell {
        let chunk: Chunk; let index: Int; let position: CellPosition; let record: NaturalTreeCell
    }
    private func cells(_ origin: NaturalTreeOrigin, in world: World) -> [OwnedCell]? {
        let minCX = floorDiv(origin.x - 16, 16), maxCX = floorDiv(origin.x + 16, 16)
        let minCZ = floorDiv(origin.z - 16, 16), maxCZ = floorDiv(origin.z + 16, 16)
        var result: [OwnedCell] = []
        for cz in minCZ...maxCZ { for cx in minCX...maxCX {
            guard world.getChunk(cx, cz) != nil else { return nil }
        } }
        let positions = positionsByOrigin[origin] ?? []
        guard positions.count <= Self.maxCellsPerTree else { protectOversized(origin); return [] }
        for p in positions.sorted() {
            guard let chunk = world.getChunkAt(p.x, p.z), chunk.inYRange(p.y) else { return nil }
            let index = chunk.index(posMod(p.x, 16), p.y, posMod(p.z, 16))
            guard let record = chunk.naturalTreeCells[index], record.origin == origin,
                  chunk.blocks[index] == record.expected else {
                positionsByOrigin[origin]?.remove(p); continue
            }
            result.append(OwnedCell(chunk: chunk, index: index, position: p, record: record))
        }
        return result
    }

    private static func supportsRoot(_ cell: Int) -> Bool {
        guard cell > 0 else { return false }
        let id = cell >> 4
        guard id < blockDefs.count else { return false }
        let n = blockDefs[id].name
        return blockDefs[id].fullCube && blockDefs[id].solid
            && !n.hasSuffix("_leaves") && !n.hasSuffix("_log")
            && n != "mangrove_roots" && n != "muddy_mangrove_roots"
    }

    private func inspect(_ origin: NaturalTreeOrigin, in world: World) -> Bool {
        guard let owned = cells(origin, in: world) else { return false }
        if owned.isEmpty { active.remove(origin); return true }
        let wood = owned.filter { Self.isWood($0.record.expected) }
        // The quadratic nearest-branch assignment is small for real generated
        // trees (including mega jungle); a malformed save cannot amplify it.
        guard wood.isEmpty || owned.count <= 262_144 / wood.count else {
            protectOversized(origin); return true
        }
        let woodPositions = Set(wood.map(\.position))
        var supported = Set<CellPosition>()
        var queue: [CellPosition] = []
        for c in wood {
            let p = c.position
            let woodName = Self.name(c.record.expected)
            if woodName == "mangrove_roots" || woodName == "muddy_mangrove_roots" {
                // Mangrove roots wrap around banks and penetrate the underside
                // of soil overhangs. A direct soil attachment grounds a root
                // regardless of which face touches it; ordinary logs still
                // need support below. Losing that soil queues a fresh check.
                let soilAttached = [(1, 0, 0), (-1, 0, 0), (0, 1, 0),
                                    (0, -1, 0), (0, 0, 1), (0, 0, -1)].contains { dx, dy, dz in
                    isTreeSoil(world.getBlock(p.x + dx, p.y + dy, p.z + dz))
                }
                if soilAttached { queue.append(p); supported.insert(p); continue }
            }
            var belowY = p.y - 1
            // A player may repair a cut trunk using unmarked logs. Such logs
            // can provide support but never become eligible for deterioration.
            while belowY >= world.info.minY && p.y - belowY <= 64 {
                let below = world.getBlock(p.x, belowY, p.z)
                if Self.supportsRoot(below) { queue.append(p); supported.insert(p); break }
                let bp = CellPosition(x: p.x, y: belowY, z: p.z)
                if woodPositions.contains(bp) || !Self.isWood(UInt16(below)) { break }
                belowY -= 1
            }
        }
        var head = 0
        while head < queue.count {
            let p = queue[head]; head += 1
            for dz in -1...1 { for dy in -1...1 { for dx in -1...1 {
                let n = CellPosition(x: p.x + dx, y: p.y + dy, z: p.z + dz)
                if woodPositions.contains(n), supported.insert(n).inserted { queue.append(n) }
            } } }
        }
        let unsupported = woodPositions.subtracting(supported)
        var hasDecay = false
        for c in owned {
            var record = c.record
            let shouldDecay: Bool
            if Self.isWood(record.expected) { shouldDecay = unsupported.contains(c.position) }
            else if wood.isEmpty { shouldDecay = true }
            else {
                // Assign canopy to its nearest surviving trunk/branch, not a
                // neighboring tree or an arbitrarily distant rooted stump.
                let closest = wood.min { a, b in
                    let da = Self.distanceSquared(a.position, c.position)
                    let db = Self.distanceSquared(b.position, c.position)
                    return da == db ? a.position < b.position : da < db
                }!
                shouldDecay = unsupported.contains(closest.position)
            }
            if shouldDecay {
                if record.decayStartTick == nil { record.decayStartTick = world.ecologyTick }
                hasDecay = true
            } else { record.decayStartTick = nil }
            if record != c.record {
                c.chunk.naturalTreeCells[c.index] = record
                c.chunk.modified = true
            }
        }
        if hasDecay { active.insert(origin) } else { active.remove(origin) }
        return true
    }

    private static func distanceSquared(_ a: CellPosition, _ b: CellPosition) -> Int {
        let dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z
        return dx * dx + dy * dy + dz * dz
    }
    private static func hash(seed: UInt32, x: Int, y: Int, z: Int, salt: Int) -> UInt64 {
        var h = UInt64(seed) ^ 0x7472_6565_6563_6F31
        for v in [x, y, z, salt] {
            h ^= UInt64(bitPattern: Int64(v)) &+ 0x9E37_79B9_7F4A_7C15
            h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
            h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
            h ^= h >> 31
        }
        return h
    }
    private func decay(_ origin: NaturalTreeOrigin, in world: World, budget: inout Int) {
        guard let owned = cells(origin, in: world) else { return }
        var hasPending = false
        for c in owned {
            guard let start = c.record.decayStartTick else { continue }
            hasPending = true
            let p = c.position
            let hash = Self.hash(seed: world.seed, x: p.x, y: p.y, z: p.z, salt: start)
            let delay = 1 + Int(hash % UInt64(DAY_LENGTH))
            guard world.ecologyTick >= start, world.ecologyTick - start >= delay, budget > 0 else { continue }
            internalMutation = true
            world.setBlock(p.x, p.y, p.z, 0)
            internalMutation = false
            budget -= 1
            world.hooks.addParticles("block", Double(p.x) + 0.5, Double(p.y) + 0.5,
                                     Double(p.z) + 0.5, 4, 0.25, Int(c.record.expected))
            if Self.isLeaf(c.record.expected), (hash >> 16) % 20 == 0,
               world.rule("doTileDrops"), let sapling = Self.sapling(for: c.record.expected) {
                seed(sapling, at: p, hash: hash, in: world)
            }
        }
        if !hasPending { active.remove(origin) }
    }
    private static func sapling(for leaf: UInt16) -> UInt16? {
        let n = name(leaf)
        let wood = String(n.dropLast("_leaves".count))
        let plant = wood == "mangrove" ? "mangrove_propagule"
            : wood == "azalea" || wood == "flowering_azalea" ? wood : "\(wood)_sapling"
        let id = bid(plant)
        return id == 0 ? nil : id
    }
    private func seed(_ sapling: UInt16, at p: CellPosition, hash: UInt64, in world: World) {
        // Exactly one seed per successful roll: either a planted sapling or a
        // collectible item, never both. Only one in four attempts self-seeds.
        if (hash >> 32) % 4 == 0 {
            let x = p.x + Int((hash >> 36) % 7) - 3
            let z = p.z + Int((hash >> 40) % 7) - 3
            if Self.plantSeedling(sapling, x: x, startY: p.y, z: z, in: world) { return }
        }
        let item = ItemEntity(world: world)
        item.stack = ItemStack(iid(blockDefs[Int(sapling)].name), 1)
        item.setPos(Double(p.x) + 0.5, Double(p.y) + 0.5, Double(p.z) + 0.5)
        item.vx = (Double((hash >> 44) % 17) - 8) / 200
        item.vy = 0.1
        item.vz = (Double((hash >> 49) % 17) - 8) / 200
        world.addEntity(item)
    }

    @discardableResult
    static func plantSeedling(_ sapling: UInt16, x: Int, startY: Int, z: Int, in world: World) -> Bool {
        guard world.isLoadedAt(x, z), !world.isTransientLANClient else { return false }
        for y in stride(from: min(startY, world.info.minY + world.info.height - 2), through: max(world.info.minY + 1, startY - 64), by: -1) {
            let below = world.getBlock(x, y - 1, z)
            if below == 0 { continue }
            guard isTreeSoil(below), world.getBlock(x, y, z) == 0,
                  world.getBlock(x, y + 1, z) == 0 else { return false }
            // Avoid unchecked spread, foundations, and forests becoming walls.
            for dz in -2...2 { for dx in -2...2 {
                guard world.isLoadedAt(x + dx, z + dz) else { return false }
                let nearby = world.getBlock(x + dx, y, z + dz)
                if nearby != 0 {
                    let n = Self.name(UInt16(nearby))
                    if Self.isWood(UInt16(nearby)) || n.hasSuffix("_sapling") || n == "mangrove_propagule" { return false }
                }
            } }
            world.setBlock(x, y, z, Int(cell(sapling)))
            return true
        }
        return false
    }
}

func isTreeSoil(_ cell: Int) -> Bool {
    let id = cell >> 4
    return id == Int(B.grass_block) || id == Int(B.dirt) || id == Int(B.coarse_dirt)
        || id == Int(B.podzol) || id == Int(B.mycelium) || id == Int(B.rooted_dirt)
        || id == Int(B.moss_block) || id == Int(B.mud) || id == Int(B.farmland)
}
