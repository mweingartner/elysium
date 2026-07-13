import Foundation

package struct ElysiumTextLimit: Equatable, Sendable {
    package let maximumCharacters: Int
    package let maximumUTF8Bytes: Int

    package init(maximumCharacters: Int, maximumUTF8Bytes: Int) {
        self.maximumCharacters = max(0, maximumCharacters)
        self.maximumUTF8Bytes = max(0, maximumUTF8Bytes)
    }
}

package struct ElysiumValidatedCharacter: Equatable, Sendable {
    package let value: Character
    package let scalarCount: Int
    package let utf8ByteCount: Int
}

package enum ElysiumTextValidationResult: Equatable, Sendable {
    case accepted(ElysiumValidatedCharacter)
    case rejected
}

package enum ElysiumTextInsertResult: Equatable, Sendable {
    case accepted(characterCount: Int, utf8ByteCount: Int)
    case rejectedInvalid
    case rejectedLimit
}

package let elysiumTextEventMaximumUTF8Bytes = 65_536

/// A nonallocating, bounded envelope check. Iteration stops at byte limit + 1;
/// callers never compute the full byte count of an untrusted event String.
package func elysiumByteSequenceFitsTextEventEnvelope<Bytes: Sequence>(
    _ bytes: Bytes, maximumBytes: Int = elysiumTextEventMaximumUTF8Bytes
) -> Bool where Bytes.Element == UInt8 {
    guard maximumBytes >= 0 else { return false }
    var count = 0
    for _ in bytes {
        count += 1
        if count > maximumBytes { return false }
    }
    return true
}

package func elysiumTextFitsEventEnvelope(
    _ text: String, maximumBytes: Int = elysiumTextEventMaximumUTF8Bytes
) -> Bool {
    elysiumByteSequenceFitsTextEventEnvelope(text.utf8, maximumBytes: maximumBytes)
}

package enum ElysiumTextEventIngressResult: Equatable, Sendable {
    case blocked
    case rejectedModifiers
    case rejectedEnvelope
    case dispatched(accepted: Bool)
}

/// Shared executable adapter used by mapped and unmapped AppKit character
/// routes. Readiness is checked before any proposal byte or dispatch callback.
package enum ElysiumTextEventIngressAdapter {
    package static func route(
        proposal: String?, commandOrControl: Bool,
        ingressBlocked: () -> Bool,
        dispatch: (String) -> Bool
    ) -> ElysiumTextEventIngressResult {
        if ingressBlocked() { return .blocked }
        guard !commandOrControl else { return .rejectedModifiers }
        guard let proposal, !proposal.isEmpty,
              elysiumTextFitsEventEnvelope(proposal) else { return .rejectedEnvelope }
        return .dispatched(accepted: dispatch(proposal))
    }
}

package enum ElysiumTextPasteIngressResult: Equatable, Sendable {
    case blocked
    case noOwner
    case noText
    case staleOwner
    case dispatched(accepted: Bool)
}

/// Owner capture precedes clipboard access, and a second owner validation
/// precedes dispatch. This is the production Pasteboard-read suppression seam.
package enum ElysiumTextPasteIngressAdapter {
    package static func route<Capture, Target>(
        ingressBlocked: () -> Bool,
        captureOwner: () -> Capture?,
        readBoundedText: () -> String?,
        revalidateOwner: (Capture) -> Target?,
        dispatch: (Target, String) -> Bool
    ) -> ElysiumTextPasteIngressResult {
        if ingressBlocked() { return .blocked }
        guard let capture = captureOwner() else { return .noOwner }
        guard let text = readBoundedText() else { return .noText }
        guard let target = revalidateOwner(capture) else { return .staleOwner }
        return .dispatched(accepted: dispatch(target, text))
    }
}

@inline(__always)
private func isNoncharacter(_ value: UInt32) -> Bool {
    (value >= 0xFDD0 && value <= 0xFDEF) || (value & 0xFFFE == 0xFFFE)
}

@inline(__always)
private func isBidiControl(_ value: UInt32) -> Bool {
    value == 0x061C || value == 0x200E || value == 0x200F ||
        (value >= 0x202A && value <= 0x202E) ||
        (value >= 0x2066 && value <= 0x2069)
}

