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
        let appHelper = makeHelper(preview: true, uiTestMode: false)
        let view = CreateVirtualDisplay(isShow: .constant(true))
            .environment(appHelper)

        render(view)
    }

    @Test func editVirtualDisplayBodyEvaluates() {
        let appHelper = makeHelper(preview: false, uiTestMode: true)
        let configID = appHelper.displayConfigs.first?.id ?? UUID()
        let view = EditVirtualDisplayConfigView(configId: configID)
            .environment(appHelper)

        render(view)
    }

    @Test func virtualDisplayViewBodyEvaluatesWithEmptyState() {
        let appHelper = makeHelper(preview: true, uiTestMode: false)
        let view = VirtualDisplayView()
            .environment(appHelper)

        render(view)
    }

    @Test func virtualDisplayViewBodyEvaluatesWithConfigs() {
        let appHelper = makeHelper(preview: false, uiTestMode: true)
        let view = VirtualDisplayView()
            .environment(appHelper)

        render(view)
    }

    private func makeHelper(preview: Bool, uiTestMode: Bool) -> AppHelper {
        AppHelper(
            preview: preview,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayService: MockVirtualDisplayService(),
            isUITestModeOverride: uiTestMode,
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
