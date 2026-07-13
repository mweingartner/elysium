import Foundation
import CryptoKit

public struct SavedWorldAuthorityRow: Sendable, Equatable {
    public let storedID: String
    public let json: String
    public let lastPlayed: Double
    public let rowDigest: Data

    public init(storedID: String, json: String, lastPlayed: Double, rowDigest: Data) {
        self.storedID = storedID; self.json = json
        self.lastPlayed = lastPlayed; self.rowDigest = rowDigest
    }
}

public struct SavedWorldAuthoritySnapshot: Sendable, Equatable {
    public let rows: [SavedWorldAuthorityRow]
    public let collectionDigest: Data
    public let aggregateRawBytes: Int

    public init(rows: [SavedWorldAuthorityRow], collectionDigest: Data,
                aggregateRawBytes: Int) {
        self.rows = rows; self.collectionDigest = collectionDigest
        self.aggregateRawBytes = aggregateRawBytes
    }
}

public struct SavedWorldDeleteExpectation: Sendable, Equatable {
    public let storedID: String
    public let rowDigest: Data
    public init(storedID: String, rowDigest: Data) {
        self.storedID = storedID; self.rowDigest = rowDigest
    }
}

public struct SavedWorldDeleteRequest: Sendable, Equatable {
    public let expectedCollectionDigest: Data
    public let expectations: [SavedWorldDeleteExpectation]
    public init(expectedCollectionDigest: Data, expectations: [SavedWorldDeleteExpectation]) {
        self.expectedCollectionDigest = expectedCollectionDigest
        self.expectations = expectations
    }
}

public struct SavedWorldDeleteReceipt: Sendable, Equatable {
    public let preAuthorityDigest: Data
    public let postAuthorityDigest: Data
    public let unrelatedIdentityDigest: Data
    public let deletedWorldCount: Int
    public init(preAuthorityDigest: Data, postAuthorityDigest: Data,
                unrelatedIdentityDigest: Data, deletedWorldCount: Int) {
        self.preAuthorityDigest = preAuthorityDigest
        self.postAuthorityDigest = postAuthorityDigest
        self.unrelatedIdentityDigest = unrelatedIdentityDigest
        self.deletedWorldCount = deletedWorldCount
    }
}

public struct SavedWorldDeleteRecoveryAuthority: Sendable, Equatable {
    /// Opaque, process-local handle identity. No authority bytes or durable
    /// receipt material are exposed outside ElysiumCore.
    let handleID: UUID
    let requestIdentity: Data
    let selectedWorldIDs: [String]

    init(handleID: UUID = UUID(), requestIdentity: Data, selectedWorldIDs: [String]) {
        self.handleID = handleID
        self.requestIdentity = requestIdentity
        self.selectedWorldIDs = selectedWorldIDs
    }
}

public enum SavedWorldDeleteOutcome: Sendable, Equatable {
    case direct(SavedWorldDeleteReceipt)
    case recovered(SavedWorldDeleteReceipt)
    case provenPrecommitFailure
    case stale
    case terminalRecovery(SavedWorldDeleteRecoveryAuthority)
    case terminalIntegrity
}

/// A bounded presentation-only rendering of an untrusted saved-world name.
/// Formatting markers and controls are expanded to visible ASCII escapes so
/// canvas text and Accessibility receive the same inert value.
public func savedWorldDisplayName(_ raw: String) -> String {
    var result = ""
    result.reserveCapacity(min(256, raw.utf8.count))
    for scalar in raw.unicodeScalars.prefix(64) {
        let fragment: String
        switch scalar.value {
        case 0x00A7: fragment = "\\u{00A7}"
        case 0x00...0x1F, 0x7F...0x9F, 0x2028, 0x2029:
            fragment = String(format: "\\u{%04X}", scalar.value)
        default:
            fragment = scalar.properties.generalCategory == .format
                ? String(format: "\\u{%04X}", scalar.value)
                : String(scalar)
        }
        guard result.utf8.count + fragment.utf8.count <= 512 else { break }
        result += fragment
    }
    return result.isEmpty ? "Unnamed World" : result
}

public enum SavedWorldSelectionError: Error, Equatable {
    case invalidSnapshot
    case limitExceeded
    case staleSelection
}

public struct CheckedSavedWorldRow {
    public let record: WorldRecord
    public let storedID: String
    public let rowDigest: Data
}

