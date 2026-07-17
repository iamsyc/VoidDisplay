import SwiftUI
import VoidDisplayDesignSystem

struct DiagnosticsStatusHeading: View {
    let recommendation: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall + 2) {
            Label(String(localized: "Status"), systemImage: "folder.badge.gearshape")
                .font(.headline)
                .accessibilityIdentifier("diagnostics_technical_details")
            Text(recommendation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
