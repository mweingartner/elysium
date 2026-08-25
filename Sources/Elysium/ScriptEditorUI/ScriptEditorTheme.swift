// ScriptEditorTheme.swift — native SwiftUI script editor (Stage A). A compact token bag ported
// from Hype's `HypeScriptTheme`/`HypeTheme` (`~/dev/hype-v2/Sources/HypeCore/Theme/HypeTheme.swift`):
// the same audited light/dark script palettes (every token/background pair meets WCAG AA — 4.5:1
// normal text, 3:1 for the gutter) and the same luminance-derived `colorScheme` trick that keeps
// labels legible regardless of which appearance is active. Elysium has no theme cascade (Hype's
// `HypeTheme` is one of many user themes; this window always uses the system light/dark palette),
// so this is a single environment value, not a whole theming system.

import SwiftUI
import AppKit

/// One color entry, resolved eagerly to both `NSColor` and `Color` — the editor's AppKit text
/// view and its SwiftUI chrome read the same palette without re-deriving colors on every draw.
struct ScriptEditorColor: Equatable {
    let hex: UInt32

    var nsColor: NSColor {
        let r = CGFloat((hex >> 16) & 0xFF) / 255
        let g = CGFloat((hex >> 8) & 0xFF) / 255
        let b = CGFloat(hex & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// The full token bag a script-editor surface needs: background/foreground, every
/// `LuaSyntaxSpanKind` color, chrome accents, and the structural ratios (radii/spacing/font size)
/// that keep the three-column layout consistent. Ported field-for-field from Hype's
/// `HypeScriptTheme` plus `HypeTheme`'s corner-radius/spacing tokens.
struct ScriptEditorTheme: Equatable {
    var background: ScriptEditorColor
    var foreground: ScriptEditorColor
    var keyword: ScriptEditorColor
    var command: ScriptEditorColor
    var string: ScriptEditorColor
    var number: ScriptEditorColor
    var comment: ScriptEditorColor
    var property: ScriptEditorColor
    var error: ScriptEditorColor
    var selection: ScriptEditorColor
    var lineNumber: ScriptEditorColor
    var currentLine: ScriptEditorColor
    var toolbarBackground: ScriptEditorColor
    var panelBackground: ScriptEditorColor
    var divider: ScriptEditorColor

    var fontSize: CGFloat = 13
    var cornerRadiusSmall: CGFloat = 6
    var cornerRadiusLarge: CGFloat = 12
    var spacing: CGFloat = 8

    func color(for kind: LuaSyntaxSpanKind) -> ScriptEditorColor {
        switch kind {
        case .plain: return foreground
        case .keyword: return keyword
        case .string: return string
        case .comment: return comment
        case .number: return number
        }
    }

    /// Hype's own audited light palette (`HypeScriptTheme.defaultLight`) — every value already
    /// passed `ThemeContrastAuditTests` there; reused verbatim rather than re-deriving new hexes.
    static let defaultLight = ScriptEditorTheme(
        background: ScriptEditorColor(hex: 0xFFFFFF),
        foreground: ScriptEditorColor(hex: 0x1A1A1A),
        keyword: ScriptEditorColor(hex: 0x7E1FFA),
        command: ScriptEditorColor(hex: 0x0A66E0),
        string: ScriptEditorColor(hex: 0xA3174F),
        number: ScriptEditorColor(hex: 0x1D874A),
        comment: ScriptEditorColor(hex: 0x727272),
        property: ScriptEditorColor(hex: 0x0E5A99),
        error: ScriptEditorColor(hex: 0xD32F2F),
        selection: ScriptEditorColor(hex: 0xCFE3FF),
        lineNumber: ScriptEditorColor(hex: 0x949494),
        currentLine: ScriptEditorColor(hex: 0xF0F0F4),
        toolbarBackground: ScriptEditorColor(hex: 0xF6F6F8),
        panelBackground: ScriptEditorColor(hex: 0xFAFAFB),
        divider: ScriptEditorColor(hex: 0xE0E0E4)
    )

    /// Hype's audited dark palette (`HypeScriptTheme.defaultDark`).
    static let defaultDark = ScriptEditorTheme(
        background: ScriptEditorColor(hex: 0x1E1E22),
        foreground: ScriptEditorColor(hex: 0xE8E8EC),
        keyword: ScriptEditorColor(hex: 0xC792EA),
        command: ScriptEditorColor(hex: 0x82AAFF),
        string: ScriptEditorColor(hex: 0xF78C6C),
        number: ScriptEditorColor(hex: 0xA5E844),
        comment: ScriptEditorColor(hex: 0x848491),
        property: ScriptEditorColor(hex: 0x89DDFF),
        error: ScriptEditorColor(hex: 0xFF6B6B),
        selection: ScriptEditorColor(hex: 0x2C4C74),
        lineNumber: ScriptEditorColor(hex: 0x686876),
        currentLine: ScriptEditorColor(hex: 0x26262E),
        toolbarBackground: ScriptEditorColor(hex: 0x252529),
        panelBackground: ScriptEditorColor(hex: 0x212125),
        divider: ScriptEditorColor(hex: 0x333338)
    )

    /// Picks light/dark by the *system* appearance — Elysium has no per-document theme
    /// cascade, so this is the one and only source of truth (unlike Hype's per-theme
    /// `scriptTheme`, which is itself one of many swappable themes).
    static func resolved(for colorScheme: ColorScheme) -> ScriptEditorTheme {
        colorScheme == .dark ? .defaultDark : .defaultLight
    }

    /// Resolves the *current* system light/dark appearance synchronously via AppKit
    /// (`NSApp.effectiveAppearance`) — for use as a `@State` initial value, where SwiftUI's own
    /// `\.colorScheme` environment isn't populated yet (a stored-property initializer runs before
    /// the view is inserted into a hierarchy). Rendering-bug fix: `ScriptEditorView` previously
    /// defaulted its `@State` theme to `.defaultLight` and only corrected it in `.onAppear`,
    /// producing one frame (and, if a later re-render was ever skipped, a persistent state) of
    /// light-theme colors — most dangerously, dark-on-dark-background text that reads as
    /// "invisible" even though the text is genuinely loaded. Resolving the real appearance up
    /// front removes that light->dark flip entirely.
    static func currentSystem() -> ScriptEditorTheme {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? .defaultDark : .defaultLight
    }

    /// Hype's `HypeTheme.colorSchemeForBackground` trick, ported: derive the `ColorScheme` that
    /// should govern text drawn on `background` from its own relative luminance, rather than
    /// trusting the OS appearance. Since our palettes are picked *from* the OS appearance already
    /// this normally agrees with it — the guard exists so a future themed background can never
    /// produce illegible labels the way a naive `.foregroundColor(.primary)` could.
    var chromeColorScheme: ColorScheme {
        Self.colorScheme(forLuminanceOf: panelBackground)
    }

    private static func colorScheme(forLuminanceOf color: ScriptEditorColor) -> ColorScheme {
        let r = Double((color.hex >> 16) & 0xFF) / 255
        let g = Double((color.hex >> 8) & 0xFF) / 255
        let b = Double(color.hex & 0xFF) / 255
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        return luminance > 0.5 ? .light : .dark
    }
}

private struct ScriptEditorThemeKey: EnvironmentKey {
    static let defaultValue: ScriptEditorTheme = .defaultLight
}

extension EnvironmentValues {
    var scriptEditorTheme: ScriptEditorTheme {
        get { self[ScriptEditorThemeKey.self] }
        set { self[ScriptEditorThemeKey.self] = newValue }
    }
}
