// ScriptNameSuggestions.swift — the one deterministic edit-distance helper behind every scripting
// "did you mean" (attribute registry suggestions, event-name typo warnings, and the dot-sugar
// typo warning), and the one camelCase-to-snake_case conversion. Inputs are bounded before any
// quadratic work, candidates whose length alone rules them out are skipped before a distance is
// computed, candidates are scanned in fixed registry order, and ties break on UTF-8 byte order, so
// a suggestion never depends on hashing or process state.

import Foundation

public enum ScriptNameSuggestions {
    /// Longest name, in Unicode scalars, the distance sweep will compare. Every registered event and
    /// attribute name is far shorter; anything longer is never a near miss.
    public static let maxComparedLength = 64

    /// Every suggestion threshold is at most two edits, and an edit distance is never smaller than
    /// the difference in length, so a candidate whose length differs by more is skipped unmeasured.
    static let maxSuggestedDistance = 2

    /// "maxHealth" -> "max_health": lowercases and inserts `_` at each lower-to-upper boundary. The
    /// single owner of this conversion (built-in name resolution, registry suggestions, typo checks).
    static func snakeCased(_ s: String) -> String {
        var out = ""
        var previousLower = false
        for ch in s {
            if ch.isUppercase && previousLower { out.append("_") }
            out.append(Character(ch.lowercased()))
            previousLower = ch.isLowercase
        }
        return out
    }

    /// Optimal-string-alignment Damerau-Levenshtein distance: insertions, deletions, substitutions
    /// and adjacent transpositions each cost one. Compares Unicode scalars exactly (case-sensitive).
    /// Returns `nil` when either input exceeds `maxComparedLength`.
    public static func editDistance(_ lhs: String, _ rhs: String) -> Int? {
        editDistance(Array(lhs.unicodeScalars), Array(rhs.unicodeScalars))
    }