package func elysiumValidateTextCharacter(_ value: Character) -> ElysiumTextValidationResult {
    var scalarCount = 0
    var byteCount = 0
    var containsZWJ = false
    var containsNonFormat = false

    for scalar in value.unicodeScalars {
        scalarCount += 1
        if scalarCount > 64 { return .rejected }
        let scalarBytes = scalar.utf8.count
        let nextBytes = byteCount.addingReportingOverflow(scalarBytes)
        if nextBytes.overflow || nextBytes.partialValue > 256 { return .rejected }
        byteCount = nextBytes.partialValue

        let code = scalar.value
        if code <= 0x1F || (code >= 0x7F && code <= 0x9F) ||
            code == 0x2028 || code == 0x2029 ||
            isNoncharacter(code) || isBidiControl(code) {
            return .rejected
        }
        switch scalar.properties.generalCategory {
        case .privateUse, .unassigned:
            return .rejected
        case .format:
            if code == 0x200D {
                containsZWJ = true
            } else {
                return .rejected
            }
        default:
            containsNonFormat = true
        }
    }
    guard scalarCount > 0, !containsZWJ || containsNonFormat else { return .rejected }
    return .accepted(ElysiumValidatedCharacter(value: value, scalarCount: scalarCount,
                                               utf8ByteCount: byteCount))
}

