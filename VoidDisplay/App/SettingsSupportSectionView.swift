import SwiftUI

struct SettingsSupportSectionView: View {
    @Bindable var controller: AppSettingsFeedbackController
    let onOpenSupportCenter: () -> Void
    let onExport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Support Center"))
                .font(.headline)
                .accessibilityIdentifier("settings_support_section")

            Text(String(localized: "Describe the problem in the support center first, then export a support package when needed."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(String(localized: "Open Support Center"), action: onOpenSupportCenter)
                    .accessibilityIdentifier("settings_open_support_center_button")

                Button(String(localized: "Export Support Bundle"), action: onExport)
                    .disabled(controller.isExporting)
                    .accessibilityIdentifier("settings_export_support_bundle_button")
            }

            if controller.exportCompleted {
                Text(String(localized: "Support bundle exported."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings_support_export_completed")
            }

            if let path = controller.lastBundleDisplayPath {
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "Latest Support Package"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("settings_support_latest_bundle_path")
                }
            }
        }
    }
}
