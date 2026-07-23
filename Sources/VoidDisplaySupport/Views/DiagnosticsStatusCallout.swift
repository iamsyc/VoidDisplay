import SwiftUI
import VoidDisplayDesignSystem

struct DiagnosticsStatusCallout: View {
    let title: String
    let detail: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: AppUI.Spacing.medium) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .accessibilityIdentifier("diagnostics_health_status_icon")

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("diagnostics_health_status_title")
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(AppUI.Spacing.medium)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppUI.Corner.small, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: AppUI.Stroke.subtle)
        )
    }
}
