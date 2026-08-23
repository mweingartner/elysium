// ObjectRefTests.swift — object-graph-attributes (change 1a). Spec
// `object-graph-refs` "Canonical round trip", "Strict rejection", "Command
// target aliases", "Entity wins over a farther block".

import XCTest
@testable import ElysiumCore

final class ObjectRefTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
    }

    // MARK: - canonical round trip (property, seeded)

    func testCanonicalRoundTripOver10000SeededRefs() {
        var rng = RandomX(778_899)
        for _ in 0..<10_000 {
            let ref = randomRef(&rng)
            let text = ref.canonical
            guard let parsed = ObjectRef.parse(text) else {
                return XCTFail("failed to parse own canonical text '\(text)' for \(ref)")
            }
            XCTAssertEqual(parsed, ref, "round trip mismatch for '\(text)'")
            XCTAssertEqual(parsed.canonical, text, "re-printing should reproduce the same text")
        }
    }

    private func randomRef(_ rng: inout RandomX) -> ObjectRef {
        switch rng.nextInt(6) {
        case 0: return .world
        case 1: return .dimension([Dim.overworld, .nether, .end][rng.nextInt(3)])
        case 2:
            let d = [Dim.overworld, .nether, .end][rng.nextInt(3)]
            let info = dimInfo(d)
            let x = rng.nextInt(60_000_001) - 30_000_000
            let z = rng.nextInt(60_000_001) - 30_000_000
            let y = info.minY + rng.nextInt(info.height)
            return .block(dim: d, x: x, y: y, z: z)
        case 3: return .entity(uid: 1 + rng.nextInt(1_000_000))
        case 4: return .player
        default:
            let len = 1 + rng.nextInt(64)
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            let s = String((0..<len).map { _ in alphabet[rng.nextInt(alphabet.count)] })
            return .lanPlayer(peerID: s)
        }
    }

    // MARK: - strict rejection

    func testStrictRejectionCorpus() {
        let corpus = [
            " world", "World", "dim:Overworld", "block:overworld:1,2", "block:overworld:+1,2,3",
            "block:overworld:01,2,3", "block:overworld:1, 2,3", "entity:0", "entity:-5", "entity:12abc",
            "player:lan:", "player:lan:a b", String(repeating: "x", count: 129),
            "block:overworld:1,9999,3",
        ]
        for s in corpus {
            XCTAssertNil(ObjectRef.parse(s), "expected '\(s)' to be rejected")
        }
    }

    func testRejectsNegativeZeroBlockCoordinate() {
        XCTAssertNil(ObjectRef.parse("block:overworld:-0,64,0"))
    }

    func testAcceptsZeroBlockCoordinate() {
        XCTAssertEqual(ObjectRef.parse("block:overworld:0,64,0"), .block(dim: .overworld, x: 0, y: 64, z: 0))
    }

    // MARK: - aliases

    func testAliasesResolve() {
        let context = ObjectTargetContext(
            currentDimension: .overworld,
            cursor: { .block(dim: .overworld, x: 3, y: 64, z: 5) }
        )
        XCTAssertEqual(context.resolve(alias: "looking"), .block(dim: .overworld, x: 3, y: 64, z: 5))
        XCTAssertEqual(context.resolve(alias: "cursor"), .block(dim: .overworld, x: 3, y: 64, z: 5))
        XCTAssertEqual(context.resolve(alias: "self"), .player)
        XCTAssertEqual(context.resolve(alias: "player"), .player)
        XCTAssertEqual(context.resolve(alias: "world"), .world)
        XCTAssertEqual(context.resolve(alias: "dim"), .dimension(.overworld))
        XCTAssertEqual(context.resolve(alias: "block:3,64,5"), .block(dim: .overworld, x: 3, y: 64, z: 5))
    }

    func testEntityWinsOverFartherBlock() {
        // The alias context's cursor resolver is the source of truth for
        // "looking" — a real cursor implementation (`GameCore.cursorObjectRef`)
        // already prefers a closer entity over a farther block; this proves
        // the alias plumbing forwards whatever the resolver returns.
        let context = ObjectTargetContext(currentDimension: .overworld, cursor: { .entity(uid: 42) })
        XCTAssertEqual(context.resolve(alias: "looking"), .entity(uid: 42))
    }

    func testNothingUnderCursorResolvesToNil() {
        let context = ObjectTargetContext(currentDimension: .overworld, cursor: { nil })
        XCTAssertNil(context.resolve(alias: "looking"))
        XCTAssertNil(context.resolve(alias: "cursor"))
    }

    func testBlockShorthandOutOfBoundsRejected() {
        let context = ObjectTargetContext(currentDimension: .overworld, cursor: { nil })
        XCTAssertNil(context.resolve(alias: "block:0,99999,0"))
    }

    func testDimAliasWithName() {
        let context = ObjectTargetContext(currentDimension: .overworld, cursor: { nil })
        XCTAssertEqual(context.resolve(alias: "dim:nether"), .dimension(.nether))
        XCTAssertNil(context.resolve(alias: "dim:bogus"))
    }

    // MARK: - kind

    func testKindMapping() {
        XCTAssertEqual(ObjectRef.world.kind, .world)
        XCTAssertEqual(ObjectRef.dimension(.overworld).kind, .dim)
        XCTAssertEqual(ObjectRef.block(dim: .overworld, x: 0, y: 0, z: 0).kind, .block)
        XCTAssertEqual(ObjectRef.entity(uid: 1).kind, .entity)
        XCTAssertEqual(ObjectRef.player.kind, .player)
        XCTAssertEqual(ObjectRef.lanPlayer(peerID: "a").kind, .player)
    }

    // MARK: - canonical text spot checks

    func testCanonicalTextExact() {
        XCTAssertEqual(ObjectRef.world.canonical, "world")
        XCTAssertEqual(ObjectRef.dimension(.nether).canonical, "dim:nether")
        XCTAssertEqual(ObjectRef.block(dim: .overworld, x: -5, y: 64, z: 5).canonical, "block:overworld:-5,64,5")
        XCTAssertEqual(ObjectRef.entity(uid: 17).canonical, "entity:17")
        XCTAssertEqual(ObjectRef.player.canonical, "player")
        XCTAssertEqual(ObjectRef.lanPlayer(peerID: "abc.123").canonical, "player:lan:abc.123")
    }
}
