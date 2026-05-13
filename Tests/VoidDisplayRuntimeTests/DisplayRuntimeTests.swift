@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeTests {
    @Test func managedVirtualDisplayIdentityUsesConfigID() {
        let configID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: .init(
                    rebuildRequestCount: 1,
                    rebuildingConfigIDs: [configID],
                    runningConfigIDs: [configID],
                    recentlyAppliedConfigIDs: [],
                    rebuildFailureConfigIDs: [],
                    configStoreHasLoadFailure: false,
                    configStoreHasDiagnostics: false,
                    managedDisplays: [
                        .init(configID: configID, serialNumber: 9001, displayID: 77, isLiveRuntime: true)
                    ],
                    configs: [
                        .init(
                            id: configID,
                            serialNumber: 9001,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)]
                        )
                    ],
                    restoreFailureConfigIDs: []
                )
            )
        )

        let snapshot = runtime.makeSnapshot()
        let surface = snapshot.surfaces.first

        #expect(surface?.identity == .managedVirtualDisplay(configID: configID))
        #expect(surface?.identity.stableID == configID.uuidString)
        #expect(surface?.currentDisplayID == 77)
        #expect(surface?.isAuxiliary == false)
        #expect(surface?.managedVirtualDisplay?.isRunning == true)
        #expect(surface?.managedVirtualDisplay?.isRebuilding == true)
        #expect(surface?.managedVirtualDisplay?.maximumPixelWidth == 3840)
        #expect(surface?.managedVirtualDisplay?.maximumPixelHeight == 2160)
    }

    @Test func physicalDisplayIsAuxiliarySurface() {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [.init(displayID: 200, pixelWidth: 2560, pixelHeight: 1440)],
                    topologySignature: [
                        .init(
                            displayID: 200,
                            isMain: true,
                            pixelWidth: 2560,
                            pixelHeight: 1440,
                            refreshRateMilliHertz: 60_000,
                            mirrorsDisplayID: nil
                        )
                    ]
                )
            )
        )

        let surface = runtime.makeSnapshot().surfaces.first

        #expect(surface?.identity == .physicalDisplay(displayID: 200))
        #expect(surface?.kind == .physicalDisplay)
        #expect(surface?.isAuxiliary == true)
        #expect(surface?.catalog?.pixelWidth == 2560)
        #expect(surface?.catalog?.isMain == true)
    }

    @Test func shareRouteDoesNotBecomeSurfaceIdentity() {
        let runtime = DisplayRuntime(
            sharingProvider: FakeSharingProvider(
                snapshot: .init(
                    activeSharingDisplayIDs: [77],
                    startingDisplayIDs: [],
                    isSharing: true,
                    isWebServiceRunning: true,
                    preferredPort: 8089,
                    sharingClientCount: 2,
                    sharingClientCounts: [.init(displayID: 77, count: 2)],
                    lifecycle: .init(
                        phase: .running,
                        requestedPort: 8089,
                        boundPort: 8089,
                        failureReason: nil,
                        hasFailureMessage: false
                    ),
                    routes: [.init(displayID: 77, hasConcreteRoute: true)]
                )
            )
        )

        let surface = runtime.makeSnapshot().surfaces.first

        #expect(surface?.identity == .physicalDisplay(displayID: 77))
        #expect(surface?.sharing?.hasRoute == true)
        #expect(surface?.sharing?.viewerCount == 2)
    }

    @Test func runtimeSnapshotAggregatesPortStatesDeterministically() {
        let configID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let sessionID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: true,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [
                        .init(displayID: 200, pixelWidth: 2560, pixelHeight: 1440),
                        .init(displayID: 77, pixelWidth: 3840, pixelHeight: 2160)
                    ],
                    topologySignature: []
                )
            ),
            captureProvider: FakeCaptureProvider(
                snapshot: .init(
                    startingDisplayIDs: [200],
                    sessions: [
                        .init(
                            id: sessionID,
                            displayID: 77,
                            isVirtualDisplay: true,
                            capturesCursor: true,
                            state: .active,
                            metrics: .init(
                                currentProfile: "quality",
                                currentFrameRateTier: "60fps",
                                receivedFrameCount: 42,
                                profileReconfigurationCount: 1,
                                cursorOverrideReconfigurationCount: 2
                            )
                        )
                    ]
                )
            ),
            sharingProvider: FakeSharingProvider(
                snapshot: .init(
                    activeSharingDisplayIDs: [77],
                    startingDisplayIDs: [],
                    isSharing: true,
                    isWebServiceRunning: true,
                    preferredPort: 8089,
                    sharingClientCount: 1,
                    sharingClientCounts: [.init(displayID: 77, count: 1)],
                    lifecycle: .init(
                        phase: .running,
                        requestedPort: 8089,
                        boundPort: 8089,
                        failureReason: nil,
                        hasFailureMessage: false
                    ),
                    routes: [.init(displayID: 77, hasConcreteRoute: true)]
                )
            ),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: .init(
                    rebuildRequestCount: 0,
                    rebuildingConfigIDs: [],
                    runningConfigIDs: [configID],
                    recentlyAppliedConfigIDs: [configID],
                    rebuildFailureConfigIDs: [],
                    configStoreHasLoadFailure: false,
                    configStoreHasDiagnostics: false,
                    managedDisplays: [
                        .init(configID: configID, serialNumber: 9002, displayID: 77, isLiveRuntime: true)
                    ],
                    configs: [
                        .init(
                            id: configID,
                            serialNumber: 9002,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: true)]
                        )
                    ],
                    restoreFailureConfigIDs: []
                )
            )
        )

        let snapshot = runtime.makeSnapshot()

        #expect(snapshot.surfaces.map(\.identity) == [
            .managedVirtualDisplay(configID: configID),
            .physicalDisplay(displayID: 200)
        ])
        #expect(snapshot.surfaces.first?.capture?.sessionIDs == [sessionID])
        #expect(snapshot.surfaces.first?.capture?.receivedFrameCount == 42)
        #expect(snapshot.surfaces.first?.sharing?.viewerCount == 1)
        #expect(snapshot.surfaces.last?.capture?.isStarting == true)
    }

    @Test func surfacesAreSortedByKindAndIdentity() {
        let firstConfigID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondConfigID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [
                        .init(displayID: 20, pixelWidth: 1920, pixelHeight: 1080),
                        .init(displayID: 10, pixelWidth: 1920, pixelHeight: 1080)
                    ],
                    topologySignature: []
                )
            ),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: .init(
                    rebuildRequestCount: 0,
                    rebuildingConfigIDs: [],
                    runningConfigIDs: [],
                    recentlyAppliedConfigIDs: [],
                    rebuildFailureConfigIDs: [],
                    configStoreHasLoadFailure: false,
                    configStoreHasDiagnostics: false,
                    managedDisplays: [],
                    configs: [
                        .init(
                            id: secondConfigID,
                            serialNumber: 9002,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: []
                        ),
                        .init(
                            id: firstConfigID,
                            serialNumber: 9001,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: []
                        )
                    ],
                    restoreFailureConfigIDs: []
                )
            )
        )

        #expect(runtime.makeSnapshot().surfaces.map(\.identity) == [
            .managedVirtualDisplay(configID: firstConfigID),
            .managedVirtualDisplay(configID: secondConfigID),
            .physicalDisplay(displayID: 10),
            .physicalDisplay(displayID: 20)
        ])
    }

    @Test func unavailableProvidersProduceEmptySnapshot() {
        let snapshot = DisplayRuntime().makeSnapshot()

        #expect(snapshot.schemaVersion == 2)
        #expect(snapshot.surfaces.isEmpty)
        #expect(snapshot.catalog == .empty)
        #expect(snapshot.capture == .empty)
        #expect(snapshot.sharing == .empty)
        #expect(snapshot.virtualDisplay == .empty)
        #expect(snapshot.transactions == .empty)
    }

    @Test func duplicatePortEntriesConvergeWithoutDroppingSnapshot() throws {
        let configID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [
                        .init(displayID: 77, pixelWidth: 1920, pixelHeight: 1080),
                        .init(displayID: 77, pixelWidth: 1920, pixelHeight: 1080)
                    ],
                    topologySignature: [
                        .init(
                            displayID: 77,
                            isMain: false,
                            pixelWidth: 1920,
                            pixelHeight: 1080,
                            refreshRateMilliHertz: 60_000,
                            mirrorsDisplayID: nil
                        ),
                        .init(
                            displayID: 77,
                            isMain: false,
                            pixelWidth: 1920,
                            pixelHeight: 1080,
                            refreshRateMilliHertz: 60_000,
                            mirrorsDisplayID: nil
                        )
                    ]
                )
            ),
            sharingProvider: FakeSharingProvider(
                snapshot: .init(
                    activeSharingDisplayIDs: [77],
                    startingDisplayIDs: [],
                    isSharing: true,
                    isWebServiceRunning: true,
                    preferredPort: 8089,
                    sharingClientCount: 3,
                    sharingClientCounts: [
                        .init(displayID: 77, count: 1),
                        .init(displayID: 77, count: 2)
                    ],
                    lifecycle: .init(
                        phase: .running,
                        requestedPort: 8089,
                        boundPort: 8089,
                        failureReason: nil,
                        hasFailureMessage: false
                    ),
                    routes: [.init(displayID: 77, hasConcreteRoute: true)]
                )
            ),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: .init(
                    rebuildRequestCount: 0,
                    rebuildingConfigIDs: [],
                    runningConfigIDs: [configID],
                    recentlyAppliedConfigIDs: [],
                    rebuildFailureConfigIDs: [],
                    configStoreHasLoadFailure: false,
                    configStoreHasDiagnostics: false,
                    managedDisplays: [
                        .init(configID: configID, serialNumber: 9004, displayID: 77, isLiveRuntime: true),
                        .init(configID: configID, serialNumber: 9004, displayID: 77, isLiveRuntime: true)
                    ],
                    configs: [
                        .init(
                            id: configID,
                            serialNumber: 9004,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
                        ),
                        .init(
                            id: configID,
                            serialNumber: 9004,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
                        )
                    ],
                    restoreFailureConfigIDs: []
                )
            )
        )

        let snapshot = runtime.makeSnapshot()
        let surface = try #require(snapshot.surfaces.first)

        #expect(snapshot.surfaces.count == 1)
        #expect(surface.identity == .managedVirtualDisplay(configID: configID))
        #expect(surface.sharing?.viewerCount == 3)
        #expect(surface.catalog?.pixelWidth == 1920)
    }

    @Test func rebuildTransactionQuiescesSessionsBeforeVirtualDisplayCommand() async throws {
        let configID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let sessionID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let recorder = RuntimeOperationRecorder()
        let catalog = catalogSnapshot(displayID: 77, isMain: false)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            captureProvider: FakeCaptureProvider(
                snapshot: .init(
                    startingDisplayIDs: [],
                    sessions: [
                        .init(
                            id: sessionID,
                            displayID: 77,
                            isVirtualDisplay: true,
                            capturesCursor: true,
                            state: .active,
                            metrics: .empty
                        )
                    ]
                )
            ),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 77)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 77)),
            catalogCommander: FakeCatalogCommander(
                recorder: recorder,
                visibleDisplays: visibleDisplays(from: catalog)
            ),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: FakeVirtualDisplayCommander(recorder: recorder),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .virtualDisplayRowRetry)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(result.hasSessionRecoveryFailures)
        #expect(recorder.events == [
            "refresh:topologyChanged",
            "stopSharing:77",
            "removeMonitoring:77",
            "rebuild:\(configID.uuidString)",
            "refresh:topologyChanged",
            "refresh:topologyChanged",
            "registerShareable:77",
            "restoreSharing:77"
        ])
        #expect(trace.phases.contains(.init(phase: .waitingForTopology)))
        #expect(trace.phases.contains(.init(phase: .restoringSessions)))
        #expect(trace.topologyStabilityResult?.status == .stable)
        #expect(trace.preSnapshotEvidence?.captureSessions.map(\.id) == [sessionID])
        #expect(trace.preSnapshotEvidence?.sharingDisplayIDs == [77])
        #expect(trace.postSnapshotEvidence != nil)
        #expect(trace.pauseIntents == [
            .init(
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                displayID: 77,
                pauseSharing: true,
                pauseMonitoring: true
            )
        ])
        #expect(trace.restoreIntents == [
            .init(
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                previousDisplayID: 77,
                resolvedDisplayID: 77,
                restoreSharing: true,
                restoreMonitoring: true,
                monitoringCapturesCursor: true
            )
        ])
        #expect(trace.restoreResults == [
            .init(
                kind: .sharing,
                status: .restored,
                previousDisplayID: 77,
                resolvedDisplayID: 77,
                failureReason: nil
            ),
            .init(
                kind: .monitoring,
                status: .skipped,
                previousDisplayID: 77,
                resolvedDisplayID: 77,
                failureReason: "monitoring_restore_deferred_until_consumer_lease"
            )
        ])
        #expect(trace.compensation.status == .degraded)
        #expect(trace.compensation.restoredSharingCount == 1)
        #expect(trace.compensation.restoredMonitoringCount == 0)
        #expect(trace.compensation.failedRestoreCount == 1)
    }

    @Test func rebuildTransactionDoesNotWriteNoOpPauseIntentWithoutSessionDemand() async throws {
        let configID = UUID(uuidString: "57575757-5757-5757-5757-575757575757")!
        let recorder = RuntimeOperationRecorder()
        let catalog = catalogSnapshot(displayID: 57, isMain: false)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: virtualDisplaySnapshot(configID: configID, displayID: 57)
            ),
            catalogCommander: FakeCatalogCommander(
                recorder: recorder,
                visibleDisplays: visibleDisplays(from: catalog)
            ),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: FakeVirtualDisplayCommander(recorder: recorder),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        _ = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(trace.pauseIntents.isEmpty)
        #expect(trace.restoreIntents.isEmpty)
        #expect(trace.restoreResults.isEmpty)
        #expect(recorder.events == [
            "refresh:topologyChanged",
            "rebuild:\(configID.uuidString)",
            "refresh:topologyChanged",
            "refresh:topologyChanged"
        ])
    }

    @Test func rebuildTransactionDeduplicatesManagedDisplayEntriesBeforeQuiesce() async throws {
        let configID = UUID(uuidString: "58585858-5858-5858-5858-585858585858")!
        let sessionID = UUID(uuidString: "59595959-5959-5959-5959-595959595959")!
        let recorder = RuntimeOperationRecorder()
        let catalog = catalogSnapshot(displayID: 58, isMain: false)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            captureProvider: FakeCaptureProvider(
                snapshot: .init(
                    startingDisplayIDs: [],
                    sessions: [
                        .init(
                            id: sessionID,
                            displayID: 58,
                            isVirtualDisplay: true,
                            capturesCursor: false,
                            state: .active,
                            metrics: .empty
                        )
                    ]
                )
            ),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 58)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: virtualDisplaySnapshot(
                    configs: [
                        (configID, 5801, 58),
                        (configID, 5801, 58)
                    ]
                )
            ),
            catalogCommander: FakeCatalogCommander(
                recorder: recorder,
                visibleDisplays: visibleDisplays(from: catalog)
            ),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: FakeVirtualDisplayCommander(recorder: recorder),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        _ = try await runtime.rebuildVirtualDisplay(configID: configID, source: .virtualDisplayRowRetry)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(trace.affectedSurfaces.map(\.configID) == [configID])
        #expect(trace.pauseIntents == [
            .init(
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                displayID: 58,
                pauseSharing: true,
                pauseMonitoring: true
            )
        ])
        #expect(recorder.events == [
            "refresh:topologyChanged",
            "stopSharing:58",
            "removeMonitoring:58",
            "rebuild:\(configID.uuidString)",
            "refresh:topologyChanged",
            "refresh:topologyChanged",
            "registerShareable:58",
            "restoreSharing:58"
        ])
    }

    @Test func rebuildTransactionWritesFailedTraceForMissingConfig() async throws {
        let missingConfigID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let commander = FakeVirtualDisplayCommander()
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: .empty),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: missingConfigID, source: .editSaveAndRebuild)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .failed)
        #expect(commander.rebuildCallCount == 0)
        #expect(trace.status == .failed)
        #expect(trace.failure?.reason == "config_not_found")
        #expect(trace.preSnapshotEvidence != nil)
        #expect(trace.postSnapshotEvidence != nil)
    }

    @Test func rebuildTransactionCoalescesDuplicateRequestForSameConfig() async throws {
        let configID = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 150_000_000)
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 88)),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        async let first = runtime.rebuildVirtualDisplay(configID: configID, source: .virtualDisplayRowRetry)
        async let second = runtime.rebuildVirtualDisplay(configID: configID, source: .editSaveAndRebuild)
        let results = try await [first, second]
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(results.map(\.transactionID).first == results.map(\.transactionID).last)
        #expect(commander.rebuildCallCount == 1)
        #expect(trace.coalescedRequestCount == 1)
        #expect(trace.phases.contains(.init(phase: .queued, note: "coalesced_duplicate_request")))
    }

    @Test func editRebuildAPIReturnsHandleAndRecordsTraceKind() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000001")!
        let edited = editConfigDTO(id: configID, displayName: "Edited Name", serial: 9101)
        let commander = FakeVirtualDisplayCommander()
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 91)),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(
                editedConfig: edited,
                expectedConfigFingerprint: edited.fingerprint,
                source: .editSaveAndRebuild
            ),
            source: .editSaveAndRebuild
        )
        _ = try await handle.waitForSaveGate()
        let result = try await handle.waitForTerminalResult()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(handle.transactionID == result.transactionID)
        #expect(result.kind == .virtualDisplayEditRebuild)
        #expect(trace.kind == .virtualDisplayEditRebuild)
        #expect(trace.source == .editSaveAndRebuild)
        #expect(trace.oldConfigEvidence?.id == configID)
        #expect(trace.editedConfigEvidence?.serialNumber == 9101)
        #expect(commander.saveConfigForRebuildCallCount == 1)
        #expect(commander.saveConfigForRebuildRequests.first?.editedConfig.displayName == "Edited Name")
        #expect(commander.saveConfigForRebuildRequests.first?.expectedConfigFingerprint == edited.fingerprint)
        #expect(commander.rebuildCallCount == 1)
    }

    @Test func editRebuildSaveGateResolvesBeforeTerminalResult() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000002")!
        let edited = editConfigDTO(id: configID, displayName: "Gate First", serial: 9102)
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 200_000_000)
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 92)),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(editedConfig: edited, expectedConfigFingerprint: edited.fingerprint, source: .editSaveAndRebuild),
            source: .editSaveAndRebuild
        )
        var terminalResolved = false
        let terminalTask = Task { @MainActor in
            _ = try await handle.waitForTerminalResult()
            terminalResolved = true
        }
        let gate = try await handle.waitForSaveGate()

        #expect(gate.configID == configID)
        #expect(terminalResolved == false)
        _ = try await terminalTask.value
    }

    @Test func editRebuildStaleRequestFailsSaveGateBeforeSideEffects() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000003")!
        let edited = editConfigDTO(id: configID, displayName: "Stale Name", serial: 9103)
        let recorder = RuntimeOperationRecorder()
        let commander = FakeVirtualDisplayCommander(recorder: recorder)
        commander.saveConfigForRebuildError = DisplayRuntimeVirtualDisplayEditRebuildSaveCommandError.editRequestStale
        let runtime = DisplayRuntime(
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 93)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 93)),
            catalogCommander: FakeCatalogCommander(recorder: recorder),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(editedConfig: edited, expectedConfigFingerprint: "stale", source: .editSaveAndRebuild),
            source: .editSaveAndRebuild
        )
        await #expect(throws: DisplayRuntimeVirtualDisplayEditRebuildFailure.self) {
            _ = try await handle.waitForSaveGate()
        }
        let result = try await handle.waitForTerminalResult()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .failed)
        #expect(trace.failure?.reason == "edit_request_stale")
        #expect(trace.virtualDisplayCommandOutcome == .notAttempted)
        #expect(commander.rebuildCallCount == 0)
        #expect(commander.restoreConfigAfterFailedEditCallCount == 0)
        #expect(recorder.events.allSatisfy { !$0.hasPrefix("stopSharing") && !$0.hasPrefix("removeMonitoring") })
    }

    @Test func editRebuildSaveFailureStopsBeforeQuiesceAndRebuild() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000004")!
        let edited = editConfigDTO(id: configID, displayName: "Save Failed Name", serial: 9104)
        let recorder = RuntimeOperationRecorder()
        let commander = FakeVirtualDisplayCommander(recorder: recorder)
        commander.saveConfigForRebuildError = NSError(domain: "EditSave", code: 4)
        let runtime = DisplayRuntime(
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 94)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 94)),
            catalogCommander: FakeCatalogCommander(recorder: recorder),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(editedConfig: edited, expectedConfigFingerprint: edited.fingerprint, source: .editSaveAndRebuild),
            source: .editSaveAndRebuild
        )
        await #expect(throws: DisplayRuntimeVirtualDisplayEditRebuildFailure.self) {
            _ = try await handle.waitForSaveGate()
        }
        _ = try await handle.waitForTerminalResult()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(trace.failure?.reason == "config_save_failed")
        #expect(trace.persistenceOutcome == .failed)
        #expect(trace.virtualDisplayCommandOutcome == .notAttempted)
        #expect(commander.rebuildCallCount == 0)
        #expect(recorder.events.allSatisfy { !$0.hasPrefix("stopSharing") && !$0.hasPrefix("removeMonitoring") })
    }

    @Test func editRebuildMissingOldConfigFailsBeforeSaveAndRebuild() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000005")!
        let commander = FakeVirtualDisplayCommander()
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: .empty),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(
                editedConfig: editConfigDTO(id: configID, displayName: "Missing", serial: 9105),
                expectedConfigFingerprint: "missing",
                source: .editSaveAndRebuild
            ),
            source: .editSaveAndRebuild
        )
        await #expect(throws: DisplayRuntimeVirtualDisplayEditRebuildFailure.self) {
            _ = try await handle.waitForSaveGate()
        }
        _ = try await handle.waitForTerminalResult()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(trace.failure?.reason == "config_not_found")
        #expect(commander.saveConfigForRebuildCallCount == 0)
        #expect(commander.rebuildCallCount == 0)
    }

    @Test func editRebuildTraceRedactsDisplayNames() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000006")!
        let secretName = "Customer Secret Display"
        let edited = editConfigDTO(id: configID, displayName: secretName, serial: 9106)
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 96)),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(editedConfig: edited, expectedConfigFingerprint: edited.fingerprint, source: .editSaveAndRebuild),
            source: .editSaveAndRebuild
        )
        _ = try await handle.waitForSaveGate()
        _ = try await handle.waitForTerminalResult()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)
        let encoded = try JSONEncoder().encode(trace)
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(trace.editedConfigEvidence?.id == configID)
        #expect(!json.contains(secretName))
        #expect(!json.contains("displayName"))
    }

    @Test func editRebuildFailureRestoresOldConfigAndRunsCompensationRebuild() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000007")!
        let previous = editConfigDTO(id: configID, displayName: "Previous Name", serial: 9107)
        let edited = editConfigDTO(id: configID, displayName: "Edited Name", serial: 9108)
        let commander = FakeVirtualDisplayCommander()
        commander.saveConfigForRebuildResult = .init(
            configID: configID,
            persistenceOutcome: .saved,
            previousConfigForCompensation: previous,
            savedConfigEvidence: .init(config: edited)
        )
        commander.scriptedRebuildErrors = [NSError(domain: "EditRebuild", code: 7), nil]
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 97)),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(editedConfig: edited, expectedConfigFingerprint: previous.fingerprint, source: .editSaveAndRebuild),
            source: .editSaveAndRebuild
        )
        _ = try await handle.waitForSaveGate()
        let result = try await handle.waitForTerminalResult()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .failed)
        #expect(trace.failure?.reason == "virtual_display_command_failed")
        #expect(trace.compensation.status == .completed)
        #expect(trace.compensation.persistenceOutcome == .rolledBack)
        #expect(trace.compensation.virtualDisplayCommandOutcome == .succeeded)
        #expect(commander.restoredConfigsAfterFailedEdit.map(\.displayName) == ["Previous Name"])
        #expect(commander.rebuildConfigIDs == [configID, configID])
    }

    @Test func editRebuildCompensationRecordsDegradedWhenCompensationRebuildFails() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000008")!
        let previous = editConfigDTO(id: configID, displayName: "Previous", serial: 9108)
        let edited = editConfigDTO(id: configID, displayName: "Edited", serial: 9109)
        let commander = FakeVirtualDisplayCommander()
        commander.saveConfigForRebuildResult = .init(
            configID: configID,
            persistenceOutcome: .saved,
            previousConfigForCompensation: previous,
            savedConfigEvidence: .init(config: edited)
        )
        commander.scriptedRebuildErrors = [
            NSError(domain: "EditRebuild", code: 8),
            NSError(domain: "CompensationRebuild", code: 9)
        ]
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 98)),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(editedConfig: edited, expectedConfigFingerprint: previous.fingerprint, source: .editSaveAndRebuild),
            source: .editSaveAndRebuild
        )
        _ = try await handle.waitForSaveGate()
        _ = try await handle.waitForTerminalResult()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(trace.compensation.status == .degraded)
        #expect(trace.compensation.persistenceOutcome == .rolledBack)
        #expect(trace.compensation.virtualDisplayCommandOutcome == .failed)
        #expect(trace.compensation.failureReason == "compensation_rebuild_failed")
    }

    @Test func editRebuildCompensationRecordsPersistenceCompensationFailure() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000009")!
        let previous = editConfigDTO(id: configID, displayName: "Previous", serial: 9109)
        let edited = editConfigDTO(id: configID, displayName: "Edited", serial: 9110)
        let commander = FakeVirtualDisplayCommander()
        commander.saveConfigForRebuildResult = .init(
            configID: configID,
            persistenceOutcome: .saved,
            previousConfigForCompensation: previous,
            savedConfigEvidence: .init(config: edited)
        )
        commander.scriptedRebuildErrors = [NSError(domain: "EditRebuild", code: 10)]
        commander.restoreConfigAfterFailedEditError = NSError(domain: "RestoreOldConfig", code: 11)
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 99)),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(editedConfig: edited, expectedConfigFingerprint: previous.fingerprint, source: .editSaveAndRebuild),
            source: .editSaveAndRebuild
        )
        _ = try await handle.waitForSaveGate()
        _ = try await handle.waitForTerminalResult()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(trace.compensation.status == .degraded)
        #expect(trace.compensation.persistenceOutcome == .rollbackFailed)
        #expect(trace.compensation.failureReason == "persistence_compensation_failed")
        #expect(commander.rebuildCallCount == 1)
    }

    @Test func duplicateEditRebuildRequestsSerializeWithoutCoalescing() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000010")!
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 50_000_000)
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 100)),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )
        let edited = editConfigDTO(id: configID, displayName: "Same Edit", serial: 9111)

        async let firstHandle = runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(editedConfig: edited, expectedConfigFingerprint: edited.fingerprint, source: .editSaveAndRebuild),
            source: .editSaveAndRebuild
        )
        async let secondHandle = runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(editedConfig: edited, expectedConfigFingerprint: edited.fingerprint, source: .editSaveAndRebuild),
            source: .editSaveAndRebuild
        )
        let handles = try await [firstHandle, secondHandle]
        for handle in handles {
            _ = try await handle.waitForSaveGate()
            _ = try await handle.waitForTerminalResult()
        }
        let traces = runtime.makeSnapshot().transactions.recentTransactions

        #expect(Set(handles.map(\.transactionID)).count == 2)
        #expect(commander.saveConfigForRebuildCallCount == 2)
        #expect(commander.rebuildCallCount == 2)
        #expect(traces.allSatisfy { $0.coalescedRequestCount == 0 })
    }

    @Test func editRebuildSameConfigDifferentEditedConfigsSerializeAndReReadState() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000011")!
        let initial = editConfigDTO(id: configID, displayName: "Initial", serial: 9111)
        let firstEdited = editConfigDTO(id: configID, displayName: "First Edit", serial: 9112)
        let secondEdited = editConfigDTO(id: configID, displayName: "Second Edit", serial: 9113)
        let provider = FakeVirtualDisplayProvider(
            snapshot: runningVirtualDisplaySnapshot(
                configID: configID,
                serial: initial.serialNumber,
                displayID: 111,
                desiredEnabled: true
            )
        )
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 50_000_000)
        commander.onSaveConfigForRebuild = { request in
            provider.setSnapshot(
                runningVirtualDisplaySnapshot(
                    configID: configID,
                    serial: request.editedConfig.serialNumber,
                    displayID: 111,
                    desiredEnabled: true
                )
            )
        }
        let runtime = DisplayRuntime(
            virtualDisplayProvider: provider,
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let firstHandle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(
                editedConfig: firstEdited,
                expectedConfigFingerprint: initial.fingerprint,
                source: .editSaveAndRebuild
            ),
            source: .editSaveAndRebuild
        )
        let secondHandle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(
                editedConfig: secondEdited,
                expectedConfigFingerprint: firstEdited.fingerprint,
                source: .editSaveAndRebuild
            ),
            source: .editSaveAndRebuild
        )

        for handle in [firstHandle, secondHandle] {
            _ = try await handle.waitForSaveGate()
            _ = try await handle.waitForTerminalResult()
        }
        let tracesByEditedSerial = Dictionary(
            uniqueKeysWithValues: runtime.makeSnapshot().transactions.recentTransactions.compactMap { trace in
                trace.editedConfigEvidence.map { ($0.serialNumber, trace) }
            }
        )

        #expect(Set([firstHandle.transactionID, secondHandle.transactionID]).count == 2)
        #expect(commander.saveConfigForRebuildRequests.map(\.editedConfig.serialNumber) == [9112, 9113])
        #expect(commander.rebuildConfigIDs == [configID, configID])
        #expect(tracesByEditedSerial[9112]?.oldConfigEvidence?.serialNumber == 9111)
        #expect(tracesByEditedSerial[9113]?.oldConfigEvidence?.serialNumber == 9112)
        #expect(tracesByEditedSerial.values.allSatisfy { $0.coalescedRequestCount == 0 })
    }

    @Test func editRebuildSameConfigDifferentExpectedFingerprintsStaleFailIndependently() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000012")!
        let initial = editConfigDTO(id: configID, displayName: "Initial", serial: 9121)
        let firstEdited = editConfigDTO(id: configID, displayName: "First Edit", serial: 9122)
        let secondEdited = editConfigDTO(id: configID, displayName: "Second Edit", serial: 9123)
        let provider = FakeVirtualDisplayProvider(
            snapshot: runningVirtualDisplaySnapshot(
                configID: configID,
                serial: initial.serialNumber,
                displayID: 112,
                desiredEnabled: true
            )
        )
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 50_000_000)
        commander.onSaveConfigForRebuild = { request in
            guard request.editedConfig.serialNumber == firstEdited.serialNumber else { return }
            provider.setSnapshot(
                runningVirtualDisplaySnapshot(
                    configID: configID,
                    serial: firstEdited.serialNumber,
                    displayID: 112,
                    desiredEnabled: true
                )
            )
            commander.saveConfigForRebuildError = DisplayRuntimeVirtualDisplayEditRebuildSaveCommandError.editRequestStale
        }
        let runtime = DisplayRuntime(
            virtualDisplayProvider: provider,
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let firstHandle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(
                editedConfig: firstEdited,
                expectedConfigFingerprint: initial.fingerprint,
                source: .editSaveAndRebuild
            ),
            source: .editSaveAndRebuild
        )
        let secondHandle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(
                editedConfig: secondEdited,
                expectedConfigFingerprint: "different-stale-fingerprint",
                source: .editSaveAndRebuild
            ),
            source: .editSaveAndRebuild
        )

        _ = try await firstHandle.waitForSaveGate()
        await #expect(throws: DisplayRuntimeVirtualDisplayEditRebuildFailure.self) {
            _ = try await secondHandle.waitForSaveGate()
        }
        let firstResult = try await firstHandle.waitForTerminalResult()
        let secondResult = try await secondHandle.waitForTerminalResult()
        let tracesByEditedSerial = Dictionary(
            uniqueKeysWithValues: runtime.makeSnapshot().transactions.recentTransactions.compactMap { trace in
                trace.editedConfigEvidence.map { ($0.serialNumber, trace) }
            }
        )

        #expect(firstResult.status != .failed)
        #expect(secondResult.status == .failed)
        #expect(secondResult.transactionID == secondHandle.transactionID)
        #expect(commander.saveConfigForRebuildRequests.map(\.expectedConfigFingerprint) == [
            initial.fingerprint,
            "different-stale-fingerprint"
        ])
        #expect(commander.rebuildConfigIDs == [configID])
        #expect(tracesByEditedSerial[9122]?.oldConfigEvidence?.serialNumber == 9121)
        #expect(tracesByEditedSerial[9123]?.oldConfigEvidence?.serialNumber == 9122)
        #expect(tracesByEditedSerial[9123]?.failure?.reason == "edit_request_stale")
        #expect(tracesByEditedSerial.values.allSatisfy { $0.coalescedRequestCount == 0 })
    }

    @Test func enableTransactionSuccessRecordsEvidenceAndTraceKind() async throws {
        let configID = UUID(uuidString: "E0010000-0000-0000-0000-000000000001")!
        let catalog = catalogSnapshot(displayID: 107, isMain: false)
        let virtualDisplayProvider = FakeVirtualDisplayProvider(
            snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 1071)
        )
        let recorder = RuntimeOperationRecorder()
        let commander = FakeVirtualDisplayCommander(recorder: recorder)
        commander.onSetDesiredEnabled = { _, enabled in
            virtualDisplayProvider.setSnapshot(disabledVirtualDisplaySnapshot(configID: configID, serial: 1071, desiredEnabled: enabled))
        }
        commander.onEnable = { _ in
            virtualDisplayProvider.setSnapshot(virtualDisplaySnapshot(configID: configID, displayID: 107))
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(recorder: recorder, visibleDisplays: visibleDisplays(from: catalog)),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.setVirtualDisplayDesiredEnabled(
            configID: configID,
            enabled: true,
            source: .virtualDisplayRowToggle
        )
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.kind == .virtualDisplayEnable)
        #expect(result.status == .completed)
        #expect(trace.kind == .virtualDisplayEnable)
        #expect(trace.preSnapshotEvidence != nil)
        #expect(trace.postSnapshotEvidence != nil)
        #expect(trace.persistenceOutcome == .saved)
        #expect(trace.virtualDisplayCommandOutcome == .succeeded)
        #expect(trace.topologyStabilityResult?.status == .stable)
        #expect(recorder.events == [
            "refresh:topologyChanged",
            "preflightEnable:\(configID.uuidString)",
            "setDesiredEnabled:\(configID.uuidString):true",
            "enable:\(configID.uuidString)",
            "refresh:topologyChanged",
            "refresh:topologyChanged"
        ])
    }

    @Test func enableTransactionSaveFailureDoesNotCallRuntimeCommand() async throws {
        let configID = UUID(uuidString: "E0010000-0000-0000-0000-000000000002")!
        let commander = FakeVirtualDisplayCommander()
        commander.setDesiredEnabledError = NSError(domain: "EnableSave", code: 1)
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 1081)
            ),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        await #expect(throws: (any Error).self) {
            try await runtime.setVirtualDisplayDesiredEnabled(
                configID: configID,
                enabled: true,
                source: .virtualDisplayRowToggle
            )
        }
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(commander.enableCallCount == 0)
        #expect(trace.persistenceOutcome == .failed)
        #expect(trace.virtualDisplayCommandOutcome == .notAttempted)
        #expect(trace.failure?.reason == "virtual_display_desired_enabled_save_failed")
    }

    @Test func enableTransactionCommandFailureKeepsSavedDesiredIntentAndRetryableTrace() async throws {
        let configID = UUID(uuidString: "E0010000-0000-0000-0000-000000000003")!
        let virtualDisplayProvider = FakeVirtualDisplayProvider(
            snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 1091)
        )
        let commander = FakeVirtualDisplayCommander()
        commander.enableError = NSError(domain: "EnableCommand", code: 2)
        commander.onSetDesiredEnabled = { _, enabled in
            virtualDisplayProvider.setSnapshot(disabledVirtualDisplaySnapshot(configID: configID, serial: 1091, desiredEnabled: enabled))
        }
        let runtime = DisplayRuntime(
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        await #expect(throws: (any Error).self) {
            try await runtime.setVirtualDisplayDesiredEnabled(
                configID: configID,
                enabled: true,
                source: .virtualDisplayRowToggle
            )
        }
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(virtualDisplayProvider.makeVirtualDisplaySnapshot().configs.first?.desiredEnabled == true)
        #expect(trace.persistenceOutcome == .saved)
        #expect(trace.virtualDisplayCommandOutcome == .failed)
        #expect(trace.failure?.recoverability == .retryable)
        #expect(trace.compensation.status == .degraded)
    }

    @Test func enableTransactionFleetRiskExpandsAffectedScopeToRunningManagedDisplays() async throws {
        let targetConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000004")!
        let peerConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000005")!
        let commander = FakeVirtualDisplayCommander()
        commander.enablePreflight = .init(
            configID: targetConfigID,
            targetPreDisplayID: nil,
            mayPerformFleetRebuild: true,
            requiresFleetQuiesce: true,
            scopeEscalationReason: .enableMayPerformFleetRebuild
        )
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: mixedVirtualDisplaySnapshot(
                    disabled: (targetConfigID, 1101),
                    running: [(peerConfigID, 1102, 110)]
                )
            ),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        _ = try await runtime.setVirtualDisplayDesiredEnabled(
            configID: targetConfigID,
            enabled: true,
            source: .virtualDisplayRowToggle
        )
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(Set(trace.affectedSurfaces.map(\.configID)) == [targetConfigID, peerConfigID])
        #expect(trace.affectedSurfaces.contains { $0.configID == peerConfigID && $0.reason == .enableFleetRiskPeer })
        #expect(trace.scopeEscalationReason == .scopeEscalatedEnableMayPerformFleetRebuild)
    }

    @Test func enableTransactionUnknownFleetRiskConservativelyQuiescesRunningPeers() async throws {
        let targetConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000006")!
        let peerConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000007")!
        let recorder = RuntimeOperationRecorder()
        let commander = FakeVirtualDisplayCommander(recorder: recorder)
        commander.enablePreflight = .init(
            configID: targetConfigID,
            targetPreDisplayID: nil,
            mayPerformFleetRebuild: nil,
            requiresFleetQuiesce: nil,
            scopeEscalationReason: nil
        )
        let runtime = DisplayRuntime(
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 111)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: mixedVirtualDisplaySnapshot(
                    disabled: (targetConfigID, 1111),
                    running: [(peerConfigID, 1112, 111)]
                )
            ),
            catalogCommander: FakeCatalogCommander(recorder: recorder),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        _ = try await runtime.setVirtualDisplayDesiredEnabled(
            configID: targetConfigID,
            enabled: true,
            source: .virtualDisplayRowToggle
        )

        #expect(recorder.events.contains("stopSharing:111"))
        #expect(commander.enableCallCount == 1)
    }

    @Test func enableTransactionRestoresPeerSharingAndDefersPeerMonitoringAfterStableTopology() async throws {
        let targetConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000008")!
        let peerConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000009")!
        let catalog = catalogSnapshot(displayIDs: [112, 113], mainDisplayID: nil)
        let virtualDisplayProvider = FakeVirtualDisplayProvider(
            snapshot: mixedVirtualDisplaySnapshot(
                disabled: (targetConfigID, 1121),
                running: [(peerConfigID, 1122, 113)]
            )
        )
        let recorder = RuntimeOperationRecorder()
        let commander = FakeVirtualDisplayCommander(recorder: recorder)
        commander.enablePreflight = .init(
            configID: targetConfigID,
            targetPreDisplayID: nil,
            mayPerformFleetRebuild: true,
            requiresFleetQuiesce: true,
            scopeEscalationReason: .enableMayPerformFleetRebuild
        )
        commander.onEnable = { _ in
            virtualDisplayProvider.setSnapshot(
                virtualDisplaySnapshot(configs: [
                    (targetConfigID, 1121, 112),
                    (peerConfigID, 1122, 113)
                ])
            )
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            captureProvider: FakeCaptureProvider(snapshot: monitoringCaptureSnapshot(displayID: 113, capturesCursor: true)),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 113)),
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(recorder: recorder, visibleDisplays: visibleDisplays(from: catalog)),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        _ = try await runtime.setVirtualDisplayDesiredEnabled(
            configID: targetConfigID,
            enabled: true,
            source: .virtualDisplayRowToggle
        )
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(recorder.events.contains("restoreSharing:113"))
        #expect(trace.restoreResults.contains {
            $0.kind == .monitoring
                && $0.previousDisplayID == 113
                && $0.failureReason == "monitoring_restore_deferred_until_consumer_lease"
        })
        #expect(trace.scopeEscalationReason == .scopeEscalatedEnableMayPerformFleetRebuild)
    }

    @Test func disableTransactionQuiescesAndNeverRestoresDisabledTarget() async throws {
        let configID = UUID(uuidString: "E0010000-0000-0000-0000-000000000010")!
        let virtualDisplayProvider = FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 120))
        let recorder = RuntimeOperationRecorder()
        let commander = FakeVirtualDisplayCommander(recorder: recorder)
        commander.onSetDesiredEnabled = { _, enabled in
            virtualDisplayProvider.setSnapshot(
                runningVirtualDisplaySnapshot(
                    configID: configID,
                    serial: 1201,
                    displayID: 120,
                    desiredEnabled: enabled
                )
            )
        }
        commander.onDisable = { _ in
            virtualDisplayProvider.setSnapshot(disabledVirtualDisplaySnapshot(configID: configID, serial: 1201, desiredEnabled: false))
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 120, isMain: false)),
            captureProvider: FakeCaptureProvider(snapshot: monitoringCaptureSnapshot(displayID: 120, capturesCursor: false)),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 120)),
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(recorder: recorder),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        _ = try await runtime.setVirtualDisplayDesiredEnabled(
            configID: configID,
            enabled: false,
            source: .virtualDisplayRowToggle
        )
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(recorder.events.contains("stopSharing:120"))
        #expect(recorder.events.contains("removeMonitoring:120"))
        #expect(recorder.events.allSatisfy { !$0.contains("restoreSharing:120") })
        #expect(trace.restoreResults.contains {
            $0.kind == .sharing && $0.failureReason == "target_disabled"
        })
        #expect(trace.restoreResults.contains {
            $0.kind == .monitoring && $0.failureReason == "target_disabled"
        })
    }

    @Test func disableTransactionRestoresPeerSharingAndDefersMonitoringAfterStableTopology() async throws {
        let targetConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000011")!
        let peerConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000012")!
        let catalog = catalogSnapshot(displayIDs: [121, 122], mainDisplayID: 121)
        let virtualDisplayProvider = FakeVirtualDisplayProvider(
            snapshot: virtualDisplaySnapshot(configs: [
                (targetConfigID, 1211, 121),
                (peerConfigID, 1212, 122)
            ])
        )
        let recorder = RuntimeOperationRecorder()
        let commander = FakeVirtualDisplayCommander(recorder: recorder)
        commander.onDisable = { _ in
            virtualDisplayProvider.setSnapshot(
                mixedVirtualDisplaySnapshot(
                    disabled: (targetConfigID, 1211),
                    running: [(peerConfigID, 1212, 122)]
                )
            )
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            captureProvider: FakeCaptureProvider(snapshot: monitoringCaptureSnapshot(displayID: 122, capturesCursor: false)),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 122)),
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(recorder: recorder, visibleDisplays: visibleDisplays(from: catalog)),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        _ = try await runtime.setVirtualDisplayDesiredEnabled(
            configID: targetConfigID,
            enabled: false,
            source: .virtualDisplayRowToggle
        )
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(recorder.events.contains("restoreSharing:122"))
        #expect(trace.restoreResults.contains {
            $0.kind == .monitoring
                && $0.previousDisplayID == 122
                && $0.failureReason == "monitoring_restore_deferred_until_consumer_lease"
        })
    }

    @Test func disableTransactionWritesPeerRestoreSkipReasonWhenTopologyIsDegraded() async throws {
        let targetConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000013")!
        let peerConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000014")!
        let catalog = catalogSnapshot(displayIDs: [123, 124], mainDisplayID: 123)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 124)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: virtualDisplaySnapshot(configs: [
                    (targetConfigID, 1231, 123),
                    (peerConfigID, 1232, 124)
                ])
            ),
            catalogCommander: FakeCatalogCommander(refreshResults: [.reusedSnapshot, .failed]),
            sharingCommander: FakeSharingCommander(),
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 4)
        )

        _ = try await runtime.setVirtualDisplayDesiredEnabled(
            configID: targetConfigID,
            enabled: false,
            source: .virtualDisplayRowToggle
        )
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(trace.topologyStabilityResult?.status == .failed)
        #expect(trace.restoreResults.contains {
            $0.kind == .sharing
                && $0.previousDisplayID == 124
                && $0.failureReason == "topology_failed"
        })
    }

    @Test func disableTransactionMissingConfigFailsWithoutCommand() async throws {
        let missingConfigID = UUID(uuidString: "E0010000-0000-0000-0000-000000000015")!
        let commander = FakeVirtualDisplayCommander()
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: .empty),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.setVirtualDisplayDesiredEnabled(
            configID: missingConfigID,
            enabled: false,
            source: .virtualDisplayRowToggle
        )
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .failed)
        #expect(commander.disableCallCount == 0)
        #expect(trace.failure?.reason == "config_not_found")
    }

    @Test func enableThenDisableSameConfigSerializesAndReReadsState() async throws {
        let configID = UUID(uuidString: "E0010000-0000-0000-0000-000000000016")!
        let catalog = catalogSnapshot(displayID: 125, isMain: false)
        let virtualDisplayProvider = FakeVirtualDisplayProvider(
            snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 1251)
        )
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 50_000_000)
        commander.onSetDesiredEnabled = { _, enabled in
            let current = virtualDisplayProvider.makeVirtualDisplaySnapshot()
            let displayID = current.managedDisplays.first?.displayID
            if let displayID, enabled {
                virtualDisplayProvider.setSnapshot(runningVirtualDisplaySnapshot(
                    configID: configID,
                    serial: 1251,
                    displayID: displayID,
                    desiredEnabled: true
                ))
            } else {
                virtualDisplayProvider.setSnapshot(disabledVirtualDisplaySnapshot(
                    configID: configID,
                    serial: 1251,
                    desiredEnabled: enabled
                ))
            }
        }
        commander.onEnable = { _ in
            virtualDisplayProvider.setSnapshot(virtualDisplaySnapshot(configID: configID, displayID: 125))
        }
        commander.onDisable = { _ in
            virtualDisplayProvider.setSnapshot(disabledVirtualDisplaySnapshot(configID: configID, serial: 1251, desiredEnabled: false))
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(visibleDisplays: visibleDisplays(from: catalog)),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let enable = Task { @MainActor in
            try await runtime.setVirtualDisplayDesiredEnabled(
                configID: configID,
                enabled: true,
                source: .virtualDisplayRowToggle
            )
        }
        await Task.yield()
        let disable = Task { @MainActor in
            try await runtime.setVirtualDisplayDesiredEnabled(
                configID: configID,
                enabled: false,
                source: .virtualDisplayRowToggle
            )
        }
        _ = try await [enable.value, disable.value]
        let traces = runtime.makeSnapshot().transactions.recentTransactions

        #expect(commander.enableCallCount == 1)
        #expect(commander.disableCallCount == 1)
        #expect(traces.first?.kind == .virtualDisplayDisable)
        #expect(traces.dropFirst().first?.kind == .virtualDisplayEnable)
        #expect(traces.first?.preSnapshotEvidence?.runningConfigIDs == [configID])
    }

    @Test func disableThenEnableSameConfigSerializesAndReReadsState() async throws {
        let configID = UUID(uuidString: "E0010000-0000-0000-0000-000000000018")!
        let catalog = catalogSnapshot(displayID: 127, isMain: false)
        let virtualDisplayProvider = FakeVirtualDisplayProvider(
            snapshot: runningVirtualDisplaySnapshot(
                configID: configID,
                serial: 1271,
                displayID: 127,
                desiredEnabled: true
            )
        )
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 50_000_000)
        commander.onSetDesiredEnabled = { _, enabled in
            if enabled {
                virtualDisplayProvider.setSnapshot(disabledVirtualDisplaySnapshot(
                    configID: configID,
                    serial: 1271,
                    desiredEnabled: true
                ))
            } else {
                virtualDisplayProvider.setSnapshot(disabledVirtualDisplaySnapshot(
                    configID: configID,
                    serial: 1271,
                    desiredEnabled: false
                ))
            }
        }
        commander.onDisable = { _ in
            virtualDisplayProvider.setSnapshot(disabledVirtualDisplaySnapshot(
                configID: configID,
                serial: 1271,
                desiredEnabled: false
            ))
        }
        commander.onEnable = { _ in
            virtualDisplayProvider.setSnapshot(runningVirtualDisplaySnapshot(
                configID: configID,
                serial: 1271,
                displayID: 127,
                desiredEnabled: true
            ))
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(visibleDisplays: visibleDisplays(from: catalog)),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let disable = Task { @MainActor in
            try await runtime.setVirtualDisplayDesiredEnabled(
                configID: configID,
                enabled: false,
                source: .virtualDisplayRowToggle
            )
        }
        await Task.yield()
        let enable = Task { @MainActor in
            try await runtime.setVirtualDisplayDesiredEnabled(
                configID: configID,
                enabled: true,
                source: .virtualDisplayRowToggle
            )
        }
        _ = try await [disable.value, enable.value]
        let traces = runtime.makeSnapshot().transactions.recentTransactions

        #expect(commander.disableCallCount == 1)
        #expect(commander.enableCallCount == 1)
        #expect(traces.first?.kind == .virtualDisplayEnable)
        #expect(traces.dropFirst().first?.kind == .virtualDisplayDisable)
        #expect(traces.first?.preSnapshotEvidence?.runningConfigIDs == [])
    }

    @Test func duplicateEnableWhileActiveCoalescesOnlyWhenKindAndConfigMatch() async throws {
        let configID = UUID(uuidString: "E0010000-0000-0000-0000-000000000017")!
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 150_000_000)
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 1261)
            ),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        async let first = runtime.setVirtualDisplayDesiredEnabled(
            configID: configID,
            enabled: true,
            source: .virtualDisplayRowToggle
        )
        async let second = runtime.setVirtualDisplayDesiredEnabled(
            configID: configID,
            enabled: true,
            source: .diagnostics
        )
        let results = try await [first, second]
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(results.first?.transactionID == results.last?.transactionID)
        #expect(commander.enableCallCount == 1)
        #expect(trace.coalescedRequestCount == 1)
    }

    @Test func duplicateDisableWhileActiveCoalescesOnlyWhenKindAndConfigMatch() async throws {
        let configID = UUID(uuidString: "E0010000-0000-0000-0000-000000000019")!
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 150_000_000)
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: runningVirtualDisplaySnapshot(
                    configID: configID,
                    serial: 1281,
                    displayID: 128,
                    desiredEnabled: true
                )
            ),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        async let first = runtime.setVirtualDisplayDesiredEnabled(
            configID: configID,
            enabled: false,
            source: .virtualDisplayRowToggle
        )
        async let second = runtime.setVirtualDisplayDesiredEnabled(
            configID: configID,
            enabled: false,
            source: .diagnostics
        )
        let results = try await [first, second]
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(results.first?.transactionID == results.last?.transactionID)
        #expect(commander.disableCallCount == 1)
        #expect(trace.coalescedRequestCount == 1)
    }

    @Test func rebuildTransactionEscalatesManagedMainToFleetScope() async throws {
        let targetConfigID = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        let peerConfigID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [
                        .init(displayID: 91, pixelWidth: 1920, pixelHeight: 1080),
                        .init(displayID: 92, pixelWidth: 1920, pixelHeight: 1080)
                    ],
                    topologySignature: [
                        .init(
                            displayID: 91,
                            isMain: true,
                            pixelWidth: 1920,
                            pixelHeight: 1080,
                            refreshRateMilliHertz: 60_000,
                            mirrorsDisplayID: nil
                        ),
                        .init(
                            displayID: 92,
                            isMain: false,
                            pixelWidth: 1920,
                            pixelHeight: 1080,
                            refreshRateMilliHertz: 60_000,
                            mirrorsDisplayID: nil
                        )
                    ]
                )
            ),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: virtualDisplaySnapshot(
                    configs: [
                        (targetConfigID, 9101, 91),
                        (peerConfigID, 9102, 92)
                    ]
                )
            ),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        _ = try await runtime.rebuildVirtualDisplay(configID: targetConfigID, source: .virtualDisplayRowRetry)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        let affectedConfigIDs = trace.affectedSurfaces.map(\.configID).sorted { $0.uuidString < $1.uuidString }
        let expectedConfigIDs = [targetConfigID, peerConfigID].sorted { $0.uuidString < $1.uuidString }
        #expect(affectedConfigIDs == expectedConfigIDs)
        #expect(trace.affectedSurfaces.contains { $0.reason == .managedMainFleetPeer && $0.configID == peerConfigID })
    }

    @Test func rebuildTransactionCallsCommandWhenPreDisplayIDIsUnavailable() async throws {
        let configID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let commander = FakeVirtualDisplayCommander()
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: .init(
                    rebuildRequestCount: 0,
                    rebuildingConfigIDs: [],
                    runningConfigIDs: [],
                    recentlyAppliedConfigIDs: [],
                    rebuildFailureConfigIDs: [],
                    configStoreHasLoadFailure: false,
                    configStoreHasDiagnostics: false,
                    managedDisplays: [],
                    configs: [
                        .init(
                            id: configID,
                            serialNumber: 9103,
                            desiredEnabled: true,
                            physicalWidthMillimeters: 600,
                            physicalHeightMillimeters: 340,
                            modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
                        )
                    ],
                    restoreFailureConfigIDs: []
                )
            ),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 2)
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(commander.rebuildCallCount == 1)
        #expect(trace.affectedSurfaces.first?.preDisplayID == nil)
        #expect(trace.pauseIntents.isEmpty)
        #expect(trace.topologyStabilityResult?.status == .timedOut)
    }

    @Test func rebuildTransactionRecordsUnprovableTopologyWhenPermissionIsUnavailable() async throws {
        let configID = UUID(uuidString: "C1C1C1C1-C1C1-C1C1-C1C1-C1C1C1C1C1C1")!
        let catalog = DisplayRuntimeCatalogSnapshot(
            hasScreenCapturePermission: false,
            lastPreflightPermission: false,
            lastRequestPermission: nil,
            isLoadingDisplays: false,
            hasLoadError: false,
            lastLoadError: nil,
            loadedDisplays: [],
            topologySignature: []
        )
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 81)),
            catalogCommander: FakeCatalogCommander(refreshResults: [.clearedSnapshot]),
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 4)
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .virtualDisplayRowRetry)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(result.virtualDisplayCommandSucceeded)
        #expect(result.hasSessionRecoveryFailures)
        #expect(trace.status == .completedWithRecoveryFailures)
        #expect(trace.topologyStabilityResult?.status == .unprovableDueToPermission)
        #expect(trace.topologyStabilityResult?.sampleCount == 1)
        #expect(trace.topologyStabilityResult?.failureReason == "screen_capture_permission_unavailable")
        #expect(trace.phases.contains(.init(phase: .waitingForTopology)))
        #expect(trace.failure == nil)
    }

    @Test func rebuildTransactionRecordsFailedTopologyRefreshAfterCommandSuccess() async throws {
        let configID = UUID(uuidString: "C2C2C2C2-C2C2-C2C2-C2C2-C2C2C2C2C2C2")!
        let catalog = catalogSnapshot(displayID: 82, isMain: false)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 82)),
            catalogCommander: FakeCatalogCommander(
                refreshResults: [.reusedSnapshot, .failed],
                visibleDisplays: visibleDisplays(from: catalog)
            ),
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 4)
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(result.virtualDisplayCommandSucceeded)
        #expect(trace.topologyStabilityResult?.status == .failed)
        #expect(trace.topologyStabilityResult?.sampleCount == 1)
        #expect(trace.topologyStabilityResult?.failureReason == "catalog_refresh_failed")
        #expect(trace.failure == nil)
    }

    @Test func rebuildTransactionRecordsTimedOutTopologyWhenAffectedDisplayCannotResolveVisibleID() async throws {
        let configID = UUID(uuidString: "C3C3C3C3-C3C3-C3C3-C3C3-C3C3C3C3C3C3")!
        let catalog = DisplayRuntimeCatalogSnapshot(
            hasScreenCapturePermission: true,
            lastPreflightPermission: true,
            lastRequestPermission: nil,
            isLoadingDisplays: false,
            hasLoadError: false,
            lastLoadError: nil,
            loadedDisplays: [],
            topologySignature: []
        )
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 83)),
            catalogCommander: FakeCatalogCommander(refreshResults: [.reusedSnapshot]),
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 2)
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(result.virtualDisplayCommandSucceeded)
        #expect(trace.topologyStabilityResult?.status == .timedOut)
        #expect(trace.topologyStabilityResult?.sampleCount == 2)
        #expect(trace.topologyStabilityResult?.failureReason == "topology_stability_timed_out")
        #expect(trace.compensation.status == .degraded)
        #expect(trace.failure == nil)
    }

    @Test func rebuildTransactionMarksRecoveryFailureWhenSharingRestoreFails() async throws {
        let configID = UUID(uuidString: "D1D1D1D1-D1D1-D1D1-D1D1-D1D1D1D1D1D1")!
        let catalog = catalogSnapshot(displayID: 101, isMain: false)
        let sharingCommander = FakeSharingCommander(
            restoreResult: .failed("display_not_found")
        )
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 101)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 101)),
            catalogCommander: FakeCatalogCommander(visibleDisplays: visibleDisplays(from: catalog)),
            sharingCommander: sharingCommander,
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(result.virtualDisplayCommandSucceeded)
        #expect(sharingCommander.restoredDisplayIDs == [101])
        #expect(trace.restoreResults == [
            .init(
                kind: .sharing,
                status: .failed,
                previousDisplayID: 101,
                resolvedDisplayID: 101,
                failureReason: "display_not_found"
            )
        ])
        #expect(trace.compensation.status == .degraded)
        #expect(trace.compensation.failedRestoreCount == 1)
        #expect(trace.failure == nil)
    }

    @Test func rebuildTransactionMarksRecoveryFailureWhenSharingRestoreInvalidates() async throws {
        let configID = UUID(uuidString: "D2D2D2D2-D2D2-D2D2-D2D2-D2D2D2D2D2D2")!
        let catalog = catalogSnapshot(displayID: 102, isMain: false)
        let sharingCommander = FakeSharingCommander(
            restoreResult: .invalidated("sharing_start_invalidated")
        )
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 102)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 102)),
            catalogCommander: FakeCatalogCommander(visibleDisplays: visibleDisplays(from: catalog)),
            sharingCommander: sharingCommander,
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(sharingCommander.restoredDisplayIDs == [102])
        #expect(trace.restoreResults.first?.status == .invalidated)
        #expect(trace.restoreResults.first?.failureReason == "sharing_start_invalidated")
        #expect(trace.compensation.status == .degraded)
        #expect(trace.failure == nil)
    }

    @Test func rebuildTransactionSkipsSharingRestoreWhenPostWebServiceStopped() async throws {
        let configID = UUID(uuidString: "D3D3D3D3-D3D3-D3D3-D3D3-D3D3D3D3D3D3")!
        let catalog = catalogSnapshot(displayID: 104, isMain: false)
        let sharingProvider = FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 104))
        let sharingCommander = FakeSharingCommander()
        var refreshCount = 0
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            sharingProvider: sharingProvider,
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 104)),
            catalogCommander: FakeCatalogCommander(
                visibleDisplays: visibleDisplays(from: catalog),
                onRefresh: {
                    refreshCount += 1
                    if refreshCount >= 2 {
                        sharingProvider.setSnapshot(stoppedSharingSnapshot(previousDisplayID: 104))
                    }
                }
            ),
            sharingCommander: sharingCommander,
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(trace.topologyStabilityResult?.status == .stable)
        #expect(trace.restoreIntents == [
            .init(
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                previousDisplayID: 104,
                resolvedDisplayID: 104,
                restoreSharing: true,
                restoreMonitoring: false,
                monitoringCapturesCursor: false
            )
        ])
        #expect(trace.restoreResults == [
            .init(
                kind: .sharing,
                status: .skipped,
                previousDisplayID: 104,
                resolvedDisplayID: 104,
                failureReason: "web_service_not_running"
            )
        ])
        #expect(sharingCommander.restoredDisplayIDs.isEmpty)
        #expect(trace.compensation.status == .degraded)
        #expect(trace.compensation.failedRestoreCount == 1)
        #expect(trace.failure == nil)
    }

    @Test func rebuildTransactionRecordsMonitoringRestoreIntentAsDeferredEvidence() async throws {
        let configID = UUID(uuidString: "D4D4D4D4-D4D4-D4D4-D4D4-D4D4D4D4D4D4")!
        let catalog = catalogSnapshot(displayID: 105, isMain: false)
        let recorder = RuntimeOperationRecorder()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            captureProvider: FakeCaptureProvider(
                snapshot: monitoringCaptureSnapshot(displayID: 105, capturesCursor: true)
            ),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 105)),
            catalogCommander: FakeCatalogCommander(
                recorder: recorder,
                visibleDisplays: visibleDisplays(from: catalog)
            ),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: FakeVirtualDisplayCommander(recorder: recorder),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(result.hasSessionRecoveryFailures)
        #expect(trace.topologyStabilityResult?.status == .stable)
        #expect(trace.restoreIntents == [
            .init(
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                previousDisplayID: 105,
                resolvedDisplayID: 105,
                restoreSharing: false,
                restoreMonitoring: true,
                monitoringCapturesCursor: true
            )
        ])
        #expect(trace.restoreResults == [
            .init(
                kind: .monitoring,
                status: .skipped,
                previousDisplayID: 105,
                resolvedDisplayID: 105,
                failureReason: "monitoring_restore_deferred_until_consumer_lease"
            )
        ])
        #expect(recorder.events == [
            "refresh:topologyChanged",
            "removeMonitoring:105",
            "rebuild:\(configID.uuidString)",
            "refresh:topologyChanged",
            "refresh:topologyChanged"
        ])
        #expect(recorder.events.allSatisfy { !$0.contains("startMonitoring") })
        #expect(recorder.events.allSatisfy { !$0.contains("setMonitoringSessionCapturesCursor") })
        #expect(trace.compensation.status == .degraded)
        #expect(trace.compensation.restoredSharingCount == 0)
        #expect(trace.compensation.restoredMonitoringCount == 0)
        #expect(trace.compensation.failedRestoreCount == 1)
        #expect(trace.failure == nil)
    }

    @Test func rebuildTransactionSkipsSharingRestoreWhenTopologyCannotProveStable() async throws {
        struct Scenario {
            let expectedStatus: DisplayRuntimeTopologyStabilityStatus
            let catalog: DisplayRuntimeCatalogSnapshot
            let refreshResults: [DisplayRuntimeCatalogRefreshResult]
            let maximumSampleCount: Int
        }

        let scenarios: [Scenario] = [
            .init(
                expectedStatus: .unprovableDueToPermission,
                catalog: .init(
                    hasScreenCapturePermission: false,
                    lastPreflightPermission: false,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [],
                    topologySignature: []
                ),
                refreshResults: [.clearedSnapshot],
                maximumSampleCount: 4
            ),
            .init(
                expectedStatus: .failed,
                catalog: catalogSnapshot(displayID: 103, isMain: false),
                refreshResults: [.reusedSnapshot, .failed],
                maximumSampleCount: 4
            ),
            .init(
                expectedStatus: .timedOut,
                catalog: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [],
                    topologySignature: []
                ),
                refreshResults: [.reusedSnapshot],
                maximumSampleCount: 2
            )
        ]

        for scenario in scenarios {
            let configID = UUID()
            let sharingCommander = FakeSharingCommander()
            let runtime = DisplayRuntime(
                catalogProvider: FakeCatalogProvider(snapshot: scenario.catalog),
                sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 103)),
                virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 103)),
                catalogCommander: FakeCatalogCommander(refreshResults: scenario.refreshResults),
                sharingCommander: sharingCommander,
                virtualDisplayCommander: FakeVirtualDisplayCommander(),
                topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: scenario.maximumSampleCount)
            )

            let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
            let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

            #expect(result.status == .completedWithRecoveryFailures)
            #expect(trace.topologyStabilityResult?.status == scenario.expectedStatus)
            #expect(trace.restoreResults == [
                .init(
                    kind: .sharing,
                    status: .skipped,
                    previousDisplayID: 103,
                    resolvedDisplayID: nil,
                    failureReason: "topology_\(scenario.expectedStatus.rawValue)"
                )
            ])
            #expect(sharingCommander.restoredDisplayIDs.isEmpty)
            #expect(trace.compensation.status == .degraded)
            #expect(trace.failure == nil)
        }
    }

    @Test func rebuildTransactionSkipsMonitoringRestoreWhenTopologyCannotProveStable() async throws {
        struct Scenario {
            let expectedStatus: DisplayRuntimeTopologyStabilityStatus
            let catalog: DisplayRuntimeCatalogSnapshot
            let refreshResults: [DisplayRuntimeCatalogRefreshResult]
            let maximumSampleCount: Int
        }

        let scenarios: [Scenario] = [
            .init(
                expectedStatus: .unprovableDueToPermission,
                catalog: .init(
                    hasScreenCapturePermission: false,
                    lastPreflightPermission: false,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [],
                    topologySignature: []
                ),
                refreshResults: [.clearedSnapshot],
                maximumSampleCount: 4
            ),
            .init(
                expectedStatus: .failed,
                catalog: catalogSnapshot(displayID: 106, isMain: false),
                refreshResults: [.reusedSnapshot, .failed],
                maximumSampleCount: 4
            ),
            .init(
                expectedStatus: .timedOut,
                catalog: .init(
                    hasScreenCapturePermission: true,
                    lastPreflightPermission: true,
                    lastRequestPermission: nil,
                    isLoadingDisplays: false,
                    hasLoadError: false,
                    lastLoadError: nil,
                    loadedDisplays: [],
                    topologySignature: []
                ),
                refreshResults: [.reusedSnapshot],
                maximumSampleCount: 2
            )
        ]

        for scenario in scenarios {
            let configID = UUID()
            let recorder = RuntimeOperationRecorder()
            let runtime = DisplayRuntime(
                catalogProvider: FakeCatalogProvider(snapshot: scenario.catalog),
                captureProvider: FakeCaptureProvider(
                    snapshot: monitoringCaptureSnapshot(displayID: 106, capturesCursor: false)
                ),
                virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 106)),
                catalogCommander: FakeCatalogCommander(
                    recorder: recorder,
                    refreshResults: scenario.refreshResults
                ),
                captureCommander: FakeCaptureCommander(recorder: recorder),
                virtualDisplayCommander: FakeVirtualDisplayCommander(recorder: recorder),
                topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: scenario.maximumSampleCount)
            )

            let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
            let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

            #expect(result.status == .completedWithRecoveryFailures)
            #expect(trace.topologyStabilityResult?.status == scenario.expectedStatus)
            #expect(trace.restoreIntents == [
                .init(
                    surfaceIdentity: .managedVirtualDisplay(configID: configID),
                    previousDisplayID: 106,
                    resolvedDisplayID: nil,
                    restoreSharing: false,
                    restoreMonitoring: true,
                    monitoringCapturesCursor: false
                )
            ])
            #expect(trace.restoreResults == [
                .init(
                    kind: .monitoring,
                    status: .skipped,
                    previousDisplayID: 106,
                    resolvedDisplayID: nil,
                    failureReason: "topology_\(scenario.expectedStatus.rawValue)"
                )
            ])
            #expect(recorder.events.allSatisfy { !$0.contains("startMonitoring") })
            #expect(recorder.events.allSatisfy { !$0.contains("setMonitoringSessionCapturesCursor") })
            #expect(trace.compensation.status == .degraded)
            #expect(trace.compensation.restoredMonitoringCount == 0)
            #expect(trace.compensation.failedRestoreCount == 1)
            #expect(trace.failure == nil)
        }
    }

    @Test func rebuildTransactionDoesNotStabilizeWhenVisibleDisplayIDsChange() async throws {
        let configID = UUID(uuidString: "C4C4C4C4-C4C4-C4C4-C4C4-C4C4C4C4C4C4")!
        let firstCatalog = catalogSnapshot(displayID: 84, isMain: false)
        let secondCatalog = DisplayRuntimeCatalogSnapshot(
            hasScreenCapturePermission: true,
            lastPreflightPermission: true,
            lastRequestPermission: nil,
            isLoadingDisplays: false,
            hasLoadError: false,
            lastLoadError: nil,
            loadedDisplays: [
                .init(displayID: 84, pixelWidth: 1920, pixelHeight: 1080),
                .init(displayID: 85, pixelWidth: 1920, pixelHeight: 1080)
            ],
            topologySignature: firstCatalog.topologySignature
        )
        let catalogProvider = FakeCatalogProvider(snapshot: firstCatalog)
        var refreshCount = 0
        let runtime = DisplayRuntime(
            catalogProvider: catalogProvider,
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 84)),
            catalogCommander: FakeCatalogCommander(
                visibleDisplays: visibleDisplays(from: secondCatalog),
                onRefresh: {
                    refreshCount += 1
                    if refreshCount == 3 {
                        catalogProvider.setSnapshot(secondCatalog)
                    }
                }
            ),
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 2)
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(trace.topologyStabilityResult?.status == .timedOut)
        #expect(trace.topologyStabilityResult?.sampleCount == 2)
        #expect(trace.topologyStabilityResult?.lastSample?.visibleDisplayIDs == [84, 85])
    }

    @Test func rebuildTransactionDoesNotStabilizeWhenManagedDisplayMappingChanges() async throws {
        let configID = UUID(uuidString: "C5C5C5C5-C5C5-C5C5-C5C5-C5C5C5C5C5C5")!
        let catalog = catalogSnapshot(displayIDs: [86, 87], mainDisplayID: nil)
        let virtualDisplayProvider = FakeVirtualDisplayProvider(
            snapshot: virtualDisplaySnapshot(configID: configID, displayID: 86)
        )
        var refreshCount = 0
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(
                visibleDisplays: visibleDisplays(from: catalog),
                onRefresh: {
                    refreshCount += 1
                    if refreshCount == 3 {
                        virtualDisplayProvider.setSnapshot(
                            virtualDisplaySnapshot(configID: configID, displayID: 87)
                        )
                    }
                }
            ),
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 2)
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(trace.topologyStabilityResult?.status == .timedOut)
        #expect(trace.topologyStabilityResult?.sampleCount == 2)
        #expect(trace.topologyStabilityResult?.lastSample?.managedVirtualDisplays.map(\.displayID) == [87])
    }

    @Test func rebuildTransactionStabilizesFirstResolvedSampleWhenSingleSamplePolicyIsRequested() async throws {
        let configID = UUID(uuidString: "C6C6C6C6-C6C6-C6C6-C6C6-C6C6C6C6C6C6")!
        let catalog = catalogSnapshot(displayID: 88, isMain: false)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 88)),
            catalogCommander: FakeCatalogCommander(visibleDisplays: visibleDisplays(from: catalog)),
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: .init(
                requiredStableSampleCount: 1,
                maximumSampleCount: 1,
                sampleIntervalNanoseconds: 0
            )
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completed)
        #expect(trace.topologyStabilityResult?.status == .stable)
        #expect(trace.topologyStabilityResult?.sampleCount == 1)
    }

    @Test func createTransactionRecordsCommandFactsAndRedactsDisplayName() async throws {
        let createdConfigID = UUID()
        let virtualDisplayProvider = FakeVirtualDisplayProvider(snapshot: .empty)
        let catalogProvider = FakeCatalogProvider(snapshot: catalogSnapshot(displayIDs: [], mainDisplayID: nil))
        let commander = FakeVirtualDisplayCommander()
        commander.createResult = .init(
            transactionID: DisplayRuntimeTransactionID(),
            createdConfigID: createdConfigID,
            serialNumber: 9401,
            targetWasRunningAfterCommand: true,
            preDisplayID: nil,
            postDisplayID: 77,
            persistenceOutcome: .saved,
            runtimeCreationOutcome: .succeeded,
            rollbackOutcome: .notAttempted,
            createdConfigEvidence: .init(
                id: createdConfigID,
                serialNumber: 9401,
                desiredEnabled: true,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modeCount: 1,
                maximumPixelWidth: 1920,
                maximumPixelHeight: 1080
            ),
            runningConfigIDsAfterCommand: [createdConfigID],
            managedDisplaysAfterCommand: [
                .init(configID: createdConfigID, serialNumber: 9401, displayID: 77, isLiveRuntime: true)
            ]
        )
        commander.onCreate = { _ in
            virtualDisplayProvider.setSnapshot(virtualDisplaySnapshot(configID: createdConfigID, displayID: 77))
            catalogProvider.setSnapshot(catalogSnapshot(displayIDs: [77], mainDisplayID: 77))
        }
        let runtime = DisplayRuntime(
            catalogProvider: catalogProvider,
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.createVirtualDisplay(
            request: createRequest(displayName: "Secret Display", serialNumber: 9401),
            source: .createVirtualDisplaySheet
        )
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)
        let encodedTrace = String(
            data: try JSONEncoder().encode(trace),
            encoding: .utf8
        ) ?? ""

        #expect(result.status == .completed)
        #expect(result.createdConfigID == createdConfigID)
        #expect(result.runtimeCreationOutcome == .succeeded)
        #expect(trace.kind == .virtualDisplayCreate)
        #expect(trace.source == .createVirtualDisplaySheet)
        #expect(trace.createdConfigID == createdConfigID)
        #expect(trace.createdConfigEvidence?.serialNumber == 9401)
        #expect(trace.persistenceOutcome == .saved)
        #expect(trace.runtimeCreationOutcome == .succeeded)
        #expect(encodedTrace.contains("Secret Display") == false)
    }

    @Test func createRuntimeCreationFailureWithRollbackFailureRecordsRecoveryFailure() async throws {
        let createdConfigID = UUID()
        let failedResult = DisplayRuntimeVirtualDisplayCreateCommandResult(
            transactionID: DisplayRuntimeTransactionID(),
            createdConfigID: createdConfigID,
            serialNumber: 9402,
            targetWasRunningAfterCommand: false,
            preDisplayID: nil,
            postDisplayID: nil,
            persistenceOutcome: .rollbackFailed,
            runtimeCreationOutcome: .failed,
            rollbackOutcome: .rollbackFailed,
            createdConfigEvidence: .init(
                id: createdConfigID,
                serialNumber: 9402,
                desiredEnabled: true,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modeCount: 1,
                maximumPixelWidth: 1920,
                maximumPixelHeight: 1080
            ),
            runningConfigIDsAfterCommand: [],
            managedDisplaysAfterCommand: []
        )
        let commander = FakeVirtualDisplayCommander()
        commander.createError = DisplayRuntimeVirtualDisplayCreateCommandError(
            reason: "persistenceRecoveryFailed",
            result: failedResult
        )
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayIDs: [], mainDisplayID: nil)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: .empty),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        await #expect(throws: DisplayRuntimeVirtualDisplayCreateCommandError.self) {
            _ = try await runtime.createVirtualDisplay(
                request: createRequest(displayName: "Rollback Failure", serialNumber: 9402),
                source: .createVirtualDisplaySheet
            )
        }
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)
        #expect(trace.status == .failed)
        #expect(trace.failure?.reason == "persistenceRecoveryFailed")
        #expect(trace.persistenceOutcome == .rollbackFailed)
        #expect(trace.runtimeCreationOutcome == .failed)
        #expect(trace.rollbackOutcome == .rollbackFailed)
    }

    @Test func createTopologyUnprovableAfterCommandSuccessCompletesWithRecoveryFailures() async throws {
        let createdConfigID = UUID()
        let catalogProvider = FakeCatalogProvider(
            snapshot: .init(
                hasScreenCapturePermission: false,
                lastPreflightPermission: false,
                lastRequestPermission: nil,
                isLoadingDisplays: false,
                hasLoadError: false,
                lastLoadError: nil,
                loadedDisplays: [],
                topologySignature: []
            )
        )
        let virtualDisplayProvider = FakeVirtualDisplayProvider(snapshot: .empty)
        let commander = FakeVirtualDisplayCommander()
        commander.createResult = .init(
            transactionID: DisplayRuntimeTransactionID(),
            createdConfigID: createdConfigID,
            serialNumber: 9403,
            targetWasRunningAfterCommand: true,
            preDisplayID: nil,
            postDisplayID: 78,
            persistenceOutcome: .saved,
            runtimeCreationOutcome: .succeeded,
            rollbackOutcome: .notAttempted,
            createdConfigEvidence: .init(
                id: createdConfigID,
                serialNumber: 9403,
                desiredEnabled: true,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modeCount: 1,
                maximumPixelWidth: 1920,
                maximumPixelHeight: 1080
            ),
            runningConfigIDsAfterCommand: [createdConfigID],
            managedDisplaysAfterCommand: [
                .init(configID: createdConfigID, serialNumber: 9403, displayID: 78, isLiveRuntime: true)
            ]
        )
        commander.onCreate = { _ in
            virtualDisplayProvider.setSnapshot(virtualDisplaySnapshot(configID: createdConfigID, displayID: 78))
        }
        let runtime = DisplayRuntime(
            catalogProvider: catalogProvider,
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.createVirtualDisplay(
            request: createRequest(displayName: "Permission Hidden", serialNumber: 9403),
            source: .createVirtualDisplaySheet
        )

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(result.runtimeCreationOutcome == .succeeded)
        #expect(result.topologyStabilityResult?.status == .unprovableDueToPermission)
    }

    @Test func deleteTransactionQuiescesBeforeCommandAndSkipsDeletedTargetRestore() async throws {
        let configID = UUID()
        let displayID: DisplayRuntimeDisplayID = 88
        let recorder = RuntimeOperationRecorder()
        let virtualDisplayProvider = FakeVirtualDisplayProvider(
            snapshot: virtualDisplaySnapshot(configID: configID, displayID: displayID)
        )
        let catalogProvider = FakeCatalogProvider(
            snapshot: catalogSnapshot(displayIDs: [displayID], mainDisplayID: displayID)
        )
        let commander = FakeVirtualDisplayCommander(recorder: recorder)
        commander.onDelete = { _ in
            virtualDisplayProvider.setSnapshot(.empty)
            catalogProvider.setSnapshot(catalogSnapshot(displayIDs: [], mainDisplayID: nil))
        }
        let runtime = DisplayRuntime(
            catalogProvider: catalogProvider,
            captureProvider: FakeCaptureProvider(snapshot: monitoringCaptureSnapshot(displayID: displayID, capturesCursor: true)),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: displayID)),
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(recorder: recorder),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureCommander: FakeCaptureCommander(recorder: recorder),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.deleteVirtualDisplay(
            configID: configID,
            source: .deleteVirtualDisplayConfirmation
        )
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completed)
        #expect(result.targetWasRunning)
        #expect(result.runtimeTrackingClearOutcome == .cleared)
        #expect(trace.kind == .virtualDisplayDelete)
        #expect(trace.source == .deleteVirtualDisplayConfirmation)
        #expect(trace.targetConfigID == configID)
        #expect(trace.restoreResults.allSatisfy { $0.failureReason == "target_deleted" })
        #expect(recorder.events.firstIndex(of: "stopSharing:\(displayID)")! < recorder.events.firstIndex(of: "delete:\(configID.uuidString)")!)
        #expect(recorder.events.firstIndex(of: "removeMonitoring:\(displayID)")! < recorder.events.firstIndex(of: "delete:\(configID.uuidString)")!)
    }

    @Test func deleteMissingConfigRecordsFailedTraceWithoutCommand() async throws {
        let missingID = UUID()
        let commander = FakeVirtualDisplayCommander()
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: .empty),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = try await runtime.deleteVirtualDisplay(
            configID: missingID,
            source: .deleteVirtualDisplayConfirmation
        )
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .failed)
        #expect(trace.failure?.reason == "config_not_found")
        #expect(trace.targetConfigID == missingID)
        #expect(trace.virtualDisplayCommandOutcome == .notAttempted)
        #expect(commander.deleteCallCount == 0)
    }

    @Test func deleteCommandFailureDoesNotMapMissingConfigToSuccess() async throws {
        let configID = UUID()
        let failedResult = DisplayRuntimeVirtualDisplayDeleteCommandResult(
            transactionID: DisplayRuntimeTransactionID(),
            configID: configID,
            targetWasRunning: false,
            preDisplayID: nil,
            postDisplayID: nil,
            persistenceOutcome: .notAttempted,
            virtualDisplayCommandOutcome: .failed,
            runtimeTrackingClearOutcome: .notAttempted,
            runningConfigIDsAfterCommand: [],
            managedDisplaysAfterCommand: []
        )
        let commander = FakeVirtualDisplayCommander()
        commander.deleteError = DisplayRuntimeVirtualDisplayDeleteCommandError(
            reason: "config_not_found",
            result: failedResult
        )
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 9404)
            ),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        await #expect(throws: DisplayRuntimeVirtualDisplayDeleteCommandError.self) {
            _ = try await runtime.deleteVirtualDisplay(
                configID: configID,
                source: .deleteVirtualDisplayConfirmation
            )
        }
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)
        #expect(trace.status == .failed)
        #expect(trace.failure?.reason == "config_not_found")
        #expect(trace.persistenceOutcome == .notAttempted)
        #expect(trace.runtimeTrackingClearOutcome == .notAttempted)
    }

    @Test func snapshotProviderUsesRuntimeKeyAndEncodesSnapshot() async throws {
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(
                snapshot: .init(
                    hasScreenCapturePermission: false,
                    lastPreflightPermission: false,
                    lastRequestPermission: false,
                    isLoadingDisplays: false,
                    hasLoadError: true,
                    lastLoadError: .init(
                        domain: "ScreenCapture",
                        code: 1,
                        hasDescription: true,
                        hasFailureReason: false,
                        hasRecoverySuggestion: false
                    ),
                    loadedDisplays: [],
                    topologySignature: []
                )
            )
        )
        let provider = DisplayRuntimeSnapshotProvider(runtime: runtime)
        let erased = AnyObservabilitySnapshotProvider(provider)

        let json = try await erased.makeSnapshot()
        let snapshot = try json.decode(DisplayRuntimeSnapshot.self)

        #expect(erased.key == "runtime")
        #expect(snapshot.catalog.hasScreenCapturePermission == false)
        #expect(snapshot.catalog.lastLoadError?.domain == "ScreenCapture")
    }

    @Test func observabilityCenterIncludesRuntimeSection() async throws {
        let isolationID = "display-runtime-\(UUID().uuidString)"
        let environment = [
            PersistenceContext.persistenceModeEnvironmentKey: PersistenceContext.testIsolatedModeValue,
            PersistenceContext.testIsolationIDEnvironmentKey: isolationID,
            PersistenceContext.xCTestConfigurationEnvironmentKey: "tests.xctest"
        ]
        let persistenceContext = PersistenceContext.resolve(environment: environment)
        defer { try? FileManager.default.removeItem(at: persistenceContext.appSupportRootURL) }

        let sanitizer = ObservabilitySanitizer()
        let observability = ObservabilityCenter(
            eventStore: EventStore(directoryURL: persistenceContext.observabilityEventsDirectoryURL),
            issueStore: IssueStore(fileURL: persistenceContext.observabilityIssuesURL),
            snapshotWriter: AgentSnapshotWriter(
                currentStateURL: persistenceContext.observabilityCurrentStateURL,
                healthSummaryURL: persistenceContext.observabilityHealthSummaryURL,
                recentEventsURL: persistenceContext.observabilityRecentEventsURL,
                debounceDuration: .zero
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
        let runtime = DisplayRuntime()

        await observability.registerSnapshotProvider(
            AnyObservabilitySnapshotProvider(DisplayRuntimeSnapshotProvider(runtime: runtime))
        )
        await observability.refreshSnapshot(reason: .manualDiagnosticsRefresh)
        let diagnostics = await observability.diagnosticsSnapshot()

        let runtimeSection = try #require(diagnostics.state.sections["runtime"])
        let snapshot = try runtimeSection.decode(DisplayRuntimeSnapshot.self)
        #expect(snapshot == .empty)
    }
}

private func catalogSnapshot(displayID: DisplayRuntimeDisplayID, isMain: Bool) -> DisplayRuntimeCatalogSnapshot {
    .init(
        hasScreenCapturePermission: true,
        lastPreflightPermission: true,
        lastRequestPermission: nil,
        isLoadingDisplays: false,
        hasLoadError: false,
        lastLoadError: nil,
        loadedDisplays: [.init(displayID: displayID, pixelWidth: 1920, pixelHeight: 1080)],
        topologySignature: [
            .init(
                displayID: displayID,
                isMain: isMain,
                pixelWidth: 1920,
                pixelHeight: 1080,
                refreshRateMilliHertz: 60_000,
                mirrorsDisplayID: nil
            )
        ]
    )
}

private func catalogSnapshot(
    displayIDs: [DisplayRuntimeDisplayID],
    mainDisplayID: DisplayRuntimeDisplayID?
) -> DisplayRuntimeCatalogSnapshot {
    .init(
        hasScreenCapturePermission: true,
        lastPreflightPermission: true,
        lastRequestPermission: nil,
        isLoadingDisplays: false,
        hasLoadError: false,
        lastLoadError: nil,
        loadedDisplays: displayIDs.map {
            .init(displayID: $0, pixelWidth: 1920, pixelHeight: 1080)
        },
        topologySignature: displayIDs.map {
            .init(
                displayID: $0,
                isMain: $0 == mainDisplayID,
                pixelWidth: 1920,
                pixelHeight: 1080,
                refreshRateMilliHertz: 60_000,
                mirrorsDisplayID: nil
            )
        }
    )
}

private func activeSharingSnapshot(displayID: DisplayRuntimeDisplayID) -> DisplayRuntimeSharingSnapshot {
    .init(
        activeSharingDisplayIDs: [displayID],
        startingDisplayIDs: [],
        isSharing: true,
        isWebServiceRunning: true,
        preferredPort: 8089,
        sharingClientCount: 1,
        sharingClientCounts: [.init(displayID: displayID, count: 1)],
        lifecycle: .init(
            phase: .running,
            requestedPort: 8089,
            boundPort: 8089,
            failureReason: nil,
            hasFailureMessage: false
        ),
        routes: [.init(displayID: displayID, hasConcreteRoute: true)]
    )
}

private func stoppedSharingSnapshot(previousDisplayID: DisplayRuntimeDisplayID) -> DisplayRuntimeSharingSnapshot {
    .init(
        activeSharingDisplayIDs: [],
        startingDisplayIDs: [],
        isSharing: false,
        isWebServiceRunning: false,
        preferredPort: 8089,
        sharingClientCount: 0,
        sharingClientCounts: [],
        lifecycle: .init(
            phase: .stopped,
            requestedPort: nil,
            boundPort: nil,
            failureReason: nil,
            hasFailureMessage: false
        ),
        routes: [.init(displayID: previousDisplayID, hasConcreteRoute: false)]
    )
}

private func monitoringCaptureSnapshot(
    displayID: DisplayRuntimeDisplayID,
    capturesCursor: Bool
) -> DisplayRuntimeCaptureSnapshot {
    .init(
        startingDisplayIDs: [],
        sessions: [
            .init(
                id: UUID(),
                displayID: displayID,
                isVirtualDisplay: true,
                capturesCursor: capturesCursor,
                state: .active,
                metrics: .empty
            )
        ]
    )
}

private func visibleDisplays(from catalog: DisplayRuntimeCatalogSnapshot) -> [DisplayRuntimeVisibleDisplay] {
    catalog.loadedDisplays.map {
        DisplayRuntimeVisibleDisplay(
            displayID: $0.displayID,
            pixelWidth: $0.pixelWidth,
            pixelHeight: $0.pixelHeight
        )
    }
}

private func fastTopologyWaitPolicy(maximumSampleCount: Int = 3) -> DisplayRuntimeTopologyWaitPolicy {
    .init(
        requiredStableSampleCount: 2,
        maximumSampleCount: maximumSampleCount,
        sampleIntervalNanoseconds: 0
    )
}

private func createRequest(
    displayName: String,
    serialNumber: UInt32
) -> DisplayRuntimeVirtualDisplayCreateRequest {
    .init(
        displayName: displayName,
        serialNumber: serialNumber,
        physicalWidthMillimeters: 600,
        physicalHeightMillimeters: 340,
        maximumPixelWidth: 1920,
        maximumPixelHeight: 1080,
        modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
        source: .createVirtualDisplaySheet
    )
}

private func virtualDisplaySnapshot(
    configID: UUID,
    displayID: DisplayRuntimeDisplayID
) -> DisplayRuntimeVirtualDisplaySnapshot {
    virtualDisplaySnapshot(configs: [(configID, 9001, displayID)])
}

private func editConfigDTO(
    id: UUID,
    displayName: String,
    serial: UInt32,
    desiredEnabled: Bool = true,
    physicalWidthMillimeters: UInt32 = 600,
    physicalHeightMillimeters: UInt32 = 340,
    modes: [DisplayRuntimeVirtualDisplayModeDTO] = [
        .init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)
    ]
) -> DisplayRuntimeVirtualDisplayConfigEditDTO {
    let maximumPixelDimensions = maximumPixelDimensions(for: modes)
    return DisplayRuntimeVirtualDisplayConfigEditDTO(
        id: id,
        displayName: displayName,
        serialNumber: serial,
        desiredEnabled: desiredEnabled,
        physicalWidthMillimeters: physicalWidthMillimeters,
        physicalHeightMillimeters: physicalHeightMillimeters,
        modes: modes,
        maximumPixelWidth: maximumPixelDimensions.width,
        maximumPixelHeight: maximumPixelDimensions.height
    )
}

