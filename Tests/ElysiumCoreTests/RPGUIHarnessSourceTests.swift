import Foundation
import XCTest

final class RPGUIHarnessSourceTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: repository.appendingPathComponent(relative), encoding: .utf8)
    }

    func testBootstrapDecisionPrecedesOrdinaryConstructionAndRetiredMutationIsAbsent() throws {
        let main = try source("Sources/Elysium/main.swift")
        let parse = try XCTUnwrap(main.range(of: "RPGUIHarnessBootstrap.parseIfPresent"))
        let keyMap = try XCTUnwrap(main.range(of: "let KEYCODE_MAP"))
        let application = try XCTUnwrap(main.range(of: "let app = NSApplication.shared"))
        XCTAssertLessThan(parse.lowerBound, keyMap.lowerBound)
        XCTAssertLessThan(parse.lowerBound, application.lowerBound)
        XCTAssertTrue(main.contains("switch elysiumBootstrapDecision"))
        XCTAssertTrue(main.contains("case .rejected(let diagnostic):"))
        for retired in ["pendingRPGAutoCreate", "runRPGAutoCreateIfNeeded",
                        "ELYSIUM_RPG_AUTOCREATE", "ELYSIUM_RPG_PATH",
                        "ELYSIUM_RPG_STARTER", "ELYSIUM_RPG_SPELLS"] {
            XCTAssertFalse(main.contains(retired), retired)
        }
        let readme = try source("README.md")
        for retired in ["ELYSIUM_RPG_AUTOCREATE", "ELYSIUM_RPG_PATH",
                        "ELYSIUM_RPG_STARTER", "ELYSIUM_RPG_SPELLS"] {
            XCTAssertFalse(readme.contains(retired), retired)
        }
    }

    func testHarnessRuntimeHasNoOrdinaryDependencyReferenceOrFactory() throws {
        let harness = try source("Sources/Elysium/RPGUIHarnessM.swift")
        for forbidden in ["GameCore", "SaveDB", "StorageEngine", "LocalSettingsStore",
                          "SettingsStore", "LANMultiplayer", "Network.framework",
                          "GameController", "AudioEngine", "Player("] {
            XCTAssertFalse(harness.contains(forbidden), forbidden)
        }
        XCTAssertTrue(harness.contains("RPGUIHarnessFixture.build"))
        XCTAssertTrue(harness.contains("RPGUIHarnessView"))
    }

    func testScreenshotReservationIsDescriptorRelativeExclusiveAndNoFollow() throws {
        let harness = try source("Sources/Elysium/RPGUIHarnessM.swift")
        for required in ["O_DIRECTORY", "O_NOFOLLOW", "O_EXCL", "openat(",
                         "mkdirat(", "fstat(", "unlinkat(", "geteuid()",
                         "S_IRWXG | S_IRWXO", "S_IRUSR | S_IWUSR"] {
            XCTAssertTrue(harness.contains(required), required)
        }
        XCTAssertFalse(harness.contains("Data.write("))
        XCTAssertFalse(harness.contains("createFile(atPath:"))
    }

    func testHarnessAccessibilityIsBoundedPassiveStateCompleteAndScreenProjected() throws {
        let harness = try source("Sources/Elysium/RPGUIHarnessM.swift")
        for required in ["prefix(512)", "accessibilityActionNames()", "{ [] }",
                         "setAccessibilityChildren", "viewDidMoveToWindow",
                         "accessibilityPublished",
                         "convert(viewRect, to: nil)", "convertPoint(toScreen:",
                         "descriptor.selected", "descriptor.prepared", "descriptor.slotted",
                         "\"Locked\"", "\"Enabled\"", "\"Disabled\""] {
            XCTAssertTrue(harness.contains(required), required)
        }
        XCTAssertFalse(harness.contains("accessibilityPerformPress"))
        XCTAssertFalse(harness.contains("label: \"RPG authority\""))
    }

    func testHarnessAndProductionRenderAllEightShapesAndFullWrappedHelp() throws {
        let harness = try source("Sources/Elysium/RPGUIHarnessM.swift")
        let production = try source("Sources/Elysium/RPGScreensM.swift")
        let iconIDs = [
            "authority.ready", "authority.awaitingHost", "authority.savingAccepted",
            "authority.savingRejected", "authority.reconnecting", "authority.finalizing",
            "authority.exhausted", "authority.unavailable",
        ]
        for icon in iconIDs {
            XCTAssertTrue(harness.contains(icon), "harness \(icon)")
            XCTAssertTrue(production.contains(icon), "production \(icon)")
        }
        XCTAssertTrue(harness.contains(".byWordWrapping"))
        XCTAssertTrue(harness.contains(".usesLineFragmentOrigin"))
        XCTAssertTrue(harness.contains("model.contextualDetailLines.enumerated()"))
        XCTAssertTrue(harness.contains(
            "rpgWrappedPresentationLines(text, width: width).enumerated()"))
        XCTAssertTrue(harness.contains("Double(index) * 12"))
        XCTAssertTrue(harness.contains("NSFont.monospacedSystemFont"))
        XCTAssertTrue(harness.contains("(line as NSString).draw("))
        XCTAssertTrue(harness.contains("withAttributes: attributes"))
        XCTAssertFalse(harness.contains(".truncatesLastVisibleLine"))
        XCTAssertTrue(production.contains("model.contextualDetailLines.enumerated()"))
        XCTAssertFalse(production.contains("clipped(model.authority.visibleHelp"))
        XCTAssertTrue(production.contains("model.authority.visibleTitle"))
        XCTAssertTrue(production.contains("status:current"))
        XCTAssertTrue(production.contains("model.layout.authorityChipFrame"))
        XCTAssertFalse(production.contains("panel.x + 150"))
        XCTAssertFalse(harness.contains("panel.minX + 150"))
        XCTAssertGreaterThanOrEqual(
            harness.components(separatedBy: "highContrast ? 3 : 1.5").count - 1, 2)
    }

    func testHarnessUsesTypedInputsAndNeverPatchesBuiltDescriptors() throws {
        let core = try source("Sources/ElysiumCore/Game/RPGUIHarness.swift")
        let model = try source("Sources/ElysiumCore/Game/RPGScreenModel.swift")
        for forbidden in ["RPGUIHarnessDescriptorOverride", "replacingDescriptors",
                          "replacingStatus"] {
            XCTAssertFalse(core.contains(forbidden), forbidden)
        }
        XCTAssertFalse(core.contains("rankPresentationFixture"))
        XCTAssertFalse(model.contains("RPGSkillRankPresentationFixture"))
        XCTAssertTrue(core.contains("repairedRankState("))
        XCTAssertTrue(core.contains("rpgLearnSkill("))
        XCTAssertTrue(core.contains("candidates.count <= 16"))
        XCTAssertTrue(core.contains("attempts <= 256"))
        XCTAssertFalse(core.contains("1 << candidates.count"))
        XCTAssertTrue(core.contains("inventoryCapacityAvailable: inventoryCapacityAvailable"))
        XCTAssertTrue(model.contains("invalidStartingSkillCount"))
        XCTAssertTrue(model.contains("card.mastered ? \"Mastered\""))
        XCTAssertTrue(core.contains("rpgRevealScrollOffset("))
        let candidate = try XCTUnwrap(core.range(of: "let candidateModel ="))
        let final = try XCTUnwrap(core.range(of: "let finalModel ="))
        let summary = try XCTUnwrap(core.range(of: "var lines = ["))
        XCTAssertLessThan(core.distance(from: core.startIndex, to: candidate.lowerBound),
                          core.distance(from: core.startIndex, to: final.lowerBound))
        XCTAssertLessThan(core.distance(from: core.startIndex, to: final.lowerBound),
                          core.distance(from: core.startIndex, to: summary.lowerBound))
        XCTAssertTrue(core.contains("finalTarget.layoutRegion == candidateRegion"))
        XCTAssertTrue(core.contains("finalTarget.visibleFrame == finalTarget.frame"))
    }

    func testBothRenderersConsumeModelOwnedCardIconsLinesAndAdornments() throws {
        let harness = try source("Sources/Elysium/RPGUIHarnessM.swift")
        let production = try source("Sources/Elysium/RPGScreensM.swift")
        for required in ["descriptor.iconAssetID", "descriptor.visualLines",
                         "descriptor.adornment", "selectedCheckDoubleBorder"] {
            XCTAssertTrue(harness.contains(required), "harness \(required)")
            XCTAssertTrue(production.contains(required), "production \(required)")
        }
        XCTAssertTrue(harness.contains("rpgIconPixels(assetID: assetID)"))
        XCTAssertTrue(production.contains("drawRPGIcon(icon"))
        XCTAssertFalse(production.contains("clipped(descriptor.label"))
        for value in [harness, production] {
            XCTAssertTrue(value.contains("guard rpgDescriptorVisualLinesFit("))
        }
        XCTAssertFalse(production.contains("guard lineY + 8 <= frame.maxY else { break }"))
        XCTAssertFalse(harness.contains("guard y + 8 <= frame.maxY else { break }"))
    }

    /// The class carousel was retired; both renderers must have dropped its chevron adornments
    /// entirely in favor of single-click card activation.
    func testBothRenderersDroppedCarouselChevronsEntirely() throws {
        let harness = try source("Sources/Elysium/RPGUIHarnessM.swift")
        let production = try source("Sources/Elysium/RPGScreensM.swift")
        let model = try source("Sources/ElysiumCore/Game/RPGScreenModel.swift")
        for value in [harness, production, model] {
            XCTAssertFalse(value.contains("carouselPrevious"))
            XCTAssertFalse(value.contains("carouselNext"))
        }
        XCTAssertFalse(model.contains("visualLines: [\"‹\"]"))
        XCTAssertFalse(model.contains("visualLines: [\"›\"]"))
    }

    func testBothRenderersUseOnlyTheSharedFocusRingTokenAndGeometry() throws {
        let harness = try source("Sources/Elysium/RPGUIHarnessM.swift")
        let production = try source("Sources/Elysium/RPGScreensM.swift")
        for value in [harness, production] {
            XCTAssertTrue(value.contains("rpgFocusRingToken(highContrast:"))
            XCTAssertTrue(value.contains("rpgFocusRingGeometry(frame:"))
            XCTAssertFalse(value.contains("systemOrange"))
            XCTAssertFalse(value.contains("focused ? 2"))
        }
    }
}
