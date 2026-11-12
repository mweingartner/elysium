import XCTest
@testable import ElysiumCore

/// Four rules that used to be written in several places now each have one owner: the charge for
/// the plant in a flower pot (`templateBlockEntityCharge`), whether a facing names a direction
/// (`isDir`), the bed compass (`FACE_DX`/`FACE_DZ` in `twoCellPartnerPosition` and
/// `rotatedTemplateCell`) and opening a door (`toggleDoor`).
///
/// Each test below holds the owner to the rule as it was written before it had one. The `old…`
/// functions are those earlier copies, frozen as they stood in 1.5.0: they are the
/// specification here, not code to call from the game. Where the rule has more than one caller,
/// the callers are also held to each other, so a caller that stops asking the owner is caught.
final class RuleOwnerRefactorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    // MARK: - Frozen rules (1.5.0)

    /// The plant charge as the bill, the refund and the standing count each wrote it.
    private func oldPlantCharge(_ plant: String?) -> TemplateMaterialLine? {
        if let plant, let itemID = iidOpt(plant) { return TemplateMaterialLine(itemID: itemID, count: 1) }
        return nil
    }

    /// `templateStandingMaterials` as it was.
    private func oldStandingMaterials(in world: World, _ x: Int, _ y: Int, _ z: Int) -> [TemplateMaterialLine] {
        let cellValue = world.getBlock(x, y, z)
        guard case .item(let itemID, let count) = templateCellCharge(cellValue) else { return [] }
        var lines = [TemplateMaterialLine(itemID: itemID, count: count)]
        if cellValue >> 4 == Int(B.flower_pot), let plant = world.getBlockEntity(x, y, z)?.plant,
           let plantID = iidOpt(plant) {
            lines.append(TemplateMaterialLine(itemID: plantID, count: 1))
        }
        return lines
    }

    /// `twoCellPartnerPosition` as it was, with the bed compass written out in place.
    private func oldPartnerPosition(of cell: Int, _ x: Int, _ y: Int, _ z: Int) -> (x: Int, y: Int, z: Int)? {
        guard let half = twoCellHalf(of: cell) else { return nil }
        let towardSecondary = half == .primary ? 1 : -1
        if blockDefs[cell >> 4].shape == .bed {
            let facing = cell & 3
            return (x + towardSecondary * [0, 0, -1, 1][facing], y, z + towardSecondary * [-1, 1, 0, 0][facing])
        }
        return (x, y + towardSecondary, z)
    }

    /// `rotatedTemplateCell` as it was, with its quarter-turn table.
    private func oldRotatedTemplateCell(_ cell: UInt16, rotationSteps: Int) -> UInt16 {
        let id = Int(cell >> 4)
        guard id > 0, id < blockDefs.count, blockDefs[id].shape == .bed else { return cell }
        var facing = Int(cell & 3)
        for _ in 0..<(((rotationSteps % 4) + 4) % 4) { facing = [3, 2, 0, 1][facing] }
        return (cell & ~3) | UInt16(facing)
    }

    /// The door branch of `useBlock` as it was (after the iron-door test, which is unchanged).
    private func oldUseDoor(_ world: World, _ player: Player, _ x: Int, _ y: Int, _ z: Int) -> Bool {
        let c = world.getBlock(x, y, z)
        let id = c >> 4
        let meta = c & 15
        guard twoCellPartnerCell(in: world, of: c, x, y, z) != nil else { return false }
        let lowerY = (meta & 8) != 0 ? y - 1 : y
        let lower = world.getBlock(x, lowerY, z)
        world.setBlock(x, lowerY, z, Int(cell(UInt16(id), (lower & 15) ^ 4)))
        world.hooks.playSound((lower & 4) != 0 ? "block.wooden_door.close" : "block.wooden_door.open",
                              Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
        world.emitVibration(Double(x), Double(y), Double(z), 11, player)
        return true
    }

    /// The door branch of the LAN host's `applyOpenableBlockUseIntent` as it was, with the
    /// recorded change returned beside the result.
    private func oldLANUseDoor(_ world: World, _ x: Int, _ y: Int, _ z: Int)
        -> (result: LANBlockIntentResult, recorded: [LANBlockChange]) {
        let targetCell = world.getBlock(x, y, z)
        let id = targetCell >> 4
        let meta = targetCell & 15
        guard id != Int(B.iron_door) else { return (.ignored("unsupported use target"), []) }
        guard twoCellPartnerCell(in: world, of: targetCell, x, y, z) != nil else {
            return (.ignored("missing door half"), [])
        }
        let lowerY = (meta & 8) != 0 ? y - 1 : y
        let lowerCell = world.getBlock(x, lowerY, z)
        guard isValidLANReplicatedCell(lowerCell), (lowerCell >> 4) == id else {
            return (.ignored("missing door base"), [])
        }
        let updatedCell = Int(cell(UInt16(id), (lowerCell & 15) ^ 4))
        _ = world.setBlock(x, lowerY, z, updatedCell)
        world.hooks.playSound((lowerCell & 4) != 0 ? "block.wooden_door.close" : "block.wooden_door.open",
                              Double(x) + 0.5, Double(y) + 0.5, Double(z) + 0.5, 1, 1)
        let change = LANBlockChange(dimension: world.dim.rawValue, x: x, y: lowerY, z: z, cell: updatedCell)
        return (.applied([change]), [change])
    }

    // MARK: - Fixtures

    private func makeWorld(seed: UInt32 = 0x0D00) -> World {
        let world = World(dim: .overworld, seed: seed)
        let info = dimInfo(.overworld)
        let chunk = Chunk(cx: 0, cz: 0, minY: info.minY, height: info.height)
        chunk.status = .lit
        chunk.buildHeightmap()
        world.setChunk(chunk)
        world.light.initChunkLight(chunk)
        return world
    }

    /// Writes `value` straight into the chunk: no neighbour update, no light, no block entity.
    private func put(_ world: World, _ x: Int, _ y: Int, _ z: Int, _ value: Int) {
        guard let chunk = world.getChunkAt(x, z), chunk.inYRange(y) else { return XCTFail("no chunk at \(x) \(y) \(z)") }
        chunk.set(posMod(x, CHUNK_W), y, posMod(z, CHUNK_W), UInt16(value))
    }

    private func column(_ world: World, _ x: Int, _ z: Int, _ ys: ClosedRange<Int>) -> [Int] {
        ys.map { world.getBlock(x, $0, z) }
    }

    private func recordSounds(_ world: World) -> () -> [String] {
        var sounds: [String] = []
        world.hooks.playSound = { name, x, y, z, volume, pitch in sounds.append("\(name) \(x) \(y) \(z) \(volume) \(pitch)") }
        return { defer { sounds.removeAll() }; return sounds }
    }

    private func makeHostSession() -> LANMultiplayerHostSession {
        let session = LANMultiplayerHostSession()
        _ = session.acceptPeer(playerID: "peer-a", displayName: "Alex")
        _ = session.updatePlayerState(LANPlayerState(
            playerID: "peer-a", displayName: "Alex", x: 2.5, y: 64, z: 1.5, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival,
            dimension: Dim.overworld.rawValue))
        return session
    }

    private func useHit(_ world: World, _ x: Int, _ y: Int, _ z: Int) -> RaycastHit {
        RaycastHit(x: x, y: y, z: z, face: 1, cell: world.getBlock(x, y, z), t: 1,
                   px: Double(x) + 0.5, py: Double(y) + 1, pz: Double(z) + 0.5)
    }

    // MARK: - The plant in a flower pot

    /// Every name a pot could carry (every item, every block, nothing, and names that are no
    /// item) is charged by the owner exactly as the three inline copies charged it: one of the
    /// item of that name, or nothing.
    func testThePlantChargeIsTheOldRuleForEveryName() {
        var names: [String?] = [nil, "", " poppy", "POPPY", "minecraft:poppy", "poppy\u{0}", "not_an_item"]
        names += itemDefs.map(\.name)
        names += blockDefs.map(\.name)
        var charged = 0
        for name in names {
            let pot = BlockEntityData(type: "flower_pot", x: 0, y: 0, z: 0)
            pot.plant = name
            let charge = templateBlockEntityCharge(pot)
            XCTAssertEqual(charge, oldPlantCharge(name), "plant \(String(describing: name))")
            if charge != nil { charged += 1 }
        }
        XCTAssertGreaterThan(charged, itemDefs.count / 2, "the sweep reached names that are items")
    }

    /// The bill, the refund for pots a paste could not write and the count of what still
    /// stands all charge a pot's plant through the one owner, so for any plant they agree with
    /// it and with each other. The pot itself is one flower pot in the bill and the standing
    /// count; the refund here is for the block entity alone.
    func testTheBillTheRefundAndTheStandingCountChargeAPotsPlantAlike() throws {
        let world = makeWorld()
        let potCell = Int(cell(B.flower_pot))
        let potItem = iid("flower_pot")
        let names: [String?] = [nil, "", "not_an_item", "poppy", "dandelion", "cactus", "oak_sapling",
                                "flower_pot", "diamond_sword"]
        for (index, name) in names.enumerated() {
            let which = "plant \(String(describing: name))"
            let expected = templateBlockEntityCharge({
                let be = BlockEntityData(type: "flower_pot", x: 0, y: 0, z: 0); be.plant = name; return be
            }())
            var expectedCounts: [Int: Int] = [potItem: 1]
            if let expected { expectedCounts[expected.itemID, default: 0] += expected.count }

            let templatePot = BlockEntityData(type: "flower_pot", x: 0, y: 0, z: 0)
            templatePot.plant = name
            let bill = try templateMaterialBill(ObjectTemplate(
                name: "Pot", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 1, sizeY: 1, sizeZ: 1,
                blocks: [TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(potCell))], blockEntities: [templatePot]))
            XCTAssertEqual(bill, TemplateMaterialBill(expectedCounts), "\(which): the bill")

            var refundCounts = expectedCounts
            refundCounts[potItem, default: 0] -= 1
            refundCounts = refundCounts.filter { $0.value != 0 }
            XCTAssertEqual(templateUnwrittenMaterials(unplacedBlocks: [], unplacedBlockEntities: [templatePot],
                                                      unfilledSupportCells: 0),
                           refundCounts, "\(which): the refund")

            let x = index
            world.setBlock(x, 70, 3, potCell, SET_SILENT)
            let standingPot = BlockEntityData(type: "flower_pot", x: x, y: 70, z: 3)
            standingPot.plant = name
            world.setBlockEntity(standingPot)
            var standing: [Int: Int] = [:]
            for line in templateStandingMaterials(in: world, x, 70, 3) { standing[line.itemID, default: 0] += line.count }
            XCTAssertEqual(standing, expectedCounts, "\(which): what stands")
        }
    }

    /// What stands in a cell is counted as before for every registered block with no block
    /// entity, with a block entity carrying a plant, and with one carrying a name that is no
    /// item: only a flower pot ever adds its plant.
    func testStandingMaterialsAreTheOldRuleForEveryBlock() {
        let world = makeWorld()
        var pots = 0
        for id in 1..<blockDefs.count {
            for plant in [nil, "poppy", "not_an_item"] as [String?] {
                let x = id % 16, z = (id / 16) % 16, y = 80 + (id / 256) * 4 + (plant == nil ? 0 : plant == "poppy" ? 1 : 2)
                world.setBlock(x, y, z, Int(cell(UInt16(id))), SET_SILENT)
                if let plant {
                    let be = BlockEntityData(type: "flower_pot", x: x, y: y, z: z)
                    be.plant = plant
                    world.setBlockEntity(be)
                }
                XCTAssertEqual(templateStandingMaterials(in: world, x, y, z), oldStandingMaterials(in: world, x, y, z),
                               "\(blockDefs[id].name) with plant \(String(describing: plant))")
                if id == Int(B.flower_pot), plant == "poppy" {
                    XCTAssertEqual(templateStandingMaterials(in: world, x, y, z).count, 2, "the control: a potted poppy")
                    pots += 1
                }
            }
        }
        XCTAssertEqual(pots, 1)
    }

    // MARK: - Whether a facing names a direction

    /// `isDir` is the bound each caller wrote (`facing > 5` on three bits, `facing >= 0,
    /// facing < 6`), for every value three or four bits hold and far outside them, and a
    /// facing is a direction exactly when `dirStep` moves one cell for it.
    func testIsDirIsTheOldBoundAndAgreesWithDirStep() {
        for meta in 0..<16 {
            XCTAssertEqual(isDir(meta & 7), !((meta & 7) > 5), "three bits of \(meta)")
            XCTAssertEqual(isDir(meta), meta >= 0 && meta < 6, "four bits \(meta)")
        }
        for dir in Array(-300...300) + [Int.min, Int.min + 1, Int.max, Int.max - 1, 1 << 40, -(1 << 40)] {
            XCTAssertEqual(isDir(dir), dir >= 0 && dir < 6, "direction \(dir)")
            let step = dirStep(dir)
            XCTAssertEqual(abs(step.x) + abs(step.y) + abs(step.z), isDir(dir) ? 1 : 0, "direction \(dir) steps")
        }
    }

    /// A dispenser or dropper of every metadata value, fired four times from a fixed random
    /// state: for a facing of 0...5 it draws one slot and then two numbers for the throw, in that
    /// order, so the same items leave the same slots in the same order; for 6 or 7 it draws
    /// nothing and throws nothing. Checked over several seeds against an independent stream.
    func testADispenserDrawsTheSameRandomNumbersForEveryFacing() throws {
        let saved = redstoneRng
        defer { redstoneRng = saved }
        let stocked: [(slot: Int, name: String, count: Int)] = [(1, "cobblestone", 9), (4, "stone", 9), (7, "dirt", 9)]
        var thrown = 0
        for block in [B.dispenser, B.dropper] {
            let fire = try XCTUnwrap(blockTickHandlers[Int(block)])
            for meta in 0..<16 {
                for seed: UInt32 in [1, 0x4ED0, 0xDEAD_BEEF, 77, 123_456] {
                    let world = makeWorld()
                    world.setBlock(8, 64, 8, Int(cell(block, meta)), SET_SILENT)
                    let contents = try XCTUnwrap(placementBlockEntity(Int(block), 8, 64, 8))
                    for stock in stocked { contents.items?[stock.slot] = stack(stock.name, stock.count) }
                    world.setBlockEntity(contents)
                    redstoneRng = RandomX(seed)
                    var oracle = RandomX(seed)
                    let facing = meta & 7
                    var expected = Dictionary(uniqueKeysWithValues: stocked.map { ($0.slot, $0.count) })
                    let which = "\(blockDefs[Int(block)].name) metadata \(meta) seed \(seed)"
                    for shot in 0..<4 {
                        let entitiesBefore = world.entities.count
                        fire(world, 8, 64, 8, world.getBlock(8, 64, 8))
                        let newItems = world.entities[entitiesBefore...].compactMap { $0 as? ItemEntity }
                        if facing < 6 {
                            let slots = expected.filter { $0.value > 0 }.keys.sorted()
                            let slot = slots[oracle.nextInt(slots.count)]
                            let noiseX = oracle.nextFloat(), noiseZ = oracle.nextFloat()
                            expected[slot]! -= 1
                            XCTAssertEqual(newItems.count, 1, "\(which) shot \(shot)")
                            let item = try XCTUnwrap(newItems.first)
                            XCTAssertEqual(item.stack.id, iid(stocked.first { $0.slot == slot }!.name), "\(which) shot \(shot)")
                            XCTAssertEqual(item.stack.count, 1)
                            XCTAssertEqual(item.vx, Double(DIR_X[facing]) * 0.2 + (noiseX - 0.5) * 0.05, "\(which) shot \(shot)")
                            XCTAssertEqual(item.vy, Double(DIR_Y[facing]) * 0.2 + 0.1)
                            XCTAssertEqual(item.vz, Double(DIR_Z[facing]) * 0.2 + (noiseZ - 0.5) * 0.05, "\(which) shot \(shot)")
                            thrown += 1
                        } else {
                            XCTAssertTrue(newItems.isEmpty, "\(which) shot \(shot)")
                        }
                        XCTAssertTrue(redstoneRng.stateWords == oracle.stateWords, "\(which) shot \(shot): the random stream")
                        let items = try XCTUnwrap(world.getBlockEntity(8, 64, 8)?.items)
                        for stock in stocked {
                            XCTAssertEqual(items[stock.slot]?.count ?? 0, expected[stock.slot], "\(which) shot \(shot) slot \(stock.slot)")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(thrown, 2 * 12 * 5 * 4, "metadata 0...5 and 8...13 throw on every shot")
    }

    // MARK: - The bed compass

    /// Where the other half of a two-cell block stands is the old answer for every cell a
    /// chunk can hold (every id, registered or not, and every metadata value), at the origin
    /// and far from it.
    func testThePartnerPositionIsTheOldCompassForEveryCell() {
        var beds = 0
        for value in 0...Int(UInt16.max) {
            for (x, y, z) in [(0, 0, 0), (-17, -64, 33), (1_000_003, 319, -1_000_003)] {
                let new = twoCellPartnerPosition(of: value, x, y, z)
                let old = oldPartnerPosition(of: value, x, y, z)
                XCTAssertEqual(new.map { [$0.x, $0.y, $0.z] }, old.map { [$0.x, $0.y, $0.z] }, "cell \(value) at \(x) \(y) \(z)")
            }
            let id = value >> 4
            if id > 0, id < blockDefs.count, blockDefs[id].shape == .bed { beds += 1 }
        }
        XCTAssertGreaterThanOrEqual(beds, 16 * 16, "every colour of bed, every metadata value")
    }

    /// Turning is the old quarter-turn table for every cell a chunk can hold and any number of
    /// turns, negative, large, and at the ends of `Int`.
    func testTurningABedIsTheOldQuarterTurnForEveryCellAndEveryTurn() {
        let turns = Array(-9...9) + [Int.min, Int.min + 1, Int.min + 2, Int.min + 3,
                                     Int.max, Int.max - 1, Int.max - 2, Int.max - 3, 1_000_001, -1_000_001]
        var mismatches: [String] = []
        for value in 0...Int(UInt16.max) {
            let cellValue = UInt16(value)
            for steps in turns {
                let new = rotatedTemplateCell(cellValue, rotationSteps: steps)
                let old = oldRotatedTemplateCell(cellValue, rotationSteps: steps)
                if new != old, mismatches.count < 20 { mismatches.append("cell \(value) turned \(steps): \(old) became \(new)") }
            }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// The rule the compass now holds once: in a template of any size, turned any number of
    /// times, each half of a bed finds the other where the turned cells put it. Checked from
    /// both halves, for every bed, every facing and every position the bed fits in.
    func testATurnedBedsHalvesFindEachOtherInAnyTemplate() {
        var checked = 0
        for id in 1..<blockDefs.count where blockDefs[id].shape == .bed {
            for facing in 0..<4 {
                let foot = Int(cell(UInt16(id), facing)), head = Int(cell(UInt16(id), 4 | facing))
                for (sizeX, sizeZ) in [(2, 1), (1, 2), (3, 5), (6, 2)] {
                    for footX in 0..<sizeX {
                        for footZ in 0..<sizeZ {
                            let headX = footX + FACE_DX[facing], headZ = footZ + FACE_DZ[facing]
                            guard (0..<sizeX).contains(headX), (0..<sizeZ).contains(headZ) else { continue }
                            for steps in -5...5 {
                                let turnedFoot = Int(rotatedTemplateCell(UInt16(foot), rotationSteps: steps))
                                let turnedHead = Int(rotatedTemplateCell(UInt16(head), rotationSteps: steps))
                                let footAt = rotatedTemplateCoordinate(x: footX, y: 0, z: footZ, sizeX: sizeX, sizeZ: sizeZ, rotationSteps: steps)
                                let headAt = rotatedTemplateCoordinate(x: headX, y: 0, z: headZ, sizeX: sizeX, sizeZ: sizeZ, rotationSteps: steps)
                                let which = "\(blockDefs[id].name) facing \(facing) at \(footX),\(footZ) in \(sizeX)x\(sizeZ) turned \(steps)"
                                let fromFoot = twoCellPartnerPosition(of: turnedFoot, footAt.x, 0, footAt.z)
                                let fromHead = twoCellPartnerPosition(of: turnedHead, headAt.x, 0, headAt.z)
                                XCTAssertEqual(fromFoot.map { [$0.x, $0.y, $0.z] }, [headAt.x, 0, headAt.z], which)
                                XCTAssertEqual(fromHead.map { [$0.x, $0.y, $0.z] }, [footAt.x, 0, footAt.z], which)
                                XCTAssertEqual(turnedFoot & 3, turnedHead & 3, "\(which): both halves turn alike")
                                checked += 1
                            }
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 16 * 4 * 11)
    }

    // MARK: - Opening a door

    /// What can stand above or below a door half: nothing, a block, the same door in every
    /// state, another wooden door, and an iron door.
    private func doorNeighbours(_ door: Int) -> [Int] {
        let other = door == Int(B.oak_door) ? Int(B.birch_door) : Int(B.oak_door)
        return [0, Int(cell(B.stone))]
            + (0..<16).map { Int(cell(UInt16(door), $0)) }
            + [0, 4, 8, 12].map { Int(cell(UInt16(other), $0)) }
            + [0, 8].map { Int(cell(B.iron_door, $0)) }
    }

    /// Using a wooden door, by hand and for a LAN guest, in every neighbourhood: every wooden
    /// door, every metadata value of the used half and every cell above and below it. Both
    /// callers end with the same column, the same answer and the same sound as the old rule;
    /// the host records exactly the change it returns; and the host's old "missing door base"
    /// refusal is never reached, because a half with its partner always has a lower half of
    /// its own block.
    func testUsingADoorIsTheOldRuleForBothCallersInEveryNeighbourhood() throws {
        registerAllEntities()
        let doors = (1..<blockDefs.count).filter { blockDefs[$0].shape == .door && $0 != Int(B.iron_door) }
        XCTAssertEqual(doors.count, WOODS.count, "every wood's door")
        let (x, y, z) = (2, 64, 1)
        var cases = 0, opened = 0, baseRefusals = 0
        for door in doors {
            let neighbours = doorNeighbours(door)
            // Four worlds that see the same cells: the old rule and the new, by hand and for a guest.
            let worlds = (0..<4).map { _ in makeWorld() }
            let sounds = worlds.map { recordSounds($0) }
            let player = Player(world: worlds[0]), newPlayer = Player(world: worlds[1])
            player.setPos(12.5, 64, 12.5)
            newPlayer.setPos(12.5, 64, 12.5)
            let session = makeHostSession()
            for meta in 0..<16 {
                for below in neighbours {
                    for above in neighbours {
                        for world in worlds {
                            put(world, x, y - 2, z, Int(cell(B.stone)))
                            put(world, x, y - 1, z, below)
                            put(world, x, y, z, Int(cell(UInt16(door), meta)))
                            put(world, x, y + 1, z, above)
                            put(world, x, y + 2, z, 0)
                            put(world, x, y + 3, z, 0)
                        }
                        let entitiesBefore = worlds.map(\.entities.count)
                        func which() -> String {
                            "\(blockDefs[door].name) \(meta), below \(below >> 4):\(below & 15), above \(above >> 4):\(above & 15)"
                        }

                        let oldOpened = oldUseDoor(worlds[0], player, x, y, z)
                        let newOpened = useBlock(InteractCtx(world: worlds[1], player: newPlayer), useHit(worlds[1], x, y, z))
                        let old = oldLANUseDoor(worlds[2], x, y, z)
                        let new = session.applyBlockIntent(
                            LANBlockIntent(action: .useBlock, x: x, y: y, z: z, face: Dir.up, selectedHotbarSlot: 0),
                            from: "peer-a", to: worlds[3])
                        let newRecorded = session.drainBlockChanges()

                        XCTAssertEqual(newOpened, oldOpened, "\(which()): by hand")
                        XCTAssertEqual(new, old.result, "\(which()): for a guest")
                        XCTAssertEqual(newRecorded, old.recorded, "\(which()): recorded for the guests")
                        let columns = worlds.map { column($0, x, z, (y - 3)...(y + 4)) }
                        XCTAssertEqual(columns[1], columns[0], "\(which()): the cells, by hand")
                        XCTAssertEqual(columns[3], columns[2], "\(which()): the cells, for a guest")
                        XCTAssertEqual(columns[3], columns[1], "\(which()): a guest and the player open a door alike")
                        let heard = sounds.map { $0() }
                        XCTAssertEqual(heard[1], heard[0], "\(which()): the sound, by hand")
                        XCTAssertEqual(heard[3], heard[2], "\(which()): the sound, for a guest")
                        XCTAssertEqual(heard[3], heard[1], "\(which()): a guest and the player hear the same")
                        XCTAssertEqual(worlds.map(\.entities.count).enumerated().map { $0.element - entitiesBefore[$0.offset] },
                                       Array(repeating: worlds[0].entities.count - entitiesBefore[0], count: 4), "\(which()): drops")
                        if case .applied = new { XCTAssertTrue(newOpened, which()) } else { XCTAssertFalse(newOpened, which()) }
                        if old.result == .ignored("missing door base") { baseRefusals += 1 }
                        if oldOpened { opened += 1 }
                        cases += 1
                    }
                }
            }
        }
        XCTAssertEqual(baseRefusals, 0, "no neighbourhood reaches the old missing-base refusal")
        XCTAssertGreaterThan(opened, doors.count * 16, "the sweep opens doors, not only refuses")
        XCTAssertEqual(cases, doors.count * 16 * 24 * 24)
    }

    /// A door at the top or bottom of the world, whose other half would stand outside it, does
    /// not open, by the old rule or the new; one with both halves inside does.
    func testADoorAtTheEdgeOfTheWorldIsTheOldRule() {
        let info = dimInfo(.overworld)
        let top = info.minY + info.height - 1, bottom = info.minY
        let (x, z) = (5, 5)
        for (lowerY, lowerMeta, usedY, partnerInside) in [(top, 0, top, false), (bottom - 1, 0, bottom, false),
                                                           (top - 1, 0, top, true), (bottom, 0, bottom, true)] {
            for upperMeta in [8, 9, 12, 15] {
                let worlds = [makeWorld(), makeWorld()]
                let sounds = worlds.map { recordSounds($0) }
                let players = worlds.map { world -> Player in let p = Player(world: world); p.setPos(12.5, 64, 12.5); return p }
                for world in worlds {
                    if world.getChunkAt(x, z)!.inYRange(lowerY) { put(world, x, lowerY, z, Int(cell(B.oak_door, lowerMeta))) }
                    if world.getChunkAt(x, z)!.inYRange(lowerY + 1) { put(world, x, lowerY + 1, z, Int(cell(B.oak_door, upperMeta))) }
                }
                let which = "lower half at \(lowerY), upper \(upperMeta), used at \(usedY)"
                let old = oldUseDoor(worlds[0], players[0], x, usedY, z)
                let new = useBlock(InteractCtx(world: worlds[1], player: players[1]), useHit(worlds[1], x, usedY, z))
                XCTAssertEqual(new, old, which)
                XCTAssertEqual(new, partnerInside, which)
                XCTAssertEqual(column(worlds[1], x, z, (usedY - 1)...(usedY + 1)), column(worlds[0], x, z, (usedY - 1)...(usedY + 1)), which)
                XCTAssertEqual(sounds[1](), sounds[0](), which)
            }
        }
    }

    /// The host's old second refusal needed a lower half that was not of the used door's
    /// block. Above and below a used half stands, in turn, a cell of every registered block
    /// in every state: whenever the old host got past "missing door half", the lower half was
    /// of the door's own block, so "missing door base" could not be returned, and `toggleDoor`
    /// answers exactly where the old host applied a change.
    func testNoCellBesideADoorReachesTheOldMissingBaseRefusal() {
        let world = makeWorld(), oracleWorld = makeWorld()
        let (x, y, z) = (4, 64, 4)
        var applied = 0
        for used in [Int(cell(B.oak_door, 0)), Int(cell(B.oak_door, 8)), Int(cell(B.oak_door, 12)), Int(cell(B.oak_door, 5))] {
            for value in 0...Int(UInt16.max) where (value >> 4) < blockDefs.count {
                let partnerY = (used & 8) != 0 ? y - 1 : y + 1
                for w in [world, oracleWorld] {
                    put(w, x, y, z, used)
                    put(w, x, partnerY, z, value)
                }
                let old = oldLANUseDoor(oracleWorld, x, y, z)
                let new = toggleDoor(in: world, used, x, y, z)
                XCTAssertNotEqual(old.result, .ignored("missing door base"), "door \(used & 15) beside cell \(value)")
                XCTAssertEqual(new.map { LANBlockChange(dimension: world.dim.rawValue, x: x, y: $0.y, z: z, cell: $0.cell) },
                               old.recorded.first, "door \(used & 15) beside cell \(value)")
                if new != nil { applied += 1 }
            }
        }
        XCTAssertEqual(applied, 4 * 8, "only the eight states of the door's own other half open it")
    }
}
