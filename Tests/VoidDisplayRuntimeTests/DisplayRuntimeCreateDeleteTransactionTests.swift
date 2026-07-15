@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeCreateDeleteTransactionTests {
    @Test func createTransactionRecordsCommandFactsAndRedactsDisplayName() async throws {
        let createdConfigID = UUID()
        let virtualDisplayProvider = FakeVirtualDisplayProvider(snapshot: .empty)
        let catalogProvider = FakeCatalogProvider(snapshot: catalogSnapshot(displayIDs: [], mainDisplayID: nil))
        let commander = FakeVirtualDisplayCommander()
        commander.createResult = createCommandResult(
            createdConfigID: createdConfigID,
            serialNumber: 9401
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
        let failedResult = createCommandResult(
            createdConfigID: createdConfigID,
            serialNumber: 9402,
            persistenceOutcome: .rollbackFailed,
            runtimeCreationOutcome: .failed,
            rollbackOutcome: .rollbackFailed
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
        commander.createResult = createCommandResult(
            createdConfigID: createdConfigID,
            serialNumber: 9403
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
        let captureIntentCommander = FakeCaptureIntentCommander(recorder: recorder)
        let runtime = DisplayRuntime(
            catalogProvider: catalogProvider,
            captureProvider: FakeCaptureProvider(snapshot: previewCaptureSnapshot(displayID: displayID, capturesCursor: true)),
            sharingProvider: FakeSharingProvider(snapshot: activeSharingSnapshot(displayID: displayID)),
            virtualDisplayProvider: virtualDisplayProvider,
            catalogCommander: FakeCatalogCommander(recorder: recorder),
            sharingCommander: FakeSharingCommander(recorder: recorder),
            captureIntentCommander: captureIntentCommander,
            virtualDisplayCommander: commander,
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
        let deleteIndex = try #require(recorder.events.firstIndex(of: "delete:\(configID.uuidString)"))
        let lanDrainIndex = try #require(recorder.events.firstIndex(of: "applyLAN:drain"))
        let previewDrainIndex = try #require(recorder.events.firstIndex(of: "applyPreview:drain"))
        #expect(lanDrainIndex < deleteIndex)
        #expect(previewDrainIndex < deleteIndex)
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
        let failedResult = deleteCommandResult(
            configID: configID,
            persistenceOutcome: .notAttempted,
            virtualDisplayCommandOutcome: .failed,
            runtimeTrackingClearOutcome: .notAttempted
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
}
