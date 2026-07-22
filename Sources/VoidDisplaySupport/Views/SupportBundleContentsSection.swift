import SwiftUI
import VoidDisplayDesignSystem

struct SupportBundleContentsSection: View {
    @Bindable var controller: AppSettingsFeedbackController

    var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            Label(String(localized: "Support Package Contents"), systemImage: "lock.doc")
                .font(.subheadline.weight(.medium))

            Text(String(localized: "Always included: issue description, sanitized app status, recent events, and recent issues."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("support_bundle_contents_summary")

            Text(String(localized: "Enhanced diagnostics (enabled by default)"))
                .font(.subheadline.weight(.medium))
                .padding(.top, AppUI.Spacing.xSmall)
            Text(String(localized: "Enabled by default to provide more diagnostic context. Turn off any item you prefer not to include."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("support_bundle_diagnostics_description")
            Toggle(String(localized: "Include unified log summary"), isOn: $controller.includeUnifiedLogSummary)
                .disabled(controller.isExporting)
                .accessibilityIdentifier("support_bundle_include_log_toggle")
            Toggle(String(localized: "Include latest crash report excerpt"), isOn: $controller.includeCrashReportExcerpt)
                .disabled(controller.isExporting)
                .accessibilityIdentifier("support_bundle_include_crash_toggle")
            Toggle(String(localized: "Include related config snapshots"), isOn: $controller.includeRelatedConfigSnapshots)
                .disabled(controller.isExporting)
                .accessibilityIdentifier("support_bundle_include_configs_toggle")

            Label(
                String(localized: "Saved locally on this Mac. Nothing is uploaded automatically."),
                systemImage: "lock.shield"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, AppUI.Spacing.xSmall)
            .accessibilityIdentifier("support_bundle_local_storage_notice")
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
