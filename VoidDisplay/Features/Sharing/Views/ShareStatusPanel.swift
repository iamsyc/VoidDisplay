import SwiftUI

struct ShareStatusPanel: View {
    let displayCount: Int
    let sharingDisplayCount: Int
    let clientsCount: Int
    let isRunning: Bool

    var body: some View {
        VStack(spacing: AppUI.Spacing.small) {
            ViewThatFits(in: .horizontal) {
                wideSummary
                compactSummary
            }

            Divider()
        }
        .font(.subheadline)
        .padding(.vertical, AppUI.Spacing.small)
        .accessibilityIdentifier("share_status_panel")
    }

    private var wideSummary: some View {
        HStack(spacing: AppUI.Spacing.medium + 2) {
            serviceSummary
            verticalDivider
            sharingSummary
            verticalDivider
            clientsSummary
            Spacer(minLength: 0)
            displaySummary
        }
    }

    private var compactSummary: some View {
        VStack(alignment: .leading, spacing: AppUI.Spacing.small) {
            HStack(spacing: AppUI.Spacing.medium + 2) {
                serviceSummary
                Spacer(minLength: 0)
                displaySummary
            }

            HStack(spacing: AppUI.Spacing.medium + 2) {
                sharingSummary
                verticalDivider
                clientsSummary
            }
        }
    }

    private var serviceSummary: some View {
        HStack(spacing: AppUI.Spacing.xSmall + 2) {
            Circle()
                .fill(isRunning ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            Text(isRunning ? String(localized: "Service Running") : String(localized: "Service Stopped"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isRunning ? .primary : .secondary)
        }
    }

    private var sharingSummary: some View {
        HStack(spacing: AppUI.Spacing.small) {
            Text(String(localized: "Sharing"))
                .foregroundStyle(.secondary)

            Text("\(sharingDisplayCount)/\(displayCount)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(sharingDisplayCount > 0 ? Color.accentColor : .primary)
        }
    }

    private var clientsSummary: some View {
        HStack(spacing: AppUI.Spacing.small) {
            Image(systemName: "person.2")
                .foregroundStyle(clientsCount > 0 ? Color.accentColor : .secondary)

            Text("\(clientsCount)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(clientsCount > 0 ? .primary : .secondary)
        }
        .accessibilityLabel(connectedClientsAccessibilityLabel(clientsCount))
    }

    private var displaySummary: some View {
        Text(localizedDisplayCount(displayCount))
            .foregroundStyle(.secondary)
    }

    private var verticalDivider: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(width: AppUI.Stroke.subtle, height: 14)
            .accessibilityHidden(true)
    }

    private func connectedClientsAccessibilityLabel(_ count: Int) -> String {
        let format = String(localized: "%lld connected")
        return String.localizedStringWithFormat(format, Int64(count))
    }

    private func localizedDisplayCount(_ count: Int) -> String {
        let format = String(localized: "%lld displays")
        return String.localizedStringWithFormat(format, Int64(count))
    }
}
