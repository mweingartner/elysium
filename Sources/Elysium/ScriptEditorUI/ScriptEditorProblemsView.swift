// ScriptEditorProblemsView.swift — compact, keyboard-accessible presentation of deterministic
// editor diagnostics and their local quick fixes. Runtime validation remains authoritative.

import SwiftUI

struct ScriptEditorProblemsView: View {
    let diagnostics: [LuaDiagnostic]
    let source: String
    let select: (LuaDiagnostic) -> Void
    let applyFix: (LuaQuickFix) -> Void

    @Environment(\.scriptEditorTheme) private var theme

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(diagnostics) { diagnostic in
                    VStack(alignment: .leading, spacing: 4) {
                        SwiftUI.Button {
                            select(diagnostic)
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: iconName(for: diagnostic.severity))
                                    .foregroundStyle(color(for: diagnostic.severity))
                                    .accessibilityHidden(true)
                                Text(diagnostic.message)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(.primary)
                                Text(locationText(for: diagnostic))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            "\(diagnostic.severity.rawValue), \(diagnostic.message), \(locationText(for: diagnostic))"
                        )

                        if !diagnostic.quickFixes.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(Array(diagnostic.quickFixes.enumerated()), id: \.offset) { _, fix in
                                    SwiftUI.Button(fix.title) { applyFix(fix) }
                                        .controlSize(.small)
                                }
                            }
                            .padding(.leading, 22)
                        }
                    }
                    .padding(.horizontal, theme.spacing)
                    .padding(.vertical, 4)
                    .background(theme.panelBackground.color.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: theme.cornerRadiusSmall))
                }
            }
            .padding(theme.spacing)
        }
        .frame(maxHeight: 150)
        .accessibilityLabel("Lua problems")
    }

    private func iconName(for severity: LuaDiagnosticSeverity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .information: "info.circle.fill"
        }
    }

    private func color(for severity: LuaDiagnosticSeverity) -> Color {
        switch severity {
        case .error: theme.error.color
        case .warning: .orange
        case .information: .blue
        }
    }

    private func locationText(for diagnostic: LuaDiagnostic) -> String {
        let text = source as NSString
        let location = min(max(0, diagnostic.range.location), text.length)
        var line = 1
        var lineStart = 0
        if location > 0 {
            for index in 0..<location where text.character(at: index) == 10 {
                line += 1
                lineStart = index + 1
            }
        }
        return "line \(line), column \(location - lineStart + 1)"
    }
}