private func maximumPixelDimensions(
    for modes: [DisplayRuntimeVirtualDisplayModeDTO]
) -> (width: UInt32, height: UInt32) {
    guard let maxMode = modes.max(by: { ($0.width * $0.height) < ($1.width * $1.height) }) else {
        return (0, 0)
    }
    let scale = modes.contains(where: \.enableHiDPI) ? 2 : 1
    return (
        UInt32(clamping: maxMode.width * scale),
        UInt32(clamping: maxMode.height * scale)
    )
}

private func disabledVirtualDisplaySnapshot(
    configID: UUID,
    serial: UInt32,
    desiredEnabled: Bool = false
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        rebuildRequestCount: 0,
        rebuildingConfigIDs: [],
        runningConfigIDs: [],
        recentlyAppliedConfigIDs: [],
        rebuildFailureConfigIDs: [],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: [],
        configs: [
            .init(
                id: configID,
                serialNumber: serial,
                desiredEnabled: desiredEnabled,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        ],
        restoreFailureConfigIDs: []
    )
}

private func runningVirtualDisplaySnapshot(
    configID: UUID,
    serial: UInt32,
    displayID: DisplayRuntimeDisplayID,
    desiredEnabled: Bool
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        rebuildRequestCount: 0,
        rebuildingConfigIDs: [],
        runningConfigIDs: [configID],
        recentlyAppliedConfigIDs: [],
        rebuildFailureConfigIDs: [],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: [
            .init(configID: configID, serialNumber: serial, displayID: displayID, isLiveRuntime: true)
        ],
        configs: [
            .init(
                id: configID,
                serialNumber: serial,
                desiredEnabled: desiredEnabled,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        ],
        restoreFailureConfigIDs: []
    )
}