public struct CheckedSavedWorldSnapshot {
    public static let maximumWorlds = 4_096
    public let rows: [CheckedSavedWorldRow]
    public let collectionDigest: Data
    public let authoritySnapshot: SavedWorldAuthoritySnapshot

    public init(authoritySnapshot: SavedWorldAuthoritySnapshot) throws {
        guard authoritySnapshot.rows.count <= Self.maximumWorlds,
              authoritySnapshot.collectionDigest.count == 32 else {
            throw SavedWorldSelectionError.limitExceeded
        }
        var decoded: [CheckedSavedWorldRow] = []
        decoded.reserveCapacity(authoritySnapshot.rows.count)
        var ids = Set<String>()
        for row in authoritySnapshot.rows {
            guard ids.insert(row.storedID).inserted,
                  row.storedID.utf8.count <= 256,
                  row.rowDigest.count == 32,
                  let bytes = row.json.data(using: .utf8),
                  let record = try? JSONDecoder().decode(WorldRecord.self, from: bytes),
                  record.id == row.storedID,
                  record.lastPlayed.bitPattern == row.lastPlayed.bitPattern,
                  record.name.count <= 64, record.name.utf8.count <= 4_096 else {
                throw SavedWorldSelectionError.invalidSnapshot
            }
            decoded.append(CheckedSavedWorldRow(
                record: record, storedID: row.storedID, rowDigest: row.rowDigest))
        }
        guard decoded.count == authoritySnapshot.rows.count else {
            throw SavedWorldSelectionError.invalidSnapshot
        }
        decoded.sort {
            if $0.record.lastPlayed != $1.record.lastPlayed {
                return $0.record.lastPlayed > $1.record.lastPlayed
            }
            return Data($0.storedID.utf8).lexicographicallyPrecedes(Data($1.storedID.utf8))
        }
        rows = decoded
        collectionDigest = authoritySnapshot.collectionDigest
        self.authoritySnapshot = authoritySnapshot
    }

    public var orderedIDs: [String] { rows.map(\.storedID) }

    public func deleteRequest(selectedIDs: Set<String>) throws
        -> SavedWorldDeleteRequest {
        guard !selectedIDs.isEmpty, selectedIDs.count <= Self.maximumWorlds else {
            throw SavedWorldSelectionError.staleSelection
        }
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.storedID, $0.rowDigest) })
        let ordered = selectedIDs.sorted {
            Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8))
        }
        let expectations = try ordered.map { id -> SavedWorldDeleteExpectation in
            guard let digest = byID[id] else { throw SavedWorldSelectionError.staleSelection }
            return SavedWorldDeleteExpectation(storedID: id, rowDigest: digest)
        }
        return SavedWorldDeleteRequest(
            expectedCollectionDigest: collectionDigest, expectations: expectations)
    }
}

public enum SavedWorldSelectionGesture: Equatable {
    case plain
    case toggle
    case range
    case extendRange
}

public struct SavedWorldSelectionState: Sendable, Equatable {
    public private(set) var selectedIDs: Set<String> = []
    public private(set) var focusedID: String?
    public private(set) var rangeAnchorID: String?
    public private(set) var orderedIDs: [String] = []

    public init() {}

    public mutating func refresh(orderedIDs newOrder: [String]) {
        let oldOrder = orderedIDs
        let oldFocusIndex = focusedID.flatMap { oldOrder.firstIndex(of: $0) }
        orderedIDs = newOrder
        let membership = Set(newOrder)
        selectedIDs.formIntersection(membership)
        if let focusedID, membership.contains(focusedID) {
            self.focusedID = focusedID
        } else if !newOrder.isEmpty {
            let desired = min(oldFocusIndex ?? 0, newOrder.count - 1)
            focusedID = newOrder[desired]
        } else {
            focusedID = nil
        }
        if let rangeAnchorID, !membership.contains(rangeAnchorID) {
            self.rangeAnchorID = focusedID
        }
    }

    public mutating func select(id: String, gesture: SavedWorldSelectionGesture) {
        guard let target = orderedIDs.firstIndex(of: id) else { return }
        focusedID = id
        switch gesture {
        case .plain:
            selectedIDs = [id]
            rangeAnchorID = id
        case .toggle:
            if selectedIDs.contains(id) { selectedIDs.remove(id) }
            else { selectedIDs.insert(id) }
            rangeAnchorID = id
        case .range, .extendRange:
            let anchor = rangeAnchorID.flatMap { orderedIDs.firstIndex(of: $0) } ?? target
            let rangeIDs = Set(orderedIDs[min(anchor, target)...max(anchor, target)])
            if gesture == .range { selectedIDs = rangeIDs }
            else { selectedIDs.formUnion(rangeIDs) }
            if rangeAnchorID == nil { rangeAnchorID = id }
        }
    }

