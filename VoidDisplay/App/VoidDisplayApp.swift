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
    let observability: ObservabilityCenter
    let sharing: SharingController
    let virtualDisplay: VirtualDisplayController
    let screenCatalog: ScreenCatalogOrchestrator
    let capturePerformancePreferences: CapturePerformancePreferences
    let feedbackController: AppSettingsFeedbackController
}

@main
struct VoidDisplayApp: App {
    @State private var capture: CaptureController
    @State private var sharing: SharingController
    @State private var virtualDisplay: VirtualDisplayController
    @State private var screenCatalog: ScreenCatalogOrchestrator
    @State private var capturePerformancePreferences: CapturePerformancePreferences
    @State private var navigation: AppNavigationController
    @State private var feedbackController: AppSettingsFeedbackController
    private let observability: ObservabilityCenter

    init() {
        let env = AppBootstrap.makeEnvironment()
        _capture = State(initialValue: env.capture)
        _sharing = State(initialValue: env.sharing)
        _virtualDisplay = State(initialValue: env.virtualDisplay)
        _screenCatalog = State(initialValue: env.screenCatalog)
        _capturePerformancePreferences = State(initialValue: env.capturePerformancePreferences)
        _navigation = State(initialValue: AppNavigationController())
        _feedbackController = State(initialValue: env.feedbackController)
        observability = env.observability
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if CapturePreviewDiagnosticsRuntime.shouldAutoOpenPreviewWindow,
                   let sessionID = capture.screenCaptureSessions.first?.id {
                    CaptureDisplayView(sessionId: sessionID)
                } else if UITestRuntime.scenario == .settingsFeedback {
                    AppSettingsView(
                        observability: observability,
                        feedbackController: feedbackController
                    )
                } else {
                    HomeView(
                        screenCatalogOrchestrator: screenCatalog,
                        observability: observability,
                        feedbackController: feedbackController
                    )
                }
            }
            .environment(capture)
            .environment(sharing)
            .environment(virtualDisplay)
            .environment(capturePerformancePreferences)
            .environment(navigation)
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
            AppSettingsView(
                observability: observability,
                feedbackController: feedbackController
            )
                .environment(capture)
                .environment(sharing)
                .environment(virtualDisplay)
                .environment(capturePerformancePreferences)
                .environment(navigation)
        }
    }
}

@MainActor
enum AppBootstrap {
    private static let xCTestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

    private struct UITestFeedbackExportFailure: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

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
        let catalogService = ScreenCaptureCatalogService()

        var persistenceEnvironment = ProcessInfo.processInfo.environment
        if preview {
            persistenceEnvironment[PersistenceContext.uiTestModeEnvironmentKey] = "1"
        }
        let persistenceContext = PersistenceContext.resolve(environment: persistenceEnvironment)
        let capturePerformancePreferences = CapturePerformancePreferences(
            defaults: persistenceContext.userDefaults
        )
        let sanitizer = ObservabilitySanitizer()
        let observability = ObservabilityCenter(
            eventStore: EventStore(directoryURL: persistenceContext.observabilityEventsDirectoryURL),
            issueStore: IssueStore(fileURL: persistenceContext.observabilityIssuesURL),
            snapshotWriter: AgentSnapshotWriter(
                currentStateURL: persistenceContext.observabilityCurrentStateURL,
                healthSummaryURL: persistenceContext.observabilityHealthSummaryURL,
                recentEventsURL: persistenceContext.observabilityRecentEventsURL
            ),
            exporter: FeedbackBundleExporter(
                exportsDirectoryURL: persistenceContext.observabilityExportsDirectoryURL,
                virtualDisplayConfigsURL: persistenceContext.virtualDisplayConfigsURL,
                displayShareMappingsURL: persistenceContext.displayShareIDMappingsURL,
                sanitizer: sanitizer
            ),
            transport: LocalExportTransport(),
            observabilityDirectoryURL: persistenceContext.observabilityDirectoryURL,
            sanitizer: sanitizer
        )
        let supportHistoryStore = SupportHistoryStore(
            historyFileURL: persistenceContext.observabilityDirectoryURL
                .appendingPathComponent("support-history.json", isDirectory: false),
            exportsDirectoryURL: persistenceContext.observabilityExportsDirectoryURL,
            sanitizer: sanitizer
        )
        let feedbackController: AppSettingsFeedbackController
        if let failureMessage = UITestRuntime.feedbackExportFailureMessage {
            feedbackController = AppSettingsFeedbackController(
                defaults: persistenceContext.userDefaults,
                historyStore: supportHistoryStore,
                exportAction: { _, _ in
                    throw UITestFeedbackExportFailure(message: failureMessage)
                }
            )
        } else {
            feedbackController = AppSettingsFeedbackController(
                defaults: persistenceContext.userDefaults,
                historyStore: supportHistoryStore
            )
        }
        let captureRegistry = DisplayCaptureRegistry(
            performanceMode: capturePerformancePreferences.mode
        )
        capturePerformancePreferences.onModeChanged = { mode in
            Task {
                await captureRegistry.updatePerformanceMode(mode)
            }
        }