package struct ElysiumBoundedTextBuffer: Equatable, Sendable {
    package private(set) var text: String
    package private(set) var characterCount: Int
    package private(set) var utf8ByteCount: Int

    package init(_ text: String = "", limit: ElysiumTextLimit) {
        self.text = ""
        characterCount = 0
        utf8ByteCount = 0
        _ = replaceAtomically(text, limit: limit)
    }

    package mutating func replaceAtomically(_ proposal: String, limit: ElysiumTextLimit) -> Bool {
        guard let counts = Self.validatedCounts(proposal, limit: limit) else { return false }
        text = proposal
        characterCount = counts.characters
        utf8ByteCount = counts.bytes
        return true
    }

    package mutating func insertAtomically(_ proposal: String, atCharacterOffset offset: Int,
                                           limit: ElysiumTextLimit) -> Bool {
        if case .accepted = insertWholeProposalAtomically(
            proposal, atCharacterOffset: offset, limit: limit) { return true }
        return false
    }

    package mutating func insertWholeProposalAtomically(
        _ proposal: String, atCharacterOffset offset: Int, limit: ElysiumTextLimit
    ) -> ElysiumTextInsertResult {
        guard offset >= 0, offset <= characterCount else { return .rejectedLimit }
        let remainingCharacters = limit.maximumCharacters - characterCount
        let remainingBytes = limit.maximumUTF8Bytes - utf8ByteCount
        guard remainingCharacters >= 0, remainingBytes >= 0 else { return .rejectedLimit }
        var characters = 0
        var bytes = 0
        for character in proposal {
            guard case .accepted(let accepted) = elysiumValidateTextCharacter(character) else {
                return .rejectedInvalid
            }
            let nextCharacters = characters.addingReportingOverflow(1)
            let nextBytes = bytes.addingReportingOverflow(accepted.utf8ByteCount)
            guard !nextCharacters.overflow, !nextBytes.overflow,
                  nextCharacters.partialValue <= remainingCharacters,
                  nextBytes.partialValue <= remainingBytes else { return .rejectedLimit }
            characters = nextCharacters.partialValue
            bytes = nextBytes.partialValue
        }
        let index = text.index(text.startIndex, offsetBy: offset)
        text.insert(contentsOf: proposal, at: index)
        characterCount += characters
        utf8ByteCount += bytes
        return .accepted(characterCount: characters, utf8ByteCount: bytes)
    }

    /// Streams at most the destination's remaining capacity, stops at the first invalid Character,
    /// and commits the valid prefix once without revalidation or an over-cap intermediate.
    package mutating func insertValidPrefixAtomically(
        _ proposal: String, atCharacterOffset offset: Int, limit: ElysiumTextLimit
    ) -> ElysiumTextInsertResult {
        guard offset >= 0, offset <= characterCount else { return .rejectedLimit }
        let remainingCharacters = limit.maximumCharacters - characterCount
        let remainingBytes = limit.maximumUTF8Bytes - utf8ByteCount
        guard remainingCharacters >= 0, remainingBytes >= 0 else { return .rejectedLimit }
        var prefix = ""
        prefix.reserveCapacity(min(remainingBytes, 4_096))
        var characters = 0
        var bytes = 0
        for character in proposal {
            guard case .accepted(let accepted) = elysiumValidateTextCharacter(character) else {
                if prefix.isEmpty { return .rejectedInvalid }
                break
            }
            let nextCharacters = characters.addingReportingOverflow(1)
            let nextBytes = bytes.addingReportingOverflow(accepted.utf8ByteCount)
            guard !nextCharacters.overflow, !nextBytes.overflow else { return .rejectedLimit }
            guard nextCharacters.partialValue <= remainingCharacters,
                  nextBytes.partialValue <= remainingBytes else {
                if prefix.isEmpty { return .rejectedLimit }
                break
            }
            prefix.append(character)
            characters = nextCharacters.partialValue
            bytes = nextBytes.partialValue
        }
        guard !prefix.isEmpty else { return .rejectedInvalid }
        let index = text.index(text.startIndex, offsetBy: offset)
        text.insert(contentsOf: prefix, at: index)
        characterCount += characters
        utf8ByteCount += bytes
        return .accepted(characterCount: characters, utf8ByteCount: bytes)
    }

    package mutating func deleteBackward(atCharacterOffset offset: inout Int) -> Bool {
        guard offset > 0, offset <= characterCount else { return false }
        let index = text.index(text.startIndex, offsetBy: offset - 1)
        let removed = text[index]
        text.remove(at: index)
        offset -= 1
        characterCount -= 1
        utf8ByteCount -= removed.utf8.count
        return true
    }

    private static func validatedCounts(_ proposal: String, limit: ElysiumTextLimit)
        -> (characters: Int, bytes: Int)? {
        var characters = 0
        var bytes = 0
        for character in proposal {
            guard case .accepted(let accepted) = elysiumValidateTextCharacter(character) else {
                return nil
            }
            let nextCharacters = characters.addingReportingOverflow(1)
            let nextBytes = bytes.addingReportingOverflow(accepted.utf8ByteCount)
            guard !nextCharacters.overflow, !nextBytes.overflow,
                  nextCharacters.partialValue <= limit.maximumCharacters,
                  nextBytes.partialValue <= limit.maximumUTF8Bytes else { return nil }
            characters = nextCharacters.partialValue
            bytes = nextBytes.partialValue
        }
        return (characters, bytes)
    }
}

package struct ElysiumTextPresentationClock: Equatable, Sendable {
    package private(set) var value: UInt64 = 0
    package init(value: UInt64 = 0) { self.value = value }
    package mutating func next() -> UInt64? {
        let result = value.addingReportingOverflow(1)
        guard !result.overflow, result.partialValue != 0 else { return nil }
        value = result.partialValue
        return value
    }
}

package struct ElysiumTextOwnerToken: Equatable, Sendable {
    package let screenIdentity: UInt64
    package let presentationGeneration: UInt64
    package let descriptorID: String
    package init(screenIdentity: UInt64, presentationGeneration: UInt64, descriptorID: String) {
        self.screenIdentity = screenIdentity
        self.presentationGeneration = presentationGeneration
        self.descriptorID = descriptorID
    }
}

package enum ElysiumTextFocusBeginResult: Equatable, Sendable {
    case started
    case idempotentReady
    case coalesced
    case rejected
}

package enum ElysiumTextActivationCause: CaseIterable, Hashable, Sendable {
    case primaryClick
    case initialOpen
    case implicitOwnerOpen
    case screenReveal
    case applicationReactivation
    case resizeRenewal

    package var publishesLayoutChange: Bool {
        switch self {
        case .initialOpen, .implicitOwnerOpen, .screenReveal, .resizeRenewal: return true
        case .primaryClick, .applicationReactivation: return false
        }
    }
}

