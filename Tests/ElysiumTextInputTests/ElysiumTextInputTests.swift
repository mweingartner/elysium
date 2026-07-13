import XCTest
@testable import ElysiumTextInput

final class ElysiumTextInputTests: XCTestCase {
    private final class ByteCounter { var reads = 0 }
    private struct CountingBytes: Sequence {
        let total: Int
        let counter: ByteCounter
        func makeIterator() -> AnyIterator<UInt8> {
            var index = 0
            return AnyIterator {
                guard index < total else { return nil }
                index += 1
                counter.reads += 1
                return 0x61
            }
        }
    }
    func testValidatorAcceptsInternationalTextAndBoundedZWJEmoji() {
        for character in [Character("é"), Character("e\u{301}"), Character("界"), Character("👩‍💻"), Character("✊🏽"), Character("️")] {
            guard case .accepted(let value) = elysiumValidateTextCharacter(character) else {
                return XCTFail("expected acceptance for \(character)")
            }
            XCTAssertEqual(value.value, character)
            XCTAssertLessThanOrEqual(value.scalarCount, 64)
            XCTAssertLessThanOrEqual(value.utf8ByteCount, 256)
        }
    }

    func testValidatorRejectsControlsPrivateUseBidiNoncharactersAndInvisibleFormat() {
        let rejected: [Character] = ["\n", "\u{0085}", "\u{E000}",
                                     "\u{061C}", "\u{200E}", "\u{202E}", "\u{2066}",
                                     "\u{200C}", "\u{200D}", "\u{2028}"]
        for value in rejected {
            XCTAssertEqual(elysiumValidateTextCharacter(value), .rejected, "accepted \(value)")
        }
    }

    func testValidatorRejectsScalarAndByteOneOver() {
        let sixtyFour = Character("a" + String(repeating: "\u{301}", count: 63))
        let sixtyFive = Character("a" + String(repeating: "\u{301}", count: 64))
        guard case .accepted = elysiumValidateTextCharacter(sixtyFour) else { return XCTFail() }
        XCTAssertEqual(elysiumValidateTextCharacter(sixtyFive), .rejected)

        let byteEdge = Character("a" + String(repeating: "\u{301}", count: 63))
        XCTAssertLessThanOrEqual(String(byteEdge).utf8.count, 256)
        let oversized = Character("a" + String(repeating: "\u{1AB0}", count: 64))
        XCTAssertEqual(elysiumValidateTextCharacter(oversized), .rejected)
    }

    func testAtomicInsertAndReplaceHonorCharacterAndByteLimits() {
        let limit = ElysiumTextLimit(maximumCharacters: 3, maximumUTF8Bytes: 8)
        var buffer = ElysiumBoundedTextBuffer("a", limit: limit)
        XCTAssertTrue(buffer.insertAtomically("é", atCharacterOffset: 1, limit: limit))
        XCTAssertEqual(buffer.text, "aé")
        XCTAssertFalse(buffer.insertAtomically("界界", atCharacterOffset: 2, limit: limit))
        XCTAssertEqual(buffer.text, "aé")
        XCTAssertFalse(buffer.replaceAtomically("abcd", limit: limit))
        XCTAssertEqual(buffer.text, "aé")
    }

    func testDeleteBackwardRemovesOneExtendedGrapheme() {
        let limit = ElysiumTextLimit(maximumCharacters: 8, maximumUTF8Bytes: 128)
        var buffer = ElysiumBoundedTextBuffer("a👩‍💻é", limit: limit)
        var caret = 2
        XCTAssertTrue(buffer.deleteBackward(atCharacterOffset: &caret))
        XCTAssertEqual(buffer.text, "aé")
        XCTAssertEqual(caret, 1)
    }

    func testValidPrefixStopsAtFirstInvalidCharacter() {
        let limit = ElysiumTextLimit(maximumCharacters: 8, maximumUTF8Bytes: 64)
        var first = ElysiumBoundedTextBuffer("", limit: limit)
        XCTAssertEqual(first.insertValidPrefixAtomically("abc\nignored", atCharacterOffset: 0,
                                                        limit: limit),
                       .accepted(characterCount: 3, utf8ByteCount: 3))
        XCTAssertEqual(first.text, "abc")
        var second = ElysiumBoundedTextBuffer("", limit: limit)
        guard case .accepted = second.insertValidPrefixAtomically(
            "é界👩‍💻", atCharacterOffset: 0, limit: limit) else { return XCTFail() }
        XCTAssertEqual(second.text, "é界👩‍💻")
    }

