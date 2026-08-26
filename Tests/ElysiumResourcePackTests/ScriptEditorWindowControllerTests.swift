import XCTest
@testable import Elysium
@testable import ElysiumCore

@MainActor
final class ScriptEditorWindowControllerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        if blockDefs.isEmpty { registerAllBlocks() }
        if itemDefs.isEmpty { registerAllItems() }
        if entityTypes().isEmpty { registerAllEntities() }
    }

    func testDirtyCloseSavePersistsAndAllowsClose() throws {
        let game = try makeGame(label: "close-save")
        let model = dirtyModel(in: game, name: "saved", source: "say(\"saved\")")
        let harness = makeController(game: game, unsavedDecisions: [.save])

        XCTAssertTrue(harness.controller.shouldCloseEditor(model))

        XCTAssertEqual(game.scriptingCommandContext().scriptStore.get(.player, "saved")?.source, "say(\"saved\")")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(harness.confirmations.actions, ["close the editor"])
    }

    func testDirtyCloseDiscardAllowsCloseWithoutSaving() throws {
        let game = try makeGame(label: "close-discard")
        let model = dirtyModel(in: game, name: "discarded", source: "say(\"draft\")")
        let harness = makeController(game: game, unsavedDecisions: [.discard])

        XCTAssertTrue(harness.controller.shouldCloseEditor(model))

        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "discarded"))
        XCTAssertTrue(model.isDirty, "discard is a navigation decision; a cancelled later quit must still retain the draft")
        XCTAssertEqual(model.source, "say(\"draft\")")
        XCTAssertEqual(harness.confirmations.actions, ["close the editor"])
    }

    func testDirtyCloseCancelRefusesCloseAndRetainsDraft() throws {
        let game = try makeGame(label: "close-cancel")
        let model = dirtyModel(in: game, name: "cancelled", source: "say(\"keep me\")")
        let harness = makeController(game: game, unsavedDecisions: [.cancel])

        XCTAssertFalse(harness.controller.shouldCloseEditor(model))

        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "cancelled"))
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.source, "say(\"keep me\")")
        XCTAssertEqual(harness.confirmations.actions, ["close the editor"])
    }

    func testDirtyCloseFailedSaveRefusesClose() throws {
        let game = try makeGame(label: "close-failed-save")
        let model = ScriptEditorModel(target: .player, game: game)
        model.currentName = "empty_source"
        XCTAssertTrue(model.isDirty)
        let harness = makeController(game: game, unsavedDecisions: [.save])

        XCTAssertFalse(harness.controller.shouldCloseEditor(model))

        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "empty_source"))
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(model.status, "Source is empty.")
        XCTAssertEqual(harness.confirmations.actions, ["close the editor"])
    }

    func testApplicationTerminationHonorsSaveDiscardAndCancel() throws {
        let game = try makeGame(label: "terminate-decisions")

        let saveModel = dirtyModel(in: game, name: "termination_saved", source: "say(\"saved\")")
        let saveHarness = makeController(game: game, unsavedDecisions: [.save])
        XCTAssertTrue(saveHarness.controller.shouldTerminateApplication(
            editors: [(window: nil, model: saveModel)]
        ))
        XCTAssertEqual(
            game.scriptingCommandContext().scriptStore.get(.player, "termination_saved")?.source,
            "say(\"saved\")"
        )
        XCTAssertEqual(saveHarness.confirmations.actions, ["quit Elysium"])

        let discardModel = dirtyModel(in: game, name: "termination_discarded", source: "say(\"draft\")")
        let discardHarness = makeController(game: game, unsavedDecisions: [.discard])
        XCTAssertTrue(discardHarness.controller.shouldTerminateApplication(
            editors: [(window: nil, model: discardModel)]
        ))
        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "termination_discarded"))
        XCTAssertTrue(discardModel.isDirty)
        XCTAssertEqual(discardHarness.confirmations.actions, ["quit Elysium"])

        let cancelModel = dirtyModel(in: game, name: "termination_cancelled", source: "say(\"keep me\")")
        let cancelHarness = makeController(game: game, unsavedDecisions: [.cancel])
        XCTAssertFalse(cancelHarness.controller.shouldTerminateApplication(
            editors: [(window: nil, model: cancelModel)]
        ))
        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "termination_cancelled"))
        XCTAssertTrue(cancelModel.isDirty)
        XCTAssertEqual(cancelHarness.confirmations.actions, ["quit Elysium"])
    }

    func testMultiWindowCancelAbortsTerminationBeforeLaterEditors() throws {
        let game = try makeGame(label: "terminate-multiple")
        let first = dirtyModel(in: game, name: "first", source: "say(\"first\")")
        let second = dirtyModel(in: game, name: "second", source: "say(\"second\")")
        let third = dirtyModel(in: game, name: "third", source: "say(\"third\")")
        let harness = makeController(game: game, unsavedDecisions: [.discard, .cancel])

        XCTAssertFalse(harness.controller.shouldTerminateApplication(editors: [
            (window: nil, model: first),
            (window: nil, model: second),
            (window: nil, model: third),
        ]))

        XCTAssertEqual(harness.confirmations.actions, ["quit Elysium", "quit Elysium"])
        XCTAssertTrue(first.isDirty)
        XCTAssertTrue(second.isDirty)
        XCTAssertTrue(third.isDirty)
        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "first"))
        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "second"))
        XCTAssertNil(game.scriptingCommandContext().scriptStore.get(.player, "third"))
    }

    func testCloseSaveCollisionRequiresInjectedReplacementDecision() throws {
        let game = try makeGame(label: "close-collision")
        let context = game.scriptingCommandContext()
        _ = try context.scriptStore.attach(
            .player, name: "existing", source: "say(\"original\")", mode: .module,
            triggers: [], by: .player, tick: context.tick
        ).get()
        let model = dirtyModel(in: game, name: "existing", source: "say(\"replacement\")")
        let harness = makeController(
            game: game,
            unsavedDecisions: [.save],
            overwriteDecisions: [.cancel]
        )

        XCTAssertFalse(harness.controller.shouldCloseEditor(model))

        XCTAssertEqual(context.scriptStore.get(.player, "existing")?.source, "say(\"original\")")
        XCTAssertTrue(model.isDirty)
        XCTAssertEqual(harness.confirmations.overwriteNames, ["existing"])
    }

    private func makeGame(label: String) throws -> GameCore {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("elysium-editor-window-\(label)-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseURL) }
        let game = GameCore(db: try SaveDB.open(databaseURL: databaseURL, migrateLegacy: false))
        game.createWorld(name: "Editor Window Test", seedText: "8128", mode: GameMode.creative, difficulty: 2)
        XCTAssertTrue(game.hasWorld())
        return game
    }

    private func dirtyModel(in game: GameCore, name: String, source: String) -> ScriptEditorModel {
        let model = ScriptEditorModel(target: .player, game: game)
        model.currentName = name
        model.source = source
        XCTAssertTrue(model.isDirty)
        return model
    }

    private func makeController(
        game: GameCore,
        unsavedDecisions: [ScriptEditorUnsavedChangesDecision],
        overwriteDecisions: [ScriptEditorOverwriteDecision] = []
    ) -> ControllerHarness {
        let owner = AppDelegate()
        owner.game = game
        let confirmations = ScriptEditorConfirmationSpy(
            unsavedDecisions: unsavedDecisions,
            overwriteDecisions: overwriteDecisions
        )
        let controller = ScriptEditorWindowController(
            owner: owner,
            confirmations: confirmations.presenter()
        )
        return ControllerHarness(owner: owner, controller: controller, confirmations: confirmations)
    }
}

