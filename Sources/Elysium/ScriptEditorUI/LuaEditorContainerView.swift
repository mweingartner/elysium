// LuaEditorContainerView.swift — AppKit container that lays out the gutter beside, rather than
// inside, the scroll view's TextKit drawing path.

import AppKit

final class LuaEditorContainerView: NSView {
    let scrollView: NSScrollView
    let gutter: LuaLineNumberGutterView

    init(scrollView: NSScrollView, gutter: LuaLineNumberGutterView) {
        self.scrollView = scrollView
        self.gutter = gutter
        super.init(frame: .zero)
        // Stay non-layer-backed. This container lives inside NSHostingView; forcing a layer on
        // the TextKit subtree changes the mixed AppKit/SwiftUI compositing order and can place
        // SwiftUI's drawing surface above otherwise live toolbar controls.

        gutter.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gutter)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 42),
            scrollView.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}
