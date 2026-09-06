import SwiftUI
import VoidDisplayDesignSystem

package struct MenuBarQuickActionsHeader: View {
    package let summary: HomeRuntimeSummaryPresentation
    package let openMainWindow: @MainActor () -> Void

    package init(
        summary: HomeRuntimeSummaryPresentation,
        openMainWindow: @escaping @MainActor () -> Void
    ) {
        self.summary = summary
        self.openMainWindow = openMainWindow
    }

    package var body: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                HomeSummaryStatusItem(
                    title: String(localized: "Running"),
                    value: "\(summary.runningVirtualDisplayCount)",
                    systemImage: "checkmark.rectangle.stack",
                    tint: summary.runningVirtualDisplayCount > 0 ? .green : .secondary,
                    isActive: summary.runningVirtualDisplayCount > 0,
                    minimumValueDigitCount: 1
                )

                HomeSummaryStatusItem(
                    title: String(localized: "Preview"),
                    value: "\(summary.previewingCount)",
                    systemImage: "dot.scope.display",
                    tint: summary.previewingCount > 0 ? .green : .secondary,
                    isActive: summary.previewingCount > 0,
                    minimumValueDigitCount: 1
                )

                HomeSummaryStatusItem(
                    title: String(localized: "Web Sharing"),
                    value: "\(summary.sharingCount)",
                    systemImage: "network",
                    tint: summary.sharingCount > 0 ? .green : .secondary,
                    isActive: summary.sharingCount > 0,
                    minimumValueDigitCount: 1
                )
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("menu_bar_runtime_summary")

            Spacer(minLength: AppUI.Spacing.xSmall)

            Button("Open VoidDisplay", systemImage: "macwindow", action: openMainWindow)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(Text("Open VoidDisplay"))
                .accessibilityIdentifier("menu_bar_open_main_window_button")
        }
    }
}