private func mixedVirtualDisplaySnapshot(
    disabled: (UUID, UInt32),
    running: [(UUID, UInt32, DisplayRuntimeDisplayID)]
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        rebuildRequestCount: 0,
        rebuildingConfigIDs: [],
        runningConfigIDs: running.map(\.0),
        recentlyAppliedConfigIDs: [],
        rebuildFailureConfigIDs: [],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: running.map {
            .init(configID: $0.0, serialNumber: $0.1, displayID: $0.2, isLiveRuntime: true)
        },
        configs: [
            .init(
                id: disabled.0,
                serialNumber: disabled.1,
                desiredEnabled: false,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        ] + running.map {
            .init(
                id: $0.0,
                serialNumber: $0.1,
                desiredEnabled: true,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        },
        restoreFailureConfigIDs: []
    )
}

private func virtualDisplaySnapshot(
    configs: [(UUID, UInt32, DisplayRuntimeDisplayID)]
) -> DisplayRuntimeVirtualDisplaySnapshot {
    .init(
        rebuildRequestCount: 0,
        rebuildingConfigIDs: [],
        runningConfigIDs: configs.map(\.0),
        recentlyAppliedConfigIDs: [],
        rebuildFailureConfigIDs: [],
        configStoreHasLoadFailure: false,
        configStoreHasDiagnostics: false,
        managedDisplays: configs.map {
            .init(configID: $0.0, serialNumber: $0.1, displayID: $0.2, isLiveRuntime: true)
        },
        configs: configs.map {
            .init(
                id: $0.0,
                serialNumber: $0.1,
                desiredEnabled: true,
                physicalWidthMillimeters: 600,
                physicalHeightMillimeters: 340,
                modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)]
            )
        },
        restoreFailureConfigIDs: []
    )
}

