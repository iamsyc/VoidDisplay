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
}
