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
    package let isPreviewing: Bool
    package let isStarting: Bool
    package let isSharing: Bool
    package let onToggle: () -> Void

    package var body: some View {
        let model = AppListRowModel(
            id: String(display.displayID),
            title: displayName,
            subtitle: resolutionText,
            status: AppRowStatus(
                title: isPreviewing
                    ? String(localized: "Previewing")
                    : String(localized: "Not Previewing"),
                tint: isPreviewing ? .green : .gray
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
            iconScreenTint: DisplayIconTintResolver.resolve(isPreviewing: isPreviewing, isSharing: isSharing),
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
                } else if isPreviewing {
                    Label(String(localized: "Stop Preview"), systemImage: "stop.fill")
                } else {
                    Label(String(localized: "Preview"), systemImage: "play.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(isPreviewing ? .red : .accentColor)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .disabled(isStarting)
            .accessibilityIdentifier("capture_preview_toggle_\(display.displayID)")
        }
    }
}
