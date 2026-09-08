@testable import VoidDisplayApp
@testable import VoidDisplayCapture
@testable import VoidDisplayRuntime
@testable import VoidDisplaySharing
@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayTestingSupport
@testable import VoidDisplayVirtualDisplay
@testable import VoidDisplayVirtualDisplayTestingSupport
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeAdapterTests {
    @Test(arguments: [false, true])
    func virtualDisplayPixelBoundsRemainConsistentInRuntimeDiagnostics(reverseModes: Bool) async throws {
        let scenarios: [([VirtualDisplayConfig.ModeConfig], UInt32, UInt32)] = [
            ([.init(width: 5120, height: 2880, refreshRate: 60, enableHiDPI: false),
              .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)], 5120, 2880),
            ([.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false),
              .init(width: 1080, height: 1920, refreshRate: 60, enableHiDPI: false)], 1920, 1920),
            ([.init(width: 3000, height: 1000, refreshRate: 60, enableHiDPI: false),
              .init(width: 1000, height: 2000, refreshRate: 60, enableHiDPI: true)], 3000, 4000),
            ([.init(width: 4096, height: 4096, refreshRate: 60, enableHiDPI: true)], 8192, 8192)
        ]
        for (modes, width, height) in scenarios {
            let config = VirtualDisplayConfig(
                displayName: "Diagnostic Bounds", serialNum: 9401, physicalWidth: 600, physicalHeight: 340,
                modes: reverseModes ? Array(modes.reversed()) : modes
            )
            let facade = MockVirtualDisplayFacade()
            facade.currentDisplayConfigs = [config]
            let adapter = DisplayRuntimeVirtualDisplayAdapter(commandFacade: facade)
            let runtime = DisplayRuntime(
                virtualDisplayProvider: adapter,
                virtualDisplayCommander: adapter,
                topologyWaitPolicy: .init(maximumSampleCount: 1, sampleIntervalNanoseconds: 0)
            )
            var edited = config
            edited.displayName = "Renamed Diagnostic Bounds"
            let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
                request: .init(
                    editedConfig: DisplayRuntimeVirtualDisplayConfigEditDTO(adapterConfig: edited),
                    expectedConfigFingerprint: config.editRebuildFingerprint,
                    source: .editSaveAndRebuild
                ),
                source: .editSaveAndRebuild
            )
            let saveGate = try await handle.waitForSaveGate()
            _ = try await handle.waitForTerminalResult()
            // Exercise the same provider and JSON representation exported in support bundles.
            let data = try ObservabilityCodec.encode(DisplayRuntimeSnapshotProvider(runtime: runtime).makeSnapshot())
            let snapshot = try ObservabilityCodec.decode(DisplayRuntimeSnapshot.self, from: data)
            let surface = try #require(snapshot.surfaces.first?.managedVirtualDisplay)
            let trace = try #require(snapshot.transactions.recentTransactions.first)
            let oldEvidence = try #require(trace.oldConfigEvidence)
            let editedEvidence = try #require(trace.editedConfigEvidence)
            let savedEvidence = try #require(trace.savedConfigEvidence)
            let snapshotEvidence = DisplayRuntimeVirtualDisplayConfigEvidence(
                snapshotConfig: try #require(snapshot.virtualDisplay.configs.first)
            )

            #expect(config.maxPixelDimensions.width == width)
            #expect(config.maxPixelDimensions.height == height)
            #expect(surface.maximumPixelWidth == Int(width))
            #expect(surface.maximumPixelHeight == Int(height))
            #expect(oldEvidence == editedEvidence)
            #expect(snapshotEvidence == savedEvidence)
            #expect(savedEvidence == saveGate.savedConfigEvidence)
            #expect(savedEvidence.maximumPixelWidth == width)
            #expect(savedEvidence.maximumPixelHeight == height)
            #expect(facade.saveConfigForRebuildCallCount == 1)
            #expect(facade.rebuildVirtualDisplayCallCount == 1)
        }
    }

    @Test func catalogAdapterReturnsOnlyCurrentVisibleDisplayDTOsInRefreshSettlement() async {
        let hiddenDisplay = SharedMockSCDisplay.make(displayID: 8101, width: 1920, height: 1080)
        let visibleDisplay = SharedMockSCDisplay.make(displayID: 8102, width: 2560, height: 1440)
        let service = ScreenCaptureCatalogService(
            permissionProvider: MockScreenCapturePermissionProvider(preflightResult: true, requestResult: true),
            loadShareableDisplays: { [hiddenDisplay, visibleDisplay] },
            activeDisplayIDsProvider: { [visibleDisplay.displayID] }
        )
        let sut = DisplayRuntimeCatalogAdapter(service: service)

        let outcome = await sut.submitRefresh(intent: .userForcedRefresh)

        #expect(outcome.catalog.loadedDisplays == [
            .init(displayID: visibleDisplay.displayID, pixelWidth: 2560, pixelHeight: 1440)
        ])
    }

    @Test func captureIntentAdapterUnavailableFailsExplicitly() async {
        var controller: CaptureController? = CaptureController(
            capturePreviewService: MockCapturePreviewService()
        )
        let sut = DisplayRuntimeCaptureAdapter(controller: controller!)
        controller = nil

        let result = await sut.applyPreviewCaptureIntent(
            DisplayRuntimeCaptureIntent(
                surfaceIdentity: .physicalDisplay(displayID: 8401),
                surfaceEpoch: .initial,
                resolvedDisplayID: 8401,
                aggregateDemand: nil,
                kind: .capture,
                reason: .attach,
                revision: .init(rawValue: 1)
            )
        )

        #expect(result.outcome == .failed)
        #expect(result.revision.rawValue == 1)
        #expect(result.failureCode == DisplayRuntimeCaptureIntentFailureCode.adapterUnavailable)
    }

    @Test func previewStartAndStopResolveManagedVirtualDisplaySurface() async throws {
        let configID = UUID(uuidString: "13131313-1313-1313-1313-131313131313")!
        let display = SharedMockSCDisplay.make(displayID: 8416, width: 3008, height: 1692)
        let harness = previewHarness(
            display: display,
            virtualDisplaySnapshot: managedVirtualDisplaySnapshot(
                configID: configID,
                displayID: display.displayID
            )
        )
        let actions = CaptureUIComposition.previewActions(
            capture: harness.controller,
            displayRuntime: harness.runtime,
            capturePerformancePreferences: adapterTestPerformancePreferences(mode: .powerEfficient)
        )

        let outcome = try await actions.startPreview(
            display,
            CapturePreviewDisplayMetadata(
                displayName: "Preview Adapter",
                resolutionText: "3008 x 1692",
                isVirtualDisplay: true
            )
        )

        guard case .started(let previewID) = outcome else {
            Issue.record("Expected managed virtual preview start to succeed.")
            return
        }
        let surfaceIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let attachedLease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let captureIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(harness.capturePreviewService.addCallCount == 1)
        #expect(actions.previewSession(previewID)?.displayID == display.displayID)
        #expect(attachedLease.surfaceIdentity == surfaceIdentity)
        #expect(attachedLease.resolvedDisplayID == display.displayID)
        #expect(attachedLease.demand.powerProfile == .powerEfficient)
        #expect(captureIntent.intent.surfaceIdentity == surfaceIdentity)
        #expect(captureIntent.intent.resolvedDisplayID == display.displayID)
        #expect(captureIntent.lastApplyResult?.outcome == .applied)

        await actions.closePreview(previewID)

        let releasedLease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let drainIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(releasedLease.surfaceIdentity == surfaceIdentity)
        #expect(releasedLease.state == .released)
        #expect(harness.runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(drainIntent.intent.surfaceIdentity == surfaceIdentity)
        #expect(drainIntent.intent.kind == .drain)
        #expect(drainIntent.lastApplyResult?.outcome == .applied)
        #expect(harness.capturePreviewService.removeByDisplayCallCount == 1)
        #expect(harness.controller.screenPreviewSessions.isEmpty)
    }

    @Test func previewIDSurvivesCaptureSessionReplacementAndResolvesNewDisplay() async throws {
        let configID = UUID(uuidString: "14141414-1414-1414-1414-141414141415")!
        let firstDisplay = SharedMockSCDisplay.make(displayID: 8417, width: 1920, height: 1080)
        let replacementDisplay = SharedMockSCDisplay.make(displayID: 8418, width: 2560, height: 1440)
        let harness = previewHarness(
            display: firstDisplay,
            activeDisplayIDs: [firstDisplay.displayID, replacementDisplay.displayID],
            virtualDisplaySnapshot: managedVirtualDisplaySnapshot(
                configID: configID,
                displayID: firstDisplay.displayID
            )
        )
        let actions = CaptureUIComposition.previewActions(
            capture: harness.controller,
            displayRuntime: harness.runtime,
            capturePerformancePreferences: adapterTestPerformancePreferences()
        )
        let outcome = try await actions.startPreview(
            firstDisplay,
            CapturePreviewDisplayMetadata(
                displayName: "Stable Preview",
                resolutionText: "1920 × 1080",
                isVirtualDisplay: true
            )
        )
        guard case let .started(previewID) = outcome else {
            Issue.record("Expected preview to start")
            return
        }
        let firstSessionID = try #require(actions.previewSession(previewID)?.id)
        let virtualDisplayProvider = try #require(harness.virtualDisplayProvider)

        virtualDisplayProvider.setSnapshot(
            managedVirtualDisplaySnapshot(configID: configID, displayID: replacementDisplay.displayID)
        )
        harness.catalogService.store.displays = [replacementDisplay]
        harness.controller.removePreviewSessions(displayID: firstDisplay.displayID)
        _ = harness.runtime.advanceSurfaceEpoch(
            surfaceIdentity: .managedVirtualDisplay(configID: configID)
        )

        let restoredState = await actions.retryPreview(previewID)
        let replacementSession = try #require(actions.previewSession(previewID))

        #expect(restoredState == .active)
        #expect(replacementSession.id != firstSessionID)
        #expect(replacementSession.displayID == replacementDisplay.displayID)
        #expect(actions.previewIDForDisplayID(replacementDisplay.displayID) == previewID)
        #expect(harness.runtime.consumerLease(
            leaseID: .init(rawValue: previewID.rawValue)
        )?.resolvedDisplayID == replacementDisplay.displayID)
    }

    @Test func lanWebViewStartAttachesRuntimeLeaseAndStartsSharingThroughIntent() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8421, width: 3840, height: 2160)
        let capturePerformancePreferences = adapterTestPerformancePreferences(mode: .powerEfficient)
        let harness = lanWebViewHarness(
            display: display,
            capturePerformancePreferences: capturePerformancePreferences
        )
        let outcome = try await harness.sharingAdapter.beginLANWebViewSharing(
            display: display,
            runtime: harness.runtime
        )

        guard case .started = outcome else {
            Issue.record("Expected LAN Web View sharing start to succeed.")
            return
        }
        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(harness.sharingService.startSharingCallCount == 1)
        #expect(harness.sharingService.startedSharingDisplayIDs == [display.displayID])
        #expect(lease.kind == .lanWebView)
        #expect(lease.state == .attached)
        #expect(lease.demand.sourcePixelSize == .init(width: 3840, height: 2160))
        #expect(lease.demand.activeViewerCount == 0)
        #expect(lease.demand.powerProfile == .powerEfficient)
        #expect(effectiveIntent.intent.kind == .capture)
        #expect(effectiveIntent.intent.reason == .attach)
        #expect(effectiveIntent.intent.aggregateDemand?.consumerKinds == [.lanWebView])
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
    }

    @Test func lanWebViewStartResolvesManagedVirtualDisplaySurface() async throws {
        let configID = UUID(uuidString: "15151515-1515-1515-1515-151515151515")!
        let display = SharedMockSCDisplay.make(displayID: 8422, width: 2560, height: 1440)
        let capturePerformancePreferences = adapterTestPerformancePreferences()
        let harness = lanWebViewHarness(
            display: display,
            capturePerformancePreferences: capturePerformancePreferences,
            virtualDisplaySnapshot: managedVirtualDisplaySnapshot(
                configID: configID,
                displayID: display.displayID
            )
        )
        let outcome = try await harness.sharingAdapter.beginLANWebViewSharing(
            display: display,
            runtime: harness.runtime
        )

        guard case .started = outcome else {
            Issue.record("Expected managed virtual LAN Web View sharing start to succeed.")
            return
        }
        let surfaceIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        let effectiveIntent = try #require(harness.runtime.currentEffectiveCaptureIntentSnapshot().first)
        #expect(lease.surfaceIdentity == surfaceIdentity)
        #expect(lease.resolvedDisplayID == display.displayID)
        #expect(effectiveIntent.intent.surfaceIdentity == surfaceIdentity)
        #expect(effectiveIntent.intent.resolvedDisplayID == display.displayID)
        #expect(effectiveIntent.lastApplyResult?.outcome == .applied)
    }

    @Test func stopAllLANWebViewSharingReleasesRestartingLease() async throws {
        let display = SharedMockSCDisplay.make(displayID: 8423, width: 1920, height: 1080)
        let capturePerformancePreferences = adapterTestPerformancePreferences()
        let harness = lanWebViewHarness(
            display: display,
            capturePerformancePreferences: capturePerformancePreferences
        )
        let adapter = DisplayRuntimeSharingAdapter(
            controller: harness.sharingController,
            capturePerformancePreferences: capturePerformancePreferences
        )
        _ = try await adapter.beginLANWebViewSharing(display: display, runtime: harness.runtime)
        let lease = try #require(harness.runtime.currentConsumerLeaseSnapshot().first)
        _ = harness.runtime.advanceSurfaceEpoch(surfaceIdentity: lease.surfaceIdentity)

        await adapter.stopAllLANWebViewSharing(runtime: harness.runtime)

        #expect(harness.runtime.consumerLease(leaseID: lease.id)?.state == .released)
        #expect(harness.runtime.currentAggregatedDemandSnapshot().isEmpty)
        #expect(harness.sharingService.activeSharingDisplayIDs.isEmpty)
    }

    @Test func virtualDisplayAdapterSnapshotMapsConfigAndManagedDisplayDTOFields() throws {
        let config = VirtualDisplayConfig(
            displayName: "Snapshot Mapping",
            serialNum: 9300,
            physicalWidth: 610,
            physicalHeight: 350,
            modes: [
                .init(width: 2560, height: 1440, refreshRate: 75, enableHiDPI: true),
                .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
            ],
            desiredEnabled: true
        )
        let facade = MockVirtualDisplayFacade()
        facade.currentDisplayConfigs = [config]
        facade.currentRunningConfigIds = [config.id]
        facade.runtimeDisplayIDByConfigId[config.id] = 8300
        let sut = DisplayRuntimeVirtualDisplayAdapter(commandFacade: facade)

        let snapshot = sut.makeVirtualDisplaySnapshot()
        let dto = try #require(snapshot.configs.first)

        #expect(snapshot.runningConfigIDs == [config.id])
        #expect(snapshot.managedDisplays == [
            DisplayRuntimeManagedVirtualDisplay(
                configID: config.id,
                serialNumber: 9300,
                displayID: 8300,
                isLiveRuntime: true
            )
        ])
        #expect(dto.id == config.id)
        #expect(dto.serialNumber == 9300)
        #expect(dto.desiredEnabled)
        #expect(dto.physicalWidthMillimeters == 610)
        #expect(dto.physicalHeightMillimeters == 350)
        #expect(dto.modes == [
            DisplayRuntimeVirtualDisplayMode(
                width: 1920,
                height: 1080,
                refreshRate: 60,
                enableHiDPI: false
            ),
            DisplayRuntimeVirtualDisplayMode(
                width: 2560,
                height: 1440,
                refreshRate: 75,
                enableHiDPI: true
            )
        ])
    }

    @Test func startupRestoreAdapterMapsLowerFailureEvidence() async throws {
        let configID = UUID(uuidString: "14141414-1414-1414-1414-141414141414")!
        let transactionID = DisplayRuntimeTransactionID()
        let facade = MockVirtualDisplayFacade()
        facade.startupRestoreCommandResultsByConfigID[configID] = VirtualDisplayStartupRestoreCommandResult(
            transactionID: transactionID.rawValue,
            configID: configID,
            preDisplayID: nil,
            postDisplayID: nil,
            restoreOutcome: .failed,
            didProduceVerifiableSideEffect: false,
            failureReason: "startup_restore_lower_command_failed",
            underlyingDomain: "CGVirtualDisplay",
            underlyingCode: -7
        )
        let sut = DisplayRuntimeVirtualDisplayAdapter(commandFacade: facade)

        let result = try await sut.restoreVirtualDisplayForStartup(
            request: DisplayRuntimeStartupRestoreCommandRequest(
                transactionID: transactionID,
                runID: .init(),
                configID: configID,
                configEvidence: DisplayRuntimeVirtualDisplayConfigEvidence(
                    id: configID,
                    serialNumber: 14,
                    desiredEnabled: true,
                    physicalWidthMillimeters: 300,
                    physicalHeightMillimeters: 200,
                    modeCount: 1,
                    maximumPixelWidth: 1920,
                    maximumPixelHeight: 1080
                )
            )
        )

        #expect(result.failureReason == "startup_restore_lower_command_failed")
        #expect(result.underlyingDomain == "CGVirtualDisplay")
        #expect(result.underlyingCode == -7)
    }
}