    public mutating func selectAll() { selectedIDs = Set(orderedIDs) }
    public mutating func clearAll() { selectedIDs.removeAll(keepingCapacity: true) }

    public mutating func moveFocus(delta: Int, extendRange: Bool, focusOnly: Bool = false) {
        guard !orderedIDs.isEmpty else { return }
        let old = focusedID.flatMap { orderedIDs.firstIndex(of: $0) } ?? 0
        let next = max(0, min(orderedIDs.count - 1, old + delta))
        let id = orderedIDs[next]
        if focusOnly { focusedID = id; return }
        select(id: id, gesture: extendRange ? .range : .plain)
    }

    /// Moves only the retained row focus. Accessibility focus must never
    /// manufacture or replace destructive selection authority.
    @discardableResult
    public mutating func focus(id: String) -> Bool {
        guard orderedIDs.contains(id) else { return false }
        focusedID = id
        return true
    }

    public mutating func toggleFocused() {
        guard let focusedID else { return }
        select(id: focusedID, gesture: .toggle)
    }
}

/// The exact selection-dependent semantics published for the saved-world
/// Accessibility tree. Keeping this projection beside the selection reducer
/// makes canvas input and retained Accessibility describe one state.
public struct SavedWorldSelectionAccessibilitySnapshot: Sendable, Equatable {
    public let bulkActionID: String
    public let bulkActionLabel: String
    public let bulkActionEnabled: Bool
    public let playEnabled: Bool
    public let deleteEnabled: Bool
    private let selectedIDs: Set<String>

    public init(selection: SavedWorldSelectionState) {
        let hasRows = !selection.orderedIDs.isEmpty
        let allSelected = hasRows
            && selection.selectedIDs.count == selection.orderedIDs.count
            && selection.orderedIDs.allSatisfy(selection.selectedIDs.contains)
        bulkActionID = allSelected ? "worlds.clearAll" : "worlds.selectAll"
        bulkActionLabel = allSelected ? "Clear All" : "Select All"
        bulkActionEnabled = hasRows
        playEnabled = selection.selectedIDs.count == 1
        deleteEnabled = !selection.selectedIDs.isEmpty
        selectedIDs = selection.selectedIDs
    }

    public func rowSelected(_ storedID: String) -> Bool {
        selectedIDs.contains(storedID)
    }

    public func rowValue(_ storedID: String) -> String {
        rowSelected(storedID) ? "Selected" : "Not selected"
    }
}

public struct SavedWorldSelectionLayout: Sendable, Equatable {
    public struct Rect: Sendable, Equatable {
        public let x: Double, y: Double, width: Double, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }
    public let toolbar: Rect
    public let list: Rect
    public let visibleCompleteRows: Int
    public let primaryButtons: [Rect]
    public let backButton: Rect
    public let statusY: Double

    public init(width: Double, height: Double) {
        let center = floor(width / 2)
        toolbar = Rect(x: center - 154, y: 22, width: 308, height: 20)
        let primaryY = height - 82
        let listTop = 46.0
        let available = max(30, primaryY - 6 - listTop)
        visibleCompleteRows = max(1, Int(floor(available / 30)))
        list = Rect(x: center - 154, y: listTop, width: 308,
                    height: Double(visibleCompleteRows) * 30)
        primaryButtons = (0..<3).map {
            Rect(x: center - 154 + Double($0) * 104, y: primaryY,
                 width: 100, height: 20)
        }
        backButton = Rect(x: center - 100, y: primaryY + 24, width: 200, height: 20)
        statusY = primaryY + 48
    }
}

/// Deterministic geometry for the destructive confirmation and recovery modal.
/// The compact 360 x 224 surface is the reference contract; larger surfaces
/// retain the same bounded panel while centering it in the available canvas.
public struct SavedWorldDeleteModalLayout: Sendable, Equatable {
    public let panel: SavedWorldSelectionLayout.Rect
    public let title: SavedWorldSelectionLayout.Rect
    public let warning: SavedWorldSelectionLayout.Rect
    public let names: SavedWorldSelectionLayout.Rect
    public let status: SavedWorldSelectionLayout.Rect
    public let leftButton: SavedWorldSelectionLayout.Rect
    public let rightButton: SavedWorldSelectionLayout.Rect
    public let singleButton: SavedWorldSelectionLayout.Rect

