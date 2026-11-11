import XCTest
@testable import ElysiumCore

/// What a paste costs the player at the keyboard: a single-player world or a LAN host
/// (`GameCore+TemplateMaterials.swift`). Every test goes through the calls the app makes:
/// arm the preview, click, let the game tick the job, Command-Z.
@MainActor
final class TemplatePasteCostTests: XCTestCase {
    // MARK: - Fixture

    private final class CapturingHost: GameHost {
        var actionBars: [String] = []
        var chat: [String] = []
        func showActionBar(_ text: String, _ time: Int) { actionBars.append(text) }
        func pushChat(_ line: String) { chat.append(line) }
        func hasScreen() -> Bool { false }; func screenPausesGame() -> Bool { false }
        func openScreen(_ kind: String, _ data: ScreenData?) {}
        func openTrading(_ villager: Mob) {}; func openVehicleChest(_ kind: String, _ vehicle: Entity) {}
        func openChat(_ prefix: String) {}; func openDeathScreen(_ message: String) {}
        func openPauseScreen() {}; func openTitleScreen() {}; func closeAllScreens() {}
        func releasePointer() {}; func capturePointer() {}
        func pushToast(_ adv: AdvancementDef) {}; func setBossBars(_ bars: [BossBarInfo]) {}
        func playSound(_ name: String, _ x: Double, _ y: Double, _ z: Double,
                       _ volume: Double, _ pitch: Double) {}
        func playUI(_ name: String) {}; func setAudioEnvironment(_ underwater: Bool, _ caveFactor: Double) {}
        func setAudioListener(_ x: Double, _ y: Double, _ z: Double, _ yaw: Double) {}
        func tickMusic(_ mood: String, _ enabled: Bool) {}; func stopDisc() {}
        func addParticles(_ type: String, _ x: Double, _ y: Double, _ z: Double,
                          _ count: Int, _ spread: Double, _ cell: Int) {}
        func spawnPrecipitation(_ kind: String, _ x: Double, _ y: Double, _ z: Double,
                                _ groundY: Double) {}
        func uploadMesh(_ cx: Int, _ sy: Int, _ cz: Int, _ minY: Int, _ mesh: MeshOutput) {}
        func removeChunkMeshes(_ cx: Int, _ cz: Int, _ sections: Int) {}; func clearAllSections() {}
    }

    private struct Fixture {
        let game: GameCore
        let world: World
        let screen: CapturingHost
        var player: Player { game.player }
    }

    /// A game whose overworld is loaded for 64 blocks around the origin, with stone ground up
    /// to y 63 where objects land, and the player at the origin looking along +z.
    private func makeFixture(mode: Int = GameMode.survival) throws -> Fixture {
        registerAllBlocks()
        registerAllItems()
        registerAllSystems()
        let game = GameCore(db: try PersistenceTestSupport.makeDatabase(owner: self, label: "paste-cost"))
        game.createWorld(name: "Paste Cost", seedText: "paste-cost", mode: mode, difficulty: 0)
        let world = World(dim: .overworld, seed: 8642)
        let info = dimInfo(.overworld)
        for cz in -4...4 {
            for cx in -4...4 {
                let chunk = Chunk(cx: cx, cz: cz, minY: info.minY, height: info.height)
                chunk.status = .lit
                world.setChunk(chunk)
            }
        }
        for x in -20...20 { for z in -8...40 { for y in 56...63 {
            world.setBlock(x, y, z, Int(cell(B.stone)), SET_SILENT)
        } } }
        world.hooks = game.world.hooks
        world.spawnX = game.world.spawnX
        world.spawnY = game.world.spawnY
        world.spawnZ = game.world.spawnZ
        game.player.world.removeEntity(game.player)
        game.player.world = world
        game.player.setPos(0.5, 64, 0.5)
        game.player.yaw = 0
        game.player.pitch = 0
        world.addEntity(game.player)
        game.worlds[game.dim] = world
        for index in game.player.inventory.indices { game.player.inventory[index] = nil }
        let screen = CapturingHost()
        game.host = screen
        return Fixture(game: game, world: world, screen: screen)
    }

