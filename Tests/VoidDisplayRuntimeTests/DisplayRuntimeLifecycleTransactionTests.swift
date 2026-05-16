@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeLifecycleTransactionTests {
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
    @Test func enableTransactionRestoresPeerSharingAndDefersPeerPreviewAfterStableTopology() async throws {
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
            captureProvider: FakeCaptureProvider(snapshot: previewCaptureSnapshot(displayID: 113, capturesCursor: true)),
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
            $0.kind == .preview
                && $0.previousDisplayID == 113
                && $0.failureReason == "preview_restore_deferred_until_consumer_lease"
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
            captureProvider: FakeCaptureProvider(snapshot: previewCaptureSnapshot(displayID: 120, capturesCursor: false)),
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
        #expect(recorder.events.contains("removePreview:120"))
        #expect(recorder.events.allSatisfy { !$0.contains("restoreSharing:120") })
        #expect(trace.restoreResults.contains {
            $0.kind == .sharing && $0.failureReason == "target_disabled"
        })
        #expect(trace.restoreResults.contains {
            $0.kind == .preview && $0.failureReason == "target_disabled"
        })
    }
    @Test func disableTransactionRestoresPeerSharingAndDefersPreviewAfterStableTopology() async throws {
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
            captureProvider: FakeCaptureProvider(snapshot: previewCaptureSnapshot(displayID: 122, capturesCursor: false)),
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
            $0.kind == .preview
                && $0.previousDisplayID == 122
                && $0.failureReason == "preview_restore_deferred_until_consumer_lease"
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
}
