import Darwin
import CryptoKit
import Foundation
import XCTest
@testable import Elysium
@testable import ElysiumCore

final class ResourcePackHardeningTests: XCTestCase {
    private func asymmetricPNG() throws -> Data {
        // Literal PNG scanlines, independent of Core Graphics: authored top is
        // red/green and authored bottom is blue/yellow (PNG filter byte 0).
        try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVR42mP4z8DwHwyBNBAw/AcAR8oI+FuapL4AAAAASUVORK5CYII="))
    }

    func testDecodePNGNormalizesVisualTopRowOnce() throws {
        let limits = ResourcePackPreparationLimits(
            archiveBytes: 512 << 20, fileBytes: 64 << 20, entries: 100_000,
            pathBytes: 1_024, aggregatePathBytes: 16 << 20,
            advertisedBytes: 512 << 20, inflatedBytes: 512 << 20,
            decodedRGBABytes: 16, metadataBytes: 64 << 10,
            framesPerTexture: 256, framesPerGeneration: 4_096,
            minimumFrameDuration: 1, maximumFrameDuration: 1_200)
        let exactBudget = ResourcePackPreparationBudget(limits: limits)
        let image = decodePNG(try asymmetricPNG(), budget: exactBudget)
        XCTAssertEqual(image?.width, 2)
        XCTAssertEqual(image?.height, 2)
        XCTAssertEqual(image?.pixels, [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 0, 255,
        ], "row zero must be authored red/green top; row one blue/yellow bottom")
        XCTAssertEqual(exactBudget.decodedRGBABytes, 16)

        var shortLimits = limits
        shortLimits.decodedRGBABytes = 15
        XCTAssertNil(decodePNG(try asymmetricPNG(),
                               budget: ResourcePackPreparationBudget(limits: shortLimits)))
        let token = ResourcePackCancellationToken()
        token.cancel()
        XCTAssertNil(decodePNG(try asymmetricPNG(),
                               budget: ResourcePackPreparationBudget(cancellation: token)))

        let alphaPNG = try XCTUnwrap(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNwaDjQAAAEhQIBHAk9JgAAAABJRU5ErkJggg=="))
        let alpha = try XCTUnwrap(decodePNG(alphaPNG))
        XCTAssertEqual(alpha.pixels[0], 63, accuracy: 1)
        XCTAssertEqual(alpha.pixels[1], 127, accuracy: 1)
        XCTAssertEqual(alpha.pixels[2], 191, accuracy: 1)
        XCTAssertEqual(alpha.pixels[3], 128)
    }

    func testRainbowAndHeldOverlayPlansClampAndStayDeterministic() throws {
        XCTAssertEqual(xpRainbowSegments(progress: -1, width: 182), [])
        XCTAssertEqual(xpRainbowSegments(progress: .nan, width: 182), [])
        let full = xpRainbowSegments(progress: 2, width: 182)
        XCTAssertEqual(full.map(\.color),
                       ["#ff4040", "#ff9b32", "#ffe84d", "#6eea58",
                        "#43d6c5", "#3978ff", "#9b70f5"])
        XCTAssertEqual(full.reduce(0) { $0 + $1.width }, 182)
        for boundary in 1...7 {
            let segments = xpRainbowSegments(progress: Double(boundary) / 7, width: 182)
            XCTAssertEqual(segments.count, boundary)
            XCTAssertEqual(segments.reduce(0) { $0 + $1.width },
                           (Double(boundary) * 182 / 7).rounded(), accuracy: 0.001)
        }

        XCTAssertNil(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                     hasMainHand: false, guiVisible: true,
                                     firstPerson: true, screenOpen: false,
                                     attack: 1, usingItem: true, useTicks: 30))
        XCTAssertNil(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                     hasMainHand: true, guiVisible: false,
                                     firstPerson: true, screenOpen: false,
                                     attack: 1, usingItem: true, useTicks: 30))
        XCTAssertNil(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                     hasMainHand: true, guiVisible: true,
                                     firstPerson: false, screenOpen: false,
                                     attack: 1, usingItem: true, useTicks: 30))
        XCTAssertNil(heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                     hasMainHand: true, guiVisible: true,
                                     firstPerson: true, screenOpen: true,
                                     attack: 1, usingItem: true, useTicks: 30))
        let idle = heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                   hasMainHand: true, guiVisible: true,
                                   firstPerson: true, screenOpen: false,
                                   attack: 0, usingItem: false, useTicks: 0)
        let use = heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                  hasMainHand: true, guiVisible: true,
                                  firstPerson: true, screenOpen: false,
                                  attack: 1, usingItem: true, useTicks: 99)
        XCTAssertEqual(idle, heldOverlayPlan(viewWidth: 320, viewHeight: 180,
                                              hasMainHand: true, guiVisible: true,
                                              firstPerson: true, screenOpen: false,
                                              attack: 0, usingItem: false, useTicks: 0))
        let unwrappedUse = try XCTUnwrap(use)
        XCTAssertLessThanOrEqual(unwrappedUse.swing, 1)
        XCTAssertLessThan(unwrappedUse.iconX, 320)
        XCTAssertLessThan(unwrappedUse.iconY, 180)
    }

    func testTemplateDeleteRequestCapturesNormalizedNameAndClaimsOnce() throws {
        var request = try XCTUnwrap(TemplateDeleteConfirmationRequest(rawName: "  Mixed  Name  "))
        XCTAssertEqual(request.displayName, "  Mixed  Name  ")
        XCTAssertEqual(request.storageKey, "mixed name")
        XCTAssertFalse(request.claimed)
        XCTAssertEqual(request.claim(), "mixed name")
        XCTAssertTrue(request.claimed)
        XCTAssertNil(request.claim(), "one confirmation cannot execute twice")
        XCTAssertNil(TemplateDeleteConfirmationRequest(rawName: "../not-a-template"))
    }
    /// Test-only AppKit interaction host. It deliberately reuses the two closed production IDs
    /// with a synthetic shared conflict group, so no conflicting descriptor or fault selector is
    /// introduced into Elysium.app. Settings/live tokens are spies for forbidden side effects.
    private struct SyntheticConflictHost {
        let interaction = ResourcePackScreenInteraction(catalog: [
            .init(id: .oreBorders64x, displayName: "Synthetic Ore", conflictGroup: "fixture"),
            .init(id: .staticLanterns, displayName: "Synthetic Lantern", conflictGroup: "fixture"),
        ])
        var selected: [BundledResourcePackAddOnID] = [.oreBorders64x]
        var settingsToken = 41
        var liveGenerationToken = 73
        var focused = BundledResourcePackAddOnID.staticLanterns
        var status: String?

        mutating func activateFocused() {
            switch interaction.evaluateToggle(selected: selected, requested: focused) {
            case .conflict(let requested, let active):
                status = "Cannot enable \(requested) while \(active) is active."
            case .ready(let candidate):
                selected = candidate
                settingsToken += 1
                liveGenerationToken += 1
            case .invalid:
                status = "Resource pack choice was not changed."
            }
        }

        mutating func consumeStatusAnnouncement() -> String? {
            defer { status = nil }
            return status
        }
    }

    private struct FixtureEntry {
        var name: String
        var bytes: Data
        var localName: String? = nil
        var flags: UInt16 = 0
        var method: UInt16 = 0
        var crcOverride: UInt32? = nil
        var externalAttributes: UInt32 = UInt32(S_IFREG | 0o600) << 16
        var centralExtra = Data()
        var localExtra = Data()
    }

    private func append16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xff)); data.append(UInt8(value >> 8))
    }

    private func append32(_ value: UInt32, to data: inout Data) {
        append16(UInt16(value & 0xffff), to: &data)
        append16(UInt16(value >> 16), to: &data)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb8_8320) }
        }
        return crc ^ 0xffff_ffff
    }

    private func zip(_ rows: [FixtureEntry], disk: UInt16 = 0) -> Data {
        var body = Data()
        var centralRows: [(FixtureEntry, UInt32, UInt32)] = []
        for row in rows {
            let offset = UInt32(body.count)
            let payloadCRC = row.crcOverride ?? crc32(row.bytes)
            let localName = Data((row.localName ?? row.name).utf8)
            append32(0x04034b50, to: &body)
            append16(20, to: &body); append16(row.flags, to: &body)
            append16(row.method, to: &body); append16(0, to: &body); append16(0, to: &body)
            append32(payloadCRC, to: &body)
            append32(UInt32(row.bytes.count), to: &body); append32(UInt32(row.bytes.count), to: &body)
            append16(UInt16(localName.count), to: &body); append16(UInt16(row.localExtra.count), to: &body)
            body.append(localName); body.append(row.localExtra); body.append(row.bytes)
            centralRows.append((row, offset, payloadCRC))
        }
        let centralStart = UInt32(body.count)
        var central = Data()
        for (row, offset, payloadCRC) in centralRows {
            let name = Data(row.name.utf8)
            append32(0x02014b50, to: &central)
            append16(UInt16((3 << 8) | 20), to: &central); append16(20, to: &central)
            append16(row.flags, to: &central); append16(row.method, to: &central)
            append16(0, to: &central); append16(0, to: &central); append32(payloadCRC, to: &central)
            append32(UInt32(row.bytes.count), to: &central); append32(UInt32(row.bytes.count), to: &central)
            append16(UInt16(name.count), to: &central); append16(UInt16(row.centralExtra.count), to: &central)
            append16(0, to: &central); append16(0, to: &central); append16(0, to: &central)
            append32(row.externalAttributes, to: &central); append32(offset, to: &central)
            central.append(name); central.append(row.centralExtra)
        }
        body.append(central)
        append32(0x06054b50, to: &body)
        append16(disk, to: &body); append16(disk, to: &body)
        append16(UInt16(rows.count), to: &body); append16(UInt16(rows.count), to: &body)
        append32(UInt32(central.count), to: &body); append32(centralStart, to: &body)
        append16(0, to: &body)
        return body
    }

    private func limits(path: Int = 1_024, aggregatePath: Int = 16 << 20,
                        advertised: Int = 512 << 20, inflated: Int = 512 << 20,
                        entries: Int = 100_000) -> ResourcePackPreparationLimits {
        var value = ResourcePackPreparationLimits.production
        value.pathBytes = path
        value.aggregatePathBytes = aggregatePath
        value.advertisedBytes = advertised
        value.inflatedBytes = inflated
        value.entries = entries
        return value
    }

    func testExactAndPlusOnePathAndByteBudgets() {
        let exactPath = zip([FixtureEntry(name: "12345678", bytes: Data([1, 2, 3, 4]))])
        XCTAssertNotNil(MiniZip(data: exactPath,
            budget: ResourcePackPreparationBudget(limits: limits(path: 8, aggregatePath: 8,
                                                                   advertised: 4, inflated: 4))))
        XCTAssertNil(MiniZip(data: exactPath,
            budget: ResourcePackPreparationBudget(limits: limits(path: 7, aggregatePath: 8,
                                                                   advertised: 4, inflated: 4))))
        XCTAssertNil(MiniZip(data: exactPath,
            budget: ResourcePackPreparationBudget(limits: limits(path: 8, aggregatePath: 7,
                                                                   advertised: 4, inflated: 4))))
        XCTAssertNil(MiniZip(data: exactPath,
            budget: ResourcePackPreparationBudget(limits: limits(path: 8, aggregatePath: 8,
                                                                   advertised: 3, inflated: 4))))
        XCTAssertNil(MiniZip(data: exactPath,
            budget: ResourcePackPreparationBudget(limits: limits(path: 8, aggregatePath: 8,
                                                                   advertised: 4, inflated: 3))))
    }

    func testCompleteStackAggregateAndDecodedMetadataAnimationBoundaries() {
        let first = zip([FixtureEntry(name: "aaaa", bytes: Data([1, 2, 3, 4]))])
        let second = zip([FixtureEntry(name: "bbbb", bytes: Data([5, 6, 7, 8]))])
        let exact = ResourcePackPreparationBudget(
            limits: limits(path: 4, aggregatePath: 8, advertised: 8, inflated: 8, entries: 2))
        XCTAssertNotNil(MiniZip(data: first, budget: exact))
        XCTAssertNotNil(MiniZip(data: second, budget: exact))
        XCTAssertEqual(exact.pathBytes, 8)
        XCTAssertEqual(exact.advertisedBytes, 8)
        XCTAssertEqual(exact.inflatedBytes, 8)

        let plusOne = ResourcePackPreparationBudget(
            limits: limits(path: 4, aggregatePath: 7, advertised: 8, inflated: 8, entries: 2))
        XCTAssertNotNil(MiniZip(data: first, budget: plusOne))
        XCTAssertNil(MiniZip(data: second, budget: plusOne))

        var tiny = ResourcePackPreparationLimits.production
        tiny.decodedRGBABytes = 16
        tiny.metadataBytes = 4
        tiny.framesPerTexture = 2
        tiny.framesPerGeneration = 2
        tiny.minimumFrameDuration = 1
        tiny.maximumFrameDuration = 3
        let work = ResourcePackPreparationBudget(limits: tiny)
        XCTAssertTrue(work.chargeDecodedRGBA(width: 2, height: 2))
        XCTAssertTrue(work.chargeMetadata(4))
        XCTAssertTrue(work.chargeAnimationFrames(2))
        XCTAssertTrue(work.validDuration(1))
        XCTAssertTrue(work.validDuration(3))
        XCTAssertFalse(work.chargeDecodedRGBA(width: 1, height: 1))

        let durationUnder = ResourcePackPreparationBudget(limits: tiny)
        XCTAssertFalse(durationUnder.validDuration(0))
        let durationOver = ResourcePackPreparationBudget(limits: tiny)
        XCTAssertFalse(durationOver.validDuration(4))
        let framesOver = ResourcePackPreparationBudget(limits: tiny)
        XCTAssertFalse(framesOver.chargeAnimationFrames(3))
        let metadataOver = ResourcePackPreparationBudget(limits: tiny)
        XCTAssertFalse(metadataOver.chargeMetadata(5))
    }

    func testAmbiguousAndUnsupportedArchivesFailClosed() {
        XCTAssertNil(MiniZip(data: zip([
            FixtureEntry(name: "A.png", bytes: Data([1])),
            FixtureEntry(name: "a.PNG", bytes: Data([2]))
        ])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "../a", bytes: Data())])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a\\b", bytes: Data())])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data([1]),
                                                    localName: "b")])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data([1]),
                                                    flags: 1)])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data([1]),
                                                    method: 99)])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data([1]),
                                                    crcOverride: 0)])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data(),
                                                    externalAttributes: UInt32(S_IFLNK | 0o777) << 16)])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data(),
                                                    centralExtra: Data([1, 0, 0, 0]))])))
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data())], disk: 1)))
    }

    func testCancellationRejectsPreparationBeforeAllocation() {
        let token = ResourcePackCancellationToken()
        token.cancel()
        let budget = ResourcePackPreparationBudget(cancellation: token)
        XCTAssertNil(MiniZip(data: zip([FixtureEntry(name: "a", bytes: Data([1]))]),
                             budget: budget))
        XCTAssertFalse(budget.shouldContinue)
    }

    func testFolderSnapshotRejectsSymlinkHardlinkAndAcceptsExactRegularFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-pack-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let valid = root.appendingPathComponent("valid", isDirectory: true)
        try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
        try Data(#"{"pack":{"pack_format":75,"description":"fixture"}}"#.utf8)
            .write(to: valid.appendingPathComponent("pack.mcmeta"))
        XCTAssertNotNil(ResourcePack(url: valid))

        let symlinked = root.appendingPathComponent("symlinked", isDirectory: true)
        try FileManager.default.copyItem(at: valid, to: symlinked)
        try FileManager.default.createSymbolicLink(
            at: symlinked.appendingPathComponent("escape.png"),
            withDestinationURL: valid.appendingPathComponent("pack.mcmeta"))
        XCTAssertNil(ResourcePack(url: symlinked))

        let hardlinked = root.appendingPathComponent("hardlinked", isDirectory: true)
        try FileManager.default.createDirectory(at: hardlinked, withIntermediateDirectories: true)
        XCTAssertEqual(link(valid.appendingPathComponent("pack.mcmeta").path,
                            hardlinked.appendingPathComponent("pack.mcmeta").path), 0)
        XCTAssertNil(ResourcePack(url: hardlinked))
    }

    func testReviewedArchivesMatchHashesAndParseAsOneBoundedStack() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let budget = ResourcePackPreparationBudget()
        var parsed: [ResourcePack] = []
        for asset in BUNDLED_RESOURCE_PACK_ASSETS {
            let bytes = try Data(contentsOf: repository.appendingPathComponent("packaging")
                .appendingPathComponent(asset.fileName))
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, asset.sha256, asset.fileName)
            let pack = try XCTUnwrap(ResourcePack(data: bytes, fileName: asset.fileName,
                                                  budget: budget), asset.fileName)
            for path in asset.requiredPaths { XCTAssertNotNil(pack.file(path), "\(asset.fileName): \(path)") }
            parsed.append(pack)
        }
        XCTAssertEqual(parsed.count, 3)
        XCTAssertNotNil(buildPackAtlas(packs: parsed, budget: budget))
        XCTAssertTrue(budget.isValid)
        XCTAssertLessThanOrEqual(budget.pathBytes, budget.limits.aggregatePathBytes)
        XCTAssertLessThanOrEqual(budget.inflatedBytes, budget.limits.inflatedBytes)
    }

    func testShippedCatalogDefaultsOffAndSupportsIndependentAndCombinedSelection() {
        let interaction = ResourcePackScreenInteraction()
        var selected: [BundledResourcePackAddOnID] = []
        let shippedGroups = BUNDLED_RESOURCE_PACK_ADD_ONS.compactMap(\.conflictGroup)
        XCTAssertEqual(shippedGroups.count, Set(shippedGroups).count,
                       "the shipped catalog must contain no active conflict pair")
        XCTAssertEqual(selected, [], "the optional catalog must begin OFF")

        guard case .ready(let oreOnly) = interaction.evaluateToggle(
            selected: selected, requested: .oreBorders64x) else {
            return XCTFail("Ore Borders must toggle independently")
        }
        selected = oreOnly
        XCTAssertEqual(selected, [.oreBorders64x])

        guard case .ready(let both) = interaction.evaluateToggle(
            selected: selected, requested: .staticLanterns) else {
            return XCTFail("the two shipped add-ons must be independently compatible")
        }
        selected = both
        XCTAssertEqual(selected, [.oreBorders64x, .staticLanterns])

        guard case .ready(let lanternOnly) = interaction.evaluateToggle(
            selected: selected, requested: .oreBorders64x) else {
            return XCTFail("Ore Borders must toggle back OFF without changing Static Lanterns")
        }
        XCTAssertEqual(lanternOnly, [.staticLanterns])
    }

    @MainActor
    func testPresentationNoticeIsFallbackOnlySerialAwareAndOneShot() {
        let original = RESOURCE_PACK_PRESENTATION
        defer { RESOURCE_PACK_PRESENTATION = original }
        let approved = "Faithful 64x is unavailable; built-in fallback active."

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 0, pendingNotice: approved)
        XCTAssertNil(consumeResourcePackPresentationNotice())

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .faithful64x(activeAddOns: []), noticeSerial: 41_000,
            pendingNotice: approved)
        XCTAssertNil(consumeResourcePackPresentationNotice())

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 41_000, pendingNotice: approved)
        XCTAssertEqual(consumeResourcePackPresentationNotice(), approved)
        XCTAssertNil(consumeResourcePackPresentationNotice(), "one serial announces once")

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .faithful64x(activeAddOns: [.oreBorders64x]),
            noticeSerial: 41_000)
        XCTAssertNil(consumeResourcePackPresentationNotice())

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 41_001, pendingNotice: "later fallback")
        XCTAssertNil(consumeResourcePackPresentationNotice())
        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 41_001, pendingNotice: approved)
        XCTAssertEqual(consumeResourcePackPresentationNotice(), approved,
                       "a rejected message must not consume the serial")
        XCTAssertNil(consumeResourcePackPresentationNotice())

        for serial in [UInt64.max, 1, 2] {
            RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
                generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
                noticeSerial: serial, pendingNotice: approved)
            XCTAssertEqual(consumeResourcePackPresentationNotice(), approved)
            XCTAssertNil(consumeResourcePackPresentationNotice())
        }

        for (serial, notice) in [(UInt64(3), ""), (4, "   "), (5, "unexpected fallback")] {
            RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
                generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
                noticeSerial: serial, pendingNotice: notice)
            XCTAssertNil(consumeResourcePackPresentationNotice())
        }

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Other pack"),
            noticeSerial: 6, pendingNotice: approved)
        XCTAssertNil(consumeResourcePackPresentationNotice())

        RESOURCE_PACK_PRESENTATION = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 7, pendingNotice: nil)
        XCTAssertNil(consumeResourcePackPresentationNotice())
    }

    func testPresentationPublicationTransitionsPreserveAdvanceAndClearExactly() {
        let pending = ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: UInt64.max,
            pendingNotice: "Faithful 64x is unavailable; built-in fallback active.")

        let active = resourcePackPresentationAfterActivePublication(
            pending, activeAddOns: [.staticLanterns])
        XCTAssertEqual(active, ResourcePackPresentationSnapshot(
            generation: .faithful64x(activeAddOns: [.staticLanterns]),
            noticeSerial: UInt64.max))
        XCTAssertNil(active.pendingNotice, "active publication clears the transient notice")

        let wrapped = resourcePackPresentationAfterFallbackPublication(pending)
        XCTAssertEqual(wrapped, ResourcePackPresentationSnapshot(
            generation: .proceduralFallback(failedPackDisplayName: "Faithful 64x"),
            noticeSerial: 1,
            pendingNotice: "Faithful 64x is unavailable; built-in fallback active."))
        let advanced = resourcePackPresentationAfterFallbackPublication(wrapped)
        XCTAssertEqual(advanced.noticeSerial, 2)
        XCTAssertEqual(advanced.pendingNotice,
                       "Faithful 64x is unavailable; built-in fallback active.")
    }

    func testSyntheticConflictFixtureNamesBothAndHasNoSettingsOrLiveSideEffects() {
        var host = SyntheticConflictHost()
        let beforeSelection = host.selected
        let beforeSettings = host.settingsToken
        let beforeLive = host.liveGenerationToken
        let beforeFocus = host.focused

        host.activateFocused()

        XCTAssertEqual(host.selected, beforeSelection)
        XCTAssertEqual(host.settingsToken, beforeSettings)
        XCTAssertEqual(host.liveGenerationToken, beforeLive)
        XCTAssertEqual(host.focused, beforeFocus)
        XCTAssertEqual(host.consumeStatusAnnouncement(),
                       "Cannot enable Synthetic Lantern while Synthetic Ore is active.")
        XCTAssertNil(host.consumeStatusAnnouncement(), "conflict status announces exactly once")
        XCTAssertEqual(BUNDLED_RESOURCE_PACK_ADD_ONS.map(\.conflictGroup),
                       ["ore-appearance", "sea-lantern-animation"],
                       "the signed catalog must not contain the synthetic conflict group")
    }

    func testCancelledWorkerRetainsLeaseUntilDrainAndRejectsReplacement() {
        let started = DispatchSemaphore(value: 0)
        let drain = DispatchSemaphore(value: 0)
        let worker = ResourcePackCPUWorker(
            queueLabel: "com.elysium.tests.resource-pack-worker.\(UUID().uuidString)"
        ) { _, cancellation in
            started.signal()
            _ = drain.wait(timeout: .now() + 5)
            XCTAssertTrue(cancellation.isCancelled)
            return nil
        }
        let snapshot = ResourcePackStackSourceSnapshot(
            enabledNames: [], sources: [], bundledAddOns: [])
        let completed = expectation(description: "cancelled worker drains")
        var completion: (UInt64, PreparedResourcePackTransaction?, Bool)?

        XCTAssertTrue(worker.submit(transactionID: 1, snapshot: snapshot) { id, prepared, cancelled in
            completion = (id, prepared, cancelled)
            completed.fulfill()
        })
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        worker.cancel(transactionID: 1)
        XCTAssertTrue(worker.isLeased, "cancellation must not free a still-running worker lease")
        XCTAssertFalse(worker.submit(transactionID: 2, snapshot: snapshot) { _, _, _ in
            XCTFail("a replacement transaction must not be queued while the old worker drains")
        })

        drain.signal()
        wait(for: [completed], timeout: 3)
        XCTAssertEqual(completion?.0, 1)
        XCTAssertNil(completion?.1)
        XCTAssertEqual(completion?.2, true)
        XCTAssertFalse(worker.isLeased)
    }
}
