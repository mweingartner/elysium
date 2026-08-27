// ObjectRecord.swift — object-graph-attributes (change 1a). design.md
// Decision 5 / spec `object-attribute-store` "ObjectRecord, entries and
// provenance". One persisted document per object: a bag of custom attribute
// entries plus a revision counter. `.script` is reserved for 1c (the scripts
// section is a sibling of `attrs` inside the same document, tolerated as
// empty here); an entry or section of unknown/unsupported shape is dropped on
// decode with a diagnostic, never the containing chunk/entity/world record.

import ElysiumScript

/// One entry in an `ObjectRecord`'s bag. `.script` carries a `ScriptRecord`
/// (script-runtime, change 1c) — 1a never constructed one, but the case
/// shape (and this file's decode tolerance for a "scripts" section) has been
/// here since 1a so this change adds no new document shape, only a
/// non-empty one.
public enum AttributeEntry {
    case value(AttrValue, readonly: Bool, provenance: Provenance)
    case script(ScriptRecord)
}

/// Who created an attribute entry and when, for diagnostics and (later) trust
/// decisions — never enforcement by itself.
public struct Provenance: Equatable, Sendable {
    public enum Author: Equatable, Sendable {
        case player
        /// `model` ≤ 64 bytes (reserved for phase 2 AI writes).
        case ai(model: String)
        /// Reserved for 1c script writes.
        case script(owner: ObjectRef, name: String)
        /// lan-client-parity (change 4): a validated `scriptIntent` from a
        /// connected guest, executed on the host through the same executors
        /// as `.player`. `peer` is the socket-bound `peer.playerID` (never a
        /// wire-claimed value), ≤ 128 bytes — the same identity the LAN
        /// transport already trusts everywhere else.
        case lan(peer: String)
    }

    public var createdBy: Author
    public var createdTick: Int64

    public init(createdBy: Author, createdTick: Int64) {
        self.createdBy = createdBy
        self.createdTick = createdTick
    }
}

/// One bag of custom attributes/scripts plus a separate namespace of persistent
/// custom-event declarations for one object (block cell, entity/player, world
/// or a dimension).
public struct ObjectRecord {
    public var entries: [String: AttributeEntry]
    public var eventDeclarations: [String: CustomEventDeclaration]
    public var revision: UInt64

    public init(
        entries: [String: AttributeEntry] = [:],
        eventDeclarations: [String: CustomEventDeclaration] = [:],
        revision: UInt64 = 0
    ) {
        self.entries = entries
        self.eventDeclarations = eventDeclarations
        self.revision = revision
    }

    public var storageEntryCount: Int { entries.count + eventDeclarations.count }
    public var isEmpty: Bool { entries.isEmpty && eventDeclarations.isEmpty }
    public var hasScriptDefinitions: Bool {
        entries.values.contains { entry in
            if case .script = entry { return true }
            return false
        }
    }
}

// MARK: - name grammar

/// `[a-z][a-z0-9_]{0,31}` — every custom attribute name and every `Provenance
/// .script` author's `name` field.
public func isValidAttributeName(_ name: String) -> Bool {
    let bytes = Array(name.utf8)
    guard bytes.count >= 1, bytes.count <= 32 else { return false }
    guard bytes[0] >= UInt8(ascii: "a"), bytes[0] <= UInt8(ascii: "z") else { return false }
    for b in bytes.dropFirst() {
        let ok = (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: "_")
        if !ok { return false }
    }
    return true
}

