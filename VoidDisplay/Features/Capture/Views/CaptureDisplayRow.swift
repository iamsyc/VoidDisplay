import SwiftUI
import ScreenCaptureKit

@MainActor
struct CaptureDisplayRow: View {
    let display: SCDisplay
    let displayName: String
    let resolutionText: String
    let isVirtualDisplay: Bool
    let isPrimaryDisplay: Bool
    let isMonitoring: Bool
    let isStarting: Bool
    let onToggle: () -> Void

    var body: some View {
        let model = AppListRowModel(
            id: String(display.displayID),
            title: displayName,
            subtitle: resolutionText,
            status: AppRowStatus(
                title: isMonitoring
                    ? String(localized: "Monitoring")
                    : String(localized: "Not Monitoring"),
                tint: isMonitoring ? .green : .gray
            ),
            metaBadges: [
                AppBadgeModel(
                    title: isVirtualDisplay
                        ? String(localized: "Virtual Display")
                        : String(localized: "Physical Display"),
                    style: isVirtualDisplay
                        ? .roundedTag(tint: .blue)
                        : .roundedTag(tint: .gray)
                )
            ],
            ribbon: isPrimaryDisplay
                ? AppCornerRibbonModel(
                    title: String(localized: "Primary Display"),
                    tint: .green
                )
                : nil,
            iconSystemName: "display",
            isEmphasized: true,
            accessibilityIdentifier: nil
        )

        return AppListRowCard(model: model) {
            Button {
                guard !isStarting else { return }
                onToggle()
            } label: {
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                } else if isMonitoring {
                    Label(String(localized: "Stop Monitoring"), systemImage: "stop.fill")
                } else {
                    Label(String(localized: "Monitor Display"), systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isMonitoring ? .red : .accentColor)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .disabled(isStarting)
            .accessibilityIdentifier("capture_monitor_toggle_\(display.displayID)")
        }
    }
}

@MainActor
struct MonitoringSessionRow: View {
    let session: ScreenMonitoringSession
    let onStop: () -> Void

    var body: some View {
        let isStarting = session.state == .starting
        let model = AppListRowModel(
            id: session.id.uuidString,
            title: session.displayName,
            subtitle: session.resolutionText,
            status: AppRowStatus(
                title: isStarting ? String(localized: "Starting") : String(localized: "Monitoring"),
                tint: isStarting ? .orange : .green
            ),
            metaBadges: [
                AppBadgeModel(
                    title: session.isVirtualDisplay
                        ? String(localized: "Virtual Display")
                        : String(localized: "Physical Display"),
                    style: session.isVirtualDisplay
                        ? .roundedTag(tint: .blue)
                        : .roundedTag(tint: .gray)
                )
            ],
            iconSystemName: "display",
            isEmphasized: true,
            accessibilityIdentifier: nil
        )

        return AppListRowCard(model: model) {
            Button(role: .destructive) {
                onStop()
            } label: {
                Label(
                    isStarting ? String(localized: "Cancel Starting") : String(localized: "Stop Monitoring"),
                    systemImage: "stop.fill"
                )
            }
            .buttonStyle(.bordered)
        }
    }
}
