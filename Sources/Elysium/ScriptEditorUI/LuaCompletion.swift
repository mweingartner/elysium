// LuaCompletion.swift — native SwiftUI script editor (Stage A). Context-aware autocomplete: what
// to suggest depends on what precedes the caret (after `:` -> handle methods, after `.` on a
// handle/`.attrs` -> attribute names, inside an event-name argument -> the `EventKind` catalog,
// else Lua keywords + globals). The popup itself is Hype's `CompletionPopup.swift`
// (`CompletionViewController`, a plain `NSTableView` in a scroll view with ↑/↓/Return/Esc) ported
// verbatim — Hype built it but never wired it up; this is that wiring, driven from
// `LuaCodeTextView`'s coordinator on every keystroke.

import AppKit
import ElysiumCore

// MARK: - context classification

enum LuaCompletionContext: Equatable {
    /// After `object:` — the handle's callable methods.
    case methods
    /// After `object.` (or `object.attrs.`) — handle properties + this target kind's attribute
    /// names (`AttributeRegistry.descriptors(for:)`).
    case attributes
    /// Inside the first string-literal argument of `on(`/`subscribe(`/`emit(`, or a handler's
    /// `event` field — the `EventKind` catalog.
    case eventName
    /// Anywhere else — Lua keywords, script globals, and the implicit call parameters.
    case keywordsAndGlobals
}

enum LuaCompletion {
    /// design.md/architecture doc's own corpus lists (kept exactly as specified so the palette,
    /// the completion popup, and any future documentation reference the same words).
    static let globals = [
        "on", "subscribe", "every", "after", "wait", "emit", "tick", "rng", "say", "sound",
        "particles", "dim", "register",
    ]
    static let tableCalls = ["objects.get", "objects.find", "objects.block", "ai.ask", "ai.await"]
    static let handleMethods = [
        "exists", "get", "set", "scripts", "define", "attach", "detach", "setBlock", "breakBlock",
    ]
    static let handleProperties = ["ref", "kind", "name", "attrs"]
    static let implicitArgs = ["self", "world", "player", "ev"]

    /// The v1 event catalog (`EventKind.swift`'s own static constants) plus a handful of common
    /// custom-event examples — mirrored here as plain strings because `EventKind` does not expose
    /// an enumerable case list (it is a validated-string type, not a closed Swift `enum`).
    static let eventKindCatalog = [
        "attribute.changed",
        "block.placed", "block.broken", "block.replaced", "block.changed", "block.used",
        "block.neighborChanged", "block.scheduledTick",
        "entity.spawned", "entity.removed", "entity.damaged", "entity.died", "entity.healed",
        "entity.interacted", "entity.targetChanged",
        "player.joined", "player.left", "player.respawned", "player.dimensionChanged",
        "player.pickedUp", "player.dropped", "player.attacked", "player.slept", "player.leveled",
        "player.advancement",
        "dim.dayPhaseChanged", "dim.weatherChanged",
        "world.gameruleChanged", "world.difficultyChanged",
        "explosion", "load", "unload", "timer.fired", "ai.replied",
        "script.faulted", "script.overBudget",
    ]

    /// Classifies the completion context from the characters immediately preceding `cursorIndex`
    /// in `source` (a plain linear scan backward — sources are capped at 16 KiB, so this is cheap
    /// even on every keystroke).
    static func context(source: String, cursorIndex: Int) -> LuaCompletionContext {
        let chars = Array(source)
        guard cursorIndex > 0, cursorIndex <= chars.count else { return .keywordsAndGlobals }
        // Walk back over the identifier prefix being typed, if any.
        var i = cursorIndex
        while i > 0, isIdentifierChar(chars[i - 1]) { i -= 1 }
        guard i > 0 else { return .keywordsAndGlobals }
        let prior = chars[i - 1]
        if prior == ":" { return .methods }
        if prior == "." { return .attributes }
        if isInsideEventArgument(chars, upTo: i) { return .eventName }
        return .keywordsAndGlobals
    }

