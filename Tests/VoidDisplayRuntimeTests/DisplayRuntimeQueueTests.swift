@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeQueueTests {
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
    @Test func disableEnableDisableKeepsAllThreeIntentsInOrder() async throws {
        let configID = UUID(uuidString: "E0010000-0000-0000-0000-000000000020")!
        let catalog = catalogSnapshot(displayID: 129, isMain: false)
        let virtualDisplayProvider = FakeVirtualDisplayProvider(
            snapshot: runningVirtualDisplaySnapshot(
                configID: configID,
                serial: 1291,
                displayID: 129,
                desiredEnabled: true
            )
        )
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 50_000_000)
        commander.onSetDesiredEnabled = { _, enabled in
            virtualDisplayProvider.setSnapshot(disabledVirtualDisplaySnapshot(
                configID: configID,
                serial: 1291,
                desiredEnabled: enabled
            ))
        }
        commander.onDisable = { _ in
            virtualDisplayProvider.setSnapshot(disabledVirtualDisplaySnapshot(
                configID: configID,
                serial: 1291,
                desiredEnabled: false
            ))
        }
        commander.onEnable = { _ in
            virtualDisplayProvider.setSnapshot(runningVirtualDisplaySnapshot(
                configID: configID,
                serial: 1291,
                displayID: 129,
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

        let firstDisable = Task { @MainActor in
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
                source: .diagnostics
            )
        }
        await Task.yield()
        let finalDisable = Task { @MainActor in
            try await runtime.setVirtualDisplayDesiredEnabled(
                configID: configID,
                enabled: false,
                source: .virtualDisplayRowToggle
            )
        }
        let results = try await [firstDisable.value, enable.value, finalDisable.value]

        #expect(Set(results.map(\.transactionID)).count == 3)
        #expect(commander.disableCallCount == 2)
        #expect(commander.enableCallCount == 1)
        #expect(virtualDisplayProvider.makeVirtualDisplaySnapshot().configs.first?.desiredEnabled == false)
    }
    @Test func rebuildEditRebuildDoesNotCoalesceAcrossEditTransaction() async throws {
        let configID = UUID(uuidString: "3B020000-0000-0000-0000-000000000012")!
        let initial = editConfigDTO(id: configID, displayName: "Initial", serial: 9121)
        let edited = editConfigDTO(id: configID, displayName: "Edited", serial: 9122)
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
            provider.setSnapshot(
                runningVirtualDisplaySnapshot(
                    configID: configID,
                    serial: request.editedConfig.serialNumber,
                    displayID: 112,
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

        let firstRebuild = Task { @MainActor in
            try await runtime.rebuildVirtualDisplay(configID: configID, source: .virtualDisplayRowRetry)
        }
        await Task.yield()
        let editHandle = try await runtime.saveVirtualDisplayConfigAndRebuild(
            request: .init(
                editedConfig: edited,
                expectedConfigFingerprint: initial.fingerprint,
                source: .editSaveAndRebuild
            ),
            source: .editSaveAndRebuild
        )
        let finalRebuild = Task { @MainActor in
            try await runtime.rebuildVirtualDisplay(configID: configID, source: .diagnostics)
        }

        let firstResult = try await firstRebuild.value
        _ = try await editHandle.waitForSaveGate()
        _ = try await editHandle.waitForTerminalResult()
        let finalResult = try await finalRebuild.value

        #expect(firstResult.transactionID != finalResult.transactionID)
        #expect(Set([firstResult.transactionID, editHandle.transactionID, finalResult.transactionID]).count == 3)
        #expect(commander.rebuildCallCount == 3)
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
}
