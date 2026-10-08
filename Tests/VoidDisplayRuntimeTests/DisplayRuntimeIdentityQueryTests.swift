@testable import VoidDisplayRuntime
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct DisplayRuntimeIdentityQueryTests {
    @Test func managedDisplayIDReadsCurrentVirtualProviderOnly() {
        let providers = IdentityQueryProviders()
        let configID = UUID()
        let runtime = providers.makeRuntime()
        #expect(runtime.managedDisplayID(for: configID) == nil)
        providers.virtualDisplay = virtualDisplaySnapshot(configID: configID, displayID: 77)
        #expect(runtime.managedDisplayID(for: configID) == 77)
        providers.virtualDisplay = virtualDisplaySnapshot(configID: configID, displayID: 88)
        #expect(runtime.managedDisplayID(for: configID) == 88)
        #expect(runtime.managedDisplayID(for: UUID()) == nil)
        #expect(providers.readCounts == [0, 0, 0, 4])
    }

    @Test func managedAndCatalogQueriesSkipUnrelatedProviders() {
        let providers = IdentityQueryProviders()
        let configID = UUID()
        providers.virtualDisplay = virtualDisplaySnapshot(configID: configID, displayID: 77)
        providers.catalog = catalogSnapshot(displayID: 88, isMain: false)
        let runtime = providers.makeRuntime()

        #expect(runtime.surfaceIdentityForDisplayID(77) == .managedVirtualDisplay(configID: configID))
        #expect(runtime.surfaceIdentityForDisplayID(88) == .physicalDisplay(displayID: 88))
        #expect(providers.readCounts == [2, 0, 0, 2])
    }

    @Test func catalogRefreshWithoutCommanderReadsOnlyCatalog() async {
        let providers = IdentityQueryProviders()
        providers.catalog = catalogSnapshot(displayID: 88, isMain: false)
        let runtime = providers.makeRuntime()
        let outcome = await runtime.forceRefreshCatalog(source: .capturePage)
        #expect(outcome.result == .failed)
        #expect(outcome.catalog == providers.catalog)
        #expect(providers.readCounts == [1, 0, 0, 0])
    }

    @Test func unresolvedLeaseIdentityReadsSurfaceFacts() {
        let providers = IdentityQueryProviders()
        let configID = UUID()
        providers.virtualDisplay = virtualDisplaySnapshot(configID: configID, displayID: 77)
        let runtime = providers.makeRuntime()
        #expect(runtime.resolvedDisplayID(for: .managedVirtualDisplay(configID: configID), surfaces: nil) == 77)
        #expect(providers.readCounts == [1, 1, 1, 1])
    }

    @Test func identityQueryPreservesCaptureAndSharingOnlySources() {
        let providers = IdentityQueryProviders()
        providers.capture = captureSnapshot(displayIDs: [77])
        providers.sharing = activeSharingSnapshot(displayID: 88)
        let runtime = providers.makeRuntime()

        #expect(runtime.surfaceIdentityForDisplayID(77) == .physicalDisplay(displayID: 77))
        #expect(runtime.surfaceIdentityForDisplayID(88) == .physicalDisplay(displayID: 88))
        #expect(runtime.surfaceIdentityForDisplayID(99) == nil)
    }

    @Test func identityQueryMatchesGraphWhenManagedRecordsContainDuplicates() {
        let providers = IdentityQueryProviders()
        let configID = UUID()
        providers.virtualDisplay = .init(
            runningConfigIDs: [configID], configStoreHasLoadFailure: false, configStoreHasDiagnostics: false,
            managedDisplays: [
                .init(configID: configID, serialNumber: 91, displayID: 77, isLiveRuntime: true),
                .init(configID: configID, serialNumber: 91, displayID: 88, isLiveRuntime: false)
            ], configs: [], restoreFailureConfigIDs: []
        )
        providers.catalog = catalogSnapshot(displayID: 88, isMain: false)
        providers.sharing = activeSharingSnapshot(displayID: 88)
        let runtime = providers.makeRuntime()
        let surfaces = runtime.makeSnapshot().surfaces
        #expect(runtime.managedDisplayID(for: configID) == surfaces.first {
            $0.identity == .managedVirtualDisplay(configID: configID)
        }?.currentDisplayID)
        for displayID in [77, 88, 99] as [DisplayRuntimeDisplayID] {
            #expect(runtime.surfaceIdentityForDisplayID(displayID) == surfaces.first { $0.currentDisplayID == displayID }?.identity)
        }
    }
}

@MainActor
@Suite(.serialized)
struct OptimizationIdentityMeasurements {
    @Test func measureManagedQueryReads() {
        for round in 0..<5 {
            let providers = IdentityQueryProviders()
            let configID = UUID()
            providers.virtualDisplay = virtualDisplaySnapshot(configID: configID, displayID: 77)
            let runtime = providers.makeRuntime()
            let clock = ContinuousClock()
            let start = clock.now
            var resolvedCount = 0
            for _ in 0..<1_000 {
                if runtime.surfaceIdentityForDisplayID(77) == .managedVirtualDisplay(configID: configID) { resolvedCount += 1 }
            }
            let duration = start.duration(to: clock.now).components
            let nanoseconds = duration.seconds * 1_000_000_000 + duration.attoseconds / 1_000_000_000
            #expect(resolvedCount == 1_000)
            print("OPTIMIZATION_METRIC identity_round=\(round) identity_queries=1000 provider_reads=\(providers.readCounts.reduce(0, +)) elapsed_ns=\(nanoseconds)")
        }
    }
}

@MainActor
private final class IdentityQueryProviders: DisplayRuntimeCatalogProviding, DisplayRuntimeCaptureProviding,
    DisplayRuntimeSharingProviding, DisplayRuntimeVirtualDisplayProviding {
    var catalog: DisplayRuntimeCatalogSnapshot = .empty
    var capture: DisplayRuntimeCaptureSnapshot = .empty
    var sharing: DisplayRuntimeSharingSnapshot = .empty
    var virtualDisplay: DisplayRuntimeVirtualDisplaySnapshot = .empty
    private(set) var readCounts = [0, 0, 0, 0]

    func makeRuntime() -> DisplayRuntime {
        DisplayRuntime(catalogProvider: self, captureProvider: self, sharingProvider: self, virtualDisplayProvider: self)
    }

    func makeCatalogSnapshot() -> DisplayRuntimeCatalogSnapshot {
        readCounts[0] += 1
        return catalog
    }

    func makeCaptureSnapshot() -> DisplayRuntimeCaptureSnapshot {
        readCounts[1] += 1
        return capture
    }

    func makeSharingSnapshot() -> DisplayRuntimeSharingSnapshot {
        readCounts[2] += 1
        return sharing
    }

    func makeVirtualDisplaySnapshot() -> DisplayRuntimeVirtualDisplaySnapshot {
        readCounts[3] += 1
        return virtualDisplay
    }
}