    /// Best-effort detection of "the word being typed is an event-name argument": the nearest
    /// unmatched `(` back from `index` is immediately preceded by `on`, `subscribe`, or `emit`,
    /// or the current line reads `event = <partial>` / `event:` (the handler-mode toolbar field
    /// mirrors this same word, so scripts that spell it inline get the same suggestions).
    private static func isInsideEventArgument(_ chars: [Character], upTo index: Int) -> Bool {
        var depth = 0
        var i = index
        while i > 0 {
            i -= 1
            let c = chars[i]
            if c == ")" { depth += 1 }
            else if c == "(" {
                if depth == 0 {
                    var j = i
                    while j > 0, chars[j - 1] == " " { j -= 1 }
                    let wordEnd = j
                    var wordStart = j
                    while wordStart > 0, isIdentifierChar(chars[wordStart - 1]) { wordStart -= 1 }
                    let word = String(chars[wordStart..<wordEnd])
                    return word == "on" || word == "subscribe" || word == "emit"
                }
                depth -= 1
            } else if c == "\n" {
                break
            }
        }
        return false
    }

    private static func isIdentifierChar(_ c: Character) -> Bool {
        c == "_" || c.isLetter || c.isNumber
    }

    /// The identifier (possibly empty) immediately before `cursorIndex` — the text the popup
    /// should treat as already-typed and replace on accept.
    static func currentPrefix(source: String, cursorIndex: Int) -> (text: String, range: NSRange) {
        let chars = Array(source)
        guard cursorIndex > 0, cursorIndex <= chars.count else {
            return ("", NSRange(location: cursorIndex, length: 0))
        }
        var i = cursorIndex
        while i > 0, isIdentifierChar(chars[i - 1]) { i -= 1 }
        return (String(chars[i..<cursorIndex]), NSRange(location: i, length: cursorIndex - i))
    }

    /// Candidate list for `context`, filtered by `prefix` (case-insensitive "starts with"),
    /// capped at 20 so the popup never grows unbounded. `targetKind` supplies the object-specific
    /// attribute names for `.attributes`.
    static func suggestions(context: LuaCompletionContext, prefix: String, targetKind: ObjectKind) -> [String] {
        let pool: [String]
        switch context {
        case .methods:
            pool = handleMethods
        case .attributes:
            let attrs = AttributeRegistry.descriptors(for: targetKind).map(\.canonical)
            pool = handleProperties + attrs
        case .eventName:
            pool = eventKindCatalog
        case .keywordsAndGlobals:
            pool = Array(LuaSyntaxColoring.keywords).sorted() + globals + tableCalls + implicitArgs
        }
        guard !prefix.isEmpty else { return Array(pool.sorted().prefix(20)) }
        let lower = prefix.lowercased()
        return pool
            .filter { $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower }
            .sorted()
            .prefix(20)
            .map { $0 }
    }
}

// MARK: - popup (ported from Hype's `Hype/Views/CompletionPopup.swift`, wired up here)

/// A simple table-based popup for code completion suggestions. Ported near-verbatim from Hype's
/// `CompletionViewController` — Hype defined this but never presented it from a live text view;
/// `LuaCodeTextView`'s coordinator is what actually shows/hides it via an `NSPopover`.
final class CompletionViewController: NSViewController {
    var suggestions: [String] = [] {
        didSet {
            tableView?.reloadData()
            if !suggestions.isEmpty { tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        }
    }
    var onSelect: ((String) -> Void)?
    var onDismiss: (() -> Void)?
    private var tableView: NSTableView?

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 150))
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("suggestion"))
        column.width = 210
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.rowHeight = 20
        table.backgroundColor = .clear
        table.target = self
        table.doubleAction = #selector(rowDoubleClicked)
        scroll.documentView = table
        self.tableView = table
        self.view = scroll
    }

    @objc func rowDoubleClicked() {
        accept(row: tableView?.selectedRow ?? -1)
    }

    private func accept(row: Int) {
        guard row >= 0, row < suggestions.count else { return }
        onSelect?(suggestions[row])
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: // Return / numpad Enter
            accept(row: tableView?.selectedRow ?? 0)
        case 53: // Escape
            onDismiss?()
        case 125: // down
            let next = min((tableView?.selectedRow ?? -1) + 1, suggestions.count - 1)
            tableView?.selectRowIndexes(IndexSet(integer: max(0, next)), byExtendingSelection: false)
            tableView?.scrollRowToVisible(max(0, next))
        case 126: // up
            let next = max((tableView?.selectedRow ?? 0) - 1, 0)
            tableView?.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            tableView?.scrollRowToVisible(next)
        default:
            super.keyDown(with: event)
        }
    }
}

extension CompletionViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        suggestions.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        let cell = NSTextField(labelWithString: suggestions[row])
        cell.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return cell
    }
}