    func testSignRepairAlwaysReturnsFourBoundedLines() {
        let result = elysiumRepairSignLines(
            ["ok", "toolong", "界", "👩‍💻", "extra"],
            makeWidthStep: { var width = 0; return { character in
                width += String(character).count * 10; return width
            } })
        XCTAssertTrue(result.repaired)
        XCTAssertEqual(result.lines.array.count, 4)
        XCTAssertEqual(result.lines.array[0], "ok")
        XCTAssertEqual(result.lines.array[1], "toolong")
        XCTAssertEqual(result.lines.array[2], "界")
        XCTAssertEqual(result.lines.array[3], "👩‍💻")
    }

    func testSignRepairStopsBeforeInvalidOrWidthOverflow() {
        let result = elysiumRepairSignLines(
            ["abc\nsecret", String(repeating: "x", count: 100)],
            makeWidthStep: { var width = 0; return { _ in width += 8; return width } })
        XCTAssertTrue(result.repaired)
        XCTAssertEqual(result.lines.array[0], "abc")
        XCTAssertEqual(result.lines.array[1].count, 11)
    }

    func testPresentationClockFailsClosedAtOverflow() {
        var clock = ElysiumTextPresentationClock(value: UInt64.max - 1)
        XCTAssertEqual(clock.next(), UInt64.max)
        XCTAssertNil(clock.next())
    }

    func testReadinessRequiresNotificationAndExactPostvalidation() {
        let first = ElysiumTextOwnerToken(screenIdentity: 7, presentationGeneration: 11,
                                         descriptorID: "world.name")
        let other = ElysiumTextOwnerToken(screenIdentity: 7, presentationGeneration: 12,
                                         descriptorID: "world.name")
        var machine = ElysiumTextIngressStateMachine()
        XCTAssertEqual(machine.begin(first, ownerAndResponderAlreadyReady: false), .started)
        XCTAssertTrue(machine.ingressBlocked)
        XCTAssertFalse(machine.isReady(first))
        XCTAssertEqual(machine.begin(first, ownerAndResponderAlreadyReady: false), .coalesced)
        XCTAssertEqual(machine.begin(other, ownerAndResponderAlreadyReady: false), .rejected)
        XCTAssertFalse(machine.complete(first, postvalidated: true))
        XCTAssertTrue(machine.markNotificationDelivered(for: first))
        XCTAssertTrue(machine.complete(first, postvalidated: true))
        XCTAssertTrue(machine.isReady(first))
        XCTAssertEqual(machine.begin(first, ownerAndResponderAlreadyReady: true), .idempotentReady)
        machine.cancel()
        XCTAssertFalse(machine.isReady(first))
    }

    func testReadinessFailureNeverPublishesAndGenerationChangeInvalidates() {
        let token = ElysiumTextOwnerToken(screenIdentity: 1, presentationGeneration: 2,
                                         descriptorID: "chat.input")
        var machine = ElysiumTextIngressStateMachine()
        XCTAssertEqual(machine.begin(token, ownerAndResponderAlreadyReady: false), .started)
        XCTAssertTrue(machine.markNotificationDelivered(for: token))
        XCTAssertFalse(machine.complete(token, postvalidated: false))
        XCTAssertFalse(machine.isReady(token))
        let replacement = ElysiumTextOwnerToken(screenIdentity: 3, presentationGeneration: 4,
                                               descriptorID: "chat.input")
        XCTAssertEqual(machine.begin(replacement, ownerAndResponderAlreadyReady: false), .started)
        machine.cancel(token)
        XCTAssertTrue(machine.ingressBlocked)
        machine.cancel(replacement)
        XCTAssertFalse(machine.ingressBlocked)
    }

