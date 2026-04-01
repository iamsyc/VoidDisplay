import SwiftUI

struct SharePerformanceModePicker: View {
    @Environment(CapturePerformancePreferences.self) private var capturePerformancePreferences

    var body: some View {
        VStack(spacing: AppUI.Spacing.small) {
            HStack(alignment: .center, spacing: AppUI.Spacing.medium) {
                Text("Share smoothness")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Picker("Capture Performance", selection: modeBinding) {
                    Text("Automatic").tag(CapturePerformanceMode.automatic)
                    Text("Smooth").tag(CapturePerformanceMode.smooth)
                    Text("Power Efficient").tag(CapturePerformanceMode.powerEfficient)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .center)

            Text("Automatic adapts frame rate for mixed preview and sharing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier("share_capture_performance_picker")
    }

    private var modeBinding: Binding<CapturePerformanceMode> {
        Binding(
            get: { capturePerformancePreferences.mode },
            set: { capturePerformancePreferences.saveMode($0) }
        )
    }
}
