import SwiftUI
import VoidDisplayDesignSystem

package struct HomeSummaryPanel: View {
    package let context: HomeSkinContext

    package init(context: HomeSkinContext) {
        self.context = context
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small + 2) {
            HomeSummaryStatusStrip(context: context)

            Divider()
                .opacity(0.55)

            HomeSharingSettingsPanel(context: context)
        }
        .padding(.horizontal, AppUI.Spacing.large)
        .padding(.top, AppUI.Spacing.small)
        .padding(.bottom, AppUI.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider()
                .opacity(0.65)
        }
        .accessibilityLabel(Text("Current Status"))
        .accessibilityIdentifier("home_summary_panel")
    }
}

package struct HomeDashboardStatusBoard: View {
    package let context: HomeSkinContext

    package init(context: HomeSkinContext) {
        self.context = context
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppUI.Spacing.large) {
                    HomeDashboardMetricStrip(summary: context.presentation.summary)
                    Spacer(minLength: AppUI.Spacing.medium)
                    HomeSharingSettingsPanel(context: context)
                        .frame(maxWidth: 520, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: AppUI.Spacing.medium) {
                    HomeDashboardMetricStrip(summary: context.presentation.summary)
                    Divider()
                    HomeSharingSettingsPanel(context: context)
                }
            }
        }
        .padding(.horizontal, AppUI.Spacing.large)
        .padding(.vertical, AppUI.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .appPanelStyle()
        .accessibilityIdentifier("home_dashboard_status_board")
    }
}