private final class AdapterTestPortPreferences: SharingPortPreferencesProtocol {
    var preferredPort: UInt16 = 8081

    func savePreferredPort(_ port: UInt16) {
        preferredPort = port
    }
}

@MainActor
private func previewHarness(
    display: SCDisplay,
    activeDisplayIDs: Set<CGDirectDisplayID>? = nil,
    virtualDisplaySnapshot: DisplayRuntimeVirtualDisplaySnapshot? = nil
) -> (
    catalogService: ScreenCaptureCatalogService,
    capturePreviewService: MockCapturePreviewService,
    controller: CaptureController,
    runtime: DisplayRuntime,
    virtualDisplayProvider: AdapterTestVirtualDisplayProvider?
) {
    let activeDisplayIDs = activeDisplayIDs ?? [display.displayID]
    let catalogService = ScreenCaptureCatalogService(
        permissionProvider: FailingScreenCapturePermissionProvider(),
        loadShareableDisplays: {
            Issue.record("Preview wiring tests must not load real shareable displays.")
            return [display]
        },
        activeDisplayIDsProvider: { activeDisplayIDs }
    )
    catalogService.store.hasScreenCapturePermission = true
    catalogService.store.lastPreflightPermission = true
    catalogService.store.displays = [display]
    catalogService.store.lastLoadedActiveDisplayTopologySignature =
        catalogService.currentActiveDisplayTopologySignature()

    let capturePreviewService = MockCapturePreviewService()
    let lifecycleService = CapturePreviewLifecycleService(
        capturePreviewService: capturePreviewService,
        acquirePreview: { captureDisplay, _ in
            .started(
                DisplayPreviewSubscription(
                    displayID: captureDisplay.displayID,
                    resolutionText: "\(captureDisplay.width) × \(captureDisplay.height)",
                    session: TestAppDisplayCaptureSession(),
                    cancelClosure: {}
                )
            )
        }
    )
    let controller = CaptureController(
        capturePreviewService: capturePreviewService,
        capturePreviewLifecycleService: lifecycleService,
        catalogService: catalogService
    )
    let adapter = DisplayRuntimeCaptureAdapter(controller: controller)
    let virtualDisplayProvider = virtualDisplaySnapshot.map(AdapterTestVirtualDisplayProvider.init)
    let runtime = DisplayRuntime(
        catalogProvider: DisplayRuntimeCatalogAdapter(service: catalogService),
        captureProvider: adapter,
        virtualDisplayProvider: virtualDisplayProvider,
        captureIntentCommander: adapter
    )
    return (
        catalogService: catalogService,
        capturePreviewService: capturePreviewService,
        controller: controller,
        runtime: runtime,
        virtualDisplayProvider: virtualDisplayProvider
    )
}

