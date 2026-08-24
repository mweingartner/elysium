// ObjectRef.swift — object-graph-attributes (change 1a). design.md Decision 1 /
// spec `object-graph-refs`. A strict value type for every kind of object the
// scripting/AI/inspector surfaces can name: the world, a dimension, a block, an
// entity (by persisted uid), the local player, or a LAN guest player (parsed now,
// resolved later — phase 3/4). `ObjectRef` is the anticorruption layer every later
// seam (Lua `h.ref`, AI payloads, LAN snapshots, saved `AttrValue.ref`) shares: one
// parser, one canonical printer, no ad hoc string handling anywhere else.

import Foundation

/// The five object kinds a ref can name (spec `object-graph-refs`: "world, dim,
/// block, entity, player"). `.lanPlayer` refs report kind `.player` — they name a
/// player, just not (yet) a live/resolvable one.
public enum ObjectKind: String, Hashable, Sendable, CaseIterable {
    case world, dim, block, entity, player
}

/// A strict, canonical reference to a scriptable object. Every case round-trips
/// through `canonical`/`parse(_:)`: `parse(canonical(r)) == r` and
/// `canonical(parse(s)) == s` for every accepted `s`.
public enum ObjectRef: Hashable, Sendable {
    case world
    case dimension(Dim)
    case block(dim: Dim, x: Int, y: Int, z: Int)
    case entity(uid: Int)
    case player
    /// Parsed and canonicalized now; resolves to `.unsupported` until LAN
    /// attribute parity (phase 3/4) — the format is fixed so no later change has
    /// to re-teach refs.
    case lanPlayer(peerID: String)

    public var kind: ObjectKind {
        switch self {
        case .world: return .world
        case .dimension: return .dim
        case .block: return .block
        case .entity: return .entity
        case .player, .lanPlayer: return .player
        }
    }

    /// The canonical printed form (spec table). Pure, side-effect-free.
    public var canonical: String {
        switch self {
        case .world:
            return "world"
        case .dimension(let d):
            return "dim:\(dimCanonicalName(d))"
        case .block(let d, let x, let y, let z):
            return "block:\(dimCanonicalName(d)):\(x),\(y),\(z)"
        case .entity(let uid):
            return "entity:\(uid)"
        case .player:
            return "player"
        case .lanPlayer(let peerID):
            return "player:lan:\(peerID)"
        }
    }

    /// Whether a `.block` ref's coordinates are in bounds for its dimension
    /// (`x`/`z` in `-30_000_000...30_000_000`, `y` in the dimension's
    /// `minY..<minY+height`). Always `true` for every other case.
    public var isWithinBounds: Bool {
        guard case .block(let d, let x, let y, let z) = self else { return true }
        let info = dimInfo(d)
        guard x >= -30_000_000, x <= 30_000_000, z >= -30_000_000, z <= 30_000_000 else { return false }
        return y >= info.minY && y < info.minY + info.height
    }

    /// Strict parse (spec "Object kinds and the ref grammar"): no case folding, no
    /// whitespace, no trailing garbage, input ≤ 128 bytes, decimal-integer and
    /// peerID grammars enforced exactly. Never traps; returns `nil` on any
    /// malformed or out-of-range input.
    public static func parse(_ s: String) -> ObjectRef? {
        guard s.utf8.count <= 128, !s.isEmpty else { return nil }
        // Reject anything outside printable ASCII up front — canonical refs are
        // pure ASCII, and a non-ASCII byte can never appear in a valid one.
        guard s.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else { return nil }

        if s == "world" { return .world }
        if s == "player" { return .player }

        if s.hasPrefix("dim:") {
            let name = String(s.dropFirst(4))
            guard !name.isEmpty, let d = dimFromCanonicalName(name) else { return nil }
            return .dimension(d)
        }

        if s.hasPrefix("entity:") {
            let rest = s.dropFirst(7)
            guard let uid = parseCanonicalUnsignedDecimal(rest), uid >= 1 else { return nil }
            return .entity(uid: uid)
        }

        if s.hasPrefix("player:lan:") {
            let peerID = String(s.dropFirst(11))
            guard isValidPeerID(peerID) else { return nil }
            return .lanPlayer(peerID: peerID)
        }

        if s.hasPrefix("block:") {
            let rest = s.dropFirst(6)
            // "<dim>:<x>,<y>,<z>" — exactly one more colon, then the coordinate triplet.
            guard let colonIndex = rest.firstIndex(of: ":") else { return nil }
            let dimName = String(rest[rest.startIndex..<colonIndex])
            let coords = rest[rest.index(after: colonIndex)...]
            guard !dimName.isEmpty, let d = dimFromCanonicalName(dimName) else { return nil }
            guard let (x, y, z) = parseXYZTriplet(coords) else { return nil }
            let ref = ObjectRef.block(dim: d, x: x, y: y, z: z)
            guard ref.isWithinBounds else { return nil }
            return ref
        }

        return nil
    }
}

// MARK: - entity ref helper (event-bus, change 1b)

/// The `ObjectRef` a live `Entity` names itself with everywhere the object
/// graph is concerned: the local player is always `.player`, never
/// `.entity(uid:)` (Decision 2 / Security (code) SC-1 — `ObjectGraph.resolve`
/// applies the identical rule). Shared by every engine-level event funnel
/// (`GameWorld`, `Living`, `AI`, `Combat`, …) so the mapping is defined once.
public func scriptRef(for entity: Entity) -> ObjectRef {
    entity is Player ? .player : .entity(uid: entity.id)
}

// MARK: - dimension name mapping

