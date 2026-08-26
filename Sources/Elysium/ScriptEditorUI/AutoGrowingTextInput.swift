// AutoGrowingTextInput.swift — native SwiftUI script editor (Stage A). Ported from Hype's
// `Hype/Views/AIChatInputView.swift`: a zero-inset `NSTextView` wrapper (so glyphs line up with a
// sibling SwiftUI `Text` placeholder using the same padding) that publishes its laid-out content
// height so the surrounding SwiftUI frame can grow with the prompt (32...320pt, matching the
// architecture doc), plus `AIChatPromptHistory` (append/dedup/cap-100/recall) and the Enter-to-
// submit / Shift+Enter-newline / ↑↓-history-on-first/last-line `NSTextView` subclass, all carried
// over verbatim — this is generic chat-input plumbing, nothing HypeTalk-specific.

import SwiftUI
import AppKit

struct AutoGrowingTextInput: NSViewRepresentable {
    @Binding var text: String
    @Binding var contentHeight: CGFloat
    var isEnabled: Bool = true
    var onSubmit: () -> Void = {}
    var onHistoryUp: () -> Void = {}
    var onHistoryDown: () -> Void = {}
    var accessibilityIdentifier: String = "scriptEditor.aiPrompt"
    var accessibilityLabel: String = "AI prompt"

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = ScriptChatInputTextView()
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.font = NSFont.preferredFont(forTextStyle: .body)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.labelColor
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false

        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        textView.delegate = context.coordinator
        textView.onSubmit = { context.coordinator.parent.onSubmit() }
        textView.onHistoryUp = { context.coordinator.parent.onHistoryUp() }
        textView.onHistoryDown = { context.coordinator.parent.onHistoryDown() }
        textView.setAccessibilityElement(true)
        textView.setAccessibilityRole(.textArea)
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(accessibilityLabel)
        scrollView.setAccessibilityElement(false)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        textView.string = text

        DispatchQueue.main.async {
            context.coordinator.publishContentHeight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ScriptChatInputTextView else { return }
        context.coordinator.parent = self

        if textView.string != text {
            textView.string = text
            let len = (text as NSString).length
            textView.setSelectedRange(NSRange(location: len, length: 0))
            DispatchQueue.main.async {
                context.coordinator.publishContentHeight()
            }
        }
        if textView.isEditable != isEnabled {
            textView.isEditable = isEnabled
        }
        let preferredFont = NSFont.preferredFont(forTextStyle: .body)
        if textView.font?.fontName != preferredFont.fontName ||
            textView.font?.pointSize != preferredFont.pointSize {
            textView.font = preferredFont
            DispatchQueue.main.async {
                context.coordinator.publishContentHeight()
            }
        }
        textView.setAccessibilityIdentifier(accessibilityIdentifier)
        textView.setAccessibilityLabel(accessibilityLabel)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AutoGrowingTextInput
        weak var textView: ScriptChatInputTextView?

        init(_ parent: AutoGrowingTextInput) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            publishContentHeight()
        }

        func publishContentHeight() {
            guard let textView, let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            let measured = max(used.height, 18)
            if abs(parent.contentHeight - measured) > 0.5 {
                parent.contentHeight = measured
            }
        }
    }
}

enum AIChatPromptHistoryDirection {
    case up
    case down
}

enum AIChatPromptHistory {
    static let maxEntries = 100

    static func appending(_ prompt: String, to history: [String]) -> [String] {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return history }
        var updated = history
        if updated.last != text {
            updated.append(text)
        }
        if updated.count > maxEntries {
            updated.removeFirst(updated.count - maxEntries)
        }
        return updated
    }

    static func recall(
        direction: AIChatPromptHistoryDirection,
        from history: [String],
        index: inout Int
    ) -> String? {
        guard !history.isEmpty else { return nil }
        switch direction {
        case .up:
            if index < 0 {
                index = history.count - 1
            } else if index > 0 {
                index -= 1
            }
            return history[index]
        case .down:
            if index >= 0 && index < history.count - 1 {
                index += 1
                return history[index]
            } else {
                index = -1
                return ""
            }
        }
    }
}

/// `NSTextView` subclass intercepting Enter (send) and ↑/↓ (history recall on the first/last
/// line only — otherwise the arrow just moves the caret as usual).
final class ScriptChatInputTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var onHistoryUp: () -> Void = {}
    var onHistoryDown: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) {
            onSubmit()
            return
        }
        if event.keyCode == 126, cursorIsOnFirstLine() {
            onHistoryUp()
            return
        }
        if event.keyCode == 125, cursorIsOnLastLine() {
            onHistoryDown()
            return
        }
        super.keyDown(with: event)
    }

    private func cursorIsOnFirstLine() -> Bool {
        guard let layoutManager else { return true }
        let selRange = selectedRange()
        let glyphRange = layoutManager.glyphRange(forCharacterRange: selRange, actualCharacterRange: nil)
        let lineRange = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        return lineRange.origin.y == 0
    }

    private func cursorIsOnLastLine() -> Bool {
        guard let layoutManager else { return true }
        let totalGlyphs = layoutManager.numberOfGlyphs
        guard totalGlyphs > 0 else { return true }
        let selRange = selectedRange()
        let glyphIdx = layoutManager.glyphRange(forCharacterRange: selRange, actualCharacterRange: nil).location
        if glyphIdx >= totalGlyphs - 1 { return true }
        let cursorRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
        let lastRect = layoutManager.lineFragmentRect(forGlyphAt: totalGlyphs - 1, effectiveRange: nil)
        return cursorRect.origin.y == lastRect.origin.y
    }
}