package struct HomeSummaryStatusStrip: View {
    package let context: HomeSkinContext

    package init(context: HomeSkinContext) {
        self.context = context
    }

    package var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                virtualDisplayMetric
                runningMetric
                Spacer(minLength: AppUI.Spacing.small)
                HomeSummaryLiveActivityCluster(summary: context.presentation.summary)
                statusDivider
                permissionStatus
                permissionAction
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                primaryStatusRow
                activityStatusRow
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("home_summary_status_strip")
    }

    private var summary: HomeRuntimeSummaryPresentation {
        context.presentation.summary
    }

    private var virtualDisplayMetric: some View {
        HomeSummaryStatusItem(
            title: String(localized: "Virtual Displays"),
            value: "\(summary.virtualDisplayCount)",
            systemImage: "display.2",
            tint: .blue,
            isActive: true,
            usesProminentValue: true
        )
    }

    private var runningMetric: some View {
        HomeSummaryStatusItem(
            title: String(localized: "Running"),
            value: "\(summary.runningVirtualDisplayCount)",
            systemImage: "checkmark.rectangle.stack",
            tint: summary.runningVirtualDisplayCount > 0 ? .green : .secondary,
            isActive: summary.runningVirtualDisplayCount > 0,
            usesProminentValue: true
        )
    }

    private var primaryStatusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                virtualDisplayMetric
                statusDivider
                runningMetric
                Spacer(minLength: AppUI.Spacing.small)
                permissionStatus
                permissionAction
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                    virtualDisplayMetric
                    statusDivider
                    runningMetric
                }
                HStack(alignment: .center, spacing: AppUI.Spacing.small) {
                    permissionStatus
                    permissionAction
                }
            }
        }
    }

    private var activityStatusRow: some View {
        ViewThatFits(in: .horizontal) {
            HomeSummaryLiveActivityCluster(summary: summary)

            VStack(alignment: .leading, spacing: AppUI.Spacing.xSmall) {
                HomeSummaryPreviewStatus(summary: summary)
                HomeSummaryWebViewStatus(summary: summary)
                HomeSummaryViewersStatus(summary: summary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionStatus: some View {
        HomeSummaryStatusItem(
            title: String(localized: "Screen Recording"),
            value: context.permissionStatus.label,
            systemImage: context.permissionStatus.systemImage,
            tint: context.permissionStatus.tint,
            isActive: context.permissionStatus.isActive
        )
    }

    private var statusDivider: some View {
        Divider()
            .frame(height: 16)
            .opacity(0.65)
    }

    @ViewBuilder
    private var permissionAction: some View {
        if context.permissionStatus.canOpenSettings {
            Button {
                context.actions.openScreenCapturePrivacySettings()
            } label: {
                Label("Open Privacy Settings", systemImage: "lock.shield")
            }
            .appActionButtonStyle(variant: .default)
            .accessibilityIdentifier("home_open_privacy_settings_button")
        }
    }
}

private struct HomeSummaryLiveActivityCluster: View {
    let summary: HomeRuntimeSummaryPresentation

    var body: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
            HomeSummaryPreviewStatus(summary: summary)
            HomeSummaryWebViewStatus(summary: summary)
            HomeSummaryViewersStatus(summary: summary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct HomeSummaryPreviewStatus: View {
    let summary: HomeRuntimeSummaryPresentation

    var body: some View {
        HomeSummaryStatusItem(
            title: String(localized: "Preview"),
            value: "\(summary.previewingCount)",
            systemImage: "dot.scope.display",
            tint: summary.previewingCount > 0 ? .green : .secondary,
            isActive: summary.previewingCount > 0
        )
    }
}

private struct HomeSummaryWebViewStatus: View {
    let summary: HomeRuntimeSummaryPresentation

    var body: some View {
        HomeSummaryStatusItem(
            title: String(localized: "Web Sharing"),
            value: "\(summary.sharingCount)",
            systemImage: "network",
            tint: summary.sharingCount > 0 ? .green : .secondary,
            isActive: summary.sharingCount > 0
        )
    }
}

private struct HomeSummaryViewersStatus: View {
    let summary: HomeRuntimeSummaryPresentation

    var body: some View {
        HomeSummaryStatusItem(
            title: String(localized: "Viewers"),
            value: "\(summary.activeViewerCount)",
            systemImage: "person.2",
            tint: summary.activeViewerCount > 0 ? .blue : .secondary,
            isActive: summary.activeViewerCount > 0
        )
    }
}

package struct HomeDashboardMetricStrip: View {
    package let summary: HomeRuntimeSummaryPresentation

    package init(summary: HomeRuntimeSummaryPresentation) {
        self.summary = summary
    }

    package var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.large) {
                HomeSummaryMetric(
                    title: String(localized: "Virtual Displays"),
                    value: "\(summary.virtualDisplayCount)",
                    systemImage: "display.2",
                    tint: .blue
                )
                HomeSummaryMetric(
                    title: String(localized: "Running"),
                    value: "\(summary.runningVirtualDisplayCount)",
                    systemImage: "checkmark.rectangle.stack",
                    tint: summary.runningVirtualDisplayCount > 0 ? .green : .secondary
                )
                HomeSummaryMetric(
                    title: String(localized: "Web Sharing"),
                    value: "\(summary.sharingCount)",
                    systemImage: "network",
                    tint: summary.sharingCount > 0 ? .green : .secondary
                )
                HomeSummaryMetric(
                    title: String(localized: "Viewers"),
                    value: "\(summary.activeViewerCount)",
                    systemImage: "person.2",
                    tint: summary.activeViewerCount > 0 ? .blue : .secondary
                )
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                    HomeSummaryStatusItem(
                        title: String(localized: "Virtual Displays"),
                        value: "\(summary.virtualDisplayCount)",
                        systemImage: "display.2",
                        tint: .blue,
                        isActive: true,
                        usesProminentValue: true
                    )
                    Divider()
                        .frame(height: 16)
                        .opacity(0.65)
                    HomeSummaryStatusItem(
                        title: String(localized: "Running"),
                        value: "\(summary.runningVirtualDisplayCount)",
                        systemImage: "checkmark.rectangle.stack",
                        tint: summary.runningVirtualDisplayCount > 0 ? .green : .secondary,
                        isActive: summary.runningVirtualDisplayCount > 0,
                        usesProminentValue: true
                    )
                }
                HomeSummaryLiveActivityCluster(summary: summary)
            }
        }
    }
}

package struct HomeSummaryMetric: View {
    package let title: String
    package let value: String
    package let systemImage: String
    package let tint: Color

    package init(
        title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
    }

    package var body: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(minWidth: 96, alignment: .leading)
    }
}

package struct HomeSummaryStatusItem: View {
    package let title: String
    package let value: String
    package let systemImage: String
    package let tint: Color
    package let isActive: Bool
    package let usesProminentValue: Bool

    package init(
        title: String,
        value: String,
        systemImage: String,
        tint: Color,
        isActive: Bool,
        usesProminentValue: Bool = false
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.isActive = isActive
        self.usesProminentValue = usesProminentValue
    }

    package var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 14)

            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(valueForegroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title): \(value)"))
    }

    private var valueForegroundColor: Color {
        if usesProminentValue {
            return .primary
        }
        return isActive ? tint : .secondary
    }
}
