import Foundation
import XCTest

final class RPGPassiveRendererSourceTests: XCTestCase {
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testProductionRendererHasNoPrototypeOrIndependentMutationSurface() throws {
        let renderer = try source("Sources/Pebble/RPGScreensM.swift")
        let forbidden = [
            "Button" + "(", "request" + "RPG", "player.rpg =",
            "rpgLearnSkill", "rpgPrepareSkill", "rpgPrepareSpell",
            "dispatchSyntheticRPGSemanticActivation", "super.onMouseDown"
        ]
        for token in forbidden {
            XCTAssertFalse(renderer.contains(token), "forbidden production renderer token: \(token)")
        }
        XCTAssertTrue(renderer.contains("rpgScreenRuntimeSnapshot()"))
        XCTAssertTrue(renderer.contains("rpgBuildScreenModel(RPGScreenModelInput("))
        XCTAssertTrue(renderer.contains("commitRPGSemanticModel(model, runtime: runtime, to: self)"))
        XCTAssertTrue(renderer.contains("captureRPGSemanticActivation"))
        XCTAssertTrue(renderer.contains("dispatchRPGSemanticActivation"))
        XCTAssertTrue(renderer.contains("#if DEBUG"))
        XCTAssertTrue(renderer.contains("override func onMouseDown"))
        XCTAssertTrue(renderer.contains("override func onWheel"))
        XCTAssertTrue(renderer.contains("override func onKey"))
        XCTAssertTrue(renderer.contains("override func onChar"))
    }

    func testDrawAndSemanticInspectionAreMutationFreeSnapshotReads() throws {
        let renderer = try source("Sources/Pebble/RPGScreensM.swift")
        let drawStart = try XCTUnwrap(renderer.range(of: "override func draw("))
        let drawEnd = try XCTUnwrap(renderer.range(
            of: "// Mouse activation", range: drawStart.upperBound..<renderer.endIndex))
        let drawBody = String(renderer[drawStart.lowerBound..<drawEnd.lowerBound])
        XCTAssertTrue(drawBody.contains("rpgCommittedSemanticSnapshot"))
        XCTAssertFalse(drawBody.contains("game."))
        XCTAssertFalse(drawBody.contains("rpgBuild"))
        XCTAssertFalse(drawBody.contains("commitRPG"))

        let manager = try source("Sources/Pebble/UIManagerM.swift")
        XCTAssertTrue(manager.contains("RPGPassiveSemanticClock()"))
        XCTAssertTrue(manager.contains("allocateScreenInstanceID()"))
        XCTAssertTrue(manager.contains("nextSemanticRevision("))
        XCTAssertTrue(manager.contains("model.descriptors.allSatisfy({ $0.actionCommand == nil })"))
        XCTAssertTrue(manager.contains("rpgCommittedSemanticSnapshot?.model"))
        XCTAssertTrue(manager.contains("boundary.capture("))
        XCTAssertTrue(manager.contains("case .staleRequiresFreshActivation:"))
    }

    func testRendererPublishesOnlyDuringInitializationAndResizeRelayout() throws {
        let renderer = try source("Sources/Pebble/RPGScreensM.swift")
        XCTAssertEqual(renderer.components(
            separatedBy: "commitRPGSemanticModel(model, runtime: runtime, to: self)").count - 1, 1)
        let provisional = try XCTUnwrap(renderer.range(of:
            "let provisionalModel = buildModel(scrollOffset: interaction.scrollOffset)"))
        let reconcile = try XCTUnwrap(renderer.range(of:
            "rpgReconcileProvisionalScreenModel("))
        let finalModel = try XCTUnwrap(renderer.range(of:
            "let model = needsAnchoredRebuild"))
        let commit = try XCTUnwrap(renderer.range(of:
            "commitRPGSemanticModel(model, runtime: runtime, to: self)"))
        for range in [provisional, reconcile, finalModel] {
            XCTAssertLessThan(renderer.distance(from: renderer.startIndex, to: range.lowerBound),
                              renderer.distance(from: renderer.startIndex, to: commit.lowerBound))
        }
        let manager = try source("Sources/Pebble/UIManagerM.swift")
        XCTAssertTrue(manager.contains("s.initScreen(self, game)"))
        XCTAssertTrue(manager.contains("screen.rpgPassiveSemanticUnavailable = true"))
        XCTAssertTrue(manager.contains("screen.rpgPassiveSemanticUnavailable = false"))
    }

    func testMouseOwnershipAndAsyncRefreshAdaptersFailClosed() throws {
        let renderer = try source("Sources/Pebble/RPGScreensM.swift")
        XCTAssertTrue(renderer.contains("override func inputOwnershipLost"))
        XCTAssertTrue(renderer.contains("override func onClose"))
        XCTAssertTrue(renderer.contains("private var interaction: RPGScreenInteractionState"))
        XCTAssertTrue(renderer.contains("rpgReduceScreenInteraction(interaction"))
        XCTAssertTrue(renderer.contains(
            "localPreferenceStatus: runtime.localPreferenceStatus"))
        let down = try XCTUnwrap(renderer.range(of: "override func onMouseDown"))
        let up = try XCTUnwrap(renderer.range(
            of: "override func onMouseUp", range: down.upperBound..<renderer.endIndex))
        let downBody = String(renderer[down.lowerBound..<up.lowerBound])
        let clear = try XCTUnwrap(downBody.range(of: "reduceInteraction(.cancelMouse"))
        let guardRange = try XCTUnwrap(downBody.range(of: "guard btn == 0"))
        XCTAssertLessThan(downBody.distance(from: downBody.startIndex, to: clear.lowerBound),
                          downBody.distance(from: downBody.startIndex, to: guardRange.lowerBound))

        let manager = try source("Sources/Pebble/UIManagerM.swift")
        XCTAssertTrue(manager.contains("stack.last?.inputOwnershipLost(self, game)"))
        XCTAssertTrue(manager.contains("_ = boundary.cancel(capture)"))
        XCTAssertTrue(manager.contains("snapshot.worldEntryGeneration == refresh.worldEntryGeneration"))
        XCTAssertTrue(manager.contains("refresh.localPreferenceRevision >= snapshot.localPreferenceRevision"))

        let core = try source("Sources/PebbleCore/Game/GameCore.swift")
        XCTAssertTrue(core.contains("rpgLocalPreferenceDidRefresh(RPGLocalPreferenceUIRefresh("))
        XCTAssertTrue(core.contains("persistenceFailed: true"))
        XCTAssertTrue(core.contains("persistenceFailed: false"))

        let app = try source("Sources/Pebble/main.swift")
        let resignStart = try XCTUnwrap(app.range(of: "func applicationDidResignActive"))
        let resignEnd = try XCTUnwrap(app.range(
            of: "func mtkView", range: resignStart.upperBound..<app.endIndex))
        let resignBody = String(app[resignStart.lowerBound..<resignEnd.lowerBound])
        XCTAssertTrue(resignBody.contains("ui.current()?.inputOwnershipLost(ui, game)"))
    }
}
