// ScriptUsabilityDeepTests.swift — white-box depth for the scripting usability polish that
// `ScriptUsabilityTests` introduces: seeded property tests for the shared edit distance and its two
// near-miss predicates, an exhaustive built-in/built-in sweep of the dot-sugar attribute typo
// warning and a pinned table of the plausible custom names it warns about (each still written),
// its per-tick host-work bounds, old-vs-new chunk-wrapper equivalence
// over a seeded corpus, fault-notice format/hygiene/rate-limit boundaries (including the
// 256-entry tracking bound under thrash), closure-timer lifecycle and `cancel` edge cases,
// `/script attach` refusal paths and linear validation, the event typo sweep over every built-in,
// schema consistency for `cancel`, and the host-cost bound of the attribute typo check.
//
// Every generator is a fixed-seed SplitMix64 so a failure replays; the failing seed/input is in
// the assertion message.

import Foundation
import ElysiumScript
import XCTest
@testable import ElysiumCore

/// Fixed-seed SplitMix64: tiny, well distributed, and independent of Swift's hash seed.
private struct SeededGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ upperExclusive: Int) -> Int { Int(next() % UInt64(upperExclusive)) }
    mutating func pick<T>(_ items: [T]) -> T { items[int(items.count)] }
}

/// Textbook full-matrix optimal-string-alignment distance over Unicode scalars — the independent
/// reference `ScriptNameSuggestions.editDistance` (rolling three-row form) must agree with.
private func referenceOSA(_ lhs: String, _ rhs: String) -> Int {
    let a = Array(lhs.unicodeScalars), b = Array(rhs.unicodeScalars)
    var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { d[i][0] = i }
    for j in 0...b.count { d[0][j] = j }
    if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
    for i in 1...a.count {
        for j in 1...b.count {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
            }
        }
    }
    return d[a.count][b.count]
}

