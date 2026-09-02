import SwiftUI
import ElysiumCore

struct RPGNativeStatusBanner: View {
    let authority: RPGAuthorityPhasePresentation
    let status: RPGStatusPresentation?

    private var symbol: String {
        guard let status else {
            return authority.disabledControlExplanation == nil
                ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        }
        switch status.kind {
        case .success: return "checkmark.circle.fill"
        case .pending: return "clock.fill"
        case .cooldown: return "timer"
        case .fatigue: return "bolt.slash.fill"
        case .missingFocus: return "scope"
        case .missingEquipment: return "shield.slash.fill"
        case .persistenceFailure: return "externaldrive.badge.exclamationmark"
        case .rejection, .permissionDenied, .authorityExhausted:
            return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        guard let status else {
            return authority.disabledControlExplanation == nil ? .secondary : .orange
        }
        switch status.kind {
        case .success: return .green
        case .pending, .cooldown: return .blue
        case .fatigue, .missingFocus, .missingEquipment: return .orange
        case .rejection, .permissionDenied, .persistenceFailure, .authorityExhausted:
            return .red
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(status?.text ?? authority.visibleTitle)
                    .font(.headline)
                Text(authority.visibleHelp)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status == nil ? authority.visibleTitle : "Character status")
        .accessibilityValue([status?.accessibilityText, authority.visibleHelp]
            .compactMap { $0 }
            .joined(separator: " "))
    }
}
