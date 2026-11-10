import XCTest
@testable import ElysiumCore

/// The wire shape of a guest's template intent and what the host does with it
/// (`LANTemplateTransfer.swift`, `LANMultiplayerHostSession.applyTemplateIntent`).
final class LANTemplateTransferTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
    }

    // MARK: - fixtures

    private func loadedWorld(groundY: Int? = 63) -> World {
        let world = World(dim: .overworld, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        if let groundY {
            for z in 0..<CHUNK_W {
                for x in 0..<CHUNK_W {
                    chunk.set(x, groundY, z, cell(B.dirt, 0))
                }
            }
        }
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }

    private func hostSession(x: Double = 2.5, y: Double = 64, z: Double = 1.5) -> LANMultiplayerHostSession {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        session.updatePlayerState(playerState(x: x, y: y, z: z))
        return session
    }

    private func playerState(x: Double, y: Double, z: Double) -> LANPlayerState {
        LANPlayerState(playerID: "guest", displayName: "Alex", x: x, y: y, z: z, yaw: 0, pitch: 0,
                       health: 20, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival)
    }

    private func template(named name: String = "Tiny", sizeX: Int = 1, sizeY: Int = 1, sizeZ: Int = 1,
                          block: UInt16 = UInt16(Int(B.oak_planks) << 4)) -> ObjectTemplate {
        var blocks: [TemplateBlock] = []
        for y in 0..<sizeY {
            for z in 0..<sizeZ {
                for x in 0..<sizeX {
                    blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: block))
                }
            }
        }
        return ObjectTemplate(name: name, anchorX: 0, anchorY: 0, anchorZ: 0,
                              sizeX: sizeX, sizeY: sizeY, sizeZ: sizeZ, blocks: blocks)
    }

    private func placeIntent(_ template: ObjectTemplate, x: Int, y: Int, z: Int,
                             rotation: Int = 0) throws -> LANTemplateIntent {
        LANTemplateIntent(action: .placeTemplate, templateName: template.name, x: x, y: y, z: z,
                          rotation: rotation, templateData: try lanGuestTemplatePayload(for: template))
    }

    private let undoIntent = LANTemplateIntent(action: .undoPlacement, templateName: "", x: 0, y: 0, z: 0, rotation: 0)

    /// Steps the guest's job to its end and returns everything the host queued for the guest.
    private func finish(_ session: LANMultiplayerHostSession, in world: World,
                        budgetPerPeer: Int = LAN_MULTIPLAYER_TEMPLATE_JOB_STEP_BUDGET,
                        file: StaticString = #filePath, line: UInt = #line) -> [LANTemplateIntentResult] {
        var steps = 0
        while session.hasActiveTemplateJob(playerID: "guest") {
            session.stepTemplateJobs(in: world, budgetPerPeer: budgetPerPeer)
            steps += 1
            if steps > 100_000 {
                XCTFail("the template job did not finish", file: file, line: line)
                break
            }
        }
        return session.drainTemplateIntentResponses().map(\.result)
    }

    private func worldCells(_ world: World) -> [Int] {
        var cells: [Int] = []
        for y in 60..<72 {
            for z in 0..<CHUNK_W {
                for x in 0..<CHUNK_W {
                    cells.append(world.getBlock(x, y, z))
                }
            }
        }
        return cells
    }

    // MARK: - wire shape

    func testPlaceIntentCarriesItsTemplateThroughTheFrameCodec() throws {
        let house = template(named: "A House", sizeX: 3, sizeY: 2, sizeZ: 2)
        let intent = try placeIntent(house, x: 9, y: 64, z: -4, rotation: -1)
        XCTAssertEqual(intent.rotation, 3)

        let frame = try LANMultiplayerFrameCodec.encode(.templateIntent(playerID: "guest", intent: intent), sequence: 7)
        guard case .templateIntent(let playerID, let received) = try LANMultiplayerFrameCodec.decode(frame).message else {
            return XCTFail("expected a template intent")
        }

        XCTAssertEqual(playerID, "guest")
        XCTAssertEqual(received, intent)
        let decoded = try lanHostTemplate(fromGuestPayload: try XCTUnwrap(received.templateData))
        XCTAssertEqual(decoded.name, "A House")
        XCTAssertEqual(decoded.blocks, house.blocks)
    }

    func testLargestPayloadFitsInOneFrameWhateverItsBytes() throws {
        // 0xFF bytes are all `/` in base64 and 0xFB bytes all `+`: the two characters the wire
        // text replaces. A frame's size must not depend on the template's content.
        var sizes = Set<Int>()
        for byte in [UInt8(0x00), 0xFB, 0xFF, 0x5A] {
            let payload = Data(repeating: byte, count: LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES)
            let intent = LANTemplateIntent(action: .placeTemplate, templateName: String(repeating: "W", count: 64),
                                           x: -30_000_000, y: -30_000_000, z: -30_000_000, rotation: 3,
                                           templateData: payload)
            XCTAssertEqual(intent.templateData, payload)
            let encoded = try LANMultiplayerFrameCodec.encodePayload(
                .templateIntent(playerID: String(repeating: "p", count: 128), intent: intent))
            XCTAssertLessThanOrEqual(encoded.payload.count, LAN_MULTIPLAYER_MAX_FRAME_BYTES)
            sizes.insert(encoded.payload.count)
            let frame = LANMultiplayerFrameCodec.frame(kind: encoded.kind, payload: encoded.payload, sequence: 1)
            guard case .templateIntent(_, let received) = try LANMultiplayerFrameCodec.decode(frame).message else {
                return XCTFail("expected a template intent")
            }
            XCTAssertEqual(received.templateData, payload)
        }
        XCTAssertEqual(sizes.count, 1, "the frame size changed with the payload's bytes: \(sizes)")
    }

    func testIntentDropsWhatItMustNotCarry() throws {
        let tooBig = Data(repeating: 1, count: LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES + 1)
        XCTAssertNil(LANTemplateIntent(action: .placeTemplate, templateName: "Big", x: 0, y: 0, z: 0, rotation: 0,
                                       templateData: tooBig).templateData)
        XCTAssertNil(LANTemplateIntent(action: .undoPlacement, templateName: "", x: 0, y: 0, z: 0, rotation: 0,
                                       templateData: Data([1, 2, 3])).templateData,
                     "an undo never carries a template")

        let far = LANTemplateIntent(action: .placeTemplate, templateName: "Far", x: Int.max, y: Int.min, z: 40_000_000,
                                    rotation: 0)
        XCTAssertEqual([far.x, far.y, far.z], [30_000_000, -30_000_000, 30_000_000])

        // Decoding goes through the same rules: wire text that is too long, or is not base64 at
        // all, leaves the intent without a template instead of failing the whole frame.
        func decode(templateData text: String, x: String = "1") throws -> LANTemplateIntent {
            let json = "{\"action\":\"placeTemplate\",\"templateName\":\"T\",\"x\":\(x),\"y\":2,\"z\":3,"
                + "\"rotation\":5,\"templateData\":\"\(text)\"}"
            return try JSONDecoder().decode(LANTemplateIntent.self, from: Data(json.utf8))
        }
        XCTAssertNil(try decode(templateData: String(repeating: "A", count: 960_004)).templateData)
        XCTAssertNil(try decode(templateData: "not base64 !").templateData)
        let decoded = try decode(templateData: "AQID", x: "9223372036854775807")
        XCTAssertEqual(decoded.templateData, Data([1, 2, 3]))
        XCTAssertEqual(decoded.x, 30_000_000)
        XCTAssertEqual(decoded.rotation, 1)
        XCTAssertThrowsError(try JSONDecoder().decode(
            LANTemplateIntent.self,
            from: Data("{\"action\":\"copyTarget\",\"templateName\":\"T\",\"x\":1,\"y\":2,\"z\":3}".utf8)),
            "the host no longer copies into its own library for a guest")
    }

    func testGuestPayloadLimitIsAboutNinetyThousandBlocks() throws {
        func slab(blocks count: Int) -> ObjectTemplate {
            var blocks: [TemplateBlock] = []
            outer: for y in 0..<96 {
                for z in 0..<96 {
                    for x in 0..<96 {
                        if blocks.count == count { break outer }
                        blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: UInt16(Int(B.stone) << 4)))
                    }
                }
            }
            return ObjectTemplate(name: "Slab", anchorX: 0, anchorY: 0, anchorZ: 0,
                                  sizeX: 96, sizeY: 96, sizeZ: 96, blocks: blocks)
        }
        let fits = try lanGuestTemplatePayload(for: slab(blocks: 89_900))
        XCTAssertLessThanOrEqual(fits.count, LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES)
        XCTAssertEqual(try lanHostTemplate(fromGuestPayload: fits).blocks.count, 89_900)
        XCTAssertThrowsError(try lanGuestTemplatePayload(for: slab(blocks: 90_001))) { error in
            XCTAssertEqual(error as? TemplateError, .tooLargeForLANGuest(90_001))
        }
    }

    // MARK: - what the host accepts from a guest's bytes

    func testHostRefusesPayloadsThatAreNotATemplate() throws {
        XCTAssertThrowsError(try lanHostTemplate(fromGuestPayload: Data()))
        XCTAssertThrowsError(try lanHostTemplate(fromGuestPayload: Data("PBT2".utf8)))
        XCTAssertThrowsError(try lanHostTemplate(fromGuestPayload: Data(repeating: 0xFF, count: 4_096)))
        // The library still reads legacy JSON templates. A guest may only send the binary form.
        let json = try JSONEncoder().encode(template())
        XCTAssertNoThrow(try decodeObjectTemplate(json))
        XCTAssertThrowsError(try lanHostTemplate(fromGuestPayload: json))
        // A truncated or padded payload fails the decoder's exact-length check.
        let good = try lanGuestTemplatePayload(for: template(sizeX: 2))
        XCTAssertThrowsError(try lanHostTemplate(fromGuestPayload: good.dropLast()))
        XCTAssertThrowsError(try lanHostTemplate(fromGuestPayload: good + Data([0])))
        XCTAssertNoThrow(try lanHostTemplate(fromGuestPayload: good))
    }

    func testHostRefusesUnreadableBlockEntityDataWithAPlainMessage() throws {
        // A well-formed header whose block-entity bytes are not the JSON they claim to be.
        var data = try lanGuestTemplatePayload(for: template())
        let garbage = Data("[{\"type\":7}]".utf8)
        // Header: magic(4) version(2) flags(2) nameLen(2) anchors(12) sizes(6) blocks(4) BEs(4) BEbytes(4)
        func setU32(_ value: Int, at offset: Int) {
            for i in 0..<4 { data[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        setU32(1, at: 32)
        setU32(garbage.count, at: 36)
        data.removeLast(2) // the empty "[]" block-entity list the encoder wrote
        data.append(garbage)

        XCTAssertThrowsError(try lanHostTemplate(fromGuestPayload: data)) { error in
            XCTAssertEqual(error as? TemplateError, .corruptTemplate("unreadable block entity data"))
        }
    }

    func testGuestTemplateArrivesWithEmptyContainers() throws {
        var source = template(named: "Stash", sizeX: 2)
        source.blocks[0].cell = UInt16(cell(B.chest, 2))
        source.blocks[1].cell = UInt16(cell(B.furnace_lit, 3))
        let chest = BlockEntityData(type: "chest", x: 0, y: 0, z: 0)
        chest.items = Array(repeating: nil, count: 27)
        chest.items?[0] = ItemStack(iid("diamond"), 64)
        let furnace = BlockEntityData(type: "furnace", x: 1, y: 0, z: 0)
        furnace.items = [ItemStack(iid("iron_ore"), 8), ItemStack(iid("coal"), 8), ItemStack(iid("iron_ingot"), 8)]
        furnace.burnTime = 100
        source.blockEntities = [chest, furnace]
        // The guest's own library can hold such a template (an old or edited one). It still
        // encodes, so the host is what must empty it.
        let payload = try lanGuestTemplatePayload(for: source)
        XCTAssertEqual(try decodeObjectTemplate(payload).blockEntities.first?.items?[0]?.count, 64)

        let world = loadedWorld()
        let session = hostSession()
        XCTAssertEqual(
            session.applyTemplateIntent(
                LANTemplateIntent(action: .placeTemplate, templateName: "Stash", x: 2, y: 64, z: 3, rotation: 0,
                                  templateData: payload),
                from: "guest", world: world),
            .accepted(action: .placeTemplate, name: "Stash"))
        XCTAssertEqual(finish(session, in: world).last,
                       .placed(name: "Stash", blocks: 2, blockEntities: 2, cleared: 0, filled: 0))

        let placedChest = try XCTUnwrap(world.getBlockEntity(2, 64, 3))
        XCTAssertEqual(placedChest.items?.count, 27)
        XCTAssertTrue(placedChest.items?.allSatisfy { $0 == nil } ?? false, "a guest's paste brought items with it")
        let placedFurnace = try XCTUnwrap(world.getBlockEntity(3, 64, 3))
        XCTAssertTrue(placedFurnace.items?.allSatisfy { $0 == nil } ?? false)
        XCTAssertEqual(placedFurnace.burnTime, 0)
        XCTAssertEqual(world.getBlock(3, 64, 3), Int(cell(B.furnace, 3)), "an emptied furnace must not stay lit")
        XCTAssertEqual(world.getBlock(2, 64, 3), Int(cell(B.chest, 2)))
    }

    // MARK: - reach

    func testReachFollowsTheGuestsOwnPreviewForEveryRotationAndPush() throws {
        var rng: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Double(rng >> 11) / Double(1 << 53)
        }
        var checked = 0
        for _ in 0..<400 {
            var raw = template(sizeX: 1 + Int(next() * 20), sizeY: 1 + Int(next() * 20), sizeZ: 1 + Int(next() * 20))
            raw.anchorX = Int(next() * Double(raw.sizeX))
            raw.anchorY = Int(next() * Double(raw.sizeY))
            raw.anchorZ = Int(next() * Double(raw.sizeZ))
            let rotation = Int(next() * 4)
            var session = try TemplatePlacementSession(template: raw, rotationSteps: rotation)
            session.nudgeDistance(by: next() * 80 - 20) // clamped by the session, as in the game
            let px = next() * 2000 - 1000, py = 60 + next() * 40, pz = next() * 2000 - 1000
            let yaw = next() * 2 * Double.pi, pitch = (next() - 0.5) * 3.1
            let target = objectTemplatePlacementTargetForValidatedTemplate(
                session.rotatedTemplate, eyeX: px, eyeY: py + PLAYER_EYE, eyeZ: pz,
                yaw: yaw, pitch: pitch, distanceOffset: session.distanceOffset)
            // The host knows the guest's position only as of its last update: let it be off by
            // a few blocks in any direction.
            let stale = playerState(x: px + (next() - 0.5) * 6, y: py + (next() - 0.5) * 4, z: pz + (next() - 0.5) * 6)
            XCTAssertTrue(
                isWithinLANTemplateReach(stale, template: session.baseTemplate, rotationSteps: rotation,
                                         targetX: target.targetX, targetY: target.targetY, targetZ: target.targetZ),
                "the host would refuse a paste the guest's own preview allows: size \(raw.sizeX)x\(raw.sizeY)x\(raw.sizeZ) rotation \(rotation) distance \(target.distance)")
            checked += 1
        }
        XCTAssertEqual(checked, 400)
    }

    func testReachRefusesATargetBeyondAnyPreview() throws {
        let cube = template(sizeX: 5, sizeY: 5, sizeZ: 5)
        let limit = try templatePlacementPreviewDistance(for: cube)
            + TemplatePlacementSession.maxExtraDistance + LAN_MULTIPLAYER_TEMPLATE_REACH_SLACK
        let eye = playerState(x: 0.5, y: 64 - PLAYER_EYE + 2.5, z: 0.5)
        // The object's centre is 2.5 blocks past its anchor on each axis; walk it out along +z.
        let just = Int((limit - 2.5).rounded(.down))
        XCTAssertTrue(isWithinLANTemplateReach(eye, template: cube, rotationSteps: 0, targetX: -2, targetY: 64, targetZ: just - 1))
        XCTAssertFalse(isWithinLANTemplateReach(eye, template: cube, rotationSteps: 0, targetX: -2, targetY: 64, targetZ: just + 2))
        XCTAssertFalse(isWithinLANTemplateReach(eye, template: cube, rotationSteps: 0,
                                                targetX: 30_000_000, targetY: -30_000_000, targetZ: 30_000_000))
        // A template whose anchor lies far outside its own bounds cannot move the object away
        // from where reach is measured: reach is measured to the object, not to the click.
        var skewed = cube
        skewed.anchorX = 2_000_000_000
        XCTAssertFalse(isWithinLANTemplateReach(eye, template: skewed, rotationSteps: 0, targetX: 0, targetY: 64, targetZ: 0))
    }

    func testHostPlacesAnObjectWhosePreviewSitsFarBeyondBlockReach() throws {
        let world = loadedWorld()
        let session = hostSession(x: 8.5, y: 64, z: 1.5)
        // Twelve blocks ahead: twice the survival block reach the host used to apply here.
        let result = session.applyTemplateIntent(try placeIntent(template(sizeX: 2, sizeY: 2, sizeZ: 2), x: 8, y: 64, z: 13),
                                                 from: "guest", world: world)
        XCTAssertEqual(result, .accepted(action: .placeTemplate, name: "Tiny"))
        XCTAssertEqual(finish(session, in: world).last,
                       .placed(name: "Tiny", blocks: 8, blockEntities: 0, cleared: 0, filled: 0))
        XCTAssertEqual(world.getBlock(9, 65, 14), Int(B.oak_planks) << 4)
    }

    // MARK: - refusals change nothing

    func testEveryRefusalLeavesTheWorldAndTheGuestsUndoAlone() throws {
        let world = loadedWorld()
        let session = hostSession()
        let tiny = template()
        let good = try placeIntent(tiny, x: 2, y: 64, z: 3)
        let before = worldCells(world)

        // No template, and bytes that are not one.
        XCTAssertEqual(session.applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: "Tiny", x: 2, y: 64, z: 3, rotation: 0),
            from: "guest", world: world), .rejected(LANTemplateRefusal.missingTemplate))
        guard case .rejected(let corrupt) = session.applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: "Tiny", x: 2, y: 64, z: 3, rotation: 0,
                              templateData: Data(repeating: 7, count: 64)),
            from: "guest", world: world) else { return XCTFail("garbage must be refused") }
        XCTAssertEqual(corrupt, "Template is corrupt: not a template the host can read.")
        // Too far.
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(tiny, x: 2, y: 64, z: 90), from: "guest", world: world),
                       .rejected(LANTemplateRefusal.outOfReach))
        // The host is in another dimension than the guest.
        let nether = World(dim: .nether, seed: 42)
        XCTAssertEqual(session.applyTemplateIntent(good, from: "guest", world: nether),
                       .rejected(LANTemplateRefusal.otherDimension))
        // Not allowed: no template grant, then no build grant.
        var permissions = LANPeerPermissions()
        permissions.canUseTemplates = false
        session.setPermissions(permissions, for: "guest")
        XCTAssertEqual(session.applyTemplateIntent(good, from: "guest", world: world),
                       .rejected(LANTemplateRefusal.notAllowed))
        XCTAssertEqual(session.applyTemplateIntent(undoIntent, from: "guest", world: world),
                       .rejected(LANTemplateRefusal.notAllowed))
        permissions = LANPeerPermissions()
        permissions.canBuild = false
        session.setPermissions(permissions, for: "guest")
        XCTAssertEqual(session.applyTemplateIntent(good, from: "guest", world: world),
                       .rejected(LANTemplateRefusal.cannotBuild))
        // A stranger, and nothing to undo.
        XCTAssertEqual(session.applyTemplateIntent(good, from: "nobody", world: world),
                       .rejected(LANTemplateRefusal.unavailable))
        session.setPermissions(LANPeerPermissions(), for: "guest")
        XCTAssertEqual(session.applyTemplateIntent(undoIntent, from: "guest", world: world),
                       .rejected(LANTemplateRefusal.nothingToUndo))
        // A destination outside the loaded world: the job's own preflight refuses it.
        guard case .rejected(let unloaded) = session.applyTemplateIntent(
            try placeIntent(tiny, x: 2, y: 64, z: -3), from: "guest", world: world) else {
            return XCTFail("an unloaded destination must be refused")
        }
        XCTAssertTrue(unloaded.hasPrefix("Destination is not loaded"), unloaded)

        XCTAssertEqual(worldCells(world), before)
        XCTAssertFalse(session.hasActiveTemplateJob(playerID: "guest"))
        XCTAssertTrue(session.drainTemplateIntentResponses().isEmpty)
    }

    func testBusyIsAnsweredBeforeThePayloadIsRead() throws {
        let world = loadedWorld()
        let session = hostSession()
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(template(sizeX: 4, sizeY: 4, sizeZ: 4), x: 2, y: 64, z: 3),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Tiny"))
        // Bytes that would be refused as corrupt get the busy answer instead: the host did not
        // look at them.
        XCTAssertEqual(session.applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: "Tiny", x: 2, y: 64, z: 3, rotation: 0,
                              templateData: Data(repeating: 7, count: 64)),
            from: "guest", world: world), .rejected(LANTemplateRefusal.busy))
        _ = finish(session, in: world)
    }

    // MARK: - undo and progress

    func testUndoNeedsNoNameAndRestoresWhatThePasteReplaced() throws {
        let world = loadedWorld()
        _ = world.setBlock(2, 64, 3, Int(cell(B.stone, 0)))
        let session = hostSession()
        let before = worldCells(world)

        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(template(named: "Named By Bytes"), x: 2, y: 64, z: 3),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Named By Bytes"))
        XCTAssertEqual(finish(session, in: world).last,
                       .placed(name: "Named By Bytes", blocks: 1, blockEntities: 0, cleared: 1, filled: 0))
        XCTAssertEqual(world.getBlock(2, 64, 3), Int(B.oak_planks) << 4)

        XCTAssertEqual(session.applyTemplateIntent(undoIntent, from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Named By Bytes"))
        XCTAssertEqual(finish(session, in: world).last, .undone(name: "Named By Bytes", restored: 1))
        XCTAssertEqual(worldCells(world), before)
    }

    func testIntentNameCannotRenameTheObject() throws {
        let world = loadedWorld()
        let session = hostSession()
        let payload = try lanGuestTemplatePayload(for: template(named: "Real Name"))
        XCTAssertEqual(session.applyTemplateIntent(
            LANTemplateIntent(action: .placeTemplate, templateName: "Other Name", x: 2, y: 64, z: 3, rotation: 0,
                              templateData: payload),
            from: "guest", world: world), .accepted(action: .placeTemplate, name: "Real Name"))
        _ = finish(session, in: world)
    }

    func testHostReportsProgressWhileALargeJobRunsAndCompletionLast() throws {
        let world = loadedWorld()
        let session = hostSession(x: 8.5, y: 64, z: 1.5)
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(template(named: "Hall", sizeX: 6, sizeY: 4, sizeZ: 6), x: 5, y: 64, z: 6),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Hall"))

        let reports = finish(session, in: world, budgetPerPeer: 4)

        let percents: [Int] = reports.dropLast().map {
            guard case .progress(let action, let name, let percent, let phase) = $0 else {
                XCTFail("only progress may come before completion, got \($0)")
                return -1
            }
            XCTAssertEqual(action, .placeTemplate)
            XCTAssertEqual(name, "Hall")
            XCTAssertFalse(phase.isEmpty)
            return percent
        }
        XCTAssertGreaterThanOrEqual(percents.count, 2, "a job of many steps must report along the way")
        XCTAssertEqual(percents, percents.sorted())
        // A job can stand at 100% for one step: its last operation is done, its completion follows.
        XCTAssertTrue(percents.allSatisfy { (0...100).contains($0) }, "\(percents)")
        XCTAssertEqual(reports.last, .placed(name: "Hall", blocks: 144, blockEntities: 0, cleared: 0, filled: 0))

        // A job that finishes within the reporting interval sends no progress at all.
        XCTAssertEqual(session.applyTemplateIntent(undoIntent, from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Hall"))
        XCTAssertEqual(finish(session, in: world), [.undone(name: "Hall", restored: 144)])
    }

    // MARK: - what the guest is told

    func testEachResultBecomesTheEventItsGuestActsOn() {
        func event(_ result: LANTemplateIntentResult) -> LANGameplayEvent {
            lanTemplateGameplayEvent(for: result, playerID: "guest", tick: 9)
        }
        let cases: [(LANTemplateIntentResult, LANGameplayEventKind, String)] = [
            (.accepted(action: .placeTemplate, name: "Hut"), .templatePlaceAccepted, "Placing \"Hut\""),
            (.accepted(action: .undoPlacement, name: "Hut"), .templateUndoAccepted, "Undoing \"Hut\""),
            (.progress(action: .placeTemplate, name: "Hut", percent: 40, phase: "placing blocks"),
             .templateProgress, "Placing \"Hut\" 40% - placing blocks"),
            (.progress(action: .undoPlacement, name: "Hut", percent: 5, phase: "restoring"),
             .templateProgress, "Undoing \"Hut\" 5% - restoring"),
            (.placed(name: "Hut", blocks: 12, blockEntities: 1, cleared: 0, filled: 0),
             .templateCompleted, "Placed object \"Hut\" - 12 blocks, 1 block entities"),
            (.placed(name: "Hut", blocks: 12, blockEntities: 1, cleared: 3, filled: 2),
             .templateCompleted, "Placed object \"Hut\" - 12 blocks, 1 block entities, cleared 3, filled 2"),
            (.undone(name: "Hut", restored: 17), .templateCompleted, "Undid object placement \"Hut\" - restored 17 cells"),
            (.rejected(LANTemplateRefusal.outOfReach), .templateRefused, LANTemplateRefusal.outOfReach),
        ]
        for (result, kind, message) in cases {
            let sent = event(result)
            XCTAssertEqual(sent.kind, kind, "\(result)")
            XCTAssertEqual(sent.message, message, "\(result)")
            XCTAssertEqual(sent.playerID, "guest")
            XCTAssertEqual(sent.tick, 9)
        }
        // Every refusal is a sentence a player can read whole in chat.
        for text in [LANTemplateRefusal.notAllowed, LANTemplateRefusal.cannotBuild, LANTemplateRefusal.dead,
                     LANTemplateRefusal.unavailable, LANTemplateRefusal.busy, LANTemplateRefusal.otherDimension,
                     LANTemplateRefusal.missingTemplate, LANTemplateRefusal.outOfReach,
                     LANTemplateRefusal.nothingToUndo, LANTemplateRefusal.undoOtherDimension,
                     LANTemplateRefusal.undoNotLoaded] {
            XCTAssertEqual(sanitizedLANChatText(text), text)
            XCTAssertTrue(text.hasSuffix("."), text)
        }
    }

    func testTemplateIntentsHaveTheirOwnRateLimit() {
        XCTAssertEqual(lanMultiplayerHostRateLimitCategory(for: .templateIntent), .templateIntent)
        XCTAssertNotEqual(lanMultiplayerHostRateLimitCategory(for: .blockIntent), .templateIntent)
    }
}