    public init(width: Double, height: Double) {
        let panelWidth = min(312, max(0, width - 48))
        let panelHeight = min(168, max(0, height - 56))
        let panelX = floor((width - panelWidth) / 2)
        let panelY = floor((height - panelHeight) / 2)
        panel = .init(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
        title = .init(x: panelX + 12, y: panelY + 12,
                      width: max(0, panelWidth - 24), height: 10)
        warning = .init(x: panelX + 12, y: panelY + 28,
                        width: max(0, panelWidth - 24), height: 10)
        names = .init(x: panelX + 12, y: panelY + 52,
                      width: max(0, panelWidth - 24), height: 62)
        status = .init(x: panelX + 12, y: panelY + 118,
                       width: max(0, panelWidth - 24), height: 10)
        leftButton = .init(x: panelX + 38, y: panelY + 138,
                           width: 100, height: 20)
        rightButton = .init(x: panelX + 174, y: panelY + 138,
                            width: 100, height: 20)
        singleButton = .init(x: panelX + floor((panelWidth - 100) / 2),
                             y: panelY + 138, width: 100, height: 20)
    }
}

/// Bounded one-shot gate for genuine AppKit pointer activation. NSEvent event
/// numbers are monotonic within a window; accepting only a strictly newer
/// number rejects copied/replayed events without retaining an unbounded set.
public struct SavedWorldPointerEventConsumption: Sendable, Equatable {
    private var screenIdentity: UInt64 = 0
    private var windowNumber: Int = 0
    private var lastEventNumber: Int = -1

    public init() {}

    public mutating func consume(
        screenIdentity: UInt64, windowNumber: Int, eventNumber: Int
    ) -> Bool {
        guard screenIdentity > 0, windowNumber > 0, eventNumber >= 0 else { return false }
        if self.screenIdentity != screenIdentity || self.windowNumber != windowNumber {
            self.screenIdentity = screenIdentity
            self.windowNumber = windowNumber
            lastEventNumber = -1
        }
        guard eventNumber > lastEventNumber else { return false }
        lastEventNumber = eventNumber
        return true
    }
}

@MainActor
public final class SavedWorldMaintenanceCoordinator {
    public struct Token: Sendable, Equatable {
        public let value: UInt64
        fileprivate init(value: UInt64) { self.value = value }
    }
    public struct DeleteAdmission: Sendable, Equatable {
        let token: Token
        let requestIdentity: Data
        let screenIdentity: UInt64
        let launchContextIdentity: UUID
        fileprivate init(token: Token, requestIdentity: Data,
                         screenIdentity: UInt64, launchContextIdentity: UUID) {
            self.token = token; self.requestIdentity = requestIdentity
            self.screenIdentity = screenIdentity
            self.launchContextIdentity = launchContextIdentity
        }
    }
    private var next: UInt64 = 0
    private var active: Token?
    private var admitted = false

    public nonisolated init() {}
    public var isHeld: Bool { active != nil }
    public var activeToken: Token? { active }

    public func acquire() -> Token? {
        guard active == nil, next < UInt64.max else { return nil }
        next += 1
        let token = Token(value: next)
        active = token
        admitted = false
        return token
    }

    public func revalidate(_ token: Token) -> Bool { active == token }
    public func admitDelete(
        _ token: Token, requestIdentity: Data,
        screenIdentity: UInt64, launchContextIdentity: UUID
    ) -> DeleteAdmission? {
        guard active == token, !admitted, requestIdentity.count == 32,
              screenIdentity > 0 else { return nil }
        admitted = true
        return DeleteAdmission(
            token: token, requestIdentity: requestIdentity,
            screenIdentity: screenIdentity,
            launchContextIdentity: launchContextIdentity)
    }
    public func release(_ token: Token) {
        if active == token { active = nil; admitted = false }
    }
}

/// Opaque, one-shot storage-safe delete/recovery owner. It retains only the
/// immutable admitted request, SaveDB, and context identities; worker threads
/// never read mutable GameCore or LAN state. Recovery authority is retained in
/// this bounded single slot rather than in a screen closure.
public final class SavedWorldDeleteOperation: @unchecked Sendable {
    let token: SavedWorldMaintenanceCoordinator.Token
    let request: SavedWorldDeleteRequest
    let requestIdentity: Data
    let screenIdentity: UInt64
    let launchContextIdentity: UUID
    let selectedWorldIDs: [String]
    private let db: SaveDB
    private let lock = NSLock()
    private var consumed = false
    private var recoveryAuthority: SavedWorldDeleteRecoveryAuthority?
    private var pendingCompletion: SavedWorldDeleteOutcome?
    private var recoveryInFlight = false

