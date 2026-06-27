import XCTest
@testable import PebbleCore

final class CommandLineSupportTests: XCTestCase {
    private func registerCoreIfNeeded() {
        registerAllBlocks()
        registerAllItems()
    }

    private func visibleWidth(_ text: String) -> Int {
        var width = 0
        var skip = false
        for ch in text {
            if skip { skip = false; continue }
            if ch == "§" { skip = true; continue }
            width += 1
        }
        return width
    }

    func testObjectTemplateShortcutsMapCommandCAndCommandVInWorldMode() {
        XCTAssertEqual(objectTemplateShortcutAction(forKey: "KeyC",
                                                    commandDown: true,
                                                    hasOpenScreen: false,
                                                    hasWorld: true,
                                                    isRepeat: false),
                       .copyObject)
        XCTAssertEqual(objectTemplateShortcutAction(forKey: "KeyV",
                                                    commandDown: true,
                                                    hasOpenScreen: false,
                                                    hasWorld: true,
                                                    isRepeat: false),
                       .placeObject)
        XCTAssertEqual(objectTemplateShortcutAction(forKey: "KeyZ",
                                                    commandDown: true,
                                                    hasOpenScreen: false,
                                                    hasWorld: true,
                                                    isRepeat: false),
                       .undoObjectPlacement)
    }

    func testObjectTemplateShortcutsDoNotStealScreenEditingOrLegacyCommandP() {
        XCTAssertNil(objectTemplateShortcutAction(forKey: "KeyV",
                                                  commandDown: true,
                                                  hasOpenScreen: true,
                                                  hasWorld: true,
                                                  isRepeat: false))
        XCTAssertNil(objectTemplateShortcutAction(forKey: "KeyZ",
                                                  commandDown: true,
                                                  hasOpenScreen: true,
                                                  hasWorld: true,
                                                  isRepeat: false))
        XCTAssertNil(objectTemplateShortcutAction(forKey: "KeyV",
                                                  commandDown: false,
                                                  hasOpenScreen: false,
                                                  hasWorld: true,
                                                  isRepeat: false))
        XCTAssertNil(objectTemplateShortcutAction(forKey: "KeyZ",
                                                  commandDown: false,
                                                  hasOpenScreen: false,
                                                  hasWorld: true,
                                                  isRepeat: false))
        XCTAssertNil(objectTemplateShortcutAction(forKey: "KeyV",
                                                  commandDown: true,
                                                  hasOpenScreen: false,
                                                  hasWorld: false,
                                                  isRepeat: false))
        XCTAssertNil(objectTemplateShortcutAction(forKey: "KeyZ",
                                                  commandDown: true,
                                                  hasOpenScreen: false,
                                                  hasWorld: false,
                                                  isRepeat: false))
        XCTAssertNil(objectTemplateShortcutAction(forKey: "KeyV",
                                                  commandDown: true,
                                                  hasOpenScreen: false,
                                                  hasWorld: true,
                                                  isRepeat: true))
        XCTAssertNil(objectTemplateShortcutAction(forKey: "KeyZ",
                                                  commandDown: true,
                                                  hasOpenScreen: false,
                                                  hasWorld: true,
                                                  isRepeat: true))
        XCTAssertNil(objectTemplateShortcutAction(forKey: "KeyP",
                                                  commandDown: true,
                                                  hasOpenScreen: false,
                                                  hasWorld: true,
                                                  isRepeat: false))
    }

    func testWrapTextKeepsWordsWithinWidth() {
        let lines = wrapTextByWidth("alpha beta gamma", maxWidth: 10, measure: visibleWidth)

        XCTAssertEqual(lines, ["alpha beta", "gamma"])
        XCTAssertTrue(lines.allSatisfy { visibleWidth($0) <= 10 })
    }

    func testWrapTextSplitsLongTokens() {
        let lines = wrapTextByWidth("abcdefghij", maxWidth: 4, measure: visibleWidth)

        XCTAssertEqual(lines, ["abcd", "efgh", "ij"])
        XCTAssertTrue(lines.allSatisfy { visibleWidth($0) <= 4 })
    }

    func testWrapTextKeepsFormattingCodesZeroWidth() {
        let lines = wrapTextByWidth("§cabcdef", maxWidth: 3, measure: visibleWidth)

        XCTAssertEqual(lines.joined(), "§cabcdef")
        XCTAssertEqual(lines.map(visibleWidth), [3, 3])
    }

    func testItemCompletionUsesFullRegisteredItemList() {
        registerCoreIfNeeded()

        let candidates = itemCompletionCandidates(for: "")

        XCTAssertEqual(candidates.count, itemDefs.count)
        XCTAssertTrue(candidates.contains("coal"))
        XCTAssertTrue(candidates.contains("diamond_pickaxe"))
    }

    func testItemCompletionCompletesTrailingCommandToken() throws {
        registerCoreIfNeeded()

        let completion = try XCTUnwrap(completeCommandLineItem(input: "/give coa"))

        XCTAssertEqual(completion.completedInput, "/give coal")
        XCTAssertEqual(completion.replacement, "coal")
        XCTAssertTrue(completion.matches.contains("coal_block"))
    }

    func testItemCompletionCyclesMultipleMatches() throws {
        registerCoreIfNeeded()

        let first = try XCTUnwrap(completeCommandLineItem(input: "/give diamond_"))
        let second = try XCTUnwrap(completeCommandLineItem(input: "/give diamond_", cycleIndex: 1))

        XCTAssertGreaterThan(first.matches.count, 1)
        XCTAssertEqual(first.completedInput, "/give diamond_axe")
        XCTAssertNotEqual(second.completedInput, first.completedInput)
        XCTAssertTrue(second.matches.allSatisfy { $0.hasPrefix("diamond_") })
    }

    func testItemCompletionMatchesDisplayNameToCanonicalID() throws {
        registerCoreIfNeeded()

        let completion = try XCTUnwrap(completeCommandLineItem(input: "/give eye"))

        XCTAssertEqual(completion.completedInput, "/give ender_eye")
    }

    func testItemCompletionAfterWhitespaceCanOfferAllItems() throws {
        registerCoreIfNeeded()

        let completion = try XCTUnwrap(completeCommandLineItem(input: "/give "))

        XCTAssertEqual(completion.matches.count, itemDefs.count)
        XCTAssertFalse(completion.replacement.isEmpty)
        XCTAssertTrue(completion.completedInput.hasPrefix("/give "))
    }

    func testItemCompletionDoesNotModifySlashCommandToken() {
        registerCoreIfNeeded()

        XCTAssertNil(completeCommandLineItem(input: "/gi"))
    }
}
