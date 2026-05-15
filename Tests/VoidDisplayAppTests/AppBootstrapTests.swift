@testable import VoidDisplayApp
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayCapture
@testable import VoidDisplaySharing
@testable import VoidDisplayRuntime
@testable import VoidDisplayObservability
@testable import VoidDisplayFoundation
@testable import VoidDisplayTestingSupport
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct AppBootstrapTests {
    @Test func initUsesDefaultCaptureMonitoringServiceWhenInjectionIsOmitted() async {
        let sharing = MockSharingService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let env = AppBootstrap.makeEnvironment(
            preview: true,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(env.capture.screenCaptureSessions.isEmpty)
        #expect(sharing.startWebServiceCallCount == 0)
        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
    }

    @Test func initRegistersRuntimeSnapshotProvider() async throws {
        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            isRunningUnderXCTestOverride: true
        )

        await env.waitForStartupObservability()
        let diagnostics = await env.observability.diagnosticsSnapshot()
        let runtimeSection = try #require(diagnostics.state.sections["runtime"])
        let runtime = try runtimeSection.decode(DisplayRuntimeSnapshot.self)

        #expect(runtime.schemaVersion == 3)
        #expect(diagnostics.state.sections["system"] != nil)
        #expect(diagnostics.state.sections["persistence"] != nil)
        #expect(diagnostics.state.sections["capture"] == nil)
        #expect(diagnostics.state.sections["sharing"] == nil)
        #expect(diagnostics.state.sections["virtualDisplay"] == nil)
        #expect(diagnostics.state.sections["screenCatalog"] == nil)
    }

    @Test func initInjectsRuntimeBackedVirtualDisplayRebuildExecutor() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Runtime Rebuild",
            serialNum: 9401,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.currentDisplayConfigs = [config]

        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(env.virtualDisplay.hasConfiguredRebuildExecutor)

        env.virtualDisplay.startRebuildFromSavedConfig(configId: config.id)

        let rebuilt = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayConfigIds == [config.id]
                && !env.displayRuntime.makeSnapshot().transactions.recentTransactions.isEmpty
        }
        let trace = try #require(env.displayRuntime.makeSnapshot().transactions.recentTransactions.first)

        #expect(rebuilt)
        #expect(trace.kind == .virtualDisplayRebuild)
        #expect(trace.status == .completed || trace.status == .completedWithRecoveryFailures)
        #expect(trace.topologyStabilityResult != nil)
    }

    @Test func initInjectsRuntimeBackedVirtualDisplayDesiredEnabledExecutor() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Runtime Toggle",
            serialNum: 9402,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: false
        )
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.currentDisplayConfigs = [config]

        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(env.virtualDisplay.hasConfiguredDesiredEnabledExecutor)

        try await env.virtualDisplay.setVirtualDisplayDesiredEnabled(
            configId: config.id,
            enabled: true,
            source: .rowToggle
        )
        let trace = try #require(env.displayRuntime.makeSnapshot().transactions.recentTransactions.first)

        #expect(virtualDisplay.setDesiredEnabledRequests.map(\.0) == [config.id])
        #expect(virtualDisplay.enableRuntimeDisplayConfigIDs == [config.id])
        #expect(virtualDisplay.enableRuntimeDisplayCallCount == 1)
        #expect(trace.kind == .virtualDisplayEnable)
    }

    @Test func initInjectsRuntimeBackedVirtualDisplayEditRebuildExecutor() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Runtime Edit",
            serialNum: 9403,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var edited = config
        edited.displayName = "Runtime Edit Renamed"
        edited.serialNum = 9404
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.currentDisplayConfigs = [config]

        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(env.virtualDisplay.hasConfiguredEditRebuildExecutor)

        let handle = try await env.virtualDisplay.saveConfigAndRebuild(
            edited,
            expectedConfigFingerprint: config.editRebuildFingerprint,
            source: .editSaveAndRebuild
        )
        let saveGate = try await handle.waitForSaveGate()
        env.virtualDisplay.startEditRebuildPresentation(configId: config.id, handle: handle)

        let rebuilt = await waitUntil {
            virtualDisplay.rebuildVirtualDisplayConfigIds == [config.id]
                && !env.displayRuntime.makeSnapshot().transactions.recentTransactions.isEmpty
        }
        let trace = try #require(env.displayRuntime.makeSnapshot().transactions.recentTransactions.first)

        #expect(saveGate.configID == config.id)
        #expect(rebuilt)
        #expect(virtualDisplay.saveConfigForRebuildCallCount == 1)
        #expect(virtualDisplay.updateConfigCallCount == 0)
        #expect(trace.kind == .virtualDisplayEditRebuild)
        #expect(trace.source == .editSaveAndRebuild)
    }

    @Test func initInjectsRuntimeBackedVirtualDisplayCreateExecutor() async throws {
        let createdConfigID = UUID()
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.createDisplayResult = .success(createdConfigID)

        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(env.virtualDisplay.hasConfiguredCreateExecutor)

        let result = try await env.virtualDisplay.createVirtualDisplay(
            VirtualDisplayCreateRequest(
                displayName: "Runtime Create",
                serialNumber: 9407,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                maximumPixelWidth: 1920,
                maximumPixelHeight: 1080,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        )
        let trace = try #require(env.displayRuntime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result == createdConfigID)
        #expect(virtualDisplay.createDisplayCommandCallCount == 1)
        #expect(virtualDisplay.createDisplayCommandSerialNumbers == [9407])
        #expect(trace.kind == .virtualDisplayCreate)
        #expect(trace.source == .createVirtualDisplaySheet)
        #expect(trace.createdConfigID == createdConfigID)
    }

    @Test func initInjectsRuntimeBackedVirtualDisplayDeleteExecutor() async throws {
        let config = VirtualDisplayConfig(
            displayName: "Runtime Delete",
            serialNum: 9408,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.currentDisplayConfigs = [config]
        virtualDisplay.currentRunningConfigIds = [config.id]
        virtualDisplay.runtimeDisplayIDByConfigId = [config.id: 9408]

        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(env.virtualDisplay.hasConfiguredDeleteExecutor)

        try await env.virtualDisplay.deleteVirtualDisplay(configId: config.id)
        let trace = try #require(env.displayRuntime.makeSnapshot().transactions.recentTransactions.first)

        #expect(virtualDisplay.destroyDisplayByConfigCallCount == 1)
        #expect(virtualDisplay.destroyedConfigIDs == [config.id])
        #expect(trace.kind == .virtualDisplayDelete)
        #expect(trace.source == .deleteVirtualDisplayConfirmation)
        #expect(trace.targetConfigID == config.id)
        #expect(trace.runtimeTrackingClearOutcome == .cleared)
    }

    @Test func editRebuildRuntimeTraceDisplayNameIsAbsentFromObservabilityAndSupportBundle() async throws {
        let secretName = "Runtime Secret Edit Name"
        let config = VirtualDisplayConfig(
            displayName: "Runtime Original",
            serialNum: 9405,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        var edited = config
        edited.displayName = secretName
        edited.serialNum = 9406
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.currentDisplayConfigs = [config]
        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        let handle = try await env.virtualDisplay.saveConfigAndRebuild(
            edited,
            expectedConfigFingerprint: config.editRebuildFingerprint,
            source: .editSaveAndRebuild
        )
        _ = try await handle.waitForSaveGate()
        _ = try await handle.waitForTerminalResult()
        await env.waitForStartupObservability()
        await env.observability.refreshSnapshot(reason: .displayRuntimeTransactionChanged)

        let runtimeJSON = String(
            decoding: try JSONEncoder().encode(env.displayRuntime.makeSnapshot()),
            as: UTF8.self
        )
        let diagnostics = await env.observability.diagnosticsSnapshot()
        let diagnosticsJSON = String(
            decoding: try JSONEncoder().encode(diagnostics.state),
            as: UTF8.self
        )
        let bundleURL = try await env.observability.exportBundle(
            draft: FeedbackDraft(happened: "Edit rebuild failed"),
            consent: FeedbackConsent()
        )
        let bundleStateJSON = try supportBundleEntryString(
            archiveURL: bundleURL,
            relativePathSuffix: "/state/current-state.json"
        )

        #expect(runtimeJSON.contains(secretName) == false)
        #expect(diagnosticsJSON.contains(secretName) == false)
        #expect(bundleStateJSON.contains(secretName) == false)
    }

    @Test func createDeleteRuntimeTraceDisplayNameIsAbsentFromObservabilityAndSupportBundle() async throws {
        let secretCreateName = "Runtime Secret Create Name"
        let secretDeleteName = "Runtime Secret Delete Name"
        let createdConfigID = UUID()
        let deleteConfig = VirtualDisplayConfig(
            displayName: secretDeleteName,
            serialNum: 9409,
            physicalWidth: 600,
            physicalHeight: 340,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        let virtualDisplay = MockVirtualDisplayFacade()
        virtualDisplay.currentDisplayConfigs = [deleteConfig]
        virtualDisplay.currentRunningConfigIds = [deleteConfig.id]
        virtualDisplay.runtimeDisplayIDByConfigId = [deleteConfig.id: 9409]
        virtualDisplay.createDisplayResult = .success(createdConfigID)
        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        _ = try await env.virtualDisplay.createVirtualDisplay(
            VirtualDisplayCreateRequest(
                displayName: secretCreateName,
                serialNumber: 9410,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                maximumPixelWidth: 1920,
                maximumPixelHeight: 1080,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        )
        try await env.virtualDisplay.deleteVirtualDisplay(configId: deleteConfig.id)
        await env.waitForStartupObservability()
        await env.observability.refreshSnapshot(reason: .displayRuntimeTransactionChanged)

        let runtimeJSON = String(
            decoding: try JSONEncoder().encode(env.displayRuntime.makeSnapshot()),
            as: UTF8.self
        )
        let diagnostics = await env.observability.diagnosticsSnapshot()
        let diagnosticsJSON = String(
            decoding: try JSONEncoder().encode(diagnostics.state),
            as: UTF8.self
        )
        let bundleURL = try await env.observability.exportBundle(
            draft: FeedbackDraft(happened: "Create delete failed"),
            consent: FeedbackConsent()
        )
        let bundleStateJSON = try supportBundleEntryString(
            archiveURL: bundleURL,
            relativePathSuffix: "/state/current-state.json"
        )

        for secretName in [secretCreateName, secretDeleteName] {
            #expect(runtimeJSON.contains(secretName) == false)
            #expect(diagnosticsJSON.contains(secretName) == false)
            #expect(bundleStateJSON.contains(secretName) == false)
        }
    }

    @Test func runtimeConsumerLeaseCallerTextIsAbsentFromObservabilityAndSupportBundle() async throws {
        let sensitiveInputs = [
            "share-id-raw-fixture-77",
            "viewer-client-secret-77",
            "https://10.0.0.7:8080/display/secret",
            "10.0.0.7",
            "\(NSHomeDirectory())/Documents/session.txt",
            "Private Window Caption",
            "typed note body",
            "visible desktop sample"
        ]
        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: MockCaptureMonitoringService(),
            sharingService: MockSharingService(),
            virtualDisplayFacade: MockVirtualDisplayFacade(),
            isRunningUnderXCTestOverride: true
        )
        _ = env.displayRuntime.attachConsumer(
            surfaceIdentity: .physicalDisplay(displayID: 777),
            kind: .lanWebView,
            owner: .init(source: .sharingService, redactedLabel: sensitiveInputs.joined(separator: " ")),
            demand: runtimeLeaseRedactionDemand()
        )

        await env.waitForStartupObservability()
        await env.observability.refreshSnapshot(reason: .manualDiagnosticsRefresh)

        let runtimeJSON = String(
            decoding: try JSONEncoder().encode(env.displayRuntime.makeSnapshot()),
            as: UTF8.self
        )
        let diagnostics = await env.observability.diagnosticsSnapshot()
        let diagnosticsJSON = String(
            decoding: try JSONEncoder().encode(diagnostics.state),
            as: UTF8.self
        )
        let bundleURL = try await env.observability.exportBundle(
            draft: FeedbackDraft(happened: "Runtime lease diagnostics"),
            consent: FeedbackConsent()
        )
        let entries = try supportBundleEntries(archiveURL: bundleURL)
        let manifestJSON = try supportBundleEntryString(
            archiveURL: bundleURL,
            relativePathSuffix: "/manifest.json"
        )
        let manifest = try supportBundleEntry(
            SupportBundleManifest.self,
            archiveURL: bundleURL,
            relativePathSuffix: "/manifest.json"
        )
        let bundleState = try supportBundleEntry(
            ObservabilityStateSnapshot.self,
            archiveURL: bundleURL,
            relativePathSuffix: "/state/current-state.json"
        )
        let bundleStateJSON = try supportBundleEntryString(
            archiveURL: bundleURL,
            relativePathSuffix: "/state/current-state.json"
        )
        let bundleTextContents = try supportBundleTextContents(archiveURL: bundleURL)
        let bundleRuntimeSection = try #require(bundleState.sections["runtime"])
        let bundleRuntime = try bundleRuntimeSection.decode(DisplayRuntimeSnapshot.self)

        #expect(entries.contains(where: { $0.hasSuffix("/manifest.json") }))
        #expect(entries.contains(where: { $0.hasSuffix("/feedback.json") }))
        #expect(entries.contains(where: { $0.hasSuffix("/state/current-state.json") }))
        #expect(entries.contains(where: { $0.hasSuffix("/state/health-summary.json") }))
        #expect(entries.contains(where: { $0.hasSuffix("/events/recent-events.ndjson") }))
        #expect(entries.contains(where: { $0.hasSuffix("/issues/recent-issues.json") }))
        #expect(entries.contains(where: { $0.contains("/attachments/") }) == false)
        #expect(manifest.attachments.isEmpty)
        #expect(manifest.consent == FeedbackConsent())
        #expect(manifest.consent.hasEnhancedCollection == false)
        #expect(manifest.consent.includeUnifiedLogSummary == false)
        #expect(manifest.consent.includeCrashReportExcerpt == false)
        #expect(manifest.consent.includeRelatedConfigSnapshots == false)
        #expect(bundleRuntime.schemaVersion == 3)
        #expect(bundleRuntime.consumerLeases.first?.ownerSource == .sharingService)
        #expect(bundleRuntime.aggregatedDemands.first?.activeViewerCount == 1)
        for sensitiveInput in sensitiveInputs {
            #expect(runtimeJSON.contains(sensitiveInput) == false)
            #expect(diagnosticsJSON.contains(sensitiveInput) == false)
            #expect(manifestJSON.contains(sensitiveInput) == false)
            #expect(bundleStateJSON.contains(sensitiveInput) == false)
            #expect(bundleTextContents.allSatisfy { $0.contains(sensitiveInput) == false })
        }
    }

    @Test func initCapturePreviewDiagnosticsScenarioBuildsMonitoringSessionFromRuntimeConfiguration() async throws {
        let overrides = [
            (UITestRuntime.modeEnvironmentKey, "1"),
            (UITestRuntime.scenarioEnvironmentKey, UITestScenario.capturePreviewDiagnostics.rawValue),
            (CapturePreviewDiagnosticsRuntime.sourceSizeEnvironmentKey, "3008x1692")
        ]
        let previousValues = overrides.map { ($0.0, ProcessInfo.processInfo.environment[$0.0]) }
        for (key, value) in overrides {
            setenv(key, value, 1)
        }
        defer {
            for (key, previousValue) in previousValues {
                if let previousValue {
                    setenv(key, previousValue, 1)
                } else {
                    unsetenv(key)
                }
            }
        }

        let env = AppBootstrap.makeEnvironment()

        let session = try #require(env.capture.screenCaptureSessions.first)
        #expect(env.capture.screenCaptureSessions.count == 1)
        #expect(session.displayName == "Preview Diagnostics")
        #expect(session.resolutionText == "3008 × 1692")
        #expect(session.capturesCursor == false)
        #expect(env.virtualDisplay.displayConfigs.count == 2)
    }

    @Test func previewEnvironmentDoesNotPersistPreferredPortToStandardDefaults() async {
        let requestedPort = TestPortAllocator.randomUnprivilegedPort()
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()
        sharing.startResult = .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort))

        let defaults = UserDefaults.standard
        let key = "sharing.preferredPort"
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )

        let startResult = await env.sharing.startWebService(requestedPort: requestedPort)

        #expect(startResult == .started(WebServiceBinding(requestedPort: requestedPort, boundPort: requestedPort)))
        let currentValue = defaults.object(forKey: key)
        let valuesMatch: Bool
        if let previousObject = previousValue as? NSObject,
           let currentObject = currentValue as? NSObject {
            valuesMatch = previousObject.isEqual(currentObject)
        } else {
            valuesMatch = previousValue == nil && currentValue == nil
        }
        #expect(valuesMatch)
    }

    @Test func initPreviewModeSkipsStartupSequence() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let env = AppBootstrap.makeEnvironment(
            preview: true,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )
        await env.waitForStartupObservability()

        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
        #expect(virtualDisplay.startupRestoreCommandRequests.isEmpty)
        #expect(sharing.startWebServiceCallCount == 0)
    }

    @Test func initUITestModeAppliesFixtureAndSkipsServiceBoot() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = UITestVirtualDisplayFacade(scenario: .baseline)

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            startupPlan: .init(
                shouldRestoreVirtualDisplays: true
            ),
            isRunningUnderXCTestOverride: false
        )

        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.virtualDisplay.displayConfigs.count == 2)
        #expect(sut.virtualDisplay.runningConfigIds.count == 1)
    }

    @Test func initRunningUnderXCTestSkipsStartupSequence() async {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: true
        )

        #expect(virtualDisplay.loadPersistedConfigsCallCount == 0)
        #expect(virtualDisplay.startupRestoreCommandRequests.isEmpty)
        #expect(sharing.startWebServiceCallCount == 0)
        #expect(sut.virtualDisplay.displayConfigs.isEmpty)
    }

    @Test func initNormalModeRestoresStartupVirtualDisplaysThroughRuntimeWithoutStartingWebService() async throws {
        let sharing = MockSharingService()
        let capture = MockCaptureMonitoringService()
        let virtualDisplay = MockVirtualDisplayFacade()

        let fixtureConfig = VirtualDisplayConfig(
            displayName: "Fixture",
            serialNum: 1,
            physicalWidth: 300,
            physicalHeight: 200,
            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
            desiredEnabled: true
        )
        virtualDisplay.currentDisplayConfigs = [fixtureConfig]
        virtualDisplay.runtimeDisplayIDByConfigId[fixtureConfig.id] = 10_001

        let sut = AppBootstrap.makeEnvironment(
            preview: false,
            captureMonitoringService: capture,
            sharingService: sharing,
            virtualDisplayFacade: virtualDisplay,
            isRunningUnderXCTestOverride: false
        )
        await sut.waitForStartupObservability()
        let startupTrace = try #require(
            sut.displayRuntime.makeSnapshot().transactions.recentTransactions.first {
                $0.kind == .virtualDisplayStartupRestore
            }
        )

        #expect(sharing.startWebServiceCallCount == 0)
        #expect(virtualDisplay.loadPersistedConfigsCallCount == 1)
        #expect(virtualDisplay.startupRestoreCommandRequests.map(\.configID) == [fixtureConfig.id])
        #expect(startupTrace.source == .startup)
        #expect(sut.virtualDisplay.displayConfigs.count == 1)
        #expect(sut.virtualDisplay.displayConfigs.first?.id == fixtureConfig.id)
        #expect(sut.virtualDisplay.displayConfigs.first?.serialNum == fixtureConfig.serialNum)
    }
}

