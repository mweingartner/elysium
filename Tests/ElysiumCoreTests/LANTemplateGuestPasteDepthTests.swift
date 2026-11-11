import XCTest
@testable import ElysiumCore

/// Deeper checks of a LAN guest's template paste (`LANTemplateTransfer.swift`,
/// `LANMultiplayerHostSession.applyTemplateIntent`): seeded property and fuzz runs over the
/// payload codec and the intent's JSON, the host's placement against the guest's own preview for
/// every rotation, the host's progress reports, and what non-container block entities bring.
/// Every generator is seeded; a failure message names the seed so it replays.
final class LANTemplateGuestPasteDepthTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        registerAllBlocks()
        registerAllItems()
    }

    // MARK: - fixtures

    /// SplitMix64: small, fast and the same on every machine.
    private struct Seeded {
        var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ range: Range<Int>) -> Int {
            range.lowerBound + Int(next() % UInt64(range.count))
        }
        mutating func int(_ range: ClosedRange<Int>) -> Int { int(range.lowerBound..<(range.upperBound + 1)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
        mutating func pick<T>(_ values: [T]) -> T { values[int(0..<values.count)] }
        mutating func bytes(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8(truncatingIfNeeded: next()) }) }
    }

    private func loadedWorld(groundY: Int = 63) -> World {
        let world = World(dim: .overworld, seed: 42)
        let chunk = Chunk(cx: 0, cz: 0, minY: world.info.minY, height: world.info.height)
        for z in 0..<CHUNK_W {
            for x in 0..<CHUNK_W {
                chunk.set(x, groundY, z, cell(B.dirt, 0))
            }
        }
        chunk.status = .generated
        world.setChunk(chunk)
        return world
    }

    private func playerState(x: Double, y: Double, z: Double, health: Double = 20) -> LANPlayerState {
        LANPlayerState(playerID: "guest", displayName: "Alex", x: x, y: y, z: z, yaw: 0, pitch: 0,
                       health: health, hunger: 20, selectedHotbarSlot: 0, gameMode: GameMode.survival)
    }

    private func hostSession(x: Double = 8.5, y: Double = 64, z: Double = 1.5) -> LANMultiplayerHostSession {
        let session = LANMultiplayerHostSession()
        session.acceptPeer(playerID: "guest", displayName: "Alex")
        session.updatePlayerState(playerState(x: x, y: y, z: z))
        session.letPasteForFree("guest")
        return session
    }

    private func box(named name: String, sizeX: Int, sizeY: Int, sizeZ: Int) -> ObjectTemplate {
        var blocks: [TemplateBlock] = []
        for y in 0..<sizeY {
            for z in 0..<sizeZ {
                for x in 0..<sizeX {
                    blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: UInt16(cell(B.oak_planks, 0))))
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

    /// Blocks that neither fall, flow nor react to their neighbours, and that the skill tree
    /// does not mark, so a placed cell equals the template's cell.
    private var palette: [UInt16] {
        [B.oak_planks, B.bricks, B.glass, B.dark_oak_planks, B.mossy_stone_bricks]
    }

    private func randomName(_ rng: inout Seeded) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        var name = String(rng.pick(letters))
        for _ in 0..<rng.int(0..<20) { name.append(rng.chance(0.15) ? " " : rng.pick(letters)) }
        return name
    }

    /// A valid template: sparse blocks with any metadata, an anchor anywhere (it is never
    /// bounds-checked), and sometimes signs carrying text.
    private func randomTemplate(_ rng: inout Seeded, maxSpan: Int = 8) -> ObjectTemplate {
        let sx = rng.int(1...maxSpan), sy = rng.int(1...maxSpan), sz = rng.int(1...maxSpan)
        var blocks: [TemplateBlock] = []
        var signs: [BlockEntityData] = []
        for y in 0..<sy {
            for z in 0..<sz {
                for x in 0..<sx where rng.chance(0.35) {
                    if rng.chance(0.05) {
                        blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: UInt16(cell(bid("oak_sign"), rng.int(0..<16)))))
                        let sign = makeSignBE(x, y, z)
                        sign.lines = (0..<4).map { _ in String(repeating: "x", count: rng.int(0..<12)) }
                        signs.append(sign)
                    } else {
                        blocks.append(TemplateBlock(dx: x, dy: y, dz: z,
                                                    cell: UInt16(cell(rng.pick(palette), rng.int(0..<16)))))
                    }
                }
            }
        }
        if blocks.isEmpty {
            blocks.append(TemplateBlock(dx: 0, dy: 0, dz: 0, cell: UInt16(cell(B.bricks, 0))))
        }
        return ObjectTemplate(name: randomName(&rng),
                              anchorX: rng.int(-4..<(sx + 4)), anchorY: rng.int(-4..<(sy + 4)), anchorZ: rng.int(-4..<(sz + 4)),
                              sizeX: sx, sizeY: sy, sizeZ: sz, blocks: blocks, blockEntities: signs)
    }

    private func sortedBlocks(_ blocks: [TemplateBlock]) -> [TemplateBlock] {
        blocks.sorted { ($0.dy, $0.dz, $0.dx) < ($1.dy, $1.dz, $1.dx) }
    }

    private func u32(_ data: Data, at offset: Int) -> Int {
        (0..<4).reduce(0) { $0 | (Int(data[data.startIndex + offset + $1]) << (8 * $1)) }
    }

    /// A template as sorted-key JSON after the host's own validation: one text per template,
    /// whatever order its blocks or its block entities' keys came in.
    private func canonical(_ template: ObjectTemplate) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try encoder.encode(try decodeObjectTemplate(try encodeObjectTemplate(template))), as: UTF8.self)
    }

    /// Steps the guest's job to its end; returns the reports and how many steps left it running.
    private func finish(_ session: LANMultiplayerHostSession, in world: World, budgetPerPeer: Int,
                        file: StaticString = #filePath, line: UInt = #line) -> (reports: [LANTemplateIntentResult], runningSteps: Int) {
        var running = 0
        var steps = 0
        while session.hasActiveTemplateJob(playerID: "guest") {
            session.stepTemplateJobs(in: world, budgetPerPeer: budgetPerPeer)
            steps += 1
            if session.hasActiveTemplateJob(playerID: "guest") { running += 1 }
            if steps > 100_000 {
                XCTFail("the template job did not finish", file: file, line: line)
                break
            }
        }
        return (session.drainTemplateIntentResponses().map(\.result), running)
    }

    // MARK: - codec properties

    func testPayloadRoundTripIsTheIdentityForRandomTemplates() throws {
        for seed in UInt64(1)...200 {
            var rng = Seeded(seed)
            let template = randomTemplate(&rng)
            let payload = try lanGuestTemplatePayload(for: template)
            let decoded = try lanHostTemplate(fromGuestPayload: payload)

            XCTAssertEqual(decoded.name, template.name, "seed \(seed)")
            XCTAssertEqual([decoded.anchorX, decoded.anchorY, decoded.anchorZ],
                           [template.anchorX, template.anchorY, template.anchorZ], "seed \(seed)")
            XCTAssertEqual([decoded.sizeX, decoded.sizeY, decoded.sizeZ],
                           [template.sizeX, template.sizeY, template.sizeZ], "seed \(seed)")
            XCTAssertEqual(decoded.blocks, sortedBlocks(template.blocks), "seed \(seed)")
            XCTAssertEqual(decoded.blockEntities.map(\.lines),
                           template.blockEntities.sorted { ($0.y, $0.z, $0.x) < ($1.y, $1.z, $1.x) }.map(\.lines),
                           "seed \(seed)")
            // Decoding then encoding again gives back the same header and blocks byte for byte,
            // and the same block entities. (Their JSON keys come out in no fixed order:
            // `encodeObjectTemplate` does not sort them, so only the canonical form is compared.)
            let again = try encodeObjectTemplate(decoded)
            let jsonLength = u32(payload, at: 36)
            XCTAssertEqual(again.count, payload.count, "seed \(seed)")
            XCTAssertEqual(again.prefix(payload.count - jsonLength), payload.prefix(payload.count - jsonLength), "seed \(seed)")
            XCTAssertEqual(try canonical(try decodeObjectTemplate(again)), try canonical(template), "seed \(seed)")

            // The intent carrying it survives JSON unchanged, whatever the rotation.
            let intent = LANTemplateIntent(action: .placeTemplate, templateName: template.name,
                                           x: rng.int(-40_000_000...40_000_000), y: rng.int(-100...400),
                                           z: rng.int(-40_000_000...40_000_000), rotation: rng.int(-9...9),
                                           templateData: payload)
            let json = try JSONEncoder().encode(intent)
            XCTAssertEqual(try JSONDecoder().decode(LANTemplateIntent.self, from: json), intent, "seed \(seed)")
            XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("\\/"),
                           "seed \(seed): the wire text must not need JSON escapes")
        }
    }

    /// The header layout `encodeObjectTemplate` writes: the block-entity count and byte length
    /// are the last two header fields, and the block-entity JSON closes the payload.
    private func payload(_ base: Data, replacingBlockEntityJSON json: Data, count: Int) -> Data {
        var out = Data(base.prefix(base.count - u32(base, at: 36)))
        for (offset, value) in [(32, count), (36, json.count)] {
            for i in 0..<4 { out[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
        }
        out.append(json)
        return out
    }

    /// A template whose block entities exercise every branch of the host's emptying: a chest
    /// and a lit furnace with items, a sign, and a jukebox with a disc.
    private func stocked() -> ObjectTemplate {
        let cells: [UInt16] = [cell(B.chest, 2), cell(B.furnace_lit, 3), cell(bid("oak_sign"), 0), cell(B.jukebox, 0)]
        let chest = BlockEntityData(type: "chest", x: 0, y: 0, z: 0)
        chest.items = Array(repeating: nil, count: 27)
        chest.items?[3] = ItemStack(iid("diamond"), 64)
        let furnace = BlockEntityData(type: "furnace", x: 1, y: 0, z: 0)
        furnace.items = [ItemStack(iid("iron_ore"), 8), ItemStack(iid("coal"), 8), nil]
        furnace.burnTime = 90
        let sign = makeSignBE(2, 0, 0)
        sign.lines = ["a", "b", "c", "d"]
        let jukebox = BlockEntityData(type: "jukebox", x: 3, y: 0, z: 0)
        jukebox.disc = ItemStack(iid("music_disc_wander"), 1)
        return ObjectTemplate(name: "Stocked", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 4, sizeY: 1, sizeZ: 1,
                              blocks: cells.enumerated().map { TemplateBlock(dx: $0.offset, dy: 0, dz: 0, cell: $0.element) },
                              blockEntities: [chest, furnace, sign, jukebox])
    }

    /// What every template the host accepts from a guest must satisfy.
    private func assertAcceptable(_ template: ObjectTemplate, _ context: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNoThrow(try TemplatePlacementSession(template: template),
                         "\(context): the host accepted a template its own validation rejects", file: file, line: line)
        XCTAssertNoThrow(try encodeObjectTemplate(template), "\(context)", file: file, line: line)
        let lit: Set<Int> = [Int(B.furnace_lit), Int(B.blast_furnace_lit), Int(B.smoker_lit)]
        for be in template.blockEntities where be.items != nil {
            XCTAssertTrue(be.items?.allSatisfy { $0 == nil } ?? true,
                          "\(context): a container arrived with items", file: file, line: line)
            if let block = template.blocks.first(where: { $0.dx == be.x && $0.dy == be.y && $0.dz == be.z }) {
                XCTAssertFalse(lit.contains(Int(block.cell >> 4)),
                               "\(context): an emptied furnace stayed lit", file: file, line: line)
            }
        }
    }

    /// The host's verdict on a payload, in a form two runs can be compared by.
    private func verdict(_ data: Data) -> String {
        do {
            return "ok " + (try canonical(try lanHostTemplate(fromGuestPayload: data)))
        } catch {
            return "refused \(error)"
        }
    }

    func testMutatedPayloadsAreRefusedOrYieldAnAcceptableEmptiedTemplate() throws {
        // Trap review before fuzzing: the binary reader bounds every read against `data.count`,
        // the header's counts are capped before any multiplication, and every payload here is a
        // fresh `Data` whose indices start at zero (as `Data(base64Encoded:)` always gives the host).
        let base = try lanGuestTemplatePayload(for: stocked())
        assertAcceptable(try lanHostTemplate(fromGuestPayload: base), "unmutated")
        let jsonLength = u32(base, at: 36)
        XCTAssertGreaterThan(jsonLength, 100, "the fixture must carry block-entity JSON to mutate")
        var accepted = 0
        for seed in UInt64(1)...600 {
            var rng = Seeded(seed &* 7919)
            var data = base
            switch seed % 6 {
            case 0: // flip a few bytes anywhere after the magic
                for _ in 0..<rng.int(1...4) { data[rng.int(4..<data.count)] ^= UInt8(rng.int(1...255)) }
            case 1: // truncate or extend
                data = rng.chance(0.5) ? Data(data.prefix(rng.int(0..<data.count)))
                                       : data + rng.bytes(rng.int(1...64))
            case 2: // a header field set to anything
                let offset = rng.pick([4, 6, 8, 10, 14, 18, 22, 24, 26, 28, 32, 36])
                for i in 0..<2 { data[offset + i] = UInt8(truncatingIfNeeded: rng.next()) }
            case 3: // printable noise inside the block-entity JSON, length kept
                let json = (data.count - jsonLength)..<data.count
                for _ in 0..<rng.int(1...6) {
                    data[rng.int(json)] = rng.pick(Array("{}[],:\"0123456789-ntrufal ".utf8))
                }
            default: // well-formed JSON with hostile values, header kept consistent
                var entities: [BlockEntityData] = []
                for _ in 0..<rng.int(0...6) {
                    let be = BlockEntityData(type: rng.pick(["chest", "furnace", "hopper", "brewing", "shelf", "campfire",
                                                             "sign", "jukebox", "brushable", "", "x"]),
                                             x: rng.int(-2...5), y: rng.int(-1...1), z: rng.int(-1...1))
                    if rng.chance(0.7) {
                        be.items = (0..<rng.int(0...40)).map { _ in
                            rng.chance(0.4) ? nil : ItemStack(rng.int(-5...(itemDefs.count + 5)), rng.int(-3...500))
                        }
                    }
                    if rng.chance(0.3) { be.disc = ItemStack(rng.int(-5...(itemDefs.count + 5)), rng.int(-3...99)) }
                    if rng.chance(0.3) { be.item = ItemStack(iid("diamond"), rng.int(1...999)) }
                    if rng.chance(0.3) { be.burnTime = rng.int(-9...99_999); be.cookTotal = nil }
                    if rng.chance(0.3) { be.lootTable = "chests/x"; be.lootSeed = rng.int(0...9) }
                    entities.append(be)
                }
                let json = try JSONEncoder().encode(entities)
                data = payload(base, replacingBlockEntityJSON: json,
                               count: rng.chance(0.9) ? entities.count : rng.int(0...9))
            }
            let first = verdict(data)
            XCTAssertEqual(verdict(data), first, "seed \(seed): the host's answer must not depend on when it asks")
            if let template = try? lanHostTemplate(fromGuestPayload: data) {
                accepted += 1
                assertAcceptable(template, "seed \(seed) payload \(data.base64EncodedString())")
            }
        }
        // The run must have exercised both answers, or it proves nothing about either.
        XCTAssertGreaterThan(accepted, 20)
        XCTAssertLessThan(accepted, 600)
    }

    func testRandomIntentJSONNeverYieldsAnIntentOutsideItsLimits() throws {
        let validPayload = try lanGuestTemplatePayload(for: box(named: "Small", sizeX: 2, sizeY: 1, sizeZ: 1))
        var decodedCount = 0
        for seed in UInt64(1)...800 {
            var rng = Seeded(seed &* 104_729)
            func number() -> Any {
                rng.chance(0.85)
                    ? rng.pick([Int.min, Int.max, 0, -1, 4, -30_000_001, 30_000_001, rng.int(-99_999...99_999)])
                    : rng.pick(["7", 1.5, NSNull(), true] as [Any])
            }
            var object: [String: Any] = [:]
            if rng.chance(0.97) {
                object["action"] = rng.chance(0.85)
                    ? rng.pick(["placeTemplate", "undoPlacement"])
                    : rng.pick(["copyTarget", "", "PLACETEMPLATE", 3] as [Any])
            }
            if rng.chance(0.8) {
                object["templateName"] = rng.pick(["Hut", "", "  spaced  name ", "tab\tnew\nline", "§cred",
                                                   String(repeating: "é", count: 300), "a/b\\c\"d", "\u{0}\u{7}"])
            }
            for key in ["x", "y", "z", "rotation"] where rng.chance(0.97) { object[key] = number() }
            if rng.chance(0.85) {
                let bytes = rng.chance(0.5) ? validPayload : rng.bytes(rng.int(0...300))
                let standard = bytes.base64EncodedString()
                object["templateData"] = rng.pick([
                    lanTemplateWireText(bytes), standard, String(standard.dropLast()), "not base64 !", "",
                    String(repeating: "A", count: 960_004), NSNull(), 12,
                ] as [Any])
            }
            let json = try JSONSerialization.data(withJSONObject: object)
            guard let intent = try? JSONDecoder().decode(LANTemplateIntent.self, from: json) else { continue }
            decodedCount += 1
            let context = "seed \(seed) json \(String(decoding: json.prefix(400), as: UTF8.self))"
            XCTAssertTrue((0..<4).contains(intent.rotation), context)
            XCTAssertTrue([intent.x, intent.y, intent.z].allSatisfy { abs($0) <= 30_000_000 }, context)
            XCTAssertEqual(intent.templateName, sanitizedLANTemplateName(intent.templateName), context)
            if let data = intent.templateData {
                XCTAssertEqual(intent.action, .placeTemplate, context)
                XCTAssertLessThanOrEqual(data.count, LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES, context)
            }
            // What the host decoded, it would send on unchanged.
            XCTAssertEqual(try JSONDecoder().decode(LANTemplateIntent.self, from: try JSONEncoder().encode(intent)),
                           intent, context)
        }
        XCTAssertGreaterThan(decodedCount, 50, "the generator must reach the decoder's success path")

        // Raw noise and byte-flipped real intents never trap the decoder.
        let real = try JSONEncoder().encode(LANTemplateIntent(action: .placeTemplate, templateName: "Hut", x: 1, y: 2, z: 3,
                                                              rotation: 1, templateData: validPayload))
        for seed in UInt64(1)...300 {
            var rng = Seeded(seed)
            var data = seed % 2 == 0 ? rng.bytes(rng.int(0...200)) : real
            if seed % 2 == 1 {
                for _ in 0..<rng.int(1...3) { data[rng.int(0..<data.count)] = UInt8(truncatingIfNeeded: rng.next()) }
            }
            if let intent = try? JSONDecoder().decode(LANTemplateIntent.self, from: data) {
                XCTAssertTrue((0..<4).contains(intent.rotation), "seed \(seed)")
                XCTAssertTrue(intent.templateData.map { $0.count <= LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES } ?? true)
            }
        }
    }

    func testWireTextAcceptsExactlyTheLargestPayloadAndNoMore() throws {
        let largest = Data(repeating: 0xFB, count: LAN_MULTIPLAYER_MAX_TEMPLATE_PAYLOAD_BYTES)
        let text = lanTemplateWireText(largest)
        XCTAssertEqual(text.utf8.count, 960_000)
        XCTAssertFalse(text.contains("+") || text.contains("/"), "the wire text uses the URL-safe alphabet")
        XCTAssertEqual(lanTemplateData(fromWireText: text), largest)
        // One byte more no longer fits the text limit.
        XCTAssertNil(lanTemplateData(fromWireText: lanTemplateWireText(largest + Data([1]))))
        // A wire text in the standard alphabet still decodes: the host does not care which.
        XCTAssertEqual(lanTemplateData(fromWireText: Data([0xFB, 0xFF]).base64EncodedString()), Data([0xFB, 0xFF]))
    }

    // MARK: - rotation: the host places what the guest's preview shows

    func testHostPlacementMatchesTheGuestsPreviewForRandomTemplatesAnchorsAndRotations() throws {
        for seed in UInt64(1)...60 {
            var rng = Seeded(seed &* 31)
            var template = randomTemplate(&rng, maxSpan: 6)
            template.blockEntities = [] // signs need support; this property is about where blocks land
            template.blocks = template.blocks.map {
                TemplateBlock(dx: $0.dx, dy: $0.dy, dz: $0.dz, cell: UInt16(cell(rng.pick(palette), Int($0.cell & 15))))
            }
            let rotation = Int(seed % 4)
            let preview = try TemplatePlacementSession(template: template, rotationSteps: rotation).rotatedTemplate
            let origin = (x: rng.int(0...(CHUNK_W - preview.sizeX)), y: 64, z: rng.int(0...(CHUNK_W - preview.sizeZ)))
            let world = loadedWorld()
            let session = hostSession(x: Double(origin.x) + 0.5, y: 64, z: Double(origin.z) + 0.5)
            let intent = try placeIntent(template, x: origin.x + preview.anchorX, y: origin.y + preview.anchorY,
                                         z: origin.z + preview.anchorZ, rotation: rotation)

            XCTAssertEqual(session.applyTemplateIntent(intent, from: "guest", world: world),
                           .accepted(action: .placeTemplate, name: template.name), "seed \(seed)")
            XCTAssertEqual(finish(session, in: world, budgetPerPeer: LAN_MULTIPLAYER_TEMPLATE_JOB_STEP_BUDGET).reports.last,
                           .placed(name: template.name, blocks: template.blocks.count, blockEntities: 0, cleared: 0, filled: 0),
                           "seed \(seed)")

            var expected: [Int: Int] = [:]
            func key(_ x: Int, _ y: Int, _ z: Int) -> Int { (y * 64 + z) * 64 + x }
            for block in preview.blocks { expected[key(block.dx, block.dy, block.dz)] = Int(block.cell) }
            for dy in 0..<preview.sizeY {
                for dz in 0..<preview.sizeZ {
                    for dx in 0..<preview.sizeX {
                        XCTAssertEqual(world.getBlock(origin.x + dx, origin.y + dy, origin.z + dz),
                                       expected[key(dx, dy, dz)] ?? 0,
                                       "seed \(seed) rotation \(rotation) anchor \(template.anchorX),\(template.anchorY),\(template.anchorZ) cell \(dx),\(dy),\(dz)")
                    }
                }
            }
        }
    }

    // MARK: - host: progress reports

    func testProgressIsReportedOnceEveryThirtyRunningStepsAndNeverAfterCompletion() throws {
        let world = loadedWorld()
        let session = hostSession()
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(box(named: "Hall", sizeX: 6, sizeY: 4, sizeZ: 6), x: 5, y: 64, z: 6),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Hall"))

        let (reports, running) = finish(session, in: world, budgetPerPeer: 1)

        // 144 blocks to place and 144 cells to notify, one a step.
        XCTAssertEqual(running, 288)
        XCTAssertEqual(reports.count, running / LAN_MULTIPLAYER_TEMPLATE_PROGRESS_REPORT_STEPS + 1)
        XCTAssertEqual(reports.last, .placed(name: "Hall", blocks: 144, blockEntities: 0, cleared: 0, filled: 0))
        XCTAssertEqual(reports.first, .progress(action: .placeTemplate, name: "Hall", percent: 10, phase: "placing blocks"))
        XCTAssertEqual(reports.dropLast().last,
                       .progress(action: .placeTemplate, name: "Hall", percent: 93, phase: "updating neighbors"))
        XCTAssertTrue(session.drainTemplateIntentResponses().isEmpty)
        session.stepTemplateJobs(in: world, budgetPerPeer: 1)
        XCTAssertTrue(session.drainTemplateIntentResponses().isEmpty, "a finished job reports nothing more")
    }

    func testAnUndoJobReportsItsOwnProgressBeforeItsCompletion() throws {
        let world = loadedWorld()
        let session = hostSession()
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(box(named: "Hall", sizeX: 6, sizeY: 4, sizeZ: 6), x: 5, y: 64, z: 6),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Hall"))
        _ = finish(session, in: world, budgetPerPeer: LAN_MULTIPLAYER_TEMPLATE_JOB_STEP_BUDGET)

        XCTAssertEqual(session.applyTemplateIntent(undoIntent, from: "guest", world: world),
                       .accepted(action: .undoPlacement, name: "Hall"))
        let (reports, running) = finish(session, in: world, budgetPerPeer: 4)

        // 144 cells to restore and 144 to notify, four a step.
        XCTAssertEqual(running, 72)
        XCTAssertEqual(reports, [
            .progress(action: .undoPlacement, name: "Hall", percent: 41, phase: "restoring"),
            .progress(action: .undoPlacement, name: "Hall", percent: 83, phase: "updating neighbors"),
            .undone(name: "Hall", restored: 144),
        ])
        XCTAssertEqual(lanTemplateGameplayEvent(for: reports[0], playerID: "guest", tick: 1).message,
                       "Undoing \"Hall\" 41% - restoring")
    }

    func testAJobPausedInAnotherDimensionNeitherReportsNorCountsTowardItsNextReport() throws {
        let world = loadedWorld()
        let session = hostSession()
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(box(named: "Hall", sizeX: 6, sizeY: 4, sizeZ: 6), x: 5, y: 64, z: 6),
                                                   from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Hall"))
        for _ in 0..<(LAN_MULTIPLAYER_TEMPLATE_PROGRESS_REPORT_STEPS - 1) { session.stepTemplateJobs(in: world, budgetPerPeer: 1) }
        XCTAssertTrue(session.drainTemplateIntentResponses().isEmpty)

        let nether = World(dim: .nether, seed: 42)
        for _ in 0..<200 { session.stepTemplateJobs(in: nether, budgetPerPeer: 1) }
        XCTAssertTrue(session.drainTemplateIntentResponses().isEmpty, "a paused job has nothing to report")
        XCTAssertTrue(session.hasActiveTemplateJob(playerID: "guest"))

        session.stepTemplateJobs(in: world, budgetPerPeer: 1)
        XCTAssertEqual(session.drainTemplateIntentResponses().map(\.result),
                       [.progress(action: .placeTemplate, name: "Hall", percent: 10, phase: "placing blocks")],
                       "the thirtieth step that ran, not the thirtieth call, reports")
        _ = finish(session, in: world, budgetPerPeer: LAN_MULTIPLAYER_TEMPLATE_JOB_STEP_BUDGET)
    }

    func testAPeerThatLeavesMidJobTakesItsQueuedReportsWithIt() throws {
        for leave in ["disconnect", "remove"] {
            let world = loadedWorld()
            let session = hostSession()
            session.acceptPeer(playerID: "other", displayName: "Blair")
            XCTAssertEqual(session.applyTemplateIntent(try placeIntent(box(named: "Hall", sizeX: 6, sizeY: 4, sizeZ: 6), x: 5, y: 64, z: 6),
                                                       from: "guest", world: world),
                           .accepted(action: .placeTemplate, name: "Hall"))
            for _ in 0..<LAN_MULTIPLAYER_TEMPLATE_PROGRESS_REPORT_STEPS { session.stepTemplateJobs(in: world, budgetPerPeer: 1) }

            if leave == "disconnect" {
                session.disconnectPeer(playerID: "guest", tick: 5)
            } else {
                session.removePeer(playerID: "guest")
            }

            XCTAssertFalse(session.hasActiveTemplateJob(playerID: "guest"), leave)
            XCTAssertTrue(session.drainTemplateIntentResponses().isEmpty,
                          "\(leave): a report queued for a guest who left must not go to anyone")
            // What the job already wrote stays: the host's world is real.
            XCTAssertEqual(world.getBlock(5, 64, 6), Int(cell(B.oak_planks, 0)), leave)
        }
    }

    // MARK: - host: permission and life are checked at admission

    func testWithdrawingPermissionDoesNotStopAJobAlreadyAdmitted() throws {
        let world = loadedWorld()
        let session = hostSession()
        let hut = box(named: "Hut", sizeX: 2, sizeY: 2, sizeZ: 2)
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(hut, x: 5, y: 64, z: 6), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Hut"))
        session.setPermissions(LANPeerPermissions(canBuild: false, canUseTemplates: false), for: "guest")

        XCTAssertEqual(finish(session, in: world, budgetPerPeer: 1).reports.last,
                       .placed(name: "Hut", blocks: 8, blockEntities: 0, cleared: 0, filled: 0),
                       "permission is checked once, at admission")
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(hut, x: 9, y: 64, z: 6), from: "guest", world: world),
                       .rejected(LANTemplateRefusal.notAllowed))
        XCTAssertEqual(session.applyTemplateIntent(undoIntent, from: "guest", world: world),
                       .rejected(LANTemplateRefusal.notAllowed))
    }

    func testADeadGuestIsToldSoForAPasteAndAnUndo() throws {
        let world = loadedWorld()
        let session = hostSession()
        let hut = box(named: "Hut", sizeX: 1, sizeY: 1, sizeZ: 1)
        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(hut, x: 5, y: 64, z: 6), from: "guest", world: world),
                       .accepted(action: .placeTemplate, name: "Hut"))
        _ = finish(session, in: world, budgetPerPeer: LAN_MULTIPLAYER_TEMPLATE_JOB_STEP_BUDGET)

        session.updatePlayerState(playerState(x: 8.5, y: 64, z: 1.5, health: 0))

        XCTAssertEqual(session.applyTemplateIntent(try placeIntent(hut, x: 6, y: 64, z: 6), from: "guest", world: world),
                       .rejected(LANTemplateRefusal.dead))
        XCTAssertEqual(session.applyTemplateIntent(undoIntent, from: "guest", world: world),
                       .rejected(LANTemplateRefusal.dead))
        XCTAssertEqual(world.getBlock(5, 64, 6), Int(cell(B.oak_planks, 0)), "a refused undo restores nothing")
    }

    // MARK: - non-functional

    func testDecodingTheLargestGuestPayloadStaysWellUnderASecond() throws {
        var blocks: [TemplateBlock] = []
        outer: for y in 0..<96 {
            for z in 0..<96 {
                for x in 0..<96 {
                    if blocks.count == 89_900 { break outer }
                    blocks.append(TemplateBlock(dx: x, dy: y, dz: z, cell: UInt16(cell(B.bricks, 0))))
                }
            }
        }
        let payload = try lanGuestTemplatePayload(for: ObjectTemplate(
            name: "Slab", anchorX: 0, anchorY: 0, anchorZ: 0, sizeX: 96, sizeY: 96, sizeZ: 96, blocks: blocks))
        let text = lanTemplateWireText(payload)

        var timings: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            let bytes = try XCTUnwrap(lanTemplateData(fromWireText: text))
            let template = try lanHostTemplate(fromGuestPayload: bytes)
            timings.append(Date().timeIntervalSince(start))
            XCTAssertEqual(template.blocks.count, 89_900)
        }
        let median = timings.sorted()[timings.count / 2]
        print("[LANTemplateGuestPasteDepthTests] wire text + decode of \(payload.count) bytes: median \(String(format: "%.1f", median * 1000)) ms")
        // A generous bound for a debug build: it catches a quadratic slip, not a slow machine.
        XCTAssertLessThan(median, 1.0)
    }
}