    static func editDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int? {
        guard a.count <= maxComparedLength, b.count <= maxComparedLength else { return nil }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var twoBack = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var best = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    best = min(best, twoBack[j - 2] + 1)
                }
                current[j] = best
            }
            (twoBack, previous, current) = (previous, current, twoBack)
        }
        return previous[b.count]
    }

    /// A near miss is a different name within distance 2, tightened for short names so that common
    /// short custom names are not mistaken for typos: when the shorter name has one or two characters
    /// it is never a near miss (`hp` is not a typo of `xp` or `x`), and at three or four characters
    /// only one edit counts.
    public static func isNearMiss(_ query: String, _ candidate: String) -> Bool {
        let a = Array(query.unicodeScalars), b = Array(candidate.unicodeScalars)
        guard let distance = editDistance(a, b) else { return false }
        return isNearMiss(a, b, distance: distance)
    }

    private static func isNearMiss(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], distance: Int) -> Bool {
        let shorter = min(a.count, b.count)
        guard distance > 0, shorter > 2 else { return false }
        return distance <= (shorter <= 4 ? 1 : 2)
    }

    /// The stricter test behind the dot-sugar attribute typo warning, which must stay quiet for
    /// ordinary custom names that merely resemble a built-in (`hit` beside `lit`, `home` beside
    /// `mode`): two adjacent letters swapped in a name of three or more characters, a single edit
    /// when the shorter name has at least five, or two edits when it has at least eight.
    public static func isLikelyTypo(_ query: String, _ candidate: String) -> Bool {
        let a = Array(query.unicodeScalars), b = Array(candidate.unicodeScalars)
        guard let distance = editDistance(a, b) else { return false }
        return isLikelyTypo(a, b, distance: distance)
    }

    private static func isLikelyTypo(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], distance: Int) -> Bool {
        guard distance > 0 else { return false }
        let shorter = min(a.count, b.count)
        if distance == 1, a.count == b.count, shorter >= 3,
           zip(a, b).filter({ $0 != $1 }).count == 2 { return true }   // one adjacent transposition
        return (distance == 1 && shorter >= 5) || (distance == 2 && shorter >= 8)
    }

    /// The closest built-in event name to `name` when `name` is not itself built-in and is a near
    /// miss of one. Ties break on (distance, UTF-8 order).
    public static func nearestBuiltInEvent(to name: String) -> String? {
        guard EventDescriptorRegistry.descriptor(named: name) == nil else { return nil }
        return nearest(to: name, among: builtInEventSpellings)
    }

    /// The warning text for an event name that is neither built in nor declared on its target but is
    /// one or two edits from a built-in, or `nil` when no warning applies.
    public static func eventTypoHint(for name: String, isDeclared: Bool) -> String? {
        guard !isDeclared, let suggestion = nearestBuiltInEvent(to: name) else { return nil }
        return "'\(name)' is not a built-in event — did you mean '\(suggestion)'?"
    }

    /// The built-in attribute (canonical name) for `kind` that a raw Lua spelling most likely
    /// mistypes, by the strict `isLikelyTypo` rule, or `nil` for an ordinary custom name. The raw
    /// name is lowercased and camelCase-split first (`maxHelth` -> `max_helth`) and compared with
    /// every canonical name and alias; indexed families (`inventory[i]`) never participate.
    public static func nearestBuiltInAttribute(kind: ObjectKind, to rawName: String) -> String? {
        guard let query = attributeTypoQuery(kind: kind, rawName: rawName) else { return nil }
        return nearestBuiltInAttribute(kind: kind, query: query)
    }

    /// The scalars a typo sweep compares for `rawName`, or `nil` when the name is longer than every
    /// built-in spelling of `kind` plus two and so cannot be a near miss. The raw length is checked
    /// before any snake-casing, so an arbitrarily long name costs one bounded length count.
    static func attributeTypoQuery(kind: ObjectKind, rawName: String) -> [Unicode.Scalar]? {
        let limit = (builtInAttributeSpellings[kind]?.longest ?? 0) + maxSuggestedDistance
        guard rawName.unicodeScalars.prefix(limit + 1).count <= limit else { return nil }
        let query = Array(snakeCased(rawName).unicodeScalars)
        return query.count <= limit ? query : nil
    }

    /// One sweep over `kind`'s precomputed spellings: length prefilter, then one distance each.
    static func nearestBuiltInAttribute(kind: ObjectKind, query: [Unicode.Scalar]) -> String? {
        var best: (name: String, distance: Int)?
        for spelling in builtInAttributeSpellings[kind]?.spellings ?? []
        where abs(spelling.scalars.count - query.count) <= maxSuggestedDistance {
            guard let distance = editDistance(query, spelling.scalars),
                  isLikelyTypo(query, spelling.scalars, distance: distance) else { continue }
            if best.map({ distance < $0.distance || (distance == $0.distance && utf8Less(spelling.canonical, $0.name)) }) ?? true {
                best = (spelling.canonical, distance)
            }
        }
        return best?.name
    }

    private static func nearest(to query: String, among candidates: [Spelling]) -> String? {
        let a = Array(query.unicodeScalars)
        guard a.count <= maxComparedLength else { return nil }
        var best: (name: String, distance: Int)?
        for candidate in candidates where abs(candidate.scalars.count - a.count) <= maxSuggestedDistance {
            guard let distance = editDistance(a, candidate.scalars),
                  isNearMiss(a, candidate.scalars, distance: distance) else { continue }
            if best.map({ distance < $0.distance || (distance == $0.distance && utf8Less(candidate.canonical, $0.name)) }) ?? true {
                best = (candidate.canonical, distance)
            }
        }
        return best?.name
    }

    /// A precomputed comparison spelling: the name a suggestion reports and the scalars compared.
    struct Spelling {
        let canonical: String
        let scalars: [Unicode.Scalar]
    }

    /// Per kind, every canonical name and alias (snake-cased, indexed families excluded) in registry
    /// order, built once. Looked up by kind only, never iterated, so hashing cannot reorder a sweep.
    private static let builtInAttributeSpellings: [ObjectKind: (spellings: [Spelling], longest: Int)] = {
        var table: [ObjectKind: (spellings: [Spelling], longest: Int)] = [:]
        for kind in ObjectKind.allCases {
            let spellings = AttributeRegistry.descriptors(for: kind).filter { !$0.canonical.contains("[") }.flatMap { descriptor in
                ([descriptor.canonical] + descriptor.aliases).map {
                    Spelling(canonical: descriptor.canonical, scalars: Array(snakeCased($0).unicodeScalars))
                }
            }
            table[kind] = (spellings, spellings.map(\.scalars.count).max() ?? 0)
        }
        return table
    }()

    private static let builtInEventSpellings: [Spelling] = EventDescriptorRegistry.names.map {
        Spelling(canonical: $0, scalars: Array($0.unicodeScalars))
    }
}

/// Deterministic per-tick admission for the dot-sugar attribute typo check, so the host-side sweep
/// a script can trigger is bounded regardless of the Lua instruction budget: at most
/// `maxChecksPerScriptPerTick` per script and `maxChecksPerWorldPerTick` per world. Over budget the
/// check is skipped silently (the write itself is unaffected). Tick-keyed, never persisted.
struct ScriptAttributeTypoCheckBudget {
    static let maxChecksPerScriptPerTick = 8
    static let maxChecksPerWorldPerTick = 64

    private var countedTick: Int64?
    private var perScript: [String: Int] = [:]
    private var worldCount = 0
    /// Every admitted check since this runtime started; tests read it to prove the bound.
    private(set) var checksPerformed = 0

    mutating func admit(scriptKey: String, tick now: Int64) -> Bool {
        if countedTick != now {
            countedTick = now
            perScript.removeAll()
            worldCount = 0
        }
        let count = perScript[scriptKey, default: 0]
        guard count < Self.maxChecksPerScriptPerTick, worldCount < Self.maxChecksPerWorldPerTick else { return false }
        perScript[scriptKey] = count + 1
        worldCount += 1
        checksPerformed = checksPerformed == Int.max ? Int.max : checksPerformed + 1
        return true
    }
}
