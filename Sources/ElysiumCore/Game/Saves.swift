// Persistence — a single SQLite database at
// ~/Library/Application Support/Elysium/elysium.db (WAL mode, fully mutexed):
//   worlds(id, json, lastPlayed)            — world metadata + global state
//   chunks(world, dim, cx, cz, data BLOB)   — modified chunks (VCK1 binary)
//   player(world, json)                     — player snapshot per world
//   lan_player_resume(hostWorld, json)      — local resume point for hosted LAN worlds
//   lan_players(world, playerID, json)      — host-side per-guest LAN player records
//   advancements(world, json)               — earned advancement ids per world
//   templates(name, json, created, data, ...) — local cloned construction templates
// Legacy installs stored loose files under saves/; they are imported once on
// first open and the old folder is kept as saves-legacy-backup. Chunk records
// keep the VCK1 container (binary blocks + JSON tail); entity-only records
// regenerate terrain from seed and re-attach saved entities.

import Foundation
import CoreFoundation
import CryptoKit
import ElysiumStorage

public struct RPGQuickSlotStorageSnapshot: Sendable, Equatable {
    public let preferences: RPGQuickSlotPreferences
    public let revision: UInt64
    public let digest: LANV6SHA256Digest
    public let migrationOriginDigest: LANV6SHA256Digest?
    public let migrationOriginRevision: UInt64?
}

public struct RPGLegacyQuickSlotMigrationResult: Sendable, Equatable {
    public let snapshot: RPGQuickSlotStorageSnapshot
    public let sourceDigest: LANV6SHA256Digest
    public let insertedDestination: Bool
}

public struct SaveDBPlayerRowDigest: Equatable, Sendable {
    public let data: Data

    public init(data: Data) throws {
        guard data.count == 32 else { throw SaveDBPlayerRowError.invalidCandidate }
        self.data = data
    }
}

public struct SaveDBPlayerRowSnapshot {
    public let worldID: String
    public let data: [String: Any]
    public let canonicalDigest: SaveDBPlayerRowDigest
}

public enum SaveDBPlayerRowExpectation: Equatable, Sendable {
    case absent
    case present(SaveDBPlayerRowDigest)
}

public enum SaveDBPlayerRowError: Error, Equatable, Sendable {
    case invalidCandidate
    case invalidStoredRow
    case conflict
    case persistenceFailed
}

public struct DimState: Codable {
    public var time: Int
    public var dayTime: Int
    public var raining: Bool
    public var thundering: Bool
    public var weatherTimer: Int

    public init(time: Int = 0, dayTime: Int = 1000, raining: Bool = false,
                thundering: Bool = false, weatherTimer: Int = 24000) {
        self.time = time
        self.dayTime = dayTime
        self.raining = raining
        self.thundering = thundering
        self.weatherTimer = weatherTimer
    }
}

/// single source of truth for the app version — the title screen, the F3
/// overlay and save records all read this (Info.plist is bumped separately
/// at packaging time)
public let ELYSIUM_VERSION = "1.1.0"

/// WorldMeta + the global-state extension (baseline WorldRecord extends WorldMeta)
public struct WorldRecord: Codable {
    public var id: String
    public var name: String
    public var seed: Int32
    public var gameMode: Int
    public var difficulty: Int
    public var lastPlayed: Double      // ms epoch, like Date.now()
    public var version: String
    /// keyed by dim rawValue as a string — Swift encodes [Int:] dicts as JSON
    /// arrays, and the record should read as `{"0": {...}, "1": {...}}` on disk
    public var dims: [String: DimState]
    public var spawnX: Int
    public var spawnY: Int
    public var spawnZ: Int
    public var worldPreset: String
    public var singleBiome: String
    public var dungeonDensity: Int
    public var gameRules: [String: Double]
    public var dragonKilled: Bool
    public var gatewaysSpawned: Int
    public var nextEntityId: Int
    public var rpgSimulationTick: Int

    public var generationSettings: WorldGenerationSettings {
        WorldGenerationSettings(presetID: worldPreset, singleBiomeID: singleBiome,
                                dungeonDensityLevel: dungeonDensity)
    }

    public init(id: String, name: String, seed: Int32, gameMode: Int, difficulty: Int,
                worldPreset: WorldPreset = .normal, singleBiome: Biome = .plains,
                dungeonDensity: DungeonDensity = .normal) {
        self.id = id
        self.name = name
        self.seed = seed
        self.gameMode = gameMode
        self.difficulty = difficulty
        lastPlayed = Date().timeIntervalSince1970 * 1000
        version = "elysium-\(ELYSIUM_VERSION)"
        dims = ["0": DimState(), "1": DimState(), "2": DimState()]
        spawnX = 0
        spawnY = 80
        spawnZ = 0
        self.worldPreset = worldPreset.rawValue
        self.singleBiome = biomeID(singleBiome)
        self.dungeonDensity = dungeonDensity.rawValue
        gameRules = [:]
        dragonKilled = false
        gatewaysSpawned = 0
        nextEntityId = 1
        rpgSimulationTick = 0
    }

    enum CodingKeys: String, CodingKey {
        case id, name, seed, gameMode, difficulty, lastPlayed, version, dims
        case spawnX, spawnY, spawnZ, worldPreset, singleBiome, dungeonDensity, gameRules
        case dragonKilled, gatewaysSpawned, nextEntityId, rpgSimulationTick
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        seed = try c.decode(Int32.self, forKey: .seed)
        gameMode = try c.decode(Int.self, forKey: .gameMode)
        difficulty = try c.decode(Int.self, forKey: .difficulty)
        lastPlayed = try c.decodeIfPresent(Double.self, forKey: .lastPlayed) ?? Date().timeIntervalSince1970 * 1000
        version = try c.decodeIfPresent(String.self, forKey: .version) ?? "elysium-\(ELYSIUM_VERSION)"
        dims = try c.decodeIfPresent([String: DimState].self, forKey: .dims)
            ?? ["0": DimState(), "1": DimState(), "2": DimState()]
        spawnX = try c.decodeIfPresent(Int.self, forKey: .spawnX) ?? 0
        spawnY = try c.decodeIfPresent(Int.self, forKey: .spawnY) ?? 80
        spawnZ = try c.decodeIfPresent(Int.self, forKey: .spawnZ) ?? 0
        worldPreset = normalizedWorldPreset(try c.decodeIfPresent(String.self, forKey: .worldPreset)).rawValue
        singleBiome = biomeID(normalizedSingleBiome(try c.decodeIfPresent(String.self, forKey: .singleBiome)))
        dungeonDensity = WorldRecord.decodeDungeonDensity(from: c).rawValue
        gameRules = try c.decodeIfPresent([String: Double].self, forKey: .gameRules) ?? [:]
        dragonKilled = try c.decodeIfPresent(Bool.self, forKey: .dragonKilled) ?? false
        gatewaysSpawned = try c.decodeIfPresent(Int.self, forKey: .gatewaysSpawned) ?? 0
        nextEntityId = try c.decodeIfPresent(Int.self, forKey: .nextEntityId) ?? 1
        if let persisted = try c.decodeIfPresent(Int.self, forKey: .rpgSimulationTick) {
            rpgSimulationTick = max(0, min(RPG_MAX_COUNTER, persisted))
        } else {
            rpgSimulationTick = max(0, min(RPG_MAX_COUNTER, dims.values.map(\.time).max() ?? 0))
        }
    }

