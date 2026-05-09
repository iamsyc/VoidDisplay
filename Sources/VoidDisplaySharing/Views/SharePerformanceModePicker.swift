import VoidDisplayDesignSystem
import VoidDisplayFoundation
import VoidDisplayObservability
import Foundation
import SwiftUI

package struct SharePerformanceModePicker: View {
    package let performanceMode: SharePerformanceModeBinding

    package var body: some View {
        VStack(spacing: AppUI.Spacing.small) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                Text("Share smoothness")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Picker("Capture Performance", selection: modeBinding) {
                    Text("Automatic").tag(SharePerformanceMode.automatic)
                    Text("Smooth").tag(SharePerformanceMode.smooth)
                    Text("Power Efficient").tag(SharePerformanceMode.powerEfficient)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text("Automatic and Smooth send AV1 at source resolution on LAN. Actual frame rate follows encoder capability.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier("share_capture_performance_picker")
    }

    private var modeBinding: Binding<SharePerformanceMode> {
        Binding(
            get: { performanceMode.get() },
            set: { performanceMode.set($0) }
        )
    }
}
