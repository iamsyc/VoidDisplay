//
//  VoidDisplayApp.swift
//  VoidDisplay
//
//

import SwiftUI

@MainActor
struct AppEnvironment {
    let capture: CaptureController
    let sharing: SharingController
    let virtualDisplay: VirtualDisplayController
}

@main
struct VoidDisplayApp: App {
    @State private var capture: CaptureController
    @State private var sharing: SharingController
    @State private var virtualDisplay: VirtualDisplayController

    init() {
        let env = AppBootstrap.makeEnvironment()
        _capture = State(initialValue: env.capture)
        _sharing = State(initialValue: env.sharing)
        _virtualDisplay = State(initialValue: env.virtualDisplay)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(capture)
                .environment(sharing)
                .environment(virtualDisplay)
        }

        WindowGroup(for: UUID.self) { $sessionId in
            CaptureDisplayWindowRoot(sessionId: sessionId)
                .environment(capture)
                .environment(sharing)
                .environment(virtualDisplay)
        }

        Settings {
            AppSettingsView()
                .environment(capture)
                .environment(sharing)
                .environment(virtualDisplay)
        }
    }
}

@MainActor
enum AppBootstrap {
    private static let xCTestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

    struct StartupPlan {
        var shouldRestoreVirtualDisplays: Bool
        var shouldStartWebService: Bool
        var postRestoreConfiguration: (@MainActor (VirtualDisplayController) -> Void)?

        static let standard = StartupPlan(
            shouldRestoreVirtualDisplays: true,
            shouldStartWebService: true,
            postRestoreConfiguration: nil
        )

        static let skipAll = StartupPlan(
            shouldRestoreVirtualDisplays: false,
            shouldStartWebService: false,
            postRestoreConfiguration: nil
        )
    }

    static func makeEnvironment() -> AppEnvironment {
        guard UITestRuntime.isEnabled else {
            return makeEnvironment(preview: false)
        }

        let scenario = UITestRuntime.scenario
        return makeEnvironment(
            preview: false,
            virtualDisplayService: UITestVirtualDisplayService(scenario: scenario),
            startupPlan: .init(
                shouldRestoreVirtualDisplays: true,
                shouldStartWebService: false,
                postRestoreConfiguration: { controller in
                    controller.applyUITestPresentationState(scenario: scenario)
                }
            )
        )
    }

    static func makeEnvironment(
        preview: Bool,
        captureMonitoringService: (any CaptureMonitoringServiceProtocol)? = nil,
        sharingService: (any SharingServiceProtocol)? = nil,
        virtualDisplayService: (any VirtualDisplayServiceProtocol)? = nil,
        appliedBadgeDisplayDurationNanoseconds: UInt64 = 2_500_000_000,
        startupPlan: StartupPlan? = nil,
        isRunningUnderXCTestOverride: Bool? = nil
    ) -> AppEnvironment {
        let isRunningUnderXCTest = isRunningUnderXCTestOverride
            ?? (ProcessInfo.processInfo.environment[xCTestConfigurationEnvironmentKey] != nil)
        let resolvedStartupPlan = startupPlan ?? (isRunningUnderXCTest ? .skipAll : .standard)
        let resolvedCaptureMonitoringService = captureMonitoringService ?? CaptureMonitoringService()
        let resolvedSharingService = sharingService ?? SharingService()
        let resolvedVirtualDisplayService = virtualDisplayService ?? VirtualDisplayService()

        let capture = CaptureController(captureMonitoringService: resolvedCaptureMonitoringService)
        let sharing = SharingController(sharingService: resolvedSharingService)
        let virtualDisplay = VirtualDisplayController(
            virtualDisplayService: resolvedVirtualDisplayService,
            appliedBadgeDisplayDurationNanoseconds: appliedBadgeDisplayDurationNanoseconds,
            stopDependentStreamsBeforeRebuild: { displayID in
                capture.stopDependentStreamsBeforeRebuild(
                    displayID: displayID,
                    sharingController: sharing
                )
            }
        )

        let env = AppEnvironment(
            capture: capture,
            sharing: sharing,
            virtualDisplay: virtualDisplay
        )

        guard !preview else { return env }

        if resolvedStartupPlan.shouldStartWebService {
            Task { @MainActor in
                _ = await sharing.startWebService()
            }
        }

        if resolvedStartupPlan.shouldRestoreVirtualDisplays {
            virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()
            resolvedStartupPlan.postRestoreConfiguration?(virtualDisplay)
        }

        return env
    }
}