        let resolvedSharingService: any SharingServiceProtocol
        if let sharingService {
            resolvedSharingService = sharingService
        } else {
            let idStore = DisplayShareIDStore(storeURL: persistenceContext.displayShareIDMappingsURL)
            let sharingCoordinator = DisplaySharingCoordinator(
                idStore: idStore,
                captureRegistry: captureRegistry
            )
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

        let capture = CaptureController(
            captureMonitoringService: resolvedCaptureMonitoringService,
            captureMonitoringLifecycleService: CaptureMonitoringLifecycleService(
                captureMonitoringService: resolvedCaptureMonitoringService,
                captureRegistry: captureRegistry
            ),
            catalogService: catalogService,
            observability: observability
        )
        let sharing = SharingController(
            sharingService: resolvedSharingService,
            portPreferences: SharingPortPreferences(defaults: persistenceContext.userDefaults),
            catalogService: catalogService,
            observability: observability
        )
        let virtualDisplay = VirtualDisplayController(
            virtualDisplayFacade: resolvedVirtualDisplayFacade,
            appliedBadgeDisplayDuration: appliedBadgeDisplayDuration,
            stopDependentStreamsBeforeRebuild: { displayID in
                capture.stopDependentStreamsBeforeRebuild(
                    displayID: displayID,
                    sharingController: sharing
                )
            },
            observability: observability
        )
        AppErrorMapper.installFailureBridge { error, subsystem, operation, context in
            Task { [weak observability] in
                guard let observability else { return }
                await observability.record(
                    error: error,
                    subsystem: subsystem,
                    operation: operation,
                    context: context
                )
            }
        }

        let env = AppEnvironment(
            capture: capture,
            observability: observability,
            sharing: sharing,
            virtualDisplay: virtualDisplay,
            screenCatalog: ScreenCatalogOrchestrator(
                catalogService: catalogService,
                capture: capture,
                sharing: sharing,
                virtualDisplay: virtualDisplay,
                observability: observability
            ),
            capturePerformancePreferences: capturePerformancePreferences,
            feedbackController: feedbackController
        )
        Task {
            await observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(CaptureSnapshotProvider(controller: capture))
            )
            await observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(SharingSnapshotProvider(controller: sharing))
            )
            await observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(VirtualDisplaySnapshotProvider(controller: virtualDisplay))
            )
            await observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(ScreenCatalogSnapshotProvider(store: catalogService.store))
            )
            await observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(SystemSnapshotProvider(environment: persistenceEnvironment))
            )
            await observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(PersistenceSnapshotProvider(context: persistenceContext))
            )
            await observability.refreshSnapshot(reason: .startup)
        }

        guard !preview else { return env }

        if resolvedStartupPlan.shouldRestoreVirtualDisplays {
            virtualDisplay.loadPersistedConfigsAndRestoreDesiredVirtualDisplays()
            resolvedStartupPlan.postRestoreConfiguration?(virtualDisplay)
        }

        return env
    }
}
