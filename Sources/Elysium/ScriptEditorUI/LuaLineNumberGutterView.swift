// LuaLineNumberGutterView.swift — independent sibling gutter for the TextKit editor. It avoids
// NSRulerView, whose hosting-view interaction previously suppressed editor glyph rendering.

import AppKit

final class LuaLineNumberGutterView: NSView {
    weak var textView: NSTextView?
    var theme: ScriptEditorTheme { didSet { needsDisplay = true } }

    init(textView: NSTextView, theme: ScriptEditorTheme) {
        self.textView = textView
        self.theme = theme
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        theme.panelBackground.nsColor.setFill()
        dirtyRect.fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return
        }

        let source = textView.string as NSString
        let visibleRect = textView.visibleRect
        let inset = textView.textContainerInset
        let preferredSize = NSFont.preferredFont(forTextStyle: .caption1).pointSize
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: preferredSize, weight: .regular),
            .foregroundColor: theme.lineNumber.nsColor,
        ]

        if source.length == 0 {
            drawLineNumber(1, y: inset.height, attributes: attributes)
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        var glyphIndex = glyphRange.location
        var lastLineStart = -1
        var currentLineNumber: Int?
        while glyphIndex < NSMaxRange(glyphRange), glyphIndex < layoutManager.numberOfGlyphs {
            let characterIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            var lineStart = 0
            source.getLineStart(&lineStart, end: nil, contentsEnd: nil,
                                for: NSRange(location: min(characterIndex, source.length), length: 0))
            var fragmentRange = NSRange(location: 0, length: 0)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &fragmentRange)
            if lineStart != lastLineStart {
                let lineNumber: Int
                if let currentLineNumber {
                    lineNumber = currentLineNumber + 1
                } else {
                    lineNumber = 1 + newlineCount(in: source, before: lineStart)
                }
                currentLineNumber = lineNumber
                let y = fragment.minY + inset.height - visibleRect.minY
                drawLineNumber(lineNumber, y: y, attributes: attributes)
                lastLineStart = lineStart
            }
            let next = NSMaxRange(fragmentRange)
            glyphIndex = next > glyphIndex ? next : glyphIndex + 1
        }
    }

    private func drawLineNumber(
        _ line: Int, y: CGFloat, attributes: [NSAttributedString.Key: Any]
    ) {
        let value = String(line)
        let size = value.size(withAttributes: attributes)
        value.draw(
            at: NSPoint(x: max(3, bounds.width - size.width - 7), y: y),
            withAttributes: attributes
        )
    }

    private func newlineCount(in source: NSString, before end: Int) -> Int {
        var count = 0
        var index = 0
        while index < end, index < source.length {
            if source.character(at: index) == 10 { count += 1 }
            index += 1
        }
        return count
    }
}
