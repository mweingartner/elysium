import XCTest
@testable import ElysiumCore

private struct RuinedPortalPoint: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

private struct RuinedPortalBlockEntityProjection: Equatable {
    let x: Int
    let y: Int
    let z: Int
    let kind: String
}

/// An unbounded fixture lets the test compare the authored portal piece to
/// its direct builder counterpart without clipping incidental cells at chunk
/// borders. Its non-air background also makes the magma/netherrack splash
/// observable rather than silently skipping every replacement.
private final class RuinedPortalFixtureSink: ChunkSink {
    let cx = 0
    let cz = 0
    let minY = 0
    let maxY = 128
    private let background: UInt16
    private(set) var cells: [RuinedPortalPoint: UInt16] = [:]
    private(set) var blockEntities: [BESpec] = []

    init(background: UInt16) {
        self.background = background
    }

    func set(_ x: Int, _ y: Int, _ z: Int, _ c: UInt16) {
        guard y >= minY, y < maxY else { return }
        cells[RuinedPortalPoint(x: x, y: y, z: z)] = c
    }

    func get(_ x: Int, _ y: Int, _ z: Int) -> Int {
        guard y >= minY, y < maxY else { return 0 }
        return Int(cells[RuinedPortalPoint(x: x, y: y, z: z)] ?? background)
    }

    func topY(_ x: Int, _ z: Int) -> Int { 64 }
    func addBlockEntity(_ spec: BESpec) { blockEntities.append(spec) }
    func addEntity(_ spec: EntitySpec) {}
}

final class RuinedPortalGenerationTests: XCTestCase {
    private let seed: UInt32 = 4_242

    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllBiomes()
        registerAllStructures()
    }

    private func renderPlan(_ plan: StructurePlan, def: StructureDef,
                            origin: (x: Int, z: Int)) -> RuinedPortalFixtureSink {
        let sink = RuinedPortalFixtureSink(background: cell(B.netherrack))
        for (index, piece) in plan.pieces.enumerated() {
            let rng = Rng(hash2(seed,
                                 origin.x &* 1_000_003 &+ index,
                                 origin.z &* 31 &- index,
                                 def.salt ^ 0x9999))
            piece.build(Builder(sink, rng))
        }
        return sink
    }

    private func renderDirect(nether: Bool, def: StructureDef,
                              origin: (x: Int, z: Int)) -> RuinedPortalFixtureSink {
        let sink = RuinedPortalFixtureSink(background: cell(B.netherrack))
        let x = origin.x * 16 + 5
        let z = origin.z * 16 + 7
        let rng = Rng(hash2(seed,
                             origin.x &* 1_000_003,
                             origin.z &* 31,
                             def.salt ^ 0x9999))
        buildRuinedPortal(Builder(sink, rng), x, 64, z, nether)
        return sink
    }

    func testNetherRuinedPortalUsesHotNetherVariant() throws {
        let portal = try XCTUnwrap(STRUCTURES.first { $0.id == "ruined_portal" })
        let origin = (x: 0, z: 0)
        let context = GenCtx(seed: seed,
                             heightAt: { _, _ in 64 },
                             biomeAt: { _, _ in Biome.netherWastes.rawValue },
                             dim: Dim.nether.rawValue,
                             generationSettingsIdentity: "nether-portal-variant",
                             baseTerrainOracleVersion: baseTerrainOracleVersion,
                             activeStructureDefinitions: [portal])
        let plan = try XCTUnwrap(portal.plan(context, origin.x, origin.z,
                                              Rng(hash2(seed, origin.x, origin.z,
                                                        portal.salt ^ 0x1234))))

        let emitted = renderPlan(plan, def: portal, origin: origin)
        let expectedNether = renderDirect(nether: true, def: portal, origin: origin)
        let expectedOverworld = renderDirect(nether: false, def: portal, origin: origin)
        XCTAssertEqual(emitted.cells, expectedNether.cells,
                       "Nether structure emission must select the hot, low-decay portal builder")
        XCTAssertNotEqual(emitted.cells, expectedOverworld.cells,
                          "the reviewed fixture must distinguish Nether from Overworld portal thresholds")
        XCTAssertEqual(emitted.blockEntities.map {
            RuinedPortalBlockEntityProjection(x: $0.x, y: $0.y, z: $0.z, kind: $0.kind)
        }, expectedNether.blockEntities.map {
            RuinedPortalBlockEntityProjection(x: $0.x, y: $0.y, z: $0.z, kind: $0.kind)
        })
    }
}
