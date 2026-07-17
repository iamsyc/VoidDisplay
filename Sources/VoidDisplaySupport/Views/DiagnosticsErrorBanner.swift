import SwiftUI
import VoidDisplayDesignSystem

struct DiagnosticsErrorBanner: View {
    let alert: UserFacingAlertState

    var body: some View {
        HStack(alignment: .top, spacing: AppUI.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(alert.title)
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(alert.title)
                .accessibilityValue(alert.title)
                .accessibilityIdentifier("support_bundle_error_title")

                VStack(alignment: .leading, spacing: 0) {
                    Text(alert.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(alert.message)
                .accessibilityValue(alert.message)
                .accessibilityIdentifier("support_bundle_error_message")
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .appPanelStyle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("support_bundle_error_banner")
    }
}
