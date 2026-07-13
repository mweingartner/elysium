import XCTest
@testable import ElysiumCore

final class MesherFixtureTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    private func meshFor(_ block: UInt16, meta: Int = 0) -> MeshOutput {
        let paddedCount = 18 * 18 * 18
        var blocks = [UInt16](repeating: B.air << 4, count: paddedCount)
        let sky = [UInt8](repeating: 15, count: paddedCount)
        let light = [UInt8](repeating: 0, count: paddedCount)
        let biomes = [UInt8](repeating: 0, count: 18 * 18)
        blocks[inputIndex(8, 8, 8)] = (block << 4) | UInt16(meta & 15)
        return buildSectionMesh(MeshInput(blocks: blocks, skyLight: sky, blockLight: light, biomes: biomes, noMerge: true))
    }

    private func inputIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
        ((y + 1) * 18 + (z + 1)) * 18 + (x + 1)
    }

    private func tileNames(in layer: MeshLayer) -> Set<String> {
        var names: Set<String> = []
        for vertex in 0..<layer.count {
            let tile = Int(layer.data[vertex * 7 + 5] & 4095)
            names.insert(tileName(tile))
        }
        return names
    }

    func testLiveTorchMeshUses3DMaterialPiecesInsteadOfSpriteCard() {
        registerCoreIfNeeded()

        let mesh = meshFor(B.torch)
        let tiles = tileNames(in: mesh.cutout)

        XCTAssertGreaterThanOrEqual(mesh.cutout.count, 48)
        XCTAssertTrue(tiles.contains("oak_planks"))
        XCTAssertTrue(tiles.contains("glowstone"))
        XCTAssertFalse(tiles.contains("torch"))
    }

    func testSoulTorchUsesSoulGlowMaterialInLiveMesh() {
        registerCoreIfNeeded()

        let mesh = meshFor(B.soul_torch)
        let tiles = tileNames(in: mesh.cutout)

        XCTAssertGreaterThanOrEqual(mesh.cutout.count, 48)
        XCTAssertTrue(tiles.contains("oak_planks"))
        XCTAssertTrue(tiles.contains("sea_lantern"))
        XCTAssertFalse(tiles.contains("soul_torch"))
    }

    func testLiveLanternMeshUsesFrameAndGlowingCorePieces() {
        registerCoreIfNeeded()

        let mesh = meshFor(B.lantern)
        let tiles = tileNames(in: mesh.cutout)

        XCTAssertGreaterThan(mesh.cutout.count, 24)
        XCTAssertTrue(tiles.contains("iron_block"))
        XCTAssertTrue(tiles.contains("glowstone"))
        XCTAssertFalse(tiles.contains("lantern"))
    }

    func testSoulLanternUsesSoulGlowMaterialInLiveMesh() {
        registerCoreIfNeeded()

        let mesh = meshFor(B.soul_lantern)
        let tiles = tileNames(in: mesh.cutout)

        XCTAssertGreaterThan(mesh.cutout.count, 24)
        XCTAssertTrue(tiles.contains("iron_block"))
        XCTAssertTrue(tiles.contains("sea_lantern"))
        XCTAssertFalse(tiles.contains("soul_lantern"))
    }
}