    init(db: SaveDB, request: SavedWorldDeleteRequest,
         admission: SavedWorldMaintenanceCoordinator.DeleteAdmission) {
        self.db = db
        self.request = request
        token = admission.token
        requestIdentity = admission.requestIdentity
        screenIdentity = admission.screenIdentity
        launchContextIdentity = admission.launchContextIdentity
        selectedWorldIDs = request.expectations.map(\.storedID)
    }

    public func execute() -> SavedWorldDeleteOutcome {
        lock.lock()
        guard !consumed else { lock.unlock(); return .stale }
        consumed = true
        lock.unlock()
        let outcome = db.deleteWorldsChecked(request)
        lock.lock()
        if case .terminalRecovery(let authority) = outcome { recoveryAuthority = authority }
        pendingCompletion = outcome
        lock.unlock()
        return outcome
    }

    public func recover() -> SavedWorldDeleteOutcome {
        lock.lock()
        guard let authority = recoveryAuthority,
              !recoveryInFlight, pendingCompletion == nil else {
            lock.unlock(); return .terminalIntegrity
        }
        recoveryInFlight = true
        lock.unlock()
        let outcome = db.recoverWorldsChecked(authority)
        lock.lock()
        switch outcome {
        case .direct, .recovered, .provenPrecommitFailure:
            recoveryAuthority = nil
        case .terminalRecovery(let next):
            recoveryAuthority = next
        case .stale, .terminalIntegrity:
            break
        }
        pendingCompletion = outcome
        recoveryInFlight = false
        lock.unlock()
        return outcome
    }

    /// Main-actor completion may consume only the exact latest result emitted
    /// by this operation. This prevents a caller from synthesizing a success
    /// classification or replaying omission retirement.
    func claimCompletion(_ outcome: SavedWorldDeleteOutcome) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let pending = pendingCompletion,
              securelyMatches(pending, outcome) else { return false }
        pendingCompletion = nil
        return true
    }

    private func securelyMatches(
        _ lhs: SavedWorldDeleteOutcome, _ rhs: SavedWorldDeleteOutcome
    ) -> Bool {
        func receiptsMatch(
            _ lhs: SavedWorldDeleteReceipt, _ rhs: SavedWorldDeleteReceipt
        ) -> Bool {
            lhs.deletedWorldCount == rhs.deletedWorldCount
                && savedWorldConstantTimeEqual32(
                    lhs.preAuthorityDigest, rhs.preAuthorityDigest)
                && savedWorldConstantTimeEqual32(
                    lhs.postAuthorityDigest, rhs.postAuthorityDigest)
                && savedWorldConstantTimeEqual32(
                    lhs.unrelatedIdentityDigest, rhs.unrelatedIdentityDigest)
        }
        switch (lhs, rhs) {
        case (.direct(let left), .direct(let right)),
             (.recovered(let left), .recovered(let right)):
            return receiptsMatch(left, right)
        case (.provenPrecommitFailure, .provenPrecommitFailure),
             (.stale, .stale), (.terminalIntegrity, .terminalIntegrity):
            return true
        case (.terminalRecovery(let left), .terminalRecovery(let right)):
            return left.handleID == right.handleID
                && left.selectedWorldIDs == right.selectedWorldIDs
                && savedWorldConstantTimeEqual32(
                    left.requestIdentity, right.requestIdentity)
        default:
            return false
        }
    }
}