/// Pure audited state kernel used by UIManager's AppKit transaction adapter.
package struct ElysiumTextIngressStateMachine: Equatable, Sendable {
    private enum Phase: Equatable, Sendable {
        case idle
        case focusing(ElysiumTextOwnerToken, notificationDelivered: Bool)
    }
    private var phase: Phase = .idle
    package private(set) var readiness: ElysiumTextOwnerToken?

    package init() {}

    package mutating func begin(_ token: ElysiumTextOwnerToken,
                                ownerAndResponderAlreadyReady: Bool) -> ElysiumTextFocusBeginResult {
        switch phase {
        case .idle:
            if readiness == token && ownerAndResponderAlreadyReady { return .idempotentReady }
            readiness = nil
            phase = .focusing(token, notificationDelivered: false)
            return .started
        case .focusing(let current, _):
            return current == token ? .coalesced : .rejected
        }
    }

    package mutating func markNotificationDelivered(for token: ElysiumTextOwnerToken) -> Bool {
        guard case .focusing(let current, false) = phase, current == token else { return false }
        phase = .focusing(token, notificationDelivered: true)
        return true
    }

    package mutating func complete(_ token: ElysiumTextOwnerToken,
                                   postvalidated: Bool) -> Bool {
        guard case .focusing(let current, true) = phase, current == token else { return false }
        readiness = postvalidated ? token : nil
        phase = .idle
        return postvalidated
    }

    package mutating func cancel(_ token: ElysiumTextOwnerToken? = nil) {
        if let token, case .focusing(let current, _) = phase, current != token { return }
        readiness = nil
        phase = .idle
    }

    package func isReady(_ token: ElysiumTextOwnerToken) -> Bool {
        phase == .idle && readiness == token
    }

    package var ingressBlocked: Bool {
        if case .focusing = phase { return true }
        return false
    }
}

package enum ElysiumTextFocusTransactionResult: Equatable, Sendable {
    case committed
    case idempotentReady
    case coalesced
    case rejected
    case failed
}

/// Executable production adapter for the complete notification-ordered focus
/// transaction. UIManager supplies AppKit/screen closures; tests exercise the
/// exact reentrancy, responder, status, and postvalidation ordering here.
package final class ElysiumTextFocusTransactionAdapter {
    private var machine = ElysiumTextIngressStateMachine()

    package init() {}

    package var ingressBlocked: Bool { machine.ingressBlocked }
    package func isReady(_ token: ElysiumTextOwnerToken) -> Bool { machine.isReady(token) }
    package func cancel(_ token: ElysiumTextOwnerToken? = nil) { machine.cancel(token) }

    package func perform(
        token: ElysiumTextOwnerToken,
        ownerAndResponderAlreadyReady: Bool,
        mutateOwner: () -> Bool,
        establishResponder: () -> Bool,
        preNotificationPostvalidate: () -> Bool,
        publishLayout: () -> Void,
        publishFocus: () -> Void,
        takeStatusAnnouncement: () -> String?,
        publishStatusAnnouncement: (String) -> Void,
        postNotificationPostvalidate: () -> Bool
    ) -> ElysiumTextFocusTransactionResult {
        switch machine.begin(token, ownerAndResponderAlreadyReady: ownerAndResponderAlreadyReady) {
        case .idempotentReady: return .idempotentReady
        case .coalesced: return .coalesced
        case .rejected: return .rejected
        case .started: break
        }
        var committed = false
        defer { if !committed { machine.cancel(token) } }
        guard mutateOwner(), establishResponder(), preNotificationPostvalidate() else {
            return .failed
        }
        publishLayout()
        publishFocus()
        if let status = takeStatusAnnouncement() { publishStatusAnnouncement(status) }
        guard machine.markNotificationDelivered(for: token),
              postNotificationPostvalidate(),
              machine.complete(token, postvalidated: true) else { return .failed }
        committed = true
        return .committed
    }
}

