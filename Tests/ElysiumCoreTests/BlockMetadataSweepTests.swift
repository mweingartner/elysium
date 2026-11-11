import XCTest
@testable import ElysiumCore

/// A block's metadata is four bits that any block may be given: by a template that was pasted,
/// imported or sent by a LAN guest, by a script, by a command. The game must survive every
/// registered block at every metadata value: being placed, hearing a neighbour change, its
/// scheduled and random ticks, its block entity's tick, its shape being measured, being used
/// and being broken. A trap here stops the game, and on a LAN host it stops it for everyone.
final class BlockMetadataSweepTests: XCTestCase {
    private func makeWorld() -> (World, Player) {
        registerAllBlocks()
        registerAllItems()
        registerAllEntities()
        registerAllSystems()
        let world = World(dim: .overworld, seed: 0x5EE9)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.status = .lit
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        for x in 0..<16 { for z in 0..<16 { world.setBlock(x, 63, z, Int(cell(B.stone)), SET_SILENT) } }
        let player = Player(world: world)
        player.setPos(8.5, 64, 4.5)
        world.addEntity(player)
        return (world, player)
    }

    func testEveryBlockAtEveryMetadataValueSurvivesBeingPlacedUpdatedTickedMeasuredUsedAndBroken() {
        let (world, player) = makeWorld()
        let (x, y, z) = (8, 64, 8)
        let trace = ProcessInfo.processInfo.environment["ELYSIUM_SWEEP_TRACE"] != nil
        var checked = 0
        for id in 1..<blockDefs.count {
            for meta in 0..<16 {
                let value = Int(cell(UInt16(id), meta))
                if trace { FileHandle.standardError.write("SWEEP \(blockDefs[id].name) \(meta)\n".data(using: .utf8)!) }
                for entity in world.entities where !(entity is Player) { world.removeEntity(entity) }
                world.removeBlockEntity(x, y, z)
                // Placed with neighbour updates, as a paste's last phase does.
                world.setBlock(x, y, z, value, SET_NO_NEIGHBORS)
                if let blockEntity = placementBlockEntity(id, x, y, z) {
                    // Something to move or throw, so a hopper, dispenser or dropper really acts.
                    if blockEntity.items?.isEmpty == false { blockEntity.items?[0] = stack("arrow", 4) }
                    world.setBlockEntity(blockEntity)
                }
                world.updateNeighbors(x, y, z)
                world.notifyBlock(x, y, z, x, y, z)
                let standing = world.getBlock(x, y, z)
                if standing >> 4 == id {
                    for d in 0..<6 {
                        neighborHandlers[id]?(world, x, y, z, world.getBlock(x, y, z), x + DIR_X[d], y + DIR_Y[d], z + DIR_Z[d])
                    }
                }
                if world.getBlock(x, y, z) >> 4 == id { blockTickHandlers[id]?(world, x, y, z, world.getBlock(x, y, z)) }
                if world.getBlock(x, y, z) >> 4 == id { randomTickHandlers[id]?(world, x, y, z, world.getBlock(x, y, z)) }
                if let blockEntity = world.getBlockEntity(x, y, z) { beTickHandlers[blockEntity.type]?(world, blockEntity) }
                // Its shape, for collision and for the outline.
                var boxes: [AABB] = []
                let get: CellGetter = { dx, dy, dz in world.getBlock(x + dx, y + dy, z + dz) }
                shapeBoxes(world.getBlock(x, y, z), get, &boxes, true)
                shapeBoxes(world.getBlock(x, y, z), get, &boxes, false)
                _ = hasAnyCollision(world.getBlock(x, y, z), get)
                for face in 0..<6 { _ = sturdyFace(world.getBlock(x, y, z), face) }
                // Used with a bare hand, then broken.
                if world.getBlock(x, y, z) != 0 {
                    let hit = RaycastHit(x: x, y: y, z: z, face: 1, cell: world.getBlock(x, y, z), t: 1,
                                         px: 8.5, py: 65, pz: 8.5)
                    for index in player.inventory.indices { player.inventory[index] = nil }
                    _ = useBlock(InteractCtx(world: world, player: player), hit)
                }
                if world.getBlock(x, y, z) != 0 {
                    finishBreaking(InteractCtx(world: world, player: player), x, y, z)
                }
                world.removeBlockEntity(x, y, z)
                for dx in -2...2 { for dy in 0...2 { for dz in -2...2 { world.setBlock(x + dx, y + dy, z + dz, 0, SET_SILENT) } } }
                checked += 1
            }
        }
        XCTAssertEqual(checked, (blockDefs.count - 1) * 16)
    }
}
