import Foundation
import VoidDisplayDesignSystem
import SwiftUI
import ScreenCaptureKit

@MainActor
package struct CaptureDisplayRow: View {
    package let display: SCDisplay
    package let displayName: String
    package let resolutionText: String
    package let isVirtualDisplay: Bool
    package let isPrimaryDisplay: Bool
    package let isMonitoring: Bool
    package let isStarting: Bool
    package let isSharing: Bool
    package let onToggle: () -> Void

    package var body: some View {
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
            iconScreenTint: DisplayIconTintResolver.resolve(isMonitoring: isMonitoring, isSharing: isSharing),
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
package struct MonitoringSessionRow: View {
    package let session: ScreenMonitoringSession
    package let isSharing: Bool
    package let onStop: () -> Void

    package var body: some View {
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
            iconScreenTint: DisplayIconTintResolver.resolve(isMonitoring: true, isSharing: isSharing),
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
