import AppKit
import SwiftUI
import Testing
@testable import VoidDisplay

@Suite(.serialized)
@MainActor
struct AppAndSharedViewBodySmokeTests {
    private static let appBootstrap: Void = {
        _ = NSApplication.shared
    }()

    @Test
    func appSettingsViewBodyEvaluates() {
        let env = makeEnvironment(preview: true, uiTestMode: false)
        let view = AppSettingsView()
            .environment(env.virtualDisplay)

        render(view)
    }

    @Test
    func shareViewBodyEvaluates() {
        let env = makeEnvironment(preview: true, uiTestMode: false)
        let view = ShareView()
            .environment(env.capture)
            .environment(env.sharing)
            .environment(env.virtualDisplay)

        render(view)
    }

    @Test
    func captureChooseBodyEvaluates() {
        let env = makeEnvironment(preview: true, uiTestMode: false)
        let view = IsCapturing()
            .environment(env.capture)
            .environment(env.virtualDisplay)

        render(view)
    }

    @Test
    func shareStatusPanelBodyEvaluatesForRunningAndStoppedStates() {
        render(
            ShareStatusPanel(
                displayCount: 3,
                sharingDisplayCount: 2,
                clientsCount: 5,
                isRunning: true
            )
        )
        render(
            ShareStatusPanel(
                displayCount: 0,
                sharingDisplayCount: 0,
                clientsCount: 0,
                isRunning: false
            )
        )
    }

    @Test
    func screenCapturePermissionGuideBodyEvaluatesWithAndWithoutOptionalContent() {
        let debugItems = [
            (title: "Bundle ID", value: "com.example.test"),
            (title: "App Path", value: "/Applications/VoidDisplay.app")
        ]

        render(
            ScreenCapturePermissionGuideView(
                loadErrorMessage: "Permission check failed",
                onOpenSettings: {},
                onRequestPermission: {},
                onRefresh: {},
                onRetry: {},
                isDebugInfoExpanded: .constant(true),
                debugItems: debugItems,
                rootAccessibilityIdentifier: "permission_root",
                openSettingsButtonAccessibilityIdentifier: "open_settings",
                requestPermissionButtonAccessibilityIdentifier: "request_permission",
                refreshButtonAccessibilityIdentifier: "refresh_permission"
            )
        )

        render(
            ScreenCapturePermissionGuideView(
                loadErrorMessage: nil,
                onOpenSettings: {},
                onRequestPermission: {},
                onRefresh: {},
                onRetry: nil,
                isDebugInfoExpanded: .constant(false),
                debugItems: [],
                rootAccessibilityIdentifier: nil,
                openSettingsButtonAccessibilityIdentifier: nil,
                requestPermissionButtonAccessibilityIdentifier: nil,
                refreshButtonAccessibilityIdentifier: nil
            )
        )
    }

    private func makeEnvironment(preview: Bool, uiTestMode: Bool) -> AppEnvironment {
        if uiTestMode {
            return AppBootstrap.makeEnvironment(
                preview: preview,
                captureMonitoringService: MockCaptureMonitoringService(),
                sharingService: MockSharingService(),
                virtualDisplayService: UITestVirtualDisplayService(scenario: .baseline),
                startupPlan: .init(
                    shouldRestoreVirtualDisplays: true,
                    shouldStartWebService: false,
                    postRestoreConfiguration: nil
                ),
                isRunningUnderXCTestOverride: true
            )
        }

        return AppBootstrap.makeEnvironment(
            preview: preview,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayService: MockVirtualDisplayService(),
            isRunningUnderXCTestOverride: true
        )
    }

    private func render<V: View>(_ view: V) {
        _ = Self.appBootstrap
        autoreleasepool {
            let host = NSHostingController(rootView: view)
            let hostedView = host.view
            hostedView.layoutSubtreeIfNeeded()
        }
    }
}
