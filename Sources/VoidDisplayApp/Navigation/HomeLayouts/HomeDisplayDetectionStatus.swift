import SwiftUI
import VoidDisplayDesignSystem

package struct HomeDisplayDetectionStatus: View {
    package let presentation: HomeDisplayDetectionPresentation
    package let rescanDisplays: @MainActor () -> Void

    package init(
        presentation: HomeDisplayDetectionPresentation,
        rescanDisplays: @escaping @MainActor () -> Void
    ) {
        self.presentation = presentation
        self.rescanDisplays = rescanDisplays
    }

    package var body: some View {
        HStack(alignment: .center, spacing: AppUI.Spacing.small) {
            Label {
                Text(verbatim: presentation.message)
            } icon: {
                Group {
                    if presentation.isScanning {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: presentation.systemImage)
                    }
                }
                .frame(width: 14, height: 14)
            }
            .foregroundStyle(statusTint)

            if presentation.showsRetryAction {
                Button("Rescan Displays", systemImage: "arrow.clockwise", action: rescanDisplays)
                    .appActionButtonStyle(variant: .default)
                    .controlSize(.small)
                    .accessibilityIdentifier("home_display_detection_retry_button")
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home_display_detection_status")
    }

    private var statusTint: Color {
        presentation.tone == .neutral ? .secondary : presentation.tone.tintColor
    }
}
