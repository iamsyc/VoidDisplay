@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeRebuildTransactionTests {
    @Test func rebuildTransactionQuiescesSessionsBeforeVirtualDisplayCommand() async throws {
        let configID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let sessionID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let recorder = RuntimeOperationRecorder()
        let catalog = catalogSnapshot(displayID: 77, isMain: false)
        let captureIntentCommander = FakeCaptureIntentCommander(recorder: recorder)
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
            captureIntentCommander: captureIntentCommander,
            virtualDisplayCommander: FakeVirtualDisplayCommander(recorder: recorder),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )
        let surfaceIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand(capturesCursor: true)
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )
        recorder.events.removeAll()

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .virtualDisplayRowRetry)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completed)
        #expect(!result.hasSessionRecoveryFailures)
        #expect(recorder.events == [
            "refresh:topologyChanged",
            "applyLAN:drain",
            "applyPreview:drain",
            "rebuild:\(configID.uuidString)",
            "refresh:topologyChanged",
            "refresh:topologyChanged",
            "registerShareable:77",
            "applyLAN:capture",
            "applyPreview:capture"
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
                pausePreview: true
            )
        ])
        #expect(trace.restoreIntents == [
            .init(
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                previousDisplayID: 77,
                resolvedDisplayID: 77,
                restoreSharing: true,
                restorePreview: true,
                previewCapturesCursor: true
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
                kind: .preview,
                status: .restored,
                previousDisplayID: 77,
                resolvedDisplayID: 77,
                failureReason: nil
            )
        ])
        #expect(trace.compensation.status == .completed)
        #expect(trace.compensation.restoredSharingCount == 1)
        #expect(trace.compensation.restoredPreviewCount == 1)
        #expect(trace.compensation.failedRestoreCount == 0)
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

    @Test func attachIsRejectedWhileSurfaceTransactionIsBusy() async throws {
        let configID = UUID(uuidString: "56565656-5656-5656-5656-565656565656")!
        let surfaceIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let catalog = catalogSnapshot(displayID: 56, isMain: false)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: virtualDisplaySnapshot(configID: configID, displayID: 56)
            ),
            catalogCommander: FakeCatalogCommander(visibleDisplays: visibleDisplays(from: catalog)),
            captureIntentCommander: FakeCaptureIntentCommander(),
            virtualDisplayCommander: FakeVirtualDisplayCommander(delayNanoseconds: 100_000_000),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )
        let transaction = Task { @MainActor in
            try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        }
        for _ in 0..<1_000 where !runtime.isConsumerTransitionBusy(surfaceIdentity: surfaceIdentity) {
            await Task.yield()
        }

        let outcome = await runtime.attachPreviewConsumer(
            surfaceIdentity: surfaceIdentity,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )

        #expect(outcome == .rejected(
            failureCode: DisplayRuntimeCaptureIntentFailureCode.consumerLeaseRestarting
        ))
        _ = try await transaction.value
        #expect(!runtime.isConsumerTransitionBusy(surfaceIdentity: surfaceIdentity))
        #expect(runtime.currentConsumerLeaseSnapshot().isEmpty)
    }

    @Test func commandFailureCompensatesExistingPreviewLease() async throws {
        let configID = UUID(uuidString: "57575757-5757-5757-5757-575757575758")!
        let surfaceIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let catalog = catalogSnapshot(displayID: 57, isMain: false)
        let commander = FakeVirtualDisplayCommander()
        commander.error = NSError(domain: "Rebuild", code: 57)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: virtualDisplaySnapshot(configID: configID, displayID: 57)
            ),
            catalogCommander: FakeCatalogCommander(visibleDisplays: visibleDisplays(from: catalog)),
            captureIntentCommander: FakeCaptureIntentCommander(),
            virtualDisplayCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand(capturesCursor: true)
        )

        await #expect(throws: (any Error).self) {
            try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        }

        let restoredLease = runtime.consumerLease(leaseID: lease.id)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)
        #expect(restoredLease?.state == .attached)
        #expect(restoredLease?.resolvedDisplayID == 57)
        #expect(restoredLease?.surfaceEpoch.rawValue == 2)
        #expect(trace.restoreResults.first?.status == .restored)
        #expect(trace.compensation.status == .completed)
        #expect(!runtime.isConsumerTransitionBusy(surfaceIdentity: surfaceIdentity))
    }

    @Test func quiesceFailureCompensatesLeaseAndSkipsVirtualDisplayCommand() async throws {
        let configID = UUID(uuidString: "C0C0C0C0-C0C0-C0C0-C0C0-C0C0C0C0C0C0")!
        let catalog = catalogSnapshot(displayID: 103, isMain: false)
        let captureIntentCommander = FakeCaptureIntentCommander { intent in
            if intent.reason == .transactionQuiesce {
                return .failed(
                    revision: intent.revision,
                    failureCode: DisplayRuntimeCaptureIntentFailureCode.applyFailed
                )
            }
            return .applied(revision: intent.revision)
        }
        let virtualDisplayCommander = FakeVirtualDisplayCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: virtualDisplaySnapshot(configID: configID, displayID: 103)
            ),
            catalogCommander: FakeCatalogCommander(visibleDisplays: visibleDisplays(from: catalog)),
            captureIntentCommander: captureIntentCommander,
            virtualDisplayCommander: virtualDisplayCommander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )
        let surfaceIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .failed)
        #expect(result.virtualDisplayCommandSucceeded == false)
        #expect(virtualDisplayCommander.rebuildCallCount == 0)
        #expect(trace.failure?.phase == .quiescingSessions)
        #expect(trace.failure?.reason == "consumer_session_quiesce_failed")
        #expect(trace.compensation.status == .completed)
        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .attached)
        #expect(runtime.isConsumerTransitionBusy(surfaceIdentity: surfaceIdentity) == false)
        #expect(captureIntentCommander.intents.map(\.reason) == [
            .attach,
            .transactionQuiesce,
            .epochChanged
        ])
    }
    @Test func rebuildTransactionDeduplicatesManagedDisplayEntriesBeforeQuiesce() async throws {
        let configID = UUID(uuidString: "58585858-5858-5858-5858-585858585858")!
        let sessionID = UUID(uuidString: "59595959-5959-5959-5959-595959595959")!
        let recorder = RuntimeOperationRecorder()
        let catalog = catalogSnapshot(displayID: 58, isMain: false)
        let captureIntentCommander = FakeCaptureIntentCommander(recorder: recorder)
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
            captureIntentCommander: captureIntentCommander,
            virtualDisplayCommander: FakeVirtualDisplayCommander(recorder: recorder),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )
        let surfaceIdentity = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .preview,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surfaceIdentity,
            kind: .lanWebView,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )
        recorder.events.removeAll()

        _ = try await runtime.rebuildVirtualDisplay(configID: configID, source: .virtualDisplayRowRetry)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(trace.affectedSurfaces.map(\.configID) == [configID])
        #expect(trace.pauseIntents == [
            .init(
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                displayID: 58,
                pauseSharing: true,
                pausePreview: true
            )
        ])
        #expect(recorder.events == [
            "refresh:topologyChanged",
            "applyLAN:drain",
            "applyPreview:drain",
            "rebuild:\(configID.uuidString)",
            "refresh:topologyChanged",
            "refresh:topologyChanged",
            "registerShareable:58",
            "applyLAN:capture",
            "applyPreview:capture"
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
                    runningConfigIDs: [],
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
    @Test func rebuildTransactionMarksRecoveryFailureWhenSharingRestoreFails() async throws {
        let configID = UUID(uuidString: "D1D1D1D1-D1D1-D1D1-D1D1-D1D1D1D1D1D1")!
        let catalog = catalogSnapshot(displayID: 101, isMain: false)
        let captureIntentCommander = FakeCaptureIntentCommander { intent in
            if intent.kind == .capture, intent.reason == .epochChanged {
                return .failed(revision: intent.revision, failureCode: "display_not_found")
            }
            return .applied(revision: intent.revision)
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 101)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 101)),
            catalogCommander: FakeCatalogCommander(visibleDisplays: visibleDisplays(from: catalog)),
            captureIntentCommander: captureIntentCommander,
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: .managedVirtualDisplay(configID: configID),
            kind: .lanWebView,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(result.virtualDisplayCommandSucceeded)
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
        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .failed)
        #expect(trace.failure == nil)
    }
    @Test func rebuildTransactionMarksRecoveryFailureWhenSharingRestoreInvalidates() async throws {
        let configID = UUID(uuidString: "D2D2D2D2-D2D2-D2D2-D2D2-D2D2D2D2D2D2")!
        let catalog = catalogSnapshot(displayID: 102, isMain: false)
        let captureIntentCommander = FakeCaptureIntentCommander { intent in
            if intent.kind == .capture, intent.reason == .epochChanged {
                return DisplayRuntimeCaptureIntentApplyResult(
                    revision: intent.revision,
                    outcome: .ignored,
                    failureCode: "sharing_start_invalidated"
                )
            }
            return .applied(revision: intent.revision)
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 102)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 102)),
            catalogCommander: FakeCatalogCommander(visibleDisplays: visibleDisplays(from: catalog)),
            captureIntentCommander: captureIntentCommander,
            virtualDisplayCommander: FakeVirtualDisplayCommander(),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )
        _ = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: .managedVirtualDisplay(configID: configID),
            kind: .lanWebView,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithRecoveryFailures)
        #expect(trace.restoreResults.first?.status == .invalidated)
        #expect(trace.restoreResults.first?.failureReason == "sharing_start_invalidated")
        #expect(trace.compensation.status == .degraded)
        #expect(trace.failure == nil)
    }
    @Test func detachingLANConsumerPreservesPreviewDemand() async throws {
        let configID = UUID(uuidString: "D3D3D3D3-D3D3-D3D3-D3D3-D3D3D3D3D3D3")!
        let surface = DisplaySurfaceIdentity.managedVirtualDisplay(configID: configID)
        let captureIntentCommander = FakeCaptureIntentCommander()
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalogSnapshot(displayID: 104, isMain: false)),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 104)),
            captureIntentCommander: captureIntentCommander
        )
        let previewLease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surface,
            kind: .preview,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )
        let lanLease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: surface,
            kind: .lanWebView,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand()
        )

        _ = await runtime.detachLANWebViewConsumer(surfaceIdentity: surface)

        #expect(runtime.consumerLease(leaseID: previewLease.id)?.state == .attached)
        #expect(runtime.consumerLease(leaseID: lanLease.id)?.state == .released)
        #expect(runtime.currentAggregatedDemandSnapshot().first?.consumerKinds == [.preview])
        #expect(captureIntentCommander.intents.last?.kind == .capture)
        #expect(captureIntentCommander.intents.last?.aggregateDemand?.consumerKinds == [.preview])
    }
    @Test func rebuildTransactionRebindsPreviewUsingStableLeaseIdentity() async throws {
        let configID = UUID(uuidString: "D4D4D4D4-D4D4-D4D4-D4D4-D4D4D4D4D4D4")!
        let catalog = catalogSnapshot(displayID: 105, isMain: false)
        let recorder = RuntimeOperationRecorder()
        let captureIntentCommander = FakeCaptureIntentCommander(recorder: recorder)
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            captureProvider: FakeCaptureProvider(
                snapshot: previewCaptureSnapshot(displayID: 105, capturesCursor: true)
            ),
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 105)),
            catalogCommander: FakeCatalogCommander(
                recorder: recorder,
                visibleDisplays: visibleDisplays(from: catalog)
            ),
            captureIntentCommander: captureIntentCommander,
            virtualDisplayCommander: FakeVirtualDisplayCommander(recorder: recorder),
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )
        let lease = await attachConsumerForTesting(
            runtime,
            surfaceIdentity: .managedVirtualDisplay(configID: configID),
            kind: .preview,
            owner: .init(source: .runtimeTest),
            demand: runtimeConsumerDemand(capturesCursor: true)
        )
        recorder.events.removeAll()

        let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completed)
        #expect(!result.hasSessionRecoveryFailures)
        #expect(trace.topologyStabilityResult?.status == .stable)
        #expect(trace.restoreIntents == [
            .init(
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                previousDisplayID: 105,
                resolvedDisplayID: 105,
                restoreSharing: false,
                restorePreview: true,
                previewCapturesCursor: true
            )
        ])
        #expect(trace.restoreResults == [
            .init(
                kind: .preview,
                status: .restored,
                previousDisplayID: 105,
                resolvedDisplayID: 105,
                failureReason: nil
            )
        ])
        #expect(recorder.events == [
            "refresh:topologyChanged",
            "applyPreview:drain",
            "rebuild:\(configID.uuidString)",
            "refresh:topologyChanged",
            "refresh:topologyChanged",
            "applyPreview:capture"
        ])
        #expect(runtime.consumerLease(leaseID: lease.id)?.id == lease.id)
        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .attached)
        #expect(runtime.consumerLease(leaseID: lease.id)?.surfaceEpoch.rawValue == 2)
        #expect(trace.compensation.status == .completed)
        #expect(trace.compensation.restoredSharingCount == 0)
        #expect(trace.compensation.restoredPreviewCount == 1)
        #expect(trace.compensation.failedRestoreCount == 0)
        #expect(trace.failure == nil)
    }
    @Test func rebuildTransactionCompensatesSharingWhenTopologyCannotProveStable() async throws {
        struct Scenario {
            let expectedStatus: DisplayRuntimeTopologyStabilityStatus
            let catalog: DisplayRuntimeCatalogSnapshot
            let refreshResults: [DisplayRuntimeCatalogRefreshResult]
            let maximumSampleCount: Int
            let canResolveOldDisplay: Bool
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
                maximumSampleCount: 4,
                canResolveOldDisplay: false
            ),
            .init(
                expectedStatus: .failed,
                catalog: catalogSnapshot(displayID: 103, isMain: false),
                refreshResults: [.reusedSnapshot, .failed],
                maximumSampleCount: 4,
                canResolveOldDisplay: true
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
                maximumSampleCount: 2,
                canResolveOldDisplay: false
            )
        ]

        for scenario in scenarios {
            let configID = UUID()
            let captureIntentCommander = FakeCaptureIntentCommander()
            let runtime = DisplayRuntime(
                catalogProvider: FakeCatalogProvider(snapshot: scenario.catalog),
                sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: 103)),
                virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 103)),
                catalogCommander: FakeCatalogCommander(refreshResults: scenario.refreshResults),
                captureIntentCommander: captureIntentCommander,
                virtualDisplayCommander: FakeVirtualDisplayCommander(),
                topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: scenario.maximumSampleCount)
            )
            let lease = await attachConsumerForTesting(
                runtime,
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                kind: .lanWebView,
                owner: .init(source: .runtimeTest),
                demand: runtimeConsumerDemand()
            )

            let result = try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
            let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

            #expect(result.status == .completedWithRecoveryFailures)
            #expect(trace.topologyStabilityResult?.status == scenario.expectedStatus)
            if scenario.canResolveOldDisplay {
                #expect(trace.restoreResults == [
                    .init(
                        kind: .sharing,
                        status: .restored,
                        previousDisplayID: 103,
                        resolvedDisplayID: 103,
                        failureReason: nil
                    )
                ])
                #expect(trace.compensation.status == .degraded)
                #expect(trace.compensation.failedRestoreCount == 0)
                #expect(runtime.consumerLease(leaseID: lease.id)?.state == .attached)
            } else {
                #expect(trace.restoreResults == [
                    .init(
                        kind: .sharing,
                        status: .failed,
                        previousDisplayID: 103,
                        resolvedDisplayID: nil,
                        failureReason: "topology_\(scenario.expectedStatus.rawValue)"
                    )
                ])
                #expect(trace.compensation.status == .degraded)
                #expect(trace.compensation.failedRestoreCount == 1)
                #expect(runtime.consumerLease(leaseID: lease.id)?.state == .failed)
            }
            #expect(trace.failure == nil)
        }
    }
    @Test func rebuildTransactionCompensatesPreviewWhenTopologyCannotProveStable() async throws {
        struct Scenario {
            let expectedStatus: DisplayRuntimeTopologyStabilityStatus
            let catalog: DisplayRuntimeCatalogSnapshot
            let refreshResults: [DisplayRuntimeCatalogRefreshResult]
            let maximumSampleCount: Int
            let canResolveOldDisplay: Bool
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
                maximumSampleCount: 4,
                canResolveOldDisplay: false
            ),
            .init(
                expectedStatus: .failed,
                catalog: catalogSnapshot(displayID: 106, isMain: false),
                refreshResults: [.reusedSnapshot, .failed],
                maximumSampleCount: 4,
                canResolveOldDisplay: true
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
                maximumSampleCount: 2,
                canResolveOldDisplay: false
            )
        ]

        for scenario in scenarios {
            let configID = UUID()
            let recorder = RuntimeOperationRecorder()
            let captureIntentCommander = FakeCaptureIntentCommander(recorder: recorder)
            let runtime = DisplayRuntime(
                catalogProvider: FakeCatalogProvider(snapshot: scenario.catalog),
                captureProvider: FakeCaptureProvider(
                    snapshot: previewCaptureSnapshot(displayID: 106, capturesCursor: false)
                ),
                virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: virtualDisplaySnapshot(configID: configID, displayID: 106)),
                catalogCommander: FakeCatalogCommander(
                    recorder: recorder,
                    refreshResults: scenario.refreshResults
                ),
                captureIntentCommander: captureIntentCommander,
                virtualDisplayCommander: FakeVirtualDisplayCommander(recorder: recorder),
                topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: scenario.maximumSampleCount)
            )
            let lease = await attachConsumerForTesting(
                runtime,
                surfaceIdentity: .managedVirtualDisplay(configID: configID),
                kind: .preview,
                owner: .init(source: .runtimeTest),
                demand: runtimeConsumerDemand()
            )
            recorder.events.removeAll()

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
                    restorePreview: true,
                    previewCapturesCursor: false
                )
            ])
            #expect(recorder.events.contains("applyPreview:drain"))
            if scenario.canResolveOldDisplay {
                #expect(trace.restoreResults == [
                    .init(
                        kind: .preview,
                        status: .restored,
                        previousDisplayID: 106,
                        resolvedDisplayID: 106,
                        failureReason: nil
                    )
                ])
                #expect(recorder.events.contains("applyPreview:capture"))
                #expect(trace.compensation.status == .degraded)
                #expect(trace.compensation.restoredPreviewCount == 1)
                #expect(trace.compensation.failedRestoreCount == 0)
                #expect(runtime.consumerLease(leaseID: lease.id)?.state == .attached)
            } else {
                #expect(trace.restoreResults == [
                    .init(
                        kind: .preview,
                        status: .failed,
                        previousDisplayID: 106,
                        resolvedDisplayID: nil,
                        failureReason: "topology_\(scenario.expectedStatus.rawValue)"
                    )
                ])
                #expect(recorder.events.allSatisfy { $0 != "applyPreview:capture" })
                #expect(trace.compensation.status == .degraded)
                #expect(trace.compensation.restoredPreviewCount == 0)
                #expect(trace.compensation.failedRestoreCount == 1)
                #expect(runtime.consumerLease(leaseID: lease.id)?.state == .failed)
            }
            #expect(trace.failure == nil)
        }
    }
}