    func testVeryLargeProposalAllocatesOnlyDestinationBoundAndRejectsAtomically() {
        let limit = ElysiumTextLimit(maximumCharacters: 64, maximumUTF8Bytes: 256)
        var buffer = ElysiumBoundedTextBuffer("seed", limit: limit)
        let huge = String(repeating: "a", count: 1_000_000)
        XCTAssertEqual(buffer.insertWholeProposalAtomically(
            huge, atCharacterOffset: 4, limit: limit), .rejectedLimit)
        XCTAssertEqual(buffer.text, "seed")
        guard case .accepted(let pasted, _) = buffer.insertValidPrefixAtomically(
            huge, atCharacterOffset: 4, limit: limit) else { return XCTFail() }
        XCTAssertEqual(pasted, 60)
        XCTAssertEqual(buffer.characterCount, 64)
        var firstInvalid = ElysiumBoundedTextBuffer("", limit: limit)
        XCTAssertEqual(firstInvalid.insertValidPrefixAtomically(
            "\n" + huge, atCharacterOffset: 0, limit: limit), .rejectedInvalid)
        XCTAssertEqual(firstInvalid.text, "")
    }

    func testTypedProposalIsWholeAtomicWhilePasteCommitsOnlyValidBoundedPrefix() {
        let limit = ElysiumTextLimit(maximumCharacters: 8, maximumUTF8Bytes: 32)
        var typed = ElysiumBoundedTextBuffer("x", limit: limit)
        XCTAssertEqual(typed.insertWholeProposalAtomically(
            "abc\nignored", atCharacterOffset: 1, limit: limit), .rejectedInvalid)
        XCTAssertEqual(typed.text, "x")
        XCTAssertEqual(typed.insertWholeProposalAtomically(
            String(repeating: "a", count: 8), atCharacterOffset: 1, limit: limit),
                       .rejectedLimit)
        XCTAssertEqual(typed.text, "x")

        var pasted = ElysiumBoundedTextBuffer("x", limit: limit)
        XCTAssertEqual(pasted.insertValidPrefixAtomically(
            "abc\nignored", atCharacterOffset: 1, limit: limit),
                       .accepted(characterCount: 3, utf8ByteCount: 3))
        XCTAssertEqual(pasted.text, "xabc")
    }

    func testEventEnvelopeStopsAtOneOverWithoutTraversingMillionByteSequence() {
        let counter = ByteCounter()
        XCTAssertFalse(elysiumByteSequenceFitsTextEventEnvelope(
            CountingBytes(total: 1_000_000, counter: counter), maximumBytes: 65_536))
        XCTAssertEqual(counter.reads, 65_537)
        let exact = ByteCounter()
        XCTAssertTrue(elysiumByteSequenceFitsTextEventEnvelope(
            CountingBytes(total: 65_536, counter: exact), maximumBytes: 65_536))
        XCTAssertEqual(exact.reads, 65_536)
    }

    func testFocusAdapterBlocksMappedUnmappedAndPasteThroughStatusNotification() {
        let adapter = ElysiumTextFocusTransactionAdapter()
        let token = ElysiumTextOwnerToken(screenIdentity: 4, presentationGeneration: 9,
                                         descriptorID: "sign.editor")
        let other = ElysiumTextOwnerToken(screenIdentity: 4, presentationGeneration: 9,
                                         descriptorID: "chat.input")
        var logicalOwner = false
        var responder = false
        var textMutations = 0
        var clipboardReads = 0
        var fallbacks = 0
        var notifications: [String] = []
        let result = adapter.perform(
            token: token, ownerAndResponderAlreadyReady: false,
            mutateOwner: { logicalOwner = true; return true },
            establishResponder: { responder = true; return true },
            preNotificationPostvalidate: { logicalOwner && responder },
            publishLayout: { notifications.append("layout") },
            publishFocus: { notifications.append("focus") },
            takeStatusAnnouncement: { "Sign text repaired" },
            publishStatusAnnouncement: { status in
                notifications.append(status)
                XCTAssertTrue(adapter.ingressBlocked)
                XCTAssertFalse(adapter.isReady(token))
                for proposal in ["mapped", "unmapped"] {
                    XCTAssertEqual(ElysiumTextEventIngressAdapter.route(
                        proposal: proposal, commandOrControl: false,
                        ingressBlocked: { adapter.ingressBlocked },
                        dispatch: { _ in textMutations += 1; return true }), .blocked)
                }
                XCTAssertEqual(ElysiumTextPasteIngressAdapter.route(
                    ingressBlocked: { adapter.ingressBlocked },
                    captureOwner: { 1 },
                    readBoundedText: { clipboardReads += 1; return "paste" },
                    revalidateOwner: { Optional($0) },
                    dispatch: { _, _ in textMutations += 1; return true }), .blocked)
                let same = adapter.perform(
                    token: token, ownerAndResponderAlreadyReady: false,
                    mutateOwner: { XCTFail(); return false },
                    establishResponder: { XCTFail(); return false },
                    preNotificationPostvalidate: { XCTFail(); return false },
                    publishLayout: { XCTFail() }, publishFocus: { XCTFail() },
                    takeStatusAnnouncement: { XCTFail(); return nil },
                    publishStatusAnnouncement: { _ in XCTFail() },
                    postNotificationPostvalidate: { XCTFail(); return false })
                XCTAssertEqual(same, .coalesced)
                let different = adapter.perform(
                    token: other, ownerAndResponderAlreadyReady: false,
                    mutateOwner: { XCTFail(); return false },
                    establishResponder: { XCTFail(); return false },
                    preNotificationPostvalidate: { XCTFail(); return false },
                    publishLayout: { XCTFail() }, publishFocus: { XCTFail() },
                    takeStatusAnnouncement: { XCTFail(); return nil },
                    publishStatusAnnouncement: { _ in XCTFail() },
                    postNotificationPostvalidate: { XCTFail(); return false })
                XCTAssertEqual(different, .rejected)
                fallbacks += adapter.ingressBlocked ? 0 : 1
            },
            postNotificationPostvalidate: { logicalOwner && responder })
        XCTAssertEqual(result, .committed)
        XCTAssertTrue(adapter.isReady(token))
        XCTAssertEqual(notifications, ["layout", "focus", "Sign text repaired"])
        XCTAssertEqual(textMutations, 0)
        XCTAssertEqual(clipboardReads, 0)
        XCTAssertEqual(fallbacks, 0)
    }

