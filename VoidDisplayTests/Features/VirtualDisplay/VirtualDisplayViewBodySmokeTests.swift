import AppKit
import SwiftUI
import Testing
@testable import VoidDisplay

@Suite(.serialized)
@MainActor
struct VirtualDisplayViewBodySmokeTests {
    private static let appBootstrap: Void = {
        _ = NSApplication.shared
    }()

    @Test func createVirtualDisplayBodyEvaluates() {
        let env = makeEnvironment(preview: true, uiTestMode: false)
        let view = CreateVirtualDisplay(isShow: .constant(true))
            .environment(env.capture)
            .environment(env.sharing)
            .environment(env.virtualDisplay)

        render(view)
    }

    @Test func editVirtualDisplayBodyEvaluates() {
        let env = makeEnvironment(preview: false, uiTestMode: true)
        let configID = env.virtualDisplay.displayConfigs.first?.id ?? UUID()
        let view = EditVirtualDisplayConfigView(configId: configID)
            .environment(env.capture)
            .environment(env.sharing)
            .environment(env.virtualDisplay)

        render(view)
    }

    @Test func virtualDisplayViewBodyEvaluatesWithEmptyState() {
        let env = makeEnvironment(preview: true, uiTestMode: false)
        let view = VirtualDisplayView(controller: env.virtualDisplay)
            .environment(env.capture)
            .environment(env.sharing)
            .environment(env.virtualDisplay)

        render(view)
    }

    @Test func virtualDisplayViewBodyEvaluatesWithConfigs() {
        let env = makeEnvironment(preview: false, uiTestMode: true)
        let view = VirtualDisplayView(controller: env.virtualDisplay)
            .environment(env.capture)
            .environment(env.sharing)
            .environment(env.virtualDisplay)

        render(view)
    }

    @Test func virtualDisplayViewBodyEvaluatesWithConfigStoreLoadFailure() {
        let mockService = MockVirtualDisplayService()
        mockService.configStoreState = .loadFailed(
            error: .unsupportedSchemaVersion(expected: 3, actual: 2),
            diagnostics: .init(
                primaryStoreURL: URL(fileURLWithPath: "/tmp/virtual-displays.json"),
                legacyContainerStoreURL: URL(fileURLWithPath: "/tmp/legacy.json"),
                legacyContainerFileExists: true,
                isTestIsolatedPath: true
            )
        )
        let failureEnv = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayService: mockService,
            isRunningUnderXCTestOverride: true
        )
        failureEnv.virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()

        let view = VirtualDisplayView(controller: failureEnv.virtualDisplay)
            .environment(failureEnv.capture)
            .environment(failureEnv.sharing)
            .environment(failureEnv.virtualDisplay)

        render(view)
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