    private static func decodeDungeonDensity(from c: KeyedDecodingContainer<CodingKeys>) -> DungeonDensity {
        if let raw = try? c.decodeIfPresent(Int.self, forKey: .dungeonDensity) {
            return normalizedDungeonDensity(raw)
        }
        if let raw = try? c.decodeIfPresent(String.self, forKey: .dungeonDensity) {
            return normalizedDungeonDensity(raw)
        }
        return .normal
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(seed, forKey: .seed)
        try c.encode(gameMode, forKey: .gameMode)
        try c.encode(difficulty, forKey: .difficulty)
        try c.encode(lastPlayed, forKey: .lastPlayed)
        try c.encode(version, forKey: .version)
        try c.encode(dims, forKey: .dims)
        try c.encode(spawnX, forKey: .spawnX)
        try c.encode(spawnY, forKey: .spawnY)
        try c.encode(spawnZ, forKey: .spawnZ)
        try c.encode(normalizedWorldPreset(worldPreset).rawValue, forKey: .worldPreset)
        try c.encode(biomeID(normalizedSingleBiome(singleBiome)), forKey: .singleBiome)
        try c.encode(normalizedDungeonDensity(dungeonDensity).rawValue, forKey: .dungeonDensity)
        try c.encode(gameRules, forKey: .gameRules)
        try c.encode(dragonKilled, forKey: .dragonKilled)
        try c.encode(gatewaysSpawned, forKey: .gatewaysSpawned)
        try c.encode(nextEntityId, forKey: .nextEntityId)
        try c.encode(max(0, min(RPG_MAX_COUNTER, rpgSimulationTick)), forKey: .rpgSimulationTick)
    }
}

public struct ChunkRecord {
    public var key: String
    public var worldId: String
    public var dim: Int
    public var cx: Int
    public var cz: Int
    /// absent on entity-only records: the chunk itself regenerates from seed
    public var blocks: [UInt16]?
    public var biomes: [UInt8]?
    public var blockEntities: [BlockEntityData]?
    public var entities: [[String: Any]]

    public init(key: String, worldId: String, dim: Int, cx: Int, cz: Int,
                blocks: [UInt16]? = nil, biomes: [UInt8]? = nil,
                blockEntities: [BlockEntityData]? = nil, entities: [[String: Any]] = []) {
        self.key = key
        self.worldId = worldId
        self.dim = dim
        self.cx = cx
        self.cz = cz
        self.blocks = blocks
        self.biomes = biomes
        self.blockEntities = blockEntities
        self.entities = entities
    }
}

/// JSON can't carry NaN/Infinity (structured clone could) — scrub them so one
/// blown-up velocity never poisons a whole chunk record
func sanitizeJSON(_ v: Any) -> Any {
    // JSONSerialization bridges both booleans and numbers through NSNumber.
    // Checking `as? Double` first coerces CFBoolean values to 1/0, which makes
    // Codable Bool fields fail to decode when the record is loaded again.
    if let number = v as? NSNumber {
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        return number.doubleValue.isFinite ? number : 0
    }
    if let arr = v as? [Any] { return arr.map(sanitizeJSON) }
    if let dict = v as? [String: Any] { return dict.mapValues(sanitizeJSON) }
    return v
}

func encodeWorldRecordJSON(_ record: WorldRecord) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(record)
}