package struct ElysiumTextAccessibilityIdentity: Equatable, Sendable {
    package let screenIdentity: UInt64
    package let presentationGeneration: UInt64
    package let descriptorID: String

    package init(screenIdentity: UInt64, presentationGeneration: UInt64, descriptorID: String) {
        self.screenIdentity = screenIdentity
        self.presentationGeneration = presentationGeneration
        self.descriptorID = descriptorID
    }
}

package func elysiumTextAccessibilityIdentityIsCurrent(
    origin: ElysiumTextAccessibilityIdentity,
    current: ElysiumTextAccessibilityIdentity
) -> Bool {
    origin == current && origin.screenIdentity != 0 && origin.presentationGeneration != 0
}

package struct ElysiumTextPresentation: Equatable, Sendable {
    package let text: String
    package let visibleStart: Int
    package let caretOffset: Int
    package let caretAdvance: Int
}

package func elysiumTextPresentation(text: String, caret: Int, visibleStart: Int,
                                    maximumWidth: Int, measure: (String) -> Int)
    -> ElysiumTextPresentation {
    let characters = Array(text)
    let boundedCaret = max(0, min(caret, characters.count))
    let width = max(0, maximumWidth)
    var start = max(0, min(visibleStart, boundedCaret))
    while start < boundedCaret && measure(String(characters[start..<boundedCaret])) > width {
        start += 1
    }
    var end = max(start, boundedCaret)
    while end < characters.count {
        guard measure(String(characters[start...end])) <= width else { break }
        end += 1
    }
    let visible = String(characters[start..<end])
    let advance = measure(String(characters[start..<boundedCaret]))
    return ElysiumTextPresentation(text: visible, visibleStart: start,
                                  caretOffset: boundedCaret, caretAdvance: max(0, advance))
}

package func elysiumCaretOffsetForClick(text: String, visibleStart: Int, clickAdvance: Double,
                                       measure: (String) -> Int) -> Int {
    let characters = Array(text)
    let start = max(0, min(visibleStart, characters.count))
    let click = max(0, clickAdvance)
    var candidate = start
    var prior = 0.0
    for offset in start..<characters.count {
        let width = Double(measure(String(characters[start...offset])))
        if click < (prior + width) / 2 { break }
        candidate = offset + 1
        prior = width
    }
    return candidate
}

package func elysiumUTF16InsertionOffset(in value: String, characterOffset: Int) -> Int? {
    guard characterOffset >= 0, characterOffset <= value.count else { return nil }
    let index = value.index(value.startIndex, offsetBy: characterOffset)
    return value[..<index].utf16.count
}

package struct ElysiumTextRect: Equatable, Sendable {
    package let x: Double
    package let y: Double
    package let width: Double
    package let height: Double
    package init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
}

package func elysiumClampTextRect(_ value: ElysiumTextRect,
                                 to bounds: ElysiumTextRect) -> ElysiumTextRect? {
    let numbers = [value.x, value.y, value.width, value.height,
                   bounds.x, bounds.y, bounds.width, bounds.height]
    guard numbers.allSatisfy(\.isFinite), value.width > 0, value.height > 0,
          bounds.width > 0, bounds.height > 0 else { return nil }
    let left = max(value.x, bounds.x)
    let bottom = max(value.y, bounds.y)
    let right = min(value.x + value.width, bounds.x + bounds.width)
    let top = min(value.y + value.height, bounds.y + bounds.height)
    guard [left, bottom, right, top].allSatisfy(\.isFinite), right > left, top > bottom else {
        return nil
    }
    return ElysiumTextRect(x: left, y: bottom, width: right - left, height: top - bottom)
}

package enum ElysiumSignLineIndex: Int, CaseIterable, Sendable {
    case first, second, third, fourth
}

package struct ElysiumSignLine: Equatable, Sendable {
    package private(set) var text: String
    package private(set) var utf8ByteCount: Int
    fileprivate init(validatedText text: String = "") {
        self.text = text
        utf8ByteCount = text.utf8.count
    }
    package static var empty: ElysiumSignLine { ElysiumSignLine() }
}