    private func object(_ name: String, _ blocks: [(Int, Int, Int, String, Int)],
                        blockEntities: [BlockEntityData] = []) -> ObjectTemplate {
        ObjectTemplate(name: name, anchorX: 0, anchorY: 0, anchorZ: 0,
                       sizeX: (blocks.map(\.0).max() ?? 0) + 1,
                       sizeY: (blocks.map(\.1).max() ?? 0) + 1,
                       sizeZ: (blocks.map(\.2).max() ?? 0) + 1,
                       blocks: blocks.map { TemplateBlock(dx: $0.0, dy: $0.1, dz: $0.2, cell: cell(bid($0.3), $0.4)) },
                       blockEntities: blockEntities)
    }

    /// A row of `count` oak planks along x.
    private func planks(_ count: Int, name: String = "Planks") -> ObjectTemplate {
        object(name, (0..<count).map { ($0, 0, 0, "oak_planks", 0) })
    }

    /// Arms the preview and makes sure the object lands on solid stone, so no ground has to be
    /// filled in unless a test digs a gap itself. Returns where the object's origin lands.
    @discardableResult
    private func arm(_ fixture: Fixture, _ template: ObjectTemplate) throws -> (x: Int, y: Int, z: Int) {
        try fixture.game.beginTemplatePlacement(template)
        let target = try XCTUnwrap(fixture.game.templatePlacementTarget())
        for dx in 0..<template.sizeX {
            for dz in 0..<template.sizeZ {
                fixture.world.setBlock(target.originX + dx, target.originY - 1, target.originZ + dz,
                                       Int(cell(B.stone)), SET_SILENT)
            }
        }
        return (target.originX, target.originY, target.originZ)
    }

    private func finishJob(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        var frames = 0
        while fixture.game.hasActiveTemplatePlacementJob() {
            _ = fixture.game.frame(dtMs: TICK_MS)
            frames += 1
            guard frames < 400 else { return XCTFail("the placement job never finished", file: file, line: line) }
        }
    }

    /// Arms, clicks and runs the job to its end.
    @discardableResult
    private func paste(_ fixture: Fixture, _ template: ObjectTemplate) throws -> (x: Int, y: Int, z: Int) {
        let origin = try arm(fixture, template)
        _ = try fixture.game.commitTemplatePlacement()
        finishJob(fixture)
        return origin
    }

    private func give(_ fixture: Fixture, _ name: String, _ count: Int, slot: Int) {
        fixture.player.inventory[slot] = stack(name, count)
    }

    private func carried(_ fixture: Fixture, _ name: String) -> Int { fixture.player.countItem(iid(name)) }

    @discardableResult
    private func placeChest(_ fixture: Fixture, at position: (Int, Int, Int), _ contents: [(String, Int)]) -> BlockEntityData {
        fixture.world.setBlock(position.0, position.1, position.2, Int(cell(B.chest)), SET_SILENT)
        let chest = makeContainerBE(position.0, position.1, position.2, 27)
        for (index, entry) in contents.enumerated() { chest.items?[index] = stack(entry.0, entry.1) }
        fixture.world.setBlockEntity(chest)
        return chest
    }

    private func stored(_ fixture: Fixture, at position: (Int, Int, Int), _ name: String) -> Int {
        let items = fixture.world.getBlockEntity(position.0, position.1, position.2)?.items ?? []
        return items.compactMap { $0 }.filter { $0.id == iid(name) }.reduce(0) { $0 + $1.count }
    }

    private func dropped(_ fixture: Fixture, _ name: String) -> Int {
        fixture.world.entities.compactMap { $0 as? ItemEntity }.filter { $0.stack.id == iid(name) }
            .reduce(0) { $0 + $1.stack.count }
    }

    // MARK: - Paying

