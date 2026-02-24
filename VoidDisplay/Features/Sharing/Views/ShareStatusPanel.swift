import SwiftUI

struct ShareStatusPanel: View {
    let displayCount: Int
    let sharingDisplayCount: Int
    let clientsCount: Int
    let isRunning: Bool

    var body: some View {
        HStack(spacing: AppUI.Spacing.medium) {
            HStack(spacing: AppUI.Spacing.xSmall) {
                Circle()
                    .fill(isRunning ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(isRunning ? String(localized: "Service Running") : String(localized: "Service Stopped"))
                    .foregroundStyle(isRunning ? .primary : .secondary)
            }

            Text("·").foregroundStyle(.quaternary)

            HStack(spacing: AppUI.Spacing.xSmall) {
                Text(String(localized: "Sharing"))
                    .foregroundStyle(.secondary)
                Text("\(sharingDisplayCount)/\(displayCount)")
                    .foregroundStyle(sharingDisplayCount > 0 ? Color.green : .secondary)
            }

            Text("·").foregroundStyle(.quaternary)

            HStack(spacing: AppUI.Spacing.xSmall) {
                Image(systemName: "person.2")
                    .foregroundStyle(clientsCount > 0 ? Color.accentColor : .secondary)
                Text("\(clientsCount)")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(localizedDisplayCount(displayCount))
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, AppUI.Spacing.medium)
        .padding(.vertical, AppUI.Spacing.small)
        .background(
            RoundedRectangle(cornerRadius: AppUI.Corner.medium, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .accessibilityIdentifier("share_status_panel")
    }

    private func localizedDisplayCount(_ count: Int) -> String {
        let format = String(localized: "%lld displays")
        return String.localizedStringWithFormat(format, Int64(count))
    }
}
