// InspectorScreen.swift — scripting-ui-and-replication (change 3), extended by
// lan-client-parity (change 4). design.md §12: "the Object Inspector (F3 summary now;
// `/inspect` screen modeled on `TemplateBrowserScreen`)". A read-only object browser —
// attributes, scripts, and event subscriptions of one target — with jump-to-editor for an
// attached script. Host and LAN-client worlds share this one screen: a guest's attributes and
// script metadata (name/mode/enabled, never source) come from the read-only replicated mirror
// (`LANMultiplayerManager.shared.mirroredAttributes(for:)`/`.mirroredScripts(for:)`), never
// `AttributeStore`/`ScriptStore` directly. Subscriptions are not replicated (design.md §11 scopes
// guest parity to attrs/scripts) — that section still says so plainly for a guest.

import ElysiumCore

/// One line in the Inspector's scrollable body, tagged so a click/Enter can act on it (jump to
/// the editor for a script row) without re-parsing display text.
private enum InspectorRow {
    case header(String)
    case attribute(text: String)
    case script(name: String, text: String)
    case subscription(text: String)
    case note(String)

    var text: String {
        switch self {
        case .header(let t), .note(let t), .subscription(let t), .attribute(let t): return t
        case .script(_, let t): return t
        }
    }

    var scriptName: String? {
        if case .script(let name, _) = self { return name }
        return nil
    }
}

/// Pure data-provider half of the screen — a free function so it can be unit-tested (`Tests/
/// ElysiumResourcePackTests`) without constructing a `Screen`/`UIManager`. Never mutates
/// anything; every read goes through the exact same paths `/inspect` and `/script` already use
/// on a host, or the replicated mirror on a guest.
func inspectorRows(target: ObjectRef, game: GameCore) -> [String] {
    inspectorRowsDetailed(target: target, game: game).map(\.text)
}

private func inspectorRowsDetailed(target: ObjectRef, game: GameCore) -> [InspectorRow] {
    let context = game.scriptingCommandContext()
    var rows: [InspectorRow] = []
    rows.append(.header("\(target.canonical) (\(target.kind.rawValue)) \(context.graph.displayName(of: target))"))

    rows.append(.header("Attributes"))
    if game.isLANClientWorld {
        if let mirrored = LANMultiplayerManager.shared.mirroredAttributes(for: target), !mirrored.isEmpty {
            for name in mirrored.keys.sorted() {
                rows.append(.attribute(text: "  \(name) = \(AttrValueCodec.encode(mirrored[name]!)) (replicated, read-only)"))
            }
        } else {
            rows.append(.note("  (nothing replicated for this object yet)"))
        }
    } else {
        let attrs = context.store.list(target)
        if attrs.isEmpty {
            rows.append(.note("  (none)"))
        } else {
            for (name, value, readonly) in attrs {
                rows.append(.attribute(text: "  \(name) = \(AttrValueCodec.encode(value))" + (readonly ? " (readonly)" : "")))
            }
        }
    }

    rows.append(.header("Scripts"))
    if game.isLANClientWorld {
        // lan-client-parity (change 4), design.md §11: replicated script *metadata* only
        // (name/mode/enabled) — never source; `.script(name:, text:)` still carries the name so
        // clicking a row still jumps to the editor (which itself reads only the same metadata
        // for a guest — see `ScriptEditorScreen.initScreen`).
        if let scripts = LANMultiplayerManager.shared.mirroredScripts(for: target), !scripts.isEmpty {
            for s in scripts.sorted(by: { $0.name < $1.name }) {
                let text = "  \(s.name) [\(s.mode)]\(s.enabled ? "" : " (disabled)") (replicated, read-only)"
                rows.append(.script(name: s.name, text: text))
            }
        } else {
            rows.append(.note("  (nothing replicated for this object yet)"))
        }
    } else {
        let scripts = context.scriptStore.list(target)
        if scripts.isEmpty {
            rows.append(.note("  (none)"))
        } else {
            for s in scripts {
                let text = "  \(s.name) [\(s.mode.rawValue)]\(s.enabled ? "" : " (disabled)")"
                    + (s.lastError.map { " — \($0)" } ?? "")
                rows.append(.script(name: s.name, text: text))
            }
        }
    }

    rows.append(.header("Subscriptions"))
    if game.isLANClientWorld {
        rows.append(.note("  (not available to guests until LAN client parity)"))
    } else {
        let subs = context.eventBus.listSubscriptions(for: target)
        if subs.isEmpty {
            rows.append(.note("  (none)"))
        } else {
            for sub in subs {
                rows.append(.subscription(text: "  #\(sub.id) \(sub.event.rawValue) on \(sub.target.displayText)"))
            }
        }
    }
    return rows
}

final class InspectorScreen: Screen {
    /// `/inspect`'s own default-alias cycle (design.md §12's target aliases): looking/cursor
    /// first (falling back to self when nothing is under the crosshair, exactly like
    /// `ScriptingCommands.runInspect`), then self/player/world on explicit Retarget presses.
    private static let aliases = ["looking", "self", "player", "world"]
    private var aliasIndex = 0
    private var target: ObjectRef?
    private var rows: [InspectorRow] = []
    private var selected = 0
    private var scroll = 0
    private weak var editButton: Button?
    private var statusMessage: String?