/// Best-effort normalization hint for an invalid name (lowercased, invalid
/// bytes folded to `_`, forced to start with a letter, truncated to 32 bytes)
/// — offered in refusal messages, never applied silently.
public func normalizedAttributeNameHint(_ name: String) -> String? {
    var scalars: [UInt8] = []
    for b in name.lowercased().utf8 {
        let ok = (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
        scalars.append(ok ? b : UInt8(ascii: "_"))
    }
    guard !scalars.isEmpty else { return nil }
    if scalars[0] < UInt8(ascii: "a") || scalars[0] > UInt8(ascii: "z") {
        scalars.insert(UInt8(ascii: "a"), at: 0)
    }
    let truncated = Array(scalars.prefix(32))
    let candidate = String(decoding: truncated, as: UTF8.self)
    return isValidAttributeName(candidate) ? candidate : nil
}

/// Canonical ergonomic spelling used when trusted Lua or the bounded AI tool lane supplies a
/// custom attribute name. Unlike `normalizedAttributeNameHint`, this preserves camelCase word
/// boundaries (`doorRef` -> `door_ref`) before applying the strict persisted-name grammar.
public func normalizedScriptCustomAttributeName(_ raw: String) -> String {
    guard !isValidAttributeName(raw) else { return raw }
    var snake = ""
    var previousLower = false
    for character in raw {
        if character.isUppercase && previousLower { snake.append("_") }
        snake.append(Character(character.lowercased()))
        previousLower = character.isLowercase
    }
    if isValidAttributeName(snake) { return snake }
    return normalizedAttributeNameHint(snake) ?? raw
}

// MARK: - codec

/// Encodes/decodes one `ObjectRecord` as the canonical document
/// `{"attrs":{"<name>":{"by":"<author>","ro":<bool>,"t":<tick>,"v":<value>}},
/// "rev":<n>,"v":1}`. Decoding is tolerant per-entry (a malformed entry is
/// dropped with a diagnostic; the record survives) but refuses the whole
/// document when its own `"v"` is not `1` (Decision 5: "dropped with a
/// diagnostic, never the container" — the *caller* treats a `nil` result as
/// "no record", exactly like an absent one).
public enum ObjectRecordCodec {
    /// Security (plan) C26: `revision` is clamped to this bound at decode
    /// time (documented relative to the bound, like `WorldRecord.nextEntityId`'s
    /// own clamp) so `AttributeStore`'s overflow-safe `+1` on every mutation
    /// always has headroom and can never trap.
    public static let maxStoredRevision: UInt64 = UInt64.max - 1_000_000

    public static func encode(_ record: ObjectRecord) -> String {
        var out = "{\"attrs\":{"
        let names = record.entries.keys.sorted(by: utf8Less)
        var first = true
        for name in names {
            guard case .value(let value, let readonly, let provenance) = record.entries[name] else { continue }
            if !first { out += "," }
            first = false
            out += "\""
            out += name
            out += "\":{\"by\":"
            out += AttrValueCodec.encode(.string(encodeAuthor(provenance.createdBy)))
            out += ",\"ro\":"
            out += readonly ? "true" : "false"
            out += ",\"t\":"
            out += String(provenance.createdTick)
            out += ",\"v\":"
            out += AttrValueCodec.encode(value)
            out += "}"
        }
        out += "}"
        // script-runtime (change 1c), §6.7: "scripts' name/source/enabled/
        // author/createdTick" persist in a section of their own, sibling to
        // "attrs" — omitted entirely when there are none, matching every
        // other optional section this document uses.
        let scriptNames = names.filter { name in
            if case .script? = record.entries[name] { return true }
            return false
        }
        if !scriptNames.isEmpty {
            out += ",\"scripts\":{"
            var firstScript = true
            for name in scriptNames {
                guard case .script(let scriptRecord)? = record.entries[name] else { continue }
                if !firstScript { out += "," }
                firstScript = false
                out += "\""
                out += name
                out += "\":"
                out += ScriptRecordCodec.encode(scriptRecord)
            }
            out += "}"
        }
        // Persistent object-scoped custom-event declarations are an optional
        // sibling section. Keeping them outside `entries` preserves the
        // independent dotted event-name namespace.
        let eventNames = record.eventDeclarations.keys.sorted(by: utf8Less).filter { name in
            record.eventDeclarations[name]?.kind.rawValue == name
        }
        if !eventNames.isEmpty {
            out += ",\"events\":{"
            for (index, name) in eventNames.enumerated() {
                guard let declaration = record.eventDeclarations[name] else { continue }
                if index > 0 { out += "," }
                out += AttrValueCodec.encode(.string(name))
                out += ":{\"by\":"
                out += AttrValueCodec.encode(.string(encodeAuthor(declaration.provenance.createdBy)))
                out += ",\"fields\":{"
                for (fieldIndex, field) in declaration.fields.sorted(by: { utf8Less($0.name, $1.name) }).enumerated() {
                    if fieldIndex > 0 { out += "," }
                    out += AttrValueCodec.encode(.string(field.name))
                    out += ":"
                    out += AttrValueCodec.encode(.string(field.typeToken))
                }
                out += "}"
                if let summary = declaration.summary {
                    out += ",\"summary\":"
                    out += AttrValueCodec.encode(.string(summary))
                }
                out += ",\"t\":\(declaration.provenance.createdTick)}"
            }
            out += "}"
        }
        out += ",\"rev\":\(record.revision),\"v\":1}"
        return out
    }

    /// `diagnostic` is called once per dropped entry/section (name + reason),
    /// never for the top-level document itself (a whole-document refusal is
    /// the `nil` return value; the caller logs that once at the call site).
    public static func decode(
        _ text: String, caps: ScriptingStorageCaps, diagnostic: (String) -> Void = { _ in }
    ) -> ObjectRecord? {
        // Test N2: a pre-decode text-size bound, before any allocation — the entity/
        // player/world-record document paths (`Entity.load`'s "object" key,
        // `GameCore+Scripting.loadWorldObjectRecords`) call this directly with no cap
        // of their own, unlike the chunk-tail path (`decodeChunkTailObjects`, which
        // already bounds each entry to ≤64 KiB before ever reaching a codec). The
        // world/dimension bag's own tighter `maxWorldDimRecordTextBytes` is enforced
        // at write time by `AttributeStore`; this is the read-side backstop against a
        // hand-edited or corrupt row using the general per-object bound.
        guard text.utf8.count <= caps.maxRecordTextBytes else { return nil }
        let bytes = Array(text.utf8)
        var i = 0
        guard consume(bytes, &i, "{") else { return nil }
        var attrsText: (Int, Int)? = nil // byte range of the "attrs" object, parsed after the whole shell is walked
        var scriptsText: (Int, Int)? = nil // byte range of the "scripts" object (change 1c)
        var eventsText: (Int, Int)? = nil // byte range of persistent custom-event declarations
        var revision: UInt64?
        var version: Int?
        if peek(bytes, i) == UInt8(ascii: "}") {
            i += 1
        } else {
            while true {
                guard let (key, afterKey) = parseKeyString(bytes, i) else { return nil }
                i = afterKey
                guard consume(bytes, &i, ":") else { return nil }
                switch key {
                case "attrs":
                    let start = i
                    guard let after = skipValue(bytes, i) else { return nil }
                    attrsText = (start, after)
                    i = after
                case "scripts":
                    // script-runtime (change 1c): the byte range is walked
                    // (never interpreted) here so the outer shell parse stays
                    // in one pass; `decodeScriptsObject` below does the real
                    // per-entry work, exactly like "attrs".
                    let start = i
                    guard let after = skipValue(bytes, i) else { return nil }
                    scriptsText = (start, after)
                    i = after
                case "events":
                    let start = i
                    guard let after = skipValue(bytes, i) else { return nil }
                    eventsText = (start, after)
                    i = after
                case "rev":
                    // Security (plan) C26: strict token, clamped to
                    // 0...(UInt64.max - 1_000_000) so a hostile/corrupt
                    // maximal revision can never make a later bump trap.
                    guard let (v, after) = parseStrictUInt64(bytes, i) else { return nil }
                    revision = min(v, Self.maxStoredRevision)
                    i = after
                case "v":
                    guard let (v, after) = parseStrictInt64(bytes, i) else { return nil }
                    version = Int(v)
                    i = after
                default:
                    guard let after = skipValue(bytes, i) else { return nil }
                    i = after
                }
                if peek(bytes, i) == UInt8(ascii: ",") { i += 1; continue }
                if peek(bytes, i) == UInt8(ascii: "}") { i += 1; break }
                return nil
            }
        }
        guard i == bytes.count else { return nil }
        guard version == 1 else { return nil }
        var record = ObjectRecord(entries: [:], eventDeclarations: [:], revision: revision ?? 0)
        var entries: [String: AttributeEntry] = [:]
        if let (attrsStart, attrsEnd) = attrsText,
            let decoded = decodeAttrsObject(bytes, attrsStart, attrsEnd, caps: caps, diagnostic: diagnostic) {
            entries = decoded
        }
        // script-runtime (change 1c): scripts share the same name namespace
        // as attrs (§6.0) but live in the sibling "scripts" section — merge
        // them in, never overwriting a name already claimed by an attr
        // (a name collision between the two sections is itself malformed
        // input; the attr wins and the script entry is dropped with a
        // diagnostic, same tolerance discipline as every other bad entry).
        if let (scriptsStart, scriptsEnd) = scriptsText {
            let scripts = decodeScriptsObject(bytes, scriptsStart, scriptsEnd, caps: caps, diagnostic: diagnostic)
            var scriptCount = 0
            for name in scripts.keys.sorted(by: utf8Less) {
                guard let scriptRecord = scripts[name] else { continue }
                if entries[name] != nil {
                    diagnostic("dropped script '\(name)': name already used by an attribute")
                    continue
                }
                guard scriptCount < maxScriptsPerObject else {
                    diagnostic("dropped script '\(name)': too many scripts")
                    continue
                }
                guard entries.count < caps.maxEntriesPerObject else {
                    diagnostic("dropped script '\(name)': too many entries")
                    continue
                }
                entries[name] = .script(scriptRecord)
                scriptCount += 1
            }
        }
        record.entries = entries
        if let (eventsStart, eventsEnd) = eventsText {
            let declarations = decodeEventsObject(
                bytes, eventsStart, eventsEnd, caps: caps, diagnostic: diagnostic
            )
            for name in declarations.keys.sorted(by: utf8Less) {
                guard let declaration = declarations[name] else { continue }
                guard record.eventDeclarations.count < caps.maxEventDeclarationsPerObject else {
                    diagnostic("dropped event '\(name)': too many declarations")
                    continue
                }
                guard record.storageEntryCount < caps.maxEntriesPerObject else {
                    diagnostic("dropped event '\(name)': too many entries")
                    continue
                }
                record.eventDeclarations[name] = declaration
            }
        }
        return record
    }

    /// Tolerant per-entry decode for the optional v1 `events` section. A bad
    /// declaration never drops an otherwise valid ObjectRecord.
    private static func decodeEventsObject(
        _ bytes: [UInt8], _ start: Int, _ end: Int, caps: ScriptingStorageCaps,
        diagnostic: (String) -> Void
    ) -> [String: CustomEventDeclaration] {
        var i = start
        guard consume(bytes, &i, "{") else { return [:] }
        var result: [String: CustomEventDeclaration] = [:]
        if peek(bytes, i) == UInt8(ascii: "}") { return result }
        while true {
            guard let (name, afterName) = parseKeyString(bytes, i) else { return result }
            i = afterName
            guard consume(bytes, &i, ":") else { return result }
            let entryStart = i
            guard let entryEnd = skipValue(bytes, i) else { return result }
            i = entryEnd
            if result[name] == nil,
               let declaration = decodeEventDeclaration(
                   bytes, entryStart, entryEnd, name: name, caps: caps
               ) {
                result[name] = declaration
            } else {
                diagnostic("dropped event '\(name)': invalid name, duplicate, or malformed declaration")
            }
            if peek(bytes, i) == UInt8(ascii: ",") { i += 1; continue }
            if peek(bytes, i) == UInt8(ascii: "}") { i += 1; break }
            return result
        }
        guard i == end else { return [:] }
        return result
    }

    private static func decodeEventDeclaration(
        _ bytes: [UInt8], _ start: Int, _ end: Int, name: String,
        caps: ScriptingStorageCaps
    ) -> CustomEventDeclaration? {
        guard case .success(.map(let map)) = AttrValueCodec.decode(
            String(decoding: bytes[start..<end], as: UTF8.self), caps: caps
        ) else { return nil }
        guard case .string(let authorText)? = map["by"], let author = decodeAuthor(authorText) else { return nil }
        guard case .int(let tick)? = map["t"], tick >= 0 else { return nil }
        guard case .map(let rawFields)? = map["fields"] else { return nil }
        var fields: [CustomEventField] = []
        fields.reserveCapacity(min(rawFields.count, caps.maxEventFieldsPerDeclaration))
        for fieldName in rawFields.keys.sorted(by: utf8Less) {
            guard case .string(let token)? = rawFields[fieldName],
                  let field = CustomEventField(name: fieldName, typeToken: token) else { return nil }
            fields.append(field)
        }
        let summary: String?
        switch map["summary"] {
        case nil: summary = nil
        case .string(let value)?: summary = value
        default: return nil
        }
        guard case .success(let validated) = validateCustomEventDeclaration(
            name: name, fields: fields, summary: summary, caps: caps
        ) else { return nil }
        return CustomEventDeclaration(
            kind: validated.kind, fields: validated.fields, summary: summary,
            provenance: Provenance(createdBy: author, createdTick: tick)
        )
    }

    /// script-runtime (change 1c). Tolerant per-entry decode matching
    /// `decodeAttrsObject`'s discipline exactly: a malformed script entry (or
    /// an invalid/duplicate name) is dropped with a diagnostic, never the
    /// whole "scripts" section.
    private static func decodeScriptsObject(
        _ bytes: [UInt8], _ start: Int, _ end: Int, caps: ScriptingStorageCaps, diagnostic: (String) -> Void
    ) -> [String: ScriptRecord] {
        var i = start
        guard consume(bytes, &i, "{") else { return [:] }
        var result: [String: ScriptRecord] = [:]
        if peek(bytes, i) == UInt8(ascii: "}") { return result }
        while true {
            guard let (name, afterName) = parseKeyString(bytes, i) else { return result }
            i = afterName
            guard consume(bytes, &i, ":") else { return result }
            let entryStart = i
            guard let entryEnd = skipValue(bytes, i) else { return result }
            i = entryEnd
            if isValidAttributeName(name), result[name] == nil,
                let record = ScriptRecordCodec.decode(bytes, entryStart, entryEnd, name: name) {
                result[name] = record
            } else {
                diagnostic("dropped script '\(name)': invalid name, duplicate, or malformed entry")
            }
            if peek(bytes, i) == UInt8(ascii: ",") { i += 1; continue }
            if peek(bytes, i) == UInt8(ascii: "}") { i += 1; break }
            return result
        }
        return result
    }

    private static func decodeAttrsObject(
        _ bytes: [UInt8], _ start: Int, _ end: Int, caps: ScriptingStorageCaps, diagnostic: (String) -> Void
    ) -> [String: AttributeEntry]? {
        var i = start
        guard consume(bytes, &i, "{") else { return nil }
        var result: [String: AttributeEntry] = [:]
        if peek(bytes, i) == UInt8(ascii: "}") { return result }
        while true {
            guard let (name, afterName) = parseKeyString(bytes, i) else { return nil }
            i = afterName
            guard consume(bytes, &i, ":") else { return nil }
            let entryStart = i
            guard let entryEnd = skipValue(bytes, i) else { return nil }
            i = entryEnd
            if let entry = decodeEntry(bytes, entryStart, entryEnd, caps: caps) {
                if isValidAttributeName(name), result.count < caps.maxEntriesPerObject {
                    result[name] = entry
                } else {
                    diagnostic("dropped attribute '\(name)': invalid name or too many entries")
                }
            } else {
                diagnostic("dropped attribute '\(name)': malformed entry")
            }
            if peek(bytes, i) == UInt8(ascii: ",") { i += 1; continue }
            if peek(bytes, i) == UInt8(ascii: "}") { i += 1; break }
            return nil
        }
        guard i == end else { return nil }
        return result
    }

    private static func decodeEntry(
        _ bytes: [UInt8], _ start: Int, _ end: Int, caps: ScriptingStorageCaps
    ) -> AttributeEntry? {
        var i = start
        guard consume(bytes, &i, "{") else { return nil }
        var kind: String?
        var byText: String?
        var readonly: Bool?
        var tick: Int64?
        var valueRange: (Int, Int)?
        if peek(bytes, i) == UInt8(ascii: "}") {
            i += 1
        } else {
            while true {
                guard let (key, afterKey) = parseKeyString(bytes, i) else { return nil }
                i = afterKey
                guard consume(bytes, &i, ":") else { return nil }
                switch key {
                case "k":
                    guard let (s, after) = parseStringValue(bytes, i) else { return nil }
                    kind = s
                    i = after
                case "by":
                    guard let (s, after) = parseStringValue(bytes, i) else { return nil }
                    byText = s
                    i = after
                case "ro":
                    guard let (b, after) = parseBool(bytes, i) else { return nil }
                    readonly = b
                    i = after
                case "t":
                    // Security (plan) C26: strict token, Int64-range checked, and (Test
                    // N1) non-negative per the condition's own letter — a negative tick
                    // is a malformed entry, dropped with the others, not silently kept.
                    guard let (v, after) = parseStrictInt64(bytes, i), v >= 0 else { return nil }
                    tick = v
                    i = after
                case "v":
                    let vStart = i
                    guard let after = skipValue(bytes, i) else { return nil }
                    valueRange = (vStart, after)
                    i = after
                default:
                    guard let after = skipValue(bytes, i) else { return nil }
                    i = after
                }
                if peek(bytes, i) == UInt8(ascii: ",") { i += 1; continue }
                if peek(bytes, i) == UInt8(ascii: "}") { i += 1; break }
                return nil
            }
        }
        guard i == end else { return nil }
        // A present, non-empty "k" names a kind this change does not
        // implement (1a has no recognized kind other than the implicit
        // "value" entry) — refuse rather than guess.
        if let kind, !kind.isEmpty { _ = kind; return nil }
        guard let byText, let author = decodeAuthor(byText) else { return nil }
        guard let readonly else { return nil }
        guard let tick else { return nil }
        guard let (vStart, vEnd) = valueRange else { return nil }
        guard case .success(let value) = AttrValueCodec.decode(
            String(decoding: bytes[vStart..<vEnd], as: UTF8.self), caps: caps
        ) else { return nil }
        return .value(value, readonly: readonly, provenance: Provenance(createdBy: author, createdTick: tick))
    }

    // MARK: - Author text

    private static func encodeAuthor(_ author: Provenance.Author) -> String {
        switch author {
        case .player: return "player"
        case .ai(let model): return "ai:\(model)"
        case .script(let owner, let name): return "script:\(owner.canonical):\(name)"
        case .lan(let peer): return "lan:\(peer)"
        }
    }

    private static func decodeAuthor(_ s: String) -> Provenance.Author? {
        if s == "player" { return .player }
        if s.hasPrefix("ai:") {
            let model = String(s.dropFirst(3))
            guard !model.isEmpty, model.utf8.count <= 64 else { return nil }
            return .ai(model: model)
        }
        if s.hasPrefix("script:") {
            let rest = s.dropFirst(7)
            guard let lastColon = rest.lastIndex(of: ":") else { return nil }
            let refText = String(rest[rest.startIndex..<lastColon])
            let name = String(rest[rest.index(after: lastColon)...])
            guard let ref = ObjectRef.parse(refText), isValidAttributeName(name) else { return nil }
            return .script(owner: ref, name: name)
        }
        if s.hasPrefix("lan:") {
            let peer = String(s.dropFirst(4))
            guard !peer.isEmpty, peer.utf8.count <= 128 else { return nil }
            return .lan(peer: peer)
        }
        return nil
    }

    // MARK: - minimal tolerant JSON-shell primitives (outer document only —
    // attribute *values* always go through `AttrValueCodec`'s own strict
    // parser; these only need to walk the fixed envelope around them and
    // skip sections this change does not interpret).

    private static func peek(_ bytes: [UInt8], _ i: Int) -> UInt8? { i < bytes.count ? bytes[i] : nil }

    private static func consume(_ bytes: [UInt8], _ i: inout Int, _ c: Character) -> Bool {
        guard peek(bytes, i) == c.asciiValue else { return false }
        i += 1
        return true
    }

    private static func parseKeyString(_ bytes: [UInt8], _ i: Int) -> (String, Int)? {
        parseStringValue(bytes, i)
    }

    private static func parseStringValue(_ bytes: [UInt8], _ start: Int) -> (String, Int)? {
        var i = start
        guard peek(bytes, i) == UInt8(ascii: "\"") else { return nil }
        i += 1
        var out: [UInt8] = []
        while true {
            guard let c = peek(bytes, i) else { return nil }
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard let e = peek(bytes, i) else { return nil }
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    guard i + 4 < bytes.count else { return nil }
                    guard let hi = hexVal(bytes[i + 1]), let m1 = hexVal(bytes[i + 2]),
                          let m2 = hexVal(bytes[i + 3]), let lo = hexVal(bytes[i + 4]) else { return nil }
                    let value = (hi << 12) | (m1 << 8) | (m2 << 4) | lo
                    guard let scalar = Unicode.Scalar(value) else { return nil }
                    out.append(contentsOf: Array(String(scalar).utf8))
                    i += 4
                default:
                    return nil
                }
                i += 1
            } else if c < 0x20 {
                return nil
            } else {
                out.append(c)
                i += 1
            }
            if out.count > 1 << 20 { return nil } // generous, non-authoritative backstop
        }
        return (String(decoding: out, as: UTF8.self), i)
    }

    private static func hexVal(_ b: UInt8) -> UInt32? {
        switch b {
        case 0x30...0x39: return UInt32(b - 0x30)
        case 0x61...0x66: return UInt32(b - 0x61 + 10)
        case 0x41...0x46: return UInt32(b - 0x41 + 10)
        default: return nil
        }
    }

    /// Security (plan) C26: the same strict canonical-decimal grammar as
    /// `ObjectRef`'s (no leading `+`, no leading zeros except the literal
    /// `"0"`, digits only) — used for every persisted integer this codec
    /// reads (`rev`, `t`, the outer `v`), so a hand-edited or corrupt value
    /// is refused rather than silently accepted via a lenient parse.
    private static func parseStrictUInt64(_ bytes: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var i = start
        guard let d0 = peek(bytes, i), d0 >= 0x30, d0 <= 0x39 else { return nil }
        let tokenStart = i
        if d0 == UInt8(ascii: "0") {
            i += 1
            if let n = peek(bytes, i), n >= 0x30, n <= 0x39 { return nil }
        } else {
            while let d = peek(bytes, i), d >= 0x30, d <= 0x39 { i += 1 }
        }
        guard let v = UInt64(String(decoding: bytes[tokenStart..<i], as: UTF8.self)) else { return nil }
        return (v, i)
    }

    private static func parseStrictInt64(_ bytes: [UInt8], _ start: Int) -> (Int64, Int)? {
        var i = start
        var negative = false
        if peek(bytes, i) == UInt8(ascii: "-") { negative = true; i += 1 }
        guard let d0 = peek(bytes, i), d0 >= 0x30, d0 <= 0x39 else { return nil }
        let digitsStart = i
        if d0 == UInt8(ascii: "0") {
            i += 1
            if let n = peek(bytes, i), n >= 0x30, n <= 0x39 { return nil }
        } else {
            while let d = peek(bytes, i), d >= 0x30, d <= 0x39 { i += 1 }
        }
        if negative, bytes[digitsStart..<i].count == 1, bytes[digitsStart] == UInt8(ascii: "0") { return nil } // "-0"
        guard let v = Int64(String(decoding: bytes[start..<i], as: UTF8.self)) else { return nil }
        return (v, i)
    }

    private static func parseBool(_ bytes: [UInt8], _ start: Int) -> (Bool, Int)? {
        let trueBytes = Array("true".utf8)
        let falseBytes = Array("false".utf8)
        if start + trueBytes.count <= bytes.count, Array(bytes[start..<(start + trueBytes.count)]) == trueBytes {
            return (true, start + trueBytes.count)
        }
        if start + falseBytes.count <= bytes.count, Array(bytes[start..<(start + falseBytes.count)]) == falseBytes {
            return (false, start + falseBytes.count)
        }
        return nil
    }

    /// Advances past one well-formed JSON value (string/number/object/array/
    /// literal) without interpreting it — used for "scripts" and any unknown
    /// key. Returns `nil` on malformed input (never traps, never loops).
    private static func skipValue(_ bytes: [UInt8], _ start: Int) -> Int? {
        guard let c = peek(bytes, start) else { return nil }
        switch c {
        case UInt8(ascii: "\""):
            return parseStringValue(bytes, start).map { $0.1 }
        case UInt8(ascii: "{"):
            var i = start + 1
            if peek(bytes, i) == UInt8(ascii: "}") { return i + 1 }
            while true {
                guard let (_, afterKey) = parseStringValue(bytes, i) else { return nil }
                i = afterKey
                guard consume(bytes, &i, ":") else { return nil }
                guard let after = skipValue(bytes, i) else { return nil }
                i = after
                if peek(bytes, i) == UInt8(ascii: ",") { i += 1; continue }
                if peek(bytes, i) == UInt8(ascii: "}") { return i + 1 }
                return nil
            }
        case UInt8(ascii: "["):
            var i = start + 1
            if peek(bytes, i) == UInt8(ascii: "]") { return i + 1 }
            while true {
                guard let after = skipValue(bytes, i) else { return nil }
                i = after
                if peek(bytes, i) == UInt8(ascii: ",") { i += 1; continue }
                if peek(bytes, i) == UInt8(ascii: "]") { return i + 1 }
                return nil
            }
        case UInt8(ascii: "t"):
            let t = Array("true".utf8)
            guard start + t.count <= bytes.count, Array(bytes[start..<(start + t.count)]) == t else { return nil }
            return start + t.count
        case UInt8(ascii: "f"):
            let f = Array("false".utf8)
            guard start + f.count <= bytes.count, Array(bytes[start..<(start + f.count)]) == f else { return nil }
            return start + f.count
        case UInt8(ascii: "n"):
            let n = Array("null".utf8)
            guard start + n.count <= bytes.count, Array(bytes[start..<(start + n.count)]) == n else { return nil }
            return start + n.count
        case UInt8(ascii: "-"), 0x30...0x39:
            var i = start
            if peek(bytes, i) == UInt8(ascii: "-") { i += 1 }
            guard let d0 = peek(bytes, i), d0 >= 0x30, d0 <= 0x39 else { return nil }
            _ = d0
            while let d = peek(bytes, i), d >= 0x30, d <= 0x39 { i += 1 }
            if peek(bytes, i) == UInt8(ascii: ".") {
                i += 1
                guard let d = peek(bytes, i), d >= 0x30, d <= 0x39 else { return nil }
                _ = d
                while let d = peek(bytes, i), d >= 0x30, d <= 0x39 { i += 1 }
            }
            if peek(bytes, i) == UInt8(ascii: "e") || peek(bytes, i) == UInt8(ascii: "E") {
                i += 1
                if peek(bytes, i) == UInt8(ascii: "+") || peek(bytes, i) == UInt8(ascii: "-") { i += 1 }
                guard let d = peek(bytes, i), d >= 0x30, d <= 0x39 else { return nil }
                _ = d
                while let d = peek(bytes, i), d >= 0x30, d <= 0x39 { i += 1 }
            }
            return i
        default:
            return nil
        }
    }
}
