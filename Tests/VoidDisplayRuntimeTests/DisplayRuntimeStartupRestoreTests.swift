@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeStartupRestoreTests {
    @Test func startupRestoreRestoresDesiredConfigAndRecordsTraceEvidence() async throws {
        let configID = UUID(uuidString: "A0010000-0000-0000-0000-000000000001")!
        let catalog = catalogSnapshot(displayID: 301, isMain: false)
        let provider = FakeVirtualDisplayProvider(
            snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 3011, desiredEnabled: true)
        )
        let commander = FakeVirtualDisplayCommander()
        commander.startupConfigLoadResult = .succeeded(configs: [
            startupRestoreConfig(id: configID, serial: 3011, desiredEnabled: true)
        ])
        commander.startupRestoreResults = [
            startupRestoreCommandResult(
                configID: configID,
                postDisplayID: 301
            )
        ]
        commander.onStartupRestore = { _ in
            provider.setSnapshot(
                runningVirtualDisplaySnapshot(
                    configID: configID,
                    serial: 3011,
                    displayID: 301,
                    desiredEnabled: true
                )
            )
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: provider,
            catalogCommander: FakeCatalogCommander(
                snapshot: catalog,
            ),
            virtualDisplayCommander: commander,
            startupRestoreCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = await runtime.restoreStartupVirtualDisplays()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .succeeded)
        #expect(result.source == .startup)
        #expect(result.duplicateBehavior == .started)
        #expect(result.configLoadTrace.desiredEnabledConfigIDs == [configID])
        #expect(result.configResults.map(\.status) == [.restored])
        #expect(result.configResults.first?.topologyStabilityResult?.status == .stable)
        #expect(commander.startupConfigLoadCallCount == 1)
        #expect(commander.startupRestoreCallCount == 1)
        #expect(commander.startupRestoreRequests.map(\.configID) == [configID])

        #expect(trace.kind == .virtualDisplayStartupRestore)
        #expect(trace.source == .startup)
        #expect(trace.startupRestoreRunID == result.runID)
        #expect(trace.startupConfigLoadResult?.desiredEnabledConfigIDs == [configID])
        #expect(trace.startupRestoreIntent?.configID == configID)
        #expect(trace.startupRestoreIntent?.configEvidence.serialNumber == 3011)
        #expect(trace.startupRestoreCommandResult?.restoreOutcome == .succeeded)
        #expect(trace.affectedSurfaces.map(\.configID) == [configID])
        #expect(trace.preSnapshotEvidence?.managedVirtualDisplays.isEmpty == true)
        #expect(trace.postSnapshotEvidence?.managedVirtualDisplays.map(\.displayID) == [301])
        #expect(trace.topologyStabilityResult?.status == .stable)
        #expect(trace.virtualDisplayCommandOutcome == .succeeded)
        #expect(trace.failure == nil)
    }

    @Test func startupRestoreRunsDesiredConfigsInPersistedOrder() async {
        let firstConfigID = UUID(uuidString: "A0010000-0000-0000-0000-000000000006")!
        let secondConfigID = UUID(uuidString: "A0010000-0000-0000-0000-000000000007")!
        let catalog = catalogSnapshot(displayIDs: [307, 308], mainDisplayID: nil)
        let provider = FakeVirtualDisplayProvider(
            snapshot: DisplayRuntimeVirtualDisplaySnapshot(
                runningConfigIDs: [],
                configStoreHasLoadFailure: false,
                configStoreHasDiagnostics: false,
                managedDisplays: [],
                configs: [
                    .init(
                        id: firstConfigID,
                        serialNumber: 3071,
                        desiredEnabled: true,
                        physicalWidthMillimeters: 600,
                        physicalHeightMillimeters: 340,
                        modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                        maximumPixelWidth: 1920,
                        maximumPixelHeight: 1080
                    ),
                    .init(
                        id: secondConfigID,
                        serialNumber: 3081,
                        desiredEnabled: true,
                        physicalWidthMillimeters: 600,
                        physicalHeightMillimeters: 340,
                        modes: [.init(width: 1920, height: 1080, refreshRate: 60, enableHiDPI: false)],
                        maximumPixelWidth: 1920,
                        maximumPixelHeight: 1080
                    )
                ],
                restoreFailureConfigIDs: []
            )
        )
        let commander = FakeVirtualDisplayCommander()
        commander.startupConfigLoadResult = .succeeded(configs: [
            startupRestoreConfig(id: firstConfigID, serial: 3071, desiredEnabled: true),
            startupRestoreConfig(id: secondConfigID, serial: 3081, desiredEnabled: true)
        ])
        commander.startupRestoreResults = [
            startupRestoreCommandResult(
                configID: firstConfigID,
                postDisplayID: 307
            ),
            startupRestoreCommandResult(
                configID: secondConfigID,
                postDisplayID: 308
            )
        ]
        commander.onStartupRestore = { request in
            let restoredRequests = commander.startupRestoreRequests.map(\.configID)
            let managedDisplays: [DisplayRuntimeManagedVirtualDisplay] = restoredRequests.map {
                if $0 == firstConfigID {
                    return .init(configID: firstConfigID, serialNumber: 3071, displayID: 307, isLiveRuntime: true)
                }
                return .init(configID: secondConfigID, serialNumber: 3081, displayID: 308, isLiveRuntime: true)
            }
            provider.setSnapshot(
                DisplayRuntimeVirtualDisplaySnapshot(
                    runningConfigIDs: restoredRequests,
                    configStoreHasLoadFailure: false,
                    configStoreHasDiagnostics: false,
                    managedDisplays: managedDisplays,
                    configs: provider.makeVirtualDisplaySnapshot().configs,
                    restoreFailureConfigIDs: []
                )
            )
            #expect(restoredRequests.last == request.configID)
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: provider,
            catalogCommander: FakeCatalogCommander(
                snapshot: catalog,
            ),
            virtualDisplayCommander: commander,
            startupRestoreCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        let result = await runtime.restoreStartupVirtualDisplays()

        #expect(result.status == .succeeded)
        #expect(commander.startupRestoreRequests.map(\.configID) == [firstConfigID, secondConfigID])
        #expect(result.configResults.allSatisfy { $0.status == .restored })
        #expect(runtime.makeSnapshot().transactions.recentTransactions.filter {
            $0.kind == .virtualDisplayStartupRestore
        }.count == 2)
    }

    @Test func startupRestoreNoDesiredEnabledConfigsCompletesAsNoOp() async throws {
        let configID = UUID(uuidString: "A0010000-0000-0000-0000-000000000002")!
        let provider = FakeVirtualDisplayProvider(
            snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 3021, desiredEnabled: false)
        )
        let commander = FakeVirtualDisplayCommander()
        commander.startupConfigLoadResult = .succeeded(configs: [
            startupRestoreConfig(id: configID, serial: 3021, desiredEnabled: false)
        ])
        let runtime = DisplayRuntime(
            virtualDisplayProvider: provider,
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            startupRestoreCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let result = await runtime.restoreStartupVirtualDisplays()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .succeededNoOp)
        #expect(result.configResults.isEmpty)
        #expect(result.configLoadTrace.persistedConfigIDs == [configID])
        #expect(result.configLoadTrace.desiredEnabledConfigIDs.isEmpty)
        #expect(result.configLoadTrace.desiredDisabledConfigIDs == [configID])
        #expect(commander.startupRestoreCallCount == 0)
        #expect(trace.kind == .virtualDisplayStartupRestore)
        #expect(trace.source == .startup)
        #expect(trace.status == .completed)
        #expect(trace.affectedSurfaces.isEmpty)
        #expect(trace.startupConfigLoadResult?.desiredEnabledConfigIDs.isEmpty == true)
        #expect(trace.startupRestoreCommandResult == nil)
        #expect(trace.failure == nil)
        #expect(trace.preSnapshotEvidence != nil)
        #expect(trace.postSnapshotEvidence != nil)
    }

    @Test func startupRestorePersistenceReadFailureRecordsTerminalFailureWithoutLowerRestore() async throws {
        let commander = FakeVirtualDisplayCommander()
        commander.startupConfigLoadResult = .failed(
            reason: "config_store_read_failed",
            underlyingDomain: "StartupStore",
            underlyingCode: 41
        )
        let runtime = DisplayRuntime(
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            startupRestoreCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let result = await runtime.restoreStartupVirtualDisplays()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .failed)
        #expect(result.configLoadTrace.status == .failed)
        #expect(result.configLoadTrace.failureReason == "config_store_read_failed")
        #expect(commander.startupRestoreCallCount == 0)
        #expect(trace.kind == .virtualDisplayStartupRestore)
        #expect(trace.source == .startup)
        #expect(trace.status == .failed)
        #expect(trace.startupConfigLoadResult?.status == .failed)
        #expect(trace.failure?.reason == "config_store_read_failed")
        #expect(trace.failure?.underlyingDomain == "StartupStore")
        #expect(trace.failure?.underlyingCode == 41)
        #expect(trace.preSnapshotEvidence != nil)
        #expect(trace.postSnapshotEvidence != nil)
        #expect(trace.compensation.status == .skipped)
        #expect(trace.compensation.virtualDisplayCommandOutcome == .notAttempted)
    }

    @Test func startupRestoreMissingConfigFailsPerConfigWithoutLowerRestore() async throws {
        let configID = UUID(uuidString: "A0010000-0000-0000-0000-000000000003")!
        let commander = FakeVirtualDisplayCommander()
        commander.startupConfigLoadResult = .succeeded(configs: [
            startupRestoreConfig(id: configID, serial: 3031, desiredEnabled: true)
        ])
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(snapshot: .empty),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            startupRestoreCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let result = await runtime.restoreStartupVirtualDisplays()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithFailures)
        #expect(result.configResults == [
            .init(
                transactionID: trace.id,
                configID: configID,
                status: .failed,
                restoreOutcome: .notAttempted,
                failureReason: "config_not_found",
                topologyStabilityResult: nil
            )
        ])
        #expect(commander.startupRestoreCallCount == 0)
        #expect(trace.kind == .virtualDisplayStartupRestore)
        #expect(trace.source == .startup)
        #expect(trace.startupRestoreIntent?.configID == configID)
        #expect(trace.startupRestoreCommandResult == nil)
        #expect(trace.failure?.reason == "config_not_found")
        #expect(trace.compensation.virtualDisplayCommandOutcome == .notAttempted)
        #expect(trace.topologyStabilityResult == nil)
    }

    @Test func startupRestoreLowerFailureRecordsCommandFailureWithoutTopologyWhenNoSideEffect() async throws {
        let configID = UUID(uuidString: "A0010000-0000-0000-0000-000000000004")!
        let commander = FakeVirtualDisplayCommander()
        commander.startupConfigLoadResult = .succeeded(configs: [
            startupRestoreConfig(id: configID, serial: 3041, desiredEnabled: true)
        ])
        commander.startupRestoreResults = [
            startupRestoreCommandResult(
                configID: configID,
                postDisplayID: nil,
                restoreOutcome: .failed,
                didProduceVerifiableSideEffect: false,
                failureReason: "driver_restore_failed",
                underlyingDomain: "CGVirtualDisplay",
                underlyingCode: -7
            )
        ]
        let runtime = DisplayRuntime(
            virtualDisplayProvider: FakeVirtualDisplayProvider(
                snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 3041, desiredEnabled: true)
            ),
            catalogCommander: FakeCatalogCommander(),
            virtualDisplayCommander: commander,
            startupRestoreCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 1)
        )

        let result = await runtime.restoreStartupVirtualDisplays()
        let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

        #expect(result.status == .completedWithFailures)
        #expect(result.configResults.first?.status == .failed)
        #expect(result.configResults.first?.failureReason == "driver_restore_failed")
        #expect(result.configResults.first?.topologyStabilityResult == nil)
        #expect(commander.startupRestoreCallCount == 1)
        #expect(trace.startupRestoreCommandResult?.restoreOutcome == .failed)
        #expect(trace.startupRestoreCommandResult?.didProduceVerifiableSideEffect == false)
        #expect(trace.startupRestoreCommandResult?.underlyingDomain == "CGVirtualDisplay")
        #expect(trace.startupRestoreCommandResult?.underlyingCode == -7)
        #expect(trace.failure?.reason == "driver_restore_failed")
        #expect(trace.failure?.underlyingDomain == "CGVirtualDisplay")
        #expect(trace.failure?.underlyingCode == -7)
        #expect(trace.topologyStabilityResult == nil)
        #expect(trace.virtualDisplayCommandOutcome == .failed)
    }

    @Test func startupRestoreReusesTopologyWaitTimedOutAndPermissionSemantics() async throws {
        struct Scenario {
            let expectedStatus: DisplayRuntimeTopologyStabilityStatus
            let catalog: DisplayRuntimeCatalogSnapshot
            let refreshResults: [DisplayRuntimeCatalogRefreshResult]
            let expectedFailureReason: String
        }

        let scenarios: [Scenario] = [
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
                expectedFailureReason: "topology_timedOut"
            ),
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
                expectedFailureReason: "topology_unprovableDueToPermission"
            )
        ]

        for scenario in scenarios {
            let configID = UUID()
            let provider = FakeVirtualDisplayProvider(
                snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 3051, desiredEnabled: true)
            )
            let commander = FakeVirtualDisplayCommander()
            commander.startupConfigLoadResult = .succeeded(configs: [
                startupRestoreConfig(id: configID, serial: 3051, desiredEnabled: true)
            ])
            commander.startupRestoreResults = [
                startupRestoreCommandResult(
                    configID: configID,
                    postDisplayID: 305
                )
            ]
            commander.onStartupRestore = { _ in
                provider.setSnapshot(
                    runningVirtualDisplaySnapshot(
                        configID: configID,
                        serial: 3051,
                        displayID: 305,
                        desiredEnabled: true
                    )
                )
            }
            let runtime = DisplayRuntime(
                catalogProvider: FakeCatalogProvider(snapshot: scenario.catalog),
                virtualDisplayProvider: provider,
                catalogCommander: FakeCatalogCommander(
                    snapshot: scenario.catalog,
                    refreshResults: scenario.refreshResults
                ),
                virtualDisplayCommander: commander,
                startupRestoreCommander: commander,
                topologyWaitPolicy: fastTopologyWaitPolicy(maximumSampleCount: 2)
            )

            let result = await runtime.restoreStartupVirtualDisplays()
            let trace = try #require(runtime.makeSnapshot().transactions.recentTransactions.first)

            #expect(result.status == .completedWithFailures)
            #expect(result.configResults.first?.status == .degraded)
            #expect(result.configResults.first?.failureReason == scenario.expectedFailureReason)
            #expect(result.configResults.first?.topologyStabilityResult?.status == scenario.expectedStatus)
            #expect(trace.failure == nil)
            #expect(trace.topologyStabilityResult?.status == scenario.expectedStatus)
            #expect(trace.restoreResults.isEmpty)
            #expect(trace.compensation.status == .degraded)
            #expect(trace.virtualDisplayCommandOutcome == .succeeded)
        }
    }

    @Test func duplicateStartupRestoreCoalescesActiveRunAndReturnsAlreadyCompletedAfterTerminal() async {
        let configID = UUID(uuidString: "A0010000-0000-0000-0000-000000000005")!
        let catalog = catalogSnapshot(displayID: 306, isMain: false)
        let provider = FakeVirtualDisplayProvider(
            snapshot: disabledVirtualDisplaySnapshot(configID: configID, serial: 3061, desiredEnabled: true)
        )
        let commander = FakeVirtualDisplayCommander(delayNanoseconds: 150_000_000)
        commander.startupConfigLoadResult = .succeeded(configs: [
            startupRestoreConfig(id: configID, serial: 3061, desiredEnabled: true)
        ])
        commander.startupRestoreResults = [
            startupRestoreCommandResult(
                configID: configID,
                postDisplayID: 306
            )
        ]
        commander.onStartupRestore = { _ in
            provider.setSnapshot(
                runningVirtualDisplaySnapshot(
                    configID: configID,
                    serial: 3061,
                    displayID: 306,
                    desiredEnabled: true
                )
            )
        }
        let runtime = DisplayRuntime(
            catalogProvider: FakeCatalogProvider(snapshot: catalog),
            virtualDisplayProvider: provider,
            catalogCommander: FakeCatalogCommander(
                snapshot: catalog,
            ),
            virtualDisplayCommander: commander,
            startupRestoreCommander: commander,
            topologyWaitPolicy: fastTopologyWaitPolicy()
        )

        async let first = runtime.restoreStartupVirtualDisplays()
        async let second = runtime.restoreStartupVirtualDisplays()
        let results = await [first, second]
        let third = await runtime.restoreStartupVirtualDisplays()

        #expect(Set(results.map(\.runID)).count == 1)
        #expect(results.map(\.duplicateBehavior).contains(.started))
        #expect(results.map(\.duplicateBehavior).contains(.coalesced))
        #expect(results.allSatisfy { $0.coalescedRequestCount == 1 })
        #expect(third.runID == results[0].runID)
        #expect(third.duplicateBehavior == .alreadyCompleted)
        #expect(commander.startupConfigLoadCallCount == 1)
        #expect(commander.startupRestoreCallCount == 1)
    }
}
