import XCTest
@testable import ElysiumCore

/// The host does not take a guest's word for a block entity. Every block of a guest's template
/// gets the entity that placing it by hand would create; only a sign's text and a potted plant
/// are carried over, and only after the game's own checks (`lanHostTemplate`).
final class LANTemplateGuestBlockEntityTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
    }

    // MARK: - fixtures

    private func loadedWorld() -> World {
        let world = World(dim: .overworld, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        for z in 0..<CHUNK_W {
            for x in 0..<CHUNK_W {
                chunk.set(x, 63, z, cell(B.dirt, 0))
            }
        }
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }

    private func hostSession() -> LANMultiplayerHostSession {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        session.updatePlayerState(LANPlayerState(
            playerID: "guest", displayName: "Alex", x: 8.5, y: 64, z: 1.5, yaw: 0, pitch: 0,
            health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival))
        session.letPasteForFree("guest")
        return session
    }

    /// A row of blocks along +x, each with the block entity the guest claims for it.
    private func row(_ entries: [(cell: UInt16, blockEntity: BlockEntityData?)]) -> ObjectTemplate {
        var blocks: [TemplateBlock] = []
        var blockEntities: [BlockEntityData] = []
        for (index, entry) in entries.enumerated() {
            blocks.append(TemplateBlock(dx: index, dy: 0, dz: 0, cell: entry.cell))
            if let blockEntity = entry.blockEntity {
                blockEntity.x = index
                blockEntity.y = 0
                blockEntity.z = 0
                blockEntities.append(blockEntity)
            }
        }
        return ObjectTemplate(name: "Row", anchorX: 0, anchorY: 0, anchorZ: 0,
                              sizeX: entries.count, sizeY: 1, sizeZ: 1,
                              blocks: blocks, blockEntities: blockEntities)
    }

    private func entity(_ type: String, _ configure: (BlockEntityData) -> Void = { _ in }) -> BlockEntityData {
        let blockEntity = BlockEntityData(type: type, x: 0, y: 0, z: 0)
        configure(blockEntity)
        return blockEntity
    }

    /// Pastes `template` as a guest at (4, 64, 6) and returns the host world.
    private func paste(_ template: ObjectTemplate, file: StaticString = #filePath, line: UInt = #line) throws -> World {
        let world = loadedWorld()
        let session = hostSession()
        // The guest's own encoder accepts every shape used here: the library format has never
        // tied a block entity's type or slot count to its block.
        let intent = LANTemplateIntent(action: .placeTemplate, templateName: template.name, x: 4, y: 64, z: 6,
                                       rotation: 0, templateData: try lanGuestTemplatePayload(for: template))
        XCTAssertEqual(session.applyTemplateIntent(intent, from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: template.name), file: file, line: line)
        var steps = 0
        while session.hasActiveTemplateJob(playerID: "guest") {
            session.stepTemplateJobs(in: world)
            steps += 1
            if steps > 64 {
                XCTFail("the job did not finish", file: file, line: line)
                break
            }
        }
        return world
    }

    // MARK: - what crashed the host before

    func testHostileBlockEntityShapesArriveAsFreshOnesAndTheWorldKeepsTicking() throws {
        let hostile = row([
            // A furnace with no slots: the furnace ticker reads slot 0.
            (UInt16(cell(B.furnace, 2)), entity("furnace") { $0.items = [] }),
            // A brewing stand with two slots: the brewing ticker reads slot 4.
            (UInt16(cell(B.brewing_stand, 0)), entity("brewing") { $0.items = [nil, nil] }),
            // No slots at all and counters at their limits: `cookTime - 2` and `Int(xpBank)` trap.
            (UInt16(cell(B.blast_furnace, 2)), entity("furnace") {
                $0.cookTime = Int.min
                $0.burnTotal = Int.max
                $0.xpBank = 1e300
            }),
            // A type that does not belong to its block.
            (UInt16(cell(B.chest, 2)), entity("furnace") { $0.items = [] }),
            (UInt16(cell(B.hopper, 0)), entity("container") { $0.items = Array(repeating: nil, count: 200) }),
            // A ticking entity on a block that has none.
            (UInt16(cell(B.stone, 0)), entity("furnace") { $0.items = [] }),
            (UInt16(cell(B.oak_planks, 0)), entity("brewing") { $0.items = [] }),
        ])
        let world = try paste(hostile)

        let furnace = try XCTUnwrap(world.getBlockEntity(4, 64, 6))
        XCTAssertEqual(furnace.type, "furnace")
        XCTAssertEqual(furnace.items?.count, 3)
        let brewing = try XCTUnwrap(world.getBlockEntity(5, 64, 6))
        XCTAssertEqual(brewing.type, "brewing")
        XCTAssertEqual(brewing.items?.count, 5)
        let blast = try XCTUnwrap(world.getBlockEntity(6, 64, 6))
        XCTAssertEqual(blast.kind, "blast")
        XCTAssertEqual(blast.items?.count, 3)
        XCTAssertEqual(blast.cookTime, 0)
        XCTAssertEqual(blast.burnTotal, 0)
        XCTAssertEqual(blast.xpBank, 0)
        let chest = try XCTUnwrap(world.getBlockEntity(7, 64, 6))
        XCTAssertEqual(chest.type, "container")
        XCTAssertEqual(chest.items?.count, 27)
        let hopper = try XCTUnwrap(world.getBlockEntity(8, 64, 6))
        XCTAssertEqual(hopper.type, "hopper")
        XCTAssertEqual(hopper.items?.count, 5)
        XCTAssertNil(world.getBlockEntity(9, 64, 6), "stone must not gain a block entity")
        XCTAssertNil(world.getBlockEntity(10, 64, 6), "planks must not gain a block entity")

        // The crash was on the first block-entity tick after the paste.
        for _ in 0..<40 { world.tick() }
        XCTAssertEqual(world.getBlock(4, 64, 6), Int(cell(B.furnace, 2)))
    }

    func testEveryBlockEntityTheHostAcceptsIsOneItWouldMakeItself() throws {
        // Whatever the guest claims for each block, the host's entity for it is exactly the one
        // `placementBlockEntity` makes, field for field.
        let claims: [(UInt16, BlockEntityData?)] = [
            (UInt16(cell(B.chest, 2)), entity("container") {
                $0.items = Array(repeating: ItemStack(iid("diamond"), 64), count: 27)
                $0.lootTable = "chests/end_city"
                $0.name = "Loot"
            }),
            (UInt16(cell(B.furnace_lit, 3)), entity("furnace") {
                $0.items = [ItemStack(iid("iron_ore"), 8), ItemStack(iid("coal"), 8), ItemStack(iid("iron_ingot"), 8)]
                $0.burnTime = 900
            }),
            (UInt16(cell(B.dropper, 0)), nil),
            (UInt16(cell(B.beacon, 0)), entity("beacon") { $0.levels = 4; $0.primary = "speed" }),
            (UInt16(cell(B.decorated_pot, 0)), entity("pot") { $0.sherds = ["archer", "prize", "skull", "heart"] }),
            (UInt16(cell(B.barrel, 0)), entity("spawner") { $0.mob = "wither" }),
        ]
        let template = try lanHostTemplate(fromGuestPayload: try lanGuestTemplatePayload(for: row(claims)))

        XCTAssertEqual(template.blocks[1].cell, UInt16(cell(B.furnace, 3)), "a furnace arrives unlit")
        XCTAssertEqual(template.blockEntities.count, claims.count)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for (index, block) in template.blocks.enumerated() {
            let expected = try XCTUnwrap(placementBlockEntity(Int(block.cell >> 4), index, 0, 0))
            let actual = try XCTUnwrap(template.blockEntities.first { $0.x == index })
            XCTAssertEqual(String(decoding: try encoder.encode(actual), as: UTF8.self),
                           String(decoding: try encoder.encode(expected), as: UTF8.self),
                           "block \(index) (\(blockDefs[Int(block.cell >> 4)].name))")
        }
    }

    // MARK: - what a paste may and may not carry

    func testAJukeboxArrivesWithoutItsDiscAndASpawnerWithoutItsMob() throws {
        let world = try paste(row([
            (UInt16(cell(B.jukebox, 0)), entity("jukebox") {
                $0.disc = ItemStack(iid("music_disc_wander"), 1)
                $0.startedTick = 77
            }),
            (UInt16(cell(B.spawner, 0)), entity("spawner") { $0.mob = "wither"; $0.delay = 0 }),
            (UInt16(cell(B.end_gateway, 0)), entity("end_gateway") {
                $0.exitX = Int.max
                $0.exitZ = Int.min
                $0.exactTeleport = true
            }),
        ]))

        XCTAssertEqual(world.getBlock(4, 64, 6) >> 4, Int(B.jukebox))
        XCTAssertNil(world.getBlockEntity(4, 64, 6), "a pasted jukebox holds no disc")
        XCTAssertEqual(world.getBlock(5, 64, 6) >> 4, Int(B.spawner))
        XCTAssertNil(world.getBlockEntity(5, 64, 6), "a pasted spawner spawns nothing")
        XCTAssertNil(world.getBlockEntity(6, 64, 6), "a pasted gateway leads nowhere of the guest's choosing")
        for _ in 0..<40 { world.tick() }
    }

    func testASignKeepsItsTextWithinTheEditorsRules() throws {
        let long = String(repeating: "W", count: 300)
        let world = try paste(row([
            (UInt16(cell(bid("oak_sign"), 0)), entity("sign") {
                $0.lines = ["Hello", "Line\u{07}bell", long, "4", "a fifth line"]
                $0.glowing = true
                $0.color = "not a colour"
                $0.items = [ItemStack(iid("diamond"), 1)]
            }),
            // A sign the guest never wrote on, and one whose entity claims to be something else.
            (UInt16(cell(bid("oak_sign"), 0)), nil),
            (UInt16(cell(bid("oak_sign"), 0)), entity("container") { $0.lines = ["not a sign"] }),
        ]))

        let written = try XCTUnwrap(world.getBlockEntity(4, 64, 6))
        XCTAssertEqual(written.type, "sign")
        XCTAssertEqual(written.lines, ["Hello", "Line", String(repeating: "W", count: 89), "4"],
                       "four lines, cut at the first invalid character and at the editor's widest line")
        XCTAssertEqual(written.glowing, false)
        XCTAssertEqual(written.color, "black")
        XCTAssertNil(written.items)
        XCTAssertEqual(world.getBlockEntity(5, 64, 6)?.lines, ["", "", "", ""])
        XCTAssertEqual(world.getBlockEntity(6, 64, 6)?.type, "sign")
        XCTAssertEqual(world.getBlockEntity(6, 64, 6)?.lines, ["", "", "", ""])
    }

    func testAPottedPlantStaysOnlyWhenItIsAPlantThatCanBePotted() throws {
        let world = try paste(row([
            (UInt16(cell(B.flower_pot, 0)), entity("lectern") { $0.plant = "poppy" }),
            (UInt16(cell(B.flower_pot, 0)), entity("lectern") { $0.plant = "diamond" }),
            (UInt16(cell(B.flower_pot, 0)), entity("lectern") { $0.plant = "poppy_that_does_not_exist" }),
            // A real item whose name contains a pottable word, but which is no plant block.
            (UInt16(cell(B.flower_pot, 0)), entity("lectern") { $0.plant = "mushroom_stew" }),
            // A plant claimed for a block that is not a pot.
            (UInt16(cell(B.stone, 0)), entity("lectern") { $0.plant = "poppy" }),
        ]))

        let pot = try XCTUnwrap(world.getBlockEntity(4, 64, 6))
        XCTAssertEqual(pot.type, "lectern")
        XCTAssertEqual(pot.plant, "poppy")
        XCTAssertNil(world.getBlockEntity(5, 64, 6), "a pot cannot hand out an item that is not a plant")
        XCTAssertNil(world.getBlockEntity(6, 64, 6))
        XCTAssertNotNil(iidOpt("mushroom_stew"), "the fixture needs a real item here")
        XCTAssertNil(world.getBlockEntity(7, 64, 6), "a pot cannot hand out mushroom stew")
        XCTAssertNil(world.getBlockEntity(8, 64, 6))
    }

    func testAPayloadSliceIsReadFromItsOwnStart() throws {
        let payload = try lanGuestTemplatePayload(for: row([(UInt16(cell(B.stone, 0)), nil)]))
        let slice = (Data([9, 9, 9, 9]) + payload).dropFirst(4)
        XCTAssertNotEqual(slice.startIndex, 0)
        XCTAssertEqual(try lanHostTemplate(fromGuestPayload: slice).blocks.count, 1)
    }
}