// binary container: "VCK1" | u8 flags | [u32 nBlocks, u16[] LE, u32 nBiomes, u8[]]
// | u32 jsonLen | JSON. These helpers intentionally know nothing about storage.
func encodeLegacyVCK(_ record: ChunkRecord) -> Data? {
    var data = Data("VCK1".utf8)
    let hasBlocks = record.blocks != nil && record.biomes != nil
    data.append(hasBlocks ? 1 : 0)
    func appendU32(_ value: Int) -> Bool {
        guard let exact = UInt32(exactly: value) else { return false }
        var littleEndian = exact.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        return true
    }
    if hasBlocks {
        guard let blocks = record.blocks, let biomes = record.biomes,
              appendU32(blocks.count) else { return nil }
        for block in blocks {
            var littleEndian = block.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        guard appendU32(biomes.count) else { return nil }
        data.append(contentsOf: biomes)
    }
    var tail: [String: Any] = ["entities": record.entities.map(sanitizeJSON)]
    if let blockEntities = record.blockEntities,
       let encoded = try? JSONEncoder().encode(blockEntities),
       let object = try? JSONSerialization.jsonObject(with: encoded) {
        tail["blockEntities"] = object
    }
    guard let json = try? JSONSerialization.data(withJSONObject: tail),
          appendU32(json.count) else { return nil }
    data.append(json)
    return data
}

private func legacyVCKLayout(_ data: Data, dimension: Int) -> (flags: UInt8, json: Range<Int>)? {
    guard data.count >= 9, data.prefix(4) == Data("VCK1".utf8),
          let dim = Dim(rawValue: dimension) else { return nil }
    var offset = 4
    let flags = data[offset]
    offset += 1
    guard flags & ~1 == 0 else { return nil }
    func readU32() -> Int? {
        guard offset <= data.count - 4 else { return nil }
        let value = Int(data[offset])
            | (Int(data[offset + 1]) << 8)
            | (Int(data[offset + 2]) << 16)
            | (Int(data[offset + 3]) << 24)
        offset += 4
        return value
    }
    if flags & 1 != 0 {
        let info = dimInfo(dim)
        let expectedBlocks = CHUNK_W * CHUNK_W * info.height
        let expectedBiomes = 4 * 4 * ((info.height + 3) / 4)
        guard let blockCount = readU32(), blockCount == expectedBlocks,
              blockCount <= (data.count - offset) / 2 else { return nil }
        offset += blockCount * 2
        guard let biomeCount = readU32(), biomeCount == expectedBiomes,
              biomeCount <= data.count - offset else { return nil }
        offset += biomeCount
    }
    guard let jsonLength = readU32(), jsonLength <= data.count - offset else { return nil }
    return (flags, offset..<(offset + jsonLength))
}

/// Registry-independent structural validation used by migration before registry boot.
func validateLegacyVCKStructure(_ data: Data, dimension: Int) -> Bool {
    guard let layout = legacyVCKLayout(data, dimension: dimension),
          legacyMigrationJSONBudget(data.subdata(in: layout.json)) != nil,
          let object = try? JSONSerialization.jsonObject(with: data.subdata(in: layout.json)),
          object is [String: Any] else { return false }
    return true
}

func decodeLegacyVCK(_ data: Data, key: String, worldId: String,
                     dimension: Int, chunkX: Int, chunkZ: Int) -> ChunkRecord? {
    guard let layout = legacyVCKLayout(data, dimension: dimension) else { return nil }
    var record = ChunkRecord(key: key, worldId: worldId, dim: dimension,
                             cx: chunkX, cz: chunkZ)
    var offset = 5
    func readU32() -> Int {
        defer { offset += 4 }
        return Int(data[offset]) | (Int(data[offset + 1]) << 8)
            | (Int(data[offset + 2]) << 16) | (Int(data[offset + 3]) << 24)
    }
    if layout.flags & 1 != 0 {
        let blockCount = readU32()
        var blocks = [UInt16]()
        blocks.reserveCapacity(blockCount)
        for _ in 0..<blockCount {
            blocks.append(UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
            offset += 2
        }
        let maximumBlockID = UInt16(clamping: blockDefs.count)
        for index in blocks.indices where (blocks[index] >> 4) >= maximumBlockID {
            blocks[index] = 0
        }
        record.blocks = blocks
        let biomeCount = readU32()
        record.biomes = Array(data[offset..<(offset + biomeCount)])
    }
    guard let tail = try? JSONSerialization.jsonObject(
        with: data.subdata(in: layout.json)) as? [String: Any] else { return nil }
    record.entities = tail["entities"] as? [[String: Any]] ?? []
    if let raw = tail["blockEntities"],
       let encoded = try? JSONSerialization.data(withJSONObject: raw),
       let blockEntities = try? JSONDecoder().decode([BlockEntityData].self, from: encoded) {
        record.blockEntities = blockEntities
    }
    return record
}

public struct SaveDBOpenError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Stage: String, Sendable {
        case storageOpen, schemaVerification, legacyBackupRecoveryRequired
        case migrationParent, migrationLease, migrationManifest
        case migrationDecode, migrationImport, migrationBarrier
        case migrationRename, migrationDirectorySync, cleanup
    }

    public enum Result: String, Sendable {
        case unavailable, conflict, invalidSource, limitExceeded
        case unsupported, durabilityFailure, cleanupFailed
    }

    public let stage: Stage
    public let result: Result

    public init(stage: Stage, result: Result) {
        self.stage = stage
        self.result = result
    }

    public var description: String {
        "Elysium save open failed: \(stage.rawValue)/\(result.rawValue)"
    }
}

#if DEBUG
enum SaveDBPlayerCASBarrierStage: Sendable {
    case beforeFacade
    case afterCommit
}

final class SaveDBPlayerCASBarrier: @unchecked Sendable {
    private let reached = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)

    func waitUntilReached() -> Bool {
        reached.wait(timeout: .now() + 5) == .success
    }

    func resume() { resumed.signal() }

    fileprivate func observe() {
        reached.signal()
        precondition(resumed.wait(timeout: .now() + 5) == .success,
                     "player CAS test barrier timed out")
    }
}
#endif

public final class SaveDB {
    private struct OpenComponents {
        let coordinator: ElysiumStorageCoordinator
        let storage: ElysiumLegacyCoreStorage
    }

    private static let deferredCleanupQueue = DispatchQueue(
        label: "elysium.storage.deferred-cleanup", qos: .utility)

    private let coordinator: ElysiumStorageCoordinator
    private let storage: ElysiumLegacyCoreStorage
    private let worldDeleteRecoveryLock = NSLock()
    private struct WorldDeleteRecoveryRecord {
        let authority: ElysiumWorldBatchDeleteRecoveryAuthority
        let requestIdentity: Data
        let selectedWorldIDs: [String]
    }
    private var worldDeleteRecoveryAuthorities: [UUID: WorldDeleteRecoveryRecord] = [:]

    private func withWorldDeleteRecoveryLock<T>(_ body: () -> T) -> T {
        worldDeleteRecoveryLock.lock(); defer { worldDeleteRecoveryLock.unlock() }
        return body()
    }
#if DEBUG
    private static let rpgDecodeRankLock = NSLock()
    private static var rpgDecodeRank = -1
    private let playerCASProbeLock = NSLock()
    private var playerCASRanks: [Int] = []
    private var playerCASBarrier: (
        stage: SaveDBPlayerCASBarrierStage, barrier: SaveDBPlayerCASBarrier
    )?

    static func _testLastRPGDecodeRank() -> Int {
        rpgDecodeRankLock.lock(); defer { rpgDecodeRankLock.unlock() }
        return rpgDecodeRank
    }

    func _testPlayerCASRanks() -> [Int] {
        playerCASProbeLock.lock(); defer { playerCASProbeLock.unlock() }
        return playerCASRanks
    }

    func _testArmPlayerCASBarrier(
        _ stage: SaveDBPlayerCASBarrierStage
    ) -> SaveDBPlayerCASBarrier {
        playerCASProbeLock.lock(); defer { playerCASProbeLock.unlock() }
        precondition(playerCASBarrier == nil, "player CAS test barrier already armed")
        let barrier = SaveDBPlayerCASBarrier()
        playerCASBarrier = (stage, barrier)
        return barrier
    }

    private func resetPlayerCASRanks() {
        playerCASProbeLock.lock(); playerCASRanks = []; playerCASProbeLock.unlock()
    }

    private func recordPlayerCASRank() {
        playerCASProbeLock.lock()
        playerCASRanks.append(elysiumCurrentLockRank())
        playerCASProbeLock.unlock()
    }

    private func observePlayerCASBarrier(_ stage: SaveDBPlayerCASBarrierStage) {
        playerCASProbeLock.lock()
        let armed = playerCASBarrier
        if armed?.stage == stage { playerCASBarrier = nil }
        playerCASProbeLock.unlock()
        if armed?.stage == stage { armed?.barrier.observe() }
    }