    override init() {
        super.init()
        pausesGame = true
    }

    private func frame(_ ui: UIManager) -> (x: Double, y: Double, w: Double, h: Double) {
        let w = max(280, min(420, ui.width - 24))
        let h = max(160, min(260, ui.height - 40))
        return (((ui.width - w) / 2).rounded(.down), ((ui.height - h) / 2).rounded(.down), w, h)
    }

    private func resolveTarget(_ game: GameCore) -> ObjectRef? {
        let context = game.scriptingCommandContext()
        let alias = Self.aliases[aliasIndex]
        if alias == "looking", context.target.resolve(alias: "looking") == nil {
            return context.target.resolve(alias: "self")
        }
        return context.target.resolve(alias: alias)
    }

    private func refresh(_ game: GameCore) {
        guard let resolved = resolveTarget(game) else {
            target = nil
            rows = [.note("nothing under the cursor")]
            selected = 0
            scroll = 0
            editButton?.enabled = false
            return
        }
        target = resolved
        rows = inspectorRowsDetailed(target: resolved, game: game)
        selected = min(selected, max(0, rows.count - 1))
        scroll = 0
        editButton?.enabled = rows.indices.contains(selected) && rows[selected].scriptName != nil
    }

    override func initScreen(_ ui: UIManager, _ game: GameCore) {
        refresh(game)
        let f = frame(ui)
        buttons.append(Button(f.x + 8, f.y + f.h - 26, 70, 20, "Retarget", { [weak self, weak game] in
            guard let self, let game else { return }
            self.aliasIndex = (self.aliasIndex + 1) % Self.aliases.count
            self.refresh(game)
        }))
        let edit = Button(f.x + 84, f.y + f.h - 26, 90, 20, "Edit Script", { [weak self, weak ui, weak game] in
            guard let self, let ui, let game, let target = self.target,
                  self.rows.indices.contains(self.selected), let name = self.rows[self.selected].scriptName
            else { return }
            ui.closeTop(game)
            ui.open(ScriptEditorScreen(target: target, existingName: name), game)
            game.host?.capturePointer()
        })
        edit.enabled = rows.indices.contains(selected) && rows[selected].scriptName != nil
        editButton = edit
        buttons.append(edit)
        buttons.append(Button(f.x + f.w - 66, f.y + 6, 56, 20, "Close", { [weak ui, weak game] in
            guard let ui, let game else { return }
            ui.closeTop(game)
            game.host?.capturePointer()
        }))
    }

    private func visibleRows(_ f: (x: Double, y: Double, w: Double, h: Double)) -> Int {
        max(1, Int((f.h - 56) / 9))
    }

    private func maxScroll(_ visible: Int) -> Int {
        max(0, rows.count - visible)
    }

    override func draw(_ ui: UIManager, _ game: GameCore, _ partial: Double) {
        let f = frame(ui)
        ui.drawDarkBg(0.58)
        ui.drawPanel(f.x, f.y, f.w, f.h)
        ui.cv.drawText("Inspector", f.x + 16, f.y + 2, 1, "#3f3f3f", shadow: false)
        let visible = visibleRows(f)
        scroll = min(scroll, maxScroll(visible))
        var y = f.y + 18
        for (offset, row) in rows.enumerated().dropFirst(scroll).prefix(visible) {
            let isSelected = offset == selected
            let color: String
            switch row {
            case .header: color = "#3f3f3f"
            case .script: color = isSelected ? "#1c6fb0" : "#204070"
            case .note: color = "#808080"
            default: color = isSelected ? "#1c6fb0" : "#404040"
            }
            let prefix = isSelected && row.scriptName != nil ? "> " : "  "
            ui.cv.drawText(prefix + row.text, f.x + 16, y, 1, color, shadow: false)
            y += 9
        }
        if let statusMessage {
            ui.cv.drawText(statusMessage, f.x + 16, f.y + f.h - 38, 1, "#a02020", shadow: false)
        }
        ui.drawButtons(self)
    }

    override func onWheel(_ ui: UIManager, _ game: GameCore, _ dy: Double) -> Bool {
        let visible = visibleRows(frame(ui))
        scroll = max(0, min(maxScroll(visible), scroll + (dy > 0 ? 1 : -1)))
        return true
    }

    override func onKey(_ ui: UIManager, _ game: GameCore, _ key: String) -> Bool {
        switch key {
        case "ArrowDown":
            selected = min(rows.count - 1, selected + 1)
            editButton?.enabled = rows.indices.contains(selected) && rows[selected].scriptName != nil
            return true
        case "ArrowUp":
            selected = max(0, selected - 1)
            editButton?.enabled = rows.indices.contains(selected) && rows[selected].scriptName != nil
            return true
        case "Escape":
            ui.closeTop(game)
            game.host?.capturePointer()
            return true
        default:
            return false
        }
    }
}
