// ScriptingCommandsTests.swift — object-graph-attributes (change 1a). Spec
// `scripting-commands`: display hygiene, `/attr` lifecycle + value grammar,
// `/inspect`, `/objects`, and LAN gating (Core-level — the pure decision
// function and `ScriptingCommands.run`'s own defense-in-depth check; the
// `CommandsM` call site itself is proven by
// `Tests/ElysiumResourcePackTests/LANGuestCommandGateTests.swift`).

import XCTest
@testable import ElysiumCore

final class ScriptingCommandsTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
    }

    private func makeContext(isLANClient: Bool = false) -> (FakeObjectGraphHost, World, ScriptingCommandContext) {
        let host = FakeObjectGraphHost()
        host.isLANClient = isLANClient
        let world = World(dim: .overworld, seed: 21)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        host.worldsByDim[.overworld] = world
        let player = Player(world: world)
        player.setPos(3, 64, 5)
        world.addEntity(player)
        host.localPlayer = player
        let graph = ObjectGraph(host: host)
        let store = AttributeStore(graph: graph)
        let target = ObjectTargetContext(currentDimension: .overworld, cursor: { .block(dim: .overworld, x: 3, y: 64, z: 5) })
        let context = ScriptingCommandContext(graph: graph, store: store, target: target, isLANClient: isLANClient, tick: 0)
        return (host, world, context)
    }

    // MARK: - display hygiene

    func testDisplayHygieneStripsFormattingMarksAndCapsLength() {
        let (_, world, context) = makeContext()
        _ = world.setBlock(3, 64, 5, Int(cell(B.chest)))
        _ = context.store.set(.block(dim: .overworld, x: 3, y: 64, z: 5), "n", .string("\u{00A7}cRED\nline\u{202E}x"))
        let result = ScriptingCommands.run(command: "attr", arguments: ["get", "looking", "n"], context: context)
        let line = result.lines.first ?? ""
        XCTAssertFalse(line.contains("\u{00A7}"))
        XCTAssertFalse(line.contains("\n"))
        XCTAssertFalse(line.contains("\u{202E}"))
    }

    func test40LineCapWithTruncationMarker() {
        let (_, world, context) = makeContext()
        _ = world.setBlock(3, 64, 5, Int(cell(B.chest)))
        for i in 0..<50 {
            _ = context.store.set(.block(dim: .overworld, x: 3, y: 64, z: 5), "n\(String(format: "%02d", i))", .int(Int64(i)))
        }
        let result = ScriptingCommands.run(command: "attr", arguments: ["list", "looking"], context: context)
        XCTAssertLessThanOrEqual(result.lines.count, 40)
        XCTAssertTrue(result.lines.last?.hasPrefix("… (+") ?? false)
    }

    // MARK: - /attr custom attribute lifecycle (spec scenario)

    func testCustomAttributeLifecycleAgainstAChest() {
        let (_, world, context) = makeContext()
        _ = world.setBlock(3, 64, 5, Int(cell(B.chest)))
        let ref = "block:overworld:3,64,5"

        var result = ScriptingCommands.run(command: "attr", arguments: ["set", "looking", "mood", "happy"], context: context)
        XCTAssertEqual(result.lines, ["\(ref).mood = \"happy\""])

        result = ScriptingCommands.run(command: "attr", arguments: ["get", "looking", "mood"], context: context)
        XCTAssertEqual(result.lines, ["\"happy\""])

        result = ScriptingCommands.run(command: "attr", arguments: ["define", "looking", "owner", "ref:player", "readonly"], context: context)
        XCTAssertEqual(result.lines, ["\(ref).owner = {\"$ref\":\"player\"} (readonly)"])

        result = ScriptingCommands.run(command: "attr", arguments: ["set", "looking", "owner", "x"], context: context)
        XCTAssertEqual(result.lines, ["owner is readonly — use /attr define --force"])

        result = ScriptingCommands.run(command: "attr", arguments: ["list", "looking"], context: context)
        XCTAssertEqual(result.lines.count, 3) // mood, owner, summary line
        XCTAssertTrue(result.lines.last?.hasSuffix("revision 2") ?? false)

        result = ScriptingCommands.run(command: "attr", arguments: ["remove", "looking", "owner"], context: context)
        XCTAssertEqual(result.lines, ["owner is readonly — use /attr define --force"])

        result = ScriptingCommands.run(command: "attr", arguments: ["remove", "looking", "owner", "--force"], context: context)
        XCTAssertEqual(result.lines, ["removed owner (forced)"])
    }

    // MARK: - value grammar

    func testValueGrammar() {
        let (_, world, context) = makeContext()
        _ = world.setBlock(3, 64, 5, Int(cell(B.chest)))
        let ref = ObjectRef.block(dim: .overworld, x: 3, y: 64, z: 5)
        let cases: [([String], AttrValue)] = [
            (["12"], .int(12)),
            (["1.5"], .number(1.5)),
            (["true"], .bool(true)),
            (["str:true"], .string("true")),
            (["[1,2,\"a\"]"], .list([.int(1), .int(2), .string("a")])),
            (["{\"a\":1,\"b\":[true]}"], .map(["a": .int(1), "b": .list([.bool(true)])])),
            (["ref:self"], .ref("player")),
            (["hello", "world"], .string("hello world")),
        ]
        for (idx, (tokens, expected)) in cases.enumerated() {
            let name = "v\(idx)"
            _ = ScriptingCommands.run(command: "attr", arguments: ["set", "looking", name] + tokens, context: context)
            XCTAssertEqual(context.store.get(ref, name), expected, "mismatch for tokens \(tokens)")
        }
    }

    // MARK: - /inspect a furnace

    func testInspectFurnace() {
        let (_, world, context) = makeContext()
        _ = world.setBlock(3, 64, 5, Int(cell(bid("furnace_lit"), 2))) // facing west
        _ = context.store.set(.block(dim: .overworld, x: 3, y: 64, z: 5), "mood", .string("happy"))

        let result = ScriptingCommands.run(command: "inspect", arguments: ["looking"], context: context)
        XCTAssertTrue(result.lines.first?.hasPrefix("block:overworld:3,64,5 (block)") ?? false)
        XCTAssertTrue(result.lines.contains { $0 == "name: furnace_lit" })
        XCTAssertTrue(result.lines.contains { $0 == "facing: west" })
        XCTAssertTrue(result.lines.contains { $0 == "lit: true" })
        XCTAssertTrue(result.lines.contains { $0.hasPrefix("attrs (1, revision 1):") })
        XCTAssertTrue(result.lines.contains { $0.contains("mood = \"happy\"") })
        XCTAssertEqual(result.lines.last, "scripts: 0")
    }

    // MARK: - /objects near ordering

    func testObjectsNearOrdering() {
        // spec `object-graph-refs` worked example: the block (nearer than
        // both cows) sorts first, and the querying player's own entity never
        // appears in its own "near me" listing.
        let (_, world, context) = makeContext() // player at (3,64,5), same as the block below
        _ = world.setBlock(3, 64, 5, Int(cell(B.chest)))
        _ = context.store.set(.block(dim: .overworld, x: 3, y: 64, z: 5), "n", .int(1))
        let cowFar = Cow(world: world)
        cowFar.setPos(3, 64, 20) // farther than the block
        world.addEntity(cowFar)
        let cowNear = Cow(world: world)
        cowNear.setPos(3, 64, 6) // closer than cowFar, still farther than the block
        world.addEntity(cowNear)

        let result = ScriptingCommands.run(command: "objects", arguments: ["near", "16"], context: context)
        XCTAssertFalse(result.lines.isEmpty)
        XCTAssertTrue(
            result.lines.first?.hasPrefix("block:overworld:3,64,5") ?? false,
            "the nearest scripted block should sort first, got: \(result.lines)"
        )
        XCTAssertTrue(result.lines.contains { $0.hasPrefix("entity:\(cowNear.id)") })
        XCTAssertFalse(result.lines.contains { $0.hasPrefix("entity: player") }, "the querying player must never list itself")
    }

    // MARK: - LAN gating (Core level)

    func testLANClientRefusalPureFunction() {
        XCTAssertNotNil(ScriptingCommands.lanClientRefusal(command: "attr"))
        XCTAssertNotNil(ScriptingCommands.lanClientRefusal(command: "inspect"))
        XCTAssertNotNil(ScriptingCommands.lanClientRefusal(command: "objects"))
        XCTAssertNotNil(ScriptingCommands.lanClientRefusal(command: "ai"))
        XCTAssertNotNil(ScriptingCommands.lanClientRefusal(command: "agent"))
        XCTAssertNil(ScriptingCommands.lanClientRefusal(command: "help"))
    }

    func testRunRefusesOnLANClientWithoutTouchingStoreOrGraph() {
        let (_, world, context) = makeContext(isLANClient: true)
        _ = world.setBlock(3, 64, 5, Int(cell(B.chest)))
        for cmd in ["attr", "inspect", "objects"] {
            let result = ScriptingCommands.run(command: cmd, arguments: ["list", "looking"], context: context)
            XCTAssertFalse(result.ok)
            XCTAssertEqual(result.lines.count, 1)
            XCTAssertTrue(result.lines[0].contains("LAN host only"))
        }
        // no attribute was ever created despite the "set" attempt below being
        // routed through `run` on a LAN client context.
        let setResult = ScriptingCommands.run(command: "attr", arguments: ["set", "looking", "x", "1"], context: context)
        XCTAssertTrue(setResult.lines[0].contains("LAN host only"))
        XCTAssertNil(context.store.get(.block(dim: .overworld, x: 3, y: 64, z: 5), "x"))
    }

    func testHelpListsAttrInspectObjects() {
        XCTAssertEqual(ScriptingCommands.helpSummary(), "attr, inspect, objects")
    }

    // MARK: - not-live messages

    func testDormantDimensionMessage() {
        let (host, _, context) = makeContext()
        let nether = World(dim: .nether, seed: 1)
        host.worldsByDim[.nether] = nether
        let result = ScriptingCommands.run(command: "attr", arguments: ["list", "dim:nether"], context: context)
        XCTAssertEqual(result.lines, ["dimension nether is not loaded"])
    }

    func testNothingUnderCursorMessage() {
        let host = FakeObjectGraphHost()
        let world = World(dim: .overworld, seed: 1)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        host.worldsByDim[.overworld] = world
        let graph = ObjectGraph(host: host)
        let store = AttributeStore(graph: graph)
        let target = ObjectTargetContext(currentDimension: .overworld, cursor: { nil })
        let context = ScriptingCommandContext(graph: graph, store: store, target: target, isLANClient: false, tick: 0)
        let result = ScriptingCommands.run(command: "inspect", arguments: ["looking"], context: context)
        XCTAssertEqual(result.lines, ["nothing under the cursor"])
    }

    // MARK: - display truncation (Test coverage gap 13, Security (code) SC-3 / N3)

    /// `ScriptingDisplayText.line` never exceeds 256 UTF-8 bytes, never manufactures
    /// U+FFFD, and -- since N3's fix -- never splits a `Character` (extended
    /// grapheme cluster): a combining-mark sequence and a multi-scalar ZWJ emoji
    /// sequence placed right at the cut boundary must come through whole or not
    /// at all, never half.
    func testDisplayTruncationRespectsCharacterBoundaries() {
        // A base scalar + combining accent, repeated, so some repetition count
        // lands the raw scalar boundary mid-Character even though the
        // Character-aware cutter must not split it.
        let combining = "e\u{0301}" // "e" + combining acute
        let combiningLine = ScriptingDisplayText.line(String(repeating: combining, count: 200))
        XCTAssertLessThanOrEqual(combiningLine.utf8.count, 256)
        XCTAssertFalse(combiningLine.contains("\u{FFFD}"))
        XCTAssertTrue(combiningLine.hasSuffix("\u{2026}"))
        let combiningBody = String(combiningLine.dropLast())
        for ch in combiningBody {
            XCTAssertEqual(String(ch), combining, "every retained Character must be the whole base+combining-mark cluster, never a lone scalar")
        }

        // A ZWJ emoji sequence (family emoji: four scalars joined by ZWJ) is one
        // `Character` -- repeated until it must be cut, the cutter must drop the
        // whole cluster rather than emit a broken partial sequence.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}"
        let familyLine = ScriptingDisplayText.line(String(repeating: family, count: 60))
        XCTAssertLessThanOrEqual(familyLine.utf8.count, 256)
        XCTAssertFalse(familyLine.contains("\u{FFFD}"))
        let familyBody = familyLine.hasSuffix("\u{2026}") ? String(familyLine.dropLast()) : familyLine
        for ch in familyBody {
            XCTAssertEqual(String(ch), family, "every retained Character must be the whole family-emoji cluster, never a partial scalar run")
        }
    }

    /// A short string well under the 256-byte cap passes through untouched (no
    /// truncation marker), and a string exactly at the cap is preserved exactly.
    func testDisplayTruncationBoundaryExactness() {
        let short = "hello"
        XCTAssertEqual(ScriptingDisplayText.line(short), short)

        let exactly256 = String(repeating: "x", count: 256)
        let result = ScriptingDisplayText.line(exactly256)
        XCTAssertEqual(result, exactly256, "a string exactly at the cap must not be truncated")
        XCTAssertLessThanOrEqual(result.utf8.count, 256)

        let oneOver = String(repeating: "x", count: 257)
        let truncated = ScriptingDisplayText.line(oneOver)
        XCTAssertLessThanOrEqual(truncated.utf8.count, 256)
        XCTAssertTrue(truncated.hasSuffix("\u{2026}"))
    }
}
