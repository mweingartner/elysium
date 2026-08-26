// NativeScriptEditorToolbar.swift — an AppKit-only toolbar bridge for the script editor.
//
// Keeping every toolbar descendant in one native NSView hierarchy avoids the mixed
// SwiftUI/AppKit sibling compositing failure that can place live controls behind a flattened
// SwiftUI graphics surface. The view deliberately does not opt into layer backing.

import AppKit
import SwiftUI
import ElysiumCore

/// A two-row AppKit toolbar that participates in SwiftUI data flow without asking SwiftUI to
/// render any of its controls. `onSave` remains a closure because the parent view owns collision
/// confirmation; every other action can call the model directly.
@MainActor
struct NativeScriptEditorToolbar: NSViewRepresentable {
    @ObservedObject private var model: ScriptEditorModel
    private let theme: ScriptEditorTheme
    private let aiPanelOpen: Bool
    private let onSave: () -> Void
    private let onToggleAI: () -> Void

    init(
        model: ScriptEditorModel,
        theme: ScriptEditorTheme,
        aiPanelOpen: Bool,
        onSave: @escaping () -> Void,
        onToggleAI: @escaping () -> Void
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.theme = theme
        self.aiPanelOpen = aiPanelOpen
        self.onSave = onSave
        self.onToggleAI = onToggleAI
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NativeScriptEditorToolbarView {
        let view = NativeScriptEditorToolbarView(theme: theme)
        context.coordinator.toolbarView = view
        view.connect(to: context.coordinator)
        view.update(model: model, theme: theme, aiPanelOpen: aiPanelOpen)
        return view
    }

    func updateNSView(_ nsView: NativeScriptEditorToolbarView, context: Context) {
        context.coordinator.parent = self
        nsView.update(model: model, theme: theme, aiPanelOpen: aiPanelOpen)
    }

    static func dismantleNSView(
        _ nsView: NativeScriptEditorToolbarView,
        coordinator: Coordinator
    ) {
        nsView.disconnect()
        coordinator.toolbarView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: NativeScriptEditorToolbar
        weak var toolbarView: NativeScriptEditorToolbarView?

        init(parent: NativeScriptEditorToolbar) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let toolbarView else { return }
            if field === toolbarView.scriptNameField {
                parent.model.currentName = field.stringValue
            } else if field === toolbarView.handlerEventField {
                parent.model.handlerEvent = field.stringValue
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            controlTextDidChange(notification)
        }

        @objc func modeChanged(_ sender: NSSegmentedControl) {
            parent.model.mode = sender.selectedSegment == 1 ? .handler : .module
        }

        @objc func eventSelected(_ sender: NSMenuItem) {
            guard let eventName = sender.representedObject as? String else { return }
            parent.model.handlerEvent = eventName
            toolbarView?.handlerEventField.stringValue = eventName
        }

        @objc func aiModeChanged(_ sender: NSPopUpButton) {
            guard let rawValue = sender.selectedItem?.representedObject as? String,
                  let mode = ScriptEditorAICompletionMode(rawValue: rawValue)
            else { return }
            parent.model.setAICompletionMode(mode)
        }

        @objc func requestAISuggestion(_ sender: Any?) {
            _ = sender
            parent.model.requestAISuggestion()
        }

        @objc func check(_ sender: Any?) {
            _ = sender
            parent.model.check()
        }

        @objc func run(_ sender: Any?) {
            _ = sender
            parent.model.run()
        }

        @objc func save(_ sender: Any?) {
            _ = sender
            parent.onSave()
        }

        @objc func toggleAI(_ sender: Any?) {
            _ = sender
            parent.onToggleAI()
        }
    }
}

/// The complete native subtree. It draws its own non-layer-backed background and relies only on
/// constraints and intrinsic control sizes, allowing the name/event fields and the flexible
/// spacer to absorb resizing without hiding actions.
@MainActor
final class NativeScriptEditorToolbarView: NSView {
    let scriptNameField = NSTextField()
    let handlerEventField = NSTextField()

