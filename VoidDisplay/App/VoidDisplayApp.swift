//
//  VoidDisplayApp.swift
//  VoidDisplay
//
//

import Foundation
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
        .windowToolbarStyle(.unified(showsTitle: true))

        WindowGroup(for: UUID.self) { $sessionId in
            CaptureDisplayWindowRoot(sessionId: sessionId)
                .environment(capture)
                .environment(sharing)
                .environment(virtualDisplay)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))

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
        var postRestoreConfiguration: (@MainActor (VirtualDisplayController) -> Void)?

        static let standard = StartupPlan(
            shouldRestoreVirtualDisplays: true,
            postRestoreConfiguration: nil
        )

        static let skipAll = StartupPlan(
            shouldRestoreVirtualDisplays: false,
            postRestoreConfiguration: nil
        )
    }

    static func makeEnvironment() -> AppEnvironment {
        guard UITestRuntime.isEnabled else {
            return makeEnvironment(preview: false)
        }

        let scenario = UITestRuntime.scenario
        let captureMonitoringService: (any CaptureMonitoringServiceProtocol)? = {
            guard scenario == .capturePreviewDiagnostics,
                  let configuration = CapturePreviewDiagnosticsRuntime.configuration()
            else {
                return nil
            }
            return try? CapturePreviewDiagnosticsBootstrap.makeMonitoringService(
                configuration: configuration
            )
        }()
        return makeEnvironment(
            preview: false,
            captureMonitoringService: captureMonitoringService,
            virtualDisplayFacade: UITestVirtualDisplayFacade(scenario: scenario),
            startupPlan: .init(
                shouldRestoreVirtualDisplays: true,
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
        virtualDisplayFacade: (any VirtualDisplayFacade)? = nil,
        appliedBadgeDisplayDuration: Duration = .seconds(2.5),
        startupPlan: StartupPlan? = nil,
        isRunningUnderXCTestOverride: Bool? = nil
    ) -> AppEnvironment {
        let isRunningUnderXCTest = isRunningUnderXCTestOverride
            ?? (ProcessInfo.processInfo.environment[xCTestConfigurationEnvironmentKey] != nil)
        let resolvedStartupPlan = startupPlan ?? (isRunningUnderXCTest ? .skipAll : .standard)
        let resolvedCaptureMonitoringService = captureMonitoringService ?? CaptureMonitoringService()

        var persistenceEnvironment = ProcessInfo.processInfo.environment
        if preview {
            persistenceEnvironment[PersistenceContext.uiTestModeEnvironmentKey] = "1"
        }
        let persistenceContext = PersistenceContext.resolve(environment: persistenceEnvironment)

        let resolvedSharingService: any SharingServiceProtocol
        if let sharingService {
            resolvedSharingService = sharingService
        } else {
            let idStore = DisplayShareIDStore(storeURL: persistenceContext.displayShareIDMappingsURL)
            let sharingCoordinator = DisplaySharingCoordinator(idStore: idStore)
            resolvedSharingService = SharingService(sharingCoordinator: sharingCoordinator)
        }

        let resolvedVirtualDisplayFacade: any VirtualDisplayFacade
        if let virtualDisplayFacade {
            resolvedVirtualDisplayFacade = virtualDisplayFacade
        } else {
            let virtualDisplayStore = VirtualDisplayStore(
                storeURL: persistenceContext.virtualDisplayConfigsURL,
                mode: persistenceContext.mode
            )
            let configRepository = VirtualDisplayConfigRepository(store: virtualDisplayStore)
            resolvedVirtualDisplayFacade = VirtualDisplayOrchestrator(configRepository: configRepository)
        }

        let capture = CaptureController(captureMonitoringService: resolvedCaptureMonitoringService)
        let sharing = SharingController(
            sharingService: resolvedSharingService,
            portPreferences: SharingPortPreferences(defaults: persistenceContext.userDefaults)
        )
        let virtualDisplay = VirtualDisplayController(
            virtualDisplayFacade: resolvedVirtualDisplayFacade,
            appliedBadgeDisplayDuration: appliedBadgeDisplayDuration,
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

        if resolvedStartupPlan.shouldRestoreVirtualDisplays {
            virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()
            resolvedStartupPlan.postRestoreConfiguration?(virtualDisplay)
        }

        return env
    }
}