@MainActor
private struct ControllerHarness {
    let owner: AppDelegate
    let controller: ScriptEditorWindowController
    let confirmations: ScriptEditorConfirmationSpy
}

@MainActor
private final class ScriptEditorConfirmationSpy {
    private var unsavedDecisions: [ScriptEditorUnsavedChangesDecision]
    private var overwriteDecisions: [ScriptEditorOverwriteDecision]
    private(set) var actions: [String] = []
    private(set) var overwriteNames: [String] = []

    init(
        unsavedDecisions: [ScriptEditorUnsavedChangesDecision],
        overwriteDecisions: [ScriptEditorOverwriteDecision]
    ) {
        self.unsavedDecisions = unsavedDecisions
        self.overwriteDecisions = overwriteDecisions
    }

    func presenter() -> ScriptEditorConfirmationPresenter {
        ScriptEditorConfirmationPresenter(
            unsavedChangesDecision: { [self] _, action in
                actions.append(action)
                guard !unsavedDecisions.isEmpty else {
                    XCTFail("Unexpected unsaved-changes confirmation for \(action)")
                    return .cancel
                }
                return unsavedDecisions.removeFirst()
            },
            overwriteDecision: { [self] _, name in
                overwriteNames.append(name)
                guard !overwriteDecisions.isEmpty else {
                    XCTFail("Unexpected overwrite confirmation for \(name)")
                    return .cancel
                }
                return overwriteDecisions.removeFirst()
            }
        )
    }
}
