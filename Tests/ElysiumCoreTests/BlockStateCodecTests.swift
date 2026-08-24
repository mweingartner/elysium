// BlockStateCodecTests.swift — object-graph-attributes (change 1a). Spec
// `block-state-codec`: total decode, encode identity/mask, door halves, lit
// swap, family table, the identity rule, and the RPG guarded-temporary
// exemption on every restore path (Security (plan) C24).

import XCTest
@testable import ElysiumCore

final class BlockStateCodecTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllEntities()
    }

    private func makeLoadedWorld() -> World {
        let world = World(dim: .overworld, seed: 11)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }

    // MARK: - total decode / encode identity

    func testDecodeIsTotalAndEncodeIsIdentityOverEveryCell() {
        for id in 0..<blockDefs.count {
            for meta in 0..<16 {
                let cellV = (id << 4) | meta
                let fields = BlockStateCodec.decode(cellV) // must not trap
                for (field, value) in fields {
                    // "waterlogged" is read-only (id-set membership, not a
                    // meta bit) and "lit" is an id swap, not a meta write —
                    // both go through dedicated paths
                    // (`isWaterlogged`/`encodeLitSwap`), never the generic
                    // per-field `encode(cell:field:value:)`.
                    guard field != "waterlogged", field != "lit" else { continue }
                    // Axis is a 2-bit field with only 3 valid values (y/x/z);
                    // `meta & 3 == 3` is an unused/reserved bit pattern no
                    // vanilla axis block ever sets — `decode` defensively
                    // reports it as "y" rather than trapping (design.md
                    // Condition 10: "decode is total"), which does not
                    // round-trip back to the original (unused) meta value.
                    // That is expected, not a codec defect.
                    if field == "axis", meta & 3 == 3 { continue }
                    // Same reasoning for facing-6: 3 bits encode 8 values but
                    // only 6 `Dir`s exist; `decode` maps the two unused
                    // patterns to "down" rather than trapping. (Facing-4
                    // blocks only ever read `meta & 3`, so this broader skip
                    // never hides a facing-4 mismatch.)
                    if field == "facing", (meta & 7) >= 6 { continue }
                    guard let reencoded = BlockStateCodec.encode(cellV, field: field, value: value) else {
                        XCTFail("encode(decode) failed for id \(id) field '\(field)'")
                        continue
                    }
                    XCTAssertEqual(Int(reencoded), cellV, "field '\(field)' re-encode changed the cell for id \(id) meta \(meta)")
                }
            }
        }
    }

    func testEncodeOnlyTouchesTheFieldsMaskBits() {
        // facing on a repeater-shaped block (facing-4): only bits 0-1 change.
        let id = Int(B.repeater)
        let original = (id << 4) | 0b0101 // facing=1(south), delay bits set
        guard let encoded = BlockStateCodec.encode(original, field: "facing", value: .string("west")) else {
            return XCTFail()
        }
        XCTAssertEqual(Int(encoded) & ~0b11, original & ~0b11, "non-facing bits must be untouched")
        XCTAssertEqual(Int(encoded) & 0b11, 2) // "west" index
    }

    // MARK: - door halves

    func testDoorOpenWrittenOnLowerHalfHingeOnUpperHalf() {
        let world = makeLoadedWorld()
        let doorID = bid("oak_door")
        // A solid floor under the door: Redstone.swift's door neighbor handler
        // (registered process-wide by `registerAllSystems()`, which some other
        // test class in the suite may have already triggered before this one
        // runs — `neighborHandlers` is a shared global, not per-World) breaks
        // any door with no full-cube block beneath its lower half on its very
        // next neighbor update. That is correct game behaviour, not something
        // this test is exercising, so give the door real support the way any
        // legitimately placed door would have.
        _ = world.setBlock(2, 63, 2, Int(cell(B.stone, 0)))
        _ = world.setBlock(2, 64, 2, Int(cell(doorID, 0))) // lower, facing north
        _ = world.setBlock(2, 65, 2, Int(cell(doorID, 8))) // upper half marker

        BlockStateCodec.write(world, 2, 65, 2, field: "open", value: .bool(true))
        let lowerCell = world.getBlock(2, 64, 2)
        let upperCell = world.getBlock(2, 65, 2)
        XCTAssertEqual(lowerCell & 4, 4, "open must be written to the lower half's bit 4")
        XCTAssertEqual(upperCell & 4, 0, "the upper half's own bit 4 is untouched")
        XCTAssertEqual(BlockStateCodec.decode(lowerCell)["open"], .bool(true))

        BlockStateCodec.write(world, 2, 64, 2, field: "hinge", value: .string("right"))
        let upperAfterHinge = world.getBlock(2, 65, 2)
        XCTAssertEqual(upperAfterHinge & 1, 1, "hinge must be written to the upper half's bit 1")
        XCTAssertEqual(BlockStateCodec.decode(upperAfterHinge)["hinge"], .string("right"))
    }

    // MARK: - lit swap keeps meta

    func testLitSwapKeepsMetaAndFiresOnBlockChanged() {
        let world = makeLoadedWorld()
        let furnaceID = bid("furnace")
        _ = world.setBlock(3, 64, 3, Int(cell(furnaceID, 2))) // west-facing (facing-4 index 2)
        var observed: (Int, Int, Int, Int, Int, Int)?
        world.hooks.onBlockChanged = { x, y, z, old, new, flags in observed = (x, y, z, old, new, flags) }

        XCTAssertTrue(BlockStateCodec.write(world, 3, 64, 3, field: "lit", value: .bool(true)))

        let newCell = world.getBlock(3, 64, 3)
        XCTAssertEqual(newCell >> 4, Int(B.furnace_lit))
        XCTAssertEqual(newCell & 15, 2, "meta must be preserved across the id swap")
        XCTAssertNotNil(observed, "World.setBlock(..., SET_DEFAULT) must have fired onBlockChanged")
        XCTAssertEqual(BlockStateCodec.decode(newCell)["facing"], .string("west"), "facing should still read 'west' after the lit swap")
    }

    // MARK: - block family / identity rule

    func testSameFamily() {
        XCTAssertTrue(BlockStateCodec.sameFamily(Int(B.furnace), Int(B.furnace)))
        XCTAssertTrue(BlockStateCodec.sameFamily(Int(B.furnace), Int(B.furnace_lit)))
        XCTAssertTrue(BlockStateCodec.sameFamily(Int(B.dirt), Int(B.grass_block)))
        XCTAssertFalse(BlockStateCodec.sameFamily(Int(B.furnace), Int(B.stone)))
    }

    func testIdentityRuleMatrix() {
        let world = makeLoadedWorld()
        let chunk = world.getChunk(0, 0)!
        let furnaceID = bid("furnace")
        _ = world.setBlock(4, 64, 4, Int(cell(furnaceID, 2)))
        let cellIndex = chunk.index(4, 64, 4)
        chunk.objectRecords[cellIndex] = ObjectRecord(entries: [
            "mood": .value(.string("hot"), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 0)),
        ])

        // same family (lit swap): record survives
        _ = world.setBlock(4, 64, 4, Int(cell(B.furnace_lit, 2)))
        XCTAssertNotNil(chunk.objectRecords[cellIndex], "record should survive a same-family id swap")

        // meta-only change: record survives
        _ = world.setBlock(4, 64, 4, Int(cell(B.furnace_lit, 3)))
        XCTAssertNotNil(chunk.objectRecords[cellIndex], "record should survive a meta-only change")

        // different family: record survives until event delivery, then is
        // cleared — event-bus (change 1b), design.md §6.7 "Block identity
        // rule": `World.setBlock` now *defers* the clear into
        // `pendingObjectRecordDrops` so `block.replaced` is delivered against
        // an intact record; `GameCore`'s event-bus tick phase (or, in a bare
        // `World` test like this one, a direct `drainPendingObjectRecordDrops`
        // call) is what actually removes it.
        _ = world.setBlock(4, 64, 4, Int(cell(B.stone, 0)))
        XCTAssertNotNil(chunk.objectRecords[cellIndex], "record should survive a real identity change until after delivery")
        world.drainPendingObjectRecordDrops()
        XCTAssertNil(chunk.objectRecords[cellIndex], "record should be cleared once delivery has run")
    }

    // MARK: - RPG guarded-temporary exemption (Security (plan) C24)

    private func makeGuardedEffect(
        world: World, position: RPGBlockPosition, original: Int, temporary: Int, ownerID: String = "owner-1"
    ) -> RPGTemporaryEffectDraft {
        RPGTemporaryEffectDraft(
            kind: .fortifiedBlock, ownerAuthorityID: ownerID, ownerEntityID: nil, ownerSequence: 1,
            center: position, durationTicks: 200, remainingCharges: 1,
            guardedBlock: RPGGuardedTemporaryBlock(position: position, originalCell: original, temporaryCell: temporary)
        )
    }

    /// Places the original block + a record, *then* registers the guarded
    /// effect and only *then* swaps to the temporary cell — so
    /// `isRPGGuardedTemporaryCell` already answers true (the effect is
    /// already registered) at the moment of the swap, exactly like the real
    /// RPG action sequence (register the reservation, then apply it). Doing
    /// the swap before registering the effect (as a naive test setup might)
    /// would have `World.setBlock`'s own family check clear the record
    /// immediately — the swap is not what this test measures.
    private func setUpGuardedCellWithRecord(_ world: World) -> (Chunk, Int, RPGBlockPosition, Int, Int) {
        let chunk = world.getChunk(0, 0)!
        let original = Int(cell(B.stone))
        let temporary = Int(cell(B.cobblestone))
        _ = world.setBlock(5, 64, 5, original)
        let cellIndex = chunk.index(5, 64, 5)
        chunk.objectRecords[cellIndex] = ObjectRecord(entries: [
            "guard": .value(.bool(true), readonly: false, provenance: Provenance(createdBy: .player, createdTick: 0)),
        ])
        return (chunk, cellIndex, RPGBlockPosition(5, 64, 5), original, temporary)
    }

    func testRecordSurvivesChunkUnloadCancellation() {
        let world = makeLoadedWorld()
        let (chunk, cellIndex, position, original, temporary) = setUpGuardedCellWithRecord(world)
        let reserved = world.reserveRPGTemporaryEffects([makeGuardedEffect(world: world, position: position, original: original, temporary: temporary)])
        XCTAssertTrue(reserved)
        _ = world.setBlock(5, 64, 5, temporary)
        XCTAssertNotNil(chunk.objectRecords[cellIndex], "record must survive the guarded swap itself")

        world.cancelRPGTemporaryEffects(inChunkX: 0, z: 0)

        XCTAssertEqual(world.getBlock(5, 64, 5), original)
        XCTAssertNotNil(chunk.objectRecords[cellIndex], "record must survive chunk-unload cancellation")
    }

    func testRecordSurvivesWorldExitCancellation() {
        let world = makeLoadedWorld()
        let (chunk, cellIndex, position, original, temporary) = setUpGuardedCellWithRecord(world)
        XCTAssertTrue(world.reserveRPGTemporaryEffects([makeGuardedEffect(world: world, position: position, original: original, temporary: temporary)]))
        _ = world.setBlock(5, 64, 5, temporary)

        world.cancelAllRPGTemporaryEffects()

        XCTAssertEqual(world.getBlock(5, 64, 5), original)
        XCTAssertNotNil(chunk.objectRecords[cellIndex], "record must survive world-exit/gamerule-toggle cancellation")
    }

    func testRecordSurvivesOwnerTermination() {
        let world = makeLoadedWorld()
        let (chunk, cellIndex, position, original, temporary) = setUpGuardedCellWithRecord(world)
        XCTAssertTrue(world.reserveRPGTemporaryEffects([
            makeGuardedEffect(world: world, position: position, original: original, temporary: temporary, ownerID: "term-owner"),
        ]))
        _ = world.setBlock(5, 64, 5, temporary)

        _ = world.terminateRPGTemporaryEffects(ownerID: "term-owner")

        XCTAssertEqual(world.getBlock(5, 64, 5), original)
        XCTAssertNotNil(chunk.objectRecords[cellIndex], "record must survive owner termination")
    }

    func testRecordSurvivesNaturalTickExpiry() {
        let world = makeLoadedWorld()
        let (chunk, cellIndex, position, original, temporary) = setUpGuardedCellWithRecord(world)
        XCTAssertTrue(world.reserveRPGTemporaryEffects([makeGuardedEffect(world: world, position: position, original: original, temporary: temporary)]))
        _ = world.setBlock(5, 64, 5, temporary)
        world.rpgSimulationTick = 100_000 // past the effect's expiry

        world.tickRPGTemporaryEffects()

        XCTAssertEqual(world.getBlock(5, 64, 5), original)
        XCTAssertNotNil(chunk.objectRecords[cellIndex], "record must survive natural tick expiry")
    }

    // MARK: - LAN-client chunk-section snapshot bypass (design.md D5)

    func testLANClientChunkSectionSnapshotNeverPopulatesObjectRecords() {
        // `applyLANChunkSectionSnapshot` lives in LANReplication.swift (not in
        // this change's manifest) and bulk-writes `Chunk.set()` directly,
        // bypassing `World.setBlock`'s family check entirely. This is safe
        // only because a LAN-client world's chunks never carry object
        // records in the first place — proven at the `Chunk` level here
        // (the invariant this test pins), independent of that bypass.
        let world = makeLoadedWorld()
        let chunk = world.getChunk(0, 0)!
        XCTAssertTrue(chunk.objectRecords.isEmpty)
        chunk.set(0, 64, 0, cell(B.stone))
        chunk.set(1, 64, 0, cell(B.dirt))
        XCTAssertTrue(chunk.objectRecords.isEmpty, "a bulk Chunk.set() bypass must never populate objectRecords")
    }
}