    func _testSetSavedWorldDeleteFailure(
        _ stage: ElysiumStorageRPGLocalFailureStage
    ) throws {
        try withStorageRank {
            try coordinator._testSetSavedWorldDeleteFailure(stage)
        }
    }

    func _testSavedWorldRecoverySideEffectSnapshot()
        throws -> ElysiumStorageRecoverySideEffectSnapshot {
        try withStorageRank {
            try coordinator._testRecoverySideEffectSnapshot()
        }
    }
#endif

    public convenience init() {
        self.init(components: Self.compatibilityComponents(
            databaseURL: vcSupportDir().appendingPathComponent("elysium.db"),
            migrateLegacy: true))
    }

    convenience init(databaseURL: URL, migrateLegacy: Bool) {
        self.init(components: Self.compatibilityComponents(
            databaseURL: databaseURL, migrateLegacy: migrateLegacy))
    }

    private init(components: OpenComponents) {
        coordinator = components.coordinator
        storage = components.storage
    }

    public static func open(databaseURL: URL, migrateLegacy: Bool) throws -> SaveDB {
        SaveDB(components: try openComponents(databaseURL: databaseURL,
                                              migrateLegacy: migrateLegacy))
    }

    private static func compatibilityComponents(databaseURL: URL,
                                                migrateLegacy: Bool) -> OpenComponents {
        do {
            return try openComponents(databaseURL: databaseURL, migrateLegacy: migrateLegacy)
        } catch {
            fatalError("Elysium save database initialization failed")
        }
    }

    private static func openComponents(databaseURL: URL,
                                       migrateLegacy: Bool) throws -> OpenComponents {
        if migrateLegacy {
            return try withElysiumLockRank(.migrationSource) {
                try openComponentsHoldingMigrationRank(databaseURL: databaseURL,
                                                       migrateLegacy: true)
            }
        }
        return try openComponentsHoldingMigrationRank(databaseURL: databaseURL,
                                                      migrateLegacy: false)
    }

