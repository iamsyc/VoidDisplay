import Foundation
import VoidDisplayVirtualDisplay
import VoidDisplayCapture
import VoidDisplaySupport
import VoidDisplayObservability
import VoidDisplayFoundation
import AppKit
import SwiftUI
package struct AppSettingsView: View {
    @Environment(AppNavigationController.self) private var navigation
    @Environment(VirtualDisplayController.self) private var virtualDisplay
    @Environment(CapturePerformancePreferences.self) private var capturePerformancePreferences
    @State private var showResetConfirmation = false
    @State private var resetCompleted = false

    private let observability: ObservabilityCenter
    private let feedbackController: AppSettingsFeedbackController

    package init(
        observability: ObservabilityCenter,
        feedbackController: AppSettingsFeedbackController
    ) {
        self.observability = observability
        self.feedbackController = feedbackController
    }

    package var body: some View {
        @Bindable var bindableVirtualDisplay = virtualDisplay

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Capture Performance")
                        .font(.headline)

                    Text("Choose how screen monitoring and sharing balance smoothness and resource usage.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("Capture Performance", selection: performanceModeBinding) {
                        Text("Automatic").tag(CapturePerformanceMode.automatic)
                        Text("Smooth").tag(CapturePerformanceMode.smooth)
                        Text("Power Efficient").tag(CapturePerformanceMode.powerEfficient)
                    }
                    .pickerStyle(.segmented)
                }

                SettingsSupportSectionView(
                    controller: feedbackController,
                    onOpenSupportCenter: openSupportCenter
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Virtual Displays")
                        .font(.headline)

                    Text("Reset will remove all saved virtual display configurations and stop currently managed virtual displays.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button("Reset Virtual Display Configurations", role: .destructive) {
                        showResetConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)

                    if resetCompleted {
                        Text("Reset completed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .frame(width: 520, height: 620, alignment: .topLeading)
        .task {
            await feedbackController.prepare(observability: observability)
            if let fixture = UITestRuntime.feedbackFixture {
                feedbackController.applyFixture(fixture)
            }
        }
        .confirmationDialog(
            "Reset Virtual Display Configurations?",
            isPresented: $showResetConfirmation
        ) {
            Button("Reset", role: .destructive) {
                do {
                    _ = try virtualDisplay.resetVirtualDisplayData()
                    resetCompleted = true
                } catch {}
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
        .alert(item: $bindableVirtualDisplay.persistenceAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK")) {
                    virtualDisplay.dismissPersistenceAlert()
                }
            )
        }
    }

    private var performanceModeBinding: Binding<CapturePerformanceMode> {
        Binding(
            get: { capturePerformancePreferences.mode },
            set: { capturePerformancePreferences.saveMode($0) }
        )
    }

    private func openSupportCenter() {
        navigation.showSupportCenter()
        NSApp.keyWindow?.close()
    }
}
