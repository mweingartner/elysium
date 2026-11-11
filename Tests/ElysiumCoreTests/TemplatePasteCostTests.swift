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

    func testASurvivalPasteOfATurnedBedPlacesOneWholeBedForOneBed() throws {
        let fixture = try makeFixture()
        give(fixture, "red_bed", 2, slot: 0)
        let bedroom = object("Bedroom", [(0, 0, 1, "red_bed", 0), (0, 0, 0, "red_bed", 4)])
        try fixture.game.beginTemplatePlacement(bedroom)
        XCTAssertTrue(fixture.game.rotateTemplatePlacement(by: 1))
        let target = try XCTUnwrap(fixture.game.templatePlacementTarget())
        for dx in 0..<2 { for dz in 0..<2 {
            fixture.world.setBlock(target.originX + dx, target.originY - 1, target.originZ + dz, Int(cell(B.stone)), SET_SILENT)
        } }
        _ = try fixture.game.commitTemplatePlacement()
        finishJob(fixture)
        XCTAssertEqual(carried(fixture, "red_bed"), 1, "one bed, although it stands on two cells")
        var halves: [(Int, Int, Int)] = []
        for dx in 0..<2 { for dz in 0..<2 where fixture.world.getBlockId(target.originX + dx, target.originY, target.originZ + dz) == Int(B.red_bed) {
            halves.append((target.originX + dx, target.originY, target.originZ + dz))
        } }
        XCTAssertEqual(halves.count, 2, "both halves are placed")
        for half in halves {
            XCTAssertNotNil(twoCellPartnerCell(in: fixture.world, of: fixture.world.getBlock(half.0, half.1, half.2),
                                               half.0, half.1, half.2), "and they belong together")
        }
    }

    func testASurvivalPasteLeavesOutLooseHalvesAndChargesNothingForThem() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 1, slot: 0)
        let loose = object("Loose", [(0, 0, 0, "oak_planks", 0), (1, 0, 0, "red_bed", 4), (2, 0, 0, "oak_door", 8)])
        let origin = try paste(fixture, loose)
        XCTAssertEqual(fixture.world.getBlockId(origin.x, origin.y, origin.z), Int(B.oak_planks))
        XCTAssertEqual(fixture.world.getBlock(origin.x + 1, origin.y, origin.z), 0, "a bed head alone is not placed")
        XCTAssertEqual(fixture.world.getBlock(origin.x + 2, origin.y, origin.z), 0, "nor a door top alone")
        XCTAssertEqual(fixture.game.lastTemplatePlacementUndo?.materials?.total, 1)

        let halvesOnly = object("Halves", [(0, 0, 0, "red_bed", 4)])
        XCTAssertThrowsError(try fixture.game.beginTemplatePlacement(halvesOnly)) { error in
            XCTAssertEqual(error as? TemplateError, .materials(TemplateMaterialError.nothingToPlace.description))
        }
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

    // MARK: - The click decides

    /// The game mode that counts is the one at the click, not the one at arming: a preview
    /// armed in Creative and placed in Survival is charged, and the other way round is free.
    func testTheModeAtTheClickDecidesWhetherAPasteIsCharged() throws {
        let armedInCreative = try makeFixture(mode: GameMode.creative)
        try arm(armedInCreative, planks(3))
        armedInCreative.player.setGameMode(GameMode.survival)
        XCTAssertThrowsError(try armedInCreative.game.commitTemplatePlacement()) { error in
            XCTAssertEqual(error as? TemplateError, .materials("Missing 3 Oak Planks - nothing was placed."))
        }
        XCTAssertFalse(armedInCreative.game.hasActiveTemplatePlacementJob())

        let pond = object("Pond", [(0, 0, 0, "oak_planks", 0), (1, 0, 0, "water", 0)])
        let pondInCreative = try makeFixture(mode: GameMode.creative)
        give(pondInCreative, "oak_planks", 5, slot: 0)
        try arm(pondInCreative, pond)
        pondInCreative.player.setGameMode(GameMode.survival)
        XCTAssertThrowsError(try pondInCreative.game.commitTemplatePlacement()) { error in
            XCTAssertEqual(error as? TemplateError,
                           .materials("Survival can't place Water. Switch to Creative to place this object."))
        }
        XCTAssertEqual(carried(pondInCreative, "oak_planks"), 5)

        let armedInSurvival = try makeFixture()
        give(armedInSurvival, "oak_planks", 3, slot: 0)
        let origin = try arm(armedInSurvival, planks(3))
        armedInSurvival.player.setGameMode(GameMode.creative)
        _ = try armedInSurvival.game.commitTemplatePlacement()
        finishJob(armedInSurvival)
        XCTAssertEqual(carried(armedInSurvival, "oak_planks"), 3, "a Creative click is free")
        XCTAssertEqual(armedInSurvival.world.getBlockId(origin.x, origin.y, origin.z), Int(B.oak_planks))
        XCTAssertNil(armedInSurvival.game.lastTemplatePlacementUndo?.materials)
    }

    /// The charge comes after the job is admitted, so a paste the world refuses (here, no
    /// ground within reach under it) costs nothing and leaves the preview armed.
    func testAPasteTheWorldRefusesCostsNothing() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 2, slot: 0)
        give(fixture, "dirt", 64, slot: 1)
        let origin = try arm(fixture, planks(2))
        for y in 56..<origin.y { fixture.world.setBlock(origin.x, y, origin.z, 0, SET_SILENT) }
        XCTAssertThrowsError(try fixture.game.commitTemplatePlacement()) { error in
            guard case .foundationTooDeep? = error as? TemplateError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(carried(fixture, "oak_planks"), 2)
        XCTAssertEqual(carried(fixture, "dirt"), 64)
        XCTAssertFalse(fixture.game.hasActiveTemplatePlacementJob())
        XCTAssertNotNil(fixture.game.templatePlacementTarget(), "the preview stays armed")
    }

    // MARK: - Settling a finished paste

    /// The dirt for the ground is charged at the click for every cell the plan will fill. A
    /// cell that holds dirt by the time the job gets there is not filled, so its dirt comes back
    /// when the job finishes, and the chat counts only what the paste kept.
    func testGroundThatNoLongerNeedsFillingWhenTheJobGetsThereIsPaidBack() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 3, slot: 0)
        give(fixture, "dirt", 5, slot: 1)
        let origin = try arm(fixture, planks(3))
        fixture.world.setBlock(origin.x, origin.y - 1, origin.z, 0, SET_SILENT)
        fixture.world.setBlock(origin.x + 1, origin.y - 1, origin.z, 0, SET_SILENT)
        _ = try fixture.game.commitTemplatePlacement()
        XCTAssertEqual(carried(fixture, "dirt"), 3, "two cells of ground are paid at the click")

        // Before the job reaches the ground, the player fills one of the two cells by hand.
        fixture.world.setBlock(origin.x + 1, origin.y - 1, origin.z, Int(cell(B.dirt)), SET_SILENT)
        finishJob(fixture)
        XCTAssertEqual(carried(fixture, "dirt"), 4, "the cell that needed no filling is paid back")
        XCTAssertEqual(fixture.game.lastTemplatePlacementUndo?.materials?.paid(iid("dirt")), 1)
        XCTAssertTrue(fixture.screen.chat.contains("§7Used 4 materials: 4 from your inventory."), "\(fixture.screen.chat)")

        // Undo pays back the dirt the paste filled, and not the dirt the player put there.
        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "dirt"), 5)
        XCTAssertEqual(carried(fixture, "oak_planks"), 3)
        XCTAssertEqual(fixture.world.getBlockId(origin.x + 1, origin.y - 1, origin.z), Int(B.dirt),
                       "undo puts back what stood there when the job took the cell")
    }

    /// Blocks in a chunk that unloaded after the click and before the job reached them are not
    /// written, so they are paid back when the job finishes, to where they came from. A chest
    /// the paste itself just placed is never where that refund goes: the next undo removes it.
    func testBlocksThePasteCouldNotWriteArePaidBackButNotIntoAChestThePasteJustPlaced() throws {
        let fixture = try makeFixture()
        let width = 24
        let probe = planks(width)
        let origin = try arm(fixture, probe)
        fixture.game.cancelTemplatePlacement(showMessage: false)
        let removedCX = floorDiv(origin.x, CHUNK_W), removedCZ = floorDiv(origin.z, CHUNK_W)
        XCTAssertNotEqual(removedCZ, 0, "the chunk that unloads must not be the player's")
        let unplaced = (0..<(width - 1)).filter { floorDiv(origin.x + $0, CHUNK_W) == removedCX }.count
        XCTAssertGreaterThan(unplaced, 0)
        XCTAssertNotEqual(floorDiv(origin.x + width - 1, CHUNK_W), removedCX, "the chest lands in a loaded chunk")

        // Planks along x, a chest at the far end; the planks come from a chest farther away. The
        // paste empties the source's first slot and leaves a full stack beside it, so the refund
        // finds no part stack to top up and must pick an empty slot: the nearest is in the
        // pasted chest, which is exactly where it must not go.
        let object = self.object("Shed", (0..<(width - 1)).map { ($0, 0, 0, "oak_planks", 0) }
                                   + [(width - 1, 0, 0, "chest", 2)])
        give(fixture, "chest", 1, slot: 0)
        let source = (30, 64, -35)
        placeChest(fixture, at: source, [("oak_planks", width - 1), ("oak_planks", 64)])
        XCTAssertEqual(try arm(fixture, object).x, origin.x)
        let pasted = (origin.x + width - 1, origin.y, origin.z)
        XCTAssertLessThan(pasted.0 * pasted.0 + pasted.2 * pasted.2, source.0 * source.0 + source.2 * source.2,
                          "the pasted chest is nearer the player than the source chest")
        _ = try fixture.game.commitTemplatePlacement()
        XCTAssertEqual(stored(fixture, at: source, "oak_planks"), 64)
        fixture.world.removeChunk(removedCX, removedCZ)
        finishJob(fixture)

        XCTAssertEqual(fixture.world.getBlockId(pasted.0, pasted.1, pasted.2), Int(B.chest))
        XCTAssertEqual(fixture.world.getBlockEntity(pasted.0, pasted.1, pasted.2)?.items?.compactMap { $0 }.count, 0,
                       "nothing is refunded into the chest the paste just placed")
        XCTAssertEqual(stored(fixture, at: source, "oak_planks"), 64 + unplaced,
                       "the planks that were not placed go back to the chest they came from")
        let receipt = try XCTUnwrap(fixture.game.lastTemplatePlacementUndo?.materials)
        XCTAssertEqual(receipt.paid(iid("oak_planks")), width - 1 - unplaced)
        XCTAssertEqual(receipt.paid(iid("chest")), 1)
        XCTAssertEqual(dropped(fixture, "oak_planks"), 0)
    }

    /// A flower pot whose chunk unloads before the job reaches it was charged for the pot and
    /// for its plant. Both should come back when the job finishes.
    func testAPottedPlantThePasteCouldNotWriteIsPaidBackWithItsPot() throws {
        let fixture = try makeFixture()
        let width = 20
        let origin = try arm(fixture, planks(width))
        fixture.game.cancelTemplatePlacement(showMessage: false)
        let removedCX = floorDiv(origin.x, CHUNK_W), removedCZ = floorDiv(origin.z, CHUNK_W)
        XCTAssertNotEqual(removedCZ, 0)
        let pot = BlockEntityData(type: "lectern", x: 0, y: 0, z: 0)
        pot.plant = "poppy"
        let object = self.object("Potted", [(0, 0, 0, "flower_pot", 0)]
                                   + (1..<width).map { ($0, 0, 0, "oak_planks", 0) }, blockEntities: [pot])
        give(fixture, "flower_pot", 1, slot: 0)
        give(fixture, "poppy", 1, slot: 1)
        give(fixture, "oak_planks", width - 1, slot: 2)
        XCTAssertEqual(try arm(fixture, object).x, origin.x)
        _ = try fixture.game.commitTemplatePlacement()
        XCTAssertEqual(carried(fixture, "poppy"), 0)
        fixture.world.removeChunk(removedCX, removedCZ)
        finishJob(fixture)

        XCTAssertEqual(carried(fixture, "flower_pot"), 1, "the pot that was not placed is paid back")
        // The plant is charged from the pot's block entity, so it is paid back from the block
        // entities the job did not attach. No later undo could return it: no pot ever stood.
        XCTAssertEqual(carried(fixture, "poppy"), 1, "and so is the plant that was charged with it")
    }

    /// Pasting the same object twice on the same spot charges twice, and undoing the second
    /// paste pays nothing back: the restore puts back the first paste's planks, which are the
    /// planks that stand, so it destroys nothing it could pay for. This is the accepted downside
    /// named in the decision record ("a block pasted onto an identical block is not refunded on
    /// undo"). Paying the second paste back when it finishes was considered and refused: the
    /// undo record still holds the first planks, so mining the row and then undoing would hand
    /// out three planks from nothing. The second half of this test walks that loop.
    func testAPasteOverTheSameObjectIsPaidForAndItsUndoNeitherPaysNorMakesBlocks() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 6, slot: 0)
        let first = try paste(fixture, planks(3))
        XCTAssertEqual(carried(fixture, "oak_planks"), 3)
        let second = try paste(fixture, planks(3))
        XCTAssertEqual([second.x, second.y, second.z], [first.x, first.y, first.z], "the same spot")
        XCTAssertEqual(carried(fixture, "oak_planks"), 0, "the second paste is charged in full")
        XCTAssertEqual(fixture.game.lastTemplatePlacementUndo?.materials?.paid(iid("oak_planks")), 3)

        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        for dx in 0..<3 {
            XCTAssertEqual(fixture.world.getBlockId(first.x + dx, first.y, first.z), Int(B.oak_planks),
                           "the first paste's planks are what undo puts back")
        }
        XCTAssertEqual(carried(fixture, "oak_planks"), 0, "the restore changed no cell, so nothing is paid back")

        // The loop a refund at completion would open: paste over the row, mine it, undo.
        give(fixture, "oak_planks", 3, slot: 0)
        let again = try paste(fixture, planks(3))
        XCTAssertEqual([again.x, again.y, again.z], [first.x, first.y, first.z])
        XCTAssertEqual(carried(fixture, "oak_planks"), 0)
        for dx in 0..<3 { fixture.world.setBlock(first.x + dx, first.y, first.z, 0) }
        give(fixture, "oak_planks", 3, slot: 0)                     // what mining the row yields
        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        let standing = (0..<3).filter { fixture.world.getBlockId(first.x + $0, first.y, first.z) == Int(B.oak_planks) }.count
        XCTAssertEqual(standing, 3, "undo puts back the row that stood before the paste")
        XCTAssertEqual(carried(fixture, "oak_planks") + standing, 6,
                       "six planks before the paste (three carried to pay, three standing), six after")
    }

    // MARK: - Where a refund may go

    /// An undo removes the chest the paste placed. A refund put into it would vanish with it,
    /// so when the inventory is full the undo refuses rather than refund into that chest.
    func testAnUndoRefundIsNeverPutIntoAContainerTheUndoRemoves() throws {
        let fixture = try makeFixture()
        give(fixture, "chest", 1, slot: 0)
        give(fixture, "oak_planks", 4, slot: 1)
        let origin = try paste(fixture, object("Crate", [(0, 0, 0, "chest", 2), (1, 0, 0, "oak_planks", 0),
                                                         (2, 0, 0, "oak_planks", 0), (3, 0, 0, "oak_planks", 0),
                                                         (4, 0, 0, "oak_planks", 0)]))
        XCTAssertEqual(fixture.world.getBlockId(origin.x, origin.y, origin.z), Int(B.chest))
        for slot in fixture.player.inventory.indices { give(fixture, "cobblestone", 64, slot: slot) }

        XCTAssertFalse(fixture.game.undoLastTemplatePlacement())
        XCTAssertTrue(fixture.screen.chat.contains("§cMake room for 2 more stacks to undo this object."), "\(fixture.screen.chat)")
        XCTAssertEqual(fixture.world.getBlockId(origin.x, origin.y, origin.z), Int(B.chest), "nothing was undone")
        XCTAssertEqual(stored(fixture, at: (origin.x, origin.y, origin.z), "oak_planks"), 0)

        fixture.player.inventory[10] = nil
        fixture.player.inventory[11] = nil
        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "chest"), 1)
        XCTAssertEqual(carried(fixture, "oak_planks"), 4)
    }

    /// A container whose loot has not been rolled, and a furnace, may pay for a paste but never
    /// take a refund: the loot roll would overwrite it, and a furnace is no storage.
    func testARefundIsNeverPutIntoAnUnrolledLootChestOrAFurnace() throws {
        for kind in ["loot chest", "furnace"] {
            let fixture = try makeFixture()
            give(fixture, "oak_planks", 3, slot: 0)
            let origin = try paste(fixture, planks(3))
            let at = (-5, 64, -5)
            if kind == "loot chest" {
                let chest = placeChest(fixture, at: at, [])
                chest.lootTable = "chests/simple_dungeon"
            } else {
                fixture.world.setBlock(at.0, at.1, at.2, Int(cell(B.furnace, 2)), SET_SILENT)
                fixture.world.setBlockEntity(try XCTUnwrap(placementBlockEntity(Int(B.furnace), at.0, at.1, at.2)))
            }
            for slot in fixture.player.inventory.indices { give(fixture, "cobblestone", 64, slot: slot) }

            XCTAssertFalse(fixture.game.undoLastTemplatePlacement(), kind)
            XCTAssertEqual(fixture.world.getBlockId(origin.x, origin.y, origin.z), Int(B.oak_planks), kind)
            XCTAssertEqual(stored(fixture, at: at, "oak_planks"), 0, kind)
        }
    }

    /// Undo pays back from what stands in the cells, not from the receipt: the dirt a paste
    /// filled and the player then dug out is not paid back, nor is anything the receipt never
    /// held, however much of it stands in the paste's cells.
    func testUndoPaysForTheGroundOnlyWhereThePastesDirtStillStands() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 2, slot: 0)
        give(fixture, "dirt", 2, slot: 1)
        let origin = try arm(fixture, planks(2))
        for dx in 0..<2 { fixture.world.setBlock(origin.x + dx, origin.y - 1, origin.z, 0, SET_SILENT) }
        _ = try fixture.game.commitTemplatePlacement()
        finishJob(fixture)
        XCTAssertEqual(carried(fixture, "dirt"), 0)
        fixture.world.setBlock(origin.x, origin.y - 1, origin.z, 0)                       // dug out, kept nothing
        fixture.world.setBlock(origin.x + 1, origin.y, origin.z, Int(cell(B.diamond_block)))  // a plank replaced

        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "dirt"), 1)
        XCTAssertEqual(carried(fixture, "oak_planks"), 1)
        XCTAssertEqual(carried(fixture, "diamond_block"), 0)
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

    // MARK: - Deeper: beds in every turn, and the bill against what stands

    /// Arms `template` turned `steps` quarter turns, and lays stone under its whole footprint
    /// (which a turn moves) so no ground has to be filled. `template` must be square in x and z.
    @discardableResult
    private func armTurned(_ fixture: Fixture, _ template: ObjectTemplate, steps: Int) throws -> (x: Int, y: Int, z: Int) {
        try fixture.game.beginTemplatePlacement(template)
        for _ in 0..<steps { XCTAssertTrue(fixture.game.rotateTemplatePlacement(by: 1)) }
        let target = try XCTUnwrap(fixture.game.templatePlacementTarget())
        let side = max(template.sizeX, template.sizeZ)
        for dx in 0..<side { for dz in 0..<side {
            fixture.world.setBlock(target.originX + dx, target.originY - 1, target.originZ + dz, Int(cell(B.stone)), SET_SILENT)
        } }
        return (target.originX, target.originY, target.originZ)
    }

    private func use(_ fixture: Fixture, _ x: Int, _ y: Int, _ z: Int) -> Bool {
        let hit = RaycastHit(x: x, y: y, z: z, face: 1, cell: fixture.world.getBlock(x, y, z), t: 1,
                             px: Double(x) + 0.5, py: Double(y) + 1, pz: Double(z) + 0.5)
        return useBlock(InteractCtx(world: fixture.world, player: fixture.player), hit)
    }

    /// One bed of each facing, pasted in each of the four turns, in survival and in creative:
    /// it stands as one whole bed, both halves facing the same way with the head in front of the
    /// foot, and sleeping in either half sets the spawn point. In survival it costs one bed, and
    /// breaking either half gives that one bed back and removes both halves.
    func testABedOfEveryFacingPastedInEveryTurnIsOneWholeBedThatWorks() throws {
        let headOffset = [(0, -1), (0, 1), (-1, 0), (1, 0)]
        for mode in [GameMode.survival, GameMode.creative] {
            let fixture = try makeFixture(mode: mode)
            var round = 0
            for facing in 0..<4 {
                let foot = (-min(0, headOffset[facing].0), 0, -min(0, headOffset[facing].1))
                let head = (foot.0 + headOffset[facing].0, 0, foot.2 + headOffset[facing].1)
                let bedroom = ObjectTemplate(name: "Bed \(facing)", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 2, sizeY: 1, sizeZ: 2,
                                             blocks: [TemplateBlock(dx: foot.0, dy: 0, dz: foot.2, cell: cell(B.red_bed, facing)),
                                                      TemplateBlock(dx: head.0, dy: 0, dz: head.2, cell: cell(B.red_bed, 4 | facing))])
                for steps in 0..<4 {
                    let which = "\(mode == GameMode.survival ? "survival" : "creative") facing \(facing) turned \(steps)"
                    for entity in fixture.world.entities where entity is ItemEntity { fixture.world.removeEntity(entity) }
                    for index in fixture.player.inventory.indices { fixture.player.inventory[index] = nil }
                    if mode == GameMode.survival { give(fixture, "red_bed", 1, slot: round % 9) }
                    round += 1
                    let origin = try armTurned(fixture, bedroom, steps: steps)
                    _ = try fixture.game.commitTemplatePlacement()
                    finishJob(fixture)

                    var halves: [(x: Int, z: Int, cell: Int)] = []
                    for dx in 0..<2 { for dz in 0..<2 {
                        let value = fixture.world.getBlock(origin.x + dx, origin.y, origin.z + dz)
                        if value >> 4 == Int(B.red_bed) { halves.append((origin.x + dx, origin.z + dz, value)) }
                    } }
                    XCTAssertEqual(halves.count, 2, which)
                    guard let footCell = halves.first(where: { twoCellHalf(of: $0.cell) == .primary }),
                          let headCell = halves.first(where: { twoCellHalf(of: $0.cell) == .secondary }) else {
                        XCTFail("\(which): a foot and a head must stand"); continue
                    }
                    let turnedFacing = footCell.cell & 3
                    XCTAssertEqual(headCell.cell & 3, turnedFacing, which)
                    XCTAssertEqual([headCell.x - footCell.x, headCell.z - footCell.z],
                                   [headOffset[turnedFacing].0, headOffset[turnedFacing].1], "\(which): the head is in front")
                    if mode == GameMode.survival { XCTAssertEqual(carried(fixture, "red_bed"), 0, "\(which): one bed paid") }

                    for target in [headCell, footCell] {
                        fixture.player.spawnPoint = nil
                        XCTAssertTrue(use(fixture, target.x, origin.y, target.z), which)
                        XCTAssertEqual(fixture.player.spawnPoint.map { [$0.0, $0.1, $0.2] }, [target.x, origin.y, target.z], which)
                    }
                    let broken = steps % 2 == 0 ? headCell : footCell
                    finishBreaking(InteractCtx(world: fixture.world, player: fixture.player), broken.x, origin.y, broken.z)
                    XCTAssertEqual(fixture.world.getBlock(footCell.x, origin.y, footCell.z), 0, which)
                    XCTAssertEqual(fixture.world.getBlock(headCell.x, origin.y, headCell.z), 0, which)
                    if mode == GameMode.survival { XCTAssertEqual(dropped(fixture, "red_bed"), 1, "\(which): one bed back") }
                }
            }
        }
    }

    /// Seeded objects of beds (pairs, and loose halves of either kind), doors (whole, and loose
    /// tops), pistons and sticky pistons (extended or not, with and without heads) and planks,
    /// pasted in survival in every turn. What the player lost is, item for item, what stands in
    /// the object's cells afterwards (`templateStandingMaterials`) and what the receipt says was
    /// paid. No piston head and no extended piston stands, every bed or door half that stands
    /// has its own other half, and undo gives back exactly what was lost.
    func testASurvivalPastesBillIsWhatStandsAfterwardsForSeededObjectsInEveryTurn() throws {
        let fixture = try makeFixture()
        var random = SplitMix64(state: 0xB111_57A4)
        let headOffset = [(0, -1), (0, 1), (-1, 0), (1, 0)]
        let side = 4
        var pasted = 0
        for round in 0..<32 {
            for entity in fixture.world.entities where entity is ItemEntity { fixture.world.removeEntity(entity) }
            for index in fixture.player.inventory.indices { fixture.player.inventory[index] = nil }
            var at: [TemplatePos: UInt16] = [:]
            func free(_ x: Int, _ z: Int) -> Bool {
                (0..<side).contains(x) && (0..<side).contains(z) && at[TemplatePos(x: x, y: 0, z: z)] == nil
            }
            at[TemplatePos(x: random.int(side), y: 0, z: random.int(side))] = cell(B.oak_planks)
            var beds = 0
            for _ in 0..<(3 + random.int(6)) {
                let x = random.int(side), z = random.int(side)
                guard free(x, z) else { continue }
                switch random.int(6) {
                case 0 where beds < 4:
                    let facing = random.int(4)
                    let hx = x + headOffset[facing].0, hz = z + headOffset[facing].1
                    switch random.int(3) {
                    case 0:                                         // a lone head
                        at[TemplatePos(x: x, y: 0, z: z)] = cell(B.red_bed, 4 | facing)
                    case 1 where free(hx, hz):                      // a whole bed
                        at[TemplatePos(x: x, y: 0, z: z)] = cell(B.red_bed, facing)
                        at[TemplatePos(x: hx, y: 0, z: hz)] = cell(B.red_bed, 4 | facing)
                        beds += 1
                    default:                                        // a foot alone
                        at[TemplatePos(x: x, y: 0, z: z)] = cell(B.red_bed, facing)
                        beds += 1
                    }
                case 1:
                    if random.int(2) == 0 { at[TemplatePos(x: x, y: 0, z: z)] = cell(B.oak_door, random.int(8)) }
                    at[TemplatePos(x: x, y: 1, z: z)] = cell(B.oak_door, 8 | random.int(8))
                case 2:
                    at[TemplatePos(x: x, y: 0, z: z)] = cell(B.piston, 2 + random.int(4) | (random.int(2) << 3))
                case 3:
                    at[TemplatePos(x: x, y: 0, z: z)] = cell(B.sticky_piston, 2 + random.int(4) | (random.int(2) << 3))
                case 4:
                    at[TemplatePos(x: x, y: 0, z: z)] = cell(B.piston_head, 2 + random.int(4) | (random.int(2) << 3))
                default:
                    at[TemplatePos(x: x, y: 0, z: z)] = cell(B.oak_planks)
                }
            }
            let template = ObjectTemplate(name: "Seeded \(round)", anchorX: 0, anchorY: 0, anchorZ: 0,
                                          sizeX: side, sizeY: 2, sizeZ: side,
                                          blocks: at.keys.sorted().map { TemplateBlock(dx: $0.x, dy: $0.y, dz: $0.z, cell: at[$0]!) })
            // Plenty of everything; a bed does not stack, so each takes a slot.
            for (slot, name) in ["oak_planks", "oak_door", "piston", "sticky_piston"].enumerated() { give(fixture, name, 64, slot: slot) }
            for slot in 4..<8 { give(fixture, "red_bed", 1, slot: slot) }
            let before = wealth(fixture, chest: (0, -60, 0))
            let steps = round % 4
            let origin = try armTurned(fixture, template, steps: steps)
            let which = "seed 0xB11157A4 round \(round) turned \(steps)"
            _ = try fixture.game.commitTemplatePlacement()
            finishJob(fixture)
            pasted += 1

            let after = wealth(fixture, chest: (0, -60, 0))
            var lost: [Int: Int] = [:]
            for itemID in Set(before.keys).union(after.keys) where (before[itemID] ?? 0) != (after[itemID] ?? 0) {
                lost[itemID] = (before[itemID] ?? 0) - (after[itemID] ?? 0)
            }
            var standing: [Int: Int] = [:]
            for dx in 0..<side { for dy in 0..<2 { for dz in 0..<side {
                let x = origin.x + dx, y = origin.y + dy, z = origin.z + dz
                for line in templateStandingMaterials(in: fixture.world, x, y, z) { standing[line.itemID, default: 0] += line.count }
                let value = fixture.world.getBlock(x, y, z)
                XCTAssertNotEqual(value >> 4, Int(B.piston_head), "\(which): a piston head stands")
                if value >> 4 == Int(B.piston) || value >> 4 == Int(B.sticky_piston) {
                    XCTAssertEqual(value & 8, 0, "\(which): an extended piston stands")
                }
                if twoCellHalf(of: value) == .secondary {
                    XCTAssertNotNil(twoCellPartnerCell(in: fixture.world, of: value, x, y, z), "\(which): a loose second half stands")
                }
            } } }
            XCTAssertEqual(lost, standing, "\(which): the bill is what stands")
            let receipt = try XCTUnwrap(fixture.game.lastTemplatePlacementUndo?.materials, which)
            for (itemID, count) in standing { XCTAssertEqual(receipt.paid(itemID), count, "\(which): \(itemDefs[itemID].name)") }
            XCTAssertEqual(receipt.total, standing.values.reduce(0, +), which)

            XCTAssertTrue(fixture.game.undoLastTemplatePlacement(), which)
            XCTAssertEqual(wealth(fixture, chest: (0, -60, 0)), before, "\(which): undo gives back what was lost")
        }
        XCTAssertEqual(pasted, 32)
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

    // MARK: - LAN host: what a guest is told about the containers

    /// A LAN host sends a guest the block entities that were marked dirty with its next delta,
    /// and otherwise only the eight nearest to a player, twice a second. A chest the host's own
    /// paste pays from or refunds into is therefore marked dirty, or a guest in a storage room
    /// keeps seeing it as it was and its next edit of that chest is refused as stale.

    /// A host session with one guest, told about rewritten containers the way the transport
    /// tells it (`LANMultiplayerManager.configureHostReplicationHooks`), and the guest's mirror
    /// after it joined.
    private func host(_ fixture: Fixture) -> (session: LANMultiplayerHostSession, guest: LANMultiplayerClientSession) {
        let session = LANMultiplayerHostSession()
        _ = session.acceptPeer(playerID: "guest", displayName: "Alex")
        fixture.game.onWorldContainerItemsChanged = { world, x, y, z in
            session.recordDirtyBlockEntity(LANBlockPosition(dimension: world.dim.rawValue, x: x, y: y, z: z))
        }
        let guest = LANMultiplayerClientSession()
        send(makeLANBlockEntitySnapshots(in: fixture.world), from: session, to: guest, fullSnapshot: true)
        return (session, guest)
    }

    private func send(_ snapshots: [LANBlockEntitySnapshot], from session: LANMultiplayerHostSession,
                      to guest: LANMultiplayerClientSession, fullSnapshot: Bool = false) {
        _ = guest.apply(session.makeBatch(
            tick: 0, fullSnapshot: fullSnapshot, worldSummary: nil, worldState: nil, localPlayer: nil,
            chunkSections: [], entitySnapshots: [], entitySnapshotsComplete: false, inventorySnapshots: [],
            blockEntitySnapshots: snapshots))
    }

    /// The host's next delta: the block entities marked dirty since the last one, drained and
    /// read from the world by the call the transport makes. Returns where they stand.
    @discardableResult
    private func sendDelta(_ fixture: Fixture, _ host: (session: LANMultiplayerHostSession, guest: LANMultiplayerClientSession),
                           file: StaticString = #filePath, line: UInt = #line) -> [[Int]] {
        let dirty = host.session.drainDirtyBlockEntitySnapshots(in: fixture.world)
        XCTAssertEqual(dirty.snapshots.map { [$0.x, $0.y, $0.z] }, dirty.positions.map { [$0.x, $0.y, $0.z] },
                       "every container that was written still stands", file: file, line: line)
        send(dirty.snapshots, from: host.session, to: host.guest)
        return dirty.positions.map { [$0.x, $0.y, $0.z] }
    }

    /// How many of an item the guest believes a container holds.
    private func mirrored(_ guest: LANMultiplayerClientSession, at position: (Int, Int, Int), _ name: String) -> Int {
        let key = LANBlockPosition(dimension: Dim.overworld.rawValue, x: position.0, y: position.1, z: position.2)
        return (guest.blockEntities[key]?.slots ?? []).filter { $0.itemID == iid(name) }.reduce(0) { $0 + $1.count }
    }

    func testAGuestIsToldAtOnceAboutAChestTheHostsPastePaidFrom() throws {
        let fixture = try makeFixture()
        // A storage room: eight empty chests behind the host, nearer than the one with planks,
        // so the twice-a-second fill of the eight nearest never reaches that one.
        for x in 1...8 { placeChest(fixture, at: (x, 64, -2), []) }
        let chestAt = (-10, 64, 10)
        placeChest(fixture, at: chestAt, [("oak_planks", 64)])
        let host = host(fixture)
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "oak_planks"), 64)

        try arm(fixture, planks(6))
        XCTAssertEqual(sendDelta(fixture, host), [], "arming the preview and its quote change no container")
        _ = try fixture.game.commitTemplatePlacement()
        XCTAssertEqual(stored(fixture, at: chestAt, "oak_planks"), 58)
        XCTAssertEqual(sendDelta(fixture, host), [[-10, 64, 10]], "the click pays, and only that chest was written")
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "oak_planks"), 58)

        finishJob(fixture)
        XCTAssertEqual(sendDelta(fixture, host), [], "a paste that wrote all its blocks pays nothing back")
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "oak_planks"), 58)
    }

    func testAGuestIsToldAboutEveryContainerAPastePaidFromAndNoOther() throws {
        let fixture = try makeFixture()
        let near = (3, 64, -3), further = (-10, 64, 10), untouched = (6, 64, -3), outOfRange = (60, 64, 0)
        placeChest(fixture, at: near, [("cobblestone", 9), ("oak_planks", 4)])
        placeChest(fixture, at: further, [("oak_planks", 64)])
        placeChest(fixture, at: untouched, [("cobblestone", 64)])
        placeChest(fixture, at: outOfRange, [("oak_planks", 64)])
        let host = host(fixture)

        try paste(fixture, planks(10))
        XCTAssertEqual(sendDelta(fixture, host), [[3, 64, -3], [-10, 64, 10]], "nearest first, each once")
        XCTAssertEqual(mirrored(host.guest, at: near, "oak_planks"), 0)
        XCTAssertEqual(mirrored(host.guest, at: near, "cobblestone"), 9)
        XCTAssertEqual(mirrored(host.guest, at: further, "oak_planks"), 58)
        XCTAssertEqual(mirrored(host.guest, at: outOfRange, "oak_planks"), 64)
    }

    func testAPasteThatTakesNothingFromAContainerTellsGuestsNothing() throws {
        let fixture = try makeFixture()
        let chestAt = (3, 64, -3)
        placeChest(fixture, at: chestAt, [("oak_planks", 3)])
        let host = host(fixture)

        // Refused: the player cannot pay, so nothing is taken.
        try arm(fixture, planks(6))
        XCTAssertThrowsError(try fixture.game.commitTemplatePlacement())
        XCTAssertEqual(sendDelta(fixture, host), [])

        // Paid from the inventory alone, and paid back to it.
        give(fixture, "oak_planks", 6, slot: 0)
        _ = try fixture.game.commitTemplatePlacement()
        finishJob(fixture)
        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(carried(fixture, "oak_planks"), 6)
        XCTAssertEqual(sendDelta(fixture, host), [])

        // Creative: free.
        fixture.player.setGameMode(GameMode.creative)
        try paste(fixture, planks(6))
        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(stored(fixture, at: chestAt, "oak_planks"), 3)
        XCTAssertEqual(sendDelta(fixture, host), [])
    }

    /// The dirt for the ground is charged at the click and paid back when the job finishes for
    /// every cell that needed no filling by then. Both writes reach the guest.
    func testAGuestIsToldWhenAFinishedPastePaysBackIntoAChest() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 3, slot: 0)
        let chestAt = (-6, 64, 6)
        placeChest(fixture, at: chestAt, [("dirt", 64)])
        let host = host(fixture)
        let origin = try arm(fixture, planks(3))
        fixture.world.setBlock(origin.x, origin.y - 1, origin.z, 0, SET_SILENT)
        fixture.world.setBlock(origin.x + 1, origin.y - 1, origin.z, 0, SET_SILENT)
        _ = try fixture.game.commitTemplatePlacement()
        XCTAssertEqual(sendDelta(fixture, host), [[-6, 64, 6]])
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "dirt"), 62, "two cells of ground are paid at the click")

        fixture.world.setBlock(origin.x + 1, origin.y - 1, origin.z, Int(cell(B.dirt)), SET_SILENT)
        finishJob(fixture)
        XCTAssertEqual(stored(fixture, at: chestAt, "dirt"), 63, "the cell that needed no filling is paid back")
        XCTAssertEqual(sendDelta(fixture, host), [[-6, 64, 6]])
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "dirt"), 63)
    }

    func testAGuestIsToldWhenUndoReturnsMaterialsToAChest() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 4, slot: 7)
        let chestAt = (-6, 64, 6)
        placeChest(fixture, at: chestAt, [("oak_planks", 20)])
        let host = host(fixture)
        try paste(fixture, planks(10))
        sendDelta(fixture, host)
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "oak_planks"), 14)

        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(stored(fixture, at: chestAt, "oak_planks"), 20)
        XCTAssertEqual(sendDelta(fixture, host), [[-6, 64, 6]])
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "oak_planks"), 20)
    }

    func testAnUndoWithNoRoomForItsRefundTellsGuestsNothing() throws {
        let fixture = try makeFixture()
        let chestAt = (-6, 64, 6)
        placeChest(fixture, at: chestAt, [("oak_planks", 5)])
        let host = host(fixture)
        try paste(fixture, planks(5))
        XCTAssertEqual(sendDelta(fixture, host), [[-6, 64, 6]])
        // No room anywhere: the chest and the inventory are full of something else.
        let chest = try XCTUnwrap(fixture.world.getBlockEntity(chestAt.0, chestAt.1, chestAt.2))
        for slot in 0..<27 { chest.items?[slot] = stack("cobblestone", 64) }
        for slot in fixture.player.inventory.indices { give(fixture, "cobblestone", 64, slot: slot) }

        XCTAssertFalse(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(sendDelta(fixture, host), [], "an undo that changes nothing writes no container")
    }

    /// The crafting screen takes ingredients from the same pool and puts a cleared grid back
    /// into it (`ScreensM.swift` makes these two calls on the host's world).
    func testAGuestIsToldAboutAChestTheHostCraftedFromAndReturnedTo() throws {
        let fixture = try makeFixture()
        let chestAt = (3, 64, -3), untouched = (6, 64, -3)
        placeChest(fixture, at: chestAt, [("oak_planks", 8)])
        placeChest(fixture, at: untouched, [("cobblestone", 64)])
        let host = host(fixture)
        var grid = [ItemStack?](repeating: nil, count: 9)
        let center = try XCTUnwrap(craftingContainerPoolCenter(for: fixture.player, isLANClientWorld: false))
        let resources = craftingResourceStacks(playerInventory: fixture.player.inventory, craftGrid: grid,
                                               world: fixture.world, centerX: center.x, centerY: center.y,
                                               centerZ: center.z, radius: CRAFTING_CONTAINER_RADIUS)
        let plan = try XCTUnwrap(craftingPlans(for: resources, gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "crafting_table"
        })
        XCTAssertEqual(sendDelta(fixture, host), [], "looking at what can be crafted changes no container")

        XCTAssertTrue(populateCraftingGridFromNearbyContainers(
            plan, grid: &grid, inventory: &fixture.player.inventory, world: fixture.world,
            centerX: center.x, centerY: center.y, centerZ: center.z, radius: CRAFTING_CONTAINER_RADIUS))
        XCTAssertEqual(sendDelta(fixture, host), [[3, 64, -3]])
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "oak_planks"), 4)

        // The player clears the grid with a full inventory: the planks go back to the chest.
        for slot in fixture.player.inventory.indices { give(fixture, "stone", 64, slot: slot) }
        for stack in grid.compactMap({ $0 }) {
            XCTAssertTrue(giveStackToNearbyCraftingContainers(
                stack, world: fixture.world, centerX: center.x, centerY: center.y, centerZ: center.z,
                radius: CRAFTING_CONTAINER_RADIUS))
        }
        XCTAssertEqual(sendDelta(fixture, host), [[3, 64, -3]])
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "oak_planks"), 8)
    }

    func testAGuestsOwnGameTellsNoSessionAboutItsContainers() throws {
        let fixture = try makeFixture()
        var told = 0
        fixture.game.onWorldContainerItemsChanged = { _, _, _, _ in told += 1 }
        let hooks = fixture.world.hooks
        hooks.onContainerItemsChanged(fixture.world, 1, 64, 1)
        XCTAssertEqual(told, 1)

        fixture.game.enterLANClientWorld(LANWorldSummary(
            worldID: "host-world", worldName: "Host", seed: 1, gameMode: GameMode.survival, difficulty: 0,
            dimension: Dim.overworld.rawValue, playerCount: 2))
        XCTAssertTrue(fixture.game.isLANClientWorld)
        hooks.onContainerItemsChanged(fixture.world, 1, 64, 1)
        fixture.game.world.hooks.onContainerItemsChanged(fixture.game.world, 1, 64, 1)
        XCTAssertEqual(told, 1, "a guest's world reports nothing: the host owns every container")
    }

    /// One delta carries at most `LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES`. A paste paid
    /// from more chests than that reaches the guest over the next deltas: every chest once, none
    /// lost, nearest first.
    func testAPastePaidFromMoreChestsThanOneDeltaCarriesReachesTheGuestOverTheNextDeltas() throws {
        let fixture = try makeFixture()
        // Seventy chests behind the player, one plank each.
        var chests: [(Int, Int, Int)] = []
        for z in -8...(-2) { for x in -9...0 { chests.append((x, 64, z)) } }
        XCTAssertGreaterThan(chests.count, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES)
        for at in chests { placeChest(fixture, at: at, [("oak_planks", 1)]) }
        let host = host(fixture)
        let floor = object("Floor", (0..<chests.count).map { ($0 % 10, 0, $0 / 10, "oak_planks", 0) })
        let origin = try arm(fixture, floor)
        XCTAssertGreaterThan(origin.z, -2, "no chest stands in the floor's box")
        XCTAssertEqual(sendDelta(fixture, host), [])

        _ = try fixture.game.commitTemplatePlacement()
        let first = sendDelta(fixture, host)
        let second = sendDelta(fixture, host)
        XCTAssertEqual(first.count, LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES)
        XCTAssertEqual(second.count, chests.count - LAN_MULTIPLAYER_MAX_REPLICATION_BLOCK_ENTITIES)
        XCTAssertEqual(sendDelta(fixture, host), [], "nothing is sent twice")
        let sent = first + second
        XCTAssertEqual(Set(sent).count, sent.count)
        XCTAssertEqual(Set(sent), Set(chests.map { [$0.0, $0.1, $0.2] }))
        let distances = sent.map { $0[0] * $0[0] + ($0[1] - 64) * ($0[1] - 64) + $0[2] * $0[2] }
        XCTAssertEqual(distances, distances.sorted(), "the nearest chests go first")
        for at in chests {
            XCTAssertEqual(stored(fixture, at: at, "oak_planks"), 0)
            XCTAssertEqual(mirrored(host.guest, at: at, "oak_planks"), 0, "\(at)")
        }
        finishJob(fixture)
        XCTAssertEqual(sendDelta(fixture, host), [])
    }

    /// Two writes to one chest before the next delta: it is sent once, with what it holds last.
    func testAChestWrittenTwiceBeforeTheNextDeltaIsSentOnceWithWhatItHoldsLast() throws {
        let fixture = try makeFixture()
        let chestAt = (3, 64, -3)
        placeChest(fixture, at: chestAt, [("oak_planks", 20)])
        let host = host(fixture)
        try arm(fixture, planks(10))
        _ = try fixture.game.commitTemplatePlacement()                       // 20 -> 10
        let center = try XCTUnwrap(craftingContainerPoolCenter(for: fixture.player, isLANClientWorld: false))
        var grid = [ItemStack?](repeating: nil, count: 9)
        let table = try XCTUnwrap(craftingPlans(for: [stack("oak_planks", 4)], gridWidth: 3, gridHeight: 3).first {
            itemDef($0.output.id).name == "crafting_table"
        })
        XCTAssertTrue(populateCraftingGridFromNearbyContainers(                // 10 -> 6
            table, grid: &grid, inventory: &fixture.player.inventory, world: fixture.world,
            centerX: center.x, centerY: center.y, centerZ: center.z, radius: CRAFTING_CONTAINER_RADIUS))
        XCTAssertEqual(stored(fixture, at: chestAt, "oak_planks"), 6)

        XCTAssertEqual(sendDelta(fixture, host), [[3, 64, -3]])
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "oak_planks"), 6)
        XCTAssertEqual(sendDelta(fixture, host), [])
        finishJob(fixture)
    }

    /// An undo refund goes to the first room in pool order, which need not be the chest it was
    /// paid from. The guest is told about the chest it went into, and not about the other.
    func testAnUndoRefundThatGoesIntoAnotherChestTellsTheGuestAboutThatChest() throws {
        let fixture = try makeFixture()
        let source = (-10, 64, 10), nearer = (2, 64, -2)
        placeChest(fixture, at: source, [("oak_planks", 6)])
        placeChest(fixture, at: nearer, [])
        let host = host(fixture)
        try paste(fixture, planks(6))
        XCTAssertEqual(sendDelta(fixture, host), [[-10, 64, 10]])
        XCTAssertEqual(mirrored(host.guest, at: source, "oak_planks"), 0)

        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(stored(fixture, at: nearer, "oak_planks"), 6, "the nearest free slot takes the refund")
        XCTAssertEqual(stored(fixture, at: source, "oak_planks"), 0)
        XCTAssertEqual(sendDelta(fixture, host), [[2, 64, -2]])
        XCTAssertEqual(mirrored(host.guest, at: nearer, "oak_planks"), 6)
        XCTAssertEqual(mirrored(host.guest, at: source, "oak_planks"), 0)
    }

    /// What was paid from the inventory goes back there, and into a chest when the inventory
    /// has filled up since: that chest is written, so the guest is told.
    func testARefundThatOverflowsAFullInventoryIntoAChestTellsTheGuest() throws {
        let fixture = try makeFixture()
        give(fixture, "oak_planks", 5, slot: 0)
        let chestAt = (2, 64, -2)
        placeChest(fixture, at: chestAt, [])
        let host = host(fixture)
        try paste(fixture, planks(5))
        XCTAssertEqual(sendDelta(fixture, host), [], "paid from the inventory alone")
        for slot in fixture.player.inventory.indices { give(fixture, "cobblestone", 64, slot: slot) }

        XCTAssertTrue(fixture.game.undoLastTemplatePlacement())
        XCTAssertEqual(stored(fixture, at: chestAt, "oak_planks"), 5)
        XCTAssertEqual(sendDelta(fixture, host), [[2, 64, -2]])
        XCTAssertEqual(mirrored(host.guest, at: chestAt, "oak_planks"), 5)
    }

    /// The halves of a double chest are two block entities; a furnace's slots and a hopper pay
    /// too. Every one the paste empties is sent once.
    func testAGuestIsToldAboutBothHalvesOfADoubleChestAFurnaceAndAHopperAPastePaidFrom() throws {
        let fixture = try makeFixture()
        let left = (2, 64, -2), right = (3, 64, -2), furnaceAt = (-2, 64, -2), hopperAt = (0, 64, -3)
        placeChest(fixture, at: left, [("oak_planks", 2)])
        placeChest(fixture, at: right, [("oak_planks", 2)])
        fixture.world.setBlock(furnaceAt.0, furnaceAt.1, furnaceAt.2, Int(cell(B.furnace, 2)), SET_SILENT)
        let furnace = makeFurnaceBE(furnaceAt.0, furnaceAt.1, furnaceAt.2, "furnace")
        furnace.items?[2] = stack("oak_planks", 2)
        fixture.world.setBlockEntity(furnace)
        fixture.world.setBlock(hopperAt.0, hopperAt.1, hopperAt.2, Int(cell(B.hopper)), SET_SILENT)
        let hopper = makeHopperBE(hopperAt.0, hopperAt.1, hopperAt.2)
        hopper.items?[3] = stack("oak_planks", 2)
        fixture.world.setBlockEntity(hopper)
        let host = host(fixture)
        for at in [left, right, furnaceAt, hopperAt] { XCTAssertEqual(mirrored(host.guest, at: at, "oak_planks"), 2) }

        try arm(fixture, planks(8))
        _ = try fixture.game.commitTemplatePlacement()
        let sent = sendDelta(fixture, host)
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(Set(sent), [[2, 64, -2], [3, 64, -2], [-2, 64, -2], [0, 64, -3]])
        for at in [left, right, furnaceAt, hopperAt] {
            XCTAssertEqual(stored(fixture, at: at, "oak_planks"), 0, "\(at)")
            XCTAssertEqual(mirrored(host.guest, at: at, "oak_planks"), 0, "\(at)")
        }
        finishJob(fixture)
    }

    /// The quote a preview shows, the check when it is armed, and a click the player cannot pay
    /// for read the pool and write no container, however many there are.
    func testQuotingAndARefusedClickTellGuestsNothingAboutAFullStorageRoom() throws {
        let fixture = try makeFixture()
        for x in -9...0 { placeChest(fixture, at: (x, 64, -3), [("oak_planks", 1), ("cobblestone", 64)]) }
        let host = host(fixture)
        let template = planks(12)
        XCTAssertEqual(fixture.game.templateMaterialQuote(for: template).missing,
                       [TemplateMaterialLine(itemID: iid("oak_planks"), count: 2)])
        try arm(fixture, template)
        XCTAssertThrowsError(try fixture.game.commitTemplatePlacement())
        XCTAssertEqual(sendDelta(fixture, host), [])
        for x in -9...0 { XCTAssertEqual(stored(fixture, at: (x, 64, -3), "oak_planks"), 1) }
    }
}