    func testFocusAdapterResponderFailureAndPostNotificationReplacementFailClosed() {
        let token = ElysiumTextOwnerToken(screenIdentity: 1, presentationGeneration: 1,
                                         descriptorID: "world.name")
        var adapter = ElysiumTextFocusTransactionAdapter()
        var notifications = 0
        XCTAssertEqual(adapter.perform(
            token: token, ownerAndResponderAlreadyReady: false,
            mutateOwner: { true }, establishResponder: { false },
            preNotificationPostvalidate: { true },
            publishLayout: { notifications += 1 }, publishFocus: { notifications += 1 },
            takeStatusAnnouncement: { nil }, publishStatusAnnouncement: { _ in notifications += 1 },
            postNotificationPostvalidate: { true }), .failed)
        XCTAssertEqual(notifications, 0)
        XCTAssertFalse(adapter.isReady(token))

        adapter = ElysiumTextFocusTransactionAdapter()
        XCTAssertEqual(adapter.perform(
            token: token, ownerAndResponderAlreadyReady: false,
            mutateOwner: { true }, establishResponder: { true },
            preNotificationPostvalidate: { true },
            publishLayout: { notifications += 1 }, publishFocus: { notifications += 1 },
            takeStatusAnnouncement: { nil }, publishStatusAnnouncement: { _ in notifications += 1 },
            postNotificationPostvalidate: { false }), .failed)
        XCTAssertFalse(adapter.isReady(token))
        XCTAssertFalse(adapter.ingressBlocked)
    }

    func testPasteAdapterOrdersOwnerCaptureReadRevalidationAndDispatch() {
        var order: [String] = []
        XCTAssertEqual(ElysiumTextPasteIngressAdapter.route(
            ingressBlocked: { order.append("blocked"); return false },
            captureOwner: { order.append("capture"); return 7 },
            readBoundedText: { order.append("read"); return "value" },
            revalidateOwner: { value in order.append("revalidate"); return value == 7 ? "target" : nil },
            dispatch: { _, text in order.append("dispatch"); return text == "value" }),
                       .dispatched(accepted: true))
        XCTAssertEqual(order, ["blocked", "capture", "read", "revalidate", "dispatch"])

        order.removeAll()
        XCTAssertEqual(ElysiumTextPasteIngressAdapter.route(
            ingressBlocked: { false }, captureOwner: { Optional<Int>.none },
            readBoundedText: { order.append("read"); return "leak" },
            revalidateOwner: { Optional($0) }, dispatch: { _, _ in true }), .noOwner)
        XCTAssertTrue(order.isEmpty)
    }