public func savedWorldDeleteRequestIdentity(_ request: SavedWorldDeleteRequest) -> Data {
    var digest = SHA256()
    digest.update(data: Data("Elysium.SavedWorldDelete.UIRequest.v1".utf8))
    func frame(_ data: Data) {
        var size = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &size) { digest.update(data: Data($0)) }
        digest.update(data: data)
    }
    frame(request.expectedCollectionDigest)
    var count = UInt64(request.expectations.count).bigEndian
    withUnsafeBytes(of: &count) { digest.update(data: Data($0)) }
    for expectation in request.expectations {
        frame(Data(expectation.storedID.utf8)); frame(expectation.rowDigest)
    }
    return Data(digest.finalize())
}

/// Bounded canonical admission shape mirrored from the storage adapter. This
/// runs before MainActor request hashing so a forged App-side request cannot
/// force unbounded work or acquire destructive authority.
public func savedWorldDeleteRequestHasBoundedCanonicalShape(
    _ request: SavedWorldDeleteRequest
) -> Bool {
    guard request.expectedCollectionDigest.count == 32,
          (1...CheckedSavedWorldSnapshot.maximumWorlds).contains(
            request.expectations.count) else { return false }
    var encodedBytes = 32 + 8
    var previousID: String?
    for expectation in request.expectations {
        let idBytes = expectation.storedID.utf8.count
        guard (1...256).contains(idBytes), expectation.rowDigest.count == 32 else {
            return false
        }
        if let previousID,
           !Data(previousID.utf8).lexicographicallyPrecedes(
            Data(expectation.storedID.utf8)) { return false }
        let (next, overflow) = encodedBytes.addingReportingOverflow(8 + idBytes + 32)
        guard !overflow, next <= 1_310_720 else { return false }
        encodedBytes = next
        previousID = expectation.storedID
    }
    return true
}

public enum SavedWorldOutcomeReductionPhase: UInt8, Sendable, Equatable {
    case prechecking
    case confirming
    case deleting
    case terminal
    case terminalReloading
}

/// Immutable main-actor admission identity for one saved-world outcome. The
/// App rebuilds the current value from its live phase before Core may claim a
/// result, so resize or any other presentation callback cannot stale-claim it.
public struct SavedWorldOutcomeReductionBinding: Sendable {
    public let screenIdentity: UInt64
    public let operationGeneration: UInt64
    public let phase: SavedWorldOutcomeReductionPhase
    public let leaseToken: UInt64
    public let requestIdentity: Data
    public let launchContextIdentity: UUID

    public init(
        screenIdentity: UInt64, operationGeneration: UInt64,
        phase: SavedWorldOutcomeReductionPhase, leaseToken: UInt64,
        requestIdentity: Data, launchContextIdentity: UUID
    ) {
        self.screenIdentity = screenIdentity
        self.operationGeneration = operationGeneration
        self.phase = phase
        self.leaseToken = leaseToken
        self.requestIdentity = requestIdentity
        self.launchContextIdentity = launchContextIdentity
    }
}

public func savedWorldOutcomeReductionMatches(
    expected: SavedWorldOutcomeReductionBinding,
    current: SavedWorldOutcomeReductionBinding
) -> Bool {
    expected.screenIdentity > 0
        && expected.screenIdentity == current.screenIdentity
        && expected.operationGeneration > 0
        && expected.operationGeneration == current.operationGeneration
        && expected.phase == current.phase
        && expected.leaseToken > 0
        && expected.leaseToken == current.leaseToken
        && expected.launchContextIdentity == current.launchContextIdentity
        && savedWorldConstantTimeEqual32(
            expected.requestIdentity, current.requestIdentity)
}

/// Fixed-length security comparison shared by App and Core admission paths.
/// Wrong-length inputs are rejected without prefix acceptance.
public func savedWorldConstantTimeEqual32(_ lhs: Data, _ rhs: Data) -> Bool {
    LANV6Crypto.constantTimeEqual32(lhs, rhs)
}

public func savedWorldDestructiveAccessibilityID(
    kind: String, screenIdentity: UInt64, actionGeneration: UInt64,
    leaseToken: UInt64, requestIdentity: Data
) -> String? {
    let allowed = Set([
        "loadRetry", "beginDelete", "cancel", "delete", "retry", "terminalReload",
    ])
    guard allowed.contains(kind), screenIdentity > 0, actionGeneration > 0,
          requestIdentity.isEmpty || requestIdentity.count == 32 else { return nil }
    let requestTag = requestIdentity.prefix(8)
        .map { String(format: "%02x", $0) }.joined()
    return "worlds.action.\(kind).\(screenIdentity).\(actionGeneration).\(leaseToken).\(requestTag)"
}
