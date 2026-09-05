import Foundation
import VoidDisplayCapture
import VoidDisplayFoundation
import VoidDisplaySharing
import VoidDisplayVirtualDisplay

@MainActor
package enum AppBootstrap {
    private static let xCTestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

    package struct StartupPlan {
        var shouldRestoreVirtualDisplays: Bool

        static let standard = StartupPlan(shouldRestoreVirtualDisplays: true)
        static let skipAll = StartupPlan(shouldRestoreVirtualDisplays: false)
    }

    package static func makeEnvironment() -> AppEnvironment {
        guard UITestRuntime.isEnabled else {
            return makeEnvironment(preview: false)
        }

        return makeEnvironment(
            preview: false,
            capturePreviewService: UITestRuntime.scenario == .menuBarQuickActions
                ? MenuBarQuickActionsUITestFixture.capturePreviewService()
                : nil,
            virtualDisplayFacade: UITestVirtualDisplayFacade(),
            startupPlan: .init(
                shouldRestoreVirtualDisplays: UITestRuntime.scenario != .menuBarQuickActions
            )
        )
    }

    package static func makeEnvironment(
        preview: Bool,
        capturePreviewService: (any CapturePreviewServiceProtocol)? = nil,
        sharingService: (any SharingServiceProtocol)? = nil,
        virtualDisplayFacade: (any VirtualDisplayFacade)? = nil,
        appliedBadgeDisplayDuration: Duration = .seconds(2.5),
        startupPlan: StartupPlan? = nil,
        isRunningUnderXCTestOverride: Bool? = nil
    ) -> AppEnvironment {
        let configuration = resolveConfiguration(
            preview: preview,
            startupPlan: startupPlan,
            isRunningUnderXCTestOverride: isRunningUnderXCTestOverride
        )
        let persistence = makePersistenceBundle(configuration: configuration)
        let captureSharing = makeCaptureSharingBundle(
            capturePreviewService: capturePreviewService,
            sharingService: sharingService,
            persistence: persistence
        )
        let virtualDisplay = makeVirtualDisplayBundle(
            facade: virtualDisplayFacade,
            persistenceContext: persistence.context,
            startupPlan: configuration.startupPlan
        )
        let baseControllers = makeBaseControllerBundle(
            captureSharing: captureSharing,
            persistence: persistence
        )
        installObservabilityFailureBridge(observability: persistence.observability)
        let runtime = makeRuntimeBundle(
            controllers: baseControllers,
            captureSharing: captureSharing,
            virtualDisplay: virtualDisplay,
            persistence: persistence
        )
        let controllers = makeControllerBundle(
            base: baseControllers,
            virtualDisplay: virtualDisplay,
            persistence: persistence,
            runtime: runtime,
            appliedBadgeDisplayDuration: appliedBadgeDisplayDuration
        )
        wireRuntime(
            runtime: runtime,
            captureSharing: captureSharing,
            capturePerformancePreferences: persistence.capturePerformancePreferences
        )
        let startupTask = makeStartupTask(
            configuration: configuration,
            persistence: persistence,
            controllers: controllers,
            runtime: runtime
        )

        return AppEnvironment(
            capture: controllers.capture,
            observability: persistence.observability,
            sharing: controllers.sharing,
            virtualDisplay: controllers.virtualDisplay,
            displayRuntime: runtime.displayRuntime,
            sharingAdapter: runtime.sharingAdapter,
            capturePerformancePreferences: persistence.capturePerformancePreferences,
            feedbackController: persistence.feedbackController,
            openScreenCapturePrivacySettings: { openURL in
                captureSharing.catalogService.openScreenCapturePrivacySettings(openURL: openURL)
            },
            startupTask: startupTask
        )
    }

    private static func resolveConfiguration(
        preview: Bool,
        startupPlan: StartupPlan?,
        isRunningUnderXCTestOverride: Bool?
    ) -> AppBootstrapConfiguration {
        let isRunningUnderXCTest = isRunningUnderXCTestOverride
            ?? (ProcessInfo.processInfo.environment[xCTestConfigurationEnvironmentKey] != nil)
        return AppBootstrapConfiguration(
            preview: preview,
            startupPlan: startupPlan ?? (isRunningUnderXCTest ? .skipAll : .standard)
        )
    }
}
