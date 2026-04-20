import SwiftUI

struct SupportBundleDraftSectionView: View {
    @Bindable var controller: AppSettingsFeedbackController
    let onExport: () -> Void
    let onCopySummary: () -> Void
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(String(localized: "Support Package Details"))
                .font(.headline)
                .accessibilityIdentifier("support_bundle_draft_section")

            Text(String(localized: "Add context before you export a support package. The technical details below use the same live data."))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextField(
                String(localized: "What happened?"),
                text: $controller.happened,
                axis: .vertical
            )
            .lineLimit(3...)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("support_bundle_happened_field")

            TextField(
                String(localized: "How can this be reproduced?"),
                text: $controller.reproductionSteps,
                axis: .vertical
            )
            .lineLimit(3...)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("support_bundle_reproduction_field")

            TextField(
                String(localized: "What did you expect?"),
                text: $controller.expectedResult,
                axis: .vertical
            )
            .lineLimit(2...)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("support_bundle_expected_field")

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Optional enhanced diagnostics"))
                    .font(.subheadline.weight(.medium))
                Toggle(String(localized: "Include unified log summary"), isOn: $controller.includeUnifiedLogSummary)
                    .accessibilityIdentifier("support_bundle_include_log_toggle")
                Toggle(String(localized: "Include latest crash report excerpt"), isOn: $controller.includeCrashReportExcerpt)
                    .accessibilityIdentifier("support_bundle_include_crash_toggle")
                Toggle(String(localized: "Include related config snapshots"), isOn: $controller.includeRelatedConfigSnapshots)
                    .accessibilityIdentifier("support_bundle_include_configs_toggle")
            }
            .toggleStyle(.switch)

            HStack(spacing: 10) {
                Button(String(localized: "Export Support Bundle"), action: onExport)
                    .appActionButtonStyle(variant: .default)
                    .disabled(controller.isExporting)
                    .accessibilityIdentifier("support_center_export_button")

                Button(String(localized: "Copy Summary"), action: onCopySummary)
                    .appActionButtonStyle(variant: .default)
                    .disabled(!controller.canCopySummary)
                    .accessibilityIdentifier("support_center_copy_summary_button")

                Button(String(localized: "Reveal Bundle"), action: onReveal)
                    .appActionButtonStyle(variant: .default)
                    .disabled(!controller.canRevealLastBundle)
                    .accessibilityIdentifier("support_center_reveal_bundle_button")
            }

            if controller.exportCompleted {
                Text(String(localized: "Support bundle exported."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("support_bundle_export_completed")
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
                        .accessibilityIdentifier("support_center_latest_bundle_path")
                }
            }
        }
        .padding()
        .appPanelStyle()
    }
}
