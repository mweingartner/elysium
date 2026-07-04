// Persistence — a single SQLite database at
// ~/Library/Application Support/Pebble/pebble.db (WAL mode, fully mutexed):
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
import SQLite3

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
public let PEBBLE_VERSION = "1.1.0"

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
    public var gameRules: [String: Double]
    public var dragonKilled: Bool
    public var gatewaysSpawned: Int
    public var nextEntityId: Int

    public init(id: String, name: String, seed: Int32, gameMode: Int, difficulty: Int) {
        self.id = id
        self.name = name
        self.seed = seed
        self.gameMode = gameMode
        self.difficulty = difficulty
        lastPlayed = Date().timeIntervalSince1970 * 1000
        version = "pebble-\(PEBBLE_VERSION)"
        dims = ["0": DimState(), "1": DimState(), "2": DimState()]
        spawnX = 0
        spawnY = 80
        spawnZ = 0
        gameRules = [:]
        dragonKilled = false
        gatewaysSpawned = 0
        nextEntityId = 1
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
private func sanitizeJSON(_ v: Any) -> Any {
    if let d = v as? Double { return d.isFinite ? d : 0 }
    if let arr = v as? [Any] { return arr.map(sanitizeJSON) }
    if let dict = v as? [String: Any] { return dict.mapValues(sanitizeJSON) }
    return v
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class SaveDB {
    private var db: OpaquePointer?

    public convenience init() {
        self.init(databaseURL: vcSupportDir().appendingPathComponent("pebble.db"), migrateLegacy: true)
    }

    init(databaseURL url: URL, migrateLegacy: Bool) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK else {
            fatalError("pebble.db could not be opened: \(String(cString: sqlite3_errmsg(db)))")
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("PRAGMA busy_timeout=5000")
        exec("""
        CREATE TABLE IF NOT EXISTS worlds(
            id TEXT PRIMARY KEY, json TEXT NOT NULL, lastPlayed REAL NOT NULL DEFAULT 0)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS chunks(
            world TEXT NOT NULL, dim INTEGER NOT NULL, cx INTEGER NOT NULL, cz INTEGER NOT NULL,
            data BLOB NOT NULL, PRIMARY KEY(world, dim, cx, cz)) WITHOUT ROWID
        """)
        exec("CREATE TABLE IF NOT EXISTS player(world TEXT PRIMARY KEY, json TEXT NOT NULL)")
        exec("""
        CREATE TABLE IF NOT EXISTS lan_player_resume(
            hostWorld TEXT PRIMARY KEY, json TEXT NOT NULL, updated REAL NOT NULL DEFAULT 0)
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS lan_players(
            world TEXT NOT NULL, playerID TEXT NOT NULL, json TEXT NOT NULL,
            updated REAL NOT NULL DEFAULT 0, PRIMARY KEY(world, playerID))
        """)
        exec("CREATE TABLE IF NOT EXISTS advancements(world TEXT PRIMARY KEY, json TEXT NOT NULL)")
        exec("""
        CREATE TABLE IF NOT EXISTS templates(
            name TEXT PRIMARY KEY, json TEXT NOT NULL, created REAL NOT NULL DEFAULT 0)
        """)
        migrateTemplateStoreSchema()
        if migrateLegacy { migrateLegacySaves() }
    }

    deinit { sqlite3_close(db) }

    // ---- tiny statement helpers -------------------------------------------------
    @discardableResult
    private func exec(_ sql: String) -> Bool {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            print("[saves] exec failed: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(60))")
            return false
        }
        return true
    }

    /// prepare + bind + step a statement; row() is called once per result row.
    /// returns false (and logs) on prepare/step errors — a silently failed
    /// write (disk full, SQLITE_ERROR) is data loss
    @discardableResult
    private func run(_ sql: String, bind: ((OpaquePointer) -> Void)? = nil,
                     row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            print("[saves] prepare failed: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(60))")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { row?(stmt); rc = sqlite3_step(stmt) }
        if rc != SQLITE_DONE {
            print("[saves] step failed (\(rc)): \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(60))")
            return false
        }
        return true
    }

    private func bindText(_ stmt: OpaquePointer, _ idx: Int32, _ s: String) {
        sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT)
    }
    private func columnText(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        sqlite3_column_text(stmt, idx).map { String(cString: $0) }
    }
    private func bindBlob(_ stmt: OpaquePointer, _ idx: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            _ = sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
        }
    }
    private func columnBlob(_ stmt: OpaquePointer, _ idx: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, idx) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, idx)))
    }

    private func tableColumns(_ table: String) -> Set<String> {
        var out = Set<String>()
        run("PRAGMA table_info(\(table))", row: { stmt in
            if let name = self.columnText(stmt, 1) { out.insert(name) }
        })
        return out
    }

    private func migrateTemplateStoreSchema() {
        let columns = tableColumns("templates")
        if !columns.contains("format") { exec("ALTER TABLE templates ADD COLUMN format INTEGER NOT NULL DEFAULT 1") }
        if !columns.contains("data") { exec("ALTER TABLE templates ADD COLUMN data BLOB") }
        if !columns.contains("sizeX") { exec("ALTER TABLE templates ADD COLUMN sizeX INTEGER NOT NULL DEFAULT 0") }
        if !columns.contains("sizeY") { exec("ALTER TABLE templates ADD COLUMN sizeY INTEGER NOT NULL DEFAULT 0") }
        if !columns.contains("sizeZ") { exec("ALTER TABLE templates ADD COLUMN sizeZ INTEGER NOT NULL DEFAULT 0") }
        if !columns.contains("blockCount") { exec("ALTER TABLE templates ADD COLUMN blockCount INTEGER NOT NULL DEFAULT 0") }
        if !columns.contains("blockEntityCount") { exec("ALTER TABLE templates ADD COLUMN blockEntityCount INTEGER NOT NULL DEFAULT 0") }
        if !columns.contains("dominantBlock") { exec("ALTER TABLE templates ADD COLUMN dominantBlock TEXT NOT NULL DEFAULT ''") }
        if !columns.contains("dominantDisplay") { exec("ALTER TABLE templates ADD COLUMN dominantDisplay TEXT NOT NULL DEFAULT ''") }
    }

    // ---- worlds ---------------------------------------------------------------
    public func listWorlds() -> [WorldRecord] {
        var out: [WorldRecord] = []
        run("SELECT json FROM worlds", row: { stmt in
            if let json = self.columnText(stmt, 0),
               let rec = try? JSONDecoder().decode(WorldRecord.self, from: Data(json.utf8)) {
                out.append(rec)
            }
        })
        return out
    }
    public func getWorld(_ id: String) -> WorldRecord? {
        var rec: WorldRecord?
        run("SELECT json FROM worlds WHERE id=?", bind: { self.bindText($0, 1, id) }) { stmt in
            if let json = self.columnText(stmt, 0) {
                rec = try? JSONDecoder().decode(WorldRecord.self, from: Data(json.utf8))
            }
        }
        return rec
    }
    public func putWorld(_ rec: WorldRecord) {
        guard let data = try? JSONEncoder().encode(rec), let json = String(data: data, encoding: .utf8) else { return }
        run("INSERT OR REPLACE INTO worlds(id, json, lastPlayed) VALUES(?,?,?)", bind: { stmt in
            self.bindText(stmt, 1, rec.id)
            self.bindText(stmt, 2, json)
            sqlite3_bind_double(stmt, 3, rec.lastPlayed)
        })
    }
    public func deleteWorld(_ id: String) {
        exec("BEGIN")
        for table in ["worlds", "chunks", "player", "advancements"] {
            let col = table == "worlds" ? "id" : "world"
            run("DELETE FROM \(table) WHERE \(col)=?", bind: { self.bindText($0, 1, id) })
        }
        exec("COMMIT")
    }

    // ---- chunks ---------------------------------------------------------------
    public func chunkKey(_ worldId: String, _ dim: Int, _ cx: Int, _ cz: Int) -> String {
        "\(worldId):\(dim):\(cx),\(cz)"
    }

    /// all saved chunk keys for a world — lets the streamer skip the DB for fresh chunks
    public func getChunkKeys(_ worldId: String) -> Set<String> {
        var keys = Set<String>()
        run("SELECT dim, cx, cz FROM chunks WHERE world=?", bind: { self.bindText($0, 1, worldId) }) { stmt in
            let dim = Int(sqlite3_column_int(stmt, 0))
            let cx = Int(sqlite3_column_int(stmt, 1))
            let cz = Int(sqlite3_column_int(stmt, 2))
            keys.insert(self.chunkKey(worldId, dim, cx, cz))
        }
        return keys
    }

    public func getChunk(_ worldId: String, _ dim: Int, _ cx: Int, _ cz: Int) -> ChunkRecord? {
        var rec: ChunkRecord?
        run("SELECT data FROM chunks WHERE world=? AND dim=? AND cx=? AND cz=?", bind: { stmt in
            self.bindText(stmt, 1, worldId)
            sqlite3_bind_int(stmt, 2, Int32(dim))
            sqlite3_bind_int(stmt, 3, Int32(cx))
            sqlite3_bind_int(stmt, 4, Int32(cz))
        }) { stmt in
            if let bytes = sqlite3_column_blob(stmt, 0) {
                let count = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: bytes, count: count)
                rec = self.decodeChunk(data, key: self.chunkKey(worldId, dim, cx, cz),
                                       worldId: worldId, dim: dim, cx: cx, cz: cz)
            }
        }
        return rec
    }

    /// batch write — one transaction, mirrors the once-per-second save tick.
    /// false = the batch did not land (rolled back); callers must re-mark the
    /// chunks dirty or the edits are silently lost
    @discardableResult
    public func putChunks(_ records: [ChunkRecord]) -> Bool {
        guard !records.isEmpty else { return true }
        guard exec("BEGIN") else { return false }
        var ok = true
        for r in records {
            guard let data = encodeChunk(r) else { ok = false; continue }
            let wrote = run("INSERT OR REPLACE INTO chunks(world, dim, cx, cz, data) VALUES(?,?,?,?,?)", bind: { stmt in
                self.bindText(stmt, 1, r.worldId)
                sqlite3_bind_int(stmt, 2, Int32(r.dim))
                sqlite3_bind_int(stmt, 3, Int32(r.cx))
                sqlite3_bind_int(stmt, 4, Int32(r.cz))
                data.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(stmt, 5, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                }
            })
            ok = ok && wrote
        }
        if ok {
            ok = exec("COMMIT")
        } else {
            exec("ROLLBACK")
        }
        return ok
    }

    // binary container: "VCK1" | u8 flags | [u32 nBlocks, u16[] LE, u32 nBiomes, u8[]] | u32 jsonLen, json
    private func encodeChunk(_ r: ChunkRecord) -> Data? {
        var data = Data("VCK1".utf8)
        let hasBlocks = r.blocks != nil && r.biomes != nil
        data.append(hasBlocks ? 1 : 0)
        func putU32(_ v: Int) {
            var le = UInt32(v).littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        if hasBlocks {
            let blocks = r.blocks!, biomes = r.biomes!
            putU32(blocks.count)
            if !blocks.isEmpty {
                blocks.withUnsafeBufferPointer { bp in
                    bp.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: blocks.count * 2) { p in
                        data.append(p, count: blocks.count * 2)  // host LE on all Apple silicon/x86
                    }
                }
            }
            putU32(biomes.count)
            data.append(contentsOf: biomes)
        }
        var tail: [String: Any] = ["entities": r.entities.map(sanitizeJSON)]
        if let bes = r.blockEntities,
           let enc = try? JSONEncoder().encode(bes),
           let obj = try? JSONSerialization.jsonObject(with: enc) {
            tail["blockEntities"] = obj
        }
        guard let json = try? JSONSerialization.data(withJSONObject: tail) else { return nil }
        putU32(json.count)
        data.append(json)
        return data
    }

    func decodeChunk(_ data: Data, key: String, worldId: String, dim: Int, cx: Int, cz: Int) -> ChunkRecord? {
        var rec = ChunkRecord(key: key, worldId: worldId, dim: dim, cx: cx, cz: cz)
        var off = 0
        func readU32() -> Int? {
            guard off + 4 <= data.count else { return nil }
            let v = Int(data[off])
                | (Int(data[off + 1]) << 8)
                | (Int(data[off + 2]) << 16)
                | (Int(data[off + 3]) << 24)
            off += 4
            return v
        }
        guard data.count >= 5, data.prefix(4) == Data("VCK1".utf8) else { return nil }
        off = 4
        let flags = data[off]; off += 1
        guard flags & ~1 == 0 else { return nil }
        guard let dimCase = Dim(rawValue: dim) else { return nil }
        let info = dimInfo(dimCase)
        let expectedBlocks = CHUNK_W * CHUNK_W * info.height
        let expectedBiomes = 4 * 4 * ((info.height + 3) / 4)
        if flags & 1 != 0 {
            guard let nBlocks = readU32(), nBlocks == expectedBlocks,
                  off + nBlocks * 2 <= data.count else { return nil }
            var blocks = [UInt16](repeating: 0, count: nBlocks)
            data.subdata(in: off..<off + nBlocks * 2).withUnsafeBytes { raw in
                blocks.withUnsafeMutableBytes { dst in
                    dst.copyMemory(from: raw)
                }
            }
            off += nBlocks * 2
            // clamp corrupted ids — blockDefs[cell >> 4] is indexed unchecked
            // in hot paths, and one bad blob must not crash the game
            let maxId = UInt16(blockDefs.count)
            for i in 0..<blocks.count where (blocks[i] >> 4) >= maxId { blocks[i] = 0 }
            rec.blocks = blocks
            guard let nBiomes = readU32(), nBiomes == expectedBiomes,
                  off + nBiomes <= data.count else { return nil }
            rec.biomes = [UInt8](data.subdata(in: off..<off + nBiomes))
            off += nBiomes
        }
        guard let jsonLen = readU32(), off + jsonLen <= data.count,
              let tail = try? JSONSerialization.jsonObject(with: data.subdata(in: off..<off + jsonLen)) as? [String: Any]
        else { return nil }
        rec.entities = tail["entities"] as? [[String: Any]] ?? []
        if let rawBE = tail["blockEntities"],
           let bytes = try? JSONSerialization.data(withJSONObject: rawBE),
           let bes = try? JSONDecoder().decode([BlockEntityData].self, from: bytes) {
            rec.blockEntities = bes
        }
        return rec
    }

    // ---- player / advancements --------------------------------------------------
    public func getPlayer(_ worldId: String) -> [String: Any]? {
        var out: [String: Any]?
        run("SELECT json FROM player WHERE world=?", bind: { self.bindText($0, 1, worldId) }) { stmt in
            if let json = self.columnText(stmt, 0) {
                out = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            }
        }
        return out
    }
    public func putPlayer(_ worldId: String, _ data: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: sanitizeJSON(data)),
              let json = String(data: bytes, encoding: .utf8) else { return }
        run("INSERT OR REPLACE INTO player(world, json) VALUES(?,?)", bind: { stmt in
            self.bindText(stmt, 1, worldId)
            self.bindText(stmt, 2, json)
        })
    }
    public func getLANClientResume(_ hostWorldKey: String) -> [String: Any]? {
        var out: [String: Any]?
        run("SELECT json FROM lan_player_resume WHERE hostWorld=?", bind: { self.bindText($0, 1, hostWorldKey) }) { stmt in
            if let json = self.columnText(stmt, 0) {
                out = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            }
        }
        return out
    }
    public func putLANClientResume(_ hostWorldKey: String, _ data: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: sanitizeJSON(data)),
              let json = String(data: bytes, encoding: .utf8) else { return }
        let updatedNumber = data["updated"] as? NSNumber
        let updatedDouble = data["updated"] as? Double
        let updated = updatedNumber?.doubleValue ?? updatedDouble ?? Date().timeIntervalSince1970 * 1000
        run("INSERT OR REPLACE INTO lan_player_resume(hostWorld, json, updated) VALUES(?,?,?)", bind: { stmt in
            self.bindText(stmt, 1, hostWorldKey)
            self.bindText(stmt, 2, json)
            sqlite3_bind_double(stmt, 3, updated)
        })
    }
    public func deleteLANClientResume(_ hostWorldKey: String) {
        run("DELETE FROM lan_player_resume WHERE hostWorld=?", bind: { self.bindText($0, 1, hostWorldKey) })
    }

    // ---- LAN host-side per-guest player records ---------------------------------
    public func getLANPlayer(world: String, playerID: String) -> [String: Any]? {
        var out: [String: Any]?
        run("SELECT json FROM lan_players WHERE world=? AND playerID=?", bind: { stmt in
            self.bindText(stmt, 1, world)
            self.bindText(stmt, 2, playerID)
        }) { stmt in
            if let json = self.columnText(stmt, 0) {
                out = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            }
        }
        return out
    }
    public func putLANPlayer(world: String, playerID: String, _ data: [String: Any]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: sanitizeJSON(data)),
              let json = String(data: bytes, encoding: .utf8) else { return }
        run("INSERT OR REPLACE INTO lan_players(world, playerID, json, updated) VALUES(?,?,?,?)", bind: { stmt in
            self.bindText(stmt, 1, world)
            self.bindText(stmt, 2, playerID)
            self.bindText(stmt, 3, json)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970 * 1000)
        })
    }
    public func listLANPlayers(world: String) -> [(playerID: String, data: [String: Any])] {
        var out: [(playerID: String, data: [String: Any])] = []
        run("SELECT playerID, json FROM lan_players WHERE world=? ORDER BY playerID", bind: { stmt in
            self.bindText(stmt, 1, world)
        }) { stmt in
            guard let playerID = self.columnText(stmt, 0), let json = self.columnText(stmt, 1),
                  let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any]
            else { return }
            out.append((playerID: playerID, data: obj))
        }
        return out
    }
    public func deleteLANPlayer(world: String, playerID: String) {
        run("DELETE FROM lan_players WHERE world=? AND playerID=?", bind: { stmt in
            self.bindText(stmt, 1, world)
            self.bindText(stmt, 2, playerID)
        })
    }

    /// test-only: writes an arbitrary (possibly malformed) JSON string directly
    /// into lan_players, bypassing JSONSerialization, so tests can verify the
    /// readers fail closed on a corrupted row instead of crashing
    func execRawLANPlayerInsertForTesting(world: String, playerID: String, json: String) {
        run("INSERT OR REPLACE INTO lan_players(world, playerID, json, updated) VALUES(?,?,?,?)", bind: { stmt in
            self.bindText(stmt, 1, world)
            self.bindText(stmt, 2, playerID)
            self.bindText(stmt, 3, json)
            sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970 * 1000)
        })
    }

    public func getAdvancements(_ worldId: String) -> [String]? {
        var out: [String]?
        run("SELECT json FROM advancements WHERE world=?", bind: { self.bindText($0, 1, worldId) }) { stmt in
            if let json = self.columnText(stmt, 0) {
                out = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String]
            }
        }
        return out
    }
    public func putAdvancements(_ worldId: String, _ ids: [String]) {
        guard let bytes = try? JSONSerialization.data(withJSONObject: ids),
              let json = String(data: bytes, encoding: .utf8) else { return }
        run("INSERT OR REPLACE INTO advancements(world, json) VALUES(?,?)", bind: { stmt in
            self.bindText(stmt, 1, worldId)
            self.bindText(stmt, 2, json)
        })
    }

    // ---- object templates -------------------------------------------------------
    public func listTemplates() -> [String] {
        var out: [String] = []
        run("SELECT name FROM templates ORDER BY name", row: { stmt in
            if let name = self.columnText(stmt, 0) { out.append(name) }
        })
        return out
    }

    public func listTemplateSummaries() -> [ObjectTemplateSummary] {
        var out: [ObjectTemplateSummary] = []
        run("""
            SELECT name, sizeX, sizeY, sizeZ, blockCount, blockEntityCount, dominantBlock, dominantDisplay
            FROM templates ORDER BY name
            """, row: { stmt in
            guard let name = self.columnText(stmt, 0) else { return }
            let blockCount = Int(sqlite3_column_int(stmt, 4))
            let dominantBlock = self.columnText(stmt, 6) ?? ""
            let dominantDisplay = self.columnText(stmt, 7) ?? ""
            if blockCount > 0, !dominantBlock.isEmpty, !dominantDisplay.isEmpty {
                out.append(ObjectTemplateSummary(
                    name: name,
                    sizeX: Int(sqlite3_column_int(stmt, 1)),
                    sizeY: Int(sqlite3_column_int(stmt, 2)),
                    sizeZ: Int(sqlite3_column_int(stmt, 3)),
                    blockCount: blockCount,
                    blockEntityCount: Int(sqlite3_column_int(stmt, 5)),
                    dominantBlockName: dominantBlock,
                    dominantBlockDisplayName: dominantDisplay))
            } else if let template = try? self.getTemplate(named: name),
                      let summary = try? summarizeObjectTemplate(template) {
                out.append(summary)
            }
        })
        return out
    }

    public func getTemplate(named rawName: String) throws -> ObjectTemplate? {
        guard let name = normalizedTemplateName(rawName) else { throw TemplateError.invalidName }
        var format = 1
        var blob: Data?
        var json: String?
        run("SELECT format, data, json FROM templates WHERE name=?", bind: { self.bindText($0, 1, name) }, row: { stmt in
            format = Int(sqlite3_column_int(stmt, 0))
            blob = self.columnBlob(stmt, 1)
            json = self.columnText(stmt, 2)
        })
        if format >= 2, let blob, !blob.isEmpty {
            return try decodeObjectTemplate(blob)
        }
        guard let json, !json.isEmpty else { return nil }
        return try decodeObjectTemplate(Data(json.utf8))
    }

    @discardableResult
    public func putTemplate(_ template: ObjectTemplate) throws -> Bool {
        guard let name = normalizedTemplateName(template.name) else { throw TemplateError.invalidName }
        var normalized = template
        normalized.name = name
        let data = try encodeObjectTemplate(normalized)
        let summary = try summarizeObjectTemplate(normalized)
        return run("""
            INSERT OR REPLACE INTO templates(
                name, json, created, format, data, sizeX, sizeY, sizeZ,
                blockCount, blockEntityCount, dominantBlock, dominantDisplay)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            """, bind: { stmt in
            self.bindText(stmt, 1, name)
            self.bindText(stmt, 2, "")
            sqlite3_bind_double(stmt, 3, Date().timeIntervalSince1970 * 1000)
            sqlite3_bind_int(stmt, 4, 2)
            self.bindBlob(stmt, 5, data)
            sqlite3_bind_int(stmt, 6, Int32(summary.sizeX))
            sqlite3_bind_int(stmt, 7, Int32(summary.sizeY))
            sqlite3_bind_int(stmt, 8, Int32(summary.sizeZ))
            sqlite3_bind_int(stmt, 9, Int32(summary.blockCount))
            sqlite3_bind_int(stmt, 10, Int32(summary.blockEntityCount))
            self.bindText(stmt, 11, summary.dominantBlockName)
            self.bindText(stmt, 12, summary.dominantBlockDisplayName)
        })
    }

    @discardableResult
    public func deleteTemplate(named rawName: String) throws -> Bool {
        guard let name = normalizedTemplateName(rawName) else { throw TemplateError.invalidName }
        guard run("DELETE FROM templates WHERE name=?", bind: { self.bindText($0, 1, name) }) else { return false }
        return sqlite3_changes(db) > 0
    }

    // ---- legacy import ----------------------------------------------------------
    /// one-time import of the pre-1.0 loose-file layout (saves/worlds/*.json,
    /// saves/chunks/<id>/*.vck, …); the old folder is renamed, never deleted
    private func migrateLegacySaves() {
        let fm = FileManager.default
        let legacy = vcSupportDir().appendingPathComponent("saves", isDirectory: true)
        let worldsDir = legacy.appendingPathComponent("worlds")
        guard fm.fileExists(atPath: worldsDir.path),
              let files = try? fm.contentsOfDirectory(at: worldsDir, includingPropertiesForKeys: nil),
              !files.isEmpty else { return }

        var worlds = 0, chunks = 0
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let rec = try? JSONDecoder().decode(WorldRecord.self, from: data) else { continue }
            putWorld(rec)
            worlds += 1
            let id = rec.id
            if let pdata = try? Data(contentsOf: legacy.appendingPathComponent("player/\(id).json")),
               let pobj = (try? JSONSerialization.jsonObject(with: pdata)) as? [String: Any] {
                putPlayer(id, pobj)
            }
            if let adata = try? Data(contentsOf: legacy.appendingPathComponent("advancements/\(id).json")),
               let aobj = (try? JSONSerialization.jsonObject(with: adata)) as? [String] {
                putAdvancements(id, aobj)
            }
            let cdir = legacy.appendingPathComponent("chunks/\(id)", isDirectory: true)
            guard let cfiles = try? fm.contentsOfDirectory(at: cdir, includingPropertiesForKeys: nil) else { continue }
            exec("BEGIN")
            for cf in cfiles where cf.pathExtension == "vck" {
                let parts = cf.deletingPathExtension().lastPathComponent.split(separator: "_")
                guard parts.count == 3, let dim = Int(parts[0]), let cx = Int(parts[1]), let cz = Int(parts[2]),
                      let cdata = try? Data(contentsOf: cf) else { continue }
                run("INSERT OR REPLACE INTO chunks(world, dim, cx, cz, data) VALUES(?,?,?,?,?)", bind: { stmt in
                    self.bindText(stmt, 1, id)
                    sqlite3_bind_int(stmt, 2, Int32(dim))
                    sqlite3_bind_int(stmt, 3, Int32(cx))
                    sqlite3_bind_int(stmt, 4, Int32(cz))
                    cdata.withUnsafeBytes { raw in
                        _ = sqlite3_bind_blob(stmt, 5, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                    }
                })
                chunks += 1
            }
            exec("COMMIT")
        }
        let backup = vcSupportDir().appendingPathComponent("saves-legacy-backup")
        try? fm.moveItem(at: legacy, to: backup)
        print("[saves] migrated \(worlds) worlds, \(chunks) chunks into pebble.db (old files kept in saves-legacy-backup)")
        fflush(stdout)
    }
}
