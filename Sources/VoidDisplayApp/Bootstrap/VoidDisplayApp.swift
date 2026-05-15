import VoidDisplayVirtualDisplay
import VoidDisplayCGVirtualDisplay
import VoidDisplayCapture
import VoidDisplaySharing
import VoidDisplaySupport
import VoidDisplayObservability
import VoidDisplayRuntime
import VoidDisplayFoundation
//
//  VoidDisplayApp.swift
//  VoidDisplay
//
//

import AppKit
import Foundation
import SwiftUI

@MainActor
package struct AppEnvironment {
    package let capture: CaptureController
    package let observability: ObservabilityCenter
    package let sharing: SharingController
    package let virtualDisplay: VirtualDisplayController
    package let displayRuntime: DisplayRuntime
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
        self.capturePerformancePreferences = capturePerformancePreferences
        self.feedbackController = feedbackController
        self.openScreenCapturePrivacySettings = openScreenCapturePrivacySettings
        self.startupTask = startupTask
    }

    package func waitForStartupTasks() async {
        await startupTask.value
    }
}

public struct VoidDisplayApplication: App {
    @NSApplicationDelegateAdaptor(VoidDisplayApplicationDelegate.self) private var appDelegate
    @State private var capture: CaptureController
    @State private var sharing: SharingController
    @State private var virtualDisplay: VirtualDisplayController
    @State private var capturePerformancePreferences: CapturePerformancePreferences
    @State private var navigation: AppNavigationController
    @State private var feedbackController: AppSettingsFeedbackController
    private let observability: ObservabilityCenter
    private let displayRuntime: DisplayRuntime
    private let openScreenCapturePrivacySettings: @MainActor (@escaping (URL) -> Void) -> Void

    public init() {
        let env = AppBootstrap.makeEnvironment()
        _capture = State(initialValue: env.capture)
        _sharing = State(initialValue: env.sharing)
        _virtualDisplay = State(initialValue: env.virtualDisplay)
        _capturePerformancePreferences = State(initialValue: env.capturePerformancePreferences)
        _navigation = State(initialValue: AppNavigationController())
        _feedbackController = State(initialValue: env.feedbackController)
        observability = env.observability
        displayRuntime = env.displayRuntime
        openScreenCapturePrivacySettings = env.openScreenCapturePrivacySettings
        AppTerminationCleanup.install {
            env.sharing.stopWebService()
        }
    }

