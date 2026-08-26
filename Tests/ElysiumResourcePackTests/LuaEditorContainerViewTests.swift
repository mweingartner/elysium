import AppKit
import XCTest
@testable import Elysium

@MainActor
final class LuaEditorContainerViewTests: XCTestCase {
    func testContainerDoesNotOptTextKitSubtreeIntoLayerBacking() {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        let gutter = LuaLineNumberGutterView(textView: textView, theme: .defaultDark)

        let container = LuaEditorContainerView(scrollView: scrollView, gutter: gutter)

        XCTAssertFalse(container.wantsLayer)
        XCTAssertNil(container.layer)
        XCTAssertFalse(gutter.wantsLayer)
        XCTAssertFalse(scrollView.wantsLayer)
    }
}
