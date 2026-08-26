// LuaCompletionPopup.swift — keyboard- and VoiceOver-accessible native completion picker with a
// documentation pane. It renders deterministic items only; AI proposals use separate ghost text.

import AppKit

/// A completion flyout must remain visible without ever becoming the key window. `NSPopover`
/// owns its presentation window and may take key status as soon as it contains selectable views,
/// which interrupts ordinary typing in the source editor. This nonactivating child panel makes
/// the invariant explicit: printable and command key events continue to reach `LuaEditorTextView`.
@MainActor
final class LuaCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentViewController: NSViewController) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.contentViewController = contentViewController
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = true
        isFloatingPanel = true
        isMovable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        setAccessibilityLabel("Lua completion picker")
    }

    func present(relativeTo caretRect: NSRect, of view: NSView) {
        guard let hostWindow = view.window else { return }
        let caretInWindow = view.convert(caretRect, to: nil)
        let caretOnScreen = hostWindow.convertToScreen(caretInWindow)
        let visibleFrame = (hostWindow.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: caretOnScreen.minX, y: caretOnScreen.minY, width: 560, height: 240)
        let margin: CGFloat = 6
        let size = frame.size
        var origin = NSPoint(
            x: caretOnScreen.minX,
            y: caretOnScreen.minY - size.height - margin
        )
        if origin.y < visibleFrame.minY + margin {
            origin.y = caretOnScreen.maxY + margin
        }
        origin.x = min(
            max(origin.x, visibleFrame.minX + margin),
            max(visibleFrame.minX + margin, visibleFrame.maxX - size.width - margin)
        )
        origin.y = min(
            max(origin.y, visibleFrame.minY + margin),
            max(visibleFrame.minY + margin, visibleFrame.maxY - size.height - margin)
        )
        if parent !== hostWindow {
            parent?.removeChildWindow(self)
            hostWindow.addChildWindow(self, ordered: .above)
        }
        setFrameOrigin(origin)
        orderFront(nil)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

final class LuaCompletionRowView: NSTableCellView {
    private let kindImage = NSImageView()
    private let primaryLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        kindImage.translatesAutoresizingMaskIntoConstraints = false
        kindImage.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        kindImage.contentTintColor = .secondaryLabelColor

        primaryLabel.translatesAutoresizingMaskIntoConstraints = false
        primaryLabel.font = .monospacedSystemFont(
            ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
            weight: .medium
        )
        primaryLabel.lineBreakMode = .byTruncatingTail

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        addSubview(kindImage)
        addSubview(primaryLabel)
        addSubview(detailLabel)
        NSLayoutConstraint.activate([
            kindImage.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            kindImage.centerYAnchor.constraint(equalTo: centerYAnchor),
            kindImage.widthAnchor.constraint(equalToConstant: 16),
            kindImage.heightAnchor.constraint(equalToConstant: 16),
            primaryLabel.leadingAnchor.constraint(equalTo: kindImage.trailingAnchor, constant: 6),
            primaryLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            primaryLabel.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            detailLabel.leadingAnchor.constraint(equalTo: primaryLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: primaryLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: primaryLabel.bottomAnchor),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(with item: LuaCompletionItem) {
        primaryLabel.stringValue = item.label
        detailLabel.stringValue = item.detail
        kindImage.image = NSImage(systemSymbolName: item.kind.systemImageName, accessibilityDescription: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(item.accessibilityLabel)
        setAccessibilityHelp(item.documentation)
    }
}

final class CompletionViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var suggestions: [LuaCompletionItem] = [] {
        didSet {
            loadViewIfNeeded()
            tableView.reloadData()
            if suggestions.isEmpty {
                documentationView.string = ""
            } else {
                tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                updateDocumentation()
            }
        }
    }
    var onSelect: ((LuaCompletionItem) -> Void)?
    var onDismiss: (() -> Void)?
    var onSelectionChange: ((LuaCompletionItem?) -> Void)?

    private let tableView = NSTableView()
    private let documentationView = NSTextView()

    var selectedItem: LuaCompletionItem? {
        let row = tableView.selectedRow
        return row >= 0 && row < suggestions.count ? suggestions[row] : nil
    }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 560, height: 240))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin

        let listScroll = NSScrollView()
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .noBorder
        let column = NSTableColumn(identifier: .init("completion"))
        column.width = 290
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = max(40, NSFont.preferredFont(forTextStyle: .body).pointSize * 2 + 12)
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.refusesFirstResponder = true
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked)
        tableView.setAccessibilityLabel("Lua completions")
        tableView.setAccessibilityHelp(
            "Use the Up and Down Arrow keys to navigate, Return or Tab to insert, and Escape to close."
        )
        listScroll.documentView = tableView

        documentationView.isEditable = false
        documentationView.isSelectable = false
        documentationView.drawsBackground = false
        documentationView.font = .preferredFont(forTextStyle: .body)
        documentationView.textColor = .labelColor
        documentationView.frame = NSRect(x: 0, y: 0, width: 260, height: 220)
        documentationView.minSize = .zero
        documentationView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        documentationView.isVerticallyResizable = true
        documentationView.isHorizontallyResizable = false
        documentationView.autoresizingMask = [.width]
        documentationView.textContainer?.containerSize = NSSize(
            width: 260,
            height: CGFloat.greatestFiniteMagnitude
        )
        documentationView.textContainer?.widthTracksTextView = true
        documentationView.textContainerInset = NSSize(width: 10, height: 10)
        documentationView.setAccessibilityRole(.staticText)
        documentationView.setAccessibilityLabel("Completion documentation")
        let documentationScroll = NSScrollView()
        documentationScroll.hasVerticalScroller = true
        documentationScroll.borderType = .noBorder
        documentationScroll.documentView = documentationView

        let keyboardHint = NSTextField(
            labelWithString: "↑↓ Navigate   Return/Tab Insert   Esc Close"
        )
        keyboardHint.translatesAutoresizingMaskIntoConstraints = false
        keyboardHint.font = .preferredFont(forTextStyle: .caption1)
        keyboardHint.textColor = .secondaryLabelColor
        keyboardHint.alignment = .center
        keyboardHint.lineBreakMode = .byTruncatingTail
        keyboardHint.setAccessibilityLabel(
            "Completion controls: Up and Down Arrow navigate, Return or Tab inserts, Escape closes."
        )

        split.addArrangedSubview(listScroll)
        split.addArrangedSubview(documentationScroll)
        root.addSubview(split)
        root.addSubview(keyboardHint)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: keyboardHint.topAnchor, constant: -4),
            keyboardHint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            keyboardHint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            keyboardHint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -5),
            listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            documentationScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
        view = root
    }

    @objc private func rowDoubleClicked() {
        acceptSelection()
    }

    func acceptSelection() {
        guard let selectedItem else { return }
        onSelect?(selectedItem)
    }

    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        let next = min(max(0, current + delta), suggestions.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
        updateDocumentation()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("LuaCompletionRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? LuaCompletionRowView
            ?? LuaCompletionRowView()
        cell.identifier = identifier
        cell.configure(with: suggestions[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDocumentation()
    }

    private func updateDocumentation() {
        guard let item = selectedItem else {
            documentationView.string = ""
            documentationView.setAccessibilityValue("")
            onSelectionChange?(nil)
            return
        }
        let readOnly = item.isReadOnly ? " • read only" : ""
        let content = NSMutableAttributedString()
        content.append(NSAttributedString(
            string: item.label + "\n",
            attributes: [
                .font: NSFont.monospacedSystemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                    weight: .semibold
                ),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        content.append(NSAttributedString(
            string: item.detail + readOnly + "\n\n",
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .caption1),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        content.append(NSAttributedString(
            string: item.documentation,
            attributes: [
                .font: NSFont.preferredFont(forTextStyle: .body),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        documentationView.textStorage?.setAttributedString(content)
        documentationView.setAccessibilityValue(content.string)
        onSelectionChange?(item)
    }
}