    private let rootStack = NSStackView()
    private let topRow = NSStackView()
    private let bottomRow = NSStackView()
    private let metadataStack = NSStackView()
    private let targetStatusField = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(
        labels: ["Module", "Handler"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let handlerEventContainer = NSStackView()
    private let eventMenuButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let aiModeButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let aiRequestContainer = NSView()
    private let aiRequestButton = NSButton()
    private let aiRequestProgress = NSProgressIndicator()
    private let flexibleSpacer = NSView()
    private let checkButton = NSButton(title: "Check", target: nil, action: nil)
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let actionSeparator = NSBox()
    private let aiPanelButton = NSButton()

    private var backgroundColor = NSColor.windowBackgroundColor
    private var contentInset: CGFloat = 8
    private var insetConstraints: [NSLayoutConstraint] = []

    init(theme: ScriptEditorTheme) {
        super.init(frame: .zero)
        configureHierarchy()
        apply(theme: theme)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("NativeScriptEditorToolbarView must be created programmatically")
    }

    override var intrinsicContentSize: NSSize {
        let measuredHeight = rootStack.fittingSize.height + (contentInset * 2)
        return NSSize(width: NSView.noIntrinsicMetric, height: max(78, measuredHeight))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        promotePlatformHostAboveSiblingSurfaces()
        // SwiftUI can finish assigning the wrapper's backing layer after this callback. Repeat on
        // the next main turn without creating a layer ourselves.
        DispatchQueue.main.async { [weak self] in
            self?.promotePlatformHostAboveSiblingSurfaces()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        backgroundColor.setFill()
        NSBezierPath(rect: bounds).fill()
    }

    func connect(to coordinator: NativeScriptEditorToolbar.Coordinator) {
        scriptNameField.delegate = coordinator
        handlerEventField.delegate = coordinator

        modeControl.target = coordinator
        modeControl.action = #selector(NativeScriptEditorToolbar.Coordinator.modeChanged(_:))
        aiModeButton.target = coordinator
        aiModeButton.action = #selector(NativeScriptEditorToolbar.Coordinator.aiModeChanged(_:))

        aiRequestButton.target = coordinator
        aiRequestButton.action = #selector(NativeScriptEditorToolbar.Coordinator.requestAISuggestion(_:))
        checkButton.target = coordinator
        checkButton.action = #selector(NativeScriptEditorToolbar.Coordinator.check(_:))
        runButton.target = coordinator
        runButton.action = #selector(NativeScriptEditorToolbar.Coordinator.run(_:))
        saveButton.target = coordinator
        saveButton.action = #selector(NativeScriptEditorToolbar.Coordinator.save(_:))
        aiPanelButton.target = coordinator
        aiPanelButton.action = #selector(NativeScriptEditorToolbar.Coordinator.toggleAI(_:))

        for item in eventMenuButton.itemArray.dropFirst() {
            guard !item.isSeparatorItem else { continue }
            item.target = coordinator
            item.action = #selector(NativeScriptEditorToolbar.Coordinator.eventSelected(_:))
        }
    }

    func disconnect() {
        scriptNameField.delegate = nil
        handlerEventField.delegate = nil
        modeControl.target = nil
        aiModeButton.target = nil
        aiRequestButton.target = nil
        checkButton.target = nil
        runButton.target = nil
        saveButton.target = nil
        aiPanelButton.target = nil
        for item in eventMenuButton.itemArray {
            item.target = nil
        }
    }

    func update(
        model: ScriptEditorModel,
        theme: ScriptEditorTheme,
        aiPanelOpen: Bool
    ) {
        apply(theme: theme)

        if scriptNameField.stringValue != model.currentName {
            scriptNameField.stringValue = model.currentName
        }
        updateTargetStatus(model: model, theme: theme)

        modeControl.selectedSegment = model.mode == .handler ? 1 : 0
        modeControl.setAccessibilityValue(model.mode == .handler ? "Handler" : "Module")
        handlerEventContainer.isHidden = model.mode != .handler
        if handlerEventField.stringValue != model.handlerEvent {
            handlerEventField.stringValue = model.handlerEvent
        }

        if let selectedAIItem = aiModeButton.itemArray.first(where: {
            ($0.representedObject as? String) == model.aiCompletionMode.rawValue
        }) {
            aiModeButton.select(selectedAIItem)
        }
        aiModeButton.toolTip = model.aiCompletionMode.detail
        aiModeButton.setAccessibilityValue(model.aiCompletionMode.title)

        let canRequestAI = model.isWorldSessionActive
            && model.aiCompletionMode != .off
            && !model.isRequestingAISuggestion
        aiRequestButton.isEnabled = canRequestAI
        aiRequestButton.isHidden = model.isRequestingAISuggestion
        aiRequestProgress.isHidden = !model.isRequestingAISuggestion
        if model.isRequestingAISuggestion {
            aiRequestProgress.startAnimation(nil)
        } else {
            aiRequestProgress.stopAnimation(nil)
        }

        checkButton.isEnabled = !model.isLANGuest && model.isWorldSessionActive
        checkButton.toolTip = model.isLANGuest
            ? "Check is not available for guests yet"
            : "Compile and dry-run without persisting"
        runButton.isEnabled = model.isWorldSessionActive
        saveButton.isEnabled = model.isWorldSessionActive
        saveButton.toolTip = "Attach this script to \(model.target.canonical)"

        let panelSymbol = aiPanelOpen ? "sidebar.trailing" : "sidebar.leading"
        aiPanelButton.image = NSImage(
            systemSymbolName: panelSymbol,
            accessibilityDescription: aiPanelOpen ? "Hide AI panel" : "Show AI panel"
        )
        aiPanelButton.toolTip = aiPanelOpen ? "Hide AI panel" : "Show AI panel"
        aiPanelButton.setAccessibilityLabel(aiPanelOpen ? "Hide AI panel" : "Show AI panel")
        aiPanelButton.setAccessibilityValue(aiPanelOpen ? "Expanded" : "Collapsed")

        invalidateIntrinsicContentSize()
        needsLayout = true
        promotePlatformHostAboveSiblingSurfaces()
    }

    /// `HSplitView` flattens sibling SwiftUI drawing and AppKit representable surfaces into one
    /// pane host. On current macOS, the first representable's backing layer otherwise sits below
    /// the pane's opaque drawing surface even though its controls remain live and accessible.
    /// Raise only SwiftUI's already-layer-backed wrapper; the toolbar and its TextKit sibling do
    /// not opt into layer backing themselves.
    func promotePlatformHostAboveSiblingSurfaces() {
        guard let platformHost = superview, let layer = platformHost.layer else { return }
        layer.zPosition = 1
    }

    private func configureHierarchy() {
        setAccessibilityElement(false)

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.distribution = .fill
        rootStack.spacing = 6
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        topRow.orientation = .horizontal
        topRow.alignment = .centerY
        topRow.distribution = .fill
        topRow.spacing = 8

        bottomRow.orientation = .horizontal
        bottomRow.alignment = .centerY
        bottomRow.distribution = .fill
        bottomRow.spacing = 6

        configureMetadataControls()
        configureHandlerEventControls()
        configureAIControls()
        configureActionControls()

        topRow.addArrangedSubview(metadataStack)
        topRow.addArrangedSubview(modeControl)
        topRow.addArrangedSubview(handlerEventContainer)

        bottomRow.addArrangedSubview(aiModeButton)
        bottomRow.addArrangedSubview(aiRequestContainer)
        bottomRow.addArrangedSubview(flexibleSpacer)
        bottomRow.addArrangedSubview(checkButton)
        bottomRow.addArrangedSubview(runButton)
        bottomRow.addArrangedSubview(saveButton)
        bottomRow.addArrangedSubview(actionSeparator)
        bottomRow.addArrangedSubview(aiPanelButton)

        rootStack.addArrangedSubview(topRow)
        rootStack.addArrangedSubview(bottomRow)

        insetConstraints = [
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ]

        NSLayoutConstraint.activate(insetConstraints + [
            topRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            bottomRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            metadataStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 90),
            modeControl.widthAnchor.constraint(equalToConstant: 130),
            handlerEventContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 125),
            handlerEventContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            aiRequestContainer.widthAnchor.constraint(equalToConstant: 26),
            aiRequestContainer.heightAnchor.constraint(equalToConstant: 22),
            actionSeparator.widthAnchor.constraint(equalToConstant: 1),
            actionSeparator.heightAnchor.constraint(equalToConstant: 18),
        ])

        metadataStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        metadataStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        handlerEventContainer.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        flexibleSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        flexibleSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureMetadataControls() {
        metadataStack.orientation = .vertical
        metadataStack.alignment = .leading
        metadataStack.distribution = .fill
        metadataStack.spacing = 1

        scriptNameField.isBordered = false
        scriptNameField.isBezeled = false
        scriptNameField.drawsBackground = false
        scriptNameField.focusRingType = .exterior
        scriptNameField.placeholderString = "script name"
        scriptNameField.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        scriptNameField.lineBreakMode = .byTruncatingTail
        scriptNameField.toolTip = "Name this script before saving"
        scriptNameField.setAccessibilityLabel("Script name")
        scriptNameField.setAccessibilityIdentifier("scriptEditor.scriptName")

        targetStatusField.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        targetStatusField.lineBreakMode = .byTruncatingMiddle
        targetStatusField.maximumNumberOfLines = 1
        targetStatusField.setAccessibilityLabel("Script target and save status")
        targetStatusField.setAccessibilityIdentifier("scriptEditor.targetStatus")

        metadataStack.addArrangedSubview(scriptNameField)
        metadataStack.addArrangedSubview(targetStatusField)
        scriptNameField.widthAnchor.constraint(equalTo: metadataStack.widthAnchor).isActive = true
        targetStatusField.widthAnchor.constraint(equalTo: metadataStack.widthAnchor).isActive = true

        modeControl.segmentStyle = .rounded
        modeControl.controlSize = .small
        modeControl.setWidth(65, forSegment: 0)
        modeControl.setWidth(65, forSegment: 1)
        modeControl.toolTip = "Choose whether this source is a module or one event handler"
        modeControl.setAccessibilityLabel("Script mode")
        modeControl.setAccessibilityIdentifier("scriptEditor.mode")
    }

    private func configureHandlerEventControls() {
        handlerEventContainer.orientation = .horizontal
        handlerEventContainer.alignment = .centerY
        handlerEventContainer.distribution = .fill
        handlerEventContainer.spacing = 4

        handlerEventField.controlSize = .small
        handlerEventField.placeholderString = "event name"
        handlerEventField.toolTip = "Built-in or validated custom event name"
        handlerEventField.setAccessibilityLabel("Handler event name")
        handlerEventField.setAccessibilityIdentifier("scriptEditor.handlerEvent")
        handlerEventField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        handlerEventField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        eventMenuButton.controlSize = .small
        eventMenuButton.bezelStyle = .texturedRounded
        eventMenuButton.imagePosition = .imageOnly
        eventMenuButton.toolTip = "Choose a shipped event"
        eventMenuButton.setAccessibilityLabel("Choose a shipped handler event")
        eventMenuButton.setAccessibilityIdentifier("scriptEditor.handlerEventMenu")
        eventMenuButton.widthAnchor.constraint(equalToConstant: 28).isActive = true

        let menu = NSMenu(title: "Shipped Events")
        let titleItem = NSMenuItem(title: "Choose Event", action: nil, keyEquivalent: "")
        titleItem.image = NSImage(
            systemSymbolName: "chevron.down.circle",
            accessibilityDescription: "Choose Event"
        )
        menu.addItem(titleItem)
        menu.addItem(.separator())
        for event in EventDescriptorRegistry.available {
            let item = NSMenuItem(title: event.kind.rawValue, action: nil, keyEquivalent: "")
            item.representedObject = event.kind.rawValue
            item.toolTip = event.summary
            menu.addItem(item)
        }
        eventMenuButton.menu = menu

        handlerEventContainer.addArrangedSubview(handlerEventField)
        handlerEventContainer.addArrangedSubview(eventMenuButton)
    }

    private func configureAIControls() {
        aiModeButton.controlSize = .small
        aiModeButton.bezelStyle = .texturedRounded
        aiModeButton.setAccessibilityLabel("AI completion mode")
        aiModeButton.setAccessibilityIdentifier("scriptEditor.aiMode")
        for mode in ScriptEditorAICompletionMode.allCases {
            aiModeButton.addItem(withTitle: "AI \(mode.title)")
            if let item = aiModeButton.lastItem {
                item.representedObject = mode.rawValue
                item.toolTip = mode.detail
                item.image = NSImage(
                    systemSymbolName: "wand.and.sparkles",
                    accessibilityDescription: nil
                )
            }
        }

        aiRequestContainer.translatesAutoresizingMaskIntoConstraints = false
        aiRequestContainer.setAccessibilityElement(false)

        aiRequestButton.translatesAutoresizingMaskIntoConstraints = false
        aiRequestButton.bezelStyle = .texturedRounded
        aiRequestButton.controlSize = .small
        aiRequestButton.imagePosition = .imageOnly
        aiRequestButton.image = NSImage(
            systemSymbolName: "text.badge.plus",
            accessibilityDescription: "Request AI suggestion"
        )
        aiRequestButton.toolTip = "Request one AI suggestion (Option-Command-/)"
        aiRequestButton.setAccessibilityLabel("Request AI suggestion")
        aiRequestButton.setAccessibilityIdentifier("scriptEditor.requestAI")

        aiRequestProgress.translatesAutoresizingMaskIntoConstraints = false
        aiRequestProgress.style = .spinning
        aiRequestProgress.controlSize = .small
        aiRequestProgress.isDisplayedWhenStopped = false
        aiRequestProgress.setAccessibilityLabel("Requesting AI suggestion")
        aiRequestProgress.setAccessibilityIdentifier("scriptEditor.requestingAI")

        aiRequestContainer.addSubview(aiRequestButton)
        aiRequestContainer.addSubview(aiRequestProgress)
        NSLayoutConstraint.activate([
            aiRequestButton.centerXAnchor.constraint(equalTo: aiRequestContainer.centerXAnchor),
            aiRequestButton.centerYAnchor.constraint(equalTo: aiRequestContainer.centerYAnchor),
            aiRequestProgress.centerXAnchor.constraint(equalTo: aiRequestContainer.centerXAnchor),
            aiRequestProgress.centerYAnchor.constraint(equalTo: aiRequestContainer.centerYAnchor),
        ])
    }

    private func configureActionControls() {
        configureActionButton(checkButton, identifier: "scriptEditor.check")
        configureActionButton(runButton, identifier: "scriptEditor.run")
        configureActionButton(saveButton, identifier: "scriptEditor.save")
        checkButton.toolTip = "Compile and dry-run without persisting"
        runButton.toolTip = "Run once, ephemeral — never saved"
        saveButton.toolTip = "Attach this script to its target"
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]

        actionSeparator.boxType = .separator
        actionSeparator.setAccessibilityElement(false)

        aiPanelButton.bezelStyle = .texturedRounded
        aiPanelButton.controlSize = .small
        aiPanelButton.imagePosition = .imageOnly
        aiPanelButton.setAccessibilityIdentifier("scriptEditor.toggleAIPanel")
        aiPanelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
    }

    private func configureActionButton(_ button: NSButton, identifier: String) {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityIdentifier(identifier)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func apply(theme: ScriptEditorTheme) {
        backgroundColor = theme.toolbarBackground.nsColor
        let appearanceName: NSAppearance.Name = theme.chromeColorScheme == .dark
            ? .darkAqua
            : .aqua
        appearance = NSAppearance(named: appearanceName)
        scriptNameField.textColor = theme.foreground.nsColor
        targetStatusField.textColor = theme.comment.nsColor
        handlerEventField.textColor = theme.foreground.nsColor

        let spacing = theme.spacing
        contentInset = spacing
        topRow.spacing = spacing
        for constraint in insetConstraints {
            switch constraint.firstAttribute {
            case .leading, .top:
                constraint.constant = spacing
            case .trailing, .bottom:
                constraint.constant = -spacing
            default:
                break
            }
        }
        needsDisplay = true
    }

    private func updateTargetStatus(model: ScriptEditorModel, theme: ScriptEditorTheme) {
        let target = model.isLANGuest ? "\(model.target.canonical) (guest)" : model.target.canonical
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let value = NSMutableAttributedString(
            string: target,
            attributes: [
                .font: font,
                .foregroundColor: theme.comment.nsColor,
            ]
        )
        if model.isDirty {
            value.append(NSAttributedString(
                string: "  ● Unsaved",
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.systemOrange,
                ]
            ))
        }
        targetStatusField.attributedStringValue = value
        targetStatusField.toolTip = model.isDirty
            ? "\(target) — unsaved changes"
            : target
        targetStatusField.setAccessibilityValue(
            model.isDirty ? "\(target), unsaved changes" : target
        )
    }
}