    func testASurvivalPasteTakesItsBlocksFromTheInventoryAndSaysSo() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 10, slot: 3)
        let origin = try arm(fixture, planks(6))
        XCTAssertTrue(fixture.screen.chat.contains("§7Costs 6 materials. You have them all."), "\(fixture.screen.chat)")
        XCTAssertEqual(carried(fixture, "oak_planks"), 10, "arming the preview costs nothing")

        XCTAssertNil(try fixture.game.commitTemplatePlacement())
        XCTAssertEqual(carried(fixture, "oak_planks"), 4, "the click pays, before the first block is placed")
        XCTAssertTrue(fixture.game.hasActiveTemplatePlacementJob())
        finishJob(fixture)

        for dx in 0..<6 { XCTAssertEqual(fixture.world.getBlockId(origin.x + dx, origin.y, origin.z), Int(B.oak_planks)) }
        XCTAssertEqual(carried(fixture, "oak_planks"), 4)
        XCTAssertEqual(fixture.game.lastTemplatePlacementUndo?.materials?.total, 6)
        XCTAssertTrue(fixture.screen.chat.contains("§7Used 6 materials: 6 from your inventory."), "\(fixture.screen.chat)")
    }

    func testASurvivalPasteTakesFromTheInventoryFirstThenFromContainersWithinCraftingRange() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 4, slot: 0)
        let near = (-10, 64, 10), far = (60, 64, 0)
        placeChest(fixture, at: near, [("oak_planks", 64)])
        placeChest(fixture, at: far, [("oak_planks", 64)])
        try paste(fixture, planks(10))

        XCTAssertEqual(carried(fixture, "oak_planks"), 0)
        XCTAssertEqual(stored(fixture, at: near, "oak_planks"), 58)
        XCTAssertEqual(stored(fixture, at: far, "oak_planks"), 64, "beyond \(CRAFTING_CONTAINER_RADIUS) blocks nothing is taken")
        let receipt = try XCTUnwrap(fixture.game.lastTemplatePlacementUndo?.materials)
        XCTAssertEqual(receipt.fromInventory, 4)
        XCTAssertEqual(receipt.fromStorage, 6)
        XCTAssertTrue(fixture.screen.chat.contains("§7Used 10 materials: 4 from your inventory, 6 from containers."),
                      "\(fixture.screen.chat)")
    }

    func testAPasteThatCannotBePaidPlacesNothingTakesNothingAndStaysArmed() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 2, slot: 0)
        let chestAt = (5, 64, -3)
        placeChest(fixture, at: chestAt, [("oak_planks", 3)])
        let origin = try arm(fixture, planks(9))
        XCTAssertTrue(fixture.screen.chat.contains("§eCosts 9 materials. Still missing 4 Oak Planks."), "\(fixture.screen.chat)")

        fixture.game.mouseDown(0)
        XCTAssertFalse(fixture.game.hasActiveTemplatePlacementJob())
        XCTAssertTrue(fixture.screen.chat.contains("§cMissing 4 Oak Planks - nothing was placed."), "\(fixture.screen.chat)")
        XCTAssertEqual(fixture.screen.actionBars.last, "Missing materials - nothing was placed",
                       "the action bar holds one short line; the list is in chat")
        for dx in 0..<9 { XCTAssertEqual(fixture.world.getBlock(origin.x + dx, origin.y, origin.z), 0) }
        XCTAssertEqual(carried(fixture, "oak_planks"), 2)
        XCTAssertEqual(stored(fixture, at: chestAt, "oak_planks"), 3)
        XCTAssertNil(fixture.game.lastTemplatePlacementUndo)
        XCTAssertNotNil(fixture.game.templatePlacementTarget(), "the preview stays armed")

        // The player fetches the rest and clicks again.
        give(fixture, "oak_planks", 4, slot: 1)
        fixture.game.mouseDown(0)
        finishJob(fixture)
        for dx in 0..<9 { XCTAssertEqual(fixture.world.getBlockId(origin.x + dx, origin.y, origin.z), Int(B.oak_planks)) }
        XCTAssertEqual(carried(fixture, "oak_planks") + stored(fixture, at: chestAt, "oak_planks"), 0)
    }

    func testOnlyPlainStacksPayForAPaste() throws {
        let fixture = try makeFixture()
        fixture.player.inventory[0] = ItemStack(iid("oak_planks"), 5, label: "Keep")
        give(fixture, "oak_planks", 1, slot: 1)
        try arm(fixture, planks(3))
        XCTAssertThrowsError(try fixture.game.commitTemplatePlacement()) { error in
            XCTAssertEqual(error as? TemplateError, .materials("Missing 2 Oak Planks - nothing was placed."))
        }
        XCTAssertEqual(fixture.player.inventory[0]?.count, 5)
        XCTAssertEqual(fixture.player.inventory[1]?.count, 1)
    }

    func testACreativePasteIsFreeAndItsUndoPaysNothing() throws {
        let fixture = try makeFixture(mode: GameMode.creative)
        let origin = try paste(fixture, planks(5))
        XCTAssertEqual(fixture.world.getBlockId(origin.x, origin.y, origin.z), Int(B.oak_planks))
        XCTAssertNil(fixture.game.lastTemplatePlacementUndo?.materials)
        XCTAssertFalse(fixture.screen.chat.contains { $0.contains("materials") }, "\(fixture.screen.chat)")

        fixture.player.setGameMode(GameMode.survival)
        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "oak_planks"), 0, "a paste that cost nothing pays nothing back")
        XCTAssertEqual(fixture.world.getBlock(origin.x, origin.y, origin.z), 0)
    }

    // MARK: - What survival can place

    func testSurvivalRefusesAnObjectItCannotPlaceWhenThePreviewIsArmed() throws {
        let pond = object("Pond", [(0, 0, 0, "oak_planks", 0), (1, 0, 0, "water", 0)])
        let survival = try makeFixture()
        give(survival, "oak_planks", 64, slot: 0)
        XCTAssertThrowsError(try survival.game.beginTemplatePlacement(pond)) { error in
            XCTAssertEqual(error as? TemplateError,
                           .materials("Survival can't place Water. Switch to Creative to place this object."))
        }
        XCTAssertNil(survival.game.templatePlacementTarget(), "nothing is armed")

        let creative = try makeFixture(mode: GameMode.creative)
        let origin = try paste(creative, pond)
        XCTAssertEqual(creative.world.getBlockId(origin.x + 1, origin.y, origin.z), Int(B.water))
    }

    func testASurvivalPastePlacesBlocksAsIfByHand() throws {
        let fixture = try makeFixture()
        let chest = makeContainerBE(0, 0, 0, 27)
        chest.items?[0] = stack("diamond", 64)
        let jukebox = BlockEntityData(type: "jukebox", x: 1, y: 0, z: 0)
        jukebox.disc = stack("music_disc_wander", 1)
        let furnished = object("Furnished", [
            (0, 0, 0, "chest", 2), (1, 0, 0, "jukebox", 0), (2, 0, 0, "furnace_lit", 3),
            (3, 0, 0, "composter", 8), (4, 0, 0, "respawn_anchor", 4),
        ], blockEntities: [chest, jukebox])
        for (slot, name) in ["chest", "jukebox", "furnace", "composter", "respawn_anchor"].enumerated() {
            give(fixture, name, 1, slot: slot)
        }
        let origin = try paste(fixture, furnished)

        XCTAssertEqual(fixture.world.getBlock(origin.x, origin.y, origin.z), Int(cell(B.chest, 2)))
        XCTAssertEqual(fixture.world.getBlockEntity(origin.x, origin.y, origin.z)?.items?.compactMap { $0 }.count, 0,
                       "the chest arrives empty")
        XCTAssertNil(fixture.world.getBlockEntity(origin.x + 1, origin.y, origin.z)?.disc)
        XCTAssertEqual(fixture.world.getBlock(origin.x + 2, origin.y, origin.z), Int(cell(B.furnace, 3)))
        XCTAssertEqual(fixture.world.getBlock(origin.x + 3, origin.y, origin.z), Int(cell(B.composter, 0)))
        XCTAssertEqual(fixture.world.getBlock(origin.x + 4, origin.y, origin.z), Int(cell(B.respawn_anchor, 0)))
        XCTAssertTrue(fixture.player.inventory.allSatisfy { $0 == nil }, "one item for each block, nothing else")
        XCTAssertEqual(dropped(fixture, "diamond"), 0)
    }

    func testACreativePasteStillCarriesWhatTheTemplateHolds() throws {
        let fixture = try makeFixture(mode: GameMode.creative)
        let jukebox = BlockEntityData(type: "jukebox", x: 0, y: 0, z: 0)
        jukebox.disc = stack("music_disc_wander", 1)
        let origin = try paste(fixture, object("Music", [(0, 0, 0, "jukebox", 0), (1, 0, 0, "composter", 8)],
                                               blockEntities: [jukebox]))
        XCTAssertEqual(fixture.world.getBlockEntity(origin.x, origin.y, origin.z)?.disc?.id, iid("music_disc_wander"))
        XCTAssertEqual(fixture.world.getBlock(origin.x + 1, origin.y, origin.z), Int(cell(B.composter, 8)))
    }

    // MARK: - The foundation

    func testTheGroundASurvivalPasteFillsInIsDirtAndCostsDirt() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 3, slot: 0)
        give(fixture, "dirt", 5, slot: 1)
        let origin = try arm(fixture, planks(3))
        // A gap two deep under the first plank, with sand beside it that a creative paste would copy.
        fixture.world.setBlock(origin.x, origin.y - 1, origin.z, 0, SET_SILENT)
        fixture.world.setBlock(origin.x, origin.y - 2, origin.z, 0, SET_SILENT)
        fixture.world.setBlock(origin.x, origin.y - 3, origin.z, Int(cell(B.stone)), SET_SILENT)
        fixture.world.setBlock(origin.x - 1, origin.y - 1, origin.z, Int(cell(B.sand)), SET_SILENT)
        _ = try fixture.game.commitTemplatePlacement()
        finishJob(fixture)

        XCTAssertEqual(fixture.world.getBlockId(origin.x, origin.y - 1, origin.z), Int(B.dirt))
        XCTAssertEqual(fixture.world.getBlockId(origin.x, origin.y - 2, origin.z), Int(B.dirt))
        XCTAssertEqual(carried(fixture, "dirt"), 3, "two cells of ground, two dirt")
        XCTAssertEqual(carried(fixture, "oak_planks"), 0)
        XCTAssertEqual(fixture.game.lastTemplatePlacementUndo?.materials?.paid(iid("dirt")), 2)

        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "dirt"), 5)
        XCTAssertEqual(carried(fixture, "oak_planks"), 3)
        XCTAssertEqual(fixture.world.getBlock(origin.x, origin.y - 1, origin.z), 0)
    }

    func testAPasteThatNeedsGroundThePlayerCannotPayIsRefused() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 3, slot: 0)
        let origin = try arm(fixture, planks(3))
        fixture.world.setBlock(origin.x, origin.y - 1, origin.z, 0, SET_SILENT)
        fixture.world.setBlock(origin.x, origin.y - 2, origin.z, Int(cell(B.stone)), SET_SILENT)
        XCTAssertThrowsError(try fixture.game.commitTemplatePlacement()) { error in
            XCTAssertEqual(error as? TemplateError, .materials("Missing 1 Dirt - nothing was placed."))
        }
        XCTAssertEqual(carried(fixture, "oak_planks"), 3)
        XCTAssertEqual(fixture.world.getBlock(origin.x, origin.y - 1, origin.z), 0)
    }

    func testACreativePasteStillFillsWithTheGroundBesideIt() throws {
        let fixture = try makeFixture(mode: GameMode.creative)
        let origin = try arm(fixture, planks(1))
        fixture.world.setBlock(origin.x, origin.y - 1, origin.z, 0, SET_SILENT)
        fixture.world.setBlock(origin.x, origin.y - 2, origin.z, Int(cell(B.stone)), SET_SILENT)
        fixture.world.setBlock(origin.x - 1, origin.y - 1, origin.z, Int(cell(B.sand)), SET_SILENT)
        _ = try fixture.game.commitTemplatePlacement()
        finishJob(fixture)
        XCTAssertEqual(fixture.world.getBlockId(origin.x, origin.y - 1, origin.z), Int(B.sand))
    }

    // MARK: - Undo

    func testUndoReturnsMaterialsToWhereTheyCameFrom() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 4, slot: 7)
        let chestAt = (-6, 64, 6)
        placeChest(fixture, at: chestAt, [("oak_planks", 20)])
        let origin = try paste(fixture, planks(10))
        XCTAssertEqual(carried(fixture, "oak_planks"), 0)
        XCTAssertEqual(stored(fixture, at: chestAt, "oak_planks"), 14)

        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "oak_planks"), 4)
        XCTAssertEqual(stored(fixture, at: chestAt, "oak_planks"), 20)
        for dx in 0..<10 { XCTAssertEqual(fixture.world.getBlock(origin.x + dx, origin.y, origin.z), 0) }
        XCTAssertNil(fixture.game.lastTemplatePlacementUndo)
        XCTAssertTrue(fixture.screen.chat.contains("§7Returned 10 materials: 4 to your inventory, 6 to containers."),
                      "\(fixture.screen.chat)")
        XCTAssertFalse(fixture.game.undoLastTemplatePlacement(), "nothing is paid back twice")
        XCTAssertEqual(carried(fixture, "oak_planks"), 4)
    }

    func testUndoDoesNotPayForABlockThatWasMinedOrReplaced() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 6, slot: 0)
        let origin = try paste(fixture, planks(6))
        finishBreaking(InteractCtx(world: fixture.world, player: fixture.player), origin.x, origin.y, origin.z)
        XCTAssertEqual(dropped(fixture, "oak_planks"), 1, "mining a pasted plank gives it back once")
        fixture.world.setBlock(origin.x + 1, origin.y, origin.z, Int(cell(B.glass)))

        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "oak_planks"), 4, "four planks still stood")
        XCTAssertEqual(carried(fixture, "glass"), 0, "a block the paste was not paid for is not paid back")
        XCTAssertEqual(fixture.world.getBlock(origin.x + 1, origin.y, origin.z), 0)
        XCTAssertEqual(carried(fixture, "oak_planks") + dropped(fixture, "oak_planks"), 5,
                       "the plank that was replaced is gone; nothing was gained")
    }

    func testUndoPaysForABlockPutBackWhereAPaidOneStoodButNeverMoreThanWasPaid() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 3, slot: 0)
        let origin = try paste(fixture, planks(3))
        // The player builds more of the same on top; undo only restores the cells of the paste.
        fixture.world.setBlock(origin.x, origin.y + 1, origin.z, Int(cell(B.oak_planks)))
        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "oak_planks"), 3)
        XCTAssertEqual(fixture.world.getBlockId(origin.x, origin.y + 1, origin.z), Int(B.oak_planks), "outside the paste")
    }

    func testUndoWithNoRoomForTheRefundChangesNothingAndCanBeTriedAgain() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 5, slot: 0)
        let origin = try paste(fixture, planks(5))
        for slot in fixture.player.inventory.indices { give(fixture, "cobblestone", 64, slot: slot) }

        XCTAssertFalse(fixture.game.undoLastTemplatePlacement())
        XCTAssertTrue(fixture.screen.chat.contains("§cMake room for 1 more stack to undo this object."), "\(fixture.screen.chat)")
        for dx in 0..<5 { XCTAssertEqual(fixture.world.getBlockId(origin.x + dx, origin.y, origin.z), Int(B.oak_planks)) }
        XCTAssertNotNil(fixture.game.lastTemplatePlacementUndo, "the undo is still there")
        XCTAssertEqual(carried(fixture, "cobblestone"), 36 * 64)

        fixture.player.inventory[20] = nil
        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "oak_planks"), 5)
        XCTAssertEqual(fixture.world.getBlock(origin.x, origin.y, origin.z), 0)
    }

    func testARefundWhoseContainerIsGoneGoesToTheInventory() throws {
        let fixture = try makeFixture()
        let chestAt = (4, 64, -4)
        placeChest(fixture, at: chestAt, [("oak_planks", 8)])
        try paste(fixture, planks(8))
        XCTAssertEqual(stored(fixture, at: chestAt, "oak_planks"), 0)
        fixture.world.removeBlockEntity(chestAt.0, chestAt.1, chestAt.2)
        fixture.world.setBlock(chestAt.0, chestAt.1, chestAt.2, 0)

        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "oak_planks"), 8)
    }

    func testAContainerInsideTheObjectsBoxIsNotPaidFrom() throws {
        let fixture = try makeFixture()
        let template = object("Box", [(0, 0, 0, "oak_planks", 0), (2, 0, 0, "oak_planks", 0)])
        let origin = try arm(fixture, template)
        // The paste clears its whole box, so a chest standing in it is about to be removed.
        let inside = (origin.x + 1, origin.y, origin.z)
        placeChest(fixture, at: inside, [("oak_planks", 64)])
        XCTAssertThrowsError(try fixture.game.commitTemplatePlacement()) { error in
            XCTAssertEqual(error as? TemplateError, .materials("Missing 2 Oak Planks - nothing was placed."))
        }
        XCTAssertEqual(stored(fixture, at: inside, "oak_planks"), 64)
        XCTAssertEqual(fixture.world.getBlockId(inside.0, inside.1, inside.2), Int(B.chest))
    }

    func testTheReceiptSurvivesTheSettleWhenTheGameIsSaved() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 7, slot: 0)
        try arm(fixture, planks(7))
        _ = try fixture.game.commitTemplatePlacement()
        XCTAssertEqual(fixture.game.settleInFlightTemplatePlacementJobs(), 1)
        XCTAssertEqual(fixture.game.lastTemplatePlacementUndo?.materials?.total, 7)
        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "oak_planks"), 7)
    }

    func testStandingMaterialsCountOnlyCellsTheUndoReallyReplaces() throws {
        let fixture = try makeFixture()
        let world = fixture.world
        world.setBlock(2, 70, 2, Int(cell(B.oak_planks)), SET_SILENT)
        world.setBlock(3, 70, 2, Int(cell(B.oak_slab, 2)), SET_SILENT)
        world.setBlock(4, 70, 2, Int(cell(B.dirt)), SET_SILENT)
        world.setBlock(5, 70, 2, Int(cell(B.oak_door, 0)), SET_SILENT)
        world.setBlock(5, 71, 2, Int(cell(B.oak_door, 8)), SET_SILENT)
        func recorded(_ x: Int, _ y: Int, _ cellValue: Int) -> TemplatePlacementUndoCell {
            TemplatePlacementUndoCell(x: x, y: y, z: 2, cell: cellValue, blockEntity: nil)
        }
        let counts = templateStandingMaterials(in: world, restoring: [
            recorded(2, 70, 0), recorded(3, 70, 0),
            recorded(4, 70, Int(cell(B.dirt))),      // undo would put back what already stands there
            recorded(5, 70, 0), recorded(5, 71, 0),
            recorded(6, 70, Int(cell(B.stone))),     // air stands there now
        ])
        XCTAssertEqual(counts, [iid("oak_planks"): 1, iid("oak_slab"): 2, iid("oak_door"): 1])
    }

    // MARK: - Seeded: paste, mine, undo never gains anything

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ bound: Int) -> Int { Int(next() % UInt64(max(1, bound))) }
    }

    /// Every item the player owns or that lies on the ground, by item id.
    private func wealth(_ fixture: Fixture, chest: (Int, Int, Int)) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        for case let stack? in fixture.player.inventory { counts[stack.id, default: 0] += stack.count }
        for case let stack? in fixture.world.getBlockEntity(chest.0, chest.1, chest.2)?.items ?? [] {
            counts[stack.id, default: 0] += stack.count
        }
        for case let item as ItemEntity in fixture.world.entities { counts[item.stack.id, default: 0] += item.stack.count }
        return counts
    }

    func testPasteMineAndUndoNeverLeavesThePlayerWithMoreForSeededObjects() throws {
        let fixture = try makeFixture()
        let chestAt = (-8, 64, 12)
        let palette = ["oak_planks", "cobblestone", "glass", "oak_slab", "torch", "bricks"]
        var random = SplitMix64(state: 0x5EED_CA5E)
        var refused = 0
        for round in 0..<40 {
            for entity in fixture.world.entities where entity is ItemEntity { fixture.world.removeEntity(entity) }
            for index in fixture.player.inventory.indices { fixture.player.inventory[index] = nil }
            var blocks: [(Int, Int, Int, String, Int)] = []
            for dx in 0..<4 { for dz in 0..<3 where random.int(3) != 0 {
                let name = palette[random.int(palette.count)]
                blocks.append((dx, 0, dz, name, name == "oak_slab" ? random.int(3) : 0))
            } }
            if blocks.isEmpty { blocks.append((0, 0, 0, "oak_planks", 0)) }
            for (slot, name) in palette.enumerated() { give(fixture, name, random.int(12), slot: slot) }
            placeChest(fixture, at: chestAt, palette.map { ($0, 6 + random.int(20)) })
            let before = wealth(fixture, chest: chestAt)

            let template = object("Seeded \(round)", blocks)
            let origin = try arm(fixture, template)
            do {
                _ = try fixture.game.commitTemplatePlacement()
            } catch {
                XCTAssertEqual(wealth(fixture, chest: chestAt), before, "round \(round): a refused paste costs nothing")
                fixture.game.cancelTemplatePlacement(showMessage: false)
                refused += 1
                continue
            }
            finishJob(fixture)
            XCTAssertLessThan(wealth(fixture, chest: chestAt).values.reduce(0, +), before.values.reduce(0, +),
                              "round \(round): the paste was paid for")
            for block in blocks where random.int(3) == 0 {
                finishBreaking(InteractCtx(world: fixture.world, player: fixture.player),
                               origin.x + block.0, origin.y + block.1, origin.z + block.2)
            }
            XCTAssertTrue(fixture.game.undoLastTemplatePlacement(), "round \(round)")
            let after = wealth(fixture, chest: chestAt)
            for itemID in Set(before.keys).union(after.keys) {
                XCTAssertLessThanOrEqual(after[itemID] ?? 0, before[itemID] ?? 0,
                                         "round \(round): more \(itemDefs[itemID].name) than before the paste")
            }
            for block in blocks {
                XCTAssertEqual(fixture.world.getBlock(origin.x + block.0, origin.y + block.1, origin.z + block.2), 0,
                               "round \(round): undo left a block standing")
            }
        }
        XCTAssertLessThan(refused, 30, "most rounds must really paste, or the scenario checks nothing")
    }

    // MARK: - The quote the browser and the chat show

    func testTheQuoteListsMissingMaterialsFirstAndSaysWhatIsMissing() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 10, slot: 0)
        placeChest(fixture, at: (3, 64, 3), [("torch", 1)])
        let house = object("House", [(0, 0, 0, "oak_planks", 0), (1, 0, 0, "oak_planks", 0), (2, 0, 0, "glass", 0),
                                     (3, 0, 0, "glass", 0), (4, 0, 0, "glass", 0), (5, 0, 0, "torch", 0),
                                     (6, 0, 0, "torch", 0)])
        let quote = fixture.game.templateMaterialQuote(for: house)
        guard case .cost(let lines) = quote else { return XCTFail("\(quote)") }
        XCTAssertEqual(lines.map { itemDefs[$0.itemID].name }, ["glass", "torch", "oak_planks"])
        XCTAssertEqual(lines.map(\.need), [3, 2, 2])
        XCTAssertEqual(lines.map(\.have), [0, 1, 10], "the chest counts too")
        XCTAssertEqual(lines.map(\.missing), [3, 1, 0])
        XCTAssertEqual(quote.statusText, "Missing 2 of 3 materials")
        XCTAssertEqual(quote.sentence, "Costs 7 materials. Still missing 3 Glass and 1 Torch.")
        XCTAssertEqual(quote.missing, [TemplateMaterialLine(itemID: iid("glass"), count: 3),
                                       TemplateMaterialLine(itemID: iid("torch"), count: 1)])

        give(fixture, "glass", 3, slot: 1)
        give(fixture, "torch", 1, slot: 2)
        let paid = fixture.game.templateMaterialQuote(for: house)
        XCTAssertEqual(paid.statusText, "Have all 7 materials")
        XCTAssertEqual(paid.sentence, "Costs 7 materials. You have them all.")
        XCTAssertEqual(paid.missing, [])
    }

    func testTheQuoteForCreativeAndForAnObjectSurvivalCannotPlace() throws {
        let pond = object("Pond", [(0, 0, 0, "oak_planks", 0), (1, 0, 0, "lava", 0)])
        let survival = try makeFixture().game.templateMaterialQuote(for: pond)
        XCTAssertEqual(survival, .unplaceable("Survival can't place Lava. Switch to Creative to place this object."))
        XCTAssertEqual(survival.statusText, "Survival can't place Lava")
        XCTAssertEqual(survival.missing, [])
        let creative = try makeFixture(mode: GameMode.creative).game.templateMaterialQuote(for: pond)
        XCTAssertEqual(creative, .free)
        XCTAssertEqual(creative.statusText, "Free in Creative")
        XCTAssertEqual(creative.sentence, "Free in Creative.")
    }
}
