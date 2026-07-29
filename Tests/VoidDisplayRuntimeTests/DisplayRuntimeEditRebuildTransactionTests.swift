@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeEditRebuildTransactionTests {
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
        #expect(recorder.events.allSatisfy { !$0.hasPrefix("stopSharing") && !$0.hasPrefix("removePreview") })
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
        #expect(recorder.events.allSatisfy { !$0.hasPrefix("stopSharing") && !$0.hasPrefix("removePreview") })
    }
    @Test func editRebuildQuiesceFailureRollsBackConfigAndSkipsRebuild() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000014")!
        let previous = editConfigDTO(id: configID, displayName: "Previous", serial: 9114)
        let edited = editConfigDTO(id: configID, displayName: "Edited", serial: 9115)
        let catalog = catalogSnapshot(displayID: 114, isMain: false)
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
        virtualDisplayCommander.saveConfigForRebuildResult = editRebuildSaveCommandResult(
            previousConfigForCompensation: previous,
            savedConfig: edited
        )
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: virtualDisplaySnapshot(configID: configID, displayID: 114)
            ),
            catalogCommander: FakeCatalogCommander(
                snapshot: catalog,
            ),
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

        let handle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(
                editedConfig: edited,
                expectedConfigFingerprint: previous.fingerprint,
                source: .editSaveAndRebuild
            ),
            source: .editSaveAndRebuild
        )
        _ = try await handle.waitForSaveGate()
        let result = try await handle.waitForTerminalResult()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .failed)
        #expect(result.virtualDisplayCommandSucceeded == false)
        #expect(trace.failure?.phase == .quiescingSessions)
        #expect(trace.failure?.reason == "consumer_session_quiesce_failed")
        #expect(trace.compensation.status == .completed)
        #expect(trace.compensation.persistenceOutcome == .rolledBack)
        #expect(trace.compensation.virtualDisplayCommandOutcome == .notAttempted)
        #expect(virtualDisplayCommander.restoreConfigAfterFailedEditCallCount == 1)
        #expect(virtualDisplayCommander.rebuildCallCount == 0)
        #expect(runtime.consumerLease(leaseID: lease.id)?.state == .attached)
        #expect(runtime.isConsumerTransitionBusy(surfaceIdentity: surfaceIdentity) == false)
        #expect(captureIntentCommander.intents.map(\.reason) == [
            .attach,
            .transactionQuiesce,
            .epochChanged
        ])
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
        commander.saveConfigForRebuildResult = editRebuildSaveCommandResult(
            previousConfigForCompensation: previous,
            savedConfig: edited
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
        commander.saveConfigForRebuildResult = editRebuildSaveCommandResult(
            previousConfigForCompensation: previous,
            savedConfig: edited
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
        commander.saveConfigForRebuildResult = editRebuildSaveCommandResult(
            previousConfigForCompensation: previous,
            savedConfig: edited
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
}