    public var body: some Scene {
        WindowGroup {
            Group {
                if CapturePreviewDiagnosticsRuntime.shouldAutoOpenPreviewWindow,
                   let sessionID = capture.screenCaptureSessions.first?.id {
                    CaptureDisplayView(
                        sessionId: sessionID,
                        monitoringActions: CaptureUIComposition.monitoringActions(
                            capture: capture,
                            displayRuntime: displayRuntime
                        ),
                        sharingStatusProvider: CaptureUIComposition.sharingStatusProvider(sharing: sharing)
                    )
                } else if UITestRuntime.scenario == .settingsFeedback {
                    AppSettingsView(
                        observability: observability,
                        feedbackController: feedbackController
                    )
                } else {
                    HomeView(
                        observability: observability,
                        feedbackController: feedbackController,
                        displayRuntime: displayRuntime,
                        openScreenCapturePrivacySettings: openScreenCapturePrivacySettings
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
            CaptureDisplayWindowRoot(
                sessionId: sessionId,
                monitoringActions: CaptureUIComposition.monitoringActions(
                    capture: capture,
                    displayRuntime: displayRuntime
                ),
                sharingStatusProvider: CaptureUIComposition.sharingStatusProvider(sharing: sharing)
            )
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
private enum AppTerminationCleanup {
    private static var handler: (() -> Void)?

    static func install(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    static func run() {
        guard let handler else { return }
        self.handler = nil
        handler()
    }
}

@MainActor
private final class VoidDisplayApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_: Notification) {
        AppTerminationCleanup.run()
    }
}

@MainActor
package enum AppBootstrap {
    private static let xCTestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

    private struct UITestFeedbackExportFailure: LocalizedError {
        let message: String

        var errorDescription: String? {
            message
        }
    }

    private struct DisplayRuntimeRebuildExecutorError: LocalizedError {
        let reason: String

        init(transactionStatus: String) {
            self.reason = "display_runtime_transaction_\(transactionStatus)"
        }

        var errorDescription: String? {
            String(localized: "Failed to rebuild virtual display.")
        }
    }

    package struct StartupPlan {
        var shouldRestoreVirtualDisplays: Bool

        static let standard = StartupPlan(
            shouldRestoreVirtualDisplays: true
        )

        static let skipAll = StartupPlan(
            shouldRestoreVirtualDisplays: false
        )
    }

    package static func makeEnvironment() -> AppEnvironment {
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
        let env = makeEnvironment(
            preview: false,
            captureMonitoringService: captureMonitoringService,
            virtualDisplayFacade: UITestVirtualDisplayFacade(scenario: scenario),
            startupPlan: .init(
                shouldRestoreVirtualDisplays: true
            )
        )
        env.virtualDisplay.applyUITestPresentationState(scenario: scenario)
        return env
    }

    package static func makeEnvironment(
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
        let relayProcessController = RelayProcessController()
        let captureRegistry = DisplayCaptureRegistry(
            performanceMode: capturePerformancePreferences.mode,
            makeShareFrameConsumer: {
                RelaySessionHub(relayProcessController: relayProcessController)
            }
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
                acquireShare: { display, invalidationContext in
                    try await captureRegistry.acquireShare(
                        display: SendableDisplay(display),
                        invalidationContext: invalidationContext
                    )
                }
            )
            resolvedSharingService = SharingService(
                webServiceController: WebServiceController(relayProcessController: relayProcessController),
                sharingCoordinator: sharingCoordinator
            )
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
            resolvedVirtualDisplayFacade = VirtualDisplayOrchestrator(
                configRepository: configRepository,
                runtimeDriver: makeVirtualDisplayRuntimeDriver()
            )
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
        let displayRuntimeCatalogAdapter = DisplayRuntimeCatalogAdapter(service: catalogService)
        let displayRuntimeCaptureAdapter = DisplayRuntimeCaptureAdapter(
            controller: capture,
            sharingController: sharing,
            isManagedVirtualDisplay: { displayID in
                virtualDisplay.managedDisplays.contains {
                    $0.displayID == displayID && $0.isLiveRuntime
                }
            }
        )
        let displayRuntimeSharingAdapter = DisplayRuntimeSharingAdapter(controller: sharing)
        let displayRuntimeVirtualDisplayAdapter = DisplayRuntimeVirtualDisplayAdapter(
            controller: virtualDisplay,
            commandFacade: resolvedVirtualDisplayFacade
        )
        let displayRuntimeObservabilityAdapter = DisplayRuntimeObservabilityAdapter(observability: observability)
        let displayRuntime = DisplayRuntime(
            catalogProvider: displayRuntimeCatalogAdapter,
            captureProvider: displayRuntimeCaptureAdapter,
            sharingProvider: displayRuntimeSharingAdapter,
            virtualDisplayProvider: displayRuntimeVirtualDisplayAdapter,
            catalogCommander: displayRuntimeCatalogAdapter,
            sharingCommander: displayRuntimeSharingAdapter,
            captureCommander: displayRuntimeCaptureAdapter,
            captureIntentCommander: displayRuntimeCaptureAdapter,
            virtualDisplayCommander: displayRuntimeVirtualDisplayAdapter,
            startupRestoreCommander: displayRuntimeVirtualDisplayAdapter,
            observabilityRecorder: displayRuntimeObservabilityAdapter
        )
        displayRuntimeSharingAdapter.configureLANWebViewDemandSync(runtime: displayRuntime)
        virtualDisplay.configureRebuildExecutor { configID, source in
            let result = try await displayRuntime.rebuildVirtualDisplay(
                configID: configID,
                source: DisplayRuntimeTransactionSource(source)
            )
            guard result.status != .failed && result.status != .cancelled else {
                throw DisplayRuntimeRebuildExecutorError(transactionStatus: result.status.rawValue)
            }
        }
        virtualDisplay.configureDesiredEnabledExecutor { configID, enabled, source in
            let result = try await displayRuntime.setVirtualDisplayDesiredEnabled(
                configID: configID,
                enabled: enabled,
                source: DisplayRuntimeTransactionSource(source)
            )
            guard result.status != .failed && result.status != .cancelled else {
                throw DisplayRuntimeRebuildExecutorError(transactionStatus: result.status.rawValue)
            }
        }
        virtualDisplay.configureEditRebuildExecutor { updatedConfig, expectedConfigFingerprint, source in
            let runtimeSource = DisplayRuntimeTransactionSource(source)
            let runtimeHandle = try await displayRuntime.saveVirtualDisplayConfigAndRebuild(
                request: DisplayRuntimeVirtualDisplayEditRebuildRequest(
                    editedConfig: DisplayRuntimeVirtualDisplayConfigEditDTO(adapterConfig: updatedConfig),
                    expectedConfigFingerprint: expectedConfigFingerprint,
                    source: runtimeSource
                ),
                source: runtimeSource
            )
            return VirtualDisplayEditRebuildTransactionHandle(
                transactionID: runtimeHandle.transactionID.rawValue,
                saveGateTask: Task { @MainActor in
                    defer { virtualDisplay.refreshVirtualDisplayState() }
                    let saveGate = try await runtimeHandle.waitForSaveGate()
                    return VirtualDisplayEditRebuildSaveGateResult(
                        transactionID: saveGate.transactionID.rawValue,
                        configID: saveGate.configID
                    )
                },
                terminalResultTask: Task { @MainActor in
                    defer { virtualDisplay.refreshVirtualDisplayState() }
                    let result = try await runtimeHandle.waitForTerminalResult()
                    return VirtualDisplayEditRebuildTransactionResult(
                        transactionID: result.transactionID.rawValue,
                        status: VirtualDisplayEditRebuildTransactionStatus(result.status),
                        virtualDisplayCommandSucceeded: result.virtualDisplayCommandSucceeded
                    )
                }
            )
        }
        virtualDisplay.configureCreateExecutor { request in
            let runtimeSource = DisplayRuntimeTransactionSource.createVirtualDisplaySheet
            let result = try await displayRuntime.createVirtualDisplay(
                request: DisplayRuntimeVirtualDisplayCreateRequest(
                    request: request,
                    source: runtimeSource
                ),
                source: runtimeSource
            )
            return VirtualDisplayCreateTransactionResult(
                transactionID: result.transactionID.rawValue,
                status: VirtualDisplayCommandTransactionStatus(result.status),
                createdConfigID: result.createdConfigID,
                virtualDisplayCommandSucceeded: result.runtimeCreationOutcome == .succeeded
            )
        }
        virtualDisplay.configureDeleteExecutor { configID in
            let result = try await displayRuntime.deleteVirtualDisplay(
                configID: configID,
                source: .deleteVirtualDisplayConfirmation
            )
            return VirtualDisplayDeleteTransactionResult(
                transactionID: result.transactionID.rawValue,
                status: VirtualDisplayCommandTransactionStatus(result.status),
                configID: result.configID,
                virtualDisplayCommandSucceeded: result.virtualDisplayCommandOutcome == .succeeded
            )
        }

        let startupTask = Task { @MainActor in
            await observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(DisplayRuntimeSnapshotProvider(runtime: displayRuntime))
            )
            await observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(SystemSnapshotProvider(environment: persistenceEnvironment))
            )
            await observability.registerSnapshotProvider(
                AnyObservabilitySnapshotProvider(PersistenceSnapshotProvider(context: persistenceContext))
            )
            if !preview, resolvedStartupPlan.shouldRestoreVirtualDisplays {
                _ = await displayRuntime.restoreStartupVirtualDisplays(source: .startup)
                virtualDisplay.refreshVirtualDisplayState()
            }
            await observability.refreshSnapshot(reason: .startup)
        }

        let env = AppEnvironment(
            capture: capture,
            observability: observability,
            sharing: sharing,
            virtualDisplay: virtualDisplay,
            displayRuntime: displayRuntime,
            capturePerformancePreferences: capturePerformancePreferences,
            feedbackController: feedbackController,
            openScreenCapturePrivacySettings: { openURL in
                catalogService.openScreenCapturePrivacySettings(openURL: openURL)
            },
            startupTask: startupTask
        )

        return env
    }
}
