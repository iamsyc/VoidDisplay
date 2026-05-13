@testable import VoidDisplayFoundation
@testable import VoidDisplayObservability
@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeTopologyWaitTests {
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
}
