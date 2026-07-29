import SwiftUI
import VoidDisplayDesignSystem

package struct HomeSummaryStatusStrip: View {
    private let context: HomeLayoutContext

    package init(context: HomeLayoutContext) {
        self.context = context
    }

    package var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                virtualDisplayMetric
                runningMetric
                statusDivider
                HomeSummaryLiveActivityCluster(summary: context.presentation.summary)
                Spacer(minLength: AppUI.Spacing.small)
                if context.permissionStatus.canOpenSettings {
                    statusDivider
                    permissionStatus
                    permissionActions
                }
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                primaryStatusRow
                activityStatusRow
            }
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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
            usesProminentValue: true,
            minimumValueDigitCount: 2
        )
        .padding(.leading, context.metrics.itemHorizontalPadding)
    }

    private var runningMetric: some View {
        HomeSummaryStatusItem(
            title: String(localized: "Running"),
            value: "\(summary.runningVirtualDisplayCount)",
            systemImage: "checkmark.rectangle.stack",
            tint: summary.runningVirtualDisplayCount > 0 ? .green : .secondary,
            isActive: summary.runningVirtualDisplayCount > 0,
            usesProminentValue: true,
            minimumValueDigitCount: 2
        )
    }

    private var primaryStatusRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                virtualDisplayMetric
                statusDivider
                runningMetric
                Spacer(minLength: AppUI.Spacing.small)
                if context.permissionStatus.canOpenSettings {
                    permissionStatus
                    permissionActions
                }
            }

            VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                    virtualDisplayMetric
                    statusDivider
                    runningMetric
                }
                if context.permissionStatus.canOpenSettings {
                    HStack(alignment: .center, spacing: AppUI.Spacing.small) {
                        permissionStatus
                        permissionActions
                    }
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
        .accessibilityIdentifier("home_header_screen_recording_permission_status")
    }

    private var statusDivider: some View {
        Divider()
            .frame(height: 16)
            .opacity(0.65)
    }

    @ViewBuilder
    private var permissionActions: some View {
        if context.permissionStatus.canOpenSettings {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: AppUI.Spacing.small) {
                    openPrivacySettingsButton
                    checkPermissionAgainButton
                }

                VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
                    openPrivacySettingsButton
                    checkPermissionAgainButton
                }
            }
        }
    }

    private var openPrivacySettingsButton: some View {
        Button {
            context.actions.openScreenCapturePrivacySettings()
        } label: {
            Label("Open Privacy Settings", systemImage: "lock.shield")
        }
        .appActionButtonStyle(variant: .default)
        .accessibilityIdentifier("home_open_privacy_settings_button")
    }

    private var checkPermissionAgainButton: some View {
        Button("Check Again", systemImage: "arrow.clockwise", action: context.actions.rescanDisplays)
            .appActionButtonStyle(variant: .default)
            .disabled(context.displayDetection.isScanning)
            .help(Text("After granting Screen Recording permission, check again."))
            .accessibilityIdentifier("home_check_screen_recording_permission_button")
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
            isActive: summary.previewingCount > 0,
            minimumValueDigitCount: 2
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
            isActive: summary.sharingCount > 0,
            minimumValueDigitCount: 2
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
            isActive: summary.activeViewerCount > 0,
            minimumValueDigitCount: 2
        )
    }
}

package struct HomeSummaryStatusItem: View {
    package let title: String
    package let value: String
    package let systemImage: String
    package let tint: Color
    package let isActive: Bool
    package let usesProminentValue: Bool
    package let minimumValueDigitCount: Int

    package init(
        title: String,
        value: String,
        systemImage: String,
        tint: Color,
        isActive: Bool,
        usesProminentValue: Bool = false,
        minimumValueDigitCount: Int = 0
    ) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.tint = tint
        self.isActive = isActive
        self.usesProminentValue = usesProminentValue
        self.minimumValueDigitCount = minimumValueDigitCount
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

            ZStack(alignment: .leading) {
                if minimumValueDigitCount > 0 {
                    Text(String(repeating: "8", count: minimumValueDigitCount))
                        .hidden()
                        .accessibilityHidden(true)
                }

                Text(value)
            }
                .fontWeight(.semibold)
                .monospacedDigit()
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