/// Plain Levenshtein (no transposition) — a true metric, used to bound OSA's triangle caveat.
private func referenceLevenshtein(_ lhs: String, _ rhs: String) -> Int {
    let a = Array(lhs.unicodeScalars), b = Array(rhs.unicodeScalars)
    if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
    var previous = Array(0...b.count)
    for i in 1...a.count {
        var current = [i] + [Int](repeating: 0, count: b.count)
        for j in 1...b.count {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        previous = current
    }
    return previous[b.count]
}

private final class SilentLogSink: ScriptLogSink {
    func log(envId: UInt64, line: String) {}
}

@MainActor
final class ScriptUsabilityDeepTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
        if itemDefs.isEmpty { registerAllItems() }
    }

    // MARK: - harness (same shape as ScriptUsabilityTests)

    private final class ChatLines {
        var lines: [String] = []
    }

    private struct Harness {
        let host: FakeObjectGraphHost
        let state: GameScriptingState
        let runtime: ScriptRuntime
        let scripts: ScriptStore
        let attributes: AttributeStore
        let chat: ChatLines
    }

    private func makeHarness(seed: Int, budgets: ScriptBudgets = .defaults, withPlayer: Bool = false) throws -> Harness {
        let host = FakeObjectGraphHost()
        let world = World(dim: .overworld, seed: UInt32(seed))
        host.worldsByDim[.overworld] = world
        if withPlayer {
            let player = Player(world: world)
            player.setPos(0.5, 65, 0.5)
            world.addEntity(player)
            host.localPlayer = player
        }
        let state = GameScriptingState()
        let chat = ChatLines()
        let runtime = try ScriptRuntime(host: host, state: state, budgets: budgets, say: { chat.lines.append($0) })
        state.scriptRuntime = runtime
        state.eventBus.delivery = { [weak runtime] event, targets in runtime?.deliver(event, targets) }
        state.eventBus.deliveryAdmission = { [weak runtime] event, targets in
            runtime?.admittedDeliveryCount(for: event, targets: targets) ?? 0
        }
        let graph = ObjectGraph(host: host)
        return Harness(
            host: host, state: state, runtime: runtime, scripts: ScriptStore(graph: graph),
            attributes: AttributeStore(graph: graph), chat: chat
        )
    }

    private func step(_ h: Harness, tick: Int64) {
        h.host.currentTick = tick
        h.state.anyScriptsAttached = true
        h.runtime.resetPerTickCounters()
        h.runtime.runLoads()
        h.runtime.runAIInbox()
        h.runtime.runResumptions()
        _ = h.state.eventBus.runDeliveryPhase(tick: tick)
        h.runtime.persistRNGState()
    }

    private func attachModule(_ h: Harness, _ name: String, _ source: String, on ref: ObjectRef = .world) throws {
        _ = try h.scripts.attach(ref, name: name, source: source, mode: .module, triggers: [], by: .player, tick: 0).get()
    }

    private func raise(_ h: Harness, _ event: String, tick: Int64, subject: ObjectRef = .world) throws {
        h.state.eventBus.raise(kind: try XCTUnwrap(EventKind.parse(event)), subject: subject, source: .engine, tick: tick)
    }

    private func notices(_ h: Harness) -> [String] { h.chat.lines.filter { $0.hasPrefix("[script] ") } }

    private func makeGame(_ label: String) -> GameCore {
        let game = PersistenceTestSupport.makeGame(owner: self, label: label)
        game.createWorld(name: label, seedText: "31", mode: GameMode.creative, difficulty: 2)
        return game
    }

    // MARK: - edit distance: seeded properties

    /// Alphabet mixes ASCII, `_`/`.`, a precomposed and a combining accent, and a 4-byte scalar so
    /// the scalar (not byte, not Character) semantics are exercised.
    private static let fuzzAlphabet: [String] = ["a", "b", "c", "_", ".", "é", "e\u{301}", "🦖", "A"]

    private func randomName(_ rng: inout SeededGenerator, maxLength: Int) -> String {
        (0..<rng.int(maxLength + 1)).map { _ in rng.pick(Self.fuzzAlphabet) }.joined()
    }

    func testEditDistanceAgreesWithAFullMatrixReferenceAndIsAMetricUpToTheOSACaveat() {
        var rng = SeededGenerator(seed: 0x5EED_0001)
        for iteration in 0..<3_000 {
            let a = randomName(&rng, maxLength: 7)
            let b = randomName(&rng, maxLength: 7)
            let c = randomName(&rng, maxLength: 7)
            let context = "seed 0x5EED0001 iteration \(iteration): a=\(a.debugDescription) b=\(b.debugDescription) c=\(c.debugDescription)"
            guard let ab = ScriptNameSuggestions.editDistance(a, b),
                  let ba = ScriptNameSuggestions.editDistance(b, a),
                  let bc = ScriptNameSuggestions.editDistance(b, c),
                  let ac = ScriptNameSuggestions.editDistance(a, c),
                  let aa = ScriptNameSuggestions.editDistance(a, a) else {
                return XCTFail("short inputs must never be refused: \(context)")
            }
            XCTAssertEqual(ab, referenceOSA(a, b), context)
            XCTAssertEqual(ab, ba, "symmetry: \(context)")
            XCTAssertEqual(aa, 0, "identity: \(context)")
            XCTAssertEqual(ab == 0, Array(a.unicodeScalars) == Array(b.unicodeScalars), "zero iff scalar-equal: \(context)")
            let la = a.unicodeScalars.count, lb = b.unicodeScalars.count
            XCTAssertGreaterThanOrEqual(ab, abs(la - lb), "length-difference lower bound: \(context)")
            XCTAssertLessThanOrEqual(ab, max(la, lb), "longer-length upper bound: \(context)")
            let lev = referenceLevenshtein(a, b)
            XCTAssertLessThanOrEqual(ab, lev, "a transposition can only shorten Levenshtein: \(context)")
            XCTAssertLessThanOrEqual(lev, 2 * ab, "one transposition is at most two Levenshtein edits: \(context)")
            // OSA is not a metric, but it is within a factor of two of one (Levenshtein).
            XCTAssertLessThanOrEqual(ac, 2 * (ab + bc), "relaxed triangle: \(context)")
        }
        // The OSA caveat itself: substring transposition cannot be edited again.
        XCTAssertEqual(ScriptNameSuggestions.editDistance("ca", "ac"), 1)
        XCTAssertEqual(ScriptNameSuggestions.editDistance("ac", "abc"), 1)
        XCTAssertEqual(ScriptNameSuggestions.editDistance("ca", "abc"), 3, "OSA violates the triangle inequality here (true Damerau gives 2)")
    }

    func testEditDistanceBoundCountsUnicodeScalarsOnBothSides() {
        let sixtyFourAccents = String(repeating: "é", count: 64)              // 128 UTF-8 bytes, 64 scalars
        XCTAssertEqual(ScriptNameSuggestions.editDistance(sixtyFourAccents, ""), 64)
        XCTAssertNil(ScriptNameSuggestions.editDistance(sixtyFourAccents + "é", ""))
        XCTAssertNil(ScriptNameSuggestions.editDistance("", sixtyFourAccents + "é"), "the bound applies to the right-hand side too")
        let combining = String(repeating: "e\u{301}", count: 32)               // 32 Characters, 64 scalars
        XCTAssertEqual(combining.count, 32)
        XCTAssertEqual(ScriptNameSuggestions.editDistance(combining, "e"), 63)
        XCTAssertNil(ScriptNameSuggestions.editDistance(combining + "e\u{301}", "e"), "66 scalars even though only 33 Characters")
        let dinosaurs = String(repeating: "🦖", count: 64)                       // 256 bytes, 64 scalars
        XCTAssertEqual(ScriptNameSuggestions.editDistance(dinosaurs, dinosaurs), 0)
        XCTAssertEqual(ScriptNameSuggestions.editDistance("A", "a"), 1, "case-sensitive")
        XCTAssertEqual(ScriptNameSuggestions.editDistance("é", "e\u{301}"), 2, "scalar-exact: no Unicode normalization")
        XCTAssertFalse(ScriptNameSuggestions.isNearMiss(String(repeating: "a", count: 65), String(repeating: "a", count: 64)))
        XCTAssertFalse(ScriptNameSuggestions.isLikelyTypo(String(repeating: "a", count: 65), String(repeating: "a", count: 64)))
        XCTAssertNil(ScriptNameSuggestions.nearestBuiltInAttribute(kind: .entity, to: String(repeating: "health", count: 11)))
        XCTAssertNil(ScriptNameSuggestions.nearestBuiltInEvent(to: String(repeating: "block.broken", count: 6)))
    }

    func testIsNearMissTruthTable() {
        let cases: [(String, String, Bool, String)] = [
            ("ab", "ac", false, "two characters never qualify"),
            ("hp", "xp", false, "two characters never qualify"),
            ("abc", "abd", true, "three characters: one substitution"),
            ("abc", "bac", true, "three characters: one transposition"),
            ("abc", "abcde", false, "three characters: two edits is too many"),
            ("abcd", "abxy", false, "four characters: two edits is too many"),
            ("abcd", "abcde", true, "four characters: one insertion"),
            ("abcde", "abxye", true, "five characters: two edits"),
            ("abcde", "axyze", false, "five characters: three edits"),
            ("abcde", "abcde", false, "an exact name is not a near miss"),
            ("block.broke", "block.broken", true, "the canonical example"),
        ]
        for (query, candidate, expected, why) in cases {
            XCTAssertEqual(ScriptNameSuggestions.isNearMiss(query, candidate), expected, "\(query)~\(candidate): \(why)")
            XCTAssertEqual(ScriptNameSuggestions.isNearMiss(candidate, query), expected, "symmetric: \(candidate)~\(query)")
        }
    }

    func testIsLikelyTypoTruthTable() {
        let cases: [(String, String, Bool, String)] = [
            ("lti", "lit", true, "three characters: adjacent swap"),
            ("tl", "lt", false, "two characters: even a swap is too short"),
            ("opn", "open", false, "four-character shorter side: one insertion is not enough"),
            ("opne", "open", true, "four characters: adjacent swap"),
            ("hlth", "health", false, "two edits on a short name"),
            ("helth", "health", true, "five-character shorter side: one edit"),
            ("helht", "health", false, "five characters: two edits need eight"),
            ("max_helht", "max_health", true, "nine characters: two edits"),
            ("abcdefgh", "abcdefxy", true, "eight characters: two edits"),
            ("abcdefg", "abcdexy", false, "seven characters: two edits is not enough"),
            ("badc", "abcd", false, "two swaps on a short name"),
            ("axcy", "abcd", false, "two separated substitutions on a short name"),
            ("abcde", "abcde", false, "exact"),
            ("home", "mode", false, "an ordinary custom name"),
            ("hit", "lit", false, "an ordinary custom name"),
        ]
        for (query, candidate, expected, why) in cases {
            XCTAssertEqual(ScriptNameSuggestions.isLikelyTypo(query, candidate), expected, "\(query)~\(candidate): \(why)")
            XCTAssertEqual(ScriptNameSuggestions.isLikelyTypo(candidate, query), expected, "symmetric: \(candidate)~\(query)")
        }
    }

    func testIsLikelyTypoIsAStrictSubsetOfIsNearMissOnSeededStrings() {
        var rng = SeededGenerator(seed: 0x5EED_0002)
        let alphabet = ["a", "b", "c", "d"]
        var likelyCount = 0
        var nearOnlyCount = 0
        for iteration in 0..<5_000 {
            let base = (0..<(3 + rng.int(8))).map { _ in rng.pick(alphabet) }.joined()
            var mutated = Array(base)
            for _ in 0..<(1 + rng.int(2)) {
                switch rng.int(4) {
                case 0 where mutated.count > 1: mutated.remove(at: rng.int(mutated.count))
                case 1: mutated.insert(Character(rng.pick(alphabet)), at: rng.int(mutated.count + 1))
                case 2: mutated[rng.int(mutated.count)] = Character(rng.pick(alphabet))
                default:
                    if mutated.count > 1 { let i = rng.int(mutated.count - 1); mutated.swapAt(i, i + 1) }
                }
            }
            let query = String(mutated)
            let likely = ScriptNameSuggestions.isLikelyTypo(query, base)
            let near = ScriptNameSuggestions.isNearMiss(query, base)
            XCTAssertTrue(!likely || near, "seed 0x5EED0002 iteration \(iteration): \(query)~\(base) likely but not near")
            if likely { likelyCount += 1 } else if near { nearOnlyCount += 1 }
        }
        XCTAssertGreaterThan(likelyCount, 500, "the generator must exercise the error rule")
        XCTAssertGreaterThan(nearOnlyCount, 500, "the warning rule must be strictly looser")
    }

    // MARK: - attribute guard: built-in vs built-in, and plausible custom names

    private func builtInSpellings(_ kind: ObjectKind) -> [String] {
        AttributeRegistry.descriptors(for: kind).filter { !$0.canonical.contains("[") }.flatMap { [$0.canonical] + $0.aliases }
    }

    func testNoBuiltInAttributeIsALikelyTypoOfAnotherBuiltInOfItsKind() {
        for kind in ObjectKind.allCases {
            let names = builtInSpellings(kind)
            XCTAssertFalse(names.isEmpty, "\(kind)")
            var flagged: [String] = []
            for a in names {
                for b in names where a != b && ScriptNameSuggestions.isLikelyTypo(a, b) { flagged.append("\(a)~\(b)") }
                if let suggestion = ScriptNameSuggestions.nearestBuiltInAttribute(kind: kind, to: a) {
                    flagged.append("\(a)->\(suggestion)")
                }
            }
            XCTAssertEqual(flagged, [], "\(kind): a real built-in must never be flagged as a typo of another")
            // The Lua camelCase dot names (`maxHealth`) normalize to the canonical, never to a neighbour.
            for attribute in ScriptLanguageSchema.attributes(for: kind) {
                for dotName in attribute.dotAccessNames {
                    XCTAssertNil(ScriptNameSuggestions.nearestBuiltInAttribute(kind: kind, to: dotName), "\(kind).\(dotName)")
                }
            }
        }
    }

    func testDotSugarNeverTypoChecksOrWarnsForAnExactBuiltInNameOnALiveObject() throws {
        let h = try makeHarness(seed: 501, withPlayer: true)
        let handles: [(ObjectKind, String)] = [(.world, "world"), (.player, "player"), (.dim, "objects.get(\"dim:overworld\")")]
        for (index, (kind, handle)) in handles.enumerated() {
            var probes = ["local h = \(handle)", "assert(h ~= nil, 'no \(kind) handle')"]
            for attribute in ScriptLanguageSchema.attributes(for: kind) where attribute.supportsDotAccess {
                for dotName in attribute.dotAccessNames {
                    probes.append("pcall(function() h.\(dotName) = h.\(dotName) end)")
                }
            }
            try attachModule(h, "probe\(index)", probes.joined(separator: "\n"))
            step(h, tick: Int64(index + 1))
            XCTAssertNil(h.scripts.get(.world, "probe\(index)")?.lastError, "\(kind)")
        }
        XCTAssertEqual(h.runtime.attributeTypoChecks.checksPerformed, 0, "a built-in write never reaches the typo check")
        XCTAssertFalse(h.chat.lines.contains { $0.contains("is not a built-in attribute") }, "\(h.chat.lines)")
    }

    /// Names an author plausibly uses for custom state. Each one listed below WARNS (it resembles a
    /// built-in) and is still written exactly as before the typo guard existed. Pinned so any
    /// threshold change is a deliberate, reviewed diff of this table.
    private static let plausibleCustomNames = [
        "home", "hit", "owner", "count", "timer", "mode2", "level", "state", "opened", "heat", "healthy",
        "position", "target_ref", "last_seen", "targets", "owned", "night", "relay", "players", "hunter",
        "training", "setting", "patch", "colour", "armour", "effect", "lights", "counts", "delays", "hinged",
        "sight", "right", "flight", "speaking", "colors", "items", "names", "visits", "visited", "uses",
        "charge", "ticks", "seeds", "times", "timed", "named", "label", "score", "kills", "deaths", "lives",
        "spawned", "spawner", "mana", "energy", "fuel", "power", "locked", "keys", "health2", "count2",
        "light2", "target2", "variants", "owners", "persisted", "gamemode", "dimensions", "spawn_points",
        "difficult", "hungry", "rained", "thunder", "stage", "growth", "layer", "shaped", "lighted", "seen",
    ]

    private static let pinnedWarnings: [ObjectKind: [String]] = [
        .world: ["difficult->difficulty"],
        .dim: ["training->raining"],
        .block: [
            "count2->count", "counts->count", "delays->delay", "flight->light", "hinged->hinge", "layer->layers",
            "light2->light", "lights->light", "night->light", "players->layers", "relay->delay", "right->light",
            "shaped->shape", "sight->light",
        ],
        .entity: [
            "armour->armor", "colors->color", "colour->color", "effect->effects", "health2->health",
            "healthy->health", "named->tamed", "owned->owner", "owners->owner", "patch->pitch",
            "persisted->persistent", "setting->sitting", "target2->target", "targets->target", "timed->tamed",
            "variants->variant",
        ],
        .player: [
            "armour->armor", "colors->color", "colour->color", "dimensions->dimension", "effect->effects",
            "gamemode->game_mode", "health2->health", "healthy->health", "hunter->hunger", "named->tamed",
            "owned->owner", "owners->owner", "patch->pitch", "persisted->persistent", "setting->sitting",
            "spawn_points->spawn_point", "speaking->sneaking", "target2->target", "targets->target",
            "timed->tamed", "variants->variant",
        ],
    ]

    func testDotSugarTypoWarningsAmongPlausibleCustomNamesArePinned() {
        for kind in ObjectKind.allCases {
            let warned = Self.plausibleCustomNames.compactMap { name -> String? in
                guard AttributeRegistry.resolve(kind: kind, name: name) == nil,
                      let suggestion = ScriptNameSuggestions.nearestBuiltInAttribute(kind: kind, to: name) else { return nil }
                return "\(name)->\(suggestion)"
            }.sorted()
            XCTAssertEqual(warned, Self.pinnedWarnings[kind] ?? [], "\(kind)")
        }
    }

    /// End to end on the player: every pinned name is written through dot sugar (one per tick, so no
    /// per-tick budget hides a check) and warns exactly once; the unflagged names never warn.
    func testPinnedWarnedNamesStillWriteThroughDotSugarAndWarnOnceEach() throws {
        let h = try makeHarness(seed: 502, withPlayer: true)
        let accepted = ["home", "hit", "timer", "mode2", "level", "state", "opened", "heat", "position", "target_ref", "last_seen"]
        let warned = (Self.pinnedWarnings[.player] ?? []).map { String($0.prefix { $0 != "-" }) }
        let names = accepted + warned
        try attachModule(h, "custom", """
        local names = {\(names.map { "\"\($0)\"" }.joined(separator: ", "))}
        local i = 0
        every(1, function() i = i + 1; if names[i] then player[names[i]] = i end end)
        """)
        for tick in Int64(1)...Int64(names.count + 2) { step(h, tick: tick) }
        XCTAssertNil(h.scripts.get(.world, "custom")?.lastError)
        for (index, name) in names.enumerated() {
            XCTAssertEqual(h.attributes.get(.player, name), .int(Int64(index + 1)), "\(name) must still be written")
        }
        let reported = h.chat.lines.compactMap { line -> String? in
            guard let open = line.range(of: ": '"), let close = line.range(of: "' is not a built-in attribute — did you mean '"),
                  let end = line.range(of: "'?", range: close.upperBound..<line.endIndex) else { return nil }
            return line[open.upperBound..<close.lowerBound] + "->" + line[close.upperBound..<end.lowerBound]
        }
        XCTAssertEqual(reported.sorted(), Self.pinnedWarnings[.player], "\(h.chat.lines)")
        // Once the custom attribute exists, dot sugar updates it silently.
        let before = h.chat.lines.count
        try attachModule(h, "update", "player.healthy = false\nplayer.targets = 4")
        step(h, tick: Int64(names.count + 3))
        XCTAssertNil(h.scripts.get(.world, "update")?.lastError)
        XCTAssertEqual(h.attributes.get(.player, "healthy"), .bool(false))
        XCTAssertEqual(h.attributes.get(.player, "targets"), .int(4))
        XCTAssertEqual(h.chat.lines.count, before, "\(h.chat.lines)")
    }

    // MARK: - event names: every built-in with one character dropped

    func testEveryLowercaseBuiltInEventWithOneCharacterDroppedWarnsWithTheRightName() {
        // Equal-distance ties break on UTF-8 order toward another real built-in; pinned here.
        let ties: [String: String] = [
            "block.eplaced": "block.placed", "block.rplaced": "block.placed",
            "player.lept": "player.left", "nload": "load", "uload": "load",
        ]
        var checked = 0
        for name in EventDescriptorRegistry.names {
            let characters = Array(name)
            for index in characters.indices {
                var dropped = characters
                dropped.remove(at: index)
                let variant = String(dropped)
                guard EventKind.parse(variant) != nil, EventDescriptorRegistry.descriptor(named: variant) == nil else { continue }
                checked += 1
                let expected = ties[variant] ?? name
                XCTAssertEqual(
                    ScriptNameSuggestions.eventTypoHint(for: variant, isDeclared: false),
                    "'\(variant)' is not a built-in event — did you mean '\(expected)'?", variant
                )
                XCTAssertNil(ScriptNameSuggestions.eventTypoHint(for: variant, isDeclared: true), "declared \(variant)")
            }
        }
        XCTAssertGreaterThan(checked, 200)
    }

    func testCamelCaseBuiltInEventTyposAreRefusedOutrightWithoutASuggestion() throws {
        // The nine frozen camelCase spellings are exact grammar exceptions, so any near miss of one
        // fails `EventKind.parse` and the stage-5 gate refuses it as malformed — no "did you mean".
        let game = makeGame("camel-typo")
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        for name in EventDescriptorRegistry.names where name != name.lowercased() {
            let variant = String(name.dropLast())
            XCTAssertNil(EventKind.parse(variant), variant)
            guard case .refused(let refusal) = AIScriptValidationGate.validate(
                source: "on(\"\(variant)\", function(ev) end)", chunkName: "camel", runtime: runtime
            ) else { XCTFail("\(variant) should be refused"); continue }
            XCTAssertEqual(refusal.stage, 5)
            XCTAssertEqual(refusal.message, "'\(variant)' is not a valid event name")
            XCTAssertFalse(refusal.hint.contains(name), "no suggestion today: \(refusal.hint)")
        }
    }

    func testCustomEventNamesFromTheDocumentedExamplesNeverWarn() {
        for name in [
            "furnace.output_converted", "furnace.output", "lumber.milestone", "machine.ready", "machine.trip",
            "ore.awakened", "sensor.threshold", "chest.sort", "inventory.sort", "world.external_transition",
        ] {
            XCTAssertNotNil(EventKind.parse(name), name)
            XCTAssertNil(ScriptNameSuggestions.eventTypoHint(for: name, isDeclared: false), name)
        }
        // Exact built-ins that are themselves within two edits of each other never warn either.
        for name in ["block.placed", "block.replaced", "player.left", "player.slept", "load", "unload"] {
            XCTAssertNil(ScriptNameSuggestions.nearestBuiltInEvent(to: name), name)
        }
        var builtInPairs: [String] = []
        let names = EventDescriptorRegistry.names
        for a in names { for b in names where utf8Less(a, b) && ScriptNameSuggestions.isNearMiss(a, b) { builtInPairs.append("\(a)~\(b)") } }
        XCTAssertEqual(builtInPairs, ["block.placed~block.replaced", "player.left~player.slept"])
    }

    func testDeclaredCustomEventSilencesOnlyItsOwnTarget() throws {
        let h = try makeHarness(seed: 503, withPlayer: true)
        try attachModule(h, "declared", """
        self:declareEvent("block.broke", {})
        self:on("block.broke", function(ev) end)
        """)
        try attachModule(h, "elsewhere", "player:on(\"block.broke\", function(ev) end)")
        step(h, tick: 1)
        step(h, tick: 2)
        XCTAssertNil(h.scripts.get(.world, "declared")?.lastError)
        XCTAssertNil(h.scripts.get(.world, "elsewhere")?.lastError)
        XCTAssertEqual(
            notices(h), ["[script] elsewhere: 'block.broke' is not a built-in event — did you mean 'block.broken'?"],
            "a declaration on the world does not cover a subscription on the player"
        )
    }

    func testEventTypoWarningsAreRateLimitedPerScriptAndEvent() throws {
        let h = try makeHarness(seed: 504)
        try attachModule(h, "spammy", """
        self:on("test.again", function(ev)
          on("block.broke", function() end)
          on("entity.dyed", function() end)
        end)
        """)
        step(h, tick: 1)
        for tick in Int64(2)...Int64(5) {
            try raise(h, "test.again", tick: tick)
            step(h, tick: tick)
        }
        XCTAssertNil(h.scripts.get(.world, "spammy")?.lastError)
        XCTAssertEqual(notices(h), [
            "[script] spammy: 'block.broke' is not a built-in event — did you mean 'block.broken'?",
            "[script] spammy: 'entity.dyed' is not a built-in event — did you mean 'entity.died'?",
        ])
    }

    // MARK: - chunk wrapper: equivalence with the old newline wrapper

    private enum ChunkOutcome: Equatable {
        case compileError(String)
        case values([ScriptValue])
        case runtimeError(String)
    }

    private func runChunk(_ wrapped: String, state: LuaState, args: [ScriptValue]) -> ChunkOutcome {
        let environment = state.makeEnvironment(name: "wrapper", random: RandomX(7))
        defer { environment.destroy() }
        switch environment.compile(source: wrapped, chunkName: "w") {
        case .failure(let fault):
            return .compileError(fault.message)
        case .success(let function):
            switch (try? state.call(function, args: args, slice: 1_000_000)) ?? .failure(ScriptFault(kind: .hostAbort, message: "threw", traceback: "")) {
            case .success(let values): return .values(values)
            case .failure(let fault): return .runtimeError(fault.message)
            }
        }
    }

    /// Rewrites every `]:N:` location and `line N` mention by `delta` so a message from the old
    /// (one line longer) wrapper can be compared with the new one.
    private func shiftLines(_ message: String, by delta: Int) -> String {
        var out = message
        for pattern in [#"\]:(\d+):"#, #"line (\d+)"#] {
            let regex = try! NSRegularExpression(pattern: pattern)
            let ns = out as NSString
            var result = ""
            var cursor = 0
            for match in regex.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                let numberRange = match.range(at: 1)
                result += ns.substring(with: NSRange(location: cursor, length: numberRange.location - cursor))
                result += String(Int(ns.substring(with: numberRange))! + delta)
                cursor = numberRange.location + numberRange.length
            }
            out = result + ns.substring(from: cursor)
        }
        return out
    }

    private func shifted(_ outcome: ChunkOutcome, by delta: Int) -> ChunkOutcome {
        switch outcome {
        case .compileError(let message): return .compileError(shiftLines(message, by: delta))
        case .runtimeError(let message): return .runtimeError(shiftLines(message, by: delta))
        case .values: return outcome
        }
    }

    private func assertWrapperEquivalent(_ source: String, state: LuaState, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        for mode in [ScriptMode.module, .handler] {
            let oldPrefix = mode == .module ? "local self, world, player = ...\n" : "local self, world, player, ev = ...\n"
            let args: [ScriptValue] = mode == .module ? [.int(1), .int(2), .int(3)] : [.int(1), .int(2), .int(3), .string("ev")]
            let old = runChunk(oldPrefix + source, state: state, args: args)
            let new = runChunk(ScriptRuntime.wrappedChunkSource(source, mode: mode), state: state, args: args)
            XCTAssertEqual(shifted(old, by: -1), new, "\(mode) \(context): \(source.debugDescription)", file: file, line: line)
        }
    }

    func testNewWrapperEqualsTheOldNewlineWrapperMinusOneLineOnASeededCorpus() throws {
        let state = try LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: SilentLogSink())
        var rng = SeededGenerator(seed: 0x5EED_0003)
        for iteration in 0..<400 {
            var lines = ["local acc = 0"]
            for index in 0..<rng.int(8) {
                let k = rng.int(9) + 1
                lines.append(rng.pick([
                    "acc = acc + \(k)",
                    "local v\(index) = \(k); acc = acc + v\(index)",
                    "if acc > \(k) then acc = acc - 1 end",
                    "for i = 1, \(k) do acc = acc + i end",
                    "local function f\(index)() return \(k) end acc = acc + f\(index)()",
                    "-- comment \(k)",
                    "",
                    "--[[ block\ncomment ]] acc = acc * 2",
                    "acc = acc + (self or 0) + (player or 0)",
                    "error(\"boom \(k)\")",
                    "local t = nil; acc = acc + t.x",
                    "local s = [[long\nstring]] acc = acc + #s",
                    "do local x = \(k) end end",
                ]))
            }
            lines.append(rng.pick(["return acc", "return acc, self, world, player", ""]))
            let separator = rng.int(4) == 0 ? "\r\n" : "\n"
            assertWrapperEquivalent(lines.joined(separator: separator), state: state, "seed 0x5EED0003 iteration \(iteration)")
        }
    }

    func testNewWrapperEqualsTheOldOneForAwkwardFirstLines() throws {
        let state = try LuaState(budgets: .defaults, math: ScriptHostMath.deterministic, log: SilentLogSink())
        let sources = [
            "",
            "(function() return 1 end)()\nreturn 2",
            "-- leading comment\nreturn 3",
            "--[[ long\ncomment ]] return 4",
            "--[==[ level\n2 ]==]\nerror('after long comment')",
            "#!/usr/bin/env lua\nreturn 5",
            "::top:: return 6",
            "\nreturn 7",
            "\n\n\nerror('fourth')",
            "return 8\r\n",
            "local a = 1\r\nlocal b = 2\r\nerror('crlf third')",
            "\u{FEFF}return 9",
            "return ...",
            "return select('#', ...)",
            "local self = 10 return self",
            "if true then\nreturn 11",
            "local s = [[\nunterminated",
            "return [[\nfirst]]",
        ]
        for source in sources { assertWrapperEquivalent(source, state: state, "edge") }
        // The two known divergences are both sources that are not valid Lua on their own: the old
        // newline let a leading operator or comma continue the preamble's expression list.
        for source in ["-1 + 0", ", extra"] {
            let old = runChunk("local self, world, player = ...\n" + source, state: state, args: [.int(1)])
            let new = runChunk(ScriptRuntime.wrappedChunkSource(source, mode: .module), state: state, args: [.int(1)])
            XCTAssertEqual(old, .values([]), "old preamble swallowed \(source.debugDescription)")
            guard case .compileError = new else { return XCTFail("new preamble must refuse \(source.debugDescription)") }
        }
    }

    func testRuntimeLinesThroughHandlersModulesTimersAndCallees() throws {
        let h = try makeHarness(seed: 505)
        _ = try h.scripts.attach(
            .world, name: "handler4", source: "local a = 1\nlocal b = 2\n\nerror(\"fourth\")", mode: .handler,
            triggers: [Trigger(event: try XCTUnwrap(EventKind.parse("test.handler")), attribute: nil, target: .object(.world))],
            by: .player, tick: 0
        ).get()
        try attachModule(h, "callee", """
        local function explode(tag)
          error("exploded " .. tag)
        end
        after(2, function() explode("after") end)
        self:on("test.callee", function(ev)
          explode("event")
        end)
        """)
        try attachModule(h, "repeater", """
        local n = 0
        local function bump()
          n = n + 1
          if n == 2 then error("second") end
        end
        every(1, function() bump() end)
        """)
        step(h, tick: 0)
        step(h, tick: 1)
        try raise(h, "test.handler", tick: 1)
        step(h, tick: 2)
        XCTAssertTrue(h.scripts.get(.world, "handler4")?.lastError?.contains(":4: fourth") == true, "\(String(describing: h.scripts.get(.world, "handler4")?.lastError))")
        XCTAssertTrue(h.scripts.get(.world, "callee")?.lastError?.contains(":2: exploded after") == true)
        XCTAssertTrue(h.scripts.get(.world, "repeater")?.lastError?.contains(":4: second") == true)
        try raise(h, "test.callee", tick: 2)
        step(h, tick: 3)
        XCTAssertTrue(h.scripts.get(.world, "callee")?.lastError?.contains(":2: exploded event") == true)
        XCTAssertTrue(notices(h).contains("[script] handler4 on world failed: line 4: fourth (/script show world handler4)"), "\(notices(h))")
        XCTAssertTrue(notices(h).contains("[script] repeater on world failed: line 4: second (/script show world repeater)"), "\(notices(h))")
    }

    // MARK: - fault notices

    func testFaultNoticeKeepsPrefixAndHowToLookSuffixAtTheWorstCaseNameAndRef() throws {
        let h = try makeHarness(seed: 506)
        let name = "s" + String(repeating: "x", count: 31)
        XCTAssertTrue(isValidAttributeName(name))
        let refs: [ObjectRef] = [
            .entity(uid: Int.max), .block(dim: .overworld, x: -30_000_000, y: -64, z: -30_000_000), .dimension(.overworld), .world,
        ]
        for (index, ref) in refs.enumerated() {
            h.host.currentTick = Int64(index)
            let message = "[string \"\(name)\"]:12: " + String(repeating: "🦕é", count: 200)
            h.runtime.postFaultNotice(owner: ref, scriptName: name, message: message)
            let line = try XCTUnwrap(h.chat.lines.last)
            XCTAssertLessThanOrEqual(line.utf8.count, 256, line)
            XCTAssertTrue(line.hasPrefix("[script] \(name) on \(ref.canonical) failed: line 12: 🦕é"), line)
            XCTAssertTrue(line.hasSuffix("… (/script show \(ref.canonical) \(name))"), line)
        }
        XCTAssertEqual(h.chat.lines.count, refs.count)
    }

    func testFaultNoticeNeutralisesControlBidiColourAndSpoofedPrefixes() throws {
        let h = try makeHarness(seed: 507)
        let hostile = "\u{1B}[31mred\u{1B}[0m\r\n[script] admin on world failed: fake\u{0}\u{7}\u{85}"
            + "\u{202E}evil\u{202C}\u{2066}iso\u{2069}\u{200F}§4colour\tTab\u{2028}sep"
        h.runtime.postFaultNotice(owner: .world, scriptName: "real", message: hostile)
        let line = try XCTUnwrap(h.chat.lines.last)
        XCTAssertTrue(line.hasPrefix("[script] real on world failed: "), line)
        XCTAssertTrue(line.hasSuffix(" (/script show world real)"), line)
        XCTAssertFalse(line.contains("§"))
        let banned = line.unicodeScalars.filter { scalar in
            scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) || (0x202A...0x202E).contains(scalar.value)
                || (0x2066...0x2069).contains(scalar.value) || [0x200E, 0x200F, 0x2028, 0x2029, 0x061C].contains(scalar.value)
        }
        XCTAssertEqual(banned.map { String(format: "U+%04X", $0.value) }, [], line)
        XCTAssertEqual(line.components(separatedBy: "/script show").count, 2, "exactly one how-to-look hint")
        XCTAssertTrue(line.contains("[script] admin"), "the spoof is inert text inside the one line, not a new line: \(line)")

        // The same hostile text raised from Lua takes the same path.
        try attachModule(h, "hostile", "error(\"\\27[31m\\r\\n[script] x failed\\226\\128\\174\")")
        step(h, tick: 5)
        let fromLua = try XCTUnwrap(notices(h).last)
        XCTAssertTrue(fromLua.hasPrefix("[script] hostile on world failed: line 1: "), fromLua)
        XCTAssertFalse(fromLua.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x202E || $0.value == 0x0D || $0.value == 0x0A })
    }

    func testFriendlyFaultTextOnlyRewritesAWellFormedLuaLocation() {
        XCTAssertEqual(ScriptRuntime.friendlyFaultText("[string \"a\"]:7: boom"), "line 7: boom")
        XCTAssertEqual(ScriptRuntime.friendlyFaultText("[string \"a\"]:7:boom"), "[string \"a\"]:7:boom")
        XCTAssertEqual(ScriptRuntime.friendlyFaultText("[string \"a\"]:x: boom"), "[string \"a\"]:x: boom")
        XCTAssertEqual(ScriptRuntime.friendlyFaultText("[string \"a\"]: boom"), "[string \"a\"]: boom")
        XCTAssertEqual(ScriptRuntime.friendlyFaultText("plain"), "plain")
        XCTAssertEqual(ScriptRuntime.friendlyFaultText(""), "")
        XCTAssertEqual(ScriptRuntime.friendlyFaultText("[string \"a\"]:٣: arabic digit"), "[string \"a\"]:٣: arabic digit")
    }

    func testNoticeLimiterBoundariesForIdenticalAndChangedMessages() {
        func outcomes(_ script: [(String, Int64)]) -> [ScriptNoticeLimiter.Admission] {
            var limiter = ScriptNoticeLimiter()
            return script.map { limiter.admit(key: "k", message: $0.0, tick: $0.1) }
        }
        XCTAssertEqual(outcomes([("a", 0), ("a", 199), ("a", 200), ("a", 1_199), ("a", 1_200), ("a", 1_201)]),
                       [.post, .suppressed, .suppressed, .suppressed, .post, .suppressed])
        XCTAssertEqual(outcomes([("a", 0), ("b", 199)]), [.post, .suppressed])
        XCTAssertEqual(outcomes([("a", 0), ("b", 200)]), [.post, .post])
        XCTAssertEqual(outcomes([("a", 0), ("b", 200), ("a", 399), ("a", 400)]), [.post, .post, .suppressed, .post],
                       "the changed window restarts from the last shown notice")
        XCTAssertEqual(outcomes([("a", 0), ("a", 1_199), ("b", 1_199)]), [.post, .suppressed, .post],
                       "a suppressed notice does not restart the window")
        XCTAssertEqual(outcomes([("a", 500), ("a", 10)]), [.post, .post], "a backward clock starts fresh rather than muting")
        XCTAssertEqual(outcomes([("a", Int64.max), ("a", Int64.min)]), [.post, .post], "overflowing elapsed time never traps")
    }

    func testAMessageThatChangesEveryTickIsShownOncePer200Ticks() {
        var limiter = ScriptNoticeLimiter()
        var shown: [Int64] = []
        for tick in Int64(0)..<1_200 where limiter.admit(key: "k", message: "tick \(tick)", tick: tick) == .post {
            shown.append(tick)
        }
        XCTAssertEqual(shown, [0, 200, 400, 600, 800, 1_000])
    }

    func testFiveScriptsFaultingInOneTickPostFourThenOneSummaryDeterministically() throws {
        func scenario() throws -> [String] {
            let h = try makeHarness(seed: 508)
            for index in 0..<5 { try attachModule(h, "bad\(index)", "error(\"boom \(index)\")") }
            for tick in Int64(1)...Int64(4) { step(h, tick: tick) }
            return h.chat.lines
        }
        let first = try scenario()
        XCTAssertEqual(first.filter { $0.contains(" failed: ") }.count, 4, "\(first)")
        XCTAssertEqual(first.last, "[script] …and 1 more script faults (/script list)")
        XCTAssertEqual(first.count, 5)
        XCTAssertEqual(try scenario(), first, "same scenario, same chat, same order")
    }

    func testNoticeLimiterTrackingBoundUnderThreeHundredScriptsAndItsThrashRate() {
        var limiter = ScriptNoticeLimiter()
        var posted = 0, overflowed = 0
        for index in 0..<300 {
            switch limiter.admit(key: "s\(index)", message: "boom", tick: 0) {
            case .post: posted += 1
            case .overflow: overflowed += 1
            case .suppressed: XCTFail("a first notice is never suppressed")
            }
        }
        XCTAssertEqual(posted, 4)
        XCTAssertEqual(overflowed, 296)
        XCTAssertEqual(limiter.takeOverflowSummary(at: 1), 296, "nothing that should show is lost: it is summarized")
        XCTAssertLessThanOrEqual(limiter.trackedKeyCount, ScriptNoticeLimiter.maxTrackedKeys)

        // Sustained: every script faults every tick for 1,300 ticks. The hard invariants hold
        // (<= 4 notices and <= 1 summary per tick, <= 256 tracked keys) ...
        func sustained(keys: Int) -> (posts: Int, summaries: Int) {
            var limiter = ScriptNoticeLimiter()
            var posts = 0, summaries = 0
            for tick in Int64(0)..<1_300 {
                if limiter.takeOverflowSummary(at: tick) != nil { summaries += 1 }
                var thisTick = 0
                for index in 0..<keys where limiter.admit(key: "s\(index)", message: "boom", tick: tick) == .post { thisTick += 1 }
                XCTAssertLessThanOrEqual(thisTick, ScriptNoticeLimiter.maxNoticesPerTick)
                XCTAssertLessThanOrEqual(limiter.trackedKeyCount, ScriptNoticeLimiter.maxTrackedKeys)
                posts += thisTick
            }
            return (posts, summaries)
        }
        // ... and the per-script quiet window holds for every tracked script. Derivation (keys are
        // admitted s0, s1, ... each tick): an overflowed notice is not recorded, so 4 new scripts are
        // shown per tick until all 256 slots hold an active window (ticks 0-63: 256 notices). Every
        // tracked script is then quiet until its own window ends 1,200 ticks after it was shown, so
        // ticks 1,200-1,263 repeat them 4 per tick (256 more) and ticks 1,264-1,299 show nothing.
        // Total 512 = each of the 256 scripts exactly once per minute, versus 5,200 (4 every tick)
        // before the fix. The overflow summary is due after every tick that overflowed but is capped
        // at once per 200 ticks.
        let atBound = sustained(keys: ScriptNoticeLimiter.maxTrackedKeys)
        XCTAssertEqual(atBound.posts, 512)
        XCTAssertEqual(atBound.summaries, 2, "overflow stops at tick 63, so summaries at ticks 1 and 201 only")
        // Past the bound, a script that finds the table full of active windows is counted into the
        // summary instead of evicting one, so the extra 44 scripts change nothing for the 256
        // tracked ones (still 512) and are reported as summaries at ticks 1, 201, ..., 1,201 (7).
        let pastBound = sustained(keys: 300)
        XCTAssertEqual(pastBound.posts, 512, "evicting active windows no longer re-admits every script every tick")
        XCTAssertEqual(pastBound.summaries, 7, "ceil(1,300 / 200) summaries, never one per tick")
    }

    func testNoNoticeFromCheckRunOnceOrValidationPaths() throws {
        let h = try makeHarness(seed: 509, withPlayer: true)
        for source in [
            "error(\"dry\")", "on(\"block.broke\", function() end)", "player.helth = 1",
            "every(1, function() end) error(\"after timers\")",
        ] {
            _ = h.runtime.dryRunOutcome(source: source, owner: .world, mode: .module)
            _ = h.runtime.dryRunOutcome(
                source: source, owner: .world, mode: .handler, handlerEvent: try XCTUnwrap(EventKind.parse("entity.dyed"))
            )
            _ = h.runtime.validateSource(source, chunkName: "check")
        }
        XCTAssertEqual(h.chat.lines, [], "Check never speaks")
        guard case .failure(let message) = h.runtime.runEphemeral(source: "error(\"once\")", owner: .world) else {
            return XCTFail("run once should fail")
        }
        XCTAssertTrue(message.contains("once"), message)
        XCTAssertEqual(notices(h), [], "Run Once reports its own failure; it must not also post a fault notice")
    }

    // MARK: - closure timers

    func testEveryBeatsAtExactMultiplesFromWhereverItWasScheduled() throws {
        let h = try makeHarness(seed: 510)
        try attachModule(h, "beats", """
        every(1, function() world.attrs.one = (world.attrs.one or "") .. tick() .. "," end)
        self:on("test.later", function(ev)
          every(3, function() world.attrs.three = (world.attrs.three or "") .. tick() .. "," end)
        end)
        """)
        for tick in Int64(0)...Int64(17) {
            if tick == 7 { try raise(h, "test.later", tick: tick) }
            step(h, tick: tick)
        }
        XCTAssertEqual(h.attributes.get(.world, "one"), .string((1...17).map { "\($0)," }.joined()))
        XCTAssertEqual(h.attributes.get(.world, "three"), .string("10,13,16,"), "scheduled at 7 -> 10, 13, 16")
    }

    func testEveryEndsOnUnloadDisableUnrelatedFaultAndShutdown() throws {
        let pulse = """
        every(1, function() world.attrs.beats = (world.attrs.beats or 0) + 1 end)
        self:on("test.boom", function(ev) error("unrelated handler") end)
        """
        func live() throws -> Harness {
            let h = try makeHarness(seed: 511)
            try attachModule(h, "pulse", pulse)
            for tick in Int64(0)...Int64(2) { step(h, tick: tick) }
            XCTAssertEqual(h.attributes.get(.world, "beats"), .int(2))
            XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 1)
            return h
        }

        let disabled = try live()
        _ = try disabled.scripts.setEnabled(.world, "pulse", false).get()
        for tick in Int64(3)...Int64(6) { step(disabled, tick: tick) }
        XCTAssertEqual(disabled.attributes.get(.world, "beats"), .int(2), "disable")
        XCTAssertEqual(disabled.runtime.repeatingClosureTimerCount, 0)

        let faulted = try live()
        try raise(faulted, "test.boom", tick: 2)
        step(faulted, tick: 3)
        let atFault = faulted.attributes.get(.world, "beats")
        for tick in Int64(4)...Int64(6) { step(faulted, tick: tick) }
        XCTAssertEqual(faulted.attributes.get(.world, "beats"), atFault, "a fault in another handler of the script")
        XCTAssertEqual(faulted.runtime.repeatingClosureTimerCount, 0)
        XCTAssertTrue(faulted.scripts.get(.world, "pulse")?.lastError?.contains("unrelated handler") == true)

        let unloaded = try live()
        unloaded.runtime.unloadScripts(for: [.world])
        XCTAssertEqual(unloaded.runtime.repeatingClosureTimerCount, 0, "object unload")

        let shutdown = try live()
        shutdown.runtime.unloadAllForShutdown()
        XCTAssertEqual(shutdown.runtime.repeatingClosureTimerCount, 0, "world exit")
    }

    func testKillSwitchPausesEveryWithoutACatchUpBurst() throws {
        let h = try makeHarness(seed: 512)
        try attachModule(h, "pulse", "every(2, function() world.attrs.beats = (world.attrs.beats or 0) + 1 end)")
        for tick in Int64(0)...Int64(4) { step(h, tick: tick) }
        XCTAssertEqual(h.attributes.get(.world, "beats"), .int(2))
        let world = try XCTUnwrap(h.host.worldsByDim[.overworld])
        world.gameRules["doScripts"] = 0
        for tick in Int64(5)...Int64(40) { step(h, tick: tick) }
        XCTAssertEqual(h.attributes.get(.world, "beats"), .int(2), "paused while scripts are off")
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 1, "paused, not dropped")
        world.gameRules["doScripts"] = 1
        step(h, tick: 41)
        XCTAssertEqual(h.attributes.get(.world, "beats"), .int(3), "one overdue beat, not eighteen")
        step(h, tick: 42)
        XCTAssertEqual(h.attributes.get(.world, "beats"), .int(3))
        step(h, tick: 43)
        XCTAssertEqual(h.attributes.get(.world, "beats"), .int(4), "the cadence restarts from the resumed beat")
    }

    func testEveryWorldCapIsCatchableAndFreedByCancel() throws {
        let h = try makeHarness(seed: 513, withPlayer: true)
        let greedy = """
        local accepted = 0
        local ids = {}
        for i = 1, 16 do
          local ok, result = pcall(every, 1000, function() end)
          if ok then accepted = accepted + 1; ids[#ids + 1] = result else world.attrs["err_" .. self.name] = result end
        end
        world.attrs["accepted_" .. self.name] = accepted
        self:on("test.free", function(ev) if ids[1] then cancel(ids[1]) end end)
        self:on("test.retry", function(ev)
          local ok, result = pcall(every, 1000, function() end)
          world.attrs["retry_" .. self.name] = ok
        end)
        """
        let names = (0..<17).map { String(format: "g%02d", $0) }
        // At most eight scripts per object, so spread the seventeen over world, dimension and player.
        let owners: [ObjectRef] = [.world, .dimension(.overworld), .player]
        for (index, name) in names.enumerated() {
            try attachModule(h, name, greedy.replacingOccurrences(of: "self.name", with: "\"\(name)\""), on: owners[index / 8])
        }
        for tick in Int64(0)...Int64(4) { step(h, tick: tick) }
        let accepted = names.map { h.attributes.get(.world, "accepted_\($0)") }
        XCTAssertEqual(accepted.compactMap { if case .int(let n)? = $0 { return n } else { return nil } }.reduce(0, +), 256)
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, ScriptClosureTimerRegistry.maxPerWorld)
        let errors = names.compactMap { name -> String? in
            if case .string(let message)? = h.attributes.get(.world, "err_\(name)") { return message }
            return nil
        }
        XCTAssertEqual(errors.count, 1, "only the script that loaded last was refused")
        XCTAssertTrue(errors.allSatisfy { $0.contains("in this world (limit 256)") }, "\(errors)")
        XCTAssertEqual(accepted.filter { $0 == .int(0) }.count, 1, "and it was refused all sixteen times")
        XCTAssertTrue(names.enumerated().allSatisfy { h.scripts.get(owners[$0.offset / 8], $0.element)?.lastError == nil })

        // Each of the 16 scripts holding timers cancels one; then all 17 retry and exactly the
        // freed 16 slots are granted (the refused script holds none, so only the world cap binds).
        for owner in owners { try raise(h, "test.free", tick: 5, subject: owner) }
        step(h, tick: 5)
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 240)
        for owner in owners { try raise(h, "test.retry", tick: 6, subject: owner) }
        step(h, tick: 6)
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 256)
        let retried = names.filter { h.attributes.get(.world, "retry_\($0)") == .bool(true) }
        XCTAssertEqual(retried.count, 16, "\(retried)")
    }

    func testCancelSemantics() throws {
        let h = try makeHarness(seed: 514)
        try attachModule(h, "victim", """
        world.attrs.victim_id = every(1, function() world.attrs.victim_beats = (world.attrs.victim_beats or 0) + 1 end)
        """)
        try attachModule(h, "actor", """
        local own
        own = every(1, function()
          world.attrs.own_beats = (world.attrs.own_beats or 0) + 1
          if world.attrs.own_beats == 2 then
            world.attrs.self_cancel = cancel(own)
            world.attrs.ran_after_cancel = true
          end
        end)
        local once
        once = after(1, function() world.attrs.after_self_cancel = cancel(once) end)
        self:on("test.cancel", function(ev)
          world.attrs.foreign = cancel(world.attrs.victim_id)
          world.attrs.unknown = cancel(987654321)
          world.attrs.zero = cancel(0)
          world.attrs.negative = cancel(-5)
          local ok, err = pcall(cancel)
          world.attrs.no_arg = tostring(err)
          ok, err = pcall(cancel, 1.5)
          world.attrs.fraction_ok = ok
        end)
        """)
        for tick in Int64(0)...Int64(4) { step(h, tick: tick) }
        try raise(h, "test.cancel", tick: 4)
        for tick in Int64(5)...Int64(8) { step(h, tick: tick) }

        XCTAssertNil(h.scripts.get(.world, "actor")?.lastError)
        XCTAssertEqual(h.attributes.get(.world, "own_beats"), .int(2), "a callback can cancel its own every")
        XCTAssertEqual(h.attributes.get(.world, "self_cancel"), .bool(true))
        XCTAssertEqual(h.attributes.get(.world, "ran_after_cancel"), .bool(true), "the current run finishes")
        XCTAssertEqual(h.attributes.get(.world, "after_self_cancel"), .bool(false), "a running after has nothing left to stop")
        XCTAssertEqual(h.attributes.get(.world, "foreign"), .bool(false), "another script's id is not mine to cancel")
        XCTAssertEqual(h.attributes.get(.world, "victim_beats"), .int(8), "and the victim keeps beating")
        XCTAssertEqual(h.attributes.get(.world, "unknown"), .bool(false))
        XCTAssertEqual(h.attributes.get(.world, "zero"), .bool(false))
        XCTAssertEqual(h.attributes.get(.world, "negative"), .bool(false))
        guard case .string(let noArg)? = h.attributes.get(.world, "no_arg") else { return XCTFail("missing no-arg error") }
        XCTAssertTrue(noArg.contains("cancel(id) requires the id"), noArg)
        XCTAssertEqual(h.attributes.get(.world, "fraction_ok"), .bool(true),
                       "a fractional id is truncated by the shared intArg (as for after/every/wait ticks), not refused")
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 1, "only the victim remains")
    }

    func testAfterAndEveryShareOneIncreasingIdSequence() throws {
        let h = try makeHarness(seed: 515)
        try attachModule(h, "ids", """
        local a = after(5, function() world.attrs.after_runs = (world.attrs.after_runs or 0) + 1 end)
        local b = every(50, function() end)
        local c = after(1, function() end)
        world.attrs.id_list = a .. "," .. b .. "," .. c
        """)
        for tick in Int64(0)...Int64(30) { step(h, tick: tick) }
        guard case .string(let ids)? = h.attributes.get(.world, "id_list") else {
            return XCTFail("missing ids: \(String(describing: h.scripts.get(.world, "ids")?.lastError))")
        }
        let parts = ids.split(separator: ",").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 3)
        XCTAssertEqual(parts, parts.sorted())
        XCTAssertEqual(Set(parts).count, 3)
        XCTAssertEqual(parts.last.map { $0 - parts[0] }, 2, "consecutive across after/every")
        XCTAssertGreaterThan(parts[0], 0, "0 is reserved for Check")
        XCTAssertEqual(h.attributes.get(.world, "after_runs"), .int(1), "after fires exactly once")
        XCTAssertEqual(
            h.runtime.dryRunOutcome(source: "assert(after(5, function() end) == 0) assert(every(5, function() end) == 0)", owner: .world, mode: .module),
            .completed
        )
    }

    func testEveryCallbackThatSchedulesEveryHitsTheScriptCapAndFaultsCleanly() throws {
        let h = try makeHarness(seed: 516)
        try attachModule(h, "breeder", """
        every(1, function()
          world.attrs.spawned = (world.attrs.spawned or 0) + 1
          every(1, function() end)
        end)
        """)
        for tick in Int64(0)...Int64(30) { step(h, tick: tick) }
        let lastError = try XCTUnwrap(h.scripts.get(.world, "breeder")?.lastError)
        XCTAssertTrue(lastError.contains("limit 16"), lastError)
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 0, "the fault drops every timer the script owned")
        XCTAssertEqual(h.attributes.get(.world, "spawned"), .int(16), "15 children + the parent fill the cap; the 16th beat faults")
        XCTAssertEqual(notices(h).count, 1)
    }

    func testEveryBeatThatExceedsItsInstructionBudgetFaultsAndStops() throws {
        var budgets = ScriptBudgets.defaults
        budgets.handlerSliceInstructions = 2_000
        budgets.handlerTotalInstructions = 10_000
        let h = try makeHarness(seed: 517, budgets: budgets)
        try attachModule(h, "spinner", """
        every(1, function()
          world.attrs.starts = (world.attrs.starts or 0) + 1
          while true do end
        end)
        """)
        for tick in Int64(0)...Int64(40) { step(h, tick: tick) }
        XCTAssertNotNil(h.scripts.get(.world, "spinner")?.lastError)
        XCTAssertEqual(h.runtime.repeatingClosureTimerCount, 0)
        XCTAssertEqual(h.attributes.get(.world, "starts"), .int(1), "the preempted beat suppresses later beats, then faults")
        XCTAssertEqual(h.runtime.summary.suspendedCoroutines, 0)
        XCTAssertEqual(notices(h).count, 1, "\(notices(h))")
    }

    func testEveryClosuresDoNotSurviveSaveAndReloadButLoadBodyTimersReregisterOnce() throws {
        let game = makeGame("every-persistence")
        let worldID = try XCTUnwrap(game.worldRec?.id)
        let scripts = ScriptStore(graph: ObjectGraph(host: game))
        _ = try scripts.attach(.world, name: "pulse", source: """
        every(1, function() world.attrs.load_beats = (world.attrs.load_beats or 0) + 1 end)
        self:on("test.start", function(ev)
          every(1, function() world.attrs.event_beats = (world.attrs.event_beats or 0) + 1 end)
        end)
        """, mode: .module, triggers: [], by: .player, tick: 0).get()
        game.scripting.anyScriptsAttached = true
        func phase(_ tick: Int) {
            game.worldRec?.rpgSimulationTick = tick
            game.world.rpgSimulationTick = tick
            game.runEventBusPhase()
        }
        phase(0)
        game.eventBus.raise(kind: try XCTUnwrap(EventKind.parse("test.start")), subject: .world, source: .engine, tick: 0)
        for tick in 1...4 { phase(tick) }
        XCTAssertEqual(game.scripting.scriptRuntime?.repeatingClosureTimerCount, 2)
        let savedEventBeats = game.attributeStore.get(.world, "event_beats")
        XCTAssertNotNil(savedEventBeats)

        game.exitToTitle()
        game.loadWorld(worldID)
        game.scripting.anyScriptsAttached = true
        for tick in 5...9 { phase(tick) }
        XCTAssertEqual(game.scripting.scriptRuntime?.repeatingClosureTimerCount, 1, "only the load body's every exists again")
        XCTAssertEqual(game.attributeStore.get(.world, "event_beats"), savedEventBeats, "the event-scheduled every is live-only")
        XCTAssertNil(ScriptStore(graph: ObjectGraph(host: game)).get(.world, "pulse")?.lastError)
    }

    // MARK: - /script attach

    func testScriptAttachRefusalNeverTouchesAnExistingRecord() throws {
        let game = makeGame("attach-keep")
        let context = game.scriptingCommandContext()
        let good = ScriptingCommands.run(command: "script", arguments: ["attach", "world", "keep", "module", "world.attrs.v = 1"], context: context)
        XCTAssertTrue(good.ok, "\(good.lines)")
        let before = try XCTUnwrap(context.scriptStore.get(.world, "keep"))
        for source in ["local = 2", "os.exit()", "on(\"Bad.Event\", function() end)", "if then"] {
            let refused = ScriptingCommands.run(command: "script", arguments: ["attach", "world", "keep", "module", source], context: context)
            XCTAssertFalse(refused.ok, source)
            XCTAssertTrue(refused.lines.first?.hasPrefix("attach refused — ") == true, "\(refused.lines)")
        }
        let handler = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "keep", "handler", "test.go", "local = 1"], context: context
        )
        XCTAssertFalse(handler.ok)
        XCTAssertEqual(context.scriptStore.get(.world, "keep"), before, "nothing stored on refusal")
    }

    func testScriptAttachRefusesWithoutARuntimeAndInAnUntrustedWorldStillChecks() throws {
        let game = makeGame("attach-noruntime")
        let full = game.scriptingCommandContext()
        let noRuntime = ScriptingCommandContext(
            graph: full.graph, store: full.store, target: full.target, isLANClient: false, tick: full.tick,
            eventBus: full.eventBus, scriptStore: full.scriptStore, scriptRuntime: nil, scriptsTrusted: true,
            killSwitchOn: true, trustWorld: {}, setKillSwitch: { _ in }
        )
        let refused = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "nort", "module", "world.attrs.v = 1"], context: noRuntime
        )
        XCTAssertFalse(refused.ok)
        XCTAssertEqual(refused.lines, ["attach refused — no script runtime this session to check the source"])
        XCTAssertNil(full.scriptStore.get(.world, "nort"))

        game.worldRec?.scriptsEnabled = false
        let untrusted = game.scriptingCommandContext()
        XCTAssertFalse(untrusted.scriptsTrusted)
        let bad = ScriptingCommands.run(command: "script", arguments: ["attach", "world", "u", "module", "local = 1"], context: untrusted)
        XCTAssertFalse(bad.ok)
        XCTAssertNil(untrusted.scriptStore.get(.world, "u"))
        let good = ScriptingCommands.run(command: "script", arguments: ["attach", "world", "u", "module", "world.attrs.v = 1"], context: untrusted)
        XCTAssertTrue(good.ok, "an untrusted world still stores a checked script (it just does not run): \(good.lines)")
    }

    /// Characterization of a known limitation: the chat/AI attach reply scans literals statically
    /// and cannot see a `declareEvent` in the same source, so it hints where the runtime (which
    /// runs the declaration first) stays silent. Harmless but misleading; see the report.
    func testScriptAttachReplyCannotSeeADeclarationInTheSameSourceButTheRuntimeCan() throws {
        let source = "self:declareEvent(\"block.broke\", {}) self:on(\"block.broke\", function(ev) end)"
        let game = makeGame("attach-self-declared")
        let result = ScriptingCommands.run(
            command: "script", arguments: ["attach", "world", "selfdecl", "module", source], context: game.scriptingCommandContext()
        )
        XCTAssertTrue(result.ok, "\(result.lines)")
        XCTAssertEqual(result.lines.last, "'block.broke' is not a built-in event — did you mean 'block.broken'?",
                       "the static reply hints even though the source declares the event")
        let h = try makeHarness(seed: 519)
        try attachModule(h, "selfdecl", source)
        step(h, tick: 1)
        XCTAssertNil(h.scripts.get(.world, "selfdecl")?.lastError)
        XCTAssertEqual(notices(h), [], "the runtime runs the declaration first and does not warn")
    }

    func testScriptAttachHintsAreDeduplicatedAndBounded() {
        let game = makeGame("attach-hints")
        let context = game.scriptingCommandContext()
        let result = ScriptingCommands.run(command: "script", arguments: [
            "attach", "world", "dupes", "handler", "block.broke",
            "on(\"block.broke\", function() end) on(\"entity.dyed\", function() end) on(\"player.joind\", function() end) on(\"block.plced\", function() end) on(\"player.lef\", function() end)",
        ], context: context)
        XCTAssertTrue(result.ok, "\(result.lines)")
        let hints = Array(result.lines.dropFirst())
        XCTAssertEqual(hints.first, "'block.broke' is not a built-in event — did you mean 'block.broken'?")
        XCTAssertEqual(hints.filter { $0.contains("'block.broke'") }.count, 1, "the trigger and the literal share one hint")
        XCTAssertLessThanOrEqual(hints.count, 5, "trigger hint plus at most four literal hints: \(hints)")
    }

    func testAIAttachToolReportsLiteralEventTyposAsWarnings() throws {
        let game = makeGame("ai-attach-typo")
        let requestID = game.scripting.aiJournal.beginRequest()
        let ctx = game.aiMutationContext(model: "test-model", requestID: requestID)
        let outcome = AIObjectGraphMutationTools.run(
            "attach_script",
            args: AIToolArguments(object: ["ref": "world", "name": "typo", "source": "on(\"block.broke\", function(ev) end)"]),
            context: ctx
        )
        XCTAssertFalse(outcome.refused)
        XCTAssertTrue(outcome.warnings.contains("'block.broke' is not a built-in event — did you mean 'block.broken'?"), "\(outcome.warnings)")
    }

    // MARK: - schema consistency for cancel

    func testCancelIsPresentInEveryAuthoringSurface() throws {
        let game = makeGame("cancel-schema")
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let globals = runtime.buildHostBindings().compactMap { binding -> String? in
            if case .function(let name, _) = binding { return name }
            return nil
        }
        XCTAssertTrue(globals.contains("cancel"))
        XCTAssertEqual(ScriptLanguageSchema.symbol(named: "cancel", parent: nil)?.signatures.first?.returns.map(\.type), [.boolean])
        XCTAssertEqual(ScriptLanguageSchema.symbol(named: "every", parent: nil)?.signatures.last?.returns.map(\.type), [.integer])
        XCTAssertEqual(ScriptLanguageSchema.symbol(named: "after", parent: nil)?.signatures.last?.returns.map(\.type), [.integer])
        let cats = ScriptLanguageSchema.luaCATSDefinitions
        XCTAssertTrue(cats.contains("function cancel("), "LuaCATS must declare cancel")
        XCTAssertTrue(String(cats.prefix(ScriptLanguageSchema.editorAIPrefixCharacterLimit)).contains("function cancel("),
                      "the bounded editor-AI prefix must still reach cancel")
        XCTAssertTrue(ScriptAIAuthoringGuide.text.contains("cancel(id)"))
        XCTAssertNil(runtime.dryRun(source: "assert(type(cancel) == 'function')", owner: .world, mode: .module))
    }

    // MARK: - budget accounting: the dot-sugar typo check is bounded host work

    private func makeBlocks(_ h: Harness, count: Int) throws -> [ObjectRef] {
        let world = try XCTUnwrap(h.host.worldsByDim[.overworld])
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        return (0..<count).map { index in
            _ = world.setBlock(index, 64, 1, Int(cell(B.stone)))
            return ObjectRef.block(dim: .overworld, x: index, y: 64, z: 1)
        }
    }

    /// A script cannot buy unbudgeted host work with a huge attribute key: normalization reads a
    /// bounded prefix, so a 4 KiB key costs about what a 64-byte one does. Before the bound, one
    /// tick of 4 KiB-key reads took 326 ms in a debug build against 10 ms for 64-byte keys.
    func testAHugeAttributeKeyCostsNoMoreThanAnOrdinaryLongOne() throws {
        func oneTick(_ body: String, keyLength: Int) throws -> (ops: Int64, ms: Double) {
            let h = try makeHarness(seed: 519, withPlayer: true)
            try attachModule(h, "prober", """
            local s = string.rep("A", \(keyLength))
            local n = 0
            while true do
              n = n + 1
              \(body)
              if n % 10 == 0 then world.attrs.progress = n end
            end
            """)
            let start = DispatchTime.now().uptimeNanoseconds
            step(h, tick: 1)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            guard case .int(let progress)? = h.attributes.get(.world, "progress") else {
                XCTFail("no progress: \(String(describing: h.scripts.get(.world, "prober")?.lastError))")
                return (0, elapsed)
            }
            return (progress, elapsed)
        }
        for (label, body) in [("read player[s]", "local _ = player[s]"),
                              ("write player[s]", "pcall(function() player[s] = n end)"),
                              ("read player.attrs[s]", "local _ = player.attrs[s]")] {
            func median(_ length: Int) throws -> (ops: Int64, ms: Double) {
                let runs = try (0..<3).map { _ in try oneTick(body, keyLength: length) }
                return (runs[0].ops, runs.map(\.ms).sorted()[1])
            }
            let ordinary = try median(64), huge = try median(4_096)
            print(String(format: "[long-key] %@: 64-byte key %.1f ms, 4 KiB key %.1f ms (%lld ops)",
                         label, ordinary.ms, huge.ms, huge.ops))
            XCTAssertEqual(huge.ops, ordinary.ops, "\(label): the key length costs no Lua instructions")
            XCTAssertLessThan(huge.ms, ordinary.ms * 4 + 20, "\(label): host cost must not grow with the key")
        }
    }

    /// The bounded normalizers return exactly what the unbounded ones did, for names of any length.
    func testBoundedAttributeNameNormalizationMatchesTheUnboundedReference() {
        func referenceHint(_ name: String) -> String? {
            var bytes: [UInt8] = []
            for b in name.lowercased().utf8 {
                let ok = (b >= UInt8(ascii: "a") && b <= UInt8(ascii: "z")) || (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9"))
                bytes.append(ok ? b : UInt8(ascii: "_"))
            }
            guard !bytes.isEmpty else { return nil }
            if bytes[0] < UInt8(ascii: "a") || bytes[0] > UInt8(ascii: "z") { bytes.insert(UInt8(ascii: "a"), at: 0) }
            let candidate = String(decoding: bytes.prefix(32), as: UTF8.self)
            return isValidAttributeName(candidate) ? candidate : nil
        }
        func referenceScriptName(_ raw: String) -> String {
            guard !isValidAttributeName(raw) else { return raw }
            var snake = ""
            var previousLower = false
            for character in raw {
                if character.isUppercase && previousLower { snake.append("_") }
                snake.append(Character(character.lowercased()))
                previousLower = character.isLowercase
            }
            if isValidAttributeName(snake) { return snake }
            return referenceHint(snake) ?? raw
        }
        var seed: UInt64 = 0x51CA_FE11
        func next(_ bound: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(bound))
        }
        let alphabet = Array("abcXYZ019_-. éÅß🙂\u{0301}")
        for trial in 0..<400 {
            let length = [0, 1, 31, 32, 33, 127, 128, 129, 200, 600, 4_096][trial % 11] + (trial % 3)
            let name = String((0..<length).map { _ in alphabet[next(alphabet.count)] })
            XCTAssertEqual(normalizedAttributeNameHint(name), referenceHint(name), "hint, trial \(trial), length \(length)")
            // A name too long to store falls back to itself only when nothing normalizes; compare
            // through the hint so a bounded fallback and an unbounded one are judged by what is stored.
            let bounded = normalizedScriptCustomAttributeName(name), reference = referenceScriptName(name)
            if isValidAttributeName(reference) || isValidAttributeName(bounded) {
                XCTAssertEqual(bounded, reference, "script name, trial \(trial), length \(length)")
            }
        }
    }

    func testDotSugarTypoSweepHostCostPerTick() throws {
        // Swift-only: one sweep over the largest kind (player) for 1,000 five-character names, which
        // pass the length prefilter and so are fully measured.
        let names = (1...1_000).map { "q" + String(format: "%04d", $0) }
        var swiftSamples: [Double] = []
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            var hits = 0
            for name in names where ScriptNameSuggestions.nearestBuiltInAttribute(kind: .player, to: name) != nil { hits += 1 }
            swiftSamples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            XCTAssertEqual(hits, 0)
        }
        func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

        // End to end under the DEFAULT budgets: an endless loop of fresh dot-sugar writes, one tick.
        // The count of writes completed before the slice expires is instruction-deterministic.
        func oneTick(_ write: String) throws -> (writes: Int64, checks: Int, ms: Double) {
            let h = try makeHarness(seed: 518, withPlayer: true)
            try attachModule(h, "writer", """
            local fmt = string.format
            local n = 0
            while true do
              n = n + 1
              local name = "q" .. fmt("%04d", n)
              pcall(function() \(write) = n end)
              if n % 10 == 0 then world.attrs.progress = n end
            end
            """)
            let start = DispatchTime.now().uptimeNanoseconds
            step(h, tick: 1)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            let checks = h.runtime.attributeTypoChecks.checksPerformed
            guard case .int(let progress)? = h.attributes.get(.world, "progress") else {
                XCTFail("no progress: \(String(describing: h.scripts.get(.world, "writer")?.lastError))")
                return (0, checks, elapsed)
            }
            return (progress, checks, elapsed)
        }
        let sugar = try oneTick("player[name]")
        let attrs = try oneTick("player.attrs[name]")
        XCTAssertEqual(sugar.writes, attrs.writes, "the check costs no Lua instructions, so both loops get the same count")
        XCTAssertGreaterThan(sugar.writes, 64, "the loop creates more names than the per-object cap")
        XCTAssertEqual(sugar.checks, ScriptAttributeTypoCheckBudget.maxChecksPerScriptPerTick,
                       "however many fresh names a tick creates, one script gets at most 8 sweeps")
        XCTAssertEqual(attrs.checks, 0, "h.attrs never checks")
        print(String(
            format: "BUDGET typo sweep (debug build): swift-only %.1f us/sweep; default budgets one tick: %lld writes, %d checks, dot-sugar %.1f ms vs h.attrs %.1f ms",
            median(swiftSamples), sugar.writes, sugar.checks, sugar.ms, attrs.ms
        ))
        // Debug build, generous ceiling: 1,000 sweeps well under 5 s means one sweep is far under 5 ms.
        XCTAssertLessThan(median(swiftSamples) / 1_000, 5.0)
    }

    func testAttributeTypoChecksAreBoundedPerScriptAndPerWorldEachTick() throws {
        // Per script: the 9th fresh name in one tick from one script is written but not checked.
        let h = try makeHarness(seed: 520, withPlayer: true)
        try attachModule(h, "nine", "for i = 1, 9 do player[\"fresh\" .. i] = i end")
        step(h, tick: 1)
        XCTAssertNil(h.scripts.get(.world, "nine")?.lastError)
        XCTAssertEqual(h.runtime.attributeTypoChecks.checksPerformed, 8)
        for index in 1...9 { XCTAssertEqual(h.attributes.get(.player, "fresh\(index)"), .int(Int64(index))) }
        // The per-script count resets on the next tick.
        try attachModule(h, "next", "player.fresh10 = 10")
        step(h, tick: 2)
        XCTAssertEqual(h.runtime.attributeTypoChecks.checksPerformed, 9)

        // Per world: nine scripts writing nine fresh names each in one tick perform 64 checks.
        let w = try makeHarness(seed: 521)
        let blocks = try makeBlocks(w, count: 9)
        for (index, block) in blocks.enumerated() {
            try attachModule(w, "writer\(index)", "for i = 1, 9 do self[\"n\" .. i] = i end", on: block)
        }
        step(w, tick: 1)
        for block in blocks {
            XCTAssertNil(w.scripts.get(block, "writer\(blocks.firstIndex(of: block) ?? 0)")?.lastError)
            XCTAssertEqual(w.attributes.get(block, "n9"), .int(9), "every write still lands")
        }
        XCTAssertEqual(w.runtime.attributeTypoChecks.checksPerformed, ScriptAttributeTypoCheckBudget.maxChecksPerWorldPerTick)

        // The admission struct on its own: per-script and per-world caps, then a fresh tick.
        var budget = ScriptAttributeTypoCheckBudget()
        let admitted = (0..<9).flatMap { script in (0..<9).map { _ in budget.admit(scriptKey: "s\(script)", tick: 5) } }
        XCTAssertEqual(admitted.filter { $0 }.count, 64)
        XCTAssertEqual(Array(admitted.prefix(9)), Array(repeating: true, count: 8) + [false])
        XCTAssertTrue(budget.admit(scriptKey: "s8", tick: 6))
    }

    func testLongUnknownDotSugarNamesPerformNoTypoCheck() throws {
        XCTAssertNil(ScriptNameSuggestions.attributeTypoQuery(kind: .player, rawName: String(repeating: "q", count: 64)))
        XCTAssertNil(ScriptNameSuggestions.attributeTypoQuery(kind: .world, rawName: String(repeating: "Q", count: 100_000)))
        let thirty = String(repeating: "q", count: 30)
        XCTAssertNil(ScriptNameSuggestions.attributeTypoQuery(kind: .player, rawName: thirty), "longer than any player built-in + 2")
        XCTAssertNotNil(ScriptNameSuggestions.attributeTypoQuery(kind: .entity, rawName: "helth"))
        let h = try makeHarness(seed: 522, withPlayer: true)
        try attachModule(h, "long", """
        world[string.rep("q", 64)] = 1
        player.\(thirty) = 1
        """)
        step(h, tick: 1)
        XCTAssertNil(h.scripts.get(.world, "long")?.lastError)
        XCTAssertEqual(h.attributes.get(.world, String(repeating: "q", count: 32)), .int(1),
                       "as before the guard, an over-long Lua name is stored under its normalized 32-byte spelling")
        XCTAssertEqual(h.attributes.get(.player, thirty), .int(1))
        XCTAssertEqual(h.runtime.attributeTypoChecks.checksPerformed, 0, "neither name reaches a distance computation")
    }

    /// The review's repro, plus a fresh-name variant: 450 dot-sugar writes per tick from one script.
    func testFourHundredFiftyDotSugarWritesPerTickPerformAtMostEightChecks() throws {
        for (label, body) in [
            ("long64", "local k = string.rep(\"q\", 64); for _ = 1, 450 do pcall(function() world[k] = 1 end) end"),
            ("fresh", "for i = 1, 450 do pcall(function() player[\"n\" .. tick() .. \"_\" .. i] = 1 end) end"),
        ] {
            let h = try makeHarness(seed: 523, withPlayer: true)
            try attachModule(h, "writer", "every(1, function() \(body) end)")
            var samples: [Double] = []
            var previous = 0
            for tick in Int64(1)...Int64(12) {
                let start = DispatchTime.now().uptimeNanoseconds
                step(h, tick: tick)
                if tick > 2 { samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6) }
                let checks = h.runtime.attributeTypoChecks.checksPerformed
                XCTAssertLessThanOrEqual(checks - previous, 8, "\(label) tick \(tick)")
                previous = checks
            }
            XCTAssertNil(h.scripts.get(.world, "writer")?.lastError, label)
            print("REPRO \(label): median \(samples.sorted()[samples.count / 2]) ms/tick (debug), \(previous) checks in 12 ticks")
        }
    }

    // MARK: - /script attach validation is linear in the source

    func testAttachValidationOfA16KiBLiteralSourceIsLinearAndReportsTheLastLine() throws {
        let game = makeGame("attach-16k")
        let runtime = try XCTUnwrap(game.scriptingCommandContext().scriptRuntime)
        let bad = "on(\"Bad.Event\")"
        var lines: [String] = []
        while (lines.count + 1) * 8 + bad.utf8.count <= 16_384 { lines.append("on(\"a\")") }
        let source = lines.joined(separator: "\n") + "\n" + bad
        XCTAssertLessThanOrEqual(source.utf8.count, 16_384)
        XCTAssertGreaterThan(lines.count, 2_000)
        var start = DispatchTime.now().uptimeNanoseconds
        let refused = AIScriptValidationGate.validateForAttach(source: source, chunkName: "big", runtime: runtime) { _ in false }
        let refuseMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        guard case .refused(let result) = refused.outcome else { return XCTFail("the bad last literal must refuse") }
        XCTAssertEqual(result.stage, 5)
        XCTAssertEqual(result.line, lines.count + 1, "the line of the one reported literal")
        XCTAssertEqual(result.message, "'Bad.Event' is not a valid event name")

        // An accepted 16 KiB source of near-miss literals: one scan, and the typo pass stops after the
        // first 64 literals. (The chat command would then refuse to STORE 16 KiB on the world; the
        // validation it runs first is this exact call, which is what a guest can make it pay for.)
        let typo = "on(\"block.broke\")"
        let accepted = Array(repeating: typo, count: 16_384 / (typo.utf8.count + 1)).joined(separator: "\n")
        var declaredQueries = 0
        start = DispatchTime.now().uptimeNanoseconds
        let checked = AIScriptValidationGate.validateForAttach(source: accepted, chunkName: "big", runtime: runtime) { _ in
            declaredQueries += 1
            return false
        }
        let acceptMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        guard case .accepted = checked.outcome else { return XCTFail("\(checked.outcome)") }
        XCTAssertEqual(checked.warnings, ["'block.broke' is not a built-in event — did you mean 'block.broken'?"])
        XCTAssertEqual(declaredQueries, AIScriptValidationGate.maxTypoCheckedLiterals, "only the first 64 literals are typo-checked")
        print(String(format: "ATTACH 16 KiB (debug): %d literals refused in %.1f ms; %d near-miss literals accepted in %.1f ms",
                     lines.count + 1, refuseMs, accepted.split(separator: "\n").count, acceptMs))
        XCTAssertLessThan(refuseMs, 50, "debug-build bound for one validation")
        XCTAssertLessThan(acceptMs, 50, "debug-build bound for one attach validation")
    }
}
