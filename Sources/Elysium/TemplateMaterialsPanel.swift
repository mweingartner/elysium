import Foundation
import ElysiumCore

/// What the selected template costs, shown in the place-template browser.
///
/// One line under the template's name says whether the player can pay, in words as well as
/// colour. The Materials button (or the M key) swaps the 3D model for the list of what the
/// paste needs and what the player has, with missing materials first. The numbers are read
/// once for each selection: the browser pauses the game, so they cannot change under it.
/// The click in the world decides; on a LAN guest this is advice and the host decides.
final class TemplateMaterialsPanel {
    private(set) var showsList = false
    private var quotedName: String?
    private var quote: TemplateMaterialQuote?
    private var scroll = 0
    private var visibleRows = 1
    let toggle = Button(0, 0, 62, 20, "Materials", {})

    private static let rowHeight = 10.0

    init() {
        toggle.onClick = { [weak self] in self?.toggleList() }
    }

    /// Reads the cost of the selected template when the selection changes. A template that
    /// has not loaded yet has no cost to show.
    func update(name: String?, template: ObjectTemplate?, game: GameCore) {
        guard let name, let template else {
            quotedName = nil
            quote = nil
            showsList = false
            return
        }
        guard quotedName != name else { return }
        quotedName = name
        quote = game.templateMaterialQuote(for: template)
        scroll = 0
        if lines.isEmpty { showsList = false }
    }

    private var lines: [TemplateMaterialQuoteLine] {
        if case .cost(let lines)? = quote { return lines }
        return []
    }

    /// False for an object survival cannot place: the Place button is disabled for it.
    var canPlace: Bool {
        if case .unplaceable? = quote { return false }
        return true
    }

    private func toggleList() {
        guard !lines.isEmpty else { return }
        showsList.toggle()
        scroll = 0
    }

    /// Puts the Materials button on the row of the rotate buttons.
    func layout(x: Double, y: Double) {
        toggle.x = x
        toggle.y = y
        toggle.visible = !lines.isEmpty
        toggle.label = showsList ? "Preview" : "Materials"
    }

    /// The status line. Returns false when there is nothing to say (no template loaded).
    func drawStatus(_ ui: UIManager, x: Double, y: Double, maxWidth: Int) -> Bool {
        guard let quote else { return false }
        let color: String
        switch quote {
        case .free: color = "#c8c8c8"
        case .unplaceable: color = "#ff8080"
        case .cost(let lines): color = lines.contains { $0.missing > 0 } ? "#ff8080" : "#80e080"
        }
        var text = quote.statusText + (lines.isEmpty ? "" : " (M)")
        while textWidth(text) > maxWidth, text.count > 4 { text.removeLast() }
        _ = ui.cv.drawText(text, x, y, 1, color, shadow: false)
        return true
    }

    /// The list of materials in place of the 3D model. Returns false when the model is shown.
    func drawList(_ ui: UIManager, rect: (x: Double, y: Double, w: Double, h: Double)) -> Bool {
        guard showsList, !lines.isEmpty else { return false }
        let cv = ui.cv
        visibleRows = max(1, Int((rect.h - 6) / Self.rowHeight))
        scroll = max(0, min(scroll, max(0, lines.count - visibleRows)))
        for row in 0..<visibleRows {
            let index = scroll + row
            guard index < lines.count else { break }
            let line = lines[index]
            let y = rect.y + 4 + Double(row) * Self.rowHeight
            var text = "\(line.have)/\(line.need) \(itemDef(line.itemID).displayName)"
            if line.missing > 0 { text = "Missing \(line.missing): " + text }
            while textWidth(text) > Int(rect.w - 14), text.count > 4 { text.removeLast() }
            _ = cv.drawText(text, rect.x + 5, y, 1, line.missing > 0 ? "#ff8080" : "#e0e0e0", shadow: false)
        }
        if lines.count > visibleRows {
            let trackH = rect.h - 4
            let thumbH = max(10, trackH * Double(visibleRows) / Double(lines.count))
            let thumbY = rect.y + 2 + (trackH - thumbH) * Double(scroll) / Double(max(1, lines.count - visibleRows))
            cv.setFill("#555555")
            cv.fillRect(rect.x + rect.w - 5, rect.y + 2, 3, trackH)
            cv.setFill("#f0f0f0")
            cv.fillRect(rect.x + rect.w - 5, thumbY, 3, thumbH)
        }
        return true
    }

    /// M shows or hides the list; Page Up and Page Down scroll it.
    func onKey(_ key: String) -> Bool {
        switch key {
        case "KeyM":
            guard !lines.isEmpty else { return false }
            toggleList()
            return true
        case "PageUp" where showsList:
            scroll = max(0, scroll - visibleRows)
            return true
        case "PageDown" where showsList:
            scroll = max(0, min(lines.count - visibleRows, scroll + visibleRows))
            return true
        default:
            return false
        }
    }

    /// The wheel scrolls the list while the pointer is over it.
    func onWheel(_ ui: UIManager, _ dy: Double, over rect: (x: Double, y: Double, w: Double, h: Double)) -> Bool {
        guard showsList, lines.count > visibleRows,
              ui.mouseX >= rect.x, ui.mouseX < rect.x + rect.w, ui.mouseY >= rect.y, ui.mouseY < rect.y + rect.h
        else { return false }
        scroll = max(0, min(lines.count - visibleRows, scroll + (dy > 0 ? 1 : -1)))
        return true
    }

    /// The cost as a sentence, and the list rows when the list is shown.
    func accessibilityDescriptors(frame: (x: Double, y: Double, w: Double, h: Double)) -> [TextEntryAccessibilityDescriptor] {
        guard let quote else { return [] }
        var descriptors = [TextEntryAccessibilityDescriptor(
            id: "templates.cost", role: .staticText, label: quote.sentence, value: "",
            help: lines.isEmpty ? "" : "Press M to list the materials.",
            frame: (frame.x, frame.y + 26, frame.w, 10), enabled: true, focused: false,
            insertionUTF16Offset: nil, focusable: false)]
        guard showsList else { return descriptors }
        descriptors.append(TextEntryAccessibilityDescriptor(
            id: "templates.materials", role: .list, label: "Materials", value: "\(lines.count) kinds",
            help: "Page Up and Page Down scroll the list.",
            frame: (frame.x + 6, frame.y + 40, frame.w - 12, frame.h - 48), enabled: true, focused: false,
            insertionUTF16Offset: nil, focusable: false))
        for (index, line) in lines.enumerated() {
            let row = max(0, min(visibleRows - 1, index - scroll))
            descriptors.append(TextEntryAccessibilityDescriptor(
                id: "templates.materials.\(line.itemID)", role: .listItem,
                label: itemDef(line.itemID).displayName,
                value: "Needs \(line.need), you have \(line.have)" + (line.missing > 0 ? ", missing \(line.missing)" : ""),
                help: "", frame: (frame.x + 6, frame.y + 44 + Double(row) * Self.rowHeight, frame.w - 12, Self.rowHeight),
                enabled: true, focused: false, insertionUTF16Offset: nil, focusable: false,
                parentID: "templates.materials"))
        }
        return descriptors
    }
}