    private static func openComponentsHoldingMigrationRank(databaseURL: URL,
                                                            migrateLegacy: Bool) throws -> OpenComponents {
        let preflight: LegacyMigrationPreflight?
        if migrateLegacy {
            do {
                try FileManager.default.createDirectory(
                    at: databaseURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            } catch {
                throw SaveDBOpenError(stage: .migrationParent, result: .unavailable)
            }
            preflight = try LegacySaveMigration.preflight(databaseURL: databaseURL)
        } else {
            preflight = nil
        }

        let coordinator: ElysiumStorageCoordinator
        do {
            coordinator = try withElysiumLockRank(.saveDB) {
                try ElysiumStorageCoordinator.open(databaseURL: databaseURL)
            }
        } catch {
            throw mapStorageError(error, stage: .storageOpen)
        }

        do {
            let storage = try withElysiumLockRank(.saveDB) {
                let facade = try coordinator.legacyCore()
                try facade.verifyCoreSchema()
                return facade
            }
            guard let preflight else {
                return OpenComponents(coordinator: coordinator, storage: storage)
            }
            let session = try LegacySaveMigration.run(
                databaseURL: databaseURL, coordinator: coordinator,
                storage: storage, preflight: preflight)
            return OpenComponents(coordinator: session.coordinator, storage: session.storage)
        } catch {
            let mapped = (error as? SaveDBOpenError)
                ?? mapStorageError(error, stage: .schemaVerification)
            do {
                try withElysiumLockRank(.saveDB) { try coordinator.close() }
            } catch {
                throw SaveDBOpenError(stage: mapped.stage, result: .cleanupFailed)
            }
            throw mapped
        }
    }

    private static func mapStorageError(_ error: Error,
                                        stage: SaveDBOpenError.Stage) -> SaveDBOpenError {
        let result: SaveDBOpenError.Result
        switch error as? ElysiumStorageError {
        case .duplicateOpen: result = .conflict
        case .invalidValue, .invalidStorageClass, .invalidUTF8,
             .schemaMismatch, .schemaIntegrity: result = .invalidSource
        case .limitExceeded: result = .limitExceeded
        default: result = .unavailable
        }
        return SaveDBOpenError(stage: stage, result: result)
    }

    public func close() throws {
        try withElysiumLockRank(.saveDB) { try coordinator.close() }
    }

    deinit {
        let retainedCoordinator = coordinator
        Self.deferredCleanupQueue.async {
            try? withElysiumLockRank(.saveDB) { try retainedCoordinator.close() }
        }
    }

    @inline(__always)
    private func withStorageRank<T>(_ body: () throws -> T) rethrows -> T {
        try withElysiumLockRank(.saveDB, body)
    }

    public func listWorlds() -> [WorldRecord] {
        guard let values = try? withStorageRank({ try storage.listLegacyWorldJSON() }) else { return [] }
        return values.compactMap { try? JSONDecoder().decode(WorldRecord.self, from: Data($0.utf8)) }
    }

    /// Returns the bounded, storage-checked saved-world authority used by the
    /// batch-selection surface. Unlike `listWorlds`, this deliberately does not
    /// discard malformed rows: a corrupt authority must block destructive work.
    public func checkedWorldSnapshot() throws -> CheckedSavedWorldSnapshot {
        let snapshot = try withStorageRank { try storage.checkedWorldSnapshot() }
        let authority = SavedWorldAuthoritySnapshot(
            rows: snapshot.rows.map {
                SavedWorldAuthorityRow(
                    storedID: $0.storedID, json: $0.json, lastPlayed: $0.lastPlayed,
                    rowDigest: $0.rowDigest)
            },
            collectionDigest: snapshot.collectionDigest,
            aggregateRawBytes: snapshot.aggregateRawBytes)
        return try CheckedSavedWorldSnapshot(authoritySnapshot: authority)
    }

    /// Atomically applies an immutable checked deletion request and reports the
    /// storage engine's post-commit recovery classification to the caller.
    public func deleteWorldsChecked(
        _ request: SavedWorldDeleteRequest
    ) -> SavedWorldDeleteOutcome {
        let storageRequest: ElysiumWorldBatchDeleteRequest
        do {
            storageRequest = try ElysiumWorldBatchDeleteRequest(
                expectedCollectionDigest: request.expectedCollectionDigest,
                expectations: try request.expectations.map {
                    try ElysiumWorldBatchDeleteExpectation(
                        storedID: $0.storedID, rowDigest: $0.rowDigest)
                })
        } catch {
            return .terminalIntegrity
        }
        let outcome = withStorageRank { storage.deleteWorldsChecked(storageRequest) }
        func receipt(_ value: ElysiumWorldBatchDeleteReceipt) -> SavedWorldDeleteReceipt {
            SavedWorldDeleteReceipt(
                preAuthorityDigest: value.preAuthorityDigest,
                postAuthorityDigest: value.postAuthorityDigest,
                unrelatedIdentityDigest: value.unrelatedIdentityDigest,
                deletedWorldCount: value.deletedWorldCount)
        }
        switch outcome {
        case .direct(let value): return .direct(receipt(value))
        case .recovered(let value): return .recovered(receipt(value))
        case .provenPrecommitFailure: return .provenPrecommitFailure
        case .stale: return .stale
        case .terminalRecovery(let authority):
            let requestIdentity = savedWorldDeleteRequestIdentity(request)
            let selectedWorldIDs = request.expectations.map(\.storedID)
            guard authority.receipt.receiptDigest.count == 32,
                  requestIdentity.count == 32 else { return .terminalIntegrity }
            let coreAuthority = SavedWorldDeleteRecoveryAuthority(
                requestIdentity: requestIdentity,
                selectedWorldIDs: selectedWorldIDs)
            withWorldDeleteRecoveryLock {
                worldDeleteRecoveryAuthorities = [
                    coreAuthority.handleID: WorldDeleteRecoveryRecord(
                        authority: authority,
                        requestIdentity: requestIdentity,
                        selectedWorldIDs: selectedWorldIDs),
                ]
            }
            return .terminalRecovery(coreAuthority)
        case .terminalIntegrity: return .terminalIntegrity
        }
    }

    public func recoverWorldsChecked(
        _ authority: SavedWorldDeleteRecoveryAuthority
    ) -> SavedWorldDeleteOutcome {
        guard authority.requestIdentity.count == 32,
              !authority.selectedWorldIDs.isEmpty,
              let retained = withWorldDeleteRecoveryLock({
                worldDeleteRecoveryAuthorities[authority.handleID]
              }),
              LANV6Crypto.constantTimeEqual32(
                retained.requestIdentity, authority.requestIdentity),
              retained.selectedWorldIDs == authority.selectedWorldIDs,
              retained.authority.receipt.receiptDigest.count == 32,
              LANV6Crypto.constantTimeEqual32(
                retained.authority.receipt.requestDigest,
                retained.authority.request.requestDigest),
              retained.authority.request.expectations.map(\.storedID)
                == retained.selectedWorldIDs,
              LANV6Crypto.constantTimeEqual32(
                savedWorldDeleteRequestIdentity(SavedWorldDeleteRequest(
                expectedCollectionDigest: retained.authority.request.expectedCollectionDigest,
                expectations: retained.authority.request.expectations.map {
                    SavedWorldDeleteExpectation(
                        storedID: $0.storedID, rowDigest: $0.rowDigest)
                })), authority.requestIdentity) else {
            return .terminalIntegrity
        }
        let outcome = withStorageRank { storage.recoverWorldsChecked(retained.authority) }
        func receipt(_ value: ElysiumWorldBatchDeleteReceipt) -> SavedWorldDeleteReceipt {
            SavedWorldDeleteReceipt(
                preAuthorityDigest: value.preAuthorityDigest,
                postAuthorityDigest: value.postAuthorityDigest,
                unrelatedIdentityDigest: value.unrelatedIdentityDigest,
                deletedWorldCount: value.deletedWorldCount)
        }
        switch outcome {
        case .recovered(let value):
            _ = withWorldDeleteRecoveryLock {
                worldDeleteRecoveryAuthorities.removeValue(forKey: authority.handleID)
            }
            return .recovered(receipt(value))
        case .provenPrecommitFailure:
            _ = withWorldDeleteRecoveryLock {
                worldDeleteRecoveryAuthorities.removeValue(forKey: authority.handleID)
            }
            return .provenPrecommitFailure
        case .terminalRecovery:
            return .terminalRecovery(authority)
        case .direct(let value):
            _ = withWorldDeleteRecoveryLock {
                worldDeleteRecoveryAuthorities.removeValue(forKey: authority.handleID)
            }
            return .direct(receipt(value))
        case .stale: return .stale
        case .terminalIntegrity: return .terminalIntegrity
        }
    }

    public func getWorld(_ id: String) -> WorldRecord? {
        guard let json = try? withStorageRank({ try storage.getLegacyWorldJSON(id: id) }) else {
            return nil
        }
        return try? JSONDecoder().decode(WorldRecord.self, from: Data(json.utf8))
    }

    public func putWorld(_ record: WorldRecord) {
        guard let encoded = encodeWorldRecordJSON(record),
              let json = String(data: encoded, encoding: .utf8),
              let row = try? ElysiumWorldStorageRow(id: record.id, json: json,
                                                   lastPlayed: record.lastPlayed) else { return }
        try? withStorageRank { try storage.putWorldRow(row) }
    }

    public func deleteWorld(_ id: String) {
        _ = try? withStorageRank { try storage.deleteWorld(id: id) }
    }

    private func decodeRPGQuickSlotRow(
        _ row: ElysiumRPGLocalPreferenceStorageRow
    ) throws -> RPGQuickSlotStorageSnapshot {
#if DEBUG
        Self.rpgDecodeRankLock.lock()
        Self.rpgDecodeRank = elysiumCurrentLockRank()
        Self.rpgDecodeRankLock.unlock()
        precondition(elysiumCurrentLockRank() == 0,
                     "RPG preference decode must run after SaveDB rank release")
#endif
        let scope = try RPGLocalPreferenceScope.validatedLocalWorld(row.worldRecordID)
        let preferences = try rpgDecodeQuickSlotPreferencesStoragePayload(row.slotsPayload)
        let digest = try rpgQuickSlotDestinationDigest(
            scope: scope, preferences: preferences, schemaVersion: row.schemaVersion,
            revision: row.revision)
        guard LANV6Crypto.constantTimeEqual32(digest.data, row.payloadDigest) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let originDigest = try row.migrationOriginDigest.map(LANV6SHA256Digest.init(data:))
        return RPGQuickSlotStorageSnapshot(
            preferences: preferences, revision: row.revision, digest: digest,
            migrationOriginDigest: originDigest,
            migrationOriginRevision: row.migrationOriginRevision)
    }

    private func makeRPGQuickSlotRow(
        worldRecordID: String, preferences: RPGQuickSlotPreferences, revision: UInt64,
        migrationOriginDigest: LANV6SHA256Digest? = nil,
        migrationOriginRevision: UInt64? = nil
    ) throws -> ElysiumRPGLocalPreferenceStorageRow {
        let scope = try RPGLocalPreferenceScope.validatedLocalWorld(worldRecordID)
        let payload = try rpgEncodeQuickSlotPreferencesStoragePayload(preferences)
        let digest = try rpgQuickSlotDestinationDigest(
            scope: scope, preferences: preferences, schemaVersion: 1, revision: revision)
        return try ElysiumRPGLocalPreferenceStorageRow(
            worldRecordID: worldRecordID, schemaVersion: 1, revision: revision,
            slotsPayload: payload, payloadDigest: digest.data,
            migrationOriginDigest: migrationOriginDigest?.data,
            migrationOriginRevision: migrationOriginRevision)
    }

    public func loadRPGQuickSlotPreferences(
        worldRecordID: String
    ) throws -> RPGQuickSlotStorageSnapshot? {
        let row = try withStorageRank {
            let facade = try coordinator.rpgLocalPreferences()
            return try facade.read(worldRecordID: worldRecordID)
        }
        return try row.map(decodeRPGQuickSlotRow)
    }

    public func materializeRPGQuickSlotPreferences(
        worldRecordID: String, defaults: RPGQuickSlotPreferences
    ) throws -> RPGQuickSlotStorageSnapshot {
        let candidate = try makeRPGQuickSlotRow(
            worldRecordID: worldRecordID, preferences: defaults, revision: 1)
        let row = try withStorageRank {
            let facade = try coordinator.rpgLocalPreferences()
            return try facade.materializeIfAbsent(candidate: candidate)
        }
        return try decodeRPGQuickSlotRow(row)
    }

    public func compareAndSwapRPGQuickSlotPreferences(
        worldRecordID: String, expected: RPGQuickSlotStorageSnapshot,
        candidatePreferences: RPGQuickSlotPreferences
    ) throws -> RPGQuickSlotStorageSnapshot {
        guard expected.revision < 1_000_000_000 else {
            throw ElysiumStorageError.limitExceeded
        }
        let candidate = try makeRPGQuickSlotRow(
            worldRecordID: worldRecordID, preferences: candidatePreferences,
            revision: expected.revision + 1,
            migrationOriginDigest: expected.migrationOriginDigest,
            migrationOriginRevision: expected.migrationOriginRevision)
        let row = try withStorageRank {
            let facade = try coordinator.rpgLocalPreferences()
            return try facade.compareAndSwap(
                expectedRevision: expected.revision, expectedDigest: expected.digest.data,
                candidate: candidate)
        }
        return try decodeRPGQuickSlotRow(row)
    }

    public func materializeLegacyRPGQuickSlotPreferences(
        worldRecordID: String, legacy: RPGQuickSlotPreferences
    ) throws -> RPGLegacyQuickSlotMigrationResult {
        let sourceDigest = try rpgLegacyQuickSlotSourceDigest(legacy)
        let destination = try makeRPGQuickSlotRow(
            worldRecordID: worldRecordID, preferences: legacy, revision: 1)
        let receipt = try withStorageRank {
            let facade = try coordinator.rpgLocalPreferences()
            return try facade.materializeLegacy(
                sourceDigest: sourceDigest.data, absentDestination: destination)
        }
        guard LANV6Crypto.constantTimeEqual32(
            receipt.marker.sourceDigest, sourceDigest.data) else {
            throw ElysiumStorageError.schemaIntegrity
        }
        let snapshot = try decodeRPGQuickSlotRow(receipt.preference)
        guard let originDigest = snapshot.migrationOriginDigest,
              LANV6Crypto.constantTimeEqual32(
                originDigest.data, receipt.marker.destinationDigest),
              snapshot.migrationOriginRevision == receipt.marker.destinationRevision else {
            throw ElysiumStorageError.schemaIntegrity
        }
        return RPGLegacyQuickSlotMigrationResult(
            snapshot: snapshot, sourceDigest: sourceDigest,
            insertedDestination: receipt.insertedDestination)
    }

    public func chunkKey(_ worldId: String, _ dim: Int, _ cx: Int, _ cz: Int) -> String {
        "\(worldId):\(dim):\(cx),\(cz)"
    }

    public func getChunkKeys(_ worldId: String) -> Set<String> {
        guard let rows = try? withStorageRank({ try storage.listChunkKeys(world: worldId) }) else {
            return []
        }
        return Set(rows.map {
            chunkKey($0.world, Int($0.dimension), Int($0.chunkX), Int($0.chunkZ))
        })
    }

    public func getChunk(_ worldId: String, _ dim: Int, _ cx: Int, _ cz: Int) -> ChunkRecord? {
        guard let dimension = Int32(exactly: dim), let chunkX = Int32(exactly: cx),
              let chunkZ = Int32(exactly: cz),
              let key = try? ElysiumChunkStorageKey(world: worldId, dimension: dimension,
                                                   chunkX: chunkX, chunkZ: chunkZ),
              let blob = try? withStorageRank({ try storage.getChunkBlob(key: key) }) else {
            return nil
        }
        return decodeLegacyVCK(blob, key: chunkKey(worldId, dim, cx, cz), worldId: worldId,
                               dimension: dim, chunkX: cx, chunkZ: cz)
    }

    @discardableResult
    public func putChunks(_ records: [ChunkRecord]) -> Bool {
        var rows: [ElysiumChunkStorageRow] = []
        rows.reserveCapacity(records.count)
        for record in records {
            guard let dimension = Int32(exactly: record.dim),
                  let chunkX = Int32(exactly: record.cx),
                  let chunkZ = Int32(exactly: record.cz),
                  let data = encodeLegacyVCK(record),
                  let key = try? ElysiumChunkStorageKey(world: record.worldId,
                                                       dimension: dimension,
                                                       chunkX: chunkX, chunkZ: chunkZ),
                  let row = try? ElysiumChunkStorageRow(key: key, data: data) else { return false }
            rows.append(row)
        }
        return (try? withStorageRank { _ = try storage.putChunkBlobRows(rows) }) != nil
    }

    func decodeChunk(_ data: Data, key: String, worldId: String,
                     dim: Int, cx: Int, cz: Int) -> ChunkRecord? {
        decodeLegacyVCK(data, key: key, worldId: worldId,
                        dimension: dim, chunkX: cx, chunkZ: cz)
    }

    private func decodeJSONObject(_ json: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
    }

    private func encodeJSONObject(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(
            withJSONObject: sanitizeJSON(object), options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func checkedPlayerRowDigest(
        _ row: ElysiumPlayerJSONStorageRow
    ) throws -> SaveDBPlayerRowDigest {
        var digest = SHA256()
        digest.update(data: Data("Pebble/player-row/exact-json/v1\0".utf8))
        let worldBytes = Data(row.world.utf8)
        digest.update(data: Data([
            UInt8(truncatingIfNeeded: UInt32(worldBytes.count) >> 24),
            UInt8(truncatingIfNeeded: UInt32(worldBytes.count) >> 16),
            UInt8(truncatingIfNeeded: UInt32(worldBytes.count) >> 8),
            UInt8(truncatingIfNeeded: UInt32(worldBytes.count)),
        ]))
        digest.update(data: worldBytes)
        let jsonBytes = Data(row.json.utf8)
        let jsonCount = UInt64(jsonBytes.count)
        digest.update(data: Data((0..<8).reversed().map {
            UInt8(truncatingIfNeeded: jsonCount >> UInt64($0 * 8))
        }))
        digest.update(data: jsonBytes)
        return try SaveDBPlayerRowDigest(data: Data(digest.finalize()))
    }

    private func checkedPlayerSnapshot(
        _ row: ElysiumPlayerJSONStorageRow
    ) throws -> SaveDBPlayerRowSnapshot {
#if DEBUG
        precondition(elysiumCurrentLockRank() == 0)
#endif
        guard let decoded = decodeJSONObject(row.json) else {
            throw SaveDBPlayerRowError.invalidStoredRow
        }
        return SaveDBPlayerRowSnapshot(
            worldID: row.world, data: decoded,
            canonicalDigest: try checkedPlayerRowDigest(row))
    }

    private func mapPlayerRowStorageError(_ error: Error) -> SaveDBPlayerRowError {
        if let transaction = error as? ElysiumStorageTransactionFailure {
            guard transaction.rollback == nil, transaction.terminal == nil else {
                return .persistenceFailed
            }
            return mapPlayerRowStorageError(transaction.primary)
        }
        if let statement = error as? ElysiumStorageStatementFailure {
            _ = statement
            return .persistenceFailed
        }
        switch error as? ElysiumStorageError {
        case .invalidValue, .invalidStorageClass, .invalidUTF8, .limitExceeded:
            return .invalidStoredRow
        default:
            return .persistenceFailed
        }
    }

    public func getPlayerChecked(_ worldId: String) throws -> SaveDBPlayerRowSnapshot? {
#if DEBUG
        precondition(elysiumCurrentLockRank() == 0)
#endif
        guard (try? ElysiumPlayerJSONStorageRow(world: worldId, json: "{}")) != nil else {
            throw SaveDBPlayerRowError.invalidCandidate
        }
        let row: ElysiumPlayerJSONStorageRow?
        do {
            row = try withStorageRank { try storage.getPlayerJSON(world: worldId) }
        } catch {
            throw mapPlayerRowStorageError(error)
        }
#if DEBUG
        precondition(elysiumCurrentLockRank() == 0)
#endif
        guard let row else { return nil }
        do {
            return try checkedPlayerSnapshot(row)
        } catch let error as SaveDBPlayerRowError {
            throw error
        } catch {
            throw SaveDBPlayerRowError.invalidStoredRow
        }
    }

    public func compareAndSwapPlayerChecked(
        _ worldId: String, expected: SaveDBPlayerRowExpectation,
        candidate: [String: Any]
    ) throws -> SaveDBPlayerRowSnapshot {
#if DEBUG
        precondition(elysiumCurrentLockRank() == 0)
        resetPlayerCASRanks()
        recordPlayerCASRank()
#endif
        guard let json = encodeJSONObject(candidate) else {
            throw SaveDBPlayerRowError.invalidCandidate
        }
        let row: ElysiumPlayerJSONStorageRow
        do {
            row = try ElysiumPlayerJSONStorageRow(world: worldId, json: json)
        } catch {
            throw SaveDBPlayerRowError.invalidCandidate
        }
#if DEBUG
        recordPlayerCASRank()
        observePlayerCASBarrier(.beforeFacade)
#endif
        let storageExpectation: ElysiumPlayerJSONExpectedRowState
        switch expected {
        case .absent:
            storageExpectation = .absent
        case let .present(digest):
            do { storageExpectation = .present(try ElysiumPlayerJSONRowDigest(data: digest.data)) }
            catch { throw SaveDBPlayerRowError.invalidCandidate }
        }
        let result: ElysiumPlayerJSONCompareAndSwapResult
        do {
            result = try withStorageRank {
#if DEBUG
                preconditionElysiumLockRank(.saveDB)
                recordPlayerCASRank()
#endif
                return try storage.compareAndSwapPlayerJSON(
                    expected: storageExpectation, candidate: row)
            }
        } catch {
            throw mapPlayerRowStorageError(error)
        }
#if DEBUG
        precondition(elysiumCurrentLockRank() == 0)
        observePlayerCASBarrier(.afterCommit)
        recordPlayerCASRank()
#endif
        switch result {
        case .conflict:
            throw SaveDBPlayerRowError.conflict
        case let .committed(stored):
            guard stored == row else { throw SaveDBPlayerRowError.persistenceFailed }
            do { return try checkedPlayerSnapshot(stored) }
            catch { throw SaveDBPlayerRowError.persistenceFailed }
        }
    }

    public func getPlayer(_ worldId: String) -> [String: Any]? {
        guard let json = try? withStorageRank({ try storage.getLegacyPlayerJSON(world: worldId) })
        else { return nil }
        return decodeJSONObject(json)
    }

    public func putPlayer(_ worldId: String, _ data: [String: Any]) {
        guard let json = encodeJSONObject(data),
              let row = try? ElysiumPlayerJSONStorageRow(world: worldId, json: json) else { return }
        try? withStorageRank { try storage.putPlayerJSON(row) }
    }

    public func getLANClientResume(_ hostWorldKey: String) -> [String: Any]? {
        guard let json = try? withStorageRank({
            try storage.getLegacyLANClientResumeJSON(hostWorld: hostWorldKey)
        }) else { return nil }
        return decodeJSONObject(json)
    }

    private static func normalizedResumeUpdated(_ value: Any?, now: () -> Double) -> Double {
        if let number = value as? NSNumber {
            let candidate = number.doubleValue
            if candidate.isNaN { return 0 }
            if candidate == .infinity { return .greatestFiniteMagnitude }
            if candidate == -.infinity { return -.greatestFiniteMagnitude }
            return candidate
        }
        let candidate = now()
        return candidate.isFinite ? candidate : 0
    }

    public func putLANClientResume(_ hostWorldKey: String, _ data: [String: Any]) {
        guard let json = encodeJSONObject(data) else { return }
        let updated = Self.normalizedResumeUpdated(data["updated"]) {
            Date().timeIntervalSince1970 * 1000
        }
        guard let row = try? ElysiumLANClientResumeStorageRow(
            hostWorld: hostWorldKey, json: json, updated: updated) else { return }
        try? withStorageRank { try storage.putLANClientResumeJSON(row) }
    }

    public func deleteLANClientResume(_ hostWorldKey: String) {
        _ = try? withStorageRank { try storage.deleteLANClientResumeJSON(hostWorld: hostWorldKey) }
    }

    public func getLANPlayer(world: String, playerID: String) -> [String: Any]? {
        guard let json = try? withStorageRank({
            try storage.getLegacyLANPlayerJSON(world: world, playerID: playerID)
        }) else { return nil }
        return decodeJSONObject(json)
    }

    public func putLANPlayer(world: String, playerID: String, _ data: [String: Any]) {
        guard let json = encodeJSONObject(data),
              let row = try? ElysiumLANPlayerStorageRow(
                world: world, playerID: playerID, json: json,
                updated: Date().timeIntervalSince1970 * 1000) else { return }
        try? withStorageRank { try storage.putLANPlayerJSON(row) }
    }

    public func listLANPlayers(world: String) -> [(playerID: String, data: [String: Any])] {
        guard let rows = try? withStorageRank({ try storage.listLegacyLANPlayerJSON(world: world) })
        else { return [] }
        return rows.compactMap { row in
            decodeJSONObject(row.json).map { (playerID: row.playerID, data: $0) }
        }
    }

    public func deleteLANPlayer(world: String, playerID: String) {
        _ = try? withStorageRank {
            try storage.deleteLANPlayerJSON(world: world, playerID: playerID)
        }
    }

#if DEBUG
    func execRawLANPlayerInsertForTesting(world: String, playerID: String, json: String) {
        guard let row = try? ElysiumLANPlayerStorageRow(
            world: world, playerID: playerID, json: json,
            updated: Date().timeIntervalSince1970 * 1000) else { return }
        try? withStorageRank { try storage.putLANPlayerJSON(row) }
    }

    static func _testNormalizeResumeUpdated(_ value: Any?, now: Double) -> Double {
        normalizedResumeUpdated(value) { now }
    }

    static func _testMapStorageError(_ error: ElysiumStorageError,
                                     stage: SaveDBOpenError.Stage) -> SaveDBOpenError {
        mapStorageError(error, stage: stage)
    }
#endif

    public func getAdvancements(_ worldId: String) -> [String]? {
        guard let json = try? withStorageRank({ try storage.getLegacyAdvancementJSON(world: worldId) })
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String]
    }

    public func putAdvancements(_ worldId: String, _ ids: [String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: ids),
              let json = String(data: data, encoding: .utf8),
              let row = try? ElysiumAdvancementStorageRow(world: worldId, json: json) else { return }
        try? withStorageRank { try storage.putAdvancementJSON(row) }
    }

    public func listTemplates() -> [String] {
        (try? withStorageRank { try storage.listLegacyTemplateNames() }) ?? []
    }

    public func listTemplateSummaries() -> [ObjectTemplateSummary] {
        guard let candidates = try? withStorageRank({
            try storage.listLegacyTemplateSummaryCandidates()
        }) else { return [] }
        var output: [ObjectTemplateSummary] = []
        output.reserveCapacity(candidates.count)
        for candidate in candidates {
            if let sizeX = candidate.sizeX, let sizeY = candidate.sizeY,
               let sizeZ = candidate.sizeZ, let blockCount = candidate.blockCount,
               let blockEntityCount = candidate.blockEntityCount,
               let dominantBlock = candidate.dominantBlock,
               let dominantDisplay = candidate.dominantDisplay,
               blockCount > 0, !dominantBlock.isEmpty, !dominantDisplay.isEmpty {
                output.append(ObjectTemplateSummary(
                    name: candidate.name, sizeX: Int(sizeX), sizeY: Int(sizeY),
                    sizeZ: Int(sizeZ), blockCount: Int(blockCount),
                    blockEntityCount: Int(blockEntityCount),
                    dominantBlockName: dominantBlock,
                    dominantBlockDisplayName: dominantDisplay))
            } else if let value = try? getTemplate(named: candidate.name),
                      let summary = try? summarizeObjectTemplate(value) {
                output.append(summary)
            }
        }
        return output
    }

    public func getTemplate(named rawName: String) throws -> ObjectTemplate? {
        guard let name = normalizedTemplateName(rawName) else { throw TemplateError.invalidName }
        guard let content = try? withStorageRank({
            try storage.getLegacyTemplateContent(name: name)
        }) else { return nil }
        if (content.format ?? 1) >= 2, let data = content.data, !data.isEmpty {
            return try decodeObjectTemplate(data)
        }
        guard let json = content.json, !json.isEmpty else { return nil }
        return try decodeObjectTemplate(Data(json.utf8))
    }

    @discardableResult
    public func putTemplate(_ template: ObjectTemplate) throws -> Bool {
        guard let name = normalizedTemplateName(template.name) else { throw TemplateError.invalidName }
        var normalized = template
        normalized.name = name
        let data = try encodeObjectTemplate(normalized)
        let summary = try summarizeObjectTemplate(normalized)
        guard let sizeX = Int32(exactly: summary.sizeX),
              let sizeY = Int32(exactly: summary.sizeY),
              let sizeZ = Int32(exactly: summary.sizeZ),
              let blockCount = Int32(exactly: summary.blockCount),
              let blockEntityCount = Int32(exactly: summary.blockEntityCount),
              let primitiveSummary = try? ElysiumTemplateSummaryStorageRow(
                name: name, sizeX: sizeX, sizeY: sizeY, sizeZ: sizeZ,
                blockCount: blockCount, blockEntityCount: blockEntityCount,
                dominantBlock: summary.dominantBlockName,
                dominantDisplay: summary.dominantBlockDisplayName),
              let row = try? ElysiumTemplateStorageRow(
                summary: primitiveSummary, json: "",
                created: Date().timeIntervalSince1970 * 1000,
                format: 2, data: data) else { return false }
        return (try? withStorageRank { _ = try storage.putTemplateRow(row) }) != nil
    }

    @discardableResult
    public func deleteTemplate(named rawName: String) throws -> Bool {
        guard let name = normalizedTemplateName(rawName) else { throw TemplateError.invalidName }
        guard let changed = try? withStorageRank({ try storage.deleteTemplateRow(name: name) })
        else { return false }
        return changed > 0
    }
}
