// LuaCodeTextView.swift — native TextKit editor wired to Elysium's deterministic Lua language
// service. Lexical and semantic styling, diagnostics, completion, line numbers, and optional AI
// ghost text are presentation-only; Save/Run still use the runtime validator and executors.

import SwiftUI
import AppKit
import ElysiumCore

struct LuaCodeTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var errorLine: Int?
    var targetKind: ObjectKind
    var theme: ScriptEditorTheme
    var targetApplicableBuiltInAttributes: Set<String>? = nil
    var targetCustomAttributes: [LuaCustomAttributeCompletion] = []
    var objectReferences: [LuaObjectReferenceCompletion] = []
    var handlerEvent: String? = nil
    var isYieldable = true
    var inlineSuggestion: String? = nil
    var isRequestingAISuggestion = false
    var externalEdit: LuaEditorExternalEdit? = nil
    var documentIdentity: UInt64 = 0
    var onTextChange: (() -> Void)? = nil
    var onRequestAISuggestion: (() -> Void)? = nil
    /// Called after the editor has inserted the accepted proposal into the document.
    var onAcceptAISuggestion: ((String) -> Void)? = nil
    var onAcceptNextAISuggestionWord: (() -> Void)? = nil
    var onAcceptNextAISuggestionLine: (() -> Void)? = nil
    var onDismissAISuggestion: (() -> Void)? = nil
    var onAnalysisChange: (([LuaDiagnostic], LuaSignatureHelp?) -> Void)? = nil
    var onCompletionDocumentationChange: ((LuaCompletionItem?) -> Void)? = nil

    private var languageEnvironment: LuaLanguageEnvironment {
        LuaLanguageEnvironment(
            targetKind: targetKind,
            targetApplicableBuiltInAttributes: targetApplicableBuiltInAttributes,
            targetCustomAttributes: targetCustomAttributes,
            objectReferences: objectReferences,
            handlerEvent: handlerEvent,
            isYieldable: isYieldable
        )
    }

    func makeNSView(context: Context) -> NSView {
        makeEditorView(coordinator: context.coordinator)
    }

    /// The production construction path extracted from the protocol witness so lifecycle tests
    /// can retain the real coordinator and invoke `dismantleNSView` without fabricating SwiftUI's
    /// opaque `NSViewRepresentableContext`.
    func makeEditorView(coordinator: Coordinator) -> NSView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let textView = LuaEditorTextView()
        configure(textView)
        scrollView.documentView = textView

        let gutter = LuaLineNumberGutterView(textView: textView, theme: theme)
        let container = LuaEditorContainerView(scrollView: scrollView, gutter: gutter)
        coordinator.install(textView: textView, scrollView: scrollView, gutter: gutter)

        textView.string = text
        coordinator.markExternalEditSeen(externalEdit)
        coordinator.markDocumentIdentitySeen(documentIdentity)
        coordinator.applyLanguageState(in: textView, forceAnalysis: true)
        coordinator.updateGhostText(in: textView, announce: false)
        return container
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let container = view as? LuaEditorContainerView,
              let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        container.gutter.theme = theme
        container.scrollView.backgroundColor = .clear

        guard !context.coordinator.isUpdating else { return }
        let documentChanged = context.coordinator.markDocumentIdentitySeen(documentIdentity)
        if documentChanged {
            context.coordinator.dismissCompletionForExternalChange()
            textView.breakUndoCoalescing()
            textView.undoManager?.removeAllActions()
        }
        if textView.string != text {
            context.coordinator.dismissCompletionForExternalChange()
            context.coordinator.isUpdating = true
            if !context.coordinator.applyExternalEdit(externalEdit, expectedText: text, in: textView) {
                // A model-driven whole-document replacement is a load/new/switch boundary, not
                // an edit in the current document. Never let Cmd-Z replay the previous script's
                // undo stack into the newly loaded source.
                if !documentChanged {
                    textView.breakUndoCoalescing()
                    textView.undoManager?.removeAllActions()
                }
                textView.string = text
                context.coordinator.markExternalEditSeen(externalEdit)
            }
            context.coordinator.restoreSelection(selectedRange, in: textView)
            context.coordinator.isUpdating = false
            textView.scrollRangeToVisible(textView.selectedRange())
            textView.window?.makeFirstResponder(textView)
        } else if textView.selectedRange() != selectedRange {
            context.coordinator.dismissCompletionForExternalChange()
            context.coordinator.restoreSelection(selectedRange, in: textView)
            textView.scrollRangeToVisible(textView.selectedRange())
            textView.window?.makeFirstResponder(textView)
        }

        context.coordinator.applyEditorAppearance(to: textView)
        context.coordinator.applyLanguageState(in: textView)
        context.coordinator.applyErrorHighlight(line: errorLine, in: textView)
        context.coordinator.updateGhostText(in: textView, announce: true)
        container.gutter.needsDisplay = true
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        _ = nsView
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func configure(_ textView: LuaEditorTextView) {
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityElement(true)
        textView.setAccessibilityRole(.textArea)
        textView.setAccessibilityLabel("Lua script editor")
        textView.setAccessibilityHelp(
            "Control-Space shows factual completions. Option-Command-Slash requests an optional AI suggestion."
        )
        textView.setAccessibilityIdentifier("scriptEditor.source")
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LuaCodeTextView
        weak var textView: LuaEditorTextView?
        weak var scrollView: NSScrollView?
        weak var gutter: LuaLineNumberGutterView?
        var isUpdating = false

        private var scrollObserver: NSObjectProtocol?
        private var currentErrorLine: Int?
        private var isInsertingText = false
        private var completionPanel: LuaCompletionPanel?
        private var completionParentResignObserver: NSObjectProtocol?
        private var completionOutsideClickMonitor: Any?
        private var completionController: CompletionViewController?
        private var completionResult: LuaCompletionResult?
        private var cachedSource: String?
        private var cachedEnvironment: LuaLanguageEnvironment?
        private var cachedAnalysis: LuaLanguageAnalysis?
        private var publishedDiagnostics: [LuaDiagnostic] = []
        private var publishedSignature: LuaSignatureHelp?
        private var selectedCompletion: LuaCompletionItem?
        private var ghostLabel: NSTextField?
        private var lastAnnouncedGhost: String?
        private var lastCompletionAnnouncement: String?
        private var zoomScale = 1.0
        private var lastAppliedExternalEditID: UInt64?
        private var lastDocumentIdentity: UInt64?

        /// Both hooks are installed and removed as one completion-presentation lifecycle. This
        /// internal invariant is observable so integration tests can detect leaked AppKit hooks.
        var hasActiveCompletionLifecycleHooks: Bool {
            completionParentResignObserver != nil || completionOutsideClickMonitor != nil
        }

        init(parent: LuaCodeTextView) {
            self.parent = parent
        }

        func install(
            textView: LuaEditorTextView,
            scrollView: NSScrollView,
            gutter: LuaLineNumberGutterView
        ) {
            self.textView = textView
            self.scrollView = scrollView
            self.gutter = gutter
            textView.delegate = self
            textView.onEditorKeyDown = { [weak self] event in self?.handleKeyDown(event) ?? false }
            textView.onRequestAISuggestion = { [weak self] in self?.parent.onRequestAISuggestion?() }
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak gutter, weak self] _ in
                Task { @MainActor in
                    gutter?.needsDisplay = true
                    if let textView = self?.textView { self?.updateGhostText(in: textView, announce: false) }
                }
            }

            let ghost = NSTextField(labelWithString: "")
            ghost.isEditable = false
            ghost.isSelectable = false
            ghost.drawsBackground = false
            ghost.isBordered = false
            ghost.lineBreakMode = .byTruncatingTail
            ghost.textColor = .tertiaryLabelColor
            ghost.setAccessibilityElement(true)
            ghost.setAccessibilityRole(.staticText)
            ghost.isHidden = true
            textView.addSubview(ghost)
            ghostLabel = ghost
            applyEditorAppearance(to: textView)
        }

        func tearDown() {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
            scrollObserver = nil
            dismissCompletionPanel()
            if textView?.delegate === self { textView?.delegate = nil }
            textView?.onEditorKeyDown = nil
            textView?.onRequestAISuggestion = nil
            ghostLabel?.removeFromSuperview()
            ghostLabel = nil
            textView = nil
            scrollView = nil
            gutter = nil
        }

        func restoreSelection(_ requested: NSRange, in textView: NSTextView) {
            let length = (textView.string as NSString).length
            let location = min(max(0, requested.location), length)
            let selectionLength = min(max(0, requested.length), length - location)
            textView.setSelectedRange(NSRange(location: location, length: selectionLength))
        }

        func markExternalEditSeen(_ edit: LuaEditorExternalEdit?) {
            if let edit { lastAppliedExternalEditID = edit.id }
        }

        @discardableResult
        func markDocumentIdentitySeen(_ identity: UInt64) -> Bool {
            defer { lastDocumentIdentity = identity }
            guard let lastDocumentIdentity else { return false }
            return lastDocumentIdentity != identity
        }

        func applyExternalEdit(
            _ edit: LuaEditorExternalEdit?, expectedText: String, in textView: NSTextView
        ) -> Bool {
            guard let edit, edit.id != lastAppliedExternalEditID else { return false }
            let current = textView.string as NSString
            guard edit.replacementRange.location >= 0,
                  NSMaxRange(edit.replacementRange) <= current.length,
                  current.replacingCharacters(in: edit.replacementRange, with: edit.replacementText) == expectedText
            else { return false }
            textView.insertText(edit.replacementText, replacementRange: edit.replacementRange)
            guard textView.string == expectedText else { return false }
            lastAppliedExternalEditID = edit.id
            return true
        }

        // MARK: - appearance and analysis

        func applyEditorAppearance(to textView: NSTextView) {
            let font = editorFont()
            let foreground = parent.theme.foreground.nsColor
            textView.font = font
            textView.backgroundColor = .clear
            textView.textColor = foreground
            textView.insertionPointColor = foreground
            textView.selectedTextAttributes = [.backgroundColor: parent.theme.selection.nsColor]
            textView.typingAttributes = [.font: font, .foregroundColor: foreground]
            ghostLabel?.font = font
            ghostLabel?.textColor = parent.theme.comment.nsColor
        }

        private func editorFont() -> NSFont {
            let accessibleBase = max(parent.theme.fontSize, NSFont.preferredFont(forTextStyle: .body).pointSize)
            return NSFont.monospacedSystemFont(ofSize: accessibleBase * zoomScale, weight: .regular)
        }

        func applyLanguageState(in textView: NSTextView, forceAnalysis: Bool = false) {
            let source = textView.string
            let environment = parent.languageEnvironment
            if forceAnalysis || source != cachedSource || environment != cachedEnvironment || cachedAnalysis == nil {
                cachedSource = source
                cachedEnvironment = environment
                cachedAnalysis = LuaLanguageService.analyze(source: source, environment: environment)
            }
            guard let analysis = cachedAnalysis else { return }
            applyHighlighting(analysis: analysis, in: textView)
            applyDiagnostics(analysis.diagnostics, in: textView)
            publishAnalysis(for: textView, analysis: analysis)
        }

        private func applyHighlighting(analysis: LuaLanguageAnalysis, in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let source = textView.string
            let fullRange = NSRange(location: 0, length: (source as NSString).length)
            let font = editorFont()
            storage.beginEditing()
            storage.setAttributes([
                .font: font,
                .foregroundColor: parent.theme.foreground.nsColor,
            ], range: fullRange)
            for span in LuaSyntaxColoring.colorSource(source) where NSMaxRange(span.range) <= fullRange.length {
                storage.addAttribute(
                    .foregroundColor,
                    value: parent.theme.color(for: span.kind).nsColor,
                    range: span.range
                )
            }
            let fontManager = NSFontManager.shared
            let boldFont = fontManager.convert(font, toHaveTrait: .boldFontMask)
            let italicFont = fontManager.convert(font, toHaveTrait: .italicFontMask)
            for token in analysis.semanticTokens where NSMaxRange(token.range) <= fullRange.length {
                switch token.role {
                case .engineGlobal, .module, .function, .method:
                    storage.addAttribute(.foregroundColor, value: parent.theme.command.nsColor, range: token.range)
                case .property, .attribute, .eventField:
                    storage.addAttribute(.foregroundColor, value: parent.theme.property.nsColor, range: token.range)
                case .eventName:
                    storage.addAttribute(.foregroundColor, value: parent.theme.string.nsColor, range: token.range)
                    storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: token.range)
                case .declaration:
                    storage.addAttribute(.font, value: boldFont, range: token.range)
                case .parameter:
                    storage.addAttribute(.font, value: italicFont, range: token.range)
                case .unavailable:
                    storage.addAttribute(.foregroundColor, value: parent.theme.error.nsColor, range: token.range)
                    storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: token.range)
                case .variable:
                    break
                }
            }
            storage.endEditing()
            textView.typingAttributes = [.font: font, .foregroundColor: parent.theme.foreground.nsColor]
        }

        private func applyDiagnostics(_ diagnostics: [LuaDiagnostic], in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.underlineColor, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.toolTip, forCharacterRange: fullRange)
            for diagnostic in diagnostics where NSMaxRange(diagnostic.range) <= fullRange.length {
                let style = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                let color: NSColor = diagnostic.severity == .error
                    ? parent.theme.error.nsColor
                    : NSColor.systemOrange
                layoutManager.addTemporaryAttributes([
                    .underlineStyle: style,
                    .underlineColor: color,
                    .toolTip: diagnostic.message,
                ], forCharacterRange: diagnostic.range)
            }
        }

        private func publishAnalysis(for textView: NSTextView, analysis: LuaLanguageAnalysis) {
            let signature = LuaLanguageService.signatureHelp(
                source: textView.string,
                cursorUTF16: textView.selectedRange().location,
                environment: parent.languageEnvironment,
                analysis: analysis
            )
            guard analysis.diagnostics != publishedDiagnostics || signature != publishedSignature else { return }
            publishedDiagnostics = analysis.diagnostics
            publishedSignature = signature
            parent.onAnalysisChange?(analysis.diagnostics, signature)
        }

        // MARK: - runtime validator line

        func applyErrorHighlight(line: Int?, in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            guard let line, line > 0, let range = Self.characterRange(for: line, in: textView.string) else {
                currentErrorLine = nil
                return
            }
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: parent.theme.error.nsColor.withAlphaComponent(0.20),
                forCharacterRange: range
            )
            if line != currentErrorLine { textView.scrollRangeToVisible(range) }
            currentErrorLine = line
        }

        private static func characterRange(for line: Int, in source: String) -> NSRange? {
            guard line >= 1 else { return nil }
            let text = source as NSString
            var currentLine = 1
            var lineStart = 0
            var index = 0
            while index < text.length {
                if currentLine == line {
                    var end = index
                    while end < text.length, text.character(at: end) != 10 { end += 1 }
                    return NSRange(location: lineStart, length: end - lineStart)
                }
                if text.character(at: index) == 10 {
                    currentLine += 1
                    lineStart = index + 1
                }
                index += 1
            }
            return currentLine == line ? NSRange(location: lineStart, length: text.length - lineStart) : nil
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            isUpdating = true
            parent.text = textView.string
            cachedSource = nil
            applyLanguageState(in: textView, forceAnalysis: true)
            isUpdating = false
            parent.onTextChange?()
            updateCompletionPanel(in: textView, force: false)
            updateGhostText(in: textView, announce: false)
            gutter?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let textView else { return }
            parent.selectedRange = textView.selectedRange()
            if completionPanel?.isVisible == true {
                if textView.selectedRange().length > 0 {
                    dismissCompletionPanel()
                } else {
                    // Ordinary typing changes the caret selection after `textDidChange`. Keep the
                    // nonactivating picker synchronized instead of treating that movement as an
                    // external dismissal; explicit selection ranges still close it.
                    updateCompletionPanel(in: textView, force: false)
                }
            }
            if let analysis = cachedAnalysis { publishAnalysis(for: textView, analysis: analysis) }
            updateGhostText(in: textView, announce: false)
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn range: NSRange,
            replacementString text: String?
        ) -> Bool {
            guard let text else { return true }
            let existing = textView.string as NSString
            guard NSMaxRange(range) <= existing.length else { return false }
            let proposed = existing.replacingCharacters(in: range, with: text)
            guard proposed.utf8.count <= 16_384,
                  ScriptingDisplayText.isValidScriptSource(proposed) else {
                NSSound.beep()
                announce("Lua source is limited to 16384 clean UTF-8 bytes.", in: textView)
                return false
            }
            if isInsertingText { return true }
            if text == "\n" {
                let source = textView.string as NSString
                guard range.location <= source.length else { return true }
                let lineRange = source.lineRange(for: NSRange(location: range.location, length: 0))
                let currentLine = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
                let leading = currentLine.prefix { $0 == " " }
                let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
                var indent = String(leading)
                if trimmed.hasSuffix("then") || trimmed.hasSuffix("do") || trimmed == "repeat"
                    || trimmed == "else" || trimmed.hasSuffix("{") || trimmed.contains("function") {
                    indent += "  "
                }
                isInsertingText = true
                textView.insertText("\n" + indent, replacementRange: range)
                isInsertingText = false
                dismissCompletionPanel()
                return false
            }
            return true
        }

        // MARK: - commands and completion

        private func handleKeyDown(_ event: NSEvent) -> Bool {
            guard let textView else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let characters = event.charactersIgnoringModifiers ?? ""

            if modifiers == [.command, .option], characters == "/" {
                parent.onRequestAISuggestion?()
                return true
            }
            if modifiers == .control, event.keyCode == 49 { // Control-Space
                updateCompletionPanel(in: textView, force: true)
                return true
            }
            let isZoomModifier = modifiers == .command || modifiers == [.command, .shift]
            if isZoomModifier, ["+", "=", "-", "0"].contains(characters) {
                if characters == "-" { zoomScale = max(0.75, zoomScale - 0.1) }
                else if characters == "0" { zoomScale = 1 }
                else { zoomScale = min(2, zoomScale + 0.1) }
                applyEditorAppearance(to: textView)
                if let analysis = cachedAnalysis { applyHighlighting(analysis: analysis, in: textView) }
                gutter?.needsDisplay = true
                announce("Editor font \(Int(editorFont().pointSize.rounded())) points", in: textView)
                return true
            }

            if event.keyCode == 124, parent.inlineSuggestion?.isEmpty == false,
               modifiers == .command || modifiers == [.command, .control] {
                if modifiers == [.command, .control] {
                    parent.onAcceptNextAISuggestionLine?()
                } else {
                    parent.onAcceptNextAISuggestionWord?()
                }
                return true
            }

            if completionPanel?.isVisible == true, let controller = completionController {
                switch event.keyCode {
                case 125 where modifiers.isEmpty:
                    controller.moveSelection(by: 1)
                    announceSelectedCompletion(controller, in: textView)
                    return true
                case 126 where modifiers.isEmpty:
                    controller.moveSelection(by: -1)
                    announceSelectedCompletion(controller, in: textView)
                    return true
                case 36, 76, 48:
                    guard modifiers.isEmpty else { break }
                    controller.acceptSelection()
                    return true
                case 53 where modifiers.isEmpty: dismissCompletionPanel(); return true
                default: break
                }
            }
            if event.keyCode == 48, modifiers.isEmpty,
               let suggestion = parent.inlineSuggestion, !suggestion.isEmpty {
                acceptInlineSuggestion(suggestion, in: textView)
                return true
            }
            if event.keyCode == 53, modifiers.isEmpty,
               (parent.inlineSuggestion?.isEmpty == false || parent.isRequestingAISuggestion) {
                parent.onDismissAISuggestion?()
                hideGhostText()
                return true
            }
            if event.keyCode == 48, modifiers.isEmpty || modifiers == .shift {
                changeIndent(in: textView, outdent: modifiers == .shift)
                return true
            }
            return false
        }

        private func changeIndent(in textView: NSTextView, outdent: Bool) {
            let selection = textView.selectedRange()
            if selection.length == 0, !outdent {
                textView.insertText("  ", replacementRange: selection)
                return
            }
            let source = textView.string as NSString
            let lineRange = source.lineRange(for: selection)
            let original = source.substring(with: lineRange)
            var lines = original.components(separatedBy: "\n")
            var firstRemoved = 0
            for index in lines.indices {
                if index == lines.index(before: lines.endIndex), lines[index].isEmpty,
                   original.hasSuffix("\n") { continue }
                if outdent {
                    if lines[index].hasPrefix("  ") {
                        lines[index].removeFirst(2)
                        if index == lines.startIndex { firstRemoved = 2 }
                    } else if lines[index].hasPrefix(" ") || lines[index].hasPrefix("\t") {
                        lines[index].removeFirst()
                        if index == lines.startIndex { firstRemoved = 1 }
                    }
                } else {
                    lines[index] = "  " + lines[index]
                }
            }
            let replacement = lines.joined(separator: "\n")
            isInsertingText = true
            textView.insertText(replacement, replacementRange: lineRange)
            isInsertingText = false
            if selection.length == 0 {
                let adjusted = outdent
                    ? max(lineRange.location, selection.location - firstRemoved)
                    : selection.location + 2
                textView.setSelectedRange(NSRange(location: adjusted, length: 0))
            } else {
                textView.setSelectedRange(NSRange(
                    location: lineRange.location,
                    length: (replacement as NSString).length
                ))
            }
        }

        private func announceSelectedCompletion(
            _ controller: CompletionViewController, in textView: NSTextView
        ) {
            guard let item = controller.selectedItem else { return }
            announce(item.accessibilityLabel, in: textView)
        }

        private func updateCompletionPanel(in textView: NSTextView, force: Bool) {
            let result = LuaLanguageService.completions(
                source: textView.string,
                cursorUTF16: textView.selectedRange().location,
                environment: parent.languageEnvironment,
                analysis: cachedAnalysis
            )
            let shouldPresent: Bool
            switch result.context {
            case .members, .eventName, .objectReference:
                shouldPresent = true
            case .keywordsAndGlobals:
                shouldPresent = force || !result.prefix.isEmpty
            }
            guard shouldPresent, !result.items.isEmpty else {
                dismissCompletionPanel()
                return
            }
            completionResult = result
            showCompletionPanel(items: result.items, prefix: result.prefix, in: textView)
        }

        private func showCompletionPanel(
            items: [LuaCompletionItem], prefix: String, in textView: NSTextView
        ) {
            let controller: CompletionViewController
            if let completionController {
                controller = completionController
            } else {
                controller = CompletionViewController()
                controller.onSelect = { [weak self] item in self?.acceptCompletion(item) }
                controller.onDismiss = { [weak self] in self?.dismissCompletionPanel() }
                controller.onSelectionChange = { [weak self] item in
                    self?.selectedCompletion = item
                    self?.parent.onCompletionDocumentationChange?(item)
                }
                completionController = controller
            }
            controller.suggestions = items

            let panel: LuaCompletionPanel
            if let completionPanel {
                panel = completionPanel
            } else {
                panel = LuaCompletionPanel(contentViewController: controller)
                completionPanel = panel
            }
            panel.setContentSize(NSSize(
                width: 560,
                height: min(240, max(120, CGFloat(items.count) * 40 + 4))
            ))
            let caret = caretRect(in: textView)
            panel.present(relativeTo: caret, of: textView)
            if completionParentResignObserver == nil, let hostWindow = textView.window {
                completionParentResignObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResignKeyNotification,
                    object: hostWindow,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor in self?.dismissCompletionPanel() }
                }
            }
            if completionOutsideClickMonitor == nil {
                completionOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
                ) { [weak self, weak panel] event in
                    guard event.window !== panel else { return event }
                    Task { @MainActor in self?.dismissCompletionPanel() }
                    return event
                }
            }
            ghostLabel?.isHidden = true

            let announcement = "\(items.count) Lua suggestions for \(prefix.isEmpty ? "this member" : prefix). \(items[0].accessibilityLabel)."
            if announcement != lastCompletionAnnouncement {
                lastCompletionAnnouncement = announcement
                announce(announcement, in: textView)
            }
        }

        private func dismissCompletionPanel() {
            completionPanel?.dismiss()
            if let completionParentResignObserver {
                NotificationCenter.default.removeObserver(completionParentResignObserver)
                self.completionParentResignObserver = nil
            }
            if let completionOutsideClickMonitor {
                NSEvent.removeMonitor(completionOutsideClickMonitor)
                self.completionOutsideClickMonitor = nil
            }
            completionResult = nil
            selectedCompletion = nil
            parent.onCompletionDocumentationChange?(nil)
            lastCompletionAnnouncement = nil
            if let textView { updateGhostText(in: textView, announce: false) }
        }

        func dismissCompletionForExternalChange() {
            if completionPanel?.isVisible == true || completionResult != nil {
                dismissCompletionPanel()
            }
        }

        private func acceptCompletion(_ item: LuaCompletionItem) {
            guard let textView, let completionResult else { return }
            let documentLength = (textView.string as NSString).length
            guard NSMaxRange(completionResult.replacementRange) <= documentLength else {
                dismissCompletionPanel()
                return
            }
            isInsertingText = true
            textView.insertText(item.insertionText, replacementRange: completionResult.replacementRange)
            isInsertingText = false
            dismissCompletionPanel()
        }

        // MARK: - optional AI ghost text

        func updateGhostText(in textView: NSTextView, announce shouldAnnounce: Bool) {
            guard completionPanel?.isVisible != true,
                  textView.selectedRange().length == 0,
                  let suggestion = parent.inlineSuggestion,
                  !suggestion.isEmpty,
                  let ghostLabel else {
                hideGhostText()
                return
            }
            let visual = visualGhostText(suggestion)
            ghostLabel.stringValue = visual
            ghostLabel.toolTip = "AI suggestion. Tab accepts; Escape dismisses."
            ghostLabel.setAccessibilityLabel("AI suggestion: \(suggestion). Press Tab to accept or Escape to dismiss.")
            ghostLabel.sizeToFit()
            let caret = caretRect(in: textView)
            let availableWidth = max(80, textView.visibleRect.maxX - caret.maxX - 8)
            ghostLabel.frame = NSRect(
                x: caret.maxX + 1,
                y: caret.minY,
                width: min(availableWidth, ghostLabel.frame.width),
                height: max(caret.height, ghostLabel.frame.height)
            )
            ghostLabel.isHidden = false
            if shouldAnnounce, suggestion != lastAnnouncedGhost {
                lastAnnouncedGhost = suggestion
                announce("AI suggestion available. Press Tab to accept or Escape to dismiss.", in: textView)
            }
        }

        private func visualGhostText(_ suggestion: String) -> String {
            if suggestion.hasPrefix("\n") {
                let remaining = suggestion.dropFirst().split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                return "↵ \(remaining)" + (suggestion.dropFirst().contains("\n") ? " …" : "")
            }
            let firstLine = suggestion.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return String(firstLine) + (suggestion.contains("\n") ? " ↵ …" : "")
        }

        private func acceptInlineSuggestion(_ suggestion: String, in textView: NSTextView) {
            let range = textView.selectedRange()
            isInsertingText = true
            textView.insertText(suggestion, replacementRange: range)
            isInsertingText = false
            parent.onAcceptAISuggestion?(suggestion)
            hideGhostText()
        }

        private func hideGhostText() {
            ghostLabel?.isHidden = true
            lastAnnouncedGhost = nil
        }

        // MARK: - geometry/accessibility

        private func caretRect(in textView: NSTextView) -> NSRect {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
                return NSRect(x: textView.textContainerInset.width, y: textView.textContainerInset.height, width: 1, height: editorFont().pointSize + 4)
            }
            layoutManager.ensureLayout(for: container)
            let character = min(textView.selectedRange().location, (textView.string as NSString).length)
            var rect: NSRect
            if character < (textView.string as NSString).length, layoutManager.numberOfGlyphs > 0 {
                let glyph = layoutManager.glyphIndexForCharacter(at: character)
                rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                rect.size.width = 1
            } else if layoutManager.extraLineFragmentTextContainer != nil {
                rect = layoutManager.extraLineFragmentRect
                rect.size.width = 1
            } else if layoutManager.numberOfGlyphs > 0 {
                let glyph = layoutManager.numberOfGlyphs - 1
                let last = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                rect = NSRect(x: last.maxX, y: last.minY, width: 1, height: last.height)
            } else {
                rect = NSRect(x: 0, y: 0, width: 1, height: editorFont().pointSize + 4)
            }
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            if rect.height <= 1 { rect.size.height = editorFont().pointSize + 4 }
            return rect
        }

        private func announce(_ message: String, in textView: NSTextView) {
            NSAccessibility.post(
                element: textView,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: message,
                    .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ]
            )
        }
    }
}