package struct ElysiumFourSignLines: Equatable, Sendable {
    package var first: ElysiumSignLine
    package var second: ElysiumSignLine
    package var third: ElysiumSignLine
    package var fourth: ElysiumSignLine

    package init(first: ElysiumSignLine = .empty, second: ElysiumSignLine = .empty,
                 third: ElysiumSignLine = .empty, fourth: ElysiumSignLine = .empty) {
        self.first = first; self.second = second; self.third = third; self.fourth = fourth
    }
    package func line(_ index: ElysiumSignLineIndex) -> ElysiumSignLine {
        switch index { case .first: first; case .second: second; case .third: third; case .fourth: fourth }
    }
    package mutating func set(_ line: ElysiumSignLine, at index: ElysiumSignLineIndex) {
        switch index { case .first: first = line; case .second: second = line; case .third: third = line; case .fourth: fourth = line }
    }
    package var array: [String] { ElysiumSignLineIndex.allCases.map { line($0).text } }
}

package struct ElysiumSignRepairResult: Equatable, Sendable {
    package let lines: ElysiumFourSignLines
    package let repaired: Bool
}

package func elysiumRepairSignLines(
    _ source: [String]?, makeWidthStep: () -> (Character) -> Int?
) -> ElysiumSignRepairResult {
    var output = ElysiumFourSignLines()
    var repaired = source == nil
    var iterator = source?.makeIterator()
    for lineIndex in ElysiumSignLineIndex.allCases {
        guard let raw = iterator?.next() else { repaired = true; continue }
        var text = ""
        var bytes = 0
        let widthStep = makeWidthStep()
        for character in raw {
            guard case .accepted(let accepted) = elysiumValidateTextCharacter(character) else {
                repaired = true; break
            }
            let nextBytes = bytes.addingReportingOverflow(accepted.utf8ByteCount)
            guard !nextBytes.overflow, nextBytes.partialValue <= 4096,
                  let nextWidth = widthStep(character), nextWidth < 90 else {
                repaired = true; break
            }
            text.append(character)
            bytes = nextBytes.partialValue
        }
        output.set(ElysiumSignLine(validatedText: text), at: lineIndex)
    }
    if iterator?.next() != nil { repaired = true }
    return ElysiumSignRepairResult(lines: output, repaired: repaired)
}

package struct ElysiumSignEditResult: Equatable, Sendable {
    package let line: ElysiumSignLine
    package let acceptedCharacterCount: Int
    package let stoppedForCapacity: Bool
    package let stoppedForInvalidCharacter: Bool
}

package func elysiumAppendSignText(
    _ proposal: String, to line: ElysiumSignLine,
    makeWidthStep: () -> (Character) -> Int?
) -> ElysiumSignEditResult {
    let widthStep = makeWidthStep()
    for existing in line.text { guard widthStep(existing) != nil else {
        return ElysiumSignEditResult(line: line, acceptedCharacterCount: 0,
                                    stoppedForCapacity: true,
                                    stoppedForInvalidCharacter: false)
    } }
    var result = line.text
    var bytes = line.utf8ByteCount
    var count = 0
    for character in proposal {
        guard case .accepted(let accepted) = elysiumValidateTextCharacter(character) else {
            return ElysiumSignEditResult(
                line: ElysiumSignLine(validatedText: result), acceptedCharacterCount: count,
                stoppedForCapacity: false, stoppedForInvalidCharacter: true)
        }
        let nextBytes = bytes.addingReportingOverflow(accepted.utf8ByteCount)
        guard !nextBytes.overflow, nextBytes.partialValue <= 4_096,
              let width = widthStep(character), width < 90 else {
            return ElysiumSignEditResult(
                line: ElysiumSignLine(validatedText: result), acceptedCharacterCount: count,
                stoppedForCapacity: true, stoppedForInvalidCharacter: false)
        }
        result.append(character)
        bytes = nextBytes.partialValue
        count += 1
    }
    return ElysiumSignEditResult(line: ElysiumSignLine(validatedText: result),
                                acceptedCharacterCount: count,
                                stoppedForCapacity: false,
                                stoppedForInvalidCharacter: false)
}

package func elysiumDeleteLastSignCharacter(_ line: ElysiumSignLine) -> ElysiumSignLine {
    guard !line.text.isEmpty else { return line }
    return ElysiumSignLine(validatedText: String(line.text.dropLast()))
}
