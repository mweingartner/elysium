// LuaCodeTextView.swift — native SwiftUI script editor (Stage A). An `NSTextView`-based Lua code
// editor ported from Hype's `HypeTalkTextView.swift`: the same two-way binding + `isUpdating`
// guard, the same TextKit syntax-highlighting pass (batched in begin/endEditing, re-run every
// keystroke), and the same temporary-attribute (non-destructive) error-line highlight. Adapted
// from HypeTalk to Lua (`LuaSyntaxColoring` instead of `HypeTalkHighlighter`), and extended with a
// line-number gutter (Hype's editor had none — added here for polish) and the context-aware
// completion popup (`LuaCompletion.swift`).
//
// **Rendering:** hand-built TextKit-1 NSScrollView+NSTextView (the `scrollableTextView()` factory
// gives a TextKit-2 view that this file's TextKit-1 ruler/highlighter can't drive — glyphs stayed
// invisible). The scroll view uses `translatesAutoresizingMaskIntoConstraints = false` so SwiftUI
// constrains it to its own layout slot (no overlap of the toolbar above), and all backgrounds are
// transparent so SwiftUI's `.background(theme.background)` paints behind the text.
import SwiftUI
import AppKit
import ElysiumCore

struct LuaCodeTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange
    var errorLine: Int?
    var targetKind: ObjectKind
    var theme: ScriptEditorTheme
    var onTextChange: (() -> Void)? = nil

    func makeNSView(context: Context) -> NSView {
        // Mirrors the (working) AI chat input's NSTextView setup: a hand-built NSScrollView +
        // NSTextView, TextKit 1. The `NSTextView.scrollableTextView()` factory yields a TextKit 2
        // view on recent macOS, whose glyphs never rendered here because the ruler and highlighter
        // drive it through TextKit-1 `layoutManager`/`textStorage`. `translatesAutoresizingMask...
        // = false` lets SwiftUI constrain the scroll view to its own layout slot (so it can't
        // draw over the toolbar above it) WITHOUT an opaque AppKit container that composited over
        // the text. Backgrounds stay transparent — SwiftUI paints the editor background behind it.
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 8)

        let font = NSFont(name: "Menlo", size: theme.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: theme.fontSize, weight: .regular)
        textView.font = font
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textColor = theme.foreground.nsColor
        textView.insertionPointColor = theme.foreground.nsColor
        textView.selectedTextAttributes = [.backgroundColor: theme.selection.nsColor]
        textView.typingAttributes = [.font: font, .foregroundColor: theme.foreground.nsColor]
        textView.delegate = context.coordinator
        textView.setAccessibilityElement(true)
        textView.setAccessibilityRole(.textArea)
        textView.setAccessibilityLabel("Lua script")
        textView.setAccessibilityIdentifier("scriptEditor.source")

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView

        // NOTE: no NSRulerView line-number gutter. An NSRulerView attached to this scroll view
        // (inside the SwiftUI NSHostingView) suppressed all glyph AND sibling-toolbar drawing in
        // the center column — a documented AppKit/TextKit + hosting-view interaction. The editor
        // is fully functional and syntax-highlighted without it; a gutter can be re-added later via
        // a SwiftUI-side line strip synced to scroll, which does not touch the AppKit draw path.

        textView.string = text
        context.coordinator.applySyntaxHighlight(in: textView)

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        context.coordinator.parent = self
        context.coordinator.ruler?.theme = theme

        // Keep the scroll view transparent so SwiftUI's `.background(theme.background)` shows
        // through (recomputed each pass, never cached, so a theme change can't leave it stale).
        context.coordinator.scrollView?.backgroundColor = .clear

        guard !context.coordinator.isUpdating else { return }
        if textView.string != text {
            context.coordinator.isUpdating = true
            textView.string = text
            let maxLoc = (text as NSString).length
            if selectedRange.location <= maxLoc {
                let length = min(selectedRange.length, maxLoc - selectedRange.location)
                textView.setSelectedRange(NSRange(location: selectedRange.location, length: max(0, length)))
            }
            context.coordinator.isUpdating = false
        } else if textView.selectedRange() != selectedRange {
            let maxLoc = (text as NSString).length
            if selectedRange.location <= maxLoc {
                let length = min(selectedRange.length, maxLoc - selectedRange.location)
                textView.setSelectedRange(NSRange(location: selectedRange.location, length: max(0, length)))
            }
        }

        // Re-apply every theme-derived color unconditionally on every pass — including
        // `typingAttributes` (previously only set once, in `makeNSView`, so newly-typed
        // characters after a theme change would silently keep using the OLD foreground color).
        let font = NSFont(name: "Menlo", size: theme.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: theme.fontSize, weight: .regular)
        let fg = theme.foreground.nsColor
        textView.backgroundColor = .clear
        textView.textColor = fg
        textView.insertionPointColor = fg
        textView.selectedTextAttributes = [.backgroundColor: theme.selection.nsColor]
        textView.typingAttributes = [.font: font, .foregroundColor: fg]

        context.coordinator.applySyntaxHighlight(in: textView)

        let requested = errorLine
        if requested != context.coordinator.currentErrorLine || requested != nil {
            context.coordinator.applyErrorHighlight(line: requested, in: textView)
        }
        context.coordinator.ruler?.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LuaCodeTextView
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        weak var ruler: LuaLineNumberRulerView?
        var isUpdating = false
        var currentErrorLine: Int? = nil
        private var isInsertingText = false

        // completion popover state
        private var completionPopover: NSPopover?
        private var completionController: CompletionViewController?

        init(parent: LuaCodeTextView) {
            self.parent = parent
        }

        // MARK: - syntax highlight (TextKit temporary/permanent attribute runs)

        func applySyntaxHighlight(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let source = textView.string
            let nsSource = source as NSString
            let fullRange = NSRange(location: 0, length: nsSource.length)
            let theme = parent.theme
            storage.beginEditing()
            storage.removeAttribute(.foregroundColor, range: fullRange)
            storage.addAttribute(.foregroundColor, value: theme.foreground.nsColor, range: fullRange)
            let lines = source.components(separatedBy: "\n")
            let allSpans = LuaSyntaxColoring.colorLines(lines)
            var lineStart = 0
            for (index, line) in lines.enumerated() {
                let chars = Array(line)
                for span in allSpans[index] {
                    guard span.range.upperBound <= chars.count else { continue }
                    let nsRange = NSRange(location: lineStart + span.range.lowerBound, length: span.range.count)
                    guard nsRange.location + nsRange.length <= nsSource.length else { continue }
                    storage.addAttribute(.foregroundColor, value: theme.color(for: span.kind).nsColor, range: nsRange)
                }
                lineStart += chars.count + 1 // +1 for the '\n' this component was split on
            }
            storage.endEditing()
        }

        // MARK: - error line (layout-manager temporary attribute — non-destructive)

        func applyErrorHighlight(line: Int?, in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            guard let line, line > 0, let range = Self.characterRange(for: line, in: textView.string) else {
                currentErrorLine = nil
                return
            }
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: parent.theme.error.nsColor.withAlphaComponent(0.20),
                forCharacterRange: range
            )
            textView.scrollRangeToVisible(range)
            currentErrorLine = line
        }

        private static func characterRange(for line: Int, in source: String) -> NSRange? {
            guard line >= 1 else { return nil }
            let nsString = source as NSString
            var currentLine = 1
            var rangeStart = 0
            var idx = 0
            let length = nsString.length
            while idx < length {
                if currentLine == line {
                    var end = idx
                    while end < length, nsString.character(at: end) != 0x0A { end += 1 }
                    return NSRange(location: rangeStart, length: end - rangeStart)
                }
                if nsString.character(at: idx) == 0x0A {
                    currentLine += 1
                    rangeStart = idx + 1
                }
                idx += 1
            }
            if currentLine == line { return NSRange(location: rangeStart, length: length - rangeStart) }
            return nil
        }

        // MARK: - NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let tv = textView else { return }
            isUpdating = true
            parent.text = tv.string
            applySyntaxHighlight(in: tv)
            isUpdating = false
            parent.onTextChange?()
            updateCompletionPopover(in: tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isUpdating, let tv = textView else { return }
            parent.selectedRange = tv.selectedRange()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
            guard let text, !isInsertingText else { return true }
            if text == "\t" {
                isInsertingText = true
                textView.insertText("  ", replacementRange: range)
                isInsertingText = false
                return false
            }
            if text == "\n" {
                let source = textView.string
                let nsString = source as NSString
                guard range.location <= nsString.length else { return true }
                let lineRange = nsString.lineRange(for: NSRange(location: range.location, length: 0))
                let currentLine = nsString.substring(with: lineRange).trimmingCharacters(in: .newlines)
                var indent = ""
                for ch in currentLine {
                    if ch == " " { indent += " " } else { break }
                }
                let trimmed = currentLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix("function") || trimmed.hasSuffix("then") || trimmed.hasSuffix("do")
                    || trimmed.hasPrefix("repeat") || trimmed == "else" {
                    indent += "  "
                }
                isInsertingText = true
                textView.insertText("\n" + indent, replacementRange: range)
                isInsertingText = false
                dismissCompletionPopover()
                return false
            }
            return true
        }

        // MARK: - completion popover

        private func updateCompletionPopover(in textView: NSTextView) {
            let cursor = textView.selectedRange().location
            let source = textView.string
            let (prefix, _) = LuaCompletion.currentPrefix(source: source, cursorIndex: cursor)
            guard !prefix.isEmpty else {
                dismissCompletionPopover()
                return
            }
            let ctx = LuaCompletion.context(source: source, cursorIndex: cursor)
            let suggestions = LuaCompletion.suggestions(context: ctx, prefix: prefix, targetKind: parent.targetKind)
            guard !suggestions.isEmpty else {
                dismissCompletionPopover()
                return
            }
            showCompletionPopover(suggestions: suggestions, in: textView)
        }

        private func showCompletionPopover(suggestions: [String], in textView: NSTextView) {
            let controller: CompletionViewController
            if let existing = completionController {
                controller = existing
            } else {
                controller = CompletionViewController()
                controller.onSelect = { [weak self] chosen in self?.acceptCompletion(chosen) }
                controller.onDismiss = { [weak self] in self?.dismissCompletionPopover() }
                completionController = controller
            }
            controller.suggestions = suggestions

            let popover: NSPopover
            if let existing = completionPopover {
                popover = existing
            } else {
                popover = NSPopover()
                popover.behavior = .transient
                popover.contentViewController = controller
                completionPopover = popover
            }
            popover.contentSize = NSSize(width: 220, height: min(150, CGFloat(suggestions.count) * 20 + 4))

            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: textView.selectedRange().location)
            var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: max(0, glyphIndex - 1), length: 1), in: container)
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height

            if popover.isShown {
                popover.contentSize = popover.contentSize
            } else {
                popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            }
        }

        private func dismissCompletionPopover() {
            completionPopover?.performClose(nil)
        }

        private func acceptCompletion(_ chosen: String) {
            guard let tv = textView else { return }
            let cursor = tv.selectedRange().location
            let (_, prefixRange) = LuaCompletion.currentPrefix(source: tv.string, cursorIndex: cursor)
            isInsertingText = true
            tv.insertText(chosen, replacementRange: prefixRange)
            isInsertingText = false
            dismissCompletionPopover()
        }
    }
}