@MainActor
private final class RuntimeOperationRecorder {
    var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

@MainActor
private final class FakeCatalogProvider: DisplayRuntimeCatalogProviding {
    private var snapshot: DisplayRuntimeCatalogSnapshot

    init(snapshot: DisplayRuntimeCatalogSnapshot) {
        self.snapshot = snapshot
    }

    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        snapshot
    }

    func setSnapshot(_ snapshot: DisplayRuntimeCatalogSnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
private final class FakeCaptureProvider: DisplayRuntimeCaptureProviding {
    let snapshot: DisplayRuntimeCaptureSnapshot

    init(snapshot: DisplayRuntimeCaptureSnapshot) {
        self.snapshot = snapshot
    }

    func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot {
        snapshot
    }
}

@MainActor
private final class FakeSharingProvider: DisplayRuntimeSharingProviding {
    private var snapshot: DisplayRuntimeSharingSnapshot

    init(snapshot: DisplayRuntimeSharingSnapshot) {
        self.snapshot = snapshot
    }

    func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        snapshot
    }

    func setSnapshot(_ snapshot: DisplayRuntimeSharingSnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
private final class FakeVirtualDisplayProvider: DisplayRuntimeVirtualDisplayProviding {
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
private final class FakeCatalogCommander: DisplayRuntimeCatalogCommanding {
    private let recorder: RuntimeOperationRecorder?
    private let visibleDisplays: [DisplayRuntimeVisibleDisplay]
    private let onRefresh: (() -> Void)?
    private var refreshResults: [DisplayRuntimeCatalogRefreshResult]

    init(
        recorder: RuntimeOperationRecorder? = nil,
        refreshResults: [DisplayRuntimeCatalogRefreshResult] = [.reusedSnapshot],
        visibleDisplays: [DisplayRuntimeVisibleDisplay] = [],
        onRefresh: (() -> Void)? = nil
    ) {
        self.recorder = recorder
        self.refreshResults = refreshResults
        self.visibleDisplays = visibleDisplays
        self.onRefresh = onRefresh
    }

    func requestPermission() -> Bool {
        true
    }

    func refreshPermission() -> Bool {
        true
    }

    func submitRefresh(
        intent: DisplayRuntimeCatalogRefreshIntent,
        ownerScope _: DisplayRuntimeCatalogRefreshOwnerScope?
    ) async -> DisplayRuntimeCatalogRefreshResult {
        recorder?.append("refresh:\(intent.rawValue)")
        onRefresh?()
        if refreshResults.count > 1 {
            return refreshResults.removeFirst()
        }
        return refreshResults.first ?? .reusedSnapshot
    }

    func clearSnapshotForDeniedPermission(loadErrorMessage _: String?) async {}

    func cancelRefresh(ownerScope _: DisplayRuntimeCatalogRefreshOwnerScope?) async {}

    func currentVisibleDisplays() -> [DisplayRuntimeVisibleDisplay] {
        visibleDisplays
    }
}

@MainActor
private final class FakeSharingCommander: DisplayRuntimeSharingCommanding {
    private let recorder: RuntimeOperationRecorder?
    private let restoreResult: DisplayRuntimeSharingRestoreCommandResult
    private(set) var restoredDisplayIDs: [DisplayRuntimeDisplayID] = []

    init(
        recorder: RuntimeOperationRecorder? = nil,
        restoreResult: DisplayRuntimeSharingRestoreCommandResult = .restored
    ) {
        self.recorder = recorder
        self.restoreResult = restoreResult
    }

    func registerShareableDisplays(_ displays: [DisplayRuntimeShareableDisplayRegistration]) {
        let displayIDs = displays.map(\.displayID).sorted()
        recorder?.append("registerShareable:\(displayIDs.map(String.init).joined(separator: ","))")
    }

    func stopSharing(displayID: DisplayRuntimeDisplayID) {
        recorder?.append("stopSharing:\(displayID)")
    }

    func restoreSharing(displayID: DisplayRuntimeDisplayID) async -> DisplayRuntimeSharingRestoreCommandResult {
        restoredDisplayIDs.append(displayID)
        recorder?.append("restoreSharing:\(displayID)")
        return restoreResult
    }
}

@MainActor
private final class FakeCaptureCommander: DisplayRuntimeCaptureCommanding {
    private let recorder: RuntimeOperationRecorder?

    init(recorder: RuntimeOperationRecorder? = nil) {
        self.recorder = recorder
    }

    func removeMonitoringSessions(displayID: DisplayRuntimeDisplayID) {
        recorder?.append("removeMonitoring:\(displayID)")
    }
}

@MainActor
private final class FakeVirtualDisplayCommander: DisplayRuntimeVirtualDisplayCommanding {
    private let recorder: RuntimeOperationRecorder?
    private let delayNanoseconds: UInt64
    var rebuildCallCount = 0
    var rebuildConfigIDs: [UUID] = []
    var preflightCallCount = 0
    var setDesiredEnabledCallCount = 0
    var setDesiredEnabledRequests: [(UUID, Bool)] = []
    var saveConfigForRebuildCallCount = 0
    var saveConfigForRebuildRequests: [DisplayRuntimeVirtualDisplayEditRebuildRequest] = []
    var restoreConfigAfterFailedEditCallCount = 0
    var restoredConfigsAfterFailedEdit: [DisplayRuntimeVirtualDisplayConfigEditDTO] = []
    var enableCallCount = 0
    var enableConfigIDs: [UUID] = []
    var disableCallCount = 0
    var disableConfigIDs: [UUID] = []
    var createCallCount = 0
    var createRequests: [DisplayRuntimeVirtualDisplayCreateRequest] = []
    var deleteCallCount = 0
    var deleteRequests: [DisplayRuntimeVirtualDisplayDeleteCommandRequest] = []
    var enablePreflight: DisplayRuntimeVirtualDisplayEnablePreflight?
    var setDesiredEnabledError: Error?
    var saveConfigForRebuildError: Error?
    var restoreConfigAfterFailedEditError: Error?
    var saveConfigForRebuildResult: DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult?
    var restoreConfigAfterFailedEditResult: DisplayRuntimeVirtualDisplayPersistenceCommandResult?
    var createResult: DisplayRuntimeVirtualDisplayCreateCommandResult?
    var deleteResult: DisplayRuntimeVirtualDisplayDeleteCommandResult?
    var enableError: Error?
    var disableError: Error?
    var createError: Error?
    var deleteError: Error?
    var onSetDesiredEnabled: ((UUID, Bool) -> Void)?
    var onSaveConfigForRebuild: ((DisplayRuntimeVirtualDisplayEditRebuildRequest) -> Void)?
    var onRestoreConfigAfterFailedEdit: ((DisplayRuntimeVirtualDisplayConfigEditDTO) -> Void)?
    var onEnable: ((UUID) -> Void)?
    var onDisable: ((UUID) -> Void)?
    var onCreate: ((DisplayRuntimeVirtualDisplayCreateRequest) -> Void)?
    var onDelete: ((DisplayRuntimeVirtualDisplayDeleteCommandRequest) -> Void)?
    var error: Error?
    var scriptedRebuildErrors: [Error?] = []

    init(
        recorder: RuntimeOperationRecorder? = nil,
        delayNanoseconds: UInt64 = 0
    ) {
        self.recorder = recorder
        self.delayNanoseconds = delayNanoseconds
    }

    func rebuildVirtualDisplay(configID: UUID) async throws -> DisplayRuntimeVirtualDisplayRebuildCommandResult {
        rebuildCallCount += 1
        rebuildConfigIDs.append(configID)
        recorder?.append("rebuild:\(configID.uuidString)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if !scriptedRebuildErrors.isEmpty {
            if let scriptedError = scriptedRebuildErrors.removeFirst() {
                throw scriptedError
            }
        } else if let error {
            throw error
        }
        return .init(
            configID: configID,
            preDisplayID: nil,
            postDisplayID: nil,
            runningConfigIDsAfterCommand: [configID],
            managedDisplaysAfterCommand: []
        )
    }

    func preflightEnableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEnablePreflight {
        preflightCallCount += 1
        recorder?.append("preflightEnable:\(request.configID.uuidString)")
        return enablePreflight ?? .init(
            configID: request.configID,
            targetPreDisplayID: request.targetPreDisplayID,
            mayPerformFleetRebuild: false,
            requiresFleetQuiesce: false,
            scopeEscalationReason: nil
        )
    }

    func setVirtualDisplayDesiredEnabled(
        request: DisplayRuntimeVirtualDisplayDesiredEnabledCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDesiredEnabledCommandResult {
        setDesiredEnabledCallCount += 1
        setDesiredEnabledRequests.append((request.configID, request.enabled))
        recorder?.append("setDesiredEnabled:\(request.configID.uuidString):\(request.enabled)")
        if let setDesiredEnabledError {
            throw setDesiredEnabledError
        }
        onSetDesiredEnabled?(request.configID, request.enabled)
        return .init(
            configID: request.configID,
            desiredEnabled: request.enabled,
            persistenceOutcome: .saved
        )
    }

    func saveConfigForRebuild(
        request: DisplayRuntimeVirtualDisplayEditRebuildRequest
    ) async throws -> DisplayRuntimeVirtualDisplayEditRebuildSaveCommandResult {
        saveConfigForRebuildCallCount += 1
        saveConfigForRebuildRequests.append(request)
        recorder?.append("saveConfigForRebuild:\(request.editedConfig.id.uuidString)")
        if let saveConfigForRebuildError {
            throw saveConfigForRebuildError
        }
        onSaveConfigForRebuild?(request)
        if let saveConfigForRebuildResult {
            return saveConfigForRebuildResult
        }
        return .init(
            configID: request.editedConfig.id,
            persistenceOutcome: .saved,
            previousConfigForCompensation: request.editedConfig,
            savedConfigEvidence: .init(config: request.editedConfig)
        )
    }

    func restoreConfigAfterFailedEdit(
        request: DisplayRuntimeVirtualDisplayEditRebuildRestoreCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayPersistenceCommandResult {
        restoreConfigAfterFailedEditCallCount += 1
        restoredConfigsAfterFailedEdit.append(request.previousConfigForCompensation)
        recorder?.append("restoreConfigAfterFailedEdit:\(request.previousConfigForCompensation.id.uuidString)")
        if let restoreConfigAfterFailedEditError {
            throw restoreConfigAfterFailedEditError
        }
        onRestoreConfigAfterFailedEdit?(request.previousConfigForCompensation)
        return restoreConfigAfterFailedEditResult ?? .init(
            configID: request.previousConfigForCompensation.id,
            persistenceOutcome: .rolledBack
        )
    }

    func enableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
        enableCallCount += 1
        enableConfigIDs.append(request.configID)
        recorder?.append("enable:\(request.configID.uuidString)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let enableError {
            throw enableError
        }
        onEnable?(request.configID)
        return .init(
            configID: request.configID,
            desiredEnabled: true,
            preDisplayID: request.targetPreDisplayID,
            postDisplayID: request.targetPreDisplayID,
            runningConfigIDsAfterCommand: [request.configID],
            managedDisplaysAfterCommand: [],
            mayPerformFleetRebuild: enablePreflight?.mayPerformFleetRebuild,
            requiresFleetQuiesce: enablePreflight?.requiresFleetQuiesce
        )
    }

    func disableVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayLifecycleCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayLifecycleCommandResult {
        disableCallCount += 1
        disableConfigIDs.append(request.configID)
        recorder?.append("disable:\(request.configID.uuidString)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let disableError {
            throw disableError
        }
        onDisable?(request.configID)
        return .init(
            configID: request.configID,
            desiredEnabled: false,
            preDisplayID: request.targetPreDisplayID,
            postDisplayID: nil,
            runningConfigIDsAfterCommand: [],
            managedDisplaysAfterCommand: [],
            mayPerformFleetRebuild: false,
            requiresFleetQuiesce: false
        )
    }

    func createVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayCreateRequest
    ) async throws -> DisplayRuntimeVirtualDisplayCreateCommandResult {
        createCallCount += 1
        createRequests.append(request)
        recorder?.append("create:\(request.serialNumber)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let createError {
            throw createError
        }
        onCreate?(request)
        if let createResult {
            return createResult
        }
        let createdConfigID = UUID()
        return .init(
            transactionID: request.transactionID,
            createdConfigID: createdConfigID,
            serialNumber: request.serialNumber,
            targetWasRunningAfterCommand: true,
            preDisplayID: nil,
            postDisplayID: 9001,
            persistenceOutcome: .saved,
            runtimeCreationOutcome: .succeeded,
            rollbackOutcome: .notAttempted,
            createdConfigEvidence: .init(
                id: createdConfigID,
                serialNumber: request.serialNumber,
                desiredEnabled: true,
                physicalWidthMillimeters: request.physicalWidthMillimeters,
                physicalHeightMillimeters: request.physicalHeightMillimeters,
                modeCount: request.modes.count,
                maximumPixelWidth: request.maximumPixelWidth,
                maximumPixelHeight: request.maximumPixelHeight
            ),
            runningConfigIDsAfterCommand: [createdConfigID],
            managedDisplaysAfterCommand: [
                .init(
                    configID: createdConfigID,
                    serialNumber: request.serialNumber,
                    displayID: 9001,
                    isLiveRuntime: true
                )
            ]
        )
    }

    func deleteVirtualDisplay(
        request: DisplayRuntimeVirtualDisplayDeleteCommandRequest
    ) async throws -> DisplayRuntimeVirtualDisplayDeleteCommandResult {
        deleteCallCount += 1
        deleteRequests.append(request)
        recorder?.append("delete:\(request.configID.uuidString)")
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if let deleteError {
            throw deleteError
        }
        onDelete?(request)
        return deleteResult ?? .init(
            transactionID: request.transactionID,
            configID: request.configID,
            targetWasRunning: request.targetWasRunning,
            preDisplayID: request.targetPreDisplayID,
            postDisplayID: nil,
            persistenceOutcome: .saved,
            virtualDisplayCommandOutcome: .succeeded,
            runtimeTrackingClearOutcome: .cleared,
            runningConfigIDsAfterCommand: [],
            managedDisplaysAfterCommand: []
        )
    }
}