    func testActivationCauseAndRetainedAccessibilityIdentityMatrix() {
        XCTAssertEqual(Set(ElysiumTextActivationCause.allCases.filter(\.publishesLayoutChange)),
                       Set([.initialOpen, .implicitOwnerOpen, .screenReveal, .resizeRenewal]))
        let origin = ElysiumTextAccessibilityIdentity(
            screenIdentity: 8, presentationGeneration: 10, descriptorID: "create.worldName")
        XCTAssertTrue(elysiumTextAccessibilityIdentityIsCurrent(origin: origin, current: origin))
        XCTAssertFalse(elysiumTextAccessibilityIdentityIsCurrent(
            origin: origin,
            current: ElysiumTextAccessibilityIdentity(
                screenIdentity: 8, presentationGeneration: 11,
                descriptorID: "create.worldName")))
        XCTAssertFalse(elysiumTextAccessibilityIdentityIsCurrent(
            origin: origin,
            current: ElysiumTextAccessibilityIdentity(
                screenIdentity: 9, presentationGeneration: 10,
                descriptorID: "create.worldName")))
    }

    func testSignEditUsesStatefulFormattingAndFractionalWidthCursor() {
        func cursor() -> (Character) -> Int? {
            var width = 0.0
            var skip = false
            return { character in
                if skip { skip = false; return Int(width.rounded()) }
                if character == "§" { skip = true; return Int(width.rounded()) }
                width += character == "i" ? 2.4 : 7.6
                return Int(width.rounded())
            }
        }
        let repaired = elysiumRepairSignLines(["§aiii", "", "", ""],
                                             makeWidthStep: cursor)
        XCTAssertFalse(repaired.repaired)
        XCTAssertEqual(repaired.lines.array[0], "§aiii")
        let edited = elysiumAppendSignText("W", to: repaired.lines.first,
                                          makeWidthStep: cursor)
        XCTAssertEqual(edited.line.text, "§aiiiW")
        XCTAssertFalse(edited.stoppedForCapacity)
        XCTAssertEqual(elysiumDeleteLastSignCharacter(edited.line).text, "§aiii")
    }

    func testUTF16InsertionAndFiniteFrameClampRejectStaleUnitsAndNonfiniteGeometry() {
        let value = "a👩‍💻\n界"
        XCTAssertEqual(elysiumUTF16InsertionOffset(in: value, characterOffset: 0), 0)
        XCTAssertEqual(elysiumUTF16InsertionOffset(in: value, characterOffset: 2),
                       String("a👩‍💻").utf16.count)
        XCTAssertEqual(elysiumUTF16InsertionOffset(in: value, characterOffset: 3),
                       String("a👩‍💻\n").utf16.count)
        XCTAssertNil(elysiumUTF16InsertionOffset(in: value, characterOffset: 5))

        XCTAssertEqual(elysiumClampTextRect(
            ElysiumTextRect(x: -5, y: 8, width: 20, height: 20),
            to: ElysiumTextRect(x: 0, y: 0, width: 10, height: 10)),
                       ElysiumTextRect(x: 0, y: 8, width: 10, height: 2))
        XCTAssertNil(elysiumClampTextRect(
            ElysiumTextRect(x: .nan, y: 0, width: 1, height: 1),
            to: ElysiumTextRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertNil(elysiumClampTextRect(
            ElysiumTextRect(x: 20, y: 20, width: 1, height: 1),
            to: ElysiumTextRect(x: 0, y: 0, width: 10, height: 10)))
    }

    func testPresentationKeepsCaretVisibleAndClickUsesGraphemeMidpoints() {
        let measure: (String) -> Int = { $0.count * 8 }
        let presentation = elysiumTextPresentation(text: "ab👩‍💻cd", caret: 5,
                                                  visibleStart: 0, maximumWidth: 24,
                                                  measure: measure)
        XCTAssertEqual(presentation.text, "👩‍💻cd")
        XCTAssertEqual(presentation.visibleStart, 2)
        XCTAssertEqual(presentation.caretAdvance, 24)
        XCTAssertEqual(elysiumCaretOffsetForClick(text: "a👩‍💻b", visibleStart: 0,
                                                 clickAdvance: 11, measure: measure), 1)
        XCTAssertEqual(elysiumCaretOffsetForClick(text: "a👩‍💻b", visibleStart: 0,
                                                 clickAdvance: 13, measure: measure), 2)
    }
}