/// Canonical dimension name used inside refs and every user-facing surface
/// (commands, docs). Not the same identifier space as `WorldRecord.dims`'s
/// integer keys — this is the string spelling the ref grammar and command
/// aliases both share.
public func dimCanonicalName(_ d: Dim) -> String {
    switch d {
    case .overworld: return "overworld"
    case .nether: return "nether"
    case .end: return "end"
    }
}

public func dimFromCanonicalName(_ s: String) -> Dim? {
    switch s {
    case "overworld": return .overworld
    case "nether": return .nether
    case "end": return .end
    default: return nil
    }
}

// MARK: - strict grammar helpers (also used by Saves.swift's chunk-tail cell-index
// keys, Security (plan) C21 — one canonical decimal-integer grammar, not two).

/// Strict signed decimal integer: optional leading `-`, digits only, no leading
/// `+`, no leading zeros except the literal `"0"`, no `"-0"` (redundant spelling
/// of zero), no whitespace. Used for block coordinates.
func parseCanonicalSignedDecimal(_ s: Substring) -> Int? {
    guard !s.isEmpty else { return nil }
    var bytes = Array(s.utf8)
    var negative = false
    if bytes.first == UInt8(ascii: "-") {
        negative = true
        bytes.removeFirst()
    }
    guard !bytes.isEmpty, bytes.count <= 19 else { return nil }
    if bytes.count > 1 && bytes[0] == UInt8(ascii: "0") { return nil }
    if negative && bytes == [UInt8(ascii: "0")] { return nil }
    for b in bytes where b < UInt8(ascii: "0") || b > UInt8(ascii: "9") { return nil }
    guard let magnitude = Int(String(decoding: bytes, as: UTF8.self)) else { return nil }
    return negative ? -magnitude : magnitude
}

/// Strict non-negative decimal integer: `"0"` or `[1-9][0-9]*`. No leading `+`,
/// no leading zeros, no whitespace. Used for entity uids and (Security (plan)
/// C21) chunk-tail `"objects"` cell-index keys — the exact same grammar, one
/// implementation.
func parseCanonicalUnsignedDecimal<S: StringProtocol>(_ s: S) -> Int? {
    guard !s.isEmpty else { return nil }
    let bytes = Array(s.utf8)
    guard bytes.count <= 19 else { return nil }
    if bytes.count > 1 && bytes[0] == UInt8(ascii: "0") { return nil }
    for b in bytes where b < UInt8(ascii: "0") || b > UInt8(ascii: "9") { return nil }
    return Int(String(decoding: bytes, as: UTF8.self))
}

/// `true` exactly when `s` is `parseCanonicalUnsignedDecimal`'s accepted
/// spelling of its own parsed value (i.e. `s` is already canonical) — used to
/// reject non-canonical-but-numerically-in-range keys (`"007"`, `"+7"`) without
/// re-deriving the check from the parsed `Int` (Security (plan) C21).
func isCanonicalUnsignedDecimal<S: StringProtocol>(_ s: S) -> Bool {
    guard let value = parseCanonicalUnsignedDecimal(s) else { return false }
    return String(value) == String(s)
}

private func parseXYZTriplet(_ s: Substring) -> (Int, Int, Int)? {
    let parts = s.split(separator: ",", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    guard let x = parseCanonicalSignedDecimal(parts[0]),
          let y = parseCanonicalSignedDecimal(parts[1]),
          let z = parseCanonicalSignedDecimal(parts[2]) else { return nil }
    return (x, y, z)
}

private func isValidPeerID(_ s: String) -> Bool {
    let bytes = Array(s.utf8)
    guard bytes.count >= 1, bytes.count <= 64 else { return false }
    for b in bytes {
        let ok = (b >= UInt8(ascii: "A") && b <= UInt8(ascii: "Z"))
            || (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z"))
            || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
            || b == UInt8(ascii: ".") || b == UInt8(ascii: "_") || b == UInt8(ascii: "-")
        if !ok { return false }
    }
    return true
}

// MARK: - command target aliases (spec "Command target aliases")

/// Pure context for resolving a command's `<target>` argument to an `ObjectRef`
/// (spec `object-graph-refs`): the current dimension and a cursor resolver.
/// Alias resolution never mutates game state — the cursor resolver itself may
/// read (but must not write) live state.
public struct ObjectTargetContext {
    public var currentDimension: Dim
    /// Resolves `looking`/`cursor`: the entity under the crosshair within
    /// interaction reach if one is closer than the block hit, else the block
    /// under the crosshair, else `nil` ("nothing under the cursor").
    public var cursor: () -> ObjectRef?

    public init(currentDimension: Dim, cursor: @escaping () -> ObjectRef?) {
        self.currentDimension = currentDimension
        self.cursor = cursor
    }

    /// Resolves a target token to a ref. Recognizes `looking`/`cursor`,
    /// `self`/`player`, `world`, `dim`, every canonical ref (`dim:<name>`,
    /// `block:<dim>:<x>,<y>,<z>`, `entity:<uid>`, `player:lan:<peerID>`), and the
    /// shorthand `block:<x>,<y>,<z>` (current dimension). Returns `nil` for
    /// anything else — including a well-formed but out-of-bounds block.
    public func resolve(alias: String) -> ObjectRef? {
        switch alias {
        case "looking", "cursor": return cursor()
        case "self", "player": return .player
        case "world": return .world
        case "dim": return .dimension(currentDimension)
        default: break
        }
        if let ref = ObjectRef.parse(alias) { return ref }
        if alias.hasPrefix("block:") {
            let rest = alias.dropFirst(6)
            guard !rest.contains(":") else { return nil } // already tried as canonical above
            guard let (x, y, z) = parseXYZTriplet(rest) else { return nil }
            let ref = ObjectRef.block(dim: currentDimension, x: x, y: y, z: z)
            guard ref.isWithinBounds else { return nil }
            return ref
        }
        return nil
    }
}
