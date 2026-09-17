import Foundation
import XCTest
@testable import ElysiumCore

final class ResourcePackSelectionTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testCatalogIsClosedAndDeterministic() {
        XCTAssertEqual(BUNDLED_RESOURCE_PACK_BASE_STYLES.map(\.id),
                       [.faithful64x, .kubikosCubicWorld])
        XCTAssertEqual(BUNDLED_RESOURCE_PACK_BASE_STYLES.map(\.displayName),
                       ["Faithful 64x", "KUBIKOS Cubic World"])
        XCTAssertEqual(BUNDLED_RESOURCE_PACK_ADD_ONS.map(\.id), [.oreBorders64x, .staticLanterns])
        XCTAssertEqual(Set(BUNDLED_RESOURCE_PACK_ADD_ONS.map(\.conflictGroup)).count, 2)
    }

    func testFreshAndMalformedSelectionsDefaultToFaithfulWithNoOptionalAddOns() {
        XCTAssertEqual(sanitizedBundledResourcePackBaseStyleID(nil), .faithful64x)
        XCTAssertEqual(sanitizedBundledResourcePackBaseStyleID("unknown-style"), .faithful64x)
        XCTAssertEqual(sanitizedBundledResourcePackBaseStyleID("kubikos-cubic-world"),
                       .kubikosCubicWorld)
        XCTAssertEqual(sanitizedBundledResourcePackAddOnIDs(nil), [])
        XCTAssertEqual(sanitizedBundledResourcePackAddOnIDs([]), [])
        XCTAssertEqual(sanitizedBundledResourcePackAddOnIDs(["../x", "unknown"]), [])
    }

    func testSanitizationDeduplicatesAndRestoresCatalogOrder() {
        XCTAssertEqual(sanitizedBundledResourcePackAddOnIDs([
            "static-lanterns", "ore-borders-64x", "static-lanterns", "unknown",
        ]), [.oreBorders64x, .staticLanterns])
    }

    func testToggleAddsAndRemovesOnlyRequestedKnownID() {
        XCTAssertEqual(evaluateBundledResourcePackToggle(selected: [], requested: "static-lanterns"),
                       .ready([.staticLanterns]))
        XCTAssertEqual(evaluateBundledResourcePackToggle(
            selected: ["ore-borders-64x", "static-lanterns"], requested: "ore-borders-64x"),
            .ready([.staticLanterns]))
        XCTAssertEqual(evaluateBundledResourcePackToggle(selected: [], requested: "invalid"), .invalid)
    }

    func testShippedCatalogHasNoConflictsAndCanCoexist() {
        XCTAssertEqual(evaluateBundledResourcePackToggle(
            selected: ["ore-borders-64x"], requested: "static-lanterns"),
            .ready([.oreBorders64x, .staticLanterns]))
    }

    func testInjectableInteractionCatalogExercisesConflictWithoutChangingShippedCatalog() {
        let interaction = ResourcePackScreenInteraction(catalog: [
            .init(id: .oreBorders64x, displayName: "Synthetic Ore", conflictGroup: "same"),
            .init(id: .staticLanterns, displayName: "Synthetic Lantern", conflictGroup: "same"),
        ])
        XCTAssertEqual(interaction.evaluateToggle(
            selected: [.oreBorders64x], requested: .staticLanterns),
            .conflict(requested: "Synthetic Lantern", active: "Synthetic Ore"))
        XCTAssertEqual(BUNDLED_RESOURCE_PACK_ADD_ONS.map(\.conflictGroup),
                       ["ore-appearance", "sea-lantern-animation"])
    }

    func testInjectableInteractionCatalogFailsClosedOnDuplicateDescriptors() {
        let duplicate = BundledResourcePackAddOnDescriptor(
            id: .oreBorders64x, displayName: "Duplicate", conflictGroup: nil)
        XCTAssertEqual(ResourcePackScreenInteraction(catalog: [duplicate, duplicate])
            .evaluateToggle(selected: [], requested: .oreBorders64x), .invalid)
    }

    func testLayoutIncludesBaseStylesAndClampsNonFiniteAndOversizedScroll() {
        let layout = ResourcePackScreenLayout(
            viewportHeight: 120, contentTop: 20, contentBottom: 70,
            requestedScrollOffset: .infinity)
        XCTAssertTrue(layout.clampedScrollOffset.isFinite)
        XCTAssertEqual(layout.clampedScrollOffset, 0)
        XCTAssertEqual(layout.visibleRows.map(\.id), [
            .baseStyle(.faithful64x), .baseStyle(.kubikosCubicWorld),
        ])
        let scrolled = ResourcePackScreenLayout(
            viewportHeight: 120, contentTop: 20, contentBottom: 70,
            requestedScrollOffset: 999)
        XCTAssertEqual(scrolled.clampedScrollOffset, 70)
        XCTAssertEqual(scrolled.visibleRows.map(\.id), [
            .addOn(.oreBorders64x), .addOn(.staticLanterns),
        ])
    }

    func testKubikosStyleClearsFaithfulAddOns() {
        let selected = ["static-lanterns", "ore-borders-64x"]
        XCTAssertTrue(bundledResourcePackAddOnsAllowed(for: .faithful64x))
        XCTAssertFalse(bundledResourcePackAddOnsAllowed(for: .kubikosCubicWorld))
        XCTAssertEqual(sanitizedBundledResourcePackAddOnIDs(selected, for: .faithful64x),
                       [.oreBorders64x, .staticLanterns])
        XCTAssertEqual(sanitizedBundledResourcePackAddOnIDs(selected, for: .kubikosCubicWorld), [])

        var settings = Settings()
        settings.bundledResourcePackBaseStyle = BundledResourcePackBaseStyleID.kubikosCubicWorld.rawValue
        settings.bundledResourcePackAddOns = selected
        let sanitized = sanitizedSettings(settings)
        XCTAssertEqual(sanitized.bundledResourcePackBaseStyle,
                       BundledResourcePackBaseStyleID.kubikosCubicWorld.rawValue)
        XCTAssertEqual(sanitized.bundledResourcePackAddOns, [])
    }

    func testSettingsSanitizesOptionalConsentIndependentlyFromUserPacks() {
        var settings = Settings()
        settings.resourcePacks = ["custom.zip"]
        settings.bundledResourcePackAddOns = ["static-lanterns", "bad", "static-lanterns"]
        let output = sanitizedSettings(settings)
        XCTAssertEqual(output.resourcePacks, ["custom.zip"])
        XCTAssertEqual(output.bundledResourcePackBaseStyle,
                       BundledResourcePackBaseStyleID.faithful64x.rawValue)
        XCTAssertEqual(output.bundledResourcePackAddOns, ["static-lanterns"])
    }

    func testAppSourcePresentsApplyingBeforeWorkerAndRetainsTimedOutLease() throws {
        let screen = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/ResourcePackScreenM.swift"), encoding: .utf8)
        let packs = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/ResourcePacks.swift"), encoding: .utf8)
        let main = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/main.swift"), encoding: .utf8)
        let applying = try XCTUnwrap(screen.range(of: "status = \"Applying "))
        let presented = try XCTUnwrap(screen.range(of: "ui.afterNextPresentedFrame", range: applying.upperBound..<screen.endIndex))
        let submit = try XCTUnwrap(screen.range(of: "ResourcePackCPUWorker.shared.submit", range: presented.upperBound..<screen.endIndex))
        XCTAssertLessThan(applying.lowerBound, presented.lowerBound)
        XCTAssertLessThan(presented.lowerBound, submit.lowerBound)
        XCTAssertTrue(screen.contains("addingReportingOverflow(15_000_000_000)"))
        XCTAssertTrue(screen.contains("deadlineExpired(transaction)"))
        XCTAssertTrue(screen.contains("lease remains occupied until that work has actually drained"))
        XCTAssertTrue(screen.contains("Previous resource pack work is still finishing"))
        let workerEnd = try XCTUnwrap(screen.range(of: "final class ResourcePackScreen"))
        let worker = screen[..<workerEnd.lowerBound]
        XCTAssertTrue(worker.contains("snapshot: ResourcePackStackSourceSnapshot"))
        for forbidden in ["validateResourcePackStack", "applyResourcePacks", "resourcePacksDir()",
                          "URL(", "userPacks:", "bundledAddOns:"] {
            XCTAssertFalse(worker.contains(forbidden), forbidden)
        }
        XCTAssertFalse(screen.contains("applyResourcePacks("),
                       "interactive toggles must not invoke the startup resolver/apply wrapper")
        XCTAssertTrue(packs.contains("enum ResourcePackSourcePayload: Sendable"))
        XCTAssertTrue(packs.contains("case archive(Data)"))
        XCTAssertTrue(packs.contains("case folder([String: Data])"))
        XCTAssertTrue(packs.contains("guard !stagingClaimed else { return nil }"))
        XCTAssertTrue(packs.contains("precondition(Thread.isMainThread && !consumed"))
        let commandPresent = try XCTUnwrap(main.range(of: "cmd.present(drawable)"))
        let completed = try XCTUnwrap(main.range(of: "cmd.addCompletedHandler", range: commandPresent.upperBound..<main.endIndex))
        let commit = try XCTUnwrap(main.range(of: "cmd.commit()", range: completed.upperBound..<main.endIndex))
        XCTAssertLessThan(commandPresent.lowerBound, completed.lowerBound)
        XCTAssertLessThan(completed.lowerBound, commit.lowerBound)
    }

    func testInteractivePipelineStagesPersistsThenPublishesOneABGeneration() throws {
        let screen = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/ResourcePackScreenM.swift"), encoding: .utf8)
        let packs = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/ResourcePacks.swift"), encoding: .utf8)
        let finish = try XCTUnwrap(screen.range(of: "private func finishPrepared"))
        let stage = try XCTUnwrap(screen.range(of: "prepared.stage(", range: finish.upperBound..<screen.endIndex))
        let persist = try XCTUnwrap(screen.range(of: "persistAndPublishSettingsCandidateCommitAware(",
                                                  range: stage.upperBound..<screen.endIndex))
        let publish = try XCTUnwrap(screen.range(of: "staged.publish(",
                                                  range: persist.upperBound..<screen.endIndex))
        XCTAssertLessThan(stage.lowerBound, persist.lowerBound)
        XCTAssertLessThan(persist.lowerBound, publish.lowerBound)
        XCTAssertTrue(screen.contains("prepared.stage(renderer: renderer, game: game)"))
        let retire = try XCTUnwrap(packs.range(of: "iconPackPublicationHook?(.retired)",
                                               range: packs.range(of: "final class StagedResourcePackPublication")!.upperBound..<packs.endIndex))
        let uiWorld = try XCTUnwrap(packs.range(of: "iconPackPublicationHook?(.uiWorldInstalled)",
                                                range: retire.upperBound..<packs.endIndex))
        let core = try XCTUnwrap(packs.range(of: "iconPackPublicationHook?(.coreCommitted)",
                                             range: uiWorld.upperBound..<packs.endIndex))
        XCTAssertLessThan(retire.lowerBound, uiWorld.lowerBound)
        XCTAssertLessThan(uiWorld.lowerBound, core.lowerBound)
        let stagedClass = try XCTUnwrap(packs.range(of: "final class StagedResourcePackPublication"))
        let iconCommit = try XCTUnwrap(packs.range(of: "publishIconSourceSnapshot(candidate)",
                                                  range: stagedClass.upperBound..<packs.endIndex))
        let meshInstall = try XCTUnwrap(packs.range(of: "game.installMeshRenderContext(meshContext)",
                                                   range: iconCommit.upperBound..<packs.endIndex))
        let remesh = try XCTUnwrap(packs.range(of: "game.remeshAllLoaded()",
                                              range: meshInstall.upperBound..<packs.endIndex))
        XCTAssertLessThan(iconCommit.lowerBound, meshInstall.lowerBound)
        XCTAssertLessThan(meshInstall.lowerBound, remesh.lowerBound)
        XCTAssertEqual(packs.components(separatedBy: "prepareNextMeshRenderContext(").count - 1, 3)
        XCTAssertEqual(packs.components(separatedBy: "installMeshRenderContext(meshContext)").count - 1, 3)
        XCTAssertFalse(packs.contains("PACK_TINT_GATE"))
        XCTAssertFalse(packs.contains("PACK_TEXTURE_GATE"))
        XCTAssertTrue(packs.contains("currentIconSourceGeneration() == generation"))
        XCTAssertTrue(screen.contains("guard !cancelled, ui.current() === self"))
        XCTAssertTrue(screen.contains("transaction.id == transactionID"))
    }

    func testAppSourceExposesStableRecoveryKeyboardAndAccessibilityContract() throws {
        let screen = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/ResourcePackScreenM.swift"), encoding: .utf8)
        let settings = try String(contentsOf: root.appendingPathComponent(
            "Sources/Elysium/MenusM.swift"), encoding: .utf8)
        for marker in [
            "event.modifiers.contains(.shift)", "ArrowUp", "ArrowDown", "NumpadEnter",
            "resource-pack.acknowledge", "resource-pack.done", "saved choice unknown",
            "Settings recovery required — Restart Elysium",
            "Restart Elysium before changing settings", "consumeTextAccessibilityStatusAnnouncement",
            "id: \"resource-pack.style.\\(descriptor.id.rawValue)\", role: .checkbox",
            "BUNDLED_RESOURCE_PACK_BASE_STYLES", "Requires Faithful 64x",
            "This Faithful 64x add-on cannot be used with KUBIKOS Cubic World.",
            "button.enabled = idle && !game.settingsRecoveryRequired && baseStyle == .faithful64x",
            "enabled: button.enabled,",
        ] { XCTAssertTrue(screen.contains(marker), marker) }
        XCTAssertEqual(BUNDLED_RESOURCE_PACK_BASE_STYLES.map {
            "resource-pack.style.\($0.id.rawValue)"
        }, [
            "resource-pack.style.faithful-64x",
            "resource-pack.style.kubikos-cubic-world",
        ])
        for marker in [
            "recoveryNavigationButtons", "for slider in sliders { slider.enabled = false",
            "for field in fields { field.enabled = false", "Settings recovery required — Restart Elysium",
        ] { XCTAssertTrue(settings.contains(marker), marker) }
    }
}
