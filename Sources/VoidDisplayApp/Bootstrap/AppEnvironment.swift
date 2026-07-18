import Foundation
import VoidDisplayCapture
import VoidDisplayObservability
import VoidDisplayRuntime
import VoidDisplaySharing
import VoidDisplaySupport
import VoidDisplayVirtualDisplay

@MainActor
package struct AppEnvironment {
    package let capture: CaptureController
    package let observability: ObservabilityCenter
    package let sharing: SharingController
    package let virtualDisplay: VirtualDisplayController
    package let displayRuntime: DisplayRuntime
    package let sharingAdapter: DisplayRuntimeSharingAdapter
    package let capturePerformancePreferences: CapturePerformancePreferences
    package let feedbackController: AppSettingsFeedbackController
    package let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void
    private let startupTask: Task<Void, Never>

    package init(
        capture: CaptureController,
        observability: ObservabilityCenter,
        sharing: SharingController,
        virtualDisplay: VirtualDisplayController,
        displayRuntime: DisplayRuntime,
        sharingAdapter: DisplayRuntimeSharingAdapter,
        capturePerformancePreferences: CapturePerformancePreferences,
        feedbackController: AppSettingsFeedbackController,
        openScreenCapturePrivacySettings: @escaping @MainActor (@escaping (URL) -> Void) -> Void,
        startupTask: Task<Void, Never>
    ) {
        self.capture = capture
        self.observability = observability
        self.sharing = sharing
        self.virtualDisplay = virtualDisplay
        self.displayRuntime = displayRuntime
        self.sharingAdapter = sharingAdapter
        self.capturePerformancePreferences = capturePerformancePreferences
        self.feedbackController = feedbackController
        self.openScreenCapturePrivacySettings = openScreenCapturePrivacySettings
        self.startupTask = startupTask
    }

    package func waitForStartupTasks() async {
        await startupTask.value
    }
}