// MARK: - line-number gutter

/// A minimal line-number ruler (Hype's editor shipped without one). Draws right-aligned line
/// numbers per wrapped-free line fragment, redrawn on every `updateNSView` pass (source sizes are
/// capped at 16 KiB — a few hundred lines at most — so a full redraw per keystroke is cheap).
final class LuaLineNumberRulerView: NSRulerView {
    var theme: ScriptEditorTheme

    init(textView: NSTextView, theme: ScriptEditorTheme) {
        self.theme = theme
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 32
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }
        theme.panelBackground.nsColor.setFill()
        rect.fill()

        let nsString = textView.string as NSString
        let visibleRect = textView.visibleRect
        let inset = textView.textContainerInset
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: theme.lineNumber.nsColor,
        ]

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineFragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            // Only label the first glyph of each line (i.e. skip wrapped continuation fragments).
            var lineStart = 0
            nsString.getLineStart(&lineStart, end: nil, contentsEnd: nil, for: NSRange(location: charIndex, length: 0))
            if lineStart == charIndex || glyphIndex == glyphRange.location {
                let lineNumber = Self.lineNumber(for: charIndex, in: nsString)
                let text = String(lineNumber)
                let size = text.size(withAttributes: attrs)
                let y = lineFragmentRect.minY + inset.height - visibleRect.minY
                let x = ruleThickness - size.width - 6
                text.draw(at: NSPoint(x: max(2, x), y: y), withAttributes: attrs)
            }
            var effectiveRange = NSRange(location: 0, length: 0)
            _ = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)
            glyphIndex = NSMaxRange(effectiveRange)
        }
    }

    private static func lineNumber(for charIndex: Int, in nsString: NSString) -> Int {
        var line = 1
        var i = 0
        while i < charIndex, i < nsString.length {
            if nsString.character(at: i) == 0x0A { line += 1 }
            i += 1
        }
        return line
    }
}