private func runtimeLeaseRedactionDemand() -> DisplayRuntimeConsumerDemand {
    DisplayRuntimeConsumerDemand(
        sourcePixelSize: .init(width: 3840, height: 2160),
        preferredPixelSize: .init(width: 1920, height: 1080),
        sourceFramesPerSecond: 60,
        preferredFramesPerSecond: 30,
        capturesCursor: true,
        powerProfile: .smooth,
        latencyPreference: .realtime,
        activeViewerCount: 1
    )
}

private func supportBundleEntryString(
    archiveURL: URL,
    relativePathSuffix: String
) throws -> String {
    String(decoding: try supportBundleEntryData(archiveURL: archiveURL, relativePathSuffix: relativePathSuffix), as: UTF8.self)
}

private func supportBundleEntry<T: Decodable>(
    _ type: T.Type,
    archiveURL: URL,
    relativePathSuffix: String
) throws -> T {
    try ObservabilityCodec.decode(
        type,
        from: supportBundleEntryData(archiveURL: archiveURL, relativePathSuffix: relativePathSuffix)
    )
}

private func supportBundleEntryData(
    archiveURL: URL,
    relativePathSuffix: String
) throws -> Data {
    let extractionURL = try makeTemporaryDirectory(prefix: "app-bootstrap-support-bundle")
    defer { try? FileManager.default.removeItem(at: extractionURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", archiveURL.path, extractionURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let bundleRoot = try #require(
        FileManager.default.contentsOfDirectory(
            at: extractionURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first
    )
    let entryURL = bundleRoot.appendingPathComponent(String(relativePathSuffix.dropFirst()))
    return try Data(contentsOf: entryURL)
}

private func supportBundleEntries(archiveURL: URL) throws -> [String] {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    process.arguments = ["-Z1", archiveURL.path]
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(decoding: data, as: UTF8.self)
    return output.split(whereSeparator: \.isNewline).map(String.init)
}

private func supportBundleTextContents(archiveURL: URL) throws -> [String] {
    let extractionURL = try makeTemporaryDirectory(prefix: "app-bootstrap-support-bundle-contents")
    defer { try? FileManager.default.removeItem(at: extractionURL) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
    process.arguments = ["-x", "-k", archiveURL.path, extractionURL.path]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let bundleRoot = try #require(
        FileManager.default.contentsOfDirectory(
            at: extractionURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).first
    )
    let enumerator = FileManager.default.enumerator(
        at: bundleRoot,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )
    var contents: [String] = []
    while let fileURL = enumerator?.nextObject() as? URL {
        let isDirectory = (try? fileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard !isDirectory,
              let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            continue
        }
        contents.append(content)
    }
    return contents
}