private final class AdapterTestVirtualDisplayProvider: DisplayRuntimeVirtualDisplayProviding {
    private var snapshot: DisplayRuntimeVirtualDisplaySnapshot

    init(snapshot: DisplayRuntimeVirtualDisplaySnapshot) {
        self.snapshot = snapshot
    }

    func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        snapshot
    }

    func setSnapshot(_ snapshot: DisplayRuntimeVirtualDisplaySnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
private func lanWebViewHarness(
    display: SCDisplay,
    capturePerformancePreferences: CapturePerformancePreferences,
    virtualDisplaySnapshot: DisplayRuntimeVirtualDisplaySnapshot? = nil
) -> (
    catalogService: ScreenCaptureCatalogService,
    sharingService: MockSharingService,
    sharingController: SharingController,
    sharingAdapter: DisplayRuntimeSharingAdapter,
    captureController: CaptureController,
    captureAdapter: DisplayRuntimeCaptureAdapter,
    runtime: DisplayRuntime
) {
    let catalogService = ScreenCaptureCatalogService(
        permissionProvider: FailingScreenCapturePermissionProvider(),
        loadShareableDisplays: {
            Issue.record("LAN Web View runtime tests must not load real shareable displays.")
            return [display]
        },
        activeDisplayIDsProvider: { [display.displayID] }
    )
    catalogService.store.hasScreenCapturePermission = true
    catalogService.store.lastPreflightPermission = true
    catalogService.store.displays = [display]
    catalogService.store.lastLoadedActiveDisplayTopologySignature =
        catalogService.currentActiveDisplayTopologySignature()

    let target = ShareTarget.id(9400 + UInt32(display.displayID % 100))
    let sharingService = MockSharingService()
    sharingService.isWebServiceRunning = true
    sharingService.webServiceLifecycleState = .running(
        WebServiceBinding(requestedPort: 8081, boundPort: 8081)
    )
    if case .id(let shareID) = target {
        sharingService.shareIDByDisplayID[display.displayID] = shareID
    }
    sharingService.shareTargetByDisplayID[display.displayID] = target

    let sharingController = SharingController(
        sharingService: sharingService,
        portPreferences: AdapterTestPortPreferences(),
        catalogService: catalogService
    )
    let captureController = CaptureController(
        capturePreviewService: MockCapturePreviewService(),
        catalogService: catalogService
    )
    let sharingAdapter = DisplayRuntimeSharingAdapter(
        controller: sharingController,
        capturePerformancePreferences: capturePerformancePreferences
    )
    let captureAdapter = DisplayRuntimeCaptureAdapter(
        controller: captureController,
        sharingController: sharingController
    )
    let runtime = DisplayRuntime(
        catalogProvider: DisplayRuntimeCatalogAdapter(service: catalogService),
        captureProvider: captureAdapter,
        sharingProvider: sharingAdapter,
        virtualDisplayProvider: virtualDisplaySnapshot.map(AdapterTestVirtualDisplayProvider.init),
        sharingCommander: sharingAdapter,
        captureIntentCommander: captureAdapter
    )
    sharingAdapter.configureLANWebViewDemandSync(runtime: runtime)
    return (
        catalogService: catalogService,
        sharingService: sharingService,
        sharingController: sharingController,
        sharingAdapter: sharingAdapter,
        captureController: captureController,
        captureAdapter: captureAdapter,
        runtime: runtime
    )
}

@MainActor
private func adapterTestPerformancePreferences(
    mode: CapturePerformanceMode = .automatic
) -> CapturePerformancePreferences {
    let suiteName = "DisplayRuntimeAdapterTests.performance.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(mode.rawValue, forKey: CapturePerformancePreferenceKeys.mode)
    return CapturePerformancePreferences(defaults: defaults)
}

private func managedVirtualDisplaySnapshot(
    configID: UUID,
    displayID: DisplayRuntimeDisplayID
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        runningConfigIDs: [configID],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: [
            .init(configID: configID, serialNumber: 9416, displayID: displayID, isLiveRuntime: true)
        ],
        configs: [
            .init(
                id: configID,
                serialNumber: 9416,
                desiredEnabled: true,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1504, height: 846, refreshRate: 60, enableHiDPI: true)],
                maximumPixelWidth: 3008,
                maximumPixelHeight: 1692
            )
        ],
        restoreFailureConfigIDs: []
    )
}

private struct FailingScreenCapturePermissionProvider: ScreenCapturePermissionProvider {
    nonisolated func preflight() -> Bool {
        Issue.record("Adapter tests must not preflight screen capture permission.")
        return false
    }

    nonisolated func request() -> Bool {
        Issue.record("Adapter tests must not request screen capture permission.")
        return false
    }
}
